// Intune App Catalog - web interface.
// Talks only to the local server it was loaded from (/api/*, JSON POST, with
// the token from the URL's #fragment). No inline script: the page's CSP
// allows script from this file only.
'use strict';

const $ = id => document.getElementById(id);
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
  for (const b of document.querySelectorAll('.tab')) b.setAttribute('aria-selected', String(b.dataset.view === v));
  $('viewApps').hidden = v !== 'apps';
  $('viewChecks').hidden = v !== 'checks';
  $('viewSettings').hidden = v !== 'settings';
  try { localStorage.setItem('view', v); } catch (e) { }
}
for (const b of document.querySelectorAll('.tab')) b.addEventListener('click', () => showView(b.dataset.view));
$('bannerSettings').addEventListener('click', () => showView('settings'));
$('btnClassic').addEventListener('click', async () => {
  const r = await api('/api/open', { target: 'classic' });
  toast(r.ok ? 'Opening the classic window...' : r.error, !r.ok);
});

// ---------------------------------------------------------------- state
let state = null;
async function loadState() {
  const r = await api('/api/state');
  if (!r.ok) { toast(r.error || 'Could not read the app state.', true); return; }
  state = r;
  $('ver').textContent = 'v' + r.version;
  document.title = 'Intune App Catalog ' + r.version;
  const badge = $('connBadge');
  badge.textContent = r.configured ? 'Connection set up' : 'Not connected';
  badge.className = 'conn ' + (r.configured ? 'ok' : 'warn');
  $('setupBanner').hidden = r.configured;
  setFields(r.settings);
  setCertStatus(r.cert);
}

// ---------------------------------------------------------------- apps
let apps = [], sortKey = 'name', sortDesc = false, lastClicked = null;
const selected = new Set();
let visible = [];

function statusPill(row) {
  const s = row.status || '';
  if (!s) return el('span', { class: 'pill ok', text: 'Deployed' });
  const parts = s.split('; ');
  const good = parts.every(p => p === 'Metadata saved - ready to deploy' || p === 'Custom package');
  const cls = good ? (parts.includes('Metadata saved - ready to deploy') ? 'ok' : 'info') : 'warn';
  return el('span', { class: 'pill ' + cls, text: s });
}
function auditPill(text) {
  if (!text) return '';
  if (/issue|Check failed/.test(text)) return el('span', { class: 'pill warn', text });
  if (/^OK/.test(text)) return el('span', { class: 'pill ok', text });
  return el('span', { class: 'pill muted', text });
}
function needsAttention(a) {
  return (a.status && !/^(Metadata saved - ready to deploy|Custom package)(; Custom package)?$/.test(a.status)) || /issue|Check failed/.test(a.audit || '');
}
const filters = {
  all: () => true,
  attention: needsAttention,
  notdeployed: a => !a.hasAppId,
  pkgmissing: a => a.packageMissing,
  winget: a => !!a.wingetId,
  custom: a => !a.wingetId,
};
function sortValue(a, k) {
  if (k === 'groups') return a.required * 10000 + a.available * 100 + a.uninstall;
  return String(a[k] || '').toLowerCase();
}
function renderApps() {
  const q = $('search').value.trim().toLowerCase();
  const f = filters[$('filter').value] || filters.all;
  const list = apps.filter(a => f(a) && (!q || (a.name + ' ' + a.wingetId).toLowerCase().includes(q)));
  list.sort((x, y) => {
    const a = sortValue(x, sortKey), b = sortValue(y, sortKey);
    const c = typeof a === 'number' ? a - b : a.localeCompare(b, undefined, { numeric: true });
    return sortDesc ? -c : c;
  });
  visible = list.map(a => a.name);
  for (const n of [...selected]) if (!apps.some(a => a.name === n)) selected.delete(n);
  const body = $('gridBody');
  body.replaceChildren(...list.map(a => {
    const tr = el('tr', { 'data-name': a.name, class: selected.has(a.name) ? 'sel' : '', title: a.appId ? 'App ID ' + a.appId : 'Not in Intune yet' },
      el('td', { class: 'name', text: a.name }),
      el('td', { class: 'mono', text: a.wingetId || '-' }),
      el('td', { text: a.type || '' }),
      el('td', { class: 'num', text: a.version || '' }),
      el('td', { class: 'num', title: 'Required / Available / Uninstall', text: `${a.required} / ${a.available} / ${a.uninstall}` }),
      el('td', {}, statusPill(a)),
      el('td', {}, auditPill(a.audit)));
    tr.addEventListener('click', e => selectRow(a.name, e));
    tr.addEventListener('dblclick', () => openEditor(a.name));
    return tr;
  }));
  $('count').textContent = list.length === apps.length ? `${apps.length} apps` : `${list.length} of ${apps.length} apps`;
  for (const th of document.querySelectorAll('.grid th')) {
    th.classList.toggle('sorted', th.dataset.sort === sortKey);
    th.classList.toggle('desc', th.dataset.sort === sortKey && sortDesc);
  }
  updateActions();
  $('emptyState').hidden = apps.length > 0;
  $('grid').hidden = apps.length === 0;
}
function selectRow(name, e) {
  if (e.shiftKey && lastClicked && visible.includes(lastClicked)) {
    const [i, j] = [visible.indexOf(lastClicked), visible.indexOf(name)].sort((x, y) => x - y);
    if (!e.ctrlKey && !e.metaKey) selected.clear();
    for (const n of visible.slice(i, j + 1)) selected.add(n);
  } else if (e.ctrlKey || e.metaKey) {
    if (selected.has(name)) selected.delete(name); else selected.add(name);
    lastClicked = name;
  } else {
    selected.clear(); selected.add(name); lastClicked = name;
  }
  for (const r of $('gridBody').children) r.classList.toggle('sel', selected.has(r.dataset.name));
  updateActions();
}
function updateActions() {
  const n = selected.size;
  $('btnEditApp').disabled = n !== 1;
  $('btnDeploy').disabled = n === 0;
  $('btnPush').disabled = n === 0 || [...selected].some(s => !(apps.find(a => a.name === s) || {}).hasAppId);
  $('btnDeploy').textContent = n > 1 ? `Deploy (${n})` : 'Deploy';
  $('btnPush').textContent = n > 1 ? `Push groups (${n})` : 'Push groups';
}

// ---------------------------------------------------------------- app editor
const lines = id => $(id).value.split(/\r?\n/).map(x => x.trim()).filter(Boolean);
const metaIds = { description: 'mDescription', publisher: 'mPublisher', appVersion: 'mAppVersion', owner: 'mOwner', developer: 'mDeveloper',
  informationUrl: 'mInformationUrl', privacyUrl: 'mPrivacyUrl', installCommand: 'mInstallCommand', uninstallCommand: 'mUninstallCommand',
  notes: 'mNotes' };
let editingName = '';
function fillEditor(a) {
  $('aName').value = a.appName || ''; $('aWinget').value = a.wingetId || ''; $('aAppId').value = a.appId || '';
  $('gRequired').value = (a.requiredFor || []).join('\n'); $('gAvailable').value = (a.availableFor || []).join('\n');
  $('gUninstall').value = (a.uninstallFor || []).join('\n'); $('gExclude').value = (a.excludeFor || []).join('\n');
  for (const [k, id] of Object.entries(metaIds)) $(id).value = (a.metadata && a.metadata[k]) || '';
  $('metaNote').textContent = a.hasMetadata ? '' : '(not set yet - the defaults are used when it is deployed)';
  fillDeploy(a.deploy);
  $('appError').hidden = true;
}
async function openEditor(name) {
  editingName = name || '';
  if (name) {
    const r = await api('/api/app-get', { name });
    if (!r.ok) { toast(r.error, true); return; }
    editorApps = r.appNames || []; editorMinOs = r.minOsChoices || [];
    fillEditor(r.app);
    $('knownGroups').textContent = r.knownGroups.length ? 'Groups used in this catalog: ' + r.knownGroups.join(', ') : '';
    $('appTitle').textContent = 'Edit ' + name;
  } else {
    editorApps = apps.map(a => a.name); editorMinOs = (prefs && prefs.minOsChoices) || [];
    fillEditor({ hasMetadata: false, deploy: prefs && prefs.defaults ? { ...prefs.defaults, detection: { type: '' }, dependencies: prefs.defaults.defaultDependencyAppNames || [] } : null });
    $('knownGroups').textContent = '';
    $('appTitle').textContent = 'Add an app';
  }
  $('btnRemoveApp').hidden = !name;
  $('dlgApp').showModal();
  $('aName').focus();
}
$('btnAddApp').addEventListener('click', () => openEditor(''));
$('btnEditApp').addEventListener('click', () => { if (selected.size === 1) openEditor([...selected][0]); });
$('appForm').addEventListener('submit', async e => {
  e.preventDefault();
  const app = {
    appName: $('aName').value, wingetId: $('aWinget').value, appId: $('aAppId').value,
    requiredFor: lines('gRequired'), availableFor: lines('gAvailable'), uninstallFor: lines('gUninstall'), excludeFor: lines('gExclude'),
    metadata: Object.fromEntries(Object.entries(metaIds).map(([k, id]) => [k, $(id).value])),
  };
  if (deployTouched) app.deploy = readDeploy();
  const r = await api('/api/app-save', { originalName: editingName, app });
  if (!r.ok) { const p = $('appError'); p.textContent = r.error; p.hidden = false; return; }
  $('dlgApp').close();
  selected.clear(); selected.add(r.name); lastClicked = r.name;
  await loadApps();
});
$('btnRemoveApp').addEventListener('click', async () => {
  if (!confirm(`Remove "${editingName}" from the catalog?\n\nOnly the catalog changes - nothing in Intune. A copy of its file goes to the Backups folder.`)) return;
  const r = await api('/api/app-remove', { name: editingName });
  if (!r.ok) { toast(r.error, true); return; }
  $('dlgApp').close(); selected.delete(editingName); await loadApps();
});

async function loadApps() {
  const r = await api('/api/catalog');
  if (!r.ok) { toast(r.error || 'Could not read the catalog.', true); return; }
  apps = r.apps || [];
  $('emptyPath').textContent = r.path || '';
  if (r.failed && r.failed.length) toast(`${r.failed.length} file(s) in the catalog could not be read: ${r.failed.join(', ')}`, true);
  renderApps();
}
for (const th of document.querySelectorAll('.grid th')) th.addEventListener('click', () => {
  if (sortKey === th.dataset.sort) sortDesc = !sortDesc; else { sortKey = th.dataset.sort; sortDesc = false; }
  renderApps();
});
let searchTimer = null;
$('search').addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(renderApps, 120); });
$('filter').addEventListener('change', renderApps);
$('btnReload').addEventListener('click', () => { loadApps(); loadState(); });
$('btnCatalogFolder').addEventListener('click', () => api('/api/open', { target: 'catalog-folder' }));
document.addEventListener('keydown', e => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f' && !$('viewApps').hidden) { e.preventDefault(); $('search').focus(); }
  if (e.key === 'F5') { e.preventDefault(); loadApps(); loadState(); }
});

// ---------------------------------------------------------------- settings
const fields = () => ({ tenantId: $('fTenant').value.trim(), clientId: $('fClient').value.trim(), thumbprint: $('fThumb').value.replace(/\s/g, '') });
function setFields(s) { $('fTenant').value = s.tenantId || ''; $('fClient').value = s.clientId || ''; $('fThumb').value = s.thumbprint || ''; updateDirty(); }
function updateDirty() {
  if (!state) return;
  const f = fields(), s = state.settings;
  $('dirtyNote').hidden = f.tenantId === (s.tenantId || '') && f.clientId === (s.clientId || '') && f.thumbprint === (s.thumbprint || '');
}
function setCertStatus(c) { const p = $('certStatus'); p.textContent = c ? c.text : ''; p.className = 'certstatus ' + (c ? c.level : ''); }
let certTimer = null;
$('fThumb').addEventListener('input', () => {
  updateDirty(); clearTimeout(certTimer);
  certTimer = setTimeout(async () => { const r = await api('/api/cert-status', { thumbprint: fields().thumbprint }); if (r.ok) setCertStatus(r); }, 300);
});
$('fTenant').addEventListener('input', updateDirty);
$('fClient').addEventListener('input', updateDirty);

$('btnSave').addEventListener('click', async () => {
  const r = await api('/api/settings-save', fields());
  if (!r.ok) { toast(r.error, true); return; }
  state = r.state; loadState(); toast('Saved.');
});

function linkify(text) {
  // Only Entra's own https addresses become links; everything else stays text.
  const out = []; const re = /https:\/\/entra\.microsoft\.com\/\S+/g; let last = 0, m;
  while ((m = re.exec(text))) {
    out.push(text.slice(last, m.index));
    out.push(el('a', { href: m[0], target: '_blank', rel: 'noopener noreferrer', text: 'Open the API permissions page' }));
    last = m.index + m[0].length;
  }
  out.push(text.slice(last));
  return out;
}

$('btnTest').addEventListener('click', async () => {
  const btn = $('btnTest'), res = $('testResult');
  btn.disabled = true; res.hidden = false; res.className = 'result busy'; res.textContent = 'Signing in...';
  const r = await api('/api/test-connection', fields());
  btn.disabled = false;
  if (!r.ok) { res.className = 'result error'; res.textContent = r.error; return; }
  res.className = 'result ' + r.level;
  res.textContent = r.summary + (r.conflict ? '\n\n' + r.conflict : '');
  $('checklistCard').hidden = false;
  $('checklist').replaceChildren(...(r.checklist || []).map(c => el('li', { class: c.status },
    el('span', { class: 'mark', text: c.status === 'ok' ? '✓' : c.status === 'failed' ? '✕' : '–' }),
    el('span', { class: 'label', text: c.name }),
    c.next ? el('span', { class: 'next', text: 'Next: ' + c.next }) : null)));
  // The level is the colour here, so the [OK]/[FAILED]/... tag in front is dropped.
  $('report').replaceChildren(...(r.report || []).filter(l => l.text.trim()).map(l => el('div', { class: l.level }, linkify(l.text.replace(/^\s*\[(OK|FAILED|WARN|INFO)\]\s*/, '')))));
});

// certificate picker
$('btnPickCert').addEventListener('click', async () => {
  const r = await api('/api/certs-local');
  if (!r.ok) { toast(r.error, true); return; }
  const list = $('certList');
  list.replaceChildren(...(r.certificates.length ? r.certificates.map(c => el('li', {
    onclick: () => { $('fThumb').value = c.thumbprint; $('fThumb').dispatchEvent(new Event('input')); $('dlgPickCert').close(); }
  }, c.subject + '  ·  valid until ' + c.notAfter + ' (' + c.store + ')', el('span', { class: 't', text: c.thumbprint }))) : [el('li', { text: 'None found. Create one first.' })]));
  $('dlgPickCert').showModal();
});
$('btnNewCert').addEventListener('click', () => $('dlgNewCert').showModal());
$('btnNewCertGo').addEventListener('click', async () => {
  const r = await api('/api/cert-new', { subject: $('fSubject').value });
  $('dlgNewCert').close();
  if (!r.ok) { toast(r.error, true); return; }
  $('fThumb').value = r.thumbprint; $('fThumb').dispatchEvent(new Event('input'));
  toast('Certificate created. Upload it to Entra next, then Save.');
});
$('btnCertFolder').addEventListener('click', () => api('/api/open', { target: 'certificates-folder' }));
for (const b of document.querySelectorAll('dialog [data-close]')) b.addEventListener('click', () => b.closest('dialog').close());

// jobs: Entra actions that sign the user in, in a console window of their own
let jobRunning = false;
function jobButtons(on) { for (const id of ['btnCheckCerts', 'btnUpload', 'btnAddPerms', 'btnDeployGo', 'btnPushGo']) $(id).disabled = !on; if (on) updateActions(); }
async function runJob(body, onDone, opts = {}) {
  if (jobRunning) { toast('Another action is still running - wait for it to finish.', true); return false; }
  const start = await api(opts.path || '/api/job-start', opts.path ? body : { ...fields(), ...body });
  if (!start.ok) { toast(start.error, true); if (onDone) onDone(false, { error: start.error }); return false; }
  jobRunning = true; jobButtons(false);
  const extra = opts.log ? $(opts.log) : null;
  const both = t => { activity(t); if (extra) { extra.textContent += t.endsWith('\n') ? t : t + '\n'; extra.scrollTop = extra.scrollHeight; } };
  both(`${stamp()} ${opts.startText || 'Sign in in the window that opens...'}`);
  let offset = 0;
  const tick = async () => {
    const r = await api('/api/job-poll', { job: start.job, offset });
    if (!r.ok) { jobRunning = false; jobButtons(true); toast(r.error, true); return; }
    if (r.text) { both(r.text); offset = r.offset; }
    if (r.done && !r.text) {
      jobRunning = false; jobButtons(true);
      const ok = r.result && r.result.success;
      if (!ok) toast((r.result && r.result.error) || 'It did not finish - see Activity.', true);
      if (onDone) onDone(ok, r.result, r.after);
      return;
    }
    setTimeout(tick, r.done ? 50 : 700);
  };
  tick();
  return true;
}

function renderEntraCerts(certs) {
  const thumb = fields().thumbprint.toUpperCase();
  $('entraCerts').replaceChildren(...(certs.length ? certs.map(c => el('li', { class: c.Thumbprint === thumb ? 'match' : '' },
    el('span', { class: 'grow' }, c.DisplayName || '(no name)', ' ', el('span', { class: 't', text: c.Thumbprint })),
    el('span', { class: 'muted', text: 'expires ' + c.Expiry }),
    el('button', { class: 'btn small', text: 'Delete...', onclick: () => {
      if (!confirm(`Remove "${c.DisplayName}" (${c.Thumbprint}) from the app registration in Entra?\n\nAnything still signing in with it stops working.`)) return;
      runJob({ mode: 'DeleteCert', keyId: c.KeyId }, ok => { if (ok) $('btnCheckCerts').click(); });
    } }))) : [el('li', { text: 'No certificates in Entra yet - upload this one.' })]));
}
$('btnCheckCerts').addEventListener('click', () => runJob({ mode: 'Check' }, (ok, res) => { if (ok) renderEntraCerts(res.certificates || []); }));
$('btnUpload').addEventListener('click', () => {
  if (!fields().thumbprint) { toast('Choose or create a certificate first.', true); return; }
  runJob({ mode: 'Upload' }, ok => { if (ok) toast('Certificate added. Allow a few minutes, then Test connection - and Save.'); });
});

// permissions
$('btnAddPerms').addEventListener('click', async () => {
  const r = await api('/api/permission-choice');
  if (!r.ok) { toast(r.error, true); return; }
  const item = (p, req) => el('li', {}, el('input', { type: 'checkbox', checked: true, disabled: req, 'data-perm': p.name }), el('span', {}, el('span', { class: 'n', text: p.name }), el('span', { class: 'p', text: p.purpose })));
  $('permList').replaceChildren(el('li', { class: 'group', text: 'Required' }), ...r.required.map(p => item(p, true)), el('li', { class: 'group', text: 'Optional' }), ...r.optional.map(p => item(p, false)));
  $('dlgPerms').showModal();
});
$('btnPermsGo').addEventListener('click', () => {
  const permissions = [...document.querySelectorAll('#permList input[data-perm]')].filter(c => c.checked).map(c => c.dataset.perm);
  $('dlgPerms').close();
  runJob({ mode: 'AddPermissions', permissions }, ok => {
    if (ok) { api('/api/open', { target: 'entra-permissions', clientId: fields().clientId }); toast('Added. In Entra, click "Grant admin consent", then Test connection.'); }
  });
});
$('btnOpenEntra').addEventListener('click', async () => {
  const r = await api('/api/open', { target: 'entra-permissions', clientId: fields().clientId });
  if (!r.ok) toast(r.error, true);
});

// ---------------------------------------------------------------- editor: deploy settings
let editorApps = [], editorMinOs = [], deployTouched = false;
function showDetFields() {
  const t = $('xType').value;
  for (const d of document.querySelectorAll('[data-det]')) d.hidden = !d.dataset.det.split(' ').includes(t);
}
$('xType').addEventListener('change', showDetFields);
function fillDeploy(d) {
  deployTouched = false;
  $('deploySec').open = false;
  if (!d) d = { detection: { type: '' }, architecture: ['x64'], installContext: 'System', minOSKey: 'W10_22H2', installTimeMinutes: 60, deviceRestartBehavior: 'basedOnReturnCode', returnCodes: [], dependencies: [] };
  const x = d.detection || { type: '' };
  $('xType').value = x.type || ''; $('xScript').value = x.script || ''; $('xProductCode').value = x.productCode || '';
  $('xPath').value = x.path || ''; $('xName').value = x.name || ''; $('xKey').value = x.keyPath || ''; $('xValueName').value = x.valueName || '';
  $('xOperator').value = x.operator || 'notConfigured'; $('xValue').value = x.value || ''; $('x32').checked = !!x.check32Bit;
  $('xFileType').value = x.type === 'File' ? (x.detectionType || 'exists') : 'exists';
  $('xRegType').value = x.type === 'Registry' ? (x.detectionType || 'exists') : 'exists';
  showDetFields();
  for (const c of document.querySelectorAll('[data-xarch]')) c.checked = (d.architecture || []).includes(c.dataset.xarch);
  $('xContext').value = d.installContext === 'User' ? 'User' : 'System';
  $('xMinOs').replaceChildren(...editorMinOs.map(o => el('option', { value: o.value, text: o.label || o.value })));
  if (d.minOSKey && ![...$('xMinOs').options].some(o => o.value === d.minOSKey)) $('xMinOs').append(el('option', { value: d.minOSKey, text: d.minOSKey }));
  $('xMinOs').value = d.minOSKey || 'W10_22H2';
  $('xTime').value = d.installTimeMinutes ?? 60; $('xRestart').value = d.deviceRestartBehavior || 'basedOnReturnCode';
  $('xDisk').value = d.minDiskSpaceMB ?? 0; $('xMem').value = d.minMemoryMB ?? 0; $('xCpus').value = d.minProcessors ?? 0; $('xSpeed').value = d.minCpuSpeedMHz ?? 0;
  $('xUninstall').checked = !!d.allowAvailableUninstall;
  $('xCodes').value = (d.returnCodes || []).map(c => `${c.returnCode} = ${c.type}`).join('\n');
  const deps = new Set(d.dependencies || []);
  $('xDeps').replaceChildren(...(editorApps.length ? editorApps.map(n => el('label', { class: 'chk' }, el('input', { type: 'checkbox', 'data-dep': n, checked: deps.has(n) }), n)) : [el('span', { class: 'muted', text: 'No other apps in the catalog.' })]));
}
$('deploySec').addEventListener('input', () => { deployTouched = true; });
$('deploySec').addEventListener('change', () => { deployTouched = true; });
function readDeploy() {
  const t = $('xType').value;
  return {
    detection: { type: t, script: $('xScript').value, productCode: $('xProductCode').value, operator: $('xOperator').value, value: $('xValue').value,
      path: $('xPath').value, name: $('xName').value, keyPath: $('xKey').value, valueName: $('xValueName').value, check32Bit: $('x32').checked,
      detectionType: t === 'File' ? $('xFileType').value : t === 'Registry' ? $('xRegType').value : '' },
    architecture: [...document.querySelectorAll('[data-xarch]')].filter(c => c.checked).map(c => c.dataset.xarch),
    installContext: $('xContext').value, minOSKey: $('xMinOs').value, installTimeMinutes: $('xTime').value.trim(), deviceRestartBehavior: $('xRestart').value,
    minDiskSpaceMB: $('xDisk').value.trim(), minMemoryMB: $('xMem').value.trim(), minProcessors: $('xCpus').value.trim(), minCpuSpeedMHz: $('xSpeed').value.trim(),
    allowAvailableUninstall: $('xUninstall').checked,
    returnCodes: lines('xCodes').map(l => { const m = /^(-?\d+)\s*[=:]\s*(\w+)$/.exec(l); return m ? { returnCode: m[1], type: m[2] } : { returnCode: l, type: '' }; }),
    dependencies: [...document.querySelectorAll('[data-dep]')].filter(c => c.checked).map(c => c.dataset.dep),
  };
}

// ---------------------------------------------------------------- deploy
let deployPlan = [];
function setDeployStatus(name, cls, text) {
  const row = [...$('deployRows').children].find(r => r.dataset.name === name);
  if (row) row.lastChild.replaceChildren(el('span', { class: 'pill ' + cls, text }));
}
$('btnDeploy').addEventListener('click', async () => {
  const r = await api('/api/deploy-plan', { names: [...selected] });
  if (!r.ok) { toast(r.error, true); return; }
  deployPlan = r.apps;
  $('deployRows').replaceChildren(...deployPlan.map(a => el('tr', { 'data-name': a.name },
    el('td', { text: a.name }), el('td', { text: a.update ? 'Update settings' : 'Create' }),
    el('td', {}, a.ready ? el('span', { class: 'pill muted', text: 'Waiting' }) : el('span', { class: 'pill warn', text: 'Skipped: ' + a.reason })))));
  if (r.circular && r.circular.length) toast('These depend on each other in a circle: ' + r.circular.join(', '), true);
  $('deployLog').textContent = '';
  const n = deployPlan.filter(a => a.ready).length;
  $('btnDeployGo').textContent = n === 1 ? 'Deploy 1 app' : `Deploy ${n} apps`;
  $('btnDeployGo').disabled = n === 0;
  $('dlgDeploy').showModal();
});
$('btnDeployGo').addEventListener('click', async () => {
  const queue = deployPlan.filter(a => a.ready).map(a => a.name);
  $('btnDeployGo').disabled = true;
  let okCount = 0;
  const next = async () => {
    const name = queue.shift();
    if (!name) { $('btnDeployGo').disabled = true; $('btnDeployGo').textContent = 'Done'; toast(`Deploy finished: ${okCount} of ${deployPlan.filter(a => a.ready).length} succeeded.`, okCount === 0); loadApps(); return; }
    setDeployStatus(name, 'info', 'Running...');
    await runJob({ name }, async (ok, result, after) => {
      setDeployStatus(name, ok ? 'ok' : 'err', ok ? 'Done' : 'Failed');
      if (ok) okCount++;
      if (ok && after && after.pushGroups) {
        setDeployStatus(name, 'info', 'Pushing groups...');
        await runJob({ names: [name], mode: 'AfterDeploy' }, ok2 => { setDeployStatus(name, ok2 ? 'ok' : 'warn', ok2 ? 'Done, groups pushed' : 'Done, groups failed'); next(); },
          { path: '/api/push-start', log: 'deployLog', startText: `Pushing ${name}'s groups...` });
        return;
      }
      next();
    }, { path: '/api/deploy-start', log: 'deployLog', startText: `Deploying ${name}...` });
  };
  next();
});

// ---------------------------------------------------------------- push groups
let pushNames = [];
$('btnPush').addEventListener('click', async () => {
  pushNames = [...selected];
  $('pushRows').replaceChildren(el('tr', {}, el('td', { colspan: 3, class: 'muted', text: 'Reading the current assignments in Intune...' })));
  $('pushLog').textContent = '';
  $('btnPushGo').disabled = true;
  $('dlgPush').showModal();
  await runJob({ names: pushNames, mode: 'Preview' }, (ok, result) => {
    if (!ok) { $('pushRows').replaceChildren(el('tr', {}, el('td', { colspan: 3, class: 'muted', text: 'Preview failed - see the log below.' }))); return; }
    const data = (result && result.data) || [];
    let changes = 0;
    $('pushRows').replaceChildren(...data.map(d => {
      const add = d.ToAdd || [], rem = d.ToRemove || [];
      changes += add.length + rem.length;
      return el('tr', {}, el('td', { text: d.AppName }),
        el('td', { class: 'chg add' }, add.length ? add.join('\n') : el('span', { class: 'muted', text: '-' })),
        el('td', { class: 'chg rem' }, rem.length ? rem.join('\n') : el('span', { class: 'muted', text: '-' })));
    }));
    $('btnPushGo').disabled = changes === 0;
    $('btnPushGo').textContent = changes === 0 ? 'Nothing to change' : 'Apply';
  }, { path: '/api/push-start', log: 'pushLog', startText: 'Comparing with Intune...' });
});
$('btnPushGo').addEventListener('click', async () => {
  $('btnPushGo').disabled = true;
  await runJob({ names: pushNames, mode: 'Apply' }, ok => {
    toast(ok ? 'Groups pushed to Intune.' : 'Push groups failed - see the log.', !ok);
    if (ok) { $('btnPushGo').textContent = 'Done'; loadApps(); }
  }, { path: '/api/push-start', log: 'pushLog', startText: 'Applying...' });
});

// ---------------------------------------------------------------- checks
let findings = [];
function fixButtons(f) {
  const out = [];
  const fix = async (action, value) => {
    const r = await api('/api/checks-fix', { action, catalogName: f.catalogName || f.app, value });
    if (!r.ok) { toast(r.error, true); return; }
    toast('Fixed in the catalog.');
    findings = findings.filter(x => x.key !== f.key); renderChecks(); loadApps();
  };
  for (const a of f.actions || []) {
    if (a === 'RenameFromIntune' && f.data && f.data.IntuneName) out.push(el('button', { class: 'btn small', text: 'Use Intune’s name', title: f.data.IntuneName, onclick: () => fix(a, f.data.IntuneName) }));
    else if (a === 'SetAppId' && f.data && f.data.MatchedId) out.push(el('button', { class: 'btn small', text: 'Link to ' + (f.data.MatchedName || 'match'), onclick: () => fix(a, f.data.MatchedId) }));
    else if (a === 'ChooseAppId' && f.data && f.data.Candidates && f.data.Candidates.length && !(f.data.MatchedId)) {
      const sel = el('select', {}, ...f.data.Candidates.map(c => el('option', { value: c.id, text: c.displayName })));
      out.push(sel, el('button', { class: 'btn small', text: 'Link', onclick: () => fix('SetAppId', sel.value) }));
    }
    else if (a === 'ClearAppId') out.push(el('button', { class: 'btn small', text: 'Clear App ID', onclick: () => { if (confirm(`Clear ${f.app}'s App ID? It points at an app that no longer exists in Intune.`)) fix(a); } }));
    else if (a === 'EditApp') out.push(el('button', { class: 'btn small', text: 'Edit', onclick: () => openEditor(f.catalogName || f.app) }));
    else if (a === 'PushGroups') out.push(el('button', { class: 'btn small', text: 'Push groups', onclick: () => { selected.clear(); selected.add(f.catalogName || f.app); $('btnPush').disabled = false; $('btnPush').click(); } }));
  }
  const rest = (f.actions || []).filter(a => !['RenameFromIntune', 'SetAppId', 'ChooseAppId', 'ClearAppId', 'EditApp', 'PushGroups'].includes(a));
  if (rest.length && !out.length) out.push(el('span', { class: 'muted', text: 'In the classic window' }));
  return el('div', { class: 'fixes' }, ...out);
}
function renderChecks() {
  const area = $('checkFilter').value;
  const list = findings.filter(f => !area || f.area === area);
  $('checkBody').replaceChildren(...list.map(f => el('tr', {},
    el('td', {}, el('span', { class: 'pill ' + (f.failed ? 'err' : 'warn'), text: f.area })),
    el('td', { class: 'name', text: f.app }),
    el('td', {}, f.problem, f.cached ? el('span', { class: 'muted', text: ` (last audit${f.checkedAt ? ', ' + f.checkedAt : ''})` }) : ''),
    el('td', { class: 'cmp', text: f.catalog }), el('td', { class: 'cmp', text: f.intune }),
    el('td', {}, fixButtons(f)))));
  $('checkCount').textContent = findings.length ? `${list.length} finding(s)` : '';
  $('checkGrid').hidden = findings.length === 0;
  $('checkEmpty').hidden = findings.length > 0;
}
$('checkFilter').addEventListener('change', renderChecks);
$('btnRunChecks').addEventListener('click', async () => {
  const b = $('btnRunChecks'); b.disabled = true; b.textContent = 'Checking...';
  $('checkNotes').textContent = 'Reading the catalog, Intune and Entra ID...';
  const r = await api('/api/checks-run');
  b.disabled = false; b.textContent = 'Run checks';
  if (!r.ok) { toast(r.error, true); return; }
  findings = r.findings || [];
  $('checkNotes').textContent = (r.notes || []).join(' ');
  const areas = [...new Set(findings.map(f => f.area))].sort();
  $('checkFilter').replaceChildren(el('option', { value: '', text: 'All areas' }), ...areas.map(a => el('option', { value: a, text: a })));
  $('checkEmptyTitle').textContent = 'Nothing to fix';
  $('checkEmptyText').textContent = 'The catalog, Intune and Entra ID agree.';
  renderChecks();
});

// ---------------------------------------------------------------- more menu (also on right-click)
const menu = $('appMenu');
function oneSelected() { return selected.size === 1 ? apps.find(a => a.name === [...selected][0]) : null; }
function openMenu(x, y) {
  const one = oneSelected();
  const sel = [...selected].map(n => apps.find(a => a.name === n)).filter(Boolean);
  const any = sel.length > 0, anyId = sel.some(a => a.hasAppId);
  const enable = { package: !any || sel.some(a => !a.wingetId), pull: anyId, status: !!(one && one.hasAppId), copyid: !!(one && one.hasAppId), clearid: !!(one && one.hasAppId), delete: !!(one && one.hasAppId), remove: !!one };
  for (const b of menu.querySelectorAll('button')) b.disabled = !enable[b.dataset.act];
  menu.querySelector('[data-act=package]').textContent = !any ? 'Package every app with its own installer' : enable.package ? `Package ${sel.length > 1 ? 'the selected apps' : 'this app'} (build .intunewin)` : 'Package (Winget apps use the shared package)';
  menu.hidden = false;
  const r = menu.getBoundingClientRect();
  menu.style.left = Math.min(x, innerWidth - r.width - 8) + 'px';
  menu.style.top = Math.min(y, innerHeight - r.height - 8) + 'px';
  const first = menu.querySelector('button:not(:disabled)'); if (first) first.focus();
}
function closeMenu() { menu.hidden = true; }
$('btnMore').addEventListener('click', e => { e.stopPropagation(); const r = $('btnMore').getBoundingClientRect(); openMenu(r.left, r.bottom + 4); });
$('gridBody').addEventListener('contextmenu', e => {
  const tr = e.target.closest('tr'); if (!tr) return;
  e.preventDefault();
  if (!selected.has(tr.dataset.name)) selectRow(tr.dataset.name, {});
  openMenu(e.clientX, e.clientY);
});
document.addEventListener('click', e => { if (!menu.contains(e.target)) closeMenu(); });
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeMenu(); });

function runDialog(title, text) {
  $('runTitle').textContent = title; $('runText').textContent = text || ''; $('runLog').textContent = '';
  $('dlgRun').showModal();
}
menu.addEventListener('click', async e => {
  const b = e.target.closest('button'); if (!b || b.disabled) return;
  closeMenu();
  const names = [...selected], one = oneSelected();
  switch (b.dataset.act) {
    case 'package':
      runDialog('Package', names.length ? `Building the .intunewin for ${names.length} app(s) with their own installer.` : 'Building every app with its own installer.');
      runJob({ names }, (ok, res, after) => { toast(ok ? (after && after.failed ? `Packaging finished - ${after.failed} failed, see the log.` : 'Packaging finished.') : 'Packaging failed - see the log.', !ok || (after && after.failed)); loadApps(); },
        { path: '/api/package-start', log: 'runLog', startText: 'Packaging...' });
      break;
    case 'pull': openPull(names); break;
    case 'status': openStatus(one.name); break;
    case 'copyid':
      try { await navigator.clipboard.writeText(one.appId); toast('Copied ' + one.appId); } catch (err) { toast('Could not copy: ' + one.appId, true); }
      break;
    case 'clearid':
      if (!confirm(`Clear ${one.name}'s App ID in the catalog?\n\nOnly the catalog changes; the app stays in Intune.`)) return;
      { const r = await api('/api/clear-appid', { name: one.name }); toast(r.ok ? 'App ID cleared.' : r.error, !r.ok); loadApps(); }
      break;
    case 'delete':
      if (!confirm(`Delete "${one.name}" from Intune?\n\nIts assignments go with it - devices that have it keep it installed, but Intune stops managing it. The catalog entry stays, without its App ID.`)) return;
      runDialog('Delete from Intune', one.name);
      runJob({ name: one.name }, ok => { toast(ok ? `${one.name} was deleted from Intune.` : 'Delete failed - see the log.', !ok); loadApps(); },
        { path: '/api/delete-intune', log: 'runLog', startText: `Deleting ${one.name}...` });
      break;
    case 'remove':
      if (!confirm(`Remove "${one.name}" from the catalog?\n\nOnly the catalog changes - nothing in Intune. A copy of its file goes to the Backups folder.`)) return;
      { const r = await api('/api/app-remove', { name: one.name }); toast(r.ok ? 'Removed from the catalog.' : r.error, !r.ok); selected.delete(one.name); loadApps(); }
      break;
  }
});

// ---------------------------------------------------------------- pull from Intune
let pullPending = '';
function openPull(names) {
  $('pullText').textContent = `Reading ${names.length} app(s) from Intune. Apps whose catalog entry matches Intune (or has no settings yet) take Intune's right away; anything different is shown here to choose.`;
  $('pullReview').replaceChildren(); $('pullLog').textContent = ''; $('btnPullApply').hidden = true; pullPending = '';
  $('dlgPull').showModal();
  runJob({ names }, (ok, res, after) => {
    if (!ok || !after) { $('pullText').textContent = 'Pull failed - see the log below.'; return; }
    const msg = [];
    if (after.applied && after.applied.length) msg.push(`Updated from Intune: ${after.applied.join(', ')}.`);
    if (after.failed && after.failed.length) msg.push(`Could not read: ${after.failed.join('; ')}.`);
    if (after.review && after.review.length) msg.push('These differ from Intune. Tick what should keep the catalog’s value - everything else takes Intune’s:');
    else msg.push('Nothing to review.');
    $('pullText').textContent = msg.join(' ');
    pullPending = after.pending || '';
    $('pullReview').replaceChildren(...(after.review || []).map(r => el('div', { class: 'pullapp', 'data-app': r.app },
      el('h3', { text: r.app }),
      el('table', {}, el('tr', {}, el('td', { class: 'muted', text: 'Keep catalog' }), el('td', { class: 'muted', text: 'Field' }), el('td', { class: 'muted', text: 'Catalog' }), el('td', { class: 'muted', text: 'Intune' })),
        ...r.diffs.map(d => el('tr', {}, el('td', {}, el('input', { type: 'checkbox', 'data-field': d.field })), el('td', { text: d.field }), el('td', { class: 'v', text: d.local }), el('td', { class: 'v', text: d.intune })))))));
    $('btnPullApply').hidden = !pullPending;
    loadApps();
  }, { path: '/api/pull-start', log: 'pullLog', startText: 'Reading from Intune...' });
}
$('btnPullApply').addEventListener('click', async () => {
  const keep = {};
  for (const box of document.querySelectorAll('#pullReview .pullapp')) keep[box.dataset.app] = [...box.querySelectorAll('input:checked')].map(c => c.dataset.field);
  const r = await api('/api/pull-apply', { pending: pullPending, keep });
  if (!r.ok) { toast(r.error, true); return; }
  $('dlgPull').close(); toast('Applied.'); loadApps();
});

// ---------------------------------------------------------------- install status
async function openStatus(name) {
  $('statusTitle').textContent = 'Install status - ' + name;
  $('statusSummary').textContent = 'Reading Intune’s install status report...';
  $('statusRows').replaceChildren();
  $('dlgStatus').showModal();
  const r = await api('/api/install-status', { name });
  if (!r.ok) { $('statusSummary').textContent = r.error; return; }
  const counts = {};
  for (const x of r.rows) counts[x.state || '?'] = (counts[x.state || '?'] || 0) + 1;
  $('statusSummary').textContent = r.rows.length ? `${r.rows.length} device(s): ` + Object.entries(counts).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${v} ${k}`).join(', ') + (r.truncated ? ' (first 5000 shown)' : '') : 'No devices have reported for this app yet.';
  $('statusRows').replaceChildren(...r.rows.map(x => el('tr', {}, el('td', { text: x.device }), el('td', { text: x.user }),
    el('td', {}, el('span', { class: 'pill ' + (/fail/i.test(x.state) ? 'err' : /install/i.test(x.state) && !/not/i.test(x.state) ? 'ok' : 'muted'), text: x.state })),
    el('td', { text: x.detail }), el('td', { class: 'chg', text: x.error }), el('td', { text: x.version }), el('td', { text: x.lastSeen }))));
}

// ---------------------------------------------------------------- settings: packaging, checks, folders, defaults, favourites
let prefs = null;
function setPkgState(p) {
  $('pkgTool').textContent = p.toolFound ? `Packaging tool found${p.toolVersion ? ' (version ' + p.toolVersion + ')' : ''}.` : 'Packaging tool (IntuneWinAppUtil.exe) not downloaded yet.';
  $('pkgTool').className = 'certstatus ' + (p.toolFound ? 'ok' : 'warn');
  $('pkgShared').textContent = p.sharedFound ? 'Shared Winget package (init.intunewin) built.' : 'Shared Winget package (init.intunewin) not built yet - every Winget app deploys with it.';
  $('pkgShared').className = 'certstatus ' + (p.sharedFound ? 'ok' : 'warn');
}
async function loadPrefs() {
  const [p, k] = await Promise.all([api('/api/prefs'), api('/api/packaging')]);
  if (k.ok) setPkgState(k);
  if (!p.ok) return;
  prefs = p;
  for (const c of document.querySelectorAll('[data-check]')) c.checked = !!p.checks[c.dataset.check];
  $('folderList').replaceChildren(...p.folders.map(f => el('div', { class: 'folder' },
    el('label', { text: f.label }), el('div', { class: 'why', text: f.why }),
    el('input', { 'data-folder': f.key, value: f.chosen, placeholder: f.default, spellcheck: 'false' }))));
  const d = p.defaults;
  for (const c of document.querySelectorAll('[data-arch]')) c.checked = d.architecture.includes(c.dataset.arch);
  $('dContext').value = d.installContext; $('dWinget').value = d.wingetInstallMethod || 'WAU';
  $('dMinOs').replaceChildren(...p.minOsChoices.map(o => el('option', { value: o.value, text: o.label || o.value })));
  if (![...$('dMinOs').options].some(o => o.value === d.minOSKey)) $('dMinOs').append(el('option', { value: d.minOSKey, text: d.minOSKey }));
  $('dMinOs').value = d.minOSKey;
  $('dTime').value = d.installTimeMinutes; $('dDisk').value = d.minDiskSpaceMB; $('dMem').value = d.minMemoryMB; $('dCpus').value = d.minProcessors; $('dSpeed').value = d.minCpuSpeedMHz;
  $('dRestart').value = d.deviceRestartBehavior; $('dUninstall').checked = d.allowAvailableUninstall;
  $('dCodes').value = d.returnCodes.map(c => `${c.returnCode} = ${c.type}`).join('\n');
  $('dDeps').value = (d.defaultDependencyAppNames || []).join('\n');
  $('favGroups').value = (p.favoriteGroups || []).join('\n');
}
async function savePrefs(part, okText, errEl) {
  const r = await api('/api/prefs-save', part);
  if (!r.ok) { if (errEl) { $(errEl).textContent = r.error; $(errEl).hidden = false; } else toast(r.error, true); return; }
  if (errEl) $(errEl).hidden = true;
  toast(okText); loadPrefs();
}
$('btnSaveChecks').addEventListener('click', () => savePrefs({ checks: Object.fromEntries([...document.querySelectorAll('[data-check]')].map(c => [c.dataset.check, c.checked])) }, 'Saved.'));
$('btnSaveFolders').addEventListener('click', () => savePrefs({ folders: Object.fromEntries([...document.querySelectorAll('[data-folder]')].map(i => [i.dataset.folder, i.value.trim()])) }, 'Folders saved.'));
$('btnSaveFavs').addEventListener('click', () => savePrefs({ favoriteGroups: lines('favGroups') }, 'Favourites saved.'));
$('btnSaveDefaults').addEventListener('click', () => {
  const codes = lines('dCodes').map(l => { const m = /^(-?\d+)\s*[=:]\s*(\w+)$/.exec(l); return m ? { returnCode: m[1], type: m[2] } : { returnCode: l, type: '' }; });
  savePrefs({ defaults: {
    architecture: [...document.querySelectorAll('[data-arch]')].filter(c => c.checked).map(c => c.dataset.arch),
    installContext: $('dContext').value, minOSKey: $('dMinOs').value, wingetInstallMethod: $('dWinget').value,
    installTimeMinutes: $('dTime').value.trim(), minDiskSpaceMB: $('dDisk').value.trim(), minMemoryMB: $('dMem').value.trim(), minProcessors: $('dCpus').value.trim(), minCpuSpeedMHz: $('dSpeed').value.trim(),
    deviceRestartBehavior: $('dRestart').value, allowAvailableUninstall: $('dUninstall').checked, returnCodes: codes, defaultDependencyAppNames: lines('dDeps'),
  } }, 'Default values saved.', 'defaultsError');
});
async function packagingSetup(what, btn) {
  const b = $(btn); b.disabled = true; const t = b.textContent; b.textContent = 'Working...';
  activity(`${stamp()} ${what === 'tool' ? 'Downloading the packaging tool...' : 'Building init.intunewin...'}`);
  const r = await api('/api/packaging-setup', { what });
  b.disabled = false; b.textContent = t;
  toast(r.ok ? (r.message || 'Done.') : r.error, !r.ok);
  if (r.state) setPkgState(r.state);
}
$('btnGetTool').addEventListener('click', () => packagingSetup('tool', 'btnGetTool'));
$('btnBuildShared').addEventListener('click', () => packagingSetup('shared', 'btnBuildShared'));

// ---------------------------------------------------------------- start
(async function start() {
  let v = 'apps'; try { v = localStorage.getItem('view') || 'apps'; } catch (e) { }
  showView(v);
  await pollServerLog();
  await loadState();
  if (state && !state.configured) showView('settings');
  loadApps();
  loadPrefs();
})();
