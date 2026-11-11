// Intune App Catalog & Deployment
// Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The web interface in a real browser, against the real server: starts
// IntuneDeployment.ps1 -NoBrowser, opens every page in Chromium and checks
// what a person would notice first - errors in the page, requests that fail,
// buttons without a name, a page wider than the window, dialogs that open
// and close. No tenant: the app runs unconfigured, the way it starts the
// first time.
//
//   npm install --no-save playwright@1.48.2 && npx playwright install chromium
//   node code/tests/ui/WebUi.Tests.mjs [--shots <folder>]
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const shotsArg = process.argv.indexOf('--shots');
const shots = shotsArg > 0 ? resolve(process.argv[shotsArg + 1]) : null;
if (shots) mkdirSync(shots, { recursive: true });
const pwsh = process.platform === 'win32' ? 'pwsh.exe' : 'pwsh';

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

const browser = await chromium.launch();
try {
  for (const theme of ['light', 'dark']) {
    for (const size of [{ width: 1440, height: 900 }, { width: 820, height: 900 }]) {
      const label = `${theme} ${size.width}px`;
      const ctx = await browser.newContext({ viewport: size, colorScheme: theme });
      const page = await ctx.newPage();
      const errors = [];
      page.on('pageerror', e => errors.push('page: ' + e.message));
      page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
      page.on('response', r => { if (r.status() >= 400) errors.push(`HTTP ${r.status()} ${r.url().replace(/#.*/, '')}`); });
      await page.addInitScript(t => { try { localStorage.setItem('theme', t); localStorage.setItem('view', 'apps'); } catch (e) { } }, theme);
      await page.goto(url);
      await page.waitForFunction(() => document.getElementById('ver').textContent.startsWith('v'));

      const shot = async name => { if (shots) await page.screenshot({ path: join(shots, `${name}-${theme}-${size.width}.png`), fullPage: false }); };
      const noOverflow = async view => {
        const w = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
        check(w[0] <= w[1] + 1, `${label}: ${view} fits the window (no sideways scrolling)`, `${w[0]} > ${w[1]}`);
      };
      const unnamed = async view => {
        const bad = await page.evaluate(() => [...document.querySelectorAll('button, [role=menuitem]')]
          .filter(b => b.offsetParent !== null && !(b.textContent.trim() || b.getAttribute('aria-label') || b.title)).map(b => b.id || b.outerHTML.slice(0, 60)));
        check(bad.length === 0, `${label}: ${view} has no button without a name`, bad.join(', '));
      };

      // Apps: an unconfigured app opens on Settings; the Apps list is empty but explained.
      await page.click('#tabApps');
      await page.waitForSelector('#emptyState:not([hidden]), #gridBody tr');
      check(await page.isVisible('#setupBanner'), `${label}: the "no connection" banner shows`);
      await noOverflow('Apps'); await unnamed('Apps'); await shot('apps');

      await page.click('#btnAddApp');
      await page.waitForSelector('#dlgApp[open]');
      await page.click('#deploySec summary');
      await unnamed('the app editor'); await shot('editor');
      await page.click('#btnSaveApp');
      check(await page.isVisible('#appError'), `${label}: saving an app without a name says why`);
      await page.keyboard.press('Escape');
      check(!(await page.isVisible('#dlgApp[open]')), `${label}: Escape closes the editor`);

      // Checks: runs, and says Intune wasn't checked.
      await page.click('#tabChecks');
      await page.click('#btnRunChecks');
      await page.waitForFunction(() => document.getElementById('btnRunChecks').textContent === 'Run checks');
      check(/not checked/i.test(await page.textContent('#checkNotes')), `${label}: Checks says Intune wasn't checked`, await page.textContent('#checkNotes'));
      await noOverflow('Checks'); await unnamed('Checks'); await shot('checks');

      // Groups and Platform scripts: empty, explained.
      await page.click('#tabGroups');
      await page.waitForSelector('#groupList li');
      await noOverflow('Groups'); await unnamed('Groups'); await shot('groups');
      await page.click('#tabScripts');
      await page.waitForFunction(() => !/Reading/.test(document.getElementById('scriptNote').textContent));
      check(/Not connected/i.test(await page.textContent('#scriptNote')), `${label}: Platform scripts says only local copies are shown`);
      await noOverflow('Platform scripts'); await unnamed('Platform scripts'); await shot('scripts');

      // Settings: diagnostics, prerequisites, the guide.
      await page.click('#tabSettings');
      await page.click('#guideReg summary');
      await page.click('#btnDiag');
      await page.waitForSelector('#diagLog .h');
      check((await page.textContent('#diagLog')).includes('Skipped'), `${label}: Diagnostics skips Intune without a connection`);
      await noOverflow('Settings'); await unnamed('Settings'); await shot('settings');

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
