<#
    Runs inside the PowerShell under test for DeployDefaults.GuiTests.ps1.

    Builds the deploy view in hosted mode exactly as "Add app..." does -
    with an EMPTY Winget ID, because the editor's Winget field has nothing
    in it yet when those tabs are built - then calls RetargetWingetId the
    way the editor's own field does once an ID has been typed, and records
    what the generated fields held before and after.

    Writes one "key=value" per line to -StatusFile; the test file turns
    those into assertions. Offline: no path here reaches Graph.
#>
param([string]$RepoRoot, [string]$StatusFile)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$lines = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$Key, $Value) $lines.Add("$Key=$Value") }

# Every text box under a control, however deeply nested - the deploy view
# puts its fields inside a scrolling panel inside a tab page.
function Get-AllBoxes($root) {
    $found = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $c = $stack.Pop()
        foreach ($child in $c.Controls) {
            if ($child -is [System.Windows.Forms.TextBox]) { $found.Add($child) }
            $stack.Push($child)
        }
    }
    return $found
}

# Armed before the app is loaded, same as DialogLayoutHarness: the app
# runs its own message loop, so the work happens on a tick.
$Global:Probe = New-Object System.Windows.Forms.Timer
$Global:Probe.Interval = 1500
$Global:Probe.Add_Tick({
    $Global:Probe.Stop()
    try {
        $hostForm = New-Object System.Windows.Forms.Form
        $hostForm.ClientSize = New-Object System.Drawing.Size(900, 1010)
        $hostTabs = New-Object System.Windows.Forms.TabControl
        $hostTabs.Location = New-Object System.Drawing.Point(10, 8)
        $hostTabs.Size = New-Object System.Drawing.Size(880, 651)
        $hostForm.Controls.Add($hostTabs)

        $deployHost = Show-CreateInIntuneDialog -AppName 'Probe App' -WingetId '' `
            -ExistingAppId '' -FromAppEditor -CurrentIndex -1 `
            -HostTabControl $hostTabs -HostForm $hostForm -HostBottomY 667

        Add-Line 'handlePresent' ([bool]$deployHost.RetargetWingetId)

        $before = @(Get-AllBoxes $hostTabs | ForEach-Object { [string]$_.Text })
        Add-Line 'beforeGenerated' (@($before | Where-Object { $_ -like '*Winget-Install.ps1*' }).Count)

        & $deployHost.RetargetWingetId '7zip.7zip'
        $after = @(Get-AllBoxes $hostTabs | ForEach-Object { [string]$_.Text })
        Add-Line 'afterGenerated' (@($after | Where-Object { $_ -like '*Winget-Install.ps1*' }).Count)
        Add-Line 'afterNamingId' (@($after | Where-Object { $_ -like '*7zip.7zip*' }).Count)

        # The other half: a value typed by hand is never replaced by a
        # later retarget, however many times the ID changes.
        $typed = @(Get-AllBoxes $hostTabs | Where-Object { $_.Multiline -and $_.Text -like '*Winget-Install.ps1*' } | Select-Object -First 1)
        if ($typed.Count -gt 0) {
            $typed[0].Text = 'MY OWN COMMAND'
            & $deployHost.RetargetWingetId 'Mozilla.Firefox'
            Add-Line 'typedSurvived' ($typed[0].Text -eq 'MY OWN COMMAND')
            $others = @(Get-AllBoxes $hostTabs | ForEach-Object { [string]$_.Text })
            Add-Line 'otherFieldsFollowed' (@($others | Where-Object { $_ -like '*Mozilla.Firefox*' }).Count)
        }
        else { Add-Line 'typedSurvived' 'no-field-found' }
        Add-Line 'ran' 'true'
    }
    catch { Add-Line 'error' $_.Exception.Message }
    [IO.File]::WriteAllLines($StatusFile, $lines)
    $Global:App.UnsavedChangesBox.Value = $false
    $Global:App.Form.Close()
})
$Global:Probe.Start()

. (Join-Path $RepoRoot 'IntuneDeployment.ps1')
