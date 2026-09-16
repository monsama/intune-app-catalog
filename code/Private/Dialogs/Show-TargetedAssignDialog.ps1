function Global:Show-TargetedAssignDialog {
    param(
        [string]$AppId,
        [string]$AppName,
        [string[]]$RequiredGroups,
        [string[]]$AvailableGroups,
        [string[]]$UninstallGroups
    )

    if (-not $AppId) {
        [System.Windows.Forms.MessageBox]::Show("This app doesn't have an App ID yet. Use 'Deploy to Intune...' or 'Look up' first.", "No App ID", "OK", "Warning") | Out-Null
        return
    }

    $allGroups = @(@($RequiredGroups) + @($AvailableGroups) + @($UninstallGroups) | Select-Object -Unique)
    if ($allGroups.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("This app has no groups set in Required/Available/Uninstall. Add at least one group first.", "Nothing to assign", "OK", "Warning") | Out-Null
        return
    }

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $tenantId       = $Global:App.GraphTenantId
    $clientId       = $Global:App.GraphClientId
    $certThumb      = $Global:App.GraphCertificateThumbprint
    $targetedScript = $Global:App.EmbeddedTargetedAssignScript

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Assign Groups - $AppName"
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 560)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Creates any of these Entra ID groups that don't already exist, then sets THIS APP's Intune assignments to match exactly - replacing any existing assignments on this app. Does not touch group membership or any other app."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(530,48)
    $dlg.Controls.Add($lblIntro)

    $lblSummaryHeader = New-Object System.Windows.Forms.Label
    $lblSummaryHeader.Text = "Groups involved ($($allGroups.Count) total):"
    $lblSummaryHeader.Location = New-Object System.Drawing.Point(15,64)
    $lblSummaryHeader.AutoSize = $true
    $dlg.Controls.Add($lblSummaryHeader)

    $summaryLines = New-Object System.Collections.Generic.List[string]
    $summaryLines.Add("REQUIRED ($(@($RequiredGroups).Count)):")
    foreach ($g in $RequiredGroups) { $summaryLines.Add("  - $g") }
    $summaryLines.Add("")
    $summaryLines.Add("AVAILABLE ($(@($AvailableGroups).Count)):")
    foreach ($g in $AvailableGroups) { $summaryLines.Add("  - $g") }
    $summaryLines.Add("")
    $summaryLines.Add("UNINSTALL ($(@($UninstallGroups).Count)):")
    foreach ($g in $UninstallGroups) { $summaryLines.Add("  - $g") }

    $txtSummary = New-Object System.Windows.Forms.TextBox
    $txtSummary.Multiline = $true
    $txtSummary.ReadOnly = $true
    $txtSummary.ScrollBars = "Vertical"
    $txtSummary.Location = New-Object System.Drawing.Point(15,84)
    $txtSummary.Size = New-Object System.Drawing.Size(530,170)
    $txtSummary.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $txtSummary.Text = ($summaryLines -join "`r`n")
    $dlg.Controls.Add($txtSummary)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,262)
    $lblStatus.Size = New-Object System.Drawing.Size(530,18)
    $dlg.Controls.Add($lblStatus)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,282)
    $rtbLog.Size = New-Object System.Drawing.Size(530,180)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Assign"
    $btnRun.Location = New-Object System.Drawing.Point(370,476)
    $btnRun.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnRun)
    $runTip = New-Object System.Windows.Forms.ToolTip
    $runTip.SetToolTip($btnRun, "REPLACES this app's entire Intune assignment list with exactly the group(s) listed above - any assignment not in that list is removed, including ones this catalog doesn't know about.")

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Close"
    $btnCancel.Location = New-Object System.Drawing.Point(460,476)
    $btnCancel.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnCancel)

    $resultBox = @{ Success = $false }
    $procBox = @{ Proc = $null }

    $btnRun.Add_Click({
        $r = [System.Windows.Forms.MessageBox]::Show(
            "This REPLACES this app's entire Intune assignment list with exactly the $($allGroups.Count) group(s) listed above.`n`nAny assignment currently on this app that isn't in that list - including ones this catalog doesn't know about - will be REMOVED. The log will show the app's current assignments before making any change, so you can Cancel if something looks unexpected.`n`nContinue?",
            "Confirm", "YesNo", "Question")
        if ($r -ne "Yes") { return }

        $configPath = Join-Path $env:TEMP (".intunepkg_targetedassign_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_targetedassign_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            AppId                 = $AppId
            AppName               = $AppName
            RequiredGroups        = @($RequiredGroups)
            AvailableGroups       = @($AvailableGroups)
            UninstallGroups       = @($UninstallGroups)
            OutputResultPath      = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Show-ConfigWriteFailedError -ErrorMessage $_.Exception.Message
            return
        }

        $btnRun.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Working... see progress below. Cancel stops it."

        # Fresh aliases for the nested -OnComplete closure - see note in
        # Show-CreateInIntuneDialog.
        $btnRunRef = $btnRun
        $lblStatusRef = $lblStatus
        $resultBoxRef = $resultBox
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $targetedScript -TempScriptName ".intunepkg_embedded_targetedassign.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $btnRunRef.Enabled = $true
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $resultBoxRef.Success = $true
                        $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblStatusRef.Text = "Success - $($result.groupsCreated) group(s) newly created."
                    }
                    else {
                        Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
                    }
                }
                catch {
                    Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not read result (exit code $code)."
                }
            }
            else {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnCancel.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show("A step is currently running. Stop it and close this dialog?", "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnRun

    # $txtSummary is first in tab order (no button precedes it), so it's
    # what gets focus by default when the form first shows - the same
    # WinForms quirk confirmed live in Show-AppRegistrationGuideDialog
    # selects an entire TextBox's contents the instant it receives focus
    # that way. Read-only and never meant to be typed into, so point
    # initial focus at Assign instead.
    $dlg.Add_Shown({ $btnRun.Focus() }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
    return $resultBox.Success
}
