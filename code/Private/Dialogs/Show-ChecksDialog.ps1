function Global:Show-ChecksDialog {
    <#
      Everything this app can check about itself and the catalog, in one
      window.

      They were four: dependencies between catalog apps, catalog groups
      against Entra ID, Winget IDs against winget, and the app's own
      diagnostics. Four menu entries under "Verify", four windows, and no
      way to tell from the outside which of them answers the question you
      actually have - the menu already grouped them for that reason
      ("someone looking for 'check X' shouldn't need to already know
      whether X lives under Catalog/Intune/Entra ID to find it"). Tabs are
      that same grouping, one step further.

      Each tab is still its own dialog, unchanged, moved onto a page - see
      Move-DialogToTabPage, and Show-IntuneCheckDialog, which did this
      first for the three Intune checks.

      Unlike those three, these four share no fetch, and two of them cost
      real time (one reads every catalog group out of Entra ID, one shells
      out to winget per app). So a tab's check runs when that tab is first
      opened, never all four when the window opens - a page hands its
      work to this host as $Page.Tag.OnFirstShow, and says when it must
      not be interrupted as $Page.Tag.BlockClose.
    #>

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Checks"
    # Fits the largest tab (the dependency overview, 820x540) with room for
    # the tab strip and the button row, and still fits a 1024x768 screen.
    $dlg.ClientSize = New-Object System.Drawing.Size(880, 640)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(700, 520)
    $dlg.MaximizeBox = $true
    $dlg.MinimizeBox = $false

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(15,12)
    $tabs.Size = New-Object System.Drawing.Size(850, 576)
    $tabs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor
                   [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $dlg.Controls.Add($tabs)

    $lblRunAll = New-Object System.Windows.Forms.Label
    $lblRunAll.Location = New-Object System.Drawing.Point(180,602)
    $lblRunAll.Size = New-Object System.Drawing.Size(430,22)
    $lblRunAll.ForeColor = [System.Drawing.Color]::DimGray
    $lblRunAll.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $dlg.Controls.Add($lblRunAll)

    $btnRunAll = New-Object System.Windows.Forms.Button
    $btnRunAll.Text = "Run all checks"
    $btnRunAll.Size = New-Object System.Drawing.Size(150,30)
    $btnRunAll.Location = New-Object System.Drawing.Point(15,598)
    $btnRunAll.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $dlg.Controls.Add($btnRunAll)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Size = New-Object System.Drawing.Size(90,30)
    $btnClose.Location = New-Object System.Drawing.Point(775,598)
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnClose)
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    # Enter dismisses the window. Every check on the tabs inside is
    # read-only - none of them changes the catalog or Intune.
    $dlg.AcceptButton = $btnClose

    # Catalog first, then the two outside systems it is checked against,
    # then the app's own plumbing - narrowest question to widest.
    foreach ($spec in @(
        @{ Title = 'Dependencies';    Build = { param($page) Show-DependencyOverviewDialog -HostTabPage $page -HostForm $dlg } }
        @{ Title = 'Catalog groups';  Build = { param($page) Show-GroupDriftCheckDialog -HostTabPage $page -HostForm $dlg } }
        @{ Title = 'Winget packages'; Build = { param($page) Show-WingetHealthCheckDialog -HostTabPage $page -HostForm $dlg } }
        @{ Title = 'Diagnostics';     Build = { param($page) Show-DiagnosticsDialog -HostTabPage $page -HostForm $dlg } }
    )) {
        $page = New-Object System.Windows.Forms.TabPage
        $page.Text = [string]$spec.Title
        $page.UseVisualStyleBackColor = $true
        [void]$tabs.TabPages.Add($page)
        # One tab failing to build must not take the other three with it -
        # each is a separate dialog with its own reasons to give up (an
        # empty catalog, no Winget IDs to check, no winget on the box).
        try { & $spec.Build $page }
        catch {
            $lblFailed = New-Object System.Windows.Forms.Label
            $lblFailed.Text = "This check couldn't be opened: $($_.Exception.Message)"
            $lblFailed.Location = New-Object System.Drawing.Point(15,15)
            $lblFailed.Size = New-Object System.Drawing.Size(600,60)
            $lblFailed.ForeColor = [System.Drawing.Color]::Firebrick
            $page.Controls.Add($lblFailed)
        }
    }

    # Each page's check runs once, the first time that page is looked at.
    # Keyed on the page object itself rather than an index, so reordering
    # the tabs above can't quietly re-run one or skip another.
    $alreadyRun = @{}
    $runPage = {
        param($page)
        if (-not $page) { return }
        $tag = $page.Tag
        if ($tag -isnot [hashtable] -or -not $tag.OnFirstShow) { return }
        if ($alreadyRun.ContainsKey($page)) { return }
        $alreadyRun[$page] = $true
        & $tag.OnFirstShow
    }.GetNewClosure()
    $tabs.Add_SelectedIndexChanged({ & $runPage $tabs.SelectedTab }.GetNewClosure())
    $dlg.Add_Shown({
        # Each tab's content takes the height its own dialog's hidden
        # button row used to have. Done here rather than while building,
        # because before the window is shown a page reports a height of
        # about 100 and every control on it reports Visible = $false - so
        # "how tall is the page" and "is anything below me" both answer
        # wrongly. A page says which control is its content (Tag.Fill);
        # nothing is guessed from geometry.
        foreach ($page in $tabs.TabPages) {
            $tag = $page.Tag
            if ($tag -is [hashtable] -and $tag.Fill) { Expand-HostedContent -Control $tag.Fill -Page $page -StopAbove $tag.FillStopAbove }
        }
        & $runPage $tabs.SelectedTab
    }.GetNewClosure())

    # "Run all checks" - one click for the whole window, for when the
    # question is "is anything wrong?" rather than one specific check.
    #
    # Strictly one at a time, never in parallel, and not because it was
    # easier: Start-EntraDirectoryLookup refuses a second concurrent
    # lookup outright (GraphFetch.ps1 - "A lookup is already running"),
    # and both the Catalog groups and Diagnostics tabs want it. Firing
    # them together would not be faster, it would report a failure that
    # isn't real. So a pump: start one, wait for every tab to go idle,
    # start the next.
    $pending = New-Object System.Collections.Generic.Queue[object]
    $pump = New-Object System.Windows.Forms.Timer
    $pump.Interval = 400
    $isAnyBusy = {
        foreach ($page in $tabs.TabPages) {
            $tag = $page.Tag
            if ($tag -is [hashtable] -and $tag.IsBusy -and (& $tag.IsBusy)) { return $true }
        }
        return $false
    }.GetNewClosure()
    $pump.Add_Tick({
        if (& $isAnyBusy) { return }
        if ($pending.Count -eq 0) {
            $pump.Stop()
            $btnRunAll.Enabled = $true
            $lblRunAll.Text = "All checks finished - each tab has its own result."
            return
        }
        $next = $pending.Dequeue()
        $alreadyRun[$next] = $true
        # Selected as it runs, so the window shows what it is working on
        # instead of a progress claim the user has to take on trust.
        $tabs.SelectedTab = $next
        $lblRunAll.Text = "Running: $($next.Text) ($($pending.Count) left after this one)"
        $tag = $next.Tag
        if ($tag -is [hashtable] -and $tag.OnFirstShow) { & $tag.OnFirstShow }
    }.GetNewClosure())
    $btnRunAll.Add_Click({
        if ($pump.Enabled) { return }
        $pending.Clear()
        foreach ($page in $tabs.TabPages) {
            # Tabs with no work to start (the dependency overview builds
            # its content as it opens) are simply already done.
            $tag = $page.Tag
            if ($tag -is [hashtable] -and $tag.OnFirstShow) { $pending.Enqueue($page) }
        }
        if ($pending.Count -eq 0) { return }
        $btnRunAll.Enabled = $false
        $lblRunAll.ForeColor = [System.Drawing.Color]::DimGray
        $lblRunAll.Text = "Starting $($pending.Count) checks, one at a time..."
        $pump.Start()
    }.GetNewClosure())

    # A tab that is mid-check keeps the window open, the same way each of
    # these dialogs used to keep itself open: their timers are still
    # ticking against controls that closing would dispose. Silent, like the
    # guards it replaces - the disabled buttons on the tab already say a
    # check is running.
    $dlg.Add_FormClosing({
        param($s, $e)
        foreach ($page in $tabs.TabPages) {
            $tag = $page.Tag
            if ($tag -is [hashtable] -and $tag.BlockClose -and (& $tag.BlockClose)) {
                $e.Cancel = $true
                return
            }
        }
    }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
    # The pump outlives the window otherwise - a stopped timer that still
    # holds this window's controls is the same leak the tabs' own timers
    # were fixed for.
    $pump.Stop()
    $pump.Dispose()
    $dlg.Dispose()
}
