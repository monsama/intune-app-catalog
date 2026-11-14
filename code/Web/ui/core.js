// Intune App Catalog - web interface: shared helpers, liveness, theme, views and state.
// Talks only to the local server it was loaded from (/api/*, JSON POST, with
// the token from the URL's #fragment). No inline script: the page's CSP
// allows script from these files only.
// The page's script is split per page (apps, checks, groups, scripts,
// settings); index.html loads them in order and app.js, last, starts it.
'use strict';

const $ = id => document.getElementById(id);
// The app's own question dialog, in place of the browser's confirm() and
// prompt() - those carry the page's address as their title, look like an
// error, and the browser may start suppressing them. The first paragraph of
// the text is the heading. The button says what happens (taken from the
// question's first word unless -ok is given); a destructive question gets a
// red button, and Cancel has the focus.
function ask(text, { ok = '', danger = null, input = null } = {}) {
  const [head, ...rest] = String(text).split('\n\n');
  const first = (head.match(/^\w+/) || [''])[0];
  const verb = first === 'Permanently' ? 'Delete' : first;
  const isDanger = danger === null ? /^(Delete|Permanently|Remove)$/.test(first) : danger;
  const dlg = $('dlgAsk'), okBtn = $('askOk'), field = $('askInput');
  $('askTitle').textContent = head;
  $('askText').textContent = rest.join('\n\n');
  $('askText').hidden = rest.length === 0;
  okBtn.textContent = ok || (/^(Remove|Delete|Clear|Add|Send|Rename|Create)$/.test(verb) ? verb : 'OK');
  okBtn.classList.toggle('dangerous', isDanger);
  field.hidden = input === null;
  field.value = input === null ? '' : input;
  return new Promise(resolve => {
    const done = v => { dlg.removeEventListener('close', onClose); okBtn.onclick = null; $('askCancel').onclick = null; field.onkeydown = null; if (dlg.open) dlg.close(); resolve(v); };
    const onClose = () => done(input === null ? false : null);
    dlg.addEventListener('close', onClose);
    okBtn.onclick = () => done(input === null ? true : field.value);
    $('askCancel').onclick = () => done(input === null ? false : null);
    field.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); okBtn.click(); } };
    dlg.showModal();
    (input !== null ? field : isDanger ? $('askCancel') : okBtn).focus();
    if (input !== null) field.select();
  });
}
// Asks for a line of text: the text, or null when cancelled.
const askText = (text, value = '', ok = '') => ask(text, { input: value, ok, danger: false });

// Buy me a coffee: in the person's own browser, not the app window.
$('btnCoffee').addEventListener('click', async () => { const r = await api('/api/open', { target: 'coffee' }); if (!r.ok) toast(r.error || 'Could not open the browser.', true); });

// Opens one of the app's folders in Explorer and says so - or why not.
async function openFolder(target) {
  const r = await api('/api/open', { target });
  toast(r.ok ? (r.path ? `Opened ${r.path} in Explorer.` : 'Opened.') : (r.error || 'Could not open the folder.'), !r.ok);
}

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
    // "deployed": the apps an answer offers to push to. One whose App ID the
    // connected tenant doesn't have (a copied catalog) would only fail there.
    if (j && Array.isArray(j.deployed) && typeof tenantState === 'function') j.deployed = j.deployed.filter(n => { const a = apps.find(x => x.name === n); return !a || tenantState(a) !== 'missing'; });
    return j;
  } catch (e) {
    return { ok: false, error: 'The app\'s server did not answer (' + e.message + ').' };
  }
}

function el(tag, attrs = {}, ...kids) {
  const n = document.createElement(tag);
  // No browser autofill or password suggestions in the app's own fields.
  // ... and no spelling correction or capitalisation: IDs, group names and commands must stay exactly as typed.
  if (tag === 'input' || tag === 'textarea') {
    for (const [k, v] of [['autocomplete', 'off'], ['spellcheck', 'false'], ['autocorrect', 'off'], ['autocapitalize', 'off']]) if (!(k in attrs)) n.setAttribute(k, v);
  }
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
// -actions: the next steps as buttons in the message, e.g. [{ label: 'Deploy', run: () => ... }] - it then stays longer.
function toast(msg, isErr, actions) {
  activity(`${stamp()} ${isErr ? '[FAILED] ' : ''}${msg}`);
  const t = $('toast');
  const acts = (actions || []).filter(Boolean);
  t.replaceChildren(el('span', { text: msg }), ...acts.map(a => el('button', { class: 'btn small', text: a.label, onclick: () => { t.hidden = true; a.run(); } })));
  t.className = 'toast' + (isErr ? ' err' : '') + (acts.length ? ' withacts' : ''); t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, acts.length ? 12000 : isErr ? 8000 : 4000);
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
  $('viewHome').hidden = v !== 'home';
  if (v === 'home') loadHome();
  $('viewApps').hidden = v !== 'apps';
  $('viewChecks').hidden = v !== 'checks';
  $('viewUpdates').hidden = v !== 'updates';
  if (v === 'updates') loadUpdates(false);
  $('viewScripts').hidden = v !== 'scripts';
  $('viewGroups').hidden = v !== 'groups';
  if (v === 'groups' && !groupsLoaded) loadGroups();
  if (v === 'scripts' && !scriptsLoaded) loadScripts();
  $('viewSettings').hidden = v !== 'settings';
  if (v === 'settings') showSettings();
  try { localStorage.setItem('view', v); } catch (e) { }
}
// Settings has four sections: Connection, Defaults, Packaging & folders, Diagnostics. -sec: one of them, or the last one shown.
let settingsSec = (() => { try { return localStorage.getItem('settingsSec') || 'connection'; } catch (e) { return 'connection'; } })();
function showSettings(sec) {
  if (sec) settingsSec = sec;
  if (!$('sec-' + settingsSec)) settingsSec = 'connection';
  if (!$('viewSettings').hidden || sec) showViewOnly('settings');
  for (const b of document.querySelectorAll('.subtab[data-sec]')) { const on = b.dataset.sec === settingsSec; b.setAttribute('aria-selected', String(on)); b.tabIndex = on ? 0 : -1; }
  for (const p of document.querySelectorAll('.setsec')) p.hidden = p.dataset.sec !== settingsSec;
  if (settingsSec === 'automation' && typeof loadUpdateRuns === 'function') loadUpdateRuns();
  try { localStorage.setItem('settingsSec', settingsSec); } catch (e) { }
}
// Switches to the Settings tab without going through showView again.
function showViewOnly(v) { if ($('viewSettings').hidden) showView(v); }
for (const b of document.querySelectorAll('.subtab[data-sec]')) b.addEventListener('click', () => showSettings(b.dataset.sec));
document.querySelector('.subtabs').addEventListener('keydown', e => {
  if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
  const tabs = [...document.querySelectorAll('.subtab[data-sec]')], i = tabs.findIndex(t => t.dataset.sec === settingsSec);
  const next = tabs[(i + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length];
  showSettings(next.dataset.sec); next.focus();
});
for (const b of document.querySelectorAll('.tab')) b.addEventListener('click', () => showView(b.dataset.view));
$('bannerSettings').addEventListener('click', () => { showSettings('connection'); $('guideReg').open = true; $('guideCard').scrollIntoView({ block: 'start' }); });

// ---------------------------------------------------------------- state
let state = null;
// The badge at the top says whether the connection really works: one small
// read from Intune when the app opens and after Save; Test connection sets it too.
function setBadge(state, text, detail) {
  const b = $('connBadge');
  b.className = 'conn ' + state; b.textContent = text;
  b.title = (detail ? detail + '\n' : '') + 'Click for Settings > Connection.';
  b.setAttribute('aria-label', text + (detail ? ' - ' + detail : ''));
}
async function checkConnection() {
  setBadge('busy', 'Checking connection...', 'Reading one app from Intune with the saved settings.');
  const r = await api('/api/connection-status');
  if (!r.ok) { setBadge('error', 'Connection problem', r.error || ''); return; }
  setBadge(r.state === 'none' ? 'none' : r.state, r.text, r.detail);
}
$('connBadge').addEventListener('click', () => { showSettings('connection'); $('fTenant').closest('.card').scrollIntoView({ block: 'start' }); $('btnTest').focus(); });

async function loadState() {
  const r = await api('/api/state');
  if (!r.ok) { toast(r.error || 'Could not read the app state.', true); return; }
  state = r;
  $('ver').textContent = 'v' + r.version;
  document.title = 'Intune App Catalog ' + r.version;
  if (r.testMode) setBadge('warn', 'TEST MODE', 'Graph answers come from a test file, not from a tenant. Started with INTUNE_CATALOG_TEST_GRAPH set - restart the app without it.');
  else if (!r.configured) setBadge('none', 'Not connected', 'Fill in the connection in Settings - until then nothing is read from or sent to Intune.');
  else checkConnection();
  $('setupBanner').hidden = r.configured;
  $('testBanner').hidden = !r.testMode;
  setFields(r.settings);
  setCertStatus(r.cert);
}
