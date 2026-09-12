function Global:Show-DependencyOverviewDialog {
    # Plain local alias - see note in Start-IntuneAppLookup.
    $appsRef = $Script:Apps

    if ($appsRef.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("The catalog is empty - nothing to show.", "Nothing to do", "OK", "Information") | Out-Null
        return
    }

    $dependedOnBy = @{}
    foreach ($a in $appsRef) {
        foreach ($depName in @($a.metadata.dependencies)) {
            if (-not $dependedOnBy.ContainsKey($depName)) { $dependedOnBy[$depName] = New-Object System.Collections.Generic.List[string] }
            if (-not $dependedOnBy[$depName].Contains($a.appName)) { $dependedOnBy[$depName].Add($a.appName) }
        }
    }

    $catalogNames = @($appsRef | ForEach-Object { $_.appName })
    $orderResult = Get-DependencyOrderedApps -Apps $appsRef
    $circularNames = @($orderResult.CircularNames)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Dependency overview"
    $dlg.ClientSize = New-Object System.Drawing.Size(820, 540)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(600, 360)
    $dlg.MaximizeBox = $true
    $dlg.MinimizeBox = $false

    # Whether this checks against LIVE Intune data too used to be a fair
    # question - it doesn't, deliberately: that comparison now lives in
    # "Intune Audit...", alongside every other local-vs-Intune
    # check, instead of being duplicated (and re-fetched) here too. This
    # stays a purely local, always-instant view of the catalog's own
    # dependency graph.
    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Every app in the catalog, what it depends on, and what depends on it. Read-only, local only - see `"Intune Audit...`" to check dependencies against what's actually live. Double-click a row to see the full lists if they're truncated."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(790,32)
    $dlg.Controls.Add($lblIntro)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,50)
    $grid.Size = New-Object System.Drawing.Size(790,430)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    $dlg.Controls.Add($grid)

    $colApp = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colApp.Name = "App"; $colApp.HeaderText = "App"; $colApp.FillWeight = 22
    $grid.Columns.Add($colApp) | Out-Null
    $colDependsOn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDependsOn.Name = "DependsOn"; $colDependsOn.HeaderText = "Depends on"; $colDependsOn.FillWeight = 34
    $grid.Columns.Add($colDependsOn) | Out-Null
    $colDependedOnBy = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDependedOnBy.Name = "DependedOnBy"; $colDependedOnBy.HeaderText = "Depended on by"; $colDependedOnBy.FillWeight = 34
    $grid.Columns.Add($colDependedOnBy) | Out-Null
    $colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStatus.Name = "Status"; $colStatus.HeaderText = "Status"; $colStatus.FillWeight = 20
    $grid.Columns.Add($colStatus) | Out-Null

    # Not-OK rows in bold orange/red, same convention as every other check
    # dialog in this app.
    $grid.Add_CellFormatting({
        param($gridSender, $e)
        if ($grid.Columns[$e.ColumnIndex].Name -ne "Status") { return }
        if ([string]$e.Value -eq "Circular") {
            $e.CellStyle.ForeColor = [System.Drawing.Color]::Firebrick
            $e.CellStyle.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
        }
        elseif ([string]$e.Value -like "Missing dependency*") {
            $e.CellStyle.ForeColor = [System.Drawing.Color]::DarkOrange
            $e.CellStyle.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
        }
    }.GetNewClosure())

    $grid.Add_CellDoubleClick({
        param($gridSender, $e)
        if ($e.RowIndex -lt 0) { return }
        $row = $grid.Rows[$e.RowIndex]
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("Depends on:")
        $lines.Add("  $([string]$row.Cells['DependsOn'].Value)")
        $lines.Add("")
        $lines.Add("Depended on by:")
        $lines.Add("  $([string]$row.Cells['DependedOnBy'].Value)")
        [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), "Dependencies - $([string]$row.Cells['App'].Value)", "OK", "Information") | Out-Null
    }.GetNewClosure())

    foreach ($a in ($appsRef | Sort-Object appName)) {
        $depNames = @($a.metadata.dependencies)
        $dependedOnByNames = if ($dependedOnBy.ContainsKey($a.appName)) { @($dependedOnBy[$a.appName]) } else { @() }
        $missingDeps = @($depNames | Where-Object { $catalogNames -notcontains $_ })

        $status = "OK"
        if ($circularNames -contains $a.appName) { $status = "Circular" }
        elseif ($missingDeps.Count -gt 0) { $status = "Missing dependency: $($missingDeps -join ', ')" }

        $dependsOnText = if ($depNames.Count -gt 0) { $depNames -join ", " } else { "(none)" }
        $dependedOnByText = if ($dependedOnByNames.Count -gt 0) { $dependedOnByNames -join ", " } else { "(none)" }

        [void]$grid.Rows.Add($a.appName, $dependsOnText, $dependedOnByText, $status)
    }

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(720,490)
    $btnClose.Size = New-Object System.Drawing.Size(85,32)
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnClose)
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnClose

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
}
