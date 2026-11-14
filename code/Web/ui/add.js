// Intune App Catalog - web interface: Add apps (winget, an installer, a PowerShell script).
// Loaded after apps.js (openEditor, loadApps, releaseStep, runDialog live there).
'use strict';

let alItems = [], alPicked = new Set();
let addSrc = 'winget', awPicked = new Map(), awTimer = 0, awSeq = 0, aiUpload = null, aiInfo = null, asTemplates = [];
const addLines = id => $(id).value.split('\n').map(s => s.trim()).filter(Boolean);

function openAdd(src, file) {
  $('addError').hidden = true;
  awPicked.clear(); $('awRows').replaceChildren(); $('awQuery').value = ''; $('awNote').textContent = 'Type to search - results appear as you type.';
  $('awDetail').replaceChildren(el('p', { class: 'muted', text: 'Pick a package to see what winget says about it.' }));
  $('awManaged').checked = !!(prefs && prefs.defaults && prefs.defaults.wingetInstallMethod === 'Managed');
  resetInstaller();
  for (const id of ['asName', 'asPublisher', 'asVersion']) $(id).value = '';
  $('asVersion').value = '1.0'; loadScriptTemplates(true);
  $('adRequired').value = ''; $('adAvailable').value = ''; $('adPublish').checked = false;
  alItems = []; alPicked.clear(); $('alRows').replaceChildren(); $('alNote').textContent = ''; $('alAll').checked = false;
  const favs = (prefs && prefs.favoriteGroups) || [];
  $('adFavs').replaceChildren(...(favs.length ? [el('span', { class: 'muted', text: 'Favourites:' }), ...favs.map(g => el('button', { type: 'button', class: 'chip', text: g, title: `Add ${g} to Required for (Shift: Available for)`, onclick: e => addGroup(e.shiftKey ? 'adAvailable' : 'adRequired', g) }))] : []));
  if (!$('dlgAdd').open) $('dlgAdd').showModal();
  showAddSrc(src || 'winget');
  if (file) startUpload(file);
}
function addGroup(id, g) { const l = addLines(id); if (!l.includes(g)) $(id).value = [...l, g].join('\n'); }
function showAddSrc(src) {
  addSrc = src;
  for (const t of document.querySelectorAll('[data-asrc]')) t.setAttribute('aria-selected', String(t.dataset.asrc === src));
  for (const s of ['winget', 'installer', 'script', 'list']) $('asec-' + s).hidden = s !== src;
  updateAddButton();
  (src === 'winget' ? $('awQuery') : src === 'installer' ? $('aiDrop') : src === 'list' ? $('btnAlFile') : $('asName')).focus();
}
for (const t of document.querySelectorAll('[data-asrc]')) t.addEventListener('click', () => showAddSrc(t.dataset.asrc));
function updateAddButton() {
  const b = $('btnAddGo');
  if (addSrc === 'winget') { b.textContent = awPicked.size ? `Add ${awPicked.size} app${awPicked.size === 1 ? '' : 's'}` : 'Add'; setEnabled(b, awPicked.size > 0, 'Tick one or more packages first.'); }
  else if (addSrc === 'installer') { b.textContent = 'Add'; setEnabled(b, !!aiInfo, 'Drop or choose an installer first.'); }
  else if (addSrc === 'list') { b.textContent = alPicked.size ? `Add ${alPicked.size} app${alPicked.size === 1 ? '' : 's'}` : 'Add'; setEnabled(b, alPicked.size > 0, 'Read a list and tick the packages first.'); }
  else { b.textContent = 'Add'; setEnabled(b, !!$('asName').value.trim(), 'Give the app a name first.'); }
}
$('btnAddBlank').addEventListener('click', () => { $('dlgAdd').close(); openEditor(''); });
$('btnAddCancel').addEventListener('click', () => $('dlgAdd').close());
$('dlgAdd').addEventListener('close', () => { if (aiUpload && aiUpload.id && !aiUpload.added) api('/api/upload-cancel', { uploadId: aiUpload.id }); aiUpload = null; });

// ---- winget: search as you type, pick several
$('awQuery').addEventListener('input', () => { clearTimeout(awTimer); awTimer = setTimeout(searchAdd, 450); });
$('awQuery').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); clearTimeout(awTimer); searchAdd(); } });
async function searchAdd() {
  const q = $('awQuery').value.trim();
  if (q.length < 2) { $('awNote').textContent = 'Type at least 2 characters.'; return; }
  const seq = ++awSeq;
  $('awNote').textContent = 'Asking winget...';
  const r = await api('/api/winget-search', { q });
  if (seq !== awSeq) return;   // a newer search is under way
  if (!r.ok) { $('awNote').textContent = r.error; return; }
  const have = new Map(apps.filter(a => a.wingetId).map(a => [a.wingetId.toLowerCase(), a.name]));
  $('awNote').textContent = r.rows.length ? `${r.rows.length} package(s)${awPicked.size ? ` - ${awPicked.size} picked` : ''}.` : 'winget found nothing - try a shorter name or the publisher.';
  $('awRows').replaceChildren(...r.rows.map(x => {
    const inCat = have.get(x.id.toLowerCase());
    const box = el('input', { type: 'checkbox', 'aria-label': `Pick ${x.name}`, disabled: !!inCat });
    box.checked = awPicked.has(x.id);
    const tr = el('tr', { class: inCat ? 'dim' : '' },
      el('td', { class: 'chk' }, box),
      el('td', {}, x.name, inCat ? el('span', { class: 'pill muted newer', text: 'in the catalog', title: `Already in the catalog as ${inCat}` }) : ''),
      el('td', { class: 'mono', text: x.id }), el('td', { text: x.version }));
    const pick = on => { if (inCat) return; if (on) awPicked.set(x.id, x); else awPicked.delete(x.id); box.checked = on; tr.classList.toggle('sel', on); updateAddButton(); };
    box.addEventListener('change', () => { pick(box.checked); showWingetDetail(x); });
    tr.addEventListener('click', e => { if (e.target !== box) { pick(!awPicked.has(x.id)); showWingetDetail(x); } });
    if (awPicked.has(x.id)) tr.classList.add('sel');
    return tr;
  }));
}
let awDetailSeq = 0;
async function showWingetDetail(x) {
  const seq = ++awDetailSeq;
  $('awDetail').replaceChildren(el('h3', { text: x.name }), el('p', { class: 'muted', text: 'Reading winget show...' }));
  const r = await api('/api/winget-details', { id: x.id });
  if (seq !== awDetailSeq) return;
  if (!r.ok) { $('awDetail').replaceChildren(el('h3', { text: x.name }), el('p', { class: 'muted', text: r.error })); return; }
  const d = r.details, row = (k, v) => v ? el('div', { class: 'kv' }, el('span', { class: 'k', text: k }), el('span', { text: v })) : '';
  $('awDetail').replaceChildren(el('h3', { text: d.Name || x.name }), d.Description ? el('p', { text: d.Description }) : '',
    row('Publisher', d.Publisher), row('Version', d.Version), row('ID', d.Id), row('License', d.License), row('Homepage', d.Homepage), row('Tags', (d.Tags || []).slice(0, 8).join(', ')));
}

// ---- an installer: drop, upload in pieces, review
function resetInstaller() {
  aiInfo = null; aiUpload = null;
  $('aiReview').hidden = true; $('aiProgress').hidden = true; $('aiDrop').hidden = false; $('aiFile').value = '';
}
$('aiDrop').addEventListener('click', () => $('aiFile').click());
$('aiDrop').addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); $('aiFile').click(); } });
$('aiFile').addEventListener('change', () => { if ($('aiFile').files[0]) startUpload($('aiFile').files[0]); });
for (const ev of ['dragenter', 'dragover']) $('aiDrop').addEventListener(ev, e => { e.preventDefault(); $('aiDrop').classList.add('over'); });
for (const ev of ['dragleave', 'drop']) $('aiDrop').addEventListener(ev, () => $('aiDrop').classList.remove('over'));
$('aiDrop').addEventListener('drop', e => { e.preventDefault(); const f = e.dataTransfer.files[0]; if (f) startUpload(f); });
const b64 = buf => { let s = ''; const a = new Uint8Array(buf); for (let i = 0; i < a.length; i += 0x8000) s += String.fromCharCode.apply(null, a.subarray(i, i + 0x8000)); return btoa(s); };
async function startUpload(file) {
  $('addError').hidden = true;
  if (!/\.(msi|exe)$/i.test(file.name)) { showAddError('Drop an .msi or .exe installer.'); return; }
  const st = await api('/api/upload-start', { fileName: file.name, size: file.size });
  if (!st.ok) { showAddError(st.error); return; }
  aiUpload = { id: st.uploadId, added: false };
  $('aiDrop').hidden = true; $('aiProgress').hidden = false; $('aiReview').hidden = true;
  const piece = 3 * 1024 * 1024;
  for (let off = 0; off < file.size; off += piece) {
    if (!aiUpload || aiUpload.id !== st.uploadId) return;   // closed meanwhile
    const data = b64(await file.slice(off, off + piece).arrayBuffer());
    const r = await api('/api/upload-chunk', { uploadId: st.uploadId, offset: off, data });
    if (!r.ok) { showAddError(r.error); resetInstaller(); return; }
    const pct = Math.round(100 * r.received / file.size);
    $('aiBar').style.width = pct + '%'; $('aiProgressText').textContent = `Uploading ${file.name} - ${pct} %`;
  }
  $('aiProgressText').textContent = `Reading ${file.name}...`;
  const f = await api('/api/upload-finish', { uploadId: st.uploadId });
  if (!f.ok) { showAddError(f.error); resetInstaller(); return; }
  aiInfo = f;
  $('aiProgress').hidden = true; $('aiReview').hidden = false;
  const kinds = { inno: 'Inno Setup', nsis: 'NSIS', burn: 'WiX bundle', installshield: 'InstallShield', advanced: 'Advanced Installer' };
  $('aiFacts').textContent = `${f.fileName} (${(f.size / 1048576).toFixed(1)} MB) - ${f.kind === 'msi' ? 'Windows Installer package' : 'setup program' + (f.exeKind ? ' made with ' + kinds[f.exeKind] : '')}${f.signer ? ', signed by ' + f.signer.replace(/^CN=([^,]+).*$/, '$1') : ', not signed'}.`;
  $('aiName').value = f.name; $('aiPublisher').value = f.publisher; $('aiVersion').value = f.version;
  $('aiInstall').value = f.installCommand; $('aiUninstall').value = f.uninstallCommand;
  $('aiDetection').value = f.detection === 'Msi' ? `MSI product code ${f.productCode}${f.version ? ', version ' + f.version + ' or newer' : ''}` : f.detection === 'Script' ? 'A script: the name and version Windows lists' : 'Nothing yet - set it in the editor';
  $('aiNotes').replaceChildren(...[...(f.nameProblem ? [f.nameProblem + ' Change the name.'] : []), ...f.notes].map(n => el('li', { text: n })));
  $('aiManagedRow').hidden = !f.managedOk; $('aiManaged').checked = false;
  updateAddButton(); $('aiName').focus();
}
function showAddError(t) { $('addError').textContent = t; $('addError').hidden = false; }

// ---- a PowerShell script app
async function loadScriptTemplates(keepText) {
  const r = await api('/api/script-templates', { name: $('asName').value.trim() || 'My app', version: $('asVersion').value.trim() });
  if (!r.ok) return;
  asTemplates = r.templates;
  const cur = $('asTemplate').value || 'installer';
  $('asTemplate').replaceChildren(...asTemplates.map(t => el('option', { value: t.id, text: t.label })));
  $('asTemplate').value = asTemplates.some(t => t.id === cur) ? cur : asTemplates[0].id;
  if (!keepText || !$('asInstall').value) applyTemplate();
}
function applyTemplate() { const t = asTemplates.find(x => x.id === $('asTemplate').value); if (t) { $('asInstall').value = t.install; $('asUninstall').value = t.uninstall; } }
$('asTemplate').addEventListener('change', applyTemplate);
let asTimer = 0, asTouched = false;
$('asInstall').addEventListener('input', () => { asTouched = true; });
// The template follows the name and version until the scripts are edited by hand.
for (const id of ['asName', 'asVersion']) $(id).addEventListener('input', () => { updateAddButton(); if (!asTouched) { clearTimeout(asTimer); asTimer = setTimeout(() => loadScriptTemplates(false), 300); } });
for (const r of document.querySelectorAll('input[name="asDetect"]')) r.addEventListener('change', () => { $('asDetectScript').hidden = document.querySelector('input[name="asDetect"]:checked').value !== 'script'; });

// ---- Add
$('btnAddGo').addEventListener('click', async () => {
  const b = $('btnAddGo'); b.disabled = true; $('addError').hidden = true;
  const groups = { requiredFor: addLines('adRequired'), availableFor: addLines('adAvailable') };
  const publish = $('adPublish').checked;
  try {
    if (addSrc === 'winget' || addSrc === 'list') {
      const items = addSrc === 'winget' ? [...awPicked.values()].map(x => ({ id: x.id, name: x.name, version: x.version })) : [...alPicked].map(id => ({ id }));
      const note = addSrc === 'winget' ? 'awNote' : 'alNote', added = [], skipped = [];
      // Five at a time: each asks winget for its details, and the page shows how far it got.
      for (let i = 0; i < items.length; i += 5) {
        $(note).textContent = `Adding ${Math.min(i + 5, items.length)} of ${items.length} - reading each one's details from winget...`;
        const r = await api('/api/add-winget', { items: items.slice(i, i + 5), managed: addSrc === 'winget' && $('awManaged').checked, ...groups });
        if (!r.ok) { showAddError(r.error); break; }
        added.push(...r.added); skipped.push(...r.skipped);
      }
      if (!added.length && !skipped.length) return;
      $('dlgAdd').close(); await afterAdd(added);
      toast(`${added.length} app(s) added${skipped.length ? ' - skipped: ' + skipped.join('; ') : ''}.`, !added.length);
    }
    else if (addSrc === 'installer') {
      const r = await api('/api/add-installer', { uploadId: aiUpload.id, name: $('aiName').value.trim(), publisher: $('aiPublisher').value.trim(), version: $('aiVersion').value.trim(),
        installCommand: $('aiInstall').value.trim(), uninstallCommand: $('aiUninstall').value.trim(), managed: $('aiManaged').checked, ...groups });
      if (!r.ok) { showAddError(r.error); return; }
      aiUpload.added = true;
      const build = $('aiBuild').checked;
      $('dlgAdd').close(); await afterAdd([r.name]);
      toast(`${r.name} added - its installer is in ${r.folder}.`);
      if (build || publish) { if (!(await buildAdded(r.name))) return; }
    }
    else {
      const custom = document.querySelector('input[name="asDetect"]:checked').value === 'script';
      const r = await api('/api/add-script', { name: $('asName').value.trim(), publisher: $('asPublisher').value.trim(), version: $('asVersion').value.trim(),
        install: $('asInstall').value, uninstall: $('asUninstall').value, detectScript: custom ? $('asDetectScript').value : '', ...groups });
      if (!r.ok) { showAddError(r.error); return; }
      $('dlgAdd').close(); await afterAdd([r.name]);
      toast(`${r.name} added - Install.ps1 and Uninstall.ps1 are in ${r.folder}.${publish ? '' : ' Build its package, then Deploy.'}`);
      if (publish && !(await buildAdded(r.name))) return;
    }
  } finally { updateAddButton(); }
});
async function afterAdd(names) {
  await loadApps();
  if (names.length) { selected.clear(); for (const n of names) selected.add(n); lastClicked = names[names.length - 1]; renderApps(); updateViewButtons(); }
  // Deploy right after adding: the Deploy dialog for them (own packages are built first, by their flow).
  if (names.length && $('adPublish').checked && addSrc !== 'installer' && addSrc !== 'script') setTimeout(() => openDeploy(names), 300);
}
// Builds an own package just added; with "Deploy right after adding", the Deploy dialog follows. Resolves with whether it built.
async function buildAdded(name) {
  runDialog(`Build ${name}`, 'Packaging it as an .intunewin for Intune.');
  const p = await releaseStep({ names: [name] }, '/api/package-start', 'runLog', `Building ${name}'s package...`);
  toast(p.ok ? `${name}'s package is built${$('adPublish').checked ? '' : ' - Deploy is next'}.` : `Building the package failed: ${p.error || 'see the log'}`, !p.ok);
  await loadApps();
  if (p.ok && $('adPublish').checked) { $('dlgRun').close(); openDeploy([name]); }
  return p.ok;
}

// ---- from a list: a winget export file, or this PC's apps
async function readList(body) {
  $('alNote').textContent = body.thisPc ? 'Running winget export here - this can take a minute...' : 'Reading the list...';
  const r = await api('/api/package-list', body);
  if (!r.ok) { $('alNote').textContent = r.error; return; }
  alItems = r.items; alPicked = new Set(r.items.filter(x => !x.inCatalog).map(x => x.id));
  $('alNote').textContent = `${r.items.length} package(s) - ${r.items.filter(x => x.inCatalog).length} already in the catalog.`;
  $('alAll').checked = alPicked.size > 0;
  renderList(); updateAddButton();
}
function renderList() {
  $('alRows').replaceChildren(...alItems.map(x => {
    const box = el('input', { type: 'checkbox', 'aria-label': `Pick ${x.id}`, disabled: !!x.inCatalog });
    box.checked = alPicked.has(x.id);
    box.addEventListener('change', () => { if (box.checked) alPicked.add(x.id); else alPicked.delete(x.id); updateAddButton(); });
    return el('tr', { class: x.inCatalog ? 'dim' : '' }, el('td', { class: 'chk' }, box), el('td', { class: 'mono', text: x.id }), el('td', { text: x.inCatalog || '-' }));
  }));
}
$('alAll').addEventListener('change', () => { alPicked = new Set($('alAll').checked ? alItems.filter(x => !x.inCatalog).map(x => x.id) : []); renderList(); updateAddButton(); });
$('btnAlFile').addEventListener('click', () => $('alFile').click());
$('alFile').addEventListener('change', async () => { const f = $('alFile').files[0]; if (!f) return; if (f.size > 5 * 1048576) { $('alNote').textContent = 'That file is too large.'; return; } readList({ json: await f.text() }); $('alFile').value = ''; });
$('btnAlThisPc').addEventListener('click', () => readList({ thisPc: true }));

// Dropping an installer anywhere on the Apps page starts Add apps with it.
document.addEventListener('dragover', e => { if (!$('viewApps').hidden && [...(e.dataTransfer.items || [])].some(i => i.kind === 'file')) e.preventDefault(); });
document.addEventListener('drop', e => {
  if ($('dlgAdd').open || $('viewApps').hidden) return;
  const f = e.dataTransfer && e.dataTransfer.files[0];
  if (f && /\.(msi|exe)$/i.test(f.name)) { e.preventDefault(); openAdd('installer', f); }
});
