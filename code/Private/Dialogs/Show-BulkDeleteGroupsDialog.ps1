function Global:Show-BulkDeleteGroupsDialog {
    <#
      Delete several Entra ID groups at once.

      Deleting a group the catalog still assigns apps to breaks those
      assignments without saying so - the catalog keeps the name, and the
      next push to Intune fails on it - so every checked group is measured
      against the catalog first and the affected apps are named, not
      counted. Typing DELETE is the same confirmation the bulk delete from
      Intune asks for, and for the same reason: this cannot be undone.
    #>
    param([System.Windows.Forms.Form]$Owner)

    # No credentials check here, like the other dialogs of its kind: the
    # window opens either way and the actions refuse on their own, which
    # also keeps it reachable for the layout audit.
    $cache = $Global:App.EntraDirectoryCache
    $tenantId = $Global:App.GraphTenantId
    $clientId = $Global:App.GraphClientId
    $certThumb = $Global:App.GraphCertificateThumbprint

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Delete groups from Entra ID"
    $dlg.ClientSize = New-Object System.Drawing.Size(660, 650)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Tick the groups to delete from Entra ID. Groups still used by an app in this catalog are marked - deleting one breaks that app's assignment, and the catalog is not updated. Nothing is deleted until you confirm."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(630,52)
    $dlg.Controls.Add($lblIntro)

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(15,70)
    $txtSearch.Size = New-Object System.Drawing.Size(450,24)
    $dlg.Controls.Add($txtSearch)
    $searchTip = New-Object System.Windows.Forms.ToolTip
    $searchTip.SetToolTip($txtSearch, "Filters the list below. Filtering never changes what's ticked.")

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Location = New-Object System.Drawing.Point(475,69)
    $btnRefresh.Size = New-Object System.Drawing.Size(170,26)
    $dlg.Controls.Add($btnRefresh)
    $refreshTip = New-Object System.Windows.Forms.ToolTip
    $refreshTip.SetToolTip($btnRefresh, "Re-fetches the group list from Entra ID.")

    $clbGroups = New-Object System.Windows.Forms.CheckedListBox
    $clbGroups.Location = New-Object System.Drawing.Point(15,102)
    $clbGroups.Size = New-Object System.Drawing.Size(630,240)
    $clbGroups.CheckOnClick = $true
    $dlg.Controls.Add($clbGroups)

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Location = New-Object System.Drawing.Point(15,348)
    $lblCount.Size = New-Object System.Drawing.Size(630,20)
    $lblCount.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblCount)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,370)
    $lblStatus.Size = New-Object System.Drawing.Size(630,20)
    $dlg.Controls.Add($lblStatus)

    $lblConfirmPrompt = New-Object System.Windows.Forms.Label
    # The same convention as the bulk delete from Intune: typing the literal
    # word is deliberate friction in front of something irreversible.
    $lblConfirmPrompt.Text = "Type DELETE below to confirm:"
    $lblConfirmPrompt.Location = New-Object System.Drawing.Point(15,396)
    $lblConfirmPrompt.AutoSize = $true
    $dlg.Controls.Add($lblConfirmPrompt)

    $txtConfirm = New-Object System.Windows.Forms.TextBox
    $txtConfirm.Location = New-Object System.Drawing.Point(15,418)
    $txtConfirm.Size = New-Object System.Drawing.Size(630,24)
    $dlg.Controls.Add($txtConfirm)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,452)
    $rtbLog.Size = New-Object System.Drawing.Size(630,140)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete checked groups"
    $btnDelete.Location = New-Object System.Drawing.Point(415,604)
    $btnDelete.Size = New-Object System.Drawing.Size(140,32)
    $btnDelete.Enabled = $false
    $dlg.Controls.Add($btnDelete)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(565,604)
    $btnClose.Size = New-Object System.Drawing.Size(80,32)
    $dlg.Controls.Add($btnClose)

    # Ticks live here, not in the list: filtering rebuilds the list, and a
    # tick that disappears because someone typed in the search box is a tick
    # nobody agreed to lose.
    $checkedBox = @{ Value = (New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)) }
    $suppressBox = @{ Value = $false }
    $procBox = @{ Proc = $null }

    $UpdateCount = {
        $checkedCount = $checkedBox.Value.Count
        $lblCount.Text = "$checkedCount group(s) ticked."
        $btnDelete.Enabled = ($checkedCount -gt 0 -and $txtConfirm.Text.Trim().ToUpperInvariant() -eq 'DELETE' -and -not $procBox.Proc)
    }.GetNewClosure()

    $RefreshList = {
        $term = $txtSearch.Text.Trim()
        $suppressBox.Value = $true
        $clbGroups.BeginUpdate()
        try {
            $clbGroups.Items.Clear()
            $groups = @($cache | Where-Object { $_.type -eq "Group" })
            if ($term) { $groups = @($groups | Where-Object { $_.displayName -like "*$term*" }) }
            foreach ($g in ($groups | Sort-Object displayName | Select-Object -First 500)) {
                $name = [string]$g.displayName
                $usedBy = @(Get-CatalogAppsUsingGroup -GroupName $name)
                $label = if ($usedBy.Count -gt 0) { "$name   (used by $($usedBy.Count) app(s))" } else { $name }
                $index = $clbGroups.Items.Add($label)
                if ($checkedBox.Value.Contains($name)) { $clbGroups.SetItemChecked($index, $true) }
            }
        }
        finally {
            $clbGroups.EndUpdate()
            $suppressBox.Value = $false
        }
        & $UpdateCount
    }.GetNewClosure()

    # The label carries the usage note, so the name has to come back off it
    $NameFromLabel = { param($Label) (([string]$Label) -split '\s{3}\(used by ')[0] }.GetNewClosure()

    $clbGroups.Add_ItemCheck({
        param($s, $e)
        if ($suppressBox.Value) { return }
        $label = [string]$clbGroups.Items[$e.Index]
        $name = & $NameFromLabel $label
        # ItemCheck runs BEFORE the item's state changes, so $e.NewValue is
        # what it is about to become.
        if ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked) { [void]$checkedBox.Value.Add($name) }
        else { [void]$checkedBox.Value.Remove($name) }
        $dlg.BeginInvoke([Action]{ & $UpdateCount }) | Out-Null
    }.GetNewClosure())

    $txtSearch.Add_TextChanged({ & $RefreshList }.GetNewClosure())
    $txtConfirm.Add_TextChanged({ & $UpdateCount }.GetNewClosure())

    $btnRefresh.Add_Click({
        $btnRefresh.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Loading groups from Entra ID..."
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $dlgRef = $dlg
        $btnRefreshRef = $btnRefresh
        $lblStatusRef = $lblStatus
        $refreshListRef = $RefreshList
        Start-EntraDirectoryLookup -OnComplete {
            param($ok, $msg)
            $btnRefreshRef.Enabled = $true
            $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
            if ($ok) {
                & $refreshListRef
                $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                $lblStatusRef.Text = "Group list refreshed."
            }
            else {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblStatusRef.Text = "Could not refresh: $msg"
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnDelete.Add_Click({
        $names = @($checkedBox.Value)
        if ($names.Count -eq 0) { return }
        $plan = @(Get-GroupDeletionPlan -GroupNames $names)
        $warning = Format-GroupDeletionWarning -Plan $plan
        $r = [System.Windows.Forms.MessageBox]::Show($dlg,
            "$warning`r`n`r`nDelete them now?",
            "Delete $($plan.Count) group(s)", "YesNo", "Warning", "Button2")
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $btnDelete.Enabled = $false
        $btnRefresh.Enabled = $false
        $clbGroups.Enabled = $false
        $btnClose.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Deleting $($plan.Count) group(s)..."

        $configPath = Join-Path $env:TEMP (".intunepkg_groupdelete_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_groupdelete_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Mode                  = "DeleteMany"
            GroupName             = ""
            GroupNames            = @($plan | ForEach-Object { $_.Name })
            MemberIds             = @()
            OutputResultPath      = $resultPath
        }
        try {
            $configJsonText = $config | ConvertTo-Json -Depth 8 -ErrorAction Stop
            [System.IO.File]::WriteAllText($configPath, $configJsonText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Show-ConfigWriteFailedError -ErrorMessage $_.Exception.Message
            $btnRefresh.Enabled = $true; $clbGroups.Enabled = $true; $btnClose.Enabled = $true
            return
        }

        $dlgRef = $dlg
        $btnDeleteRef = $btnDelete
        $btnRefreshRef = $btnRefresh
        $btnCloseRef = $btnClose
        $clbGroupsRef = $clbGroups
        $lblStatusRef = $lblStatus
        $txtConfirmRef = $txtConfirm
        $checkedBoxRef = $checkedBox
        $procBoxRef = $procBox
        $configPathRef = $configPath
        $resultPathRef = $resultPath
        $refreshListRef = $RefreshList
        $updateCountRef = $UpdateCount
        $deletedNames = @($plan | ForEach-Object { $_.Name })

        $procBox.Proc = Start-PipelineProcess -ScriptContent $Global:App.EmbeddedGroupManagerScript -TempScriptName ".intunepkg_embedded_groupdelete.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue
            if ($dlgRef.IsDisposed) { return }
            $btnRefreshRef.Enabled = $true
            $clbGroupsRef.Enabled = $true
            $btnCloseRef.Enabled = $true
            $errorMessage = ''
            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content $resultPathRef -Raw -Encoding UTF8 | ConvertFrom-Json
                    if (-not $result.success) { $errorMessage = [string]$result.errorMessage }
                }
                catch { }
                Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
            }
            if ($code -eq 0 -and -not $errorMessage) {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                $lblStatusRef.Text = "Deleted $($deletedNames.Count) group(s)."
                # They're gone, so nothing should still be ticked for them
                foreach ($gone in $deletedNames) { [void]$checkedBoxRef.Value.Remove($gone) }
            }
            else {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblStatusRef.Text = if ($errorMessage) { "Not everything was deleted - see the log below." } else { "Deleting failed - see the log below." }
            }
            # The directory cache still lists what was just deleted
            Start-EntraDirectoryLookup -OnComplete {
                param($ok, $msg)
                if (-not $dlgRef.IsDisposed) { & $refreshListRef }
            }.GetNewClosure()
            $txtConfirmRef.Text = ""
            & $updateCountRef
        }.GetNewClosure()
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    Register-CloseConfirmation -Dialog $dlg -GetQuestion {
        if ($procBox.Proc) { return @{ Title = "Stop and close?"; Text = "Groups are still being deleted. Stop and close anyway?" } }
        return $null
    }.GetNewClosure() -OnConfirmed {
        if ($procBox.Proc) { try { $procBox.Proc.Kill() } catch { } }
    }.GetNewClosure()

    & $RefreshList
    if (@($cache | Where-Object { $_.type -eq "Group" }).Count -eq 0) {
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblStatus.Text = "No groups loaded yet - click Refresh to fetch them from Entra ID."
    }

    if ($Owner) { [void]$dlg.ShowDialog($Owner) } else { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
}
