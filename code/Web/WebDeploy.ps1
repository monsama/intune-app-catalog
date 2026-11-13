# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    What the Apps list changes in Intune: the deploy plan, Deploy, Push
    groups, Package, Pull, Delete from Intune, Clear App ID and Install
    status. The routes are in WebApi.ps1.
#>

function Global:Get-WebDeployPlan {
    <#
      What Deploy would do for the chosen apps, before anything runs: in
      dependency order, each app ready or skipped with the reason.
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ })
    $chosen = @($catalog.Apps | Where-Object { $names -contains $_.appName })
    if ($chosen.Count -eq 0) { return @{ ok = $false; error = 'Choose one or more apps first.' } }
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $order = Get-DependencyOrderedApps -Apps $chosen
    $index = Get-PackageFolderIndex -Root (Get-AppFolder -Kind Packages)
    # App IDs the connected tenant doesn't have (a catalog copied from another tenant): an update would fail.
    $tenantIds = $null
    if (@($chosen | Where-Object { $_.appId }).Count) {
        $t = Get-WebIntuneApps @{}
        if ($t.ok) { $tenantIds = @{}; foreach ($i in @($t.ids)) { $tenantIds[[string]$i] = $true } }
    }
    # Settings > Automatic checks: before creating an app, look for one of the
    # same name already in Intune - creating a second is the mistake to stop.
    $inIntune = @{}
    $note = ''
    if ($Global:App.CheckIntuneOnDeployOpen -and @($chosen | Where-Object { -not $_.appId }).Count) {
        $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action {
            param($Graph)
            $names = New-Object System.Collections.Generic.List[object]
            $uri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$select=id,displayName&$top=999'
            while ($uri) { $page = & $Graph $uri; foreach ($v in @($page.value)) { $names.Add($v) }; $uri = [string]$page.'@odata.nextLink' }
            , $names.ToArray()
        }
        if ($read.ok) { foreach ($v in @($read.value)) { $inIntune[([string]$v.displayName).Trim().ToLowerInvariant()] = [string]$v.id } }
        else { $note = "Couldn't look for apps of the same name in Intune: $($read.error)" }
    }
    $plan = foreach ($a in @($order.Ordered)) {
        $unc = Test-AppIsUncommon -App $a
        $pkg = Resolve-AppPackagePath -AppName $a.appName -Uncommon $unc -Index $index -PackagePath $a.packagePath
        $reason = ''
        if ($a.appId -and $tenantIds -and -not $tenantIds.ContainsKey(([string]$a.appId).ToLowerInvariant())) { $reason = "Its App ID isn't in this tenant (copied from another?) - clear it first: Catalog > Set up this tenant." }
        # A same-name app in Intune first: building a package would only lead to a duplicate.
        elseif (-not $a.appId -and $inIntune.ContainsKey(([string]$a.appName).Trim().ToLowerInvariant())) { $reason = 'An app with this name is already in Intune - link it (Checks > Link) instead of creating a second one.' }
        elseif (-not $pkg.Found) {
            $reason = if ($unc) { "No package (.intunewin) yet - build it with More > Package." } else { "The shared Winget package (init.intunewin) isn't built yet - Settings > Packaging builds it." }
        }
        elseif ($a.managedUpdates -and $a.wingetId -and -not (Test-ReleaseVersionText ([string]$(if ($a.metadata) { $a.metadata.appVersion })))) { $reason = "Managed updates deploy a fixed version - set its App version first (More > Take winget's version)." }
        elseif ($unc -and -not ($a.metadata -and $a.metadata.detectionRule)) { $reason = "No detection rule yet - an app with its own package needs one (the editor's Deploy settings)." }
        [ordered]@{ name = $a.appName; update = [bool]$a.appId; ready = (-not $reason); reason = $reason; deps = @($(if ($a.metadata) { @($a.metadata.dependencies) | Where-Object { $_ } | ForEach-Object { [string]$_ } })) }
    }
    return @{ ok = $true; apps = @($plan); circular = @($order.CircularNames); note = $note }
}

function Global:Start-WebDeploy {
    # Deploys ONE app (the page runs the plan's apps one after another).
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $a = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "'$name' is no longer in the catalog." } }
    $unc = Test-AppIsUncommon -App $a
    # -metadataOnly: Push settings - the catalog's settings to an app already in
    # Intune, without uploading a package.
    $metadataOnly = [bool]$Data.metadataOnly
    if ($metadataOnly) {
        if (-not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune yet - Deploy it first." } }
        if (-not $a.metadata) { return @{ ok = $false; error = "$name has no settings of its own yet - Pull them from Intune, or set them in the editor, first." } }
        $pkg = @{ Found = $true; Path = '' }
    }
    else {
        $pkg = Resolve-AppPackagePath -AppName $a.appName -Uncommon $unc -PackagePath $a.packagePath
        if (-not $pkg.Found) { return @{ ok = $false; error = "$name has no package to upload." } }
    }
    $defaults = $null
    $m = $a.metadata
    if (-not $m) { $defaults = Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon $unc; $m = $defaults }
    # Managed: deployed pinned to its App version, whatever the file's commands say.
    if ($a.managedUpdates -and $a.wingetId) {
        if (-not (Test-ReleaseVersionText ([string]$m.appVersion))) { return @{ ok = $false; error = "$name has managed updates, so it is deployed at a fixed version - set its App version first (or More > Take winget's version)." } }
        $pinned = [pscustomobject]@{ managedUpdates = $true; wingetId = $a.wingetId; metadata = $m.PSObject.Copy() }
        [void](Set-ManagedAppPin $pinned)
        $m = $pinned.metadata
    }
    if (-not $m.detectionRule) { return @{ ok = $false; error = "$name has no detection rule - set one in the editor's Deploy settings." } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_createapp_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = New-WebCreateAppConfig -Catalog $catalog -App $a -Metadata $m -Defaults $defaults -PackagePath $pkg.Path -ResultPath $resultPath
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedCreateAppScript -Name 'createapp' -ConfigJson (ConvertTo-CreateAppConfigJson -Config $config) -ResultPath $resultPath -Kind "$(if ($metadataOnly) { 'Push settings' } else { 'Deploy' }) $name" `
        -After @{ Kind = 'deploy'; AppName = $a.appName; Defaults = $defaults; WasUpdate = [bool]$a.appId }
    if ($started.ok) { Write-Log "[INFO] $(if ($metadataOnly) { "Pushing $name's settings to Intune" } else { "Deploying $name ($($config.Mode))" })..." }
    return $started
}

function Global:New-WebCreateAppConfig {
    # The CreateApp step's settings for one app (-Metadata: its settings, pinned for a managed app); Deploy and Release change what they need after.
    param($Catalog, $App, $Metadata, $Defaults, [string]$PackagePath, [string]$ResultPath)
    $a = $App; $m = $Metadata; $defaults = $Defaults
    # Dependencies by name -> the App IDs they have now; one not deployed yet is left out (as Batch Deploy does).
    $depIds = @(@($m.dependencies) | Where-Object { $_ } | ForEach-Object {
        $depName = [string]$_
        $dep = $Catalog.Apps | Where-Object { $_.appName -eq $depName } | Select-Object -First 1
        if ($dep -and $dep.appId) { $dep.appId }
    })
    return [pscustomobject]@{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        Mode = $(if ($a.appId) { 'UpdateMetadata' } else { 'Create' }); ExistingAppId = [string]$a.appId
        AppName = $a.appName; Description = $m.description; Publisher = $m.publisher; Owner = $m.owner; Developer = $m.developer
        InformationUrl = $m.informationUrl; PrivacyUrl = $m.privacyUrl; Notes = $m.notes; AppVersion = $m.appVersion; IsFeatured = $(if ($defaults -and $a.appId) { $null } else { $m.isFeatured })
        InstallCommand = $m.installCommand; UninstallCommand = $m.uninstallCommand; DetectionRule = $m.detectionRule
        InstallContext = $m.installContext; Architecture = $m.architecture; MinOSVersionKey = $m.minOSKey; PackagePath = $PackagePath
        DependencyAppIds = $depIds; ReplaceContent = $false; LargeIcon = $a.icon
        # An app with no settings of its own, already in Intune: the defaults say nothing about supersedence or Featured - leave Intune's.
        Supersedence = $(if ($defaults -and $a.appId) { $null } else { $m.supersedes })
        MinDiskSpaceMB = [int]$m.minDiskSpaceMB; MinMemoryMB = [int]$m.minMemoryMB; MinProcessors = [int]$m.minProcessors; MinCpuSpeedMHz = [int]$m.minCpuSpeedMHz
        InstallTimeMinutes = $(if ($m.installTimeMinutes) { [int]$m.installTimeMinutes } else { 60 }); DeviceRestartBehavior = $m.deviceRestartBehavior
        AllowAvailableUninstall = [bool]$m.allowAvailableUninstall; ReturnCodes = @($m.returnCodes); OutputResultPath = $ResultPath
    }
}

function Global:Start-WebPushGroups {
    <#
      Push groups for the chosen apps: Mode Preview lists what would be added
      and removed in Intune, Mode Apply does it (BatchAssign - Intune gets
      exactly the catalog's groups; missing groups are created). -single
      after a deploy pushes one app the way the single deploy does
      (TargetedAssign, no groups created).
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ })
    $apps = @($catalog.Apps | Where-Object { $names -contains $_.appName -and $_.appId })
    if ($apps.Count -eq 0) { return @{ ok = $false; error = 'None of the chosen apps is in Intune yet (no App ID).' } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_assign_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $creds = @{ TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint }
    if ([string]$Data.mode -eq 'AfterDeploy') {
        $a = $apps[0]
        $config = @{
            TenantId = $creds.TenantId; ClientId = $creds.ClientId; CertificateThumbprint = $creds.CertificateThumbprint
            AppId = $a.appId; AppName = $a.appName
            RequiredGroups = @($a.requiredFor); AvailableGroups = @($a.availableFor); UninstallGroups = @($a.uninstallFor); ExcludeGroups = @($a.excludeFor)
            CreateMissingGroups = $false; OutputResultPath = $resultPath
        }
        return (Start-WebStepJob -ScriptContent $Global:App.EmbeddedTargetedAssignScript -Name 'targetedassign' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath -Kind "Push groups $($a.appName)")
    }
    $mode = if ([string]$Data.mode -eq 'Apply') { 'Apply' } else { 'Preview' }
    $config = @{
        TenantId = $creds.TenantId; ClientId = $creds.ClientId; CertificateThumbprint = $creds.CertificateThumbprint
        Mode = $mode
        Apps = @($apps | ForEach-Object { @{ AppName = $_.appName; AppId = $_.appId; RequiredGroups = @($_.requiredFor); AvailableGroups = @($_.availableFor); UninstallGroups = @($_.uninstallFor); ExcludeGroups = @($_.excludeFor) } })
        OutputResultPath = $resultPath
    }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedBatchAssignScript -Name 'batchassign' -ConfigJson ($config | ConvertTo-Json -Depth 8) -ResultPath $resultPath -Kind "Push groups ($mode, $($apps.Count) app(s))"
    if ($started.ok) { Write-Log "[INFO] Push groups - $(if ($mode -eq 'Apply') { 'applying' } else { 'previewing' }) for $($apps.Count) app(s)..." }
    return $started
}

function Global:Start-WebPackage {
    <#
      Builds .intunewin packages (Package.ps1) for apps with their own
      installer - one, several, or every one when -names is empty. Winget
      apps all deploy the shared init.intunewin and are skipped.
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $own = @($catalog.Apps | Where-Object { Test-AppIsUncommon -App $_ })
    if ($names.Count) { $own = @($own | Where-Object { $names -contains $_.appName }) }
    if ($names.Count -and $own.Count -eq 0) { return @{ ok = $false; error = 'None of the chosen apps has its own installer to package - Winget apps use the shared package.' } }
    $params = @{ InputFolder = (Get-AppFolder -Kind Packages -Create); Force = $true; ToolPath = (Get-PackagingToolPath) }
    $folders = @($own | ForEach-Object { Get-SafeFileNameForApp -Name $_.appName })
    if ($names.Count -eq 1) { $params.SingleFolderName = $folders[0] }
    elseif ($names.Count -gt 1) { $params.FolderNames = ($folders -join ',') }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedPackageScript -Name 'package' -ConfigJson '' -ResultPath '' -Kind 'Package' -Parameters $params -After @{ Kind = 'package' }
    if ($started.ok) { Write-Log "[INFO] Packaging $(if ($names.Count) { "$($own.Count) app(s)" } else { 'every app with its own installer' })..." }
    return $started
}

function Global:Start-WebPull {
    # Pull from Intune: reads each chosen app's settings and groups (SyncMetadata - only reads).
    param($Data)
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ })
    $apps = @($catalog.Apps | Where-Object { $names -contains $_.appName -and $_.appId })
    if ($apps.Count -eq 0) { return @{ ok = $false; error = 'None of the chosen apps is in Intune yet (no App ID).' } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_sync_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        Apps = @($apps | ForEach-Object { @{ AppName = $_.appName; AppId = $_.appId } }); OutputResultPath = $resultPath
    }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedSyncMetadataScript -Name 'syncmeta' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath -Kind "Pull ($($apps.Count) app(s))" -After @{ Kind = 'pull' }
    if ($started.ok) { Write-Log "[INFO] Reading $($apps.Count) app(s) from Intune..." }
    return $started
}

function Global:Complete-WebPull {
    <#
      What Pull found: an app whose catalog entry matches
      Intune (or has no settings yet) takes Intune's at once; one that
      differs is kept back for the user to choose, field by field.
    #>
    param($Result)
    $applied = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    $review = New-Object System.Collections.Generic.List[object]
    $pending = @{}
    foreach ($r in @($Result.results)) {
        if (-not $r.Success) { $failed.Add("$($r.AppName): $($r.Error)"); continue }
        $app = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq $r.AppName } | Select-Object -First 1
        if (-not $app) { continue }
        $fieldDiffs = @(Get-CatalogMetadataFieldDiffs -Local $app.metadata -Remote $r.Metadata -OdataType $r.OdataType)
        # @() around the whole if: one difference on its own would otherwise be
        # unrolled to a single object without .Count (Windows PowerShell 5.1).
        $groupDiffs = @(if ($r.GroupFetchOk) { Get-GroupFieldDiffs -LocalApp $app -RemoteResult $r })
        if (($app.metadata -and $fieldDiffs.Count -gt 0) -or $groupDiffs.Count -gt 0) {
            $pending[$r.AppName] = $r
            $review.Add([ordered]@{ app = $r.AppName; diffs = @(@($fieldDiffs) + @($groupDiffs) | ForEach-Object { [ordered]@{ field = [string]$_.Field; local = (Get-CheckValueText $_.Local); intune = (Get-CheckValueText $_.Remote) } }) })
        }
        else {
            $rr = $r
            [void](Update-WebCatalogApp -Name $r.AppName -Change {
                param($a)
                $a.intuneAppType = Get-FriendlyIntuneAppType -ODataType $rr.OdataType
                $a.intuneAppVersion = [string]$rr.DisplayVersion
                $a.metadata = $rr.Metadata
            }.GetNewClosure())
            $applied.Add($r.AppName)
        }
    }
    $id = [guid]::NewGuid().ToString('N')
    if ($review.Count) { $Global:App.WebPending[$id] = $pending }
    Write-Log "[OK] Pulled from Intune: $($applied.Count) updated$(if ($review.Count) { ", $($review.Count) to review" })$(if ($failed.Count) { ", $($failed.Count) failed" })."
    return @{ ok = $true; pending = $(if ($review.Count) { $id } else { '' }); applied = $applied.ToArray(); review = $review.ToArray(); failed = $failed.ToArray() }
}

function Global:Invoke-WebPullApply {
    # The user's choice per reviewed app: which fields keep the catalog's value; the rest take Intune's.
    param($Data)
    $id = [string]$Data.pending
    if (-not $id -or -not $Global:App.WebPending.ContainsKey($id)) { return @{ ok = $false; error = 'Nothing waiting to be applied (run Pull again).' } }
    $pending = $Global:App.WebPending[$id]
    $done = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($pending.Keys)) {
        $r = $pending[$name]
        $keep = @($Data.keep.$name | ForEach-Object { [string]$_ })
        [void](Update-WebCatalogApp -Name $name -Change {
            param($a)
            $a.intuneAppType = Get-FriendlyIntuneAppType -ODataType $r.OdataType
            $a.intuneAppVersion = [string]$r.DisplayVersion
            $a.metadata = if ($a.metadata) { Merge-CatalogMetadata -Remote $r.Metadata -Local $a.metadata -KeepLocalFields $keep } else { $r.Metadata }
            if ($r.GroupFetchOk) {
                if ($keep -notcontains 'Required for') { $a.requiredFor = @($r.RequiredGroupNames) }
                if ($keep -notcontains 'Available for') { $a.availableFor = @($r.AvailableGroupNames) }
                if ($keep -notcontains 'Uninstall for') { $a.uninstallFor = @($r.UninstallGroupNames) }
            }
        }.GetNewClosure())
        $done.Add($name)
    }
    [void]$Global:App.WebPending.Remove($id)
    Write-Log "[OK] Applied the pull for: $($done -join ', ')."
    return @{ ok = $true; applied = $done.ToArray() }
}

function Global:Start-WebDeleteFromIntune {
    <#
      Deletes ONE app from Intune (DeleteApp - removes it as a dependency of
      another app first when -dependentOf says so), then clears its App ID
      in the catalog. The catalog entry itself stays.
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $a = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a -or -not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune (no App ID)." } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_delete_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        AppId = $a.appId; AppName = $a.appName; RemoveDependencyFromAppId = ''; OutputResultPath = $resultPath
    }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedDeleteAppScript -Name 'deleteapp' -ConfigJson ($config | ConvertTo-Json -Depth 4) -ResultPath $resultPath -Kind "Delete $name from Intune" -After @{ Kind = 'deleted'; AppName = $a.appName }
    if ($started.ok) { Write-Log "[INFO] Deleting $name from Intune..." }
    return $started
}

function Global:Clear-WebAppIds {
    <#
      Clears the App ID of several apps at once - after copying a catalog
      from another tenant, every App ID points at apps this tenant doesn't
      have. Intune isn't touched. Under the catalog lock (route table).
    #>
    param($Data)
    $names = @($Data.names | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) { return @{ ok = $false; error = 'Choose one or more apps first.' } }
    $cleared = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    $undo = New-WebUndo "Clear $($names.Count) App ID(s)"
    # Supersedence pointing at apps this tenant doesn't have came along with the copy too - dropped with the App IDs.
    $t = Get-WebIntuneApps @{}
    $tenantIds = $null
    if ($t.ok) { $tenantIds = @{}; foreach ($i in @($t.ids)) { $tenantIds[[string]$i] = $true } }
    foreach ($n in $names) {
        try {
            [void](Update-WebCatalogApp -Name $n -Change {
                    param($a)
                    $a.appId = ''; $a.intuneAppType = ''; $a.intuneAppVersion = ''
                    # Its pilot and superseded releases are the other tenant's apps too.
                    $a.releases = @()
                    if ($tenantIds -and $a.metadata -and $null -ne $a.metadata.supersedes) {
                        $keep = @(@($a.metadata.supersedes) | Where-Object { $_ -and $tenantIds.ContainsKey(([string]$_.appId).ToLowerInvariant()) })
                        if ($keep.Count -ne @($a.metadata.supersedes).Count) { $a.metadata.supersedes = $(if ($keep.Count) { $keep } else { $null }) }
                    }
                } -Undo $undo)
            $cleared.Add($n)
        }
        catch { $failed.Add("$n`: $($_.Exception.Message)") }
    }
    Save-WebUndo $undo
    $Global:App.IntuneAppsCache = $null
    Write-Log "[OK] Cleared the App ID of $($cleared.Count) app(s) in the catalog (Intune unchanged).$(if ($failed.Count) { " Failed: $($failed -join '; ')" })"
    return @{ ok = ($failed.Count -eq 0); cleared = $cleared.ToArray(); failed = $failed.ToArray(); error = $(if ($failed.Count) { "Not cleared: $($failed -join '; ')" } else { '' }) }
}

function Global:Clear-WebAppId {
    # Forgets the Intune link in the catalog (App ID, Intune's type and version). Intune isn't touched.
    param($Data)
    $name = [string]$Data.name
    try { [void](Update-WebCatalogApp -Name $name -Change { param($a) $a.appId = ''; $a.intuneAppType = ''; $a.intuneAppVersion = '' }) }
    catch { return @{ ok = $false; error = $_.Exception.Message } }
    Write-Log "[OK] Cleared $name's App ID in the catalog."
    return @{ ok = $true }
}

function Global:Get-WebInstallStatus {
    # Every device's install state for one app, from Intune's install status report.
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $a = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a -or -not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune (no App ID)." } }
    $id = [string]$a.appId
    $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) Get-AppInstallStatusRows -AppId $id -Invoke $Graph }
    if (-not $read.ok) { return $read }
    $report = $read.value
    $rows = @($report.Rows | ForEach-Object { [ordered]@{ device = [string]$_.DeviceName; user = [string]$_.UserName; state = [string]$_.State; detail = [string]$_.Detail; error = [string]$_.ErrorCode; version = [string]$_.Version; lastSeen = [string]$_.LastSeen } })
    return @{ ok = $true; app = $name; rows = $rows; truncated = [bool]$report.Truncated; summary = (Format-InstallStatusSummary @($report.Rows)) }
}
