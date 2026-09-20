function Global:Show-ChecksDialog {
    <#
      Everything this app can check about itself and the catalog, in one
      window.

      They were seven, in two windows and four menu entries, and three of
      them could also be reached from a toolbar button or the grid's
      right-click menu. Nothing said from the outside which one answers
      the question you actually have.

      Seven tabs now, in two groups. "Intune:" for the three that ask the
      tenant - App IDs, Audit, Metadata sync - then the four that look at
      what is on this machine: dependencies between catalog apps, catalog
      groups against Entra ID, Winget IDs against winget, and this app's
      own diagnostics.

      The three Intune tabs stay first and stay together because they
      share one read of every app in the tenant. That shared fetch is why
      they were a window of their own (Check against Intune, now gone),
      and it survives by building them together in this order, as that
      window did.

      The other four cost real time each (one reads every catalog group
      out of Entra ID, one shells out to winget per app), so those run
      when their tab is first opened - a page hands its work to this host
      as $Page.Tag.OnFirstShow, says when it must not be interrupted as
      $Page.Tag.BlockClose, and names its content control as $Page.Tag.Fill.

      Each tab is still its own dialog, unchanged, moved onto a page - see
      Move-DialogToTabPage.

      -ScopedIndices narrows Audit and Metadata sync to selected catalog
      rows, the way the grid's right-click menu asks for them.
      -StartTab opens on a particular tab, so "Run audit..." on a row
      still lands where it used to.
    #>

    param([int[]]$ScopedIndices = @(), [string]$StartTab)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Checks"
    # Sized for the widest tab, which is App IDs: it lists every app in the
    # tenant beside every app in the catalog, and that was a 1320px window
    # of its own before it moved in here. 8px margins for the same reason
    # that window used them - at 1024x768 this is shrunk to fit, and the
    # tabs need every pixel of what is left.
    $dlg.ClientSize = New-Object System.Drawing.Size(1320, 700)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(900, 560)
    $dlg.MaximizeBox = $true
    $dlg.MinimizeBox = $false

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(8,8)
    $tabs.Size = New-Object System.Drawing.Size(1304, 640)
    $tabs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor
                   [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $dlg.Controls.Add($tabs)

    $lblRunAll = New-Object System.Windows.Forms.Label
    $lblRunAll.Location = New-Object System.Drawing.Point(175,662)
    $lblRunAll.Size = New-Object System.Drawing.Size(1037,22)
    $lblRunAll.ForeColor = [System.Drawing.Color]::DimGray
    # Anchored on both sides: left only, it kept its full width when the
    # window was shrunk to fit a small screen and ran out over Close.
    $lblRunAll.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($lblRunAll)

    $btnRunAll = New-Object System.Windows.Forms.Button
    $btnRunAll.Text = "Run all checks"
    $btnRunAll.Size = New-Object System.Drawing.Size(150,30)
    $btnRunAll.Location = New-Object System.Drawing.Point(8,658)
    $btnRunAll.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $dlg.Controls.Add($btnRunAll)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Size = New-Object System.Drawing.Size(90,30)
    $btnClose.Location = New-Object System.Drawing.Point(1222,658)
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnClose)
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    # A tab that changed the catalog says so with Tag.Changed, and the main
    # grid is refreshed once here rather than by each tab reaching across
    # into it from inside a nested closure.
    $dlg.Add_FormClosed({
        foreach ($page in $tabs.TabPages) {
            $tag = $page.Tag
            if ($tag -is [hashtable] -and $tag.Changed -and $tag.Changed.Value) { Update-Grid; break }
        }
    }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    # No AcceptButton. It used to be Close, on the grounds that every tab
    # in here was read-only - which stopped being true before this window
    # did: Metadata sync's "Sync selected" writes the catalog, App IDs
    # applies matched IDs, and Sync check adds apps to the catalog and
    # clears stale App IDs. Enter-to-dismiss is fine on a window that only
    # reports; on one with per-row action buttons it is a way to lose your
    # place mid-fix. Esc still closes.

    # Grouped by what a check talks to, and named so the tab strip says
    # which group it is in. The three "Intune:" tabs go first because they
    # share one read of every app in the tenant - that shared fetch is why
    # they were a window of their own, and it is kept by building them
    # together, in this order, exactly as that window did. The four after
    # them each stand alone and cost nothing until opened.
    foreach ($spec in @(
        @{ Title = 'Intune: App IDs';       Build = { param($page) Show-AppIdMatchDialog -HostTabPage $page -HostForm $dlg } }
        @{ Title = 'Intune: Audit';         Build = { param($page) Show-IntuneAuditDialog -ScopedIndices $ScopedIndices -HostTabPage $page -HostForm $dlg } }
        @{ Title = 'Intune: Metadata sync'; Build = { param($page) Show-SyncMetadataDialog -ScopedIndices $ScopedIndices -HostTabPage $page -HostForm $dlg } }
        @{ Title = 'Intune: Sync check';    Build = { param($page) Show-IntuneOnlyAppsDialog -HostTabPage $page -HostForm $dlg } }
        @{ Title = 'Dependencies';    Build = { param($page) Show-DependencyOverviewDialog -HostTabPage $page -HostForm $dlg } }
        @{ Title = 'Catalog groups';  Build = { param($page) Show-GroupDriftCheckDialog -HostTabPage $page -HostForm $dlg } }
        @{ Title = 'Winget packages'; Build = { param($page) Show-WingetHealthCheckDialog -HostTabPage $page -HostForm $dlg } }
        @{ Title = 'Diagnostics';     Build = { param($page) Show-DiagnosticsDialog -HostTabPage $page -HostForm $dlg } }
    )) {
        $page = New-Object System.Windows.Forms.TabPage
        $page.Text = [string]$spec.Title
        $page.UseVisualStyleBackColor = $true
        [void]$tabs.TabPages.Add($page)
        # One tab failing to build must not take the others with it -
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
    # Asked for a particular tab - "Run audit..." on a grid row still lands
    # on Audit. Matched on the part after the group prefix as well as the
    # whole title, so a caller can say 'Audit' without knowing it is filed
    # under "Intune:".
    if ($StartTab) {
        foreach ($page in $tabs.TabPages) {
            $bare = ($page.Text -replace '^[^:]+:\s*', '')
            if ($page.Text -eq $StartTab -or $bare -eq $StartTab) { $tabs.SelectedTab = $page; break }
        }
    }
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
