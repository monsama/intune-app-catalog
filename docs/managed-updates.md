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

## Release rings

With only pilot groups, a release goes pilot -> everyone. **Settings >
Defaults > Managed updates > Release rings** adds stages in between, one per
line:

```
Early adopters: SG-Intune-Early, SG-IT
Broad: SG-Intune-Broad
```

A release that passes the rule in one ring gets the next ring's groups too
(**Next ring...**, or the nightly run with automatic promotion on), and
everyone after the last. The rule's days count again in each ring. **Promote**
skips the remaining rings.

## Fast track

For a security fix: tick **Fast track** in Release new version. The release
is judged after *Fast track: in pilot (hours)* (4 by default) instead of
days, downloads in the foreground, skips the rings, and goes to everyone.
The nightly task promotes it once it's ready even with automatic promotion
off - ticking Fast track is the decision. A second scheduled task ("...
fast-track updates") looks at fast-track releases every two hours.

## An app's own rule

In the editor, under **Managed updates**, an app can have its own days,
failure limit and minimum installs: say 1 day for a browser, 7 for a
line-of-business tool. Empty fields use Settings' rule.

## Install deadline, restart, notifications

Settings > Managed updates > *Fast track and installation*:

- **Install deadline (days):** the Required assignment of a release gets a
  deadline this many days after it reaches a group. Users can install it
  earlier from the Company Portal; at the deadline it's installed. 0 (the
  default): as soon as possible.
- **Restart grace period (minutes):** when the installer asks for a
  restart, how long the user may put it off.
- **Notifications on the device:** show all, only restarts, or none.

These are set when a release is assigned (pilot, next ring, promote, roll
back). **Push groups** sets assignments without them, so after a push the
app's assignments use Intune's defaults again.

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
| **On older versions** | Devices that Intune's inventory (Apps > Monitor > Discovered apps) finds with an older version - also ones installed by hand. Needs DeviceManagementManagedDevices.Read.All. The app is found by its name; if it's listed differently on devices, set **Name on devices** in the editor. |
| **Superseded** | Earlier releases kept in Intune for rollback. |

Release, Next ring, Promote, Withdraw and Roll back are on each row.
**Export CSV** saves the table, for an audit or a report. After two nightly
runs, a line shows the share of devices on the current version over the
last 30 days (from the runs' reports). The page reuses its counts for a
minute when you switch tabs; **Reload** reads them again.

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

### What else the nightly run does

- **Health first:** the certificate (warned 30 days before it expires),
  signing in, the packages, disk space. **Check health now** shows the
  same.
- **Release window:** Settings > *Release window* - the days it may
  release and promote by itself, and optionally not in a month's last
  week. Withdrawals, fast-track releases and your own clicks don't wait.
- **On hold, and why:** a held release lists the failed devices' error
  codes. **Withdraw automatically at X %** withdraws it by itself once that
  share of at least three devices failed.
- **Drift** (full runs): every deployed app against Intune, as Checks
  does. With *put the catalog's groups back*, drifted assignments are
  pushed again.
- **Own packages:** with *Release a newer installer automatically* in the
  app's editor, a newer installer in its folder is built and released to
  pilot. With a download address, the installer is fetched first - and
  used only if it has a valid digital signature from the same publisher as
  the one already there.
- **Backup** (full runs): a zip of the catalog's app files in the Backups
  folder (30 kept); a commit if the catalog folder is a git repository.
- **Monthly report:** on a month's first full run.
- **Test tenant first:** set *Test tenant's catalog folder* (a share this
  PC can read) and Winget apps are released by themselves only in a
  version promoted in that tenant's catalog. Run the catalog there too,
  with its own nightly task.

*Plan only* reports release decisions; it skips the drift check, the
backup and the monthly report.

### Running while nobody is signed in

A task that runs without a signed-in user can't use your own private
keys. **Settings > Managed updates > Run while nobody is signed in** shows
what's missing; **Create the setup script** writes
`Logs\\unattended-setup.ps1`. Run it once in PowerShell started with *Run
as administrator*: it copies the certificate into the computer's store,
lets you read its private key, and sets both tasks to run whether you are
signed in or not (S4U - no password stored). Sign out once and check the
next run's report.

### Alerts

**Settings > Defaults > Managed updates > Alerts** sends a message after a
run: always, or only when something needs a look (failed, on hold, ready,
released, promoted, advanced).

- **Teams:** in the channel, *... > Workflows > Post to a channel when a
  webhook request is received*; paste its address. It's saved on this PC
  and never shown again.
- **Email:** a mailbox to send from and the addresses to send to. The app
  registration needs the application permission **Mail.Send** (consider an
  application access policy that limits it to that mailbox).

**Send a test** checks both.

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
