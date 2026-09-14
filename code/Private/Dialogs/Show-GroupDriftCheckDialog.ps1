function Global:Show-GroupDriftCheckDialog {
    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef  = $Global:App.Apps
    $cacheRef = $Global:App.EntraDirectoryCache

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Group name check"
    $dlg.ClientSize = New-Object System.Drawing.Size(700, 500)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Checks every group name referenced anywhere in the catalog against Entra ID, and lists any not found - a rename, a deletion, a typo, or one never created. A rename is best fixed via `"Pull metadata and groups from Intune...`"; review and fix anything else here by hand."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(670,48)
    $dlg.Controls.Add($lblIntro)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,62)
    $lblStatus.Size = New-Object System.Drawing.Size(480,20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh from Entra ID"
    $btnRefresh.Location = New-Object System.Drawing.Point(505,60)
    $btnRefresh.Size = New-Object System.Drawing.Size(180,26)
    $dlg.Controls.Add($btnRefresh)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,92)
    $grid.Size = New-Object System.Drawing.Size(670,340)
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

    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.Name = "GroupName"; $colName.HeaderText = "Group name"; $colName.FillWeight = 35
    $grid.Columns.Add($colName) | Out-Null
    $colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStatus.Name = "Status"; $colStatus.HeaderText = "Status"; $colStatus.FillWeight = 20
    $grid.Columns.Add($colStatus) | Out-Null
    $colUsedBy = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colUsedBy.Name = "UsedBy"; $colUsedBy.HeaderText = "Referenced by"; $colUsedBy.FillWeight = 45
    $grid.Columns.Add($colUsedBy) | Out-Null
    $dlg.Controls.Add($grid)

    # Not-found rows in bold orange, so the ones that actually need
    # attention stand out at a glance rather than blending into a full list.
    $grid.Add_CellFormatting({
        param($gridSender, $e)
        if ($grid.Columns[$e.ColumnIndex].Name -eq "Status" -and $e.Value -eq "Not found in Entra ID") {
            $e.CellStyle.ForeColor = [System.Drawing.Color]::DarkOrange
            $e.CellStyle.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
        }
    }.GetNewClosure())

    # "Referenced by" can be a long, comma-joined app list that gets
    # truncated within the cell - double-click any row to see the full text
    # rather than needing to widen the column or scroll horizontally.
    $grid.Add_CellDoubleClick({
        param($gridSender, $e)
        if ($e.RowIndex -lt 0) { return }
        $row = $grid.Rows[$e.RowIndex]
        $groupName = [string]$row.Cells["GroupName"].Value
        $usedBy = [string]$row.Cells["UsedBy"].Value
        [System.Windows.Forms.MessageBox]::Show($usedBy, "Referenced by - $groupName", "OK", "Information") | Out-Null
    }.GetNewClosure())

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(605,444)
    $btnClose.Size = New-Object System.Drawing.Size(80,32)
    $dlg.Controls.Add($btnClose)

    $populateGrid = {
        $grid.DataSource = $null
        $grid.Rows.Clear()

        $entraGroupNames = @{}
        foreach ($e in $cacheRef) {
            if ($e.type -eq "Group") {
                $norm = ($e.displayName.Trim() -replace '\s+', ' ')
                $entraGroupNames[$norm] = $true
            }
        }

        # Map every referenced group name -> the app names that reference it
        $usage = @{}
        foreach ($app in $appsRef) {
            $refs = @($app.requiredFor) + @($app.availableFor) + @($app.uninstallFor)
            foreach ($g in ($refs | Select-Object -Unique)) {
                if (-not $g) { continue }
                if (-not $usage.ContainsKey($g)) { $usage[$g] = New-Object System.Collections.Generic.List[string] }
                if (-not $usage[$g].Contains($app.appName)) { $usage[$g].Add($app.appName) }
            }
        }

        $rows = @($usage.Keys | ForEach-Object {
            $norm = ($_.Trim() -replace '\s+', ' ')
            [pscustomobject]@{
                Name  = $_
                Found = $entraGroupNames.ContainsKey($norm)
            }
        })
        # Not-found rows first (the ones that need a look), each bucket
        # sorted alphabetically within itself - PowerShell's default
        # ascending sort already puts $false before $true, so sorting by
        # Found ascending correctly puts "not found" (false) rows first.
        $ordered = @($rows | Sort-Object Found, Name)

        $missingCount = 0
        foreach ($r in $ordered) {
            if ($r.Found) {
                $status = "OK"
            }
            else {
                $status = "Not found in Entra ID"
                $missingCount++
            }
            [void]$grid.Rows.Add($r.Name, $status, ($usage[$r.Name] -join ", "))
        }

        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "$($usage.Keys.Count) group name(s) referenced in the catalog - $missingCount not found in Entra ID."
    }.GetNewClosure()

    $btnRefresh.Add_Click({
        $btnRefresh.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Fetching groups from Entra ID..."
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnRefreshRef = $btnRefresh
        $dlgRef = $dlg
        $lblStatusRef = $lblStatus
        $populateGridRef = $populateGrid

        Start-EntraDirectoryLookup -OnComplete {
            param($ok, $msg)
            $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
            $btnRefreshRef.Enabled = $true
            if (-not $ok) {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblStatusRef.Text = "Fetch failed: $msg"
                return
            }
            & $populateGridRef
        }.GetNewClosure()
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnClose

    # Blocks the window (X button / Alt+F4, not just Close) from closing
    # while Start-EntraDirectoryLookup's background runspace is still in
    # flight - $btnRefresh.Enabled already IS the "is a fetch running" flag
    # (see the click handler above). Without this, closing mid-fetch leaves
    # its timer ticking against controls on a disposed form.
    $dlg.Add_FormClosing({
        param($s, $e)
        if (-not $btnRefresh.Enabled) { return }
        $e.Cancel = $true
    }.GetNewClosure())

    # Deferred to Add_Shown rather than called directly here - kicking off
    # the async refresh (PerformClick -> Start-.../timer) BEFORE ShowDialog()
    # has actually shown/realized the window let the WaitCursor assignment
    # get set on a not-yet-created window handle, which doesn't reliably
    # "stick" - the cursor could end up stuck spinning even after the async
    # work (and its Cursor = Default reset) had already completed.
    #
    # Always a live fetch, never the reused-cache branch this used to have -
    # $cacheRef ($Global:App.EntraDirectoryCache) is shared across the whole
    # app, so it can already be non-empty here purely from something
    # unrelated done earlier in the session. This dialog's entire job is
    # telling you what's actually missing in Entra ID right now, so opening
    # it must mean "check now", not "show whatever happened to be cached
    # from something else, however old that is" - same reasoning as the
    # identical fix in Show-IntuneOnlyAppsDialog's own Add_Shown.
    $dlg.Add_Shown({
        $btnRefresh.PerformClick()
    }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
