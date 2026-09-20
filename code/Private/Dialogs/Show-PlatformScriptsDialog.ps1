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
    $dlg.ClientSize = New-Object System.Drawing.Size(1040, 620)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "PowerShell scripts Intune runs on enrolled Windows devices (Devices > Scripts and remediations > Platform scripts in the portal). A script runs once per device, and again whenever you change it here."
    $lblIntro.Location = New-Object System.Drawing.Point(15, 12)
    $lblIntro.Size = New-Object System.Drawing.Size(1010, 36)
    $dlg.Controls.Add($lblIntro)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15, 54)
    $lblStatus.Size = New-Object System.Drawing.Size(620, 20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $lblStatus.Text = "Loading..."
    $dlg.Controls.Add($lblStatus)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Location = New-Object System.Drawing.Point(895, 50)
    $btnRefresh.Size = New-Object System.Drawing.Size(130, 26)
    $dlg.Controls.Add($btnRefresh)

    $grid = New-Object System.Windows.Forms.DataGridView
    Set-AppGridStyle -Grid $grid
    $grid.Location = New-Object System.Drawing.Point(15, 84)
    $grid.Size = New-Object System.Drawing.Size(1010, 250)
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
        @{ Name = "Signature";   Header = "Signature"; Weight = 12 }
        @{ Name = "Modified";    Header = "Last changed"; Weight = 15 }
        # Whether this tenant's script also exists in the local catalog,
        # and whether the two still agree - the same question the app
        # catalog answers with its own drift check.
        @{ Name = "Local";       Header = "Local copy"; Weight = 14 }
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
    $btnEdit.Location = New-Object System.Drawing.Point(315, 344)
    $btnEdit.Size = New-Object System.Drawing.Size(130, 30)
    $btnEdit.Enabled = $false
    $dlg.Controls.Add($btnEdit)

    $btnRunStatus = New-Object System.Windows.Forms.Button
    $btnRunStatus.Text = "Run status..."
    $btnRunStatus.Location = New-Object System.Drawing.Point(455, 344)
    $btnRunStatus.Size = New-Object System.Drawing.Size(130, 30)
    $btnRunStatus.Enabled = $false
    $dlg.Controls.Add($btnRunStatus)

    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete..."
    $btnDelete.Location = New-Object System.Drawing.Point(595, 344)
    $btnDelete.Size = New-Object System.Drawing.Size(130, 30)
    $btnDelete.Enabled = $false
    $dlg.Controls.Add($btnDelete)

    # Local copies of what's in the tenant, the same way the app catalog
    # keeps apps: one JSON per script under data\script-data. A script that
    # only ever lived in Intune had nowhere to be written before it went
    # live, and nothing to compare against afterwards.
    $scriptCatalogPath = Get-AppFolder -Kind Scripts

    $btnNewLocal = New-Object System.Windows.Forms.Button
    $btnNewLocal.Text = "New local script..."
    $btnNewLocal.Location = New-Object System.Drawing.Point(155, 344)
    $btnNewLocal.Size = New-Object System.Drawing.Size(150, 30)
    $dlg.Controls.Add($btnNewLocal)
    $newLocalTip = New-Object System.Windows.Forms.ToolTip
    $newLocalTip.SetToolTip($btnNewLocal, "Writes a script to the local catalog without sending anything to Intune - for preparing one before it goes live. It appears in the list as 'Local only'; Edit it and save to create it in Intune.")

    $btnSaveLocal = New-Object System.Windows.Forms.Button
    $btnSaveLocal.Text = "Save local copies"
    $btnSaveLocal.Location = New-Object System.Drawing.Point(735, 344)
    $btnSaveLocal.Size = New-Object System.Drawing.Size(140, 30)
    $dlg.Controls.Add($btnSaveLocal)
    $saveLocalTip = New-Object System.Windows.Forms.ToolTip
    $saveLocalTip.SetToolTip($btnSaveLocal, "Reads every listed script in full - body and assigned groups - and saves it under data\script-data. Read-only against Intune. A script no longer in the tenant loses its local file, so the folder matches what is actually there.")

    $btnOpenLocal = New-Object System.Windows.Forms.Button
    $btnOpenLocal.Text = "Open local folder"
    $btnOpenLocal.Location = New-Object System.Drawing.Point(885, 344)
    $btnOpenLocal.Size = New-Object System.Drawing.Size(140, 30)
    $dlg.Controls.Add($btnOpenLocal)
    $openLocalTip = New-Object System.Windows.Forms.ToolTip
    $openLocalTip.SetToolTip($btnOpenLocal, "Opens data\script-data, where the local copies live - one JSON per script, readable and diffable.")
    $btnOpenLocal.Add_Click({
        try {
            [void][IO.Directory]::CreateDirectory($scriptCatalogPath)
            Start-Process $scriptCatalogPath
        }
        catch { Write-DialogLogLine -LogBox $rtbLog -Text "[FAILED] Could not open $scriptCatalogPath : $($_.Exception.Message)`r`n" }
    }.GetNewClosure())

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15, 384)
    $rtbLog.Size = New-Object System.Drawing.Size(1010, 182)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(940, 576)
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
        $btnRunStatus.Enabled = $hasSelection
        $btnDelete.Enabled = $hasSelection
        $btnSaveLocal.Enabled = (-not $Busy) -and (@($rowsBox.Value).Count -gt 0)
    }.GetNewClosure()

    $populateGrid = {
        $grid.Rows.Clear()
        # Read once per refresh, not once per row
        $localByName = @{}
        foreach ($localScript in @((Import-ScriptsFromFolder -Path $scriptCatalogPath).Scripts)) {
            if ($localScript.displayName) { $localByName[[string]$localScript.displayName] = $localScript }
        }
        foreach ($row in @($rowsBox.Value)) {
            $localState = "Not saved here"
            $local = $localByName[[string]$row.DisplayName]
            if ($local) {
                # Only the fields a listing actually knows: the body and the
                # groups aren't in the list response, so claiming they match
                # would be claiming something never looked at.
                $listDiffs = @(Get-ScriptFieldDiffs -Local $local -Remote $row | Where-Object { $_.Field -notin @('scriptContent', 'assignedGroups') })
                $localState = if ($listDiffs.Count -eq 0) { "Saved" } else { "Differs ($($listDiffs.Count))" }
            }
            $index = $grid.Rows.Add($row.DisplayName, $row.FileName, $row.RunAs, $row.RunAs32Bit, $row.Signature, $row.Modified, $localState)
            if ($localState -like 'Differs*') { $grid.Rows[$index].Cells[6].Style.ForeColor = [System.Drawing.Color]::DarkOrange }
            elseif ($localState -eq 'Saved') { $grid.Rows[$index].Cells[6].Style.ForeColor = [System.Drawing.Color]::SeaGreen }
            $grid.Rows[$index].Cells[6].ToolTipText = if ($local) { "A copy of this script is in the local catalog. 'Differs' compares only what a listing shows - the body and groups are checked when you save." } else { "No local copy yet - use 'Save local copies' to keep one." }
            $grid.Rows[$index].Tag = $row
            if ($local) { [void]$localByName.Remove([string]$row.DisplayName) }
            $grid.Rows[$index].Cells[0].ToolTipText = if ($row.Description) { [string]$row.Description } else { [string]$row.DisplayName }
        }
        # Whatever is left in the local catalog exists only here - written
        # before it was ever sent, or left behind by a script since deleted
        # from the tenant. Shown as rows too, because a local script you
        # can't see is a local script you'll forget to push.
        $localOnlyCount = 0
        foreach ($orphan in @($localByName.Values | Sort-Object displayName)) {
            $orphanRunAs = if ($orphan.runAsAccount -eq 'user') { "Signed-in user" } else { "System" }
            $orphan32Bit = if ($orphan.runAs32Bit) { "Yes" } else { "No" }
            $orphanSignature = if ($orphan.enforceSignatureCheck) { "Required" } else { "Not required" }
            $index = $grid.Rows.Add($orphan.displayName, $orphan.fileName, $orphanRunAs, $orphan32Bit, $orphanSignature, "", "Local only")
            $grid.Rows[$index].Cells[6].Style.ForeColor = [System.Drawing.Color]::MediumBlue
            $grid.Rows[$index].Cells[6].ToolTipText = "This script is in the local catalog but not in this tenant. Use Edit to review it, then save to create it in Intune."
            # Marked so Edit and Delete know there is no Intune app behind it
            $grid.Rows[$index].Tag = [pscustomobject]@{
                Id = ""; DisplayName = $orphan.displayName; Description = $orphan.description
                FileName = $orphan.fileName; RunAs = $orphan.runAsAccount
                RunAs32Bit = $orphan.runAs32Bit; Signature = $orphan.enforceSignatureCheck
                LocalOnly = $true; LocalRecord = $orphan
            }
            $localOnlyCount++
        }
        $grid.ClearSelection()
        $grid.CurrentCell = $null
        $count = @($rowsBox.Value).Count
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = if ($count -eq 0) { "No platform scripts in this tenant yet." } elseif ($count -eq 1) { "1 platform script." } else { "$count platform scripts." }
        if ($localOnlyCount -gt 0) { $lblStatus.Text += " $localOnlyCount only in the local catalog." }
    }.GetNewClosure()

    # Saving means reading each script in full, one at a time - a listing has
    # no body and no groups. A queue rather than a loop, because each read is
    # a background fetch that finishes later.
    $SaveLocalCopies = {
        $pending = New-Object System.Collections.Generic.Queue[object]
        foreach ($row in @($rowsBox.Value)) { $pending.Enqueue($row) }
        $total = $pending.Count
        if ($total -eq 0) { return }
        $collected = New-Object System.Collections.Generic.List[object]
        & $setBusy $true
        Write-DialogLogLine -LogBox $rtbLog -Text "[INFO] Reading $total script(s) in full, to save local copies...`r`n"

        $rtbLogRef = $rtbLog
        $lblStatusRef = $lblStatus
        $setBusyRef = $setBusy
        $populateGridRef = $populateGrid
        $catalogPathRef = $scriptCatalogPath
        $dlgRef = $dlg

        # Held in a box so the fetch's own callback can reach the next step
        # without the scriptblock having to refer to itself by name.
        $stepBox = @{ Next = $null }
        $stepBox.Next = {
            if ($pending.Count -eq 0) {
                $saveResult = Save-ScriptsToFolder -Path $catalogPathRef -Scripts $collected
                foreach ($problem in @($saveResult.Errors)) {
                    Write-DialogLogLine -LogBox $rtbLogRef -Text "[FAILED] $problem`r`n"
                }
                $removedNote = if ($saveResult.Removed -gt 0) { ", $($saveResult.Removed) no longer in the tenant removed" } else { "" }
                Write-DialogLogLine -LogBox $rtbLogRef -Text "[OK] Saved $($saveResult.Saved) local copy/copies$removedNote.`r`n" -MirrorToMainLog
                $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                $lblStatusRef.Text = "Local copies saved: $($saveResult.Saved) script(s)."
                & $setBusyRef $false
                & $populateGridRef
                return
            }
            $row = $pending.Dequeue()
            $lblStatusRef.ForeColor = [System.Drawing.Color]::DimGray
            $lblStatusRef.Text = "Reading '$($row.DisplayName)' ($($total - $pending.Count) of $total)..."
            Start-PlatformScriptDetailFetch -ScriptId $row.Id -LogBox $rtbLogRef -OnComplete {
                param($ok, $errMsg, $detail)
                if ($dlgRef.IsDisposed) { return }
                if ($ok) {
                    # From the detail, so the body and groups are the real
                    # ones rather than what a listing could guess.
                    $collected.Add((ConvertTo-ScriptRecord @{
                        id                    = $row.Id
                        displayName           = $row.DisplayName
                        description           = $row.Description
                        fileName              = $row.FileName
                        runAsAccount          = $row.RunAs
                        runAs32Bit            = $row.RunAs32Bit
                        enforceSignatureCheck = $row.Signature
                        scriptContent         = [string]$detail.ScriptContent
                        assignedGroups        = @($detail.GroupNames)
                    }))
                }
                else {
                    Write-DialogLogLine -LogBox $rtbLogRef -Text "[FAILED] '$($row.DisplayName)' couldn't be read, so it has no local copy: $errMsg`r`n"
                }
                & $stepBox.Next
            }.GetNewClosure()
        }.GetNewClosure()
        & $stepBox.Next
    }.GetNewClosure()
    $btnSaveLocal.Add_Click({ & $SaveLocalCopies }.GetNewClosure())

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
                    # Through Write-DialogError, so a refused permission says
                    # which one to add rather than only "Forbidden".
                    Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "Could not load the platform scripts: $errMsg"
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

    # Writes one script into the local catalog without touching the others
    $SaveOneLocally = {
        param($Record)
        $existing = @((Import-ScriptsFromFolder -Path $scriptCatalogPath).Scripts |
            Where-Object { [string]$_.displayName -ne [string]$Record.displayName })
        $saveResult = Save-ScriptsToFolder -Path $scriptCatalogPath -Scripts (@($existing) + @($Record))
        foreach ($problem in @($saveResult.Errors)) {
            Write-DialogLogLine -LogBox $rtbLog -Text "[FAILED] $problem`r`n"
        }
        return ($saveResult.Errors.Count -eq 0)
    }.GetNewClosure()

    $btnNewLocal.Add_Click({
        $entered = Show-PlatformScriptEditorDialog
        if (-not $entered) { return }
        $record = ConvertTo-ScriptRecord @{
            displayName           = $entered.DisplayName
            description           = $entered.Description
            fileName              = $entered.FileName
            runAsAccount          = $entered.RunAsAccount
            runAs32Bit            = $entered.RunAs32Bit
            enforceSignatureCheck = $entered.EnforceSignatureCheck
            scriptContent         = $entered.ScriptContent
            assignedGroups        = @($entered.GroupNames)
        }
        if (& $SaveOneLocally $record) {
            Write-DialogLogLine -LogBox $rtbLog -Text "[OK] '$($record.displayName)' saved to the local catalog. Nothing was sent to Intune - use Edit on its row to create it there.`r`n" -MirrorToMainLog
            $lblStatus.ForeColor = [System.Drawing.Color]::SeaGreen
            $lblStatus.Text = "'$($record.displayName)' saved locally - not in Intune yet."
            & $populateGrid
        }
    }.GetNewClosure())

    $btnEdit.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { return }
        $selected = $grid.SelectedRows[0].Tag

        # A local-only script has nothing in Intune to read, so it opens
        # straight from its file; saving then CREATES it there.
        if ($selected.LocalOnly) {
            $local = $selected.LocalRecord
            $edited = Show-PlatformScriptEditorDialog -DisplayName $local.displayName -Description $local.description `
                -FileName $local.fileName -ScriptContent $local.scriptContent -RunAsAccount $local.runAsAccount `
                -RunAs32Bit ([bool]$local.runAs32Bit) -EnforceSignatureCheck ([bool]$local.enforceSignatureCheck) `
                -GroupNames @($local.assignedGroups)
            if (-not $edited) { return }
            [void](& $SaveOneLocally (ConvertTo-ScriptRecord @{
                displayName           = $edited.DisplayName
                description           = $edited.Description
                fileName              = $edited.FileName
                runAsAccount          = $edited.RunAsAccount
                runAs32Bit            = $edited.RunAs32Bit
                enforceSignatureCheck = $edited.EnforceSignatureCheck
                scriptContent         = $edited.ScriptContent
                assignedGroups        = @($edited.GroupNames)
            }))
            & $runScriptAction @{
                Mode                  = "Save"
                ScriptId              = ""
                DisplayName           = $edited.DisplayName
                Description           = $edited.Description
                FileName              = $edited.FileName
                ScriptContentBase64   = (ConvertTo-PlatformScriptBase64 $edited.ScriptContent)
                RunAsAccount          = $edited.RunAsAccount
                RunAs32Bit            = $edited.RunAs32Bit
                EnforceSignatureCheck = $edited.EnforceSignatureCheck
                GroupNames            = @($edited.GroupNames)
                AssignGroups          = $edited.AssignGroups
            } "Creating '$($edited.DisplayName)' in Intune from the local copy..."
            return
        }

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
        $btnRunStatus.Enabled = $hasSelection
        $btnDelete.Enabled = $hasSelection
    }.GetNewClosure())
    $grid.Add_CellDoubleClick({
        param($sender, $e)
        if ($e.RowIndex -ge 0 -and $btnEdit.Enabled) { $btnEdit.PerformClick() }
    }.GetNewClosure())

    $btnRunStatus.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { return }
        $selected = $grid.SelectedRows[0].Tag
        Show-PlatformScriptRunStatusDialog -ScriptId $selected.Id -ScriptName $selected.DisplayName
    }.GetNewClosure())

    $btnRefresh.Add_Click({ & $loadList }.GetNewClosure())
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    # Enter opens the selected script, matching the double-click on the list and Enter on the main catalog grid. Delete stays a click - it is the one button here that destroys something.
    $dlg.AcceptButton = $btnEdit
    Register-CloseConfirmation -Dialog $dlg -GetQuestion {
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            "A change is still being sent to Intune. Stop it and close?`n`nWhatever already went through stays - reopen this window to see what Intune has now."
        }
    }.GetNewClosure() -OnConfirmed { $procBox.Proc.Kill() }.GetNewClosure()

    $dlg.Add_Shown({ & $loadList }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
