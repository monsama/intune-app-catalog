function Global:Show-BulkDeleteFromIntuneDialog {
    param([int[]]$Indices)

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef        = $Global:App.Apps
    $tenantId       = $Global:App.GraphTenantId
    $clientId       = $Global:App.GraphClientId
    $certThumb      = $Global:App.GraphCertificateThumbprint
    $deleteScript   = $Global:App.EmbeddedDeleteAppScript
    $unsavedBox     = $Global:App.UnsavedChangesBox
    $linkedFilePath = $Global:App.LinkedFilePath

    $candidateApps = @($Indices | ForEach-Object { $appsRef[$_] })
    $eligibleApps  = @($candidateApps | Where-Object { $_.appId })

    if ($eligibleApps.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("None of the selected app(s) have an App ID - there's nothing in Intune to delete for them.", "Nothing to do", "OK", "Information") | Out-Null
        return $false
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Delete from Intune - $($eligibleApps.Count) app(s)"
    $dlg.ClientSize = New-Object System.Drawing.Size(660, 646)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    # Shortened from an original ~330-char, two-run-on-sentence version -
    # the stakes here (permanent, unrecoverable delete) deserve a warning
    # that's actually quick to read, not one more paragraph to skim past.
    # Bold used for the one sentence that matters most if this is all
    # anyone reads; everything else is plain-weight follow-up detail.
    $lblWarning = New-Object System.Windows.Forms.RichTextBox
    $lblWarning.Location = New-Object System.Drawing.Point(15,12)
    $lblWarning.Size = New-Object System.Drawing.Size(630,60)
    $lblWarning.ReadOnly = $true
    $lblWarning.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $lblWarning.BackColor = $Global:App.LightPalette.FormBack
    $lblWarning.DetectUrls = $false
    $lblWarning.SelectionFont = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblWarning.SelectionColor = [System.Drawing.Color]::Firebrick
    $lblWarning.AppendText("Permanently deletes every checked app from Intune - content, assignments, and install history included. This cannot be undone.")
    $skippedCount = $candidateApps.Count - $eligibleApps.Count
    if ($skippedCount -gt 0) {
        $lblWarning.SelectionFont = New-Object System.Drawing.Font("Segoe UI", 9)
        $lblWarning.SelectionColor = [System.Drawing.Color]::Firebrick
        $lblWarning.AppendText(" $skippedCount app(s) you selected have no App ID, so there's nothing to delete for them - left out below.")
    }
    $lblWarning.SelectionFont = New-Object System.Drawing.Font("Segoe UI", 9)
    $lblWarning.SelectionColor = $Global:App.LightPalette.ControlFore
    $lblWarning.AppendText("`n`nEach catalog entry stays - only its App ID is cleared, so you can recreate it later without losing its groups.")
    $lblWarning.SelectionStart = 0
    $lblWarning.SelectionLength = 0
    $dlg.Controls.Add($lblWarning)

    $clbApps = New-Object System.Windows.Forms.CheckedListBox
    $clbApps.Location = New-Object System.Drawing.Point(15,90)
    $clbApps.Size = New-Object System.Drawing.Size(630,220)
    $clbApps.CheckOnClick = $true
    $dlg.Controls.Add($clbApps)
    foreach ($eligibleApp in ($eligibleApps | Sort-Object appName)) {
        [void]$clbApps.Items.Add($eligibleApp.appName, $true)
    }

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select all"
    $btnSelectAll.Location = New-Object System.Drawing.Point(15,316)
    $btnSelectAll.Size = New-Object System.Drawing.Size(100,26)
    $dlg.Controls.Add($btnSelectAll)

    $btnSelectNone = New-Object System.Windows.Forms.Button
    $btnSelectNone.Text = "Select none"
    $btnSelectNone.Location = New-Object System.Drawing.Point(125,316)
    $btnSelectNone.Size = New-Object System.Drawing.Size(110,26)
    $dlg.Controls.Add($btnSelectNone)

    # Hidden until a run actually has failures to retry - same convention
    # as Show-SyncMetadataDialog's own "Retry failed only".
    $btnRetryFailed = New-Object System.Windows.Forms.Button
    $btnRetryFailed.Text = "Retry failed only"
    $btnRetryFailed.Location = New-Object System.Drawing.Point(245,316)
    $btnRetryFailed.Size = New-Object System.Drawing.Size(155,26)
    $btnRetryFailed.Visible = $false
    $dlg.Controls.Add($btnRetryFailed)

    # Checked by default - a checked app blocked because Intune itself has
    # it set as a dependency for another app (Winget AutoUpdate depending
    # on nearly everything else being a very common real case, per testing)
    # is by far the more likely outcome than a genuine "leave it alone"
    # case, and leaving this unchecked just means every blocked app fails
    # outright instead. No per-app Yes/No prompt during the run itself,
    # unlike the single-app dialog's own version of this same retry - a
    # bulk run with N apps queued up is exactly the case where stopping to
    # ask mid-run, once per blocked app, defeats the point of doing this in
    # bulk at all; this single upfront checkbox is the batch-appropriate
    # equivalent of that same Yes/No.
    $chkAutoRemoveDeps = New-Object System.Windows.Forms.CheckBox
    $chkAutoRemoveDeps.Text = "Automatically remove blocking dependency relationships (e.g. `"Winget AutoUpdate`") and retry, instead of just failing"
    $chkAutoRemoveDeps.Location = New-Object System.Drawing.Point(15,346)
    # Two lines tall - the text doesn't fit on one.
    $chkAutoRemoveDeps.Size = New-Object System.Drawing.Size(630,36)
    $chkAutoRemoveDeps.CheckAlign = [System.Drawing.ContentAlignment]::TopLeft
    $chkAutoRemoveDeps.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $chkAutoRemoveDeps.Checked = $true
    $dlg.Controls.Add($chkAutoRemoveDeps)

    $lblConfirmPrompt = New-Object System.Windows.Forms.Label
    # Typing the exact name (like the single-app dialog) doesn't scale to N
    # apps at once - typing the literal word DELETE is the same convention
    # widely used elsewhere for an irreversible bulk/multi-item action.
    $lblConfirmPrompt.Text = "Type DELETE below to confirm:"
    $lblConfirmPrompt.Location = New-Object System.Drawing.Point(15,390)
    $lblConfirmPrompt.AutoSize = $true
    $dlg.Controls.Add($lblConfirmPrompt)

    $txtConfirm = New-Object System.Windows.Forms.TextBox
    $txtConfirm.Location = New-Object System.Drawing.Point(15,410)
    $txtConfirm.Size = New-Object System.Drawing.Size(630,24)
    $dlg.Controls.Add($txtConfirm)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,440)
    $lblStatus.Size = New-Object System.Drawing.Size(630,36)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(15,476)
    $progressBar.Size = New-Object System.Drawing.Size(630,12)
    $progressBar.Style = "Continuous"
    $dlg.Controls.Add($progressBar)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,492)
    $rtbLog.Size = New-Object System.Drawing.Size(630,94)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete permanently"
    $btnDelete.Location = New-Object System.Drawing.Point(455,602)
    $btnDelete.Size = New-Object System.Drawing.Size(190,32)
    $btnDelete.Enabled = $false
    $dlg.Controls.Add($btnDelete)
    $deleteTip = New-Object System.Windows.Forms.ToolTip
    $deleteTip.SetToolTip($btnDelete, "Deletes every checked app from Intune only. Catalog entries are kept (just their App ID cleared) unless you choose to remove them too, asked separately afterward.")

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(365,602)
    $btnClose.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnClose)

    $procBox = @{ Proc = $null }
    $lastFailedBox = @{ Names = @() }
    $deletedAnyBox = @{ Value = $false }

    $txtConfirm.Add_TextChanged({
        $btnDelete.Enabled = ($txtConfirm.Text.Trim() -eq "DELETE")
    }.GetNewClosure())

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

    # A mutable container, not a plain variable - RunNext needs to call
    # ITSELF again (moving on to the next app) from within its own
    # -OnComplete - see the extensive reasoning on the identical pattern in
    # Show-BatchDeployDialog's own $RunNextBox for why a plain
    # self-referencing scriptblock would capture $null instead.
    $RunNextBox = @{ Value = $null }

    $RunNextBox.Value = {
        # $RemoveDependencyFromAppId/$RetryAttempt let this same queue item
        # be re-run in place (same $QueueIndex, not the next one) after
        # removing a blocking dependency, mirroring what the single-app
        # dialog's own $RunDeleteBox does interactively - just without a
        # Yes/No prompt each time, since $chkAutoRemoveDeps up front already
        # covers that consent for the whole run. $RetryAttempt caps how many
        # times in a row THIS app can loop back on itself (a fresh
        # dependency found each time) - protects against a pathological
        # dependency chain looping forever; a single-app dependency block
        # only ever needs one or two removals in practice.
        param($Queue, $QueueIndex, $Results, $RemoveDependencyFromAppId = "", $RetryAttempt = 0)

        if ($QueueIndex -ge $Queue.Count) {
            $deletedNames = @($Results | Where-Object { $_.Status -eq "Deleted" } | ForEach-Object { $_.AppName })
            $okCount = $deletedNames.Count
            $failedCount = @($Results | Where-Object { $_.Status -eq "Failed" }).Count
            $progressBar.Value = $progressBar.Maximum
            $btnSelectAll.Enabled = $true
            $btnSelectNone.Enabled = $true
            $clbApps.Enabled = $true
            $chkAutoRemoveDeps.Enabled = $true
            $txtConfirm.Enabled = $true
            $btnDelete.Enabled = ($txtConfirm.Text.Trim() -eq "DELETE")
            $failedNames = @($Results | Where-Object { $_.Status -eq "Failed" } | ForEach-Object { $_.AppName })
            $lastFailedBox.Names = $failedNames
            $btnRetryFailed.Visible = ($failedNames.Count -gt 0)

            # Asked once for the whole run, right after it finishes - not
            # per app mid-run, same reasoning as $chkAutoRemoveDeps above:
            # a single upfront-or-afterward choice, not a popup for every
            # item. Most of the time deleting an app from Intune means
            # you're actually done with it, so leaving every one of these
            # now-orphaned catalog entries behind by default would just be
            # more manual cleanup afterward, not the friendlier outcome.
            $removedCatalogCount = 0
            if ($okCount -gt 0) {
                $catalogChoice = [System.Windows.Forms.MessageBox]::Show(
                    "Deleted $okCount app(s) from Intune.`n`nAlso remove these from the local catalog entirely?`n`n$($deletedNames -join ", ")`n`nChoosing No just clears their App IDs, keeping the entries (and group assignments) so they're easy to recreate later.",
                    "Remove from catalog too?", "YesNo", "Question")
                if ($catalogChoice -eq "Yes") {
                    foreach ($deletedName in $deletedNames) {
                        for ($dci = 0; $dci -lt $appsRef.Count; $dci++) {
                            if ($appsRef[$dci].appName -eq $deletedName) {
                                $appsRef.RemoveAt($dci)
                                $removedCatalogCount++
                                break
                            }
                        }
                    }
                    $unsavedBox.Value = $true
                    [void](Save-AppsToFile -Path $linkedFilePath)
                }
            }

            $lblStatus.ForeColor = if ($failedCount -gt 0) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::SeaGreen }
            $catalogSuffix = if ($removedCatalogCount -gt 0) { " $removedCatalogCount removed from the catalog entirely." } else { "" }
            $lblStatus.Text = "Done - $okCount deleted, $failedCount failed.$catalogSuffix"

            # Closes itself on a clean run, same as the single-app delete
            # dialog already does - nothing left here worth an extra manual
            # click to dismiss. Left open on ANY failure, though, even a
            # partial one: the log and "Retry failed only" are the whole
            # point of staying up in that case, and the user already had to
            # make an active choice on the catalog-removal prompt above
            # regardless, so this isn't closing out from under them mid-task.
            if ($failedCount -eq 0) {
                $dlg.Close()
            }
            return
        }

        $currentApp = $Queue[$QueueIndex]
        if ($RemoveDependencyFromAppId) {
            Write-DialogLogLine -LogBox $rtbLog -Text "  [WARN] Blocked by a dependency - removing it and retrying ($($RetryAttempt+1)/5)...`r`n" -MirrorToMainLog
            $lblStatus.Text = "Removing a blocking dependency for $($currentApp.appName), then retrying..."
        }
        else {
            Write-DialogLogLine -LogBox $rtbLog -Text "`r`n[$($QueueIndex+1)/$($Queue.Count)] $($currentApp.appName)`r`n" -MirrorToMainLog
            $lblStatus.Text = "Deleting $($QueueIndex+1) of $($Queue.Count): $($currentApp.appName)..."
            $progressBar.Value = $QueueIndex
        }

        $configPath = Join-Path $env:TEMP (".intunepkg_bulkdelete_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_bulkdelete_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId                  = $tenantId
            ClientId                  = $clientId
            CertificateThumbprint     = $certThumb
            AppId                     = $currentApp.appId
            AppName                   = $currentApp.appName
            RemoveDependencyFromAppId = $RemoveDependencyFromAppId
            OutputResultPath          = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
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
        $retryAttemptRef = $RetryAttempt
        $chkAutoRemoveDepsRef = $chkAutoRemoveDeps
        $configPathRef = $configPath
        $resultPathRef = $resultPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $appsRefRef = $appsRef
        $unsavedBoxRef = $unsavedBox
        $linkedFilePathRef = $linkedFilePath
        $deletedAnyBoxRef = $deletedAnyBox
        $RunNextBoxRef = $RunNextBox

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $deleteScript -TempScriptName ".intunepkg_embedded_bulkdelete.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLogRef -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            $status = "Failed"
            $message = "No result written (exit code $code)."
            $retryBlockingAppId = $null
            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $status = "Deleted"
                        $message = "Deleted"
                        for ($ai = 0; $ai -lt $appsRefRef.Count; $ai++) {
                            if ($appsRefRef[$ai].appName -eq $currentAppRef.appName) {
                                $appsRefRef[$ai].appId = ""
                                break
                            }
                        }
                        $unsavedBoxRef.Value = $true
                        $deletedAnyBoxRef.Value = $true
                        # Direct-save after EACH successful delete, not just
                        # once at the very end - same reasoning as the
                        # identical per-item save in Show-BatchDeployDialog's
                        # own queue runner: a batch interrupted partway
                        # through must not leave an already-deleted app's
                        # stale App ID sitting in the catalog looking like
                        # it's still there.
                        [void](Save-AppsToFile -Path $linkedFilePathRef)
                        Write-DialogLogLine -LogBox $rtbLogRef -Text "  [OK] Deleted`r`n" -MirrorToMainLog
                    }
                    elseif ($result.blockingAppId -and $chkAutoRemoveDepsRef.Checked -and $retryAttemptRef -lt 5) {
                        # Not recorded as Failed and not advancing the queue
                        # yet - retried in place below instead, same as the
                        # single-app dialog's own Yes/No retry, just without
                        # asking each time (the checkbox up front already
                        # covers that consent for the whole run).
                        $retryBlockingAppId = $result.blockingAppId
                    }
                    elseif ($result.blockingAppId) {
                        $message = if (-not $chkAutoRemoveDepsRef.Checked) {
                            "Blocked - Intune has it set as a dependency for `"$($result.blockingAppName)`". Tick `"Automatically remove blocking dependency relationships`" above and retry, or use `"Delete from Intune...`" on just this one app."
                        } else {
                            "Still blocked after removing $retryAttemptRef blocking dependenc$(if ($retryAttemptRef -eq 1) {'y'} else {'ies'}) in a row - stopping here to avoid looping forever. Currently blocked by `"$($result.blockingAppName)`" - use `"Delete from Intune...`" on just this one app to look closer."
                        }
                        Write-DialogLogLine -LogBox $rtbLogRef -Text "  [FAILED] $message`r`n" -MirrorToMainLog
                    }
                    else {
                        $message = $result.error
                        Write-DialogLogLine -LogBox $rtbLogRef -Text "  [FAILED] $message`r`n" -MirrorToMainLog
                    }
                }
                catch {
                    $message = "Could not read result: $($_.Exception.Message)"
                    Write-DialogLogLine -LogBox $rtbLogRef -Text "  [FAILED] $message`r`n" -MirrorToMainLog
                }
            }
            else {
                Write-DialogLogLine -LogBox $rtbLogRef -Text "  [FAILED] $message`r`n" -MirrorToMainLog
            }

            if ($retryBlockingAppId) {
                & $RunNextBoxRef.Value -Queue $queueRef -QueueIndex $queueIndexRef -Results $resultsRef -RemoveDependencyFromAppId $retryBlockingAppId -RetryAttempt ($retryAttemptRef + 1)
                return
            }

            $resultsRef.Add([pscustomobject]@{ AppName = $currentAppRef.appName; Status = $status; Message = $message })
            & $RunNextBoxRef.Value -Queue $queueRef -QueueIndex ($queueIndexRef + 1) -Results $resultsRef
        }.GetNewClosure()
    }.GetNewClosure()

    $btnDelete.Add_Click({
        $checkedNames = @($clbApps.CheckedItems | ForEach-Object { [string]$_ })
        if ($checkedNames.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one app to delete.", "Nothing selected", "OK", "Warning") | Out-Null
            return
        }
        $r = [System.Windows.Forms.MessageBox]::Show("Permanently delete these $($checkedNames.Count) app(s) from Intune?`n`n$($checkedNames -join ", ")", "Confirm bulk delete", "YesNo", "Warning")
        if ($r -ne "Yes") { return }

        $queueApps = New-Object System.Collections.Generic.List[object]
        foreach ($checkedName in $checkedNames) {
            $matchApp = $eligibleApps | Where-Object { $_.appName -eq $checkedName } | Select-Object -First 1
            if ($matchApp) { $queueApps.Add($matchApp) }
        }

        $btnDelete.Enabled = $false
        $btnSelectAll.Enabled = $false
        $btnSelectNone.Enabled = $false
        $clbApps.Enabled = $false
        $chkAutoRemoveDeps.Enabled = $false
        $txtConfirm.Enabled = $false
        $btnRetryFailed.Visible = $false
        $rtbLog.Clear()
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Starting..."
        $progressBar.Minimum = 0
        $progressBar.Maximum = [Math]::Max(1, $queueApps.Count)
        $progressBar.Value = 0

        $resultsList = New-Object System.Collections.Generic.List[object]
        & $RunNextBox.Value -Queue $queueApps.ToArray() -QueueIndex 0 -Results $resultsList
    }.GetNewClosure())

    $btnClose.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "A deletion is currently running. Stop it and close this dialog?`n`nAny app already deleted from Intune stays deleted - check the catalog's App ID column afterward.",
                "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    # Same type-DELETE-to-confirm pattern as Show-DeleteAppDialog's own
    # $btnDelete/AcceptButton pairing - btnDelete starts disabled and only
    # arms once the confirmation text matches, so Enter is safe here for
    # the same reason it's safe there.
    $dlg.AcceptButton = $btnDelete

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
    return $deletedAnyBox.Value
}
