<#
.SYNOPSIS
    The pages that read Microsoft Graph, without a tenant: starts the real
    server in test mode (INTUNE_CATALOG_TEST_GRAPH, see code\Web\WebGraph.ps1),
    where every Graph call is answered from a file this test writes, and
    checks what each page makes of those answers - Checks, Diagnostics, the
    deploy plan, install status, platform scripts, groups, the directory
    search, paging, fallbacks and a refused request.

    Nothing signs in and nothing reaches a tenant. The apps it adds to the
    catalog and the script copy it saves are removed again.

    pwsh -NoProfile -File code/tests/WebGraph.Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$failures = New-Object System.Collections.Generic.List[string]
$passed = 0
function Check([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { $script:passed++ } else { $script:failures.Add("$Name $Detail") ; Write-Host "FAIL: $Name $Detail" -ForegroundColor Red }
}

# IDs and names nobody's tenant or catalog has.
$appLinked = 'aaaaaaaa-0000-4000-8000-000000000001'
$appOnlyIntune = 'aaaaaaaa-0000-4000-8000-000000000002'
$appSameName = 'aaaaaaaa-0000-4000-8000-000000000003'
$appBlocked = 'aaaaaaaa-0000-4000-8000-000000000004'
$blockedName = 'ZZ Graph Blocked'
$groupId = 'bbbbbbbb-0000-4000-8000-000000000001'
$scriptId = 'cccccccc-0000-4000-8000-000000000001'
$newGroupId = 'bbbbbbbb-0000-4000-8000-000000000002'
$oldGroupId = 'bbbbbbbb-0000-4000-8000-000000000003'
$linkedName = 'ZZ Graph Linked'
$sameName = 'ZZ Graph Same Name'
$scriptName = 'ZZ Graph Script'
$relName = 'ZZ Graph Managed'
$relWithdrawName = 'ZZ Graph Managed Withdraw'
$relCurrent = 'eeeeeeee-0000-4000-8000-000000000001'
$relPilot = 'dddddddd-0000-4000-8000-000000000001'
$relPilot2 = 'dddddddd-0000-4000-8000-000000000002'
$relOldName = 'ZZ Graph Managed Old'
$relCur3 = 'eeeeeeee-0000-4000-8000-000000000003'
$relPrevA = 'cccccccc-1111-4000-8000-00000000000a'
$relPrevB = 'cccccccc-1111-4000-8000-00000000000b'
$scriptText = "Write-Output 'hi'"

$answers = [ordered]@{
    # Two pages, to check that every page follows @odata.nextLink.
    'GET beta/deviceAppManagement/mobileApps?$select=id,displayName&$top=999' = @{
        value = @(@{ id = $appLinked; displayName = "$linkedName (new name)" }, @{ id = $appOnlyIntune; displayName = 'ZZ Graph Only In Intune' })
        '@odata.nextLink' = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$skiptoken=page2'
    }
    'GET beta/deviceAppManagement/mobileApps?$skiptoken=page2' = @{ value = @(@{ id = $appSameName; displayName = $sameName }) }
    # Managed updates: renaming the releases on promotion, deleting a withdrawn pilot.
    "PATCH beta/deviceAppManagement/mobileApps/$relPilot" = $null
    "GET beta/deviceAppManagement/mobileApps/$relPilot/installSummary" = @{ installedDeviceCount = 4; failedDeviceCount = 1; pendingInstallDeviceCount = 2 }
    "PATCH beta/deviceAppManagement/mobileApps/$relCurrent" = $null
    "DELETE beta/deviceAppManagement/mobileApps/$relPilot2" = $null
    # Clean-up: B superseded A; A's relationship is taken off B, then A is deleted. Rollback renames B and the current one.
    "GET beta/deviceAppManagement/mobileApps/$relPrevB/relationships" = @{ value = @(
            @{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = $relPrevA; targetType = 'child'; supersedenceType = 'update' },
            @{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = $appLinked; targetType = 'child'; dependencyType = 'autoInstall' }) }
    "POST beta/deviceAppManagement/mobileApps/$relPrevB/updateRelationships" = $null
    "DELETE beta/deviceAppManagement/mobileApps/$relPrevA" = $null
    "PATCH beta/deviceAppManagement/mobileApps/$relPrevB" = $null
    "PATCH beta/deviceAppManagement/mobileApps/$relCur3" = $null
    # The Updates page: Intune's inventory for the app with two superseded versions (current 2.0) -
    # older versions under its name count, a newer or same version and another product ("... Helper") don't.
    "GET beta/deviceManagement/detectedApps?`$filter=startswith(displayName,'$relOldName')&`$select=id,displayName,version,deviceCount&`$top=999" = @{ value = @(
            @{ displayName = $relOldName; version = '1.5'; deviceCount = 3 }, @{ displayName = "$relOldName 1.0 (x64)"; version = '1.0'; deviceCount = 2 },
            @{ displayName = "$relOldName Helper"; version = '0.1'; deviceCount = 9 }, @{ displayName = $relOldName; version = '2.0'; deviceCount = 50 }) }
    # Apps worth adding: the whole inventory - one app the catalog lacks, one it has.
    'GET beta/deviceManagement/detectedApps?$select=id,displayName,version,deviceCount&$top=999' = @{ value = @(
            @{ displayName = 'ZZ Suggest Me'; version = '1.0'; deviceCount = 4 }, @{ displayName = 'ZZ Suggest Me (x64)'; version = '1.1'; deviceCount = 2 },
            @{ displayName = $linkedName; version = '1.0'; deviceCount = 8 }, @{ displayName = 'Windows PC Health Check'; version = '3.6'; deviceCount = 30 }) }
    # Alerts: the email, sent with Graph.
    'POST v1.0/users/reports@contoso.com/sendMail' = $null
    # The install overview's report (one row) and one app's icon.
    'POST beta/deviceManagement/reports/getAppsInstallSummaryReport' = @{
        Schema = @(@{ Column = 'ApplicationId' }, @{ Column = 'DisplayName' }, @{ Column = 'InstalledDeviceCount' }, @{ Column = 'FailedDeviceCount' }, @{ Column = 'PendingInstallDeviceCount' }, @{ Column = 'NotInstalledDeviceCount' }, @{ Column = 'NotApplicableDeviceCount' })
        Values = @(, @($appLinked, 'ZZ Graph Linked', 5, 2, 1, 0, 0))
    }
    "GET beta/deviceAppManagement/mobileApps/$appLinked`?`$select=id,largeIcon" = @{ id = $appLinked; largeIcon = @{ '@odata.type' = '#microsoft.graph.mimeContent'; type = 'image/png'; value = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==' } }
    # The badge's connection check: one app's id.
    'GET beta/deviceAppManagement/mobileApps?$select=id&$top=1' = @{ value = @(@{ id = $appLinked }) }
    # Checks looks up only the groups the catalog uses, by name.
    "GET v1.0/groups?`$filter=displayName in ('SG-ZZ-Exists','SG-ZZ-Missing')&`$select=id,displayName&`$top=999" = @{ value = @(@{ id = $groupId; displayName = 'SG-ZZ-Exists' }) }

    # Install status: beta refuses, v1.0 answers - the fallback.
    'POST beta/deviceManagement/reports/retrieveDeviceAppInstallationStatusReport' = @{ __status = 400; __body = @{ error = @{ code = 'BadRequest'; message = 'not here' } } }
    'POST v1.0/deviceManagement/reports/retrieveDeviceAppInstallationStatusReport' = @{
        Schema = @(@{ Column = 'DeviceName' }, @{ Column = 'UserPrincipalName' }, @{ Column = 'AppInstallState_loc' })
        Values = @(, @('PC-ZZ-1', 'one@example.test', 'Installed')) + @(, @('PC-ZZ-2', 'two@example.test', 'Failed'))
    }

    # Steps (Windows only - they run in Windows PowerShell): what they send is
    # recorded in <answers file>.calls.
    "DELETE beta/deviceAppManagement/mobileApps/$appLinked" = $null
    "DELETE beta/deviceAppManagement/mobileApps/$appBlocked" = @{ __status = 400; __body = @{ error = @{ code = 'BadRequest'; message = "Unable to delete: this app is the parent of another app: $appSameName" } } }
    "GET beta/deviceAppManagement/mobileApps/$appSameName" = @{ id = $appSameName; displayName = $sameName }
    "PATCH v1.0/groups/$groupId" = $null
    # Push groups (Apply): one group exists, one is created, an old assignment goes.
    "GET v1.0/groups?`$filter=displayName eq 'SG-ZZ-Exists'&`$select=id,displayName" = @{ value = @(@{ id = $groupId; displayName = 'SG-ZZ-Exists' }) }
    "GET v1.0/groups?`$filter=displayName eq 'SG-ZZ-Missing'&`$select=id,displayName" = @{ value = @() }
    'POST v1.0/groups' = @{ id = $newGroupId; displayName = 'SG-ZZ-Missing' }
    "GET beta/deviceAppManagement/mobileApps/$appLinked/assignments" = @{ value = @(@{ id = 'as1'; intent = 'required'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $oldGroupId } }) }
    "GET v1.0/groups/$oldGroupId" = @{ displayName = 'SG-ZZ-Old' }
    "POST beta/deviceAppManagement/mobileApps/$appLinked/assign" = $null

    # Platform scripts
    'GET beta/deviceManagement/deviceManagementScripts?$select=id,displayName,description,fileName,runAsAccount,runAs32Bit,enforceSignatureCheck,lastModifiedDateTime' = @{
        value = @(@{ id = $scriptId; displayName = $scriptName; description = 'from the test'; fileName = 'zz.ps1'; runAsAccount = 'system'; runAs32Bit = $false; enforceSignatureCheck = $false; lastModifiedDateTime = '2026-01-02T03:04:05Z' })
    }
    'GET beta/deviceManagement/deviceManagementScripts?$select=id' = @{ value = @(@{ id = $scriptId }) }
    "GET beta/deviceManagement/deviceManagementScripts/$scriptId" = @{
        id = $scriptId; displayName = $scriptName; description = 'from the test'; fileName = 'zz.ps1'; runAsAccount = 'system'; runAs32Bit = $false; enforceSignatureCheck = $false
        lastModifiedDateTime = '2026-01-02T03:04:05Z'; scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptText))
    }
    "GET beta/deviceManagement/deviceManagementScripts/$scriptId/assignments" = @{ value = @(@{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $groupId } }) }
    "GET v1.0/groups/$groupId`?`$select=displayName" = @{ displayName = 'SG-ZZ-Exists' }
    # Run status: the $expand is refused, the plain list works.
    "GET beta/deviceManagement/deviceManagementScripts/$scriptId/deviceRunStates?`$expand=managedDevice" = @{ __status = 400; __body = @{ error = @{ code = 'BadRequest'; message = 'expand not supported' } } }
    "GET beta/deviceManagement/deviceManagementScripts/$scriptId/deviceRunStates" = @{ value = @(@{ id = 'run1'; runState = 'success'; resultMessage = 'hi'; errorCode = 0; lastStateUpdateDateTime = '2026-01-02T03:04:05Z' }) }

    # Groups
    "GET v1.0/groups?`$filter=displayName eq 'SG-ZZ-Exists'&`$select=id,displayName,description" = @{ value = @(@{ id = $groupId; displayName = 'SG-ZZ-Exists'; description = 'test group' }) }
    "GET v1.0/groups/$groupId/members?`$select=id,displayName,userPrincipalName&`$top=999" = @{
        value = @(@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; displayName = 'Zed User'; userPrincipalName = 'zed@example.test' }, @{ '@odata.type' = '#microsoft.graph.device'; id = 'd1'; displayName = 'PC-ZZ-1' })
    }
    "GET v1.0/groups?`$filter=displayName eq 'SG-ZZ-Missing'&`$select=id,displayName,description" = @{ value = @() }
    "GET v1.0/groups?`$filter=displayName eq 'SG-ZZ-Forbidden'&`$select=id,displayName,description" = @{ __status = 403; __body = @{ error = @{ code = 'Authorization_RequestDenied'; message = 'Insufficient privileges to complete the operation.' } } }
    "GET v1.0/groups?`$filter=startswith(displayName,'ZZ')&`$select=id,displayName&`$top=25" = @{ value = @(@{ id = $groupId; displayName = 'ZZ Group' }) }
    "GET v1.0/users?`$filter=startswith(displayName,'ZZ') or startswith(userPrincipalName,'ZZ')&`$select=id,displayName,userPrincipalName&`$top=25" = @{ __status = 403; __body = @{ error = @{ code = 'Authorization_RequestDenied'; message = 'Insufficient privileges' } } }
}
$answersFile = Join-Path ([System.IO.Path]::GetTempPath()) ("webgraph-" + [guid]::NewGuid().ToString('N') + ".json")
Set-Content -LiteralPath $answersFile -Value ($answers | ConvertTo-Json -Depth 20) -Encoding UTF8

$hostExe = (Get-Process -Id $PID).Path
$entry = Join-Path $repoRoot 'IntuneDeployment.ps1'
$outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("webgraph-" + [guid]::NewGuid().ToString('N') + ".out")
$settingsPath = Join-Path $repoRoot "data\intune-deployment-settings.json"
$settingsBackup = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw } else { $null }

$startArgs = @{
    FilePath               = $hostExe
    ArgumentList           = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$entry`"", '-NoBrowser')
    RedirectStandardOutput = $outFile
    PassThru               = $true
}
if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { $startArgs.WindowStyle = 'Hidden' }
$env:INTUNE_CATALOG_TEST_GRAPH = $answersFile
try { $proc = Start-Process @startArgs }
finally { Remove-Item Env:\INTUNE_CATALOG_TEST_GRAPH -ErrorAction SilentlyContinue }

$created = New-Object System.Collections.Generic.List[string]
try {
    $url = $null
    $deadline = (Get-Date).AddSeconds(90)
    while (-not $url -and (Get-Date) -lt $deadline -and -not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $outFile) {
            $m = Select-String -LiteralPath $outFile -Pattern 'Open:\s+(http://127\.0\.0\.1:\d+)/#t=([0-9a-f]{32})' | Select-Object -First 1
            if ($m) { $url = $m.Matches[0].Groups[1].Value; $token = $m.Matches[0].Groups[2].Value }
        }
    }
    Check ([bool]$url) 'the server starts in test mode' "(exited: $($proc.HasExited); output: $(if (Test-Path $outFile) { Get-Content $outFile -Raw }))"
    if (-not $url) { throw 'no server' }
    Check ((Get-Content -LiteralPath $outFile -Raw) -match 'TEST MODE') 'the console says it is in test mode'
    $port = [int]($url -replace '.*:(\d+)$', '$1')

    function Invoke-Api([string]$Path, [hashtable]$Data = @{}) {
        $Data.token = $token
        $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $port)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Compress -Depth 10))
            $head = [Text.Encoding]::ASCII.GetBytes("POST $Path HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
            $stream = $client.GetStream(); $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
            $text = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
            return ($text.Substring($text.IndexOf("`r`n`r`n") + 4) | ConvertFrom-Json)
        }
        finally { $client.Close() }
    }
    function Add-TestApp([hashtable]$App) {
        # Unmanaged unless a test says otherwise (managed updates are the default for new Winget apps since 2.9.0; these tests aren't about them).
        $base = @{ appId = ''; wingetId = 'Vendor.ZZGraph'; managedUpdates = $false; requiredFor = @(); availableFor = @(); uninstallFor = @(); excludeFor = @(); metadata = @{ description = 'from the test' } }
        foreach ($k in $App.Keys) { $base[$k] = $App[$k] }
        $r = Invoke-Api '/api/app-save' @{ originalName = ''; app = $base }
        if ($r.ok) { $created.Add($r.name) }
        return $r
    }

    $state = Invoke-Api '/api/state'
    Check ($state.ok -and $state.configured) 'test mode counts as connected' ($state | ConvertTo-Json -Compress -Depth 3)
    Check ($state.testMode) 'the page is told it is test mode (badge and banner)'
    $tenantApps = Invoke-Api '/api/intune-apps' @{ force = $true }
    Check ($tenantApps.ok -and @($tenantApps.ids).Count -eq 3 -and (@($tenantApps.ids) -contains $appLinked.ToLowerInvariant())) 'intune apps: every app id in the tenant, both pages (the Apps list checks App IDs against them)' ($tenantApps | ConvertTo-Json -Compress)
    $conn = Invoke-Api '/api/connection-status'
    Check ($conn.ok -and $conn.state -eq 'ok' -and $conn.text -eq 'Connected' -and $conn.detail -like '*Intune answered*') 'connection status: one read from Intune works, so the badge says Connected' ($conn | ConvertTo-Json -Compress)
    $settingsBefore = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw } else { $null }
    $favSave = Invoke-Api '/api/prefs-save' @{ favoriteGroups = @('SG-ZZ-Test') }
    $settingsAfter = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw } else { $null }
    Check (-not $favSave.ok -and $settingsAfter -eq $settingsBefore) 'test mode never writes the settings file (its made-up IDs stay in memory)' ($favSave | ConvertTo-Json -Compress)
    Check ((Add-TestApp @{ appName = $linkedName; appId = $appLinked; requiredFor = @('SG-ZZ-Exists'); availableFor = @('SG-ZZ-Missing') }).ok) 'a linked app is added'
    Check ((Add-TestApp @{ appName = $sameName }).ok) 'an app not linked yet is added'

    # Set up this tenant: what it still needs
    $ts = Invoke-Api '/api/tenant-setup'
    Check ($ts.ok -and @($ts.missingGroups) -contains 'SG-ZZ-Missing' -and @($ts.missingGroups) -notcontains 'SG-ZZ-Exists' -and @($ts.notDeployed) -contains $sameName -and @($ts.stale).Count -eq 0 -and @($ts.pushGroups) -contains $linkedName) 'tenant setup: missing groups, apps to deploy, groups to push' ($ts | ConvertTo-Json -Compress -Depth 4)
    $ov = Invoke-Api '/api/install-overview'
    $ovLinked = @($ov.rows) | Where-Object { $_.name -eq $linkedName }
    Check ($ov.ok -and $ovLinked.known -and $ovLinked.installed -eq 5 -and $ovLinked.failed -eq 2 -and $ovLinked.pending -eq 1) 'install overview: counts per app from the summary report' ($ov | ConvertTo-Json -Compress -Depth 4)
    $ic = Invoke-Api '/api/app-icon-intune' @{ name = $linkedName }
    Check ($ic.ok -and $ic.icon.type -eq 'image/png' -and $ic.icon.value -like 'iVBOR*') 'icon: read from Intune' ($ic | ConvertTo-Json -Compress)
    Check (-not (Invoke-Api '/api/app-icon-intune' @{ name = $sameName }).ok) 'icon: an app not in Intune has none to read'

    # Checks: Intune (two pages) and Entra ID
    $checks = Invoke-Api '/api/checks-run'
    $rows = @($checks.findings)
    $by = { param($problem) @($rows | Where-Object { $_.problem -like $problem }) }
    Check ($checks.ok -and $checks.connected) 'checks: Intune and Entra ID were read' ($checks | ConvertTo-Json -Compress -Depth 6)
    Check ((@($checks.notes) -join ' ') -like '*3 app(s) in Intune*') 'checks: every page of Intune''s apps was read (nextLink followed)' (@($checks.notes) -join ' | ')
    $renamed = @(& $by 'Renamed in Intune')
    Check ($renamed.Count -eq 1 -and $renamed[0].catalogName -eq $linkedName -and @($renamed[0].actions) -contains 'RenameFromIntune') 'checks: an app renamed in Intune'
    $missing = @(& $by 'In Intune, not in the catalog')
    $onlyIntune = @($missing | Where-Object { $_.intune -like '*Only In Intune*' })
    Check ($onlyIntune.Count -eq 1 -and @($onlyIntune[0].actions) -contains 'AddToCatalog' -and @($missing | Where-Object { $_.intune -like "*$linkedName*" }).Count -eq 0) 'checks: an app only in Intune, to add to the catalog (and not the linked one)'
    $unlinked = @(& $by 'In Intune, App ID not set')
    Check ($unlinked.Count -eq 1 -and $unlinked[0].catalogName -eq $sameName -and $unlinked[0].data.MatchedId -eq $appSameName) 'checks: a catalog app with the same name in Intune, to link'
    $group = @(& $by '*SG-ZZ-Missing*')
    Check ($group.Count -eq 1 -and @(& $by '*SG-ZZ-Exists*').Count -eq 0) 'checks: a group missing in Entra ID (and not the one that exists)'
    Check ((@($checks.notes) -join ' ') -like '*1 of the 2 group(s) the catalog uses found*') 'checks: only the catalog''s groups were looked up, by name (no full group or user listing)' (@($checks.notes) -join ' | ')

    # Diagnostics
    $dg = Invoke-Api '/api/diagnostics'
    $intuneLines = @($dg.sections[2].lines.text) -join ' | '
    Check ($dg.ok -and $intuneLines -like '*Connected - 3 app(s) in Intune*') 'diagnostics: connected, and how many apps are in Intune' $intuneLines

    # Deploy plan: the same-name app is held back
    $plan = Invoke-Api '/api/deploy-plan' @{ names = @($sameName) }
    $row = @($plan.apps) | Where-Object { $_.name -eq $sameName } | Select-Object -First 1
    Check ($plan.ok -and $row -and -not $row.ready -and $row.reason -like '*already in Intune*') 'deploy plan: an app of the same name in Intune is not created again' ($plan | ConvertTo-Json -Compress -Depth 4)

    # Install status: beta refused, v1.0 answers
    $st = Invoke-Api '/api/install-status' @{ name = $linkedName }
    Check ($st.ok -and @($st.rows).Count -eq 2 -and $st.summary -eq '2 devices: 1 Failed, 1 Installed') 'install status: rows and summary (from v1.0 after beta refused)' ($st | ConvertTo-Json -Compress -Depth 4)
    Check ((@($st.rows | Where-Object { $_.device -eq 'PC-ZZ-2' -and $_.state -eq 'Failed' })).Count -eq 1) 'install status: the device and its state'

    # Platform scripts
    $list = Invoke-Api '/api/scripts'
    $srow = @($list.rows) | Where-Object { $_.displayName -eq $scriptName } | Select-Object -First 1
    Check ($list.ok -and $list.tenantRead -and $srow -and $srow.id -eq $scriptId -and $srow.local -eq 'Not saved here') 'scripts: listed from Intune, not saved locally yet' ($list | ConvertTo-Json -Compress -Depth 4)
    $detail = Invoke-Api '/api/script-get' @{ id = $scriptId }
    Check ($detail.ok -and $detail.script.scriptContent -eq $scriptText -and (@($detail.script.groups) -join ',') -eq 'SG-ZZ-Exists') 'scripts: the text decoded, the assignment as a group name' ($detail | ConvertTo-Json -Compress -Depth 4)
    $runs = Invoke-Api '/api/script-runstatus' @{ id = $scriptId }
    Check ($runs.ok -and @($runs.rows).Count -eq 1) 'scripts: run status (without $expand after it was refused)' ($runs | ConvertTo-Json -Compress -Depth 4)
    $copies = Invoke-Api '/api/scripts-save-local'
    $after = @((Invoke-Api '/api/scripts').rows) | Where-Object { $_.displayName -eq $scriptName } | Select-Object -First 1
    Check ($copies.ok -and $after -and $after.local -ne 'Not saved here') 'scripts: Save local copies keeps a copy' "$($copies | ConvertTo-Json -Compress -Depth 4) / $($after.local)"
    $gone = Invoke-Api '/api/script-delete' @{ name = $scriptName }
    Check ($gone.ok -and $gone.local) 'scripts: the local copy is removed again (nothing sent to Intune)' ($gone | ConvertTo-Json -Compress)

    # Groups
    $g = Invoke-Api '/api/group-get' @{ name = 'SG-ZZ-Exists' }
    Check ($g.ok -and $g.found -and $g.id -eq $groupId -and @($g.members).Count -eq 2) 'groups: found by name, with its members' ($g | ConvertTo-Json -Compress -Depth 4)
    Check ((@($g.members | ForEach-Object { $_.type }) | Sort-Object) -join ',' -eq 'Device,User') 'groups: members typed as user and device'
    Check (@(@($g.uses) | ForEach-Object { $_.app }) -contains $linkedName) 'groups: which catalog apps use it' ($g.uses | ConvertTo-Json -Compress -Depth 4)
    $nf = Invoke-Api '/api/group-get' @{ name = 'SG-ZZ-Missing' }
    Check ($nf.ok -and -not $nf.found) 'groups: a name with no group in Entra ID says so' ($nf | ConvertTo-Json -Compress -Depth 4)
    $denied = Invoke-Api '/api/group-get' @{ name = 'SG-ZZ-Forbidden' }
    Check (-not $denied.ok -and $denied.error -like '*Group.ReadWrite.All*' -and $denied.error -notlike '*DeviceManagementScripts*') 'groups: a refused request names the permission this page needs' ($denied | ConvertTo-Json -Compress)
    $gs = Invoke-Api '/api/groups-status'
    $gsNames = @(@($gs.found) | ForEach-Object { $_.name })
    Check ($gs.ok -and $gs.state -eq 'ok' -and $gsNames -contains 'SG-ZZ-Exists' -and $gsNames -notcontains 'SG-ZZ-Missing' -and (@($gs.found) | Where-Object { $_.name -eq 'SG-ZZ-Exists' }).id -eq $groupId) 'groups status: which catalog groups Entra ID has, looked up by name' ($gs | ConvertTo-Json -Compress -Depth 4)
    $search = Invoke-Api '/api/directory-search' @{ q = 'ZZ' }
    Check ($search.ok -and @($search.hits).Count -eq 1 -and (@($search.notes) -join ' ') -like '*Users couldn''t be searched*') 'directory search: groups found, users refused with a note' ($search | ConvertTo-Json -Compress -Depth 4)

    # The steps that change Intune, against the same stored answers - they run
    # in Windows PowerShell, so only on Windows.
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        function Wait-TestJob([string]$Job) {
            $offset = 0; $deadline = (Get-Date).AddSeconds(120); $log = ''
            while ((Get-Date) -lt $deadline) {
                $p = Invoke-Api '/api/job-poll' @{ job = $Job; offset = $offset }
                if (-not $p.ok) { return @{ Poll = $p; Log = $log } }
                $offset = $p.offset; $log += [string]$p.text
                if ($p.done -and -not $p.text) { return @{ Poll = $p; Log = $log } }
                Start-Sleep -Milliseconds 400
            }
            return @{ Poll = $null; Log = $log }
        }
        $callsFile = "$answersFile.calls"
        $calls = { @(if (Test-Path -LiteralPath $callsFile) { Get-Content -LiteralPath $callsFile -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } }) }

        $push = Invoke-Api '/api/push-start' @{ names = @($linkedName); mode = 'Apply' }
        $pushDone = Wait-TestJob $push.job
        Check ($push.ok -and $pushDone.Poll.result.success) 'step: Push groups (Apply) succeeds' "$($pushDone.Poll.result | ConvertTo-Json -Compress -Depth 5) $($pushDone.Log)"
        $madeGroups = @(& $calls | Where-Object { $_.method -eq 'POST' -and $_.uri -like '*/v1.0/groups' })
        Check ($madeGroups.Count -eq 1 -and ($madeGroups[0].body | ConvertFrom-Json).displayName -eq 'SG-ZZ-Missing') 'step: ... creating the one group that was missing' ((& $calls | ConvertTo-Json -Compress))
        $assign = @(& $calls | Where-Object { $_.method -eq 'POST' -and $_.uri -like "*/mobileApps/$appLinked/assign" }) | Select-Object -First 1
        $targets = @(if ($assign) { @(($assign.body | ConvertFrom-Json).mobileAppAssignments) | ForEach-Object { "$($_.intent):$($_.target.groupId)" } })
        Check ($assign -and ($targets -contains "required:$groupId") -and ($targets -contains "available:$newGroupId") -and -not ($targets -like "*$oldGroupId")) 'step: ... and Intune gets exactly the catalog''s groups (old assignment dropped)' ($targets -join ', ')

        $del = Invoke-Api '/api/delete-intune' @{ name = $linkedName }
        $delDone = Wait-TestJob $del.job
        Check ($del.ok -and $delDone.Poll.result.success) 'step: Delete from Intune succeeds' "$($delDone.Poll | ConvertTo-Json -Compress -Depth 4) $($delDone.Log)"
        Check (@(& $calls | Where-Object { $_.method -eq 'DELETE' -and $_.uri -like "*/mobileApps/$appLinked" }).Count -eq 1) 'step: ... sending exactly one DELETE for that app' ((& $calls | ConvertTo-Json -Compress))
        Check (-not (Invoke-Api '/api/app-get' @{ name = $linkedName }).app.appId) 'step: ... and the catalog forgets its App ID afterwards'

        Check ((Add-TestApp @{ appName = $blockedName; appId = $appBlocked }).ok) 'a second linked app is added'
        $blk = Invoke-Api '/api/delete-intune' @{ name = $blockedName }
        $blkDone = Wait-TestJob $blk.job
        Check ($blk.ok -and -not $blkDone.Poll.result.success -and ([string]$blkDone.Poll.result.error) -like "*dependency*$sameName*") 'step: a delete blocked by a dependency names the app that depends on it' "$($blkDone.Poll.result | ConvertTo-Json -Compress)"
        Check ((Invoke-Api '/api/app-get' @{ name = $blockedName }).app.appId -eq $appBlocked) 'step: ... and the catalog keeps its App ID'

        $ren = Invoke-Api '/api/group-job' @{ mode = 'Rename'; name = 'SG-ZZ-Exists'; groupId = $groupId; newName = 'SG-ZZ-Renamed' }
        $renDone = Wait-TestJob $ren.job
        $patch = @(& $calls | Where-Object { $_.method -eq 'PATCH' -and $_.uri -like "*/groups/$groupId" }) | Select-Object -First 1
        Check ($ren.ok -and $renDone.Poll.result.success -and $patch -and ($patch.body | ConvertFrom-Json).displayName -eq 'SG-ZZ-Renamed') 'step: Rename sends the new name to Entra ID' "$($ren | ConvertTo-Json -Compress) $($renDone.Log)"
        Check (@((Invoke-Api '/api/app-get' @{ name = $linkedName }).app.requiredFor) -contains 'SG-ZZ-Renamed') 'step: ... and the catalog apps that used the group follow'
        Remove-Item -LiteralPath $callsFile -Force -ErrorAction SilentlyContinue
    }
    else { Write-Host '(Steps that change Intune: skipped - they run in Windows PowerShell.)' -ForegroundColor DarkGray }

    # Managed updates: an app with a version in pilot (written as the release step would leave it), promoted and withdrawn.
    $catDir = (Invoke-Api '/api/state').catalogPath
    $relApp = { param($n, $pilotId) [ordered]@{ appId = $relCurrent; appName = $n; wingetId = 'Vendor.ZZManaged'; managedUpdates = $true
            releases = @(@{ version = '2.0'; appId = $pilotId; state = 'pilot'; at = '2026-11-13 10:00' }); requiredFor = @('SG-ZZ-Exists'); availableFor = @(); excludeFor = @(); uninstallFor = @()
            metadata = @{ description = 'managed'; appVersion = '1.0'; installCommand = ''; uninstallCommand = ''; installContext = 'System' } } }
    foreach ($pair in @(@($relName, $relPilot), @($relWithdrawName, $relPilot2))) {
        $file = Join-Path $catDir ($pair[0].Replace(' ', '-') + '.json')
        [System.IO.File]::WriteAllText($file, ((& $relApp $pair[0] $pair[1]) | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        $created.Add($pair[0])
    }
    # Two superseded versions of a third app: 1.0 (oldest) and 1.5, current 2.0.
    $oldApp = & $relApp $relOldName $relPilot
    $oldApp.appId = $relCur3; $oldApp.metadata.appVersion = '2.0'
    $oldApp.releases = @(@{ version = '1.5'; appId = $relPrevB; state = 'previous'; at = '2026-11-01 10:00' }, @{ version = '1.0'; appId = $relPrevA; state = 'previous'; at = '2026-10-01 10:00' })
    [System.IO.File]::WriteAllText((Join-Path $catDir ($relOldName.Replace(' ', '-') + '.json')), ($oldApp | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    $created.Add($relOldName)
    $info = Invoke-Api '/api/release-info' @{ name = $relName }
    Check ($info.ok -and $info.managed -and $info.pilot.version -eq '2.0' -and $info.current -eq '1.0') 'release: the app''s pilot and current versions' ($info | ConvertTo-Json -Compress -Depth 4)
    Check ($info.pilotStatus.ok -and $info.pilotStatus.counts.installed -eq 4 -and $info.pilotStatus.counts.failed -eq 1 -and $info.pilotStatus.action -eq 'hold') 'release: pilot status from Intune - 20 % failed is more than the 5 % allowed, so hold' ($info.pilotStatus | ConvertTo-Json -Compress -Depth 4)
    Check (-not (Invoke-Api '/api/release-start' @{ name = $relName; version = '3.0' }).ok) 'release: refused while a version is in pilot'
    $uo = Invoke-Api '/api/updates-overview'
    $uoRow = @($uo.rows) | Where-Object { $_.name -eq $relName } | Select-Object -First 1
    $uoOld = @($uo.rows) | Where-Object { $_.name -eq $relOldName } | Select-Object -First 1
    Check ($uo.ok -and $uo.connected -and $uoRow.current -eq '1.0' -and $uoRow.pilot.version -eq '2.0' -and $uoRow.pilot.installed -eq 4 -and $uoRow.pilot.action -eq 'hold' -and $uo.summary.inPilot -ge 2 -and $uo.summary.held -ge 1) 'updates page: the pilot release with its counts and the release rule''s verdict' ($uo | ConvertTo-Json -Compress -Depth 5)
    Check ($uoOld -and -not $uoOld.pilot -and (@($uoOld.previous) -join ',') -eq '1.0,1.5' -and @($uo.rows | Where-Object { $_.name -eq $linkedName }).Count -eq 0) 'updates page: superseded versions listed; apps without managed updates left out' ($uoOld | ConvertTo-Json -Compress -Depth 4)
    Check ($uoRow.pilot.reason -like '*Why: 1 device*') 'updates page: a held release says why - the failed devices from the install status report' ($uoRow.pilot | ConvertTo-Json -Compress -Depth 4)
    $sg = Invoke-Api '/api/inventory-suggestions'
    $sgMe = @($sg.suggestions) | Where-Object { $_.name -eq 'ZZ Suggest Me' } | Select-Object -First 1
    Check ($sg.ok -and $sgMe.devices -eq 6 -and @($sg.suggestions | Where-Object { $_.name -eq $linkedName -or $_.name -like 'Windows*' }).Count -eq 0) 'apps worth adding: from the inventory, without catalog apps and parts of Windows' ($sg | ConvertTo-Json -Compress -Depth 4)
    $hc = Invoke-Api '/api/health'
    Check ($hc.ok -and @($hc.checks | Where-Object { $_.level -eq 'ok' -and $_.text -like 'Signing in to Microsoft Graph works*' }).Count -eq 1) 'health: signing in to Graph is checked' ($hc | ConvertTo-Json -Compress -Depth 4)
    $mr = Invoke-Api '/api/monthly-report' @{ month = '2026-01' }
    Check ($mr.ok -and $mr.month -eq '2026-01' -and (Test-Path -LiteralPath $mr.path) -and -not $mr.error -and @($mr.sent).Count -eq 0) 'monthly report: written to the reports folder; nothing sent without alerts' ($mr | ConvertTo-Json -Compress)
    Check ($uoOld.older.devices -eq 5 -and @($uoOld.older.versions).Count -eq 2 -and $uo.summary.olderDevices -eq 5) 'updates page: devices on older versions from the inventory - not newer ones, not another product' ($uoOld.older | ConvertTo-Json -Compress -Depth 4)
    # Release rings (test mode keeps settings in memory only): the release is judged as ring 1 of 2.
    [void](Invoke-Api '/api/prefs-save' @{ releaseRingsText = 'Early adopters: SG-ZZ-Exists' })
    $ri2 = Invoke-Api '/api/release-info' @{ name = $relName }
    Check (@($ri2.rings).Count -eq 2 -and $ri2.rings[1].name -eq 'Early adopters' -and $ri2.pilotStatus.ringCount -eq 2 -and $ri2.pilotStatus.action -eq 'hold') 'release rings: listed, and the release is judged in ring 1 of 2 (still held: too many failed)' ($ri2 | ConvertTo-Json -Compress -Depth 5)
    Check (-not (Invoke-Api '/api/prefs-save' @{ releaseRingsText = 'no colon here' }).ok) 'release rings: a line without "Name:" is refused'
    [void](Invoke-Api '/api/prefs-save' @{ releaseRingsText = '' })
    # Alerts: a test to Teams (kept in memory in test mode) and an email through Graph.
    [void](Invoke-Api '/api/prefs-save' @{ alerts = @{ level = 'attention'; webhookUrl = 'https://example.invalid/workflows/abc'; mailFrom = 'reports@contoso.com'; mailTo = @('it@contoso.com') } })
    $prefsNow = Invoke-Api '/api/prefs'
    Check ($prefsNow.alerts.webhookSet -and -not ($prefsNow | ConvertTo-Json -Depth 6 -Compress).Contains('example.invalid')) 'alerts: the page learns a webhook is saved, never its address'
    $at = Invoke-Api '/api/alert-test'
    Check ($at.ok -and $at.message -like '*Teams*' -and $at.message -like '*email*') 'alerts: the test goes to Teams and by email' ($at | ConvertTo-Json -Compress)
    [void](Invoke-Api '/api/prefs-save' @{ alerts = @{ level = 'off'; clearWebhook = $true; mailFrom = ''; mailTo = @() } })
    # The unattended run (-RunUpdates -PlanOnly) on the same test answers: decides, reports, changes nothing.
    $env:INTUNE_CATALOG_TEST_GRAPH = $answersFile
    try { $runOut = (& $hostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry -RunUpdates -PlanOnly 2>&1 | Out-String) }
    finally { Remove-Item Env:\INTUNE_CATALOG_TEST_GRAPH -ErrorAction SilentlyContinue }
    $reportHtml = [regex]::Match($runOut, 'Report: (.+?\.html)').Groups[1].Value.Trim()
    $runReport = if ($reportHtml -and (Test-Path -LiteralPath ($reportHtml -replace '\.html$', '.json'))) { Get-Content -LiteralPath ($reportHtml -replace '\.html$', '.json') -Raw | ConvertFrom-Json } else { $null }
    $runItem = if ($runReport) { @($runReport.items) | Where-Object { $_.app -eq $relName } | Select-Object -First 1 } else { $null }
    Check ($runReport -and $runReport.planOnly -and $runItem.outcome -eq 'hold' -and (Test-Path -LiteralPath $reportHtml)) 'nightly run (plan only): reports the pilot release as held, in HTML and JSON' $runOut
    Check ((Invoke-Api '/api/app-get' @{ name = $relName }).app.appId -eq $relCurrent) 'nightly run (plan only): nothing changed'
    $cleanItem = if ($runReport) { @($runReport.items) | Where-Object { $_.app -eq $relOldName -and $_.outcome -eq 'cleanup' } | Select-Object -First 1 } else { $null }
    Check ($cleanItem -and $cleanItem.text -like '*1.0*' -and $cleanItem.text -like '*1.5 is kept*') 'nightly run (plan only): reports the old superseded version for clean-up, keeping the newest' $runOut
    $runs = Invoke-Api '/api/update-runs'
    Check ($runs.ok -and @($runs.runs).Count -ge 1 -and -not $runs.running) 'nightly run: listed for Settings, not running any more' ($runs | ConvertTo-Json -Compress -Depth 3)
    $row = @((Invoke-Api '/api/catalog').apps) | Where-Object { $_.name -eq $relName }
    Check ($row.managed -and $row.pilotVersion -eq '2.0') 'release: the Apps list shows the pilot version'
    $prom = Invoke-Api '/api/release-promoted' @{ name = $relName }
    $promApp = (Invoke-Api '/api/app-get' @{ name = $relName }).app
    Check ($prom.ok -and $promApp.appId -eq $relPilot -and $promApp.metadata.appVersion -eq '2.0' -and $promApp.metadata.installCommand -like "*--version '2.0'*" -and (@($promApp.releases | Where-Object { $_.state -eq 'previous' -and $_.appId -eq $relCurrent }).Count -eq 1) -and -not @($promApp.releases | Where-Object { $_.state -eq 'pilot' }).Count) 'release: promoted - the pilot app is current, pinned to 2.0, the old one kept as previous' ($promApp | ConvertTo-Json -Compress -Depth 5)
    $cl = Invoke-Api '/api/release-cleanup' @{ name = $relOldName }
    $clApp = (Invoke-Api '/api/app-get' @{ name = $relOldName }).app
    Check ($cl.ok -and @($cl.removed) -contains '1.0' -and @($cl.kept) -contains '1.5' -and @($clApp.releases).Count -eq 1 -and $clApp.releases[0].appId -eq $relPrevB) 'clean-up: 1.0 taken out of 1.5''s supersedence and deleted; 1.5 kept for rollback' ($cl | ConvertTo-Json -Compress)
    $rb = Invoke-Api '/api/release-rolledback' @{ name = $relOldName }
    $rbApp = (Invoke-Api '/api/app-get' @{ name = $relOldName }).app
    Check ($rb.ok -and $rbApp.appId -eq $relPrevB -and $rbApp.metadata.appVersion -eq '1.5' -and $rbApp.metadata.installCommand -like "*--version '1.5'*" -and @($rbApp.releases | Where-Object { $_.appId -eq $relCur3 -and $_.state -eq 'previous' }).Count -eq 1) 'rollback: 1.5 is current again, pinned; 2.0 kept as superseded' ($rbApp | ConvertTo-Json -Compress -Depth 5)
    Check (-not (Invoke-Api '/api/release-cleanup' @{ name = $relOldName }).removed.Count) 'clean-up: nothing more to delete with one superseded version'
    $wd = Invoke-Api '/api/release-withdrawn' @{ name = $relWithdrawName }
    $wdApp = (Invoke-Api '/api/app-get' @{ name = $relWithdrawName }).app
    Check ($wd.ok -and $wd.deleted -and $wdApp.appId -eq $relCurrent -and -not @($wdApp.releases).Count) 'release: withdrawn - deleted from Intune, the current release stays' ($wd | ConvertTo-Json -Compress)

    foreach ($n in @($created)) {
        $r = Invoke-Api '/api/app-remove' @{ name = $n }
        Check ($r.ok) "the test app '$n' is removed again" ($r | ConvertTo-Json -Compress)
        if ($r.ok) { [void]$created.Remove($n) }
    }
    [void](Invoke-Api '/api/quit')
    Check ($proc.WaitForExit(15000)) 'quit stops the server'
}
finally {
    if (-not $proc.HasExited) {
        foreach ($n in @($created)) { try { [void](Invoke-Api '/api/app-remove' @{ name = $n }) } catch { } }
        try { $proc.Kill() } catch { }
    }
    if ($null -ne $settingsBackup) { Set-Content -LiteralPath $settingsPath -Value $settingsBackup -Encoding UTF8 } else { Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $outFile, $answersFile, "$answersFile.calls" -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -eq 0) { Write-Host "PASSED: $passed check(s)." -ForegroundColor Green; exit 0 }
Write-Host "FAILED: $($failures.Count) of $($passed + $failures.Count)." -ForegroundColor Red
exit 1
