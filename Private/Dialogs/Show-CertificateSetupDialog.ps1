function Global:Show-CertificateSetupDialog {
    # Plain local aliases - see note in Start-IntuneAppLookup. Even a single
    # level of GetNewClosure() (like $btnUpload.Add_Click below) does not
    # reliably see $Script:-qualified variables directly, only plain ones.
    $certUploadScript = $Global:App.EmbeddedCertUploadScript

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Settings - Microsoft Graph Connection"
    $dlg.ClientSize = New-Object System.Drawing.Size(930, 1034)
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

    $btnGenerate = New-Object System.Windows.Forms.Button
    $btnGenerate.Text = "Generate certificate..."
    $btnGenerate.Location = New-Object System.Drawing.Point(185,$y)
    $btnGenerate.Size = New-Object System.Drawing.Size(190,30)
    $dlg.Controls.Add($btnGenerate)

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = "Test connection"
    $btnTest.Location = New-Object System.Drawing.Point(385,$y)
    $btnTest.Size = New-Object System.Drawing.Size(530,30)
    $dlg.Controls.Add($btnTest)
    $y += 40

    $btnDeleteLocal = New-Object System.Windows.Forms.Button
    $btnDeleteLocal.Text = "Delete local certificate..."
    $btnDeleteLocal.Location = New-Object System.Drawing.Point(15,$y)
    $btnDeleteLocal.Size = New-Object System.Drawing.Size(900,28)
    $dlg.Controls.Add($btnDeleteLocal)
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

    $btnUpload = New-Object System.Windows.Forms.Button
    $btnUpload.Text = "Upload certificate..."
    $btnUpload.Location = New-Object System.Drawing.Point(470,$y)
    $btnUpload.Size = New-Object System.Drawing.Size(445,30)
    $dlg.Controls.Add($btnUpload)
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
    $y += 36

    $lblTestResult = New-Object System.Windows.Forms.Label
    $lblTestResult.Location = New-Object System.Drawing.Point(15,$y)
    $lblTestResult.Size = New-Object System.Drawing.Size(900,36)
    $dlg.Controls.Add($lblTestResult)
    $y += 46

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(745,$y)
    $btnSave.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Close"
    $btnCancel.Location = New-Object System.Drawing.Point(835,$y)
    $btnCancel.Size = New-Object System.Drawing.Size(80,30)
    $dlg.Controls.Add($btnCancel)

    $btnSetupGuide.Add_Click({ Show-AppRegistrationGuideDialog }.GetNewClosure())

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
        $thumb = $txtThumb.Text.Trim() -replace '\s', ''
        if (-not $thumb) {
            [System.Windows.Forms.MessageBox]::Show("Enter or pick a certificate thumbprint first.", "No thumbprint", "OK", "Information") | Out-Null
            return
        }

        # Same two locations Get-CertificateStatusText already searches -
        # deletion should look wherever the status check would have found it.
        $foundPath = $null
        $foundCert = $null
        foreach ($location in @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")) {
            $candidate = Get-ChildItem -Path $location -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumb } | Select-Object -First 1
            if ($candidate) {
                $foundPath = Join-Path $location $thumb
                $foundCert = $candidate
                break
            }
        }
        if (-not $foundCert) {
            [System.Windows.Forms.MessageBox]::Show("No certificate with thumbprint $thumb was found in CurrentUser\My or LocalMachine\My on this machine.", "Not found", "OK", "Warning") | Out-Null
            return
        }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "Permanently delete this certificate from $foundPath ?`n`n$($foundCert.Subject)`n`nThis only removes it from THIS machine - it does NOT remove it from Entra ID. Use Check certificates / Delete from Entra above for that, separately.",
            "Confirm local delete", "YesNo", "Warning")
        if ($r -ne "Yes") { return }

        try {
            Remove-Item -Path $foundPath -Force -ErrorAction Stop
            # Only clear the field if it still pointed at the cert that was
            # just deleted - not if the user had already typed something else.
            if (($txtThumb.Text.Trim() -replace '\s', '') -eq $thumb) {
                $txtThumb.Text = ""
                & $RefreshStatus
            }
            [System.Windows.Forms.MessageBox]::Show("Certificate deleted from $foundPath.", "Deleted", "OK", "Information") | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not delete the certificate: $($_.Exception.Message)`n`nDeleting from LocalMachine\My usually needs an elevated (Run as Administrator) session.", "Delete failed", "OK", "Error") | Out-Null
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
            "Confirm certificate upload", "YesNo", "Question")
        if ($r -ne "Yes") { return }

        $btnUpload.Enabled = $false
        $btnCheckCerts.Enabled = $false
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
        # for the WHOLE rest of this app entirely, not just this dialog -
        # worth a sharper warning than a routine confirmation.
        if ($certKeyIds.Count -eq 1) {
            $r0 = [System.Windows.Forms.MessageBox]::Show(
                "This is the ONLY certificate currently trusted for this app registration. Removing it will break app-only sign-in for this app entirely, everywhere it's used (Deploy, Assign, App ID lookup, etc.) until a new one is uploaded. Continue anyway?",
                "This is the last certificate", "YesNo", "Warning")
            if ($r0 -ne "Yes") { return }
        }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "Remove this certificate from Entra ID?`n`n$certLabel`n`nThis only removes it from Entra - it does NOT delete it from this machine. Use Delete local certificate above for that, separately.",
            "Confirm delete from Entra", "YesNo", "Warning")
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

        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($TenantId, $ClientId, $CertThumb)
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertThumb -NoWelcome -ErrorAction Stop
            $ctx = Get-MgContext -ErrorAction Stop
            [pscustomobject]@{ AppName = $ctx.AppName; AuthType = $ctx.AuthType }
        }).AddArgument($testTenant).AddArgument($testClient).AddArgument($testThumb)

        $handle = $ps.BeginInvoke()
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 300
        $timer.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $timer.Stop(); $timer.Dispose()
            $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
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
                    $lblTestResultRef.ForeColor = [System.Drawing.Color]::SeaGreen
                    $lblTestResultRef.Text = "Success - connected as '$($raw[0].AppName)' ($($raw[0].AuthType))."
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

    $btnSave.Add_Click({
        if (-not $txtTenant.Text.Trim() -or -not $txtClient.Text.Trim() -or -not $txtThumb.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Tenant ID, Client ID, and thumbprint are all required.", "Missing values", "OK", "Warning") | Out-Null
            return
        }
        $saveResultBox.TenantId   = $txtTenant.Text.Trim()
        $saveResultBox.ClientId   = $txtClient.Text.Trim()
        $saveResultBox.Thumbprint = ($txtThumb.Text.Trim() -replace '\s', '')
        $saveResultBox.Saved = $true
        $dlg.Close()
    }.GetNewClosure())

    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnSave
    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)

    if ($saveResultBox.Saved) {
        if (Save-GraphSettings -TenantId $saveResultBox.TenantId -ClientId $saveResultBox.ClientId -CertificateThumbprint $saveResultBox.Thumbprint) {
            $Global:App.GraphTenantId = $saveResultBox.TenantId
            $Global:App.GraphClientId = $saveResultBox.ClientId
            $Global:App.GraphCertificateThumbprint = $saveResultBox.Thumbprint
            $Global:App.IntuneAppsCache.Clear()   # old cache may have been fetched under a different identity
            Write-Log "[OK] Settings saved. Client: $($saveResultBox.ClientId), Tenant: $($saveResultBox.TenantId).`r`n" ([System.Drawing.Color]::LightGreen)
            [System.Windows.Forms.MessageBox]::Show("Saved.", "Saved", "OK", "Information") | Out-Null
        }
    }
}
