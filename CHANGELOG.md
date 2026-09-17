# Changelog

## 1.3

### Installation status of an app

Right-click an app in the catalog and choose **Installation status...** to
see what Intune reports about it, per device: the device, its user, the
state, the error code of a failure (in red, with the searchable hex form),
the version and when it was last reported. **Failed only** filters the
list, **Copy list** puts it on the clipboard, and **Refresh** asks Intune
again. Read-only - nothing here changes Intune or the catalog.

The numbers come from Intune's reporting pipeline, the same one behind the
portal's own "Device install status" view, so a very recent install or
failure takes a while to appear. It reads the report endpoint the portal
uses, and falls back to the older `deviceStatuses` endpoint if a tenant
doesn't answer on it. Needs `DeviceManagementApps.Read.All`, which the app
registration already has.

## 1.2

### See what the app does in Intune

The dialog log boxes and the **Log** tab now show what the app sends to
Microsoft Graph and which programs it runs:

| Line | Meaning |
|---|---|
| `[GRAPH] PATCH /beta/deviceAppManagement/mobileApps/… -> OK (310 ms)` | A change in Intune or Entra ID (create, update, assign, delete). Always shown. |
| `[GRAPH] Intune app lookup: 12 read request(s) (1.4 s)` | Reads, summed up per step. |
| `[GRAPH] GET /v1.0/groups/… -> FAILED (95 ms): … (request-id …)` | A failed request, in red, with Graph's request-id - what Microsoft support asks for. Always shown. |
| `[RUN] winget search "7zip" -> 12 result(s) (2.3 s)` | A program the app ran (winget search, IntuneWinAppUtil). A failed packaging run also shows the tool's last output lines. |

- **Detailed Graph log** (Log tab) shows every read request on its own line
  instead of a summary.
- Lookups started from a dialog (Diagnostics, Group manager, App editor,
  Deploy to Intune) show their lines in that dialog's log box too.
- Only the method, address and outcome are logged - never tokens, headers,
  request contents, or the upload address of a package.
- The Log tab has **Copy log**, **Save log...** and **Open log folder**
  (`data\logs`, one file per day).

### Questions that say what they do

- Questions that delete or replace something (catalog entries, apps and
  assignments in Intune, groups, certificates, package content) now have
  **No** as the default button - pressing Enter no longer confirms them.
- **"Stop and close?"** is asked however a running dialog is closed - Close,
  Esc, the window's X or Alt+F4 - and **No** really keeps it open (before,
  the Close button closed the dialog even after No, and X didn't ask).
  Closing the Intune audit just stops it, since it only reads.
- The **app editor** asks before discarding any unsaved change (Cancel,
  Previous/Next app, X), not only for a deployed but unsaved new app.
- Closing the main window or **Settings** with unsaved changes offers
  **Save / Don't save / Cancel**. **Open other folder...** asks before
  discarding unsaved catalog changes, like **Reload** does.
- Clearer questions: app names instead of App IDs for duplicates, which
  catalog apps use a group before it's deleted or renamed, a warning when a
  local certificate is the one the app signs in with, what Yes changes when
  a dependency blocks a delete. Double questions were merged (last
  certificate, typing DELETE in bulk delete).
- If a duplicate warning during another action is answered with No, the
  Log tab says the change wasn't saved.

### Fixes

- **Batch edit Intune fields**: an empty Dependencies list now removes the
  apps' dependencies (it was listed in the question but skipped). Empty
  Return codes set Intune's standard codes, in the catalog as well.
- **Push groups to Intune (multiple apps)** no longer offers to add a group
  when the apps have no App ID (that led back to the same question).
- Packaging could hang when IntuneWinAppUtil wrote a lot of output.
- The app's runtime `data\` folder is no longer tracked by git.

### Tests

- New GUI test `CloseConfirmation.GuiTests.ps1` for "Stop and close?", and
  the editor's "Discard changes?" in `CatalogCrud.GuiTests.ps1`.
- [docs/tenant-test-checklist.md](docs/tenant-test-checklist.md) lists what
  still needs a real test tenant.
