# The one list the Checks window shows. Every check this app runs - how
# the catalog lines up with the tenant's apps, each deployed app's
# metadata/groups/dependencies/assignments against Intune, the catalog's
# own dependencies, its groups against Entra ID, its Winget IDs - turns its
# data into the same kind of row here, so a single list can hold them all
# and a single set of buttons can fix them.
#
# Pure: no WinForms, no Graph. The window does the reading and hands the
# results in; these only decide what is a problem, how to say it, and
# which fixes apply. That is also what makes them testable without Intune.
#
# Actions are keys the window knows how to carry out, most useful first:
#   Pull            take Intune's metadata and groups into the catalog
#   PushMetadata    send the catalog's metadata to Intune
#   PushGroups      send the catalog's groups to Intune
#   AddToCatalog    add an Intune-only app to the catalog
#   RenameFromIntune  rename the catalog entry to Intune's name
#   ClearAppId      forget an App ID Intune no longer has
#   SetAppId        record the App ID of the Intune app that matches
#   ChooseAppId     pick which Intune app this catalog entry is
#   EditApp         open the app in the editor
#   FindWingetId    look for the package's new Winget ID

function Global:New-CheckFinding {
    param(
        [string]$Area, [string]$App, [string]$CatalogName = "", [string]$AppId = "",
        [string]$Problem, [string]$Catalog = "", [string]$Intune = "",
        [string[]]$Actions = @(), [switch]$Failed, $Data = $null
    )
    return [pscustomobject]@{
        # Stable across runs, so a re-check can replace exactly the rows it
        # is about and a selection can survive it.
        Key         = "$Area|$CatalogName|$AppId|$App"
        Area        = $Area
        App         = $App
        CatalogName = $CatalogName
        AppId       = $AppId
        Problem     = $Problem
        Catalog     = $Catalog
        Intune      = $Intune
        Actions     = @($Actions)
        Failed      = [bool]$Failed
        Cached      = $false
        CheckedAt   = $null
        Data        = $Data
    }
}

function Global:Find-IntuneNameMatches {
    # Find-IntuneMatches' matching, against a list handed in rather than
    # the global cache: exact (whitespace-normalised) names first, then
    # names that contain one another.
    param([string]$Name, $IntuneApps)
    $results = New-Object System.Collections.Generic.List[object]
    if (-not $Name) { return $results.ToArray() }
    $normalizedName = ($Name.Trim() -replace '\s+', ' ')
    foreach ($candidate in @($IntuneApps)) {
        if (-not $candidate -or -not $candidate.displayName) { continue }
        if (((([string]$candidate.displayName).Trim()) -replace '\s+', ' ') -eq $normalizedName) { $results.Add($candidate) }
    }
    foreach ($candidate in @($IntuneApps)) {
        if (-not $candidate -or -not $candidate.displayName) { continue }
        $normDisplay = ([string]$candidate.displayName).Trim() -replace '\s+', ' '
        if ($normDisplay -ne $normalizedName -and ($normDisplay -like "*$normalizedName*" -or $normalizedName -like "*$normDisplay*")) {
            $results.Add($candidate)
        }
    }
    return $results.ToArray()
}

function Global:Get-IntuneLinkFindings {
    # How the catalog's entries line up with the tenant's apps - what the
    # old "Sync check" and "App IDs" tabs each answered half of.
    #   Not in catalog       an Intune app nothing in the catalog is
    #   Renamed in Intune    same App ID, different name
    #   App ID not in Intune the catalog's App ID is gone from the tenant
    #   App ID not set       a catalog app with no App ID that an Intune
    #                        app matches by name (exactly, or possibly)
    # A catalog app with no App ID and no match at all is simply not
    # deployed yet - not a problem, so not a row.
    #
    # -Scoped: only these catalog apps are being checked, so the tenant's
    # other apps are none of this run's business.
    param($Apps, $IntuneApps, [switch]$Scoped)

    $findings = New-Object System.Collections.Generic.List[object]
    $drift = Get-IntuneCatalogDrift -Apps @($Apps) -IntuneApps @($IntuneApps)

    if (-not $Scoped) {
        foreach ($missing in @($drift.Missing | Sort-Object displayName)) {
            $findings.Add((New-CheckFinding -Area "Intune link" -App ([string]$missing.displayName) -AppId ([string]$missing.id) `
                -Problem "In Intune, not in the catalog" -Catalog "(not in catalog)" -Intune ([string]$missing.displayName) `
                -Actions @("AddToCatalog")))
        }
    }
    foreach ($renamed in @($drift.Renamed | Sort-Object IntuneName)) {
        $findings.Add((New-CheckFinding -Area "Intune link" -App ([string]$renamed.CatalogName) -CatalogName ([string]$renamed.CatalogName) -AppId ([string]$renamed.Id) `
            -Problem "Renamed in Intune" -Catalog ([string]$renamed.CatalogName) -Intune ([string]$renamed.IntuneName) `
            -Actions @("RenameFromIntune") -Data ([pscustomobject]@{ IntuneName = [string]$renamed.IntuneName })))
    }
    foreach ($gone in @($drift.DeletedFromIntune | Sort-Object appName)) {
        $findings.Add((New-CheckFinding -Area "Intune link" -App ([string]$gone.appName) -CatalogName ([string]$gone.appName) -AppId ([string]$gone.appId) `
            -Problem "App ID not in Intune any more" -Catalog ([string]$gone.appId) -Intune "(no such app)" `
            -Actions @("ClearAppId")))
    }

    # App IDs already taken by a catalog entry can't be another one's match
    $usedIds = @{}
    foreach ($a in @($Apps)) { if ($a -and $a.appId) { $usedIds[[string]$a.appId] = $true } }
    foreach ($a in @($Apps | Where-Object { $_ -and -not $_.appId } | Sort-Object appName)) {
        $candidates = @(Find-IntuneNameMatches -Name ([string]$a.appName) -IntuneApps $IntuneApps | Where-Object { -not $usedIds.ContainsKey([string]$_.id) })
        if ($candidates.Count -eq 0) { continue }
        $normName = ([string]$a.appName).Trim() -replace '\s+', ' '
        $exact = @($candidates | Where-Object { (([string]$_.displayName).Trim() -replace '\s+', ' ') -eq $normName })
        if ($exact.Count -eq 1) {
            $findings.Add((New-CheckFinding -Area "Intune link" -App ([string]$a.appName) -CatalogName ([string]$a.appName) `
                -Problem "In Intune, App ID not set" -Catalog "(no App ID)" -Intune "$($exact[0].displayName) [$($exact[0].id)]" `
                -Actions @("SetAppId", "ChooseAppId") -Data ([pscustomobject]@{ MatchedId = [string]$exact[0].id; MatchedName = [string]$exact[0].displayName; Candidates = $candidates })))
        }
        else {
            $findings.Add((New-CheckFinding -Area "Intune link" -App ([string]$a.appName) -CatalogName ([string]$a.appName) `
                -Problem "Possibly in Intune, App ID not set" -Catalog "(no App ID)" -Intune "$($candidates.Count) possible match(es): $((@($candidates | Select-Object -First 3 | ForEach-Object { $_.displayName })) -join ', ')" `
                -Actions @("ChooseAppId") -Data ([pscustomobject]@{ Candidates = $candidates })))
        }
    }
    return $findings.ToArray()
}

function Global:Get-AuditSummaryTexts {
    # The one-line answers the Last Audit column and its detail window
    # have always shown, from one app's SyncMetadata result - kept word for
    # word, since Get-LastAuditSummary and Show-LastAuditDetail read them.
    param($CatalogApp, $Result)
    if (-not $Result.Success) {
        $failed = "Failed: $($Result.Error)"
        return [pscustomobject]@{ Metadata = $failed; Groups = $failed; Dependencies = $failed; MetadataDiffs = @(); GroupDiffs = @() }
    }
    $metaDiffs = @(Get-CatalogMetadataFieldDiffs -Local $CatalogApp.metadata -Remote $Result.Metadata -OdataType $Result.OdataType)
    $metadataText = if ($metaDiffs.Count -eq 0) { "OK" } else { "$($metaDiffs.Count) field(s) differ: $(($metaDiffs | ForEach-Object { $_.Field }) -join ', ')" }
    $groupDiffs = @()
    if ($Result.GroupFetchOk) {
        $groupDiffs = @(Get-GroupFieldDiffs -LocalApp $CatalogApp -RemoteResult $Result)
        $groupsText = Format-GroupFieldDiffs -Diffs $groupDiffs
    }
    else { $groupsText = "Failed: could not fetch live assignments" }
    $liveDeps = @(@($Result.Metadata.dependencies) | Where-Object { $_ } | Sort-Object)
    $localDeps = @(@($CatalogApp.metadata.dependencies) | Where-Object { $_ } | Sort-Object)
    if (($liveDeps -join "|") -eq ($localDeps -join "|")) { $depsText = "OK" }
    else {
        $liveText = if ($liveDeps.Count -gt 0) { $liveDeps -join ", " } else { "(none)" }
        $localText = if ($localDeps.Count -gt 0) { $localDeps -join ", " } else { "(none)" }
        $depsText = "Catalog has: $localText | Intune has: $liveText"
    }
    return [pscustomobject]@{ Metadata = $metadataText; Groups = $groupsText; Dependencies = $depsText; MetadataDiffs = $metaDiffs; GroupDiffs = $groupDiffs }
}

function Global:Get-AppDetailFindings {
    # One deployed app against what Intune says about it, from its
    # SyncMetadata result: metadata, groups, dependencies. One row per area
    # that differs; a failed read is a row too, since "could not check" is
    # not "fine".
    param($CatalogApp, $Result)
    $findings = New-Object System.Collections.Generic.List[object]
    $name = [string]$CatalogApp.appName
    $id = [string]$CatalogApp.appId
    $texts = Get-AuditSummaryTexts -CatalogApp $CatalogApp -Result $Result
    if (-not $Result.Success) {
        $findings.Add((New-CheckFinding -Area "Metadata" -App $name -CatalogName $name -AppId $id -Problem "Could not check: $($Result.Error)" -Failed -Actions @("Recheck")))
        return $findings.ToArray()
    }
    if (@($texts.MetadataDiffs).Count -gt 0) {
        $diffs = @($texts.MetadataDiffs)
        $findings.Add((New-CheckFinding -Area "Metadata" -App $name -CatalogName $name -AppId $id -Problem $texts.Metadata `
            -Catalog ((@($diffs | ForEach-Object { "$($_.Field): $(Get-CheckValueText $_.Local)" })) -join "; ") `
            -Intune ((@($diffs | ForEach-Object { "$($_.Field): $(Get-CheckValueText $_.Remote)" })) -join "; ") `
            -Actions @("Pull", "PushMetadata") -Data ([pscustomobject]@{ Diffs = $diffs })))
    }
    if ($texts.Groups -like "Failed*") {
        $findings.Add((New-CheckFinding -Area "Groups" -App $name -CatalogName $name -AppId $id -Problem $texts.Groups -Failed -Actions @("Recheck")))
    }
    elseif (@($texts.GroupDiffs).Count -gt 0) {
        $gd = @($texts.GroupDiffs)
        $findings.Add((New-CheckFinding -Area "Groups" -App $name -CatalogName $name -AppId $id -Problem "$($gd.Count) assignment list(s) differ: $((@($gd | ForEach-Object { $_.Field })) -join ', ')" `
            -Catalog ((@($gd | ForEach-Object { "$($_.Field): $(Get-CheckValueText $_.Local)" })) -join "; ") `
            -Intune ((@($gd | ForEach-Object { "$($_.Field): $(Get-CheckValueText $_.Remote)" })) -join "; ") `
            -Actions @("Pull", "PushGroups") -Data ([pscustomobject]@{ Diffs = $gd })))
    }
    if ($texts.Dependencies -ne "OK") {
        $parts = $texts.Dependencies -split ' \| Intune has: ', 2
        $findings.Add((New-CheckFinding -Area "Dependencies" -App $name -CatalogName $name -AppId $id -Problem "Dependencies differ" `
            -Catalog ($parts[0] -replace '^Catalog has: ', '') -Intune $(if ($parts.Count -gt 1) { $parts[1] } else { "" }) `
            -Actions @("Pull", "PushMetadata")))
    }
    return $findings.ToArray()
}

function Global:Get-CheckValueText {
    # A compared value as one short line - blank reads as (blank), not as
    # nothing at all.
    param($Value)
    $text = (([string]$Value) -replace '\r?\n', ' ').Trim()
    if (-not $text) { return "(blank)" }
    if ($text.Length -gt 120) { return $text.Substring(0, 120) + "..." }
    return $text
}

function Global:Get-UnknownAssignmentText {
    # The Last Audit wording for one app's assignment preview.
    param($ToRemove)
    $items = @(@($ToRemove) | Where-Object { $_ })
    if ($items.Count -eq 0) { return "OK" }
    return "$($items.Count) unknown: $($items -join ', ')"
}

function Global:Get-UnknownAssignmentFindings {
    # Assignments Intune has that the catalog doesn't know about - a push
    # of the catalog's groups would remove them.
    param($CatalogApp, $ToRemove)
    $items = @(@($ToRemove) | Where-Object { $_ })
    if ($items.Count -eq 0) { return @() }
    return @(New-CheckFinding -Area "Unknown assignments" -App ([string]$CatalogApp.appName) -CatalogName ([string]$CatalogApp.appName) -AppId ([string]$CatalogApp.appId) `
        -Problem (Get-UnknownAssignmentText $items) -Catalog "(not in the catalog)" -Intune ($items -join ", ") -Actions @("PushGroups", "Pull"))
}

function Global:Get-DependencyFindings {
    # The catalog's own dependencies: an app depending on a name that
    # isn't in the catalog, or apps depending on each other in a circle
    # (which no deploy order can satisfy). Nothing asks Intune.
    param($Apps, [string[]]$OnlyNames)
    $findings = New-Object System.Collections.Generic.List[object]
    $allApps = @(@($Apps) | Where-Object { $_ })
    $names = @{}
    foreach ($a in $allApps) { $names[[string]$a.appName] = $true }
    $circular = @((Get-DependencyOrderedApps -Apps $allApps).CircularNames)
    foreach ($a in @($allApps | Sort-Object appName)) {
        $name = [string]$a.appName
        if ($OnlyNames -and $OnlyNames -notcontains $name) { continue }
        $deps = @(@($a.metadata.dependencies) | Where-Object { $_ })
        if ($circular -contains $name) {
            $findings.Add((New-CheckFinding -Area "Catalog dependencies" -App $name -CatalogName $name -AppId ([string]$a.appId) `
                -Problem "Circular dependency" -Catalog "Depends on: $($deps -join ', ')" -Actions @("EditApp")))
            continue
        }
        $missing = @($deps | Where-Object { -not $names.ContainsKey([string]$_) })
        if ($missing.Count -gt 0) {
            $findings.Add((New-CheckFinding -Area "Catalog dependencies" -App $name -CatalogName $name -AppId ([string]$a.appId) `
                -Problem "Depends on an app that isn't in the catalog" -Catalog "Missing: $($missing -join ', ')" -Actions @("EditApp")))
        }
    }
    return $findings.ToArray()
}

function Global:Get-EntraGroupFindings {
    # Group names the catalog assigns (or excludes) that don't exist in
    # Entra ID - an assignment to one reaches nobody. One row per group,
    # naming the apps that use it.
    param($Apps, $Directory, [string[]]$OnlyNames)
    $known = @{}
    foreach ($entry in @($Directory)) {
        if ($entry -and [string]$entry.type -eq 'Group' -and $entry.displayName) {
            $known[(([string]$entry.displayName).Trim() -replace '\s+', ' ').ToLowerInvariant()] = $true
        }
    }
    $usage = [ordered]@{}
    foreach ($a in @(@($Apps) | Where-Object { $_ } | Sort-Object appName)) {
        if ($OnlyNames -and $OnlyNames -notcontains [string]$a.appName) { continue }
        foreach ($groupName in @(@($a.requiredFor) + @($a.availableFor) + @($a.uninstallFor) + @($a.excludeFor) | Where-Object { $_ })) {
            $normGroup = ([string]$groupName).Trim() -replace '\s+', ' '
            if (-not $usage.Contains($normGroup)) { $usage[$normGroup] = New-Object System.Collections.Generic.List[string] }
            if (-not $usage[$normGroup].Contains([string]$a.appName)) { $usage[$normGroup].Add([string]$a.appName) }
        }
    }
    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($groupName in @($usage.Keys | Sort-Object)) {
        if ($known.ContainsKey($groupName.ToLowerInvariant())) { continue }
        $users = @($usage[$groupName])
        $appLabel = if ($users.Count -eq 1) { $users[0] } else { "$($users.Count) apps" }
        $findings.Add((New-CheckFinding -Area "Entra groups" -App $appLabel -CatalogName $(if ($users.Count -eq 1) { $users[0] } else { "" }) `
            -Problem "Group `"$groupName`" doesn't exist in Entra ID" -Catalog "Used by: $($users -join ', ')" -Intune "(not in Entra ID)" `
            -Actions $(if ($users.Count -eq 1) { @("EditApp") } else { @() }) -Data ([pscustomobject]@{ Group = $groupName; Apps = $users })))
    }
    return $findings.ToArray()
}

function Global:Get-WingetFindings {
    # Winget IDs winget no longer knows (new devices can't install the
    # app), and ones it couldn't be asked about. Input: the winget check's
    # {AppName, WingetId, Ok, Result} rows.
    param($Results, $Apps)
    $findings = New-Object System.Collections.Generic.List[object]
    $idByName = @{}
    foreach ($a in @($Apps)) { if ($a) { $idByName[[string]$a.appName] = [string]$a.appId } }
    foreach ($r in @(@($Results) | Where-Object { $_ -and -not $_.Ok })) {
        $name = [string]$r.AppName
        $gone = [string]$r.Result -like 'NOT FOUND*'
        $findings.Add((New-CheckFinding -Area "Winget ID" -App $name -CatalogName $name -AppId ([string]$idByName[$name]) `
            -Problem $(if ($gone) { "Winget no longer has this package" } else { [string]$r.Result }) `
            -Catalog ([string]$r.WingetId) -Intune "" -Failed:(-not $gone) `
            -Actions $(if ($gone) { @("FindWingetId") } else { @() })))
    }
    return $findings.ToArray()
}

function Global:Get-CachedAuditFindings {
    # What the last audit found, for opening the window on something other
    # than a blank list - the same Last Audit cache the grid's column
    # reads. Marked Cached, with the time of that check, so the window can
    # show them as not fresh.
    param($Apps, $LastAuditResults, [string[]]$OnlyNames)
    $findings = New-Object System.Collections.Generic.List[object]
    if (-not $LastAuditResults) { return $findings.ToArray() }
    $areaMap = [ordered]@{
        Metadata     = @{ Area = "Metadata"; Actions = @("Pull", "PushMetadata") }
        Groups       = @{ Area = "Groups"; Actions = @("Pull", "PushGroups") }
        Dependencies = @{ Area = "Dependencies"; Actions = @("Pull", "PushMetadata") }
        Unknown      = @{ Area = "Unknown assignments"; Actions = @("PushGroups", "Pull") }
    }
    foreach ($a in @(@($Apps) | Where-Object { $_ -and $_.appId } | Sort-Object appName)) {
        $name = [string]$a.appName
        if ($OnlyNames -and $OnlyNames -notcontains $name) { continue }
        if (-not $LastAuditResults.ContainsKey($name)) { continue }
        $entry = $LastAuditResults[$name]
        foreach ($field in $areaMap.Keys) {
            $value = [string]$entry.$field
            if (-not $value -or $value -eq "OK") { continue }
            $isFailed = $value -like "Failed*"
            $finding = New-CheckFinding -Area $areaMap[$field].Area -App $name -CatalogName $name -AppId ([string]$a.appId) `
                -Problem $value -Failed:$isFailed -Actions $(if ($isFailed) { @("Recheck") } else { $areaMap[$field].Actions })
            $finding.Cached = $true
            $checkedText = if ($entry.Checked -and $entry.Checked.$field) { [string]$entry.Checked.$field } else { [string]$entry.Timestamp }
            $parsed = [datetime]::MinValue
            if ($checkedText -and [datetime]::TryParse($checkedText, [ref]$parsed)) { $finding.CheckedAt = $parsed }
            elseif ($entry.Timestamp -is [datetime]) { $finding.CheckedAt = $entry.Timestamp }
            $findings.Add($finding)
        }
    }
    return $findings.ToArray()
}
