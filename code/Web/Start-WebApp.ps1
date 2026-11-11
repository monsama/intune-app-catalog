# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    Runs the web interface: IntuneDeployment.ps1 -Web dot-sources this after
    loading code\Private, the same functions the classic window uses.
#>
param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [switch]$NoBrowser
)

# Windows-only assemblies some shared functions use for types (colors,
# certificate dialogs). Absent on Linux, where the server still runs for CI.
# System.Windows.Forms too: shared functions name its types in their
# parameters (an optional log box), and PowerShell resolves those when the
# function is called, even when nothing is passed. Nothing is shown.
foreach ($assembly in 'System.Drawing', 'System.Security', 'System.Windows.Forms') {
    try { Add-Type -AssemblyName $assembly -ErrorAction Stop } catch { }
}

. (Join-Path $PSScriptRoot 'WebServer.ps1')
. (Join-Path $PSScriptRoot 'WebApi.ps1')
. (Join-Path $PSScriptRoot 'WebScripts.ps1')

Initialize-AppState -RootPath $RootPath
$Global:App.WebLog = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$Global:App.WebJobs = [hashtable]::Synchronized(@{})
$Global:App.WebPending = [hashtable]::Synchronized(@{})
try {
    $logFolder = Get-AppFolder -Kind Logs -Create
    $Global:App.WebLogFile = Join-Path $logFolder ("intune-deployment-" + (Get-Date).ToString('yyyy-MM-dd') + ".log")
}
catch { $Global:App.WebLogFile = $null }

$uiRoot = Join-Path $PSScriptRoot 'ui'
$token = [guid]::NewGuid().ToString('N')

# A fixed port keeps the page's origin - and with it what the browser
# remembers for it (column widths, the last tab) - the same from one start
# to the next; a random one only when all of them are taken.
$listener = $null; $port = 0
foreach ($try in 17710..17717) {
    try { $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $try); $l.Start(); $listener = $l; $port = $try; break }
    catch { $listener = $null }
}
if (-not $listener) {
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $listener.Start(); $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
}
$url = "http://127.0.0.1:$port/#t=$token"

Write-Host ""
Write-Host "  Intune App Catalog $($Global:App.AppVersion) - web interface" -ForegroundColor Green
Write-Host "  Open:  $url"
Write-Host "  Close the app window (or this console) to stop." -ForegroundColor DarkGray
Write-Host ""
Write-Log "[INFO] Web interface started on 127.0.0.1:$port."

# Every request runs in a pooled runspace with this app's functions and
# its shared state - so a slow Graph call doesn't hold up the page.
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($fn in Get-ChildItem function: | Where-Object { $_.ScriptBlock.File -and $_.ScriptBlock.File.StartsWith($RootPath, [System.StringComparison]::OrdinalIgnoreCase) }) {
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn.Name, $fn.ScriptBlock)))
}
$shared = [hashtable]::Synchronized(@{ LastPing = Get-Date; Quit = $false })
foreach ($entry in @(@('App', $Global:App), @('WebToken', $token), @('WebShared', $shared), @('WebUiRoot', $uiRoot))) {
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($entry[0], $entry[1], '')))
}
$pool = [runspacefactory]::CreateRunspacePool(1, 8, $iss, $Host)
$pool.Open()

$handler = {
    param($Client)
    try {
        $req = Read-WebRequest $Client
        $refusal = Test-WebRequestAllowed $req
        if ($refusal) { Send-WebResponse $Client '403 Forbidden' 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('Forbidden')); return }
        if ($req.Path -like '/api/*') {
            $data = $null
            try { if ($req.Body) { $data = $req.Body | ConvertFrom-Json } } catch { }
            if (-not (Test-WebToken -Data $data -Expected $WebToken)) { Send-WebJson $Client @{ ok = $false; error = 'bad token' }; return }
            if ($req.Path -eq '/api/ping') { $WebShared.LastPing = Get-Date; Send-WebJson $Client @{ ok = $true }; return }
            if ($req.Path -eq '/api/quit') { Send-WebJson $Client @{ ok = $true }; $WebShared.Quit = $true; return }
            Send-WebJson $Client (Invoke-WebApi -Path $req.Path -Data $data)
            return
        }
        $file = Get-WebStaticFile -Path $req.Path -UiRoot $WebUiRoot
        if ($file) { Send-WebResponse $Client '200 OK' $file.ContentType $file.Bytes }
        else { Send-WebResponse $Client '404 Not Found' 'text/plain' ([Text.Encoding]::UTF8.GetBytes('not found')) }
    }
    catch {
        try { Send-WebJson $Client @{ ok = $false; error = $_.Exception.Message } } catch { }
    }
    finally { try { $Client.Close() } catch { } }
}

$browser = $null
if (-not $NoBrowser) {
    $browser = Start-WebAppWindow -Url $url
    if (-not $browser) {
        Write-Host "  No Edge or Chrome found - opening your default browser." -ForegroundColor Yellow
        try { Start-Process $url } catch { }
    }
}

$inFlight = New-Object System.Collections.Generic.List[object]
$run = $true
while ($run) {
    $pending = $false
    try { $pending = $listener.Server.Poll(200000, [System.Net.Sockets.SelectMode]::SelectRead) } catch { Start-Sleep -Milliseconds 50 }
    if ($pending) {
        $client = $null
        try { $client = $listener.AcceptTcpClient() } catch { $client = $null }
        if ($client) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($handler).AddArgument($client)
            $inFlight.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
        }
    }
    $still = New-Object System.Collections.Generic.List[object]
    foreach ($item in $inFlight) {
        if ($item.Handle.IsCompleted) {
            try { [void]$item.PS.EndInvoke($item.Handle) } catch { Write-Host "Request error: $($_.Exception.Message)" -ForegroundColor Yellow }
            $item.PS.Dispose()
        }
        else { $still.Add($item) }
    }
    $inFlight = $still
    if ($shared.Quit) { $run = $false }
    elseif ($browser -and $browser.HasExited) { $run = $false }
    elseif (((Get-Date) - $shared.LastPing).TotalHours -gt 6) { $run = $false }
}

foreach ($item in $inFlight) {
    try { [void]$item.Handle.AsyncWaitHandle.WaitOne(2000); [void]$item.PS.EndInvoke($item.Handle) } catch { }
    $item.PS.Dispose()
}
try { $pool.Close(); $pool.Dispose() } catch { }
try { $listener.Stop() } catch { }
Write-Host "Stopped."
