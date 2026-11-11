<#
.SYNOPSIS
    Starts the real web interface server (IntuneDeployment.ps1 -Web
    -NoBrowser) in a child PowerShell and talks to it over HTTP: the page
    and its files, the token, the refusals (wrong Host, foreign Origin, not
    JSON, no token), and the API answers that need no tenant.

    Runs anywhere PowerShell does - the server is plain TcpListener and the
    catalog/settings code, no WinForms.

    pwsh -NoProfile -File code/tests/WebServer.Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$failures = New-Object System.Collections.Generic.List[string]
$passed = 0
function Check([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { $script:passed++ } else { $script:failures.Add("$Name $Detail") ; Write-Host "FAIL: $Name $Detail" -ForegroundColor Red }
}

$hostExe = (Get-Process -Id $PID).Path
$entry = Join-Path $repoRoot 'IntuneDeployment.ps1'
$outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("websrv-" + [guid]::NewGuid().ToString('N') + ".out")
$startArgs = @{
    FilePath               = $hostExe
    ArgumentList           = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$entry`"", '-Web', '-NoBrowser')
    RedirectStandardOutput = $outFile
    PassThru               = $true
}
# -WindowStyle exists only on Windows.
if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { $startArgs.WindowStyle = 'Hidden' }
$proc = Start-Process @startArgs

try {
    # The server prints "Open:  http://127.0.0.1:<port>/#t=<token>" once it listens.
    $url = $null
    $deadline = (Get-Date).AddSeconds(90)
    while (-not $url -and (Get-Date) -lt $deadline -and -not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $outFile) {
            $m = Select-String -LiteralPath $outFile -Pattern 'Open:\s+(http://127\.0\.0\.1:\d+)/#t=([0-9a-f]{32})' | Select-Object -First 1
            if ($m) { $url = $m.Matches[0].Groups[1].Value; $token = $m.Matches[0].Groups[2].Value }
        }
    }
    Check ([bool]$url) 'the server starts and prints its address' "(exited: $($proc.HasExited); output: $(if (Test-Path $outFile) { Get-Content $outFile -Raw }))"
    if (-not $url) { throw 'no server' }

    function Invoke-Raw {
        # A raw request, so Host/Origin can be anything (Invoke-WebRequest won't send a foreign Host).
        param([string]$Method = 'GET', [string]$Path = '/', [string]$HostHeader, [string]$Origin, [string]$ContentType, [string]$Body = '')
        $port = [int]($url -replace '.*:(\d+)$', '$1')
        $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $port)
        try {
            $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $head = "$Method $Path HTTP/1.1`r`nHost: $(if ($HostHeader) { $HostHeader } else { "127.0.0.1:$port" })`r`n"
            if ($Origin) { $head += "Origin: $Origin`r`n" }
            if ($ContentType) { $head += "Content-Type: $ContentType`r`n" }
            $head += "Content-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
            $stream = $client.GetStream()
            $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
            $stream.Write($headBytes, 0, $headBytes.Length); $stream.Write($bodyBytes, 0, $bodyBytes.Length); $stream.Flush()
            $reader = New-Object System.IO.StreamReader($stream)
            $text = $reader.ReadToEnd()
            $split = $text.IndexOf("`r`n`r`n")
            return @{ Status = [int](($text -split ' ')[1]); Headers = $text.Substring(0, [Math]::Max(0, $split)); Body = $(if ($split -ge 0) { $text.Substring($split + 4) } else { '' }) }
        }
        finally { $client.Close() }
    }
    function Invoke-Api([string]$Path, [hashtable]$Data = @{}, [string]$Token = $token) {
        $Data.token = $Token
        $r = Invoke-Raw -Method POST -Path $Path -ContentType 'application/json' -Body ($Data | ConvertTo-Json -Compress)
        return ($r.Body | ConvertFrom-Json)
    }

    # The page and its files
    $page = Invoke-Raw -Path '/'
    Check ($page.Status -eq 200 -and $page.Body -like '*<script src="app.js"*') 'the page is served'
    Check ($page.Headers -match 'Content-Security-Policy: default-src ''self''' -and $page.Headers -match 'X-Frame-Options: DENY' -and $page.Headers -match 'Cache-Control: no-store') 'every response carries the security headers' $page.Headers
    Check ($page.Body -notmatch '<script>[^<]') 'no inline script (the CSP allows none)'
    Check ((Invoke-Raw -Path '/app.js').Status -eq 200) 'app.js is served'
    Check ((Invoke-Raw -Path '/app.css').Status -eq 200) 'app.css is served'
    Check ((Invoke-Raw -Path '/../IntuneDeployment.ps1').Status -eq 404) 'nothing outside the fixed file list'
    Check ((Invoke-Raw -Path '/code/Web/WebApi.ps1').Status -eq 404) 'not even the app''s own files'

    # Refusals
    Check ((Invoke-Raw -Path '/' -HostHeader 'evil.example:80').Status -eq 403) 'a foreign Host is refused (DNS rebinding)'
    Check ((Invoke-Raw -Method POST -Path '/api/state' -ContentType 'application/json' -Origin 'https://evil.example' -Body "{`"token`":`"$token`"}").Status -eq 403) 'a foreign Origin is refused'
    Check ((Invoke-Raw -Method POST -Path '/api/state' -ContentType 'text/plain' -Body "{`"token`":`"$token`"}").Status -eq 403) 'an API call that is not JSON is refused (a cross-site form can''t send JSON)'
    Check ((Invoke-Raw -Method GET -Path '/api/state').Status -eq 403) 'an API GET is refused'
    Check ((Invoke-Api '/api/state' -Token ('0' * 32)).error -eq 'bad token') 'a wrong token gets nothing'
    Check ((Invoke-Api '/api/state' -Token '').error -eq 'bad token') 'no token gets nothing'

    # Answers
    $state = Invoke-Api '/api/state'
    Check ($state.ok -and $state.version -match '^\d+\.\d+\.\d+$') 'state: the app version' ($state | ConvertTo-Json -Compress)
    Check ($state.PSObject.Properties.Name -contains 'settings' -and $state.PSObject.Properties.Name -contains 'configured') 'state: settings and whether a connection is set up'
    $catalog = Invoke-Api '/api/catalog'
    Check ($catalog.ok -and $catalog.PSObject.Properties.Name -contains 'apps') 'catalog: a list (empty or not)' ($catalog | ConvertTo-Json -Compress -Depth 4)
    $choice = Invoke-Api '/api/permission-choice'
    Check ($choice.ok -and @($choice.required.name) -contains 'DeviceManagementApps.ReadWrite.All') 'permission choice: the required permissions'
    Check ((Invoke-Api '/api/open' @{ target = 'calc.exe' }).ok -eq $false) 'open: only its fixed targets'
    Check ((Invoke-Api '/api/job-start' @{ mode = 'Anything'; tenantId = 'x'; clientId = 'y' }).ok -eq $false) 'job-start: only the known actions'
    Check ((Invoke-Api '/api/no-such-thing').error -eq 'unknown') 'an unknown route says so'
    $log = Invoke-Api '/api/log' @{ from = 0 }
    Check ($log.ok -and (@($log.lines.Text) -join "`n") -like '*Web interface started*') 'log: the server''s own lines for the Activity box'

    # Quit stops it
    [void](Invoke-Api '/api/quit')
    Check ($proc.WaitForExit(15000)) 'quit stops the server'
}
finally {
    if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -eq 0) { Write-Host "PASSED: $passed check(s)." -ForegroundColor Green; exit 0 }
Write-Host "FAILED: $($failures.Count) of $($passed + $failures.Count)." -ForegroundColor Red
exit 1
