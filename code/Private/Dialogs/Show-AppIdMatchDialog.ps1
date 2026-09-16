function Global:Show-AppIdMatchDialog {
    if ($Global:App.IntuneAppsCache.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No apps were returned from Intune. Check the Pipeline tab's log for details - likely a missing 'DeviceManagementApps.Read.All' application permission (with admin consent) on the app registration.", "Nothing to match", "OK", "Information") | Out-Null
        return
    }

    # Plain (non-$Script:) local aliases - see note in Start-IntuneAppLookup. Both are
    # reference types, so mutating them through these aliases from inside closures
    # below is visible everywhere else that reads the real $Script: names.
    $appsRef = $Global:App.Apps
    $unsavedBox = $Global:App.UnsavedChangesBox
    $cache = $Global:App.IntuneAppsCache
    $linkedFilePath = $Global:App.LinkedFilePath
    $pickerChoices = @($cache | ForEach-Object { "$($_.displayName)  [$($_.id)]" })

    # Scoped to apps with NO App ID yet - this dialog exists to bootstrap
    # the App ID for a catalog app that's never been linked to anything in
    # Intune, matched by NAME since there's nothing more reliable to go on
    # yet for those. An app that ALREADY has an App ID is deliberately left
    # out here, not re-matched by name too - "Intune sync check..."'s own
    # "Renamed in Intune" already covers that same "does this app's stored
    # ID still make sense?" question, the correct direction: by the App ID
    # already on file (the durable identity), checking whether Intune's
    # CURRENT name for that exact ID has drifted from the catalog's. Doing
    # it here too, by name, could disagree with that - a name collision (or
    # a coincidentally similar name) could suggest switching an already-
    # correct App ID to a wrong one, with no way to tell which of the two
    # tools' answers to trust. One tool, one direction, per case.
    $eligibleIndices = New-Object System.Collections.Generic.List[int]
    for ($ei = 0; $ei -lt $appsRef.Count; $ei++) {
        if (-not $appsRef[$ei].appId) { $eligibleIndices.Add($ei) }
    }
    if ($eligibleIndices.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Every catalog app already has an App ID - there's nothing to look up. If one looks wrong or stale, use `"Intune sync check...`" instead, which checks against the App ID already on file rather than matching by name.", "Nothing to do", "OK", "Information") | Out-Null
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Look up App IDs from Intune"
    $dlg.ClientSize = New-Object System.Drawing.Size(1300, 520)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(900, 360)

    # Regular weight, color-coded by outcome (below) - matches how every
    # other dialog's own status line (Intune sync check,
    # Check catalog groups against Entra ID, ...) is styled, rather than
    # this one dialog alone using bold.
    $lblHelp = New-Object System.Windows.Forms.Label
    $lblHelp.Text = "Matches catalog apps with no App ID to an Intune app by name, so you can link them - this only updates your LOCAL catalog, never Intune itself. Exact matches are pre-checked; use `"Choose...`" to pick a different one, then `"Apply checked rows to catalog`". Apps that already have an App ID aren't shown here - use `"Intune sync check...`" for those instead."
    $lblHelp.Dock = "Top"
    $lblHelp.Height = 62
    $lblHelp.ForeColor = [System.Drawing.Color]::DimGray
    $lblHelp.Padding = New-Object System.Windows.Forms.Padding(10,8,10,8)
    $dlg.Controls.Add($lblHelp)

    $lblSummary = New-Object System.Windows.Forms.Label
    $lblSummary.Dock = "Top"
    $lblSummary.Height = 24
    $lblSummary.Padding = New-Object System.Windows.Forms.Padding(10,0,10,0)
    $dlg.Controls.Add($lblSummary)

    $matchGrid = New-Object System.Windows.Forms.DataGridView
    $matchGrid.Dock = "Fill"
    $matchGrid.AllowUserToAddRows = $false
    $matchGrid.AllowUserToDeleteRows = $false
    $matchGrid.RowHeadersVisible = $false
    $matchGrid.AutoGenerateColumns = $false
    $matchGrid.AutoSizeColumnsMode = "Fill"
    $matchGrid.EditMode = "EditOnEnter"
    # Commits a checkbox cell's edit the instant it's clicked, rather than
    # leaving it pending until the cell loses focus - same fix, same
    # reasoning, as the identical DataGridView checkbox column in "Intune
    # sync check": a checkbox visually toggles immediately on click, but
    # its actual .Value doesn't update until the edit is explicitly
    # committed. The existing $matchGrid.EndEdit() below (right before
    # "Apply" reads the checked rows) already defended against this for
    # that one specific moment - this makes the checkbox itself behave
    # consistently the instant it's clicked, matching the other dialog
    # exactly, not just patched around for this one button.
    $matchGrid.Add_CurrentCellDirtyStateChanged({
        if ($matchGrid.IsCurrentCellDirty) {
            $matchGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    }.GetNewClosure())

    $colApply = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colApply.Name = "Apply"; $colApply.HeaderText = "Apply"; $colApply.FillWeight = 7
    $matchGrid.Columns.Add($colApply) | Out-Null

    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.Name = "AppName"; $colName.HeaderText = "Catalog app"; $colName.ReadOnly = $true; $colName.FillWeight = 19
    $matchGrid.Columns.Add($colName) | Out-Null

    $colCurrentId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCurrentId.Name = "CurrentId"; $colCurrentId.HeaderText = "Current App ID"; $colCurrentId.ReadOnly = $true; $colCurrentId.FillWeight = 17
    $matchGrid.Columns.Add($colCurrentId) | Out-Null

    $colMatch = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colMatch.Name = "Match"; $colMatch.HeaderText = "Matched name in Intune"; $colMatch.ReadOnly = $true; $colMatch.FillWeight = 21
    $matchGrid.Columns.Add($colMatch) | Out-Null

    $colMatchedId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colMatchedId.Name = "MatchedId"; $colMatchedId.HeaderText = "Matched App ID"; $colMatchedId.ReadOnly = $true; $colMatchedId.FillWeight = 17
    $matchGrid.Columns.Add($colMatchedId) | Out-Null

    $colChoose = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $colChoose.Name = "Choose"; $colChoose.HeaderText = ""; $colChoose.Text = "Choose..."; $colChoose.UseColumnTextForButtonValue = $true
    $colChoose.FillWeight = 12
    $matchGrid.Columns.Add($colChoose) | Out-Null

    $colIndex = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colIndex.Name = "CatalogIndex"; $colIndex.Visible = $false
    $matchGrid.Columns.Add($colIndex) | Out-Null

    # Every eligible app here has NO App ID yet (see the eligibility filter
    # above), so any exact match is inherently a real change - going from
    # blank to a real ID - not just a possible one, unlike when this used
    # to also consider apps that already had an ID of their own.
    $changeCount = 0
    foreach ($i in $eligibleIndices) {
        $app = $appsRef[$i]
        $candidates = Find-IntuneMatches -Name $app.appName
        $normAppName = ($app.appName.Trim() -replace '\s+', ' ')
        $isExact = $candidates.Count -gt 0 -and (($candidates[0].displayName.Trim() -replace '\s+', ' ') -eq $normAppName)
        if ($isExact) { $changeCount++ }

        $rowIdx = $matchGrid.Rows.Add()
        $row = $matchGrid.Rows[$rowIdx]
        $row.Cells["Apply"].Value = $isExact
        $row.Cells["AppName"].Value = $app.appName
        $row.Cells["CurrentId"].Value = "(none)"
        if ($isExact) {
            $row.Cells["Match"].Value = $candidates[0].displayName
            $row.Cells["MatchedId"].Value = $candidates[0].id
        }
        else {
            $row.Cells["Match"].Value = "(no match)"
            $row.Cells["MatchedId"].Value = ""
        }
        $row.Cells["CatalogIndex"].Value = $i
    }

    if ($changeCount -eq 0) {
        $lblSummary.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblSummary.Text = "$($eligibleIndices.Count) app(s) have no App ID yet, but none matched an Intune app by name - use `"Choose...`" to pick one manually if it's just a naming difference."
    }
    else {
        $lblSummary.ForeColor = [System.Drawing.Color]::SeaGreen
        $lblSummary.Text = "$changeCount of $($eligibleIndices.Count) app(s) with no App ID matched by name and are pre-checked below - applying sets their App ID in the local catalog only."
    }

    $dlg.Controls.Add($matchGrid)
    $matchGrid.BringToFront()

    $btnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnPanel.Dock = "Bottom"
    $btnPanel.Height = 45
    $btnPanel.FlowDirection = "RightToLeft"
    $btnPanel.Padding = New-Object System.Windows.Forms.Padding(10)

    $btnCancelMatch = New-Object System.Windows.Forms.Button
    $btnCancelMatch.Text = "Close"
    $btnCancelMatch.AutoSize = $true

    $btnApplyMatch = New-Object System.Windows.Forms.Button
    $btnApplyMatch.Text = "Apply checked rows to catalog"
    $btnApplyMatch.AutoSize = $true

    $btnPanel.Controls.Add($btnCancelMatch)
    $btnPanel.Controls.Add($btnApplyMatch)
    $dlg.Controls.Add($btnPanel)

    $matchGrid.Add_CellClick({
        param($gridSender, $e)
        if ($e.RowIndex -lt 0) { return }
        if ($matchGrid.Columns[$e.ColumnIndex].Name -ne "Choose") { return }

        $row = $matchGrid.Rows[$e.RowIndex]
        $appName = [string]$row.Cells["AppName"].Value
        $pick = Show-SimpleListPicker -Title "Choose a match" -Prompt "Pick the Intune app that matches '$appName':" -Items $pickerChoices
        if ($pick -and $pick -match '^(.*?)\s+\[([0-9a-fA-F-]{36})\]\s*$') {
            $row.Cells["Match"].Value = $Matches[1]
            $row.Cells["MatchedId"].Value = $Matches[2]
            $row.Cells["Apply"].Value = $true
        }
    }.GetNewClosure())

    $btnApplyMatch.Add_Click({
        $matchGrid.EndEdit()
        $applied = 0
        foreach ($row in $matchGrid.Rows) {
            $apply = [bool]$row.Cells["Apply"].Value
            $matchedId = [string]$row.Cells["MatchedId"].Value
            if (-not $apply -or [string]::IsNullOrEmpty($matchedId)) { continue }
            $idx = [int]$row.Cells["CatalogIndex"].Value
            $appsRef[$idx].appId = $matchedId
            $applied++
        }
        if ($applied -gt 0) {
            $unsavedBox.Value = $true
            # Direct-save, not just staged in memory - same reasoning as
            # every other single, atomic action made direct-save this
            # session: applying matched App IDs is a complete action in
            # itself, with no batching benefit to be had from deferring it.
            [void](Save-AppsToFile -Path $linkedFilePath)
            Update-Grid
            Write-Log "Applied $applied App ID(s) from Intune lookup.`r`n" ([System.Drawing.Color]::LightGreen)
        }
        $doneMsg = if ($applied -gt 0) { "$applied App ID(s) applied and saved to the local catalog." } else { "$applied App ID(s) applied." }
        [System.Windows.Forms.MessageBox]::Show($doneMsg, "Done", "OK", "Information") | Out-Null
    }.GetNewClosure())

    $btnCancelMatch.Add_Click({ $dlg.Close() }.GetNewClosure())

    $dlg.CancelButton = $btnCancelMatch
    $dlg.AcceptButton = $btnApplyMatch
    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
