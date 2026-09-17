function Global:Show-PlatformScriptsDialog {
    <#
      The platform scripts in Intune (PowerShell scripts it runs on
      enrolled Windows devices): list them, add one, change one, delete
      one. Reading happens in this process (Start-PlatformScriptListFetch/
      Start-PlatformScriptDetailFetch); creating, changing, assigning and
      deleting run through EmbeddedScripts\PlatformScripts.ps1, whose
      output lands in the black box below like every other Intune action.
    #>

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $tenantId      = $Global:App.GraphTenantId
    $clientId      = $Global:App.GraphClientId
    $certThumb     = $Global:App.GraphCertificateThumbprint
    $scriptSource  = $Global:App.EmbeddedPlatformScriptsScript

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Platform scripts"
    $dlg.ClientSize = New-Object System.Drawing.Size(880, 620)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "PowerShell scripts Intune runs on enrolled Windows devices (Devices > Scripts and remediations > Platform scripts in the portal). A script runs once per device, and again whenever you change it here."
    $lblIntro.Location = New-Object System.Drawing.Point(15, 12)
    $lblIntro.Size = New-Object System.Drawing.Size(850, 36)
    $dlg.Controls.Add($lblIntro)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15, 54)
    $lblStatus.Size = New-Object System.Drawing.Size(620, 20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $lblStatus.Text = "Loading..."
    $dlg.Controls.Add($lblStatus)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Location = New-Object System.Drawing.Point(735, 50)
    $btnRefresh.Size = New-Object System.Drawing.Size(130, 26)
    $dlg.Controls.Add($btnRefresh)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15, 84)
    $grid.Size = New-Object System.Drawing.Size(850, 250)
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.ReadOnly = $true
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    foreach ($col in @(
        @{ Name = "DisplayName"; Header = "Name"; Weight = 26 }
        @{ Name = "FileName";    Header = "File"; Weight = 20 }
        @{ Name = "RunAs";       Header = "Runs as"; Weight = 14 }
        @{ Name = "RunAs32Bit";  Header = "32-bit"; Weight = 9 }
        @{ Name = "Signature";   Header = "Signature"; Weight = 14 }
        @{ Name = "Modified";    Header = "Last changed"; Weight = 17 }
    )) {
        $gridCol = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $gridCol.Name = $col.Name
        $gridCol.HeaderText = $col.Header
        $gridCol.FillWeight = $col.Weight
        $gridCol.ReadOnly = $true
        [void]$grid.Columns.Add($gridCol)
    }
    $dlg.Controls.Add($grid)

    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = "New script..."
    $btnNew.Location = New-Object System.Drawing.Point(15, 344)
    $btnNew.Size = New-Object System.Drawing.Size(130, 30)
    $dlg.Controls.Add($btnNew)

    $btnEdit = New-Object System.Windows.Forms.Button
    $btnEdit.Text = "Edit..."
    $btnEdit.Location = New-Object System.Drawing.Point(155, 344)
    $btnEdit.Size = New-Object System.Drawing.Size(130, 30)
    $btnEdit.Enabled = $false
    $dlg.Controls.Add($btnEdit)

    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete..."
    $btnDelete.Location = New-Object System.Drawing.Point(295, 344)
    $btnDelete.Size = New-Object System.Drawing.Size(130, 30)
    $btnDelete.Enabled = $false
    $dlg.Controls.Add($btnDelete)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15, 384)
    $rtbLog.Size = New-Object System.Drawing.Size(850, 182)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(780, 576)
    $btnClose.Size = New-Object System.Drawing.Size(85, 30)
    $dlg.Controls.Add($btnClose)

    $rowsBox = @{ Value = @() }
    $procBox = @{ Proc = $null }
    $busyBox = @{ Value = $false }

    $setBusy = {
        param([bool]$Busy)
        $busyBox.Value = $Busy
        $btnRefresh.Enabled = -not $Busy
        $btnNew.Enabled = -not $Busy
        $grid.Enabled = -not $Busy
        $hasSelection = (-not $Busy) -and ($grid.SelectedRows.Count -gt 0)
        $btnEdit.Enabled = $hasSelection
        $btnDelete.Enabled = $hasSelection
    }.GetNewClosure()

    $populateGrid = {
        $grid.Rows.Clear()
        foreach ($row in @($rowsBox.Value)) {
            $index = $grid.Rows.Add($row.DisplayName, $row.FileName, $row.RunAs, $row.RunAs32Bit, $row.Signature, $row.Modified)
            $grid.Rows[$index].Tag = $row
            $grid.Rows[$index].Cells[0].ToolTipText = if ($row.Description) { [string]$row.Description } else { [string]$row.DisplayName }
        }
        $grid.ClearSelection()
        $grid.CurrentCell = $null
        $count = @($rowsBox.Value).Count
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = if ($count -eq 0) { "No platform scripts in this tenant yet." } elseif ($count -eq 1) { "1 platform script." } else { "$count platform scripts." }
    }.GetNewClosure()

    $loadList = {
        & $setBusy $true
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Loading from Intune..."
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh aliases for the nested -OnComplete closure - see the note at
        # the top of Show-CreateInIntuneDialog.
        $dlgRef = $dlg
        $lblStatusRef = $lblStatus
        $rowsBoxRef = $rowsBox
        $populateGridRef = $populateGrid
        $setBusyRef = $setBusy
        $rtbLogRef = $rtbLog

        Start-PlatformScriptListFetch -LogBox $rtbLogRef -OnComplete {
            param($ok, $errMsg, $rows)
            try {
                if ($dlgRef.IsDisposed) { return }
                if (-not $ok) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Could not load: $errMsg"
                    return
                }
                $rowsBoxRef.Value = @($rows)
                & $populateGridRef
            }
            finally {
                if (-not $dlgRef.IsDisposed) {
                    & $setBusyRef $false
                    $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
                    [System.Windows.Forms.Application]::DoEvents()
                    [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
                }
            }
        }.GetNewClosure()
    }.GetNewClosure()

    # Create/update/delete all run the same embedded script and end the same
    # way: reload the list so the grid shows what Intune actually has now.
    $runScriptAction = {
        param($Config, [string]$StepText)
        & $setBusy $true
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = $StepText
        $rtbLog.Clear()

        $configPath = Join-Path $env:TEMP (".intunepkg_platformscript_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_platformscript_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $Config.OutputResultPath = $resultPath
        $Config.TenantId = $tenantId
        $Config.ClientId = $clientId
        $Config.CertificateThumbprint = $certThumb
        try {
            $configJson = [pscustomobject]$Config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJson, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Write-DialogError -StatusLabel $lblStatus -LogBox $rtbLog -ErrorMessage "Could not write the config file: $($_.Exception.Message)"
            & $setBusy $false
            return
        }

        $dlgRef = $dlg
        $lblStatusRef = $lblStatus
        $rtbLogRef = $rtbLog
        $procBoxRef = $procBox
        $setBusyRef = $setBusy
        $loadListRef = $loadList
        $configPathRef = $configPath
        $resultPathRef = $resultPath

        $procBox.Proc = Start-PipelineProcess -ScriptContent $scriptSource -TempScriptName ".intunepkg_embedded_platformscript.ps1" `
            -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue
            if ($dlgRef.IsDisposed) {
                Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                return
            }
            $result = $null
            if (Test-Path $resultPathRef) {
                try { $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json } catch { }
                Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
            }
            & $setBusyRef $false
            if ($result -and $result.success) {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                $lblStatusRef.Text = "Done."
                & $loadListRef
            }
            elseif ($result) {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage $result.error
            }
            else {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See the log above."
            }
        }.GetNewClosure()
    }.GetNewClosure()

    $btnNew.Add_Click({
        $entered = Show-PlatformScriptEditorDialog
        if (-not $entered) { return }
        & $runScriptAction @{
            Mode                  = "Save"
            ScriptId              = ""
            DisplayName           = $entered.DisplayName
            Description           = $entered.Description
            FileName              = $entered.FileName
            ScriptContentBase64   = (ConvertTo-PlatformScriptBase64 $entered.ScriptContent)
            RunAsAccount          = $entered.RunAsAccount
            RunAs32Bit            = $entered.RunAs32Bit
            EnforceSignatureCheck = $entered.EnforceSignatureCheck
            GroupNames            = @($entered.GroupNames)
            AssignGroups          = $entered.AssignGroups
        } "Creating '$($entered.DisplayName)' in Intune..."
    }.GetNewClosure())

    $btnEdit.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { return }
        $selected = $grid.SelectedRows[0].Tag
        & $setBusy $true
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Loading '$($selected.DisplayName)' from Intune..."

        $dlgRef = $dlg
        $lblStatusRef = $lblStatus
        $rtbLogRef = $rtbLog
        $setBusyRef = $setBusy
        $selectedRef = $selected
        $runScriptActionRef = $runScriptAction

        Start-PlatformScriptDetailFetch -ScriptId $selected.Id -LogBox $rtbLog -OnComplete {
            param($ok, $errMsg, $detail)
            if ($dlgRef.IsDisposed) { return }
            & $setBusyRef $false
            if (-not $ok) {
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not load the script: $errMsg"
                return
            }
            $lblStatusRef.Text = ""
            $edited = Show-PlatformScriptEditorDialog -ScriptId $selectedRef.Id -DisplayName $detail.Script.DisplayName `
                -Description $detail.Script.Description -FileName $detail.Script.FileName -ScriptContent $detail.ScriptContent `
                -RunAsAccount $(if ($detail.Script.RunAs -eq 'Signed-in user') { 'user' } else { 'system' }) `
                -RunAs32Bit ($detail.Script.RunAs32Bit -eq 'Yes') -EnforceSignatureCheck ($detail.Script.Signature -eq 'Required') `
                -GroupNames @($detail.GroupNames) -GroupsKnown ([bool]$detail.GroupsKnown)
            if (-not $edited) { return }
            & $runScriptActionRef @{
                Mode                  = "Save"
                ScriptId              = $selectedRef.Id
                DisplayName           = $edited.DisplayName
                Description           = $edited.Description
                FileName              = $edited.FileName
                ScriptContentBase64   = (ConvertTo-PlatformScriptBase64 $edited.ScriptContent)
                RunAsAccount          = $edited.RunAsAccount
                RunAs32Bit            = $edited.RunAs32Bit
                EnforceSignatureCheck = $edited.EnforceSignatureCheck
                GroupNames            = @($edited.GroupNames)
                AssignGroups          = $edited.AssignGroups
            } "Saving '$($edited.DisplayName)' to Intune..."
        }.GetNewClosure()
    }.GetNewClosure())

    $btnDelete.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { return }
        $selected = $grid.SelectedRows[0].Tag
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Permanently delete the platform script '$($selected.DisplayName)' from Intune?`n`nDevices that already ran it keep whatever it did - deleting only stops Intune running it again. This can't be undone.",
            "Delete platform script", "YesNo", "Warning", "Button2")
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        & $runScriptAction @{
            Mode        = "Delete"
            ScriptId    = $selected.Id
            DisplayName = $selected.DisplayName
        } "Deleting '$($selected.DisplayName)'..."
    }.GetNewClosure())

    $grid.Add_SelectionChanged({
        if ($busyBox.Value) { return }
        $hasSelection = $grid.SelectedRows.Count -gt 0
        $btnEdit.Enabled = $hasSelection
        $btnDelete.Enabled = $hasSelection
    }.GetNewClosure())
    $grid.Add_CellDoubleClick({
        param($sender, $e)
        if ($e.RowIndex -ge 0 -and $btnEdit.Enabled) { $btnEdit.PerformClick() }
    }.GetNewClosure())

    $btnRefresh.Add_Click({ & $loadList }.GetNewClosure())
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    Register-CloseConfirmation -Dialog $dlg -GetQuestion {
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            "A change is still being sent to Intune. Stop it and close?`n`nWhatever already went through stays - reopen this window to see what Intune has now."
        }
    }.GetNewClosure() -OnConfirmed { $procBox.Proc.Kill() }.GetNewClosure()

    $dlg.Add_Shown({ & $loadList }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
