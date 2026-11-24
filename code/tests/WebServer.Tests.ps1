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
# A settings file with a folder chosen earlier - saving other settings from
# the web must keep it (a save once wrote back only what it knew about).
$settingsPath = Join-Path $repoRoot "data\intune-deployment-settings.json"
$settingsBackup = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw } else { $null }
[void](New-Item -ItemType Directory -Path (Split-Path $settingsPath -Parent) -Force)
$seedLogs = Join-Path ([IO.Path]::GetTempPath()) ("webtest-logs-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
[void](New-Item -ItemType Directory -Path $seedLogs -Force)
Set-Content -LiteralPath $settingsPath -Value (@{ Folders = @{ Logs = $seedLogs } } | ConvertTo-Json -Compress) -Encoding UTF8

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
        $r = Invoke-Raw -Method POST -Path $Path -ContentType 'application/json' -Body ($Data | ConvertTo-Json -Compress -Depth 10)
        return ($r.Body | ConvertFrom-Json)
    }

    # The page and its files
    $page = Invoke-Raw -Path '/'
    Check ($page.Status -eq 200 -and $page.Body -like '*<script src="app.js"*') 'the page is served'
    Check ($page.Headers -match 'Content-Security-Policy: default-src ''self''' -and $page.Headers -match 'X-Frame-Options: DENY' -and $page.Headers -match 'Cache-Control: no-store') 'every response carries the security headers' $page.Headers
    Check ($page.Body -notmatch '<script>[^<]') 'no inline script (the CSP allows none)'
    foreach ($js in 'core.js', 'apps.js', 'tools.js', 'checks.js', 'groups.js', 'updates.js', 'add.js', 'convenience.js', 'guide.js', 'windows.js', 'blocks.js', 'chips.js', 'scripts.js', 'settings.js', 'app.js') {
        Check ((Invoke-Raw -Path "/$js").Status -eq 200 -and $page.Body -like "*<script src=`"$js`" defer>*") "$js is served and loaded by the page"
    }
    Check ((Invoke-Raw -Path '/app.css').Status -eq 200) 'app.css is served'
    Check ((Invoke-Raw -Path '/../IntuneDeployment.ps1').Status -eq 404) 'nothing outside the fixed file list'
    Check ((Invoke-Raw -Path '/code/Web/WebApi.ps1').Status -eq 404) 'not even the app''s own files'

    # Refusals
    Check ((Invoke-Raw -Path '/' -HostHeader 'evil.example:80').Status -eq 403) 'a foreign Host is refused (DNS rebinding)'
    Check ((Invoke-Raw -Method POST -Path '/api/state' -ContentType 'application/json' -Origin 'https://evil.example' -Body "{`"token`":`"$token`"}").Status -eq 403) 'a foreign Origin is refused'
    Check ((Invoke-Raw -Method POST -Path '/api/state' -ContentType 'text/plain' -Body "{`"token`":`"$token`"}").Status -eq 403) 'an API call that is not JSON is refused (a cross-site form can''t send JSON)'
    Check ((Invoke-Raw -Method GET -Path '/api/state').Status -eq 403) 'an API GET is refused'
    Check ((Invoke-Api '/api/state' -Token ('0' * 32)).error -eq 'bad token') 'a wrong token gets nothing'
    # Headers that never end: refused once they pass 64 KB, and the server goes on.
    $port0 = [int]($url -replace '.*:(\d+)$', '$1')
    $flood = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $port0)
    try {
        $junk = [Text.Encoding]::ASCII.GetBytes("GET / HTTP/1.1`r`nHost: 127.0.0.1:$port0`r`nX-Pad: " + ('a' * 70000))
        $fs = $flood.GetStream(); $fs.Write($junk, 0, $junk.Length); $fs.Flush(); $fs.ReadTimeout = 15000
        $floodAnswer = (New-Object System.IO.StreamReader($fs)).ReadToEnd()
    }
    catch { $floodAnswer = '' }
    finally { $flood.Close() }
    Check ($floodAnswer -notmatch '200 OK') 'headers over 64 KB are not answered' ($floodAnswer.Substring(0, [Math]::Min(80, $floodAnswer.Length)))
    Check ((Invoke-Raw -Path '/').Status -eq 200) '... and the server still answers afterwards'
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
    $folderOpen = Invoke-Api '/api/open' @{ target = 'scripts-folder' }
    Check (($folderOpen.ok -and $folderOpen.path) -or (-not $folderOpen.ok -and $folderOpen.error -like '*Explorer*')) 'open: a folder button answers with the folder it opened, or why it could not - never silence' ($folderOpen | ConvertTo-Json -Compress)
    Check ((Invoke-Api '/api/job-start' @{ mode = 'Anything'; tenantId = 'x'; clientId = 'y' }).ok -eq $false) 'job-start: only the known actions'
    Check ((Invoke-Api '/api/no-such-thing').error -eq 'unknown') 'an unknown route says so'
    $conn = Invoke-Api '/api/connection-status'
    Check ($conn.ok -and $conn.state -eq 'none' -and $conn.text -eq 'Not connected') 'connection status: nothing set up says Not connected (the badge), without trying Graph' ($conn | ConvertTo-Json -Compress)
    $jobs = Invoke-Api '/api/jobs'
    Check ($jobs.ok -and @($jobs.jobs).Count -eq 0) 'jobs: none running at start (a reloaded page asks for these)' ($jobs | ConvertTo-Json -Compress)
    # Platform scripts - the local copies (no tenant in CI)
    $scriptName = "Web test script $([guid]::NewGuid().ToString('N').Substring(0, 6))"
    $scriptForm = @{ id = ''; displayName = $scriptName; description = 'from the test'; fileName = ''; runAsAccount = 'system'; runAs32Bit = $false; enforceSignatureCheck = $false
        scriptContent = "Write-Output 'hello'`r`nexit 0"; groups = @('SG-A', 'SG-A', ' ') }
    $emptyScript = Invoke-Api '/api/script-save' @{ destination = 'Local'; originalName = ''; script = @{ displayName = $scriptName; scriptContent = '  '; runAsAccount = 'system' } }
    Check (-not $emptyScript.ok -and $emptyScript.error -like '*empty*') 'scripts: an empty script is refused' ($emptyScript | ConvertTo-Json -Compress)
    $badRunAs = Invoke-Api '/api/script-save' @{ destination = 'Local'; originalName = ''; script = @{ displayName = $scriptName; scriptContent = 'x'; runAsAccount = 'admin' } }
    Check (-not $badRunAs.ok) 'scripts: an unknown run-as account is refused'
    $savedScript = Invoke-Api '/api/script-save' @{ destination = 'Local'; originalName = ''; script = $scriptForm }
    Check ($savedScript.ok -and $savedScript.local) 'scripts: saved locally' ($savedScript | ConvertTo-Json -Compress)
    $listed = Invoke-Api '/api/scripts'
    $row = @($listed.rows) | Where-Object { $_.displayName -eq $scriptName }
    Check ($listed.ok -and -not $listed.tenantRead -and $listed.tenantError -and $row -and $row.local -eq 'Local copy' -and $row.fileName -eq (($scriptName -replace ' ', '-') + '.ps1')) 'scripts: listed as a local copy, file name made from the name, and says Intune was not read' ($listed | ConvertTo-Json -Compress -Depth 4)
    $detail = Invoke-Api '/api/script-get' @{ name = $scriptName }
    Check ($detail.ok -and $detail.script.scriptContent -eq "Write-Output 'hello'`nexit 0" -and @($detail.script.groups).Count -eq 1) 'scripts: reads back (line endings normalised, groups cleaned)' ($detail | ConvertTo-Json -Compress -Depth 4)
    $form2 = $scriptForm.Clone(); $form2.displayName = "$scriptName 2"
    $renamedScript = Invoke-Api '/api/script-save' @{ destination = 'Local'; originalName = $scriptName; script = $form2 }
    $names2 = @((Invoke-Api '/api/scripts').rows.displayName)
    Check ($renamedScript.ok -and $names2 -contains "$scriptName 2" -and $names2 -notcontains $scriptName) 'scripts: a rename replaces the old local file' ($names2 -join ', ')
    Check (-not (Invoke-Api '/api/script-save' @{ destination = 'Intune'; originalName = "$scriptName 2"; script = $scriptForm }).ok) 'scripts: Save to Intune refused without a connection'
    Check (@((Invoke-Api '/api/scripts').rows.displayName) -contains "$scriptName 2") 'scripts: ... and the refused save left the local copy as it was'
    Check (-not (Invoke-Api '/api/script-get' @{ id = '../../users' }).ok) 'scripts: an id that is not a GUID is refused'
    Check (-not (Invoke-Api '/api/script-runstatus' @{ id = '' }).ok) 'scripts: no run status for a script not in Intune'
    $delScript = Invoke-Api '/api/script-delete' @{ name = "$scriptName 2" }
    Check ($delScript.ok -and @((Invoke-Api '/api/scripts').rows.displayName) -notcontains "$scriptName 2") 'scripts: the local copy is deleted'
    Check (-not (Invoke-Api '/api/script-delete' @{ name = "$scriptName 2" }).ok) 'scripts: deleting it again says there is none'
    # 3d: setup and help
    $dg = Invoke-Api '/api/diagnostics'
    Check ($dg.ok -and @($dg.sections).Count -eq 3 -and @($dg.sections[1].lines).Count -ge 7) 'diagnostics: this machine, the catalog and Intune' ($dg | ConvertTo-Json -Compress -Depth 6)
    Check ((@($dg.sections[2].lines.text) -join ' ') -like '*Skipped*') 'diagnostics: Intune is skipped without a connection'
    $pq = Invoke-Api '/api/prereqs'
    Check ($pq.ok -and @($pq.rows).Count -ge 1 -and $pq.module -eq 'Microsoft.Graph.Authentication') 'prerequisites: the module in each PowerShell' ($pq | ConvertTo-Json -Compress -Depth 4)
    Check (-not (Invoke-Api '/api/prereq-install' @{ exe = 'C:\Windows\System32\calc.exe' }).ok) 'prerequisites: installs only into a PowerShell it listed as missing the module'
    Check ((Invoke-Api '/api/certs-all').ok) 'certificates: the list on this machine (empty where there is no certificate store)'
    $usable = Invoke-Api '/api/certs-local'
    Check ($usable.ok -and $usable.PSObject.Properties.Name -contains 'expired' -and $usable.PSObject.Properties.Name -contains 'noKey') 'certificates: the picker says how many it left out, and why' ($usable | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/cert-delete-local' @{ thumbprint = '..\..\x'; store = 'CurrentUser' }).ok) 'certificates: a thumbprint that is not one is refused'
    Check (-not (Invoke-Api '/api/cert-delete-local' @{ thumbprint = ('A' * 40); store = 'Root' }).ok) 'certificates: only the two personal stores'
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
    $row = @((Invoke-Api '/api/catalog').apps | Where-Object { $_.name -eq $testName })[0]
    Check ($row -and @($row.requiredFor) -contains 'SG-A' -and $row.PSObject.Properties.Name -contains 'excludeFor') 'apps list: each app''s groups per role (Remove groups offers them)' ($row | ConvertTo-Json -Compress -Depth 3)
    Check ($got.version -match '^[0-9A-F]{64}$') 'editor: the app comes with a fingerprint of its file' ([string]$got.version)
    # Something else (a deploy saving its App ID) changes the file while the editor is open.
    $changedId = '11111111-2222-3333-4444-555555555555'
    $fix = Invoke-Api '/api/checks-fix' @{ catalogName = $testName; action = 'SetAppId'; value = $changedId }
    Check ($fix.ok) 'editor: the file changes while the editor is open' ($fix | ConvertTo-Json -Compress)
    $stale = Invoke-Api '/api/app-save' @{ originalName = $testName; version = $got.version; app = @{ appName = $testName; wingetId = 'Vendor.WebTest'; appId = ''; requiredFor = @('SG-A'); metadata = @{ description = 'from the test' } } }
    Check (-not $stale.ok -and $stale.stale -and $stale.error -like '*changed since you opened it*') 'editor: a save from before that change is refused' ($stale | ConvertTo-Json -Compress)
    $kept = Invoke-Api '/api/app-get' @{ name = $testName }
    Check ($kept.app.appId -eq $changedId -and $kept.version -ne $got.version) 'editor: ... and the App ID saved meanwhile is kept' ($kept.app | ConvertTo-Json -Compress -Depth 3)
    $fresh = Invoke-Api '/api/app-save' @{ originalName = $testName; version = $kept.version; app = @{ appName = $testName; wingetId = 'Vendor.WebTest'; appId = ''; requiredFor = @('SG-A'); metadata = @{ description = 'from the test' } } }
    Check ($fresh.ok) 'editor: a save from the current file goes through' ($fresh | ConvertTo-Json -Compress)
    # Ten saves of one app at the same time: each completes, the file stays valid JSON.
    # Runspaces rather than Start-ThreadJob, which Windows PowerShell 5.1 doesn't have.
    $port = [int]($url -replace '.*:(\d+)$', '$1')
    $send = {
        param($port, $body)
        $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $port)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($body)
            $head = [Text.Encoding]::ASCII.GetBytes("POST /api/checks-fix HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
            $stream = $client.GetStream(); $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
            $text = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
            $text.Substring($text.IndexOf("`r`n`r`n") + 4) | ConvertFrom-Json
        }
        finally { $client.Close() }
    }
    $pool = [runspacefactory]::CreateRunspacePool(1, 10); $pool.Open()
    $running = foreach ($n in 1..10) {
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        $body = @{ token = $token; catalogName = $testName; action = 'SetWingetId'; value = "Vendor.WebTest$n" } | ConvertTo-Json -Compress
        [void]$ps.AddScript($send).AddArgument($port).AddArgument($body)
        @{ PS = $ps; Handle = $ps.BeginInvoke() }
    }
    $answers = foreach ($r in $running) { try { $r.PS.EndInvoke($r.Handle) } finally { $r.PS.Dispose() } }
    $pool.Close()
    $after = Invoke-Api '/api/app-get' @{ name = $testName }
    Check (@($answers | Where-Object { $_.ok }).Count -eq 10 -and $after.ok -and $after.app.wingetId -match '^Vendor\.WebTest\d+$') 'editor: ten changes at once all go through, one after another' ("$(@($answers | ConvertTo-Json -Compress)) / $($after.app.wingetId)")
    [void](Invoke-Api '/api/app-save' @{ originalName = $testName; app = @{ appName = $testName; wingetId = 'Vendor.WebTest'; appId = ''; requiredFor = @('SG-A'); metadata = @{ description = 'from the test' } } })
    # Earlier versions: every save above kept a copy; one goes back.
    $hist = Invoke-Api '/api/app-backups' @{ name = $testName }
    $older = @($hist.backups | Where-Object { @($_.changed).Count -gt 0 }) | Select-Object -First 1
    Check ($hist.ok -and @($hist.backups).Count -ge 1 -and $older) 'history: earlier versions of the app are listed, with what differs' ($hist | ConvertTo-Json -Compress -Depth 4)
    if ($older) {
        $before = (Invoke-Api '/api/app-get' @{ name = $testName }).app
        $restored = Invoke-Api '/api/app-restore' @{ name = $testName; id = $older.id }
        $afterRestore = (Invoke-Api '/api/app-get' @{ name = $testName }).app
        Check ($restored.ok -and ($afterRestore | ConvertTo-Json -Compress -Depth 6) -ne ($before | ConvertTo-Json -Compress -Depth 6)) 'history: a restore puts that version back' ($restored | ConvertTo-Json -Compress)
        $hist2 = Invoke-Api '/api/app-backups' @{ name = $testName }
        Check (@($hist2.backups).Count -gt @($hist.backups).Count) 'history: ... and keeps the version before the restore as a copy too'
        # A copy changed in the Backups folder (a share others may write to) isn't taken back; one the catalog recorded is.
        Check (@($hist2.backups | Where-Object { $_.verified }).Count -ge 1) 'backups: copies this app wrote are recorded by the catalog (verified)'
        $bkf = @((Invoke-Api '/api/prefs').folders | Where-Object { $_.key -eq 'Backups' })[0]
        $bkRoot = if ($bkf.chosen) { $bkf.chosen } else { $bkf.default }
        $victim = $hist2.backups[0]
        $victimPath = Join-Path $bkRoot ($victim.id -replace '/', [IO.Path]::DirectorySeparatorChar)
        Add-Content -LiteralPath $victimPath -Value ' '
        $tampered = Invoke-Api '/api/app-restore' @{ name = $testName; id = $victim.id }
        Check (-not $tampered.ok -and $tampered.error -like '*changed in the Backups folder*') 'backups: a copy changed in the Backups folder is not restored' ($tampered | ConvertTo-Json -Compress)
        Check (Test-Path -LiteralPath (Join-Path (Invoke-Api '/api/catalog').path '.integrity')) 'history: kept next to the catalog (.integrity), not in the Backups folder'
    }
    Check (-not (Invoke-Api '/api/app-restore' @{ name = $testName; id = '../../settings.json' }).ok) 'history: an id that is not a backup is refused'
    Check (-not (Invoke-Api '/api/app-restore' @{ name = $testName; id = 'app-edit_2020-01-01/000000_Other-App.json' }).ok) 'history: a backup of another app is refused'
    [void](Invoke-Api '/api/app-save' @{ originalName = $testName; app = @{ appName = $testName; wingetId = 'Vendor.WebTest'; appId = ''; requiredFor = @('SG-A'); metadata = @{ description = 'from the test' } } })
    $bad = Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $testName; wingetId = ''; appId = '' } }
    Check (-not $bad.ok -and $bad.error -like '*already called*') 'editor: a second app with the same name is refused' ($bad | ConvertTo-Json -Compress)
    $badId = Invoke-Api '/api/app-save' @{ originalName = $testName; app = @{ appName = $testName; wingetId = 'Vendor.WebTest'; appId = '../../groups/x' } }
    Check (-not $badId.ok -and $badId.error -like '*GUID*') 'editor: an App ID that is not a GUID is refused'
    $badWinget = Invoke-Api '/api/app-save' @{ originalName = $testName; app = @{ appName = $testName; wingetId = 'Foo$(calc)'; appId = '' } }
    Check (-not $badWinget.ok -and $badWinget.error -like '*Winget ID*') 'editor: a Winget ID winget would not accept is refused'
    $renamed = Invoke-Api '/api/app-save' @{ originalName = $testName; app = @{ appName = "$testName renamed"; wingetId = 'Vendor.WebTest'; appId = ''; requiredFor = @('SG-A'); metadata = @{ description = 'from the test' } } }
    $names = @((Invoke-Api '/api/catalog').apps.name)
    Check ($renamed.ok -and $names -contains "$testName renamed" -and $names -notcontains $testName) 'editor: a rename replaces the old file' ($names -join ', ')
    $rn = "$testName renamed"
    $deployBase = @{ architecture = @('x64'); installContext = 'User'; minOSKey = 'W10_22H2'; installTimeMinutes = '60'; deviceRestartBehavior = 'basedOnReturnCode'
        minDiskSpaceMB = '0'; minMemoryMB = '0'; minProcessors = '0'; minCpuSpeedMHz = '0'; allowAvailableUninstall = $true
        returnCodes = @(@{ returnCode = '0'; type = 'success' }, @{ returnCode = '3010'; type = 'softReboot' }); dependencies = @() }
    function New-DeployEdit($Deploy) { @{ originalName = $rn; app = @{ appName = $rn; wingetId = 'Vendor.WebTest'; appId = ''; requiredFor = @('SG-A'); metadata = @{ description = 'from the test' }; deploy = $Deploy } } }
    $d = $deployBase.Clone(); $d.detection = @{ type = 'Registry'; keyPath = ' '; detectionType = 'exists'; operator = 'notConfigured' }
    $noKey = Invoke-Api '/api/app-save' (New-DeployEdit $d)
    Check (-not $noKey.ok -and $noKey.error -like '*key path*') 'deploy settings: a registry rule without a key path is refused' ($noKey | ConvertTo-Json -Compress)
    $d = $deployBase.Clone(); $d.detection = @{ type = '' }; $d.dependencies = @($rn)
    $selfDep = Invoke-Api '/api/app-save' (New-DeployEdit $d)
    Check (-not $selfDep.ok -and $selfDep.error -like '*itself*') 'deploy settings: an app depending on itself is refused' ($selfDep | ConvertTo-Json -Compress)
    $d = $deployBase.Clone(); $d.detection = @{ type = '' }; $d.dependencies = @('No Such App')
    $badDep = Invoke-Api '/api/app-save' (New-DeployEdit $d)
    Check (-not $badDep.ok -and $badDep.error -like '*catalog*') 'deploy settings: a dependency that is not in the catalog is refused'
    $d = $deployBase.Clone(); $d.detection = @{ type = 'File'; path = 'C:\Program Files\Vendor'; name = 'app.exe'; detectionType = 'version'; operator = 'greaterThanOrEqual'; value = '1.2'; check32Bit = $false }
    $okDeploy = Invoke-Api '/api/app-save' (New-DeployEdit $d)
    $back = (Invoke-Api '/api/app-get' @{ name = $rn }).app.deploy
    Check ($okDeploy.ok -and $back.detection.type -eq 'File' -and $back.detection.name -eq 'app.exe' -and $back.detection.operator -eq 'greaterThanOrEqual') 'deploy settings: a file detection rule is saved and reads back' ($back | ConvertTo-Json -Compress -Depth 5)
    Check ($back.installContext -eq 'User' -and @($back.returnCodes).Count -eq 2 -and (@($back.returnCodes | Where-Object { $_.returnCode -eq 3010 }).type -eq 'softReboot')) 'deploy settings: install context and return codes saved' ($back | ConvertTo-Json -Compress -Depth 5)
    $keep = Invoke-Api '/api/app-save' @{ originalName = $rn; app = @{ appName = $rn; wingetId = 'Vendor.WebTest'; appId = ''; requiredFor = @('SG-A'); metadata = @{ description = 'changed' } } }
    Check ($keep.ok -and (Invoke-Api '/api/app-get' @{ name = $rn }).app.deploy.detection.type -eq 'File') 'deploy settings: a save without them keeps them'
    # Supersedence through the editor
    # (with the file detection rule saved above - later tests expect it kept)
    $d = $deployBase.Clone(); $d.detection = @{ type = 'File'; path = 'C:\Program Files\Vendor'; name = 'app.exe'; detectionType = 'version'; operator = 'greaterThanOrEqual'; value = '1.2'; check32Bit = $false }
    $d.supersedesSet = $true; $d.supersedes = @(@{ appId = 'not-a-guid'; type = 'update' })
    $badSup = Invoke-Api '/api/app-save' (New-DeployEdit $d)
    Check (-not $badSup.ok -and $badSup.error -like '*GUID*') 'supersedence: an App ID that is not a GUID is refused' ($badSup | ConvertTo-Json -Compress)
    $d.supersedes = @(@{ appId = '0b0b0b0b-1111-4222-8333-444455556666'; name = 'Old Tool'; type = 'replace' })
    $okSup = Invoke-Api '/api/app-save' (New-DeployEdit $d)
    $supBack = (Invoke-Api '/api/app-get' @{ name = $rn }).app.deploy
    Check ($okSup.ok -and $supBack.supersedesSet -and @($supBack.supersedes).Count -eq 1 -and @($supBack.supersedes)[0].type -eq 'replace' -and @($supBack.supersedes)[0].name -eq 'Old Tool') 'supersedence: saved and read back' ($supBack | ConvertTo-Json -Compress -Depth 5)
    $d.supersedesSet = $false
    $offSup = Invoke-Api '/api/app-save' (New-DeployEdit $d)
    Check ($offSup.ok -and -not (Invoke-Api '/api/app-get' @{ name = $rn }).app.deploy.supersedesSet) 'supersedence: unticked leaves Intune''s alone (nothing recorded)'
    # The app's icon
    $png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='
    $iconEdit = { param($change, $icon) @{ originalName = $rn; app = @{ appName = $rn; wingetId = 'Vendor.WebTest'; appId = ''; requiredFor = @('SG-A'); metadata = @{ description = 'from the test' }; iconChange = $change; icon = $icon } } }
    $badIcon = Invoke-Api '/api/app-save' (& $iconEdit 'set' @{ type = 'image/svg+xml'; value = $png })
    Check (-not $badIcon.ok -and $badIcon.error -like '*PNG*') 'icon: only PNG or JPEG' ($badIcon | ConvertTo-Json -Compress)
    $setIcon = Invoke-Api '/api/app-save' (& $iconEdit 'set' @{ type = 'image/png'; value = $png })
    $icons = Invoke-Api '/api/app-icons' @{ names = @($rn) }
    $row = @((Invoke-Api '/api/catalog').apps) | Where-Object { $_.name -eq $rn }
    Check ($setIcon.ok -and (Invoke-Api '/api/app-get' @{ name = $rn }).app.icon.value -eq $png -and $icons.icons.$rn -like 'data:image/png;base64,*' -and $row.hasIcon) 'icon: saved, read back, listed' ($icons | ConvertTo-Json -Compress)
    [void](Invoke-Api '/api/app-save' (& $iconEdit 'keep' $null))
    Check ((Invoke-Api '/api/app-get' @{ name = $rn }).app.icon.value -eq $png) 'icon: a save that does not touch it keeps it'
    [void](Invoke-Api '/api/app-save' (& $iconEdit 'remove' $null))
    Check ($null -eq (Invoke-Api '/api/app-get' @{ name = $rn }).app.icon) 'icon: removed'
    # History: what one save changed, and that version next to now
    $bks = Invoke-Api '/api/app-backups' @{ name = $rn }
    $cmp = Invoke-Api '/api/app-compare' @{ name = $rn; id = @($bks.backups)[0].id }
    Check ($cmp.ok -and @($cmp.thatSave | Where-Object { $_.field -eq 'icon' }).Count -eq 1) 'history: the newest copy shows the icon removal as what that save changed' ($cmp | ConvertTo-Json -Compress -Depth 4)
    Check (-not (Invoke-Api '/api/app-compare' @{ name = $rn; id = 'app-edit_2000-01-01/000000_nope.json' }).ok) 'history: a copy that is not this app''s is refused'
    # Winget versions: nothing to take before winget was asked
    $tv = Invoke-Api '/api/winget-take-version' @{ names = @($rn) }
    Check ($tv.ok -and @($tv.changed).Count -eq 0 -and @($tv.skipped).Count -eq 1) 'winget version: not taken before winget was asked' ($tv | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/tenant-setup').ok) 'tenant setup: needs a connection'
    Check (-not (Invoke-Api '/api/install-overview').ok) 'install overview: needs a connection'
    Check (-not (Invoke-Api '/api/alert-test').ok) 'alerts: a test needs a webhook or an email first'
    $badRings = Invoke-Api '/api/prefs-save' @{ releaseRingsText = 'Early adopters SG-1' }
    Check (-not $badRings.ok -and $badRings.error -like 'Release rings*Line 1*') 'release rings: a line without "Name:" is refused, saying which' ($badRings | ConvertTo-Json -Compress)
    $badAlert = Invoke-Api '/api/prefs-save' @{ alerts = @{ level = 'always'; webhookUrl = 'http://not-https.example/x' } }
    Check (-not $badAlert.ok -and $badAlert.error -like '*https*') 'alerts: a webhook that is not https is refused' ($badAlert | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/inventory-suggestions').ok) 'apps worth adding: needs a connection'
    $hc0 = Invoke-Api '/api/health'
    Check ($hc0.ok -and @($hc0.checks | Where-Object { $_.level -eq 'failed' -and $_.text -like '*connection*' }).Count -eq 1) 'health: no connection is a problem, said plainly' ($hc0 | ConvertTo-Json -Compress -Depth 4)
    $us = Invoke-Api '/api/unattended-status'
    Check ($us.ok -and -not $us.ready) 'running unattended: not ready without a task and the certificate' ($us | ConvertTo-Json -Compress -Depth 4)
    Check (-not (Invoke-Api '/api/unattended-script' @{}).ok) 'running unattended: no script before the task exists (or off Windows)'
    $tr = Invoke-Api '/api/updates-trend'
    Check ($tr.ok -and @($tr.points).Count -eq 0) 'updates trend: no nightly run yet - no points'
    $uoff = Invoke-Api '/api/updates-overview'
    Check ($uoff.ok -and -not $uoff.connected -and $null -ne $uoff.summary -and @($uoff.rows | Where-Object { $null -ne $_.installed }).Count -eq 0) 'updates page: without a connection, the catalog''s side only - no counts' ($uoff | ConvertTo-Json -Compress -Depth 4)
    # Groups (no tenant in CI): what the catalog uses, and the refusals
    $gl = Invoke-Api '/api/groups'
    $sga = @($gl.groups) | Where-Object { $_.name -eq 'SG-A' }
    Check ($gl.ok -and $sga -and @($sga.uses | Where-Object { $_.app -eq $rn -and $_.role -eq 'Required' }).Count -eq 1) 'groups: the catalog''s groups, with which app uses them and how' ($gl | ConvertTo-Json -Compress -Depth 5)
    Check (-not (Invoke-Api '/api/group-get' @{ name = '' }).ok) 'groups: an empty name is refused'
    $gg = Invoke-Api '/api/group-get' @{ name = 'SG-A' }
    Check (-not $gg.ok -and $gg.error -like '*connection*') 'groups: reading Entra ID says the connection is missing' ($gg | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/directory-search' @{ q = 'a' }).ok) 'groups: a one-letter search is refused'
    Check (-not (Invoke-Api '/api/group-job' @{ mode = 'Save'; name = 'SG-A' }).ok) 'groups: changes refused without a connection'
    # 3c: checks stages, fixes and batch actions (no tenant in CI)
    $cr = Invoke-Api '/api/checks-run' @{ names = @($rn) }
    Check ($cr.ok -and -not $cr.connected -and @($cr.findings | Where-Object { $_.catalogName -and $_.catalogName -ne $rn }).Count -eq 0) 'checks: narrowed to the named apps' ($cr | ConvertTo-Json -Compress -Depth 5)
    Check (-not (Invoke-Api '/api/checks-details' @{ names = @($rn) }).ok) 'checks: the detailed check needs a deployed app and a connection'
    $cw = Invoke-Api '/api/checks-winget' @{ names = @($rn) }
    Check ($cw.ok -or $cw.error -like '*winget*') 'checks: winget is asked, or says it is missing' ($cw | ConvertTo-Json -Compress -Depth 5)
    Check (-not (Invoke-Api '/api/winget-search' @{ q = 'a' }).ok) 'winget search: a one-letter search is refused'
    Check (-not (Invoke-Api '/api/checks-fix' @{ action = 'SetWingetId'; catalogName = $rn; value = 'bad id"; calc' }).ok) 'checks fix: a Winget ID winget would not accept is refused'
    $before = (Invoke-Api '/api/app-get' @{ name = $rn }).app
    $sw = Invoke-Api '/api/checks-fix' @{ action = 'SetWingetId'; catalogName = $rn; value = 'Vendor.WebTestNew' }
    $after = (Invoke-Api '/api/app-get' @{ name = $rn }).app
    Check ($sw.ok -and $after.wingetId -eq 'Vendor.WebTestNew' -and ($before.metadata.installCommand -notlike '*Vendor.WebTest*' -or $after.metadata.installCommand -like '*Vendor.WebTestNew*')) 'checks fix: Set Winget ID, the install command follows' ($after | ConvertTo-Json -Compress -Depth 4)
    Check (-not (Invoke-Api '/api/add-from-intune' @{ apps = @(@{ id = 'nope'; name = 'X' }) }).ok) 'add to catalog: an id that is not a GUID is refused'
    Check (-not (Invoke-Api '/api/deploy-start' @{ name = $rn; metadataOnly = $true }).ok) 'push settings: refused for an app not in Intune'
    Check (-not (Invoke-Api '/api/batch-edit' @{ names = @($rn); changes = @{} }).ok) 'batch edit: nothing ticked is refused'
    Check (-not (Invoke-Api '/api/batch-edit' @{ names = @($rn); changes = @{ appId = 'x' } }).ok) 'batch edit: a field it does not offer is refused'
    Check (-not (Invoke-Api '/api/batch-edit' @{ names = @($rn); changes = @{ dependencies = @('No Such App') } }).ok) 'batch edit: an unknown dependency is refused'
    $be = Invoke-Api '/api/batch-edit' @{ names = @($rn); changes = @{ owner = ' IT Workplace '; installTimeMinutes = '62'; architecture = @('x64', 'arm64'); dependencies = @($rn) } }
    $bm = (Invoke-Api '/api/app-get' @{ name = $rn }).app
    Check ($be.ok -and $bm.metadata.owner -eq 'IT Workplace' -and $bm.deploy.installTimeMinutes -eq 60 -and (@($bm.deploy.architecture) -join ',') -eq 'x64,arm64' -and @($bm.deploy.dependencies).Count -eq 0 -and $bm.deploy.detection.type -eq 'File') 'batch edit: ticked fields changed (time snapped, self-dependency dropped), the rest kept' ($bm | ConvertTo-Json -Compress -Depth 5)
    Check (-not (Invoke-Api '/api/batch-groups' @{ mode = 'add'; names = @($rn); roles = @{} }).ok) 'batch groups: no group is refused'
    $ga = Invoke-Api '/api/batch-groups' @{ mode = 'add'; names = @($rn); roles = @{ availableFor = @('SG-B'); excludeFor = @('SG-X', 'sg-x') } }
    $gm = (Invoke-Api '/api/app-get' @{ name = $rn }).app
    Check ($ga.ok -and @($gm.availableFor) -contains 'SG-B' -and @($gm.excludeFor).Count -eq 1 -and @($gm.requiredFor) -contains 'SG-A') 'batch groups: added (no duplicates), the other lists kept' ($gm | ConvertTo-Json -Compress -Depth 4)
    # [All users] / [All devices] (2.38.4): Intune can't exclude them.
    $gx = Invoke-Api '/api/batch-groups' @{ mode = 'add'; names = @($rn); roles = @{ excludeFor = @('[All users]') } }
    Check (-not $gx.ok -and $gx.error -like "*can't exclude*") 'batch groups: [All users] refused in Excluded' ($gx | ConvertTo-Json -Compress)
    $gxs = Invoke-Api '/api/app-save' @{ originalName = $rn; app = @{ appName = $rn; appId = ''; wingetId = $gm.wingetId; requiredFor = @('SG-A'); excludeFor = @('[all devices]') } }
    Check (-not $gxs.ok -and $gxs.error -like "*can't exclude*") 'app editor: [All devices] refused in Excluded' ($gxs | ConvertTo-Json -Compress)
    # 2.38.12: Available is for users - Intune has no Available for all devices.
    $gav = Invoke-Api '/api/app-save' @{ originalName = $rn; app = @{ appName = $rn; appId = ''; wingetId = $gm.wingetId; requiredFor = @('SG-A'); availableFor = @('[All devices]') } }
    Check (-not $gav.ok -and $gav.error -like "*Available is offered to users*") 'app editor: [All devices] refused in Available' ($gav | ConvertTo-Json -Compress)
    $gr = Invoke-Api '/api/batch-groups' @{ mode = 'remove'; names = @($rn); roles = @{ availableFor = @('sg-b') } }
    Check ($gr.ok -and @((Invoke-Api '/api/app-get' @{ name = $rn }).app.availableFor).Count -eq 0) 'batch groups: removed (case does not matter)'
    # Batch edit preview: says what changes, writes nothing.
    $pv = Invoke-Api '/api/batch-edit' @{ names = @($rn); changes = @{ owner = 'Preview Owner'; publisher = (Invoke-Api '/api/app-get' @{ name = $rn }).app.metadata.publisher }; preview = $true }
    $pvOwner = @($pv.changes | Where-Object { $_.field -eq 'owner' })
    Check ($pv.ok -and $pv.preview -and $pvOwner.Count -eq 1 -and $pvOwner[0].old -eq 'IT Workplace' -and $pvOwner[0].new -eq 'Preview Owner' -and -not @($pv.changes | Where-Object { $_.field -eq 'publisher' }).Count) 'batch edit preview: only the fields that differ, old and new' ($pv | ConvertTo-Json -Compress -Depth 4)
    Check ((Invoke-Api '/api/app-get' @{ name = $rn }).app.metadata.owner -eq 'IT Workplace') 'batch edit preview: nothing written'
    Check (-not (Invoke-Api '/api/batch-edit' @{ names = @($rn); changes = @{ dependencies = @(); dependenciesMode = 'add' } }).ok) 'batch edit: adding no dependencies is refused'
    Check (-not (Invoke-Api '/api/batch-edit' @{ names = @($rn); changes = @{ dependencies = @(); dependenciesMode = 'merge' } }).ok) 'batch edit: an unknown dependencies mode is refused'
    # Replace a group in the catalog, then undo it.
    Check (-not (Invoke-Api '/api/replace-group' @{ old = 'SG-Nobody-Uses'; new = 'SG-New' }).ok) 'replace group: a group no app uses is refused'
    $rp = Invoke-Api '/api/replace-group' @{ old = 'sg-a'; new = 'SG-A2'; names = @($rn) }
    $rpApp = (Invoke-Api '/api/app-get' @{ name = $rn }).app
    Check ($rp.ok -and @($rpApp.requiredFor) -contains 'SG-A2' -and @($rpApp.requiredFor) -notcontains 'SG-A') 'replace group: the app names the new group (old name matched without case)' ($rpApp.requiredFor | ConvertTo-Json -Compress)
    $ui = Invoke-Api '/api/undo-info'
    Check ($ui.ok -and $ui.undo.label -like 'Replace*' -and $ui.undo.count -eq 1) 'undo: the last bulk change is named' ($ui | ConvertTo-Json -Compress -Depth 4)
    $un = Invoke-Api '/api/undo-last'
    Check ($un.ok -and @($un.restored) -contains $rn -and @((Invoke-Api '/api/app-get' @{ name = $rn }).app.requiredFor) -contains 'SG-A') 'undo: the group is back' ($un | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/undo-last').ok) 'undo: only once'
    [void](Invoke-Api '/api/replace-group' @{ old = 'SG-A'; new = 'SG-A3'; names = @($rn) })
    [void](Invoke-Api '/api/batch-groups' @{ mode = 'add'; names = @($rn); roles = @{ uninstallFor = @('SG-Unrelated') } })
    [void](Invoke-Api '/api/replace-group' @{ old = 'SG-A3'; new = 'SG-A'; names = @($rn) })
    $edited = (Invoke-Api '/api/app-get' @{ name = $rn })
    [void](Invoke-Api '/api/app-save' @{ originalName = $rn; version = $edited.version; app = @{ appName = $rn; wingetId = $edited.app.wingetId; appId = ''; requiredFor = @($edited.app.requiredFor); uninstallFor = @(); metadata = @{ description = 'changed after the bulk change' } } })
    $un2 = Invoke-Api '/api/undo-last'
    Check ($un2.ok -and @($un2.skipped).Count -eq 1 -and @((Invoke-Api '/api/app-get' @{ name = $rn }).app.requiredFor) -contains 'SG-A') 'undo: a file changed since is left alone' ($un2 | ConvertTo-Json -Compress)
    # CSV: export, import with a preview, refused rows, apply, undo.
    $ex = Invoke-Api '/api/csv-export'
    Check ($ex.ok -and $ex.text -like '"appName";*' -and $ex.text -like "*`"$rn`"*" -and $ex.text -like '*"requiredFor"*') 'csv export: one row per app, semicolons' (([string]$ex.text).Substring(0, [Math]::Min(300, ([string]$ex.text).Length)))
    $csv = "appName;owner;requiredFor;nonsense`r`n`"$rn`";CSV Owner;SG-A | SG-C;x`r`nNo Such App;x;;`r`n"
    $ip = Invoke-Api '/api/csv-import' @{ text = $csv; preview = $true }
    Check ($ip.ok -and @($ip.changes).Count -eq 2 -and @($ip.notFound) -contains 'No Such App' -and @($ip.ignoredColumns) -contains 'nonsense' -and (Invoke-Api '/api/app-get' @{ name = $rn }).app.metadata.owner -ne 'CSV Owner') 'csv import preview: two changes, unknown app and column named, nothing written' ($ip | ConvertTo-Json -Compress -Depth 4)
    $bad = Invoke-Api '/api/csv-import' @{ text = "appName,installContext`n`"$rn`",Nobody`n"; preview = $true }
    Check ($bad.ok -and @($bad.errors).Count -eq 1) 'csv import: a value the editor would refuse is named (comma file read too)' ($bad | ConvertTo-Json -Compress -Depth 4)
    Check (-not (Invoke-Api '/api/csv-import' @{ text = "appName,installContext`n`"$rn`",Nobody`n" }).ok) 'csv import: refused while a row is wrong'
    Check (-not (Invoke-Api '/api/csv-import' @{ text = "name;owner`nx;y`n"; preview = $true }).ok) 'csv import: a file without appName is refused'
    $ia = Invoke-Api '/api/csv-import' @{ text = $csv }
    $iaApp = (Invoke-Api '/api/app-get' @{ name = $rn }).app
    Check ($ia.ok -and $iaApp.metadata.owner -eq 'CSV Owner' -and @($iaApp.requiredFor) -contains 'SG-C' -and (Invoke-Api '/api/undo-info').undo.label -eq 'CSV import') 'csv import: applied, and can be undone' ($iaApp | ConvertTo-Json -Compress -Depth 4)
    [void](Invoke-Api '/api/undo-last')
    Check (@((Invoke-Api '/api/app-get' @{ name = $rn }).app.requiredFor) -notcontains 'SG-C') 'csv import: undone'
    # A value Excel would run as a formula goes out as text, and comes back unchanged.
    [void](Invoke-Api '/api/batch-edit' @{ names = @($rn); changes = @{ notes = '=HYPERLINK("https://example.invalid","x")' } })
    $fx = Invoke-Api '/api/csv-export'
    Check ($fx.text -like "*`"'=HYPERLINK(*") 'csv export: a formula-like value is written as text (leading '')' (([string]$fx.text) -split "`n" | Where-Object { $_ -like "*$rn*" } | Select-Object -First 1)
    $fxBack = Invoke-Api '/api/csv-import' @{ text = $fx.text; preview = $true }
    Check ($fxBack.ok -and -not @($fxBack.changes | Where-Object { $_.app -eq $rn }).Count) 'csv import: the guarded value reads back as it was - nothing to change' ($fxBack | ConvertTo-Json -Compress -Depth 4)
    [void](Invoke-Api '/api/undo-last')
    $badUrl = Invoke-Api '/api/app-save' @{ originalName = $rn; app = @{ appName = $rn; wingetId = 'Vendor.WebTest'; appId = ''; metadata = @{ informationUrl = 'javascript:alert(1)' } } }
    Check (-not $badUrl.ok -and $badUrl.error -like '*http*') 'editor: a URL that is not http(s) is refused'
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
    $relFolder = Invoke-Api '/api/prefs-save' @{ folders = @{ Logs = 'data\elsewhere' } }
    Check (-not $relFolder.ok -and $relFolder.error -like '*full path*') 'prefs: a relative folder is refused' ($relFolder | ConvertTo-Json -Compress)
    $quoteFolder = Invoke-Api '/api/prefs-save' @{ folders = @{ Logs = 'C:\x" & calc' } }
    Check (-not $quoteFolder.ok -and $quoteFolder.error -like '*quotes*') 'prefs: a folder with a quote is refused' ($quoteFolder | ConvertTo-Json -Compress)
    $badKind = Invoke-Api '/api/prefs-save' @{ folders = @{ Windows = 'C:\Windows' } }
    Check (-not $badKind.ok -and $badKind.error -like '*Unknown folder*') 'prefs: an unknown folder kind is refused, not an error' ($badKind | ConvertTo-Json -Compress)
    $saved = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    Check ($saved.Folders.Logs -eq $seedLogs) 'settings: saving keeps a folder chosen earlier' (Get-Content -LiteralPath $settingsPath -Raw)
    [void](Invoke-Api '/api/checks-fix' @{ action = 'SetAppId'; catalogName = "$testName renamed"; value = 'c0ffee00-1111-4222-8333-444455556666' })
    $cleared = Invoke-Api '/api/clear-appid' @{ name = "$testName renamed" }
    Check ($cleared.ok -and -not (Invoke-Api '/api/app-get' @{ name = "$testName renamed" }).app.appId) 'clear App ID: the catalog forgets the Intune link'
    Check (-not (Invoke-Api '/api/pull-start' @{ names = @("$testName renamed") }).ok) 'pull: nothing to pull for an app not in Intune'
    [void](Invoke-Api '/api/checks-fix' @{ action = 'SetAppId'; catalogName = "$testName renamed"; value = 'c0ffee00-1111-4222-8333-444455556666' })
    $bulk = Invoke-Api '/api/clear-appids' @{ names = @("$testName renamed") }
    Check ($bulk.ok -and @($bulk.cleared).Count -eq 1 -and -not (Invoke-Api '/api/app-get' @{ name = "$testName renamed" }).app.appId) 'clear App IDs: several at once (a catalog copied from another tenant)' ($bulk | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/clear-appids' @{ names = @() }).ok) 'clear App IDs: nothing chosen is refused'
    $gs = Invoke-Api '/api/groups-status'
    Check ($gs.ok -and $gs.state -eq 'none') 'groups status: without a connection Entra ID is not asked' ($gs | ConvertTo-Json -Compress)
    $ids = Invoke-Api '/api/intune-apps'
    Check (-not $ids.ok -and $ids.state -eq 'none') 'intune apps: without a connection the list says so instead of guessing' ($ids | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/delete-intune' @{ name = "$testName renamed" }).ok) 'delete from Intune: refused for an app not in Intune'
    Check (-not (Invoke-Api '/api/install-status' @{ name = "$testName renamed" }).ok) 'install status: refused for an app not in Intune'

    # Managed updates: on pins the commands to the App version; a release needs a connection and a deployed app.
    $mu = Invoke-Api '/api/managed-updates' @{ names = @("$testName renamed"); on = $true }
    $muApp = (Invoke-Api '/api/app-get' @{ name = "$testName renamed" }).app
    Check ($mu.ok -and $muApp.managedUpdates) 'managed updates: turned on' ($mu | ConvertTo-Json -Compress)
    $pin = Invoke-Api '/api/app-save' @{ originalName = "$testName renamed"; app = @{ appName = "$testName renamed"; wingetId = $muApp.wingetId; appId = ''; managedUpdates = $true; metadata = @{ description = 'pinned'; appVersion = '3.2.1' } } }
    $pinApp = (Invoke-Api '/api/app-get' @{ name = "$testName renamed" }).app
    Check ($pin.ok -and $pinApp.metadata.installCommand -like "*--version '3.2.1'*") 'managed updates: the install command follows the App version' $pinApp.metadata.installCommand
    $ri = Invoke-Api '/api/release-info' @{ name = "$testName renamed" }
    Check ($ri.ok -and $ri.managed -and $ri.current -eq '3.2.1' -and $null -eq $ri.pilot) 'release info: managed, at 3.2.1, nothing in pilot' ($ri | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/release-start' @{ name = "$testName renamed"; version = '3.3' }).ok) 'release: refused without a connection'
    Check (-not (Invoke-Api '/api/release-assign' @{ name = "$testName renamed"; step = 'pilot' }).ok) 'release: assigning refused without a connection'
    Check (-not (Invoke-Api '/api/release-promoted' @{ name = "$testName renamed" }).ok) 'release: nothing to promote without a pilot release'
    $ur = Invoke-Api '/api/update-runs'
    Check ($ur.ok -and $null -ne $ur.schedule) 'nightly run: its runs and schedule can be read' ($ur | ConvertTo-Json -Compress -Depth 3)
    Check (-not (Invoke-Api '/api/update-run' @{ planOnly = $true }).ok) 'nightly run: Run now refused without a connection'
    Check (-not (Invoke-Api '/api/update-schedule' @{ on = $true; runAt = '25:99' }).ok) 'nightly run: a time that is not HH:mm is refused (or no scheduled tasks here)'
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        # The real scheduled task: created at a time, read back, removed.
        $sch = Invoke-Api '/api/update-schedule' @{ on = $true; runAt = '04:17' }
        Check ($sch.ok -and $sch.schedule.exists -and $sch.schedule.runAt -eq '04:17') 'nightly run: the scheduled task is created at the time given' ($sch | ConvertTo-Json -Compress -Depth 3)
        $unsch = Invoke-Api '/api/update-schedule' @{ on = $false }
        Check ($unsch.ok -and -not $unsch.schedule.exists) 'nightly run: the scheduled task is removed again' ($unsch | ConvertTo-Json -Compress -Depth 3)
        # An own package's installer: its version read from the file in the app's folder.
        $ownName = 'ZZ Own Package ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
        [void](Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $ownName; wingetId = ''; appId = ''; metadata = @{ description = 'own' } } })
        $ownDir = Join-Path $repoRoot ('data\app-packages\' + $ownName.Replace(' ', '-'))
        [void](New-Item -ItemType Directory -Path $ownDir -Force)
        Copy-Item -LiteralPath (Get-Process -Id $PID).Path -Destination (Join-Path $ownDir 'setup.exe')
        $oi = Invoke-Api '/api/release-info' @{ name = $ownName }
        Check ($oi.ok -and $oi.kind -eq 'package' -and $oi.installer.found -and $oi.installer.file -eq 'setup.exe' -and $oi.installer.version -match '^\d+\.\d+') 'own package: the installer''s version is read from its folder' ($oi | ConvertTo-Json -Compress -Depth 4)
        [void](Invoke-Api '/api/app-remove' @{ name = $ownName })
        Remove-Item -LiteralPath $ownDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Add apps: an installer uploaded in pieces, a script app - and what is refused.
    Check (-not (Invoke-Api '/api/upload-start' @{ fileName = 'notes.txt'; size = 10 }).ok) 'add apps: only an .msi, .exe or .zip can be uploaded'
    $setup = [Text.Encoding]::ASCII.GetBytes('MZ fake setup - Nullsoft Install System v3.09 ' + ('x' * 5000))
    $up = Invoke-Api '/api/upload-start' @{ fileName = 'zz-tool-setup.exe'; size = $setup.Length }
    $first = Invoke-Api '/api/upload-chunk' @{ uploadId = $up.uploadId; offset = 0; data = [Convert]::ToBase64String($setup, 0, 3000) }
    Check ($up.ok -and $first.ok -and $first.received -eq 3000 -and -not (Invoke-Api '/api/upload-chunk' @{ uploadId = $up.uploadId; offset = 4000; data = 'AAAA' }).ok) 'add apps: an upload arrives piece by piece, in order'
    [void](Invoke-Api '/api/upload-chunk' @{ uploadId = $up.uploadId; offset = 3000; data = [Convert]::ToBase64String($setup, 3000, $setup.Length - 3000) })
    $fin = Invoke-Api '/api/upload-finish' @{ uploadId = $up.uploadId }
    Check ($fin.ok -and $fin.kind -eq 'exe' -and $fin.exeKind -eq 'nsis' -and $fin.installCommand -eq '"zz-tool-setup.exe" /S' -and $fin.detection -eq 'Script') 'add apps: the installer is read - an NSIS setup, its silent switch, detection by what Windows lists' ($fin | ConvertTo-Json -Compress)
    $upName = 'ZZ Upload ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $addI = Invoke-Api '/api/add-installer' @{ uploadId = $up.uploadId; name = $upName; publisher = 'ZZ Vendor'; version = '1.2.3'; requiredFor = @('SG-ZZ-Up'); availableFor = @() }
    $upApp = (Invoke-Api '/api/app-get' @{ name = $upName }).app
    $upDir = [string]$addI.folder
    Check ($addI.ok -and $upApp.metadata.installCommand -eq '"zz-tool-setup.exe" /S' -and $upApp.metadata.uninstallCommand -like '*Uninstall.ps1' -and $upApp.deploy.detection.type -eq 'Script' -and @($upApp.requiredFor) -contains 'SG-ZZ-Up' -and $upApp.metadata.publisher -eq 'ZZ Vendor' -and
        (Test-Path -LiteralPath (Join-Path $upDir 'zz-tool-setup.exe')) -and (Test-Path -LiteralPath (Join-Path $upDir 'Uninstall.ps1'))) 'add apps: the installer becomes an own package - commands, detection, groups, the file and Uninstall.ps1 in its folder' ($addI | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/add-installer' @{ uploadId = $up.uploadId; name = 'again' }).ok) 'add apps: an upload is added once'
    # Before sending: what doesn't fit together in the package - shown by Checks (no connection needed).
    Remove-Item -LiteralPath (Join-Path $upDir 'Uninstall.ps1') -Force
    $pkgChk = Invoke-Api '/api/checks-run' @{ names = @($upName) }
    $pkgRow = @($pkgChk.findings | Where-Object { $_.area -eq 'Package' -or $_.Area -eq 'Package' }) | Select-Object -First 1
    Check ($pkgChk.ok -and $pkgRow -and (($pkgRow | ConvertTo-Json -Compress) -match 'Uninstall\.ps1')) 'checks: an own package whose uninstall command runs a file it lacks' ($pkgChk | ConvertTo-Json -Compress -Depth 4)
    # Watch winget for new versions (an own package): saved, a bad ID refused, shown in the list; not asked in test mode.
    $wApp = (Invoke-Api '/api/app-get' @{ name = $upName })
    $wBad = Invoke-Api '/api/app-save' @{ originalName = $upName; version = $wApp.version; app = @{ appName = $upName; wingetId = ''; appId = ''; requiredFor = @('SG-ZZ-Up'); watchWinget = 'not an id!' } }
    Check (-not $wBad.ok -and $wBad.error -like '*Winget ID*') 'watch winget: a bad Winget ID is refused' ($wBad | ConvertTo-Json -Compress)
    $wOk = Invoke-Api '/api/app-save' @{ originalName = $upName; version = $wApp.version; app = @{ appName = $upName; wingetId = ''; appId = ''; requiredFor = @('SG-ZZ-Up'); watchWinget = 'ZZVendor.Tool' } }
    $wRow = @((Invoke-Api '/api/catalog').apps | Where-Object { $_.name -eq $upName }) | Select-Object -First 1
    Check ($wOk.ok -and (Invoke-Api '/api/app-get' @{ name = $upName }).app.watchWinget -eq 'ZZVendor.Tool' -and $wRow.watchWinget -eq 'ZZVendor.Tool') 'watch winget: saved and in the Apps list' (@($wOk, $wRow) | ConvertTo-Json -Compress -Depth 3)
    Check (-not (Invoke-Api '/api/watch-fetch' @{ name = $upName }).ok -and -not (Invoke-Api '/api/watch-check' @{ name = 'No Such App' }).ok) 'watch winget: nothing downloaded in test mode; an unknown app is refused'
    [void](Invoke-Api '/api/app-remove' @{ name = $upName }); Remove-Item -LiteralPath $upDir -Recurse -Force -ErrorAction SilentlyContinue
    # 2.33.0: an installer for an app already in the catalog (one taken over from Intune comes without it): into its
    # packages folder, what is empty filled in, what it has kept; a second installer and a Winget app are refused.
    $sendUp = { param($file) $u = Invoke-Api '/api/upload-start' @{ fileName = $file; size = $setup.Length }; [void](Invoke-Api '/api/upload-chunk' @{ uploadId = $u.uploadId; offset = 0; data = [Convert]::ToBase64String($setup) }); [void](Invoke-Api '/api/upload-finish' @{ uploadId = $u.uploadId }); $u.uploadId }
    $lobName = 'ZZ From Intune ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    [void](Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $lobName; wingetId = ''; appId = 'aaea81e5-38fd-434a-a553-29fd3fb8d307'; requiredFor = @('SG-ZZ-Lob') } })
    $ai = Invoke-Api '/api/app-installer' @{ name = $lobName; uploadId = (& $sendUp 'zz-lob-setup.exe') }
    $lobApp = (Invoke-Api '/api/app-get' @{ name = $lobName }).app
    Check ($ai.ok -and @($ai.filled) -contains 'the install command' -and (@($ai.filled) -join ' ') -match 'detection rule' -and $lobApp.metadata.installCommand -eq '"zz-lob-setup.exe" /S' -and $lobApp.deploy.detection.type -eq 'Script' -and $lobApp.appId -eq 'aaea81e5-38fd-434a-a553-29fd3fb8d307' -and @($lobApp.requiredFor) -contains 'SG-ZZ-Lob' -and (Test-Path -LiteralPath (Join-Path ([string]$ai.folder) 'zz-lob-setup.exe')) -and (Test-Path -LiteralPath (Join-Path ([string]$ai.folder) 'Uninstall.ps1'))) 'installer for an app: into its folder, the commands and detection filled in, its App ID and groups kept' ($ai | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/app-installer' @{ name = $lobName; uploadId = (& $sendUp 'zz-other-setup.exe') }).ok) 'installer for an app: a second, different installer is refused (a new version is a release)'
    $keepName = 'ZZ Keep ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    [void](Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $keepName; wingetId = ''; appId = ''; metadata = @{ installCommand = 'my-own.cmd'; uninstallCommand = 'my-own-uninstall.cmd' } } })
    $ak = Invoke-Api '/api/app-installer' @{ name = $keepName; uploadId = (& $sendUp 'zz-keep-setup.exe') }
    $keepApp = (Invoke-Api '/api/app-get' @{ name = $keepName }).app
    Check ($ak.ok -and $keepApp.metadata.installCommand -eq 'my-own.cmd' -and $keepApp.metadata.uninstallCommand -eq 'my-own-uninstall.cmd' -and @($ak.filled) -notcontains 'the install command') 'installer for an app: commands it already has are kept' ($ak | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/app-installer' @{ name = $testName; uploadId = (& $sendUp 'zz-winget-setup.exe') }).ok) 'installer for an app: refused for a Winget app'
    # 2.34.0: a whole folder (or a .zip of it) for an app: every file into its packages folder, the setup file
    # suggested and changeable, replace or add asked, the files listed and deleted one by one - nothing outside it.
    $fName = 'ZZ Folder ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    [void](Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $fName; wingetId = ''; appId = '' } })
    Check (-not (Invoke-Api '/api/folder-upload-start' @{ folderName = 'x'; files = @(@{ path = '../evil.txt'; size = 3 }) }).ok -and -not (Invoke-Api '/api/folder-upload-start' @{ folderName = 'x'; files = @(@{ path = 'C:\evil.txt'; size = 3 }) }).ok) 'folder upload: a path outside the folder is refused before anything is sent'
    $folderFiles = [ordered]@{ 'Setup\zz-folder-setup.exe' = $setup; 'Setup\config.xml' = [Text.Encoding]::UTF8.GetBytes('<cfg/>'); 'readme.txt' = [Text.Encoding]::UTF8.GetBytes('hi') }
    $fs = Invoke-Api '/api/folder-upload-start' @{ folderName = 'Vendor App'; files = @($folderFiles.Keys | ForEach-Object { @{ path = $_; size = $folderFiles[$_].Length } }) }
    $idx = 0; foreach ($k in $folderFiles.Keys) { [void](Invoke-Api '/api/upload-chunk' @{ uploadId = $fs.uploadId; index = $idx; offset = 0; data = [Convert]::ToBase64String($folderFiles[$k]) }); $idx++ }
    $ff = Invoke-Api '/api/upload-finish' @{ uploadId = $fs.uploadId }
    Check ($ff.ok -and $ff.folder -and $ff.fileCount -eq 3 -and $ff.setup -eq 'Setup\zz-folder-setup.exe' -and $ff.installCommand -eq '"Setup\zz-folder-setup.exe" /S') 'folder upload: all files arrive, the setup file in a subfolder is suggested and its commands use its path' ($ff | ConvertTo-Json -Compress -Depth 4)
    $sw = Invoke-Api '/api/upload-setup' @{ uploadId = $fs.uploadId; setup = '' }
    Check ($sw.ok -and -not $sw.installCommand -and -not (Invoke-Api '/api/upload-setup' @{ uploadId = $fs.uploadId; setup = 'missing.exe' }).ok) 'folder upload: another setup file (or none) makes the proposal again; a file not in it is refused'
    [void](Invoke-Api '/api/upload-setup' @{ uploadId = $fs.uploadId; setup = 'Setup\zz-folder-setup.exe' })
    $fa = Invoke-Api '/api/app-installer' @{ name = $fName; uploadId = $fs.uploadId }
    $fApp = (Invoke-Api '/api/app-get' @{ name = $fName }).app
    $pf = Invoke-Api '/api/package-files' @{ name = $fName }
    $pfPaths = @($pf.files | ForEach-Object { $_.path })
    Check ($fa.ok -and $fa.files -eq 3 -and $fa.setup -eq 'Setup\zz-folder-setup.exe' -and $fApp.metadata.installCommand -eq '"Setup\zz-folder-setup.exe" /S' -and $pf.ok -and $pf.setupFile -eq 'Setup\zz-folder-setup.exe' -and ($pfPaths -contains 'Setup\config.xml') -and ($pfPaths -contains 'readme.txt') -and ($pfPaths -contains 'Uninstall.ps1')) 'folder upload: into its packages folder with its subfolders, the setup file remembered, the commands filled in' ($pfPaths -join ', ')
    # A .zip on top: asked first (files there already); added, it keeps them - replaced, they go. A .zip with a ../ entry is refused.
    $zipBytes = { param($entries) $ms = New-Object System.IO.MemoryStream; $za = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true); foreach ($k in $entries.Keys) { $e = $za.CreateEntry($k); $w = New-Object System.IO.StreamWriter($e.Open()); $w.Write([string]$entries[$k]); $w.Dispose() }; $za.Dispose(); $ms.ToArray() }
    Add-Type -AssemblyName System.IO.Compression
    $sendZip = { param($name, $bytes) $u = Invoke-Api '/api/upload-start' @{ fileName = $name; size = $bytes.Length }; [void](Invoke-Api '/api/upload-chunk' @{ uploadId = $u.uploadId; offset = 0; data = [Convert]::ToBase64String($bytes) }); @{ id = $u.uploadId; fin = (Invoke-Api '/api/upload-finish' @{ uploadId = $u.uploadId }) } }
    $evilZ = & $sendZip 'evil.zip' (& $zipBytes ([ordered]@{ 'ok.txt' = 'x'; '../../escaped.txt' = 'bad' }))
    Check ((-not $evilZ.fin.ok) -and $evilZ.fin.error -like "*isn't allowed*") 'zip upload: an entry pointing outside the folder is refused' ($evilZ.fin | ConvertTo-Json -Compress)
    $z = & $sendZip 'Vendor App.zip' (& $zipBytes ([ordered]@{ 'Vendor App/extra.cfg' = 'cfg'; 'Vendor App/Setup/zz-folder-setup.exe' = 'MZ new' }))
    Check ($z.fin.ok -and $z.fin.folder -and $z.fin.fileCount -eq 2 -and @($z.fin.files | ForEach-Object { $_.path }) -contains 'extra.cfg') 'zip upload: unpacked, its one top folder taken as the folder itself' ($z.fin | ConvertTo-Json -Compress -Depth 4)
    $ask = Invoke-Api '/api/app-installer' @{ name = $fName; uploadId = $z.id }
    Check ((-not $ask.ok) -and $ask.needsChoice -and $ask.existing -eq 4) 'zip upload: files there already - replace or add is asked, not guessed' ($ask | ConvertTo-Json -Compress)
    $add = Invoke-Api '/api/app-installer' @{ name = $fName; uploadId = $z.id; mode = 'add' }
    $after = @((Invoke-Api '/api/package-files' @{ name = $fName }).files | ForEach-Object { $_.path })
    Check ($add.ok -and ($after -contains 'readme.txt') -and ($after -contains 'extra.cfg')) 'zip upload: added - the files there stay, the new ones join them' ($after -join ', ')
    $z2 = & $sendZip 'only.zip' (& $zipBytes ([ordered]@{ 'only.cfg' = 'x' }))
    $rep = Invoke-Api '/api/app-installer' @{ name = $fName; uploadId = $z2.id; mode = 'replace' }
    $after2 = @((Invoke-Api '/api/package-files' @{ name = $fName }).files | ForEach-Object { $_.path })
    Check ($rep.ok -and $after2.Count -eq 1 -and $after2[0] -eq 'only.cfg') 'zip upload: replaced - only the new files are there' ($after2 -join ', ')
    # The file list: one file deleted (only one inside the folder), the setup file set to one of them.
    Check (-not (Invoke-Api '/api/package-file-delete' @{ name = $fName; path = '..\..\catalog.json' }).ok -and -not (Invoke-Api '/api/package-setup' @{ name = $fName; path = 'missing.exe' }).ok) 'package files: a path outside it, or not in it, is refused'
    $ps = Invoke-Api '/api/package-setup' @{ name = $fName; path = 'only.cfg' }
    $del = Invoke-Api '/api/package-file-delete' @{ name = $fName; path = 'only.cfg' }
    $pf3 = Invoke-Api '/api/package-files' @{ name = $fName }
    Check ($ps.ok -and $del.ok -and @($pf3.files).Count -eq 0 -and -not $pf3.setupFile) 'package files: the setup file chosen; deleted, it is forgotten too' ($pf3 | ConvertTo-Json -Compress)
    [void](Invoke-Api '/api/app-remove' @{ name = $fName }); if ($fa.folder) { Remove-Item -LiteralPath ([string]$fa.folder) -Recurse -Force -ErrorAction SilentlyContinue }
    # And built: Package runs on an uploaded folder whose setup file is in a subfolder (the package holds the whole folder).
    $bName = 'ZZ Build ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    [void](Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $bName; wingetId = ''; appId = '' } })
    $bs = Invoke-Api '/api/folder-upload-start' @{ folderName = 'Build'; files = @(@{ path = 'Setup\zz-build-setup.exe'; size = $setup.Length }, @{ path = 'Setup\cfg.ini'; size = 3 }) }
    [void](Invoke-Api '/api/upload-chunk' @{ uploadId = $bs.uploadId; index = 0; offset = 0; data = [Convert]::ToBase64String($setup) })
    [void](Invoke-Api '/api/upload-chunk' @{ uploadId = $bs.uploadId; index = 1; offset = 0; data = [Convert]::ToBase64String([byte[]](65, 66, 67)) })
    [void](Invoke-Api '/api/upload-finish' @{ uploadId = $bs.uploadId })
    $ba = Invoke-Api '/api/app-installer' @{ name = $bName; uploadId = $bs.uploadId }
    $pkgJob = Invoke-Api '/api/package-start' @{ names = @($bName) }
    $pkgLog = ''; $pkgDone = $false; $off = 0; $until = (Get-Date).AddSeconds(120)
    while ($pkgJob.ok -and -not $pkgDone -and (Get-Date) -lt $until) {
        $pp = Invoke-Api '/api/job-poll' @{ job = $pkgJob.job; offset = $off }
        if (-not $pp.ok) { break }
        $off = $pp.offset; $pkgLog += [string]$pp.text
        if ($pp.done -and -not $pp.text) { $pkgDone = $true } else { Start-Sleep -Milliseconds 400 }
    }
    $built = @(Get-ChildItem -LiteralPath ([string]$ba.folder) -Filter '*.intunewin' -File -ErrorAction SilentlyContinue)
    Check ($ba.ok -and $pkgDone -and $built.Count -eq 1 -and $built[0].Length -gt 0) 'folder upload: Package builds it - the setup file in its subfolder' (($pkgLog -split "`n" | Select-Object -Last 8) -join ' | ')
    [void](Invoke-Api '/api/app-remove' @{ name = $bName }); if ($ba.folder) { Remove-Item -LiteralPath ([string]$ba.folder) -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($n in $lobName, $keepName) { [void](Invoke-Api '/api/app-remove' @{ name = $n }) }
    foreach ($d in $ai.folder, $ak.folder) { if ($d) { Remove-Item -LiteralPath ([string]$d) -Recurse -Force -ErrorAction SilentlyContinue } }
    $scName = 'ZZ Script ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $tpls = Invoke-Api '/api/script-templates' @{ name = $scName; version = '2.0' }
    Check (-not (Invoke-Api '/api/add-script' @{ name = $scName; version = '2.0'; install = 'Write-Output hi'; uninstall = 'Write-Output bye' }).ok) 'add apps: a script app without the version marker or a detection script is refused'
    $addS = Invoke-Api '/api/add-script' @{ name = $scName; publisher = 'IT'; version = '2.0'; install = $tpls.templates[1].install; uninstall = $tpls.templates[1].uninstall }
    $scApp = (Invoke-Api '/api/app-get' @{ name = $scName }).app
    $scDir = [string]$addS.folder
    Check ($addS.ok -and $scApp.deploy.detection.type -eq 'Registry' -and $scApp.deploy.detection.value -eq '2.0' -and $scApp.metadata.installCommand -like '*-File .\Install.ps1' -and (Test-Path -LiteralPath (Join-Path $scDir 'Install.ps1')) -and $scApp.managedUpdates) 'add apps: a script app - Install.ps1 in its folder, detected by its version marker, managed updates on' ($addS | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/add-script' @{ name = $scName; version = '2.0'; install = $tpls.templates[1].install; uninstall = 'x' }).ok) 'add apps: a name already in the catalog is refused'
    # A new version: the detection rule and the script's version marker move together.
    $scQ = Invoke-Api '/api/app-quick' @{ name = $scName; field = 'appVersion'; value = '2.5' }
    $scApp2 = (Invoke-Api '/api/app-get' @{ name = $scName }).app
    Check ($scQ.ok -and @($scQ.scripts) -contains 'Install.ps1' -and $scApp2.deploy.detection.value -eq '2.5' -and (Get-Content -LiteralPath (Join-Path $scDir 'Install.ps1') -Raw) -match "-Name Version -Value '2\.5'") 'a script app''s new version: detection and the Install.ps1 marker both 2.5' ($scQ | ConvertTo-Json -Compress)
    # Package scripts in the app (2.26): read with the locked marker lines, saved only unchanged since opened, parsing and keeping the marker; the earlier one in Backups.
    $ps1 = Invoke-Api '/api/package-script' @{ name = $scName; file = 'Install.ps1' }
    Check ($ps1.ok -and $ps1.text -match 'IntuneAppCatalog' -and @($ps1.locked).Count -ge 2 -and @($ps1.files) -contains 'Uninstall.ps1') 'script editor: Install.ps1 read, its version marker locked' ($ps1 | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/package-script' @{ name = $scName; file = '..\..\evil.ps1' }).ok -and -not (Invoke-Api '/api/package-script' @{ name = 'No Such App'; file = 'Install.ps1' }).ok) 'script editor: only the package scripts of an app in the catalog'
    $edited = $ps1.text.Replace('$ErrorActionPreference', "Write-Output 'edited in the app'`r`n`$ErrorActionPreference")
    $sv = Invoke-Api '/api/package-script-save' @{ name = $scName; file = 'Install.ps1'; text = $edited; hash = $ps1.hash }
    Check ($sv.ok -and (Get-Content -LiteralPath (Join-Path $scDir 'Install.ps1') -Raw) -match 'edited in the app' -and $sv.hash -ne $ps1.hash) 'script editor: saved' ($sv | ConvertTo-Json -Compress)
    $stale = Invoke-Api '/api/package-script-save' @{ name = $scName; file = 'Install.ps1'; text = $edited + "`r`n# again"; hash = $ps1.hash }
    Check ((-not $stale.ok) -and $stale.conflict) 'script editor: a save over a change made since it was opened is refused'
    $markerGone = Invoke-Api '/api/package-script-save' @{ name = $scName; file = 'Install.ps1'; text = ($edited -replace "-Value '2\.5'", "-Value '9.9'"); hash = $sv.hash }
    $broken = Invoke-Api '/api/package-script-save' @{ name = $scName; file = 'Install.ps1'; text = ($edited + "`r`nif (`$x {"); hash = $sv.hash }
    Check ((-not $markerGone.ok) -and (-not $broken.ok) -and @($broken.errors).Count -ge 1) 'script editor: a changed version marker or a script that does not parse is refused'
    $prev = Invoke-Api '/api/package-script-previous' @{ name = $scName; file = 'Install.ps1' }
    Check ($prev.ok -and $prev.text -eq $ps1.text) 'script editor: the previous version comes from the recorded copy in Backups' ($prev | ConvertTo-Json -Compress)
    # 2.38.17: the text files a setup reads open too - saved in their own encoding and line ends (an ANSI .cfg stays ANSI).
    $cfgBytes = [byte[]](@([System.Text.Encoding]::ASCII.GetBytes("[Params]`r`nName=M")) + @([byte]0xFC) + @([System.Text.Encoding]::ASCII.GetBytes("ller`r`n")))
    [System.IO.File]::WriteAllBytes((Join-Path $scDir 'SilentClient.cfg'), $cfgBytes)
    [System.IO.File]::WriteAllText((Join-Path $scDir 'login.xml'), "<a><b>1</b></a>", (New-Object System.Text.UTF8Encoding($false)))
    $cfg = Invoke-Api '/api/package-script' @{ name = $scName; file = 'SilentClient.cfg' }
    $cfgSave = Invoke-Api '/api/package-script-save' @{ name = $scName; file = 'SilentClient.cfg'; text = ($cfg.text -replace 'Name=', 'Name=Herr '); hash = $cfg.hash }
    $cfgAfter = [System.IO.File]::ReadAllBytes((Join-Path $scDir 'SilentClient.cfg'))
    Check ($cfg.ok -and $cfg.kind -eq 'text' -and $cfg.text -match ('M' + [char]0xFC + 'ller') -and @($cfg.files) -contains 'login.xml' -and $cfgSave.ok -and $cfgAfter -contains [byte]0xFC -and -not ($cfgAfter[0] -eq 0xEF) -and ([System.Text.Encoding]::ASCII.GetString($cfgAfter)) -match "Herr M.ller`r`n") 'text editor: a .cfg read and saved back in its own (ANSI) encoding and line ends' (($cfgSave | ConvertTo-Json -Compress) + ' bytes: ' + (($cfgAfter | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
    $xml = Invoke-Api '/api/package-script' @{ name = $scName; file = 'login.xml' }
    $badXml = Invoke-Api '/api/package-script-save' @{ name = $scName; file = 'login.xml'; text = '<a><b>1</a>'; hash = $xml.hash }
    $chk = Invoke-Api '/api/package-script-check' @{ file = 'login.xml'; text = '<a><b>1</a>'; old = '' }
    Check ($xml.ok -and -not $badXml.ok -and -not $chk.valid -and @($chk.errors).Count -ge 1 -and -not (Invoke-Api '/api/package-script' @{ name = $scName; file = 'setup.exe' }).ok) 'text editor: an .xml must stay well-formed; other file types are not opened'
    $blk = Invoke-Api '/api/install-blocks' @{ install = $scApp.metadata.installCommand; uninstall = $scApp.metadata.uninstallCommand }
    $mblk = Invoke-Api '/api/install-compose' @{ form = 'msi'; values = @{ file = 'a.msi'; props = @(@{ name = 'ALLUSERS'; value = '1' }); code = '{12345678-1234-1234-1234-123456789ABC}' }; install = 'msiexec /i "a.msi" /qn /norestart'; uninstall = 'msiexec /x {12345678-1234-1234-1234-123456789ABC} /qn /norestart' }
    Check ($blk.ok -and $blk.form -eq 'script' -and $mblk.ok -and $mblk.install -eq 'msiexec /i "a.msi" /qn /norestart ALLUSERS=1') 'blocks: a script app''s commands, and an MSI property written into its command' ($mblk | ConvertTo-Json -Compress)
    [void](Invoke-Api '/api/app-remove' @{ name = $scName }); Remove-Item -LiteralPath $scDir -Recurse -Force -ErrorAction SilentlyContinue
    # The change history: an editor save is recorded field by field, from the Editor; undo puts one change back; a rename keeps the history.
    $hName = 'ZZ History ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    [void](Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $hName; wingetId = 'Contoso.History'; appId = ''; requiredFor = @('SG-A'); metadata = @{ description = 'first' } } })
    [void](Invoke-Api '/api/app-save' @{ originalName = $hName; app = @{ appName = $hName; wingetId = 'Contoso.History'; appId = ''; requiredFor = @('SG-A', 'SG-B'); metadata = @{ description = 'second' } } })
    $h = Invoke-Api '/api/app-history' @{ name = $hName }
    $hLast = $h.entries[0]
    Check ($h.ok -and @($h.entries).Count -eq 2 -and $hLast.source -eq 'Editor' -and $hLast.canUndo -and @($hLast.changes | Where-Object { $_.field -eq 'requiredFor' -and $_.after -eq 'SG-A, SG-B' }).Count -eq 1 -and
        @($hLast.changes | Where-Object { $_.field -eq 'metadata.description' -and $_.before -eq 'first' }).Count -eq 1 -and $h.entries[1].text -eq 'Added to the catalog') 'history: an editor save, field by field, from the Editor' ($h | ConvertTo-Json -Compress -Depth 6)
    $hu = Invoke-Api '/api/history-undo' @{ name = $hName; id = $hLast.id }
    $hApp = (Invoke-Api '/api/app-get' @{ name = $hName }).app
    Check ($hu.ok -and @($hApp.requiredFor).Count -eq 1 -and $hApp.metadata.description -eq 'first') 'history: undo puts that change''s fields back' ($hu | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/history-undo' @{ name = $hName; id = $hLast.id }).ok) 'history: undoing it twice does nothing (the fields were changed since)'
    # A Winget app without settings of its own: picking a version gives it settings (the defaults) with that version.
    $qvName = 'ZZ QuickVer ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    Set-Content -LiteralPath (Join-Path (Invoke-Api '/api/catalog').path ($qvName.Replace(' ', '-') + '.json')) -Encoding UTF8 -Value (@{ appName = $qvName; wingetId = 'Contoso.QuickVer'; appId = '' } | ConvertTo-Json)
    $qv = Invoke-Api '/api/app-quick' @{ name = $qvName; field = 'appVersion'; value = '3.2.1' }
    $qvApp = (Invoke-Api '/api/app-get' @{ name = $qvName }).app
    Check ($qv.ok -and $qvApp.metadata.appVersion -eq '3.2.1' -and $qvApp.hasMetadata) 'side panel: a version picked for a Winget app without settings gives it settings with that version' ($qv | ConvertTo-Json -Compress)
    [void](Invoke-Api '/api/app-remove' @{ name = $qvName })
    # Another admin changing an app (a busy marker from another PC, next to the catalog): the list says who.
    $busyDir = Join-Path (Join-Path (Invoke-Api '/api/catalog').path '.integrity') 'busy'
    [void](New-Item -ItemType Directory -Path $busyDir -Force)
    $busyApp = @((Invoke-Api '/api/catalog').apps)[0].name
    $busySafe = (((($busyApp -replace '[<>:"/\\|?*\x00-\x1f]', '') -replace '\s+', ' ') -replace '\s', '-') -replace '[.-]+', '-').Trim('-')
    $busyFile = Join-Path $busyDir ($busySafe + '.json')
    Set-Content -LiteralPath $busyFile -Encoding UTF8 -Value (@{ pid = 1; procStart = ''; started = (Get-Date).ToUniversalTime().ToString('o'); what = 'Release'; user = 'anna'; machine = 'OTHER-PC' } | ConvertTo-Json -Compress)
    $busyRow = @((Invoke-Api '/api/catalog').apps | Where-Object { $_.name -eq $busyApp })[0]
    Check ([string]$busyRow.busy -like '*anna on OTHER-PC*Release*') 'several admins: an app another admin is changing says who and what' ([string]$busyRow.busy + ' / ' + $busySafe)
    Remove-Item -LiteralPath $busyFile -Force
    $cv = Invoke-Api '/api/catalog-values'
    Check ($cv.ok -and $null -ne $cv.owner) 'pickers: the catalog''s publishers, owners and developers are listed' ($cv | ConvertTo-Json -Compress)
    $ch = Invoke-Api '/api/catalog-history' @{ limit = 50 }
    $chMine = @($ch.groups | Where-Object { @($_.items | Where-Object { $_.app -eq $hName }).Count })
    Check ($ch.ok -and $chMine.Count -ge 2 -and @($chMine[0].items | Where-Object { $_.app -eq $hName -and $_.id }).Count -ge 1) 'recent changes: the catalog''s history across apps, newest first, each change with its id' ((($ch | ConvertTo-Json -Compress -Depth 8) + '').Substring(0, [Math]::Min(1500, (($ch | ConvertTo-Json -Compress -Depth 8) + '').Length)))
    [void](Invoke-Api '/api/app-save' @{ originalName = $hName; app = @{ appName = "$hName R"; wingetId = 'Contoso.History'; appId = ''; requiredFor = @('SG-A'); metadata = @{ description = 'first' } } })
    $hr = Invoke-Api '/api/app-history' @{ name = "$hName R" }
    Check (@($hr.entries).Count -eq 4 -and @($hr.entries[0].changes | Where-Object { $_.field -eq 'appName' }).Count -eq 1 -and $hr.entries[-1].app -eq $hName) 'history: a rename keeps what happened under the old name' ($hr | ConvertTo-Json -Compress -Depth 6)
    Check (-not (Invoke-Api '/api/history-undo' @{ name = "$hName R"; id = '../x' }).ok) 'history: an id that isn''t one is refused'
    [void](Invoke-Api '/api/app-remove' @{ name = "$hName R" })
    # Retiring: refused without an App ID or groups; an app not in Intune is archived and removed at once; Restore brings it back without groups.
    $rtName = 'ZZ Retire ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    [void](Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $rtName; wingetId = 'Contoso.Retire'; appId = ''; requiredFor = @('SG-A'); metadata = @{ description = 'r' } } })
    Check (-not (Invoke-Api '/api/retire-start' @{ name = $rtName }).ok) 'retire: an app not in Intune has nothing to uninstall - refused'
    $rts = Invoke-Api '/api/retire-status' @{ name = $rtName }
    Check ($rts.ok -and -not $rts.inIntune -and -not $rts.retiringSince -and @($rts.groups) -contains 'SG-A') 'retire: the status says what would be uninstalled'
    $rtf = Invoke-Api '/api/retire-finish' @{ name = $rtName }
    $rtl = Invoke-Api '/api/retired-list'
    $rtEntry = @($rtl.apps | Where-Object { $_.name -eq $rtName })[0]
    Check ($rtf.ok -and -not (Invoke-Api '/api/app-get' @{ name = $rtName }).ok -and $rtEntry) 'retire: finished - archived and out of the catalog' ($rtl | ConvertTo-Json -Compress -Depth 4)
    $rtr = Invoke-Api '/api/retired-restore' @{ id = $rtEntry.id }
    $rtApp = (Invoke-Api '/api/app-get' @{ name = $rtName }).app
    Check ($rtr.ok -and $rtApp -and @($rtApp.requiredFor).Count -eq 0 -and -not $rtApp.appId -and $rtApp.metadata.description -eq 'r') 'retire: restored - its settings back, not in Intune, without groups'
    Check (-not (Invoke-Api '/api/retired-restore' @{ id = $rtEntry.id }).ok -and -not (Invoke-Api '/api/retired-restore' @{ id = '..\x.json' }).ok) 'retire: restoring it twice, or a name that is not one, is refused'
    $rth = Invoke-Api '/api/app-history' @{ name = $rtName }
    Check (@($rth.entries | Where-Object { $_.text -like 'Retired*' }).Count -eq 1 -and $rth.entries[0].text -like 'Restored*') 'retire: retiring and restoring are in its history'
    [void](Invoke-Api '/api/app-remove' @{ name = $rtName })
    $rtGuid = [guid]::NewGuid().ToString()
    [void](Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = "$rtName 2"; wingetId = 'Contoso.Retire'; appId = $rtGuid; metadata = @{ description = 'r' } } })
    Check (-not (Invoke-Api '/api/retire-start' @{ name = "$rtName 2" }).ok) 'retire: an app without groups has nothing to uninstall - refused (finish deletes it)'
    [void](Invoke-Api '/api/app-remove' @{ name = "$rtName 2" })
    # Quick edits from the side panel: a group added and taken off, the version - and it's in the history as from the side panel.
    $qName = 'ZZ Quick ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    [void](Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $qName; wingetId = 'Contoso.Quick'; appId = ''; requiredFor = @('SG-A'); managedUpdates = $false; metadata = @{ description = 'q'; appVersion = '1.0' } } })
    $q1 = Invoke-Api '/api/app-quick' @{ name = $qName; field = 'availableFor'; add = 'SG-B' }
    $q2 = Invoke-Api '/api/app-quick' @{ name = $qName; field = 'requiredFor'; remove = 'SG-A' }
    $q3 = Invoke-Api '/api/app-quick' @{ name = $qName; field = 'appVersion'; value = '2.0' }
    $qApp = (Invoke-Api '/api/app-get' @{ name = $qName }).app
    Check ($q1.ok -and $q2.ok -and $q3.ok -and @($qApp.availableFor) -contains 'SG-B' -and @($qApp.requiredFor).Count -eq 0 -and $qApp.metadata.appVersion -eq '2.0') 'quick edit: a group added, one taken off, the version changed - without the editor'
    Check (-not (Invoke-Api '/api/app-quick' @{ name = $qName; field = 'appId'; value = 'x' }).ok -and -not (Invoke-Api '/api/app-quick' @{ name = $qName; field = 'requiredFor'; add = "bad`tname" }).ok) 'quick edit: only groups and the version, and only group names Entra ID takes'
    Check ((Invoke-Api '/api/app-history' @{ name = $qName }).entries[0].source -eq 'Side panel') 'quick edit: in the history, from the side panel'
    [void](Invoke-Api '/api/app-remove' @{ name = $qName })
    # A deployed app with managed updates: its version only through a release - the editor refuses a typed one.
    $mgName = 'ZZ Managed Guard ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    [void](Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $mgName; wingetId = 'Contoso.Guard'; appId = [guid]::NewGuid().ToString(); managedUpdates = $true; metadata = @{ description = 'g'; appVersion = '1.0' } } })
    $mgSave = Invoke-Api '/api/app-save' @{ originalName = $mgName; app = @{ appName = $mgName; wingetId = 'Contoso.Guard'; appId = (Invoke-Api '/api/app-get' @{ name = $mgName }).app.appId; managedUpdates = $true; metadata = @{ description = 'g'; appVersion = '2.0' } } }
    Check (-not $mgSave.ok -and $mgSave.error -like '*Release new version*') 'editor: a deployed managed app''s version is changed by a release, not typed in' ($mgSave | ConvertTo-Json -Compress)
    # Renaming an app: another app's dependency on it follows.
    $depName = 'ZZ Depends ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $catDir = (Invoke-Api '/api/catalog').path
    Set-Content -LiteralPath (Join-Path $catDir ($depName.Replace(' ', '-') + '.json')) -Encoding UTF8 -Value (@{ appName = $depName; wingetId = 'Contoso.Dep'; appId = ''; metadata = @{ description = 'd'; dependencies = @($mgName) } } | ConvertTo-Json -Depth 4)
    $depBefore = (Invoke-Api '/api/app-get' @{ name = $depName }).app
    [void](Invoke-Api '/api/app-save' @{ originalName = $mgName; app = @{ appName = "$mgName R"; wingetId = 'Contoso.Guard'; appId = (Invoke-Api '/api/app-get' @{ name = $mgName }).app.appId; managedUpdates = $true; metadata = @{ description = 'g'; appVersion = '1.0' } } })
    $depAfter = (Invoke-Api '/api/app-get' @{ name = $depName }).app
    Check (@($depBefore.deploy.dependencies) -contains $mgName -and @($depAfter.deploy.dependencies) -contains "$mgName R" -and @($depAfter.deploy.dependencies) -notcontains $mgName) 'rename: another app''s dependency follows the new name' (@{ before = $depBefore.deploy.dependencies; after = $depAfter.deploy.dependencies } | ConvertTo-Json -Compress)
    [void](Invoke-Api '/api/app-remove' @{ name = $depName }); [void](Invoke-Api '/api/app-remove' @{ name = "$mgName R" })
    # Winget-AutoUpdate removed (2.19): an app still on its commands is switched to managed updates, its WAU dependency dropped.
    $wauName = 'ZZ Wau ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $wauCmd = '%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File "C:\Program Files\Winget-AutoUpdate\Winget-Install.ps1" -AppIDs "Contoso.Wau"'
    Set-Content -LiteralPath (Join-Path $catDir ($wauName.Replace(' ', '-') + '.json')) -Encoding UTF8 -Value (@{ appName = $wauName; wingetId = 'Contoso.Wau'; appId = ''; metadata = @{ description = 'w'; appVersion = '2.5'; installContext = 'System'; installCommand = $wauCmd; uninstallCommand = "$wauCmd -Uninstall"; dependencies = @('Winget-AutoUpdate') } } | ConvertTo-Json -Depth 4)
    [void](Invoke-Api '/api/managed-default' @{})
    $wauPre = Invoke-Api '/api/wau-switch' @{ preview = $true }
    $wauAtt = Invoke-Api '/api/attention'
    $wauRun = Invoke-Api '/api/wau-switch' @{}
    $wauNow = (Invoke-Api '/api/app-get' @{ name = $wauName }).app
    Check ($wauPre.ok -and @($wauPre.apps | Where-Object { $_.app -eq $wauName }).Count -eq 1 -and @($wauAtt.items | Where-Object { $_.title -like '*still use Winget-AutoUpdate*' }).Count -eq 1 -and
        $wauRun.ok -and $wauNow.managedUpdates -and $wauNow.metadata.installCommand -notlike '*Winget-Install.ps1*' -and $wauNow.metadata.installCommand -like "*--version '2.5'*" -and @($wauNow.deploy.dependencies) -notcontains 'Winget-AutoUpdate') `
        'Winget-AutoUpdate: Home names the app, the switch pins it to its App version and drops the WAU dependency' (@{ pre = $wauPre; run = $wauRun; now = $wauNow.metadata } | ConvertTo-Json -Compress -Depth 4)
    Check (-not (Invoke-Api '/api/winget-commands' @{ wingetId = 'Contoso.Wau'; method = 'WAU' }).ok) 'Winget-AutoUpdate: the editor can no longer ask for its commands'
    [void](Invoke-Api '/api/app-remove' @{ name = $wauName })
    # Company Portal without a Winget ID: one click makes it the Store app.
    $cpName = 'Company Portal'
    if (-not (Invoke-Api '/api/app-get' @{ name = $cpName }).ok) {
        Set-Content -LiteralPath (Join-Path $catDir 'Company-Portal.json') -Encoding UTF8 -Value (@{ appName = $cpName; wingetId = ''; appId = ''; metadata = @{ description = 'cp' } } | ConvertTo-Json -Depth 4)
        $cpAtt = Invoke-Api '/api/attention'
        $cpFix = Invoke-Api '/api/portal-store' @{}
        Check (@($cpAtt.items | Where-Object { $_.go -eq 'do:portalstore' }).Count -eq 1 -and $cpFix.ok -and (Invoke-Api '/api/app-get' @{ name = $cpName }).app.wingetId -eq '9WZDNCRFJ3PZ') 'Company Portal: Home offers the fix, which makes it the Store app' ($cpFix | ConvertTo-Json -Compress)
        [void](Invoke-Api '/api/app-remove' @{ name = $cpName })
    }
    # An assignment filter round-trips through the catalog file and the editor.
    $flName = 'ZZ Filter ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    [void](Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $flName; wingetId = 'Contoso.Filter'; appId = ''; requiredFor = @('SG-A'); assignmentFilter = ' Corp laptops '; assignmentFilterMode = 'exclude'; metadata = @{ description = 'f' } } })
    $flApp = (Invoke-Api '/api/app-get' @{ name = $flName }).app
    Check ($flApp.assignmentFilter -eq 'Corp laptops' -and $flApp.assignmentFilterMode -eq 'exclude') 'filter: saved by name (trimmed) with its mode, read back in the editor'
    [void](Invoke-Api '/api/app-remove' @{ name = $flName })
    $fl = Invoke-Api '/api/filters'
    Check ($fl.ok -and @($fl.filters).Count -eq 0 -and $fl.note) 'filters: not connected - an empty list and a note, so the name can still be typed'
    # A Microsoft Store app: never managed updates (the Store updates it).
    $stName = 'ZZ Store ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    [void](Invoke-Api '/api/app-save' @{ originalName = ''; app = @{ appName = $stName; wingetId = '9NBLGGH4NNS1'; appId = ''; managedUpdates = $true; metadata = @{ description = 'store' } } })
    Check (-not (Invoke-Api '/api/app-get' @{ name = $stName }).app.managedUpdates) 'store app: managed updates stay off - the Store updates it'
    [void](Invoke-Api '/api/app-remove' @{ name = $stName })
    # PSADT: refused without the template (and no download); with the template in its folder, filled in and added.
    $psName = 'ZZ PSADT ' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    Check (-not (Invoke-Api '/api/add-psadt' @{ name = $psName; version = '1.0'; download = $false }).ok) 'psadt: without the template in its folder (and no download) it is refused'
    $psDir = Join-Path (Split-Path $scDir -Parent) $psName.Replace(' ', '-')
    [void](New-Item -ItemType Directory -Path $psDir -Force)
    Set-Content -LiteralPath (Join-Path $psDir 'Invoke-AppDeployToolkit.ps1') -Value "`$adtSession = @{`r`n    AppVendor = ''`r`n    AppName = ''`r`n    AppVersion = ''`r`n}`r`n    ## <Perform Post-Installation tasks here>`r`n    ## <Perform Post-Uninstallation tasks here>" -Encoding UTF8
    $ps = Invoke-Api '/api/add-psadt' @{ name = $psName; publisher = 'Contoso'; version = '2.0'; download = $false }
    $psApp = (Invoke-Api '/api/app-get' @{ name = $psName }).app
    Check ($ps.ok -and @($ps.missing).Count -eq 0 -and $psApp.metadata.installCommand -like '*Invoke-AppDeployToolkit*-DeploymentType Install*' -and $psApp.deploy.detection.type -eq 'Registry' -and $psApp.managedUpdates -and
        (Get-Content -LiteralPath (Join-Path $psDir 'Invoke-AppDeployToolkit.ps1') -Raw) -match "AppVendor = 'Contoso'") 'psadt: the template filled in, the toolkit''s commands, detected by its version marker' ($ps | ConvertTo-Json -Compress)
    [void](Invoke-Api '/api/app-remove' @{ name = $psName }); Remove-Item -LiteralPath $psDir -Recurse -Force -ErrorAction SilentlyContinue
    Check (-not (Invoke-Api '/api/permission-check').ok) 'permissions: the check needs a connection'

    # Conveniences: group suggestions, profiles, the grid, Home, lists, icons.
    $gsug = Invoke-Api '/api/group-suggest' @{ q = 'SG' }
    Check ($gsug.ok -and @($gsug.groups).Count -ge 1 -and @($gsug.groups | Where-Object { $_.source -eq 'entra' }).Count -eq 0) 'group picker: suggestions from the catalog without a connection - Entra ID isn''t asked' ($gsug | ConvertTo-Json -Compress -Depth 3)
    Check (-not (Invoke-Api '/api/group-check' @{ names = @('SG-X') }).checked) 'group picker: no check against Entra ID without a connection'
    $gall = Invoke-Api '/api/group-suggest' @{ q = 'all' }
    Check ($gall.ok -and @($gall.groups | Where-Object { $_.source -eq 'built-in' } | ForEach-Object { $_.name }) -join ',' -eq '[All users],[All devices]') 'group picker: Intune''s All users and All devices offered' ($gall | ConvertTo-Json -Compress -Depth 3)
    $profBad = Invoke-Api '/api/prefs-save' @{ profiles = @(@{ name = 'Twice'; required = @('SG-1') }, @{ name = 'Twice'; available = @('SG-2') }) }
    Check (-not $profBad.ok -and $profBad.error -like '*same name*') 'profiles: two with the same name are refused' ($profBad | ConvertTo-Json -Compress)
    $profOk = Invoke-Api '/api/prefs-save' @{ profiles = @(@{ name = 'Standard'; required = @('SG-ZZ-All'); available = @('SG-ZZ-IT'); exclude = @() }) }
    Check ($profOk.ok -and @($profOk.profiles).Count -eq 1 -and $profOk.profiles[0].name -eq 'Standard') 'profiles: saved and given back to the page' ($profOk | ConvertTo-Json -Compress -Depth 4)
    [void](Invoke-Api '/api/prefs-save' @{ profiles = @() })
    $mxr = Invoke-Api '/api/assignment-matrix'
    $setA = Invoke-Api '/api/assignments-set' @{ changes = @(@{ name = "$testName renamed"; group = 'SG-ZZ-Grid'; role = 'available' }) }
    $gridApp = (Invoke-Api '/api/app-get' @{ name = "$testName renamed" }).app
    Check (@((Invoke-Api '/api/assignment-matrix').groups) -contains 'SG-ZZ-Grid') 'groups and apps grid: a group set on an app is a column'
    Check ($mxr.ok -and @($mxr.apps | Where-Object { $_.name -eq "$testName renamed" }).Count -eq 1 -and $setA.ok -and @($gridApp.availableFor) -contains 'SG-ZZ-Grid') 'groups and apps grid: lists the apps; a cell set to Available is saved' ($setA | ConvertTo-Json -Compress)
    [void](Invoke-Api '/api/assignments-set' @{ changes = @(@{ name = "$testName renamed"; group = 'SG-ZZ-Grid'; role = '' }) })
    Check (@((Invoke-Api '/api/app-get' @{ name = "$testName renamed" }).app.availableFor) -notcontains 'SG-ZZ-Grid') 'groups and apps grid: a cell set to none takes the group off'
    Check (-not (Invoke-Api '/api/assignments-set' @{ changes = @(@{ name = "$testName renamed"; group = 'SG-ZZ-Grid'; role = 'owner' }) }).ok) 'groups and apps grid: an unknown role is refused'
    # The catalog's lock file is held only while a change is written - after it, another process can take it.
    $lockPath = Join-Path (Invoke-Api '/api/state').catalogPath '.catalog-write.lock'
    $lockFree = $false
    if (Test-Path -LiteralPath $lockPath) { try { $fs = [System.IO.File]::Open($lockPath, 'Open', 'ReadWrite', 'None'); $fs.Dispose(); $lockFree = $true } catch { } }
    Check ((Test-Path -LiteralPath $lockPath) -and $lockFree) 'catalog lock: a lock file in the catalog folder, released after each change'
    $md = Invoke-Api '/api/managed-default' @{}
    Check ($md.ok -and (Invoke-Api '/api/prefs').defaults.wingetInstallMethod -eq 'Managed') 'managed updates: the default for new Winget apps' ($md | ConvertTo-Json -Compress)
    $att = Invoke-Api '/api/attention'
    Check ($att.ok -and @($att.items | Where-Object { $_.title -eq 'Not connected' }).Count -eq 1 -and $att.apps -ge 1) 'home: says it is not connected, counts the apps' ($att | ConvertTo-Json -Compress -Depth 3)
    Check (@($att.setup).Count -eq 5 -and -not $att.setup[0].done -and $att.setup[0].title -eq 'Connect to Intune' -and $att.setup[2].done -and -not @($att.setup | Where-Object { $_.title -match 'shared Winget package' }).Count) 'home: getting started - connecting not done, apps added' ($att.setup | ConvertTo-Json -Compress -Depth 3)
    $attL = Invoke-Api '/api/attention' @{ part = 'local' }
    $attI = Invoke-Api '/api/attention' @{ part = 'intune' }
    Check ($attL.ok -and @($attL.items).Count -eq @($att.items).Count -and @($attL.setup).Count -eq 5 -and $attI.ok -and @($attI.items).Count -eq 0 -and $null -eq $attI.setup) 'home: the local part has every item without Intune, the Intune part only its own (none when not connected)' (@($attL, $attI) | ConvertTo-Json -Compress -Depth 3)
    $pl = Invoke-Api '/api/package-list' @{ json = '{"Sources":[{"Packages":[{"PackageIdentifier":"Vendor.ZZNew"},{"PackageIdentifier":"Mozilla.Firefox"}]}]}' }
    Check ($pl.ok -and @($pl.items).Count -eq 2 -and @($pl.items | Where-Object { $_.id -eq 'Vendor.ZZNew' -and -not $_.inCatalog }).Count -eq 1) 'from a list: a winget export file''s packages, each marked in the catalog or not' ($pl | ConvertTo-Json -Compress -Depth 3)
    # 2.38.10: a certificate exported with its private key - a long password, and the same certificate comes back.
    $px = Invoke-Api '/api/cert-export-pfx' @{ thumbprint = ('CD' * 20); password = 'a-long-enough-pw' }
    Check (-not $px.ok -and $px.error -like '*Only the connection*') '.pfx export: an unknown certificate is refused' ($px | ConvertTo-Json -Compress)
    # 2.38.12: on a PC only the connection's certificate - not the user's own (mail, VPN, code signing) in the same store.
    if ($IsLinux) {
        $nc = Invoke-Api '/api/cert-new' @{ subject = 'ZZ Export Test' }
        $pxOther = Invoke-Api '/api/cert-export-pfx' @{ thumbprint = $nc.thumbprint; password = 'a-long-enough-pw' }
        Check ($nc.ok -and -not $pxOther.ok -and $pxOther.error -like "*Only the connection*") '.pfx export: on a PC, a certificate that isn''t the connection''s is refused' ($pxOther | ConvertTo-Json -Compress)
        if ($nc.ok) { [void](Invoke-Api '/api/cert-delete-local' @{ thumbprint = $nc.thumbprint; store = 'CurrentUser' }) }
    }
    # 2.38.13: Add apps > Microsoft Store - the search wants 2 characters, like winget's.
    $ss = Invoke-Api '/api/store-search' @{ q = 'x' }
    Check (-not $ss.ok -and $ss.error -like '*at least 2*') 'store search: too short a query is refused' ($ss | ConvertTo-Json -Compress)
    $st = Invoke-Api '/api/package-list' @{ starter = $true }
    Check ($st.ok -and $st.starter -and @($st.items).Count -ge 20 -and @($st.items | Where-Object { $_.recommended }).Count -eq 10 -and @($st.items | Where-Object { $_.id -eq 'Mozilla.Firefox' -and $_.name -and $_.category -and $_.why }).Count -eq 1) 'recommended apps: the starter set, each with its name, category and why' ($st | ConvertTo-Json -Compress -Depth 3)
    Check ((Invoke-Api '/api/installed-apps').ok) 'detection from this PC: the installed apps can be listed (empty off Windows)'
    # 2.38.21: Microsoft 365 Apps from the starter set - Intune's own Office app with its settings, ready to send without a package.
    $o365 = Invoke-Api '/api/add-winget' @{ items = @(@{ id = 'Microsoft.365Apps.Intune'; name = 'Microsoft 365 Apps' }); required = @('SG-ZZ-Office') }
    $o365Name = @($o365.added)[0]
    $o365App = if ($o365Name) { (Invoke-Api '/api/app-get' @{ name = $o365Name }).app }
    Check ($o365.ok -and $o365Name -and $o365App.office.channel -eq 'monthlyEnterprise' -and -not $o365App.wingetId -and @($o365App.office.excluded) -contains 'lync') 'Microsoft 365 Apps: added from the starter set with the default settings' (@($o365, $o365App) | ConvertTo-Json -Compress -Depth 4)
    $o365Again = Invoke-Api '/api/add-winget' @{ items = @(@{ id = 'Microsoft.365Apps.Intune' }) }
    Check (@($o365Again.added).Count -eq 0 -and @($o365Again.skipped) -match 'already in the catalog') 'Microsoft 365 Apps: a second one is refused' ($o365Again | ConvertTo-Json -Compress)
    if ($o365Name) {
        $o365Edit = $o365App; $o365Edit | Add-Member -NotePropertyName office -NotePropertyValue @{ channel = 'current'; architecture = 'x86'; locales = @('de-de'); excluded = @('teams'); sharedActivation = $true; removeOlder = $false } -Force
        $o365Save = Invoke-Api '/api/app-save' @{ originalName = $o365Name; version = (Invoke-Api '/api/app-get' @{ name = $o365Name }).version; app = $o365Edit }
        $o365After = (Invoke-Api '/api/app-get' @{ name = $o365Name }).app
        Check ($o365Save.ok -and $o365After.office.channel -eq 'current' -and $o365After.office.architecture -eq 'x86' -and (@($o365After.office.excluded) -join ',') -eq 'teams' -and $o365After.office.sharedActivation -and -not $o365After.office.removeOlder) 'Microsoft 365 Apps: its settings saved from the editor and read back' (@($o365Save, $o365After.office) | ConvertTo-Json -Compress -Depth 4)
        $o365Row = @((Invoke-Api '/api/catalog').apps | Where-Object { $_.name -eq $o365Name })[0]
        Check ($o365Row.office -and $o365Row.officeText -like 'Current Channel, 32-bit, de-de*without Teams' -and -not $o365Row.msHint) 'Microsoft 365 Apps: the list says its settings in one line' ($o365Row | ConvertTo-Json -Compress -Depth 4)
        $stO = Invoke-Api '/api/package-list' @{ starter = $true }
        Check (@($stO.items | Where-Object { $_.id -eq 'Microsoft.365Apps.Intune' -and $_.inCatalog -eq $o365Name }).Count -eq 1) 'recommended apps: Microsoft 365 Apps shown as already in the catalog' ''
        $o365Off = $o365After; $o365Off | Add-Member -NotePropertyName office -NotePropertyValue $false -Force
        $o365OffSave = Invoke-Api '/api/app-save' @{ originalName = $o365Name; version = (Invoke-Api '/api/app-get' @{ name = $o365Name }).version; app = $o365Off }
        Check ($o365OffSave.ok -and -not (Invoke-Api '/api/app-get' @{ name = $o365Name }).app.office) 'Microsoft 365 Apps: choosing another source takes its settings away' ($o365OffSave | ConvertTo-Json -Compress)
        [void](Invoke-Api '/api/app-remove' @{ name = $o365Name })
    }
    # Duplicate app: a copy with the same groups and settings, under a new name.
    $dupBad = Invoke-Api '/api/app-duplicate' @{ name = "$testName renamed"; newName = "$testName renamed" }
    Check (-not $dupBad.ok) 'duplicate: the same name is refused' ($dupBad | ConvertTo-Json -Compress)
    $dupTwin = Invoke-Api '/api/app-duplicate' @{ name = "$testName renamed"; newName = ("$testName renamed" -replace ' ', '-') }
    Check (-not $dupTwin.ok -and $dupTwin.error -like '*packages folder*') 'duplicate: a name that would share the original''s file and packages folder is refused' ($dupTwin | ConvertTo-Json -Compress)
    $sbApp = (Invoke-Api '/api/app-get' @{ name = "$testName renamed" }).app
    $dup = Invoke-Api '/api/app-duplicate' @{ name = "$testName renamed"; newName = "$testName copy" }
    $dupApp = (Invoke-Api '/api/app-get' @{ name = "$testName copy" }).app
    Check ($dup.ok -and $dupApp -and -not $dupApp.appId -and $dupApp.deploy.detection.type -eq $sbApp.deploy.detection.type -and @($dupApp.requiredFor).Count -eq @($sbApp.requiredFor).Count) 'duplicate: a copy with the settings and groups, no App ID' (@($dup, $dupApp) | ConvertTo-Json -Compress -Depth 4)
    [void](Invoke-Api '/api/app-remove' @{ name = "$testName copy" })
    # Default assignment profile for new apps.
    [void](Invoke-Api '/api/prefs-save' @{ profiles = @(@{ name = 'Standard'; required = @('SG-ZZ-All'); available = @(); exclude = @('SG-ZZ-Kiosk') }) })
    $dpBad = Invoke-Api '/api/prefs-save' @{ defaultProfile = 'Nope' }
    Check (-not $dpBad.ok) 'default profile: one that does not exist is refused' ($dpBad | ConvertTo-Json -Compress)
    $dpOk = Invoke-Api '/api/prefs-save' @{ defaultProfile = 'Standard' }
    Check ($dpOk.ok -and (Invoke-Api '/api/prefs').defaultProfile -eq 'Standard') 'default profile: saved and given back to the page' ($dpOk | ConvertTo-Json -Compress)
    [void](Invoke-Api '/api/prefs-save' @{ profiles = @() })
    Check ((Invoke-Api '/api/prefs').defaultProfile -eq '') 'default profile: cleared when its profile is deleted'
    Check (-not (Invoke-Api '/api/icon-find' @{ name = 'No Such App' }).ok) 'icon: an app not in the catalog is refused'

    $muOff = Invoke-Api '/api/managed-updates' @{ names = @("$testName renamed"); on = $false }
    Check ($muOff.ok -and -not (Invoke-Api '/api/app-get' @{ name = "$testName renamed" }).app.managedUpdates) 'managed updates: turned off again'

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
