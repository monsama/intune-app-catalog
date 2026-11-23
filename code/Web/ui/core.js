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

// The server version (the container) has a sign-in; the desktop app's page gets its token from the app window.
let SERVER = false, signingOut = false;
function goSignIn(why) {
  if (signingOut) return; signingOut = true;
  try { sessionStorage.removeItem('iacTok'); } catch (e) { }
  location.replace('login.html' + (why ? '?why=' + encodeURIComponent(why) : ''));
}
(async () => {
  try {
    const h = await (await fetch('/api/hello', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })).json();
    if (!h || !h.server) return;
    SERVER = true; document.documentElement.classList.add('servermode');
    if (!TOKEN) { goSignIn(''); return; }
    // Sign out: top right, next to coffee and theme.
    const b = document.createElement('button');
    b.className = 'btn ghost iconbtn'; b.id = 'btnSignOut'; b.title = 'Sign out'; b.setAttribute('aria-label', 'Sign out');
    b.innerHTML = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="M16 17l5-5-5-5"/><path d="M21 12H9"/></svg>';
    b.addEventListener('click', async () => { await api('/api/logout'); goSignIn('signedout'); });
    api('/api/signin-settings').then(r => { if (r && r.ok && r.signedInAs) b.title = `Sign out ${r.signedInAs}${r.upn ? ` (${r.upn})` : ''}`; });
    const bar = document.getElementById('pageBtns'); if (bar) bar.append(b);
    // Words for the server: "this machine" is the server here (data-server-text/-title/-placeholder/-empty).
    for (const [attr, set] of [['serverText', (n, v) => { n.textContent = v; }], ['serverTitle', (n, v) => { n.title = v; }], ['serverPlaceholder', (n, v) => { n.placeholder = v; }], ['serverEmpty', (n, v) => { n.dataset.empty = v; }]])
      for (const n of document.querySelectorAll(`[data-${attr.replace(/[A-Z]/g, c => '-' + c.toLowerCase())}]`)) set(n, n.dataset[attr]);
    // What a Windows PC does comes as a download here (PC helpers).
    // Anything drawn before this answer came (the setup guide, from /api/state) is drawn again for the server.
    if (typeof renderSetupSteps === 'function') renderSetupSteps();
    for (const m of document.querySelectorAll('[data-act="sandbox"]')) { m.textContent = 'Download a Sandbox test...'; m.title = 'A zip for a Windows PC with Windows Sandbox: the package, the test and a starter that opens the Sandbox and says how it went'; }
  } catch (e) { /* the desktop app, or no answer: nothing to do here */ }
})();

// A file an answer brought (base64) saved by the browser - the PC helper scripts, a .cer.
function saveB64File(r, type = 'application/octet-stream') {
  const bin = atob(r.file), bytes = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([bytes], { type })); a.download = r.name;
  document.body.append(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}
// A file the server prepared, by its single-use link.
function saveFromUrl(url, name) { const a = document.createElement('a'); a.href = url; a.download = name || ''; document.body.append(a); a.click(); setTimeout(() => a.remove(), 1000); }

async function api(path, body = {}) {
  try {
    const r = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-ICA-Session': TOKEN }, body: JSON.stringify({ ...body, token: TOKEN }) });
    const j = await r.json();
    // The server version: a page to open comes back as its address - this browser opens it.
    if (path === '/api/open' && j && j.ok && j.url) window.open(j.url, '_blank', 'noopener');
    // The server version: the session ended (taken over by a sign-in elsewhere, idle, signed out) - back to sign-in.
    if (j && j.error === 'bad token') { if (j.reason) { goSignIn(j.reason); return j; } showDead(); }
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
  let t = log.textContent + (text.endsWith('\n') ? text : text + '\n');
  // A page left open for days: the newest ~2000 lines are kept.
  if (t.length > 300000) { const cut = t.indexOf('\n', t.length - 200000); t = '...\n' + t.slice(cut + 1); }
  log.textContent = t;
  log.scrollTop = log.scrollHeight;
}
const stamp = () => new Date().toTimeString().slice(0, 8);

// 2.38.8: every log colours its lines - failures red, warnings amber, OK green - whoever writes to it (they all set
// textContent; this follows). A failure also opens a folded log, so it is never hidden.
const logKind = l => /\[(FAILED|ERROR)\]|-> FAILED\b|^\s*(ERROR|FAILED)\b[:\s]|\bException\b/.test(l) ? 'lerr'
  : /\[(WARN|WARNING|!)\]/.test(l) ? 'lwarn' : /\[OK\]|^\s*\[\+\]|^PASSED\b/.test(l) ? 'lok' : '';
const logSeen = new WeakMap();
function colourLog(pre) {
  const text = pre.textContent;
  if (logSeen.get(pre) === text) return;
  // A log with markup of its own (Diagnostics' headings and verdicts) is left as it is - only plain text is coloured.
  if ([...pre.children].some(c => !/^(lerr|lwarn|lok)$/.test(c.className))) { logSeen.set(pre, text); return; }
  const atEnd = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 24;
  if (text.length > 400000) { logSeen.set(pre, text); return; }
  const frag = document.createDocumentFragment();
  let plain = '', failed = false;
  for (const line of text.split(/(?<=\n)/)) {
    const k = logKind(line);
    if (!k) { plain += line; continue; }
    if (plain) { frag.append(plain); plain = ''; }
    if (k === 'lerr') failed = true;
    frag.append(el('span', { class: k, text: line }));
  }
  if (plain) frag.append(plain);
  logSeen.set(pre, text);
  pre.replaceChildren(frag);
  pre.classList.toggle('hasfail', failed);
  if (failed) { const d = pre.closest('details'); if (d && !d.open) d.open = true; }
  if (atEnd) pre.scrollTop = pre.scrollHeight;
}
{
  const pending = new Set(); let scheduled = false;
  // One frame for whatever changed since the last - a step writes two logs at once (its own and Activity).
  const mo = new MutationObserver(recs => {
    for (const r of recs) { const pre = (r.target.nodeType === 3 ? r.target.parentElement : r.target).closest('pre.log'); if (pre) pending.add(pre); }
    if (pending.size && !scheduled) { scheduled = true; requestAnimationFrame(() => { scheduled = false; const list = [...pending]; pending.clear(); for (const p of list) colourLog(p); }); }
  });
  for (const pre of document.querySelectorAll('pre.log')) mo.observe(pre, { childList: true, characterData: true, subtree: true });
}

let toastTimer = null;
// -actions: the next steps as buttons in the message, e.g. [{ label: 'Send to Intune', run: () => ... }] - it then stays longer.
// A Microsoft Store product ID (winget's msstore source) - sent to Intune as its own Store app type.
const isStoreId = id => /^(9[0-9A-Z]{11}|XP[0-9A-Z]{12})$/.test(String(id || ''));
// A message shows above everything: inside the dialog on top when one is open (a modal dialog dims and blurs the
// rest of the page, and makes it unclickable - the message, and its Undo, would be under it), else on the page.
function placeToast() {
  const t = $('toast'); if (!t) return;
  const top = (typeof wcStack !== 'undefined' ? wcStack : []).filter(d => d.open && d.matches(':modal') && !d.classList.contains('minimized')).pop()
    || [...document.querySelectorAll('dialog[open]')].filter(d => d.matches(':modal') && !d.classList.contains('minimized')).pop();
  const host = top || document.body;
  if (t.parentElement !== host) host.append(t);
}
window.addEventListener('close', () => setTimeout(placeToast, 0), true);
// A dialog opened while a toast shows: the toast moves into it (else it sits blurred under the backdrop).
const _showModal = HTMLDialogElement.prototype.showModal;
HTMLDialogElement.prototype.showModal = function () { _showModal.call(this); if (!$('toast').hidden) placeToast(); };
function toast(msg, isErr, actions) {
  activity(`${stamp()} ${isErr ? '[FAILED] ' : ''}${msg}`);
  const t = $('toast');
  placeToast();
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
// Light, dark, or automatic - following Windows (and changing with it while the app is open).
const themeDark = matchMedia('(prefers-color-scheme: dark)');
const themeIcons = {
  auto: '<path d="M12 3a9 9 0 1 0 0 18z" fill="currentColor"/><circle cx="12" cy="12" r="9"/>',
  light: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  dark: '<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/>',
};
const themeNames = { auto: 'Automatic (follows the system)', light: 'Light', dark: 'Dark' };
let themePref = 'auto';
function applyTheme(pref) {
  themePref = ['light', 'dark'].includes(pref) ? pref : 'auto';
  document.documentElement.dataset.theme = themePref === 'auto' ? (themeDark.matches ? 'dark' : 'light') : themePref;
  const b = $('btnTheme');
  b.innerHTML = `<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${themeIcons[themePref]}</svg>`;
  b.setAttribute('aria-label', `Theme: ${themeNames[themePref]}`);
  b.title = `Theme: ${themeNames[themePref]} - click for ${themeNames[{ auto: 'light', light: 'dark', dark: 'auto' }[themePref]].toLowerCase()}`;
}
(function initTheme() {
  let t = null;
  try { t = localStorage.getItem('theme'); } catch (e) { }
  applyTheme(t || 'auto');
})();
themeDark.addEventListener('change', () => { if (themePref === 'auto') applyTheme('auto'); });
$('btnTheme').addEventListener('click', () => {
  const t = { auto: 'light', light: 'dark', dark: 'auto' }[themePref];
  applyTheme(t); try { localStorage.setItem('theme', t); } catch (e) { }
});

// ---------------------------------------------------------------- views
// Coffee and theme sit top right in the page bar, on every page and at every width (the bar stays at the top).
function placePageBtns() {
  const bar = document.querySelector('.pagebar');
  if ($('pageBtns').parentElement !== bar) bar.append($('pageBtns'));
}
addEventListener('resize', () => placePageBtns());
function showView(v) {
  // Only the pages there are (a view saved by another version, or a typo, would leave a blank page - and be saved).
  if (![...document.querySelectorAll('.tab[data-view]')].some(b => b.dataset.view === v)) v = 'home';
  if (v === 'checks') delete $('tabChecks').dataset.count;
  document.body.dataset.view = v;   // Home says "not connected" in Getting started - the banner is for the other pages
  for (const b of document.querySelectorAll('.tab')) b.setAttribute('aria-selected', String(b.dataset.view === v));
  const tabLabel = document.querySelector(`.tab[data-view="${v}"] .tl`);
  if (tabLabel) $('pageTitle').textContent = tabLabel.textContent;
  // Coffee and theme sit at the end of the page's own toolbar, on one line with its buttons (the page bar when it has none).
  placePageBtns(v);
  $('viewHome').hidden = v !== 'home';
  if (v === 'home') loadHome();
  $('viewApps').hidden = v !== 'apps';
  $('viewChecks').hidden = v !== 'checks';
  $('viewUpdates').hidden = v !== 'updates';
  if (v === 'updates') loadUpdates(false);
  $('viewScripts').hidden = v !== 'scripts';
  $('viewGroups').hidden = v !== 'groups';
  // Shown as "needs the connection" before: look again - it may have been set up since.
  if (v === 'groups' && (!groupsLoaded || $('viewGroups').classList.contains('noconn'))) loadGroups();
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
  if (settingsSec === 'connection' && typeof loadSignIn === 'function') loadSignIn();
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
// Already on Settings: the banner's button would only scroll - it hides there.
new MutationObserver(() => { const b = $('bannerSettings'); if (b) b.hidden = !$('viewSettings').hidden; }).observe($('viewSettings'), { attributes: true, attributeFilter: ['hidden'] });
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
$('connBadge').addEventListener('click', () => {
  // Not set up yet: the setup guide, step by step; set up: the connection fields and Test connection.
  if (state && !state.configured && !state.testMode) { showSettings('connection'); $('guideReg').open = true; $('guideCard').scrollIntoView({ block: 'start' }); return; }
  showSettings('connection'); $('fTenant').closest('.card').scrollIntoView({ block: 'start' }); $('btnTest').focus();
});

async function loadState() {
  const r = await api('/api/state');
  if (!r.ok) { toast(r.error || 'Could not read the app state.', true); return; }
  state = r;
  $('ver').textContent = 'v' + r.version;
  document.title = 'Intune App Catalog ' + r.version;
  if (r.testMode) setBadge('warn', 'TEST MODE', 'Graph answers come from a test file, not from a tenant. Started with INTUNE_CATALOG_TEST_GRAPH set - restart the app without it.');
  else if (!r.configured) setBadge('none', 'Not connected - set up', 'Nothing is read from or sent to Intune until the connection is set up - click for the setup guide.');
  else checkConnection();
  // 2.32.0: no banner on every page - the badge says it (and leads to the setup guide), each page says what it can't do.
  $('setupBanner').hidden = true;
  $('testBanner').hidden = !r.testMode;
  // Connection fields changed and not saved yet (a new certificate chosen, then an old one deleted): kept - only
  // whether they still differ from what's saved is worked out again.
  if ($('dirtyNote').hidden) { setFields(r.settings); setCertStatus(r.cert); } else updateDirty();
}

// ---------------------------------------------------------------- row actions: one main button, the rest behind "⋯"
let rowMenuEl = null, rowMenuAnchor = null;
function closeRowMenu(refocus) {
  if (!rowMenuEl) return;
  rowMenuEl.remove(); rowMenuEl = null;
  if (rowMenuAnchor) { rowMenuAnchor.setAttribute('aria-expanded', 'false'); if (refocus) rowMenuAnchor.focus(); }
  rowMenuAnchor = null;
}
function openRowMenu(anchor, items) {
  const same = rowMenuAnchor === anchor;
  closeRowMenu();
  if (same) return;
  rowMenuEl = el('div', { class: 'menu rowmenu', role: 'menu' }, ...items.map(b => el('button', { type: 'button', role: 'menuitem', text: b.textContent, title: b.title || '', disabled: b.disabled,
    onclick: e => { e.stopPropagation(); closeRowMenu(true); b.click(); } })));
  rowMenuEl.addEventListener('focusout', e => { if (rowMenuEl && !rowMenuEl.contains(e.relatedTarget) && e.relatedTarget !== rowMenuAnchor) closeRowMenu(); });
  rowMenuEl.addEventListener('keydown', e => {
    const list = [...rowMenuEl.querySelectorAll('button:not(:disabled)')], i = list.indexOf(document.activeElement);
    if (e.key === 'Escape') { e.preventDefault(); closeRowMenu(true); }
    else if (e.key === 'ArrowDown') { e.preventDefault(); list[(i + 1) % list.length].focus(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); list[(i - 1 + list.length) % list.length].focus(); }
  });
  document.body.append(rowMenuEl);
  rowMenuAnchor = anchor; anchor.setAttribute('aria-expanded', 'true');
  const a = anchor.getBoundingClientRect(), m = rowMenuEl.getBoundingClientRect();
  rowMenuEl.style.left = Math.max(8, Math.min(a.right - m.width, innerWidth - m.width - 8)) + 'px';
  rowMenuEl.style.top = (a.bottom + 4 + m.height > innerHeight - 8 ? Math.max(8, a.top - 4 - m.height) : a.bottom + 4) + 'px';
  const first = rowMenuEl.querySelector('button:not(:disabled)'); if (first) first.focus();
}
document.addEventListener('click', () => closeRowMenu());
addEventListener('scroll', e => { if (rowMenuAnchor && (e.target === document || (e.target.contains && e.target.contains(rowMenuAnchor)))) closeRowMenu(); }, true);
// The first button stays as it is; any others go into a "⋯" menu next to it.
function rowActions(acts) {
  const list = acts.filter(Boolean), btns = list.filter(a => a.tagName === 'BUTTON');
  if (btns.length <= 1) return list;
  const [main, ...rest] = btns;
  const more = el('button', { type: 'button', class: 'btn small moreacts', 'aria-haspopup': 'menu', 'aria-expanded': 'false', 'aria-label': 'More actions: ' + rest.map(b => b.textContent.replace(/\.\.\.$/, '')).join(', '),
    title: rest.map(b => b.textContent.replace(/\.\.\.$/, '')).join(', '), text: '⋯', onclick: e => { e.stopPropagation(); openRowMenu(more, rest); } });
  return [main, more];
}

// ---------------------------------------------------------------- loading placeholders
// Grey shimmering rows in a table body (or list) while its content is read - the layout doesn't jump when it arrives.
function skeleton(target, cols = 4, rows = 5) {
  if (!target) return;
  const bar = i => el('span', { class: 'sk w' + (i % 4) });
  if (target.tagName === 'TBODY') target.replaceChildren(...Array.from({ length: rows }, (_, r) => el('tr', { class: 'skel', 'aria-hidden': 'true' }, ...Array.from({ length: cols }, (_, c) => el('td', {}, bar(r + c))))));
  else target.replaceChildren(...Array.from({ length: rows }, (_, r) => el('li', { class: 'skel', 'aria-hidden': 'true' }, bar(r), el('span', { class: 'sk w3' }))));
}

// One date format everywhere: 2026-11-15 14:52 (24 hours); "Today 14:52" / "Yesterday 14:52" for the last two days.
function fmtWhen(v) {
  const d = v instanceof Date ? v : new Date(v); if (isNaN(d)) return String(v || '');
  const p = n => String(n).padStart(2, '0'), hm = `${p(d.getHours())}:${p(d.getMinutes())}`, day = x => x.toDateString();
  if (day(d) === day(new Date())) return `Today ${hm}`;
  if (day(d) === day(new Date(Date.now() - 864e5))) return `Yesterday ${hm}`;
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${hm}`;
}
