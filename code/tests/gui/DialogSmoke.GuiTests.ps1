<#
.SYNOPSIS
    GUI smoke test: starts the real app, opens every toolbar button and
    every "More actions..." item, closes whatever each one opens, and
    checks the app neither crashes nor writes to stderr along the way.

.DESCRIPTION
    Runs against a throwaway sandbox copy of the app (see
    GuiTestDriver.ps1) with no Graph credentials, so every Graph-facing
    action stops at its own "not configured" / "module missing" guard.
    Skipped on purpose: "Package apps" (spawns packaging work) and every
    Delete/Remove action (CatalogCrud.GuiTests.ps1 covers the local ones).

    Also pins down a few specific layout/behavior fixes:
    - every main-grid column header fits its text (PowerShell 7 host only:
      .NET Framework's DataGridView isn't exposed to UI Automation)
    - the "Get started" toolbar row wraps instead of running off a narrow
      window
    - Diagnostics opens without a blocking "Not configured" box first
    - "Look up App IDs..." without a Graph connection shows one message,
      not two
    - "View dependencies..." on apps without dependency metadata doesn't
      throw
    - Prerequisites... reflects whether the Graph module is installed (its
      Install button is never clicked - that would change the machine)

    Needs an interactive Windows desktop session. Windows appear briefly
    while it runs - don't type or click into them.

.PARAMETER AppHost
    Which PowerShell(s) to run the app under. Default: both.

.PARAMETER ShotDir
    Optional folder for a screenshot of every window opened.

.EXAMPLE
    pwsh -NoProfile -File code/tests/gui/DialogSmoke.GuiTests.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File code\tests\gui\DialogSmoke.GuiTests.ps1 -AppHost powershell -ShotDir .\shots
#>
param(
    [string[]]$AppHost = @('pwsh', 'powershell'),
    [string]$ShotDir
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GuiTestDriver.ps1')

$skipPattern = 'Package|Delete|Remove'

function Test-GridHeaders {
    param($Ctx)
    try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms } catch { return }
    $AE = [System.Windows.Automation.AutomationElement]
    $TS = [System.Windows.Automation.TreeScope]
    $CT = [System.Windows.Automation.ControlType]
    $grid = $AE::FromHandle($Ctx.Main).FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::DataGrid)))
    if (-not $grid) {
        Write-Host "  skip grid header widths - grid not exposed to UI Automation under this host" -ForegroundColor DarkYellow
        return
    }
    $font = New-Object System.Drawing.Font('Segoe UI', 9)
    $mr = New-Object GuiTest.W32+RECT; [void]$W32::GetWindowRect($Ctx.Main, [ref]$mr)
    foreach ($size in @(@(($mr.R - $mr.L), ($mr.B - $mr.T)), @(1366, 768), @(1100, 700))) {
        [void]$W32::MoveWindow($Ctx.Main, $mr.L, $mr.T, $size[0], $size[1], $true)
        Start-Sleep -Milliseconds 1200
        $headers = @($grid.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Header))) |
            Where-Object { $_.Current.BoundingRectangle.Width -gt 0 -and $_.Current.Name })
        $tops = @($headers | ForEach-Object { [int]$_.Current.BoundingRectangle.Top } | Select-Object -Unique)
        $tooNarrow = @($headers | Where-Object {
            # header text + sort glyph + padding
            $_.Current.BoundingRectangle.Width -lt ([System.Windows.Forms.TextRenderer]::MeasureText($_.Current.Name, $font).Width + 18)
        } | ForEach-Object { "$($_.Current.Name) ($([int]$_.Current.BoundingRectangle.Width)px)" })
        # Below the columns' combined minimum width the grid scrolls
        # horizontally instead, so the rightmost headers are out of view there.
        if ($size[0] -ge 1366) {
            Assert-True ($headers.Count -ge 13) "grid shows all 13 column headers at $($size[0])x$($size[1])" "found $($headers.Count)"
        }
        Assert-True ($tooNarrow.Count -eq 0) "every visible grid column header fits its text at $($size[0])x$($size[1])" ($tooNarrow -join ', ')
        Assert-True ($tops.Count -eq 1) "grid column headers share one row at $($size[0])x$($size[1])"
    }
    [void]$W32::MoveWindow($Ctx.Main, $mr.L, $mr.T, $mr.R - $mr.L, $mr.B - $mr.T, $true)
    Start-Sleep -Milliseconds 800
}

function Test-ToolbarWraps {
    param($Ctx)
    $mr = New-Object GuiTest.W32+RECT; [void]$W32::GetWindowRect($Ctx.Main, [ref]$mr)
    # the form's own MinimumSize is 860x560
    [void]$W32::MoveWindow($Ctx.Main, $mr.L, $mr.T, 900, 600, $true)
    Start-Sleep -Milliseconds 1200
    Save-AppShot $Ctx $Ctx.Main 'main_900x600'
    $nr = New-Object GuiTest.W32+RECT; [void]$W32::GetWindowRect($Ctx.Main, [ref]$nr)
    $clipped = @()
    foreach ($name in '+ Add app...', 'Edit...', 'Package apps', 'Batch deploy...', 'Intune Audit...', 'Reload', 'Settings...', 'Getting started...', 'More actions...') {
        $h = $Ctx.Buttons[$name]
        $br = New-Object GuiTest.W32+RECT; [void]$W32::GetWindowRect($h, [ref]$br)
        if ($br.R -gt $nr.R - 8) { $clipped += "$name (right edge $($br.R) > window $($nr.R))" }
    }
    Assert-True ($clipped.Count -eq 0) "toolbar buttons stay inside a 900px-wide window" ($clipped -join '; ')
    [void]$W32::MoveWindow($Ctx.Main, $mr.L, $mr.T, $mr.R - $mr.L, $mr.B - $mr.T, $true)
    Start-Sleep -Milliseconds 800
}

function Test-PrerequisitesDialog {
    <#
      Opens More actions > Verify > Prerequisites... and checks its state
      against what's really installed - without ever clicking Install.
    #>
    param($Ctx, [string]$Exe)
    $expectInstalled = (& $Exe -NoProfile -NonInteractive -Command "[bool](Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)" 2>$null | Select-Object -Last 1) -eq 'True'
    [void](Invoke-MoreActionsItem $Ctx 'Verify' 'Prerequisites...')
    $dlg = Wait-AppDialog $Ctx 'Prerequisites'
    Close-AppMenus $Ctx
    Assert-True ([bool]$dlg) "'Verify > Prerequisites...' opens the Prerequisites dialog"
    if (-not $dlg) { return }
    $install = Get-ChildWindow $dlg 'Install missing'
    $recheck = Get-ChildWindow $dlg 'Check again'
    Assert-True ($install -and $recheck -and (Get-ChildWindow $dlg 'Close')) "Prerequisites offers Install missing / Check again / Close"
    # the status check runs once the dialog is shown (it may start another PowerShell) - wait for it
    $end = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $end -and -not $W32::IsWindowEnabled($recheck)) { Start-Sleep -Milliseconds 300 }
    Start-Sleep -Milliseconds 500
    Save-AppShot $Ctx $dlg 'Prerequisites'
    Assert-True ($W32::IsWindowEnabled($install) -eq (-not $expectInstalled)) "Install missing is enabled exactly when the module is missing here (installed: $expectInstalled)"
    $overlaps = @(Get-ControlOverlaps $dlg)
    Assert-True ($overlaps.Count -eq 0) "no overlapping controls in 'Prerequisites'" ($overlaps -join '; ')
    Assert-True ((Close-AppDialog $dlg) -ne 'WOULD NOT CLOSE') "Prerequisites closes again"
    [void](Wait-NoAppDialogs $Ctx 5)
}

foreach ($exe in Resolve-AppHosts $AppHost) {
    $script:currentHost = [IO.Path]::GetFileNameWithoutExtension($exe)
    Write-Host "`n=== Dialog smoke test - app running under $exe ===" -ForegroundColor Cyan
    $root = New-AppSandbox
    # A Graph PowerShell sign-in cache the user already had - the app must leave it alone on exit.
    $cacheDir = Join-Path $root 'localappdata\.IdentityService'
    [void][IO.Directory]::CreateDirectory($cacheDir)
    [IO.File]::WriteAllText((Join-Path $cacheDir 'mg.msal.cache.cae'), 'pre-existing')
    $ctx = $null
    try {
        $ctx = Start-AppUnderTest -AppHost $exe -Root $root
        # ...and one that appears while the app runs (as a delegated sign-in would create) - removed on exit.
        [IO.File]::WriteAllText((Join-Path $cacheDir 'mg.msal.cache.nocae'), 'from this session')
        Assert-True ($W32::DpiAwareness($ctx.Main) -eq 0) "main window is DPI-unaware (layouts are fixed-pixel)" "awareness: $($W32::DpiAwareness($ctx.Main))"
        if ($ShotDir) {
            $ctx.ShotDir = Join-Path $ShotDir $script:currentHost
            [void][IO.Directory]::CreateDirectory($ctx.ShotDir)
        }
        Save-AppShot $ctx $ctx.Main 'main_window'
        Assert-True ($W32::Text($ctx.Main) -like 'Intune App Catalog & Deployment (v*)') "main window title"
        Assert-True ((Get-AppDialogs $ctx).Count -eq 0) "no popup at startup"
        foreach ($b in '+ Add app...', 'Edit...', 'Package apps', 'Batch deploy...', 'Intune Audit...', 'Reload', 'Settings...', 'Getting started...', 'More actions...') {
            Assert-True ($ctx.Buttons.ContainsKey($b)) "toolbar has '$b'"
        }

        Test-GridHeaders $ctx
        Test-ToolbarWraps $ctx

        # --- toolbar buttons ---
        $expectTitle = @{
            '+ Add app...'       = 'Add app'
            'Settings...'        = 'Settings - Microsoft Graph Connection'
            'Getting started...' = 'Getting started'
        }
        Select-OnlyGridRow $ctx '7-Zip'   # so Edit... has a selection
        foreach ($name in @($ctx.Buttons.Keys | Sort-Object)) {
            if ($name -match $skipPattern -or $name -eq 'More actions...' -or $name -match '^(Check|Also run)') { continue }
            if (-not $W32::IsWindowEnabled($ctx.Buttons[$name])) { continue }
            $W32::Click($ctx.Buttons[$name])
            $seen = Watch-AppDialogs $ctx
            $titles = @($seen | ForEach-Object Title)
            Write-Host "    $name -> $(if ($titles) { $titles -join ' -> ' } else { '(nothing opened)' })" -ForegroundColor DarkGray
            if ($expectTitle.ContainsKey($name)) {
                Assert-True ($titles -contains $expectTitle[$name]) "'$name' opens '$($expectTitle[$name])'" "saw: $($titles -join ', ')"
            }
            Assert-True (@($seen | Where-Object { $_.Closed -eq 'WOULD NOT CLOSE' }).Count -eq 0) "everything '$name' opened closes again"
            foreach ($w in $seen) { Assert-True ($w.Overlaps.Count -eq 0) "no overlapping controls in '$($w.Title)'" ($w.Overlaps -join '; ') }
            Assert-True (-not $ctx.Process.HasExited) "app still running after '$name'"
        }
        Clear-GridFilter $ctx

        # --- "More actions..." ---
        $groups = @(Open-MoreActionsMenu $ctx | ForEach-Object Name)
        Close-AppMenus $ctx
        Assert-True ((@('Catalog maintenance', 'Intune', 'Entra ID', 'Verify') | Where-Object { $groups -notcontains $_ }).Count -eq 0) "'More actions...' has its four groups" "found: $($groups -join ', ')"
        foreach ($group in $groups) {
            $items = @(Open-MoreActionsMenu $ctx $group | ForEach-Object Name)
            Close-AppMenus $ctx
            foreach ($item in $items) {
                if ($item -match $skipPattern) { continue }
                if ($item -eq 'Prerequisites...') { Test-PrerequisitesDialog $ctx $exe; continue }
                if (-not (Invoke-MoreActionsItem $ctx $group $item)) { continue }
                $seen = Watch-AppDialogs $ctx
                Close-AppMenus $ctx
                $titles = @($seen | ForEach-Object Title)
                Write-Host "    $group > $item -> $(if ($titles) { $titles -join ' -> ' } else { '(nothing opened)' })" -ForegroundColor DarkGray
                Assert-True (@($seen | Where-Object { $_.Closed -eq 'WOULD NOT CLOSE' }).Count -eq 0) "everything '$group > $item' opened closes again"
                foreach ($w in $seen) { Assert-True ($w.Overlaps.Count -eq 0) "no overlapping controls in '$($w.Title)'" ($w.Overlaps -join '; ') }
                Assert-True (-not $ctx.Process.HasExited) "app still running after '$group > $item'"

                switch ($item) {
                    'Run diagnostics...' {
                        Assert-True ($titles.Count -ge 1 -and $titles[0] -eq 'Diagnostics') "Diagnostics opens without a 'Not configured' popup first" "saw: $($titles -join ' -> ')"
                    }
                    'Look up App IDs...' {
                        # 'Prerequisites' when the Graph module is missing, 'Not configured' when it's there
                        Assert-True ($titles.Count -eq 1 -and $titles[0] -in @('Prerequisites', 'Not configured')) "Look up App IDs without a Graph connection shows exactly one window" "saw: $($titles -join ' -> ')"
                    }
                    'View dependencies...' {
                        Assert-True ($titles -contains 'Dependency overview') "View dependencies opens the overview" "saw: $($titles -join ' -> ')"
                        Assert-True ([string]::IsNullOrWhiteSpace((Get-AppStdErr $ctx))) "View dependencies writes no errors for apps without dependency metadata" (Get-AppStdErr $ctx)
                    }
                    'Edit default values...' {
                        Assert-True ($titles -contains 'Edit default values') "Edit default values opens" "saw: $($titles -join ' -> ')"
                    }
                }
            }
        }
    }
    catch {
        Assert-True $false "test run completed" "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
    }
    finally {
        if ($ctx) {
            Assert-True (Stop-AppUnderTest $ctx) "app closes cleanly"
            $err = Get-AppStdErr $ctx
            Assert-True ([string]::IsNullOrWhiteSpace($err)) "app wrote nothing to stderr" $err
            Assert-True (Test-Path (Join-Path $cacheDir 'mg.msal.cache.cae')) "a sign-in cache file that existed before the app started is kept"
            Assert-True (-not (Test-Path (Join-Path $cacheDir 'mg.msal.cache.nocae'))) "a sign-in cache file created during the session is removed on exit"
        }
        Remove-AppSandbox $root
    }
}
$script:currentHost = ''
exit (Write-TestReport)
