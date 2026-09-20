function Global:Show-DefaultAppSettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Edit default values"
    # Two fields per row rather than four. The requirements used to be four
    # boxes across one 820px row with 15px between them, which left nowhere
    # to say what each one's built-in value is - and that is the whole point
    # of the "built-in:" links added below.
    $dlg.ClientSize = New-Object System.Drawing.Size(820, 639)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "These are the defaults every new Winget app starts with - in `"Deploy to Intune`", `"Set default values...`", and Batch Deploy for an app with no saved metadata. Anything you have changed shows what the app originally shipped with, and clicking that puts back just that one value. Changing these does NOT touch any app already saved or deployed."
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
    $cmbContext.Size = New-Object System.Drawing.Size(140,24)
    $cmbContext.DropDownStyle = "DropDownList"
    [void]$cmbContext.Items.AddRange(@("System","User"))
    $cmbContext.SelectedItem = $Global:App.DefaultAppSettings.InstallContext
    $dlg.Controls.Add($cmbContext)

    # Starts at 280, not 200: the install context above needs room for its
    # own "built-in:" link between the two.
    $lblArch = New-Object System.Windows.Forms.Label
    $lblArch.Text = "Applicable architectures"
    $lblArch.Location = New-Object System.Drawing.Point(280,64)
    $lblArch.AutoSize = $true
    $dlg.Controls.Add($lblArch)

    $archList = @($Global:App.DefaultAppSettings.Architecture -split ',' | ForEach-Object { $_.Trim().ToLower() })
    $chkArchX86 = New-Object System.Windows.Forms.CheckBox
    $chkArchX86.Text = "x86"
    $chkArchX86.Location = New-Object System.Drawing.Point(280,83)
    $chkArchX86.Size = New-Object System.Drawing.Size(48,22)
    $chkArchX86.Checked = $archList -contains "x86"
    $dlg.Controls.Add($chkArchX86)

    $chkArchX64 = New-Object System.Windows.Forms.CheckBox
    $chkArchX64.Text = "x64"
    $chkArchX64.Location = New-Object System.Drawing.Point(336,83)
    $chkArchX64.Size = New-Object System.Drawing.Size(48,22)
    $chkArchX64.Checked = $archList -contains "x64"
    $dlg.Controls.Add($chkArchX64)

    $chkArchArm64 = New-Object System.Windows.Forms.CheckBox
    $chkArchArm64.Text = "ARM64"
    $chkArchArm64.Location = New-Object System.Drawing.Point(392,83)
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

    # Two per row, left column at 15 and right at 320, so each field has
    # room beside it for what it shipped as.
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
    $lblMemory.Location = New-Object System.Drawing.Point(320,193)
    $lblMemory.AutoSize = $true
    $dlg.Controls.Add($lblMemory)
    $txtMemory = New-Object System.Windows.Forms.TextBox
    $txtMemory.Location = New-Object System.Drawing.Point(320,210)
    $txtMemory.Size = New-Object System.Drawing.Size(130,23)
    $txtMemory.Text = [string]$Global:App.DefaultAppSettings.MinMemoryMB
    $dlg.Controls.Add($txtMemory)

    $lblProcessors = New-Object System.Windows.Forms.Label
    $lblProcessors.Text = "Min. processors"
    $lblProcessors.Location = New-Object System.Drawing.Point(15,246)
    $lblProcessors.AutoSize = $true
    $dlg.Controls.Add($lblProcessors)
    $txtProcessors = New-Object System.Windows.Forms.TextBox
    $txtProcessors.Location = New-Object System.Drawing.Point(15,263)
    $txtProcessors.Size = New-Object System.Drawing.Size(130,23)
    $txtProcessors.Text = [string]$Global:App.DefaultAppSettings.MinProcessors
    $dlg.Controls.Add($txtProcessors)

    $lblCpuSpeed = New-Object System.Windows.Forms.Label
    $lblCpuSpeed.Text = "Min. CPU speed (MHz)"
    $lblCpuSpeed.Location = New-Object System.Drawing.Point(320,246)
    $lblCpuSpeed.AutoSize = $true
    $dlg.Controls.Add($lblCpuSpeed)
    $txtCpuSpeed = New-Object System.Windows.Forms.TextBox
    $txtCpuSpeed.Location = New-Object System.Drawing.Point(320,263)
    $txtCpuSpeed.Size = New-Object System.Drawing.Size(130,23)
    $txtCpuSpeed.Text = [string]$Global:App.DefaultAppSettings.MinCpuSpeedMHz
    $dlg.Controls.Add($txtCpuSpeed)

    $lblInstallTime = New-Object System.Windows.Forms.Label
    $lblInstallTime.Text = "Install time required (mins)"
    $lblInstallTime.Location = New-Object System.Drawing.Point(15,299)
    $lblInstallTime.AutoSize = $true
    $dlg.Controls.Add($lblInstallTime)
    $txtInstallTime = New-Object System.Windows.Forms.TextBox
    $txtInstallTime.Location = New-Object System.Drawing.Point(15,316)
    $txtInstallTime.Size = New-Object System.Drawing.Size(130,23)
    # Intune keeps this in 5-minute steps - see Get-NormalizedInstallTimeMinutes
    $txtInstallTime.Add_Leave({
        $normalized = Get-NormalizedInstallTimeMinutes $txtInstallTime.Text
        if ($null -ne $normalized -and "$normalized" -ne $txtInstallTime.Text.Trim()) {
            $txtInstallTime.Text = [string]$normalized
        }
    }.GetNewClosure())
    $txtInstallTime.Text = [string]$Global:App.DefaultAppSettings.InstallTimeMinutes
    $dlg.Controls.Add($txtInstallTime)

    $lblRestartBehavior = New-Object System.Windows.Forms.Label
    $lblRestartBehavior.Text = "Device restart behavior"
    $lblRestartBehavior.Location = New-Object System.Drawing.Point(320,299)
    $lblRestartBehavior.AutoSize = $true
    $dlg.Controls.Add($lblRestartBehavior)
    $cmbRestartBehavior = New-Object System.Windows.Forms.ComboBox
    $cmbRestartBehavior.Location = New-Object System.Drawing.Point(320,316)
    $cmbRestartBehavior.Size = New-Object System.Drawing.Size(300,23)
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
    $chkAllowUninstall.Location = New-Object System.Drawing.Point(15,352)
    $chkAllowUninstall.AutoSize = $true
    $chkAllowUninstall.Checked = [bool]$Global:App.DefaultAppSettings.AllowAvailableUninstall
    $dlg.Controls.Add($chkAllowUninstall)

    $lblReturnCodes = New-Object System.Windows.Forms.Label
    $lblReturnCodes.Text = "Return codes"
    $lblReturnCodes.Location = New-Object System.Drawing.Point(15,384)
    $lblReturnCodes.AutoSize = $true
    $dlg.Controls.Add($lblReturnCodes)

    $grdReturnCodes = New-Object System.Windows.Forms.DataGridView
    Set-AppGridStyle -Grid $grdReturnCodes
    $grdReturnCodes.Location = New-Object System.Drawing.Point(15,403)
    # 180 tall so it ends level with the dependencies list beside it, and
    # Fill so the two columns use the width - Set-AppGridStyle leaves column
    # sizing to the caller, so the FillWeights below did nothing until now
    # and the table sat in the left half of its own box.
    $grdReturnCodes.Size = New-Object System.Drawing.Size(460,180)
    $grdReturnCodes.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
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
    $btnAddReturnCode.Location = New-Object System.Drawing.Point(485,403)
    $btnAddReturnCode.Size = New-Object System.Drawing.Size(120,26)
    $dlg.Controls.Add($btnAddReturnCode)
    $btnAddReturnCode.Add_Click({
        $rowIdx = $grdReturnCodes.Rows.Add()
        $grdReturnCodes.Rows[$rowIdx].Cells["Type"].Value = "success"
    }.GetNewClosure())

    $btnRemoveReturnCode = New-Object System.Windows.Forms.Button
    $btnRemoveReturnCode.Text = "Remove row"
    $btnRemoveReturnCode.Location = New-Object System.Drawing.Point(485,433)
    $btnRemoveReturnCode.Size = New-Object System.Drawing.Size(120,26)
    $dlg.Controls.Add($btnRemoveReturnCode)
    $btnRemoveReturnCode.Add_Click({
        if ($grdReturnCodes.CurrentRow) { $grdReturnCodes.Rows.RemoveAt($grdReturnCodes.CurrentRow.Index) }
    }.GetNewClosure())

    $lblDefaultDeps = New-Object System.Windows.Forms.Label
    $lblDefaultDeps.Text = "Default dependencies"
    $lblDefaultDeps.Location = New-Object System.Drawing.Point(485,464)
    $lblDefaultDeps.AutoSize = $true
    $dlg.Controls.Add($lblDefaultDeps)

    # A CheckedListBox, not a single-select ComboBox - see the note where
    # this field used to live (right after the Min. Windows combo above)
    # for why more than one default dependency needs to be pickable here.
    $clbDefaultDeps = New-Object System.Windows.Forms.CheckedListBox
    $clbDefaultDeps.Location = New-Object System.Drawing.Point(485,483)
    $clbDefaultDeps.Size = New-Object System.Drawing.Size(320,100)
    $clbDefaultDeps.CheckOnClick = $true
    foreach ($a in ($Global:App.Apps | Sort-Object appName)) {
        $idx = $clbDefaultDeps.Items.Add($a.appName)
        if (@($Global:App.DefaultAppSettings.DefaultDependencyAppNames) -contains $a.appName) { $clbDefaultDeps.SetItemChecked($idx, $true) }
    }
    $dlg.Controls.Add($clbDefaultDeps)

    # What "built-in" means for each field on this page, and a way back to
    # it one field at a time.
    #
    # This page showed the values in force but never what they started as,
    # so the only way back from one changed field was "Reset to built-in
    # defaults", which threw away the other eleven as well. And that reset
    # set each value again by hand - a second copy of the list in
    # Get-FactoryAppSettings that nothing would have told us had drifted.
    #
    # One table instead: every field says how to read itself, what the
    # built-in value is, and how to put that value back. The per-field
    # links and the reset-everything button both go through it, so there
    # is one list of built-in values and it is the shipped one.
    $factory = Get-FactoryAppSettings
    $factoryMinOsLabel = $minOsMap.Keys | Where-Object { $minOsMap[$_] -eq $factory.MinOSKey } | Select-Object -First 1
    $factoryRestartLabel = $restartBehaviorMap.Keys | Where-Object { $restartBehaviorMap[$_] -eq $factory.DeviceRestartBehavior } | Select-Object -First 1
    $factoryReturnCodes = (@($factory.ReturnCodes) | ForEach-Object { "$($_.returnCode)=$($_.type)" }) -join ', '
    $factoryDeps = (@($factory.DefaultDependencyAppNames) | Sort-Object) -join ', '
    # Only the built-in dependencies this catalog actually has, because
    # only those can be ticked. A catalog without "Winget AutoUpdate" in it
    # would otherwise sit permanently at "not the built-in value" with a
    # link that puts nothing back when clicked.
    $factoryDepsHere = (@($factory.DefaultDependencyAppNames | Where-Object { $clbDefaultDeps.Items -contains $_ }) | Sort-Object) -join ', '

    $factoryFields = @(
        @{  Key = 'InstallContext'; At = @(160, 85); Show = $factory.InstallContext
            Now = { [string]$cmbContext.SelectedItem }.GetNewClosure()
            Was = { $factory.InstallContext }.GetNewClosure()
            Put = { $cmbContext.SelectedItem = $factory.InstallContext }.GetNewClosure() }
        @{  Key = 'Architecture'; At = @(465, 85); Show = $factory.Architecture
            Now = { (@(
                        if ($chkArchX86.Checked)   { 'x86' }
                        if ($chkArchX64.Checked)   { 'x64' }
                        if ($chkArchArm64.Checked) { 'arm64' }
                     ) -join ',') }.GetNewClosure()
            Was = { $factory.Architecture }.GetNewClosure()
            Put = {
                $wanted = @($factory.Architecture -split ',' | ForEach-Object { $_.Trim().ToLower() })
                $chkArchX86.Checked   = $wanted -contains 'x86'
                $chkArchX64.Checked   = $wanted -contains 'x64'
                $chkArchArm64.Checked = $wanted -contains 'arm64'
            }.GetNewClosure() }
        @{  Key = 'MinOSKey'; At = @(285, 140); Show = $factoryMinOsLabel
            Now = { $minOsMap[[string]$cmbMinOS.SelectedItem] }.GetNewClosure()
            Was = { $factory.MinOSKey }.GetNewClosure()
            Put = { if ($factoryMinOsLabel) { $cmbMinOS.SelectedItem = $factoryMinOsLabel } }.GetNewClosure() }
        @{  Key = 'MinDiskSpaceMB'; At = @(153, 213); Show = [string]$factory.MinDiskSpaceMB
            Now = { $txtDiskSpace.Text.Trim() }.GetNewClosure()
            Was = { [string]$factory.MinDiskSpaceMB }.GetNewClosure()
            Put = { $txtDiskSpace.Text = [string]$factory.MinDiskSpaceMB }.GetNewClosure() }
        @{  Key = 'MinMemoryMB'; At = @(458, 213); Show = [string]$factory.MinMemoryMB
            Now = { $txtMemory.Text.Trim() }.GetNewClosure()
            Was = { [string]$factory.MinMemoryMB }.GetNewClosure()
            Put = { $txtMemory.Text = [string]$factory.MinMemoryMB }.GetNewClosure() }
        @{  Key = 'MinProcessors'; At = @(153, 266); Show = [string]$factory.MinProcessors
            Now = { $txtProcessors.Text.Trim() }.GetNewClosure()
            Was = { [string]$factory.MinProcessors }.GetNewClosure()
            Put = { $txtProcessors.Text = [string]$factory.MinProcessors }.GetNewClosure() }
        @{  Key = 'MinCpuSpeedMHz'; At = @(458, 266); Show = [string]$factory.MinCpuSpeedMHz
            Now = { $txtCpuSpeed.Text.Trim() }.GetNewClosure()
            Was = { [string]$factory.MinCpuSpeedMHz }.GetNewClosure()
            Put = { $txtCpuSpeed.Text = [string]$factory.MinCpuSpeedMHz }.GetNewClosure() }
        @{  Key = 'InstallTimeMinutes'; At = @(153, 319); Show = [string]$factory.InstallTimeMinutes
            Now = { $txtInstallTime.Text.Trim() }.GetNewClosure()
            Was = { [string]$factory.InstallTimeMinutes }.GetNewClosure()
            Put = { $txtInstallTime.Text = [string]$factory.InstallTimeMinutes }.GetNewClosure() }
        @{  Key = 'DeviceRestartBehavior'; At = @(628, 319); Show = 'return codes decide'
            Now = { $restartBehaviorMap[[string]$cmbRestartBehavior.SelectedItem] }.GetNewClosure()
            Was = { $factory.DeviceRestartBehavior }.GetNewClosure()
            Put = { if ($factoryRestartLabel) { $cmbRestartBehavior.SelectedItem = $factoryRestartLabel } }.GetNewClosure() }
        @{  Key = 'AllowAvailableUninstall'; At = @(180, 353); Show = $(if ($factory.AllowAvailableUninstall) { 'ticked' } else { 'unticked' })
            Now = { [string][bool]$chkAllowUninstall.Checked }.GetNewClosure()
            Was = { [string][bool]$factory.AllowAvailableUninstall }.GetNewClosure()
            Put = { $chkAllowUninstall.Checked = [bool]$factory.AllowAvailableUninstall }.GetNewClosure() }
        @{  Key = 'ReturnCodes'; At = @(100, 384); Show = "the $(@($factory.ReturnCodes).Count) shipped codes"
            Now = {
                (@($grdReturnCodes.Rows | Where-Object { -not $_.IsNewRow } | ForEach-Object {
                    "$([string]$_.Cells['Code'].Value)=$([string]$_.Cells['Type'].Value)"
                }) -join ', ')
            }.GetNewClosure()
            Was = { $factoryReturnCodes }.GetNewClosure()
            Put = {
                $grdReturnCodes.Rows.Clear()
                foreach ($rc in @($factory.ReturnCodes)) {
                    $rowIdx = $grdReturnCodes.Rows.Add()
                    $grdReturnCodes.Rows[$rowIdx].Cells['Code'].Value = [string]$rc.returnCode
                    $grdReturnCodes.Rows[$rowIdx].Cells['Type'].Value = [string]$rc.type
                }
            }.GetNewClosure() }
        @{  Key = 'DefaultDependencyAppNames'; At = @(618, 464); Show = $(if ($factoryDepsHere) { $factoryDepsHere } else { 'none' })
            Now = { (@($clbDefaultDeps.CheckedItems | ForEach-Object { [string]$_ }) | Sort-Object) -join ', ' }.GetNewClosure()
            Was = { $factoryDepsHere }.GetNewClosure()
            Put = {
                $wanted = @($factory.DefaultDependencyAppNames)
                for ($ci = 0; $ci -lt $clbDefaultDeps.Items.Count; $ci++) {
                    $clbDefaultDeps.SetItemChecked($ci, ($wanted -contains [string]$clbDefaultDeps.Items[$ci]))
                }
            }.GetNewClosure() }
    )

    # One link per field, shown only while that field differs from what the
    # app ships with - so an untouched page stays quiet, and anything that
    # has been changed says so and offers the way back. Clicking puts that
    # one value back and leaves the rest of the page alone.
    $factoryTips = New-Object System.Windows.Forms.ToolTip
    foreach ($field in $factoryFields) {
        $shown = [string]$field.Show
        if ($shown.Length -gt 22) { $shown = $shown.Substring(0, 21) + "..." }
        $link = New-Object System.Windows.Forms.LinkLabel
        $link.Text = "built-in: $shown"
        $link.Location = New-Object System.Drawing.Point($field.At[0], $field.At[1])
        $link.AutoSize = $true
        $link.Visible = $false
        $link.LinkBehavior = [System.Windows.Forms.LinkBehavior]::HoverUnderline
        $link.LinkColor = [System.Drawing.Color]::FromArgb(0,102,170)
        $factoryTips.SetToolTip($link, "This is not the value the app ships with ($($field.Show)). Click to put just this one back - nothing else on this page changes, and nothing is saved until you press Save.")
        $dlg.Controls.Add($link)
        $link.BringToFront()
        $field.Link = $link
        $link.Add_LinkClicked({ & $field.Put }.GetNewClosure())
    }

    # Polled rather than wired to each control's own change event. Twelve
    # fields across combo boxes, text boxes, a grid whose cell value is not
    # committed yet when CellValueChanged fires, and a CheckedListBox whose
    # ItemCheck fires BEFORE the item changes: each of those needs its own
    # workaround to read back what was just entered, and getting one wrong
    # shows a link that lies. Twelve string comparisons three times a
    # second cost nothing and cannot disagree with what is on screen.
    $refreshFactoryLinks = {
        foreach ($field in $factoryFields) {
            $field.Link.Visible = ((& $field.Now) -ne (& $field.Was))
        }
    }.GetNewClosure()
    $factoryTimer = New-Object System.Windows.Forms.Timer
    $factoryTimer.Interval = 300
    $factoryTimer.Add_Tick($refreshFactoryLinks)
    $dlg.Add_Shown({ & $refreshFactoryLinks; $factoryTimer.Start() }.GetNewClosure())
    $dlg.Add_FormClosed({ $factoryTimer.Stop(); $factoryTimer.Dispose() }.GetNewClosure())

    $btnResetFactory = New-Object System.Windows.Forms.Button
    $btnResetFactory.Text = "Reset all to built-in"
    $btnResetFactory.Location = New-Object System.Drawing.Point(15,592)
    $btnResetFactory.Size = New-Object System.Drawing.Size(180,32)
    $dlg.Controls.Add($btnResetFactory)
    $resetFactoryTip = New-Object System.Windows.Forms.ToolTip
    $resetFactoryTip.SetToolTip($btnResetFactory, "Fills in every field above with this app's original built-in defaults - to put back just one, use its own `"built-in:`" link. Either way, Save still has to be pressed to apply it.")

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(635,592)
    $btnCancel.Size = New-Object System.Drawing.Size(80,32)
    $dlg.Controls.Add($btnCancel)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(720,592)
    $btnSave.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnSave)

    # Every field at once is every field's own Put, run in turn - the same
    # code one link runs, so there is no second list to keep in step.
    $btnResetFactory.Add_Click({
        $r = [System.Windows.Forms.MessageBox]::Show("Reset all fields below to the tool's built-in defaults?`n`nNothing is saved until you click Save.", "Reset to built-in defaults", "YesNo", "Question", "Button2")
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        foreach ($field in $factoryFields) { & $field.Put }
        & $refreshFactoryLinks
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
        $Global:App.DefaultAppSettings.InstallTimeMinutes        = (Get-NormalizedInstallTimeMinutes $txtInstallTime.Text)
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
