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

function Global:Set-Theme {
    param([System.Windows.Forms.Control]$Control)
    Set-ThemeRecursive -Ctrl $Control -Palette $Global:App.LightPalette
}

function Global:Set-ThemeRecursive {
    param($Ctrl, $Palette)

    switch ($Ctrl.GetType().Name) {
        "Form" {
            $Ctrl.BackColor = $Palette.FormBack
            $Ctrl.ForeColor = $Palette.ControlFore
        }
        { $_ -in @("Panel","GroupBox","TabPage","FlowLayoutPanel","TabControl") } {
            $Ctrl.BackColor = $Palette.FormBack
            $Ctrl.ForeColor = $Palette.ControlFore
        }
        "Label" {
            $Ctrl.ForeColor = $Palette.ControlFore
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
    $dlg.Text = $Title
    $dlg.ClientSize = New-Object System.Drawing.Size(420, 320)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Prompt
    $lbl.Location = New-Object System.Drawing.Point(12,12)
    $lbl.Size = New-Object System.Drawing.Size(396,40)
    $dlg.Controls.Add($lbl)

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location = New-Object System.Drawing.Point(12,55)
    $lst.Size = New-Object System.Drawing.Size(396,210)
    $lst.Items.AddRange($Items)
    if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = 0 }
    $dlg.Controls.Add($lst)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Select"
    $btnOk.Location = New-Object System.Drawing.Point(228,275)
    $btnOk.Size = New-Object System.Drawing.Size(85,28)
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(323,275)
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

    foreach ($b in $Buttons) {
        $b.AutoSize = $true
        $b.Padding = New-Object System.Windows.Forms.Padding(8,3,8,3)
        $b.Margin = New-Object System.Windows.Forms.Padding(0,0,4,0)
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
    param($Name, $Header, $Width = 100, $FillWeight = 20)
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $Name
    $col.HeaderText = $Header
    $col.DataPropertyName = $Name
    $col.FillWeight = $FillWeight
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
