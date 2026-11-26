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
import { mkdirSync, existsSync, rmSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
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
// What the run itself creates in the repo (the catalog and settings in data\, the shared package in init\) is removed
// again afterwards - so the next run starts clean. Folders that were there before the run are left alone.
const leftovers = ['data', 'init'].map(d => join(repo, d)).filter(d => !existsSync(d));
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
      // 2.38.3: nothing squeezed - a field a few pixels wide, a label wrapping letter by letter (the release rule's
      // fields sat beside a floated heading). In the open dialog, else the page; only what is shown.
      const squeezed = async view => {
        const bad = await page.evaluate(() => {
          const dlg = [...document.querySelectorAll('dialog[open]')].pop();
          const root = dlg || document.querySelector('.view:not([hidden])') || document.body;
          const shown = e => { const r = e.getBoundingClientRect(); if (!r.width && !r.height) return false; const cs = getComputedStyle(e); return cs.visibility !== 'hidden' && cs.display !== 'none' && cs.clip !== 'rect(0px, 0px, 0px, 0px)' && !e.closest('[hidden]'); };
          const name = e => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + (e.className && typeof e.className === 'string' ? '.' + e.className.trim().split(/\s+/).slice(0, 2).join('.') : '');
          const out = [];
          for (const e of root.querySelectorAll('input, select, textarea')) {
            if (['checkbox', 'radio', 'hidden', 'file', 'color', 'range'].includes(e.type) || !shown(e)) continue;
            const w = e.getBoundingClientRect().width;
            if (w > 0 && w < 36) out.push(`${name(e)} is ${Math.round(w)}px wide`);
          }
          for (const e of root.querySelectorAll('label, legend, p, span, td, th, h2, h3, button, a, b, li')) {
            const own = [...e.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join('').trim();
            if (own.length < 6 || !shown(e)) continue;
            // Squeezed: narrow and wrapping over several lines (a short ID that is simply narrow is fine).
            const r = e.getBoundingClientRect(), line = parseFloat(getComputedStyle(e).fontSize) * 1.25;
            if (r.width > 0 && r.width < 48 && r.height > 2.5 * line) out.push(`${name(e)} "${own.slice(0, 20)}" is ${Math.round(r.width)}px wide, ${Math.round(r.height)}px high`);
          }
          // 2.38.8: nothing cut off - a button, link or field reaching past a box that hides what sticks out (the
          // Getting started card hid its Open buttons behind a long permission name). Scrolling boxes are fine.
          for (const e of root.querySelectorAll('button, a.btn, select, input:not([type=checkbox]):not([type=radio]):not([type=hidden])')) {
            if (!shown(e)) continue;
            const r = e.getBoundingClientRect();
            if (r.width < 2) continue;
            for (let a = e.parentElement; a && a !== document.body; a = a.parentElement) {
              const ox = getComputedStyle(a).overflowX;
              if (ox !== 'hidden' && ox !== 'clip') continue;
              const ar = a.getBoundingClientRect();
              if (r.right > ar.right + 1 || r.left < ar.left - 1) { out.push(`${name(e)} "${(e.textContent || e.value || '').trim().slice(0, 16)}" is cut off by ${name(a)} (${Math.round(r.right - ar.right)}px)`); break; }
            }
          }
          return out.slice(0, 5);
        });
        check(!bad.length, `${label}: ${view} - nothing squeezed or cut off (fields, labels and buttons have room)`, bad.join('; '));
      };
      // Every rule axe-core has for WCAG 2.1 A/AA and best practice - in the
      // open dialog when there is one (axe skips what's behind a modal).
      // 2.38.4: opening a list doesn't move things - lists that fill in when clicked (winget's versions, Link...,
      // profiles) keep their width, and so does everything beside them.
      const steady = async view => {
        const where = () => {
          const dlg = [...document.querySelectorAll('dialog[open]')].pop();
          const root = dlg || document.querySelector('.view:not([hidden])') || document.body;
          return [...root.querySelectorAll('select:not([multiple]):not([size])')].filter(e => e.offsetParent !== null && !e.disabled);
        };
        // Measured once the dialog's opening animation is over (it grows from 98%).
        await page.evaluate(() => Promise.all(document.getAnimations().filter(a => a.effect && a.effect.getComputedTiming().iterations !== Infinity).map(a => a.finished.catch(() => { }))));
        const before = await page.evaluate(`(${where})().map(e => [e.id || e.className, Math.round(e.getBoundingClientRect().width)])`);
        await page.evaluate(`(${where})().forEach(e => { e.dispatchEvent(new Event('focus')); e.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })); })`);
        await page.waitForTimeout(600);
        const after = await page.evaluate(`(${where})().map(e => [e.id || e.className, Math.round(e.getBoundingClientRect().width)])`);
        const moved = before.filter(([id, w]) => { const a = after.find(x => x[0] === id); return a && Math.abs(a[1] - w) > 1; })
          .map(([id, w]) => `${id} ${w}px -> ${after.find(x => x[0] === id)[1]}px`);
        check(!moved.length, `${label}: ${view} - lists keep their size when opened`, moved.join('; '));
      };
      const a11y = async view => {
        await squeezed(view);
        await steady(view);
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
      // 2.38.67: one banner on the pages that need the connection (and the sidebar badge) - not each page in its own words.
      check(await page.isVisible('#setupBanner') && /Not connected/.test(await page.textContent('#setupBanner')) && /Not connected - set up/.test(await page.textContent('#connBadge')) && !/Not connected/.test(await page.textContent('#viewApps')), `${label}: "not connected" is one banner (and the badge), not a line of the Apps page`, await page.textContent('#connBadge'));
      await noOverflow('Apps'); await unnamed('Apps'); await a11y('Apps'); await shot('apps');
      // 2.38.3: an app in a later release ring, before the settings are read: the list still shows (it stayed empty).
      const ringOk = await page.evaluate(() => { const keep = prefs; prefs = null; apps.push({ ...(apps[0] || {}), name: 'ZZ ring app', pilotVersion: '2.0', pilotRing: 1, groups: [] });
        let ok = true; try { renderApps(); } catch (e) { ok = false; } apps.pop(); prefs = keep; renderApps(); return ok; });
      check(ringOk, `${label}: the Apps list shows an app in a later release ring before the settings are read`);

      // Add apps: three ways in; the empty form is one click further.
      await page.click('#btnAddApp');
      await page.waitForSelector('#dlgAdd[open]');
      check(await page.isVisible('#awQuery') && await page.isDisabled('#btnAddGo'), `${label}: Add apps opens on the winget search, Add off until something is picked`);
      await unnamed('Add apps (winget)'); await a11y('Add apps (winget)'); await shot('add-winget');
      // 2.38.13: Microsoft Store - the same search, asking the Store (answered here by hand), no managed updates.
      await page.evaluate(`window.__apiS = api; api = (path, body) => path === '/api/store-search' ? Promise.resolve({ ok: true, source: 'store',
        rows: [{ name: 'Company Portal', id: '9WZDNCRFJ3PZ', publisher: 'Microsoft Corporation', version: '' }] }) : window.__apiS(path, body);`);
      await page.click('#atab-store');
      await page.fill('#awQuery', 'company');
      await page.waitForSelector('#awRows tr');
      const sto = await page.evaluate(() => ({ col: document.getElementById('awColLast').textContent, cell: document.querySelector('#awRows tr td:last-child').textContent,
        managed: !document.getElementById('awManagedRow').hidden, note: !document.getElementById('awStoreNote').hidden, ph: document.getElementById('awQuery').placeholder }));
      check(sto.col === 'Publisher' && sto.cell === 'Microsoft Corporation' && !sto.managed && sto.note && /Microsoft Store/.test(sto.ph), `${label}: Add apps > Microsoft Store searches the Store, shows the publisher, no managed updates`, JSON.stringify(sto));
      await page.click('#awRows tr');
      check(await page.textContent('#btnAddGo') === 'Add 1 Store app' && /apps\.microsoft\.com\/detail\/9WZDNCRFJ3PZ/.test(await page.getAttribute('#awDetail a', 'href')), `${label}: a picked Store app - its Store page, and Add names it`, await page.textContent('#btnAddGo'));
      await a11y('Add apps (Microsoft Store)');
      await page.click('#atab-winget');
      check(await page.evaluate(() => document.getElementById('awColLast').textContent === 'Version' && !document.getElementById('awManagedRow').hidden && !document.querySelector('#awRows tr')), `${label}: back on Winget - its own columns, managed updates, the Store picks gone`);
      await page.evaluate('api = window.__apiS;'); await page.fill('#awQuery', '');
      await page.click('#atab-installer');
      check(await page.isVisible('#aiDrop'), `${label}: Add apps has a drop zone for an installer`);
      await a11y('Add apps (installer)');
      // 2.38.18: Detected by chosen in the dialog - and several files at once go up together, as one folder.
      const det = await page.evaluate(() => {
        showUploadReview({ ok: true, fileName: 'ClientSetup.exe', size: 1000, kind: 'exe', exeKind: 'inno', name: 'apm system2', publisher: 'APM', version: '2.1', installCommand: '"ClientSetup.exe" /VERYSILENT', uninstallCommand: 'x', detection: 'Script', notes: [], managedOk: false });
        const out = { proposed: aiDetection(), proposedText: document.getElementById('aiDetType').selectedOptions[0].textContent };
        const t = document.getElementById('aiDetType'); t.value = 'registry'; t.dispatchEvent(new Event('change'));
        out.innoKey = document.getElementById('aiDetKey').value; out.blocked = document.getElementById('btnAddGo').disabled;
        document.getElementById('aiDetKey').value = 'HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{A6917EBF-00FC-419B-A5D0-42F265CD9C85}_is1';
        document.getElementById('aiDet32').checked = true; document.getElementById('aiDetKey').dispatchEvent(new Event('input'));
        out.rule = aiDetection(); out.boxShown = !document.getElementById('aiDetBox').hidden; out.free = !document.getElementById('btnAddGo').disabled;
        const f = n => new File(['x'], n);
        out.many = pickFromFiles([f('login.xml'), f('ClientSetup.exe'), f('loneos.inf')]);
        out.many = { folderName: out.many.folderName, count: out.many.files.length };
        out.one = !!pickFromFiles([f('ClientSetup.exe')]).file;
        t.value = 'proposed'; t.dispatchEvent(new Event('change'));
        return out;
      });
      check(det.proposed === null && /Proposed: A script/.test(det.proposedText) && /\{AppId\}_is1$/.test(det.innoKey) && det.blocked && det.boxShown && det.free
        && det.rule.Type === 'Registry' && det.rule.Reg_ValueName === 'DisplayVersion' && det.rule.Reg_DetectionType === 'version' && det.rule.Reg_DetectionValue === '2.1' && det.rule.Reg_Check32Bit === true
        && det.many.folderName === 'ClientSetup' && det.many.count === 3 && det.one, `${label}: Detected by is chosen in the Add dialog (Inno: the _is1 key to fill in), and several files go up together`, JSON.stringify(det));
      await page.evaluate(() => resetInstaller());
      await page.click('#atab-script');
      await page.waitForFunction(() => document.getElementById('asTemplate').options.length > 0 && /IntuneAppCatalog/.test(document.getElementById('asInstall').value));
      await page.fill('#asName', 'ZZ UI script');
      check(!(await page.isDisabled('#btnAddGo')), `${label}: a script app can be added once it has a name - the template writes the version marker`);
      check(await page.textContent('#btnAddGo') === 'Add script app', `${label}: the Add button names what it adds`, await page.textContent('#btnAddGo'));
      await unnamed('Add apps (script)'); await a11y('Add apps (script)'); await shot('add-script');
      // 2.38.0: From a list > Recommended apps - the starter set by category, the recommended ones ticked.
      await page.click('#atab-list'); await page.click('#btnAlStarter');
      await page.waitForFunction(() => document.querySelectorAll('#alRows tr').length > 20, null, { timeout: 10000 }).catch(() => {});
      const rec = await page.evaluate(() => ({ pinned: [...document.querySelectorAll('#alRows tr.grouprow > *')].some(c => getComputedStyle(c).position === 'sticky'), heads: document.querySelectorAll('#alRows tr.grouprow').length, ticked: document.querySelectorAll('#alRows input:checked').length, common: [...document.querySelectorAll('#alRows .pill')].filter(p => p.textContent === 'common').length, tv: /TeamViewer Host[\s\S]*TeamViewer QuickSupport/.test(document.getElementById('alRows').textContent), firefox: /Mozilla Firefox/.test(document.getElementById('alRows').textContent), ms: /^Microsoft 365 Apps[\s\S]*Company Portal/.test(document.querySelector('#alRows tr:not(.grouprow) td:nth-child(2)')?.textContent + ' ' + document.querySelectorAll('#alRows tr:not(.grouprow) td:nth-child(2)')[1]?.textContent), cleanup: [...document.querySelectorAll('#alRows td .mono')].filter(m => m.textContent === 'script app').length, button: document.getElementById('btnAddGo').textContent }));
      check(!rec.pinned && rec.heads >= 5 && rec.ticked === 0 && rec.common === 15 && rec.ms && rec.tv && rec.firefox && rec.cleanup === 5 && rec.button === 'Add from the list', `${label}: Recommended apps - by category, nothing ticked, the fifteen usual ones marked common (Microsoft 365 Apps and Company Portal first, the three clean-up and two TeamViewer script apps), TeamViewer Host and QuickSupport there`, JSON.stringify(rec));
      await noOverflow('Add apps (recommended)'); await unnamed('Add apps (recommended)'); await a11y('Add apps (recommended)');
      await page.evaluate(() => { const w = document.getElementById('alGrid').closest('.tablewrap'); w.scrollTop = 400; }); await shot('add-recommended');
      // 2.38.33: the list has a search - every word must match name, ID, category or what it is for; Select all ticks only what shows.
      await page.fill('#alSearch', 'lenovo');
      const srch = await page.evaluate(() => ({ shown: document.getElementById('alSearchRow').hidden === false, rows: [...document.querySelectorAll('#alRows tr:not(.grouprow)')].map(r => r.textContent) }));
      check(srch.shown && srch.rows.length >= 2 && srch.rows.every(t => /lenovo/i.test(t)), `${label}: From a list - the search shows only matching apps`, JSON.stringify(srch));
      await page.evaluate(() => { const a = document.getElementById('alAll'); a.checked = true; a.dispatchEvent(new Event('change')); });
      await page.fill('#alSearch', '');
      const tickedAll = await page.evaluate(() => document.querySelectorAll('#alRows input:checked:not(#alAll)').length);
      check(tickedAll >= 2 && tickedAll <= 4, `${label}: From a list - Select all ticks only the apps the search showed`, String(tickedAll));
      await page.fill('#alSearch', 'zzznothingzzz');
      check(/Nothing in the list matches/.test(await page.textContent('#alRows')), `${label}: From a list - a search without matches says so`);
      await page.fill('#alSearch', '');
      await page.click('#atab-script');
      await page.click('#btnAddBlank');
      await page.waitForSelector('#dlgApp[open]');
      await unnamed('the app editor'); await a11y('the app editor'); await shot('editor');
      // 2.38.3: managed updates on, the release rule opened with Change - its fields have room (they were squeezed).
      await page.evaluate(() => { const m = document.getElementById('aManaged'); m.checked = true; m.dispatchEvent(new Event('change')); });
      await page.click('.edtab[data-i="1"]');   // 2.38.67: the release rule is under Updates
      await page.click('#arSum button');
      check(await page.evaluate(() => { const r = document.getElementById('arDays').getBoundingClientRect(); return r.width > 60; }), `${label}: the release rule's fields have room once opened`, String(await page.evaluate(() => document.getElementById('arDays').getBoundingClientRect().width)));
      await squeezed('the app editor (release rule open)');
      // A fresh editor again (the toggle made this one changed - Escape would ask first).
      await page.evaluate(() => { document.getElementById('dlgApp').close(); openEditor(''); });
      await page.waitForSelector('#dlgApp[open]');
      // Each tab is a page of the editor: only its part shows.
      await page.click('.edtab[data-i="4"]');
      check(await page.isVisible('#xType') && !(await page.isVisible('#aName')), `${label}: the editor's Install & detection tab shows the detection rule, not the basics`);
      await unnamed('the app editor (install & detection)'); await a11y('the app editor (install & detection)');
      // 2.38.67: "Ready to send?" is a chip in the footer on every part; it opens the list, and a link in it goes to the field.
      check(await page.isVisible('#readyChip') && /of \d/.test(await page.textContent('#readyChip')), `${label}: the footer says how ready it is, on every part`, await page.textContent('#readyChip'));
      await page.click('#readyChip');
      check(await page.isVisible('#readyBox'), `${label}: the chip opens the list of what it still needs`);
      await page.click('#readyList .linkish');
      check(!(await page.isVisible('#readyBox')) && await page.isVisible('#aName'), `${label}: a link in the list goes to the field (the App part) and closes the list`);
      await page.click('.edtab[data-i="4"]');
      // The name is a required field: the browser itself says so, the save never leaves the page, and the editor shows the name's page.
      await page.click('#btnSaveApp');
      const blocked = await page.evaluate(() => document.getElementById('aName').validity.valueMissing && document.getElementById('dlgApp').open);
      check(blocked && await page.isVisible('#aName'), `${label}: saving an app without a name is stopped, the editor stays open on the name's page`);
      await page.keyboard.press('Escape');
      check(!(await page.isVisible('#dlgApp[open]')), `${label}: Escape closes the editor`);

      // Home: getting started (nothing set up here), what needs a look; Ctrl+K finds pages and actions.
      await page.click('#tabHome');
      await page.waitForFunction(() => !/Looking/.test(document.getElementById('homeNote').textContent));
      check(await page.isVisible('#homeSetup') && /Connect to Intune/.test(await page.textContent('#setupList li.now')), `${label}: Home's getting started points at the first step - connecting`, await page.textContent('#homeSetup'));
      // 2.31.0: said once - in Getting started, not again in Needs attention or the banner; no zero tiles.
      check(!/Not connected/.test(await page.textContent('#homeList')) && !(await page.isVisible('#setupBanner')) && !(await page.isVisible('#homeStats')), `${label}: Home says "not connected" once, in Getting started`, await page.textContent('#homeList'));
      await noOverflow('Home'); await unnamed('Home'); await a11y('Home'); await shot('home');
      // 2.38.6/2.38.8: connected but a permission missing - the step says which, with its long name, and every Open button
      // stays inside the card.
      await page.evaluate(`homeLocal = { ...homeLocal, setup: homeLocal.setup.map((x, i) => i === 0 ? { ...x, done: true } : x) };
        homeIntune = { ok: true, items: [], summary: null, permMissing: ['DeviceManagementManagedDevices.Read.All'] }; renderHome();`);
      check(/Grant the missing permissions/.test(await page.textContent('#setupList li.now')) && /1 permission is missing/.test(await page.textContent('#setupList li.now'))
        && /DeviceManagementManagedDevices\.Read\.All/.test(await page.getAttribute('#setupList li.now .body', 'title')) && (await page.textContent('#setupList li.now button')) === 'Check permissions',
        `${label}: Getting started keeps Connect open while a permission is missing, and names it`, await page.textContent('#setupList'));
      await squeezed('Home (a permission missing)');
      await page.evaluate('homeIntune = null; loadHome(true);');
      // 2.38.8: Read from Intune - each differing field is a choice between its two values (Intune's picked), the
      // log folded away. Fed a result by hand (no tenant here).
      await page.evaluate(`window.__runJob = runJob; runJob = (body, done) => { done(true, null, { applied: [], failed: [], pending: 'zz',
        review: [{ app: 'ZZ Pull', diffs: [{ field: 'Required for', local: '', intune: '[All devices]' }, { field: 'Publisher', local: 'Old Name Ltd', intune: 'New Name Ltd' }] }] }); return Promise.resolve(true); };
        openPull(['ZZ Pull']);`);
      await page.waitForSelector('#dlgPull[open] #pullReview tr[data-field]');
      const pull0 = await page.evaluate(() => ({ picks: [...document.querySelectorAll('#pullReview tr[data-field]')].map(t => t.dataset.pick).join(','), btn: document.getElementById('btnPullApply').textContent, log: document.getElementById('pullLogBox').open, blank: /\(empty\)/.test(document.getElementById('pullReview').textContent) }));
      check(pull0.picks === 'intune,intune' && /2 from Intune, 0 kept/.test(pull0.btn) && !pull0.log && pull0.blank, `${label}: Read from Intune - Intune's value is picked for each field, the log folded`, JSON.stringify(pull0));
      await page.click('#pullReview tr[data-field="Publisher"] td.pick[data-side="catalog"]');
      const pull1 = await page.evaluate(() => ({ picks: [...document.querySelectorAll('#pullReview tr[data-field]')].map(t => t.dataset.pick).join(','), btn: document.getElementById('btnPullApply').textContent }));
      check(pull1.picks === 'intune,catalog' && /1 from Intune, 1 kept/.test(pull1.btn), `${label}: Read from Intune - clicking the catalog's value keeps it`, JSON.stringify(pull1));
      await page.click('#pullReview .pullall button:first-child');
      check(await page.evaluate(() => [...document.querySelectorAll('#pullReview tr[data-field]')].every(t => t.dataset.pick === 'catalog')), `${label}: Read from Intune - Keep all picks the catalog's values`);
      await a11y('Read from Intune');
      await page.evaluate(`document.getElementById('dlgPull').close(); runJob = window.__runJob;`);
      // 2.38.8: every log colours its lines; a failure opens a folded log.
      await page.evaluate(() => { const l = document.getElementById('pullLog'); document.getElementById('pullLogBox').open = false; l.textContent = '== Step ==\n  [OK] Connected.\n  [WARN] Slow.\n[FAILED] Graph said no.\n[GRAPH] GET /x -> FAILED (9 ms): nope\n'; });
      await page.waitForFunction(() => document.querySelectorAll('#pullLog .lerr').length === 2);
      const logc = await page.evaluate(() => ({ err: document.querySelectorAll('#pullLog .lerr').length, warn: document.querySelectorAll('#pullLog .lwarn').length, ok: document.querySelectorAll('#pullLog .lok').length, open: document.getElementById('pullLogBox').open, text: document.getElementById('pullLog').textContent.split('\n').length }));
      check(logc.err === 2 && logc.warn === 1 && logc.ok === 1 && logc.open && logc.text === 6, `${label}: logs colour failures, warnings and OK lines, and a failure opens the log`, JSON.stringify(logc));
      await page.evaluate(() => { document.getElementById('pullLog').textContent = ''; });
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
      check(await page.isVisible('#updEmpty') && await page.isVisible('#setupBanner') && !/Not connected/i.test(await page.textContent('#updNote')), `${label}: Updates explains the empty page; the banner says it isn't connected`, await page.textContent('#updNote'));
      await noOverflow('Updates'); await unnamed('Updates'); await a11y('Updates'); await shot('updates');

      // Checks: runs, and says Intune wasn't checked.
      await page.click('#tabChecks');
      await page.click('#btnRunChecks');
      await page.waitForFunction(() => document.getElementById('btnRunChecks').textContent === 'Run checks');
      // 2.32.0: said once - in the empty state, not again in the note above it.
      check(/not checked/i.test(await page.textContent('#checkEmptyText')) && !/not checked/i.test(await page.textContent('#checkNotes')), `${label}: Checks says once that Intune wasn't checked`, await page.textContent('#checkNotes'));
      await noOverflow('Checks'); await unnamed('Checks'); await a11y('Checks'); await shot('checks');
      // 2.38.4: "Differs" - a chip per field; pointing at them shows the values side by side, Esc closes, and from the
      // keyboard the focus goes into the card and back. Findings put in by hand (there is no tenant here).
      await page.evaluate(`findings = [
        { area: 'Metadata', app: 'ZZ Card', catalogName: 'ZZ Card', problem: '3 field(s) differ', actions: ['Pull', 'PushMetadata'],
          data: { Diffs: [{ Field: 'Description', Local: 'A file archiver', Remote: 'A file manager' }, { Field: 'Publisher', Local: 'Igor Pavlov', Remote: '' },
            { Field: 'Return codes', Local: '[{"returnCode":0,"type":"success"},{"returnCode":3010,"type":"softReboot"}]', Remote: '[{"returnCode":0,"type":"success"}]' }] } },
        { area: 'Unknown assignments', app: 'ZZ Portal', catalogName: 'ZZ Portal', problem: '1 unknown', catalog: '(not in the catalog)', intune: '[required] All devices', actions: ['PushGroups', 'Pull'] }];
        renderChecks();`);
      const chips = await page.$$eval('#checkBody .difs .dchip', a => a.map(x => x.textContent));
      check(chips.join('|') === 'Description|Publisher|Return codes', `${label}: Checks lists the differing fields as chips`, chips.join('|'));
      check(/Intune.*All devices/.test(await page.textContent('#checkBody tr:nth-child(2) td.dif')), `${label}: a finding without fields shows its catalog and Intune lines`);
      await page.hover('#checkBody .difs');
      await page.waitForSelector('#cmpCard:not([hidden])', { timeout: 3000 }).catch(() => { });
      const card = await page.evaluate(() => { const c = document.getElementById('cmpCard'); if (!c || c.hidden) return null; const r = c.getBoundingClientRect();
        return { rows: c.querySelectorAll('tbody tr').length, marks: c.querySelectorAll('mark.del, mark.add').length, blank: /\(empty\)/.test(c.textContent),
          inside: r.left >= 0 && r.right <= innerWidth && r.top >= 0 && r.bottom <= innerHeight, take: [...c.querySelectorAll('button')].map(b => b.textContent).join('|') }; });
      check(card && card.rows === 3 && card.marks >= 2 && card.blank, `${label}: hovering the chips shows the fields side by side, the changes marked`, JSON.stringify(card));
      check(card && card.inside, `${label}: the hover card fits the window`, JSON.stringify(card));
      check(card && card.take === 'Open full compare|Take from Intune|Send settings', `${label}: the hover card offers the fixes`, card && card.take);
      await a11y('Checks hover card');
      await page.mouse.move(2, 2); await page.waitForTimeout(400);
      check(await page.evaluate(() => document.getElementById('cmpCard').hidden), `${label}: the hover card closes when the pointer leaves`);
      // 2.38.35: clicked into, it stays - scrolling inside it and moving the pointer away don't close it; Esc does.
      await page.hover('#checkBody .difs');
      await page.waitForSelector('#cmpCard:not([hidden])', { timeout: 3000 }).catch(() => { });
      await page.click('#cmpCard header');
      await page.evaluate(() => { const b = document.querySelector('#cmpCard .hcbody'); b.dispatchEvent(new Event('scroll')); });
      await page.mouse.move(2, 2); await page.waitForTimeout(400);
      check(await page.evaluate(() => !document.getElementById('cmpCard').hidden), `${label}: the hover card, clicked into, stays while it is scrolled and the pointer leaves`);
      await page.keyboard.press('Escape');
      check(await page.evaluate(() => document.getElementById('cmpCard').hidden), `${label}: ...and Esc closes it`);
      await page.focus('#checkBody .difs'); await page.keyboard.press('Enter');
      check(await page.evaluate(() => { const c = document.getElementById('cmpCard'); return !c.hidden && c.contains(document.activeElement); }), `${label}: Enter on the chips opens the card and moves into it`);
      await page.keyboard.press('Escape');
      check(await page.evaluate(() => document.getElementById('cmpCard').hidden && document.activeElement.classList.contains('difs') && !document.querySelector('dialog[open]')), `${label}: Esc closes the card and goes back to the chips`);
      await page.click('#checkBody .difs'); await page.click('#cmpCard button');
      check(await page.evaluate(() => document.getElementById('dlgCompare').open && document.getElementById('cmpCard').hidden), `${label}: Open full compare opens Compare`);
      await page.keyboard.press('Escape');
      // 2.38.6: one problem, one row - an Unknown assignments finding that the app's Groups finding already shows is
      // folded into it; one with something the Groups row can't show (a filter) stays.
      await page.evaluate(`findings = [
        { area: 'Groups', app: 'ZZ Portal', catalogName: 'ZZ Portal', problem: '1 assignment list(s) differ: Required for', actions: ['Pull', 'PushGroups'],
          data: { Diffs: [{ Field: 'Required for', Local: '', Remote: '[All devices]' }] } },
        { area: 'Unknown assignments', app: 'ZZ Portal', catalogName: 'ZZ Portal', problem: '1 unknown', catalog: '(not in the catalog)', intune: '[required] [All devices]', actions: ['PushGroups', 'Pull'] },
        { area: 'Groups', app: 'ZZ Filtered', catalogName: 'ZZ Filtered', problem: '1 differ', actions: ['Pull'], data: { Diffs: [{ Field: 'Required for', Local: '', Remote: 'SG-A' }] } },
        { area: 'Unknown assignments', app: 'ZZ Filtered', catalogName: 'ZZ Filtered', problem: '1 unknown', catalog: '(not in the catalog)', intune: '[required] SG-A (filter: Laptops)', actions: ['Pull'] }];
        renderChecks();`);
      const rows = await page.$$eval('#checkBody tr', r => r.map(x => x.children[1].textContent + ':' + x.children[2].textContent));
      check(rows.join('|') === 'Groups:ZZ Portal|Groups:ZZ Filtered|Unknown assignments:ZZ Filtered', `${label}: an Unknown assignments finding the Groups row already shows is one row`, rows.join('|'));
      check(/^3 /.test(await page.textContent('#checkCount')), `${label}: the count leaves the folded finding out`, await page.textContent('#checkCount'));
      // 2.38.8: the last audit's saved rows (shown while checks run) carry only their text - they fold too.
      await page.evaluate(`findings = [
        { area: 'Groups', app: 'ZZ Saved', catalogName: 'ZZ Saved', cached: true, problem: '2 differ: Required for - catalog: (none) | Intune: [All devices]; Available for - catalog: SG-A | Intune: SG-A, SG-B', actions: ['Pull'] },
        { area: 'Unknown assignments', app: 'ZZ Saved', catalogName: 'ZZ Saved', cached: true, problem: '2 unknown: [required] [All devices], [available] SG-B', actions: ['Pull'] },
        { area: 'Groups', app: 'ZZ Saved2', catalogName: 'ZZ Saved2', cached: true, problem: '1 differ: Required for - catalog: (none) | Intune: SG-C', actions: ['Pull'] },
        { area: 'Unknown assignments', app: 'ZZ Saved2', catalogName: 'ZZ Saved2', cached: true, problem: '1 unknown: [required] SG-D', actions: ['Pull'] }];
        renderChecks();`);
      const savedRows = await page.$$eval('#checkBody tr', r => r.map(x => x.children[1].textContent + ':' + x.children[2].textContent));
      check(savedRows.join('|') === 'Groups:ZZ Saved|Groups:ZZ Saved2|Unknown assignments:ZZ Saved2', `${label}: the last audit's saved rows fold the same way`, savedRows.join('|'));
      await page.evaluate('findings = []; renderChecks();');
      // 2.38.8: Changes to send - pointing at the stage shows what changed since the last send (answered here by hand).
      await page.click('#tabApps');
      await page.evaluate(`window.__api = api; api = (path, body) => path === '/api/unsent-diff' ? Promise.resolve({ ok: true, name: 'ZZ Unsent', fromHistory: false,
        rows: [{ part: 'settings', field: 'Description', sent: 'A file archiver', now: 'A file archiver with a high compression ratio' }] }) : window.__api(path, body);
        apps.push({ name: 'ZZ Unsent', hasAppId: true, unsent: 'settings', groups: ['SG-A'], version: '1.0' }); renderApps();`);
      // 2.38.37: Send settings while another is being sent lines it up instead of refusing it.
      const queued = await page.evaluate(async () => { const was = jobRunning, la = loadApps; loadApps = () => {}; jobRunning = true; sendSettingsNow(['ZZ Q1']); sendSettingsNow(['ZZ Q2']); sendSettingsNow(['ZZ Q2']);
        const q = sendQueue.map(x => x.name).join(',');
        // 2.38.39: each send its own window, side by side - the newest on the left (the stack runs right to left).
        const cards = [...document.querySelectorAll('#sendStack .sendcard')].map(c => c.querySelector('.sapp').textContent + ':' + c.querySelector('.sstate').textContent);
        const r = [...document.querySelectorAll('#sendStack .sendcard')].map(c => c.getBoundingClientRect().left);
        sendQueue.length = 0; jobRunning = was; await new Promise(r => setTimeout(r, 1200)); loadApps = la; document.getElementById('sendStack').remove();
        return { q, cards: cards.join('|'), newestLeft: r.length === 2 && r[1] < r[0] }; });
      check(queued.q === 'ZZ Q1,ZZ Q2', `${label}: Send settings clicked again while one runs is queued (once per app), not refused`, JSON.stringify(queued));
      check(queued.cards === 'ZZ Q1:Waiting|ZZ Q2:Waiting' && (size.width < 1001 || queued.newestLeft), `${label}: each queued send has its own window, the newest left of the others (one column below 1000 px)`, JSON.stringify(queued));
      const unsentPill = page.locator('#grid tr', { hasText: 'ZZ Unsent' }).locator('button.pillbtn');
      check(await unsentPill.count() === 1 && /Changes to send/.test(await unsentPill.textContent()), `${label}: Changes to send is a pill that opens the changes`);
      await unsentPill.hover();
      await page.waitForSelector('#cmpCard:not([hidden])', { timeout: 3000 }).catch(() => { });
      const uc = await page.evaluate(() => { const c = document.getElementById('cmpCard'); return c && !c.hidden ? { rows: c.querySelectorAll('tbody tr').length, head: [...c.querySelectorAll('th')].map(t => t.textContent).join('|'), marks: c.querySelectorAll('mark.add').length, btns: [...c.querySelectorAll('footer button')].map(b => b.textContent).join('|') } : null; });
      check(uc && uc.rows === 1 && uc.head === 'Field|Intune has (last sent)|Catalog now' && uc.marks === 1 && uc.btns === 'Send settings|Edit', `${label}: hovering Changes to send shows the last-sent value next to the catalog's`, JSON.stringify(uc));
      await a11y('Changes to send card');
      await page.mouse.move(2, 2); await page.waitForTimeout(400);
      await page.evaluate(`api = window.__api; apps = apps.filter(a => a.name !== 'ZZ Unsent'); renderApps();`);
      await page.click('#tabChecks');

      // Groups and Platform scripts: empty, explained.
      await page.click('#tabGroups');
      // 2.32.0: not connected and no group in the catalog - one message and a way to set it up, no controls.
      await page.waitForSelector('#btnGroupsSetup:not([hidden])');
      check(!(await page.isVisible('#groupSearch')) && /needs the connection/.test(await page.textContent('#groupEmpty')), `${label}: Groups without a connection says so once, with a way to set it up`);
      await noOverflow('Groups'); await unnamed('Groups'); await a11y('Groups'); await shot('groups');
      await page.click('#tabScripts');
      await page.waitForFunction(() => !/Reading/.test(document.getElementById('scriptNote').textContent));
      check(await page.isVisible('#setupBanner') && !(await page.getAttribute('#scriptNote', 'class')).includes('warntext'), `${label}: Platform scripts - the banner says it isn't connected, the page's note isn't a warning`);
      await noOverflow('Platform scripts'); await unnamed('Platform scripts'); await a11y('Platform scripts'); await shot('scripts');

      // Settings: diagnostics, prerequisites, the guide.
      await page.click('#tabSettings');
      await page.click('#stab-connection');
      await page.click('#guideReg summary');
      await noOverflow('Settings'); await unnamed('Settings'); await a11y('Settings'); await shot('settings');
      for (const sec of ['defaults', 'updates', 'automation', 'packaging']) {
        await page.click(`#stab-${sec}`);
        if (sec === 'defaults') check(await page.isVisible('#dWinget') && await page.isVisible('#profRows'), `${label}: Settings > Apps & defaults has the default values and the profiles`);
        if (sec === 'updates') check(await page.isVisible('#pilotGroupsChips') && await page.isVisible('#rpDays') && await page.isVisible('#rpFastHours'), `${label}: Settings > Updates has the pilot groups and the release rule`);
        if (sec === 'automation') {
          // The nightly run's list (no run yet on a fresh test machine), and alerts.
          await page.waitForFunction(() => /No run yet|run is going|plan only/i.test(document.getElementById('runList').textContent));
          check(await page.isVisible('#btnRunPlan') && await page.isVisible('#alLevel'), `${label}: Settings > Nightly run & alerts has the nightly run and the alerts`);
        }
        if (sec === 'packaging') {
          // 2.38.60: the shared package and the packages folders each a part of their own, each said either way.
          await page.waitForFunction(() => document.getElementById('pkgOrphans').textContent.trim() !== '', null, { timeout: 8000 }).catch(() => {});
          const pk = await page.evaluate(() => ({ heads: [...document.querySelectorAll('#sec-packaging h3')].map(h => h.textContent), orph: document.getElementById('pkgOrphans').textContent, shared: document.getElementById('pkgShared').textContent }));
          check(pk.heads.join('|') === 'Shared Winget package|Packages folders' && pk.orph && pk.shared.includes('init.intunewin'), `${label}: Settings > Packaging - the shared package and the packages folders in parts of their own`, JSON.stringify(pk));
          await shot('settings-packaging');
        }
        check(await page.isVisible(`#sec-${sec}`) && !(await page.isVisible('#sec-connection')), `${label}: Settings > ${sec} shows only its own cards`);
        await noOverflow(`Settings ${sec}`); await unnamed(`Settings ${sec}`); await a11y(`Settings ${sec}`);
      }
      await page.click('#stab-diagnostics');
      await page.click('#btnDiag');
      await page.waitForSelector('#diagLog .h');
      check((await page.textContent('#diagLog')).includes('Skipped'), `${label}: Diagnostics skips Intune without a connection`);
      await noOverflow('Settings diagnostics'); await unnamed('Settings diagnostics'); await a11y('Settings diagnostics');
      // 2.38.34: Settings > About - the version, where it runs, the folders (desktop), updates and the project's pages.
      await page.click('#stab-about');
      await page.waitForFunction(() => /Version/.test(document.getElementById('aboutFacts').textContent));
      const about = await page.evaluate(() => ({ facts: document.getElementById('aboutFacts').textContent, folders: document.querySelectorAll('#aboutFolders dt').length, links: document.querySelectorAll('[data-about]').length }));
      check(/\d+\.\d+\.\d+/.test(about.facts) && /PowerShell/.test(about.facts) && about.folders >= 3 && about.links === 5, `${label}: Settings > About shows the version, PowerShell, the folders and the project links`, JSON.stringify(about));
      await noOverflow('Settings about'); await unnamed('Settings about'); await a11y('Settings about'); await shot('settings-about');
      await page.click('#stab-connection');

      if (size.width === 1440) {
        // Certificates on this machine (none on Linux - the dialog says so).
        // In the certificate menu beside the thumbprint.
        await page.click('#btnCertMenu'); await page.waitForSelector('#certMenu:not([hidden])');
        await page.click('#btnCertsLocal');
        await page.waitForSelector('#dlgCertsLocal[open]');
        await unnamed('the certificates dialog'); await a11y('the certificates dialog');
        await page.keyboard.press('Escape');
        // 2.38.10: export with its private key - a password of 12+ characters, typed twice; the server says why it can't.
        const thumbWas = await page.inputValue('#fThumb');
        await page.fill('#fThumb', 'AB'.repeat(20));
        await page.click('#btnCertMenu'); await page.waitForSelector('#certMenu:not([hidden])');
        await page.click('#btnPfxExport');
        await page.waitForSelector('#dlgPfxExport[open]');
        await a11y('the .pfx export dialog');
        await page.fill('#pfxExPw', 'short'); await page.fill('#pfxExPw2', 'short'); await page.click('#btnPfxExGo');
        check(/at least 12/.test(await page.textContent('#pfxExError')), `${label}: .pfx export refuses a short password`);
        await page.fill('#pfxExPw', 'a-long-enough-pw'); await page.fill('#pfxExPw2', 'a-long-enough-px'); await page.click('#btnPfxExGo');
        check(/differ/.test(await page.textContent('#pfxExError')), `${label}: .pfx export wants the password twice the same`);
        await page.fill('#pfxExPw2', 'a-long-enough-pw'); await page.click('#btnPfxExGo');
        await page.waitForFunction(() => /No certificate|Only the connection/.test(document.getElementById('pfxExError').textContent));
        check(await page.evaluate(() => document.getElementById('dlgPfxExport').open && !document.getElementById('pfxExPw').value), `${label}: .pfx export says why it can't (not the connection's certificate) and clears the passwords`);
        await page.keyboard.press('Escape');
        await page.fill('#fThumb', thumbWas);

        // An app added through the editor, then Batch edit and Add groups on it.
        await page.click('#tabApps');
        await page.evaluate(() => localStorage.setItem('addLastSrc', 'installer'));   // as after adding an installer
        await page.click('#btnAddApp');
        await page.waitForSelector('#dlgAdd[open]');
        check(await page.isVisible('#aiDrop') && await page.textContent('#btnAddGo') === 'Add installer', `${label}: Add apps opens on the kind added last time`);
        await page.evaluate(() => localStorage.removeItem('addLastSrc'));
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
        // 2.38.67: a Winget app has one control for it - Updates > Install with (no managed tick box beside it).
        await page.click('.edtab[data-i="1"]');
        await page.waitForSelector('#aMethodRow:not([hidden])', { timeout: 10000 });
        check(await page.evaluate(() => document.getElementById('aManagedRow').hidden && document.getElementById('aMethod').value === 'Managed' && !!document.getElementById('aVerRow').offsetParent), `${label}: Updates holds the version and one choice for how versions come (no managed tick box beside it)`);
        await page.selectOption('#aMethod', 'Winget');   // this one stays unmanaged: Release is checked below to be off, and to say why
        await page.waitForFunction(() => !document.getElementById('aManaged').checked, null, { timeout: 10000 });
        // Groups are chips: typed and Enter adds one, x takes it off again; return codes are rows.
        await page.click('.edtab[data-i="2"]');
        // A comma adds what's typed as it is (Enter takes a highlighted suggestion instead - when one comes up in time
        // depends on the machine, which made this step flaky); then wait for the chip, not a fixed time.
        await page.click('#gAvailableChips'); await page.keyboard.type('SG-ZZ-Chip'); await page.keyboard.press(',');
        await page.waitForSelector('#gAvailableBox .chip.tag .x', { timeout: 8000 }).catch(() => {});
        const chipAdded = (await page.inputValue('#gAvailable')).split('\n').includes('SG-ZZ-Chip');
        await page.click('#gAvailableBox .chip.tag .x');
        check(chipAdded && !(await page.inputValue('#gAvailable')).includes('SG-ZZ-Chip'), `${label}: a group is added as a chip and removed with its x`, await page.inputValue('#gAvailable'));
        // 2.38.73: Requirements on a part of its own - the fields show at once (no folded line with Change there).
        await page.click('.edtab[data-i="5"]');
        check(await page.evaluate(() => document.querySelectorAll('.edtab').length === 6 && !!document.getElementById('xTime').offsetParent && !!document.getElementById('xCodesRows').offsetParent && !document.querySelector('[data-sum="req"]').offsetParent), `${label}: the Requirements part shows its fields at once`);
        await page.click('.edtab[data-i="4"]');
        check(await page.evaluate(() => !document.getElementById('xType').offsetParent && /Made for winget/.test(document.querySelector('[data-sum="det"]').textContent) && !document.getElementById('xTime').offsetParent), `${label}: a winget app's detection shows as one line; the requirements are not on Install & detection`);
        await page.click('.edtab[data-i="5"]');
        await page.click('#xCodesRows > button');
        await page.fill('#xCodesRows .coderow:last-of-type input', '1707');
        check((await page.inputValue('#xCodes')).split('\n').includes('1707 = success'), `${label}: a return code is added as a row`, await page.inputValue('#xCodes'));
        await page.click('#btnSaveApp');
        await page.waitForSelector(`#gridBody tr[data-name="${testApp}"]`);
        check(!(await page.isVisible('#dlgApp[open]')), `${label}: the new app is saved and listed`);

        // 2.35.0: adding warns about a name already in the catalog; Add and send ends on a summary of what's ready.
        await page.click('#btnAddApp'); await page.waitForSelector('#dlgAdd[open]');
        await page.click('#atab-script');
        await page.waitForFunction(() => document.getElementById('asTemplate').options.length > 0);
        await page.fill('#asName', testApp);
        await page.waitForFunction(() => [...document.querySelectorAll('.namewarn')].some(x => x.offsetParent && /already an app called .* in the catalog/i.test(x.textContent)), null, { timeout: 5000 }).catch(() => {});
        check(await page.evaluate(() => [...document.querySelectorAll('.namewarn')].some(x => x.offsetParent && /already an app called .* in the catalog/i.test(x.textContent))), `${label}: Add apps warns that an app of that name is already in the catalog`);
        const sendApp = `ZZ UI Send ${label.replace(/\W+/g, '')} ${Date.now() % 100000}`;
        await page.fill('#asName', sendApp);
        // Not connected here: Add and send is there beside Add, off, and says why.
        check(await page.isVisible('#btnAddSend') && await page.isDisabled('#btnAddSend') && /connection/i.test(await page.getAttribute('#btnAddSend', 'title')), `${label}: Add and send is beside Add - off without a connection, saying so`);
        await page.click('#btnAddGo'); await page.waitForSelector(`#gridBody tr[data-name="${sendApp}"]`, { timeout: 20000 }).catch(() => {});
        check(await page.isVisible(`#gridBody tr[data-name="${sendApp}"]`), `${label}: a script app is added with Add`);
        // 2.36.0: the rest of Add and send - the summary, then Send - with Intune's answers stood in for here (sending
        // needs a connection and an upload to Intune): only the ready app is sent, with its groups; a warning shows, not blocks.
        await page.evaluate(([ready, notReady]) => {
          window.__realApi = api; window.__calls = [];
          api = async (path, body = {}) => {
            if (path === '/api/deploy-plan') return { ok: true, note: '', circular: [], apps: [
              { name: ready, ready: true, update: false, reason: '', deps: [], warnings: ['The App version is 1.0, the installer is 1.1.'] },
              { name: notReady, ready: false, update: false, reason: "No package (.intunewin) yet - build it with More > Package.", deps: [], warnings: [] }] };
            if (path === '/api/deploy-start') { window.__calls.push(body); return { ok: false, error: 'stood in for: not sent' }; }
            return window.__realApi(path, body);
          };
        }, [sendApp, testApp]);
        await page.evaluate(([a, b]) => showAddSummary([a, b]), [sendApp, testApp]);
        await page.waitForSelector('#dlgAddDone[open]', { timeout: 10000 }).catch(() => {});
        const sum = await page.evaluate(() => ({ text: document.getElementById('adDoneRows').textContent, send: document.getElementById('adDoneSend').textContent, off: document.getElementById('adDoneSend').disabled,
          buttons: [...document.querySelectorAll('#adDoneRows button')].map(b => b.textContent) }));
        check(/Ready - check/.test(sum.text) && /installer is 1\.1/.test(sum.text) && sum.buttons.includes('Build') && sum.send === 'Send the 1 ready' && !sum.off, `${label}: the summary - ready with a warning, Build for the one without a package, Send the 1 ready`, JSON.stringify(sum));
        await a11y('the Add and send summary'); await unnamed('the Add and send summary');
        await page.click('#adDoneSend');
        await page.waitForFunction(() => window.__calls.length > 0, null, { timeout: 15000 }).catch(() => {});
        const sent = await page.evaluate(() => window.__calls);
        check(sent.length === 1 && sent[0].name === sendApp && sent[0].sendGroups === true, `${label}: Send sends only the ready app, with its groups`, JSON.stringify(sent));
        await page.waitForFunction(() => /Failed/.test(document.getElementById('dlgDeploy').textContent), null, { timeout: 10000 }).catch(() => {});
        await page.evaluate(() => { api = window.__realApi; });
        await page.keyboard.press('Escape'); await page.waitForFunction(() => !document.getElementById('dlgDeploy').open, null, { timeout: 5000 }).catch(() => {});
        // 2.37.0: Updates > Get new installers - every watched app with a newer version on winget, fetched one after another
        // (winget and the download stood in for here), each with its next step.
        await page.evaluate(n => {
          window.__realApi = api; window.__fetched = [];
          api = async (path, body = {}) => {
            if (path === '/api/checks-winget') return { ok: true, areas: [], names: [], findings: [] };
            if (path === '/api/watch-fetch') { window.__fetched.push(body.name); return { ok: true, version: '9.9', file: 'Install.ps1', managed: false }; }
            const r = await window.__realApi(path, body);
            if (path === '/api/catalog' && r.ok) for (const a of r.apps) if (a.name === n) Object.assign(a, { watchWinget: 'ZZ.Watched', wingetVersion: '9.9', newerOnWinget: true });
            return r;
          };
        }, sendApp);
        await page.evaluate(() => document.getElementById('btnUpdWatched').click());
        await page.waitForSelector('#dlgWatched[open]', { timeout: 10000 }).catch(() => {});
        check(await page.evaluate(n => [...document.querySelectorAll('#wtRows tr')].some(r => r.textContent.includes(n) && /→ 9\.9/.test(r.textContent)), sendApp), `${label}: Get new installers lists each watched app with a newer version on winget`);
        await a11y('Get new installers'); await unnamed('Get new installers');
        await page.click('#wtGo');
        await page.waitForFunction(() => /9\.9 in its folder/.test(document.getElementById('wtRows').textContent), null, { timeout: 10000 }).catch(() => {});
        check(await page.evaluate(n => window.__fetched.includes(n) && [...document.querySelectorAll('#wtRows button')].some(b => b.textContent === 'Open'), sendApp), `${label}: ... gets each, then offers its next step`);
        await page.evaluate(() => { api = window.__realApi; document.getElementById('dlgWatched').close(); });
        await page.waitForFunction(() => !document.getElementById('dlgRun')?.open, null, { timeout: 20000 }).catch(() => {});
        // 2.38.56: Working... goes to where the running step writes - the Checks page with its log open, not the empty tray.
        const chipGo = await page.evaluate(() => {
          const was = jobLogId, chip = document.getElementById('jobChip'); jobLogId = 'checkLog'; chip.hidden = false;
          document.getElementById('checkLogBox').open = false; chip.click();
          const r = document.body.dataset.view === 'checks' && document.getElementById('checkLogBox').open && !document.getElementById('dlgRun').open;
          jobLogId = was; chip.hidden = true; showView('apps'); return r;
        });
        check(chipGo, `${label}: Working... shows the running step's own log (Checks), not the empty run tray`);
        // 2.38.62: Reload starts from nothing ticked.
        await page.click(`#gridBody tr[data-name="${testApp}"]`);
        const hadTick = await page.evaluate(() => selected.size);
        await page.click('#btnAppsReload');
        await page.waitForFunction(() => !document.getElementById('btnAppsReload').disabled, null, { timeout: 15000 }).catch(() => {});
        check(hadTick === 1 && await page.evaluate(() => selected.size === 0 && !document.querySelector('#gridBody input:checked')), `${label}: Reload unticks the ticked apps`, String(hadTick));
        // Duplicate app: a copy to start from, under a new name.
        await page.evaluate(() => { selected.clear(); renderApps(); });
        await page.click(`#gridBody tr[data-name="${testApp}"]`);
        await page.evaluate(n => api('/api/app-duplicate', { name: n, newName: n + ' (2)' }).then(() => loadApps()), testApp);
        check(await page.isVisible(`#gridBody tr[data-name="${testApp} (2)"]`), `${label}: Duplicate app makes a copy under a new name`);
        await page.evaluate(([a, b]) => Promise.all([api('/api/app-remove', { name: a + ' (2)' }), api('/api/app-remove', { name: b })]).then(() => loadApps()), [testApp, sendApp]);
        await page.click(`#gridBody tr[data-name="${testApp}"]`);
        await page.waitForSelector('#appPanel:not([hidden]) .pfacts');
        // 2.33.0: an app with no installer (one taken over from Intune) gets it uploaded right in the editor -
        // into its packages folder, the commands and detection rule filled in.
        const lobApp = `ZZ UI Installer ${label.replace(/\W+/g, '')}`, fakeSetup = join(tmpdir(), `zz-ui-setup-${Date.now()}.exe`);
        writeFileSync(fakeSetup, Buffer.concat([Buffer.from('MZ fake setup - Nullsoft Install System v3.09 '), Buffer.alloc(4000, 120)]));
        await page.evaluate(n => api('/api/app-save', { originalName: '', app: { appName: n, wingetId: '', appId: '', requiredFor: [], availableFor: [], uninstallFor: [], excludeFor: [] } }).then(() => loadApps()), lobApp);
        await page.dblclick(`#gridBody tr[data-name="${lobApp}"]`); await page.waitForSelector('#dlgApp[open] #btnAppInstaller');
        await page.setInputFiles('#aInstallerFile', fakeSetup);
        await page.waitForSelector('#dlgPkgUp[open]', { timeout: 20000 }); await page.click('#puGo');
        await page.waitForFunction(() => /zz-ui-setup-\d+\.exe" \/S/.test(document.getElementById('mInstallCommand').value) && document.getElementById('xType').value === 'Script', null, { timeout: 20000 });
        check(true, `${label}: an installer uploaded in the editor fills in the commands and the detection rule`);
        await page.keyboard.press('Escape'); await page.waitForFunction(() => !document.getElementById('dlgApp').open);
        // 2.36.0: an own package watches winget for new versions - the field is there for it (not for a Winget app).
        await page.dblclick(`#gridBody tr[data-name="${lobApp}"]`); await page.waitForSelector('#dlgApp[open]');
        check(await page.evaluate(() => !document.getElementById('aWatchRow').hidden && document.getElementById('aWingetRow').hidden && document.querySelector('.srcpick [data-src="own"]').getAttribute('aria-checked') === 'true'), `${label}: an own package can watch a winget package for new versions - and shows no Winget ID field (Installs from: its own installer)`);
        await page.keyboard.press('Escape'); await page.waitForFunction(() => !document.getElementById('dlgApp').open);
        await page.keyboard.press('Escape');
        await page.evaluate(n => api('/api/app-remove', { name: n }).then(() => loadApps()), lobApp); rmSync(fakeSetup, { force: true });
        // 2.38.21: Installs from > Microsoft 365 - its settings card, saved and shown as Microsoft 365 Apps in the list.
        const o365App = `ZZ UI Office ${label.replace(/\W+/g, '')}`;
        await page.evaluate(n => api('/api/app-save', { originalName: '', app: { appName: n, wingetId: '', appId: '', requiredFor: ['SG-ZZ-Office'], availableFor: [], uninstallFor: [], excludeFor: [] } }).then(() => loadApps()), o365App);
        await page.dblclick(`#gridBody tr[data-name="${o365App}"]`); await page.waitForSelector('#dlgApp[open]');
        await page.click('.srcpick [data-src="office"]');
        check(await page.evaluate(() => !document.getElementById('aOfficeBox').hidden && document.getElementById('aWingetRow').hidden && document.getElementById('oChannel').value === 'monthlyEnterprise' && document.querySelector('[data-oapp="word"]').checked && !document.querySelector('[data-oapp="lync"]').checked), `${label}: Installs from Microsoft 365 shows its settings, with the defaults`);
        await unnamed('the Microsoft 365 settings'); await a11y('the Microsoft 365 settings');
        check(await page.evaluate(() => !!document.querySelector('#appMenu [data-act="deploy"], [role="menu"] [data-act="deploy"]')), `${label}: the app menu has Send to Intune (2.38.22)`);
        check(await page.evaluate(() => document.querySelector('.edtab[data-i="4"]').hidden && document.querySelector('.edtab[data-i="5"]').hidden && document.querySelector('.edtab[data-i="1"]').hidden && getComputedStyle(document.getElementById('mAppVersion').closest('label')).display === 'none'), `${label}: Microsoft 365 Apps - no Install & detection tab and no App version (2.38.22)`); await page.$eval('#aOfficeBox', e => e.scrollIntoView({ block: 'center' })); await shot('editor-office');
        await page.selectOption('#oChannel', 'current'); await page.uncheck('[data-oapp="teams"]');
        await page.click('#btnSaveApp'); await page.waitForFunction(() => !document.getElementById('dlgApp').open, null, { timeout: 15000 });
        // The dialog closes before the list is read again - wait for the row as it is now.
        await page.waitForFunction(n => { const a = apps.find(x => x.name === n); return !!(a && a.office); }, o365App, { timeout: 15000 }).catch(() => {});
        const o365Row = await page.evaluate(n => { const a = apps.find(x => x.name === n); return a && { office: a.office, text: a.officeText, src: document.querySelector(`#gridBody tr[data-name="${n}"] td.src`)?.textContent }; }, o365App);
        check(!!(o365Row && o365Row.office && o365Row.office.channel === 'current' && o365Row.office.excluded.includes('teams') && o365Row.src === 'Microsoft 365 Apps'), `${label}: Microsoft 365 Apps saved with its settings and shown as such in the list`, JSON.stringify(o365Row));
        await page.evaluate(n => api('/api/app-remove', { name: n }).then(() => loadApps()), o365App);
        // 2.38.24: Add apps > Microsoft 365 - the tab and its usual settings, ready to add.
        await page.evaluate(() => openAdd('office')); await page.waitForSelector('#dlgAdd[open] #asec-office:not([hidden])');
        check(await page.evaluate(() => document.getElementById('aoChannel').value === 'monthlyEnterprise' && document.querySelector('[data-aoapp="word"]').checked && !document.querySelector('[data-aoapp="visio"]').checked && !document.getElementById('btnAddGo').disabled), `${label}: Add apps > Microsoft 365 starts with the usual settings, ready to add`);
        await unnamed('Add apps > Microsoft 365'); await a11y('Add apps > Microsoft 365'); await shot('add-office');
        await page.keyboard.press('Escape'); await page.waitForFunction(() => !document.getElementById('dlgAdd').open);
        // 2.34.0: a whole folder for an app - reviewed (the setup file in a subfolder suggested), all of it in its
        // packages folder, listed file by file; a file deleted from the list.
        const folderApp = `ZZ UI Folder ${label.replace(/\W+/g, '')}`, dir = mkdtempSync(join(tmpdir(), 'zz-ui-folder-'));
        mkdirSync(join(dir, 'Setup')); writeFileSync(join(dir, 'Setup', 'zz-folder-setup.exe'), Buffer.concat([Buffer.from('MZ fake setup - Nullsoft Install System v3.09 '), Buffer.alloc(4000, 120)]));
        writeFileSync(join(dir, 'Setup', 'config.xml'), '<cfg/>'); writeFileSync(join(dir, 'readme.txt'), 'hi');
        await page.evaluate(n => api('/api/app-save', { originalName: '', app: { appName: n, wingetId: '', appId: '', requiredFor: [], availableFor: [], uninstallFor: [], excludeFor: [] } }).then(() => loadApps()), folderApp);
        await page.dblclick(`#gridBody tr[data-name="${folderApp}"]`); await page.waitForSelector('#dlgApp[open] #btnAppFolder');
        await page.setInputFiles('#aInstallerFolder', dir);
        await page.waitForSelector('#dlgPkgUp[open]', { timeout: 20000 });
        check(await page.inputValue('#puSetup') === 'Setup\\zz-folder-setup.exe' && /3 files/.test(await page.textContent('#puFacts')), `${label}: a folder upload is reviewed - its files counted, the setup file in its subfolder suggested`, await page.textContent('#puFacts'));
        await unnamed('the folder upload review'); await a11y('the folder upload review');
        await page.click('#puGo');
        await page.waitForFunction(() => /Setup\\zz-folder-setup\.exe" \/S/.test(document.getElementById('mInstallCommand').value), null, { timeout: 20000 });
        await page.waitForSelector('#aPkgInfo .pkgfiles'); await page.click('#aPkgInfo .pkgfiles summary');
        const listed = await page.$$eval('#aPkgInfo .pkgfiles .pfpath', els => els.map(e => e.textContent));
        check(['readme.txt', 'Setup\\config.xml', 'Setup\\zz-folder-setup.exe'].every(f => listed.includes(f)), `${label}: the folder's files are in its packages folder, listed`, listed.join(', '));
        await page.click('#aPkgInfo .pkgfiles button[aria-label="Delete readme.txt"]'); await page.click('#askOk');
        await page.waitForFunction(() => ![...document.querySelectorAll('#aPkgInfo .pkgfiles .pfpath')].some(e => e.textContent === 'readme.txt'), null, { timeout: 10000 });
        check(true, `${label}: a file is deleted from the packages folder in the list`);
        await page.keyboard.press('Escape'); await page.waitForFunction(() => !document.getElementById('dlgApp').open);
        await page.evaluate(n => api('/api/app-remove', { name: n }).then(() => loadApps()), folderApp); rmSync(dir, { recursive: true, force: true });
        await page.click(`#gridBody tr[data-name="${testApp}"]`); await page.waitForSelector('#appPanel:not([hidden]) .pfacts');

        // 2.32.2: the side panel's More... opens the actions menu (the same click used to close it again at once).
        await page.click('#appPanel .pacts button:has-text("More ▾")');
        check(await page.isVisible('#appMenu'), `${label}: the side panel's More... opens the actions menu`);
        await page.keyboard.press('Escape');
        // Without groups (the chip above was taken off again) its stage says so: "Ready - no groups" (no button - Who gets it is in the editor).
        check(/Ready to send|Ready - no groups|Draft/.test(await page.textContent(`#gridBody tr[data-name="${testApp}"]`)) && (await page.isVisible('#btnNext') || await page.isEnabled('#btnDeploy')), `${label}: a new app shows its stage and the next step (in the row and on the toolbar)`, await page.textContent(`#gridBody tr[data-name="${testApp}"]`));
        await noOverflow('Apps with the side panel'); await unnamed('Apps with the side panel'); await a11y('Apps with the side panel');
        await page.click('#btnMore');
        const relTip = await page.getAttribute('[data-act="release"]', 'title');
        check(await page.isDisabled('[data-act="release"]') && /managed updates on/i.test(relTip || ''), `${label}: Release new version is off for an app without managed updates, and says why`, relTip);
        // 2.37.0: what can never apply to a Winget app isn't listed (an own installer's actions); what can be, is.
        check(await page.evaluate(() => { const v = a => !document.querySelector(`#appMenu [data-act="${a}"]`).hidden;
          return !v('watchfetch') && !v('package') && !v('promote') && v('takeversion') && v('release') && !document.querySelector('#appMenu [data-act="filldetails"]').disabled; }),
          `${label}: the menu leaves out what can't apply to a Winget app; Fill in details from winget works`);
        await page.keyboard.press('Escape');
        // 2.38.0: Escape gives focus back to what opened the menu; the arrow keys skip what it hides.
        check(await page.evaluate(() => document.getElementById('appMenu').hidden && document.activeElement && document.activeElement.id === 'btnMore'), `${label}: Escape on the More menu puts focus back on More`);
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
        // 2.38.56: other groups as chips, with the group picker's suggestions (favourites, the catalog's, Entra ID's).
        check(await page.evaluate(() => document.getElementById('gbxrequiredForChips')?.getAttribute('aria-controls') === 'gpList'), `${label}: Add groups suggests group names as they are typed`);
        await page.fill('#gbxrequiredForChips', 'SG-ZZ-UI');
        await page.uncheck('#gbPush');
        await page.click('#btnGbGo');
        await page.waitForFunction(() => !document.getElementById('dlgGroupsBatch').open);

        await page.dblclick(`#gridBody tr[data-name="${testApp}"]`);
        await page.waitForSelector('#dlgApp[open]');
        await page.waitForFunction(() => document.getElementById('aName').value !== '');
        check(await page.inputValue('#mOwner') === 'ZZ Owner', `${label}: Batch edit saved the owner`, await page.inputValue('#mOwner'));
        check((await page.inputValue('#gRequired')).split('\n').includes('SG-ZZ-UI'), `${label}: Add groups saved the group`, await page.inputValue('#gRequired'));
        // Blocks (2.26): the winget commands as locked and editable blocks; an option added there lands in the command.
        await page.click('.edtab[data-i="4"]');
        await page.waitForSelector('#instBlocks:not([hidden]) .brec', { timeout: 8000 });
        check(await page.evaluate(() => document.getElementById('mInstallCommand').readOnly && document.querySelectorAll('#instBlocks .blk.lock').length >= 3), `${label}: the commands show as blocks, the text read-only`);
        // 2.38.73: the fixed parts always show (greyed), under Install and Uninstall headings; the raw commands stay folded.
        check(await page.evaluate(() => !document.getElementById('instRaw').open && [...document.querySelectorAll('#instBlocks .blk.lock')].every(b => !!b.offsetParent) && !document.querySelector('#instBlocks .bfixed')
          && [...document.querySelectorAll('#instBlocks .bsec')].map(h => h.textContent).join(',') === 'Install,Uninstall'), `${label}: every part of the commands shows, under Install and Uninstall; the raw commands are folded`);
        await unnamed('the blocks'); await shot('blocks');
        await page.selectOption('#instBlocks select.badd', '--override');
        await page.fill('#instBlocks input[aria-label="--override value"]', '/S');
        await page.press('#instBlocks input[aria-label="--override value"]', 'Tab');
        await page.waitForFunction(() => /--override '\/S'/.test(document.getElementById('mInstallCommand').value), null, { timeout: 8000 });
        check(true, `${label}: an option added as a block is written into the install command`);
        await page.click('#instBlocks .bx[aria-label="Remove --override"]');
        await page.waitForFunction(() => !/--override/.test(document.getElementById('mInstallCommand').value), null, { timeout: 8000 });
        // 2.29.3: a linked part is changed in its row - it writes into its own field (Install for), the command follows.
        await page.selectOption('#instBlocks select[data-bid="context"]', 'User');
        await page.waitForFunction(() => document.getElementById('xContext').value === 'User' && !/--scope machine/.test(document.getElementById('mInstallCommand').value), null, { timeout: 8000 });
        check(true, `${label}: Install for is changed in its row - the field and the command follow`);
        await page.selectOption('#instBlocks select[data-bid="context"]', 'System');
        await page.waitForFunction(() => document.getElementById('xContext').value === 'System' && /--scope machine/.test(document.getElementById('mInstallCommand').value), null, { timeout: 8000 });
        // 2.32.1: a new Winget ID in its row writes the generated commands again for it (they were for the old one).
        await page.fill('#instBlocks input[data-bid="wingetId"]', 'Vendor.ZZUiTestTwo'); await page.press('#instBlocks input[data-bid="wingetId"]', 'Tab');
        await page.waitForFunction(() => /--id 'Vendor\.ZZUiTestTwo'/.test(document.getElementById('mInstallCommand').value) && /--id 'Vendor\.ZZUiTestTwo'/.test(document.getElementById('mUninstallCommand').value), null, { timeout: 8000 });
        check(await page.inputValue('#aWinget') === 'Vendor.ZZUiTestTwo', `${label}: a new Winget ID in its row - the field and both commands follow`);
        await page.fill('#instBlocks input[data-bid="wingetId"]', 'Vendor.ZZUiTest'); await page.press('#instBlocks input[data-bid="wingetId"]', 'Tab');
        await page.waitForFunction(() => /--id 'Vendor\.ZZUiTest'/.test(document.getElementById('mInstallCommand').value), null, { timeout: 8000 });
        await page.keyboard.press('Escape');
        // Written back from the blocks, the commands are in today's form - the editor asks before it drops that.
        if (await page.isVisible('#dlgAsk[open]').catch(() => false) || await page.waitForSelector('#dlgAsk[open]', { timeout: 1500 }).then(() => true, () => false)) await page.click('#askOk');
        await page.waitForFunction(() => !document.getElementById('dlgApp').open);

        // Undo the last bulk change (Add groups): the group is gone again, the owner from Batch edit stays.
        // Recent changes: the dot says a bulk change can be undone; the panel lists it and takes it back.
        await page.waitForSelector('#recentDot:not([hidden])');
        await page.click('#btnRecent');
        await page.waitForSelector('#recentUndo:not([hidden])');
        check(/Add groups/.test(await page.textContent('#recentUndo')), `${label}: Recent changes names the last bulk change`, await page.textContent('#recentUndo'));
        check(/SG-ZZ-UI/.test(await page.textContent('#recentList')) || (await page.locator('#recentList > li').count()) > 0, `${label}: Recent changes lists the changes`);
        await a11y('Recent changes');
        await page.click('#recentUndo .btn');
        await page.waitForSelector('#dlgAsk[open]');
        await page.click('#askOk');
        await page.waitForSelector('#recentDot', { state: 'hidden' });
        await page.keyboard.press('Escape');
        await page.waitForFunction(() => !document.getElementById('dlgRecent').open);
        await page.dblclick(`#gridBody tr[data-name="${testApp}"]`);
        await page.waitForSelector('#dlgApp[open]');
        await page.waitForFunction(() => document.getElementById('aName').value !== '');
        check(!(await page.inputValue('#gRequired')).split('\n').includes('SG-ZZ-UI') && await page.inputValue('#mOwner') === 'ZZ Owner', `${label}: Undo took Add groups back and kept Batch edit`, await page.inputValue('#gRequired'));
        // 2.38.67: Remove from catalog is under the footer's More menu.
        await page.click('#btnAppMore'); await page.click('#btnRemoveApp');
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
  await new Promise(r => setTimeout(r, 1500));   // let the server let go of its files
  for (const d of leftovers) { try { rmSync(d, { recursive: true, force: true }); } catch (e) { console.log(`Note: could not remove ${d}: ${e.message}`); } }
}

console.log('');
if (failures.length === 0) { console.log(`PASSED: ${passed} check(s).`); process.exit(0); }
console.log(`FAILED: ${failures.length} of ${passed + failures.length}.`);
process.exit(1);
