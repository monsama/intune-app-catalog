# Changelog

## 1.4.5

### Fixes

- **Deleting a script that only exists locally asked Intune to delete
  it.** A local-only script has no Intune id because it is a file, so
  the request went out with no id at all and Graph answered "No OData
  route exists that match template ~/singleton/navigation with http verb
  DELETE" - true, and no help at all. Delete now recognises which it is:
  a local-only script is a file, named and removed, with nothing sent to
  Intune.
- **"Run status..." had the same hole** - it asks Intune how a script ran
  on each device, which for one that has never been there is the same
  empty request. It is disabled for local-only rows.
- Deleting a script that IS in Intune now says what happens to its local
  copy: it stays until the next "Save local copies".

## 1.4.4

### Fixes

- **"Save local copies" hung, and could have deleted your local copies.**
  Two separate faults. The save unrolled a generic list with `@(...)`,
  which throws "Argument types do not match"; nothing caught it, so the
  exception escaped the timer driving the save and the dialog sat on
  "Reading 'x' (1 of 1)..." with no error and no way forward. And the
  save *prunes* - the folder is the catalog, so files not in the set are
  removed - which meant a failed read would have deleted the local copy
  it had just failed to read. It now prunes only when every script was
  read, and says so when it doesn't.
- **A logging failure could take the app down with it.** A dialog's log
  box arriving empty threw "The property 'SelectionStart' cannot be found
  on this object" at the user, and took the message it was carrying with
  it. Logging now falls back to the main log instead of throwing - and
  the fallback cannot throw either.
- **The package path set in the editor was never saved.** The catalog
  writes its JSON field by field, and that field was not in the list, so
  it read back, showed in the editor and vanished on save. The catalog
  table also ignored it for any app with a Winget ID.
- **"Catalog groups: N not found" counted every group, not the missing
  ones** - a red finding for a catalog with nothing wrong with it.
- **Packages you placed by hand were reported as orphans.** The check
  matched folder names derived from the app and knew nothing about a
  package path you had set.

### The editor fills in what it can

- **The app's name now fills the display name** on the Metadata tab, and
  a Winget ID entered after the fact fills the install command,
  uninstall command and detection script. Both are built before "Add
  app..." has anything to build them from, so both used to stay blank.
  Either stops following the moment you make it deliberately different.

### Plainer answers

- **Checks says what it found**, not just that it finished: "3 app(s)
  differ", "2 group name(s) don't exist in Entra ID - those assignments
  reach nobody". Findings carry their consequence, because a count on its
  own does not tell you whether it matters today.
- **Nothing runs until asked.** Opening a tab used to start its check, so
  clicking along the strip fired off four of them. Every tab has its own
  button, and says "Not checked yet" until it has actually run - an empty
  grid reads as "nothing wrong" to anyone who did not watch it start.
- **The long checks can be stopped** - winget, Sync check and the Audit.
  What was already done is kept.
- **One "New script..."**, with "Save locally" beside "Create in Intune"
  in the editor, rather than two buttons that opened the same editor and
  differed only in where the result went.

### While in there

Platform scripts and Prerequisites moved onto the toolbar; "Look up App
IDs...", "Open other folder..." and the Verify submenu left it. Check
tabs run broad to deep. Dismiss buttons are one height throughout, the
progress bars have room around them, four file pickers open somewhere
sensible rather than wherever Windows last was, and eight buttons whose
consequence was not in their label gained a tooltip. Favorites are
"groups or users", which they always were.

### For maintainers

`GraphContract.Tests.ps1` checks the 57 Graph properties this app depends
on against Microsoft's published `$metadata`, weekly and on demand, so a
rename is news from CI rather than from a failed deployment. It catches
removals and renames; a property Graph still declares but no longer
accepts is beyond it, and the manifest says so.

## 1.4.3

### Fixes

- **"Save local copies" hung on the first platform script.** It read the
  script, its assignments and its groups, and then stopped: no save, no
  error, the status line still mid-sentence. The callback that advances
  to the next script is nested inside another callback, and reached for
  the queue without taking the local alias this codebase needs at that
  depth - so it advanced nothing, and the collection it had been adding
  each script to was not the real one either.
- **A Winget ID entered after "Add app..." left Package and detection
  blank.** Those tabs are built the moment the editor opens, when the
  Winget field is still empty, so they were built for an app with no
  Winget ID - no install command, no uninstall command, no detection
  script, and nothing that would ever fill them. Naming the ID now
  regenerates them, whether it was typed or picked with "Search
  winget...", along with the package path pointing at the shared
  init.intunewin. Anything typed by hand is left alone.
- **"Set default values" cut off every line it listed.** The list could
  not scroll sideways (the scrollbar it carried was never given anything
  to scroll) and had no tooltip either, so the right-hand end of each
  line was simply unreachable. It wraps now, and can be selected and
  copied.
- **Test connection called a feature available when it was not.** A
  registration with only `DeviceManagementScripts.Read.All` was told
  "Platform scripts: yes" - it can list them and gets a 403 on the first
  save. Reading and changing are separate rows now, and `Group.Read.All`
  gets the same treatment: it finds a group, it cannot assign an app to
  one.

### Fewer places to look

- **Intune sync check** is the eighth tab of the Checks window rather
  than a window of its own, and **Look up App IDs...** has gone from the
  menu - it already did nothing but run the lookup and open that same
  window on its App IDs tab.
- **Platform scripts** sits beside Checks on the toolbar, and
  **Prerequisites** beside Settings, where it belongs: it installs the
  missing Graph module rather than reporting on anything. The "Verify"
  submenu held only that, so it is gone.
- **Open other folder...** has gone from the menu too - Settings >
  Folders > Catalog does the same job and shows you where the folder
  currently is. Switching catalogs there now asks before discarding
  unsaved changes, which the menu entry always did and this path did not.
- Catalog maintenance is in alphabetical order.

### While in there

The Checks window no longer describes its tabs as read-only, because
three of them write: Metadata sync, App IDs and the new Sync check. Enter
no longer dismisses it either - fine on a window that only reports, a way
to lose your place on one with per-row action buttons. Esc still closes.
In the app editor, "Push groups to Intune" is the same width as "Pull
groups from Intune" above it.

## 1.4.2

### Where this app keeps things

**Settings... > Folders** lets each folder this app writes to be pointed
somewhere else: the catalog, built packages, the shared Winget package,
the packaging tool, platform script copies, logs and catalog backups.
They were all built as `data\<something>` next to the app, at ten call
sites, with no way to move any of them - which is wrong in both
directions on a machine where the app lives under Program Files, or where
the catalog belongs on a share and the logs do not. Leave a box empty and
that folder follows its default, including if a later version moves it -
and an empty box shows that default greyed inside it, so every row says
where it is actually writing rather than saying nothing at all.

### The suite brings its own packaging

The two files needed before anything can be packaged have never shipped
with this app, and neither had a button:

- **Download packaging tool** fetches Microsoft's Win32 Content Prep Tool.
  It used to download itself silently the first time packaging ran, which
  is fine until the machine has no internet at the moment you press
  Package.
- **Build init.intunewin** makes the one package every Winget app deploys
  with. A missing one failed every Winget app with "Package missing" and
  nothing offered to fix it. **Deploy** now offers to build it - and to
  fetch the tool first if that is missing too - at the moment a Winget app
  finds it gone. Batch Deploy says where the fix is instead of listing
  every common app as "package not built yet".

### Edit default values says what each field shipped as

The page showed the values in force but never what they started from, so
the only way back from one changed field was **Reset to built-in
defaults**, which threw away the other eleven as well. Anything that
differs from the shipped value now carries a **built-in: x64** link that
puts back just that one field. Requirements moved from four boxes across
one row to two rows of two to make room, and the return-codes table fills
its own width instead of sitting in the left half of it.

### Fixes

- **The Settings window hid its last folder row and wasted 86px under the
  buttons.** Its log sat 60px too high, painting over the bottom of the
  tab page below it. Both were the same mistake, measured from the top of
  a window whose height is fixed by the smallest screen it has to fit.
- **On a smaller screen, Checks drew "Sync selected" on top of its own
  log.** 1.4.1 claimed to have fixed this and had not: a dialog that
  becomes a tab was having anything near its bottom edge re-anchored to
  the bottom of the page, and a page can be shorter than the dialog it
  came from - a tab strip costs height, and twice that once the captions
  wrap. A bottom-anchored button on a short page does not scroll into
  view, it rides up over what is above it. Tabs keep the vertical layout
  they were built with now, and a page that wants its content to fill the
  height says which control that is.
- The Metadata sync tab ended in empty space, because it was the one page
  in that window that never named its content control.

## 1.4.1

### Fixes for 1.4.0

- **On a 1024x768 screen, "Check against Intune" drew its metadata log on
  top of the Sync selected button.** That window is 1320 wide and is
  shrunk to fit a smaller screen, and 1.4.0's tidy-up of window margins
  took 14px it could not spare. It keeps its own margins again.
- **"Check Intune when opening Deploy" did nothing when Deploy was opened
  from the app editor**, which is the usual way in since 1.3.3 made an app
  one window. It armed itself on the deploy dialog, and that dialog is no
  longer the window that opens - the editor is.
- **"Refresh from Intune" could not be reached from the app editor at
  all.** It was only ever revealed by the same handler above, so it stayed
  hidden. It is always available now: wanting to re-read an app after
  someone else has touched it has nothing to do with whether the automatic
  check is switched on.

### While in there

The app editor names the app it is editing - **Edit app - 7-Zip** - and
follows renames as you type. Five tabs in, nothing else on screen said
which app you had open. It is also 51px taller, so the Assignments tab
stops scrolling for its last group, and **Refresh from Intune** and
**Compare** sit beside the status text they act on instead of above the
buttons that close the window.

## 1.4.0

### The catalog grid keeps your place

Clicking a column header sorts by it, and clicking it again reverses it.
It never did before: the grid is bound to a plain list, which cannot sort
itself, so the click did nothing at all. The rows are ordered before they
are bound instead, which is also what makes the order survive everything
below.

That matters because the grid is thrown away and rebuilt constantly - on
every save, deploy, sync, and on every keystroke in the search box.
Everything it knew went with it, so after a deploy you were back at the
top with nothing selected. Your selection and your scroll position come
back now, and the selection is remembered by app **name**, not by row or
catalog index, because those shift when an app is added, removed or
sorted.

The one case where a selection cannot come back is an app the current
filter hides. Binding a list selects the first row by itself, so that is
cleared deliberately - otherwise the selection lands on whichever app
happens to sort first, and the next Deploy acts on **that** one.

Sort column, direction and column widths survive a restart, and the
window comes back where it was left. A saved position is used only if it
still lands on a monitor attached right now: undock a laptop and
yesterday's coordinates put the window somewhere unreachable, which looks
exactly like the app failing to start.

### Typing in the search box is not a workout

Every character rebuilt the whole grid, and a rebuild walks
`data\app-packages` recursively for every app with no Winget ID, hunting
its `.intunewin`. A four-letter filter meant four full rebuilds and dozens
of directory walks, felt as the box lagging behind the typing. It waits
250ms for typing to stop now. **Esc** clears the filter.

The status bar said "120 apps" above a grid showing three of them - the
one moment that number is worth reading, and the one moment it was wrong.
It says "Showing 3 of 120 apps" while a filter is on.

Two other things in that same path: working out an app's default metadata
scanned the whole catalog once per configured default dependency, once
per app, on every refresh (333ms to 70ms over 200 apps), and the status
bar's three assignment totals were three separate walks where one does
(29ms to 9ms).

### Every check in one window

Dependencies, catalog groups against Entra ID, Winget IDs and this app's
own diagnostics were four menu entries and four windows, with nothing to
tell you from the outside which one answers the question you have. They
are tabs of **Checks** now.

A tab's check runs when you open that tab, never all four when the window
opens - two of them cost real time. **Run all checks** is there for "is
anything wrong?", and runs them strictly one at a time, because a second
concurrent directory lookup is refused outright and would report a
failure that isn't real. A full run also reads the tenant's groups and
users **once** rather than twice, since two of those checks each read the
whole directory.

### Enter is no longer the answer to "are you sure?"

Twelve confirmations focused **Yes**, so Enter confirmed them - including
several that follow a click which already armed the action, where the
Enter confirming the first thing carried into the second. Saving a
catalog with duplicate App IDs, deploying through a circular dependency,
"Also remove these from the local catalog entirely?" after an Intune
delete, clearing a stale App ID, renaming a group in Entra ID, uploading
a certificate: all default to **No** now. A prompt that only offers a next
step, like batch assign's "Add a favorite group now?", still does not.

### The toolbar says what it is

Nine buttons sat under one box titled "Get started" while doing three
different jobs. They are **Catalog**, **Intune** and **Setup** now, and
the primary nine have Alt-key shortcuts. The three checkboxes that lived
between them are persistent settings, so they moved to Settings' new
**Automatic checks** tab, leaving the toolbar as actions only.

Also in the main window: **Ctrl+F** goes to the search box, **F5**
reloads, and an empty catalog explains what a catalog is and offers the
three ways forward, instead of showing a blank grid and "0 apps".

### Windows that use the window

The app editor and Deploy were a narrow column in a wide window: fields
stopping a third short of the right edge, and group lists so narrow that
`SG-Intune-Win32-Required-Production-AllManagedDevices-EMEA` clipped
mid-word. Everything ends at one right edge now, and those lists are more
than twice as wide.

The status line and the "bold blue label" legend sat in a bordered box
stacked above the log - two blocks above the buttons, both dark in the
dark theme, the upper one usually empty and reading as a second log that
never fills. They are plain lines above the log now, which is the one
block down there. The actions sit on a single row measured from the
window's own edges, so **Update Metadata** joins Cancel on the right
instead of floating on a line of its own above a 440px gap.

### Platform scripts have a local catalog too

The apps have always been a folder of files you can keep in git. The
platform scripts now are as well: **Save local copies** writes what the
tenant has into `data\script-data`, the same shape the apps use.

And it goes both ways. **New local script...** writes one locally without
sending anything anywhere, for preparing it before it goes live. It then
appears in the list as **Local only**, alongside the tenant's own scripts,
because a local script you cannot see is a local script you will forget to
push. Edit opens it straight from its file, and saving creates it in
Intune. A script deleted from the tenant but still in the catalog shows up
the same way, rather than vanishing from view while its file stays on
disk.

### Under the hood

`GridBehavior.GuiTests.ps1` is new: it drives the real grid with the real
`Update-Grid` over a fixture catalog and checks the sort order, the
selection and the scroll position a rebuild has to put back. It caught a
real bug in that rebuild before it shipped, and it runs in CI beside the
other four GUI suites.

## 1.3.3

### An app is one window

Editing an app and deploying it were two windows for one thing. They are
one now: **Catalog, Assignments, Metadata, Package and detection,
Requirements and behaviour**, with the status box, the log and the deploy
button under all five.

Nothing was rewritten to get there - the deploy dialog builds exactly as
before and hands its pages to the host instead of opening a window. What
did need care: the places that closed the deploy window now close whichever
window is showing it, and the catalog save that used to happen when that
window returned now runs the moment a create or update succeeds.

### All three Intune checks in one window

**Look up App IDs**, **Intune audit** and **Sync metadata** ask three
versions of one question and all three began with the same read of every
app in the tenant. They are tabs of **Check against Intune** now, sharing
that one fetch - so the obvious next question no longer costs another
window and another wait.

### Install context can no longer be asked for where it cannot happen

Batch edit offered it for apps already in Intune, which Graph refuses
outright ("The 'RunAsAccount' property cannot be patched for the
'Win32LobApp' type"). It is offered only with **Catalog only** ticked now.

### Dialogs that stopped being walls

- **Deploy to Intune** is three tabs - Metadata, Package and detection,
  Requirements and behaviour - with the status box, the log and the buttons
  below them, since those belong to the whole dialog. Detection moved under
  the install commands, which is what the extra 400px of width was for, so
  the window is 900x912 instead of 1300x1035.
- **Settings** is Connection and Certificate: two unrelated jobs, and only
  one of them is ever the reason it is open. The log stays below both,
  because Test connection sits on Connection and writes into it. 930x970
  becomes 930x658.
- **Batch edit Intune fields** puts its two field columns on tabs and keeps
  the app list beside them - which apps and which fields are one decision.
  1180x900 becomes 870x900.

The layout audit only ever measured whichever tab happened to be open, so
two thirds of Deploy, and every page but the first of the main window, were
never checked at all. It now walks each page in turn - and caught a bug in
this very change within a minute of being taught to.

### Deleting groups

**Group manager > Delete several groups...** ticks off a list instead of
repeating the same three steps per group. Groups the catalog still uses are
marked, and the confirmation names the apps whose assignments would break
rather than counting them. One group failing doesn't abandon the rest.

## 1.3.2

### Install status works against a current tenant

It never had. Two faults, both confirmed fixed live:

- The app asked for `getDeviceInstallStatusReport`, an action that exists in
  neither beta nor v1.0 of Graph - several guides still name it - and got
  "Resource not found for the segment". The action is
  `retrieveDeviceAppInstallationStatusReport`. The fallback to
  `mobileApps/{id}/deviceStatuses` is gone: that navigation property has
  been removed from `mobileApp` in both versions, so it could only ever add
  a second, more confusing error.
- Graph declares that action as a stream, so its JSON arrives as
  `application/octet-stream` and the SDK refuses to parse it. The request
  now asks for the raw response and reads it.

A report holding exactly one device row came back as one row per column,
each with a single cell: `$x = if (...) {...}` sends its value through the
pipeline, which unrolls a one-element array. Every test until now used two
or more rows.

### A refusal now says which permission is missing

"Forbidden" alone never says what to add, and the app answered "likely
missing a required permission" while Graph had already named the scopes it
wanted. Graph's response body was reaching the log and nothing else:
`ErrorDetails` does not survive leaving a runspace, so the dialog got an
exception with none. The body now travels with the exception.

**Settings > Test connection reports what the token is allowed to do** -
the permissions it carries, which feature each missing one blocks, and
whether the token belongs to a different app registration than Settings
names. Signing in successfully and being permitted anything are different
questions, and the test only ever asked the first: an app registration
allowed to do almost nothing still passed it.

### Elsewhere

- "Save changes?" no longer reappears on every close: the question was
  asked without owning the window behind it, so each further Close or Esc
  stacked another copy. Answering Yes with an incomplete Tenant ID, Client
  ID or thumbprint now says what is missing and offers to close anyway.
- The first-time setup guide opens beside Settings instead of on top of it,
  so it can be read while the fields are filled in.
- **Batch edit Intune fields** is laid out in three columns.
- The GUI tests run in parallel: about a quarter of an hour down to five
  minutes.

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
- **Batch edit Intune fields** is laid out in three columns - the apps, the
  requirements and install behaviour, and the description and commands -
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
  can still be read - the success popup's OK used to close the whole
  window. The action buttons are disabled afterwards and Cancel becomes
  Close; closing still saves to the catalog exactly as before.
- The app editor's **Excluded from** list was built but never added to the
  window, so exclusions couldn't be seen or changed.

### Templates, and a Deploy dialog that doesn't wait

- Right-click apps > **Clear App ID...** forgets which Intune app an entry
  belongs to (Intune itself is untouched), and **Save as template...**
  copies the selection to a folder without App IDs, so the same
  configuration deploys as new apps - in another tenant, or this one.
- **Check Intune when opening Deploy** (toolbar, Sync box, on by default):
  turn it off and "Deploy to Intune" opens immediately with what's saved
  here, offers **Refresh from Intune**, and checks Intune automatically
  right before an update is sent - the moment where a stale value could
  actually overwrite a newer one. Drift is shown there, field by field,
  before the update continues.
- **Batch edit Intune fields...** can now also change description,
  publisher, owner, developer, information and privacy URL, notes, install
  and uninstall command and install context, and has a **Catalog only**
  mode that contacts Intune not at all - so apps that were never deployed
  can be bulk-edited too.

### Excluded groups

An app can now carry an **Excluded from** list next to Required, Available
and Uninstall: those groups never get the app, whichever list would
otherwise have covered them ("everyone in Sales except contractors").
Before, exclusions had to be set in the portal - and the next push from
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
