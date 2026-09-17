function Global:Show-BatchEditMetadataDialog {
    param([int[]]$ScopedIndices = @())

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef      = $Global:App.Apps
    $tenantId     = $Global:App.GraphTenantId
    $clientId     = $Global:App.GraphClientId
    $certThumb    = $Global:App.GraphCertificateThumbprint
    $createScript = $Global:App.EmbeddedCreateAppScript
    $unsavedBox   = $Global:App.UnsavedChangesBox
    $linkedFilePath = $Global:App.LinkedFilePath

    # ScopedIndices only decides which eligible apps start CHECKED below,
    # never which ones are shown - unlike Batch Deploy/Sync Metadata's own
    # -ScopedIndices (which narrow the whole list, correct for THEM since
    # they're reached from a right-click on a specific selection), this
    # dialog is reached from a plain toolbar button while the grid's
    # normal single-row selection is very likely just whatever row was
    # last clicked/browsed, not a deliberate "only these apps" choice for
    # a batch field edit. Hard-filtering the list to that one leftover
    # selection (a real, reported bug) meant "Apps to change" showed just
    # one app almost every time this was opened from the toolbar, with no
    # way to see or add any other eligible app from inside the dialog.
    $isScoped = $ScopedIndices.Count -gt 0
    $scopedAppNames = if ($isScoped) { @($ScopedIndices | ForEach-Object { $appsRef[$_].appName }) } else { @() }

    # Win32 (not uncommon), already deployed (has an App ID - nothing in
    # Intune to PATCH otherwise), and has saved local metadata to use as
    # the base for the fields NOT being changed - UpdateMetadata PATCHes
    # every one of these fields at once (see the embedded script's own
    # comment on why it can't do a partial patch), so an app with no local
    # metadata at all has nothing safe to fill the untouched fields with
    # and is excluded rather than guessed at.
    $allCandidates = @($appsRef | Where-Object { -not (Test-AppIsUncommon -App $_) })
    $eligibleApps = @($allCandidates | Where-Object { $_.appId -and $_.metadata })
    $noMetadataCount = @($allCandidates | Where-Object { $_.appId -and -not $_.metadata }).Count

    if ($eligibleApps.Count -eq 0) {
        $msg = "No apps are eligible - this needs a Win32 app that's already deployed (has an App ID) and has saved metadata."
        if ($noMetadataCount -gt 0) { $msg += " $noMetadataCount app(s) have an App ID but no saved metadata - use `"Pull metadata and groups from Intune...`" on them first." }
        [System.Windows.Forms.MessageBox]::Show($msg, "Nothing to do", "OK", "Information") | Out-Null
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Batch edit Intune fields"
    $dlg.ClientSize = New-Object System.Drawing.Size(950, 850)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Changes only the checked field(s) on the checked apps, then pushes each straight to Intune - everything else is left as-is. Lists every eligible app, not just what's selected in the main grid (that only pre-checks rows here). Install/uninstall commands and the detection rule aren't offered - those are per-app, not safe to set to one shared value."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(920,74)
    $dlg.Controls.Add($lblIntro)

    $lblApps = New-Object System.Windows.Forms.Label
    $lblApps.Text = "Apps to change"
    $lblApps.Location = New-Object System.Drawing.Point(15,92)
    $lblApps.AutoSize = $true
    $dlg.Controls.Add($lblApps)

    $clbApps = New-Object System.Windows.Forms.CheckedListBox
    $clbApps.Location = New-Object System.Drawing.Point(15,112)
    $clbApps.Size = New-Object System.Drawing.Size(330,380)
    $clbApps.CheckOnClick = $true
    $dlg.Controls.Add($clbApps)
    # Pre-checked: every eligible app whenever nothing specific was
    # selected in the main grid, otherwise just the ones that were - see
    # $scopedAppNames's own comment above for why this never hides the
    # rest of the list either way.
    foreach ($eligibleApp in ($eligibleApps | Sort-Object appName)) {
        $startChecked = if ($isScoped) { $scopedAppNames -contains $eligibleApp.appName } else { $true }
        [void]$clbApps.Items.Add($eligibleApp.appName, $startChecked)
    }

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select all"
    $btnSelectAll.Location = New-Object System.Drawing.Point(15,498)
    $btnSelectAll.Size = New-Object System.Drawing.Size(100,26)
    $dlg.Controls.Add($btnSelectAll)

    $btnSelectNone = New-Object System.Windows.Forms.Button
    $btnSelectNone.Text = "Select none"
    $btnSelectNone.Location = New-Object System.Drawing.Point(125,498)
    $btnSelectNone.Size = New-Object System.Drawing.Size(110,26)
    $dlg.Controls.Add($btnSelectNone)

    $lblFields = New-Object System.Windows.Forms.Label
    $lblFields.Text = "Fields to change (check a field to include it)"
    $lblFields.Location = New-Object System.Drawing.Point(365,92)
    $lblFields.AutoSize = $true
    $dlg.Controls.Add($lblFields)

    $fieldsY = 116

    $chkEnableArch = New-Object System.Windows.Forms.CheckBox
    $chkEnableArch.Text = "Architecture"
    $chkEnableArch.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $chkEnableArch.Size = New-Object System.Drawing.Size(110,22)
    $dlg.Controls.Add($chkEnableArch)
    $chkArchX86 = New-Object System.Windows.Forms.CheckBox
    $chkArchX86.Text = "x86"
    $chkArchX86.Location = New-Object System.Drawing.Point(480,$fieldsY)
    $chkArchX86.Size = New-Object System.Drawing.Size(48,22)
    $dlg.Controls.Add($chkArchX86)
    $chkArchX64 = New-Object System.Windows.Forms.CheckBox
    $chkArchX64.Text = "x64"
    $chkArchX64.Location = New-Object System.Drawing.Point(530,$fieldsY)
    $chkArchX64.Size = New-Object System.Drawing.Size(48,22)
    $chkArchX64.Checked = $true
    $dlg.Controls.Add($chkArchX64)
    $chkArchArm64 = New-Object System.Windows.Forms.CheckBox
    $chkArchArm64.Text = "ARM64"
    $chkArchArm64.Location = New-Object System.Drawing.Point(580,$fieldsY)
    $chkArchArm64.Size = New-Object System.Drawing.Size(65,22)
    $dlg.Controls.Add($chkArchArm64)
    $fieldsY += 30

    $chkEnableMinOS = New-Object System.Windows.Forms.CheckBox
    $chkEnableMinOS.Text = "Minimum Windows"
    $chkEnableMinOS.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $chkEnableMinOS.Size = New-Object System.Drawing.Size(190,22)
    $dlg.Controls.Add($chkEnableMinOS)
    $cmbMinOS = New-Object System.Windows.Forms.ComboBox
    $cmbMinOS.Location = New-Object System.Drawing.Point(560,$fieldsY)
    $cmbMinOS.Size = New-Object System.Drawing.Size(260,24)
    $cmbMinOS.DropDownStyle = "DropDownList"
    # Same full set Show-CreateInIntuneDialog/Show-DefaultAppSettingsDialog's
    # own $minOsMap offer - kept in sync manually, same as every other copy
    # of this list.
    $minOsRawValues = @("W10_1607", "W10_1703", "W10_1709", "W10_1803", "W10_1809", "W10_1903", "W10_1909", "W10_2004", "W10_20H2", "W10_21H1", "W10_21H2", "W10_22H2", "W11_21H2", "W11_22H2")
    $minOsMap = [ordered]@{}
    foreach ($rawValue in $minOsRawValues) { $minOsMap[(Get-FriendlyMinOsRelease -RawValue $rawValue)] = $rawValue }
    [void]$cmbMinOS.Items.AddRange(@($minOsMap.Keys))
    $cmbMinOS.SelectedIndex = 0
    $dlg.Controls.Add($cmbMinOS)
    $fieldsY += 34

    $chkEnableDiskSpace = New-Object System.Windows.Forms.CheckBox
    $chkEnableDiskSpace.Text = "Disk space (MB)"
    $chkEnableDiskSpace.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $chkEnableDiskSpace.Size = New-Object System.Drawing.Size(190,22)
    $dlg.Controls.Add($chkEnableDiskSpace)
    $txtDiskSpace = New-Object System.Windows.Forms.TextBox
    $txtDiskSpace.Location = New-Object System.Drawing.Point(560,$fieldsY)
    $txtDiskSpace.Size = New-Object System.Drawing.Size(120,23)
    $txtDiskSpace.Text = "0"
    $dlg.Controls.Add($txtDiskSpace)
    $fieldsY += 30

    $chkEnableMemory = New-Object System.Windows.Forms.CheckBox
    $chkEnableMemory.Text = "Memory (MB)"
    $chkEnableMemory.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $chkEnableMemory.Size = New-Object System.Drawing.Size(190,22)
    $dlg.Controls.Add($chkEnableMemory)
    $txtMemory = New-Object System.Windows.Forms.TextBox
    $txtMemory.Location = New-Object System.Drawing.Point(560,$fieldsY)
    $txtMemory.Size = New-Object System.Drawing.Size(120,23)
    $txtMemory.Text = "0"
    $dlg.Controls.Add($txtMemory)
    $fieldsY += 30

    $chkEnableProcessors = New-Object System.Windows.Forms.CheckBox
    $chkEnableProcessors.Text = "Min. processors"
    $chkEnableProcessors.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $chkEnableProcessors.Size = New-Object System.Drawing.Size(190,22)
    $dlg.Controls.Add($chkEnableProcessors)
    $txtProcessors = New-Object System.Windows.Forms.TextBox
    $txtProcessors.Location = New-Object System.Drawing.Point(560,$fieldsY)
    $txtProcessors.Size = New-Object System.Drawing.Size(120,23)
    $txtProcessors.Text = "0"
    $dlg.Controls.Add($txtProcessors)
    $fieldsY += 30

    $chkEnableCpuSpeed = New-Object System.Windows.Forms.CheckBox
    $chkEnableCpuSpeed.Text = "Min. CPU speed (MHz)"
    $chkEnableCpuSpeed.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $chkEnableCpuSpeed.Size = New-Object System.Drawing.Size(190,22)
    $dlg.Controls.Add($chkEnableCpuSpeed)
    $txtCpuSpeed = New-Object System.Windows.Forms.TextBox
    $txtCpuSpeed.Location = New-Object System.Drawing.Point(560,$fieldsY)
    $txtCpuSpeed.Size = New-Object System.Drawing.Size(120,23)
    $txtCpuSpeed.Text = "0"
    $dlg.Controls.Add($txtCpuSpeed)
    $fieldsY += 30

    $chkEnableInstallTime = New-Object System.Windows.Forms.CheckBox
    $chkEnableInstallTime.Text = "Install time required (mins)"
    $chkEnableInstallTime.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $chkEnableInstallTime.Size = New-Object System.Drawing.Size(190,22)
    $dlg.Controls.Add($chkEnableInstallTime)
    $txtInstallTime = New-Object System.Windows.Forms.TextBox
    $txtInstallTime.Location = New-Object System.Drawing.Point(560,$fieldsY)
    $txtInstallTime.Size = New-Object System.Drawing.Size(120,23)
    $txtInstallTime.Text = "60"
    $dlg.Controls.Add($txtInstallTime)
    $fieldsY += 34

    $chkEnableRestartBehavior = New-Object System.Windows.Forms.CheckBox
    $chkEnableRestartBehavior.Text = "Device restart behavior"
    $chkEnableRestartBehavior.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $chkEnableRestartBehavior.Size = New-Object System.Drawing.Size(190,22)
    $dlg.Controls.Add($chkEnableRestartBehavior)
    $cmbRestartBehavior = New-Object System.Windows.Forms.ComboBox
    $cmbRestartBehavior.Location = New-Object System.Drawing.Point(560,$fieldsY)
    $cmbRestartBehavior.Size = New-Object System.Drawing.Size(260,24)
    $cmbRestartBehavior.DropDownStyle = "DropDownList"
    $restartBehaviorMap = [ordered]@{
        "Determine behavior based on return codes"      = "basedOnReturnCode"
        "No specific action"                            = "allow"
        "App install may force a device restart"        = "suppress"
        "Intune will force a mandatory device restart"  = "force"
    }
    foreach ($k in $restartBehaviorMap.Keys) { [void]$cmbRestartBehavior.Items.Add($k) }
    $cmbRestartBehavior.SelectedIndex = 0
    $dlg.Controls.Add($cmbRestartBehavior)
    $fieldsY += 34

    $chkEnableAllowUninstall = New-Object System.Windows.Forms.CheckBox
    $chkEnableAllowUninstall.Text = "Allow available uninstall"
    $chkEnableAllowUninstall.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $chkEnableAllowUninstall.Size = New-Object System.Drawing.Size(190,22)
    $dlg.Controls.Add($chkEnableAllowUninstall)
    $chkAllowUninstall = New-Object System.Windows.Forms.CheckBox
    $chkAllowUninstall.Text = "Yes"
    $chkAllowUninstall.Location = New-Object System.Drawing.Point(560,$fieldsY)
    $chkAllowUninstall.Size = New-Object System.Drawing.Size(60,22)
    $dlg.Controls.Add($chkAllowUninstall)
    $fieldsY += 34

    $chkEnableReturnCodes = New-Object System.Windows.Forms.CheckBox
    $chkEnableReturnCodes.Text = "Return codes (replaces the whole list)"
    $chkEnableReturnCodes.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $chkEnableReturnCodes.AutoSize = $true
    $dlg.Controls.Add($chkEnableReturnCodes)
    $fieldsY += 22
    $grdReturnCodes = New-Object System.Windows.Forms.DataGridView
    $grdReturnCodes.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $grdReturnCodes.Size = New-Object System.Drawing.Size(425,120)
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
    foreach ($rc in @(
        [pscustomobject]@{ returnCode = 0; type = "success" }
        [pscustomobject]@{ returnCode = 1707; type = "success" }
        [pscustomobject]@{ returnCode = 3010; type = "softReboot" }
        [pscustomobject]@{ returnCode = 1641; type = "hardReboot" }
        [pscustomobject]@{ returnCode = 1618; type = "retry" }
    )) {
        $rowIdx = $grdReturnCodes.Rows.Add()
        $grdReturnCodes.Rows[$rowIdx].Cells["Code"].Value = [string]$rc.returnCode
        $grdReturnCodes.Rows[$rowIdx].Cells["Type"].Value = [string]$rc.type
    }
    $btnAddReturnCode = New-Object System.Windows.Forms.Button
    $btnAddReturnCode.Text = "Add row"
    $btnAddReturnCode.Location = New-Object System.Drawing.Point(800,$fieldsY)
    $btnAddReturnCode.Size = New-Object System.Drawing.Size(90,26)
    $dlg.Controls.Add($btnAddReturnCode)
    $btnAddReturnCode.Add_Click({
        $rowIdx = $grdReturnCodes.Rows.Add()
        $grdReturnCodes.Rows[$rowIdx].Cells["Type"].Value = "success"
    }.GetNewClosure())
    $btnRemoveReturnCode = New-Object System.Windows.Forms.Button
    $btnRemoveReturnCode.Text = "Remove row"
    $btnRemoveReturnCode.Location = New-Object System.Drawing.Point(800,($fieldsY+30))
    $btnRemoveReturnCode.Size = New-Object System.Drawing.Size(90,26)
    $dlg.Controls.Add($btnRemoveReturnCode)
    $btnRemoveReturnCode.Add_Click({
        if ($grdReturnCodes.CurrentRow) { $grdReturnCodes.Rows.RemoveAt($grdReturnCodes.CurrentRow.Index) }
    }.GetNewClosure())
    $fieldsY += 130

    $chkEnableDependencies = New-Object System.Windows.Forms.CheckBox
    $chkEnableDependencies.Text = "Dependencies (replaces the whole list)"
    $chkEnableDependencies.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $chkEnableDependencies.AutoSize = $true
    $dlg.Controls.Add($chkEnableDependencies)
    $fieldsY += 22
    $clbDeps = New-Object System.Windows.Forms.CheckedListBox
    $clbDeps.Location = New-Object System.Drawing.Point(365,$fieldsY)
    $clbDeps.Size = New-Object System.Drawing.Size(560,70)
    $clbDeps.CheckOnClick = $true
    $dlg.Controls.Add($clbDeps)
    # A dependency on itself is silently dropped per-app at run time below
    # (an app can't depend on itself), not filtered out of this list up
    # front - the same shared list is offered for every checked app, and
    # which app(s) that would even apply to varies per app being changed.
    foreach ($a in ($appsRef | Sort-Object appName)) { [void]$clbDeps.Items.Add($a.appName) }

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,660)
    $lblStatus.Size = New-Object System.Drawing.Size(920,20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(15,684)
    $progressBar.Size = New-Object System.Drawing.Size(920,12)
    $progressBar.Style = "Continuous"
    $dlg.Controls.Add($progressBar)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,700)
    $rtbLog.Size = New-Object System.Drawing.Size(920,90)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Apply to Intune..."
    $btnRun.Location = New-Object System.Drawing.Point(755,796)
    $btnRun.Size = New-Object System.Drawing.Size(180,32)
    $dlg.Controls.Add($btnRun)
    $runTip = New-Object System.Windows.Forms.ToolTip
    $runTip.SetToolTip($btnRun, "Applies every checked field change to every checked app in Intune. Unchecked apps and unchecked fields are left untouched.")

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(665,796)
    $btnClose.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnClose)

    $procBox = @{ Proc = $null }

    $btnSelectAll.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $true) }
    }.GetNewClosure())
    $btnSelectNone.Add_Click({
        for ($ci = 0; $ci -lt $clbApps.Items.Count; $ci++) { $clbApps.SetItemChecked($ci, $false) }
    }.GetNewClosure())

    $RunNextBox = @{ Value = $null }

    $RunNextBox.Value = {
        param($Queue, $QueueIndex, $Results, $Changes)

        if ($QueueIndex -ge $Queue.Count) {
            $updatedCount = @($Results | Where-Object { $_.Status -eq "Updated" }).Count
            $failedCount  = @($Results | Where-Object { $_.Status -eq "Failed" }).Count
            $progressBar.Value = $progressBar.Maximum
            $btnRun.Enabled = $true
            $btnSelectAll.Enabled = $true
            $btnSelectNone.Enabled = $true
            $clbApps.Enabled = $true
            $lblStatus.ForeColor = if ($failedCount -gt 0) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::SeaGreen }
            $lblStatus.Text = "Done - $updatedCount updated, $failedCount failed."
            Update-Grid
            if ($failedCount -eq 0) { $dlg.Close() }
            return
        }

        $currentApp = $Queue[$QueueIndex]
        Write-DialogLogLine -LogBox $rtbLog -Text "`r`n[$($QueueIndex+1)/$($Queue.Count)] $($currentApp.appName)`r`n" -MirrorToMainLog
        $lblStatus.Text = "Updating $($QueueIndex+1) of $($Queue.Count): $($currentApp.appName)..."
        $progressBar.Value = $QueueIndex

        # Starts from this app's OWN saved metadata (every field, not just
        # the ones being changed) - UpdateMetadata PATCHes the whole
        # win32LobApp shape at once (see this function's own top comment),
        # so anything not explicitly overridden here must still be the
        # app's real current value, not a blank/default.
        $m = $currentApp.metadata
        $newMetadata = [pscustomobject]@{
            description      = $m.description
            publisher        = $m.publisher
            owner            = $m.owner
            developer        = $m.developer
            informationUrl   = $m.informationUrl
            privacyUrl       = $m.privacyUrl
            notes            = $m.notes
            installCommand   = $m.installCommand
            uninstallCommand = $m.uninstallCommand
            architecture     = $m.architecture
            installContext   = $m.installContext
            minOSKey         = $m.minOSKey
            detectionRule    = $m.detectionRule
            dependencies     = @($m.dependencies)
            minDiskSpaceMB          = $m.minDiskSpaceMB
            minMemoryMB             = $m.minMemoryMB
            minProcessors           = $m.minProcessors
            minCpuSpeedMHz          = $m.minCpuSpeedMHz
            installTimeMinutes      = $m.installTimeMinutes
            deviceRestartBehavior   = $m.deviceRestartBehavior
            allowAvailableUninstall = $m.allowAvailableUninstall
            returnCodes             = @($m.returnCodes)
        }
        if ($Changes.Architecture)          { $newMetadata.architecture = $Changes.Architecture }
        if ($Changes.MinOSKey)               { $newMetadata.minOSKey = $Changes.MinOSKey }
        if ($null -ne $Changes.MinDiskSpaceMB)       { $newMetadata.minDiskSpaceMB = $Changes.MinDiskSpaceMB }
        if ($null -ne $Changes.MinMemoryMB)          { $newMetadata.minMemoryMB = $Changes.MinMemoryMB }
        if ($null -ne $Changes.MinProcessors)        { $newMetadata.minProcessors = $Changes.MinProcessors }
        if ($null -ne $Changes.MinCpuSpeedMHz)       { $newMetadata.minCpuSpeedMHz = $Changes.MinCpuSpeedMHz }
        if ($null -ne $Changes.InstallTimeMinutes)   { $newMetadata.installTimeMinutes = $Changes.InstallTimeMinutes }
        if ($Changes.DeviceRestartBehavior)  { $newMetadata.deviceRestartBehavior = $Changes.DeviceRestartBehavior }
        if ($null -ne $Changes.AllowAvailableUninstall) { $newMetadata.allowAvailableUninstall = $Changes.AllowAvailableUninstall }
        if ($null -ne $Changes.ReturnCodes)  { $newMetadata.returnCodes = @($Changes.ReturnCodes) }
        if ($null -ne $Changes.Dependencies) {
            # An app can't depend on itself - silently dropped here rather
            # than failing the whole batch over it, same "skip just the
            # one bad piece, not the whole app" reasoning Show-BatchDeployDialog
            # already uses for an unresolved dependency App ID.
            $newMetadata.dependencies = @($Changes.Dependencies | Where-Object { $_ -ne $currentApp.appName })
        }

        $resolvedDepIds = New-Object System.Collections.Generic.List[string]
        foreach ($depName in @($newMetadata.dependencies)) {
            $depApp = $appsRef | Where-Object { $_.appName -eq $depName } | Select-Object -First 1
            if ($depApp -and $depApp.appId) {
                $resolvedDepIds.Add($depApp.appId)
            }
            else {
                Write-DialogLogLine -LogBox $rtbLog -Text "  [SKIPPED] Dependency `"$depName`" has no App ID yet - skipping just that dependency, not the whole app.`r`n" -MirrorToMainLog
            }
        }

        $configPath = Join-Path $env:TEMP (".intunepkg_batchedit_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_batchedit_result_" + [guid]::NewGuid().ToString("N") + ".json")

        $config = [pscustomobject]@{
            TenantId                = $tenantId
            ClientId                = $clientId
            CertificateThumbprint   = $certThumb
            Mode                    = "UpdateMetadata"
            ExistingAppId           = $currentApp.appId
            AppName                 = $currentApp.appName
            Description             = $newMetadata.description
            Publisher               = $newMetadata.publisher
            Owner                   = $newMetadata.owner
            Developer               = $newMetadata.developer
            InformationUrl          = $newMetadata.informationUrl
            PrivacyUrl              = $newMetadata.privacyUrl
            Notes                   = $newMetadata.notes
            InstallCommand          = $newMetadata.installCommand
            UninstallCommand        = $newMetadata.uninstallCommand
            DetectionRule           = $newMetadata.detectionRule
            InstallContext          = $newMetadata.installContext
            Architecture            = $newMetadata.architecture
            MinOSVersionKey         = $newMetadata.minOSKey
            MinDiskSpaceMB          = $newMetadata.minDiskSpaceMB
            MinMemoryMB             = $newMetadata.minMemoryMB
            MinProcessors           = $newMetadata.minProcessors
            MinCpuSpeedMHz          = $newMetadata.minCpuSpeedMHz
            InstallTimeMinutes      = $newMetadata.installTimeMinutes
            DeviceRestartBehavior   = $newMetadata.deviceRestartBehavior
            AllowAvailableUninstall = $newMetadata.allowAvailableUninstall
            ReturnCodes             = @($newMetadata.returnCodes)
            PackagePath             = ""
            DependencyAppIds        = @($resolvedDepIds)
            ReplaceContent          = $false
            OutputResultPath        = $resultPath
        }

        try {
            $configJsonText = $config | ConvertTo-Json -Depth 10 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Show-ConfigWriteFailedError -ErrorMessage $_.Exception.Message
            return
        }

        # Fresh aliases for this nested -OnComplete closure - see note at
        # the top of Show-CreateInIntuneDialog for why this matters here too.
        $currentAppRef = $currentApp
        $newMetadataRef = $newMetadata
        $queueRef = $Queue
        $queueIndexRef = $QueueIndex
        $resultsRef = $Results
        $changesRef = $Changes
        $configPathRef = $configPath
        $resultPathRef = $resultPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $appsRefRef = $appsRef
        $RunNextBoxRef = $RunNextBox
        $linkedFilePathRef = $linkedFilePath
        $unsavedBoxRef = $unsavedBox

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $createScript -TempScriptName ".intunepkg_embedded_batchedit.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLogRef -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            $status = "Failed"
            $message = "No result written (exit code $code)."
            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw -Encoding UTF8 | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $status = "Updated"
                        $message = "Updated"
                        for ($ai = 0; $ai -lt $appsRefRef.Count; $ai++) {
                            if ($appsRefRef[$ai].appName -eq $currentAppRef.appName) {
                                # Saved as the NEW values just pushed, not
                                # re-fetched from Intune - a successful PATCH
                                # means Intune now matches this exactly.
                                $appsRefRef[$ai].metadata = $newMetadataRef
                                break
                            }
                        }
                        $unsavedBoxRef.Value = $true
                        # Direct-save after EACH successful app, not just once
                        # at the end - same reasoning as Show-BatchDeployDialog's
                        # own per-app save: an interrupted batch shouldn't lose
                        # progress already confirmed successful in Intune.
                        [void](Save-AppsToFile -Path $linkedFilePathRef)
                        Write-DialogLogLine -LogBox $rtbLogRef -Text "  [OK] Updated.`r`n" -MirrorToMainLog
                    }
                    else {
                        $message = $result.error
                        Write-DialogLogLine -LogBox $rtbLogRef -Text "  [FAILED] $($result.error)`r`n" -MirrorToMainLog
                    }
                }
                catch {
                    $message = "Could not read result: $($_.Exception.Message)"
                    Write-DialogLogLine -LogBox $rtbLogRef -Text "  [FAILED] Could not read result: $($_.Exception.Message)`r`n" -MirrorToMainLog
                }
            }
            else {
                Write-DialogLogLine -LogBox $rtbLogRef -Text "  [FAILED] $message`r`n" -MirrorToMainLog
            }

            $resultsRef.Add([pscustomobject]@{ AppName = $currentAppRef.appName; Status = $status; Message = $message })
            & $RunNextBoxRef.Value -Queue $queueRef -QueueIndex ($queueIndexRef + 1) -Results $resultsRef -Changes $changesRef
        }.GetNewClosure()
    }.GetNewClosure()

    $btnRun.Add_Click({
        $checkedNames = @($clbApps.CheckedItems | ForEach-Object { [string]$_ })
        if ($checkedNames.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one app to change.", "Nothing selected", "OK", "Warning") | Out-Null
            return
        }
        if (-not ($chkEnableArch.Checked -or $chkEnableMinOS.Checked -or $chkEnableDiskSpace.Checked -or $chkEnableMemory.Checked -or $chkEnableProcessors.Checked -or $chkEnableCpuSpeed.Checked -or $chkEnableInstallTime.Checked -or $chkEnableRestartBehavior.Checked -or $chkEnableAllowUninstall.Checked -or $chkEnableReturnCodes.Checked -or $chkEnableDependencies.Checked)) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one field to change.", "Nothing to change", "OK", "Warning") | Out-Null
            return
        }
        if ($chkEnableArch.Checked -and -not ($chkArchX86.Checked -or $chkArchX64.Checked -or $chkArchArm64.Checked)) {
            [System.Windows.Forms.MessageBox]::Show("Architecture is checked, but no architecture is selected. Pick at least one (x86/x64/ARM64).", "Nothing selected", "OK", "Warning") | Out-Null
            return
        }

        # Same [int]::TryParse validation as Show-DefaultAppSettingsDialog's
        # own identical set of numeric fields, only for whichever ones are
        # actually checked here - a raw [int] cast further down used to
        # throw an unhandled exception (aborting the whole batch) on any
        # non-numeric text, instead of the friendly warning every other
        # numeric field in this app already gives.
        $numericChecks = @(
            @{ Label = "Disk space (MB)"; Box = $txtDiskSpace; Enabled = $chkEnableDiskSpace.Checked }
            @{ Label = "Memory (MB)"; Box = $txtMemory; Enabled = $chkEnableMemory.Checked }
            @{ Label = "Min. processors"; Box = $txtProcessors; Enabled = $chkEnableProcessors.Checked }
            @{ Label = "Min. CPU speed (MHz)"; Box = $txtCpuSpeed; Enabled = $chkEnableCpuSpeed.Checked }
            @{ Label = "Install time required (mins)"; Box = $txtInstallTime; Enabled = $chkEnableInstallTime.Checked }
        )
        foreach ($numCheck in $numericChecks) {
            if (-not $numCheck.Enabled) { continue }
            $parsedNum = 0
            if (-not [int]::TryParse($numCheck.Box.Text.Trim(), [ref]$parsedNum) -or $parsedNum -lt 0) {
                [System.Windows.Forms.MessageBox]::Show("$($numCheck.Label) must be a whole number, 0 or greater.", "Invalid value", "OK", "Warning") | Out-Null
                return
            }
        }

        $checkedApps = New-Object System.Collections.Generic.List[object]
        foreach ($name in $checkedNames) {
            $matchApp = $eligibleApps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
            if ($matchApp) { $checkedApps.Add($matchApp) }
        }

        $changeSummary = New-Object System.Collections.Generic.List[string]
        $changes = [pscustomobject]@{
            Architecture = $null; MinOSKey = $null; MinDiskSpaceMB = $null; MinMemoryMB = $null
            MinProcessors = $null; MinCpuSpeedMHz = $null; InstallTimeMinutes = $null
            DeviceRestartBehavior = $null; AllowAvailableUninstall = $null; ReturnCodes = $null; Dependencies = $null
        }
        if ($chkEnableArch.Checked) {
            $archList = @(@("x86","x64","arm64") | Where-Object { ($_ -eq "x86" -and $chkArchX86.Checked) -or ($_ -eq "x64" -and $chkArchX64.Checked) -or ($_ -eq "arm64" -and $chkArchArm64.Checked) })
            $changes.Architecture = $archList -join ","
            $changeSummary.Add("Architecture -> $($changes.Architecture)")
        }
        if ($chkEnableMinOS.Checked) {
            $changes.MinOSKey = $minOsMap[[string]$cmbMinOS.SelectedItem]
            $changeSummary.Add("Minimum Windows -> $($cmbMinOS.SelectedItem)")
        }
        if ($chkEnableDiskSpace.Checked)      { $changes.MinDiskSpaceMB = [int]$txtDiskSpace.Text.Trim(); $changeSummary.Add("Disk space (MB) -> $($changes.MinDiskSpaceMB)") }
        if ($chkEnableMemory.Checked)         { $changes.MinMemoryMB = [int]$txtMemory.Text.Trim(); $changeSummary.Add("Memory (MB) -> $($changes.MinMemoryMB)") }
        if ($chkEnableProcessors.Checked)     { $changes.MinProcessors = [int]$txtProcessors.Text.Trim(); $changeSummary.Add("Min. processors -> $($changes.MinProcessors)") }
        if ($chkEnableCpuSpeed.Checked)       { $changes.MinCpuSpeedMHz = [int]$txtCpuSpeed.Text.Trim(); $changeSummary.Add("Min. CPU speed (MHz) -> $($changes.MinCpuSpeedMHz)") }
        if ($chkEnableInstallTime.Checked)    { $changes.InstallTimeMinutes = [int]$txtInstallTime.Text.Trim(); $changeSummary.Add("Install time (mins) -> $($changes.InstallTimeMinutes)") }
        if ($chkEnableRestartBehavior.Checked) {
            $changes.DeviceRestartBehavior = $restartBehaviorMap[[string]$cmbRestartBehavior.SelectedItem]
            $changeSummary.Add("Device restart behavior -> $($cmbRestartBehavior.SelectedItem)")
        }
        if ($chkEnableAllowUninstall.Checked) { $changes.AllowAvailableUninstall = $chkAllowUninstall.Checked; $changeSummary.Add("Allow available uninstall -> $(if ($chkAllowUninstall.Checked) { 'Yes' } else { 'No' })") }
        if ($chkEnableReturnCodes.Checked) {
            $rcList = New-Object System.Collections.Generic.List[object]
            foreach ($row in $grdReturnCodes.Rows) {
                if ($row.IsNewRow) { continue }
                $rcCode = [string]$row.Cells["Code"].Value
                $rcType = [string]$row.Cells["Type"].Value
                if (-not $rcCode -and -not $rcType) { continue }
                $parsedRc = 0
                [void][int]::TryParse($rcCode.Trim(), [ref]$parsedRc)
                $rcList.Add([pscustomobject]@{ returnCode = $parsedRc; type = $rcType })
            }
            if ($rcList.Count -eq 0) {
                # Intune always needs return codes - an app update without any
                # gets these (CreateApp.ps1), so the catalog gets them too
                foreach ($standardRc in @(@(0, 'success'), @(1707, 'success'), @(3010, 'softReboot'), @(1641, 'hardReboot'), @(1618, 'retry'))) {
                    $rcList.Add([pscustomobject]@{ returnCode = $standardRc[0]; type = $standardRc[1] })
                }
                $changeSummary.Add("Return codes -> Intune's standard set (0, 1707, 3010, 1641, 1618), since no rows are entered")
            }
            else {
                $changeSummary.Add("Return codes -> the $($rcList.Count) row(s) entered")
            }
            $changes.ReturnCodes = $rcList.ToArray()
        }
        if ($chkEnableDependencies.Checked) {
            $changes.Dependencies = @($clbDeps.CheckedItems | ForEach-Object { [string]$_ })
            $depsText = if ($changes.Dependencies.Count -gt 0) { $changes.Dependencies -join ", " } else { "none (existing dependencies are removed)" }
            $changeSummary.Add("Dependencies -> $depsText")
        }

        $appList = (@($checkedNames | Select-Object -First 15) -join ", ") + $(if ($checkedNames.Count -gt 15) { ", and $($checkedNames.Count - 15) more" })
        $confirmMsg = "Update $($checkedApps.Count) app(s) in Intune and in the catalog with these settings?`n`n$($changeSummary -join "`n")`n`nApps: $appList"
        $r = [System.Windows.Forms.MessageBox]::Show($confirmMsg, "Confirm batch edit", "YesNo", "Warning", "Button2")
        if ($r -ne "Yes") { return }

        $btnRun.Enabled = $false
        $btnSelectAll.Enabled = $false
        $btnSelectNone.Enabled = $false
        $clbApps.Enabled = $false
        $rtbLog.Clear()
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Starting..."
        $progressBar.Minimum = 0
        $progressBar.Maximum = [Math]::Max(1, $checkedApps.Count)
        $progressBar.Value = 0

        $resultsList = New-Object System.Collections.Generic.List[object]
        & $RunNextBox.Value -Queue $checkedApps.ToArray() -QueueIndex 0 -Results $resultsList -Changes $changes
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    Register-CloseConfirmation -Dialog $dlg -GetQuestion {
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            "A batch edit is still running. Stop it and close?`n`nApps already updated in Intune stay updated."
        }
    }.GetNewClosure() -OnConfirmed { $procBox.Proc.Kill() }.GetNewClosure()
    $dlg.CancelButton = $btnClose

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
