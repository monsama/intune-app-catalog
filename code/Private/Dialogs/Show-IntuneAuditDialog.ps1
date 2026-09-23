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
        # As a tab, this goes on the page. A MessageBox raised while the
        # tab is being BUILT stops the whole Checks window mid-
        # construction - the seven tabs after this one are not built until
        # somebody presses OK - and then leaves this page blank, which is
        # exactly "I clicked OK and nothing happened". No Tag either, so
        # Run all skips a tab that has nothing to run rather than waiting
        # on it. Show-AppIdMatchDialog already handles its own empty case
        # this way.
        if ($HostTabPage) {
            $lblNothing = New-Object System.Windows.Forms.Label
            $lblNothing.Text = $msg
            $lblNothing.Location = New-Object System.Drawing.Point(15,15)
            $lblNothing.Size = New-Object System.Drawing.Size(700,40)
            $lblNothing.ForeColor = [System.Drawing.Color]::DimGray
            $HostTabPage.Controls.Add($lblNothing)
            return
        }
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
    # 500, not 420: the Pull/Push row under the list costs 42px, and at
    # 420 the list shrank to about ten pixels.
    $dlg.MinimumSize = New-Object System.Drawing.Size(700, 500)
    $dlg.MaximizeBox = $true
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $scopeText = if ($isScoped) { "the $($deployedApps.Count) selected app(s)'" } else { "every deployed app's" }
    # A difference has two possible fixes and the audit cannot know which
    # side is right - so it says both, and the buttons under the list do
    # them. It used to name Pull alone, which is exactly wrong when the
    # catalog is the source of truth: pulling throws your change away.
    $lblIntro.Text = "Checks $scopeText Metadata, Groups, Dependencies, and Assignments against what's live in Intune right now - the audit itself only reads. Where a row differs, decide which side is right and select it: Pull from Intune if Intune is right, Push to Intune if the catalog is. Double-click a row for the full detail."
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
    # Says it has not run. This panel is bordered, so an empty label draws
    # as a blank white box that reads like a field you could type in - and
    # since nothing starts itself any more, that is what this tab looks
    # like when it opens.
    $lblStatus.Text = "Not checked yet - press Run audit. It reads every deployed app from Intune one at a time, so it is the slowest check here."
    $pnlStatusInfo.Controls.Add($lblStatus)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Run audit"
    $btnRun.Location = New-Object System.Drawing.Point(825,60)
    $btnCancelAudit = New-Object System.Windows.Forms.Button
    $btnCancelAudit.Text = "Stop"
    $btnCancelAudit.Location = New-Object System.Drawing.Point(735,60)
    $btnCancelAudit.Size = New-Object System.Drawing.Size(80,26)
    $btnCancelAudit.Enabled = $false
    $btnCancelAudit.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnCancelAudit)
    $cancelAuditTip = New-Object System.Windows.Forms.ToolTip
    $cancelAuditTip.SetToolTip($btnCancelAudit, "Stops the audit. Rows already checked keep their result; the rest stay as they were. Nothing in Intune or the catalog is touched either way - this check only reads.")
    $btnRun.Size = New-Object System.Drawing.Size(80,26)
    $btnRun.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnRun)

    $grid = New-Object System.Windows.Forms.DataGridView
    Set-AppGridStyle -Grid $grid
    # An audit reads every deployed app from Intune one at a time, which on
    # a real catalog is a long, silent wait - the status line said
    # something was happening but nothing showed it moving. A marquee bar
    # (the work is per-app, and the total only becomes known once the list
    # comes back) and, below the grid, the same dark log every other
    # Graph-facing window in this app has, so a refused permission or an
    # expired certificate is readable here instead of only in the status
    # line's one sentence.
    $prgAudit = New-Object System.Windows.Forms.ProgressBar
    $prgAudit.Location = New-Object System.Drawing.Point(15,106)
    $prgAudit.Size = New-Object System.Drawing.Size(890,6)
    $prgAudit.Style = "Marquee"
    $prgAudit.MarqueeAnimationSpeed = 30
    $prgAudit.Visible = $false
    $prgAudit.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor
                       [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($prgAudit)

    $grid.Location = New-Object System.Drawing.Point(15,122)
    # Ends above the Pull/Push row, which sits between it and the log - the
    # log itself does not move.
    $grid.Size = New-Object System.Drawing.Size(890,250)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    # Several at once, because Pull and Push below act on the selection.
    $grid.MultiSelect = $true
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    $dlg.Controls.Add($grid)

    # The same dark log every other Graph-facing window here has. The
    # status line above says what the audit concluded; this says what Graph
    # was actually asked and what it answered, which is the difference
    # between "Audit failed" and "the app registration is missing
    # DeviceManagementApps.Read.All".
    $rtbAuditLog = New-Object System.Windows.Forms.RichTextBox
    $rtbAuditLog.Location = New-Object System.Drawing.Point(15,424)
    $rtbAuditLog.Size = New-Object System.Drawing.Size(890,140)
    $rtbAuditLog.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor
                          [System.Windows.Forms.AnchorStyles]::Right
    Initialize-DarkLogBox -LogBox $rtbAuditLog
    $dlg.Controls.Add($rtbAuditLog)

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
    # Binding selects the first row by itself - and with Pull/Push acting
    # on the selection, a row nobody picked must not be the one they act on.
    $grid.ClearSelection()

    # What to do about a difference, right where it is seen. Both buttons
    # open the same windows the main grid's right-click menu does, scoped
    # to the rows selected here - nothing new is pushed or pulled from this
    # dialog directly, and each of those windows still asks before it
    # changes anything.
    $btnSelectDiffering = New-Object System.Windows.Forms.Button
    $btnSelectDiffering.Name = 'btnSelectDiffering'
    $btnSelectDiffering.Text = "Select all that differ"
    $btnSelectDiffering.Location = New-Object System.Drawing.Point(15,380)
    $btnSelectDiffering.Size = New-Object System.Drawing.Size(170,30)
    $btnSelectDiffering.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $dlg.Controls.Add($btnSelectDiffering)

    $lblFixHint = New-Object System.Windows.Forms.Label
    $lblFixHint.Name = 'lblFixHint'
    $lblFixHint.AutoEllipsis = $true
    $lblFixHint.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lblFixHint.ForeColor = [System.Drawing.Color]::DimGray
    $lblFixHint.Location = New-Object System.Drawing.Point(193,380)
    $lblFixHint.Size = New-Object System.Drawing.Size(336,30)
    $lblFixHint.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($lblFixHint)

    $btnPullFromIntune = New-Object System.Windows.Forms.Button
    $btnPullFromIntune.Name = 'btnPullFromIntune'
    $btnPullFromIntune.Text = "Pull from Intune..."
    $btnPullFromIntune.Location = New-Object System.Drawing.Point(537,380)
    $btnPullFromIntune.Size = New-Object System.Drawing.Size(170,30)
    $btnPullFromIntune.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnPullFromIntune)

    $btnPushToIntune = New-Object System.Windows.Forms.Button
    $btnPushToIntune.Name = 'btnPushToIntune'
    $btnPushToIntune.Text = "Push to Intune..."
    $btnPushToIntune.Location = New-Object System.Drawing.Point(715,380)
    $btnPushToIntune.Size = New-Object System.Drawing.Size(190,30)
    $btnPushToIntune.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnPushToIntune)

    $fixTip = New-Object System.Windows.Forms.ToolTip
    $fixTip.SetToolTip($btnSelectDiffering, "Selects every row with a difference in any column. Rows that could not be checked are left out - there is nothing known to fix on them.")
    $fixTip.SetToolTip($btnPullFromIntune, "Intune is right: update the catalog to match it. Opens `"Pull metadata and groups from Intune`" for the selected app(s) - it shows what would change and asks first.")
    $fixTip.SetToolTip($btnPushToIntune, "The catalog is right: send its groups to Intune. Fixes Groups and Unknown assignments. A Metadata or Dependencies difference needs `"Deploy to Intune`" (update) instead - groups are all this sends.")

    # The rows a fix can be about: the audited ones that differ somewhere.
    # "(not checked)", "(checking...)" and "Failed..." are not differences.
    $rowDiffers = {
        param($auditRow)
        foreach ($colName in $checkColumns) {
            $cell = [string]$auditRow.Cells[$colName].Value
            if (-not $cell -or $cell -eq "OK" -or $cell -eq "(not checked)" -or $cell -eq "(checking...)" -or $cell -like "Failed*") { continue }
            return $true
        }
        return $false
    }.GetNewClosure()

    # Catalog positions of the selected rows, by name - the audit's rows
    # are sorted by name, the catalog is not, so a row index means nothing
    # there.
    $getSelectedCatalogIndices = {
        $names = @($grid.SelectedRows | ForEach-Object { [string]$_.Cells['App'].Value })
        $found = New-Object System.Collections.Generic.List[int]
        for ($ci = 0; $ci -lt $appsRef.Count; $ci++) {
            if ($names -contains [string]$appsRef[$ci].appName) { $found.Add($ci) }
        }
        return ,$found.ToArray()
    }.GetNewClosure()

    $updateFixButtons = {
        $count = $grid.SelectedRows.Count
        $idle = $btnRun.Enabled
        $btnPullFromIntune.Enabled = $idle -and $count -gt 0
        $btnPushToIntune.Enabled = $idle -and $count -gt 0
        $anyDiffer = $false
        foreach ($auditRow in $grid.Rows) { if (& $rowDiffers $auditRow) { $anyDiffer = $true; break } }
        $btnSelectDiffering.Enabled = $idle -and $anyDiffer
        $lblFixHint.Text = if (-not $idle) { "Wait for the audit to finish." }
                           elseif ($count -gt 0) { "$count selected - Pull if Intune is right, Push if the catalog is." }
                           elseif ($anyDiffer) { "Select the rows that differ, then Pull or Push." }
                           else { "" }
    }.GetNewClosure()
    $grid.Add_SelectionChanged($updateFixButtons)
    # Run audit is disabled exactly while an audit runs, and re-enabled by
    # every way one ends - so following it covers finish, failure and Stop
    # without touching any of those paths.
    $btnRun.Add_EnabledChanged($updateFixButtons)

    $btnSelectDiffering.Add_Click({
        $grid.ClearSelection()
        foreach ($auditRow in $grid.Rows) { if (& $rowDiffers $auditRow) { $auditRow.Selected = $true } }
    }.GetNewClosure())

    # Neither fix is checked here afterwards: the window it opens may have
    # been cancelled, or changed only some of what was selected, and
    # re-auditing every app for that is the slowest thing this app does. So
    # it says what to do next instead of guessing.
    $afterFix = {
        param([string]$What, [int]$Count)
        Update-Grid
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "$What for $Count app(s) - press Run audit to confirm they now match."
    }.GetNewClosure()

    $btnPullFromIntune.Add_Click({
        $indices = & $getSelectedCatalogIndices
        if ($indices.Count -eq 0) { return }
        Show-SyncMetadataDialog -ScopedIndices $indices
        & $afterFix "Pull from Intune done" $indices.Count
    }.GetNewClosure())

    $btnPushToIntune.Add_Click({
        $indices = & $getSelectedCatalogIndices
        if ($indices.Count -eq 0) { return }
        # The same split the main grid's "Push groups to Intune" makes: one
        # app goes straight to its assignment window, several to batch.
        if ($indices.Count -eq 1) { Invoke-QuickAssignGroups -Index $indices[0] }
        else { Show-BatchAssignDialog -ScopedIndices $indices }
        & $afterFix "Push to Intune done" $indices.Count
    }.GetNewClosure())
    & $updateFixButtons

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
    # Whether the run that is finishing was stopped on purpose, so the
    # ending can say "stopped" rather than "complete" - killing the two
    # processes makes their -OnComplete fire exactly as a real failure
    # would, and "Audit complete" over a half-filled grid is a lie.
    $auditCancelledBox = @{ Value = $false }
    # What each fetch records when it cannot deliver a result. Writing only
    # to the status label was not enough: the OTHER fetch's -OnComplete
    # runs afterwards and overwrote a red "... fetch failed" with a green
    # "Audit complete", leaving that fetch's columns sitting at
    # "(checking...)" under a message claiming everything was checked.
    $fetchErrorBox = @{ Messages = New-Object System.Collections.Generic.List[string] }

    $btnRun.Add_Click({
        $btnRun.Enabled = $false
        $btnCancelAudit.Enabled = $true
        $auditCancelledBox.Value = $false
        $fetchErrorBox.Messages.Clear()
        $prgAudit.Visible = $true
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
        $prgAuditRef = $prgAudit
        $rtbAuditLogRef = $rtbAuditLog
        $rowByAppNameRef = $rowByAppName
        $appByNameRef = $appByName
        $pendingBoxRef = $pendingBox
        $deployedAppsCountRef = $deployedApps.Count
        $procBox1Ref = $procBox1
        $procBox2Ref = $procBox2
        $btnCancelAuditRef = $btnCancelAudit
        $auditCancelledBoxRef = $auditCancelledBox
        $fetchErrorBoxRef = $fetchErrorBox

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
                $btnCancelAuditRef.Enabled = $false
                $prgAuditRef.Visible = $false
                if ($auditCancelledBoxRef.Value) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                    $lblStatusRef.Text = "Audit stopped - rows already checked keep their result."
                }
                elseif ($fetchErrorBoxRef.Messages.Count -gt 0) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Audit incomplete - $($fetchErrorBoxRef.Messages.ToArray() -join ' | ')"
                }
                else {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                    $lblStatusRef.Text = "Audit complete - $deployedAppsCountRef app(s) checked."
                }
                # Written once, here, after BOTH fetches have finished -
                # not after each individual app's row updates - so a
                # 49-app audit writes the cache file once, not 49 times.
                Save-LastAuditCache
            }
        }.GetNewClosure()

        # Resolves every cell a fetch left at "(checking...)" - the state a
        # row is put in when the run starts and only ever moved out of by a
        # result arriving for that exact app. A fetch that fails outright,
        # or comes back without an entry for some of the apps it was asked
        # about, used to leave those cells reading "(checking...)" forever,
        # which says "still working" about something that has already
        # stopped. Called on every exit path out of both -OnComplete
        # closures, and built here (beside $finishOne) so those closures
        # capture it - see the aliasing note above for why.
        $settleColumns = {
            param([string[]]$Columns, [string]$Text, [switch]$RunFailed)
            # Stopping on purpose kills both processes, so their -OnComplete
            # reports exactly what a real failure does. It isn't one: those
            # rows were simply never reached, and "Failed:" over a run the
            # user stopped themselves would be as misleading as
            # "(checking...)" over one that already ended.
            $wasStopped = $auditCancelledBoxRef.Value
            if ($RunFailed -and -not $wasStopped) { $fetchErrorBoxRef.Messages.Add($Text) }
            if ($dlgRef.IsDisposed) { return }
            $settled = if ($wasStopped) { "(not checked)" } else { "Failed: $Text" }
            foreach ($rowKey in $rowByAppNameRef.Keys) {
                $settleRow = $rowByAppNameRef[$rowKey]
                foreach ($colName in $Columns) {
                    if ([string]$settleRow.Cells[$colName].Value -ne "(checking...)") { continue }
                    $settleRow.Cells[$colName].Value = $settled
                }
            }
        }.GetNewClosure()
        $settleColumnsRef = $settleColumns
        $fetch1ColumnsRef = @("Metadata", "Groups", "Dependencies")
        $fetch2ColumnsRef = @("Unknown")

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

            $procBox1Ref.Proc = Start-PipelineProcess -ScriptContent $syncScript -TempScriptName ".intunepkg_embedded_audit_sync.ps1" -ArgumentString "-ConfigPath `"$configPath1Ref`"" -ExtraLogTarget $rtbAuditLogRef -OnComplete {
                param($code)
                $procBox1Ref.Proc = $null
                Remove-Item $configPath1Ref -Force -ErrorAction SilentlyContinue

                # See $finishOne's own note above - same reasoning, this
                # closure runs unconditionally on process exit regardless of
                # whether the dialog that started it is still open.
                if ($dlgRef.IsDisposed) { & $finishOne; return }

                if (-not (Test-Path $resultPath1Ref)) {
                    $failText1 = "Metadata/Groups/Dependencies fetch failed: no result written (exit code $code)."
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = $failText1
                    & $settleColumnsRef $fetch1ColumnsRef $failText1 -RunFailed
                    & $finishOne
                    return
                }
                $result1 = $null
                try {
                    $result1 = Get-Content -Path $resultPath1Ref -Raw | ConvertFrom-Json
                    Remove-Item $resultPath1Ref -Force -ErrorAction SilentlyContinue
                }
                catch {
                    $failText1 = "Metadata/Groups/Dependencies fetch failed: could not read result: $($_.Exception.Message)"
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = $failText1
                    & $settleColumnsRef $fetch1ColumnsRef $failText1 -RunFailed
                    & $finishOne
                    return
                }
                if (-not $result1.success) {
                    $failText1 = "Metadata/Groups/Dependencies fetch failed: $($result1.error)"
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = $failText1
                    & $settleColumnsRef $fetch1ColumnsRef $failText1 -RunFailed
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
                # A result that simply has no entry for some of the apps it
                # was asked about leaves those rows behind - the loop above
                # only ever writes rows it was handed.
                & $settleColumnsRef $fetch1ColumnsRef "the check finished without a result for this app."
                & $finishOne
            }.GetNewClosure()
        }
        catch {
            $failStart1 = "Could not start the Metadata/Groups/Dependencies check: $($_.Exception.Message)"
            $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
            $lblStatusRef.Text = $failStart1
            & $settleColumnsRef $fetch1ColumnsRef $failStart1 -RunFailed
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

            $procBox2Ref.Proc = Start-PipelineProcess -ScriptContent $batchScript -TempScriptName ".intunepkg_embedded_audit_assign.ps1" -ArgumentString "-ConfigPath `"$configPath2Ref`"" -ExtraLogTarget $rtbAuditLogRef -OnComplete {
                param($code)
                $procBox2Ref.Proc = $null
                Remove-Item $configPath2Ref -Force -ErrorAction SilentlyContinue

                # See $finishOne's own note above - same reasoning.
                if ($dlgRef.IsDisposed) { & $finishOne; return }

                if (-not (Test-Path $resultPath2Ref)) {
                    $failText2 = "Unknown assignments fetch failed: no result written (exit code $code)."
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = $failText2
                    & $settleColumnsRef $fetch2ColumnsRef $failText2 -RunFailed
                    & $finishOne
                    return
                }
                $result2 = $null
                try {
                    $result2 = Get-Content -Path $resultPath2Ref -Raw | ConvertFrom-Json
                    Remove-Item $resultPath2Ref -Force -ErrorAction SilentlyContinue
                }
                catch {
                    $failText2 = "Unknown assignments fetch failed: could not read result: $($_.Exception.Message)"
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = $failText2
                    & $settleColumnsRef $fetch2ColumnsRef $failText2 -RunFailed
                    & $finishOne
                    return
                }
                if (-not $result2.success) {
                    $failText2 = "Unknown assignments fetch failed: $($result2.error)"
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = $failText2
                    & $settleColumnsRef $fetch2ColumnsRef $failText2 -RunFailed
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
                # Same as Fetch 1's - see its note.
                & $settleColumnsRef $fetch2ColumnsRef "the check finished without a result for this app."
                & $finishOne
            }.GetNewClosure()
        }
        catch {
            $failStart2 = "Could not start the Unknown Assignments check: $($_.Exception.Message)"
            $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
            $lblStatusRef.Text = $failStart2
            & $settleColumnsRef $fetch2ColumnsRef $failStart2 -RunFailed
            & $finishOne
        }
    }.GetNewClosure())

    $btnCancelAudit.Add_Click({
        $auditCancelledBox.Value = $true
        $btnCancelAudit.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblStatus.Text = "Stopping the audit..."
        # Each kill makes that process's -OnComplete fire, which is what
        # re-enables Run audit and writes the ending - so stopping goes
        # through exactly the same path a finished run does.
        try { if ($procBox1.Proc -and -not $procBox1.Proc.HasExited) { $procBox1.Proc.Kill() } } catch { }
        try { if ($procBox2.Proc -and -not $procBox2.Proc.HasExited) { $procBox2.Proc.Kill() } } catch { }
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
        # The grid stretches to fill a taller page and the log lives under
        # it, so without this the grid is drawn straight over the log and
        # the Graph output has nowhere to appear.
        #
        # Anchored Top, not Bottom: inside a tab these controls sit in a
        # SCROLLING panel, where "the bottom" is the bottom of the panel's
        # content rather than of the visible page. Anchoring the log there
        # put it at y=932, past the end of a 612px page - which is exactly
        # why it could not be seen at all.
        $rtbAuditLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor
                              [System.Windows.Forms.AnchorStyles]::Right
        # The grid's own Top+Bottom anchor would stretch it back over the
        # log on the next layout pass, whatever height it is given. Top
        # only here, and its height is set to stop above the log.
        $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor
                       [System.Windows.Forms.AnchorStyles]::Right
        # The Pull/Push row sits between the grid and the log, so it is
        # Top-anchored for the same scrolling-panel reason as the log, and
        # it - not the log - is what the grid stops above.
        $btnSelectDiffering.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
        $lblFixHint.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor
                             [System.Windows.Forms.AnchorStyles]::Right
        $btnPullFromIntune.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
        $btnPushToIntune.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
        $HostTabPage.Tag = @{
            Fill          = $grid
            FillStopAbove = $btnSelectDiffering
            RunAll        = { $btnRun.PerformClick() }.GetNewClosure()
            IsBusy        = { -not $btnRun.Enabled }.GetNewClosure()
            BlockClose    = { -not $btnRun.Enabled }.GetNewClosure()
            Summary       = {
                $cols = @("Metadata", "Groups", "Dependencies", "Unknown")
                # A column that could not be checked is not a difference -
                # reported separately so "3 app(s) differ" never actually
                # means "3 app(s) we failed to ask about".
                $differ = 0
                $unchecked = 0
                foreach ($auditRow in $grid.Rows) {
                    $rowDiffers = $false
                    $rowUnchecked = $false
                    foreach ($colName in $cols) {
                        $cell = [string]$auditRow.Cells[$colName].Value
                        if (-not $cell -or $cell -eq "OK" -or $cell -eq "(not checked)") { continue }
                        if ($cell -like "Failed*" -or $cell -eq "(checking...)") { $rowUnchecked = $true }
                        else { $rowDiffers = $true }
                    }
                    if ($rowDiffers) { $differ++ }
                    if ($rowUnchecked) { $unchecked++ }
                }
                $parts = New-Object System.Collections.Generic.List[string]
                if ($differ -gt 0) { $parts.Add("$differ app(s) differ") }
                if ($unchecked -gt 0) { $parts.Add("$unchecked app(s) could not be checked") }
                $parts.ToArray() -join ", "
            }.GetNewClosure()
        }
        return
    }
    [void]$dlg.ShowDialog($Global:App.Form)
}
