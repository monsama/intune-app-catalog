// Intune App Catalog - web interface: conveniences. The group picker, assignment profiles,
// finding an icon, a test in Windows Sandbox, detection from an app on this PC, the Home
// page, Ctrl+K, and the groups x apps grid. Loaded after apps.js and add.js.
'use strict';

// ---------------------------------------------------------------- group picker
// Every "one group per line" box: suggestions for the line being typed (favourites, the
// catalog's groups, Entra ID's), arrow keys and Enter to pick; groups Entra doesn't have yet are named.
// The chip boxes' "Add a group" fields (chips.js), else the text box itself.
const gpBoxes = ['gRequired', 'gAvailable', 'gUninstall', 'gExclude', 'adRequired', 'adAvailable', 'pilotGroups', 'favGroups', 'sGroups'];
const gpList = el('ul', { id: 'gpList', class: 'gplist', role: 'listbox', 'aria-label': 'Group suggestions', hidden: true });
document.body.append(gpList);
let gpBox = null, gpItems = [], gpActive = -1, gpTimer = 0, gpSeq = 0;
function gpLine(ta) {
  if (ta.tagName === 'INPUT') return { start: 0, end: ta.value.length, text: ta.value.trim() };
  const v = ta.value, pos = ta.selectionStart, start = v.lastIndexOf('\n', pos - 1) + 1, endI = v.indexOf('\n', pos), end = endI < 0 ? v.length : endI;
  return { start, end, text: v.slice(start, end).trim() };
}
function gpHide() { gpList.hidden = true; gpItems = []; gpActive = -1; if (gpBox) gpBox.removeAttribute('aria-activedescendant'); }
function gpShow(ta, items) {
  gpBox = ta; gpItems = items; gpActive = items.length ? 0 : -1;
  if (!items.length) { gpHide(); return; }
  // Shown inside the open dialog (top layer), else in the page.
  const host = ta.closest('dialog[open]') || document.body;
  if (gpList.parentElement !== host) host.append(gpList);
  const r = ta.getBoundingClientRect(), hr = host === document.body ? { left: 0, top: 0 } : host.getBoundingClientRect();
  gpList.style.left = (r.left - hr.left + (host === document.body ? window.scrollX : host.scrollLeft)) + 'px';
  gpList.style.top = (r.bottom - hr.top + 2 + (host === document.body ? window.scrollY : host.scrollTop)) + 'px';
  gpList.style.minWidth = Math.max(220, r.width) + 'px';
  const label = { favourite: 'favourite', catalog: 'in the catalog', entra: 'Entra ID' };
  gpList.replaceChildren(...items.map((g, i) => el('li', { id: 'gp-' + i, role: 'option', 'aria-selected': String(i === gpActive), class: i === gpActive ? 'on' : '', onmousedown: e => { e.preventDefault(); gpPick(i); } },
    el('span', { text: g.name }), el('span', { class: 'src', text: label[g.source] || '' }))));
  gpList.hidden = false;
  ta.setAttribute('aria-activedescendant', 'gp-' + gpActive);
}
function gpMove(d) {
  if (!gpItems.length) return;
  gpActive = (gpActive + d + gpItems.length) % gpItems.length;
  [...gpList.children].forEach((li, i) => { li.classList.toggle('on', i === gpActive); li.setAttribute('aria-selected', String(i === gpActive)); });
  gpBox.setAttribute('aria-activedescendant', 'gp-' + gpActive);
  gpList.children[gpActive].scrollIntoView({ block: 'nearest' });
}
function gpPick(i) {
  const ta = gpBox, g = gpItems[i]; if (!ta || !g) return;
  if (ta._addChip) { ta._addChip(g.name); gpHide(); ta.focus(); return; }
  const l = gpLine(ta), v = ta.value;
  const before = v.slice(0, l.start), after = v.slice(l.end);
  // The picked group replaces the line being typed; a group already in the box isn't listed twice.
  const seen = new Set();
  ta.value = (before + g.name + after).split('\n').filter(s => { const k = s.trim().toLowerCase(); if (!k) return true; if (seen.has(k)) return false; seen.add(k); return true; }).join('\n');
  const at = ta.value.toLowerCase().indexOf(g.name.toLowerCase());
  const caret = at >= 0 ? at + g.name.length : ta.value.length;
  ta.setSelectionRange(caret, caret);
  ta.dispatchEvent(new Event('input', { bubbles: true }));
  gpHide(); ta.focus();
}
async function gpSuggest(ta) {
  const l = gpLine(ta), seq = ++gpSeq;
  const r = await api('/api/group-suggest', { q: l.text });
  if (seq !== gpSeq || document.activeElement !== ta) return;
  const have = new Set((ta._source || ta).value.split('\n').map(s => s.trim().toLowerCase()));
  gpShow(ta, r.ok ? r.groups.filter(g => !have.has(g.name.toLowerCase()) || g.name.toLowerCase() === l.text.toLowerCase()).filter(g => g.name.toLowerCase() !== l.text.toLowerCase()).slice(0, 12) : []);
}
async function gpCheck(ta) {
  const src = ta._source || ta, anchor = ta._source ? ta.parentElement : ta;
  let warn = anchor.parentElement.querySelector('.gpwarn');
  const names = src.value.split('\n').map(s => s.trim()).filter(Boolean);
  if (!names.length) { if (warn) warn.hidden = true; return; }
  const r = await api('/api/group-check', { names });
  if (!r.ok || !r.checked) { if (warn) warn.hidden = true; return; }
  if (!warn) { warn = el('span', { class: 'gpwarn' }); anchor.after(warn); }
  warn.hidden = !r.missing.length;
  warn.textContent = r.missing.length ? `Not in Entra ID yet: ${r.missing.join(', ')} - created when the groups are pushed. A typo?` : '';
}
// Suggestions for one group field (a chip box's input, or a text box); chips.js calls it for boxes it makes later.
function gpAttach(ta) {
  if (!ta || ta.dataset.gp) return; ta.dataset.gp = '1';
  ta.setAttribute('aria-autocomplete', 'list'); ta.setAttribute('aria-controls', 'gpList');
  ta.addEventListener('input', e => { if (e.isTrusted === false && !gpList.hidden) return; clearTimeout(gpTimer); gpTimer = setTimeout(() => gpSuggest(ta), 200); });
  ta.addEventListener('focus', () => { clearTimeout(gpTimer); gpTimer = setTimeout(() => gpSuggest(ta), 150); });
  ta.addEventListener('keydown', e => {
    if (gpList.hidden || gpBox !== ta) return;
    if (e.key === 'ArrowDown') { e.preventDefault(); gpMove(1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); gpMove(-1); }
    else if ((e.key === 'Enter' || e.key === 'Tab') && gpActive >= 0 && gpLine(ta).text) { e.preventDefault(); gpPick(gpActive); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); gpHide(); }
  });
  ta.addEventListener('blur', () => { setTimeout(() => { if (document.activeElement !== ta) gpHide(); gpCheck(ta); }, 260); });
}
for (const id of gpBoxes) gpAttach($(id + 'Chips') || $(id));
for (const inp of document.querySelectorAll('.chipinput[data-kind="group"]')) gpAttach(inp);

// ---------------------------------------------------------------- assignment profiles
const profiles = () => (prefs && prefs.profiles) || [];
function fillProfileSelect(sel, first) {
  sel.replaceChildren(el('option', { value: '', text: first }), ...profiles().map((p, i) => el('option', { value: String(i), text: p.name })));
  sel.disabled = !profiles().length; sel.title = profiles().length ? 'Fill in a profile\'s groups' : 'No assignment profiles yet - Settings > Apps & defaults > Assignment profiles';
}
const mergeLines = (id, add) => { const have = $(id).value.split('\n').map(s => s.trim()).filter(Boolean); for (const g of add) if (!have.some(h => h.toLowerCase() === g.toLowerCase())) have.push(g); $(id).value = have.join('\n'); };
$('aProfile').addEventListener('focus', () => fillProfileSelect($('aProfile'), 'Apply a profile...'));
$('aProfile').addEventListener('change', () => {
  const p = profiles()[+$('aProfile').value]; if (!p) return;
  mergeLines('gRequired', p.required); mergeLines('gAvailable', p.available); mergeLines('gExclude', p.exclude);
  toast(`Profile "${p.name}" added to the groups.`); $('aProfile').value = '';
});
$('adProfile').addEventListener('focus', () => fillProfileSelect($('adProfile'), '(none)'));
$('adProfile').addEventListener('change', () => {
  const p = profiles()[+$('adProfile').value]; if (!p) return;
  mergeLines('adRequired', p.required); mergeLines('adAvailable', p.available);
  if (p.exclude.length) toast(`"${p.name}" also excludes ${p.exclude.join(', ')} - add that in the editor afterwards.`);
  $('adProfile').value = '';
});
let profN = 0;
function profRow(p) {
  // Each role a chip box (chips.js) over a hidden text box, one group per line.
  const part = (list, label) => { const t = el('textarea', { id: `prof${++profN}`, 'aria-label': label, rows: 1 }); t.value = (list || []).join('\n'); return el('label', { class: 'pfield' }, label, t); };
  const row = el('div', { class: 'profrow2' },
    el('label', { class: 'pfield' }, 'Name', el('input', { value: p.name || '', placeholder: 'e.g. Standard', 'aria-label': 'Profile name' })),
    part(p.required, 'Required for'), part(p.available, 'Available for'), part(p.exclude, 'Excluded'),
    el('button', { class: 'btn small ghost', text: 'Remove', title: 'Remove this profile', 'aria-label': `Remove the profile ${p.name || ''}`.trim(), onclick: () => row.remove() }));
  for (const t of row.querySelectorAll('textarea')) chipify(t);
  return row;
}
function fillProfiles(p) {
  fillProfileSelect($('aProfile'), 'Apply a profile...'); fillProfileSelect($('adProfile'), '(none)'); $('profRows').replaceChildren(...((p && p.profiles) || []).map(profRow)); if (!$('profRows').children.length) $('profRows').append(profRow({})); }
$('btnProfAdd').addEventListener('click', () => { const r = profRow({}); $('profRows').append(r); r.querySelector('input').focus(); });
$('btnProfSave').addEventListener('click', () => {
  const lines = t => t.value.split('\n').map(x => x.trim()).filter(Boolean);
  const list = [...$('profRows').children].map(r => { const t = [...r.querySelectorAll('textarea')]; return { name: r.querySelector('input').value.trim(), required: lines(t[0]), available: lines(t[1]), exclude: lines(t[2]) }; })
    .filter(p => p.name || p.required.length || p.available.length || p.exclude.length);
  savePrefs({ profiles: list }, 'Assignment profiles saved.');
});

// ---------------------------------------------------------------- an icon, found
$('btnIconFind').addEventListener('click', async () => {
  if (!editingName) { toast('Save the app first - the icon is looked for by its installer or homepage.', true); return; }
  const b = $('btnIconFind'); b.disabled = true;
  try {
    const r = await api('/api/icon-find', { name: editingName });
    if (!r.ok) { toast(r.error, true); return; }
    setEditorIcon(r.icon, 'set'); toast(`Icon found (${r.from}) - save to keep it.`);
  } finally { b.disabled = false; }
});

// ---------------------------------------------------------------- a test in Windows Sandbox
let sbId = '', sbTimer = 0;
async function openSandbox(name) {
  const r = await api('/api/sandbox-start', { name });
  if (!r.ok) { toast(r.error, true); return; }
  sbId = r.id;
  $('sbTitle').textContent = `Test ${name} in Windows Sandbox`;
  $('sbText').textContent = 'Windows Sandbox is starting - it installs the app with its install command, checks the detection rule, uninstalls it and checks again. This takes a few minutes; the Sandbox window can stay in the background.';
  $('sbSteps').replaceChildren(el('li', { class: 'muted', text: 'Waiting for the Sandbox...' })); $('sbLog').textContent = '';
  $('dlgSandbox').showModal();
  clearInterval(sbTimer); sbTimer = setInterval(pollSandbox, 3000);
}
async function pollSandbox() {
  if (!$('dlgSandbox').open) { clearInterval(sbTimer); return; }
  const r = await api('/api/sandbox-result', { id: sbId });
  if (!r.ok) return;
  $('sbLog').textContent = r.log || '';
  if (!r.done) return;
  clearInterval(sbTimer);
  const x = r.result, step = (ok, text) => el('li', {}, el('span', { class: 'pill ' + (ok ? 'ok' : 'err'), text: ok ? 'OK' : 'Problem' }), ' ' + text);
  $('sbSteps').replaceChildren(
    step(!x.before, x.before ? 'It was detected before installing - the rule may be too loose.' : 'Not detected before installing.'),
    step([0, 1707, 3010, 1641].includes(x.installExit), `Install command: exit code ${x.installExit}.`),
    step(!!x.detectedAfterInstall, x.detectedAfterInstall ? 'Detected after installing.' : 'Not detected after installing - check the detection rule.'),
    ...(x.uninstallExit === null || x.uninstallExit === undefined ? [] : [step([0, 1605, 3010, 1641].includes(x.uninstallExit), `Uninstall command: exit code ${x.uninstallExit}.`), step(!x.detectedAfterUninstall, x.detectedAfterUninstall ? 'Still detected after uninstalling.' : 'Gone after uninstalling.')]));
  $('sbText').textContent = r.passed ? 'Passed: it installs, is detected, and uninstalls cleanly. Ready to deploy.' : `Not ready: ${r.verdict}`;
}
$('btnSbFolder').addEventListener('click', () => api('/api/open', { target: 'sandbox-folder', id: sbId }).then(r => { if (!r.ok) toast(r.error, true); }));

// ---------------------------------------------------------------- detection from an app on this PC
let installed = [];
$('btnDetFromPc').addEventListener('click', async () => {
  $('inRows').replaceChildren(el('tr', {}, el('td', { colspan: 4, class: 'muted', text: 'Reading the apps installed here...' })));
  $('inFilter').value = ''; $('dlgInstalled').showModal(); $('inFilter').focus();
  const r = await api('/api/installed-apps');
  installed = r.ok ? r.apps : [];
  if (!installed.length) { $('inRows').replaceChildren(el('tr', {}, el('td', { colspan: 4, class: 'muted', text: r.note || 'No installed app found.' }))); return; }
  const guess = ($('aName').value || '').trim().toLowerCase().split(/\s+/)[0] || '';
  if (guess.length > 2 && installed.some(a => a.name.toLowerCase().includes(guess))) $('inFilter').value = guess;
  renderInstalled();
});
function renderInstalled() {
  const f = $('inFilter').value.trim().toLowerCase();
  const rows = installed.filter(a => !f || a.name.toLowerCase().includes(f) || (a.publisher || '').toLowerCase().includes(f)).slice(0, 200);
  $('inRows').replaceChildren(...(rows.length ? rows.map(a => el('tr', {}, el('td', { class: 'name', text: a.name }), el('td', { class: 'mono', text: a.version }), el('td', { text: a.publisher }),
    el('td', { class: 'act' }, el('button', { class: 'btn small', text: 'Use', onclick: () => useInstalled(a) }))))
    : [el('tr', {}, el('td', { colspan: 4, class: 'muted', text: 'No installed app matches.' }))]));
}
$('inFilter').addEventListener('input', renderInstalled);
async function useInstalled(a) {
  const r = await api('/api/detection-from-installed', { key: a.key, hive: a.hive });
  if (!r.ok) { toast(r.error, true); return; }
  const d = r.detection;
  $('xType').value = d.type; $('xProductCode').value = d.productCode; $('xPath').value = d.path; $('xName').value = d.name; $('xKey').value = d.keyPath; $('xValueName').value = d.valueName;
  $('xOperator').value = d.operator || 'notConfigured'; $('xValue').value = d.value; $('x32').checked = !!d.check32Bit;
  if (d.type === 'File') $('xFileType').value = d.detectionType; if (d.type === 'Registry') $('xRegType').value = d.detectionType;
  showDetFields(); deployTouched = true; $('deploySec').open = true; edPageFor($('xType'));
  $('dlgInstalled').close();
  toast(`Detection: ${r.text}. Save to keep it.`);
}

// ---------------------------------------------------------------- Home
async function loadHome() {
  $('homeNote').textContent = 'Looking...';
  if (!$('homeList').children.length) skeleton($('homeList'), 1, 3);
  const r = await api('/api/attention');
  if (!r.ok) { $('homeNote').textContent = r.error; return; }
  renderSetup(r.setup);
  $('homeNote').textContent = r.items.length ? `${r.items.length} thing${r.items.length === 1 ? '' : 's'} to look at${r.lastRun ? ` - last nightly run ${r.lastRun}` : ''}.` : 'Nothing needs a look right now.';
  const s = r.summary, stat = (n, l, cls) => el('div', { class: 'stat ' + (cls || '') }, el('span', { class: 'n', text: n }), el('span', { class: 'l', text: l }));
  $('homeStats').replaceChildren(stat(String(r.apps), 'apps in the catalog'), stat(String(r.deployed), 'in Intune'), stat(String(r.managed), 'with managed updates'),
    ...(s && s.onCurrentPercent !== null ? [stat(s.onCurrentPercent + ' %', `of ${s.devices} devices on the current version`, s.onCurrentPercent < 90 ? 'warn' : 'ok')] : []));
  const where = { 'settings:connection': ['Settings', () => showSettings('connection')], 'settings:defaults': ['Settings', () => showSettings('defaults')], 'settings:updates': ['Settings', () => showSettings('updates')], 'settings:automation': ['Settings', () => showSettings('automation')], 'settings:packaging': ['Settings', () => showSettings('packaging')],
    'apps:notdeployed': ['Show them', () => { showView('apps'); $('filter').value = 'notdeployed'; renderApps(); updateViewButtons(); }], 'apps:all': ['Apps', () => showView('apps')],
    updates: ['Updates', () => showView('updates')], checks: ['Checks', () => showView('checks')],
    'open:release': ["What's new", () => api('/api/open', { target: 'release' })], 'do:manageddefault': ['Make it the default', makeManagedDefault], 'do:managedall': ['Turn on for all', managedForAll], 'do:takeversions': ["Take winget's versions", takeVersionsForManaged] };
  const pill = { err: ['err', 'Problem'], warn: ['warn', 'Look'], ok: ['ok', 'Ready'], info: ['info', 'To do'] };
  $('homeList').replaceChildren(...(r.items.length ? r.items.map(i => { const w = where[i.go], p = pill[i.level] || pill.info;
    return el('li', { class: 'att ' + i.level }, el('span', { class: 'pill ' + p[0], text: p[1] }), el('div', { class: 'body' }, el('b', { text: i.title }), el('span', { class: 'muted', text: i.text })),
      w ? el('button', { class: 'btn small', text: w[0], onclick: w[1] }) : ''); })
    : [el('li', { class: 'att ok' }, el('span', { class: 'pill ok', text: 'All good' }), el('div', { class: 'body' }, el('b', { text: 'Nothing to do' }), el('span', { class: 'muted', text: 'Every app is deployed, nothing is on hold, and the last nightly run went fine.' })))]));
}
$('btnHomeReload').addEventListener('click', loadHome);
$('btnHomeAdd').addEventListener('click', () => openAdd());
$('btnHomeCheck').addEventListener('click', async () => {
  const b = $('btnHomeCheck'); b.disabled = true;
  try { $('chkDetails').checked = true; await runChecks(); await loadApps(); toast(findings.length ? `${findings.length} difference(s) between the catalog and Intune.` : 'The catalog and Intune match.', false, findings.length ? [{ label: 'See them', run: () => showView('checks') }] : []); loadHome(); }
  finally { b.disabled = false; }
});

// ---------------------------------------------------------------- Ctrl+K
let palItems = [], palActive = 0;
function palCommands() {
  const v = (name, view) => ({ label: name, hint: 'Page', run: () => showView(view) });
  const cat = (label, act) => ({ label, hint: 'Catalog', run: () => { showView('apps'); document.querySelector(`[data-cact="${act}"]`).click(); } });
  return [v('Home', 'home'), v('Apps', 'apps'), v('Updates', 'updates'), v('Checks', 'checks'), v('Groups', 'groups'), v('Platform scripts', 'scripts'),
    { label: 'Settings: Connection', hint: 'Page', run: () => showSettings('connection') }, { label: 'Settings: Apps & defaults, profiles, favourites', hint: 'Page', run: () => showSettings('defaults') },
    { label: 'Settings: Updates - pilot groups, rings, release rule', hint: 'Page', run: () => showSettings('updates') }, { label: 'Settings: Nightly run & alerts', hint: 'Page', run: () => showSettings('automation') },
    { label: 'Settings: Packaging & folders', hint: 'Page', run: () => showSettings('packaging') }, { label: 'Settings: Diagnostics', hint: 'Page', run: () => showSettings('diagnostics') },
    { label: 'Add apps', hint: 'Action', run: () => openAdd() }, { label: 'Add an installer (MSI / EXE)', hint: 'Action', run: () => openAdd('installer') },
    { label: 'Add a PowerShell script app', hint: 'Action', run: () => openAdd('script') }, { label: 'Add apps from a list (winget export)', hint: 'Action', run: () => openAdd('list') },
    cat('Groups and apps grid', 'matrix'), cat('Apps worth adding', 'suggest'), cat('Check winget for new versions', 'wingetcheck'), cat('Install status of every app', 'overview'),
    cat('Set up this tenant', 'tenantsetup'), cat('Export to CSV', 'export'), cat('Import from CSV', 'import'), cat('Undo last bulk change', 'undo'),
    { label: 'Run checks', hint: 'Action', run: () => { showView('checks'); $('btnRunChecks').click(); } },
    { label: 'Switch theme (automatic, light, dark)', hint: 'Action', run: () => $('btnTheme').click() },
    ...apps.map(a => ({ label: a.name, hint: a.hasAppId ? 'App' : 'App - not deployed', run: () => { showView('apps'); selected.clear(); selected.add(a.name); lastClicked = a.name; renderApps(); updateViewButtons(); openEditor(a.name); } })),
    ...apps.filter(a => a.managed && a.hasAppId).map(a => ({ label: `Release ${a.name}`, hint: 'Managed updates', run: () => openRelease(a.name) })),
    ...apps.map(a => ({ label: `Send ${a.name}`, hint: 'Action', run: () => openDeploy([a.name]) }))];
}
function palScore(label, q) {
  const l = label.toLowerCase(); if (!q) return 1;
  if (l.startsWith(q)) return 100 - l.length / 100; const i = l.indexOf(q); if (i >= 0) return 50 - i / 10;
  let p = 0; for (const c of q) { p = l.indexOf(c, p); if (p < 0) return 0; p++; } return 10;
}
function palRender() {
  const q = $('palQuery').value.trim().toLowerCase();
  palItems = palCommands().map(c => ({ ...c, s: palScore(c.label, q) })).filter(c => c.s > 0).sort((a, b) => b.s - a.s).slice(0, 12);
  palActive = 0;
  $('palList').replaceChildren(...palItems.map((c, i) => el('li', { role: 'option', id: 'pal-' + i, 'aria-selected': String(i === palActive), class: i === palActive ? 'on' : '', onmousedown: e => { e.preventDefault(); palRun(i); } },
    el('span', { text: c.label }), el('span', { class: 'src', text: c.hint }))));
  $('palQuery').setAttribute('aria-activedescendant', palItems.length ? 'pal-0' : '');
}
function palRun(i) { const c = palItems[i]; if (!c) return; $('dlgPalette').close(); c.run(); }
function openPalette() { if (document.querySelector('dialog[open]:not(#dlgPalette)')) return; $('palQuery').value = ''; palRender(); $('dlgPalette').showModal(); $('palQuery').focus(); }
$('palQuery').addEventListener('input', palRender);
$('palQuery').addEventListener('keydown', e => {
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault(); if (!palItems.length) return;
    palActive = (palActive + (e.key === 'ArrowDown' ? 1 : -1) + palItems.length) % palItems.length;
    [...$('palList').children].forEach((li, i) => { li.classList.toggle('on', i === palActive); li.setAttribute('aria-selected', String(i === palActive)); });
    $('palQuery').setAttribute('aria-activedescendant', 'pal-' + palActive);
  }
  else if (e.key === 'Enter') { e.preventDefault(); palRun(palActive); }
  else if (e.key === 'Escape') { e.preventDefault(); $('dlgPalette').close(); }
});
document.addEventListener('keydown', e => { if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); openPalette(); } });

// ---------------------------------------------------------------- groups x apps
let mx = null, mxChanges = new Map();
const mxRoles = ['', 'required', 'available', 'uninstall', 'exclude'], mxLetter = { required: 'R', available: 'A', uninstall: 'U', exclude: 'X', '': '' }, mxCls = { required: 'r', available: 'a', uninstall: 'u', exclude: 'x', '': '' };
async function openMatrix() {
  const r = await api('/api/assignment-matrix');
  if (!r.ok) { toast(r.error, true); return; }
  mx = r; mxChanges = new Map(); $('mxApps').value = ''; $('mxGroups').value = '';
  renderMatrix(); $('dlgMatrix').showModal();
}
function mxRole(a, g) {
  const k = a.name + '\u0001' + g; if (mxChanges.has(k)) return mxChanges.get(k);
  return a.required.includes(g) ? 'required' : a.available.includes(g) ? 'available' : a.uninstall.includes(g) ? 'uninstall' : a.exclude.includes(g) ? 'exclude' : '';
}
function renderMatrix() {
  const fa = $('mxApps').value.trim().toLowerCase(), fg = $('mxGroups').value.trim().toLowerCase();
  const groups = mx.groups.filter(g => !fg || g.toLowerCase().includes(fg)), rows = mx.apps.filter(a => !fa || a.name.toLowerCase().includes(fa));
  const head = el('tr', {}, el('th', { class: 'corner', text: `${rows.length} apps x ${groups.length} groups` }), ...groups.map(g => el('th', { class: 'gh', title: g }, el('span', { text: g }))));
  const body = rows.map(a => el('tr', {}, el('th', { class: 'ah', text: a.name, title: a.deployed ? a.name : a.name + ' (not deployed)' }), ...groups.map(g => {
    const role = mxRole(a, g), k = a.name + '\u0001' + g;
    return el('td', {}, el('button', { class: 'cell ' + mxCls[role] + (mxChanges.has(k) ? ' changed' : ''), text: mxLetter[role], 'aria-label': `${a.name} - ${g}: ${role || 'not assigned'}`, title: `${a.name} / ${g}: ${role || 'not assigned'} (click to change)`,
      onclick: () => { const next = mxRoles[(mxRoles.indexOf(role) + 1) % mxRoles.length], orig = (() => { mxChanges.delete(k); return mxRole(a, g); })(); if (next !== orig) mxChanges.set(k, next); renderMatrix(); } }));
  })));
  $('mxGrid').replaceChildren(el('thead', {}, head), el('tbody', {}, ...body));
  $('mxNote').textContent = mxChanges.size ? `${mxChanges.size} change(s) not saved yet.` : '';
  setEnabled($('btnMxSave'), mxChanges.size > 0, 'Change some cells first.');
}
$('mxApps').addEventListener('input', renderMatrix); $('mxGroups').addEventListener('input', renderMatrix);
$('btnMxSave').addEventListener('click', async () => {
  const changes = [...mxChanges].map(([k, role]) => { const [name, group] = k.split('\u0001'); return { name, group, role }; });
  const r = await api('/api/assignments-set', { changes });
  if (!r.ok) { toast(r.error, true); return; }
  toast(`${changes.length} change(s) saved to ${r.apps.length} app(s) in the catalog.`, false, [
    { label: 'Send groups', run: () => { const names = r.apps.filter(n => (apps.find(a => a.name === n) || {}).hasAppId); if (names.length) { showView('apps'); selected.clear(); names.forEach(n => selected.add(n)); renderApps(); $('btnPush').click(); } else toast('None of them is in Intune yet - Send them to Intune.'); } },
    { label: 'Undo', run: () => undoLast() }]);
  await loadApps(); await openMatrix();
});
$('dlgMatrix').addEventListener('cancel', async e => { if (mxChanges.size) { e.preventDefault(); if (await ask(`Discard ${mxChanges.size} change(s) in the grid?`, { ok: 'Discard', danger: true })) { mxChanges.clear(); $('dlgMatrix').close(); } } });

// ---------------------------------------------------------------- managed updates as the default (Home's buttons)
async function makeManagedDefault() {
  const r = await api('/api/managed-default', {});
  toast(r.ok ? 'Managed updates are the default for new Winget apps.' : r.error, !r.ok);
  await loadPrefs(); loadHome();
}
async function managedForAll() {
  const names = apps.filter(a => a.wingetId && !a.managed).map(a => a.name);
  if (!names.length) return;
  if (!(await ask(`Turn managed updates on for ${names.length} Winget app(s)?\n\n${names.slice(0, 12).join(', ')}${names.length > 12 ? ', ...' : ''}\n\nEach installs a fixed version from then on, and new versions go to the pilot groups first. Their install commands follow the App version - apps without one take winget's current version next (Home asks).`, { ok: 'Turn on', danger: false }))) return;
  const r = await api('/api/managed-updates', { names, on: true });
  toast(r.ok ? `Managed updates on for ${r.changed.length} app(s)${r.skipped.length ? ' - skipped: ' + r.skipped.join('; ') : ''}.` : r.error, !r.ok, r.ok ? [{ label: 'Undo', run: () => undoLast() }] : []);
  await loadApps(); loadHome();
}
async function takeVersionsForManaged() {
  const names = apps.filter(a => a.wingetId && a.managed && !a.version).map(a => a.name);
  if (!names.length) return;
  toast(`Asking winget for the current version of ${names.length} app(s)...`);
  const w = await api('/api/checks-winget', {});
  if (!w.ok) { toast(w.error, true); return; }
  const r = await api('/api/winget-take-version', { names });
  if (!r.ok) { toast(r.error, true); return; }
  await loadApps(); loadHome();
  const inIntune = (r.deployed || []);
  toast(`${r.changed.length} app(s) now start from winget's current version${r.skipped.length ? ' - skipped: ' + r.skipped.join('; ') : ''}.${inIntune.length ? ` Send ${inIntune.length} of them to Intune again so Intune installs that version: ${inIntune.join(', ')}.` : ''}`);
}
