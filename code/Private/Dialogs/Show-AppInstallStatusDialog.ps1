function Global:Show-AppInstallStatusDialog {
    <#
      Who actually has an app: one row per device, with its user, the
      install state and the error code of a failure. Read-only - nothing
      here changes Intune or the catalog.

      The numbers come from Intune's reporting pipeline (the same one
      behind the portal's "Device install status" view), so they lag
      behind reality by a while - said on the dialog itself, since
      "installed 10 minutes ago but still Pending here" is otherwise a
      confusing thing to see.
    #>
    param([string]$AppId, [string]$AppName)

    if (-not $AppId) {
        [System.Windows.Forms.MessageBox]::Show("'$AppName' has no App ID yet, so Intune has nothing to report on it.`n`nDeploy it first, or use 'Look up App IDs...'.", "No App ID", "OK", "Information") | Out-Null
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Install status - $AppName"
    $dlg.ClientSize = New-Object System.Drawing.Size(860, 560)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "What Intune reports about this app per device, in your local time. Read-only. These numbers come from Intune's reporting pipeline, the same one the portal's own 'Device install status' view uses, so a very recent install or failure can take a while to show up here. Hover a row for the full text."
    $lblIntro.Location = New-Object System.Drawing.Point(15, 12)
    $lblIntro.Size = New-Object System.Drawing.Size(830, 36)
    $dlg.Controls.Add($lblIntro)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15, 56)
    $lblStatus.Size = New-Object System.Drawing.Size(520, 20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $lblStatus.Text = "Loading..."
    $dlg.Controls.Add($lblStatus)

    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = "Show:"
    $lblFilter.Location = New-Object System.Drawing.Point(545, 58)
    $lblFilter.Size = New-Object System.Drawing.Size(40, 20)
    $dlg.Controls.Add($lblFilter)

    $cmbFilter = New-Object System.Windows.Forms.ComboBox
    $cmbFilter.DropDownStyle = "DropDownList"
    $cmbFilter.Location = New-Object System.Drawing.Point(585, 54)
    $cmbFilter.Size = New-Object System.Drawing.Size(120, 24)
    [void]$cmbFilter.Items.Add("All")
    [void]$cmbFilter.Items.Add("Failed only")
    $cmbFilter.SelectedIndex = 0
    $dlg.Controls.Add($cmbFilter)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Location = New-Object System.Drawing.Point(715, 53)
    $btnRefresh.Size = New-Object System.Drawing.Size(130, 26)
    $dlg.Controls.Add($btnRefresh)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15, 86)
    $grid.Size = New-Object System.Drawing.Size(830, 400)
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $true
    $grid.ReadOnly = $true
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    foreach ($col in @(
        @{ Name = "DeviceName"; Header = "Device"; Weight = 17 }
        @{ Name = "UserName";   Header = "User";   Weight = 21 }
        @{ Name = "State";      Header = "State";  Weight = 12 }
        @{ Name = "Detail";     Header = "Detail"; Weight = 23 }
        @{ Name = "ErrorCode";  Header = "Error";  Weight = 11 }
        @{ Name = "Version";    Header = "Version"; Weight = 8 }
        @{ Name = "LastSeen";   Header = "Last reported"; Weight = 13 }
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
    $btnCopy.Location = New-Object System.Drawing.Point(15, 498)
    $btnCopy.Size = New-Object System.Drawing.Size(120, 30)
    $dlg.Controls.Add($btnCopy)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(760, 498)
    $btnClose.Size = New-Object System.Drawing.Size(85, 30)
    $dlg.Controls.Add($btnClose)

    # Everything fetched, before the filter is applied - so switching the
    # filter doesn't need another round trip to Graph.
    $rowsBox = @{ Value = @() }
    $busyBox = @{ Value = $false }

    $populateGrid = {
        $grid.Rows.Clear()
        $filter = [string]$cmbFilter.SelectedItem
        $shown = @($rowsBox.Value | Where-Object { Test-InstallStatusRowMatchesFilter -Row $_ -Filter $filter })
        foreach ($row in $shown) {
            # the hex form alone in the cell, the decimal too in its tooltip -
            # a long error string otherwise pushes the Detail column out
            $errorShort = ([string]$row.ErrorCode -split ' ')[0]
            $index = $grid.Rows.Add($row.DeviceName, $row.UserName, $row.State, $row.Detail, $errorShort, $row.Version, $row.LastSeen)
            $gridRow = $grid.Rows[$index]
            if ([string]$row.State -like '*fail*') {
                $gridRow.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Firebrick
            }
            # every cell keeps its full text on hover - Detail especially is
            # a whole sentence from Intune, far wider than any column here
            $full = @($row.DeviceName, $row.UserName, $row.State, $row.Detail, $row.ErrorCode, $row.Version, $row.LastSeen)
            for ($c = 0; $c -lt $full.Count; $c++) { $gridRow.Cells[$c].ToolTipText = [string]$full[$c] }
        }
        # nothing preselected when the list appears
        $grid.ClearSelection()
        $grid.CurrentCell = $null
        $summary = Format-InstallStatusSummary $rowsBox.Value
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = if ($filter -eq 'All') { $summary } else { "$summary - showing $($shown.Count) of $($rowsBox.Value.Count)" }
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
        # the top of Show-CreateInIntuneDialog for why this matters.
        $dlgRef = $dlg
        $gridRef = $grid
        $lblStatusRef = $lblStatus
        $btnRefreshRef = $btnRefresh
        $cmbFilterRef = $cmbFilter
        $rowsBoxRef = $rowsBox
        $busyBoxRef = $busyBox
        $populateGridRef = $populateGrid

        Start-AppInstallStatusFetch -AppId $AppId -OnComplete {
            param($ok, $errMsg, $data)
            try {
                if ($dlgRef.IsDisposed) { return }
                if (-not $ok) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Could not load: $errMsg"
                    $gridRef.Rows.Clear()
                    return
                }
                $rowsBoxRef.Value = @($data.Rows)
                & $populateGridRef
                if ($data.Truncated) {
                    $lblStatusRef.Text = "$($lblStatusRef.Text) - only the first $($rowsBoxRef.Value.Count) rows are shown"
                }
                if ($data.Source -eq 'deviceStatuses') {
                    Write-Log "[INFO] Install status came from the older deviceStatuses endpoint - the report endpoint wasn't available in this tenant.`r`n" ([System.Drawing.Color]::Gainsboro)
                }
            }
            catch {
                if (-not $dlgRef.IsDisposed) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Could not show the result: $($_.Exception.Message)"
                }
            }
            finally {
                $busyBoxRef.Value = $false
                if (-not $dlgRef.IsDisposed) {
                    $btnRefreshRef.Enabled = $true
                    $cmbFilterRef.Enabled = $true
                    $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
                    # See the same pattern's note in Show-WingetSearchDialog -
                    # forces an immediate cursor repaint.
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
        $lines.Add("Install status - $AppName (App ID $AppId)")
        $lines.Add("Device`tUser`tState`tDetail`tError`tVersion`tLast reported")
        foreach ($r in $grid.Rows) {
            if ($r.IsNewRow) { continue }
            $lines.Add((@(0..6 | ForEach-Object { [string]$r.Cells[$_].Value }) -join "`t"))
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
    # No question on close even mid-fetch: this only reads, and the fetch's
    # own callback checks IsDisposed before touching anything here - same
    # reasoning as the Intune Audit dialog.

    # Deferred to Add_Shown - same reasoning as every other "start the work
    # once the window is actually up" case in this app.
    $dlg.Add_Shown({ & $runFetch }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
