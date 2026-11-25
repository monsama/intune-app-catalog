# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    The web interface's Checks page: every check, and the fixes for what
    they find. The findings come from the same
    functions (code\Private\Catalog\CheckFindings.ps1).

    Stages:
      checks-run      the catalog's dependencies, the Intune link (apps
                      only in Intune, renamed, App ID gone or missing),
                      Entra groups, and what the last audit found
      checks-details  each deployed app's metadata, groups and dependencies
                      against Intune (SyncMetadata step, a job)
      checks-assign   assignments in Intune the catalog doesn't have
                      (BatchAssign Preview, a job)
      checks-winget   Winget IDs winget no longer knows
#>

function Global:ConvertTo-WebFindingRow {
    # A finding (New-CheckFinding) as the page's row.
    param($Finding)
    $f = $Finding
    return [ordered]@{
        key = [string]$f.Key; area = [string]$f.Area; app = [string]$f.App; catalogName = [string]$f.CatalogName; appId = [string]$f.AppId
        problem = [string]$f.Problem; catalog = (Get-CheckValueText $f.Catalog); intune = (Get-CheckValueText $f.Intune)
        actions = @($f.Actions); failed = [bool]$f.Failed; cached = [bool]$f.Cached
        checkedAt = $(if ($f.CheckedAt) { ([datetime]$f.CheckedAt).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) } else { '' })
        data = $f.Data
    }
}

function Global:Get-WebCheckApps {
    # The catalog's apps, narrowed to -Names when given.
    param([string[]]$Names)
    $apps = @((Read-WebCatalogRecords).Apps)
    $wanted = @($Names | Where-Object { $_ })
    if ($wanted.Count) { $apps = @($apps | Where-Object { $wanted -contains [string]$_.appName }) }
    return $apps
}

function Global:Get-WebIntuneApps {
    <#
      The ids of every app in the connected tenant, for the Apps list to
      tell "Deployed" from an App ID this tenant doesn't know (a catalog
      copied from another tenant, an app deleted in Intune). Kept for five
      minutes per connection; -force reads again.
    #>
    param($Data)
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; state = 'none'; error = 'Not connected.' } }
    $key = "$($Global:App.GraphTenantId)|$($Global:App.GraphClientId)"
    $cache = $Global:App.IntuneAppsCache
    if (-not $Data.force -and $cache -and $cache.Key -eq $key -and ((Get-Date) - $cache.At).TotalMinutes -lt 5) {
        return @{ ok = $true; ids = $cache.Ids; apps = $cache.Apps; at = $cache.At.ToString('HH:mm'); cached = $true }
    }
    $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action {
        param($Graph)
        $list = New-Object System.Collections.Generic.List[object]
        $uri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$select=id,displayName&$top=999'
        while ($uri) {
            $page = & $Graph $uri
            foreach ($v in @($page.value)) {
                # Built first, then added: [ordered] straight inside a method call doesn't parse in Windows PowerShell.
                $odataType = [string]$v.'@odata.type'
                $one = [ordered]@{ id = ([string]$v.id).ToLowerInvariant(); name = [string]$v.displayName; type = ($odataType -replace '^#microsoft\.graph\.', '') }
                $list.Add($one)
            }
            $uri = [string]$page.'@odata.nextLink'
        }
        , $list.ToArray()
    }
    if (-not $read.ok) { return @{ ok = $false; state = 'error'; error = $read.error } }
    # Every app in the tenant: its id for "is this App ID here", its name and type for "only in Intune" on the Apps page.
    $appsNow = @($read.value)
    $Global:App.IntuneAppsCache = @{ Key = $key; At = (Get-Date); Ids = @($appsNow | ForEach-Object { $_.id }); Apps = $appsNow }
    return @{ ok = $true; ids = @($appsNow | ForEach-Object { $_.id }); apps = $appsNow; at = (Get-Date).ToString('HH:mm'); cached = $false }
}

function Global:Get-WebCatalogGroupNames {
    # Pure: every group name the apps use, in any role, once (case-insensitively), sorted.
    param($Apps)
    $seen = @{}
    foreach ($a in @($Apps)) {
        foreach ($g in @(@($a.requiredFor) + @($a.availableFor) + @($a.uninstallFor) + @($a.excludeFor))) {
            $n = ([string]$g).Trim() -replace '\s+', ' '
            # All users / All devices: Intune's own targets, never looked up in Entra ID.
            if (Get-AllTargetInfo $n) { continue }
            if ($n -and -not $seen.ContainsKey($n.ToLowerInvariant())) { $seen[$n.ToLowerInvariant()] = $n }
        }
    }
    return @($seen.Values | Sort-Object)
}

function Global:Invoke-WebChecks {
    <#
      The checks that need no step script. -names narrows them to some apps
      (Re-check); the Intune and Entra ID reads still cover the whole tenant,
      since "not in the catalog" can only be said about all of it.
    #>
    param($Data)
    $names = @($Data.names | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $all = @((Read-WebCatalogRecords).Apps)
    $apps = @(if ($names.Count) { $all | Where-Object { $names -contains [string]$_.appName } } else { $all })
    $findings = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-DependencyFindings -Apps $all)) { if (-not $names.Count -or $names -contains [string]$f.CatalogName) { $findings.Add($f) } }
    # Own packages: what doesn't fit together in the package (2.36.0) - local, no Intune needed.
    foreach ($a in @($apps | Where-Object { -not $_.wingetId -and $_.metadata })) {
        $ws = @(Get-WebPackageWarnings $a)
        if ($ws.Count) { $findings.Add((New-CheckFinding -Area 'Package' -App $a.appName -CatalogName $a.appName -AppId ([string]$a.appId) -Problem ($ws -join ' ') -Actions @('EditApp'))) }
    }
    try { Load-LastAuditCache } catch { }
    foreach ($f in @(Get-CachedAuditFindings -Apps $apps -LastAuditResults $Global:App.LastAuditResults)) { $findings.Add($f) }

    $read = $null
    $summary = ''
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { $notes.Add('Intune and Entra ID were not checked: no connection set up (Settings).') }
    elseif (-not (Test-GraphModuleHere)) { $notes.Add("Intune and Entra ID were not checked: the Microsoft.Graph.Authentication module isn't installed.") }
    else {
        $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All and Group.Read.All' -Action {
            param($Graph)
            $pages = {
                param([string]$Uri)
                $items = New-Object System.Collections.Generic.List[object]
                while ($Uri) { $page = & $Graph $Uri; foreach ($v in @($page.value)) { $items.Add($v) }; $Uri = [string]$page.'@odata.nextLink' }
                # One item at a time: the callers pipe this into ForEach-Object,
                # which would otherwise get the whole list as a single item.
                $items.ToArray()
            }
            # Windows apps only (2.38.32): the tenant's iOS, Android and macOS apps were "in Intune, not in the catalog" -
            # with Add to catalog - while the Apps page leaves them out, as this catalog is for Windows.
            $winTypes = '^(win32LobApp|winGetApp|windowsMicrosoftEdgeApp|officeSuiteApp|windowsMobileMSI|windowsUniversalAppX|windowsStoreApp|microsoftStoreForBusinessApp|windowsWebApp|webApp|windowsAppX|win32CatalogApp)$'
            $intuneApps = @(& $pages 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$select=id,displayName&$top=999' |
                Where-Object { -not [string]$_.'@odata.type' -or (([string]$_.'@odata.type') -replace '^#?microsoft\.graph\.', '') -match $winTypes } |
                ForEach-Object { [pscustomobject]@{ id = [string]$_.id; displayName = [string]$_.displayName } })
            # Only the groups the catalog names, 15 to a request - not every group
            # and user in the tenant, which in a big one is hundreds of pages.
            # A tenant that refuses the "in" filter gets the full list instead.
            $directory = New-Object System.Collections.Generic.List[object]
            $wanted = @(Get-WebCatalogGroupNames -Apps $apps)
            $byName = $true
            try {
                foreach ($uri in @(Get-GroupLookupUris -Names $wanted)) {
                    foreach ($g in @(& $pages $uri)) { $directory.Add([pscustomobject]@{ displayName = [string]$g.displayName; type = 'Group'; id = [string]$g.id; upn = '' }) }
                }
            }
            catch {
                $byName = $false
                $directory.Clear()
                foreach ($g in @(& $pages 'https://graph.microsoft.com/v1.0/groups?$select=id,displayName&$top=999')) { $directory.Add([pscustomobject]@{ displayName = [string]$g.displayName; type = 'Group'; id = [string]$g.id; upn = '' }) }
            }
            @{ IntuneApps = $intuneApps; Directory = $directory.ToArray(); Wanted = $wanted.Count; ByName = $byName }
        }
        if ($read.ok) {
            foreach ($f in @(Get-IntuneLinkFindings -Apps $all -IntuneApps $read.value.IntuneApps)) {
                if (-not $names.Count -or -not $f.CatalogName -or $names -contains [string]$f.CatalogName) { $findings.Add($f) }
            }
            foreach ($f in @(Get-EntraGroupFindings -Apps $apps -Directory $read.value.Directory)) { $findings.Add($f) }
            # What was compared - not a warning (notes are what was NOT compared). Only the catalog's groups count, also when the tenant was read in full.
            # Each catalog group once (two Entra groups of one name count once), spacing as Get-EntraGroupFindings compares it.
            $norm = { param($t) (([string]$t).Trim() -replace '\s+', ' ').ToLowerInvariant() }
            $wantedSet = @{}; foreach ($n in @(Get-WebCatalogGroupNames -Apps $apps)) { $wantedSet[(& $norm $n)] = $true }
            $foundCount = @($read.value.Directory | ForEach-Object { & $norm $_.displayName } | Where-Object { $wantedSet.ContainsKey($_) } | Select-Object -Unique).Count
            $summary = "Compared with $(Format-Count (@($read.value.IntuneApps).Count) 'app') in Intune; $foundCount of the $(Format-Count ($read.value.Wanted) 'group') the catalog uses found in Entra ID$(if (-not $read.value.ByName) { ' (read in full - this tenant refused a lookup by name)' })."

        }
        else { $notes.Add("Intune and Entra ID could not be checked: $($read.error)") }
    }
    $rows = @($findings | ForEach-Object { ConvertTo-WebFindingRow $_ })
    Write-Log "[INFO] Checks: $(Format-Count ($rows.Count) 'finding'). $summary $($notes -join ' ')"
    return @{ ok = $true; findings = $rows; notes = $notes.ToArray(); summary = $summary; deployed = @($apps | Where-Object { $_.appId } | ForEach-Object { $_.appName }).Count
        winget = @($apps | Where-Object { $_.wingetId -and -not (Test-StoreProductId ([string]$_.wingetId)) } | ForEach-Object { $_.appName }).Count; connected = [bool]($read -and $read.ok) }
}

function Global:Start-WebCheckDetails {
    # Each deployed app (or -names) against Intune: SyncMetadata, read-only. Complete-WebCheckDetails turns it into findings.
    param($Data)
    $apps = @(Get-WebCheckApps -Names @($Data.names) | Where-Object { $_.appId })
    if ($apps.Count -eq 0) { return @{ ok = $false; error = 'No deployed app to check.' } }
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_checks_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{ TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        Apps = @($apps | ForEach-Object { @{ AppName = $_.appName; AppId = $_.appId } }); OutputResultPath = $resultPath }
    return (Start-WebStepJob -ScriptContent $Global:App.EmbeddedSyncMetadataScript -Name 'checksdetails' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath `
        -Kind "Check $(Format-Count ($apps.Count) 'deployed app') in detail" -After @{ Kind = 'checkdetails'; Names = @($apps | ForEach-Object { [string]$_.appName }) })
}

function Global:Complete-WebCheckDetails {
    # SyncMetadata's results as Metadata / Groups / Dependencies findings, and into the last-audit cache (the Apps list's Last audit).
    param([hashtable]$After, $Result)
    $catalog = @((Read-WebCatalogRecords).Apps)
    try { Load-LastAuditCache } catch { }
    $new = New-Object System.Collections.Generic.List[object]
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($one in @($Result.results)) {
        $app = @($catalog | Where-Object { [string]$_.appName -eq [string]$one.AppName }) | Select-Object -First 1
        if (-not $app) { continue }
        # Linked to a Microsoft Store app (new) but without its Store ID in the catalog (2.38.30): Intune says what it is -
        # taken over (Company Portal and the like showed as an own installer).
        $sid = Get-StoreIdFromSync $one
        if ($sid -and -not $app.wingetId -and -not $app.office) {
            # One app's catalog file busy (another admin saving) mustn't fail the whole check (2.38.31) - said, and left for the next run.
            try {
                [void](Update-WebCatalogApp -Name ([string]$app.appName) -Change { param($x) $x.wingetId = $sid; $x.intuneAppType = 'Microsoft Store app (new)'; $x.managedUpdates = $false }.GetNewClosure())
                Add-WebHistoryEntry -App ([string]$app.appName) -Kind 'catalog' -Text "Store product ID $sid taken from Intune (it is a Microsoft Store app there)"
                Write-Log "[OK] $($app.appName): Store product ID $sid taken from Intune - it is a Microsoft Store app there."
                $changed.Add([string]$app.appName)
                $fresh = @((Read-WebCatalogRecords).Apps | Where-Object { [string]$_.appName -eq [string]$one.AppName }) | Select-Object -First 1
                if ($fresh) { $app = $fresh }
            }
            catch { Write-Log "[WARN] $($app.appName) is a Microsoft Store app in Intune ($sid), but its Store ID couldn't be saved now: $($_.Exception.Message) - the next check tries again." }
        }
        # Its own earlier releases (2.38.33): a promotion leaves the new app superseding the old one in Intune, and apps that
        # depend on it still pointing at "<name> <version> (superseded)". Neither is a difference the catalog has to know.
        # A managed app is compared as it would be sent (2.38.38): pinned to its version in today's form - a file written
        # by an earlier version kept the old detection script and return codes, which were never what Intune gets.
        if ($app.managedUpdates -and $app.wingetId -and $app.metadata) {
            $app = $app.PSObject.Copy(); $app.metadata = $app.metadata.PSObject.Copy(); [void](Set-ManagedAppPin $app)
        }
        # 2.38.34: on the catalog's side too - an earlier Pull may have stored the old release's ID or name there.
        if ($one.Metadata) {
            $catNames = @($catalog | ForEach-Object { [string]$_.appName })
            $one.Metadata = Get-MetadataWithoutOwnReleases -Metadata $one.Metadata -App $app -CatalogNames $catNames
            if ($app.metadata) { $app = $app.PSObject.Copy(); $app.metadata = Get-MetadataWithoutOwnReleases -Metadata $app.metadata -App $app -CatalogNames $catNames }
        }
        # A Microsoft Store app has no install commands or detection in Intune to compare - its settings aren't checked.
        # Nor Intune's other own types (2.38.42) - only a Win32 app's settings are sent from here.
        $isStore = (Test-StoreProductId ([string]$app.wingetId)) -or [bool]$app.office -or (-not ([string]$app.wingetId).Trim() -and [bool](Get-NonPackageAppHint $app))
        # Nor their dependencies (2.38.32): Intune's Store and Microsoft 365 app types take none from here - a permanent "differ".
        foreach ($f in @(Get-AppDetailFindings -CatalogApp $app -Result $one)) { if ($isStore -and [string]$f.Area -in 'Metadata', 'Dependencies') { continue }; $new.Add($f) }
        $texts = Get-AuditSummaryTexts -CatalogApp $app -Result $one
        # Store apps and Microsoft 365 Apps: their settings aren't compared (above) - the audit says OK for them too (2.38.31:
        # Home kept "differs" for fields Intune doesn't have on those types).
        if ($isStore) { $texts.Metadata = 'OK'; $texts.Dependencies = 'OK' }
        # Microsoft 365 Apps' own settings (2.38.42): compared with what Intune has - a channel or app changed in the
        # portal was neither seen nor pulled, and the next send put the catalog's back without a word.
        if ($app.office -and -not ([string]$app.wingetId).Trim() -and $app.appId) {
            $od = Get-WebOfficeDiff -App $app
            if ($od) {
                $new.Add((New-CheckFinding -Area 'Metadata' -App ([string]$app.appName) -CatalogName ([string]$app.appName) -AppId ([string]$app.appId) -Problem 'Microsoft 365 settings differ' -Catalog $od.Local -Intune $od.Remote -Actions @('PushMetadata', 'Pull')))
                $texts.Metadata = 'Microsoft 365 settings differ'
            }
        }
        Set-LastAuditCacheEntry -AppName ([string]$one.AppName) -Metadata $texts.Metadata -Groups $texts.Groups -Dependencies $texts.Dependencies
    }
    Save-LastAuditCache
    return @{ ok = $true; areas = @('Metadata', 'Groups', 'Dependencies'); names = @($After.Names); findings = @($new | ForEach-Object { ConvertTo-WebFindingRow $_ }); changed = $changed.ToArray() }
}

function Global:Start-WebCheckAssign {
    # Assignments Intune has that the catalog doesn't: BatchAssign in Preview, which changes nothing.
    param($Data)
    $apps = @(Get-WebCheckApps -Names @($Data.names) | Where-Object { $_.appId })
    if ($apps.Count -eq 0) { return @{ ok = $false; error = 'No deployed app to check.' } }
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_checks_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{ TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        Mode = 'Preview'; OutputResultPath = $resultPath
        Apps = @($apps | ForEach-Object { @{ AppName = $_.appName; AppId = $_.appId; RequiredGroups = @($_.requiredFor); AvailableGroups = @($_.availableFor); UninstallGroups = @($_.uninstallFor); ExcludeGroups = @($_.excludeFor); FilterName = [string]$_.assignmentFilter; FilterMode = [string]$_.assignmentFilterMode } }) }
    return (Start-WebStepJob -ScriptContent $Global:App.EmbeddedBatchAssignScript -Name 'checksassign' -ConfigJson ($config | ConvertTo-Json -Depth 8) -ResultPath $resultPath `
        -Kind "Check $(Format-Count ($apps.Count) 'app')' assignments" -After @{ Kind = 'checkassign'; Names = @($apps | ForEach-Object { [string]$_.appName }) })
}

function Global:Complete-WebCheckAssign {
    param([hashtable]$After, $Result)
    $catalog = @((Read-WebCatalogRecords).Apps)
    try { Load-LastAuditCache } catch { }
    $new = New-Object System.Collections.Generic.List[object]
    foreach ($one in @($Result.data)) {
        $app = @($catalog | Where-Object { [string]$_.appName -eq [string]$one.AppName }) | Select-Object -First 1
        if (-not $app) { continue }
        $chg = Get-AssignmentChangeFindings -CatalogApp $app -ToAdd @($one.ToAdd) -ToRemove @($one.ToRemove)
        foreach ($f in @($chg.Findings)) { $new.Add($f) }
        Set-LastAuditCacheEntry -AppName ([string]$one.AppName) -Unknown ([string]$chg.Text)
    }
    Save-LastAuditCache
    return @{ ok = $true; areas = @('Unknown assignments', 'Assignment filter'); names = @($After.Names); findings = @($new | ForEach-Object { ConvertTo-WebFindingRow $_ }) }
}

function Global:Invoke-WebCheckWinget {
    # Asks winget about each Winget ID (or -names'). One at a time: winget is a process each time, and they share one source cache.
    param($Data)
    # Store product IDs aren't winget packages (2.38.32): winget's index doesn't have them, so every Store app showed
    # "Winget no longer has this package" - they are asked of the Store's own catalog (the Store tab) instead.
    $apps = @(Get-WebCheckApps -Names @($Data.names) | Where-Object { $_.wingetId -and -not (Test-StoreProductId ([string]$_.wingetId)) })
    if ($apps.Count -eq 0 -and -not @(Get-WebCheckApps -Names @($Data.names) | Where-Object { -not $_.wingetId -and $_.watchWinget }).Count) { return @{ ok = $true; areas = @('Winget ID'); names = @(); findings = @() } }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue) -and -not (Test-WingetIndexUsable)) { return @{ ok = $false; error = "winget.exe isn't on this machine, so Winget IDs can't be checked. It comes with the 'App Installer' package on Windows 10 and 11." } }
    $results = @($apps | ForEach-Object { Test-WingetPackageId -AppName $_.appName -WingetId $_.wingetId })
    # Own packages that watch a winget package for new versions (2.36.0): only its newest version is wanted.
    $watched = @(Get-WebCheckApps -Names @($Data.names) | Where-Object { -not $_.wingetId -and $_.watchWinget } | ForEach-Object { Test-WingetPackageId -AppName $_.appName -WingetId $_.watchWinget })
    # The newest version winget offers, kept for the Apps list ("Newer on winget") until the app restarts.
    if (-not $Global:App.WingetLatest) { $Global:App.WingetLatest = [hashtable]::Synchronized(@{}) }
    foreach ($r in @($results) + @($watched)) { if ($r.Ok -and $r.Version) { $Global:App.WingetLatest[([string]$r.WingetId).ToLowerInvariant()] = [string]$r.Version } }
    $new = @(Get-WingetFindings -Results $results -Apps @((Read-WebCatalogRecords).Apps))
    Write-Log "[INFO] winget: asked about $(Format-Count ($apps.Count) 'Winget ID'), $(Format-Count ($new.Count) 'problem')."
    return @{ ok = $true; areas = @('Winget ID'); names = @($apps | ForEach-Object { [string]$_.appName }); findings = @($new | ForEach-Object { ConvertTo-WebFindingRow $_ })
        versions = @($results | Where-Object { $_.Version } | ForEach-Object { [ordered]@{ app = [string]$_.AppName; version = [string]$_.Version } }) }
}

function Global:Set-WebWingetVersions {
    <#
      Takes winget's newest version (from the last ask, Invoke-WebCheckWinget)
      as the catalog's App version of the named apps - with Undo. The
      install command doesn't change: Winget apps always install winget's
      latest; the version is what Intune and the Company Portal show.
    #>
    param($Data)
    $names = @($Data.names | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if (-not $names.Count) { return @{ ok = $false; error = 'Choose one or more apps first.' } }
    $latest = $Global:App.WingetLatest
    $undo = New-WebUndo "Take winget's version"
    $changed = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($a in @((Read-WebCatalogRecords).Apps | Where-Object { $names -contains $_.appName })) {
        $v = if ($latest -and $a.wingetId) { [string]$latest[([string]$a.wingetId).ToLowerInvariant()] } else { '' }
        if (-not $v) { $skipped.Add("$($a.appName) (winget not asked yet)"); continue }
        # A deployed managed app gets a new version only through a release (pilot first) - except its first one:
        # an app just switched to managed updates has none yet, and winget's is where it starts.
        if ($a.managedUpdates -and $a.appId -and $a.metadata -and [string]$a.metadata.appVersion) { $skipped.Add("$($a.appName) (managed - use Release new version)"); continue }
        if (-not $a.metadata) { $a.metadata = Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon (Test-AppIsUncommon -App $a) }
        if ([string]$a.metadata.appVersion -eq $v) { continue }
        if ($a.metadata.PSObject.Properties.Name -contains 'appVersion') { $a.metadata.appVersion = $v } else { $a.metadata | Add-Member -NotePropertyName appVersion -NotePropertyValue $v }
        [void](Set-ManagedAppPin $a)
        Write-WebAppFile -App $a -Undo $undo
        $changed.Add($a.appName)
    }
    Save-WebUndo $undo
    Write-Log "[OK] Took winget's version for $(Format-Count ($changed.Count) 'app') in the catalog$(if ($changed.Count) { ': ' + ($changed -join ', ') })."
    return @{ ok = $true; changed = $changed.ToArray(); skipped = $skipped.ToArray(); deployed = @((Read-WebCatalogRecords).Apps | Where-Object { $_.appId -and $changed -contains $_.appName } | ForEach-Object { $_.appName }) }
}

function Global:Find-WebWinget {
    # winget search, for Add app and Find Winget ID.
    param($Data)
    $q = ([string]$Data.q).Trim()
    if ($q.Length -lt 2) { return @{ ok = $false; error = 'Type at least 2 characters.' } }
    if ($q.Length -gt 100) { return @{ ok = $false; error = 'That is too long to search for.' } }
    try { $rows = @(Find-WingetPackage -Query $q) }
    catch { return @{ ok = $false; error = $_.Exception.Message } }
    return @{ ok = $true; rows = @($rows | Select-Object -First 100 | ForEach-Object { [ordered]@{ name = $_.Name; id = $_.Id; version = $_.Version; source = $_.Source } }) }
}

function Global:Find-WebStoreApps {
    <#
      Add apps > Microsoft Store (2.38.13): the Store's own catalog, as winget's msstore source asks it - on the server
      too, where there is no winget. On Windows, if the service doesn't answer, winget's own search (its Store results).
    #>
    param($Data)
    $q = ([string]$Data.q).Trim()
    if ($q.Length -lt 2) { return @{ ok = $false; error = 'Type at least 2 characters.' } }
    if ($q.Length -gt 100) { return @{ ok = $false; error = 'That is too long to search for.' } }
    $why = ''
    try {
        $body = @{ Query = @{ KeyWord = $q; MatchType = 'Substring' } } | ConvertTo-Json -Depth 4 -Compress
        # TLS 1.2 and UTF-8 bytes: Windows PowerShell 5.1 would otherwise send a non-Latin query as '?'.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-WebRequest -Method Post -Uri 'https://storeedgefd.dsx.mp.microsoft.com/v9.0/manifestSearch' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 -UseBasicParsing
        # The answer is a few KB; anything far larger is not the Store (a proxy page, a broken answer) - don't parse it.
        if (([string]$resp.Content).Length -gt 2MB) { throw 'the answer was too large' }
        $answer = ([string]$resp.Content) | ConvertFrom-Json
        $rows = @(ConvertFrom-StoreSearchResult $answer)
        return @{ ok = $true; source = 'store'; rows = @($rows | Select-Object -First 60 | ForEach-Object { [ordered]@{ name = $_.Name; id = $_.Id; publisher = $_.Publisher; version = '' } }) }
    }
    catch { $why = $_.Exception.Message }
    if (-not ($IsLinux -or $IsMacOS)) {
        try {
            $rows = @(Find-WingetPackage -Query $q | Where-Object { Test-StoreProductId ([string]$_.Id) })
            return @{ ok = $true; source = 'winget'; rows = @($rows | Select-Object -First 60 | ForEach-Object { [ordered]@{ name = $_.Name; id = $_.Id; publisher = ''; version = '' } }) }
        }
        catch { $why = "$why / winget: $($_.Exception.Message)" }
    }
    return @{ ok = $false; error = "The Microsoft Store couldn't be searched ($why). Its catalog is at storeedgefd.dsx.mp.microsoft.com - a proxy or firewall may block it." }
}

function Global:Start-WebAddFromIntune {
    # Add to catalog: reads the Intune-only apps (SyncMetadata) and adds them with their settings and groups.
    param($Data)
    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $items = @(@($Data.apps) | Where-Object { [string]$_.id -match $guid -and ([string]$_.name).Trim() })
    if ($items.Count -eq 0) { return @{ ok = $false; error = 'Nothing to add.' } }
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_sync_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{ TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        Apps = @($items | ForEach-Object { @{ AppName = ([string]$_.name).Trim(); AppId = [string]$_.id } }); OutputResultPath = $resultPath }
    return (Start-WebStepJob -ScriptContent $Global:App.EmbeddedSyncMetadataScript -Name 'syncmeta' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath `
        -Kind "Add $(Format-Count ($items.Count) 'app') from Intune" -After @{ Kind = 'addtocatalog'; Ids = @($items | ForEach-Object { @{ Name = ([string]$_.name).Trim(); Id = [string]$_.id } }) })
}

function Global:ConvertTo-WebCatalogEntryFromSync {
    # Pure: a catalog entry from one SyncMetadata result (which carries no App ID - it's passed in) - what Add to catalog writes.
    param($Result, [string]$AppId)
    $r = $Result
    $groupsKnown = [bool]$r.GroupFetchOk
    return [pscustomobject]@{
        appId = $AppId; appName = ([string]$r.AppName).Trim()
        wingetId = $(if (Get-StoreIdFromSync $r) { Get-StoreIdFromSync $r } elseif ($r.Metadata) { Get-WingetIdFromInstallCommand -InstallCommand ([string]$r.Metadata.installCommand) } else { '' })
        intuneAppType = Get-FriendlyIntuneAppType -ODataType ([string]$r.OdataType); intuneAppVersion = [string]$r.DisplayVersion
        requiredFor = $(if ($groupsKnown) { @(@($r.RequiredGroupNames) | Where-Object { $_ }) } else { @() })
        availableFor = $(if ($groupsKnown) { @(@($r.AvailableGroupNames) | Where-Object { $_ }) } else { @() })
        uninstallFor = $(if ($groupsKnown) { @(@($r.UninstallGroupNames) | Where-Object { $_ }) } else { @() })
        excludeFor = @()
        metadata = $r.Metadata
    }
}

function Global:Complete-WebAddFromIntune {
    param([hashtable]$After, $Result)
    $folder = Get-AppFolder -Kind Catalog -Create
    $existing = @((Read-WebCatalogRecords).Apps | ForEach-Object { ([string]$_.appName).ToLowerInvariant() })
    $added = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $noGroups = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($Result.results)) {
        $name = ([string]$r.AppName).Trim()
        if (-not $r.Success) { $skipped.Add("$name ($($r.Error))"); continue }
        if ($existing -contains $name.ToLowerInvariant()) { $skipped.Add("$name (already in the catalog)"); continue }
        $id = [string](@($After.Ids | Where-Object { $_.Name -eq $name }) | Select-Object -First 1).Id
        $entry = ConvertTo-AppRecord (ConvertTo-WebCatalogEntryFromSync -Result $r -AppId $id)
        if (-not $r.GroupFetchOk) { $noGroups.Add($name) }
        $file = Join-Path $folder ((Get-SafeFileNameForApp -Name $entry.appName) + '.json')
        if (Test-Path -LiteralPath $file) { $skipped.Add("$name (a file with its name exists)"); continue }
        Save-WebAppJson -File $file -App $entry -Text 'Added from Intune'
        $added.Add($name); $existing += $name.ToLowerInvariant()
    }
    Write-Log "[OK] Added from Intune: $($added.Count)$(if ($skipped.Count) { "; skipped: $($skipped -join ', ')" })$(if ($noGroups.Count) { "; groups couldn't be read for: $($noGroups -join ', ')" })."
    return @{ ok = $true; added = $added.ToArray(); skipped = $skipped.ToArray(); noGroups = $noGroups.ToArray() }
}

function Global:Invoke-WebCheckFix {
    # The fixes that change only the catalog: take Intune's name, set or clear the App ID, set the Winget ID.
    param($Data)
    $name = [string]$Data.catalogName
    $action = [string]$Data.action
    switch ($action) {
        'RenameFromIntune' {
            $newName = ([string]$Data.value).Trim()
            if (-not $newName) { return @{ ok = $false; error = 'No name to take.' } }
            $catalog = Read-WebCatalogRecords
            $existing = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
            if (-not $existing) { return @{ ok = $false; error = "'$name' is no longer in the catalog." } }
            $edit = Get-WebAppEditable $existing
            $edit.appName = $newName
            return (Save-WebApp ([pscustomobject]@{ originalName = $name; app = [pscustomobject]$edit }))
        }
        'SetAppId' {
            $id = [guid]::Empty
            if (-not [guid]::TryParse([string]$Data.value, [ref]$id)) { return @{ ok = $false; error = 'Not an App ID.' } }
            $idText = $id.ToString()
            [void](Update-WebCatalogApp -Name $name -Change { param($app) $app.appId = $idText }.GetNewClosure())
            Write-Log "[OK] $name now points at the Intune app $idText."
            return @{ ok = $true }
        }
        'ClearAppId' {
            [void](Update-WebCatalogApp -Name $name -Change { param($app) $app.appId = '' })
            Write-Log "[OK] Cleared $name's App ID (it no longer exists in Intune)."
            return @{ ok = $true }
        }
        'SetWingetId' {
            $new = ([string]$Data.value).Trim()
            if ($new -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$') { return @{ ok = $false; error = "That isn't a Winget ID winget would accept." } }
            $app = Update-WebCatalogApp -Name $name -Change {
                param($a)
                $old = [string]$a.wingetId
                $a.wingetId = $new
                # The install commands and the detection name the package too - left as they were, they would go on with the old ID.
                if ($old -and $a.metadata -and -not (Set-AppWingetIdCommands -App $a -OldId $old)) {
                    foreach ($field in 'installCommand', 'uninstallCommand') {
                        $cmd = [string]$a.metadata.$field
                        if ($cmd -and $cmd.Contains($old)) { $a.metadata.$field = $cmd.Replace($old, $new) }
                    }
                }
            }.GetNewClosure()
            Write-Log "[OK] $name's Winget ID is now $new$(if ($app.metadata) { ' (install commands updated too)' })."
            return @{ ok = $true }
        }
        default { return @{ ok = $false; error = "Unknown fix '$action'." } }
    }
}
