<#
.SYNOPSIS
    Round trips against a fake Intune that remembers (2.38.44): what the app
    sends comes back on the next read, as Intune would give it back - so a
    send followed by Checks and Pull must find nothing to change. The kind of
    mismatch this catches: a detection script given a second BOM, the
    architectures in another order, missing return codes against Intune's
    defaults, Featured or supersedence lost on the way.

    Also the release flows end to end (the server runs their steps and
    completion), and a step left finished by a stopped server being completed
    at the next start.

    Starts the real server in test mode (INTUNE_CATALOG_TEST_GRAPH with
    "__memory", see code\Web\WebGraph.ps1). Nothing signs in and nothing
    reaches a tenant; the apps it adds are removed again.

    pwsh -NoProfile -File code/tests/RoundTrip.Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$failures = New-Object System.Collections.Generic.List[string]
$passed = 0
function Check([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { $script:passed++ } else { $script:failures.Add("$Name $Detail"); Write-Host "FAIL: $Name $Detail" -ForegroundColor Red }
}

# IDs and names nobody's tenant or catalog has.
$idScript = 'abababab-0000-4000-8000-000000000001'
$idFile = 'abababab-0000-4000-8000-000000000002'
$idOld = 'abababab-0000-4000-8000-000000000003'
$idWinget = 'abababab-0000-4000-8000-000000000004'
$idStore = 'abababab-0000-4000-8000-000000000005'
$idOffice = 'abababab-0000-4000-8000-000000000006'
$idRelCur = 'abababab-0000-4000-8000-000000000011'
$idRelPilot = 'abababab-0000-4000-8000-000000000012'
$idWdCur = 'abababab-0000-4000-8000-000000000021'
$idWdPilot = 'abababab-0000-4000-8000-000000000022'
$idResume = 'abababab-0000-4000-8000-000000000031'
$groupId = 'bcbcbcbc-0000-4000-8000-000000000001'
$nScript = 'ZZ RT Script'; $nFile = 'ZZ RT File'; $nWinget = 'ZZ RT Winget'; $nStore = 'ZZ RT Store'; $nOffice = 'ZZ RT Office'
$nRel = 'ZZ RT Release'; $nWd = 'ZZ RT Withdraw'; $nResume = 'ZZ RT Resume'
$group = 'SG-ZZ-RT'
$storeId = '9WZDNCRFJ3PZ'

# Non-ASCII text built from codes - the test files stay ASCII (Windows PowerShell reads them as cp1252).
$uml = 'B' + [char]0xFC + 'ro ' + [char]0x00AE
$win32 = { param($id, $name) @{ id = $id; displayName = $name; '@odata.type' = '#microsoft.graph.win32LobApp' } }
$answers = [ordered]@{
    # The fake Intune remembers what it is sent (Get-WebTestGraphMemoryAnswer).
    '__memory' = $true
    "GET beta/deviceAppManagement/mobileApps/$idScript" = (& $win32 $idScript $nScript)
    "GET beta/deviceAppManagement/mobileApps/$idFile" = (& $win32 $idFile $nFile)
    "GET beta/deviceAppManagement/mobileApps/$idOld" = (& $win32 $idOld 'ZZ RT Old')
    "GET beta/deviceAppManagement/mobileApps/$idWinget" = (& $win32 $idWinget $nWinget)
    "GET beta/deviceAppManagement/mobileApps/$idStore" = @{ id = $idStore; displayName = $nStore; '@odata.type' = '#microsoft.graph.winGetApp'; packageIdentifier = $storeId }
    "GET beta/deviceAppManagement/mobileApps/$idOffice" = @{ id = $idOffice; displayName = $nOffice; '@odata.type' = '#microsoft.graph.officeSuiteApp' }
    "GET beta/deviceAppManagement/mobileApps/$idRelCur" = (& $win32 $idRelCur $nRel)
    "GET beta/deviceAppManagement/mobileApps/$idRelPilot" = (& $win32 $idRelPilot "$nRel 2.0 (pilot)")
    "GET beta/deviceAppManagement/mobileApps/$idWdCur" = (& $win32 $idWdCur $nWd)
    "GET beta/deviceAppManagement/mobileApps/$idWdPilot" = (& $win32 $idWdPilot "$nWd 2.0 (pilot)")
    "DELETE beta/deviceAppManagement/mobileApps/$idWdPilot" = $null
    # The tenant's apps (the plan, Checks) and groups.
    'GET beta/deviceAppManagement/mobileApps?$select=id,displayName&$top=999' = @{ value = @(
            @{ id = $idScript; displayName = $nScript }, @{ id = $idFile; displayName = $nFile }, @{ id = $idOld; displayName = 'ZZ RT Old' }, @{ id = $idWinget; displayName = $nWinget },
            @{ id = $idStore; displayName = $nStore }, @{ id = $idOffice; displayName = $nOffice }, @{ id = $idRelCur; displayName = $nRel }, @{ id = $idRelPilot; displayName = "$nRel 2.0 (pilot)" },
            @{ id = $idWdCur; displayName = $nWd }, @{ id = $idWdPilot; displayName = "$nWd 2.0 (pilot)" }) }
    "GET v1.0/groups?`$filter=displayName in ('$group')&`$select=id,displayName&`$top=999" = @{ value = @(@{ id = $groupId; displayName = $group }) }
    "GET v1.0/groups?`$filter=displayName eq '$group'&`$select=id,displayName" = @{ value = @(@{ id = $groupId; displayName = $group }) }
    "GET v1.0/groups/$groupId" = @{ id = $groupId; displayName = $group }
    'TOKEN roles' = @('DeviceManagementApps.ReadWrite.All', 'Group.ReadWrite.All')
}
# Every app: no relationships, its catalog group assigned (Required) - and assigning works.
foreach ($id in $idScript, $idFile, $idOld, $idWinget, $idStore, $idOffice, $idRelCur, $idRelPilot, $idWdCur, $idWdPilot) {
    $answers["GET beta/deviceAppManagement/mobileApps/$id/relationships"] = @{ value = @() }
    $answers["GET beta/deviceAppManagement/mobileApps/$id/assignments"] = @{ value = @(@{ id = "as-$id"; intent = 'required'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $groupId } }) }
    $answers["POST beta/deviceAppManagement/mobileApps/$id/assign"] = $null
}
$answersFile = Join-Path ([System.IO.Path]::GetTempPath()) ("roundtrip-" + [guid]::NewGuid().ToString('N') + ".json")
Set-Content -LiteralPath $answersFile -Value ($answers | ConvertTo-Json -Depth 20) -Encoding UTF8
$callsFile = "$answersFile.calls"
$calls = { @(if (Test-Path -LiteralPath $callsFile) { Get-Content -LiteralPath $callsFile -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } }) }

$hostExe = (Get-Process -Id $PID).Path
$entry = Join-Path $repoRoot 'IntuneDeployment.ps1'
$settingsPath = Join-Path $repoRoot "data\intune-deployment-settings.json"
$settingsBackup = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw } else { $null }
$script:proc = $null; $script:port = 0; $script:token = ''
$outFiles = New-Object System.Collections.Generic.List[string]

function Start-TestServer {
    $out = Join-Path ([System.IO.Path]::GetTempPath()) ("roundtrip-" + [guid]::NewGuid().ToString('N') + ".out")
    $outFiles.Add($out)
    $startArgs = @{ FilePath = $hostExe; ArgumentList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$entry`"", '-NoBrowser'); RedirectStandardOutput = $out; PassThru = $true }
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { $startArgs.WindowStyle = 'Hidden' }
    $env:INTUNE_CATALOG_TEST_GRAPH = $answersFile
    try { $script:proc = Start-Process @startArgs }
    finally { Remove-Item Env:\INTUNE_CATALOG_TEST_GRAPH -ErrorAction SilentlyContinue }
    $deadline = (Get-Date).AddSeconds(90); $url = $null
    while (-not $url -and (Get-Date) -lt $deadline -and -not $script:proc.HasExited) {
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $out) {
            $m = Select-String -LiteralPath $out -Pattern 'Open:\s+(http://127\.0\.0\.1:\d+)/#t=([0-9a-f]{32})' | Select-Object -First 1
            if ($m) { $url = $m.Matches[0].Groups[1].Value; $script:token = $m.Matches[0].Groups[2].Value }
        }
    }
    if (-not $url) { throw "no server: $(if (Test-Path $out) { Get-Content $out -Raw })" }
    $script:port = [int]($url -replace '.*:(\d+)$', '$1')
}
function Invoke-Api([string]$Path, [hashtable]$Data = @{}) {
    $Data.token = $script:token
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $script:port)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Compress -Depth 12))
        $head = [Text.Encoding]::ASCII.GetBytes("POST $Path HTTP/1.1`r`nHost: 127.0.0.1:$($script:port)`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
        $stream = $client.GetStream(); $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        $text = (New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)).ReadToEnd()
        return ($text.Substring($text.IndexOf("`r`n`r`n") + 4) | ConvertFrom-Json)
    }
    finally { $client.Close() }
}
function Wait-TestJob($Started) {
    # Follows a step to its end, and the next one a flow's completion started (after.nextJob), as the page does.
    if (-not $Started.ok) { return @{ Poll = $null; Log = [string]$Started.error; Jobs = 0 } }
    $job = [string]$Started.job; $offset = 0; $log = ''; $jobs = 1
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        $p = Invoke-Api '/api/job-poll' @{ job = $job; offset = $offset }
        if (-not $p.ok) { return @{ Poll = $p; Log = $log; Jobs = $jobs } }
        $offset = $p.offset; $log += [string]$p.text
        if ($p.done -and -not $p.text) {
            if ($p.result.success -and $p.after -and $p.after.nextJob) { $job = [string]$p.after.nextJob; $offset = 0; $jobs++; continue }
            return @{ Poll = $p; Log = $log; Jobs = $jobs }
        }
        Start-Sleep -Milliseconds 400
    }
    return @{ Poll = $null; Log = $log; Jobs = $jobs }
}
$created = New-Object System.Collections.Generic.List[string]
function Add-TestApp([hashtable]$App) {
    # Written as the catalog keeps it (metadata.detectionRule and all), the way an earlier send or Pull leaves it.
    $base = [ordered]@{ appName = ''; appId = ''; wingetId = ''; managedUpdates = $false; requiredFor = @($group); availableFor = @(); uninstallFor = @(); excludeFor = @() }
    foreach ($k in $App.Keys) { $base[$k] = $App[$k] }
    [System.IO.File]::WriteAllText((Join-Path $script:catDir ($base.appName.Replace(' ', '-') + '.json')), ($base | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    $created.Add($base.appName)
    $r = Invoke-Api '/api/app-get' @{ name = $base.appName }
    return @{ ok = [bool]($r.ok -and $r.app) }
}
function Get-Findings([string[]]$Names) {
    # Checks' detail stage (Intune's settings, groups, dependencies) for these apps.
    $d = Wait-TestJob (Invoke-Api '/api/checks-details' @{ names = $Names })
    return @{ Rows = @($(if ($d.Poll -and $d.Poll.after) { $d.Poll.after.findings })); Done = $d }
}

try {
    Start-TestServer
    $script:catDir = (Invoke-Api '/api/state').catalogPath; $catDir = $script:catDir

    # ---- send, read back, compare ---------------------------------------------------------------------
    $scriptRule = @{ Type = 'Script'; Script_Content = "# $uml`r`n`$found = Get-ItemProperty -Path 'HKLM:\SOFTWARE\ZZ' -ErrorAction SilentlyContinue`r`nif (`$found) { Write-Output 'Installed' }" }
    Check ((Add-TestApp @{ appName = $nScript; appId = $idScript; metadata = @{
                    description = "Detects $uml"; publisher = 'ZZ Vendor'; owner = 'Team ZZ'; notes = "line one`nline two"; appVersion = '1.0'; isFeatured = $true
                    installCommand = 'install.cmd'; uninstallCommand = 'uninstall.cmd'; installContext = 'System'; architecture = 'x64,x86'; minOSKey = 'W10_21H2'
                    detectionRule = $scriptRule; returnCodes = @(); supersedes = @() } }).ok) 'an own package with a non-ASCII script detection, x64 before x86 and no return codes is added'
    Check ((Add-TestApp @{ appName = $nFile; appId = $idFile; metadata = @{
                    description = 'file rule'; publisher = 'ZZ Vendor'; appVersion = '3.1'; installCommand = 'setup.exe /S'; uninstallCommand = 'uninstall.exe /S'; installContext = 'User'; architecture = 'x64'
                    detectionRule = @{ Type = 'File'; File_Path = 'C:\Program Files\ZZ'; File_Name = 'zz.exe'; File_Check32Bit = $false; File_DetectionType = 'version'; File_Operator = 'greaterThanOrEqual'; File_DetectionValue = '3.1' }
                    returnCodes = @(@{ returnCode = 0; type = 'success' }, @{ returnCode = 3010; type = 'softReboot' })
                    supersedes = @(@{ appId = $idOld; name = 'ZZ RT Old'; type = 'replace' }) } }).ok) 'an own package with a file rule, its own return codes and a supersedence is added'
    Check ((Add-TestApp @{ appName = $nWinget; appId = $idWinget; wingetId = 'Vendor.ZZRT'; managedUpdates = $true; metadata = @{ description = 'winget'; publisher = 'ZZ Vendor'; appVersion = '2.0'; installContext = 'System'; architecture = 'x64' } }).ok) 'a Winget app with managed updates is added'
    Check ((Add-TestApp @{ appName = $nStore; appId = $idStore; wingetId = $storeId; metadata = @{ description = 'store'; publisher = 'Microsoft'; owner = 'Team ZZ'; developer = 'Dev ZZ'; notes = 'store notes'; isFeatured = $true } }).ok) 'a Store app is added'
    Check ((Add-TestApp @{ appName = $nOffice; appId = $idOffice; office = @{ channel = 'current'; architecture = 'x64'; locales = @(); excluded = @('groove', 'lync'); sharedActivation = $false; removeOlder = $true }; metadata = @{ description = 'office'; owner = 'Team ZZ' } }).ok) 'Microsoft 365 Apps is added'

    $sendNames = @($nScript, $nFile, $nWinget, $nStore, $nOffice)
    foreach ($n in $sendNames) {
        $s = Wait-TestJob (Invoke-Api '/api/deploy-start' @{ name = $n; metadataOnly = $true })
        Check ($s.Poll -and $s.Poll.result.success -and -not ($s.Poll.after -and $s.Poll.after.ok -eq $false)) "send: $n's settings are sent" "$($s.Poll | ConvertTo-Json -Compress -Depth 5) $($s.Log)"
    }
    $f = Get-Findings $sendNames
    $diffs = @($f.Rows | Where-Object { [string]$_.area -in 'Metadata', 'Dependencies' })
    Check ($f.Done.Poll.result.success -and $diffs.Count -eq 0) 'round trip: Checks finds nothing to change right after the send' "$(($diffs | ConvertTo-Json -Compress -Depth 5)) $($f.Done.Log)"
    $pull = Wait-TestJob (Invoke-Api '/api/pull-start' @{ names = $sendNames })
    $pa = if ($pull.Poll) { $pull.Poll.after } else { $null }
    Check ($pa -and @($pa.review).Count -eq 0 -and @($pa.failed).Count -eq 0) 'round trip: Pull has nothing to ask about right after the send' "$($pa | ConvertTo-Json -Compress -Depth 6) $($pull.Log)"
    $f2 = Get-Findings $sendNames
    $diffs2 = @($f2.Rows | Where-Object { [string]$_.area -in 'Metadata', 'Dependencies' })
    Check ($diffs2.Count -eq 0) 'round trip: ... nor after Pull took Intune''s values' ($diffs2 | ConvertTo-Json -Compress -Depth 5)
    $after = (Invoke-Api '/api/app-get' @{ name = $nScript }).app
    $scr = [string]$after.deploy.detection.script
    # Ordinal: a culture compare skips a BOM (U+FEFF) as if it weren't there.
    Check ($scr.Length -gt 0 -and $scr[0] -eq [char]'#' -and $scr.IndexOf($uml, [StringComparison]::Ordinal) -ge 0) 'round trip: the script comes back as it was sent - no BOM in it, the text whole' $scr
    $afterFile = (Invoke-Api '/api/app-get' @{ name = $nFile }).app
    Check (@($afterFile.deploy.supersedes | Where-Object { $_.appId -eq $idOld -and $_.type -eq 'replace' }).Count -eq 1) 'round trip: supersedence comes back as it was set' ($afterFile.deploy | ConvertTo-Json -Compress -Depth 5)

    # Sent again after Pull: one BOM, never two.
    $s2 = Wait-TestJob (Invoke-Api '/api/deploy-start' @{ name = $nScript; metadataOnly = $true })
    $patch = @(& $calls | Where-Object { $_.method -eq 'PATCH' -and $_.uri -like "*/mobileApps/$idScript" }) | Select-Object -Last 1
    $det = if ($patch) { @(($patch.body | ConvertFrom-Json).detectionRules)[0] } else { $null }
    $bytes = if ($det) { [Convert]::FromBase64String([string]$det.scriptContent) } else { @() }
    Check ($s2.Poll.result.success -and $bytes.Count -gt 6 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF -and -not ($bytes[3] -eq 0xEF -and $bytes[4] -eq 0xBB -and $bytes[5] -eq 0xBF)) 'round trip: a non-ASCII script sent again after Pull has one BOM, not two' "$(if ($bytes.Count) { ($bytes[0..5] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' })"
    $storePatch = @(& $calls | Where-Object { $_.method -eq 'PATCH' -and $_.uri -like "*/mobileApps/$idStore" }) | Select-Object -Last 1
    $sb = if ($storePatch) { $storePatch.body | ConvertFrom-Json } else { $null }
    Check ($sb -and $sb.owner -eq 'Team ZZ' -and $sb.developer -eq 'Dev ZZ' -and $sb.notes -eq 'store notes' -and $sb.isFeatured -eq $true) 'send: a Store app gets its owner, developer, notes and Featured flag' ($storePatch.body)

    # Microsoft 365 Apps changed in the portal: Checks sees it, Pull takes it.
    $mem = Get-Content -LiteralPath "$answersFile.memory.json" -Raw | ConvertFrom-Json
    $mem.$idOffice.app.updateChannel = 'monthlyEnterprise'
    [System.IO.File]::WriteAllText("$answersFile.memory.json", ($mem | ConvertTo-Json -Depth 30 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    $f3 = Get-Findings @($nOffice)
    Check (@($f3.Rows | Where-Object { $_.problem -eq 'Microsoft 365 settings differ' }).Count -eq 1) 'Microsoft 365 Apps: a channel changed in the portal is a Checks finding' ($f3.Rows | ConvertTo-Json -Compress -Depth 5)
    $pull3 = Wait-TestJob (Invoke-Api '/api/pull-start' @{ names = @($nOffice) })
    $rv = if ($pull3.Poll) { $pull3.Poll.after } else { $null }
    $offRow = @($(if ($rv) { $rv.review }) | ForEach-Object { $_.diffs } | Where-Object { $_.field -eq 'Microsoft 365 settings' })
    Check ($rv -and $rv.pending -and $offRow.Count -eq 1) 'Microsoft 365 Apps: Pull asks about its settings' ($rv | ConvertTo-Json -Compress -Depth 6)
    if ($rv -and $rv.pending) {
        $ap = Invoke-Api '/api/pull-apply' @{ pending = $rv.pending; keep = @{ $nOffice = @() } }
        $off = (Invoke-Api '/api/app-get' @{ name = $nOffice }).app.office
        Check ($ap.ok -and [string]$off.channel -eq 'monthlyEnterprise') 'Microsoft 365 Apps: ... and takes Intune''s channel' "$($ap | ConvertTo-Json -Compress) $($off | ConvertTo-Json -Compress)"
    }

    # ---- release flows, run by the server ---------------------------------------------------------------
    $relApp = { param($n, $cur, $pilot) [ordered]@{ appId = $cur; appName = $n; wingetId = 'Vendor.ZZRelease'; managedUpdates = $true
            releases = @(@{ version = '2.0'; appId = $pilot; state = 'pilot'; at = '2026-11-20 10:00'; ring = 0 }); requiredFor = @($group); availableFor = @(); excludeFor = @(); uninstallFor = @()
            metadata = [ordered]@{ description = 'managed'; appVersion = '1.0'; installCommand = ''; uninstallCommand = ''; installContext = 'System'; architecture = 'x64' } } }
    foreach ($t in @(@($nRel, $idRelCur, $idRelPilot), @($nWd, $idWdCur, $idWdPilot))) {
        [System.IO.File]::WriteAllText((Join-Path $catDir ($t[0].Replace(' ', '-') + '.json')), ((& $relApp $t[0] $t[1] $t[2]) | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        $created.Add($t[0])
    }
    $pr = Wait-TestJob (Invoke-Api '/api/release-flow' @{ name = $nRel; flow = 'promote' })
    $prApp = (Invoke-Api '/api/app-get' @{ name = $nRel }).app
    Check ($pr.Jobs -eq 2 -and $pr.Poll.after.flowDone -and $pr.Poll.after.ok -ne $false) 'promote: one call - the server runs both steps and records it' "jobs=$($pr.Jobs) $($pr.Poll | ConvertTo-Json -Compress -Depth 5) $($pr.Log)"
    Check ($prApp.appId -eq $idRelPilot -and $prApp.metadata.appVersion -eq '2.0' -and @($prApp.releases | Where-Object { $_.state -eq 'previous' -and $_.appId -eq $idRelCur }).Count -eq 1 -and -not @($prApp.releases | Where-Object { $_.state -eq 'pilot' }).Count) 'promote: the pilot is the current release, the old one kept as previous' ($prApp | ConvertTo-Json -Compress -Depth 5)
    $assignNew = @(& $calls | Where-Object { $_.method -eq 'POST' -and $_.uri -like "*/mobileApps/$idRelPilot/assign" }) | Select-Object -Last 1
    $assignOld = @(& $calls | Where-Object { $_.method -eq 'POST' -and $_.uri -like "*/mobileApps/$idRelCur/assign" }) | Select-Object -Last 1
    $newTargets = @(if ($assignNew) { @(($assignNew.body | ConvertFrom-Json).mobileAppAssignments) | ForEach-Object { "$($_.intent):$($_.target.groupId)" } })
    Check ($newTargets -contains "required:$groupId" -and $assignOld -and @(($assignOld.body | ConvertFrom-Json).mobileAppAssignments).Count -eq 0) 'promote: the new release gets the app''s groups, the old one none' "new=$($newTargets -join ',') old=$($assignOld.body)"
    $wd = Wait-TestJob (Invoke-Api '/api/release-flow' @{ name = $nWd; flow = 'withdraw' })
    $wdApp = (Invoke-Api '/api/app-get' @{ name = $nWd }).app
    Check ($wd.Poll.after.flowDone -and $wd.Poll.after.deleted -and $wdApp.appId -eq $idWdCur -and -not @($wdApp.releases).Count -and @($wdApp.blockedVersions) -contains '2.0') 'withdraw: one call - unassigned, deleted, forgotten, not released again by itself' "$($wd.Poll | ConvertTo-Json -Compress -Depth 5) $($wd.Log)"

    # ---- a step finished while the server was down ------------------------------------------------------
    Check ((Add-TestApp @{ appName = $nResume; appId = $idResume; metadata = @{ description = 'resume' } }).ok) 'an app for the restart test is added'
    [void](Invoke-Api '/api/quit')
    Check ($script:proc.WaitForExit(20000)) 'the server stops'
    $jobDir = Join-Path ([System.IO.Path]::GetTempPath().TrimEnd('/', '\')) 'IntuneAppCatalog-jobs'
    [void](New-Item -ItemType Directory -Path $jobDir -Force)
    $rid = [guid]::NewGuid().ToString('N')
    $res = Join-Path $jobDir "result-$rid.json"
    Set-Content -LiteralPath $res -Value (@{ success = $true; error = '' } | ConvertTo-Json -Compress) -Encoding UTF8
    $logFile = Join-Path $jobDir "log-$rid.log"; Set-Content -LiteralPath $logFile -Value '' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $jobDir "$rid.json") -Value (@{ id = $rid; mode = "Delete $nResume from Intune"; step = 'deleteapp'; result = $res; log = $logFile; cleanup = @(); after = @{ Kind = 'deleted'; AppName = $nResume }; historyApps = @($nResume); pid = 0; procStart = 0; owner = 0; started = (Get-Date).ToString('o') } | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8
    Start-TestServer
    $deadline = (Get-Date).AddSeconds(30)
    do { Start-Sleep -Milliseconds 700; $ra = (Invoke-Api '/api/app-get' @{ name = $nResume }).app } while ($ra.appId -and (Get-Date) -lt $deadline)
    Check (-not $ra.appId -and -not (Test-Path -LiteralPath (Join-Path $jobDir "$rid.json"))) 'restart: a step that ended while the server was down is finished at the next start (its App ID cleared)' "$($ra.appId) $((Invoke-Api '/api/log' @{ from = 0 }) | ConvertTo-Json -Compress -Depth 4)"

    foreach ($n in @($created)) { $r = Invoke-Api '/api/app-remove' @{ name = $n }; if ($r.ok) { [void]$created.Remove($n) } }
    Check ($created.Count -eq 0) 'the test apps are removed again' ($created -join ', ')
    [void](Invoke-Api '/api/quit')
    Check ($script:proc.WaitForExit(15000)) 'quit stops the server'
}
finally {
    if ($script:proc -and -not $script:proc.HasExited) {
        foreach ($n in @($created)) { try { [void](Invoke-Api '/api/app-remove' @{ name = $n }) } catch { } }
        try { $script:proc.Kill() } catch { }
    }
    if ($null -ne $settingsBackup) { Set-Content -LiteralPath $settingsPath -Value $settingsBackup -Encoding UTF8 } else { Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (@($outFiles) + @($answersFile, $callsFile, "$answersFile.memory.json")) -Force -ErrorAction SilentlyContinue
}

if ($failures.Count) { Write-Host "FAILED: $($failures.Count) of $($passed + $failures.Count) check(s)." -ForegroundColor Red; exit 1 }
Write-Host "PASSED: $passed check(s)." -ForegroundColor Green
