function Global:Get-AppUiFont {
    # The one UI font every window uses. Set explicitly on each Form right
    # after it's created (before any child control exists), because the
    # WinForms default differs by host: PowerShell 7 (.NET) defaults to
    # Segoe UI 9, Windows PowerShell 5.1 (.NET Framework) to Microsoft Sans
    # Serif 8.25 - so a dialog without its own Font rendered noticeably
    # smaller, differently-shaped text on 5.1 in layouts sized for Segoe UI.
    # Segoe UI ships with every supported Windows version.
    if (-not $script:AppUiFont) { $script:AppUiFont = New-Object System.Drawing.Font("Segoe UI", 9) }
    return $script:AppUiFont
}

function Global:Get-GraphPermissionHint {
    <#
      Which application permission a refused request most likely needs.
      "Forbidden" on its own never says which one.

      Graph often names the scopes in the response body ("Application must
      have one of the following scopes: X, Y"), and what it says beats
      anything worked out from the address, so that is read first. The
      address is the fallback for a refusal that explains nothing. $null
      when the text names no endpoint this app knows.
    #>
    param([string]$Text)
    if (-not $Text) { return $null }
    if ($Text -match '(?:following scopes|scopes required|requires the scopes?)\s*:?\s*([A-Za-z0-9_.]+(?:\.All)?(?:\s*,\s*[A-Za-z0-9_.]+)*)') {
        $named = @($Matches[1] -split '\s*,\s*' | Where-Object { $_ -match '\.' } | Select-Object -Unique)
        if ($named.Count) { return "$($named -join ' or ') (application)" }
    }
    if ($Text -match 'deviceManagementScripts|deviceHealthScripts') { return "DeviceManagementScripts.ReadWrite.All (application)" }
    if ($Text -match 'deviceManagement/reports')                    { return "DeviceManagementApps.Read.All (application)" }
    if ($Text -match 'deviceAppManagement|mobileApps')              { return "DeviceManagementApps.ReadWrite.All (application)" }
    if ($Text -match 'graph\.microsoft\.com/(v1\.0|beta)/(groups|users|directoryObjects)') { return "Group.Read.All and Directory.Read.All (application)" }
    if ($Text -match 'deviceManagement')                            { return "DeviceManagementConfiguration.ReadWrite.All (application)" }
    return $null
}

function Global:ConvertTo-FriendlyGraphError {
    # Recognizes a handful of common, recurring Connect-MgGraph/Graph SDK
    # failure shapes and puts the actual takeaway first, in plain words -
    # the raw exception (confirmed live: "ClientCertificateCredential
    # authentication failed: [At line:35 char:16 + ... ]") reads like an
    # internal parse error to anyone who isn't already familiar with this
    # app's own runspace plumbing, and gives no hint the real fix is back
    # in Settings. The original text is always kept, appended below the
    # plain-language summary, so a genuinely unfamiliar failure is still
    # fully diagnosable - this only adds context, never hides detail.
    param([string]$RawMessage)
    if (-not $RawMessage) { return $RawMessage }
    # Idempotent: a fetch converts its own message, and the dialog showing it
    # converts again. Without this the second pass wraps the first one's
    # summary and the reader gets the same sentence twice, nested.
    if ($RawMessage -like '*(Raw error:*') { return $RawMessage }
    $summary = $null
    if ($RawMessage -match 'ClientCertificateCredential authentication failed|Cannot find the certificate|certificate.*not found|No certificate found') {
        $summary = "Could not sign in with the configured certificate - it may have been replaced, expired, or removed from this machine since Settings was last saved. Open Settings, Test connection, and Save once it succeeds."
    }
    elseif ($RawMessage -match 'AADSTS700027|invalid_client|AADSTS70021') {
        $summary = "Microsoft Entra ID rejected this app's credentials. Double-check the Tenant ID, Client ID, and certificate in Settings."
    }
    elseif ($RawMessage -match '\bunauthorized\b|\b401\b') {
        $summary = "Microsoft Graph rejected this request as unauthorized - the configured credentials may be stale. Try Settings > Test connection."
    }
    elseif ($RawMessage -match '\bforbidden\b|\b403\b|insufficient privileges|Authorization_RequestDenied') {
        $permission = Get-GraphPermissionHint $RawMessage
        $summary = if ($permission) {
            "Microsoft Graph refused this request: the app registration is missing a permission. Add $permission to it and grant admin consent, then try again (Settings > First time? Setup guide... walks through it)."
        } else {
            "Microsoft Graph refused this request - the app registration is likely missing a required permission (see Settings > First time? Setup guide...)."
        }
    }
    if (-not $summary) { return $RawMessage }
    return "$summary`n`n(Raw error: $RawMessage)"
}

function Global:Move-DialogToTabPage {
    <#
      Moves a whole dialog's contents onto a tab page, so a window that was
      built to stand alone can be one tab of a bigger one. Positions are
      kept: each of these dialogs already lays out from its own top-left,
      which is exactly where a page starts too.

      The dialog object stays alive and unshown - its handlers refer to
      controls by variable, so they neither know nor care that the controls
      now live somewhere else.
    #>
    param([System.Windows.Forms.Form]$Dialog, [System.Windows.Forms.TabPage]$Page)
    # The width the dialog was laid out for, read before anything moves.
    # Every decision below is "how did this control relate to its own
    # dialog's edges?", which is only answerable while it still has them.
    $originalWidth = $Dialog.ClientSize.Width
    $originalHeight = $Dialog.ClientSize.Height

    $inner = New-Object System.Windows.Forms.Panel
    $inner.Dock = [System.Windows.Forms.DockStyle]::Fill
    $inner.AutoScroll = $true
    $Page.Controls.Add($inner)
    foreach ($control in @($Dialog.Controls)) {
        $Dialog.Controls.Remove($control)
        $inner.Controls.Add($control)
    }

    # A tab page is wider than the dialog that used to hold these controls -
    # and wider again when the window is resized or maximized. Left as they
    # were, a 700px-wide text box sits in an 864px page with dead space
    # down the right, which is what makes an embedded dialog look like it
    # was dropped into a window rather than built for one.
    #
    # Nothing is repositioned here; the controls only learn which edges
    # they belong to:
    #   - something that spanned its dialog's width (a text box, a log, a
    #     grid, a full-width label) is anchored to BOTH sides, so it grows
    #     with the page - this is the one that actually shows
    #   - something small that sat at the right edge (a button) is anchored
    #     to the right only, so it moves rather than stretching into a
    #     button half the window wide
    #   - anything else keeps the top-left it always had
    # A control that is docked already manages its own edges, so it is left
    # strictly alone.
    $edgeTolerance = 24
    $spansWidth = 0.6
    foreach ($control in @($inner.Controls)) {
        if ($control.Dock -ne [System.Windows.Forms.DockStyle]::None) { continue }
        $anchor = $control.Anchor
        $reachesRight = ($control.Right -ge ($originalWidth - $edgeTolerance))
        if ($reachesRight) {
            if ($control.Width -ge ($originalWidth * $spansWidth)) {
                $anchor = $anchor -bor [System.Windows.Forms.AnchorStyles]::Right
            }
            else {
                $anchor = ($anchor -bor [System.Windows.Forms.AnchorStyles]::Right) -band (-bnot [System.Windows.Forms.AnchorStyles]::Left)
            }
        }
        # Horizontally only. The same trick vertically looks right until
        # the page is SHORTER than the dialog was - a tab strip costs
        # height, and two rows of captions cost it twice - and then a
        # bottom-anchored button does not scroll into view, it rides up
        # over the log above it. That shipped three times: the audit log
        # landing at y=932, and "Sync selected" sitting 5px into its log on
        # CI's screen but not on mine.
        #
        # Everything keeps the Top it was laid out with, so a short page
        # scrolls, which is what the AutoScroll panel above is for. A page
        # that wants its content to fill the height says so by name in
        # Expand-HostedContent - one dialog, one decision, nothing inferred
        # from where a control happens to sit.
        $control.Anchor = $anchor
    }

    return $inner
}

function Global:Expand-HostedContent {
    <#
      Gives one control on a tab page the height the page has.

      A dialog that becomes a tab leaves a hole: its own Close button and
      button row are hidden, because the host window has those, and the
      grid or log that sat above them keeps its old height - so the page
      ends in empty space a third of the way up from the bottom.

      Call this from the host's Shown handler, never while building. Before
      the window is shown a TabPage reports a ClientSize of about 100, and
      every control on it reports Visible = $false because nothing in the
      chain is on screen yet - so "how tall is the page" and "is anything
      below me" both answer wrongly, and confidently.

      The caller names the control, because only the dialog knows which one
      is its content. Guessing "the biggest one" is how the wrong thing
      grows.
    #>
    param(
        [System.Windows.Forms.Control]$Control,
        [System.Windows.Forms.TabPage]$Page,
        # What still sits under the content, if anything - the winget check
        # keeps a "Copy list" button below its grid. Named by the caller
        # rather than found by looking: a control on a tab page that is not
        # the selected one reports Visible = $false, exactly like one hidden
        # on purpose, so there is no way to tell "hidden" from "on another
        # tab" by inspection.
        [System.Windows.Forms.Control]$StopAbove,
        # Moves -StopAbove, and everything level with or below it, down to
        # the bottom of the page before filling - so a trailing button row
        # ends up ON the bottom edge and the content takes everything
        # above it, instead of the row staying at the height the old
        # dialog put it and leaving a band of dead space underneath.
        #
        # Down only. A page SHORTER than the dialog it came from has to
        # leave the row where it is and scroll to it; dragging a row
        # upwards is how a button ends up sitting over the log above it.
        [switch]$PushDown,
        [int]$BottomMargin = 12
    )
    if (-not $Control -or -not $Page) { return }
    if ($PushDown -and $StopAbove -and $StopAbove.Parent) {
        # The whole trailing row, not just the named control: "Select all"
        # and "Select none" sit level with it and have to travel with it.
        $rowTop = $StopAbove.Top
        $trailing = @($StopAbove.Parent.Controls | Where-Object { $_.Top -ge $rowTop })
        $lowest = ($trailing | Measure-Object -Property Bottom -Maximum).Maximum
        $delta = ($StopAbove.Parent.ClientSize.Height - $BottomMargin) - $lowest
        if ($delta -gt 0) { foreach ($sibling in $trailing) { $sibling.Top = $sibling.Top + $delta } }
    }
    $fillTo = $Page.ClientSize.Height - $BottomMargin
    $hasSomethingBelow = [bool]$StopAbove
    if ($StopAbove -and ($StopAbove.Top - $BottomMargin) -lt $fillTo) {
        $fillTo = $StopAbove.Top - $BottomMargin
    }

    # Fits the content to the space, in both directions. Growing is the
    # obvious half; shrinking matters because a page can be SHORTER than
    # the dialog was (a tab strip costs height, and it costs two rows'
    # worth once the captions no longer fit on one), and then everything
    # anchored to the bottom rides up into whatever is above it. The 80px
    # floor stops a very short page from collapsing the content entirely.
    if ($fillTo -gt ($Control.Top + 80)) {
        $Control.Height = $fillTo - $Control.Top
    }
    # Anchored to the bottom only when nothing is under it. Whatever is
    # below is anchored to the top and stays put, so a control that grows
    # with the window would grow straight over it.
    if (-not $hasSomethingBelow) {
        $Control.Anchor = $Control.Anchor -bor [System.Windows.Forms.AnchorStyles]::Bottom
    }
}

function Global:Get-ControlGroupOrigin {
    <#
      The top-left corner of a set of controls, as @{ X; Y }, from their
      (x, y) pairs. Moving a group onto its own tab means subtracting this
      and adding back the margin the page wants, so a group that started
      600px down the old panel starts at the top of its page instead.
      @{ X = 0; Y = 0 } for an empty set, so the caller can move nothing
      without a special case.
    #>
    param($Points)
    $all = @($Points)
    if ($all.Count -eq 0) { return @{ X = 0; Y = 0 } }
    $minX = ($all | ForEach-Object { [int]$_.X } | Measure-Object -Minimum).Minimum
    $minY = ($all | ForEach-Object { [int]$_.Y } | Measure-Object -Minimum).Minimum
    return @{ X = [int]$minX; Y = [int]$minY }
}

function Global:Convert-PanelToTabs {
    <#
      Splits one flat panel of absolutely-positioned controls into tab
      pages, without any of them being re-laid-out by hand: each page takes
      the controls named for it, keeps their positions relative to each
      other, and is shifted up so the group starts at the top of its page.

      -Pages is @(@{ Title = '...'; Controls = @($a, $b, ...) }, ...).
      $null entries are ignored, so a caller can list a control that only
      exists in some modes. Anything left over lands on the first page
      rather than disappearing, because a control that silently stops being
      shown is far worse than one on the wrong tab.

      Returns the TabControl.
    #>
    param(
        [System.Windows.Forms.Form]$Dialog,
        [System.Windows.Forms.Panel]$Panel,
        $Pages,
        [int]$Margin = 12,
        # Where the tabs go when the controls come straight off the dialog
        # (no panel to inherit a position from).
        [System.Drawing.Rectangle]$Bounds
    )
    # Without a panel the controls are taken off the dialog itself, and then
    # only the ones named may move - everything else on the form (the log,
    # the buttons) has to stay exactly where it is.
    $source = if ($Panel) { $Panel } else { $Dialog }
    $sweepLeftovers = [bool]$Panel

    $tabs = New-Object System.Windows.Forms.TabControl
    if ($Panel) {
        $tabs.Location = $Panel.Location
        $tabs.Size = $Panel.Size
    }
    else {
        $tabs.Location = New-Object System.Drawing.Point($Bounds.X, $Bounds.Y)
        $tabs.Size = New-Object System.Drawing.Size($Bounds.Width, $Bounds.Height)
    }

    foreach ($spec in @($Pages)) {
        $page = New-Object System.Windows.Forms.TabPage
        $page.Text = [string]$spec.Title
        $page.UseVisualStyleBackColor = $true
        $inner = New-Object System.Windows.Forms.Panel
        $inner.Dock = [System.Windows.Forms.DockStyle]::Fill
        $inner.AutoScroll = $true
        $page.Controls.Add($inner)
        [void]$tabs.TabPages.Add($page)

        # Only what this panel actually holds. A control the dialog attaches
        # and detaches as the user picks something (the detection panels
        # here) has no parent at this moment, and adding it anyway would put
        # every one of them on screen at once, stacked.
        $wanted = @(@($spec.Controls) | Where-Object { $_ -and [object]::ReferenceEquals($_.Parent, $source) })
        if ($wanted.Count -eq 0) { continue }
        $origin = Get-ControlGroupOrigin -Points (@($wanted | ForEach-Object { @{ X = $_.Left; Y = $_.Top } }))
        foreach ($control in $wanted) {
            $newX = $control.Left - $origin.X + $Margin
            $newY = $control.Top - $origin.Y + $Margin
            $source.Controls.Remove($control)
            $control.Location = New-Object System.Drawing.Point($newX, $newY)
            $inner.Controls.Add($control)
        }
    }

    # Whatever wasn't listed, onto the first page at the position it had -
    # only when a panel was emptied, since a dialog's other controls belong
    # where they are.
    if ($sweepLeftovers -and $tabs.TabPages.Count -gt 0) {
        $firstInner = $tabs.TabPages[0].Controls[0]
        foreach ($leftover in @($Panel.Controls)) {
            $Panel.Controls.Remove($leftover)
            $firstInner.Controls.Add($leftover)
        }
    }

    if ($Panel) { $Dialog.Controls.Remove($Panel) }
    $Dialog.Controls.Add($tabs)
    # Run it now for the plain case, and again whenever this tab control is
    # given a different size. That second part is what actually matters for
    # the app editor: the deploy dialog builds these pages against its own
    # narrow panel, and the editor then re-hosts the whole tab control in a
    # much wider window - at build time there is no spare width to hand
    # out, and the real width only exists later.
    return $tabs
}

function Global:Get-GroupDeletionPlan {
    <#
      What deleting these groups would cost, one row per group:
      @{ Name; UsedBy = <catalog app names>; }. -UsedByLookup does the
      catalog side (Get-CatalogAppsUsingGroup by default) so this is
      testable without a catalog.

      Rows come back in the order given, duplicates and blanks dropped -
      a list built from a checked list can contain neither, but a list
      built from anything else can.
    #>
    param([string[]]$GroupNames, [scriptblock]$UsedByLookup)
    if (-not $UsedByLookup) { $UsedByLookup = { param($Name) @(Get-CatalogAppsUsingGroup -GroupName $Name) } }
    $rows = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($GroupNames)) {
        $trimmed = ([string]$name).Trim()
        if (-not $trimmed) { continue }
        if (-not $seen.Add($trimmed)) { continue }
        $rows.Add(@{ Name = $trimmed; UsedBy = @(& $UsedByLookup $trimmed) })
    }
    return $rows.ToArray()
}

function Global:Format-GroupDeletionWarning {
    <#
      The sentence above the confirmation box. Deleting a group the catalog
      still assigns apps to breaks those assignments silently - the catalog
      keeps the name and the next push fails - so the apps affected are
      named rather than counted.
    #>
    param($Plan)
    $rows = @($Plan)
    if ($rows.Count -eq 0) { return "Nothing is selected." }
    $inUse = @($rows | Where-Object { @($_.UsedBy).Count -gt 0 })
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Permanently delete $($rows.Count) group(s) from Entra ID. This can't be undone.")
    if ($inUse.Count -eq 0) {
        $lines.Add("No app in this catalog uses any of them.")
    }
    else {
        $lines.Add("$($inUse.Count) of them are still used by apps in this catalog, whose assignments will break:")
        foreach ($row in ($inUse | Select-Object -First 8)) {
            $apps = @($row.UsedBy)
            $shown = ($apps | Select-Object -First 5) -join ', '
            if ($apps.Count -gt 5) { $shown = "$shown, +$($apps.Count - 5) more" }
            $lines.Add("  $($row.Name) - $shown")
        }
        if ($inUse.Count -gt 8) { $lines.Add("  ...and $($inUse.Count - 8) more.") }
    }
    return ($lines -join "`r`n")
}

function Global:Get-GraphRunspaceErrorMessage {
    # Shared by every Timer-polled runspace fetch in this file - builds
    # the same "message [file:line]" detail every one of them wants for
    # diagnosing a genuinely unexpected failure, then routes it through
    # ConvertTo-FriendlyGraphError so the common, already-recognized ones
    # lead with something a non-developer can actually act on.
    param($ErrorRecords)
    $raw = (@($ErrorRecords) | ForEach-Object {
        # Get-GraphErrorRecordMessage, not $_.ToString(): an ErrorRecord with
        # ErrorDetails set returns the DETAILS from ToString(), so the
        # exception's own text ("Forbidden (Forbidden)") was being replaced by
        # Graph's body rather than joined to it. It builds both halves, and
        # it's the same message the catch path produces.
        $line = Get-GraphErrorRecordMessage $_
        $where = $_.InvocationInfo.PositionMessage
        if ($where) { "$line [$($where.Trim())]" } else { $line }
    }) -join "`n"
    return ConvertTo-FriendlyGraphError $raw
}

function Global:ConvertTo-DisplayLineEndings {
    # WinForms Multiline TextBox/RichTextBox controls only ever render a
    # bare `n as a line break inconsistently - they need real `r`n. This
    # repo's own source files use LF-only line endings, so any here-string
    # template (like the winget detection script below) carries bare `n
    # when read into a string - fine to execute as a script, but it shows
    # up as one giant run-on line if put straight into a TextBox.Text.
    # Idempotent: an already-CRLF string round-trips unchanged.
    param([string]$Text)
    if (-not $Text) { return $Text }
    return ($Text -replace "`r?`n", "`r`n")
}

function Global:ConvertTo-CanonicalLineEndings {
    # The inverse of ConvertTo-DisplayLineEndings, for the other direction
    # of the same round trip - reading a detection script back OUT of a
    # TextBox (now `r`n, after display normalization) to save it to the
    # catalog or upload it to Intune. Without this, a detection script
    # that was only ever VIEWED (not edited - e.g. just opening an
    # existing app to change an unrelated field like Architecture) would
    # get written back with `r`n even though the original catalog file
    # and whatever's already live in Intune both still have the original
    # bare `n - a byte-for-byte difference with no real content change
    # behind it, but enough to make the next metadata-drift check flag
    # "Detection rule" as differing (confirmed live) and needlessly dirty
    # the catalog file's own git diff. Normalizing back to `n here - not
    # leaving it as `r`n - matches this repo's own LF convention and
    # keeps re-saves of an unedited script byte-identical to before.
    param([string]$Text)
    if (-not $Text) { return $Text }
    return ($Text -replace "`r`n", "`n")
}

function Global:Set-Theme {
    param([System.Windows.Forms.Control]$Control)
    Set-ThemeRecursive -Ctrl $Control -Palette $Global:App.LightPalette
    if ($Control -is [System.Windows.Forms.Form]) {
        Resize-DialogToScreen -Form $Control
        # Windows selects all text in the text box that gets focus when a
        # dialog opens (e.g. the app name in Edit app) - one careless
        # keystroke would replace it. Put the caret at the end instead.
        # Deferred (BeginInvoke) so it runs after the dialog's own Shown
        # handlers - some move focus to their name box there themselves.
        $Control.Add_Shown({
            param($sender, $e)
            $shownForm = $sender
            [void]$shownForm.BeginInvoke([Action]{
                $focused = $shownForm.ActiveControl
                while ($focused -is [System.Windows.Forms.ContainerControl] -and $focused.ActiveControl) { $focused = $focused.ActiveControl }
                if ($focused -is [System.Windows.Forms.TextBoxBase] -and $focused.SelectionLength -gt 0) {
                    $focused.SelectionStart = $focused.TextLength
                    $focused.SelectionLength = 0
                }
            }.GetNewClosure())
        })
    }
}

function Global:Get-UsableScreenArea {
    # Working area of the screen the app is on. INTUNEPACKAGER_TEST_SCREEN
    # ("1024x768") pretends a smaller one, to reproduce small-screen layout
    # problems on a big monitor.
    if ($env:INTUNEPACKAGER_TEST_SCREEN -match '^(\d+)x(\d+)$') {
        return New-Object System.Drawing.Rectangle(0, 0, ([int]$Matches[1]), ([int]$Matches[2] - 40))   # minus a taskbar
    }
    $screen = if ($Global:App.Form -and $Global:App.Form.IsHandleCreated) { [System.Windows.Forms.Screen]::FromControl($Global:App.Form) } else { [System.Windows.Forms.Screen]::PrimaryScreen }
    return $screen.WorkingArea
}

function Global:Resize-DialogToScreen {
    # The fixed-size dialogs are laid out for a large screen - App editor is
    # 940px tall, Deploy to Intune 1300x1087. On a smaller one (1366x768
    # laptops, 1024x768 VMs) Windows just cuts the window down and the bottom
    # rows (Save, Close, Apply...) become unreachable. Instead, when a dialog
    # doesn't fit, its content moves into a scrolling panel and the window
    # shrinks to the screen. A dialog that fits is left exactly as it is.
    # Resizable dialogs lay themselves out (anchors), so they're just made
    # small enough to fit.
    param([System.Windows.Forms.Form]$Form)
    if ([object]::ReferenceEquals($Form, $Global:App.Form)) { return }
    $area = Get-UsableScreenArea
    if ($Form.FormBorderStyle -eq [System.Windows.Forms.FormBorderStyle]::Sizable -or $Form.FormBorderStyle -eq [System.Windows.Forms.FormBorderStyle]::SizableToolWindow) {
        if ($Form.Width -gt $area.Width -or $Form.Height -gt $area.Height) {
            $Form.Size = New-Object System.Drawing.Size(
                [Math]::Max($Form.MinimumSize.Width, [Math]::Min($Form.Width, $area.Width)),
                [Math]::Max($Form.MinimumSize.Height, [Math]::Min($Form.Height, $area.Height)))
        }
        return
    }
    # What the dialog was laid out for: its requested ClientSize, or further
    # if any control reaches beyond that (+ the usual 10px margin).
    $contentWidth = $Form.ClientSize.Width
    $contentHeight = $Form.ClientSize.Height
    foreach ($c in @($Form.Controls)) {
        if ($c.Dock -ne [System.Windows.Forms.DockStyle]::None) { continue }
        $contentWidth = [Math]::Max($contentWidth, $c.Right + 10)
        $contentHeight = [Math]::Max($contentHeight, $c.Bottom + 10)
    }
    $content = New-Object System.Drawing.Size($contentWidth, $contentHeight)
    # Title bar + borders, measured on a small throwaway form with the same
    # border style - not as $Form.Size minus its ClientSize, because on a
    # small screen Windows has already capped $Form.Size (not its requested
    # ClientSize), which made that difference negative.
    $probe = New-Object System.Windows.Forms.Form
    try {
        $probe.FormBorderStyle = $Form.FormBorderStyle
        $probe.ClientSize = New-Object System.Drawing.Size(100, 100)
        $chromeWidth = $probe.Width - 100
        $chromeHeight = $probe.Height - 100
    }
    finally { $probe.Dispose() }
    $maxWidth = $area.Width - $chromeWidth
    $maxHeight = $area.Height - $chromeHeight
    if ($content.Width -le $maxWidth -and $content.Height -le $maxHeight) { return }

    $scroller = New-Object System.Windows.Forms.Panel
    $scroller.Dock = [System.Windows.Forms.DockStyle]::Fill
    $scroller.AutoScroll = $true
    $scroller.BackColor = $Form.BackColor
    $Form.SuspendLayout()
    foreach ($c in @($Form.Controls)) {
        # keep each control exactly where the dialog put it, inside the scroll area
        if ($c.Dock -eq [System.Windows.Forms.DockStyle]::None) {
            $c.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
        }
        $Form.Controls.Remove($c)
        $scroller.Controls.Add($c)
    }
    $Form.Controls.Add($scroller)
    $scroller.AutoScrollMinSize = $content
    # Room for the scrollbar that will appear, so it doesn't force a second one
    # (a vertical bar eats into the width, a horizontal one into the height).
    $width = $content.Width
    $height = $content.Height
    if ($height -gt $maxHeight) { $width += [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth }
    if ($width -gt $maxWidth) { $height += [System.Windows.Forms.SystemInformation]::HorizontalScrollBarHeight }
    $Form.ClientSize = New-Object System.Drawing.Size([Math]::Min($width, $maxWidth), [Math]::Min($height, $maxHeight))
    $Form.ResumeLayout()
}

function Global:Set-ThemeRecursive {
    param($Ctrl, $Palette)

    switch ($Ctrl.GetType().Name) {
        "Form" {
            $Ctrl.BackColor = $Palette.FormBack
            $Ctrl.ForeColor = $Palette.ControlFore
        }
        { $_ -in @("Panel","GroupBox","TabPage","FlowLayoutPanel","TabControl") } {
            # Only overwrites a color still at its WinForms default - a
            # caller that already gave this control its own deliberate
            # BackColor/ForeColor (e.g. a bordered "field"-look info box)
            # keeps it. Confirmed live, repeatedly: this function runs
            # once, right before ShowDialog(), well AFTER every control's
            # own creation-time styling - unconditionally overwriting here
            # silently wiped out custom colors set earlier in the same
            # function, with no way for the caller to tell without
            # re-applying its own color again after this call (which is
            # what every one of those call sites had to do before this
            # fix, one at a time, as each case was found).
            if ($Ctrl.BackColor -eq [System.Drawing.SystemColors]::Control) { $Ctrl.BackColor = $Palette.FormBack }
            if ($Ctrl.ForeColor -eq [System.Drawing.SystemColors]::ControlText) { $Ctrl.ForeColor = $Palette.ControlFore }
        }
        "Label" {
            # Same "only touch it if it's still at the default" reasoning
            # as the Panel/GroupBox/... case above - a Label given its own
            # color at creation (DimGray for a status line, DarkOrange/
            # Firebrick for a warning, ...) keeps it instead of being
            # silently flattened to plain body text the moment this runs.
            if ($Ctrl.ForeColor -eq [System.Drawing.SystemColors]::ControlText) { $Ctrl.ForeColor = $Palette.ControlFore }
        }
        { $_ -in @("TextBox","ComboBox") } {
            $Ctrl.BackColor = $Palette.FieldBack
            $Ctrl.ForeColor = $Palette.ControlFore
        }
        "Button" {
            $Ctrl.BackColor = $Palette.ButtonBack
            $Ctrl.ForeColor = $Palette.ControlFore
            $Ctrl.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $Ctrl.FlatAppearance.BorderColor = $Palette.BorderColor
            # A hover/press color, not just a flat border - the previous
            # version left FlatAppearance's Mouse*BackColor at their
            # WinForms defaults (a jarring dark-grey flash on hover/click
            # against a light theme), which read as broken rather than
            # deliberately flat. Palette entries are optional (checked with
            # -contains, not direct access) so a caller that themes a
            # button with an older/custom palette missing these two keys
            # doesn't hit a $null FlatAppearance.MouseOverBackColor assignment.
            if ($Palette.Keys -contains 'ButtonHoverBack') { $Ctrl.FlatAppearance.MouseOverBackColor = $Palette.ButtonHoverBack }
            if ($Palette.Keys -contains 'ButtonPressBack') { $Ctrl.FlatAppearance.MouseDownBackColor = $Palette.ButtonPressBack }
        }
        { $_ -in @("CheckBox","RadioButton") } {
            $Ctrl.ForeColor = $Palette.ControlFore
        }
        { $_ -in @("ListBox","CheckedListBox") } {
            $Ctrl.BackColor = $Palette.FieldBack
            $Ctrl.ForeColor = $Palette.ControlFore
            # Long group/app names scroll sideways instead of being cut off at
            # the right edge (the bar only appears when something is wider).
            if (-not $Ctrl.MultiColumn) { $Ctrl.HorizontalScrollbar = $true }
        }
        "DataGridView" {
            $Ctrl.BackgroundColor = $Palette.GridBack
            $Ctrl.ForeColor = $Palette.ControlFore
            $Ctrl.GridColor = $Palette.BorderColor
            $Ctrl.EnableHeadersVisualStyles = $false
            $Ctrl.DefaultCellStyle.BackColor = $Palette.GridBack
            $Ctrl.DefaultCellStyle.ForeColor = $Palette.ControlFore
            $Ctrl.DefaultCellStyle.SelectionBackColor = $Palette.SelectionBack
            $Ctrl.DefaultCellStyle.SelectionForeColor = $Palette.SelectionFore
            $Ctrl.AlternatingRowsDefaultCellStyle.BackColor = $Palette.GridAltBack
            $Ctrl.AlternatingRowsDefaultCellStyle.ForeColor = $Palette.ControlFore
            $Ctrl.ColumnHeadersDefaultCellStyle.BackColor = $Palette.GridHeaderBack
            $Ctrl.ColumnHeadersDefaultCellStyle.ForeColor = $Palette.ControlFore
            # With header visual styles off, newer WinForms (PS 7) paints the
            # selected cell's column header in the selection color - keep
            # headers looking like headers.
            $Ctrl.ColumnHeadersDefaultCellStyle.SelectionBackColor = $Palette.GridHeaderBack
            $Ctrl.ColumnHeadersDefaultCellStyle.SelectionForeColor = $Palette.ControlFore
            # One row height under both PowerShells - .NET 7+ pads rows a few
            # pixels more than .NET Framework for the same font. Grids that
            # size their own rows (wrapped multi-line cells) are left alone.
            if ($Ctrl.AutoSizeRowsMode -eq [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::None) {
                $rowHeight = $Ctrl.Font.Height + 6
                $Ctrl.RowTemplate.Height = $rowHeight
                foreach ($row in $Ctrl.Rows) { $row.Height = $rowHeight }
            }
            $Ctrl.RowHeadersDefaultCellStyle.BackColor = $Palette.GridHeaderBack
            $Ctrl.RowHeadersDefaultCellStyle.ForeColor = $Palette.ControlFore
        }
        "StatusStrip" {
            # StatusStrip's actual content (ToolStripStatusLabel etc.) lives
            # in .Items, not the regular .Controls tree the recursive walk
            # below descends into - so without this explicit case, the
            # status bar would silently stay stuck at default system colors
            # (a visibly mismatched light bar at the bottom of a dark form).
            $Ctrl.BackColor = $Palette.FormBack
            foreach ($item in $Ctrl.Items) {
                $item.ForeColor = $Palette.ControlFore
            }
        }
        "MenuStrip" {
            # Same ToolStrip-family issue as StatusStrip above - a MenuStrip's
            # top-level items AND their dropdown items both live outside the
            # regular .Controls tree.
            $Ctrl.BackColor = $Palette.FormBack
            foreach ($item in $Ctrl.Items) {
                $item.ForeColor = $Palette.ControlFore
                if ($item.DropDownItems) {
                    foreach ($sub in $item.DropDownItems) {
                        $sub.ForeColor = $Palette.ControlFore
                    }
                }
            }
        }
        default { }
    }

    foreach ($child in @($Ctrl.Controls)) {
        Set-ThemeRecursive -Ctrl $child -Palette $Palette
    }
    Resolve-CaptionOverlaps -Container $Ctrl
}

function Global:Resolve-CaptionOverlaps {
    # An AutoSize Label is a few pixels taller than its text, so a caption
    # placed the usual ~20px above its field ended up covering the field's
    # top border (text boxes, list boxes, combo boxes - app-wide, found by
    # code\tests\gui\DialogSmoke.GuiTests.ps1). Nudges each such caption up
    # by exactly the overlap. Only small overlaps (up to 6px) are touched,
    # so a label deliberately placed over another control stays put, and
    # layout-engine containers (FlowLayoutPanel/TableLayoutPanel) are left
    # to position their own children.
    param([System.Windows.Forms.Control]$Container)
    if ($Container -is [System.Windows.Forms.FlowLayoutPanel] -or $Container -is [System.Windows.Forms.TableLayoutPanel]) { return }
    $kids = @($Container.Controls)
    foreach ($lbl in $kids) {
        if ($lbl -isnot [System.Windows.Forms.Label] -or -not $lbl.AutoSize) { continue }
        $b = $lbl.Bounds
        $overlap = 0
        foreach ($o in $kids) {
            if ($o -eq $lbl -or $o -is [System.Windows.Forms.Label]) { continue }
            if ($o -is [System.Windows.Forms.Panel] -or $o -is [System.Windows.Forms.GroupBox] -or $o -is [System.Windows.Forms.TabControl] -or $o -is [System.Windows.Forms.SplitContainer]) { continue }
            $below = $o.Top -gt $b.Top -and $o.Top -lt $b.Bottom
            $sideBySide = $o.Left -lt $b.Right -and $o.Right -gt $b.Left
            if ($below -and $sideBySide) { $overlap = [Math]::Max($overlap, $b.Bottom - $o.Top) }
        }
        if ($overlap -gt 0 -and $overlap -le 6) {
            $lbl.Top = [Math]::Max(0, $lbl.Top - $overlap)
        }
    }
}

function Global:Add-RemovableItemContextMenu {
    param($CheckedListBox)

    $ctxMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miRemove = New-Object System.Windows.Forms.ToolStripMenuItem "Remove from list"
    [void]$ctxMenu.Items.Add($miRemove)
    # Mutable container, not a plain variable - written by the mouse-down
    # handler below, read by the menu item's own, separately-created
    # click handler.
    $rightClickedIndexBox = @{ Value = -1 }

    $CheckedListBox.Add_MouseDown({
        param($clbSender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            $idx = $clbSender.IndexFromPoint($e.Location)
            $rightClickedIndexBox.Value = $idx
            if ($idx -ge 0) { $clbSender.SelectedIndex = $idx }
        }
    }.GetNewClosure())

    $miRemove.Add_Click({
        $idx = $rightClickedIndexBox.Value
        if ($idx -lt 0 -or $idx -ge $CheckedListBox.Items.Count) { return }
        if ($CheckedListBox.GetItemChecked($idx)) {
            [System.Windows.Forms.MessageBox]::Show("`"$($CheckedListBox.Items[$idx])`" is currently checked - uncheck it first, then remove it.", "Still checked", "OK", "Warning") | Out-Null
            return
        }
        $CheckedListBox.Items.RemoveAt($idx)
    }.GetNewClosure())

    $CheckedListBox.ContextMenuStrip = $ctxMenu
}

function Global:Show-SimpleListPicker {
    param([string]$Title, [string]$Prompt, [string[]]$Items)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = $Title
    # Wide enough for "<app name>  [<App ID GUID>]" entries - the GUID at the
    # end is what tells same-named matches apart, so it must not be cut off.
    $dlg.ClientSize = New-Object System.Drawing.Size(600, 320)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Prompt
    $lbl.Location = New-Object System.Drawing.Point(12,12)
    $lbl.Size = New-Object System.Drawing.Size(576,40)
    $dlg.Controls.Add($lbl)

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location = New-Object System.Drawing.Point(12,55)
    $lst.Size = New-Object System.Drawing.Size(576,210)
    $lst.HorizontalScrollbar = $true   # still readable when a name is longer still
    $lst.Items.AddRange($Items)
    if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = 0 }
    $dlg.Controls.Add($lst)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Select"
    $btnOk.Location = New-Object System.Drawing.Point(408,271)
    $btnOk.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(503,271)
    $btnCancel.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnCancel)

    # Plain local box (not $Script:-qualified) - closures reliably capture and mutate
    # plain variables via GetNewClosure(), so the button handlers write into this box
    # and the code below (outside any closure) reads it back after ShowDialog returns.
    $resultBox = @{ Value = $null }

    $btnOk.Add_Click({
        $resultBox.Value = if ($lst.SelectedItem) { [string]$lst.SelectedItem } else { $null }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure())
    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    }.GetNewClosure())
    $lst.Add_DoubleClick({ $btnOk.PerformClick() }.GetNewClosure())

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    Set-Theme -Control $dlg
    $result = $dlg.ShowDialog($Global:App.Form)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $resultBox.Value }
    return $null
}

function Global:Set-Status {
    param([string]$Text)
    $Global:App.StatusLabel.Text = $Text
}

# Called in pairs around any background startup task (Start-
# StartupDriftCheck, Start-TypeVersionBackfill) - $Delta is +1 when the
# task starts, -1 when it finishes (success, failure, or nothing to do).
# A shared counter rather than a plain boolean because both tasks can
# legitimately run at once; the indicator only disappears once EVERY
# task that raised it has also lowered it again.
function Global:Update-StartupBusyIndicator {
    param([int]$Delta = 0)
    $Global:App.StartupBusyCount = [Math]::Max(0, $Global:App.StartupBusyCount + $Delta)
    $Global:App.LblStartupBusy.Visible = ($Global:App.StartupBusyCount -gt 0)
}

# Shows/hides the App Catalog tab's yellow "no Graph connection"/
# "certificate warning" banner and logs the same thing to the Log tab -
# extracted out of MainApp.ps1's own startup code so it can be re-run
# after Settings closes too, not just once at launch. Previously the
# banner only ever got EVALUATED at startup - if it came up (no
# credentials, or a certificate that needs attention) and the user then
# fixed it via Settings mid-session, the banner stayed up for the rest of
# the session regardless, contradicting the app's own now-working state.
# Always resets to hidden first, then re-shows only if still warranted -
# safe to call as often as needed (startup, and after Settings closes).
function Global:Update-CredentialWarningBanner {
    $Global:App.PanelCredWarning.Visible = $false

    # Whitespace-aware, same as Test-GraphCredentialsConfigured - a plain
    # truthiness check here would treat a whitespace-only value as "set" and
    # skip straight to the certificate-store lookup below, which is exactly
    # the class of bug that made Diagnostics contradict itself (see
    # Test-GraphCredentialsConfigured's own comment). Not calling that
    # function directly here since it also pops a MessageBox on failure,
    # which this silent check must never do.
    if ([string]::IsNullOrWhiteSpace($Global:App.GraphTenantId) -or [string]::IsNullOrWhiteSpace($Global:App.GraphClientId) -or [string]::IsNullOrWhiteSpace($Global:App.GraphCertificateThumbprint)) {
        Write-Log "No Graph connection configured yet - open 'Settings...' to set your Tenant ID, Client ID, and certificate before using anything that talks to Intune or Entra ID (App ID lookup, Deploy to Intune, Assign Groups, Intune sync check, Batch assign).`r`n" ([System.Drawing.Color]::Orange)
        # Also shown as a banner on the App Catalog tab itself, not just
        # logged - the Log tab isn't the default active one, so this is
        # otherwise easy for a new user to never see until something fails
        # with no obvious explanation why.
        $Global:App.PanelCredWarning.Visible = $true
        return
    }

    # Proactive, since every Graph-based feature in this app depends on this
    # one certificate - previously this status only ever showed up if
    # someone happened to open Settings, meaning it could quietly expire
    # with zero warning until every Graph-based feature started failing
    # all at once.
    $certStatus = Get-CertificateStatusText -Thumbprint $Global:App.GraphCertificateThumbprint
    if ($certStatus.Color -ne [System.Drawing.Color]::SeaGreen) {
        Write-Log "Certificate warning: $($certStatus.Text) Open 'Settings...' to check or replace it.`r`n" ([System.Drawing.Color]::Orange)
        $Global:App.LblCredWarning.Text = "Certificate warning: $($certStatus.Text) Open Settings to check or replace it."
        $Global:App.PanelCredWarning.Visible = $true
    }
}

function Global:Write-DialogError {
    param(
        [System.Windows.Forms.Label]$StatusLabel,
        [System.Windows.Forms.RichTextBox]$LogBox,
        [string]$ErrorMessage
    )
    # Through the same plain-language pass the in-process lookups get, so a
    # refused permission or a stale certificate reads the same way whether
    # the call came from this process or from an embedded script.
    $ErrorMessage = ConvertTo-FriendlyGraphError $ErrorMessage
    # $LogBox was already guarded; $StatusLabel was not, and it is reached
    # through the same aliases from the same nested closures. A null one
    # threw "The property 'ForeColor' cannot be found on this object" -
    # replacing the error being reported with an error about reporting it.
    if ($StatusLabel -and -not $StatusLabel.IsDisposed) {
        $StatusLabel.ForeColor = [System.Drawing.Color]::Firebrick
        $StatusLabel.Text = "Failed - see the log below for details."
    }
    # Whatever happens to the controls, the failure itself must not be
    # lost - the main log always exists.
    if (-not $LogBox -or $LogBox.IsDisposed) {
        Write-Log "[FAILED] $ErrorMessage`r`n" ([System.Drawing.Color]::Tomato)
        return
    }
    if ($LogBox) {
        $LogBox.SelectionStart = $LogBox.TextLength
        $LogBox.SelectionLength = 0
        $LogBox.SelectionColor = [System.Drawing.Color]::FromArgb(255,110,110)
        $LogBox.AppendText("`r`n[FAILED] $ErrorMessage`r`n")
        $LogBox.SelectionColor = $LogBox.ForeColor
        $LogBox.ScrollToCaret()
    }
}

function Global:Show-ConfigWriteFailedError {
    param([string]$ErrorMessage)
    [System.Windows.Forms.MessageBox]::Show("Could not write the config file needed to run this: $ErrorMessage", "Failed to prepare", "OK", "Error") | Out-Null
}

function Global:Initialize-DarkLogBox {
    param(
        [System.Windows.Forms.RichTextBox]$LogBox,
        [double]$FontSize = 8.5
    )
    $LogBox.ReadOnly = $true
    $LogBox.BackColor = [System.Drawing.Color]::FromArgb(13,17,23)
    $LogBox.ForeColor = [System.Drawing.Color]::Gainsboro
    $LogBox.Font = New-Object System.Drawing.Font("Consolas", $FontSize)
}

# The single place that maps a line's leading [TAG] to a color, so every
# dark log box in the app (not just the main Log tab and Diagnostics, which
# used to be the only two that colored anything) highlights the same way.
# Was previously plain white-on-black text in most dialogs - the [OK]/
# [FAILED]/etc tag was there to read, but nothing let you glance-scan for
# red vs green the way the main Log tab always could.
function Global:Get-DialogLogLineColor {
    param([string]$Text)
    if ($Text -match '^\s*\[GRAPH\].*-> FAILED') { return [System.Drawing.Color]::Tomato }
    if ($Text -match '^\s*\[GRAPH\]') { return [System.Drawing.Color]::LightSkyBlue }
    if ($Text -match '^\s*\[RUN\].*-> FAILED') { return [System.Drawing.Color]::Tomato }
    if ($Text -match '^\s*\[RUN\]') { return [System.Drawing.Color]::Khaki }
    if ($Text -match '^\s*(\[OK\])') { return [System.Drawing.Color]::LightGreen }
    if ($Text -match '^\s*(\[FAILED\])') { return [System.Drawing.Color]::Tomato }
    if ($Text -match '^\s*(\[WARN\])') { return [System.Drawing.Color]::Orange }
    if ($Text -match '^\s*(\[SKIPPED\])') { return [System.Drawing.Color]::DimGray }
    if ($Text -match '^\s*(\[INFO\])') { return [System.Drawing.Color]::Gainsboro }
    return [System.Drawing.Color]::Gainsboro
}

# Appends one line to a dialog's own dark log box, colored by its leading
# [TAG] via Get-DialogLogLineColor above - the per-dialog equivalent of
# Write-Log (which only ever targets the main window's single Log tab).
#
# -MirrorToMainLog also writes the same line to the main Log tab (and,
# through it, to the persisted log file on disk) - use this for a dialog
# whose own results are worth keeping around after it closes (the batch/
# bulk dialogs looping over many apps: Batch Deploy, Batch Edit, Bulk
# Delete). Every OTHER dialog with its own log box already gets mirrored
# for free, indirectly, because it shells out to an embedded script via
# Start-PipelineProcess -ExtraLogTarget, which mirrors that script's raw
# output into the main Log tab itself - these three don't shell out to
# anything, they call Graph directly in a loop, so without this they were
# the one place a completed run's outcome existed nowhere but that one
# dialog's own memory, gone the moment it closed.
function Global:Write-DialogLogLine {
    param(
        [System.Windows.Forms.RichTextBox]$LogBox,
        [string]$Text,
        [switch]$MirrorToMainLog
    )
    $color = Get-DialogLogLineColor -Text $Text
    # Same fix as Write-Log's own copy (Pipeline.ps1) - some callers build
    # multi-line text with a bare `n (e.g. joining PowerShell error
    # records), which this RichTextBox won't render as a line break.
    $Text = ConvertTo-DisplayLineEndings $Text
    # A null box is not worth throwing over, and it is not worth swallowing
    # either. It means a caller's -LogBox alias came back empty - the
    # closure-nesting trap this codebase hits repeatedly - and what matters
    # is that the line itself still reaches somebody. It goes to the main
    # log instead, which every dialog's log mirrors into anyway.
    #
    # Before this, three of these in a row threw "The property
    # 'SelectionStart' cannot be found on this object" at the user, and the
    # message they were trying to read was lost with it.
    if (-not $LogBox -or $LogBox.IsDisposed) {
        # try/catch because the fallback must not become the new crash:
        # Write-Log writes to the main window, which may itself be gone
        # during shutdown. Logging is never worth taking the app down for.
        try { Write-Log $Text $color } catch { }
        return
    }
    $LogBox.SelectionStart = $LogBox.TextLength
    $LogBox.SelectionLength = 0
    $LogBox.SelectionColor = $color
    $LogBox.AppendText($Text)
    $LogBox.ScrollToCaret()
    if ($MirrorToMainLog) {
        Write-Log $Text $color
    }
}

# Names of the catalog apps that have a group in Required, Available or
# Uninstall - shown before a group is deleted or renamed.
function Global:Get-CatalogAppsUsingGroup {
    param([string]$GroupName)
    @($Global:App.Apps | Where-Object {
        (@($_.requiredFor) + @($_.availableFor) + @($_.uninstallFor)) -contains $GroupName
    } | ForEach-Object { [string]$_.appName })
}

# Deleting an app that has no App ID: it isn't in Intune, so only the
# catalog entry goes. The same question wherever it's asked (app editor,
# "Delete from Intune" on such an app). No is the default button.
function Global:Confirm-CatalogOnlyDelete {
    param([string]$AppName, [switch]$UnsavedEdits)
    $text = "Delete '$AppName' from the catalog?`n`nIt has no App ID, so it isn't in Intune - this only removes the local entry."
    if ($UnsavedEdits) { $text += " Your unsaved edits to it are discarded too." }
    $r = [System.Windows.Forms.MessageBox]::Show($text, "Confirm delete", "YesNo", "Warning", "Button2")
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

# Asks before a dialog closes, however it's closed - its Close button, Esc,
# the X or Alt+F4 all end up in FormClosing. -GetQuestion returns $null
# (close without asking), the question text, or @{ Title; Text }; the
# title defaults to "Stop and close?". -OnConfirmed runs after Yes, e.g. to
# stop the step that's still running. No is the default button, so Enter
# never closes over a running step by accident.
function Global:Register-CloseConfirmation {
    param(
        [System.Windows.Forms.Form]$Dialog,
        [scriptblock]$GetQuestion,
        [scriptblock]$OnConfirmed
    )
    # $true while the question is on screen. Without it, a second attempt to
    # close (the Close button, Esc, the X) opens ANOTHER question on top of
    # the first - they stack up and the window looks stuck.
    $askingBox = @{ Value = $false }
    $Dialog.Add_FormClosing({
        param($sender, $e)
        if ($e.Cancel) { return }
        if ($askingBox.Value) { $e.Cancel = $true; return }
        $question = & $GetQuestion
        if (-not $question) { return }
        $title = "Stop and close?"
        $text = [string]$question
        if ($question -is [hashtable]) { $title = [string]$question.Title; $text = [string]$question.Text }
        # $sender as the owner: a message box without one doesn't disable the
        # window behind it, so that window keeps accepting clicks.
        $askingBox.Value = $true
        try { $r = [System.Windows.Forms.MessageBox]::Show($sender, $text, $title, "YesNo", "Warning", "Button2") }
        finally { $askingBox.Value = $false }
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
        if ($OnConfirmed) { try { & $OnConfirmed } catch { } }
    }.GetNewClosure())
}

function Global:New-ToolbarGroup {
    param([string]$Title, [System.Windows.Forms.Control[]]$Buttons)

    $gb = New-Object System.Windows.Forms.GroupBox
    $gb.Text = $Title
    $gb.Height = 60
    $gb.AutoSize = $true
    $gb.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $gb.Margin = New-Object System.Windows.Forms.Padding(4,4,4,0)

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Location = New-Object System.Drawing.Point(8,20)
    $flow.AutoSize = $true
    $flow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $flow.WrapContents = $false
    $flow.FlowDirection = "LeftToRight"

    # Every item gets a button's height - a group of checkboxes (Sync) was
    # otherwise a few pixels shorter than the button groups beside it.
    $probe = New-Object System.Windows.Forms.Button
    $probe.Font = Get-AppUiFont
    $probe.AutoSize = $true
    $probe.Padding = New-Object System.Windows.Forms.Padding(8,3,8,3)
    $probe.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat   # what Set-Theme turns every button into
    $probe.Text = "Ag"
    $rowHeight = $probe.PreferredSize.Height
    $probe.Dispose()

    foreach ($b in $Buttons) {
        $b.AutoSize = $true
        $b.Padding = New-Object System.Windows.Forms.Padding(8,3,8,3)
        $b.Margin = New-Object System.Windows.Forms.Padding(0,0,4,0)
        if ($b -is [System.Windows.Forms.TextBox] -or $b -is [System.Windows.Forms.ComboBox]) {
            # a single-line text box (or drop-down) keeps its own height - center it in the row instead
            $b.Font = Get-AppUiFont   # measured in the font it will actually use (5.1 would inherit it only later)
            $spare = [Math]::Max(0, $rowHeight - $b.PreferredHeight)
            $top = [int][Math]::Floor($spare / 2)
            $b.Margin = New-Object System.Windows.Forms.Padding(0, $top, 4, ($spare - $top))
        }
        elseif ($b -isnot [System.Windows.Forms.Button]) {
            $b.MinimumSize = New-Object System.Drawing.Size(0, $rowHeight)   # content stays vertically centered
        }
        $flow.Controls.Add($b)
    }
    $gb.Controls.Add($flow)
    return $gb
}

function Global:New-OverflowSubmenu {
    # $Tips is the same ToolTip instance already used to tooltip the real
    # toolbar buttons these items delegate to - reusing GetToolTip($Btn)
    # here means each menu item automatically carries the identical
    # wording as its button, with nothing to keep in sync by hand.
    param([string]$Title, [array]$Items, [System.Windows.Forms.ToolTip]$Tips)
    $sub = New-Object System.Windows.Forms.ToolStripMenuItem $Title
    foreach ($item in $Items) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem $item.Text
        $btnRef = $item.Btn
        if ($Tips) {
            $btnTip = $Tips.GetToolTip($btnRef)
            if ($btnTip) { $mi.ToolTipText = $btnTip }
        }
        $mi.Add_Click({ $btnRef.PerformClick() }.GetNewClosure())
        [void]$sub.DropDownItems.Add($mi)
    }
    return $sub
}

function Global:Set-AppGridStyle {
    <#
      The house look for a table, applied to every grid in the app.

      Deliberately cosmetic only - row headers, row resizing, the border
      and the background. What a grid is FOR differs from dialog to dialog
      (one allows multi-select, one is editable, one sizes its columns by
      content), so nothing here touches selection, editing or column
      sizing; those stay the caller's decision.

      There were eighteen grids across the app and only eleven of them
      agreed on a background, fourteen on whether rows could be dragged
      taller. The difference is small in any one window and obvious when
      you move between them.
    #>
    param([System.Windows.Forms.DataGridView]$Grid)
    if (-not $Grid) { return }
    $Grid.RowHeadersVisible = $false          # nothing in this app has a row header worth 40px
    $Grid.AllowUserToResizeRows = $false      # rows are one line everywhere; dragging one taller only ever misaligns it
    $Grid.AllowUserToAddRows = $false         # every grid here is filled from code
    $Grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $Grid.BackColor = $Global:App.LightPalette.GridBack
    $Grid.BackgroundColor = $Global:App.LightPalette.GridBack
    # Set-Theme repaints headers to match the palette, which WinForms
    # ignores while a grid is drawing its headers in the visual style.
    $Grid.EnableHeadersVisualStyles = $false
}

function Global:Set-TextBoxPlaceholder {
    <#
      Grey hint text inside an empty box - what the value would be if you
      left it alone - the way a browser shows one.

      Win32's own cue banner, not WinForms' PlaceholderText: that property
      arrived in .NET 5, and this app also runs on Windows PowerShell 5.1,
      where the property does not exist and setting it throws.

      A cue banner belongs to the window handle, not to the control, so it
      is re-sent every time a handle is created. That is not a rare event
      here: moving a control to another parent - which is exactly what
      Move-DialogToTabPage and Convert-PanelToTabs do - destroys the old
      handle and the banner with it.

      The box's Text is untouched and stays empty, so "nothing entered"
      still reads as nothing entered to everything that asks.
    #>
    param([System.Windows.Forms.TextBox]$Box, [string]$Text)
    if (-not $Box) { return }
    if (-not ('IntunePackager.NativeText' -as [type])) {
        Add-Type -Namespace IntunePackager -Name NativeText -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageW(System.IntPtr hWnd, int msg, System.IntPtr wParam, string lParam);
"@
    }
    # EM_SETCUEBANNER. wParam 1 keeps the hint visible once the box has
    # focus and is still empty, which is when it is most wanted - clicking
    # into a box should not blank the only thing telling you what it does.
    $sendBanner = {
        if ($Box.IsHandleCreated) {
            [void][IntunePackager.NativeText]::SendMessageW($Box.Handle, 0x1501, [IntPtr]1, [string]$Text)
        }
    }.GetNewClosure()
    $Box.Add_HandleCreated($sendBanner)
    & $sendBanner
}

function Global:New-GridColumn {
    # -Font: the grid's font, used to give the column a MinimumWidth that
    # always fits its own header text (plus cell padding and the sort
    # glyph) - Fill mode alone happily squeezes a narrow column down until
    # "Required" reads "Requirec". -MinimumWidth raises that floor further,
    # for columns whose VALUES need more room than their header (App ID).
    #
    # -FitTo: for a column whose content is always about the same length (a
    # count, Yes/No, a GUID, a version): the widest value it will show. The
    # column then has exactly that width, out of the Fill share-out, so
    # widening the window gives the room to the columns whose text actually
    # varies instead of padding "Yes" out to 150px. Needs -Font.
    param($Name, $Header, $Width = 100, $FillWeight = 20, [System.Drawing.Font]$Font, [int]$MinimumWidth = 0, [string[]]$FitTo)
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $Name
    $col.HeaderText = $Header
    $col.DataPropertyName = $Name
    $col.FillWeight = $FillWeight
    # Programmatic, not Automatic: the grid is bound to a plain List, which
    # can't sort itself, so an Automatic header click does nothing at all.
    # Sort-Grid orders the rows before they're bound and sets the glyph
    # here itself - which also survives the rebuild Update-Grid does on
    # every refresh and every keystroke in the search box.
    $col.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Programmatic
    if ($Font) {
        $headerWidth = [System.Windows.Forms.TextRenderer]::MeasureText($Header, $Font).Width + 24
        $col.MinimumWidth = [Math]::Max($headerWidth, $MinimumWidth)
    }
    elseif ($MinimumWidth -gt 0) {
        $col.MinimumWidth = $MinimumWidth
    }
    if ($FitTo -and $Font) {
        # 16 is the cell's own padding either side; the header already
        # carries its sort-glyph allowance in MinimumWidth above.
        $fit = $col.MinimumWidth
        foreach ($sample in $FitTo) {
            $fit = [Math]::Max($fit, [System.Windows.Forms.TextRenderer]::MeasureText($sample, $Font).Width + 16)
        }
        $col.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::None
        $col.MinimumWidth = $fit
        $col.Width = $fit
    }
    return $col
}

function Global:Get-GridColumnWidths {
    # Column name -> FillWeight, not pixels: the grid is in Fill mode, so
    # dragging a column edge changes its weight. Weights are also the thing
    # worth keeping - they still mean the same on a window reopened at a
    # different size, where saved pixel widths would not.
    $widths = @{}
    if (-not $Global:App.Grid) { return $widths }
    foreach ($col in $Global:App.Grid.Columns) {
        if (-not $col.Visible) { continue }
        # A -FitTo column has a width of its own and no share of the fill,
        # so its weight means nothing and is not worth keeping.
        if ($col.AutoSizeMode -eq [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::None) { continue }
        $widths[$col.Name] = [Math]::Round([double]$col.FillWeight, 2)
    }
    return $widths
}

function Global:Restore-GridColumnWidths {
    # Read back defensively: this comes from a file a person can edit, and
    # a column that has since been renamed or removed simply has no saved
    # width any more. Anything missing or unusable keeps the built-in
    # weight, so the worst case is the layout this grid always had.
    $saved = $Global:App.SavedGridColumnWidths
    if (-not $saved -or -not $Global:App.Grid) { return }
    foreach ($col in $Global:App.Grid.Columns) {
        $value = if ($saved -is [System.Collections.IDictionary]) { $saved[$col.Name] }
                 elseif ($saved.PSObject.Properties[$col.Name]) { $saved.PSObject.Properties[$col.Name].Value }
                 else { $null }
        if ($null -eq $value) { continue }
        $weight = 0.0
        # FillWeight refuses anything at or below zero, so a corrupt or
        # hand-typed 0 must not reach it.
        if ([double]::TryParse([string]$value, [ref]$weight) -and $weight -gt 0) {
            $col.FillWeight = $weight
        }
    }
}

function Global:Get-WindowPlacement {
    $form = $Global:App.Form
    if (-not $form) { return $null }
    # RestoreBounds, not Bounds, whenever the window isn't in its normal
    # state: Bounds while maximized is the whole monitor, which would come
    # back as a "normal" window exactly covering the screen - maximized to
    # look at, but not actually maximized.
    $bounds = if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) { $form.Bounds } else { $form.RestoreBounds }
    # Minimized is never saved as a state to come back to - nobody wants to
    # reopen an app into the taskbar.
    $state = if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized) { 'Maximized' } else { 'Normal' }
    return [pscustomobject]@{
        State  = $state
        X      = [int]$bounds.X
        Y      = [int]$bounds.Y
        Width  = [int]$bounds.Width
        Height = [int]$bounds.Height
    }
}

function Global:Restore-WindowPlacement {
    # Called before the window is shown. Does nothing at all unless there is
    # a saved placement that still makes sense on the monitors attached
    # right now, so the default (maximized) stands on a first run.
    $placement = $Global:App.SavedWindowPlacement
    if (-not $placement) { return }
    $width = [int]$placement.Width
    $height = [int]$placement.Height
    if ($width -lt 400 -or $height -lt 300) { return }
    $rect = New-Object System.Drawing.Rectangle([int]$placement.X, [int]$placement.Y, $width, $height)

    # The monitor this was last on may be gone - a laptop undocked, a screen
    # unplugged. Restoring onto coordinates that no screen covers any more
    # puts the window somewhere the user cannot reach or even see, and the
    # app looks like it failed to start. Enough of it has to land on a
    # screen that exists, or the saved placement is simply ignored.
    $visible = $false
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $overlap = [System.Drawing.Rectangle]::Intersect($screen.WorkingArea, $rect)
        if ($overlap.Width -ge 200 -and $overlap.Height -ge 100) { $visible = $true; break }
    }
    if (-not $visible) { return }

    $Global:App.Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $Global:App.Form.Bounds = $rect
    if ($placement.State -eq 'Maximized') {
        $Global:App.Form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
    }
    else {
        $Global:App.Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
}

function Global:Sort-Grid {
    # Called by the grid's own header click. The first click on a column
    # sorts it ascending, a second click on the SAME column reverses it -
    # the convention every other list in Windows follows.
    param([string]$ColumnName)
    if ($Global:App.GridSortColumn -eq $ColumnName) {
        $Global:App.GridSortAscending = -not $Global:App.GridSortAscending
    }
    else {
        $Global:App.GridSortColumn = $ColumnName
        $Global:App.GridSortAscending = $true
    }
    Update-Grid
}

function Global:Get-NavigableAppIndices {
    # The apps an editor's Previous/Next steps through: the main grid's
    # rows, in the order it shows them - search, problem filter and sort
    # all included. The editor and the deploy window each used to redo the
    # search on their own, which ignored the sort, and would have ignored
    # the filter drop-down next to the search box as well.
    $fromGrid = New-Object System.Collections.Generic.List[int]
    if ($Global:App.Grid -and $Global:App.Grid.Columns.Contains('Index')) {
        foreach ($row in $Global:App.Grid.Rows) {
            $v = $row.Cells['Index'].Value
            if ($null -ne $v) { $fromGrid.Add([int]$v) }
        }
    }
    if ($fromGrid.Count -gt 0) { return ,$fromGrid.ToArray() }
    # No grid rows to go by (a test harness, or startup): the catalog in
    # its own order, with the search applied the way the grid does.
    $navFilter = if ($Global:App.TxtSearch) { $Global:App.TxtSearch.Text.Trim().ToLower() } else { "" }
    $all = New-Object System.Collections.Generic.List[int]
    for ($vi = 0; $vi -lt $Global:App.Apps.Count; $vi++) {
        if ($navFilter) {
            $navHay = ("$($Global:App.Apps[$vi].appName) $($Global:App.Apps[$vi].wingetId)").ToLower()
            if ($navHay -notlike "*$navFilter*") { continue }
        }
        $all.Add($vi)
    }
    return ,$all.ToArray()
}

function Global:Get-GridFilterKinds {
    # The problem filter beside the search box: what each choice is called,
    # and which rows it keeps. A row here is the object Update-Grid binds,
    # so a choice can only look at what the grid itself shows.
    return @(
        @{ Name = "All apps";            Keep = { param($row) $true } }
        @{ Name = "Has a problem";       Keep = { param($row) $row.PackageMissing -or ($row.IntuneAudit -like "*issue*") -or ($row.IntuneAudit -like "Check failed*") } }
        @{ Name = "Differs from Intune"; Keep = { param($row) ($row.IntuneAudit -like "*issue*") -or ($row.IntuneAudit -like "Check failed*") } }
        @{ Name = "Not deployed";        Keep = { param($row) -not $row.HasAppId } }
        @{ Name = "Package missing";     Keep = { param($row) $row.PackageMissing } }
    )
}

function Global:Update-Grid {
    $filter = $Global:App.TxtSearch.Text.Trim().ToLower()
    # The drop-down beside the search box (Get-GridFilterKinds). "All apps",
    # or no drop-down at all (a test harness), keeps every row.
    $filterKindName = [string]$Global:App.GridFilterKind
    $keepRow = $null
    if ($filterKindName -and $filterKindName -ne "All apps") {
        $kind = @(Get-GridFilterKinds | Where-Object { $_.Name -eq $filterKindName }) | Select-Object -First 1
        if ($kind) { $keepRow = $kind.Keep }
    }
    $rows = New-Object System.Collections.Generic.List[Object]

    # The packages folder, listed once for this whole rebuild. Every
    # uncommon app asks Resolve-AppPackagePath where its package is, and
    # that used to walk the entire tree per app - on every rebuild, which
    # is every keystroke in the search box. One walk now, shared by all of
    # them, and rebuilt next time so a package built since still shows up.
    $packageIndexForRefresh = Get-PackageFolderIndex -Root (Get-AppFolder -Kind Packages)

    # What the user was looking at before this rebuild. Update-Grid runs
    # from 20-odd places - every save, deploy, sync, and every keystroke in
    # the search box - and rebinding DataSource drops the selection and
    # scrolls back to the top, so without this you lose your place in a
    # long catalog every time anything happens. Remembered by app NAME, not
    # row or catalog index: both of those shift when an app is added,
    # removed or sorted, and would quietly restore the selection onto a
    # DIFFERENT app than the one that was selected.
    $prevNames = @()
    $prevFirstRow = -1
    if ($Global:App.Grid -and $Global:App.Grid.Columns.Contains("AppName")) {
        $prevNames = @($Global:App.Grid.SelectedRows | ForEach-Object { [string]$_.Cells["AppName"].Value })
        $prevFirstRow = $Global:App.Grid.FirstDisplayedScrollingRowIndex
    }

    for ($i = 0; $i -lt $Global:App.Apps.Count; $i++) {
        $app = $Global:App.Apps[$i]
        if ($filter) {
            $hay = ("$($app.appName) $($app.wingetId)").ToLower()
            if ($hay -notlike "*$filter*") { continue }
        }
        $isUncommon = Test-AppIsUncommon -App $app
        # A blank Winget ID alone (what Test-AppIsUncommon actually checks)
        # doesn't distinguish "an uncommon WIN32 app that genuinely needs
        # its own .intunewin built" from "a non-Win32 app type (Company
        # Portal - Microsoft Store app (new), Microsoft 365 Apps, ...) that
        # never needs a package from this tool at all" - this app only ever
        # PACKAGES/DEPLOYS win32LobApp objects, so an app already known
        # (from a prior sync) to be some other Intune type was showing a
        # permanent, unfixable "Package missing" for something that isn't
        # actually missing - there was never going to be a package for it.
        # Same "Windows app (Win32)" friendly-label check already used
        # elsewhere (Get-FriendlyIntuneAppType collapses win32LobApp/
        # win32CatalogApp/windowsMobileMSI to this one string) - blank
        # intuneAppType (never synced, or genuinely not deployed yet) still
        # falls through to the normal uncommon/package check below, since
        # that's the only case where a real package IS actually expected.
        $isKnownNonWin32 = $app.intuneAppType -and $app.intuneAppType -ne "Windows app (Win32)"
        # A stored packagePath counts too, Winget ID or not. "Has a Winget
        # ID" normally means "deploys with the shared init.intunewin", so
        # this column ignored those apps entirely - which made a custom
        # package pointed at from the editor look like it had not been
        # saved, because nothing here ever asked about it.
        $needsPackageCheck = ($isUncommon -or $app.packagePath) -and -not $isKnownNonWin32
        # Only for the Status warning below - where the package is lives in
        # the app editor now (Package location), not in a column here.
        $pkg = if ($needsPackageCheck) { Resolve-AppPackagePath -AppName $app.appName -Uncommon $isUncommon -Index $packageIndexForRefresh -PackagePath $app.packagePath } else { $null }

        # For the Custom Config column only. Status used to repeat it as a
        # note, which said the same thing twice on one row.
        $hasCustomConfig = Test-AppHasCustomConfig -App $app

        $status = ""
        if (-not $app.appId) {
            $status = if ($app.metadata) { "Metadata saved - ready to deploy" } else { "No App ID" }
        }
        elseif ($needsPackageCheck -and -not $pkg.Found) {
            $status = "Package missing"
        }

        # An app that plainly has a Winget ID but was pointed at its own
        # .intunewin installs from that, not from the shared winget
        # wrapper - nothing else on the row says so. Only worth saying for
        # an app that WOULD otherwise use the wrapper: an app with no
        # Winget ID has its own package by definition, and its empty
        # Winget ID cell already shows that.
        if ($app.packagePath -and -not $isUncommon) {
            $status = if ($status) { "$status; Custom package" } else { "Custom package" }
        }

        $reqCount = @($app.requiredFor).Count
        $availCount = @($app.availableFor).Count
        $uninstCount = @($app.uninstallFor).Count
        $gridRow = [pscustomobject]@{
            AppName   = $app.appName
            WingetId  = $app.wingetId
            Type      = if ($app.intuneAppType) { $app.intuneAppType } else { "" }
            Version   = if ($app.intuneAppVersion) { $app.intuneAppVersion } else { "" }
            # Blank (not "Yes") for an app with no Winget ID:
            # Test-AppHasCustomConfig returns true for every such app
            # unconditionally (there's no computed default for it to have
            # deviated FROM), so "Yes" there would say nothing. Left meaning
            # one specific thing everywhere it's shown: a Winget app whose
            # saved settings were hand-edited away from what this tool
            # would otherwise default it to.
            CustomConfig = if ($isUncommon) { "" } elseif ($hasCustomConfig) { "Yes" } else { "No" }
            Groups    = "$reqCount / $availCount / $uninstCount"
            # Not columns - what sorting the Groups column orders by.
            Required  = $reqCount
            Available = $availCount
            Uninstall = $uninstCount
            Status    = $status
            IntuneAudit = if ($app.appId) { Get-LastAuditSummary -AppName $app.appName } else { "" }
            # Not columns - what the "Not deployed" and "Package missing"
            # filters ask. The second is its own flag because Status only
            # says "Package missing" once an app has an App ID; before
            # that it says "No App ID", and the package is just as missing.
            HasAppId  = [bool]$app.appId
            PackageMissing = [bool]($needsPackageCheck -and -not $pkg.Found)
            Index     = $i
        }
        # The problem filter, on the row as it will be shown - after the
        # Status and Last Audit it is judged by have been worked out.
        if ($keepRow -and -not (& $keepRow $gridRow)) { continue }
        $rows.Add($gridRow)
    }

    # Sorted here, before binding, rather than by the grid: a plain List
    # DataSource has no sorting of its own, and doing it here is what makes
    # the order stick through every later rebuild instead of silently
    # reverting to catalog order on the next keystroke or save.
    $sortColumn = [string]$Global:App.GridSortColumn
    # A sort saved against a column the grid no longer has (Package folder,
    # Uncommon, App ID, the three group counts) is dropped, not applied.
    if ($sortColumn -and $Global:App.Grid -and -not $Global:App.Grid.Columns.Contains($sortColumn)) { $sortColumn = "" }
    if ($sortColumn -and $rows.Count -gt 1) {
        # "Groups" is text ("10 / 0 / 0" would sort before "2 / 0 / 0"), so
        # it orders by the counts behind it: Required first, then the rest.
        $sortBy = if ($sortColumn -eq 'Groups') { @('Required', 'Available', 'Uninstall') } else { $sortColumn }
        $sorted = if ($Global:App.GridSortAscending) { @($rows | Sort-Object -Property $sortBy) }
                  else { @($rows | Sort-Object -Property $sortBy -Descending) }
        $rows = New-Object System.Collections.Generic.List[Object]
        foreach ($r in $sorted) { $rows.Add($r) }
    }

    $Global:App.Grid.DataSource = $null
    $Global:App.Grid.DataSource = $rows

    foreach ($col in $Global:App.Grid.Columns) {
        $glyph = if ($col.Name -eq $sortColumn) {
            if ($Global:App.GridSortAscending) { "Ascending" } else { "Descending" }
        } else { "None" }
        $col.HeaderCell.SortGlyphDirection = [System.Windows.Forms.SortOrder]$glyph
    }

    # Put the selection and the scroll position back where they were. An
    # app that the current filter hides has no row to go back to, which is
    # why this is best-effort and never forces a fallback selection: being
    # handed row 0 when your app scrolled out of view is how the wrong app
    # gets deployed.
    if ($prevNames.Count -gt 0 -and $Global:App.Grid.Rows.Count -gt 0) {
        # foreach, not a Where-Object pipeline: this runs on every refresh
        # over every row in the grid, and -contains against a handful of
        # remembered names is cheap next to the pipeline around it.
        $restored = New-Object System.Collections.Generic.List[object]
        foreach ($row in $Global:App.Grid.Rows) {
            if ($prevNames -contains [string]$row.Cells["AppName"].Value) { [void]$restored.Add($row) }
        }
        if ($restored.Count -gt 0) {
            # CurrentCell first, then the selection: assigning CurrentCell
            # selects its own row and drops everything else, which would
            # quietly shrink a restored multi-row selection back to one.
            # It also drives keyboard navigation, so it has to move with the
            # selection or the next arrow key jumps back to the old cursor.
            $Global:App.Grid.CurrentCell = $restored[0].Cells[0]
            $Global:App.Grid.ClearSelection()
            foreach ($row in $restored) { $row.Selected = $true }
        }
        else {
            # Nothing to restore, because what was selected is filtered out
            # or gone from the catalog. Binding a DataSource selects the
            # first row by itself, so this has to be undone deliberately:
            # otherwise the selection silently lands on whichever app
            # happens to sort first, and the next Deploy or Delete acts on
            # THAT one. Better to select nothing and make the user pick.
            $Global:App.Grid.ClearSelection()
        }
    }
    if ($prevFirstRow -ge 0 -and $prevFirstRow -lt $Global:App.Grid.Rows.Count) {
        $Global:App.Grid.FirstDisplayedScrollingRowIndex = $prevFirstRow
    }

    # The empty-catalog panel covers the grid only when the CATALOG is
    # empty, never when a search simply matches nothing - the search box is
    # right there to explain that case, and "Add the first app..." would be
    # the wrong advice while apps exist.
    if ($Global:App.PanelEmptyCatalog) {
        $catalogIsEmpty = ($Global:App.Apps.Count -eq 0)
        $Global:App.PanelEmptyCatalog.Visible = $catalogIsEmpty
        if ($catalogIsEmpty) {
            $Global:App.LblEmptyPath.Text = "This catalog folder: $($Global:App.LinkedFilePath)"
        }
    }

    # One pass for all three totals. This was three separate pipelines over
    # the whole catalog, each building a ForEach-Object and a Measure-Object
    # for a running total - three walks and six pipelines per refresh, for
    # three numbers that come out of the same single walk.
    $reqTotal = 0
    $availTotal = 0
    $uninstTotal = 0
    foreach ($app in $Global:App.Apps) {
        $reqTotal    += @($app.requiredFor).Count
        $availTotal  += @($app.availableFor).Count
        $uninstTotal += @($app.uninstallFor).Count
    }
    $dirty = if ($Global:App.UnsavedChangesBox.Value) { "  *unsaved changes*" } else { "" }
    # While a filter is on, the count has to be what you can actually see.
    # It read "120 apps" over a grid showing three of them, which is the
    # one moment that number is worth reading and the one moment it was
    # wrong. The assignment totals below stay catalog-wide on purpose -
    # they answer "what does this catalog deploy", not "what is on screen".
    $countText = if ($filter -or $keepRow) { "Showing $($rows.Count) of $($Global:App.Apps.Count) apps" } else { "$($Global:App.Apps.Count) apps" }
    if ($keepRow) { $countText += " ($filterKindName)" }
    Set-Status "$countText  |  $reqTotal required, $availTotal available, $uninstTotal uninstall assignments  |  $($Global:App.LinkedFilePath)$dirty"
}

function Global:Get-SelectedAppIndex {
    if ($Global:App.Grid.SelectedRows.Count -eq 0) { return $null }
    return [int]$Global:App.Grid.SelectedRows[0].Cells["Index"].Value
}

function Global:Get-SelectedAppIndices {
    return @($Global:App.Grid.SelectedRows | ForEach-Object { [int]$_.Cells["Index"].Value })
}

function Global:Show-LastAuditDetail {
    param([string]$AppName)

    if (-not $Global:App.LastAuditResults.ContainsKey($AppName)) {
        [System.Windows.Forms.MessageBox]::Show("`"$AppName`" hasn't been checked against Intune yet this session. Run `"Intune Audit...`" (or open `"Deploy to Intune...`" for it, which checks Metadata and Dependencies automatically) to see where it stands.", "Never audited - $AppName", "OK", "Information") | Out-Null
        return
    }

    $entry = $Global:App.LastAuditResults[$AppName]
    $age = Get-FriendlyAge -Timestamp $entry.Timestamp
    $fields = @(
        @{ Label = "Metadata"; Value = $entry.Metadata }
        @{ Label = "Groups"; Value = $entry.Groups }
        @{ Label = "Dependencies"; Value = $entry.Dependencies }
        @{ Label = "Unknown assignments"; Value = $entry.Unknown }
    )

    # A window, not a MessageBox: this is where "Groups: 1 differ" is read,
    # and a MessageBox could only say it and offer OK. The fix is one of
    # two directions, and only you know which side is right - so both are
    # here, the same actions the audit window and the grid's menu have.
    $appIndex = -1
    for ($ai = 0; $ai -lt $Global:App.Apps.Count; $ai++) {
        if ([string]$Global:App.Apps[$ai].appName -eq $AppName) { $appIndex = $ai; break }
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Last audit - $AppName ($age)"
    $dlg.ClientSize = New-Object System.Drawing.Size(620, 300)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $grid = New-Object System.Windows.Forms.DataGridView
    Set-AppGridStyle -Grid $grid
    $grid.Location = New-Object System.Drawing.Point(15,15)
    $grid.Size = New-Object System.Drawing.Size(590,170)
    $grid.ReadOnly = $true
    $grid.AllowUserToDeleteRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.ColumnHeadersVisible = $false
    $grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells
    $colCheck = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCheck.Name = "Check"
    $colCheck.Width = 160
    $colCheck.DefaultCellStyle.Font = New-Object System.Drawing.Font($dlg.Font, [System.Drawing.FontStyle]::Bold)
    [void]$grid.Columns.Add($colCheck)
    $colResult = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colResult.Name = "Result"
    $colResult.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $colResult.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
    [void]$grid.Columns.Add($colResult)
    foreach ($f in $fields) {
        $displayVal = if ($null -ne $f.Value) { [string]$f.Value } else { "(not checked this session)" }
        # One group list per line (Format-GroupFieldDiffs joins them with
        # "; " to fit a single cell elsewhere).
        [void]$grid.Rows.Add($f.Label, ($displayVal -replace '; ', "`r`n"))
    }
    # The audit window's colours: green OK, red could-not-check, orange
    # for a difference.
    $grid.Add_CellFormatting({
        param($gridSender, $e)
        if ($e.ColumnIndex -ne 1) { return }
        $val = [string]$e.Value
        if ($val -eq "OK") { $e.CellStyle.ForeColor = [System.Drawing.Color]::SeaGreen }
        elseif ($val -like "Failed*") { $e.CellStyle.ForeColor = [System.Drawing.Color]::Firebrick }
        elseif ($val -and $val -notlike "(not checked*") { $e.CellStyle.ForeColor = [System.Drawing.Color]::DarkOrange }
    }.GetNewClosure())
    $dlg.Controls.Add($grid)
    $dlg.Add_Shown({ $grid.ClearSelection() }.GetNewClosure())

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "Something differs? Pull from Intune if Intune is right. If the catalog is right: Push groups for Groups and Unknown assignments, Push metadata for Metadata and Dependencies."
    $lblHint.ForeColor = [System.Drawing.Color]::DimGray
    $lblHint.Location = New-Object System.Drawing.Point(15,192)
    $lblHint.Size = New-Object System.Drawing.Size(590,44)
    $dlg.Controls.Add($lblHint)

    $btnPull = New-Object System.Windows.Forms.Button
    $btnPull.Text = "Pull from Intune..."
    $btnPull.Location = New-Object System.Drawing.Point(15,254)
    $btnPull.Size = New-Object System.Drawing.Size(150,32)
    $dlg.Controls.Add($btnPull)

    $btnPushGroups = New-Object System.Windows.Forms.Button
    $btnPushGroups.Text = "Push groups..."
    $btnPushGroups.Location = New-Object System.Drawing.Point(173,254)
    $btnPushGroups.Size = New-Object System.Drawing.Size(130,32)
    $dlg.Controls.Add($btnPushGroups)

    $btnPushMetadata = New-Object System.Windows.Forms.Button
    $btnPushMetadata.Text = "Push metadata..."
    $btnPushMetadata.Location = New-Object System.Drawing.Point(311,254)
    $btnPushMetadata.Size = New-Object System.Drawing.Size(150,32)
    $dlg.Controls.Add($btnPushMetadata)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(525,254)
    $btnClose.Size = New-Object System.Drawing.Size(80,32)
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnClose)
    $dlg.CancelButton = $btnClose

    $tips = New-Object System.Windows.Forms.ToolTip
    $tips.SetToolTip($btnPull, "Intune is right: update the catalog to match it. Shows what would change and asks first.")
    $tips.SetToolTip($btnPushGroups, "The catalog is right about groups: send them to Intune. Fixes Groups and Unknown assignments.")
    $tips.SetToolTip($btnPushMetadata, "The catalog is right about metadata: opens the update window, which compares with Intune, keeps the catalog's value for every field that differs, and sends nothing until you click Update Metadata.")

    # Gone from the catalog since it was audited - nothing to act on.
    if ($appIndex -lt 0) {
        $btnPull.Enabled = $false
        $btnPushGroups.Enabled = $false
        $btnPushMetadata.Enabled = $false
    }

    # Which action was picked, run once this window has closed - the
    # results shown here are about to be out of date, and the action's own
    # window should not open on top of a popup that no longer means much.
    $pickedBox = @{ Action = $null }
    $btnPull.Add_Click({ $pickedBox.Action = 'Pull'; $dlg.Close() }.GetNewClosure())
    $btnPushGroups.Add_Click({ $pickedBox.Action = 'PushGroups'; $dlg.Close() }.GetNewClosure())
    $btnPushMetadata.Add_Click({ $pickedBox.Action = 'PushMetadata'; $dlg.Close() }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
    $dlg.Dispose()

    switch ($pickedBox.Action) {
        'Pull'         { Show-SyncMetadataDialog -ScopedIndices @($appIndex) }
        'PushGroups'   { Invoke-QuickAssignGroups -Index $appIndex }
        'PushMetadata' { Invoke-QuickPushMetadata -Index $appIndex }
        default        { return }
    }
    Update-Grid
    Set-Status "Done with `"$AppName`" - run the audit on it again to confirm Intune and the catalog now match."
}
