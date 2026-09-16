function Global:Show-AddFavoriteGroupToAppsDialog {
    param([object[]]$CandidateApps)

    if ($Global:App.FavoriteGroups.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No favorite groups set yet - use `"Favorite groups...`" on the toolbar to pick some first.", "No favorite groups", "OK", "Information") | Out-Null
        return $null
    }

    $appsRef = $Global:App.Apps
    $unsavedBoxRef = $Global:App.UnsavedChangesBox
    $linkedFilePathRef = $Global:App.LinkedFilePath

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Add favorite group to apps"
    $dlg.ClientSize = New-Object System.Drawing.Size(460, 700)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    # Same three-CheckedListBox layout as the App Editor's own Required/
    # Available/Uninstall pickers (see New-GroupBox in Show-AppEditor) -
    # tick as many favorite groups as needed per intent, not just one
    # group at a time. Deliberately favorites-only here, no "+ New
    # group..." - this dialog's whole point is a quick bulk pick from an
    # already-curated list, not managing group membership.
    function New-FavoriteGroupBox {
        param($Title, $Top)
        $gb = New-Object System.Windows.Forms.GroupBox
        $gb.Text = $Title
        $gb.Location = New-Object System.Drawing.Point(15,$Top)
        $gb.Size = New-Object System.Drawing.Size(430,100)

        $clb = New-Object System.Windows.Forms.CheckedListBox
        $clb.Location = New-Object System.Drawing.Point(10,20)
        $clb.Size = New-Object System.Drawing.Size(410,70)
        $clb.CheckOnClick = $true
        [void]$clb.Items.AddRange(@($Global:App.FavoriteGroups | Sort-Object))
        $gb.Controls.Add($clb)

        return @{ Box = $gb; List = $clb }
    }

    $reqGroup    = New-FavoriteGroupBox -Title "Required for"  -Top 12
    $availGroup  = New-FavoriteGroupBox -Title "Available for" -Top 118
    $uninstGroup = New-FavoriteGroupBox -Title "Uninstall for" -Top 224
    $dlg.Controls.Add($reqGroup.Box)
    $dlg.Controls.Add($availGroup.Box)
    $dlg.Controls.Add($uninstGroup.Box)

    $lblApps = New-Object System.Windows.Forms.Label
    $lblApps.Text = "Apps (unchecked ones below are left alone)"
    $lblApps.Location = New-Object System.Drawing.Point(15,334)
    $lblApps.AutoSize = $true
    $dlg.Controls.Add($lblApps)

    $clbApps = New-Object System.Windows.Forms.CheckedListBox
    $clbApps.Location = New-Object System.Drawing.Point(15,354)
    $clbApps.Size = New-Object System.Drawing.Size(430,260)
    $clbApps.CheckOnClick = $true
    $dlg.Controls.Add($clbApps)
    foreach ($candidateApp in ($CandidateApps | Sort-Object appName)) {
        [void]$clbApps.Items.Add($candidateApp.appName, $true)
    }

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select all"
    $btnSelectAll.Location = New-Object System.Drawing.Point(15,620)
    $btnSelectAll.Size = New-Object System.Drawing.Size(100,26)
    $dlg.Controls.Add($btnSelectAll)

    $btnSelectNone = New-Object System.Windows.Forms.Button
    $btnSelectNone.Text = "Select none"
    $btnSelectNone.Location = New-Object System.Drawing.Point(125,620)
    $btnSelectNone.Size = New-Object System.Drawing.Size(110,26)
    $dlg.Controls.Add($btnSelectNone)

    $btnSelectAll.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $true) }
    }.GetNewClosure())
    $btnSelectNone.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $false) }
    }.GetNewClosure())

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "Add to checked apps"
    $btnAdd.Location = New-Object System.Drawing.Point(255,658)
    $btnAdd.Size = New-Object System.Drawing.Size(190,30)
    $dlg.Controls.Add($btnAdd)
    $addTip = New-Object System.Windows.Forms.ToolTip
    $addTip.SetToolTip($btnAdd, "Adds the checked group(s) to the checked apps in the LOCAL CATALOG only. Push groups to Intune afterward to assign them there too.")

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(155,658)
    $btnCancel.Size = New-Object System.Drawing.Size(90,30)
    $dlg.Controls.Add($btnCancel)

    $resultBox = @{ Count = $null }

    $btnAdd.Add_Click({
        $pickedFields = @(
            @{ List = $reqGroup.List; FieldName = "requiredFor" }
            @{ List = $availGroup.List; FieldName = "availableFor" }
            @{ List = $uninstGroup.List; FieldName = "uninstallFor" }
        )
        $anyGroupChecked = (@($pickedFields | ForEach-Object { $_.List.CheckedItems.Count }) | Measure-Object -Sum).Sum -gt 0
        if (-not $anyGroupChecked) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one group above (Required/Available/Uninstall) first.", "No group selected", "OK", "Warning") | Out-Null
            return
        }
        $checkedNames = @($clbApps.CheckedItems | ForEach-Object { [string]$_ })
        if ($checkedNames.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one app first.", "Nothing checked", "OK", "Warning") | Out-Null
            return
        }

        $changedCount = 0
        foreach ($checkedName in $checkedNames) {
            $target = $appsRef | Where-Object { $_.appName -eq $checkedName } | Select-Object -First 1
            if (-not $target) { continue }
            $targetChanged = $false
            foreach ($pick in $pickedFields) {
                foreach ($groupName in @($pick.List.CheckedItems | ForEach-Object { [string]$_ })) {
                    if (@($target.($pick.FieldName)) -notcontains $groupName) {
                        $target.($pick.FieldName) = @(@($target.($pick.FieldName)) + $groupName)
                        $targetChanged = $true
                    }
                }
            }
            if ($targetChanged) { $changedCount++ }
        }
        if ($changedCount -gt 0) {
            $unsavedBoxRef.Value = $true
            [void](Save-AppsToFile -Path $linkedFilePathRef)
        }
        $resultBox.Count = $changedCount
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure())

    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnAdd
    Set-Theme -Control $dlg
    $dlgResult = $dlg.ShowDialog($Global:App.Form)
    if ($dlgResult -eq [System.Windows.Forms.DialogResult]::OK) { return $resultBox.Count }
    return $null
}
