function Global:Show-PlatformScriptEditorDialog {
    <#
      One platform script: its name, the script itself, how Intune runs it
      and which groups get it. Collects and validates only - the caller
      (Show-PlatformScriptsDialog) is what sends it to Intune.

      Returns $null on Cancel, otherwise:
      @{ DisplayName; Description; FileName; ScriptContent; RunAsAccount;
         RunAs32Bit; EnforceSignatureCheck; GroupNames; AssignGroups }
    #>
    param(
        [string]$ScriptId,
        [string]$DisplayName = "",
        [string]$Description = "",
        [string]$FileName = "",
        [string]$ScriptContent = "",
        [string]$RunAsAccount = "system",
        [bool]$RunAs32Bit = $false,
        [bool]$EnforceSignatureCheck = $false,
        [string[]]$GroupNames = @(),
        [bool]$GroupsKnown = $true
    )

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = if ($ScriptId) { "Edit platform script - $DisplayName" } else { "New platform script" }
    $dlg.ClientSize = New-Object System.Drawing.Size(820, 700)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "A PowerShell script Intune runs on the devices of the groups you pick below. It runs once per device (again only if you change it here), 64-bit and as the system account unless you say otherwise."
    $lblIntro.Location = New-Object System.Drawing.Point(15, 12)
    $lblIntro.Size = New-Object System.Drawing.Size(790, 36)
    $dlg.Controls.Add($lblIntro)

    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = "Name"
    $lblName.Location = New-Object System.Drawing.Point(15, 56)
    $lblName.Size = New-Object System.Drawing.Size(120, 20)
    $dlg.Controls.Add($lblName)
    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Location = New-Object System.Drawing.Point(15, 78)
    $txtName.Size = New-Object System.Drawing.Size(500, 24)
    $txtName.Text = $DisplayName
    $dlg.Controls.Add($txtName)

    $lblFileName = New-Object System.Windows.Forms.Label
    $lblFileName.Text = "File name (optional)"
    $lblFileName.Location = New-Object System.Drawing.Point(535, 56)
    $lblFileName.Size = New-Object System.Drawing.Size(270, 20)
    $dlg.Controls.Add($lblFileName)
    $txtFileName = New-Object System.Windows.Forms.TextBox
    $txtFileName.Location = New-Object System.Drawing.Point(535, 78)
    $txtFileName.Size = New-Object System.Drawing.Size(270, 24)
    $txtFileName.Text = $FileName
    $dlg.Controls.Add($txtFileName)

    $lblDescription = New-Object System.Windows.Forms.Label
    $lblDescription.Text = "Description (optional)"
    $lblDescription.Location = New-Object System.Drawing.Point(15, 110)
    $lblDescription.Size = New-Object System.Drawing.Size(300, 20)
    $dlg.Controls.Add($lblDescription)
    $txtDescription = New-Object System.Windows.Forms.TextBox
    $txtDescription.Location = New-Object System.Drawing.Point(15, 132)
    $txtDescription.Size = New-Object System.Drawing.Size(790, 24)
    $txtDescription.Text = $Description
    $dlg.Controls.Add($txtDescription)

    $lblScript = New-Object System.Windows.Forms.Label
    $lblScript.Text = "Script - paste it here, or load a .ps1 file"
    $lblScript.Location = New-Object System.Drawing.Point(15, 166)
    $lblScript.Size = New-Object System.Drawing.Size(500, 20)
    $dlg.Controls.Add($lblScript)

    $btnLoadFile = New-Object System.Windows.Forms.Button
    $btnLoadFile.Text = "Load .ps1 file..."
    $btnLoadFile.Location = New-Object System.Drawing.Point(675, 162)
    $btnLoadFile.Size = New-Object System.Drawing.Size(130, 26)
    $dlg.Controls.Add($btnLoadFile)

    $txtScript = New-Object System.Windows.Forms.TextBox
    $txtScript.Location = New-Object System.Drawing.Point(15, 190)
    $txtScript.Size = New-Object System.Drawing.Size(790, 300)
    $txtScript.Multiline = $true
    $txtScript.ScrollBars = "Both"
    $txtScript.WordWrap = $false
    $txtScript.Font = New-Object System.Drawing.Font("Consolas", 9)
    $txtScript.Text = ConvertTo-DisplayLineEndings $ScriptContent
    $dlg.Controls.Add($txtScript)

    $grpHow = New-Object System.Windows.Forms.GroupBox
    $grpHow.Text = "How Intune runs it"
    $grpHow.Location = New-Object System.Drawing.Point(15, 500)
    $grpHow.Size = New-Object System.Drawing.Size(390, 118)
    $dlg.Controls.Add($grpHow)

    $lblRunAs = New-Object System.Windows.Forms.Label
    $lblRunAs.Text = "Run this script as"
    $lblRunAs.Location = New-Object System.Drawing.Point(12, 26)
    $lblRunAs.Size = New-Object System.Drawing.Size(150, 20)
    $grpHow.Controls.Add($lblRunAs)
    $cmbRunAs = New-Object System.Windows.Forms.ComboBox
    $cmbRunAs.DropDownStyle = "DropDownList"
    $cmbRunAs.Location = New-Object System.Drawing.Point(165, 22)
    $cmbRunAs.Size = New-Object System.Drawing.Size(210, 24)
    [void]$cmbRunAs.Items.Add("System account")
    [void]$cmbRunAs.Items.Add("Signed-in user")
    $cmbRunAs.SelectedIndex = if ($RunAsAccount -eq 'user') { 1 } else { 0 }
    $grpHow.Controls.Add($cmbRunAs)

    $chk32Bit = New-Object System.Windows.Forms.CheckBox
    $chk32Bit.Text = "Run in 32-bit PowerShell"
    $chk32Bit.Location = New-Object System.Drawing.Point(12, 56)
    $chk32Bit.Size = New-Object System.Drawing.Size(360, 22)
    $chk32Bit.Checked = $RunAs32Bit
    $grpHow.Controls.Add($chk32Bit)

    $chkSignature = New-Object System.Windows.Forms.CheckBox
    $chkSignature.Text = "Only run if the script is signed by a trusted publisher"
    $chkSignature.Location = New-Object System.Drawing.Point(12, 82)
    $chkSignature.Size = New-Object System.Drawing.Size(360, 22)
    $chkSignature.Checked = $EnforceSignatureCheck
    $grpHow.Controls.Add($chkSignature)

    $grpGroups = New-Object System.Windows.Forms.GroupBox
    $grpGroups.Text = "Groups that get this script"
    $grpGroups.Location = New-Object System.Drawing.Point(420, 500)
    $grpGroups.Size = New-Object System.Drawing.Size(385, 118)
    $dlg.Controls.Add($grpGroups)

    $clbGroups = New-Object System.Windows.Forms.CheckedListBox
    $clbGroups.Location = New-Object System.Drawing.Point(10, 22)
    $clbGroups.Size = New-Object System.Drawing.Size(245, 84)
    $clbGroups.CheckOnClick = $true
    $allGroupOptions = @(@($Global:App.FavoriteGroups) + @($GroupNames) | Where-Object { $_ } | Select-Object -Unique)
    foreach ($groupName in $allGroupOptions) {
        $index = $clbGroups.Items.Add($groupName)
        if (@($GroupNames) -contains $groupName) { $clbGroups.SetItemChecked($index, $true) }
    }
    Add-RemovableItemContextMenu -CheckedListBox $clbGroups
    $grpGroups.Controls.Add($clbGroups)

    $btnAddGroup = New-Object System.Windows.Forms.Button
    $btnAddGroup.Text = "+ Group..."
    $btnAddGroup.Location = New-Object System.Drawing.Point(262, 22)
    $btnAddGroup.Size = New-Object System.Drawing.Size(113, 28)
    $btnAddGroup.Add_Click({
        $picked = Show-EntraMemberPicker
        if ($picked) {
            $picked = $picked.Trim()
            if ($picked -and ($clbGroups.Items -notcontains $picked)) {
                $index = $clbGroups.Items.Add($picked)
                $clbGroups.SetItemChecked($index, $true)
            }
        }
    }.GetNewClosure())
    $grpGroups.Controls.Add($btnAddGroup)

    $lblGroupsNote = New-Object System.Windows.Forms.Label
    $lblGroupsNote.Location = New-Object System.Drawing.Point(262, 54)
    $lblGroupsNote.Size = New-Object System.Drawing.Size(113, 52)
    $lblGroupsNote.ForeColor = [System.Drawing.Color]::DimGray
    $lblGroupsNote.Text = if ($GroupsKnown) { "Saving replaces this script's assignments in Intune." } else { "Its current groups couldn't be read - leave empty to keep them." }
    $grpGroups.Controls.Add($lblGroupsNote)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Location = New-Object System.Drawing.Point(15, 626)
    $lblHint.Size = New-Object System.Drawing.Size(560, 36)
    $lblHint.ForeColor = [System.Drawing.Color]::DimGray
    $lblHint.Text = "Nothing is sent to Intune until you click Save. A script Intune has already run on a device runs again after you change it here."
    $dlg.Controls.Add($lblHint)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = if ($ScriptId) { "Save changes" } else { "Create in Intune" }
    $btnSave.Location = New-Object System.Drawing.Point(585, 630)
    $btnSave.Size = New-Object System.Drawing.Size(130, 32)
    $dlg.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(722, 630)
    $btnCancel.Size = New-Object System.Drawing.Size(83, 32)
    $dlg.Controls.Add($btnCancel)

    $resultBox = @{ Value = $null }

    $btnLoadFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        try {
            $ofd.Filter = "PowerShell scripts (*.ps1)|*.ps1|All files (*.*)|*.*"
            if ($ofd.ShowDialog($dlg) -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $txtScript.Text = ConvertTo-DisplayLineEndings ([System.IO.File]::ReadAllText($ofd.FileName))
            if (-not $txtFileName.Text.Trim()) { $txtFileName.Text = [System.IO.Path]::GetFileName($ofd.FileName) }
            if (-not $txtName.Text.Trim()) { $txtName.Text = [System.IO.Path]::GetFileNameWithoutExtension($ofd.FileName) }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not read that file: $($_.Exception.Message)", "Load failed", "OK", "Warning") | Out-Null
        }
        finally { $ofd.Dispose() }
    }.GetNewClosure())

    $btnSave.Add_Click({
        $problem = Test-PlatformScriptInput -DisplayName $txtName.Text -ScriptContent $txtScript.Text
        if ($problem) {
            [System.Windows.Forms.MessageBox]::Show($problem, "Check the script", "OK", "Warning") | Out-Null
            return
        }
        $checkedGroups = @($clbGroups.CheckedItems | ForEach-Object { [string]$_ })
        # Assignments are replaced wholesale by the assign action, so an
        # empty list means "no group gets this any more" - worth asking
        # about rather than silently unassigning.
        $assignGroups = $true
        if ($checkedGroups.Count -eq 0) {
            if ($ScriptId -and -not $GroupsKnown) {
                $assignGroups = $false
            }
            elseif ($ScriptId) {
                $r = [System.Windows.Forms.MessageBox]::Show(
                    "No group is checked, so this script stops being assigned to anyone in Intune.`n`nSave it without any assignment?",
                    "No groups checked", "YesNo", "Warning", "Button2")
                if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }
            else {
                $r = [System.Windows.Forms.MessageBox]::Show(
                    "No group is checked, so Intune won't run this script anywhere yet. You can assign it later.`n`nCreate it anyway?",
                    "No groups checked", "YesNo", "Question")
                if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }
        }
        $resultBox.Value = @{
            DisplayName           = $txtName.Text.Trim()
            Description           = $txtDescription.Text.Trim()
            FileName              = Get-PlatformScriptFileName -DisplayName $txtName.Text -FileName $txtFileName.Text
            ScriptContent         = $txtScript.Text
            RunAsAccount          = if ($cmbRunAs.SelectedIndex -eq 1) { "user" } else { "system" }
            RunAs32Bit            = [bool]$chk32Bit.Checked
            EnforceSignatureCheck = [bool]$chkSignature.Checked
            GroupNames            = $checkedGroups
            AssignGroups          = $assignGroups
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure())

    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    }.GetNewClosure())
    $dlg.CancelButton = $btnCancel

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
    return $resultBox.Value
}
