# Tenant test checklist

The automated tests never sign in to Microsoft Graph: they check the page,
the server and the logic, and stop at "Set up the connection first". Run
through this once against a **test tenant** (never production) before
relying on a release. About 45 minutes, plus about 30 for managed updates
(section 10).

## Setup

- A test tenant, and an Entra ID app registration for it - Settings > Setup
  guide walks through it.
- Two throwaway groups, e.g. `ZZ-Test-A` and `ZZ-Test-B` (you'll create
  them in section 6 if they don't exist).
- Work on a copy of your catalog (Settings > Packaging & folders > Folders), or remove
  the test apps afterwards.
- Keep an eye on **Settings > Activity** and the black log box of each
  dialog. Settings > Defaults > Automatic checks > **Detailed Graph log** stays off
  until section 1 says otherwise.

## 1. Connection, certificate, permissions

- [ ] **Create new certificate...** - the thumbprint fills in, and the .cer
      is in the certificates folder (**Open certificates folder**).
- [ ] **Upload this certificate** - a console window asks you to sign in;
      afterwards **Check certificates** lists it in Entra ID.
- [ ] **Add required permissions...** - adds them as Application
      permissions; **Open in Entra** shows them waiting for consent. Grant it.
- [ ] **Test connection** - signed in, every required permission ticked, the
      checklist all green. **Save**.
- [ ] Settings > Prerequisites says the Graph module is installed in each
      PowerShell. Settings > **Run diagnostics** shows "Connected - N
      app(s) in Intune".
- [ ] Turn on **Detailed Graph log**, run Checks - one `[GRAPH] GET ...`
      line per request in Activity. Turn it off again.
- [ ] Nothing in Activity or the log file (Settings > Folders > Logs)
      contains a token, `Bearer`, or `sig=`.

## 2. Checks and Add to catalog

- [ ] **Checks > Run checks** with both switches on. The log shows the
      detailed read and the assignment comparison; the notes say how many
      apps and groups were compared.
- [ ] Apps that are only in Intune appear as "In Intune, not in the
      catalog". Tick two, **Add to catalog** - they appear on Apps with
      their settings and groups, and their JSON files have both.
- [ ] Rename one of those apps in the Intune portal, **Re-check** - "Renamed
      in Intune", and **Use Intune's name** renames the catalog file.
- [ ] Change an added app's description in the portal, Re-check - a
      Metadata finding. **Pull** shows the field; keep the catalog's value -
      **Push settings** then puts it back in the portal.

## 3. Add and deploy a Winget app

- [ ] **Add app**, **Find...** next to Winget ID, search `7zip` and **Use**
      `7zip.7zip`. Set `ZZ-Test-A` as Required. Save.
- [ ] Settings > Packaging: tool found, init.intunewin built (build it if
      not).
- [ ] **Deploy** - the plan says Create; the log shows `[GRAPH] POST ...`
      lines for the create and the upload, and **no** line containing
      `blob.core.windows.net`.
- [ ] Afterwards the app has an App ID (Apps list: Deployed) and the portal
      shows it, assigned to `ZZ-Test-A` (Settings > Automatic checks: push
      groups after creating is on by default).
- [ ] Select another new app with the same name as something already in
      Intune and press Deploy - it is skipped with "already in Intune -
      link it" instead of creating a second one.
- [ ] Deploy another test app and **close the app window while it runs**.
      The console says it waits for the running step; once it has
      finished, start the app again - the app has its App ID in the
      catalog, and Activity says its groups weren't pushed.
- [ ] Deploy one more and **reload the page (F5)** while it runs - within
      about 20 seconds of the step ending, the app shows as Deployed.

## 4. Deploy settings and an app with its own package

- [ ] Add an app without a Winget ID, put an installer in its package
      folder, **More > Package** - the .intunewin is built.
- [ ] Deploy it without a detection rule - skipped, pointing to Deploy
      settings. Set a File or Registry rule in the editor's **Deploy
      settings**, Deploy again - created; the portal shows the same rule.
- [ ] Change the install time to 61 - it is saved as 60 (Intune's 5-minute
      steps). Return codes and dependencies arrive in the portal as set.

## 5. Groups on apps

- [ ] Add `ZZ-Test-B` under **Excluded** for the 7-Zip test app, **Push
      groups** - the preview lists `[required] EXCLUDE ZZ-Test-B`; Apply; the
      portal shows the exclusion.
- [ ] Assign the app to "All devices" in the portal, then preview a push -
      the preview says that target will be removed. Cancel.
- [ ] Select two test apps, **More > Add groups...** `ZZ-Test-A` as
      Available, with "then push" ticked - the push preview opens for both.
- [ ] **More > Remove groups...** takes it away again.
- [ ] **More > Batch edit...** on both: tick Owner, type a value, keep "then
      push" - both show it in the portal.

## 6. Groups page

- [ ] **Groups**: `ZZ-Test-A` lists the apps using it. Open it - its
      members from Entra ID.
- [ ] Search a user, **Add**, **Update group** - the portal shows the
      member. **Remove** takes them out again.
- [ ] **New group** `ZZ-Test-C`, Create - it exists in Entra ID.
- [ ] **Rename** `ZZ-Test-A` to `ZZ-Test-A2` - Entra ID has the new name,
      and every catalog app that used it now says `ZZ-Test-A2` (including
      Excluded).
- [ ] **Delete several...** `ZZ-Test-C` - gone from Entra ID.

## 7. Platform scripts

- [ ] **Platform scripts** lists what the portal shows under Devices >
      Scripts and remediations > Platform scripts.
- [ ] **New script**, `Write-Output "hello"`, name `ZZ-Test-Script`, group
      `ZZ-Test-B`, tick "send these groups", **Create in Intune** - the
      portal shows it, assigned, with the text intact (no stray characters
      at the top).
- [ ] **Edit** loads the text and the group back. Empty the group list and
      save - asked first; afterwards the portal shows no assignment.
- [ ] **Save local copies** - every script gets a local copy ("Saved");
      change one in the portal - it reads "Differs".
- [ ] **Run status** shows rows per device once it has run (a new script
      may have none yet).
- [ ] **Delete** asks, and removes it from Intune; the local copy stays
      until the next Save local copies.

## 8. Install status, delete

- [ ] **More > Install status** on a deployed app - rows per device, the
      counts match the portal's "Device install status".
- [ ] Select two test apps, **More > Delete from Intune** - asked once,
      both gone from the portal, their App IDs cleared in the catalog.

## 9. Start-up checks

- [ ] Settings > Defaults > Automatic checks: tick "Run Checks when the app opens",
      Save, close the app window and start the app again - the Checks tab
      shows a count, and Activity says how many findings.

## 10. Managed updates

Use a small Winget app with an older version still in winget (e.g.
`7zip.7zip`), one pilot group with one test device in it, and a second
group with another device.

- [ ] Settings > Defaults > Managed updates: pilot group `ZZ-Test-A`, rule
      "0 days, 50 %, 1 installed", all three automatic switches **off**.
      Save.
- [ ] Add the app, tick **Managed updates**, App version = an *older*
      version than winget's newest (e.g. `23.01`). Required for
      `ZZ-Test-B`. The editor's install command ends with `--version
      '23.01'`; Deploy settings > detection is the generated script.
- [ ] **Deploy** - one app in Intune under the catalog's name. On the
      `ZZ-Test-B` device, that exact version installs and Intune reports it
      installed (the detection script works under SYSTEM).
- [ ] Catalog > **Check winget for new versions** - the app shows
      "-> newest".
- [ ] **More > Release new version...** with the newest version - a second
      app "*name version (pilot)*" appears in the portal. It supersedes the
      first (Properties > Supersedence) and is assigned Required to
      `ZZ-Test-A` only. The list shows "pilot x.y".
- [ ] On the pilot device the new version installs (an update, not a
      second install). The `ZZ-Test-B` device stays on the old one.
- [ ] **More > Promote pilot release...** shows the pilot counts and "the
      release rule says it is ready". Promote: the pilot app is renamed to
      the app's name and assigned to `ZZ-Test-B`. The old one is renamed
      "*(superseded)*", without assignments. The catalog's App ID is the new
      app's.
- [ ] The `ZZ-Test-B` device updates to the new version.
- [ ] **More > Roll back to previous version...** - the old app gets
      `ZZ-Test-B` again and its name back, and the new one is "*(rolled
      back)*". Devices keep the newer version (nothing is uninstalled).
- [ ] Release and promote once more, so there are two superseded versions.
      **More > Delete old versions from Intune...** - the older one is gone
      from the portal; the newest superseded one is still there, and its
      supersedence to the deleted one is gone.
- [ ] Release once more, then **More > Withdraw pilot release...** - the
      pilot app is deleted from the portal.
- [ ] Settings > Managed updates > **Plan only** - a report under Logs\reports
      (Open reports folder) lists the app with what the run would do;
      nothing changes in the portal.
- [ ] **Schedule** at a time two minutes from now - the task "Intune App
      Catalog - managed updates" is in Task Scheduler. Turn on "release
      automatically", release nothing yourself, and wait. The run releases
      the newest winget version to pilot, and Settings lists the run.
      Then **Remove** the task.
- [ ] Optional, own package: an app with its own MSI, detection by MSI
      product code. Tick Managed updates, put a newer MSI in its folder,
      **Release new version...** The version and product code are read
      from the MSI, the package is rebuilt, and the pilot app's detection
      shows the new version and product code.

## 11. Clean up

- [ ] Delete the test apps from Intune and the catalog (with every
      superseded or pilot release of the managed one), the test groups, and
      the `ZZ-Test-Script` platform script and its local copy.
- [ ] Put back anything you changed on a real app while testing.
