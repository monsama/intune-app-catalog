# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    Runs the app: IntuneDeployment.ps1 dot-sources this after loading
    code\Private.
#>
param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [switch]$NoBrowser,
    [switch]$RunUpdates,
    [switch]$PlanOnly,
    [switch]$FastTrackOnly
)

# Certificate dialogs and X509 helpers (New-WebCertificate, the certificate
# checks) - absent on Linux, where the server still runs for CI.
try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }

. (Join-Path $PSScriptRoot 'WebServer.ps1')
. (Join-Path $PSScriptRoot 'WebApi.ps1')
. (Join-Path $PSScriptRoot 'WebEditor.ps1')
. (Join-Path $PSScriptRoot 'WebDeploy.ps1')
. (Join-Path $PSScriptRoot 'WebSettings.ps1')
. (Join-Path $PSScriptRoot 'WebGraph.ps1')
. (Join-Path $PSScriptRoot 'WebScripts.ps1')
. (Join-Path $PSScriptRoot 'WebGroups.ps1')
. (Join-Path $PSScriptRoot 'WebChecks.ps1')
. (Join-Path $PSScriptRoot 'WebBatch.ps1')
. (Join-Path $PSScriptRoot 'WebBulk.ps1')
. (Join-Path $PSScriptRoot 'WebTenant.ps1')
. (Join-Path $PSScriptRoot 'WebReleases.ps1')
. (Join-Path $PSScriptRoot 'WebAutomation.ps1')
. (Join-Path $PSScriptRoot 'WebAdd.ps1')
. (Join-Path $PSScriptRoot 'WebConvenience.ps1')
. (Join-Path $PSScriptRoot 'WebSetup.ps1')
. (Join-Path $PSScriptRoot 'WebBlocks.ps1')
. (Join-Path $PSScriptRoot 'WebServerMode.ps1')
. (Join-Path $PSScriptRoot 'WebPcHelpers.ps1')

Initialize-AppState -RootPath $RootPath
$Global:App.WebLog = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$Global:App.WebJobs = [hashtable]::Synchronized(@{})
$Global:App.WebPending = [hashtable]::Synchronized(@{})
# Held while a request changes an app's file (Invoke-WithCatalogLock).
$Global:App.CatalogLock = New-Object System.Object
try {
    $logFolder = Get-AppFolder -Kind Logs -Create
    $Global:App.WebLogFile = Join-Path $logFolder ("intune-deployment-" + (Get-Date).ToString('yyyy-MM-dd') + ".log")
}
catch { $Global:App.WebLogFile = $null }

# What earlier runs left behind, and what has grown old enough to go (Invoke-WebHousekeeping).
try { Invoke-WebHousekeeping } catch { }
# Apps not in Intune yet still on Winget-AutoUpdate's commands (before 2.19) switch by themselves - nothing to send.
try { [void](Invoke-WithCatalogLock { Invoke-WebWauSwitch @{ auto = $true } }) } catch { }

if (Enable-WebTestGraph) {
    Write-Host "  TEST MODE: Graph answers come from $env:INTUNE_CATALOG_TEST_GRAPH - nothing reaches a tenant." -ForegroundColor Red
    Write-Log "[WARN] Test mode: Graph answers come from $env:INTUNE_CATALOG_TEST_GRAPH."
}

# The unattended run: no server, no window - the same functions the page's buttons use, then the process ends.
if ($RunUpdates) {
    $exitCode = Invoke-ManagedUpdateRun -PlanOnly:$PlanOnly -FastTrackOnly:$FastTrackOnly
    # Steps still running (a release that took longer than the run waits): finished or stopped, not left behind.
    try { Complete-WebJobsAtExit -TimeoutMinutes 30 -StopUnfinished } catch { }
    exit $exitCode
}

$uiRoot = Join-Path $PSScriptRoot 'ui'
$token = [guid]::NewGuid().ToString('N')
# Server mode (the container): every address, the port from ICA_PORT, a sign-in instead of the start token.
$serverMode = Test-WebServerMode
if ($serverMode) {
    try { Initialize-WebServerMode }
    catch { Write-Host "  Can't start: $($_.Exception.Message)" -ForegroundColor Red; Write-Log "[FAILED] Server mode: $($_.Exception.Message)"; exit 1 }
    $NoBrowser = $true
}

# A fixed port keeps the page's origin - and with it what the browser
# remembers for it (column widths, the last tab) - the same from one start
# to the next; a random one only when all of them are taken.
$listener = $null; $port = 0
if ($serverMode) {
    $port = $Global:App.Server.Port
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Any, $port)
    $listener.Start()
}
else {
    foreach ($try in 17710..17717) {
        try { $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $try); $l.Start(); $listener = $l; $port = $try; break }
        catch { $listener = $null }
    }
}
if (-not $listener) {
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $listener.Start(); $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
}
$url = if ($serverMode) { "port $port, for $(@($Global:App.Server.Hosts) -join ', ')" } else { "http://127.0.0.1:$port/#t=$token" }

Write-Host ""
Write-Host "  Intune App Catalog $($Global:App.AppVersion) - web interface" -ForegroundColor Green
Write-Host "  Open:  $url"
Write-Host $(if ($serverMode) { '  Server mode: sign in with the admin password. Runs until the container stops.' } else { '  Close the app window (or this console) to stop.' }) -ForegroundColor DarkGray
Write-Host ""
Write-Log "[INFO] Web interface started on $(if ($serverMode) { "port $port (server mode)" } else { "127.0.0.1:$port" })."

# Every request runs in a pooled runspace with this app's functions and
# its shared state - so a slow Graph call doesn't hold up the page.
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($fn in Get-ChildItem function: | Where-Object { $_.ScriptBlock.File -and $_.ScriptBlock.File.StartsWith($RootPath, [System.StringComparison]::OrdinalIgnoreCase) }) {
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn.Name, $fn.ScriptBlock)))
}
$shared = [hashtable]::Synchronized(@{ LastPing = Get-Date; Quit = $false })
foreach ($entry in @(@('App', $Global:App), @('WebToken', $token), @('WebShared', $shared), @('WebUiRoot', $uiRoot), @('WebServerMode', $serverMode))) {
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($entry[0], $entry[1], '')))
}
# 16 at a time: a few slow clients can't take every slot (each also has a deadline - Read-WebRequest).
$pool = [runspacefactory]::CreateRunspacePool(1, 16, $iss, $Host)
$pool.Open()

$handler = {
    param($Client)
    try {
        $req = Read-WebRequest $Client
        $refusal = Test-WebRequestAllowed $req
        if ($refusal) { Send-WebResponse $Client '403 Forbidden' 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('Forbidden')); return }
        if ($req.Path -like '/api/*') {
            # The container's health check (a GET) - the page's own Health checks are a POST to the same name.
            if ($req.Path -eq '/api/health' -and $req.Method -eq 'GET') { Send-WebJson $Client @{ ok = $true; version = $App.AppVersion }; return }
            $data = $null
            try { if ($req.Body) { $data = $req.Body | ConvertFrom-Json } } catch { }
            # Before signing in: what kind of server this is, and the sign-in itself.
            if ($req.Path -eq '/api/hello') { Send-WebJson $Client @{ ok = $true; server = [bool]$WebServerMode; version = $App.AppVersion }; return }
            if ($WebServerMode) {
                if ($req.Path -eq '/api/login') { Send-WebJson $Client (Invoke-WebLogin -Data $data -Agent $req.Agent -Client $req.ClientAddr); return }
                if ($req.Path -eq '/api/logout') { Send-WebJson $Client (Invoke-WebLogout -Token ([string]$data.token)); return }
                $why = Test-WebSession ([string]$data.token)
                if ($why) { Send-WebJson $Client @{ ok = $false; error = 'bad token'; reason = $why }; return }
                # The container runs until it is stopped: no idle stop, no Quit.
                if ($req.Path -eq '/api/ping') { Send-WebJson $Client @{ ok = $true; server = $true }; return }
                if ($req.Path -eq '/api/quit') { Send-WebJson $Client @{ ok = $false; error = 'The server runs until its container is stopped.' }; return }
            }
            elseif (-not (Test-WebToken -Data $data -Expected $WebToken)) { Send-WebJson $Client @{ ok = $false; error = 'bad token' }; return }
            if ($req.Path -eq '/api/ping') { $WebShared.LastPing = Get-Date; Send-WebJson $Client @{ ok = $true }; return }
            if ($req.Path -eq '/api/quit') { Send-WebJson $Client @{ ok = $true }; $WebShared.Quit = $true; return }
            Send-WebJson $Client (Invoke-WebApi -Path $req.Path -Data $data)
            return
        }
        # A file the page prepared (a Sandbox test zip): once, by its random link.
        if ($req.Method -eq 'GET' -and $req.Path -match '^/download/([0-9a-f]{32})$') { Send-WebDownload -Client $Client -Id $Matches[1]; return }
        $file = Get-WebStaticFile -Path $req.Path -UiRoot $WebUiRoot
        if ($file) { Send-WebResponse $Client '200 OK' $file.ContentType $file.Bytes }
        else { Send-WebResponse $Client '404 Not Found' 'text/plain' ([Text.Encoding]::UTF8.GetBytes('not found')) }
    }
    catch {
        try { Send-WebJson $Client @{ ok = $false; error = (Protect-LogText $_.Exception.Message) } } catch { }
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
$lastOrphanCheck = Get-Date
$lastScheduleCheck = Get-Date; $scheduleState = @{}
while ($run) {
    $pending = $false
    try { $pending = $listener.Server.Poll(200000, [System.Net.Sockets.SelectMode]::SelectRead) } catch { Start-Sleep -Milliseconds 50 }
    if ($pending) {
        $client = $null
        try { $client = $listener.AcceptTcpClient() } catch { $client = $null }
        # At most 64 requests at once: a local program opening connections
        # without end would otherwise queue up runspaces without end.
        if ($client -and $inFlight.Count -ge 64) { try { $client.Close() } catch { }; $client = $null }
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
    # A step that ended while no page polled it (reload, closed tab) is finished here.
    if (((Get-Date) - $lastOrphanCheck).TotalSeconds -ge 5) { $lastOrphanCheck = Get-Date; try { Complete-WebOrphanJobs } catch { } }
    # The server version: its own schedule for the nightly and fast-track runs (no Windows scheduled tasks).
    if ($serverMode -and ((Get-Date) - $lastScheduleCheck).TotalSeconds -ge 30) { $lastScheduleCheck = Get-Date; try { Invoke-WebServerSchedule -State $scheduleState } catch { } }
    if ($shared.Quit) { $run = $false }
    elseif ($browser -and $browser.HasExited) { $run = $false }
    elseif (-not $serverMode -and ((Get-Date) - $shared.LastPing).TotalHours -gt 6) { $run = $false }
}

foreach ($item in $inFlight) {
    try { [void]$item.Handle.AsyncWaitHandle.WaitOne(2000); [void]$item.PS.EndInvoke($item.Handle) } catch { }
    $item.PS.Dispose()
}

# Steps still running when the window closed (a deploy, a push, a pull) go on
# in their own process - wait for them and finish them as the page would have,
# or a created app's App ID would never reach the catalog and the next Deploy
# would create it a second time.
Complete-WebJobsAtExit
try { $pool.Close(); $pool.Dispose() } catch { }
try { $listener.Stop() } catch { }
Write-Host "Stopped."
