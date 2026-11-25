# Changelog

## 2.38.43

The larger follow-ups from the 2.38.42 sweep:

- **Release flows run on the server**: Release, Promote, Withdraw, Next ring
  and Roll back are one action each - the server runs their steps one after
  the other and records the result in the catalog. Before, the page started
  each step; a reload or a closed tab in between left Intune changed and the
  catalog behind. The app stays reserved for the whole flow, and taking the
  groups off the old release only touches the release that was current when
  the flow started.
- **Steps survive a restart**: a running step is written down, so after a
  restart of the app or the server (a container update) it is finished -
  App ID saved, release recorded - instead of lost. One whose result is gone
  is named in Activity.
- **"Sent" is what was sent**: Changes to send records the values a send
  started with - an edit saved while it ran stays a change to send.
- **Store apps and Microsoft 365 Apps** send owner, developer, notes and the
  Featured flag too. Microsoft 365 Apps' own settings (channel, apps left out,
  ...) are compared in Checks and can be pulled.
- **Promote keeps the app's Featured flag and supersedence**: a new release is
  created with them, not only superseding the current version.
- **Pull review**: an app changed since the review (a promotion, a send, an
  edit) isn't overwritten with the older values - it is named, to pull again.
- **Server version**: when the server can't be reached (it restarts after an
  update) the page says so and carries on once it answers - instead of asking
  to start a script that doesn't exist there.

## 2.38.42

A sweep for "the page offers it, then it fails" and "sent, stored and compared
don't agree":

- **Own packages with a script detection rule** (any uploaded .exe) can be
  released - every release was refused before ("doesn't check for X").
- **New installer for a managed app in Intune**: the editor's upload takes it
  again (into its folder only), and offers Release new version, which builds
  and sends it pilot first. The messages that pointed elsewhere are fixed.
- **No pilot groups, every path**: the nightly run's own-package release and
  its retry of an unassigned pilot went to a pilot assigned to nobody - they go
  to everyone now. A pilot or ring step with no groups, and a promote or
  rollback of an app without groups, are refused instead of leaving it
  assigned to nobody.
- **Releases**: checked again once the app is reserved (no second pilot app
  when the nightly run and you release at once); not while the app is being
  retired; a retirement includes a version in pilot.
- **Steps that ran but couldn't be saved** (the App ID, the release) count as
  failed, not "Done". A step finished by another page (a second tab, another
  admin) still tells the page that started it how it ended.
- **Sends that bypassed the queue** (batch edit, switching the winget command,
  CSV import, Checks stages) wait for a running send instead of failing with
  "sent for 0 of N".
- **Menus say what the server would refuse**: Send settings and Package are
  hidden for Intune's own non-Win32 apps (and refused on the server), Duplicate
  for Microsoft 365, Retire's Uninstall is disabled with the reason (a pilot,
  apps that depend on it), Roll back no longer needs managed updates, Delete old
  versions counts rolled-back versions and names them, and Check winget works
  when only own packages watch winget. The Send to Intune plan says up front
  when a Store or Microsoft 365 app is linked to a type it can't become.
- **Compared like they are sent**:
  - Detection scripts with non-ASCII text no longer get a second BOM after a
    Pull and a send (PowerShell failed on it, so the app was never detected).
  - Architecture order (x64,x86 vs x86,x64), install context case and minimum
    OS spelling no longer show as differences; install context and minimum OS
    are now compared and offered in Pull instead of replaced silently.
  - No return codes in the catalog equal Intune's five defaults.
  - Sending an app without settings of its own keeps Intune's Featured flag
    and supersedence recorded as unknown, not as off / none.
  - Keeping an empty field in Pull marks it cleared, so the next send empties
    it in Intune.
  - Dependencies on a rolled-back release are named back to the app; deleted
    releases leave the catalog's supersedence.
  - Release assignment steps no longer mark the app's groups as sent.
- **Add apps**: a batch that failed is named in the summary instead of
  disappearing with the dialog.
- Wording: Settings paths and menu names that had moved.

## 2.38.41

- **Release to everyone works**: without pilot groups the server still refused
  the release ("Set the pilot groups first") although the dialog offered
  "Release to everyone" - it goes through now. The dialog's text names the
  version and leaves "(pilot)" out when there is no pilot.
- **GUI review**:
  - Send windows: they no longer stretch to the tallest one, the stack scrolls
    instead of covering the list, a waiting one can be closed (it is taken out
    of the queue), they stay usable over an open dialog, and a sent one still
    closes by itself after the pointer leaves it. Error messages show above
    them and aren't pushed away by a plain note.
  - Counts read "1 app", "3 apps" everywhere (Home, Checks, Diagnostics, the
    logs) - no more "app(s)"; "1 field differs", "2 fields differ".
  - "Send" throughout, where some texts still said Push or deploy.
  - Recent changes names the remaining sources in words (Remove from catalog,
    Installer upload, Packages folder, Duplicate, ...).
  - Empty values read "(empty)" everywhere, values not kept "(not recorded)".
  - Checks: the Area labels and fix buttons are one width; when not connected
    it says "Not connected - only the catalog was checked", with one blue button.
  - Settings > About: the folders use the full width and long paths break at
    their separators; a version newer than the latest release says so.
  - Settings > Updates: label and unit on one line, number fields sized for a
    number. The nightly run's results show their outcome in words.
  - Apps: longer names before they are cut on wide screens; the toolbar says
    "Send to Intune (2)" like "Send groups (2)" and keeps its width.

## 2.38.40

- **Release without pilot groups**: with no pilot groups set, "Release new
  version" was greyed out. It now says "Release to everyone": the new version is
  created, gets the app's groups and replaces the current one at once. The
  nightly run does the same - before, it released to a pilot of nobody.
- **Recent changes reads better**: the source is said in words ("Send to
  Intune", "After the send" - not "This app (deploy-start)", "Step result");
  "Send settings" as on the buttons, without repeating the app's name; field
  names in one spelling ("Return codes"); return codes as what was added and
  removed instead of two lines of JSON; the Intune mark on every line that
  changed Intune (it showed only on the opened ones); "8 apps" instead of
  "8 app(s)".

## 2.38.39

- **One window per send**: each Send settings / Send groups gets its own small
  window, side by side in the bottom right corner - the newest left of the
  others. Each says Waiting, Sending..., Sent or Failed and has its own log;
  a sent one closes by itself after a while, a failed one stays to be read.
  They still go to Intune one after the other.
- **Apps that update themselves**: browsers and meeting apps (Chrome, Firefox,
  Edge, Brave, Zoom, Teams, Webex, Slack, ...) keep themselves current on the
  device, so pinning their version only brings "can no longer be downloaded"
  and weekly releases. They are known now: added from winget they stay on
  winget's latest even when managed updates are the default, Home no longer
  lists them as "without managed updates" and "Turn on for all" leaves them
  out. The editor has "Updates itself" for any Winget app, and says so when
  such an app has managed updates on.
- **Microsoft 365 Apps: Send settings failed with "Property is read-only:
  'Publisher'"**: an existing app's publisher is Intune's own - it isn't sent
  any more when updating, and should Intune name another read-only property,
  the update is tried again without it.

## 2.38.38

- **Managed apps no longer differ for good after "Send settings"**: a managed app
  is sent pinned to its version, with the detection script and return codes as
  this version writes them (new in 2.38.34) - but the catalog file kept the
  older form, so Checks kept reporting "Detection rule, Return codes" differ
  right after a successful send. Checks now compares a managed app as it is
  sent, and a send writes that form into the catalog too.
- **Send settings from Checks queues too**: like on the Apps page (2.38.37), a
  Send settings clicked while another send runs waits its turn instead of being
  refused; the findings are checked again once it is sent. The tray says which
  app is being sent now and which come after.

## 2.38.37

- **Send settings / Send groups queue up**: clicking another app's "Send
  settings" (or "Send groups") while one is still being sent lined nothing up -
  it was refused with "Another action is still running". Now it is queued (once
  per app) and sent right after, one app after the other; the toast at the end
  says what was sent and what wasn't.
- **Stage column**: the next-step buttons beside the stage (Send settings,
  Checks, Edit, ...) are one width, so they line up like the stage labels.

## 2.38.36

- **"Changes to send" no longer shows "(blank)" for what Intune does have**: an
  app sent while it had managed updates doesn't keep its version, commands,
  detection and return codes in the send record (its releases carry them).
  When managed updates are off later, the card showed those fields as blank in
  Intune; it now says "(not kept at the last send)".
- **A pinned version that can't be downloaded any more is replaced by itself**:
  winget keeps only recent versions, so a managed app pinned to an older one
  (e.g. Chrome) can't be installed on new devices. The nightly run now releases
  winget's current version to pilot for such an app even when automatic release
  is off or the release window is closed - through the pilot as always, never
  straight to everyone; a version withdrawn before isn't used.
- **Home**: the buttons in "Needs attention" are one width and line up. The
  message for a pinned version winget no longer offers says the nightly run
  replaces it, and how to do it now.
- **Backups (server)**: backup-ica.sh (also run by update-ica.sh) no longer prints
  "socket ignored" for the running app's scratch folder - it was harmless (the
  sockets aren't data), the folder is now left out entirely.
- **Settings > Packaging and Diagnostics**: one card per row, full width (the
  Activity log reads better wide; on the server Packaging stood alone at half
  width).

## 2.38.35

- **The "what changed" card stays open to be read**: the card that opens when
  pointing at "Changes to send" (and at a finding's fields in Checks) closed as
  soon as it was clicked and scrolled - its own scrolling counted as the page
  scrolling away. Clicked into, it now stays open while it is scrolled (wheel,
  arrow and page keys) and when the pointer leaves it; a click elsewhere or Esc
  closes it.

## 2.38.34

A full review of the app: what runs on the devices, what is sent to Intune,
security, logic, the screens, and the server and release setup.

- **Settings > About**: the version, where it runs (desktop or server),
  PowerShell and the system, the folders, a "Check for updates" button and the
  project's pages (GitHub, changelog, report a problem, security policy,
  license). "Copy details" copies what a bug report needs.

**On the devices**
- Detection scripts with letters outside ASCII in the app's name (é, ü, Ñ) no
  longer break on Windows PowerShell 5.1 - the name is written as \u codes,
  and a script that still has such letters goes up with a BOM.
- Managed updates: an older build no longer counts as installed. The version
  compare ignores a word before the version ("ad 8.1.0") and counts a
  pre-release as older; the Uninstall entry alone is enough only for the exact
  version (a newer one only while winget isn't there yet or can't list the
  installed apps).
- "Installed" detection compares part by part - "24", or five-part versions,
  no longer fail - and looks at the user's Uninstall entries too.
- The generated Uninstall.ps1 reads an unquoted uninstaller path with spaces
  ("C:\Program Files\App\uninst.exe /S").
- winget's own exit codes are mapped: "another install in progress" is Retry,
  "already installed" and "no applicable update" are Success (detection
  decides), "restart required" is a soft reboot. Managed apps get them the next
  time their settings are sent.
- The script-app installer template writes its version marker after exit 1641
  too.
- Detection from an app on a PC: a per-user install's path is written with
  %LOCALAPPDATA% / %APPDATA% (not the technician's profile), and it says to
  install it for the user.

**Sent to Intune**
- Fields emptied in the catalog reach Intune: when Owner, Developer, the links,
  Notes or App version is emptied (in the editor, Batch edit or a CSV import),
  the next send empties it in Intune too (before, Intune kept the old value and
  Checks showed it as a difference for good). A field the catalog never had is
  still left alone, so what was set in the portal stays. Microsoft Store apps:
  the two links (their type takes no owner, developer or notes from here).
- Minimum OS: Windows 10 up to 21H1 is sent as Graph expects ("1607" ...
  "21H1", 20H2 as "2H20") - "Windows10_1607" was refused with a 400. Take from
  Intune reads today's property (Windows 11 values too), and an empty minimum
  OS no longer clears Intune's. Windows 11 23H2 and 24H2 are offered.
- Replacing a package uploads it first, then changes the settings - a failed
  upload no longer leaves new detection rules on the old package.
- Packages over 2 GB upload (read block by block).
- Updating a Store app no longer blanks links and texts set in the portal.
- Assignments and relationships are read page by page; withdrawing a release
  leaves a relationship list it couldn't read fully alone.
- Removing supersedence in the catalog now reaches Intune, and "not set"
  supersedence keeps what was set in the portal.

**Checks and Take from Intune**
- Take from Intune no longer wipes the catalog's dependencies and supersedence
  when Intune's couldn't be read, and doesn't store a promotion's old release.
- Assignment filter and exclusion differences are one row per app, are kept in
  the last audit (Home and the Apps list show them), and a filter name with
  brackets is read right.
- A new App ID is saved even when the catalog was busy (retried), and logged if
  it still can't be.

**Security**
- Package files are never deleted or replaced through a link, and clean-up
  removes links as links.
- The icon finder only reads public addresses (also after redirects).
- The PSADT template needs GitHub's SHA-256, and the toolkit's own scripts must
  be signed too.

**Screens**
- The editor's checklist asks for the Winget ID (or Store ID) when that is
  where the app installs from, not for an installer.
- Checks: no empty band, a "!" icon and "Set up the connection" when not
  connected. Home says "Setting up" until the guide is done.
- "1 app" / "3 apps" instead of "app(s)"; ID and command fields keep the
  monospace font, other fields don't; radio buttons look right in the dark
  theme; Add apps tabs stay on one line when narrow; the Updates empty state has
  an "Open Apps" button; Platform scripts says "3 scripts"; the editor's
  release rule sits right under its heading.

**Server and releases**
- Settings > Folders on the server only takes folders inside /app/data.
- deploy-ica.sh: a host name or image given on a re-run replaces the old one;
  a failed pull no longer builds and labels the checkout as the release
  (BUILD_LOCAL=1 builds it as a local image).
- update-ica.sh pulls the release's image or stops, and says how to restore the
  backup when it goes back.
- The release zip has the LICENSE; test builds are pre-releases; the image is
  only published after the release's version check.
- README: the permissions match what the app checks (no Directory.Read.All).

## 2.38.33

- **Search in "From a list"**: Add apps > From a list has a search box - name, ID,
  category or what the app is for (e.g. "pdf", "vpn", "lenovo"). "Select all"
  ticks only what the search shows.
- **No false findings after a promotion**: the new release superseding the old one
  and apps that depend on "<name> <version> (superseded)" are no longer reported as
  differences. "Send settings" keeps the update path to the app's own earlier
  releases instead of removing it.
- **Leftover release names**: an app still called "<name> <version> (pilot)" in
  Intune (the rename at promotion failed) is reported as such, and "Send settings"
  puts the catalog name back - before, the only offer was to take the pilot name
  into the catalog.
- **"Possibly in Intune"** no longer offers another app's old release or a
  "(superseded)"/"(pilot)" copy as a match.
- **Assignments compared in full**: a different assignment filter now shows as
  "Assignment filter differs" (was an unknown assignment), and an exclusion the
  catalog has but Intune doesn't shows as "Exclusion missing in Intune" (was not
  shown at all). A group whose name can't be read is named in the log instead of
  quietly showing as an unknown ID.
- **Withdraw**: when deleting the pilot from Intune fails, the release is kept as
  rolled back and unassigned, so it isn't lost track of.

## 2.38.32

- **Checks kept showing one app only**: after "Checks" for one app (Apps list,
  Microsoft 365, ...), the "Only <app>" filter stayed when Checks was opened again
  from Home or the menu - "0 finding(s)" while other apps had some. Opening Checks
  any other way now shows every app, and with the filter on, the count says how
  many findings the other apps have.
- **Checks: "Winget no longer has this package" for Store apps** (Company Portal):
  Store product IDs were checked against winget's index, which doesn't have them.
  Store apps aren't asked of winget any more.
- **Checks review** (every kind of finding, for false alarms):
  - iOS, Android and macOS apps in the tenant are no longer "In Intune, not in the
    catalog" with Add to catalog - the catalog is for Windows, as the Apps page.
  - An App ID typed in capitals no longer reads as "not in Intune any more" (with
    Clear App ID offered).
  - A dependency list Intune couldn't be asked for is "could not check", not "Intune
    has (none)" - Take from Intune would have wiped the catalog's.
  - Store apps and Microsoft 365 Apps: no permanent "Dependencies differ" (those
    Intune types take none from here).
  - Nightly run: apps whose groups it pushed back are "fixed", no longer "differ
    from Intune" on Home; it never creates groups unattended (a mistyped group name
    made an empty one); Home reads the last full nightly run, not a fast-track run.

## 2.38.31

Full sweep (GUI alignment on every page and dialog, security, bugs).

- **Bugs**
  - Checks: one app's catalog file busy (another admin saving) while taking a Store
    ID from Intune no longer fails the whole detailed check (and the nightly drift
    check); the Apps list reloads when Checks changed an app.
  - Home "differ from Intune" now clears for Store apps and Microsoft 365 Apps too
    (Intune has no owner/developer/notes on those types), and Home no longer reloads
    the shared check results while a check is saving them.
  - A Store app whose Store ID was changed in the catalog: Send to Intune says that
    Intune can't change an app's Store product (it reported "updated" and nothing
    changed).
  - Stage: an app with only Uninstall or Excluded groups is "no groups" - nobody gets it.
  - Microsoft 365 extra languages: "de" or "fr" alone is refused with a hint (de-de,
    fr-ch) instead of silently dropped.
- **Security**: uploads into a package folder check every folder on the way for links
  before anything is deleted or written - Replace emptied a linked folder's target
  first, and a link higher up the path wasn't seen. Uninstall.ps1 is never written
  through a link.
- **GUI**
  - Add apps: "Fill in by hand..." on the tabs' baseline (with or without a
    scrollbar); the tabs wrap on narrow windows instead of hiding "From a list";
    focus rings no longer clipped; notes and labels in the same size as around them.
  - Dialog window controls level with the title; messages show at the top while a
    dialog is open (they covered its buttons).
  - Group fields as high as the inputs beside them; menu headings in line with their
    items; equal row heights in the Apps list; the icon placeholder as high as its
    buttons; Recommended apps' ticks on the first line; wider names on narrow screens.

## 2.38.30

- **Store apps read from Intune keep their Store ID**: an app that is a "Microsoft
  Store app (new)" in Intune (Company Portal, say) came into the catalog as "Its own
  installer" - Intune's package ID wasn't taken over. Add to catalog and Read from
  Intune now take it as the Store product ID, and Checks takes it over for apps
  already linked (with an entry in the app's history).
- Add apps: "Fill in by hand..." sits on the tab row, not above it.

## 2.38.29

- **Home: "app(s) differ from Intune"** came from the last nightly run and stayed
  until the next one - even when Checks, run later, found everything as the catalog
  says. An app Checks compared since that run and found in order is no longer
  listed there.
- **Company Portal (and any Store app) linked to another app type** in Intune (the
  legacy Store app, a Win32 package): Send to Intune says to clear the App ID and
  send it again (the Store app is created new) instead of failing in Intune. The
  editor's "Use Store ID" item says what it changes: the catalog only - nothing on
  devices.
- Apps list: every stage label the same width.

## 2.38.28

- **Stage says what is true for the devices**: "Released 24.09" (managed updates,
  every ring has that version), "Deployed" (in Intune for its groups), "Update
  25.01" (winget has a newer version - Release... next to it), and "In Intune - no
  groups" (warning) instead of "Everyone" for an app no group gets. Pointing at it
  says which groups have which version.
- Editor: no small scrollbar beside the tabs any more.

## 2.38.27

- **Microsoft 365 Apps: Send to Intune failed** with "A valid office default file
  format version must be selected" - Intune requires the default file format. It
  is now sent as Office Open XML (.docx, .xlsx, .pptx), as Intune's own page sets it.

## 2.38.26

- Recommended apps: Lenovo Commercial Vantage taken out again (its Store ID wasn't
  confirmed); Lenovo Vantage (9WZDNCRFJ4MV, confirmed in the Store) stays.

## 2.38.25

- **Recommended apps**: Snapform Viewer (Ringler.SnapformViewer - Snapform forms,
  .qdf) in Files and documents, and eDrawings Viewer (SolidWorks.eDrawings - CAD
  drawings and 3D models without a CAD licence) in Media and design.
- **Device vendor tools** (a new group of recommended apps): HP Support Assistant,
  HP Image Assistant, Lenovo System Update and Dell Command | Update (winget), and
  Lenovo Commercial Vantage and Lenovo Vantage (Microsoft Store apps).
  Store apps picked from the list are added with their name (winget has none for them).
- Apps list: "Ready - no groups" without the Groups... button next to it - who gets
  an app is set in the editor or the side panel.

## 2.38.24

- **Add apps > Microsoft 365**: a tab of its own for Intune's Microsoft 365 Apps -
  name, update channel, architecture, extra languages, the apps installed, remove
  older Office, shared computer activation (the usual settings filled in), with
  the dialog's groups. Add and send works too (nothing to build). One per catalog:
  when it is there already, the tab says so with Open it.

## 2.38.23

Full sweep (security, bugs, usability).

- **Microsoft 365 Apps**
  - Ticking every app and saving kept the default exclusions - "no app left out" is
    now kept. A minimised editor opened again no longer loses its Microsoft 365
    settings on Save.
  - An app linked to Intune's own Microsoft 365 Apps reads its settings from Intune
    when switched to "Installs from Microsoft 365", so the next send doesn't
    overwrite the tenant's channel, languages and apps with the defaults.
  - Linked to another app type in Intune (an Office Deployment Tool package as
    Win32): Send to Intune says to clear the App ID instead of failing in Intune.
  - Defaults now also leave out Visio (needs its own licence) and Publisher
    (retired); Publisher and Microsoft as publisher/developer are filled in.
  - Not shown as an "own package not built" on Home; can't be duplicated (one per
    catalog); languages like sr-latn-rs are kept; Managed updates on says why it
    doesn't apply.
- **Company Portal** linked to the legacy Store app: the one-click fix creates the
  new Store app instead of sending a body the legacy type can't take; an app
  packaged on purpose is left alone.
- **Editor**: the Install & detection tab is hidden only for apps that really are
  Intune's own types - an app merely named like Office keeps it. No Managed
  updates checkbox for Store apps.
- **Security hardening**
  - "Previous version" of a package file could load another app's copy when names
    had underscores - copies are now kept per app.
  - Saving and Previous version keep the 256 KB limit of opening a file.
  - A file in the ANSI code page refuses characters it can't hold (they became "?").
  - Uploads into a package folder keep a copy of each file they replace (Backups)
    and never write through links.
- **Usability**
  - One name per action: "Pin newest" / "Pin winget's newest version", and
    "Build package" everywhere.
  - The menu no longer offers managed updates or releases for Store and Microsoft
    365 apps; greyed-out menu items look greyed out.
  - Checks that couldn't compare everything no longer show the green all-clear.
  - Home doesn't offer winget details for Store apps; Starter set shows "Intune's
    Office app" and "Store 9WZDNCRFJ3PZ" instead of bare IDs.

## 2.38.22

- **Ready to send? for Microsoft's own apps** says what to do, with a button:
  Company Portal without its Store ID gets "Use Store ID 9WZDNCRFJ3PZ" (it is
  then sent as the Store app); an app named Microsoft 365 / Office gets
  "Install from Microsoft 365". No more "Missing: ... is Intune's own app
  type". A linked Company Portal is told the Store ID too.
- **Editor for Store, Microsoft 365 and Microsoft's own apps**: no Install &
  detection tab (no commands, detection, requirements or dependencies are sent
  for them) and no App version field - Microsoft or the Store keeps it.
  Details stay: description, publisher and links go to Intune.
- More room between the Name field and "Installs from".
- **Send to Intune...** in the app menu (right-click a row, or More...) - not
  only the button top right.
- The Apps list is faster with many apps: the "custom settings" check stops
  at the first difference and skips identical fields without normalising them.

## 2.38.21

- **Microsoft 365 Apps, made and changed in the app**: in the editor, Installs
  from > **Microsoft 365** sends it as Intune's own Office app (Microsoft 365
  Apps for Windows 10 and later) with its settings: update channel,
  architecture, extra languages, the apps installed (Word, Excel, ... - untick
  to leave one out), remove older Office first, shared computer activation.
  Sensible defaults: Monthly Enterprise Channel, 64-bit, the language of
  Windows, older Office removed, retired apps (Skype for Business, InfoPath,
  SharePoint Designer, Groove) and Bing left out. No package or detection - like
  a Store app; a change of its settings shows as "Changes to send".
- **Suggested apps (Add apps > From a list > Starter set)** start with
  Microsoft's own two: **Microsoft 365 Apps** (with the defaults above) and
  **Company Portal** (the Store app 9WZDNCRFJ3PZ). Either is shown as already
  in the catalog when it is - also when linked without a Store ID.
- The list's Source column says "Microsoft 365 Apps" for it, as "(Store)" for a
  Store app.

## 2.38.20

- **Checks said "Nothing to fix" too early**: when "Deployed apps in detail"
  was off, the settings and groups in Intune weren't compared, yet the page said
  "the catalog, Intune and Entra ID agree". It now says what wasn't compared.
  And the box no longer stays off after the check at start (when "full check at
  start" is off) - every later Run checks compares everything again.
- **Company Portal (and other Microsoft apps) linked to Intune** without their
  Store ID now show as "Microsoft (Intune)", not "own installer"; Home's "Fix
  Company Portal" sets the Store ID (9WZDNCRFJ3PZ) for a linked one too.
- **Editor: Installs from** Winget, Its own installer or Microsoft Store - the
  ID field only where it means something (none for an own installer), named
  "Winget ID" or "Store product ID". A new app starts on Winget.
- **Create last month's report** downloads the report (HTML) in the browser -
  on the server the Logs folder was out of reach.
- Upload review: room between "Setup file" and its dropdown.

## 2.38.19

- **Windows Sandbox test removed**: "Test in Windows Sandbox" (the app's menu,
  the side panel, the result dialog), its server download (the zip with
  Start-Test.ps1) and the upload of its result are gone - also the single-use
  /download/ link only it used. Folders earlier versions left for it in the
  user's app data are cleaned up at the next start. Test an app on a pilot
  device instead (a test group as Required).
- **Files next to the setup, in the editor**: dropping or choosing a single
  file that isn't an installer (login.xml, a .cfg) now puts it into the app's
  packages folder beside its setup - the setup file, the commands and the
  detection rule stay as they are (before: "Choose an .msi or .exe installer").

## 2.38.18

- **Detected by, chosen in Add apps > Installer**: besides the app's proposal,
  a file (exists, or version at least) or a registry value (key exists, or a
  value's version at least), each with "32-bit app" - right there, before the
  app is added. For an Inno Setup installer it starts on the registry rule with
  the `Uninstall\{AppId}_is1` key to fill in (DisplayVersion, at least the
  version). When nothing is proposed (a folder whose setup is install.ps1),
  "Add and send" waits until a rule is chosen - Intune takes no app without one.
- **Detection by the name Windows lists**: "apm system2 Version 2.1" now counts
  as "apm system2" in version 2.1 ("Version" / "Ver." before the number) - the
  proposed script would never have found it. Existing scripts keep working.
- **Several files at once**: dropping or choosing several files (the setup with
  its .xml, .inf, .cfg...) uploads all of them together, as one folder named
  after the setup file - before, only the first one was taken. Folders dropped
  along with them keep their subfolders. Also in the editor's upload.

## 2.38.17

- **Edit a package's text files in the app**: the file list on the editor's
  Basics tab has "Open" for every script and text file directly in the app's
  packages folder - .ps1 and now also .cfg, .ini, .xml, .txt, .cmd, .bat,
  .inf, .iss, .json, .reg and .config (e.g. an installer's SilentClient.cfg or a
  client's login.xml). They open in the code editor, with all of them as tabs.
  A text file is saved back exactly as it was written (ANSI, UTF-8 with or
  without BOM, UTF-16; Windows or Unix line ends) - an older setup reads its
  .ini only that way; an .xml must stay well-formed. As with scripts: only
  unchanged since it was opened, the earlier one kept in Backups ("Previous
  version"), the change in the history - and the package needs building again.
- **Packaging on the server said "failed" although it worked**: the packager
  cleared the screen first, which fails without a terminal ("TERM environment
  variable not set"), and that exit code was the job's result. Now the result is
  only whether a package failed.
- **Adding an installer without a detection rule** (a folder whose setup is
  install.ps1 or a .cmd) now says so in the log, instead of "( detection)".

## 2.38.16

Third full sweep (security, bugs, UI).

- **Adding Winget apps without winget's details**: when `winget show` doesn't
  answer (a slow index or manifest download), it is asked once more; if it still
  doesn't, the result now says which apps came without publisher, description
  and links, with a "Fill in details" button - before, they were added silently
  without them (Home later listed them as "details missing").
- **Checks with many apps**: the dependency order no longer takes a minute for
  500 apps (a per-pair comparison in 2.38.16's first build).
- **Checks really re-checks after a fix** now - in 2.38.15 it mostly didn't (the
  fixed row was dropped first, and with it the app's name). It also waits while
  another job runs instead of losing the detailed findings.
- **Package upload**: a second renewal of the upload address no longer reuses
  the refused one, and an address that runs out just before the final commit is
  renewed too.
- **Home and Updates tiles**: the same number of tiles from the start (Home's
  "on the current version" tile shows "–" until Intune answers; Updates always
  has its inventory tile) - the page no longer drops when they fill in.
- **Apps**: selecting a second app no longer moves the page ("Send 2 to Intune"
  has room); the first load no longer jumps (Save view and the chip bar keep
  their place); no sideways scrolling at 800px.
- **Sorting**: a click on a Checks header no longer breaks the Apps list's sort.
- **Updates**: Promote and the menu stay on one line; at 1000px and narrower the
  Superseded and Older-versions columns step aside so the actions stay in view.
- **Editor**: minimize, maximize and close stay above the sticky section tabs.
- **Install status**: Last seen no longer breaks inside the date.
- **Home warns** when the nightly task itself hasn't run (fast-track checks and
  plan-only clicks no longer count as a run).
- **Dependencies** named in other case ("dep" for "Dep") are no longer a
  "circular dependency"; batch edit saves the catalog's spelling.
- **Adding an app that is refused** (e.g. a profile group that doesn't fit)
  no longer leaves files behind that block the next try.
- **Case-only renames**: on Windows the file takes the new spelling too; on the
  server a script renamed by case in Intune leaves no stale copy.
- **Security**: on a PC the step scripts run from your own TEMP folder, not the
  app folder (another user of a shared PC could swap them); the catalog's git
  config is read by git itself for the backup check; the PSADT template must
  match the SHA-256 GitHub publishes; new server installs have the proxy buffer
  request bodies (a slow client can't tie up the app's request slots - for an
  existing proxy site, the deploy script says what to add).
- Small: the toast's close button is a proper target; "Add apps..." the same on
  Home and Apps; placeholder tiles go when Updates can't be read.

## 2.38.15

Second full sweep (security, bugs, UI), and:

- **Package upload refused with 403 "SAS identifier cannot be found"**: the
  upload address Intune just handed out can need ~30 s before Azure Storage
  accepts it. The upload now waits and tries again, and if Azure still refuses,
  asks Intune for a new address and sends the block again (it failed at once).
- **Checks refreshes itself after a fix**: after Take from Intune, Send
  settings, Send groups, Add to catalog or a catalog fix, it checks those apps
  again - the list shows what is still different, not a stale row.
- **Checks: "N selected"** counts only the rows in sight (a tick on a row hidden
  by the area or app filter no longer counts or gets sent).
- **Home warns when the nightly run hasn't run** for a day and a half though it
  is scheduled (the PC was off, the task couldn't start).
- **Apps list**: the version (lock, "-> newer", "pilot") and the stage pill sit
  on one line with the rest of the row.
- **Catalog backup to git** (nightly run): refuses repositories whose config
  could make git run a program (includes, signing, drivers, a .git that points
  elsewhere, filters in any .gitattributes) and runs git with signing and the
  attributes file switched off; the owner check works on Linux too.
- **Scripts > Save local copies** no longer deletes scripts saved locally and
  never sent to Intune.
- **Script run status** no longer lists devices twice when a later page fails.
- **Renaming an app by case only** ("Foo app" -> "Foo App") no longer leaves a
  second file on the server version (Linux).
- **PC test results** with non-English app names are read as UTF-8 on Windows
  PowerShell 5.1 (the detection rule got a garbled name).
- **Install status**: times read the same on any regional setting, and a report
  of exactly 5000 rows is no longer called cut off.
- **UI**: messages at the bottom have a close button; the palette's search box
  uses the whole width; on the Groups page the members table gets the full width
  up to 1600px, names stay on one line and the button just says Remove; the
  Checks App column no longer squeezes to one word a line; the Apps chip says
  "not in Intune yet"; the side panel says "Next step:" before its button.
- **Less movement while loading and clicking**: Home and Updates show
  placeholder tiles from the start (the page no longer drops when the numbers
  come), Home's Shortcuts card no longer shows and then vanishes, the note above
  the buttons has its own line on narrower windows, and the Updates placeholder
  rows use the real columns. The Apps table no longer jumps sideways when the
  side panel opens (Source is simply not shown up to 1600px - it is in the
  panel).
- **Long dialogs**: minimize, maximize and close stay in the top right corner
  while the dialog scrolls (the editor with a section open).
- **Install status on narrower windows**: Detail and Version step aside so Last
  seen stays in view; the error explanation uses the normal font.

## 2.38.14

Full sweep (security, bugs, UI).

- **Permissions**: the check no longer tells you to remove what "Add required
  permissions" just granted - the narrow read-only ones (inventory, filters,
  devices, users) count as optional while nothing uses them yet; only Mail.Send
  is still called out. Directory.Read.All counts for users too (the Groups
  page). The table now spans the whole page, names break only at the dots and
  each note sits on its own line.
- **Install status**: when Intune's report is cut off (over 5000 rows), no
  "Waiting for report" rows are guessed - a note says why.
- **Microsoft Store search**: sends non-Latin searches correctly (UTF-8) and
  uses TLS 1.2 on Windows PowerShell 5.1; a far too large answer isn't read.
  The publisher is cut to 256 characters.
- **Add apps**: each tab (Winget, Microsoft Store) keeps its own picks; a slow
  winget detail no longer lands on the Store tab; no "Store" pill on every Store
  row; texts and column names fit the tab; Store IDs stay in one piece; the
  table doesn't move when switching tabs; the tabs wrap instead of being cut off
  on narrow windows; arrow keys move between tabs.
- **Checks**: while a check runs the list can't be ticked or filtered (keyboard
  included), and the note above it no longer makes the list jump.
- **Batch Send groups**: if a group can't be found, the message says the batch
  stopped there and which apps were changed.
- Entra display names are cleaned of control characters before they go into
  the log; links use the theme's colour; Home's attention buttons keep their
  size on narrow windows.

## 2.38.13

- **Permissions check**: each permission now says exactly what it is used for
  (which pages and steps), not just a short label.
- **Add apps > Microsoft Store**: a tab of its own. It searches the Store's
  catalog (as winget's msstore source does - on the server version too, where
  there is no winget; on Windows winget's own search if the Store doesn't
  answer), shows the publisher and the app's Store page, and adds the apps as
  Intune's Microsoft Store app type - no package, the Store keeps them up to
  date (no managed updates).
- **A send never drops a group.** Send groups and the release steps replace an
  app's whole assignment list in Intune; a group whose ID couldn't be found
  was left out of it - and so lost its assignment, or every assignment when
  none was found. Now the step stops and changes nothing, and says which
  group it couldn't find.
- **Permissions - one list, the narrow ones.** "Add required permissions"
  (and the server's Entra setup script) offered Directory.Read.All while the
  permission check called it "not needed": both now use the narrow ones -
  User.Read.All (group members), Device.Read.All (the devices in an app's
  groups - install status names them with it), DeviceManagementManagedDevices
  .Read.All (apps on devices) and DeviceManagementConfiguration.Read.All
  (assignment filters), besides apps and groups. The check no longer calls
  DeviceManagementScripts.ReadWrite.All "not needed" when this folder has no
  script yet - the Scripts page uses it.
- **Checks: one change to the list.** While the checks run, the list stays as
  it was, dimmed, and the result replaces it in one go - no rows coming and
  going for a few seconds.

## 2.38.12

**A full sweep - security, bugs and the GUI - since 2.38.0.**

Security
- **A group named "[All users]" or "[All devices]" stays a group.** Reading
  assignments from Intune took a real Entra group with such a name for
  Intune's built-in target - and a send would then have assigned the app to
  every user. It is kept by its ID now (with a warning to rename it), and only
  the bracketed names are read as the built-in targets.
- **.pfx export on a PC: only the connection's certificate.** The same store
  holds the user's own certificates (mail, VPN, code signing) - the export
  isn't a general tool for those. The server version's store has only the
  app's own.

Bugs
- **Logs stopped colouring** after the first step that wrote to a dialog's log
  (two logs written at once). Fixed.
- **[All devices] for Available** was accepted, and Intune then refused the
  app's whole assignment list: Available is offered to users. It is refused
  in the editor, Batch edit, the grid, CSV import and Replace group, and not
  offered in the Available pickers.
- **Changes to send** (for an app last sent by an earlier version): the
  change history's rows are only those of the part that has no sent values,
  without a managed app's release fields, and never twice.
- **Install status**: when Entra ID couldn't be read, it said each group
  "isn't in Entra ID" - one note now. The waiting rows say that Available ones
  report once their user installs the app.
- **Groups**: left-over search results could keep offering Delete for a group
  just deleted, and Delete was offered while Entra ID wasn't checked. Fixed.
- **Checks**: the start-up badge, Home's toast and ticked findings left in a
  folded row now count only what the list shows. A change to send's card no
  longer opens after the pointer has left.

GUI
- The hover cards keep the keyboard: Tab past the last button goes back to
  what opened it; "Changes to send" can be reached with Tab.
- Read from Intune and Send to Intune open on what there is to do, not on the
  folded log; on a phone, Read from Intune shows each field above its two
  values.
- Done is the one button left after a send (Send to Intune, Send groups,
  Release, CSV import); "Send their groups too" can't be changed after the
  run; a failed CSV apply can be tried again; Send keeps its tooltip.
- Getting started's permission step says "Grant the missing permissions" with
  a "Check permissions" button; the names are in its tooltip.
- Install status: the summary's sentences are separated.
- Narrow windows: the Apps list hides "Who gets it" at a phone's width so the
  next step fits; Checks hides the Area column there.
- Home: a failed nightly-run step reads "404 Not Found - <Graph's message>",
  not Graph's raw JSON.

## 2.38.11

- **Export the certificate with its private key (.pfx)** - Settings >
  Connection, the certificate menu: as Windows' certificate manager exports
  one, to move the connection to another machine or keep a copy. It takes a
  password of at least 12 characters (typed twice), says first what the file
  can do (sign in to Intune as the app), and every export is in the log with
  who did it. A key kept as not exportable can't leave the machine - the app
  creates its own certificates that way on Windows, and the dialog says so;
  on the server version (and for an imported .pfx) it works.

## 2.38.10

- **Recommended apps: Jabra Direct** (`Jabra.Direct`) under Communication - for
  Jabra headsets: firmware updates and settings, and call control in Teams and
  softphones. 67 apps now.

## 2.38.9

- **Install status lists who is still to come.** Besides the devices Intune's
  report has, it lists the devices and users in the app's Required and
  Available groups (nested groups too, excluded groups' members left out) that
  haven't reported yet, as "Waiting for report" - so a fresh assignment shows
  who gets it instead of an empty table. The summary says how many are still to
  report and why it takes a while (a device reports after it checks in and
  tries the app). All users / All devices aren't listed one by one - a note
  says so; a group that isn't in Entra ID is a note too, never an error.

## 2.38.8

**Changes to send says what changed, logs show their errors, and a round of
GUI fixes.**

- **Changes to send - what changed.** Point at the Apps list's "Changes to
  send" (or click it) for a card with each changed field: what Intune has
  (last sent) next to what the catalog has now, the change marked, with Send
  settings / Send groups. Each send now keeps the values it sent beside its
  fingerprint; for an app last sent by an earlier version the card takes the
  catalog's edits since its last send from the change history.
- **Logs show their errors.** Every log in the app colours its lines - failures
  red, warnings amber, OK green - and a failure opens a folded log by itself.
- **Read from Intune** is simpler: each differing field is a choice between its
  two values - click the one to keep (Intune's is picked), or "Keep all" /
  "All from Intune". The button says what happens ("Save to catalog (1 from
  Intune, 1 kept)"), and the log is folded unless something failed. (The old
  "Keep catalog" tick's screen-reader label said the opposite of what it did.)
- **Done closes.** Send to Intune, CSV import and Release ended on a "Done"
  that was switched off; Send groups' "Done" ran Apply again. Each now closes
  its dialog.
- **Groups: two existing groups selected offered "Create 1" and "Delete 1..."**
  In "All groups in Entra ID", a group the catalog doesn't use counted as
  missing. Fixed - both say "Delete 2..." now, and Create stays off.
- **Getting started** cut off its Open buttons when a step had a long word (the
  missing permission's name). Fixed - and the UI tests now fail on any button
  or field cut off by its box, on every page and dialog they open.
- **Checks: no doubled rows while it runs.** The last audit's rows, shown while
  the checks run, fold "Unknown assignments" into the app's "Groups" row from
  the start - not only once the assignment stage has finished.
- **Install status** with nothing reported yet says why (devices report after
  they check in and try the app) instead of showing empty column headings.

## 2.38.7

- **Server image builds can't hang on a slow package mirror.** Ubuntu's
  package step once took 29 minutes in CI (and one run hung for an hour).
  apt now gives up on a stalled mirror after 30 seconds and tries again (5
  times); CI caches the image's layers, so the packages are only downloaded
  again when the Dockerfile changes or once a week (security fixes still come
  in); and CI's image job stops after 20 minutes instead of holding a release.
  The released image is still built fresh, with every security fix.
- **update-ica.sh / backup-ica.sh**: the backup leaves out the running app's
  scratch folder (tmp/), so tar no longer prints "socket ignored" - those
  were throwaway files, the backups were always complete.

## 2.38.6

- **Checks: one problem, one row.** An app assigned in Intune to a group or
  to All users / All devices the catalog doesn't have showed twice - as
  "Groups: ... differ" and as "Unknown assignments" - with the same fixes.
  The Unknown assignments row is now left out when the app's Groups row
  already shows every item on it. What the Groups row can't show (an
  assignment with a filter, an exclusion, a target the catalog can't hold)
  still gets its own row.
- **Missing Graph permissions are said up front.** Getting started no longer
  ticks "Connect to Intune" while the app registration lacks a permission the
  catalog uses (or one Graph already refused): the step says which, and
  Check permissions opens Settings > Diagnostics and runs the check. Once
  Getting started is done, Home says it instead. "Apps worth adding" shows a
  missing permission as a message with that button, not as a table row.
- **Groups: "Delete by name..." is gone.** Select the groups (Ctrl/Shift+click;
  "All groups in Entra ID" shows those the catalog doesn't use) and press
  Delete - one way, with the groups in front of you.

## 2.38.5

- **Checks failed** with "The term 'Get-AllTargetInfo' is not recognized"
  when it compared assignments (2.38.4): the workers that read each app's
  assignments in parallel weren't handed the new All users / All devices
  helper. Fixed - and a test now fails if those workers miss any assignment
  helper the rest of the app has.
- **Checks**: a finding with nothing stored for the catalog or Intune (an
  earlier audit's) no longer shows "Catalog (blank) / Intune (blank)".

## 2.38.4

**Checks shows what differs side by side, the catalog can assign to All users
and All devices, and lists no longer jump when you open them.**

- **Checks - "Differs"**: the two cut-off Catalog / Intune text columns are one
  column with a chip per field that differs. Point at the chips (or Tab to them
  and press Enter) for a card with the fields side by side - Field, Catalog,
  Intune - the changed part marked, "(blank)" spelled out, and Open full
  compare / Take from Intune / Send settings / Send groups right there. Esc
  closes it.
- **All users / All devices**: Intune's built-in targets can be in an app's
  Required, Available and Uninstall lists as `[All users]` and `[All devices]`
  (the group picker offers them). Send groups assigns them, Take from Intune
  brings them into the catalog, and they are never looked up, created or
  reported missing in Entra ID. Intune can't exclude them, so Excluded refuses
  them. An app assigned to All devices in Intune (Company Portal, say) no
  longer shows as "Unknown assignments" once it's taken from Intune; anything
  else Intune has that the catalog can't hold is named readably instead of as
  a raw Graph type.
- **No jumping lists**: "Pick..." beside App version, "Link..." beside the App
  ID, the assignment profile lists and the Checks area filter keep one width
  when they fill in. The UI tests now open every list on every page and dialog
  they visit and fail if one changes size.

## 2.38.3

**A full GUI sweep: every page, dialog and editor state at four widths, light and
dark - what looked broken is fixed, and the tests now catch squeezed layout.**

- **Release rule** (the editor, managed updates, Change): its three fields were
  squeezed to a few pixels beside the box's heading. Fixed - and the UI tests
  now check every page and dialog they open for squeezed fields and text.
- **Apps list empty** when an app was in a later release ring and the settings
  weren't read yet - fixed.
- **Remove groups offered nothing** to remove - the list now carries each app's
  groups per role.
- **Changing a Winget ID twice quickly** (in its block row) left the commands on
  the one in between - fixed.
- **Long names**: group names pushed the editor's Available/Excluded columns out
  of the dialog (the four boxes now go 2x2, then one column on phones); app names
  pushed Stage off the Apps grid (cut with "..." now, shorter with the side panel
  open); a group name without spaces spilled out of Remove groups.
- **Phones**: Add groups and the group boxes stack; From a list shows the list
  (brought into view); a group's apps table scrolls sideways with Unassign whole;
  the Updates toolbar and the Alerts select fit.
- **Store apps**: no empty command fields, detection rule or empty box - the Store
  installs and detects them.
- Smaller: Settings > Defaults cards full width; "Ready to send?" marks keep
  their shape; the setup guide's steps without divider lines; nothing shows
  above the editor's tabs while scrolling; App ID shows its focus; the managed
  updates note below its label; room between the detection Type field and its
  blocks; the sign-in page follows the system's dark mode; "Scheduled tasks need
  Windows" (it said "To do undefined"); a missing space on Updates.

## 2.38.2

- **Recommended apps: nothing ticked by default** - each app is chosen.
  The eight nearly every organisation deploys (Firefox, Chrome, 7-Zip,
  Acrobat Reader, Notepad++, VLC, Java 25, the Visual C++ runtime) say
  "common" instead.
- **TeamViewer Host and TeamViewer QuickSupport** in the list, right after
  TeamViewer: Host on users' PCs for unattended support, QuickSupport for
  support the user starts; the full TeamViewer for the support team.

## 2.38.1

**More recommended apps, and the list looks right while it scrolls.**

- **64 apps** in Add apps > From a list > Recommended apps (was 28), in
  clearer categories: Browsers, Files and documents, Communication, Remote
  access, Cloud storage, Passwords, Media and design, Runtimes, IT and
  developers. New among them: Microsoft Teams, Slack, Thunderbird, PDF24,
  PDFsam, Acrobat Pro, Everything, TreeSize, OpenVPN, WireGuard, AnyDesk,
  TeamViewer, Dropbox, Google Drive, Box, Bitwarden, 1Password, IrfanView,
  GIMP, Inkscape, Audacity, OBS Studio, Creative Cloud, Figma, Miro,
  Notion, Power BI Desktop, .NET 9, Python, Node.js, Azure CLI, Azure
  Storage Explorer, SQL Server Management Studio, Postman, Wireshark. Every
  ID checked against winget's index; licensed ones say so.
- **Java 25** (Eclipse Temurin) is the ticked Java now - the current
  long-term version; 21, 17 and 8 stay there for apps not certified on it.
  Still 8 ticked by default.
- Not in the list: what Windows or Microsoft 365 bring (Edge, OneDrive,
  Office), and VPN clients winget doesn't have (FortiClient, Cisco Secure
  Client).
- **Fixed:** a category heading stayed at the top of the list while it
  scrolled, over the column names. The column says "App" for this list.

## 2.38.0

**Recommended apps to start with, and a full sweep (security, bugs, UI)
since 2.28.5 - everything it found fixed.**

### Recommended apps
- **Add apps > From a list > Recommended apps**: 28 Winget apps most
  organisations deploy, by category, each with why. Ticked: Firefox,
  Google Chrome (the enterprise MSI), 7-Zip, Adobe Acrobat Reader,
  Notepad++, VLC, Java 21 (Eclipse Temurin - no Oracle licence needed) and
  the Visual C++ runtime. Also there: Firefox ESR, SumatraPDF, LibreOffice,
  Paint.NET, Greenshot, Java 17 and 8, .NET 8, Zoom, Webex, Citrix
  Workspace, KeePassXC, PowerShell 7, PowerToys, VS Code, Git, WinMerge,
  PuTTY, WinSCP. Every ID checked against winget's index.
- The list tab has its own **Managed updates** box (the Settings default) -
  apps added from a list never got managed updates before.

### Security
- **Sign in with Microsoft couldn't be blocked any more.** /auth/login
  needs no sign-in; 50 calls in ten minutes refused every new sign-in (with
  the password off: everyone locked out). Now at most 5 under way per
  client, and the oldest goes when 200 are.
- **Get new installer only takes an installer of the same type**: a link
  to a .zip, .msix or anything else never replaces the folder's .exe or
  .msi, and the download's first bytes must say .exe (MZ) or .msi. The same
  for the nightly download. The question says when the signature can't be
  checked (the server - Windows does that).
- **Different names, one packages folder** ("7-Zip", "7 Zip", "7.Zip"):
  refused when adding or duplicating - one could delete or replace the
  other's installer.
- Install commands from an uploaded folder quote paths with spaces ("My
  App\install.ps1" ran ".\My").
- The server warns when the trusted proxy has no address (wrong passwords
  would be counted for everyone); deploy-ica.sh --no-proxy says to set
  ICA_TRUSTED_PROXY. Two pieces of one upload sent at once are taken one
  after the other.

### Bugs
- The installer's own name was lost on a cached read - the check of a
  detection rule by name almost never ran.
- **Use as the detection rule** takes the name without its version ("7-Zip
  24.09 (x64)" is "7-Zip"), so the next version is found too - and a
  release now moves the version that rule looks for, so a managed own
  package with it can still be released.
- **Retiring** an app also uninstalls and deletes the MSI line-of-business
  app it replaced, when that is still in Intune.
- Uploads into a packages folder and retiring the MSI app don't hold the
  catalog lock the whole time (other saves waited and failed) - only the
  catalog write does.
- The setup file suggested for a folder is never an uninstaller, and a
  setup-named installer or an .msi comes before a plain .exe that is merely
  higher up (Setup\setup.exe before a top-level vcredist). Package itself
  no longer takes an Uninstall.exe as the setup.
- The editor's "setup" mark names the file Package really uses.
- Duplicate app keeps the release rule, automatic release, download address
  and the name Windows lists the app under.
- Get new installers doesn't list an app again whose new installer is
  already in its folder. For a PSADT app it lands in Files\.
- Add apps: emptying both group lists clears a profile's exclusions too.

- **Faster on Windows PowerShell 5.1**: 2.37.0 rebuilt every answer from
  plain values there - the Apps list of 500 apps took 7.7 s instead of
  about 5. Now only an answer that needs it is rebuilt (plain JSON fails or
  carries a file's PSPath).

### UI
- Menus: Escape gives focus back to what opened them; arrow keys skip
  hidden items, Home/End work; the server's Sandbox test menu no longer
  takes focus back from where you clicked, and closes when you Tab out.
- Updates: Get new installers moved into the toolbar's More (it pushed the
  toolbar off a phone screen).
- Send to Intune: package warnings in the warning color, kept while it is
  sent. Add and send's summary: one item per line, focus on Send, no
  greyed-out "Send the 0 ready", Build can't be pressed twice.
- "New apps get" lists profiles as they are typed and keeps the choice
  through a rename; on its own line.
- Get new installers ends with only Close; Sandbox results: each button
  says which entry it takes, one primary, the others off once one is used.
- Package files: columns line up, no "Use as setup" on Uninstall.ps1,
  delete asked as a dangerous step. "Winget package to watch" moved below
  the release rule (two Winget ID fields one above the other were
  confusing).
- Add apps: a name the catalog has turns Add off and offers Open it; small
  files show in KB.

## 2.37.0

**Windows PowerShell 5.1 made safe for every answer, new installers in
one go, and a shorter menu.**

- **Every answer the page gets is plain values on Windows PowerShell
  5.1.** 5.1 writes what PowerShell hangs on a value into the JSON too -
  text read from a file carries its path, drive and provider, many levels
  deep - and the answer then fails (2.36.0 fixed one case, the Sandbox
  log). The server now rebuilds each answer from plain values on 5.1 first,
  so no page can run into it. PowerShell 7 (and the server version) leaves
  those out by itself.
- **Updates > Get new installers...**: every app with its own installer
  that watches a winget package and has a newer version there, in one
  list - each downloaded into its folder one after another (SHA256 as
  winget gives it), then **Release...** (managed) or **Open** (set the App
  version, Package and send) beside it.
- **A shorter More menu**: what can never apply to the selected apps isn't
  listed (Sandbox, Package and Get new installer for Winget apps; Take
  winget's version and Fill in details for own installers; Promote,
  Withdraw, Roll back and clean-up without versions to act on), and a
  section with nothing left loses its heading. What could apply after a
  step stays, greyed out with the reason (Release new version: turn on
  managed updates).
- **Fixed: Fill in details from winget was always greyed out** in the
  menu. "Fill in details" moved from Groups to Package & Intune.
- **The server's side panel has one Sandbox test... button** - download
  the test, or upload its result - instead of two.
- Tested: the last step of Add and send (the summary's Send sends only the
  ready apps, with their groups; Intune's answers stood in for in the
  page), and Get new installers.

## 2.36.0

**New versions of your own packages, the server's Sandbox results, and a
check before sending.**

- **Watch winget for new versions** (an app with its own installer; the
  editor, next to the release rule): a winget package with the same app,
  only watched - devices still install your package. The Apps list shows
  "→ newer" when winget has one (Checks > winget, the nightly run), and
  **More > Get new installer** downloads it into the app's folder under the
  installer's own name - used only if its SHA256 is the one winget gives
  (and on Windows, if the installer there was signed, by the same
  publisher). Then Release new version (managed) or Package + send.
- **Sandbox results on the server**: "Upload test result..." in the side
  panel takes the result.json that Start-Test.ps1 wrote on the PC - shown
  like a test run here, with **Use as the detection rule**. Start-Test.ps1
  says where to upload it.
- **Before sending: what doesn't fit together** in an own package - a
  command running a file the package doesn't have, the chosen setup file
  gone, detection looking for another product code, a newer version or
  another name than the installer's, the App version not the installer's.
  Warnings, not blockers: in Send to Intune, in Add and send's summary
  ("Ready - check", with Fix...) and in Checks (area Package).
- The installer's own name (MSI ProductName, an .exe's version block) is
  read for that check.
- **Fixed: a Sandbox test's progress in Windows PowerShell 5.1.** The
  answer carrying the test's log failed there (5.1 wrote the log file's
  provider details along with its text), so the result never showed.
- Tests for what 2.35.0 left out: the deploy plan's warnings against fake
  Intune answers, "Use as the detection rule" clicked in the page, the
  app's own Uninstall.ps1 following the name, and an .exe's version block
  read from a file across the read boundary.

## 2.35.0

**Adding apps takes fewer steps, and makes fewer duplicates.**

- **Add and send** beside Add (Add apps): it adds the app, builds its
  package, then shows a summary - who gets each app, and Ready or what it
  lacks, with **Build** or **Fix...** (the editor, at that field) - and
  **Send the N ready** to Intune with their groups. It needs a connection;
  without one it is off and says so.
- **Duplicate warnings while adding**: a name that's already in the
  catalog, or an app of that name already in Intune and not linked (link
  it in Checks instead of sending a second one). Winget search marks such
  packages "in Intune".
- **Duplicate app** (the app's menu): a copy with the same groups,
  settings, detection, requirements and icon under a new name - no App ID,
  no supersedence.
- **A default assignment profile** for new apps (Settings > Assignment
  profiles, "New apps get"): Add apps and the editor start with its
  groups, its exclusions too. A profile's exclusions now carry over when
  it is picked in Add apps.
- **Better .exe detection**:
  - The name, publisher and version an installer states about itself
    (Inno Setup, NSIS, ...) are read on the server too, not only on
    Windows.
  - A Sandbox test now records what Windows lists after the install. The
    result shows it with **Use as the detection rule**: a script rule for
    that exact name, that version or newer. An Uninstall.ps1 this app
    wrote looks for the same name. Start-Test.ps1 (the server's Sandbox
    package) prints the name.

## 2.34.0

**Upload whole folders (or a .zip of one) to build the .intunewin** - also
on the server, where the packages folder can't be reached otherwise.

- **A folder, a .zip or a single installer** - in the editor ("Upload an
  installer or .zip...", "Upload a folder...", or drop it on the package
  box) and in Add apps > Installer (drop a folder, or "choose a folder").
  Subfolders come along.
- **The setup file is suggested** (the top of the folder first: a PSADT 4
  launcher, install.ps1, a setup/install installer, an .msi, an .exe) and
  can be changed; the commands, detection rule and version are made from
  it - only where still empty. Package uses that file, in a subfolder too.
- **Replace or add** when the app's folder has files already - asked, not
  guessed. (A new installer of an app with managed updates still goes
  through Release new version.)
- **The packages folder as a list** in the editor: each file and its size,
  which one is the setup file ("Use as setup"), delete a file, and when
  the package was last built.
- **Safe unpacking:** every path is checked (nothing can land outside the
  app's folder - no "..", no root or drive), symbolic links are skipped,
  Mac clutter (__MACOSX, .DS_Store) left out, and at most 5000 files and
  8 GB, counted as they are written.

Fixed:

- **Packages now hold the app's whole folder.** An installer app was built
  from the setup file alone - its other files were left out, among them
  the Uninstall.ps1 an EXE app's uninstall command runs (so that uninstall
  failed on the devices). Rebuild such packages (More > Package) and send
  them again.
- A package no longer contains the .intunewin built before it (script apps
  were packaged with their folder as it was).

## 2.33.0

**MSI line-of-business apps can move to Win32.** An app taken over from
Intune that Intune has as an *MSI line-of-business app* (its own MSI type)
came into the catalog without its .msi - Intune never gives it back - and
couldn't be built or sent: this tool sends Win32 apps, and Intune can't
turn an MSI app into one. Now, the way Microsoft recommends:

1. **Upload the installer right in the editor** (Basics - "Upload the
   installer..."), on the server too. It goes into the app's packages
   folder and fills in what is still empty: the install and uninstall
   commands, the detection rule (MSI product code), the version and the
   publisher. What the app already has is kept.
2. **Send to Intune creates it as a new Win32 app** with its groups. Send
   asks Intune for the linked app's type first; the plan says "Create as
   Win32" and why. The catalog then follows the Win32 app.
3. **Retire the MSI app** from the app's side panel, once the Win32 app has
   its groups - asked first, and only if Intune still says it is an MSI
   line-of-business app. It is deleted from Intune; devices keep the
   software (the Win32 app finds it by the same MSI product code), so
   nothing is uninstalled and installed again.

Also:

- **Its type is said as it is:** "Windows MSI line-of-business app"
  instead of "Windows app (Win32)"; the side panel and the editor explain
  what to do with one.
- Push settings to an MSI line-of-business app is refused with why (its
  settings can't be pushed as a Win32 app's).
- New tests: the type helpers, the installer upload (filled in, kept,
  refused), retiring the MSI app (only an MSI app, only once replaced) and
  the editor upload in the browser.

## 2.32.2

- **Fixed: the side panel's More... did nothing.** It opened the actions
  menu - and the same click closed it again at once.
- **The icon's More... is a real menu now** (it was a drop-down whose
  entries were mostly greyed out with the reason only in a tooltip, so
  picking one seemed to do nothing). What can't be done yet says why under
  its name - in every More menu.
- **The Intune App ID where you look for it:** in the side panel in full,
  with **Copy** and **Open in Intune** (the app's page in the Intune admin
  center); and as an optional **App ID** column in the list (view menu >
  Intune App ID). Hovering a row still shows it too.
- **Fixed: downloads failed on Windows PowerShell 5.1** (the Sandbox test
  zip, helper scripts) - the random link name used a call that only
  PowerShell 7 has. Found by the new Sandbox test.
- The Sandbox test in the server version (a zip for a Windows PC with
  Windows Sandbox) now has a server test of its own.

## 2.32.1

A sweep of 2.29 to 2.32 (the folds, menus and in-place edits):

- **A new Winget ID rewrites the generated commands** - in its row on
  Install & detection or on Basics. Before, the commands kept the old ID
  (and the blocks then showed them as your own command). Commands edited by
  hand are left as typed.
- **A save refused for something folded away opens it:** dependencies or
  supersedence, the detection rule, the requirements, or the release
  rule's download address - the message and the field are both in view.
- **Groups looks again** after the connection is set up, instead of still
  saying it needs one until the app restarts.
- **The new More menus** (Updates) move with the arrow keys like the
  other menus.
- **Clicking a field right after an editor tab** keeps the focus there -
  before, the tab moved it to its first field a moment later, so typing
  could land in the wrong field (Required instead of Available).
- The blocks' tooltips say the Winget ID, version and Install for are
  changed right there (not "set on Basics").

## 2.32.0

Each thing said once, and controls only where they can do something:

- **No "no connection" banner on every page.** The sidebar badge says
  "Not connected - set up" and opens the setup guide; each page says what
  it can't do without the connection.
- **Settings > Connection:** the Entra ID buttons are in the setup guide
  while it is being set up - the row under the connection appears once it
  is (a new certificate, the permissions again later). The guide folds
  away when setup is complete. Choosing a certificate is the first item of
  the **Certificate** menu - one button beside the thumbprint.
- **Updates:** with no app on managed updates, just the message - no zero
  tiles or empty column headers. Check downloads and Compliance report are
  under **More**; Reload is an icon.
- **Checks:** "Deployed apps in detail" and "Ask winget" are under
  **Options** next to Run checks; with no findings, what wasn't compared is
  said once (in the empty state).
- **Groups:** not connected and no group in the catalog - one message with
  **Set up the connection** instead of controls that can't work. Reload is
  an icon next to the search; the selection hint is the list's tooltip.

## 2.31.0

Quieter everywhere - said once, and what most people never change folded:

- **Home:** "Not connected" is said once, in Getting started - not again
  in Needs attention or the banner (other pages keep the banner). An empty
  catalog shows no zero tiles, and Shortcuts appears once Getting started
  is done.
- **Apps list:** Columns, rows and the mouse-and-keys hint are in one icon
  menu next to Reload and Recent changes; **Save view...** only shows when
  there is a search or filter to keep.
- **Editor, Basics:** the release rule is one line ("The rule from
  Settings: 3 days per ring, at most 5 % failed, at least 1 device" -
  **Change**); the App ID reads as plain text; the icon has **Choose
  image...** and one **More...** menu (from Intune, find one, remove).
- **Add apps:** who gets the new apps is one line ("Who gets it: nobody
  yet") - **Choose** brings out the profile, the groups and favourites.

## 2.30.0

- **The editor has 4 tabs instead of 6.** Install & detection holds all of
  how the app installs: the commands, the detection rule, the requirements,
  then dependencies and supersedence - in one column.
- **What most apps never change shows as one line,** with **Change** to
  bring the fields out:
  - *Detection* of a winget app: "Made for winget - installed when winget
    lists <ID>" (**Set a rule of its own** for anything else). Apps with
    their own package show the detection fields as before.
  - *Requirements*: "Windows 10 22H2 or newer · x64 · for the device ·
    60 min · restart: by return code · 7 return codes".
  - *Dependencies*: "Installs on its own · supersedence as Intune has it".
  The Ready checklist, a required field and "go to the field" open the
  part they need by themselves.
- **Install & detection: changed in place.** The Winget ID, the version
  (newest or pinned with managed updates) and who it installs for are
  changed right in their rows - no more jumping to Basics or Requirements.
  They write into the same fields as before, so Save, the checks and the
  commands follow as they always did.
- **Calmer rows:** no icons, no tinted rows - label on the left, value or
  control on the right.
- **Fixed: changing Install for now rewrites generated commands.** Before,
  switching to User (or back) left `--scope machine` in the winget command
  until the install method was chosen again. Own commands are left as
  typed.

## 2.29.2

- **Add apps opens on the kind you added last** (Winget, installer, script,
  PSADT or a list). Opened for a kind (an installer dropped on the window,
  the command palette), it opens on that one as before.
- **The UI tests clean up after themselves:** the `data` and `init` folders
  a run creates are removed again, so the next run starts clean. Folders
  that were there before the run are left alone.

## 2.29.1

- **The shared Winget package builds itself.** `init.intunewin` is built
  when it is missing - at start, before a send, a release and in the
  nightly check - instead of being a step you have to remember. The
  Packaging card says when it was built; the button there rebuilds it.
- **Getting started lists the steps already done** in place (ticked, title
  only), so you see where you are in the whole list.
- **Install & detection is quieter.** The parts the tool writes the same
  for every app fold into one line ("4 fixed parts - the same for every
  app"), click to show them. The raw install/uninstall commands and the
  detection script fold under the blocks ("as Intune gets them"); they
  open by themselves when there are no blocks, the app is your own, or you
  edit as text. The colour legend is gone - the icons keep their tooltips.
- **Add apps: the button names what it adds** ("Add 2 Winget apps", "Add
  installer", "Add script app", "Add PSADT app", "Add 3 from the list").
  Only the open tab is added; what is filled in on the other tabs is left.

## 2.29.0

- **Sign in with Microsoft (the server version).** People sign in with their
  own Entra ID account instead of the shared admin password: Entra ID asks
  for the password and the second factor, so your MFA and Conditional
  Access rules apply. Only members of one Entra ID group get in (checked at
  each sign-in, nested groups included). The history says who changed
  what; the sign-out button says who is signed in.
  - Set up in **Settings > Connection > Sign-in**: the group, on/off, and
    whether the admin password still works. The password can only be
    turned off from a session signed in with Microsoft - the new way in is
    proven first. `ICA_PASSWORD_SIGNIN=1` in `.env` is the way back in.
  - Uses the connection's app registration and certificate (no client
    secret). The **Entra setup script** adds the redirect URI
    `https://<name>/auth/callback` to it.
  - OpenID Connect code flow with PKCE; the ID token is checked (app,
    tenant, issuer, nonce, times); the browser picks the session up with a
    one-time code that never reaches a server. Tested end to end against a
    stand-in for Entra ID (PKCE, the certificate's signature, wrong app,
    wrong nonce, cancelled, not in the group, codes used twice).
  - The sign-in page shows **Sign in with Microsoft** and/or the password,
    and says plainly why a sign-in didn't work.

## 2.28.7

- **Product code: detection and uninstall checked against each other.** An
  MSI app is found and removed by its product code; after an update (a new
  MSI) both must be the new one - detection on the old code says "not
  installed" for ever, an uninstall with the old one removes nothing. When
  they differ, the editor says so under the detection rule and in "Ready to
  send?", with a button for either direction. Not tied together silently:
  they can differ on purpose.
- **The history reads as text.** A detection rule is shown as the editor
  says it ("MSI product code {...}, version 26.06 or newer", "File
  %ProgramFiles%\7-Zip\7zFM.exe, version 24.08 or newer") instead of its
  JSON - in the app's history, Recent changes and the version comparison.
  Recent changes names an app once (it was in the group's line and again
  over its changes).
- **Times in the viewer's own time.** The run list, Home's last run, the
  backups in History and their comparison came as the server's local time
  without its zone, and a browser in another zone read them as its own
  (the same dialog showed one save at 17:01 and 18:01). They come with the
  server's offset now and are all shown the same way. The nightly run's
  time is the server's clock - from another time zone the page says so
  ("server time (UTC+1)").

## 2.28.6

A sweep of the whole app (security, bugs, UI - with every preview checked
against the real data).

- **Previews that said something else than the data:**
  - An app without groups showed "Ready to send - Everything is set" in the
    list and the side panel, while the editor said "4 of 5 - no groups".
    The list now says **Ready - no groups**, with Groups... as next step.
  - The editor's "Ready to send?" list kept "Its installer is packaged"
    when the install command named another installer than the one in the
    packages folder (an MSI file block changed) - it says so now.
  - Home said "last nightly run" for any run (fast track too) - now "last
    managed-updates run".
  - History: Restore was enabled for copies the catalog didn't record (it
    refused them anyway); a batch-edit preview brought back from the tray
    is made again.
- **The server's nightly run never looked for new winget versions** (it
  asked for winget.exe, which Linux hasn't) and reported a failure every
  night - it asks winget's package index now, so automatic releases work.
- **Switching the server's schedule on** after its time started a real run
  at once - today's now counts as done, the first is at the time tomorrow.
- **A refused Save changed nothing** - before, a bad group name was refused
  after the update rules were already applied.
- Settings > Connection: deleting an old certificate no longer puts the
  saved thumbprint back over a new, unsaved one. The setup guide is drawn
  for the server as soon as that is known; the server refuses the desktop's
  sign-in jobs. Help texts point to Settings > Connection (the removed
  cards were still named).
- winget: descriptions over several paragraphs are read whole; installers
  named in capitals (Setup.MSI) are found on the server; XP... Store IDs
  aren't offered for the winget-command switch.
- **Security (server version):** before signing in, a request may carry
  4 KB and has 3 seconds (16 request slots instead of 8); wrong passwords
  are counted per client only as the HTTPS proxy reports it
  (`ICA_TRUSTED_PROXY`, default `nobs-proxy`), IPv6 per /64.
- **CI and release:** the tests run with a read-only token; the signing
  secrets reach only the signing step; the version is passed as data and
  checked; a released image is never overwritten.
- UI: the side panel's Sandbox test is the download on the server; the
  theme says "follows the system"; an unknown page goes to Home instead of
  a blank one; side panel, batch edit and Add apps fit on a phone;
  "Install and uninstall commands".

## 2.28.5

- **Dependabot as in our other apps:** weekly instead of monthly, and now
  also for the Docker base image (`mcr.microsoft.com/powershell`) - a new
  version arrives as a pull request. Still bumped by hand:
  Microsoft.Graph.Authentication in the Dockerfile (PowerShell Gallery) and
  Playwright / axe-core in the UI test.

## 2.28.4

- **Settings > Connection in one form.** The certificate is handled where its
  thumbprint is: **Choose...** beside the field, and a **Certificate** menu
  (create, import a .pfx, download the .cer, open the folder, delete one).
  The Entra ID actions sit in an "In Entra ID" box under it - on the server
  the Entra setup script and Grant consent, on the desktop Upload, Add
  required permissions and Check certificates. The separate Certificate
  and API permissions cards are gone; Setup guide moved to the right.
- **The setup guide on the server** offers what works there: Choose /
  Import a .pfx / Create new for the certificate, and the Entra setup
  script for the certificate and the permissions in Entra ID (it clicked
  the desktop's Upload and Add permissions before).
- **Home uses the whole width** of the window (it stopped at 1180 px).
- **Prerequisites isn't shown on the server**: the image brings the Graph
  module, there is nothing to check or install.
- Home: a nightly run's problem that isn't about one app no longer starts
  with "(all):".

## 2.28.3

- **One button size per row.** The editor's field buttons (Choose image,
  From Intune, Find one, Remove, From an app on a PC, Add an app) and
  Settings' Add a return code / Add a ring are the size of the field
  buttons beside them (Find..., Link..., Choose...); the small size stays
  for table rows, lists, toasts and panels. Groups: the buttons under the
  list line up.
- **Editor:** "Ready to send?" without the extra space above its title; an
  empty dependency list has its note inside the box; on a phone the parts
  scroll on one line and Cancel/Save stay on the right.
- **The nightly run's time** reads the same in the sentence as in the time
  field (12- or 24-hour, as the browser shows times).
- **Groups:** the search box's text isn't cut off; the "set up the
  connection" note shows once, under the select.
- Winget IDs in the search results break at their dots, not mid-word;
  two-column fields line up when one label wraps.

## 2.28.2

A sweep of the whole app (security, bugs, UI), mostly the server version.

- **Security (server version):**
  - Every request has a deadline: someone sending a body a byte at a time
    could hold all request slots and freeze the server without signing in.
    Bodies larger than a sign-in are read only for the open session.
  - Wrong passwords are counted per address (as the proxy saw it): someone
    guessing can no longer lock the admin out, and many guesses at once
    don't get past the limit.
  - An installer's name can't break out of the comment in the Sandbox
    starter script (it could have run a command on the PC outside the
    Sandbox).
  - `localhost` is answered only from inside the container: another
    container on the proxy's network has to go through the HTTPS proxy.
- **Bugs:**
  - Saving Managed updates or Nightly run turned the server's nightly run
    off and set its time back - only Schedule sets them now.
  - .exe installers had no version on the server - it is read from the file.
  - Working files (staged installers, Sandbox zips) are on the data volume,
    not the small /tmp in memory - large installers fit.
  - Open in Entra, What's new and the coffee button open in your browser on
    the server version; folder actions aren't offered there.
  - winget's index: one download at a time for sure; without the CDN, a
    failed download isn't retried for 30 minutes (searches don't wait).
  - The server always packages with the built-in packager; the session's
    state is locked against requests at the same time; Linux folder paths
    are accepted; msiinfo can't hang on its errors.
- **UI:** app icons have their colours again (the page's security policy
  refused how they were set); the server's texts say "the server", not
  "this machine"; menus stay inside the window; settings and Add apps tabs
  scroll on phones; fast-track runs are labelled in the run list; Groups
  says why a search failed; a toast shows above a dialog opened after it.

## 2.28.1

- **The server version: scripts for what needs a Windows PC.** These download
  from the page and run on a Windows PC (right-click > Run with PowerShell):
  - **Entra setup script** (Settings > Connection): you sign in on the PC; it
    adds the chosen certificate and the API permissions to the app
    registration, then opens the page for the admin consent - the desktop
    version's Upload to Entra / Add permissions.
  - **Sandbox test** (app menu > Download a Sandbox test): a zip with the
    package, the test and `Start-Test.ps1`, which opens Windows Sandbox and
    says how the install and the detection went.
  - **Detection from an app on a PC** (editor > Detection): a script lists
    the PC's installed apps; the one you pick goes to the clipboard, pasted
    back it becomes the detection rule.
  - **A PC's apps** (Add apps > From a list): a script runs `winget export`
    on the PC; its file is chosen in From a list as before.
  Download links are single-use and expire after 5 minutes.

## 2.28.0

- **The server version: the app as a Docker container.** The same app, on a
  Linux server next to NOBS Inventory, behind its shared HTTPS proxy -
  `sudo ICA_HOST=apps.example.ch ./deploy-ica.sh` sets it up (image
  `ghcr.io/monsama/intune-app-catalog`), see docs/docker.md. The nightly
  run and the fast-track runs happen on the server: no PC has to stay on.
  - **One admin, one session**: the admin password is a Docker secret;
    signing in ends a session that is open in another browser (it goes
    back to the sign-in page and says why); a session also ends after 2
    hours idle and 12 hours after sign-in; five wrong passwords in a
    minute pause the checks for a minute; Sign out top right.
  - **winget without winget**: search, versions, details, installer links
    and fill-in come from winget's own package index (the same source
    winget reads, from cdn.winget.microsoft.com), refreshed every 6 hours.
  - **The certificate** lives in the server's store on the data volume:
    import the .pfx you have, or create one and download its .cer for
    Entra ID (adding it and the API permissions there is done by hand -
    the server can't sign you in to Entra ID).
  - MSI product codes and versions are read with msitools; packages are
    built with the built-in packager; the deployment steps run with
    PowerShell 7 (the fake-Graph step tests now also run on Linux).
  - Not in the server version: the Windows Sandbox test, Detection from an
    app on this PC, Read this PC's apps, Open folder, IntuneWinAppUtil.exe.
  - The apps you have: send them to Intune from the desktop version, then
    Checks > Add to catalog on the server.
  - The container is read-only and runs without rights; everything it keeps
    is on the volume intune-app-catalog-data. scripts/update-ica.sh updates
    (with a backup, and back again when unhealthy), scripts/backup-ica.sh
    backs up, scripts/docker-smoke.sh tests an image; CI builds and tests
    the image on every push, a release publishes it.
- The desktop version reads certificates through .NET's store (the same
  lists as before) and MSI files through one helper - no change in use.

## 2.27.8

- **A fixed header bar above every page**: the page's name on the left,
  coffee and theme on the right, on the sidebar's colour with a hairline
  under it, the height of the sidebar's brand row. It stays at the top
  while the page scrolls; the two buttons are always in it (on wide
  windows they used to move into each page's own toolbar). Its hairline
  runs on under the logo, so one line goes through the full width of the
  window (also with the narrow icon sidebar).

## 2.27.7

- **Dropdowns look the same everywhere.** One style for all 41 of them on
  every page, Settings section, dialog and editor tab: the app's own
  chevron (the browser's arrow looked different on every system), regular
  text (27 had taken the bold of their label, 12 hadn't), the same size,
  corners, colours, hover and focus; the editor's block rows use the same
  look at a row's height. The open list follows the theme too.

## 2.27.6

- **Script apps written another way get their blocks.** Commands like
  `%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe
  -ExecutionPolicy Bypass -NoProfile -File install.ps1` (switches in any
  order, with or without `.\` or quotes, any script name, with arguments)
  are shown as a PowerShell script with its Install and Uninstall scripts
  to open in the code editor - the commands themselves stay exactly as
  they are. Before, only the app's own form was recognised and everything
  else was "an own command".
- **The code editor opens any .ps1 in the app's package folder** (it took
  only Install.ps1, Uninstall.ps1 and Invoke-AppDeployToolkit.ps1, spelled
  exactly so - install.ps1 was refused); its tabs list every script there.
- **Edit as text opens the code editor**: for the install and uninstall
  command, with a tab for each, colours, find, the 1024-character count
  and Apply; for the detection script, with the parse check.
- **Winget: the Install row links to the Winget ID** (it looked locked,
  but the ID is set on Basics); its tip says why -e, --source winget and
  --silent are always there. **"Written in an older form"** has a
  "Write today's form" button - the same values, rewritten in one click.

## 2.27.5

- **The editor, the same pass as Add apps.** Every tab starts its card
  and heading at the same height (Details sat lower because of its Fill
  button, Requirements and Dependencies 12-24 px lower); the install card
  and the detection rule card no longer share an edge; Description and the
  Publisher row, Architecture and its tick boxes, and Managed updates and
  Install with have room between them; this app's release rule has its
  heading inside the box instead of cut into the border (the same for
  every such box in the app).

## 2.27.4

- **Add apps looks right on every tab.** "Fill in by hand..." sits at the
  end of the tab row instead of squeezed against the window's buttons;
  every row has the same room above it (the search hint, Start from,
  Managed updates no longer touch what's above); the Winget results and
  From a list fill the tab, and say what appears there while they're
  empty (no header strip over a blank area); Install.ps1 and
  Uninstall.ps1 are in a code font with lines kept whole; the Detection
  box has its heading inside.
- **A ticked checkbox showed no tick in some places** (Settings > Apps &
  defaults: Architecture, Allow uninstall; the editor's copies) - a field
  rule gave them padding, which pushed the tick out. Every checkbox is now
  the same 16px box everywhere; a check over every page and dialog
  confirms it.
- **Room where things touched**, found by a check over every page,
  Settings section and dialog: Packaging's "Build packages with" and its
  status lines, the platform script dialog's Run as row and its groups
  note ("Assigned to" instead of a second "Groups").

## 2.27.3

- **Home: "Install the WinGet PowerShell module" has an Install it
  button.** It installs Microsoft.WinGet.Client from the PowerShell
  Gallery for your user only (the same way Settings > Prerequisites
  installs the Graph module), into the PowerShell the app runs in, and
  winget is asked through it straight away - no PowerShell window, no
  command to copy, no restart.
- **Apps list**: tick box, icon and name sit on the same line as the
  other cells (the name used to sit a few pixels higher).
- **Home loads faster.** It now comes in two parts, asked at the same
  time: what the app knows itself (catalog, last nightly run, setup) shows
  at once; Intune's release and install counts - the slow part - are added
  when they arrive ("Reading install counts from Intune..." meanwhile).
  The Intune part is kept for 45 seconds (new at once when the catalog
  changes, a step finishes, or you press Reload), the nightly task's
  state for a minute (asking Task Scheduler took a second or more each
  time), and what an own package's installer says (version, product
  code) as long as it's the same file - Home, Updates and the Apps list
  read it often.
- **"N app(s) with details missing" no longer stays forever.** Home asks
  for a publisher, a description and an information link; when winget's
  entry doesn't have one of them, Fill in details couldn't fill it and the
  item never went away. Fill in details now says what winget lacks ("winget
  has no information link for MySQL Workbench - type it in the editor if
  you want it") and Home stops asking for exactly that until the app's
  Winget ID changes. The information link also falls back to the
  publisher's support page when winget has neither a homepage nor a
  publisher site.

## 2.27.2

- **Send settings / Deploy of a managed Winget app sent a detection script
  without the app's name** (`$NamePattern = ''`), so Checks kept reporting
  "Detection rule differs" however often it was sent. The copy pinned to
  the App version for the send now carries the app's name (and the name
  Windows lists it under), so Intune gets exactly the catalog's script.
  Send settings once more for the managed apps already in Intune - a
  re-check then finds nothing. Devices weren't affected beyond the
  detection falling back to winget's list.

## 2.27.1

- **Checks > Compare**: a finding where the catalog and Intune differ
  (settings, detection rule, return codes, groups, dependencies) has a
  Compare button - catalog on the left, Intune on the right, the
  differing lines and characters marked. A detection script is spread out
  line by line instead of one long JSON line. Tick several findings and
  Compare steps through them; Take from Intune / Send settings / Send
  groups are right there.
- **Checks**: the fix buttons stay in the toolbar while there are
  findings (greyed out until something is ticked), so ticking a finding
  no longer pushes the table down.
- **Creating a group**: the few seconds Entra ID needs before a new group
  can be read no longer log red `[GRAPH] ... FAILED ... NotFound` lines;
  the wait says "Entra ID is still copying the new group (normal)".
- **Groups page: search all of Entra ID.** The list showed only the
  groups the catalog's apps use, and Open took the typed text as an exact
  name - so searching for "intune" opened a new, not-yet-created group
  called "intune". Now **Search Entra ID** (or Enter, or "All groups in
  Entra ID" in the list's picker) lists every Entra ID group whose name
  contains the text, `*` as a wildcard, with its kind (Security, dynamic,
  Microsoft 365) and how many catalog apps use it. A search with no match
  in the catalog offers the Entra ID search in one click; with no groups in
  the catalog yet, the page starts on Entra ID's list. New group still
  starts a new one.
- **A group just created shows as created.** Entra ID's search by name
  lags behind a new group for a while, so the page re-read it and said
  "Not in Entra ID" - and Create group again could have made a second one
  with the same name. The app now keeps the new group's ID for 15 minutes:
  the page shows it by that ID ("Just created" while Entra ID catches up,
  then its members), the list counts it as there, and saving it again
  updates that group instead of creating another.
- **Home shows what's running.** A Home button that starts something
  (Take winget's versions, Switch them, Fill them in, ...) spins and says
  "Working...", a bar moves under its row and the card's header says
  Working... - through Home's own refreshes, until it has finished. Check
  everything now spins too ("Checking...").

## 2.27.0

- **Switch from Winget-AutoUpdate**: an app whose catalog entry has no
  Winget ID takes the one its WAU command installs (`-AppIDs
  "OpenJS.NodeJS"`) and is switched. When the catalog's Winget ID is
  another one than the command's, the message now names both, so you can
  set the one you want and switch again - nothing is guessed.
- **Apps list**: an app without an icon shows its first letter on a colour
  of its own, instead of a grey square that looked like a checkbox (rows
  are picked by clicking them; Ctrl or Shift for several).
- Checkboxes everywhere are drawn by the app: a thin outlined box, blue
  with a white tick when ticked (the browser's dark-mode box was a solid
  grey block).
- **Side panel of a Microsoft app** (Microsoft 365 Apps, Company Portal
  before it's set up as a Store app): no Version picker (there's no version
  to pick), no group fields while it isn't in Intune from here (nothing to
  send them to), and no "Next step: Edit" that only opened the editor
  again. Store apps don't show the Version picker either.
- **Messages after an action** (and their Undo) show sharp on top while a
  dialog is open - they were under its dimmed, blurred background and
  couldn't be clicked.
- **Apps list: checkboxes to pick several apps** - one before each app (that
  app in or out, the others stay picked; Shift for a range) and one in the
  header for every app in the view (a dash when only some are picked).
  Clicking a row still picks just that one; Ctrl/Shift+click work as before.
- **Changes to send**: an app in Intune whose settings or groups changed in
  the catalog since they were last sent shows **Changes to send**, with the
  send it needs (Send settings, or Send groups) as its next step; after Save
  a message says Intune still has the old ones, with **Send now**. Known
  for what's sent from this version on (a fingerprint of what was sent is
  kept next to the catalog); a managed app's version, commands and
  detection are left out - releases send those.
- **Reload** button in the Apps toolbar: the catalog and Intune read again.
- **Fill in details from winget** (More, for the selected apps; Catalog >
  Fill in missing details for all): publisher, description, information and
  privacy links and developer from winget, and the **owner** from a new
  setting (Settings > Apps & defaults > Owner) - only where a field is still
  empty, never the App version (managed updates pin and release it). With
  Undo; apps already in Intune then show Changes to send. New Winget apps
  get the default owner too.
  Also in the editor (**Fill from winget** by Intune details - into the form,
  kept with Save) and on Home ("N apps with details missing" - **Fill them
  in**).
- **A missing API permission** says so in one sentence ("the app
  registration is missing the API permission X ... Add required
  permissions... adds it"); the full answer from Graph goes to the log.
  Home shows **Missing API permission** until a call with it works again,
  and Diagnostics > Check permissions counts a ReadWrite permission as
  covering its Read.All.
- **Spacing in forms**: room under every section heading, and a button,
  checkbox or label after a field, list or checkbox no longer touches it
  (Supersedence, Dependencies, Return codes, Allow uninstall, rings).
- Ticked checkboxes inside labels (Settings: release window days, ...) show
  their tick - a stretching rule made them solid blue squares.

## 2.26.3

- The tenant test checklist has a section for the blocks and the code
  editor (10c), and the "renamed group" step says what the app does now.

## 2.26.2

**Bug review fixes.**

- **The app editor's blocks**: a value typed into a block and then Save
  (or Ctrl+S) is saved - it was written into the command only after the
  save. Escape with such a value asks first.
- **The code editor**: minimized and opened again, it comes back as it was
  instead of reloading over what was typed; a detection script is applied
  only to the app it was opened for; Build package's progress shows on top.
- **Ctrl+S** saves the app editor only when it's the window on top (not
  under a question, the history or the code editor); Ctrl+F no longer
  swallows the browser's find in a dialog.
- **Home**: a failed refresh keeps what was shown; a button whose action is
  still running stays disabled through the minute's refresh, and the
  refresh waits while you're on Home's buttons with the keyboard.
- **Being changed (several admins)**: works on PowerShell 7 too (times
  were read differently there), counts another user's window on the same
  PC, refuses a second start in the same window (a double click no longer
  makes two pilot apps), is taken in one step (two PCs can't both get it),
  and now also covers deploy, send groups, delete and retire.
- **Time stamps** are written the same way in every Windows language (a
  time separator other than ":" kept releases from moving on automatically).
- **Groups renamed in Entra ID**: the message points to Replace a group,
  and a rename made here moves the kept object ID with it; the IDs of
  parallel sends are no longer lost.
- winget answers with a progress spinner in front of a line are read
  correctly; WAU options in capitals (--Override) are taken; a carried
  option that makes the pinned command too long for Intune is left out.
- A package script in the ANSI code page (an older one with umlauts)
  opens with its umlauts.

## 2.26.1

**A consistency pass over every page and dialog** (dark and light, wide
and narrow):

- Every page's toolbar is the Apps page's panel now - Home, Updates,
  Checks, Groups and Platform scripts - with related buttons joined into
  one control and counts as badges.
- Checks: the coffee and theme buttons no longer wrap onto a row of their
  own; "1 selected" without the stray colon.
- Updates' tiles are Home's tiles (size, accent edge).
- One style for table headers, pills and chips (square like the rest, not
  rounded ends), and the corner sizes everywhere from the same three steps.
- Every dialog's buttons sit on a footer line, as in the app editor; one
  size for dialog titles.
- The blocks' fields are their own size again (30 px), the return-code x
  is quiet grey, the code editor marks the open file, and its file tabs are
  joined.
- Small tables no longer stretch into an empty band; with the side panel
  open on a narrower screen, the Source column steps aside so Stage stays
  readable; the Apps search box shows its whole hint.

## 2.26.0

**Commands and detection as blocks, and package scripts edited in the app.**

- **Blocks** (editor, *Install & detection*): the install and uninstall
  commands are shown as blocks - **locked** ones (dashed: what the tool
  writes the same way for every app - the 64-bit PowerShell, finding winget,
  msiexec's silent switches) and **editable** ones (this app's values),
  plus **linked** ones set in another field (the pinned version: *Install
  with*; machine or user: *Install for* - a click goes there). The command
  below is the read-only result.
  - **Winget**: extra winget options as blocks (`--override`, `--custom`,
    `--architecture`, `--locale`, `--installer-type`).
  - **MSI**: the file, public properties (`ALLUSERS=1`,
    `TRANSFORMS=Company.mst`, `INSTALLDIR="C:\Apps\X"`) and the product code.
  - **Installer (.exe)**: the file, its maker (Inno Setup, NSIS, WiX
    bundle, InstallShield, Advanced Installer - their silent switches) and
    extra switches.
  - **Script app / PSADT 4**: the scripts (open them in the editor) and
    PSADT's deploy mode (Silent, NonInteractive, Interactive).
  - **Edit as text** makes it your own command, kept exactly as typed; the
    blocks come back when it's one of their forms again.
- **Detection script as blocks**: the managed release's script (the name
  Windows lists editable, the version linked to the App version, winget
  as the fallback) and the installed-app script (name and minimum version).
  An own script opens in the code editor.
- The blocks are read from the commands and written back to them - the
  commands stay the one stored truth, a form counts only when writing it
  again gives exactly the same command, and every value is checked on the
  server (they run as SYSTEM): no quotes or shell characters, known options
  only, within Intune's 1024 characters.
- **Package scripts in the app**: `Install.ps1`, `Uninstall.ps1` and
  `Invoke-AppDeployToolkit.ps1` open in a code editor - line numbers,
  PowerShell colours, Tab, Ctrl+F, Ctrl+S. The version marker the detection
  rule reads is **locked** (grey); the script is checked as you type and
  can't be saved while it doesn't parse. Saving refuses if someone changed
  the file since you opened it, keeps the earlier one in Backups (recorded,
  so **Previous version** can trust it), notes who changed it in Recent
  changes, and offers **Build package**. Only those files, in the app's own
  package folder.
- Reviewed for security, correctness and behaviour before release: the
  version marker is checked by where it runs in the script (not commented
  out, put in a condition or after an exit), MSI values with `%VAR%` are
  quoted, links in the package folders are refused, release marker writes
  share the save lock, and the editor keeps focus, sequence and Ctrl+S to
  itself.

## 2.25.0

**Extra winget options per app.**

- The editor (*Install & detection*, under *Install with*) has **Extra
  winget options**: `--override`, `--custom`, `--architecture`, `--locale`
  and `--installer-type`, added to winget's install command - for the few
  packages whose own silent switches aren't what you want.
- They live in the install command itself and are read back from it, so
  they stay through every new pinned version, a new Winget ID or another
  install context - nothing to keep in sync.
- The command runs as SYSTEM on every device: only those options are
  taken, values are checked (no double quotes, backtick, `$`, `%`, `;`,
  `&`, `|`, `<`, `>`, `^`) and single-quoted, and anything else is refused,
  not cleaned up. Within Intune's 1024 characters for an install command.
- **Switch from Winget-AutoUpdate** carries the winget options WAU passed
  after the ID over (`--override /S` stays `--override '/S'`) instead of
  leaving them out; only options winget's own command can't take are left
  out and listed.

## 2.24.2

- **Switch from Winget-AutoUpdate** also takes WAU commands that pass
  winget options after the ID (`-AppIDs "7zip.7zip --scope machine
  --override /S"`). winget's own command installs for the machine already
  and uses each package's silent switches; any other options left out
  (such as `--override /S`) are listed after the switch, so you can check
  those apps.
- **Home refreshes by itself:** after any change made in the app, when you
  come back to the window, and every minute while it's open (so another
  admin's changes show up too) - quietly, without "Looking..." each time.

## 2.24.1

- **Switch from Winget-AutoUpdate** now also switches apps whose WAU
  commands are worded differently from this tool's (another PowerShell path,
  other quotes, extra switches such as `-Silent`): any command that runs
  `Winget-Install.ps1` for the app's own Winget ID. Only commands for
  several or other IDs are left to you. A switch that changed nothing no
  longer offers Undo.
- **Fix Company Portal** explains why: Company Portal only exists in the
  Microsoft Store, a winget package of it often fails on devices, and
  Intune's Store app type installs it, keeps it updated and reports it
  correctly - and when to skip it.
- **Apps page header:** the controls sit on one panel - a search box with
  a search icon, the view buttons (Save view, Columns, Recent changes) and
  the actions on the selected apps (Send to Intune, More) each joined into
  one control, the app count as a badge. The counters under it are one
  strip, the chosen one marked, with a green dot when Intune was read.
- **Less rounded corners** everywhere: panels, buttons, fields and dialogs
  (6, 4 and 3 px instead of 14, 8 and 6).

## 2.24.0

**Ready for several admins, other Windows languages and larger catalogs.**

- **Who is changing what:** while a release, deploy or push runs on an app,
  the Apps list shows it as **Being changed** - with the Windows user and
  PC, also when that's another admin on another PC (the markers live in the
  catalog's `.integrity` folder). **Recent changes** shows who made each
  change.
- **Groups by object ID:** the first time a group is sent to Intune, its
  Entra ID object ID is remembered next to the catalog. A group renamed in
  Entra ID stops the step with a clear message instead of failing on a
  name lookup, and a name that two groups share is never guessed.
- **winget in any Windows language:** winget's answers are read in German,
  French, Spanish, Italian, Portuguese and Dutch too (search, details,
  versions, Checks). With Microsoft's WinGet PowerShell module installed
  (`Microsoft.WinGet.Client`), it's used first - exact in every language;
  Home suggests it on a non-English Windows.
- **Faster Apps list:** a catalog of 500 apps loads several times faster on
  Windows PowerShell 5.1 (the default values no longer walk the whole
  catalog once per app).
- **Compliance report:** Updates > **Compliance report** (was Export CSV)
  adds per app whether it meets the bar - 90 % of devices on the pinned
  version and that version still downloadable - and a totals row.
- The tenant test checklist has a section for what 2.20 - 2.24 added.

## 2.23.0

**The Backups folder can't be used to slip a change into the catalog.**
The Backups folder may be a share more people can write to than the catalog
folder. What comes back from it is now only taken when the catalog itself
vouches for it:

- Every copy this app writes there (Earlier versions, the copies Undo puts
  back, retired apps) gets its SHA-256 fingerprint recorded in the catalog
  folder (`.integrity\copies.tsv`, with the catalog's permissions).
  **Restore, Undo and Restore a retired app refuse a copy that was changed
  since**, or that was never recorded (put there by hand). Earlier
  versions marks such copies **not verified**.
- **The change history moved next to the catalog** (`.integrity\history`),
  out of the Backups folder. History from before this version is still
  shown, but nothing is undone from it.
- Copies kept before this version can't be verified, so they aren't
  restored automatically; the ones written from now on are.

## 2.22.1

- **Settings > Apps & defaults**: the Architecture checkboxes take a
  field's height, so the two columns of default values line up row by
  row (Install for next to Min. memory, Minimum OS next to Min. CPU
  speed, ...).

## 2.22.0

A second full sweep - bugs, security, usability and the look - with every
finding checked before it was fixed.

**Security**
- **Groups with the same name**: Entra ID allows several groups of one name.
  Sending groups, assigning, deleting and saving a group now refuse when a
  name matches more than one group, instead of taking whichever came
  first - a look-alike group made by someone else can't get an assignment
  (or be deleted in place of the real one).
- **Undo** of one change only applies to that app's own history, and it
  no longer puts back install/uninstall commands or detection rules on
  its own (they run as SYSTEM on devices, and the history is a file in the
  Backups folder) - Earlier versions brings those back with the whole file.
- **Managed apps' commands** can't be changed through Batch edit or a CSV
  import (they follow the pinned version; a CSV could otherwise skip the
  pilot).
- **PSADT template**: every .exe, .psm1 and .psd1 in it must be signed by
  the toolkit's own signer (and .dll files validly signed), not only the
  module.
- **The generated winget command run as SYSTEM** takes winget only from its
  protected App Installer folder, never from PATH (a PATH folder can be
  writable by users). Commands made before are still recognised.

**Bugs**
- **Group boxes**: typing an existing group's exact name and pressing Enter
  added a longer, different group from the suggestions. Nothing is
  highlighted now until Down arrow is used; comma and semicolon always add
  what's typed; the list no longer opens over the fields when a tab is
  switched.
- **"only in Intune"**: a hidden app stayed selected (Enter/Delete acted
  on it), the filter couldn't be left with the dropdown, and with an empty
  catalog nothing showed - all fixed.
- **Minimized windows**: the chips go into the window on top (by opening
  order), stay clickable, sit outside the window's buttons, and no longer
  move along when a window is dragged.
- **Group description** can be cleared.
- **Versions**: the editor's list no longer shows another app's versions;
  "Other" in the side panel doesn't get stuck; a script app's version
  change says to build its package again (with a Build button).
- **Recent changes** keeps open entries open after an Undo, reads only
  what it shows, and is read again when restored; History doesn't offer
  Undo for release steps.
- Checks' group count counts each group once; a BOM in scripts read from
  Intune is removed again on Windows PowerShell.

**Usability**
- **One next step**: the toolbar no longer repeats the row's next step.
  An app in pilot offers **Next ring...** while rings are left (as
  Updates does), **Pin newest** pins winget's newest version of that app
  only, **Needs a look** opens Checks for that app (and checks it).
- **Several apps selected**: the side panel stays, with what they are and
  Send to Intune / Add groups / Batch edit for all of them.
- **One set of words**: In Intune / Not in Intune yet, Send to Intune, Send
  settings, Send groups, Take from Intune - on every page.
- **App ID** is linked by picking an Intune app (or unlinked), not typed;
  **version** fields have a **Pick...** list of winget's versions;
  **Publisher** in Add apps offers the catalog's names; **Install time**
  suggests common values.
- **Settings** shows "Unsaved changes" on a card and asks before leaving.
- Checks' fix buttons show only once findings are ticked; Updates offers
  **Send to Intune...** for apps not in Intune yet; Groups says
  **Unassign** (catalog) and **Remove member** (Entra ID); toasts that tell
  you to send groups have the button; one date format everywhere.
- The editor and Add apps keep one size on every tab.

**Look**
- Buttons, fields and dropdowns share one height (34 px), small buttons
  another (26 px); rows in the apps list are all the same height; IDs no
  longer break inside a word; checkboxes line up with the first line of
  their label; return codes and their type line up; the "?" buttons are
  all the same; the file picker matches the app's buttons; the maximized
  editor keeps its buttons at the bottom; the release-ring arrows are
  visible again.

## 2.21.1

- **The side panel's version picker works for every Winget app.** Change
  (winget's versions, newest first) was missing for an app still on the
  default settings, and the quick edit refused it; picking a version now
  gives it settings of its own (the defaults) with that version.
- **The side panel's version is one steady field**: the version as it is
  now, and opening it lists winget's versions (asked the first time),
  newest first, plus the ones kept from earlier releases and "Other" to
  type one. No button that turns into a list - nothing moves.
- **"only in Intune" shows only those apps.** It added them under the
  whole catalog list; now the list is just the Intune-only apps, and the
  count says so.

## 2.21.0

- **Recent changes.** A clock button on the Apps toolbar (and Catalog >
  Recent changes, Ctrl+K) opens every change to the catalog, newest
  first: when, from where (Editor, Batch edit, Updates, the nightly run,
  ...), what, and which apps - an action on many apps is one entry you
  open to see each app's fields, before and after. Each change can be
  undone on its own, and the last bulk change as a whole ("Undo it").
  The bar over the apps list is gone; a dot on the clock says a bulk
  change can be undone.
- **Apps > Version says which version devices get**, one way per app:
  - **pinned** (managed updates): a lock and the version - with an arrow
    when winget has a newer one to release;
  - **newest** (the winget command): devices get whatever winget has,
    its version today in grey - no arrow, there's nothing to release;
  - **not pinned yet**: managed, but the version to pin isn't set;
  - **Store**, **-** (Microsoft's own apps) and **not set** (own
    installer without a version).
- **Pick instead of typing**:
  - **Version** in the side panel: Change opens winget's versions (newest
    first) and the ones kept from earlier releases; "Other" still lets
    you type one. The editor's App version and Release new version offer
    winget's versions the same way.
  - **Publisher, Owner and Developer** (editor and Batch edit) offer the
    names the catalog already uses, so they're written the same way.
- **Group boxes**: Enter adds what's typed when no suggestion is
  highlighted (it did nothing while the suggestion list was open).

## 2.20.1

The cosmetic leftovers from the 2.20 sweep.

- **Editor > Basics**: the fields get the room; "Ready to send?" is a
  narrower column beside them that stays in view.
- **Add apps** is as tall as the tab's content (no blank band under a
  short tab), and opens near the top so switching tabs doesn't make it
  jump.
- **Groups**: the description has its own **Save** right beside it. The
  button under To add only shows when there are members to add (it says
  how many).
- **Checks**: the fix buttons sit together on a row of their own.

## 2.20.0

A full sweep: the server logic, the pages' behaviour, the layout of every
page and window, and every message checked against a real catalog (49
apps, none in Intune yet, Company Portal, Microsoft 365 Apps).

**Fixed - could go wrong in Intune**
- **Pilot and ring releases with two or more groups** were assigned to one
  made-up group named after all of them (and that group was created). Each
  group is assigned again. The nightly run's health checks and drift
  report, Settings > Diagnostics' health list and CSV import of several
  dependencies had the same cause and are fixed too.
- **Send groups keeps a release's assignment settings** (install deadline,
  restart grace period, Company Portal auto-update) for assignments that
  stay, and sends nothing when nothing differs.
- **Promote and Roll back no longer offer Undo**: Intune has already
  changed, so undoing only the catalog pointed it at the wrong app.
- **The nightly run doesn't release a withdrawn version again** through
  the test-tenant gate, and doesn't say "the newest on winget" when
  winget wasn't asked.
- **Switching from Winget-AutoUpdate**: apps in Intune without an App
  version get the winget command (managed updates once they have a
  version), so Send to Intune really updates them; apps whose WAU commands
  were edited by hand are named instead of being counted as switched.
- **A Win32 package with a Microsoft name** (an Office Deployment Tool
  package called "Microsoft 365 Apps for enterprise") is built and sent as
  usual - only an app with nothing of its own counts as Microsoft's.

**Fixed - what the pages say**
- **Apps > Version shows the App version.** It showed the version Intune
  last reported, so it was empty for apps not in Intune, and managed apps
  looked like they had no version ("Set version").
- **Stages**: Company Portal / Microsoft 365 Apps show "Microsoft app",
  Winget-AutoUpdate "Retire", and an own package without an install
  command or detection rule "Draft" (Send to Intune refuses those). The
  Stage column sorts by stage.
- **Side panel and editor** describe updates per kind: managed, the
  winget command, the Store, an own installer, Microsoft. The editor's
  Ready checklist fits Store and Microsoft apps; the installer box is
  hidden for them and knows script apps.
- **Home**: "Winget apps without managed updates" leaves out Store apps and
  WAU; the WAU advice says "remove from the catalog" when it isn't in
  Intune; "Check everything now" says when Intune wasn't compared; the
  release count matches its list.
- **Checks** shows what was compared apart from what wasn't, and counts
  only the catalog's groups.
- Old names (Deploy, Push groups, Add app, WAU) are gone from texts and
  docs.

**Fixed - windows and pages**
- **A minimized window comes back as it was** when opened again - it was
  refilled before (a half-edited app lost, a running deploy's list reset).
  Its chip works while another window is open, a Sandbox test keeps going
  while minimized, and Tenant setup is read again when restored.
- The side panel no longer shows an app when several are selected; saving
  one Settings card keeps what's typed in the others; the Updates page is
  read again after Promote, Withdraw, Roll back and Advance; the job tray
  no longer blocks the list keys and Ctrl+K; Home and Groups ignore late
  answers; Home's buttons wait for their action.
- **Layout**: the Apps toolbar stays on one line on wide windows (coffee
  and theme top right on narrower ones), Groups' cards stack below
  1360 px, Settings' default values use the full width (return codes and
  dropdowns readable), fields in a row line up, Updates' tiles stay in one
  row, Batch edit's buttons stay in sight, small row buttons have the
  fields' height, focus rings match the app, missing labels added.


**New**
- **Windows have minimize, maximize and close** in their top right
  corner, as in the other NOBS apps. A minimized window keeps what was
  typed in it and waits as a chip at the bottom right (its name restores
  it, x closes it); maximized it fills the window; it moves by its title,
  and a double-click on the title maximizes it. Close asks about unsaved
  changes, as Escape does.
- **Coffee and theme sit at the end of each page's toolbar**, on one line
  with its buttons.
- **Groups and apps**: groups set on apps are columns again (the grid
  could show "0 groups"), the columns sit next to the app names, rows are
  striped, and with no groups yet it says how to add them.
- **Send to Intune isn't shown twice** for several selected apps either.
- **Company Portal: one click.** Home's Microsoft apps item has **Fix
  Company Portal**: it becomes the Microsoft Store app (9WZDNCRFJ3PZ), so
  Send to Intune creates it as Intune's Store type. Microsoft 365 Apps is
  still added in Intune itself.

## 2.19.1

- **Apps > Version** is never just empty. An app without an App version
  shows what devices actually get, greyed: **newest (24.09)** for a Winget
  app (winget's version from the last check), **Store** for a Store app,
  **not set** for an own installer. Hovering explains it.
- **Company Portal and Microsoft 365 Apps** show as **Microsoft (Intune)**
  with the stage **Microsoft app** - not "own installer", "Draft" and
  "Build", since there's nothing to build.
- **Winget-AutoUpdate apps switch by themselves.** At start, apps that
  still have WAU's commands and aren't in Intune yet are switched to the
  default install method (Managed updates or the winget command) - nothing
  to send, so nothing to click. Apps already in Intune stay on Home's
  **Switch them**, which also sends the new commands. Both follow the
  default install method now, not always managed updates.
- **No second "Send to Intune" button**: the next-step button only shows
  when the next step is something else.
- **The Apps toolbar wraps** on narrower windows instead of pushing the
  side panel off the right edge.

## 2.19.0

Winget-AutoUpdate (WAU) is removed. Managed updates are the one way the
catalog updates apps.

- **No more WAU commands.** New apps, the editor's Install with, the
  default setting and batch edit offer Managed updates or the winget
  command only. A setting saved with WAU loads as Managed updates.
- **No WAU dependency.** The default dependency on a "Winget AutoUpdate"
  app is gone, also from settings saved before.
- **Home > Switch them.** Apps still installing through WAU, or depending
  on it, are listed. One click turns managed updates on, pins each to its
  App version (the newest from winget until it has one), removes the WAU
  dependency and pushes the new commands to Intune. Undo works.
- **Home** also says when the WAU app itself is still in the catalog:
  retire it to take it off the devices.
- **Company Portal installs are updated too.** When a release is
  promoted, its Available assignments have Intune's "auto-update
  superseded apps" on, so devices that installed the app themselves get
  the new version - not only the Required groups.

## 2.18.1

Layout fixes, found by checking every page and Settings section for
fields that are cut off, overflow their card or don't line up.

- **Home** is laid out again: the numbers on top, then **Needs
  attention** as one card with a row per item, and Getting started and
  shortcuts beside it (under it on narrow windows).
- **Company Portal and Microsoft 365 Apps** no longer count as "own
  package(s) not built". They are Microsoft's own Intune app types, so
  there's nothing to package: Home lists them apart with what to do
  (Company Portal: use its Store ID 9WZDNCRFJ3PZ as the Winget ID;
  Microsoft 365 Apps: add it in Intune itself), and Deploy says the same
  instead of asking for a package. Apps already in Intune as a Store or
  Microsoft 365 app are never counted.
- **Editor > Basics > Install with** (Winget apps): choose Managed
  updates, Winget-AutoUpdate or the winget command per app. The commands
  are rewritten to match (after asking, when they were edited by hand). A
  line under it says which version devices get: managed apps "exactly
  24.004 (the App version)", WAU and winget "whatever version winget has
  at that moment - nothing is pinned", plus what winget offers now (last
  check) and whether anything updates the app afterwards.
- **Own-package apps** show which installer gets uploaded: the file in
  the package folder and its version, next to the App version, with a
  note when the two differ.
- **The release rule's** three fields line up, also when one label
  wraps onto two lines.
- **Group warnings** under a group box: one left over from before
  (the box emptied, a chip removed, another app opened) is cleared. A
  group that's only written differently in Entra ID (case, spacing, a
  different dash, & or "and") is named: "did you mean ...?". Otherwise
  it says plainly that pushing would create a new, empty group.
- **Settings > Apps & defaults > Winget apps install with**: changing it
  now offers to switch the Winget apps already in the catalog as well
  (and to push the new commands to the ones in Intune). Before, it only
  shaped apps added afterwards. Hand-edited commands and managed apps'
  pinned commands are kept; choosing Managed updates offers to turn them
  on for all.
- **Settings > Updates**: the pilot groups are **Ring 1 - Pilot**, in the
  same row layout as the rings after it, so it's clear the first box is
  the first ring. Ring names and group boxes have the same height.
- **Group boxes** everywhere are as high as the text fields next to them.
- **Settings > Apps & defaults**:
  - The default values no longer run out of their card, and the return
    codes show their full type, with a small x to remove one.
  - Assignment profiles show the name on one line and their three group
    boxes under it. Before, the name box was two letters wide and
    Excluded ran off the card.
- **Headings inside a card** are smaller than the card's title, with even
  spacing and a divider (Nightly run, Updates and others).
- **Toolbars**: all buttons and fields in a row are the same height (Save
  view... and Columns... on the Apps list, the time on Nightly run).
- **The theme and coffee buttons are top right**, as in our other apps, in
  a slim bar above every page that also shows the page's name.

## 2.18.0

Day-to-day logic and leftovers, from a review of how the app is used every
day.

### Releases and updates

- **A withdrawn or rolled-back version isn't released again by itself.**
  The nightly run used to release it again every night. It now says so on
  the Updates page. Releasing that version by hand clears the block.
- **Rollback and clean-up go by version number, not date.**
  - The version rolled back from is kept as *rolled back*. It is never a
    rollback target, and clean-up deletes it.
  - Clean-up finds the release that actually supersedes the one it
    deletes, so it no longer fails after a rollback.
  - Clean-up also runs for apps that no longer have managed updates.
- **A release that wouldn't install the new version is refused.** That
  happens when the install command or detection was edited by hand; before,
  the release installed the old version and was still promoted.
- **A pilot whose assignment failed is assigned by the next nightly run.**
  Before, it stayed in pilot with no groups.
- **The page and the nightly run can't change the same app at the same
  time.** Before, that could create a duplicate pilot or leave the app
  with no groups. One gets "being changed elsewhere".
- **MSI apps**: every release keeps its product code, a rollback restores
  it, and the uninstall command follows a new product code.
- **PSADT apps**: the version is read from the installer in Files, not
  from the toolkit's own exe.

### Sending to Intune

- **An own package (MSI, EXE, script, PSADT) without managed updates**
  that is already in Intune gets its package uploaded again when it's
  newer than the last one. Before, devices kept the old installer.
- **A failed upload no longer leaves an empty app in Intune.** It is
  deleted again, and the encrypted copy of the package is always removed
  from the temp folder.

### Editing

- **The editor can't change the version of a deployed app with managed
  updates.** That goes through Release new version, pilot first. It also
  can't switch managed updates off while a version is in pilot.
- **History**:
  - Undo isn't offered for changes that came with a release step
    (promotion, rollback).
  - Undoing a version change of a deployed managed app is refused.
- **Renaming an app**: other apps' dependencies on it, and its packages
  folder, follow the new name.
- **A new Winget ID**: the generated commands (with the pinned version)
  and the detection follow it, in the editor and in Checks' fix.
- **Renaming a group** on the Groups page also renames it in the pilot
  groups, release rings and assignment profiles. Before, the next pilot
  created the old, empty group.

### Retiring

- **Every version of the app in Intune** gets the Uninstall, counts in
  the progress, and is deleted at Finish (newest first).
- **Retiring an app other apps depend on is refused**, with their names.

### Leftovers and growth

- **Packaging**:
  - The temporary copies are removed when packaging fails too.
  - A packaging tool that hangs is stopped after 30 minutes.
- **Housekeeping at every start and before every nightly run** removes:
  - step files, unfinished uploads and packaging folders older than a day;
  - Sandbox test folders older than 7 days, and a Sandbox folder at once
    when the Sandbox doesn't start;
  - file backups older than 180 days;
  - logs older than 90 days.
- **The nightly run** stops (and cleans up) steps still running at its
  end instead of leaving them running.
- **The log starts a new file every day**, also while the app keeps
  running.
- **Reports**: nightly reports are kept for 400 days. Fast-track runs keep
  their last 60 separately and no longer push the nightly reports out of
  the monthly report and the trend.
- **Unchanged saves** (a Pull of an app that matches Intune) no longer
  write the file or make a backup.
- **The Activity box** keeps the newest ~2000 lines, and keeps getting
  new server lines after the server's list is full.
- **The nightly run's lock** remembers when its process started, so a
  reused process number after a crash doesn't block runs.
- **Pull reviews** left open without applying are dropped after an hour.

## 2.17.1

Fixes from a full sweep of the app (security, bugs, interface).

### Security

- **The PSADT template** is used only from its expected release file, and
  only when its toolkit module carries a valid digital signature.
- **App IDs** have to be GUIDs before they go into a Graph address, in
  every step that assigns or updates apps (Delete already did this).
- **Download checks** only ask https links, and follow redirects only to
  https.
- **Undo (History) and Restore (Retired apps)** only change fields the
  app has. They run the same checks as the editor's Save, and a managed
  app's commands follow its version.
- **Adding a PSADT app** refuses a name that would share a packages folder
  with another app. Before, the other app's script could be overwritten.
- Detection for apps without managed updates uses a temporary file of
  its own, and backslashes never get into a Winget ID in a command.

### Bugs

- **Download check**:
  - Works with winget in any language.
  - Says *winget no longer has it* only when winget really says so. A
    network or source problem is "not known", and no longer blocks a
    release.
- **Script and PSADT apps**: a new version (in the editor, the side panel
  or a release) now also changes the version marker in Install.ps1 /
  Invoke-AppDeployToolkit.ps1. Before, devices reported the app as not
  detected after a release.
- **Retire**: devices where the uninstall failed count as *still have it*,
  not as removed.
- **The 9009 Retry return code** goes to every app with the winget
  commands, not only managed ones.
- **Released versions** keep the Uninstall-entry detection.
- **History**:
  - Times are right on PowerShell 7.
  - Undoing the change that created an app's Intune details takes the
    app back to the defaults, not to empty details.
  - *Undo last bulk change* is recorded in History too.
  - Comparing versions shows changes to the assignment filter and
    retirement.
- Several downloads checked at the same time no longer lose results.

### Interface

- **Editor**:
  - The install and uninstall commands are on the *Install & detection*
    page.
  - "Go to the field" and the *Who gets it* tab put the cursor in the
    group box.
  - Picking a Winget ID with *Find...*, or a detection rule *From an app
    on this PC*, updates the Ready list.
- **Focus** comes back to where it was after a row's "⋯" menu, and after
  a quick edit in the side panel.
- **Menus**: the row menu and Columns close when focus leaves them. Arrow
  keys in Columns move between its options and no longer cause an error.
- **Loading placeholders** are cleared when reading fails.
- **The connection mark** in the icon rail is visible when not connected.
- **Checks** no longer says "agree" when not everything could be
  compared.
- Wording fixes.

## 2.17.0

Making the winget way of installing sturdier:

- **Pinned versions whose download is gone**: winget only knows where the
  vendor keeps the installer, and some vendors keep only their latest
  version online. A pinned version then stops installing - first on new
  devices.
  - Updates > **Check downloads** checks every pinned version (winget's
    installer link for it), and so does the nightly run.
  - A version that's gone shows *download gone* on the Updates page and
    as a problem on Home.
  - A version is not released at all if its download is already gone.
  - When the newest version still downloads, the app says the vendor
    keeps only its latest version online, and suggests fast track or
    managed updates off for that app.
- **Detection without winget**: a managed Winget app's detection script
  looks at the Windows Uninstall entries first (by the app's name, or its
  *Name on devices*). It is faster, and works while winget isn't there.
  Only when no entry has the version or newer is winget asked, as before.
- **New devices (Autopilot)**: the install command waits up to 5 minutes
  for winget, then exits 9009. That is now a *Retry* return code, so
  Intune tries again later instead of reporting a failure. The install
  status explains 9009.
- Apps whose commands were generated before keep being recognised, and
  get the new command, detection and return code the next time they're
  saved or released. Send them to Intune (or release) for devices to get
  them.

## 2.16.0

- **Navigation in a sidebar** with icons. On a medium-width window it is an
  icon rail (names as tooltips); on a phone it stays a top bar. The
  connection, the theme and the coffee button sit at the bottom of the
  sidebar.
- **Theme follows Windows**: one button switches between Automatic,
  Light and Dark. Automatic changes with Windows while the app is open.
- **Home**: what needs attention comes first. Getting started lists only
  the open steps, and the finished ones are one line of ticks.
- **Updates**: each row has one main action, and the others (Promote,
  Withdraw, Roll back) are in a "⋯" menu.
- **Checks**: the fix buttons appear once there are findings. Before the
  first run, the page says what it compares, with a Run checks button.
- **Loading placeholders** instead of "Reading..." in Updates, Home, the
  install status, the install status of every app, History and Retired
  apps.
- **Buttons come in three kinds**: the main action, normal (outlined) and
  quiet (text in the accent colour). The Settings buttons that looked like
  plain text are normal buttons now.
- **The editor's tabs are pages**: Basics, Who gets it, Details,
  Install & detection, Requirements, Dependencies - each shows its part
  only. Save still saves everything; a required field left empty brings
  its page up, and the Ready list's "go to the field" links open the right
  page.
- **Quick edits in the side panel**:
  - Each group has an × to take it off, and "+ Add" adds one, with the
    catalog's groups suggested.
  - The version has Change, for apps that have Intune details and aren't
    deployed with managed updates. Those get new versions through
    Release new version.
  - Changes save at once and show in History as from the side panel.
- **Apps list Columns...**: show or hide Source, Version, Who gets it and
  Stage, and choose Comfortable or Compact rows. This is kept in the
  browser.

## 2.15.0

A visual refresh across every page and dialog:

- Fields are filled, with a soft focus ring instead of an outline. Labels
  are a little stronger, and placeholders are quieter.
- Group chips have square corners everywhere: the side panel, the editor's
  group boxes and favourites. Long group names wrap instead of stretching
  the chip.
- Buttons have a calmer hover, and the primary button has a slight lift.
  Dialogs have rounder corners, a deeper shadow, a lightly blurred page
  behind them and a short slide-in. The slide-in is off when the system asks
  for reduced motion.
- The editor shows each column as a card and separates its sections with
  dividers. Its tabs are an underline bar. The *Ready to send* box is
  tinted, with round check marks.
- Table headings are small capitals.

## 2.14.0

- **Assignment filters**: an app's *Who gets it* takes an Intune
  assignment filter (picked from the tenant's) and whether the devices it
  matches get the app or not. It goes on every included group (Intune
  takes none on exclusions), in pushes, releases and retirements, and the
  drift check sees a changed or removed filter. Reading filters needs
  DeviceManagementConfiguration.Read.All - Check permissions says so when
  an app uses one.
- **Install errors explained**: the install status shows what each error
  code means and what usually fixes it (not detected after install,
  Windows Installer errors, a restart needed, a timeout, file not found and
  more; others by family), and *Why installs fail* lists the most common
  ones. The *N failed* count on the Updates page opens it.
- **Retire an app** (More > Retire...): its groups get it as Uninstall
  (the catalog's groups follow), the dialog counts the devices that still
  have it, and Finish deletes it from Intune, archives it and removes it
  from the catalog. **Catalog > Retired apps** restores one. The nightly
  run leaves an app being retired alone.
- **History** (the editor's History...): every change to an app in the
  catalog, field by field from what to what, with where it came from
  (Editor, Batch edit, Nightly run, Pull from Intune...), and every step
  that changed it in Intune - following renames. **Undo** puts one change
  back (only fields not changed again since). Earlier versions (whole
  files) are below it as before.
- **Built-in packaging**: .intunewin packages are built by the app itself
  (zipped, AES-256 encrypted, HMAC and digest as Intune expects) - no
  IntuneWinAppUtil.exe download needed. Settings > Packaging & folders >
  *Build packages with*: Automatic (the tool when it's there, built in
  otherwise), Built in, or IntuneWinAppUtil.exe. Tested by building a
  package and reading it back with the upload code.

## 2.13.0

- **Check permissions** (Settings > Diagnostics): the Graph permissions
  the app registration has, against what the features in use need - what
  to add, what's only partly there (Group.Read.All instead of
  ReadWrite), and what to remove; broad ones it never uses are called out.
- **Microsoft Store apps** (9N... / XP... IDs) go to Intune as native
  *Microsoft Store app (new)* apps: no package, the Store keeps them
  current, so managed updates and the metadata checks skip them.
- **PSADT 4**: a new tab in *Add apps* downloads the PowerShell App
  Deployment Toolkit 4 template, fills in vendor, name and version, adds a
  version marker for detection, and sets the toolkit's install and
  uninstall commands - managed updates on.
- README lists the two feature-only permissions (detected apps, email
  alerts).

## 2.12.0

### Security

Findings of a review of what was added since 2.5.0, all fixed:

- **The nightly git backup** no longer commits by itself: it's a switch of
  its own (off), runs git with its hooks, fsmonitor and untracked cache off,
  and refuses a repository whose .git belongs to someone else or sets a
  filter - on a share, someone else's .git could otherwise run a command
  as the user who holds the connection's certificate.
- **Downloaded installers** (own packages released by themselves) are used
  only when signed by the same publisher - subject and issuer - as a
  validly signed installer already in the app's folder; with none there,
  nothing is downloaded. Redirects off https are refused, and the size is
  capped.
- **Generated scripts** (detection and uninstall for an EXE, script-app
  templates, Sandbox tests, the unattended setup script) quote every name
  and value safely - typographic quotes doubled, line breaks removed - so a
  crafted product name can't end a string or a comment.
- **Uninstall.ps1 and detection for an EXE** match the product exactly (or
  with a version or "(x64)" after it), not by prefix - "Microsoft Teams"
  no longer matches "Microsoft Teams Meeting Add-in".
- **The unattended setup script and Sandbox tests** are written to your
  own local app data, not the Logs folder (which can be a share); the
  script's SHA256 is in the Activity log.
- **Teams alerts** can't carry links from app names or error texts.
- **Icons from homepages:** https only, a megabyte at most per page and
  icon.
- **The local server** doesn't read the body of a request it will refuse
  (another host or origin, not an API call).

### Added

- **Catalog lock across processes and PCs:** a lock file in the catalog
  folder while a change is written - the nightly run and other PCs using
  the same folder (a share) wait their turn; a long wait names who holds
  it.
- **A newer version of this app** shows on Home (GitHub, at most twice a
  day; *Settings > Apps & defaults > Tell me when a new version is out*).

### Changed

- **Faster with a big catalog** (especially on a share): each app file's
  text is kept until its time or size changes.
- **Start-up** asks for the log and the state at once.
- The Catalog menu's tools and the managed-update actions moved from
  apps.js to tools.js; browser tests for group chips and return-code rows.

## 2.11.0

### Changed

- **One "Send to Intune"** instead of Deploy, Push groups and Push
  settings: it creates or updates the selected apps - settings, package -
  and, with *Send their groups too* (on by default), their assignments.
  *Send groups only* and *Send settings only* are in the More menu.
- **A slimmer Apps list:** App, Source (winget package or "own
  installer"), Version, *Who gets it* ("3 groups" - the roles on hover)
  and Stage. Type and Last audit are gone - Stage says *Needs a look*
  when a check found something. The toolbar is **Add apps**, the selected
  app's **next step**, **Send to Intune**, **More** and **Catalog**; Edit
  is in the side panel, the More menu and a double-click.
- **One row above the list** instead of three banners: the catalog vs
  Intune counts, the other-tenant note and the last bulk change's Undo.
- **The editor's parts as tabs** - Basics, Who gets it, Details, Install
  & detection, Requirements, Replaces: one click to each (the deploy
  settings open by themselves), the part in view highlighted.
- **Check everything now** on Home: what differs shows on Home, on the
  apps (*Needs a look*) and in Checks, which is the detail view.
- **One word per idea:** *Send to Intune* / *Read from Intune*, *Send
  groups*, *version in pilot*, *Ready to send*, *Everyone*, *Only in
  Intune* - in buttons, menus, messages and tooltips.

## 2.10.0

### Added

- **The catalog and Intune, side by side** (Apps page): a strip above the
  list - *in the catalog*, *of them in Intune*, *only in the catalog* (not
  deployed yet), *only in Intune* (Windows apps made in the portal). Each
  is a filter; *only in Intune* adds those apps to the list, greyed, with
  **Add to catalog**. The catalog is the source of truth - anything only
  in Intune should be added to it, or deleted there.
- **Stage and next step:** every app shows where it is - *Draft*, *Ready
  to deploy*, *In Intune*, *In pilot x*, *Everyone*, *Needs a look*, *Other
  tenant* - and the one button that moves it on (Build, Set version,
  Deploy, Promote, Release, Checks, Clear App ID). The toolbar's primary
  button is the selected app's next step (or "Deploy N apps").
- **Side panel:** select one app for its stage, next step, versions,
  source, update mode, groups by role, release timeline and last check -
  with Edit, Install status, Test in Sandbox and More.
- **Groups as chips:** every group box (the editor's four roles, Add apps,
  pilot groups, favourites, profiles, release rings, platform scripts) is
  a row of group chips with an "Add a group" field - suggestions as you
  type, Enter (or comma, or a pasted list) to add, x to remove, Backspace
  for the last one. Alert recipients and default dependencies are chips
  too.
- **Return codes as rows:** an exit code and what it means (Success,
  restart later, restart now, Retry, Failed), Add / Remove - in the
  editor, the defaults and batch edit.
- **Release rings as rows:** a name and its group chips per ring.
- **Ready to deploy?** in the editor: name, installer or Winget ID,
  install command, detection rule, version (managed updates), groups -
  each missing one links to its field.
- **Getting started** on Home: seven steps from connecting to the
  nightly run, done ones ticked, "Do it" on the next.
- **"?" explanations** for managed updates, detection rules, the four
  assignment roles, release rings, fast track and supersedence.
- **Release timeline** (Updates page, side panel): Pilot > rings >
  Everyone, the current stage highlighted.
- **Next steps in messages:** after adding apps (Deploy, Build, Test in
  Sandbox), building, saving the grid (Push groups, Undo) or turning
  managed updates on (Undo).

### Changed

- **Settings** in five sections: *Connection*, *Apps & defaults*
  (default values, profiles, favourites, automatic checks), *Updates*
  (pilot groups, rings, release rule, fast track, window), *Nightly run &
  alerts* (schedule, runs, what else it does, health, running unattended,
  alerts), *Packaging & folders*, *Diagnostics*.
- **Actions run in a tray** in the corner, not a window you wait in -
  *Hide* it and keep working; the "Working..." button at the top shows it
  again.
- **The More menu** has headings (Package & Intune, Releases, Groups, App
  ID, Remove); *Pull from Intune* is **Read from Intune**, *Push settings
  to Intune* is **Send settings to Intune**.
- The **Status** column is **Stage**.

## 2.9.0

### Changed

- **Managed updates are the default.** New Winget apps install a pinned
  version and get new ones through the pilot groups (Settings > Defaults >
  Default values, "Winget apps install with", is *Managed updates* unless
  you chose otherwise). Add apps ticks it for winget packages, for MSIs
  (detected by product code and version) and for script apps (detected by
  their version marker).
- **Home** helps switch over: *Make it the default* when your settings
  still say otherwise, *Turn on for all* for Winget apps without managed
  updates, and *Take winget's versions* for managed apps that have no
  version yet - also ones already in Intune (their first version; deploy
  them again so Intune installs it).

## 2.8.0

### Added

- **Home** (the first tab): what needs a look, worst first, each with the
  button that fixes it - releases on hold or ready, failed installs,
  apps that differ from Intune (last night), certificate expiry, apps not
  deployed or own packages not built, a missing shared package, the
  nightly run unscheduled or with problems - and the catalog at a glance.
- **Group picker:** every "one group per line" box suggests groups as you
  type - favourites first, then the catalog's, then Entra ID's (when
  connected) - arrow keys and Enter to pick. Leaving the box names the
  groups Entra ID doesn't have yet ("a typo?").
- **Assignment profiles** (Settings > Defaults): named sets of Required,
  Available and Excluded groups; *Apply a profile* in the editor and in
  Add apps fills them in.
- **Test in Windows Sandbox** (More menu, own packages and script apps):
  installs the app with its install command in a throwaway Windows,
  checks the detection rule, uninstalls it and checks again - then says
  "ready to deploy" or which step failed, with the log.
- **Detection from an app on this PC** (editor > Deploy settings): pick
  the app from the ones installed here - an MSI by its product code and
  version, an EXE app by its program file's version, else its Uninstall
  entry.
- **Find an icon** (editor): the installer's own icon (an .exe in the
  packages folder), else the homepage's (its Information URL - https,
  PNG or JPEG).
- **Deploy right after adding** (Add apps): own packages are built, then
  the Deploy dialog opens for the new apps.
- **Add apps > From a list:** a `winget export` file from another PC, or
  this PC's own apps - tick and add many at once (five at a time, with
  progress).
- **Ctrl+K:** jump to any app, page, Settings section or action - Add
  apps, the grid, Check winget, Deploy or Release an app, dark mode.
- **Groups and apps grid** (Catalog menu): every app against every group;
  click a cell to go through Required, Available, Uninstall, Excluded and
  none; filters for both; saved with one Undo.

### Fixed

- Opening Settings no longer takes the Add apps tabs out of the keyboard
  order (the Settings tabs and the dialog's shared a class).

## 2.7.0

### Added

- **Add apps** (the Apps tab's Add button, or drop an installer on the
  list) - three ways in, each ending in an app that's ready to deploy:
  - **Winget:** search as you type, tick several packages, add them at
    once. Each gets what `winget show` knows - publisher, description,
    homepage, privacy URL, license - the groups you give, and managed
    updates when ticked. Packages already in the catalog are marked and
    can't be picked twice. A side panel shows the package you clicked.
  - **Installer (MSI / EXE):** drop the file (or choose it). It's uploaded
    in pieces and read: an MSI's ProductName, ProductVersion, Manufacturer
    and ProductCode; an EXE's version information, its maker (Inno Setup,
    NSIS, WiX bundle, InstallShield, Advanced Installer) and signature.
    The install and uninstall commands and the detection rule are worked
    out - msiexec and the product code by version for an MSI (managed
    updates possible); the maker's silent switch, an Uninstall.ps1 that
    runs the uninstaller Windows lists, and detection by name and version
    for an EXE. Everything can be changed before adding. The file goes
    into the app's packages folder, and the package can be built straight
    away.
  - **PowerShell script:** Install.ps1 and Uninstall.ps1 from a template
    (run an installer, copy files, set registry values, empty), checked
    for syntax, run as SYSTEM with 64-bit PowerShell. Detected by a version
    marker the install script writes - a registry rule by version, so
    managed updates can follow it - or by your own detection script.
  - Groups for all of them in one place, with your favourite groups one
    click away. **Empty form...** still opens the full editor.

## 2.6.0

### Added

- **Health checks** first in every nightly run: the connection certificate
  (found, has its private key, warned from 30 days before it expires),
  signing in to Graph, the shared Winget package and the packaging tool
  when apps need them, free disk space. Problems are in the report and
  the alerts. **Check health now** in Settings.
- **Drift every night:** every deployed app against Intune - settings,
  groups, dependencies, assignments the catalog doesn't have - reported
  and alerted. Optionally, the catalog's groups are pushed back when
  assignments drifted.
- **Release window:** the days the nightly run may release and promote by
  itself, and "not in the last week of the month". Fast-track releases and
  your own clicks don't wait.
- **Why a release is on hold:** the failed devices' error codes from the
  install status report, most common first - in the report, the alert and
  the Updates page.
- **Automatic withdraw:** at a failure share you set (at least three
  devices), the nightly run withdraws the release by itself, any day.
- **Own packages released automatically** (per app): a newer installer in
  the app's folder is built and released to pilot by the nightly run.
  Optionally it is downloaded first from an https address - used only with
  a valid digital signature from the same publisher as the installer
  already there, and kept under the folder's file name.
- **Apps worth adding** (Catalog menu): apps Intune's inventory finds on
  three or more devices that the catalog doesn't have - parts of Windows
  and drivers left out. **Add...** opens a new app with winget searched.
- **Catalog backup** every night: a zip of the app files (the last 30
  kept), and a commit when the catalog folder is a git repository.
- **Run while nobody is signed in:** Settings shows what's missing and
  writes a script to run once as administrator - the certificate copied
  to the computer's store, its private key readable by you, both tasks set
  to run whether you are signed in or not (no password stored).
- **Monthly report:** on the first run of a month, last month's
  releases, promotions, withdrawals, holds and the devices on the current
  version - as HTML in Logs\\reports, and by email / Teams when alerts are
  set up. **Create last month's report** in Settings.
- **Test tenant first:** with a test tenant's catalog folder set, Winget
  apps here are released automatically only in a version that is
  promoted there. The Updates page says what the test tenant has.

### Changed

- Install counts the summary report doesn't have, and the inventory of
  apps on devices, are read with Graph's batch requests - 20 apps a call
  instead of one.

## 2.5.0

### Added

- **Alerts from the nightly run:** a card in a Teams channel (a Workflows
  webhook) and/or an email sent with Graph (Mail.Send), after every run or
  only when something needs a look - failed, on hold, ready, released,
  promoted. **Send a test** in Settings. The webhook address is kept on
  this PC and never shown again on the page; an error names only its host.
- **Fast track** for security fixes: a release ticked "Fast track" is
  judged after a few hours (Settings: 4 by default) instead of days,
  downloads in the foreground, skips the release rings and goes to
  everyone. A second scheduled task looks at fast-track releases every two
  hours and promotes them when ready, even with automatic promotion off.
- **An app's own release rule** (editor > Managed updates): its own days,
  failure limit and minimum installs over Settings' rule.
- **Release rings:** further stages after the pilot groups (Settings, one
  per line, "Name: group, group"). A release that passes the rule in one
  ring goes on to the next (**Next ring...**, or the nightly run), then to
  everyone; the days count again in each ring.
- **Install deadline, restart grace period and notifications** on a
  release's Required assignments (Settings > Managed updates). Users can
  install early from the Company Portal; it's forced at the deadline.
- **Older versions on devices** (Updates page): from Intune's inventory of
  apps on devices - also versions installed by hand - per app, with a tile
  for the total. Matched by name (exactly, or with a version or "(x64)"
  after it); **Name on devices** in the editor when it differs. Needs
  DeviceManagementManagedDevices.Read.All.
- **Trend** (Updates page): the share of devices on the current version
  over the last 30 days, from the nightly reports, with a hover read-out
  and a table view.

### Changed

- The Updates page reuses its counts for a minute when you switch tabs
  (Reload reads them again), and a refresh asked for while it is loading
  runs once that load ends - after Promote, say, the page no longer shows
  the old state.
- The column "Pilot" is "In release": the ring (or fast track) and the
  rule's verdict, "ready for next ring" included.

## 2.4.0

### Added

- **Updates page** (a tab between Apps and Checks): every app with managed
  updates in one table - the current version and how many devices have it,
  the version in pilot with its install counts and the release rule's
  verdict (ready, waiting, on hold, and why), the newer version available
  (winget's, or the installer in an own package's folder) and the
  superseded versions kept for rollback.
  - Tiles on top: apps with managed updates, in pilot (ready / on hold),
    newer versions available, and the share of devices on the current
    version.
  - Each row's actions: Release, Promote, Withdraw, Roll back - the same
    dialogs as on the Apps tab; the page reads Intune again when they close.
  - **Check winget for new versions** and **Export CSV** (for an audit or a
    report; cells that would start a formula are quoted).
  - Without a connection, the page shows the catalog's side and says the
    counts are missing.

### Changed

- The install overview and the Updates page read install counts the same
  way: the apps install summary report once, then app by app for any the
  report doesn't list.

## 2.3.1

### Added

- **docs/managed-updates.md:** how managed updates work (current, pilot and
  superseded releases), how to set them up, what the nightly run does with
  each switch, and what to do when something goes wrong.
- **Tenant test checklist, section 10 "Managed updates":** release,
  promote, roll back, delete old versions, withdraw, Plan only, the
  scheduled task and an own MSI package, checked against a test tenant step
  by step.

### Changed

- The checklist's Settings paths follow the four Settings sections.
- **Browser test:** checks the Managed updates card and nightly-run list in
  Settings, and that Release new version is off (and says why) for an app
  without managed updates.

## 2.3.0

### Added

- **Roll back to previous version...** (More menu, apps with managed
  updates):
  - The catalog's groups go back to the newest superseded release, which
    becomes the current one again: its name in Intune, its App ID and
    version in the catalog, and the install command and detection rule
    pinned to it.
  - The release rolled back from stays in Intune as "*App x.y (rolled
    back)*".
  - Devices that already have the newer version keep it; nothing is
    uninstalled.
- **Delete old versions from Intune...** (More menu) deletes an app's
  superseded releases except the newest, which is kept for rollback.
  - Intune won't delete an app another app supersedes, so each one is first
    taken out of the newer release's relationships; that release's other
    relationships, such as dependencies, stay.
  - **The nightly run** does this too when **delete older superseded
    versions** is on (Settings > Defaults > Managed updates). Otherwise its
    report lists what could go.

### Tests

- On Windows, the server test creates the real scheduled task at a given
  time, reads it back and removes it. It also reads a real EXE's version
  from an own package's folder.
- The Graph test covers clean-up (relationship removed, older version
  deleted, newest kept) and rollback, and checks that the plan-only nightly
  run reports the clean-up.

## 2.2.0

### Added

- **Managed updates for your own packages.** An app with its own installer
  can have managed updates too:
  - **Release new version...** reads the version from the installer in
    the app's folder (Packages\<app>): an MSI's ProductVersion and
    ProductCode, or an EXE's version.
  - It builds the `.intunewin` from that folder and releases it to the
    pilot groups, like a Winget app.
  - The detection rule is set to the new version (and the new MSI product
    code), so devices on the old version get the update.
  - The app needs a detection rule that compares a version: MSI, or a file
    or registry rule by version. Managed updates explain when it doesn't.
- **Release rule** (Settings > Defaults > Managed updates). A pilot release
  is ready for everyone after N days in pilot, with at most X % of pilot
  devices failed and at least M installed. It is put on hold as soon as
  too many fail, or when nothing installed it for twice the pilot time.
- **Pilot status before promoting:** Promote shows the pilot devices'
  installed / failed / pending counts from Intune, and what the rule says.
- **Nightly run** (Settings > Defaults > Managed updates):
  - **Schedule** creates a Windows scheduled task that runs
    `IntuneDeployment.ps1 -RunUpdates` every day, as you.
  - **Run now** and **Plan only** start the same run on demand.
  - **Each run, per app with managed updates:**
    - promotes a pilot release the rule says is ready, or reports why it's
      waiting or on hold;
    - releases a newer winget version to the pilot groups;
    - reports a newer installer waiting in an own package's folder.
  - Promoting and releasing happen only when **promote automatically** and
    **release new winget versions automatically** are on; otherwise the run
    reports what it would do.
  - Every run writes a report, HTML and JSON, in Logs\reports. The last ten
    are listed in Settings.

## 2.1.0

### Added

- **Managed updates (Winget apps).** An alternative to Winget-AutoUpdate,
  with rings and reporting in Intune:
  - **A fixed version:** an app with managed updates installs exactly its
    App version (`winget install --version`), and its detection rule
    checks for that version *or newer*. The install command and detection
    follow the App version, so changing the version re-pins them.
  - **Release new version...** (More menu) creates the new version as a
    separate Intune app, "*App 24.09 (pilot)*". It supersedes the current
    one (update) and is assigned Required to the **pilot groups** only
    (Settings > Defaults > Managed updates), so everyone else stays on the
    current version.
  - **Promote pilot release...** gives it the catalog's groups and takes
    them off the old one. It is renamed to the app's name, and the old one
    is kept in Intune as "*App 24.08 (superseded)*".
  - **Withdraw pilot release...** deletes the pilot app; pilot devices keep
    the newer version.
  - **Turning it on:** **Managed updates on/off** (More menu, several apps
    at once), the editor's checkbox, or "Winget apps install with: Managed
    updates" as the default for new apps.
  - **Apps list:** a "pilot x.y" tag, and filters for **Managed updates**
    and **In pilot**. Checks knows a release's apps in Intune, so they
    aren't "not in the catalog".
  - Take winget's version still sets the version of a managed app that
    isn't deployed yet. Once deployed, new versions go through Release.

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
