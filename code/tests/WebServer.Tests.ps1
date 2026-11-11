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
    foreach ($js in 'core.js', 'apps.js', 'checks.js', 'groups.js', 'scripts.js', 'settings.js', 'app.js') {
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
    Check ((Invoke-Api '/api/job-start' @{ mode = 'Anything'; tenantId = 'x'; clientId = 'y' }).ok -eq $false) 'job-start: only the known actions'
    Check ((Invoke-Api '/api/no-such-thing').error -eq 'unknown') 'an unknown route says so'
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
    $gr = Invoke-Api '/api/batch-groups' @{ mode = 'remove'; names = @($rn); roles = @{ availableFor = @('sg-b') } }
    Check ($gr.ok -and @((Invoke-Api '/api/app-get' @{ name = $rn }).app.availableFor).Count -eq 0) 'batch groups: removed (case does not matter)'
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
