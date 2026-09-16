function Global:Show-CertificatePickerDialog {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    $certs = @($store.Certificates)
    $store.Close()

    if ($certs.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No certificates found in CurrentUser\My. Use 'Generate certificate...' to create one.", "No certificates", "OK", "Information") | Out-Null
        return $null
    }

    # A custom picker instead of the built-in X509Certificate2UI.SelectFromCollection
    # dialog - that's a native Windows dialog with a fixed layout Claude can't
    # resize or add columns to. This one shows subject, friendly name,
    # thumbprint, and expiry side by side, wide enough to actually read all
    # of it, which is the whole reason to build a custom version at all.
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Select Certificate"
    $dlg.ClientSize = New-Object System.Drawing.Size(760, 420)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(620, 300)

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Choose the certificate used for Microsoft Graph app-only authentication."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(730,20)
    $lblIntro.Anchor = "Top,Left,Right"
    $dlg.Controls.Add($lblIntro)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,38)
    $grid.Size = New-Object System.Drawing.Size(730,330)
    $grid.Anchor = "Top,Bottom,Left,Right"
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.AutoGenerateColumns = $false
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false

    $colSubject = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSubject.Name = "Subject"; $colSubject.HeaderText = "Subject"; $colSubject.FillWeight = 38
    $grid.Columns.Add($colSubject) | Out-Null
    $colFriendly = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colFriendly.Name = "FriendlyName"; $colFriendly.HeaderText = "Friendly name"; $colFriendly.FillWeight = 20
    $grid.Columns.Add($colFriendly) | Out-Null
    $colThumb = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colThumb.Name = "Thumbprint"; $colThumb.HeaderText = "Thumbprint"; $colThumb.FillWeight = 30
    $grid.Columns.Add($colThumb) | Out-Null
    $colExpiry = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colExpiry.Name = "Expiry"; $colExpiry.HeaderText = "Expires"; $colExpiry.FillWeight = 12
    $grid.Columns.Add($colExpiry) | Out-Null
    $dlg.Controls.Add($grid)

    foreach ($c in ($certs | Sort-Object Subject)) {
        $rowIdx = $grid.Rows.Add()
        $row = $grid.Rows[$rowIdx]
        $row.Cells["Subject"].Value = $c.Subject
        $row.Cells["FriendlyName"].Value = $c.FriendlyName
        $row.Cells["Thumbprint"].Value = $c.Thumbprint
        $row.Cells["Expiry"].Value = $c.NotAfter.ToString("yyyy-MM-dd")
        $row.Tag = $c.Thumbprint
        if ($c.NotAfter -lt (Get-Date)) {
            $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Firebrick
        }
    }
    if ($grid.Rows.Count -gt 0) { $grid.Rows[0].Selected = $true }

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "OK"
    $btnOK.Location = New-Object System.Drawing.Point(580,378)
    $btnOK.Size = New-Object System.Drawing.Size(80,28)
    $btnOK.Anchor = "Bottom,Right"
    $dlg.Controls.Add($btnOK)

    $btnCancelPick = New-Object System.Windows.Forms.Button
    $btnCancelPick.Text = "Cancel"
    $btnCancelPick.Location = New-Object System.Drawing.Point(665,378)
    $btnCancelPick.Size = New-Object System.Drawing.Size(80,28)
    $btnCancelPick.Anchor = "Bottom,Right"
    $dlg.Controls.Add($btnCancelPick)

    $resultBox = @{ Thumbprint = $null }

    $btnOK.Add_Click({
        if ($grid.SelectedRows.Count -gt 0) {
            $resultBox.Thumbprint = [string]$grid.SelectedRows[0].Tag
        }
        $dlg.Close()
    }.GetNewClosure())
    $btnCancelPick.Add_Click({ $dlg.Close() }.GetNewClosure())
    $grid.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -ge 0) {
            $resultBox.Thumbprint = [string]$grid.Rows[$e.RowIndex].Tag
            $dlg.Close()
        }
    }.GetNewClosure())

    $dlg.AcceptButton = $btnOK
    $dlg.CancelButton = $btnCancelPick
    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)

    return $resultBox.Thumbprint
}
