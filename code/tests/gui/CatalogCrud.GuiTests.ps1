<#
.SYNOPSIS
    GUI test: add, edit, rename, and remove catalog apps through the real
    app's dialogs, checking the per-app JSON files on disk after each step.

.DESCRIPTION
    Local-catalog only. Every app this test creates has no App ID, so no
    path it takes can reach Intune - "Delete app from catalog..." inside
    the editor is only ever confirmed when its prompt says it just removes
    the local entry.

    Runs against a throwaway sandbox copy of the app (see
    GuiTestDriver.ps1), never the repo's own data folder.

    Needs an interactive Windows desktop session. Windows appear briefly
    while it runs - don't type or click into them.

.PARAMETER AppHost
    Which PowerShell(s) to run the app under. Default: both.

.PARAMETER ShotDir
    Optional folder for a screenshot of every step.

.EXAMPLE
    pwsh -NoProfile -File code/tests/gui/CatalogCrud.GuiTests.ps1
#>
param(
    [string[]]$AppHost = @('pwsh', 'powershell'),
    [string]$ShotDir
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GuiTestDriver.ps1')

function Open-EditorForRow {
    param($Ctx, [string]$AppName)
    Select-OnlyGridRow $Ctx $AppName
    $W32::Click($Ctx.Buttons['Edit...'])
    $ed = Wait-AppDialog $Ctx 'Edit app'
    Assert-True ([bool]$ed) "Edit... opens the editor for '$AppName'" "open windows: $(@(Get-AppDialogs $Ctx | ForEach-Object { $W32::Text($_) }) -join ', ')"
    return $ed
}

function Save-Editor {
    param($Ctx, [IntPtr]$Editor, [string]$Step)
    Save-AppShot $Ctx $Editor $Step
    $W32::Click((Get-ChildWindow $Editor 'Save app to catalog'))
    $closed = Wait-NoAppDialogs $Ctx
    if (-not $closed) {
        $left = @(Get-AppDialogs $Ctx | ForEach-Object { "[$($W32::Text($_))] $(Get-StaticText $_)" })
        foreach ($d in Get-AppDialogs $Ctx) { [void](Close-AppDialog $d) }
    }
    Assert-True $closed "$Step - editor saves and closes without further prompts" ($left -join '; ')
}

function Get-FixtureState {
    param($Ctx)
    Get-ChildItem $Ctx.AppData -Filter *.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
        Where-Object { $_.appName -notlike 'ZZ GUI Test*' } | Sort-Object appName | ForEach-Object {
            "$($_.appName)|$($_.wingetId)|$($_.appId)|$(@($_.requiredFor) -join '+')|$(@($_.availableFor) -join '+')|$(@($_.uninstallFor) -join '+')|$($_.intuneAppType)|$($_.intuneAppVersion)"
        }
}

foreach ($exe in Resolve-AppHosts $AppHost) {
    $script:currentHost = [IO.Path]::GetFileNameWithoutExtension($exe)
    Write-Host "`n=== Catalog create/edit/remove - app running under $exe ===" -ForegroundColor Cyan
    $root = New-AppSandbox
    $ctx = $null
    $appA = 'ZZ GUI Test App'
    $appB = 'ZZ GUI Test App Two'
    try {
        $ctx = Start-AppUnderTest -AppHost $exe -Root $root
        if ($ShotDir) {
            $ctx.ShotDir = Join-Path $ShotDir $script:currentHost
            [void][IO.Directory]::CreateDirectory($ctx.ShotDir)
        }
        $fixturesBefore = @(Get-FixtureState $ctx)

        # --- create ---
        $W32::Click($ctx.Buttons['+ Add app...'])
        $ed = Wait-AppDialog $ctx 'Add app'
        Assert-True ([bool]$ed) "'+ Add app...' opens the editor"
        $boxes = Get-EditBoxes $ed
        $W32::SetText($boxes[0], $appA)
        $W32::SetText($boxes[1], 'Test.GuiApp')
        Save-Editor $ctx $ed 'create'
        [void](Wait-Condition { @(Get-CatalogEntries $ctx $appA).Count -eq 1 })
        $saved = @(Get-CatalogEntries $ctx $appA)
        Assert-True ($saved.Count -eq 1) "create writes exactly one catalog file" "found $($saved.Count)"
        Assert-True ($saved[0].wingetId -eq 'Test.GuiApp') "create saves the Winget ID" "wingetId=$($saved[0].wingetId)"
        Assert-True ([string]::IsNullOrEmpty($saved[0].appId)) "a new app has no App ID"

        # --- validation ---
        $W32::Click($ctx.Buttons['+ Add app...'])
        $ed = Wait-AppDialog $ctx 'Add app'
        $W32::Click((Get-ChildWindow $ed 'Save app to catalog'))
        $mb = Wait-AppDialog $ctx 'Missing name' 5
        Assert-True ([bool]$mb) "saving without a name is refused with 'Missing name'"
        if ($mb) { $W32::Click((Get-ChildWindow $mb 'OK')); Start-Sleep -Milliseconds 500 }
        $W32::Click((Get-ChildWindow $ed 'Cancel'))
        Assert-True (Wait-NoAppDialogs $ctx 5) "Cancel closes an untouched editor without asking"
        foreach ($d in Get-AppDialogs $ctx) { [void](Close-AppDialog $d) }

        # --- reload keeps it ---
        $W32::Click($ctx.Buttons['Reload'])
        Start-Sleep -Milliseconds 1500
        foreach ($d in Get-AppDialogs $ctx) { [void](Close-AppDialog $d) }

        # --- edit ---
        $ed = Open-EditorForRow $ctx $appA
        if ($ed) {
            $boxes = Get-EditBoxes $ed
            Assert-True (($W32::Text($boxes[0]) -eq $appA) -and ($W32::Text($boxes[1]) -eq 'Test.GuiApp')) "editor is prefilled from the catalog (also after Reload)" "name='$($W32::Text($boxes[0]))' winget='$($W32::Text($boxes[1]))'"
            $W32::SetText($boxes[1], 'Test.GuiApp.Edited')
            Save-Editor $ctx $ed 'edit'
            [void](Wait-Condition { @(Get-CatalogEntries $ctx $appA | Where-Object { $_.wingetId -eq 'Test.GuiApp.Edited' }).Count -eq 1 })
            $saved = @(Get-CatalogEntries $ctx $appA)
            Assert-True ($saved.Count -eq 1 -and $saved[0].wingetId -eq 'Test.GuiApp.Edited') "edit is saved in place, no duplicate file" "files=$($saved.Count) wingetId=$($saved[0].wingetId)"
        }

        # --- leaving with unsaved edits asks first: No stays, Yes discards ---
        $ed = Open-EditorForRow $ctx $appA
        if ($ed) {
            $W32::SetText((Get-EditBoxes $ed)[1], 'Test.GuiApp.NotSaved')
            $W32::Click((Get-ChildWindow $ed 'Cancel'))
            $q = Wait-AppDialog $ctx 'Discard changes?' 5
            Assert-True ($q -and (Get-StaticText $q) -like "*unsaved changes to '$appA'*") "Cancel with an unsaved edit asks before discarding it" "$(if ($q) { Get-StaticText $q })"
            if ($q) {
                $W32::Click((Get-ChildWindow $q 'No'))
                Start-Sleep -Milliseconds 800
                Assert-True ($W32::IsWindowVisible($ed)) "answering No keeps the editor open"
                $W32::Close($ed)
                $q = Wait-AppDialog $ctx 'Discard changes?' 5
                Assert-True ([bool]$q) "the window's X asks the same question"
                if ($q) { $W32::Click((Get-ChildWindow $q 'Yes')) }
                Assert-True (Wait-NoAppDialogs $ctx 5) "answering Yes closes the editor"
            }
            foreach ($d in Get-AppDialogs $ctx) { [void](Close-AppDialog $d) }
            $saved = @(Get-CatalogEntries $ctx $appA)
            Assert-True ($saved.Count -eq 1 -and $saved[0].wingetId -eq 'Test.GuiApp.Edited') "a discarded edit isn't saved" "wingetId=$($saved[0].wingetId)"
        }

        # --- rename ---
        $ed = Open-EditorForRow $ctx $appA
        if ($ed) {
            $W32::SetText((Get-EditBoxes $ed)[0], "$appA Renamed")
            Save-Editor $ctx $ed 'rename'
            [void](Wait-Condition { (@(Get-CatalogEntries $ctx "$appA Renamed").Count -eq 1) -and (@(Get-CatalogEntries $ctx $appA).Count -eq 0) })
            $renamed = @(Get-CatalogEntries $ctx "$appA Renamed")
            Assert-True ($renamed.Count -eq 1 -and $renamed[0].wingetId -eq 'Test.GuiApp.Edited') "rename keeps the app's other fields"
            Assert-True (@(Get-CatalogEntries $ctx $appA).Count -eq 0) "rename leaves no file behind under the old name"
            $appA = "$appA Renamed"
        }

        # --- remove from the main window: No keeps it, Yes deletes it ---
        Select-OnlyGridRow $ctx $appA
        [void](Invoke-MoreActionsItem $ctx 'Catalog maintenance' 'Remove from catalog...')
        $cf = Wait-AppDialog $ctx 'Confirm delete'
        Assert-True ($cf -and (Get-StaticText $cf) -like "*'$appA'*") "Remove from catalog asks for confirmation, naming the app" "$(if ($cf) { Get-StaticText $cf })"
        if ($cf) { $W32::Click((Get-ChildWindow $cf 'No')); [void](Wait-NoAppDialogs $ctx 5) }
        Start-Sleep -Seconds 2   # nothing should happen - give a slow machine time to do the wrong thing
        Assert-True (@(Get-CatalogEntries $ctx $appA).Count -eq 1) "answering No keeps the app"

        Select-OnlyGridRow $ctx $appA
        [void](Invoke-MoreActionsItem $ctx 'Catalog maintenance' 'Remove from catalog...')
        $cf = Wait-AppDialog $ctx 'Confirm delete'
        if ($cf) {
            Save-AppShot $ctx $cf 'confirm_remove'
            $W32::Click((Get-ChildWindow $cf 'Yes'))
            [void](Wait-NoAppDialogs $ctx 5)
        }
        Assert-True (Wait-Condition { @(Get-CatalogEntries $ctx $appA).Count -eq 0 }) "answering Yes deletes the app's file"
        Clear-GridFilter $ctx

        # --- remove from inside the editor (no App ID -> catalog-only) ---
        $W32::Click($ctx.Buttons['+ Add app...'])
        $ed = Wait-AppDialog $ctx 'Add app'
        $W32::SetText((Get-EditBoxes $ed)[0], $appB)
        Save-Editor $ctx $ed 'create uncommon app'
        [void](Wait-Condition { @(Get-CatalogEntries $ctx $appB).Count -eq 1 })
        $saved = @(Get-CatalogEntries $ctx $appB)
        Assert-True ($saved.Count -eq 1 -and [string]::IsNullOrEmpty($saved[0].wingetId)) "an app without a Winget ID (uncommon) can be created"

        $ed = Open-EditorForRow $ctx $appB
        if ($ed) {
            $del = $W32::Children($ed) | Where-Object { $W32::Cls($_) -match 'BUTTON' -and $W32::Text($_) -eq 'Delete app from catalog...' } | Select-Object -First 1
            Assert-True ([bool]$del) "editor offers 'Delete app from catalog...' for an app without App ID"
            if ($del) {
                $W32::Click($del)
                $cf = Wait-AppDialog $ctx 'Confirm delete' 5
                $text = if ($cf) { Get-StaticText $cf } else { '' }
                $isLocalOnly = $text -like '*only removes the local entry*'
                Assert-True $isLocalOnly "its confirmation says it only removes the local entry" $text
                if ($isLocalOnly) { $W32::Click((Get-ChildWindow $cf 'Yes')) }
                [void](Wait-NoAppDialogs $ctx 5)
                foreach ($d in Get-AppDialogs $ctx) { [void](Close-AppDialog $d) }
                Assert-True (Wait-Condition { @(Get-CatalogEntries $ctx $appB).Count -eq 0 }) "deleting from the editor removes the app's file"
            }
        }
        Clear-GridFilter $ctx
        Save-AppShot $ctx $ctx.Main 'main_end'

        $fixturesAfter = @(Get-FixtureState $ctx)
        Assert-True (($fixturesBefore -join "`n") -eq ($fixturesAfter -join "`n")) "the other catalog apps are unchanged" "before:`n      $($fixturesBefore -join "`n      ")`n    after:`n      $($fixturesAfter -join "`n      ")"
        Assert-True ((Get-AppDialogs $ctx).Count -eq 0) "no stray dialogs left open"
    }
    catch {
        Assert-True $false "test run completed" "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
        if ($ctx) { foreach ($d in Get-AppDialogs $ctx) { [void](Close-AppDialog $d) } }
    }
    finally {
        if ($ctx) {
            Assert-True (Stop-AppUnderTest $ctx) "app closes cleanly"
            $err = Get-AppStdErr $ctx
            Assert-True ([string]::IsNullOrWhiteSpace($err)) "app wrote nothing to stderr" $err
        }
        Remove-AppSandbox $root
    }
}
$script:currentHost = ''
exit (Write-TestReport)
