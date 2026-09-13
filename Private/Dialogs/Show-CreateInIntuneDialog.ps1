function Global:Show-CreateInIntuneDialog {
    param(
        [string]$AppName, [string]$WingetId, [string]$ExistingAppId, [switch]$FromAppEditor,
        # Same meaning as Show-AppEditor's own -CurrentIndex - only set (and
        # only >= 0) when this was opened FROM the app editor for an app
        # actually at a known catalog position, which is the only case
        # where the Previous/Next buttons below make sense. Powers
        # navigating straight from one app's Deploy view to the next one's,
        # without a detour back through the plain editor screen in between.
        [int]$CurrentIndex = -1
    )

    # Derived, not passed in separately - see Test-AppIsUncommon. Keeps this
    # dialog's notion of "uncommon" in sync with the same single source of
    # truth the rest of the app uses, rather than a second copy that could
    # drift from it.
    $Uncommon = [string]::IsNullOrWhiteSpace($WingetId)

    # Plain local aliases - see note in Start-IntuneAppLookup. Everything the
    # nested -OnComplete closure inside btnCreate's handler touches must be a
    # freshly-assigned plain variable, not a $Script:-qualified read or a
    # variable this function itself only inherited from an outer closure.
    $rootPath      = $Global:App.RootPath
    $tenantId      = $Global:App.GraphTenantId
    $clientId      = $Global:App.GraphClientId
    $certThumb     = $Global:App.GraphCertificateThumbprint
    $createScript  = $Global:App.EmbeddedCreateAppScript
    $appsRef       = $Global:App.Apps
    $unsavedBox    = $Global:App.UnsavedChangesBox
    $linkedFilePath = $Global:App.LinkedFilePath

    # Previous/Next targets - same filtered-list computation as
    # Show-AppEditor's own (duplicated rather than shared, same reasoning
    # as that copy's own comment: it's a two-line check, not worth
    # threading a delegate through a function with otherwise zero
    # dependency on the main grid's internals).
    $prevAppIndex = $null
    $nextAppIndex = $null
    if ($CurrentIndex -ge 0) {
        $navFilter = $Global:App.TxtSearch.Text.Trim().ToLower()
        $visibleAppIndices = New-Object System.Collections.Generic.List[int]
        for ($vi = 0; $vi -lt $appsRef.Count; $vi++) {
            if ($navFilter) {
                $navHay = ("$($appsRef[$vi].appName) $($appsRef[$vi].wingetId)").ToLower()
                if ($navHay -notlike "*$navFilter*") { continue }
            }
            $visibleAppIndices.Add($vi)
        }
        $navPos = $visibleAppIndices.IndexOf($CurrentIndex)
        if ($navPos -gt 0) { $prevAppIndex = $visibleAppIndices[$navPos - 1] }
        if ($navPos -ge 0 -and $navPos -lt ($visibleAppIndices.Count - 1)) { $nextAppIndex = $visibleAppIndices[$navPos + 1] }
    }

    # A mutable container, not a plain variable - needs to be WRITTEN from
    # inside the auto-fetch's nested -OnComplete closure further down (a
    # two-level closure, which can only safely mutate a reference type's
    # contents, not reassign a plain outer variable), then READ later from
    # "Save local copy..."'s own, separate button handler - a real gap this
    # was built to fix: that handler used to hardcode dependencies as
    # always empty for every existing app, regardless of what Intune
    # actually had. Declared HERE, at the very top of the function, before
    # ANY button or closure gets built - the "Save local copy..." button's
    # own .GetNewClosure() runs earlier in this function's execution than
    # where this was originally declared, and .GetNewClosure() captures
    # variables BY VALUE at the moment it's called, not as a live reference
    # to something declared afterward. Declaring this after that closure
    # was already built would have meant it captured $null, not this
    # container - the exact same class of bug as the self-referencing
    # $RunDelete closure fixed earlier this session, caught here before
    # shipping by explicitly checking declaration order rather than
    # assuming it was fine.
    $fetchedDependencyBox = @{ Names = @() }

    $isDuplicate = [bool]$ExistingAppId

    # Single source of truth for every default value this form pre-fills
    # for a brand-new app - Batch Deploy's own Get-DefaultAppMetadata
    # computes the exact same defaults for an app that has no saved
    # metadata, so both places read from one function instead of
    # maintaining two separately-hardcoded copies of "what a new app
    # defaults to" that could silently drift apart. Computed unconditionally
    # (not just when -not $isDuplicate) - several of these fields (requirements,
    # return codes, restart behavior) are set as a sensible placeholder even
    # in Update mode, later overwritten by the live Intune fetch below if
    # that succeeds; same reasoning the original hardcoded values already
    # followed.
    $defaults = Get-DefaultAppMetadata -AppName $AppName -WingetId $WingetId -Uncommon $Uncommon

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Deploy to Intune - $AppName"
    # 40px taller than before, to fit the Previous/Next row below the
    # existing Save/Deploy/Cancel row without moving any of this
    # function's many other absolutely-positioned controls.
    $dlg.ClientSize = New-Object System.Drawing.Size(730, 1030)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    # This dialog has grown past what fits on a typical screen - everything
    # from here down to the Dependencies checklist lives inside a scrollable
    # panel with a fixed visible height, instead of the dialog itself just
    # being 1230px tall. Status/log/buttons stay pinned below it, outside
    # the scroll area, so they're always reachable without scrolling down to
    # find them.
    $scrollPanel = New-Object System.Windows.Forms.Panel
    $scrollPanel.Location = New-Object System.Drawing.Point(0,0)
    $scrollPanel.Size = New-Object System.Drawing.Size(730,560)
    $scrollPanel.AutoScroll = $true
    $dlg.Controls.Add($scrollPanel)

    if ($isDuplicate) {
        $lblDup = New-Object System.Windows.Forms.Label
        $lblDup.Text = "This app already has an App ID ($ExistingAppId). By default this will UPDATE that app's metadata (name/description/install/uninstall/detection/dependencies) - it will NOT touch or re-upload package content."
        $lblDup.Location = New-Object System.Drawing.Point(15,12)
        $lblDup.Size = New-Object System.Drawing.Size(675,44)
        $lblDup.ForeColor = [System.Drawing.Color]::DarkOrange
        $scrollPanel.Controls.Add($lblDup)

        $chkForceNew = New-Object System.Windows.Forms.CheckBox
        $chkForceNew.Text = "Create a brand new app instead (uploads package content, leaves the existing app untouched)"
        $chkForceNew.Location = New-Object System.Drawing.Point(15,58)
        $chkForceNew.Size = New-Object System.Drawing.Size(675,20)
        $scrollPanel.Controls.Add($chkForceNew)

        $chkReplaceContent = New-Object System.Windows.Forms.CheckBox
        $chkReplaceContent.Text = "Also replace package content on the existing app (uses the Package field below)"
        $chkReplaceContent.Location = New-Object System.Drawing.Point(15,80)
        $chkReplaceContent.Size = New-Object System.Drawing.Size(675,20)
        $scrollPanel.Controls.Add($chkReplaceContent)
    }

    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = "Name"
    $lblName.Location = New-Object System.Drawing.Point(15,109)
    $lblName.AutoSize = $true
    $scrollPanel.Controls.Add($lblName)

    $txtCreateName = New-Object System.Windows.Forms.TextBox
    $txtCreateName.Location = New-Object System.Drawing.Point(15,128)
    $txtCreateName.Size = New-Object System.Drawing.Size(675,24)
    $txtCreateName.Text = $AppName
    $scrollPanel.Controls.Add($txtCreateName)

    $lblDesc = New-Object System.Windows.Forms.Label
    $lblDesc.Text = "Description"
    $lblDesc.Location = New-Object System.Drawing.Point(15,160)
    $lblDesc.AutoSize = $true
    $scrollPanel.Controls.Add($lblDesc)

    $txtDesc = New-Object System.Windows.Forms.TextBox
    $txtDesc.Location = New-Object System.Drawing.Point(15,179)
    $txtDesc.Size = New-Object System.Drawing.Size(675,24)
    if (-not $isDuplicate) { $txtDesc.Text = $AppName }
    $scrollPanel.Controls.Add($txtDesc)

    $lblPublisher = New-Object System.Windows.Forms.Label
    $lblPublisher.Text = "Publisher"
    $lblPublisher.Location = New-Object System.Drawing.Point(15,211)
    $lblPublisher.AutoSize = $true
    $scrollPanel.Controls.Add($lblPublisher)

    $txtPublisher = New-Object System.Windows.Forms.TextBox
    $txtPublisher.Location = New-Object System.Drawing.Point(15,230)
    $txtPublisher.Size = New-Object System.Drawing.Size(675,24)
    if (-not $isDuplicate) { $txtPublisher.Text = $defaults.publisher }
    $scrollPanel.Controls.Add($txtPublisher)

    # Optional, purely descriptive fields - not tied to install mechanics, so
    # (unlike install context/architecture/min OS) these are freely editable
    # at any time, in both Create and Update mode. In Update mode these start
    # blank and then get repopulated with what's actually live in Intune once
    # Start-AppMetadataFetch comes back (see the dialog's Add_Shown handler
    # below) - if that fetch fails, they stay blank, and the embedded script
    # only includes a field in the request if you've actually typed
    # something, so a blank field here still never overwrites an existing
    # value with nothing even when the fetch didn't succeed.
    $lblOwner = New-Object System.Windows.Forms.Label
    $lblOwner.Text = "Owner (optional)"
    $lblOwner.Location = New-Object System.Drawing.Point(15,262)
    $lblOwner.AutoSize = $true
    $scrollPanel.Controls.Add($lblOwner)

    $txtOwner = New-Object System.Windows.Forms.TextBox
    $txtOwner.Location = New-Object System.Drawing.Point(15,281)
    $txtOwner.Size = New-Object System.Drawing.Size(280,24)
    $scrollPanel.Controls.Add($txtOwner)

    $lblDeveloper = New-Object System.Windows.Forms.Label
    $lblDeveloper.Text = "Developer (optional)"
    $lblDeveloper.Location = New-Object System.Drawing.Point(325,262)
    $lblDeveloper.AutoSize = $true
    $scrollPanel.Controls.Add($lblDeveloper)

    $txtDeveloper = New-Object System.Windows.Forms.TextBox
    $txtDeveloper.Location = New-Object System.Drawing.Point(325,281)
    $txtDeveloper.Size = New-Object System.Drawing.Size(280,24)
    $scrollPanel.Controls.Add($txtDeveloper)

    $lblInfoUrl = New-Object System.Windows.Forms.Label
    $lblInfoUrl.Text = "Information URL (optional)"
    $lblInfoUrl.Location = New-Object System.Drawing.Point(15,313)
    $lblInfoUrl.AutoSize = $true
    $scrollPanel.Controls.Add($lblInfoUrl)

    $txtInfoUrl = New-Object System.Windows.Forms.TextBox
    $txtInfoUrl.Location = New-Object System.Drawing.Point(15,332)
    $txtInfoUrl.Size = New-Object System.Drawing.Size(280,24)
    $scrollPanel.Controls.Add($txtInfoUrl)

    $lblPrivacyUrl = New-Object System.Windows.Forms.Label
    $lblPrivacyUrl.Text = "Privacy URL (optional)"
    $lblPrivacyUrl.Location = New-Object System.Drawing.Point(325,313)
    $lblPrivacyUrl.AutoSize = $true
    $scrollPanel.Controls.Add($lblPrivacyUrl)

    $txtPrivacyUrl = New-Object System.Windows.Forms.TextBox
    $txtPrivacyUrl.Location = New-Object System.Drawing.Point(325,332)
    $txtPrivacyUrl.Size = New-Object System.Drawing.Size(280,24)
    $scrollPanel.Controls.Add($txtPrivacyUrl)

    $lblNotes = New-Object System.Windows.Forms.Label
    $lblNotes.Text = "Notes (optional)"
    $lblNotes.Location = New-Object System.Drawing.Point(15,364)
    $lblNotes.AutoSize = $true
    $scrollPanel.Controls.Add($lblNotes)

    $txtNotes = New-Object System.Windows.Forms.TextBox
    $txtNotes.Location = New-Object System.Drawing.Point(15,383)
    $txtNotes.Size = New-Object System.Drawing.Size(675,40)
    $txtNotes.Multiline = $true
    $scrollPanel.Controls.Add($txtNotes)

    $lblPackage = New-Object System.Windows.Forms.Label
    $lblPackage.Text = "Package (.intunewin) - used when creating a new app, or when replacing content on an existing one"
    $lblPackage.Location = New-Object System.Drawing.Point(15,433)
    $lblPackage.AutoSize = $true
    $scrollPanel.Controls.Add($lblPackage)

    $txtPackagePath = New-Object System.Windows.Forms.TextBox
    $txtPackagePath.Location = New-Object System.Drawing.Point(15,452)
    $txtPackagePath.Size = New-Object System.Drawing.Size(580,24)
    $scrollPanel.Controls.Add($txtPackagePath)

    $btnBrowsePackage = New-Object System.Windows.Forms.Button
    $btnBrowsePackage.Text = "Browse..."
    $btnBrowsePackage.Location = New-Object System.Drawing.Point(600,451)
    $btnBrowsePackage.Size = New-Object System.Drawing.Size(90,26)
    $scrollPanel.Controls.Add($btnBrowsePackage)

    $resolved = Resolve-AppPackagePath -AppName $AppName -Uncommon $Uncommon
    $txtPackagePath.Text = $resolved.Path
    $txtPackagePath.ForeColor = if ($resolved.Found) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::Firebrick }

    $btnBrowsePackage.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Intune package (*.intunewin)|*.intunewin|All files (*.*)|*.*"
        $ofd.InitialDirectory = $rootPath
        if ($ofd.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtPackagePath.Text = $ofd.FileName
            $txtPackagePath.ForeColor = [System.Drawing.Color]::Black
        }
    }.GetNewClosure())

    $lblInstall = New-Object System.Windows.Forms.Label
    $lblInstall.Text = "Install command"
    $lblInstall.Location = New-Object System.Drawing.Point(15,485)
    $lblInstall.AutoSize = $true
    $scrollPanel.Controls.Add($lblInstall)

    $txtInstall = New-Object System.Windows.Forms.TextBox
    $txtInstall.Location = New-Object System.Drawing.Point(15,504)
    $txtInstall.Size = New-Object System.Drawing.Size(675,46)
    $txtInstall.Multiline = $true
    $txtInstall.ScrollBars = "Vertical"
    $scrollPanel.Controls.Add($txtInstall)

    $lblUninstall = New-Object System.Windows.Forms.Label
    $lblUninstall.Text = "Uninstall command"
    $lblUninstall.Location = New-Object System.Drawing.Point(15,555)
    $lblUninstall.AutoSize = $true
    $scrollPanel.Controls.Add($lblUninstall)

    $txtUninstall = New-Object System.Windows.Forms.TextBox
    $txtUninstall.Location = New-Object System.Drawing.Point(15,574)
    $txtUninstall.Size = New-Object System.Drawing.Size(675,46)
    $txtUninstall.Multiline = $true
    $txtUninstall.ScrollBars = "Vertical"
    $scrollPanel.Controls.Add($txtUninstall)

    $lblDetection = New-Object System.Windows.Forms.Label
    $lblDetection.Text = "Detection method"
    $lblDetection.Location = New-Object System.Drawing.Point(15,568)
    $lblDetection.AutoSize = $true
    $dlg.Controls.Add($lblDetection)

    $cmbDetectionType = New-Object System.Windows.Forms.ComboBox
    $cmbDetectionType.Location = New-Object System.Drawing.Point(15,587)
    $cmbDetectionType.Size = New-Object System.Drawing.Size(260,24)
    $cmbDetectionType.DropDownStyle = "DropDownList"
    [void]$cmbDetectionType.Items.AddRange(@("PowerShell script","MSI product code","File or folder","Registry"))
    $cmbDetectionType.SelectedIndex = 0
    $dlg.Controls.Add($cmbDetectionType)

    # Shared by MSI/File/Registry's version/value comparison dropdowns -
    # confirmed against Microsoft's documented win32LobAppDetectionOperator
    # values, same list for all three detection types.
    $operatorMap = [ordered]@{
        "(any / not configured)"   = "notConfigured"
        "Equal to"                 = "equal"
        "Not equal to"             = "notEqual"
        "Greater than"             = "greaterThan"
        "Greater than or equal to" = "greaterThanOrEqual"
        "Less than"                = "lessThan"
        "Less than or equal to"    = "lessThanOrEqual"
    }

    $detPanelY = 615
    $detPanelH = 150

    # --- PowerShell script panel (default, matches previous behavior) ---
    $pnlDetScript = New-Object System.Windows.Forms.Panel
    $pnlDetScript.Location = New-Object System.Drawing.Point(15,$detPanelY)
    $pnlDetScript.Size = New-Object System.Drawing.Size(675,$detPanelH)
    $dlg.Controls.Add($pnlDetScript)

    $txtDetection = New-Object System.Windows.Forms.TextBox
    $txtDetection.Location = New-Object System.Drawing.Point(0,0)
    $txtDetection.Size = New-Object System.Drawing.Size(675,$detPanelH)
    $txtDetection.Multiline = $true
    $txtDetection.ScrollBars = "Vertical"
    $txtDetection.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $pnlDetScript.Controls.Add($txtDetection)

    # --- MSI product code panel ---
    $pnlDetMsi = New-Object System.Windows.Forms.Panel
    $pnlDetMsi.Location = New-Object System.Drawing.Point(15,$detPanelY)
    $pnlDetMsi.Size = New-Object System.Drawing.Size(675,$detPanelH)
    $dlg.Controls.Add($pnlDetMsi)

    $lblMsiCode = New-Object System.Windows.Forms.Label
    $lblMsiCode.Text = "MSI product code (GUID)"
    $lblMsiCode.Location = New-Object System.Drawing.Point(0,0)
    $lblMsiCode.AutoSize = $true
    $pnlDetMsi.Controls.Add($lblMsiCode)

    $txtMsiCode = New-Object System.Windows.Forms.TextBox
    $txtMsiCode.Location = New-Object System.Drawing.Point(0,19)
    $txtMsiCode.Size = New-Object System.Drawing.Size(675,24)
    $pnlDetMsi.Controls.Add($txtMsiCode)

    $lblMsiVer = New-Object System.Windows.Forms.Label
    $lblMsiVer.Text = "Version check (optional - leave as 'any' to skip)"
    $lblMsiVer.Location = New-Object System.Drawing.Point(0,51)
    $lblMsiVer.AutoSize = $true
    $pnlDetMsi.Controls.Add($lblMsiVer)

    $cmbMsiOperator = New-Object System.Windows.Forms.ComboBox
    $cmbMsiOperator.Location = New-Object System.Drawing.Point(0,70)
    $cmbMsiOperator.Size = New-Object System.Drawing.Size(280,24)
    $cmbMsiOperator.DropDownStyle = "DropDownList"
    [void]$cmbMsiOperator.Items.AddRange(@($operatorMap.Keys))
    $cmbMsiOperator.SelectedIndex = 0
    $pnlDetMsi.Controls.Add($cmbMsiOperator)

    $txtMsiVersion = New-Object System.Windows.Forms.TextBox
    $txtMsiVersion.Location = New-Object System.Drawing.Point(300,70)
    $txtMsiVersion.Size = New-Object System.Drawing.Size(290,24)
    $pnlDetMsi.Controls.Add($txtMsiVersion)

    # --- File or folder panel ---
    $pnlDetFile = New-Object System.Windows.Forms.Panel
    $pnlDetFile.Location = New-Object System.Drawing.Point(15,$detPanelY)
    $pnlDetFile.Size = New-Object System.Drawing.Size(675,$detPanelH)
    $dlg.Controls.Add($pnlDetFile)

    $lblFilePath = New-Object System.Windows.Forms.Label
    $lblFilePath.Text = "Folder path"
    $lblFilePath.Location = New-Object System.Drawing.Point(0,0)
    $lblFilePath.AutoSize = $true
    $pnlDetFile.Controls.Add($lblFilePath)

    $txtFilePath = New-Object System.Windows.Forms.TextBox
    $txtFilePath.Location = New-Object System.Drawing.Point(0,19)
    $txtFilePath.Size = New-Object System.Drawing.Size(430,24)
    $pnlDetFile.Controls.Add($txtFilePath)

    $chkFileCheck32 = New-Object System.Windows.Forms.CheckBox
    $chkFileCheck32.Text = "32-bit on 64-bit"
    $chkFileCheck32.Location = New-Object System.Drawing.Point(440,21)
    $chkFileCheck32.Size = New-Object System.Drawing.Size(150,22)
    $pnlDetFile.Controls.Add($chkFileCheck32)

    $lblFileName = New-Object System.Windows.Forms.Label
    $lblFileName.Text = "File or folder name"
    $lblFileName.Location = New-Object System.Drawing.Point(0,51)
    $lblFileName.AutoSize = $true
    $pnlDetFile.Controls.Add($lblFileName)

    $txtFileName = New-Object System.Windows.Forms.TextBox
    $txtFileName.Location = New-Object System.Drawing.Point(0,70)
    $txtFileName.Size = New-Object System.Drawing.Size(675,24)
    $pnlDetFile.Controls.Add($txtFileName)

    $lblFileDetType = New-Object System.Windows.Forms.Label
    $lblFileDetType.Text = "Detection type"
    $lblFileDetType.Location = New-Object System.Drawing.Point(0,102)
    $lblFileDetType.AutoSize = $true
    $pnlDetFile.Controls.Add($lblFileDetType)

    $lblFileOp = New-Object System.Windows.Forms.Label
    $lblFileOp.Text = "Operator (if comparing)"
    $lblFileOp.Location = New-Object System.Drawing.Point(200,102)
    $lblFileOp.AutoSize = $true
    $pnlDetFile.Controls.Add($lblFileOp)

    $lblFileVal = New-Object System.Windows.Forms.Label
    $lblFileVal.Text = "Value (if comparing)"
    $lblFileVal.Location = New-Object System.Drawing.Point(400,102)
    $lblFileVal.AutoSize = $true
    $pnlDetFile.Controls.Add($lblFileVal)

    $fileDetTypeMap = [ordered]@{
        "Exists"           = "exists"
        "Does not exist"   = "doesNotExist"
        "Modified date"    = "modifiedDate"
        "Created date"     = "createdDate"
        "Version"          = "version"
        "Size (MB)"        = "sizeInMB"
    }
    $cmbFileDetType = New-Object System.Windows.Forms.ComboBox
    $cmbFileDetType.Location = New-Object System.Drawing.Point(0,121)
    $cmbFileDetType.Size = New-Object System.Drawing.Size(190,24)
    $cmbFileDetType.DropDownStyle = "DropDownList"
    [void]$cmbFileDetType.Items.AddRange(@($fileDetTypeMap.Keys))
    $cmbFileDetType.SelectedIndex = 0
    $pnlDetFile.Controls.Add($cmbFileDetType)

    $cmbFileOperator = New-Object System.Windows.Forms.ComboBox
    $cmbFileOperator.Location = New-Object System.Drawing.Point(200,121)
    $cmbFileOperator.Size = New-Object System.Drawing.Size(190,24)
    $cmbFileOperator.DropDownStyle = "DropDownList"
    [void]$cmbFileOperator.Items.AddRange(@($operatorMap.Keys))
    $cmbFileOperator.SelectedIndex = 0
    $pnlDetFile.Controls.Add($cmbFileOperator)

    $txtFileDetValue = New-Object System.Windows.Forms.TextBox
    $txtFileDetValue.Location = New-Object System.Drawing.Point(400,121)
    $txtFileDetValue.Size = New-Object System.Drawing.Size(190,24)
    $pnlDetFile.Controls.Add($txtFileDetValue)

    # --- Registry panel ---
    $pnlDetReg = New-Object System.Windows.Forms.Panel
    $pnlDetReg.Location = New-Object System.Drawing.Point(15,$detPanelY)
    $pnlDetReg.Size = New-Object System.Drawing.Size(675,$detPanelH)
    $dlg.Controls.Add($pnlDetReg)

    $lblRegPath = New-Object System.Windows.Forms.Label
    $lblRegPath.Text = "Registry key path (e.g. HKEY_LOCAL_MACHINE\SOFTWARE\...)"
    $lblRegPath.Location = New-Object System.Drawing.Point(0,0)
    $lblRegPath.AutoSize = $true
    $pnlDetReg.Controls.Add($lblRegPath)

    $txtRegKeyPath = New-Object System.Windows.Forms.TextBox
    $txtRegKeyPath.Location = New-Object System.Drawing.Point(0,19)
    $txtRegKeyPath.Size = New-Object System.Drawing.Size(430,24)
    $pnlDetReg.Controls.Add($txtRegKeyPath)

    $chkRegCheck32 = New-Object System.Windows.Forms.CheckBox
    $chkRegCheck32.Text = "32-bit on 64-bit"
    $chkRegCheck32.Location = New-Object System.Drawing.Point(440,21)
    $chkRegCheck32.Size = New-Object System.Drawing.Size(150,22)
    $pnlDetReg.Controls.Add($chkRegCheck32)

    $lblRegValueName = New-Object System.Windows.Forms.Label
    $lblRegValueName.Text = "Value name (optional - blank checks the key itself)"
    $lblRegValueName.Location = New-Object System.Drawing.Point(0,51)
    $lblRegValueName.AutoSize = $true
    $pnlDetReg.Controls.Add($lblRegValueName)

    $txtRegValueName = New-Object System.Windows.Forms.TextBox
    $txtRegValueName.Location = New-Object System.Drawing.Point(0,70)
    $txtRegValueName.Size = New-Object System.Drawing.Size(675,24)
    $pnlDetReg.Controls.Add($txtRegValueName)

    $lblRegDetType = New-Object System.Windows.Forms.Label
    $lblRegDetType.Text = "Detection type"
    $lblRegDetType.Location = New-Object System.Drawing.Point(0,102)
    $lblRegDetType.AutoSize = $true
    $pnlDetReg.Controls.Add($lblRegDetType)

    $lblRegOp = New-Object System.Windows.Forms.Label
    $lblRegOp.Text = "Operator (if comparing)"
    $lblRegOp.Location = New-Object System.Drawing.Point(200,102)
    $lblRegOp.AutoSize = $true
    $pnlDetReg.Controls.Add($lblRegOp)

    $lblRegVal = New-Object System.Windows.Forms.Label
    $lblRegVal.Text = "Value (if comparing)"
    $lblRegVal.Location = New-Object System.Drawing.Point(400,102)
    $lblRegVal.AutoSize = $true
    $pnlDetReg.Controls.Add($lblRegVal)

    $regDetTypeMap = [ordered]@{
        "Exists"          = "exists"
        "Does not exist"  = "doesNotExist"
        "String"          = "string"
        "Integer"         = "integer"
        "Version"         = "version"
    }
    $cmbRegDetType = New-Object System.Windows.Forms.ComboBox
    $cmbRegDetType.Location = New-Object System.Drawing.Point(0,121)
    $cmbRegDetType.Size = New-Object System.Drawing.Size(190,24)
    $cmbRegDetType.DropDownStyle = "DropDownList"
    [void]$cmbRegDetType.Items.AddRange(@($regDetTypeMap.Keys))
    $cmbRegDetType.SelectedIndex = 0
    $pnlDetReg.Controls.Add($cmbRegDetType)

    $cmbRegOperator = New-Object System.Windows.Forms.ComboBox
    $cmbRegOperator.Location = New-Object System.Drawing.Point(200,121)
    $cmbRegOperator.Size = New-Object System.Drawing.Size(190,24)
    $cmbRegOperator.DropDownStyle = "DropDownList"
    [void]$cmbRegOperator.Items.AddRange(@($operatorMap.Keys))
    $cmbRegOperator.SelectedIndex = 0
    $pnlDetReg.Controls.Add($cmbRegOperator)

    $txtRegDetValue = New-Object System.Windows.Forms.TextBox
    $txtRegDetValue.Location = New-Object System.Drawing.Point(400,121)
    $txtRegDetValue.Size = New-Object System.Drawing.Size(190,24)
    $pnlDetReg.Controls.Add($txtRegDetValue)

    # Toggling .Visible on siblings stacked at identical coordinates inside
    # an AutoScroll panel doesn't reliably repaint in WinForms (confirmed by
    # testing - the panel toggled but rendered blank). Physically adding and
    # removing the panel from the Controls collection instead always forces
    # a full, correct layout+paint cycle, since that's ordinary control
    # attachment rather than relying on invalidation of an already-attached,
    # merely-hidden sibling.
    $detPanels = @($pnlDetScript, $pnlDetMsi, $pnlDetFile, $pnlDetReg)
    foreach ($p in $detPanels) { $dlg.Controls.Remove($p) }
    $UpdateDetPanel = {
        $sel = $cmbDetectionType.SelectedIndex
        foreach ($p in $detPanels) { $dlg.Controls.Remove($p) }
        if ($sel -ge 0 -and $sel -lt $detPanels.Count) {
            $dlg.Controls.Add($detPanels[$sel])
        }
    }.GetNewClosure()
    $cmbDetectionType.Add_SelectedIndexChanged({ & $UpdateDetPanel }.GetNewClosure())
    & $UpdateDetPanel

    if (-not $isDuplicate) {
        $txtInstall.Text = $defaults.installCommand
        $txtUninstall.Text = $defaults.uninstallCommand
        # .detectionRule is $null for an uncommon app (see
        # Get-DefaultAppMetadata) - there's genuinely no default to give it,
        # so $txtDetection is deliberately left however it already started
        # (blank) rather than risk assigning a WinForms TextBox.Text a $null
        # value, which throws.
        if ($defaults.detectionRule) { $txtDetection.Text = $defaults.detectionRule.Script_Content }
    }

    # --- Context / Architecture / Min OS, one row ---
    $lblContext = New-Object System.Windows.Forms.Label
    # Kept short deliberately - the full "(locked - set at creation only)"
    # wording used to run wide enough to overlap "Applicable architectures"
    # right next to it (the two labels share this one row). The full
    # explanation is still available, via the tooltip below.
    $lblContext.Text = if ($isDuplicate) { "Install context (locked)" } else { "Install context" }
    $lblContext.Location = New-Object System.Drawing.Point(15,631)
    $lblContext.AutoSize = $true
    $scrollPanel.Controls.Add($lblContext)

    $cmbContext = New-Object System.Windows.Forms.ComboBox
    $cmbContext.Location = New-Object System.Drawing.Point(15,650)
    $cmbContext.Size = New-Object System.Drawing.Size(180,24)
    $cmbContext.DropDownStyle = "DropDownList"
    [void]$cmbContext.Items.AddRange(@("System","User"))
    if (-not $isDuplicate) { $cmbContext.SelectedItem = $defaults.installContext }
    $scrollPanel.Controls.Add($cmbContext)

    $lblArch = New-Object System.Windows.Forms.Label
    $lblArch.Text = "Applicable architectures"
    $lblArch.Location = New-Object System.Drawing.Point(205,631)
    $lblArch.AutoSize = $true
    $scrollPanel.Controls.Add($lblArch)

    $chkArchX86 = New-Object System.Windows.Forms.CheckBox
    $chkArchX86.Text = "x86"
    $chkArchX86.Location = New-Object System.Drawing.Point(205,651)
    $chkArchX86.Size = New-Object System.Drawing.Size(48,22)
    $scrollPanel.Controls.Add($chkArchX86)

    $chkArchX64 = New-Object System.Windows.Forms.CheckBox
    $chkArchX64.Text = "x64"
    $chkArchX64.Location = New-Object System.Drawing.Point(261,651)
    $chkArchX64.Size = New-Object System.Drawing.Size(48,22)
    $scrollPanel.Controls.Add($chkArchX64)

    $chkArchArm64 = New-Object System.Windows.Forms.CheckBox
    $chkArchArm64.Text = "ARM64"
    $chkArchArm64.Location = New-Object System.Drawing.Point(317,651)
    $chkArchArm64.Size = New-Object System.Drawing.Size(65,22)
    $chkArchArm64.Checked = $false
    $scrollPanel.Controls.Add($chkArchArm64)

    # All three set together, from $defaults.architecture, now that all
    # three controls exist - same comma-split parsing already used
    # elsewhere in this function for the live-fetched value, applied here
    # to the DEFAULT value instead, so a future change to what
    # Get-DefaultAppMetadata defaults to (e.g. adding arm64) is reflected
    # here automatically instead of needing this checkbox logic updated
    # separately too.
    if (-not $isDuplicate -and $defaults.architecture) {
        $defaultArchList = @($defaults.architecture -split ',' | ForEach-Object { $_.Trim().ToLower() })
        $chkArchX86.Checked = $defaultArchList -contains "x86"
        $chkArchX64.Checked = $defaultArchList -contains "x64"
        $chkArchArm64.Checked = $defaultArchList -contains "arm64"
    }

    $lblMinOS = New-Object System.Windows.Forms.Label
    $lblMinOS.Text = "Minimum Windows"
    $lblMinOS.Location = New-Object System.Drawing.Point(415,631)
    $lblMinOS.AutoSize = $true
    $scrollPanel.Controls.Add($lblMinOS)

    $cmbMinOS = New-Object System.Windows.Forms.ComboBox
    $cmbMinOS.Location = New-Object System.Drawing.Point(415,650)
    $cmbMinOS.Size = New-Object System.Drawing.Size(190,24)
    $cmbMinOS.DropDownStyle = "DropDownList"
    # Values (not labels - see Get-FriendlyMinOsRelease for those) are the
    # full confirmed set for minimumSupportedWindowsRelease, sourced from
    # the IntuneWin32App PowerShell module's own ValidateSet - this used
    # to be a deliberately curated 6-value subset of the OLD
    # minimumSupportedOperatingSystem property (whose schema has no
    # Windows 11 values at all, full stop), before this dialog switched
    # to writing the new property - see the note next to
    # $Global:App.EmbeddedCreateAppScript's own $patchBody assignment for why.
    $minOsRawValues = @("W10_1607", "W10_1703", "W10_1709", "W10_1803", "W10_1809", "W10_1903", "W10_1909", "W10_2004", "W10_20H2", "W10_21H1", "W10_21H2", "W10_22H2", "W11_21H2", "W11_22H2")
    $minOsMap = [ordered]@{}
    foreach ($rawValue in $minOsRawValues) { $minOsMap[(Get-FriendlyMinOsRelease -RawValue $rawValue)] = $rawValue }
    [void]$cmbMinOS.Items.AddRange(@($minOsMap.Keys))
    if (-not $isDuplicate -and $defaults.minOSKey) {
        $defaultMinOsLabel = $minOsMap.Keys | Where-Object { $minOsMap[$_] -eq $defaults.minOSKey } | Select-Object -First 1
        if ($defaultMinOsLabel) { $cmbMinOS.SelectedItem = $defaultMinOsLabel }
    }
    $scrollPanel.Controls.Add($cmbMinOS)

    # $minOsMap above is a deliberately curated subset (only the values
    # this dialog itself ever sets) - Intune's real schema has more
    # possible values than that (e.g. v10_1703, v10_1803, v10_1903, set by
    # an app created outside this tool, in the Intune portal or another
    # tool entirely). The live-fetch OnComplete below fills this in
    # whenever that happens, so a value that's genuinely set in Intune but
    # not offered here doesn't just silently look unset.
    $lblMinOSStatus = New-Object System.Windows.Forms.Label
    $lblMinOSStatus.Text = ""
    $lblMinOSStatus.Location = New-Object System.Drawing.Point(415,676)
    $lblMinOSStatus.Size = New-Object System.Drawing.Size(220,30)
    $lblMinOSStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    $lblMinOSStatus.Font = New-Object System.Drawing.Font($lblMinOSStatus.Font.FontFamily, 7.5)
    $scrollPanel.Controls.Add($lblMinOSStatus)

    # Only install context is actually excluded here - confirmed rejected
    # by Graph specifically ("The 'RunAsAccount' property cannot be
    # patched for the 'Win32LobApp' type."). Architecture and Min OS were
    # PREVIOUSLY also locked here too, based on an unverified assumption
    # they'd behave the same way - that assumption was wrong, confirmed
    # otherwise directly against Microsoft's own PATCH documentation
    # example, an official Microsoft sample script, and the Intune
    # portal's own editable "Requirements"/"Detection rules" sections on
    # an existing app.
    if ($isDuplicate) {
        $cmbContext.Enabled = $false
        $contextLockedTip = New-Object System.Windows.Forms.ToolTip
        $contextLockedTip.SetToolTip($lblContext, "Set at creation only - cannot be changed afterward.")
        $contextLockedTip.SetToolTip($cmbContext, "Set at creation only - cannot be changed afterward.")
    }

    # A visual separator, not an actual collapsible section - this dialog's
    # fixed-coordinate layout would make a true collapse/expand risky (every
    # control below it would need dynamic repositioning). This still gives
    # new users a clear visual signal that everything below has sensible
    # defaults and rarely needs touching for a typical app, without the
    # complexity of actually hiding it.
    $lblAdvancedSeparator = New-Object System.Windows.Forms.Label
    $lblAdvancedSeparator.Text = "Advanced (usually fine to leave as-is)"
    $lblAdvancedSeparator.Location = New-Object System.Drawing.Point(15,690)
    $lblAdvancedSeparator.AutoSize = $true
    $lblAdvancedSeparator.ForeColor = [System.Drawing.Color]::Gray
    $lblAdvancedSeparator.Font = New-Object System.Drawing.Font($lblAdvancedSeparator.Font, [System.Drawing.FontStyle]::Italic)
    $scrollPanel.Controls.Add($lblAdvancedSeparator)

    # Its own full row, not squeezed beside the separator label - a plain
    # button crammed onto the same tight baseline as an italic label read
    # as an unlabeled bar rather than a clickable button. Only meaningful
    # for a Winget app - an Uncommon app has no shared Get-DefaultAppMetadata
    # template to reset back to (its install/uninstall/detection are
    # inherently app-specific, same reasoning as Test-AppIsUncommon
    # everywhere else in this app), so there's nothing for this button to
    # do for one and it stays hidden.
    $btnSetDefaults = New-Object System.Windows.Forms.Button
    $btnSetDefaults.Text = "Set default values..."
    $btnSetDefaults.Location = New-Object System.Drawing.Point(15,712)
    $btnSetDefaults.Size = New-Object System.Drawing.Size(220,28)
    $btnSetDefaults.Visible = (-not $Uncommon)
    $scrollPanel.Controls.Add($btnSetDefaults)
    $setDefaultsTip = New-Object System.Windows.Forms.ToolTip
    $setDefaultsTip.SetToolTip($btnSetDefaults, "Fills in the fields below with the computed Winget defaults - nothing is saved or deployed until you click Save/Deploy afterward.")

    $lblSetDefaultsHint = New-Object System.Windows.Forms.Label
    $lblSetDefaultsHint.Text = "Resets install/uninstall/detection, architecture, min OS, requirements, and return codes to this app's standard Winget defaults - free-text fields (description, publisher, notes, ...) are left alone."
    $lblSetDefaultsHint.Location = New-Object System.Drawing.Point(245,717)
    $lblSetDefaultsHint.Size = New-Object System.Drawing.Size(445,40)
    $lblSetDefaultsHint.ForeColor = [System.Drawing.Color]::Gray
    $lblSetDefaultsHint.Font = New-Object System.Drawing.Font($lblSetDefaultsHint.Font.FontFamily, 7.5)
    $lblSetDefaultsHint.Visible = (-not $Uncommon)
    $scrollPanel.Controls.Add($lblSetDefaultsHint)

    # --- Dependencies ---
    $lblDeps = New-Object System.Windows.Forms.Label
    $lblDeps.Text = "Dependencies (undeployed apps shown too - resolved by name at actual deploy time)"
    $lblDeps.Location = New-Object System.Drawing.Point(15,760)
    $lblDeps.AutoSize = $true
    $scrollPanel.Controls.Add($lblDeps)

    $clbDeps = New-Object System.Windows.Forms.CheckedListBox
    $clbDeps.Location = New-Object System.Drawing.Point(15,779)
    $clbDeps.Size = New-Object System.Drawing.Size(675,85)
    $clbDeps.CheckOnClick = $true
    # Undeployed apps (no App ID yet) are now included, not just ones
    # already in Intune - Batch Deploy's own ordering logic already
    # resolves dependencies by NAME at actual deploy time specifically so
    # one undeployed app can depend on another undeployed one, but this
    # picker was still filtering those out, an artificial gap rather than
    # a real one. Immediate deploy (the Create/Update button) still needs
    # a REAL App ID right now, though - that path can't defer resolution
    # the way Batch Deploy can, so it validates and blocks separately,
    # below, rather than silently sending Graph something it can't use.
    $depCandidates = @($Global:App.Apps | Where-Object { $_.appName -ne $AppName })
    $depIdByLabel = @{}
    $depNameByLabel = @{}
    foreach ($d in ($depCandidates | Sort-Object appName)) {
        $label = if ($d.appId) { $d.appName } else { "$($d.appName)  [not deployed yet]" }
        $idx = $clbDeps.Items.Add($label)
        $depIdByLabel[$label] = $d.appId
        $depNameByLabel[$label] = $d.appName
        if ($d.appName -eq "Winget AutoUpdate") { $clbDeps.SetItemChecked($idx, $true) }
    }
    $scrollPanel.Controls.Add($clbDeps)

    # --- Requirements (0 = not required, matching the portal's own "No X
    # required" wording for an unset value) ---
    $lblReqs = New-Object System.Windows.Forms.Label
    $lblReqs.Text = "Requirements (0 = not required)"
    $lblReqs.Location = New-Object System.Drawing.Point(15,873)
    $lblReqs.AutoSize = $true
    $scrollPanel.Controls.Add($lblReqs)

    $lblDiskSpace = New-Object System.Windows.Forms.Label
    $lblDiskSpace.Text = "Disk space (MB)"
    $lblDiskSpace.Location = New-Object System.Drawing.Point(15,894)
    $lblDiskSpace.AutoSize = $true
    $scrollPanel.Controls.Add($lblDiskSpace)
    $txtDiskSpace = New-Object System.Windows.Forms.TextBox
    $txtDiskSpace.Location = New-Object System.Drawing.Point(15,911)
    $txtDiskSpace.Size = New-Object System.Drawing.Size(130,23)
    $txtDiskSpace.Text = [string]$defaults.minDiskSpaceMB
    $scrollPanel.Controls.Add($txtDiskSpace)

    $lblMemory = New-Object System.Windows.Forms.Label
    $lblMemory.Text = "Memory (MB)"
    $lblMemory.Location = New-Object System.Drawing.Point(160,894)
    $lblMemory.AutoSize = $true
    $scrollPanel.Controls.Add($lblMemory)
    $txtMemory = New-Object System.Windows.Forms.TextBox
    $txtMemory.Location = New-Object System.Drawing.Point(160,911)
    $txtMemory.Size = New-Object System.Drawing.Size(130,23)
    $txtMemory.Text = [string]$defaults.minMemoryMB
    $scrollPanel.Controls.Add($txtMemory)

    $lblProcessors = New-Object System.Windows.Forms.Label
    $lblProcessors.Text = "Min. processors"
    $lblProcessors.Location = New-Object System.Drawing.Point(305,894)
    $lblProcessors.AutoSize = $true
    $scrollPanel.Controls.Add($lblProcessors)
    $txtProcessors = New-Object System.Windows.Forms.TextBox
    $txtProcessors.Location = New-Object System.Drawing.Point(305,911)
    $txtProcessors.Size = New-Object System.Drawing.Size(130,23)
    $txtProcessors.Text = [string]$defaults.minProcessors
    $scrollPanel.Controls.Add($txtProcessors)

    $lblCpuSpeed = New-Object System.Windows.Forms.Label
    $lblCpuSpeed.Text = "Min. CPU speed (MHz)"
    $lblCpuSpeed.Location = New-Object System.Drawing.Point(450,894)
    $lblCpuSpeed.AutoSize = $true
    $scrollPanel.Controls.Add($lblCpuSpeed)
    $txtCpuSpeed = New-Object System.Windows.Forms.TextBox
    $txtCpuSpeed.Location = New-Object System.Drawing.Point(450,911)
    $txtCpuSpeed.Size = New-Object System.Drawing.Size(130,23)
    $txtCpuSpeed.Text = [string]$defaults.minCpuSpeedMHz
    $scrollPanel.Controls.Add($txtCpuSpeed)

    # --- Install experience extras ---
    $lblInstallTime = New-Object System.Windows.Forms.Label
    $lblInstallTime.Text = "Install time required (mins)"
    $lblInstallTime.Location = New-Object System.Drawing.Point(15,947)
    $lblInstallTime.AutoSize = $true
    $scrollPanel.Controls.Add($lblInstallTime)
    $txtInstallTime = New-Object System.Windows.Forms.TextBox
    $txtInstallTime.Location = New-Object System.Drawing.Point(15,964)
    $txtInstallTime.Size = New-Object System.Drawing.Size(130,23)
    $txtInstallTime.Text = [string]$defaults.installTimeMinutes
    $scrollPanel.Controls.Add($txtInstallTime)

    $lblRestartBehavior = New-Object System.Windows.Forms.Label
    $lblRestartBehavior.Text = "Device restart behavior"
    $lblRestartBehavior.Location = New-Object System.Drawing.Point(160,947)
    $lblRestartBehavior.AutoSize = $true
    $scrollPanel.Controls.Add($lblRestartBehavior)
    $cmbRestartBehavior = New-Object System.Windows.Forms.ComboBox
    $cmbRestartBehavior.Location = New-Object System.Drawing.Point(160,964)
    $cmbRestartBehavior.Size = New-Object System.Drawing.Size(350,23)
    $cmbRestartBehavior.DropDownStyle = "DropDownList"
    # Display labels are the exact wording the Intune portal's own
    # "Device restart behavior" dropdown uses (confirmed directly against
    # a live screenshot of it) - the enum VALUES on the right were already
    # correct (confirmed against Microsoft's resource docs separately),
    # only the LABELS shown here were off: "No specific action" was
    # previously mapped to basedOnReturnCode, but the portal actually uses
    # that exact wording for "allow" instead - "Determine behavior based
    # on return codes" is the portal's real label for basedOnReturnCode.
    $restartBehaviorMap = [ordered]@{
        "Determine behavior based on return codes"      = "basedOnReturnCode"
        "No specific action"                            = "allow"
        "App install may force a device restart"        = "suppress"
        "Intune will force a mandatory device restart"  = "force"
    }
    foreach ($k in $restartBehaviorMap.Keys) { [void]$cmbRestartBehavior.Items.Add($k) }
    $defaultRestartLabel = $restartBehaviorMap.Keys | Where-Object { $restartBehaviorMap[$_] -eq $defaults.deviceRestartBehavior } | Select-Object -First 1
    $cmbRestartBehavior.SelectedItem = if ($defaultRestartLabel) { $defaultRestartLabel } else { "Determine behavior based on return codes" }
    $scrollPanel.Controls.Add($cmbRestartBehavior)

    $chkAllowUninstall = New-Object System.Windows.Forms.CheckBox
    $chkAllowUninstall.Text = "Allow available uninstall"
    $chkAllowUninstall.Location = New-Object System.Drawing.Point(525,966)
    $chkAllowUninstall.AutoSize = $true
    $chkAllowUninstall.Checked = [bool]$defaults.allowAvailableUninstall
    $scrollPanel.Controls.Add($chkAllowUninstall)

    # --- Return codes ---
    $lblReturnCodes = New-Object System.Windows.Forms.Label
    $lblReturnCodes.Text = "Return codes"
    $lblReturnCodes.Location = New-Object System.Drawing.Point(15,1000)
    $lblReturnCodes.AutoSize = $true
    $scrollPanel.Controls.Add($lblReturnCodes)

    $grdReturnCodes = New-Object System.Windows.Forms.DataGridView
    $grdReturnCodes.Location = New-Object System.Drawing.Point(15,1019)
    $grdReturnCodes.Size = New-Object System.Drawing.Size(460,110)
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
    # Exact win32LobAppReturnCode "type" enum values, confirmed against the
    # same docs as the rest of this section.
    [void]$colType.Items.AddRange(@("success", "softReboot", "hardReboot", "retry", "failed"))
    [void]$grdReturnCodes.Columns.Add($colType)
    $scrollPanel.Controls.Add($grdReturnCodes)

    $btnAddReturnCode = New-Object System.Windows.Forms.Button
    $btnAddReturnCode.Text = "Add row"
    $btnAddReturnCode.Location = New-Object System.Drawing.Point(485,1019)
    $btnAddReturnCode.Size = New-Object System.Drawing.Size(120,26)
    $scrollPanel.Controls.Add($btnAddReturnCode)
    $btnAddReturnCode.Add_Click({
        $rowIdx = $grdReturnCodes.Rows.Add()
        $grdReturnCodes.Rows[$rowIdx].Cells["Type"].Value = "success"
    }.GetNewClosure())

    $btnRemoveReturnCode = New-Object System.Windows.Forms.Button
    $btnRemoveReturnCode.Text = "Remove row"
    $btnRemoveReturnCode.Location = New-Object System.Drawing.Point(485,1049)
    $btnRemoveReturnCode.Size = New-Object System.Drawing.Size(120,26)
    $scrollPanel.Controls.Add($btnRemoveReturnCode)
    $btnRemoveReturnCode.Add_Click({
        if ($grdReturnCodes.CurrentRow) { $grdReturnCodes.Rows.RemoveAt($grdReturnCodes.CurrentRow.Index) }
    }.GetNewClosure())

    # Standard defaults - the same fixed set Get-DefaultAppMetadata also
    # uses for Batch Deploy, shown here as editable, pre-filled rows
    # instead of being invisible and fixed.
    foreach ($rc in @($defaults.returnCodes)) {
        $rowIdx = $grdReturnCodes.Rows.Add()
        $grdReturnCodes.Rows[$rowIdx].Cells["Code"].Value = [string]$rc.returnCode
        $grdReturnCodes.Rows[$rowIdx].Cells["Type"].Value = $rc.type
    }

    # Requirements, return codes, and install time/restart behavior/
    # allow-uninstall are NOT locked (unlike Install context above) -
    # confirmed patchable on an existing app, correcting an earlier,
    # unverified assumption that they'd behave the same way as
    # runAsAccount. See the note on Install context above for the
    # confirming evidence.

    # Compares the form's CURRENT values against Get-DefaultAppMetadata's
    # computed defaults (the exact same defaults this dialog itself
    # pre-fills a brand-new Winget app with). Deliberately scoped to
    # install-mechanics fields only (install/uninstall/detection,
    # architecture, min OS, requirements, restart behavior, allow-
    # uninstall, return codes, dependencies) - NOT description/publisher/
    # owner/developer/URLs/notes, which are free-text metadata neither this
    # function nor "Set default values..." has any business touching.
    #
    # A scriptblock variable, NOT a nested `function` - confirmed live
    # (real crash: "Update-CustomFieldHighlights is not recognized...")
    # that a plain nested function defined here is NOT reliably callable
    # from inside the doubly-nested closure the live-Intune auto-fetch's
    # own -OnComplete runs in (Add_Shown's own .GetNewClosure(), then
    # Start-AppMetadataFetch's own -OnComplete .GetNewClosure() nested
    # inside it) - unlike a plain VARIABLE holding a scriptblock, which
    # this file's "fresh alias" convention already handles correctly
    # everywhere else. Needs the same fresh-alias care at each call site
    # this note used to claim it didn't. Used both by "Set default
    # values..." itself (below) and by $updateCustomFieldHighlights, so
    # the two can never drift apart on what counts as "differs from
    # default".
    $getCurrentVsDefaultChanges = {
        $currentDetection = switch ($cmbDetectionType.SelectedIndex) {
            0 { if ($txtDetection.Text.Trim()) { [pscustomobject]@{ Type = "Script"; Script_Content = $txtDetection.Text } } else { $null } }
            default { [pscustomobject]@{ Type = "Other" } }
        }
        $currentArches = New-Object System.Collections.Generic.List[string]
        if ($chkArchX86.Checked)   { $currentArches.Add("x86") }
        if ($chkArchX64.Checked)   { $currentArches.Add("x64") }
        if ($chkArchArm64.Checked) { $currentArches.Add("arm64") }
        $currentDepNames = New-Object System.Collections.Generic.List[string]
        foreach ($checkedLabel in $clbDeps.CheckedItems) {
            if ($depNameByLabel.ContainsKey([string]$checkedLabel)) { $currentDepNames.Add($depNameByLabel[[string]$checkedLabel]) }
        }
        $currentReturnCodes = New-Object System.Collections.Generic.List[object]
        foreach ($rcRow in $grdReturnCodes.Rows) {
            if ($rcRow.IsNewRow) { continue }
            $rcCode = [string]$rcRow.Cells["Code"].Value
            $rcType = [string]$rcRow.Cells["Type"].Value
            if (-not $rcCode -and -not $rcType) { continue }
            $parsedRc = 0
            [void][int]::TryParse($rcCode.Trim(), [ref]$parsedRc)
            $currentReturnCodes.Add([pscustomobject]@{ returnCode = $parsedRc; type = $rcType })
        }
        $currentMinOsKey = if ($cmbMinOS.SelectedItem) { $minOsMap[[string]$cmbMinOS.SelectedItem] } else { "" }
        $currentRestartBehavior = if ($cmbRestartBehavior.SelectedItem) { $restartBehaviorMap[[string]$cmbRestartBehavior.SelectedItem] } else { "" }
        $parsedDisk = 0; [void][int]::TryParse($txtDiskSpace.Text.Trim(), [ref]$parsedDisk)
        $parsedMem = 0; [void][int]::TryParse($txtMemory.Text.Trim(), [ref]$parsedMem)
        $parsedProc = 0; [void][int]::TryParse($txtProcessors.Text.Trim(), [ref]$parsedProc)
        $parsedCpu = 0; [void][int]::TryParse($txtCpuSpeed.Text.Trim(), [ref]$parsedCpu)
        $parsedInstallTime = 0; [void][int]::TryParse($txtInstallTime.Text.Trim(), [ref]$parsedInstallTime)

        # Truncates a one-line value for the confirmation list below - the
        # full current value is already visible on the form itself right
        # above this button, so this only needs to say ENOUGH to recognize
        # which setting is which, not reproduce it in full.
        function Get-ShortDisplayValue([string]$Text, [int]$MaxLen = 70) {
            if ([string]::IsNullOrWhiteSpace($Text)) { return "(blank)" }
            $oneLine = ($Text -replace '\r?\n', ' ').Trim()
            if ($oneLine.Length -gt $MaxLen) { return $oneLine.Substring(0, $MaxLen) + "..." }
            return $oneLine
        }

        # {Label; Current; Default; Display} rows - built by hand rather
        # than through Get-CatalogMetadataFieldDiffs, which compares a
        # different (and wider, description/publisher/notes included)
        # field set than this button intentionally touches. Display is a
        # short, human-readable one-liner for the confirmation dialog -
        # multi-line/large values (detection script, return codes) get a
        # plain-English description there instead of a raw dump, which is
        # unreadable at any dialog size and duplicates what's already
        # visible on the form itself.
        $changeRows = New-Object System.Collections.Generic.List[object]
        if ($txtInstall.Text -ne $defaults.installCommand) {
            $changeRows.Add([pscustomobject]@{ Label = "Install command"; Display = "Install command: $(Get-ShortDisplayValue $txtInstall.Text)  ->  $(Get-ShortDisplayValue $defaults.installCommand)" })
        }
        if ($txtUninstall.Text -ne $defaults.uninstallCommand) {
            $changeRows.Add([pscustomobject]@{ Label = "Uninstall command"; Display = "Uninstall command: $(Get-ShortDisplayValue $txtUninstall.Text)  ->  $(Get-ShortDisplayValue $defaults.uninstallCommand)" })
        }
        $defaultDetSummary = if ($defaults.detectionRule) { ConvertTo-DetectionRuleJson -DetectionRule $defaults.detectionRule -IndentLevel 0 } else { "" }
        $currentDetSummary = if ($currentDetection -and $currentDetection.Type -eq "Script") { ConvertTo-DetectionRuleJson -DetectionRule $currentDetection -IndentLevel 0 } else { "(non-script detection method)" }
        if ($cmbDetectionType.SelectedIndex -ne 0 -or $currentDetSummary -ne $defaultDetSummary) {
            $detDisplay = if ($cmbDetectionType.SelectedIndex -ne 0) { "Detection rule: switches from a non-script detection method back to the standard Winget detection script" } else { "Detection rule: replaced with the standard Winget detection script" }
            $changeRows.Add([pscustomobject]@{ Label = "Detection rule"; Display = $detDisplay })
        }
        $currentArchText = ($currentArches -join ",")
        if ($currentArchText -ne $defaults.architecture) {
            $archDisplay = if ($currentArchText) { $currentArchText } else { "(none selected)" }
            $changeRows.Add([pscustomobject]@{ Label = "Architecture"; Display = "Architecture: $archDisplay  ->  $($defaults.architecture)" })
        }
        if ($currentMinOsKey -ne $defaults.minOSKey) {
            $curOsLabel = if ($currentMinOsKey) { Get-FriendlyMinOsRelease -RawValue $currentMinOsKey } else { "(none selected)" }
            $defOsLabel = Get-FriendlyMinOsRelease -RawValue $defaults.minOSKey
            $changeRows.Add([pscustomobject]@{ Label = "Minimum OS"; Display = "Minimum OS: $curOsLabel  ->  $defOsLabel" })
        }
        $currentDepText = (@($currentDepNames) | Sort-Object) -join ", "
        $defaultDepText = (@($defaults.dependencies) | Sort-Object) -join ", "
        if ($currentDepText -ne $defaultDepText) {
            $curDepDisplay = if ($currentDepText) { $currentDepText } else { "(none)" }
            $defDepDisplay = if ($defaultDepText) { $defaultDepText } else { "(none)" }
            $changeRows.Add([pscustomobject]@{ Label = "Dependencies"; Display = "Dependencies: $curDepDisplay  ->  $defDepDisplay" })
        }
        if ($parsedDisk -ne $defaults.minDiskSpaceMB) {
            $changeRows.Add([pscustomobject]@{ Label = "Disk space (MB)"; Display = "Disk space (MB): $parsedDisk  ->  $($defaults.minDiskSpaceMB)" })
        }
        if ($parsedMem -ne $defaults.minMemoryMB) {
            $changeRows.Add([pscustomobject]@{ Label = "Memory (MB)"; Display = "Memory (MB): $parsedMem  ->  $($defaults.minMemoryMB)" })
        }
        if ($parsedProc -ne $defaults.minProcessors) {
            $changeRows.Add([pscustomobject]@{ Label = "Min. processors"; Display = "Min. processors: $parsedProc  ->  $($defaults.minProcessors)" })
        }
        if ($parsedCpu -ne $defaults.minCpuSpeedMHz) {
            $changeRows.Add([pscustomobject]@{ Label = "Min. CPU speed (MHz)"; Display = "Min. CPU speed (MHz): $parsedCpu  ->  $($defaults.minCpuSpeedMHz)" })
        }
        if ($parsedInstallTime -ne $defaults.installTimeMinutes) {
            $changeRows.Add([pscustomobject]@{ Label = "Install time (mins)"; Display = "Install time (mins): $parsedInstallTime  ->  $($defaults.installTimeMinutes)" })
        }
        if ($currentRestartBehavior -ne $defaults.deviceRestartBehavior) {
            $curRbLabel = if ($currentRestartBehavior) { ($restartBehaviorMap.Keys | Where-Object { $restartBehaviorMap[$_] -eq $currentRestartBehavior } | Select-Object -First 1) } else { $null }
            $defRbLabel = $restartBehaviorMap.Keys | Where-Object { $restartBehaviorMap[$_] -eq $defaults.deviceRestartBehavior } | Select-Object -First 1
            $changeRows.Add([pscustomobject]@{ Label = "Device restart behavior"; Display = "Device restart behavior: $(if ($curRbLabel) { $curRbLabel } else { '(none selected)' })  ->  $defRbLabel" })
        }
        if ($chkAllowUninstall.Checked -ne [bool]$defaults.allowAvailableUninstall) {
            $changeRows.Add([pscustomobject]@{ Label = "Allow available uninstall"; Display = "Allow available uninstall: $($chkAllowUninstall.Checked)  ->  $([bool]$defaults.allowAvailableUninstall)" })
        }
        # Piped straight into ConvertTo-Json/ForEach-Object below, never
        # wrapped in @(...) first - $currentReturnCodes is a
        # System.Collections.Generic.List[object] (built via New-Object a
        # few lines up), and PowerShell's @() array-subexpression operator
        # throws "Argument types do not match" (a real .NET/PowerShell
        # binder bug, not a logic error here) when applied directly to a
        # List[object] instance. Piping it through a cmdlet first sidesteps
        # the buggy code path entirely and behaves identically for this
        # purpose. This is exactly the crash reported live ("Could not load
        # current metadata (Argument types do not match ... currentReturnCodes)
        # | ConvertTo-Json ...") the first time an app with default return
        # codes had its live metadata re-fetched.
        $currentRcSummary = if ($currentReturnCodes.Count -gt 0) { ($currentReturnCodes | ConvertTo-Json -Compress -Depth 5) } else { "" }
        $defaultRcSummary = if (@($defaults.returnCodes).Count -gt 0) { (@($defaults.returnCodes) | ConvertTo-Json -Compress -Depth 5) } else { "" }
        if ($currentRcSummary -ne $defaultRcSummary) {
            # Same reasoning as above - no @(...) around $rcList, since this
            # is called with $currentReturnCodes (a List[object]) as well as
            # $defaults.returnCodes (a plain array); .Count and a plain pipe
            # both work identically for either one without it.
            $rcToText = { param($rcList) if ($rcList.Count -eq 0) { "(none)" } else { ($rcList | ForEach-Object { "$($_.returnCode) ($($_.type))" }) -join ", " } }
            $changeRows.Add([pscustomobject]@{ Label = "Return codes"; Display = "Return codes: $(& $rcToText $currentReturnCodes)  ->  $(& $rcToText $defaults.returnCodes)" })
        }

        return $changeRows
    }.GetNewClosure()

    # Highlights each field's LABEL in bold DarkOrange when its current
    # value differs from the computed Winget default, so "which settings
    # are custom here" is visible at a glance without clicking "Set
    # default values..." - that button still exists for actually
    # resetting them; this just answers "which ones, right now" passively.
    # Only meaningful for a Winget app - see $getCurrentVsDefaultChanges's
    # own comment on why an Uncommon app has nothing to compare against.
    # Not live/reactive (doesn't re-run on every keystroke) - called once
    # after the form settles (pre-fill, and again after the live-Intune
    # auto-fetch for an existing app), which is enough to answer "what's
    # custom on this app" without wiring change-tracking onto every one of
    # these controls. A scriptblock variable, same reasoning as
    # $getCurrentVsDefaultChanges above - references that one directly
    # (safe here, both are defined at this same top level, no extra
    # closure nesting between them).
    $updateCustomFieldHighlights = {
        if ($Uncommon) { return }
        $customLabels = @((& $getCurrentVsDefaultChanges) | ForEach-Object { $_.Label })
        $fieldControls = @{
            "Install command"          = $lblInstall
            "Uninstall command"        = $lblUninstall
            "Detection rule"           = $lblDetection
            "Architecture"             = $lblArch
            "Minimum OS"               = $lblMinOS
            "Dependencies"             = $lblDeps
            "Disk space (MB)"          = $lblDiskSpace
            "Memory (MB)"              = $lblMemory
            "Min. processors"          = $lblProcessors
            "Min. CPU speed (MHz)"     = $lblCpuSpeed
            "Install time (mins)"      = $lblInstallTime
            "Device restart behavior"  = $lblRestartBehavior
            "Allow available uninstall" = $chkAllowUninstall
            "Return codes"             = $lblReturnCodes
        }
        foreach ($fieldLabel in $fieldControls.Keys) {
            $ctrl = $fieldControls[$fieldLabel]
            if ($customLabels -contains $fieldLabel) {
                $ctrl.ForeColor = [System.Drawing.Color]::DarkOrange
                $ctrl.Font = New-Object System.Drawing.Font($ctrl.Font, ($ctrl.Font.Style -bor [System.Drawing.FontStyle]::Bold))
            }
            else {
                $ctrl.ForeColor = [System.Drawing.SystemColors]::ControlText
                $ctrl.Font = New-Object System.Drawing.Font($ctrl.Font, ($ctrl.Font.Style -band (-bnot [System.Drawing.FontStyle]::Bold)))
            }
        }
    }.GetNewClosure()

    # Applies a reviewed "keep my local value for these fields" choice
    # (from Show-MetadataDriftDialog) to the form - factored out into its
    # own scriptblock variable, same reasoning/pattern as
    # $getCurrentVsDefaultChanges/$updateCustomFieldHighlights above, so
    # $btnShowDiff's own click handler further down can re-run the exact
    # same field-by-field logic the live-Intune auto-fetch already uses,
    # without duplicating it. Takes $LocalSnapshot as a parameter rather
    # than closing over $localSnapshot directly - the auto-fetch's own
    # call site is two closure levels deep (inside Start-AppMetadataFetch's
    # -OnComplete) and needs a fresh alias for its own local snapshot
    # anyway, so passing it explicitly here means this scriptblock doesn't
    # also need a *Ref alias just for that one value.
    $applyKeepLocalFields = {
        param($KeepLocalFields, $LocalSnapshot)

        if ($KeepLocalFields -contains "Description")          { $txtDesc.Text = $LocalSnapshot.Description }
        if ($KeepLocalFields -contains "Publisher")             { $txtPublisher.Text = $LocalSnapshot.Publisher }
        if ($KeepLocalFields -contains "Owner")                 { $txtOwner.Text = $LocalSnapshot.Owner }
        if ($KeepLocalFields -contains "Developer")             { $txtDeveloper.Text = $LocalSnapshot.Developer }
        if ($KeepLocalFields -contains "Information URL")       { $txtInfoUrl.Text = $LocalSnapshot.InformationUrl }
        if ($KeepLocalFields -contains "Privacy URL")           { $txtPrivacyUrl.Text = $LocalSnapshot.PrivacyUrl }
        if ($KeepLocalFields -contains "Notes")                 { $txtNotes.Text = $LocalSnapshot.Notes }
        if ($KeepLocalFields -contains "Install command")       { $txtInstall.Text = $LocalSnapshot.InstallCommand }
        if ($KeepLocalFields -contains "Uninstall command")     { $txtUninstall.Text = $LocalSnapshot.UninstallCommand }
        if ($KeepLocalFields -contains "Architecture") {
            $localArchList = @([string]$LocalSnapshot.Architecture -split ',' | ForEach-Object { $_.Trim().ToLower() })
            $chkArchX86.Checked = $localArchList -contains "x86"
            $chkArchX64.Checked = $localArchList -contains "x64"
            $chkArchArm64.Checked = $localArchList -contains "arm64"
        }
        if ($KeepLocalFields -contains "Detection rule" -and $LocalSnapshot.DetectionRule) {
            $localDetRule = $LocalSnapshot.DetectionRule
            switch ($localDetRule.Type) {
                "Script" {
                    $cmbDetectionType.SelectedIndex = 0
                    if ($localDetRule.Script_Content) { $txtDetection.Text = $localDetRule.Script_Content }
                }
                "Msi" {
                    $cmbDetectionType.SelectedIndex = 1
                    $txtMsiCode.Text = $localDetRule.Msi_ProductCode
                    $opKey = $operatorMap.Keys | Where-Object { $operatorMap[$_] -eq $localDetRule.Msi_VersionOperator } | Select-Object -First 1
                    if ($opKey) { $cmbMsiOperator.SelectedItem = $opKey }
                    $txtMsiVersion.Text = $localDetRule.Msi_Version
                }
                "File" {
                    $cmbDetectionType.SelectedIndex = 2
                    $txtFilePath.Text = $localDetRule.File_Path
                    $txtFileName.Text = $localDetRule.File_Name
                    $chkFileCheck32.Checked = [bool]$localDetRule.File_Check32Bit
                    $dtKey = $fileDetTypeMap.Keys | Where-Object { $fileDetTypeMap[$_] -eq $localDetRule.File_DetectionType } | Select-Object -First 1
                    if ($dtKey) { $cmbFileDetType.SelectedItem = $dtKey }
                    $opKey = $operatorMap.Keys | Where-Object { $operatorMap[$_] -eq $localDetRule.File_Operator } | Select-Object -First 1
                    if ($opKey) { $cmbFileOperator.SelectedItem = $opKey }
                    $txtFileDetValue.Text = $localDetRule.File_DetectionValue
                }
                "Registry" {
                    $cmbDetectionType.SelectedIndex = 3
                    $txtRegKeyPath.Text = $localDetRule.Reg_KeyPath
                    $txtRegValueName.Text = $localDetRule.Reg_ValueName
                    $chkRegCheck32.Checked = [bool]$localDetRule.Reg_Check32Bit
                    $dtKey = $regDetTypeMap.Keys | Where-Object { $regDetTypeMap[$_] -eq $localDetRule.Reg_DetectionType } | Select-Object -First 1
                    if ($dtKey) { $cmbRegDetType.SelectedItem = $dtKey }
                    $opKey = $operatorMap.Keys | Where-Object { $operatorMap[$_] -eq $localDetRule.Reg_Operator } | Select-Object -First 1
                    if ($opKey) { $cmbRegOperator.SelectedItem = $opKey }
                    $txtRegDetValue.Text = $localDetRule.Reg_DetectionValue
                }
            }
        }
        if ($KeepLocalFields -contains "Disk space requirement")        { $txtDiskSpace.Text = [string]$LocalSnapshot.MinDiskSpaceMB }
        if ($KeepLocalFields -contains "Memory requirement")            { $txtMemory.Text = [string]$LocalSnapshot.MinMemoryMB }
        if ($KeepLocalFields -contains "Min. processors requirement")   { $txtProcessors.Text = [string]$LocalSnapshot.MinProcessors }
        if ($KeepLocalFields -contains "Min. CPU speed requirement")    { $txtCpuSpeed.Text = [string]$LocalSnapshot.MinCpuSpeedMHz }
        if ($KeepLocalFields -contains "Install time required")         { $txtInstallTime.Text = [string]$LocalSnapshot.InstallTimeMinutes }
        if ($KeepLocalFields -contains "Device restart behavior") {
            $rbKeyLocal = $restartBehaviorMap.Keys | Where-Object { $restartBehaviorMap[$_] -eq $LocalSnapshot.DeviceRestartBehavior } | Select-Object -First 1
            if ($rbKeyLocal) { $cmbRestartBehavior.SelectedItem = $rbKeyLocal }
        }
        if ($KeepLocalFields -contains "Allow available uninstall") { $chkAllowUninstall.Checked = [bool]$LocalSnapshot.AllowAvailableUninstall }
        if ($KeepLocalFields -contains "Return codes" -and $LocalSnapshot.ReturnCodes) {
            $grdReturnCodes.Rows.Clear()
            foreach ($rc in @($LocalSnapshot.ReturnCodes)) {
                $rcRowIdxLocal = $grdReturnCodes.Rows.Add()
                $grdReturnCodes.Rows[$rcRowIdxLocal].Cells["Code"].Value = [string]$rc.returnCode
                $grdReturnCodes.Rows[$rcRowIdxLocal].Cells["Type"].Value = [string]$rc.type
            }
        }
        if ($KeepLocalFields -contains "Dependencies") {
            for ($ci = 0; $ci -lt $clbDeps.Items.Count; $ci++) { $clbDeps.SetItemChecked($ci, $false) }
            for ($ci = 0; $ci -lt $clbDeps.Items.Count; $ci++) {
                $itemLabel = [string]$clbDeps.Items[$ci]
                if ($depNameByLabel.ContainsKey($itemLabel) -and (@($LocalSnapshot.Dependencies) -contains $depNameByLabel[$itemLabel])) {
                    $clbDeps.SetItemChecked($ci, $true)
                }
            }
        }
        $lblCreateStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblCreateStatus.Text = "Kept your local value for: $($KeepLocalFields -join ', ')."
        & $updateCustomFieldHighlights
    }.GetNewClosure()

    # Holds the most recent live-vs-local drift rows (from the auto-fetch
    # below) so $btnShowDiff can bring the SAME compare dialog back up on
    # demand - without this, dismissing/deciding that dialog once was the
    # only chance to see it; re-reading it meant closing and reopening this
    # whole dialog (a fresh Intune fetch) just to look again.
    $lastDriftBox = @{ Rows = $null; LocalSnapshot = $null }

    $btnSetDefaults.Add_Click({
        $changeRows = & $getCurrentVsDefaultChanges
        if ($changeRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Every setting already matches the computed defaults for this app.", "Nothing to change", "OK", "Information") | Out-Null
            return
        }

        $confirmResult = Show-SetDefaultsConfirmDialog -Lines (@($changeRows | ForEach-Object { $_.Display })) -ParentForm $dlg
        if (-not $confirmResult) { return }

        foreach ($cr in $changeRows) {
            switch ($cr.Label) {
                "Install command" { $txtInstall.Text = $defaults.installCommand }
                "Uninstall command" { $txtUninstall.Text = $defaults.uninstallCommand }
                "Detection rule" {
                    if ($defaults.detectionRule -and $defaults.detectionRule.Type -eq "Script") {
                        $cmbDetectionType.SelectedIndex = 0
                        $txtDetection.Text = $defaults.detectionRule.Script_Content
                    }
                }
                "Architecture" {
                    if ($defaults.architecture) {
                        $defArchList = @($defaults.architecture -split ',' | ForEach-Object { $_.Trim().ToLower() })
                        $chkArchX86.Checked = $defArchList -contains "x86"
                        $chkArchX64.Checked = $defArchList -contains "x64"
                        $chkArchArm64.Checked = $defArchList -contains "arm64"
                    }
                }
                "Minimum OS" {
                    $defMinOsLabel = $minOsMap.Keys | Where-Object { $minOsMap[$_] -eq $defaults.minOSKey } | Select-Object -First 1
                    if ($defMinOsLabel) { $cmbMinOS.SelectedItem = $defMinOsLabel }
                }
                "Dependencies" {
                    for ($ci = 0; $ci -lt $clbDeps.Items.Count; $ci++) { $clbDeps.SetItemChecked($ci, $false) }
                    for ($ci = 0; $ci -lt $clbDeps.Items.Count; $ci++) {
                        $itemLabel = [string]$clbDeps.Items[$ci]
                        if ($depNameByLabel.ContainsKey($itemLabel) -and (@($defaults.dependencies) -contains $depNameByLabel[$itemLabel])) {
                            $clbDeps.SetItemChecked($ci, $true)
                        }
                    }
                }
                "Disk space (MB)" { $txtDiskSpace.Text = [string]$defaults.minDiskSpaceMB }
                "Memory (MB)" { $txtMemory.Text = [string]$defaults.minMemoryMB }
                "Min. processors" { $txtProcessors.Text = [string]$defaults.minProcessors }
                "Min. CPU speed (MHz)" { $txtCpuSpeed.Text = [string]$defaults.minCpuSpeedMHz }
                "Install time (mins)" { $txtInstallTime.Text = [string]$defaults.installTimeMinutes }
                "Device restart behavior" {
                    $defRbKey = $restartBehaviorMap.Keys | Where-Object { $restartBehaviorMap[$_] -eq $defaults.deviceRestartBehavior } | Select-Object -First 1
                    if ($defRbKey) { $cmbRestartBehavior.SelectedItem = $defRbKey }
                }
                "Allow available uninstall" { $chkAllowUninstall.Checked = [bool]$defaults.allowAvailableUninstall }
                "Return codes" {
                    $grdReturnCodes.Rows.Clear()
                    foreach ($rc in @($defaults.returnCodes)) {
                        $rcRowIdx = $grdReturnCodes.Rows.Add()
                        $grdReturnCodes.Rows[$rcRowIdx].Cells["Code"].Value = [string]$rc.returnCode
                        $grdReturnCodes.Rows[$rcRowIdx].Cells["Type"].Value = [string]$rc.type
                    }
                }
            }
        }
        & $updateCustomFieldHighlights
        [System.Windows.Forms.MessageBox]::Show("Reset $($changeRows.Count) setting(s) to their computed defaults. Nothing has been saved or deployed yet - review below, then Save/Deploy as usual.", "Defaults applied", "OK", "Information") | Out-Null
    }.GetNewClosure())

    $lblCreateStatus = New-Object System.Windows.Forms.Label
    $lblCreateStatus.Location = New-Object System.Drawing.Point(15,773)
    $lblCreateStatus.Size = New-Object System.Drawing.Size(700,40)
    $dlg.Controls.Add($lblCreateStatus)

    $rtbCreateLog = New-Object System.Windows.Forms.RichTextBox
    $rtbCreateLog.Location = New-Object System.Drawing.Point(15,821)
    $rtbCreateLog.Size = New-Object System.Drawing.Size(700,110)
    Initialize-DarkLogBox -LogBox $rtbCreateLog
    $dlg.Controls.Add($rtbCreateLog)

    $btnCreate = New-Object System.Windows.Forms.Button
    $btnCreate.Text = if ($isDuplicate) { "Update Metadata" } else { "Deploy" }
    $btnCreate.Location = New-Object System.Drawing.Point(425,941)
    $btnCreate.Size = New-Object System.Drawing.Size(200,32)
    $dlg.Controls.Add($btnCreate)

    # For a new app, lets its metadata be captured and saved locally
    # without requiring the package to exist yet - so a batch of new apps
    # can be filled in ahead of time and deployed together later. For an
    # EXISTING app, saves whatever's currently displayed (typically the
    # live Intune values, just fetched below, or the user's own edits on
    # top of them) as a local copy - a way to keep a browsable, editable
    # record of an app's metadata without needing to push anything back to
    # Intune at all.
    $btnSaveForLater = New-Object System.Windows.Forms.Button
    $btnSaveForLater.Text = if ($isDuplicate) { "Save local copy..." } else { "Save to App Catalog without Deploying" }
    $btnSaveForLater.Location = New-Object System.Drawing.Point(15,941)
    $btnSaveForLater.Size = New-Object System.Drawing.Size(300,32)
    $btnSaveForLater.Font = New-Object System.Drawing.Font($btnSaveForLater.Font.FontFamily, 8)
    $dlg.Controls.Add($btnSaveForLater)

    # Brings back the SAME compare dialog the live-Intune auto-fetch below
    # already showed once, for whichever fields it found differing - without
    # this, dismissing/deciding it that one time was the only chance to see
    # it again; re-checking meant closing and reopening this whole dialog (a
    # fresh Intune fetch) just to look. Hidden by default rather than just
    # disabled - there's nothing to compare for a brand-new app (no live
    # Intune copy to diff against at all), and for an existing app it stays
    # hidden until the auto-fetch below actually finds a real difference, so
    # its mere presence is itself a signal something differs, not a
    # permanently-greyed-out button with nothing behind it most of the time.
    $btnShowDiff = New-Object System.Windows.Forms.Button
    $btnShowDiff.Text = "Compare..."
    $btnShowDiff.Location = New-Object System.Drawing.Point(320,941)
    $btnShowDiff.Size = New-Object System.Drawing.Size(95,32)
    $btnShowDiff.Font = New-Object System.Drawing.Font($btnSaveForLater.Font.FontFamily, 8)
    $btnShowDiff.Visible = $false
    $dlg.Controls.Add($btnShowDiff)
    $showDiffTip = New-Object System.Windows.Forms.ToolTip
    $showDiffTip.SetToolTip($btnShowDiff, "Show again which fields differ from Intune's live copy, and optionally keep your local value for some of them.")
    $btnShowDiff.Add_Click({
        if (-not $lastDriftBox.Rows -or $lastDriftBox.Rows.Count -eq 0) { return }
        $keepLocalFields = @(Show-MetadataDriftDialog -Rows $lastDriftBox.Rows)
        if ($keepLocalFields.Count -gt 0) {
            & $applyKeepLocalFields -KeepLocalFields $keepLocalFields -LocalSnapshot $lastDriftBox.LocalSnapshot
        }
    }.GetNewClosure())

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(635,941)
    $btnCancel.Size = New-Object System.Drawing.Size(80,32)
    $dlg.Controls.Add($btnCancel)

    if ($isDuplicate) {
        # Button label follows both checkboxes live. Force-new and
        # Replace-content are mutually exclusive - Create mode always
        # uploads content, so "also replace content" is meaningless once
        # Force-new is checked.
        $chkForceNew.Add_Click({
            if ($chkForceNew.Checked) {
                $chkReplaceContent.Checked = $false
                $chkReplaceContent.Enabled = $false
                # Creating a brand new app - install context is meaningful
                # again. Architecture/Min OS/Requirements/return codes/
                # install experience were never actually locked below
                # (confirmed patchable on an existing app), so there's
                # nothing else to re-enable here now.
                $cmbContext.Enabled = $true
                # A non-win32 EXISTING app (see the auto-fetch's own type
                # check above) doesn't matter anymore once Force-new is
                # checked - this is now about creating a brand new
                # win32LobApp alongside it, not touching that other object
                # at all, so the block on Create/Update doesn't apply here.
                $btnCreate.Enabled = $true
            }
            else {
                $chkReplaceContent.Enabled = $true
                # Back to updating the existing app - install context is
                # the one field Graph genuinely won't let get changed
                # post-creation.
                $cmbContext.Enabled = $false
                # Re-block if the existing app's own fetched type still
                # says it isn't a win32 app - unchecking Force-new means
                # this button is back to targeting THAT object again.
                $rawTypeNameForToggle = if ($fetchedIntuneFactsBox.OdataType) { $fetchedIntuneFactsBox.OdataType -replace '^#?microsoft\.graph\.', '' } else { "" }
                if ($rawTypeNameForToggle -and @("win32LobApp", "win32CatalogApp", "windowsMobileMSI") -notcontains $rawTypeNameForToggle) {
                    $btnCreate.Enabled = $false
                }
            }
            $btnCreate.Text = if ($chkForceNew.Checked) { "Deploy" } elseif ($chkReplaceContent.Checked) { "Update + Replace Content" } else { "Update Metadata" }
        }.GetNewClosure())
        $chkReplaceContent.Add_Click({
            $btnCreate.Text = if ($chkForceNew.Checked) { "Deploy" } elseif ($chkReplaceContent.Checked) { "Update + Replace Content" } else { "Update Metadata" }
        }.GetNewClosure())
    }

    # Metadata is $null unless -FromAppEditor deferred a local-catalog save
    # to the caller (see the Create/Update success handler and
    # $btnSaveForLater below) - the caller then folds it into its own save.
    # NavigateToIndex is set only by the Previous/Next buttons below - the
    # caller (Show-AppEditor's own "Intune Deployment" click handler)
    # checks it before touching anything else in this result, since
    # navigating away means none of this dialog's other fields apply to
    # the app that's about to close.
    $resultBox = @{ NewAppId = $null; NewAppName = $null; Metadata = $null; IntuneAppType = $null; IntuneAppVersion = $null; NavigateToIndex = $null }

    # Only shown when this was opened from the app editor for an app at a
    # known catalog position (see -CurrentIndex's own param comment) -
    # hidden for a brand-new app or any other caller. Navigating away
    # discards whatever's in THIS form the same way Cancel would (no
    # implicit save) - Show-AppEditor's own Previous/Next buttons work the
    # same way, for the same reason. Wired here, right after $resultBox
    # exists, not up by the rest of the button row - .GetNewClosure()
    # captures variable VALUES at the moment it's called, so wiring these
    # any earlier (before $resultBox was ever assigned) would have
    # permanently captured $null instead of the real box.
    $btnPrevAppDeploy = New-Object System.Windows.Forms.Button
    $btnPrevAppDeploy.Text = "< Previous app"
    $btnPrevAppDeploy.Location = New-Object System.Drawing.Point(15,979)
    $btnPrevAppDeploy.Size = New-Object System.Drawing.Size(150,30)
    $btnPrevAppDeploy.Enabled = ($null -ne $prevAppIndex)
    $btnPrevAppDeploy.Visible = ($CurrentIndex -ge 0)
    $dlg.Controls.Add($btnPrevAppDeploy)

    $lblDeployNavPosition = New-Object System.Windows.Forms.Label
    $lblDeployNavPosition.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblDeployNavPosition.Location = New-Object System.Drawing.Point(280,979)
    $lblDeployNavPosition.Size = New-Object System.Drawing.Size(170,30)
    $lblDeployNavPosition.ForeColor = [System.Drawing.Color]::DimGray
    if ($CurrentIndex -ge 0) {
        $navFilterForLabel = $Global:App.TxtSearch.Text.Trim().ToLower()
        $visibleCountForLabel = 0
        $visiblePosForLabel = 0
        for ($li = 0; $li -lt $appsRef.Count; $li++) {
            if ($navFilterForLabel) {
                $liHay = ("$($appsRef[$li].appName) $($appsRef[$li].wingetId)").ToLower()
                if ($liHay -notlike "*$navFilterForLabel*") { continue }
            }
            $visibleCountForLabel++
            if ($li -eq $CurrentIndex) { $visiblePosForLabel = $visibleCountForLabel }
        }
        $lblDeployNavPosition.Text = if ($visiblePosForLabel -gt 0) { "$visiblePosForLabel of $visibleCountForLabel" } else { "" }
    }
    $dlg.Controls.Add($lblDeployNavPosition)

    $btnNextAppDeploy = New-Object System.Windows.Forms.Button
    $btnNextAppDeploy.Text = "Next app >"
    $btnNextAppDeploy.Location = New-Object System.Drawing.Point(565,979)
    $btnNextAppDeploy.Size = New-Object System.Drawing.Size(150,30)
    $btnNextAppDeploy.Enabled = ($null -ne $nextAppIndex)
    $btnNextAppDeploy.Visible = ($CurrentIndex -ge 0)
    $dlg.Controls.Add($btnNextAppDeploy)

    $btnPrevAppDeploy.Add_Click({
        $resultBox.NavigateToIndex = $prevAppIndex
        $dlg.Close()
    }.GetNewClosure())
    $btnNextAppDeploy.Add_Click({
        $resultBox.NavigateToIndex = $nextAppIndex
        $dlg.Close()
    }.GetNewClosure())

    # Filled in by the auto-fetch below (isDuplicate case only - a brand
    # new app has nothing live to fetch yet) and read back by the Create/
    # Update success handler further down, so a successful Update can
    # record the version Intune had right before this run, not leave it
    # permanently blank just because this dialog itself never asks
    # Intune to report a version back after a Create/Update completes.
    # Declared here, before either closure that touches it, for the same
    # reason as every other mutable container in this file.
    $fetchedIntuneFactsBox = @{ OdataType = $null; DisplayVersion = $null }
    $procBox = @{ Proc = $null }   # lets btnCancel below terminate a still-running step

    $btnCreate.Add_Click({
        if (-not $txtCreateName.Text.Trim() -or -not $txtInstall.Text.Trim() -or -not $txtUninstall.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Name, install command, and uninstall command are all required.", "Missing values", "OK", "Warning") | Out-Null
            return
        }

        $mode = if ($isDuplicate -and -not $chkForceNew.Checked) { "UpdateMetadata" } else { "Create" }
        $replaceContent = ($mode -eq "UpdateMetadata") -and $isDuplicate -and $chkReplaceContent.Checked

        if ($mode -eq "Create" -or $replaceContent) {
            if (-not (Test-Path $txtPackagePath.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Package file not found:`n$($txtPackagePath.Text)`n`nUse Browse... to point at the correct .intunewin file.", "Package not found", "OK", "Warning") | Out-Null
                return
            }
        }

        $selectedDepIds = New-Object System.Collections.Generic.List[string]
        $undeployedDepNames = New-Object System.Collections.Generic.List[string]
        foreach ($checkedLabel in $clbDeps.CheckedItems) {
            $depId = $depIdByLabel[[string]$checkedLabel]
            if ($depId) {
                $selectedDepIds.Add($depId)
            }
            elseif ($depNameByLabel.ContainsKey([string]$checkedLabel)) {
                # This path (immediate Create/Update) can't defer
                # dependency resolution the way "Save for later..." or
                # Batch Deploy can - Graph needs a real App ID right now,
                # not a name to resolve later.
                $undeployedDepNames.Add($depNameByLabel[[string]$checkedLabel])
            }
        }
        if ($undeployedDepNames.Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show("These checked dependencies aren't deployed to Intune yet, so there's no App ID to set: $($undeployedDepNames -join ', ')`n`nDeploy them first, or use `"Save for later...`" instead and let Batch Deploy resolve dependencies once everything's created.", "Dependency not deployed yet", "OK", "Warning") | Out-Null
            return
        }

        $selectedArches = New-Object System.Collections.Generic.List[string]
        if ($chkArchX86.Checked)   { $selectedArches.Add("x86") }
        if ($chkArchX64.Checked)   { $selectedArches.Add("x64") }
        if ($chkArchArm64.Checked) { $selectedArches.Add("arm64") }
        if ($selectedArches.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one architecture.", "No architecture selected", "OK", "Warning") | Out-Null
            return
        }

        foreach ($urlCheck in @(@{ Label = "Information URL"; Text = $txtInfoUrl.Text.Trim() }, @{ Label = "Privacy URL"; Text = $txtPrivacyUrl.Text.Trim() })) {
            if (-not $urlCheck.Text) { continue }
            $parsedUri = $null
            $isValidUrl = [Uri]::TryCreate($urlCheck.Text, [UriKind]::Absolute, [ref]$parsedUri) -and ($parsedUri.Scheme -eq 'http' -or $parsedUri.Scheme -eq 'https')
            if (-not $isValidUrl) {
                [System.Windows.Forms.MessageBox]::Show("$($urlCheck.Label) doesn't look like a valid URL:`n`n$($urlCheck.Text)`n`nIt needs a scheme, e.g. https://example.com - or leave it blank.", "Invalid URL", "OK", "Warning") | Out-Null
                return
            }
        }

        $numericChecks = @(
            @{ Label = "Disk space (MB)"; Text = $txtDiskSpace.Text.Trim() }
            @{ Label = "Memory (MB)"; Text = $txtMemory.Text.Trim() }
            @{ Label = "Min. processors"; Text = $txtProcessors.Text.Trim() }
            @{ Label = "Min. CPU speed (MHz)"; Text = $txtCpuSpeed.Text.Trim() }
            @{ Label = "Install time required (mins)"; Text = $txtInstallTime.Text.Trim() }
        )
        foreach ($numCheck in $numericChecks) {
            $parsedNum = 0
            if (-not [int]::TryParse($numCheck.Text, [ref]$parsedNum) -or $parsedNum -lt 0) {
                [System.Windows.Forms.MessageBox]::Show("$($numCheck.Label) must be a whole number, 0 or greater.", "Invalid value", "OK", "Warning") | Out-Null
                return
            }
        }

        $returnCodesConfig = New-Object System.Collections.Generic.List[object]
        foreach ($rcRow in $grdReturnCodes.Rows) {
            if ($rcRow.IsNewRow) { continue }
            $codeText = [string]$rcRow.Cells["Code"].Value
            $typeText = [string]$rcRow.Cells["Type"].Value
            if (-not $codeText -and -not $typeText) { continue }
            $parsedCode = 0
            if (-not [int]::TryParse([string]$codeText.Trim(), [ref]$parsedCode)) {
                [System.Windows.Forms.MessageBox]::Show("Return code `"$codeText`" isn't a valid whole number.", "Invalid return code", "OK", "Warning") | Out-Null
                return
            }
            if (-not $typeText) {
                [System.Windows.Forms.MessageBox]::Show("Return code $parsedCode needs a type selected.", "Missing return code type", "OK", "Warning") | Out-Null
                return
            }
            $returnCodesConfig.Add([pscustomobject]@{ returnCode = $parsedCode; type = $typeText })
        }
        if ($returnCodesConfig.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("At least one return code is required.", "No return codes", "OK", "Warning") | Out-Null
            return
        }

        switch ($cmbDetectionType.SelectedIndex) {
            0 {
                if (-not $txtDetection.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter a detection script.", "No detection script", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{ Type = "Script"; Script_Content = $txtDetection.Text }
            }
            1 {
                if (-not $txtMsiCode.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter the MSI product code.", "No product code", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{
                    Type                = "Msi"
                    Msi_ProductCode     = $txtMsiCode.Text.Trim()
                    Msi_VersionOperator = $operatorMap[[string]$cmbMsiOperator.SelectedItem]
                    Msi_Version         = $txtMsiVersion.Text.Trim()
                }
            }
            2 {
                if (-not $txtFilePath.Text.Trim() -or -not $txtFileName.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter both the folder path and the file or folder name.", "Missing fields", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{
                    Type               = "File"
                    File_Path           = $txtFilePath.Text.Trim()
                    File_Name           = $txtFileName.Text.Trim()
                    File_Check32Bit     = $chkFileCheck32.Checked
                    File_DetectionType  = $fileDetTypeMap[[string]$cmbFileDetType.SelectedItem]
                    File_Operator       = $operatorMap[[string]$cmbFileOperator.SelectedItem]
                    File_DetectionValue = $txtFileDetValue.Text.Trim()
                }
            }
            3 {
                if (-not $txtRegKeyPath.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter the registry key path.", "No key path", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{
                    Type               = "Registry"
                    Reg_KeyPath         = $txtRegKeyPath.Text.Trim()
                    Reg_ValueName       = $txtRegValueName.Text.Trim()
                    Reg_Check32Bit      = $chkRegCheck32.Checked
                    Reg_DetectionType   = $regDetTypeMap[[string]$cmbRegDetType.SelectedItem]
                    Reg_Operator        = $operatorMap[[string]$cmbRegOperator.SelectedItem]
                    Reg_DetectionValue  = $txtRegDetValue.Text.Trim()
                }
            }
        }

        if ($replaceContent) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "This replaces the package content on the EXISTING, live app ($ExistingAppId) with:`n$($txtPackagePath.Text)`n`nDevices that already have this app installed will get the new content on their next check-in. This cannot be undone from here. Continue?",
                "Confirm content replacement", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
        }

        # $resultPath computed BEFORE $config now, specifically so
        # OutputResultPath can be included directly in the object literal
        # below - the previous approach built $config first, then bolted
        # this one extra property on afterward via
        # "$config | Select-Object *, @{...}". That extra step was
        # confirmed, directly and repeatedly, to sometimes produce a
        # genuinely null result with no error at all - not a timing issue,
        # not a write issue, not an antivirus issue, all three already
        # ruled out. Rather than keep chasing why that specific PowerShell
        # construct misbehaves, this sidesteps it entirely by never using
        # it in the first place.
        $configPath = Join-Path $env:TEMP (".intunepkg_createapp_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_createapp_result_" + [guid]::NewGuid().ToString("N") + ".json")

        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Mode                  = $mode
            ExistingAppId         = $ExistingAppId
            AppName               = $txtCreateName.Text.Trim()
            Description           = $txtDesc.Text.Trim()
            Publisher             = $txtPublisher.Text.Trim()
            Owner                 = $txtOwner.Text.Trim()
            Developer             = $txtDeveloper.Text.Trim()
            InformationUrl        = $txtInfoUrl.Text.Trim()
            PrivacyUrl            = $txtPrivacyUrl.Text.Trim()
            Notes                 = $txtNotes.Text.Trim()
            InstallCommand        = $txtInstall.Text
            UninstallCommand      = $txtUninstall.Text
            DetectionRule         = $detectionRuleConfig
            InstallContext        = [string]$cmbContext.SelectedItem
            Architecture          = ($selectedArches -join ",")
            MinOSVersionKey       = $minOsMap[[string]$cmbMinOS.SelectedItem]
            PackagePath           = $txtPackagePath.Text
            DependencyAppIds      = @($selectedDepIds)
            ReplaceContent        = $replaceContent
            MinDiskSpaceMB        = [int]$txtDiskSpace.Text.Trim()
            MinMemoryMB           = [int]$txtMemory.Text.Trim()
            MinProcessors         = [int]$txtProcessors.Text.Trim()
            MinCpuSpeedMHz        = [int]$txtCpuSpeed.Text.Trim()
            InstallTimeMinutes    = [int]$txtInstallTime.Text.Trim()
            DeviceRestartBehavior = $restartBehaviorMap[[string]$cmbRestartBehavior.SelectedItem]
            AllowAvailableUninstall = $chkAllowUninstall.Checked
            # .ToArray() now, not @(...) - confirmed, directly and
            # precisely, to sometimes throw "Argument types do not match"
            # for this exact List[object] pattern elsewhere in this same
            # function (Save for later's own return-codes handling). If
            # this same construct was ALSO throwing here, inside $config's
            # own construction, that would silently abort the whole
            # object - explaining why Create never actually worked even
            # after the serializer itself was rewritten to hand-roll
            # everything else: the real failure was upstream of
            # serialization entirely, in building $config in the first
            # place.
            ReturnCodes           = $returnCodesConfig.ToArray()
            OutputResultPath      = $resultPath
        }

        # Hand-rolled via ConvertTo-CreateAppConfigJson, not a direct
        # ConvertTo-Json call on the whole $config object - serializing
        # this whole, larger, 30+ field object through one single
        # ConvertTo-Json call was confirmed, directly and repeatedly, to
        # sometimes silently produce a completely empty result with no
        # error thrown at all, even with -ErrorAction Stop, even with the
        # earlier Select-Object step already removed. This mirrors the
        # exact approach that already fixed the identical symptom for the
        # catalog's own per-app metadata: hand-roll every simple field,
        # isolate only the genuinely complex nested object (DetectionRule)
        # through its own, separate ConvertTo-Json call.
        $configJsonTextLength = 0
        try {
            $configJsonText = ConvertTo-CreateAppConfigJson -Config $config
            $configJsonTextLength = if ($configJsonText) { $configJsonText.Length } else { 0 }
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Show-ConfigWriteFailedError -ErrorMessage $_.Exception.Message
            return
        }
        # Verified explicitly, immediately after the write, rather than
        # trusting it succeeded just because no exception surfaced -
        # exceptions inside a WinForms event handler scriptblock don't
        # always propagate the same way they would in the main script body,
        # even with $ErrorActionPreference = "Stop" set globally. Launching
        # the child process anyway, on an unverified assumption the config
        # is actually there, is exactly what would produce "Config file not
        # found" from the child instead of a clear, immediate error here.
        #
        # Checks CONTENT, not just existence - a real failure mode already
        # seen once: Test-Path alone can find the file, but the child
        # process that reads it right after gets back empty/incomplete
        # content, which silently parses to a blank config (empty AppName,
        # empty Mode) instead of throwing any error at all. Retried briefly
        # rather than checked once, on the same reasoning as before - a
        # real-time antivirus/EDR scan intercepting a newly-written file
        # (this one contains embedded PowerShell script content, which can
        # draw extra scrutiny even though it's completely legitimate here)
        # is a well-known cause of exactly this kind of transient gap
        # between "the file exists" and "the file's actual content is
        # available to read." Same kind of short, transient-visibility
        # retry already proven elsewhere in this app (group creation
        # propagation delay).
        $configVerified = $false
        # The specific failure reason from the LAST attempt, not just a
        # generic "didn't work" - the empty catch block this replaced was
        # silently throwing away exactly the information needed to tell
        # apart "file never appeared", "file appeared but is empty",
        # "file has content but won't parse as JSON", and "parsed fine but
        # a field came back blank" - four genuinely different problems
        # that all produced the identical, unhelpful message before.
        $lastVerifyDetail = "the file does not exist"
        for ($verifyAttempt = 1; $verifyAttempt -le 5; $verifyAttempt++) {
            if (Test-Path $configPath) {
                try {
                    $fileInfo = Get-Item -Path $configPath -ErrorAction Stop
                    $verifyContent = Get-Content -Path $configPath -Raw -ErrorAction Stop
                    if (-not $verifyContent -or $verifyContent.Trim().Length -eq 0) {
                        $lastVerifyDetail = "the file exists ($($fileInfo.Length) bytes on disk) but its content read back empty"
                        # Not just noted and retried unchanged - actively
                        # re-attempted with a different, lower-level write
                        # path: raw bytes through a FileStream with an
                        # explicit OS-level flush, rather than
                        # WriteAllText's higher-level buffering. Worth
                        # trying in its own right after "0 bytes on disk"
                        # has now been seen twice already, at two
                        # completely different folder locations - giving
                        # this attempt a real chance to actually succeed,
                        # not just collecting more information about the
                        # same failure a third time.
                        try {
                            $configBytesRetry = [System.Text.Encoding]::UTF8.GetBytes($configJsonText)
                            $retryStream = [System.IO.File]::Open($configPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                            try {
                                $retryStream.Write($configBytesRetry, 0, $configBytesRetry.Length)
                                $retryStream.Flush($true)
                            }
                            finally {
                                $retryStream.Close()
                                $retryStream.Dispose()
                            }
                        }
                        catch {
                            $lastVerifyDetail = "the file exists ($($fileInfo.Length) bytes on disk) but its content read back empty, and the fallback rewrite attempt also failed: $($_.Exception.Message)"
                        }
                    }
                    else {
                        try {
                            $verifyParsed = $verifyContent | ConvertFrom-Json -ErrorAction Stop
                            if ($verifyParsed.AppName) { $configVerified = $true; break }
                            $lastVerifyDetail = "the file parsed as JSON ($($verifyContent.Length) chars) but its AppName field came back blank"
                        }
                        catch {
                            $lastVerifyDetail = "the file has content ($($verifyContent.Length) chars) but failed to parse as JSON: $($_.Exception.Message)"
                        }
                    }
                }
                catch {
                    $lastVerifyDetail = "the file exists but could not be read: $($_.Exception.Message)"
                }
            }
            Start-Sleep -Milliseconds 200
        }
        if (-not $configVerified) {
            [System.Windows.Forms.MessageBox]::Show("The config file at:`n$configPath`n`ncould not be verified after waiting a moment: $lastVerifyDetail.`n`nThe JSON text generated before the write was $configJsonTextLength characters long.`n`nNothing was started.`n`nIf this keeps happening, check whether antivirus/EDR software on this machine is intercepting, delaying, or quarantining newly-written .json files.", "Failed to prepare", "OK", "Error") | Out-Null
            return
        }

        $btnCreate.Enabled = $false
        $lblCreateStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblCreateStatus.Text = "Working... this can take a few minutes for larger packages. See progress below. Cancel stops it."

        # Fresh aliases for the nested -OnComplete closure below - see note at
        # the top of this function.
        $btnCreateRef = $btnCreate
        $lblStatusRef = $lblCreateStatus
        $dlgRef = $dlg
        $resultBoxRef = $resultBox
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $appNameRef = $config.AppName
        $fromAppEditorRef = $FromAppEditor
        $rtbLogRef = $rtbCreateLog
        # Added specifically so the success handler below can build and
        # save a catalog-shaped metadata object via
        # Save-AppMetadataToLocalCatalog - a real Create/Update Metadata
        # previously only ever touched Intune, never the local catalog
        # file, even though "Save for later..." (right next to it, same
        # dialog) already did this correctly. $detectionRuleConfig,
        # $selectedArches, and $returnCodesConfig are already-built local
        # variables from this same button's own validation just above,
        # not re-read from the UI a second time.
        $appsRefRef = $appsRef
        $linkedFilePathRef = $linkedFilePath
        $txtDescRef = $txtDesc
        $txtPublisherRef = $txtPublisher
        $txtOwnerRef = $txtOwner
        $txtDeveloperRef = $txtDeveloper
        $txtInfoUrlRef = $txtInfoUrl
        $txtPrivacyUrlRef = $txtPrivacyUrl
        $txtNotesRef = $txtNotes
        $txtInstallRef = $txtInstall
        $txtUninstallRef = $txtUninstall
        $cmbContextRef = $cmbContext
        $cmbMinOSRef = $cmbMinOS
        $minOsMapRef = $minOsMap
        $detectionRuleConfigRef = $detectionRuleConfig
        $selectedArchesRef = $selectedArches
        $txtDiskSpaceRef = $txtDiskSpace
        $txtMemoryRef = $txtMemory
        $txtProcessorsRef = $txtProcessors
        $txtCpuSpeedRef = $txtCpuSpeed
        $txtInstallTimeRef = $txtInstallTime
        $cmbRestartBehaviorRef = $cmbRestartBehavior
        $restartBehaviorMapRef = $restartBehaviorMap
        $chkAllowUninstallRef = $chkAllowUninstall
        $returnCodesConfigRef = $returnCodesConfig
        $clbDepsRef = $clbDeps
        $depNameByLabelRef = $depNameByLabel
        $fetchedIntuneFactsBoxRef = $fetchedIntuneFactsBox

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $createScript -TempScriptName ".intunepkg_embedded_createapp.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbCreateLog -OnComplete {
            param($code)
            $btnCreateRef.Enabled = $true
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $resultBoxRef.NewAppId = $result.appId
                        $resultBoxRef.NewAppName = $appNameRef
                        # This tool only ever creates/updates win32LobApp
                        # objects, so the type is a known fact on any
                        # success, no fetch needed. Version isn't a known
                        # fact the same way - $fetchedIntuneFactsBoxRef only
                        # has one whenever this WAS an existing app (the
                        # auto-fetch above ran before this click); blank for
                        # a genuinely brand-new create, where Intune hasn't
                        # necessarily processed/reported a version yet.
                        $resultBoxRef.IntuneAppType = "Windows app (Win32)"
                        $resultBoxRef.IntuneAppVersion = $fetchedIntuneFactsBoxRef.DisplayVersion

                        # Builds and saves a catalog-shaped metadata object
                        # now, same schema and same shared function "Save
                        # for later..." uses - a real Create/Update
                        # Metadata previously only ever reached Intune,
                        # never the local catalog file, even though
                        # everything entered here (description, install
                        # command, detection script, requirements, return
                        # codes...) was successfully sent to Intune and
                        # then simply never recorded locally at all.
                        # Wrapped in its own try/catch, not left bare - the
                        # same defensive pattern already proven necessary
                        # for this exact kind of object construction in
                        # "Save for later...".
                        $localSaveOk = $true
                        try {
                            $depNamesForSave = New-Object System.Collections.Generic.List[string]
                            foreach ($checkedLabel in $clbDepsRef.CheckedItems) {
                                if ($depNameByLabelRef.ContainsKey([string]$checkedLabel)) { $depNamesForSave.Add($depNameByLabelRef[[string]$checkedLabel]) }
                            }
                            $createMetadata = [pscustomobject]@{
                                description      = $txtDescRef.Text.Trim()
                                publisher        = $txtPublisherRef.Text.Trim()
                                owner            = $txtOwnerRef.Text.Trim()
                                developer        = $txtDeveloperRef.Text.Trim()
                                informationUrl   = $txtInfoUrlRef.Text.Trim()
                                privacyUrl       = $txtPrivacyUrlRef.Text.Trim()
                                notes            = $txtNotesRef.Text.Trim()
                                installCommand   = $txtInstallRef.Text
                                uninstallCommand = $txtUninstallRef.Text
                                architecture     = ($selectedArchesRef -join ",")
                                installContext   = [string]$cmbContextRef.SelectedItem
                                minOSKey         = $minOsMapRef[[string]$cmbMinOSRef.SelectedItem]
                                detectionRule    = $detectionRuleConfigRef
                                dependencies     = @($depNamesForSave)
                                minDiskSpaceMB          = [int]$txtDiskSpaceRef.Text.Trim()
                                minMemoryMB             = [int]$txtMemoryRef.Text.Trim()
                                minProcessors           = [int]$txtProcessorsRef.Text.Trim()
                                minCpuSpeedMHz          = [int]$txtCpuSpeedRef.Text.Trim()
                                installTimeMinutes      = [int]$txtInstallTimeRef.Text.Trim()
                                deviceRestartBehavior   = $restartBehaviorMapRef[[string]$cmbRestartBehaviorRef.SelectedItem]
                                allowAvailableUninstall = $chkAllowUninstallRef.Checked
                                returnCodes             = $returnCodesConfigRef.ToArray()
                            }
                            if ($fromAppEditorRef) {
                                # Deferred, not saved here - the App Editor
                                # this dialog was opened from is still open,
                                # with its own unsaved appName/wingetId/group
                                # fields, and hasn't had its own "Save app to
                                # catalog" clicked yet. Writing this metadata
                                # (and $result.appId) straight to $Global:App.Apps
                                # and disk here, unconditionally, used to mean
                                # a brand-new app got ADDED to the catalog the
                                # instant Create succeeded - so that editor's
                                # own later "Save app to catalog" click added
                                # a second, duplicate entry for the same app,
                                # and clicking Cancel instead couldn't undo
                                # the first one at all, leaving a stray entry
                                # behind. Handing it back via $resultBoxRef
                                # instead lets the App Editor fold it into the
                                # ONE save (or discard) it already owns.
                                $resultBoxRef.Metadata = $createMetadata
                            }
                            else {
                                $localSaveResult = Save-AppMetadataToLocalCatalog -AppsRef $appsRefRef -LinkedFilePath $linkedFilePathRef -AppName $appNameRef -Metadata $createMetadata -NewAppId $result.appId -IntuneAppVersion $fetchedIntuneFactsBoxRef.DisplayVersion
                                $localSaveOk = $localSaveResult.Success
                            }
                        }
                        catch {
                            $localSaveOk = $false
                            Write-Log "[FAILED] Create/Update Metadata: saving to the local catalog threw: $($_.Exception.Message)`r`n" ([System.Drawing.Color]::Tomato)
                        }

                        $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblStatusRef.Text = "Success - App ID: $($result.appId)"
                        # Accurate for both callers, not just one - this
                        # dialog is opened from two different places with two
                        # different save behaviors: the App Editor (which
                        # still has its own separate appName/wingetId/group
                        # fields, and this app's App ID/metadata now stay
                        # staged - not written anywhere - until its own "Save
                        # app to catalog" is clicked) and everywhere else
                        # (where App ID and metadata are both already saved
                        # directly, right above).
                        $doneMsg = if (-not $localSaveOk) {
                            "Done. App ID: $($result.appId)`n`n...but saving this to the local catalog failed - check the Log tab. The app was still created/updated in Intune successfully."
                        } elseif ($fromAppEditorRef) {
                            "Done. App ID: $($result.appId)`n`nThe App ID has been filled in above. Nothing is saved to the catalog yet - click `"Save app to catalog`" in the app editor to save it there (or Cancel to discard it; the app in Intune itself is unaffected either way)."
                        } else {
                            "Done. App ID: $($result.appId)`n`nAlready saved to disk."
                        }
                        [System.Windows.Forms.MessageBox]::Show($doneMsg, "Success", "OK", "Information") | Out-Null
                        $dlgRef.Close()
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
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above for the last thing it was doing."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnSaveForLater.Add_Click({
        if (-not $txtCreateName.Text.Trim() -or -not $txtInstall.Text.Trim() -or -not $txtUninstall.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Name, install command, and uninstall command are all required.", "Missing values", "OK", "Warning") | Out-Null
            return
        }

        $selectedArches = New-Object System.Collections.Generic.List[string]
        if ($chkArchX86.Checked)   { $selectedArches.Add("x86") }
        if ($chkArchX64.Checked)   { $selectedArches.Add("x64") }
        if ($chkArchArm64.Checked) { $selectedArches.Add("arm64") }
        if ($selectedArches.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one architecture.", "No architecture selected", "OK", "Warning") | Out-Null
            return
        }

        foreach ($urlCheck in @(@{ Label = "Information URL"; Text = $txtInfoUrl.Text.Trim() }, @{ Label = "Privacy URL"; Text = $txtPrivacyUrl.Text.Trim() })) {
            if (-not $urlCheck.Text) { continue }
            $parsedUri = $null
            $isValidUrl = [Uri]::TryCreate($urlCheck.Text, [UriKind]::Absolute, [ref]$parsedUri) -and ($parsedUri.Scheme -eq 'http' -or $parsedUri.Scheme -eq 'https')
            if (-not $isValidUrl) {
                [System.Windows.Forms.MessageBox]::Show("$($urlCheck.Label) doesn't look like a valid URL:`n`n$($urlCheck.Text)`n`nIt needs a scheme, e.g. https://example.com - or leave it blank.", "Invalid URL", "OK", "Warning") | Out-Null
                return
            }
        }

        $numericChecksSave = @(
            @{ Label = "Disk space (MB)"; Text = $txtDiskSpace.Text.Trim() }
            @{ Label = "Memory (MB)"; Text = $txtMemory.Text.Trim() }
            @{ Label = "Min. processors"; Text = $txtProcessors.Text.Trim() }
            @{ Label = "Min. CPU speed (MHz)"; Text = $txtCpuSpeed.Text.Trim() }
            @{ Label = "Install time required (mins)"; Text = $txtInstallTime.Text.Trim() }
        )
        foreach ($numCheckSave in $numericChecksSave) {
            $parsedNumSave = 0
            if (-not [int]::TryParse($numCheckSave.Text, [ref]$parsedNumSave) -or $parsedNumSave -lt 0) {
                [System.Windows.Forms.MessageBox]::Show("$($numCheckSave.Label) must be a whole number, 0 or greater.", "Invalid value", "OK", "Warning") | Out-Null
                return
            }
        }

        $returnCodesConfigSave = New-Object System.Collections.Generic.List[object]
        foreach ($rcRowSave in $grdReturnCodes.Rows) {
            if ($rcRowSave.IsNewRow) { continue }
            $codeTextSave = [string]$rcRowSave.Cells["Code"].Value
            $typeTextSave = [string]$rcRowSave.Cells["Type"].Value
            if (-not $codeTextSave -and -not $typeTextSave) { continue }
            $parsedCodeSave = 0
            if (-not [int]::TryParse([string]$codeTextSave.Trim(), [ref]$parsedCodeSave)) {
                [System.Windows.Forms.MessageBox]::Show("Return code `"$codeTextSave`" isn't a valid whole number.", "Invalid return code", "OK", "Warning") | Out-Null
                return
            }
            if (-not $typeTextSave) {
                [System.Windows.Forms.MessageBox]::Show("Return code $parsedCodeSave needs a type selected.", "Missing return code type", "OK", "Warning") | Out-Null
                return
            }
            $returnCodesConfigSave.Add([pscustomobject]@{ returnCode = $parsedCodeSave; type = $typeTextSave })
        }
        if ($returnCodesConfigSave.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("At least one return code is required.", "No return codes", "OK", "Warning") | Out-Null
            return
        }

        $detectionRuleConfig = $null
        switch ($cmbDetectionType.SelectedIndex) {
            0 {
                if (-not $txtDetection.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter a detection script.", "No detection script", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{ Type = "Script"; Script_Content = $txtDetection.Text }
            }
            1 {
                if (-not $txtMsiCode.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter the MSI product code.", "No product code", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{
                    Type                = "Msi"
                    Msi_ProductCode     = $txtMsiCode.Text.Trim()
                    Msi_VersionOperator = $operatorMap[[string]$cmbMsiOperator.SelectedItem]
                    Msi_Version         = $txtMsiVersion.Text.Trim()
                }
            }
            2 {
                if (-not $txtFilePath.Text.Trim() -or -not $txtFileName.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter both the folder path and the file or folder name.", "Missing fields", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{
                    Type               = "File"
                    File_Path           = $txtFilePath.Text.Trim()
                    File_Name           = $txtFileName.Text.Trim()
                    File_Check32Bit     = $chkFileCheck32.Checked
                    File_DetectionType  = $fileDetTypeMap[[string]$cmbFileDetType.SelectedItem]
                    File_Operator       = $operatorMap[[string]$cmbFileOperator.SelectedItem]
                    File_DetectionValue = $txtFileDetValue.Text.Trim()
                }
            }
            3 {
                if (-not $txtRegKeyPath.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show("Enter the registry key path.", "No key path", "OK", "Warning") | Out-Null
                    return
                }
                $detectionRuleConfig = [pscustomobject]@{
                    Type               = "Registry"
                    Reg_KeyPath         = $txtRegKeyPath.Text.Trim()
                    Reg_ValueName       = $txtRegValueName.Text.Trim()
                    Reg_Check32Bit      = $chkRegCheck32.Checked
                    Reg_DetectionType   = $regDetTypeMap[[string]$cmbRegDetType.SelectedItem]
                    Reg_Operator        = $operatorMap[[string]$cmbRegOperator.SelectedItem]
                    Reg_DetectionValue  = $txtRegDetValue.Text.Trim()
                }
            }
        }

        # Read directly from the picker's current checked state, not just
        # whatever was passively fetched/loaded earlier - the picker now
        # includes undeployed apps too (resolved by name at actual deploy
        # time, same as Batch Deploy already does), so this is the only
        # way to actually SET a dependency when saving metadata for a new
        # app that doesn't exist in Intune yet to fetch anything from.
        $depNamesFromPicker = New-Object System.Collections.Generic.List[string]
        foreach ($checkedLabel in $clbDeps.CheckedItems) {
            if ($depNameByLabel.ContainsKey([string]$checkedLabel)) { $depNamesFromPicker.Add($depNameByLabel[[string]$checkedLabel]) }
        }

        # Built field by field, each into its own variable, with a
        # checkpoint logged after each group - "Argument types do not
        # match" was confirmed as the actual, specific exception here,
        # but that alone doesn't say WHICH of the ~20 fields threw it.
        # Rather than guess again, this pinpoints the exact line: the
        # checkpoint log written right before the exception fires tells
        # us precisely how far construction got before failing.
        try {
            $fDescription = $txtDesc.Text.Trim()
            $fPublisher = $txtPublisher.Text.Trim()
            $fOwner = $txtOwner.Text.Trim()
            $fDeveloper = $txtDeveloper.Text.Trim()
            $fInformationUrl = $txtInfoUrl.Text.Trim()
            $fPrivacyUrl = $txtPrivacyUrl.Text.Trim()
            $fNotes = $txtNotes.Text.Trim()
            $fInstallCommand = $txtInstall.Text
            $fUninstallCommand = $txtUninstall.Text
            Write-Log "Save for later: checkpoint 1/6 (simple text fields) OK.`r`n"

            $fArchitecture = ($selectedArches -join ",")
            Write-Log "Save for later: checkpoint 2/6 (architecture join) OK.`r`n"

            $fInstallContext = [string]$cmbContext.SelectedItem
            Write-Log "Save for later: checkpoint 3/6 (installContext cast) OK - value=`"$fInstallContext`".`r`n"

            $fMinOSKeySelected = [string]$cmbMinOS.SelectedItem
            Write-Log "Save for later: checkpoint 3.5/6 (minOS SelectedItem cast) OK - value=`"$fMinOSKeySelected`", type=$($fMinOSKeySelected.GetType().FullName).`r`n"
            $fMinOSKey = $minOsMap[$fMinOSKeySelected]
            Write-Log "Save for later: checkpoint 4/6 (minOsMap lookup) OK - value=`"$fMinOSKey`".`r`n"

            $fDetectionRule = $detectionRuleConfig
            $fDependencies = @($depNamesFromPicker)
            Write-Log "Save for later: checkpoint 5/6 (detectionRule, dependencies) OK.`r`n"

            $fMinDiskSpaceMB = [int]$txtDiskSpace.Text.Trim()
            $fMinMemoryMB = [int]$txtMemory.Text.Trim()
            $fMinProcessors = [int]$txtProcessors.Text.Trim()
            $fMinCpuSpeedMHz = [int]$txtCpuSpeed.Text.Trim()
            $fInstallTimeMinutes = [int]$txtInstallTime.Text.Trim()
            Write-Log "Save for later: checkpoint 6/6a ([int] casts) OK.`r`n"

            $fRestartBehaviorSelected = [string]$cmbRestartBehavior.SelectedItem
            Write-Log "Save for later: checkpoint 6/6b (restartBehavior SelectedItem cast) OK - value=`"$fRestartBehaviorSelected`", type=$($fRestartBehaviorSelected.GetType().FullName).`r`n"
            $fDeviceRestartBehavior = $restartBehaviorMap[$fRestartBehaviorSelected]
            Write-Log "Save for later: checkpoint 6/6c (restartBehaviorMap lookup) OK - value=`"$fDeviceRestartBehavior`".`r`n"

            $fAllowAvailableUninstall = $chkAllowUninstall.Checked
            Write-Log "Save for later: checkpoint 6/6d1 (allowUninstall) OK - value=$fAllowAvailableUninstall, type=$($fAllowAvailableUninstall.GetType().FullName).`r`n"

            Write-Log "Save for later: about to wrap returnCodesConfigSave - Count=$($returnCodesConfigSave.Count), type=$($returnCodesConfigSave.GetType().FullName).`r`n"
            # .ToArray() now, not the @(...) array-subexpression operator -
            # confirmed, directly and precisely (via checkpoint logging
            # isolating this exact statement, on its own, outside any
            # larger expression), to be the one specific operation
            # throwing "Argument types do not match" for this particular
            # List[object]. .ToArray() is a plain method call already
            # defined on the list itself, sidestepping whatever PowerShell's
            # own @(...) enumeration logic was doing differently here.
            $fReturnCodes = $returnCodesConfigSave.ToArray()
            Write-Log "Save for later: checkpoint 6/6d2 (returnCodes wrap) OK - result Count=$($fReturnCodes.Count).`r`n"

            $newMetadata = [pscustomobject]@{
                description      = $fDescription
                publisher        = $fPublisher
                owner            = $fOwner
                developer        = $fDeveloper
                informationUrl   = $fInformationUrl
                privacyUrl       = $fPrivacyUrl
                notes            = $fNotes
                installCommand   = $fInstallCommand
                uninstallCommand = $fUninstallCommand
                architecture     = $fArchitecture
                installContext   = $fInstallContext
                minOSKey         = $fMinOSKey
                detectionRule    = $fDetectionRule
                dependencies     = $fDependencies
                minDiskSpaceMB          = $fMinDiskSpaceMB
                minMemoryMB             = $fMinMemoryMB
                minProcessors           = $fMinProcessors
                minCpuSpeedMHz          = $fMinCpuSpeedMHz
                installTimeMinutes      = $fInstallTimeMinutes
                deviceRestartBehavior   = $fDeviceRestartBehavior
                allowAvailableUninstall = $fAllowAvailableUninstall
                returnCodes             = $fReturnCodes
            }
            Write-Log "Save for later: final object assembly OK.`r`n"
        }
        catch {
            Write-Log "[FAILED] Save for later: building the metadata object threw: $($_.Exception.Message)`r`n" ([System.Drawing.Color]::Tomato)
            [System.Windows.Forms.MessageBox]::Show("Could not build the metadata to save: $($_.Exception.Message)", "Save failed", "OK", "Error") | Out-Null
            return
        }
        Write-Log "Save for later: `$newMetadata built - is `$null: $($null -eq $newMetadata), description in it: `"$($newMetadata.description)`".`r`n"

        # Opened from the App Editor (-FromAppEditor): stage this metadata
        # for that still-open editor's own "Save app to catalog" instead of
        # writing it here - same reasoning as the Create/Update Metadata
        # success handler above. Writing it here unconditionally used to
        # mean a brand-new app's editor Save afterward added a SECOND,
        # duplicate catalog entry, and Cancelling that editor couldn't undo
        # the entry this button had already written.
        if ($FromAppEditor) {
            $resultBox.Metadata = $newMetadata
            Write-Log "Save for later (from app editor): metadata staged for `"$AppName`" - will be saved when `"Save app to catalog`" is clicked there.`r`n" ([System.Drawing.Color]::LightGreen)
            $dlg.Close()
            return
        }

        # Saves straight to disk rather than just staging the change in
        # memory - unlike most other actions in this app (which batch
        # several related edits before one explicit Save), this button's
        # entire job IS the save; requiring a separate click afterward just
        # to persist it was pure friction, and had already caused real,
        # demonstrated confusion earlier this session (mistaking "not yet
        # written to disk" for "the save silently failed"). Routed through
        # the same shared function the Create/Update Metadata success
        # handler now also uses (see Save-AppMetadataToLocalCatalog) -
        # find/create-by-name, whole-element replacement, and the actual
        # write all happen there now, not duplicated here.
        $saveResult = Save-AppMetadataToLocalCatalog -AppsRef $appsRef -LinkedFilePath $linkedFilePath -AppName $AppName -Metadata $newMetadata
        $saveSucceeded = $saveResult.Success
        $createdNewEntry = $saveResult.CreatedNewEntry
        $unsavedBox.Value = $true
        Write-Log "Save for later: Save-AppMetadataToLocalCatalog returned Success=$saveSucceeded, CreatedNewEntry=$createdNewEntry.`r`n"

        $createdMsg = if ($createdNewEntry) { "`"$AppName`" wasn't in the catalog yet, so it was added. " } else { "" }
        if (-not $saveSucceeded) {
            # A real failure worth seeing and acting on, not just a
            # confirmation - dialog stays open so the user can retry
            # (e.g. via the main toolbar's Save to input.json) rather than
            # closing on them right when something needs attention.
            $lblCreateStatus.ForeColor = [System.Drawing.Color]::DarkOrange
            $lblCreateStatus.Text = "$($createdMsg)Metadata saved in memory for `"$AppName`", but writing to disk was cancelled or failed - use Force save catalog to try again."
            return
        }

        $savedMsg = if ($isDuplicate) {
            "$($createdMsg)Local copy saved and written to disk for `"$AppName`"."
        } else {
            "$($createdMsg)Metadata saved and written to disk for `"$AppName`". Deploy later once its package is ready."
        }
        # No popup on success - a modal box requiring its own click to
        # dismiss, on an action that now virtually always succeeds, was
        # exactly the kind of friction worth removing. The dialog closing
        # is itself sufficient confirmation; the details still go to the
        # Log tab for anyone who wants to check back on them.
        Write-Log $savedMsg ([System.Drawing.Color]::LightGreen)
        $dlg.Close()
    }.GetNewClosure())

    $btnCancel.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "A step is currently running (PID $($procBox.Proc.Id)). Stop it and close this dialog?`n`nIf the app object was already created in Intune, it may be left in an incomplete state - check the Intune portal afterward and delete it if needed before retrying.",
                "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())

    # Pre-fill from LOCALLY saved metadata (if any), before anything else -
    # for a new app that was already "Saved for later" once, this restores
    # what was entered instead of starting over from generic templates. For
    # an EXISTING app (about to be auto-refreshed from Intune just below),
    # this also gives something to diff the live fetch against, so a field
    # that's drifted between the two gets flagged instead of the live value
    # silently overwriting it with nobody noticing the difference.
    $localSnapshot = $null
    $targetCatalogApp = $appsRef | Where-Object { $_.appName -eq $AppName } | Select-Object -First 1
    if ($targetCatalogApp -and $targetCatalogApp.metadata) {
        $m = $targetCatalogApp.metadata
        if ($null -ne $m.description)    { $txtDesc.Text = $m.description }
        if ($null -ne $m.publisher)      { $txtPublisher.Text = $m.publisher }
        if ($null -ne $m.owner)          { $txtOwner.Text = $m.owner }
        if ($null -ne $m.developer)      { $txtDeveloper.Text = $m.developer }
        if ($null -ne $m.informationUrl) { $txtInfoUrl.Text = $m.informationUrl }
        if ($null -ne $m.privacyUrl)     { $txtPrivacyUrl.Text = $m.privacyUrl }
        if ($null -ne $m.notes)          { $txtNotes.Text = $m.notes }
        if ($m.installCommand)           { $txtInstall.Text = $m.installCommand }
        if ($m.uninstallCommand)         { $txtUninstall.Text = $m.uninstallCommand }
        if ($m.detectionRule) {
            switch ($m.detectionRule.Type) {
                "Script" {
                    $cmbDetectionType.SelectedIndex = 0
                    if ($m.detectionRule.Script_Content) { $txtDetection.Text = $m.detectionRule.Script_Content }
                }
                "Msi" {
                    $cmbDetectionType.SelectedIndex = 1
                    $txtMsiCode.Text = $m.detectionRule.Msi_ProductCode
                    $opKey = $operatorMap.Keys | Where-Object { $operatorMap[$_] -eq $m.detectionRule.Msi_VersionOperator } | Select-Object -First 1
                    if ($opKey) { $cmbMsiOperator.SelectedItem = $opKey }
                    $txtMsiVersion.Text = $m.detectionRule.Msi_Version
                }
                "File" {
                    $cmbDetectionType.SelectedIndex = 2
                    $txtFilePath.Text = $m.detectionRule.File_Path
                    $txtFileName.Text = $m.detectionRule.File_Name
                    $chkFileCheck32.Checked = [bool]$m.detectionRule.File_Check32Bit
                    $dtKey = $fileDetTypeMap.Keys | Where-Object { $fileDetTypeMap[$_] -eq $m.detectionRule.File_DetectionType } | Select-Object -First 1
                    if ($dtKey) { $cmbFileDetType.SelectedItem = $dtKey }
                    $opKey = $operatorMap.Keys | Where-Object { $operatorMap[$_] -eq $m.detectionRule.File_Operator } | Select-Object -First 1
                    if ($opKey) { $cmbFileOperator.SelectedItem = $opKey }
                    $txtFileDetValue.Text = $m.detectionRule.File_DetectionValue
                }
                "Registry" {
                    $cmbDetectionType.SelectedIndex = 3
                    $txtRegKeyPath.Text = $m.detectionRule.Reg_KeyPath
                    $txtRegValueName.Text = $m.detectionRule.Reg_ValueName
                    $chkRegCheck32.Checked = [bool]$m.detectionRule.Reg_Check32Bit
                    $dtKey = $regDetTypeMap.Keys | Where-Object { $regDetTypeMap[$_] -eq $m.detectionRule.Reg_DetectionType } | Select-Object -First 1
                    if ($dtKey) { $cmbRegDetType.SelectedItem = $dtKey }
                    $opKey = $operatorMap.Keys | Where-Object { $operatorMap[$_] -eq $m.detectionRule.Reg_Operator } | Select-Object -First 1
                    if ($opKey) { $cmbRegOperator.SelectedItem = $opKey }
                    $txtRegDetValue.Text = $m.detectionRule.Reg_DetectionValue
                }
            }
        }
        if ($m.architecture) {
            $archList = @($m.architecture -split ',' | ForEach-Object { $_.Trim().ToLower() })
            $chkArchX86.Checked = $archList -contains "x86"
            $chkArchX64.Checked = $archList -contains "x64"
            $chkArchArm64.Checked = $archList -contains "arm64"
        }
        if ($m.installContext) { $cmbContext.SelectedItem = $m.installContext }
        if ($m.minOSKey) {
            $matchKey = $minOsMap.Keys | Where-Object { $minOsMap[$_] -eq $m.minOSKey } | Select-Object -First 1
            if ($matchKey) { $cmbMinOS.SelectedItem = $matchKey }
        }
        if ($m.dependencies) {
            $fetchedDependencyBox.Names = @($m.dependencies)
            # Pre-checks the picker to match EXACTLY what's saved, not just
            # storing the names silently in the background - without this,
            # "Save for later..." reading from the picker (below) would
            # show existing dependencies as unchecked and silently wipe
            # them out the moment someone clicked Save without noticing.
            # Cleared first, not just added to - otherwise the picker's own
            # default "Winget AutoUpdate" pre-check could stick around even
            # when the saved dependencies deliberately don't include it.
            for ($ci = 0; $ci -lt $clbDeps.Items.Count; $ci++) { $clbDeps.SetItemChecked($ci, $false) }
            for ($ci = 0; $ci -lt $clbDeps.Items.Count; $ci++) {
                $itemLabel = [string]$clbDeps.Items[$ci]
                if ($depNameByLabel.ContainsKey($itemLabel) -and (@($m.dependencies) -contains $depNameByLabel[$itemLabel])) {
                    $clbDeps.SetItemChecked($ci, $true)
                }
            }
        }
        if ($null -ne $m.minDiskSpaceMB)     { $txtDiskSpace.Text = [string]$m.minDiskSpaceMB }
        if ($null -ne $m.minMemoryMB)        { $txtMemory.Text = [string]$m.minMemoryMB }
        if ($null -ne $m.minProcessors)      { $txtProcessors.Text = [string]$m.minProcessors }
        if ($null -ne $m.minCpuSpeedMHz)     { $txtCpuSpeed.Text = [string]$m.minCpuSpeedMHz }
        if ($null -ne $m.installTimeMinutes) { $txtInstallTime.Text = [string]$m.installTimeMinutes }
        if ($m.deviceRestartBehavior) {
            $rbKey = $restartBehaviorMap.Keys | Where-Object { $restartBehaviorMap[$_] -eq $m.deviceRestartBehavior } | Select-Object -First 1
            if ($rbKey) { $cmbRestartBehavior.SelectedItem = $rbKey }
        }
        $chkAllowUninstall.Checked = [bool]$m.allowAvailableUninstall
        if (@($m.returnCodes).Count -gt 0) {
            $grdReturnCodes.Rows.Clear()
            foreach ($rc in @($m.returnCodes)) {
                $rcRowIdx = $grdReturnCodes.Rows.Add()
                $grdReturnCodes.Rows[$rcRowIdx].Cells["Code"].Value = [string]$rc.returnCode
                $grdReturnCodes.Rows[$rcRowIdx].Cells["Type"].Value = [string]$rc.type
            }
        }

        # Captured AFTER setting the fields above, as an exact snapshot of
        # what LOCAL held - compared later against the live Intune fetch
        # (for existing apps only) to flag any drift between the two.
        $localSnapshot = [pscustomobject]@{
            Description        = $txtDesc.Text
            Publisher          = $txtPublisher.Text
            Owner              = $txtOwner.Text
            Developer          = $txtDeveloper.Text
            InformationUrl     = $txtInfoUrl.Text
            PrivacyUrl         = $txtPrivacyUrl.Text
            Notes              = $txtNotes.Text
            InstallCommand     = $txtInstall.Text
            UninstallCommand   = $txtUninstall.Text
            Architecture       = $m.architecture
            Dependencies       = @($m.dependencies)
            DetectionSummary   = if ($m.detectionRule) { ConvertTo-DetectionRuleJson -DetectionRule $m.detectionRule -IndentLevel 0 } else { "" }
            MinDiskSpaceMB     = $txtDiskSpace.Text
            MinMemoryMB        = $txtMemory.Text
            MinProcessors      = $txtProcessors.Text
            MinCpuSpeedMHz     = $txtCpuSpeed.Text
            InstallTimeMinutes = $txtInstallTime.Text
            DeviceRestartBehavior = if ($m.deviceRestartBehavior) { $m.deviceRestartBehavior } else { "basedOnReturnCode" }
            AllowAvailableUninstall = [bool]$m.allowAvailableUninstall
            ReturnCodesSummary = if (@($m.returnCodes).Count -gt 0) { (@($m.returnCodes) | ConvertTo-Json -Compress -Depth 5) } else { "" }
            # The raw structured objects behind the two summary strings
            # above - only used if the drift-compare dialog needs to
            # actually REVERT one of these two composite fields back to the
            # local value (repopulating the detection-rule sub-form or the
            # return-codes grid needs the real object, not the JSON string
            # used for the diff/display).
            DetectionRule = $m.detectionRule
            ReturnCodes   = @($m.returnCodes)
        }
    }

    # First pass - covers a brand-new app (nothing but computed defaults on
    # the form yet, so nothing highlights) and an existing app before its
    # live-Intune auto-fetch below has come back (highlights based on the
    # locally saved copy just pre-filled above). The auto-fetch's own
    # OnComplete calls this again once live values are in, for an existing
    # app - see there for why that second pass matters.
    & $updateCustomFieldHighlights

    if ($isDuplicate) {
        # Fetches what's actually live in Intune right now and repopulates
        # the fields above (which start out holding local guesses/templates)
        # once it comes back, so Update Metadata edits a real, current
        # picture instead of possibly overwriting a correct Intune value
        # with a stale local guess.
        $dlg.Add_Shown({
            $lblCreateStatus.ForeColor = [System.Drawing.Color]::DimGray
            $lblCreateStatus.Text = "Loading current metadata from Intune..."

            # Fresh aliases for the nested -OnComplete closure - see note at
            # the top of this function for why this matters.
            $existingAppIdRef = $ExistingAppId
            $updateCustomFieldHighlightsRef = $updateCustomFieldHighlights
            $applyKeepLocalFieldsRef = $applyKeepLocalFields
            $lastDriftBoxRef = $lastDriftBox
            $btnShowDiffRef = $btnShowDiff
            $AppNameRef = $AppName
            $lblCreateStatusRef = $lblCreateStatus
            $txtCreateNameRef = $txtCreateName
            $txtDescRef = $txtDesc
            $txtPublisherRef = $txtPublisher
            $txtOwnerRef = $txtOwner
            $txtDeveloperRef = $txtDeveloper
            $txtInfoUrlRef = $txtInfoUrl
            $txtPrivacyUrlRef = $txtPrivacyUrl
            $txtNotesRef = $txtNotes
            $txtInstallRef = $txtInstall
            $txtUninstallRef = $txtUninstall
            $txtDetectionRef = $txtDetection
            $cmbContextRef = $cmbContext
            $chkArchX86Ref = $chkArchX86
            $chkArchX64Ref = $chkArchX64
            $chkArchArm64Ref = $chkArchArm64
            $cmbMinOSRef = $cmbMinOS
            $minOsMapRef = $minOsMap
            $lblMinOSStatusRef = $lblMinOSStatus
            $cmbDetectionTypeRef = $cmbDetectionType
            $operatorMapRef = $operatorMap
            $txtMsiCodeRef = $txtMsiCode
            $cmbMsiOperatorRef = $cmbMsiOperator
            $txtMsiVersionRef = $txtMsiVersion
            $txtFilePathRef = $txtFilePath
            $txtFileNameRef = $txtFileName
            $chkFileCheck32Ref = $chkFileCheck32
            $cmbFileDetTypeRef = $cmbFileDetType
            $fileDetTypeMapRef = $fileDetTypeMap
            $cmbFileOperatorRef = $cmbFileOperator
            $txtFileDetValueRef = $txtFileDetValue
            $txtRegKeyPathRef = $txtRegKeyPath
            $txtRegValueNameRef = $txtRegValueName
            $chkRegCheck32Ref = $chkRegCheck32
            $cmbRegDetTypeRef = $cmbRegDetType
            $regDetTypeMapRef = $regDetTypeMap
            $cmbRegOperatorRef = $cmbRegOperator
            $txtRegDetValueRef = $txtRegDetValue
            $localSnapshotRef = $localSnapshot
            $fetchedDependencyBoxRef = $fetchedDependencyBox
            $clbDepsRef = $clbDeps
            $depNameByLabelRef = $depNameByLabel
            $txtDiskSpaceRef = $txtDiskSpace
            $txtMemoryRef = $txtMemory
            $txtProcessorsRef = $txtProcessors
            $txtCpuSpeedRef = $txtCpuSpeed
            $txtInstallTimeRef = $txtInstallTime
            $cmbRestartBehaviorRef = $cmbRestartBehavior
            $restartBehaviorMapRef = $restartBehaviorMap
            $chkAllowUninstallRef = $chkAllowUninstall
            $grdReturnCodesRef = $grdReturnCodes
            $fetchedIntuneFactsBoxRef = $fetchedIntuneFactsBox
            $btnCreateRef = $btnCreate
            $rtbCreateLogRef = $rtbCreateLog

            Start-AppMetadataFetch -AppId $existingAppIdRef -OnComplete {
                param($ok, $errMsg, $data)
                if (-not $ok) {
                    $lblCreateStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                    $lblCreateStatusRef.Text = "Could not load current metadata ($errMsg) - fields above are local guesses, not confirmed live values."
                    # The label above wraps to a fixed height and clips
                    # anything past it - the diagnostic detail this can now
                    # carry (exception type, source position) routinely runs
                    # past that. The log box below has room to spare and is
                    # already scrollable, so the FULL message always lands
                    # there too.
                    Write-DialogLogLine -LogBox $rtbCreateLogRef -Text "`r`n[FAILED] Could not load current metadata: $errMsg`r`n"
                    return
                }
                $fetchedIntuneFactsBoxRef.OdataType = $data.OdataType
                $fetchedIntuneFactsBoxRef.DisplayVersion = $data.DisplayVersion

                # This tool only ever builds a win32LobApp-shaped PATCH body
                # (installExperience, detectionRules, minimumSupportedOS,
                # ...) - sending that to an app of any OTHER type (Microsoft
                # 365 Apps, a Store app, ...) means Graph rejects it with a
                # confusing "property does not exist on this type" error,
                # not a helpful one. Blocked here, against the type just
                # fetched LIVE, rather than only from the cached local
                # intuneAppType column (which is blank for anything never
                # synced) - this is the one place that already has to know
                # the real type regardless.
                $knownWin32Types = @("win32LobApp", "win32CatalogApp", "windowsMobileMSI")
                $rawTypeName = if ($data.OdataType) { $data.OdataType -replace '^#?microsoft\.graph\.', '' } else { "" }
                if ($rawTypeName -and $knownWin32Types -notcontains $rawTypeName) {
                    $btnCreateRef.Enabled = $false
                    $lblCreateStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblCreateStatusRef.Text = "This app is a `"$(Get-FriendlyIntuneAppType -ODataType $data.OdataType)`" in Intune, not a Win32 app - this tool only manages Win32 app deployments. Use the Intune portal directly for this app."
                    return
                }
                if ($data.DisplayName)              { $txtCreateNameRef.Text = $data.DisplayName }
                if ($null -ne $data.Description)    { $txtDescRef.Text = $data.Description }
                if ($null -ne $data.Publisher)      { $txtPublisherRef.Text = $data.Publisher }
                if ($null -ne $data.Owner)          { $txtOwnerRef.Text = $data.Owner }
                if ($null -ne $data.Developer)      { $txtDeveloperRef.Text = $data.Developer }
                if ($null -ne $data.InformationUrl) { $txtInfoUrlRef.Text = $data.InformationUrl }
                if ($null -ne $data.PrivacyInformationUrl) { $txtPrivacyUrlRef.Text = $data.PrivacyInformationUrl }
                if ($null -ne $data.Notes)          { $txtNotesRef.Text = $data.Notes }
                if ($null -ne $data.InstallCommandLine)   { $txtInstallRef.Text = $data.InstallCommandLine }
                if ($null -ne $data.UninstallCommandLine) { $txtUninstallRef.Text = $data.UninstallCommandLine }
                # Live Intune value replaces whatever local held, once it's
                # actually back - fixes a real gap where "Save local
                # copy..." used to hardcode dependencies as always empty
                # for every existing app, regardless of what Intune had.
                if ($null -ne $data.Dependencies) {
                    $fetchedDependencyBoxRef.Names = @($data.Dependencies)
                    # Same reasoning as the local-metadata prefill above -
                    # pre-checks the picker to match exactly what's live in
                    # Intune, cleared first so the picker's own default
                    # pre-check doesn't linger if the real data doesn't
                    # include it.
                    for ($ci = 0; $ci -lt $clbDepsRef.Items.Count; $ci++) { $clbDepsRef.SetItemChecked($ci, $false) }
                    for ($ci = 0; $ci -lt $clbDepsRef.Items.Count; $ci++) {
                        $itemLabel = [string]$clbDepsRef.Items[$ci]
                        if ($depNameByLabelRef.ContainsKey($itemLabel) -and (@($data.Dependencies) -contains $depNameByLabelRef[$itemLabel])) {
                            $clbDepsRef.SetItemChecked($ci, $true)
                        }
                    }
                }

                # Shown even though these controls are disabled for an
                # existing app (Graph rejects PATCHing them post-creation,
                # same as Context/Architecture/MinOS) - same reasoning
                # already established for those: a wrong/default guess
                # displayed next to a grayed-out control would be actively
                # misleading about what's really set.
                if ($null -ne $data.MinDiskSpaceMB)     { $txtDiskSpaceRef.Text = [string]$data.MinDiskSpaceMB }
                if ($null -ne $data.MinMemoryMB)        { $txtMemoryRef.Text = [string]$data.MinMemoryMB }
                if ($null -ne $data.MinProcessors)      { $txtProcessorsRef.Text = [string]$data.MinProcessors }
                if ($null -ne $data.MinCpuSpeedMHz)     { $txtCpuSpeedRef.Text = [string]$data.MinCpuSpeedMHz }
                if ($null -ne $data.InstallTimeMinutes) { $txtInstallTimeRef.Text = [string]$data.InstallTimeMinutes }
                if ($data.DeviceRestartBehavior) {
                    $rbKey = $restartBehaviorMapRef.Keys | Where-Object { $restartBehaviorMapRef[$_] -eq $data.DeviceRestartBehavior } | Select-Object -First 1
                    if ($rbKey) { $cmbRestartBehaviorRef.SelectedItem = $rbKey }
                }
                $chkAllowUninstallRef.Checked = [bool]$data.AllowAvailableUninstall
                if (@($data.ReturnCodes).Count -gt 0) {
                    $grdReturnCodesRef.Rows.Clear()
                    foreach ($rc in @($data.ReturnCodes)) {
                        $rcRowIdx = $grdReturnCodesRef.Rows.Add()
                        $grdReturnCodesRef.Rows[$rcRowIdx].Cells["Code"].Value = [string]$rc.returnCode
                        $grdReturnCodesRef.Rows[$rcRowIdx].Cells["Type"].Value = [string]$rc.type
                    }
                }

                if ($data.DetectionRule) {
                    switch ($data.DetectionRule.Type) {
                        "Script" {
                            $cmbDetectionTypeRef.SelectedIndex = 0
                            if ($data.DetectionRule.Script_Content) { $txtDetectionRef.Text = $data.DetectionRule.Script_Content }
                        }
                        "Msi" {
                            $cmbDetectionTypeRef.SelectedIndex = 1
                            $txtMsiCodeRef.Text = $data.DetectionRule.Msi_ProductCode
                            $opKey = $operatorMapRef.Keys | Where-Object { $operatorMapRef[$_] -eq $data.DetectionRule.Msi_VersionOperator } | Select-Object -First 1
                            if ($opKey) { $cmbMsiOperatorRef.SelectedItem = $opKey }
                            $txtMsiVersionRef.Text = $data.DetectionRule.Msi_Version
                        }
                        "File" {
                            $cmbDetectionTypeRef.SelectedIndex = 2
                            $txtFilePathRef.Text = $data.DetectionRule.File_Path
                            $txtFileNameRef.Text = $data.DetectionRule.File_Name
                            $chkFileCheck32Ref.Checked = [bool]$data.DetectionRule.File_Check32Bit
                            $dtKey = $fileDetTypeMapRef.Keys | Where-Object { $fileDetTypeMapRef[$_] -eq $data.DetectionRule.File_DetectionType } | Select-Object -First 1
                            if ($dtKey) { $cmbFileDetTypeRef.SelectedItem = $dtKey }
                            $opKey = $operatorMapRef.Keys | Where-Object { $operatorMapRef[$_] -eq $data.DetectionRule.File_Operator } | Select-Object -First 1
                            if ($opKey) { $cmbFileOperatorRef.SelectedItem = $opKey }
                            $txtFileDetValueRef.Text = $data.DetectionRule.File_DetectionValue
                        }
                        "Registry" {
                            $cmbDetectionTypeRef.SelectedIndex = 3
                            $txtRegKeyPathRef.Text = $data.DetectionRule.Reg_KeyPath
                            $txtRegValueNameRef.Text = $data.DetectionRule.Reg_ValueName
                            $chkRegCheck32Ref.Checked = [bool]$data.DetectionRule.Reg_Check32Bit
                            $dtKey = $regDetTypeMapRef.Keys | Where-Object { $regDetTypeMapRef[$_] -eq $data.DetectionRule.Reg_DetectionType } | Select-Object -First 1
                            if ($dtKey) { $cmbRegDetTypeRef.SelectedItem = $dtKey }
                            $opKey = $operatorMapRef.Keys | Where-Object { $operatorMapRef[$_] -eq $data.DetectionRule.Reg_Operator } | Select-Object -First 1
                            if ($opKey) { $cmbRegOperatorRef.SelectedItem = $opKey }
                            $txtRegDetValueRef.Text = $data.DetectionRule.Reg_DetectionValue
                        }
                    }
                }

                # These three stay disabled either way (Graph rejects changing
                # them via PATCH), but setting the DISPLAYED value even while
                # disabled matters - showing a wrong/default guess next to a
                # grayed-out control would be actively misleading about what's
                # really set.
                if ($data.RunAsAccount) {
                    $cmbContextRef.SelectedItem = if ($data.RunAsAccount -eq "user") { "User" } else { "System" }
                }
                # Confirmed directly from Microsoft's own win32LobApp docs:
                # when an app uses MULTIPLE architectures, that's actually
                # represented via the separate allowedArchitectures property
                # - and setting that forces applicableArchitectures to the
                # literal string "none" as a side effect, not blank/null.
                # Reading only applicableArchitectures (as this used to)
                # meant any multi-architecture app came back as "none",
                # matched nothing, and silently left every checkbox
                # unchecked - which is exactly what this looked like.
                # allowedArchitectures is checked first and preferred
                # whenever it holds a real, non-"none" value; single-
                # architecture apps that only ever set applicableArchitectures
                # still fall back to that correctly.
                $archSource = $null
                if ($data.AllowedArchitectures -and $data.AllowedArchitectures -ne "none") {
                    $archSource = $data.AllowedArchitectures
                }
                elseif ($data.ApplicableArchitectures -and $data.ApplicableArchitectures -ne "none") {
                    $archSource = $data.ApplicableArchitectures
                }
                # Re-normalized into the same canonical, comma-joined
                # "x86,x64,arm64" order the local catalog's own architecture
                # field always uses (see the -join "," that builds it) -
                # Intune has been observed returning this as a
                # PERIOD-separated string (e.g. "x64.arm64") for a
                # multi-architecture app, not comma. Splitting on [,.]
                # handles either separator; re-joining in this fixed order
                # (rather than whatever order/separator Intune used) means
                # both the checkbox pre-fill right below AND the
                # local-vs-Intune comparison further down are comparing the
                # actual architecture SET, not incidental formatting -
                # without this, splitting a period-joined value on a comma
                # leaves it as one unmatched token, so every checkbox below
                # would silently end up unchecked, and an identical local
                # copy would always be flagged as "different".
                if ($archSource) {
                    $archTokensNorm = @($archSource -split '[,.]' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
                    $archSource = (@("x86","x64","arm64") | Where-Object { $archTokensNorm -contains $_ }) -join ","
                }
                if ($archSource) {
                    $archList = @($archSource -split ',' | ForEach-Object { $_.Trim().ToLower() })
                    $chkArchX86Ref.Checked = $archList -contains "x86"
                    $chkArchX64Ref.Checked = $archList -contains "x64"
                    $chkArchArm64Ref.Checked = $archList -contains "arm64"
                }
                # This dialog now reads/writes minimumSupportedWindowsRelease
                # (see the note next to $Global:App.EmbeddedCreateAppScript's own
                # $patchBody assignment for why) - matched via
                # Get-ParsedMinOsRelease, not a raw string comparison, since
                # THREE different spellings of this same property have been
                # observed live for the exact same release ("W11_21H2",
                # "Windows11_21H2", bare "21H1").
                $matchedFromNew = $null
                if ($data.MinimumSupportedWindowsRelease) {
                    $newParsed = Get-ParsedMinOsRelease -RawValue $data.MinimumSupportedWindowsRelease
                    $matchedFromNew = $minOsMapRef.Keys | Where-Object {
                        $candidateParsed = Get-ParsedMinOsRelease -RawValue $minOsMapRef[$_]
                        $candidateParsed.Major -eq $newParsed.Major -and $candidateParsed.Release -eq $newParsed.Release
                    } | Select-Object -First 1
                }

                if ($matchedFromNew) {
                    $cmbMinOSRef.SelectedItem = $matchedFromNew
                    $lblMinOSStatusRef.Text = ""
                }
                elseif ($data.MinOSPropertyName) {
                    # This app has never had the NEW property set at all -
                    # only the legacy one (e.g. not touched since before
                    # Microsoft's switch). Pre-selects the dropdown's
                    # equivalent as a convenience, but says so plainly:
                    # saving from here sets the NEW property, which this
                    # app doesn't currently have.
                    $legacyParsed = Get-ParsedMinOsRelease -RawValue $data.MinOSPropertyName
                    $matchedFromLegacy = $minOsMapRef.Keys | Where-Object {
                        $candidateParsed = Get-ParsedMinOsRelease -RawValue $minOsMapRef[$_]
                        $candidateParsed.Major -eq $legacyParsed.Major -and $candidateParsed.Release -eq $legacyParsed.Release
                    } | Select-Object -First 1
                    if ($matchedFromLegacy) { $cmbMinOSRef.SelectedItem = $matchedFromLegacy }
                    $lblMinOSStatusRef.Text = "Intune only has the older property set (`"$(Get-FriendlyMinOsRelease -RawValue $data.MinOSPropertyName)`"). Saving here sets the current one instead."
                }
                else {
                    $lblMinOSStatusRef.Text = ""
                }

                # Compared against whatever was saved locally BEFORE this
                # fetch overwrote the fields above with live values - Intune
                # still wins as the actually-displayed value either way
                # (it's the current truth), but drift from the local copy
                # is worth surfacing rather than silently disappearing the
                # moment this dialog is opened.
                $diffFields = New-Object System.Collections.Generic.List[string]
                if ($localSnapshotRef) {
                    if (([string]$data.Description) -ne ([string]$localSnapshotRef.Description)) { $diffFields.Add("Description") }
                    if (([string]$data.Publisher) -ne ([string]$localSnapshotRef.Publisher)) { $diffFields.Add("Publisher") }
                    if (([string]$data.Owner) -ne ([string]$localSnapshotRef.Owner)) { $diffFields.Add("Owner") }
                    if (([string]$data.Developer) -ne ([string]$localSnapshotRef.Developer)) { $diffFields.Add("Developer") }
                    if (([string]$data.InformationUrl) -ne ([string]$localSnapshotRef.InformationUrl)) { $diffFields.Add("Information URL") }
                    if (([string]$data.PrivacyInformationUrl) -ne ([string]$localSnapshotRef.PrivacyUrl)) { $diffFields.Add("Privacy URL") }
                    if (([string]$data.Notes) -ne ([string]$localSnapshotRef.Notes)) { $diffFields.Add("Notes") }
                    if (([string]$data.InstallCommandLine) -ne ([string]$localSnapshotRef.InstallCommand)) { $diffFields.Add("Install command") }
                    if (([string]$data.UninstallCommandLine) -ne ([string]$localSnapshotRef.UninstallCommand)) { $diffFields.Add("Uninstall command") }
                    if (([string]$archSource) -ne ([string]$localSnapshotRef.Architecture)) { $diffFields.Add("Architecture") }
                    $liveDetSummary = if ($data.DetectionRule) { ConvertTo-DetectionRuleJson -DetectionRule $data.DetectionRule -IndentLevel 0 } else { "" }
                    if ($liveDetSummary -ne $localSnapshotRef.DetectionSummary) { $diffFields.Add("Detection rule") }
                    # "0" (local) and blank (Intune) are the SAME thing for
                    # these four - the same "0 = not required" convention
                    # the editor's own "Requirements (0 = not required)"
                    # label documents, and the exact same false-positive
                    # already fixed once in Get-CatalogMetadataFieldDiffs
                    # for the bulk Sync metadata flow - this single-app
                    # auto-fetch duplicates that comparison inline instead
                    # of reusing that function, so it needed the same fix
                    # applied here too, confirmed still broken live (a
                    # 3-field "diff" - Memory/Min. processors/Min. CPU
                    # speed, all local "0" vs Intune "(blank)" - for an app
                    # where nothing had actually changed).
                    $normalizeReq = { param($v) if ([string]$v -eq "0") { "" } else { [string]$v } }
                    if ((& $normalizeReq $data.MinDiskSpaceMB) -ne (& $normalizeReq $localSnapshotRef.MinDiskSpaceMB)) { $diffFields.Add("Disk space requirement") }
                    if ((& $normalizeReq $data.MinMemoryMB) -ne (& $normalizeReq $localSnapshotRef.MinMemoryMB)) { $diffFields.Add("Memory requirement") }
                    if ((& $normalizeReq $data.MinProcessors) -ne (& $normalizeReq $localSnapshotRef.MinProcessors)) { $diffFields.Add("Min. processors requirement") }
                    if ((& $normalizeReq $data.MinCpuSpeedMHz) -ne (& $normalizeReq $localSnapshotRef.MinCpuSpeedMHz)) { $diffFields.Add("Min. CPU speed requirement") }
                    if (([string]$data.InstallTimeMinutes) -ne ([string]$localSnapshotRef.InstallTimeMinutes)) { $diffFields.Add("Install time required") }
                    if (([string]$data.DeviceRestartBehavior) -ne ([string]$localSnapshotRef.DeviceRestartBehavior)) { $diffFields.Add("Device restart behavior") }
                    if (([string][bool]$data.AllowAvailableUninstall) -ne ([string]$localSnapshotRef.AllowAvailableUninstall)) { $diffFields.Add("Allow available uninstall") }
                    $liveReturnCodesSummary = if (@($data.ReturnCodes).Count -gt 0) { (@($data.ReturnCodes) | ConvertTo-Json -Compress -Depth 5) } else { "" }
                    if ($liveReturnCodesSummary -ne $localSnapshotRef.ReturnCodesSummary) { $diffFields.Add("Return codes") }

                    # Dependencies were already fetched live (right above,
                    # to repopulate the picker) and already held locally in
                    # $localSnapshotRef - comparing the two here means
                    # opening this dialog surfaces a dependency drift (e.g.
                    # something added/removed directly in Intune) the same
                    # way it already does for every other field, instead of
                    # needing a separate trip to "Intune Audit..."
                    # to notice it.
                    $liveDependenciesSorted = @($data.Dependencies) | Sort-Object
                    $localDependenciesSorted = @($localSnapshotRef.Dependencies) | Sort-Object
                    if (($liveDependenciesSorted -join "|") -ne ($localDependenciesSorted -join "|")) { $diffFields.Add("Dependencies") }

                    # Feeds the main grid's own "Last Audit" column - opening
                    # this dialog for an app now counts as a (partial) audit
                    # of it, same as a full "Intune Audit..." run
                    # would, just for Metadata/Dependencies only (this
                    # dialog has no Groups/Unknown Assignments check of its
                    # own - see the note on Get-GroupFieldDiffs's usage
                    # inside Show-IntuneAuditDialog for why that one stays
                    # bulk-tooling territory).
                    $metadataOnlyDiffCount = @($diffFields | Where-Object { $_ -ne "Dependencies" }).Count
                    $metadataStatus = if ($metadataOnlyDiffCount -eq 0) { "OK" } else { "$metadataOnlyDiffCount field(s) differ" }
                    $dependencyStatus = if ($diffFields -contains "Dependencies") { "Catalog and Intune differ" } else { "OK" }
                    Set-LastAuditCacheEntry -AppName $AppNameRef -Metadata $metadataStatus -Dependencies $dependencyStatus
                    Save-LastAuditCache
                }

                if ($archSource) {
                    $lblCreateStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                    $statusMsg = "Loaded current metadata from Intune - fields above now reflect what's actually live there."
                    if ($diffFields.Count -gt 0) {
                        $lblCreateStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                        $statusMsg += " Differs from the locally saved copy in: $($diffFields -join ', ')."
                    }
                    $lblCreateStatusRef.Text = $statusMsg
                }
                else {
                    # Two genuinely different situations were being shown
                    # as the same generic warning before this fix:
                    #   1. Intune explicitly has this set to "None" (shown
                    #      in the portal as "Check operating system
                    #      architecture: No") - a real, valid, intentional
                    #      setting meaning this app doesn't check
                    #      architecture at all. Not an error, and not
                    #      something this tool can currently reproduce -
                    #      there's no checkbox here for "none of the
                    #      above", only x86/x64/arm64 - but it deserves an
                    #      accurate message, not one implying the fetch
                    #      came back broken.
                    #   2. Genuinely missing/empty in BOTH fields - actually
                    #      unexpected, and the "select manually" guidance
                    #      still applies there.
                    $isExplicitlyNone = ($data.ApplicableArchitectures -eq "none") -or ($data.AllowedArchitectures -eq "none")
                    $lblCreateStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                    if ($isExplicitlyNone) {
                        $lblCreateStatusRef.Text = "This app is set to NOT check architecture at all in Intune (`"Check operating system architecture: No`"). This tool has no equivalent for that - only x86/x64/arm64 checkboxes - so none are pre-checked. Deploying an update through this tool requires picking at least one, which won't exactly match the original `"no check`" setting."
                    }
                    else {
                        # Genuinely no usable value in either field - surfaced
                        # directly here instead of leaving every architecture
                        # checkbox silently unchecked with no explanation, only
                        # to be discovered later via a confusing "check at least
                        # one" validation error on submit.
                        $lblCreateStatusRef.Text = "Loaded current metadata from Intune - but it didn't return a usable architecture value, so none are pre-checked below. Select the correct one(s) manually."
                    }
                }

                # Every field above already holds Intune's value - this only
                # offers a look at what actually differs and a way to pick
                # individual fields back to the local value, it never
                # changes the outcome on its own. Built as flat, explicit
                # per-field checks against $diffFields/$keepLocalFields
                # (not scriptblocks built inside a loop) - a closure built
                # per loop iteration to capture that iteration's own control
                # reference is exactly the class of bug already hunted down
                # elsewhere in this file (self-referencing/loop-captured
                # closures), so this sidesteps it entirely by never doing
                # that in the first place.
                if ($diffFields.Count -gt 0) {
                    $driftRows = New-Object System.Collections.Generic.List[object]
                    if ($diffFields -contains "Description")              { $driftRows.Add([pscustomobject]@{ Field = "Description"; Local = $localSnapshotRef.Description; Intune = [string]$data.Description }) }
                    if ($diffFields -contains "Publisher")                { $driftRows.Add([pscustomobject]@{ Field = "Publisher"; Local = $localSnapshotRef.Publisher; Intune = [string]$data.Publisher }) }
                    if ($diffFields -contains "Owner")                    { $driftRows.Add([pscustomobject]@{ Field = "Owner"; Local = $localSnapshotRef.Owner; Intune = [string]$data.Owner }) }
                    if ($diffFields -contains "Developer")                { $driftRows.Add([pscustomobject]@{ Field = "Developer"; Local = $localSnapshotRef.Developer; Intune = [string]$data.Developer }) }
                    if ($diffFields -contains "Information URL")         { $driftRows.Add([pscustomobject]@{ Field = "Information URL"; Local = $localSnapshotRef.InformationUrl; Intune = [string]$data.InformationUrl }) }
                    if ($diffFields -contains "Privacy URL")              { $driftRows.Add([pscustomobject]@{ Field = "Privacy URL"; Local = $localSnapshotRef.PrivacyUrl; Intune = [string]$data.PrivacyInformationUrl }) }
                    if ($diffFields -contains "Notes")                    { $driftRows.Add([pscustomobject]@{ Field = "Notes"; Local = $localSnapshotRef.Notes; Intune = [string]$data.Notes }) }
                    if ($diffFields -contains "Install command")          { $driftRows.Add([pscustomobject]@{ Field = "Install command"; Local = $localSnapshotRef.InstallCommand; Intune = [string]$data.InstallCommandLine }) }
                    if ($diffFields -contains "Uninstall command")        { $driftRows.Add([pscustomobject]@{ Field = "Uninstall command"; Local = $localSnapshotRef.UninstallCommand; Intune = [string]$data.UninstallCommandLine }) }
                    if ($diffFields -contains "Architecture")             { $driftRows.Add([pscustomobject]@{ Field = "Architecture"; Local = $localSnapshotRef.Architecture; Intune = [string]$archSource }) }
                    if ($diffFields -contains "Detection rule")           { $driftRows.Add([pscustomobject]@{ Field = "Detection rule"; Local = $localSnapshotRef.DetectionSummary; Intune = $liveDetSummary }) }
                    if ($diffFields -contains "Disk space requirement")   { $driftRows.Add([pscustomobject]@{ Field = "Disk space requirement"; Local = [string]$localSnapshotRef.MinDiskSpaceMB; Intune = [string]$data.MinDiskSpaceMB }) }
                    if ($diffFields -contains "Memory requirement")       { $driftRows.Add([pscustomobject]@{ Field = "Memory requirement"; Local = [string]$localSnapshotRef.MinMemoryMB; Intune = [string]$data.MinMemoryMB }) }
                    if ($diffFields -contains "Min. processors requirement")  { $driftRows.Add([pscustomobject]@{ Field = "Min. processors requirement"; Local = [string]$localSnapshotRef.MinProcessors; Intune = [string]$data.MinProcessors }) }
                    if ($diffFields -contains "Min. CPU speed requirement")   { $driftRows.Add([pscustomobject]@{ Field = "Min. CPU speed requirement"; Local = [string]$localSnapshotRef.MinCpuSpeedMHz; Intune = [string]$data.MinCpuSpeedMHz }) }
                    if ($diffFields -contains "Install time required")    { $driftRows.Add([pscustomobject]@{ Field = "Install time required"; Local = [string]$localSnapshotRef.InstallTimeMinutes; Intune = [string]$data.InstallTimeMinutes }) }
                    if ($diffFields -contains "Device restart behavior")  { $driftRows.Add([pscustomobject]@{ Field = "Device restart behavior"; Local = [string]$localSnapshotRef.DeviceRestartBehavior; Intune = [string]$data.DeviceRestartBehavior }) }
                    if ($diffFields -contains "Allow available uninstall") { $driftRows.Add([pscustomobject]@{ Field = "Allow available uninstall"; Local = [string]$localSnapshotRef.AllowAvailableUninstall; Intune = [string][bool]$data.AllowAvailableUninstall }) }
                    if ($diffFields -contains "Return codes")             { $driftRows.Add([pscustomobject]@{ Field = "Return codes"; Local = $localSnapshotRef.ReturnCodesSummary; Intune = $liveReturnCodesSummary }) }
                    if ($diffFields -contains "Dependencies") {
                        $localDepsText = if ($localDependenciesSorted.Count -gt 0) { $localDependenciesSorted -join ", " } else { "(none)" }
                        $liveDepsText = if ($liveDependenciesSorted.Count -gt 0) { $liveDependenciesSorted -join ", " } else { "(none)" }
                        $driftRows.Add([pscustomobject]@{ Field = "Dependencies"; Local = $localDepsText; Intune = $liveDepsText })
                    }

                    # Cached so $btnShowDiff can bring this exact compare
                    # dialog back up later without a fresh Intune fetch -
                    # see $lastDriftBox's own comment further up.
                    $lastDriftBoxRef.Rows = $driftRows.ToArray()
                    $lastDriftBoxRef.LocalSnapshot = $localSnapshotRef
                    $btnShowDiffRef.Visible = $true

                    $keepLocalFields = @(Show-MetadataDriftDialog -Rows $driftRows.ToArray())
                    if ($keepLocalFields.Count -gt 0) {
                        & $applyKeepLocalFieldsRef -KeepLocalFields $keepLocalFields -LocalSnapshot $localSnapshotRef
                    }
                }

                # Second pass, now that live Intune values (and any
                # per-field "keep local" reverts just above) have fully
                # settled. This is two closure levels removed from where
                # $updateCustomFieldHighlights is defined, so it must be
                # called through the fresh alias captured above - a plain
                # nested function is NOT reliably callable here (this is
                # what caused the real "Update-CustomFieldHighlights is
                # not recognized" crash).
                & $updateCustomFieldHighlightsRef
            }.GetNewClosure()
        }.GetNewClosure())
    }

    $dlg.CancelButton = $btnCancel
    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
    return $resultBox
}
