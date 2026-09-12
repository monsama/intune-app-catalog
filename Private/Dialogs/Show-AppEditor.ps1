function Global:Show-AppEditor {
    param(
        $ExistingApp, # $null when adding a new app
        # This app's position in $Global:App.Apps - only known (and only >= 0)
        # when opened from the grid for an app that's actually IN the
        # catalog already. Powers the "Previous app"/"Next app" buttons
        # below; left at the default for the "Add app" flow (nothing to
        # navigate to/from for an app that doesn't exist yet) and for every
        # OTHER caller of this function (Show-IntuneOnlyAppsDialog's own
        # "Add to catalog..." prefill, etc.) - all of them are adding a
        # brand-new entry, not editing one already at a known index.
        [int]$CurrentIndex = -1,
        # Set only when this editor is being (re)opened because Previous/
        # Next was clicked FROM WITHIN the "Intune Deployment" dialog
        # itself, not from this editor's own Previous/Next - lets that
        # navigation land straight back in Deploy view for the next app
        # instead of stopping on the plain editor screen in between.
        [switch]$AutoOpenDeploy
    )

    # Plain (non-$Script:) local alias - see note in Start-IntuneAppLookup.
    $cache = $Global:App.IntuneAppsCache
    $linkedFilePath = $Global:App.LinkedFilePath
    $appsRef = $Global:App.Apps
    $unsavedBoxRef = $Global:App.UnsavedChangesBox

    # Previous/Next targets, computed once against the SAME filter the main
    # grid itself is currently showing (Update-Grid's own "$appName
    # $wingetId" -like "*filter*" check, duplicated here rather than
    # shared - it's a two-line check, and sharing it would mean threading
    # a delegate through a function that otherwise has zero dependency on
    # the main grid's own internals) - so "Next" always matches whatever
    # row is actually next in the grid the user just came from, filtered
    # search included, not silently ignoring an active search and jumping
    # to a row that's currently hidden.
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

    # Set by the Previous/Next handlers below (this editor's own, AND the
    # nested "Intune Deployment" dialog's) to request navigation instead of
    # a normal close - checked right after ShowDialog returns. Declared
    # here, before any closure below could reference it, same reasoning as
    # every other mutable box in this function.
    $navigateToIndexBox = @{ Value = $null }
    # Companion to the box above - set to $true only when the navigation
    # request came from INSIDE "Intune Deployment" (see its own handler
    # below), so the next app's editor knows to jump straight back into
    # Deploy view instead of stopping on the plain editor screen.
    $navigateAutoOpenDeployBox = @{ Value = $false }

    # Holds metadata handed back from "Deploy to Intune..." (Create/Update or
    # Save for later) while this editor is still open, so it can be folded
    # into the object this editor itself saves once "Save app to catalog" is
    # clicked. Declared here, before ANY button handler below gets
    # .GetNewClosure()'d - same reasoning as every other mutable container in
    # this file: closures capture variable VALUES at the moment they're
    # built, not a live reference, so this has to exist before the first
    # closure that touches it is created. A container (never reassigned), not
    # a plain variable, so the Deploy handler can WRITE into it and the Save
    # handler can later READ that write back out.
    $pendingDeployMetadataBox = @{ Value = $null }

    # Same staging idea as $pendingDeployMetadataBox above, for the two
    # top-level (non-metadata) Intune-reported facts - Type and Version -
    # since a brand-new app has nowhere else for a just-succeeded Create's
    # result to land until "Save app to catalog" actually runs.
    $pendingDeployIntuneFactsBox = @{ IntuneAppType = ""; IntuneAppVersion = "" }

    # Set by "Save && Deploy (Winget defaults)" only - tells this editor's
    # caller (below, via the return value) to route straight to Batch
    # Deploy for this one app right after saving, instead of just saving.
    # Same declare-before-any-closure reasoning as $pendingDeployMetadataBox
    # above.
    $deployAfterSaveBox = @{ Value = $false }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = if ($ExistingApp) { "Edit app" } else { "Add app" }
    # 40px taller than before, to fit the Previous/Next row below the
    # existing Save/Delete/Cancel row without moving any of this
    # function's many other absolutely-positioned controls.
    $dlg.ClientSize = New-Object System.Drawing.Size(470, 940)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = "App name"
    $lblName.Location = New-Object System.Drawing.Point(15,15)
    $lblName.AutoSize = $true
    $dlg.Controls.Add($lblName)

    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Location = New-Object System.Drawing.Point(15,35)
    $txtName.Size = New-Object System.Drawing.Size(430,24)
    $txtName.Text = if ($ExistingApp) { $ExistingApp.appName } else { "" }
    $dlg.Controls.Add($txtName)

    $lblWinget = New-Object System.Windows.Forms.Label
    $lblWinget.Text = "Winget ID (leave blank for custom install scripts)"
    $lblWinget.Location = New-Object System.Drawing.Point(15,68)
    $lblWinget.AutoSize = $true
    $dlg.Controls.Add($lblWinget)

    $txtWinget = New-Object System.Windows.Forms.TextBox
    $txtWinget.Location = New-Object System.Drawing.Point(15,88)
    $txtWinget.Size = New-Object System.Drawing.Size(290,24)
    $txtWinget.Text = if ($ExistingApp) { $ExistingApp.wingetId } else { "" }
    $dlg.Controls.Add($txtWinget)

    $btnSearchWinget = New-Object System.Windows.Forms.Button
    $btnSearchWinget.Text = "Search winget..."
    $btnSearchWinget.Location = New-Object System.Drawing.Point(313,87)
    $btnSearchWinget.Size = New-Object System.Drawing.Size(132,26)
    $dlg.Controls.Add($btnSearchWinget)

    $lblUncommonNote = New-Object System.Windows.Forms.Label
    $lblUncommonNote.Text = "No Winget ID = treated as an uncommon app (needs its own .intunewin, not the shared init package)."
    $lblUncommonNote.Location = New-Object System.Drawing.Point(15,118)
    $lblUncommonNote.Size = New-Object System.Drawing.Size(430,32)
    $lblUncommonNote.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblUncommonNote)

    $lblId = New-Object System.Windows.Forms.Label
    $lblId.Text = "App ID (Intune mobileApp GUID - generated by Intune, from 3_GetAppIdFromIntune.ps1)"
    $lblId.Location = New-Object System.Drawing.Point(15,152)
    $lblId.AutoSize = $true
    $lblId.MaximumSize = New-Object System.Drawing.Size(430,0)
    $dlg.Controls.Add($lblId)

    $txtId = New-Object System.Windows.Forms.TextBox
    $txtId.Location = New-Object System.Drawing.Point(15,186)
    $txtId.Size = New-Object System.Drawing.Size(320,24)
    $txtId.Text = if ($ExistingApp) { $ExistingApp.appId } else { "" }
    $dlg.Controls.Add($txtId)

    $btnLookupId = New-Object System.Windows.Forms.Button
    $btnLookupId.Text = "Look up"
    $btnLookupId.Location = New-Object System.Drawing.Point(345,185)
    $btnLookupId.Size = New-Object System.Drawing.Size(100,26)
    $dlg.Controls.Add($btnLookupId)

    $btnCreateInIntune = New-Object System.Windows.Forms.Button
    $btnCreateInIntune.Text = "Intune Deployment"
    $btnCreateInIntune.Location = New-Object System.Drawing.Point(15,216)
    $btnCreateInIntune.Size = New-Object System.Drawing.Size(210,30)
    $dlg.Controls.Add($btnCreateInIntune)

    # Shortcut for the common case (a Winget app with nothing unusual about
    # it): saves this app to the catalog, then routes straight to Batch
    # Deploy scoped to just this one app - same defaulting logic Batch
    # Deploy already uses for any app with no saved metadata (see
    # Get-DefaultAppMetadata), so there's exactly one place that computes
    # "sensible Winget defaults", not a second copy of that logic living
    # here. Batch Deploy's own pre-flight (package built? eligible?) and
    # progress log are reused as-is, rather than re-implemented inline in
    # this already-large editor.
    $btnSaveAndDeployWinget = New-Object System.Windows.Forms.Button
    $btnSaveAndDeployWinget.Text = "Save && Deploy (Winget defaults)"
    $btnSaveAndDeployWinget.Location = New-Object System.Drawing.Point(235,216)
    $btnSaveAndDeployWinget.Size = New-Object System.Drawing.Size(210,30)
    $dlg.Controls.Add($btnSaveAndDeployWinget)

    # Only makes sense for a genuinely brand-new app - $ExistingApp is
    # non-null both for a normal Edit AND for "Intune sync check"'s "Add
    # to catalog..." prefill (which already carries an App ID, since it
    # came from an app found live in Intune) - either way there's already
    # an Intune presence or an existing catalog entry to respect, not a
    # blank slate to default-and-deploy from scratch. When hidden, "Deploy
    # to Intune..." reclaims the full row it used to have before this
    # button existed.
    if ($ExistingApp) {
        $btnSaveAndDeployWinget.Visible = $false
        $btnCreateInIntune.Size = New-Object System.Drawing.Size(430,30)
    }
    else {
        # Greyed out until a Winget ID is actually typed - "Winget
        # defaults" has nothing to default FROM without one (that's also
        # exactly what its own click handler already validates below;
        # this just surfaces the same requirement up front instead of
        # only after a click).
        $updateSaveAndDeployWingetState = {
            $btnSaveAndDeployWinget.Enabled = [bool]$txtWinget.Text.Trim()
        }.GetNewClosure()
        $txtWinget.Add_TextChanged({ & $updateSaveAndDeployWingetState }.GetNewClosure())
        & $updateSaveAndDeployWingetState
    }

    # Lives at the bottom now, to the right of "Save app to catalog" -
    # created here (rather than down where the Save/Cancel buttons are)
    # since $updateDeleteButtonState and its Add_Click handler are both
    # defined right below, next to the rest of this button's own logic.
    $btnDeleteFromIntune = New-Object System.Windows.Forms.Button
    $btnDeleteFromIntune.Text = "Delete from Intune..."
    $btnDeleteFromIntune.Location = New-Object System.Drawing.Point(170,860)
    $btnDeleteFromIntune.Size = New-Object System.Drawing.Size(190,30)
    $dlg.Controls.Add($btnDeleteFromIntune)
    $appEditorTip = New-Object System.Windows.Forms.ToolTip

    # Shared output log for this whole dialog - same black-console look as
    # $rtbCreateLog in Show-CreateInIntuneDialog. Every error this dialog
    # can hit (App ID lookup, Intune Deployment, delete, group read/sync)
    # used to only ever get a single, easily-missed status line up near
    # whatever control triggered it - some of them long enough to run past
    # that label's fixed height and get silently clipped (the exact bug
    # chased down in Start-AppMetadataFetch's own error path). Routing
    # every error into one scrollable, persistent log instead means
    # nothing gets lost, and the status labels themselves can stay short
    # (compact) since they're no longer the only place the full message
    # lives. Created here, early, rather than down where it visually sits
    # (right above the bottom button row) - it needs to already be in
    # scope for every .GetNewClosure()'d handler below to capture it, same
    # reasoning as every other cross-cutting variable in this function.
    $rtbAppEditorLog = New-Object System.Windows.Forms.RichTextBox
    $rtbAppEditorLog.Location = New-Object System.Drawing.Point(15,766)
    $rtbAppEditorLog.Size = New-Object System.Drawing.Size(430,86)
    Initialize-DarkLogBox -LogBox $rtbAppEditorLog
    $dlg.Controls.Add($rtbAppEditorLog)

    $lblIdStatus = New-Object System.Windows.Forms.Label
    $lblIdStatus.Text = ""
    $lblIdStatus.Location = New-Object System.Drawing.Point(15,250)
    $lblIdStatus.Size = New-Object System.Drawing.Size(430,40)
    $lblIdStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblIdStatus)

    $TryFillIdFromCache = {
        $candidates = Find-IntuneMatches -Name $txtName.Text.Trim()
        if ($candidates.Count -eq 0) {
            $lblIdStatus.Text = "No matching app found in Intune for '$($txtName.Text.Trim())'."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::DarkOrange
            $rtbAppEditorLog.AppendText("[WARN] No matching app found in Intune for `"$($txtName.Text.Trim())`".`r`n")
        }
        elseif ($candidates.Count -eq 1 -or $candidates[0].displayName -eq $txtName.Text.Trim()) {
            $txtId.Text = $candidates[0].id
            $lblIdStatus.Text = "Matched: $($candidates[0].displayName)"
            $lblIdStatus.ForeColor = [System.Drawing.Color]::SeaGreen
        }
        else {
            $pick = Show-SimpleListPicker -Title "Multiple matches" -Prompt "Several Intune apps match '$($txtName.Text.Trim())'. Pick one:" -Items ($candidates | ForEach-Object { "$($_.displayName)  [$($_.id)]" })
            if ($pick -and $pick -match '\[([0-9a-fA-F-]{36})\]\s*$') {
                $txtId.Text = $Matches[1]
                $lblIdStatus.Text = "Matched: $pick"
                $lblIdStatus.ForeColor = [System.Drawing.Color]::SeaGreen
            }
        }
    }.GetNewClosure()

    $btnLookupId.Add_Click({
        if (-not $txtName.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Enter an app name first.", "No name", "OK", "Information") | Out-Null
            return
        }
        if ($cache.Count -eq 0) {
            $lblIdStatus.Text = "Connecting to Intune..."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::DimGray
            # Fresh local aliases - see note in Show-CertificateSetupDialog's Test
            # Connection handler. The -OnComplete block below is a closure nested
            # inside this already-closured Add_Click handler, so it needs its own
            # freshly-assigned copies of anything it touches rather than reusing
            # $lblIdStatus/$TryFillIdFromCache directly.
            $lblIdStatusRef = $lblIdStatus
            $tryFillRef = $TryFillIdFromCache
            $rtbAppEditorLogRef = $rtbAppEditorLog
            Start-IntuneAppLookup -OnComplete {
                param($ok, $data)
                if ($ok) { & $tryFillRef }
                else {
                    $lblIdStatusRef.Text = "Lookup failed: $data"
                    $lblIdStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $rtbAppEditorLogRef.AppendText("[FAILED] Lookup failed: $data`r`n")
                }
            }.GetNewClosure()
        }
        else {
            & $TryFillIdFromCache
        }
    }.GetNewClosure())

    $btnSearchWinget.Add_Click({
        # Deliberately not pre-filled with the app's Name field - the two
        # are often different (a custom/short catalog display name doesn't
        # necessarily match what the real winget package is called), so
        # pre-filling just meant clearing stale text before typing an actual
        # search term most of the time.
        $picked = Show-WingetSearchDialog
        if ($picked) { $txtWinget.Text = $picked }
    }.GetNewClosure())

    $btnCreateInIntune.Add_Click({
        if (-not $txtName.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Enter an app name first.", "No name", "OK", "Information") | Out-Null
            return
        }
        $deployResult = Show-CreateInIntuneDialog -AppName $txtName.Text.Trim() -WingetId $txtWinget.Text.Trim() -ExistingAppId $txtId.Text.Trim() -FromAppEditor -CurrentIndex $CurrentIndex

        # Previous/Next was clicked INSIDE "Intune Deployment" - none of
        # this handler's own staging/save logic below applies (there's
        # nothing from THIS app to stage; navigating away is a discard,
        # same as Cancel), so hand off to this editor's own navigation
        # exactly like its own Previous/Next buttons do, with
        # AutoOpenDeploy set so the next app lands straight back in
        # Deploy view instead of stopping on the plain editor screen.
        if ($null -ne $deployResult -and $null -ne $deployResult.NavigateToIndex) {
            $navigateToIndexBox.Value = $deployResult.NavigateToIndex
            $navigateAutoOpenDeployBox.Value = $true
            $dlg.Close()
            return
        }
        # Metadata (from Create/Update or "Save for later") is staged here,
        # not written to the catalog yet - Show-CreateInIntuneDialog, called
        # with -FromAppEditor, deliberately defers that write to this
        # editor's own "Save app to catalog" click, so Cancelling out of
        # THIS editor genuinely discards it instead of leaving a stray or
        # duplicate catalog entry behind (the bug this staging replaces:
        # that write used to happen immediately inside the Deploy dialog,
        # so a later "Save app to catalog" click added a SECOND entry for a
        # brand-new app, and Cancel couldn't undo the first one at all).
        #
        # That risk only exists for a BRAND-NEW app, though ($ExistingApp
        # is $null) - one that isn't in the catalog at all yet, where this
        # editor's own caller is the one that eventually adds it. For an
        # app that's already IN the catalog ($ExistingApp set), there's no
        # "stray entry" to create - Save-AppMetadataToLocalCatalog below
        # just updates that same existing entry in place, the exact same
        # upsert Show-CreateInIntuneDialog itself already uses everywhere
        # else it isn't called with -FromAppEditor. And by this point
        # Intune itself has already been changed for real (a live Create
        # or Update just succeeded) - requiring a SEPARATE manual "Save app
        # to catalog" click just to keep the LOCAL copy in sync with that
        # protects against nothing anymore, it just leaves the catalog
        # stale if that second click is forgotten.
        if ($deployResult -and $deployResult.Metadata) {
            $pendingDeployMetadataBox.Value = $deployResult.Metadata
        }
        # Staged the same freshest-first way as metadata above, for the
        # brand-new-app case below that has no catalog entry yet to write
        # Type/Version into directly.
        if ($deployResult -and $deployResult.IntuneAppType) { $pendingDeployIntuneFactsBox.IntuneAppType = $deployResult.IntuneAppType }
        if ($deployResult -and $deployResult.IntuneAppVersion) { $pendingDeployIntuneFactsBox.IntuneAppVersion = $deployResult.IntuneAppVersion }
        if ($deployResult -and ($deployResult.NewAppId -or $deployResult.Metadata) -and $ExistingApp) {
            $saveNowResult = Save-AppMetadataToLocalCatalog -AppsRef $appsRef -LinkedFilePath $linkedFilePath -AppName $ExistingApp.appName -Metadata $deployResult.Metadata -NewAppId $deployResult.NewAppId -IntuneAppVersion $deployResult.IntuneAppVersion
            if ($deployResult.NewAppId) {
                $txtId.Text = $deployResult.NewAppId
                if ($deployResult.NewAppName) { $txtName.Text = $deployResult.NewAppName }
            }
            if ($saveNowResult.Success) {
                $lblIdStatus.Text = if ($deployResult.NewAppId) { "Created/updated in Intune: $($deployResult.NewAppId) - saved to catalog." } else { "Metadata saved to catalog." }
                $lblIdStatus.ForeColor = [System.Drawing.Color]::SeaGreen
            }
            else {
                $lblIdStatus.Text = "Deployed to Intune, but saving to the catalog failed - check the Log tab, then use `"Save app to catalog`" below."
                $lblIdStatus.ForeColor = [System.Drawing.Color]::DarkOrange
                $rtbAppEditorLog.AppendText("[FAILED] Deployed to Intune, but saving to the local catalog failed - see the Log tab for details.`r`n")
            }
        }
        elseif ($deployResult -and $deployResult.NewAppId) {
            $txtId.Text = $deployResult.NewAppId
            if ($deployResult.NewAppName) { $txtName.Text = $deployResult.NewAppName }
            $lblIdStatus.Text = "Created/updated in Intune: $($deployResult.NewAppId) - click `"Save app to catalog`" below to save it here."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::SeaGreen
        }
        elseif ($deployResult -and $deployResult.Metadata) {
            $lblIdStatus.Text = "Metadata staged - click `"Save app to catalog`" below to save it here."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::SeaGreen
        }
    }.GetNewClosure())

    $btnDeleteFromIntune.Add_Click({
        if (-not $txtId.Text.Trim()) {
            # No App ID to delete from Intune at all - this click means
            # "remove the catalog entry itself" instead, matching what the
            # button's own text and tooltip say in this state (set below).
            # Same confirmation style as the main grid's own Delete button
            # (a plain Yes/No) rather than Show-DeleteAppDialog's
            # type-the-name-to-confirm - that stricter flow exists because
            # deleting an app FROM INTUNE is the genuinely irreversible,
            # live action; removing a catalog entry that already has no
            # Intune presence at all is a much lower-stakes, purely local
            # change.
            $r = [System.Windows.Forms.MessageBox]::Show("Delete '$($txtName.Text.Trim())' from the catalog? It has no App ID, so this only removes the local entry - there is nothing left in Intune to delete.", "Confirm delete", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
            $delIdx = -1
            for ($di = 0; $di -lt $appsRef.Count; $di++) {
                if ($ExistingApp -and $appsRef[$di].appName -eq $ExistingApp.appName) { $delIdx = $di; break }
            }
            if ($delIdx -ge 0) { $appsRef.RemoveAt($delIdx) }
            $unsavedBoxRef.Value = $true
            [void](Save-AppsToFile -Path $linkedFilePath)
            $dlg.Close()
            return
        }
        $deleted = Show-DeleteAppDialog -AppId $txtId.Text.Trim() -AppName $txtName.Text.Trim()
        # .Success alone would miss a catalog-only removal (Success=$false,
        # RemovedFromCatalog=$true) - can't actually happen from THIS call
        # site today (the no-App-ID case is already intercepted above,
        # before Show-DeleteAppDialog is ever called with a blank AppId),
        # but checked the same defensive way as Invoke-QuickDeleteFromIntune
        # regardless, in case that guard above ever changes.
        if (-not $deleted.Success -and -not $deleted.RemovedFromCatalog) { return }
        if ($deleted.RemovedFromCatalog) {
            # Show-DeleteAppDialog already removed the whole catalog entry
            # and saved, when the user chose that there - nothing left in
            # this editor to keep editing, since the entry it opened for no
            # longer exists. Closing it (same as the "no App ID" branch
            # above) rather than leaving it open on a now-nonexistent app.
            $dlg.Close()
            return
        }
        $txtId.Text = ""
        # Direct-save immediately, matching the main grid's own "Quick
        # delete from Intune" - this specific branch was the one gap
        # left over from before that convention existed everywhere
        # else. Without this, the App ID was only ever cleared in this
        # dialog's own textbox and in-memory copy, not actually
        # persisted - reopening the editor without first clicking
        # "Save app" separately would reload the OLD, still-persisted
        # App ID from disk, making it look like the Intune delete
        # itself hadn't done anything at all, since this button's own
        # dynamic text (see $updateDeleteButtonState) would then
        # incorrectly still read the stale, non-empty value too.
        # Whole-element replacement, not property mutation - see the
        # extensive comment on the identical pattern in
        # Save-AppMetadataToLocalCatalog for why that distinction
        # specifically matters here.
        $delFromIntuneIdx = -1
        for ($dfi = 0; $dfi -lt $appsRef.Count; $dfi++) {
            if ($ExistingApp -and $appsRef[$dfi].appName -eq $ExistingApp.appName) { $delFromIntuneIdx = $dfi; break }
        }
        if ($delFromIntuneIdx -ge 0) {
            $existingForClear = $appsRef[$delFromIntuneIdx]
            $appsRef[$delFromIntuneIdx] = [pscustomobject]@{
                appId            = ""
                appName          = $existingForClear.appName
                wingetId         = $existingForClear.wingetId
                # Cleared, not preserved, same reasoning as appId itself -
                # both describe what Intune currently says about this app,
                # and there's no longer anything in Intune for either to
                # describe.
                intuneAppType    = ""
                intuneAppVersion = ""
                requiredFor      = @($existingForClear.requiredFor)
                availableFor     = @($existingForClear.availableFor)
                uninstallFor     = @($existingForClear.uninstallFor)
                metadata         = $existingForClear.metadata
            }
        }
        $unsavedBoxRef.Value = $true
        $delFromIntuneSaveOk = Save-AppsToFile -Path $linkedFilePath
        if ($delFromIntuneSaveOk) {
            $lblIdStatus.Text = "Deleted from Intune - App ID cleared and saved."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::SeaGreen
        }
        else {
            $lblIdStatus.Text = "Deleted from Intune, but saving the cleared App ID failed - check the Log tab, then use Force save catalog."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::Firebrick
            $rtbAppEditorLog.AppendText("[FAILED] Deleted from Intune, but saving the cleared App ID locally failed - see the Log tab for details.`r`n")
        }
    }.GetNewClosure())

    # Same button, two different meanings depending on state, rather than
    # a second button squeezed in somewhere - this dialog has no spare
    # width or height left for one without repositioning every control
    # below it (see the identical reasoning on the duplicate-name check
    # above). No App ID at all - nothing new was ever deployed, or it was
    # just deleted from Intune above - means "delete from Intune" makes no
    # sense; "delete from catalog" does instead. A brand-new, never-saved
    # app (no $ExistingApp yet) disables this entirely, since there is
    # neither an Intune app nor a catalog entry yet to delete either way.
    $updateDeleteButtonState = {
        if (-not $ExistingApp) {
            $btnDeleteFromIntune.Enabled = $false
            $btnDeleteFromIntune.Text = "Delete from Intune..."
            $appEditorTip.SetToolTip($btnDeleteFromIntune, "Save this app first - there's nothing to delete yet.")
        }
        elseif (-not $txtId.Text.Trim()) {
            $btnDeleteFromIntune.Enabled = $true
            $btnDeleteFromIntune.Text = "Delete app from catalog..."
            $appEditorTip.SetToolTip($btnDeleteFromIntune, "No App ID - removes this app from the local catalog instead, since there's nothing in Intune to delete.")
        }
        else {
            $btnDeleteFromIntune.Enabled = $true
            $btnDeleteFromIntune.Text = "Delete from Intune..."
            $appEditorTip.SetToolTip($btnDeleteFromIntune, "Permanently deletes this app from Intune and clears its App ID here.")
        }
    }.GetNewClosure()
    $txtId.Add_TextChanged({ & $updateDeleteButtonState }.GetNewClosure())
    & $updateDeleteButtonState

    # Favorites now, not every group ever used by any app in the whole
    # catalog - that "everything, always" list only grows over time and
    # gets harder to scan the more groups exist. "+ New member" (below,
    # within each list) remains the way to reach any other group not
    # marked a favorite - see Show-FavoriteGroupsManager for managing
    # which ones get this default, always-visible treatment.
    $known = @($Global:App.FavoriteGroups)

    function New-GroupBox {
        param($Title, $Top, $Selected)
        $gb = New-Object System.Windows.Forms.GroupBox
        $gb.Text = $Title
        $gb.Location = New-Object System.Drawing.Point(15,$Top)
        $gb.Size = New-Object System.Drawing.Size(430,120)

        $clb = New-Object System.Windows.Forms.CheckedListBox
        $clb.Location = New-Object System.Drawing.Point(10,20)
        $clb.Size = New-Object System.Drawing.Size(300,85)
        $clb.CheckOnClick = $true
        # Union of already-known groups and whatever's pre-selected (e.g. a
        # default group from Settings that no existing app has used yet) -
        # otherwise a brand-new default group would be silently dropped
        # instead of showing up checked.
        $allOptions = @(@($known) + @($Selected) | Select-Object -Unique)
        foreach ($g in $allOptions) {
            $idx = $clb.Items.Add($g)
            if ($Selected -contains $g) { $clb.SetItemChecked($idx, $true) }
        }
        Add-RemovableItemContextMenu -CheckedListBox $clb
        $gb.Controls.Add($clb)

        $btnAddGroup = New-Object System.Windows.Forms.Button
        $btnAddGroup.Text = "+ New group..."
        $btnAddGroup.Location = New-Object System.Drawing.Point(310,20)
        $btnAddGroup.Size = New-Object System.Drawing.Size(110,28)
        $btnAddGroup.Add_Click({
            $picked = Show-EntraMemberPicker
            if ($picked) {
                $picked = $picked.Trim()
                if ($picked -and ($clb.Items -notcontains $picked)) {
                    $idx = $clb.Items.Add($picked)
                    $clb.SetItemChecked($idx, $true)
                }
            }
        }.GetNewClosure())
        $gb.Controls.Add($btnAddGroup)

        return @{ Box = $gb; List = $clb }
    }

    $reqGroup   = New-GroupBox -Title "Required for"  -Top 296 -Selected @($ExistingApp.requiredFor)
    $availGroup = New-GroupBox -Title "Available for" -Top 422 -Selected @($ExistingApp.availableFor)
    $uninstGroup= New-GroupBox -Title "Uninstall for" -Top 548 -Selected @($ExistingApp.uninstallFor)
    $dlg.Controls.Add($reqGroup.Box)
    $dlg.Controls.Add($availGroup.Box)
    $dlg.Controls.Add($uninstGroup.Box)

    # Pulls this app's CURRENT live group assignments from Intune and sets
    # the three pickers above to match exactly - the read-only counterpart
    # to "Assign Groups to Intune..." right below (which only ever pushes
    # THESE checkboxes outward), so the two live next to each other.
    # Without it, an app that already has real assignments in Intune
    # (created outside this tool, or from before these checkboxes
    # existed) shows every box unchecked here, which reads as "assigned
    # to nobody" when the truth is just "this editor never asked Intune
    # what's actually there".
    $btnReadGroupsFromIntune = New-Object System.Windows.Forms.Button
    $btnReadGroupsFromIntune.Text = "Pull groups from Intune..."
    $btnReadGroupsFromIntune.Location = New-Object System.Drawing.Point(15,674)
    $btnReadGroupsFromIntune.Size = New-Object System.Drawing.Size(430,30)
    $dlg.Controls.Add($btnReadGroupsFromIntune)

    # Dedicated status label for the button right above - this used to
    # reuse $lblIdStatus (the App ID lookup status, up near the top of the
    # dialog around y=250), which put "Groups above now match..." nowhere
    # near the button/lists it was actually reporting on.
    $lblGroupSyncStatus = New-Object System.Windows.Forms.Label
    $lblGroupSyncStatus.Text = ""
    $lblGroupSyncStatus.Location = New-Object System.Drawing.Point(15,708)
    $lblGroupSyncStatus.Size = New-Object System.Drawing.Size(430,18)
    $lblGroupSyncStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblGroupSyncStatus)

    $btnAssignGroups = New-Object System.Windows.Forms.Button
    $btnAssignGroups.Text = "Push groups to Intune (single app)..."
    $btnAssignGroups.Location = New-Object System.Drawing.Point(15,730)
    $btnAssignGroups.Size = New-Object System.Drawing.Size(430,30)
    $dlg.Controls.Add($btnAssignGroups)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Save app to catalog"
    $btnOk.Location = New-Object System.Drawing.Point(15,860)
    $btnOk.Size = New-Object System.Drawing.Size(150,30)
    $dlg.Controls.Add($btnOk)

    # $btnDeleteFromIntune itself is created earlier, up next to
    # $btnCreateInIntune's own logic - only its position, right here to
    # the right of "Save app to catalog", is decided at this end of the
    # bottom row.
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(365,860)
    $btnCancel.Size = New-Object System.Drawing.Size(90,30)
    $dlg.Controls.Add($btnCancel)

    # Only shown for an app actually opened from the grid (see
    # $CurrentIndex's own param comment) - hidden outright for "Add app",
    # where there's no catalog position to navigate from. Same Cancel-is-
    # a-silent-discard convention this dialog (and every other dialog in
    # this app) already uses for its own Cancel button - clicking Previous/
    # Next does NOT save whatever's currently in the form first; it moves
    # on exactly like Cancel would, just straight into the next editor
    # instead of closing outright. Anyone mid-edit who wants THIS app's
    # changes kept needs "Save app to catalog" before navigating away.
    $btnPrevApp = New-Object System.Windows.Forms.Button
    $btnPrevApp.Text = "< Previous app"
    $btnPrevApp.Location = New-Object System.Drawing.Point(15,898)
    $btnPrevApp.Size = New-Object System.Drawing.Size(150,30)
    $btnPrevApp.Enabled = ($null -ne $prevAppIndex)
    $btnPrevApp.Visible = ($CurrentIndex -ge 0)
    $dlg.Controls.Add($btnPrevApp)

    $lblAppNavPosition = New-Object System.Windows.Forms.Label
    $lblAppNavPosition.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblAppNavPosition.Location = New-Object System.Drawing.Point(170,898)
    $lblAppNavPosition.Size = New-Object System.Drawing.Size(130,30)
    $lblAppNavPosition.ForeColor = [System.Drawing.Color]::DimGray
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
        $lblAppNavPosition.Text = if ($visiblePosForLabel -gt 0) { "$visiblePosForLabel of $visibleCountForLabel" } else { "" }
    }
    $dlg.Controls.Add($lblAppNavPosition)

    $btnNextApp = New-Object System.Windows.Forms.Button
    $btnNextApp.Text = "Next app >"
    $btnNextApp.Location = New-Object System.Drawing.Point(305,898)
    $btnNextApp.Size = New-Object System.Drawing.Size(150,30)
    $btnNextApp.Enabled = ($null -ne $nextAppIndex)
    $btnNextApp.Visible = ($CurrentIndex -ge 0)
    $dlg.Controls.Add($btnNextApp)

    $btnPrevApp.Add_Click({
        $navigateToIndexBox.Value = $prevAppIndex
        $dlg.Close()
    }.GetNewClosure())
    $btnNextApp.Add_Click({
        $navigateToIndexBox.Value = $nextAppIndex
        $dlg.Close()
    }.GetNewClosure())

    $btnAssignGroups.Add_Click({
        if (-not $txtName.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Enter an app name first.", "No name", "OK", "Information") | Out-Null
            return
        }
        Show-TargetedAssignDialog -AppId $txtId.Text.Trim() -AppName $txtName.Text.Trim() `
            -RequiredGroups @($reqGroup.List.CheckedItems) -AvailableGroups @($availGroup.List.CheckedItems) -UninstallGroups @($uninstGroup.List.CheckedItems) | Out-Null
    }.GetNewClosure())

    $btnReadGroupsFromIntune.Add_Click({
        if (-not $txtId.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("This app has no App ID yet - there's nothing in Intune to read groups from.", "No App ID", "OK", "Information") | Out-Null
            return
        }
        $btnReadGroupsFromIntune.Enabled = $false
        $lblGroupSyncStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblGroupSyncStatus.Text = "Reading current group assignments from Intune..."

        # Fresh aliases for the nested -OnComplete closure - see note at
        # the top of Show-CreateInIntuneDialog for why this matters here
        # too.
        $reqGroupRef = $reqGroup
        $availGroupRef = $availGroup
        $uninstGroupRef = $uninstGroup
        $btnReadGroupsFromIntuneRef = $btnReadGroupsFromIntune
        $lblGroupSyncStatusRef = $lblGroupSyncStatus
        $rtbAppEditorLogRef = $rtbAppEditorLog

        Start-AppMetadataFetch -AppId $txtId.Text.Trim() -OnComplete {
            param($ok, $errMsg, $data)
            $btnReadGroupsFromIntuneRef.Enabled = $true
            if (-not $ok) {
                $lblGroupSyncStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                $lblGroupSyncStatusRef.Text = "Could not read groups from Intune - see log below."
                $rtbAppEditorLogRef.AppendText("[FAILED] Could not read groups from Intune: $errMsg`r`n")
                return
            }
            # Sets each list to match Intune EXACTLY, not a merge - this
            # button's whole point is "show me what's actually there",
            # same as Sync metadata's own authoritative-pull philosophy
            # elsewhere in this app. A group Intune has that isn't in the
            # list yet is added (same as "+ New group..."), then every
            # box is checked/unchecked to match live reality, including
            # unchecking anything checked here that Intune doesn't
            # actually have.
            $syncGroupList = {
                param($List, $Names)
                foreach ($groupName in @($Names)) {
                    if ($List.Items -notcontains $groupName) { [void]$List.Items.Add($groupName) }
                }
                for ($gi = 0; $gi -lt $List.Items.Count; $gi++) {
                    $List.SetItemChecked($gi, (@($Names) -contains [string]$List.Items[$gi]))
                }
            }
            & $syncGroupList $reqGroupRef.List $data.RequiredGroupNames
            & $syncGroupList $availGroupRef.List $data.AvailableGroupNames
            & $syncGroupList $uninstGroupRef.List $data.UninstallGroupNames

            $lblGroupSyncStatusRef.ForeColor = [System.Drawing.Color]::SeaGreen
            $lblGroupSyncStatusRef.Text = "Groups above now match what's currently assigned in Intune."
        }.GetNewClosure()
    }.GetNewClosure())

    # Plain local box (not $Script:-qualified) - see the same pattern/reasoning in
    # Show-SimpleListPicker. $Script:-qualified reads/writes from inside a
    # .GetNewClosure()'d block do not reliably reach the real script scope.
    $resultBox = @{ Value = $null }

    # Shared by both "Save app to catalog" and "Save && Deploy (Winget
    # defaults)" - the two buttons only differ in validation (the latter
    # additionally requires a Winget ID) and in whether $deployAfterSaveBox
    # gets set before this runs; the actual "build the saved object and
    # close" logic is identical either way, so it lives in exactly one
    # place rather than two copies that could drift.
    $performSave = {
        if (-not $txtName.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("App name is required.", "Missing name", "OK", "Warning") | Out-Null
            return
        }
        # metadata explicitly preserved, not dropped - this editor has no
        # fields for it at all (that's what "Deploy to Intune..." is for),
        # so building the result without it would silently wipe out any
        # metadata already saved for this app the moment "Save app" is
        # clicked, even if nothing metadata-related was touched in this
        # dialog at all.
        #
        # Read directly from this app's own file on disk now, not from
        # $Global:App.Apps in memory - confirmed, directly, that by the time
        # this handler runs, $Global:App.Apps can have already lost this
        # app entirely (a name-based lookup against it came back with no
        # match at all, despite the app definitively existing seconds
        # earlier), even though the file on disk was independently
        # confirmed correct at that same moment. Rather than keep
        # chasing why the in-memory collection loses this specific entry
        # in this specific nested-dialog sequence, this reads from the
        # one source that's actually been reliable throughout: disk.
        # Falls back to $Global:App.Apps only if no file exists yet (a brand
        # new app that's never been saved at all).
        $preservedMetadata = $null
        $metadataSource = "none"
        # Freshest first: metadata just staged by "Deploy to Intune..." in
        # THIS still-open editing session (see $pendingDeployMetadataBox
        # above) is more current than whatever's already on disk or in
        # memory - a Create/Update or Save for later click that just ran
        # deliberately hasn't been written anywhere yet, precisely so this
        # click is the one that commits it.
        if ($pendingDeployMetadataBox.Value) {
            $preservedMetadata = $pendingDeployMetadataBox.Value
            $metadataSource = "pending-deploy"
        }
        if (-not $preservedMetadata) {
            try {
                $existingFilePath = Join-Path $linkedFilePath ((Get-SafeFileNameForApp -Name $ExistingApp.appName) + ".json")
                if ($ExistingApp -and (Test-Path $existingFilePath)) {
                    # -Encoding UTF8 explicitly - same reasoning as
                    # Import-AppsFromFile's own read of this same file format.
                    $onDiskApp = Get-Content -Path $existingFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($onDiskApp.metadata) {
                        $preservedMetadata = $onDiskApp.metadata
                        $metadataSource = "disk"
                    }
                }
            }
            catch {
                # Falls through to the in-memory fallback below - a failed
                # disk read here shouldn't block saving the rest of the edit.
            }
        }
        if (-not $preservedMetadata) {
            $liveAppForMetadata = $Global:App.Apps | Where-Object { $_.appName -eq $ExistingApp.appName } | Select-Object -First 1
            $preservedMetadata = if ($liveAppForMetadata) { $liveAppForMetadata.metadata } else { $ExistingApp.metadata }
            if ($preservedMetadata) { $metadataSource = "memory" }
        }
        # Logged explicitly - confirms which source actually supplied the
        # preserved metadata (disk, memory, or neither), rather than
        # assuming.
        Write-Log "Save app: ExistingApp.appName=`"$($ExistingApp.appName)`" - metadata source: $metadataSource, preservedMetadata is `$null: $($null -eq $preservedMetadata).`r`n"

        # intuneAppType/intuneAppVersion are read-only, Intune-reported
        # facts this editor has no field for - same reasoning as metadata
        # above, preserved from whatever's already on file for this app
        # rather than silently blanked out just because this editor
        # doesn't show or edit them.
        $preservedIntuneAppType = ""
        $preservedIntuneAppVersion = ""
        if ($ExistingApp) {
            $liveAppForType = $Global:App.Apps | Where-Object { $_.appName -eq $ExistingApp.appName } | Select-Object -First 1
            $preservedIntuneAppType = if ($liveAppForType -and $liveAppForType.intuneAppType) { $liveAppForType.intuneAppType } else { $ExistingApp.intuneAppType }
            $preservedIntuneAppVersion = if ($liveAppForType -and $liveAppForType.intuneAppVersion) { $liveAppForType.intuneAppVersion } else { $ExistingApp.intuneAppVersion }
        }
        # A brand-new app (no $ExistingApp) has nothing to preserve above,
        # but "Deploy to Intune..." may still have just staged a fresh
        # Create result via $pendingDeployIntuneFactsBox (see its own
        # button handler) - freshest wins, same reasoning and same
        # override pattern as $pendingDeployMetadataBox above.
        if ($pendingDeployIntuneFactsBox.IntuneAppType) { $preservedIntuneAppType = $pendingDeployIntuneFactsBox.IntuneAppType }
        if ($pendingDeployIntuneFactsBox.IntuneAppVersion) { $preservedIntuneAppVersion = $pendingDeployIntuneFactsBox.IntuneAppVersion }
        $resultBox.Value = [pscustomobject]@{
            appId            = $txtId.Text.Trim()
            appName          = $txtName.Text.Trim()
            wingetId         = $txtWinget.Text.Trim()
            intuneAppType    = $preservedIntuneAppType
            intuneAppVersion = $preservedIntuneAppVersion
            requiredFor      = @($reqGroup.List.CheckedItems)
            availableFor     = @($availGroup.List.CheckedItems)
            uninstallFor     = @($uninstGroup.List.CheckedItems)
            metadata         = $preservedMetadata
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure()

    $btnOk.Add_Click({ & $performSave }.GetNewClosure())

    $btnSaveAndDeployWinget.Add_Click({
        if (-not $txtWinget.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("A Winget ID is required to deploy with Winget defaults. Leave it blank and use `"Save app to catalog`" instead for a custom-install (uncommon) app.", "Winget ID required", "OK", "Warning") | Out-Null
            return
        }
        $deployAfterSaveBox.Value = $true
        & $performSave
    }.GetNewClosure())

    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    }.GetNewClosure())

    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnOk
    Set-Theme -Control $dlg

    # Flags a duplicate name the moment it's typed, rather than only at
    # the very end when "Save app" is clicked - Save-AppsToFile's own
    # duplicate-name check (case-insensitive, whitespace-normalized, same
    # comparison used here for consistency) already blocks this at save
    # time regardless, but discovering that only after filling out the
    # entire form - metadata, requirements, groups, everything - is exactly
    # the kind of late, avoidable surprise this catches earlier instead.
    # Reuses the existing "App name" label above the field for the message
    # itself - a tooltip alone isn't visible without hovering, and this
    # dialog has no spare vertical room for a new label without
    # repositioning every control below it. Tints the field too, as a
    # second, immediate visual cue.
    #
    # Defined here, after Set-Theme, not up where $txtName/$lblName are
    # created - $lblNameThemedColor has to be captured after theming has
    # already set $lblName's real ForeColor, and .GetNewClosure() captures
    # variable VALUES at the moment it's called, not a live reference to
    # them - defining this any earlier would have captured
    # $lblNameThemedColor as $null, permanently, before it was ever
    # assigned.
    $lblNameOriginalText = $lblName.Text
    $lblNameThemedColor = $lblName.ForeColor
    $nameWarningTip = New-Object System.Windows.Forms.ToolTip
    $checkDuplicateName = {
        $typed = ($txtName.Text.Trim() -replace '\s+', ' ').ToLowerInvariant()
        $isDup = $false
        if ($typed) {
            foreach ($otherApp in $appsRef) {
                if (-not $otherApp.appName) { continue }
                if ($ExistingApp -and $otherApp.appName -eq $ExistingApp.appName) { continue }
                $otherNorm = ($otherApp.appName.Trim() -replace '\s+', ' ').ToLowerInvariant()
                if ($otherNorm -eq $typed) { $isDup = $true; break }
            }
        }
        if ($isDup) {
            $txtName.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 214)
            $lblName.Text = "$lblNameOriginalText  -  an app with this name already exists"
            $lblName.ForeColor = [System.Drawing.Color]::DarkOrange
            $nameWarningTip.SetToolTip($txtName, "An app with this name already exists in the catalog. Saving will still warn again, but two apps with the same name isn't recommended.")
        }
        else {
            $txtName.BackColor = [System.Drawing.SystemColors]::Window
            $lblName.Text = $lblNameOriginalText
            $lblName.ForeColor = $lblNameThemedColor
            $nameWarningTip.SetToolTip($txtName, "")
        }
    }.GetNewClosure()
    $txtName.Add_TextChanged({ & $checkDuplicateName }.GetNewClosure())
    & $checkDuplicateName   # catches a pre-filled duplicate (e.g. Intune sync check's prefill) immediately on open, not just after the first keystroke

    # Only fires when THIS editor was itself opened by Previous/Next
    # clicked inside "Intune Deployment" for a different app (see
    # -AutoOpenDeploy's own param comment) - deferred to Add_Shown, not
    # called directly here, same reasoning as every other "kick off work
    # right as the window appears" case in this app: doing it before the
    # window is actually realized can leave WaitCursor-equivalent UI state
    # that doesn't reliably stick.
    if ($AutoOpenDeploy) {
        $dlg.Add_Shown({ $btnCreateInIntune.PerformClick() }.GetNewClosure())
    }

    $dlgResult = $dlg.ShowDialog($Global:App.Form)

    # Previous/Next was clicked - this editor's own result (there isn't
    # one; navigating away is a discard, same as Cancel) is done, and the
    # NEXT app's editor takes over from here. Tail-recurses rather than
    # looping, so an arbitrarily long chain of Previous/Next clicks in one
    # sitting is just nested calls, each returning the one after it -
    # whatever the LAST editor in the chain actually returns (a save, or
    # $null on Cancel/Close) is what this whole chain ultimately hands
    # back to the ORIGINAL caller (btnEdit's own click handler), Index
    # included, so it knows exactly which catalog slot that result belongs
    # to even though it's no longer the app it originally opened.
    if ($null -ne $navigateToIndexBox.Value) {
        return Show-AppEditor -ExistingApp $Global:App.Apps[$navigateToIndexBox.Value] -CurrentIndex $navigateToIndexBox.Value -AutoOpenDeploy:$navigateAutoOpenDeployBox.Value
    }

    if ($dlgResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return [pscustomobject]@{ App = $resultBox.Value; DeployAfterSave = $deployAfterSaveBox.Value; Index = $CurrentIndex }
    }
    return $null
}
