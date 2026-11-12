# Changelog

## 2.0.15

A security, bug and usability sweep.

### Security

- **CSV export:** a value Excel would run as a formula (starting with `=`,
  `+`, `-` or `@`) is written as text, and comes back unchanged on import.
- **Packaging tool:** IntuneWinAppUtil.exe's Microsoft signature is checked
  before every use, not only after download, and the signer must be exactly
  "Microsoft Corporation". This matters when the Tools folder is a share
  others can write to.
- **Activity log:** a step's output reaches the page in whole lines, so the
  secret filter always sees a token or signature in one piece.

### Fixed

- **Deploy:**
  - "Done" deployed everything again when clicked; it is now disabled.
  - A missed status poll left the queue stuck with a dialog that wouldn't
    close; polls are retried, and a lost step ends the wait with a message.
  - A step finished while the window was minimised is no longer completed
    by the server after 15 s (now 2 minutes).
- **Steps:** two quick clicks could start two of them.
- **Lost changes:**
  - "Supersedes nothing" was read back as "leave Intune's alone".
  - Updating an app with no settings of its own cleared Intune's
    supersedence and its Featured flag.
- **Copying a catalog to a new tenant:**
  - Deploy refuses an App ID the connected tenant doesn't have, saying why,
    instead of failing on every app.
  - Clearing App IDs also drops supersedence that points at the old
    tenant's apps.
  - The "push settings / push groups afterwards" choices leave out apps that
    aren't in this tenant.
- **Version comparison:**
  - a pre-release ("1.0-beta") counts as older than its release;
  - a leading "v" is ignored;
  - very long numbers no longer stop the Apps list from loading;
  - an app without a version can take winget's.
- **CSV:**
  - no "sep=" line, so Excel keeps umlauts and accents;
  - a file Excel saved in its own encoding is read correctly;
  - a duplicate row is a warning, not a blocker;
  - group names with `|` survive.
- **Smaller fixes:**
  - Replace a group no longer leaves both "SG-A" and "sg-a" on an app.
  - The icon size limit is the same in the editor and the server.
  - A failed group read no longer leaves its buttons disabled.

### Changed

- **Set up this tenant:**
  - Step 3 says how many apps are ready, lists why the others aren't, and
    links to Packaging when the shared Winget package is missing.
  - Step 2 says the groups are created empty, links to the Groups page, and
    shows "not checked" when Entra ID couldn't be read, instead of a tick.
  - Step 4 is a check you can run again, not a step that is never "done".
- **Apps list:**
  - **Statuses:** "Not deployed" (grey) and "Not deployed - own settings"
    replace "No App ID" and "Metadata saved - ready to deploy". Neither
    counts as needing attention any more. "Custom package" reads
    "Winget ID + own package".
  - **Last audit:** an audit from another tenant shows as "Other tenant".
  - **Type:** short ("Win32", "Store"), with the full name on hover.
  - **Groups column:** headed "R / A / U".
  - **Toolbar:** stays on one row down to about 1100 px.
- **Tenant banner:** **Set up this tenant...** is the main button. "Clear
  their App IDs" is gone, since it is step 1 there.
- **Keyboard:** Enter or Delete on a button, link or menu no longer opens or
  removes the selected app.
- **App editor:**
  - Escape or Cancel asks before discarding changes.
  - The Save/Cancel row stays visible while scrolling.
  - The Uninstall command's tooltip is fixed.
- **Wording and buttons:**
  - Deploy's action for an app in Intune is "Push settings", and apps it
    can't run are "Not ready".
  - Replace a group says "in these apps" or "in all apps".
  - Batch edit, Add groups and CSV import have Cancel until something is
    applied.
  - Clear App IDs explains what stays.
  - New group's button is "Next".
  - The group save button says what it does ("Add 2 members and save",
    "Save description"), and the description sits above the two cards.
- **Smaller changes:**
  - Batch edit doesn't offer the selected apps as their own dependencies.
  - Checks keeps its log folded unless a stage fails.
  - The undo banner shows the date when it isn't today.

## 2.0.14

### Added

- **Set up this tenant** (Catalog menu, and the banner when App IDs don't
  match the tenant). One window lists what the connected tenant still needs
  for the catalog, in order:
  1. clear App IDs from another tenant;
  2. create the groups Entra ID doesn't have;
  3. deploy the apps not in Intune;
  4. push the deployed apps' groups.

  Each step names the apps or groups and opens the usual question or
  preview. The list reads the tenant again after each step.
- **Install status of every app** (Catalog menu): installed, failed,
  pending, not installed and not applicable devices for every deployed app.
  It reads one report, falling back to each app's own summary. Worst first,
  with a filter for failures and **Devices...** for one app's devices.
- **App icons:**
  - in the editor: **Choose image...** (PNG or JPEG; larger than 512 px is
    scaled down; at most 750 KB), **From Intune**, **Remove**;
  - kept in the app's own file, so renames, backups and Undo carry it;
  - shown in the Apps list, and sent to Intune on deploy and on push
    settings. No icon leaves Intune's own alone.
- **Newer on winget:**
  - **Catalog > Check winget for new versions** asks winget for every Winget
    app (Checks' winget stage does too);
  - the Version column shows "→ newer" with a **Newer on winget** filter;
  - **More > Take winget's version** sets the App version, with Undo, then
    offers to push settings.
- **Supersedence in the editor** (Deploy settings): the older apps this one
  updates or replaces (uninstalling the old one), at most 10. These can be
  catalog apps, or any Intune app by App ID. Unticked, Intune's own
  supersedence is left alone, as before.
- **Earlier versions: Compare.** Shows what the save at that time changed
  (before and after), and that version next to the app as it is now.

### Changed

- **Retries:** steps also retry Graph's 502 and 504 gateway errors, and the
  package upload to Azure Storage retries a block that times out, is
  dropped or throttled. Up to 4 tries, waiting 5, 15 and 30 seconds. Before,
  one dropped block failed the deploy.

## 2.0.13

### Added

- **Preview before Batch edit.** The first click shows every field that
  changes, per app, old and new; a second click applies it. A field an app
  already has as asked doesn't count, and that app's file isn't rewritten.
- **Undo the last bulk change.** Batch edit, Add, Remove or Replace groups,
  clearing App IDs and CSV import keep a record. A banner over the Apps list
  names the change, with **Undo** (also in the Catalog menu).
  - Each file gets back its copy from before.
  - A file changed since (an editor save, a deploy's App ID) is left alone
    and named.
- **Replace a group:** one group swapped for another in every role, on all
  apps (Catalog menu), on the selected ones (More), or from the Groups
  page's right-click menu. Catalog only; Rename on the Groups page still
  renames a group in Entra ID.
- **Dependencies in Batch edit:** add the ticked apps, remove them, or set
  exactly them. Before, it could only replace the whole list.
- **CSV export and import** (Catalog menu):
  - **Export** writes one row per app (semicolons, readable by Excel).
    Groups, dependencies, details, requirements and commands are columns;
    lists are separated with `|`.
  - **Import** shows every change first. Values are checked like the editor
    (one wrong row stops the whole import), apps not in the catalog are
    skipped, and appId and wingetId are never changed.
  - After an import, it offers to push settings and groups for deployed
    apps.
- **Deploy queue:**
  - a progress bar and counts;
  - a failure's reason on its row;
  - an app whose dependency failed is skipped, saying which;
  - **Stop after this app**, and **Retry** for whatever failed, was skipped
    or didn't start.
- **Apps list:**
  - **Saved views:** a search and filter kept under a name.
  - New filters: **Deployed** and **Assigned to no group**.
  - `group:name` in the search shows the apps assigned to a group.
- **Several apps at once:** Copy App IDs, Clear App IDs and Remove from
  catalog now take a multi-selection.
- **Groups:** favourites can be added or removed from the right-click
  menu, and are starred in the list.

### Changed

- **Catalog menu:** Reload and Open catalog folder moved there from the
  Apps toolbar, beside CSV, Replace a group and Undo.
- **Settings in four sections:** Connection (with certificate, permissions
  and prerequisites), Defaults (default values, automatic checks,
  favourite groups), Packaging & folders, and Diagnostics (with Activity).
  It used to be one long page with connection parts in both columns.

## 2.0.12

### Changed

- **Groups page.** Built for a catalog that's new to a tenant:
  - **Entra ID status in the list:** a dot per group (green in Entra ID,
    amber not), "x of y not in Entra ID", and a filter for either.
  - **Several groups at once:** Ctrl+click and Shift+click select, Ctrl+A
    selects all. A bar offers Create and Delete for the selection.
  - **Right-click menu:**
    - Open, Copy name, Assign apps;
    - Create in Entra ID, Rename;
    - Remove from all apps (the catalog only; Entra ID keeps the group);
    - Delete from Entra ID.

    The keyboard works too: arrows, the menu key, Delete and Escape.
  - **Apps in the catalog** is a table. Each row shows how the app is
    assigned, whether it's in the tenant, and a Remove button; the app name
    opens the editor. Counts per assignment sit on top, with **Assign
    apps...** (pick the assignment, tick the apps) and **Push groups...**
    for the deployed ones.
  - **A group not in Entra ID** says how many assignments reach nobody,
    with **Create group** right there.
  - Apps and members side by side; "Delete several..." is now "Delete by
    name..." for groups the catalog doesn't use.
- **Checks: Create group.** "Group doesn't exist in Entra ID" findings get
  **Create group** and **Open in Groups**, and the toolbar creates the
  groups of every ticked finding at once.

## 2.0.11

### Changed

- **"Deployed" means deployed in the tenant you're connected to.** Status
  used to say Deployed for any app whose catalog file had an App ID. After
  copying a catalog from another tenant, that was every app. The Apps list
  now checks its App IDs against the connected tenant (read once, kept for
  five minutes):
  - **Deployed:** the tenant has an app with that ID.
  - **Not in this tenant:** the ID is unknown there. The catalog was
    copied from another tenant, or the app was deleted in Intune.
  - **Has App ID:** not checked yet, because there's no connection.

  A banner names how many apps are affected, with **Show them** and
  **Clear their App IDs** (one question for all). Cleared apps keep their
  settings, groups and packages, read "ready to deploy", and Deploy creates
  them in this tenant. "Needs attention" and a new "Not in this tenant"
  filter include them.
- **Dependencies are a list.** In the app editor and Batch edit:
  - the chosen apps show as chips on top, and × removes one;
  - a filter field narrows the list;
  - every app is a full row with its checkbox, in a box that scrolls on
    its own.

### Fixed

- **Keyboard:** the Apps table can be scrolled with the keyboard when it is
  taller than the window.

## 2.0.10

### Changed

- **The badge at the top right says whether the connection really
  works.** It used to say "Connection set up" as soon as the three fields
  were filled in, even if signing in would fail. Now:
  - When the app opens and after Save, it reads one app from Intune with
    the saved settings. It shows **● Connected** in green, **● Connection
    problem** in red, or **Checking connection...** while it runs. The
    tooltip says what it signed in as, the tenant and the time, or the
    error.
  - Test connection updates it straight away.
  - **Not connected** still means nothing is set up yet.
  - Clicking the badge goes to Settings > Connection, with Test connection
    focused.

## 2.0.9

### Fixed

- **The "Open ... folder" buttons seemed to do nothing.** Explorer opened,
  but behind the app window: Windows doesn't let a background process, the
  app's server, bring a new window to the front.
  - Now the folder is opened through Windows' Shell and its Explorer window
    is brought forward; one already showing the folder is reused.
  - Every folder button says what it opened, or why it couldn't. Two of
    them used to ignore errors.

### Added

- **Buy me a coffee:** a small coffee-cup button at the top right, like the
  one in NOBS. It opens https://buymeacoffee.com/monsama in your own
  browser.

### Changed

- **The setup guide is a stepper.**
  - **Five steps** that tick themselves off: app registration, IDs,
    certificate, permissions, Test connection.
  - **Progress:** the next open step is highlighted, and the heading shows
    "2 of 5 done", or "Setup complete".
  - **Each step has its own button:** Open App registrations, Go to
    Connection, Use an existing one / Create new / Upload, Add required
    permissions, Test connection.
  - **How a step counts as done:** from the filled-in fields, the
    certificate on this machine, and the last Test connection (remembered
    in this browser).
  - **"Getting started"** shows the three situations as rows, each with its
    own button: Run Checks, Add app, Open Checks.

- **Using a certificate you already have is easier to find.** Settings >
  Certificate has **Use an existing one...** next to "Create new
  certificate...". It opens the same picker as Choose... in Connection.
  - The picker lists certificates from your user store (CurrentUser\My)
    and the machine store (LocalMachine\My) that can sign in: with a
    private key, and not expired.
  - It also says how many it left out and why (expired, no private key),
    so an empty list explains itself.
  - The choices are proper buttons, so the keyboard works too.

## 2.0.8

### Fixed

- **Starting from a zip that wasn't unblocked.** Windows marks downloaded
  files, and with the usual RemoteSigned policy PowerShell refused every
  file under `code\` with "not digitally signed", once per file.
  - Now the app notices the mark when it starts, says what it means, and
    offers to unblock its own files (`IntuneDeployment.ps1` and `code\`
    only).
  - If the policy still refuses them, it shows one explanation with the
    exact command.
  - Where a group policy requires signed scripts (AllSigned), it says that
    unblocking can't help.
- **Browser features that got in the way in the app window.** The window
  has its own browser profile, and the app now sets that profile up before
  each start; your normal Edge or Chrome isn't touched. Switched off:
  - "Translate this page?";
  - the password manager and form autofill;
  - spelling correction and capitalisation;
  - sync and the "we're syncing your data" sign-in notice.

  The page itself says it is English and shouldn't be translated, and
  every field turns off autofill, spellcheck, autocorrect and
  autocapitalise. Edge's text predictions, the menu on selected text, the
  sidebar and shopping suggestions are switched off by name.
- **Groups page:** the "Used by" and "To add" lists no longer give their
  placeholder line a list-option role. That was an accessibility error,
  added in 2.0.1 by mistake.

## 2.0.7

### Added

- **Keyboard use in the Apps list:**
  - ↑/↓ move the selection, and Shift extends it;
  - Home/End jump to the ends, and Ctrl+A selects everything shown;
  - Enter opens the editor, and Delete asks to remove the app from the
    catalog;
  - Ctrl+S saves in the editor.

  None of these react while you type in a field or a dialog is open.

### Tests and checks

- **Push groups (Apply) is tested without a tenant**, on Windows:
  - the one missing group is created;
  - Intune gets exactly the catalog's groups;
  - an old assignment the catalog no longer has is dropped.
- **Large catalog:** `Scale.Tests.ps1` generates 500 apps and times the
  Apps list, Checks, opening and saving an app, Diagnostics and Groups
  against generous limits. It runs in CI on all three shells.
- **Code checker:** CI runs PSScriptAnalyzer over `code/` with the rules
  that catch real bugs; its settings are in
  `code/tests/PSScriptAnalyzerSettings.psd1`. It found five things, all
  fixed:
  - Packaging assigned to `$Args`, a variable PowerShell fills in itself.
    It works, but one refactor away from passing the wrong arguments.
  - An unused path in the certificate actions.
  - Three in the tests.
- The tests README covers the scale test, the code checker and the weekly
  Graph check.

## 2.0.6

### Added

- **Earlier versions in the app editor.** A copy of an app's file has
  always been kept on every save. Now the editor's **Earlier versions...**
  lists them with what differs from now (name, App ID, groups, settings),
  and **Restore** puts one back. The current version is kept as a copy
  too, so a restore can itself be undone.
  - Two saves within the same second no longer share one copy.
- **A running step shows again after a page reload.** The page asks the
  server what's still running and follows it in the Working dialog.

### Tests and release

- **Steps that change Intune are tested without a tenant**, on Windows.
  Test mode now reaches the steps' own Windows PowerShell:
  - Delete from Intune;
  - a delete blocked by a dependency;
  - renaming a group.

  The test checks what each step sent, and what the catalog does after.
- **Restore:** the server test lists earlier versions, restores one, keeps
  the version before the restore, and refuses an ID that isn't a copy of
  this app.
- **Release workflow:** the GitHub Actions it uses are pinned to exact
  commits, and Dependabot proposes updates. `SECURITY.md` says so.
- README screenshots updated.

## 2.0.5

Usability and speed.

### Changed

- **Questions in the app's own dialog.** All 17 browser popups (`confirm`
  and `prompt`) are gone. Those showed the page's address as their title,
  looked like an error, and Chrome can suppress them after a few. Now:
  - the question is the heading;
  - the button says what happens: Delete, Remove, Clear, Add, Rename,
    Create;
  - destructive questions have a red button, and Cancel has the focus;
  - Escape cancels, and Enter confirms a typed name (New group, Rename).
- **Checks is much faster in a big tenant.** It used to read every group
  and every user in Entra ID on each run, hundreds of pages in a large
  tenant. The users were never needed at all.
  - It now looks up only the groups the catalog names, 15 names per
    request.
  - A tenant that refuses that lookup gets the full group list as before.
  - The notes say how many of the catalog's groups were found.

### Tests

- The browser test fails if any browser popup appears, and checks the
  remove question (red button, Cancel focused, accessibility rules).
- The Graph test checks that Checks asks for the catalog's groups by name
  and reads no users.
- Unit tests for the by-name lookup: requests of 15, OData quoting.
- The tenant checklist covers closing the window and reloading the page
  during a deploy (2.0.4).

## 2.0.4

A bug sweep.

### Fixed

- **Closing the window during a deploy no longer loses the App ID.** The
  server used to stop at once. The step went on in its own process and
  created the app in Intune, but its App ID never reached the catalog, so
  the next Deploy would create a second copy.
  - Now the app waits for running steps before it stops, and finishes them
    as the page would have. The console says so; Ctrl+C stops without
    waiting.
  - What the page would have started next (pushing groups after a deploy)
    is written to the Activity log instead.
- **Reloading the page during a step** no longer leaves it unfinished
  until the app stops. A step that has ended and isn't being watched is
  finished by the server after 15 seconds.
- **Brackets in folder and app names.** File commands read `[` and `]` as
  wildcards, so a package folder like `Tool [x64]`, or the app installed
  under such a folder, was silently not found. Every file command now
  takes the path literally, and a unit test keeps it that way.
- **Single results in Windows PowerShell 5.1.** In some places a list with
  exactly one entry became a single object without a count:
  - **Pull from Intune:** an app whose only difference was one group
    wasn't offered for review.
  - **The setup checklist:** it miscounted a single missing optional
    permission.
  - **Add to catalog:** an app with one group in a role got it as text
    instead of a list.
  - **Packaging:** a folder with one installer.
- API answers are serialized deep enough for every nested result (12
  levels instead of 8).

## 2.0.3

A security sweep. Every finding needed the page's start token or a local
program first, so these are hardening fixes, not open holes.

### Security

- **Deleting a certificate on this machine now deletes its private key
  too.** Before, Windows removed the certificate and left the key file
  behind.
- **Winget search text** is passed as `--query` with correct Windows
  quoting:
  - text that looks like an option (`--help`) can no longer act as one;
  - a trailing backslash can no longer run into the next argument.
- **Folder settings** must be full paths (a drive or `\\server\share`)
  without quotes, wildcards, control characters or `..`. An unknown folder
  kind gets a clear refusal instead of an error.
- **Logs and errors** are filtered for anything shaped like a secret
  before they reach the Activity log, the log file or the page:
  - signed-URL signatures;
  - bearer tokens and JSON Web Tokens;
  - `client_secret`, password and access token values.

  The steps already avoided writing them; this is the second layer.
- **The local server** stops reading request headers past 64 KB and
  handles at most 64 requests at once, so another program can't make it
  use memory without end.
- **Test mode** (`INTUNE_CATALOG_TEST_GRAPH`) now shows a TEST MODE badge
  and banner in the page, not only in the console. Its made-up connection
  IDs are never written to the settings file.

### Documentation

- `SECURITY.md`: what the app exposes, what it keeps and what it never
  does, and how to report a problem.

### Tests

- Unit tests for the quoting, the secret filter and the folder rules.
- **Server tests:**
  - oversized headers;
  - refused folder paths and an unknown folder kind;
  - test mode visible and never writing the settings file.

## 2.0.2

### Changed

- **Tooltips.** About 60 buttons got one, saying what they do and whether
  they change the catalog, Intune or Entra ID - Delete from Intune and
  Remove from catalog, Pull and Push, Upload, Build, Apply.
- **Disabled buttons say why** when you hover them: "Select exactly one app
  to edit", "Only apps already in Intune - deploy X first", "This script is
  only a local copy". This covers the Apps toolbar, the More menu, the
  Checks fixes, Groups and Platform scripts.
- **Status labels:**
  - Every status on the Apps list explains itself and what to do: No App
    ID, Package missing, Custom package, ready to deploy.
  - So does every Last audit result and the connection badge.
- **Column headers** in Apps, Checks, Platform scripts and Push groups
  explain what they show.
- **Fields that are easy to get wrong** explain themselves in the editor,
  the default values and Batch edit: install context, restart, install
  time, detection, return codes, the four assignment kinds and the
  Winget ID.
- The Restart choice "Based on return code" is now "By return code": the
  longer text was cut off in the default values. The saved value is the
  same.

### Tests

- The browser test checks that every greyed-out button has a tooltip.
- **Layout check,** against a mock API in light and dark mode at 1440 and
  820 pixels: buttons in a row line up, nothing overlaps, no text is cut
  off and paddings are consistent. The only problem it found was the
  Restart choice above.

## 2.0.1

### Fixed

- **Checks compared Intune as one app.** With a connection set up, Checks
  handed every app in Intune (and every group in Entra ID) to the
  comparison as a single item, so the Intune and group findings were wrong.
- **A save no longer undoes another change.** Changes to an app's file now
  wait for each other, so a deploy saving its App ID while the editor saves
  the same app no longer loses one of the two. The editor also refuses a
  save when the app was changed since it was opened, instead of writing its
  older copy back over the new App ID.
- **Permission hints name the right permission.** A refused request on the
  Groups page, Checks or Install status said Platform scripts needed
  `DeviceManagementScripts.ReadWrite.All`. Each page now names the
  permission it needs.
- The deploy plan reports an app of the same name already in Intune before
  a missing package, so building the package doesn't lead to a duplicate.
- Messages and Prerequisites no longer talk about "this window" where they
  mean the PowerShell running the app.

### Accessibility

Checked with axe-core against WCAG 2.1 AA:

- Contrast of green and grey text in light mode, and of the primary
  buttons and grey text in dark mode.
- A level-one heading.
- Log boxes can be scrolled with the keyboard.
- Labels for every Batch edit field and the favourite groups.
- Named table headers.

### Tests and release

- **Graph test mode:** with `INTUNE_CATALOG_TEST_GRAPH` naming a file of
  stored answers, Graph calls are answered from it and nothing signs in.
  `WebGraph.Tests.ps1` uses it to check every page that reads Graph:
  - paging;
  - fallbacks;
  - refused requests.

  It found the Checks bug above.
- **The browser test** runs the accessibility rules on every page and the
  main dialogs. It also adds an app through the editor, changes it with
  Batch edit and Add groups, and removes it again.
- **The server test** checks the stale-save refusal and ten changes to one
  app at once.
- **Signing:** releases are signed when the repository has a code-signing
  certificate as secrets.
- **Code layout:** the page script and `WebApi.ps1` are split per page. The
  code is unchanged.

## 2.0.0

The web interface is now the app. `IntuneDeployment.ps1` opens it directly;
the WinForms window is gone.

### Changed

- **One interface.** Everything the classic window did is in the web
  interface: Apps, Checks, Groups, Platform scripts and Settings. Starting
  the app opens an Edge or Chrome app window on a server bound to
  127.0.0.1; closing the window stops it. `-NoBrowser` prints the address
  instead. `-Web` is still accepted, so existing shortcuts keep working.
- **Settings > Automatic checks now does something in the web interface:**
  - "Run Checks when the app opens" runs Checks once when the app opens,
    optionally with every deployed app in detail. The Checks tab shows how
    many findings there are.
  - "Before deploying a new app, look for one of the same name in Intune"
    skips such an app in the deploy plan instead of creating a second one.
- The settings file no longer holds the classic window's column widths,
  sort order and window position. A file that has them still loads; they're
  just not written back.

### Removed

- `MainApp.ps1`, every WinForms dialog (`code/Private/Dialogs`), the
  background fetches built on WinForms timers (`GraphFetch.ps1`) and the
  toolbar quick actions - about 28,000 lines. The functions that both
  interfaces shared stay in `code/Private`, with no WinForms left in them:
  `GuiHelpers.ps1` is now `Helpers.ps1`, packaging logs to the Activity log,
  and the certificate status returns a level instead of a colour.
- The WinForms GUI test suites and their CI jobs.

### Added

- A browser test (`code/tests/ui/WebUi.Tests.mjs`). It runs the real
  server and opens every page in Chromium, in light and dark mode, wide and
  narrow, and fails on page errors, failed requests, unnamed buttons, or a
  page wider than the window. CI keeps the screenshots.
- The README, its screenshots, the test documentation and the tenant test
  checklist describe the web interface.

## 1.14.0

### Added

Web interface, step 3d (`IntuneDeployment.ps1 -Web`) - Settings:

- **Setup guide:** the Entra ID app registration step by step, and getting
  the catalog and Intune to match.
- **Prerequisites:** whether the Microsoft.Graph.Authentication module is
  installed in each PowerShell the app uses, and **Install missing** (for
  your user account, from the PowerShell Gallery).
- **Diagnostics:** this machine's setup, the catalog itself (apps with
  nothing to deploy, deployed apps assigned to nobody, duplicate names and
  App IDs, package folders no app uses) and how it lines up with Intune.
- **Certificates on this machine:** every certificate in the two personal
  stores, marked when it is in use, expired or has no private key, with
  **Delete**.

## 1.13.0

### Added

Web interface, step 3c (`IntuneDeployment.ps1 -Web`):

- **Checks: every check the classic window runs.**
  - The deployed apps in detail: settings, groups and dependencies against
    Intune, and assignments in Intune the catalog doesn't have. The last
    audit (the Apps list's Last audit column) is updated as before.
  - Winget IDs that winget no longer knows.
  - Two switches choose whether to run the slow parts.
  - A log of the run.
- **Checks: every fix.** Pull, Push settings, Push groups, Add to catalog,
  Find Winget ID and Re-check. Tick several rows to fix them in one go.
- **Several apps at once** (More menu, also on right-click):
  - Batch edit: change only the ticked fields, then optionally push the
    settings of the apps already in Intune.
  - Push settings to Intune: the catalog's settings, without uploading a
    package.
  - Add groups (from your favourites or by name) and Remove groups, then
    optionally push groups.
  - Delete from Intune.
- **Find on winget** in the app editor, next to the Winget ID.

### Changed

- Find Winget ID also updates the app's install and uninstall commands
  when they name the old ID. Before, they kept installing the old
  package.
- Deploy's reasons for skipping an app point to the web interface's own
  Package, Settings > Packaging and Deploy settings.

## 1.12.0

### Added

Web interface, step 3b (`IntuneDeployment.ps1 -Web`):

- **Deploy settings in the app editor:** a collapsible section with the
  detection rule (script, MSI product code, file or folder, registry),
  architecture, install context, minimum OS, install time, disk, memory
  and CPU requirements, restart behaviour, Company Portal uninstall,
  return codes and dependencies. Checked like the classic deploy form.
  Install context moved here from the general fields.
- **Groups page:**
  - The groups the catalog assigns apps to, with which apps use each
    one and how.
  - A group's members in Entra ID. Search users and groups to add them,
    remove members, and set the description.
  - Create a group, rename it (the catalog and favourites follow), delete
    one, or delete several at once.
- **Platform scripts page:**
  - Intune's platform scripts beside the local copies, marked Saved,
    Differs, Not saved here or Local only.
  - Edit, create, save locally or to Intune with groups, and delete.
  - Run status for each device, and Save local copies.

### Fixed

- Renaming a group in the classic group manager also renames it where
  apps exclude it. Before, an exclusion kept the old name.
- The editor refuses information and privacy URLs that aren't http or
  https.

## 1.11.0

### Added

Web interface, step 3a (`IntuneDeployment.ps1 -Web`):

- **More menu, also on right-click:**
  - Package (builds the .intunewin for apps with their own installer)
  - Pull from Intune
  - Install status
  - Copy and Clear App ID
  - Delete from Intune
  - Remove from catalog
- **Pull from Intune:** each app's settings and groups come from Intune.
  An app that differs from the catalog is shown field by field, and you
  tick what keeps the catalog's value.
- **Install status:** every device's state for an app, with counts.
- **Delete from Intune:** deletes the app in Intune and clears its App
  ID in the catalog. The catalog entry stays.
- **Settings:**
  - Packaging: tool status, Download packaging tool, Build
    init.intunewin.
  - Automatic checks and pushes.
  - Folders.
  - Default values for new apps, with the same checks as the classic
    dialog.
  - Favourite groups.

### Fixed

- **Saving settings from the web interface wiped the classic window's
  column widths and window position.** They are now kept, and a failed
  save no longer tries to show a classic message box.

## 1.10.0

### Added

- **New web interface (preview).** Start it with
  `IntuneDeployment.ps1 -Web`. It works like the NOBS apps:
  - a small local server answers only on 127.0.0.1, and the token
    changes on every start;
  - the interface opens maximised in an Edge or Chrome app window, a
    normal window you can move, snap, minimise, maximise and close.

  This first step has:
  - **Apps:** the catalog with search, filters (needs attention, not
    deployed, package missing, ...), sorting and coloured status.
  - **Settings:** connection fields, Test connection with the setup
    checklist and permission report, choosing or creating a certificate,
    checking, uploading and deleting certificates in Entra, "Add required
    permissions", and opening Entra for consent.
  - **Activity:** one log of everything, including the output of each
    Entra action.
  - Light and dark mode.

  It also has:
  - **The app editor:** add, edit and remove apps (name, Winget ID, App
    ID, the four assignment lists and the Intune details). Every save
    backs up the app's file first. Names, file names, App IDs and Winget
    IDs are checked before anything is written.
  - **Deploy:** one or more apps, in dependency order. Apps that can't
    be deployed are listed with the reason. Each App ID is saved to the
    catalog as soon as that app is done, and its groups are pushed
    afterwards when the setting says so.
  - **Push groups:** a preview of what will be added and removed in
    Intune, then Apply.
  - **Checks:** catalog dependencies, how the catalog lines up with
    Intune (renamed, not linked, App ID gone, not in the catalog),
    groups missing in Entra ID, and the last audit's findings. One-click
    fixes take Intune's name, link the matching app, clear a stale App
    ID, open the editor or push groups.

  "Open classic window" opens what hasn't moved yet: packaging, the full
  deploy form, metadata sync, platform scripts, groups and the
  remaining fixes. `IntuneDeployment.ps1` still opens the classic window
  by default.

### Fixed

- **Batch Deploy dropped supersedence.** The classic Batch Deploy wrote
  the step's settings in a format the step didn't read for supersedence,
  so it was silently left out. The web Deploy writes it correctly; the
  classic Batch Deploy is unchanged in this release.

### Changed

- App state setup is now shared by both interfaces
  (`code/Private/AppState.ps1`), and so is the catalog list row
  (`Get-CatalogRow`). The app version now lives in `AppState.ps1`.

## 1.9.0

### Added

- **Add required permissions with one button.** Settings > Certificate >
  "Add required permissions..." signs you in once and adds the Microsoft
  Graph application permissions this app uses to the app registration:
  the required ones, and the optional ones if you choose. Anything
  already listed there is kept. It then opens the registration's API
  permissions page in Entra, where an admin clicks "Grant admin consent".
  "Open API permissions in Entra" goes straight to that page at any
  time.
- The permission report and the setup checklist name that button and
  include a clickable link to the registration's API permissions page.

### Changed

- **Faster Test connection and lookups.** The Graph module is looked up
  once per session. Before, every Test connection and some lookups
  searched every module folder on the machine.
- **Smoother catalog list.** The list is double buffered, so it no
  longer flickers when scrolling or filtering. It also no longer creates
  a new font object for every styled cell on every repaint.
- **Readable status colours.** Green, amber, blue and grey status text in
  the list now has at least 4.5:1 contrast. The old DarkOrange and
  SeaGreen were well under that.
- The Settings log says what will appear in it, instead of opening as an
  empty black box.

### Security

- Links in the Settings log only open `https://` addresses. The log
  shows text from Graph error responses, and a `file://` link in one
  could otherwise have started a program.

## 1.8.0

### Security

- **App names can't run code during packaging.** Folder names were
  pasted into PowerShell code with `'` doubled. PowerShell also ends a
  string on the typographic quotes `‘ ’ ‚ ‛`, so a crafted app name (from
  a catalog file, or copied over from Intune) could run its own code on
  Package. Step parameters are now passed as values and never parsed as
  code.
- **Winget IDs can't inject into device scripts.** The generated
  detection script and install and uninstall commands run as SYSTEM on
  every targeted device. A Winget ID is now always a single-quoted,
  escaped literal in them, and a `$(...)` in one is never run.
- **App IDs must be GUIDs.** An App ID from a catalog file goes straight
  into Graph addresses, so a value like `../../v1.0/groups/<id>` could
  aim Delete at a group. The catalog now drops App IDs that aren't
  GUIDs, and the delete step refuses them.
- **The downloaded packaging tool must be signed by Microsoft.**
  IntuneWinAppUtil.exe comes from a GitHub branch and runs on every
  package. It's only kept if it has a valid Microsoft Authenticode
  signature, and its temp files have unique names.
- **Generated certificates have non-exportable private keys.** Only the
  public .cer is ever needed.
- **Certificate upload no longer leaves your sign-in behind.** That
  sign-in carries Application.ReadWrite.All on your own account. It now
  only lasts for the one operation, and isn't cached in your profile.
- **No storage SAS signature in the log.** A failed upload logs the
  address without its signed query.
- Windows' reserved names (`CON`, `NUL`, `COM1`, ...) and control
  characters are kept out of app folder names. Each background step gets
  its own uniquely named script, so two runs of the same step at once
  can't overwrite each other.

### Added

- **Setup checklist after Test connection.** The log now shows each
  step of the first-time setup as done, failed or not checked yet:
  - the Graph module
  - the connection details
  - the certificate on this machine, with its private key and not
    expired
  - Entra accepting the certificate
  - the required permissions with admin consent
  - the settings saved

  Under the first step that isn't done, it says what to do next.

### Changed

- **Background steps no longer look like malware to endpoint
  protection.** Every background PowerShell started with an
  unreadable `-EncodedCommand <base64>` command line, which Cortex XDR,
  Defender ASR and similar tools block or report. This covered pipeline
  steps, module checks and the module installer. They now run
  `powershell.exe -File <app folder>\code\Runner\Invoke-AppStep.ps1
  -Spec <file>.json`, a file that ships with the app. The JSON file says
  in plain text what to run and is deleted as soon as it's read. No
  script runs from `%TEMP%` any more: the Graph helper sits next to the
  step script in the app folder, and the module installer is no longer
  written to a file at all.

## 1.7.0

### Added

- **PowerShell module conflicts are named, with a restart.** When a
  module already loaded in the app's window (usually Az,
  ExchangeOnlineManagement, PnP or an older Microsoft.Graph, from the
  PowerShell profile) brings different versions of the libraries
  Microsoft Graph needs, sign-in used to end in a .NET error such as
  "RefreshCacheAsync ... does not have an implementation". Test
  connection now checks for this first. Any Graph sign-in in the window
  that fails this way also gets the check. It names the module in the
  way and offers to restart the app without the profile.
- **Error and status texts can be copied.** Right-click any text in a
  window, such as the result under Test connection or a check's status,
  and choose Copy.

### Fixed

- **Diagnostics opened from Settings checked the old connection.** With
  a new certificate or Client ID not yet saved, it checked the old one
  and reported it missing. It now offers to save the changes first.
- **A sign-in from before granting permissions kept being used.** The
  app's lookups reuse one Graph sign-in. After Test connection ran
  without permissions, that sign-in stayed in use with a token that had
  no permissions, for up to an hour, and Intune answered 401. Test
  connection no longer leaves its sign-in behind. Saving settings,
  running Diagnostics and changing the certificate all start a fresh
  sign-in, and a 401 now names the missing permission.

### Changed

- **Missing permissions come with the fix.** Test connection and
  Diagnostics list what already works and each permission still to add,
  marked as required or optional with what it's for. They also give the
  path in the Entra admin center (Application, not Delegated), the
  admin consent step, and what to check when a permission shows as
  granted but still doesn't work.
- **Clearer certificate sign-in errors.** A certificate that isn't on
  this machine any more, and one that Entra ID doesn't accept (usually
  not uploaded to the app registration yet), each get their own
  plain-language explanation and not the raw .NET error.

## 1.6.0

### Added

- **Choose how Winget apps install.** "Edit default values" has an
  "Install with" setting: Winget-AutoUpdate (Winget-Install.ps1, as
  before) or the Winget command, which calls winget.exe directly and
  needs nothing else on the device. It decides the install and
  uninstall commands a Winget app gets by default. Apps that already
  have saved commands keep them.
- **Switch existing apps too.** Right-click apps → "Change install
  method..." (or "Install with" in Batch edit Intune fields) moves them
  between Winget-AutoUpdate and the winget command, each with its own
  Winget ID, and pushes the change to Intune - or to the catalog only.
  The confirmation says how many switch; an app whose commands were
  edited by hand keeps them, and the log says so.

## 1.5.0

### Added

- **Checks is one run and one list.** It used to be eight tabs - Sync
  check, App IDs, Audit, Metadata sync, Dependencies, Catalog groups,
  Winget packages, Diagnostics - most answering part of the same
  question, each reading Intune on its own. Now "Run checks" reads
  everything once and lists every problem in one place: how the catalog
  lines up with the apps in Intune (not in the catalog, renamed, App ID
  gone, App ID not set), each deployed app's metadata, groups,
  dependencies and assignments, the catalog's own dependencies, its
  groups against Entra ID, and its Winget IDs ("Skip Winget IDs" leaves
  out the slow part). Each row says what the catalog has and what the
  other side has; the buttons under the list are the fixes for what is
  selected - Pull, Push metadata, Push groups, Add to catalog, Set,
  Choose or Clear App ID, Use Intune's name, Open app, Find Winget ID,
  Re-check. "Show" narrows the list to one area. It opens on what is
  already known (the last audit, the catalog's own dependencies), in
  italics, and still keeps the Last Audit column up to date.
- **Diagnostics is in Settings** ("Run diagnostics..." on the Connection
  tab) - it checks this machine's setup, not the catalog.
- "Get apps from Intune..." on an empty catalog and the grid's "Run
  audit..." open Checks and start straight away; "Pull metadata and
  groups from Intune..." opens the pull itself again.

- **Supersedence, under Dependencies on Requirements and behaviour.** Pick
  the Intune apps this one supersedes - usually an older version that
  only exists in Intune, so the picker lists Intune's apps as well as the
  catalog's - and whether it updates them or replaces them (uninstalling
  the old app). Saved in the catalog by App ID, sent by Deploy, Push
  Metadata and the batch windows, read back by Pull from Intune, and
  compared by Checks and the Local vs. Intune compare. An app that has
  never recorded its supersedence keeps whatever Intune has on an update,
  and isn't reported as different until it does.

- **App version and "Show this as a featured app in the Company Portal"**
  - the two app-information fields Intune has that the catalog didn't.
  Both are on the Metadata tab (App version beside Publisher), saved to
  the catalog, sent by Deploy, Push Metadata and Batch Deploy, read back
  by Pull from Intune, and compared by Checks and the Local vs. Intune
  compare. Batch Edit can set Featured app on several apps at once.
  A blank App version leaves Intune's value alone, like the other
  optional fields. A catalog entry saved before these fields existed
  isn't reported as different by Checks until it has them (a Pull or a
  save fills them in), and an App version on its own doesn't mark an app
  as Custom Config.

### Fixes

- **Updating an app no longer deletes its supersedence.** Intune keeps an
  app's dependencies and supersedence in one list, and setting
  dependencies replaces that whole list - so every Update or Push
  Metadata from here removed any supersedence set in the Intune portal.
  The app's current supersedence is now read first and sent back with the
  dependencies; if it can't be read, the dependency step is skipped
  rather than risk removing it. **If an app of yours had supersedence and
  was pushed from an earlier version, check it in the portal - it may
  need setting again.**
- **Deleting an app that another app depends on keeps that other app's
  remaining relationships intact.** Clearing the blocking dependency
  resent every other relationship as a dependency, supersedence and
  other apps' entries included.
- **Closing the app editor warns about unsaved edits on its Intune
  tabs.** Cancel, the window's X and Previous/Next only asked about the
  Catalog tab's fields, so metadata typed on the Deploy tabs was
  discarded without a word.
- **Batch Edit accepts a change made only on its "Description and
  commands" tab.** Ticking just Publisher (or any text field, or Install
  context) was refused with "Check at least one field to change".

## 1.4.9

### Added

- **Filter the grid by problem** - Has a problem, Differs from Intune,
  Not deployed, Package missing - beside the search box. Copy App ID is
  on the right-click menu.
- **Push metadata from more places.** The main grid's right-click menu,
  the audit's results and the Last Audit window (now a small window with
  Pull from Intune, Push groups and Push metadata, not a message box).
  For one app it opens the app editor on its Deploy side, the compare
  starting on the catalog's values; for several, one window compares
  them with Intune and pushes the ticked ones.
- **The audit says what to do about a difference, and does it.** It
  offers both Pull and Push, with Select all that differ; Push is split
  into Push groups and Push metadata. It opens with the last known
  results and how old they are, and Re-check selected audits just those.
- **Group differences say which side has which groups**, in the audit,
  Last Audit and the app editor. The editor's Assignments tab compares
  its groups with Intune the first time it opens.
- **A Package location card on the app editor's Catalog tab** - the
  resolved package, whether it was found, Open folder and Copy path -
  replacing the grid's Package folder column.

### Fixes

- **Metadata typed in the app editor's Deploy tabs is saved to the
  catalog.** Publisher, Owner, Developer, the two URLs, Notes and every
  other field there were only written by a successful deploy - "Save app
  to catalog" kept whatever metadata was already on file and never read
  those tabs, so values entered without deploying were lost. It now saves
  them whenever one was changed by hand (checking them first, the same
  way "Save local copy..." does); an app nobody edited there keeps its
  metadata exactly as before.
- **A new app no longer deploys with "Package file not found: ...\App.intunewin".**
  "Add app..." builds the Intune tabs before the app has a name or a
  Winget ID, and an empty name resolves to `App`. The tabs only caught
  up when a field lost focus or you switched tabs, so an ID picked with
  "Search winget..." left a Winget app looking like a custom one (no
  commands, no detection, no init.intunewin) until you opened Package
  and detection - and a custom app's package never followed its name at
  all. Deploy now catches the tabs up on the name, Winget ID and package
  path itself before it checks anything, and the search does it at once.
- **The package path set in the app editor is the one Deploy uses.** The
  Intune tabs, and Deploy from the grid, worked the path out from the
  app's name and ignored the one stored for it.
- **Saving metadata no longer forgets an app's package path.** Deploy,
  Push Metadata and "Save local copy..." rebuilt the catalog entry
  without it, as did "Delete from Intune" and exporting the catalog as a
  template - so a package kept somewhere its name doesn't predict had to
  be picked again.
- **Deploying from the grid after changing the display name no longer
  duplicates the app in the catalog.** The result was saved under the
  display name sent to Intune rather than the catalog entry's own name,
  so it landed as a second entry, and the original was then renamed to
  match - two entries with the same name and App ID.
- **A failed read of an app's groups no longer looks like "no groups".**
  Pull groups from Intune used to untick every group and report a match;
  a group name Intune can't resolve no longer shows as a difference or
  gets its ID written into the catalog.
- **Closing the Local vs. Intune compare before an update doesn't send
  it.** From Push metadata, Cancel used to send Intune's own values back
  and save them into the catalog.
- **Last Audit keeps a time per check**, so a partial check no longer
  makes old results look fresh; batch Push metadata no longer marks
  unchecked fields as OK.

### Polish

- The grid drops the Uncommon and App ID columns and counts groups in one
  column; fixed-length columns are sized once to their longest value.
- "Update Metadata" is called Push Metadata, as everywhere else.
- A status with good news plus a note is no longer shown in warning
  orange.
- The audit's buttons stay in place on the Checks tab.
- The release zip holds only what runs the app.

## 1.4.8

### Fixes

- **An app imported from Intune now gets its Winget ID, Type and
  Version.** Type and Version came back with the same fetch that reads
  everything else and were being dropped, which is why an imported app
  showed those columns blank. The Winget ID is not an Intune field at
  all, so it is read out of the install command - an app deployed
  through Winget-Install.ps1 carries `-AppIDs "Some.App"`. That decides
  whether the app is treated as a Winget app or as an uncommon one
  needing its own .intunewin, so it is worth more than a filled column.
- **The Winget ID read back in 1.4.7 could include the command's
  arguments.** A real command puts them inside the same quoted string -
  `-AppIDs "Adobe.Acrobat.Reader.64-bit --scope machine --override "` -
  and the whole string was taken as the ID. It is the first token; an
  identifier never contains a space. **If you imported apps with 1.4.7,
  check the Winget ID column: any value containing a space was stored
  wrong and needs correcting by hand.**
- **The Type/Version backfill could only run once per session.** Its
  guard meant "already ran" and was set even when it found nothing to do,
  so on a complete catalog - or an empty one about to be filled from
  Intune - it was spent seconds after launch and could not run again
  until a restart. Anything arriving afterwards without a type kept blank
  columns: an App ID attached by "Look up App IDs", an app added in the
  editor, an import whose fetch failed. The guard now means "a queue is
  running", so Reload picks up whatever is still missing.

## 1.4.7

### Added

- **An empty catalog can be filled from Intune.** Pointing this at a
  tenant that already has apps in it and starting from nothing is an
  obvious first move, and the empty-catalog screen offered three buttons,
  none of which was it. No new function - the sync check has always
  listed what is in Intune with no catalog entry and added the ones you
  tick; it just lived on a tab of the Checks window, which is not where
  anyone looks when the question is "how do I start".
- **Settings > About**, with the version, the copyright line, the
  GPL-2-or-later notice and warranty disclaimer, links to the site,
  source and licence text, and what is third party. The version used to
  be answerable only from the window title.

### Fixes

- **An app added from Intune arrives whole.** Adding one calls the same
  fetch that reads the ENTIRE app - description, publisher, install and
  uninstall commands, architecture, run-as account, detection rule,
  minimum OS, requirements, install experience, return codes, groups and
  dependencies - and then stored none of it, telling you to fill it in
  by hand afterwards for information the tool had just been handed. Same
  Graph call either way; only the keeping was missing.
- **Dependencies are no longer lost on import,** as one casualty of the
  above, and the one that matters most: deploy order, the dependency
  overview and the audit all read that list. An app whose dependency is
  not in the catalog is now offered rather than left half-imported -
  "what you added depends on 2 app(s) that are not in this catalog ...
  add them too?" - and answering yes catches dependencies of those too.

### Polish

- **The two "add" buttons in the sync check no longer read as a pair.**
  One acts on the tick boxes, the other on the highlighted row, and they
  produce different things. The single-row one is "Review and add..."
  (it opens the editor with the app filled in); the bulk one is "Add
  ticked to catalog" and carries the count. Rows that cannot be ticked
  no longer show a tick box that refuses the click.
- The Deploy button says whether the groups go with it - "Update
  Metadata (Including groups)".
- On the empty-catalog screen, "Getting started..." moves to the end, so
  the buttons that actually fill the catalog sit together.
- A dialog that is busy when the GUI suite tries to close it is no
  longer reported as one that refuses to - test harness only, no app
  behaviour.

## 1.4.6

### Added

- **Deploy can assign the app's groups, instead of stopping at the
  upload.** An app with groups in the catalog used to go live in Intune
  assigned to nobody, and the second step was a separate window you had
  to know to open. Two settings under Settings > Automatic checks decide
  it, and they differ on purpose: a NEW app has no assignments to
  overwrite, so this is on; an UPDATE replaces the app's entire
  assignment list, so a group somebody added in the Intune portal would
  disappear because an install command was edited here - off unless you
  ask for it. The Deploy button says which it is doing ("Update Metadata
  including groups"), so it is never a surprise.
- Groups are assigned but never **created** this way. A name in the
  catalog that does not exist in Entra ID is reported and nothing is
  assigned, rather than a typo quietly becoming a real directory object.
  "Push groups to Intune..." still creates them - there you can see it
  happen.
- **Diagnostics reports every Graph permission**, not only the ones that
  run happens to need. Its checks probe what they use, so a missing
  permission for a feature they do not touch stayed invisible until it
  failed - platform scripts especially: everything passed, then the
  first Save took a 403. It now reads the app registration's own token
  and lists every feature, the same way Settings' "Test connection"
  does.
- The catalog's **Uncommon** column also flags an app pointed at a
  hand-picked .intunewin. It installs from that package rather than the
  shared winget wrapper, which is what the column exists to say, but
  having a Winget ID used to hide it. Status says why ("Custom
  package").

### Fixes

- **One app with no assignments in Intune broke the whole Unknown
  Assignments check** with "Index operation failed; the array index
  evaluated to null". An app with nothing assigned produces an empty
  set, PowerShell returns an empty array as `$null`, and the comparison
  then indexed a hashtable by a null key. A single app was enough to end
  the run for every app in it. The same fault could have sent an empty
  assignment body when pushing groups.
- **A check that had stopped kept saying "(checking...)".** The audit
  runs two fetches; if one failed it wrote its error to the status line
  and stopped, and then the other one finished and overwrote that error
  with a green "Audit complete" - over a column still reading
  "(checking...)" for every row. Failures are now reported at the end,
  every abandoned cell says what actually happened, and a run you stop
  yourself goes back to "(not checked)" rather than claiming to have
  failed.
- **The audit reported a detection rule as differing when it was
  identical.** The catalog keeps every detection field the editor has a
  box for, so a File rule switched to "exists" still carries the
  operator and value from before. Those two are never sent for "exists"
  - Intune has no such concept there - so the comparison flagged two
  fields neither side can act on, permanently, with nothing you could do
  about it. Also affected Registry/"exists" and MSI with no version
  operator.
- The Checks summary counted a check that **failed** as an app that
  **differs**, so "3 app(s) differ" could mean "3 app(s) we could not
  ask about". Those are reported separately now.
- Catalog groups reported every row as not found in Entra ID, rather
  than the rows that actually were.
- The orphan-folder check no longer flags a folder an app deliberately
  points at.

### Polish

- Button sizes follow one scheme across the app, now checked by a test:
  32px for a dialog's footer and primary actions, 30px for a wide
  stacked button, 26px for a small one attached to a control. Seven
  dialogs had "Select all" and "Select none" side by side at different
  widths.
- "Remove group from apps" and "Add favorite to apps" had 6px between
  the app list and the first button and 12px of bottom margin, which
  read as crowded rather than deliberate.

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
