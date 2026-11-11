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
# A settings file as the classic window leaves it, with column widths and a
# window position - saving from the web must keep both (it used to wipe them).
$settingsPath = Join-Path $repoRoot "data\intune-deployment-settings.json"
$settingsBackup = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw } else { $null }
[void](New-Item -ItemType Directory -Path (Split-Path $settingsPath -Parent) -Force)
Set-Content -LiteralPath $settingsPath -Value '{ "GridColumnWidths": { "AppName": 31 }, "WindowPlacement": { "X": 10, "Y": 20, "Width": 900, "Height": 700, "Maximized": false } }' -Encoding UTF8

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

    # The app editor: add, rename, refuse a clash, remove - in the catalog
    # folder of this checkout (data\ is git-ignored, so nothing real is touched).
    $testName = 'Web Test App ' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $added = Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $testName; wingetId = 'Vendor.WebTest'; appId = ''; requiredFor = @('SG-A', 'SG-A', ' '); availableFor = @(); uninstallFor = @(); excludeFor = @(); metadata = @{ description = 'from the test' } } }
    Check ($added.ok -and $added.name -eq $testName) 'editor: a new app is saved' ($added | ConvertTo-Json -Compress)
    $got = Invoke-Api '/api/app-get' @{ name = $testName }
    Check ($got.ok -and $got.app.wingetId -eq 'Vendor.WebTest' -and @($got.app.requiredFor).Count -eq 1) 'editor: it reads back, groups cleaned (blank and duplicate dropped)' ($got | ConvertTo-Json -Compress -Depth 5)
    Check ($got.app.metadata.description -eq 'from the test' -and $got.app.hasMetadata) 'editor: metadata created from the defaults plus what was typed'
    $bad = Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $testName; wingetId = ''; appId = '' } }
    Check (-not $bad.ok -and $bad.error -like '*already called*') 'editor: a second app with the same name is refused' ($bad | ConvertTo-Json -Compress)
    $badId = Invoke-Api '/api/app-save' @{ originalName = $testName; app = @{ appName = $testName; wingetId = 'Vendor.WebTest'; appId = '../../groups/x' } }
    Check (-not $badId.ok -and $badId.error -like '*GUID*') 'editor: an App ID that is not a GUID is refused'
    $badWinget = Invoke-Api '/api/app-save' @{ originalName = $testName; app = @{ appName = $testName; wingetId = 'Foo$(calc)'; appId = '' } }
    Check (-not $badWinget.ok -and $badWinget.error -like '*Winget ID*') 'editor: a Winget ID winget would not accept is refused'
    $renamed = Invoke-Api '/api/app-save' @{ originalName = $testName; app = @{ appName = "$testName renamed"; wingetId = 'Vendor.WebTest'; appId = ''; requiredFor = @('SG-A'); metadata = @{ description = 'from the test' } } }
    $names = @((Invoke-Api '/api/catalog').apps.name)
    Check ($renamed.ok -and $names -contains "$testName renamed" -and $names -notcontains $testName) 'editor: a rename replaces the old file' ($names -join ', ')
    # Deploy, push and checks without a connection set up (CI has none): clear answers, nothing started.
    $plan = Invoke-Api '/api/deploy-plan' @{ names = @("$testName renamed") }
    Check (-not $plan.ok -and $plan.error -like '*connection*') 'deploy plan: says the connection is missing' ($plan | ConvertTo-Json -Compress)
    $push = Invoke-Api '/api/push-start' @{ names = @("$testName renamed"); mode = 'Preview' }
    Check (-not $push.ok -and $push.error -like '*App ID*') 'push groups: nothing to push for an app not in Intune' ($push | ConvertTo-Json -Compress)
    $checks = Invoke-Api '/api/checks-run'
    Check ($checks.ok -and (@($checks.notes) -join ' ') -like '*not checked*') 'checks: run locally, and say Intune was not checked' ($checks | ConvertTo-Json -Compress -Depth 4)
    $fixBad = Invoke-Api '/api/checks-fix' @{ action = 'SetAppId'; catalogName = "$testName renamed"; value = 'not-a-guid' }
    Check (-not $fixBad.ok) 'checks fix: an App ID that is not a GUID is refused'
    $fixOk = Invoke-Api '/api/checks-fix' @{ action = 'SetAppId'; catalogName = "$testName renamed"; value = 'c0ffee00-1111-4222-8333-444455556666' }
    $linked = Invoke-Api '/api/app-get' @{ name = "$testName renamed" }
    Check ($fixOk.ok -and $linked.app.appId -eq 'c0ffee00-1111-4222-8333-444455556666') 'checks fix: Set App ID saves it to the catalog' ($fixOk | ConvertTo-Json -Compress)
    $fixClear = Invoke-Api '/api/checks-fix' @{ action = 'ClearAppId'; catalogName = "$testName renamed" }
    Check ($fixClear.ok -and -not (Invoke-Api '/api/app-get' @{ name = "$testName renamed" }).app.appId) 'checks fix: Clear App ID'

    # 3a: packaging, settings pages, clear App ID, pull/delete/status without Intune
    $pk = Invoke-Api '/api/packaging'
    Check ($pk.ok -and $pk.PSObject.Properties.Name -contains 'toolFound' -and $pk.PSObject.Properties.Name -contains 'sharedFound') 'packaging: says whether the tool and shared package are there'
    $pkgWinget = Invoke-Api '/api/package-start' @{ names = @("$testName renamed") }
    Check (-not $pkgWinget.ok -and $pkgWinget.error -like '*Winget*') 'package: a Winget app has nothing of its own to package' ($pkgWinget | ConvertTo-Json -Compress)
    $prefs = Invoke-Api '/api/prefs'
    Check ($prefs.ok -and @($prefs.folders.key) -contains 'Catalog' -and $prefs.defaults.installContext) 'prefs: checks, folders and default values'
    $badDefaults = Invoke-Api '/api/prefs-save' @{ defaults = @{ architecture = @(); installContext = 'System'; minOSKey = 'W10_22H2'; minDiskSpaceMB = '0'; minMemoryMB = '0'; minProcessors = '0'; minCpuSpeedMHz = '0'; installTimeMinutes = '60'; deviceRestartBehavior = 'allow'; returnCodes = @(@{ returnCode = '0'; type = 'success' }) } }
    Check (-not $badDefaults.ok -and $badDefaults.error -like '*architecture*') 'prefs: default values without an architecture are refused'
    $goodDefaults = Invoke-Api '/api/prefs-save' @{ checks = @{ pushGroupsOnCreate = $false; pushGroupsOnUpdate = $true }; defaults = @{ architecture = @('x64', 'arm64'); installContext = 'User'; minOSKey = 'W11_22H2'; minDiskSpaceMB = '10'; minMemoryMB = '0'; minProcessors = '0'; minCpuSpeedMHz = '0'; installTimeMinutes = '61'; deviceRestartBehavior = 'suppress'; allowAvailableUninstall = $true; returnCodes = @(@{ returnCode = '0'; type = 'success' }, @{ returnCode = '3010'; type = 'softReboot' }); defaultDependencyAppNames = @('A', 'A'); wingetInstallMethod = 'Winget' }; favoriteGroups = @('SG-1', ' SG-1 ', 'SG-2') }
    Check ($goodDefaults.ok -and $goodDefaults.defaults.installTimeMinutes -eq 60 -and (@($goodDefaults.defaults.architecture) -join ',') -eq 'x64,arm64' -and $goodDefaults.defaults.wingetInstallMethod -eq 'Winget') 'prefs: default values saved, install time snapped to Intune''s 5-minute steps' ($goodDefaults.defaults | ConvertTo-Json -Compress)
    Check ($goodDefaults.checks.pushGroupsOnUpdate -and -not $goodDefaults.checks.pushGroupsOnCreate -and @($goodDefaults.favoriteGroups).Count -eq 2) 'prefs: switches and favourites saved (duplicates dropped)'
    $saved = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    Check ($saved.GridColumnWidths.AppName -eq 31 -and $saved.WindowPlacement.Width -eq 900) 'settings: saving from the web keeps the classic window''s column widths and position' (Get-Content -LiteralPath $settingsPath -Raw)
    [void](Invoke-Api '/api/checks-fix' @{ action = 'SetAppId'; catalogName = "$testName renamed"; value = 'c0ffee00-1111-4222-8333-444455556666' })
    $cleared = Invoke-Api '/api/clear-appid' @{ name = "$testName renamed" }
    Check ($cleared.ok -and -not (Invoke-Api '/api/app-get' @{ name = "$testName renamed" }).app.appId) 'clear App ID: the catalog forgets the Intune link'
    Check (-not (Invoke-Api '/api/pull-start' @{ names = @("$testName renamed") }).ok) 'pull: nothing to pull for an app not in Intune'
    Check (-not (Invoke-Api '/api/delete-intune' @{ name = "$testName renamed" }).ok) 'delete from Intune: refused for an app not in Intune'
    Check (-not (Invoke-Api '/api/install-status' @{ name = "$testName renamed" }).ok) 'install status: refused for an app not in Intune'

    $removed = Invoke-Api '/api/app-remove' @{ name = "$testName renamed" }
    Check ($removed.ok -and @((Invoke-Api '/api/catalog').apps.name) -notcontains "$testName renamed") 'editor: remove takes it out of the catalog'

    # Quit stops it
    [void](Invoke-Api '/api/quit')
    Check ($proc.WaitForExit(15000)) 'quit stops the server'
}
finally {
    if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
    if ($null -ne $settingsBackup) { Set-Content -LiteralPath $settingsPath -Value $settingsBackup -Encoding UTF8 } else { Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -eq 0) { Write-Host "PASSED: $passed check(s)." -ForegroundColor Green; exit 0 }
Write-Host "FAILED: $($failures.Count) of $($passed + $failures.Count)." -ForegroundColor Red
exit 1
