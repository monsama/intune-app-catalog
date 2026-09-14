function Global:Show-SetDefaultsConfirmDialog {
    param([string[]]$Lines, $ParentForm)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Set default values"
    $dlg.ClientSize = New-Object System.Drawing.Size(620, 420)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(420, 260)
    $dlg.MaximizeBox = $true
    $dlg.MinimizeBox = $false

    $lblHeader = New-Object System.Windows.Forms.Label
    $rowWord = if (@($Lines).Count -eq 1) { "setting" } else { "settings" }
    $lblHeader.Text = "Reset the following $(@($Lines).Count) $rowWord to their computed defaults?"
    $lblHeader.Location = New-Object System.Drawing.Point(15,12)
    $lblHeader.Size = New-Object System.Drawing.Size(590,20)
    $dlg.Controls.Add($lblHeader)

    $lstChanges = New-Object System.Windows.Forms.ListBox
    $lstChanges.Location = New-Object System.Drawing.Point(15,40)
    $lstChanges.Size = New-Object System.Drawing.Size(590,320)
    $lstChanges.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $lstChanges.HorizontalScrollbar = $true
    $lstChanges.SelectionMode = "None"
    $lstChanges.IntegralHeight = $false
    foreach ($line in @($Lines)) { [void]$lstChanges.Items.Add($line) }
    $dlg.Controls.Add($lstChanges)

    $btnYes = New-Object System.Windows.Forms.Button
    $btnYes.Text = "Yes, reset these"
    $btnYes.Location = New-Object System.Drawing.Point(400,372)
    $btnYes.Size = New-Object System.Drawing.Size(120,30)
    $btnYes.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnYes)

    $btnNo = New-Object System.Windows.Forms.Button
    $btnNo.Text = "No"
    $btnNo.Location = New-Object System.Drawing.Point(525,372)
    $btnNo.Size = New-Object System.Drawing.Size(80,30)
    $btnNo.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnNo)

    $btnYes.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Yes; $dlg.Close() }.GetNewClosure())
    $btnNo.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::No; $dlg.Close() }.GetNewClosure())
    $dlg.AcceptButton = $btnNo
    $dlg.CancelButton = $btnNo

    Set-Theme -Control $dlg
    $result = $dlg.ShowDialog($ParentForm)
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}
