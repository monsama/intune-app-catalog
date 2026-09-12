function Show-AppRegistrationGuideDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Set up the Entra ID app registration"
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 460)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $txtGuide = New-Object System.Windows.Forms.TextBox
    $txtGuide.Location = New-Object System.Drawing.Point(15,15)
    $txtGuide.Size = New-Object System.Drawing.Size(530,390)
    $txtGuide.Multiline = $true
    $txtGuide.ReadOnly = $true
    $txtGuide.ScrollBars = "Vertical"
    $txtGuide.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $txtGuide.Text = @"
This is a one-time setup, done once per tenant/environment - not something
this tool automates. Granting an application broad tenant permissions is
worth doing deliberately through the portal's own review screens, not
silently via a script, even though only a Global/Privileged Role Admin
could run either path.

1. In the Entra admin center, go to "App registrations" and create a new
   registration (or use an existing one your organization has already
   approved for this purpose).

2. Note its "Application (client) ID" and "Directory (tenant) ID" - enter
   both into the fields in the Settings dialog.

3. Open the app registration, go to:
   API permissions > Add a permission > Microsoft Graph >
   Application permissions (NOT Delegated) - and add:
     - DeviceManagementApps.ReadWrite.All
     - Group.ReadWrite.All
     - User.Read.All
     - Device.Read.All
     - Directory.Read.All

4. Click "Grant admin consent for [tenant]" and confirm every permission
   shows "Granted."
   Requires a Global Administrator or Privileged Role Administrator.

5. Back in Settings, use "Pick certificate..." or "Generate certificate...",
   then "Upload certificate..." to link this tool to that app registration
   - or export/upload the certificate through the portal yourself instead,
   if you'd rather do that step there too.
"@
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

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
}
