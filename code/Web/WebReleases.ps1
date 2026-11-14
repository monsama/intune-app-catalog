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
    if (-not @($Global:App.PilotGroups).Count) { return @{ ok = $false; error = 'Set the pilot groups first: Settings > Updates.' } }
    $pkg = Resolve-AppPackagePath -AppName $a.appName -Uncommon $own -PackagePath $a.packagePath
    if (-not $pkg.Found) { return @{ ok = $false; error = $(if ($own) { "$name has no package to upload - put the new installer in its folder and build it (the release dialog does both)." } else { "The shared Winget package (init.intunewin) isn't built yet - Settings > Packaging & folders builds it." }) } }
    $defaults = $null
    $m = $a.metadata
    if (-not $m) { $defaults = Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon $own; $m = $defaults }
    if ($own) { $why = Test-VersionDetectionRule $m.detectionRule; if ($why) { return @{ ok = $false; error = "${name}: $why" } } }
    $next = [pscustomobject]@{ managedUpdates = $true; wingetId = $a.wingetId; metadata = $m.PSObject.Copy() }
    $next.metadata.appVersion = $version
    [void](Set-ManagedAppPin $next -ProductCode ([string]$Data.productCode))
    $resultPath = Join-Path $env:TEMP (".intunepkg_createapp_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = New-WebCreateAppConfig -Catalog $catalog -App $a -Metadata $next.metadata -Defaults $null -PackagePath $pkg.Path -ResultPath $resultPath
    $config.Mode = 'Create'; $config.ExistingAppId = ''
    $config.AppName = "$($a.appName) $version (pilot)"
    # Supersedes exactly the current release (update: devices that have it get this one) - not the catalog's own supersedence list.
    $config.Supersedence = @([pscustomobject]@{ appId = [string]$a.appId; type = 'update' })
    $config.IsFeatured = $null
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedCreateAppScript -Name 'createapp' -ConfigJson (ConvertTo-CreateAppConfigJson -Config $config) -ResultPath $resultPath -Kind "Release $name $version" `
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
            $now = (Get-Date).ToString('yyyy-MM-dd HH:mm')
            $app.releases = @(@($app.releases) | Where-Object { $_.state -ne 'pilot' }) + @([pscustomobject]@{ version = $version; appId = $newId; state = 'pilot'; at = $now; productCode = $code; ring = 0; ringAt = $now; fastTrack = $fast })
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
        RequiredSettings = $(if ($step -in 'pilot', 'advance', 'promote', 'rollback') { Get-ReleaseAssignmentSettings -Policy $Global:App.ReleasePolicy -FastTrack ([bool]($pilot -and $pilot.fastTrack -and $step -ne 'rollback')) -NowUtc ([datetime]::UtcNow) } else { $null })
    }
    return (Start-WebStepJob -ScriptContent $Global:App.EmbeddedTargetedAssignScript -Name 'targetedassign' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath -Kind $label -Apps @([string]$a.appName))
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
    $pilot.ring = $next; $pilot.ringAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
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
    $a.metadata.appVersion = [string]$pilot.version
    [void](Set-ManagedAppPin $a -ProductCode ([string]$pilot.productCode))
    $kept = @(@($a.releases) | Where-Object { $_.state -ne 'pilot' })
    if ($oldId) { $kept += [pscustomobject]@{ version = $oldVersion; appId = $oldId; state = 'previous'; at = (Get-Date).ToString('yyyy-MM-dd HH:mm') } }
    $a.releases = $kept
    $a.appId = [string]$pilot.appId
    Write-WebAppFile -App $a -Undo $undo
    Save-WebUndo $undo
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
    $msi = Get-ChildItem -LiteralPath $folder -Filter '*.msi' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $exe = Get-ChildItem -LiteralPath $folder -Filter '*.exe' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
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
    # Pure: an app's superseded releases, oldest first ("at" sorts as text: yyyy-MM-dd HH:mm).
    param($App)
    return @(@($App.releases) | Where-Object { $_ -and $_.state -eq 'previous' } | Sort-Object { [string]$_.at }, { [string]$_.version })
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
    $a.metadata.appVersion = [string]$prev.version
    [void](Set-ManagedAppPin $a -ProductCode ([string]$prev.productCode))
    $a.releases = @(@($a.releases) | Where-Object { [string]$_.appId -ne [string]$prev.appId }) + @([pscustomobject]@{ version = $oldVersion; appId = $oldId; state = 'previous'; at = (Get-Date).ToString('yyyy-MM-dd HH:mm'); productCode = '' })
    $a.appId = [string]$prev.appId
    Write-WebAppFile -App $a -Undo $undo
    Save-WebUndo $undo
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
    if ($prev.Count -le 1) { return @{ ok = $true; removed = @(); failed = @(); kept = @($prev | ForEach-Object { $_.version }) } }
    $old = @($prev | Select-Object -First ($prev.Count - 1))
    if ($Data.planOnly) { return @{ ok = $true; plan = @($old | ForEach-Object { $_.version }); removed = @(); failed = @(); kept = @($prev[-1].version) } }
    $removed = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $old.Count; $i++) {
        $target = [string]$old[$i].appId
        $parent = [string]$prev[$i + 1].appId
        $res = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action {
            param($Graph)
            $rels = @((& $Graph "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$parent/relationships").value)
            $keep = @($rels | Where-Object { $_ -and ([string]$_.targetType -eq 'child' -or -not $_.targetType) -and [string]$_.targetId -ne $target } | ForEach-Object {
                    $r = @{ '@odata.type' = [string]$_.'@odata.type'; targetId = [string]$_.targetId }
                    if ([string]$_.'@odata.type' -like '*Supersedence') { $r.supersedenceType = [string]$_.supersedenceType } else { $r.dependencyType = [string]$_.dependencyType }
                    $r
                })
            if (@($rels | Where-Object { [string]$_.targetId -eq $target }).Count) {
                [void](& $Graph "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$parent/updateRelationships" 'POST' @{ relationships = @($keep) })
            }
            [void](& $Graph "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$target" 'DELETE')
            $true
        }
        if ($res.ok) { $removed.Add([string]$old[$i].version) } else { $failed.Add("$($old[$i].version): $($res.error)") }
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
    Write-Log "[$(if ($failed.Count) { 'WARN' } else { 'OK' })] $($a.appName): deleted superseded release(s) $($removed -join ', ') from Intune$(if ($failed.Count) { "; not deleted: $($failed -join '; ')" }); kept $($prev[-1].version) for rollback."
    return @{ ok = ($failed.Count -eq 0); removed = $removed.ToArray(); failed = $failed.ToArray(); kept = @($prev[-1].version); error = $(if ($failed.Count) { "Not deleted: $($failed -join '; ')" } else { '' }) }
}
