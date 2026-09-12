function Show-SyncMetadataDialog {
    param([int[]]$ScopedIndices = @())

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef      = $Script:Apps
    $tenantId     = $Script:GraphTenantId
    $clientId     = $Script:GraphClientId
    $certThumb    = $Script:GraphCertificateThumbprint
    $syncScript   = $Script:EmbeddedSyncMetadataScript
    $unsavedBox   = $Script:UnsavedChangesBox
    $linkedFilePath = $Script:LinkedFilePath

    # Selected rows (if any, passed in by the caller) scope this to just
    # them; nothing selected checks the whole catalog like Batch Assign
    # and Package apps already do, for the same reason - consistency with
    # how every other selection-aware action in this app already behaves.
    $candidateApps = if ($ScopedIndices.Count -gt 0) { @($ScopedIndices | ForEach-Object { $appsRef[$_] }) } else { @($appsRef) }
    $isScoped = $ScopedIndices.Count -gt 0

    $eligibleApps = @($candidateApps | Where-Object { $_.appId })

    if ($eligibleApps.Count -eq 0) {
        $msg = if ($isScoped) { "None of the selected app(s) have an App ID yet - nothing to sync." } else { "No apps have an App ID yet - nothing to sync." }
        [System.Windows.Forms.MessageBox]::Show($msg, "Nothing to do", "OK", "Information") | Out-Null
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Pull metadata and groups from Intune"
    $dlg.ClientSize = New-Object System.Drawing.Size(620, 600)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $scopeText = if ($isScoped) { "$($eligibleApps.Count) selected app(s)" } else { "all $($eligibleApps.Count) app(s) with an App ID" }
    $lblIntro.Text = "Fetches current metadata AND current group assignments from Intune for $scopeText and stores them locally in the catalog - including picking up a group that was renamed in Entra ID, since this follows each assignment's group by ID rather than by name. This is READ-ONLY - it never changes anything in Intune itself. An app whose local copy already differs from Intune isn't silently overwritten - a compare dialog opens for it, one app at a time, so you can pick which fields keep your local value before it's applied."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(590,80)
    $dlg.Controls.Add($lblIntro)

    $clbApps = New-Object System.Windows.Forms.CheckedListBox
    $clbApps.Location = New-Object System.Drawing.Point(15,98)
    $clbApps.Size = New-Object System.Drawing.Size(590,260)
    $clbApps.CheckOnClick = $true
    $dlg.Controls.Add($clbApps)
    foreach ($eligibleApp in ($eligibleApps | Sort-Object appName)) {
        [void]$clbApps.Items.Add($eligibleApp.appName, $true)
    }

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select all"
    $btnSelectAll.Location = New-Object System.Drawing.Point(15,362)
    $btnSelectAll.Size = New-Object System.Drawing.Size(100,26)
    $dlg.Controls.Add($btnSelectAll)

    $btnSelectNone = New-Object System.Windows.Forms.Button
    $btnSelectNone.Text = "Select none"
    $btnSelectNone.Location = New-Object System.Drawing.Point(125,362)
    $btnSelectNone.Size = New-Object System.Drawing.Size(110,26)
    $dlg.Controls.Add($btnSelectNone)

    # Hidden until a sync run actually has failures to retry - nothing to
    # show before that point, and showing it disabled/greyed the whole
    # time would just be visual noise for the common case where a sync
    # fully succeeds.
    $btnRetryFailed = New-Object System.Windows.Forms.Button
    $btnRetryFailed.Text = "Retry failed only"
    $btnRetryFailed.Location = New-Object System.Drawing.Point(245,362)
    $btnRetryFailed.Size = New-Object System.Drawing.Size(155,26)
    $btnRetryFailed.Visible = $false
    $dlg.Controls.Add($btnRetryFailed)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,396)
    $lblStatus.Size = New-Object System.Drawing.Size(590,36)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    # Marquee, not a determinate bar - unlike the app/delete queue-runners
    # (one Graph call per app, from THIS process, so their own loop can just
    # report "N of M" directly), this whole sync runs as a single embedded
    # child-process invocation covering every checked app at once with no
    # per-app progress signal streamed back - there's genuinely no "N of M"
    # to report here, just "still running" vs "done".
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(15,432)
    $progressBar.Size = New-Object System.Drawing.Size(590,12)
    $progressBar.Style = "Marquee"
    $progressBar.MarqueeAnimationSpeed = 0
    $dlg.Controls.Add($progressBar)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,448)
    $rtbLog.Size = New-Object System.Drawing.Size(590,98)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnSync = New-Object System.Windows.Forms.Button
    $btnSync.Text = "Sync selected"
    $btnSync.Location = New-Object System.Drawing.Point(420,556)
    $btnSync.Size = New-Object System.Drawing.Size(185,32)
    $dlg.Controls.Add($btnSync)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(330,556)
    $btnClose.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnClose)

    $procBox = @{ Proc = $null }
    # Mutable container, not a plain variable - written from within the
    # nested -OnComplete closure below when a sync run finishes, then read
    # from this button's own separate click handler.
    $lastFailedBox = @{ Names = @() }

    $btnSelectAll.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $true) }
    }.GetNewClosure())
    $btnSelectNone.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $false) }
    }.GetNewClosure())
    $btnRetryFailed.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) {
            $itemName = [string]$clbApps.Items[$ci]
            $clbApps.SetItemChecked($ci, ($lastFailedBox.Names -contains $itemName))
        }
    }.GetNewClosure())

    $btnSync.Add_Click({
        $checkedNames = @($clbApps.CheckedItems | ForEach-Object { [string]$_ })
        if ($checkedNames.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one app to sync.", "Nothing selected", "OK", "Warning") | Out-Null
            return
        }

        # Deliberately a plain foreach, not ForEach-Object, for the outer
        # loop here - nesting a Where-Object INSIDE a ForEach-Object would
        # have both blocks fighting over the same $_ variable, silently
        # comparing an app's name against itself instead of against the
        # checked name actually being looked for.
        $configApps = New-Object System.Collections.Generic.List[object]
        foreach ($checkedName in $checkedNames) {
            $matchApp = $eligibleApps | Where-Object { $_.appName -eq $checkedName } | Select-Object -First 1
            if ($matchApp) {
                $configApps.Add([pscustomobject]@{ AppName = $matchApp.appName; AppId = $matchApp.appId })
            }
        }

        $btnSync.Enabled = $false
        $btnSelectAll.Enabled = $false
        $btnSelectNone.Enabled = $false
        $clbApps.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Syncing $($configApps.Count) app(s)..."
        $rtbLog.Clear()
        $progressBar.MarqueeAnimationSpeed = 30

        $configPath = Join-Path $env:TEMP (".intunepkg_syncmeta_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_syncmeta_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Apps                  = $configApps.ToArray()
            OutputResultPath      = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 10 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Show-ConfigWriteFailedError -ErrorMessage $_.Exception.Message
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnSyncRef = $btnSync
        $btnSelectAllRef = $btnSelectAll
        $btnSelectNoneRef = $btnSelectNone
        $clbAppsRef = $clbApps
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $appsRefRef = $appsRef
        $unsavedBoxRef = $unsavedBox
        $linkedFilePathRef = $linkedFilePath
        $lastFailedBoxRef = $lastFailedBox
        $btnRetryFailedRef = $btnRetryFailed
        $progressBarRef = $progressBar

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $syncScript -TempScriptName ".intunepkg_embedded_syncmeta.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            $progressBarRef.MarqueeAnimationSpeed = 0
            $btnSyncRef.Enabled = $true
            $btnSelectAllRef.Enabled = $true
            $btnSelectNoneRef.Enabled = $true
            $clbAppsRef.Enabled = $true
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (-not (Test-Path $resultPathRef)) {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
                return
            }

            $result = $null
            try {
                $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not read result (exit code $code): $($_.Exception.Message)"
                return
            }

            if (-not $result.success) {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
                return
            }

            try {
                $okCount = 0
                $reviewedCount = 0
                $totalCount = @($result.results).Count
                $failedNames = New-Object System.Collections.Generic.List[string]
                # Apps with real drift are queued here, not resolved
                # inline - the loop below still needs to finish matching
                # every result against $appsRefRef by name before any
                # review dialog pops up, so a slow/interactive review for
                # app #2 doesn't delay even starting to process app #3..N.
                $reviewQueue = New-Object System.Collections.Generic.List[object]
                foreach ($oneResult in @($result.results)) {
                    if (-not $oneResult.Success) { $failedNames.Add($oneResult.AppName); continue }
                    for ($ai = 0; $ai -lt $appsRefRef.Count; $ai++) {
                        if ($appsRefRef[$ai].appName -eq $oneResult.AppName) {
                            # Always applied directly, unlike metadata below -
                            # there's no local, user-editable counterpart for
                            # "what type of app is this in Intune" or "what
                            # version does Intune currently have", so there's
                            # nothing to preserve/review a conflict against;
                            # it's just a fact mirrored from Intune.
                            $appsRefRef[$ai].intuneAppType = Get-FriendlyIntuneAppType -ODataType $oneResult.OdataType
                            $appsRefRef[$ai].intuneAppVersion = $oneResult.DisplayVersion

                            # Not a blind overwrite - an app whose local copy
                            # already differs from what Intune actually has
                            # right now is queued for an interactive
                            # per-field compare below, same one
                            # Show-CreateInIntuneDialog's own auto-fetch
                            # already offers for one app at a time, rather
                            # than silently taking Intune's value.
                            $existingMetadata = $appsRefRef[$ai].metadata
                            $fieldDiffs = Get-CatalogMetadataFieldDiffs -Local $existingMetadata -Remote $oneResult.Metadata -OdataType $oneResult.OdataType

                            # Group names are only compared when this app's
                            # live assignments actually fetched OK - see the
                            # embedded script's own comment next to
                            # GroupFetchOk. A failed fetch there already
                            # comes back as empty name lists, which would
                            # otherwise look exactly like "every group was
                            # removed" and clear real local assignments for
                            # nothing worse than a transient Graph hiccup.
                            $groupDiffs = if ($oneResult.GroupFetchOk) { Get-GroupFieldDiffs -LocalApp $appsRefRef[$ai] -RemoteResult $oneResult } else { @() }
                            $allDiffs = @($fieldDiffs) + @($groupDiffs)

                            if (($existingMetadata -and $fieldDiffs.Count -gt 0) -or $groupDiffs.Count -gt 0) {
                                $reviewQueue.Add([pscustomobject]@{ Index = $ai; AppName = $oneResult.AppName; Local = $existingMetadata; Remote = $oneResult.Metadata; Diffs = $allDiffs; GroupsRemote = $oneResult })
                            }
                            else {
                                $appsRefRef[$ai].metadata = $oneResult.Metadata
                                $okCount++
                            }
                            break
                        }
                    }
                }

                # Reviewed one app at a time, right here - each compare
                # dialog blocks until closed (safe to do from inside this
                # background process's -OnComplete: it still runs on the
                # UI thread, same as everything else in this callback), but
                # it only ever appears for an app that actually has real
                # drift; the common no-drift case above never triggers it.
                foreach ($reviewItem in $reviewQueue) {
                    $driftRows = New-Object System.Collections.Generic.List[object]
                    foreach ($d in $reviewItem.Diffs) {
                        $driftRows.Add([pscustomobject]@{ Field = $d.Field; Local = $d.Local; Intune = $d.Remote })
                    }
                    $keepLocalFields = @(Show-MetadataDriftDialog -Rows $driftRows.ToArray() -AppName $reviewItem.AppName)
                    $mergedMetadata = Merge-CatalogMetadata -Remote $reviewItem.Remote -Local $reviewItem.Local -KeepLocalFields $keepLocalFields
                    $appsRefRef[$reviewItem.Index].metadata = $mergedMetadata

                    # Same reviewed keep-local-or-take-Intune choice, applied
                    # to the three group fields - handled here rather than
                    # inside Merge-CatalogMetadata since these live directly
                    # on the app object, not under App.metadata.
                    if ($reviewItem.GroupsRemote) {
                        if ($keepLocalFields -notcontains "Required for") {
                            $appsRefRef[$reviewItem.Index].requiredFor = @($reviewItem.GroupsRemote.RequiredGroupNames)
                        }
                        if ($keepLocalFields -notcontains "Available for") {
                            $appsRefRef[$reviewItem.Index].availableFor = @($reviewItem.GroupsRemote.AvailableGroupNames)
                        }
                        if ($keepLocalFields -notcontains "Uninstall for") {
                            $appsRefRef[$reviewItem.Index].uninstallFor = @($reviewItem.GroupsRemote.UninstallGroupNames)
                        }
                    }
                    $okCount++
                    $reviewedCount++
                    $keptMsg = if ($keepLocalFields.Count -gt 0) { "kept your local value for: $($keepLocalFields -join ', ')" } else { "took Intune's value for everything" }
                    $rtbLogRef.AppendText("  [REVIEWED] $($reviewItem.AppName): $keptMsg`r`n")
                }

                # Shown only when there's actually something to retry -
                # re-checks just the failed apps in the picker so "Sync
                # selected" can be re-run on them directly, instead of
                # manually re-selecting from a list of 50 apps by hand.
                if ($failedNames.Count -gt 0) {
                    $lastFailedBoxRef.Names = @($failedNames)
                    $btnRetryFailedRef.Visible = $true
                }
                else {
                    $btnRetryFailedRef.Visible = $false
                }
                if ($okCount -gt 0) { $unsavedBoxRef.Value = $true }
                # Direct-save, not just staging in memory - same reasoning
                # as "Save for later..."/"Save local copy...": this
                # button's entire job IS the save, with no batching benefit
                # to be had from deferring it, so a separate click
                # afterward just to persist it is pure friction.
                $syncSaveOk = if ($okCount -gt 0) { Save-AppsToFile -Path $linkedFilePathRef } else { $true }
                $summaryParts = New-Object System.Collections.Generic.List[string]
                $summaryParts.Add("$okCount synced")
                if ($reviewedCount -gt 0) { $summaryParts.Add("$reviewedCount of those reviewed") }
                if ($failedNames.Count -gt 0) { $summaryParts.Add("$($failedNames.Count) failed") }
                $summary = ($summaryParts -join ", ") + " of $totalCount."
                if (-not $syncSaveOk) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                    $lblStatusRef.Text = "$summary Writing to disk was cancelled or failed - use Force save catalog to try again."
                }
                elseif ($failedNames.Count -gt 0) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                    $lblStatusRef.Text = "$summary See log for what failed."
                }
                else {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                    $lblStatusRef.Text = "$summary"
                }
            }
            catch {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Sync completed, but something went wrong applying the results: $($_.Exception.Message)"
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnClose.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show("A sync is currently running. Stop it and close this dialog?", "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnSync

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
}
