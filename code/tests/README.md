# Tests

`CatalogLogic.Tests.ps1` is a small, framework-free test suite for the
handful of **pure, side-effect-free** functions in
`IntuneDeployment.ps1` – the ones with no WinForms dependency and no
live Microsoft Graph call, so they can actually run headless (including in
CI, or any Linux box with PowerShell 7+ – no Windows needed for this part).

Run it with:

```
pwsh -NoProfile -File code/tests/CatalogLogic.Tests.ps1
```

It extracts the functions under test directly from the real script's AST
(never a hand-copied duplicate), so it can't silently drift from what
actually ships – if a targeted function's signature changes incompatibly,
these tests fail loudly instead of quietly testing a stale copy. It also
parses the whole main script first and fails immediately if that has a
syntax error.

## What this does NOT cover

This is deliberately narrow, and a green run here is **not** proof the app
works end to end. Almost everything in this app lives outside what's tested
here:

- **The GUI itself** – every dialog, button handler, and closure is
  WinForms, which isn't even available outside Windows. That part is what
  the separate GUI tests below are for.
- **Every live Microsoft Graph / Intune call** – creating, updating, or
  deleting a Win32 app, assigning groups, fetching current metadata, all of
  it. Testing that for real means real API calls against a real tenant.
  That's only safe against a **dedicated sandbox tenant**, never
  production, and needs its own credential handling and teardown-on-failure
  logic to avoid leaving orphaned test apps behind. Not attempted here.

If you're looking for confidence that "create 3 test apps and exercise
every error path" actually works, that's the second category above – a
real integration-test investment, not something this suite does.

## Adding a new pure function to this suite

Only add a function to `$testableFunctionNames` in the test file if it
has **no** WinForms control references and **no** live Graph/network call in
it. If it touches `$Script:Apps` or similar script-scoped state (like
`Get-DefaultAppMetadata` does), stub that state in the test file before
calling it, same as the existing tests do.

## GUI tests (Windows only)

`gui\` drives the **real app** – the same `IntuneDeployment.ps1` you'd run -
by posting Win32 clicks and text to its windows, and checks what happens on
screen and on disk. It needs an interactive Windows desktop session; windows
pop up and close by themselves while it runs, so don't type or click into
them.

```
pwsh -NoProfile -File code/tests/gui/DialogSmoke.GuiTests.ps1
pwsh -NoProfile -File code/tests/gui/CatalogCrud.GuiTests.ps1
pwsh -NoProfile -File code/tests/gui/CloseConfirmation.GuiTests.ps1
pwsh -NoProfile -File code/tests/gui/DialogLayout.GuiTests.ps1
```

Both run the app under **both** PowerShell 7 and Windows PowerShell 5.1 by
default (`-AppHost pwsh` or `-AppHost powershell` for just one), and work
when launched from either. `-ShotDir <folder>` saves a screenshot of every
window they open – handy for comparing the two hosts side by side.

- `DialogSmoke.GuiTests.ps1` – opens every toolbar button and every
  "More actions..." item and closes whatever appears; fails on a crash, any
  stderr output, a window that won't close, or two sibling controls that
  overlap (a caption sitting on its field's border, a grid running into a
  button). Also checks that every main-grid column header fits its text
  (PowerShell 7 host only – .NET Framework doesn't expose that grid to UI
  Automation) and that the toolbar wraps in a narrow window. Skips
  "Package apps" and every Delete/Remove action.
- `CatalogCrud.GuiTests.ps1` – adds, edits, renames, and removes catalog
  apps through the real dialogs (main window and editor paths, Yes and No
  answers, empty-name validation, the editor's "Discard changes?" question)
  and checks the per-app JSON files after every step.
- `CloseConfirmation.GuiTests.ps1` – the "Stop and close?" question of the
  dialogs that run a step in a child process. Those need a Graph connection
  before they start anything, so it drives a stand-in
  (`CloseConfirmationHarness.ps1`) wired the same way – the real
  `Register-CloseConfirmation`, Close as the CancelButton, a real sleeping
  child process – and checks that Close and X both ask, No is the default
  and keeps the dialog and the step running, Yes stops the step, and
  nothing is asked once nothing runs.
- `DialogLayout.GuiTests.ps1` – opens **every** dialog (via
  `DialogLayoutHarness.ps1`, which runs inside the app process) with sample
  data, including deliberately long app and group names, and measures each
  visible control's text against the space it has. Fails on text that's cut
  off or hidden, list entries wider than a list without a scrollbar, grid
  headers too narrow for their text, controls running past their container,
  and overlapping controls – one assertion per window. Takes a few minutes
  per host; `-ShotDir` keeps a screenshot of every window, and
  `-Screen 1024x768` checks the small-screen case on a big monitor (every
  dialog must fit the screen – oversized ones scroll instead).
- `Prerequisites.GuiTests.ps1` – **needs internet.** Clicks *Install missing*
  in the Prerequisites dialog and follows it through: the download, the live
  log, the status re-check, and Graph actions getting past the module check
  afterwards. The module is saved into the sandbox (the app's
  `INTUNEPACKAGER_TEST_MODULE_DIR` test hook), never into your profile, and
  a host where the module is already installed for real is skipped. Kept
  separate so the other two stay offline. (Windows PowerShell's package
  tooling creates an empty `%LOCALAPPDATA%\PackageManagement` in the *real*
  profile regardless of the redirect below; the test removes it again if it
  wasn't there before.)

**Safe by construction:** each run copies the app into a throwaway temp
folder with its own fixture catalog and **no settings file**, so no Graph
credentials exist – every Intune/Entra action stops at its own "not
configured" / "module missing" guard. The app's `LOCALAPPDATA` is pointed
into that folder too (the app clears the Microsoft Graph PowerShell sign-in
cache there on exit). The repo's own `data\` folder is never touched, and
the temp folder is deleted afterwards. Test apps never get an App ID, and
the editor's delete button is only confirmed when its prompt says it just
removes the local entry.

`gui\GuiTestDriver.ps1` holds the shared plumbing (dot-source it). Clicks
are always *posted*, never sent through a synchronous UI Automation
Invoke – a synchronous Invoke on a button that opens a modal dialog never
returns and hangs every later automation call.