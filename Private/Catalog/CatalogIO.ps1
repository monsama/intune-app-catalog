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
        appId        = [string]$Raw.appId
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
        # Filtered, not just wrapped in @() - a missing/null field in the
        # source JSON (an older catalog entry from before groups existed,
        # or hand-edited JSON) makes $Raw.requiredFor itself $null, and
        # @($null) in PowerShell is a ONE-element array containing $null,
        # not an empty array. Left unfiltered, that single $null element
        # then flows everywhere this field is read - inflating
        # @($_.requiredFor).Count to 1 for an app with genuinely zero
        # groups (miscounting it as "has a group" in every eligibility
        # check that relies on that Count), and reaching
        # CheckedListBox.Items.Add($null, ...) in Show-RemoveGroupFromAppsDialog's
        # New-GroupRemovalBox, which throws ArgumentNullException outright.
        requiredFor  = @(@($Raw.requiredFor)  | Where-Object { $null -ne $_ })
        availableFor = @(@($Raw.availableFor) | Where-Object { $null -ne $_ })
        uninstallFor = @(@($Raw.uninstallFor) | Where-Object { $null -ne $_ })
        metadata     = $metadata
    }
}

function Global:Import-AppsFromFile {
    param([string]$Path)

    # Every (re)load is a fresh catalog as far as the Type/Version
    # backfill is concerned - see Start-TypeVersionBackfill and
    # $Global:App.TypeVersionBackfillDone.
    $Global:App.TypeVersionBackfillDone = $false
    # See $Global:App.CatalogGeneration's own comment in MainApp.ps1 - this
    # invalidates any backfill queue still in flight from whatever was
    # loaded before this call.
    $Global:App.CatalogGeneration++

    # One-time automatic migration: if the new per-app folder doesn't exist
    # or is empty, but the OLD single-file input.json does, split it into
    # per-app files now rather than starting with an empty catalog. The
    # old file is renamed, not deleted, afterward - kept as a safety net
    # until the new format has actually proven itself in practice.
    $hasFolderData = (Test-Path $Path) -and (@(Get-ChildItem -Path $Path -Filter "*.json" -ErrorAction SilentlyContinue).Count -gt 0)
    if (-not $hasFolderData) {
        $oldSingleFilePath = Join-Path $Global:App.RootPath "input.json"
        if (Test-Path $oldSingleFilePath) {
            try {
                # -Encoding UTF8 explicitly - same reasoning as the per-app
                # file read further below in this function.
                $rawOld = Get-Content -Path $oldSingleFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -eq $rawOld) { $rawOld = @() }
                if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                $migratedCount = 0
                foreach ($item in @($rawOld)) {
                    $record = ConvertTo-AppRecord $item
                    $fileName = (Get-SafeFileNameForApp -Name $record.appName) + ".json"
                    $filePath = Join-Path $Path $fileName
                    $json = ConvertTo-SingleAppJson -App $record
                    [System.IO.File]::WriteAllText($filePath, $json, $utf8NoBom)
                    $migratedCount++
                }
                $migratedBackupName = "input.json.migrated-$(Get-Date -Format 'yyyy-MM-dd_HHmmss')"
                Rename-Item -Path $oldSingleFilePath -NewName $migratedBackupName -Force -ErrorAction SilentlyContinue
                [System.Windows.Forms.MessageBox]::Show(
                    "Migrated $migratedCount app(s) from the old single input.json into one file per app in:`n$Path`n`nThe old file was kept, renamed to:`n$migratedBackupName",
                    "Migrated to per-app files", "OK", "Information") | Out-Null
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Found an old input.json to migrate, but migration failed:`n$($_.Exception.Message)`n`nStarting with an empty catalog instead - the old file was left untouched, nothing was lost.",
                    "Migration failed", "OK", "Error") | Out-Null
            }
        }
    }

    if (-not (Test-Path $Path)) {
        [System.Windows.Forms.MessageBox]::Show(
            "No app data found at:`n$Path`n`nStarting with an empty catalog. Use Save to create it.",
            "No data found", "OK", "Warning") | Out-Null
        $Global:App.Apps.Clear()
        return
    }

    try {
        $files = @(Get-ChildItem -Path $Path -Filter "*.json" -ErrorAction SilentlyContinue)
        $Global:App.Apps.Clear()
        # One bad file no longer takes down the whole catalog load - each
        # app's file is now completely independent of every other one,
        # unlike the old single-array format where a single syntax error
        # anywhere broke loading everything, not just the one entry near it.
        $failedFiles = New-Object System.Collections.Generic.List[string]
        foreach ($file in $files) {
            try {
                # -Encoding UTF8 explicitly, not left to Get-Content's own
                # default - these files are always written BOM-less UTF-8
                # (see Save-AppsToFile's $utf8NoBom), but under Windows
                # PowerShell 5.1 (not pwsh 7, where UTF-8 is already the
                # no-BOM default), Get-Content falls back to the system's
                # ANSI codepage for any file with no BOM. That silently
                # re-corrupted every non-ASCII character (curly quotes, em
                # dashes, accented names) on EVERY load, even for text that
                # was perfectly clean on disk - confirmed as the actual
                # cause of a live report where "Sync metadata..." fixed a
                # field's mojibake, the very next audit in the same session
                # showed it fixed, and then it came back exactly as before
                # after simply restarting the app (no editing in between) -
                # this read-time corruption, not the write path, was reintroducing it.
                $rawText = Get-Content -Path $file.FullName -Raw -Encoding UTF8
                try {
                    $raw = $rawText | ConvertFrom-Json
                }
                catch {
                    # Self-heals the one specific corruption pattern the
                    # $null-pipe returnCodes bug above used to write to disk
                    # before it was fixed: "returnCode": , (nothing before
                    # the comma) instead of valid JSON. Files already saved
                    # with this corruption (typically non-Win32 apps like
                    # "Microsoft Store app (new)", which Graph never returns
                    # returnCodes for) would otherwise stay permanently
                    # unparseable and silently vanish from the catalog on
                    # every load, even after the writer itself was fixed -
                    # only fixing new writes doesn't help a file already
                    # broken on disk. Re-throws the original error if this
                    # single targeted repair doesn't make the text valid, so
                    # any other, unrelated parse failure still surfaces
                    # normally as a skipped file below.
                    $repairedText = $rawText -replace '"returnCode"\s*:\s*,', '"returnCode": null,'
                    $raw = $repairedText | ConvertFrom-Json
                    [System.IO.File]::WriteAllText($file.FullName, $repairedText, (New-Object System.Text.UTF8Encoding($false)))
                }
                [void]$Global:App.Apps.Add((ConvertTo-AppRecord $raw))
            }
            catch {
                $failedFiles.Add($file.Name)
            }
        }
        $Global:App.UnsavedChangesBox.Value = $false
        if ($failedFiles.Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Loaded $($Global:App.Apps.Count) app(s) successfully, but these file(s) could not be parsed and were skipped:`n$($failedFiles -join "`n")",
                "Some files failed to load", "OK", "Warning") | Out-Null
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not read app data from $Path`n`n$($_.Exception.Message)",
            "Load failed", "OK", "Error") | Out-Null
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
            $fields.Add("$innerPad`"Script_Content`": $(ConvertTo-JsonStringLiteral $DetectionRule.Script_Content)")
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
    $fields.Add("  `"requiredFor`": $(ConvertTo-JsonStringArray -Items @($App.requiredFor) -IndentLevel 1)")
    $fields.Add("  `"availableFor`": $(ConvertTo-JsonStringArray -Items @($App.availableFor) -IndentLevel 1)")
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
        $metaFields.Add("    `"installCommand`": $(ConvertTo-JsonStringLiteral $m.installCommand)")
        $metaFields.Add("    `"uninstallCommand`": $(ConvertTo-JsonStringLiteral $m.uninstallCommand)")
        $metaFields.Add("    `"architecture`": $(ConvertTo-JsonStringLiteral $m.architecture)")
        $metaFields.Add("    `"installContext`": $(ConvertTo-JsonStringLiteral $m.installContext)")
        $metaFields.Add("    `"minOSKey`": $(ConvertTo-JsonStringLiteral $m.minOSKey)")
        $metaFields.Add("    `"detectionRule`": $(ConvertTo-DetectionRuleJson -DetectionRule $m.detectionRule -IndentLevel 2)")
        $metaFields.Add("    `"dependencies`": $(ConvertTo-JsonStringArray -Items @($m.dependencies) -IndentLevel 2)")
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
    $fields.Add("  `"ReplaceContent`": $(if ($Config.ReplaceContent) { 'true' } else { 'false' })")
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

function Global:Save-AppsToFile {
    param([string]$Path)

    $dupIds = $Global:App.Apps | Where-Object { $_.appId } | Group-Object appId | Where-Object { $_.Count -gt 1 }
    if ($dupIds) {
        $names = ($dupIds | ForEach-Object { $_.Name }) -join ", "
        $r = [System.Windows.Forms.MessageBox]::Show(
            "These App IDs are used by more than one app:`n$names`n`nSave anyway?",
            "Duplicate App IDs", "YesNo", "Warning")
        if ($r -ne "Yes") { return $false }
    }

    # Case-insensitive, whitespace-normalized - two entries that differ only
    # by casing or extra spaces still look identical everywhere this app
    # matches by name (Group Manager, App ID lookup, the drift check), and
    # would also collide on the derived package folder name for uncommon
    # apps, since that's computed directly from the name.
    $dupNames = $Global:App.Apps | Where-Object { $_.appName } | Group-Object { ($_.appName.Trim() -replace '\s+', ' ').ToLowerInvariant() } | Where-Object { $_.Count -gt 1 }
    if ($dupNames) {
        $names = ($dupNames | ForEach-Object { $_.Group[0].appName }) -join ", "
        $r2 = [System.Windows.Forms.MessageBox]::Show(
            "These app names are used by more than one entry:`n$names`n`nSave anyway?",
            "Duplicate app names", "YesNo", "Warning")
        if ($r2 -ne "Yes") { return $false }
    }

    # NOT just a warning like the two checks above - this one BLOCKS
    # outright, no "save anyway" option. Two apps with different real
    # names can still collide on the same derived FILENAME once unsafe
    # characters are stripped (e.g. "MyApp/Test" and "MyApp Test" both
    # become "MyApp-Test") - with one file per app now, that's not a
    # display inconsistency, it's one app's file silently overwriting the
    # other's on disk.
    $dupFileNames = $Global:App.Apps | Where-Object { $_.appName } | Group-Object { Get-SafeFileNameForApp -Name $_.appName } | Where-Object { $_.Count -gt 1 }
    if ($dupFileNames) {
        $collisionText = ($dupFileNames | ForEach-Object { "`"" + (($_.Group | ForEach-Object { $_.appName }) -join "`" and `"") + "`" both -> $($_.Name).json" }) -join "`n"
        [System.Windows.Forms.MessageBox]::Show(
            "These app names would collide on the same saved filename, once unsafe characters are stripped:`n`n$collisionText`n`nOne would silently overwrite the other's file. Rename one of them first, then save again.",
            "Filename collision - not saved", "OK", "Error") | Out-Null
        return $false
    }

    # A real, specific safety net - if the in-memory catalog is somehow
    # empty (a bug, or "Open other folder..." pointed somewhere unexpected)
    # while the target folder already holds real per-app files, saving
    # would otherwise delete every one of them as "no longer in the
    # catalog" (see the orphan cleanup below). That's not a save, it's
    # silently wiping out an entire existing catalog.
    if ($Global:App.Apps.Count -eq 0 -and (Test-Path $Path)) {
        $existingCount = @(Get-ChildItem -Path $Path -Filter "*.json" -ErrorAction SilentlyContinue).Count
        if ($existingCount -gt 0) {
            $r3 = [System.Windows.Forms.MessageBox]::Show(
                "The catalog in memory is empty, but $existingCount app file(s) already exist in:`n$Path`n`nSaving now would delete all of them. Save anyway?",
                "Empty catalog - confirm", "YesNo", "Warning")
            if ($r3 -ne "Yes") { return $false }
        }
    }

    # A backup of the WHOLE FOLDER as it was BEFORE this save, not a
    # safeguard against this specific save - if this save turns out to be
    # wrong, the backup is what lets you recover the version before it,
    # rather than the mistake being the only copy of the catalog that
    # still exists. One backup covers every app's file together, same as
    # the single-file version did, rather than one backup per app file.
    if (Test-Path $Path) {
        try {
            $backupDir = Join-Path $Global:App.RootPath "backups"
            if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
            $backupName = "app-data_" + (Get-Date -Format "yyyy-MM-dd_HHmmss")
            Copy-Item -Path $Path -Destination (Join-Path $backupDir $backupName) -Recurse -Force -ErrorAction Stop

            # Keep the last 20 - enough recovery headroom without letting
            # the backups folder grow without bound over months of use.
            $existingBackups = Get-ChildItem -Path $backupDir -Filter "app-data_*" -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
            if ($existingBackups.Count -gt 20) {
                $existingBackups | Select-Object -Skip 20 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            # A failed backup shouldn't block the actual save - it's a
            # safety net, not a prerequisite for saving.
        }
    }

    try {
        if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }

        # Write UTF-8 without a BOM explicitly, since Set-Content -Encoding UTF8 adds a
        # BOM on Windows PowerShell 5.1 but not on PowerShell 7+ - this keeps each file's
        # encoding identical (and Git diffs clean) regardless of which one runs this script.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $currentFileNames = New-Object System.Collections.Generic.HashSet[string]

        # Each app's write isolated in its own try/catch, not one shared
        # try around the whole loop - the same principle already applied
        # in Import-AppsFromFile: one app's data being unable to serialize
        # shouldn't block every OTHER app in the catalog from being saved
        # correctly. Failed apps are collected and reported clearly
        # afterward, rather than either silently skipping them or letting
        # one bad app take the whole save down with it.
        $failedSaveApps = New-Object System.Collections.Generic.List[string]
        foreach ($app in $Global:App.Apps) {
            $fileName = (Get-SafeFileNameForApp -Name $app.appName) + ".json"
            [void]$currentFileNames.Add($fileName)
            $filePath = Join-Path $Path $fileName
            try {
                $json = ConvertTo-SingleAppJson -App $app
                [System.IO.File]::WriteAllText($filePath, $json, $utf8NoBom)
            }
            catch {
                $failedSaveApps.Add("$($app.appName): $($_.Exception.Message)")
            }
        }

        # Removes files for apps no longer in the in-memory catalog -
        # otherwise a deleted or renamed app's old file would be left
        # behind forever, silently reappearing as a phantom entry the next
        # time the folder gets loaded.
        $existingFiles = Get-ChildItem -Path $Path -Filter "*.json" -ErrorAction SilentlyContinue
        foreach ($existingFile in $existingFiles) {
            if (-not $currentFileNames.Contains($existingFile.Name)) {
                Remove-Item -Path $existingFile.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        # Always reported, and reported clearly, if even one app's save
        # failed - a caller checking only the boolean return must not see
        # a plain success when even one app's data didn't actually
        # persist. Returning $false here on any failure, not just when
        # every app fails, so the caller's own existing "save failed"
        # handling takes over correctly instead of also reporting success
        # right alongside this warning.
        if ($failedSaveApps.Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "$($Global:App.Apps.Count - $failedSaveApps.Count) of $($Global:App.Apps.Count) app(s) saved. These failed and were left unchanged on disk:`n`n$($failedSaveApps -join "`n")",
                "Some apps failed to save", "OK", "Warning") | Out-Null
            return $false
        }

        $Global:App.UnsavedChangesBox.Value = $false
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not save to $Path`n`n$($_.Exception.Message)",
            "Save failed", "OK", "Error") | Out-Null
        return $false
    }
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
    if (-not (Test-Path $Global:App.LastAuditCachePath)) { return }
    try {
        # -Encoding UTF8 explicitly, same reasoning as Import-AppsFromFile/
        # Import-GraphSettings - Save-LastAuditCache's own Set-Content
        # -Encoding UTF8 writes a BOM under Windows PowerShell 5.1, which
        # happens to make auto-detection work today, but that's the writer's
        # accident to rely on, not this reader's guarantee.
        $raw = Get-Content -Path $Global:App.LastAuditCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) {
            $entry = $prop.Value
            $Global:App.LastAuditResults[$prop.Name] = [pscustomobject]@{
                Timestamp    = [datetime]$entry.Timestamp
                Metadata     = $entry.Metadata
                Groups       = $entry.Groups
                Dependencies = $entry.Dependencies
                Unknown      = $entry.Unknown
            }
        }
    }
    catch {
        # Previously silent - a load failure here looked EXACTLY like "the
        # audit cache just doesn't persist across a restart", with nothing
        # anywhere to say why. Logged, not a MessageBox - called once during
        # ordinary startup (after the main window and its Log tab already
        # exist - see MainApp.ps1's own startup sequence), and a failure
        # here isn't worth interrupting startup over.
        Write-Log "[WARN] Could not load the last-audit cache ($($Global:App.LastAuditCachePath)): $($_.Exception.Message)`r`n" ([System.Drawing.Color]::Orange)
    }
}

function Global:Save-LastAuditCache {
    try {
        $Global:App.LastAuditResults | ConvertTo-Json -Depth 5 | Set-Content -Path $Global:App.LastAuditCachePath -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # See the matching note in Load-LastAuditCache above - same reasoning.
        Write-Log "[WARN] Could not save the last-audit cache ($($Global:App.LastAuditCachePath)): $($_.Exception.Message)`r`n" ([System.Drawing.Color]::Orange)
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
    $Global:App.LastAuditResults[$AppName] = [pscustomobject]@{
        Timestamp    = Get-Date
        Metadata     = if ($PSBoundParameters.ContainsKey('Metadata'))     { $Metadata }     elseif ($existing) { $existing.Metadata }     else { $null }
        Groups       = if ($PSBoundParameters.ContainsKey('Groups'))       { $Groups }       elseif ($existing) { $existing.Groups }       else { $null }
        Dependencies = if ($PSBoundParameters.ContainsKey('Dependencies')) { $Dependencies } elseif ($existing) { $existing.Dependencies } else { $null }
        Unknown      = if ($PSBoundParameters.ContainsKey('Unknown'))      { $Unknown }      elseif ($existing) { $existing.Unknown }      else { $null }
    }
}
