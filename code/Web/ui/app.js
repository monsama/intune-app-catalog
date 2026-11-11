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
let editingVersion = '';
async function openEditor(name) {
  editingName = name || ''; editingVersion = '';
  if (name) {
    const r = await api('/api/app-get', { name });
    if (!r.ok) { toast(r.error, true); return; }
    editorApps = r.appNames || []; editorMinOs = r.minOsChoices || [];
    editingVersion = r.version || '';
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
  const r = await api('/api/app-save', { originalName: editingName, version: editingVersion, app });
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
function jobButtons(on) { for (const id of ['btnCheckCerts', 'btnUpload', 'btnAddPerms', 'btnDeployGo', 'btnPushGo', 'btnScriptIntune', 'btnScriptLocal', 'btnGroupSave', 'btnGroupsDeleteGo']) $(id).disabled = !on; if (on) { updateActions(); updateCheckActions(); } }
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
  $('deployLog').textContent = r.note ? r.note + '\n' : '';
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
$('btnPush').addEventListener('click', () => openPushGroups([...selected]));
async function openPushGroups(names) {
  pushNames = names;
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
}
$('btnPushGo').addEventListener('click', async () => {
  $('btnPushGo').disabled = true;
  await runJob({ names: pushNames, mode: 'Apply' }, ok => {
    toast(ok ? 'Groups pushed to Intune.' : 'Push groups failed - see the log.', !ok);
    if (ok) { $('btnPushGo').textContent = 'Done'; loadApps(); }
  }, { path: '/api/push-start', log: 'pushLog', startText: 'Applying...' });
});

// ---------------------------------------------------------------- checks
let findings = [], checkSel = new Set(), checksRunning = false;
const checkLog = t => { const l = $('checkLog'); l.textContent += t.endsWith('\n') ? t : t + '\n'; l.scrollTop = l.scrollHeight; activity(t); };
const keyOf = f => f.key || `${f.area}|${f.catalogName || f.app}|${f.appId}`;
// A stage's fresh findings replace what that stage said before about the same apps (the last audit's cached rows included).
function mergeFindings(r) {
  const names = new Set(r.names || []), areas = new Set(r.areas || []);
  findings = findings.filter(f => !(areas.has(f.area) && names.has(f.catalogName || f.app))).concat(r.findings || []);
}
function setCheckAreas() {
  const cur = $('checkFilter').value, areas = [...new Set(findings.map(f => f.area))].sort();
  $('checkFilter').replaceChildren(el('option', { value: '', text: 'All areas' }), ...areas.map(a => el('option', { value: a, text: a })));
  if (areas.includes(cur)) $('checkFilter').value = cur;
}
// One stage that is a job (details, assignments): resolves when it has ended.
function checkJob(path, body, label) {
  return new Promise(resolve => {
    runJob(body, (ok, res, after) => resolve(ok && after && after.ok ? after : null), { path, log: 'checkLog', startText: label }).then(started => { if (!started) resolve(null); });
  });
}
async function runChecks(names) {
  if (checksRunning) return;
  checksRunning = true; updateCheckActions();
  const b = $('btnRunChecks'); b.disabled = true; b.textContent = 'Checking...';
  $('checkLogBox').open = true; $('checkLog').textContent = '';
  const only = names && names.length ? { names } : {};
  try {
    $('checkNotes').textContent = 'Reading the catalog, Intune and Entra ID...';
    const r = await api('/api/checks-run', only);
    if (!r.ok) { toast(r.error, true); return; }
    if (names && names.length) {
      const set = new Set(names);
      findings = findings.filter(f => !set.has(f.catalogName || f.app)).concat(r.findings || []);
    } else findings = r.findings || [];
    const notes = [...(r.notes || [])];
    checkLog(`${stamp()} ${notes.join(' ')}`);
    renderChecks();
    if ($('chkDetails').checked && r.connected && r.deployed > 0) {
      $('checkNotes').textContent = `Reading ${r.deployed} deployed app(s) from Intune in detail - the slowest part...`;
      const d = await checkJob('/api/checks-details', only, 'Reading the deployed apps in detail...');
      if (d) { mergeFindings(d); renderChecks(); } else notes.push('The detailed check of the deployed apps did not finish - see the log.');
      const a = await checkJob('/api/checks-assign', only, 'Comparing the assignments...');
      if (a) { mergeFindings(a); renderChecks(); } else notes.push('The assignments could not be compared - see the log.');
    }
    if ($('chkWinget').checked && r.winget > 0) {
      $('checkNotes').textContent = `Asking winget about ${r.winget} Winget ID(s)...`;
      checkLog(`${stamp()} Asking winget about ${r.winget} Winget ID(s)...`);
      const w = await api('/api/checks-winget', only);
      if (w.ok) { mergeFindings(w); checkLog(`${stamp()} winget: ${(w.findings || []).length} problem(s).`); }
      else { notes.push(w.error); checkLog(`${stamp()} [WARN] ${w.error}`); }
    }
    $('checkNotes').textContent = notes.join(' ');
    $('checkEmptyTitle').textContent = 'Nothing to fix';
    $('checkEmptyText').textContent = 'The catalog, Intune and Entra ID agree.';
    checkLog(`${stamp()} [OK] Checks finished: ${findings.length} finding(s).`);
  } finally {
    checksRunning = false; b.disabled = false; b.textContent = 'Run checks';
    setCheckAreas(); renderChecks();
  }
}
$('btnRunChecks').addEventListener('click', () => runChecks());

const selFindings = () => findings.filter(f => checkSel.has(keyOf(f)));
const namesWith = (list, action) => [...new Set(list.filter(f => (f.actions || []).includes(action)).map(f => f.catalogName || f.app))];
function updateCheckActions() {
  const sel = selFindings();
  const count = a => namesWith(sel, a).length;
  const set = (id, a, label) => { const n = count(a); $(id).disabled = checksRunning || jobRunning || n === 0; $(id).textContent = n > 1 ? `${label} (${n})` : label; };
  set('btnFixPull', 'Pull', 'Pull'); set('btnFixPushSettings', 'PushMetadata', 'Push settings'); set('btnFixPushGroups', 'PushGroups', 'Push groups');
  $('btnFixAdd').disabled = checksRunning || jobRunning || !sel.some(f => (f.actions || []).includes('AddToCatalog'));
  $('btnFixRecheck').disabled = checksRunning || jobRunning || sel.length === 0;
  $('checkSelCount').textContent = sel.length ? `${sel.length} selected` : '';
}
$('btnFixPull').addEventListener('click', () => openPull(namesWith(selFindings(), 'Pull')));
$('btnFixPushSettings').addEventListener('click', () => pushSettings(namesWith(selFindings(), 'PushMetadata')));
$('btnFixPushGroups').addEventListener('click', () => openPushGroups(namesWith(selFindings(), 'PushGroups')));
$('btnFixAdd').addEventListener('click', () => addFromIntune(selFindings().filter(f => (f.actions || []).includes('AddToCatalog'))));
$('btnFixRecheck').addEventListener('click', () => runChecks([...new Set(selFindings().map(f => f.catalogName || f.app).filter(Boolean))]));
$('checkAll').addEventListener('change', e => {
  const area = $('checkFilter').value;
  for (const f of findings.filter(f => !area || f.area === area)) { if (e.target.checked) checkSel.add(keyOf(f)); else checkSel.delete(keyOf(f)); }
  renderChecks();
});

function dropFinding(f) { findings = findings.filter(x => keyOf(x) !== keyOf(f)); checkSel.delete(keyOf(f)); renderChecks(); }
function fixButtons(f) {
  const out = [], name = f.catalogName || f.app;
  const btn = (text, onclick, title) => out.push(el('button', { class: 'btn small', text, title: title || '', onclick }));
  const fix = async (action, value) => {
    const r = await api('/api/checks-fix', { action, catalogName: name, value });
    if (!r.ok) { toast(r.error, true); return false; }
    toast('Fixed in the catalog.'); dropFinding(f); loadApps(); return true;
  };
  // One order on every row, so the same fix is always in the same place.
  const order = ['RenameFromIntune', 'SetAppId', 'ChooseAppId', 'ClearAppId', 'AddToCatalog', 'Pull', 'PushMetadata', 'PushGroups', 'FindWingetId', 'EditApp', 'Recheck'];
  for (const a of order.filter(x => (f.actions || []).includes(x))) {
    if (a === 'RenameFromIntune' && f.data && f.data.IntuneName) btn('Use Intune’s name', () => fix(a, f.data.IntuneName), f.data.IntuneName);
    else if (a === 'SetAppId' && f.data && f.data.MatchedId) btn('Link to ' + (f.data.MatchedName || 'match'), () => fix(a, f.data.MatchedId));
    else if (a === 'ChooseAppId' && f.data && f.data.Candidates && f.data.Candidates.length && !(f.data.MatchedId)) {
      const sel = el('select', { 'aria-label': 'Intune app' }, ...f.data.Candidates.map(c => el('option', { value: c.id, text: c.displayName })));
      out.push(sel); btn('Link', () => fix('SetAppId', sel.value));
    }
    else if (a === 'ClearAppId') btn('Clear App ID', () => { if (confirm(`Clear ${f.app}'s App ID? It points at an app that no longer exists in Intune.`)) fix(a); });
    else if (a === 'EditApp') btn('Edit', () => openEditor(name));
    else if (a === 'Pull') btn('Pull', () => openPull([name]), 'Intune is right: take its settings and groups into the catalog');
    else if (a === 'PushMetadata') btn('Push settings', () => pushSettings([name]), 'The catalog is right: send its settings to Intune');
    else if (a === 'PushGroups') btn('Push groups', () => openPushGroups([name]), 'The catalog is right: send its groups to Intune');
    else if (a === 'AddToCatalog') btn('Add to catalog', () => addFromIntune([f]));
    else if (a === 'FindWingetId') btn('Find Winget ID', () => openWinget(f.app, async id => { if (await fix('SetWingetId', id)) runChecks([name]); }));
    else if (a === 'Recheck') btn('Re-check', () => runChecks([name]));
  }
  return el('div', { class: 'fixes' }, ...out);
}
function renderChecks() {
  const area = $('checkFilter').value;
  const list = findings.filter(f => !area || f.area === area);
  $('checkBody').replaceChildren(...list.map(f => {
    const k = keyOf(f);
    const box = el('input', { type: 'checkbox', 'aria-label': 'Select', checked: checkSel.has(k) });
    box.addEventListener('change', () => { if (box.checked) checkSel.add(k); else checkSel.delete(k); updateCheckActions(); });
    return el('tr', { 'aria-selected': String(checkSel.has(k)) },
      el('td', { class: 'sel' }, box),
      el('td', {}, el('span', { class: 'pill ' + (f.failed ? 'err' : 'warn'), text: f.area })),
      el('td', { class: 'name', text: f.app }),
      el('td', {}, f.problem, f.cached ? el('span', { class: 'muted', text: ` (last audit${f.checkedAt ? ', ' + f.checkedAt : ''})` }) : ''),
      el('td', { class: 'cmp', text: f.catalog }), el('td', { class: 'cmp', text: f.intune }),
      el('td', {}, fixButtons(f)));
  }));
  $('checkAll').checked = list.length > 0 && list.every(f => checkSel.has(keyOf(f)));
  $('checkCount').textContent = findings.length ? `${list.length} finding(s)` : '';
  $('checkGrid').hidden = findings.length === 0;
  $('checkEmpty').hidden = findings.length > 0;
  updateCheckActions();
}
$('checkFilter').addEventListener('change', renderChecks);

// Add to catalog: reads the Intune-only apps' settings and groups and adds them.
function addFromIntune(list) {
  const items = list.map(f => ({ id: f.appId, name: f.app }));
  if (!items.length) return;
  if (!confirm(`Add ${items.length === 1 ? `"${items[0].name}"` : items.length + ' apps'} from Intune to the catalog?\n\nEach one's settings and groups are read from Intune first. Nothing in Intune changes.`)) return;
  runDialog('Add to catalog', items.map(i => i.name).join(', '));
  runJob({ apps: items }, (ok, res, after) => {
    if (!ok || !after) return;
    const parts = [`Added ${after.added.length} app(s).`];
    if (after.skipped.length) parts.push(`Skipped: ${after.skipped.join('; ')}.`);
    if (after.noGroups.length) parts.push(`Groups couldn't be read for ${after.noGroups.join(', ')} - left empty.`);
    toast(parts.join(' '), !after.added.length);
    for (const f of list) if (after.added.includes(f.app)) dropFinding(f);
    loadApps();
  }, { path: '/api/add-from-intune', log: 'runLog', startText: 'Reading from Intune...' });
}

// Runs one job per name, one after another, in the Run dialog; resolves with the names that worked.
async function runEach(names, body, opts) {
  const done = [];
  for (const name of names) {
    const ok = await new Promise(resolve => {
      runJob(body(name), ok => resolve(ok), { ...opts, startText: (opts.startText || '') + name + '...' }).then(started => { if (!started) resolve(false); });
    });
    if (ok) done.push(name);
  }
  return done;
}
async function pushSettings(names) {
  if (!names.length) return;
  if (!confirm(`Send the catalog's settings for ${names.length === 1 ? `"${names[0]}"` : names.length + ' apps'} to Intune?\n\nDescription, commands, detection rule, requirements, return codes and dependencies are replaced with the catalog's. No package is uploaded; groups aren't touched.`)) return;
  runDialog('Push settings to Intune', names.join(', '));
  const done = await runEach(names, name => ({ name, metadataOnly: true }), { path: '/api/deploy-start', log: 'runLog', startText: 'Pushing ' });
  toast(`Settings pushed for ${done.length} of ${names.length} app(s).`, done.length < names.length);
  for (const f of findings.filter(f => done.includes(f.catalogName) && (f.actions || []).includes('PushMetadata'))) dropFinding(f);
  loadApps();
}

// ---------------------------------------------------------------- winget search (Find Winget ID, Add app)
let wingetPick = null;
function openWinget(query, onPick) {
  wingetPick = onPick;
  $('wgQuery').value = query || ''; $('wgRows').replaceChildren(); $('wgNote').textContent = 'Searches winget’s sources. Pick the package to use its ID.';
  $('dlgWinget').showModal();
  if (query) searchWinget();
}
async function searchWinget() {
  const q = $('wgQuery').value.trim();
  if (q.length < 2) { $('wgNote').textContent = 'Type at least 2 characters.'; return; }
  $('wgNote').textContent = 'Asking winget...'; $('btnWgSearch').disabled = true;
  const r = await api('/api/winget-search', { q });
  $('btnWgSearch').disabled = false;
  if (!r.ok) { $('wgNote').textContent = r.error; return; }
  $('wgNote').textContent = r.rows.length ? `${r.rows.length} package(s). Pick one to use its ID.` : 'winget found nothing - try a shorter name or the publisher.';
  $('wgRows').replaceChildren(...r.rows.map(x => el('tr', {}, el('td', { text: x.name }), el('td', { class: 'chg', text: x.id }), el('td', { text: x.version }), el('td', { text: x.source }),
    el('td', {}, el('button', { class: 'btn small', text: 'Use', onclick: () => { $('dlgWinget').close(); if (wingetPick) wingetPick(x.id, x); } })))));
}
$('btnWgSearch').addEventListener('click', searchWinget);
$('btnFindWinget').addEventListener('click', () => openWinget($('aName').value.trim() || $('aWinget').value.trim(), (id, x) => {
  $('aWinget').value = id;
  if (!$('aName').value.trim()) $('aName').value = x.name;
  if (!$('mPublisher').value.trim() && id.includes('.')) $('mPublisher').value = id.split('.')[0];
}));
$('wgQuery').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); searchWinget(); } });

// ---------------------------------------------------------------- batch edit, add/remove groups
function openBatch(names) {
  batchNames = names;
  $('batchTitle').textContent = `Batch edit - ${names.length} app(s)`;
  $('batchText').textContent = `Tick the fields to change on ${names.join(', ')}. Everything else stays as each app has it.`;
  for (const c of document.querySelectorAll('[data-bf]')) c.checked = false;
  $('bMinOs').replaceChildren(...((prefs && prefs.minOsChoices) || [{ value: 'W10_22H2', label: 'Windows 10 22H2' }]).map(o => el('option', { value: o.value, text: o.label || o.value })));
  $('bMinOs').value = 'W10_22H2';
  $('bDeps').replaceChildren(...apps.map(a => el('label', { class: 'chk' }, el('input', { type: 'checkbox', 'data-bdep': a.name }), a.name)));
  $('batchErr').hidden = true; $('batchLog').hidden = true; $('batchLog').textContent = '';
  $('btnBatchGo').disabled = false;
  $('dlgBatch').showModal();
}
let batchNames = [];
for (const box of document.querySelectorAll('.bfield')) box.addEventListener('input', e => { if (!e.target.matches('[data-bf]')) { const c = box.querySelector('[data-bf]'); if (c) c.checked = true; } });
function readBatch() {
  const v = {
    architecture: () => [...document.querySelectorAll('[data-barch]')].filter(c => c.checked).map(c => c.dataset.barch),
    minOSKey: () => $('bMinOs').value, installContext: () => $('bContext').value, installTimeMinutes: () => $('bTime').value.trim(),
    minDiskSpaceMB: () => $('bDisk').value.trim(), minMemoryMB: () => $('bMem').value.trim(), minProcessors: () => $('bCpus').value.trim(), minCpuSpeedMHz: () => $('bSpeed').value.trim(),
    deviceRestartBehavior: () => $('bRestart').value, allowAvailableUninstall: () => $('bUninstall').value === '1', isFeatured: () => $('bFeatured').value === '1',
    wingetInstallMethod: () => $('bMethod').value, publisher: () => $('bPublisher').value, owner: () => $('bOwner').value, developer: () => $('bDeveloper').value,
    informationUrl: () => $('bInfoUrl').value, privacyUrl: () => $('bPrivacyUrl').value, notes: () => $('bNotes').value,
    returnCodes: () => lines('bCodes').map(l => { const m = /^(-?\d+)\s*[=:]\s*(\w+)$/.exec(l); return m ? { returnCode: m[1], type: m[2] } : { returnCode: l, type: '' }; }),
    dependencies: () => [...document.querySelectorAll('[data-bdep]')].filter(c => c.checked).map(c => c.dataset.bdep),
  };
  const changes = {};
  for (const c of document.querySelectorAll('[data-bf]')) if (c.checked) changes[c.dataset.bf] = v[c.dataset.bf]();
  return changes;
}
$('btnBatchGo').addEventListener('click', async () => {
  $('batchErr').hidden = true;
  const r = await api('/api/batch-edit', { names: batchNames, changes: readBatch() });
  if (!r.ok) { $('batchErr').textContent = r.error; $('batchErr').hidden = false; return; }
  loadApps();
  const msg = `Changed ${r.changed.length} app(s) in the catalog.` + (r.kept.length ? ` Install commands edited by hand were kept on ${r.kept.join(', ')}.` : '');
  if (!$('bPush').checked || !r.deployed.length) { toast(msg); $('dlgBatch').close(); return; }
  $('btnBatchGo').disabled = true; $('batchLog').hidden = false;
  const done = await runEach(r.deployed, name => ({ name, metadataOnly: true }), { path: '/api/deploy-start', log: 'batchLog', startText: 'Pushing ' });
  toast(`${msg} Settings pushed for ${done.length} of ${r.deployed.length}.`, done.length < r.deployed.length);
});

let gbMode = 'add', gbNames = [];
function openGroupsBatch(mode, names) {
  gbMode = mode; gbNames = names;
  const sel = names.map(n => apps.find(a => a.name === n)).filter(Boolean);
  $('gbTitle').textContent = mode === 'add' ? 'Add groups' : 'Remove groups';
  $('gbText').textContent = (mode === 'add' ? 'Adds these groups to ' : 'Removes these groups from ') + `${names.join(', ')} - in the catalog. Push groups sends them to Intune.`;
  const roles = [['requiredFor', 'Required'], ['availableFor', 'Available'], ['uninstallFor', 'Uninstall'], ['excludeFor', 'Excluded']];
  const favs = (prefs && prefs.favoriteGroups) || [];
  $('gbRoles').replaceChildren(...roles.map(([field, label]) => {
    const choices = mode === 'add' ? favs : [...new Set(sel.flatMap(a => a[field] || []))].sort();
    return el('fieldset', { class: 'gbrole' }, el('legend', { text: label }),
      ...(choices.length ? choices.map(g => el('label', { class: 'chk' }, el('input', { type: 'checkbox', 'data-gbr': field, value: g }), g)) : [el('span', { class: 'muted', text: mode === 'add' ? 'No favourites yet.' : 'None of these apps has one.' })]),
      mode === 'add' ? el('input', { 'data-gbx': field, placeholder: 'Other group name', spellcheck: 'false' }) : null);
  }));
  $('gbErr').hidden = true; $('gbLog').hidden = true; $('gbLog').textContent = ''; $('btnGbGo').disabled = false;
  $('dlgGroupsBatch').showModal();
}
$('btnGbGo').addEventListener('click', async () => {
  const roles = {};
  for (const c of document.querySelectorAll('[data-gbr]:checked')) (roles[c.dataset.gbr] = roles[c.dataset.gbr] || []).push(c.value);
  for (const t of document.querySelectorAll('[data-gbx]')) if (t.value.trim()) (roles[t.dataset.gbx] = roles[t.dataset.gbx] || []).push(t.value.trim());
  const r = await api('/api/batch-groups', { mode: gbMode, names: gbNames, roles });
  if (!r.ok) { $('gbErr').textContent = r.error; $('gbErr').hidden = false; return; }
  loadApps();
  $('dlgGroupsBatch').close();
  toast(`${r.changed.length} app(s) changed in the catalog.`);
  if ($('gbPush').checked && r.deployed.length) openPushGroups(r.deployed);
});

// ---------------------------------------------------------------- more menu (also on right-click)
const menu = $('appMenu');
function oneSelected() { return selected.size === 1 ? apps.find(a => a.name === [...selected][0]) : null; }
function openMenu(x, y) {
  const one = oneSelected();
  const sel = [...selected].map(n => apps.find(a => a.name === n)).filter(Boolean);
  const any = sel.length > 0, anyId = sel.some(a => a.hasAppId);
  const enable = { package: !any || sel.some(a => !a.wingetId), pull: anyId, pushsettings: anyId, status: !!(one && one.hasAppId), batchedit: any, addgroups: any, removegroups: any,
    copyid: !!(one && one.hasAppId), clearid: !!(one && one.hasAppId), delete: anyId, remove: !!one };
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
  const names = [...selected], one = oneSelected(), sel = () => names.map(n => apps.find(a => a.name === n)).filter(Boolean);
  switch (b.dataset.act) {
    case 'package':
      runDialog('Package', names.length ? `Building the .intunewin for ${names.length} app(s) with their own installer.` : 'Building every app with its own installer.');
      runJob({ names }, (ok, res, after) => { toast(ok ? (after && after.failed ? `Packaging finished - ${after.failed} failed, see the log.` : 'Packaging finished.') : 'Packaging failed - see the log.', !ok || (after && after.failed)); loadApps(); },
        { path: '/api/package-start', log: 'runLog', startText: 'Packaging...' });
      break;
    case 'pull': openPull(names); break;
    case 'pushsettings': pushSettings(sel().filter(a => a.hasAppId).map(a => a.name)); break;
    case 'batchedit': if (!prefs) await loadPrefs(); openBatch(names); break;
    case 'addgroups': if (!prefs) await loadPrefs(); openGroupsBatch('add', names); break;
    case 'removegroups': openGroupsBatch('remove', names); break;
    case 'status': openStatus(one.name); break;
    case 'copyid':
      try { await navigator.clipboard.writeText(one.appId); toast('Copied ' + one.appId); } catch (err) { toast('Could not copy: ' + one.appId, true); }
      break;
    case 'clearid':
      if (!confirm(`Clear ${one.name}'s App ID in the catalog?\n\nOnly the catalog changes; the app stays in Intune.`)) return;
      { const r = await api('/api/clear-appid', { name: one.name }); toast(r.ok ? 'App ID cleared.' : r.error, !r.ok); loadApps(); }
      break;
    case 'delete': {
      const del = sel().filter(a => a.hasAppId).map(a => a.name);
      if (!confirm(`Delete ${del.length === 1 ? `"${del[0]}"` : `these ${del.length} apps`} from Intune?\n\n${del.length > 1 ? del.join('\n') + '\n\n' : ''}Their assignments go with them - devices that have them keep them installed, but Intune stops managing them. The catalog entries stay, without an App ID.`)) return;
      runDialog('Delete from Intune', del.join(', '));
      const done = await runEach(del, name => ({ name }), { path: '/api/delete-intune', log: 'runLog', startText: 'Deleting ' });
      toast(`Deleted ${done.length} of ${del.length} app(s) from Intune.`, done.length < del.length); loadApps();
      break;
    }
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
  $('statusSummary').textContent = r.summary + (r.truncated ? ' (only the first rows are shown)' : '');
  $('statusRows').replaceChildren(...r.rows.map(x => el('tr', {}, el('td', { text: x.device }), el('td', { text: x.user }),
    el('td', {}, el('span', { class: 'pill ' + (/fail/i.test(x.state) ? 'err' : /install/i.test(x.state) && !/not/i.test(x.state) ? 'ok' : 'muted'), text: x.state })),
    el('td', { text: x.detail }), el('td', { class: 'chg', text: x.error }), el('td', { text: x.version }), el('td', { text: x.lastSeen }))));
}

// ---------------------------------------------------------------- groups
let groups = [], groupsLoaded = false, group = null, toAdd = new Map();
async function loadGroups() {
  groupsLoaded = true;
  const r = await api('/api/groups');
  if (!r.ok) { toast(r.error, true); return; }
  groups = r.groups || [];
  renderGroupList();
}
function renderGroupList() {
  const q = $('groupSearch').value.trim().toLowerCase();
  const rows = groups.filter(g => !q || g.name.toLowerCase().includes(q));
  $('groupList').replaceChildren(...(rows.length ? rows.map(g => {
    const li = el('li', { role: 'option', 'aria-selected': String(!!group && group.name.toLowerCase() === g.name.toLowerCase()), title: g.uses.map(u => `${u.app} (${u.role})`).join('\n') },
      el('span', { class: 'n', text: g.name }), el('span', { class: 'c', text: g.apps === 1 ? '1 app' : g.apps + ' apps' }));
    li.addEventListener('click', () => openGroup(g.name));
    return li;
  }) : [el('li', { class: 'muted', text: groups.length ? 'No match - Open looks the name up in Entra ID.' : 'No app is assigned to a group yet.' })]));
}
$('groupSearch').addEventListener('input', renderGroupList);
$('groupSearch').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); $('btnGroupOpen').click(); } });
$('btnGroupOpen').addEventListener('click', () => { const n = $('groupSearch').value.trim(); if (n) openGroup(n); else toast('Type a group name first.', true); });
$('btnGroupsReload').addEventListener('click', () => { loadGroups(); if (group) openGroup(group.name); });
$('btnGroupNew').addEventListener('click', () => {
  const n = (prompt('Name of the new security group:') || '').trim();
  if (n) openGroup(n);
});

function setGroupBusy(on) { for (const id of ['btnGroupRename', 'btnGroupDelete', 'btnGroupSave', 'btnGroupFind']) $(id).disabled = on || (id !== 'btnGroupSave' && id !== 'btnGroupFind' && !(group && group.found)); }
async function openGroup(name) {
  $('groupEmpty').hidden = true; $('groupDetail').hidden = false; $('groupLog').hidden = true;
  group = { name, found: false }; toAdd = new Map(); renderAdd(); $('gHits').replaceChildren(); $('gFindNote').textContent = '';
  renderGroupList();
  $('gName').textContent = name; $('gState').className = 'pill muted'; $('gState').textContent = 'Reading...';
  $('gNote').textContent = ''; $('gDesc').value = ''; $('gMembers').replaceChildren(); $('gCount').textContent = ''; $('gUses').replaceChildren();
  setGroupBusy(true);
  const r = await api('/api/group-get', { name });
  if (!group || group.name !== name) return;
  if (!r.ok) {
    $('gState').className = 'pill err'; $('gState').textContent = 'Not read';
    $('gNote').textContent = r.error; $('btnGroupSave').disabled = true; return;
  }
  group = r;
  $('gState').className = 'pill ' + (r.found ? 'ok' : 'warn');
  $('gState').textContent = r.found ? 'In Entra ID' : 'Not in Entra ID';
  $('gNote').textContent = !r.found ? 'No group with this exact name exists yet - Create / update group creates it as a security group.'
    : r.duplicates > 1 ? `${r.duplicates} groups have this exact name - this shows the first. Intune can't tell them apart by name; rename the others in Entra ID.` : `Object ID ${r.id}`;
  $('gDesc').value = r.description || '';
  $('gCount').textContent = r.found ? `(${r.members.length})` : '';
  $('gMembers').replaceChildren(...(r.members.length ? r.members.map(m => el('tr', {}, el('td', { text: m.name }), el('td', { text: m.type }), el('td', { class: 'chg', text: m.upn }),
    el('td', {}, (() => { const b = el('button', { class: 'btn small danger', text: 'Remove' }); b.addEventListener('click', () => removeMember(m)); return b; })())))
    : [el('tr', {}, el('td', { class: 'muted', colspan: '4', text: r.found ? 'No members.' : '-' }))]));
  $('gUses').replaceChildren(...(r.uses.length ? r.uses.map(u => el('li', { text: `${u.app} - ${u.role}` })) : [el('li', { class: 'muted', text: 'No app in the catalog uses this group.' })]));
  $('btnGroupSave').textContent = r.found ? 'Update group' : 'Create group';
  setGroupBusy(false);
}
function renderAdd() {
  $('gAddCount').textContent = toAdd.size ? `(${toAdd.size})` : '';
  $('gAdd').replaceChildren(...(toAdd.size ? [...toAdd.values()].map(m => {
    const b = el('button', { class: 'btn small', text: 'Remove' }); b.addEventListener('click', () => { toAdd.delete(m.id); renderAdd(); });
    return el('li', {}, el('span', { class: 'n', text: m.name + (m.upn ? ` (${m.upn})` : '') }), el('span', { class: 'muted', text: m.type }), b);
  }) : [el('li', { class: 'muted', text: 'Nobody yet - search above and Add.' })]));
}
async function findMembers() {
  const q = $('gFind').value.trim();
  if (q.length < 2) { $('gFindNote').textContent = 'Type at least 2 letters.'; return; }
  $('gFindNote').textContent = 'Searching...';
  const r = await api('/api/directory-search', { q });
  if (!r.ok) { $('gFindNote').textContent = r.error; return; }
  const have = new Set((group.members || []).map(m => m.id));
  $('gFindNote').textContent = (r.hits.length ? '' : 'Nothing found. ') + (r.notes || []).join(' ');
  $('gHits').replaceChildren(...r.hits.map(h => {
    const b = el('button', { class: 'btn small', text: have.has(h.id) ? 'Member' : toAdd.has(h.id) ? 'Added' : 'Add' });
    b.disabled = have.has(h.id) || toAdd.has(h.id) || (group.id && h.id === group.id);
    b.addEventListener('click', () => { toAdd.set(h.id, h); b.textContent = 'Added'; b.disabled = true; renderAdd(); });
    return el('li', {}, el('span', { class: 'n', text: h.name + (h.upn ? ` (${h.upn})` : '') }), el('span', { class: 'muted', text: h.type }), b);
  }));
}
$('btnGroupFind').addEventListener('click', findMembers);
$('gFind').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); findMembers(); } });

function groupJob(body, title, onOk) {
  $('groupLog').hidden = false; $('groupLog').textContent = '';
  return runJob(body, (ok, res, after) => { if (ok) onOk(after); }, { path: '/api/group-job', log: 'groupLog', startText: title });
}
$('btnGroupSave').addEventListener('click', () => {
  if (!group) return;
  const name = group.name;
  groupJob({ mode: 'Save', name, description: $('gDesc').value, memberIds: [...toAdd.keys()] }, `${group.found ? 'Updating' : 'Creating'} ${name}...`,
    () => { toast(`${name} is ready.`); loadGroups(); openGroup(name); });
});
function removeMember(m) {
  if (!confirm(`Remove ${m.name} from ${group.name}?\n\nApps assigned to this group stop applying to it.`)) return;
  const name = group.name;
  groupJob({ mode: 'RemoveMember', name, groupId: group.id, memberId: m.id }, `Removing ${m.name}...`, () => { toast('Removed.'); openGroup(name); });
}
$('btnGroupRename').addEventListener('click', () => {
  if (!group || !group.found) return;
  const old = group.name;
  const nn = (prompt(`New name for "${old}":\n\nEntra ID renames the group (same group, same members), then every app in the catalog that names it follows.`, old) || '').trim();
  if (!nn || nn === old) return;
  groupJob({ mode: 'Rename', name: old, groupId: group.id, newName: nn }, `Renaming ${old}...`, after => {
    const n = after && after.updated ? after.updated.length : 0;
    toast(`Renamed to ${nn}; ${n} app(s) in the catalog updated.`); $('groupSearch').value = ''; loadGroups(); loadApps(); openGroup(nn);
  });
});
$('btnGroupDelete').addEventListener('click', () => {
  if (!group || !group.found) return;
  const name = group.name, uses = (group.uses || []).length;
  if (!confirm(`Delete the group "${name}" from Entra ID?\n\n${uses ? `${uses} catalog assignment(s) name it - those apps lose this assignment in Intune, and the catalog keeps naming a group that is gone.` : 'No app in the catalog uses it.'} This can't be undone here.`)) return;
  groupJob({ mode: 'Delete', name }, `Deleting ${name}...`, () => { toast(`${name} was deleted.`); group = null; $('groupDetail').hidden = true; $('groupEmpty').hidden = false; loadGroups(); });
});
$('btnGroupsDelete').addEventListener('click', () => {
  $('gDelLog').hidden = true; $('gDelLog').textContent = ''; $('gDelMore').value = '';
  $('gDelList').replaceChildren(...(groups.length ? groups.map(g => el('label', { class: 'chk' }, el('input', { type: 'checkbox', 'data-gdel': g.name }), `${g.name} `, el('span', { class: 'muted', text: `(${g.apps} app${g.apps === 1 ? '' : 's'})` })))
    : [el('span', { class: 'muted', text: 'No catalog groups - type names below.' })]));
  $('dlgGroupsDelete').showModal();
});
$('btnGroupsDeleteGo').addEventListener('click', () => {
  const names = [...new Set([...document.querySelectorAll('[data-gdel]')].filter(c => c.checked).map(c => c.dataset.gdel).concat(lines('gDelMore')))];
  if (!names.length) { toast('Tick or type at least one group.', true); return; }
  if (!confirm(`Delete ${names.length} group(s) from Entra ID?\n\n${names.join('\n')}\n\nApps assigned to them lose those assignments. This can't be undone here.`)) return;
  $('gDelLog').hidden = false;
  runJob({ mode: 'DeleteMany', names }, ok => { toast(ok ? `Deleted ${names.length} group(s).` : 'Not every group was deleted - see the log.', !ok); loadGroups(); },
    { path: '/api/group-job', log: 'gDelLog', startText: `Deleting ${names.length} group(s)...` });
});

// ---------------------------------------------------------------- platform scripts
let scripts = [], scriptsLoaded = false, scriptSel = null, scriptOrig = null;
async function loadScripts() {
  scriptsLoaded = true;
  $('scriptNote').textContent = 'Reading the scripts...';
  const r = await api('/api/scripts');
  if (!r.ok) { $('scriptNote').textContent = r.error; return; }
  scripts = r.rows || [];
  const notes = [r.tenantRead ? 'PowerShell scripts Intune runs on enrolled Windows devices, with the local copies kept beside the catalog.' : r.tenantError];
  if (r.localErrors && r.localErrors.length) notes.push('Unreadable local files: ' + r.localErrors.join('; '));
  $('scriptNote').textContent = notes.join(' ');
  $('scriptNote').className = 'sub' + (r.tenantRead ? '' : ' warntext');
  $('btnScriptsSave').disabled = !r.tenantRead;
  if (scriptSel && !scripts.some(x => x.displayName === scriptSel.displayName && x.id === scriptSel.id)) scriptSel = null;
  renderScripts();
}
function renderScripts() {
  const q = $('scriptSearch').value.trim().toLowerCase();
  const rows = scripts.filter(x => !q || (x.displayName + ' ' + x.fileName + ' ' + x.description).toLowerCase().includes(q));
  const pill = t => el('span', { class: 'pill ' + (t === 'Saved' ? 'ok' : /^Differs/.test(t) ? 'warn' : /^Local/.test(t) ? 'info' : 'muted'), text: t });
  $('scriptBody').replaceChildren(...rows.map(x => {
    const tr = el('tr', { 'aria-selected': String(scriptSel === x), title: x.description || x.displayName },
      el('td', { text: x.displayName }), el('td', { class: 'mono', text: x.fileName }), el('td', { text: x.runAs }), el('td', { text: x.runAs32Bit }),
      el('td', { text: x.signature }), el('td', { text: x.modified }), el('td', {}, pill(x.local)));
    tr.addEventListener('click', () => { scriptSel = x; renderScripts(); });
    tr.addEventListener('dblclick', () => { scriptSel = x; openScript(x); });
    return tr;
  }));
  $('scriptCount').textContent = `${rows.length} of ${scripts.length}`;
  $('scriptEmpty').hidden = scripts.length > 0;
  $('btnScriptEdit').disabled = !scriptSel;
  $('btnScriptDelete').disabled = !scriptSel;
  $('btnScriptStatus').disabled = !scriptSel || !scriptSel.id;
}
$('scriptSearch').addEventListener('input', renderScripts);
$('btnScriptsReload').addEventListener('click', loadScripts);
$('btnScriptsFolder').addEventListener('click', async () => { const r = await api('/api/open', { target: 'scripts-folder' }); if (!r.ok) toast(r.error, true); });
$('btnScriptNew').addEventListener('click', () => openScript(null));
$('btnScriptEdit').addEventListener('click', () => scriptSel && openScript(scriptSel));
$('btnScriptStatus').addEventListener('click', () => scriptSel && openScriptStatus(scriptSel));
$('btnScriptsSave').addEventListener('click', async () => {
  const b = $('btnScriptsSave'); b.disabled = true; toast('Reading every script in full...');
  const r = await api('/api/scripts-save-local');
  b.disabled = false;
  if (!r.ok) { toast(r.error, true); return; }
  toast(r.message + (r.failed && r.failed.length ? ` ${r.failed.length} could not be read - see Activity.` : ''), r.failed && r.failed.length);
  loadScripts();
});
$('btnScriptDelete').addEventListener('click', async () => {
  const x = scriptSel; if (!x) return;
  if (!x.id) {
    if (!confirm(`Delete the local copy of "${x.displayName}"?\n\nThis script isn't in Intune${x.local === 'Local copy' ? ' (or Intune was not read)' : ''}, so only the file goes.`)) return;
    const r = await api('/api/script-delete', { name: x.displayName });
    toast(r.ok ? 'Local copy deleted.' : r.error, !r.ok); scriptSel = null; loadScripts(); return;
  }
  if (!confirm(`Permanently delete the platform script "${x.displayName}" from Intune?\n\nDevices that already ran it keep whatever it did - Intune only stops running it. Any local copy stays.`)) return;
  runDialog('Delete platform script', x.displayName);
  runJob({ id: x.id, name: x.displayName }, ok => { toast(ok ? `${x.displayName} was deleted from Intune.` : 'Delete failed - see the log.', !ok); scriptSel = null; loadScripts(); },
    { path: '/api/script-delete', log: 'runLog', startText: `Deleting ${x.displayName}...` });
});

function fillScript(s) {
  $('sName').value = s.displayName || ''; $('sDescription').value = s.description || ''; $('sFile').value = s.fileName || '';
  $('sRunAs').value = s.runAsAccount === 'user' ? 'user' : 'system'; $('s32').checked = !!s.runAs32Bit; $('sSig').checked = !!s.enforceSignatureCheck;
  $('sGroups').value = (s.groups || []).join('\n'); $('sContent').value = s.scriptContent || '';
  // Groups that couldn't be read must not be sent as "none" - that would remove every assignment.
  $('sAssign').checked = s.groupsKnown !== false && !!(s.groups && s.groups.length);
  $('sAssign').disabled = s.groupsKnown === false;
  $('sAssignNote').textContent = s.groupsKnown === false ? "The script's groups couldn't be read, so they can't be sent - fix the Group.Read.All permission, then reopen." : "Replaces the script's assignments in Intune - an empty list removes them all.";
}
async function openScript(row) {
  $('scriptErr').hidden = true; $('scriptLog').hidden = true; $('scriptLog').textContent = '';
  scriptOrig = row ? { id: row.id, name: row.displayName } : { id: '', name: '' };
  $('scriptTitle').textContent = row ? row.displayName : 'New platform script';
  $('scriptWhere').textContent = row ? (row.id ? 'In Intune' + (row.local !== 'Not saved here' ? ' - a local copy is kept too.' : '.') : 'Only a local copy - Save to Intune creates it there.') : 'Save locally to keep it as a draft, or Save to Intune to create it there.';
  $('btnScriptIntune').textContent = row && row.id ? 'Save to Intune' : 'Create in Intune';
  fillScript({ runAsAccount: 'system' });
  $('dlgScript').showModal();
  if (row) {
    $('sContent').value = 'Loading...';
    const r = await api('/api/script-get', row.id ? { id: row.id } : { name: row.displayName });
    if (!r.ok) { $('sContent').value = ''; $('scriptErr').textContent = 'Could not load the script: ' + r.error; $('scriptErr').hidden = false; return; }
    fillScript(r.script);
  }
}
$('sLoad').addEventListener('change', async e => {
  const f = e.target.files[0]; if (!f) return;
  if (f.size > 200000) { toast('That file is larger than the 200 KB Intune accepts.', true); return; }
  $('sContent').value = (await f.text()).replace(/^﻿/, '');
  if (!$('sFile').value) $('sFile').value = f.name;
  e.target.value = '';
});
function readScript() {
  return { id: scriptOrig.id, displayName: $('sName').value, description: $('sDescription').value, fileName: $('sFile').value, runAsAccount: $('sRunAs').value,
    runAs32Bit: $('s32').checked, enforceSignatureCheck: $('sSig').checked, scriptContent: $('sContent').value, groups: lines('sGroups') };
}
async function saveScript(destination) {
  $('scriptErr').hidden = true;
  const body = { script: readScript(), originalName: scriptOrig.name, destination, assignGroups: $('sAssign').checked && !$('sAssign').disabled };
  if (destination === 'Intune' && body.assignGroups && !body.script.groups.length && !confirm('The group list is empty - saving removes every assignment this script has in Intune. Continue?')) return;
  if (destination === 'Local') {
    const r = await api('/api/script-save', body);
    if (!r.ok) { $('scriptErr').textContent = r.error; $('scriptErr').hidden = false; return; }
    toast('Saved locally - nothing was sent to Intune.'); $('dlgScript').close(); loadScripts(); return;
  }
  $('scriptLog').hidden = false; $('scriptLog').textContent = '';
  const started = await runJob(body, (ok, res) => {
    if (ok) { toast(`${body.script.displayName} saved to Intune.`); $('dlgScript').close(); }
    else { $('scriptErr').textContent = (res && res.error) || 'It did not finish - see the log.'; $('scriptErr').hidden = false; }
    loadScripts();
  }, { path: '/api/script-save', log: 'scriptLog', startText: 'Sending to Intune...' });
  if (!started) $('scriptLog').hidden = true;
}
$('btnScriptLocal').addEventListener('click', () => saveScript('Local'));
$('btnScriptIntune').addEventListener('click', () => saveScript('Intune'));

async function openScriptStatus(x) {
  $('sStatusTitle').textContent = 'Run status - ' + x.displayName;
  $('sStatusSummary').textContent = 'Reading how the script went on each device...';
  $('sStatusRows').replaceChildren();
  $('dlgScriptStatus').showModal();
  const r = await api('/api/script-runstatus', { id: x.id });
  if (!r.ok) { $('sStatusSummary').textContent = r.error; return; }
  $('sStatusSummary').textContent = r.summary;
  $('sStatusRows').replaceChildren(...r.rows.map(y => el('tr', {}, el('td', { text: y.device }), el('td', { text: y.user }),
    el('td', {}, el('span', { class: 'pill ' + (y.state === 'Success' ? 'ok' : y.state === 'Failed' ? 'err' : 'muted'), text: y.state })),
    el('td', { class: 'v', text: y.result }), el('td', { class: 'chg', text: y.error }), el('td', { text: y.lastRun }))));
}

// ---------------------------------------------------------------- settings: guide, prerequisites, diagnostics, local certificates
$('btnGuideEntra').addEventListener('click', async () => { const r = await api('/api/open', { target: 'entra-home' }); if (!r.ok) toast(r.error, true); });
let prereqRows = [];
async function checkPrereqs() {
  $('btnPrereqCheck').disabled = true; $('prereqText').textContent = 'Checking each PowerShell (a few seconds)...';
  const r = await api('/api/prereqs');
  $('btnPrereqCheck').disabled = false;
  if (!r.ok) { $('prereqText').textContent = r.error; return; }
  prereqRows = r.rows;
  $('prereqText').textContent = r.allInstalled ? `${r.module} is installed everywhere this app needs it.` : `${r.module} is missing in ${r.rows.filter(x => !x.version).length} PowerShell(s).`;
  $('prereqRows').replaceChildren(...r.rows.map(x => el('li', {}, el('span', { class: 'pill ' + (x.version ? 'ok' : 'err'), text: x.version ? x.version : 'missing' }), el('span', { text: x.name + (x.problem ? ' - ' + x.problem : '') }))));
  $('btnPrereqInstall').hidden = r.allInstalled;
}
$('btnPrereqCheck').addEventListener('click', checkPrereqs);
$('btnPrereqInstall').addEventListener('click', async () => {
  const missing = prereqRows.filter(x => !x.version);
  $('btnPrereqInstall').disabled = true;
  const done = await runEach(missing.map(x => x.exe), exe => ({ exe }), { path: '/api/prereq-install', startText: 'Installing into ' });
  $('btnPrereqInstall').disabled = false;
  toast(done.length === missing.length ? 'Installed.' : 'Not everything could be installed - see Activity.', done.length < missing.length);
  checkPrereqs(); loadState();
});
$('btnDiag').addEventListener('click', async () => {
  const b = $('btnDiag'); b.disabled = true; b.textContent = 'Running...';
  const log = $('diagLog'); log.hidden = false; log.replaceChildren(el('span', { class: 'info', text: 'Reading...' }));
  const r = await api('/api/diagnostics');
  b.disabled = false; b.textContent = 'Run diagnostics';
  if (!r.ok) { log.replaceChildren(el('span', { class: 'failed', text: r.error })); return; }
  const tag = { ok: '[OK]', warn: '[WARN]', failed: '[FAILED]', info: '[INFO]' };
  const out = [];
  for (const sec of r.sections) {
    out.push(el('span', { class: 'h', text: `=== ${sec.title} ===\n` }));
    for (const l of sec.lines) {
      out.push(el('span', { class: l.level, text: `${tag[l.level] || ''} ${l.text}\n` }));
      for (const i of l.items || []) out.push(el('span', { class: 'item', text: `    - ${i}\n` }));
    }
    out.push('\n');
  }
  log.replaceChildren(...out);
  activity(`${stamp()} Diagnostics run.`);
});
async function loadCertsLocal() {
  const r = await api('/api/certs-all');
  if (!r.ok) { toast(r.error, true); return; }
  $('certsLocalRows').replaceChildren(...(r.certificates.length ? r.certificates.map(c => el('tr', {},
    el('td', {}, c.subject, c.inUse ? el('span', { class: 'pill ok', text: 'in use' }) : '', !c.hasKey ? el('span', { class: 'pill muted', text: 'no private key' }) : ''),
    el('td', { text: c.store }), el('td', { class: 'chg', text: c.thumbprint }),
    el('td', {}, el('span', { class: c.expired ? 'pill err' : '', text: c.notAfter })),
    el('td', {}, el('button', { class: 'btn small danger', text: 'Delete', onclick: async () => {
      if (!confirm(`Permanently delete this certificate, with its private key, from ${c.store}\\My?\n\n${c.subject}\n${c.thumbprint}${c.inUse ? '\n\nThis is the certificate the app signs in with - without it nothing reaches Intune until you choose another.' : ''}\n\nEntra ID keeps its copy.`)) return;
      const d = await api('/api/cert-delete-local', { thumbprint: c.thumbprint, store: c.store });
      toast(d.ok ? 'Certificate deleted.' : d.error, !d.ok); if (d.ok) { loadCertsLocal(); loadState(); }
    } }))))
    : [el('tr', {}, el('td', { colspan: '5', class: 'muted', text: 'No certificates on this machine.' }))]));
}
$('btnCertsLocal').addEventListener('click', () => { $('dlgCertsLocal').showModal(); loadCertsLocal(); });

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
  await loadApps();
  loadPrefs();
  // Settings > Automatic checks: Checks runs once when the app opens; the tab
  // shows how many findings there are, and the page stays where it was.
  if (state && state.configured && state.startup && state.startup.drift) {
    $('chkDetails').checked = !!state.startup.fullAudit;
    await runChecks();
    if (findings.length) $('tabChecks').dataset.count = findings.length;
    if (findings.length) activity(`${stamp()} Checks at start: ${findings.length} finding(s) - see Checks.`);
  }
})();
