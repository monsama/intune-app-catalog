# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    Managed updates: releasing a new version of an app through a pilot
    group before everyone gets it.

    A managed app's current release is the Intune app its catalog entry
    points at (appId), installing exactly its App version. A new version:

    1. Release (Start-WebRelease): a new Intune app "<name> <version> (pilot)"
       that installs the new version and supersedes the current one
       (update), assigned Required to the pilot groups only
       (Start-WebReleaseAssign 'pilot'). Recorded in the app's releases as
       state "pilot".
    2. Promote: the pilot app gets the catalog's groups
       (Start-WebReleaseAssign 'promote'), the current app loses its own
       ('retire'), and Complete-WebPromotion renames both in Intune and
       makes the pilot app the catalog's current one. The old one stays in
       Intune (state "previous") - devices keep what they have.
    Or withdraw (Start-WebReleaseAssign 'withdraw' + Complete-WebWithdrawal):
    the pilot app loses its assignments and is deleted from Intune; pilot
    devices keep the newer version (the current release's detection counts
    newer as installed).

    The steps that change Intune run as jobs (CreateApp, TargetedAssign);
    the page runs them one after another, like Deploy and Push groups.
#>

function Global:Get-WebAppRelease {
    # Pure: an app's pilot release, or $null.
    param($App)
    return (@($App.releases) | Where-Object { $_ -and $_.state -eq 'pilot' } | Select-Object -First 1)
}

function Global:Get-WebReleaseRings {
    # The release rings: the pilot groups first, then Settings' further rings - @(@{ Name; Groups }).
    return @(@([ordered]@{ Name = 'Pilot'; Groups = @($Global:App.PilotGroups) }) + @($Global:App.ReleaseRings))
}

function Global:Get-WebReleaseDecision {
    # What the release rule says about an app's pilot release, given its install counts: @{ Action; Reason; Rule; Ring; RingCount; RingName }.
    param($App, $Pilot, $Counts)
    $rings = @(Get-WebReleaseRings)
    $rule = Get-EffectiveReleaseRule -Policy $Global:App.ReleasePolicy -App $App -Release $Pilot
    $ring = [Math]::Min([int]$Pilot.ring, $rings.Count - 1)
    $since = if ($Pilot.ringAt) { [string]$Pilot.ringAt } else { [string]$Pilot.at }
    $at = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($since, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$at)) { $at = Get-Date }
    # A fast-track release skips the rings: one stage, then everyone.
    $count = if ($rule.FastTrack) { 1 } else { $rings.Count }
    $d = Get-ReleaseDecision -ReleasedAt $at -Now (Get-Date) -Counts $Counts -Policy $rule -Ring $(if ($rule.FastTrack) { 0 } else { $ring }) -RingCount $count
    $prefix = @($(if ($rule.FastTrack) { 'Fast track.' }), $(if ($rule.Own) { "This app's own rule." })) -join ' '
    return @{ Action = $d.Action; Reason = ($(if ($prefix.Trim()) { $prefix.Trim() + ' ' }) + $d.Reason); Rule = $rule; Ring = $ring; RingCount = $rings.Count; RingName = [string]$rings[$ring].Name }
}

function Global:Get-WebReleaseInfo {
    # What the Release dialog shows for one app.
    param($Data)
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$($Data.name)' in the catalog." } }
    $pilot = Get-WebAppRelease $a
    $latest = if ($Global:App.WingetLatest -and $a.wingetId) { [string]$Global:App.WingetLatest[([string]$a.wingetId).ToLowerInvariant()] } else { '' }
    $own = -not $a.wingetId
    $installer = if ($own) { Get-WebInstallerInfo $a.appName } else { $null }
    $status = if ($pilot) { Get-WebPilotStatus $pilot -App $a } else { $null }
    return @{ ok = $true; name = $a.appName; managed = [bool]$a.managedUpdates; wingetId = [string]$a.wingetId; appId = [string]$a.appId
        kind = $(if ($own) { 'package' } else { 'winget' }); installer = $installer; pilotStatus = $status
        detectionProblem = $(if ($own) { Test-VersionDetectionRule $(if ($a.metadata) { $a.metadata.detectionRule }) } else { '' })
        current = [string]$(if ($a.metadata) { $a.metadata.appVersion }); latest = $latest
        pilot = $(if ($pilot) { @{ version = $pilot.version; appId = $pilot.appId; at = $pilot.at; ring = [int]$pilot.ring; fastTrack = [bool]$pilot.fastTrack } } else { $null })
        previous = @(Get-WebPreviousReleases $a | ForEach-Object { @{ version = $_.version; appId = $_.appId; at = $_.at } })
        pilotGroups = @($Global:App.PilotGroups); rings = @(Get-WebReleaseRings | ForEach-Object { [ordered]@{ name = $_.Name; groups = @($_.Groups) } })
        fastTrackHours = [int]$Global:App.ReleasePolicy.FastTrackHours }
}

function Global:Start-WebRelease {
    # Step 1: the new version as a new Intune app superseding the current one (CreateApp, Create mode).
    param($Data)
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $version = ([string]$Data.version).Trim()
    $a = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "'$name' is no longer in the catalog." } }
    if (-not $a.managedUpdates) { return @{ ok = $false; error = "$name doesn't have managed updates - turn them on first (More > Managed updates)." } }
    $own = -not $a.wingetId
    if (-not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune yet - Deploy it first; that is its first release." } }
    if (Get-WebAppRelease $a) { return @{ ok = $false; error = "$name already has a version in pilot - promote or withdraw it first." } }
    if (-not (Test-ReleaseVersionText $version)) { return @{ ok = $false; error = "'$version' isn't a version a release can pin (letters, digits and . - + _)." } }
    $current = [string]$(if ($a.metadata) { $a.metadata.appVersion })
    if ($version -eq $current) { return @{ ok = $false; error = "$name is at $version already." } }
    # A Winget version whose installer is gone would fail on every pilot device - not released.
    if (-not $own -and -not $Global:App.TestGraph) {
        $dl = Test-WebPinnedDownload -WingetId $a.wingetId -Version $version
        if ($dl.status -in 'gone', 'notinwinget') { return @{ ok = $false; error = "Not released: $($dl.text)" } }
    }
    if (-not @($Global:App.PilotGroups).Count) { return @{ ok = $false; error = 'Set the pilot groups first: Settings > Updates.' } }
    $pkg = Resolve-AppPackagePath -AppName $a.appName -Uncommon $own -PackagePath $a.packagePath
    if (-not $pkg.Found) { return @{ ok = $false; error = $(if ($own) { "$name has no package to upload - put the new installer in its folder and build it (the release dialog does both)." } else { "The shared Winget package (init.intunewin) isn't built yet - Settings > Packaging & folders builds it." }) } }
    $defaults = $null
    $m = $a.metadata
    if (-not $m) { $defaults = Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon $own; $m = $defaults }
    if ($own) { $why = Test-VersionDetectionRule $m.detectionRule; if ($why) { return @{ ok = $false; error = "${name}: $why" } } }
    $next = [pscustomobject]@{ managedUpdates = $true; wingetId = $a.wingetId; appName = $a.appName; detectedName = $a.detectedName; metadata = $m.PSObject.Copy() }
    $next.metadata.appVersion = $version
    [void](Set-ManagedAppPin $next -ProductCode ([string]$Data.productCode))
    # Commands edited by hand aren't re-pinned - such a release would install the old version and still count as installed.
    $notPinned = Test-ReleasePinned -Metadata $next.metadata -Version $version -Winget (-not $own)
    if ($notPinned) { return @{ ok = $false; error = "Not released: $notPinned" } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_createapp_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = New-WebCreateAppConfig -Catalog $catalog -App $a -Metadata $next.metadata -Defaults $null -PackagePath $pkg.Path -ResultPath $resultPath
    $config.Mode = 'Create'; $config.ExistingAppId = ''
    $config.AppName = "$($a.appName) $version (pilot)"
    # Supersedes exactly the current release (update: devices that have it get this one) - not the catalog's own supersedence list.
    $config.Supersedence = @([pscustomobject]@{ appId = [string]$a.appId; type = 'update' })
    $config.IsFeatured = $null
    $busy = Enter-WebAppBusy -Name $a.appName -What "releasing $version"
    if ($busy) { return @{ ok = $false; error = $busy } }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedCreateAppScript -Name 'createapp' -ConfigJson (ConvertTo-CreateAppConfigJson -Config $config) -ResultPath $resultPath -Kind "Release $name $version" -BusyApp $a.appName `
        -After @{ Kind = 'release'; AppName = $a.appName; Version = $version; FastTrack = [bool]$Data.fastTrack; ProductCode = $(if ($own) { [string]$next.metadata.detectionRule.Msi_ProductCode } else { '' }) }
    if ($started.ok) { Write-Log "[INFO] Releasing $name $version to pilot$(if ($Data.fastTrack) { ' on the fast track' }) (a new app superseding $current)..." }
    return $started
}

function Global:Complete-WebRelease {
    # After step 1: the new app is the pilot release.
    param([hashtable]$After, $Result)
    $newId = [string]$Result.appId
    if ($newId -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') { return @{ ok = $false; error = 'The release step did not report the new app''s ID.' } }
    $version = [string]$After.Version
    $code = [string]$After.ProductCode
    $fast = [bool]$After.FastTrack
    [void](Update-WebCatalogApp -Name $After.AppName -Change {
            param($app)
            $now = (Get-Date).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            $app.releases = @(@($app.releases) | Where-Object { $_.state -ne 'pilot' }) + @([pscustomobject]@{ version = $version; appId = $newId; state = 'pilot'; at = $now; productCode = $code; ring = 0; ringAt = $now; fastTrack = $fast; unassigned = $true })
            $app.blockedVersions = @(@($app.blockedVersions) | Where-Object { $_ -and [string]$_ -ne $version })
        }.GetNewClosure())
    Write-Log "[OK] $($After.AppName) $version is in Intune as a pilot release (App ID $newId)."
    return @{ ok = $true; assignPilot = $true; appId = $newId }
}

function Global:Start-WebReleaseAssign {
    <#
      Assignments for a release step (TargetedAssign - exactly these groups):
        pilot     the pilot app: Required to the groups of its ring (the pilot groups, and the rings before)
        advance   the pilot app: Required to the next ring's groups too (Complete-WebAdvance records it)
        promote   the pilot app: the catalog's groups
        retire    the current app: none (its devices are now the pilot app's)
        withdraw  the pilot app: none
    #>
    param($Data)
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "'$($Data.name)' is no longer in the catalog." } }
    $pilot = Get-WebAppRelease $a
    $step = [string]$Data.step
    $rings = @(Get-WebReleaseRings)
    $none = @{ Required = @(); Available = @(); Uninstall = @(); Exclude = @() }
    switch ($step) {
        'pilot' { if (-not $pilot) { return @{ ok = $false; error = "$($a.appName) has no pilot release." } }; $id = $pilot.appId; $g = @{ Required = @(Get-ReleaseRingGroups -Rings $rings -Ring ([int]$pilot.ring)); Available = @(); Uninstall = @(); Exclude = @($a.excludeFor) }; $label = "Assign $($a.appName) $($pilot.version) to pilot" }
        'advance' {
            if (-not $pilot) { return @{ ok = $false; error = "$($a.appName) has no pilot release." } }
            $nextRing = [int]$pilot.ring + 1
            if ($nextRing -ge $rings.Count) { return @{ ok = $false; error = "$($a.appName) $($pilot.version) is in the last ring - promote it to everyone." } }
            $id = $pilot.appId; $g = @{ Required = @(Get-ReleaseRingGroups -Rings $rings -Ring $nextRing); Available = @(); Uninstall = @(); Exclude = @($a.excludeFor) }; $label = "Give $($a.appName) $($pilot.version) to $($rings[$nextRing].Name)"
        }
        'promote' { if (-not $pilot) { return @{ ok = $false; error = "$($a.appName) has no pilot release." } }; $id = $pilot.appId; $g = @{ Required = @($a.requiredFor); Available = @($a.availableFor); Uninstall = @($a.uninstallFor); Exclude = @($a.excludeFor) }; $label = "Promote $($a.appName) $($pilot.version)" }
        'retire' { if (-not $a.appId) { return @{ ok = $false; error = "$($a.appName) has no current release." } }; $id = $a.appId; $g = $none; $label = "Retire $($a.appName) $(if ($a.metadata) { $a.metadata.appVersion })" }
        'rollback' {
            if ($pilot) { return @{ ok = $false; error = "$($a.appName) has a version in pilot - promote or withdraw it first." } }
            $back = @(Get-WebPreviousReleases $a) | Select-Object -Last 1
            if (-not $back) { return @{ ok = $false; error = "$($a.appName) has no earlier release to go back to." } }
            $id = $back.appId; $g = @{ Required = @($a.requiredFor); Available = @($a.availableFor); Uninstall = @($a.uninstallFor); Exclude = @($a.excludeFor) }; $label = "Roll $($a.appName) back to $($back.version)"
        }
        'withdraw' { if (-not $pilot) { return @{ ok = $false; error = "$($a.appName) has no pilot release." } }; $id = $pilot.appId; $g = $none; $label = "Withdraw $($a.appName) $($pilot.version)" }
        default { return @{ ok = $false; error = 'Unknown release step.' } }
    }
    $resultPath = Join-Path $env:TEMP (".intunepkg_assign_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        AppId = $id; AppName = $a.appName
        RequiredGroups = @($g.Required); AvailableGroups = @($g.Available); UninstallGroups = @($g.Uninstall); ExcludeGroups = @($g.Exclude)
        FilterName = [string]$a.assignmentFilter; FilterMode = [string]$a.assignmentFilterMode
        CreateMissingGroups = ($step -in 'pilot', 'advance'); OutputResultPath = $resultPath
        # Install deadline, restart grace period, notifications (Settings > Managed updates) on the Required assignments.
        # Promoted (it supersedes the version before): Company Portal installs are updated as well.
        AvailableSettings = $(if ($step -eq 'promote') { Get-ReleaseAvailableSettings } else { $null })
        RequiredSettings = $(if ($step -in 'pilot', 'advance', 'promote', 'rollback') { Get-ReleaseAssignmentSettings -Policy $Global:App.ReleasePolicy -FastTrack ([bool]($pilot -and $pilot.fastTrack -and $step -ne 'rollback')) -NowUtc ([datetime]::UtcNow) } else { $null })
    }
    $gid = Add-WebGroupIdsToConfig $config; if ($gid) { return @{ ok = $false; error = $gid } }
    # The pilot assignment done: the release is no longer waiting for it.
    $after = if ($step -eq 'pilot') { @{ Kind = 'pilotassigned'; AppName = [string]$a.appName; AppId = [string]$id } } else { @{} }
    $busy = Enter-WebAppBusy -Name $a.appName -What $label
    if ($busy) { return @{ ok = $false; error = $busy } }
    return (Start-WebStepJob -BusyApp $a.appName -ScriptContent $Global:App.EmbeddedTargetedAssignScript -Name 'targetedassign' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath -Kind $label -Apps @([string]$a.appName) -After $after)
}

function Global:Complete-WebAdvance {
    # After 'advance': the pilot release is in the next ring from now (the rule's days count again from here).
    param($Data)
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "'$($Data.name)' is no longer in the catalog." } }
    $pilot = Get-WebAppRelease $a
    if (-not $pilot) { return @{ ok = $false; error = "$($a.appName) has no pilot release." } }
    $rings = @(Get-WebReleaseRings)
    $next = [Math]::Min([int]$pilot.ring + 1, $rings.Count - 1)
    $pilot.ring = $next; $pilot.ringAt = (Get-Date).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    Write-WebAppFile -App $a
    Write-Log "[OK] $($a.appName) $($pilot.version) is in ring $($next + 1) of $($rings.Count) ($($rings[$next].Name)) now."
    return @{ ok = $true; ring = $next; ringName = [string]$rings[$next].Name; version = [string]$pilot.version }
}

function Global:Rename-WebIntuneApp {
    # Renames one Win32 app in Intune; '' when it worked, else the reason.
    param([string]$AppId, [string]$Name)
    $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action {
        param($Graph)
        [void](& $Graph "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId" 'PATCH' @{ '@odata.type' = '#microsoft.graph.win32LobApp'; displayName = $Name })
        $true
    }
    return $(if ($read.ok) { '' } else { [string]$read.error })
}

function Global:Complete-WebPromotion {
    <#
      After 'promote' and 'retire': the pilot app is the current release -
      named as the catalog names the app, its App ID and version in the
      catalog (commands and detection pinned to it) - and the old one is
      kept as "previous", renamed "<name> <version> (superseded)".
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $a = $catalog.Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "'$($Data.name)' is no longer in the catalog." } }
    $pilot = Get-WebAppRelease $a
    if (-not $pilot) { return @{ ok = $false; error = "$($a.appName) has no pilot release." } }
    $oldId = [string]$a.appId
    $oldVersion = [string]$(if ($a.metadata) { $a.metadata.appVersion })
    $notes = New-Object System.Collections.Generic.List[string]
    $why = Rename-WebIntuneApp -AppId $pilot.appId -Name $a.appName
    if ($why) { $notes.Add("The new release keeps its pilot name in Intune ($why) - rename it to '$($a.appName)' there.") }
    if ($oldId) {
        $why = Rename-WebIntuneApp -AppId $oldId -Name "$($a.appName) $oldVersion (superseded)"
        if ($why) { $notes.Add("The old release keeps its name in Intune ($why).") }
    }
    $undo = New-WebUndo "Promote $($a.appName) $($pilot.version)"
    if (-not $a.metadata) { $a.metadata = Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon $false }
    $oldCode = [string]$(if ($a.metadata.detectionRule) { $a.metadata.detectionRule.Msi_ProductCode })
    $a.metadata.appVersion = [string]$pilot.version
    [void](Set-ManagedAppPin $a -ProductCode ([string]$pilot.productCode))
    $kept = @(@($a.releases) | Where-Object { $_.state -ne 'pilot' })
    if ($oldId) { $kept += [pscustomobject]@{ version = $oldVersion; appId = $oldId; state = 'previous'; at = (Get-Date).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture); productCode = $oldCode } }
    $a.releases = $kept
    $a.appId = [string]$pilot.appId
    Write-WebAppFile -App $a -Undo $undo
    # No Undo here: Intune has already moved the assignments and renamed the apps - an Undo of the catalog alone would point it at the wrong app. Roll back (or promote again) instead.
    $Global:App.IntuneAppsCache = $null
    Write-Log "[OK] $($a.appName) $($pilot.version) promoted: it is the current release now (App ID $($pilot.appId)); $oldVersion is kept as superseded."
    return @{ ok = $true; version = $pilot.version; notes = $notes.ToArray() }
}

function Global:Complete-WebWithdrawal {
    # After 'withdraw': the pilot app is deleted from Intune and dropped from the catalog.
    param($Data)
    $catalog = Read-WebCatalogRecords
    $a = $catalog.Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "'$($Data.name)' is no longer in the catalog." } }
    $pilot = Get-WebAppRelease $a
    if (-not $pilot) { return @{ ok = $false; error = "$($a.appName) has no pilot release." } }
    $id = [string]$pilot.appId
    $del = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) [void](& $Graph "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$id" 'DELETE'); $true }
    $a.releases = @(@($a.releases) | Where-Object { $_.state -ne 'pilot' })
    # Not released again by itself (the nightly run) - Release new version by hand still can.
    $a.blockedVersions = @(@($a.blockedVersions) + [string]$pilot.version | Where-Object { $_ } | Select-Object -Unique)
    Write-WebAppFile -App $a
    $Global:App.IntuneAppsCache = $null
    Write-Log "[OK] $($a.appName) $($pilot.version) withdrawn$(if (-not $del.ok) { " - but it couldn't be deleted from Intune ($($del.error)); it has no assignments any more" })."
    return @{ ok = $true; deleted = [bool]$del.ok; error = $(if ($del.ok) { '' } else { [string]$del.error }) }
}

function Global:Set-WebManagedUpdates {
    # Managed updates on or off for the chosen Winget apps (with Undo); on pins their commands to their App version.
    param($Data)
    $names = @($Data.names | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $on = [bool]$Data.on
    $undo = New-WebUndo "Managed updates $(if ($on) { 'on' } else { 'off' })"
    $changed = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($a in @((Read-WebCatalogRecords).Apps | Where-Object { $names -contains $_.appName })) {
        if ($on -and (Test-StoreProductId ([string]$a.wingetId))) { $skipped.Add("$($a.appName) (a Microsoft Store app - the Store updates it)"); continue }
        if ($on -and -not $a.wingetId) {
            $why = Test-VersionDetectionRule $(if ($a.metadata) { $a.metadata.detectionRule })
            if ($why) { $skipped.Add("$($a.appName) (its detection rule doesn't compare a version)"); continue }
        }
        if (-not $on -and (Get-WebAppRelease $a)) { $skipped.Add("$($a.appName) (a version is in pilot)"); continue }
        if ([bool]$a.managedUpdates -eq $on) { continue }
        $a.managedUpdates = $on
        if ($on) {
            if (-not $a.metadata) { $a.metadata = Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon $false }
            [void](Set-ManagedAppPin $a)
        }
        Write-WebAppFile -App $a -Undo $undo
        $changed.Add($a.appName)
    }
    Save-WebUndo $undo
    Write-Log "[OK] Managed updates $(if ($on) { 'on' } else { 'off' }) for $($changed.Count) app(s)$(if ($skipped.Count) { "; skipped: $($skipped -join ', ')" })."
    return @{ ok = $true; changed = $changed.ToArray(); skipped = $skipped.ToArray() }
}

function Global:Get-WebInstallerInfo {
    <#
      The installer in an own-package app's folder (Packages\<app>): the
      newest .msi - its ProductVersion and ProductCode, read with Windows
      Installer - or else the newest .exe's product/file version.
      @{ folder; found; file; version; productCode }.
    #>
    param([string]$AppName)
    $folder = Join-Path (Get-AppFolder -Kind Packages) (Get-SafeFileNameForApp -Name $AppName)
    $info = [ordered]@{ folder = $folder; found = $false; file = ''; version = ''; productCode = '' }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return $info }
    # A PSADT app: the installer is in the toolkit's Files folder - the toolkit's own exe isn't the app.
    $look = $folder
    if (Test-Path -LiteralPath (Join-Path $folder 'Invoke-AppDeployToolkit.ps1')) {
        $look = Join-Path $folder 'Files'
        if (-not (Test-Path -LiteralPath $look -PathType Container)) { return $info }
    }
    $msi = Get-ChildItem -LiteralPath $look -Filter '*.msi' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $exe = Get-ChildItem -LiteralPath $look -Filter '*.exe' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'Invoke-AppDeployToolkit.exe', 'Deploy-Application.exe' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($msi) {
        $info.found = $true; $info.file = $msi.Name
        try {
            $wi = New-Object -ComObject WindowsInstaller.Installer
            $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($msi.FullName, 0))
            foreach ($prop in 'ProductVersion', 'ProductCode') {
                $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$prop'"))
                [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
                $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                $val = if ($rec) { [string]$rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) } else { '' }
                [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
                if ($prop -eq 'ProductVersion') { $info.version = $val } else { $info.productCode = $val }
            }
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($db); [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wi)
        }
        catch { }
    }
    elseif ($exe) {
        $info.found = $true; $info.file = $exe.Name
        $vi = $exe.VersionInfo
        $v = ([string]$vi.ProductVersion).Trim(); if (-not $v) { $v = ([string]$vi.FileVersion).Trim() }
        $info.version = ($v -replace '[^0-9A-Za-z.\-+_].*$', '')
    }
    if ($info.version -and -not (Test-ReleaseVersionText $info.version)) { $info.version = '' }
    return $info
}

function Global:Get-WebPilotStatus {
    # A pilot release's install counts in Intune and what the release policy says to do now (Get-ReleaseDecision).
    param($Pilot, $App)
    $id = [string]$Pilot.appId
    $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) & $Graph "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$id/installSummary" }
    if (-not $read.ok) { return @{ ok = $false; error = [string]$read.error } }
    $s = $read.value
    $counts = @{ installed = [int]$s.installedDeviceCount; failed = [int]$s.failedDeviceCount; pending = [int]$s.pendingInstallDeviceCount; notInstalled = [int]$s.notInstalledDeviceCount }
    $decision = Get-WebReleaseDecision -App $App -Pilot $Pilot -Counts $counts
    return @{ ok = $true; counts = $counts; action = $decision.Action; reason = $decision.Reason; ring = $decision.Ring; ringCount = $decision.RingCount; ringName = $decision.RingName; fastTrack = [bool]$decision.Rule.FastTrack }
}

# ---------------------------------------------------------------- rollback and clean-up

function Global:Get-WebPreviousReleases {
    # Pure: an app's superseded releases (rollback targets), oldest VERSION first - not by date: a rollback records the
    # version it left at "now", and that must never become the newest one to go back to.
    param($App)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in @(@($App.releases) | Where-Object { $_ -and $_.state -eq 'previous' })) {
        $i = 0
        while ($i -lt $list.Count -and (Compare-AppVersionText ([string]$list[$i].version) ([string]$r.version)) -eq 1) { $i++ }
        $list.Insert($i, $r)
    }
    return $list.ToArray()
}

function Global:Complete-WebRollback {
    <#
      After 'rollback' (the newest superseded release gets the catalog's
      groups) and 'retire' (the current one loses its own): that release is
      the current one again - named as the catalog names the app, its App ID
      and version in the catalog - and the one rolled back from is kept as
      superseded, renamed "<name> <version> (rolled back)". Devices that
      have the newer version keep it (nothing is uninstalled); new devices
      get the older one.
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $a = $catalog.Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "'$($Data.name)' is no longer in the catalog." } }
    $prev = @(Get-WebPreviousReleases $a) | Select-Object -Last 1
    if (-not $prev) { return @{ ok = $false; error = "$($a.appName) has no earlier release to go back to." } }
    $oldId = [string]$a.appId
    $oldVersion = [string]$(if ($a.metadata) { $a.metadata.appVersion })
    $notes = New-Object System.Collections.Generic.List[string]
    $why = Rename-WebIntuneApp -AppId $prev.appId -Name $a.appName
    if ($why) { $notes.Add("The restored release keeps its old name in Intune ($why).") }
    $why = Rename-WebIntuneApp -AppId $oldId -Name "$($a.appName) $oldVersion (rolled back)"
    if ($why) { $notes.Add("The release rolled back from keeps its name in Intune ($why).") }
    $undo = New-WebUndo "Roll $($a.appName) back to $($prev.version)"
    if (-not $a.metadata) { $a.metadata = Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon (-not $a.wingetId) }
    $leftCodeBefore = [string]$(if ($a.metadata.detectionRule) { $a.metadata.detectionRule.Msi_ProductCode })
    $a.metadata.appVersion = [string]$prev.version
    [void](Set-ManagedAppPin $a -ProductCode ([string]$prev.productCode))
    $leftCode = $leftCodeBefore
    $a.releases = @(@($a.releases) | Where-Object { [string]$_.appId -ne [string]$prev.appId }) + @([pscustomobject]@{ version = $oldVersion; appId = $oldId; state = 'rolledback'; at = (Get-Date).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture); productCode = $leftCode })
    # The version rolled back from isn't released again by itself (the nightly run).
    $a.blockedVersions = @(@($a.blockedVersions) + $oldVersion | Where-Object { $_ } | Select-Object -Unique)
    $a.appId = [string]$prev.appId
    Write-WebAppFile -App $a -Undo $undo
    # No Undo here: Intune has already moved the assignments and renamed the apps - an Undo of the catalog alone would point it at the wrong app. Roll back (or promote again) instead.
    $Global:App.IntuneAppsCache = $null
    Write-Log "[OK] $($a.appName) rolled back to $($prev.version) (App ID $($prev.appId)); $oldVersion is kept as superseded."
    return @{ ok = $true; version = $prev.version; notes = $notes.ToArray() }
}

function Global:Remove-WebOldReleases {
    <#
      Deletes an app's superseded releases from Intune except the newest one
      (kept for rollback), oldest first. Intune won't delete an app another
      app supersedes, so each one is first taken out of the relationships of
      the release that superseded it (the next newer one). -planOnly: only
      says which. @{ ok; removed; failed; kept }.
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $a = $catalog.Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "'$($Data.name)' is no longer in the catalog." } }
    $prev = @(Get-WebPreviousReleases $a)
    # Rolled-back releases go too (never a rollback target); of the superseded ones the newest VERSION is kept for rollback.
    $rolled = @(@($a.releases) | Where-Object { $_ -and $_.state -eq 'rolledback' })
    $old = @(@($(if ($prev.Count -gt 1) { $prev | Select-Object -First ($prev.Count - 1) })) + $rolled | Where-Object { $_ })
    $keptVersions = @($(if ($prev.Count) { $prev[-1].version }))
    if (-not $old.Count) { return @{ ok = $true; removed = @(); failed = @(); kept = $keptVersions } }
    if ($Data.planOnly) { return @{ ok = $true; plan = @($old | ForEach-Object { $_.version }); removed = @(); failed = @(); kept = $keptVersions } }
    $removed = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    # Whichever of the app's own Intune apps supersedes (or depends on) the one deleted is found by its relationships -
    # after a rollback that isn't the next newer version.
    $known = @(@([string]$a.appId) + @(@($a.releases) | ForEach-Object { [string]$_.appId }) | Where-Object { $_ } | Select-Object -Unique)
    foreach ($o in $old) {
        $target = [string]$o.appId
        $parents = @($known | Where-Object { $_ -ne $target })
        $res = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action {
            param($Graph)
            foreach ($parent in $parents) {
                $rels = @(try { (& $Graph "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$parent/relationships").value } catch { })
                if (-not @($rels | Where-Object { $_ -and [string]$_.targetId -eq $target -and ([string]$_.targetType -eq 'child' -or -not $_.targetType) }).Count) { continue }
                $keep = @($rels | Where-Object { $_ -and ([string]$_.targetType -eq 'child' -or -not $_.targetType) -and [string]$_.targetId -ne $target } | ForEach-Object {
                        $r = @{ '@odata.type' = [string]$_.'@odata.type'; targetId = [string]$_.targetId }
                        if ([string]$_.'@odata.type' -like '*Supersedence') { $r.supersedenceType = [string]$_.supersedenceType } else { $r.dependencyType = [string]$_.dependencyType }
                        $r
                    })
                [void](& $Graph "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$parent/updateRelationships" 'POST' @{ relationships = @($keep) })
            }
            [void](& $Graph "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$target" 'DELETE')
            $true
        }.GetNewClosure()
        if ($res.ok) { $removed.Add([string]$o.version) } else { $failed.Add("$($o.version): $($res.error)") }
    }
    if ($removed.Count) {
        Invoke-WithCatalogLock {
            $fresh = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq $a.appName } | Select-Object -First 1
            if ($fresh) {
                $gone = @($old | Where-Object { $removed -contains [string]$_.version } | ForEach-Object { [string]$_.appId })

                $fresh.releases = @(@($fresh.releases) | Where-Object { $gone -notcontains [string]$_.appId })
                Write-WebAppFile -App $fresh
            }
        } | Out-Null
        $Global:App.IntuneAppsCache = $null
    }
    Write-Log "[$(if ($failed.Count) { 'WARN' } else { 'OK' })] $($a.appName): deleted superseded release(s) $($removed -join ', ') from Intune$(if ($failed.Count) { "; not deleted: $($failed -join '; ')" })$(if ($keptVersions.Count) { "; kept $($keptVersions -join ', ') for rollback" })."
    return @{ ok = ($failed.Count -eq 0); removed = $removed.ToArray(); failed = $failed.ToArray(); kept = $keptVersions; error = $(if ($failed.Count) { "Not deleted: $($failed -join '; ')" } else { '' }) }
}

# ---------------------------------------------------------------- can a pinned winget version still be installed?
# winget only knows where the vendor's installer is; a vendor that keeps only
# its latest download online breaks a pinned version weeks later, first on new
# devices. Checked before a release and by the nightly run; the results are
# kept (Logs\download-checks.json) for the Updates page and Home.

function Global:Get-WebUrlStatus {
    # The HTTP status a download link answers (HEAD, then a one-byte GET if HEAD isn't taken); 0 when it couldn't be asked.
    param([string]$Url, [int]$Hops = 0)
    # https only, and redirects followed here (at most 5), each to https too - the link comes from a manifest.
    if ($Url -notmatch '^https://' -or $Hops -gt 5) { return 0 }
    foreach ($method in 'HEAD', 'GET') {
        try {
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = $method; $req.AllowAutoRedirect = $false; $req.Timeout = 20000; $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) IntuneAppCatalog'
            if ($method -eq 'GET') { $req.AddRange(0, 0) }
            $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $location = [string]$resp.Headers['Location']; $resp.Close()
            if ($code -ge 300 -and $code -lt 400 -and $location) { return (Get-WebUrlStatus -Url ([string](New-Object System.Uri((New-Object System.Uri($Url)), $location))) -Hops ($Hops + 1)) }
            return $code
        }
        catch [System.Net.WebException] {
            $resp = $_.Exception.Response
            if ($resp) {
                $code = [int]$resp.StatusCode; $location = [string]$resp.Headers['Location']; $resp.Close()
                if ($code -ge 300 -and $code -lt 400 -and $location) { return (Get-WebUrlStatus -Url ([string](New-Object System.Uri((New-Object System.Uri($Url)), $location))) -Hops ($Hops + 1)) }
                if ($method -eq 'HEAD' -and $code -notin 404, 410) { continue }
                return $code
            }
            if ($method -eq 'GET') { return 0 }
        }
        catch { return 0 }
    }
    return 0
}

function Global:Get-WebDownloadChecks {
    # The kept results: "<winget id>|<version>" -> @{ status; text; url; at; latestOnly }.
    if ($Global:App.DownloadChecks) { return $Global:App.DownloadChecks }
    $h = [hashtable]::Synchronized(@{})
    $file = Join-Path (Get-AppFolder -Kind Logs -Create) 'download-checks.json'
    if (Test-Path -LiteralPath $file) {
        try { $j = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $h[$p.Name] = $p.Value } } catch { }
    }
    $Global:App.DownloadChecks = $h
    return $h
}

function Global:Test-WebPinnedDownload {
    <#
      Whether winget can still install -Version of -WingetId: winget knows the
      version, and its installer link answers. When it can't, the newest
      version is checked too - downloadable means the vendor keeps only its
      latest version online (latestOnly). Kept for the Updates page and Home.
    #>
    param([string]$WingetId, [string]$Version)
    # Test mode: no winget and no internet - nothing is known.
    if ($Global:App.TestGraph) { return @{ status = 'unknown'; text = 'Not checked in test mode.'; url = ''; latestOnly = $false; at = '' } }
    $check = {
        param([string]$V)
        $show = Invoke-Winget -Arguments @(@('show', '--id', $WingetId, '--exact') + $(if ($V) { @('--version', $V) } else { @() }) + @('--accept-source-agreements', '--disable-interactivity')) -TimeoutSeconds 60
        $url = ConvertFrom-WingetInstallerUrl $show.StdOut
        $label = if ($V) { $V } else { 'the newest version' }
        # Only winget's own "no package found" (0x8A150014) means it's gone from winget; any other failure (no network, a source problem, an answer that can't be read) isn't known.
        $verdict = if ($show.ExitCode -eq 0 -and $url) { Get-DownloadCheckVerdict -InWinget $true -StatusCode (Get-WebUrlStatus $url) -Version $label }
            elseif ($show.ExitCode -eq -1978335212) { Get-DownloadCheckVerdict -InWinget $false -StatusCode 0 -Version $label }
            else { Get-DownloadCheckVerdict -InWinget $true -StatusCode 0 -Version $label -NoLink }
        $verdict.url = $url
        $verdict
    }
    try { $r = & $check $Version }
    catch { $r = @{ status = 'unknown'; text = "winget couldn't be asked: $($_.Exception.Message)"; url = '' } }
    $r.latestOnly = $false
    if ($r.url -and $r.url -notmatch '^https://' -and $r.status -eq 'unknown') { $r.text = "The $Version download isn't on https - not asked from here." }
    if ($r.status -in 'gone', 'notinwinget') {
        try { if ((& $check '').status -eq 'ok') { $r.latestOnly = $true; $r.text += ' The newest version can be downloaded - this vendor keeps only its latest version online: release new versions soon after they come out (fast track), or turn managed updates off for this app.' } } catch { }
    }
    $r.at = (Get-Date).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $h = Get-WebDownloadChecks
    # Requests run side by side: one at a time changes and writes the results.
    [System.Threading.Monitor]::Enter($h.SyncRoot)
    try {
        $h["$WingetId|$Version"] = $r
        try { [System.IO.File]::WriteAllText((Join-Path (Get-AppFolder -Kind Logs -Create) 'download-checks.json'), (ConvertTo-Json -InputObject ([hashtable]$h.Clone()) -Depth 4), (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }
    finally { [System.Threading.Monitor]::Exit($h.SyncRoot) }
    return $r
}

function Global:Invoke-WebDownloadChecks {
    # Updates > Check downloads: every deployed Winget app with managed updates, its pinned version (and the one in pilot).
    $apps = @((Read-WebCatalogRecords).Apps | Where-Object { $_.managedUpdates -and $_.wingetId -and -not (Test-StoreProductId $_.wingetId) -and $_.metadata -and [string]$_.metadata.appVersion })
    $rows = foreach ($a in $apps) {
        $r = Test-WebPinnedDownload -WingetId $a.wingetId -Version ([string]$a.metadata.appVersion)
        [ordered]@{ name = $a.appName; version = [string]$a.metadata.appVersion; status = $r.status; text = $r.text; latestOnly = [bool]$r.latestOnly }
    }
    $bad = @($rows | Where-Object { $_.status -in 'gone', 'notinwinget' })
    Write-Log "$(if ($bad.Count) { '[WARN]' } else { '[OK]' }) Checked $(@($rows).Count) pinned download(s)$(if ($bad.Count) { " - can't be installed any more: $(($bad | ForEach-Object { "$($_.name) $($_.version)" }) -join ', ')" })."
    return @{ ok = $true; rows = @($rows); bad = $bad.Count }
}

# ---------------------------------------------------------------- one release step per app at a time
# The page and the nightly run are separate processes: a file per app being
# changed (.integrity\busy next to the catalog) keeps them from releasing, assigning or withdrawing the
# same app at the same time. A file whose process is gone (or older than 3
# hours) doesn't count.

# Who is changing an app right now - next to the catalog (every admin's app sees it, also on another PC), with the
# person and the PC. On this PC a holder whose process ended doesn't count; one on another PC counts for 3 hours.
function Global:Get-WebBusyFile { param([string]$Name) Join-Path (Join-Path (Get-WebIntegrityFolder -Create) 'busy') ((Get-SafeFileNameForApp -Name $Name) + '.json') }

function Global:ConvertTo-WebUtcTicks {
    # A time from a busy marker as UTC ticks, however it was read: ticks (2.26.2), an ISO text, or the [datetime] PowerShell 7's ConvertFrom-Json makes of an ISO text.
    param($Value)
    if ($null -eq $Value -or '' -eq $Value) { return [int64]0 }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().Ticks }
    if ($Value -is [int64] -or $Value -is [int] -or $Value -is [double] -or $Value -is [decimal]) { return [int64]$Value }
    $t = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$t)) { return $t.Ticks }
    return [int64]0
}

function Global:Get-WebBusyHolder {
    # The record of whoever holds the app now (not this process), or $null.
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $b = $null
    try { $b = Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        # Being written right now (another PC's marker, half there): held - for a minute, then it doesn't count.
        try { if (((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $File).LastWriteTimeUtc).TotalSeconds -lt 60) { return [pscustomobject]@{ what = 'starting a change'; user = ''; machine = ''; started = (Get-Date).ToUniversalTime().Ticks } } } catch { }
        return $null
    }
    if (-not $b) { return $null }
    $started = ConvertTo-WebUtcTicks $b.started
    if (-not $started -or ((Get-Date).ToUniversalTime().Ticks - $started) -ge [TimeSpan]::FromHours(3).Ticks) { return $null }
    $here = -not $b.machine -or [string]$b.machine -eq [string]$env:COMPUTERNAME
    if ($here) {
        if ([int]$b.pid -eq $PID) { return $null }
        $p = Get-Process -Id ([int]$b.pid) -ErrorAction SilentlyContinue
        if (-not $p) { return $null }
        # Another user's process can't always be asked its start time: it's there, so it counts.
        $procStart = $null
        try { $procStart = $p.StartTime.ToUniversalTime().Ticks } catch { return $b }
        # The process with that number is another one now (the holder ended, its number was reused): not held.
        if ([math]::Abs($procStart - (ConvertTo-WebUtcTicks $b.procStart)) -gt [TimeSpan]::FromSeconds(1).Ticks) { return $null }
    }
    return $b
}

function Global:Format-WebBusyHolder {
    param($Holder)
    $who = if ($Holder.user) { "$($Holder.user)$(if ($Holder.machine -and $Holder.machine -ne $env:COMPUTERNAME) { " on $($Holder.machine)" })" } else { 'another window' }
    $ticks = ConvertTo-WebUtcTicks $Holder.started
    $since = if ($ticks) { ([datetime]::new($ticks, [DateTimeKind]::Utc)).ToLocalTime().ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture) } else { '' }
    return "$who - $($Holder.what)$(if ($since) { ", since $since" })"
}

function Global:Enter-WebAppBusy {
    <#
      '' when this process may work on the app (and now holds it), else who
      has it. Held per window with a count: a second click on the same app
      in this window is refused, while a step that continues one (-Shared:
      a release's assign) adds to it; the marker goes when the last lets go.
      The file is created at once (CreateNew), so two PCs can't both take it.
    #>
    param([string]$Name, [string]$What, [switch]$Shared)
    if (-not $Global:App.BusyHeld) { $Global:App.BusyHeld = [hashtable]::Synchronized(@{}) }
    $key = Get-SafeFileNameForApp -Name $Name
    $held = $Global:App.BusyHeld
    [System.Threading.Monitor]::Enter($held.SyncRoot)
    try {
        if ($held[$key] -gt 0) {
            if (-not $Shared) { return "$Name is being changed in this window already - wait until that step is done." }
            $held[$key] = [int]$held[$key] + 1
            return ''
        }
        $file = Get-WebBusyFile $Name
        $dir = Split-Path -Parent $file
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $holder = Get-WebBusyHolder $file
        if ($holder) { return "$Name is being changed right now by $(Format-WebBusyHolder $holder) - try again once that's done." }
        # Free (no marker, or one left behind): taken in one step - whoever creates the file first has it.
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        $me = Get-Process -Id $PID
        $rec = [ordered]@{ pid = $PID; procStart = $me.StartTime.ToUniversalTime().Ticks; started = (Get-Date).ToUniversalTime().Ticks; what = $What; user = [string]$env:USERNAME; machine = [string]$env:COMPUTERNAME }
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $rec -Compress))
        try {
            $fs = [System.IO.File]::Open($file, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
        }
        catch [System.IO.IOException] {
            $holder = Get-WebBusyHolder $file
            return "$Name is being changed right now by $(if ($holder) { Format-WebBusyHolder $holder } else { 'someone else' }) - try again once that's done."
        }
        $held[$key] = 1
        return ''
    }
    finally { [System.Threading.Monitor]::Exit($held.SyncRoot) }
}

function Global:Exit-WebAppBusy {
    # Lets go of the app once - the marker goes when the last step of this window holding it is done.
    param([string]$Name)
    $key = Get-SafeFileNameForApp -Name $Name
    $held = $Global:App.BusyHeld
    if ($held) {
        [System.Threading.Monitor]::Enter($held.SyncRoot)
        try {
            $n = [int]$held[$key] - 1
            if ($n -gt 0) { $held[$key] = $n; return }
            $held.Remove($key)
        }
        finally { [System.Threading.Monitor]::Exit($held.SyncRoot) }
    }
    $file = Get-WebBusyFile $Name
    try {
        if (Test-Path -LiteralPath $file) {
            $b = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$b.pid -eq $PID -and (-not $b.machine -or [string]$b.machine -eq [string]$env:COMPUTERNAME)) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        }
    }
    catch { }
}

function Global:Get-WebBusyApps {
    # Every app someone else is changing right now: safe file name -> who and what.
    $out = @{}
    $dir = Join-Path (Get-WebIntegrityFolder) 'busy'
    if (-not (Test-Path -LiteralPath $dir)) { return $out }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $h = Get-WebBusyHolder $f.FullName
        if ($h) { $out[$f.BaseName] = Format-WebBusyHolder $h }
    }
    return $out
}

function Global:Invoke-WebWauSwitch {
    <#
      Winget-AutoUpdate is gone (2.19): every app still installing through
      its Winget-Install.ps1, or depending on the WAU app, is switched to
      the default install method - managed updates (pinned to its App
      version, or the plain winget command until it has one) or the winget
      command - and its WAU dependency removed. -preview lists them without
      changing anything; -auto (at start) switches only the apps not in
      Intune yet, which need nothing sent. With Undo.
    #>
    param($Data)
    $all = @((Read-WebCatalogRecords).Apps)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($a in $all) { $use = @(Get-WauUse $a); if ($use.Count) { $rows.Add([ordered]@{ app = [string]$a.appName; use = $use; deployed = [bool]$a.appId; hasVersion = [bool](Test-ReleaseVersionText ([string]$(if ($a.metadata) { $a.metadata.appVersion }))) }) } }
    $wauApp = @($all | Where-Object { (Test-WauAppName $_.appName) -or (Test-WauAppName $_.wingetId) } | ForEach-Object { [string]$_.appName })
    if ($Data.preview) { return @{ ok = $true; apps = $rows.ToArray(); wauApp = $wauApp } }
    $undo = New-WebUndo 'Switch from Winget-AutoUpdate to managed updates'
    $changed = New-Object System.Collections.Generic.List[string]
    $noVersion = New-Object System.Collections.Generic.List[string]
    $managed = ([string]$Global:App.DefaultAppSettings.WingetInstallMethod) -ne 'Winget'
    $byHand = New-Object System.Collections.Generic.List[string]
    $dropped = New-Object System.Collections.Generic.List[string]
    $carried = New-Object System.Collections.Generic.List[string]
    $tookId = New-Object System.Collections.Generic.List[string]
    $mismatch = New-Object System.Collections.Generic.List[string]
    foreach ($a in @($all | Where-Object { @(Get-WauUse $_).Count })) {
        if (Get-WebAppRelease $a) { continue }
        if ($Data.auto -and $a.appId) { continue }
        $m = $a.metadata
        $before = (ConvertTo-Json @($m.installCommand, $m.uninstallCommand, @($m.dependencies), [bool]$a.managedUpdates) -Compress -Depth 4)
        if ($m.PSObject.Properties['dependencies']) { $m.dependencies = @(@($m.dependencies) | Where-Object { $_ -and -not (Test-WauAppName ([string]$_)) }) }
        $isWau = $a.wingetId -and -not (Test-StoreProductId ([string]$a.wingetId)) -and (Get-AppWingetInstallMethod -WingetId $a.wingetId -InstallCommand ([string]$m.installCommand) -UninstallCommand ([string]$m.uninstallCommand)) -eq 'WAU'
        # Commands in another wording (other path, quotes, switches) that still run Winget-Install.ps1 for this app's own ID are WAU's too.
        if (-not $isWau -and $a.wingetId -and -not (Test-StoreProductId ([string]$a.wingetId)) -and (Test-WauCommandForId -WingetId ([string]$a.wingetId) -Command ([string]$m.installCommand))) { $isWau = $true }
        # No Winget ID in the catalog yet: the one the WAU command installs is the app's (that's what devices got).
        # Another one than the catalog's: not guessed - the message names both.
        if (-not $isWau) {
            $cmdId = Get-WauCommandId ([string]$m.installCommand)
            if ($cmdId -and -not ([string]$a.wingetId).Trim()) { $a.wingetId = $cmdId; $tookId.Add("$($a.appName) ($cmdId)"); $isWau = $true }
            elseif ($cmdId -and [string]$a.wingetId -ine $cmdId) { $mismatch.Add("$($a.appName): the command installs $cmdId, the Winget ID says $($a.wingetId)"); continue }
        }
        if ($isWau) {
            # The winget options WAU passed after the ID (--override /S ...) carry over to winget's own command - when they're
            # options it may take (ConvertTo-WingetOptionText); others are left out and listed.
            $carry = ''
            $extras = Get-WauCommandExtras ([string]$m.installCommand)
            if ($extras) {
                $o = ConvertTo-WingetOptionText $extras
                if ($o.Ok) { $carry = $o.Options; $carried.Add("$($a.appName) ($carry)") } else { $dropped.Add("$($a.appName) ($extras - $($o.Error))") }
            }
            $hasVersion = Test-ReleaseVersionText ([string]$m.appVersion)
            # Managed updates only with a version to pin. Without one an app in Intune would be refused by Send (it needs
            # the version first) and keep WAU there - so it gets the plain winget command now, managed updates once it has one.
            if ($managed -and ($hasVersion -or -not $a.appId)) { $a.managedUpdates = $true }
            # The plain winget form first (with the carried options): Set-ManagedAppPin then pins exactly that, options included.
            $c = Get-WingetCommandLines -WingetId $a.wingetId -Method 'Winget' -InstallContext ([string]$m.installContext) -Options $carry
            # Pinned, the command gets a little longer still: options that would take it past Intune's 1024 characters are left out.
            if ($carry -and $c.Install.Length -gt 960) {
                $carried.Remove("$($a.appName) ($carry)") | Out-Null; $dropped.Add("$($a.appName) ($extras - too long for Intune's install command)"); $carry = ''
                $c = Get-WingetCommandLines -WingetId $a.wingetId -Method 'Winget' -InstallContext ([string]$m.installContext)
            }
            $m.installCommand = $c.Install; $m.uninstallCommand = $c.Uninstall
            $m.returnCodes = @(Add-WingetRetryReturnCode $m.returnCodes)
            if (-not ($a.managedUpdates -and (Set-ManagedAppPin $a)) -and $a.managedUpdates) { $noVersion.Add([string]$a.appName) }
            # Pinned, the command is longer: past Intune's 1024 characters the options stay out after all.
            if ($carry -and ([string]$m.installCommand).Length -gt 1024) {
                [void]$carried.Remove("$($a.appName) ($carry)"); $dropped.Add("$($a.appName) ($extras - too long for Intune's install command)")
                $c = Get-WingetCommandLines -WingetId $a.wingetId -Method 'Winget' -InstallContext ([string]$m.installContext)
                $m.installCommand = $c.Install; $m.uninstallCommand = $c.Uninstall
                if ($a.managedUpdates) { [void](Set-ManagedAppPin $a) }
            }
        }
        elseif (@(Get-WauUse $a) -contains 'commands') { $byHand.Add([string]$a.appName) }
        # Only what really changed counts (and is written): an app whose WAU commands were edited by hand stays as it is.
        if ((ConvertTo-Json @($m.installCommand, $m.uninstallCommand, @($m.dependencies), [bool]$a.managedUpdates) -Compress -Depth 4) -eq $before) { continue }
        Write-WebAppFile -App $a -Undo $undo
        $changed.Add([string]$a.appName)
    }
    if ($byHand.Count -and -not $Data.auto) { Write-Log "[WARN] Not switched - their Winget-AutoUpdate commands were edited by hand, change them in the editor (Install with): $($byHand -join ', ')." }
    if (-not $changed.Count) { return @{ ok = $true; changed = @(); noVersion = @(); deployed = @(); byHand = $byHand.ToArray(); mismatch = $mismatch.ToArray(); dropped = @(); carried = @(); wauApp = $wauApp } }
    if ($tookId.Count) { Write-Log "[OK] Took the Winget ID from the WAU command (none was set): $($tookId -join '; ')." }
    if ($mismatch.Count -and -not $Data.auto) { Write-Log "[WARN] Not switched - the WAU command installs another Winget ID than the app has: $($mismatch -join '; ')." }
    if ($carried.Count) { Write-Log "[OK] Carried WAU's extra winget options over: $($carried -join '; ')." }
    if ($dropped.Count) { Write-Log "[WARN] Left out WAU options winget's own command can't take: $($dropped -join '; ')." }
    Save-WebUndo $undo
    Write-Log "[OK] Switched $($changed.Count) app(s) from Winget-AutoUpdate to $(if ($managed) { 'managed updates' } else { 'the winget command' })$(if ($noVersion.Count) { " ($($noVersion.Count) still need an App version: $($noVersion -join ', '))" })."
    return @{ ok = $true; changed = $changed.ToArray(); noVersion = $noVersion.ToArray(); deployed = @($all | Where-Object { $changed -contains $_.appName -and $_.appId } | ForEach-Object { [string]$_.appName }); byHand = $byHand.ToArray(); mismatch = $mismatch.ToArray(); tookId = $tookId.ToArray(); dropped = $dropped.ToArray(); carried = $carried.ToArray(); wauApp = $wauApp }
}
