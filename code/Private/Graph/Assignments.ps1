# What an app's Intune assignments should look like, and what they look like
# right now - in one place, because three things need exactly the same answer:
# the single-app push (TargetedAssign.ps1), the multi-app push
# (BatchAssign.ps1) and the audit's drift check.
#
# An assignment here is one (intent, mode, group):
#   intent - required / available / uninstall
#   mode   - include (the group gets the app) or exclude (it doesn't, even if
#            another included group would have covered it)
# Excluded groups are stored once per app (excludeFor) and applied to every
# intent the app actually uses, which is what "everyone in X except Y" means
# in practice. Intune allows only ONE inclusion intent per group per app.
#
# Pure logic, no Graph calls - covered by CatalogLogic.Tests.ps1, and handed
# to the embedded scripts as text by Get-AssignmentScriptHelpers.

function Global:Get-AssignmentKey {
    # "required|include|SG-Sales" - the identity of one assignment
    param([string]$Intent, [string]$Mode, [string]$Group)
    return "$Intent|$Mode|$Group"
}

function Global:Get-DesiredAssignmentEntries {
    <#
      The assignments an app should have, from its catalog groups.
      A group excluded and included at the same time is only excluded -
      Intune would reject the pair, and "except" is the safer reading.
    #>
    param(
        [string[]]$RequiredGroups = @(),
        [string[]]$AvailableGroups = @(),
        [string[]]$UninstallGroups = @(),
        [string[]]$ExcludeGroups = @()
    )
    $clean = {
        param($Names)
        @(@($Names) | Where-Object { $null -ne $_ -and "$_".Trim() } | ForEach-Object { "$_".Trim() } | Select-Object -Unique)
    }
    $excluded = @(& $clean $ExcludeGroups)
    $entries = New-Object System.Collections.Generic.List[object]
    $usedIntents = New-Object System.Collections.Generic.List[string]
    foreach ($pair in @(
        @{ Intent = 'required';  Groups = (& $clean $RequiredGroups) },
        @{ Intent = 'available'; Groups = (& $clean $AvailableGroups) },
        @{ Intent = 'uninstall'; Groups = (& $clean $UninstallGroups) }
    )) {
        $included = @($pair.Groups | Where-Object { $excluded -notcontains $_ })
        if ($included.Count -eq 0) { continue }
        $usedIntents.Add($pair.Intent)
        foreach ($group in $included) {
            $entries.Add([pscustomobject]@{ Intent = $pair.Intent; Mode = 'include'; Group = $group; Key = (Get-AssignmentKey $pair.Intent 'include' $group) })
        }
    }
    # An exclusion only means something next to an inclusion of the same
    # intent, so nothing is excluded for an intent this app doesn't use.
    foreach ($intent in $usedIntents) {
        foreach ($group in $excluded) {
            $entries.Add([pscustomobject]@{ Intent = $intent; Mode = 'exclude'; Group = $group; Key = (Get-AssignmentKey $intent 'exclude' $group) })
        }
    }
    # Returned unwrapped, and an EMPTY result therefore reaches the caller
    # as $null - PowerShell unrolls a returned array into the pipeline and
    # an empty one unrolls to nothing at all. Deliberately left that way:
    # every caller already wraps this in @(), and ",$entries.ToArray()"
    # would hand those callers an array nested one level deeper. The
    # hazard it creates - "@($null)" being an array holding one $null
    # rather than an empty array - is handled where it actually bites, in
    # Get-AssignmentDiff and New-AppAssignmentBody below.
    return $entries.ToArray()
}

function Global:ConvertTo-CurrentAssignmentEntries {
    <#
      The same shape, from what Graph returned for an app's assignments.
      -GroupNameById turns the target's group id into the name the catalog
      uses; an id with no name known keeps the id, so it still shows up as
      something rather than vanishing. Non-group targets (All devices, All
      users) are reported separately by -OtherTargets, since this app's
      catalog has no way to express them and must not silently drop them.
    #>
    param($Assignments, $GroupNameById, [ref]$OtherTargets)
    $entries = New-Object System.Collections.Generic.List[object]
    $others = New-Object System.Collections.Generic.List[string]
    foreach ($assignment in @($Assignments)) {
        $intent = if ($assignment -is [System.Collections.IDictionary]) { [string]$assignment['intent'] } else { [string]$assignment.intent }
        $target = if ($assignment -is [System.Collections.IDictionary]) { $assignment['target'] } else { $assignment.target }
        if (-not $target) { continue }
        $targetType = if ($target -is [System.Collections.IDictionary]) { [string]$target['@odata.type'] } else { [string]$target.'@odata.type' }
        $groupId = if ($target -is [System.Collections.IDictionary]) { [string]$target['groupId'] } else { [string]$target.groupId }
        $mode = switch -Wildcard ($targetType) {
            '*exclusionGroupAssignmentTarget' { 'exclude'; break }
            '*groupAssignmentTarget'          { 'include'; break }
            default                           { $null }
        }
        if (-not $mode -or -not $groupId) {
            $others.Add("[$intent] $targetType")
            continue
        }
        $name = $groupId
        if ($GroupNameById -and $GroupNameById.Contains($groupId) -and $GroupNameById[$groupId]) { $name = [string]$GroupNameById[$groupId] }
        $entries.Add([pscustomobject]@{ Intent = $intent; Mode = $mode; Group = $name; GroupId = $groupId; Key = (Get-AssignmentKey $intent $mode $name) })
    }
    if ($OtherTargets) { $OtherTargets.Value = $others.ToArray() }
    # $null for an app with no assignments in Intune - see
    # Get-DesiredAssignmentEntries' own note on why that is left alone.
    return $entries.ToArray()
}

function Global:Format-AssignmentLabel {
    # "[required] SG-Sales" / "[required] EXCLUDE SG-Contractors"
    param($Entry)
    if ($Entry.Mode -eq 'exclude') { return "[$($Entry.Intent)] EXCLUDE $($Entry.Group)" }
    return "[$($Entry.Intent)] $($Entry.Group)"
}

function Global:Get-AssignmentDiff {
    <#
      What has to change to get from $Current to $Desired, as the labels
      the preview and the log show. Same intent+mode+group on both sides
      means no change.
    #>
    param($Current, $Desired)
    # Dropped before anything indexes by .Key. A $null entry's .Key is
    # itself $null, and a hashtable assignment with a null key throws
    # "Index operation failed; the array index evaluated to null" - which
    # is how one app with no assignments used to take down the whole
    # multi-app preview, since a single worker's error aborts the run.
    # Both producers above now keep empty sets empty, but this is the
    # place the failure actually surfaced, and it is handed to the
    # embedded scripts as text where a null can arrive from a config file
    # rather than from these functions. Producers above deliberately still
    # return $null for an empty set - see their own notes.
    $currentEntries = @(@($Current) | Where-Object { $_ -and $_.Key })
    $desiredEntries = @(@($Desired) | Where-Object { $_ -and $_.Key })

    $currentByKey = @{}
    foreach ($entry in $currentEntries) { $currentByKey[$entry.Key] = $entry }
    $desiredByKey = @{}
    foreach ($entry in $desiredEntries) { $desiredByKey[$entry.Key] = $entry }

    $toAdd = @($desiredEntries | Where-Object { -not $currentByKey.ContainsKey($_.Key) } | ForEach-Object { Format-AssignmentLabel $_ })
    $toRemove = @($currentEntries | Where-Object { -not $desiredByKey.ContainsKey($_.Key) } | ForEach-Object { Format-AssignmentLabel $_ })
    return [pscustomobject]@{ ToAdd = @($toAdd | Sort-Object); ToRemove = @($toRemove | Sort-Object) }
}

function Global:New-AppAssignmentBody {
    <#
      The body of an app's /assign call, from the desired entries and a
      group-name -> id lookup. A group with no id known is skipped (the
      caller creates or resolves them first). Sending this replaces the
      app's whole assignment list, which is why the entries have to be
      complete, exclusions included.
    #>
    param($Entries, $GroupIdByName)
    $assignments = @(@($Entries) | ForEach-Object {
        # Same null-entry guard as Get-AssignmentDiff, and it matters more
        # here: this is the body of the call that REPLACES an app's whole
        # assignment list, and Hashtable.Contains($null) throws outright.
        if (-not $_ -or -not $_.Group) { return }
        $groupId = $null
        if ($GroupIdByName -and $GroupIdByName.Contains($_.Group)) { $groupId = [string]$GroupIdByName[$_.Group] }
        if (-not $groupId) { return }
        $targetType = if ($_.Mode -eq 'exclude') { "#microsoft.graph.exclusionGroupAssignmentTarget" } else { "#microsoft.graph.groupAssignmentTarget" }
        @{
            "@odata.type" = "#microsoft.graph.mobileAppAssignment"
            intent        = $_.Intent
            target        = @{ "@odata.type" = $targetType; groupId = $groupId }
        }
    })
    return @{ mobileAppAssignments = @($assignments) }
}

function Global:Get-AssignmentScriptHelpers {
    # The functions above as script text, for the embedded scripts' own
    # runs - same approach as Get-GraphLogScriptHelpers.
    $names = @(
        'Get-AssignmentKey', 'Get-DesiredAssignmentEntries', 'ConvertTo-CurrentAssignmentEntries',
        'Format-AssignmentLabel', 'Get-AssignmentDiff', 'New-AppAssignmentBody'
    )
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        $parts.Add("function global:$name {`n$((Get-Command $name).ScriptBlock.ToString())`n}")
    }
    return ($parts -join "`n`n")
}
