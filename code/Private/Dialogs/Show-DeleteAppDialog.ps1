function Global:Show-DeleteAppDialog {
    param([string]$AppId, [string]$AppName)

    if (-not $AppId) {
        # Same question the app editor's own "Delete from Intune..." button
        # already asks in this exact situation (no App ID at all) - offered
        # here too now, rather than this dialog just being a dead end that
        # tells you there's nothing to delete and leaves the (already
        # pointless, since there's nothing in Intune for it to refer to)
        # catalog entry sitting there regardless.
        $r = [System.Windows.Forms.MessageBox]::Show("`"$AppName`" doesn't have an App ID - there's nothing in Intune to delete.`n`nDelete it from the local catalog instead?", "No App ID", "YesNo", "Question")
        if ($r -ne "Yes") {
            return @{ Success = $false; RemovedFromCatalog = $false }
        }
        $noIdDelIdx = -1
        for ($ndi = 0; $ndi -lt $Global:App.Apps.Count; $ndi++) {
            if ($Global:App.Apps[$ndi].appName -eq $AppName) { $noIdDelIdx = $ndi; break }
        }
        if ($noIdDelIdx -ge 0) { $Global:App.Apps.RemoveAt($noIdDelIdx) }
        $Global:App.UnsavedChangesBox.Value = $true
        [void](Save-AppsToFile -Path $Global:App.LinkedFilePath)
        return @{ Success = $false; RemovedFromCatalog = $true }
    }

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $tenantId      = $Global:App.GraphTenantId
    $clientId      = $Global:App.GraphClientId
    $certThumb     = $Global:App.GraphCertificateThumbprint
    $deleteScript  = $Global:App.EmbeddedDeleteAppScript
    $appsRef       = $Global:App.Apps
    $unsavedBox    = $Global:App.UnsavedChangesBox
    $linkedFilePath = $Global:App.LinkedFilePath

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Delete from Intune - $AppName"
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 380)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblWarning = New-Object System.Windows.Forms.Label
    $lblWarning.Text = "This permanently deletes `"$AppName`" (App ID: $AppId) from Intune, including its content, assignments, and install history. This CANNOT be undone.`n`nOn success, you'll be asked whether to also remove the catalog entry itself, or just clear its App ID and keep the entry (and its group assignments) around to recreate later."
    $lblWarning.Location = New-Object System.Drawing.Point(15,12)
    $lblWarning.Size = New-Object System.Drawing.Size(530,90)
    $lblWarning.ForeColor = [System.Drawing.Color]::Firebrick
    $dlg.Controls.Add($lblWarning)

    $lblConfirmPrompt = New-Object System.Windows.Forms.Label
    $lblConfirmPrompt.Text = "Type the app name below to confirm:"
    $lblConfirmPrompt.Location = New-Object System.Drawing.Point(15,108)
    $lblConfirmPrompt.AutoSize = $true
    $dlg.Controls.Add($lblConfirmPrompt)

    $txtConfirm = New-Object System.Windows.Forms.TextBox
    $txtConfirm.Location = New-Object System.Drawing.Point(15,128)
    $txtConfirm.Size = New-Object System.Drawing.Size(530,24)
    $dlg.Controls.Add($txtConfirm)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,158)
    $lblStatus.Size = New-Object System.Drawing.Size(530,50)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,212)
    $rtbLog.Size = New-Object System.Drawing.Size(530,120)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete permanently"
    $btnDelete.Location = New-Object System.Drawing.Point(345,336)
    $btnDelete.Size = New-Object System.Drawing.Size(150,32)
    $btnDelete.Enabled = $false
    $dlg.Controls.Add($btnDelete)
    $deleteTip = New-Object System.Windows.Forms.ToolTip
    $deleteTip.SetToolTip($btnDelete, "Permanently removes this app from Intune only. Afterward you'll be asked whether to also remove it from the local catalog, or just clear its App ID and keep the entry.")

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(255,336)
    $btnCancel.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnCancel)

    $procBox = @{ Proc = $null }
    $deletedBox = @{ Success = $false; RemovedFromCatalog = $false }

    # Stored as a named closure (rather than inline in the button handler)
    # specifically so it can call itself again from within its own
    # -OnComplete - if the delete is blocked by a dependency and the user
    # confirms removing it, this re-runs with that dependency's App ID set,
    # rather than needing a second, separate code path to express the retry.
    # A mutable container, not a plain variable - $RunDelete needs to call
    # ITSELF recursively (from within its own -OnComplete, when retrying
    # after removing a blocking dependency), and .GetNewClosure() captures
    # variables BY VALUE at the moment it's called, not as a live reference
    # to their future state. A plain "$RunDelete = {...$RunDelete...}
    # .GetNewClosure()" self-reference would capture $RunDelete's value from
    # BEFORE the assignment even completes - which is $null, since the
    # variable doesn't exist yet at that instant - not the scriptblock being
    # assigned to it. A hashtable is a reference type: the closure captures
    # the CONTAINER, so reading .Value later (once it's actually been set)
    # correctly sees the real, fully-assigned scriptblock. Same pattern
    # already used everywhere else in this app for exactly this kind of
    # "closures need to see an updated value" problem (see $procBox above).
    $RunDeleteBox = @{ Value = $null }

    $RunDeleteBox.Value = {
        param([string]$RemoveDependencyFromAppId = "")

        $btnDelete.Enabled = $false
        $txtConfirm.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = if ($RemoveDependencyFromAppId) { "Removing the blocking dependency, then deleting..." } else { "Deleting..." }

        $configPath = Join-Path $env:TEMP (".intunepkg_deleteapp_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_deleteapp_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId                  = $tenantId
            ClientId                  = $clientId
            CertificateThumbprint     = $certThumb
            AppId                     = $AppId
            AppName                   = $AppName
            RemoveDependencyFromAppId = $RemoveDependencyFromAppId
            OutputResultPath          = $resultPath
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
        $btnDeleteRef = $btnDelete
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $deletedBoxRef = $deletedBox
        $dlgRef = $dlg
        $rtbLogRef = $rtbLog
        $RunDeleteBoxRef = $RunDeleteBox
        $AppNameRef = $AppName
        $appsRefRef = $appsRef
        $unsavedBoxRef = $unsavedBox
        $linkedFilePathRef = $linkedFilePath

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $deleteScript -TempScriptName ".intunepkg_embedded_deleteapp.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (-not (Test-Path $resultPathRef)) {
                $btnDeleteRef.Enabled = $true
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
                return
            }

            # Parsing kept in its OWN try/catch, separate from handling the
            # parsed result below - they were previously one block, which
            # meant a failure while HANDLING a successfully-parsed result
            # (e.g. the recursive retry call below, if it throws for any
            # reason) would get misreported as "Could not read result",
            # pointing at completely the wrong step.
            $result = $null
            try {
                $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
            }
            catch {
                $btnDeleteRef.Enabled = $true
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not read result (exit code $code): $($_.Exception.Message)"
                return
            }

            try {
                if ($result.success) {
                    $deletedBoxRef.Success = $true
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                    $lblStatusRef.Text = "Deleted from Intune."
                    # Asked now, right after Intune confirms the delete,
                    # rather than leaving the caller to always just clear
                    # the App ID and silently keep the entry around - most
                    # of the time deleting an app from Intune means you're
                    # actually done with it, not planning to recreate it, so
                    # leaving a now-orphaned catalog entry behind by default
                    # was the more surprising outcome, not the friendlier one.
                    $removeChoice = [System.Windows.Forms.MessageBox]::Show(
                        "Deleted `"$AppNameRef`" from Intune.`n`nAlso remove it from the local catalog entirely? Choosing No just clears its App ID here, keeping the entry (and its group assignments) so it's easy to recreate later.",
                        "Remove from catalog too?", "YesNo", "Question")
                    if ($removeChoice -eq "Yes") {
                        $delCatalogIdx = -1
                        for ($dci = 0; $dci -lt $appsRefRef.Count; $dci++) {
                            if ($appsRefRef[$dci].appName -eq $AppNameRef) { $delCatalogIdx = $dci; break }
                        }
                        if ($delCatalogIdx -ge 0) { $appsRefRef.RemoveAt($delCatalogIdx) }
                        $unsavedBoxRef.Value = $true
                        # Direct-save here too - the caller's own post-close
                        # handling (clearing the App ID and saving) is
                        # skipped entirely when RemovedFromCatalog is true,
                        # since there's no longer an entry left for it to
                        # act on, so this has to be the one place that
                        # actually persists the removal.
                        [void](Save-AppsToFile -Path $linkedFilePathRef)
                        $deletedBoxRef.RemovedFromCatalog = $true
                    }
                    $dlgRef.Close()
                }
                elseif ($result.blockingAppId) {
                    $r2 = [System.Windows.Forms.MessageBox]::Show(
                        "This app can't be deleted because Intune has it set as a dependency for `"$($result.blockingAppName)`".`n`nRemove that dependency relationship and then delete this app?",
                        "Dependency in the way", "YesNo", "Warning")
                    if ($r2 -eq "Yes") {
                        & $RunDeleteBoxRef.Value -RemoveDependencyFromAppId $result.blockingAppId
                    }
                    else {
                        $btnDeleteRef.Enabled = $true
                        $lblStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                        $lblStatusRef.Text = "Not deleted - still blocked by that dependency."
                    }
                }
                else {
                    $btnDeleteRef.Enabled = $true
                    Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
                }
            }
            catch {
                $btnDeleteRef.Enabled = $true
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Result was read, but something went wrong acting on it: $($_.Exception.Message)"
            }
        }.GetNewClosure()
    }.GetNewClosure()

    $txtConfirm.Add_TextChanged({
        $btnDelete.Enabled = ($txtConfirm.Text.Trim() -eq $AppName)
    }.GetNewClosure())

    $btnDelete.Add_Click({
        & $RunDeleteBox.Value
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
    $dlg.AcceptButton = $btnDelete

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
    # A hashtable now, not a plain bool - callers must check .Success
    # explicitly (a hashtable reference is truthy on its own, even one with
    # Success=$false), and .RemovedFromCatalog tells them whether they still
    # need to do their own "clear the App ID and save" step, or whether this
    # dialog already removed the whole entry (and saved) itself.
    return $deletedBox
}
