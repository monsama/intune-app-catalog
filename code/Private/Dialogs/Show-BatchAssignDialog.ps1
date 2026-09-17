function Global:Show-BatchAssignDialog {
    param([int[]]$ScopedIndices = @())

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef      = $Global:App.Apps
    $tenantId     = $Global:App.GraphTenantId
    $clientId     = $Global:App.GraphClientId
    $certThumb    = $Global:App.GraphCertificateThumbprint
    $batchScript  = $Global:App.EmbeddedBatchAssignScript

    # Selected rows (if any, passed in by the caller) scope this to just
    # them; nothing selected checks the whole catalog like before.
    $candidateApps = if ($ScopedIndices.Count -gt 0) { @($ScopedIndices | ForEach-Object { $appsRef[$_] }) } else { @($appsRef) }
    $isScoped = $ScopedIndices.Count -gt 0

    $eligibleApps = @($candidateApps | Where-Object {
        $_.appId -and (@($_.requiredFor).Count -gt 0 -or @($_.availableFor).Count -gt 0 -or @($_.uninstallFor).Count -gt 0)
    })

    if ($eligibleApps.Count -eq 0) {
        # This used to just say "nothing to do" and stop - true as far as
        # reconciling goes (nothing here has a group to reconcile YET),
        # but it's also exactly the situation someone reaches for "Batch
        # assign groups..." to fix in the first place: several apps that
        # need the SAME group and don't have it yet. Offers the actual
        # fix right here instead of a dead end - add a favorite group to
        # these apps, then reopen this same dialog (same scope) so
        # they're immediately eligible to reconcile/push to Intune.
        # ...but only when a group is what's missing: an app without an App
        # ID can't become eligible by adding a group, and offering it anyway
        # just led back to this same question.
        $scopeText = if ($isScoped) { "None of the selected app(s) have" } else { "No apps have" }
        $appsWithId = @($candidateApps | Where-Object { $_.appId })
        if ($appsWithId.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("$scopeText an App ID yet, so there's nothing to push to Intune.`n`nDeploy the app(s) first, or use 'Look up App IDs' to find apps that already exist in Intune.", "Nothing to push yet", "OK", "Information") | Out-Null
            return
        }
        $r = [System.Windows.Forms.MessageBox]::Show("$scopeText any groups set yet, so there's nothing to push to Intune.`n`nAdd a favorite group to $(if ($appsWithId.Count -eq 1) { "'$($appsWithId[0].appName)'" } else { "these $($appsWithId.Count) apps" }) now?", "Nothing to push yet", "YesNo", "Question")
        if ($r -eq "Yes") {
            $addedCount = Show-AddFavoriteGroupToAppsDialog -CandidateApps $appsWithId
            if ($addedCount -gt 0) { Show-BatchAssignDialog -ScopedIndices $ScopedIndices }
        }
        return
    }

    # Config apps array is built once, up front, from a snapshot of the
    # catalog at the moment this dialog opened - both the Preview and
    # (later) Apply runs use this same snapshot, so what Apply does always
    # matches exactly what Preview showed, even if you keep the dialog open
    # a while before applying.
    $appsForScript = @($eligibleApps | ForEach-Object {
        [pscustomobject]@{
            AppName         = $_.appName
            AppId           = $_.appId
            RequiredGroups  = @($_.requiredFor)
            AvailableGroups = @($_.availableFor)
            UninstallGroups = @($_.uninstallFor)
        }
    })

    # Boxed (not plain variables) so "+ Add favorite group..." below can
    # refresh what $runBatch's already-built closure sees on its NEXT
    # Preview run - $runBatch is .GetNewClosure()'d once, which snapshots
    # whatever a plain variable holds at that moment; only a shared,
    # mutable container (same pattern as $procBox/$previewDataBox just
    # below) stays visible to a closure that already captured it.
    $eligibleAppsBox = @{ Value = $eligibleApps }
    $appsForScriptBox = @{ Value = $appsForScript }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Batch assign groups"
    $dlg.ClientSize = New-Object System.Drawing.Size(780, 530)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $scopeText = if ($isScoped) { "$($eligibleApps.Count) of your selected app(s) that have" } else { "every app with" }
    $lblIntro.Text = "Checks $scopeText an App ID and at least one group against Intune's CURRENT assignments. Nothing changes until you click Apply below."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(750,34)
    $dlg.Controls.Add($lblIntro)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Checking $($eligibleApps.Count) app(s)..."
    $lblStatus.Location = New-Object System.Drawing.Point(15,50)
    $lblStatus.Size = New-Object System.Drawing.Size(750,20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,76)
    $grid.Size = New-Object System.Drawing.Size(750,210)
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window

    $colApp = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colApp.Name = "App"; $colApp.HeaderText = "App"; $colApp.FillWeight = 50
    $grid.Columns.Add($colApp) | Out-Null
    $colAdd = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colAdd.Name = "Add"; $colAdd.HeaderText = "Will add"; $colAdd.FillWeight = 25
    $grid.Columns.Add($colAdd) | Out-Null
    $colRemove = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colRemove.Name = "Remove"; $colRemove.HeaderText = "Will remove"; $colRemove.FillWeight = 25
    $grid.Columns.Add($colRemove) | Out-Null
    $dlg.Controls.Add($grid)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,296)
    $rtbLog.Size = New-Object System.Drawing.Size(750,170)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnViewDetails = New-Object System.Windows.Forms.Button
    $btnViewDetails.Text = "View details..."
    $btnViewDetails.Location = New-Object System.Drawing.Point(15,476)
    $btnViewDetails.Size = New-Object System.Drawing.Size(150,32)
    $btnViewDetails.Enabled = $false
    $dlg.Controls.Add($btnViewDetails)

    $btnAddFavoriteGroup = New-Object System.Windows.Forms.Button
    $btnAddFavoriteGroup.Text = "+ Add favorite group..."
    $btnAddFavoriteGroup.Location = New-Object System.Drawing.Point(180,476)
    $btnAddFavoriteGroup.Size = New-Object System.Drawing.Size(180,32)
    $dlg.Controls.Add($btnAddFavoriteGroup)

    $btnRemoveGroup = New-Object System.Windows.Forms.Button
    $btnRemoveGroup.Text = "- Remove group..."
    $btnRemoveGroup.Location = New-Object System.Drawing.Point(365,476)
    $btnRemoveGroup.Size = New-Object System.Drawing.Size(165,32)
    $dlg.Controls.Add($btnRemoveGroup)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "Apply to Intune..."
    $btnApply.Location = New-Object System.Drawing.Point(535,476)
    $btnApply.Size = New-Object System.Drawing.Size(130,32)
    $btnApply.Enabled = $false
    $dlg.Controls.Add($btnApply)
    $applyTip = New-Object System.Windows.Forms.ToolTip
    $applyTip.SetToolTip($btnApply, "Pushes the assignment changes shown above to Intune, for every eligible app. Any assignment not backed by an app's catalog groups is removed too, even ones this catalog didn't create - cannot be undone from here.")

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(675,476)
    $btnClose.Size = New-Object System.Drawing.Size(90,32)
    $dlg.Controls.Add($btnClose)

    $procBox = @{ Proc = $null }
    $previewDataBox = @{ Results = @() }

    # Separate from $previewDataBox on purpose - that one is the grid's
    # historical record (a successful Apply's own ToAdd/ToRemove is exactly
    # what it JUST did, and the grid should keep showing that as a record
    # of what happened), while THIS is "how much is still outstanding
    # against Intune right now", which is 0/0 the instant an Apply
    # succeeds - conflating the two used to make Close's own pending-
    # changes warning below fire right after a successful Apply, reading
    # "what was just applied" as if it were still unapplied.
    $pendingBox = @{ TotalAdd = 0; TotalRemove = 0 }

    # Rebuilds the grid from whatever preview/apply results just came back.
    $populateGrid = {
        param($Results)
        $grid.DataSource = $null
        $grid.Rows.Clear()
        foreach ($r in $Results) {
            $addText = if (@($r.ToAdd).Count -gt 0) { "$(@($r.ToAdd).Count)" } else { "-" }
            $removeText = if (@($r.ToRemove).Count -gt 0) { "$(@($r.ToRemove).Count)" } else { "-" }
            [void]$grid.Rows.Add($r.AppName, $addText, $removeText)
        }
        $previewDataBox.Results = $Results
    }.GetNewClosure()

    # Shared by both the initial Preview run and the later Apply run - only
    # the Mode differs between the two calls.
    $runBatch = {
        param($Mode)

        $btnApply.Enabled = $false
        $btnViewDetails.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = if ($Mode -eq "Preview") { "Checking $($eligibleAppsBox.Value.Count) app(s)..." } else { "Applying changes to $($eligibleAppsBox.Value.Count) app(s)..." }

        $configPath = Join-Path $env:TEMP (".intunepkg_batchassign_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_batchassign_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Mode                  = $Mode
            Apps                  = $appsForScriptBox.Value
            OutputResultPath      = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Show-ConfigWriteFailedError -ErrorMessage $_.Exception.Message
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnApplyRef = $btnApply
        $btnViewDetailsRef = $btnViewDetails
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $populateGridRef = $populateGrid
        $pendingBoxRef = $pendingBox
        $modeRef = $Mode
        $rtbLogRef = $rtbLog

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $batchScript -TempScriptName ".intunepkg_embedded_batchassign.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $results = @($result.data)
                        & $populateGridRef $results
                        $btnViewDetailsRef.Enabled = $true
                        $totalAdd = ($results | ForEach-Object { @($_.ToAdd).Count } | Measure-Object -Sum).Sum
                        $totalRemove = ($results | ForEach-Object { @($_.ToRemove).Count } | Measure-Object -Sum).Sum
                        if ($modeRef -eq "Preview") {
                            $btnApplyRef.Enabled = ($totalAdd -gt 0 -or $totalRemove -gt 0)
                            $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                            $lblStatusRef.Text = "Checked $(@($results).Count) app(s) - $totalAdd to add, $totalRemove to remove in total."
                            # Preview's own diff IS the outstanding amount.
                            $pendingBoxRef.TotalAdd = $totalAdd
                            $pendingBoxRef.TotalRemove = $totalRemove
                        }
                        else {
                            $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                            $lblStatusRef.Text = "Applied. $(@($results).Count) app(s) processed."
                            # A successful Apply just pushed exactly this
                            # diff to Intune - nothing is outstanding
                            # anymore, even though $totalAdd/$totalRemove
                            # above (and the grid $populateGridRef just
                            # populated from the same $results) still show
                            # those same numbers as a record of what was
                            # done.
                            $pendingBoxRef.TotalAdd = 0
                            $pendingBoxRef.TotalRemove = 0
                        }
                    }
                    else {
                        Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure()

    $btnViewDetails.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { return }
        $rowIndex = $grid.SelectedRows[0].Index
        if ($rowIndex -ge $previewDataBox.Results.Count) { return }
        $r = $previewDataBox.Results[$rowIndex]
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("App: $($r.AppName)")
        $lines.Add("")
        $lines.Add("Will add ($(@($r.ToAdd).Count)):")
        foreach ($g in @($r.ToAdd)) { $lines.Add("  + $g") }
        if (@($r.ToAdd).Count -eq 0) { $lines.Add("  (none)") }
        $lines.Add("")
        $lines.Add("Will remove ($(@($r.ToRemove).Count)):")
        foreach ($g in @($r.ToRemove)) { $lines.Add("  - $g") }
        if (@($r.ToRemove).Count -eq 0) { $lines.Add("  (none)") }
        [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), "Details", "OK", "Information") | Out-Null
    }.GetNewClosure())

    $btnApply.Add_Click({
        $totalAdd = ($previewDataBox.Results | ForEach-Object { @($_.ToAdd).Count } | Measure-Object -Sum).Sum
        $totalRemove = ($previewDataBox.Results | ForEach-Object { @($_.ToRemove).Count } | Measure-Object -Sum).Sum
        $changedApps = @($previewDataBox.Results | Where-Object { @($_.ToAdd).Count -gt 0 -or @($_.ToRemove).Count -gt 0 }).Count
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Apply the changes shown above to $changedApps app(s) in Intune? $totalAdd assignment(s) will be added and $totalRemove removed.`n`nAny assignment that isn't in an app's catalog groups is removed, including ones this catalog doesn't know about. This can't be undone from here.",
            "Confirm batch apply", "YesNo", "Warning", "Button2")
        if ($r -ne "Yes") { return }
        & $runBatch "Apply"
    }.GetNewClosure())

    # Shared by both the Add and Remove favorite-group buttons below - both
    # only ever change catalog data (via $candidateApps, whose app objects
    # are the same live references $Global:App.Apps holds), then need the SAME
    # re-derive-and-Preview-again refresh: eligibility and the Preview/
    # Apply snapshot are re-derived from $candidateApps and written into
    # the SAME boxes $runBatch already closed over (see the note by
    # $eligibleAppsBox/$appsForScriptBox above for why boxes, not plain
    # variables, are needed here), then Preview just re-runs in place - no
    # second window. Re-filtering rather than assuming the checked set is
    # now exactly right matters for Add specifically: an app that had NO
    # groups at all before is only newly eligible if the group was
    # actually added to it, not to every app in $candidateApps.
    $refreshAfterCatalogEdit = {
        $eligibleAppsBox.Value = @($candidateApps | Where-Object {
            $_.appId -and (@($_.requiredFor).Count -gt 0 -or @($_.availableFor).Count -gt 0 -or @($_.uninstallFor).Count -gt 0)
        })
        $appsForScriptBox.Value = @($eligibleAppsBox.Value | ForEach-Object {
            [pscustomobject]@{
                AppName         = $_.appName
                AppId           = $_.appId
                RequiredGroups  = @($_.requiredFor)
                AvailableGroups = @($_.availableFor)
                UninstallGroups = @($_.uninstallFor)
            }
        })
        $scopeText = if ($isScoped) { "$($eligibleAppsBox.Value.Count) of your selected app(s) that have" } else { "every app with" }
        $lblIntro.Text = "Checks $scopeText an App ID and at least one group against Intune's CURRENT assignments. Nothing changes until you click Apply below."
        & $runBatch "Preview"
    }.GetNewClosure()

    $btnAddFavoriteGroup.Add_Click({
        $addedCount = Show-AddFavoriteGroupToAppsDialog -CandidateApps $candidateApps
        if ($addedCount -gt 0) { & $refreshAfterCatalogEdit }
    }.GetNewClosure())

    # Catalog-side only, same as Add above - removes the picked group(s)
    # from the picked apps' requiredFor/availableFor/uninstallFor and
    # saves, but doesn't touch Intune itself. The refresh above re-runs
    # Preview right after, which is what actually SHOWS the now-stale
    # Intune assignment as something "Will remove" - Apply (still a
    # separate, explicit click) is what pushes that removal to Intune.
    $btnRemoveGroup.Add_Click({
        $removedCount = Show-RemoveGroupFromAppsDialog -CandidateApps $candidateApps
        if ($removedCount -gt 0) { & $refreshAfterCatalogEdit }
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())

    # One question on close, however the dialog is closed - a running step
    # (Preview or Apply) and changes not yet applied to Intune are asked
    # about together, not in two prompts in a row.
    #
    # Warns on whatever's still outstanding against Intune - a group
    # added/removed via the buttons above (which already saved to the
    # LOCAL catalog the moment you clicked them, Apply or not) just as
    # much as any pre-existing drift this dialog opened with. Reads
    # $pendingBox, NOT $previewDataBox.Results - the latter is the
    # grid's historical record and, right after a successful Apply,
    # still shows the diff that Apply just PUSHED (that's the whole
    # point of it as a record), which would make this warning fire
    # immediately after every successful Apply if used here instead.
    # $pendingBox is exactly "still outstanding right now": set by
    # Preview, zeroed by a successful Apply - see its own comment above.
    Register-CloseConfirmation -Dialog $dlg -GetQuestion {
        $running = $procBox.Proc -and -not $procBox.Proc.HasExited
        $pending = $pendingBox.TotalAdd -gt 0 -or $pendingBox.TotalRemove -gt 0
        $pendingText = "$($pendingBox.TotalAdd) assignment(s) to add and $($pendingBox.TotalRemove) to remove aren't applied to Intune."
        if ($running) {
            $text = "A step is still running. Stop it and close?`n`nIf Apply was running, some apps may already be changed in Intune."
            if ($pending) { $text += " $pendingText" }
            return $text
        }
        if ($pending) {
            return @{ Title = "Unapplied changes"; Text = "$pendingText`n`nGroups you added or removed above are already saved in the catalog - this only affects Intune.`n`nClose without applying?" }
        }
    }.GetNewClosure() -OnConfirmed {
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) { $procBox.Proc.Kill() }
    }.GetNewClosure()
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnApply

    $dlg.Add_Shown({
        & $runBatch "Preview"
    }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
