function Global:Show-SetDefaultsConfirmDialog {
    param([string[]]$Lines, $ParentForm)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Set default values"
    # Wider than it was: these lines are "Label: current -> default", and
    # at 620 almost every one of them ran past the right edge.
    $dlg.ClientSize = New-Object System.Drawing.Size(760, 420)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(460, 260)
    $dlg.MaximizeBox = $true
    $dlg.MinimizeBox = $false

    $lblHeader = New-Object System.Windows.Forms.Label
    $rowWord = if (@($Lines).Count -eq 1) { "setting" } else { "settings" }
    $lblHeader.Text = "Reset the following $(@($Lines).Count) $rowWord to their computed defaults?"
    $lblHeader.Location = New-Object System.Drawing.Point(15,12)
    $lblHeader.Size = New-Object System.Drawing.Size(730,20)
    $lblHeader.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($lblHeader)

    # A wrapping, read-only text box rather than the ListBox this used to
    # be. A ListBox clips an item that is wider than it is and has no
    # tooltip to make up for it - and the HorizontalScrollbar = $true it
    # was carrying did nothing, because a ListBox only scrolls
    # horizontally as far as HorizontalExtent, which defaults to 0 and was
    # never set. So every one of these lines ended at the right edge with
    # no way, by scrolling or hovering, to read the rest of it.
    #
    # Wrapping suits them better than scrolling anyway: they are sentences
    # ("Install command: this -> that"), not columns. A blank line between
    # them keeps a wrapped continuation from reading like the next change,
    # and being a text box means the whole list can be selected and copied.
    $lstChanges = New-Object System.Windows.Forms.TextBox
    $lstChanges.Location = New-Object System.Drawing.Point(15,40)
    $lstChanges.Size = New-Object System.Drawing.Size(730,320)
    $lstChanges.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $lstChanges.Multiline = $true
    $lstChanges.WordWrap = $true
    $lstChanges.ReadOnly = $true
    $lstChanges.ScrollBars = "Vertical"
    $lstChanges.Text = (@($Lines) -join "`r`n`r`n")
    $dlg.Controls.Add($lstChanges)

    $btnYes = New-Object System.Windows.Forms.Button
    $btnYes.Text = "Yes, reset these"
    $btnYes.Location = New-Object System.Drawing.Point(540,372)
    $btnYes.Size = New-Object System.Drawing.Size(120,30)
    $btnYes.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnYes)

    $btnNo = New-Object System.Windows.Forms.Button
    $btnNo.Text = "No"
    $btnNo.Location = New-Object System.Drawing.Point(665,372)
    $btnNo.Size = New-Object System.Drawing.Size(80,30)
    $btnNo.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnNo)

    $btnYes.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Yes; $dlg.Close() }.GetNewClosure())
    $btnNo.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::No; $dlg.Close() }.GetNewClosure())
    $dlg.AcceptButton = $btnNo
    $dlg.CancelButton = $btnNo
    # Otherwise the read-only list takes the initial focus and sits there
    # blinking a caret, which reads as an editable field. No is also the
    # answer this window defaults to, so focusing it is the honest place
    # to start.
    $dlg.Add_Shown({ $btnNo.Focus() }.GetNewClosure())

    Set-Theme -Control $dlg
    $result = $dlg.ShowDialog($ParentForm)
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}
