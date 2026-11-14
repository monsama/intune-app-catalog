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
        checkedAt = $(if ($f.CheckedAt) { ([datetime]$f.CheckedAt).ToString('yyyy-MM-dd HH:mm') } else { '' })
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
    try { Load-LastAuditCache } catch { }
    foreach ($f in @(Get-CachedAuditFindings -Apps $apps -LastAuditResults $Global:App.LastAuditResults)) { $findings.Add($f) }

    $read = $null
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
            $intuneApps = @(& $pages 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$select=id,displayName&$top=999' |
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
            $notes.Add("Compared with $(@($read.value.IntuneApps).Count) app(s) in Intune; $(@($read.value.Directory).Count) of the $($read.value.Wanted) group(s) the catalog uses found in Entra ID$(if (-not $read.value.ByName) { ' (read in full - this tenant refused a lookup by name)' }).")
        }
        else { $notes.Add("Intune and Entra ID could not be checked: $($read.error)") }
    }
    $rows = @($findings | ForEach-Object { ConvertTo-WebFindingRow $_ })
    Write-Log "[INFO] Checks: $($rows.Count) finding(s). $($notes -join ' ')"
    return @{ ok = $true; findings = $rows; notes = $notes.ToArray(); deployed = @($apps | Where-Object { $_.appId } | ForEach-Object { $_.appName }).Count
        winget = @($apps | Where-Object { $_.wingetId } | ForEach-Object { $_.appName }).Count; connected = [bool]($read -and $read.ok) }
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
        -Kind "Check $($apps.Count) deployed app(s) in detail" -After @{ Kind = 'checkdetails'; Names = @($apps | ForEach-Object { [string]$_.appName }) })
}

function Global:Complete-WebCheckDetails {
    # SyncMetadata's results as Metadata / Groups / Dependencies findings, and into the last-audit cache (the Apps list's Last audit).
    param([hashtable]$After, $Result)
    $catalog = @((Read-WebCatalogRecords).Apps)
    try { Load-LastAuditCache } catch { }
    $new = New-Object System.Collections.Generic.List[object]
    foreach ($one in @($Result.results)) {
        $app = @($catalog | Where-Object { [string]$_.appName -eq [string]$one.AppName }) | Select-Object -First 1
        if (-not $app) { continue }
        # A Microsoft Store app has no install commands or detection in Intune to compare - its settings aren't checked.
        $isStore = Test-StoreProductId ([string]$app.wingetId)
        foreach ($f in @(Get-AppDetailFindings -CatalogApp $app -Result $one)) { if ($isStore -and [string]$f.Area -eq 'Metadata') { continue }; $new.Add($f) }
        $texts = Get-AuditSummaryTexts -CatalogApp $app -Result $one
        Set-LastAuditCacheEntry -AppName ([string]$one.AppName) -Metadata $texts.Metadata -Groups $texts.Groups -Dependencies $texts.Dependencies
    }
    Save-LastAuditCache
    return @{ ok = $true; areas = @('Metadata', 'Groups', 'Dependencies'); names = @($After.Names); findings = @($new | ForEach-Object { ConvertTo-WebFindingRow $_ }) }
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
        Apps = @($apps | ForEach-Object { @{ AppName = $_.appName; AppId = $_.appId; RequiredGroups = @($_.requiredFor); AvailableGroups = @($_.availableFor); UninstallGroups = @($_.uninstallFor); ExcludeGroups = @($_.excludeFor) } }) }
    return (Start-WebStepJob -ScriptContent $Global:App.EmbeddedBatchAssignScript -Name 'checksassign' -ConfigJson ($config | ConvertTo-Json -Depth 8) -ResultPath $resultPath `
        -Kind "Check $($apps.Count) app(s)' assignments" -After @{ Kind = 'checkassign'; Names = @($apps | ForEach-Object { [string]$_.appName }) })
}

function Global:Complete-WebCheckAssign {
    param([hashtable]$After, $Result)
    $catalog = @((Read-WebCatalogRecords).Apps)
    try { Load-LastAuditCache } catch { }
    $new = New-Object System.Collections.Generic.List[object]
    foreach ($one in @($Result.data)) {
        $app = @($catalog | Where-Object { [string]$_.appName -eq [string]$one.AppName }) | Select-Object -First 1
        if (-not $app) { continue }
        foreach ($f in @(Get-UnknownAssignmentFindings -CatalogApp $app -ToRemove @($one.ToRemove))) { $new.Add($f) }
        Set-LastAuditCacheEntry -AppName ([string]$one.AppName) -Unknown (Get-UnknownAssignmentText @($one.ToRemove))
    }
    Save-LastAuditCache
    return @{ ok = $true; areas = @('Unknown assignments'); names = @($After.Names); findings = @($new | ForEach-Object { ConvertTo-WebFindingRow $_ }) }
}

function Global:Invoke-WebCheckWinget {
    # Asks winget about each Winget ID (or -names'). One at a time: winget is a process each time, and they share one source cache.
    param($Data)
    $apps = @(Get-WebCheckApps -Names @($Data.names) | Where-Object { $_.wingetId })
    if ($apps.Count -eq 0) { return @{ ok = $true; areas = @('Winget ID'); names = @(); findings = @() } }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return @{ ok = $false; error = "winget.exe isn't on this machine, so Winget IDs can't be checked. It comes with the 'App Installer' package on Windows 10 and 11." } }
    $results = @($apps | ForEach-Object { Test-WingetPackageId -AppName $_.appName -WingetId $_.wingetId })
    # The newest version winget offers, kept for the Apps list ("Newer on winget") until the app restarts.
    if (-not $Global:App.WingetLatest) { $Global:App.WingetLatest = [hashtable]::Synchronized(@{}) }
    foreach ($r in $results) { if ($r.Ok -and $r.Version) { $Global:App.WingetLatest[([string]$r.WingetId).ToLowerInvariant()] = [string]$r.Version } }
    $new = @(Get-WingetFindings -Results $results -Apps @((Read-WebCatalogRecords).Apps))
    Write-Log "[INFO] winget: asked about $($apps.Count) Winget ID(s), $($new.Count) problem(s)."
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
    Write-Log "[OK] Took winget's version for $($changed.Count) app(s) in the catalog$(if ($changed.Count) { ': ' + ($changed -join ', ') })."
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
        -Kind "Add $($items.Count) app(s) from Intune" -After @{ Kind = 'addtocatalog'; Ids = @($items | ForEach-Object { @{ Name = ([string]$_.name).Trim(); Id = [string]$_.id } }) })
}

function Global:ConvertTo-WebCatalogEntryFromSync {
    # Pure: a catalog entry from one SyncMetadata result (which carries no App ID - it's passed in) - what Add to catalog writes.
    param($Result, [string]$AppId)
    $r = $Result
    $groupsKnown = [bool]$r.GroupFetchOk
    return [pscustomobject]@{
        appId = $AppId; appName = ([string]$r.AppName).Trim()
        wingetId = $(if ($r.Metadata) { Get-WingetIdFromInstallCommand -InstallCommand ([string]$r.Metadata.installCommand) } else { '' })
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
        [System.IO.File]::WriteAllText($file, (ConvertTo-SingleAppJson -App $entry), (New-Object System.Text.UTF8Encoding($false)))
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
                # The install commands name the package too - left as they were, they would go on installing the old ID.
                if ($old -and $a.metadata) {
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
