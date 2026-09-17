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
    elseif ($RawMessage -match '\bforbidden\b|\b403\b|insufficient privileges') {
        $summary = "Microsoft Graph refused this request - the app registration is likely missing a required permission (see Settings > First time? Setup guide...)."
    }
    if (-not $summary) { return $RawMessage }
    return "$summary`n`n(Raw error: $RawMessage)"
}

function Global:Get-GraphRunspaceErrorMessage {
    # Shared by every Timer-polled runspace fetch in this file - builds
    # the same "message [file:line]" detail every one of them wants for
    # diagnosing a genuinely unexpected failure, then routes it through
    # ConvertTo-FriendlyGraphError so the common, already-recognized ones
    # lead with something a non-developer can actually act on.
    param($ErrorRecords)
    $raw = (@($ErrorRecords) | ForEach-Object {
        $where = $_.InvocationInfo.PositionMessage
        if ($where) { "$($_.ToString()) [$($where.Trim())]" } else { $_.ToString() }
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
    $btnOk.Location = New-Object System.Drawing.Point(408,275)
    $btnOk.Size = New-Object System.Drawing.Size(85,28)
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(503,275)
    $btnCancel.Size = New-Object System.Drawing.Size(85,28)
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
    $StatusLabel.ForeColor = [System.Drawing.Color]::Firebrick
    $StatusLabel.Text = "Failed - see the log below for details."
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
    $LogBox.SelectionStart = $LogBox.TextLength
    $LogBox.SelectionLength = 0
    $LogBox.SelectionColor = $color
    $LogBox.AppendText($Text)
    $LogBox.ScrollToCaret()
    if ($MirrorToMainLog) {
        Write-Log $Text $color
    }
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
        if ($b -is [System.Windows.Forms.TextBox]) {
            # a single-line text box keeps its own height - center it in the row instead
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

function Global:New-GridColumn {
    # -Font: the grid's font, used to give the column a MinimumWidth that
    # always fits its own header text (plus cell padding and the sort
    # glyph) - Fill mode alone happily squeezes a narrow column down until
    # "Required" reads "Requirec". -MinimumWidth raises that floor further,
    # for columns whose VALUES need more room than their header (App ID).
    param($Name, $Header, $Width = 100, $FillWeight = 20, [System.Drawing.Font]$Font, [int]$MinimumWidth = 0)
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $Name
    $col.HeaderText = $Header
    $col.DataPropertyName = $Name
    $col.FillWeight = $FillWeight
    if ($Font) {
        $headerWidth = [System.Windows.Forms.TextRenderer]::MeasureText($Header, $Font).Width + 24
        $col.MinimumWidth = [Math]::Max($headerWidth, $MinimumWidth)
    }
    elseif ($MinimumWidth -gt 0) {
        $col.MinimumWidth = $MinimumWidth
    }
    return $col
}

function Global:Update-Grid {
    $filter = $Global:App.TxtSearch.Text.Trim().ToLower()
    $rows = New-Object System.Collections.Generic.List[Object]

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
        $needsPackageCheck = $isUncommon -and -not $isKnownNonWin32
        # Resolved once and reused for both the Status warning and the
        # Folder column below, rather than searching the filesystem twice
        # per uncommon app on every grid refresh.
        $pkg = if ($needsPackageCheck) { Resolve-AppPackagePath -AppName $app.appName -Uncommon $true } else { $null }

        # Computed once, reused for both the Status note below and the
        # separate Custom Config column - same check, no reason to run
        # Test-AppHasCustomConfig twice per app on every grid refresh.
        $hasCustomConfig = Test-AppHasCustomConfig -App $app

        $status = ""
        if (-not $app.appId) {
            $status = if ($app.metadata) { "Metadata saved - ready to deploy" } else { "No App ID" }
        }
        elseif ($needsPackageCheck -and -not $pkg.Found) {
            $status = "Package missing"
        }

        # A Winget app (has a Winget ID, so NOT uncommon) whose saved
        # metadata deviates from what this tool would default it to - a
        # custom install/uninstall command, detection rule, requirements,
        # etc. The separate "Custom Config" column already tracks this as
        # a plain Yes/No, but that column has no highlighting and is easy
        # to scroll past; surfacing it here too puts it next to every
        # other actionable note this column already carries. Composed
        # with whatever else Status already says (semicolon-joined)
        # rather than replacing it, so a Winget app that's ALSO missing
        # its App ID still shows both.
        if (-not $isUncommon -and $hasCustomConfig) {
            $status = if ($status) { "$status; Custom config" } else { "Custom config" }
        }

        $folderDisplay = ""
        if ($needsPackageCheck) {
            $folderDisplay = if ($pkg.Found) { Split-Path $pkg.Path -Parent } else { "(not found)" }
        }
        elseif ($isUncommon -and $isKnownNonWin32) {
            $folderDisplay = "(not applicable - $($app.intuneAppType))"
        }

        $rows.Add([pscustomobject]@{
            AppName   = $app.appName
            WingetId  = $app.wingetId
            Type      = if ($app.intuneAppType) { $app.intuneAppType } else { "" }
            Version   = if ($app.intuneAppVersion) { $app.intuneAppVersion } else { "" }
            Uncommon  = if ($isUncommon) { "Yes" } else { "" }
            # Blank (not "Yes") for an Uncommon app: Test-AppHasCustomConfig
            # returns true for every Uncommon app unconditionally (there's
            # no computed default for it to have deviated FROM), so showing
            # "Yes" here just echoed the Uncommon column back with no new
            # information. Left meaning one specific thing everywhere it's
            # shown: a Winget app whose saved settings were hand-edited
            # away from what this tool would otherwise default it to.
            CustomConfig = if ($isUncommon) { "" } elseif ($hasCustomConfig) { "Yes" } else { "No" }
            Folder    = $folderDisplay
            Required  = @($app.requiredFor).Count
            Available = @($app.availableFor).Count
            Uninstall = @($app.uninstallFor).Count
            AppId     = if ($app.appId) { $app.appId } else { "(none yet)" }
            Status    = $status
            IntuneAudit = if ($app.appId) { Get-LastAuditSummary -AppName $app.appName } else { "" }
            Index     = $i
        })
    }

    $Global:App.Grid.DataSource = $null
    $Global:App.Grid.DataSource = $rows

    $reqTotal   = ($Global:App.Apps | ForEach-Object { @($_.requiredFor).Count } | Measure-Object -Sum).Sum
    $availTotal = ($Global:App.Apps | ForEach-Object { @($_.availableFor).Count } | Measure-Object -Sum).Sum
    $uninstTotal= ($Global:App.Apps | ForEach-Object { @($_.uninstallFor).Count } | Measure-Object -Sum).Sum
    $dirty = if ($Global:App.UnsavedChangesBox.Value) { "  *unsaved changes*" } else { "" }
    Set-Status "$($Global:App.Apps.Count) apps  |  $reqTotal required, $availTotal available, $uninstTotal uninstall assignments  |  $($Global:App.LinkedFilePath)$dirty"
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
    $lines = New-Object System.Collections.Generic.List[string]
    $fields = @(
        @{ Label = "Metadata"; Value = $entry.Metadata }
        @{ Label = "Groups"; Value = $entry.Groups }
        @{ Label = "Dependencies"; Value = $entry.Dependencies }
        @{ Label = "Unknown assignments"; Value = $entry.Unknown }
    )
    foreach ($f in $fields) {
        $displayVal = if ($null -ne $f.Value) { $f.Value } else { "(not checked this session)" }
        $lines.Add("$($f.Label): $displayVal")
    }
    [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n`r`n"), "Last audit - $AppName ($age)", "OK", "Information") | Out-Null
}
