# Changelog

## 1.3.1

- **"Save changes?" no longer comes back over and over.** The question was
  asked without owning the window behind it, so every further Close or Esc
  stacked another copy of it, and answering Yes with an empty Tenant ID,
  Client ID or thumbprint left the window open with nothing to click. The
  question now blocks its own window, and when the settings can't be saved
  it says why and offers to close and lose the changes. The same ownership
  fix applies to the app editor, the favorite groups manager, the main
  window and every dialog that asks before closing.
- **The first-time setup guide is now a separate window**, opened beside
  Settings instead of on top of it, so the steps can be read while the
  fields are filled in. It closes with Settings.
- **Install status** works again: the report Intune builds needs `select`
  and `orderBy` in the request, and without them every lookup came back as
  BadRequest.
- **Batch edit Intune fields** is laid out in three columns – the apps, the
  requirements and install behaviour, and the description and commands –
  with each text field's label above its box, instead of one very tall
  column.

## 1.3

### Fixes from a live tenant

- **Install time required** is now kept in the 5-minute steps Intune
  actually stores. Entering 61 used to be sent as 61 while Intune kept 60,
  so the catalog and Intune disagreed for ever and the audit reported that
  difference on every run. The field snaps as you leave it (61 -> 60,
  64 -> 65), and is capped at Intune's maximum of 1440 minutes.
- **Deploy to Intune stays open after a successful run**, so the log box
  can still be read – the success popup's OK used to close the whole
  window. The action buttons are disabled afterwards and Cancel becomes
  Close; closing still saves to the catalog exactly as before.
- The app editor's **Excluded from** list was built but never added to the
  window, so exclusions couldn't be seen or changed.

### Templates, and a Deploy dialog that doesn't wait

- Right-click apps > **Clear App ID...** forgets which Intune app an entry
  belongs to (Intune itself is untouched), and **Save as template...**
  copies the selection to a folder without App IDs, so the same
  configuration deploys as new apps – in another tenant, or this one.
- **Check Intune when opening Deploy** (toolbar, Sync box, on by default):
  turn it off and "Deploy to Intune" opens immediately with what's saved
  here, offers **Refresh from Intune**, and checks Intune automatically
  right before an update is sent – the moment where a stale value could
  actually overwrite a newer one. Drift is shown there, field by field,
  before the update continues.
- **Batch edit Intune fields...** can now also change description,
  publisher, owner, developer, information and privacy URL, notes, install
  and uninstall command and install context, and has a **Catalog only**
  mode that contacts Intune not at all – so apps that were never deployed
  can be bulk-edited too.

### Excluded groups

An app can now carry an **Excluded from** list next to Required, Available
and Uninstall: those groups never get the app, whichever list would
otherwise have covered them ("everyone in Sales except contractors").
Before, exclusions had to be set in the portal – and the next push from
here wiped them.

The preview shows exclusions as their own lines, and a target the catalog
can't express (All devices, All users) is now listed as "WILL BE REMOVED"
instead of disappearing without a word.

### Winget package check

**More actions... > Verify > Winget package check...** asks winget on your
machine whether each catalog app's Winget ID still exists. A renamed or
dropped ID keeps working on devices that already have the app, but fails
to install on every new one, which otherwise only surfaces as install
failures much later. Versions aren't compared on purpose: the deployed
install command takes whatever Winget ships at install time, and the
generated detection rule matches the package ID, not a version.

### Platform scripts

**More actions... > Intune > Platform scripts...** lists the PowerShell
scripts Intune runs on enrolled Windows devices, and lets you add, change
and delete them without the portal: paste a script or load a `.ps1`, set
the name, description and file name, choose whether it runs as the system
account or the signed-in user, in 32-bit, and whether a signature is
required, then tick the groups that get it.

Saving replaces that script's assignments in Intune with exactly the
groups ticked, and says so before it does. Changing a script makes Intune
run it again on devices that already had it. Needs
`DeviceManagementScripts.ReadWrite.All` as an application permission
(the older `DeviceManagementConfiguration.ReadWrite.All` also works), plus
the `Group.Read.All` the app already uses to resolve group names.

Each script's **Run status...** shows how it actually went per device -
Intune's own state, its result message, the error of a failure and when it
last ran.

### Installation status of an app

Right-click an app in the catalog and choose **Installation status...** to
see what Intune reports about it, per device: the device, its user, the
state, the error code of a failure (in red, with the searchable hex form),
the version and when it was last reported. **Failed only** filters the
list, **Copy list** puts it on the clipboard, and **Refresh** asks Intune
again. Read-only – nothing here changes Intune or the catalog.

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
| `[GRAPH] GET /v1.0/groups/… -> FAILED (95 ms): … (request-id …)` | A failed request, in red, with Graph's request-id – what Microsoft support asks for. Always shown. |
| `[RUN] winget search "7zip" -> 12 result(s) (2.3 s)` | A program the app ran (winget search, IntuneWinAppUtil). A failed packaging run also shows the tool's last output lines. |

- **Detailed Graph log** (Log tab) shows every read request on its own line
  instead of a summary.
- Lookups started from a dialog (Diagnostics, Group manager, App editor,
  Deploy to Intune) show their lines in that dialog's log box too.
- Only the method, address and outcome are logged – never tokens, headers,
  request contents, or the upload address of a package.
- The Log tab has **Copy log**, **Save log...** and **Open log folder**
  (`data\logs`, one file per day).

### Questions that say what they do

- Questions that delete or replace something (catalog entries, apps and
  assignments in Intune, groups, certificates, package content) now have
  **No** as the default button – pressing Enter no longer confirms them.
- **"Stop and close?"** is asked however a running dialog is closed – Close,
  Esc, the window's X or Alt+F4 – and **No** really keeps it open (before,
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
