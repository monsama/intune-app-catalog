function Global:Show-PlatformScriptRunStatusDialog {
    <#
      How a platform script actually went, per device: the state Intune
      reports, its result message, the error of a failure, and when it last
      ran. Read-only.

      Like the app install status view, these numbers come from Intune's
      reporting, so a run from minutes ago may not be in here yet.
    #>
    param([string]$ScriptId, [string]$ScriptName)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Run status - $ScriptName"
    $dlg.ClientSize = New-Object System.Drawing.Size(860, 540)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "What Intune reports about this script per device, in your local time. Read-only. A run from the last few minutes may not show up yet. Hover a row for the full text."
    $lblIntro.Location = New-Object System.Drawing.Point(15, 12)
    $lblIntro.Size = New-Object System.Drawing.Size(830, 36)
    $dlg.Controls.Add($lblIntro)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15, 54)
    $lblStatus.Size = New-Object System.Drawing.Size(520, 20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $lblStatus.Text = "Loading..."
    $dlg.Controls.Add($lblStatus)

    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = "Show:"
    $lblFilter.Location = New-Object System.Drawing.Point(545, 56)
    $lblFilter.Size = New-Object System.Drawing.Size(40, 20)
    $dlg.Controls.Add($lblFilter)

    $cmbFilter = New-Object System.Windows.Forms.ComboBox
    $cmbFilter.DropDownStyle = "DropDownList"
    $cmbFilter.Location = New-Object System.Drawing.Point(585, 52)
    $cmbFilter.Size = New-Object System.Drawing.Size(120, 24)
    [void]$cmbFilter.Items.Add("All")
    [void]$cmbFilter.Items.Add("Failed only")
    $cmbFilter.SelectedIndex = 0
    $dlg.Controls.Add($cmbFilter)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Location = New-Object System.Drawing.Point(715, 51)
    $btnRefresh.Size = New-Object System.Drawing.Size(130, 26)
    $dlg.Controls.Add($btnRefresh)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15, 84)
    $grid.Size = New-Object System.Drawing.Size(830, 380)
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.ReadOnly = $true
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    foreach ($col in @(
        @{ Name = "DeviceName"; Header = "Device"; Weight = 19 }
        @{ Name = "UserName";   Header = "User"; Weight = 21 }
        @{ Name = "State";      Header = "State"; Weight = 12 }
        @{ Name = "Result";     Header = "Result"; Weight = 20 }
        @{ Name = "ErrorText";  Header = "Error"; Weight = 16 }
        @{ Name = "LastRun";    Header = "Last run"; Weight = 12 }
    )) {
        $gridCol = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $gridCol.Name = $col.Name
        $gridCol.HeaderText = $col.Header
        $gridCol.FillWeight = $col.Weight
        $gridCol.ReadOnly = $true
        [void]$grid.Columns.Add($gridCol)
    }
    $dlg.Controls.Add($grid)

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = "Copy list"
    $btnCopy.Location = New-Object System.Drawing.Point(15, 478)
    $btnCopy.Size = New-Object System.Drawing.Size(120, 30)
    $dlg.Controls.Add($btnCopy)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(760, 478)
    $btnClose.Size = New-Object System.Drawing.Size(85, 30)
    $dlg.Controls.Add($btnClose)

    $rowsBox = @{ Value = @() }
    $busyBox = @{ Value = $false }

    $populateGrid = {
        $grid.Rows.Clear()
        $filter = [string]$cmbFilter.SelectedItem
        $shown = @($rowsBox.Value | Where-Object { $filter -ne 'Failed only' -or ([string]$_.State -like '*fail*') })
        foreach ($row in $shown) {
            $index = $grid.Rows.Add($row.DeviceName, $row.UserName, $row.State, $row.Result, $row.ErrorText, $row.LastRun)
            $gridRow = $grid.Rows[$index]
            if ([string]$row.State -like '*fail*') { $gridRow.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Firebrick }
            $full = @($row.DeviceName, $row.UserName, $row.State, $row.Result, $row.ErrorText, $row.LastRun)
            for ($c = 0; $c -lt $full.Count; $c++) { $gridRow.Cells[$c].ToolTipText = [string]$full[$c] }
        }
        $grid.ClearSelection()
        $grid.CurrentCell = $null
        $summary = Format-ScriptRunSummary $rowsBox.Value
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = if ($filter -eq 'All') { $summary } else { "$summary - showing $($shown.Count) of $(@($rowsBox.Value).Count)" }
    }.GetNewClosure()

    $runFetch = {
        if ($busyBox.Value) { return }
        $busyBox.Value = $true
        $btnRefresh.Enabled = $false
        $cmbFilter.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Loading from Intune..."
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh aliases for the nested -OnComplete closure - see the note at
        # the top of Show-CreateInIntuneDialog.
        $dlgRef = $dlg
        $lblStatusRef = $lblStatus
        $btnRefreshRef = $btnRefresh
        $cmbFilterRef = $cmbFilter
        $rowsBoxRef = $rowsBox
        $busyBoxRef = $busyBox
        $populateGridRef = $populateGrid

        Start-PlatformScriptRunStatusFetch -ScriptId $ScriptId -OnComplete {
            param($ok, $errMsg, $rows)
            try {
                if ($dlgRef.IsDisposed) { return }
                if (-not $ok) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Could not load: $errMsg"
                    return
                }
                $rowsBoxRef.Value = @($rows)
                & $populateGridRef
            }
            finally {
                $busyBoxRef.Value = $false
                if (-not $dlgRef.IsDisposed) {
                    $btnRefreshRef.Enabled = $true
                    $cmbFilterRef.Enabled = $true
                    $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
                    [System.Windows.Forms.Application]::DoEvents()
                    [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
                }
            }
        }.GetNewClosure()
    }.GetNewClosure()

    $btnRefresh.Add_Click({ & $runFetch }.GetNewClosure())
    $cmbFilter.Add_SelectedIndexChanged({ & $populateGrid }.GetNewClosure())
    $btnCopy.Add_Click({
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("Run status - $ScriptName")
        $lines.Add("Device`tUser`tState`tResult`tError`tLast run")
        foreach ($r in $grid.Rows) {
            if ($r.IsNewRow) { continue }
            $lines.Add((@(0..5 | ForEach-Object { [string]$r.Cells[$_].Value }) -join "`t"))
        }
        try {
            [System.Windows.Forms.Clipboard]::SetText(($lines -join "`r`n"))
            $lblStatus.ForeColor = [System.Drawing.Color]::SeaGreen
            $lblStatus.Text = "Copied $($grid.Rows.Count) row(s) to the clipboard."
        }
        catch {
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
            $lblStatus.Text = "Could not copy: $($_.Exception.Message)"
        }
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    # Enter dismisses this report, same as Esc - read-only, like the app install status it mirrors.
    $dlg.AcceptButton = $btnClose
    # Read-only, so closing mid-fetch just closes - same as the audit and
    # the app install status view.
    $dlg.Add_Shown({ & $runFetch }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
