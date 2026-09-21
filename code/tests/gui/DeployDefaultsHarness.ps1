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

# The same walk, unfiltered - the deploy view's checkboxes sit at a
# different depth from its text boxes.
function Get-AllControls($root) {
    $found = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $c = $stack.Pop()
        foreach ($child in $c.Controls) {
            $found.Add($child)
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

        # Whether a deploy also pushes the app's groups is decided ONLY by
        # these two settings - the Deploy view deliberately has no
        # checkbox of its own, so the absence is worth asserting as much
        # as the defaults are. A box creeping back in here would mean two
        # places disagreeing about the same question.
        $pushBoxes = @(Get-AllControls $hostForm | Where-Object {
            $_ -is [System.Windows.Forms.CheckBox] -and [string]$_.Text -like '*push*groups*'
        })
        Add-Line 'pushGroupsBoxCount' $pushBoxes.Count
        Add-Line 'pushOnCreateIsBool' ($Global:App.PushGroupsOnCreate -is [bool])
        Add-Line 'pushOnUpdateIsBool' ($Global:App.PushGroupsOnUpdate -is [bool])
        Add-Line 'pushOnCreateDefault' ([bool]$Global:App.PushGroupsOnCreate)
        Add-Line 'pushOnUpdateDefault' ([bool]$Global:App.PushGroupsOnUpdate)

        # With no control on this window, the Deploy button's own label is
        # the only thing on screen that says whether the groups go too -
        # so it has to follow the setting. Built twice, once each way,
        # because a label that happens to match the default proves nothing.
        Add-Line 'deployLabelWhenPushOn' ([string]$deployHost.Deploy.Text)

        $savedPushOnCreate = $Global:App.PushGroupsOnCreate
        $Global:App.PushGroupsOnCreate = $false
        $hostForm2 = New-Object System.Windows.Forms.Form
        $hostForm2.ClientSize = New-Object System.Drawing.Size(900, 1010)
        $hostTabs2 = New-Object System.Windows.Forms.TabControl
        $hostTabs2.Location = New-Object System.Drawing.Point(10, 8)
        $hostTabs2.Size = New-Object System.Drawing.Size(880, 651)
        $hostForm2.Controls.Add($hostTabs2)
        $deployHost2 = Show-CreateInIntuneDialog -AppName 'Probe App 2' -WingetId '' `
            -ExistingAppId '' -FromAppEditor -CurrentIndex -1 `
            -HostTabControl $hostTabs2 -HostForm $hostForm2 -HostBottomY 667
        Add-Line 'deployLabelWhenPushOff' ([string]$deployHost2.Deploy.Text)
        # Whatever it says, it has to fit - the button is sized once for
        # the widest label it can show, and a truncated verb on the one
        # button that changes Intune is not acceptable.
        $labelWidth = [System.Windows.Forms.TextRenderer]::MeasureText([string]$deployHost.Deploy.Text, $deployHost.Deploy.Font).Width
        Add-Line 'deployLabelFits' ($labelWidth -le $deployHost.Deploy.Width)
        $hostForm2.Dispose()
        $Global:App.PushGroupsOnCreate = $savedPushOnCreate

        # The log funnel, handed nothing to write to. An alias taken one
        # closure level too high arrives $null, and that used to throw
        # "The property 'SelectionStart' cannot be found on this object"
        # at the user, taking the message with it. Asserted here rather
        # than in the pure-logic suite because these take WinForms
        # controls, and that suite has no WinForms and runs on Linux.
        $guardThrew = $false
        try { Write-DialogLogLine -LogBox $null -Text "[OK] guard check`r`n" } catch { $guardThrew = $true }
        Add-Line 'nullLogBoxSurvived' (-not $guardThrew)
        $guardThrew = $false
        try { Write-DialogError -StatusLabel $null -LogBox $null -ErrorMessage 'guard check' } catch { $guardThrew = $true }
        Add-Line 'nullStatusSurvived' (-not $guardThrew)

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
    }
    catch { Add-Line 'error' $_.Exception.Message }

    # Phase two, through the real editor. Phase one calls RetargetWingetId
    # itself, which is exactly why it could not catch the editor wiring
    # the ID up to only one of the two ways that field changes: typing
    # raises Leave, and "Search winget..." assigning .Text does not.
    #
    # A WinForms Timer keeps ticking inside a modal ShowDialog's own
    # message loop, so $Editor below runs while the editor is open and
    # drives it from the inside.
    $Global:EditorPhase = New-Object System.Windows.Forms.Timer
    $Global:EditorPhase.Interval = 1200
    $Global:EditorPhase.Add_Tick({
        $Global:EditorPhase.Stop()
        try {
            $editor = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like 'Add app*' -or $_.Text -like 'Edit app*' })
            if ($editor.Count -eq 0) { Add-Line 'editorFound' 'false' }
            else {
                $form = $editor[0]
                Add-Line 'editorFound' 'true'
                $box = @($form.Controls.Find('txtWingetId', $true))
                $tabs = @($form.Controls.Find('editorTabs', $true))
                if ($box.Count -eq 0 -or $tabs.Count -eq 0) { Add-Line 'editorControls' 'missing' }
                else {
                    # Exactly what Show-WingetSearchDialog's caller does:
                    # assign the ID. No focus, no keystroke, no Leave.
                    # The app's name fills the display name on Metadata -
                    # that tab is built before "Add app..." has a name.
                    $nameBox = @($form.Controls.Find('txtAppName', $true))
                    if ($nameBox.Count -gt 0) {
                        $nameBox[0].Text = 'Probe Named App'
                        $tabs[0].SelectedIndex = 1
                        [System.Windows.Forms.Application]::DoEvents()
                        $named = @(Get-AllBoxes $tabs[0] | Where-Object { [string]$_.Text -eq 'Probe Named App' }).Count
                        Add-Line 'displayNameFollowed' $named
                        $tabs[0].SelectedIndex = 0
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                    else { Add-Line 'displayNameFollowed' 'no-name-box' }

                    $box[0].Text = '7zip.7zip'
                    Add-Line 'editorAfterAssign' (@(Get-AllBoxes $tabs[0] | Where-Object { $_.Text -like '*Winget-Install.ps1*' }).Count)
                    # Then switch tabs, which is when the user looks.
                    $tabs[0].SelectedIndex = [Math]::Min(2, $tabs[0].TabPages.Count - 1)
                    [System.Windows.Forms.Application]::DoEvents()
                    $after = @(Get-AllBoxes $tabs[0] | ForEach-Object { [string]$_.Text })
                    Add-Line 'editorAfterTabSwitch' (@($after | Where-Object { $_ -like '*Winget-Install.ps1*' }).Count)
                    Add-Line 'editorPackagePath' (@($after | Where-Object { $_ -like '*init.intunewin*' }).Count)
                    # Put the field back before closing. The editor asks
                    # "discard this unsaved app?" when its catalog fields
                    # differ from how they opened, and that question is a
                    # modal MessageBox - which, from inside this tick,
                    # hangs the harness rather than failing it.
                    $box[0].Text = ''
                    # The name too, or the editor counts itself changed and
                    # asks "discard this unsaved app?" on close - a modal
                    # that hangs this harness rather than failing it.
                    $nameBoxAgain = @($form.Controls.Find('txtAppName', $true))
                    if ($nameBoxAgain.Count -gt 0) { $nameBoxAgain[0].Text = '' }
                    $tabs[0].SelectedIndex = 0
                    [System.Windows.Forms.Application]::DoEvents()
                }
                $form.Close()
            }
        }
        catch { Add-Line 'editorError' $_.Exception.Message }
        Add-Line 'ran' 'true'
        [IO.File]::WriteAllLines($StatusFile, $lines)
        $Global:App.UnsavedChangesBox.Value = $false
        $Global:App.Form.Close()
    })
    $Global:EditorPhase.Start()
    # Modal - the tick above runs inside its message loop and closes it.
    Show-AppEditor -ExistingApp $null
})
$Global:Probe.Start()

. (Join-Path $RepoRoot 'IntuneDeployment.ps1')
