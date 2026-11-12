// Intune App Catalog - web interface: Settings.
// Loaded after core.js (shared helpers and state); app.js starts the page.
'use strict';

// ---------------------------------------------------------------- settings
const fields = () => ({ tenantId: $('fTenant').value.trim(), clientId: $('fClient').value.trim(), thumbprint: $('fThumb').value.replace(/\s/g, '') });
function setFields(s) { $('fTenant').value = s.tenantId || ''; $('fClient').value = s.clientId || ''; $('fThumb').value = s.thumbprint || ''; updateDirty(); }
function updateDirty() {
  if (!state) return;
  const f = fields(), s = state.settings;
  $('dirtyNote').hidden = f.tenantId === (s.tenantId || '') && f.clientId === (s.clientId || '') && f.thumbprint === (s.thumbprint || '');
}
function setCertStatus(c) { const p = $('certStatus'); p.textContent = c ? c.text : ''; p.className = 'certstatus ' + (c ? c.level : ''); if (typeof renderSetupSteps === 'function') renderSetupSteps(); }
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
  rememberTest(r);
  $('checklistCard').hidden = false;
  $('checklist').replaceChildren(...(r.checklist || []).map(c => el('li', { class: c.status },
    el('span', { class: 'mark', text: c.status === 'ok' ? '✓' : c.status === 'failed' ? '✕' : '–' }),
    el('span', { class: 'label', text: c.name }),
    c.next ? el('span', { class: 'next', text: 'Next: ' + c.next }) : null)));
  // The level is the colour here, so the [OK]/[FAILED]/... tag in front is dropped.
  $('report').replaceChildren(...(r.report || []).filter(l => l.text.trim()).map(l => el('div', { class: l.level }, linkify(l.text.replace(/^\s*\[(OK|FAILED|WARN|INFO)\]\s*/, '')))));
});

// certificate picker
async function pickCertificate() {
  const r = await api('/api/certs-local');
  if (!r.ok) { toast(r.error, true); return; }
  const list = $('certList');
  list.replaceChildren(...(r.certificates.length ? r.certificates.map(c => el('li', {},
    el('button', { type: 'button', class: 'pick', title: 'Use this certificate for the connection (Save keeps it)', onclick: () => {
      $('fThumb').value = c.thumbprint; $('fThumb').dispatchEvent(new Event('input')); $('dlgPickCert').close();
      toast('Certificate chosen - Test connection, then Save.');
    } }, c.subject + '  ·  valid until ' + c.notAfter + ' (' + c.store + ')', el('span', { class: 't', text: c.thumbprint })))) :
    [el('li', { class: 'muted', text: 'None that can sign in. Create one, or import yours into your user store (certmgr.msc > Personal) with its private key.' })]));
  const hidden = [r.expired ? `${r.expired} expired` : '', r.noKey ? `${r.noKey} without a private key` : ''].filter(Boolean);
  $('certHidden').textContent = hidden.length ? `Not shown: ${hidden.join(', ')} - Delete one... lists every certificate.` : '';
  $('certHidden').hidden = !hidden.length;
  $('dlgPickCert').showModal();
}
$('btnPickCert').addEventListener('click', pickCertificate);
$('btnUseCert').addEventListener('click', pickCertificate);
$('btnNewCert').addEventListener('click', () => $('dlgNewCert').showModal());
$('btnNewCertGo').addEventListener('click', async () => {
  const r = await api('/api/cert-new', { subject: $('fSubject').value });
  $('dlgNewCert').close();
  if (!r.ok) { toast(r.error, true); return; }
  $('fThumb').value = r.thumbprint; $('fThumb').dispatchEvent(new Event('input'));
  toast('Certificate created. Upload it to Entra next, then Save.');
});
$('btnCertFolder').addEventListener('click', () => openFolder('certificates-folder'));
for (const b of document.querySelectorAll('dialog [data-close]')) b.addEventListener('click', () => b.closest('dialog').close());

// jobs: Entra actions that sign the user in, in a console window of their own
let jobRunning = false;
function jobButtons(on) { for (const id of ['btnCheckCerts', 'btnUpload', 'btnAddPerms', 'btnDeployGo', 'btnPushGo', 'btnScriptIntune', 'btnScriptLocal', 'btnGroupSave', 'btnGroupsDeleteGo']) $(id).disabled = !on; if (on) { updateActions(); updateCheckActions(); } }
async function runJob(body, onDone, opts = {}) {
  if (jobRunning) { toast('Another action is still running - wait for it to finish.', true); return false; }
  const start = await api(opts.path || '/api/job-start', opts.path ? body : { ...fields(), ...body });
  if (!start.ok) { toast(start.error, true); if (onDone) onDone(false, { error: start.error }); return false; }
  return followJob(start.job, onDone, opts);
}
// Shows a running step's output until it ends, then hands over its result -
// for a step just started, and for one still running from before a reload.
function followJob(job, onDone, opts = {}) {
  jobRunning = true; jobButtons(false);
  const extra = opts.log ? $(opts.log) : null;
  const both = t => { activity(t); if (extra) { extra.textContent += t.endsWith('\n') ? t : t + '\n'; extra.scrollTop = extra.scrollHeight; } };
  both(`${stamp()} ${opts.startText || 'Sign in in the window that opens...'}`);
  let offset = 0;
  const tick = async () => {
    const r = await api('/api/job-poll', { job, offset });
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
    el('button', { class: 'btn small', text: 'Delete...', onclick: async () => {
      if (!(await ask(`Remove "${c.DisplayName}" (${c.Thumbprint}) from the app registration in Entra?\n\nAnything still signing in with it stops working.`))) return;
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

// ---------------------------------------------------------------- settings: guide, prerequisites, diagnostics, local certificates
// ---- Setup guide: five steps that tick themselves off from what the app
// knows - the fields, the certificate on this machine, and the last Test
// connection (remembered per browser: it's guidance, not state).
let lastTest = null;
try { lastTest = JSON.parse(localStorage.getItem('lastTest') || 'null'); } catch (e) { lastTest = null; }
function rememberTest(r) {
  const rows = r.checklist || [], row = re => rows.find(c => re.test(c.name));
  const ok = c => !!(c && c.status === 'ok');
  lastTest = { at: Date.now(), entra: ok(row(/Entra ID accepts/i)), perms: ok(row(/permissions/i)), all: rows.length > 0 && rows.every(c => c.status === 'ok') };
  try { localStorage.setItem('lastTest', JSON.stringify(lastTest)); } catch (e) { }
  renderSetupSteps();
}
function renderSetupSteps() {
  const f = fields(), certOk = $('certStatus').classList.contains('ok'), t = lastTest || {};
  const btn = (text, id, title) => el('button', { type: 'button', class: 'btn', text, title, onclick: () => $(id).click() });
  const steps = [
    { title: 'Create the app registration', text: 'In Entra ID > App registrations: a new registration, or one your organization approved for this.', done: !!(f.tenantId && f.clientId),
      acts: [el('button', { type: 'button', class: 'btn', text: 'Open App registrations', title: 'Open the Entra admin center in your browser', onclick: async () => { const r = await api('/api/open', { target: 'entra-home' }); if (!r.ok) toast(r.error, true); } })] },
    { title: 'Copy its IDs into Connection', text: 'The Application (client) ID and the Directory (tenant) ID.', done: !!(f.tenantId && f.clientId),
      acts: [el('button', { type: 'button', class: 'btn', text: 'Go to Connection', title: 'Jump to the Tenant ID field', onclick: () => { $('fTenant').scrollIntoView({ block: 'center' }); $('fTenant').focus(); } })] },
    { title: 'Give it a certificate', text: 'Use one from your user or machine store, or create one - then upload it to the app registration.', done: certOk && !!t.entra,
      acts: [btn('Use an existing one...', 'btnUseCert', 'Pick a certificate from your user or machine store'), btn('Create new...', 'btnNewCert', 'Create a self-signed certificate on this machine'), btn('Upload to Entra', 'btnUpload', 'Add the chosen certificate to the app registration (you sign in)')] },
    { title: 'Add the API permissions', text: 'As Application permissions (not Delegated) - then an admin presses Grant admin consent in Entra.', done: !!t.perms,
      acts: [btn('Add required permissions...', 'btnAddPerms', 'Add the permissions to the app registration (you sign in)')] },
    { title: 'Test the connection', text: 'Signs in with the settings above and lists anything still missing.', done: !!t.all,
      acts: [btn('Test connection', 'btnTest', 'Sign in and check the permissions - nothing is changed')] },
  ];
  const current = steps.findIndex(s => !s.done);
  $('setupSteps').replaceChildren(...steps.map((s, i) => el('li', { class: 'step' + (s.done ? ' done' : '') + (i === current ? ' current' : ''), 'aria-current': i === current ? 'step' : false },
    el('span', { class: 'num', 'aria-hidden': 'true', text: s.done ? '✓' : String(i + 1) }),
    el('div', {}, el('h3', {}, s.title, s.done ? el('span', { class: 'sr', text: ' (done)' }) : null), el('p', { text: s.text }), el('div', { class: 'acts' }, s.acts)))));
  const doneCount = steps.filter(s => s.done).length;
  $('guideState').textContent = doneCount === steps.length ? 'Setup complete' : `${doneCount} of ${steps.length} done`;
  $('guideState').className = 'guidestate' + (doneCount === steps.length ? ' ok' : '');
}
for (const id of ['fTenant', 'fClient', 'fThumb']) $(id).addEventListener('input', () => setTimeout(renderSetupSteps, 0));
$('tileChecks').addEventListener('click', () => { showView('checks'); $('btnRunChecks').click(); });
$('tileAdd').addEventListener('click', () => { showView('apps'); $('btnAddApp').click(); });
$('tileDiff').addEventListener('click', () => showView('checks'));
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
      if (!(await ask(`Permanently delete this certificate, with its private key, from ${c.store}\\My?\n\n${c.subject}\n${c.thumbprint}${c.inUse ? '\n\nThis is the certificate the app signs in with - without it nothing reaches Intune until you choose another.' : ''}\n\nEntra ID keeps its copy.`))) return;
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
