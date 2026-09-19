function Global:Show-IntuneOnlyAppsDialog {
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

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Intune sync check"
    $dlg.ClientSize = New-Object System.Drawing.Size(760, 534)
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
    $dlg.Controls.Add($lblStatus)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh from Intune"
    $btnRefresh.Location = New-Object System.Drawing.Point(595,66)
    $btnRefresh.Size = New-Object System.Drawing.Size(150,26)
    $dlg.Controls.Add($btnRefresh)

    $grid = New-Object System.Windows.Forms.DataGridView
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

    # Bulk path, separate from $btnAction below - check any number of
    # "Not in catalog" rows and add them all at once with just name and
    # App ID, no full editor per app. $btnAction (further right) remains
    # for the single-row, full-editor add, plus the Renamed/Deleted
    # actions, which don't make sense to batch the same way.
    $btnAddChecked = New-Object System.Windows.Forms.Button
    $btnAddChecked.Text = "Add checked to catalog"
    $btnAddChecked.Location = New-Object System.Drawing.Point(15,474)
    $btnAddChecked.Size = New-Object System.Drawing.Size(175,32)
    $dlg.Controls.Add($btnAddChecked)
    $addCheckedTip = New-Object System.Windows.Forms.ToolTip
    $addCheckedTip.SetToolTip($btnAddChecked, "Bulk-adds every checked ""Not in catalog"" app using just its Intune name and App ID - no full editor per app. Renamed/deleted rows are not affected by this button.")

    # Same "Select all"/"Select none" convenience the other checkbox-driven
    # bulk-pick dialogs already have (Batch Deploy, Sync Metadata, Bulk
    # Delete) - this grid's checkbox column was the one bulk-selection UI
    # in the app missing them, forcing every row to be clicked
    # individually.
    $btnSelectAllChecked = New-Object System.Windows.Forms.Button
    $btnSelectAllChecked.Text = "Select all"
    $btnSelectAllChecked.Location = New-Object System.Drawing.Point(200,474)
    $btnSelectAllChecked.Size = New-Object System.Drawing.Size(90,32)
    $dlg.Controls.Add($btnSelectAllChecked)

    $btnSelectNoneChecked = New-Object System.Windows.Forms.Button
    $btnSelectNoneChecked.Text = "Select none"
    $btnSelectNoneChecked.Location = New-Object System.Drawing.Point(300,474)
    $btnSelectNoneChecked.Size = New-Object System.Drawing.Size(100,32)
    $dlg.Controls.Add($btnSelectNoneChecked)

    $btnAction = New-Object System.Windows.Forms.Button
    $btnAction.Text = "Add to catalog..."
    $btnAction.Location = New-Object System.Drawing.Point(515,474)
    $btnAction.Size = New-Object System.Drawing.Size(140,32)
    $btnAction.Enabled = $false
    $dlg.Controls.Add($btnAction)
    $actionTip = New-Object System.Windows.Forms.ToolTip
    $actionTip.SetToolTip($btnAction, "Acts on the single selected row - label changes with the row's kind: opens the full editor to add it, syncs the catalog's stored name to match Intune, or clears an App ID that no longer exists in Intune.")

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
        foreach ($r in ($renamed | Sort-Object IntuneName)) {
            # Checkbox column disabled (read-only) for these rows - bulk
            # "add checked" below only ever applies to "Not in catalog"
            # rows, so leaving this checkable here would silently do
            # nothing when checked, which is worse than not offering it
            # at all.
            $rIdx = $grid.Rows.Add($false, "Renamed in Intune", $r.IntuneName, $r.CatalogName, $r.Id)
            $grid.Rows[$rIdx].Cells["Selected"].ReadOnly = $true
        }
        foreach ($d in ($deletedFromIntune | Sort-Object appName)) {
            $dIdx = $grid.Rows.Add($false, "Deleted from Intune", "", $d.appName, $d.appId)
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
        $btnAction.Text = if ($type -eq "Renamed in Intune") { "Sync name from Intune" } elseif ($type -eq "Deleted from Intune") { "Clear stale App ID" } else { "Add to catalog..." }
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
                "Sync name from Intune", "YesNo", "Question")
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
                "Clear stale App ID", "YesNo", "Warning")
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
                    requiredFor  = if ($ok) { @($data.RequiredGroupNames) } else { @() }
                    availableFor = if ($ok) { @($data.AvailableGroupNames) } else { @() }
                    uninstallFor = if ($ok) { @($data.UninstallGroupNames) } else { @() }
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
    }.GetNewClosure())
    $btnSelectNoneChecked.Add_Click({
        $grid.EndEdit()
        foreach ($row in $grid.Rows) {
            if ([string]$row.Cells["Type"].Value -eq "Not in catalog") { $row.Cells["Selected"].Value = $false }
        }
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

        if ($QueueIndex -ge $Queue.Count) {
            $btnAddChecked.Enabled = $true
            $btnAction.Enabled = $true
            $grid.Enabled = $true
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
            $addedMsg = "Added $AddedCount app(s) to the catalog, with their current group assignments fetched from Intune. Set Winget ID and metadata for them later from the main catalog."
            if ($FailedGroupFetchCount -gt 0) {
                $addedMsg += "`n`n$FailedGroupFetchCount of them could not have their group assignments fetched (Graph error) - those were added with blank groups instead."
            }
            [System.Windows.Forms.MessageBox]::Show($addedMsg, "Added", "OK", "Information") | Out-Null
            & $populateGrid   # the just-added apps drop out of the "not in catalog" list
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
                wingetId         = ""
                intuneAppType    = ""
                intuneAppVersion = ""
                requiredFor      = if ($ok) { @($data.RequiredGroupNames) } else { @() }
                availableFor     = if ($ok) { @($data.AvailableGroupNames) } else { @() }
                uninstallFor     = if ($ok) { @($data.UninstallGroupNames) } else { @() }
                metadata         = $null
            }
            [void]$appsRefRef3.Add($newEntry)
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
            [System.Windows.Forms.MessageBox]::Show("Check at least one `"Not in catalog`" app first.", "Nothing checked", "OK", "Information") | Out-Null
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
    [void]$dlg.ShowDialog($Global:App.Form)
    return $anyAddedBox.Value
}
