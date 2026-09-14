function Global:Show-EntraMemberPicker {
    # Plain local alias - see note in Start-IntuneAppLookup. $UpdateStatus and
    # $RefreshList below are closures; even a single level of GetNewClosure()
    # does not reliably see $Script:-qualified variables, only plain ones.
    $cache = $Global:App.EntraDirectoryCache

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Add group or user"
    $dlg.ClientSize = New-Object System.Drawing.Size(480, 420)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Search, or type a name directly if it's not listed:"
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

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "Add"
    $btnAdd.Location = New-Object System.Drawing.Point(300,370)
    $btnAdd.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnAdd)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(388,370)
    $btnCancel.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnCancel)

    $UpdateStatus = {
        if ($cache.Count -eq 0) {
            $lblStatus.Text = "Nothing loaded yet - click Refresh to browse Entra ID, or just type a name and Add."
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        } else {
            $groupCount = @($cache | Where-Object { $_.type -eq "Group" }).Count
            $userCount  = @($cache | Where-Object { $_.type -eq "User" }).Count
            $lblStatus.Text = "Loaded $groupCount group(s), $userCount user(s) from Entra ID."
            $lblStatus.ForeColor = [System.Drawing.Color]::SeaGreen
        }
    }.GetNewClosure()

    $RefreshList = {
        $term = $txtSearch.Text.Trim()
        $lst.Items.Clear()
        $filtered = $cache
        if ($term) {
            $filtered = @($filtered | Where-Object { $_.displayName -like "*$term*" })
        }
        $shown = $filtered | Sort-Object type, displayName | Select-Object -First 200
        foreach ($m in $shown) {
            $label = if ($m.type -eq "User" -and $m.upn) { "[User] $($m.displayName) ($($m.upn))" } else { "[$($m.type)] $($m.displayName)" }
            [void]$lst.Items.Add($label)
        }
    }.GetNewClosure()

    & $UpdateStatus
    & $RefreshList

    $txtSearch.Add_TextChanged({ & $RefreshList }.GetNewClosure())
    $lst.Add_DoubleClick({ $btnAdd.PerformClick() }.GetNewClosure())

    $btnRefresh.Add_Click({
        $btnRefresh.Enabled = $false
        $lblStatus.Text = "Connecting to Entra ID..."
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray

        # Fresh local aliases for everything the nested -OnComplete closure below
        # touches - a closure nested inside this already-closured Add_Click does
        # not reliably re-capture variables THIS handler itself only inherited
        # from the outer Show-EntraMemberPicker scope (see the note in
        # Show-CertificateSetupDialog's Test Connection handler).
        $btnRefreshRef   = $btnRefresh
        $lblStatusRef    = $lblStatus
        $updateStatusRef = $UpdateStatus
        $refreshListRef  = $RefreshList

        Start-EntraDirectoryLookup -OnComplete {
            param($ok, $msg)
            $btnRefreshRef.Enabled = $true
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

    $btnAdd.Add_Click({
        if ($lst.SelectedItem) {
            $text = [string]$lst.SelectedItem
            if ($text -match '^\[(?:Group|User)\]\s+(.+?)(?:\s+\([^)]*\))?$') {
                $resultBox.Value = $Matches[1]
            } else {
                $resultBox.Value = $text
            }
        }
        elseif ($txtSearch.Text.Trim()) {
            $resultBox.Value = $txtSearch.Text.Trim()
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Select an item from the list, or type a name.", "Nothing to add", "OK", "Information") | Out-Null
            return
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure())

    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnAdd
    Set-Theme -Control $dlg
    $result = $dlg.ShowDialog($Global:App.Form)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $resultBox.Value }
    return $null
}
