function Global:Show-GroupOnlyPicker {
    # Plain local alias - see note in Start-IntuneAppLookup.
    $cache = $Global:App.EntraDirectoryCache

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Find a group"
    $dlg.ClientSize = New-Object System.Drawing.Size(480, 420)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Search, or type a new name directly if it doesn't exist yet:"
    $lblSearch.Location = New-Object System.Drawing.Point(12,12)
    $lblSearch.AutoSize = $true
    $dlg.Controls.Add($lblSearch)

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(12,32)
    $txtSearch.Size = New-Object System.Drawing.Size(368,24)
    $dlg.Controls.Add($txtSearch)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Location = New-Object System.Drawing.Point(388,31)
    $btnRefresh.Size = New-Object System.Drawing.Size(80,26)
    $dlg.Controls.Add($btnRefresh)
    $refreshTip = New-Object System.Windows.Forms.ToolTip
    $refreshTip.SetToolTip($btnRefresh, "Re-fetches this list from Entra ID.")

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location = New-Object System.Drawing.Point(12,64)
    $lst.Size = New-Object System.Drawing.Size(456,260)
    $dlg.Controls.Add($lst)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(12,328)
    $lblStatus.Size = New-Object System.Drawing.Size(456,36)
    $dlg.Controls.Add($lblStatus)

    $btnSelect = New-Object System.Windows.Forms.Button
    $btnSelect.Text = "Select"
    $btnSelect.Location = New-Object System.Drawing.Point(297,370)
    $btnSelect.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnSelect)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(385,370)
    $btnCancel.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnCancel)

    $UpdateStatus = {
        $groupCount = @($cache | Where-Object { $_.type -eq "Group" }).Count
        if ($cache.Count -eq 0) {
            $lblStatus.Text = "Nothing loaded yet - click Refresh to browse Entra ID, or just type a name and Select."
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        } else {
            $lblStatus.Text = "Loaded $groupCount group(s) from Entra ID."
            $lblStatus.ForeColor = [System.Drawing.Color]::SeaGreen
        }
    }.GetNewClosure()

    $RefreshList = {
        $term = $txtSearch.Text.Trim()
        $lst.Items.Clear()
        $filtered = @($cache | Where-Object { $_.type -eq "Group" })
        if ($term) {
            $filtered = @($filtered | Where-Object { $_.displayName -like "*$term*" })
        }
        $shown = $filtered | Sort-Object displayName | Select-Object -First 200
        foreach ($m in $shown) {
            [void]$lst.Items.Add($m.displayName)
        }
    }.GetNewClosure()

    & $UpdateStatus
    & $RefreshList

    $txtSearch.Add_TextChanged({ & $RefreshList }.GetNewClosure())
    $lst.Add_DoubleClick({ $btnSelect.PerformClick() }.GetNewClosure())

    $btnRefresh.Add_Click({
        $btnRefresh.Enabled = $false
        $lblStatus.Text = "Connecting to Entra ID..."
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        # Start-EntraDirectoryLookup sets $Global:App.Form.Cursor itself,
        # but that's the MAIN window, hidden behind this modal picker the
        # whole time this runs - see the same fix and note in
        # Show-EntraMemberPicker's own Refresh handler.
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh local aliases for everything the nested -OnComplete closure below
        # touches - see the note in Show-EntraMemberPicker's own Refresh handler.
        $dlgRef          = $dlg
        $btnRefreshRef   = $btnRefresh
        $lblStatusRef    = $lblStatus
        $updateStatusRef = $UpdateStatus
        $refreshListRef  = $RefreshList

        Start-EntraDirectoryLookup -OnComplete {
            param($ok, $msg)
            $btnRefreshRef.Enabled = $true
            $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Application]::DoEvents()
            [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
            if ($ok) {
                & $updateStatusRef
                & $refreshListRef
            } else {
                $lblStatusRef.Text = "Failed: $msg"
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $resultBox = @{ Value = $null }

    $btnSelect.Add_Click({
        if ($lst.SelectedItem) {
            $resultBox.Value = [string]$lst.SelectedItem
        }
        elseif ($txtSearch.Text.Trim()) {
            $resultBox.Value = $txtSearch.Text.Trim()
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Select a group from the list, or type a name.", "Nothing selected", "OK", "Information") | Out-Null
            return
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure())

    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnSelect
    Set-Theme -Control $dlg
    $result = $dlg.ShowDialog($Global:App.Form)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $resultBox.Value }
    return $null
}
