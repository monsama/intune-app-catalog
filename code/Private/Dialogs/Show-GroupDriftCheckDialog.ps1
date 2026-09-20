function Global:Show-GroupDriftCheckDialog {
    # -HostTabPage: become one tab of Show-ChecksDialog instead of a window
    # of its own - see Move-DialogToTabPage.
    param([System.Windows.Forms.TabPage]$HostTabPage, [System.Windows.Forms.Form]$HostForm)
    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef  = $Global:App.Apps
    $cacheRef = $Global:App.EntraDirectoryCache

    $dlg = New-Object System.Windows.Forms.Form
    # The window the busy cursor belongs to: this dialog standalone, or the
    # host it was moved into as a tab. Embedded, $dlg is never shown, so a
    # wait cursor set on it is a wait cursor nobody sees. A box, so the
    # hosted branch at the bottom can repoint it after the closures below
    # have captured it.
    $busyFormBox = @{ Form = $dlg }
    $dlg.Font = Get-AppUiFont
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
    # An empty result must not read as a clean one to somebody who did
    # not watch this open.
    $lblStatus.Text = "Not checked yet - press Refresh from Entra ID."
    $dlg.Controls.Add($lblStatus)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh from Entra ID"
    $btnRefresh.Location = New-Object System.Drawing.Point(505,60)
    $btnRefresh.Size = New-Object System.Drawing.Size(180,26)
    $dlg.Controls.Add($btnRefresh)

    $grid = New-Object System.Windows.Forms.DataGridView
    Set-AppGridStyle -Grid $grid
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
        $busyFormBox.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnRefreshRef = $btnRefresh
        $lblStatusRef = $lblStatus
        $populateGridRef = $populateGrid
        $busyFormBoxRef = $busyFormBox

        Start-EntraDirectoryLookup -OnComplete {
            param($ok, $msg)
            $busyFormBoxRef.Form.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
            # See the same pattern's note in Show-WingetSearchDialog - forces
            # an immediate cursor repaint instead of waiting on a mouse move.
            [System.Windows.Forms.Application]::DoEvents()
            [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
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
        # $btnRefresh.Enabled is TRUE when idle (no fetch running) and
        # FALSE while a fetch is in flight (see the click handler above) -
        # this condition was inverted, so closing was blocked whenever
        # idle (confirmed live: the dialog couldn't be closed at all once
        # its own auto-refresh on open had finished) and silently
        # ALLOWED mid-fetch, the one case this was actually meant to stop.
        if ($btnRefresh.Enabled) { return }
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
    if ($HostTabPage) {
        $btnClose.Visible = $false
        # The controls belong to the host window now, so that is where the
        # busy cursor has to go - see $busyFormBox above.
        $busyFormBox.Form = $HostForm
        [void](Move-DialogToTabPage -Dialog $dlg -Page $HostTabPage)
        # Embedded, the Add_Shown above never fires - the dialog itself is
        # never shown. The host runs this the first time this tab is
        # opened, deliberately not when the window opens: this check reads
        # every group in the catalog out of Entra ID, and opening a window
        # of checks should not fire off everything at once.
        #
        # BlockClose keeps the host from closing mid-fetch for the same
        # reason the FormClosing guard above kept this dialog open:
        # $btnRefresh is disabled exactly while a fetch is in flight, and
        # a timer is still ticking against these controls.
        $HostTabPage.Tag = @{
            Fill        = $grid
            RunAll      = { $btnRefresh.PerformClick() }.GetNewClosure()
            # IsBusy is "still working" (what Run all waits on before
            # starting the next check); BlockClose is the stricter "must not
            # be interrupted". Here they are the same condition, because a
            # fetch in flight is exactly what closing would break.
            IsBusy      = { -not $btnRefresh.Enabled }.GetNewClosure()
            BlockClose  = { -not $btnRefresh.Enabled }.GetNewClosure()
            # This grid only ever lists groups it could NOT find, so a row
            # is a finding and an empty grid is the good answer.
            Summary     = { if ($grid.Rows.Count -gt 0) { "$($grid.Rows.Count) group(s) not found" } else { "" } }.GetNewClosure()
        }
        return
    }
    [void]$dlg.ShowDialog($Global:App.Form)
}
