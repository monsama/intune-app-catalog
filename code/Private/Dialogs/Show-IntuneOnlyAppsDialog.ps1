function Global:Show-IntuneOnlyAppsDialog {
    # -HostTabPage: become one tab of Show-ChecksDialog instead of a window
    # of its own, the same way the other seven checks in there do. Every
    # handler below is unchanged - they reference controls by variable, not
    # by whichever container the controls happen to sit in.
    param([System.Windows.Forms.TabPage]$HostTabPage, [System.Windows.Forms.Form]$HostForm)
    # Plain local aliases - see note in Start-IntuneAppLookup. This dialog's
    # own closures (populateGrid, the action button handler) cannot reliably
    # read or write $Script:-qualified variables directly.
    $appsRef       = $Global:App.Apps
    $cacheRef      = $Global:App.IntuneAppsCache
    $unsavedBoxRef = $Global:App.UnsavedChangesBox
    $linkedFilePathRef = $Global:App.LinkedFilePath

    # Tracks whether anything changed, so the caller (a plain, top-level
    # button handler - the same proven-safe context every other Update-Grid
    # call site uses) can refresh the main catalog grid itself after this
    # dialog closes, rather than this dialog trying to reach across into the
    # main grid's own refresh from deep inside a nested closure.
    $anyAddedBox = @{ Value = $false }

    # Counts how many of this dialog's THREE separate background fetches
    # (Refresh, the single-row "Add to catalog..." group fetch, and the
    # bulk "Add checked to catalog" queue) are currently in flight - none
    # of the existing per-button Enabled flags work as a single "is
    # anything running" signal on their own ($btnAction.Enabled in
    # particular also means "a row happens to be selected", unrelated to
    # any fetch), so this is a dedicated counter instead. Read by
    # FormClosing below to block the window from closing mid-fetch, which
    # would otherwise leave a Timer still ticking against controls on a
    # disposed form - and for the bulk queue specifically, keep silently
    # calling Save-AppsToFile/mutating the catalog after the user believes
    # they've cancelled.
    $busyBox = @{ Count = 0 }
    # Asked to stop. Read at the top of each turn of the bulk-add queue,
    # which is the only long-running thing here - one Graph fetch per
    # checked app, and on a tenant with a hundred strangers in it that is
    # a wait with no way out of it.
    $cancelAddBox = @{ Value = $false }
    # Dependency names seen on the apps added by the run in progress, and
    # the ones already offered across the whole session. Two lists, not
    # one: the first is emptied at the end of each pass so the offer is
    # about what that pass found, the second never is, so a dependency
    # declined once is not asked about again and a dependency cycle in
    # Intune cannot bounce the queue back and forth forever.
    $pendingDepsBox = @{ Names = New-Object System.Collections.Generic.List[string] }
    $offeredDepsBox = @{ Names = New-Object System.Collections.Generic.List[string] }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Intune sync check"
    $dlg.ClientSize = New-Object System.Drawing.Size(760, 521)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Compares Intune against this catalog three ways: apps in Intune with no matching catalog entry (`"Not in catalog`"), catalog apps whose Intune app was renamed since (`"Renamed in Intune`" - matched by App ID, not name), and catalog apps whose stored App ID no longer exists in Intune at all (`"Deleted from Intune`")."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(730,48)
    $dlg.Controls.Add($lblIntro)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,68)
    $lblStatus.Size = New-Object System.Drawing.Size(570,20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    # An empty result must not read as a clean one to somebody who did
    # not watch this open.
    $lblStatus.Text = "Not checked yet - press Refresh from Intune."
    $dlg.Controls.Add($lblStatus)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh from Intune"
    $btnRefresh.Location = New-Object System.Drawing.Point(595,66)
    $btnRefresh.Size = New-Object System.Drawing.Size(150,26)
    $dlg.Controls.Add($btnRefresh)

    $grid = New-Object System.Windows.Forms.DataGridView
    Set-AppGridStyle -Grid $grid
    $grid.Location = New-Object System.Drawing.Point(15,96)
    $grid.Size = New-Object System.Drawing.Size(730,368)
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    # Commits a checkbox cell's edit the instant it's clicked, rather than
    # leaving it pending until the cell loses focus - a well-known
    # DataGridView quirk (unlike CheckedListBox, there's no CheckOnClick
    # here) where a checkbox visually toggles immediately but its actual
    # .Value doesn't update until the edit is explicitly committed. Without
    # this, checking a box and immediately clicking a button elsewhere -
    # without first clicking away to commit it - reads back the OLD,
    # unchanged value, making it look like the checkbox "can't be checked"
    # at all.
    $grid.Add_CurrentCellDirtyStateChanged({
        if ($grid.IsCurrentCellDirty) {
            $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    }.GetNewClosure())

    $colSelected = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colSelected.Name = "Selected"; $colSelected.HeaderText = ""; $colSelected.FillWeight = 8
    $grid.Columns.Add($colSelected) | Out-Null
    $colType = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colType.Name = "Type"; $colType.HeaderText = "Type"; $colType.FillWeight = 16
    $colType.ReadOnly = $true
    $grid.Columns.Add($colType) | Out-Null
    $colIntuneName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colIntuneName.Name = "IntuneName"; $colIntuneName.HeaderText = "Name in Intune"; $colIntuneName.FillWeight = 27
    $colIntuneName.ReadOnly = $true
    $grid.Columns.Add($colIntuneName) | Out-Null
    $colCatalogName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCatalogName.Name = "CatalogName"; $colCatalogName.HeaderText = "Name in catalog"; $colCatalogName.FillWeight = 27
    $colCatalogName.ReadOnly = $true
    $grid.Columns.Add($colCatalogName) | Out-Null
    $colId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colId.Name = "Id"; $colId.HeaderText = "App ID"; $colId.FillWeight = 30
    $colId.ReadOnly = $true
    $grid.Columns.Add($colId) | Out-Null
    $dlg.Controls.Add($grid)

    # Bulk path, separate from $btnAction below - tick any number of
    # "Not in catalog" rows and add them all at once with name, App ID and
    # groups, no editor per app. $btnAction (further right) remains
    # for the single-row, full-editor add, plus the Renamed/Deleted
    # actions, which don't make sense to batch the same way.
    $btnAddChecked = New-Object System.Windows.Forms.Button
    $btnAddChecked.Text = "Add ticked to catalog"
    $btnAddChecked.Location = New-Object System.Drawing.Point(15,474)
    $btnAddChecked.Size = New-Object System.Drawing.Size(175,32)
    $dlg.Controls.Add($btnAddChecked)
    $addCheckedTip = New-Object System.Windows.Forms.ToolTip
    $addCheckedTip.SetToolTip($btnAddChecked, "Adds every TICKED row at once, with its name, App ID and groups - it does not open the editor. Only ""Not in catalog"" rows can be ticked. For one app with its metadata filled in, select the row and use the button to the right instead.")
    # Says how many rows are ticked, because "checked" and "selected" are
    # two different things in this grid and the button that acts on ticks
    # sits next to one that acts on the highlighted row. A number is the
    # shortest way to say which of the two you are about to use.
    $syncAddCheckedLabel = {
        $ticked = 0
        foreach ($row in $grid.Rows) {
            if ([string]$row.Cells["Type"].Value -ne "Not in catalog") { continue }
            if ([bool]$row.Cells["Selected"].Value) { $ticked++ }
        }
        $btnAddChecked.Text = if ($ticked -gt 0) { "Add $ticked ticked to catalog" } else { "Add ticked to catalog" }
    }.GetNewClosure()

    # Same "Select all"/"Select none" convenience the other checkbox-driven
    # bulk-pick dialogs already have (Batch Deploy, Sync Metadata, Bulk
    # Delete) - this grid's checkbox column was the one bulk-selection UI
    # in the app missing them, forcing every row to be clicked
    # individually.
    $btnSelectAllChecked = New-Object System.Windows.Forms.Button
    $btnSelectAllChecked.Text = "Select all"
    # Equal widths for a pair sitting side by side - 90 next to 100 is
    # visible in a way a lone button's width never is. 32px, not the 26px
    # the other Select all/none pairs use, because these are in the footer
    # row with Add checked/Close rather than tucked under a list.
    $btnSelectAllChecked.Location = New-Object System.Drawing.Point(200,474)
    $btnSelectAllChecked.Size = New-Object System.Drawing.Size(100,32)
    $dlg.Controls.Add($btnSelectAllChecked)

    $btnSelectNoneChecked = New-Object System.Windows.Forms.Button
    $btnSelectNoneChecked.Text = "Select none"
    $btnSelectNoneChecked.Location = New-Object System.Drawing.Point(310,474)
    $btnSelectNoneChecked.Size = New-Object System.Drawing.Size(100,32)
    $dlg.Controls.Add($btnSelectNoneChecked)

    $btnAction = New-Object System.Windows.Forms.Button
    $btnAction.Text = "Review and add..."
    # 420, not 515. The gap was there to keep this single-row action clear
    # of the bulk buttons, with Close filling the space to its right - and
    # as a tab, Close is hidden, so it read as a button that had come
    # loose. 20px still separates it from "Select none"; 115 looked like a
    # mistake.
    $btnAction.Location = New-Object System.Drawing.Point(420,474)
    $btnAction.Size = New-Object System.Drawing.Size(140,32)
    $btnAction.Enabled = $false
    $dlg.Controls.Add($btnAction)
    $actionTip = New-Object System.Windows.Forms.ToolTip
    $actionTip.SetToolTip($btnAction, "Acts on the ONE highlighted row, not on the ticks - its label follows that row: opens the editor with the app's metadata and groups filled in ready to save, syncs the catalog name to match Intune, or clears an App ID that no longer exists there.")

    $btnCancelAdd = New-Object System.Windows.Forms.Button
    $btnCancelAdd.Text = "Stop"
    $btnCancelAdd.Location = New-Object System.Drawing.Point(570,474)
    $btnCancelAdd.Size = New-Object System.Drawing.Size(85,32)
    $btnCancelAdd.Enabled = $false
    $btnCancelAdd.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $dlg.Controls.Add($btnCancelAdd)
    $cancelAddTip = New-Object System.Windows.Forms.ToolTip
    $cancelAddTip.SetToolTip($btnCancelAdd, "Stops the bulk add after the app it is currently reading. Apps already added are saved and kept; the rest are left alone.")
    $btnCancelAdd.Add_Click({
        if (-not $btnCancelAdd.Enabled) { return }
        $cancelAddBox.Value = $true
        $btnCancelAdd.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblStatus.Text = "Stopping after this app..."
    }.GetNewClosure())

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(665,474)
    $btnClose.Size = New-Object System.Drawing.Size(80,32)
    $dlg.Controls.Add($btnClose)

    # Stored in a variable so both the initial load and the post-action
    # refresh can reuse the exact same logic.
    $populateGrid = {
        # Explicitly force DataSource to $null before clearing - this grid is
        # never meant to be data-bound (rows are always added manually via
        # .Rows.Add() below), but .Rows.Clear() throws "cannot be
        # programmatically cleared when...data-bound..." if DataSource is
        # ever non-null for any reason, which has been observed happening
        # here. This unconditionally prevents that regardless of cause.
        $grid.DataSource = $null
        $grid.Rows.Clear()

        # Shared with the Settings-toggled startup drift check (Get-
        # IntuneCatalogDrift, CatalogLogic.ps1) - same walk, same three
        # buckets, so the two never quietly disagree.
        $drift = Get-IntuneCatalogDrift -Apps $appsRef -IntuneApps $cacheRef
        $missing = $drift.Missing
        $renamed = $drift.Renamed
        $deletedFromIntune = $drift.DeletedFromIntune

        foreach ($o in ($missing | Sort-Object displayName)) {
            [void]$grid.Rows.Add($false, "Not in catalog", $o.displayName, "", $o.id)
        }
        # No checkbox at all on these two kinds, not a read-only one. Bulk
        # "add checked" only ever applies to "Not in catalog" rows, and a
        # checkbox that cannot be ticked still draws as a checkbox - it
        # reads as "tickable, and my click missed" rather than "this row
        # is not part of that button". Swapping the cell for a plain empty
        # one removes the offer instead of refusing it.
        foreach ($r in ($renamed | Sort-Object IntuneName)) {
            $rIdx = $grid.Rows.Add($false, "Renamed in Intune", $r.IntuneName, $r.CatalogName, $r.Id)
            $grid.Rows[$rIdx].Cells["Selected"] = New-Object System.Windows.Forms.DataGridViewTextBoxCell
            $grid.Rows[$rIdx].Cells["Selected"].ReadOnly = $true
        }
        foreach ($d in ($deletedFromIntune | Sort-Object appName)) {
            $dIdx = $grid.Rows.Add($false, "Deleted from Intune", "", $d.appName, $d.appId)
            $grid.Rows[$dIdx].Cells["Selected"] = New-Object System.Windows.Forms.DataGridViewTextBoxCell
            $grid.Rows[$dIdx].Cells["Selected"].ReadOnly = $true
        }

        if ($missing.Count -eq 0 -and $renamed.Count -eq 0 -and $deletedFromIntune.Count -eq 0) {
            $lblStatus.ForeColor = [System.Drawing.Color]::SeaGreen
            $lblStatus.Text = "No differences found - all $($cacheRef.Count) app(s) in Intune match the catalog."
        }
        else {
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
            $lblStatus.Text = "$($cacheRef.Count) app(s) in Intune - $($missing.Count) not in catalog, $($renamed.Count) renamed since last synced, $($deletedFromIntune.Count) deleted from Intune."
        }
        # Rebuilding the rows resets every tick, so the count on the
        # button has to come back to zero with them.
        & $syncAddCheckedLabel
    }.GetNewClosure()

    $btnRefresh.Add_Click({
        $btnRefresh.Enabled = $false
        $busyBox.Count++
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Fetching apps from Intune..."
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnRefreshRef = $btnRefresh
        $dlgRef = $dlg
        $lblStatusRef = $lblStatus
        $populateGridRef = $populateGrid
        $busyBoxRef = $busyBox

        Start-IntuneAppLookup -OnComplete {
            param($ok, $data)
            $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
            # See the same pattern's note in Show-WingetSearchDialog - forces
            # an immediate cursor repaint instead of waiting on a mouse move.
            [System.Windows.Forms.Application]::DoEvents()
            [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
            $btnRefreshRef.Enabled = $true
            $busyBoxRef.Count--
            if (-not $ok) {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblStatusRef.Text = "Fetch failed: $data"
                return
            }
            & $populateGridRef
        }.GetNewClosure()
    }.GetNewClosure())

    $grid.Add_SelectionChanged({
        if ($grid.SelectedRows.Count -eq 0) {
            $btnAction.Enabled = $false
            return
        }
        $btnAction.Enabled = $true
        $type = [string]$grid.SelectedRows[0].Cells["Type"].Value
        # "Review and add...", not "Add to catalog..." - that read as a
        # single-row twin of "Add ticked to catalog" next to it, when the
        # two differ in what they produce as well as how many: this one
        # opens the editor with the app's metadata and groups filled in,
        # the bulk one writes the entry and moves on.
        $btnAction.Text = if ($type -eq "Renamed in Intune") { "Sync name from Intune" } elseif ($type -eq "Deleted from Intune") { "Clear stale App ID" } else { "Review and add..." }
    }.GetNewClosure())

    $btnAction.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { return }
        $type = [string]$grid.SelectedRows[0].Cells["Type"].Value
        $intuneName = [string]$grid.SelectedRows[0].Cells["IntuneName"].Value
        $id = [string]$grid.SelectedRows[0].Cells["Id"].Value

        if ($type -eq "Renamed in Intune") {
            $catalogName = [string]$grid.SelectedRows[0].Cells["CatalogName"].Value
            $r = [System.Windows.Forms.MessageBox]::Show(
                "Rename this catalog entry from`n`n  `"$catalogName`"`n`nto match Intune's current name:`n`n  `"$intuneName`"`n`nContinue?",
                "Sync name from Intune", "YesNo", "Question", "Button2")
            if ($r -ne "Yes") { return }
            $target = $appsRef | Where-Object { $_.appId -eq $id } | Select-Object -First 1
            if ($target) {
                $target.appName = $intuneName
                $unsavedBoxRef.Value = $true
                $anyAddedBox.Value = $true
                # Direct-save, not just staged in memory - same reasoning
                # as every other single, atomic action made direct-save
                # this session.
                [void](Save-AppsToFile -Path $linkedFilePathRef)
                & $populateGrid
            }
        }
        elseif ($type -eq "Deleted from Intune") {
            $catalogName = [string]$grid.SelectedRows[0].Cells["CatalogName"].Value
            $r = [System.Windows.Forms.MessageBox]::Show(
                "`"$catalogName`" has App ID $id in the catalog, but that App ID no longer exists in Intune - it was likely deleted there directly, outside this tool.`n`nClear the stale App ID from this catalog entry? It stays in the catalog, just without an ID - use `"Deploy to Intune`" afterward if it should be re-created.",
                "Clear stale App ID", "YesNo", "Warning", "Button2")
            if ($r -ne "Yes") { return }
            $target = $appsRef | Where-Object { $_.appId -eq $id } | Select-Object -First 1
            if ($target) {
                $target.appId = ""
                $unsavedBoxRef.Value = $true
                $anyAddedBox.Value = $true
                [void](Save-AppsToFile -Path $linkedFilePathRef)
                & $populateGrid
            }
        }
        else {
            $btnAction.Enabled = $false
            $busyBox.Count++
            $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
            $lblStatus.Text = "Fetching current group assignments from Intune..."
            $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

            # Fresh aliases for the nested -OnComplete closure - see note at
            # the top of Show-CreateInIntuneDialog for why this matters here
            # too.
            $intuneNameRef2 = $intuneName
            $idRef2 = $id
            $appsRefRef2 = $appsRef
            $unsavedBoxRefRef2 = $unsavedBoxRef
            $anyAddedBoxRef2 = $anyAddedBox
            $linkedFilePathRefRef2 = $linkedFilePathRef
            $populateGridRef2 = $populateGrid
            $dlgRef2 = $dlg
            $lblStatusRef2 = $lblStatus
            $btnActionRef2 = $btnAction
            $busyBoxRef2 = $busyBox

            Start-AppMetadataFetch -AppId $id -OnComplete {
                param($ok, $errMsg, $data)
                $dlgRef2.Cursor = [System.Windows.Forms.Cursors]::Default
                # Cursor.Current + DoEvents, not just Form.Cursor - see the
                # note on this same pattern in Show-WingetSearchDialog: a
                # confirmed live report of the wait cursor sticking around
                # after results/UI had already updated.
                [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
                [System.Windows.Forms.Application]::DoEvents()
                [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
                $btnActionRef2.Enabled = $true
                $busyBoxRef2.Count--

                # A failed fetch still opens the editor - the whole point of
                # this button is adding the app locally, and a Graph hiccup
                # fetching its CURRENT group assignments shouldn't block
                # that; it just means groups start blank, same as before
                # this fetch existed at all. Not silent though - a brief
                # DarkOrange note before the editor opens, same convention
                # as every other "degraded but continuing" fetch failure in
                # this file.
                if ($ok) {
                    $lblStatusRef2.Text = ""
                }
                else {
                    $lblStatusRef2.ForeColor = [System.Drawing.Color]::DarkOrange
                    $lblStatusRef2.Text = "Could not fetch current group assignments ($errMsg) - opening with blank groups."
                }
                $prefill = [pscustomobject]@{
                    appName      = $intuneNameRef2
                    appId        = $idRef2
                    # Same three as the bulk path - see its own note. The
                    # editor opens with the Winget field already filled for
                    # an app that is plainly a Winget app.
                    wingetId     = if ($ok) { Get-WingetIdFromInstallCommand -InstallCommand ([string]$data.InstallCommandLine) } else { "" }
                    intuneAppType    = if ($ok) { Get-FriendlyIntuneAppType -ODataType ([string]$data.OdataType) } else { "" }
                    intuneAppVersion = if ($ok) { [string]$data.DisplayVersion } else { "" }
                    requiredFor  = if ($ok) { @($data.RequiredGroupNames) } else { @() }
                    availableFor = if ($ok) { @($data.AvailableGroupNames) } else { @() }
                    uninstallFor = if ($ok) { @($data.UninstallGroupNames) } else { @() }
                    # Same fetch, same waste, same fix as the bulk path -
                    # the editor opens with this app's real values filled
                    # in rather than blank fields for things Intune had
                    # already told us.
                    metadata     = if ($ok) { ConvertTo-CatalogMetadataFromFetch -Fetched $data } else { $null }
                }
                # Opens plain, not auto-deploying - this used to auto-open
                # "Deploy to Intune..." the instant the editor showed, but
                # that meant the Deploy dialog popped up immediately,
                # before there was any chance to set a Winget ID first (a
                # detail Deploy to Intune's own defaults care about). Groups
                # and metadata are still both reachable from here - groups
                # via "Pull groups from Intune..." (which this dialog's own
                # fetch above already primed requiredFor/availableFor/
                # uninstallFor with, so it's a re-confirm not a first
                # fetch), metadata via "Deploy to Intune..." itself, once
                # Winget ID (or a custom install script) is actually set.
                $editorResult = Show-AppEditor -ExistingApp $prefill
                if ($editorResult) {
                    [void]$appsRefRef2.Add($editorResult.App)
                    $unsavedBoxRefRef2.Value = $true
                    $anyAddedBoxRef2.Value = $true
                    [void](Save-AppsToFile -Path $linkedFilePathRefRef2)
                    & $populateGridRef2   # the just-added app drops out of the "not in catalog" list
                }
            }.GetNewClosure()
        }
    }.GetNewClosure())

    $btnSelectAllChecked.Add_Click({
        $grid.EndEdit()
        foreach ($row in $grid.Rows) {
            if ([string]$row.Cells["Type"].Value -eq "Not in catalog") { $row.Cells["Selected"].Value = $true }
        }
        & $syncAddCheckedLabel
    }.GetNewClosure())
    $btnSelectNoneChecked.Add_Click({
        $grid.EndEdit()
        foreach ($row in $grid.Rows) {
            if ([string]$row.Cells["Type"].Value -eq "Not in catalog") { $row.Cells["Selected"].Value = $false }
        }
        & $syncAddCheckedLabel
    }.GetNewClosure())
    # Wired here rather than next to the CurrentCellDirtyStateChanged
    # handler further up, which is created before $syncAddCheckedLabel
    # exists and so cannot see it - a closure captures what is there when
    # it is built, not what appears later.
    $grid.Add_CellValueChanged({
        param($gridSender, $e)
        if ($e.ColumnIndex -lt 0) { return }
        if ($grid.Columns[$e.ColumnIndex].Name -ne "Selected") { return }
        & $syncAddCheckedLabel
    }.GetNewClosure())

    # Self-referencing queue-runner, same pattern as Show-BatchDeployDialog's
    # own $RunNextBox - fetches each checked app's CURRENT Intune group
    # assignments one at a time (each fetch runs in its own runspace via
    # Start-AppMetadataFetch) rather than firing every fetch at once.
    # Metadata deliberately stays OUT of this bulk path, unlike the
    # single-row "Add to catalog..." button above - that one auto-opens a
    # single, human-reviewable Deploy-to-Intune dialog per app; doing that
    # N times in a row for a bulk add would be far more tedious than
    # useful, so bulk-added apps still pick up metadata later via "Sync
    # metadata..." instead, same as before this queue existed.
    $RunAddQueueBox = @{ Value = $null }
    $RunAddQueueBox.Value = {
        param($Queue, $QueueIndex, $AddedCount, $FailedGroupFetchCount)

        # Cancel joins the same ending rather than getting one of its own:
        # the apps already added are real, and they have to be saved,
        # reported, and have the grid put back exactly as a full run does.
        # Anything else leaves them added in memory and not on disk.
        $stoppedEarly = $cancelAddBox.Value -and $QueueIndex -lt $Queue.Count
        if ($QueueIndex -ge $Queue.Count -or $stoppedEarly) {
            $btnAddChecked.Enabled = $true
            $btnAction.Enabled = $true
            $grid.Enabled = $true
            $btnCancelAdd.Enabled = $false
            $busyBox.Count--
            $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
            # See the note on this same pattern above (Start-AppMetadataFetch's
            # own -OnComplete) - same fix, same reason.
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Application]::DoEvents()
            [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
            $lblStatus.ForeColor = [System.Drawing.Color]::SeaGreen
            $lblStatus.Text = ""
            $unsavedBoxRef.Value = $true
            $anyAddedBox.Value = $true
            [void](Save-AppsToFile -Path $linkedFilePathRef)
            # A failed group fetch doesn't block adding the app (see the
            # per-item comment below), but it shouldn't be silent either -
            # otherwise "added N apps" reads as fully successful even when
            # some came in with blank groups because Graph hiccuped.
            $addedMsg = if ($stoppedEarly) {
                "Stopped after $AddedCount of $($Queue.Count) app(s). Those are saved to the catalog with their metadata and current group assignments; the rest were not touched."
            } else {
                "Added $AddedCount app(s) to the catalog, with the metadata, detection rule and group assignments they have in Intune right now. Set a Winget ID for any of them that should deploy from the shared winget package."
            }
            if ($FailedGroupFetchCount -gt 0) {
                $addedMsg += "`n`n$FailedGroupFetchCount of them could not be read from Intune (Graph error) - those were added with their name and App ID only, and no metadata or groups."
            }
            [System.Windows.Forms.MessageBox]::Show($addedMsg, "Added", "OK", "Information") | Out-Null
            & $populateGrid   # the just-added apps drop out of the "not in catalog" list

            # An app whose dependency is missing from the catalog is a
            # half-imported app: deploy order, the dependency overview and
            # the audit all read that list, and every one of them is wrong
            # about an app that is not there. The names came back with the
            # metadata above, so this costs nothing to notice.
            #
            # Offered, not done silently - these are apps the user did not
            # tick, and adding them behind their back is exactly the kind
            # of helpfulness nobody asked for. Answering yes runs the same
            # queue again, so dependencies OF the dependencies are caught
            # on the next pass; $offeredDepsBox stops a cycle in Intune
            # from turning that into a loop.
            $stillMissing = New-Object System.Collections.Generic.List[object]
            foreach ($depName in @($pendingDepsBox.Names.ToArray() | Sort-Object -Unique)) {
                if (-not $depName) { continue }
                if ($offeredDepsBox.Names -contains $depName) { continue }
                if (@($appsRef | Where-Object { $_.appName -eq $depName }).Count -gt 0) { continue }
                $depApp = @($cacheRef | Where-Object { [string]$_.displayName -eq $depName }) | Select-Object -First 1
                if (-not $depApp) { continue }
                $offeredDepsBox.Names.Add($depName)
                $stillMissing.Add([pscustomobject]@{ Name = $depName; Id = [string]$depApp.id })
            }
            $pendingDepsBox.Names.Clear()
            if ($stillMissing.Count -gt 0 -and -not $stoppedEarly) {
                $depList = ($stillMissing.ToArray() | ForEach-Object { $_.Name }) -join "`n  - "
                $r = [System.Windows.Forms.MessageBox]::Show(
                    "What you just added depends on $($stillMissing.Count) app(s) that are not in this catalog:`n`n  - $depList`n`nWithout them, deploy order and the dependency overview are working from an incomplete picture. Add them too?",
                    "Dependencies missing from the catalog", "YesNo", "Question", "Button1")
                if ($r -eq "Yes") {
                    $btnAddChecked.Enabled = $false
                    $btnAction.Enabled = $false
                    $grid.Enabled = $false
                    $cancelAddBox.Value = $false
                    $btnCancelAdd.Enabled = $true
                    $busyBox.Count++
                    $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                    & $RunAddQueueBox.Value -Queue $stillMissing.ToArray() -QueueIndex 0 -AddedCount 0 -FailedGroupFetchCount 0
                }
            }
            return
        }

        $currentItem = $Queue[$QueueIndex]
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Fetching group assignments $($QueueIndex+1) of $($Queue.Count): $($currentItem.Name)..."

        # Fresh aliases for this nested -OnComplete closure - see note at
        # the top of Show-CreateInIntuneDialog for why this matters here
        # too.
        $currentItemRef = $currentItem
        $appsRefRef3 = $appsRef
        $QueueRef = $Queue
        $QueueIndexRef = $QueueIndex
        $AddedCountRef = $AddedCount
        $FailedGroupFetchCountRef = $FailedGroupFetchCount
        $RunAddQueueBoxRef = $RunAddQueueBox
        $pendingDepsBoxRef = $pendingDepsBox

        Start-AppMetadataFetch -AppId $currentItem.Id -OnComplete {
            param($ok, $errMsg, $data)
            # A failed fetch still adds the app - same reasoning as the
            # single-row path above: a Graph hiccup fetching one app's
            # groups shouldn't block adding it at all, it just means
            # groups start blank for that one, same as before this fetch
            # existed. Not silent though - counted and reported in the
            # final summary MessageBox once the whole queue finishes.
            $newEntry = [pscustomobject]@{
                appId            = $currentItemRef.Id
                appName          = $currentItemRef.Name
                # Intune has no Winget ID field, but the install command
                # usually says - an app deployed through Winget-Install.ps1
                # carries -AppIDs "Some.App". Read back, an imported Winget
                # app is one the catalog KNOWS is a Winget app, which
                # decides whether it deploys from the shared package or is
                # treated as uncommon and needs its own .intunewin.
                wingetId         = if ($ok) { Get-WingetIdFromInstallCommand -InstallCommand ([string]$data.InstallCommandLine) } else { "" }
                # Both came back with the fetch and were being dropped on
                # the floor, which is why an imported app showed blank Type
                # and Version columns until a sync was run over it.
                intuneAppType    = if ($ok) { Get-FriendlyIntuneAppType -ODataType ([string]$data.OdataType) } else { "" }
                intuneAppVersion = if ($ok) { [string]$data.DisplayVersion } else { "" }
                requiredFor      = if ($ok) { @($data.RequiredGroupNames) } else { @() }
                availableFor     = if ($ok) { @($data.AvailableGroupNames) } else { @() }
                uninstallFor     = if ($ok) { @($data.UninstallGroupNames) } else { @() }
                # The fetch above already read the whole app - commands,
                # detection rule, requirements, dependencies. This used to
                # store $null and tell the user to fill it in by hand
                # afterwards, for information the tool had just been
                # handed. Still $null when the fetch FAILED, which is the
                # one case where there is genuinely nothing to store.
                metadata         = if ($ok) { ConvertTo-CatalogMetadataFromFetch -Fetched $data } else { $null }
            }
            [void]$appsRefRef3.Add($newEntry)
            # Collected as each app comes back rather than re-read from the
            # catalog at the end - the same fetch that filled the metadata
            # above is the only place these names appear.
            if ($ok) {
                foreach ($depName in @($data.Dependencies)) {
                    if ($depName) { $pendingDepsBoxRef.Names.Add([string]$depName) }
                }
            }
            $nextFailedCount = $FailedGroupFetchCountRef + $(if ($ok) { 0 } else { 1 })
            & $RunAddQueueBoxRef.Value -Queue $QueueRef -QueueIndex ($QueueIndexRef + 1) -AddedCount ($AddedCountRef + 1) -FailedGroupFetchCount $nextFailedCount
        }.GetNewClosure()
    }.GetNewClosure()

    $btnAddChecked.Add_Click({
        # Defensive, on top of the CurrentCellDirtyStateChanged commit
        # above - forces any still-pending checkbox edit to commit right
        # before reading values below, in case a checkbox was just
        # clicked and this button clicked again before that event had a
        # chance to run.
        $grid.EndEdit()
        $toAdd = New-Object System.Collections.Generic.List[object]
        foreach ($row in $grid.Rows) {
            $rowType = [string]$row.Cells["Type"].Value
            if ($rowType -ne "Not in catalog") { continue }
            $isChecked = [bool]$row.Cells["Selected"].Value
            if (-not $isChecked) { continue }
            $toAdd.Add([pscustomobject]@{ Name = [string]$row.Cells["IntuneName"].Value; Id = [string]$row.Cells["Id"].Value })
        }
        if ($toAdd.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Tick at least one `"Not in catalog`" row first.`n`nOnly those rows have a tick box - a renamed or deleted app is fixed one at a time with the button to the right.", "Nothing ticked", "OK", "Information") | Out-Null
            return
        }
        # Still a minimal entry per app - no full editor, no metadata (see
        # $RunAddQueueBox below for why metadata specifically stays out of
        # this bulk path) - but group assignments ARE fetched now, one app
        # at a time via the same queue-runner pattern Batch Deploy/Bulk
        # Delete already use, matching what the single-row "Add to
        # catalog..." button does. Winget ID and metadata are still fully
        # editable afterward from the main catalog.
        $btnAddChecked.Enabled = $false
        $btnAction.Enabled = $false
        $grid.Enabled = $false
        $cancelAddBox.Value = $false
        $btnCancelAdd.Enabled = $true
        $busyBox.Count++
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        & $RunAddQueueBox.Value -Queue $toAdd.ToArray() -QueueIndex 0 -AddedCount 0 -FailedGroupFetchCount 0
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    # Enter closes the window rather than adding anything - adding to the catalog is a deliberate click, not a keystroke.
    $dlg.AcceptButton = $btnClose

    # Blocks the window (X button / Alt+F4, not just Close) from closing
    # while any of this dialog's three background fetches is still in
    # flight - see $busyBox's own comment above for why a dedicated
    # counter, not an existing Enabled flag, is what this checks.
    $dlg.Add_FormClosing({
        param($s, $e)
        if ($busyBox.Count -gt 0) { $e.Cancel = $true }
    }.GetNewClosure())

    # Deferred to Add_Shown rather than called directly here - kicking off
    # the async refresh (PerformClick -> Start-.../timer) BEFORE ShowDialog()
    # has actually shown/realized the window let the WaitCursor assignment
    # get set on a not-yet-created window handle, which doesn't reliably
    # "stick" - the cursor could end up stuck spinning even after the async
    # work (and its Cursor = Default reset) had already completed.
    #
    # Always a live fetch, never the reused-cache branch this used to have -
    # $cacheRef ($Global:App.IntuneAppsCache) is shared across the whole app, so
    # it can already be non-empty here purely from something unrelated (e.g.
    # the app editor's own "Look up" button) run earlier in the session.
    # This dialog's entire job is telling you what's actually different
    # right now, so opening it must mean "check now", not "show whatever
    # happened to be cached from something else, however old that is".
    $dlg.Add_Shown({
        $btnRefresh.PerformClick()
    }.GetNewClosure())

    Set-Theme -Control $dlg
    if ($HostTabPage) {
        $btnClose.Visible = $false
        [void](Move-DialogToTabPage -Dialog $dlg -Page $HostTabPage)
        # The grid is the content, stopping above the button row under it.
        # $anyAddedBox is handed over rather than returned: a tab has no
        # moment where it returns to a caller, so the host refreshes the
        # catalog grid when the window closes - see Show-ChecksDialog.
        $HostTabPage.Tag = @{
            Fill          = $grid
            FillStopAbove = $btnAddChecked
            FillPushDown  = $true
            RunAll        = { $btnRefresh.PerformClick() }.GetNewClosure()
            # Same pair, same condition, as every other tab in that window:
            # a fetch in flight is both "still working" and "do not close".
            # $busyBox counts all three of this dialog's fetches, which is
            # stricter than $btnRefresh.Enabled alone - the bulk add queue
            # keeps calling Save-AppsToFile, and closing under it would
            # leave a timer ticking against controls on a disposed form.
            IsBusy        = { $busyBox.Count -gt 0 -or -not $btnRefresh.Enabled }.GetNewClosure()
            BlockClose    = { $busyBox.Count -gt 0 }.GetNewClosure()
            Changed       = $anyAddedBox
            Summary       = { if ($grid.Rows.Count -gt 0) { "$($grid.Rows.Count) difference(s)" } else { "" } }.GetNewClosure()
        }
        return
    }
    [void]$dlg.ShowDialog($Global:App.Form)
    return $anyAddedBox.Value
}
