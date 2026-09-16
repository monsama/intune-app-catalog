function Global:Show-RemoveGroupFromAppsDialog {
    param([object[]]$CandidateApps)

    $reqNames    = @($CandidateApps | ForEach-Object { $_.requiredFor }  | Select-Object -Unique | Sort-Object)
    $availNames  = @($CandidateApps | ForEach-Object { $_.availableFor } | Select-Object -Unique | Sort-Object)
    $uninstNames = @($CandidateApps | ForEach-Object { $_.uninstallFor } | Select-Object -Unique | Sort-Object)
    if ($reqNames.Count -eq 0 -and $availNames.Count -eq 0 -and $uninstNames.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("None of these apps have any group set - nothing to remove.", "No groups", "OK", "Information") | Out-Null
        return $null
    }

    $appsRef = $Global:App.Apps
    $unsavedBoxRef = $Global:App.UnsavedChangesBox
    $linkedFilePathRef = $Global:App.LinkedFilePath

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Remove group from apps"
    $dlg.ClientSize = New-Object System.Drawing.Size(460, 700)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    # Same layout as Show-AddFavoriteGroupToAppsDialog's New-FavoriteGroupBox
    # (three GroupBoxes at the same Top offsets), just sourced from each
    # field's actually-referenced group names instead of the favorites
    # list. Starts every item UNCHECKED, unlike the Add dialog's app list -
    # removal is destructive (it takes effect on Intune the moment Batch
    # assign groups' Apply step runs afterward), so which group(s) get
    # removed should always be a deliberate pick, never a default-
    # everything list someone has to remember to uncheck.
    function New-GroupRemovalBox {
        param($Title, $Top, [string[]]$Names)
        $gb = New-Object System.Windows.Forms.GroupBox
        $gb.Text = $Title
        $gb.Location = New-Object System.Drawing.Point(15,$Top)
        $gb.Size = New-Object System.Drawing.Size(430,100)

        $clb = New-Object System.Windows.Forms.CheckedListBox
        $clb.Location = New-Object System.Drawing.Point(10,20)
        $clb.Size = New-Object System.Drawing.Size(410,70)
        $clb.CheckOnClick = $true
        foreach ($n in $Names) { [void]$clb.Items.Add($n, $false) }
        $gb.Controls.Add($clb)

        return @{ Box = $gb; List = $clb }
    }

    $reqGroup    = New-GroupRemovalBox -Title "Required for"  -Top 12  -Names $reqNames
    $availGroup  = New-GroupRemovalBox -Title "Available for" -Top 118 -Names $availNames
    $uninstGroup = New-GroupRemovalBox -Title "Uninstall for" -Top 224 -Names $uninstNames
    $dlg.Controls.Add($reqGroup.Box)
    $dlg.Controls.Add($availGroup.Box)
    $dlg.Controls.Add($uninstGroup.Box)

    $lblApps = New-Object System.Windows.Forms.Label
    $lblApps.Text = "From these apps (unchecked ones below are left alone)"
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

    # Both act on the APPS list only - the group boxes keep their own
    # deliberate picks regardless, same reasoning as starting them
    # unchecked above.
    $btnSelectAll.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $true) }
    }.GetNewClosure())
    $btnSelectNone.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $false) }
    }.GetNewClosure())

    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = "Remove from checked apps"
    $btnRemove.Location = New-Object System.Drawing.Point(240,658)
    $btnRemove.Size = New-Object System.Drawing.Size(205,30)
    $dlg.Controls.Add($btnRemove)
    $removeTip = New-Object System.Windows.Forms.ToolTip
    $removeTip.SetToolTip($btnRemove, "Removes the checked group(s) from the checked apps in the LOCAL CATALOG only. Push groups to Intune afterward to unassign them there too.")

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(140,658)
    $btnCancel.Size = New-Object System.Drawing.Size(90,30)
    $dlg.Controls.Add($btnCancel)

    $resultBox = @{ Count = $null }

    $btnRemove.Add_Click({
        $pickedFields = @(
            @{ List = $reqGroup.List; FieldName = "requiredFor" }
            @{ List = $availGroup.List; FieldName = "availableFor" }
            @{ List = $uninstGroup.List; FieldName = "uninstallFor" }
        )
        $totalPicked = (@($pickedFields | ForEach-Object { $_.List.CheckedItems.Count }) | Measure-Object -Sum).Sum
        if ($totalPicked -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one group above (Required/Available/Uninstall) first.", "No group selected", "OK", "Warning") | Out-Null
            return
        }
        $checkedAppNames = @($clbApps.CheckedItems | ForEach-Object { [string]$_ })
        if ($checkedAppNames.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one app first.", "Nothing checked", "OK", "Warning") | Out-Null
            return
        }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "Removes $totalPicked group/field pick(s) from $($checkedAppNames.Count) app(s) in the LOCAL CATALOG - each group only from the specific list(s) (Required/Available/Uninstall) it's checked under above. This alone does not change anything in Intune - run `"Push groups to Intune (multiple apps)...`" (Preview, then Apply) right after this to actually unassign them there too.`n`nContinue?",
            "Confirm removal", "YesNo", "Warning")
        if ($r -ne "Yes") { return }

        $changedCount = 0
        foreach ($checkedAppName in $checkedAppNames) {
            $target = $appsRef | Where-Object { $_.appName -eq $checkedAppName } | Select-Object -First 1
            if (-not $target) { continue }
            $targetChanged = $false
            foreach ($pick in $pickedFields) {
                $checkedNamesForField = @($pick.List.CheckedItems | ForEach-Object { [string]$_ })
                if ($checkedNamesForField.Count -eq 0) { continue }
                $before = @($target.($pick.FieldName))
                $after = @($before | Where-Object { $checkedNamesForField -notcontains $_ })
                if ($after.Count -ne $before.Count) {
                    $target.($pick.FieldName) = $after
                    $targetChanged = $true
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
    $dlg.AcceptButton = $btnRemove
    Set-Theme -Control $dlg
    $dlgResult = $dlg.ShowDialog($Global:App.Form)
    if ($dlgResult -eq [System.Windows.Forms.DialogResult]::OK) { return $resultBox.Count }
    return $null
}
