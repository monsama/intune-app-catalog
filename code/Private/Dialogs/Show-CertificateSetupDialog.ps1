function Global:Show-CertificateSetupDialog {
    # Plain local aliases - see note in Start-IntuneAppLookup. Even a single
    # level of GetNewClosure() (like $btnUpload.Add_Click below) does not
    # reliably see $Script:-qualified variables directly, only plain ones.
    $certUploadScript = $Global:App.EmbeddedCertUploadScript

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Settings - Microsoft Graph Connection"
    # Height trimmed from 1034 to 955 - tracing every $y increment below
    # shows the last row of real content (Save/Close) lands at y=920 and
    # is ~30px tall, ending around y=950; the extra 84px past that was
    # pure dead space at the bottom of the window, confirmed against a
    # live screenshot showing exactly that empty gap below the buttons.
    $dlg.ClientSize = New-Object System.Drawing.Size(930, 658)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $y = 15
    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "These identify the Entra ID app registration used for app-only sign-in (Launch/Assign and the App ID lookup). Changes here are saved to intune-deployment-settings.json next to this script."
    $lblIntro.Location = New-Object System.Drawing.Point(15,$y)
    $lblIntro.Size = New-Object System.Drawing.Size(900,45)
    $dlg.Controls.Add($lblIntro)
    $y += 55

    $btnSetupGuide = New-Object System.Windows.Forms.Button
    $btnSetupGuide.Text = "First time? Setup guide..."
    $btnSetupGuide.Location = New-Object System.Drawing.Point(15,$y)
    $btnSetupGuide.Size = New-Object System.Drawing.Size(900,28)
    $dlg.Controls.Add($btnSetupGuide)
    $y += 36

    $lblTenant = New-Object System.Windows.Forms.Label
    $lblTenant.Text = "Tenant ID"
    $lblTenant.Location = New-Object System.Drawing.Point(15,$y)
    $lblTenant.AutoSize = $true
    $dlg.Controls.Add($lblTenant)
    $y += 20

    $txtTenant = New-Object System.Windows.Forms.TextBox
    $txtTenant.Location = New-Object System.Drawing.Point(15,$y)
    $txtTenant.Size = New-Object System.Drawing.Size(900,24)
    $txtTenant.Text = $Global:App.GraphTenantId
    $dlg.Controls.Add($txtTenant)
    $y += 34

    $lblClient = New-Object System.Windows.Forms.Label
    $lblClient.Text = "Client (Application) ID"
    $lblClient.Location = New-Object System.Drawing.Point(15,$y)
    $lblClient.AutoSize = $true
    $dlg.Controls.Add($lblClient)
    $y += 20

    $txtClient = New-Object System.Windows.Forms.TextBox
    $txtClient.Location = New-Object System.Drawing.Point(15,$y)
    $txtClient.Size = New-Object System.Drawing.Size(900,24)
    $txtClient.Text = $Global:App.GraphClientId
    $dlg.Controls.Add($txtClient)
    $y += 34

    $lblThumb = New-Object System.Windows.Forms.Label
    $lblThumb.Text = "Certificate thumbprint"
    $lblThumb.Location = New-Object System.Drawing.Point(15,$y)
    $lblThumb.AutoSize = $true
    $dlg.Controls.Add($lblThumb)
    $y += 20

    $txtThumb = New-Object System.Windows.Forms.TextBox
    $txtThumb.Location = New-Object System.Drawing.Point(15,$y)
    $txtThumb.Size = New-Object System.Drawing.Size(900,24)
    $txtThumb.Text = $Global:App.GraphCertificateThumbprint
    $dlg.Controls.Add($txtThumb)
    $y += 30

    # Baseline to detect "typed/tested a new value but never actually
    # saved it" on the way out - a real, live-confirmed gap: Test
    # connection (below) checks whatever's currently typed, but only Save
    # ever updates $Global:App.Graph* - every OTHER feature (Deploy, Sync,
    # Assign, ...) keeps using the previous saved values until then, with
    # no indication anything is stale. Silently discarding that mismatch
    # on Cancel/X is the same convention every other dialog in this app
    # already uses for a plain edit, but the blast radius here is bigger
    # (confusing auth failures elsewhere, not just a lost edit), so this
    # one dialog asks first instead of assuming Cancel always means "fine
    # to lose this."
    $origTenant = $txtTenant.Text
    $origClient = $txtClient.Text
    $origThumb  = $txtThumb.Text

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,$y)
    $lblStatus.Size = New-Object System.Drawing.Size(900,36)
    $dlg.Controls.Add($lblStatus)
    $y += 42

    $RefreshStatus = {
        $status = Get-CertificateStatusText -Thumbprint $txtThumb.Text
        $lblStatus.Text = $status.Text
        $lblStatus.ForeColor = $status.Color
    }.GetNewClosure()
    & $RefreshStatus

    $lblLocalSection = New-Object System.Windows.Forms.Label
    $lblLocalSection.Text = "LOCAL CERTIFICATE"
    $lblLocalSection.Location = New-Object System.Drawing.Point(15,$y)
    $lblLocalSection.AutoSize = $true
    $lblLocalSection.Font = New-Object System.Drawing.Font($dlg.Font.FontFamily, 8, [System.Drawing.FontStyle]::Bold)
    $lblLocalSection.ForeColor = [System.Drawing.Color]::FromArgb(90,90,90)
    $dlg.Controls.Add($lblLocalSection)

    $sepLocal = New-Object System.Windows.Forms.Panel
    $sepLocal.Location = New-Object System.Drawing.Point(180,($y+8))
    $sepLocal.Size = New-Object System.Drawing.Size(735,1)
    $sepLocal.BackColor = [System.Drawing.Color]::FromArgb(200,200,200)
    $dlg.Controls.Add($sepLocal)
    $y += 22

    $btnPick = New-Object System.Windows.Forms.Button
    $btnPick.Text = "Pick certificate..."
    $btnPick.Location = New-Object System.Drawing.Point(15,$y)
    $btnPick.Size = New-Object System.Drawing.Size(160,30)
    $dlg.Controls.Add($btnPick)
    $pickTip = New-Object System.Windows.Forms.ToolTip
    $pickTip.SetToolTip($btnPick, "Choose an existing certificate already in CurrentUser\My on this machine.")

    $btnGenerate = New-Object System.Windows.Forms.Button
    $btnGenerate.Text = "Generate certificate..."
    $btnGenerate.Location = New-Object System.Drawing.Point(185,$y)
    $btnGenerate.Size = New-Object System.Drawing.Size(190,30)
    $dlg.Controls.Add($btnGenerate)
    $generateTip = New-Object System.Windows.Forms.ToolTip
    $generateTip.SetToolTip($btnGenerate, "Creates a new self-signed certificate in CurrentUser\My and offers to export its public .cer file for upload to Entra ID.")

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = "Test connection"
    $btnTest.Location = New-Object System.Drawing.Point(385,$y)
    $btnTest.Size = New-Object System.Drawing.Size(530,30)
    $dlg.Controls.Add($btnTest)
    $testTip = New-Object System.Windows.Forms.ToolTip
    $testTip.SetToolTip($btnTest, "Tries an app-only Graph sign-in with the Tenant ID, Client ID, and certificate above - confirms this exact combination actually works before you Save.")
    $y += 40

    # Directly under Test connection, so its result shows next to the button
    # (it used to sit at the very bottom of the dialog).
    # Bordered, scrollable box instead of a plain fixed-height Label -
    # $lblTestResult's own .Text includes raw exception text below
    # ("Failed: $($ps.Streams.Error[0].ToString())"), which is unbounded
    # in length, and a fixed 36px/couple-lines height would silently clip
    # anything longer than that with no way to see the rest. Same pattern
    # as Show-CreateInIntuneDialog's own $pnlStatusInfo.
    $pnlTestResultInfo = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlTestResultInfo.Location = New-Object System.Drawing.Point(15,$y)
    $pnlTestResultInfo.Size = New-Object System.Drawing.Size(900,50)
    $pnlTestResultInfo.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $pnlTestResultInfo.WrapContents = $false
    $pnlTestResultInfo.AutoScroll = $true
    $pnlTestResultInfo.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $pnlTestResultInfo.BackColor = $Global:App.LightPalette.FieldBack
    $pnlTestResultInfo.Padding = New-Object System.Windows.Forms.Padding(6)
    $dlg.Controls.Add($pnlTestResultInfo)

    $lblTestResult = New-Object System.Windows.Forms.Label
    $lblTestResult.AutoSize = $true
    $lblTestResult.MaximumSize = New-Object System.Drawing.Size(870,0)
    $lblTestResult.Margin = New-Object System.Windows.Forms.Padding(0,0,0,0)
    $lblTestResult.Text = "Test connection shows its result here."
    $lblTestResult.ForeColor = [System.Drawing.Color]::DimGray
    $pnlTestResultInfo.Controls.Add($lblTestResult)
    $y += 58

    $btnDeleteLocal = New-Object System.Windows.Forms.Button
    $btnDeleteLocal.Text = "Delete local certificate..."
    $btnDeleteLocal.Location = New-Object System.Drawing.Point(15,$y)
    $btnDeleteLocal.Size = New-Object System.Drawing.Size(900,28)
    $dlg.Controls.Add($btnDeleteLocal)
    $deleteLocalTip = New-Object System.Windows.Forms.ToolTip
    $deleteLocalTip.SetToolTip($btnDeleteLocal, "Removes a certificate from THIS machine only (CurrentUser\My or LocalMachine\My) - does not touch Entra ID.")
    $y += 40

    $lblEntraSection = New-Object System.Windows.Forms.Label
    $lblEntraSection.Text = "ENTRA ID APP REGISTRATION"
    $lblEntraSection.Location = New-Object System.Drawing.Point(15,$y)
    $lblEntraSection.AutoSize = $true
    $lblEntraSection.Font = New-Object System.Drawing.Font($dlg.Font.FontFamily, 8, [System.Drawing.FontStyle]::Bold)
    $lblEntraSection.ForeColor = [System.Drawing.Color]::FromArgb(90,90,90)
    $dlg.Controls.Add($lblEntraSection)

    $sepEntra = New-Object System.Windows.Forms.Panel
    $sepEntra.Location = New-Object System.Drawing.Point(240,($y+8))
    $sepEntra.Size = New-Object System.Drawing.Size(675,1)
    $sepEntra.BackColor = [System.Drawing.Color]::FromArgb(200,200,200)
    $dlg.Controls.Add($sepEntra)
    $y += 22

    # The one operation in this whole app that can't use app-only cert auth -
    # that certificate isn't trusted by the app registration yet, which is
    # exactly the problem this solves. Needs interactive sign-in as a
    # separate, explicit step, with its own visible log, since the person
    # running it has to actually complete the browser sign-in prompt.
    $btnCheckCerts = New-Object System.Windows.Forms.Button
    $btnCheckCerts.Text = "Check certificates..."
    $btnCheckCerts.Location = New-Object System.Drawing.Point(15,$y)
    $btnCheckCerts.Size = New-Object System.Drawing.Size(445,30)
    $dlg.Controls.Add($btnCheckCerts)
    $checkCertsTip = New-Object System.Windows.Forms.ToolTip
    $checkCertsTip.SetToolTip($btnCheckCerts, "Lists which certificates this app registration currently trusts in Entra ID - read-only, changes nothing.")

    $btnUpload = New-Object System.Windows.Forms.Button
    $btnUpload.Text = "Upload certificate..."
    $btnUpload.Location = New-Object System.Drawing.Point(470,$y)
    $btnUpload.Size = New-Object System.Drawing.Size(445,30)
    $dlg.Controls.Add($btnUpload)
    $uploadTip = New-Object System.Windows.Forms.ToolTip
    $uploadTip.SetToolTip($btnUpload, "Adds the certificate above (from Tenant/Client/thumbprint) as a trusted certificate on the app registration in Entra ID - existing trusted certificates are kept, not replaced.")
    $y += 38

    $lblUploadStatus = New-Object System.Windows.Forms.Label
    $lblUploadStatus.Text = "Both use the app registration's Client ID above and require signing in with YOUR OWN account (not the app-only certificate) - Check just looks and may need its own sign-in even right after Upload (or vice versa). Upload needs the Application Administrator role or being an owner of this app registration."
    $lblUploadStatus.Location = New-Object System.Drawing.Point(15,$y)
    $lblUploadStatus.Size = New-Object System.Drawing.Size(900,68)
    $lblUploadStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblUploadStatus)
    $y += 74

    $rtbUploadLog = New-Object System.Windows.Forms.RichTextBox
    $rtbUploadLog.Location = New-Object System.Drawing.Point(15,$y)
    $rtbUploadLog.Size = New-Object System.Drawing.Size(900,170)
    Initialize-DarkLogBox -LogBox $rtbUploadLog
    # DetectUrls only makes a URL look like a link (blue, underlined) - it
    # doesn't open anything by itself, that needs its own LinkClicked handler.
    $rtbUploadLog.DetectUrls = $true
    $rtbUploadLog.Add_LinkClicked({
        param($s, $e)
        try { Start-Process $e.LinkText } catch { }
    })
    $dlg.Controls.Add($rtbUploadLog)
    $y += 178

    $lblCertList = New-Object System.Windows.Forms.Label
    $lblCertList.Text = "Certificates found by Check (select one to delete it from Entra):"
    $lblCertList.Location = New-Object System.Drawing.Point(15,$y)
    $lblCertList.AutoSize = $true
    $dlg.Controls.Add($lblCertList)
    $y += 20

    $lstCerts = New-Object System.Windows.Forms.ListBox
    $lstCerts.Location = New-Object System.Drawing.Point(15,$y)
    $lstCerts.Size = New-Object System.Drawing.Size(900,90)
    $dlg.Controls.Add($lstCerts)
    $y += 98

    $btnDeleteEntraCert = New-Object System.Windows.Forms.Button
    $btnDeleteEntraCert.Text = "Delete selected from Entra..."
    $btnDeleteEntraCert.Location = New-Object System.Drawing.Point(15,$y)
    $btnDeleteEntraCert.Size = New-Object System.Drawing.Size(250,28)
    $btnDeleteEntraCert.Enabled = $false
    $dlg.Controls.Add($btnDeleteEntraCert)
    $deleteEntraTip = New-Object System.Windows.Forms.ToolTip
    $deleteEntraTip.SetToolTip($btnDeleteEntraCert, "Removes the certificate selected below from Entra ID's trust list - does not touch anything on this machine.")
    $y += 36


    # The three checks the app can run by itself, without being asked. They
    # were checkboxes in the main toolbar, wedged between the buttons: a
    # toolbar is for actions you take now, and each of these is a setting
    # that persists to the settings file the moment it changes - which is
    # what this window is. Same three flags, same writes, same wording.
    $chkTips = New-Object System.Windows.Forms.ToolTip

    $lblAutoIntro = New-Object System.Windows.Forms.Label
    $lblAutoIntro.Text = "These run on their own, without being asked. Each needs Tenant ID, Client ID and a certificate on the Connection tab to do anything, and each takes effect the moment you tick it."
    $lblAutoIntro.Location = New-Object System.Drawing.Point(15,15)
    $lblAutoIntro.Size = New-Object System.Drawing.Size(860,40)
    $dlg.Controls.Add($lblAutoIntro)

    $chkDriftStart = New-Object System.Windows.Forms.CheckBox
    $chkDriftStart.Text = "Check Intune drift when this app starts"
    $chkDriftStart.AutoSize = $true
    $chkDriftStart.Location = New-Object System.Drawing.Point(15,65)
    $chkDriftStart.Checked = [bool]$Global:App.CheckDriftOnStartup
    $chkTips.SetToolTip($chkDriftStart, "When checked, the NEXT time this app starts it quietly compares Intune against this catalog once and flags any differences - useful if more than one person works from this catalog.")
    $dlg.Controls.Add($chkDriftStart)
    $chkDriftStart.Add_CheckedChanged({
        $Global:App.CheckDriftOnStartup = $chkDriftStart.Checked
        if (Write-SettingsFile) {
            Write-Log "[OK] $(if ($chkDriftStart.Checked) { 'Will' } else { 'Will not' }) check for Intune drift the next time this app starts.`r`n" ([System.Drawing.Color]::LightGreen)
        }
    }.GetNewClosure())

    # Indented under the drift check because it only adds to it - still its
    # own independent flag, for the reason $Global:App.RunFullAuditOnStartup
    # documents: a full audit fetches every deployed app individually and is
    # meaningfully slower, so it stays an explicit opt-in rather than
    # silently riding along with the lighter check above.
    $chkFullAudit = New-Object System.Windows.Forms.CheckBox
    $chkFullAudit.Text = "...and also run the full audit (slower)"
    $chkFullAudit.AutoSize = $true
    $chkFullAudit.Location = New-Object System.Drawing.Point(35,93)
    $chkFullAudit.Checked = [bool]$Global:App.RunFullAuditOnStartup
    $chkTips.SetToolTip($chkFullAudit, "When checked, the NEXT time this app starts it also runs the full 'Intune Audit...' check (Metadata/Groups/Dependencies/Assignments) - not just the lighter drift check above. Fetches every deployed app individually, so this is noticeably slower to complete on a large catalog.")
    $dlg.Controls.Add($chkFullAudit)
    $chkFullAudit.Add_CheckedChanged({
        $Global:App.RunFullAuditOnStartup = $chkFullAudit.Checked
        if (Write-SettingsFile) {
            Write-Log "[OK] $(if ($chkFullAudit.Checked) { 'Will' } else { 'Will not' }) run a full Intune audit the next time this app starts.`r`n" ([System.Drawing.Color]::LightGreen)
        }
    }.GetNewClosure())

    $chkDeployOpen = New-Object System.Windows.Forms.CheckBox
    $chkDeployOpen.Text = "Check Intune every time 'Deploy to Intune' opens"
    $chkDeployOpen.AutoSize = $true
    $chkDeployOpen.Location = New-Object System.Drawing.Point(15,129)
    $chkDeployOpen.Checked = [bool]$Global:App.CheckIntuneOnDeployOpen
    $chkTips.SetToolTip($chkDeployOpen, "When checked, 'Deploy to Intune' loads an existing app's current values from Intune every time it opens. Unchecked, it opens straight away with what's saved here and asks Intune only before an update is sent (and whenever you press Refresh from Intune) - the check that actually prevents overwriting a newer value.")
    $dlg.Controls.Add($chkDeployOpen)
    $chkDeployOpen.Add_CheckedChanged({
        $Global:App.CheckIntuneOnDeployOpen = $chkDeployOpen.Checked
        if (Write-SettingsFile) {
            Write-Log "[OK] Deploy to Intune $(if ($chkDeployOpen.Checked) { 'checks Intune when it opens.' } else { 'opens without contacting Intune - it still checks before any update.' })`r`n" ([System.Drawing.Color]::LightGreen)
        }
    }.GetNewClosure())

    $lblDeployOpenNote = New-Object System.Windows.Forms.Label
    $lblDeployOpenNote.Text = "Unticked is the faster default, and still safe: Deploy always checks Intune before it sends an update, whatever this says."
    $lblDeployOpenNote.Location = New-Object System.Drawing.Point(35,152)
    $lblDeployOpenNote.Size = New-Object System.Drawing.Size(840,20)
    $lblDeployOpenNote.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblDeployOpenNote)

    # Three tabs, because these are three separate jobs: the connection
    # details the app signs in with, looking after the certificate itself,
    # and what the app checks without being asked. Only one of them is ever
    # the reason Settings is open.
    #
    # The log stays below both. Test connection lives on Connection but
    # writes the token's permissions into that log, and an answer that
    # appears on a tab you aren't looking at may as well not appear.
    $settingsTabs = Convert-PanelToTabs -Dialog $dlg -Bounds (New-Object System.Drawing.Rectangle(10, 8, 910, 440)) -Pages @(
        @{
            Title = 'Connection'
            Controls = @(
                $lblIntro, $btnSetupGuide,
                $lblTenant, $txtTenant, $lblClient, $txtClient, $lblThumb, $txtThumb,
                $lblStatus, $btnTest, $pnlTestResultInfo
            )
        }
        @{
            Title = 'Certificate'
            Controls = @(
                $lblLocalSection, $sepLocal, $btnPick, $btnGenerate, $btnDeleteLocal,
                $lblEntraSection, $sepEntra, $btnCheckCerts, $btnUpload, $lblUploadStatus,
                $lblCertList, $lstCerts, $btnDeleteEntraCert
            )
        }
        @{
            Title = 'Automatic checks'
            Controls = @(
                $lblAutoIntro, $chkDriftStart, $chkFullAudit, $chkDeployOpen, $lblDeployOpenNote
            )
        }
    )

    # Laid out for the page rather than for the old single column: the
    # controls were 900 wide inside a dialog 930 wide, which is wider than a
    # tab page and put a scrollbar on every one of them.
    $lblIntro.Location = New-Object System.Drawing.Point(12,12)
    $lblIntro.Size = New-Object System.Drawing.Size(866,45)
    $btnSetupGuide.Location = New-Object System.Drawing.Point(12,64)
    $btnSetupGuide.Size = New-Object System.Drawing.Size(866,28)
    $lblTenant.Location = New-Object System.Drawing.Point(12,100)
    $txtTenant.Location = New-Object System.Drawing.Point(12,120)
    $txtTenant.Size = New-Object System.Drawing.Size(866,24)
    $lblClient.Location = New-Object System.Drawing.Point(12,154)
    $txtClient.Location = New-Object System.Drawing.Point(12,174)
    $txtClient.Size = New-Object System.Drawing.Size(866,24)
    $lblThumb.Location = New-Object System.Drawing.Point(12,208)
    $txtThumb.Location = New-Object System.Drawing.Point(12,228)
    $txtThumb.Size = New-Object System.Drawing.Size(866,24)
    $lblStatus.Location = New-Object System.Drawing.Point(12,258)
    $lblStatus.Size = New-Object System.Drawing.Size(866,36)
    $btnTest.Location = New-Object System.Drawing.Point(12,302)
    $btnTest.Size = New-Object System.Drawing.Size(866,30)
    $pnlTestResultInfo.Location = New-Object System.Drawing.Point(12,340)
    $pnlTestResultInfo.Size = New-Object System.Drawing.Size(866,60)
    $lblTestResult.MaximumSize = New-Object System.Drawing.Size(836,0)

    $lblLocalSection.Location = New-Object System.Drawing.Point(12,12)
    $sepLocal.Location = New-Object System.Drawing.Point(180,20)
    $sepLocal.Size = New-Object System.Drawing.Size(698,1)
    $btnPick.Location = New-Object System.Drawing.Point(12,34)
    $btnGenerate.Location = New-Object System.Drawing.Point(182,34)
    $btnDeleteLocal.Location = New-Object System.Drawing.Point(382,34)
    $btnDeleteLocal.Size = New-Object System.Drawing.Size(496,30)
    $lblEntraSection.Location = New-Object System.Drawing.Point(12,80)
    $sepEntra.Location = New-Object System.Drawing.Point(180,88)
    $sepEntra.Size = New-Object System.Drawing.Size(698,1)
    $btnCheckCerts.Location = New-Object System.Drawing.Point(12,102)
    $btnCheckCerts.Size = New-Object System.Drawing.Size(430,30)
    $btnUpload.Location = New-Object System.Drawing.Point(448,102)
    $btnUpload.Size = New-Object System.Drawing.Size(430,30)
    $lblUploadStatus.Location = New-Object System.Drawing.Point(12,140)
    $lblUploadStatus.Size = New-Object System.Drawing.Size(866,58)
    $lblCertList.Location = New-Object System.Drawing.Point(12,204)
    $lstCerts.Location = New-Object System.Drawing.Point(12,224)
    $lstCerts.Size = New-Object System.Drawing.Size(866,108)
    $btnDeleteEntraCert.Location = New-Object System.Drawing.Point(12,340)

    $rtbUploadLog.Location = New-Object System.Drawing.Point(15,458)
    $rtbUploadLog.Size = New-Object System.Drawing.Size(900,140)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(745,610)
    $btnSave.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Close"
    $btnCancel.Location = New-Object System.Drawing.Point(835,610)
    $btnCancel.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnCancel)

    # -Owner so Settings stays usable while the guide is open - the steps
    # exist to be followed IN Settings.
    $btnSetupGuide.Add_Click({ Show-AppRegistrationGuideDialog -Owner $dlg }.GetNewClosure())

    $btnPick.Add_Click({
        try {
            $picked = Show-CertificatePickerDialog
            if ($picked) {
                $txtThumb.Text = $picked
                & $RefreshStatus
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not open certificate picker: $($_.Exception.Message)", "Error", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())

    $btnDeleteLocal.Add_Click({
        # Delegated entirely to its own dialog now, not this dialog's
        # $txtThumb field - see Show-DeleteLocalCertificateDialog's own
        # header comment for why reusing that field as the delete target
        # was a real risk (it also represents the ACTIVE configured
        # certificate). Only reconciled here afterward: if whatever got
        # deleted happens to match what's currently shown in $txtThumb,
        # clear it and refresh the status line - same end result as
        # before for that specific case, just decided by the returned
        # list instead of by sharing the field itself.
        $deletedThumbprints = @(Show-DeleteLocalCertificateDialog)
        $currentThumb = $txtThumb.Text.Trim() -replace '\s', ''
        if ($currentThumb -and ($deletedThumbprints -contains $currentThumb)) {
            $txtThumb.Text = ""
            & $RefreshStatus
        }
    }.GetNewClosure())

    $btnGenerate.Add_Click({
        if (-not (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)) {
            [System.Windows.Forms.MessageBox]::Show("New-SelfSignedCertificate isn't available (the PKI module is missing). This is built into Windows 10/11 and Windows Server 2012 R2+ by default.", "Not available", "OK", "Error") | Out-Null
            return
        }

        $subject = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Certificate subject (the 'CN=' prefix is added automatically if you leave it out):",
            "Generate certificate", "Intune Deployment")
        if (-not $subject) { return }
        $subject = $subject.Trim()
        if (-not $subject) { return }
        if ($subject -notmatch '^CN=') { $subject = "CN=$subject" }

        try {
            $newCert = New-SelfSignedCertificate -Subject $subject -CertStoreLocation "Cert:\CurrentUser\My" `
                -KeyExportPolicy Exportable -KeySpec Signature -KeyLength 2048 -KeyAlgorithm RSA `
                -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(2)

            $txtThumb.Text = $newCert.Thumbprint
            & $RefreshStatus

            $sfd = New-Object System.Windows.Forms.SaveFileDialog
            $sfd.Filter = "Certificate files (*.cer)|*.cer"
            $sfd.FileName = "Intune-Deployment.cer"
            $sfd.Title = "Export public certificate (upload this to Entra ID)"
            if ($sfd.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) {
                Export-Certificate -Cert $newCert -FilePath $sfd.FileName | Out-Null
                [System.Windows.Forms.MessageBox]::Show(
                    "Certificate created and exported to:`n$($sfd.FileName)`n`nNext steps:`n1. In Entra ID, open your app registration > Certificates & secrets > Certificates > Upload certificate, and upload this .cer file.`n2. Click Save here to start using this certificate.",
                    "Certificate created", "OK", "Information") | Out-Null
            }
            else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Certificate created but not exported. You'll need to export its public key later (Certificate Manager, or re-run this dialog) and upload it to Entra ID before this certificate will work.",
                    "Certificate created", "OK", "Warning") | Out-Null
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not create certificate: $($_.Exception.Message)", "Error", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())

    # Parallel to $lstCerts.Items - index N here is the keyId for whatever's
    # shown at index N, populated by a successful Check and consumed by
    # Delete selected from Entra. Deliberately keyId, not thumbprint - two
    # entries can legitimately share a thumbprint if the same certificate
    # was uploaded more than once, and matching a delete by thumbprint alone
    # would remove every entry that shares it, not just the one selected.
    $certKeyIds = New-Object System.Collections.Generic.List[string]

    $btnCheckCerts.Add_Click({
        $checkTenant = $txtTenant.Text.Trim()
        $checkClient = $txtClient.Text.Trim()

        if (-not $checkTenant -or -not $checkClient) {
            [System.Windows.Forms.MessageBox]::Show("Fill in Tenant ID and Client ID first.", "Missing fields", "OK", "Warning") | Out-Null
            return
        }

        $btnCheckCerts.Enabled = $false
        $btnUpload.Enabled = $false
        $btnDeleteEntraCert.Enabled = $false
        $lblUploadStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblUploadStatus.Text = "Starting sign-in..."
        $rtbUploadLog.Clear()

        $configPath = Join-Path $env:TEMP (".intunepkg_certupload_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_certupload_result_" + [guid]::NewGuid().ToString("N") + ".json")
        # OutputResultPath included directly in the object literal, not
        # bolted on afterward via a separate Select-Object step - that
        # extra step was confirmed, directly and repeatedly, to sometimes
        # produce a genuinely null result with no error at all, in the
        # same pattern elsewhere in this file. Sidestepped entirely here
        # too, rather than relying on a construct already shown to
        # misbehave.
        $config = [pscustomobject]@{
            Mode             = "Check"
            TenantId         = $checkTenant
            ClientId         = $checkClient
            OutputResultPath = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Show-ConfigWriteFailedError -ErrorMessage $_.Exception.Message
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnCheckCertsRef = $btnCheckCerts
        $btnUploadRef = $btnUpload
        $btnDeleteEntraCertRef = $btnDeleteEntraCert
        $lblUploadStatusRef = $lblUploadStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $rtbUploadLogRef = $rtbUploadLog
        $lstCertsRef = $lstCerts
        $certKeyIdsRef = $certKeyIds

        Start-PipelineProcess -ScriptContent $certUploadScript -TempScriptName ".intunepkg_embedded_certupload.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbUploadLog -ShowConsoleWindow -OnComplete {
            param($code)
            $btnCheckCertsRef.Enabled = $true
            $btnUploadRef.Enabled = $true
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $lblUploadStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblUploadStatusRef.Text = "Done - see the certificates listed above and below."
                        $lstCertsRef.Items.Clear()
                        $certKeyIdsRef.Clear()
                        foreach ($c in @($result.certificates)) {
                            [void]$lstCertsRef.Items.Add("$($c.DisplayName)  [$($c.Thumbprint)]  expires $($c.Expiry)")
                            $certKeyIdsRef.Add([string]$c.KeyId)
                        }
                    }
                    else {
                        Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnUpload.Add_Click({
        $uploadTenant = $txtTenant.Text.Trim()
        $uploadClient = $txtClient.Text.Trim()
        $uploadThumb  = $txtThumb.Text.Trim()

        if (-not $uploadTenant -or -not $uploadClient -or -not $uploadThumb) {
            [System.Windows.Forms.MessageBox]::Show("Fill in Tenant ID, Client ID, and Certificate Thumbprint first.", "Missing fields", "OK", "Warning") | Out-Null
            return
        }

        $localCert = $null
        try {
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            $localCert = $store.Certificates | Where-Object { $_.Thumbprint -eq $uploadThumb } | Select-Object -First 1
            $store.Close()
        } catch { }
        if (-not $localCert) {
            [System.Windows.Forms.MessageBox]::Show("No certificate with thumbprint $uploadThumb was found in CurrentUser\My. Pick or generate one first.", "Certificate not found", "OK", "Warning") | Out-Null
            return
        }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "This adds `"$($localCert.Subject)`" to the app registration's trusted certificates in Entra ID.`n`nRequires signing in with YOUR OWN account (a console window and a browser window will both briefly open) and either the Application Administrator role or being an owner of this app registration.`n`nAny certificates already trusted for this app registration are kept, not replaced. Continue?",
            "Confirm certificate upload", "YesNo", "Question", "Button2")
        if ($r -ne "Yes") { return }

        $btnUpload.Enabled = $false
        $btnCheckCerts.Enabled = $false
        $btnDeleteEntraCert.Enabled = $false
        $lblUploadStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblUploadStatus.Text = "Starting sign-in..."
        $rtbUploadLog.Clear()

        $configPath = Join-Path $env:TEMP (".intunepkg_certupload_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_certupload_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            Mode             = "Upload"
            TenantId         = $uploadTenant
            ClientId         = $uploadClient
            CertThumbprint   = $uploadThumb
            CertSubject      = $localCert.Subject
            CertBase64       = [Convert]::ToBase64String($localCert.RawData)
            CertNotBefore    = $localCert.NotBefore.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            CertNotAfter     = $localCert.NotAfter.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            OutputResultPath = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Show-ConfigWriteFailedError -ErrorMessage $_.Exception.Message
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnUploadRef = $btnUpload
        $btnCheckCertsRef = $btnCheckCerts
        $lblUploadStatusRef = $lblUploadStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $rtbUploadLogRef = $rtbUploadLog

        Start-PipelineProcess -ScriptContent $certUploadScript -TempScriptName ".intunepkg_embedded_certupload.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbUploadLog -ShowConsoleWindow -OnComplete {
            param($code)
            $btnUploadRef.Enabled = $true
            $btnCheckCertsRef.Enabled = $true
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $lblUploadStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblUploadStatusRef.Text = "Certificate added. It can take a few minutes to propagate before Test connection succeeds with it."
                    }
                    else {
                        Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $lstCerts.Add_SelectedIndexChanged({
        $btnDeleteEntraCert.Enabled = ($lstCerts.SelectedIndex -ge 0)
    }.GetNewClosure())

    $btnDeleteEntraCert.Add_Click({
        if ($lstCerts.SelectedIndex -lt 0) { return }
        $idx = $lstCerts.SelectedIndex
        $certLabel = [string]$lstCerts.Items[$idx]
        $keyIdToDelete = $certKeyIds[$idx]
        $deleteTenant = $txtTenant.Text.Trim()
        $deleteClient = $txtClient.Text.Trim()

        # Removing the only certificate left would break app-only sign-in
        # for the WHOLE rest of this app, not just this dialog - said in the
        # same question rather than a second one.
        $lastCertWarning = if ($certKeyIds.Count -eq 1) {
            "`n`nThis is the ONLY certificate trusted for this app registration. Without it, sign-in fails everywhere in this app (Deploy, Assign, App ID lookup, ...) until a new one is uploaded."
        } else { "" }
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Remove this certificate from Entra ID?`n`n$certLabel$lastCertWarning`n`nIt stays on this machine - use 'Delete local certificate' for that.",
            "Delete from Entra ID", "YesNo", "Warning", "Button2")
        if ($r -ne "Yes") { return }

        $btnCheckCerts.Enabled = $false
        $btnUpload.Enabled = $false
        $btnDeleteEntraCert.Enabled = $false
        $lblUploadStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblUploadStatus.Text = "Starting sign-in..."
        $rtbUploadLog.Clear()

        $configPath = Join-Path $env:TEMP (".intunepkg_certupload_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_certupload_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            Mode             = "DeleteCert"
            TenantId         = $deleteTenant
            ClientId         = $deleteClient
            KeyIdToDelete    = $keyIdToDelete
            OutputResultPath = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Show-ConfigWriteFailedError -ErrorMessage $_.Exception.Message
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $btnCheckCertsRef = $btnCheckCerts
        $btnUploadRef = $btnUpload
        $btnDeleteEntraCertRef = $btnDeleteEntraCert
        $lblUploadStatusRef = $lblUploadStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $rtbUploadLogRef = $rtbUploadLog

        Start-PipelineProcess -ScriptContent $certUploadScript -TempScriptName ".intunepkg_embedded_certupload.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbUploadLog -ShowConsoleWindow -OnComplete {
            param($code)
            $btnCheckCertsRef.Enabled = $true
            $btnUploadRef.Enabled = $true
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $lblUploadStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblUploadStatusRef.Text = "Removed. Reloading certificate list..."
                        $btnCheckCertsRef.PerformClick()
                    }
                    else {
                        $btnDeleteEntraCertRef.Enabled = $true
                        Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    $btnDeleteEntraCertRef.Enabled = $true
                    Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                $btnDeleteEntraCertRef.Enabled = $true
                Write-DialogError -StatusLabel $lblUploadStatusRef -LogBox $rtbUploadLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnTest.Add_Click({
        $testTenant = $txtTenant.Text.Trim()
        $testClient = $txtClient.Text.Trim()
        $testThumb  = $txtThumb.Text.Trim()

        if (-not $testTenant -or -not $testClient -or -not $testThumb) {
            $lblTestResult.ForeColor = [System.Drawing.Color]::Firebrick
            $lblTestResult.Text = "Fill in Tenant ID, Client ID, and Certificate Thumbprint first."
            return
        }

        if (-not (Test-GraphModuleAvailable -CurrentHostOnly)) {
            $lblTestResult.ForeColor = [System.Drawing.Color]::Firebrick
            $lblTestResult.Text = "The Microsoft.Graph.Authentication module isn't installed yet."
            return
        }

        $lblTestResult.ForeColor = [System.Drawing.Color]::DimGray
        $lblTestResult.Text = "Connecting..."
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $btnTest.Enabled = $false

        # Fresh local aliases, assigned here (within this closure's own execution)
        # rather than reused directly from the outer capture. A closure nested
        # inside an already-closured handler (the Timer.Add_Tick below, nested
        # inside this Add_Click) does not reliably re-capture variables that
        # were themselves captured by an outer GetNewClosure() call - only
        # variables freshly assigned in the immediately-enclosing scope, like
        # these aliases (and $ps/$handle/$timer below), come through reliably.
        $dlgRef = $dlg
        $btnTestRef = $btnTest
        $lblTestResultRef = $lblTestResult
        $rtbUploadLogRef = $rtbUploadLog
        $testClientRef = $testClient

        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($TenantId, $ClientId, $CertThumb, $TokenHelperText)
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertThumb -NoWelcome -ErrorAction Stop
            $ctx = Get-MgContext -ErrorAction Stop
            # A signed-in app that is allowed to do nothing still reports
            # success here, which is how "I granted it but it says Forbidden"
            # survives a passing connection test. So the token is read too -
            # see GraphToken.ps1. A failure to read it doesn't fail the test:
            # the sign-in genuinely did work.
            . ([scriptblock]::Create($TokenHelperText))
            $claims = $null
            $claimsError = ''
            try { $claims = Get-GraphAppTokenClaims -TenantId $TenantId -ClientId $ClientId -Thumbprint $CertThumb }
            catch { $claimsError = $_.Exception.Message }
            [pscustomobject]@{
                AppName     = $ctx.AppName
                AuthType    = $ctx.AuthType
                Roles       = @($claims.roles)
                TokenAppId  = [string]$claims.appid
                ClaimsError = $claimsError
            }
        }).AddArgument($testTenant).AddArgument($testClient).AddArgument($testThumb).
            AddArgument((Get-ReportHelperScriptText -Names 'ConvertFrom-JwtPayload', 'Get-GraphAppTokenClaims'))

        $handle = $ps.BeginInvoke()
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 300
        $timer.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $timer.Stop(); $timer.Dispose()
            $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
            # Forces Windows to actually repaint the cursor now instead of
            # waiting on the next mouse-move to trigger it - see the note
            # on this same pattern in Show-WingetSearchDialog for the
            # confirmed live report this fixes.
            [System.Windows.Forms.Application]::DoEvents()
            [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
            $btnTestRef.Enabled = $true
            try {
                $raw = @($ps.EndInvoke($handle))
                if ($ps.Streams.Error.Count -gt 0) {
                    $lblTestResultRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblTestResultRef.Text = "Failed: $($ps.Streams.Error[0].ToString())"
                }
                elseif ($raw.Count -eq 0) {
                    $lblTestResultRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblTestResultRef.Text = "Failed: no response."
                }
                else {
                    $result = $raw[0]
                    $report = Get-GraphRoleReport -Roles @($result.Roles)
                    $blocked = @(@($report.Missing) | Where-Object { $_.Required }).Count
                    $lblTestResultRef.ForeColor = if ($blocked -gt 0) { [System.Drawing.Color]::Firebrick }
                                                  elseif (@($report.Missing).Count -gt 0) { [System.Drawing.Color]::DarkOrange }
                                                  else { [System.Drawing.Color]::SeaGreen }
                    $signedIn = "Signed in as '$($result.AppName)' ($($result.AuthType))"
                    $lblTestResultRef.Text = if ($result.ClaimsError) { "$signedIn - couldn't read the permissions, see the log below." }
                                             elseif ($blocked -gt 0) { "$signedIn, but it's missing a permission the app needs - see the log below." }
                                             elseif (@($report.Missing).Count -gt 0) { "$signedIn. Some features are missing a permission - see the log below." }
                                             else { "$signedIn, with every permission this app uses." }
                    if ($rtbUploadLogRef) {
                        Write-DialogLogLine -LogBox $rtbUploadLogRef -Text "`r`n[INFO] Test connection: $signedIn.`r`n"
                        if ($result.ClaimsError) {
                            Write-DialogLogLine -LogBox $rtbUploadLogRef -Text "[WARN] The sign-in worked, but reading the token's permissions didn't: $($result.ClaimsError)`r`n"
                        }
                        else {
                            foreach ($line in (Format-GraphRoleReport -Report $report -TokenAppId $result.TokenAppId -SettingsClientId $testClientRef)) {
                                Write-DialogLogLine -LogBox $rtbUploadLogRef -Text "$line`r`n"
                            }
                        }
                    }
                }
            }
            catch {
                $lblTestResultRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblTestResultRef.Text = "Failed: $($_.Exception.Message)"
            }
            finally {
                $ps.Dispose(); $rs.Close(); $rs.Dispose()
            }
        }.GetNewClosure())
        $timer.Start()
    }.GetNewClosure())

    # Plain local box (not $Script:-qualified) - the btnSave handler below is a
    # closure and cannot reliably write $Script:-qualified variables (see the
    # note in Start-IntuneAppLookup). It records what to save here instead; the
    # actual $Global:App.GraphTenantId/etc mutation happens after ShowDialog
    # returns, in this function's own plain (non-closure) body.
    $saveResultBox = @{ Saved = $false; TenantId = $null; ClientId = $null; Thumbprint = $null }

    # True while any of Check certificates / Upload certificate / Delete
    # from Entra is running, OR while Test connection's own background
    # runspace is running ($btnTest.Enabled). Unlike the batch dialogs
    # elsewhere in this app, none of these four operations had ANY guard
    # against Save/Cancel/the window's own X button closing the dialog
    # out from under them - an interactive browser sign-in (Check/Upload/
    # Delete) or a live Graph connection test can run for a while, and
    # closing mid-run left their -OnComplete closures touching disposed
    # controls once they eventually finished.
    #
    # Deliberately checks btnCheckCerts/btnUpload only, NOT
    # btnDeleteEntraCert - all three of Check/Upload/Delete disable both
    # btnCheckCerts and btnUpload together whenever any of them starts, so
    # those two alone already fully cover "one of these three is
    # running." btnDeleteEntraCert's own Enabled state means something
    # else entirely most of the time (whether a certificate is currently
    # SELECTED in the list - see $lstCerts' own SelectionChanged handler),
    # which is $false by default and after every completed Check, long
    # before/after any operation is actually running - including it here
    # made this dialog impossible to close (Save/Cancel/X all silently
    # blocked with "An operation is still running") from the moment it
    # opened, confirmed live.
    $anyCertOpRunning = {
        (-not $btnCheckCerts.Enabled) -or (-not $btnUpload.Enabled) -or (-not $btnTest.Enabled)
    }.GetNewClosure()

    $HasUnsavedConnectionChanges = {
        ($txtTenant.Text.Trim() -ne $origTenant.Trim()) -or
        ($txtClient.Text.Trim() -ne $origClient.Trim()) -or
        (($txtThumb.Text.Trim() -replace '\s', '') -ne ($origThumb.Trim() -replace '\s', ''))
    }.GetNewClosure()

    # Set by Cancel's own click handler once it has already asked and the
    # user chose to discard - stops FormClosing (fired by $dlg.Close()
    # from that same click) from immediately asking the exact same
    # question a second time right after the first answer.
    $discardConfirmedBox = @{ Value = $false }
    # $true while closing runs Save itself - Save then mustn't close again
    $closingBox = @{ Value = $false }

    # Save's checks and result - also used when closing asks "Save changes?"
    # and the answer is Yes. Returns $true when saved.
    # -Quiet: closing asks its own question about what to do next, so the
    # complaint about missing values isn't shown twice.
    $performSave = {
        param([switch]$Quiet)
        if (& $anyCertOpRunning) {
            if (-not $Quiet) { [System.Windows.Forms.MessageBox]::Show("An operation is still running - wait for it to finish first.", "Please wait", "OK", "Information") | Out-Null }
            return $false
        }
        if (-not $txtTenant.Text.Trim() -or -not $txtClient.Text.Trim() -or -not $txtThumb.Text.Trim()) {
            if (-not $Quiet) { [System.Windows.Forms.MessageBox]::Show("Tenant ID, Client ID, and thumbprint are all required.", "Missing values", "OK", "Warning") | Out-Null }
            return $false
        }
        $saveResultBox.TenantId   = $txtTenant.Text.Trim()
        $saveResultBox.ClientId   = $txtClient.Text.Trim()
        $saveResultBox.Thumbprint = ($txtThumb.Text.Trim() -replace '\s', '')
        $saveResultBox.Saved = $true
        if (-not $closingBox.Value) { $dlg.Close() }
        return $true
    }.GetNewClosure()
    $btnSave.Add_Click({ [void](& $performSave) }.GetNewClosure())

    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())

    # The one place leaving is checked - Save, Cancel (also Esc), X and
    # Alt+F4 all end up here. A CancelButton closes the dialog on its own
    # after its click handler, so asking in the handler couldn't have kept
    # the dialog open anyway.
    # $true while a question about closing is on screen - a second attempt
    # to close would otherwise stack another one on top of it.
    $askingBox = @{ Value = $false }
    $dlg.Add_FormClosing({
        param($s, $e)
        if ($askingBox.Value) { $e.Cancel = $true; return }
        if (& $anyCertOpRunning) {
            $askingBox.Value = $true
            try { [System.Windows.Forms.MessageBox]::Show($s, "An operation is still running - wait for it to finish first.", "Please wait", "OK", "Information") | Out-Null }
            finally { $askingBox.Value = $false }
            $e.Cancel = $true
            return
        }
        if ($saveResultBox.Saved -or $discardConfirmedBox.Value) { return }
        if (& $HasUnsavedConnectionChanges) {
            $askingBox.Value = $true
            try {
                $r = [System.Windows.Forms.MessageBox]::Show($s,
                    "Save your changes to the Tenant ID, Client ID or certificate thumbprint?`n`nIf you don't, the rest of the app (Deploy, Sync, Assign, ...) keeps using the previously saved values - 'Test connection' doesn't save anything.",
                    "Save changes?", "YesNoCancel", "Warning")
            }
            finally { $askingBox.Value = $false }
            if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
                $closingBox.Value = $true
                $saved = $false
                try { $saved = [bool](& $performSave -Quiet) }
                finally { $closingBox.Value = $false }
                if (-not $saved) {
                    # Without this the window is a trap: saving can't succeed
                    # with a field still empty, so every attempt to close
                    # asked the same question again, for ever.
                    $why = if (& $anyCertOpRunning) {
                        "An operation is still running, so the settings can't be saved yet."
                    } else {
                        "Tenant ID, Client ID and certificate thumbprint are all required, and one of them is still empty."
                    }
                    $askingBox.Value = $true
                    try {
                        $r2 = [System.Windows.Forms.MessageBox]::Show($s,
                            "$why`n`nClose anyway and lose the changes made here?",
                            "Not saved", "YesNo", "Warning", "Button2")
                    }
                    finally { $askingBox.Value = $false }
                    if ($r2 -eq [System.Windows.Forms.DialogResult]::Yes) { $discardConfirmedBox.Value = $true }
                    else { $e.Cancel = $true }
                }
            }
            elseif ($r -ne [System.Windows.Forms.DialogResult]::No) { $e.Cancel = $true }
        }
    }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnSave
    Set-Theme -Control $dlg
    # Set-ThemeRecursive's combined Panel/FlowLayoutPanel/... case
    # unconditionally resets BackColor to the dialog's own plain
    # background - reapplied so $pnlTestResultInfo actually looks like
    # the bordered, distinct "field" it's meant to be.
    $pnlTestResultInfo.BackColor = $Global:App.LightPalette.FieldBack
    [void]$dlg.ShowDialog($Global:App.Form)

    if ($saveResultBox.Saved) {
        if (Save-GraphSettings -TenantId $saveResultBox.TenantId -ClientId $saveResultBox.ClientId -CertificateThumbprint $saveResultBox.Thumbprint) {
            $Global:App.GraphTenantId = $saveResultBox.TenantId
            $Global:App.GraphClientId = $saveResultBox.ClientId
            $Global:App.GraphCertificateThumbprint = $saveResultBox.Thumbprint
            $Global:App.IntuneAppsCache.Clear()   # old cache may have been fetched under a different identity
            # No confirmation popup here, deliberately - the only place in
            # this app that had one after a successful save. The dialog
            # already closed and this line is already in the persistent
            # Log tab; every other save action in this app (catalog,
            # favorite groups, default app settings, ...) relies on that
            # same combination without an extra required click.
            Write-Log "[OK] Settings saved. Client: $($saveResultBox.ClientId), Tenant: $($saveResultBox.TenantId).`r`n" ([System.Drawing.Color]::LightGreen)
        }
    }
}
