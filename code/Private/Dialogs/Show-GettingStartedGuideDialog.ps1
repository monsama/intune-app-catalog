function Global:Show-GettingStartedGuideDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Getting started"
    $dlg.ClientSize = New-Object System.Drawing.Size(620, 560)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    # RichTextBox instead of a plain TextBox - lets each block below get
    # its own font/color (section headers bolded and in the app's own
    # accent blue, asides in italic gray) instead of one flat wall of
    # same-size, same-color text. Set-ThemeRecursive (GuiHelpers.ps1) has
    # no case for "RichTextBox" at all, so BackColor/ForeColor are set
    # explicitly here (matching the palette a plain TextBox would have
    # gotten) and nothing further down overwrites the per-block colors set
    # below.
    $txtGuide = New-Object System.Windows.Forms.RichTextBox
    $txtGuide.Location = New-Object System.Drawing.Point(15,15)
    $txtGuide.Size = New-Object System.Drawing.Size(590,490)
    $txtGuide.ReadOnly = $true
    $txtGuide.ScrollBars = "Vertical"
    $txtGuide.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
    $txtGuide.BackColor = $Global:App.LightPalette.FieldBack
    $txtGuide.ForeColor = $Global:App.LightPalette.ControlFore
    $txtGuide.DetectUrls = $false

    $fontBody   = New-Object System.Drawing.Font("Segoe UI", 9)
    $fontHeader = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $fontNote   = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
    $colorBody   = $Global:App.LightPalette.ControlFore
    $colorHeader = $Global:App.LightPalette.SelectionBack
    $colorNote   = [System.Drawing.Color]::FromArgb(110,114,120)

    # {Type; Text} blocks, in reading order - Header/SubNote/Note get their
    # own font+color below; Body/Intro just inherit the plain reading font.
    # Kept as separate blocks (not one big here-string like this dialog used
    # to be) specifically so headers can be visually pulled out from the
    # step-by-step instructions under them - the wall-of-text version had
    # no way to tell "this is a new section" from "this is still the same
    # paragraph" at a glance.
    $blocks = @(
        @{ Type = "Intro"; Text = "This app manages a local catalog (one JSON file per app) alongside whatever's actually deployed in Intune. The two aren't the same thing until you make them match - here's how, for the situations that come up most." }

        @{ Type = "Header"; Text = "Before any of this: connect to Microsoft Graph" }
        @{ Type = "Body"; Text = "Everything below talks to Intune, so none of it works until this app can sign in. One-time, per tenant:" }
        @{ Type = "Body"; Text = "1. Open `"Settings...`" (toolbar). If anything here says a PowerShell module is missing, `"More actions > Verify > Prerequisites...`" installs it.`n2. If your organization hasn't already set up an app registration for this tool, click `"First time? Setup guide...`" inside Settings first - that's the Entra ID / permissions side, a separate topic from everything else in this guide.`n3. Fill in Tenant ID, Client ID, and a certificate (pick an existing one or generate a new one right there), click `"Test connection`" to confirm it actually works, then `"Save.`"" }
        @{ Type = "Note"; Text = "A banner across the top of the Catalog tab says outright when this hasn't been done yet, so it's hard to miss - but the two workflows below assume it's already sorted." }

        @{ Type = "Header"; Text = "Catalog is empty, Intune already has apps" }
        @{ Type = "SubNote"; Text = "(a fresh checkout of an existing catalog folder, or your first time using this catalog against an established tenant)" }
        @{ Type = "Body"; Text = "1. Open `"Intune sync check...`" (More actions > Intune).`n2. Click `"Refresh from Intune`" if the grid is empty - every app in Intune will show up as `"Not in catalog,`" since nothing's been imported yet.`n3. Bring them in one of two ways, mixed as you like:`n     - Tick the ones you want (`"Select all`" / `"Select none`" help), then `"Add checked to catalog`" - fast, just records the name and App ID.`n     - Or `"Add to catalog...`" on a single row instead - opens the full App Editor for that app so you can also set its winget ID and Required/Available/Uninstall groups right away.`n4. Anything added the fast way can be filled in later - open it in the App Editor whenever you're ready to add a winget ID or groups." }

        @{ Type = "Header"; Text = "Catalog has apps, nothing deployed to Intune yet" }
        @{ Type = "SubNote"; Text = "(building out a new catalog from scratch, or bringing a batch of planned apps live for the first time)" }
        @{ Type = "Body"; Text = "1. Add each app via `"+ Add app...`" - just a name to start; a winget ID is optional (leave it blank for an app with its own custom install script instead).`n2. Use `"Deploy to Intune...`" from inside the app editor to create it in Intune (or `"Batch deploy...`" from the toolbar to do several apps at once, in dependency order).`n3. Assign groups either while deploying, or afterward via `"Push groups to Intune (single app)...`" / `"Push groups to Intune (multiple apps)...`"." }

        @{ Type = "Header"; Text = "Keeping the two in sync going forward" }
        @{ Type = "Body"; Text = "- `"Intune sync check...`" (above) is also the tool for ongoing drift, not just first-time import - it flags apps renamed in Intune since, and catalog apps whose App ID no longer exists in Intune at all (deleted outside this tool), not just brand-new ones.`n- The `"Check Intune drift on start`" toggle (toolbar, Sync group) runs that same check quietly once every time the app opens, and only says something if it actually finds a difference - useful if more than one person works from this catalog, so drift doesn't sit unnoticed until something fails.`n- `"Pull metadata and groups from Intune...`" goes the other direction - updates the LOCAL catalog to match what's live in Intune for apps that already have an App ID, for when Intune is the one with the current truth (e.g. someone changed something there directly)." }
    )

    # Parent, font, and native handle all settled BEFORE any formatting is
    # applied. On .NET Framework (Windows PowerShell 5.1) SelectionFont/
    # SelectionColor set before the handle exists are silently dropped, and
    # a later ambient font change (e.g. being added to the dialog) re-fonts
    # all existing text - either way the guide came out as plain text there,
    # while PowerShell 7 kept the formatting.
    $txtGuide.Font = $fontBody
    $dlg.Controls.Add($txtGuide)
    [void]$txtGuide.Handle

    $isFirstBlock = $true
    foreach ($block in $blocks) {
        if (-not $isFirstBlock) {
            # Extra blank line before a new section header, so it reads as
            # a break even before its bold/color registers - a single blank
            # line otherwise, same as a paragraph break.
            $sep = if ($block.Type -eq "Header") { "`r`n`r`n`r`n" } else { "`r`n`r`n" }
            $txtGuide.AppendText($sep)
        }
        $isFirstBlock = $false

        # Style applies at the caret - put it at the end first, same order
        # Write-DialogLogLine uses.
        $txtGuide.SelectionStart = $txtGuide.TextLength
        $txtGuide.SelectionLength = 0
        switch ($block.Type) {
            "Header"  { $txtGuide.SelectionFont = $fontHeader; $txtGuide.SelectionColor = $colorHeader }
            "SubNote" { $txtGuide.SelectionFont = $fontNote;   $txtGuide.SelectionColor = $colorNote }
            "Note"    { $txtGuide.SelectionFont = $fontNote;   $txtGuide.SelectionColor = $colorNote }
            default   { $txtGuide.SelectionFont = $fontBody;   $txtGuide.SelectionColor = $colorBody }
        }
        $txtGuide.AppendText((ConvertTo-DisplayLineEndings $block.Text))
    }

    # AppendText leaves the caret (and the visible scroll position) at the
    # very end - without resetting this, the dialog would open already
    # scrolled to the bottom instead of showing the intro first.
    $txtGuide.SelectionStart = 0
    $txtGuide.SelectionLength = 0
    $txtGuide.ScrollToCaret()

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(515,513)
    $btnClose.Size = New-Object System.Drawing.Size(90,32)
    $dlg.Controls.Add($btnClose)
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnClose

    # $txtGuide is first in tab order, so it's what gets focus by default
    # when the form is shown - pointed at Close instead, same as before.
    $dlg.Add_Shown({ $btnClose.Focus() }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
