function Global:Show-WingetSearchDialog {
    param([string]$InitialQuery = "")

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Search winget"
    $dlg.ClientSize = New-Object System.Drawing.Size(640, 470)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblQuery = New-Object System.Windows.Forms.Label
    $lblQuery.Text = "Search term"
    $lblQuery.Location = New-Object System.Drawing.Point(15,15)
    $lblQuery.AutoSize = $true
    $dlg.Controls.Add($lblQuery)

    $txtQuery = New-Object System.Windows.Forms.TextBox
    $txtQuery.Location = New-Object System.Drawing.Point(15,34)
    $txtQuery.Size = New-Object System.Drawing.Size(500,24)
    $txtQuery.Text = $InitialQuery
    $dlg.Controls.Add($txtQuery)

    $btnSearch = New-Object System.Windows.Forms.Button
    $btnSearch.Text = "Search"
    $btnSearch.Location = New-Object System.Drawing.Point(525,33)
    $btnSearch.Size = New-Object System.Drawing.Size(95,26)
    $dlg.Controls.Add($btnSearch)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,64)
    $lblStatus.Size = New-Object System.Drawing.Size(605,18)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,86)
    $grid.Size = New-Object System.Drawing.Size(605,330)
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

    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.Name = "Name"; $colName.HeaderText = "Name"; $colName.FillWeight = 34
    $grid.Columns.Add($colName) | Out-Null
    $colId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colId.Name = "Id"; $colId.HeaderText = "Winget ID"; $colId.FillWeight = 34
    $grid.Columns.Add($colId) | Out-Null
    $colVersion = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colVersion.Name = "Version"; $colVersion.HeaderText = "Version"; $colVersion.FillWeight = 16
    $grid.Columns.Add($colVersion) | Out-Null
    $colSource = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSource.Name = "Source"; $colSource.HeaderText = "Source"; $colSource.FillWeight = 16
    $grid.Columns.Add($colSource) | Out-Null
    $dlg.Controls.Add($grid)

    $btnSelect = New-Object System.Windows.Forms.Button
    $btnSelect.Text = "Use selected ID"
    $btnSelect.Location = New-Object System.Drawing.Point(390,426)
    $btnSelect.Size = New-Object System.Drawing.Size(140,32)
    $btnSelect.Enabled = $false
    $dlg.Controls.Add($btnSelect)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Close"
    $btnCancel.Location = New-Object System.Drawing.Point(535,426)
    $btnCancel.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnCancel)

    $resultBox = @{ SelectedId = $null }

    # Stored in a variable (not inlined into Add_Click) so both the Search
    # button and the query textbox's Enter key can trigger the exact same
    # logic, and so it can also run once automatically on open.
    $runSearch = {
        if (-not $btnSearch.Enabled) { return }   # a search is already running - ignore this trigger rather than overlap it
        $q = $txtQuery.Text.Trim()
        if (-not $q) { return }
        $grid.Rows.Clear()
        $btnSearch.Enabled = $false
        $btnSelect.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Searching winget for '$q'..."
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $gridRef = $grid
        $btnSearchRef = $btnSearch
        $lblStatusRef = $lblStatus
        $dlgRef = $dlg

        Start-WingetSearch -Query $q -OnComplete {
            param($ok, $data)
            try {
                if (-not $ok) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Search failed: $data"
                    return
                }
                $results = @($data)
                if ($results.Count -eq 0) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::DimGray
                    $lblStatusRef.Text = "No results."
                    return
                }
                foreach ($r in $results) {
                    [void]$gridRef.Rows.Add([string]$r.Name, [string]$r.Id, [string]$r.Version, [string]$r.Source)
                }
                $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                $lblStatusRef.Text = "$($results.Count) result(s)."
            }
            catch {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblStatusRef.Text = "Error showing results: $($_.Exception.Message)"
            }
            finally {
                # Guaranteed to run no matter what happened above - this is
                # what actually ends the "loading" state, so it must never be
                # skippable by an exception partway through populating rows.
                $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
                [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
                $btnSearchRef.Enabled = $true
            }
        }.GetNewClosure()
    }.GetNewClosure()

    $btnSearch.Add_Click($runSearch)

    $txtQuery.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $_.SuppressKeyPress = $true
            & $runSearch
        }
    }.GetNewClosure())

    $grid.Add_SelectionChanged({
        $btnSelect.Enabled = $grid.SelectedRows.Count -gt 0
    }.GetNewClosure())

    $grid.Add_CellDoubleClick({
        param($gridSender, $e)
        if ($e.RowIndex -ge 0) { $btnSelect.PerformClick() }
    }.GetNewClosure())

    $btnSelect.Add_Click({
        if ($grid.SelectedRows.Count -gt 0) {
            $resultBox.SelectedId = [string]$grid.SelectedRows[0].Cells["Id"].Value
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        }
    }.GetNewClosure())

    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnSearch

    if ($InitialQuery) { & $runSearch }

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
    return $resultBox.SelectedId
}
