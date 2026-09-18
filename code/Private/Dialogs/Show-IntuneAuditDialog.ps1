function Global:Show-IntuneAuditDialog {
    # Selected rows (if any, passed in by the caller) scope this to just
    # them; nothing selected audits the whole catalog like every other
    # -ScopedIndices dialog in this app - same convention Batch Deploy and
    # Sync Metadata already use.
    param([int[]]$ScopedIndices = @(), [System.Windows.Forms.TabPage]$HostTabPage, [System.Windows.Forms.Form]$HostForm)

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef     = $Global:App.Apps
    $tenantId    = $Global:App.GraphTenantId
    $clientId    = $Global:App.GraphClientId
    $certThumb   = $Global:App.GraphCertificateThumbprint
    $syncScript  = $Global:App.EmbeddedSyncMetadataScript
    $batchScript = $Global:App.EmbeddedBatchAssignScript

    $isScoped = $ScopedIndices.Count -gt 0
    $candidateApps = if ($isScoped) { @($ScopedIndices | ForEach-Object { $appsRef[$_] }) } else { @($appsRef) }

    $deployedApps = @($candidateApps | Where-Object { $_.appId })
    if ($deployedApps.Count -eq 0) {
        $msg = if ($isScoped) { "None of the selected app(s) have an App ID yet - nothing to audit." } else { "No apps have an App ID yet - nothing to audit." }
        [System.Windows.Forms.MessageBox]::Show($msg, "Nothing to do", "OK", "Information") | Out-Null
        return
    }

    # Local lookup by name - built once here rather than re-scanning
    # $appsRef with Where-Object from inside every nested -OnComplete
    # closure below (the same closure-safety reasoning as the "fresh
    # alias" note above: a lookup built fresh outside those closures and
    # then aliased into each one is both faster and one less thing that
    # can silently read a stale/empty capture).
    $appByName = @{}
    foreach ($a in $deployedApps) { $appByName[$a.appName] = $a }

    $dlg = New-Object System.Windows.Forms.Form
    # Which window the close buttons act on - its own, or the host's when
    # this dialog is a tab of Show-IntuneCheckDialog.
    $closeTargetBox = @{ Form = $dlg }
    $dlg.Font = Get-AppUiFont
    $dlg.Text = if ($isScoped) { "Intune Audit - $($deployedApps.Count) selected app(s)" } else { "Intune Audit" }
    $dlg.ClientSize = New-Object System.Drawing.Size(920, 620)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(700, 420)
    $dlg.MaximizeBox = $true
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $scopeText = if ($isScoped) { "the $($deployedApps.Count) selected app(s)'" } else { "every deployed app's" }
    $lblIntro.Text = "Checks $scopeText Metadata, Groups, Dependencies, and Assignments against what's actually live in Intune right now. Read-only - never changes Intune or the catalog. Double-click a row for the full detail; findings are fixed via `"Pull metadata and groups from Intune...`" (Metadata/Groups/Dependencies) or `"Push groups to Intune (multiple apps)...`" (Unknown Assignments)."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(890,48)
    $dlg.Controls.Add($lblIntro)

    # Bordered, scrollable box instead of a plain fixed-height Label -
    # $lblStatus's own .Text is set from several places below (including
    # raw exception messages, which are unbounded in length) and a fixed
    # 20px/1-line height would silently clip anything longer than that
    # with no way to see the rest. Same pattern as Show-
    # CreateInIntuneDialog's own $pnlStatusInfo.
    $pnlStatusInfo = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlStatusInfo.Location = New-Object System.Drawing.Point(15,64)
    $pnlStatusInfo.Size = New-Object System.Drawing.Size(700,40)
    $pnlStatusInfo.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $pnlStatusInfo.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $pnlStatusInfo.WrapContents = $false
    $pnlStatusInfo.AutoScroll = $true
    $pnlStatusInfo.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $pnlStatusInfo.BackColor = $Global:App.LightPalette.FieldBack
    $pnlStatusInfo.Padding = New-Object System.Windows.Forms.Padding(6)
    $dlg.Controls.Add($pnlStatusInfo)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.AutoSize = $true
    $lblStatus.MaximumSize = New-Object System.Drawing.Size(670,0)
    $lblStatus.Margin = New-Object System.Windows.Forms.Padding(0,0,0,0)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $pnlStatusInfo.Controls.Add($lblStatus)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Run audit"
    $btnRun.Location = New-Object System.Drawing.Point(825,60)
    $btnRun.Size = New-Object System.Drawing.Size(80,26)
    $btnRun.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnRun)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,114)
    # Ends 10px above Close below (it used to run 14px into it).
    $grid.Size = New-Object System.Drawing.Size(890,452)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
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
    $dlg.Controls.Add($grid)

    $colApp = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colApp.Name = "App"; $colApp.HeaderText = "App"; $colApp.FillWeight = 22
    $grid.Columns.Add($colApp) | Out-Null
    $colMetadata = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colMetadata.Name = "Metadata"; $colMetadata.HeaderText = "Metadata"; $colMetadata.FillWeight = 19
    $grid.Columns.Add($colMetadata) | Out-Null
    $colGroups = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colGroups.Name = "Groups"; $colGroups.HeaderText = "Groups"; $colGroups.FillWeight = 19
    $grid.Columns.Add($colGroups) | Out-Null
    $colDependencies = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDependencies.Name = "Dependencies"; $colDependencies.HeaderText = "Dependencies"; $colDependencies.FillWeight = 19
    $grid.Columns.Add($colDependencies) | Out-Null
    $colUnknown = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colUnknown.Name = "Unknown"; $colUnknown.HeaderText = "Unknown assignments"; $colUnknown.FillWeight = 21
    $grid.Columns.Add($colUnknown) | Out-Null

    $checkColumns = @("Metadata", "Groups", "Dependencies", "Unknown")

    # Same bold-orange/firebrick/green convention as every other check
    # dialog in this app - applied identically across all four check
    # columns instead of one bespoke rule per column.
    $grid.Add_CellFormatting({
        param($gridSender, $e)
        $colName = $grid.Columns[$e.ColumnIndex].Name
        if ($checkColumns -notcontains $colName) { return }
        $val = [string]$e.Value
        if ($val -eq "OK") {
            $e.CellStyle.ForeColor = [System.Drawing.Color]::SeaGreen
        }
        elseif ($val -like "Failed*") {
            $e.CellStyle.ForeColor = [System.Drawing.Color]::Firebrick
        }
        elseif ($val -and $val -ne "(not checked)" -and $val -ne "(checking...)") {
            $e.CellStyle.ForeColor = [System.Drawing.Color]::DarkOrange
            $e.CellStyle.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
        }
    }.GetNewClosure())

    $grid.Add_CellDoubleClick({
        param($gridSender, $e)
        if ($e.RowIndex -lt 0) { return }
        $row = $grid.Rows[$e.RowIndex]
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($colName in $checkColumns) {
            $lines.Add("$($grid.Columns[$colName].HeaderText):")
            $lines.Add("  $([string]$row.Cells[$colName].Value)")
            $lines.Add("")
        }
        [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n").TrimEnd(), "Audit detail - $([string]$row.Cells['App'].Value)", "OK", "Information") | Out-Null
    }.GetNewClosure())

    $rowByAppName = @{}
    foreach ($a in ($deployedApps | Sort-Object appName)) {
        $rowIdx = $grid.Rows.Add($a.appName, "(not checked)", "(not checked)", "(not checked)", "(not checked)")
        $rowByAppName[$a.appName] = $grid.Rows[$rowIdx]
    }

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(825,576)
    $btnClose.Size = New-Object System.Drawing.Size(80,32)
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnClose)

    $procBox1 = @{ Proc = $null }
    $procBox2 = @{ Proc = $null }
    # Ticked down by each of the two fetches' own -OnComplete as it
    # finishes - only once BOTH reach zero does the status label report
    # "audit complete" and Run audit/Close re-enable, since either fetch
    # can finish well before the other.
    $pendingBox = @{ Count = 0 }

    $btnRun.Add_Click({
        $btnRun.Enabled = $false
        foreach ($rowKey in $rowByAppName.Keys) {
            foreach ($colName in $checkColumns) { $rowByAppName[$rowKey].Cells[$colName].Value = "(checking...)" }
        }
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Auditing $($deployedApps.Count) app(s)..."
        $pendingBox.Count = 2

        # Fresh aliases for the two nested -OnComplete closures below - see
        # note at the top of Show-CreateInIntuneDialog for why this matters:
        # a plain outer-function variable isn't reliably visible two
        # closure levels deep (btnRun.Add_Click's own .GetNewClosure(),
        # then Start-PipelineProcess's own -OnComplete .GetNewClosure()
        # nested inside it) - confirmed as a real, live bug in this exact
        # dialog's own dependency-check predecessor, not a theoretical
        # concern.
        $dlgRef = $dlg
        $btnRunRef = $btnRun
        $btnCloseRef = $btnClose
        $lblStatusRef = $lblStatus
        $gridRef = $grid
        $rowByAppNameRef = $rowByAppName
        $appByNameRef = $appByName
        $pendingBoxRef = $pendingBox
        $deployedAppsCountRef = $deployedApps.Count
        $procBox1Ref = $procBox1
        $procBox2Ref = $procBox2

        $finishOne = {
            $pendingBoxRef.Count--
            # The dialog can already be closed and disposed by the time this
            # fires - Close (after a user-confirmed Kill() of a still-running
            # audit) doesn't wait for these background -OnComplete closures,
            # so the polling timer's next tick still runs this against a
            # disposed grid/button/label. Bails before touching any of them.
            if ($dlgRef.IsDisposed) { return }
            $gridRef.Refresh()
            if ($pendingBoxRef.Count -le 0) {
                $btnRunRef.Enabled = $true
                $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                $lblStatusRef.Text = "Audit complete - $deployedAppsCountRef app(s) checked."
                # Written once, here, after BOTH fetches have finished -
                # not after each individual app's row updates - so a
                # 49-app audit writes the cache file once, not 49 times.
                Save-LastAuditCache
            }
        }.GetNewClosure()

        # --- Fetch 1: Metadata + Groups + Dependencies, one pass ---
        $configApps1 = New-Object System.Collections.Generic.List[object]
        foreach ($a in $deployedApps) { $configApps1.Add([pscustomobject]@{ AppName = $a.appName; AppId = $a.appId }) }
        $configPath1 = Join-Path $env:TEMP (".intunepkg_audit_sync_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath1 = Join-Path $env:TEMP (".intunepkg_audit_sync_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config1 = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Apps                  = $configApps1.ToArray()
            OutputResultPath      = $resultPath1
        }
        $configPath1Ref = $configPath1
        $resultPath1Ref = $resultPath1
        try {
            $configJsonText1 = $config1 | ConvertTo-Json -Depth 10 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath1Ref, $configJsonText1, (New-Object System.Text.UTF8Encoding($false)))

            $procBox1Ref.Proc = Start-PipelineProcess -ScriptContent $syncScript -TempScriptName ".intunepkg_embedded_audit_sync.ps1" -ArgumentString "-ConfigPath `"$configPath1Ref`"" -OnComplete {
                param($code)
                $procBox1Ref.Proc = $null
                Remove-Item $configPath1Ref -Force -ErrorAction SilentlyContinue

                # See $finishOne's own note above - same reasoning, this
                # closure runs unconditionally on process exit regardless of
                # whether the dialog that started it is still open.
                if ($dlgRef.IsDisposed) { & $finishOne; return }

                if (-not (Test-Path $resultPath1Ref)) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Metadata/Groups/Dependencies fetch failed: no result written (exit code $code)."
                    & $finishOne
                    return
                }
                $result1 = $null
                try {
                    $result1 = Get-Content -Path $resultPath1Ref -Raw | ConvertFrom-Json
                    Remove-Item $resultPath1Ref -Force -ErrorAction SilentlyContinue
                }
                catch {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Metadata/Groups/Dependencies fetch failed: could not read result: $($_.Exception.Message)"
                    & $finishOne
                    return
                }
                if (-not $result1.success) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Metadata/Groups/Dependencies fetch failed: $($result1.error)"
                    & $finishOne
                    return
                }

                foreach ($oneResult in @($result1.results)) {
                    if (-not $rowByAppNameRef.ContainsKey($oneResult.AppName)) { continue }
                    $row = $rowByAppNameRef[$oneResult.AppName]
                    $catalogApp = $appByNameRef[$oneResult.AppName]

                    if (-not $oneResult.Success) {
                        $row.Cells['Metadata'].Value = "Failed: $($oneResult.Error)"
                        $row.Cells['Groups'].Value = "Failed: $($oneResult.Error)"
                        $row.Cells['Dependencies'].Value = "Failed: $($oneResult.Error)"
                        Set-LastAuditCacheEntry -AppName $oneResult.AppName -Metadata "Failed: $($oneResult.Error)" -Groups "Failed: $($oneResult.Error)" -Dependencies "Failed: $($oneResult.Error)"
                        continue
                    }

                    $metaDiffs = Get-CatalogMetadataFieldDiffs -Local $catalogApp.metadata -Remote $oneResult.Metadata -OdataType $oneResult.OdataType
                    $row.Cells['Metadata'].Value = if ($metaDiffs.Count -eq 0) { "OK" } else { "$($metaDiffs.Count) field(s) differ: $(($metaDiffs | ForEach-Object { $_.Field }) -join ', ')" }

                    if ($oneResult.GroupFetchOk) {
                        $groupDiffs = Get-GroupFieldDiffs -LocalApp $catalogApp -RemoteResult $oneResult
                        $row.Cells['Groups'].Value = if ($groupDiffs.Count -eq 0) { "OK" } else { "$($groupDiffs.Count) differ: $(($groupDiffs | ForEach-Object { $_.Field }) -join ', ')" }
                    }
                    else {
                        $row.Cells['Groups'].Value = "Failed: could not fetch live assignments"
                    }

                    $liveDeps = @($oneResult.Metadata.dependencies) | Sort-Object
                    $localDeps = @($catalogApp.metadata.dependencies) | Sort-Object
                    if (($liveDeps -join "|") -eq ($localDeps -join "|")) {
                        $row.Cells['Dependencies'].Value = "OK"
                    }
                    else {
                        $liveText = if ($liveDeps.Count -gt 0) { $liveDeps -join ", " } else { "(none)" }
                        $localText = if ($localDeps.Count -gt 0) { $localDeps -join ", " } else { "(none)" }
                        $row.Cells['Dependencies'].Value = "Catalog has: $localText | Intune has: $liveText"
                    }
                    Set-LastAuditCacheEntry -AppName $oneResult.AppName -Metadata ([string]$row.Cells['Metadata'].Value) -Groups ([string]$row.Cells['Groups'].Value) -Dependencies ([string]$row.Cells['Dependencies'].Value)
                }
                & $finishOne
            }.GetNewClosure()
        }
        catch {
            $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
            $lblStatusRef.Text = "Could not start the Metadata/Groups/Dependencies check: $($_.Exception.Message)"
            & $finishOne
        }

        # --- Fetch 2: Unknown Assignments ---
        $appsForScript2 = @($deployedApps | ForEach-Object {
            [pscustomobject]@{
                AppName         = $_.appName
                AppId           = $_.appId
                RequiredGroups  = @($_.requiredFor)
                AvailableGroups = @($_.availableFor)
                UninstallGroups = @($_.uninstallFor)
            ExcludeGroups   = @($_.excludeFor)
            }
        })
        $configPath2 = Join-Path $env:TEMP (".intunepkg_audit_assign_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath2 = Join-Path $env:TEMP (".intunepkg_audit_assign_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config2 = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Mode                  = "Preview"
            Apps                  = $appsForScript2
            OutputResultPath      = $resultPath2
        }
        $configPath2Ref = $configPath2
        $resultPath2Ref = $resultPath2
        try {
            $configJsonText2 = $config2 | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath2Ref, $configJsonText2, (New-Object System.Text.UTF8Encoding($false)))

            $procBox2Ref.Proc = Start-PipelineProcess -ScriptContent $batchScript -TempScriptName ".intunepkg_embedded_audit_assign.ps1" -ArgumentString "-ConfigPath `"$configPath2Ref`"" -OnComplete {
                param($code)
                $procBox2Ref.Proc = $null
                Remove-Item $configPath2Ref -Force -ErrorAction SilentlyContinue

                # See $finishOne's own note above - same reasoning.
                if ($dlgRef.IsDisposed) { & $finishOne; return }

                if (-not (Test-Path $resultPath2Ref)) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Unknown assignments fetch failed: no result written (exit code $code)."
                    & $finishOne
                    return
                }
                $result2 = $null
                try {
                    $result2 = Get-Content -Path $resultPath2Ref -Raw | ConvertFrom-Json
                    Remove-Item $resultPath2Ref -Force -ErrorAction SilentlyContinue
                }
                catch {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Unknown assignments fetch failed: could not read result: $($_.Exception.Message)"
                    & $finishOne
                    return
                }
                if (-not $result2.success) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Unknown assignments fetch failed: $($result2.error)"
                    & $finishOne
                    return
                }

                foreach ($oneResult in @($result2.data)) {
                    if (-not $rowByAppNameRef.ContainsKey($oneResult.AppName)) { continue }
                    $row = $rowByAppNameRef[$oneResult.AppName]
                    $toRemove = @($oneResult.ToRemove)
                    $row.Cells['Unknown'].Value = if ($toRemove.Count -eq 0) { "OK" } else { "$($toRemove.Count) unknown: $($toRemove -join ', ')" }
                    Set-LastAuditCacheEntry -AppName $oneResult.AppName -Unknown ([string]$row.Cells['Unknown'].Value)
                }
                & $finishOne
            }.GetNewClosure()
        }
        catch {
            $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
            $lblStatusRef.Text = "Could not start the Unknown Assignments check: $($_.Exception.Message)"
            & $finishOne
        }
    }.GetNewClosure())

    $btnClose.Add_Click({ $closeTargetBox.Form.Close() }.GetNewClosure())
    # The audit only reads from Intune - closing just stops it, no question
    # needed, however the dialog is closed.
    $dlg.Add_FormClosing({
        try { if ($procBox1.Proc -and -not $procBox1.Proc.HasExited) { $procBox1.Proc.Kill() } } catch { }
        try { if ($procBox2.Proc -and -not $procBox2.Proc.HasExited) { $procBox2.Proc.Kill() } } catch { }
    }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    # Deliberately NOT also AcceptButton, unlike a couple of other dialogs'
    # Close buttons - every OTHER dialog whose Close handler shows a
    # blocking "still running, stop and close?" confirmation (Create,
    # Sync, Batch Assign, Bulk Delete, ...) leaves AcceptButton pointing at
    # its own PRIMARY action button instead, never at Close - this was the
    # one exception, and a live report showed "No" on that confirmation
    # still closing the dialog. Removing it matches the working convention
    # everywhere else this pattern is used.

    # Deferred to Add_Shown - same reasoning as Show-GroupDriftCheckDialog's
    # own Add_Shown: kicking off the fetch before the window is actually
    # realized can leave a WaitCursor-equivalent UI state that doesn't
    # reliably stick, and this dialog's whole job is telling you what's
    # true RIGHT NOW, not showing stale results from some earlier run.
    $dlg.Add_Shown({
        $btnRun.PerformClick()
    }.GetNewClosure())

    Set-Theme -Control $dlg
    # Set-ThemeRecursive's combined Panel/FlowLayoutPanel/... case
    # unconditionally resets BackColor to the dialog's own plain
    # background - reapplied so $pnlStatusInfo actually looks like the
    # bordered, distinct "field" it's meant to be.
    $pnlStatusInfo.BackColor = $Global:App.LightPalette.FieldBack
    if ($HostTabPage) {
        $closeTargetBox.Form = $HostForm
        $btnClose.Visible = $false
        [void](Move-DialogToTabPage -Dialog $dlg -Page $HostTabPage)
        return
    }
    [void]$dlg.ShowDialog($Global:App.Form)
}
