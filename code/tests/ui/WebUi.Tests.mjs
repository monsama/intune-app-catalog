// Intune App Catalog & Deployment
// Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The web interface in a real browser, against the real server: starts
// IntuneDeployment.ps1 -NoBrowser, opens every page in Chromium and checks
// what a person would notice first - errors in the page, requests that fail,
// buttons without a name, a page wider than the window, dialogs that open
// and close - and runs axe-core's accessibility rules (WCAG 2.1 A/AA and
// best practices) on every page and the main dialogs. No tenant: the app
// runs unconfigured, the way it starts the first time. One app is added
// through the editor, changed with Batch edit and Add groups, and removed
// again.
//
//   npm install --no-save playwright@1.48.2 axe-core@4.10.2 && npx playwright install chromium
//   node code/tests/ui/WebUi.Tests.mjs [--shots <folder>]
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { chromium } from 'playwright';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const shotsArg = process.argv.indexOf('--shots');
const shots = shotsArg > 0 ? resolve(process.argv[shotsArg + 1]) : null;
if (shots) mkdirSync(shots, { recursive: true });
const pwsh = process.platform === 'win32' ? 'pwsh.exe' : 'pwsh';
let axePath = null;
try { axePath = createRequire(import.meta.url).resolve('axe-core/axe.min.js', { paths: [repo, process.cwd()] }); } catch (e) { }

let passed = 0;
const failures = [];
const check = (ok, name, detail = '') => { if (ok) passed++; else { failures.push(`${name}${detail ? ' - ' + detail : ''}`); console.log(`FAIL: ${name} ${detail}`); } };

// ---- the server
const server = spawn(pwsh, ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(repo, 'IntuneDeployment.ps1'), '-NoBrowser'], { cwd: repo });
let out = '';
server.stdout.on('data', d => { out += d; });
server.stderr.on('data', d => { out += d; });
const url = await new Promise((res, rej) => {
  const t = setTimeout(() => rej(new Error('the server did not print its address within 90 s:\n' + out)), 90000);
  const poll = setInterval(() => { const m = /Open:\s+(http:\/\/127\.0\.0\.1:\d+\/#t=[0-9a-f]+)/.exec(out); if (m) { clearInterval(poll); clearTimeout(t); res(m[1]); } }, 200);
});
console.log('Server: ' + url.replace(/#t=.*/, ''));
check(!!axePath, 'axe-core is installed (npm install --no-save axe-core@4.10.2)');
const testApp = 'ZZ UI Test';

const browser = await chromium.launch();
try {
  for (const theme of ['light', 'dark']) {
    for (const size of [{ width: 1440, height: 900 }, { width: 820, height: 900 }]) {
      const label = `${theme} ${size.width}px`;
      // bypassCSP: the page's own policy (script-src 'self') also forbids the
      // string evaluation Playwright's waitForFunction uses. The page is still
      // served with it - WebServer.Tests.ps1 checks the header and that there
      // is no inline script.
      const ctx = await browser.newContext({ viewport: size, colorScheme: theme, bypassCSP: true });
      const page = await ctx.newPage();
      const errors = [];
      page.on('pageerror', e => errors.push('page: ' + e.message));
      page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
      page.on('response', r => { if (r.status() >= 400) errors.push(`HTTP ${r.status()} ${r.url().replace(/#.*/, '')}`); });
      // The app asks in its own dialog (ask() in core.js), never with the browser's confirm()/prompt().
      page.on('dialog', d => { errors.push(`native ${d.type()} popup: ${d.message().slice(0, 60)}`); d.dismiss(); });
      await page.addInitScript(t => { try { localStorage.setItem('theme', t); localStorage.setItem('view', 'apps'); } catch (e) { } }, theme);
      await page.goto(url);
      await page.waitForFunction(() => document.getElementById('ver').textContent.startsWith('v'));

      const shot = async name => { if (shots) await page.screenshot({ path: join(shots, `${name}-${theme}-${size.width}.png`), fullPage: false }); };
      const noOverflow = async view => {
        const w = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
        check(w[0] <= w[1] + 1, `${label}: ${view} fits the window (no sideways scrolling)`, `${w[0]} > ${w[1]}`);
      };
      // Every rule axe-core has for WCAG 2.1 A/AA and best practice - in the
      // open dialog when there is one (axe skips what's behind a modal).
      const a11y = async view => {
        if (!axePath) return;
        if (!(await page.evaluate(() => typeof window.axe !== 'undefined'))) await page.addScriptTag({ path: axePath });
        const found = await page.evaluate(async () => {
          const r = await window.axe.run(document, { runOnly: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'best-practice'] });
          return r.violations.map(v => `${v.id} (${v.impact}): ${v.nodes.slice(0, 3).map(n => n.target.join(' ')).join(', ')}`);
        });
        check(found.length === 0, `${label}: ${view} passes the accessibility rules`, found.join(' | '));
      };
      const unnamed = async view => {
        const bad = await page.evaluate(() => [...document.querySelectorAll('button, [role=menuitem]')]
          .filter(b => b.offsetParent !== null && !(b.textContent.trim() || b.getAttribute('aria-label') || b.title)).map(b => b.id || b.outerHTML.slice(0, 60)));
        check(bad.length === 0, `${label}: ${view} has no button without a name`, bad.join(', '));
        // A greyed-out button says why on hover.
        const mute = await page.evaluate(() => [...document.querySelectorAll('button:disabled')]
          .filter(b => b.offsetParent !== null && !b.title).map(b => b.id || b.textContent.trim()));
        check(mute.length === 0, `${label}: ${view} - every disabled button has a tooltip`, mute.join(', '));
      };

      // Apps: an unconfigured app opens on Settings; the Apps list is empty but explained.
      await page.click('#tabApps');
      await page.waitForSelector('#emptyState:not([hidden]), #gridBody tr');
      check(await page.isVisible('#setupBanner'), `${label}: the "no connection" banner shows`);
      await noOverflow('Apps'); await unnamed('Apps'); await a11y('Apps'); await shot('apps');

      // Add apps: three ways in; the empty form is one click further.
      await page.click('#btnAddApp');
      await page.waitForSelector('#dlgAdd[open]');
      check(await page.isVisible('#awQuery') && await page.isDisabled('#btnAddGo'), `${label}: Add apps opens on the winget search, Add off until something is picked`);
      await unnamed('Add apps (winget)'); await a11y('Add apps (winget)'); await shot('add-winget');
      await page.click('#atab-installer');
      check(await page.isVisible('#aiDrop'), `${label}: Add apps has a drop zone for an installer`);
      await a11y('Add apps (installer)');
      await page.click('#atab-script');
      await page.waitForFunction(() => document.getElementById('asTemplate').options.length > 0 && /IntuneAppCatalog/.test(document.getElementById('asInstall').value));
      await page.fill('#asName', 'ZZ UI script');
      check(!(await page.isDisabled('#btnAddGo')), `${label}: a script app can be added once it has a name - the template writes the version marker`);
      await unnamed('Add apps (script)'); await a11y('Add apps (script)'); await shot('add-script');
      await page.click('#btnAddBlank');
      await page.waitForSelector('#dlgApp[open]');
      await page.click('#deploySec summary');
      await unnamed('the app editor'); await a11y('the app editor'); await shot('editor');
      // The name is a required field: the browser itself says so and the save never leaves the page.
      await page.click('#btnSaveApp');
      const blocked = await page.evaluate(() => document.getElementById('aName').validity.valueMissing && document.getElementById('dlgApp').open);
      check(blocked, `${label}: saving an app without a name is stopped, and the editor stays open`);
      await page.keyboard.press('Escape');
      check(!(await page.isVisible('#dlgApp[open]')), `${label}: Escape closes the editor`);

      // Home: what needs a look; Ctrl+K finds pages and actions.
      await page.click('#tabHome');
      await page.waitForFunction(() => !/Looking/.test(document.getElementById('homeNote').textContent));
      check(/Not connected/.test(await page.textContent('#homeList')), `${label}: Home says the app isn't connected`, await page.textContent('#homeList'));
      await noOverflow('Home'); await unnamed('Home'); await a11y('Home'); await shot('home');
      await page.keyboard.press('Control+k');
      await page.waitForSelector('#dlgPalette[open]');
      await page.keyboard.type('updates');
      check(/Updates/.test(await page.textContent('#palList li:first-child')), `${label}: Ctrl+K finds the Updates page`, await page.textContent('#palList'));
      await a11y('the Ctrl+K palette');
      await page.keyboard.press('Escape');
      check(!(await page.isVisible('#dlgPalette[open]')), `${label}: Escape closes the Ctrl+K palette`);

      // Updates: no app has managed updates yet - the page says how to start.
      await page.click('#tabUpdates');
      await page.waitForFunction(() => !/Reading/.test(document.getElementById('updNote').textContent));
      check(await page.isVisible('#updEmpty') && /Not connected/i.test(await page.textContent('#updNote')), `${label}: Updates explains the empty page and that there are no counts without a connection`, await page.textContent('#updNote'));
      await noOverflow('Updates'); await unnamed('Updates'); await a11y('Updates'); await shot('updates');

      // Checks: runs, and says Intune wasn't checked.
      await page.click('#tabChecks');
      await page.click('#btnRunChecks');
      await page.waitForFunction(() => document.getElementById('btnRunChecks').textContent === 'Run checks');
      check(/not checked/i.test(await page.textContent('#checkNotes')), `${label}: Checks says Intune wasn't checked`, await page.textContent('#checkNotes'));
      await noOverflow('Checks'); await unnamed('Checks'); await a11y('Checks'); await shot('checks');

      // Groups and Platform scripts: empty, explained.
      await page.click('#tabGroups');
      await page.waitForSelector('#groupList li');
      await noOverflow('Groups'); await unnamed('Groups'); await a11y('Groups'); await shot('groups');
      await page.click('#tabScripts');
      await page.waitForFunction(() => !/Reading/.test(document.getElementById('scriptNote').textContent));
      check(/Not connected/i.test(await page.textContent('#scriptNote')), `${label}: Platform scripts says only local copies are shown`);
      await noOverflow('Platform scripts'); await unnamed('Platform scripts'); await a11y('Platform scripts'); await shot('scripts');

      // Settings: diagnostics, prerequisites, the guide.
      await page.click('#tabSettings');
      await page.click('#stab-connection');
      await page.click('#guideReg summary');
      await noOverflow('Settings'); await unnamed('Settings'); await a11y('Settings'); await shot('settings');
      for (const sec of ['defaults', 'packaging']) {
        await page.click(`#stab-${sec}`);
        if (sec === 'defaults') {
          // Managed updates: the card, and the nightly run's list (no run yet on a fresh test machine).
          await page.waitForFunction(() => /No run yet|run is going|plan only/i.test(document.getElementById('runList').textContent));
          check(await page.isVisible('#pilotGroups') && await page.isVisible('#rpDays') && await page.isVisible('#btnRunPlan'), `${label}: Settings > Defaults has managed updates and the nightly run`);
        }
        check(await page.isVisible(`#sec-${sec}`) && !(await page.isVisible('#sec-connection')), `${label}: Settings > ${sec} shows only its own cards`);
        await noOverflow(`Settings ${sec}`); await unnamed(`Settings ${sec}`); await a11y(`Settings ${sec}`);
      }
      await page.click('#stab-diagnostics');
      await page.click('#btnDiag');
      await page.waitForSelector('#diagLog .h');
      check((await page.textContent('#diagLog')).includes('Skipped'), `${label}: Diagnostics skips Intune without a connection`);
      await noOverflow('Settings diagnostics'); await unnamed('Settings diagnostics'); await a11y('Settings diagnostics');
      await page.click('#stab-connection');

      if (size.width === 1440) {
        // Certificates on this machine (none on Linux - the dialog says so).
        await page.click('#btnCertsLocal');
        await page.waitForSelector('#dlgCertsLocal[open]');
        await unnamed('the certificates dialog'); await a11y('the certificates dialog');
        await page.keyboard.press('Escape');

        // An app added through the editor, then Batch edit and Add groups on it.
        await page.click('#tabApps');
        await page.click('#btnAddApp');
        await page.waitForSelector('#dlgAdd[open]');
        await page.click('#btnAddBlank');
        await page.waitForSelector('#dlgApp[open]');
        await page.fill('#aName', testApp);
        await page.fill('#aWinget', 'Vendor.ZZUiTest');
        await page.click('#btnFindWinget');
        await page.waitForSelector('#dlgWinget[open]');
        await page.fill('#wgQuery', 'zz-ui-test');
        await page.click('#btnWgSearch');
        await page.waitForFunction(() => !/Asking winget/.test(document.getElementById('wgNote').textContent));
        await unnamed('the Winget search'); await a11y('the Winget search');
        await page.keyboard.press('Escape');
        check(await page.isVisible('#dlgApp[open]'), `${label}: closing the Winget search goes back to the editor`);
        check(await page.isChecked('#aManaged'), `${label}: a new Winget app has managed updates by default`);
        await page.uncheck('#aManaged');   // this one stays unmanaged: Release is checked below to be off, and to say why
        await page.click('#btnSaveApp');
        await page.waitForSelector(`#gridBody tr[data-name="${testApp}"]`);
        check(!(await page.isVisible('#dlgApp[open]')), `${label}: the new app is saved and listed`);

        await page.click(`#gridBody tr[data-name="${testApp}"]`);
        await page.click('#btnMore');
        const relTip = await page.getAttribute('[data-act="release"]', 'title');
        check(await page.isDisabled('[data-act="release"]') && /managed updates on/i.test(relTip || ''), `${label}: Release new version is off for an app without managed updates, and says why`, relTip);
        await page.keyboard.press('Escape');
        await page.click(`#gridBody tr[data-name="${testApp}"]`);
        await page.click('#btnMore');
        await page.click('[data-act="batchedit"]');
        await page.waitForSelector('#dlgBatch[open]');
        await unnamed('Batch edit'); await a11y('Batch edit'); await shot('batch');
        await page.fill('#bOwner', 'ZZ Owner');
        check(await page.isChecked('[data-bf="owner"]'), `${label}: typing in a Batch edit field ticks it`);
        await page.uncheck('#bPush');
        await page.click('#btnBatchGo');
        await page.waitForSelector('#batchPreview:not([hidden])');
        check((await page.textContent('#batchPreview')).includes('ZZ Owner'), `${label}: Batch edit shows what changes before applying`, await page.textContent('#batchPreview'));
        await a11y('the Batch edit preview');
        await page.click('#btnBatchGo');
        await page.waitForFunction(() => !document.getElementById('dlgBatch').open);

        await page.click(`#gridBody tr[data-name="${testApp}"]`);
        await page.click('#btnMore');
        await page.click('[data-act="addgroups"]');
        await page.waitForSelector('#dlgGroupsBatch[open]');
        await unnamed('Add groups'); await a11y('Add groups');
        await page.fill('[data-gbx="requiredFor"]', 'SG-ZZ-UI');
        await page.uncheck('#gbPush');
        await page.click('#btnGbGo');
        await page.waitForFunction(() => !document.getElementById('dlgGroupsBatch').open);

        await page.dblclick(`#gridBody tr[data-name="${testApp}"]`);
        await page.waitForSelector('#dlgApp[open]');
        await page.waitForFunction(() => document.getElementById('aName').value !== '');
        check(await page.inputValue('#mOwner') === 'ZZ Owner', `${label}: Batch edit saved the owner`, await page.inputValue('#mOwner'));
        check((await page.inputValue('#gRequired')).split('\n').includes('SG-ZZ-UI'), `${label}: Add groups saved the group`, await page.inputValue('#gRequired'));
        await page.keyboard.press('Escape');
        await page.waitForFunction(() => !document.getElementById('dlgApp').open);

        // Undo the last bulk change (Add groups): the group is gone again, the owner from Batch edit stays.
        await page.waitForSelector('#undoBanner:not([hidden])');
        check(/Add groups/.test(await page.textContent('#undoText')), `${label}: the undo banner names the last bulk change`, await page.textContent('#undoText'));
        await page.click('#btnUndo');
        await page.waitForSelector('#dlgAsk[open]');
        await page.click('#askOk');
        await page.waitForSelector('#undoBanner', { state: 'hidden' });
        await page.dblclick(`#gridBody tr[data-name="${testApp}"]`);
        await page.waitForSelector('#dlgApp[open]');
        await page.waitForFunction(() => document.getElementById('aName').value !== '');
        check(!(await page.inputValue('#gRequired')).split('\n').includes('SG-ZZ-UI') && await page.inputValue('#mOwner') === 'ZZ Owner', `${label}: Undo took Add groups back and kept Batch edit`, await page.inputValue('#gRequired'));
        await page.click('#btnRemoveApp');
        await page.waitForSelector('#dlgAsk[open]');
        check(await page.evaluate(() => document.activeElement.id === 'askCancel' && document.getElementById('askOk').classList.contains('dangerous')),
          `${label}: removing asks in the app's own dialog, red button, Cancel focused`);
        await unnamed('the question dialog'); await a11y('the question dialog');
        await page.click('#askOk');
        await page.waitForSelector(`#gridBody tr[data-name="${testApp}"]`, { state: 'detached' });
        check(!(await page.isVisible(`#gridBody tr[data-name="${testApp}"]`)), `${label}: the app is removed again`);
      }

      check(errors.length === 0, `${label}: no errors in the page and no failed requests`, errors.join(' | '));
      await ctx.close();
    }
  }
} finally {
  await browser.close();
  // The page's own Quit isn't reachable without a window; the server stops with its process.
  server.kill();
}

console.log('');
if (failures.length === 0) { console.log(`PASSED: ${passed} check(s).`); process.exit(0); }
console.log(`FAILED: ${failures.length} of ${passed + failures.length}.`);
process.exit(1);
