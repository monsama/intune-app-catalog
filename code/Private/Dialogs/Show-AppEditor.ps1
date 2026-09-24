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
        [switch]$AutoOpenDeploy,
        # Opened to push this app's catalog metadata to Intune (the audit's
        # "Push metadata"): the Deploy side's compare with Intune starts
        # every differing field on the catalog's value instead of Intune's
        # (Show-CreateInIntuneDialog -PreferLocal). For this app only -
        # Previous/Next open the next one the ordinary way.
        [switch]$PreferLocal
    )

    # Plain (non-$Script:) local alias - see note in Start-IntuneAppLookup.
    $cache = $Global:App.IntuneAppsCache
    $linkedFilePath = $Global:App.LinkedFilePath
    $appsRef = $Global:App.Apps
    $unsavedBoxRef = $Global:App.UnsavedChangesBox

    # Previous/Next targets: whatever row is next in the grid the user just
    # came from, in the order it shows them - search, filter and sort
    # included (Get-NavigableAppIndices), never a row that is hidden there.
    $prevAppIndex = $null
    $nextAppIndex = $null
    # Filled one by one: a cast of the returned array to List[int] fails
    # in both PowerShells (it arrives wrapped once more by @()).
    $visibleAppIndices = New-Object System.Collections.Generic.List[int]
    foreach ($navIndex in (Get-NavigableAppIndices)) { $visibleAppIndices.Add([int]$navIndex) }
    if ($CurrentIndex -ge 0) {
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

    # Tells the Deploy tabs the Winget ID changed ($syncWingetId, set once
    # those tabs exist further down). Declared up here for the same reason
    # as the boxes above: "Search winget..." is built before them and has
    # to be able to call it.
    $deploySyncBox = @{ Run = $null }

    # The Deploy side, once it exists (set right after it is built, further
    # down). Declared this early because $GetDiscardQuestion - built before
    # those tabs - asks it whether anything was edited there.
    $deployHostBox = @{ Host = $null }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    # The app's name in the title, because five tabs in there is nothing
    # else on screen that says which app this is - the name field itself is
    # on the Catalog tab, four tabs away from where you might be standing.
    # It follows renames, so the title never claims the old name.
    $dlg.Text = if ($ExistingApp) { "Edit app - $($ExistingApp.appName)" } else { "Add app" }
    # 40px taller than before, to fit the Previous/Next row below the
    # existing Save/Delete/Cancel row without moving any of this
    # function's many other absolutely-positioned controls.
    # 1010, not 959: the Assignments tab holds four group boxes and still
    # had to scroll for the last one. Everything below the tabs moves down
    # with it - see the bottom row block further down, which measures from
    # these same numbers.
    $dlg.ClientSize = New-Object System.Drawing.Size(900, 1010)
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
    # Named for DeployDefaultsHarness, same as $txtWingetId below.
    $txtName.Name = 'txtAppName'
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
    # Named so DeployDefaultsHarness can find it by name instead of by
    # guessing which box on the page it is. The field is the one the
    # generated install/uninstall/detection all hang off, and the test that
    # covers that is worth a control having a name.
    $txtWinget.Name = 'txtWingetId'
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
    $lblId.Text = "App ID (Intune mobileApp GUID - generated by Intune; use Look up to find it)"
    $lblId.Location = New-Object System.Drawing.Point(15,152)
    $lblId.AutoSize = $true
    $lblId.MaximumSize = New-Object System.Drawing.Size(430,0)
    $dlg.Controls.Add($lblId)

    $txtId = New-Object System.Windows.Forms.TextBox
    $txtId.Location = New-Object System.Drawing.Point(15,186)
    $txtId.Size = New-Object System.Drawing.Size(320,24)
    $txtId.Text = if ($ExistingApp) { $ExistingApp.appId } else { "" }
    $dlg.Controls.Add($txtId)

    # True only for a BRAND-NEW app ($ExistingApp is $null) that's had a
    # successful "Intune Deployment..." run this session but hasn't had
    # "Save app to catalog" clicked since - the one case where Cancel/
    # Previous/Next silently discarding, same as this editor's own
    # convention for a plain field edit, would ALSO leave Intune already
    # changed with no local record of it at all (see $btnCreateInIntune's
    # own staging note further down - an EXISTING app auto-saves
    # immediately instead, so there's nothing pending to lose for that
    # case). Defined here, right after $txtId above - not down by
    # Cancel/Previous/Next where it's actually used, since $btnCreateInIntune's
    # own closure (just below) needs it too, and GetNewClosure() captures
    # variable VALUES at the moment it's called, not a live reference -
    # defining this any later would have left $btnCreateInIntune's own
    # copy permanently pointing at $null.
    $HasUnsavedDeployResult = {
        (-not $ExistingApp) -and ($pendingDeployMetadataBox.Value -or $pendingDeployIntuneFactsBox.IntuneAppType)
    }.GetNewClosure()
    # What leaving without saving would lose, as the question to ask - or
    # $null when nothing would be lost. Asked in FormClosing (below) for
    # every way out: Cancel, Previous/Next (here and inside "Intune
    # Deployment"), X and Alt+F4. Compares the fields "Save app to
    # catalog" writes with how they were when the editor opened;
    # $editorStateBox.Get is filled in once the group lists exist.
    $editorStateBox = @{ Initial = $null; Get = $null }
    $GetDiscardQuestion = {
        $name = $txtName.Text.Trim()
        $label = if ($name) { "'$name'" } else { "This new app" }
        if (& $HasUnsavedDeployResult) {
            return "$label was deployed to Intune, but isn't saved to the catalog yet. Discard it here?`n`nThe app stays in Intune either way - click 'Save app to catalog' to keep it here too."
        }
        if ($editorStateBox.Get -and ((& $editorStateBox.Get) -ne $editorStateBox.Initial)) {
            if ($ExistingApp) { return "Discard your unsaved changes to ${label}?" }
            return "$label isn't saved to the catalog yet. Discard it?"
        }
        # Fields edited by hand on the Deploy tabs - "Save app to catalog"
        # saves them, so leaving without it loses them just the same.
        $deployHostForClose = $deployHostBox.Host
        if ($deployHostForClose -and $deployHostForClose.HasUserEdits -and (& $deployHostForClose.HasUserEdits)) {
            if ($ExistingApp) { return "Discard your unsaved changes to ${label}'s Intune deployment fields?" }
            return "$label isn't saved to the catalog yet. Discard it, and what you entered on the Intune tabs?"
        }
        return $null
    }.GetNewClosure()
    # Set once the user has already been asked (Cancel/Previous/Next) and
    # chose to discard, or the close is one this editor already resolved
    # some other way (a successful Save, or the app being deleted
    # outright) - stops FormClosing's own backstop further down from
    # asking the exact same question again right after.
    $discardConfirmedBox = @{ Value = $false }
    # $true while the discard question is on screen - see the FormClosing below
    $askingBox = @{ Value = $false }

    $btnLookupId = New-Object System.Windows.Forms.Button
    $btnLookupId.Text = "Look up"
    $btnLookupId.Location = New-Object System.Drawing.Point(345,185)
    $btnLookupId.Size = New-Object System.Drawing.Size(100,26)
    $dlg.Controls.Add($btnLookupId)
    $lookupIdTip = New-Object System.Windows.Forms.ToolTip
    $lookupIdTip.SetToolTip($btnLookupId, "Searches Intune by this app's name and fills in App ID above if a match is found.")

    $btnCreateInIntune = New-Object System.Windows.Forms.Button
    $btnCreateInIntune.Text = "Intune Deployment"
    $btnCreateInIntune.Location = New-Object System.Drawing.Point(15,216)
    $btnCreateInIntune.Size = New-Object System.Drawing.Size(210,30)
    $dlg.Controls.Add($btnCreateInIntune)
    $createInIntuneTip = New-Object System.Windows.Forms.ToolTip
    $createInIntuneTip.SetToolTip($btnCreateInIntune, "Opens the full deployment workflow (package, requirements, assignments) for this app - separate from 'Save app to catalog' below.")

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
    $btnDeleteFromIntune.Location = New-Object System.Drawing.Point(170,984)
    $btnDeleteFromIntune.Size = New-Object System.Drawing.Size(190,32)
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
    $rtbAppEditorLog.Location = New-Object System.Drawing.Point(15,892)
    $rtbAppEditorLog.Size = New-Object System.Drawing.Size(430,86)
    Initialize-DarkLogBox -LogBox $rtbAppEditorLog
    $dlg.Controls.Add($rtbAppEditorLog)
    # Which log this editor's own messages go to. It starts as the box
    # above, because the handlers below are built long before the deploy
    # side is hosted - and once it is, this is repointed at the one log
    # under every tab, and the box above is dropped. Two black boxes on the
    # Catalog tab, one of them the window's log and the other this one, was
    # never intentional: there is one place things get reported.
    $editorLogBox = @{ Box = $rtbAppEditorLog }

    $lblIdStatus = New-Object System.Windows.Forms.Label
    $lblIdStatus.Text = ""
    $lblIdStatus.Location = New-Object System.Drawing.Point(15,250)
    $lblIdStatus.Size = New-Object System.Drawing.Size(430,40)

    # Where this app's own .intunewin is, for the cases the prediction
    # from its name cannot reach: a package built elsewhere, one kept on
    # a share, or a folder holding more than one .intunewin, which
    # Resolve-AppPackagePath refuses to guess between.
    #
    # Empty is the right default and stays the common case - a derived
    # path follows a rename, a stored one does not. So the predicted path
    # sits in the box greyed, the same way the Folders tab shows its
    # defaults: you can see what it resolves to without that becoming an
    # override the moment you look at it.
    $lblAppPackagePath = New-Object System.Windows.Forms.Label
    $lblAppPackagePath.Text = "Package (.intunewin) - set this and it wins, Winget ID or not. Empty means: the shared init.intunewin for a Winget app, otherwise the one found by name."
    $lblAppPackagePath.Location = New-Object System.Drawing.Point(15,462)
    $lblAppPackagePath.AutoSize = $true
    $dlg.Controls.Add($lblAppPackagePath)

    $txtAppPackagePath = New-Object System.Windows.Forms.TextBox
    $txtAppPackagePath.Location = New-Object System.Drawing.Point(15,482)
    $txtAppPackagePath.Size = New-Object System.Drawing.Size(700,24)
    $txtAppPackagePath.Text = if ($ExistingApp) { [string]$ExistingApp.packagePath } else { "" }
    $dlg.Controls.Add($txtAppPackagePath)

    $btnBrowseAppPackage = New-Object System.Windows.Forms.Button
    $btnBrowseAppPackage.Text = "Browse..."
    $btnBrowseAppPackage.Location = New-Object System.Drawing.Point(725,481)
    $btnBrowseAppPackage.Size = New-Object System.Drawing.Size(110,26)
    $dlg.Controls.Add($btnBrowseAppPackage)
    $appPackageTip = New-Object System.Windows.Forms.ToolTip
    $appPackageTip.SetToolTip($btnBrowseAppPackage, "Pick the .intunewin file itself, or a folder containing exactly one. A Winget app does not need this - they all deploy with the shared init.intunewin.")
    $btnBrowseAppPackage.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Intune package (*.intunewin)|*.intunewin|All files (*.*)|*.*"
        $ofd.Title = "Select this app's .intunewin"
        # Where this app's packages live, or where the box already points.
        # Left unset a picker opens wherever Windows last left this
        # process - which is whatever OTHER picker ran before it.
        $startIn = $txtAppPackagePath.Text.Trim()
        if ($startIn -and (Test-Path -LiteralPath $startIn)) {
            if (Test-Path -LiteralPath $startIn -PathType Leaf) { $ofd.FileName = $startIn }
            else { $ofd.InitialDirectory = $startIn }
        }
        else {
            $packagesFolder = Get-AppFolder -Kind Packages
            if (Test-Path -LiteralPath $packagesFolder) { $ofd.InitialDirectory = $packagesFolder }
        }
        if ($ofd.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) { $txtAppPackagePath.Text = $ofd.FileName }
    }.GetNewClosure())
    $lblIdStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblIdStatus)

    $TryFillIdFromCache = {
        $candidates = Find-IntuneMatches -Name $txtName.Text.Trim()
        if ($candidates.Count -eq 0) {
            $lblIdStatus.Text = "No matching app found in Intune for '$($txtName.Text.Trim())'."
            $lblIdStatus.ForeColor = [System.Drawing.Color]::DarkOrange
            Write-DialogLogLine -LogBox $editorLogBox.Box -Text "[WARN] No matching app found in Intune for `"$($txtName.Text.Trim())`".`r`n"
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
            # Start-IntuneAppLookup sets $Global:App.Form.Cursor itself, but
            # that's the MAIN window, which sits behind this modal editor
            # the whole time this runs - setting its cursor has no visible
            # effect here. Set/reset THIS dialog's own cursor instead so
            # there's actually a visible loading indicator (a live report:
            # this exact class of bug, just fixed the same way already in
            # Show-CreateInIntuneDialog).
            $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            # Fresh local aliases - see note in Show-CertificateSetupDialog's Test
            # Connection handler. The -OnComplete block below is a closure nested
            # inside this already-closured Add_Click handler, so it needs its own
            # freshly-assigned copies of anything it touches rather than reusing
            # $lblIdStatus/$TryFillIdFromCache directly.
            $dlgRef = $dlg
            $lblIdStatusRef = $lblIdStatus
            $tryFillRef = $TryFillIdFromCache
            $rtbAppEditorLogRef = $editorLogBox.Box
            Start-IntuneAppLookup -LogBox $rtbAppEditorLogRef -OnComplete {
                param($ok, $data)
                try {
                    if ($ok) { & $tryFillRef }
                    else {
                        $lblIdStatusRef.Text = "Lookup failed: $data"
                        $lblIdStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                        Write-DialogLogLine -LogBox $rtbAppEditorLogRef -Text "[FAILED] Lookup failed: $data`r`n"
                    }
                }
                finally {
                    # Cursor + Cursor.Current + DoEvents + a Position
                    # self-assignment - see Show-WingetSearchDialog's own
                    # note on why all four are needed for a reliable reset.
                    $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
                    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
                    [System.Windows.Forms.Application]::DoEvents()
                    [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
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
        if ($picked) {
            $txtWinget.Text = $picked
            # Setting .Text raises no Leave, so without this the Deploy
            # tabs kept treating a new app as a custom one - no install,
            # uninstall or detection, and its own missing .intunewin
            # instead of the shared init.intunewin - until you happened to
            # switch tabs. Pressing Deploy straight away sent that.
            if ($deploySyncBox.Run) { & $deploySyncBox.Run }
        }
    }.GetNewClosure())

    # What used to run when the separate Deploy window closed. The Intune
    # side is tabs of this window now, so it runs the moment a create or
    # update succeeds instead - same logic, same result object, handed to
    # Show-CreateInIntuneDialog as -OnDeployComplete.
    $ApplyDeployResult = {
        param($deployResult)

        # Previous/Next was clicked INSIDE "Intune Deployment" - none of
        # this handler's own staging/save logic below applies (there's
        # nothing from THIS app to stage; navigating away is a discard,
        # same as Cancel), so hand off to this editor's own navigation
        # exactly like its own Previous/Next buttons do, with
        # AutoOpenDeploy set so the next app lands straight back in
        # Deploy view instead of stopping on the plain editor screen.
        if ($null -ne $deployResult -and $null -ne $deployResult.NavigateToIndex) {
            # FormClosing asks first if anything unsaved would be lost
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
                Write-DialogLogLine -LogBox $editorLogBox.Box -Text "[FAILED] Deployed to Intune, but saving to the local catalog failed - see the Log tab for details.`r`n"
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
    }.GetNewClosure()

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
            if (-not (Confirm-CatalogOnlyDelete -AppName $txtName.Text.Trim() -UnsavedEdits:([bool](& $GetDiscardQuestion)))) { return }
            $delIdx = -1
            for ($di = 0; $di -lt $appsRef.Count; $di++) {
                if ($ExistingApp -and $appsRef[$di].appName -eq $ExistingApp.appName) { $delIdx = $di; break }
            }
            if ($delIdx -ge 0) { $appsRef.RemoveAt($delIdx) }
            $unsavedBoxRef.Value = $true
            [void](Save-AppsToFile -Path $linkedFilePath)
            $discardConfirmedBox.Value = $true
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
            $discardConfirmedBox.Value = $true
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
                # Not an Intune fact - the package is still on disk.
                packagePath      = [string]$existingForClear.packagePath
                requiredFor      = @($existingForClear.requiredFor)
                availableFor     = @($existingForClear.availableFor)
                uninstallFor     = @($existingForClear.uninstallFor)
                excludeFor       = @($existingForClear.excludeFor)
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
            Write-DialogLogLine -LogBox $editorLogBox.Box -Text "[FAILED] Deleted from Intune, but saving the cleared App ID locally failed - see the Log tab for details.`r`n"
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
        $gb.Size = New-Object System.Drawing.Size(820,120)

        $clb = New-Object System.Windows.Forms.CheckedListBox
        $clb.Location = New-Object System.Drawing.Point(10,20)
        # Width trimmed from 300 to 292 - the list used to end at x=310
        # (10+300), exactly where "+ New group..." starts, with zero gap
        # between them (a live screenshot showed the checkbox list and
        # button touching directly). $btnAddGroup's own x=310 is
        # unchanged, so this alone opens an 8px gap without needing to
        # move the button too.
        $clb.Size = New-Object System.Drawing.Size(682,85)
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
        # "+ Group/user...", not "+ New group..." - Show-EntraMemberPicker
        # below lets you pick a USER too, not just a group (confirmed:
        # its own picker list is prefixed "[Group]"/"[User]"), so the old
        # label was misleading about what this button actually does.
        $btnAddGroup.Text = "+ Group/user..."
        $btnAddGroup.Location = New-Object System.Drawing.Point(700,20)
        $btnAddGroup.Size = New-Object System.Drawing.Size(118,28)
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
    # Excluded groups apply to whichever of the three lists above this app
    # actually uses - that's what "everyone in X except Y" means, and it's
    # how the assignment push (Assignments.ps1) builds them.
    $excludeGroup = New-GroupBox -Title "Excluded from (overrides the lists above)" -Top 674 -Selected @($ExistingApp.excludeFor)
    $dlg.Controls.Add($reqGroup.Box)
    $dlg.Controls.Add($availGroup.Box)
    $dlg.Controls.Add($uninstGroup.Box)
    $dlg.Controls.Add($excludeGroup.Box)

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
    $btnReadGroupsFromIntune.Location = New-Object System.Drawing.Point(15,800)
    $btnReadGroupsFromIntune.Size = New-Object System.Drawing.Size(820,30)
    $dlg.Controls.Add($btnReadGroupsFromIntune)
    $readGroupsTip = New-Object System.Windows.Forms.ToolTip
    $readGroupsTip.SetToolTip($btnReadGroupsFromIntune, "Sets the group lists above to match Intune EXACTLY, not a merge - anything checked here that Intune doesn't actually have gets unchecked.")

    # Dedicated status label for the button right above - this used to
    # reuse $lblIdStatus (the App ID lookup status, up near the top of the
    # dialog around y=250), which put "Groups above now match..." nowhere
    # near the button/lists it was actually reporting on.
    $lblGroupSyncStatus = New-Object System.Windows.Forms.Label
    # A placeholder, not blank - otherwise this whole row reads as empty
    # dead space until the user has clicked Pull at least once, rather
    # than as a status line that just hasn't reported anything yet.
    # Overwritten by the real status (below) the moment Pull actually runs.
    $lblGroupSyncStatus.Text = "Not yet checked against Intune."
    $lblGroupSyncStatus.Location = New-Object System.Drawing.Point(15,834)
    $lblGroupSyncStatus.Size = New-Object System.Drawing.Size(820,18)
    $lblGroupSyncStatus.ForeColor = [System.Drawing.Color]::DimGray
    # A difference names groups, and group names run long - one line, cut
    # with "...", and the whole of it on hover and in the log.
    $lblGroupSyncStatus.AutoEllipsis = $true
    $dlg.Controls.Add($lblGroupSyncStatus)
    $groupStatusTip = New-Object System.Windows.Forms.ToolTip
    $showGroupStatus = {
        param([string]$Text, [System.Drawing.Color]$Color)
        $lblGroupSyncStatus.Text = $Text
        $lblGroupSyncStatus.ForeColor = $Color
        $groupStatusTip.SetToolTip($lblGroupSyncStatus, $Text)
    }.GetNewClosure()

    # What the three lists would look like as a catalog entry - the ticked
    # groups, i.e. what "Push groups" would send right now.
    $getTickedGroups = {
        [pscustomobject]@{
            requiredFor  = @($reqGroup.List.CheckedItems | ForEach-Object { [string]$_ })
            availableFor = @($availGroup.List.CheckedItems | ForEach-Object { [string]$_ })
            uninstallFor = @($uninstGroup.List.CheckedItems | ForEach-Object { [string]$_ })
        }
    }.GetNewClosure()

    # Run whenever the Intune side of this window fetches the app's live
    # values (see Show-CreateInIntuneDialog -OnLiveFetch). That fetch has
    # always carried the live group assignments too; nothing here compared
    # them, so this tab said "Not yet checked" however fresh the data was,
    # and a difference only ever showed up in the audit - without saying
    # which side had which groups. It says now, and changes nothing: which
    # side is right is yours to say, with Pull or Push below.
    # Whether a comparison has happened (or is on its way) in this window -
    # so opening the Assignments tab starts one only when nothing else has.
    # Pulled: "Pull groups from Intune" has since set the lists from Intune.
    # A compare still in flight from before then would only say "matches"
    # over Pull's own message, which carries the "save to keep this" hint.
    $groupsCheckedBox = @{ Done = $false; Running = $false; Pulled = $false }
    # $deployHostBox (declared near the top) is asked here whether the
    # Deploy side is already reading from Intune (IsReadingLive).
    $compareGroupsWithIntune = {
        param($data)
        # Whatever this answer is, nothing is on its way any more.
        $groupsCheckedBox.Running = $false
        if ($groupsCheckedBox.Pulled) { return }
        # $null: the read itself failed (the Deploy side reports that too).
        if ($null -eq $data) {
            & $showGroupStatus "Could not compare with Intune - the read failed, see the log." ([System.Drawing.Color]::Firebrick)
            return
        }
        if (-not $data.GroupFetchOk) {
            & $showGroupStatus "Could not read this app's groups from Intune - not compared." ([System.Drawing.Color]::Firebrick)
            return
        }
        $groupsCheckedBox.Done = $true
        $diffs = @(Get-GroupFieldDiffs -LocalApp (& $getTickedGroups) -RemoteResult $data)
        if ($diffs.Count -eq 0) {
            # Required, Available and Uninstall - exclusions are not part of
            # what Intune's assignments are compared on here, so this does
            # not claim they match.
            & $showGroupStatus "Required, Available and Uninstall match Intune." ([System.Drawing.Color]::SeaGreen)
        }
        else {
            $parts = foreach ($d in $diffs) {
                $hereText = if ($d.Local) { $d.Local } else { "(none)" }
                $intuneText = if ($d.Remote) { $d.Remote } else { "(none)" }
                "$($d.Field) - ticked here: $hereText | Intune: $intuneText"
            }
            & $showGroupStatus "Differs from Intune: $($parts -join '; ')" ([System.Drawing.Color]::DarkOrange)
            foreach ($p in $parts) { Write-DialogLogLine -LogBox $editorLogBox.Box -Text "[WARN] Groups differ from Intune - $p`r`n" }
            Write-DialogLogLine -LogBox $editorLogBox.Box -Text "[INFO] Intune is right: Pull groups from Intune. The groups ticked here are right: Push groups to Intune.`r`n"
        }
        # The Last Audit column is about the SAVED entry, not unsaved ticks,
        # so that one compares what is on disk - and only when the fetch was
        # for that entry's own App ID, not one typed into the box since.
        if ($ExistingApp -and $ExistingApp.appName -and $ExistingApp.appId -and $txtId.Text.Trim() -eq [string]$ExistingApp.appId) {
            Set-LastAuditCacheEntry -AppName ([string]$ExistingApp.appName) -Groups (Format-GroupFieldDiffs -Diffs (Get-GroupFieldDiffs -LocalApp $ExistingApp -RemoteResult $data))
        }
    }.GetNewClosure()

    # Once compared, ticking or unticking a group makes "match" or
    # "differs" out of date - so it says that instead of standing still.
    # Not while Pull itself sets the ticks (Applying), which reports its own.
    $markGroupsEdited = {
        if (-not $groupsCheckedBox.Done -or $groupsCheckedBox.Applying) { return }
        & $showGroupStatus "Changed here since the comparison with Intune - Push groups sends these, Pull groups takes Intune's." ([System.Drawing.Color]::DimGray)
    }.GetNewClosure()
    foreach ($groupList in @($reqGroup.List, $availGroup.List, $uninstGroup.List)) { $groupList.Add_ItemCheck($markGroupsEdited) }

    $btnAssignGroups = New-Object System.Windows.Forms.Button
    $btnAssignGroups.Text = "Push groups to Intune (single app)..."
    $btnAssignGroups.Location = New-Object System.Drawing.Point(15,856)
    # Same 820 as "Pull groups from Intune..." three rows up. These two are
    # the same idea in opposite directions and each owns its row, so a 430
    # button with dead space beside it just made the column look unfinished.
    $btnAssignGroups.Size = New-Object System.Drawing.Size(820,30)
    $dlg.Controls.Add($btnAssignGroups)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Save app to catalog"
    $btnOk.Location = New-Object System.Drawing.Point(15,984)
    $btnOk.Size = New-Object System.Drawing.Size(150,32)
    $dlg.Controls.Add($btnOk)

    # $btnDeleteFromIntune itself is created earlier, up next to
    # $btnCreateInIntune's own logic - only its position, right here to
    # the right of "Save app to catalog", is decided at this end of the
    # bottom row.
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(365,984)
    $btnCancel.Size = New-Object System.Drawing.Size(90,32)
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
    $btnPrevApp.Location = New-Object System.Drawing.Point(15,1024)
    $btnPrevApp.Size = New-Object System.Drawing.Size(150,30)
    $btnPrevApp.Enabled = ($null -ne $prevAppIndex)
    $btnPrevApp.Visible = ($CurrentIndex -ge 0)
    $dlg.Controls.Add($btnPrevApp)
    $prevAppTip = New-Object System.Windows.Forms.ToolTip
    $prevAppTip.SetToolTip($btnPrevApp, "Opens the previous app. Asks first if this one has unsaved changes.")

    $lblAppNavPosition = New-Object System.Windows.Forms.Label
    $lblAppNavPosition.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblAppNavPosition.Location = New-Object System.Drawing.Point(170,1024)
    $lblAppNavPosition.Size = New-Object System.Drawing.Size(130,30)
    $lblAppNavPosition.ForeColor = [System.Drawing.Color]::DimGray
    if ($CurrentIndex -ge 0) {
        # The same list Previous/Next use, so "3 of 12" counts what they step through.
        $visiblePosForLabel = $visibleAppIndices.IndexOf($CurrentIndex) + 1
        $lblAppNavPosition.Text = if ($visiblePosForLabel -gt 0) { "$visiblePosForLabel of $($visibleAppIndices.Count)" } else { "" }
    }
    $dlg.Controls.Add($lblAppNavPosition)

    $btnNextApp = New-Object System.Windows.Forms.Button
    $btnNextApp.Text = "Next app >"
    $btnNextApp.Location = New-Object System.Drawing.Point(305,1024)
    $btnNextApp.Size = New-Object System.Drawing.Size(150,30)
    $btnNextApp.Enabled = ($null -ne $nextAppIndex)
    $btnNextApp.Visible = ($CurrentIndex -ge 0)
    $dlg.Controls.Add($btnNextApp)
    $nextAppTip = New-Object System.Windows.Forms.ToolTip
    $nextAppTip.SetToolTip($btnNextApp, "Opens the next app. Asks first if this one has unsaved changes.")

    # The catalog entry and its assignments become two tabs, so that the
    # Intune side can join them as three more (Show-CreateInIntuneDialog,
    # -HostTabControl) and an app is one window rather than two.
    # $editorTabs.Name is set right after this call, for the same reason
    # $txtWingetId carries one.
    $editorTabs = Convert-PanelToTabs -Dialog $dlg -Bounds (New-Object System.Drawing.Rectangle(10, 8, 880, 651)) -Pages @(
        @{
            Title = 'Catalog'
            Controls = @(
                $lblName, $txtName,
                $lblWinget, $txtWinget, $btnSearchWinget, $lblUncommonNote,
                $lblId, $txtId, $btnLookupId, $lblIdStatus,
                $lblAppPackagePath, $txtAppPackagePath, $btnBrowseAppPackage
            )
        }
        @{
            Title = 'Assignments'
            Controls = @(
                $reqGroup.Box, $availGroup.Box, $uninstGroup.Box, $excludeGroup.Box,
                $btnReadGroupsFromIntune, $lblGroupSyncStatus, $btnAssignGroups
            )
        }
    )
    $editorTabs.Name = 'editorTabs'

    # The Assignments tab compares with Intune the first time it is opened,
    # unless something already has in this window (the Deploy side's own
    # fetch does, when "Check Intune when opening Deploy" is on). Without
    # this the tab said "Not yet checked" until an unrelated button was
    # pressed. It only reads, and only once.
    $editorTabs.Add_SelectedIndexChanged({
        if ($groupsCheckedBox.Done -or $groupsCheckedBox.Running) { return }
        if (-not $editorTabs.SelectedTab -or $editorTabs.SelectedTab.Text -ne 'Assignments') { return }
        $appIdNow = $txtId.Text.Trim()
        if (-not $appIdNow) { return }
        $groupsCheckedBox.Running = $true
        & $showGroupStatus "Comparing with Intune..." ([System.Drawing.Color]::DimGray)
        # The Deploy side may be reading this same app from Intune already
        # (it does on opening, with "Check Intune when opening Deploy" on).
        # Its answer comes here through -OnLiveFetch - good or failed - so
        # wait for it rather than send the same read twice. Only for the
        # App ID it was opened with, which is the one it reads.
        $deployHostNow = $deployHostBox.Host
        if ($deployHostNow -and $deployHostNow.IsReadingLive -and (& $deployHostNow.IsReadingLive) -and $appIdNow -eq $deployHostBox.AppId) { return }
        # Fresh aliases for the nested -OnComplete closure.
        $groupsCheckedBoxRef = $groupsCheckedBox
        $showGroupStatusRef = $showGroupStatus
        $compareRef = $compareGroupsWithIntune
        $dlgRef3 = $dlg
        Start-AppMetadataFetch -AppId $appIdNow -LogBox $editorLogBox.Box -OnComplete {
            param($ok, $errMsg, $data)
            $groupsCheckedBoxRef.Running = $false
            if ($dlgRef3.IsDisposed) { return }
            if (-not $ok) {
                & $showGroupStatusRef "Could not compare with Intune: $errMsg" ([System.Drawing.Color]::Firebrick)
                return
            }
            & $compareRef $data
        }.GetNewClosure()
    }.GetNewClosure())
    # Its own log belongs with the actions that write to it - the App ID
    # lookup and Delete from Intune, both on Catalog.
    $rtbAppEditorLog.Location = New-Object System.Drawing.Point(12,300)
    $rtbAppEditorLog.Size = New-Object System.Drawing.Size(820,150)
    $txtName.Size = New-Object System.Drawing.Size(820,24)
    $lblUncommonNote.Size = New-Object System.Drawing.Size(820,32)
    $lblIdStatus.Size = New-Object System.Drawing.Size(820,40)
    # Straight under App ID. The editor's own log used to sit between them
    # and moved out to the shared one at the bottom of the window, so
    # anything placed where it was just leaves a hole on this page.
    $lblAppPackagePath.Location = New-Object System.Drawing.Point(12,300)
    $txtAppPackagePath.Location = New-Object System.Drawing.Point(12,320)
    $txtAppPackagePath.Size = New-Object System.Drawing.Size(706,24)
    $btnBrowseAppPackage.Location = New-Object System.Drawing.Point(726,319)
    $btnBrowseAppPackage.Size = New-Object System.Drawing.Size(106,26)
    # What it resolves to today, greyed inside the empty box - the same
    # "here is the default you are inheriting" the Folders tab uses. Only
    # for an app that has its own package; a Winget app deploys with the
    # shared init.intunewin and has nothing useful to show here.
    if ($ExistingApp -and (Test-AppIsUncommon -App $ExistingApp)) {
        $predicted = Resolve-AppPackagePath -AppName ([string]$ExistingApp.appName) -Uncommon $true
        $hint = if ($predicted.Found) { $predicted.Path } else { "$($predicted.Path)  (not there yet)" }
        Set-TextBoxPlaceholder -Box $txtAppPackagePath -Text $hint
    }
    else {
        # A placeholder only shows while the box is EMPTY, so this says
        # what happens when nothing is set - which for a Winget app is the
        # shared package. Setting a path overrides that, deliberately:
        # having a Winget ID is not the same as having no package of your
        # own, and the label above says which wins.
        Set-TextBoxPlaceholder -Box $txtAppPackagePath -Text "Empty - this Winget app deploys with the shared init.intunewin"
    }

    # Where this app's package actually is, resolved - the answer the main
    # grid's "Package folder" column used to give, moved here because a full
    # path was the widest thing in that grid and the least often read. The
    # box above says what you SET; this card says what that resolves to,
    # whether it is there, and takes you to it.
    $palette = $Global:App.LightPalette
    $cardBack = [System.Drawing.Color]::FromArgb(250,251,252)
    $pnlPackageLocation = New-Object System.Windows.Forms.Panel
    $pnlPackageLocation.Name = 'pnlPackageLocation'
    $pnlPackageLocation.Location = New-Object System.Drawing.Point(12,360)
    $pnlPackageLocation.Size = New-Object System.Drawing.Size(820,124)
    $pnlPackageLocation.BackColor = $cardBack
    $cardBorder = $palette.BorderColor
    $pnlPackageLocation.Add_Paint({
        param($sender, $e)
        $pen = New-Object System.Drawing.Pen($cardBorder)
        $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1)
        $pen.Dispose()
    }.GetNewClosure())
    $txtAppPackagePath.Parent.Controls.Add($pnlPackageLocation)

    $lblPkgHeading = New-Object System.Windows.Forms.Label
    $lblPkgHeading.Text = "Package location"
    $lblPkgHeading.Font = New-Object System.Drawing.Font($dlg.Font, [System.Drawing.FontStyle]::Bold)
    $lblPkgHeading.Location = New-Object System.Drawing.Point(14,12)
    $lblPkgHeading.AutoSize = $true
    $pnlPackageLocation.Controls.Add($lblPkgHeading)

    # A coloured pill beside the heading - the one thing to take in at a
    # glance. Positioned from the heading's measured width, so it follows
    # whatever font size the app runs at.
    $lblPkgState = New-Object System.Windows.Forms.Label
    $lblPkgState.Name = 'lblPackageState'
    $lblPkgState.AutoSize = $true
    $lblPkgState.Padding = New-Object System.Windows.Forms.Padding(8,2,8,2)
    $lblPkgState.Font = New-Object System.Drawing.Font($dlg.Font.FontFamily, ($dlg.Font.Size - 0.5), [System.Drawing.FontStyle]::Bold)
    $headingWidth = [System.Windows.Forms.TextRenderer]::MeasureText($lblPkgHeading.Text, $lblPkgHeading.Font).Width
    $lblPkgState.Location = New-Object System.Drawing.Point((14 + $headingWidth + 10), 10)
    $pnlPackageLocation.Controls.Add($lblPkgState)

    $captionColor = [System.Drawing.Color]::FromArgb(110,115,125)
    $lblPkgFolderCaption = New-Object System.Windows.Forms.Label
    $lblPkgFolderCaption.Text = "Folder"
    $lblPkgFolderCaption.ForeColor = $captionColor
    $lblPkgFolderCaption.Location = New-Object System.Drawing.Point(14,42)
    $lblPkgFolderCaption.Size = New-Object System.Drawing.Size(60,20)
    $pnlPackageLocation.Controls.Add($lblPkgFolderCaption)

    # AutoEllipsis rather than wrapping: a path is one line or it is
    # unreadable. The whole of it is in the tooltip and on Copy path.
    $lblPkgFolder = New-Object System.Windows.Forms.Label
    $lblPkgFolder.Name = 'lblPackageFolder'
    $lblPkgFolder.AutoEllipsis = $true
    $lblPkgFolder.Location = New-Object System.Drawing.Point(78,42)
    $lblPkgFolder.Size = New-Object System.Drawing.Size(600,20)
    $pnlPackageLocation.Controls.Add($lblPkgFolder)

    $lblPkgFileCaption = New-Object System.Windows.Forms.Label
    $lblPkgFileCaption.Text = "File"
    $lblPkgFileCaption.ForeColor = $captionColor
    $lblPkgFileCaption.Location = New-Object System.Drawing.Point(14,66)
    $lblPkgFileCaption.Size = New-Object System.Drawing.Size(60,20)
    $pnlPackageLocation.Controls.Add($lblPkgFileCaption)

    $lblPkgFile = New-Object System.Windows.Forms.Label
    $lblPkgFile.Name = 'lblPackageFile'
    $lblPkgFile.AutoEllipsis = $true
    $lblPkgFile.Location = New-Object System.Drawing.Point(78,66)
    $lblPkgFile.Size = New-Object System.Drawing.Size(600,20)
    $pnlPackageLocation.Controls.Add($lblPkgFile)

    $lblPkgNote = New-Object System.Windows.Forms.Label
    $lblPkgNote.AutoEllipsis = $true
    $lblPkgNote.ForeColor = $captionColor
    $lblPkgNote.Location = New-Object System.Drawing.Point(14,94)
    $lblPkgNote.Size = New-Object System.Drawing.Size(664,20)
    $pnlPackageLocation.Controls.Add($lblPkgNote)

    $btnOpenPkgFolder = New-Object System.Windows.Forms.Button
    $btnOpenPkgFolder.Name = 'btnOpenPackageFolder'
    $btnOpenPkgFolder.Text = "Open folder"
    $btnOpenPkgFolder.Location = New-Object System.Drawing.Point(692,38)
    $btnOpenPkgFolder.Size = New-Object System.Drawing.Size(114,28)
    $pnlPackageLocation.Controls.Add($btnOpenPkgFolder)

    $btnCopyPkgPath = New-Object System.Windows.Forms.Button
    $btnCopyPkgPath.Name = 'btnCopyPackagePath'
    $btnCopyPkgPath.Text = "Copy path"
    $btnCopyPkgPath.Location = New-Object System.Drawing.Point(692,72)
    $btnCopyPkgPath.Size = New-Object System.Drawing.Size(114,28)
    $pnlPackageLocation.Controls.Add($btnCopyPkgPath)

    # Where Open folder is, in its place, when there is no package yet for
    # an app that needs its own - the card is where that is noticed, and
    # the packaging step was only reachable from the grid's menu.
    $btnPackageNow = New-Object System.Windows.Forms.Button
    $btnPackageNow.Name = 'btnPackageNow'
    $btnPackageNow.Text = "Package now..."
    $btnPackageNow.Location = $btnOpenPkgFolder.Location
    $btnPackageNow.Size = $btnOpenPkgFolder.Size
    $btnPackageNow.Visible = $false
    $pnlPackageLocation.Controls.Add($btnPackageNow)

    $pkgTip = New-Object System.Windows.Forms.ToolTip
    $pkgTip.SetToolTip($btnPackageNow, "Builds this app's .intunewin from its source folder, the same as Package this app for Intune in the grid's right-click menu.")
    $pkgTip.SetToolTip($btnOpenPkgFolder, "Open this folder in Explorer, with the package selected.")
    $pkgTip.SetToolTip($btnCopyPkgPath, "Copy the full path of the package (or of the folder it belongs in) to the clipboard.")

    # What the two buttons act on - written by the refresh below, read by
    # their handlers. A box, for the same closure reason as every other one
    # in this function.
    $pkgLocationBox = @{ Folder = ""; File = "" }
    $existingIntuneType = if ($ExistingApp) { [string]$ExistingApp.intuneAppType } else { "" }

    $refreshPackageLocation = {
        $name = $txtName.Text.Trim()
        $override = $txtAppPackagePath.Text.Trim()
        $isUncommon = [string]::IsNullOrWhiteSpace($txtWinget.Text)
        # The same "never a package from this tool" rule the grid's Status
        # uses - a Store or M365 app is not missing a package, it has none.
        $isKnownNonWin32 = $existingIntuneType -and $existingIntuneType -ne "Windows app (Win32)"

        $state = ""; $stateFore = $null; $stateBack = $null
        $folder = ""; $file = ""; $note = ""
        $okFore = [System.Drawing.Color]::FromArgb(22,101,52);   $okBack = [System.Drawing.Color]::FromArgb(220,252,231)
        $badFore = [System.Drawing.Color]::FromArgb(153,27,27);  $badBack = [System.Drawing.Color]::FromArgb(254,226,226)
        $infoFore = [System.Drawing.Color]::FromArgb(30,64,175); $infoBack = [System.Drawing.Color]::FromArgb(219,234,254)
        $offFore = [System.Drawing.Color]::FromArgb(75,85,99);   $offBack = [System.Drawing.Color]::FromArgb(229,231,235)

        if ($isKnownNonWin32 -and -not $override) {
            $state = "Not applicable"; $stateFore = $offFore; $stateBack = $offBack
            $note = "A $existingIntuneType app - Intune does not install it from a package this tool builds."
        }
        elseif ($isUncommon -and -not $name -and -not $override) {
            $state = "No name yet"; $stateFore = $offFore; $stateBack = $offBack
            $note = "Give the app a name to see where its package is expected."
        }
        else {
            $pkg = Resolve-AppPackagePath -AppName $name -Uncommon $isUncommon -PackagePath $override
            $looksLikeFile = [IO.Path]::GetExtension([string]$pkg.Path) -ne ""
            if ($pkg.Found) {
                $folder = Split-Path -Parent $pkg.Path
                $file = Split-Path -Leaf $pkg.Path
            }
            elseif ($looksLikeFile) {
                $folder = Split-Path -Parent $pkg.Path
                $file = Split-Path -Leaf $pkg.Path
            }
            else {
                $folder = [string]$pkg.Path
            }

            if ($override) {
                $note = if ($pkg.Found) { "Set in the box above - this package wins, Winget ID or not." }
                        else { "The path in the box above has no single .intunewin - pick the file itself." }
            }
            elseif ($isUncommon) {
                $note = if ($pkg.Found) { "Found by the app's name in the packages folder." }
                        else { "Nothing there yet - package the app, or point the box above at its .intunewin." }
            }
            else {
                $note = "A Winget app - it deploys with the shared init.intunewin, like every other one."
            }

            if (-not $pkg.Found) {
                $state = "Not found"; $stateFore = $badFore; $stateBack = $badBack
            }
            elseif (-not $isUncommon -and -not $override) {
                $state = "Shared package"; $stateFore = $infoFore; $stateBack = $infoBack
            }
            else {
                $state = "Found"; $stateFore = $okFore; $stateBack = $okBack
            }
        }

        $lblPkgState.Text = $state
        $lblPkgState.ForeColor = $stateFore
        $lblPkgState.BackColor = $stateBack
        $lblPkgFolder.Text = if ($folder) { $folder } else { [string][char]0x2014 }
        $lblPkgFile.Text = if ($file) { $file } else { [string][char]0x2014 }
        $lblPkgNote.Text = $note
        $fullPath = if ($file -and $folder) { Join-Path $folder $file } elseif ($folder) { $folder } else { $file }
        $pkgTip.SetToolTip($lblPkgFolder, $folder)
        $pkgTip.SetToolTip($lblPkgFile, $fullPath)
        $pkgTip.SetToolTip($lblPkgNote, $note)
        # The box itself, too: a long path is cut off at its right edge, and
        # an empty box shows its greyed default, which is cut off the same
        # way. What is typed, when something is; otherwise what it resolves to.
        $boxTip = if ($override) { $override } elseif ($fullPath) { "$fullPath  (default)" } else { $note }
        $pkgTip.SetToolTip($txtAppPackagePath, $boxTip)
        $pkgLocationBox.Folder = $folder
        $pkgLocationBox.File = if ($file -and (Test-Path -LiteralPath (Join-Path $folder $file) -PathType Leaf)) { Join-Path $folder $file } else { "" }
        $btnOpenPkgFolder.Enabled = [bool]($folder -and (Test-Path -LiteralPath $folder -PathType Container))
        $btnCopyPkgPath.Enabled = [bool]$folder
        # Only for the package this tool builds itself: an app with no
        # Winget ID, found by name, not there yet. A path typed into the
        # box above is someone else's package to build.
        $canPackage = ($state -eq "Not found") -and $isUncommon -and (-not $override) -and [bool]$name
        $btnPackageNow.Visible = $canPackage
        $btnOpenPkgFolder.Visible = -not $canPackage
    }.GetNewClosure()

    $btnOpenPkgFolder.Add_Click({
        # /select opens the folder with the package highlighted; without a
        # file there, the folder alone.
        if ($pkgLocationBox.File) { Start-Process explorer.exe -ArgumentList "/select,`"$($pkgLocationBox.File)`"" }
        elseif ($pkgLocationBox.Folder) { Start-Process explorer.exe -ArgumentList "`"$($pkgLocationBox.Folder)`"" }
    }.GetNewClosure())
    $btnPackageNow.Add_Click({
        $packageName = $txtName.Text.Trim()
        if (-not $packageName) { return }
        Show-PackagingProgressDialog -SingleFolderName (Get-SafeFileNameForApp -Name $packageName)
        # Whatever packaging did, the card says what is there now.
        & $refreshPackageLocation
    }.GetNewClosure())
    $btnCopyPkgPath.Add_Click({
        $toCopy = if ($pkgLocationBox.File) { $pkgLocationBox.File } else { $pkgLocationBox.Folder }
        if ($toCopy) {
            [System.Windows.Forms.Clipboard]::SetText($toCopy)
            Write-DialogLogLine -LogBox $editorLogBox.Box -Text "[OK] Copied to the clipboard: $toCopy`r`n"
        }
    }.GetNewClosure())

    # Resolving walks the packages folder, so typing a name does not do it
    # per keystroke - the timer restarts on each change and fires once the
    # typing stops.
    $pkgRefreshTimer = New-Object System.Windows.Forms.Timer
    $pkgRefreshTimer.Interval = 350
    $pkgRefreshTimer.Add_Tick({ $pkgRefreshTimer.Stop(); & $refreshPackageLocation }.GetNewClosure())
    $restartPkgRefresh = { $pkgRefreshTimer.Stop(); $pkgRefreshTimer.Start() }.GetNewClosure()
    $txtName.Add_TextChanged($restartPkgRefresh)
    $txtWinget.Add_TextChanged($restartPkgRefresh)
    $txtAppPackagePath.Add_TextChanged($restartPkgRefresh)
    $dlg.Add_FormClosed({ $pkgRefreshTimer.Stop(); $pkgRefreshTimer.Dispose() }.GetNewClosure())
    & $refreshPackageLocation

    # The Intune side, as three more tabs of this same window. Its status
    # box, log and Deploy button come with it and sit under every tab, so
    # there is one place things are reported and one button that sends.
    # Read when a deploy succeeds, not now: these are the editor's own live
    # checkboxes, on a tab of this same window, and they can be ticked
    # while the Deploy tab is sitting open. A snapshot taken here would
    # push whatever was selected when the editor opened.
    $deployHost = Show-CreateInIntuneDialog -AppName $txtName.Text.Trim() -WingetId $txtWinget.Text.Trim() -PackagePath $txtAppPackagePath.Text.Trim() `
        -ExistingAppId $txtId.Text.Trim() -FromAppEditor -CallerHasExistingCatalogEntry:([bool]$ExistingApp) `
        -CurrentIndex $CurrentIndex -HostTabControl $editorTabs -HostForm $dlg -HostBottomY 667 `
        -OnDeployComplete $ApplyDeployResult -OnLiveFetch $compareGroupsWithIntune -PreferLocal:$PreferLocal `
        -GetAssignGroups {
            @{
                Required  = @($reqGroup.List.CheckedItems | ForEach-Object { [string]$_ })
                Available = @($availGroup.List.CheckedItems | ForEach-Object { [string]$_ })
                Uninstall = @($uninstGroup.List.CheckedItems | ForEach-Object { [string]$_ })
                Exclude   = @($excludeGroup.List.CheckedItems | ForEach-Object { [string]$_ })
            }
        }.GetNewClosure()
    # For the Assignments tab's compare (see its SelectedIndexChanged): the
    # Deploy side, and the App ID it reads - the one it was opened with.
    $deployHostBox.Host = $deployHost
    $deployHostBox.AppId = $txtId.Text.Trim()

    # The Winget ID is typed here, on this tab, after the tabs above were
    # built - so for "Add app..." the Package and detection tab was built
    # for an app with no Winget ID, which means no install command, no
    # uninstall command and no detection script, and nothing that would
    # ever fill them in. Telling it the ID changed regenerates exactly the
    # fields still holding what it generated before.
    # Declared, so Deploy's catch-up below never picks up a caller's
    # variable of the same name when a hook isn't offered.
    $syncWingetId = $null
    $syncAppName = $null
    if ($deployHost.RetargetWingetId) {
        $retargetRef = $deployHost.RetargetWingetId
        $wingetBoxRef = $txtWinget
        # Remembers what the deploy side was last told, so this is free to
        # fire often and only does the work when the ID has really moved.
        $lastWingetIdBox = @{ Value = $txtWinget.Text.Trim() }
        $syncWingetId = {
            $nowId = $wingetBoxRef.Text.Trim()
            if ($nowId -eq $lastWingetIdBox.Value) { return }
            $lastWingetIdBox.Value = $nowId
            & $retargetRef $nowId
        }.GetNewClosure()

        # Not TextChanged: regenerating a detection script on every
        # keystroke means doing it once per character of "7zip.7zip", and
        # every value but the last one is wrong anyway. So two moments
        # instead, because there are two ways this field changes and only
        # one of them involves the keyboard:
        $txtWinget.Add_Leave($syncWingetId)
        $deploySyncBox.Run = $syncWingetId

        # The app's name fills the display name on the Metadata tab, for
        # the same reason and by the same route: that tab is built before
        # "Add app..." has a name to build it from.
        if ($deployHost.RetargetAppName) {
            $retargetNameRef = $deployHost.RetargetAppName
            $nameBoxRef = $txtName
            $lastNameBox = @{ Value = $txtName.Text.Trim() }
            $syncAppName = {
                $nowName = $nameBoxRef.Text.Trim()
                if ($nowName -eq $lastNameBox.Value) { return }
                $lastNameBox.Value = $nowName
                & $retargetNameRef $nowName
            }.GetNewClosure()
            $txtName.Add_Leave($syncAppName)
            $editorTabs.Add_SelectedIndexChanged($syncAppName)
        }
        # ...and "Search winget..." assigns .Text directly (see
        # $btnSearchWinget above), which raises no Leave at all - the field
        # was never focused. Switching tabs is the moment the generated
        # fields are about to be looked at, whichever way the ID got there,
        # so it is the one hook that cannot be got round.
        $editorTabs.Add_SelectedIndexChanged($syncWingetId)
    }

    # The package override on the Catalog tab, by the same two routes -
    # Browse... assigns .Text, so again no Leave.
    $syncPackagePath = $null
    if ($deployHost.RetargetPackagePath) {
        $retargetPkgRef = $deployHost.RetargetPackagePath
        $pkgBoxRef = $txtAppPackagePath
        $lastPkgBox = @{ Value = $txtAppPackagePath.Text.Trim() }
        $syncPackagePath = {
            $nowPkg = $pkgBoxRef.Text.Trim()
            if ($nowPkg -eq $lastPkgBox.Value) { return }
            $lastPkgBox.Value = $nowPkg
            & $retargetPkgRef $nowPkg
        }.GetNewClosure()
        $txtAppPackagePath.Add_Leave($syncPackagePath)
        $editorTabs.Add_SelectedIndexChanged($syncPackagePath)
    }

    # Every one of those hooks can be got round - a field set from code, or
    # Deploy pressed without a tab switch or a Leave in between - and what
    # that cost was a new app deploying with ...\App.intunewin, the
    # package of an app with no name. So Deploy runs all three itself
    # before it checks anything; each is a no-op when nothing moved.
    if ($deployHost.BeforeDeploy) {
        $beforeSyncs = @($syncAppName, $syncWingetId, $syncPackagePath | Where-Object { $_ })
        $deployHost.BeforeDeploy.Run = {
            foreach ($beforeSync in $beforeSyncs) { & $beforeSync }
        }.GetNewClosure()
    }

    # Its own two launch buttons were how you reached that window. There is
    # no second window now.
    $btnCreateInIntune.Visible = $false
    $btnSaveAndDeployWinget.Visible = $false

    # One log for the window. The editor's own box goes away and everything
    # it had to say goes to the log under every tab, which is where the
    # deploy side already reports - see $editorLogBox.
    if ($deployHost.Log) {
        $editorLogBox.Box = $deployHost.Log
        $rtbAppEditorLog.Visible = $false
        $dlg.Controls.Remove($rtbAppEditorLog)
    }

    # The bottom of the window, below every tab, laid out from the window's
    # own edges rather than from numbers that happened to fit once: one
    # left margin for everything, one right edge for everything, and every
    # gap between neighbours the same.
    #
    # Two rows, because seven controls do not fit across 900px, and they
    # split by what they are for: what this window can DO on top, moving
    # between apps underneath. What the deploy side contributes (Update
    # Metadata / Deploy) joins the top row beside Cancel instead of
    # floating on a line of its own above it.
    $edgeLeft = 15
    $edgeRight = $dlg.ClientSize.Width - $edgeLeft
    $gap = 10
    $rowActions = 931
    $rowNavigate = 969

    # The status lines and the log reach the same edges, so the block above
    # the buttons lines up with them instead of ending short of the window.
    # "Refresh from Intune" (and "Compare...", when there is something to
    # compare) belong with what they affect - the status line and the
    # fields it describes - not down in the row of things that finish the
    # window. They sit at the right of the status band, and the status
    # text stops where they begin.
    $deploySideButtons = @($deployHost.Refresh, $deployHost.Diff | Where-Object { $_ })
    $sideButtonsWidth = 0
    $sideX = $edgeRight
    foreach ($btn in $deploySideButtons) {
        $sideX = $sideX - $btn.Width
        $btn.Location = New-Object System.Drawing.Point($sideX,667)
        $sideX = $sideX - $gap
        $sideButtonsWidth += $btn.Width + $gap
    }

    $statusPanel = $deployHost.Status.Parent
    if ($statusPanel) {
        $statusPanel.Location = New-Object System.Drawing.Point($edgeLeft,667)
        $statusPanel.Size = New-Object System.Drawing.Size(($edgeRight - $edgeLeft - $sideButtonsWidth),112)
        # The status text and the legend were built 830 wide for a window
        # that was 870 across with nothing beside them. Narrowed by the
        # buttons now to their right, they have to be narrowed too - left
        # alone they run past the panel's edge and it grows a sideways
        # scrollbar under two lines of plain text. Both then wrap onto a
        # second line, so both get the height for two.
        foreach ($child in $statusPanel.Controls) {
            $child.Width = $statusPanel.ClientSize.Width - $statusPanel.Padding.Horizontal - 4
            $child.Height = 44
        }
    }
    if ($deployHost.Log) {
        $deployHost.Log.Location = New-Object System.Drawing.Point($edgeLeft,787)
        $deployHost.Log.Size = New-Object System.Drawing.Size(($edgeRight - $edgeLeft),132)
    }

    $btnOk.Location = New-Object System.Drawing.Point($edgeLeft,$rowActions)
    $btnDeleteFromIntune.Location = New-Object System.Drawing.Point(($btnOk.Right + $gap),$rowActions)
    # Cancel on the right edge, the deploy button immediately left of it:
    # the two "I am finished here" actions together, and both as far as
    # possible from the destructive one on the left.
    $btnCancel.Location = New-Object System.Drawing.Point(($edgeRight - $btnCancel.Width),$rowActions)
    if ($deployHost.Deploy) {
        $deployHost.Deploy.Location = New-Object System.Drawing.Point(($btnCancel.Left - $gap - $deployHost.Deploy.Width),$rowActions)
    }

    # Previous on the left edge, Next on the right edge, and "3 of 12"
    # centred between them - the shape of the thing it describes. Bunched
    # together at the left, the counter read like a third button.
    $btnPrevApp.Location = New-Object System.Drawing.Point($edgeLeft,$rowNavigate)
    $btnNextApp.Location = New-Object System.Drawing.Point(($edgeRight - $btnNextApp.Width),$rowNavigate)
    $lblAppNavPosition.Size = New-Object System.Drawing.Size(($btnNextApp.Left - $btnPrevApp.Right - ($gap * 2)),$btnPrevApp.Height)
    $lblAppNavPosition.Location = New-Object System.Drawing.Point(($btnPrevApp.Right + $gap),$rowNavigate)
    $lblAppNavPosition.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

    # FormClosing asks first if anything unsaved would be lost
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
            -RequiredGroups @($reqGroup.List.CheckedItems) -AvailableGroups @($availGroup.List.CheckedItems) -UninstallGroups @($uninstGroup.List.CheckedItems) `
            -ExcludeGroups @($excludeGroup.List.CheckedItems) | Out-Null
    }.GetNewClosure())

    $btnReadGroupsFromIntune.Add_Click({
        if (-not $txtId.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("This app has no App ID yet - there's nothing in Intune to read groups from.", "No App ID", "OK", "Information") | Out-Null
            return
        }
        $btnReadGroupsFromIntune.Enabled = $false
        # Every status here goes through $showGroupStatus, so the tooltip
        # always matches the line - it used to keep the text before.
        & $showGroupStatus "Reading current group assignments from Intune..." ([System.Drawing.Color]::DimGray)
        # Start-AppMetadataFetch has no cursor handling of its own - this
        # button gave no visible loading feedback beyond the status label.
        # Same fix as this same dialog's "Look up" button above.
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh aliases for the nested -OnComplete closure - see note at
        # the top of Show-CreateInIntuneDialog for why this matters here
        # too.
        $dlgRef2 = $dlg
        $reqGroupRef = $reqGroup
        $availGroupRef = $availGroup
        $uninstGroupRef = $uninstGroup
        $btnReadGroupsFromIntuneRef = $btnReadGroupsFromIntune
        $showGroupStatusRef2 = $showGroupStatus
        $groupsCheckedBoxRef2 = $groupsCheckedBox
        # Where this window's log actually is by the time a click happens -
        # repointed from $rtbAppEditorLog once the deploy side is hosted,
        # after which that box is no longer on the form. Graph's own lines
        # and this handler's failures used to go there, out of sight,
        # under a status that said "see log below".
        $editorLogBoxRef = $editorLogBox

        Start-AppMetadataFetch -AppId $txtId.Text.Trim() -LogBox $editorLogBox.Box -OnComplete {
            param($ok, $errMsg, $data)
            $btnReadGroupsFromIntuneRef.Enabled = $true
            $dlgRef2.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.Application]::DoEvents()
            [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
            if ($dlgRef2.IsDisposed) { return }
            if (-not $ok) {
                & $showGroupStatusRef2 "Could not read groups from Intune - see the log." ([System.Drawing.Color]::Firebrick)
                Write-DialogLogLine -LogBox $editorLogBoxRef.Box -Text "[FAILED] Could not read groups from Intune: $errMsg`r`n"
                return
            }
            # The app was read but its assignments were not. The three
            # lists are then empty because nothing came back, not because
            # Intune assigns nothing - applying them unticked every group
            # here and called it a match.
            if (-not $data.GroupFetchOk) {
                & $showGroupStatusRef2 "Could not read this app's groups from Intune - nothing was changed here." ([System.Drawing.Color]::Firebrick)
                Write-DialogLogLine -LogBox $editorLogBoxRef.Box -Text "[FAILED] Intune returned the app but not its assignments - the groups above were left as they were.`r`n"
                return
            }
            # From here the lists are Intune's. A compare still on its way
            # must not report over this, and the ticks set below are not
            # the user's edits.
            $groupsCheckedBoxRef2.Pulled = $true
            $groupsCheckedBoxRef2.Done = $true
            $groupsCheckedBoxRef2.Applying = $true
            # Sets each list to match Intune EXACTLY, not a merge - this
            # button's whole point is "show me what's actually there",
            # same as Sync metadata's own authoritative-pull philosophy
            # elsewhere in this app. A group Intune has that isn't in the
            # list yet is added (same as "+ New group..."), then every
            # box is checked/unchecked to match live reality, including
            # unchecking anything checked here that Intune doesn't
            # actually have.
            #
            # Returns what it changed, one line per group, so the status
            # can say "unticked GroupA" instead of only "now match" - which
            # was all it said even when it had just unticked half the list.
            $syncGroupList = {
                param($List, $Names, [string]$Label)
                $changes = New-Object System.Collections.Generic.List[string]
                foreach ($groupName in @($Names)) {
                    if ($List.Items -notcontains $groupName) { [void]$List.Items.Add($groupName) }
                }
                for ($gi = 0; $gi -lt $List.Items.Count; $gi++) {
                    $itemName = [string]$List.Items[$gi]
                    $want = @($Names) -contains $itemName
                    $had = $List.GetItemChecked($gi)
                    if ($want -and -not $had) { $changes.Add("ticked $itemName in $Label") }
                    elseif ($had -and -not $want) { $changes.Add("unticked $itemName in $Label") }
                    $List.SetItemChecked($gi, $want)
                }
                return ,$changes.ToArray()
            }
            $pulledChanges = @()
            try {
                $pulledChanges += & $syncGroupList $reqGroupRef.List $data.RequiredGroupNames "Required for"
                $pulledChanges += & $syncGroupList $availGroupRef.List $data.AvailableGroupNames "Available for"
                $pulledChanges += & $syncGroupList $uninstGroupRef.List $data.UninstallGroupNames "Uninstall for"
            }
            finally { $groupsCheckedBoxRef2.Applying = $false }
            foreach ($change in $pulledChanges) {
                Write-DialogLogLine -LogBox $editorLogBoxRef.Box -Text "[OK] Pulled from Intune: $change`r`n"
            }
            if ($pulledChanges.Count -gt 0) {
                & $showGroupStatusRef2 "Now match Intune - $($pulledChanges -join '; '). Save app to catalog to keep this." ([System.Drawing.Color]::SeaGreen)
                return
            }
            & $showGroupStatusRef2 "Already matched Intune - nothing to change." ([System.Drawing.Color]::SeaGreen)
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
        # Freshest of all: fields edited by hand on this window's own
        # Deploy tabs. They used to be ignored here entirely - a Publisher,
        # Owner, Notes... typed there without deploying was lost on save,
        # since this click only ever kept the metadata already on file.
        # Only when something was actually edited, so an app with no
        # metadata doesn't gain the generated defaults just by being saved.
        # Enter in the Winget ID field saves (AcceptButton) without that
        # field ever raising Leave - catch the Deploy tabs up first.
        if ($deploySyncBox.Run) { & $deploySyncBox.Run }
        $deployHostForSave = $deployHostBox.Host
        if ($deployHostForSave -and $deployHostForSave.HasUserEdits -and (& $deployHostForSave.HasUserEdits)) {
            $editedMetadata = & $deployHostForSave.GetMetadata
            if ($null -eq $editedMetadata) {
                # GetMetadata already said which field is wrong
                $deployAfterSaveBox.Value = $false
                return
            }
            $preservedMetadata = $editedMetadata
        }
        # Next: metadata just staged by "Deploy to Intune..." in
        # THIS still-open editing session (see $pendingDeployMetadataBox
        # above) is more current than whatever's already on disk or in
        # memory - a Create/Update or Save for later click that just ran
        # deliberately hasn't been written anywhere yet, precisely so this
        # click is the one that commits it.
        if (-not $preservedMetadata -and $pendingDeployMetadataBox.Value) {
            $preservedMetadata = $pendingDeployMetadataBox.Value
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
        }

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
            packagePath      = $txtAppPackagePath.Text.Trim()
            requiredFor      = @($reqGroup.List.CheckedItems)
            availableFor     = @($availGroup.List.CheckedItems)
            uninstallFor     = @($uninstGroup.List.CheckedItems)
            excludeFor       = @($excludeGroup.List.CheckedItems)
            metadata         = $preservedMetadata
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure()

    $btnOk.Add_Click({ & $performSave }.GetNewClosure())

    $btnSaveAndDeployWinget.Add_Click({
    $saveDeployTip = New-Object System.Windows.Forms.ToolTip
    $saveDeployTip.SetToolTip($btnSaveAndDeployWinget, "Two things at once: saves this app to the catalog, then opens Deploy with the Winget defaults filled in. Nothing reaches Intune until you press Deploy there.")
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

    # The one place leaving without saving is confirmed - Cancel (also
    # Esc), Previous/Next and the window's X / Alt+F4 all end up here. A
    # CancelButton closes the dialog on its own after its click handler,
    # so asking in the handler couldn't have kept the editor open anyway.
    $dlg.Add_FormClosing({
        param($s, $e)
        if ($dlg.DialogResult -eq [System.Windows.Forms.DialogResult]::OK) { return }
        if ($discardConfirmedBox.Value) { return }
        if ($askingBox.Value) { $e.Cancel = $true; return }
        $question = & $GetDiscardQuestion
        if (-not $question) { return }
        # $s as the owner, so this window is disabled while the question is
        # up - otherwise another Close click stacks a second question.
        $askingBox.Value = $true
        try { $r = [System.Windows.Forms.MessageBox]::Show($s, $question, "Discard changes?", "YesNo", "Warning", "Button2") }
        finally { $askingBox.Value = $false }
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
            $e.Cancel = $true
            # stay on this app
            $navigateToIndexBox.Value = $null
            $navigateAutoOpenDeployBox.Value = $false
        }
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
    $txtName.Add_TextChanged({
        & $checkDuplicateName
        # The title follows the name as it is typed, so renaming an app
        # never leaves the titlebar naming the app it used to be.
        if ($ExistingApp) {
            $typed = $txtName.Text.Trim()
            $dlg.Text = if ($typed) { "Edit app - $typed" } else { "Edit app" }
        }
    }.GetNewClosure())
    & $checkDuplicateName   # catches a pre-filled duplicate (e.g. Intune sync check's prefill) immediately on open, not just after the first keystroke

    # Only fires when THIS editor was itself opened by Previous/Next
    # clicked inside "Intune Deployment" for a different app (see
    # -AutoOpenDeploy's own param comment) - deferred to Add_Shown, not
    # called directly here, same reasoning as every other "kick off work
    # right as the window appears" case in this app: doing it before the
    # window is actually realized can leave WaitCursor-equivalent UI state
    # that doesn't reliably stick.
    #
    # It selects the first Deploy tab. It used to PerformClick the old
    # "Deploy to Intune" button, which has been hidden (and without a
    # handler) since deploy became tabs of this window - PerformClick on a
    # hidden button does nothing, so this landed on the Catalog tab.
    if ($AutoOpenDeploy) {
        $dlg.Add_Shown({
            $firstDeployTab = @($editorTabs.TabPages | Where-Object { $_.Text -ne 'Catalog' -and $_.Text -ne 'Assignments' }) | Select-Object -First 1
            if ($firstDeployTab) { $editorTabs.SelectedTab = $firstDeployTab }
        }.GetNewClosure())
    }

    # The fields "Save app to catalog" writes, as they are now - compared
    # with how they were on opening (see $GetDiscardQuestion)
    $editorStateBox.Get = {
        @(
            $txtName.Text.Trim(), $txtWinget.Text.Trim(), $txtId.Text.Trim(),
            # In here too, or pointing an app at its package and closing
            # would discard it without the editor thinking anything had
            # changed - which is the one way to lose an edit silently.
            $txtAppPackagePath.Text.Trim(),
            (@($reqGroup.List.CheckedItems) -join "`n"),
            (@($availGroup.List.CheckedItems) -join "`n"),
            (@($uninstGroup.List.CheckedItems) -join "`n"),
            (@($excludeGroup.List.CheckedItems) -join "`n")
        ) -join [char]1
    }.GetNewClosure()
    $editorStateBox.Initial = & $editorStateBox.Get

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
