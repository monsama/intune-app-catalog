function Global:Show-BatchDeployDialog {
    param([int[]]$ScopedIndices = @())

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef      = $Global:App.Apps
    $tenantId     = $Global:App.GraphTenantId
    $clientId     = $Global:App.GraphClientId
    $certThumb    = $Global:App.GraphCertificateThumbprint
    $createScript = $Global:App.EmbeddedCreateAppScript
    $unsavedBox   = $Global:App.UnsavedChangesBox
    $linkedFilePath = $Global:App.LinkedFilePath

    $candidateApps = if ($ScopedIndices.Count -gt 0) { @($ScopedIndices | ForEach-Object { $appsRef[$_] }) } else { @($appsRef) }
    $isScoped = $ScopedIndices.Count -gt 0

    # Eligible: just no App ID yet (not deployed) - metadata is no longer
    # required up front. An app with saved metadata (from "Save for
    # later...") uses it; one without gets the same defaults
    # Show-CreateInIntuneDialog's own form would pre-fill for a brand-new
    # app (see Get-DefaultAppMetadata), computed and saved into the
    # catalog at actual deploy time below - rather than being excluded
    # from the batch just for never having been opened in that dialog
    # once first. The one real exception: an UNCOMMON app with no saved
    # metadata has no detection script to default to (there's no real
    # install to derive one from), so that specific case is still skipped
    # at deploy time, same as a missing package.
    $eligibleApps = @($candidateApps | Where-Object { -not $_.appId })

    if ($eligibleApps.Count -eq 0) {
        $msg = if ($isScoped) { "None of the selected app(s) need deploying - they all already have an App ID." } else { "No apps need deploying - they all already have an App ID." }
        [System.Windows.Forms.MessageBox]::Show($msg, "Nothing to do", "OK", "Information") | Out-Null
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Batch deploy to Intune"
    $dlg.ClientSize = New-Object System.Drawing.Size(660, 630)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $scopeText = if ($isScoped) { "$($eligibleApps.Count) selected app(s)" } else { "all $($eligibleApps.Count) app(s)" }
    $lblIntro.Text = "Creates $scopeText in Intune, in dependency order where one depends on another. Uses saved metadata where an app has it; otherwise uses the same defaults Deploy to Intune's own form would, and saves them to the catalog. Apps whose package isn't built yet (or, for an uncommon app with no saved metadata, has no detection to default to) are skipped, not failed."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(630,66)
    $dlg.Controls.Add($lblIntro)

    # Package readiness is shown up front, per app, rather than only
    # discovered mid-run - so a missing package can be noticed and fixed
    # before starting, instead of the run just skipping past it silently.
    # Same for whether saved metadata exists or defaults will be used.
    $clbApps = New-Object System.Windows.Forms.CheckedListBox
    $clbApps.Location = New-Object System.Drawing.Point(15,84)
    $clbApps.Size = New-Object System.Drawing.Size(630,240)
    $clbApps.CheckOnClick = $true
    $dlg.Controls.Add($clbApps)
    $itemLabelToApp = @{}
    foreach ($eligibleApp in ($eligibleApps | Sort-Object appName)) {
        $isUncommon = Test-AppIsUncommon -App $eligibleApp
        $pkg = Resolve-AppPackagePath -AppName $eligibleApp.appName -Uncommon $isUncommon
        # A common app has no package of its own - it shares
        # init.intunewin - so "not built yet" there means the one shared
        # package is missing and EVERY common app in this list is about to
        # be skipped for the same reason. Worth saying where the fix is,
        # rather than letting it read like each app needs packaging.
        $tag = if (-not $pkg.Found) {
            if ($isUncommon) { "  [package not built yet]" } else { "  [shared package missing - Settings > Folders]" }
        }
        elseif (-not $eligibleApp.metadata) {
            if ($isUncommon) { "  [no saved metadata and no Winget ID - can't default detection]" } else { "  [no saved metadata - will use defaults]" }
        }
        else { "" }
        $label = "$($eligibleApp.appName)$tag"
        $itemLabelToApp[$label] = $eligibleApp
        $canCheck = $pkg.Found -and (-not $isUncommon -or $eligibleApp.metadata)
        [void]$clbApps.Items.Add($label, $canCheck)
    }

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select all"
    $btnSelectAll.Location = New-Object System.Drawing.Point(15,328)
    $btnSelectAll.Size = New-Object System.Drawing.Size(100,26)
    $dlg.Controls.Add($btnSelectAll)

    $btnSelectNone = New-Object System.Windows.Forms.Button
    $btnSelectNone.Text = "Select none"
    $btnSelectNone.Location = New-Object System.Drawing.Point(125,328)
    $btnSelectNone.Size = New-Object System.Drawing.Size(110,26)
    $dlg.Controls.Add($btnSelectNone)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,362)
    $lblStatus.Size = New-Object System.Drawing.Size(630,36)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    # A known-length queue (one app at a time, count known up front) is
    # exactly what a determinate ProgressBar is for - the label above
    # already says "N of M", but a bar makes overall progress readable at
    # a glance without reading the text.
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(15,398)
    $progressBar.Size = New-Object System.Drawing.Size(630,12)
    $progressBar.Style = "Continuous"
    $dlg.Controls.Add($progressBar)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,414)
    $rtbLog.Size = New-Object System.Drawing.Size(630,138)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnDeploy = New-Object System.Windows.Forms.Button
    $btnDeploy.Text = "Deploy selected"
    $btnDeploy.Location = New-Object System.Drawing.Point(455,582)
    $btnDeploy.Size = New-Object System.Drawing.Size(185,32)
    $dlg.Controls.Add($btnDeploy)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(365,582)
    $btnClose.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnClose)

    $procBox = @{ Proc = $null }

    $btnSelectAll.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $true) }
    }.GetNewClosure())
    $btnSelectNone.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $false) }
    }.GetNewClosure())

    # A mutable container, not a plain variable - RunNext needs to call
    # ITSELF again (moving on to the next app) from within its own
    # -OnComplete. .GetNewClosure() captures variables BY VALUE at the
    # moment it's called, not as a live reference to their future state -
    # a plain self-referencing "$RunNext = {...$RunNext...}.GetNewClosure()"
    # would capture $null, since the variable doesn't exist yet at that
    # exact instant. This exact bug already happened once this session (the
    # delete-app dependency retry) - same fix reused here rather than
    # repeating the mistake in a new dialog.
    $RunNextBox = @{ Value = $null }

    $RunNextBox.Value = {
        param($Queue, $QueueIndex, $Results)

        if ($QueueIndex -ge $Queue.Count) {
            $createdCount = @($Results | Where-Object { $_.Status -eq "Created" }).Count
            $skippedCount = @($Results | Where-Object { $_.Status -eq "Skipped" }).Count
            $failedCount  = @($Results | Where-Object { $_.Status -eq "Failed" }).Count
            $progressBar.Value = $progressBar.Maximum
            $btnDeploy.Enabled = $true
            $btnSelectAll.Enabled = $true
            $btnSelectNone.Enabled = $true
            $clbApps.Enabled = $true
            $lblStatus.ForeColor = if ($failedCount -gt 0) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::SeaGreen }
            # No longer says "use Save to persist" - stale wording left
            # over from before each successful app started saving directly
            # to disk right after its own creation, inside the loop above,
            # rather than only once at the very end here.
            $lblStatus.Text = "Done - $createdCount created, $skippedCount skipped, $failedCount failed."

            # Main grid is already stale the moment this ran (every
            # successful app saved its new App ID/type straight to disk
            # inside the loop above, not just here at the end) - refreshed
            # now regardless of whether this dialog is about to close,
            # same reasoning as every other bulk action in this app.
            Update-Grid

            # Closes itself on a clean run, same as bulk delete already
            # does - nothing left here worth an extra manual click to
            # dismiss. A skip isn't a failure (it's an expected, already-
            # explained outcome - missing package or no detection to
            # default), so it doesn't hold this open; an actual failure
            # does, since the log is the whole point of staying up then.
            if ($failedCount -eq 0) {
                $dlg.Close()
            }
            return
        }

        $currentApp = $Queue[$QueueIndex]
        Write-DialogLogLine -LogBox $rtbLog -Text "`r`n[$($QueueIndex+1)/$($Queue.Count)] $($currentApp.appName)`r`n" -MirrorToMainLog
        $lblStatus.Text = "Deploying $($QueueIndex+1) of $($Queue.Count): $($currentApp.appName)..."
        $progressBar.Value = $QueueIndex

        $isUncommon = Test-AppIsUncommon -App $currentApp
        $pkg = Resolve-AppPackagePath -AppName $currentApp.appName -Uncommon $isUncommon
        if (-not $pkg.Found) {
            $why = if ($isUncommon) { "Package not built yet" } else { "Shared package missing - build it under Settings > Folders" }
            Write-DialogLogLine -LogBox $rtbLog -Text "  [SKIPPED] $($why): $($pkg.Path)`r`n" -MirrorToMainLog
            $Results.Add([pscustomobject]@{ AppName = $currentApp.appName; Status = "Skipped"; Message = $why })
            # $RunNextBox directly, not an alias - still the outer
            # scriptblock's own direct body at this point, not the nested
            # -OnComplete closure further below, so no alias is needed (or
            # would even be defined yet) here.
            & $RunNextBox.Value -Queue $Queue -QueueIndex ($QueueIndex + 1) -Results $Results
            return
        }

        # An app with no saved metadata gets the same defaults
        # Show-CreateInIntuneDialog's own form would pre-fill for it - see
        # Get-DefaultAppMetadata. $usedDefaults is threaded through to the
        # success handler below so it knows to actually save this computed
        # metadata into the catalog alongside the new App ID, same as if
        # "Save for later..." had been done first.
        $usedDefaults = -not $currentApp.metadata
        $effectiveMetadata = if ($currentApp.metadata) { $currentApp.metadata } else { Get-DefaultAppMetadata -AppName $currentApp.appName -WingetId $currentApp.wingetId -Uncommon $isUncommon }
        if (-not $effectiveMetadata.detectionRule) {
            # Calls out the Winget ID specifically, not just "uncommon" -
            # a blank Winget ID IS what makes Test-AppIsUncommon call this
            # app uncommon in the first place (see its own definition), so
            # for an app that was actually meant to be a winget app, a
            # missing/typo'd ID here is the single most likely, and most
            # directly fixable, reason detection couldn't be defaulted.
            Write-DialogLogLine -LogBox $rtbLog -Text "  [SKIPPED] No detection available - this app has no Winget ID (so it's treated as uncommon) and no saved metadata to default detection from. If it should be a winget app, set its Winget ID; otherwise use `"Deploy to Intune...`" to set detection manually. Then re-run.`r`n" -MirrorToMainLog
            $Results.Add([pscustomobject]@{ AppName = $currentApp.appName; Status = "Skipped"; Message = "No Winget ID and no detection script available" })
            & $RunNextBox.Value -Queue $Queue -QueueIndex ($QueueIndex + 1) -Results $Results
            return
        }
        if ($usedDefaults) {
            Write-DialogLogLine -LogBox $rtbLog -Text "  [INFO] No saved metadata - using the same defaults Deploy to Intune's own form would.`r`n" -MirrorToMainLog
        }

        # Dependency names resolved to App IDs at the moment each app is
        # actually about to be created, not once up front - a dependency
        # earlier in this SAME batch may only have just received its own
        # App ID a few seconds ago, from an earlier step in this loop.
        $resolvedDepIds = New-Object System.Collections.Generic.List[string]
        foreach ($depName in @($effectiveMetadata.dependencies)) {
            $depApp = $appsRef | Where-Object { $_.appName -eq $depName } | Select-Object -First 1
            if ($depApp -and $depApp.appId) {
                $resolvedDepIds.Add($depApp.appId)
            }
            else {
                Write-DialogLogLine -LogBox $rtbLog -Text "  [SKIPPED] Dependency `"$depName`" has no App ID yet - skipping just that dependency, not the whole app.`r`n" -MirrorToMainLog
            }
        }

        $configPath = Join-Path $env:TEMP (".intunepkg_batchdeploy_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_batchdeploy_result_" + [guid]::NewGuid().ToString("N") + ".json")

        $config = [pscustomobject]@{
            TenantId                = $tenantId
            ClientId                = $clientId
            CertificateThumbprint   = $certThumb
            Mode                    = "Create"
            ExistingAppId           = ""
            AppName                 = $currentApp.appName
            Description             = $effectiveMetadata.description
            Publisher               = $effectiveMetadata.publisher
            Owner                   = $effectiveMetadata.owner
            Developer               = $effectiveMetadata.developer
            InformationUrl          = $effectiveMetadata.informationUrl
            PrivacyUrl              = $effectiveMetadata.privacyUrl
            Notes                   = $effectiveMetadata.notes
            InstallCommand          = $effectiveMetadata.installCommand
            UninstallCommand        = $effectiveMetadata.uninstallCommand
            DetectionRule           = $effectiveMetadata.detectionRule
            InstallContext          = $effectiveMetadata.installContext
            Architecture            = $effectiveMetadata.architecture
            MinOSVersionKey         = $effectiveMetadata.minOSKey
            # Previously omitted here entirely (this config never had these
            # fields at all) - the embedded create script silently fell back
            # to ITS OWN internal defaults for them instead, which for
            # DeviceRestartBehavior ("suppress") and ReturnCodes (none at
            # all) actually differed from what Deploy to Intune's own form
            # defaults to ("basedOnReturnCode" and the standard 5 rows) -
            # every batch-deployed app was silently getting different
            # requirements/return-code/restart-behavior settings than a
            # manually-created one, not just ones using generated defaults.
            MinDiskSpaceMB          = $effectiveMetadata.minDiskSpaceMB
            MinMemoryMB             = $effectiveMetadata.minMemoryMB
            MinProcessors           = $effectiveMetadata.minProcessors
            MinCpuSpeedMHz          = $effectiveMetadata.minCpuSpeedMHz
            InstallTimeMinutes      = $effectiveMetadata.installTimeMinutes
            DeviceRestartBehavior   = $effectiveMetadata.deviceRestartBehavior
            AllowAvailableUninstall = $effectiveMetadata.allowAvailableUninstall
            ReturnCodes             = @($effectiveMetadata.returnCodes)
            PackagePath             = $pkg.Path
            DependencyAppIds        = @($resolvedDepIds)
            ReplaceContent          = $false
            OutputResultPath        = $resultPath
        }

        try {
            $configJsonText = $config | ConvertTo-Json -Depth 10 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Show-ConfigWriteFailedError -ErrorMessage $_.Exception.Message
            return
        }

        # Fresh aliases for this nested -OnComplete closure - see note at
        # the top of Show-CreateInIntuneDialog for why this matters here too.
        $currentAppRef = $currentApp
        $queueRef = $Queue
        $queueIndexRef = $QueueIndex
        $resultsRef = $Results
        $configPathRef = $configPath
        $resultPathRef = $resultPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $appsRefRef = $appsRef
        $RunNextBoxRef = $RunNextBox
        $linkedFilePathRef = $linkedFilePath
        $unsavedBoxRef = $unsavedBox
        $usedDefaultsRef = $usedDefaults
        $effectiveMetadataRef = $effectiveMetadata

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $createScript -TempScriptName ".intunepkg_embedded_batchdeploy.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLogRef -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            $status = "Failed"
            $message = "No result written (exit code $code)."
            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $status = "Created"
                        $message = "Created"
                        if ($result.appId) {
                            for ($ai = 0; $ai -lt $appsRefRef.Count; $ai++) {
                                if ($appsRefRef[$ai].appName -eq $currentAppRef.appName) {
                                    $appsRefRef[$ai].appId = $result.appId
                                    # This tool only ever creates win32LobApp
                                    # objects, so the type is a known fact on
                                    # any successful creation - no fetch needed.
                                    $appsRefRef[$ai].intuneAppType = "Windows app (Win32)"
                                    # The generated defaults are only saved
                                    # into the catalog on actual SUCCESS,
                                    # not the moment they're computed above -
                                    # a failed create (bad detection script,
                                    # Graph rejecting something, etc.)
                                    # shouldn't leave unvalidated, made-up
                                    # metadata sitting in the catalog for an
                                    # app that was never actually deployed.
                                    if ($usedDefaultsRef) {
                                        $appsRefRef[$ai].metadata = $effectiveMetadataRef
                                    }
                                    break
                                }
                            }
                            $unsavedBoxRef.Value = $true
                            # Direct-save after EACH successful app, not just
                            # once at the very end of the whole batch - the
                            # stakes of losing progress here are real: if a
                            # multi-app batch gets interrupted partway
                            # through and nothing was ever saved, re-running
                            # it later would recreate apps that already
                            # exist in Intune, not just redo harmless work.
                            [void](Save-AppsToFile -Path $linkedFilePathRef)
                        }
                        $defaultsNote = if ($usedDefaultsRef) { " - default metadata saved to the catalog" } else { "" }
                        Write-DialogLogLine -LogBox $rtbLogRef -Text "  [OK] Created (App ID: $($result.appId))$defaultsNote`r`n" -MirrorToMainLog
                    }
                    else {
                        $message = $result.error
                        Write-DialogLogLine -LogBox $rtbLogRef -Text "  [FAILED] $($result.error)`r`n" -MirrorToMainLog
                    }
                }
                catch {
                    $message = "Could not read result: $($_.Exception.Message)"
                    Write-DialogLogLine -LogBox $rtbLogRef -Text "  [FAILED] Could not read result: $($_.Exception.Message)`r`n" -MirrorToMainLog
                }
            }
            else {
                Write-DialogLogLine -LogBox $rtbLogRef -Text "  [FAILED] $message`r`n" -MirrorToMainLog
            }

            $resultsRef.Add([pscustomobject]@{ AppName = $currentAppRef.appName; Status = $status; Message = $message })
            & $RunNextBoxRef.Value -Queue $queueRef -QueueIndex ($queueIndexRef + 1) -Results $resultsRef
        }.GetNewClosure()
    }.GetNewClosure()

    $btnDeploy.Add_Click({
        $checkedLabels = @($clbApps.CheckedItems | ForEach-Object { [string]$_ })
        if ($checkedLabels.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one app to deploy.", "Nothing selected", "OK", "Warning") | Out-Null
            return
        }

        $checkedApps = New-Object System.Collections.Generic.List[object]
        foreach ($label in $checkedLabels) {
            if ($itemLabelToApp.ContainsKey($label)) { $checkedApps.Add($itemLabelToApp[$label]) }
        }

        $orderResult = Get-DependencyOrderedApps -Apps $checkedApps.ToArray()
        if ($orderResult.CircularNames.Count -gt 0) {
            $names = $orderResult.CircularNames -join ", "
            $r = [System.Windows.Forms.MessageBox]::Show(
                "These apps have a circular dependency and can't be fully ordered: $names`n`nThey'll still be attempted, but one or more may fail to reference a dependency that isn't created yet. Continue anyway?",
                "Circular dependency", "YesNo", "Warning", "Button2")
            if ($r -ne "Yes") { return }
        }

        $btnDeploy.Enabled = $false
        $btnSelectAll.Enabled = $false
        $btnSelectNone.Enabled = $false
        $clbApps.Enabled = $false
        $rtbLog.Clear()
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Starting..."
        $progressBar.Minimum = 0
        $progressBar.Maximum = [Math]::Max(1, $orderResult.Ordered.Count)
        $progressBar.Value = 0

        $resultsList = New-Object System.Collections.Generic.List[object]
        & $RunNextBox.Value -Queue $orderResult.Ordered -QueueIndex 0 -Results $resultsList
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    Register-CloseConfirmation -Dialog $dlg -GetQuestion {
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            "A deployment is still running. Stop it and close?`n`nApps already created in Intune stay there - check the catalog's App ID column afterwards."
        }
    }.GetNewClosure() -OnConfirmed { $procBox.Proc.Kill() }.GetNewClosure()
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnDeploy

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
