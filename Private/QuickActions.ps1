function Invoke-QuickDeploy {
    param([int]$Index)
    $app = $Script:Apps[$Index]
    if (-not $app.appName.Trim()) {
        [System.Windows.Forms.MessageBox]::Show("This app has no name.", "No name", "OK", "Warning") | Out-Null
        return
    }
    $deployResult = Show-CreateInIntuneDialog -AppName $app.appName -WingetId $app.wingetId -ExistingAppId $app.appId
    if ($deployResult -and $deployResult.NewAppId) {
        $Script:Apps[$Index].appId = $deployResult.NewAppId
        if ($deployResult.NewAppName) { $Script:Apps[$Index].appName = $deployResult.NewAppName }
        $Script:UnsavedChangesBox.Value = $true
        # Direct-save, not just staged in memory - this action's entire
        # purpose IS recording the new App ID, and the stakes of NOT saving
        # it are real: if the save is forgotten and this app gets "deployed"
        # again later thinking it still needs it, that creates a genuine
        # duplicate in Intune, not just a display inconsistency.
        [void](Save-AppsToFile -Path $Script:LinkedFilePath)
        Refresh-Grid
    }
}

function Invoke-QuickAssignGroups {
    param([int]$Index)
    $app = $Script:Apps[$Index]
    if (-not $app.appId) {
        [System.Windows.Forms.MessageBox]::Show("This app doesn't have an App ID yet - use Deploy to Intune first.", "No App ID", "OK", "Warning") | Out-Null
        return
    }
    Show-TargetedAssignDialog -AppId $app.appId -AppName $app.appName `
        -RequiredGroups @($app.requiredFor) -AvailableGroups @($app.availableFor) -UninstallGroups @($app.uninstallFor) | Out-Null
}

function Invoke-QuickDeleteFromIntune {
    param([int]$Index)
    $app = $Script:Apps[$Index]
    $deleted = Show-DeleteAppDialog -AppId $app.appId -AppName $app.appName
    # .Success only ever means "deleted from Intune" - a catalog-only
    # removal (no App ID to begin with) reports Success=$false with
    # RemovedFromCatalog=$true instead, so both are checked here, not
    # just Success alone; missing that would skip the Refresh-Grid below
    # and leave a stale row for an app that's already gone from $Script:Apps.
    if (-not $deleted.Success -and -not $deleted.RemovedFromCatalog) { return }
    # Show-DeleteAppDialog itself already removed the catalog entry and
    # saved when the user chose that - nothing left here to clear or save
    # for an entry that no longer exists. Only the "keep the entry, just
    # clear its App ID" path still needs handling here.
    if (-not $deleted.RemovedFromCatalog) {
        $Script:Apps[$Index].appId = ""
        $Script:UnsavedChangesBox.Value = $true
        # Direct-save, not just staged in memory - matters more here than
        # most other actions: without this, a stale App ID would linger in
        # the catalog after a successful Intune deletion, making the
        # catalog wrongly think the app still exists there until someone
        # remembered to save separately.
        [void](Save-AppsToFile -Path $Script:LinkedFilePath)
    }
    Refresh-Grid
}
