<#
.SYNOPSIS
    Runs INSIDE the app process for DialogLayout.GuiTests.ps1 - copied into
    the test sandbox and started in place of IntuneDeployment.ps1, which it
    then loads itself.

.DESCRIPTION
    Once the main window is up, opens every dialog in turn with sample data
    (including deliberately long app and group names), measures each visible
    control's text against the space it actually has, screenshots the
    window, and closes it again. Message boxes that pop up along the way are
    recorded and dismissed (No / Cancel / close).

    Writes one line per event to <OutDir>\findings.txt:
        == <step>
          window '<title>' (<w>x<h>): ok | <n> issue(s)
              <KIND> <details>
            msgbox: [<title>] <text>
            step error: <message>
        == DONE
    and closes the app when every step has run.
#>
param([Parameter(Mandatory)][string]$OutDir, [string]$ShotDir, [string]$Only = "")
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace LayoutAudit -Name Native -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool EnumThreadWindows(uint tid, EnumProc cb, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool EnumChildWindows(System.IntPtr p, EnumProc cb, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder sb, int n);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder sb, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr h, System.IntPtr hdc, uint flags);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
// Message boxes (#32770) this thread currently shows.
public static System.Collections.Generic.List<System.IntPtr> MessageBoxes() {
    var r = new System.Collections.Generic.List<System.IntPtr>();
    EnumThreadWindows(GetCurrentThreadId(), (h, l) => { var sb = new System.Text.StringBuilder(64); GetClassName(h, sb, 64); if (sb.ToString() == "#32770" && IsWindowVisible(h)) r.Add(h); return true; }, System.IntPtr.Zero);
    return r;
}
// "[title] text" of a message box.
public static string Describe(System.IntPtr h) {
    var parts = new System.Collections.Generic.List<string>();
    var t = new System.Text.StringBuilder(512); GetWindowText(h, t, 512); parts.Add("[" + t + "]");
    EnumChildWindows(h, (c, l) => { var cls = new System.Text.StringBuilder(64); GetClassName(c, cls, 64); if (cls.ToString() == "Static") { var sb = new System.Text.StringBuilder(2048); GetWindowText(c, sb, 2048); if (sb.Length > 0) parts.Add(sb.ToString()); } return true; }, System.IntPtr.Zero);
    return string.Join(" ", parts).Replace("\r", " ").Replace("\n", " ");
}
'@

$Global:LayoutAudit = @{
    Log   = Join-Path $OutDir 'findings.txt'
    Shots = $ShotDir
    ShotN = 0
    Seen  = @{}
    Steps = New-Object System.Collections.Queue
    Only  = $Only
}
[IO.File]::WriteAllText($Global:LayoutAudit.Log, "")
function Global:Write-LayoutAudit([string]$Line) { [IO.File]::AppendAllText($Global:LayoutAudit.Log, $Line + "`r`n") }
function Global:Add-LayoutAuditStep([string]$Name, [scriptblock]$Run) {
    # -Only filters here rather than at run time, so a filtered run really
    # does open just those windows instead of opening them all and
    # reporting on a few.
    if ($Global:LayoutAudit.Only -and $Name -notlike $Global:LayoutAudit.Only) { return }
    $Global:LayoutAudit.Steps.Enqueue([pscustomobject]@{ Name = $Name; Run = $Run })
}

function Global:Measure-WrappedText($Text, $Font, [int]$Width) {
    $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::TextBoxControl
    [System.Windows.Forms.TextRenderer]::MeasureText([string]$Text, $Font, (New-Object System.Drawing.Size($Width, 100000)), $flags)
}

function Global:Get-LayoutControlName($c) {
    # Whitespace collapsed to single spaces first: a log box's own text
    # carries newlines, and a finding that starts with one is a finding
    # whose second half - the control it overlaps, and by how much - ends
    # up on a line of its own that reads like a different result entirely.
    $t = ([string]$c.Text) -replace '\s+', ' '
    $shown = if ($t.Length -gt 45) { "'$($t.Substring(0, 42))...'" } elseif ($t) { "'$t'" } else { "" }
    "$($c.GetType().Name) $shown".Trim()
}

function Global:Get-FormTabControls($Parent) {
    # Every TabControl in the window, however deeply nested.
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($c in @($Parent.Controls)) {
        if ($c -is [System.Windows.Forms.TabControl]) { [void]$found.Add($c) }
        foreach ($nested in @(Get-FormTabControls $c)) { [void]$found.Add($nested) }
    }
    return $found.ToArray()
}

function Global:Test-FormLayout($Form) {
    <# Every visible control whose text doesn't fit, that runs outside its container, or that overlaps a sibling. #>
    $issues = New-Object System.Collections.Generic.List[string]
    # the window itself has to fit the screen (or the pretend one - INTUNEPACKAGER_TEST_SCREEN)
    $area = Get-UsableScreenArea
    if ($Form.Width -gt $area.Width -or $Form.Height -gt $area.Height) {
        $issues.Add("TOO BIG  window is $($Form.Width)x$($Form.Height), usable screen area is $($area.Width)x$($area.Height)")
    }
    # nothing preselected in the focused box (a keystroke would replace it)
    $focused = $Form.ActiveControl
    while ($focused -is [System.Windows.Forms.ContainerControl] -and $focused.ActiveControl) { $focused = $focused.ActiveControl }
    if ($focused -is [System.Windows.Forms.TextBoxBase] -and $focused.TextLength -gt 0 -and $focused.SelectionLength -eq $focused.TextLength) {
        $issues.Add("SELECTED $(Get-LayoutControlName $focused): all its text is preselected when the window opens")
    }    $walk = {
        param($parent)
        $kids = @($parent.Controls | Where-Object { $_.Visible })
        foreach ($c in $kids) {
            $cs = $c.ClientSize
            $txt = [string]$c.Text
            $name = Get-LayoutControlName $c
            $isContainer = $c -is [System.Windows.Forms.Panel] -or $c -is [System.Windows.Forms.GroupBox] -or $c -is [System.Windows.Forms.TabControl] -or $c -is [System.Windows.Forms.TabPage] -or $c -is [System.Windows.Forms.SplitContainer] -or $c -is [System.Windows.Forms.UserControl]

            # text that doesn't fit its own control
            if ($c -is [System.Windows.Forms.Label] -and $txt -and -not $c.AutoSize -and -not $c.AutoEllipsis) {
                $avail = $cs.Width - $c.Padding.Horizontal
                $need = Measure-WrappedText $txt $c.Font $avail
                if ($need.Height -gt ($cs.Height - $c.Padding.Vertical + 1)) { $issues.Add("CLIPPED  ${name}: text needs $($need.Height)px height, has $($cs.Height)px") }
                if ($need.Width -gt ($avail + 1)) { $issues.Add("CLIPPED  ${name}: a word needs $($need.Width)px width, has $($avail)px") }
            }
            if ($c -is [System.Windows.Forms.Button] -and $txt -and -not $c.AutoSize) {
                $avail = $cs.Width - 12
                $need = Measure-WrappedText $txt $c.Font $avail
                if ($need.Width -gt $avail -or $need.Height -gt ($cs.Height - 6)) { $issues.Add("CLIPPED  ${name}: text needs $($need.Width)x$($need.Height), has $($avail)x$($cs.Height - 6)") }
            }
            if (($c -is [System.Windows.Forms.CheckBox] -or $c -is [System.Windows.Forms.RadioButton]) -and $txt -and -not $c.AutoSize) {
                $avail = $cs.Width - 20
                $need = Measure-WrappedText $txt $c.Font $avail
                if ($need.Width -gt $avail -or $need.Height -gt ($cs.Height + 1)) { $issues.Add("CLIPPED  ${name}: text needs $($need.Width)x$($need.Height), has $($avail)x$($cs.Height)") }
            }
            if ($c -is [System.Windows.Forms.GroupBox] -and $txt) {
                $need = [System.Windows.Forms.TextRenderer]::MeasureText($txt, $c.Font).Width + 16
                if ($need -gt $c.Width) { $issues.Add("CLIPPED  ${name}: caption needs $($need)px, box is $($c.Width)px") }
            }
            if ($c -is [System.Windows.Forms.ComboBox] -and $c.DropDownStyle -eq 'DropDownList' -and $c.SelectedItem) {
                $need = [System.Windows.Forms.TextRenderer]::MeasureText([string]$c.SelectedItem, $c.Font).Width + 24
                if ($need -gt $c.Width) { $issues.Add("CLIPPED  ComboBox showing '$($c.SelectedItem)': needs $($need)px, has $($c.Width)px") }
            }
            if ($c -is [System.Windows.Forms.ListBox] -and -not $c.HorizontalScrollbar -and $c.Items.Count) {
                $avail = $cs.Width - $(if ($c -is [System.Windows.Forms.CheckedListBox]) { 20 } else { 4 })
                $wide = @($c.Items | Where-Object { [System.Windows.Forms.TextRenderer]::MeasureText([string]$_, $c.Font).Width -gt $avail } | ForEach-Object { [string]$_ })
                if ($wide.Count) { $issues.Add("CUT      $($c.GetType().Name) entries wider than the list ($($avail)px), no scrollbar: $(($wide | Select-Object -First 3) -join ' | ')") }
            }
            if ($c -is [System.Windows.Forms.DataGridView] -and $c.ColumnHeadersHeightSizeMode -ne [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize) {
                # (an AutoSize header row wraps long headers onto a second line instead)
                $headerFont = if ($c.ColumnHeadersDefaultCellStyle.Font) { $c.ColumnHeadersDefaultCellStyle.Font } else { $c.Font }
                foreach ($col in $c.Columns) {
                    if (-not $col.Visible -or -not $col.HeaderText) { continue }
                    $need = [System.Windows.Forms.TextRenderer]::MeasureText($col.HeaderText, $headerFont).Width + 12
                    if ($need -gt $col.Width) { $issues.Add("CUT      grid header '$($col.HeaderText)': needs $($need)px, column is $($col.Width)px") }
                }
            }

            # control running past its container's visible area
            $scrolls = ($parent -is [System.Windows.Forms.ScrollableControl]) -and $parent.AutoScroll
            $laysOut = ($parent -is [System.Windows.Forms.FlowLayoutPanel]) -or ($parent -is [System.Windows.Forms.TableLayoutPanel])
            if (-not $scrolls -and -not $laysOut) {
                $area = $parent.DisplayRectangle
                if ($c.Right -gt $area.Right + 1 -or $c.Bottom -gt $area.Bottom + 1) {
                    $issues.Add("OUTSIDE  $name ends at ($($c.Right),$($c.Bottom)), its container's area ends at ($($area.Right),$($area.Bottom))")
                }
            }

            # siblings overlapping (containers excluded - things sit inside them)
            if (-not $isContainer) {
                $myIndex = [Array]::IndexOf($kids, $c)
                for ($j = $myIndex + 1; $j -lt $kids.Count; $j++) {
                    $o = $kids[$j]
                    if ($o -is [System.Windows.Forms.Panel] -or $o -is [System.Windows.Forms.GroupBox] -or $o -is [System.Windows.Forms.TabControl]) { continue }
                    $r = [System.Drawing.Rectangle]::Intersect($c.Bounds, $o.Bounds)
                    if ($r.Width -gt 0 -and $r.Height -gt 0) { $issues.Add("OVERLAP  $name and $(Get-LayoutControlName $o) by $($r.Width)x$($r.Height)px") }
                }
            }

            $hasOwnParts = $c -is [System.Windows.Forms.DataGridView] -or $c -is [System.Windows.Forms.ComboBox] -or $c -is [System.Windows.Forms.NumericUpDown]
            if ($c.Controls.Count -and -not $hasOwnParts) { & $walk $c }
        }
    }
    & $walk $Form
    return , $issues
}

function Global:Save-LayoutShot($Form) {
    if (-not $Global:LayoutAudit.Shots) { return }
    try {
        $Global:LayoutAudit.ShotN++
        $bmp = New-Object System.Drawing.Bitmap $Form.Width, $Form.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        # PrintWindow, not DrawToBitmap - that one skips RichTextBox content on .NET Framework
        [void][LayoutAudit.Native]::PrintWindow($Form.Handle, $hdc, 2)
        $g.ReleaseHdc($hdc); $g.Dispose()
        $safe = (($Form.Text -replace '[^\w\- ]', '').Trim()) -replace '\s+', '_'
        $bmp.Save((Join-Path $Global:LayoutAudit.Shots ('{0:D2}_{1}.png' -f $Global:LayoutAudit.ShotN, $safe)))
        $bmp.Dispose()
    } catch { }
}

function Global:Close-LayoutAuditWindow {
    # the topmost thing first: a message box, else the newest dialog
    foreach ($mb in [LayoutAudit.Native]::MessageBoxes()) {
        Write-LayoutAudit "    msgbox: $([LayoutAudit.Native]::Describe($mb))"
        [void][LayoutAudit.Native]::PostMessage($mb, 0x0111, [IntPtr]7, [IntPtr]::Zero)   # WM_COMMAND IDNO
        [void][LayoutAudit.Native]::PostMessage($mb, 0x0111, [IntPtr]2, [IntPtr]::Zero)   # WM_COMMAND IDCANCEL
        [void][LayoutAudit.Native]::PostMessage($mb, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        return
    }
    $forms = @([System.Windows.Forms.Application]::OpenForms | Where-Object { -not [object]::ReferenceEquals($_, $Global:App.Form) -and $_.Visible })
    if (-not $forms) { return }
    $f = $forms[-1]
    $key = $f.GetHashCode()
    if (-not $Global:LayoutAudit.Seen.ContainsKey($key)) {
        $Global:LayoutAudit.Seen[$key] = $true
        # Every tab page, not just the one that happens to be open: an
        # unselected TabPage isn't Visible, so the walk below skips it and a
        # whole tab's worth of layout would never be measured at all.
        $issues = New-Object System.Collections.Generic.List[string]
        foreach ($i in (Test-FormLayout $f)) { [void]$issues.Add($i) }
        foreach ($tabs in @(Get-FormTabControls $f)) {
            $originalIndex = $tabs.SelectedIndex
            for ($p = 0; $p -lt $tabs.TabPages.Count; $p++) {
                if ($p -eq $originalIndex) { continue }
                $tabs.SelectedIndex = $p
                [System.Windows.Forms.Application]::DoEvents()
                foreach ($i in (Test-FormLayout $f)) {
                    $tagged = "[tab '$($tabs.TabPages[$p].Text)'] $i"
                    if (-not $issues.Contains($tagged)) { [void]$issues.Add($tagged) }
                }
                Save-LayoutShot $f
            }
            if ($originalIndex -ge 0) { $tabs.SelectedIndex = $originalIndex; [System.Windows.Forms.Application]::DoEvents() }
        }
        Write-LayoutAudit "  window '$($f.Text)' ($($f.ClientSize.Width)x$($f.ClientSize.Height)): $(if ($issues.Count) { "$($issues.Count) issue(s)" } else { 'ok' })"
        foreach ($i in $issues) { Write-LayoutAudit "      $i" }
        Save-LayoutShot $f
    }
    $f.Close()   # a busy dialog may refuse - the next tick asks again
}

# ---------------------------------------------------------------------------
# The dialogs, with the sample state they need
# ---------------------------------------------------------------------------
function Global:Register-LayoutAuditSteps {
    $apps = $Global:App.Apps
    $a0 = $apps | Where-Object appName -eq '7-Zip' | Select-Object -First 1
    $a0 | Add-Member -NotePropertyName metadata -NotePropertyValue (Get-DefaultAppMetadata -AppName '7-Zip' -WingetId '7zip.7zip' -Uncommon $false) -Force
    $longGroup = 'SG-Intune-Win32-Required-Production-AllManagedDevices-EMEA'
    $a0.requiredFor = @($a0.requiredFor) + $longGroup
    $a0.availableFor = @($a0.availableFor) + 'SG-Intune-Win32-Available-Pilot-Ring-Finance-Department'
    $long = $a0.PSObject.Copy()
    $long.appName = 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - Enterprise Edition'
    $long.wingetId = 'Microsoft.VCRedist.2015+.x64'
    $long.appId = 'c0ffee00-1111-4222-8333-444455556666'
    [void]$apps.Add($long)
    $noId = $apps | Where-Object { -not $_.appId } | Select-Object -First 1
    [void]$Global:App.FavoriteGroups.Add('SG-Intune-AllDevices')
    [void]$Global:App.FavoriteGroups.Add($longGroup)
    foreach ($a in @($a0, $long, $noId)) {
        $Global:App.IntuneAppsCache.Add([pscustomobject]@{ displayName = $a.appName; id = $(if ($a.appId) { $a.appId } else { 'b1b2b3b4-0000-4000-8000-000000000001' }); '@odata.type' = '#microsoft.graph.win32LobApp' })
    }
    $i0 = $apps.IndexOf($a0); $iLong = $apps.IndexOf($long); $iNoId = $apps.IndexOf($noId)
    $all = @(0..($apps.Count - 1))

    Add-LayoutAuditStep 'App editor (existing)' { Show-AppEditor -ExistingApp $a0 -CurrentIndex $i0 }.GetNewClosure()
    Add-LayoutAuditStep 'App editor (long name)' { Show-AppEditor -ExistingApp $long -CurrentIndex $iLong }.GetNewClosure()
    Add-LayoutAuditStep 'App editor (new)' { Show-AppEditor -ExistingApp $null }
    Add-LayoutAuditStep 'Add favorite group to apps' { Show-AddFavoriteGroupToAppsDialog -CandidateApps @($apps) }.GetNewClosure()
    Add-LayoutAuditStep 'Remove group from apps' { Show-RemoveGroupFromAppsDialog -CandidateApps @($apps) }.GetNewClosure()
    Add-LayoutAuditStep 'Look up App IDs' { Show-AppIdMatchDialog }
    Add-LayoutAuditStep 'App registration guide' { Show-AppRegistrationGuideDialog }
    Add-LayoutAuditStep 'Batch assign' { Show-BatchAssignDialog -ScopedIndices $all }.GetNewClosure()
    Add-LayoutAuditStep 'Batch deploy' { Show-BatchDeployDialog -ScopedIndices @($iNoId) }.GetNewClosure()
    Add-LayoutAuditStep 'Batch edit Intune fields' { Show-BatchEditMetadataDialog -ScopedIndices @($i0) }.GetNewClosure()
    Add-LayoutAuditStep 'Delete from Intune (bulk)' { Show-BulkDeleteFromIntuneDialog -Indices @($i0, $iLong) }.GetNewClosure()
    Add-LayoutAuditStep 'Certificate picker' { Show-CertificatePickerDialog }
    Add-LayoutAuditStep 'Settings' { Show-CertificateSetupDialog }
    Add-LayoutAuditStep 'Deploy to Intune (existing)' { Show-CreateInIntuneDialog -AppName $a0.appName -WingetId $a0.wingetId -ExistingAppId $a0.appId }.GetNewClosure()
    Add-LayoutAuditStep 'Deploy to Intune (from app editor, with Previous/Next)' { Show-CreateInIntuneDialog -AppName $a0.appName -WingetId $a0.wingetId -ExistingAppId $a0.appId -FromAppEditor -CallerHasExistingCatalogEntry -CurrentIndex $i0 }.GetNewClosure()
    Add-LayoutAuditStep 'Deploy to Intune (long name)' { Show-CreateInIntuneDialog -AppName $long.appName -WingetId $long.wingetId -ExistingAppId $long.appId }.GetNewClosure()
    Add-LayoutAuditStep 'Deploy to Intune (new)' { Show-CreateInIntuneDialog -AppName $noId.appName -WingetId '' }.GetNewClosure()
    Add-LayoutAuditStep 'Edit default values' { Show-DefaultAppSettingsDialog }
    Add-LayoutAuditStep 'Delete from Intune (single)' { Show-DeleteAppDialog -AppId $a0.appId -AppName $a0.appName }.GetNewClosure()
    Add-LayoutAuditStep 'Delete from Intune (long name)' { Show-DeleteAppDialog -AppId $long.appId -AppName $long.appName }.GetNewClosure()
    Add-LayoutAuditStep 'Delete local certificate' { Show-DeleteLocalCertificateDialog }
    Add-LayoutAuditStep 'Dependency overview' { Show-DependencyOverviewDialog }
    Add-LayoutAuditStep 'Diagnostics' { Show-DiagnosticsDialog }
    Add-LayoutAuditStep 'Add group or user' { Show-EntraMemberPicker }
    Add-LayoutAuditStep 'Favorite groups' { Show-FavoriteGroupsManager }
    Add-LayoutAuditStep 'Getting started' { Show-GettingStartedGuideDialog }
    Add-LayoutAuditStep 'Group name check' { Show-GroupDriftCheckDialog }
    Add-LayoutAuditStep 'Checks (all seven)' { Show-ChecksDialog }
    # The four standalone check dialogs are audited one by one above and
    # below; this is the window that hosts them as tabs, where they have
    # to fit a shared page instead of their own form.
    Add-LayoutAuditStep 'Group manager' { Show-GroupManagerDialog }
    Add-LayoutAuditStep 'Delete groups (bulk)' { Show-BulkDeleteGroupsDialog }
    Add-LayoutAuditStep 'Find a group' { Show-GroupOnlyPicker }
    Add-LayoutAuditStep 'Intune Audit' { Show-IntuneAuditDialog }
    Add-LayoutAuditStep 'Intune sync check' { Show-IntuneOnlyAppsDialog }
    Add-LayoutAuditStep 'Install status' { Show-AppInstallStatusDialog -AppId $a0.appId -AppName $a0.appName }.GetNewClosure()
    Add-LayoutAuditStep 'Platform scripts' { Show-PlatformScriptsDialog }
    Add-LayoutAuditStep 'Platform script run status' { Show-PlatformScriptRunStatusDialog -ScriptId 'd1e2f3a4-0000-4000-8000-000000000001' -ScriptName 'Set the time zone on every enrolled device' }
    Add-LayoutAuditStep 'Platform script (new)' { Show-PlatformScriptEditorDialog }
    Add-LayoutAuditStep 'Platform script (existing)' {
        Show-PlatformScriptEditorDialog -ScriptId 'd1e2f3a4-0000-4000-8000-000000000001' `
            -DisplayName 'Set the time zone on every enrolled device' -Description 'Sets W. Europe Standard Time and enables automatic DST' `
            -FileName 'Set-TimeZone.ps1' -ScriptContent "Set-TimeZone -Id 'W. Europe Standard Time'`nSet-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -Name 'DynamicDaylightTimeDisabled' -Value 0" `
            -RunAsAccount 'system' -RunAs32Bit $false -EnforceSignatureCheck $false -GroupNames @($longGroup, 'SG-Intune-AllDevices')
    }.GetNewClosure()
    Add-LayoutAuditStep 'Install status (long name)' { Show-AppInstallStatusDialog -AppId $long.appId -AppName $long.appName }.GetNewClosure()
    Add-LayoutAuditStep 'Local vs. Intune' {
        Show-MetadataDriftDialog -AppName $a0.appName -Rows @(
            [pscustomobject]@{ Field = 'Install command'; Local = 'powershell.exe -ExecutionPolicy Bypass -File install.ps1 -Mode Silent -LogPath C:\Windows\Temp\7zip.log'; Intune = 'install.cmd' }
            [pscustomobject]@{ Field = 'Minimum Windows'; Local = 'Windows 10 22H2'; Intune = 'Windows 11 22H2' })
    }.GetNewClosure()
    Add-LayoutAuditStep 'Set default values (confirm)' { Show-SetDefaultsConfirmDialog -Lines @('Install context: System -> User', 'Minimum Windows: Windows 10 22H2 -> Windows 11 22H2', 'Return codes: 5 -> 6 rows') -ParentForm $Global:App.Form }
    Add-LayoutAuditStep 'Pull metadata and groups' { Show-SyncMetadataDialog -ScopedIndices @($i0) }.GetNewClosure()
    Add-LayoutAuditStep 'Assign groups' { Show-TargetedAssignDialog -AppId $a0.appId -AppName $a0.appName -RequiredGroups @($a0.requiredFor) -AvailableGroups @($a0.availableFor) -UninstallGroups @() }.GetNewClosure()
    Add-LayoutAuditStep 'Assign groups (long names)' { Show-TargetedAssignDialog -AppId $long.appId -AppName $long.appName -RequiredGroups @($longGroup) -AvailableGroups @() -UninstallGroups @() }.GetNewClosure()
    Add-LayoutAuditStep 'Winget package check' { Show-WingetHealthCheckDialog }
    Add-LayoutAuditStep 'Search winget' { Show-WingetSearchDialog -InitialQuery '' }
    Add-LayoutAuditStep 'Multiple matches picker' {
        Show-SimpleListPicker -Title 'Multiple matches' -Prompt "Several Intune apps match '$($long.appName)'. Pick one:" -Items @("$($long.appName)  [$($long.appId)]", "Microsoft Visual C++ Redistributable  [c0ffee00-1111-4222-8333-444455556667]")
    }.GetNewClosure()
    Add-LayoutAuditStep 'Prerequisites' { Show-PrerequisitesDialog }
}

# ---------------------------------------------------------------------------
# Drive it: start once the main window's message loop runs
# ---------------------------------------------------------------------------
# Looks at (and closes) whatever the current step opened: first after 2.5 s,
# then every 1.5 s.
$Global:LayoutAudit.Closer = New-Object System.Windows.Forms.Timer
$Global:LayoutAudit.Closer.Interval = 2500
$Global:LayoutAudit.Closer.Add_Tick({
    $Global:LayoutAudit.Closer.Interval = 1500
    try { Close-LayoutAuditWindow } catch { Write-LayoutAudit "    closer error: $($_.Exception.Message)" }
})

$Global:LayoutAudit.Kick = New-Object System.Windows.Forms.Timer
$Global:LayoutAudit.Kick.Interval = 6000
$Global:LayoutAudit.Kick.Add_Tick({
    $Global:LayoutAudit.Kick.Stop()
    try { Register-LayoutAuditSteps } catch { Write-LayoutAudit "    step error: sample data: $($_.Exception.Message)" }
    $Global:LayoutAudit.Closer.Start()
    while ($Global:LayoutAudit.Steps.Count) {
        $step = $Global:LayoutAudit.Steps.Dequeue()
        Write-LayoutAudit "== $($step.Name)"
        $Global:LayoutAudit.Closer.Interval = 2500
        try { [void](& $step.Run) } catch { Write-LayoutAudit "    step error: $($_.Exception.Message)" }
        # give a follow-up window (e.g. a message box after a dialog) time to show and be handled
        $settle = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $settle) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    }
    $Global:LayoutAudit.Closer.Stop()
    Write-LayoutAudit "== DONE"
    $Global:App.UnsavedChangesBox.Value = $false
    $Global:App.Form.Close()
})
$Global:LayoutAudit.Kick.Start()

. (Join-Path $PSScriptRoot 'IntuneDeployment.ps1')
