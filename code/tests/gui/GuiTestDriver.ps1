<#
.SYNOPSIS
    Shared plumbing for the GUI tests in this folder - dot-source it, don't
    run it.

.DESCRIPTION
    Drives the REAL app (IntuneDeployment.ps1) through Win32 messages, not
    by calling its functions: every click is a posted BM_CLICK / mouse
    message, text goes in via WM_SETTEXT, and dialogs are closed with a
    posted WM_CLOSE. Nothing here ever waits synchronously on the app's UI
    thread - a synchronous UI Automation Invoke on a button that opens a
    modal dialog never returns, and hangs every UIA call after it.

    Menu items ("More actions..." dropdown) are ToolStrip items with no
    window handle; they're found via MSAA (IAccessible), which works on
    both .NET and .NET Framework - UI Automation sees no children in a
    .NET Framework ToolStripDropDown at all.

    Every run happens in a throwaway SANDBOX copy of the app (see
    New-AppSandbox): its own data folder with fixture apps, no settings
    file (so no Graph credentials - every Graph-facing action stops at its
    own "not configured" / "module missing" guard), and LOCALAPPDATA
    pointed inside the sandbox for the app process, because the app clears
    the Microsoft Graph PowerShell sign-in cache under LOCALAPPDATA when it
    closes. The repo's own data folder is never touched.

    Windows only, needs an interactive desktop session (the app's windows
    are real windows). Works from either PowerShell 7 or Windows
    PowerShell 5.1, and can drive the app under either one.
#>

if (-not ('GuiTest.W32' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace GuiTest {
    public static class W32 {
        public delegate bool EnumProc(IntPtr h, IntPtr l);
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextLength(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
        [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref POINT p);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
        [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
        [DllImport("user32.dll")] static extern IntPtr ChildWindowFromPointEx(IntPtr p, POINT pt, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int index);
        [DllImport("user32.dll")] static extern IntPtr GetWindowDpiAwarenessContext(IntPtr h);
        [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageSb(IntPtr h, uint m, IntPtr w, StringBuilder l);
        [DllImport("user32.dll", EntryPoint = "SendMessageW")] static extern IntPtr SendMessagePtr(IntPtr h, uint m, IntPtr w, IntPtr l);
        // 0 = unaware, 1 = system aware, 2 = per-monitor aware
        public static int DpiAwareness(IntPtr h) { return GetAwarenessFromDpiAwarenessContext(GetWindowDpiAwarenessContext(h)); }
        // Full control text via WM_GETTEXT - GetWindowText can't read e.g. a RichEdit in another process.
        public static string ControlText(IntPtr h) {
            int len = SendMessagePtr(h, 0x000E, IntPtr.Zero, IntPtr.Zero).ToInt32();   // WM_GETTEXTLENGTH
            var sb = new StringBuilder(len + 2);
            SendMessageSb(h, 0x000D, (IntPtr)sb.Capacity, sb);                            // WM_GETTEXT
            return sb.ToString();
        }

        public static string Text(IntPtr h) { var sb = new StringBuilder(GetWindowTextLength(h) + 2); GetWindowText(h, sb, sb.Capacity); return sb.ToString(); }
        public static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
        public static uint ProcessOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
        public static List<IntPtr> TopLevel(uint pid) {
            var r = new List<IntPtr>();
            EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) r.Add(h); return true; }, IntPtr.Zero);
            return r;
        }
        public static List<IntPtr> Children(IntPtr parent) {
            var r = new List<IntPtr>();
            EnumChildWindows(parent, (h, l) => { r.Add(h); return true; }, IntPtr.Zero);
            return r;
        }
        public static void Click(IntPtr h) { PostMessage(h, 0x00F5, IntPtr.Zero, IntPtr.Zero); }   // BM_CLICK
        public static void Close(IntPtr h) { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }   // WM_CLOSE
        public static void Escape(IntPtr h) { PostMessage(h, 0x0100, (IntPtr)0x1B, IntPtr.Zero); } // WM_KEYDOWN VK_ESCAPE
        public static void SetText(IntPtr h, string s) { SendMessage(h, 0x000C, IntPtr.Zero, s); }  // WM_SETTEXT
        public static int DefaultButtonId(IntPtr h) { return (int)(SendMessagePtr(h, 0x0400, IntPtr.Zero, IntPtr.Zero).ToInt64() & 0xFFFF); }  // DM_GETDEFID (IDYES 6, IDNO 7)
        public static void ClickAt(IntPtr h, int screenX, int screenY) {
            var p = new POINT { X = screenX, Y = screenY }; ScreenToClient(h, ref p);
            var lp = (IntPtr)((p.Y << 16) | (p.X & 0xFFFF));
            PostMessage(h, 0x0200, IntPtr.Zero, lp);   // WM_MOUSEMOVE
            PostMessage(h, 0x0201, (IntPtr)1, lp);     // WM_LBUTTONDOWN
            PostMessage(h, 0x0202, IntPtr.Zero, lp);   // WM_LBUTTONUP
        }
        // Deepest visible child under a screen point - independent of other apps' z-order.
        public static IntPtr Deepest(IntPtr top, int screenX, int screenY) {
            IntPtr cur = top;
            for (int i = 0; i < 20; i++) {
                var p = new POINT { X = screenX, Y = screenY }; ScreenToClient(cur, ref p);
                IntPtr c = ChildWindowFromPointEx(cur, p, 0x0001 | 0x0004);
                if (c == IntPtr.Zero || c == cur) return cur;
                cur = c;
            }
            return cur;
        }
    }
}
'@
}

if (-not ('GuiTest.Msaa' -as [type])) {
    # On PowerShell 7, -ReferencedAssemblies replaces the default reference
    # set, so the core ones have to be listed again; Accessibility.dll is a
    # .NET Framework-era assembly, hence -IgnoreWarnings for its
    # System.Runtime 4.0 -> current version unification warning.
    $msaaRefs = if ($PSVersionTable.PSEdition -eq 'Core') { @('Accessibility', 'System.Runtime', 'System.Collections', 'System.Runtime.InteropServices') } else { @('Accessibility') }
    Add-Type -ReferencedAssemblies $msaaRefs -IgnoreWarnings -WarningAction SilentlyContinue @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Accessibility;
namespace GuiTest {
    public class AccItem { public string Name; public bool Enabled; public int X; public int Y; }
    public static class Msaa {
        [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr h, uint id, ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
        [DllImport("oleacc.dll")] static extern int AccessibleChildren(IAccessible p, int start, int count, [Out] object[] kids, out int got);
        // Every menu item (ROLE_SYSTEM_MENUITEM) inside a dropdown window, with its screen-space center.
        public static List<AccItem> MenuItems(IntPtr hwnd) {
            var res = new List<AccItem>();
            Guid iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
            object o; AccessibleObjectFromWindow(hwnd, 0xFFFFFFFC, ref iid, out o);   // OBJID_CLIENT
            Walk(o as IAccessible, res, 0);
            return res;
        }
        static void Walk(IAccessible acc, List<AccItem> res, int depth) {
            if (acc == null || depth > 3) return;
            int n = acc.accChildCount; if (n <= 0) return;
            var kids = new object[n]; int got;
            AccessibleChildren(acc, 0, n, kids, out got);
            for (int i = 0; i < got; i++) {
                var k = kids[i] as IAccessible;
                if (k == null) continue;
                int role = 0; try { role = Convert.ToInt32(k.get_accRole(0)); } catch { }
                if (role == 12) {
                    int x, y, w, h; k.accLocation(out x, out y, out w, out h, 0);
                    int st = Convert.ToInt32(k.get_accState(0));
                    res.Add(new AccItem { Name = k.get_accName(0), Enabled = (st & 1) == 0, X = x + w / 2, Y = y + h / 2 });
                } else Walk(k, res, depth + 1);
            }
        }
    }
}
'@
}

Add-Type -AssemblyName System.Drawing
$script:W32 = [GuiTest.W32]

# ---------------------------------------------------------------------------
# Assertions / reporting - same shape as CatalogLogic.Tests.ps1
# ---------------------------------------------------------------------------
$script:failures = New-Object System.Collections.Generic.List[string]
$script:passCount = 0
$script:currentHost = ''

function Assert-True {
    param([bool]$Condition, [string]$Because, [string]$Detail = '')
    $label = if ($script:currentHost) { "[$script:currentHost] $Because" } else { $Because }
    if ($Condition) {
        $script:passCount++
        Write-Host "  ok   $label" -ForegroundColor DarkGreen
    } else {
        $script:failures.Add("$label$(if ($Detail) { "`n    $Detail" })")
        Write-Host "  FAIL $label $(if ($Detail) { "- $Detail" })" -ForegroundColor Red
    }
}

function Write-TestReport {
    Write-Host ""
    if ($script:failures.Count -eq 0) {
        Write-Host "PASSED: $($script:passCount) assertion(s), 0 failure(s)." -ForegroundColor Green
        return 0
    }
    Write-Host "FAILED: $($script:failures.Count) of $($script:passCount + $script:failures.Count) assertion(s)." -ForegroundColor Red
    foreach ($f in $script:failures) { Write-Host "`n$f" -ForegroundColor Red }
    return 1
}

function Resolve-AppHosts {
    # 'pwsh' / 'powershell' / full paths -> executables that actually exist here
    param([string[]]$Names)
    foreach ($n in $Names) {
        $cmd = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $cmd.Source } else { Write-Host "Skipping host '$n' - not found on this machine." -ForegroundColor Yellow }
    }
}

# ---------------------------------------------------------------------------
# Sandbox + app lifecycle
# ---------------------------------------------------------------------------
function New-AppSandbox {
    <#
      Copies just what the app needs to run into a fresh temp folder and
      seeds data\app-data with fixture apps. Returns the sandbox root.
    #>
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $root = Join-Path ([IO.Path]::GetTempPath()) ("intune-app-catalog-guitest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($root)
    Copy-Item (Join-Path $repoRoot 'IntuneDeployment.ps1'), (Join-Path $repoRoot 'MainApp.ps1') $root
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'code'))
    Copy-Item (Join-Path $repoRoot 'code\Private') (Join-Path $root 'code\Private') -Recurse
    Copy-Item (Join-Path $repoRoot 'code\EmbeddedScripts') (Join-Path $root 'code\EmbeddedScripts') -Recurse
    $appData = Join-Path $root 'data\app-data'
    [void][IO.Directory]::CreateDirectory($appData)
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'localappdata'))
    $fixtures = @(
        [ordered]@{ appName = '7-Zip'; wingetId = '7zip.7zip'; appId = '3f1c2a9e-5b7d-4e21-9a0c-8d6e4b1f2a37'; intuneAppType = 'Windows app (Win32)'; intuneAppVersion = '24.08'; requiredFor = @('SG-Intune-AllDevices'); availableFor = @('SG-Intune-Pilot', 'SG-IT'); uninstallFor = @() }
        [ordered]@{ appName = 'Google Chrome Enterprise'; wingetId = 'Google.Chrome.EXE'; appId = 'a7b8c9d0-1e2f-4a3b-8c4d-5e6f7a8b9c0d'; intuneAppType = 'Windows app (Win32)'; intuneAppVersion = '140.0.7339.128'; requiredFor = @('SG-Intune-AllDevices', 'SG-Sales'); availableFor = @(); uninstallFor = @('SG-Legacy') }
        [ordered]@{ appName = 'Contoso Line-of-Business Client (x64)'; wingetId = ''; appId = ''; requiredFor = @(); availableFor = @('SG-Finance'); uninstallFor = @() }
        [ordered]@{ appName = 'Company Portal'; wingetId = ''; appId = '0c1d2e3f-4a5b-4c6d-9e7f-8a9b0c1d2e3f'; intuneAppType = 'Microsoft Store app (new)'; intuneAppVersion = ''; requiredFor = @('SG-Intune-AllDevices'); availableFor = @(); uninstallFor = @() }
    )
    $i = 0
    foreach ($f in $fixtures) { $i++; [IO.File]::WriteAllText((Join-Path $appData "fixture-$i.json"), ($f | ConvertTo-Json -Depth 5)) }
    return $root
}

function Remove-AppSandbox {
    param([string]$Root)
    if ($Root -and $Root.StartsWith([IO.Path]::GetTempPath()) -and (Split-Path $Root -Leaf) -like 'intune-app-catalog-guitest-*') {
        for ($i = 0; $i -lt 5; $i++) {
            try { [IO.Directory]::Delete($Root, $true); return } catch { Start-Sleep -Milliseconds 500 }
        }
    }
}

function Start-AppUnderTest {
    <#
      Launches IntuneDeployment.ps1 from the sandbox under the given host
      and waits for the main window. Returns a context object used by
      every other helper here. -Script/-ScriptArguments run a different
      entry script from the sandbox instead (one that loads the app itself).
    #>
    param([string]$AppHost, [string]$Root, [int]$TimeoutSec = 90, [hashtable]$Environment = @{},
          [string]$Script = 'IntuneDeployment.ps1', [string[]]$ScriptArguments = @())
    $stdout = Join-Path $Root 'stdout.txt'
    $stderr = Join-Path $Root 'stderr.txt'
    $vars = @{ LOCALAPPDATA = (Join-Path $Root 'localappdata') } + $Environment
    $saved = @{}
    foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
    try {
        foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
        $p = Start-Process $AppHost -ArgumentList (@('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root $Script)) + $ScriptArguments) `
            -WorkingDirectory $Root -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    $ctx = [pscustomobject]@{ Process = $p; Pid = [uint32]$p.Id; Main = [IntPtr]::Zero; Root = $Root; StdErr = $stderr; AppData = (Join-Path $Root 'data\app-data'); Buttons = @{}; ShotDir = $null; ShotN = 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec -and -not $p.HasExited) {
        $m = $W32::TopLevel($ctx.Pid) | Where-Object { $W32::Text($_) -like 'Intune App Catalog*' } | Select-Object -First 1
        if ($m) { $ctx.Main = $m; break }
        Start-Sleep -Milliseconds 400
    }
    if ($ctx.Main -eq [IntPtr]::Zero) {
        if (-not $p.HasExited) { $p.Kill() }
        throw "Main window never appeared under $AppHost. stderr: $(Get-Content $stderr -Raw -ErrorAction SilentlyContinue)"
    }
    Start-Sleep -Seconds 4   # startup backfill / Shown handlers
    Update-AppButtons $ctx
    return $ctx
}

function Update-AppButtons {
    param($Ctx)
    $Ctx.Buttons = @{}
    foreach ($h in $W32::Children($Ctx.Main)) {
        if ($W32::Cls($h) -match 'BUTTON' -and $W32::IsWindowVisible($h)) {
            # Keyed by what the button READS as on screen, not by its raw
            # caption: an Alt-key mnemonic puts an '&' in the text
            # ("&Edit...") that is never drawn, and a test asks for the
            # button a user can see. '&&' is how a caption spells a literal
            # ampersand, so it collapses to one instead of disappearing.
            $sentinel = [string][char]1   # not "`u{...}": this file has to parse under Windows PowerShell 5.1 too
            $caption = ($W32::Text($h) -replace '&&', $sentinel) -replace '&', ''
            $Ctx.Buttons[($caption -replace $sentinel, '&')] = $h
        }
    }
}

function Stop-AppUnderTest {
    <# Closes the main window like a user would; returns $true if the process exited on its own. #>
    param($Ctx)
    if (-not $Ctx) { return $false }
    foreach ($d in Get-AppDialogs $Ctx) { $W32::Close($d) }
    Start-Sleep -Milliseconds 500
    $W32::Close($Ctx.Main)
    Start-Sleep -Seconds 2
    foreach ($d in Get-AppDialogs $Ctx) {
        # "Save changes?" (Yes/No/Cancel) -> No, don't save; a Yes/No "close anyway?" -> Yes
        $no = Get-ChildWindow $d 'No'
        $yes = Get-ChildWindow $d 'Yes'
        if ($no -and (Get-ChildWindow $d 'Cancel')) { $W32::Click($no) }
        elseif ($yes) { $W32::Click($yes) }
        else { $W32::Close($d) }
    }
    $clean = $Ctx.Process.WaitForExit(20000)
    if (-not $clean) { $Ctx.Process.Kill() }
    return $clean
}

function Get-AppStdErr { param($Ctx) (Get-Content $Ctx.StdErr -Raw -ErrorAction SilentlyContinue) }

# ---------------------------------------------------------------------------
# Windows, controls, dialogs
# ---------------------------------------------------------------------------
function Get-AppDialogs {
    # Visible top-level windows of the app other than the main one, that have a title (dialogs / message boxes).
    param($Ctx)
    @($W32::TopLevel($Ctx.Pid) | Where-Object { $_ -ne $Ctx.Main -and ($W32::Text($_) -or $W32::Cls($_) -eq '#32770') })
}

function Wait-AppDialog {
    param($Ctx, [string]$TitleLike = '*', [int]$TimeoutSec = 10)
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end) {
        $d = Get-AppDialogs $Ctx | Where-Object { $W32::Text($_) -like $TitleLike } | Select-Object -First 1
        if ($d) { Start-Sleep -Milliseconds 800; return $d }   # let it finish building
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Wait-NoAppDialogs {
    param($Ctx, [int]$TimeoutSec = 10)
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end -and (Get-AppDialogs $Ctx).Count) { Start-Sleep -Milliseconds 250 }
    return ((Get-AppDialogs $Ctx).Count -eq 0)
}

function Get-ChildWindow {
    # Child control by its visible text, ignoring & mnemonics ("&Yes" -> "Yes", "Save && Deploy" -> "Save & Deploy")
    param([IntPtr]$Parent, [string]$Text)
    $W32::Children($Parent) | Where-Object { (($W32::Text($_) -replace '&&', "`0") -replace '&', '' -replace "`0", '&') -eq $Text } | Select-Object -First 1
}

function Get-StaticText {
    # Message text of a MessageBox (its STATIC children)
    param([IntPtr]$Window)
    ((@($W32::Children($Window) | Where-Object { $W32::Cls($_) -match 'Static' } | ForEach-Object { $W32::Text($_) }) -join ' ') -replace '\s+', ' ').Trim()
}

function Get-EditBoxes {
    # Visible single-line text boxes, top to bottom then left to right
    param([IntPtr]$Parent)
    @($W32::Children($Parent) | Where-Object { $W32::Cls($_) -match '\.EDIT\.' -and $W32::IsWindowVisible($_) } | ForEach-Object {
        $r = New-Object GuiTest.W32+RECT; [void]$W32::GetWindowRect($_, [ref]$r)
        [pscustomobject]@{ Handle = $_; Top = $r.T; Left = $r.L }
    } | Sort-Object Top, Left | ForEach-Object Handle)
}

function Wait-Condition {
    # Polls $Condition until it's true or the timeout passes; returns the final answer.
    # CI runners are much slower than a dev box - never assert right after a fixed sleep.
    param([scriptblock]$Condition, [int]$TimeoutSec = 15)
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return [bool](& $Condition)
}

function Close-AppDialog {
    <#
      WM_CLOSE, then No/Cancel/Close/OK if the window refuses (Yes/No boxes).
      A dialog that's still running a step asks "Stop and close?" - that's
      answered Yes, since closing it is what the caller wants. A dialog that's
      still busy otherwise may refuse for a while - keep asking for up to
      $TimeoutSec. Returns how it closed.
    #>
    param([IntPtr]$Window, [int]$TimeoutSec = 20)
    $isOpen = { $W32::IsWindow($Window) -and $W32::IsWindowVisible($Window) }
    $end = (Get-Date).AddSeconds($TimeoutSec)
    $appPid = $W32::ProcessOf($Window)
    do {
        $W32::Close($Window)
        if (-not (Wait-Condition { -not (& $isOpen) } -TimeoutSec 2)) {
            $stopQuestion = $W32::TopLevel($appPid) | Where-Object { $W32::Cls($_) -eq '#32770' -and $W32::Text($_) -eq 'Stop and close?' } | Select-Object -First 1
            if ($stopQuestion) {
                $W32::Click((Get-ChildWindow $stopQuestion 'Yes'))
                if (Wait-Condition { -not (& $isOpen) } -TimeoutSec 3) { return 'closed after Stop and close? -> Yes' }
            }
            foreach ($label in 'No', 'Cancel', 'Close', 'OK') {
                $b = Get-ChildWindow $Window $label
                if ($b -and $W32::IsWindowEnabled($b)) {
                    $W32::Click($b)
                    if (Wait-Condition { -not (& $isOpen) } -TimeoutSec 2) { return "closed via $label" }
                }
            }
        }
        if (-not (& $isOpen)) { return 'closed' }
    } while ((Get-Date) -lt $end)
    return 'WOULD NOT CLOSE'
}

function Get-ControlOverlaps {
    <#
      Sibling controls (same parent) whose bounds intersect - a caption
      sitting on the border of the field under it, a grid running into a
      button below it, ... Containers (group boxes, panels) are skipped,
      since controls legitimately sit inside them. Returns one
      "a overlaps b by NxMpx" string per pair.
    #>
    param([IntPtr]$Window)
    $all = @($W32::Children($Window))
    $kids = @($all | Where-Object { $W32::IsWindowVisible($_) } | ForEach-Object {
        $h = $_
        $cls = $W32::Cls($h)
        $isGroupBox = $cls -match 'BUTTON' -and (($W32::GetWindowLong($h, -16) -band 0xF) -eq 7)   # BS_GROUPBOX
        $hasControls = @($all | Where-Object { $W32::GetParent($_) -eq $h -and $W32::Cls($_) -notmatch 'SCROLLBAR' }).Count -gt 0
        if ($isGroupBox -or ($hasControls -and $cls -notmatch 'COMBOBOX')) { return }
        $r = New-Object GuiTest.W32+RECT; [void]$W32::GetWindowRect($h, [ref]$r)
        $text = $W32::Text($h)
        $name = if ($text -and $text.Length -le 40) { "'$text'" } elseif ($text) { "'$($text.Substring(0, 37))...'" } else { $cls -replace '^WindowsForms10\.', '' -replace '\..*$', '' }
        [pscustomobject]@{ H = $h; Parent = $W32::GetParent($h); Name = $name; R = $r }
    })
    for ($i = 0; $i -lt $kids.Count; $i++) {
        for ($j = $i + 1; $j -lt $kids.Count; $j++) {
            $a = $kids[$i]; $b = $kids[$j]
            if ($a.Parent -ne $b.Parent) { continue }
            $ix = [Math]::Min($a.R.R, $b.R.R) - [Math]::Max($a.R.L, $b.R.L)
            $iy = [Math]::Min($a.R.B, $b.R.B) - [Math]::Max($a.R.T, $b.R.T)
            if ($ix -gt 0 -and $iy -gt 0) { "$($a.Name) overlaps $($b.Name) by ${ix}x${iy}px" }
        }
    }
}
function Save-AppShot {
    # Screenshot of a window into $Ctx.ShotDir (no-op when no -ShotDir was given)
    param($Ctx, [IntPtr]$Window, [string]$Name)
    if (-not $Ctx.ShotDir) { return }
    $Ctx.ShotN++
    $safe = (($Name -replace '[^\w\- ]', '').Trim()) -replace '\s+', '_'
    $r = New-Object GuiTest.W32+RECT; [void]$W32::GetWindowRect($Window, [ref]$r)
    if ($r.R -le $r.L -or $r.B -le $r.T) { return }
    $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void]$W32::PrintWindow($Window, $hdc, 2)   # PW_RENDERFULLCONTENT - works for windows behind others
    $g.ReleaseHdc($hdc); $g.Dispose()
    $bmp.Save((Join-Path $Ctx.ShotDir ('{0:D2}_{1}.png' -f $Ctx.ShotN, $safe)), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Watch-AppDialogs {
    <#
      After an action: waits for whatever window(s) it opens, closes each
      (following up on any window that opens in response), and returns
      one record per window seen.
    #>
    param($Ctx, [int]$TimeoutSec = 10)
    $seen = @()
    $end = (Get-Date).AddSeconds($TimeoutSec); $any = $false
    while ((Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 400
        $dlgs = Get-AppDialogs $Ctx
        if ($dlgs.Count) {
            $any = $true
            Start-Sleep -Milliseconds 1200
            foreach ($d in (Get-AppDialogs $Ctx)) {
                $title = $W32::Text($d)
                $text = Get-StaticText $d
                Save-AppShot $Ctx $d $title
                # only the app's own WinForms windows - not Windows' common dialogs (folder picker, ...)
                $overlaps = if ($W32::Cls($d) -like 'WindowsForms10.*') { @(Get-ControlOverlaps $d) } else { @() }
                $seen += [pscustomobject]@{ Title = $title; Text = $text; Overlaps = $overlaps; Closed = (Close-AppDialog $d) }
            }
            $end = (Get-Date).AddSeconds(3)
        }
        elseif ($any) { break }
    }
    return , $seen
}

# ---------------------------------------------------------------------------
# Main window: grid, search, "More actions..." menu
# ---------------------------------------------------------------------------
function Get-AppGrid {
    param($Ctx)
    $r = New-Object GuiTest.W32+RECT; [void]$W32::GetWindowRect($Ctx.Main, [ref]$r)
    $W32::Deepest($Ctx.Main, [int](($r.L + $r.R) / 2), [int]($r.B - 150))
}

function Select-OnlyGridRow {
    <# Filters the grid via the search box, then clicks its first row. #>
    param($Ctx, [string]$Filter)
    $search = (Get-EditBoxes $Ctx.Main)[0]
    $W32::SetText($search, $Filter)
    Start-Sleep -Milliseconds 800
    $grid = Get-AppGrid $Ctx
    $r = New-Object GuiTest.W32+RECT; [void]$W32::GetWindowRect($grid, [ref]$r)
    $W32::ClickAt($grid, $r.L + 60, $r.T + 36)   # below the header row
    Start-Sleep -Milliseconds 500
}

function Clear-GridFilter {
    param($Ctx)
    $W32::SetText((Get-EditBoxes $Ctx.Main)[0], '')
    Start-Sleep -Milliseconds 600
}

function Get-MenuDrops {
    param($Ctx)
    @($W32::TopLevel($Ctx.Pid) | Where-Object { $_ -ne $Ctx.Main -and -not $W32::Text($_) -and $W32::Cls($_) -like 'WindowsForms10.Window*' })
}

function Close-AppMenus {
    param($Ctx)
    for ($i = 0; $i -lt 4 -and (Get-MenuDrops $Ctx).Count; $i++) {
        foreach ($d in Get-MenuDrops $Ctx) { $W32::Escape($d) }
        Start-Sleep -Milliseconds 300
    }
}

function Wait-MenuItems {
    # Polls until a dropdown other than $Exclude is open and lists its items (menus open asynchronously).
    param($Ctx, [IntPtr]$Exclude = [IntPtr]::Zero, [int]$TimeoutSec = 5)
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 250
        $drop = Get-MenuDrops $Ctx | Where-Object { $_ -ne $Exclude } | Select-Object -First 1
        if (-not $drop) { continue }
        $items = @([GuiTest.Msaa]::MenuItems($drop) | Where-Object { $_.Name } | ForEach-Object { [pscustomobject]@{ Drop = $drop; Name = $_.Name; Enabled = $_.Enabled; X = $_.X; Y = $_.Y } })
        if ($items.Count) { Start-Sleep -Milliseconds 150; return $items }
    }
    return @()
}

function Open-MoreActionsMenu {
    <# Opens "More actions..." (and optionally one submenu); returns the items of the innermost open menu. #>
    param($Ctx, [string]$Submenu)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Close-AppMenus $Ctx
        $W32::Click($Ctx.Buttons['More actions...'])
        $items = @(Wait-MenuItems $Ctx)
        if (-not $items) { continue }
        if (-not $Submenu) { return $items }
        $sub = $items | Where-Object Name -eq $Submenu | Select-Object -First 1
        if (-not $sub) { return @() }
        $W32::ClickAt($sub.Drop, $sub.X, $sub.Y)
        $inner = @(Wait-MenuItems $Ctx -Exclude $sub.Drop)
        if ($inner) { return $inner }
    }
    return @()
}

function Invoke-MoreActionsItem {
    param($Ctx, [string]$Submenu, [string]$Item)
    $it = Open-MoreActionsMenu $Ctx $Submenu | Where-Object Name -eq $Item | Select-Object -First 1
    if (-not $it) { Close-AppMenus $Ctx; throw "Menu item 'More actions... > $Submenu > $Item' not found" }
    if (-not $it.Enabled) { Close-AppMenus $Ctx; return $false }
    $W32::ClickAt($it.Drop, $it.X, $it.Y)
    return $true
}

# ---------------------------------------------------------------------------
# Catalog files
# ---------------------------------------------------------------------------
function Get-CatalogEntries {
    param($Ctx, [string]$AppName)
    # The app rewrites the catalog while saving - a file can vanish between
    # listing and reading; callers poll, so just skip it this time.
    @(Get-ChildItem $Ctx.AppData -Filter *.json | ForEach-Object {
        try { $j = [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json } catch { return }
        if ($j.appName -eq $AppName) { $j }
    })
}
