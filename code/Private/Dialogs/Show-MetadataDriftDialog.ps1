function Global:Show-MetadataDriftDialog {
    # -AppName is optional and purely cosmetic (title/header only) - lets a
    # caller reviewing MULTIPLE apps in a row (bulk "Pull metadata and groups from Intune...")
    # make clear which app each popup is actually about, since several of
    # these can appear back to back in that flow.
    param($Rows, [string]$AppName = "")

    $dlg = New-Object System.Windows.Forms.Form
    $rowWord = if (@($Rows).Count -eq 1) { "field" } else { "fields" }
    $appSuffix = if ($AppName) { " - $AppName" } else { "" }
    $dlg.Text = "Local vs. Intune - $(@($Rows).Count) $rowWord differ$appSuffix"
    $dlg.ClientSize = New-Object System.Drawing.Size(800, 480)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(600, 320)
    $dlg.MaximizeBox = $true
    $dlg.MinimizeBox = $false

    $lblHeader = New-Object System.Windows.Forms.Label
    $appPhrase = if ($AppName) { " for `"$AppName`"" } else { "" }
    $lblHeader.Text = "These fields$appPhrase differ between your local catalog copy and what's actually live in Intune. Intune's value wins by default for every row - untick a row below to keep your local value for that field instead."
    $lblHeader.Location = New-Object System.Drawing.Point(15,12)
    $lblHeader.Size = New-Object System.Drawing.Size(770,40)
    $dlg.Controls.Add($lblHeader)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,58)
    $grid.Size = New-Object System.Drawing.Size(770,362)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells
    $grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
    # Fixed-pixel column widths (the original .Width-only setup this
    # replaced) meant the GRID itself stretched to fill a resized/
    # maximized dialog (it's anchored on all four sides), but the columns
    # inside it stayed pinned at their original widths - leaving a large,
    # useless blank strip on the right instead of actually using the extra
    # room for the Local/Intune text columns that need it most. FillWeight
    # mirrors the original 110:150:250:250 proportions, so a default-sized
    # window looks the same as before; only a resized one now benefits.
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill

    $colUse = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colUse.Name = "UseIntune"
    $colUse.HeaderText = "Use Intune's value"
    $colUse.FillWeight = 14
    [void]$grid.Columns.Add($colUse)

    $colField = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colField.Name = "Field"
    $colField.HeaderText = "Field"
    $colField.ReadOnly = $true
    $colField.FillWeight = 19
    [void]$grid.Columns.Add($colField)

    $colLocal = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colLocal.Name = "Local"
    $colLocal.HeaderText = "Local (catalog)"
    $colLocal.ReadOnly = $true
    $colLocal.FillWeight = 33
    $colLocal.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
    [void]$grid.Columns.Add($colLocal)

    $colIntune = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colIntune.Name = "Intune"
    $colIntune.HeaderText = "Intune (live)"
    $colIntune.ReadOnly = $true
    $colIntune.FillWeight = 34
    $colIntune.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
    [void]$grid.Columns.Add($colIntune)

    $dlg.Controls.Add($grid)

    foreach ($row in @($Rows)) {
        $rIdx = $grid.Rows.Add()
        $grid.Rows[$rIdx].Cells["UseIntune"].Value = $true
        $grid.Rows[$rIdx].Cells["Field"].Value = $row.Field
        $grid.Rows[$rIdx].Cells["Local"].Value = if ([string]::IsNullOrWhiteSpace($row.Local)) { "(blank)" } else { $row.Local }
        $grid.Rows[$rIdx].Cells["Intune"].Value = if ([string]::IsNullOrWhiteSpace($row.Intune)) { "(blank)" } else { $row.Intune }
    }

    $btnAllIntune = New-Object System.Windows.Forms.Button
    $btnAllIntune.Text = "Use Intune for all"
    $btnAllIntune.Location = New-Object System.Drawing.Point(15,428)
    $btnAllIntune.Size = New-Object System.Drawing.Size(140,28)
    $btnAllIntune.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $dlg.Controls.Add($btnAllIntune)
    $allIntuneTip = New-Object System.Windows.Forms.ToolTip
    $allIntuneTip.SetToolTip($btnAllIntune, "Sets every row's choice to Intune's value - just changes the picks below, doesn't apply anything until you click OK.")

    $btnAllLocal = New-Object System.Windows.Forms.Button
    $btnAllLocal.Text = "Keep local for all"
    $btnAllLocal.Location = New-Object System.Drawing.Point(160,428)
    $btnAllLocal.Size = New-Object System.Drawing.Size(140,28)
    $btnAllLocal.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $dlg.Controls.Add($btnAllLocal)
    $allLocalTip = New-Object System.Windows.Forms.ToolTip
    $allLocalTip.SetToolTip($btnAllLocal, "Sets every row's choice to keep your local value - just changes the picks below, doesn't apply anything until you click OK.")

    $btnAllIntune.Add_Click({
        $grid.EndEdit()
        foreach ($r in $grid.Rows) { $r.Cells["UseIntune"].Value = $true }
    }.GetNewClosure())
    $btnAllLocal.Add_Click({
        $grid.EndEdit()
        foreach ($r in $grid.Rows) { $r.Cells["UseIntune"].Value = $false }
    }.GetNewClosure())

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"
    $btnOk.Location = New-Object System.Drawing.Point(615,428)
    $btnOk.Size = New-Object System.Drawing.Size(80,28)
    $btnOk.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(705,428)
    $btnCancel.Size = New-Object System.Drawing.Size(80,28)
    $btnCancel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnCancel)

    # Plain local box (not $Script:-qualified) - see the same pattern/reasoning
    # in Show-SimpleListPicker.
    $resultBox = @{ Value = @() }
    $btnOk.Add_Click({
        $grid.EndEdit()
        $keepLocal = New-Object System.Collections.Generic.List[string]
        foreach ($r in $grid.Rows) {
            if (-not [bool]$r.Cells["UseIntune"].Value) { $keepLocal.Add([string]$r.Cells["Field"].Value) }
        }
        $resultBox.Value = @($keepLocal)
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure())
    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    }.GetNewClosure())

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    Set-Theme -Control $dlg

    $result = $dlg.ShowDialog($Global:App.Form)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $resultBox.Value }
    return @()
}
