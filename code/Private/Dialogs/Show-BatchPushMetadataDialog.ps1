function Global:Show-BatchPushMetadataDialog {
    <#
      "Push metadata" for several apps at once: the catalog is right about
      their metadata and Intune has drifted.

      Two steps, both in this one window. First it compares - the same
      bulk fetch the audit uses, read-only - and lists each app with the
      fields that differ, ticked. Then "Push" sends the ticked apps' saved
      catalog metadata to Intune, one app at a time, through the same
      UpdateMetadata run Batch edit Intune fields uses. An app that
      already matches starts unticked; nothing is sent that was not shown.

      Groups are not part of this. They have their own Push.
    #>
    param([int[]]$ScopedIndices = @())

    # Plain local aliases - see note in Start-IntuneAppLookup.
    $appsRef      = $Global:App.Apps
    $tenantId     = $Global:App.GraphTenantId
    $clientId     = $Global:App.GraphClientId
    $certThumb    = $Global:App.GraphCertificateThumbprint
    $syncScript   = $Global:App.EmbeddedSyncMetadataScript
    $createScript = $Global:App.EmbeddedCreateAppScript

    # Which apps can be pushed at all, and why the others cannot - listed
    # either way, so an app does not just vanish from what was selected.
    $entries = New-Object System.Collections.Generic.List[object]
    # Results come back from Intune keyed by app name, so two selected
    # apps with the same name cannot both be told apart - the second is
    # listed but not compared or pushed.
    $namesSeen = @{}
    foreach ($idx in @($ScopedIndices | Sort-Object -Unique)) {
        $app = $appsRef[$idx]
        if (-not $app) { continue }
        $skip = if ($namesSeen.ContainsKey([string]$app.appName)) { "Another selected app has the same name - push this one on its own." }
                elseif (-not $app.appId) { "Not in Intune yet - use Deploy to Intune." }
                elseif (-not $app.metadata) { "No saved metadata to push - Pull from Intune or open Deploy to Intune first." }
                elseif ($app.intuneAppType -and $app.intuneAppType -ne "Windows app (Win32)") { "A $($app.intuneAppType) app - this tool only updates Win32 apps." }
                else { "" }
        $namesSeen[[string]$app.appName] = $true
        $entries.Add([pscustomobject]@{ Index = $idx; App = $app; Skip = $skip })
    }
    if (@($entries | Where-Object { -not $_.Skip }).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("None of the selected apps can have their metadata pushed:`n`n" + (($entries | ForEach-Object { "$($_.App.appName): $($_.Skip)" }) -join "`n"), "Nothing to push", "OK", "Information") | Out-Null
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Push metadata to Intune - $($entries.Count) app(s)"
    $dlg.ClientSize = New-Object System.Drawing.Size(900, 620)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(720, 480)
    $dlg.MaximizeBox = $true
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Sends each ticked app's saved catalog metadata to Intune - commands, detection, requirements, return codes, dependencies. Groups are not touched, and a field left blank in the catalog keeps Intune's value. Apps are compared with Intune before and after; hovering a row shows both values."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(870,48)
    $lblIntro.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($lblIntro)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.AutoEllipsis = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $lblStatus.Location = New-Object System.Drawing.Point(15,64)
    $lblStatus.Size = New-Object System.Drawing.Size(870,20)
    $lblStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($lblStatus)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(15,88)
    $progress.Size = New-Object System.Drawing.Size(870,6)
    $progress.Style = "Marquee"
    $progress.MarqueeAnimationSpeed = 30
    $progress.Visible = $false
    $progress.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($progress)

    $grid = New-Object System.Windows.Forms.DataGridView
    Set-AppGridStyle -Grid $grid
    $grid.Name = 'grdPushMetadata'
    $grid.Location = New-Object System.Drawing.Point(15,100)
    $grid.Size = New-Object System.Drawing.Size(870,300)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.AllowUserToDeleteRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = "Fill"
    $colPush = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colPush.Name = "Push"; $colPush.HeaderText = "Push"; $colPush.FillWeight = 7; $colPush.MinimumWidth = 50
    [void]$grid.Columns.Add($colPush)
    $colApp = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colApp.Name = "App"; $colApp.HeaderText = "App"; $colApp.FillWeight = 28; $colApp.ReadOnly = $true
    [void]$grid.Columns.Add($colApp)
    $colDiff = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDiff.Name = "Differs"; $colDiff.HeaderText = "Differs from Intune"; $colDiff.FillWeight = 50; $colDiff.ReadOnly = $true
    [void]$grid.Columns.Add($colDiff)
    $colResult = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colResult.Name = "Result"; $colResult.HeaderText = "Result"; $colResult.FillWeight = 15; $colResult.ReadOnly = $true
    [void]$grid.Columns.Add($colResult)
    $dlg.Controls.Add($grid)

    # Row per app, keyed by name for the results coming back.
    $rowByName = @{}
    foreach ($entry in $entries) {
        $rIdx = $grid.Rows.Add($false, $entry.App.appName, $(if ($entry.Skip) { $entry.Skip } else { "(comparing...)" }), "")
        $row = $grid.Rows[$rIdx]
        $row.Tag = $entry
        # A row that cannot be pushed cannot be ticked either (see
        # CellBeginEdit below).
        if ($entry.Skip) { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray }
        # The first row of a name is the one compared (see $namesSeen).
        if (-not $rowByName.ContainsKey([string]$entry.App.appName)) { $rowByName[[string]$entry.App.appName] = $row }
    }

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,410)
    $rtbLog.Size = New-Object System.Drawing.Size(870,150)
    $rtbLog.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnPush = New-Object System.Windows.Forms.Button
    $btnPush.Name = 'btnPushTicked'
    $btnPush.Text = "Push"
    $btnPush.Location = New-Object System.Drawing.Point(605,574)
    $btnPush.Size = New-Object System.Drawing.Size(190,32)
    $btnPush.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnPush.Enabled = $false
    $dlg.Controls.Add($btnPush)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(805,574)
    $btnClose.Size = New-Object System.Drawing.Size(80,32)
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnClose)
    $dlg.CancelButton = $btnClose

    $tips = New-Object System.Windows.Forms.ToolTip
    $tips.SetToolTip($btnPush, "Sends the ticked apps' catalog metadata to Intune, one at a time. Apps already matching Intune start unticked.")

    # Running state, shared by every handler below: which process is live
    # (so closing can stop it), and whether a compare or push is under way.
    $procBox = @{ Proc = $null }
    $busyBox = @{ Value = $false }

    $updatePushButton = {
        $ticked = 0
        foreach ($r in $grid.Rows) { if ([bool]$r.Cells['Push'].Value) { $ticked++ } }
        $btnPush.Text = if ($ticked -eq 1) { "Push 1 app to Intune" } else { "Push $ticked apps to Intune" }
        $btnPush.Enabled = (-not $busyBox.Value) -and $ticked -gt 0
    }.GetNewClosure()
    # A ticked box only counts once it is committed, which a DataGridView
    # does on leaving the cell - committed at once here, so the button's
    # count follows each click.
    $grid.Add_CurrentCellDirtyStateChanged({
        if ($grid.IsCurrentCellDirty) { $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
    }.GetNewClosure())
    $grid.Add_CellValueChanged({ & $updatePushButton }.GetNewClosure())
    # One place decides what can be ticked: never a row that cannot be
    # pushed, and nothing at all while a compare or push is running over
    # the list. (Per-cell ReadOnly would be undone by any later change to
    # the grid's own ReadOnly.)
    $grid.Add_CellBeginEdit({
        param($s, $e)
        if ($busyBox.Value -or $grid.Rows[$e.RowIndex].Tag.Skip) { $e.Cancel = $true }
    }.GetNewClosure())

    # --- Step 1: compare, read-only ---
    $runCompare = {
        $toCompare = @($entries | Where-Object { -not $_.Skip })
        # Run again after a push, too - so no row may keep what the last
        # compare said about it while this one is out asking.
        foreach ($r in $grid.Rows) {
            if ($r.Tag.Skip) { continue }
            $r.Cells['Differs'].Value = "(comparing...)"
            $r.Cells['Differs'].ToolTipText = ""
        }
        $busyBox.Value = $true
        $progress.Visible = $true
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Comparing $($toCompare.Count) app(s) with Intune..."
        & $updatePushButton

        $configPath = Join-Path $env:TEMP (".intunepkg_pushmeta_compare_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_pushmeta_compare_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Apps                  = @($toCompare | ForEach-Object { [pscustomobject]@{ AppName = $_.App.appName; AppId = $_.App.appId } })
            OutputResultPath      = $resultPath
        }
        try {
            [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10 -ErrorAction Stop), (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Show-ConfigWriteFailedError -ErrorMessage $_.Exception.Message
            $busyBox.Value = $false
            $progress.Visible = $false
            return
        }

        # Fresh aliases for the nested -OnComplete closure - see note at
        # the top of Show-CreateInIntuneDialog for why this matters.
        $dlgRef = $dlg
        $gridRef = $grid
        $rowByNameRef = $rowByName
        $lblStatusRef = $lblStatus
        $progressRef = $progress
        $busyBoxRef = $busyBox
        $procBoxRef = $procBox
        $updatePushButtonRef = $updatePushButton
        $configPathRef = $configPath
        $resultPathRef = $resultPath

        $procBox.Proc = Start-PipelineProcess -ScriptContent $syncScript -TempScriptName ".intunepkg_embedded_pushmeta_compare.ps1" -ArgumentString "-ConfigPath `"$configPath`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            $busyBoxRef.Value = $false
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue
            if ($dlgRef.IsDisposed) { return }
            $progressRef.Visible = $false

            $result = $null
            try {
                if (Test-Path $resultPathRef) {
                    $result = Get-Content -Path $resultPathRef -Raw -Encoding UTF8 | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                }
            }
            catch { $result = $null }
            if (-not $result -or -not $result.success) {
                $why = if ($result -and $result.error) { $result.error } else { "no result written (exit code $code)" }
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblStatusRef.Text = "Could not compare with Intune: $why"
                foreach ($r in $gridRef.Rows) {
                    if ([string]$r.Cells['Differs'].Value -eq "(comparing...)") { $r.Cells['Differs'].Value = "Not compared" }
                }
                & $updatePushButtonRef
                return
            }

            $differCount = 0
            foreach ($one in @($result.results)) {
                $row = $rowByNameRef[[string]$one.AppName]
                if (-not $row) { continue }
                $catalogApp = $row.Tag.App
                if (-not $one.Success) {
                    $row.Cells['Differs'].Value = "Could not read from Intune: $($one.Error)"
                    continue
                }
                # The catalog may not know the app's type yet (never
                # synced), but Intune does. An update is a Win32 PATCH, and
                # sending one to a Store or M365 app only fails at Graph.
                $liveType = Get-FriendlyIntuneAppType -ODataType ([string]$one.OdataType)
                if ($liveType -and $liveType -ne "Windows app (Win32)") {
                    $row.Tag.Skip = "A $liveType app in Intune - this tool only updates Win32 apps."
                    $row.Cells['Differs'].Value = $row.Tag.Skip
                    $row.Cells['Push'].Value = $false
                    $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
                    continue
                }
                $diffs = New-Object System.Collections.Generic.List[object]
                foreach ($d in @(Get-CatalogMetadataFieldDiffs -Local $catalogApp.metadata -Remote $one.Metadata -OdataType $one.OdataType)) { $diffs.Add($d) }
                $liveDeps = @($one.Metadata.dependencies) | Sort-Object
                $localDeps = @($catalogApp.metadata.dependencies) | Sort-Object
                if (($liveDeps -join "|") -ne ($localDeps -join "|")) {
                    $diffs.Add([pscustomobject]@{ Field = "Dependencies"; Local = ($localDeps -join ", "); Remote = ($liveDeps -join ", ") })
                }
                if ($diffs.Count -eq 0) {
                    $row.Cells['Differs'].Value = "Already matches Intune"
                    $row.Cells['Push'].Value = $false
                    continue
                }
                $differCount++
                $row.Cells['Differs'].Value = "$($diffs.Count) field(s): $(($diffs | ForEach-Object { $_.Field }) -join ', ')"
                # Both values per field, on hover - too long for a cell.
                $row.Cells['Differs'].ToolTipText = ($diffs | ForEach-Object {
                    $l = if ([string]$_.Local) { [string]$_.Local } else { "(blank)" }
                    $r = if ([string]$_.Remote) { [string]$_.Remote } else { "(blank)" }
                    "$($_.Field)`n  catalog: $l`n  Intune:  $r"
                }) -join "`n"
                $row.Cells['Push'].Value = $true
            }
            foreach ($r in $gridRef.Rows) {
                if ([string]$r.Cells['Differs'].Value -eq "(comparing...)") { $r.Cells['Differs'].Value = "No answer from Intune" }
            }
            $lblStatusRef.ForeColor = if ($differCount -gt 0) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::SeaGreen }
            $lblStatusRef.Text = if ($differCount -gt 0) { "$differCount app(s) differ from Intune and are ticked. Untick any you don't want to push, then Push." } else { "Every app already matches Intune - nothing to push." }
            & $updatePushButtonRef
        }.GetNewClosure()
    }.GetNewClosure()

    # --- Step 2: push the ticked apps, one at a time ---
    $RunNextBox = @{ Value = $null }
    $RunNextBox.Value = {
        param($Queue, [int]$QueueIndex, [int]$Pushed, [int]$Failed)

        if ($QueueIndex -ge $Queue.Count) {
            $busyBox.Value = $false
            $progress.Visible = $false
            Write-DialogLogLine -LogBox $rtbLog -Text "`r`n[INFO] Done - $Pushed pushed, $Failed failed. Comparing with Intune again...`r`n"
            # Read back what Intune has now, the same read-only compare the
            # window opened with - each row then says whether it matches,
            # including anything a push cannot change.
            & $runCompare
            return
        }

        $row = $Queue[$QueueIndex]
        $app = $row.Tag.App
        $m = $app.metadata
        $row.Cells['Result'].Value = "Pushing..."
        $lblStatus.Text = "Pushing $($QueueIndex + 1) of $($Queue.Count): $($app.appName)..."
        Write-DialogLogLine -LogBox $rtbLog -Text "`r`n[$($QueueIndex + 1)/$($Queue.Count)] $($app.appName)`r`n" -MirrorToMainLog

        $depIds = New-Object System.Collections.Generic.List[string]
        foreach ($depName in @($m.dependencies)) {
            if (-not $depName -or $depName -eq $app.appName) { continue }
            $depApp = @($appsRef | Where-Object { $_.appName -eq $depName }) | Select-Object -First 1
            if ($depApp -and $depApp.appId) { $depIds.Add([string]$depApp.appId) }
            else { Write-DialogLogLine -LogBox $rtbLog -Text "  [SKIPPED] Dependency `"$depName`" has no App ID yet - skipping just that dependency.`r`n" -MirrorToMainLog }
        }

        $configPath = Join-Path $env:TEMP (".intunepkg_pushmeta_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_pushmeta_result_" + [guid]::NewGuid().ToString("N") + ".json")
        # The app's saved catalog metadata, whole - UpdateMetadata PATCHes
        # the full win32LobApp shape (same config Batch edit builds, with
        # no changes laid over it).
        $config = [pscustomobject]@{
            TenantId                = $tenantId
            ClientId                = $clientId
            CertificateThumbprint   = $certThumb
            Mode                    = "UpdateMetadata"
            ExistingAppId           = $app.appId
            AppName                 = $app.appName
            Description             = $m.description
            Publisher               = $m.publisher
            Owner                   = $m.owner
            Developer               = $m.developer
            InformationUrl          = $m.informationUrl
            PrivacyUrl              = $m.privacyUrl
            Notes                   = $m.notes
            InstallCommand          = $m.installCommand
            UninstallCommand        = $m.uninstallCommand
            DetectionRule           = $m.detectionRule
            InstallContext          = $m.installContext
            Architecture            = $m.architecture
            MinOSVersionKey         = $m.minOSKey
            MinDiskSpaceMB          = $m.minDiskSpaceMB
            MinMemoryMB             = $m.minMemoryMB
            MinProcessors           = $m.minProcessors
            MinCpuSpeedMHz          = $m.minCpuSpeedMHz
            InstallTimeMinutes      = $m.installTimeMinutes
            DeviceRestartBehavior   = $m.deviceRestartBehavior
            AllowAvailableUninstall = $m.allowAvailableUninstall
            ReturnCodes             = @($m.returnCodes)
            PackagePath             = ""
            DependencyAppIds        = @($depIds)
            ReplaceContent          = $false
            OutputResultPath        = $resultPath
        }
        try {
            [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10 -ErrorAction Stop), (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            $row.Cells['Result'].Value = "Failed"
            Write-DialogLogLine -LogBox $rtbLog -Text "  [FAILED] Could not write the settings file: $($_.Exception.Message)`r`n" -MirrorToMainLog
            & $RunNextBox.Value $Queue ($QueueIndex + 1) $Pushed ($Failed + 1)
            return
        }

        # Fresh aliases for the nested -OnComplete closure.
        $rowRef = $row
        $appRef = $app
        $queueRef = $Queue
        $queueIndexRef = $QueueIndex
        $pushedRef = $Pushed
        $failedRef = $Failed
        $configPathRef = $configPath
        $resultPathRef = $resultPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $dlgRef = $dlg
        $RunNextBoxRef = $RunNextBox

        $procBox.Proc = Start-PipelineProcess -ScriptContent $createScript -TempScriptName ".intunepkg_embedded_pushmeta.ps1" -ArgumentString "-ConfigPath `"$configPath`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue
            $ok = $false
            $message = "No result written (exit code $code)."
            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw -Encoding UTF8 | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) { $ok = $true } else { $message = [string]$result.error }
                }
                catch { $message = "Could not read result: $($_.Exception.Message)" }
            }
            if ($ok) {
                # Nothing is written to Last Audit here. "Pushed" is not
                # "matches": the update leaves a field that is blank in the
                # catalog as it is in Intune, and a dependency it could not
                # set is a warning, not a failure. The compare that runs
                # when the queue ends is what says whether they match now.
                Write-DialogLogLine -LogBox $rtbLogRef -Text "  [OK] Pushed.`r`n" -MirrorToMainLog
            }
            else {
                Write-DialogLogLine -LogBox $rtbLogRef -Text "  [FAILED] $message`r`n" -MirrorToMainLog
            }
            if ($dlgRef.IsDisposed) { return }
            $rowRef.Cells['Result'].Value = if ($ok) { "Pushed" } else { "Failed" }
            $rowRef.Cells['Result'].ToolTipText = if ($ok) { "" } else { $message }
            if ($ok) { $rowRef.Cells['Push'].Value = $false }
            & $RunNextBoxRef.Value $queueRef ($queueIndexRef + 1) ($pushedRef + [int]$ok) ($failedRef + [int](-not $ok))
        }.GetNewClosure()
    }.GetNewClosure()

    $btnPush.Add_Click({
        $queue = @($grid.Rows | Where-Object { [bool]$_.Cells['Push'].Value -and -not $_.Tag.Skip })
        if ($queue.Count -eq 0) { return }
        $names = @($queue | ForEach-Object { [string]$_.Cells['App'].Value })
        $shown = (@($names | Select-Object -First 15) -join "`n") + $(if ($names.Count -gt 15) { "`n...and $($names.Count - 15) more" })
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Replace the metadata of $($queue.Count) app(s) in Intune with what the catalog has?`n`n$shown`n`nGroups are not changed.",
            "Push metadata to Intune", "YesNo", "Warning", "Button2")
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $busyBox.Value = $true
        $progress.Visible = $true
        # No ticking and unticking while the queue runs over them - see
        # CellBeginEdit, which reads $busyBox.
        $grid.EndEdit()
        & $updatePushButton
        & $RunNextBox.Value $queue 0 0 0
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.Add_FormClosing({
        param($s, $e)
        if (-not $busyBox.Value) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show("Still working. Stop and close? An app being pushed right now may or may not be updated.", "Still running", "YesNo", "Warning", "Button2")
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
        try { if ($procBox.Proc -and -not $procBox.Proc.HasExited) { $procBox.Proc.Kill() } } catch { }
    }.GetNewClosure())

    # Compared as soon as the window is up - it only reads, and a list of
    # apps with nothing said about them is no help in deciding what to push.
    $dlg.Add_Shown({ & $runCompare }.GetNewClosure())

    Set-Theme -Control $dlg
    & $updatePushButton
    [void]$dlg.ShowDialog($Global:App.Form)
    $dlg.Dispose()
    Update-Grid
}
