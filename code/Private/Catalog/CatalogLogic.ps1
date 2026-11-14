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
      Winget apps deploy through Winget-AutoUpdate's Winget-Install.ps1
      with -AppIDs "Some.App" (see Get-CreateAppTemplates), and a plain
      "winget install --id Some.App" says the same thing another way.
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
        "windowsMobileMSI"        = "Windows app (Win32)"
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
        DefaultDependencyAppNames = @("Winget AutoUpdate")
        # How a Winget app's generated install and uninstall commands run
        # winget: "WAU" through Winget-AutoUpdate's Winget-Install.ps1
        # (needs WAU on the device), "Winget" by calling winget.exe itself.
        # New Winget apps: a pinned version, new ones released through the pilot groups (managed updates).
        WingetInstallMethod      = "Managed"
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
`$JsonFile = "`$env:TEMP\InstalledApps.json"
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

function Global:Get-WingetCommandLines {
    <#
      The install and uninstall command lines for a Winget app.

      "WAU" (also what anything else falls back to) runs Winget-AutoUpdate's
      Winget-Install.ps1, so the device needs WAU installed. "Winget" calls
      winget.exe itself: under SYSTEM it isn't on PATH, so the command finds
      it in the App Installer package folder first, and falls back to plain
      "winget" for a user install, which can't list that folder.
    #>
    param([string]$WingetId, [string]$Method, [string]$InstallContext, [string]$Version)

    $ps = "%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile"
    # The ID ends up in code and command lines that run as SYSTEM on the
    # devices - escaped for its single quotes, and anything that would close
    # the surrounding double quotes removed (see ConvertTo-PsSingleQuotedContent).
    $WingetId = ConvertTo-PsSingleQuotedContent $WingetId
    # "Managed": winget itself, pinned to -Version - a release of exactly that
    # version (Get-ManagedWingetDetection checks for it or newer). Without a
    # version yet it is the plain winget form.
    $pin = ""
    if ($Method -eq "Managed") {
        $Method = "Winget"
        if ($Version -and (Test-ReleaseVersionText $Version)) { $pin = " --version '$(ConvertTo-PsSingleQuotedContent $Version)'" }
    }
    if ($Method -eq "Winget") {
        $scope = if ($InstallContext -eq "User") { "" } else { " --scope machine" }
        # Newest App Installer first: there can be more than one version
        # side by side, and a plain name sort puts 1.9 after 1.21.
        $find = "`$w = Get-Item `$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe -ErrorAction SilentlyContinue | Sort-Object { `$_.VersionInfo.FileVersionRaw } | Select-Object -Last 1 -ExpandProperty FullName; if (-not `$w) { `$w = 'winget' }"
        return @{
            Install   = "$ps -Command `"$find; & `$w install --id '$WingetId' -e$pin --source winget$scope --silent --accept-package-agreements --accept-source-agreements; exit `$LASTEXITCODE`""
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
    # A pinned winget command is the managed form, whatever version it pins.
    if ($InstallCommand -match " --version '((?:[^']|'')+)'") {
        $pinned = $Matches[1] -replace "''", "'"
        foreach ($context in @("System", "User")) {
            $generated = Get-WingetCommandLines -WingetId $WingetId -Method "Managed" -InstallContext $context -Version $pinned
            if ($InstallCommand -eq $generated.Install -and $UninstallCommand -eq $generated.Uninstall) { return "Managed" }
        }
        return ""
    }
    foreach ($method in @("WAU", "Winget")) {
        foreach ($context in @("System", "User")) {
            $generated = Get-WingetCommandLines -WingetId $WingetId -Method $method -InstallContext $context
            if ($InstallCommand -eq $generated.Install -and $UninstallCommand -eq $generated.Uninstall) { return $method }
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
    $wanted = Get-WingetCommandLines -WingetId $WingetId -Method $Method -InstallContext $InstallContext
    if ($wanted.Install -eq $InstallCommand -and $wanted.Uninstall -eq $UninstallCommand) {
        return @{ Status = "Already"; Install = $InstallCommand; Uninstall = $UninstallCommand }
    }
    return @{ Status = "Switched"; Install = $wanted.Install; Uninstall = $wanted.Uninstall }
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
    $catalogNames = @{}
    foreach ($catalogApp in $Global:App.Apps) {
        if ($catalogApp.appName) { $catalogNames[[string]$catalogApp.appName] = $true }
    }
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
        returnCodes             = @($das.ReturnCodes)
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
    #>
    param([string]$WingetId, [string]$Version)
    $id = ConvertTo-PsSingleQuotedContent $WingetId
    $v = ConvertTo-PsSingleQuotedContent $Version
    return @"
`$AppToDetect = '$id'
`$Wanted = '$v'

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

`$winget   = Get-WingetCmd
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
        $rule = Set-DetectionRuleVersion -Rule $m.detectionRule -Version $version -ProductCode $ProductCode
        if (-not $rule.Changed) { return $false }
        $m.detectionRule = $rule.Rule
        return $true
    }
    if (-not (Get-AppWingetInstallMethod -WingetId $App.wingetId -InstallCommand $m.installCommand -UninstallCommand $m.uninstallCommand) -and $m.installCommand) { return $false }
    $c = Get-WingetCommandLines -WingetId $App.wingetId -Method "Managed" -InstallContext $m.installContext -Version $version
    $detect = Get-ManagedWingetDetection -WingetId $App.wingetId -Version $version
    $changed = ($m.installCommand -ne $c.Install) -or ($m.uninstallCommand -ne $c.Uninstall) -or -not ($m.detectionRule -and $m.detectionRule.Type -eq 'Script' -and $m.detectionRule.Script_Content -eq $detect)
    $m.installCommand = $c.Install; $m.uninstallCommand = $c.Uninstall
    $m.detectionRule = [pscustomobject]@{ Type = 'Script'; Script_Content = $detect }
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
    return , $out.ToArray()
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

function Global:ConvertFrom-WingetShowOutput {
    <#
      Pure: "winget show --id X --exact" as @{ Name; Id; Version; Publisher;
      PublisherUrl; Description; Homepage; License; PrivacyUrl; Tags }. Keys
      are at the start of a line ("Key: value"); a value can continue on
      indented lines (a long description, the tags).
    #>
    param([string]$Text)
    $out = [ordered]@{ Name = ''; Id = ''; Version = ''; Publisher = ''; PublisherUrl = ''; Description = ''; Homepage = ''; License = ''; PrivacyUrl = ''; Tags = @() }
    $map = @{ 'Version' = 'Version'; 'Publisher' = 'Publisher'; 'Publisher Url' = 'PublisherUrl'; 'Description' = 'Description'; 'Short Description' = 'Description'; 'Homepage' = 'Homepage'; 'License' = 'License'; 'Privacy Url' = 'PrivacyUrl'; 'Tags' = 'Tags' }
    $key = ''
    foreach ($raw in @(([string]$Text) -split "`r?`n")) {
        $line = $raw -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
        $m = [regex]::Match($line, '^Found (.+) \[([^\]]+)\]\s*$')
        if ($m.Success) { $out.Name = $m.Groups[1].Value.Trim(); $out.Id = $m.Groups[2].Value.Trim(); $key = ''; continue }
        $m = [regex]::Match($line, '^([A-Za-z][A-Za-z ]*?):\s*(.*)$')
        if ($m.Success) {
            $k = $m.Groups[1].Value
            $key = if ($map.ContainsKey($k)) { $map[$k] } else { '' }
            if ($key -eq 'Description' -and $out.Description -and $k -eq 'Short Description') { $key = ''; continue }
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
    if (-not $name) { $name = ([System.IO.Path]::GetFileNameWithoutExtension($file) -replace '[_\-.]+(x64|x86|amd64|win64|win32|setup|installer|install)$', '' -replace '[_]+', ' ' -replace '\s+v?\d[\d.]*$', '').Trim() }
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
    $switches = switch ([string]$Info.ExeKind) {
        'inno' { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }
        'nsis' { '/S' }
        'burn' { '/quiet /norestart' }
        'installshield' { '/s /v"/qn REBOOT=ReallySuppress"' }
        'advanced' { '/exenoui /qn /norestart' }
        default { '' }
    }
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
        $isGranted = (& $has $f[0]) -or ($f[0] -eq 'DeviceManagementConfiguration.Read.All' -and (& $has 'DeviceManagementConfiguration.ReadWrite.All'))
        if ($f[1]) { & $row $f[0] $(if ($isGranted) { 'ok' } else { 'missing' }) $f[2] $f[3] }
        elseif ($isGranted) { & $row $f[0] 'unused' $f[2] $(if ($f[0] -eq 'Mail.Send') { 'No email alerts are set up - and Mail.Send can send as any mailbox: remove it, or limit it with an application access policy.' } else { 'Nothing here uses it yet.' }) }
        else { & $row $f[0] 'optional' $f[2] 'Only when you use it.' }
    }
    $known = @('DeviceManagementApps.ReadWrite.All', 'Group.ReadWrite.All', 'Group.Read.All', 'DeviceManagementScripts.ReadWrite.All', 'DeviceManagementManagedDevices.Read.All', 'Mail.Send', 'User.Read.All', 'DeviceManagementConfiguration.Read.All')
    # ReadWrite stands in for Read.All when filters are used; otherwise it's a broad one never needed (below).
    if ($Usage.Filters -and -not (& $has 'DeviceManagementConfiguration.Read.All')) { $known += 'DeviceManagementConfiguration.ReadWrite.All' }
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
        if ($t -match $rx) { $lit = (ConvertTo-PsLiteral $pair[1]).Replace('$', '$$'); $t = [regex]::Replace($t, $rx, ('${1}' + $lit), 1); $filled.Add($pair[0]) } else { $missing.Add($pair[0]) }
    }
    $key = ConvertTo-PsLiteral ("HKLM:\SOFTWARE\IntuneAppCatalog\Apps\" + ([string]$Name -replace '[\\/]', '-'))
    $ver = ConvertTo-PsLiteral $Version
    $add = "`r`n    ## The version marker Intune's detection rule reads (added by Intune App Catalog) - keep it.`r`n    New-Item -Path $key -Force | Out-Null`r`n    Set-ItemProperty -LiteralPath $key -Name Version -Value $ver`r`n"
    $remove = "`r`n    ## The version marker (added by Intune App Catalog).`r`n    Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue`r`n"
    $rxIn = '(?m)^(\s*## <Perform Post-Installation tasks here>[^\r\n]*)'
    if ($t -match $rxIn) { $t = [regex]::Replace($t, $rxIn, ('${1}' + $add.Replace('$', '$$')), 1); $filled.Add('marker after install') } else { $missing.Add('marker after install') }
    $rxUn = '(?m)^(\s*## <Perform Post-Uninstallation tasks here>[^\r\n]*)'
    if ($t -match $rxUn) { $t = [regex]::Replace($t, $rxUn, ('${1}' + $remove.Replace('$', '$$')), 1); $filled.Add('marker after uninstall') } else { $missing.Add('marker after uninstall') }
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
        '0x80070001' = @('The installer returned 1 (incorrect function / generic failure).', 'Exit code 1 is the installer''s own "failed" - run it by hand as SYSTEM to see why; for scripts, check the script''s errors.')
    }
    if ($known.ContainsKey($hex)) { return [ordered]@{ hex = $hex; meaning = $known[$hex][0]; fix = $known[$hex][1] } }
    if (($u -band 0xFFFF0000L) -eq 0x80070000L) {
        $w = [int]($u -band 0xFFFF)
        if ($w -ge 1600 -and $w -le 1650) { return [ordered]@{ hex = $hex; meaning = "Windows Installer error $w."; fix = "Look up MSI error $w; run the installer by hand as SYSTEM with logging (/l*v) to see the cause." } }
        return [ordered]@{ hex = $hex; meaning = "Windows error $w (or exit code $w from the installer)."; fix = "Search for $hex; if it is the installer's own exit code, its vendor documents it - add it to the return codes if it means success." }
    }
    if (($u -band 0xFFF00000L) -eq 0x87D00000L) { return [ordered]@{ hex = $hex; meaning = 'An error of the Intune Management Extension (the agent that installs Win32 apps).'; fix = "Search for $hex; the device's IntuneManagementExtension.log has the details." } }
    if ($u -lt 0x10000L) { return [ordered]@{ hex = $hex; meaning = "The installer exited with $u."; fix = "An exit code Intune doesn't know as success: the installer's documentation says what $u means - add it to the return codes if it means success." } }
    return [ordered]@{ hex = $hex; meaning = 'An error Intune reported.'; fix = "Search for $hex." }
}

function Global:Get-InstallErrorSummary {
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
