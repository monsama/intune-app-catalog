function Global:Invoke-QuickDeploy {
    param([int]$Index)
    $app = $Global:App.Apps[$Index]
    if (-not $app.appName.Trim()) {
        [System.Windows.Forms.MessageBox]::Show("This app has no name.", "No name", "OK", "Warning") | Out-Null
        return
    }
    # The catalog entry itself is the source here - nothing is being edited
    # alongside, so what it holds now is what a deploy should push.
    $deployResult = Show-CreateInIntuneDialog -AppName $app.appName -WingetId $app.wingetId -ExistingAppId $app.appId `
        -GetAssignGroups {
            @{
                Required  = @($app.requiredFor)
                Available = @($app.availableFor)
                Uninstall = @($app.uninstallFor)
                Exclude   = @($app.excludeFor)
            }
        }.GetNewClosure()
    if ($deployResult -and $deployResult.NewAppId) {
        $Global:App.Apps[$Index].appId = $deployResult.NewAppId
        if ($deployResult.NewAppName) { $Global:App.Apps[$Index].appName = $deployResult.NewAppName }
        $Global:App.UnsavedChangesBox.Value = $true
        # Direct-save, not just staged in memory - this action's entire
        # purpose IS recording the new App ID, and the stakes of NOT saving
        # it are real: if the save is forgotten and this app gets "deployed"
        # again later thinking it still needs it, that creates a genuine
        # duplicate in Intune, not just a display inconsistency.
        [void](Save-AppsToFile -Path $Global:App.LinkedFilePath)
        Update-Grid
    }
}

function Global:Invoke-EditApp {
    # Opens the app editor for one catalog entry and keeps what it returns
    # - the grid's Edit button, and anything else that opens an app for
    # editing, so they all save the same way.
    #
    # -OpenDeploy: straight to the Deploy side, as the editor's own
    # Previous/Next from there does. -PreferLocal: that side's compare with
    # Intune starts on the catalog's values (see Show-AppEditor).
    param([int]$Index, [switch]$OpenDeploy, [switch]$PreferLocal)
    $editorResult = Show-AppEditor -ExistingApp $Global:App.Apps[$Index] -CurrentIndex $Index -AutoOpenDeploy:$OpenDeploy -PreferLocal:$PreferLocal
    if (-not $editorResult) { return }
    # Not necessarily $Index anymore - Previous/Next inside the editor can
    # navigate to (and save) a DIFFERENT app before finally returning
    # here, and Show-AppEditor's own result always carries the index of
    # whichever app it actually last saved (see its own comment next to
    # this Index field). Falling back to $Index covers older in-memory
    # result shapes/callers that never set it.
    $targetIndex = if ($null -ne $editorResult.Index -and $editorResult.Index -ge 0) { $editorResult.Index } else { $Index }
    $Global:App.Apps[$targetIndex] = $editorResult.App
    $Global:App.UnsavedChangesBox.Value = $true
    [void](Save-AppsToFile -Path $Global:App.LinkedFilePath)
    Update-Grid
    if ($editorResult.DeployAfterSave) { Show-BatchDeployDialog -ScopedIndices @($targetIndex) }
}

function Global:Invoke-QuickPushMetadata {
    # The catalog is right about this app's metadata and Intune has
    # drifted - the audit's "Push metadata". Not a window of its own: the
    # app editor, opened on its Deploy side, with the compare there
    # starting every differing field on the catalog's value. It still
    # fetches what is live, shows which fields differ and waits for
    # Push Metadata, so nothing is sent without being seen first.
    param([int]$Index)
    $app = $Global:App.Apps[$Index]
    if (-not $app.appId) {
        [System.Windows.Forms.MessageBox]::Show("This app doesn't have an App ID yet - there is nothing in Intune to update. Use Deploy to Intune first.", "No App ID", "OK", "Warning") | Out-Null
        return
    }
    Invoke-EditApp -Index $Index -OpenDeploy -PreferLocal
}

function Global:Invoke-QuickAssignGroups {
    param([int]$Index)
    $app = $Global:App.Apps[$Index]
    if (-not $app.appId) {
        [System.Windows.Forms.MessageBox]::Show("This app doesn't have an App ID yet - use Deploy to Intune first.", "No App ID", "OK", "Warning") | Out-Null
        return
    }
    Show-TargetedAssignDialog -AppId $app.appId -AppName $app.appName `
        -RequiredGroups @($app.requiredFor) -AvailableGroups @($app.availableFor) -UninstallGroups @($app.uninstallFor) `
        -ExcludeGroups @($app.excludeFor) | Out-Null
}

function Global:Invoke-QuickDeleteFromIntune {
    param([int]$Index)
    $app = $Global:App.Apps[$Index]
    $deleted = Show-DeleteAppDialog -AppId $app.appId -AppName $app.appName
    # .Success only ever means "deleted from Intune" - a catalog-only
    # removal (no App ID to begin with) reports Success=$false with
    # RemovedFromCatalog=$true instead, so both are checked here, not
    # just Success alone; missing that would skip the Update-Grid below
    # and leave a stale row for an app that's already gone from $Global:App.Apps.
    if (-not $deleted.Success -and -not $deleted.RemovedFromCatalog) { return }
    # Show-DeleteAppDialog itself already removed the catalog entry and
    # saved when the user chose that - nothing left here to clear or save
    # for an entry that no longer exists. Only the "keep the entry, just
    # clear its App ID" path still needs handling here.
    if (-not $deleted.RemovedFromCatalog) {
        $Global:App.Apps[$Index].appId = ""
        $Global:App.UnsavedChangesBox.Value = $true
        # Direct-save, not just staged in memory - matters more here than
        # most other actions: without this, a stale App ID would linger in
        # the catalog after a successful Intune deletion, making the
        # catalog wrongly think the app still exists there until someone
        # remembered to save separately.
        [void](Save-AppsToFile -Path $Global:App.LinkedFilePath)
    }
    Update-Grid
}
