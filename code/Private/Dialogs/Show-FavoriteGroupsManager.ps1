function Global:Show-FavoriteGroupsManager {
    # Plain local alias - see note in Start-IntuneAppLookup. Needed here
    # specifically because $btnSave's own closure below mutates this
    # (Clear/Add), not just reads it.
    $favoriteGroupsRef = $Global:App.FavoriteGroups

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Favorite groups"
    $dlg.ClientSize = New-Object System.Drawing.Size(420, 415)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Checked groups show up as ready-to-tick options in every app's Required/Available/Uninstall lists. Unchecked groups still work fine via `"+ New group...`" in those lists - they just aren't shown by default. Right-click an unchecked group to remove it from this list entirely.`n`nNothing here takes effect until you click Save below."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(390,75)
    $dlg.Controls.Add($lblIntro)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = New-Object System.Drawing.Point(15,93)
    $clb.Size = New-Object System.Drawing.Size(390,255)
    $clb.CheckOnClick = $true
    # Union of every group already used anywhere in the catalog and
    # whatever's currently marked a favorite - a favorite that no app
    # happens to use yet (e.g. one added here directly via "+ New
    # group...", below) still needs to show up checked, not silently
    # dropped just because Get-AllKnownGroups doesn't know about it yet.
    $knownGroups = @(Get-AllKnownGroups)
    # The ACTUALLY-saved set, before the first-time default below can
    # replace it - used to detect "nothing real has been saved, what's
    # checked right now is just a suggestion" so Cancel/X can warn instead
    # of silently discarding what looks, on screen, exactly like a normal
    # saved state.
    $actuallySavedFavorites = @($favoriteGroupsRef)
    $currentFavorites = $actuallySavedFavorites
    # First time this is ever opened - no favorites have been marked at
    # all yet - defaults to every group already in use as a sensible
    # starting point to prune from, rather than opening on an entirely
    # blank list that offers nothing to work with until every box gets
    # checked by hand one at a time.
    if ($currentFavorites.Count -eq 0 -and $knownGroups.Count -gt 0) {
        $currentFavorites = $knownGroups
    }
    $allOptions = @(@($knownGroups) + @($currentFavorites) | Select-Object -Unique | Sort-Object)
    foreach ($g in $allOptions) {
        $idx = $clb.Items.Add($g)
        if ($currentFavorites -contains $g) { $clb.SetItemChecked($idx, $true) }
    }
    Add-RemovableItemContextMenu -CheckedListBox $clb
    $dlg.Controls.Add($clb)

    $btnAddGroup = New-Object System.Windows.Forms.Button
    # "+ Group/user...", not "+ New group..." - see the same rename and
    # reasoning in Show-AppEditor's own New-GroupBox (Show-EntraMemberPicker
    # below lets you pick a USER too, not just a group).
    $btnAddGroup.Text = "+ Group/user..."
    $btnAddGroup.Location = New-Object System.Drawing.Point(15,355)
    $btnAddGroup.Size = New-Object System.Drawing.Size(140,30)
    $btnAddGroup.Add_Click({
        $picked = Show-EntraMemberPicker
        if ($picked) {
            $picked = $picked.Trim()
            if ($picked -and ($clb.Items -notcontains $picked)) {
                $idx = $clb.Items.Add($picked)
                $clb.SetItemChecked($idx, $true)
            }
        }
    }.GetNewClosure())
    $dlg.Controls.Add($btnAddGroup)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(230,355)
    $btnSave.Size = New-Object System.Drawing.Size(85,30)
    $btnSave.Add_Click({
        $favoriteGroupsRef.Clear()
        foreach ($item in $clb.CheckedItems) { [void]$favoriteGroupsRef.Add([string]$item) }
        if (Save-FavoriteGroups) {
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        }
    }.GetNewClosure())
    $dlg.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(320,355)
    $btnCancel.Size = New-Object System.Drawing.Size(85,30)

    # Compares what's checked right now against the set actually on disk
    # (captured above, before the first-time "suggest everything" default
    # could overwrite it) - catches both "changed something and forgot to
    # Save" AND the more surprising case this exists for: opened on a
    # totally untouched suggested default and closed without ever
    # realizing nothing was saved yet.
    $HasUnsavedFavoriteChanges = {
        $checkedNow = @($clb.CheckedItems | ForEach-Object { [string]$_ } | Sort-Object)
        $saved = @($actuallySavedFavorites | Sort-Object)
        [string]::Join("`n", $checkedNow) -ne [string]::Join("`n", $saved)
    }.GetNewClosure()
    $discardConfirmedBox = @{ Value = $false }

    $btnCancel.Add_Click({
        if (& $HasUnsavedFavoriteChanges) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "These checked groups were never saved as favorites - closing now discards them, and they won't show up as ready-to-tick options in any app's Required/Available/Uninstall lists.`n`nDiscard?",
                "Unsaved favorite groups", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            $discardConfirmedBox.Value = $true
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    }.GetNewClosure())
    $dlg.Controls.Add($btnCancel)

    # Backstop for the window's own X button / Alt+F4, which don't go
    # through Cancel's click handler above at all.
    $dlg.Add_FormClosing({
        param($s, $e)
        if ($dlg.DialogResult -eq [System.Windows.Forms.DialogResult]::OK) { return }
        if ($discardConfirmedBox.Value) { return }
        if (& $HasUnsavedFavoriteChanges) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "These checked groups were never saved as favorites - closing now discards them, and they won't show up as ready-to-tick options in any app's Required/Available/Uninstall lists.`n`nDiscard?",
                "Unsaved favorite groups", "YesNo", "Warning")
            if ($r -ne "Yes") { $e.Cancel = $true }
        }
    }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnSave
    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
