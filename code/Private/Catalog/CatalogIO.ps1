function Global:ConvertTo-AppRecord {
    param($Raw)
    # Only present once metadata has actually been captured for an app
    # that doesn't exist in Intune yet (via Deploy to Intune's "Save for
    # later" option) - $null for every existing catalog entry until then,
    # so this stays fully backward compatible with every input.json
    # already in use.
    $metadata = $null
    if ($Raw.metadata) {
        $metadata = [pscustomobject]@{
            description      = [string]$Raw.metadata.description
            publisher        = [string]$Raw.metadata.publisher
            owner            = [string]$Raw.metadata.owner
            developer        = [string]$Raw.metadata.developer
            informationUrl   = [string]$Raw.metadata.informationUrl
            privacyUrl       = [string]$Raw.metadata.privacyUrl
            notes            = [string]$Raw.metadata.notes
            # Intune's "App version" (displayVersion) and "Show this as a
            # featured app in the Company Portal" (isFeatured) - the value
            # to push, not the version Intune last reported (that is the
            # top-level intuneAppVersion). $null, not "" or $false, when the
            # file predates these fields: "never recorded" is not "blank",
            # and the audit skips a field the catalog never had instead of
            # reporting every app with a version in Intune as different.
            appVersion       = if ($null -ne $Raw.metadata.appVersion) { [string]$Raw.metadata.appVersion } else { $null }
            isFeatured       = if ($null -ne $Raw.metadata.isFeatured) { [bool]$Raw.metadata.isFeatured } else { $null }
            installCommand   = [string]$Raw.metadata.installCommand
            uninstallCommand = [string]$Raw.metadata.uninstallCommand
            # Comma-joined selection string, same as what the Deploy dialog
            # already builds and the Create-app script already knows how to
            # route correctly (a single value to applicableArchitectures, a
            # comma-joined one to allowedArchitectures) - reusing that
            # existing, already-fixed logic rather than re-deciding here.
            architecture     = [string]$Raw.metadata.architecture
            installContext   = [string]$Raw.metadata.installContext
            minOSKey         = [string]$Raw.metadata.minOSKey
            # Kept as a generic object, not re-typed here - its shape
            # varies by detection type (Script/Msi/File/Registry), and it
            # already matches the exact $Config.DetectionRule shape the
            # Create-app script expects, so it can be passed straight
            # through unchanged at actual deploy time.
            detectionRule    = $Raw.metadata.detectionRule
            # By NAME, not App ID - at the point metadata gets saved, a
            # dependency being referenced might not have an App ID yet
            # either, if it's also still pending its own first deploy.
            # Resolved to actual App IDs only at batch-deploy time, once
            # dependencies have had a chance to be created first.
            dependencies     = @($Raw.metadata.dependencies)
            # Apps this one supersedes, by Intune App ID - usually an older
            # version that only exists in Intune, not in the catalog, which
            # is why it isn't by name like dependencies. $null when never
            # recorded: an update then keeps whatever Intune has, where []
            # would clear it.
            supersedes       = if ($null -ne $Raw.metadata.supersedes) {
                                   @(@($Raw.metadata.supersedes) | Where-Object { $_ -and $_.appId } | ForEach-Object {
                                       [pscustomobject]@{ appId = [string]$_.appId; name = [string]$_.name; type = $(if ([string]$_.type -eq 'replace') { 'replace' } else { 'update' }) }
                                   })
                               } else { $null }
            # Requirements and install-experience/return-code fields below
            # all confirmed directly against Microsoft's own win32LobApp
            # schema docs before being added - minimumFreeDiskSpaceInMB,
            # minimumMemoryInMB, minimumNumberOfProcessors, and
            # minimumCpuSpeedInMHz are top-level Int32 fields (0 means "not
            # required", matching the portal's own "No X required" wording
            # for an unset value); deviceRestartBehavior and
            # maxRunTimeInMinutes live inside installExperience;
            # allowAvailableUninstall is a top-level boolean, defaulting to
            # false per the docs if never set; returnCodes is a collection
            # of {returnCode, type} pairs, same shape already used
            # elsewhere in this app for the fixed default set.
            minDiskSpaceMB          = if ($null -ne $Raw.metadata.minDiskSpaceMB) { [int]$Raw.metadata.minDiskSpaceMB } else { 0 }
            minMemoryMB             = if ($null -ne $Raw.metadata.minMemoryMB) { [int]$Raw.metadata.minMemoryMB } else { 0 }
            minProcessors           = if ($null -ne $Raw.metadata.minProcessors) { [int]$Raw.metadata.minProcessors } else { 0 }
            minCpuSpeedMHz          = if ($null -ne $Raw.metadata.minCpuSpeedMHz) { [int]$Raw.metadata.minCpuSpeedMHz } else { 0 }
            installTimeMinutes      = if ($null -ne $Raw.metadata.installTimeMinutes) { [int]$Raw.metadata.installTimeMinutes } else { 60 }
            deviceRestartBehavior   = if ($Raw.metadata.deviceRestartBehavior) { [string]$Raw.metadata.deviceRestartBehavior } else { "basedOnReturnCode" }
            allowAvailableUninstall = [bool]$Raw.metadata.allowAvailableUninstall
            # Kept as generic objects, not re-typed - same {returnCode,
            # type} shape the Create-app script's own hardcoded default
            # already uses, so it can be passed straight through unchanged.
            returnCodes             = @($Raw.metadata.returnCodes)
        }
    }
    [pscustomobject]@{
        # A GUID or nothing. The ID is put into Graph addresses as is (the
        # delete step's included), so a catalog file with "../../groups/<id>"
        # here could aim them at something else entirely.
        appId        = $(if ([string]$Raw.appId -match '^[{(]?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}[)}]?$') { ([string]$Raw.appId).Trim('{', '}', '(', ')') } else { '' })
        appName      = [string]$Raw.appName
        wingetId     = [string]$Raw.wingetId
        # "uncommon" is no longer a stored field - see Test-AppIsUncommon.
        # Any stray "uncommon" key in an older input.json is simply ignored;
        # whether an app is common/uncommon is always derived from wingetId.
        #
        # Read-only, Intune-reported facts (not deployment config, so
        # deliberately siblings of appId/wingetId, not nested inside
        # metadata) - the app's actual @odata.type from Intune (e.g.
        # "Windows app (Win32)") and its displayVersion, if any. Blank
        # (missing from an older catalog file, or never synced yet) for
        # any app this hasn't been fetched for.
        intuneAppType    = [string]$Raw.intuneAppType
        intuneAppVersion = [string]$Raw.intuneAppVersion
        # Where this app's .intunewin actually is, when it is not where
        # Resolve-AppPackagePath would predict from the app's name. Blank
        # for almost every app, and blank is the right default: a derived
        # path follows a rename, a stored one does not. It exists for the
        # cases the prediction genuinely cannot reach - a package built
        # elsewhere, kept on a share, or a folder holding more than one
        # .intunewin, which that resolver refuses to guess between.
        #
        # Either a .intunewin file or a folder containing exactly one.
        packagePath      = [string]$Raw.packagePath
        # Filtered, not just wrapped in @() - a missing/null field in the
        # source JSON (an older catalog entry from before groups existed,
        # or hand-edited JSON) makes $Raw.requiredFor itself $null, and
        # @($null) in PowerShell is a ONE-element array containing $null,
        # not an empty array. Left unfiltered, that single $null element
        # then flows everywhere this field is read - inflating
        # @($_.requiredFor).Count to 1 for an app with genuinely zero
        # groups (miscounting it as "has a group" in every eligibility
        # check that relies on that Count), and reaching
        # a group list (CheckedListBox.Items.Add($null, ...) in the old window's
        # New-GroupRemovalBox, which throws ArgumentNullException outright.
        requiredFor  = @(@($Raw.requiredFor)  | Where-Object { $null -ne $_ })
        availableFor = @(@($Raw.availableFor) | Where-Object { $null -ne $_ })
        uninstallFor = @(@($Raw.uninstallFor) | Where-Object { $null -ne $_ })
        # Groups that must NOT get this app, whichever of the three lists
        # above would otherwise have covered them ("everyone in X except Y")
        excludeFor   = @(@($Raw.excludeFor)   | Where-Object { $null -ne $_ })
        # The app's icon for Intune and the Company Portal (PNG or JPEG,
        # base64) - kept in the app's own file so a rename, a backup and
        # Undo carry it along. Anything else in the field is dropped.
        icon         = (ConvertTo-AppIcon $Raw.icon)
        metadata     = $metadata
    }
}

function Global:ConvertTo-JsonStringLiteral {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`t", '\t').Replace("`r", '\r').Replace("`n", '\n')
    return '"' + $escaped + '"'
}

function Global:ConvertTo-DetectionRuleJson {
    param($DetectionRule, [int]$IndentLevel)

    if (-not $DetectionRule) { return "null" }
    $pad = "  " * $IndentLevel
    $innerPad = "  " * ($IndentLevel + 1)
    $fields = New-Object System.Collections.Generic.List[string]

    switch ([string]$DetectionRule.Type) {
        "Script" {
            $fields.Add("$innerPad`"Type`": $(ConvertTo-JsonStringLiteral 'Script')")
            # Normalized to `n here, not left as whatever the caller
            # happened to pass - this function serves BOTH the catalog
            # file's own actual persisted JSON (self-healing any stray
            # `r`n forward, e.g. from a Windows text box round-trip) and
            # every metadata-drift comparison in the app (Show-
            # CreateInIntuneDialog, CatalogLogic.ps1's own Get-
            # CatalogMetadataFieldDiffs) - a line-ending-only difference
            # between two functionally-identical scripts is not a real
            # change and must never surface as one (confirmed live: an
            # unrelated field edit alone made "Detection rule" show up as
            # differing between local and Intune).
            # .TrimEnd() on top of that, not just the `r`n->`n swap above -
            # confirmed live (WinMerge): Intune's own copy of a script can
            # come back with a trailing `r`n where the local catalog copy
            # has a trailing `n (or none at all) - same harmless "how many/
            # what kind of newline(s) sit after the last real line"
            # non-difference, just at the very end of the string instead of
            # mid-script, and trailing whitespace of any kind after a
            # script's last real line never changes what it does when run.
            $fields.Add("$innerPad`"Script_Content`": $(ConvertTo-JsonStringLiteral ((ConvertTo-CanonicalLineEndings $DetectionRule.Script_Content).TrimEnd()))")
        }
        "Msi" {
            $fields.Add("$innerPad`"Type`": $(ConvertTo-JsonStringLiteral 'Msi')")
            $fields.Add("$innerPad`"Msi_ProductCode`": $(ConvertTo-JsonStringLiteral $DetectionRule.Msi_ProductCode)")
            $fields.Add("$innerPad`"Msi_VersionOperator`": $(ConvertTo-JsonStringLiteral $DetectionRule.Msi_VersionOperator)")
            $fields.Add("$innerPad`"Msi_Version`": $(ConvertTo-JsonStringLiteral $DetectionRule.Msi_Version)")
        }
        "File" {
            $fields.Add("$innerPad`"Type`": $(ConvertTo-JsonStringLiteral 'File')")
            $fields.Add("$innerPad`"File_Path`": $(ConvertTo-JsonStringLiteral $DetectionRule.File_Path)")
            $fields.Add("$innerPad`"File_Name`": $(ConvertTo-JsonStringLiteral $DetectionRule.File_Name)")
            $fields.Add("$innerPad`"File_Check32Bit`": $(if ($DetectionRule.File_Check32Bit) { 'true' } else { 'false' })")
            $fields.Add("$innerPad`"File_DetectionType`": $(ConvertTo-JsonStringLiteral $DetectionRule.File_DetectionType)")
            $fields.Add("$innerPad`"File_Operator`": $(ConvertTo-JsonStringLiteral $DetectionRule.File_Operator)")
            $fields.Add("$innerPad`"File_DetectionValue`": $(ConvertTo-JsonStringLiteral $DetectionRule.File_DetectionValue)")
        }
        "Registry" {
            $fields.Add("$innerPad`"Type`": $(ConvertTo-JsonStringLiteral 'Registry')")
            $fields.Add("$innerPad`"Reg_KeyPath`": $(ConvertTo-JsonStringLiteral $DetectionRule.Reg_KeyPath)")
            $fields.Add("$innerPad`"Reg_ValueName`": $(ConvertTo-JsonStringLiteral $DetectionRule.Reg_ValueName)")
            $fields.Add("$innerPad`"Reg_Check32Bit`": $(if ($DetectionRule.Reg_Check32Bit) { 'true' } else { 'false' })")
            $fields.Add("$innerPad`"Reg_DetectionType`": $(ConvertTo-JsonStringLiteral $DetectionRule.Reg_DetectionType)")
            $fields.Add("$innerPad`"Reg_Operator`": $(ConvertTo-JsonStringLiteral $DetectionRule.Reg_Operator)")
            $fields.Add("$innerPad`"Reg_DetectionValue`": $(ConvertTo-JsonStringLiteral $DetectionRule.Reg_DetectionValue)")
        }
        default {
            # Shouldn't happen given the UI only ever produces these four
            # types, but falls back to null rather than silently dropping
            # data or producing invalid JSON if it ever does.
            return "null"
        }
    }
    return "{`r`n" + ($fields -join ",`r`n") + "`r`n$pad}"
}

function Global:ConvertTo-JsonStringArray {
    param([string[]]$Items, [int]$IndentLevel)
    # Filters out null/empty entries explicitly, not just wraps and
    # counts - PowerShell coerces a $null element into an empty string
    # "" when binding to this [string[]] parameter, rather than leaving
    # it $null, so @($null) becoming a one-element array here doesn't
    # produce invalid JSON the way it did in the returnCodes case
    # elsewhere - but it DOES produce a real, silently wrong result:
    # ["",] instead of [] for a field that was actually empty/unset. A
    # genuine group or dependency name is never blank in practice, so
    # filtering these out is always correct, not just a defensive
    # workaround.
    $items = @($Items | Where-Object { $_ -and $_.Trim() })
    $pad = "  " * $IndentLevel
    if ($items.Count -eq 0) { return "[]" }
    $lines = for ($j = 0; $j -lt $items.Count; $j++) {
        $comma = if ($j -lt $items.Count - 1) { "," } else { "" }
        "$pad  $(ConvertTo-JsonStringLiteral $items[$j])$comma"
    }
    return "[`r`n" + ($lines -join "`r`n") + "`r`n$pad]"
}

function Global:ConvertTo-AppIcon {
    # Pure: an icon as @{ type; value } when it is a PNG or JPEG in base64 of at most 750 KB, else $null.
    param($Icon)
    if (-not $Icon) { return $null }
    $type = [string]$Icon.type; $value = ([string]$Icon.value) -replace '\s', ''
    if ($type -notin 'image/png', 'image/jpeg') { return $null }
    if (-not $value -or $value.Length -gt 1000000 -or $value -notmatch '^[A-Za-z0-9+/]+={0,2}$') { return $null }
    return [pscustomobject]@{ type = $type; value = $value }
}

function Global:ConvertTo-SupersedenceJson {
    # metadata.supersedes, hand-rolled like the rest of this file. $null
    # (never recorded) is written as null, not [] - an empty list means
    # "supersedes nothing" and an update would clear Intune's to match,
    # while null means "leave Intune's alone".
    param($Entries, [int]$IndentLevel = 0)
    if ($null -eq $Entries) { return "null" }
    $items = @(@($Entries) | Where-Object { $_ -and $_.appId })
    if ($items.Count -eq 0) { return "[]" }
    $pad = "  " * $IndentLevel
    $lines = for ($j = 0; $j -lt $items.Count; $j++) {
        $comma = if ($j -lt $items.Count - 1) { "," } else { "" }
        "$pad  { `"appId`": $(ConvertTo-JsonStringLiteral ([string]$items[$j].appId)), `"name`": $(ConvertTo-JsonStringLiteral ([string]$items[$j].name)), `"type`": $(ConvertTo-JsonStringLiteral ([string]$items[$j].type)) }$comma"
    }
    return "[`r`n" + ($lines -join "`r`n") + "`r`n$pad]"
}

function Global:ConvertTo-SingleAppJson {
    param($App)

    $fields = New-Object System.Collections.Generic.List[string]
    $fields.Add("  `"appId`": $(ConvertTo-JsonStringLiteral $App.appId)")
    $fields.Add("  `"appName`": $(ConvertTo-JsonStringLiteral $App.appName)")
    if ($App.wingetId) {
        $fields.Add("  `"wingetId`": $(ConvertTo-JsonStringLiteral $App.wingetId)")
    }
    if ($App.intuneAppType) {
        $fields.Add("  `"intuneAppType`": $(ConvertTo-JsonStringLiteral $App.intuneAppType)")
    }
    if ($App.intuneAppVersion) {
        $fields.Add("  `"intuneAppVersion`": $(ConvertTo-JsonStringLiteral $App.intuneAppVersion)")
    }
    # Written only when set, like every optional field above. This file
    # builds its JSON field by field rather than serialising the object,
    # so a new field that is not added here is read back (ConvertTo-
    # AppRecord knows it), held in memory, shown in the editor - and
    # silently dropped the moment the catalog is saved.
    if ($App.packagePath) {
        $fields.Add("  `"packagePath`": $(ConvertTo-JsonStringLiteral $App.packagePath)")
    }
    if ($App.icon -and $App.icon.value) {
        $fields.Add("  `"icon`": { `"type`": $(ConvertTo-JsonStringLiteral ([string]$App.icon.type)), `"value`": $(ConvertTo-JsonStringLiteral ([string]$App.icon.value)) }")
    }
    $fields.Add("  `"requiredFor`": $(ConvertTo-JsonStringArray -Items @($App.requiredFor) -IndentLevel 1)")
    $fields.Add("  `"availableFor`": $(ConvertTo-JsonStringArray -Items @($App.availableFor) -IndentLevel 1)")
    $fields.Add("  `"excludeFor`": $(ConvertTo-JsonStringArray -Items @($App.excludeFor) -IndentLevel 1)")
    $fields.Add("  `"uninstallFor`": $(ConvertTo-JsonStringArray -Items @($App.uninstallFor) -IndentLevel 1)")
    if ($App.metadata) {
        # Fully hand-rolled now, matching this whole file's style
        # throughout, rather than routing metadata through ConvertTo-Json
        # (previously the case here, and confirmed, directly and
        # repeatedly, to sometimes silently produce a completely empty
        # result with no error at all for certain inputs elsewhere in
        # this file). detectionRule is the one field with a genuinely
        # variable shape (Script/Msi/File/Registry), handled by its own
        # small, dedicated hand-rolled serializer above rather than
        # ConvertTo-Json - removing that cmdlet from this path entirely,
        # not just working around its known failure mode.
        $m = $App.metadata
        $metaFields = New-Object System.Collections.Generic.List[string]
        $metaFields.Add("    `"description`": $(ConvertTo-JsonStringLiteral $m.description)")
        $metaFields.Add("    `"publisher`": $(ConvertTo-JsonStringLiteral $m.publisher)")
        $metaFields.Add("    `"owner`": $(ConvertTo-JsonStringLiteral $m.owner)")
        $metaFields.Add("    `"developer`": $(ConvertTo-JsonStringLiteral $m.developer)")
        $metaFields.Add("    `"informationUrl`": $(ConvertTo-JsonStringLiteral $m.informationUrl)")
        $metaFields.Add("    `"privacyUrl`": $(ConvertTo-JsonStringLiteral $m.privacyUrl)")
        $metaFields.Add("    `"notes`": $(ConvertTo-JsonStringLiteral $m.notes)")
        # null stays null - see ConvertTo-AppRecord
        $metaFields.Add("    `"appVersion`": $(if ($null -ne $m.appVersion) { ConvertTo-JsonStringLiteral ([string]$m.appVersion) } else { 'null' })")
        $metaFields.Add("    `"isFeatured`": $(if ($null -eq $m.isFeatured) { 'null' } elseif ($m.isFeatured) { 'true' } else { 'false' })")
        $metaFields.Add("    `"installCommand`": $(ConvertTo-JsonStringLiteral $m.installCommand)")
        $metaFields.Add("    `"uninstallCommand`": $(ConvertTo-JsonStringLiteral $m.uninstallCommand)")
        $metaFields.Add("    `"architecture`": $(ConvertTo-JsonStringLiteral $m.architecture)")
        $metaFields.Add("    `"installContext`": $(ConvertTo-JsonStringLiteral $m.installContext)")
        $metaFields.Add("    `"minOSKey`": $(ConvertTo-JsonStringLiteral $m.minOSKey)")
        $metaFields.Add("    `"detectionRule`": $(ConvertTo-DetectionRuleJson -DetectionRule $m.detectionRule -IndentLevel 2)")
        $metaFields.Add("    `"dependencies`": $(ConvertTo-JsonStringArray -Items @($m.dependencies) -IndentLevel 2)")
        $metaFields.Add("    `"supersedes`": $(ConvertTo-SupersedenceJson -Entries $m.supersedes -IndentLevel 2)")
        # Numeric fields explicitly default to "null" (valid JSON) rather
        # than interpolating $null directly, which would produce
        # "minDiskSpaceMB": , with nothing before the comma - invalid
        # JSON. Matters for apps saved before these fields existed at
        # all, where they'd genuinely be $null rather than 0.
        $metaFields.Add("    `"minDiskSpaceMB`": $(if ($null -ne $m.minDiskSpaceMB) { $m.minDiskSpaceMB } else { 'null' })")
        $metaFields.Add("    `"minMemoryMB`": $(if ($null -ne $m.minMemoryMB) { $m.minMemoryMB } else { 'null' })")
        $metaFields.Add("    `"minProcessors`": $(if ($null -ne $m.minProcessors) { $m.minProcessors } else { 'null' })")
        $metaFields.Add("    `"minCpuSpeedMHz`": $(if ($null -ne $m.minCpuSpeedMHz) { $m.minCpuSpeedMHz } else { 'null' })")
        $metaFields.Add("    `"installTimeMinutes`": $(if ($null -ne $m.installTimeMinutes) { $m.installTimeMinutes } else { 'null' })")
        $metaFields.Add("    `"deviceRestartBehavior`": $(ConvertTo-JsonStringLiteral $m.deviceRestartBehavior)")
        $metaFields.Add("    `"allowAvailableUninstall`": $(if ($m.allowAvailableUninstall) { 'true' } else { 'false' })")
        # Filters out $null explicitly before counting, rather than
        # trusting @($m.returnCodes).Count alone - confirmed, directly,
        # that PowerShell's @() doesn't turn a genuinely null value into
        # an empty array the way it does for an empty array or $null
        # element inside a real array. @($null) produces a ONE-element
        # array containing $null, not zero elements - so apps whose
        # returnCodes was never set at all (loaded from data that
        # predates this field) fell through to the "build real entries"
        # branch with one phantom null item, and interpolating $null
        # produced "returnCode": with nothing before the comma: invalid
        # JSON that then failed to parse and got silently skipped on
        # every subsequent load.
        # Also filters out any entry that IS a real (non-null) object but
        # still has a $null returnCode - the "$null piped into
        # ForEach-Object still runs once" quirk documented where
        # metadata.returnCodes gets built (e.g. non-Win32 apps like
        # "Microsoft Store app (new)", which Graph never returns
        # returnCodes for at all) produces exactly this shape, and it's
        # not caught by the plain-truthiness filter above since the
        # object itself is truthy even though its returnCode isn't.
        $rcItems = @($m.returnCodes | Where-Object { $_ -and $null -ne $_.returnCode })
        if ($rcItems.Count -eq 0) {
            $metaFields.Add("    `"returnCodes`": []")
        }
        else {
            $rcLines = for ($j = 0; $j -lt $rcItems.Count; $j++) {
                $comma = if ($j -lt $rcItems.Count - 1) { "," } else { "" }
                "      { `"returnCode`": $($rcItems[$j].returnCode), `"type`": $(ConvertTo-JsonStringLiteral $rcItems[$j].type) }$comma"
            }
            $metaFields.Add("    `"returnCodes`": [`r`n" + ($rcLines -join "`r`n") + "`r`n    ]")
        }
        $fields.Add("  `"metadata`": {`r`n" + ($metaFields -join ",`r`n") + "`r`n  }")
    }

    return "{`r`n" + ($fields -join ",`r`n") + "`r`n}"
}

function Global:ConvertTo-CreateAppConfigJson {
    param($Config)

    $fields = New-Object System.Collections.Generic.List[string]
    $fields.Add("  `"TenantId`": $(ConvertTo-JsonStringLiteral $Config.TenantId)")
    $fields.Add("  `"ClientId`": $(ConvertTo-JsonStringLiteral $Config.ClientId)")
    $fields.Add("  `"CertificateThumbprint`": $(ConvertTo-JsonStringLiteral $Config.CertificateThumbprint)")
    $fields.Add("  `"Mode`": $(ConvertTo-JsonStringLiteral $Config.Mode)")
    $fields.Add("  `"ExistingAppId`": $(ConvertTo-JsonStringLiteral $Config.ExistingAppId)")
    $fields.Add("  `"AppName`": $(ConvertTo-JsonStringLiteral $Config.AppName)")
    $fields.Add("  `"Description`": $(ConvertTo-JsonStringLiteral $Config.Description)")
    $fields.Add("  `"Publisher`": $(ConvertTo-JsonStringLiteral $Config.Publisher)")
    $fields.Add("  `"Owner`": $(ConvertTo-JsonStringLiteral $Config.Owner)")
    $fields.Add("  `"Developer`": $(ConvertTo-JsonStringLiteral $Config.Developer)")
    $fields.Add("  `"InformationUrl`": $(ConvertTo-JsonStringLiteral $Config.InformationUrl)")
    $fields.Add("  `"PrivacyUrl`": $(ConvertTo-JsonStringLiteral $Config.PrivacyUrl)")
    $fields.Add("  `"Notes`": $(ConvertTo-JsonStringLiteral $Config.Notes)")
    $fields.Add("  `"AppVersion`": $(ConvertTo-JsonStringLiteral ([string]$Config.AppVersion))")
    # null = leave Intune's setting alone (a catalog entry that never
    # recorded it must not switch a portal-set featured app off)
    $fields.Add("  `"IsFeatured`": $(if ($null -eq $Config.IsFeatured) { 'null' } elseif ($Config.IsFeatured) { 'true' } else { 'false' })")
    $fields.Add("  `"InstallCommand`": $(ConvertTo-JsonStringLiteral $Config.InstallCommand)")
    $fields.Add("  `"UninstallCommand`": $(ConvertTo-JsonStringLiteral $Config.UninstallCommand)")

    # DetectionRule now uses the same shared, hand-rolled serializer as
    # the catalog's own metadata.detectionRule, rather than its own
    # separate ConvertTo-Json call - removes ConvertTo-Json from this
    # path entirely, and keeps this field's formatting visually
    # consistent with the rest of this file wherever it's serialized.
    $fields.Add("  `"DetectionRule`": $(ConvertTo-DetectionRuleJson -DetectionRule $Config.DetectionRule -IndentLevel 1)")

    $fields.Add("  `"InstallContext`": $(ConvertTo-JsonStringLiteral $Config.InstallContext)")
    $fields.Add("  `"Architecture`": $(ConvertTo-JsonStringLiteral $Config.Architecture)")
    $fields.Add("  `"MinOSVersionKey`": $(ConvertTo-JsonStringLiteral $Config.MinOSVersionKey)")
    $fields.Add("  `"PackagePath`": $(ConvertTo-JsonStringLiteral $Config.PackagePath)")
    $fields.Add("  `"DependencyAppIds`": $(ConvertTo-JsonStringArray -Items @($Config.DependencyAppIds) -IndentLevel 1)")
    # Supersedence: SupersedenceSet false (the catalog never recorded any)
    # keeps Intune's on an update - see CreateApp.ps1's Get-ConfigSupersedence.
    $supersedenceItems = @(@($Config.Supersedence) | Where-Object { $_ -and $_.appId })
    $fields.Add("  `"SupersedenceSet`": $(if ($null -ne $Config.Supersedence) { 'true' } else { 'false' })")
    if ($supersedenceItems.Count -eq 0) {
        $fields.Add("  `"Supersedence`": []")
    }
    else {
        $supLines = for ($j = 0; $j -lt $supersedenceItems.Count; $j++) {
            $comma = if ($j -lt $supersedenceItems.Count - 1) { "," } else { "" }
            "    { `"targetId`": $(ConvertTo-JsonStringLiteral ([string]$supersedenceItems[$j].appId)), `"supersedenceType`": $(ConvertTo-JsonStringLiteral ([string]$supersedenceItems[$j].type)) }$comma"
        }
        $fields.Add("  `"Supersedence`": [`r`n" + ($supLines -join "`r`n") + "`r`n  ]")
    }
    $fields.Add("  `"ReplaceContent`": $(if ($Config.ReplaceContent) { 'true' } else { 'false' })")
    $fields.Add("  `"LargeIcon`": $(if ($Config.LargeIcon -and $Config.LargeIcon.value) { "{ `"type`": $(ConvertTo-JsonStringLiteral ([string]$Config.LargeIcon.type)), `"value`": $(ConvertTo-JsonStringLiteral ([string]$Config.LargeIcon.value)) }" } else { 'null' })")
    $fields.Add("  `"MinDiskSpaceMB`": $($Config.MinDiskSpaceMB)")
    $fields.Add("  `"MinMemoryMB`": $($Config.MinMemoryMB)")
    $fields.Add("  `"MinProcessors`": $($Config.MinProcessors)")
    $fields.Add("  `"MinCpuSpeedMHz`": $($Config.MinCpuSpeedMHz)")
    $fields.Add("  `"InstallTimeMinutes`": $($Config.InstallTimeMinutes)")
    $fields.Add("  `"DeviceRestartBehavior`": $(ConvertTo-JsonStringLiteral $Config.DeviceRestartBehavior)")
    $fields.Add("  `"AllowAvailableUninstall`": $(if ($Config.AllowAvailableUninstall) { 'true' } else { 'false' })")

    # Filters out $null explicitly - same reasoning as the identical
    # pattern in ConvertTo-SingleAppJson: @($x) alone doesn't produce an
    # empty array when $x is genuinely $null, it produces a one-element
    # array containing that $null.
    $rcItems = @($Config.ReturnCodes | Where-Object { $_ })
    if ($rcItems.Count -eq 0) {
        $fields.Add("  `"ReturnCodes`": []")
    }
    else {
        $rcLines = for ($j = 0; $j -lt $rcItems.Count; $j++) {
            $comma = if ($j -lt $rcItems.Count - 1) { "," } else { "" }
            "    { `"returnCode`": $($rcItems[$j].returnCode), `"type`": $(ConvertTo-JsonStringLiteral $rcItems[$j].type) }$comma"
        }
        $fields.Add("  `"ReturnCodes`": [`r`n" + ($rcLines -join "`r`n") + "`r`n  ]")
    }

    $fields.Add("  `"OutputResultPath`": $(ConvertTo-JsonStringLiteral $Config.OutputResultPath)")

    return "{`r`n" + ($fields -join ",`r`n") + "`r`n}"
}

function Global:Get-AllKnownGroups {
    $set = New-Object System.Collections.Generic.HashSet[string]
    foreach ($app in $Global:App.Apps) {
        foreach ($g in @($app.requiredFor))  { [void]$set.Add($g) }
        foreach ($g in @($app.availableFor)) { [void]$set.Add($g) }
        foreach ($g in @($app.uninstallFor)) { [void]$set.Add($g) }
    }
    return ($set | Sort-Object)
}

function Global:Load-LastAuditCache {
    if (-not (Test-Path -LiteralPath $Global:App.LastAuditCachePath)) { return }
    try {
        # -Encoding UTF8 explicitly, same reasoning as Import-AppsFromFile/
        # Import-GraphSettings - Save-LastAuditCache's own Set-Content
        # -Encoding UTF8 writes a BOM under Windows PowerShell 5.1, which
        # happens to make auto-detection work today, but that's the writer's
        # accident to rely on, not this reader's guarantee.
        $raw = Get-Content -LiteralPath $Global:App.LastAuditCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $skipped = 0
        foreach ($prop in $raw.PSObject.Properties) {
            # Wrapped in its OWN try/catch, per entry - this used to be one
            # big try around the whole loop, so ONE bad entry threw and
            # silently dropped every remaining app too, not just itself.
            # Confirmed live: a cache written by Windows PowerShell 5.1 has
            # $entry.Timestamp as a NESTED object (5.1's ConvertTo-Json
            # serializes [datetime] as {value="/Date(...)/"; DisplayHint;
            # DateTime}, unlike PowerShell 7's plain ISO string) - a bare
            # [datetime]$entry.Timestamp cast on that threw on the very
            # FIRST entry, which is exactly what made every app show "Never
            # audited" after a restart despite the file being right there,
            # full of valid data. Set-LastAuditCacheEntry now writes
            # Timestamp as an explicit .ToString("o") string specifically to
            # stop relying on ConvertTo-Json's per-PowerShell-version
            # datetime shape at all - the fallback below only exists to
            # still read a cache file written before that fix.
            try {
                $entry = $prop.Value
                $tsRaw = $entry.Timestamp
                $ts = if ($tsRaw -is [string]) {
                    [datetime]$tsRaw
                }
                elseif ($tsRaw.PSObject.Properties.Name -contains 'value') {
                    # $tsRaw.value itself is ALSO version-dependent: Windows
                    # PowerShell 5.1's ConvertFrom-Json leaves it as the raw
                    # "/Date(1234567890123)/" string, but PowerShell 7's
                    # ConvertFrom-Json recognizes that same convention and
                    # already hands back a real [datetime] - confirmed by
                    # directly testing both shapes, not assumed.
                    if ($tsRaw.value -is [datetime]) {
                        $tsRaw.value
                    }
                    else {
                        $ms = [int64]([regex]::Match([string]$tsRaw.value, '-?\d+').Value)
                        [DateTimeOffset]::FromUnixTimeMilliseconds($ms).LocalDateTime
                    }
                }
                else {
                    [datetime]$tsRaw
                }
                # Per-check times (see Set-LastAuditCacheEntry). A cache
                # written before they existed has only the one Timestamp,
                # which then stands for every check it holds.
                $checkedIn = [ordered]@{}
                foreach ($name in 'Metadata', 'Groups', 'Dependencies', 'Unknown') {
                    $stamp = if ($entry.Checked -and $entry.Checked.$name) { $entry.Checked.$name } elseif ($null -ne $entry.$name) { $ts } else { $null }
                    $checkedIn[$name] = if ($stamp) { ([datetime]$stamp).ToString("o") } else { $null }
                }
                $Global:App.LastAuditResults[$prop.Name] = [pscustomobject]@{
                    Timestamp    = $ts
                    Metadata     = $entry.Metadata
                    Groups       = $entry.Groups
                    Dependencies = $entry.Dependencies
                    Unknown      = $entry.Unknown
                    Checked      = [pscustomobject]$checkedIn
                }
            }
            catch {
                $skipped++
            }
        }
        if ($skipped -gt 0) {
            Write-Log "[WARN] Skipped $skipped unreadable entr$(if ($skipped -eq 1) { 'y' } else { 'ies' }) in the last-audit cache - re-run an audit for those app(s).`r`n"
        }
    }
    catch {
        # Logged, not silent: a load failure looked exactly like "the audit
        # cache doesn't persist across a restart", with nothing to say why.
        Write-Log "[WARN] Could not load the last-audit cache ($($Global:App.LastAuditCachePath)): $($_.Exception.Message)`r`n"
    }
}

function Global:Save-LastAuditCache {
    try {
        $Global:App.LastAuditResults | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Global:App.LastAuditCachePath -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # See the matching note in Load-LastAuditCache above - same reasoning.
        Write-Log "[WARN] Could not save the last-audit cache ($($Global:App.LastAuditCachePath)): $($_.Exception.Message)`r`n"
    }
}

function Global:Set-LastAuditCacheEntry {
    param([string]$AppName, [string]$Metadata, [string]$Groups, [string]$Dependencies, [string]$Unknown)

    # $PSBoundParameters, not a $null check on the parameter itself - a
    # [string] parameter that's simply never PASSED still comes back as ""
    # (empty string), not $null, once PowerShell's parameter binder is done
    # with it - confirmed live, not a guess. A $null check here was
    # therefore treating "this field wasn't part of THIS call" the same as
    # "this field really is blank", clobbering whichever of the two fetches
    # (Metadata/Groups/Dependencies vs Unknown) finished SECOND for an app
    # over what the other one had just written - a real, confirmed-live bug
    # (every field the second call's caller didn't pass got reset to "",
    # which then counted as a false "issue" in Get-LastAuditSummary below).
    $existing = if ($Global:App.LastAuditResults.ContainsKey($AppName)) { $Global:App.LastAuditResults[$AppName] } else { $null }

    # When each of the four was last checked, not just the entry as a
    # whole. One shared Timestamp, moved to "now" by any partial write,
    # made a Groups-only check (the app editor's) show five-day-old
    # Metadata as "just now". Timestamp stays - everything reads it - but
    # is now the OLDEST of the four, so an age never overstates freshness.
    #
    # ISO-8601 strings ("o" - round-trip format), not raw [datetime]s -
    # ConvertTo-Json's own serialization of [datetime] differs between
    # PowerShell versions (see Load-LastAuditCache's note on this same
    # field), so writing them as already-plain strings sidesteps that.
    $now = (Get-Date).ToString("o")
    $oldEntryTime = if ($existing -and $existing.Timestamp) { ([datetime]$existing.Timestamp).ToString("o") } else { $null }
    $fields = [ordered]@{
        Metadata     = @{ Given = $PSBoundParameters.ContainsKey('Metadata');     Value = $Metadata }
        Groups       = @{ Given = $PSBoundParameters.ContainsKey('Groups');       Value = $Groups }
        Dependencies = @{ Given = $PSBoundParameters.ContainsKey('Dependencies'); Value = $Dependencies }
        Unknown      = @{ Given = $PSBoundParameters.ContainsKey('Unknown');      Value = $Unknown }
    }
    $values = [ordered]@{}
    $checked = [ordered]@{}
    foreach ($name in $fields.Keys) {
        if ($fields[$name].Given) {
            $values[$name] = $fields[$name].Value
            $checked[$name] = $now
            continue
        }
        $values[$name] = if ($existing) { $existing.$name } else { $null }
        $checked[$name] = if ($null -eq $values[$name]) { $null }
                          elseif ($existing -and $existing.Checked -and $existing.Checked.$name) { ([datetime]$existing.Checked.$name).ToString("o") }
                          else { $oldEntryTime }
    }
    $oldest = @($checked.Values | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object) | Select-Object -First 1
    $Global:App.LastAuditResults[$AppName] = [pscustomobject]@{
        Timestamp    = if ($oldest) { $oldest.ToString("o") } else { $now }
        Metadata     = $values.Metadata
        Groups       = $values.Groups
        Dependencies = $values.Dependencies
        Unknown      = $values.Unknown
        Checked      = [pscustomobject]$checked
    }
}
