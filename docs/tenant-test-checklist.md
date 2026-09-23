# Tenant test checklist

The automated tests never sign in to Microsoft Graph, so these parts of 1.2
have only been checked against a stand-in. Run through this once against a
**test tenant** (never production) before relying on them. About 30 minutes.

## Setup

- A test tenant with the app registration from **Settings... > First time?
  Setup guide...** and its certificate.
- Two throwaway groups, e.g. `ZZ-Test-A` and `ZZ-Test-B`.
- On the **Log** tab, leave **Detailed Graph log** off for now.
- Work on a copy of your catalog (**Open other folder...**), or remove the
  test apps afterwards.

For every step, check the dialog's log box **and** the Log tab.

## 1. Graph log lines

- [ ] **Look up App IDs...** - the Log tab shows
      `[GRAPH] Intune app lookup: N read request(s) (…)`, no line per request.
- [ ] Turn on **Detailed Graph log**, look up again - one
      `[GRAPH] GET /beta/deviceAppManagement/mobileApps… -> OK` line per request.
      Turn it off again.
- [ ] Add a test app (e.g. Winget ID `7zip.7zip`), **Deploy to Intune...**,
      **Deploy**. The log box shows light-blue `[GRAPH] POST …` / `PATCH …`
      lines for the create and upload steps, and **no** line containing
      `blob.core.windows.net` or `sig=` (the package upload).
- [ ] Open the app in the editor - the **Deploy to Intune...** dialog shows
      `[GRAPH] Intune app details (…): N read request(s)` in its log box
      before the loaded values.
- [ ] **Run diagnostics...** - its log box shows `[GRAPH]` lines for the
      app lookup, the Minimum OS lookup and the Entra ID lookup.
- [ ] Group manager: type `ZZ-Test-A`, load members - `[GRAPH] Group
      lookup (ZZ-Test-A): …` in its log box.
- [ ] Make a request fail on purpose: in the editor, enter a made-up App ID
      (`00000000-0000-0000-0000-000000000000`) and **Pull groups from
      Intune...**. A red `[GRAPH] … -> FAILED (…): … (request-id <guid>)`
      line appears.
- [ ] **Copy log**, paste somewhere - the `[GRAPH]` lines are there.
      **Save log...** writes the same text. **Open log folder** opens
      `data\logs` with today's file.
- [ ] Nothing in the log or the log file contains a token, `Bearer`, or a
      certificate thumbprint in a request address.

## 2. "Stop and close?" with a real step

- [ ] Deploy the test app again (Update + Replace Content with any
      package) and click **Cancel** while it runs. The question appears,
      **No** is highlighted. Answer **No** - the dialog stays and the step
      finishes normally.
- [ ] Start the same again, close with the window's **X**, answer **Yes** -
      the dialog closes, the Log tab shows where it stopped. Check the app
      in the Intune portal.
- [ ] **Pull metadata and groups from Intune...** (Sync) on a few apps,
      press **Esc** while it runs - asked; **Yes** stops it.
- [ ] **Push groups to Intune (multiple apps)...**: after Preview shows
      changes, close without applying - one "Unapplied changes" question,
      not two.

## 3. Settings "Save changes?"

- [ ] Open **Settings...**, change the Client ID by one character, close
      with **X** - "Save changes?" with Yes / No / Cancel.
      **Cancel** keeps Settings open. **No** closes and the old value is
      still used (**Look up App IDs...** still works).
- [ ] Change it again, answer **Yes** - it's saved (reopen Settings to
      check), then change it back and **Save**.
- [ ] **Delete selected from Entra...** on a test certificate when the app
      registration has only one - a single question that includes the
      "ONLY certificate" warning. Answer **No**.

## 4. Batch edit clears dependencies

- [ ] Give the test app a dependency (Deploy to Intune..., dependencies,
      Push Metadata). Check it in the Intune portal.
- [ ] **Batch edit Intune fields...**, tick only **Dependencies** with
      nothing checked, **Apply to Intune...** - the question says
      "none (existing dependencies are removed)". Answer **Yes**.
- [ ] The portal shows no dependency any more, and the catalog entry has
      none either.
- [ ] Same with **Return codes** ticked and no rows: the portal shows the
      standard codes 0, 1707, 3010, 1641, 1618, and so does the app's
      catalog file.

## 5. Installation status (new in 1.3)

- [ ] Right-click a deployed app > **Installation status...** - a row per
      device, with user, state, version and "last reported".
- [ ] The line above the list counts the states ("12 devices: 9 Installed,
      2 Failed, 1 Pending"), and the numbers match the Intune portal's own
      "Device install status" for that app.
- [ ] A failed row is red and shows an error code like
      `0x87D10324 (-2016345308)`.
- [ ] **Failed only** shows just those rows; **All** brings the rest back.
- [ ] **Copy list** pastes as a tab-separated table.
- [ ] **Refresh** reloads, and the Log tab shows a `[GRAPH] Install status
      (<app id>): N read request(s)` line.
- [ ] An app with many devices (more than 200) shows them all - paging
      works - or says "only the first N rows are shown".
- [ ] If the State column shows "State 1" style values instead of words
      like "Installed", tell me: the report returned numbers without the
      text column, and the app deliberately doesn't guess what they mean.
- [ ] The menu entry is greyed out for an app without an App ID, and for a
      multi-row selection.

## 6. Platform scripts (new in 1.3)

- [ ] **More actions... > Intune > Platform scripts...** lists what the
      portal shows under Devices > Scripts and remediations > Platform
      scripts, with the same "runs as", 32-bit and signature values.
- [ ] **New script...**: paste a harmless script (e.g.
      `Write-Output "hello"`), name it `ZZ-Test-Script`, tick one test
      group, **Create in Intune**. The black box shows `[GRAPH] POST
      /beta/deviceManagement/deviceManagementScripts -> OK` and a second
      `POST .../assign`, and the list shows it afterwards.
- [ ] The portal shows the same script, with that group assigned and the
      script text intact (no stray characters at the top - that would mean
      the encoding is wrong).
- [ ] **Edit...** on it loads the script text and the group back, exactly
      as saved.
- [ ] Change the text, untick every group, Save - it warns that the script
      stops being assigned, and afterwards the portal shows no assignment.
- [ ] Load a `.ps1` file with **Load .ps1 file...** - the name and file
      name fill in from the file name when they're empty.
- [ ] A script that doesn't exist in Entra: type a group name that doesn't
      exist via "+ Group..." and save - the run fails with "No group named
      ... exists in Entra ID", and nothing half-done is left behind.
- [ ] **Delete...** asks first, with No as the default, then the script is
      gone from both the list and the portal.
- [ ] If Graph refuses with a permissions error, add
      `DeviceManagementScripts.ReadWrite.All` (application) to the app
      registration and grant admin consent, then retry.

## 7. Excluded groups, run status, winget check (new in 1.3)

- [ ] Open an app with a group in **Required for**, add a test group to
      **Excluded from**, then **Push groups to Intune (single app)...**.
      The preview lists `[required] EXCLUDE <group>` as an addition.
- [ ] After it runs, the portal shows that group under "Excluded groups"
      for the app's Required assignment.
- [ ] Remove the exclusion, push again - the preview says it's removed, and
      the portal agrees.
- [ ] Assign an app to "All devices" in the portal, then preview a push
      from here: the preview says that target WILL BE REMOVED (the catalog
      has no way to express it). Undo in the portal if you don't want that.
- [ ] **Push groups to Intune (multiple apps)...** shows the same exclusion
      lines in its preview, and Apply produces them in the portal.
- [ ] Platform scripts > select the test script > **Run status...**: rows
      per device with a state, and the Log tab shows a `[GRAPH] Script run
      status (...)` line. (A brand-new script may legitimately have no rows
      yet.)
- [ ] **More actions... > Verify > Winget package check...**: every real ID
      says "Found", and if you temporarily set an app's Winget ID to
      something invented, it turns red with "NOT FOUND".

## 8. Deploy without checking Intune on open (new in 1.3)

The risky one: the check that stops a stale local value overwriting a newer
Intune value moved from "every time the dialog opens" to "right before an
update is sent". Test it on a **test app**, not something real.

- [ ] Untick **Check Intune when opening Deploy** (toolbar, Sync box).
      Reopen the app to confirm the setting survived a restart.
- [ ] Right-click a deployed test app > **Deploy to Intune...**. It opens
      immediately, says "Showing the values saved here - Intune hasn't been
      asked...", and shows a **Refresh from Intune** button.
- [ ] Press **Refresh from Intune**: the fields load from Intune, the
      status line changes, and the Log tab shows the `[GRAPH]` lines.
- [ ] Close it. Change something about that app in the **Intune portal**
      (e.g. the description). Open Deploy again (still without the check),
      and press **Push Metadata** straight away.
      - It must first load from Intune, then show the drift dialog naming
        the description, let you keep either value, and only then run the
        update.
      - Afterwards the portal shows what you chose - never the stale value
        silently.
- [ ] Repeat with **Update + Replace Content** on a test app, to confirm
      the same pre-check happens for that path.
- [ ] Tick the setting again and confirm the dialog goes back to loading on
      open (the Refresh button then stays hidden).

## 9. Templates and Clear App ID (new in 1.3)

- [ ] Select two apps > right-click > **Save as template...** and pick an
      empty folder. The message says how many were written.
- [ ] Those .json files have `"appId": ""` and no `intuneAppType` /
      `intuneAppVersion`, but keep name, Winget ID, groups, exclusions and
      metadata. Your working catalog is unchanged (check one app still has
      its App ID).
- [ ] Saving into the folder the catalog is loaded from is refused.
- [ ] **Open other folder...** on the template folder, then deploy one app
      from it into the test tenant: it creates a NEW app rather than
      updating the original. Delete that test app afterwards.
- [ ] Back in your real catalog: right-click a test app > **Clear App ID...**
      - the question says Intune isn't touched, No is the default.
      Answer Yes: the App ID column empties, the app still exists in the
      Intune portal, and the Log tab confirms it.

## 10. Bulk editing more fields (new in 1.3)

- [ ] **Batch edit Intune fields...** on two test apps: tick **Publisher**,
      type a value, run. Both apps show it in the portal and in their
      catalog files.
- [ ] Tick **Publisher** with an empty box: the confirmation says
      "(blank)", and afterwards the field is empty in the portal too.
- [ ] Tick **Install command**, change it, and confirm the portal shows the
      new command (this one really does change how the app installs - use a
      throwaway app).
- [ ] Tick **Catalog only** and run: the black box shows only catalog
      lines, no `[GRAPH]` lines appear, and the portal is unchanged.
- [ ] With **Catalog only** off, check an app that has no App ID: running
      is refused with "Not in Intune yet", naming that app.
- [ ] An app that was never deployed can be edited with **Catalog only**
      ticked, and its .json file shows the change.

## 11. Install time steps (fixed in 1.3)

- [ ] Deploy to Intune > set **Install time required** to 61 and click
      elsewhere: the field becomes 60 (Intune stores 5-minute steps).
      64 becomes 65, 5000 becomes 1440.
- [ ] Push Metadata with it, then **Refresh from Intune**: the value
      matches what the field showed, and the app's catalog file agrees.
- [ ] The audit no longer reports "Install time required" as drift for
      that app.

## 12. Delete prompts

- [ ] **Delete from Intune...** on the test app, where a second test app
      depends on it - "Dependency in the way" names both apps and says Yes
      changes the other one. **No** is the default.
- [ ] Delete the group `ZZ-Test-B` in Group manager while a catalog app
      uses it - the question lists that app.

## 13. Clean up

- [ ] Delete the test apps from Intune (and the catalog), the two test
      groups, the `ZZ-Test-Script` platform script if it's still there, and
      the template folder from section 9.
- [ ] Put back anything you changed on a real app while testing (the
      description in section 8, the publisher and install command in
      section 10).
