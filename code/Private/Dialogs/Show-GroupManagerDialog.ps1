function Global:Show-GroupManagerDialog {
    # Plain local aliases - see note in Start-IntuneAppLookup.
    $tenantId       = $Global:App.GraphTenantId
    $clientId       = $Global:App.GraphClientId
    $certThumb      = $Global:App.GraphCertificateThumbprint
    $gmScript       = $Global:App.EmbeddedGroupManagerScript
    $cacheRef       = $Global:App.EntraDirectoryCache
    $appsRef        = $Global:App.Apps
    $linkedFilePath = $Global:App.LinkedFilePath
    $unsavedBoxRef  = $Global:App.UnsavedChangesBox

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Group manager"
    $dlg.ClientSize = New-Object System.Drawing.Size(620, 600)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Creates a security group (or reuses one with this exact name). Shows current members on the left to review/remove. Load/Search a group, then Rename group updates Entra ID and the whole catalog together."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(590,32)
    $dlg.Controls.Add($lblIntro)

    $lblGroupName = New-Object System.Windows.Forms.Label
    $lblGroupName.Text = "Group name"
    $lblGroupName.Location = New-Object System.Drawing.Point(15,50)
    $lblGroupName.AutoSize = $true
    $dlg.Controls.Add($lblGroupName)

    $txtGroupName = New-Object System.Windows.Forms.TextBox
    $txtGroupName.Location = New-Object System.Drawing.Point(15,69)
    $txtGroupName.Size = New-Object System.Drawing.Size(473,24)
    $dlg.Controls.Add($txtGroupName)

    $btnSearchGroup = New-Object System.Windows.Forms.Button
    $btnSearchGroup.Text = "Search..."
    $btnSearchGroup.Location = New-Object System.Drawing.Point(498,68)
    $btnSearchGroup.Size = New-Object System.Drawing.Size(107,26)
    $dlg.Controls.Add($btnSearchGroup)

    $lblDescription = New-Object System.Windows.Forms.Label
    $lblDescription.Text = "Description (optional)"
    $lblDescription.Location = New-Object System.Drawing.Point(15,104)
    $lblDescription.AutoSize = $true
    $dlg.Controls.Add($lblDescription)

    $txtDescription = New-Object System.Windows.Forms.TextBox
    $txtDescription.Location = New-Object System.Drawing.Point(15,123)
    $txtDescription.Size = New-Object System.Drawing.Size(590,48)
    $txtDescription.Multiline = $true
    $dlg.Controls.Add($txtDescription)

    # Left column - current, actual members (fetched live). Right column -
    # members queued up to add on the next Create/Update. Kept as two
    # visually separate lists rather than one merged view, since "what's
    # really there right now" and "what you're about to change" are
    # different things and conflating them invites mistakes.
    $lblCurrentMembers = New-Object System.Windows.Forms.Label
    $lblCurrentMembers.Text = "Current members"
    $lblCurrentMembers.Location = New-Object System.Drawing.Point(15,181)
    $lblCurrentMembers.AutoSize = $true
    $dlg.Controls.Add($lblCurrentMembers)

    $lstCurrentMembers = New-Object System.Windows.Forms.ListBox
    $lstCurrentMembers.Location = New-Object System.Drawing.Point(15,201)
    $lstCurrentMembers.Size = New-Object System.Drawing.Size(290,140)
    $dlg.Controls.Add($lstCurrentMembers)

    $btnLoadMembers = New-Object System.Windows.Forms.Button
    $btnLoadMembers.Text = "Load members"
    $btnLoadMembers.Location = New-Object System.Drawing.Point(15,345)
    $btnLoadMembers.Size = New-Object System.Drawing.Size(130,28)
    $dlg.Controls.Add($btnLoadMembers)

    $btnRemoveCurrentMember = New-Object System.Windows.Forms.Button
    $btnRemoveCurrentMember.Text = "Remove member..."
    $btnRemoveCurrentMember.Location = New-Object System.Drawing.Point(155,345)
    $btnRemoveCurrentMember.Size = New-Object System.Drawing.Size(150,28)
    $dlg.Controls.Add($btnRemoveCurrentMember)

    $lblMembers = New-Object System.Windows.Forms.Label
    $lblMembers.Text = "Members to add"
    $lblMembers.Location = New-Object System.Drawing.Point(315,181)
    $lblMembers.AutoSize = $true
    $dlg.Controls.Add($lblMembers)

    $lstMembers = New-Object System.Windows.Forms.ListBox
    $lstMembers.Location = New-Object System.Drawing.Point(315,201)
    $lstMembers.Size = New-Object System.Drawing.Size(290,140)
    $dlg.Controls.Add($lstMembers)

    $btnAddMember = New-Object System.Windows.Forms.Button
    $btnAddMember.Text = "+ Add member..."
    $btnAddMember.Location = New-Object System.Drawing.Point(315,345)
    $btnAddMember.Size = New-Object System.Drawing.Size(140,28)
    $dlg.Controls.Add($btnAddMember)

    $btnRemoveMember = New-Object System.Windows.Forms.Button
    $btnRemoveMember.Text = "Remove selected"
    $btnRemoveMember.Location = New-Object System.Drawing.Point(465,345)
    $btnRemoveMember.Size = New-Object System.Drawing.Size(140,28)
    $dlg.Controls.Add($btnRemoveMember)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,381)
    $lblStatus.Size = New-Object System.Drawing.Size(590,40)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,423)
    $rtbLog.Size = New-Object System.Drawing.Size(590,120)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnDeleteGroup = New-Object System.Windows.Forms.Button
    $btnDeleteGroup.Text = "Delete group..."
    $btnDeleteGroup.Location = New-Object System.Drawing.Point(15,553)
    $btnDeleteGroup.Size = New-Object System.Drawing.Size(150,32)
    $dlg.Controls.Add($btnDeleteGroup)

    $btnRenameGroup = New-Object System.Windows.Forms.Button
    $btnRenameGroup.Text = "Rename group..."
    $btnRenameGroup.Location = New-Object System.Drawing.Point(175,553)
    $btnRenameGroup.Size = New-Object System.Drawing.Size(140,32)
    $dlg.Controls.Add($btnRenameGroup)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Create / Update Group"
    $btnRun.Location = New-Object System.Drawing.Point(420,553)
    $btnRun.Size = New-Object System.Drawing.Size(185,32)
    $dlg.Controls.Add($btnRun)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(325,553)
    $btnClose.Size = New-Object System.Drawing.Size(85,32)
    $dlg.Controls.Add($btnClose)

    # Parallel to $lstCurrentMembers.Items - index N here is the resolved
    # Object ID for whatever's at index N, as of the last Load.
    $currentMemberIds = New-Object System.Collections.Generic.List[string]
    $currentGroupIdBox = @{ Value = $null }

    # Parallel to $lstMembers.Items - index N here is the resolved Object ID
    # for whatever display text is at index N in the listbox.
    $pendingMemberIds = New-Object System.Collections.Generic.List[string]
    $procBox = @{ Proc = $null }

    # Stored closure so both btnLoadMembers and (after picking via Search,
    # or after a successful removal) other handlers can reuse the exact same
    # fetch-and-populate logic rather than duplicating it.
    $LoadCurrentMembers = {
        $groupName = $txtGroupName.Text.Trim()
        if (-not $groupName) { return }
        $btnLoadMembers.Enabled = $false
        $btnRemoveCurrentMember.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Loading current members..."
        # Start-GroupMembersFetch has no cursor handling of its own - this
        # dialog gave no visible loading feedback beyond the status label.
        # Same fix as the other dialogs that hit this (Show-CreateInIntuneDialog,
        # Show-AppEditor, Show-DiagnosticsDialog, Show-EntraMemberPicker,
        # Show-GroupOnlyPicker).
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $dlgRef = $dlg
        $btnLoadMembersRef = $btnLoadMembers
        $btnRemoveCurrentMemberRef = $btnRemoveCurrentMember
        $lblStatusRef = $lblStatus
        $lstCurrentMembersRef = $lstCurrentMembers
        $currentMemberIdsRef = $currentMemberIds
        $currentGroupIdBoxRef = $currentGroupIdBox
        $groupNameRef = $groupName
        $txtDescriptionRef = $txtDescription

        Start-GroupMembersFetch -GroupName $groupNameRef -OnComplete {
            param($ok, $errMsg, $data)
            try {
            $btnLoadMembersRef.Enabled = $true
            $lstCurrentMembersRef.Items.Clear()
            $currentMemberIdsRef.Clear()
            $currentGroupIdBoxRef.Value = $null

            if (-not $ok) {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblStatusRef.Text = "Could not load members: $errMsg"
                return
            }
            if (-not $data.Found) {
                $lblStatusRef.ForeColor = [System.Drawing.Color]::DarkOrange
                $lblStatusRef.Text = "No group named `"$groupNameRef`" exists yet - nothing to load."
                return
            }
            $currentGroupIdBoxRef.Value = $data.GroupId
            $txtDescriptionRef.Text = $data.Description
            foreach ($m in @($data.Members)) {
                [void]$lstCurrentMembersRef.Items.Add("[$($m.type)] $($m.displayName)")
                $currentMemberIdsRef.Add($m.id)
            }
            $btnRemoveCurrentMemberRef.Enabled = ($currentMemberIdsRef.Count -gt 0)
            $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
            $lblStatusRef.Text = "Loaded $($currentMemberIdsRef.Count) current member(s) and description."
            }
            finally {
                # Cursor + Cursor.Current + DoEvents + a Position
                # self-assignment - see Show-WingetSearchDialog's own note
                # on why all four are needed for a reliable reset.
                $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
                [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
                [System.Windows.Forms.Application]::DoEvents()
                [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
            }
        }.GetNewClosure()
    }.GetNewClosure()

    $btnLoadMembers.Add_Click({ & $LoadCurrentMembers }.GetNewClosure())

    $txtGroupName.Add_TextChanged({
        # The loaded members belonged to whatever name was in this field
        # before - the moment that name changes, they're potentially
        # describing a different group entirely (or nothing, if this is now
        # a brand new name to create), so clear them rather than leave a
        # stale, misleading list sitting under a name it no longer matches.
        if ($currentGroupIdBox.Value -or $lstCurrentMembers.Items.Count -gt 0) {
            $lstCurrentMembers.Items.Clear()
            $currentMemberIds.Clear()
            $currentGroupIdBox.Value = $null
            $btnRemoveCurrentMember.Enabled = $false
            $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
            $lblStatus.Text = "Name changed - click Load members to see this group's current members."
        }
    }.GetNewClosure())

    $btnSearchGroup.Add_Click({
        $picked = Show-GroupOnlyPicker
        if ($picked) {
            $txtGroupName.Text = $picked
            & $LoadCurrentMembers
        }
    }.GetNewClosure())

    $btnAddMember.Add_Click({
        $pickedName = Show-EntraMemberPicker
        if (-not $pickedName) { return }
        $match = $cacheRef | Where-Object { $_.displayName -eq $pickedName } | Select-Object -First 1
        if (-not $match) {
            [System.Windows.Forms.MessageBox]::Show("`"$pickedName`" isn't in the fetched directory list, so there's no Object ID to add as a member. Use Refresh in the picker first, then pick from the list rather than typing a name manually.", "Can't resolve", "OK", "Warning") | Out-Null
            return
        }
        if ($pendingMemberIds.Contains($match.id)) { return }   # already queued
        [void]$lstMembers.Items.Add("[$($match.type)] $($match.displayName)")
        $pendingMemberIds.Add($match.id)
    }.GetNewClosure())

    $btnRemoveMember.Add_Click({
        if ($lstMembers.SelectedIndex -lt 0) { return }
        $idx = $lstMembers.SelectedIndex
        $pendingMemberIds.RemoveAt($idx)
        $lstMembers.Items.RemoveAt($idx)
    }.GetNewClosure())

    $btnRun.Add_Click({
        $groupName = $txtGroupName.Text.Trim()
        if (-not $groupName) {
            [System.Windows.Forms.MessageBox]::Show("Enter a group name first.", "No name", "OK", "Warning") | Out-Null
            return
        }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "Creates `"$groupName`" if it doesn't already exist (exact name match), sets its description if you entered one, and adds $($pendingMemberIds.Count) member(s) to it. Continue?",
            "Confirm", "YesNo", "Question")
        if ($r -ne "Yes") { return }

        $btnRun.Enabled = $false
        $btnDeleteGroup.Enabled = $false
        $btnRenameGroup.Enabled = $false
        $btnRemoveCurrentMember.Enabled = $false
        $btnLoadMembers.Enabled = $false
        $btnClose.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Working..."

        $configPath = Join-Path $env:TEMP (".intunepkg_groupmanager_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_groupmanager_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            GroupName             = $groupName
            Description           = $txtDescription.Text.Trim()
            MemberIds             = @($pendingMemberIds)
            OutputResultPath      = $resultPath
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
        $btnRunRef = $btnRun
        $btnDeleteGroupRef = $btnDeleteGroup
        $btnRenameGroupRef = $btnRenameGroup
        $btnRemoveCurrentMemberRef = $btnRemoveCurrentMember
        $btnLoadMembersRef = $btnLoadMembers
        $btnCloseRef = $btnClose
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $loadCurrentMembersRef = $LoadCurrentMembers
        $lstMembersRef = $lstMembers
        $pendingMemberIdsRef = $pendingMemberIds

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $gmScript -TempScriptName ".intunepkg_embedded_groupmanager.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $btnRunRef.Enabled = $true
            $btnDeleteGroupRef.Enabled = $true
            $btnRenameGroupRef.Enabled = $true
            $btnRemoveCurrentMemberRef.Enabled = $true
            $btnLoadMembersRef.Enabled = $true
            $btnCloseRef.Enabled = $true
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblStatusRef.Text = "Done - group ID: $($result.groupId). Reloading current members and description..."
                        # These were just successfully applied - leaving them
                        # sitting in "Members to add" would make them look
                        # still-pending even though they're now also showing
                        # up in "Current members" below, which is exactly the
                        # kind of stale-looking mismatch worth avoiding.
                        $lstMembersRef.Items.Clear()
                        $pendingMemberIdsRef.Clear()
                        & $loadCurrentMembersRef
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
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnDeleteGroup.Add_Click({
        $groupName = $txtGroupName.Text.Trim()
        if (-not $groupName) {
            [System.Windows.Forms.MessageBox]::Show("Enter (or search for) a group name first.", "No name", "OK", "Warning") | Out-Null
            return
        }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "This permanently deletes the group `"$groupName`" from Entra ID. If any app is currently assigned to it (required/available/uninstall), that assignment breaks too. This CANNOT be undone.`n`nContinue?",
            "Confirm group deletion", "YesNo", "Warning")
        if ($r -ne "Yes") { return }

        $btnRun.Enabled = $false
        $btnDeleteGroup.Enabled = $false
        $btnRenameGroup.Enabled = $false
        $btnRemoveCurrentMember.Enabled = $false
        $btnLoadMembers.Enabled = $false
        $btnClose.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Deleting..."

        $configPath = Join-Path $env:TEMP (".intunepkg_groupmanager_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_groupmanager_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Mode                  = "Delete"
            GroupName             = $groupName
            MemberIds             = @()
            OutputResultPath      = $resultPath
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
        $btnRunRef = $btnRun
        $btnDeleteGroupRef = $btnDeleteGroup
        $btnRenameGroupRef = $btnRenameGroup
        $btnRemoveCurrentMemberRef = $btnRemoveCurrentMember
        $btnLoadMembersRef = $btnLoadMembers
        $btnCloseRef = $btnClose
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $lstCurrentMembersRef = $lstCurrentMembers
        $currentMemberIdsRef = $currentMemberIds
        $currentGroupIdBoxRef = $currentGroupIdBox

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $gmScript -TempScriptName ".intunepkg_embedded_groupmanager.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $btnRunRef.Enabled = $true
            $btnDeleteGroupRef.Enabled = $true
            $btnRenameGroupRef.Enabled = $true
            $btnRemoveCurrentMemberRef.Enabled = $true
            $btnLoadMembersRef.Enabled = $true
            $btnCloseRef.Enabled = $true
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblStatusRef.Text = "Group deleted."
                        # The group no longer exists - clear the stale
                        # current-members list so it can't be confused for
                        # still being accurate.
                        $lstCurrentMembersRef.Items.Clear()
                        $currentMemberIdsRef.Clear()
                        $currentGroupIdBoxRef.Value = $null
                        $btnRemoveCurrentMemberRef.Enabled = $false
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
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    # Requires the group to already be Loaded/Searched (so $currentGroupIdBox
    # has its real Object ID) rather than just typed into the name field -
    # renaming by NAME alone would mean either re-resolving against the OLD
    # name (which stops working the instant it's actually renamed) or, worse,
    # silently creating a brand-new group under the new name the way editing
    # the name field for Create/Update already does. Going by ID sidesteps
    # both: it's unambiguous no matter what the name says.
    #
    # This is also the one place in the whole app that can fix a rename
    # immediately and everywhere at once: every app in the local catalog
    # that references the OLD name gets updated to the new one, right here,
    # rather than needing "Pull metadata and groups from Intune..." to catch it up per app later.
    $btnRenameGroup.Add_Click({
        $groupName = $txtGroupName.Text.Trim()
        if (-not $groupName) {
            [System.Windows.Forms.MessageBox]::Show("Enter (or search for) a group name first.", "No name", "OK", "Warning") | Out-Null
            return
        }
        if (-not $currentGroupIdBox.Value) {
            [System.Windows.Forms.MessageBox]::Show("Load members (or Search...) for this group first - renaming needs its actual Object ID, not just the name typed here.", "Nothing loaded", "OK", "Warning") | Out-Null
            return
        }

        $newName = [Microsoft.VisualBasic.Interaction]::InputBox(
            "New name for `"$groupName`":", "Rename group", $groupName)
        if (-not $newName) { return }
        $newName = $newName.Trim()
        if (-not $newName -or $newName -eq $groupName) { return }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "Renames `"$groupName`" to `"$newName`" in Entra ID, and updates every app in the local catalog that references `"$groupName`" (Required/Available/Uninstall) to the new name. Continue?",
            "Confirm rename", "YesNo", "Question")
        if ($r -ne "Yes") { return }

        $btnRun.Enabled = $false
        $btnDeleteGroup.Enabled = $false
        $btnRenameGroup.Enabled = $false
        $btnRemoveCurrentMember.Enabled = $false
        $btnLoadMembers.Enabled = $false
        $btnClose.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Renaming..."

        $configPath = Join-Path $env:TEMP (".intunepkg_groupmanager_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_groupmanager_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Mode                  = "Rename"
            GroupId               = $currentGroupIdBox.Value
            NewGroupName          = $newName
            GroupName             = $groupName
            MemberIds             = @()
            OutputResultPath      = $resultPath
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
        $btnRunRef = $btnRun
        $btnDeleteGroupRef = $btnDeleteGroup
        $btnRenameGroupRef = $btnRenameGroup
        $btnRemoveCurrentMemberRef = $btnRemoveCurrentMember
        $btnLoadMembersRef = $btnLoadMembers
        $btnCloseRef = $btnClose
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $oldNameRef = $groupName
        $newNameRef = $newName
        $txtGroupNameRef = $txtGroupName
        $appsRefRef = $appsRef
        $linkedFilePathRef = $linkedFilePath
        $unsavedBoxRefRef = $unsavedBoxRef
        $loadCurrentMembersRef = $LoadCurrentMembers

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $gmScript -TempScriptName ".intunepkg_embedded_groupmanager.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $btnRunRef.Enabled = $true
            $btnDeleteGroupRef.Enabled = $true
            $btnRenameGroupRef.Enabled = $true
            $btnRemoveCurrentMemberRef.Enabled = $true
            $btnLoadMembersRef.Enabled = $true
            $btnCloseRef.Enabled = $true
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        # Propagate the rename into every app in the catalog
                        # that referenced the OLD name - straight to the new
                        # name, since this already has proof (the Entra ID
                        # rename above just succeeded, by this exact group's
                        # ID) that it's the same group, not a guess the way
                        # a name-only match would be.
                        $updatedCount = 0
                        # Names, not just a count - a count alone gives no
                        # way to tell, from THIS dialog, whether an
                        # unexpectedly low number means "that's genuinely
                        # every app that referenced this group" or "some
                        # were silently missed" (e.g. a stray whitespace/
                        # casing mismatch in one entry) without going to
                        # inspect the main catalog grid separately.
                        $updatedNames = New-Object System.Collections.Generic.List[string]
                        foreach ($appEntry in $appsRefRef) {
                            $changed = $false
                            for ($gi = 0; $gi -lt $appEntry.requiredFor.Count; $gi++) {
                                if ($appEntry.requiredFor[$gi] -eq $oldNameRef) { $appEntry.requiredFor[$gi] = $newNameRef; $changed = $true }
                            }
                            for ($gi = 0; $gi -lt $appEntry.availableFor.Count; $gi++) {
                                if ($appEntry.availableFor[$gi] -eq $oldNameRef) { $appEntry.availableFor[$gi] = $newNameRef; $changed = $true }
                            }
                            for ($gi = 0; $gi -lt $appEntry.uninstallFor.Count; $gi++) {
                                if ($appEntry.uninstallFor[$gi] -eq $oldNameRef) { $appEntry.uninstallFor[$gi] = $newNameRef; $changed = $true }
                            }
                            if ($changed) { $updatedCount++; $updatedNames.Add($appEntry.appName) }
                        }
                        if ($updatedCount -gt 0) {
                            $unsavedBoxRefRef.Value = $true
                            [void](Save-AppsToFile -Path $linkedFilePathRef)
                        }

                        $txtGroupNameRef.Text = $newNameRef
                        $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblStatusRef.Text = "Renamed to `"$newNameRef`" - updated $updatedCount app(s) in the catalog to match."
                        $updatedNamesText = if ($updatedNames.Count -gt 0) { " ($($updatedNames -join ', '))" } else { "" }
                        Write-DialogLogLine -LogBox $rtbLogRef -Text "[OK] Renamed `"$oldNameRef`" to `"$newNameRef`" and updated $updatedCount app(s) in the catalog$updatedNamesText.`r`n"
                        # $txtGroupNameRef.Text just above already triggers
                        # Add_TextChanged, which clears the loaded-members
                        # view (a name change usually means "different
                        # group" to that handler) - reload right after so
                        # it ends up showing the SAME group's members again,
                        # now under its new name, instead of sitting empty.
                        & $loadCurrentMembersRef
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
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnRemoveCurrentMember.Add_Click({
        if ($lstCurrentMembers.SelectedIndex -lt 0) { return }
        if (-not $currentGroupIdBox.Value) {
            [System.Windows.Forms.MessageBox]::Show("Load members first.", "Nothing loaded", "OK", "Warning") | Out-Null
            return
        }
        $idx = $lstCurrentMembers.SelectedIndex
        $memberLabel = [string]$lstCurrentMembers.Items[$idx]
        $memberId = $currentMemberIds[$idx]

        $r = [System.Windows.Forms.MessageBox]::Show("Remove $memberLabel from this group? This only removes them from the group - it does not delete the user or group itself.", "Confirm removal", "YesNo", "Warning")
        if ($r -ne "Yes") { return }

        $btnRun.Enabled = $false
        $btnDeleteGroup.Enabled = $false
        $btnRenameGroup.Enabled = $false
        $btnRemoveCurrentMember.Enabled = $false
        $btnLoadMembers.Enabled = $false
        $btnClose.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Removing..."

        $configPath = Join-Path $env:TEMP (".intunepkg_groupmanager_config_" + [guid]::NewGuid().ToString("N") + ".json")
        $resultPath = Join-Path $env:TEMP (".intunepkg_groupmanager_result_" + [guid]::NewGuid().ToString("N") + ".json")
        $config = [pscustomobject]@{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certThumb
            Mode                  = "RemoveMember"
            GroupId               = $currentGroupIdBox.Value
            MemberId              = $memberId
            GroupName             = $txtGroupName.Text.Trim()
            MemberIds             = @()
            OutputResultPath      = $resultPath
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
        $btnRunRef = $btnRun
        $btnDeleteGroupRef = $btnDeleteGroup
        $btnRenameGroupRef = $btnRenameGroup
        $btnRemoveCurrentMemberRef = $btnRemoveCurrentMember
        $btnLoadMembersRef = $btnLoadMembers
        $btnCloseRef = $btnClose
        $lblStatusRef = $lblStatus
        $resultPathRef = $resultPath
        $configPathRef = $configPath
        $procBoxRef = $procBox
        $rtbLogRef = $rtbLog
        $loadCurrentMembersRef = $LoadCurrentMembers

        $procBoxRef.Proc = Start-PipelineProcess -ScriptContent $gmScript -TempScriptName ".intunepkg_embedded_groupmanager.ps1" -ArgumentString "-ConfigPath `"$configPathRef`"" -ExtraLogTarget $rtbLog -OnComplete {
            param($code)
            $btnRunRef.Enabled = $true
            $btnDeleteGroupRef.Enabled = $true
            $btnRenameGroupRef.Enabled = $true
            $btnRemoveCurrentMemberRef.Enabled = $true
            $btnLoadMembersRef.Enabled = $true
            $btnCloseRef.Enabled = $true
            $procBoxRef.Proc = $null
            Remove-Item $configPathRef -Force -ErrorAction SilentlyContinue

            if (Test-Path $resultPathRef) {
                try {
                    $result = Get-Content -Path $resultPathRef -Raw | ConvertFrom-Json
                    Remove-Item $resultPathRef -Force -ErrorAction SilentlyContinue
                    if ($result.success) {
                        $lblStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
                        $lblStatusRef.Text = "Removed. Reloading members..."
                        & $loadCurrentMembersRef
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
                Write-DialogError -StatusLabel $lblStatusRef -LogBox $rtbLogRef -ErrorMessage "No result written (exit code $code). See progress above."
            }
        }.GetNewClosure()
    }.GetNewClosure())

    $btnClose.Add_Click({
        if ($procBox.Proc -and -not $procBox.Proc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show("A step is currently running. Stop it and close this dialog?", "Stop and close?", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            try { $procBox.Proc.Kill() } catch { }
        }
        $dlg.Close()
    }.GetNewClosure())
    $dlg.CancelButton = $btnClose

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
