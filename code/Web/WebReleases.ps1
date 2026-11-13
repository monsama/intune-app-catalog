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

function Global:Get-WebReleaseInfo {
    # What the Release dialog shows for one app.
    param($Data)
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$($Data.name)' in the catalog." } }
    $pilot = Get-WebAppRelease $a
    $latest = if ($Global:App.WingetLatest -and $a.wingetId) { [string]$Global:App.WingetLatest[([string]$a.wingetId).ToLowerInvariant()] } else { '' }
    return @{ ok = $true; name = $a.appName; managed = [bool]$a.managedUpdates; wingetId = [string]$a.wingetId; appId = [string]$a.appId
        current = [string]$(if ($a.metadata) { $a.metadata.appVersion }); latest = $latest
        pilot = $(if ($pilot) { @{ version = $pilot.version; appId = $pilot.appId; at = $pilot.at } } else { $null })
        previous = @(@($a.releases) | Where-Object { $_.state -eq 'previous' } | ForEach-Object { @{ version = $_.version; appId = $_.appId; at = $_.at } })
        pilotGroups = @($Global:App.PilotGroups) }
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
    if (-not ($a.managedUpdates -and $a.wingetId)) { return @{ ok = $false; error = "$name doesn't have managed updates - turn them on first (More > Managed updates)." } }
    if (-not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune yet - Deploy it first; that is its first release." } }
    if (Get-WebAppRelease $a) { return @{ ok = $false; error = "$name already has a version in pilot - promote or withdraw it first." } }
    if (-not (Test-ReleaseVersionText $version)) { return @{ ok = $false; error = "'$version' isn't a version a release can pin (letters, digits and . - + _)." } }
    $current = [string]$(if ($a.metadata) { $a.metadata.appVersion })
    if ($version -eq $current) { return @{ ok = $false; error = "$name is at $version already." } }
    if (-not @($Global:App.PilotGroups).Count) { return @{ ok = $false; error = 'Set the pilot groups first: Settings > Defaults > Managed updates.' } }
    $pkg = Resolve-AppPackagePath -AppName $a.appName -Uncommon $false -PackagePath $a.packagePath
    if (-not $pkg.Found) { return @{ ok = $false; error = "The shared Winget package (init.intunewin) isn't built yet - Settings > Packaging & folders builds it." } }
    $defaults = $null
    $m = $a.metadata
    if (-not $m) { $defaults = Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon $false; $m = $defaults }
    $next = [pscustomobject]@{ managedUpdates = $true; wingetId = $a.wingetId; metadata = $m.PSObject.Copy() }
    $next.metadata.appVersion = $version
    [void](Set-ManagedAppPin $next)
    $resultPath = Join-Path $env:TEMP (".intunepkg_createapp_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = New-WebCreateAppConfig -Catalog $catalog -App $a -Metadata $next.metadata -Defaults $null -PackagePath $pkg.Path -ResultPath $resultPath
    $config.Mode = 'Create'; $config.ExistingAppId = ''
    $config.AppName = "$($a.appName) $version (pilot)"
    # Supersedes exactly the current release (update: devices that have it get this one) - not the catalog's own supersedence list.
    $config.Supersedence = @([pscustomobject]@{ appId = [string]$a.appId; type = 'update' })
    $config.IsFeatured = $null
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedCreateAppScript -Name 'createapp' -ConfigJson (ConvertTo-CreateAppConfigJson -Config $config) -ResultPath $resultPath -Kind "Release $name $version" `
        -After @{ Kind = 'release'; AppName = $a.appName; Version = $version }
    if ($started.ok) { Write-Log "[INFO] Releasing $name $version to pilot (a new app superseding $current)..." }
    return $started
}

function Global:Complete-WebRelease {
    # After step 1: the new app is the pilot release.
    param([hashtable]$After, $Result)
    $newId = [string]$Result.appId
    if ($newId -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') { return @{ ok = $false; error = 'The release step did not report the new app''s ID.' } }
    $version = [string]$After.Version
    [void](Update-WebCatalogApp -Name $After.AppName -Change {
            param($app)
            $app.releases = @(@($app.releases) | Where-Object { $_.state -ne 'pilot' }) + @([pscustomobject]@{ version = $version; appId = $newId; state = 'pilot'; at = (Get-Date).ToString('yyyy-MM-dd HH:mm') })
        }.GetNewClosure())
    Write-Log "[OK] $($After.AppName) $version is in Intune as a pilot release (App ID $newId)."
    return @{ ok = $true; assignPilot = $true; appId = $newId }
}

function Global:Start-WebReleaseAssign {
    <#
      Assignments for a release step (TargetedAssign - exactly these groups):
        pilot     the pilot app: Required to the pilot groups
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
    $none = @{ Required = @(); Available = @(); Uninstall = @(); Exclude = @() }
    switch ($step) {
        'pilot' { if (-not $pilot) { return @{ ok = $false; error = "$($a.appName) has no pilot release." } }; $id = $pilot.appId; $g = @{ Required = @($Global:App.PilotGroups); Available = @(); Uninstall = @(); Exclude = @($a.excludeFor) }; $label = "Assign $($a.appName) $($pilot.version) to pilot" }
        'promote' { if (-not $pilot) { return @{ ok = $false; error = "$($a.appName) has no pilot release." } }; $id = $pilot.appId; $g = @{ Required = @($a.requiredFor); Available = @($a.availableFor); Uninstall = @($a.uninstallFor); Exclude = @($a.excludeFor) }; $label = "Promote $($a.appName) $($pilot.version)" }
        'retire' { if (-not $a.appId) { return @{ ok = $false; error = "$($a.appName) has no current release." } }; $id = $a.appId; $g = $none; $label = "Retire $($a.appName) $(if ($a.metadata) { $a.metadata.appVersion })" }
        'withdraw' { if (-not $pilot) { return @{ ok = $false; error = "$($a.appName) has no pilot release." } }; $id = $pilot.appId; $g = $none; $label = "Withdraw $($a.appName) $($pilot.version)" }
        default { return @{ ok = $false; error = 'Unknown release step.' } }
    }
    $resultPath = Join-Path $env:TEMP (".intunepkg_assign_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        AppId = $id; AppName = $a.appName
        RequiredGroups = @($g.Required); AvailableGroups = @($g.Available); UninstallGroups = @($g.Uninstall); ExcludeGroups = @($g.Exclude)
        CreateMissingGroups = ($step -eq 'pilot'); OutputResultPath = $resultPath
    }
    return (Start-WebStepJob -ScriptContent $Global:App.EmbeddedTargetedAssignScript -Name 'targetedassign' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath -Kind $label)
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
    [void](Set-ManagedAppPin $a)
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
        if (-not $a.wingetId) { $skipped.Add("$($a.appName) (no Winget ID)"); continue }
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
