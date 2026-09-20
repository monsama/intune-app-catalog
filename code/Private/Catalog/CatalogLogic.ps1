function Global:Save-AppMetadataToLocalCatalog {
    param($AppsRef, $LinkedFilePath, $AppName, $Metadata, $NewAppId = $null, $IntuneAppVersion = $null)

    $targetIndex = -1
    for ($si = 0; $si -lt $AppsRef.Count; $si++) {
        if ($AppsRef[$si].appName -eq $AppName) { $targetIndex = $si; break }
    }
    $createdNewEntry = $false
    if ($targetIndex -lt 0) {
        $newEntry = [pscustomobject]@{
            appId            = ""
            appName          = $AppName
            wingetId         = ""
            intuneAppType    = ""
            intuneAppVersion = ""
            requiredFor      = @()
            availableFor     = @()
            uninstallFor     = @()
            excludeFor       = @()
            metadata         = $null
        }
        [void]$AppsRef.Add($newEntry)
        $targetIndex = $AppsRef.Count - 1
        $createdNewEntry = $true
    }

    $existingApp = $AppsRef[$targetIndex]
    $updatedApp = [pscustomobject]@{
        appId            = if ($NewAppId) { $NewAppId } else { $existingApp.appId }
        appName          = $existingApp.appName
        wingetId         = $existingApp.wingetId
        # A NewAppId means this call is reporting a just-succeeded Intune
        # creation, not just staging local metadata - and this tool only
        # ever creates win32LobApp objects, so the type is a known fact,
        # not something that needs fetching.
        intuneAppType    = if ($NewAppId) { "Windows app (Win32)" } else { $existingApp.intuneAppType }
        # Same reasoning as intuneAppType above, but version genuinely
        # ISN'T a known fact the way the type is - it comes from whatever
        # the caller fetched live from Intune (blank for a brand-new
        # create, where Intune hasn't necessarily processed/reported a
        # version yet), so it's only overwritten when the caller actually
        # supplied one, never blanked out just because this particular
        # call didn't have one to offer.
        intuneAppVersion = if ($IntuneAppVersion) { $IntuneAppVersion } else { $existingApp.intuneAppVersion }
        requiredFor      = @($existingApp.requiredFor)
        availableFor     = @($existingApp.availableFor)
        uninstallFor     = @($existingApp.uninstallFor)
        excludeFor       = @($existingApp.excludeFor)
        metadata         = $Metadata
    }
    $AppsRef[$targetIndex] = $updatedApp

    $saveSucceeded = Save-AppsToFile -Path $LinkedFilePath
    return @{ Success = $saveSucceeded; CreatedNewEntry = $createdNewEntry }
}

function Global:Get-IntuneCatalogDrift {
    # The exact three-way comparison Show-IntuneOnlyAppsDialog's own grid
    # is built from, pulled out so the same logic can also run headless
    # (no grid, just counts) for the startup drift check - two copies of
    # this same walk quietly drifting apart over time would be worse than
    # the small extra param-passing this costs.
    param([array]$Apps, [array]$IntuneApps)

    $catalogByNormName = @{}
    $catalogByAppId = @{}
    foreach ($app in $Apps) {
        $normName = ($app.appName.Trim() -replace '\s+', ' ')
        $catalogByNormName[$normName] = $true
        if ($app.appId) { $catalogByAppId[$app.appId] = $app }
    }

    # Every ID actually live in Intune right now, for the third comparison
    # direction below - a catalog entry can only be flagged as genuinely
    # deleted if its own stored ID isn't in this set at all, not just
    # absent from a name-based lookup.
    $intuneIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($ia in $IntuneApps) { [void]$intuneIds.Add($ia.id) }

    $missing = New-Object System.Collections.Generic.List[object]
    $renamed = New-Object System.Collections.Generic.List[object]
    foreach ($ia in $IntuneApps) {
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

function Global:Get-CatalogMetadataSimpleFields {
    return @(
        @{ Key = "description"; Label = "Description" }
        @{ Key = "publisher"; Label = "Publisher" }
        @{ Key = "owner"; Label = "Owner" }
        @{ Key = "developer"; Label = "Developer" }
        @{ Key = "informationUrl"; Label = "Information URL" }
        @{ Key = "privacyUrl"; Label = "Privacy URL" }
        @{ Key = "notes"; Label = "Notes" }
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

    # Same set already used elsewhere in this app (see the "not a Win32
    # app" guard in Show-CreateInIntuneDialog's own auto-fetch) to decide
    # whether this tool's Win32-shaped deploy flow applies to a given live
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
        $localDetSummary = if ($Local.detectionRule) { ConvertTo-DetectionRuleJson -DetectionRule $Local.detectionRule -IndentLevel 0 } else { "" }
        $remoteDetSummary = if ($Remote.detectionRule) { ConvertTo-DetectionRuleJson -DetectionRule $Remote.detectionRule -IndentLevel 0 } else { "" }
        if ($localDetSummary -ne $remoteDetSummary) {
            $diffs.Add([pscustomobject]@{ Field = "Detection rule"; Local = $localDetSummary; Remote = $remoteDetSummary })
        }

        $localRcSummary = if (@($Local.returnCodes).Count -gt 0) { (@($Local.returnCodes) | ConvertTo-Json -Compress -Depth 5) } else { "" }
        $remoteRcSummary = if (@($Remote.returnCodes).Count -gt 0) { (@($Remote.returnCodes) | ConvertTo-Json -Compress -Depth 5) } else { "" }
        if ($localRcSummary -ne $remoteRcSummary) {
            $diffs.Add([pscustomobject]@{ Field = "Return codes"; Local = $localRcSummary; Remote = $remoteRcSummary })
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
        # v10_2H20 - see the note next to $minOsMap in
        # Show-CreateInIntuneDialog.
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
    $safeName = $Name -replace '[<>:"/\\|?*]', ''
    $safeName = $safeName -replace '\s+', ' '
    $safeName = $safeName -replace '\s', '-'
    $safeName = $safeName -replace '[.-]+', '-'
    $safeName = $safeName.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = "App" }
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
    foreach ($file in @(Get-ChildItem -Path $Root -Recurse -Filter '*.intunewin' -File -ErrorAction SilentlyContinue)) {
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
    param([string]$AppName, [bool]$Uncommon, $Index)

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
    if (Test-Path $uncommonRoot) {
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
        requiredFor      = @($App.requiredFor)
        availableFor     = @($App.availableFor)
        uninstallFor     = @($App.uninstallFor)
        excludeFor       = @($App.excludeFor)
        metadata         = $App.metadata
    }
}

function Global:Get-FactoryAppSettings {
    <#
      The defaults this app ships with, as an object shaped exactly like
      $Global:App.DefaultAppSettings.

      One definition, because there were two: MainApp built these at
      startup and "Reset to built-in defaults" set each field again by
      hand in its own click handler. Two lists of the same twelve values
      drift the moment one is edited and the other is not, and nothing
      would have said so.

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
    }
}

function Global:Get-CreateAppTemplates {
    param([string]$WingetId, [bool]$Uncommon)

    if (-not $Uncommon -and $WingetId) {
        $install = "%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"C:\Program Files\Winget-AutoUpdate\Winget-Install.ps1`" -AppIDs `"$WingetId`""
        $uninstall = "%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"C:\Program Files\Winget-AutoUpdate\Winget-Install.ps1`" -AppIDs `"$WingetId`" -Uninstall"
        $detection = @"
`$AppToDetect = "$WingetId"

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
        installCommand   = $templates.Install
        uninstallCommand = $templates.Uninstall
        architecture     = $das.Architecture
        installContext   = $das.InstallContext
        minOSKey         = $das.MinOSKey
        detectionRule    = if ($templates.Detection) { [pscustomobject]@{ Type = "Script"; Script_Content = $templates.Detection } } else { $null }
        dependencies     = $defaultDeps
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
    $diffs = Get-CatalogMetadataFieldDiffs -Local $App.metadata -Remote $defaults
    return (@($diffs).Count -gt 0)
}
