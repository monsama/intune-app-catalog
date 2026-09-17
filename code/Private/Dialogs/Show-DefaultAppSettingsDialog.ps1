function Global:Show-DefaultAppSettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Edit default values"
    $dlg.ClientSize = New-Object System.Drawing.Size(820, 590)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "These are the defaults every new Winget app starts with - in `"Deploy to Intune`", `"Set default values...`", and Batch Deploy for an app with no saved metadata. Changing these here does NOT touch any app already saved or deployed."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(790,48)
    $dlg.Controls.Add($lblIntro)

    $lblContext = New-Object System.Windows.Forms.Label
    $lblContext.Text = "Install context"
    $lblContext.Location = New-Object System.Drawing.Point(15,64)
    $lblContext.AutoSize = $true
    $dlg.Controls.Add($lblContext)

    $cmbContext = New-Object System.Windows.Forms.ComboBox
    $cmbContext.Location = New-Object System.Drawing.Point(15,83)
    $cmbContext.Size = New-Object System.Drawing.Size(160,24)
    $cmbContext.DropDownStyle = "DropDownList"
    [void]$cmbContext.Items.AddRange(@("System","User"))
    $cmbContext.SelectedItem = $Global:App.DefaultAppSettings.InstallContext
    $dlg.Controls.Add($cmbContext)

    $lblArch = New-Object System.Windows.Forms.Label
    $lblArch.Text = "Applicable architectures"
    $lblArch.Location = New-Object System.Drawing.Point(200,64)
    $lblArch.AutoSize = $true
    $dlg.Controls.Add($lblArch)

    $archList = @($Global:App.DefaultAppSettings.Architecture -split ',' | ForEach-Object { $_.Trim().ToLower() })
    $chkArchX86 = New-Object System.Windows.Forms.CheckBox
    $chkArchX86.Text = "x86"
    $chkArchX86.Location = New-Object System.Drawing.Point(200,83)
    $chkArchX86.Size = New-Object System.Drawing.Size(48,22)
    $chkArchX86.Checked = $archList -contains "x86"
    $dlg.Controls.Add($chkArchX86)

    $chkArchX64 = New-Object System.Windows.Forms.CheckBox
    $chkArchX64.Text = "x64"
    $chkArchX64.Location = New-Object System.Drawing.Point(256,83)
    $chkArchX64.Size = New-Object System.Drawing.Size(48,22)
    $chkArchX64.Checked = $archList -contains "x64"
    $dlg.Controls.Add($chkArchX64)

    $chkArchArm64 = New-Object System.Windows.Forms.CheckBox
    $chkArchArm64.Text = "ARM64"
    $chkArchArm64.Location = New-Object System.Drawing.Point(312,83)
    $chkArchArm64.Size = New-Object System.Drawing.Size(65,22)
    $chkArchArm64.Checked = $archList -contains "arm64"
    $dlg.Controls.Add($chkArchArm64)

    $lblMinOS = New-Object System.Windows.Forms.Label
    $lblMinOS.Text = "Minimum Windows"
    $lblMinOS.Location = New-Object System.Drawing.Point(15,118)
    $lblMinOS.AutoSize = $true
    $dlg.Controls.Add($lblMinOS)

    $cmbMinOS = New-Object System.Windows.Forms.ComboBox
    $cmbMinOS.Location = New-Object System.Drawing.Point(15,137)
    $cmbMinOS.Size = New-Object System.Drawing.Size(260,24)
    $cmbMinOS.DropDownStyle = "DropDownList"
    # Same full set Show-CreateInIntuneDialog's own $minOsMap offers -
    # kept in sync manually, same as every other copy of this list.
    $minOsRawValues = @("W10_1607", "W10_1703", "W10_1709", "W10_1803", "W10_1809", "W10_1903", "W10_1909", "W10_2004", "W10_20H2", "W10_21H1", "W10_21H2", "W10_22H2", "W11_21H2", "W11_22H2")
    $minOsMap = [ordered]@{}
    foreach ($rawValue in $minOsRawValues) { $minOsMap[(Get-FriendlyMinOsRelease -RawValue $rawValue)] = $rawValue }
    [void]$cmbMinOS.Items.AddRange(@($minOsMap.Keys))
    $defaultMinOsLabel = $minOsMap.Keys | Where-Object { $minOsMap[$_] -eq $Global:App.DefaultAppSettings.MinOSKey } | Select-Object -First 1
    $cmbMinOS.SelectedItem = if ($defaultMinOsLabel) { $defaultMinOsLabel } else { $minOsMap.Keys | Select-Object -First 1 }
    $dlg.Controls.Add($cmbMinOS)

    # Moved out of this row entirely (was a single-select ComboBox right
    # here) - a new app can sensibly default to depending on MORE than one
    # other app (e.g. both a runtime AND an updater), unlike every other
    # combo in this dialog (Install context/Min. Windows/Restart behavior),
    # which really is just one value each. A CheckedListBox needs more
    # height than fits in this row without overlapping the Requirements
    # section right below it, so it lives instead in the return-codes
    # column's own unused space below its Add/Remove row buttons - see
    # $lblDefaultDeps/$clbDefaultDeps further down.

    $lblReqs = New-Object System.Windows.Forms.Label
    $lblReqs.Text = "Requirements (0 = not required)"
    $lblReqs.Location = New-Object System.Drawing.Point(15,167)
    $lblReqs.AutoSize = $true
    $dlg.Controls.Add($lblReqs)

    $lblDiskSpace = New-Object System.Windows.Forms.Label
    $lblDiskSpace.Text = "Disk space (MB)"
    $lblDiskSpace.Location = New-Object System.Drawing.Point(15,193)
    $lblDiskSpace.AutoSize = $true
    $dlg.Controls.Add($lblDiskSpace)
    $txtDiskSpace = New-Object System.Windows.Forms.TextBox
    $txtDiskSpace.Location = New-Object System.Drawing.Point(15,210)
    $txtDiskSpace.Size = New-Object System.Drawing.Size(130,23)
    $txtDiskSpace.Text = [string]$Global:App.DefaultAppSettings.MinDiskSpaceMB
    $dlg.Controls.Add($txtDiskSpace)

    $lblMemory = New-Object System.Windows.Forms.Label
    $lblMemory.Text = "Memory (MB)"
    $lblMemory.Location = New-Object System.Drawing.Point(160,193)
    $lblMemory.AutoSize = $true
    $dlg.Controls.Add($lblMemory)
    $txtMemory = New-Object System.Windows.Forms.TextBox
    $txtMemory.Location = New-Object System.Drawing.Point(160,210)
    $txtMemory.Size = New-Object System.Drawing.Size(130,23)
    $txtMemory.Text = [string]$Global:App.DefaultAppSettings.MinMemoryMB
    $dlg.Controls.Add($txtMemory)

    $lblProcessors = New-Object System.Windows.Forms.Label
    $lblProcessors.Text = "Min. processors"
    $lblProcessors.Location = New-Object System.Drawing.Point(305,193)
    $lblProcessors.AutoSize = $true
    $dlg.Controls.Add($lblProcessors)
    $txtProcessors = New-Object System.Windows.Forms.TextBox
    $txtProcessors.Location = New-Object System.Drawing.Point(305,210)
    $txtProcessors.Size = New-Object System.Drawing.Size(130,23)
    $txtProcessors.Text = [string]$Global:App.DefaultAppSettings.MinProcessors
    $dlg.Controls.Add($txtProcessors)

    $lblCpuSpeed = New-Object System.Windows.Forms.Label
    $lblCpuSpeed.Text = "Min. CPU speed (MHz)"
    $lblCpuSpeed.Location = New-Object System.Drawing.Point(450,193)
    $lblCpuSpeed.AutoSize = $true
    $dlg.Controls.Add($lblCpuSpeed)
    $txtCpuSpeed = New-Object System.Windows.Forms.TextBox
    $txtCpuSpeed.Location = New-Object System.Drawing.Point(450,210)
    $txtCpuSpeed.Size = New-Object System.Drawing.Size(130,23)
    $txtCpuSpeed.Text = [string]$Global:App.DefaultAppSettings.MinCpuSpeedMHz
    $dlg.Controls.Add($txtCpuSpeed)

    $lblInstallTime = New-Object System.Windows.Forms.Label
    $lblInstallTime.Text = "Install time required (mins)"
    $lblInstallTime.Location = New-Object System.Drawing.Point(15,246)
    $lblInstallTime.AutoSize = $true
    $dlg.Controls.Add($lblInstallTime)
    $txtInstallTime = New-Object System.Windows.Forms.TextBox
    $txtInstallTime.Location = New-Object System.Drawing.Point(15,263)
    $txtInstallTime.Size = New-Object System.Drawing.Size(130,23)
    $txtInstallTime.Text = [string]$Global:App.DefaultAppSettings.InstallTimeMinutes
    $dlg.Controls.Add($txtInstallTime)

    $lblRestartBehavior = New-Object System.Windows.Forms.Label
    $lblRestartBehavior.Text = "Device restart behavior"
    $lblRestartBehavior.Location = New-Object System.Drawing.Point(180,246)
    $lblRestartBehavior.AutoSize = $true
    $dlg.Controls.Add($lblRestartBehavior)
    $cmbRestartBehavior = New-Object System.Windows.Forms.ComboBox
    $cmbRestartBehavior.Location = New-Object System.Drawing.Point(180,263)
    $cmbRestartBehavior.Size = New-Object System.Drawing.Size(330,23)
    $cmbRestartBehavior.DropDownStyle = "DropDownList"
    $restartBehaviorMap = [ordered]@{
        "Determine behavior based on return codes"      = "basedOnReturnCode"
        "No specific action"                            = "allow"
        "App install may force a device restart"        = "suppress"
        "Intune will force a mandatory device restart"  = "force"
    }
    foreach ($k in $restartBehaviorMap.Keys) { [void]$cmbRestartBehavior.Items.Add($k) }
    $defaultRestartLabel = $restartBehaviorMap.Keys | Where-Object { $restartBehaviorMap[$_] -eq $Global:App.DefaultAppSettings.DeviceRestartBehavior } | Select-Object -First 1
    $cmbRestartBehavior.SelectedItem = if ($defaultRestartLabel) { $defaultRestartLabel } else { "Determine behavior based on return codes" }
    $dlg.Controls.Add($cmbRestartBehavior)

    $chkAllowUninstall = New-Object System.Windows.Forms.CheckBox
    $chkAllowUninstall.Text = "Allow available uninstall"
    $chkAllowUninstall.Location = New-Object System.Drawing.Point(15,300)
    $chkAllowUninstall.AutoSize = $true
    $chkAllowUninstall.Checked = [bool]$Global:App.DefaultAppSettings.AllowAvailableUninstall
    $dlg.Controls.Add($chkAllowUninstall)

    $lblReturnCodes = New-Object System.Windows.Forms.Label
    $lblReturnCodes.Text = "Return codes"
    $lblReturnCodes.Location = New-Object System.Drawing.Point(15,332)
    $lblReturnCodes.AutoSize = $true
    $dlg.Controls.Add($lblReturnCodes)

    $grdReturnCodes = New-Object System.Windows.Forms.DataGridView
    $grdReturnCodes.Location = New-Object System.Drawing.Point(15,351)
    $grdReturnCodes.Size = New-Object System.Drawing.Size(460,150)
    $grdReturnCodes.AllowUserToAddRows = $false
    $grdReturnCodes.AllowUserToDeleteRows = $false
    $grdReturnCodes.RowHeadersVisible = $false
    $grdReturnCodes.SelectionMode = "FullRowSelect"
    $grdReturnCodes.MultiSelect = $false
    $colCode = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCode.Name = "Code"; $colCode.HeaderText = "Return code"; $colCode.FillWeight = 40
    [void]$grdReturnCodes.Columns.Add($colCode)
    $colType = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
    $colType.Name = "Type"; $colType.HeaderText = "Type"; $colType.FillWeight = 60
    [void]$colType.Items.AddRange(@("success", "softReboot", "hardReboot", "retry", "failed"))
    [void]$grdReturnCodes.Columns.Add($colType)
    $dlg.Controls.Add($grdReturnCodes)
    foreach ($rc in @($Global:App.DefaultAppSettings.ReturnCodes)) {
        $rowIdx = $grdReturnCodes.Rows.Add()
        $grdReturnCodes.Rows[$rowIdx].Cells["Code"].Value = [string]$rc.returnCode
        $grdReturnCodes.Rows[$rowIdx].Cells["Type"].Value = [string]$rc.type
    }

    $btnAddReturnCode = New-Object System.Windows.Forms.Button
    $btnAddReturnCode.Text = "Add row"
    $btnAddReturnCode.Location = New-Object System.Drawing.Point(485,351)
    $btnAddReturnCode.Size = New-Object System.Drawing.Size(120,26)
    $dlg.Controls.Add($btnAddReturnCode)
    $btnAddReturnCode.Add_Click({
        $rowIdx = $grdReturnCodes.Rows.Add()
        $grdReturnCodes.Rows[$rowIdx].Cells["Type"].Value = "success"
    }.GetNewClosure())

    $btnRemoveReturnCode = New-Object System.Windows.Forms.Button
    $btnRemoveReturnCode.Text = "Remove row"
    $btnRemoveReturnCode.Location = New-Object System.Drawing.Point(485,381)
    $btnRemoveReturnCode.Size = New-Object System.Drawing.Size(120,26)
    $dlg.Controls.Add($btnRemoveReturnCode)
    $btnRemoveReturnCode.Add_Click({
        if ($grdReturnCodes.CurrentRow) { $grdReturnCodes.Rows.RemoveAt($grdReturnCodes.CurrentRow.Index) }
    }.GetNewClosure())

    $lblDefaultDeps = New-Object System.Windows.Forms.Label
    $lblDefaultDeps.Text = "Default dependencies"
    $lblDefaultDeps.Location = New-Object System.Drawing.Point(485,412)
    $lblDefaultDeps.AutoSize = $true
    $dlg.Controls.Add($lblDefaultDeps)

    # A CheckedListBox, not a single-select ComboBox - see the note where
    # this field used to live (right after the Min. Windows combo above)
    # for why more than one default dependency needs to be pickable here.
    $clbDefaultDeps = New-Object System.Windows.Forms.CheckedListBox
    $clbDefaultDeps.Location = New-Object System.Drawing.Point(485,431)
    $clbDefaultDeps.Size = New-Object System.Drawing.Size(320,100)
    $clbDefaultDeps.CheckOnClick = $true
    foreach ($a in ($Global:App.Apps | Sort-Object appName)) {
        $idx = $clbDefaultDeps.Items.Add($a.appName)
        if (@($Global:App.DefaultAppSettings.DefaultDependencyAppNames) -contains $a.appName) { $clbDefaultDeps.SetItemChecked($idx, $true) }
    }
    $dlg.Controls.Add($clbDefaultDeps)

    $btnResetFactory = New-Object System.Windows.Forms.Button
    $btnResetFactory.Text = "Reset to built-in defaults"
    $btnResetFactory.Location = New-Object System.Drawing.Point(15,540)
    $btnResetFactory.Size = New-Object System.Drawing.Size(180,32)
    $dlg.Controls.Add($btnResetFactory)
    $resetFactoryTip = New-Object System.Windows.Forms.ToolTip
    $resetFactoryTip.SetToolTip($btnResetFactory, "Fills in the fields above with this app's original built-in defaults - still requires Save below to actually apply.")

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(635,540)
    $btnCancel.Size = New-Object System.Drawing.Size(80,32)
    $dlg.Controls.Add($btnCancel)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(720,540)
    $btnSave.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnSave)

    # Factory values live here, once, rather than duplicating the literal
    # list a second time - re-running Get-DefaultAppMetadata's own logic
    # would need an app name/Winget ID it doesn't have here, so this is a
    # plain, separate literal copy of the same starting values
    # $Global:App.DefaultAppSettings itself is initialized with at the top of
    # this script - kept in sync manually if those ever change.
    $btnResetFactory.Add_Click({
        $r = [System.Windows.Forms.MessageBox]::Show("Reset all fields below to the tool's built-in defaults?`n`nNothing is saved until you click Save.", "Reset to built-in defaults", "YesNo", "Question")
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $cmbContext.SelectedItem = "System"
        $chkArchX86.Checked = $false
        $chkArchX64.Checked = $true
        $chkArchArm64.Checked = $false
        $factoryMinOsLabel = $minOsMap.Keys | Where-Object { $minOsMap[$_] -eq "W10_22H2" } | Select-Object -First 1
        if ($factoryMinOsLabel) { $cmbMinOS.SelectedItem = $factoryMinOsLabel }
        for ($ci = 0; $ci -lt $clbDefaultDeps.Items.Count; $ci++) {
            $clbDefaultDeps.SetItemChecked($ci, ([string]$clbDefaultDeps.Items[$ci] -eq "Winget AutoUpdate"))
        }
        $txtDiskSpace.Text = "0"
        $txtMemory.Text = "0"
        $txtProcessors.Text = "0"
        $txtCpuSpeed.Text = "0"
        $txtInstallTime.Text = "60"
        $cmbRestartBehavior.SelectedItem = "Determine behavior based on return codes"
        $chkAllowUninstall.Checked = $false
        $grdReturnCodes.Rows.Clear()
        foreach ($rc in @(
            [pscustomobject]@{ returnCode = 0; type = "success" }
            [pscustomobject]@{ returnCode = 1707; type = "success" }
            [pscustomobject]@{ returnCode = 3010; type = "softReboot" }
            [pscustomobject]@{ returnCode = 1641; type = "hardReboot" }
            [pscustomobject]@{ returnCode = 1618; type = "retry" }
        )) {
            $rowIdx = $grdReturnCodes.Rows.Add()
            $grdReturnCodes.Rows[$rowIdx].Cells["Code"].Value = [string]$rc.returnCode
            $grdReturnCodes.Rows[$rowIdx].Cells["Type"].Value = $rc.type
        }
    }.GetNewClosure())

    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())

    $btnSave.Add_Click({
        if (-not $chkArchX86.Checked -and -not $chkArchX64.Checked -and -not $chkArchArm64.Checked) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one architecture.", "No architecture selected", "OK", "Warning") | Out-Null
            return
        }
        $numericChecks = @(
            @{ Label = "Disk space (MB)"; Box = $txtDiskSpace }
            @{ Label = "Memory (MB)"; Box = $txtMemory }
            @{ Label = "Min. processors"; Box = $txtProcessors }
            @{ Label = "Min. CPU speed (MHz)"; Box = $txtCpuSpeed }
            @{ Label = "Install time required (mins)"; Box = $txtInstallTime }
        )
        foreach ($numCheck in $numericChecks) {
            $parsedNum = 0
            if (-not [int]::TryParse($numCheck.Box.Text.Trim(), [ref]$parsedNum) -or $parsedNum -lt 0) {
                [System.Windows.Forms.MessageBox]::Show("$($numCheck.Label) must be a whole number, 0 or greater.", "Invalid value", "OK", "Warning") | Out-Null
                return
            }
        }
        $returnCodesConfig = New-Object System.Collections.Generic.List[object]
        foreach ($rcRow in $grdReturnCodes.Rows) {
            if ($rcRow.IsNewRow) { continue }
            $rcCode = [string]$rcRow.Cells["Code"].Value
            $rcType = [string]$rcRow.Cells["Type"].Value
            if (-not $rcCode -and -not $rcType) { continue }
            $parsedCode = 0
            if (-not [int]::TryParse($rcCode.Trim(), [ref]$parsedCode)) {
                [System.Windows.Forms.MessageBox]::Show("Return code `"$rcCode`" isn't a valid whole number.", "Invalid return code", "OK", "Warning") | Out-Null
                return
            }
            if (-not $rcType) {
                [System.Windows.Forms.MessageBox]::Show("Return code $parsedCode needs a type selected.", "Missing return code type", "OK", "Warning") | Out-Null
                return
            }
            $returnCodesConfig.Add([pscustomobject]@{ returnCode = $parsedCode; type = $rcType })
        }
        if ($returnCodesConfig.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("At least one return code is required.", "No return codes", "OK", "Warning") | Out-Null
            return
        }

        $selectedArches = New-Object System.Collections.Generic.List[string]
        if ($chkArchX86.Checked)   { $selectedArches.Add("x86") }
        if ($chkArchX64.Checked)   { $selectedArches.Add("x64") }
        if ($chkArchArm64.Checked) { $selectedArches.Add("arm64") }

        $Global:App.DefaultAppSettings.Architecture             = ($selectedArches -join ",")
        $Global:App.DefaultAppSettings.InstallContext            = [string]$cmbContext.SelectedItem
        $Global:App.DefaultAppSettings.MinOSKey                  = $minOsMap[[string]$cmbMinOS.SelectedItem]
        $Global:App.DefaultAppSettings.MinDiskSpaceMB            = [int]$txtDiskSpace.Text.Trim()
        $Global:App.DefaultAppSettings.MinMemoryMB               = [int]$txtMemory.Text.Trim()
        $Global:App.DefaultAppSettings.MinProcessors             = [int]$txtProcessors.Text.Trim()
        $Global:App.DefaultAppSettings.MinCpuSpeedMHz            = [int]$txtCpuSpeed.Text.Trim()
        $Global:App.DefaultAppSettings.InstallTimeMinutes        = [int]$txtInstallTime.Text.Trim()
        $Global:App.DefaultAppSettings.DeviceRestartBehavior     = $restartBehaviorMap[[string]$cmbRestartBehavior.SelectedItem]
        $Global:App.DefaultAppSettings.AllowAvailableUninstall   = $chkAllowUninstall.Checked
        $Global:App.DefaultAppSettings.ReturnCodes               = $returnCodesConfig.ToArray()
        $Global:App.DefaultAppSettings.DefaultDependencyAppNames = @($clbDefaultDeps.CheckedItems | ForEach-Object { [string]$_ })

        if (-not (Write-SettingsFile)) { return }
        [System.Windows.Forms.MessageBox]::Show("Default values saved. Only affects NEW comparisons/deploys from here on - no existing app's saved metadata was touched.", "Saved", "OK", "Information") | Out-Null
        $dlg.Close()
    }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnSave
    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
