# Tests

Four suites, each a plain script - no test framework to install.

```
pwsh -NoProfile -File code/tests/CatalogLogic.Tests.ps1   # pure logic
pwsh -NoProfile -File code/tests/WebServer.Tests.ps1      # the real server, over HTTP
pwsh -NoProfile -File code/tests/WebGraph.Tests.ps1       # the pages that read Graph, without a tenant
node code/tests/ui/WebUi.Tests.mjs                        # every page in Chromium
```

Every push runs the first three on Linux (PowerShell 7) and Windows
(PowerShell 7 and Windows PowerShell 5.1), and the browser test on Linux -
see `.github/workflows/tests.yml`.

## CatalogLogic.Tests.ps1 - the logic

The **pure** functions under `code\Private` - no network, no file outside a
temp folder: the catalog's JSON shape, comparing the catalog with what
Intune returned, the checks' findings, assignments with exclusions,
detection rules, platform scripts, winget's output, the diagnostics, the
Graph error messages. They are extracted from the real files' syntax tree,
never copied, so a test can't keep passing against a stale duplicate - and
a function that moved to another file is still found.

Only add a function to `$testableFunctionNames` if it has no live Graph
call and no lasting side effect. If it reads `$Global:App` state, set that
state in the test first, as the existing tests do.

Also here: the step runner (`code\Runner\Invoke-AppStep.ps1`) is started for
real and checked to pass parameters through unchanged and to return the
step's exit code, and no part of the app may start PowerShell with
`-EncodedCommand` (endpoint protection blocks it).

## WebServer.Tests.ps1 - the server

Starts `IntuneDeployment.ps1 -NoBrowser` and talks to it the way the page
does:

- **Security:** security headers, no inline script, only the fixed list of
  files is served, a foreign Host or Origin is refused, an API call without
  the start token, without JSON or as GET is refused.
- **Every page's API:** the catalog, the editor (validation, deploy
  settings, rename, remove), deploy and push refused without a connection,
  checks, fixes, batch edit and batch groups, groups, platform scripts
  (saved locally, listed, renamed, deleted), settings (a save keeps what it
  didn't change), diagnostics, prerequisites, certificates.

**Safe by construction:** no connection is configured, so nothing reaches a
tenant - everything that would stops at "Set up the connection first", and
the test checks that it does. What it creates in the catalog and the script
folder it removes again, and the settings file is put back as it was.

## WebGraph.Tests.ps1 - the pages that read Graph

Starts the server in **test mode**: the environment variable
`INTUNE_CATALOG_TEST_GRAPH` names a JSON file of stored Graph answers
(`code\Web\WebGraph.ps1`), every Graph call is answered from it, and
nothing signs in. The console says `TEST MODE` in red. The test checks what
each page makes of those answers: Checks (renamed, only in Intune, not
linked, a missing group), Diagnostics, the deploy plan holding back an app
of the same name, install status, platform scripts (list, text, groups, run
status, local copies), groups and members, the directory search - and the
awkward cases: a second page (`@odata.nextLink`), a refused `$expand`, the
beta report falling back to v1.0, and a refused request naming the
permission that page needs.

**The steps too.** On Windows, the steps that change Intune run as well,
in their own Windows PowerShell. In test mode their helper defines
stand-ins for `Import-Module` (Graph only), `Get-MgContext`,
`Connect-MgGraph` and `Invoke-MgGraphRequest`; a function wins over a
cmdlet of the same name. The stand-ins answer from the same file and
write every request to `<file>.calls`, so the test checks what a step
would have sent:
- Delete from Intune sends one DELETE and clears the App ID;
- a delete blocked by a dependency names the app that depends on it;
- Rename sends the new name, and the catalog follows.

On Linux these are skipped: there is no Windows PowerShell there.

The answers file maps `"METHOD path?query"` (or `"METHOD path"` for any
query), relative to `https://graph.microsoft.com/`, to the JSON Graph would
send. A list is answered in order; `{ "__status": 403, "__body": {...} }`
is an error.

## ui/WebUi.Tests.mjs - the page

The real server and the real page in Chromium, in light and dark mode, at
1440 and 820 pixels wide: every tab, the app editor, Checks, Diagnostics.
Fails on an error in the page, a failed request, a button without a name,
a page wider than the window, or a broken accessibility rule - axe-core's
WCAG 2.1 A/AA and best-practice rules, on every page and the main dialogs.
It also adds an app through the editor (with a Winget search), changes it
with Batch edit and Add groups, checks both arrived, and removes it again.
`--shots <folder>` keeps a screenshot of each page; CI uploads them.

```
npm install --no-save playwright@1.48.2 axe-core@4.10.2
npx playwright install chromium
node code/tests/ui/WebUi.Tests.mjs --shots ./shots
```

## GraphContract.Tests.ps1 - Microsoft's side

Checks every Graph type and property the app relies on
(`code\GraphContract.json`) against Microsoft's published `$metadata`. Needs
the internet and can fail because Microsoft changed something, so it isn't
part of the push run.

## What none of this covers

A live tenant. Creating, updating and deleting apps, assigning groups,
reading install status - all of it is real API calls, and testing it means
a **dedicated test tenant**, never production.
[docs/tenant-test-checklist.md](../../docs/tenant-test-checklist.md) is the
pass to make there before relying on a release.
