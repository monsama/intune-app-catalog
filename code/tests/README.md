# Tests

`CatalogLogic.Tests.ps1` is a small, framework-free test suite for the
handful of **pure, side-effect-free** functions in
`IntuneDeployment.ps1` - the ones with no WinForms dependency and no
live Microsoft Graph call, so they can actually run headless (including in
CI, or any Linux box with PowerShell 7+ - no Windows needed for this part).

Run it with:

```
pwsh -NoProfile -File code/tests/CatalogLogic.Tests.ps1
```

It extracts the functions under test directly from the real script's AST
(never a hand-copied duplicate), so it can't silently drift from what
actually ships - if a targeted function's signature changes incompatibly,
these tests fail loudly instead of quietly testing a stale copy. It also
parses the whole main script first and fails immediately if that has a
syntax error.

## What this does NOT cover

This is deliberately narrow, and a green run here is **not** proof the app
works end to end. Almost everything in this app lives outside what's tested
here:

- **The GUI itself** - every dialog, button handler, and closure is
  WinForms, which isn't even available outside Windows. Testing that would
  need a Windows UI-automation framework (e.g. FlaUI) driving the actual
  compiled app - a real project of its own, and a fragile one for a
  hand-built, closure-heavy single-file app like this where a harmless
  layout tweak can break automation that isn't testing logic at all.
- **Every live Microsoft Graph / Intune call** - creating, updating, or
  deleting a Win32 app, assigning groups, fetching current metadata, all of
  it. Testing that for real means real API calls against a real tenant.
  That's only safe against a **dedicated sandbox tenant**, never
  production, and needs its own credential handling and teardown-on-failure
  logic to avoid leaving orphaned test apps behind. Not attempted here.

If you're looking for confidence that "create 3 test apps and exercise
every error path" actually works, that's the second category above - a
real integration-test investment, not something this suite does.

## Adding a new pure function to this suite

Only add a function to `$testableFunctionNames` in the test file if it
has **no** WinForms control references and **no** live Graph/network call in
it. If it touches `$Script:Apps` or similar script-scoped state (like
`Get-DefaultAppMetadata` does), stub that state in the test file before
calling it, same as the existing tests do.
