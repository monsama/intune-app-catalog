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
  // The badge follows the test: connected only when it fully worked.
  if (r.level === 'ok') setBadge('ok', 'Connected', r.summary + ' (tested ' + new Date().toTimeString().slice(0, 5) + ')');
  else setBadge('error', 'Connection problem', r.summary);
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
// The certificate menu beside the thumbprint: create, import, download, delete.
const certMenu = $('certMenu');
// Choosing a certificate is one more item of the Certificate menu (2.32.0) - one button beside the thumbprint.
$('btnPickCertMenu').addEventListener('click', () => $('btnPickCert').click());
$('btnCertMenu').addEventListener('click', e => {
  e.stopPropagation();
  if (!certMenu.hidden) { certMenu.hidden = true; $('btnCertMenu').setAttribute('aria-expanded', 'false'); return; }
  setEnabled($('btnCerDownload'), !!$('fThumb').value.trim(), 'Choose or create a certificate first.');
  setEnabled($('btnPfxExport'), !!$('fThumb').value.trim(), 'Choose, create or import a certificate first.');
  const r = $('btnCertMenu').getBoundingClientRect();
  placeMenu(certMenu, r.right - 240, r.bottom + 4); $('btnCertMenu').setAttribute('aria-expanded', 'true');
});
certMenu.addEventListener('click', e => { if (e.target.closest('button')) { certMenu.hidden = true; $('btnCertMenu').setAttribute('aria-expanded', 'false'); } });
document.addEventListener('click', e => { if (!certMenu.hidden && !certMenu.contains(e.target)) { certMenu.hidden = true; $('btnCertMenu').setAttribute('aria-expanded', 'false'); } });
document.addEventListener('keydown', e => { if (e.key === 'Escape' && !certMenu.hidden) { certMenu.hidden = true; $('btnCertMenu').setAttribute('aria-expanded', 'false'); $('btnCertMenu').focus(); } });
$('btnNewCert').addEventListener('click', () => $('dlgNewCert').showModal());
$('btnNewCertGo').addEventListener('click', async () => {
  const r = await api('/api/cert-new', { subject: $('fSubject').value });
  $('dlgNewCert').close();
  if (!r.ok) { toast(r.error, true); return; }
  $('fThumb').value = r.thumbprint; $('fThumb').dispatchEvent(new Event('input'));
  toast('Certificate created. Upload it to Entra next, then Save.');
});
$('btnCertFolder').addEventListener('click', () => openFolder('certificates-folder'));
// The server version: the certificate comes as a .pfx, and its .cer goes to Entra ID by hand.
$('btnPfxImport').addEventListener('click', () => { $('pfxFile').value = ''; $('pfxPassword').value = ''; $('pfxError').hidden = true; $('dlgPfx').showModal(); });
$('btnPfxGo').addEventListener('click', async () => {
  const f = $('pfxFile').files[0];
  if (!f) { $('pfxError').textContent = 'Choose the .pfx file.'; $('pfxError').hidden = false; return; }
  const bytes = new Uint8Array(await f.arrayBuffer()); let bin = ''; for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  const r = await api('/api/cert-import', { pfx: btoa(bin), password: $('pfxPassword').value });
  $('pfxPassword').value = '';
  if (!r.ok) { $('pfxError').textContent = r.error; $('pfxError').hidden = false; return; }
  $('dlgPfx').close();
  $('fThumb').value = r.thumbprint; $('fThumb').dispatchEvent(new Event('input'));
  toast(`Imported ${r.subject} (valid until ${r.notAfter}) - Test connection, then Save.`);
});
$('btnCerDownload').addEventListener('click', async () => {
  const t = $('fThumb').value.trim();
  if (!t) { toast('Choose, create or import a certificate first.', true); return; }
  const r = await api('/api/cert-file', { thumbprint: t });
  if (!r.ok) { toast(r.error, true); return; }
  saveB64File(r, 'application/pkix-cert');
});
// 2.38.10: the certificate with its private key, as a .pfx - with a password, and only after saying what the file can do.
$('btnPfxExport').addEventListener('click', () => {
  const t = $('fThumb').value.trim();
  if (!t) { toast('Choose, create or import a certificate first.', true); return; }
  $('pfxExWhat').textContent = `The certificate ${t} - as Windows' certificate manager exports it. To use the connection on another machine (or keep a copy), import the file there.`;
  $('pfxExPw').value = ''; $('pfxExPw2').value = ''; $('pfxExError').hidden = true;
  $('dlgPfxExport').showModal(); $('pfxExPw').focus();
});
$('btnPfxExGo').addEventListener('click', async () => {
  const pw = $('pfxExPw').value, err = t => { $('pfxExError').textContent = t; $('pfxExError').hidden = false; };
  if (pw.length < 12) return err('Use a password of at least 12 characters - the file can sign in as the app.');
  if (pw !== $('pfxExPw2').value) return err('The two passwords differ.');
  const r = await api('/api/cert-export-pfx', { thumbprint: $('fThumb').value.trim(), password: pw });
  $('pfxExPw').value = ''; $('pfxExPw2').value = '';
  if (!r.ok) return err(r.error);
  $('dlgPfxExport').close();
  saveB64File(r, 'application/x-pkcs12');
  toast(`Exported ${r.name} - keep it safe; the export is in the log.`);
});
for (const b of document.querySelectorAll('dialog [data-close]')) b.addEventListener('click', () => b.closest('dialog').close());

// jobs: Entra actions that sign the user in, in a console window of their own
let jobRunning = false;
// While a step runs, the buttons that start another are off; afterwards each
// gets back the state it had before - a button its dialog had switched off
// (Deploy's "Done", Apply before a preview) stays off.
const jobButtonIds = ['btnCheckCerts', 'btnUpload', 'btnAddPerms', 'btnDeployGo', 'btnPushGo', 'btnScriptIntune', 'btnScriptLocal', 'btnGroupSave'];
function jobButtons(on) {
  const chip = $('jobChip'); if (chip) chip.hidden = on;
  for (const id of jobButtonIds) {
    const b = $(id);
    if (!on) { if (b.dataset.jobWas === undefined) b.dataset.jobWas = b.disabled ? '1' : '0'; b.disabled = true; }
    else { if (b.dataset.jobWas !== undefined) { b.disabled = b.dataset.jobWas === '1'; delete b.dataset.jobWas; } }
  }
  if (on) { updateActions(); updateCheckActions(); }
}
async function runJob(body, onDone, opts = {}) {
  const busy = 'Another action is still running - wait for it to finish.';
  if (jobRunning) { toast(busy, true); if (onDone) onDone(false, { error: busy }); return false; }
  // Taken before the request: two quick clicks must not start two steps.
  jobRunning = true;
  const start = await api(opts.path || '/api/job-start', opts.path ? body : { ...fields(), ...body });
  if (!start.ok) { jobRunning = false; toast(start.error, true); if (onDone) onDone(false, { error: start.error }); return false; }
  return followJob(start.job, onDone, opts);
}
// Shows a running step's output until it ends, then hands over its result -
// for a step just started, and for one still running from before a reload.
function followJob(job, onDone, opts = {}) {
  jobRunning = true; jobButtons(false);
  const extra = opts.log ? $(opts.log) : null;
  const both = t => { activity(t); if (extra) { extra.textContent += t.endsWith('\n') ? t : t + '\n'; extra.scrollTop = extra.scrollHeight; } };
  both(`${stamp()} ${opts.startText || 'Sign in in the window that opens...'}`);
  let offset = 0, fails = 0;
  const tick = async () => {
    const r = await api('/api/job-poll', { job, offset });
    if (!r.ok) {
      // A missed answer is retried; a job the server no longer knows (or five misses in a row) ends here - and says so to whoever waits for it.
      if (r.error !== 'No such job.' && ++fails < 5) { setTimeout(tick, 1500); return; }
      jobRunning = false; jobButtons(true);
      const error = r.error === 'No such job.' ? 'The page lost track of this step - the server finished it on its own; see Activity.' : r.error;
      toast(error, true);
      if (onDone) onDone(false, { error });
      return;
    }
    fails = 0;
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
$('btnEntraScript').addEventListener('click', () => $('btnAddPerms').click());
$('btnAddPerms').addEventListener('click', async () => {
  const r = await api('/api/permission-choice');
  if (!r.ok) { toast(r.error, true); return; }
  const item = (p, req) => el('li', {}, el('input', { type: 'checkbox', checked: true, disabled: req, 'data-perm': p.name, 'aria-label': p.name }), el('span', {}, el('span', { class: 'n', text: p.name }), el('span', { class: 'p', text: p.purpose })));
  $('permList').replaceChildren(el('li', { class: 'group', text: 'Required' }), ...r.required.map(p => item(p, true)), el('li', { class: 'group', text: 'Optional' }), ...r.optional.map(p => item(p, false)));
  $('dlgPerms').showModal();
});
$('btnPermsGo').addEventListener('click', async () => {
  const permissions = [...document.querySelectorAll('#permList input[data-perm]')].filter(c => c.checked).map(c => c.dataset.perm);
  $('dlgPerms').close();
  // The server version: the same step as a script for a Windows PC (you sign in there).
  if (SERVER) {
    const f = fields();
    const r = await api('/api/entra-script', { tenantId: f.tenantId, clientId: f.clientId, thumbprint: f.thumbprint, permissions });
    if (!r.ok) { toast(r.error, true); return; }
    saveB64File(r, 'text/plain');
    toast('Run the script on a Windows PC (right-click > Run with PowerShell) and sign in. Then grant admin consent on the page it opens, and Test connection here.');
    return;
  }
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
    // The server version: the certificate is chosen, created or imported here; Entra ID gets it (and the permissions)
    // from the Entra setup script, run on a Windows PC.
    ...(SERVER ? [
      { title: 'Give it a certificate', text: 'Import the .pfx the app registration already has, or create one here.', done: certOk,
        acts: [btn('Choose...', 'btnPickCert', 'Pick a certificate from the server\'s store'), btn('Import a .pfx...', 'btnPfxImport', 'The app registration\'s certificate, with its private key'), btn('Create new...', 'btnNewCert', 'A self-signed certificate on the server')] },
      { title: 'Add it and the API permissions in Entra ID', text: 'The Entra setup script does both on a Windows PC (you sign in there); then an admin presses Grant admin consent.', done: !!(t.entra && t.perms),
        acts: [btn('Entra setup script...', 'btnEntraScript', 'A script for a Windows PC: adds the certificate and the permissions'), btn('Grant consent...', 'btnOpenEntra', 'Open the API permissions page in Entra')] },
    ] : [
    { title: 'Give it a certificate', text: 'Use one from your user or machine store, or create one - then upload it to the app registration.', done: certOk && !!t.entra,
      acts: [btn('Use an existing one...', 'btnPickCert', 'Pick a certificate from your user or machine store'), btn('Create new...', 'btnNewCert', 'Create a self-signed certificate on this machine'), btn('Upload to Entra', 'btnUpload', 'Add the chosen certificate to the app registration (you sign in)')] },
    { title: 'Add the API permissions', text: 'As Application permissions (not Delegated) - then an admin presses Grant admin consent in Entra.', done: !!t.perms,
      acts: [btn('Add required permissions...', 'btnAddPerms', 'Add the permissions to the app registration (you sign in)')] },
    ]),
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
  // 2.32.0: while it is being set up, the guide has the Entra ID buttons (once); set up, the guide folds away and
  // the Entra ID row under the connection holds them for later (a new certificate, the permissions again).
  const complete = doneCount === steps.length;
  document.querySelector('#viewSettings .entrarow').hidden = !(complete || (state && state.configured));
  if (guideWasComplete !== complete) { $('guideReg').open = !complete; guideWasComplete = complete; }
}
let guideWasComplete = null;
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
  const builtIn = p.packagerInUse === 'builtin';
  $('pkgTool').textContent = builtIn ? `Packages are built in - no download needed.${p.toolFound ? ' IntuneWinAppUtil.exe is there too.' : ''}`
    : p.toolFound ? `Packaging tool found${p.toolVersion ? ' (version ' + p.toolVersion + ')' : ''}.` : 'Packaging tool (IntuneWinAppUtil.exe) not downloaded yet.';
  $('pkgTool').className = 'certstatus ' + (builtIn || p.toolFound ? 'ok' : 'warn');
  if (p.packager) $('pkgPackager').value = p.packager;
  // Built by itself when it's missing (start, before a send, the nightly run) - the card only says it's there, and since when.
  $('pkgShared').textContent = p.sharedFound ? `Shared Winget package (init.intunewin): ready - built ${p.sharedBuilt ? fmtWhen(p.sharedBuilt) : ''}. Every Winget app deploys with it; the app builds it again by itself if it goes missing.`
    : 'Shared Winget package (init.intunewin): not there yet - the app builds it by itself before the first Winget app is sent (or Build it now).';
  $('pkgShared').className = 'certstatus ' + (p.sharedFound ? 'ok' : 'warn');
  if ($('btnBuildShared')) { $('btnBuildShared').textContent = p.sharedFound ? 'Rebuild init.intunewin' : 'Build init.intunewin'; $('btnBuildShared').title = p.sharedFound ? 'Build it again - only needed if the file was damaged; its content never changes' : 'Build it now'; }
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
  $('dContext').value = d.installContext; $('dOwner').value = d.defaultOwner || ''; $('dWinget').value = ['Managed', 'Winget'].includes(d.wingetInstallMethod) ? d.wingetInstallMethod : 'Managed'; dWingetSaved = $('dWinget').value;
  $('dMinOs').replaceChildren(...p.minOsChoices.map(o => el('option', { value: o.value, text: o.label || o.value })));
  if (![...$('dMinOs').options].some(o => o.value === d.minOSKey)) $('dMinOs').append(el('option', { value: d.minOSKey, text: d.minOSKey }));
  $('dMinOs').value = d.minOSKey;
  $('dTime').value = d.installTimeMinutes; $('dDisk').value = d.minDiskSpaceMB; $('dMem').value = d.minMemoryMB; $('dCpus').value = d.minProcessors; $('dSpeed').value = d.minCpuSpeedMHz;
  $('dRestart').value = d.deviceRestartBehavior; $('dUninstall').checked = d.allowAvailableUninstall;
  $('dCodes').value = d.returnCodes.map(c => `${c.returnCode} = ${c.type}`).join('\n');
  $('dDeps').value = (d.defaultDependencyAppNames || []).join('\n');
  $('favGroups').value = (p.favoriteGroups || []).join('\n');
  fillProfiles(p);
  $('pilotGroups').value = (p.pilotGroups || []).join('\n');
  const rp = p.releasePolicy || {};
  $('rpDays').value = rp.Days ?? 3; $('rpFailed').value = rp.MaxFailedPercent ?? 5; $('rpMin').value = rp.MinInstalled ?? 1;
  const rdays = rp.ReleaseDays || [0, 1, 2, 3, 4, 5, 6];
  for (const c of document.querySelectorAll('[data-rday]')) c.checked = rdays.includes(+c.dataset.rday);
  $('rpSkipLast').checked = !!rp.SkipLastWeek; $('rpWithdraw').value = rp.AutoWithdrawPercent ?? 0;
  $('rpDrift').checked = rp.DriftCheck !== false; $('rpDriftFix').checked = !!rp.DriftFix; $('rpBackup').checked = rp.BackupCatalog !== false; $('rpBackupGit').checked = !!rp.BackupGit; $('rpMonthly').checked = !!rp.MonthlyReport; $('rpGate').value = rp.GatePath || '';
  $('rpFastHours').value = rp.FastTrackHours ?? 4; $('rpDeadline').value = rp.DeadlineDays ?? 0; $('rpGrace').value = rp.RestartGraceMinutes ?? 0; $('rpNotif').value = rp.Notifications || 'showAll';
  $('releaseRings').value = (p.releaseRings || []).map(r => `${r.name}: ${r.groups.join(', ')}`).join('\n');
  const al = p.alerts || {};
  $('alLevel').value = al.level || 'off'; $('alWebhook').value = ''; $('alClearHook').checked = false; $('alClearHook').parentElement.hidden = !al.webhookSet;
  $('alWebhook').placeholder = al.webhookSet ? 'Saved - paste a new address to change it' : 'https://...';
  $('alFrom').value = al.mailFrom || ''; $('alTo').value = (al.mailTo || []).join(', ');
  $('rpAutoRelease').checked = !!rp.AutoRelease; $('rpAutoPromote').checked = !!rp.AutoPromote; $('rpCleanup').checked = !!rp.CleanupOld;
}
// Settings cards with changes not saved yet: saving one card reloads the settings, but leaves what's typed in the others.
// A card with unsaved changes says so next to its title; leaving the app then asks first.
function markDirty(c, on) {
  if (!c) return;
  if (on) c.dataset.dirty = '1'; else delete c.dataset.dirty;
  const h = c.querySelector('h2'); if (!h) return;
  let tag = h.querySelector('.unsaved');
  if (on && !tag) h.append(tag = el('span', { class: 'pill warn unsaved', text: 'Unsaved changes' }));
  if (!on && tag) tag.remove();
}
document.getElementById('viewSettings').addEventListener('input', e => markDirty(e.target.closest('.card'), true));
document.getElementById('viewSettings').addEventListener('change', e => markDirty(e.target.closest('.card'), true));
addEventListener('beforeunload', e => { if (document.querySelector('#viewSettings .card[data-dirty]')) { e.preventDefault(); e.returnValue = ''; } });
async function savePrefs(part, okText, errEl) {
  const savedCard = document.activeElement && document.activeElement.closest && document.activeElement.closest('#viewSettings .card');
  const r = await api('/api/prefs-save', part);
  if (!r.ok) { if (errEl) { $(errEl).textContent = r.error; $(errEl).hidden = false; } else toast(r.error, true); return false; }
  if (errEl) $(errEl).hidden = true;
  toast(okText);
  if (savedCard) markDirty(savedCard, false);
  const keep = [...document.querySelectorAll('#viewSettings .card[data-dirty]')].flatMap(c => [...c.querySelectorAll('input, select, textarea')]).filter(x => x.id && !x.id.endsWith('Chips'))
    .map(x => [x, x.type === 'checkbox' || x.type === 'radio' ? x.checked : x.value]);
  await loadPrefs();
  for (const [x, v] of keep) { if (x.type === 'checkbox' || x.type === 'radio') x.checked = v; else x.value = v; }
  return true;
}
$('btnSaveChecks').addEventListener('click', () => savePrefs({ checks: Object.fromEntries([...document.querySelectorAll('[data-check]')].map(c => [c.dataset.check, c.checked])) }, 'Saved.'));
$('btnSaveFolders').addEventListener('click', () => savePrefs({ folders: Object.fromEntries([...document.querySelectorAll('[data-folder]')].map(i => [i.dataset.folder, i.value.trim()])) }, 'Folders saved.'));
const savePolicy = okText => savePrefs({ pilotGroups: lines('pilotGroups'), releaseRingsText: $('releaseRings').value, releasePolicy: { Days: $('rpDays').value, MaxFailedPercent: $('rpFailed').value, MinInstalled: $('rpMin').value,
  FastTrackHours: $('rpFastHours').value,
  ReleaseDays: [...document.querySelectorAll('[data-rday]')].filter(c => c.checked).map(c => +c.dataset.rday), SkipLastWeek: $('rpSkipLast').checked, AutoWithdrawPercent: $('rpWithdraw').value,
  DriftCheck: $('rpDrift').checked, DriftFix: $('rpDriftFix').checked, BackupCatalog: $('rpBackup').checked, BackupGit: $('rpBackupGit').checked, MonthlyReport: $('rpMonthly').checked, GatePath: $('rpGate').value.trim(), DeadlineDays: $('rpDeadline').value, RestartGraceMinutes: $('rpGrace').value, Notifications: $('rpNotif').value,
  AutoRelease: $('rpAutoRelease').checked, AutoPromote: $('rpAutoPromote').checked, CleanupOld: $('rpCleanup').checked, RunAt: (prefs && prefs.releasePolicy && prefs.releasePolicy.RunAt) || '03:00' } }, okText);
$('btnSavePilot').addEventListener('click', () => savePolicy('Managed updates saved.'));
$('btnSaveNightly').addEventListener('click', () => savePolicy('Nightly run saved.'));
const alertPart = () => ({ alerts: { level: $('alLevel').value, webhookUrl: $('alWebhook').value.trim(), clearWebhook: $('alClearHook').checked, mailFrom: $('alFrom').value.trim(), mailTo: $('alTo').value.split(/[,;\s]+/).filter(Boolean) } });
$('btnSaveAlerts').addEventListener('click', () => savePrefs(alertPart(), 'Alerts saved.'));
$('btnAlertTest').addEventListener('click', async () => {
  const b = $('btnAlertTest'); b.disabled = true;
  try { const r = await api('/api/alert-test', {}); toast(r.ok ? r.message : r.error, !r.ok); } finally { b.disabled = false; }
});
$('btnSaveFavs').addEventListener('click', () => savePrefs({ favoriteGroups: lines('favGroups') }, 'Favourites saved.'));
let dWingetSaved = '';
// The default only shapes new apps - when it changes, the Winget apps already in the catalog are offered the same switch.
async function switchExistingWinget(method) {
  if (method === 'Managed') { if (apps.some(a => a.wingetId && !a.managed)) await managedForAll(); return; }
  const names = apps.filter(a => a.wingetId && !a.managed && !isStoreId(a.wingetId)).map(a => a.name);
  if (!names.length) return;
  const label = 'the winget command';
  if (!(await ask(`Switch the install and uninstall commands of the ${names.length} Winget app(s) already in the catalog to ${label} too?\n\n${names.slice(0, 12).join(', ')}${names.length > 12 ? ', ...' : ''}\n\nCommands edited by hand are kept. Apps with managed updates keep their pinned commands. Apps in Intune get the new commands pushed.`, { ok: 'Switch them' }))) return;
  const r = await api('/api/batch-edit', { names, changes: { wingetInstallMethod: method } });
  if (!r.ok) { toast(r.error, true); return; }
  await loadApps();
  const msg = `Switched ${r.changed.length} app(s).` + (r.kept.length ? ` Kept the hand-edited commands of ${r.kept.join(', ')}.` : '');
  if (!r.deployed.length) { toast(msg); return; }
  const done = await runEach(r.deployed, name => ({ name, metadataOnly: true }), { path: '/api/deploy-start', startText: 'Pushing ' });
  toast(`${msg} Pushed to Intune for ${done.length} of ${r.deployed.length}.`, done.length < r.deployed.length, [{ label: 'Undo', run: () => undoLast() }]);
}
$('btnSaveDefaults').addEventListener('click', async () => {
  const before = dWingetSaved, method = $('dWinget').value;
  const codes = lines('dCodes').map(l => { const m = /^(-?\d+)\s*[=:]\s*(\w+)$/.exec(l); return m ? { returnCode: m[1], type: m[2] } : { returnCode: l, type: '' }; });
  const ok = await savePrefs({ defaults: {
    architecture: [...document.querySelectorAll('[data-arch]')].filter(c => c.checked).map(c => c.dataset.arch),
    installContext: $('dContext').value, minOSKey: $('dMinOs').value, wingetInstallMethod: $('dWinget').value, defaultOwner: $('dOwner').value,
    installTimeMinutes: $('dTime').value.trim(), minDiskSpaceMB: $('dDisk').value.trim(), minMemoryMB: $('dMem').value.trim(), minProcessors: $('dCpus').value.trim(), minCpuSpeedMHz: $('dSpeed').value.trim(),
    deviceRestartBehavior: $('dRestart').value, allowAvailableUninstall: $('dUninstall').checked, returnCodes: codes, defaultDependencyAppNames: lines('dDeps'),
  } }, 'Default values saved.', 'defaultsError');
  if (ok && before && method !== before) await switchExistingWinget(method);
});
async function packagingSetup(what, btn) {
  const b = $(btn); b.disabled = true; const t = b.textContent; b.textContent = 'Working...';
  activity(`${stamp()} ${what === 'tool' ? 'Downloading the packaging tool...' : 'Building init.intunewin...'}`);
  const r = await api('/api/packaging-setup', { what });
  b.disabled = false; b.textContent = t;
  // Said as what happened, not as a bare file path.
  toast(r.ok ? (what === 'shared' ? 'The shared Winget package (init.intunewin) is built.' : (r.message || 'Done.')) : r.error, !r.ok);
  if (r.state) setPkgState(r.state);
}
$('pkgPackager').addEventListener('change', async () => {
  const r = await api('/api/prefs-save', { packager: $('pkgPackager').value });
  if (!r.ok) { toast(r.error || 'Not saved.', true); return; }
  const k = await api('/api/packaging'); if (k.ok) setPkgState(k);
  toast('Packager saved.');
});
$('btnGetTool').addEventListener('click', () => packagingSetup('tool', 'btnGetTool'));
$('btnBuildShared').addEventListener('click', () => packagingSetup('shared', 'btnBuildShared'));

// ---------------------------------------------------------------- managed updates: the nightly run
async function loadUpdateRuns() {
  loadUnattended();
  const r = await api('/api/update-runs');
  if (!r.ok) return;
  const sch = r.schedule || {};
  $('runSchedule').dataset.base = $('runSchedule').dataset.base || $('runSchedule').textContent;
  $('runSchedule').textContent = $('runSchedule').dataset.base + (!sch.supported ? ' (Scheduled tasks need Windows.)' : sch.exists ? ` Scheduled every day at ${showTime(sch.runAt)}${serverTimeNote(sch)}, as ${sch.user}.` : ' Not scheduled yet.');
  if (sch.runAt) $('runAt').value = sch.runAt; else if (!$('runAt').value) $('runAt').value = (prefs && prefs.releasePolicy && prefs.releasePolicy.RunAt) || '03:00';
  setEnabled($('btnSchedule'), !!sch.supported, 'Scheduled tasks need Windows.');
  setEnabled($('btnUnschedule'), !!sch.exists, 'There is no scheduled task.');
  $('btnSchedule').textContent = sch.exists ? 'Change' : 'Schedule';
  const cls = { withdrawn: 'warn', drift: 'warn', health: 'warn', fixed: 'ok', report: 'info', advanced: 'ok', promoted: 'ok', released: 'ok', cleaned: 'ok', failed: 'err', hold: 'warn', ready: 'info', available: 'info', cleanup: 'info' };
  $('runList').replaceChildren(...(r.running ? [el('p', { class: 'muted', text: 'A run is going now - Reload shows it when it ends.' })] : []),
    ...(r.runs.length ? r.runs.map(run => {
      const shown = run.items.filter(i => !['current', 'none', 'wait'].includes(i.outcome));
      return el('details', { class: 'run' }, el('summary', {}, `${fmtWhen(run.started)}${run.fastTrack ? ' (fast track)' : ''}${run.planOnly ? ' (plan only)' : ''} - `,
        el('span', { class: 'pill ' + (run.failed ? 'err' : shown.length ? 'info' : 'ok'), text: run.failed ? `${run.failed} failed` : shown.length ? `${shown.length} to look at` : 'nothing to do' })),
        el('ul', {}, ...run.items.map(i => el('li', {}, el('b', { text: i.app === '(all)' ? 'All apps' : i.app }), ' ', el('span', { class: 'pill ' + (cls[i.outcome] || 'muted'), text: i.outcome }), ' ' + i.text))));
    }) : [el('p', { class: 'muted', text: 'No run yet.' })]));
}
// "03:00" as this browser writes times - the same form the time field next to it shows (12- or 24-hour).
// The server's clock in another time zone than this browser: the run's time is the server's - said so, with its offset.
function serverTimeNote(sch) {
  if (sch.offsetMinutes == null || -new Date().getTimezoneOffset() === sch.offsetMinutes) return '';
  const m = Math.abs(sch.offsetMinutes), sign = sch.offsetMinutes < 0 ? '-' : '+';
  return ` server time (UTC${sign}${Math.floor(m / 60)}${m % 60 ? ':' + String(m % 60).padStart(2, '0') : ''})`;
}
function showTime(hhmm) { const m = /^(\d{1,2}):(\d{2})$/.exec(String(hhmm || '')); if (!m) return hhmm; const d = new Date(); d.setHours(+m[1], +m[2], 0, 0); return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }); }
$('btnRunReload').addEventListener('click', loadUpdateRuns);
$('btnReports').addEventListener('click', () => openFolder('reports-folder'));
for (const [id, planOnly] of [['btnRunNow', false], ['btnRunPlan', true]]) $(id).addEventListener('click', async () => {
  if (!planOnly && !(await ask('Run managed updates now?\n\nAs the nightly run: promotes ready version in pilots and releases new winget versions - each only if its switch is on. It runs in its own window-less process; Reload shows the report.', { ok: 'Run now', danger: false }))) return;
  const r = await api('/api/update-run', { planOnly });
  toast(r.ok ? `${planOnly ? 'Plan-only run' : 'Run'} started - Reload in a minute for its report.` : r.error, !r.ok);
  if (r.ok) setTimeout(loadUpdateRuns, 4000);
});
$('btnSchedule').addEventListener('click', async () => {
  const r = await api('/api/update-schedule', { on: true, runAt: $('runAt').value });
  toast(r.ok ? `Scheduled every day at ${showTime($('runAt').value)}.` : r.error, !r.ok); loadUpdateRuns();
});
$('btnUnschedule').addEventListener('click', async () => {
  if (!(await ask('Remove the scheduled task?\n\nManaged updates then only run when you click Run now.'))) return;
  const r = await api('/api/update-schedule', { on: false });
  toast(r.ok ? 'Scheduled task removed.' : r.error, !r.ok); loadUpdateRuns();
});

// ---------------------------------------------------------------- health, monthly report, running unattended
const healthItem = (level, text) => el('li', { class: 'hl ' + level }, el('span', { class: 'pill ' + (level === 'ok' ? 'ok' : level === 'warn' ? 'warn' : level === 'failed' ? 'err' : 'muted'), text: level === 'ok' ? 'OK' : level === 'warn' ? 'Look' : level === 'failed' ? 'Problem' : 'To do' }), ' ' + text);
$('btnHealth').addEventListener('click', async () => {
  const b = $('btnHealth'); b.disabled = true; $('healthList').hidden = false; $('healthList').replaceChildren(el('li', { class: 'muted', text: 'Checking...' }));
  try {
    const r = await api('/api/health');
    $('healthList').replaceChildren(...(r.ok ? r.checks.map(c => healthItem(c.level, c.text)) : [healthItem('failed', r.error)]));
  } finally { b.disabled = false; }
});
$('btnMonthly').addEventListener('click', async () => {
  const b = $('btnMonthly'); b.disabled = true;
  try {
    const r = await api('/api/monthly-report', {});
    toast(r.ok ? `Report for ${r.month} saved (${r.path})${r.sent.length ? ' and sent (' + r.sent.join(', ') + ')' : ''}.${r.error ? ' Sending failed: ' + r.error : ''}` : r.error, !r.ok || !!r.error);
  } finally { b.disabled = false; }
});
async function loadUnattended() {
  const r = await api('/api/unattended-status');
  if (!r.ok) return;
  $('unattSteps').replaceChildren(...r.steps.map(s => healthItem(s.done ? 'ok' : 'todo', s.text)));
  setEnabled($('btnUnattScript'), r.supported && !r.ready, r.ready ? 'Everything is set already.' : 'Scheduled tasks need Windows.');
}
$('btnUnattReload').addEventListener('click', loadUnattended);
$('btnUnattScript').addEventListener('click', async () => {
  const r = await api('/api/unattended-script', {});
  if (!r.ok) { toast(r.error, true); return; }
  $('unattNote').hidden = false;
  $('unattNote').replaceChildren(`Written to ${r.path}. Open PowerShell with "Run as administrator" and run it once: `, el('code', { text: `& '${r.path.replace(/'/g, "''")}'` }), ' - then Check again.');
});

// ---------------------------------------------------------------- permissions: granted vs used
// From Home, Getting started or a page that hit a missing permission: Settings > Diagnostics, the check run at once.
function checkPermissionsNow() { showSettings('diagnostics'); $('btnPermCheck').click(); $('btnPermCheck').scrollIntoView({ block: 'center' }); }
$('btnPermCheck').addEventListener('click', async () => {
  const b = $('btnPermCheck'); b.disabled = true; $('permNote').textContent = 'Signing in to read the permissions...';
  try {
    const r = await api('/api/permission-check');
    if (!r.ok) { $('permNote').textContent = r.error; return; }
    $('permNote').textContent = r.missing ? `${r.missing} to add, ${r.unused} you could remove.` : r.unused ? `Everything needed is there - ${r.unused} you could remove.` : 'Exactly what this catalog needs.';
    const look = { ok: ['ok', 'OK'], missing: ['err', 'Add it'], partly: ['warn', 'Partly'], unused: ['warn', 'Not needed - remove'], optional: ['muted', 'Optional'] };
    $('permRows').replaceChildren(...r.rows.map(x => el('tr', {}, el('td', { class: 'mono pname' }, ...x.name.split('.').flatMap((p, i, a) => i < a.length - 2 ? [p + '.', el('wbr')] : i < a.length - 1 ? [p + '.'] : [p]), el('div', { class: 'pstat-in' }, el('span', { class: 'pill ' + look[x.status][0], text: look[x.status][1] }))), el('td', { class: 'pstat' }, el('span', { class: 'pill ' + look[x.status][0], text: look[x.status][1] })), el('td', {}, x.for, x.why ? el('div', { class: 'why', text: x.why }) : ''))));
    $('permWrap').hidden = false;
  } finally { b.disabled = false; }
});

// ---------------------------------------------------------------- sign-in (the server version): Sign in with Microsoft
async function loadSignIn() {
  if (!SERVER) return;
  const r = await api('/api/signin-settings');
  if (!r.ok) return;
  $('siEntra').checked = !!r.entra; $('siGroup').value = r.groupName || r.groupId || ''; $('siPassword').checked = r.allowPassword !== false;
  $('siRedirect').value = r.redirectUri || '';
  $('siNow').textContent = r.signedInAs ? `Signed in now: ${r.signedInAs}${r.upn ? ` (${r.upn})` : ''}, ${r.signedInWith === 'entra' ? 'with Microsoft' : 'with the admin password'}.` + (r.forcedPassword ? ' ICA_PASSWORD_SIGNIN is set on the server: the admin password works whatever is chosen here.' : '') : '';
  siShow();
}
function siShow() { const on = $('siEntra').checked; $('siGroup').disabled = !on; $('siPassword').disabled = !on; if (!on) $('siPassword').checked = true; }
$('siEntra').addEventListener('change', siShow);
$('btnSiCopy').addEventListener('click', async () => { try { await navigator.clipboard.writeText($('siRedirect').value); toast('Copied.'); } catch (e) { $('siRedirect').select(); } });
$('btnSiSave').addEventListener('click', async () => {
  $('siError').hidden = true;
  if ($('siEntra').checked && !$('siPassword').checked && !(await ask('Turn the admin password off?\n\nThen only members of the group get in, with Microsoft. If Entra ID or this setting ever fails, the way back in is ICA_PASSWORD_SIGNIN=1 in the server\'s .env (then docker compose up -d app).', { ok: 'Turn it off', danger: true }))) return;
  const b = $('btnSiSave'); b.disabled = true;
  const r = await api('/api/signin-save', { entra: $('siEntra').checked, group: $('siGroup').value.trim(), allowPassword: $('siPassword').checked });
  b.disabled = false;
  if (!r.ok) { $('siError').textContent = r.error; $('siError').hidden = false; return; }
  toast(r.entra ? `Sign in with Microsoft is on for the members of ${r.groupName}.` : 'Only the admin password signs in.');
  loadSignIn();
});
