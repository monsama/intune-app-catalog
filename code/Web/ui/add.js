// Intune App Catalog - web interface: Add apps (winget, an installer, a PowerShell script).
// Loaded after apps.js (openEditor, loadApps, releaseStep, runDialog live there).
'use strict';

let alItems = [], alPicked = new Set();
let addExclude = [];   // a profile's excluded groups (no field of their own in the dialog - the summary says them)
let addSrc = 'winget', awPickedBy = { winget: new Map(), store: new Map() }, awPicked = awPickedBy.winget, awTimer = 0, awSeq = 0, aiUpload = null, aiInfo = null, asTemplates = [];
const addLines = id => $(id).value.split('\n').map(s => s.trim()).filter(Boolean);

function openAdd(src, file) {
  if (wcResume('dlgAdd')) return;
  $('addError').hidden = true;
  awPickedBy.winget.clear(); awPickedBy.store.clear(); $('awRows').replaceChildren(); $('awQuery').value = ''; $('awNote').textContent = 'Type to search - results appear as you type.';
  $('awDetail').replaceChildren(el('p', { class: 'muted', text: 'Pick a package to see what winget says about it.' }));
  $('awManaged').checked = !!(prefs && prefs.defaults && prefs.defaults.wingetInstallMethod === 'Managed');
  $('alManaged').checked = $('awManaged').checked;
  resetInstaller();
  for (const id of ['asName', 'asPublisher', 'asVersion']) $(id).value = '';
  $('asVersion').value = '1.0'; loadScriptTemplates(true);
  $('adRequired').value = ''; $('adAvailable').value = ''; addExclude = [];
  // The default profile's groups (Settings > Apps & defaults), filled in for every new app - changeable here.
  const dp = defaultProfile();
  if (dp) { mergeLines('adRequired', dp.required); mergeLines('adAvailable', dp.available); addExclude = [...dp.exclude]; }
  $('adRequired').dispatchEvent(new Event('input')); $('adAvailable').dispatchEvent(new Event('input'));
  document.querySelector('#dlgAdd .addgroups').classList.add('folded'); addGroupsSummary();
  alItems = []; alPicked.clear(); $('alRows').replaceChildren(); $('alNote').textContent = ''; $('alAll').checked = false;
  const favs = (prefs && prefs.favoriteGroups) || [];
  $('adFavs').replaceChildren(...(favs.length ? [el('span', { class: 'muted', text: 'Favourites:' }), ...favs.map(g => el('button', { type: 'button', class: 'chip', text: g, title: `Add ${g} to Required for (Shift: Available for)`, onclick: e => addGroup(e.shiftKey ? 'adAvailable' : 'adRequired', g) }))] : []));
  if (!$('dlgAdd').open) $('dlgAdd').showModal();
  // Opened without a kind (the Add apps button): on the kind added last time.
  let last = ''; try { last = localStorage.getItem('addLastSrc') || ''; } catch (e) { }
  showAddSrc(src || (['winget', 'store', 'installer', 'script', 'psadt', 'list'].includes(last) ? last : 'winget'));
  if (file) startUpload(file);
}
// Who gets the new apps, as one line (2.31.0) - Choose brings out the profile, the groups and the favourites.
document.querySelector('#dlgAdd .addgroups').prepend(el('div', { class: 'foldsum', id: 'adSum' }, el('span', { class: 'fstext' }),
  el('button', { type: 'button', class: 'btn small', text: 'Choose', 'aria-label': 'Choose who gets the new apps', onclick: () => { document.querySelector('#dlgAdd .addgroups').classList.remove('folded'); ($('adRequiredChips') || $('adRequired')).focus(); } })));
function addGroupsSummary() {
  const r = addLines('adRequired'), a = addLines('adAvailable'), list = l => l.length > 3 ? `${l.slice(0, 3).join(', ')} and ${l.length - 3} more` : l.join(', ');
  const dp = defaultProfile();
  // Nobody gets it: no exclusions either (2.38.0) - a profile's excluded groups had no way to be taken off again.
  if (!r.length && !a.length) addExclude = [];
  $('adSum').querySelector('.fstext').textContent = 'Who gets it: ' + (r.length || a.length ? [r.length ? `required for ${list(r)}` : '', a.length ? `available for ${list(a)}` : '', addExclude.length ? `not ${list(addExclude)}` : ''].filter(Boolean).join(' · ') : 'nobody yet - you can choose later in the editor') +
    (dp && r.join() === dp.required.join() && a.join() === dp.available.join() ? ` (the "${dp.name}" profile)` : '');
}
for (const id of ['adRequired', 'adAvailable']) { $(id).addEventListener('input', addGroupsSummary); $(id).addEventListener('change', addGroupsSummary); }
function addGroup(id, g) { const l = addLines(id); if (!l.includes(g)) $(id).value = [...l, g].join('\n'); }
// 2.38.13: Microsoft Store - the Winget search's table and detail pane, asking the Store's catalog instead.
let awMode = 'winget';
function setSearchMode(mode) {
  if (awMode === mode) return;
  // Each tab keeps its own picks (back on Winget, what was ticked there still is); a reply for the other tab is dropped.
  awMode = mode; awPicked = awPickedBy[mode] || (awPickedBy[mode] = new Map()); ++awSeq; ++awDetailSeq; $('awRows').replaceChildren(); clearTimeout(awTimer);
  const store = mode === 'store';
  $('awQuery').placeholder = store ? 'Search the Microsoft Store - app name or publisher (e.g. Company Portal, WhatsApp)' : 'Search winget - name, publisher or ID (e.g. 7-Zip, Mozilla, Notepad++)';
  $('awQuery').setAttribute('aria-label', store ? 'Search the Microsoft Store' : 'Search winget');
  $('awColLast').textContent = store ? 'Publisher' : 'Version'; $('awColName').textContent = store ? 'App' : 'Package';
  $('awWrap').setAttribute('aria-label', store ? 'Microsoft Store apps' : 'Winget packages');
  $('awManagedRow').hidden = store; $('awStoreNote').hidden = !store;
  $('awNote').textContent = 'Type to search - results appear as you type.';
  $('awDetail').replaceChildren(el('p', { class: 'muted', text: store ? 'Pick an app to see its Store page.' : 'Pick a package to see what winget says about it.' }));
  if ($('awQuery').value.trim().length >= 2) searchAdd();
}
function showAddSrc(src) {
  addSrc = src;
  for (const t of document.querySelectorAll('[data-asrc]')) t.setAttribute('aria-selected', String(t.dataset.asrc === src));
  const sec = src === 'store' ? 'winget' : src;
  for (const s of ['winget', 'office', 'installer', 'script', 'psadt', 'list']) $('asec-' + s).hidden = s !== sec;
  if (src === 'office') aoShow();
  if (sec === 'winget') { setSearchMode(src); $('asec-winget').setAttribute('aria-labelledby', 'atab-' + src); }
  updateAddButton();
  (sec === 'winget' ? $('awQuery') : src === 'office' ? $('aoChannel') : src === 'installer' ? $('aiDrop') : src === 'list' ? $('btnAlFile') : src === 'psadt' ? $('apName') : $('asName')).focus();
}
for (const t of document.querySelectorAll('[data-asrc]')) t.addEventListener('click', () => showAddSrc(t.dataset.asrc));
function updateAddButton() {
  const b = $('btnAddGo');
  // The button names what it adds: only the open tab counts - what is filled in on the other tabs is left as it is.
  if (addSrc === 'winget' || addSrc === 'store') { const kind = addSrc === 'store' ? 'Store' : 'Winget'; b.textContent = awPicked.size ? `Add ${awPicked.size} ${kind} app${awPicked.size === 1 ? '' : 's'}` : `Add ${kind} apps`; setEnabled(b, awPicked.size > 0, 'Tick one or more first.'); }
  else if (addSrc === 'installer') { b.textContent = 'Add installer'; const d = aiInfo ? aiDetection() : null; setEnabled(b, !!aiInfo && !(d && d.error), !aiInfo ? 'Drop or choose an installer first.' : (d && d.error) || ''); }
  else if (addSrc === 'office') { const have = apps.find(a => a.office && !a.wingetId); b.textContent = 'Add Microsoft 365 Apps'; setEnabled(b, !have && !!$('aoName').value.trim() && [...document.querySelectorAll('[data-aoapp]')].some(c => c.checked), have ? `${have.name} is Microsoft 365 Apps already - change its settings in the editor.` : 'Give it a name and keep at least one app.'); }
  else if (addSrc === 'psadt') { b.textContent = 'Add PSADT app'; setEnabled(b, !!($('apName').value.trim() && $('apVersion').value.trim()), 'Give the app a name and the version you are packaging.'); }
  else if (addSrc === 'list') { b.textContent = alPicked.size ? `Add ${alPicked.size} from the list` : 'Add from the list'; setEnabled(b, alPicked.size > 0, 'Read a list and tick the packages first.'); }
  else { b.textContent = 'Add script app'; setEnabled(b, !!$('asName').value.trim(), 'Give the app a name first.'); }
  const nameField = { installer: 'aiName', script: 'asName', psadt: 'apName', office: 'aoName' }[addSrc];
  if (nameField && !b.disabled && catalogTwin($(nameField).value)) setEnabled(b, false, 'An app of that name is in the catalog - choose another name.');
  // Add and send follows Add - same condition, and the same kind of thing.
  // Sending needs the connection: without it, Add alone (it would build, then stop at "set up the connection").
  const conn = !!(state && state.configured);
  // Add and send needs a detection rule (Intune won't take an app without one): the proposal or one chosen here.
  const noRule = addSrc === 'installer' && aiInfo && $('aiDetType').value === 'proposed' && !aiProposal;
  setEnabled($('btnAddSend'), !b.disabled && conn && !noRule, b.disabled ? b.title : noRule ? 'Choose how Intune detects it first (Detected by) - Add alone works, and the editor sets it later.' : 'Set up the connection to Intune first (Settings > Connection).');
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
  const mode = awMode;
  $('awNote').textContent = mode === 'store' ? 'Asking the Microsoft Store...' : 'Asking winget...';
  const r = await api(mode === 'store' ? '/api/store-search' : '/api/winget-search', { q });
  if (mode !== awMode) return;
  if (seq !== awSeq) return;   // a newer search is under way
  if (!r.ok) { $('awNote').textContent = r.error; return; }
  const have = new Map(apps.filter(a => a.wingetId).map(a => [a.wingetId.toLowerCase(), a.name]));
  $('awNote').textContent = r.rows.length ? `${r.rows.length} ${mode === 'store' ? 'app' : 'package'}(s)${awPicked.size ? ` - ${awPicked.size} picked` : ''}.` : (mode === 'store' ? 'The Store found nothing - try a shorter name.' : 'winget found nothing - try a shorter name or the publisher.');
  $('awRows').replaceChildren(...r.rows.map(x => {
    const inCat = have.get(x.id.toLowerCase());
    // Already in Intune by its name, and not linked to a catalog app: adding is fine - sending would make a second one.
    const inIntune = !inCat && intuneTwin(x.name);
    const box = el('input', { type: 'checkbox', 'aria-label': `Pick ${x.name}`, disabled: !!inCat });
    box.checked = awPicked.has(x.id);
    const tr = el('tr', { class: inCat ? 'dim' : '' },
      el('td', { class: 'chk' }, box),
      el('td', {}, x.name, mode !== 'store' && isStoreId(x.id) ? el('span', { class: 'pill info newer', text: 'Store', title: 'A Microsoft Store app: Intune\'s own Store type - no package, the Store installs and updates it' }) : '', inCat ? el('span', { class: 'pill muted newer', text: 'in the catalog', title: `Already in the catalog as ${inCat}` }) : '',
        inIntune ? el('span', { class: 'pill warn newer', text: 'in Intune', title: `An app called "${inIntune.name}" is already in Intune - after adding, link it (Checks) instead of sending a second one` }) : ''),
      el('td', { class: 'mono', text: x.id }), el('td', { text: mode === 'store' ? (x.publisher || '') : x.version }));
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
  // A Store app: what the Store said, and its page - winget's details aren't there for it on every machine.
  if (awMode === 'store') {
    const kv = (k, v) => v ? el('div', { class: 'kv' }, el('span', { class: 'k', text: k }), el('span', { text: v })) : '';
    $('awDetail').replaceChildren(el('h3', { text: x.name }), kv('Publisher', x.publisher), kv('Product ID', x.id),
      el('p', {}, el('a', { href: `https://apps.microsoft.com/detail/${encodeURIComponent(x.id)}`, target: '_blank', rel: 'noopener noreferrer', text: 'Open its Store page' })),
      el('p', { class: 'muted', text: 'Intune installs it from the Store and the Store keeps it up to date.' }));
    return;
  }
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
  aiInfo = null; aiUpload = null; delete $('aiName').dataset.touched; $('aiSetupRow').hidden = true;
  $('aiReview').hidden = true; $('aiProgress').hidden = true; $('aiDrop').hidden = false; $('aiFolderRow').hidden = false; $('aiFile').value = '';
}
$('aiDrop').addEventListener('click', () => $('aiFile').click());
$('aiDrop').addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); $('aiFile').click(); } });
$('aiFile').addEventListener('change', () => { const p = pickFromFiles([...$('aiFile').files]); $('aiFile').value = ''; if (p) startUpload(p); });
$('aiFolder').addEventListener('change', () => { const p = pickFromFolderInput($('aiFolder')); $('aiFolder').value = ''; if (p) startUpload(p); });
$('aiFolderBtn').addEventListener('click', () => $('aiFolder').click());
for (const ev of ['dragenter', 'dragover']) $('aiDrop').addEventListener(ev, e => { e.preventDefault(); $('aiDrop').classList.add('over'); });
for (const ev of ['dragleave', 'drop']) $('aiDrop').addEventListener(ev, () => $('aiDrop').classList.remove('over'));
$('aiDrop').addEventListener('drop', async e => { e.preventDefault(); const p = await pickFromDrop(e.dataTransfer); if (p) startUpload(p); });
const b64 = buf => { let s = ''; const a = new Uint8Array(buf); for (let i = 0; i < a.length; i += 0x8000) s += String.fromCharCode.apply(null, a.subarray(i, i + 0x8000)); return btoa(s); };
// ---- the same app twice (2.35.0): a name already in the catalog, or an app of that name in Intune not linked to one.
function intuneTwin(name) {
  const n = String(name || '').trim().toLowerCase(); if (!n || !intuneApps) return null;
  const linked = new Set(apps.filter(a => a.appId).map(a => String(a.appId).toLowerCase()));
  return intuneApps.find(i => String(i.name || '').trim().toLowerCase() === n && !linked.has(i.id)) || null;
}
function nameWarning(name) {
  const n = String(name || '').trim(); if (!n) return '';
  const cat = apps.find(a => a.name.toLowerCase() === n.toLowerCase());
  if (cat) return `There's already an app called "${cat.name}" in the catalog - choose another name, or open that one.`;   // with Open it beside it
  const tw = intuneTwin(n);
  return tw ? `An app called "${tw.name}" is already in Intune. Adding is fine - then link it (Checks > Link) instead of sending a second one.` : '';
}
for (const id of ['aiName', 'asName', 'apName']) {
  const inp = $(id), note = el('p', { class: 'namewarn', id: id + 'Warn', role: 'status', hidden: true });
  (inp.closest('label') || inp).after(note);
  // A name the catalog has: Add is off (the server would refuse it), and Open it opens that app (2.38.0).
  const check = () => {
    const w = nameWarning(inp.value), twin = catalogTwin(inp.value);
    note.replaceChildren(w, twin ? ' ' : '', twin ? el('button', { type: 'button', class: 'linkish', text: 'Open it', onclick: () => { $('dlgAdd').close(); openEditor(twin.name); } }) : '');
    note.hidden = !w; updateAddButton();
  };
  inp.addEventListener('input', check); inp.addEventListener('change', check);
}
function catalogTwin(name) { const n = String(name || '').trim().toLowerCase(); return n ? apps.find(a => a.name.toLowerCase() === n) || null : null; }
const nameWarnRefresh = () => { for (const id of ['aiName', 'asName', 'apName']) $(id).dispatchEvent(new Event('change')); };

// ---- uploads (2.34.0): one installer or a .zip of its folder, or a whole folder - in pieces of 3 MB
const PIECE = 3 * 1024 * 1024;
// pick: { file } or { folderName, files: [{ file, path }] } (paths inside the folder). The finished upload's answer, with uploadId.
async function uploadPick(pick, say) {
  const mb = n => fmtMB(n);
  if (pick.file) {
    const f = pick.file;
    const st = await api('/api/upload-start', { fileName: f.name, size: f.size });
    if (!st.ok) return st;
    for (let off = 0; off < f.size; off += PIECE) {
      const r = await api('/api/upload-chunk', { uploadId: st.uploadId, offset: off, data: b64(await f.slice(off, off + PIECE).arrayBuffer()) });
      if (!r.ok) { api('/api/upload-cancel', { uploadId: st.uploadId }); return r; }
      say(`Uploading ${f.name} - ${Math.round(100 * r.received / f.size)} %`, r.received / f.size);
    }
    say(/\.zip$/i.test(f.name) ? `Unpacking ${f.name}...` : `Reading ${f.name}...`);
    const fin = await api('/api/upload-finish', { uploadId: st.uploadId });
    if (!fin.ok) api('/api/upload-cancel', { uploadId: st.uploadId });
    return { ...fin, uploadId: st.uploadId };
  }
  const list = pick.files;
  if (!list.length) return { ok: false, error: 'The folder is empty.' };
  if (list.length > 5000) return { ok: false, error: `The folder holds ${list.length} files - at most 5000 go into one package.` };
  const total = list.reduce((n, x) => n + x.file.size, 0);
  const st = await api('/api/folder-upload-start', { folderName: pick.folderName, files: list.map(x => ({ path: x.path, size: x.file.size })) });
  if (!st.ok) return st;
  let sent = 0;
  for (const [i, x] of list.entries()) {
    for (let off = 0; off < x.file.size; off += PIECE) {
      const piece = x.file.slice(off, off + PIECE);
      const r = await api('/api/upload-chunk', { uploadId: st.uploadId, index: i, offset: off, data: b64(await piece.arrayBuffer()) });
      if (!r.ok) { api('/api/upload-cancel', { uploadId: st.uploadId }); return r; }
      sent += piece.size;
      say(`Uploading ${pick.folderName} - ${Math.round(100 * sent / Math.max(1, total))} % (file ${i + 1} of ${list.length}, ${mb(total)})`, sent / Math.max(1, total));
    }
  }
  say(`Reading ${pick.folderName}...`);
  const fin = await api('/api/upload-finish', { uploadId: st.uploadId });
  if (!fin.ok) api('/api/upload-cancel', { uploadId: st.uploadId });
  return { ...fin, uploadId: st.uploadId };
}
// A folder input's files, with their paths inside the chosen folder (its own name left off).
function pickFromFolderInput(input) {
  const files = [...input.files]; if (!files.length) return null;
  const top = files[0].webkitRelativePath.split('/')[0];
  return { folderName: top, files: files.map(f => ({ file: f, path: f.webkitRelativePath.split('/').slice(1).join('/') })) };
}
// Several files chosen or dropped at once (2.38.18 - only the first one was taken): together, as a folder named after its
// setup file. One file stays one file.
function pickFromFiles(files, extra) {
  const all = [...files.map(f => ({ file: f, path: f.name })), ...(extra || [])];
  if (!all.length) return null;
  if (all.length === 1 && !(extra && extra.length)) return { file: all[0].file };
  const setup = all.find(x => !x.path.includes('/') && /\.(msi|exe)$/i.test(x.path)) || all.find(x => /\.(msi|exe)$/i.test(x.path)) || all[0];
  return { folderName: setup.path.split('/').pop().replace(/\.[^.]+$/, ''), files: all };
}
// What was dropped: a folder (read through its entries, subfolders too), one file - or several files and folders together.
async function pickFromDrop(dt) {
  const entries = [...(dt.items || [])].map(i => (i.webkitGetAsEntry ? i.webkitGetAsEntry() : null)).filter(Boolean);
  if (entries.length === 1 && entries[0].isDirectory) { const files = []; await walkEntry(entries[0], '', files); return { folderName: entries[0].name, files }; }
  if (entries.length > 1) {
    const files = [], sub = [];
    for (const e of entries) {
      if (e.isDirectory) await walkEntry(e, e.name + '/', sub);
      else files.push(await new Promise((res, rej) => e.file(res, rej)));
    }
    return pickFromFiles(files, sub);
  }
  const f = dt.files && dt.files[0]; return f ? { file: f } : null;
}
async function walkEntry(dir, prefix, out) {
  const reader = dir.createReader(); let batch;
  do {
    batch = await new Promise((res, rej) => reader.readEntries(res, rej));
    for (const e of batch) {
      if (e.isDirectory) await walkEntry(e, prefix + e.name + '/', out);
      else out.push({ file: await new Promise((res, rej) => e.file(res, rej)), path: prefix + e.name });
    }
  } while (batch.length);
}
const isPickable = pick => !!pick && (pick.files ? pick.files.length > 0 : /\.(msi|exe|zip)$/i.test(pick.file.name));
const fmtMB = n => n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB';

// ---- Add apps > Installer: an installer, a .zip or a folder
async function startUpload(pick) {
  if (pick instanceof File) pick = { file: pick };
  $('addError').hidden = true;
  if (!isPickable(pick)) { showAddError('Drop an .msi or .exe installer, a .zip of its folder, the folder itself - or several files at once.'); return; }
  $('aiDrop').hidden = true; $('aiFolderRow').hidden = true; $('aiProgress').hidden = false; $('aiReview').hidden = true;
  const token = {}; aiUpload = { id: '', added: false, token };
  const f = await uploadPick(pick, (t, frac) => { if (aiUpload && aiUpload.token === token) { $('aiProgressText').textContent = t; if (frac !== undefined) $('aiBar').style.width = Math.round(100 * frac) + '%'; } });
  if (!aiUpload || aiUpload.token !== token) { if (f.uploadId) api('/api/upload-cancel', { uploadId: f.uploadId }); return; }   // closed meanwhile
  aiUpload.id = f.uploadId || '';
  if (!f.ok) { showAddError(f.error); resetInstaller(); return; }
  showUploadReview(f);
}
function showUploadReview(f) {
  aiInfo = f;
  $('aiProgress').hidden = true; $('aiReview').hidden = false;
  const kinds = { inno: 'Inno Setup', nsis: 'NSIS', burn: 'WiX bundle', installshield: 'InstallShield', advanced: 'Advanced Installer' };
  const what = f.kind === 'msi' ? 'Windows Installer package' : f.kind === 'exe' ? 'setup program' + (f.exeKind ? ' made with ' + kinds[f.exeKind] : '') : '';
  $('aiFacts').textContent = f.folder
    ? `${f.fileName}: ${f.fileCount} file${f.fileCount === 1 ? '' : 's'}, ${fmtMB(f.size)} - all of them go into the package.${what ? ` Its setup file is a ${what}${f.signer ? ', signed by ' + f.signer.replace(/^CN=([^,]+).*$/, '$1') : ''}.` : ''}`
    : `${f.fileName} (${fmtMB(f.size)}) - ${what}${f.signer ? ', signed by ' + f.signer.replace(/^CN=([^,]+).*$/, '$1') : ', not signed'}.`;
  // A folder: which of its files is the setup file (suggested; another one makes the proposal again).
  $('aiSetupRow').hidden = !f.folder;
  if (f.folder) $('aiSetup').replaceChildren(el('option', { value: '', text: '(none - I write the commands)' }), ...(f.candidates || []).map(c => el('option', { value: c, text: c })));
  if (f.folder) $('aiSetup').value = f.setup || '';
  if (!$('aiName').dataset.touched) $('aiName').value = f.name;
  nameWarnRefresh();
  $('aiPublisher').value = f.publisher; $('aiVersion').value = f.version;
  $('aiInstall').value = f.installCommand; $('aiUninstall').value = f.uninstallCommand;
  // Detected by (2.38.18): the proposal - or a file or registry value of your own, right here.
  aiProposal = f.detection === 'Msi' ? `MSI product code ${f.productCode}${f.version ? ', version ' + f.version + ' or newer' : ''}` : f.detection === 'Script' ? 'A script: the name and version Windows lists' : '';
  $('aiDetProposed').textContent = aiProposal ? `Proposed: ${aiProposal}` : 'Nothing proposed - choose a file or a registry value';
  $('aiDetType').value = aiProposal ? 'proposed' : (f.exeKind === 'inno' ? 'registry' : 'file');
  for (const id of ['aiDetFolder', 'aiDetFileName', 'aiDetKey', 'aiDetVersion']) $(id).value = '';
  $('aiDetValue').value = 'DisplayVersion'; $('aiDetCheck').value = f.version ? 'version' : 'exists'; $('aiDetVersion').value = f.version || ''; $('aiDet32').checked = false;
  // Inno Setup lists itself under Uninstall\<its AppId>_is1 - the key to fill in (the AppId is in the registry after a test install).
  if (f.exeKind === 'inno') $('aiDetKey').value = 'HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{AppId}_is1';
  aiDetShow();
  $('aiNotes').replaceChildren(...[...(f.nameProblem ? [f.nameProblem + ' Change the name.'] : []), ...f.notes].map(n => el('li', { text: n })));
  $('aiManagedRow').hidden = !f.managedOk; $('aiManaged').checked = !!f.managedOk;
  updateAddButton(); $('aiName').focus();
}
$('aiSetup').addEventListener('change', async () => {
  if (!aiUpload || !aiUpload.id) return;
  const r = await api('/api/upload-setup', { uploadId: aiUpload.id, setup: $('aiSetup').value });
  if (!r.ok) { showAddError(r.error); return; }
  showUploadReview({ ...r, uploadId: aiUpload.id });
});
$('aiName').addEventListener('input', () => { $('aiName').dataset.touched = '1'; });
let aiProposal = '';
function aiDetShow() {
  const t = $('aiDetType').value;
  $('aiDetBox').hidden = t === 'proposed'; $('aiDetFile').hidden = t !== 'file'; $('aiDetReg').hidden = t !== 'registry';
  $('aiDetVersion').hidden = $('aiDetCheck').value !== 'version';
  $('aiDetHint').textContent = t === 'registry' ? (aiInfo && aiInfo.exeKind === 'inno' ? 'Inno Setup: replace {AppId} with the key name a test install made (HKLM\\...\\Uninstall, ends in _is1) and tick 32-bit if it is under WOW6432Node.' : 'Tick 32-bit for a key under WOW6432Node - write it without that part.')
    : t === 'file' ? 'The program file the setup puts there. For a 32-bit app in Program Files (x86), tick 32-bit.' : '';
  updateAddButton();
}
for (const id of ['aiDetType', 'aiDetCheck']) $(id).addEventListener('change', aiDetShow);
for (const id of ['aiDetFolder', 'aiDetFileName', 'aiDetKey', 'aiDetValue', 'aiDetVersion']) $(id).addEventListener('input', updateAddButton);
// The detection rule chosen here, as the catalog keeps it - null for the proposal; { error } when something is missing.
function aiDetection() {
  const t = $('aiDetType').value; if (t === 'proposed') return null;
  const ver = $('aiDetCheck').value === 'version', v = $('aiDetVersion').value.trim(), b32 = $('aiDet32').checked;
  if (ver && !v) return { error: 'Give the version to check against.' };
  if (t === 'file') {
    const folder = $('aiDetFolder').value.trim(), file = $('aiDetFileName').value.trim();
    if (!folder || !file) return { error: 'Give the folder and the file Intune looks for.' };
    return { Type: 'File', File_Path: folder, File_Name: file, File_Check32Bit: b32, File_DetectionType: ver ? 'version' : 'exists', File_Operator: ver ? 'greaterThanOrEqual' : 'notConfigured', File_DetectionValue: ver ? v : '' };
  }
  const key = $('aiDetKey').value.trim(), val = $('aiDetValue').value.trim();
  if (!key || /\{AppId\}/i.test(key)) return { error: 'Give the registry key (replace {AppId} with the real key name).' };
  if (ver && !val) return { error: 'A version is read from a value - give its name (e.g. DisplayVersion).' };
  return { Type: 'Registry', Reg_KeyPath: key, Reg_ValueName: val, Reg_Check32Bit: b32, Reg_DetectionType: ver ? 'version' : 'exists', Reg_Operator: ver ? 'greaterThanOrEqual' : 'notConfigured', Reg_DetectionValue: ver ? v : '' };
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
for (const id of ['apName', 'apVersion']) $(id).addEventListener('input', updateAddButton);
for (const id of ['asName', 'asVersion']) $(id).addEventListener('input', () => { updateAddButton(); if (!asTouched) { clearTimeout(asTimer); asTimer = setTimeout(() => loadScriptTemplates(false), 300); } });
for (const r of document.querySelectorAll('input[name="asDetect"]')) r.addEventListener('change', () => { $('asDetectScript').hidden = document.querySelector('input[name="asDetect"]:checked').value !== 'script'; });

// ---- Microsoft 365 Apps (2.38.24): the editor's settings, here before it is added - one per catalog.
$('aoChannel').replaceChildren(...officeChannels.map(([v, t]) => el('option', { value: v, text: t })));
$('aoApps').replaceChildren(...officeApps.map(([k, t]) => el('label', { class: 'chk' }, el('input', { type: 'checkbox', 'data-aoapp': k }), t)));
function aoReset() {
  const d = officeDefaults();
  $('aoName').value = 'Microsoft 365 Apps'; $('aoChannel').value = d.channel; $('aoArch').value = d.architecture; $('aoLocales').value = '';
  for (const c of document.querySelectorAll('[data-aoapp]')) c.checked = !d.excluded.includes(c.dataset.aoapp);
  $('aoRemoveOlder').checked = d.removeOlder; $('aoShared').checked = d.sharedActivation;
}
aoReset();
function aoShow() {
  const have = apps.find(a => a.office && !a.wingetId);
  $('aoHave').hidden = !have;
  if (have) $('aoHave').replaceChildren(`${have.name} is in the catalog as Microsoft 365 Apps already - there is one per catalog. `,
    el('button', { type: 'button', class: 'btn small', text: 'Open it', onclick: () => { $('dlgAdd').close(); openEditor(have.name); } }));
  updateAddButton();
}
const aoRead = () => ({ channel: $('aoChannel').value, architecture: $('aoArch').value, locales: $('aoLocales').value.split(/[\s,;]+/).map(x => x.trim().toLowerCase()).filter(Boolean),
  excluded: [...document.querySelectorAll('[data-aoapp]')].filter(c => !c.checked).map(c => c.dataset.aoapp), sharedActivation: $('aoShared').checked, removeOlder: $('aoRemoveOlder').checked });
$('aoName').addEventListener('input', updateAddButton);
$('aoApps').addEventListener('change', updateAddButton);

// ---- Add
// Add, or Add and send (2.35.0): the second builds what needs a package, then shows the summary - who gets each new
// app and whether it is ready - and sends what is with one click (Fix opens the editor at what is missing).
$('btnAddGo').addEventListener('click', () => doAdd(false));
$('btnAddSend').addEventListener('click', () => doAdd(true));
async function doAdd(send) {
  const b = $('btnAddGo'); b.disabled = true; $('btnAddSend').disabled = true; $('addError').hidden = true;
  const groups = { requiredFor: addLines('adRequired'), availableFor: addLines('adAvailable'), excludeFor: addExclude };
  const publish = send;
  let done = [];
  try {
    try { localStorage.setItem('addLastSrc', addSrc); } catch (e) { }   // the next Add apps opens on this kind
    if (addSrc === 'winget' || addSrc === 'store' || addSrc === 'list') {
      const items = addSrc !== 'list' ? [...awPicked.values()].map(x => ({ id: x.id, name: x.name, version: x.version, publisher: x.publisher || '' })) : [...alPicked].map(id => { const x = alItems.find(i => i.id === id) || {}; return x.category === 'Microsoft' || isStoreId(id) ? { id, name: x.name } : { id }; });   // Store apps: winget has no name for them
      const note = addSrc !== 'list' ? 'awNote' : 'alNote', added = [], skipped = [], noDetails = [];
      // Five at a time: each asks winget for its details, and the page shows how far it got.
      for (let i = 0; i < items.length; i += 5) {
        $(note).textContent = `Adding ${Math.min(i + 5, items.length)} of ${items.length} - ${addSrc === 'store' ? 'adding them as Store apps' : 'reading each one\'s details from winget'}...`;
        const r = await api('/api/add-winget', { items: items.slice(i, i + 5), managed: addSrc === 'store' ? false : addSrc === 'winget' ? $('awManaged').checked : $('alManaged').checked, ...groups });
        if (!r.ok) { showAddError(r.error); break; }
        added.push(...r.added); skipped.push(...r.skipped); noDetails.push(...(r.noDetails || []));
      }
      if (!added.length && !skipped.length) return;
      $('dlgAdd').close(); await afterAdd(added); done = added;
      // winget didn't give the details for some: said here, with the button that reads them again.
      const lacking = noDetails.length ? ` winget's details (publisher, description, links) couldn't be read for ${noDetails.join(', ')} - Fill in details reads them later.` : '';
      toast(`${added.length} app(s) added${skipped.length ? ' - skipped: ' + skipped.join('; ') : ''}.${lacking}`, !added.length, [
        ...(noDetails.length && typeof fillDetails === 'function' ? [{ label: 'Fill in details', run: () => fillDetails(noDetails) }] : []),
        ...(added.length && !send ? [{ label: added.length === 1 ? 'Send to Intune' : `Send ${added.length}`, run: () => openDeploy(added) }] : [])]);
    }
    else if (addSrc === 'installer') {
      const r = await api('/api/add-installer', { uploadId: aiUpload.id, name: $('aiName').value.trim(), publisher: $('aiPublisher').value.trim(), version: $('aiVersion').value.trim(),
        installCommand: $('aiInstall').value.trim(), uninstallCommand: $('aiUninstall').value.trim(), managed: $('aiManaged').checked, detection: aiDetection(), ...groups });
      if (!r.ok) { showAddError(r.error); return; }
      aiUpload.added = true;
      const build = $('aiBuild').checked;
      $('dlgAdd').close(); await afterAdd([r.name]); done = [r.name];
      toast(`${r.name} added - its installer is in ${r.folder}.`, false, build || publish ? [] : [{ label: 'Build', run: () => buildAdded(r.name) }]);
      if (build || publish) await buildAdded(r.name, publish);
    }
    else if (addSrc === 'office') {
      const r = await api('/api/add-office', { name: $('aoName').value.trim(), office: aoRead(), ...groups });
      if (!r.ok) { showAddError(r.error); return; }
      $('dlgAdd').close(); await afterAdd([r.name]); done = [r.name]; aoReset();
      toast(`${r.name} added as Microsoft 365 Apps - nothing to build; Send to Intune creates it.`, false, send ? [] : [{ label: 'Send to Intune', run: () => openDeploy([r.name]) }]);
    }
    else if (addSrc === 'psadt') {
      $('addError').hidden = false; $('addError').textContent = $('apDownload').checked ? 'Downloading the PSADT template...' : 'Adding...'; $('addError').classList.add('muted');
      const r = await api('/api/add-psadt', { name: $('apName').value.trim(), publisher: $('apVendor').value.trim(), version: $('apVersion').value.trim(), download: $('apDownload').checked, ...groups });
      $('addError').classList.remove('muted');
      if (!r.ok) { showAddError(r.error); return; }
      $('dlgAdd').close(); await afterAdd([r.name]); done = [r.name];
      if (publish) await buildAdded(r.name, true);
      toast(`${r.name} added - edit Invoke-AppDeployToolkit.ps1 in ${r.folder}${r.missing.length ? ` (couldn't fill in: ${r.missing.join(', ')} - do that by hand)` : ''}.`, !!r.missing.length, [SERVER ? null : { label: 'Open the folder', run: () => api('/api/open', { target: 'package-folder', name: r.name }) }, { label: 'Build', run: () => buildAdded(r.name) }]);
    }
    else {
      const custom = document.querySelector('input[name="asDetect"]:checked').value === 'script';
      const r = await api('/api/add-script', { name: $('asName').value.trim(), publisher: $('asPublisher').value.trim(), version: $('asVersion').value.trim(),
        install: $('asInstall').value, uninstall: $('asUninstall').value, detectScript: custom ? $('asDetectScript').value : '', ...groups });
      if (!r.ok) { showAddError(r.error); return; }
      $('dlgAdd').close(); await afterAdd([r.name]); done = [r.name];
      toast(`${r.name} added - Install.ps1 and Uninstall.ps1 are in ${r.folder}.`, false, publish ? [] : [{ label: 'Build', run: () => buildAdded(r.name) }]);
      if (publish) await buildAdded(r.name, true);
    }
  } finally { updateAddButton(); }
  if (send && done.length) showAddSummary(done);
}

// What was just added, app by app: who gets it, ready to send or what it lacks (Fix: the editor at that field).
async function showAddSummary(names) {
  const r = await api('/api/deploy-plan', { names });
  if (!r.ok) { toast(r.error, true); return; }
  const fieldFor = reason => /detection rule/i.test(reason) ? 'xType' : /App version|fixed version/i.test(reason) ? 'mAppVersion' : /install command/i.test(reason) ? 'mInstallCommand' : '';
  const who = n => { const a = apps.find(x => x.name === n); if (!a) return ''; const g = a.groups || []; return a.required + a.available ? `${g.slice(0, 3).join(', ')}${g.length > 3 ? ` and ${g.length - 3} more` : ''}` : 'nobody yet'; };
  const ready = r.apps.filter(a => a.ready).map(a => a.name);
  const buildable = reason => /package \(\.intunewin\)|isn't built/i.test(reason) && !/shared Winget/i.test(reason);
  $('adDoneRows').replaceChildren(...r.apps.map(a => el('tr', {},
    el('td', { text: a.name }), el('td', { class: who(a.name) === 'nobody yet' ? 'muted' : '', text: who(a.name) }),
    el('td', {}, a.ready && (a.warnings || []).length ? el('span', { class: 'addfix' }, el('span', { class: 'pill warn', text: 'Ready - check' }), ...a.warnings.map(w => el('span', { class: 'why pkgwarn', text: '⚠ ' + w })),
        el('button', { type: 'button', class: 'btn small', text: 'Fix...', title: 'Open it in the editor', onclick: async () => { $('dlgAddDone').close(); await openEditor(a.name); } }))
      : a.ready ? el('span', { class: 'pill ok', text: a.replacesLob ? 'Ready - as Win32' : 'Ready' })
      : el('span', { class: 'addfix' }, el('span', { class: 'why', text: buildable(a.reason) ? a.reason.replace(/ - build it with More > Package\.?$/, '.') : a.reason }),
        buildable(a.reason) ? el('button', { type: 'button', class: 'btn small', text: 'Build', onclick: async e => { e.currentTarget.disabled = true; await buildAdded(a.name, true); showAddSummary(names); } })
          : el('button', { type: 'button', class: 'btn small', text: 'Fix...', title: 'Open it in the editor, at what it lacks', onclick: async () => { $('dlgAddDone').close(); await openEditor(a.name); const f = fieldFor(a.reason) && $(fieldFor(a.reason)); if (f) { edPageFor(f); const d = f.closest('details'); if (d) d.open = true; f.focus(); } } }))))));
  $('adDoneSend').textContent = ready.length === r.apps.length ? (ready.length === 1 ? 'Send it' : `Send all ${ready.length}`) : `Send the ${ready.length} ready`;
  // Nothing ready: no Send at all (2.38.0) - a greyed-out "Send the 0 ready" said nothing.
  $('adDoneSend').hidden = !ready.length; $('adDoneSend').disabled = !ready.length;
  $('adDoneSend').onclick = () => { $('dlgAddDone').close(); openDeploy(ready, { autostart: true }); };
  $('adDoneSub').textContent = ready.length === r.apps.length ? 'Everything is ready - it goes to Intune with its groups.' : 'What is ready goes to Intune with its groups. What still lacks something says what - Fix opens the editor there.';
  if (!$('dlgAddDone').open) $('dlgAddDone').showModal();
  (ready.length ? $('adDoneSend') : $('adDoneClose')).focus();
}
$('adDoneClose').addEventListener('click', () => $('dlgAddDone').close());
async function afterAdd(names) {
  await loadApps();
  if (names.length) { selected.clear(); for (const n of names) selected.add(n); lastClicked = names[names.length - 1]; renderApps(); updateViewButtons(); }
}
// Builds an own package just added; with "Send to Intune right after adding", the Send to Intune dialog follows. Resolves with whether it built.
async function buildAdded(name, quiet) {
  runDialog(`Build ${name}`, 'Packaging it as an .intunewin for Intune.');
  const p = await releaseStep({ names: [name] }, '/api/package-start', 'runLog', `Building ${name}'s package...`);
  toast(p.ok ? `${name}'s package is built.` : `Building the package failed: ${p.error || 'see the log'}`, !p.ok,
    p.ok && !quiet ? [{ label: 'Send to Intune', run: () => openDeploy([name]) }] : []);
  await loadApps();
  // Part of Add and send: the run window closes by itself - the summary says what comes next.
  if (quiet && $('dlgRun').open) $('dlgRun').close();
  return p.ok;
}

// ---- from a list: a winget export file, or this PC's apps
async function readList(body) {
  $('alNote').textContent = body.thisPc ? 'Running winget export here - this can take a minute...' : 'Reading the list...';
  const r = await api('/api/package-list', body);
  if (!r.ok) { $('alNote').textContent = r.error; return; }
  alItems = r.items;
  $('alGrid').tHead.rows[0].cells[1].textContent = r.starter ? 'App' : 'Winget ID';
  // The starter set: nothing ticked (2.38.2) - each is chosen; the ones nearly everyone deploys say "common".
  alPicked = new Set(r.starter ? [] : r.items.filter(x => !x.inCatalog).map(x => x.id));
  $('alNote').textContent = r.starter ? `${r.items.length} apps - tick what you need${r.items.some(x => x.inCatalog) ? ` (${r.items.filter(x => x.inCatalog).length} already in the catalog)` : ''}.`
    : `${r.items.length} package(s) - ${r.items.filter(x => x.inCatalog).length} already in the catalog.`;
  $('alAll').checked = alPicked.size > 0 && alPicked.size === r.items.filter(x => !x.inCatalog).length;
  renderList(); updateAddButton();
  // On a phone the explanation fills the screen: the list is brought into view (it started below it).
  if (innerWidth < 600) $('alGrid').scrollIntoView({ block: 'start' });
}
function renderList() {
  let cat = '';
  $('alRows').replaceChildren(...alItems.flatMap(x => {
    const box = el('input', { type: 'checkbox', 'aria-label': `Pick ${x.name || x.id}`, disabled: !!x.inCatalog });
    box.checked = alPicked.has(x.id);
    box.addEventListener('change', () => { if (box.checked) alPicked.add(x.id); else alPicked.delete(x.id); updateAddButton(); });
    // The starter set: a heading per category, the app's name and why beside its Winget ID.
    // A plain cell (2.38.1): the table's heading cells stay at the top while it scrolls, and a category heading did too - over the column names.
    const head = x.category && x.category !== cat ? [el('tr', { class: 'grouprow' }, el('td', { colspan: 3, text: (cat = x.category) }))] : [];
    const what = x.name ? el('td', {}, el('b', { text: x.name }), ' ', x.recommended ? el('span', { class: 'pill info', text: 'common', title: 'Nearly every organisation deploys it' }) : '', ' ', el('span', { class: 'mono muted', text: x.id === 'Microsoft.365Apps.Intune' ? "Intune's Office app" : isStoreId(x.id) ? `Store ${x.id}` : x.id }), x.why ? el('div', { class: 'muted small', text: x.why }) : '')
      : el('td', { class: 'mono', text: x.id });
    return [...head, el('tr', { class: x.inCatalog ? 'dim' : '' }, el('td', { class: 'chk' }, box), what, el('td', { text: x.inCatalog || '-' }))];
  }));
}
$('alAll').addEventListener('change', () => { alPicked = new Set($('alAll').checked ? alItems.filter(x => !x.inCatalog).map(x => x.id) : []); renderList(); updateAddButton(); });
$('btnAlFile').addEventListener('click', () => $('alFile').click());
$('btnAlStarter').addEventListener('click', () => readList({ starter: true }));
$('alFile').addEventListener('change', async () => { const f = $('alFile').files[0]; if (!f) return; if (f.size > 5 * 1048576) { $('alNote').textContent = 'That file is too large.'; return; } readList({ json: await f.text() }); $('alFile').value = ''; });
$('btnAlThisPc').addEventListener('click', () => readList({ thisPc: true }));

// Dropping an installer anywhere on the Apps page starts Add apps with it.
document.addEventListener('dragover', e => { if (!$('viewApps').hidden && [...(e.dataTransfer.items || [])].some(i => i.kind === 'file')) e.preventDefault(); });
document.addEventListener('drop', async e => {
  if ($('dlgAdd').open || $('viewApps').hidden || !e.dataTransfer) return;
  // Read before the first await - a drop's items are gone after it. An installer, a .zip, or a folder.
  e.preventDefault();
  const p = await pickFromDrop(e.dataTransfer);
  if (isPickable(p)) openAdd('installer', p);
});

// Down arrow from the winget search goes into the results; the picks are then ticked with Space.
$('awQuery').addEventListener('keydown', e => { if (e.key === 'ArrowDown') { const f = $('awRows').querySelector('input[type=checkbox], button, [tabindex]'); if (f) { e.preventDefault(); f.focus(); } } });

// The server version: winget export runs on a PC - this is the script for it; its file is chosen above.
$('btnAlScript').addEventListener('click', async () => { const r = await api('/api/winget-export-script'); if (r.ok) { saveB64File(r, 'text/plain'); toast('Run it on the PC (right-click > Run with PowerShell); it saves a file on the desktop - choose that here.'); } else toast(r.error, true); });
// Arrow keys move between the Add apps tabs, as in Settings.
document.querySelector('#dlgAdd .subtabs').addEventListener('keydown', e => {
  if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
  const tabs = [...document.querySelectorAll('[data-asrc]')].filter(t => !t.hidden), i = tabs.findIndex(t => t.dataset.asrc === addSrc);
  const next = tabs[(i + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length];
  e.preventDefault(); showAddSrc(next.dataset.asrc); next.focus();
});
