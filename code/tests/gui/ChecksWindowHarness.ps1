<#
    Runs inside the PowerShell under test for ChecksWindow.GuiTests.ps1.

    Opens the real Checks window over a fixture catalog, with Intune's app
    list and the last audit's results already in hand - so it has rows
    from the moment it opens, without reading anything - and records what
    the list and the fix buttons do: which rows appear, what the Show
    filter offers, and which fixes each kind of selection offers.

    Writes one "key=value" per line to -StatusFile; the test file turns
    those into assertions. Offline: nothing here presses Run, so no path
    reaches Graph, Entra ID or winget.
#>
param([string]$RepoRoot, [string]$StatusFile)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$lines = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$Key, $Value) $lines.Add("$Key=$Value") }

function Get-AllControls($root) {
    $found = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $c = $stack.Pop()
        foreach ($child in $c.Controls) { $found.Add($child); $stack.Push($child) }
    }
    return $found
}

# Armed before the app is loaded: the app runs its own message loop, so
# the work happens on a tick.
$Global:Probe = New-Object System.Windows.Forms.Timer
$Global:Probe.Interval = 1500
$Global:Probe.Add_Tick({
    $Global:Probe.Stop()
    try {
        # The fixture: one of each kind of Intune link problem, plus an
        # app the last audit found a difference on.
        $Global:App.Apps.Clear()
        foreach ($fixture in @(
            @{ appId = 'id-7zip'; appName = '7-Zip'; wingetId = '7zip.7zip' }
            @{ appId = 'id-old';  appName = 'Old Name'; wingetId = 'Vendor.Old' }
            @{ appId = 'id-gone'; appName = 'Gone App'; wingetId = 'Vendor.Gone' }
            @{ appId = '';        appName = 'Firefox'; wingetId = 'Mozilla.Firefox' }
        )) {
            [void]$Global:App.Apps.Add([pscustomobject]@{
                appId = $fixture.appId; appName = $fixture.appName; wingetId = $fixture.wingetId
                intuneAppType = ''; intuneAppVersion = ''; packagePath = ''
                requiredFor = @(); availableFor = @(); uninstallFor = @(); excludeFor = @()
                metadata = [pscustomobject]@{ description = $fixture.appName; dependencies = @() }
            })
        }
        $Global:App.IntuneAppsCache.Clear()
        foreach ($intuneApp in @(
            @{ id = 'id-7zip'; displayName = '7-Zip' }
            @{ id = 'id-old';  displayName = 'New Name' }
            @{ id = 'id-ff';   displayName = 'Firefox' }
            @{ id = 'id-only'; displayName = 'Intune Only App' }
        )) { [void]$Global:App.IntuneAppsCache.Add([pscustomobject]$intuneApp) }
        $Global:App.LastAuditResults = @{
            '7-Zip' = [pscustomobject]@{
                Timestamp = (Get-Date).AddHours(-3); Metadata = '1 field(s) differ: Publisher'; Groups = 'OK'; Dependencies = 'OK'; Unknown = 'OK'
                Checked = [pscustomobject]@{ Metadata = (Get-Date).AddHours(-3).ToString('o'); Groups = $null; Dependencies = $null; Unknown = $null }
            }
        }

        # Inside the modal window's own message loop.
        $Global:Inspect = New-Object System.Windows.Forms.Timer
        $Global:Inspect.Interval = 1200
        $Global:Inspect.Add_Tick({
            $Global:Inspect.Stop()
            try {
                $form = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like 'Checks*' }) | Select-Object -First 1
                Add-Line 'windowFound' ([bool]$form)
                if ($form) {
                    $controls = @(Get-AllControls $form)
                    $grid = @($controls | Where-Object { $_ -is [System.Windows.Forms.DataGridView] }) | Select-Object -First 1
                    $combo = @($controls | Where-Object { $_ -is [System.Windows.Forms.ComboBox] }) | Select-Object -First 1
                    $buttons = @($controls | Where-Object { $_ -is [System.Windows.Forms.Button] })
                    $visibleFixes = {
                        [System.Windows.Forms.Application]::DoEvents()
                        return (@($buttons | Where-Object { $_.Visible -and $_.Parent -is [System.Windows.Forms.FlowLayoutPanel] } | ForEach-Object { $_.Text }) -join '|')
                    }
                    $selectApp = {
                        param([string[]]$Apps)
                        $grid.ClearSelection()
                        foreach ($row in $grid.Rows) { if ($Apps -contains [string]$row.Cells['App'].Value) { $row.Selected = $true } }
                    }

                    Add-Line 'rows' $grid.Rows.Count
                    Add-Line 'apps' ((@($grid.Rows | ForEach-Object { "$($_.Cells['Area'].Value):$($_.Cells['App'].Value)" }) | Sort-Object) -join ',')
                    Add-Line 'showItems' ((@($combo.Items | ForEach-Object { [string]$_ })) -join '|')
                    Add-Line 'runEnabled' (@($buttons | Where-Object { $_.Text -eq 'Run checks' })[0].Enabled)
                    Add-Line 'stopEnabled' (@($buttons | Where-Object { $_.Text -eq 'Stop' })[0].Enabled)
                    Add-Line 'fixesNothingSelected' (& $visibleFixes)

                    & $selectApp @('Old Name');         Add-Line 'fixesRenamed' (& $visibleFixes)
                    & $selectApp @('Intune Only App');  Add-Line 'fixesNotInCatalog' (& $visibleFixes)
                    & $selectApp @('Gone App');         Add-Line 'fixesStaleId' (& $visibleFixes)
                    & $selectApp @('Firefox');          Add-Line 'fixesNoAppId' (& $visibleFixes)
                    & $selectApp @('7-Zip');            Add-Line 'fixesMetadata' (& $visibleFixes)
                    & $selectApp @('Old Name', 'Gone App'); Add-Line 'fixesTwoKinds' (& $visibleFixes)

                    $cachedRow = @($grid.Rows | Where-Object { [string]$_.Cells['App'].Value -eq '7-Zip' }) | Select-Object -First 1
                    Add-Line 'cachedChecked' ([string]$cachedRow.Cells['Checked'].Value)

                    $linkItem = @($combo.Items | Where-Object { [string]$_ -like 'Intune link*' }) | Select-Object -First 1
                    if ($linkItem) {
                        $combo.SelectedItem = $linkItem
                        [System.Windows.Forms.Application]::DoEvents()
                        Add-Line 'rowsLinkOnly' $grid.Rows.Count
                        Add-Line 'linkOnlyAreas' ((@($grid.Rows | ForEach-Object { [string]$_.Cells['Area'].Value }) | Select-Object -Unique) -join ',')
                    }
                    $form.Close()
                }
            }
            catch { Add-Line 'inspectError' $_.Exception.Message }
        })
        $Global:Inspect.Start()
        # Modal - the tick above runs inside its message loop and closes it.
        $changed = Show-ChecksDialog
        Add-Line 'returnedChanged' $changed
    }
    catch { Add-Line 'error' $_.Exception.Message }
    Add-Line 'ran' 'true'
    [IO.File]::WriteAllLines($StatusFile, $lines)
    $Global:App.UnsavedChangesBox.Value = $false
    $Global:App.Form.Close()
})
$Global:Probe.Start()

. (Join-Path $RepoRoot 'IntuneDeployment.ps1')
