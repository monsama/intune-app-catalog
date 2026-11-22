function Global:Get-IntuneCatalogDrift {
    # The three-way comparison of the catalog with Intune's apps that the
    # Intune link findings (Get-IntuneLinkFindings) are built from.
    param([array]$Apps, [array]$IntuneApps)

    $catalogByNormName = @{}
    $catalogByAppId = @{}
    # A managed app's pilot and superseded releases are its own apps in Intune, under other names - not drift.
    $releaseIds = @{}
    foreach ($app in $Apps) {
        $normName = ($app.appName.Trim() -replace '\s+', ' ')
        $catalogByNormName[$normName] = $true
        if ($app.appId) { $catalogByAppId[$app.appId] = $app }
        foreach ($r in @($app.releases)) {
            if ($r -and $r.appId) { $relKey = [string]$r.appId; $releaseIds[$relKey] = $true }
        }
    }

    # Every ID actually live in Intune right now, for the third comparison
    # direction below - a catalog entry can only be flagged as genuinely
    # deleted if its own stored ID isn't in this set at all, not just
    # absent from a name-based lookup.
    $intuneIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($ia in $IntuneApps) { [void]$intuneIds.Add($ia.id) }

    $missing = New-Object System.Collections.Generic.List[object]
    $renamed = New-Object System.Collections.Generic.List[object]
    $notReleases = @($IntuneApps | Where-Object { $relId = [string]$_.id; -not $releaseIds.ContainsKey($relId) })
    foreach ($ia in $notReleases) {
        $normIntuneName = ($ia.displayName.Trim() -replace '\s+', ' ')
        if ($catalogByAppId.ContainsKey($ia.id)) {
            # Known App ID - check whether the catalog's name still matches
            $catalogApp = $catalogByAppId[$ia.id]
            $normCatalogName = ($catalogApp.appName.Trim() -replace '\s+', ' ')
            if ($normCatalogName -ne $normIntuneName) {
                $renamed.Add([pscustomobject]@{ IntuneName = $ia.displayName; CatalogName = $catalogApp.appName; Id = $ia.id })
            }
        }
        elseif (-not $catalogByNormName.ContainsKey($normIntuneName)) {
            $missing.Add($ia)
        }
    }

    # The third direction, walked from the CATALOG's own side rather than
    # Intune's - the two loops above only ever iterate Intune's app list,
    # so a catalog entry whose own stored App ID has been deleted from
    # Intune entirely (not renamed - genuinely gone, e.g. removed directly
    # in the portal, bypassing this tool) would never surface in either
    # "Not in catalog" or "Renamed in Intune", since neither of those
    # checks ever looks the other way.
    $deletedFromIntune = New-Object System.Collections.Generic.List[object]
    foreach ($app in $Apps) {
        if ($app.appId -and -not $intuneIds.Contains($app.appId)) {
            $deletedFromIntune.Add($app)
        }
    }

    return [pscustomobject]@{
        Missing           = $missing
        Renamed           = $renamed
        DeletedFromIntune = $deletedFromIntune
    }
}

function Global:Get-FriendlyAge {
    param([datetime]$Timestamp)

    $span = (Get-Date) - $Timestamp
    if ($span.TotalSeconds -lt 60) { return "just now" }
    if ($span.TotalMinutes -lt 60) { return "$([int]$span.TotalMinutes)m ago" }
    if ($span.TotalHours -lt 24) { return "$([int]$span.TotalHours)h ago" }
    return "$([int]$span.TotalDays)d ago"
}

function Global:Get-LastAuditSummary {
    param([string]$AppName)

    if (-not $Global:App.LastAuditResults.ContainsKey($AppName)) { return "Never audited" }
    $entry = $Global:App.LastAuditResults[$AppName]
    $checked = @($entry.Metadata, $entry.Groups, $entry.Dependencies, $entry.Unknown) | Where-Object { $null -ne $_ }
    $age = Get-FriendlyAge -Timestamp $entry.Timestamp

    if (@($checked | Where-Object { $_ -like "Failed*" }).Count -gt 0) { return "Check failed ($age)" }
    $issueCount = @($checked | Where-Object { $_ -ne "OK" }).Count
    if ($issueCount -eq 0) { return "OK ($age)" }
    return "$issueCount issue$(if ($issueCount -ne 1) { 's' }) ($age)"
}

function Global:ConvertTo-SupersedenceEntries {
    # Intune's relationship list for one app -> the catalog's supersedes
    # entries. Only "child" relationships are this app's own (it supersedes
    # the target); "parent" ones are other apps superseding this one.
    param($Relationships)
    return @(@($Relationships) | Where-Object {
        $_ -and ([string]$_.'@odata.type') -like '*mobileAppSupersedence' -and (-not [string]$_.targetType -or [string]$_.targetType -eq 'child')
    } | ForEach-Object {
        [pscustomobject]@{
            appId = [string]$_.targetId
            name  = [string]$_.targetDisplayName
            type  = if ([string]$_.supersedenceType -eq 'replace') { 'replace' } else { 'update' }
        }
    })
}

function Global:Format-SupersedenceSummary {
    # One line for a compare row or a confirmation: "Old App (update), ...".
    # "replace" is shown as what it does - the old app is uninstalled.
    param($Entries)
    $items = @(@($Entries) | Where-Object { $_ -and $_.appId })
    if ($items.Count -eq 0) { return "(none)" }
    return (@($items | Sort-Object { [string]$_.name } | ForEach-Object {
        $label = if ([string]$_.name) { [string]$_.name } else { [string]$_.appId }
        "$label ($(if ($_.type -eq 'replace') { 'replace - uninstalls it' } else { 'update' }))"
    }) -join ", ")
}

function Global:Get-SupersedenceCompareKey {
    # By App ID and type only - a renamed app in Intune is the same app.
    param($Entries)
    return ((@(@($Entries) | Where-Object { $_ -and $_.appId } | ForEach-Object { "$([string]$_.appId):$([string]$_.type)" }) | Sort-Object) -join "|")
}

function Global:Get-CatalogMetadataSimpleFields {
    return @(
        @{ Key = "description"; Label = "Description" }
        @{ Key = "publisher"; Label = "Publisher" }
        @{ Key = "owner"; Label = "Owner" }
        @{ Key = "developer"; Label = "Developer" }
        @{ Key = "informationUrl"; Label = "Information URL" }
        @{ Key = "privacyUrl"; Label = "Privacy URL" }
        @{ Key = "notes"; Label = "Notes" }
        # Unrecorded: skipped while the catalog entry doesn't have the
        # field at all ($null - it predates it), rather than every app
        # with a version or a featured flag in Intune showing as different
        # the first time it is checked. Pull or a save fills it in.
        @{ Key = "isFeatured"; Label = "Featured app"; Unrecorded = $true }
        # Win32Only fields below only exist as concepts on a win32LobApp -
        # Graph has no installCommandLine/architecture/requirements/
        # installExperience/returnCodes (or detection rules, handled
        # separately below) for any other app type, so it always reports
        # them blank/null for e.g. a "Microsoft Store app (new)" like
        # Company Portal. Comparing those against this tool's own Win32-
        # shaped local defaults (installTimeMinutes: 60,
        # deviceRestartBehavior: "basedOnReturnCode", ...) produced a
        # permanent, unfixable "N fields differ" on every single sync for
        # every non-Win32 app in the catalog - see Get-CatalogMetadataFieldDiffs's
        # own -OdataType gating.
        # displayVersion exists on win32LobApp, not on Store apps
        @{ Key = "appVersion"; Label = "App version"; Win32Only = $true; Unrecorded = $true }
        @{ Key = "installCommand"; Label = "Install command"; Win32Only = $true }
        @{ Key = "uninstallCommand"; Label = "Uninstall command"; Win32Only = $true }
        @{ Key = "architecture"; Label = "Architecture"; Win32Only = $true }
        @{ Key = "minDiskSpaceMB"; Label = "Disk space requirement"; Win32Only = $true }
        @{ Key = "minMemoryMB"; Label = "Memory requirement"; Win32Only = $true }
        @{ Key = "minProcessors"; Label = "Min. processors requirement"; Win32Only = $true }
        @{ Key = "minCpuSpeedMHz"; Label = "Min. CPU speed requirement"; Win32Only = $true }
        @{ Key = "installTimeMinutes"; Label = "Install time required"; Win32Only = $true }
        @{ Key = "deviceRestartBehavior"; Label = "Device restart behavior"; Win32Only = $true }
        @{ Key = "allowAvailableUninstall"; Label = "Allow available uninstall"; Win32Only = $true }
    )
}

function Global:Get-WingetIdFromInstallCommand {
    <#
      The Winget ID an install command is really installing, or "" when it
      is not installing one.

      An app imported from Intune has no Winget ID, because Intune has no
      such field - but the command line usually says. This tool's own
      Winget apps call "winget install --id Some.App", and commands of
      Winget-AutoUpdate's Winget-Install.ps1 (-AppIDs "Some.App", from
      before 2.19 or other tools) say the same thing another way.
      Reading it back turns an imported app that IS a Winget app into one
      the catalog knows is a Winget app, which is the difference between
      deploying it from the shared package and treating it as uncommon.

      Deliberately conservative. A command naming SEVERAL ids returns
      nothing: the catalog has one wingetId per app, and picking the first
      of three would quietly describe the app as something it is not.
      Guessing wrong here is worse than not guessing, because a wrong
      Winget ID is what a later deploy would install.
    #>
    param([string]$InstallCommand)

    if ([string]::IsNullOrWhiteSpace($InstallCommand)) { return "" }

    # -AppIDs "X" / -AppIDs 'X' / -AppIDs X, the Winget-AutoUpdate form.
    $appIdsMatch = [regex]::Match($InstallCommand, '(?i)-AppIDs\s+("([^"]+)"|''([^'']+)''|([^\s"'']+))')
    if ($appIdsMatch.Success) {
        $captured = @($appIdsMatch.Groups[2].Value, $appIdsMatch.Groups[3].Value, $appIdsMatch.Groups[4].Value) |
            Where-Object { $_ } | Select-Object -First 1
        return (Get-FirstWingetIdToken -Captured $captured)
    }

    # winget install --id X / -e --id X, the same intent without the
    # wrapper. "winget install X" with a bare package name is NOT matched:
    # that argument is a search term, which Winget resolves to whatever it
    # happens to find, and a search term is not an id.
    $wingetMatch = [regex]::Match($InstallCommand, '(?i)\bwinget\b[^\r\n]*?\s--id\s+("([^"]+)"|''([^'']+)''|([^\s"'']+))')
    if ($wingetMatch.Success) {
        $captured = @($wingetMatch.Groups[2].Value, $wingetMatch.Groups[3].Value, $wingetMatch.Groups[4].Value) |
            Where-Object { $_ } | Select-Object -First 1
        return (Get-FirstWingetIdToken -Captured $captured)
    }
    return ""
}

function Global:Get-FirstWingetIdToken {
    <#
      The Winget ID out of whatever was found after -AppIDs or --id.

      Quoting does not mean "this is all the ID". A real, live command
      reads -AppIDs "Adobe.Acrobat.Reader.64-bit --scope machine
      --override " - the extra arguments ride along inside the same quoted
      string, and taking the quoted string whole gave a "Winget ID" with
      spaces and switches in it. A Winget package identifier never
      contains a space, so the ID is the first token and the rest is
      arguments.

      Still nothing when the first token names several packages, and
      nothing when it is itself a switch - "-AppIDs --scope" is a command
      this function has no business having an opinion about.
    #>
    param([string]$Captured)

    if ([string]::IsNullOrWhiteSpace($Captured)) { return "" }
    $first = @($Captured.Trim() -split '\s+') | Where-Object { $_ } | Select-Object -First 1
    if (-not $first) { return "" }
    if ($first -match '[,;]') { return "" }
    if ($first.StartsWith('-')) { return "" }
    return $first
}

function Global:ConvertTo-CatalogMetadataFromFetch {
    <#
      A catalog "metadata" object from what Start-AppMetadataFetch returns.

      That fetch already reads the WHOLE app - commands, detection rule,
      requirements, install experience, dependencies - and the two places
      that add an app from Intune both threw all of it away and stored
      $null, leaving entries that had to be filled in by hand afterwards
      for information the tool had already been handed. Same Graph round
      trip either way; only the keeping was missing.

      The shape produced here is the one SyncMetadata.ps1 writes, field for
      field, because the catalog has one metadata shape and a second
      almost-identical one is how they drift. The fetch hands its fields
      back flat and PascalCase; the catalog stores them nested and camel.

      Architecture and minimum-OS follow the precedence Show-
      CreateInIntuneDialog's own auto-fetch already uses - allowed before
      applicable, the current Windows-release property before the legacy
      one - rather than a second opinion about the same two fields.
    #>
    param($Fetched)

    if (-not $Fetched) { return $null }

    $architecture = ""
    if ($Fetched.AllowedArchitectures -and $Fetched.AllowedArchitectures -ne "none") {
        $architecture = [string]$Fetched.AllowedArchitectures
    }
    elseif ($Fetched.ApplicableArchitectures -and $Fetched.ApplicableArchitectures -ne "none") {
        $architecture = [string]$Fetched.ApplicableArchitectures
    }

    # The live property wins; the legacy one is only a fallback for an app
    # never touched since Microsoft's switch. Stored raw - Get-Parsed
    # MinOsRelease is what turns either spelling into something comparable,
    # and it is the editor's job to match it to a dropdown entry.
    $minOsKey = if ($Fetched.MinimumSupportedWindowsRelease) { [string]$Fetched.MinimumSupportedWindowsRelease }
                elseif ($Fetched.MinOSPropertyName) { [string]$Fetched.MinOSPropertyName }
                else { "" }

    $returnCodes = @()
    if (@($Fetched.ReturnCodes).Count -gt 0) {
        $returnCodes = @(@($Fetched.ReturnCodes) | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{ returnCode = $_.returnCode; type = $_.type }
        })
    }

    return [pscustomobject]@{
        description      = [string]$Fetched.Description
        publisher        = [string]$Fetched.Publisher
        owner            = [string]$Fetched.Owner
        developer        = [string]$Fetched.Developer
        informationUrl   = [string]$Fetched.InformationUrl
        privacyUrl       = [string]$Fetched.PrivacyInformationUrl
        notes            = [string]$Fetched.Notes
        appVersion       = [string]$Fetched.DisplayVersion
        isFeatured       = [bool]$Fetched.IsFeatured
        installCommand   = [string]$Fetched.InstallCommandLine
        uninstallCommand = [string]$Fetched.UninstallCommandLine
        architecture     = $architecture
        installContext   = [string]$Fetched.RunAsAccount
        minOSKey         = $minOsKey
        detectionRule    = $Fetched.DetectionRule
        dependencies     = @($Fetched.Dependencies)
        # $null when the relationships couldn't be read - not "none"
        supersedes       = $Fetched.Supersedence
        minDiskSpaceMB          = $Fetched.MinDiskSpaceMB
        minMemoryMB             = $Fetched.MinMemoryMB
        minProcessors           = $Fetched.MinProcessors
        minCpuSpeedMHz          = $Fetched.MinCpuSpeedMHz
        installTimeMinutes      = $Fetched.InstallTimeMinutes
        deviceRestartBehavior   = [string]$Fetched.DeviceRestartBehavior
        allowAvailableUninstall = $Fetched.AllowAvailableUninstall
        returnCodes             = $returnCodes
    }
}

function Global:Get-ComparableDetectionRule {
    <#
      A detection rule with the fields its own detection type does not use
      blanked out, for comparing local against live.

      The catalog stores every field the editor has a box for, whichever
      type is selected - switch a File rule from "version" to "exists" and
      the operator and value boxes keep what was in them. CreateApp.ps1
      does NOT send those two for "exists", because Intune has no such
      concept there, so the live app comes back without them. Comparing
      the two raw then reports a rule that differs on fields neither side
      can act on, over and over, with nothing the user can do about it:
      "Intune has no File_DetectionValue 1" for an app that was deployed
      from this very catalog seconds earlier.

      The conditions below mirror CreateApp.ps1's own send conditions
      exactly. If those ever change, these have to change with them - they
      are two halves of one rule about which fields a detection type uses.

      Comparison only. What is PERSISTED keeps every field, so switching
      the type back and forth in the editor doesn't silently discard what
      was typed.
    #>
    param($DetectionRule)

    if (-not $DetectionRule) { return $null }
    $comparable = $DetectionRule.PSObject.Copy()
    switch ([string]$DetectionRule.Type) {
        "Msi" {
            # CreateApp.ps1: productVersion is sent only alongside a real
            # operator.
            if (-not $DetectionRule.Msi_VersionOperator -or [string]$DetectionRule.Msi_VersionOperator -eq "notConfigured") {
                $comparable | Add-Member -NotePropertyName Msi_Version -NotePropertyValue "" -Force
            }
        }
        "File" {
            if (@("modifiedDate", "createdDate", "version", "sizeInMB") -notcontains [string]$DetectionRule.File_DetectionType) {
                $comparable | Add-Member -NotePropertyName File_Operator -NotePropertyValue "" -Force
                $comparable | Add-Member -NotePropertyName File_DetectionValue -NotePropertyValue "" -Force
            }
        }
        "Registry" {
            if (@("string", "integer", "version") -notcontains [string]$DetectionRule.Reg_DetectionType) {
                $comparable | Add-Member -NotePropertyName Reg_Operator -NotePropertyValue "" -Force
                $comparable | Add-Member -NotePropertyName Reg_DetectionValue -NotePropertyValue "" -Force
            }
        }
    }
    return $comparable
}

function Global:Get-CatalogMetadataFieldDiffs {
    # -OdataType is the live app's raw @odata.type (with or without the
    # "#microsoft.graph." prefix) - pass it whenever it's known (the bulk
    # "Pull metadata and groups from Intune..." flow always has it) so Win32Only fields are
    # skipped for a non-Win32 app instead of producing a permanent false
    # "N fields differ". Left blank/omitted, this assumes Win32 - the
    # right default for every OTHER caller (Test-AppHasCustomConfig, the
    # single-app auto-fetch), which only ever deal with apps this tool
    # itself deploys as win32LobApp.
    param($Local, $Remote, [string]$OdataType = "")

    $diffs = New-Object System.Collections.Generic.List[object]
    if (-not $Local) { return $diffs.ToArray() }

    # The set of app types that decides whether this tool's Win32-shaped deploy flow applies to a given live
    # Intune app - types that behave like a Win32 app for the Win32Only
    # fields below.
    $win32LikeOdataTypes = @("win32LobApp", "win32CatalogApp", "windowsMobileMSI")
    $rawOdataType = $OdataType -replace '^#?microsoft\.graph\.', ''
    $isWin32 = (-not $rawOdataType) -or ($win32LikeOdataTypes -contains $rawOdataType)

    # These four fields use the same "0 = not required" convention the
    # editor's own "Requirements (0 = not required)" label documents -
    # Intune reports an unset requirement as blank/null, not 0, so a
    # local "0" and a live blank are the SAME thing (no requirement),
    # not a real difference worth flagging. Confirmed as a real false
    # positive live: memory/processors/CPU speed all showing local "0"
    # vs Intune "(blank)" as a 3-field diff for an app where nothing had
    # actually changed.
    $zeroEqualsBlankFields = @("minDiskSpaceMB", "minMemoryMB", "minProcessors", "minCpuSpeedMHz")

    foreach ($f in (Get-CatalogMetadataSimpleFields)) {
        if ($f.Win32Only -and -not $isWin32) { continue }
        if ($f.Unrecorded -and $null -eq $Local.($f.Key)) { continue }
        $localVal = [string]$Local.($f.Key)
        $remoteVal = [string]$Remote.($f.Key)
        # Same "a line-ending/trailing-whitespace-only difference is not a
        # real change" normalization ConvertTo-DetectionRuleJson applies for
        # the detection script (confirmed live, WinMerge: Intune's own copy
        # of a script came back with a trailing `r`n where the local
        # catalog had a trailing `n). Notes/Install command/Uninstall
        # command are all Multiline textboxes just as capable of the same
        # CRLF-vs-LF round trip against Intune's own copy - applied to
        # every simple field here, not just those three, since it's a
        # no-op for a genuinely single-line value (no `r`n or trailing
        # whitespace to strip) and cheaper than maintaining a field-by-field
        # allowlist that's one rediscovery of this same bug away from
        # needing a third entry.
        $compareLocal = (ConvertTo-CanonicalLineEndings $localVal).TrimEnd()
        $compareRemote = (ConvertTo-CanonicalLineEndings $remoteVal).TrimEnd()
        if ($zeroEqualsBlankFields -contains $f.Key) {
            if ($compareLocal -eq "0") { $compareLocal = "" }
            if ($compareRemote -eq "0") { $compareRemote = "" }
        }
        if ($compareLocal -ne $compareRemote) {
            $diffs.Add([pscustomobject]@{ Field = $f.Label; Local = $localVal; Remote = $remoteVal })
        }
    }

    # Detection rule and return codes are Win32Only concepts too, same
    # reasoning as above - skipped entirely for a non-Win32 app rather
    # than comparing against Intune's inherent blank/null for both.
    if ($isWin32) {
        # ConvertTo-Json is not used here - it's confirmed (see ConvertTo-DetectionRuleJson's
        # own comment) to sometimes silently return an empty result for certain inputs,
        # which made multi-line Script detection rules (e.g. winget apps) show up as a
        # spurious "Detection rule" diff on every sync even when nothing had changed.
        # Through Get-ComparableDetectionRule first - see its own note for
        # why a raw comparison reports a permanent difference on fields the
        # selected detection type does not use.
        $localDetSummary = if ($Local.detectionRule) { ConvertTo-DetectionRuleJson -DetectionRule (Get-ComparableDetectionRule -DetectionRule $Local.detectionRule) -IndentLevel 0 } else { "" }
        $remoteDetSummary = if ($Remote.detectionRule) { ConvertTo-DetectionRuleJson -DetectionRule (Get-ComparableDetectionRule -DetectionRule $Remote.detectionRule) -IndentLevel 0 } else { "" }
        if ($localDetSummary -ne $remoteDetSummary) {
            $diffs.Add([pscustomobject]@{ Field = "Detection rule"; Local = $localDetSummary; Remote = $remoteDetSummary })
        }

        $localRcSummary = if (@($Local.returnCodes).Count -gt 0) { (@($Local.returnCodes) | ConvertTo-Json -Compress -Depth 5) } else { "" }
        $remoteRcSummary = if (@($Remote.returnCodes).Count -gt 0) { (@($Remote.returnCodes) | ConvertTo-Json -Compress -Depth 5) } else { "" }
        if ($localRcSummary -ne $remoteRcSummary) {
            $diffs.Add([pscustomobject]@{ Field = "Return codes"; Local = $localRcSummary; Remote = $remoteRcSummary })
        }
    }

    # Supersedence (Win32 apps only). Skipped while the catalog never
    # recorded any ($null), and when the other side couldn't be read
    # ($null) - neither is a difference anyone can act on.
    if ($isWin32 -and $null -ne $Local.supersedes -and $null -ne $Remote.supersedes) {
        if ((Get-SupersedenceCompareKey $Local.supersedes) -ne (Get-SupersedenceCompareKey $Remote.supersedes)) {
            $diffs.Add([pscustomobject]@{ Field = "Supersedence"; Local = (Format-SupersedenceSummary $Local.supersedes); Remote = (Format-SupersedenceSummary $Remote.supersedes) })
        }
    }

    return $diffs.ToArray()
}

function Global:Merge-CatalogMetadata {
    param($Remote, $Local, [string[]]$KeepLocalFields)

    $merged = $Remote.PSObject.Copy()
    if (-not $Local -or @($KeepLocalFields).Count -eq 0) { return $merged }

    foreach ($f in (Get-CatalogMetadataSimpleFields)) {
        if ($KeepLocalFields -contains $f.Label) {
            $merged | Add-Member -NotePropertyName $f.Key -NotePropertyValue $Local.($f.Key) -Force
        }
    }
    if ($KeepLocalFields -contains "Detection rule") {
        $merged | Add-Member -NotePropertyName "detectionRule" -NotePropertyValue $Local.detectionRule -Force
    }
    if ($KeepLocalFields -contains "Return codes") {
        $merged | Add-Member -NotePropertyName "returnCodes" -NotePropertyValue $Local.returnCodes -Force
    }
    if ($KeepLocalFields -contains "Supersedence") {
        $merged | Add-Member -NotePropertyName "supersedes" -NotePropertyValue $Local.supersedes -Force
    }
    return $merged
}

function Global:Get-GroupFieldDiffs {
    param($LocalApp, $RemoteResult)

    $diffs = New-Object System.Collections.Generic.List[object]
    if (-not $LocalApp -or -not $RemoteResult) { return $diffs.ToArray() }

    $fields = @(
        @{ Key = "requiredFor"; RemoteKey = "RequiredGroupNames"; Label = "Required for" }
        @{ Key = "availableFor"; RemoteKey = "AvailableGroupNames"; Label = "Available for" }
        @{ Key = "uninstallFor"; RemoteKey = "UninstallGroupNames"; Label = "Uninstall for" }
    )
    foreach ($f in $fields) {
        $localStr = (@($LocalApp.($f.Key)) | Sort-Object) -join ", "
        $remoteStr = (@($RemoteResult.($f.RemoteKey)) | Sort-Object) -join ", "
        if ($localStr -ne $remoteStr) {
            $diffs.Add([pscustomobject]@{ Field = $f.Label; Local = $localStr; Remote = $remoteStr })
        }
    }
    return $diffs.ToArray()
}

function Global:Format-GroupFieldDiffs {
    # What a group difference says wherever it is shown - the audit's
    # Groups cell, Last Audit, the app editor. "1 differ: Available for"
    # was all any of them said, with both sides already in hand: you could
    # not tell whether the catalog or Intune was the one with groups in it,
    # which is the whole question when deciding between Pull and Push.
    # "OK" for no differences, so callers can store it as they did before.
    param($Diffs)
    $list = @($Diffs | Where-Object { $_ })
    if ($list.Count -eq 0) { return "OK" }
    $parts = foreach ($d in $list) {
        $localText = if ([string]$d.Local) { [string]$d.Local } else { "(none)" }
        $remoteText = if ([string]$d.Remote) { [string]$d.Remote } else { "(none)" }
        "$($d.Field) - catalog: $localText | Intune: $remoteText"
    }
    return "$($list.Count) differ: $($parts -join '; ')"
}

function Global:Test-AppIsUncommon {
    param($App)
    return [string]::IsNullOrWhiteSpace($App.wingetId)
}

function Global:Test-PackageRelativePath {
    <#
      Pure: whether a path is a safe file path inside an app's packages folder - relative, no '..' or '.' parts,
      no drive or UNC root, no characters Windows refuses, at most 20 levels and 400 characters. For uploaded
      folders and .zip entries (nothing may land outside the folder) and the chosen setup file.
    #>
    param([string]$Path)
    if (-not $Path -or $Path.Length -gt 400) { return $false }
    if ($Path -match '^[\\/]|^[A-Za-z]:|[\x00-\x1F<>:"|?*]') { return $false }
    $parts = @($Path -split '[\\/]')
    if ($parts.Count -gt 20) { return $false }
    foreach ($p in $parts) {
        if (-not $p -or $p -eq '.' -or $p -eq '..' -or $p.Trim() -ne $p -or $p.EndsWith('.')) { return $false }
        if ($p -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { return $false }
    }
    return $true
}

function Global:Test-IntuneLobMsiType {
    # Pure: whether an Intune app type (an @odata.type, with or without its prefix, or its friendly label) is the MSI line-of-business type.
    param([string]$Type)
    $t = ($Type -replace '^#?microsoft\.graph\.', '').Trim()
    return ($t -eq 'windowsMobileMSI' -or $t -eq 'Windows MSI line-of-business app')
}

function Global:Test-PackagedIntuneAppType {
    # Pure: an Intune app type this tool builds a package for - Win32, or an MSI line-of-business app (moved to Win32
    # when it's sent; Test-IntuneLobMsiType). Blank (not synced, not deployed) counts too.
    param([string]$Label)
    return (-not $Label -or $Label -eq 'Windows app (Win32)' -or (Test-IntuneLobMsiType $Label))
}

function Global:Get-FriendlyIntuneAppType {
    param([string]$ODataType)

    if (-not $ODataType) { return "" }
    $typeName = $ODataType -replace '^#?microsoft\.graph\.', ''

    $knownTypes = @{
        "win32LobApp"             = "Windows app (Win32)"
        "win32CatalogApp"         = "Windows app (Win32)"
        "officeSuiteApp"          = "Microsoft 365 Apps (Windows 10 and later)"
        "windowsMicrosoftEdgeApp" = "Microsoft Edge, version 77 and later"
        "windowsStoreApp"         = "Microsoft Store app (legacy)"
        "winGetApp"               = "Microsoft Store app (new)"
        "windowsUniversalAppX"    = "Microsoft Store app (legacy)"
        "windowsAppX"             = "Windows app package (.appx)"
        "windowsPhone81AppX"      = "Windows Phone app package (.appx)"
        "windowsWebApp"           = "Web link"
        "webApp"                  = "Web link"
        # Intune's own MSI type (an .msi uploaded as a line-of-business app) - not Win32: it can't be updated as one,
        # and Intune never gives the .msi back. Said so, so it isn't mistaken for a Win32 app (2.33.0).
        "windowsMobileMSI"        = "Windows MSI line-of-business app"
    }
    if ($knownTypes.ContainsKey($typeName)) { return $knownTypes[$typeName] }

    $spaced = $typeName -creplace '([a-z0-9])([A-Z])', '$1 $2'
    if ($spaced.Length -gt 0) { return $spaced.Substring(0,1).ToUpper() + $spaced.Substring(1) }
    return $spaced
}

function Global:Get-ParsedMinOsRelease {
    param([string]$RawValue)

    if (-not $RawValue) { return $null }
    if ($RawValue -match '^(?i)(?:W|Windows)(10|11)[_\s]?(.+)$') {
        return @{ Major = $Matches[1]; Release = $Matches[2].ToUpperInvariant() }
    }
    if ($RawValue -match '^(?i)v10_(.+)$') {
        # Same digit-swapped "20H2" quirk as the legacy property's own
        # v10_2H20.
        $release = $Matches[1].ToUpperInvariant()
        if ($release -eq "2H20") { $release = "20H2" }
        return @{ Major = "10"; Release = $release }
    }
    # No recognizable major-version marker at all (e.g. a bare "21H1",
    # observed live) - every release token seen without one so far
    # predates Windows 11 (which only exists from 21H2 onward), so
    # Windows 10 is a safe default rather than leaving it unlabeled.
    return @{ Major = "10"; Release = $RawValue.ToUpperInvariant() }
}

function Global:Get-FriendlyMinOsRelease {
    param([string]$RawValue)
    $parsed = Get-ParsedMinOsRelease -RawValue $RawValue
    if (-not $parsed) { return "" }
    return "Windows $($parsed.Major) $($parsed.Release)"
}

function Global:Get-SafeFileNameForApp {
    param([string]$Name)
    $safeName = $Name -replace '[<>:"/\\|?*\x00-\x1f]', ''
    $safeName = $safeName -replace '\s+', ' '
    $safeName = $safeName -replace '\s', '-'
    $safeName = $safeName -replace '[.-]+', '-'
    $safeName = $safeName.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = "App" }
    # Windows' reserved device names can't be folder names (a folder "CON"
    # can't be created or deleted normally).
    if ($safeName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $safeName += "_" }
    return $safeName
}

function Global:Get-PackageFolderIndex {
    <#
      Every .intunewin under the packages folder, listed once, as
      @{ Root; ByName; ByFolder } - file name to full path, and folder to
      the files in it. Both are what Resolve-AppPackagePath asks about.

      It exists because that resolver used to walk the whole packages tree
      per app, and Update-Grid calls it per uncommon app on every rebuild -
      which includes every keystroke in the search box. Twenty uncommon
      apps meant twenty full recursive walks per keystroke.

      Keys are lower-cased because the Get-ChildItem -Filter this replaces
      matched case-insensitively, and a catalog app called "7-zip" must
      still find "7-Zip.intunewin".
    #>
    param([string]$Root)
    $index = @{ Root = $Root; ByName = @{}; ByFolder = @{} }
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return $index }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.intunewin' -File -ErrorAction SilentlyContinue)) {
        $nameKey = $file.Name.ToLowerInvariant()
        if (-not $index.ByName.ContainsKey($nameKey)) { $index.ByName[$nameKey] = $file.FullName }
        $folderKey = ([string]$file.DirectoryName).ToLowerInvariant()
        if (-not $index.ByFolder.ContainsKey($folderKey)) {
            $index.ByFolder[$folderKey] = New-Object System.Collections.Generic.List[string]
        }
        $index.ByFolder[$folderKey].Add($file.FullName)
    }
    return $index
}

function Global:Resolve-AppPackagePath {
    # -Index: a Get-PackageFolderIndex built once by a caller resolving
    # many apps at a time. Without it this builds its own, so a single
    # call still behaves exactly as it always did.
    #
    # -PackagePath: this app's stored override, when it has one. It wins
    # over everything below, because somebody pointed at it deliberately
    # and a prediction should not argue with that. A path that no longer
    # exists is reported as not found rather than silently falling back -
    # quietly deploying a different package than the one named would be
    # the worst outcome available.
    param([string]$AppName, [bool]$Uncommon, $Index, [string]$PackagePath)

    if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
        $chosen = $PackagePath.Trim()
        if (Test-Path -LiteralPath $chosen -PathType Leaf) { return @{ Path = $chosen; Found = $true } }
        if (Test-Path -LiteralPath $chosen -PathType Container) {
            # A folder is allowed because that is how people think about
            # it - "the package is in here" - and how the build output is
            # shaped. One file in it is unambiguous; more than one is the
            # same refusal to guess as below.
            $inFolder = @(Get-ChildItem -LiteralPath $chosen -Filter '*.intunewin' -File -ErrorAction SilentlyContinue)
            if ($inFolder.Count -eq 1) { return @{ Path = $inFolder[0].FullName; Found = $true } }
            return @{ Path = $chosen; Found = $false }
        }
        return @{ Path = $chosen; Found = $false }
    }

    if (-not $Uncommon) {
        # The expected location, or wherever an older install left one -
        # Get-SharedPackagePath does both, and remembers the expensive
        # half. This used to repeat that search itself, so a catalog with
        # no init.intunewin walked the whole app folder twice per app.
        $initPath = Get-SharedPackagePath
        return @{ Path = $initPath; Found = (Test-Path -LiteralPath $initPath) }
    }

    $safeName = Get-SafeFileNameForApp -Name $AppName
    $uncommonRoot = Get-AppFolder -Kind Packages
    $packageIndex = if ($Index -and $Index.Root -eq $uncommonRoot) { $Index } else { Get-PackageFolderIndex -Root $uncommonRoot }
    if (Test-Path -LiteralPath $uncommonRoot) {
        $wantedName = "$safeName.intunewin".ToLowerInvariant()
        if ($packageIndex.ByName.ContainsKey($wantedName)) {
            return @{ Path = $packageIndex.ByName[$wantedName]; Found = $true }
        }

        # The .intunewin file itself doesn't always end up named after the
        # app the way this tool's own packaging step names it - a file
        # someone packaged with a different tool (or a raw win32 content
        # prep utility) commonly keeps the SOURCE installer's own name
        # instead (e.g. "OpenXMLSDKV25.intunewin" for "Open XML SDK 2.5
        # for Microsoft Office"). The FOLDER, though, is still reliably
        # this app's own - it's this same $safeName, created by whatever
        # put the package there. So: if that expected folder exists and
        # holds exactly one .intunewin file, that's this app's package,
        # regardless of what it's actually called. More than one is
        # ambiguous (which one's real?) - falls through to "not found"
        # rather than guessing wrong.
        $expectedFolder = (Join-Path $uncommonRoot $safeName).ToLowerInvariant()
        if ($packageIndex.ByFolder.ContainsKey($expectedFolder)) {
            $filesInFolder = @($packageIndex.ByFolder[$expectedFolder])
            if ($filesInFolder.Count -eq 1) { return @{ Path = $filesInFolder[0]; Found = $true } }
        }
    }
    # Not found under the predicted name - still return the guess so the
    # dialog can show it (crossed out / flagged) alongside a Browse button.
    return @{ Path = (Join-Path $uncommonRoot "$safeName\$safeName.intunewin"); Found = $false }
}

function Global:Get-DependencyOrderedApps {
    param($Apps)

    $byName = @{}
    foreach ($a in $Apps) { $byName[$a.appName] = $a }
    $namesInBatch = $byName.Keys

    # Only dependencies that are THEMSELVES part of this batch are tracked -
    # a dependency that's already deployed (has its own App ID) or simply
    # wasn't selected for this run doesn't need to be waited on here; its
    # App ID gets resolved separately at actual create time regardless.
    $remainingDeps = @{}
    foreach ($a in $Apps) {
        $depsInBatch = New-Object System.Collections.Generic.List[string]
        foreach ($depName in @($a.metadata.dependencies)) {
            if ($namesInBatch -contains $depName) { $depsInBatch.Add($depName) }
        }
        $remainingDeps[$a.appName] = $depsInBatch
    }

    $ordered = New-Object System.Collections.Generic.List[object]
    $remainingNames = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Apps) { $remainingNames.Add($a.appName) }

    while ($remainingNames.Count -gt 0) {
        $readyName = $null
        foreach ($name in $remainingNames) {
            if ($remainingDeps[$name].Count -eq 0) { $readyName = $name; break }
        }
        if (-not $readyName) {
            # Nothing left is ready - a circular dependency among whatever
            # remains. Added in their original order rather than failing
            # outright, so the caller can still show and warn about exactly
            # which apps are involved instead of aborting with nothing.
            foreach ($name in $remainingNames) { $ordered.Add($byName[$name]) }
            return [pscustomobject]@{ Ordered = $ordered.ToArray(); CircularNames = @($remainingNames) }
        }

        $ordered.Add($byName[$readyName])
        [void]$remainingNames.Remove($readyName)
        foreach ($name in $remainingNames) {
            [void]$remainingDeps[$name].Remove($readyName)
        }
    }

    return [pscustomobject]@{ Ordered = $ordered.ToArray(); CircularNames = @() }
}

function Global:Get-NormalizedInstallTimeMinutes {
    <#
      "Install time required" as Intune will actually store it.

      Confirmed against a live tenant: Intune keeps this value in steps of
      5 minutes - send 61 and reading the app back gives 60. Sending the
      raw number therefore left the catalog saying 61 while Intune said
      60, which the audit and the Deploy dialog's drift check then reported
      as a difference on every single run. Snapping here, before anything
      is sent, keeps both sides equal.

      Also clamps to 5..1440 minutes: Microsoft documents 1440 (a day) as
      the maximum, and 0 would mean "give up immediately".
    #>
    param($Minutes)
    $value = 0
    if (-not [int]::TryParse("$Minutes".Trim(), [ref]$value)) { return $null }
    if ($value -le 0) { return 5 }
    if ($value -gt 1440) { return 1440 }
    $rounded = [int]([Math]::Round($value / 5.0, [System.MidpointRounding]::AwayFromZero) * 5)
    if ($rounded -lt 5) { $rounded = 5 }
    if ($rounded -gt 1440) { $rounded = 1440 }
    return $rounded
}

function Global:ConvertTo-TemplateAppRecord {
    <#
      The same app with everything that ties it to ONE tenant removed:
      the App ID, and the type/version Intune itself reported. Everything
      that was actual work - the name, Winget ID, groups, metadata - stays.

      That's what makes a catalog reusable as a starting point: in another
      tenant (or after the Intune apps are gone) these entries deploy as
      new apps instead of pointing at IDs that don't exist there.
    #>
    param($App)
    return [pscustomobject]@{
        appId            = ""
        appName          = [string]$App.appName
        wingetId         = [string]$App.wingetId
        intuneAppType    = ""
        intuneAppVersion = ""
        # Where the package is on disk isn't tied to a tenant - it stays.
        packagePath      = [string]$App.packagePath
        requiredFor      = @($App.requiredFor)
        availableFor     = @($App.availableFor)
        uninstallFor     = @($App.uninstallFor)
        excludeFor       = @($App.excludeFor)
        assignmentFilter     = [string]$App.assignmentFilter
        assignmentFilterMode = [string]$App.assignmentFilterMode
        icon             = $App.icon
        # Managed stays; its releases are this tenant's apps - dropped.
        managedUpdates   = [bool]$App.managedUpdates
        releaseRule      = $App.releaseRule
        detectedName     = [string]$App.detectedName
        autoRelease      = [bool]$App.autoRelease
        downloadUrl      = [string]$App.downloadUrl
        watchWinget      = [string]$App.watchWinget
        releases         = @()
        metadata         = $App.metadata
    }
}

function Global:Get-FactoryAppSettings {
    <#
      The defaults this app ships with, as an object shaped exactly like
      $Global:App.DefaultAppSettings.

      One definition: app start and resetting to the built-in defaults
      both use it, so the two can't drift apart.

      A fresh object every call - the caller edits what it gets back, and
      a shared one would mean editing the factory settings themselves.
    #>
    return [pscustomobject]@{
        Architecture             = "x64"
        InstallContext           = "System"
        # Newest Windows 10 release, not Windows 11 - a sensible default
        # shouldn't silently require Windows 11 for every new app.
        MinOSKey                 = "W10_22H2"
        MinDiskSpaceMB           = 0
        MinMemoryMB              = 0
        MinProcessors            = 0
        MinCpuSpeedMHz           = 0
        InstallTimeMinutes       = 60
        DeviceRestartBehavior    = "basedOnReturnCode"
        AllowAvailableUninstall  = $false
        ReturnCodes              = @(
            [pscustomobject]@{ returnCode = 0; type = "success" }
            [pscustomobject]@{ returnCode = 1707; type = "success" }
            [pscustomobject]@{ returnCode = 3010; type = "softReboot" }
            [pscustomobject]@{ returnCode = 1641; type = "hardReboot" }
            [pscustomobject]@{ returnCode = 1618; type = "retry" }
        )
        # The app(s) every OTHER app defaults to depending on, when an app
        # by that name exists in the catalog - an empty array means "no
        # default dependencies".
        DefaultDependencyAppNames = @()
        # How a Winget app's generated install and uninstall commands run
        # winget: "Managed" pinned to the App version, "Winget" the newest.
        # New Winget apps: a pinned version, new ones released through the pilot groups (managed updates).
        WingetInstallMethod      = "Managed"
        # Who owns apps in Intune (Owner field) - filled into new apps and Fill in details; empty: none.
        DefaultOwner             = ""
    }
}

function Global:ConvertTo-PsLiteral {
    <#
      Pure: -Text as a whole single-quoted PowerShell string, for scripts this
      app writes (detection, uninstall, templates, test scripts): every kind
      of single quote doubled - PowerShell also ends a string on U+2018 to
      U+201B - and line breaks and other control characters removed, so a
      name from an installer can't end the string or a comment line. Double
      quotes stay (a command line needs them).
    #>
    param([string]$Text)
    return "'" + ((([string]$Text) -replace '[\x00-\x1f\x7f]', '') -replace "['\u2018\u2019\u201A\u201B]", '$0$0') + "'"
}

function Global:Get-InstalledNamePattern {
    # Pure: a regex for a product's name as Windows lists it - the name itself, or followed by a version or "(x64)" - not "<name> Meeting Add-in", another product.
    param([string]$Name)
    return '^' + [regex]::Escape(([string]$Name).Trim()) + '(\s+(v?\d[\w.\-]*|\([^)]*\)))*\s*$'
}

function Global:ConvertTo-PsSingleQuotedContent {
    <#
      Pure: text made safe to put between single quotes in PowerShell code
      that runs somewhere else - every kind of single quote doubled, which
      includes the typographic ones (U+2018 to U+201B) PowerShell also ends a
      string on, and the characters that would break the command line it
      sits in (double quote, line breaks) removed. Used for the Winget ID in
      the generated install, uninstall and detection scripts, which run as
      SYSTEM on every targeted device.
    #>
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $clean = $Text -replace '["\r\n\x00-\x1f]', ''
    return ($clean -replace "['\u2018\u2019\u201A\u201B]", '$0$0')
}

function Global:Get-CreateAppTemplates {
    param([string]$WingetId, [bool]$Uncommon, [string]$Method)

    if (-not $Uncommon -and $WingetId) {
        if (-not $Method) { $Method = [string]$Global:App.DefaultAppSettings.WingetInstallMethod }
        # Winget-AutoUpdate is no longer generated (2.19).
        if ($Method -eq 'WAU') { $Method = 'Winget' }
        $commands = Get-WingetCommandLines -WingetId $WingetId -Method $Method -InstallContext ([string]$Global:App.DefaultAppSettings.InstallContext)
        $install = $commands.Install
        $uninstall = $commands.Uninstall
        $detection = @"
`$AppToDetect = '$(ConvertTo-PsSingleQuotedContent $WingetId)'

Function Get-WingetCmd {
    `$WingetCmd = `$null
    try {
        `$WingetInfo = (Get-Item "`$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe").VersionInfo | Sort-Object -Property FileVersionRaw
        `$WingetCmd = `$WingetInfo[-1].FileName
    }
    catch {
        if (Test-Path "`$env:LocalAppData\Microsoft\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe") {
            `$WingetCmd = "`$env:LocalAppData\Microsoft\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"
        }
    }
    return `$WingetCmd
}

`$winget   = Get-WingetCmd
`$JsonFile = "`$env:TEMP\InstalledApps-`$([guid]::NewGuid().ToString('N')).json"
& `$Winget export -o `$JsonFile --accept-source-agreements | Out-Null
`$Json     = Get-Content `$JsonFile -Raw | ConvertFrom-Json
`$Packages = `$Json.Sources.Packages
Remove-Item `$JsonFile -Force
`$Apps = `$Packages | Where-Object { `$_.PackageIdentifier -eq `$AppToDetect }
if (`$Apps) { return "Installed!" }
"@
        return @{ Install = $install; Uninstall = $uninstall; Detection = $detection }
    }
    else {
        $install = "%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File install.ps1"
        $uninstall = "%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File uninstall.ps1"
        return @{ Install = $install; Uninstall = $uninstall; Detection = "" }
    }
}

function Global:ConvertTo-WingetOptionText {
    <#
      Pure: an app's extra winget install options, checked and written the
      one way the generated install command carries them -
      @{ Ok; Options; Error }. Options is '' for none, else e.g.
      "--override '/S' --architecture 'x64'".

      They end up in the install command that runs as SYSTEM on every
      targeted device, so only these winget install options are taken, each
      once: --override and --custom (the installer's own switches),
      --architecture, --locale and --installer-type. Values are plain ASCII
      without the characters that could leave the quoting or the command
      line (double quotes, backtick, $, %, ;, &, |, <, >, ^, line breaks);
      a single quote is doubled. Anything else is refused, never cleaned up.
      Input values can be in double or single quotes, or one bare word.
    #>
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if (-not $t) { return @{ Ok = $true; Options = ''; Error = '' } }
    # Intune takes install commands up to 1024 characters; the generated one leaves room for about 200 more.
    if ($t.Length -gt 200) { return @{ Ok = $false; Options = ''; Error = 'The extra winget options are too long (200 characters at most - Intune takes install commands up to 1024).' } }
    $allowed = [ordered]@{
        '--override' = '^[A-Za-z0-9 _\-./\\:=+,@()\[\]{}!#~'']{1,180}$'
        '--custom' = '^[A-Za-z0-9 _\-./\\:=+,@()\[\]{}!#~'']{1,180}$'
        '--architecture' = '^(?i:x86|x64|arm|arm64|neutral)$'
        '--locale' = '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3}$'
        '--installer-type' = '^(?i:msi|msix|appx|exe|inno|nullsoft|wix|burn|portable|zip)$'
    }
    $seen = [ordered]@{}
    $i = 0
    while ($i -lt $t.Length) {
        if ([char]::IsWhiteSpace($t[$i])) { $i++; continue }
        $m = [regex]::Match($t.Substring($i), '(?i)^(--[a-z][a-z\-]*)(?:\s+|=|$)')
        if (-not $m.Success) { return @{ Ok = $false; Options = ''; Error = "Extra winget options: '$($t.Substring($i).Split(' ')[0])' isn't an option (they start with --, e.g. --override `"/S`")." } }
        $name = $m.Groups[1].Value.ToLowerInvariant()
        if (-not $allowed.Contains($name)) { return @{ Ok = $false; Options = ''; Error = "Extra winget options: $name isn't taken - only $(@($allowed.Keys) -join ', ')." } }
        if ($seen.Contains($name)) { return @{ Ok = $false; Options = ''; Error = "Extra winget options: $name is there twice." } }
        $i += $m.Length
        while ($i -lt $t.Length -and [char]::IsWhiteSpace($t[$i])) { $i++ }
        if ($i -ge $t.Length) { return @{ Ok = $false; Options = ''; Error = "Extra winget options: $name has no value." } }
        $value = ''
        if ($t[$i] -eq '"') {
            $end = $t.IndexOf('"', $i + 1)
            if ($end -lt 0) { return @{ Ok = $false; Options = ''; Error = "Extra winget options: the value of $name has no closing double quote." } }
            $value = $t.Substring($i + 1, $end - $i - 1); $i = $end + 1
        }
        elseif ($t[$i] -eq "'") {
            $sb = New-Object System.Text.StringBuilder
            $j = $i + 1; $closed = $false
            while ($j -lt $t.Length) {
                if ($t[$j] -eq "'") { if ($j + 1 -lt $t.Length -and $t[$j + 1] -eq "'") { [void]$sb.Append("'"); $j += 2; continue }; $closed = $true; break }
                [void]$sb.Append($t[$j]); $j++
            }
            if (-not $closed) { return @{ Ok = $false; Options = ''; Error = "Extra winget options: the value of $name has no closing single quote." } }
            $value = $sb.ToString(); $i = $j + 1
        }
        else {
            $end = $i
            while ($end -lt $t.Length -and -not [char]::IsWhiteSpace($t[$end])) { $end++ }
            $value = $t.Substring($i, $end - $i); $i = $end
        }
        if ($i -lt $t.Length -and -not [char]::IsWhiteSpace($t[$i])) { return @{ Ok = $false; Options = ''; Error = "Extra winget options: put a space after the value of $name." } }
        $value = $value.Trim()
        if ($value -cnotmatch $allowed[$name]) {
            $why = if ($name -in '--override', '--custom') { "plain letters, digits, spaces and / \ - _ . : = + , @ ( ) [ ] { } ! # ~ ' - no double quotes, backtick, `$, %, ;, &, |, <, > or ^" } else { 'not a value winget knows' }
            return @{ Ok = $false; Options = ''; Error = "Extra winget options: the value of $name isn't allowed ($why)." }
        }
        $seen[$name] = $value
    }
    $parts = foreach ($k in $seen.Keys) { "$k '$($seen[$k].Replace("'", "''"))'" }
    return @{ Ok = $true; Options = (@($parts) -join ' '); Error = '' }
}

function Global:Get-WingetCommandOptions {
    <#
      Pure: the extra winget options a generated install command carries
      ('' when none) - read back from the command, so they stay through a
      new pinned version, a new Winget ID or another install context. Only
      options in the exact checked form count (ConvertTo-WingetOptionText).
    #>
    param([string]$InstallCommand)
    $m = [regex]::Match([string]$InstallCommand, ' --accept-source-agreements (--.+); exit \$LASTEXITCODE"$')
    if (-not $m.Success) { return '' }
    $o = ConvertTo-WingetOptionText $m.Groups[1].Value
    if ($o.Ok -and $o.Options -ceq $m.Groups[1].Value) { return $o.Options }
    return ''
}

function Global:Get-WingetCommandLines {
    <#
      The install and uninstall command lines for a Winget app.

      "Managed" pins -Version; "Winget" (also what anything else falls back
      to) installs the newest. Both call winget.exe itself: under SYSTEM it isn't on PATH, so the command finds
      it in the App Installer package folder first, and falls back to plain
      "winget" for a user install, which can't list that folder.
    #>
    param([string]$WingetId, [string]$Method, [string]$InstallContext, [string]$Version,
        # The form before 2.17 (no waiting for winget) - only to recognise commands generated then.
        [switch]$Legacy,
        # The form of 2.17-2.21 (System context also looked for winget.exe on PATH) - only to recognise commands generated then.
        [switch]$PathFallback,
        # Extra winget install options (2.25), as ConvertTo-WingetOptionText writes them - added to the install command only.
        [string]$Options)

    $ps = "%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile"
    # The ID ends up in code and command lines that run as SYSTEM on the
    # devices - escaped for its single quotes, and anything that would close
    # the surrounding double quotes removed (see ConvertTo-PsSingleQuotedContent).
    # A backslash never belongs in a winget ID - and one at the end would escape the closing quote of the WAU form.
    $WingetId = (ConvertTo-PsSingleQuotedContent $WingetId).Replace('\', '')
    # "Managed": winget itself, pinned to -Version - a release of exactly that
    # version (Get-ManagedWingetDetection checks for it or newer). Without a
    # version yet it is the plain winget form.
    $pin = ""
    if ($Method -eq "Managed") {
        $Method = "Winget"
        if ($Version -and (Test-ReleaseVersionText $Version)) { $pin = " --version '$(ConvertTo-PsSingleQuotedContent $Version)'" }
    }
    # "WAU" is only asked for to recognise commands of Winget-AutoUpdate's
    # Winget-Install.ps1 (before 2.19), so they can be switched to managed
    # updates - it is never generated for an app any more.
    # Checked again here: whatever reaches this point runs as SYSTEM on the devices.
    $opts = ''
    if ($Options) {
        $o = ConvertTo-WingetOptionText $Options
        if (-not $o.Ok) { throw $o.Error }
        $opts = " $($o.Options)"
    }
    if ($Method -ne "WAU") {
        $scope = if ($InstallContext -eq "User") { "" } else { " --scope machine" }
        # Newest App Installer first: there can be more than one version
        # side by side, and a plain name sort puts 1.9 after 1.21.
        # SYSTEM never takes a winget.exe from PATH (a folder there may be writable by users): only the protected App Installer folder.
        # A user install may - it can't list that folder, and runs as that user anyway.
        $pathPart = if ($InstallContext -eq "User" -or $PathFallback) { 'if (-not $w) { $w = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source }; ' } else { "" }
        $find = if ($Legacy) { "`$w = Get-Item `$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe -ErrorAction SilentlyContinue | Sort-Object { `$_.VersionInfo.FileVersionRaw } | Select-Object -Last 1 -ExpandProperty FullName; if (-not `$w) { `$w = 'winget' }" }
        # A new device (Autopilot) can get its apps before App Installer is
        # registered: winget is looked for up to 5 minutes, then the command
        # exits 9009 - a Retry return code (Add-WingetRetryReturnCode), so
        # Intune tries again later instead of reporting a failure.
        else { "`$w = `$null; for (`$i = 0; `$i -lt 30 -and -not `$w; `$i++) { `$w = Get-Item `$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe -ErrorAction SilentlyContinue | Sort-Object { `$_.VersionInfo.FileVersionRaw } | Select-Object -Last 1 -ExpandProperty FullName; $($pathPart)if (-not `$w) { Start-Sleep 10 } }; if (-not `$w) { exit 9009 }" }
        return @{
            Install   = "$ps -Command `"$find; & `$w install --id '$WingetId' -e$pin --source winget$scope --silent --accept-package-agreements --accept-source-agreements$opts; exit `$LASTEXITCODE`""
            Uninstall = "$ps -Command `"$find; & `$w uninstall --id '$WingetId' -e --source winget$scope --silent --accept-source-agreements; exit `$LASTEXITCODE`""
        }
    }
    return @{
        Install   = "$ps -File `"C:\Program Files\Winget-AutoUpdate\Winget-Install.ps1`" -AppIDs `"$WingetId`""
        Uninstall = "$ps -File `"C:\Program Files\Winget-AutoUpdate\Winget-Install.ps1`" -AppIDs `"$WingetId`" -Uninstall"
    }
}

function Global:Get-AppWingetInstallMethod {
    <#
      Which generated form an app's install and uninstall commands are:
      "WAU", "Winget", or "" when they are anything else - typed by hand,
      tuned with extra switches, or for a different Winget ID. Only an
      exact match counts, so a command someone edited is never mistaken
      for one this tool may rewrite.
    #>
    param([string]$WingetId, [string]$InstallCommand, [string]$UninstallCommand)

    if (-not $WingetId) { return "" }
    # Extra winget options (2.25) are part of the generated form: compared with them.
    $opts = Get-WingetCommandOptions $InstallCommand
    # A pinned winget command is the managed form, whatever version it pins.
    if ($InstallCommand -match " --version '((?:[^']|'')+)'") {
        $pinned = $Matches[1] -replace "''", "'"
        foreach ($context in @("System", "User")) {
            foreach ($form in 'now', 'path', 'legacy') {
                $generated = Get-WingetCommandLines -WingetId $WingetId -Method "Managed" -InstallContext $context -Version $pinned -Legacy:($form -eq 'legacy') -PathFallback:($form -eq 'path') -Options $(if ($form -eq 'now') { $opts } else { '' })
                if ($InstallCommand -eq $generated.Install -and $UninstallCommand -eq $generated.Uninstall) { return "Managed" }
            }
        }
        return ""
    }
    foreach ($method in @("WAU", "Winget")) {
        foreach ($context in @("System", "User")) {
            foreach ($form in 'now', 'path', 'legacy') {
                $generated = Get-WingetCommandLines -WingetId $WingetId -Method $method -InstallContext $context -Legacy:($form -eq 'legacy') -PathFallback:($form -eq 'path') -Options $(if ($form -eq 'now' -and $method -ne 'WAU') { $opts } else { '' })
                if ($InstallCommand -eq $generated.Install -and $UninstallCommand -eq $generated.Uninstall) { return $method }
            }
        }
    }
    return ""
}

function Global:Convert-AppWingetInstallMethod {
    <#
      An app's install and uninstall commands switched to -Method.

      Status says what happened: "Switched", "Already" (it uses that method
      now), or "Custom" (its commands aren't a generated form - see
      Get-AppWingetInstallMethod - and are handed back unchanged, because
      rewriting a command someone tuned by hand loses their change).
    #>
    param([string]$WingetId, [string]$InstallCommand, [string]$UninstallCommand, [string]$Method, [string]$InstallContext)

    $current = Get-AppWingetInstallMethod -WingetId $WingetId -InstallCommand $InstallCommand -UninstallCommand $UninstallCommand
    if (-not $current) { return @{ Status = "Custom"; Install = $InstallCommand; Uninstall = $UninstallCommand } }
    # Never back to Winget-AutoUpdate (2.19): its commands only switch away.
    if ($Method -eq 'WAU') { $Method = 'Winget' }
    $wanted = Get-WingetCommandLines -WingetId $WingetId -Method $Method -InstallContext $InstallContext -Options (Get-WingetCommandOptions $InstallCommand)
    if ($wanted.Install -eq $InstallCommand -and $wanted.Uninstall -eq $UninstallCommand) {
        return @{ Status = "Already"; Install = $InstallCommand; Uninstall = $UninstallCommand }
    }
    return @{ Status = "Switched"; Install = $wanted.Install; Uninstall = $wanted.Uninstall }
}

function Global:Get-CatalogNameLookup {
    <#
      The catalog's app names as a hashtable (case-insensitive, like -eq),
      built once per catalog list - the same list object, count and last
      name - not for every app. No @() on the list: in Get-DefaultAppMetadata's
      callers that trips PowerShell ("Argument types do not match").
    #>
    $appsNow = $Global:App.Apps
    # Count and last name read straight off the list, so a cache hit doesn't walk it.
    $count = 0; $last = ''
    if ($appsNow -is [System.Collections.IList]) { $count = $appsNow.Count; if ($count) { $last = [string]$appsNow[$count - 1].appName } }
    else { foreach ($a in $appsNow) { $count++; $last = [string]$a.appName } }
    $identity = 0
    if ($null -ne $appsNow) { $identity = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($appsNow) }
    $cache = $Global:App.CatalogNamesCache   # one object, replaced whole: a request in another runspace never sees half of it
    if ($cache -and $cache['Identity'] -eq $identity -and $cache['N'] -eq $count -and $cache['Last'] -ceq $last) { return $cache['Names'] }
    $names = @{}
    foreach ($a in $appsNow) { if ($a.appName) { $names[[string]$a.appName] = $true } }
    if ($null -ne $appsNow) { $Global:App['CatalogNamesCache'] = @{ Identity = $identity; N = $count; Last = $last; Names = $names } }
    return $names
}

function Global:Get-DefaultAppMetadata {
    param([string]$AppName, [string]$WingetId, [bool]$Uncommon)

    $templates = Get-CreateAppTemplates -WingetId $WingetId -Uncommon $Uncommon
    $das = $Global:App.DefaultAppSettings
    # Each configured name only counts as a default dependency if an app by
    # that name actually exists in the catalog (same as the single-
    # dependency version this replaced) AND isn't this app itself - a
    # default dependency list that happens to include the app currently
    # being defaulted (e.g. computing Winget AutoUpdate's own defaults)
    # would otherwise make it depend on itself.
    # One pass over the catalog into a lookup, rather than a pipeline scan
    # of every app per configured dependency name. This function runs once
    # per app on every grid refresh (via Test-AppHasCustomConfig), so the
    # scan it replaces was the whole catalog walked once per dependency
    # name per app - quadratic in catalog size, for a question that is just
    # "is there an app called this?". A PowerShell hashtable matches names
    # case-insensitively, exactly as the -eq it replaces did.
    # The name lookup is built once per catalog list (the same list object), not for every app - for the
    # Apps list that was every app walked once per app.
    $catalogNames = Get-CatalogNameLookup
    $defaultDeps = @(
        $das.DefaultDependencyAppNames | Where-Object {
            $depName = $_
            $depName -and $depName -ne $AppName -and $catalogNames.ContainsKey([string]$depName)
        }
    )

    return [pscustomobject]@{
        description      = $AppName
        publisher        = ""
        owner            = ""
        developer        = ""
        informationUrl   = ""
        privacyUrl       = ""
        notes            = ""
        appVersion       = ""
        isFeatured       = $false
        installCommand   = $templates.Install
        uninstallCommand = $templates.Uninstall
        architecture     = $das.Architecture
        installContext   = $das.InstallContext
        minOSKey         = $das.MinOSKey
        detectionRule    = if ($templates.Detection) { [pscustomobject]@{ Type = "Script"; Script_Content = $templates.Detection } } else { $null }
        dependencies     = $defaultDeps
        # Nothing superseded by default. Empty, not $null: this is what a
        # new app is created with, and what Custom Config compares against.
        supersedes       = @()
        minDiskSpaceMB          = $das.MinDiskSpaceMB
        minMemoryMB             = $das.MinMemoryMB
        minProcessors           = $das.MinProcessors
        minCpuSpeedMHz          = $das.MinCpuSpeedMHz
        installTimeMinutes      = $das.InstallTimeMinutes
        deviceRestartBehavior   = $das.DeviceRestartBehavior
        allowAvailableUninstall = $das.AllowAvailableUninstall
        # The generated winget commands exit 9009 when winget isn't on a new device yet - Retry, not Failed.
        returnCodes             = $(if ([string]$templates.Install -like '*exit 9009*') { @(Add-WingetRetryReturnCode @($das.ReturnCodes)) } else { @($das.ReturnCodes) })
    }
}

function Global:Test-AppHasCustomConfig {
    param($App)

    if (Test-AppIsUncommon -App $App) { return $true }
    if (-not $App.metadata) { return $false }

    $defaults = Get-DefaultAppMetadata -AppName $App.appName -WingetId $App.wingetId -Uncommon $false
    # App version is a fact about the package, not a setting - an app
    # whose version was pulled from Intune isn't custom because of it.
    $diffs = @(Get-CatalogMetadataFieldDiffs -Local $App.metadata -Remote $defaults | Where-Object { $_.Field -ne "App version" })
    return ($diffs.Count -gt 0)
}

function Global:Test-ReleaseVersionText {
    # Pure: a version a release can pin - letters, digits and . - + _ only, at most 64 characters (it goes into a command line).
    param([string]$Version)
    return [bool]($Version -match '^[0-9A-Za-z][0-9A-Za-z.\-+_]{0,63}$')
}

function Global:Get-ManagedWingetDetection {
    <#
      Pure: the detection script of a managed release - installed when
      winget lists -WingetId at -Version or newer. Newer counts too: a
      device a later release (or the app itself) already updated must not
      get the older version again.

      -NamePattern (Get-InstalledNamePattern of the name Windows lists it
      under): the Uninstall entries are looked at first - fast, and it works
      while winget isn't there yet. Only when no entry has the version or
      newer does winget get asked (an entry under another name, or none).
    #>
    param([string]$WingetId, [string]$Version, [string]$NamePattern = '')
    $id = ConvertTo-PsSingleQuotedContent $WingetId
    $v = ConvertTo-PsSingleQuotedContent $Version
    $np = ConvertTo-PsSingleQuotedContent $NamePattern
    return @"
`$AppToDetect = '$id'
`$Wanted = '$v'
`$NamePattern = '$np'

Function Get-WingetCmd {
    `$WingetCmd = `$null
    try {
        `$WingetInfo = (Get-Item "`$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe").VersionInfo | Sort-Object -Property FileVersionRaw
        `$WingetCmd = `$WingetInfo[-1].FileName
    }
    catch {
        if (Test-Path "`$env:LocalAppData\Microsoft\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe") {
            `$WingetCmd = "`$env:LocalAppData\Microsoft\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"
        }
    }
    return `$WingetCmd
}

# 1 when `$b is newer than `$a, 0 the same, -1 older: numbers as numbers, part by part.
Function Compare-Version([string]`$a, [string]`$b) {
    `$pa = @(`$a -split '[.\-+_ ]' | Where-Object { `$_ -ne '' }); `$pb = @(`$b -split '[.\-+_ ]' | Where-Object { `$_ -ne '' })
    for (`$i = 0; `$i -lt [Math]::Max(`$pa.Count, `$pb.Count); `$i++) {
        `$x = if (`$i -lt `$pa.Count) { `$pa[`$i] } else { '0' }; `$y = if (`$i -lt `$pb.Count) { `$pb[`$i] } else { '0' }
        if (`$x -match '^\d+$' -and `$y -match '^\d+$') {
            `$xs = `$x.TrimStart('0'); `$ys = `$y.TrimStart('0')
            if (`$xs.Length -ne `$ys.Length) { return [Math]::Sign(`$ys.Length - `$xs.Length) }
            `$c = [string]::CompareOrdinal(`$ys, `$xs); if (`$c) { return [Math]::Sign(`$c) }
        }
        elseif (`$x -ne `$y) { return [Math]::Sign([string]::CompareOrdinal(`$y.ToLowerInvariant(), `$x.ToLowerInvariant())) }
    }
    return 0
}

# First the Uninstall entries Windows keeps (64-bit, 32-bit, the user's).
if (`$NamePattern) {
    foreach (`$Root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
        foreach (`$Key in @(Get-ChildItem -LiteralPath `$Root -ErrorAction SilentlyContinue)) {
            `$Entry = Get-ItemProperty -LiteralPath `$Key.PSPath -ErrorAction SilentlyContinue
            if (`$Entry -and [string]`$Entry.DisplayName -match `$NamePattern -and `$Entry.DisplayVersion -and (Compare-Version `$Wanted ([string]`$Entry.DisplayVersion)) -ge 0) { return "Installed!" }
        }
    }
}

`$winget   = Get-WingetCmd
if (-not `$winget) { return }
`$JsonFile = "`$env:TEMP\InstalledApps-`$([guid]::NewGuid().ToString('N')).json"
& `$winget export -o `$JsonFile --include-versions --accept-source-agreements | Out-Null
`$Json     = Get-Content `$JsonFile -Raw | ConvertFrom-Json
Remove-Item `$JsonFile -Force -ErrorAction SilentlyContinue
`$Apps = @(`$Json.Sources.Packages | Where-Object { `$_.PackageIdentifier -eq `$AppToDetect })
foreach (`$App in `$Apps) {
    if (`$App.Version -and (Compare-Version `$Wanted ([string]`$App.Version)) -ge 0) { return "Installed!" }
}
"@
}

function Global:Set-ManagedAppPin {
    <#
      Pure apart from changing -App: a managed app's install and uninstall
      commands and detection rule, pinned to its App version (metadata.appVersion).
      Commands someone edited by hand (neither generated form) are left
      alone. Returns whether anything changed.
    #>
    param($App, [string]$ProductCode)
    if (-not $App.managedUpdates -or -not $App.metadata) { return $false }
    $m = $App.metadata
    $version = [string]$m.appVersion
    if (-not (Test-ReleaseVersionText $version)) { return $false }
    # An app with its own package: the version is in its detection rule (and an MSI's product code, which a new MSI usually changes).
    if (-not $App.wingetId) {
        $oldCode = [string]$(if ($m.detectionRule) { $m.detectionRule.Msi_ProductCode })
        $rule = Set-DetectionRuleVersion -Rule $m.detectionRule -Version $version -ProductCode $ProductCode
        if (-not $rule.Changed) { return $false }
        $m.detectionRule = $rule.Rule
        # A new MSI usually has a new product code: "msiexec /x {old}" would uninstall nothing.
        $newCode = [string]$rule.Rule.Msi_ProductCode
        if ($oldCode -and $newCode -and $oldCode -ne $newCode -and [string]$m.uninstallCommand -and ([string]$m.uninstallCommand).IndexOf($oldCode, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $m.uninstallCommand = [regex]::Replace([string]$m.uninstallCommand, [regex]::Escape($oldCode), $newCode.Replace('$', '$$'), 'IgnoreCase')
        }
        return $true
    }
    if (-not (Get-AppWingetInstallMethod -WingetId $App.wingetId -InstallCommand $m.installCommand -UninstallCommand $m.uninstallCommand) -and $m.installCommand) { return $false }
    $c = Get-WingetCommandLines -WingetId $App.wingetId -Method "Managed" -InstallContext $m.installContext -Version $version -Options (Get-WingetCommandOptions ([string]$m.installCommand))
    $onDevices = ([string]$(if ([string]$App.detectedName) { $App.detectedName } else { $App.appName })).Trim()
    $detect = Get-ManagedWingetDetection -WingetId $App.wingetId -Version $version -NamePattern $(if ($onDevices) { Get-InstalledNamePattern $onDevices } else { '' })
    $changed = ($m.installCommand -ne $c.Install) -or ($m.uninstallCommand -ne $c.Uninstall) -or -not ($m.detectionRule -and $m.detectionRule.Type -eq 'Script' -and $m.detectionRule.Script_Content -eq $detect)
    $m.installCommand = $c.Install; $m.uninstallCommand = $c.Uninstall
    $m.detectionRule = [pscustomobject]@{ Type = 'Script'; Script_Content = $detect }
    # The install command exits 9009 when winget never turned up (a new device): Retry, not a failure.
    $codes = @(Add-WingetRetryReturnCode $m.returnCodes)
    if (@($m.returnCodes).Count -ne $codes.Count) {
        if ($m.PSObject.Properties['returnCodes']) { $m.returnCodes = $codes } else { $m | Add-Member -NotePropertyName returnCodes -NotePropertyValue $codes }
        $changed = $true
    }
    return $changed
}

function Global:Test-VersionDetectionRule {
    # Pure: why -Rule can't follow a new version ('' when it can) - an MSI rule, or a file or registry rule that compares a version.
    param($Rule)
    if (-not $Rule) { return 'It has no detection rule.' }
    switch ([string]$Rule.Type) {
        'Msi' { return '' }
        'File' { if ([string]$Rule.File_DetectionType -eq 'version') { return '' } }
        'Registry' { if ([string]$Rule.Reg_DetectionType -eq 'version') { return '' } }
    }
    return "Its detection rule doesn't compare a version (an MSI rule, or a file or registry rule detecting by version) - a release couldn't tell the new version from the old one. Change it in the editor's Deploy settings."
}

function Global:Set-DetectionRuleVersion {
    <#
      Pure: a copy of -Rule that detects -Version or newer: the MSI version
      (and -ProductCode when given), or the file / registry version. The
      operator becomes "greater than or equal" when it was not a version
      comparison. @{ Rule; Changed }; an unsuitable rule comes back as it was.
    #>
    param($Rule, [string]$Version, [string]$ProductCode)
    if (Test-VersionDetectionRule $Rule) { return @{ Rule = $Rule; Changed = $false } }
    $r = $Rule.PSObject.Copy()
    $before = ($Rule | ConvertTo-Json -Compress -Depth 4)
    $ops = 'greaterThanOrEqual', 'greaterThan', 'equal'
    switch ([string]$r.Type) {
        'Msi' {
            $r.Msi_Version = $Version
            if ([string]$r.Msi_VersionOperator -notin $ops) { $r.Msi_VersionOperator = 'greaterThanOrEqual' }
            if ($ProductCode -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') { $r.Msi_ProductCode = $ProductCode.ToUpperInvariant() }
        }
        'File' { $r.File_DetectionValue = $Version; if ([string]$r.File_Operator -notin $ops) { $r.File_Operator = 'greaterThanOrEqual' } }
        'Registry' { $r.Reg_DetectionValue = $Version; if ([string]$r.Reg_Operator -notin $ops) { $r.Reg_Operator = 'greaterThanOrEqual' } }
    }
    return @{ Rule = $r; Changed = (($r | ConvertTo-Json -Compress -Depth 4) -ne $before) }
}

function Global:Format-ReleaseSpan {
    # Pure: a pilot's length for the reasons - hours below a day (a fast-track release), days otherwise.
    param([double]$Days)
    if ($Days -lt 1) { $h = [Math]::Floor($Days * 24); return "$h hour$(if ($h -ne 1) { 's' })" }
    $d = [Math]::Floor($Days); return "$d day$(if ($d -ne 1) { 's' })"
}

function Global:Get-ReleaseDecision {
    <#
      Pure: what to do with a pilot release now. -Counts: the pilot app's
      installed / failed / pending devices (Intune's install summary).
      -Policy: Days (in this ring at least this long - a fraction for a
      fast-track release counted in hours), MaxFailedPercent (of installed
      + failed), MinInstalled (devices). -Ring / -RingCount: which release
      ring the release is in (0 = the pilot groups) and how many there are.
      Action: promote (to everyone), advance (to the next ring), wait, or
      hold (something is wrong - a person looks).
    #>
    param([datetime]$ReleasedAt, [datetime]$Now, $Counts, $Policy, [int]$Ring = 0, [int]$RingCount = 1)
    $days = [double]$Policy.Days; $max = [double]$Policy.MaxFailedPercent; $min = [int]$Policy.MinInstalled
    $age = ($Now - $ReleasedAt).TotalDays
    $installed = [int]$Counts.installed; $failed = [int]$Counts.failed
    $tried = $installed + $failed
    $pct = if ($tried) { [Math]::Round(100.0 * $failed / $tried, 1) } else { 0 }
    $where = if ($RingCount -gt 1) { "ring $($Ring + 1) of $RingCount" } else { 'pilot' }
    $summary = "$installed installed, $failed failed$(if ([int]$Counts.pending) { ", $([int]$Counts.pending) pending" }) on $(if ($RingCount -gt 1) { 'release-ring' } else { 'pilot' }) devices"
    $span = if ($days -lt 1) { Format-ReleaseSpan $age } else { "$([Math]::Floor($age))" }
    if ($tried -and $pct -gt $max) { return @{ Action = 'hold'; Reason = "$summary - $pct % failed, more than the $max % allowed. Look at Install status, then promote or withdraw it." } }
    if ($age -lt $days) { return @{ Action = 'wait'; Reason = "$summary - in $where for $span of $(Format-ReleaseSpan $days)." } }
    if ($installed -lt $min) {
        if ($age -ge 2 * [Math]::Max($days, 1)) { return @{ Action = 'hold'; Reason = "$summary - fewer than $min after $(Format-ReleaseSpan $age). Check the groups have devices." } }
        return @{ Action = 'wait'; Reason = "$summary - waiting for at least $min." }
    }
    $how = "$summary$(if ($tried) { " ($pct % failed)" }) after $(Format-ReleaseSpan $age)"
    if ($Ring -lt $RingCount - 1) { return @{ Action = 'advance'; Reason = "$how in $where - ready for the next ring." } }
    return @{ Action = 'promote'; Reason = "$how." }
}

function Global:Get-EffectiveReleaseRule {
    <#
      Pure: the rule a pilot release is judged by - the release policy,
      with the app's own values (releaseRule) over it; a fast-track
      release waits FastTrackHours instead of the days.
    #>
    param($Policy, $App, $Release)
    $rule = @{ Days = [double]$Policy.Days; MaxFailedPercent = [double]$Policy.MaxFailedPercent; MinInstalled = [int]$Policy.MinInstalled; Own = $false; FastTrack = $false }
    $own = if ($App) { $App.releaseRule } else { $null }
    if ($own) {
        if ($null -ne $own.days) { $rule.Days = [double]$own.days; $rule.Own = $true }
        if ($null -ne $own.maxFailedPercent) { $rule.MaxFailedPercent = [double]$own.maxFailedPercent; $rule.Own = $true }
        if ($null -ne $own.minInstalled) { $rule.MinInstalled = [int]$own.minInstalled; $rule.Own = $true }
    }
    if ($Release -and $Release.fastTrack) {
        $hours = [int]$Policy.FastTrackHours; if ($hours -lt 1) { $hours = 4 }
        $rule.Days = $hours / 24.0; $rule.FastTrack = $true
    }
    return $rule
}

function Global:Get-ReleaseRingGroups {
    # Pure: the groups a release in ring -Ring is assigned to - the pilot groups and every ring up to this one.
    param($Rings, [int]$Ring)
    $out = New-Object System.Collections.Generic.List[string]
    $list = @($Rings)
    for ($i = 0; $i -le $Ring -and $i -lt $list.Count; $i++) { foreach ($g in @($list[$i].Groups)) { if ($g -and -not $out.Contains([string]$g)) { $out.Add([string]$g) } } }
    return $out.ToArray()
}

function Global:ConvertFrom-ReleaseRingText {
    <#
      Pure: the release rings after the pilot groups, from Settings' text -
      one ring per line, "Name: group, group". @{ Rings; Error }.
    #>
    param([string]$Text)
    $rings = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($line in @(([string]$Text) -split "`r?`n")) {
        $n++
        $t = $line.Trim(); if (-not $t) { continue }
        $m = [regex]::Match($t, '^([^:]{1,60}):\s*(.+)$')
        if (-not $m.Success) { return @{ Rings = @(); Error = "Line ${n}: write it as ""Name: group, group""." } }
        $groups = @($m.Groups[2].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if (-not $groups.Count) { return @{ Rings = @(); Error = "Line ${n}: no group." } }
        $rings.Add([ordered]@{ Name = $m.Groups[1].Value.Trim(); Groups = $groups })
    }
    if ($rings.Count -gt 5) { return @{ Rings = @(); Error = 'At most five rings after the pilot groups.' } }
    return @{ Rings = $rings.ToArray(); Error = '' }
}

function Global:Get-ReleaseAssignmentSettings {
    <#
      Pure: the settings for a release's Required assignments (Win32):
      the install deadline (DeadlineDays after now; a fast-track release
      installs as soon as possible, in the foreground), the restart grace
      period and the notifications. $null when every one is Intune's
      default - the assignments are then sent without settings, as before.
    #>
    param($Policy, [bool]$FastTrack, [datetime]$NowUtc)
    $deadlineDays = if ($FastTrack) { 0 } else { [int]$Policy.DeadlineDays }
    $grace = [int]$Policy.RestartGraceMinutes
    $notif = [string]$Policy.Notifications; if ($notif -notin 'showAll', 'showReboot', 'hideAll') { $notif = 'showAll' }
    if (-not $FastTrack -and -not $deadlineDays -and -not $grace -and $notif -eq 'showAll') { return $null }
    $s = [ordered]@{ '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings'; notifications = $notif
        deliveryOptimizationPriority = $(if ($FastTrack) { 'foreground' } else { 'notConfigured' }); installTimeSettings = $null; restartSettings = $null }
    if ($deadlineDays) { $s.installTimeSettings = [ordered]@{ useLocalTime = $false; startDateTime = $null; deadlineDateTime = $NowUtc.AddDays($deadlineDays).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) } }
    if ($grace) { $s.restartSettings = [ordered]@{ gracePeriodInMinutes = $grace; countdownDisplayBeforeRestartInMinutes = [Math]::Min(15, $grace); restartNotificationSnoozeDurationInMinutes = [Math]::Min(240, $grace) } }
    return $s
}

function Global:Get-ManagedRunAlert {
    <#
      Pure: whether a run's report is worth an alert, and its text.
      -Level: off, attention (something failed, is on hold, is ready for a
      person, or was released / promoted / advanced), or always.
      @{ Send; Title; Lines }.
    #>
    param($Report, [string]$Level)
    $items = @($Report.items)
    $loud = @('failed', 'hold', 'ready', 'promoted', 'released', 'advanced', 'advance', 'withdrawn', 'drift', 'fixed', 'health')
    $hits = @($items | Where-Object { $loud -contains [string]$_.outcome })
    $send = switch ($Level) { 'always' { $true } 'attention' { $hits.Count -gt 0 } default { $false } }
    $failed = [int]$Report.failed
    $title = "Managed updates: " + $(if ($failed) { "$failed failed" } elseif ($hits.Count) { "$($hits.Count) to look at" } else { 'nothing to do' }) + $(if ($Report.planOnly) { ' (plan only)' })
    $lines = @($(if ($Level -eq 'always') { $items } else { $hits }) | ForEach-Object { "$($_.app) - $($_.outcome): $($_.text)" })
    return @{ Send = $send; Title = $title; Lines = $lines }
}

function Global:Test-ReleaseWindow {
    <#
      Pure: may the nightly run release, advance or promote now? -Policy:
      ReleaseDays (weekday numbers, 0 = Sunday ... 6 = Saturday) and
      SkipLastWeek (not in a month's last seven days). @{ Open; Reason }.
      Fast-track releases and a person's own clicks don't ask.
    #>
    param([datetime]$Now, $Policy)
    $names = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
    $days = @(@($Policy.ReleaseDays) | Where-Object { "$_" -match '^[0-6]$' } | ForEach-Object { [int]"$_" })
    if ($days.Count -and $days -notcontains [int]$Now.DayOfWeek) { return @{ Open = $false; Reason = "no releases on $($names[[int]$Now.DayOfWeek])s (release window: $(($days | Sort-Object | ForEach-Object { $names[$_].Substring(0, 3) }) -join ', '))" } }
    if ($Policy.SkipLastWeek -and $Now.Day -gt [DateTime]::DaysInMonth($Now.Year, $Now.Month) - 7) { return @{ Open = $false; Reason = "no releases in the last week of the month" } }
    return @{ Open = $true; Reason = '' }
}

function Global:Get-InstallErrorSummary {
    <#
      Pure: why devices failed, from install status rows (State, ErrorCode,
      Detail) - the failed ones grouped by error code, most common first.
      @{ Failed; Top = @(@{ code; detail; devices }); Text }.
    #>
    param($Rows, [int]$Top = 3)
    $failed = @(@($Rows) | Where-Object { $_ -and ([string]$_.State -match 'fail|error' -or ([string]$_.ErrorCode -and [string]$_.ErrorCode -notmatch '^(0|0x0+)$')) -and [string]$_.State -notmatch '^installed$' })
    $groups = @($failed | Group-Object { if ([string]$_.ErrorCode) { [string]$_.ErrorCode } else { '(no code)' } } | Sort-Object @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
    $topList = @($groups | Select-Object -First $Top | ForEach-Object {
            $detail = @($_.Group | ForEach-Object { [string]$_.Detail } | Where-Object { $_ } | Select-Object -First 1)
            [ordered]@{ code = $_.Name; detail = $(if ($detail.Count) { $detail[0] } else { '' }); devices = $_.Count } })
    $text = if ($failed.Count) { (@($topList | ForEach-Object { "$($_.devices) device$(if ($_.devices -ne 1) { 's' }): $($_.code)$(if ($_.detail) { " ($($_.detail))" })" }) -join '; ') + $(if ($groups.Count -gt $Top) { "; $($groups.Count - $Top) other error(s)" }) } else { '' }
    return @{ Failed = $failed.Count; Top = $topList; Text = $text }
}

function Global:Test-AutoWithdraw {
    # Pure: should the nightly run withdraw a release by itself - failed at least -Percent (0 = never) of at least three devices that tried?
    param($Counts, [double]$Percent)
    if ($Percent -le 0) { return $false }
    $installed = [int]$Counts.installed; $failed = [int]$Counts.failed
    $tried = $installed + $failed
    return [bool]($tried -ge 3 -and (100.0 * $failed / $tried) -ge $Percent)
}

function Global:Get-CertificateHealth {
    # Pure: the connection certificate's state from its expiry - @{ Level = ok|warn|failed; Text }. Warns from 30 days ahead.
    param($NotAfter, [datetime]$Now)
    if (-not $NotAfter) { return @{ Level = 'failed'; Text = 'The connection certificate is not on this PC (CurrentUser\My or LocalMachine\My) - every Intune step fails.' } }
    $left = [Math]::Floor(([datetime]$NotAfter - $Now).TotalDays)
    $when = ([datetime]$NotAfter).ToString('yyyy-MM-dd')
    if ($left -lt 0) { return @{ Level = 'failed'; Text = "The connection certificate expired on $when - every Intune step fails. Make a new one (Settings > Connection) and upload it to the app registration." } }
    if ($left -le 30) { return @{ Level = 'warn'; Text = "The connection certificate expires in $left day$(if ($left -ne 1) { 's' }) ($when). Make a new one (Settings > Connection) and upload it to the app registration before then." } }
    return @{ Level = 'ok'; Text = "The connection certificate is valid until $when." }
}

function Global:Get-InventorySuggestions {
    <#
      Pure: apps worth adding to the catalog - Intune's inventory of apps on
      devices (displayName, version, deviceCount) grouped by name, on at
      least -MinDevices devices, not already in the catalog (its names and
      names on devices, also followed by a version or "(x64)"), and not
      parts of Windows or drivers. Most devices first.
    #>
    param($Detected, $Apps, [int]$MinDevices = 3, [int]$Max = 40)
    $known = @(@($Apps) | ForEach-Object { [string]$_.appName; [string]$_.detectedName } | Where-Object { $_ } | ForEach-Object { '^' + [regex]::Escape($_) + '(\s+(v?\d[\w.\-]*|\([^)]*\)))*\s*$' })
    $system = '^(Microsoft (Visual C\+\+|Edge( Update| WebView2)?|Update Health Tools|\.NET|Windows Desktop Runtime|ASP\.NET|Intune Management Extension|Teams Meeting Add-in|OneDrive|GameInput|Policy Platform)|Windows |Update for |Security Update|Hotfix|Intel\(R\)|Realtek|NVIDIA|AMD |Dell |HP |Lenovo )'
    $byName = @{}
    foreach ($d in @($Detected)) {
        $name = ([string]$d.displayName).Trim()
        if (-not $name -or $name -match $system) { continue }
        $base = ($name -replace '(\s+(v?\d[\w.\-]*|\([^)]*\)))+\s*$', '').Trim()
        if (-not $base) { $base = $name }
        $hit = $false; foreach ($k in $known) { if ($name -match $k -or $base -match $k) { $hit = $true; break } }
        if ($hit) { continue }
        if (-not $byName.ContainsKey($base)) { $byName[$base] = @{ devices = 0; versions = New-Object System.Collections.Generic.List[string] } }
        $byName[$base].devices += [int]$d.deviceCount
        $v = [string]$d.version; if ($v -and -not $byName[$base].versions.Contains($v)) { $byName[$base].versions.Add($v) }
    }
    return @($byName.Keys | Where-Object { $byName[$_].devices -ge $MinDevices } | Sort-Object @{ Expression = { $byName[$_].devices }; Descending = $true }, @{ Expression = { $_ }; Descending = $false } | Select-Object -First $Max | ForEach-Object {
            [ordered]@{ name = $_; devices = $byName[$_].devices; versions = @($byName[$_].versions | Select-Object -First 5) } })
}

function Global:Get-GateVersion {
    <#
      Pure: the newest version a production catalog may release, when a
      test tenant's catalog gates it: the test catalog's current version of
      the same app (same Winget ID, else the same name) - only once it's
      newer than ours. @{ Version; Reason }; Version '' = nothing to release.
    #>
    param($App, $GateApps)
    $mine = [string]$(if ($App.metadata) { $App.metadata.appVersion })
    $twin = @(@($GateApps) | Where-Object { $_ -and (($App.wingetId -and [string]$_.wingetId -eq [string]$App.wingetId) -or (-not $App.wingetId -and [string]$_.appName -eq [string]$App.appName)) }) | Select-Object -First 1
    if (-not $twin) { return @{ Version = ''; Reason = 'not in the test catalog - nothing is released here until it is tested there' } }
    $theirs = [string]$(if ($twin.metadata) { $twin.metadata.appVersion })
    if (-not $theirs -or -not $twin.appId) { return @{ Version = ''; Reason = 'not deployed in the test tenant yet' } }
    if ((Compare-AppVersionText $mine $theirs) -ne 1) { return @{ Version = ''; Reason = "the test tenant is at $theirs - nothing newer approved" } }
    return @{ Version = $theirs; Reason = "$theirs is promoted in the test tenant" }
}

function Global:Get-MonthlyReportData {
    <#
      Pure: a month's managed-updates summary from the nightly reports
      (started, items, trend): what was released, promoted, advanced,
      withdrawn, held or failed, per app, and the share of devices on the
      current version at the start and end of the month.
    #>
    param($Reports, [string]$Month)
    $inMonth = @(@($Reports) | Where-Object { $_ -and ([string]$_.started).StartsWith($Month) } | Sort-Object { [string]$_.started })
    $events = New-Object System.Collections.Generic.List[object]
    $kinds = @('released', 'promoted', 'advanced', 'withdrawn', 'hold', 'failed', 'drift', 'health')
    $seen = @{}
    foreach ($r in $inMonth) {
        foreach ($i in @($r.items)) {
            if ($kinds -notcontains [string]$i.outcome) { continue }
            $key = "$($i.app)|$($i.outcome)|$($i.text)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $events.Add([ordered]@{ at = ([string]$r.started); app = [string]$i.app; outcome = [string]$i.outcome; text = [string]$i.text })
        }
    }
    $trend = @($inMonth | Where-Object { $_.trend -and $null -ne $_.trend.onCurrentPercent })
    $count = { param($o) @($events | Where-Object { $_.outcome -eq $o }).Count }
    return [ordered]@{ month = $Month; runs = $inMonth.Count
        released = (& $count 'released'); promoted = (& $count 'promoted'); withdrawn = (& $count 'withdrawn'); held = (& $count 'hold'); failed = (& $count 'failed')
        startPercent = $(if ($trend.Count) { $trend[0].trend.onCurrentPercent } else { $null }); endPercent = $(if ($trend.Count) { $trend[-1].trend.onCurrentPercent } else { $null })
        events = $events.ToArray() }
}

# ---------------------------------------------------------------- adding apps: winget details, installers, script apps

function Global:Get-WingetShowLabelMap {
    <#
      Pure: winget show's labels (lowercase) -> the field they fill. winget
      writes them in Windows' display language, so the common translations
      are here too (German, French, Spanish, Italian, Portuguese, Dutch).
      A label that isn't known is just left out.
    #>
    $m = @{}
    $add = { param($Field, [string[]]$Labels) foreach ($l in $Labels) { $m[$l.ToLowerInvariant()] = $Field } }
    & $add 'Version' @('Version', ('Versi' + [char]0xF3 + 'n'), 'Versione', ('Vers' + [char]0xE3 + 'o'), 'Versie')
    & $add 'Publisher' @('Publisher', 'Herausgeber', ([string][char]0xC9 + 'diteur'), 'Editeur', 'Editor', 'Publicador', 'Autore', 'Uitgever')
    & $add 'SupportUrl' @('Publisher Support Url', 'Herausgeber-Support-URL', 'Support-URL des Herausgebers', ("URL du support de l'" + [char]0xE9 + 'diteur'), 'URL de soporte del editor', "URL dell'assistenza dell'editore", 'URL de suporte do editor', 'Ondersteunings-URL van uitgever')
    & $add 'PublisherUrl' @('Publisher Url', 'Herausgeber-URL', ("URL de l'" + [char]0xE9 + 'diteur'), 'URL del editor', 'URL del publicador', "URL dell'editore", 'URL do editor', 'Uitgever-URL')
    & $add 'Description' @('Description', 'Short Description', 'Beschreibung', 'Kurzbeschreibung', ('Descripci' + [char]0xF3 + 'n'), 'Descrizione', ('Descri' + [char]0xE7 + [char]0xE3 + 'o'), 'Beschrijving')
    & $add 'Homepage' @('Homepage', 'Startseite', "Page d'accueil", ('P' + [char]0xE1 + 'gina principal'), ('P' + [char]0xE1 + 'gina inicial'), 'Home page', 'Startpagina')
    & $add 'License' @('License', 'Lizenz', 'Licence', 'Licencia', 'Licenza', ('Licen' + [char]0xE7 + 'a'), 'Licentie')
    & $add 'PrivacyUrl' @('Privacy Url', 'Datenschutz-URL', ('URL de confidentialit' + [char]0xE9), 'URL de privacidad', 'URL della privacy', 'URL de privacidade', 'Privacy-URL')
    & $add 'Tags' @('Tags', 'Markierungen', 'Balises', 'Etiquetas', 'Etichette', 'Marcas')
    & $add 'Author' @('Author', 'Autor', 'Auteur', 'Autore', 'Auteur(s)')
    return $m
}
function Global:Get-AppDetailsFill {
    <#
      Pure: what Fill in details sets on an app - only fields that are empty
      now (a description equal to the app's name counts as empty: Add apps
      writes the name when it has nothing better), never the App version.
      -Details: what winget show says (ConvertFrom-WingetShowOutput), or an
      installer's own (ProductName, Manufacturer). Returns an ordered field ->
      value list (empty when there's nothing to fill).
    #>
    param($Metadata, $Details, [string]$AppName, [string]$DefaultOwner)
    # A field the app's settings don't have at all counts as empty ('' - never $null, which has no .Trim()).
    $now = { param($k) $v = if ($Metadata -and $Metadata.PSObject.Properties[$k]) { $Metadata.$k } else { $null }; if ($null -eq $v) { '' } else { [string]$v } }
    $url = { param($u) $t = ([string]$u).Trim(); if ($t -match '^https?://[^\s"<>]{3,500}$') { $t } else { '' } }
    $out = [ordered]@{}
    $publisher = ([string]$Details.Publisher).Trim()
    if ($publisher -and -not (& $now 'publisher').Trim()) { $out.publisher = $publisher.Substring(0, [Math]::Min($publisher.Length, 200)) }
    $desc = ([string]$Details.Description).Trim()
    $haveDesc = (& $now 'description').Trim()
    if ($desc -and (-not $haveDesc -or $haveDesc -eq ([string]$AppName).Trim())) { $out.description = $desc.Substring(0, [Math]::Min($desc.Length, 2000)) }
    # The package's homepage; else the publisher's site; else its support page - any of them tells people where the app comes from.
    $info = & $url $(if ($Details.Homepage) { $Details.Homepage } elseif ($Details.PublisherUrl) { $Details.PublisherUrl } else { $Details.SupportUrl })
    if ($info -and -not (& $now 'informationUrl').Trim()) { $out.informationUrl = $info }
    $privacy = & $url $Details.PrivacyUrl
    if ($privacy -and -not (& $now 'privacyUrl').Trim()) { $out.privacyUrl = $privacy }
    $dev = ([string]$(if ($Details.Author) { $Details.Author } else { $Details.Publisher })).Trim()
    if ($dev -and -not (& $now 'developer').Trim()) { $out.developer = $dev.Substring(0, [Math]::Min($dev.Length, 200)) }
    $owner = ([string]$DefaultOwner).Trim()
    if ($owner -and -not (& $now 'owner').Trim()) { $out.owner = $owner }
    return $out
}

function Global:ConvertFrom-WingetShowOutput {
    <#
      Pure: "winget show --id X --exact" as @{ Name; Id; Version; Publisher;
      PublisherUrl; Description; Homepage; License; PrivacyUrl; Tags }. Keys
      are at the start of a line ("Key: value"); a value can continue on
      indented lines (a long description, the tags).
    #>
    param([string]$Text)
    $out = [ordered]@{ Name = ''; Id = ''; Version = ''; Publisher = ''; PublisherUrl = ''; SupportUrl = ''; Author = ''; Description = ''; Homepage = ''; License = ''; PrivacyUrl = ''; Tags = @() }
    $map = Get-WingetShowLabelMap
    $key = ''
    foreach ($raw in @(([string]$Text) -split "`r?`n")) {
        # After a progress spinner's last carriage return; control characters out.
        $line = (([string]$raw) -split "`r")[-1] -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
        # "Found 7-Zip [7zip.7zip]" ("Gefunden ...", "Trouve ..." in other Windows languages): the first line ending in [Id].
        $m = [regex]::Match($line, '^\S+\s+(.+?)\s+\[([A-Za-z0-9][A-Za-z0-9.\-_+]*)\]\s*$')
        if ($m.Success -and -not $out.Id) { $out.Name = $m.Groups[1].Value.Trim(); $out.Id = $m.Groups[2].Value.Trim(); $key = ''; continue }
        $m = [regex]::Match($line, "^(\p{L}[\p{L} '\-]*?):\s*(.*)$")
        if ($m.Success) {
            $k = $m.Groups[1].Value.ToLowerInvariant()
            $key = if ($map.ContainsKey($k)) { $map[$k] } else { '' }
            if ($key -eq 'Description' -and $out.Description) { $key = ''; continue }
            if ($key -eq 'Tags') { if ($m.Groups[2].Value.Trim()) { $out.Tags = @($m.Groups[2].Value.Trim()) } }
            elseif ($key) { $out[$key] = $m.Groups[2].Value.Trim() }
            continue
        }
        if ($key -and $line -match '^\s+\S') {
            $v = $line.Trim()
            if ($key -eq 'Tags') { $out.Tags = @($out.Tags) + $v }
            elseif ($key -eq 'Description') { $out.Description = ($out.Description + ' ' + $v).Trim() }
            continue
        }
        if ($line -notmatch '^\s') { $key = '' }
    }
    return $out
}

function Global:Get-InstallerKind {
    # Pure: an .exe installer's maker from strings in its first megabytes - inno, nsis, installshield, burn (WiX bundle), advanced (Advanced Installer), or '' when unknown.
    param([string]$Sample)
    if ($Sample -match 'Inno Setup') { return 'inno' }
    if ($Sample -match 'Nullsoft|NSIS Error') { return 'nsis' }
    if ($Sample -match 'WixBundle|\.wixburn|WiX Toolset') { return 'burn' }
    if ($Sample -match 'InstallShield') { return 'installshield' }
    if ($Sample -match 'Advanced Installer') { return 'advanced' }
    return ''
}

function Global:Get-InstallerProposal {
    <#
      Pure: how to deploy an installer, from what was read from it -
      -Info: @{ Kind = msi|exe; FileName; ProductName; Manufacturer;
      ProductVersion; ProductCode; ExeKind }. @{ Name; Publisher; Version;
      InstallCommand; UninstallCommand; Detection; NeedsUninstallScript;
      Notes = @(); ManagedOk }. MSI: msiexec, the product code and a
      version check (managed updates possible). EXE: the maker's silent
      switch, an uninstall script that finds the app's own uninstaller,
      and a detection script by the name and version Windows lists.
    #>
    param($Info)
    $file = [string]$Info.FileName
    $name = ([string]$Info.ProductName).Trim()
    # From the file's own name - it may be a path in an uploaded folder (Setup\setup.exe), on any system.
    if (-not $name) { $name = ([System.IO.Path]::GetFileNameWithoutExtension(($file -split '[\\/]')[-1]) -replace '[_\-.]+(x64|x86|amd64|win64|win32|setup|installer|install)$', '' -replace '[_]+', ' ' -replace '\s+v?\d[\d.]*$', '').Trim() }
    $version = ([string]$Info.ProductVersion).Trim() -replace '[^0-9A-Za-z.\-+_].*$', ''
    $notes = New-Object System.Collections.Generic.List[string]
    $p = [ordered]@{ Name = $name; Publisher = ([string]$Info.Manufacturer).Trim(); Version = $version; InstallCommand = ''; UninstallCommand = ''; Detection = $null; NeedsUninstallScript = $false; Notes = $null; ManagedOk = $false }
    $ps = '%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
    if ([string]$Info.Kind -eq 'msi') {
        $p.InstallCommand = "msiexec /i `"$file`" /qn /norestart"
        $code = [string]$Info.ProductCode
        if ($code -match '^\{[0-9A-Fa-f-]{36}\}$') {
            $p.UninstallCommand = "msiexec /x $($code.ToUpperInvariant()) /qn /norestart"
            $p.Detection = [ordered]@{ Type = 'Msi'; Msi_ProductCode = $code.ToUpperInvariant(); Msi_VersionOperator = $(if ($version) { 'greaterThanOrEqual' } else { 'notConfigured' }); Msi_Version = $version }
            $p.ManagedOk = [bool]$version
        }
        else { $notes.Add("The MSI's product code couldn't be read - set the uninstall command and the detection rule in the editor.") }
        $p.Notes = $notes.ToArray()
        return $p
    }
    # The maker's silent switches - one table (Get-ExeSilentSwitches), which the editor's blocks read too.
    $switches = Get-ExeSilentSwitches ([string]$Info.ExeKind)
    $p.InstallCommand = "`"$file`"$(if ($switches) { " $switches" })"
    if (-not $switches) { $notes.Add("The installer's maker wasn't recognised - add its silent switch to the install command (the vendor's documentation, or try /S, /quiet or /silent).") }
    $p.UninstallCommand = "$ps .\Uninstall.ps1"
    $p.NeedsUninstallScript = $true
    $label = if ($name) { $name } else { $file }
    $p.Detection = [ordered]@{ Type = 'Script'; Script_Content = (New-InstalledAppDetectionScript -DisplayName $label -Version $version) }
    $notes.Add("Detected by the name and version Windows lists under Apps ('$label' $(if ($version) { "$version or newer" } else { 'any version' })) - check that name after a test install. For managed updates, switch to a file rule by version.")
    $p.Notes = $notes.ToArray()
    return $p
}

function Global:New-InstalledAppDetectionScript {
    # Pure: a detection script - the app is installed when Windows lists it (Uninstall keys, both views) by -DisplayName (exactly, or with a version or "(x64)" after it) with -Version or newer.
    param([string]$DisplayName, [string]$Version)
    $pat = ConvertTo-PsLiteral (Get-InstalledNamePattern $DisplayName); $v = ConvertTo-PsLiteral $Version
    return @"
`$pattern = $pat; `$want = $v
`$keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
foreach (`$e in @(Get-ItemProperty -Path `$keys -ErrorAction SilentlyContinue | Where-Object { [string]`$_.DisplayName -match `$pattern })) {
    if (-not `$want) { Write-Output 'Installed'; exit 0 }
    try { if ([version]([string]`$e.DisplayVersion -replace '[^0-9.].*$', '') -ge [version](`$want -replace '[^0-9.].*$', '')) { Write-Output 'Installed'; exit 0 } } catch { if ([string]`$e.DisplayVersion -eq `$want) { Write-Output 'Installed'; exit 0 } }
}
exit 0
"@
}

function Global:New-InstalledAppUninstallScript {
    # Pure: Uninstall.ps1 for an .exe app - runs the uninstaller Windows lists for -DisplayName (exactly, or with a version or "(x64)" after it), silently.
    param([string]$DisplayName, [string]$ExeKind)
    $pat = ConvertTo-PsLiteral (Get-InstalledNamePattern $DisplayName)
    $sw = switch ($ExeKind) { 'inno' { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' } 'nsis' { '/S' } 'burn' { '/uninstall /quiet /norestart' } 'installshield' { '/s' } default { '/S' } }
    return @"
# Uninstalls the app: the uninstaller Windows lists for it, silently. Written by Intune App Catalog.
`$pattern = $pat
`$keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
`$entry = @(Get-ItemProperty -Path `$keys -ErrorAction SilentlyContinue | Where-Object { [string]`$_.DisplayName -match `$pattern }) | Select-Object -First 1
if (-not `$entry) { Write-Output 'Not installed.'; exit 0 }
if (`$entry.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$' -and `$entry.UninstallString -match 'msiexec') {
    `$p = Start-Process msiexec.exe -ArgumentList "/x `$(`$entry.PSChildName) /qn /norestart" -Wait -PassThru; exit `$p.ExitCode
}
`$cmd = if (`$entry.QuietUninstallString) { [string]`$entry.QuietUninstallString } else { [string]`$entry.UninstallString + ' $sw' }
`$m = [regex]::Match(`$cmd, '^\s*"([^"]+)"\s*(.*)$')
if (-not `$m.Success) { `$m = [regex]::Match(`$cmd, '^\s*(\S+\.exe)\s*(.*)$') }
if (-not `$m.Success) { Write-Output "Can't read the uninstall command: `$cmd"; exit 1 }
`$p = Start-Process -FilePath `$m.Groups[1].Value -ArgumentList `$m.Groups[2].Value -Wait -PassThru
exit `$p.ExitCode
"@
}

function Global:Get-ScriptAppTemplates {
    # Pure: the starting points for a script app: @(@{ id; label; install; uninstall }), with the app's name and version filled in. Each install writes the version marker the detection rule reads.
    param([string]$Name, [string]$Version)
    # Quoted for PowerShell (ConvertTo-PsLiteral): a name or version can't end a string in the scripts.
    $key = ConvertTo-PsLiteral ("HKLM:\SOFTWARE\IntuneAppCatalog\Apps\" + ([string]$Name -replace '[\\/]', '-')); $ver = ConvertTo-PsLiteral $Version; $folderName = ConvertTo-PsLiteral ([string]$Name -replace '[\\/:*?"<>|]', '-')
    $marker = @"
# The version marker Intune's detection rule reads (HKLM\SOFTWARE\IntuneAppCatalog\Apps\<name>, Version) - keep it last.
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -LiteralPath $key -Name Version -Value $ver
"@
    $unmarker = "Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue"
    $head = "`$ErrorActionPreference = 'Stop'`r`n# Runs as SYSTEM from the package folder (every file you put in Packages\<app> is next to it).`r`n"
    return @(
        [ordered]@{ id = 'installer'; label = 'Run an installer with arguments'
            install = $head + "`$p = Start-Process -FilePath (Join-Path `$PSScriptRoot 'setup.exe') -ArgumentList '/S' -Wait -PassThru`r`nif (`$p.ExitCode -notin 0, 3010) { exit `$p.ExitCode }`r`n" + $marker + "`r`nexit `$p.ExitCode"
            uninstall = $head + "`$p = Start-Process -FilePath (Join-Path (Join-Path `$env:ProgramFiles $folderName) 'uninstall.exe') -ArgumentList '/S' -Wait -PassThru`r`n$unmarker`r`nexit `$p.ExitCode" },
        [ordered]@{ id = 'files'; label = 'Copy files to Program Files'
            install = $head + "`$target = Join-Path `$env:ProgramFiles $folderName`r`nNew-Item -ItemType Directory -Path `$target -Force | Out-Null`r`nCopy-Item -Path (Join-Path `$PSScriptRoot 'files\*') -Destination `$target -Recurse -Force`r`n" + $marker
            uninstall = $head + "Remove-Item -Path (Join-Path `$env:ProgramFiles $folderName) -Recurse -Force -ErrorAction SilentlyContinue`r`n$unmarker" },
        [ordered]@{ id = 'settings'; label = 'Set registry values (a configuration)'
            install = $head + "New-Item -Path 'HKLM:\SOFTWARE\Policies\Vendor\App' -Force | Out-Null`r`nSet-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Vendor\App' -Name 'Setting' -Value 1 -Type DWord`r`n" + $marker
            uninstall = $head + "Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Vendor\App' -Name 'Setting' -ErrorAction SilentlyContinue`r`n$unmarker" },
        [ordered]@{ id = 'blank'; label = 'Empty script'
            install = $head + "# Your install steps here.`r`n" + $marker
            uninstall = $head + "# Your uninstall steps here.`r`n$unmarker" }
    )
}

function Global:Get-ScriptAppMarkerRule {
    # Pure: the detection rule for a script app - its version marker, this version or newer (so managed updates can follow it).
    param([string]$Name, [string]$Version)
    return [ordered]@{ Type = 'Registry'; Reg_KeyPath = "HKEY_LOCAL_MACHINE\SOFTWARE\IntuneAppCatalog\Apps\$($Name -replace '[\\/]', '-')"; Reg_ValueName = 'Version'; Reg_Check32Bit = $false
        Reg_DetectionType = $(if ($Version) { 'version' } else { 'exists' }); Reg_Operator = $(if ($Version) { 'greaterThanOrEqual' } else { 'notConfigured' }); Reg_DetectionValue = [string]$Version }
}

# ---------------------------------------------------------------- convenience: profiles, installed apps, sandbox tests, lists

function Global:ConvertTo-AssignmentProfiles {
    # Pure: assignment profiles from settings or the page - at most 30, each with a name and at least one group; groups trimmed and unique.
    param($Raw)
    $clean = { param($l) @(@($l) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique) }
    return @(@($Raw) | Where-Object { $_ -and ([string]$_.Name).Trim() } | ForEach-Object {
            [ordered]@{ Name = ([string]$_.Name).Trim().Substring(0, [Math]::Min(([string]$_.Name).Trim().Length, 60)); Required = (& $clean $_.Required); Available = (& $clean $_.Available); Exclude = (& $clean $_.Exclude) }
        } | Where-Object { ($_.Required.Count + $_.Available.Count + $_.Exclude.Count) -gt 0 } | Select-Object -First 30)
}

function Global:ConvertTo-DetectionFromInstalled {
    <#
      Pure: a detection rule for an app as Windows lists it (an Uninstall
      key: Key = its name, WindowsInstaller, DisplayVersion, InstallLocation,
      DisplayIcon; Hive = HKLM / HKLM-WOW / HKCU; MainExe = the program's
      file and its version, when found). An MSI: its product code, this
      version or newer. Otherwise the program's file by version, or the
      Uninstall key's DisplayVersion. @{ Rule; Text }.
    #>
    param($Entry)
    $ver = ([string]$Entry.DisplayVersion).Trim()
    if ([string]$Entry.Key -match '^\{[0-9A-Fa-f-]{36}\}$' -and [int]$Entry.WindowsInstaller -eq 1) {
        return @{ Rule = [ordered]@{ Type = 'Msi'; Msi_ProductCode = ([string]$Entry.Key).ToUpperInvariant(); Msi_VersionOperator = $(if ($ver) { 'greaterThanOrEqual' } else { 'notConfigured' }); Msi_Version = $ver }; Text = "MSI product code $(([string]$Entry.Key).ToUpperInvariant())$(if ($ver) { ", $ver or newer" })" }
    }
    if ($Entry.MainExe -and $Entry.MainExe.Path -and $Entry.MainExe.Version) {
        $p = [string]$Entry.MainExe.Path
        # A Windows path, split by hand (the System.IO helpers don't know "\" off Windows).
        $cut = $p.LastIndexOf('\')
        $file = $p.Substring($cut + 1)
        $folder = $p.Substring(0, [Math]::Max($cut, 0)) -replace '^C:\\Program Files \(x86\)', '%ProgramFiles(x86)%' -replace '^C:\\Program Files', '%ProgramFiles%'
        return @{ Rule = [ordered]@{ Type = 'File'; File_Path = $folder; File_Name = $file; File_Check32Bit = $false; File_DetectionType = 'version'; File_Operator = 'greaterThanOrEqual'; File_DetectionValue = [string]$Entry.MainExe.Version }; Text = "$file in $folder, version $($Entry.MainExe.Version) or newer" }
    }
    $root = switch ([string]$Entry.Hive) { 'HKCU' { 'HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' } 'HKLM-WOW' { 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' } default { 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' } }
    $key = "$root\$($Entry.Key)"
    return @{ Rule = [ordered]@{ Type = 'Registry'; Reg_KeyPath = $key; Reg_ValueName = 'DisplayVersion'; Reg_Check32Bit = ([string]$Entry.Hive -eq 'HKLM-WOW'); Reg_DetectionType = $(if ($ver) { 'version' } else { 'exists' }); Reg_Operator = $(if ($ver) { 'greaterThanOrEqual' } else { 'notConfigured' }); Reg_DetectionValue = $ver }; Text = "the Uninstall key $($Entry.Key)$(if ($ver) { ", DisplayVersion $ver or newer" })" }
}

function Global:ConvertTo-DetectionTestScript {
    <#
      Pure: PowerShell that says whether -Rule detects the app here - for a
      test in Windows Sandbox. Writes $true or $false.
    #>
    param($Rule)
    $q = { param($s) ConvertTo-PsLiteral $s }
    $cmp = { param($have, $op, $want) "`$ok = `$false; try { `$h = [version](($have) -replace '[^0-9.].*$', ''); `$w = [version]($(& $q $want) -replace '[^0-9.].*$', ''); `$ok = switch ($(& $q $op)) { 'equal' { `$h -eq `$w } 'notEqual' { `$h -ne `$w } 'greaterThan' { `$h -gt `$w } 'greaterThanOrEqual' { `$h -ge `$w } 'lessThan' { `$h -lt `$w } 'lessThanOrEqual' { `$h -le `$w } default { `$true } } } catch { `$ok = (($have) -eq $(& $q $want)) }; `$ok" }
    # In parentheses: as a command argument, [Environment]::... would be passed as text.
    $expand = { param($p) "([Environment]::ExpandEnvironmentVariables($(& $q $p)))" }
    switch ([string]$Rule.Type) {
        'Msi' {
            $code = [string]$Rule.Msi_ProductCode
            $find = "`$e = @(Get-ItemProperty -Path ('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + $(& $q $code)), ('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\' + $(& $q $code)) -ErrorAction SilentlyContinue) | Select-Object -First 1"
            if ([string]$Rule.Msi_VersionOperator -in '', 'notConfigured') { return "$find; [bool]`$e" }
            return "$find; if (-not `$e) { `$false } else { $(& $cmp '[string]$e.DisplayVersion' $Rule.Msi_VersionOperator $Rule.Msi_Version) }"
        }
        'File' {
            $path = "(Join-Path $(& $expand $Rule.File_Path) $(& $q $Rule.File_Name))"
            switch ([string]$Rule.File_DetectionType) {
                'doesNotExist' { return "-not (Test-Path -LiteralPath $path)" }
                'version' { return "`$f = $path; if (-not (Test-Path -LiteralPath `$f)) { `$false } else { $(& $cmp '[string](Get-Item -LiteralPath $f).VersionInfo.FileVersion' $Rule.File_Operator $Rule.File_DetectionValue) }" }
                default { return "Test-Path -LiteralPath $path" }
            }
        }
        'Registry' {
            $k = 'Registry::' + ([string]$Rule.Reg_KeyPath)
            $name = [string]$Rule.Reg_ValueName
            switch ([string]$Rule.Reg_DetectionType) {
                'doesNotExist' { return "-not (Test-Path -LiteralPath $(& $q $k))" }
                'exists' { if ($name) { return "`$null -ne (Get-ItemProperty -LiteralPath $(& $q $k) -Name $(& $q $name) -ErrorAction SilentlyContinue)" }; return "Test-Path -LiteralPath $(& $q $k)" }
                'version' { return "`$v = (Get-ItemProperty -LiteralPath $(& $q $k) -Name $(& $q $name) -ErrorAction SilentlyContinue).PSObject.Properties[$(& $q $name)].Value; if (-not `$v) { `$false } else { $(& $cmp '[string]$v' $Rule.Reg_Operator $Rule.Reg_DetectionValue) }" }
                default { return "`$v = (Get-ItemProperty -LiteralPath $(& $q $k) -Name $(& $q $name) -ErrorAction SilentlyContinue).PSObject.Properties[$(& $q $name)].Value; [string]`$v -eq $(& $q $Rule.Reg_DetectionValue)" }
            }
        }
        'Script' { return "`$out = & { $([string]$Rule.Script_Content) } 2>`$null; [bool](@(`$out) | Where-Object { `$_ })" }
    }
    return '$false'
}

function Global:ConvertFrom-WingetExportJson {
    # Pure: the package IDs in a "winget export" file (Sources[].Packages[].PackageIdentifier), each once.
    param([string]$Json)
    try { $o = $Json | ConvertFrom-Json } catch { return @{ Ids = @(); Error = "That isn't a winget export file (JSON)." } }
    $ids = @(@($o.Sources) | ForEach-Object { @($_.Packages) } | ForEach-Object { [string]$_.PackageIdentifier } | Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9.\-_+]{0,127}$' } | Select-Object -Unique)
    if (-not $ids.Count) { return @{ Ids = @(); Error = 'No winget package in that file - make it with "winget export -o apps.json".' } }
    return @{ Ids = $ids; Error = '' }
}


function Global:Get-AppUpdateOffer {
    # Pure: whether a GitHub release (tag "vX.Y.Z", its notes) is newer than -Current - @{ Newer; Version; Notes (the first lines, as plain text) }.
    param([string]$Current, [string]$Tag, [string]$Body)
    $v = ([string]$Tag).Trim() -replace '^[vV]', ''
    if ($v -notmatch '^\d+(\.\d+){1,3}$') { return @{ Newer = $false; Version = ''; Notes = '' } }
    $newer = (Compare-AppVersionText $Current $v) -eq 1
    $notes = @(([string]$Body -split "`r?`n") | ForEach-Object { ($_ -replace '[#*`>\[\]]', '').Trim() } | Where-Object { $_ } | Select-Object -First 6) -join ' / '
    if ($notes.Length -gt 400) { $notes = $notes.Substring(0, 400) + '...' }
    return @{ Newer = [bool]$newer; Version = $v; Notes = $notes }
}


function Global:Test-StoreProductId {
    # Pure: is -Id a Microsoft Store product ID ("9N..." 12 or "XP..." 14 letters and digits) - winget's msstore source, Intune's "Microsoft Store app (new)"?
    param([string]$Id)
    return [bool]([string]$Id -cmatch '^(9[0-9A-Z]{11}|XP[0-9A-Z]{12})$')
}

function Global:Get-PermissionReport {
    <#
      Pure: the Graph application permissions the app registration has
      (-Granted) against what this app uses, by feature (-Usage: Scripts,
      Inventory, Mail, GroupsPage as booleans). Rows @{ name; status = ok |
      missing | partly | unused | optional; for; why }: missing and partly are
      to add; unused is granted but not needed - removing it shrinks what the
      certificate can do.
    #>
    param([string[]]$Granted, $Usage)
    $g = @($Granted | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $has = { param($n) $g -contains $n }
    $rows = New-Object System.Collections.Generic.List[object]
    $row = { param($name, $status, $for, $why) $rows.Add([ordered]@{ name = $name; status = $status; for = $for; why = $why }) }
    & $row 'DeviceManagementApps.ReadWrite.All' $(if (& $has 'DeviceManagementApps.ReadWrite.All') { 'ok' } else { 'missing' }) 'Apps: send to Intune, assign, release, install status' 'Everything about apps needs it.'
    if (& $has 'Group.ReadWrite.All') { & $row 'Group.ReadWrite.All' 'ok' 'Groups: create missing ones, rename, members' '' }
    elseif (& $has 'Group.Read.All') { & $row 'Group.ReadWrite.All' 'partly' 'Groups: create missing ones, rename, members' 'Group.Read.All finds groups, but missing groups can''t be created and the Groups page can''t change them.' }
    else { & $row 'Group.ReadWrite.All' 'missing' 'Groups: find, create, rename' 'Assignments name groups - they are looked up and created with it.' }
    $feat = @(
        @('DeviceManagementScripts.ReadWrite.All', [bool]$Usage.Scripts, 'Platform scripts', 'There are platform scripts in the scripts folder.'),
        @('DeviceManagementManagedDevices.Read.All', [bool]$Usage.Inventory, 'Apps on devices: older versions, apps worth adding', 'Apps have managed updates - the Updates page reads the inventory.'),
        @('Mail.Send', [bool]$Usage.Mail, 'Email alerts from the nightly run', 'Email alerts are set up.'),
        @('User.Read.All', [bool]$Usage.GroupsPage, 'The Groups page: finding users to add as members', 'The Groups page adds users to groups.'),
        @('DeviceManagementConfiguration.Read.All', [bool]$Usage.Filters, 'Assignment filters', 'Apps have an assignment filter - it is looked up by name.')
    )
    foreach ($f in $feat) {
        # A ReadWrite permission covers its Read.All.
        $isGranted = (& $has $f[0]) -or ($f[0] -match '\.Read\.All$' -and (& $has ($f[0] -replace '\.Read\.All$', '.ReadWrite.All')))
        if ($f[1]) { & $row $f[0] $(if ($isGranted) { 'ok' } else { 'missing' }) $f[2] $f[3] }
        elseif ($isGranted) { & $row $f[0] 'unused' $f[2] $(if ($f[0] -eq 'Mail.Send') { 'No email alerts are set up - and Mail.Send can send as any mailbox: remove it, or limit it with an application access policy.' } else { 'Nothing here uses it yet.' }) }
        else { & $row $f[0] 'optional' $f[2] 'Only when you use it.' }
    }
    $known = @('DeviceManagementApps.ReadWrite.All', 'Group.ReadWrite.All', 'Group.Read.All', 'DeviceManagementScripts.ReadWrite.All', 'DeviceManagementManagedDevices.Read.All', 'Mail.Send', 'User.Read.All', 'DeviceManagementConfiguration.Read.All')
    # ReadWrite stands in for Read.All when filters are used; otherwise it's a broad one never needed (below).
    if ($Usage.Filters -and -not (& $has 'DeviceManagementConfiguration.Read.All')) { $known += 'DeviceManagementConfiguration.ReadWrite.All' }
    if ($Usage.Inventory -and -not (& $has 'DeviceManagementManagedDevices.Read.All')) { $known += 'DeviceManagementManagedDevices.ReadWrite.All' }
    if ((& $has 'Group.Read.All') -and (& $has 'Group.ReadWrite.All')) { & $row 'Group.Read.All' 'unused' 'Reading groups' 'Group.ReadWrite.All covers it.' }
    $broad = '^(Directory\.ReadWrite\.All|Application\.ReadWrite\.All|AppRoleAssignment\.ReadWrite\.All|RoleManagement\.ReadWrite\.Directory|DeviceManagementConfiguration\.ReadWrite\.All|DeviceManagementRBAC\.ReadWrite\.All|Sites\.FullControl\.All|Mail\.ReadWrite|Files\.ReadWrite\.All|User\.ReadWrite\.All)$'
    foreach ($p in @($g | Where-Object { $known -notcontains $_ } | Sort-Object)) {
        & $row $p 'unused' 'Not used by this app' $(if ($p -match $broad) { 'A broad permission this app never needs - remove it: the certificate could otherwise change far more than apps.' } elseif ($p -in 'Directory.Read.All', 'Device.Read.All') { 'User.Read.All and Group.ReadWrite.All cover what this app reads.' } else { 'Not used by this app.' })
    }
    # One row per pipeline object (callers wrap it in @()); there's always at least the apps row.
    return $rows.ToArray()
}

function Global:Set-PsadtTemplateValues {
    <#
      Pure: a PSADT 4 Invoke-AppDeployToolkit.ps1 with this app filled in -
      AppVendor, AppName, AppVersion in $adtSession, and the version marker
      (the detection rule's) written after the install and removed after the
      uninstall, at the template's "Perform Post-Installation /
      Post-Uninstallation tasks here" lines. @{ Text; Filled = @(...); Missing = @(...) }.
    #>
    param([string]$Text, [string]$Name, [string]$Vendor, [string]$Version)
    $filled = New-Object System.Collections.Generic.List[string]; $missing = New-Object System.Collections.Generic.List[string]
    $t = [string]$Text
    foreach ($pair in @(@('AppVendor', $Vendor), @('AppName', $Name), @('AppVersion', $Version))) {
        $rx = '(?m)^(\s*' + $pair[0] + '\s*=\s*)''[^''\r\n]*'''
        if ($t -match $rx) { $lit = (ConvertTo-PsLiteral $pair[1]).Replace('$', '$$'); $t = ([regex]$rx).Replace($t, ('${1}' + $lit), 1); $filled.Add($pair[0]) } else { $missing.Add($pair[0]) }
    }
    $key = ConvertTo-PsLiteral ("HKLM:\SOFTWARE\IntuneAppCatalog\Apps\" + ([string]$Name -replace '[\\/]', '-'))
    $ver = ConvertTo-PsLiteral $Version
    $add = "`r`n    ## The version marker Intune's detection rule reads (added by Intune App Catalog) - keep it.`r`n    New-Item -Path $key -Force | Out-Null`r`n    Set-ItemProperty -LiteralPath $key -Name Version -Value $ver`r`n"
    $remove = "`r`n    ## The version marker (added by Intune App Catalog).`r`n    Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue`r`n"
    $rxIn = '(?m)^(\s*## <Perform Post-Installation tasks here>[^\r\n]*)'
    if ($t -match $rxIn) { $t = ([regex]$rxIn).Replace($t, ('${1}' + $add.Replace('$', '$$')), 1); $filled.Add('marker after install') } else { $missing.Add('marker after install') }
    $rxUn = '(?m)^(\s*## <Perform Post-Uninstallation tasks here>[^\r\n]*)'
    if ($t -match $rxUn) { $t = ([regex]$rxUn).Replace($t, ('${1}' + $remove.Replace('$', '$$')), 1); $filled.Add('marker after uninstall') } else { $missing.Add('marker after uninstall') }
    return @{ Text = $t; Filled = $filled.ToArray(); Missing = $missing.ToArray() }
}

function Global:Get-InstallErrorInfo {
    <#
      Pure: what an install error code from Intune's install status report
      means and what usually fixes it - @{ hex; meaning; fix }, $null for no
      error. The code as the report gives it (decimal, signed or not) or as
      hex ("0x87D1041C"). Codes it doesn't know get the general reading of
      their family (a Windows / Windows Installer error, an Intune agent
      error) and the hex to search for.
    #>
    param($Code)
    $text = ([string]$Code).Trim()
    if (-not $text) { return $null }
    $n = 0L
    if ($text -match '^0x([0-9A-Fa-f]{1,8})') { $n = [Convert]::ToInt64($Matches[1], 16) }
    elseif ($text -match '^(-?\d+)') { $n = [long]$Matches[1] } else { return $null }
    $u = [uint32]($n -band 0xFFFFFFFFL)
    if ($u -eq 0) { return $null }
    $hex = '0x{0:X8}' -f $u
    $known = @{
        '0x87D1041C' = @('The installer finished, but the app wasn''t detected afterwards.', 'The detection rule doesn''t match what the installer leaves behind: check the rule (path, registry key, MSI product code, version marker) - for a newer version, the version it checks for.')
        '0x80070643' = @('The installer failed (Windows Installer error 1603, a fatal error during installation).', 'Usually something the installer needs: a prerequisite, a running copy of the app, or a path SYSTEM can''t reach. Install it by hand as SYSTEM (psexec -s) with logging (/l*v) to see why.')
        '0x80070652' = @('Another installation was already running (Windows Installer error 1618).', 'Intune tries again by itself. If it keeps happening, add 1618 as a Retry return code.')
        '0x80070666' = @('Another version of the product is already installed (Windows Installer error 1638).', 'Uninstall the old version first: supersede it with this app (uninstall the previous one), or add the old version''s uninstall to the install script.')
        '0x80070667' = @('The installer''s command line is invalid (Windows Installer error 1639).', 'Check the install command''s switches and quoting.')
        '0x80070642' = @('The installation was cancelled (Windows Installer error 1602).', 'Someone cancelled it, or the installer showed a prompt. Make the install command silent (/qn, /S) and run it as SYSTEM.')
        '0x80070641' = @('The Windows Installer service couldn''t be reached (error 1601).', 'Usually passes on the next try; repeated, the device''s Windows Installer needs repair.')
        '0x80070645' = @('This only works for an installed product (Windows Installer error 1605).', 'Typically an uninstall of something that isn''t there - check the uninstall command''s product code.')
        '0x8007064C' = @('The installer''s source isn''t available (Windows Installer error 1612).', 'The installer needs files that aren''t in the package - put them into the app''s package folder and rebuild it.')
        '0x80070BC2' = @('Installed, but a restart is needed (exit code 3010).', 'Not a real failure: add 3010 as a Soft reboot return code so Intune reports it as success.')
        '0x80070BC9' = @('Installed, but a restart is needed to finish (exit code 3017).', 'Add 3017 as a Soft reboot return code, or let the device restart.')
        '0x80070002' = @('A file wasn''t found (Windows error 2).', 'The install command names a file that isn''t in the package (or the wrong path) - check it against the package folder, and rebuild the package.')
        '0x80070003' = @('A path wasn''t found (Windows error 3).', 'The install command uses a folder that doesn''t exist on the device - check paths and quoting.')
        '0x80070005' = @('Access denied (Windows error 5).', 'The install ran without the rights it needs: install for the system, not the user, or check that nothing (antivirus, policies) blocks it.')
        '0x800705B4' = @('The installation timed out.', 'The installer took longer than the maximum install time - often a hidden prompt waiting for an answer. Make it silent, or raise the install time in the app''s deploy settings.')
        '0x80072329' = @('winget wasn''t on the device (exit code 9009) - usually a new device still setting up (Autopilot).', 'Nothing to do: the install command waits for winget up to 5 minutes and Intune tries again later (9009 is a Retry return code). If it stays, check that App Installer is on the device.')
        '0x80070001' = @('The installer returned 1 (incorrect function / generic failure).', 'Exit code 1 is the installer''s own "failed" - run it by hand as SYSTEM to see why; for scripts, check the script''s errors.')
    }
    if ($known.ContainsKey($hex)) { return [ordered]@{ hex = $hex; meaning = $known[$hex][0]; fix = $known[$hex][1] } }
    if (($u -band 0xFFFF0000L) -eq 0x80070000L) {
        $w = [int]($u -band 0xFFFF)
        if ($w -ge 1600 -and $w -le 1650) { return [ordered]@{ hex = $hex; meaning = "Windows Installer error $w."; fix = "Look up MSI error $w; run the installer by hand as SYSTEM with logging (/l*v) to see the cause." } }
        return [ordered]@{ hex = $hex; meaning = "Windows error $w (or exit code $w from the installer)."; fix = "Search for $hex; if it is the installer's own exit code, its vendor documents it - add it to the return codes if it means success." }
    }
    if (($u -band 0xFFF00000L) -eq 0x87D00000L) { return [ordered]@{ hex = $hex; meaning = 'An error of the Intune Management Extension (the agent that installs Win32 apps).'; fix = "Search for $hex; the device's IntuneManagementExtension.log has the details." } }
    if ($u -eq 9009) { return [ordered]@{ hex = $hex; meaning = $known['0x80072329'][0]; fix = $known['0x80072329'][1] } }
    if ($u -lt 0x10000L) { return [ordered]@{ hex = $hex; meaning = "The installer exited with $u."; fix = "An exit code Intune doesn't know as success: the installer's documentation says what $u means - add it to the return codes if it means success." } }
    return [ordered]@{ hex = $hex; meaning = 'An error Intune reported.'; fix = "Search for $hex." }
}

function Global:Get-InstallErrorTop {
    <#
      Pure: the most common install errors in an install status report's
      rows (each with ErrorCode), most frequent first -
      @(@{ hex; count; meaning; fix }), at most -Top.
    #>
    param($Rows, [int]$Top = 5)
    $byHex = @{}
    foreach ($r in @($Rows)) {
        if (-not $r) { continue }
        $code = if ($r -is [System.Collections.IDictionary]) { $r['ErrorCode'] } else { $r.ErrorCode }
        # The report's ErrorCode can come formatted ("0x87D1041C (-2016345060)") - the hex is first.
        $info = Get-InstallErrorInfo $code
        if (-not $info) { continue }
        if (-not $byHex.ContainsKey($info.hex)) { $byHex[$info.hex] = [ordered]@{ hex = $info.hex; count = 0; meaning = $info.meaning; fix = $info.fix } }
        $byHex[$info.hex].count++
    }
    return @($byHex.Values | Sort-Object @{ Expression = { $_.count }; Descending = $true }, @{ Expression = { $_.hex } } | Select-Object -First $Top)
}

function Global:Get-AppRecordFieldValues {
    <#
      Pure: an app record's fields as field -> compact JSON, for the change
      history: 'metadata.<name>' for each Intune detail, the icon only as a
      fingerprint (an image isn't history text).
    #>
    param($Record)
    $out = [ordered]@{}
    if (-not $Record) { return $out }
    $pairs = if ($Record -is [System.Collections.IDictionary]) { @($Record.Keys | ForEach-Object { @{ Name = [string]$_; Value = $Record[$_] } }) } else { @($Record.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } }) }
    foreach ($p in $pairs) {
        if ($p.Name -eq 'metadata') {
            $m = $p.Value
            if ($m) {
                $mp = if ($m -is [System.Collections.IDictionary]) { @($m.Keys | ForEach-Object { @{ Name = [string]$_; Value = $m[$_] } }) } else { @($m.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } }) }
                foreach ($q in $mp) { $j = ConvertTo-Json -InputObject $q.Value -Compress -Depth 12; $out["metadata.$($q.Name)"] = $(if ($j) { [string]$j } else { 'null' }) }
            }
            continue
        }
        if ($p.Name -eq 'icon') {
            $v = if ($p.Value) { [string]$p.Value.value } else { '' }
            $out['icon'] = $(if ($v) { $sha = [System.Security.Cryptography.SHA256]::Create(); try { '"image ' + ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($v)), 0, 6) -replace '-', '') + '"' } finally { $sha.Dispose() } } else { 'null' })
            continue
        }
        # Windows PowerShell's ConvertTo-Json gives nothing for $null - 'null', as everywhere else.
        $j = ConvertTo-Json -InputObject $p.Value -Compress -Depth 12
        $out[$p.Name] = $(if ($j) { [string]$j } else { 'null' })
    }
    return $out
}

function Global:Get-AppRecordChanges {
    # Pure: the fields that differ between two versions of an app record, @(@{ field; before; after }) with the values as compact JSON.
    param($Before, $After)
    $a = Get-AppRecordFieldValues $Before; $b = Get-AppRecordFieldValues $After
    # '' too: Windows PowerShell's ConvertTo-Json gives nothing at all for $null.
    $empty = @('null', '""', '[]', '')
    $keys = @(@($a.Keys) + @($b.Keys) | Select-Object -Unique)
    return @(foreach ($k in $keys) {
        $x = if ($a.Contains($k)) { [string]$a[$k] } else { 'null' }
        $y = if ($b.Contains($k)) { [string]$b[$k] } else { 'null' }
        # Missing, null, empty text and an empty list all mean "not set" - not a change.
        if ($x -cne $y -and -not ($empty -contains $x -and $empty -contains $y)) { [ordered]@{ field = $k; before = $x; after = $y } }
    })
}

function Global:Test-AppRecordFieldRevertable {
    # Pure: whether the history can put a field back by itself - not the name (a rename), the icon, nor what ties the app to Intune.
    param([string]$Field)
    # Not the commands and detection rule either: they run as SYSTEM on devices, and the history is a file in the Backups
    # folder - those come back only with a whole earlier version (Earlier versions shows the file in full).
    return -not ($Field -in 'appName', 'icon', 'appId', 'intuneAppType', 'intuneAppVersion', 'releases', 'packagePath', 'metadata.installCommand', 'metadata.uninstallCommand', 'metadata.detectionRule')
}

function Global:Set-AppRecordFieldJson {
    <#
      Sets one field of an app record (as Get-AppRecordFieldValues names it)
      from compact JSON. $false for one the history doesn't put back.
    #>
    param($Record, [string]$Field, [string]$Json)
    if (-not (Test-AppRecordFieldRevertable $Field)) { return $false }
    $t = ([string]$Json).Trim()
    # Assigned in each branch, not as "$value = if ...": that goes through the
    # pipeline, which turns a one-item list into the item and an empty one into $null.
    $value = $null
    if ($t -eq '[]') { $value = @() }
    elseif ($t.StartsWith('"')) { $value = [regex]::Unescape($t.Substring(1, $t.Length - 2)) }
    # Piped, so the list is enumerated - Windows PowerShell's ConvertFrom-Json hands a JSON list over as one object.
    elseif ($t.StartsWith('[')) { $parsed = ConvertFrom-Json -InputObject $t; $value = @($parsed | ForEach-Object { $_ }) }
    elseif ($t -and $t -ne 'null') { $value = ConvertFrom-Json -InputObject $t }
    $target = $Record; $name = $Field
    if ($Field -like 'metadata.*') {
        $name = $Field.Substring(9)
        $target = if ($Record -is [System.Collections.IDictionary]) { $Record['metadata'] } else { $Record.metadata }
        if (-not $target) { return $false }
    }
    if ($target -is [System.Collections.IDictionary]) { $target[$name] = $value }
    elseif ($target.PSObject.Properties[$name]) { $target.$name = $value }
    else { $target | Add-Member -NotePropertyName $name -NotePropertyValue $value }
    return $true
}

function Global:ConvertTo-SandboxResult {
    <#
      Pure (2.36.0): a Sandbox test's result.json as pasted or uploaded - only the fields a test writes, each of
      its type (exit codes as numbers, the found apps as short text, at most 10) - or $null when it isn't one.
    #>
    param([string]$Text)
    if (-not $Text -or $Text.Length -gt 65536) { return $null }
    try { $j = $Text.Trim([char]0xFEFF).Trim() | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if (-not $j -or $j -is [array] -or $null -eq $j.installExit) { return $null }
    $int = { param($v) $n = 0L; if ([long]::TryParse([string]$v, [ref]$n) -and $n -ge [int]::MinValue -and $n -le [uint32]::MaxValue) { [long]$n } else { $null } }
    $ie = & $int $j.installExit
    if ($null -eq $ie) { return $null }
    $short = { param($v) $t = ([string]$v -replace '[\x00-\x1F]', '').Trim(); if ($t.Length -gt 256) { $t.Substring(0, 256) } else { $t } }
    $found = @(@($j.installed) | Where-Object { $_ -and $_.name } | Select-Object -First 10 | ForEach-Object { [ordered]@{ name = (& $short $_.name); version = (& $short $_.version); publisher = (& $short $_.publisher) } } | Where-Object { $_.name })
    return [ordered]@{
        before = [bool]$j.before; installExit = $ie; detectedAfterInstall = [bool]$j.detectedAfterInstall
        uninstallExit = $(if ($null -ne $j.uninstallExit) { & $int $j.uninstallExit } else { $null }); detectedAfterUninstall = [bool]$j.detectedAfterUninstall
        installed = $found
    }
}

function Global:Get-StarterAppSet {
    <#
      Pure (2.38.0): a starter set of Winget apps most organisations deploy, by category - the recommended ones
      ticked by default (browsers, 7-Zip, a PDF reader, a text editor, VLC, Java and the Visual C++ runtime);
      the others common choices for some. Every ID was checked against winget's index when it was written.
      Java is Eclipse Temurin (no Oracle licence needed); Chrome is Google's enterprise MSI.
    #>
    return @(
        [ordered]@{ id = 'Mozilla.Firefox'; name = 'Mozilla Firefox'; category = 'Browsers'; recommended = $true; why = 'A second browser beside Edge - many sites and admins expect one.' },
        [ordered]@{ id = 'Google.Chrome'; name = 'Google Chrome'; category = 'Browsers'; recommended = $true; why = 'Chrome''s enterprise MSI - installs for all users, managed by policy.' },
        [ordered]@{ id = 'Mozilla.Firefox.ESR'; name = 'Mozilla Firefox ESR'; category = 'Browsers'; recommended = $false; why = 'Instead of Firefox: a release a year, security fixes only - fewer changes for users.' },
        [ordered]@{ id = '7zip.7zip'; name = '7-Zip'; category = 'Files and documents'; recommended = $true; why = 'Opens .7z, .rar, .tar and more - Windows itself only does .zip well.' },
        [ordered]@{ id = 'Adobe.Acrobat.Reader.64-bit'; name = 'Adobe Acrobat Reader'; category = 'Files and documents'; recommended = $true; why = 'Forms and signatures in PDFs that the browser viewers handle badly.' },
        [ordered]@{ id = 'Notepad++.Notepad++'; name = 'Notepad++'; category = 'Files and documents'; recommended = $true; why = 'A text editor for logs, scripts and config files.' },
        [ordered]@{ id = 'SumatraPDF.SumatraPDF'; name = 'SumatraPDF'; category = 'Files and documents'; recommended = $false; why = 'A small, fast PDF reader - instead of Acrobat where forms are not needed.' },
        [ordered]@{ id = 'TheDocumentFoundation.LibreOffice'; name = 'LibreOffice'; category = 'Files and documents'; recommended = $false; why = 'An office suite where there is no Microsoft 365 licence.' },
        [ordered]@{ id = 'VideoLAN.VLC'; name = 'VLC media player'; category = 'Media'; recommended = $true; why = 'Plays nearly every audio and video format without extra codecs.' },
        [ordered]@{ id = 'dotPDN.PaintDotNet'; name = 'Paint.NET'; category = 'Media'; recommended = $false; why = 'Simple image editing beyond Paint.' },
        [ordered]@{ id = 'Greenshot.Greenshot'; name = 'Greenshot'; category = 'Media'; recommended = $false; why = 'Screenshots with arrows and blur - for support tickets and documentation.' },
        [ordered]@{ id = 'EclipseAdoptium.Temurin.21.JRE'; name = 'Java 21 (Eclipse Temurin JRE)'; category = 'Runtimes'; recommended = $true; why = 'Java without an Oracle licence: the current long-term version, for Java apps.' },
        [ordered]@{ id = 'EclipseAdoptium.Temurin.17.JRE'; name = 'Java 17 (Eclipse Temurin JRE)'; category = 'Runtimes'; recommended = $false; why = 'The previous long-term Java - for apps not yet certified on 21.' },
        [ordered]@{ id = 'EclipseAdoptium.Temurin.8.JRE'; name = 'Java 8 (Eclipse Temurin JRE)'; category = 'Runtimes'; recommended = $false; why = 'Only for old apps that need Java 8.' },
        [ordered]@{ id = 'Microsoft.VCRedist.2015+.x64'; name = 'Visual C++ Redistributable (x64)'; category = 'Runtimes'; recommended = $true; why = 'Needed by many desktop apps - better installed once than by each app.' },
        [ordered]@{ id = 'Microsoft.VCRedist.2015+.x86'; name = 'Visual C++ Redistributable (x86)'; category = 'Runtimes'; recommended = $false; why = 'The same for 32-bit apps.' },
        [ordered]@{ id = 'Microsoft.DotNet.DesktopRuntime.8'; name = '.NET 8 Desktop Runtime'; category = 'Runtimes'; recommended = $false; why = 'For apps built on .NET 8 that do not bring it themselves.' },
        [ordered]@{ id = 'Zoom.Zoom'; name = 'Zoom'; category = 'Meetings and remote work'; recommended = $false; why = 'Where customers or partners meet on Zoom.' },
        [ordered]@{ id = 'Cisco.Webex'; name = 'Webex'; category = 'Meetings and remote work'; recommended = $false; why = 'Where meetings run on Webex.' },
        [ordered]@{ id = 'Citrix.Workspace'; name = 'Citrix Workspace'; category = 'Meetings and remote work'; recommended = $false; why = 'For Citrix virtual apps and desktops.' },
        [ordered]@{ id = 'KeePassXCTeam.KeePassXC'; name = 'KeePassXC'; category = 'Meetings and remote work'; recommended = $false; why = 'A local password manager, where no company one is in use.' },
        [ordered]@{ id = 'Microsoft.PowerShell'; name = 'PowerShell 7'; category = 'IT and developers'; recommended = $false; why = 'The current PowerShell, beside Windows PowerShell 5.1.' },
        [ordered]@{ id = 'Microsoft.PowerToys'; name = 'PowerToys'; category = 'IT and developers'; recommended = $false; why = 'Window layouts, quick launcher, file tools - for power users.' },
        [ordered]@{ id = 'Microsoft.VisualStudioCode'; name = 'Visual Studio Code'; category = 'IT and developers'; recommended = $false; why = 'A code editor - for IT and developers.' },
        [ordered]@{ id = 'Git.Git'; name = 'Git'; category = 'IT and developers'; recommended = $false; why = 'Version control - for IT and developers.' },
        [ordered]@{ id = 'WinMerge.WinMerge'; name = 'WinMerge'; category = 'IT and developers'; recommended = $false; why = 'Compares files and folders.' },
        [ordered]@{ id = 'PuTTY.PuTTY'; name = 'PuTTY'; category = 'IT and developers'; recommended = $false; why = 'SSH and serial connections to network devices.' },
        [ordered]@{ id = 'WinSCP.WinSCP'; name = 'WinSCP'; category = 'IT and developers'; recommended = $false; why = 'Copies files over SFTP and SCP.' }
    )
}

function Global:Get-CommandPackageFiles {
    <#
      Pure: the package's own files a command runs or reads ("setup.exe", "Files\app.msi", TRANSFORMS=x.mst,
      -File Install.ps1) - not Windows' own programs, not a path on the device (C:\..., %ProgramFiles%\...).
    #>
    param([string]$Command)
    $system = @('msiexec.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe', 'wscript.exe', 'cscript.exe', 'rundll32.exe', 'reg.exe', 'regsvr32.exe', 'conhost.exe', 'start.exe', 'sc.exe', 'net.exe', 'taskkill.exe', 'dism.exe')
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches([string]$Command, '"([^"]+)"|(\S+)')) {
        $t = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        # A path on the device (C:\..., %ProgramFiles%\..., \\server\...) isn't in the package.
        if ($t -match '^(?i)([a-z]:|%|\\\\|\$env:|\$)') { continue }
        # PROPERTY=value (TRANSFORMS=x.mst), /switch:value - the value.
        $t = ($t -replace '^/?[A-Za-z_][A-Za-z0-9_]*(=|:(?![\\/]))', '').Trim('"', "'", ';', ',')
        if ($t -notmatch '(?i)\.(msi|exe|ps1|cmd|bat|mst|msp|vbs)$') { continue }
        if ($t -match '^(?i)([a-z]:|%|\\\\|\$env:|\$)') { continue }
        $t = $t -replace '^\.[\\/]', '' -replace '/', '\'
        if ($system -contains ($t -split '\\')[-1].ToLowerInvariant()) { continue }
        if (-not $out.Contains($t)) { $out.Add($t) }
    }
    return $out.ToArray()
}

function Global:Get-PackageConsistencyWarnings {
    <#
      Pure (2.36.0): what doesn't fit together in an own package before it is sent - a command naming a file
      the package doesn't have, the chosen setup file gone, the detection rule looking for another product
      code, version or name than the installer's, the App version not the installer's. Warnings, not blockers:
      each can be on purpose. -Files: the folder's files (relative paths); -Installer: @{ file; version;
      productCode; name } (Get-WebInstallerInfo).
    #>
    param($Metadata, [string[]]$Files = @(), $Installer = $null, [string]$SetupFile = '')
    $w = New-Object System.Collections.Generic.List[string]
    if (-not $Metadata) { return @() }
    $have = @{}; foreach ($f in @($Files)) { if ($f) { $p = ([string]$f -replace '/', '\').ToLowerInvariant(); $have[$p] = $true; $have[($p -split '\\')[-1]] = $true } }
    $hasFiles = $have.Count -gt 0
    if ($hasFiles) {
        foreach ($k in 'installCommand', 'uninstallCommand') {
            foreach ($f in @(Get-CommandPackageFiles ([string]$Metadata.$k))) {
                $key = $f.ToLowerInvariant()
                if (-not ($have.ContainsKey($key) -or $have.ContainsKey(($key -split '\\')[-1]))) {
                    $w.Add("The $(if ($k -eq 'installCommand') { 'install' } else { 'uninstall' }) command runs $f, but the package has no such file.")
                }
            }
        }
        if ($SetupFile -and -not $have.ContainsKey(($SetupFile -replace '/', '\').ToLowerInvariant())) { $w.Add("The setup file chosen for it ($SetupFile) isn't in its folder any more.") }
    }
    $rule = $Metadata.detectionRule
    $iv = if ($Installer) { [string]$Installer.version } else { '' }
    $ipc = if ($Installer) { [string]$Installer.productCode } else { '' }
    $iname = if ($Installer) { [string]$Installer.name } else { '' }
    if ($rule -and $rule.Type) {
        $detVer = ''; $op = ''
        switch ([string]$rule.Type) {
            'Msi' {
                if ($ipc -and $rule.Msi_ProductCode -and ([string]$rule.Msi_ProductCode).Trim('{}').ToLowerInvariant() -ne $ipc.Trim('{}').ToLowerInvariant()) {
                    $w.Add("The detection rule looks for product code $($rule.Msi_ProductCode), the installer's is $ipc - it would never be found installed.")
                }
                $detVer = [string]$rule.Msi_Version; $op = [string]$rule.Msi_VersionOperator
            }
            'File' { if ([string]$rule.File_DetectionType -eq 'version') { $detVer = [string]$rule.File_DetectionValue; $op = [string]$rule.File_Operator } }
            'Registry' { if ([string]$rule.Reg_DetectionType -eq 'version') { $detVer = [string]$rule.Reg_DetectionValue; $op = [string]$rule.Reg_Operator } }
            'Script' {
                $sc = [string]$rule.Script_Content
                $m = [regex]::Match($sc, "(?m)\`$want = '((?:[^']|'')*)'")
                if ($m.Success) { $detVer = $m.Groups[1].Value -replace "''", "'"; $op = 'greaterThanOrEqual' }
                # A rule this app wrote (by the name Windows lists): the installer's own name should match it.
                $pm = [regex]::Match($sc, "(?m)^\`$pattern = '((?:[^']|'')*)'")
                if ($pm.Success -and $iname) {
                    $ok = $false; try { $ok = $iname -match ($pm.Groups[1].Value -replace "''", "'") } catch { $ok = $true }
                    if (-not $ok) {
                        $shown = $pm.Groups[1].Value.Replace("''", "'") -replace '^\^', '' -replace '\(\\s\+.*$', ''
                        try { $shown = [regex]::Unescape($shown) } catch { }
                        $w.Add("The detection rule looks for an app listed as '$shown', the installer calls itself '$iname' - a Sandbox test shows the name Windows lists.")
                    }
                }
            }
        }
        # Looking for a newer version than the installer installs: never found, installed again and again.
        if ($detVer -and $iv -and $op -in 'greaterThanOrEqual', 'equal', 'greaterThan' -and (Compare-AppVersionText $iv $detVer) -eq 1) {
            $w.Add("The detection rule looks for version $detVer, the installer is $iv - it would never be found installed.")
        }
    }
    $av = [string]$Metadata.appVersion
    if ($av -and $iv -and (Compare-AppVersionText $av $iv) -ne 0) { $w.Add("The App version is $av, the installer is $iv - Intune and the Company Portal would show the wrong one.") }
    return $w.ToArray()
}

function Global:Format-DetectionRuleText {
    <#
      Pure: a catalog detection rule as one line, as the editor says it - for the history and the comparisons
      (they showed its JSON). "MSI product code {...}, version 26.06 or newer", "File C:\...\7zFM.exe exists", ...
    #>
    param($Rule)
    if (-not $Rule -or -not $Rule.Type) { return '' }
    $op = { param($o) switch ([string]$o) { 'greaterThanOrEqual' { 'or newer' } 'greaterThan' { 'newer than' } 'equal' { 'exactly' } 'lessThan' { 'older than' } 'lessThanOrEqual' { 'or older' } 'notEqual' { 'not' } default { [string]$o } } }
    $ver = { param($o, $v) if (-not $v) { '' } elseif ([string]$o -in 'greaterThanOrEqual', 'lessThanOrEqual') { "$v $(& $op $o)" } else { "$(& $op $o) $v" } }
    $where = { param($a, $b) (@([string]$a, [string]$b) | Where-Object { $_ }) -join '\' }
    switch ([string]$Rule.Type) {
        'Msi' { $v = & $ver $Rule.Msi_VersionOperator $Rule.Msi_Version; return "MSI product code $($Rule.Msi_ProductCode)$(if ($v) { ", version $v" })" }
        'File' {
            $what = & $where $Rule.File_Path $Rule.File_Name
            $how = switch ([string]$Rule.File_DetectionType) { 'version' { "version $(& $ver $Rule.File_Operator $Rule.File_DetectionValue)" } 'exists' { 'exists' } 'doesNotExist' { "doesn't exist" } '' { 'exists' } default { "$($Rule.File_DetectionType) $(& $ver $Rule.File_Operator $Rule.File_DetectionValue)".Trim() } }
            return "File $what, $how$(if ($Rule.File_Check32Bit) { ' (32-bit)' })"
        }
        'Registry' {
            $what = (@([string]$Rule.Reg_KeyPath, [string]$Rule.Reg_ValueName) | Where-Object { $_ }) -join ' : '
            $how = switch ([string]$Rule.Reg_DetectionType) { 'exists' { 'exists' } 'doesNotExist' { "doesn't exist" } '' { 'exists' } default { "$($Rule.Reg_DetectionType) $(& $ver $Rule.Reg_Operator $Rule.Reg_DetectionValue)".Trim() } }
            return "Registry $what, $how$(if ($Rule.Reg_Check32Bit) { ' (32-bit)' })"
        }
        'Script' { $lines = @(([string]$Rule.Script_Content) -split "`r?`n" | Where-Object { $_.Trim() }).Count; return "Script ($lines line$(if ($lines -ne 1) { 's' }))" }
        default { return [string]$Rule.Type }
    }
}

function Global:Format-AppHistoryValue {
    # Pure: a history value (compact JSON) as short text - a list as "a, b", text as itself, '' for not set.
    param([string]$Json, [int]$Max = 300)
    $t = ([string]$Json).Trim()
    $text = if ($t -in 'null', '""', '[]', '') { '' }  # '' - Windows PowerShell's JSON for $null
        elseif ($t.StartsWith('"')) { [regex]::Unescape($t.Substring(1, $t.Length - 2)) }
        elseif ($t.StartsWith('{') -and $t -match '"Type"\s*:') { $d = try { ConvertFrom-Json -InputObject $t } catch { $null }; $(if ($d) { Format-DetectionRuleText $d } else { $t }) }
        elseif ($t.StartsWith('[')) {
            $items = @(try { $parsed = ConvertFrom-Json -InputObject $t; $parsed | ForEach-Object { $_ } } catch { })
            if ($items.Count -and -not @($items | Where-Object { $_ -isnot [string] }).Count) { $items -join ', ' } else { $t }
        }
        else { $t }
    if ($text.Length -gt $Max) { $text = $text.Substring(0, $Max) + '...' }
    return $text
}

function Global:Get-RetireGroups {
    # Pure: the groups an app being retired gets an Uninstall for - every group it was given, minus its exclusions.
    param($App)
    $excluded = @(@($App.excludeFor) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    return @(@(@($App.requiredFor) + @($App.availableFor) + @($App.uninstallFor)) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and $excluded -notcontains $_ } | Select-Object -Unique)
}

function Global:Get-RetireProgress {
    <#
      Pure: how far an app's retirement is, from its install status rows
      (State as the report shows it) - @{ total; still; removed; failed; other; done; text }.
      done: no device reports it installed any more.
    #>
    param($Rows)
    $still = 0; $removed = 0; $failed = 0; $other = 0
    foreach ($r in @($Rows)) {
        if (-not $r) { continue }
        $s = ([string]$r.State).Trim()
        if ($s -match '^installed$') { $still++ }
        # Failed first: "Uninstall failed" is still there.
        elseif ($s -match 'fail|error') { $failed++ }
        elseif ($s -match 'uninstall|not installed|not applicable') { $removed++ }
        else { $other++ }
    }
    $total = $still + $removed + $failed + $other
    $text = if (-not $total) { 'No device reports this app - nothing left to uninstall.' }
        elseif (-not $still -and -not $failed) { "Gone from all $total device(s) that reported it." }
        else { "$still of $total device(s) still have it$(if ($failed) { "; the uninstall failed on $failed" })$(if ($other) { "; $other pending or unknown" })." }
    return [ordered]@{ total = $total; still = $still; removed = $removed; failed = $failed; other = $other; done = [bool](-not $still -and -not $failed); text = $text }
}

function Global:ConvertFrom-WingetInstallerUrl {
    <#
      Pure: the installer link in "winget show" output ('' when there's none).
      winget's labels follow Windows' language ("Installer Url", "Installer-URL",
      ...): a link on a line whose label has "Installer" in it, else one that
      ends like an installer file.
    #>
    param([string]$Text)
    $links = @(foreach ($line in @(([string]$Text) -split "`r?`n")) { if ($line -match '^\s*([^:]*):\s*(https?://\S+)\s*$') { [pscustomobject]@{ Label = $Matches[1]; Url = $Matches[2] } } })
    $byLabel = @($links | Where-Object { $_.Label -match 'install' }) | Select-Object -First 1
    if ($byLabel) { return $byLabel.Url }
    $byFile = @($links | Where-Object { $_.Url -match '\.(exe|msi|msix|msixbundle|appx|appxbundle|zip)(\?|$)' }) | Select-Object -First 1
    if ($byFile) { return $byFile.Url }
    return ''
}

function Global:ConvertFrom-WingetInstallerSha256 {
    # Pure (2.36.0): the installer's SHA256 in "winget show" output ('' when there's none) - on a line whose label has SHA256 in it.
    param([string]$Text)
    foreach ($line in @(([string]$Text) -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*[^:]*SHA-?256[^:]*:\s*([0-9A-Fa-f]{64})\s*$')
        if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() }
    }
    return ''
}

function Global:Get-DownloadCheckVerdict {
    <#
      Pure: whether a pinned version can still be installed by winget on a
      device - @{ status = ok | gone | notinwinget | unknown; text }.
      -InWinget: winget still knows the version; -StatusCode: what its
      installer link answered (0 when it couldn't be asked).
    #>
    param([bool]$InWinget, [int]$StatusCode, [string]$Version, [switch]$NoLink)
    if ($NoLink) { return @{ status = 'unknown'; text = "winget's answer about $Version couldn't be read (no installer link in it)." } }
    if (-not $InWinget) { return @{ status = 'notinwinget'; text = "winget no longer has $Version - devices that don't have it yet can't install it. Release a newer version." } }
    if ($StatusCode -in 200, 206) { return @{ status = 'ok'; text = "$Version can still be downloaded." } }
    if ($StatusCode -in 404, 410) { return @{ status = 'gone'; text = "The vendor removed the $Version download (HTTP $StatusCode) - devices that don't have it yet fail to install it. Release a newer version (fast track for a quick one); if this keeps happening, the vendor only keeps its latest version online." } }
    if ($StatusCode -le 0) { return @{ status = 'unknown'; text = "Couldn't ask for the $Version download (no answer)." } }
    return @{ status = 'unknown'; text = "The $Version download answered HTTP $StatusCode - it may need a browser or be blocked here; devices may still get it." }
}

function Global:Add-WingetRetryReturnCode {
    <#
      Pure: return codes with 9009 = retry added - what a winget install
      command exits with when winget isn't on the device yet (a new device
      still setting up, Autopilot), so Intune tries again later instead of
      reporting a failure. An empty list stands for Intune's defaults, which
      are kept.
    #>
    param($ReturnCodes)
    $list = @(@($ReturnCodes) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ returnCode = [int]$_.returnCode; type = [string]$_.type } })
    if (-not $list.Count) {
        $list = @(@{ c = 0; t = 'success' }, @{ c = 1707; t = 'success' }, @{ c = 3010; t = 'softReboot' }, @{ c = 1641; t = 'hardReboot' }, @{ c = 1618; t = 'retry' }) | ForEach-Object { [pscustomobject]@{ returnCode = $_.c; type = $_.t } }
    }
    if (-not @($list | Where-Object { $_.returnCode -eq 9009 }).Count) { $list = @($list) + [pscustomobject]@{ returnCode = 9009; type = 'retry' } }
    # Never empty, so unrolled is fine - callers wrap it in @().
    return $list
}

function Global:Set-MarkerScriptVersion {
    <#
      Pure: a script app's or PSADT app's script with its version set to
      -Version - the version marker this app writes
      (Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\IntuneAppCatalog\Apps\...' -Name Version -Value '<v>')
      and, in a PSADT script, AppVersion = '<v>'. So the script writes the
      version its detection rule checks for. @{ Text; Changed }.
    #>
    param([string]$Text, [string]$Version)
    $lit = (ConvertTo-PsLiteral $Version).Replace('$', '$$')
    $t = [regex]::Replace([string]$Text, "(?m)(Set-ItemProperty\s+-LiteralPath\s+'HKLM:\\SOFTWARE\\IntuneAppCatalog\\Apps\\(?:[^']|'')*'\s+-Name\s+Version\s+-Value\s+)'(?:[^']|'')*'", ('${1}' + $lit))
    $t = [regex]::Replace($t, "(?m)^(\s*AppVersion\s*=\s*)'(?:[^']|'')*'", ('${1}' + $lit))
    return @{ Text = $t; Changed = ($t -cne [string]$Text) }
}

function Global:Test-ReleasePinned {
    <#
      Pure: why a release's settings don't install and detect -Version ('' when
      they do). A Winget app: its install command pins the version and the
      detection checks it; an own package: its detection rule checks it. Hand-
      edited commands aren't re-pinned (Set-ManagedAppPin) - a release would
      then install the old version and still count as installed.
    #>
    param($Metadata, [string]$Version, [bool]$Winget)
    if (-not $Metadata) { return 'It has no settings to release with.' }
    if ($Winget) {
        if ([string]$Metadata.installCommand -notlike "*--version '$Version'*") { return "Its install command doesn't install $Version (it was edited by hand) - make it the generated one again (editor: clear the install and uninstall commands, or switch managed updates off and on), then release." }
        $d = [string]$(if ($Metadata.detectionRule) { $Metadata.detectionRule.Script_Content })
        if ($d -notlike "*'$Version'*") { return "Its detection doesn't check for $Version - it was edited by hand." }
        return ''
    }
    $r = $Metadata.detectionRule
    $v = switch ([string]$(if ($r) { $r.Type })) { 'Msi' { [string]$r.Msi_Version } 'File' { [string]$r.File_DetectionValue } 'Registry' { [string]$r.Reg_DetectionValue } default { '' } }
    if ($v -ne $Version) { return "Its detection rule doesn't check for $Version - it would count the old version as installed." }
    return ''
}

function Global:Test-ManagedAppEdit {
    <#
      Pure: why an edit to an app with managed updates that is in Intune can't
      be saved ('' when it can). Its version only changes through a release
      (pilot first) - a version typed in would reach everyone on the next send,
      and an own package's detection would check a version its package
      doesn't have. Managed updates can't be switched off while a version is
      in pilot (it would drop off the Updates page, still assigned).
    #>
    param($Existing, $Record)
    if (-not $Existing -or -not $Existing.managedUpdates -or -not $Existing.appId) { return '' }
    $was = [string]$(if ($Existing.metadata) { $Existing.metadata.appVersion }); $now = [string]$(if ($Record.metadata) { $Record.metadata.appVersion })
    if ($was -and $now -ne $was -and $Record.managedUpdates) { return "$($Existing.appName) has managed updates and is in Intune: a new version goes to the pilot groups first - use Release new version (More), not the App version field." }
    if (-not $Record.managedUpdates -and @(@($Existing.releases) | Where-Object { $_ -and $_.state -eq 'pilot' }).Count) { return "A version of $($Existing.appName) is in pilot - promote or withdraw it before switching managed updates off." }
    return ''
}

function Global:Set-AppWingetIdCommands {
    <#
      Pure apart from changing -App: an app whose Winget ID changed from -OldId
      gets its generated install and uninstall commands for the new ID (any
      form: winget, managed with its pinned version, the old WAU form), and its detection
      script's ID too. Commands edited by hand are left alone. Returns whether
      anything changed.
    #>
    param($App, [string]$OldId)
    $m = $App.metadata
    $new = [string]$App.wingetId
    if (-not $m -or -not $OldId -or -not $new -or $OldId -eq $new) { return $false }
    $changed = $false
    $method = Get-AppWingetInstallMethod -WingetId $OldId -InstallCommand ([string]$m.installCommand) -UninstallCommand ([string]$m.uninstallCommand)
    if ($method) {
        $pinned = ''
        if ($method -eq 'Managed' -and [string]$m.installCommand -match " --version '((?:[^']|'')+)'") { $pinned = $Matches[1] -replace "''", "'" }
        # Never written again (2.19): an app on the old WAU form gets the winget command for its new ID.
        if ($method -eq 'WAU') { $method = 'Winget' }
        $c = Get-WingetCommandLines -WingetId $new -Method $method -InstallContext ([string]$m.installContext) -Version $pinned -Options (Get-WingetCommandOptions ([string]$m.installCommand))
        $m.installCommand = $c.Install; $m.uninstallCommand = $c.Uninstall; $changed = $true
    }
    $rule = $m.detectionRule
    if ($rule -and [string]$rule.Type -eq 'Script') {
        $q = "'" + (ConvertTo-PsSingleQuotedContent $OldId) + "'"
        $s = [string]$rule.Script_Content
        if ($s.Contains($q)) { $r = $rule.PSObject.Copy(); $r.Script_Content = $s.Replace($q, "'" + (ConvertTo-PsSingleQuotedContent $new) + "'"); $m.detectionRule = $r; $changed = $true }
    }
    return $changed
}

function Global:Get-NonPackageAppHint {
    <#
      Pure: why an app without a Winget ID needs no package of its own ('' when
      it does need one) - an Intune app type other than Win32 (Store, Microsoft
      365 Apps, ...), or, before it's in Intune, one of Microsoft's apps that
      Intune itself provides: Company Portal (the Store app) and Microsoft 365 Apps.
    #>
    param($App)
    if (([string]$App.wingetId).Trim()) { return '' }
    $t = [string]$App.intuneAppType
    if (-not (Test-PackagedIntuneAppType $t)) { return "$($App.appName) is Intune's own app type ($t) - there's nothing to package." }
    # By name only for an app that has nothing of its own: an install command, a detection rule or a package path
    # means someone packaged it as Win32 (an Office Deployment Tool package, say) - that one is built and sent as usual.
    $m = $App.metadata
    if (($t -and (Test-PackagedIntuneAppType $t)) -or [string]$App.packagePath -or ($m -and ([string]$m.installCommand).Trim() -and $m.detectionRule)) { return '' }
    $n = ([string]$App.appName).Trim()
    if (Test-CompanyPortalName $n) { return "Company Portal is a Microsoft Store app: put 9WZDNCRFJ3PZ in its Winget ID and it's sent as one - nothing to package." }
    if ($n -match '^(Microsoft\s+)?(365|Office)\b|^Microsoft 365 Apps') { return "$n is added in Intune itself (Apps > Windows > Add > Microsoft 365 Apps) - not a package." }
    return ''
}

function Global:Get-ClosestGroupName {
    <#
      Pure: the one name in -Candidates that is -Name written differently -
      other case, spacing, dash kind (- vs an en dash) or & vs "and" - else ''.
    #>
    param([string]$Name, [string[]]$Candidates)
    $norm = { param($s) ((([string]$s).ToLowerInvariant() -replace '[\u2010-\u2015]', '-' -replace '\s*&\s*', ' and ' -replace '[\s_\-]+', ' ')).Trim() }
    $want = & $norm $Name
    $hits = @(@($Candidates) | Where-Object { $_ -and $_ -cne $Name -and (& $norm $_) -eq $want } | Select-Object -Unique)
    if ($hits.Count -eq 1) { return [string]$hits[0] }
    return ''
}


function Global:Test-WauAppName {
    # Pure: whether a catalog app name or Winget ID is Winget-AutoUpdate itself.
    param([string]$Name)
    return ([string]$Name -match '(?i)^\s*(Romanitho\.)?winget[\s\-_.]*auto[\s\-_]*update\s*$')
}

function Global:Test-WauCommandForId {
    <#
      Pure: whether -Command runs Winget-AutoUpdate's Winget-Install.ps1 for
      exactly -WingetId (-AppIDs "Id", 'Id' or Id), in whatever wording -
      another PowerShell path, other quotes, extra switches. WAU is gone
      (2.19), so such a command has nothing left worth keeping; one for
      several IDs or another ID is not this app's and stays.
    #>
    param([string]$WingetId, [string]$Command)
    if (-not $WingetId -or -not $Command) { return $false }
    if ($Command -notmatch '(?i)Winget-Install\.ps1') { return $false }
    $m = [regex]::Match($Command, '(?i)-AppIDs?\s+(?:"([^"]*)"|''([^'']*)''|(\S+))')
    if (-not $m.Success) { return $false }
    $ids = ($m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value).Trim()
    # WAU passes what follows the ID on to winget: "7zip.7zip --scope machine --override /S" is still this app's.
    $parts = @($ids -split '\s+' | Where-Object { $_ })
    if (-not $parts.Count -or $parts[0] -ine $WingetId) { return $false }
    return ($parts.Count -eq 1 -or $parts[1].StartsWith('--'))
}

function Global:Get-WauCommandId {
    <#
      Pure: the one Winget ID a WAU command installs (-AppIDs "Some.App", maybe
      with winget options after it) - '' when it isn't a Winget-Install.ps1
      command, or names several IDs.
    #>
    param([string]$Command)
    if ([string]$Command -notmatch '(?i)Winget-Install\.ps1') { return '' }
    $m = [regex]::Match([string]$Command, '(?i)-AppIDs?\s+(?:"([^"]*)"|''([^'']*)''|(\S+))')
    if (-not $m.Success) { return '' }
    $parts = @((($m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value).Trim()) -split '\s+' | Where-Object { $_ })
    if (-not $parts.Count -or ($parts.Count -gt 1 -and -not $parts[1].StartsWith('--'))) { return '' }
    if ($parts[0] -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-_+]{0,127}$') { return '' }
    return $parts[0]
}

function Global:Get-WauCommandExtras {
    <#
      Pure: the winget options a WAU command passed after the app's ID
      ("--override /S"), which the switch to winget's own command leaves
      out - '' when there are none. --scope machine isn't counted: the
      generated command installs for the machine already (System context).
    #>
    param([string]$Command)
    $m = [regex]::Match([string]$Command, '(?i)-AppIDs?\s+(?:"([^"]*)"|''([^'']*)''|(\S+))')
    if (-not $m.Success) { return '' }
    $ids = ($m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value).Trim()
    $rest = (($ids -split '\s+', 2) | Select-Object -Skip 1) -join ''
    return ([regex]::Replace([string]$rest, '(?i)--scope\s+machine', '') -replace '\s+', ' ').Trim()
}

function Global:Get-WauUse {
    <#
      Pure: how an app still relies on Winget-AutoUpdate, which this catalog
      no longer uses (2.19) - @() when it doesn't. 'commands': its install
      commands run Winget-Install.ps1; 'dependency': it depends on the WAU app.
      WAU itself isn't counted (it's retired, not switched).
    #>
    param($App)
    if ((Test-WauAppName $App.appName) -or (Test-WauAppName $App.wingetId)) { return @() }
    $m = $App.metadata
    $use = @()
    if ($App.wingetId -and $m -and (Get-AppWingetInstallMethod -WingetId $App.wingetId -InstallCommand ([string]$m.installCommand) -UninstallCommand ([string]$m.uninstallCommand)) -eq 'WAU') { $use += 'commands' }
    elseif ($m -and ([string]$m.installCommand) -match '(?i)Winget-AutoUpdate\\Winget-Install\.ps1') { $use += 'commands' }
    if ($m -and @(@($m.dependencies) | Where-Object { Test-WauAppName ([string]$_) }).Count) { $use += 'dependency' }
    return $use
}

function Global:Get-ReleaseAvailableSettings {
    <#
      Pure: settings for the Available assignments of a release that replaces
      an older one - Intune updates the devices that installed the older
      version from Company Portal too (auto-update superseded apps), not only
      the Required groups.
    #>
    return [ordered]@{ '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings'; notifications = 'showAll'
        autoUpdateSettings = [ordered]@{ '@odata.type' = '#microsoft.graph.win32LobAppAutoUpdateSettings'; autoUpdateSupersededAppsState = 'enabled' } }
}

function Global:Test-CompanyPortalName {
    # Pure: whether a catalog name is Intune's Company Portal app.
    param([string]$Name)
    return (([string]$Name).Trim() -match '^(Microsoft\s+|Intune\s+)?Company Portal$')
}

function Global:ConvertFrom-WingetVersionsOutput {
    <#
      Pure: "winget show --id X --exact --versions" as the versions it lists,
      newest first as winget gives them - the lines under the "Version" header
      and its dashes; progress spinners and blank lines left out.
    #>
    param([string]$Text)
    # A spinner overwrites itself with carriage returns: what's left of a line is after its last one.
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ([string]$Text).Split("`n")) {
        $last = ''
        foreach ($part in $raw.Split("`r")) { if ($part.Trim()) { $last = $part.Trim() } }
        if ($last -match '^[\-\\|/]$') { $last = '' }
        $lines.Add($last)
    }
    $start = -1
    # The header is "Version" in English, "Version" with accents, ... in other Windows languages: any one-word line over the dashes.
    for ($i = 0; $i -lt $lines.Count - 1; $i++) { if ($lines[$i] -match '^\S+$' -and $lines[$i] -notmatch '^-+$' -and $lines[$i + 1] -match '^-{3,}$') { $start = $i + 2; break } }
    if ($start -lt 0) { return @() }
    return @($lines[$start..($lines.Count - 1)] | Where-Object { $_ -match '^[0-9A-Za-z][0-9A-Za-z.\-_+]{0,63}$' } | Select-Object -First 100)
}

# ---------------------------------------------------------------- command and detection blocks (2.26)
<#
  The install and uninstall commands and the detection script, as blocks:
  locked ones (what this tool writes the same way for every app - the
  64-bit PowerShell, finding winget, msiexec's silent switches, the frame of
  a detection script) and editable ones (what each app chooses - its MSI
  file and properties, its winget options, the name Windows lists it
  under). The blocks are read from the commands themselves and written
  back to them - the commands stay the one stored truth, so nothing can get
  out of step. A command that isn't one of these forms is the app's own
  ("Own"): kept exactly as it is.
#>

function Global:New-CommandBlock {
    # Pure: one block for the editor. -Kind: lock (fixed), edit (this app's value), link (another field's value), list (name = value pairs), action (opens something).
    param([string]$Id, [string]$Kind, [string]$Label, [string]$Text = '', $Value = $null, [string]$Type = 'text', $Choices = @(), [string]$Link = '', [string]$Help = '', [string]$Part = 'install')
    return [ordered]@{ id = $Id; kind = $Kind; label = $Label; text = $Text; value = $Value; type = $Type; choices = @($Choices); link = $Link; help = $Help; part = $Part }
}

function Global:Get-ExeSilentSwitches {
    # Pure: the silent install switches for an .exe installer's maker (Get-InstallerKind) - '' when unknown.
    param([string]$Kind)
    switch ($Kind) {
        'inno' { return '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }
        'nsis' { return '/S' }
        'burn' { return '/quiet /norestart' }
        'installshield' { return '/s /v"/qn REBOOT=ReallySuppress"' }
        'advanced' { return '/exenoui /qn /norestart' }
    }
    return ''
}

function Global:Get-ScriptCommandFile {
    <#
      Pure: a command that runs a PowerShell script from the package folder - Windows PowerShell (by its full
      path or not, quoted or not) with the usual switches in any order, then -File and a .ps1 file name (with or
      without .\ and quotes) and maybe its own arguments. @{ Runner; File; Args } or $null when it's anything else.
    #>
    param([string]$Command)
    $c = ([string]$Command).Trim()
    $re = '^(?<runner>"?(?:(?:%SystemRoot%|%windir%|[A-Za-z]:\\Windows)\\(?:sysnative|System32|SysWOW64)\\WindowsPowerShell\\v1\.0\\)?powershell(?:\.exe)?"?' +
        '(?:\s+-(?:NoProfile|NonInteractive|NoLogo|Sta|Mta|ExecutionPolicy\s+(?:Bypass|Unrestricted|RemoteSigned|AllSigned)|WindowStyle\s+(?:Hidden|Minimized|Normal)))*\s+-File)' +
        '\s+(?:"(?:\.\\)?(?<qfile>[A-Za-z0-9][A-Za-z0-9 ._\-]{0,80}\.ps1)"|(?:\.\\)?(?<file>[A-Za-z0-9][A-Za-z0-9._\-]{0,80}\.ps1))(?<args>(?:\s+.*)?)$'
    $m = [regex]::Match($c, $re, 'IgnoreCase')
    if (-not $m.Success) { return $null }
    $file = if ($m.Groups['qfile'].Success) { $m.Groups['qfile'].Value } else { $m.Groups['file'].Value }
    return @{ Runner = $m.Groups['runner'].Value; File = $file; Args = $m.Groups['args'].Value }
}

function Global:Get-PackageScriptRunner {
    # Pure: how a package's own PowerShell script is run - 64-bit Windows PowerShell, no profile, from the package folder.
    return '%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
}

function Global:Test-BlockValueText {
    # Pure: whether -Text is a value that can go into a command line as it is - plain ASCII, no quotes, no characters a shell or PowerShell acts on, at most -Max characters.
    param([string]$Text, [int]$Max = 200, [switch]$AllowPercent, [switch]$AllowSemicolon)
    if ($null -eq $Text -or $Text.Length -gt $Max) { return $false }
    $extra = $(if ($AllowPercent) { '%' } else { '' }) + $(if ($AllowSemicolon) { ';' } else { '' })
    return ($Text -cmatch ('^[A-Za-z0-9 _\-./\\:=+,@()\[\]{}!#~''' + [regex]::Escape($extra) + ']*$'))
}

function Global:New-MsiCommandLines {
    <#
      Pure: an MSI's install and uninstall commands from its blocks -
      @{ Ok; Install; Uninstall; Error }. -Properties: @(@{ name; value })
      public properties (upper case) such as ALLUSERS=1 or TRANSFORMS=x.mst;
      a value with a space is put in double quotes.
    #>
    param([string]$File, $Properties = @(), [string]$ProductCode)
    $f = ([string]$File).Trim()
    if ($f -notmatch '^[A-Za-z0-9 _\-.()\[\]+,@!#~]{1,120}\.msi$') { return @{ Ok = $false; Error = "The MSI file must be a file name in the package folder, ending in .msi (no path, no quotes)." } }
    $code = ([string]$ProductCode).Trim().ToUpperInvariant()
    if ($code -notmatch '^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}$') { return @{ Ok = $false; Error = 'The product code must look like {12345678-1234-1234-1234-123456789ABC}.' } }
    $parts = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($p in @($Properties)) {
        if (-not $p) { continue }
        $n = ([string]$p.name).Trim().ToUpperInvariant(); $v = ([string]$p.value).Trim()
        if (-not $n -and -not $v) { continue }
        if ($n -notmatch '^[A-Z_][A-Z0-9_.]{0,63}$') { return @{ Ok = $false; Error = "'$n' isn't an MSI property name (letters, digits, _ and . - public properties are upper case)." } }
        if ($n -in 'REBOOT', 'REBOOTPROMPT') { return @{ Ok = $false; Error = "$n is set by the tool already (/norestart) - leave it out." } }
        if ($seen.ContainsKey($n)) { return @{ Ok = $false; Error = "$n is there twice." } }
        if (-not (Test-BlockValueText $v -AllowPercent -AllowSemicolon)) { return @{ Ok = $false; Error = "The value of $n isn't allowed: plain letters, digits, spaces and / \ - _ . : = + , @ ( ) [ ] { } ! # ~ ' % ; - no double quotes, &, |, <, > or ^ (200 characters at most)." } }
        $seen[$n] = $true
        # In double quotes when it has a space - or a %VAR%, which Intune expands (Program Files has a space).
        $parts.Add($(if ($v -match '[\s%]' -or $v -eq '') { "$n=`"$v`"" } else { "$n=$v" }))
    }
    $install = "msiexec /i `"$f`" /qn /norestart" + $(if ($parts.Count) { ' ' + ($parts -join ' ') } else { '' })
    if ($install.Length -gt 1024) { return @{ Ok = $false; Error = "The install command would be $($install.Length) characters - Intune takes 1024 at most." } }
    return @{ Ok = $true; Install = $install; Uninstall = "msiexec /x $code /qn /norestart"; Error = '' }
}

function Global:New-ExeCommandLines {
    # Pure: an .exe installer's commands from its blocks - the maker's silent switches, extra switches, and Uninstall.ps1 (which finds the app's own uninstaller). @{ Ok; Install; Uninstall; Error }.
    param([string]$File, [string]$Kind, [string]$Extra)
    $f = ([string]$File).Trim()
    if ($f -notmatch '^[A-Za-z0-9 _\-.()\[\]+,@!#~]{1,120}\.exe$') { return @{ Ok = $false; Error = 'The installer must be a file name in the package folder, ending in .exe (no path, no quotes).' } }
    if ($Kind -and -not (Get-ExeSilentSwitches $Kind)) { return @{ Ok = $false; Error = "'$Kind' isn't an installer maker this tool knows." } }
    $x = ([string]$Extra).Trim()
    if ($x -and -not (Test-BlockValueText $x)) { return @{ Ok = $false; Error = "The extra switches aren't allowed: plain letters, digits, spaces and / \ - _ . : = + , @ ( ) [ ] { } ! # ~ ' - no quotes, %, ;, &, |, <, > or ^ (200 characters at most)." } }
    $sw = Get-ExeSilentSwitches $Kind
    $install = "`"$f`"" + $(if ($sw) { " $sw" } else { '' }) + $(if ($x) { " $x" } else { '' })
    return @{ Ok = $true; Install = $install; Uninstall = "$(Get-PackageScriptRunner) .\Uninstall.ps1"; Error = '' }
}

function Global:Get-InstallBlocks {
    <#
      Pure: an app's install and uninstall commands as blocks - @{ Form;
      Own; Blocks; Note }. Form: winget, msi, exe, script, psadt, or own
      (a command this tool doesn't write - kept as it is, Blocks empty).
      Each form is recognised only when writing its blocks back gives
      exactly the same commands.
    #>
    param([string]$WingetId, [string]$Install, [string]$Uninstall, [string]$InstallContext)
    $own = @{ Form = 'own'; Own = $true; Blocks = @(); Note = 'An own command: kept exactly as it is.' }
    $Install = [string]$Install; $Uninstall = [string]$Uninstall
    if (-not $Install.Trim()) { return @{ Form = 'none'; Own = $true; Blocks = @(); Note = 'No install command yet.' } }

    # Winget: the generated forms (Get-AppWingetInstallMethod), pinned or newest, with extra options.
    if ($WingetId -and -not (Test-StoreProductId $WingetId)) {
        $method = Get-AppWingetInstallMethod -WingetId $WingetId -InstallCommand $Install -UninstallCommand $Uninstall
        if ($method -in 'Managed', 'Winget') {
            $pinned = ''
            if ($method -eq 'Managed' -and $Install -match " --version '((?:[^']|'')+)'") { $pinned = $Matches[1] -replace "''", "'" }
            $opts = Get-WingetCommandOptions $Install
            $list = @(foreach ($m in [regex]::Matches($opts, "(--[a-z\-]+) '((?:[^']|'')*)'")) { [ordered]@{ name = $m.Groups[1].Value; value = ($m.Groups[2].Value -replace "''", "'") } })
            $machine = $Install -match ' --scope machine'
            $blocks = @(
                (New-CommandBlock -Id 'ps' -Kind 'lock' -Label 'PowerShell' -Text '64-bit Windows PowerShell, no profile' -Help "Intune's agent is 32-bit: sysnative reaches the 64-bit PowerShell.")
                (New-CommandBlock -Id 'find' -Kind 'lock' -Label 'Find winget' -Text 'the newest App Installer - waits up to 5 minutes on a new device, else exit 9009 (Intune retries)')
                (New-CommandBlock -Id 'cmd' -Kind 'link' -Label 'Install' -Text "winget install --id $WingetId -e --source winget --silent" -Link 'aWinget' -Help "The Winget ID - changed here or on Basics, the commands follow. -e (exactly this ID), --source winget and --silent are always there - an install with nobody at the device needs them. More switches go in Extra winget options; Edit as text makes it an own command.")
                (New-CommandBlock -Id 'version' -Kind 'link' -Label 'Version' -Text $(if ($pinned) { "$pinned - pinned (managed updates)" } else { 'the newest winget has' }) -Link 'aMethod' -Help 'The newest winget has, or pinned to the App version (managed updates) - changed here or with Install with on Basics.')
                (New-CommandBlock -Id 'scope' -Kind 'link' -Label 'For' -Text $(if ($machine) { 'the device (--scope machine)' } else { 'the signed-in user' }) -Link 'xContext' -Help 'Who it installs for - the same as Install for in the requirements; changed here or there, the commands follow.')
                (New-CommandBlock -Id 'options' -Kind 'list' -Label 'Extra winget options' -Value $list -Choices @('--override', '--custom', '--architecture', '--locale', '--installer-type') -Help 'Most packages need none - winget installs silently with the package''s own switches.')
                (New-CommandBlock -Id 'uninstall' -Kind 'lock' -Label 'Uninstall' -Text "winget uninstall --id $WingetId -e --silent" -Part 'uninstall')
            )
            # An older generated form (before 2.22) still counts, but a change writes today's form - said up front.
            $today = Get-WingetCommandLines -WingetId $WingetId -Method $method -InstallContext $(if ($machine) { 'System' } else { 'User' }) -Version $pinned -Options $opts
            $note = if ($today.Install -cne $Install -or $today.Uninstall -cne $Uninstall) { "Written in an older form - a change here writes today's form." } else { '' }
            return @{ Form = 'winget'; Own = $false; Blocks = $blocks; Note = $note }
        }
        return $own
    }

    # MSI: msiexec /i "file.msi" /qn /norestart [PROPERTY=value ...], uninstalled by its product code.
    $mi = [regex]::Match($Install, '^msiexec /i "([^"]+)" /qn /norestart((?: [A-Z_][A-Z0-9_.]*=(?:"[^"]*"|[^\s"]+))*)$')
    $mu = [regex]::Match($Uninstall, '^msiexec /x (\{[0-9A-F-]{36}\}) /qn /norestart$')
    if ($mi.Success -and $mu.Success) {
        $props = @(foreach ($m in [regex]::Matches($mi.Groups[2].Value, ' ([A-Z_][A-Z0-9_.]*)=(?:"([^"]*)"|([^\s"]+))')) { [ordered]@{ name = $m.Groups[1].Value; value = ($m.Groups[2].Value + $m.Groups[3].Value) } })
        $again = New-MsiCommandLines -File $mi.Groups[1].Value -Properties $props -ProductCode $mu.Groups[1].Value
        if ($again.Ok -and $again.Install -ceq $Install -and $again.Uninstall -ceq $Uninstall) {
            $blocks = @(
                (New-CommandBlock -Id 'msiexec' -Kind 'lock' -Label 'Run' -Text 'msiexec /i')
                (New-CommandBlock -Id 'file' -Kind 'edit' -Label 'MSI file' -Value $mi.Groups[1].Value -Help 'A file in the app''s package folder.')
                (New-CommandBlock -Id 'silent' -Kind 'lock' -Label 'Silent' -Text '/qn /norestart - no windows, no restart (Intune restarts by the return code)')
                (New-CommandBlock -Id 'props' -Kind 'list' -Label 'Properties' -Value $props -Help 'Public MSI properties, e.g. ALLUSERS=1, TRANSFORMS=Company.mst, INSTALLDIR=C:\Apps\X.')
                (New-CommandBlock -Id 'msix' -Kind 'lock' -Label 'Uninstall' -Text 'msiexec /x' -Part 'uninstall')
                (New-CommandBlock -Id 'code' -Kind 'edit' -Label 'Product code' -Value $mu.Groups[1].Value -Part 'uninstall' -Help 'The MSI''s ProductCode - read from the installer when it was added.')
                (New-CommandBlock -Id 'usilent' -Kind 'lock' -Label 'Silent' -Text '/qn /norestart' -Part 'uninstall')
            )
            return @{ Form = 'msi'; Own = $false; Blocks = $blocks; Note = '' }
        }
        return $own
    }

    # EXE: "setup.exe" with the maker's silent switches and extra ones; Uninstall.ps1 runs the app's own uninstaller.
    $me = [regex]::Match($Install, '^"([^"]+\.exe)"(.*)$')
    if ($me.Success -and $Uninstall -ceq "$(Get-PackageScriptRunner) .\Uninstall.ps1") {
        $rest = $me.Groups[2].Value.Trim(); $kind = ''; $extra = $rest
        foreach ($k in 'inno', 'nsis', 'burn', 'installshield', 'advanced') {
            $sw = Get-ExeSilentSwitches $k
            if ($rest -ceq $sw -or $rest.StartsWith("$sw ", [StringComparison]::Ordinal)) { $kind = $k; $extra = $rest.Substring($sw.Length).Trim(); break }
        }
        $again = New-ExeCommandLines -File $me.Groups[1].Value -Kind $kind -Extra $extra
        if ($again.Ok -and $again.Install -ceq $Install) {
            $choices = @([ordered]@{ value = ''; label = '(unknown - switches below)' }) + @(foreach ($k in 'inno', 'nsis', 'burn', 'installshield', 'advanced') { [ordered]@{ value = $k; label = "$(@{ inno = 'Inno Setup'; nsis = 'NSIS'; burn = 'WiX bundle (Burn)'; installshield = 'InstallShield'; advanced = 'Advanced Installer' }[$k]) - $(Get-ExeSilentSwitches $k)" } })
            $blocks = @(
                (New-CommandBlock -Id 'file' -Kind 'edit' -Label 'Installer' -Value $me.Groups[1].Value -Help 'A file in the app''s package folder.')
                (New-CommandBlock -Id 'kind' -Kind 'edit' -Label 'Made with' -Type 'select' -Value $kind -Choices $choices -Help 'Sets the silent switches its maker uses.')
                (New-CommandBlock -Id 'extra' -Kind 'edit' -Label 'Extra switches' -Value $extra -Help 'Added after the silent switches, e.g. /DIR=C:\Apps\X or /LOG.')
                (New-CommandBlock -Id 'uninstall' -Kind 'action' -Label 'Uninstall' -Text 'Uninstall.ps1 - runs the uninstaller Windows lists for the app, silently' -Value 'Uninstall.ps1' -Part 'uninstall')
            )
            return @{ Form = 'exe'; Own = $false; Blocks = $blocks; Note = '' }
        }
        return $own
    }

    # A script app: Install.ps1 and Uninstall.ps1 in its package folder.
    $run = Get-PackageScriptRunner
    if ($Install -ceq "$run .\Install.ps1" -and $Uninstall -ceq "$run .\Uninstall.ps1") {
        $blocks = @(
            (New-CommandBlock -Id 'ps' -Kind 'lock' -Label 'PowerShell' -Text '64-bit Windows PowerShell, no profile, from the package folder')
            (New-CommandBlock -Id 'script' -Kind 'action' -Label 'Install' -Text 'Install.ps1' -Value 'Install.ps1')
            (New-CommandBlock -Id 'uscript' -Kind 'action' -Label 'Uninstall' -Text 'Uninstall.ps1' -Value 'Uninstall.ps1' -Part 'uninstall')
        )
        return @{ Form = 'script'; Own = $false; Blocks = $blocks; Note = '' }
    }

    # A script app written another way (by hand, from Intune, another tool): Windows PowerShell running a .ps1 from
    # the package folder - any order of the usual switches, with or without .\ or quotes, any file name. Shown as
    # blocks with the scripts to open; the commands stay exactly as they are (nothing in them is rewritten).
    $si = Get-ScriptCommandFile $Install
    $su = Get-ScriptCommandFile $Uninstall
    if ($si -and $si.File -ine 'Invoke-AppDeployToolkit.ps1') {
        $blocks = New-Object System.Collections.Generic.List[object]
        $blocks.Add((New-CommandBlock -Id 'ps' -Kind 'lock' -Label 'PowerShell' -Text $si.Runner))
        $blocks.Add((New-CommandBlock -Id 'script' -Kind 'action' -Label 'Install' -Text "$($si.File)$($si.Args)" -Value $si.File))
        if ($su) {
            if ($su.Runner -cne $si.Runner) { $blocks.Add((New-CommandBlock -Id 'ups' -Kind 'lock' -Label 'PowerShell' -Text $su.Runner -Part 'uninstall')) }
            $blocks.Add((New-CommandBlock -Id 'uscript' -Kind 'action' -Label 'Uninstall' -Text "$($su.File)$($su.Args)" -Value $su.File -Part 'uninstall'))
        }
        else { $blocks.Add((New-CommandBlock -Id 'ucmd' -Kind 'lock' -Label 'Runs' -Text $Uninstall -Part 'uninstall')) }
        return @{ Form = 'script'; Own = $false; Blocks = $blocks.ToArray(); Note = 'Your own script commands - kept exactly as they are; open the scripts below.' }
    }

    # PSADT 4: Invoke-AppDeployToolkit (.exe, or the .ps1 with PowerShell), its deploy mode.
    $mp = [regex]::Match($Install, '^(Invoke-AppDeployToolkit\.exe|' + [regex]::Escape($run) + ' Invoke-AppDeployToolkit\.ps1) -DeploymentType Install -DeployMode (Silent|NonInteractive|Interactive)$')
    if ($mp.Success -and $Uninstall -ceq "$($mp.Groups[1].Value) -DeploymentType Uninstall -DeployMode $($mp.Groups[2].Value)") {
        $blocks = @(
            (New-CommandBlock -Id 'run' -Kind 'lock' -Label 'Run' -Text $mp.Groups[1].Value.Replace($run, '64-bit PowerShell:'))
            (New-CommandBlock -Id 'type' -Kind 'lock' -Label 'Deployment' -Text '-DeploymentType Install (Uninstall for the uninstall command)')
            (New-CommandBlock -Id 'mode' -Kind 'edit' -Label 'Deploy mode' -Type 'select' -Value $mp.Groups[2].Value -Choices @([ordered]@{ value = 'Silent'; label = 'Silent - no windows' }, [ordered]@{ value = 'NonInteractive'; label = 'NonInteractive - progress, no questions' }, [ordered]@{ value = 'Interactive'; label = 'Interactive - asks the user (close apps, defer)' }))
            (New-CommandBlock -Id 'script' -Kind 'action' -Label 'Script' -Text 'Invoke-AppDeployToolkit.ps1' -Value 'Invoke-AppDeployToolkit.ps1')
        )
        return @{ Form = 'psadt'; Own = $false; Blocks = $blocks; Note = '' }
    }
    return $own
}

function Global:New-InstallFromBlocks {
    <#
      Pure: the commands written from -Values (block id -> value) for -Form,
      starting from the current commands (what isn't a block stays as it
      is: the pinned version, the install context, the PSADT runner).
      @{ Ok; Install; Uninstall; Error }. Every value is checked here - these
      commands run as SYSTEM on every device.
    #>
    param([string]$Form, $Values, [string]$WingetId, [string]$Install, [string]$Uninstall, [string]$InstallContext)
    $now = Get-InstallBlocks -WingetId $WingetId -Install $Install -Uninstall $Uninstall -InstallContext $InstallContext
    if ($now.Form -ne $Form) { return @{ Ok = $false; Error = "The commands aren't the $Form form any more (changed meanwhile) - open the app again." } }
    $get = { param($k) if ($Values -is [System.Collections.IDictionary]) { $Values[$k] } elseif ($Values) { $Values.$k } }
    switch ($Form) {
        'winget' {
            $method = Get-AppWingetInstallMethod -WingetId $WingetId -InstallCommand $Install -UninstallCommand $Uninstall
            $pinned = ''
            if ($method -eq 'Managed' -and $Install -match " --version '((?:[^']|'')+)'") { $pinned = $Matches[1] -replace "''", "'" }
            $text = (@(foreach ($o in @(& $get 'options')) { if ($o -and ([string]$o.name).Trim()) { "$(([string]$o.name).Trim()) '$(([string]$o.value).Replace("'", "''"))'" } }) -join ' ')
            $o = ConvertTo-WingetOptionText $text
            if (-not $o.Ok) { return @{ Ok = $false; Error = $o.Error } }
            $context = if ($Install -match ' --scope machine') { 'System' } else { 'User' }
            $c = Get-WingetCommandLines -WingetId $WingetId -Method $method -InstallContext $context -Version $pinned -Options $o.Options
            if ($c.Install.Length -gt 1024) { return @{ Ok = $false; Error = "With these options the install command is $($c.Install.Length) characters - Intune takes 1024 at most." } }
            return @{ Ok = $true; Install = $c.Install; Uninstall = $c.Uninstall; Error = '' }
        }
        'msi' { $r = New-MsiCommandLines -File ([string](& $get 'file')) -Properties @(& $get 'props') -ProductCode ([string](& $get 'code')); return $r }
        'exe' { return (New-ExeCommandLines -File ([string](& $get 'file')) -Kind ([string](& $get 'kind')) -Extra ([string](& $get 'extra'))) }
        'psadt' {
            $mode = [string](& $get 'mode')
            if ($mode -notin 'Silent', 'NonInteractive', 'Interactive') { return @{ Ok = $false; Error = 'Deploy mode must be Silent, NonInteractive or Interactive.' } }
            $runner = ([regex]::Match($Install, '^(.+?) -DeploymentType Install')).Groups[1].Value
            return @{ Ok = $true; Install = "$runner -DeploymentType Install -DeployMode $mode"; Uninstall = "$runner -DeploymentType Uninstall -DeployMode $mode"; Error = '' }
        }
        'script' { return @{ Ok = $true; Install = $Install; Uninstall = $Uninstall; Error = '' } }
    }
    return @{ Ok = $false; Error = "An own command has no blocks - it's edited as text." }
}

function Global:ConvertFrom-InstalledNamePattern {
    # Pure: the name Get-InstalledNamePattern made -Pattern from ('' when it isn't one of its patterns) - so the name can be shown and edited instead of the regex.
    param([string]$Pattern)
    if (-not $Pattern) { return '' }
    $tail = '(\s+(v?\d[\w.\-]*|\([^)]*\)))*\s*$'
    if (-not $Pattern.StartsWith('^', [StringComparison]::Ordinal) -or -not $Pattern.EndsWith($tail, [StringComparison]::Ordinal)) { return $null }
    $escaped = $Pattern.Substring(1, $Pattern.Length - 1 - $tail.Length)
    try { $name = [regex]::Unescape($escaped) } catch { return $null }
    if ((Get-InstalledNamePattern $name) -cne $Pattern) { return $null }
    return $name
}

function Global:Get-DetectionBlocks {
    <#
      Pure: a detection rule as blocks - @{ Form; Own; Blocks; Note }.
      Form: managed (the managed winget release's script), installed (the
      name and version Windows lists), rule (an MSI, file or registry rule -
      already fields of their own), own (a script this tool didn't write),
      none. A script counts as a form only when writing it again from its
      blocks gives exactly the same script.
    #>
    param($Rule)
    if (-not $Rule -or -not [string]$Rule.Type) { return @{ Form = 'none'; Own = $true; Blocks = @(); Note = '' } }
    if ([string]$Rule.Type -ne 'Script') { return @{ Form = 'rule'; Own = $false; Blocks = @(); Note = '' } }
    $s = ([string]$Rule.Script_Content) -replace "`r`n", "`n"
    $q = "'((?:[^']|'')*)'"
    $un = { param($t) $t -replace "''", "'" }
    $m = [regex]::Match($s, "^\`$AppToDetect = $q\n\`$Wanted = $q\n\`$NamePattern = $q\n")
    if ($m.Success) {
        $id = & $un $m.Groups[1].Value; $ver = & $un $m.Groups[2].Value; $pat = & $un $m.Groups[3].Value
        $name = ConvertFrom-InstalledNamePattern $pat
        if ($null -ne $name -and ((Get-ManagedWingetDetection -WingetId $id -Version $ver -NamePattern $pat) -replace "`r`n", "`n") -ceq $s) {
            $blocks = @(
                (New-CommandBlock -Id 'read' -Kind 'lock' -Label 'First' -Text "Windows' Uninstall entries (64-bit, 32-bit, the user's)" -Part 'detection')
                (New-CommandBlock -Id 'name' -Kind 'edit' -Label 'Name Windows lists' -Value $name -Part 'detection' -Help 'Exactly, or with a version or "(x64)" after it - looked for first; winget is asked when it isn''t found.')
                (New-CommandBlock -Id 'version' -Kind 'link' -Label 'Version at least' -Text $ver -Link 'mAppVersion' -Part 'detection' -Help 'The App version - a release moves it. Newer counts too.')
                (New-CommandBlock -Id 'id' -Kind 'link' -Label 'Else winget' -Text "winget lists $id" -Link 'aWinget' -Part 'detection')
                (New-CommandBlock -Id 'result' -Kind 'lock' -Label 'Found' -Text "writes 'Installed!' - what Intune counts as installed" -Part 'detection')
            )
            return @{ Form = 'managed'; Own = $false; Blocks = $blocks; Note = '' }
        }
    }
    $m = [regex]::Match($s, "^\`$pattern = $q; \`$want = $q\n")
    if ($m.Success) {
        $pat = & $un $m.Groups[1].Value; $ver = & $un $m.Groups[2].Value
        $name = ConvertFrom-InstalledNamePattern $pat
        if ($name -and ((New-InstalledAppDetectionScript -DisplayName $name -Version $ver) -replace "`r`n", "`n") -ceq $s) {
            $blocks = @(
                (New-CommandBlock -Id 'read' -Kind 'lock' -Label 'Look in' -Text "Windows' Uninstall entries (64-bit and 32-bit)" -Part 'detection')
                (New-CommandBlock -Id 'name' -Kind 'edit' -Label 'Name Windows lists' -Value $name -Part 'detection' -Help 'Exactly, or with a version or "(x64)" after it - not another product that starts the same.')
                (New-CommandBlock -Id 'version' -Kind 'edit' -Label 'Version at least' -Value $ver -Part 'detection' -Help 'Empty: any version.')
                (New-CommandBlock -Id 'result' -Kind 'lock' -Label 'Found' -Text "writes 'Installed', exit 0 - what Intune counts as installed" -Part 'detection')
            )
            return @{ Form = 'installed'; Own = $false; Blocks = $blocks; Note = '' }
        }
    }
    return @{ Form = 'own'; Own = $true; Blocks = @(); Note = 'An own script: kept exactly as it is.' }
}

function Global:New-DetectionFromBlocks {
    # Pure: the detection script written from -Values for -Form, from the current -Rule (what isn't a block stays). @{ Ok; Script; DetectedName; Error }.
    param([string]$Form, $Values, $Rule)
    $now = Get-DetectionBlocks $Rule
    if ($now.Form -ne $Form) { return @{ Ok = $false; Error = "The detection script isn't the $Form form any more - open the app again." } }
    $get = { param($k) if ($Values -is [System.Collections.IDictionary]) { $Values[$k] } elseif ($Values) { $Values.$k } }
    $name = ([string](& $get 'name')).Trim()
    # At most 100 (what the catalog keeps as the name on devices), one line, and no quotes the script would have to change.
    if ($name.Length -gt 100 -or $name -match '[\x00-\x1f]') { return @{ Ok = $false; Error = 'The name must be one line of at most 100 characters.' } }
    if ($name -match "[`"\u2018-\u201F]") { return @{ Ok = $false; Error = 'The name can''t contain double quotes or typographic quotes - leave them out (the rest of the name still matches).' } }
    $s = ([string]$Rule.Script_Content) -replace "`r`n", "`n"
    $q = "'((?:[^']|'')*)'"
    if ($Form -eq 'managed') {
        # Empty would be filled with the app's name again at the next release (Set-ManagedAppPin) - so it's needed here.
        if (-not $name) { return @{ Ok = $false; Error = 'The name Windows lists is needed - the next release writes the detection from it.' } }
        $m = [regex]::Match($s, "^\`$AppToDetect = $q\n\`$Wanted = $q\n")
        $script = Get-ManagedWingetDetection -WingetId ($m.Groups[1].Value -replace "''", "'") -Version ($m.Groups[2].Value -replace "''", "'") -NamePattern $(if ($name) { Get-InstalledNamePattern $name } else { '' })
        return @{ Ok = $true; Script = $script; DetectedName = $name; Error = '' }
    }
    if ($Form -eq 'installed') {
        if (-not $name) { return @{ Ok = $false; Error = 'The name Windows lists is needed.' } }
        $ver = ([string](& $get 'version')).Trim()
        if ($ver -and -not (Test-ReleaseVersionText $ver)) { return @{ Ok = $false; Error = "'$ver' isn't a version (digits, letters, . - + _)." } }
        return @{ Ok = $true; Script = (New-InstalledAppDetectionScript -DisplayName $name -Version $ver); DetectedName = ''; Error = '' }
    }
    return @{ Ok = $false; Error = "This detection rule has no blocks." }
}

# ---------------------------------------------------------------- package scripts in the editor (2.26)

function Global:Get-PackageScriptLockedLines {
    <#
      Pure: the lines of a package script this tool owns - the version
      marker the detection rule reads (and its comment), which a release
      moves to the new version. The editor keeps them as they are; zero-based
      line numbers.
    #>
    param([string]$Text)
    $lines = ([string]$Text) -split "`r?`n"
    $locked = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # PSADT's AppVersion = '<v>' - a release writes it (Set-MarkerScriptVersion).
        if ($lines[$i] -match "^\s*AppVersion\s*=\s*'") { $locked.Add($i); continue }
        if ($lines[$i] -match 'IntuneAppCatalog\\Apps\\') {
            $locked.Add($i)
            if ($i -gt 0 -and $lines[$i - 1] -match '^\s*#.*version marker' -and -not $locked.Contains($i - 1)) { $locked.Add($i - 1) }
            if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s*Set-ItemProperty\b.*-Name\s+Version\b' -and -not $locked.Contains($i + 1)) { $locked.Add($i + 1) }
        }
    }
    return @($locked | Sort-Object -Unique)
}

function Global:Get-MarkerCommandPlaces {
    <#
      Pure: where in -Text the version marker is written - for each
      Set-ItemProperty ... IntuneAppCatalog\Apps\... -Name Version: the blocks
      around it (functions by name, if, loops, script blocks) and how many
      unconditional exits, returns or throws come before it at its own level.
      Test-PackageScriptEdit compares these, so the marker can't be switched
      off without changing its own line (commented out, put in an if, after
      an exit).
    #>
    param([string]$Text)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput([string]$Text, [ref]$null, [ref]$null)
    $cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-ItemProperty' -and $n.Extent.Text -match 'IntuneAppCatalog\\Apps\\' -and $n.Extent.Text -match '-Name\s+Version\b' }, $true))
    $places = foreach ($c in $cmds) {
        $path = New-Object System.Collections.Generic.List[string]
        $stmt = $c
        while ($stmt.Parent -and -not ($stmt.Parent -is [System.Management.Automation.Language.NamedBlockAst] -or $stmt.Parent -is [System.Management.Automation.Language.StatementBlockAst])) { $stmt = $stmt.Parent }
        $n = $c.Parent
        while ($n) {
            if ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $path.Add('function ' + $n.Name) }
            elseif (-not ($n -is [System.Management.Automation.Language.PipelineAst] -or $n -is [System.Management.Automation.Language.NamedBlockAst] -or $n -is [System.Management.Automation.Language.StatementBlockAst])) { $path.Add($n.GetType().Name) }
            $n = $n.Parent
        }
        $before = 0
        if ($stmt.Parent) {
            foreach ($s in @($stmt.Parent.Statements)) {
                if ([object]::ReferenceEquals($s, $stmt)) { break }
                if ($s -is [System.Management.Automation.Language.ReturnStatementAst] -or $s -is [System.Management.Automation.Language.ExitStatementAst] -or $s -is [System.Management.Automation.Language.ThrowStatementAst] -or $s -is [System.Management.Automation.Language.BreakStatementAst] -or $s -is [System.Management.Automation.Language.ContinueStatementAst]) { $before++ }
            }
        }
        "$($path -join '/')|$before"
    }
    return @(@($places) | Sort-Object)
}

function Global:Test-PackageScriptEdit {
    <#
      Pure: whether -New may replace -Old - @{ Ok; Error; Errors }. It must
      parse as PowerShell (Errors: @{ line; column; message }, one-based) and
      keep the locked lines of -Old (Get-PackageScriptLockedLines) unchanged
      and in their order.
    #>
    param([string]$Old, [string]$New)
    if (([string]$New).Length -gt 262144) { return @{ Ok = $false; Error = 'The script is too long (256 KB at most).'; Errors = @() } }
    # A lone carriage return is a line break to PowerShell but not to the line checks below.
    if ([string]$New -match "`r(?!`n)") { return @{ Ok = $false; Error = 'The script has a line break the editor doesn''t write (a carriage return on its own) - take it out.'; Errors = @() } }
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput([string]$New, [ref]$null, [ref]$errs)
    $list = @(foreach ($e in @($errs)) { if ($e) { [ordered]@{ line = $e.Extent.StartLineNumber; column = $e.Extent.StartColumnNumber; message = $e.Message } } })
    if ($list.Count) { return @{ Ok = $false; Error = "It doesn't parse: $($list[0].message) (line $($list[0].line))."; Errors = $list } }
    $oldLines = ([string]$Old) -split "`r?`n"; $newLines = ([string]$New) -split "`r?`n"
    $want = @(foreach ($i in (Get-PackageScriptLockedLines $Old)) { $oldLines[$i] })
    $have = @(foreach ($i in (Get-PackageScriptLockedLines $New)) { $newLines[$i] })
    if (($want -join "`n") -cne ($have -join "`n")) { return @{ Ok = $false; Error = "The locked lines (the version marker the detection rule reads) must stay as they are."; Errors = @() } }
    # The lines alone aren't enough: the marker must still run where it ran (not commented out, in an if, after an exit).
    $was = @(Get-MarkerCommandPlaces $Old)
    if ($was.Count -and (($was -join "`n") -cne (@(Get-MarkerCommandPlaces $New) -join "`n"))) { return @{ Ok = $false; Error = 'The version marker must still run as it did - not commented out, inside a condition or a block of its own, or after an exit, return or throw.'; Errors = @() } }
    return @{ Ok = $true; Error = ''; Errors = @() }
}
