// Intune App Catalog - web interface: shared helpers, liveness, theme, views and state.
// Talks only to the local server it was loaded from (/api/*, JSON POST, with
// the token from the URL's #fragment). No inline script: the page's CSP
// allows script from these files only.
// The page's script is split per page (apps, checks, groups, scripts,
// settings); index.html loads them in order and app.js, last, starts it.
'use strict';

const $ = id => document.getElementById(id);
// Enables or disables a button; disabled, its tooltip says why first, then
// what it does. The usual tooltip is kept in data-tip.
function setEnabled(b, on, why) {
  if (b.dataset.tip === undefined) b.dataset.tip = b.title || '';
  b.disabled = !on;
  b.title = on || !why ? b.dataset.tip : why + (b.dataset.tip ? '\n' + b.dataset.tip : '');
}
const TOKEN = (() => {
  let t = '';
  try {
    const m = /[#&]t=([0-9a-f]{32})/.exec(location.hash || '');
    if (m) { t = m[1]; sessionStorage.setItem('iacTok', t); history.replaceState(null, '', location.pathname + location.search); }
    else t = sessionStorage.getItem('iacTok') || '';
  } catch (e) { /* storage blocked: the token only lives for this page */ }
  return t;
})();

async function api(path, body = {}) {
  try {
    const r = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...body, token: TOKEN }) });
    const j = await r.json();
    if (j && j.error === 'bad token') showDead();
    return j;
  } catch (e) {
    return { ok: false, error: 'The app\'s server did not answer (' + e.message + ').' };
  }
}

function el(tag, attrs = {}, ...kids) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') n.className = v;
    else if (k === 'text') n.textContent = v;
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) n.setAttribute(k, v === true ? '' : v);
  }
  for (const k of kids.flat()) if (k != null) n.append(k.nodeType ? k : document.createTextNode(String(k)));
  return n;
}

// The Activity box: everything that happens - the server's own log lines,
// each Entra action's output, and every message the page shows - in one place.
let activityFresh = true;
function activity(text) {
  const log = $('jobLog');
  if (!log) return;
  if (activityFresh) { log.textContent = ''; activityFresh = false; }
  log.textContent += text.endsWith('\n') ? text : text + '\n';
  log.scrollTop = log.scrollHeight;
}
const stamp = () => new Date().toTimeString().slice(0, 8);

let toastTimer = null;
function toast(msg, isErr) {
  activity(`${stamp()} ${isErr ? '[FAILED] ' : ''}${msg}`);
  const t = $('toast');
  t.textContent = msg; t.className = 'toast' + (isErr ? ' err' : ''); t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, isErr ? 8000 : 4000);
}

// ---------------------------------------------------------------- liveness
let pingFails = 0;
function showDead() { $('deadNote').hidden = false; }
setInterval(async () => {
  const r = await api('/api/ping');
  if (r && r.ok) pingFails = 0; else if (++pingFails >= 2) showDead();
}, 5000);

let logNext = 0;
async function pollServerLog() {
  const r = await api('/api/log', { from: logNext });
  if (r && r.ok) {
    for (const l of r.lines || []) activity(`${l.Time} ${l.Text}`);
    logNext = r.next;
  }
}
setInterval(pollServerLog, 2000);

// ---------------------------------------------------------------- theme
function applyTheme(t) { document.documentElement.dataset.theme = t; $('btnTheme').textContent = t === 'dark' ? 'Light mode' : 'Dark mode'; }
(function initTheme() {
  let t = null;
  try { t = localStorage.getItem('theme'); } catch (e) { }
  if (!t) t = matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  applyTheme(t);
})();
$('btnTheme').addEventListener('click', () => {
  const t = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  applyTheme(t); try { localStorage.setItem('theme', t); } catch (e) { }
});

// ---------------------------------------------------------------- views
function showView(v) {
  if (v === 'checks') delete $('tabChecks').dataset.count;
  for (const b of document.querySelectorAll('.tab')) b.setAttribute('aria-selected', String(b.dataset.view === v));
  $('viewApps').hidden = v !== 'apps';
  $('viewChecks').hidden = v !== 'checks';
  $('viewScripts').hidden = v !== 'scripts';
  $('viewGroups').hidden = v !== 'groups';
  if (v === 'groups' && !groupsLoaded) loadGroups();
  if (v === 'scripts' && !scriptsLoaded) loadScripts();
  $('viewSettings').hidden = v !== 'settings';
  try { localStorage.setItem('view', v); } catch (e) { }
}
for (const b of document.querySelectorAll('.tab')) b.addEventListener('click', () => showView(b.dataset.view));
$('bannerSettings').addEventListener('click', () => { showView('settings'); $('guideReg').open = true; $('guideCard').scrollIntoView({ block: 'start' }); });

// ---------------------------------------------------------------- state
let state = null;
async function loadState() {
  const r = await api('/api/state');
  if (!r.ok) { toast(r.error || 'Could not read the app state.', true); return; }
  state = r;
  $('ver').textContent = 'v' + r.version;
  document.title = 'Intune App Catalog ' + r.version;
  const badge = $('connBadge');
  badge.textContent = r.testMode ? 'TEST MODE' : r.configured ? 'Connection set up' : 'Not connected';
  badge.className = 'conn ' + (r.testMode ? 'warn' : r.configured ? 'ok' : 'warn');
  if (r.testMode) badge.title = 'Graph answers come from a test file, not from a tenant. Started with INTUNE_CATALOG_TEST_GRAPH set - restart the app without it.';
  else badge.title = r.configured ? 'Tenant ID, Client ID and certificate are filled in - Settings > Test connection checks that they work.' : 'Fill in the connection in Settings - until then nothing is read from or sent to Intune.';
  $('setupBanner').hidden = r.configured;
  $('testBanner').hidden = !r.testMode;
  setFields(r.settings);
  setCertStatus(r.cert);
}
