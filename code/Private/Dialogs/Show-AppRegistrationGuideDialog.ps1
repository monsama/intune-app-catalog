function Global:Show-AppRegistrationGuideDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Set up the Entra ID app registration"
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 460)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    # RichTextBox, not a plain TextBox - same reasoning as
    # Show-GettingStartedGuideDialog's own version of this: per-block
    # font/color (the caution note in italic gray, the permission list as
    # real indented bullets) instead of one flat wall of text. Set-
    # ThemeRecursive has no case for "RichTextBox" at all, so BackColor/
    # ForeColor are set explicitly here rather than left to the theme pass.
    $txtGuide = New-Object System.Windows.Forms.RichTextBox
    $txtGuide.Location = New-Object System.Drawing.Point(15,15)
    $txtGuide.Size = New-Object System.Drawing.Size(530,390)
    $txtGuide.ReadOnly = $true
    $txtGuide.ScrollBars = "Vertical"
    $txtGuide.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
    $txtGuide.BackColor = $Global:App.LightPalette.FieldBack
    $txtGuide.ForeColor = $Global:App.LightPalette.ControlFore
    $txtGuide.DetectUrls = $false

    $fontBody = New-Object System.Drawing.Font("Segoe UI", 9)
    $fontNote = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
    $colorBody = $Global:App.LightPalette.ControlFore
    $colorNote = [System.Drawing.Color]::FromArgb(110,114,120)

    # {Type; Text} blocks, in reading order - same pattern as
    # Show-GettingStartedGuideDialog, including its plain (not bolded)
    # step numbering, so the two guides read consistently side by side.
    # "Bullets" renders each line as its own indented, bulleted line
    # instead of a single run-on paragraph.
    $blocks = @(
        @{ Type = "Body"; Text = "This is a one-time setup, done once per tenant/environment - not something this tool automates." }
        @{ Type = "Note"; Text = "Granting an application broad tenant permissions is worth doing deliberately through the portal's own review screens, not silently via a script, even though only a Global/Privileged Role Admin could run either path." }
        @{ Type = "Step"; Number = "1."; Text = "In the Entra admin center, go to `"App registrations`" and create a new registration (or use an existing one your organization has already approved for this purpose)." }
        @{ Type = "Step"; Number = "2."; Text = "Note its `"Application (client) ID`" and `"Directory (tenant) ID`" - enter both into the fields in the Settings dialog." }
        @{ Type = "Step"; Number = "3."; Text = "Open the app registration, go to:`nAPI permissions > Add a permission > Microsoft Graph > Application permissions (NOT Delegated) - and add:" }
        @{ Type = "Bullets"; Items = @("DeviceManagementApps.ReadWrite.All", "Group.ReadWrite.All", "User.Read.All", "Device.Read.All", "Directory.Read.All") }
        @{ Type = "Step"; Number = "4."; Text = "Click `"Grant admin consent for [tenant]`" and confirm every permission shows `"Granted.`" Requires a Global Administrator or Privileged Role Administrator." }
        @{ Type = "Step"; Number = "5."; Text = "Back in Settings, use `"Pick certificate...`" or `"Generate certificate...`", then `"Upload certificate...`" to link this tool to that app registration - or export/upload the certificate through the portal yourself instead, if you'd rather do that step there too." }
    )

    $isFirstBlock = $true
    foreach ($block in $blocks) {
        if (-not $isFirstBlock) { $txtGuide.AppendText("`r`n`r`n") }
        $isFirstBlock = $false

        switch ($block.Type) {
            "Note" {
                $txtGuide.SelectionFont = $fontNote
                $txtGuide.SelectionColor = $colorNote
                $txtGuide.AppendText((ConvertTo-DisplayLineEndings $block.Text))
            }
            "Step" {
                # Same plain-weight numbering as Getting started's own
                # numbered steps - bolding just the number read as
                # inconsistent with that dialog once the two sat side by
                # side (per the user, "not fat numbers").
                $txtGuide.SelectionFont = $fontBody
                $txtGuide.SelectionColor = $colorBody
                $txtGuide.AppendText((ConvertTo-DisplayLineEndings "$($block.Number) $($block.Text)"))
            }
            "Bullets" {
                $txtGuide.SelectionFont = $fontBody
                $txtGuide.SelectionColor = $colorBody
                $lines = @($block.Items | ForEach-Object { "     - $_" })
                $txtGuide.AppendText((ConvertTo-DisplayLineEndings ($lines -join "`n")))
            }
            default {
                $txtGuide.SelectionFont = $fontBody
                $txtGuide.SelectionColor = $colorBody
                $txtGuide.AppendText((ConvertTo-DisplayLineEndings $block.Text))
            }
        }
    }

    # AppendText leaves the caret (and scroll position) at the end -
    # reset so the dialog opens showing the intro, not the last step.
    $txtGuide.SelectionStart = 0
    $txtGuide.SelectionLength = 0
    $txtGuide.ScrollToCaret()

    $dlg.Controls.Add($txtGuide)

    $btnOpenPortal = New-Object System.Windows.Forms.Button
    $btnOpenPortal.Text = "Open Entra admin center"
    $btnOpenPortal.Location = New-Object System.Drawing.Point(15,415)
    $btnOpenPortal.Size = New-Object System.Drawing.Size(190,30)
    $dlg.Controls.Add($btnOpenPortal)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(455,415)
    $btnClose.Size = New-Object System.Drawing.Size(90,30)
    $dlg.Controls.Add($btnClose)

    $btnOpenPortal.Add_Click({
        try { Start-Process "https://entra.microsoft.com" } catch { }
    })
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnClose

    # $txtGuide is first in tab order, so it's what the form focuses by
    # default when first shown - a known WinForms quirk selects an entire
    # TextBox's text the moment it receives focus that way, visible as
    # the whole guide highlighted blue on open (confirmed live). It's
    # read-only and never meant to be typed into, so just point initial
    # focus at Close instead of fighting the selection after the fact.
    $dlg.Add_Shown({ $btnClose.Focus() }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
