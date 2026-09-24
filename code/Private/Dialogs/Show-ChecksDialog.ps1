function Global:Show-ChecksDialog {
    <#
      Every check this app runs, as one run and one list.

      It used to be eight tabs - Sync check, App IDs, Audit, Metadata sync,
      Dependencies, Catalog groups, Winget packages, Diagnostics - and most
      of them answered part of the same question: does the catalog still
      match reality? Sync check and App IDs were two halves of "how do the
      catalog's apps line up with the tenant's", Metadata sync was the
      audit's Pull button, and each read Intune on its own.

      Now one Run reads everything once, in this order, and every problem
      any of it finds is a row of the same list (see CheckFindings.ps1):
        1. the catalog's own dependencies     instant, nothing to ask
        2. the tenant's app list               how the catalog lines up
        3. each deployed app, in detail        metadata, groups,
                                               dependencies, assignments
        4. Entra ID's groups                   group names that exist
        5. winget                              Winget IDs that still exist
                                               (skippable - it is slow)
      A row says which area it is from, what the catalog has and what the
      other side has, and the buttons under the list are the fixes that
      apply to what is selected: Pull, Push, Add to catalog, set or clear
      an App ID, and so on. The fixes are the same tools as before -
      Pull is "Pull metadata and groups from Intune", Push groups is the
      assign dialog - so they behave and ask exactly as they always have.

      Diagnostics (this machine's own setup) is not here: it isn't about
      the catalog. It lives in Settings.

      -ScopedIndices narrows the run to those catalog apps (the grid's
      right-click "Run audit..."). -StartTab picks what the list shows
      first, by the old tab names, so every entry point that asked for a
      tab still lands on the right rows. -AutoRun starts a run as soon as
      the window opens.
    #>

    param([int[]]$ScopedIndices = @(), [string]$StartTab, [switch]$AutoRun)

    $appsRef = $Global:App.Apps
    $isScoped = @($ScopedIndices).Count -gt 0
    $scopeNames = if ($isScoped) { @($ScopedIndices | ForEach-Object { [string]$appsRef[$_].appName }) } else { $null }

    # Areas in the order the list shows them - the order the questions get
    # asked, from "is it even the same app" down to "does the package exist".
    $areaOrder = @("Intune link", "Metadata", "Groups", "Dependencies", "Unknown assignments", "Catalog dependencies", "Entra groups", "Winget ID")

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = if ($isScoped) { "Checks - $(@($scopeNames).Count) selected app(s)" } else { "Checks" }
    $dlg.ClientSize = New-Object System.Drawing.Size(1180, 720)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(900, 600)
    $dlg.MaximizeBox = $true
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "One run checks everything - the catalog against Intune's apps, each deployed app's metadata, groups, dependencies and assignments, the catalog's own dependencies, its Entra ID groups and its Winget IDs - and lists what needs fixing. Checking only reads. Select rows and fix them with the buttons under the list."
    $lblIntro.Location = New-Object System.Drawing.Point(15,8)
    $lblIntro.Size = New-Object System.Drawing.Size(1150,46)
    $lblIntro.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($lblIntro)

    # Bordered and scrollable: the status can carry an error message of any
    # length, which a one-line label would clip.
    $pnlStatus = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlStatus.Location = New-Object System.Drawing.Point(15,58)
    $pnlStatus.Size = New-Object System.Drawing.Size(800,40)
    $pnlStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $pnlStatus.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $pnlStatus.WrapContents = $false
    $pnlStatus.AutoScroll = $true
    $pnlStatus.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $pnlStatus.BackColor = $Global:App.LightPalette.FieldBack
    $pnlStatus.Padding = New-Object System.Windows.Forms.Padding(6)
    $dlg.Controls.Add($pnlStatus)
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.AutoSize = $true
    $lblStatus.MaximumSize = New-Object System.Drawing.Size(770,0)
    $lblStatus.Margin = New-Object System.Windows.Forms.Padding(0)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $pnlStatus.Controls.Add($lblStatus)
    $pnlStatus.Add_SizeChanged({
        $lblStatus.MaximumSize = New-Object System.Drawing.Size([Math]::Max(100, $pnlStatus.ClientSize.Width - 30), 0)
    }.GetNewClosure())

    $chkSkipWinget = New-Object System.Windows.Forms.CheckBox
    $chkSkipWinget.Text = "Skip Winget IDs"
    $chkSkipWinget.Location = New-Object System.Drawing.Point(828,66)
    $chkSkipWinget.Size = New-Object System.Drawing.Size(150,24)
    $chkSkipWinget.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($chkSkipWinget)

    $btnStop = New-Object System.Windows.Forms.Button
    $btnStop.Text = "Stop"
    $btnStop.Location = New-Object System.Drawing.Point(985,62)
    $btnStop.Size = New-Object System.Drawing.Size(72,30)
    $btnStop.Enabled = $false
    $btnStop.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnStop)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Run checks"
    $btnRun.Location = New-Object System.Drawing.Point(1065,62)
    $btnRun.Size = New-Object System.Drawing.Size(100,30)
    $btnRun.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnRun)

    $prg = New-Object System.Windows.Forms.ProgressBar
    $prg.Location = New-Object System.Drawing.Point(15,102)
    $prg.Size = New-Object System.Drawing.Size(1150,6)
    $prg.Style = "Marquee"
    $prg.MarqueeAnimationSpeed = 30
    $prg.Visible = $false
    $prg.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($prg)

    $lblShow = New-Object System.Windows.Forms.Label
    $lblShow.Text = "Show:"
    $lblShow.Location = New-Object System.Drawing.Point(15,117)
    $lblShow.AutoSize = $true
    $dlg.Controls.Add($lblShow)
    $cmbShow = New-Object System.Windows.Forms.ComboBox
    $cmbShow.DropDownStyle = "DropDownList"
    $cmbShow.Location = New-Object System.Drawing.Point(62,113)
    $cmbShow.Size = New-Object System.Drawing.Size(280,24)
    $dlg.Controls.Add($cmbShow)
    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Location = New-Object System.Drawing.Point(352,117)
    $lblCount.Size = New-Object System.Drawing.Size(813,20)
    $lblCount.AutoEllipsis = $true
    $lblCount.ForeColor = [System.Drawing.Color]::DimGray
    $lblCount.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($lblCount)

    $grid = New-Object System.Windows.Forms.DataGridView
    Set-AppGridStyle -Grid $grid
    $grid.Location = New-Object System.Drawing.Point(15,144)
    $grid.Size = New-Object System.Drawing.Size(1150,372)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $true
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    foreach ($colSpec in @(
        @{ Name = "Area";    Header = "Area";      Weight = 12 }
        @{ Name = "App";     Header = "App";       Weight = 16 }
        @{ Name = "Problem"; Header = "Problem";   Weight = 24 }
        @{ Name = "Catalog"; Header = "Catalog";   Weight = 20 }
        @{ Name = "Intune";  Header = "Intune / other side"; Weight = 20 }
        @{ Name = "Checked"; Header = "Checked";   Weight = 8 }
    )) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $colSpec.Name; $col.HeaderText = $colSpec.Header; $col.FillWeight = $colSpec.Weight
        [void]$grid.Columns.Add($col)
    }
    $dlg.Controls.Add($grid)

    # The fixes for what is selected. Built from $actionSpecs below; only
    # the ones that apply to the selection are shown.
    $pnlFix = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlFix.Location = New-Object System.Drawing.Point(15,522)
    $pnlFix.Size = New-Object System.Drawing.Size(1150,36)
    $pnlFix.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $pnlFix.WrapContents = $false
    $pnlFix.AutoScroll = $true
    $dlg.Controls.Add($pnlFix)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Location = New-Object System.Drawing.Point(15,560)
    $lblHint.Size = New-Object System.Drawing.Size(1150,20)
    $lblHint.AutoEllipsis = $true
    $lblHint.ForeColor = [System.Drawing.Color]::DimGray
    $lblHint.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($lblHint)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,584)
    $rtbLog.Size = New-Object System.Drawing.Size(1150,86)
    $rtbLog.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(1075,678)
    $btnClose.Size = New-Object System.Drawing.Size(90,32)
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnClose)
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    # Esc closes. No AcceptButton: several fixes here write, and Enter
    # should not be a way to trigger one mid-list.
    $dlg.CancelButton = $btnClose

    $tips = New-Object System.Windows.Forms.ToolTip
    $tips.SetToolTip($chkSkipWinget, "Winget is asked about every Winget ID one at a time, which can take minutes on a large catalog. Tick to leave that part out of this run.")
    $tips.SetToolTip($btnRun, "Runs every check. Only reads - nothing in Intune or the catalog changes until you use a fix below.")
    $tips.SetToolTip($btnStop, "Stops the run. What was already found stays in the list.")

    # Everything the closures below share, in one place. A closure built
    # with GetNewClosure() captures values, not live variables, and one
    # nested inside another doesn't reliably see the outer one's - see the
    # note at the top of Show-CreateInIntuneDialog. A hashtable is a
    # reference, so every closure that captures $ctx sees the same state,
    # and the functions it holds can call each other through it.
    $ctx = @{
        Dlg = $dlg; Grid = $grid; Status = $lblStatus; LblCount = $lblCount; Hint = $lblHint; Log = $rtbLog
        Prg = $prg; BtnRun = $btnRun; BtnStop = $btnStop; ChkSkipWinget = $chkSkipWinget; CmbShow = $cmbShow; PnlFix = $pnlFix
        Apps = $appsRef; Scoped = $isScoped; ScopeNames = $scopeNames; AreaOrder = $areaOrder
        # Read with .ToArray(), never @(...): @() over a List[object]
        # throws "Argument types do not match" in PowerShell.
        Findings = New-Object System.Collections.Generic.List[object]
        # What has been read this session, so a fix can recompute its area
        # without reading again.
        IntuneRead = $false; EntraRead = $false
        Run = @{ Id = 0; Active = $false; Stopped = $false; Queue = $null; Names = $null; Procs = @{}; Winget = $null; Pending = 0; Problems = (New-Object System.Collections.Generic.List[string]) }
        Changed = $false
        ShowFilter = "All areas"
        ActionButtons = [ordered]@{}
        SelectingAll = $false
    }

    # --- helpers --------------------------------------------------------

    $ctx.SetStatus = {
        param([string]$Text, [string]$Tone = "Info")
        if ($ctx.Dlg.IsDisposed) { return }
        $ctx.Status.ForeColor = switch ($Tone) {
            "Good"  { [System.Drawing.Color]::SeaGreen }
            "Warn"  { [System.Drawing.Color]::DarkOrange }
            "Bad"   { [System.Drawing.Color]::Firebrick }
            default { [System.Drawing.Color]::DimGray }
        }
        $ctx.Status.Text = $Text
    }.GetNewClosure()

    $ctx.InScope = {
        param([string]$Name)
        if (-not $ctx.Scoped) { return $true }
        return (@($ctx.ScopeNames) -contains $Name)
    }.GetNewClosure()

    # The catalog apps a run or a fix is about: the scope if there is one.
    $ctx.ScopeApps = {
        return @($ctx.Apps | Where-Object { $_ -and (& $ctx.InScope ([string]$_.appName)) })
    }.GetNewClosure()

    $ctx.IndexOf = {
        param([string]$Name)
        for ($i = 0; $i -lt $ctx.Apps.Count; $i++) { if ([string]$ctx.Apps[$i].appName -eq $Name) { return $i } }
        return -1
    }.GetNewClosure()

    # Swaps in new findings for the ones they replace, then redraws. Every
    # stage and every fix goes through here, so the list is always "the
    # latest answer for each thing". Replaced: rows in -Areas, narrowed to
    # -Names (catalog names; "" matches rows about no catalog app) when
    # given, leaving failed rows alone with -KeepFailed; or the one row
    # -Key. Plain values rather than a filter scriptblock, which would be
    # a closure built inside another closure - see the note at the top of
    # Show-CreateInIntuneDialog.
    $ctx.Replace = {
        param([string[]]$Areas = @(), $New = @(), [string[]]$Names = $null, [switch]$KeepFailed, [string]$Key = "")
        for ($i = $ctx.Findings.Count - 1; $i -ge 0; $i--) {
            $old = $ctx.Findings[$i]
            $hit = if ($Key) { $old.Key -eq $Key }
                   else {
                       ($Areas -contains $old.Area) -and
                       ($null -eq $Names -or $Names -contains [string]$old.CatalogName) -and
                       -not ($KeepFailed -and $old.Failed)
                   }
            if ($hit) { $ctx.Findings.RemoveAt($i) }
        }
        foreach ($f in @($New)) { if ($f) { $ctx.Findings.Add($f) } }
        & $ctx.Render
    }.GetNewClosure()

    $ctx.Render = {
        if ($ctx.Dlg.IsDisposed) { return }
        $grid = $ctx.Grid
        $selectedKeys = @($grid.SelectedRows | ForEach-Object { $_.Tag.Key })
        $all = $ctx.Findings.ToArray()

        # The Show list: every area that has rows, with its count, plus the
        # checks that failed - rebuilt each time, keeping the choice.
        $cmb = $ctx.CmbShow
        $items = New-Object System.Collections.Generic.List[string]
        $items.Add("All areas ($($all.Count))")
        foreach ($area in $ctx.AreaOrder) {
            $n = @($all | Where-Object { $_.Area -eq $area }).Count
            if ($n -gt 0) { $items.Add("$area ($n)") }
        }
        $failedCount = @($all | Where-Object { $_.Failed }).Count
        if ($failedCount -gt 0) { $items.Add("Could not check ($failedCount)") }
        $wanted = $ctx.ShowFilter
        $ctx.Rendering = $true
        try {
            $cmb.BeginUpdate()
            $cmb.Items.Clear()
            foreach ($item in $items) { [void]$cmb.Items.Add($item) }
            $match = @($items | Where-Object { ($_ -replace ' \(\d+\)$', '') -eq $wanted }) | Select-Object -First 1
            $cmb.SelectedItem = if ($match) { $match } else { $items[0] }
            $cmb.EndUpdate()
        }
        finally { $ctx.Rendering = $false }
        $filter = ([string]$cmb.SelectedItem) -replace ' \(\d+\)$', ''

        $shown = @($all | Where-Object {
            if ($filter -eq "All areas") { $true }
            elseif ($filter -eq "Could not check") { $_.Failed }
            else { $_.Area -eq $filter }
        } | Sort-Object @{ Expression = { [array]::IndexOf($ctx.AreaOrder, $_.Area) } }, @{ Expression = { [string]$_.App } })

        $grid.SuspendLayout()
        $grid.Rows.Clear()
        foreach ($f in $shown) {
            $checked = if ($f.Cached) {
                if ($f.CheckedAt) { try { Get-FriendlyAge -Timestamp $f.CheckedAt } catch { "earlier" } } else { "earlier" }
            } else { "just now" }
            $rowIdx = $grid.Rows.Add([string]$f.Area, [string]$f.App, [string]$f.Problem, [string]$f.Catalog, [string]$f.Intune, $checked)
            $row = $grid.Rows[$rowIdx]
            $row.Tag = $f
            if ($f.Failed) { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Firebrick }
            if ($f.Cached) { $row.DefaultCellStyle.Font = $ctx.ItalicFont }
            $row.Cells["Catalog"].ToolTipText = [string]$f.Catalog
            $row.Cells["Intune"].ToolTipText = [string]$f.Intune
            $row.Cells["Problem"].ToolTipText = [string]$f.Problem
        }
        $grid.ClearSelection()
        foreach ($row in $grid.Rows) { if ($selectedKeys -contains $row.Tag.Key) { $row.Selected = $true } }
        $grid.ResumeLayout()

        $problems = @($all | Where-Object { -not $_.Failed }).Count
        $cachedCount = @($all | Where-Object { $_.Cached }).Count
        $ctx.LblCount.Text = if ($all.Count -eq 0) { "" }
            else { "$problems to look at, $failedCount could not be checked$(if ($cachedCount -gt 0) { " - $cachedCount from earlier runs, in italics" })" }
        & $ctx.UpdateButtons
    }.GetNewClosure()

    $ctx.SelectedFindings = {
        return @($ctx.Grid.SelectedRows | ForEach-Object { $_.Tag } | Where-Object { $_ })
    }.GetNewClosure()

    # --- local findings (no reading needed) ------------------------------

    # Recomputes the areas that come from data already in hand - the
    # catalog itself, plus the tenant's app list and Entra's groups if they
    # have been read. After a fix that changed the catalog, these are
    # current again without another trip to Intune.
    $ctx.RefreshLocal = {
        $scopeApps = & $ctx.ScopeApps
        $onlyNames = if ($ctx.Scoped) { @($ctx.ScopeNames) } else { $null }
        & $ctx.Replace -Areas @("Catalog dependencies") -New (Get-DependencyFindings -Apps $ctx.Apps.ToArray() -OnlyNames $onlyNames)
        if ($ctx.IntuneRead -or @($Global:App.IntuneAppsCache).Count -gt 0) {
            $link = @(Get-IntuneLinkFindings -Apps $scopeApps -IntuneApps @($Global:App.IntuneAppsCache) -Scoped:$ctx.Scoped)
            if (-not $ctx.IntuneRead) { foreach ($f in $link) { $f.Cached = $true } }
            & $ctx.Replace -Areas @("Intune link") -New $link -KeepFailed
        }
        if ($ctx.EntraRead) {
            & $ctx.Replace -Areas @("Entra groups") -New (Get-EntraGroupFindings -Apps $ctx.Apps.ToArray() -Directory @($Global:App.EntraDirectoryCache) -OnlyNames $onlyNames) -KeepFailed
        }
    }.GetNewClosure()

    # --- the run --------------------------------------------------------

    $ctx.Log = $rtbLog
    $ctx.LogLine = {
        param([string]$Text)
        if (-not $ctx.Dlg.IsDisposed) { Write-DialogLogLine -LogBox $ctx.Log -Text "$Text`r`n" }
    }.GetNewClosure()

    # Runs the next queued stage, or finishes. Each stage calls this when
    # its reading is done, so they run strictly one after another - two of
    # them (Intune and Entra) refuse to run alongside another lookup.
    $ctx.Next = {
        $run = $ctx.Run
        if ($ctx.Dlg.IsDisposed) { $run.Active = $false; return }
        if ($run.Stopped -or $run.Queue.Count -eq 0) { & $ctx.Finish; return }
        $stage = $run.Queue.Dequeue()
        try { & $ctx.Stages[$stage] }
        catch {
            $run.Problems.Add("$($stage): $($_.Exception.Message)")
            & $ctx.LogLine "[FAILED] $($stage): $($_.Exception.Message)"
            & $ctx.Next
        }
    }.GetNewClosure()

    $ctx.Finish = {
        $run = $ctx.Run
        $run.Active = $false
        $run.Names = $null
        if ($ctx.Dlg.IsDisposed) { return }
        $ctx.Prg.Visible = $false
        $ctx.BtnRun.Enabled = $true
        $ctx.BtnStop.Enabled = $false
        $all = $ctx.Findings.ToArray()
        $problems = @($all | Where-Object { -not $_.Failed -and -not $_.Cached }).Count
        $failed = @($all | Where-Object { $_.Failed -and -not $_.Cached }).Count
        if ($run.Stopped) {
            & $ctx.SetStatus "Stopped - what was already found is in the list." "Warn"
        }
        elseif ($run.Problems.Count -gt 0) {
            & $ctx.SetStatus "Finished, but not everything could be checked: $($run.Problems.ToArray() -join ' | ')" "Bad"
        }
        elseif ($problems -eq 0 -and $failed -eq 0) {
            & $ctx.SetStatus "Everything checked - nothing to fix." "Good"
        }
        else {
            & $ctx.SetStatus "Finished - $problems thing(s) to look at$(if ($failed -gt 0) { ", $failed that could not be checked" }). Select rows and use the buttons under the list." "Warn"
        }
        & $ctx.UpdateButtons
    }.GetNewClosure()

    $ctx.Start = {
        param([string[]]$OnlyNames, [string[]]$Stages)
        $run = $ctx.Run
        if ($run.Active) { return }
        $run.Active = $true
        $run.Stopped = $false
        # Callbacks from an earlier run (one Stop ended before its read
        # came back) check this and stay out of the new one.
        $run.Id++
        $run.Names = $OnlyNames
        $run.Problems.Clear()
        $run.Queue = New-Object System.Collections.Generic.Queue[string]
        $defaultStages = @("Local", "IntuneApps", "Details", "Entra")
        if (-not $ctx.ChkSkipWinget.Checked) { $defaultStages += "Winget" }
        foreach ($stage in @(if ($Stages) { $Stages } else { $defaultStages })) { $run.Queue.Enqueue($stage) }
        $ctx.BtnRun.Enabled = $false
        $ctx.BtnStop.Enabled = $true
        $ctx.Prg.Visible = $true
        & $ctx.UpdateButtons
        & $ctx.Next
    }.GetNewClosure()

    $ctx.Stages = @{}

    $ctx.Stages.Local = {
        & $ctx.SetStatus "Checking the catalog's own dependencies..."
        & $ctx.RefreshLocal
        & $ctx.Next
    }.GetNewClosure()

    $ctx.Stages.IntuneApps = {
        & $ctx.SetStatus "Reading the list of apps in Intune..."
        # Start-IntuneAppLookup returns without calling back while another
        # lookup is running (it guards itself with this button) - which
        # would leave this run waiting forever.
        if ($Global:App.BtnLookupIds -and -not $Global:App.BtnLookupIds.Enabled) {
            $ctx.Run.Problems.Add("Intune's app list: another lookup is already running")
            & $ctx.Next
            return
        }
        $c = $ctx
        $runId = $ctx.Run.Id
        Start-IntuneAppLookup -LogBox $ctx.Log -OnComplete {
            param($ok, $data)
            if ($c.Dlg.IsDisposed) { $c.Run.Active = $false; return }
            if ($c.Run.Id -ne $runId -or -not $c.Run.Active) { return }
            # Whatever goes wrong in here, the run moves on to its next
            # stage - an error that skipped & $c.Next left the window
            # "checking" forever.
            try {
            if (-not $ok) {
                $c.Run.Problems.Add("Intune: $data")
                & $c.Replace -Areas @("Intune link") -New @(New-CheckFinding -Area "Intune link" -App "(Intune)" -Problem "Could not read Intune's apps: $data" -Failed)
                # Nothing else here can reach Intune or Entra either - the
                # same connection settings are missing or broken.
                if ($data -in @("Not configured", "Module missing")) {
                    $remaining = @($c.Run.Queue.ToArray() | Where-Object { $_ -notin @("Details", "Entra") })
                    $c.Run.Queue.Clear()
                    foreach ($s in $remaining) { $c.Run.Queue.Enqueue($s) }
                }
            }
            else {
                $c.IntuneRead = $true
                # A failure row from an earlier run is answered now
                & $c.Replace -Areas @("Intune link") -Names @("")
                & $c.RefreshLocal
            }
            }
            catch {
                $c.Run.Problems.Add("Intune: $($_.Exception.Message)")
                & $c.LogLine "[FAILED] Intune: $($_.Exception.Message)"
            }
            & $c.Next
        }.GetNewClosure()
    }.GetNewClosure()

    # Each deployed app in detail: the same two reads the audit always did
    # - metadata/groups/dependencies (SyncMetadata) and assignments the
    # catalog doesn't know about (BatchAssign in Preview) - side by side,
    # each a process of its own. Also what the grid's Last Audit column
    # shows, so it is written there too.
    $ctx.Stages.Details = {
        $run = $ctx.Run
        $names = $run.Names
        $apps = @(& $ctx.ScopeApps | Where-Object { $_.appId -and (-not $names -or $names -contains [string]$_.appName) })
        if ($apps.Count -eq 0) { & $ctx.Next; return }
        & $ctx.SetStatus "Reading $($apps.Count) deployed app(s) from Intune in detail - the slowest part..."
        $runNames = @($apps | ForEach-Object { [string]$_.appName })
        $run.Pending = 2
        $c = $ctx

        $runId = $ctx.Run.Id
        $detailDone = {
            if ($c.Run.Id -ne $runId) { return }
            $c.Run.Pending--
            if ($c.Run.Pending -gt 0) { return }
            try { Save-LastAuditCache } catch { $c.Run.Problems.Add("Last Audit: $($_.Exception.Message)") }
            $c.Changed = $true
            & $c.Next
        }.GetNewClosure()

        $startScript = {
            param([string]$Label, [string]$Script, $Config, [scriptblock]$OnResult)
            $configPath = Join-Path $env:TEMP (".intunepkg_checks_config_" + [guid]::NewGuid().ToString("N") + ".json")
            $resultPath = Join-Path $env:TEMP (".intunepkg_checks_result_" + [guid]::NewGuid().ToString("N") + ".json")
            $Config | Add-Member -NotePropertyName OutputResultPath -NotePropertyValue $resultPath -Force
            [System.IO.File]::WriteAllText($configPath, ($Config | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
            $cc = $c
            $labelRef = $Label
            $configPathRef = $configPath
            $resultPathRef = $resultPath
            $onResultRef = $OnResult
            $doneRef = $detailDone
            $runIdRef = $runId
            $cc.Run.Procs[$Label] = Start-PipelineProcess -ScriptContent $Script -TempScriptName ".intunepkg_embedded_checks_$($Label.ToLower()).ps1" `
                -ArgumentString "-ConfigPath `"$configPath`"" -ExtraLogTarget $cc.Log -OnComplete {
                param($code)
                $cc.Run.Procs.Remove($labelRef)
                Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue
                $result = $null
                $problem = $null
                if ($cc.Run.Stopped) { $problem = $null }
                elseif (-not (Test-Path $resultPathRef)) { $problem = "no result written (exit code $code)" }
                else {
                    try { $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json }
                    catch { $problem = "could not read the result: $($_.Exception.Message)" }
                    if ($result -and -not $result.success) { $problem = [string]$result.error; $result = $null }
                }
                Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                if (-not $cc.Dlg.IsDisposed -and -not $cc.Run.Stopped -and $cc.Run.Id -eq $runIdRef) {
                    try { & $onResultRef $result $problem }
                    catch { $cc.Run.Problems.Add("$($labelRef): $($_.Exception.Message)") }
                }
                & $doneRef
            }.GetNewClosure()
        }.GetNewClosure()

        $graphConfig = { [pscustomobject]@{ TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint } }

        # 1: metadata, groups, dependencies
        $config1 = & $graphConfig
        $config1 | Add-Member -NotePropertyName Apps -NotePropertyValue @($apps | ForEach-Object { [pscustomobject]@{ AppName = [string]$_.appName; AppId = [string]$_.appId } })
        $runNamesRef = $runNames
        try {
            & $startScript "Details" $Global:App.EmbeddedSyncMetadataScript $config1 {
                param($result, $problem)
                $areas = @("Metadata", "Groups", "Dependencies")
                if ($problem) {
                    $c.Run.Problems.Add("App details: $problem")
                    & $c.Replace -Areas $areas -Names $runNamesRef -New @($runNamesRef | ForEach-Object { New-CheckFinding -Area "Metadata" -App $_ -CatalogName $_ -Problem "Could not check: $problem" -Failed -Actions @("Recheck") })
                    return
                }
                $new = New-Object System.Collections.Generic.List[object]
                foreach ($one in @($result.results)) {
                    $catalogApp = @($c.Apps | Where-Object { [string]$_.appName -eq [string]$one.AppName }) | Select-Object -First 1
                    if (-not $catalogApp) { continue }
                    foreach ($f in @(Get-AppDetailFindings -CatalogApp $catalogApp -Result $one)) { $new.Add($f) }
                    $texts = Get-AuditSummaryTexts -CatalogApp $catalogApp -Result $one
                    Set-LastAuditCacheEntry -AppName ([string]$one.AppName) -Metadata $texts.Metadata -Groups $texts.Groups -Dependencies $texts.Dependencies
                }
                & $c.Replace -Areas $areas -Names $runNamesRef -New $new.ToArray()
            }.GetNewClosure()
        }
        catch {
            $c.Run.Problems.Add("App details: $($_.Exception.Message)")
            & $detailDone
        }

        # 2: assignments the catalog doesn't know about
        $config2 = & $graphConfig
        $config2 | Add-Member -NotePropertyName Mode -NotePropertyValue "Preview"
        $config2 | Add-Member -NotePropertyName Apps -NotePropertyValue @($apps | ForEach-Object {
            [pscustomobject]@{ AppName = [string]$_.appName; AppId = [string]$_.appId; RequiredGroups = @($_.requiredFor); AvailableGroups = @($_.availableFor); UninstallGroups = @($_.uninstallFor); ExcludeGroups = @($_.excludeFor) }
        })
        try {
            & $startScript "Assignments" $Global:App.EmbeddedBatchAssignScript $config2 {
                param($result, $problem)
                if ($problem) {
                    $c.Run.Problems.Add("Assignments: $problem")
                    & $c.Replace -Areas @("Unknown assignments") -Names $runNamesRef
                    return
                }
                $new = New-Object System.Collections.Generic.List[object]
                foreach ($one in @($result.data)) {
                    $catalogApp = @($c.Apps | Where-Object { [string]$_.appName -eq [string]$one.AppName }) | Select-Object -First 1
                    if (-not $catalogApp) { continue }
                    foreach ($f in @(Get-UnknownAssignmentFindings -CatalogApp $catalogApp -ToRemove @($one.ToRemove))) { $new.Add($f) }
                    Set-LastAuditCacheEntry -AppName ([string]$one.AppName) -Unknown (Get-UnknownAssignmentText @($one.ToRemove))
                }
                & $c.Replace -Areas @("Unknown assignments") -Names $runNamesRef -New $new.ToArray()
            }.GetNewClosure()
        }
        catch {
            $c.Run.Problems.Add("Assignments: $($_.Exception.Message)")
            & $detailDone
        }
    }.GetNewClosure()

    $ctx.Stages.Entra = {
        & $ctx.SetStatus "Reading Entra ID's groups..."
        $c = $ctx
        $runId = $ctx.Run.Id
        Start-EntraDirectoryLookup -LogBox $ctx.Log -OnComplete {
            param($ok, $msg)
            if ($c.Dlg.IsDisposed) { $c.Run.Active = $false; return }
            if ($c.Run.Id -ne $runId -or -not $c.Run.Active) { return }
            try {
                if (-not $ok) {
                    $c.Run.Problems.Add("Entra ID: $msg")
                    & $c.Replace -Areas @("Entra groups") -New @(New-CheckFinding -Area "Entra groups" -App "(Entra ID)" -Problem "Could not read Entra ID's groups: $msg" -Failed)
                }
                else {
                    $c.EntraRead = $true
                    & $c.Replace -Areas @("Entra groups") -Names @("")
                    & $c.RefreshLocal
                }
            }
            catch {
                $c.Run.Problems.Add("Entra ID: $($_.Exception.Message)")
                & $c.LogLine "[FAILED] Entra ID: $($_.Exception.Message)"
            }
            & $c.Next
        }.GetNewClosure()
    }.GetNewClosure()

    $ctx.Stages.Winget = {
        $names = $ctx.Run.Names
        $apps = @(& $ctx.ScopeApps | Where-Object { $_.wingetId -and (-not $names -or $names -contains [string]$_.appName) })
        if ($apps.Count -eq 0) { & $ctx.Next; return }
        & $ctx.SetStatus "Asking winget about $($apps.Count) Winget ID(s)..."
        $c = $ctx
        $runId = $ctx.Run.Id
        $results = New-Object System.Collections.Generic.List[object]
        $total = $apps.Count
        $ctx.Run.Winget = Start-WingetIdCheck -Apps @($apps | ForEach-Object { @{ AppName = $_.appName; WingetId = $_.wingetId } }) -OnResult {
            param($item)
            $results.Add($item)
            & $c.SetStatus "Asking winget: $($results.Count) of $total..."
        }.GetNewClosure() -OnComplete {
            param($ok, $errorText, $stopped)
            if ($c.Dlg.IsDisposed) { $c.Run.Active = $false; return }
            if ($c.Run.Id -ne $runId) { return }
            $c.Run.Winget = $null
            try {
                $checkedNames = @(@($results | ForEach-Object { [string]$_.AppName }) + @(""))
                & $c.Replace -Areas @("Winget ID") -Names $checkedNames -New (Get-WingetFindings -Results $results.ToArray() -Apps $c.Apps.ToArray())
                if (-not $ok -and -not $stopped) {
                    $c.Run.Problems.Add("winget: $errorText")
                    & $c.Replace -New @(New-CheckFinding -Area "Winget ID" -App "(winget)" -Problem "Could not ask winget: $errorText" -Failed)
                }
            }
            catch {
                $c.Run.Problems.Add("winget: $($_.Exception.Message)")
                & $c.LogLine "[FAILED] winget: $($_.Exception.Message)"
            }
            & $c.Next
        }.GetNewClosure()
    }.GetNewClosure()

    $ctx.Stop = {
        $run = $ctx.Run
        if (-not $run.Active) { return }
        $run.Stopped = $true
        $ctx.BtnStop.Enabled = $false
        & $ctx.SetStatus "Stopping..." "Warn"
        $waiting = $false
        foreach ($proc in @($run.Procs.Values)) { try { if ($proc -and -not $proc.HasExited) { $proc.Kill(); $waiting = $true } } catch { } }
        if ($run.Winget) { & $run.Winget.Stop; $waiting = $true }
        # Nothing in the background to report back (the Intune and Entra
        # reads can't be interrupted, and call back into a stopped run
        # harmlessly): finish now rather than wait on a callback - so Stop
        # always ends a run, even one a stage never handed on from.
        if (-not $waiting) { & $ctx.Finish }
    }.GetNewClosure()

    $btnRun.Add_Click({ & $ctx.Start }.GetNewClosure())
    $btnStop.Add_Click({ & $ctx.Stop }.GetNewClosure())

    # --- fixes ----------------------------------------------------------

    # After a fix that wrote the catalog: the main grid, the areas that
    # can be recomputed from what is in hand, and a fresh read of the apps
    # it touched where only Intune can say whether they match now.
    $ctx.AfterFix = {
        param([string[]]$RecheckNames)
        $ctx.Changed = $true
        Update-Grid
        & $ctx.RefreshLocal
        $names = @($RecheckNames | Where-Object { $_ })
        if ($names.Count -gt 0 -and -not $ctx.Run.Active) {
            & $ctx.Start $names @("Details")
        }
    }.GetNewClosure()

    $ctx.SaveCatalog = {
        $Global:App.UnsavedChangesBox.Value = $true
        return (Save-AppsToFile -Path $Global:App.LinkedFilePath)
    }.GetNewClosure()

    $ctx.Confirm = {
        param([string]$Question, [string]$Title, $Findings)
        $list = @($Findings | Select-Object -First 15 | ForEach-Object { "  - $($_.App)" })
        if (@($Findings).Count -gt 15) { $list += "  ...and $(@($Findings).Count - 15) more" }
        $r = [System.Windows.Forms.MessageBox]::Show("$Question`n`n$($list -join "`n")", $Title, "YesNo", "Question", "Button2")
        return ($r -eq "Yes")
    }.GetNewClosure()

    $ctx.CatalogIndices = {
        param($Findings)
        return @(@($Findings | ForEach-Object { [string]$_.CatalogName } | Where-Object { $_ } | Select-Object -Unique) | ForEach-Object { & $ctx.IndexOf $_ } | Where-Object { $_ -ge 0 })
    }.GetNewClosure()

    $ctx.Act = @{}

    $ctx.Act.Pull = {
        param($Findings)
        $indices = @(& $ctx.CatalogIndices $Findings)
        if ($indices.Count -eq 0) { return }
        # "Pull metadata and groups from Intune" - it shows what would
        # change and asks, field by field, before writing anything.
        Show-SyncMetadataDialog -ScopedIndices $indices
        & $ctx.AfterFix @($indices | ForEach-Object { [string]$ctx.Apps[$_].appName })
    }.GetNewClosure()

    $ctx.Act.PushMetadata = {
        param($Findings)
        $indices = @(& $ctx.CatalogIndices $Findings)
        if ($indices.Count -eq 0) { return }
        if ($indices.Count -eq 1) { Invoke-QuickPushMetadata -Index $indices[0] }
        else { Show-BatchPushMetadataDialog -ScopedIndices $indices }
        & $ctx.AfterFix @($indices | ForEach-Object { [string]$ctx.Apps[$_].appName })
    }.GetNewClosure()

    $ctx.Act.PushGroups = {
        param($Findings)
        $indices = @(& $ctx.CatalogIndices $Findings)
        if ($indices.Count -eq 0) { return }
        if ($indices.Count -eq 1) { Invoke-QuickAssignGroups -Index $indices[0] }
        else { Show-BatchAssignDialog -ScopedIndices $indices }
        & $ctx.AfterFix @($indices | ForEach-Object { [string]$ctx.Apps[$_].appName })
    }.GetNewClosure()

    $ctx.Act.RenameFromIntune = {
        param($Findings)
        if (-not (& $ctx.Confirm "Rename these catalog entries to the name they have in Intune now?" "Use Intune's name" $Findings)) { return }
        foreach ($f in $Findings) {
            $target = @($ctx.Apps | Where-Object { [string]$_.appId -eq [string]$f.AppId }) | Select-Object -First 1
            if ($target) { $target.appName = [string]$f.Data.IntuneName }
        }
        [void](& $ctx.SaveCatalog)
        & $ctx.AfterFix
    }.GetNewClosure()

    $ctx.Act.ClearAppId = {
        param($Findings)
        if (-not (& $ctx.Confirm "Intune no longer has an app with these App IDs. Clear them, so the catalog entries count as not deployed? The entries themselves stay." "Clear App ID" $Findings)) { return }
        foreach ($f in $Findings) {
            $target = @($ctx.Apps | Where-Object { [string]$_.appName -eq [string]$f.CatalogName }) | Select-Object -First 1
            if ($target) { $target.appId = "" }
        }
        [void](& $ctx.SaveCatalog)
        & $ctx.AfterFix
    }.GetNewClosure()

    $ctx.Act.SetAppId = {
        param($Findings)
        $list = @($Findings | Where-Object { $_.Data -and $_.Data.MatchedId })
        if ($list.Count -eq 0) { return }
        if (-not (& $ctx.Confirm "Record the App ID of the Intune app with the same name for each of these?" "Set App ID" $list)) { return }
        foreach ($f in $list) {
            $target = @($ctx.Apps | Where-Object { [string]$_.appName -eq [string]$f.CatalogName }) | Select-Object -First 1
            if ($target) { $target.appId = [string]$f.Data.MatchedId }
        }
        [void](& $ctx.SaveCatalog)
        & $ctx.AfterFix @($list | ForEach-Object { [string]$_.CatalogName })
    }.GetNewClosure()

    $ctx.Act.ChooseAppId = {
        param($Findings)
        $f = @($Findings)[0]
        $used = @{}
        foreach ($a in $ctx.Apps) { if ($a.appId) { $used[[string]$a.appId] = $true } }
        $items = @(@($Global:App.IntuneAppsCache) | Where-Object { $_ -and -not $used.ContainsKey([string]$_.id) } | Sort-Object displayName | ForEach-Object { "$($_.displayName)  [$($_.id)]" })
        if ($items.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("There are no Intune apps without a catalog entry to choose from. Run checks first if Intune hasn't been read yet.", "Choose App ID", "OK", "Information") | Out-Null
            return
        }
        $pick = Show-SimpleListPicker -Title "Choose App ID" -Prompt "Which Intune app is `"$($f.App)`"?" -Items $items
        if (-not $pick -or $pick -notmatch '\[([^\]]+)\]\s*$') { return }
        $target = @($ctx.Apps | Where-Object { [string]$_.appName -eq [string]$f.CatalogName }) | Select-Object -First 1
        if (-not $target) { return }
        $target.appId = $Matches[1]
        [void](& $ctx.SaveCatalog)
        & $ctx.AfterFix @([string]$f.CatalogName)
    }.GetNewClosure()

    $ctx.Act.EditApp = {
        param($Findings)
        $index = & $ctx.IndexOf ([string]@($Findings)[0].CatalogName)
        if ($index -lt 0) { return }
        Invoke-EditApp -Index $index
        & $ctx.AfterFix
    }.GetNewClosure()

    $ctx.Act.FindWingetId = {
        param($Findings)
        $f = @($Findings)[0]
        $picked = Show-WingetSearchDialog -InitialQuery ([string]$f.App)
        if (-not $picked) { return }
        $target = @($ctx.Apps | Where-Object { [string]$_.appName -eq [string]$f.CatalogName }) | Select-Object -First 1
        if (-not $target) { return }
        $target.wingetId = [string]$picked
        [void](& $ctx.SaveCatalog)
        & $ctx.LogLine "[OK] $($f.App): Winget ID changed to $picked."
        & $ctx.Replace -Key $f.Key
        & $ctx.AfterFix
        if (-not $ctx.Run.Active) { & $ctx.Start @([string]$f.CatalogName) @("Winget") }
    }.GetNewClosure()

    $ctx.Act.Recheck = {
        param($Findings)
        $names = @($Findings | ForEach-Object { [string]$_.CatalogName } | Where-Object { $_ } | Select-Object -Unique)
        if ($names.Count -eq 0) { & $ctx.Start; return }
        $stages = New-Object System.Collections.Generic.List[string]
        $stages.Add("Local")
        if (@($Findings | Where-Object { $_.Area -in @("Metadata", "Groups", "Dependencies", "Unknown assignments") }).Count -gt 0) { $stages.Add("Details") }
        if (@($Findings | Where-Object { $_.Area -eq "Winget ID" }).Count -gt 0) { $stages.Add("Winget") }
        if (@($Findings | Where-Object { $_.Area -eq "Intune link" }).Count -gt 0) { $stages.Add("IntuneApps") }
        if (@($Findings | Where-Object { $_.Area -eq "Entra groups" }).Count -gt 0) { $stages.Add("Entra") }
        & $ctx.Start $names $stages.ToArray()
    }.GetNewClosure()

    # Add to catalog: one app is read from Intune and opened in the editor
    # to look over before it is added; several are read and added in one go.
    $ctx.Act.AddToCatalog = {
        param($Findings)
        $list = @($Findings)
        if ($list.Count -eq 1) {
            $f = $list[0]
            & $ctx.SetStatus "Reading `"$($f.App)`" from Intune..."
            $ctx.Dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $c = $ctx
            $fRef = $f
            Start-AppMetadataFetch -AppId ([string]$f.AppId) -LogBox $ctx.Log -OnComplete {
                param($ok, $errMsg, $data)
                if ($c.Dlg.IsDisposed) { return }
                $c.Dlg.Cursor = [System.Windows.Forms.Cursors]::Default
                $entry = ConvertTo-CatalogEntryFromFetch -Id ([string]$fRef.AppId) -Name ([string]$fRef.App) -Ok ([bool]$ok) -Data $data
                if (-not $ok) { & $c.SetStatus "Could not read it from Intune ($errMsg) - opening with what is known." "Warn" }
                elseif (-not $entry.GroupsKnown) { & $c.SetStatus "Its group assignments couldn't be read - opening with blank groups." "Warn" }
                else { & $c.SetStatus "" }
                $entry.PSObject.Properties.Remove('GroupsKnown')
                $editorResult = Show-AppEditor -ExistingApp $entry
                if ($editorResult -and $editorResult.App) {
                    [void]$c.Apps.Add($editorResult.App)
                    [void](& $c.SaveCatalog)
                    & $c.AfterFix
                }
            }.GetNewClosure()
            return
        }
        if (-not (& $ctx.Confirm "Add these $($list.Count) apps from Intune to the catalog? Each one's metadata and groups are read from Intune first." "Add to catalog" $list)) { return }
        $queue = New-Object System.Collections.Generic.Queue[object]
        foreach ($f in $list) { $queue.Enqueue($f) }
        $state = @{ Added = 0; GroupsUnknown = 0; Total = $list.Count }
        $ctx.BtnRun.Enabled = $false
        $ctx.Prg.Visible = $true
        $c = $ctx
        $addNext = @{ Run = $null }
        $addNext.Run = {
            if ($c.Dlg.IsDisposed) { return }
            if ($queue.Count -eq 0) {
                [void](& $c.SaveCatalog)
                $c.Prg.Visible = $false
                $c.BtnRun.Enabled = $true
                & $c.SetStatus "Added $($state.Added) of $($state.Total) app(s) to the catalog$(if ($state.GroupsUnknown -gt 0) { " - $($state.GroupsUnknown) with groups that couldn't be read (left blank)" })." $(if ($state.GroupsUnknown -gt 0) { "Warn" } else { "Good" })
                & $c.AfterFix
                return
            }
            $f = $queue.Dequeue()
            & $c.SetStatus "Adding $($state.Total - $queue.Count) of $($state.Total): $($f.App)..."
            # Locals, for the callback built here inside this closure -
            # it only captures what is local at this point.
            $fRef = $f
            $cRef = $c
            $stateRef = $state
            $addNextRef = $addNext
            Start-AppMetadataFetch -AppId ([string]$f.AppId) -LogBox $c.Log -OnComplete {
                param($ok, $errMsg, $data)
                if ($cRef.Dlg.IsDisposed) { return }
                $entry = ConvertTo-CatalogEntryFromFetch -Id ([string]$fRef.AppId) -Name ([string]$fRef.App) -Ok ([bool]$ok) -Data $data
                if (-not $entry.GroupsKnown) { $stateRef.GroupsUnknown++ }
                $entry.PSObject.Properties.Remove('GroupsKnown')
                [void]$cRef.Apps.Add($entry)
                $stateRef.Added++
                & $addNextRef.Run
            }.GetNewClosure()
        }.GetNewClosure()
        & $addNext.Run
    }.GetNewClosure()

    # What each fix is called, and whether it works on several rows at once.
    $actionSpecs = @(
        @{ Key = "Pull";             Text = "Pull from Intune...";  Multi = $true;  Tip = "Intune is right: take its metadata and groups into the catalog. Shows what would change and asks first." }
        @{ Key = "PushMetadata";     Text = "Push metadata...";     Multi = $true;  Tip = "The catalog is right about metadata or dependencies: send it to Intune. Nothing is sent until you confirm there." }
        @{ Key = "PushGroups";       Text = "Push groups...";       Multi = $true;  Tip = "The catalog is right about groups: send them to Intune. Fixes Groups and Unknown assignments." }
        @{ Key = "AddToCatalog";     Text = "Add to catalog...";    Multi = $true;  Tip = "Adds the Intune app to the catalog with its metadata and groups. One app opens in the editor first." }
        @{ Key = "SetAppId";         Text = "Set App ID";           Multi = $true;  Tip = "Records the App ID of the Intune app with the same name." }
        @{ Key = "ChooseAppId";      Text = "Choose App ID...";     Multi = $false; Tip = "Pick which Intune app this catalog entry is." }
        @{ Key = "RenameFromIntune"; Text = "Use Intune's name";    Multi = $true;  Tip = "Renames the catalog entry to the name the app has in Intune now." }
        @{ Key = "ClearAppId";       Text = "Clear App ID";         Multi = $true;  Tip = "Forgets an App ID Intune no longer has. The catalog entry stays, as not deployed." }
        @{ Key = "EditApp";          Text = "Open app...";          Multi = $false; Tip = "Opens the app in the editor." }
        @{ Key = "FindWingetId";     Text = "Find Winget ID...";    Multi = $false; Tip = "Searches winget for the package's current ID and uses the one you pick." }
        @{ Key = "Recheck";          Text = "Re-check";             Multi = $true;  Tip = "Checks the selected apps again." }
    )

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select all"
    $btnSelectAll.AutoSize = $true
    $btnSelectAll.MinimumSize = New-Object System.Drawing.Size(90,30)
    $pnlFix.Controls.Add($btnSelectAll)
    $tips.SetToolTip($btnSelectAll, "Selects every row the list is showing.")
    $btnSelectAll.Add_Click({
        $ctx.SelectingAll = $true
        try { foreach ($row in $ctx.Grid.Rows) { $row.Selected = $true } }
        finally { $ctx.SelectingAll = $false }
        & $ctx.UpdateButtons
    }.GetNewClosure())

    foreach ($spec in $actionSpecs) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $spec.Text
        $btn.AutoSize = $true
        $btn.MinimumSize = New-Object System.Drawing.Size(90,30)
        $btn.Visible = $false
        $pnlFix.Controls.Add($btn)
        $tips.SetToolTip($btn, $spec.Tip)
        $keyRef = $spec.Key
        $multiRef = $spec.Multi
        $btn.Add_Click({
            $chosen = @(& $ctx.SelectedFindings | Where-Object { $_.Actions -contains $keyRef })
            if ($chosen.Count -eq 0) { return }
            if (-not $multiRef) { $chosen = @($chosen[0]) }
            & $ctx.Act[$keyRef] $chosen
        }.GetNewClosure())
        $ctx.ActionButtons[$spec.Key] = @{ Button = $btn; Multi = $spec.Multi; Text = $spec.Text }
    }

    $ctx.UpdateButtons = {
        if ($ctx.SelectingAll -or $ctx.Dlg.IsDisposed) { return }
        $selected = @(& $ctx.SelectedFindings)
        $busy = $ctx.Run.Active
        $any = $false
        foreach ($key in $ctx.ActionButtons.Keys) {
            $entry = $ctx.ActionButtons[$key]
            $n = @($selected | Where-Object { $_.Actions -contains $key }).Count
            $show = $n -gt 0 -and ($entry.Multi -or $selected.Count -eq 1)
            $entry.Button.Visible = $show
            $entry.Button.Enabled = $show -and -not $busy
            $entry.Button.Text = if ($show -and $entry.Multi -and $n -gt 1) { "$($entry.Text) ($n)" } else { $entry.Text }
            if ($show) { $any = $true }
        }
        $ctx.Hint.Text = if ($busy) { "Checking - the fixes are available again when it has finished." }
            elseif ($selected.Count -gt 0 -and -not $any) { "Nothing to fix from here for what is selected - double-click a row for the details." }
            elseif ($selected.Count -gt 0) { "$($selected.Count) selected. Pull if Intune is right, Push if the catalog is." }
            elseif ($ctx.Grid.Rows.Count -gt 0) { "Select one or more rows to see what can be done about them. Double-click a row for the full details." }
            else { "" }
    }.GetNewClosure()

    $grid.Add_SelectionChanged({ & $ctx.UpdateButtons }.GetNewClosure())
    $cmbShow.Add_SelectedIndexChanged({
        if ($ctx.Rendering) { return }
        $ctx.ShowFilter = ([string]$ctx.CmbShow.SelectedItem) -replace ' \(\d+\)$', ''
        & $ctx.Render
    }.GetNewClosure())

    # Right-click: the same fixes, for the row under the mouse.
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Add_Opening({
        param($s, $e)
        $menu.Items.Clear()
        foreach ($key in $ctx.ActionButtons.Keys) {
            $entry = $ctx.ActionButtons[$key]
            if (-not $entry.Button.Visible) { continue }
            $item = New-Object System.Windows.Forms.ToolStripMenuItem $entry.Button.Text
            $item.Enabled = $entry.Button.Enabled
            $btnRef = $entry.Button
            $item.Add_Click({ $btnRef.PerformClick() }.GetNewClosure())
            [void]$menu.Items.Add($item)
        }
        if ($menu.Items.Count -eq 0) { $e.Cancel = $true }
    }.GetNewClosure())
    $grid.ContextMenuStrip = $menu
    $grid.Add_CellMouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right -or $e.RowIndex -lt 0) { return }
        $clicked = $ctx.Grid.Rows[$e.RowIndex]
        if (-not $clicked.Selected) { $ctx.Grid.ClearSelection(); $clicked.Selected = $true }
    }.GetNewClosure())

    $grid.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $f = $ctx.Grid.Rows[$e.RowIndex].Tag
        if (-not $f) { return }
        $lines = @(
            "Area: $($f.Area)"
            "Problem: $($f.Problem)"
            ""
            "Catalog:"
            "  $(([string]$f.Catalog) -replace '; ', "`r`n  ")"
            ""
            "Intune / other side:"
            "  $(([string]$f.Intune) -replace '; ', "`r`n  ")"
        )
        [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), "Checks - $($f.App)", "OK", "Information") | Out-Null
    }.GetNewClosure())

    $ctx.ItalicFont = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Italic)
    $dlg.Add_Disposed({ $ctx.ItalicFont.Dispose() }.GetNewClosure())

    # Closing mid-run asks first, then stops it - the background reads
    # check for a closed window, but a half-finished run is worth a word.
    $dlg.Add_FormClosing({
        param($s, $e)
        if (-not $ctx.Run.Active) { return }
        $r = [System.Windows.Forms.MessageBox]::Show("A check is still running. Stop it and close?", "Checks", "YesNo", "Question", "Button2")
        if ($r -ne "Yes") { $e.Cancel = $true; return }
        & $ctx.Stop
    }.GetNewClosure())

    # --- opening ----------------------------------------------------------

    # What is already known, so the window opens on something useful
    # rather than an empty list: the last audit's results, the catalog's
    # own dependencies, and - if Intune's app list was read earlier this
    # session - how the catalog lines up with it. All marked as earlier.
    $onlyNames = if ($isScoped) { @($scopeNames) } else { $null }
    foreach ($f in @(Get-CachedAuditFindings -Apps $appsRef.ToArray() -LastAuditResults $Global:App.LastAuditResults -OnlyNames $onlyNames)) { $ctx.Findings.Add($f) }
    & $ctx.RefreshLocal

    # The old tab names still pick what the list shows first.
    $ctx.ShowFilter = switch -Wildcard ([string]$StartTab) {
        "*Sync check*"    { "Intune link" }
        "*App IDs*"       { "Intune link" }
        "*Metadata*"      { "Metadata" }
        "*Dependencies*"  { "Catalog dependencies" }
        "*groups*"        { "Entra groups" }
        "*Winget*"        { "Winget ID" }
        default           { "All areas" }
    }
    & $ctx.Render
    & $ctx.SetStatus $(if ($ctx.Findings.ToArray().Count -gt 0) { "Showing what is already known - rows in italics are from earlier checks. Run checks to check everything now." } else { "Not checked yet - press Run checks." })

    if ($AutoRun) { $dlg.Add_Shown({ & $ctx.Start }.GetNewClosure()) }

    Set-Theme -Control $dlg
    $pnlStatus.BackColor = $Global:App.LightPalette.FieldBack
    [void]$dlg.ShowDialog($Global:App.Form)
    if ($ctx.Changed) { Update-Grid }
    return [bool]$ctx.Changed
}
