# Managed updates

How the catalog keeps apps up to date in Intune with a pilot ring:
versions are released to a test group first, and reach everyone only once
the pilot devices are fine.

It replaces Winget-AutoUpdate (WAU) for the apps that use it. Every version
is an Intune app of its own, so Intune reports per device which version it
has, and nothing changes on a device without an assignment you can see in
the portal.

## The idea

| | What it is in Intune |
|---|---|
| **Current release** | The app under the catalog's name, assigned to the catalog's groups. It installs exactly its version; its detection rule checks for that version *or newer*. |
| **Pilot release** | "*App 24.09 (pilot)*": the new version, superseding the current one (type *update*), assigned Required to the pilot groups only. |
| **Superseded release** | "*App 24.08 (superseded)*": an earlier version, without assignments, kept for rollback. |

1. **Release new version...** creates the pilot release. Pilot devices get
   the new version as an update; everyone else stays where they are.
2. **Promote** gives the pilot release the catalog's groups and takes them
   off the old one. The pilot app becomes the current release and the old
   one is superseded.
3. **Withdraw** deletes the pilot app instead. **Roll back** gives the
   catalog's groups back to the newest superseded release.

Nothing is ever uninstalled: a device that has a newer version keeps it,
because every release counts "this version or newer" as installed.

## Setting it up

1. **Settings > Defaults > Managed updates**: the pilot groups (a few IT
   devices, then perhaps a wider early-adopter group) and the release rule:
   - **In pilot at least N days.**
   - **Failed at most X %** of the pilot devices that tried.
   - **Installed on at least M** pilot devices.
2. **Settings > Defaults > Default values**: "Winget apps install with:
   Managed updates" for new apps. Take *Winget AutoUpdate* out of the
   default dependencies. A managed app doesn't need it.
3. For existing apps: select them, **More > Managed updates on...**
4. A managed Winget app needs an **App version** before its first deploy:
   **More > Take winget's version**. That deploy is its first release.

### Own packages

An app with its own installer can have managed updates too, if its
detection rule compares a version: an **MSI** rule, or a **file** or
**registry** rule detecting by version.

To release a new version, put the new installer in the app's folder under
the packages folder (Packages\\*App-Name*) and use **Release new
version...**:

- The version comes from the installer: an MSI's ProductVersion (and
  ProductCode), or an EXE's version.
- The package is rebuilt from that folder.
- The detection rule is set to the new version (and the new MSI product
  code).

If the install command names the installer file, keep the file name the
same, or change the command first.

## The Updates page

The **Updates** tab shows every app with managed updates on one page:

| Column | What it says |
|---|---|
| **Current** | The version everyone gets. |
| **Devices on it** | Devices with the current release installed, of those it is assigned to (failed ones are flagged). |
| **Pilot** | The version in pilot, and the release rule's verdict: *ready*, *waiting* or *on hold*, with the reason. |
| **Available** | A newer version: winget's (after **Check winget for new versions**), or the installer in an own package's folder. |
| **Superseded** | Earlier releases kept in Intune for rollback. |

Release, Promote, Withdraw and Roll back are on each row. **Export CSV**
saves the table, for an audit or a report.

## The nightly run

**Settings > Defaults > Managed updates > Schedule** creates a Windows
scheduled task, "Intune App Catalog - managed updates". It runs
`IntuneDeployment.ps1 -RunUpdates` every day as you, on this PC, while
you're signed in. For an always-on server, open the task in Task Scheduler
and set "Run whether user is logged on or not". The certificate must then
be in the machine store, or the store of the account the task runs as.

Each run, for every app with managed updates:

| Situation | The run... | Only when this switch is on |
|---|---|---|
| A version is in pilot | applies the release rule: **promotes** it, or reports *wait* / *hold* with the reason | Promote automatically when ready |
| A Winget app, nothing in pilot, winget has a newer version | **releases** it to the pilot groups | Release new winget versions to pilot automatically |
| An own package, a newer installer in its folder | reports it (a person releases their own installer) | - |
| More than one superseded release | **deletes** the older ones from Intune, keeping the newest for rollback | Delete older superseded versions |

With a switch off, the run reports what it would have done. **Plan only**
does the same for everything and changes nothing. That's a good way to
start: run Plan only for a few days, read the reports, then turn the
switches on one at a time.

Every run writes a report (HTML and JSON) to Logs\\reports. Settings
lists the last ten, and **Open reports folder** has them all (the last 60
runs are kept). Only one run goes at a time.

The run needs **winget** on the PC it runs on, to look up new versions. It
signs in with the app's own certificate, like the page.

## When something goes wrong

- **A pilot release is on hold:** too many pilot devices failed, or none
  installed it. Look at **More > Install status...** for the pilot app (the
  pilot version is in the list), fix the cause or **Withdraw** it.
- **The new version is broken for everyone:** **Roll back** sends the
  previous version to the groups again. Devices that already updated keep
  the new version, so fix those by hand or with a new release.
- **A step failed half-way** (for example promoted, but the old release
  kept its assignments): the message says what's left. Finish it in the
  portal, or run the action again.
- **Undo** (the banner over the Apps list) takes back a promotion or
  rollback *in the catalog*. It does not change Intune.
