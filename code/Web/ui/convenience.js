// Intune App Catalog - web interface: conveniences. The group picker, assignment profiles,
// finding an icon, detection from an app on this PC, the Home
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
  // Nothing highlighted at first: Enter adds what's typed; Down arrow picks a suggestion.
  gpBox = ta; gpItems = items; gpActive = -1;
  if (!items.length) { gpHide(); return; }
  // Shown inside the open dialog (top layer), else in the page.
  const host = ta.closest('dialog[open]') || document.body;
  if (gpList.parentElement !== host) host.append(gpList);
  const r = ta.getBoundingClientRect(), hr = host === document.body ? { left: 0, top: 0 } : host.getBoundingClientRect();
  gpList.style.left = (r.left - hr.left + (host === document.body ? window.scrollX : host.scrollLeft)) + 'px';
  gpList.style.top = (r.bottom - hr.top + 2 + (host === document.body ? window.scrollY : host.scrollTop)) + 'px';
  gpList.style.minWidth = Math.max(220, r.width) + 'px';
  const label = { 'built-in': 'Intune built-in', favourite: 'favourite', catalog: 'in the catalog', entra: 'Entra ID' };
  gpList.replaceChildren(...items.map((g, i) => el('li', { id: 'gp-' + i, role: 'option', 'aria-selected': String(i === gpActive), class: i === gpActive ? 'on' : '', onmousedown: e => { e.preventDefault(); gpPick(i); } },
    el('span', { text: g.name }), el('span', { class: 'src', text: label[g.source] || '' }))));
  gpList.hidden = false;
  ta.setAttribute('aria-activedescendant', 'gp-' + gpActive);
}
function gpMove(d) {
  if (!gpItems.length) return;
  gpActive = gpActive < 0 ? (d > 0 ? 0 : gpItems.length - 1) : (gpActive + d + gpItems.length) % gpItems.length;
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
  const src = ta._source || ta, have = new Set(src.value.split(src.tagName === 'INPUT' ? /\n|, / : '\n').map(s => s.trim().toLowerCase()));
  // [All users] / [All devices] (Intune's own targets) only where an app gets assigned: never Excluded, pilot or favourite lists.
  const builtInOk = ['gRequired', 'gAvailable', 'gUninstall', 'adRequired', 'adAvailable'].includes(src.id) || ['Required for', 'Available for'].includes(src.getAttribute('aria-label'));
  // Available is for users - [All devices] isn't offered there (Intune refuses it).
  const isAvail = ['gAvailable', 'adAvailable'].includes(src.id) || src.getAttribute('aria-label') === 'Available for';
  gpShow(ta, r.ok ? r.groups.filter(g => builtInOk || g.source !== 'built-in').filter(g => !(isAvail && g.name === '[All devices]')).filter(g => !have.has(g.name.toLowerCase()) || g.name.toLowerCase() === l.text.toLowerCase()).filter(g => g.name.toLowerCase() !== l.text.toLowerCase()).slice(0, 12) : []);
}
async function gpCheck(ta) {
  const src = ta._source || ta, anchor = ta._source ? ta.parentElement : ta;
  let warn = anchor.parentElement.querySelector('.gpwarn');
  // A one-line chip box (Add groups) joins with ", " (2.38.61: "G1, G2" was checked as one group's name).
  const sep = src.tagName === 'INPUT' ? /\n|, / : '\n';
  const names = src.value.split(sep).map(s => s.trim()).filter(Boolean);
  if (!names.length) { if (warn) warn.hidden = true; return; }
  const r = await api('/api/group-check', { names });
  if (!r.ok || !r.checked) { if (warn) warn.hidden = true; return; }
  if (!warn) { warn = el('span', { class: 'gpwarn' }); anchor.after(warn); }
  // The box may have changed while Entra ID was asked.
  if (src.value.split(sep).map(s => s.trim()).filter(Boolean).join('\n') !== names.join('\n')) return;
  warn.hidden = !r.missing.length;
  const close = r.close || {}, near = r.missing.filter(n => close[n]), none = r.missing.filter(n => !close[n]);
  warn.textContent = [
    ...near.map(n => `"${n}" isn't in Entra ID, but "${close[n]}" is - did you mean that one?`),
    ...(none.length ? [`${none.length === 1 ? 'No group' : 'No groups'} named ${none.map(n => `"${n}"`).join(', ')} in Entra ID. Sending the groups creates ${none.length === 1 ? 'it as a new, empty group' : 'them as new, empty groups'} - check the spelling if ${none.length === 1 ? 'it' : 'they'} should already exist.`] : [])].join(' ');
}
// Re-checked when the box changes (a chip removed, another app opened), so a warning never outlives its names.
function gpRecheck(ta) { const src = ta._source || ta, anchor = ta._source ? ta.parentElement : ta, warn = anchor.parentElement.querySelector('.gpwarn');
  if (!warn) return; if (!src.value.trim()) { warn.hidden = true; warn.textContent = ''; return; } clearTimeout(ta._gpRe); ta._gpRe = setTimeout(() => gpCheck(ta), 400); }
// Suggestions for one group field (a chip box's input, or a text box); chips.js calls it for boxes it makes later.
function gpAttach(ta) {
  if (!ta || ta.dataset.gp) return; ta.dataset.gp = '1';
  ta.setAttribute('aria-autocomplete', 'list'); ta.setAttribute('aria-controls', 'gpList');
  ta.addEventListener('input', e => { if (e.isTrusted === false && !gpList.hidden) return; clearTimeout(gpTimer); gpTimer = setTimeout(() => gpSuggest(ta), 200); });
  // On focus only when something is typed already: a tab switch focusing the box doesn't drop a list over the fields below.
  ta.addEventListener('focus', () => { clearTimeout(gpTimer); if (gpLine(ta).text) gpTimer = setTimeout(() => gpSuggest(ta), 150); });
  ta.addEventListener('keydown', e => {
    if (gpList.hidden || gpBox !== ta) return;
    if (e.key === 'ArrowDown') { e.preventDefault(); gpMove(1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); gpMove(-1); }
    else if ((e.key === 'Enter' || e.key === 'Tab') && gpActive >= 0 && gpLine(ta).text) { e.preventDefault(); gpPick(gpActive); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); gpHide(); }
  });
  ta.addEventListener('blur', () => { setTimeout(() => { if (document.activeElement !== ta) gpHide(); gpCheck(ta); }, 260); });
  const src = ta._source || ta; if (src !== ta) { src.addEventListener('input', () => gpRecheck(ta)); src.addEventListener('change', () => gpRecheck(ta)); src.addEventListener('chipsset', () => gpRecheck(ta)); }
}
for (const id of gpBoxes) gpAttach($(id + 'Chips') || $(id));
for (const inp of document.querySelectorAll('.chipinput[data-kind="group"]')) gpAttach(inp);

// ---------------------------------------------------------------- assignment profiles
const profiles = () => (prefs && prefs.profiles) || [];
// The profile new apps get (Settings > Apps & defaults - 2.35.0), or null.
const defaultProfile = () => { const n = prefs && prefs.defaultProfile; return n ? profiles().find(p => p.name === n) || null : null; };
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
  for (const g of p.exclude) if (!addExclude.some(x => x.toLowerCase() === g.toLowerCase())) addExclude.push(g);
  for (const id of ['adRequired', 'adAvailable']) $(id).dispatchEvent(new Event('input'));
  $('adProfile').value = '';
});
let profN = 0;
function profRow(p) {
  // Each role a chip box (chips.js) over a hidden text box, one group per line.
  const part = (list, label) => { const t = el('textarea', { id: `prof${++profN}`, 'aria-label': label, rows: 1 }); t.value = (list || []).join('\n'); return el('label', { class: 'pfield' }, label, t); };
  const row = el('div', { class: 'profrow2', 'data-pid': String(++profN) },
    el('label', { class: 'pfield' }, 'Name', el('input', { value: p.name || '', placeholder: 'e.g. Standard', 'aria-label': 'Profile name' })),
    part(p.required, 'Required for'), part(p.available, 'Available for'), part(p.exclude, 'Excluded'),
    el('button', { class: 'btn small ghost', text: 'Remove', title: 'Remove this profile', 'aria-label': `Remove the profile ${p.name || ''}`.trim(), onclick: () => { row.remove(); profDefaultOptions(); } }));
  for (const t of row.querySelectorAll('textarea')) chipify(t);
  return row;
}
// "New apps get" lists the profiles as they are typed (2.38.0): a new one can be the default before it is saved,
// and the choice follows its row - a renamed default stays the default.
function profDefaultOptions(pickName) {
  const sel = $('profDefault'), was = pickName === undefined ? sel.value : '';
  const rows = [...$('profRows').children].map(r => ({ pid: r.dataset.pid, name: r.querySelector('input').value.trim() })).filter(x => x.name);
  sel.replaceChildren(el('option', { value: '', text: '(none)' }), ...rows.map(x => el('option', { value: x.pid, text: x.name })));
  const pick = pickName !== undefined ? (rows.find(x => x.name === pickName) || {}).pid : was;
  sel.value = rows.some(x => x.pid === pick) ? pick : '';
}
function fillProfiles(p) {
  fillProfileSelect($('aProfile'), 'Apply a profile...'); fillProfileSelect($('adProfile'), '(none)');
  $('profRows').replaceChildren(...((p && p.profiles) || []).map(profRow)); if (!$('profRows').children.length) $('profRows').append(profRow({}));
  profDefaultOptions((p && p.defaultProfile) || ''); }
$('profRows').addEventListener('input', e => { if (e.target.matches('input[aria-label="Profile name"]')) profDefaultOptions(); });
$('btnProfAdd').addEventListener('click', () => { const r = profRow({}); $('profRows').append(r); r.querySelector('input').focus(); });
$('btnProfSave').addEventListener('click', () => {
  const lines = t => t.value.split('\n').map(x => x.trim()).filter(Boolean);
  const rows = [...$('profRows').children];
  const list = rows.map(r => { const t = [...r.querySelectorAll('textarea')]; return { name: r.querySelector('input').value.trim(), required: lines(t[0]), available: lines(t[1]), exclude: lines(t[2]) }; })
    .filter(p => p.name || p.required.length || p.available.length || p.exclude.length);
  // The default by its row: its name as it is now.
  const dRow = rows.find(r => r.dataset.pid === $('profDefault').value), dp = dRow ? dRow.querySelector('input').value.trim() : '';
  savePrefs({ profiles: list, defaultProfile: dp }, 'Assignment profiles saved.');
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

// ---------------------------------------------------------------- detection from an app on this PC
let installed = [];
// The server version: the PC's apps come from a script run on that PC, pasted here.
$('btnDetFromPaste').addEventListener('click', () => { $('dpText').value = ''; $('dpError').hidden = true; $('dlgDetPaste').showModal(); });
$('btnDetScript').addEventListener('click', async () => { const r = await api('/api/installed-script'); if (r.ok) saveB64File(r, 'text/plain'); else toast(r.error, true); });
$('btnDetPasteGo').addEventListener('click', async () => {
  const r = await api('/api/detection-from-paste', { text: $('dpText').value });
  if (!r.ok) { $('dpError').textContent = r.error; $('dpError').hidden = false; return; }
  applyDetection(r); $('dlgDetPaste').close();
});
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
  applyDetection(r);
  $('dlgInstalled').close();
}
// A detection rule (the editor's form) into the editor's fields.
function applyDetection(r) {
  const d = r.detection;
  $('xType').value = d.type; $('xProductCode').value = d.productCode; $('xPath').value = d.path; $('xName').value = d.name; $('xKey').value = d.keyPath; $('xValueName').value = d.valueName;
  $('xOperator').value = d.operator || 'notConfigured'; $('xValue').value = d.value; $('x32').checked = !!d.check32Bit;
  if (d.type === 'File') $('xFileType').value = d.detectionType; if (d.type === 'Registry') $('xRegType').value = d.detectionType;
  showDetFields(); deployTouched = true; $('deploySec').open = true; edPageFor($('xType'));
  $('xType').dispatchEvent(new Event('change', { bubbles: true }));
  toast(`Detection: ${r.text}. Save to keep it.`);
}

// ---------------------------------------------------------------- Home
let homeSeq = 0, homeAt = 0, homeSoon = 0;
// Actions started from Home that are still running: their buttons stay disabled through a refresh.
const homeRunning = new Set();
// Home refreshes by itself: after any change in the app (loadApps), when the window comes back, and every
// minute while it's open - another admin's changes show up too. Only while Home is the page shown.
function refreshHomeSoon() { if ($('viewHome').hidden) return; clearTimeout(homeSoon); homeSoon = setTimeout(loadHome, 400); }
document.addEventListener('visibilitychange', () => { if (!document.hidden && Date.now() - homeAt > 15000) refreshHomeSoon(); });
// Not while someone is on Home's buttons with the keyboard (the refresh would take the focus away).
setInterval(() => { if (!document.hidden && Date.now() - homeAt > 55000 && !$('viewHome').contains(document.activeElement)) refreshHomeSoon(); }, 60000);
// While a Home action runs: its button spins and says Working..., its row shows a moving bar, and the
// header says what's running - through any refresh, until the action has finished.
const homeWorking = () => [el('span', { class: 'spinner', 'aria-hidden': 'true' }), 'Working...'];
function showHomeBusy(go, on) {
  const b = $('homeList').querySelector(`[data-go="${CSS.escape(go)}"]`), li = $('homeList').querySelector(`li[data-row="${CSS.escape(go)}"]`);
  if (b) { b.disabled = on; b.classList.toggle('working', on); b.title = on ? 'Still running' : ''; b.replaceChildren(...(on ? homeWorking() : [b.dataset.label])); }
  if (li) { li.classList.toggle('busy', on); li.setAttribute('aria-busy', String(on)); }
  $('homeBusy').hidden = !homeRunning.size;
}
async function runHomeAction(go, fn) {
  if (homeRunning.has(go)) return;
  homeRunning.add(go); showHomeBusy(go, true);
  try { await fn(); } finally { homeRunning.delete(go); showHomeBusy(go, false); }
}
// Home comes in two parts, asked at the same time: what the app knows itself (the catalog, the last nightly run,
// the setup) - shown as soon as it's there - and Intune's release and install counts, the slow part, added when
// they arrive. Until then, the last Intune part shown stays.
let homeLocal = null, homeIntune = null, homeIntuneSeq = 0;
async function loadHome(fresh) {
  const seq = ++homeSeq, iseq = ++homeIntuneSeq;
  // Only the first load shows that it's looking; a refresh swaps the content in place, without flicker.
  if (!$('homeList').children.length) { $('homeNote').textContent = 'Looking...'; skeleton($('homeList'), 1, 3); tileSkeleton($('homeStats'), state && state.configured ? 4 : 3); }
  homeAt = Date.now();
  const intune = api('/api/attention', { part: 'intune', fresh: fresh === true });
  const r = await api('/api/attention', { part: 'local' });
  // A slower, older answer never overwrites a newer one (it could bring back something just fixed).
  if (seq !== homeSeq) return;
  // A refresh that fails keeps what's shown (only the note says so); a first load that fails shows nothing stale.
  if (!r.ok) {
    $('homeNote').textContent = r.error;
    if (!$('homeList').querySelector('li.att')) { $('homeList').replaceChildren(); $('homeCount').textContent = ''; $('homeStats').replaceChildren(); }
    return;
  }
  homeLocal = r; homeIntuneWaiting = true;
  renderHome();
  const q = await intune;
  if (iseq !== homeIntuneSeq) return;
  homeIntuneWaiting = false;
  if (q.ok) homeIntune = q;
  renderHome();
}
let homeIntuneWaiting = false;
function renderHome() {
  const r = homeLocal; if (!r) return;
  const order = { err: 0, warn: 1, ok: 2, info: 3 };
  // Getting started still open: its first step is the connection - "Not connected" isn't said twice.
  // Connected, but a Graph permission the catalog uses is missing (2.38.6): the connection step isn't done yet.
  const perm = [...new Set([...(r.refused || []), ...((homeIntune && homeIntune.permMissing) || [])])];
  const setup = (r.setup || []).map(s => perm.length && s.go === 'settings:connection' && s.done
    ? { ...s, done: false, go: 'settings:permissions', title: 'Grant the missing permissions', button: 'Check permissions',
        text: `Connected - but ${perm.length} permission${perm.length === 1 ? ' is' : 's are'} missing in Entra ID. Check permissions lists ${perm.length === 1 ? 'it' : 'them'} and how to add ${perm.length === 1 ? 'it' : 'them'}.`, tip: perm.join('\n') } : s);
  const setupOpen = setup.some(s => !s.done);
  const items = [...r.items.filter(x => !(setupOpen && ((x.go === 'settings:connection' && x.title === 'Not connected') || x.go === 'settings:permissions'))),
    ...((homeIntune && homeIntune.items) || []).filter(x => !(setupOpen && x.go === 'settings:permissions'))].map((x, n) => [x, n]).sort((a, b) => (order[a[0].level] ?? 3) - (order[b[0].level] ?? 3) || a[1] - b[1]).map(x => x[0]);
  renderSetup(setup);
  const reading = homeIntuneWaiting && !homeIntune && r.connected !== false ? ' Reading install counts from Intune...' : '';
  // Not set up yet (2.38.34): not "nothing needs a look" while the guide is open.
  $('homeNote').textContent = (items.length ? `${items.length} thing${items.length === 1 ? '' : 's'} to look at${r.lastRun ? ` - last managed-updates run ${fmtWhen(r.lastRun)}` : ''}.` : setupOpen ? 'Not set up yet - Getting started shows the next step.' : 'Nothing needs a look right now.') + reading;
  $('homeCount').textContent = items.length ? String(items.length) : '';
  const s = homeIntune && homeIntune.summary, stat = (n, l, cls) => el('div', { class: 'stat ' + (cls || '') }, el('span', { class: 'n', text: n }), el('span', { class: 'l', text: l }));
  // An empty catalog: three zeros say nothing - Getting started is what's there to do.
  $('homeStats').hidden = !r.apps;
  $('homeTips').hidden = setupOpen;
  $('homeStats').replaceChildren(stat(String(r.apps), 'apps in the catalog'), stat(String(r.deployed), 'in Intune'), stat(String(r.managed), 'with managed updates'),
    // The fourth tile is there from the start when connected ('–' until Intune answers): the row doesn't grow later.
    ...(s && s.onCurrentPercent !== null && s.onCurrentPercent !== undefined ? [stat(s.onCurrentPercent + ' %', `of ${s.devices} devices on the current version`, s.onCurrentPercent < 90 ? 'warn' : 'ok')] : r.connected !== false && state && state.configured ? [stat('–', 'devices on the current version', 'skel')] : []));
  const where = { 'settings:connection': ['Settings', () => showSettings('connection')], 'settings:permissions': ['Check permissions', checkPermissionsNow], 'settings:defaults': ['Settings', () => showSettings('defaults')], 'settings:updates': ['Settings', () => showSettings('updates')], 'settings:automation': ['Settings', () => showSettings('automation')], 'settings:packaging': ['Settings', () => showSettings('packaging')],
    'apps:notdeployed': ['Show them', () => { showView('apps'); $('filter').value = 'notdeployed'; renderApps(); updateViewButtons(); }], 'apps:all': ['Apps', () => showView('apps')],
    updates: ['Updates', () => showView('updates')], checks: ['Checks', () => showView('checks')],
    'open:release': ["What's new", () => api('/api/open', { target: 'release' })], 'do:manageddefault': ['Make it the default', makeManagedDefault], 'do:managedall': ['Turn on for all', managedForAll], 'do:takeversions': ["Take winget's versions", takeVersionsForManaged], 'do:wauswitch': ['Switch them', wauSwitch], 'do:portalstore': ['Fix Company Portal', portalStore], 'do:filldetails': ['Fill them in', () => fillDetails([])], 'do:wingetmodule': ['Install it', installWingetModule] };
  const pill = { err: ['err', 'Problem'], warn: ['warn', 'Look'], ok: ['ok', 'Ready'], info: ['info', 'To do'] };
  $('homeList').replaceChildren(...(items.length ? items.map(i => { const w = where[i.go], p = pill[i.level] || pill.info;
    const busy = homeRunning.has(i.go);
    return el('li', { class: 'att ' + i.level + (busy ? ' busy' : ''), 'data-row': i.go || '', 'aria-busy': String(busy) }, el('span', { class: 'pill ' + p[0], text: p[1] }), el('div', { class: 'body' }, el('b', { text: i.title }), el('span', { class: 'muted', text: i.text })),
      w ? el('button', { class: 'btn small' + (busy ? ' working' : ''), 'data-go': i.go, 'data-label': w[0], disabled: busy, title: busy ? 'Still running' : null, onclick: () => runHomeAction(i.go, w[1]) }, busy ? homeWorking() : w[0]) : ''); })
    : [el('li', { class: 'att ' + (setupOpen ? 'info' : 'ok') }, el('span', { class: setupOpen ? 'pill' : 'pill ok', text: setupOpen ? 'Setting up' : 'All good' }), el('div', { class: 'body' }, el('b', { text: setupOpen ? 'Nothing here yet' : 'Nothing to do' }), el('span', { class: 'muted', text: setupOpen ? 'Getting started shows what comes next.' : 'Every app is deployed, nothing is on hold, and the last nightly run went fine.' })))]));
}
$('btnHomeReload').addEventListener('click', () => loadHome(true));
$('btnHomeAdd').addEventListener('click', () => openAdd());
$('btnHomeCheck').addEventListener('click', async () => {
  const b = $('btnHomeCheck'); b.disabled = true; b.classList.add('working'); b.replaceChildren(el('span', { class: 'spinner', 'aria-hidden': 'true' }), 'Checking...');
  try { $('chkDetails').checked = true; const cr = await runChecks(); await loadApps();
    const notCompared = cr && cr.connected === false;
    toast(shownFindings().length ? `${nWord(shownFindings().length, 'finding')} - Checks has them.` : notCompared ? 'Not compared with Intune: not connected (Settings > Connection). The catalog itself looks fine.' : 'The catalog and Intune match.', false, findings.length ? [{ label: 'See them', run: () => showView('checks') }] : []); loadHome(); }
  finally { b.disabled = false; b.classList.remove('working'); b.textContent = 'Check everything now'; }
});

// ---------------------------------------------------------------- Ctrl+K
let palItems = [], palActive = 0;
function palCommands() {
  const v = (name, view) => ({ label: name, hint: 'Page', run: () => showView(view) });
  const cat = (label, act) => ({ label, hint: 'Catalog', run: () => { showView('apps'); document.querySelector(`[data-cact="${act}"]`).click(); } });
  return [v('Home', 'home'), v('Apps', 'apps'), v('Updates', 'updates'), v('Checks', 'checks'), v('Groups', 'groups'), v('Platform scripts', 'scripts'),
    { label: 'Settings: Connection', hint: 'Page', run: () => showSettings('connection') }, { label: 'Settings: Apps & defaults, profiles, favourites', hint: 'Page', run: () => showSettings('defaults') },
    { label: 'Settings: Updates - pilot groups, rings, release rule', hint: 'Page', run: () => showSettings('updates') }, { label: 'Settings: Nightly run & alerts', hint: 'Page', run: () => showSettings('automation') },
    { label: 'Settings: Packaging & folders', hint: 'Page', run: () => showSettings('packaging') }, { label: 'Settings: Diagnostics', hint: 'Page', run: () => showSettings('diagnostics') }, { label: 'Settings: About (version, updates)', hint: 'Page', run: () => showSettings('about') },
    { label: 'Add apps', hint: 'Action', run: () => openAdd() }, { label: 'Add an installer (MSI / EXE)', hint: 'Action', run: () => openAdd('installer') },
    { label: 'Add a PowerShell script app', hint: 'Action', run: () => openAdd('script') }, { label: 'Add apps from a list (winget export)', hint: 'Action', run: () => openAdd('list') },
    cat('Groups and apps grid', 'matrix'), cat('Apps worth adding', 'suggest'), cat('Check winget for new versions', 'wingetcheck'), cat('Install status of every app', 'overview'),
    cat('Set up this tenant', 'tenantsetup'), cat('Recent changes (with Undo)', 'recent'), cat('Export to CSV', 'export'), cat('Import from CSV', 'import'), cat('Undo last bulk change', 'undo'),
    { label: 'Run checks', hint: 'Action', run: () => { showView('checks'); $('btnRunChecks').click(); } },
    { label: 'Switch theme (automatic, light, dark)', hint: 'Action', run: () => $('btnTheme').click() },
    ...apps.map(a => ({ label: a.name, hint: a.hasAppId ? 'App' : 'App - not in Intune yet', run: () => { showView('apps'); selected.clear(); selected.add(a.name); lastClicked = a.name; renderApps(); updateViewButtons(); openEditor(a.name); } })),
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
function openPalette() { if (document.querySelector('dialog[open]:not(#dlgPalette):not(#dlgRun)')) return; $('palQuery').value = ''; palRender(); $('dlgPalette').showModal(); $('palQuery').focus(); }
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
  if (wcResume('dlgMatrix')) return;
  const r = await api('/api/assignment-matrix');
  if (!r.ok) { toast(r.error, true); return; }
  mx = r; mxChanges = new Map(); $('mxApps').value = ''; $('mxGroups').value = '';
  renderMatrix(); $('dlgMatrix').showModal();
}
function mxRole(a, g) {
  const k = a.name + '\u0001' + g; if (mxChanges.has(k)) return mxChanges.get(k);
  // Ignoring case, as the columns are made: "sg-sales" on an app is the SG-Sales column.
  const has = list => list.some(x => String(x).toLowerCase() === g.toLowerCase());
  return has(a.required) ? 'required' : has(a.available) ? 'available' : has(a.uninstall) ? 'uninstall' : has(a.exclude) ? 'exclude' : '';
}
function renderMatrix() {
  const fa = $('mxApps').value.trim().toLowerCase(), fg = $('mxGroups').value.trim().toLowerCase();
  const groups = mx.groups.filter(g => !fg || g.toLowerCase().includes(fg)), rows = mx.apps.filter(a => !fa || a.name.toLowerCase().includes(fa));
  const head = el('tr', {}, el('th', { class: 'corner', text: `${rows.length} apps x ${groups.length} groups` }), ...groups.map(g => el('th', { class: 'gh', title: g }, el('span', { text: g }))));
  const body = rows.map(a => el('tr', {}, el('th', { class: 'ah', text: a.name, title: a.deployed ? a.name : a.name + ' (not in Intune yet)' }), ...groups.map(g => {
    const role = mxRole(a, g), k = a.name + '\u0001' + g;
    return el('td', {}, el('button', { class: 'cell ' + mxCls[role] + (mxChanges.has(k) ? ' changed' : ''), text: mxLetter[role], 'aria-label': `${a.name} - ${g}: ${role || 'not assigned'}`, title: `${a.name} / ${g}: ${role || 'not assigned'} (click to change)`,
      onclick: () => { const next = mxRoles[(mxRoles.indexOf(role) + 1) % mxRoles.length], orig = (() => { mxChanges.delete(k); return mxRole(a, g); })(); if (next !== orig) mxChanges.set(k, next); renderMatrix(); } }));
  })));
  // No groups at all (or none matching): say why, instead of a bare list of names.
  if (!groups.length) {
    $('mxGrid').replaceChildren(el('tbody', {}, el('tr', {}, el('td', { class: 'mxempty' }, el('b', { text: mx.groups.length ? 'No group matches the filter.' : 'No app has a group yet.' }),
      el('span', { class: 'muted', text: mx.groups.length ? ' Clear "Filter groups" to see them all.' : ' Give apps groups in the editor (Who gets it) or with Add groups - each group becomes a column here.' })))));
  } else $('mxGrid').replaceChildren(el('thead', {}, head), el('tbody', {}, ...body));
  $('mxNote').textContent = mxChanges.size ? `${nWord(mxChanges.size, 'change')} not saved yet.` : '';
  setEnabled($('btnMxSave'), mxChanges.size > 0, 'Change some cells first.');
}
$('mxApps').addEventListener('input', renderMatrix); $('mxGroups').addEventListener('input', renderMatrix);
$('btnMxSave').addEventListener('click', async () => {
  const changes = [...mxChanges].map(([k, role]) => { const [name, group] = k.split('\u0001'); return { name, group, role }; });
  const r = await api('/api/assignments-set', { changes });
  if (!r.ok) { toast(r.error, true); return; }
  toast(`${nWord(changes.length, 'change')} saved to ${nWord(r.apps.length, 'app')} in the catalog.`, false, [
    { label: 'Send groups', run: () => { const names = r.apps.filter(n => (apps.find(a => a.name === n) || {}).hasAppId); if (names.length) { showView('apps'); selected.clear(); names.forEach(n => selected.add(n)); renderApps(); $('btnPush').click(); } else toast('None of them is in Intune yet - Send them to Intune.'); } },
    { label: 'Undo', run: () => undoLast() }]);
  await loadApps(); await openMatrix();
});
$('dlgMatrix').addEventListener('cancel', async e => { if (mxChanges.size) { e.preventDefault(); if (await ask(`Discard ${nWord(mxChanges.size, 'change')} in the grid?`, { ok: 'Discard', danger: true })) { mxChanges.clear(); $('dlgMatrix').close(); } } });

// ---------------------------------------------------------------- managed updates as the default (Home's buttons)
async function makeManagedDefault() {
  const r = await api('/api/managed-default', {});
  toast(r.ok ? 'Managed updates are the default for new Winget apps.' : r.error, !r.ok);
  await loadPrefs(); loadHome();
}
async function managedForAll() {
  // Not Store apps (the Store updates them) nor Winget-AutoUpdate itself (it's retired, not managed).
  // Nor apps that update themselves (2.38.40) - winget's latest is their way.
  const names = apps.filter(a => a.wingetId && !a.managed && !a.updatesItself && !isStoreId(a.wingetId) && !isWauApp(a)).map(a => a.name);
  if (!names.length) return;
  if (!(await ask(`Turn managed updates on for ${nWord(names.length, 'Winget app')}?\n\n${names.slice(0, 12).join(', ')}${names.length > 12 ? ', ...' : ''}\n\nEach installs a fixed version from then on, and new versions go to the pilot groups first. Their install commands follow the App version - apps without one take winget's current version next (Home asks).`, { ok: 'Turn on', danger: false }))) return;
  const r = await api('/api/managed-updates', { names, on: true });
  toast(r.ok ? `Managed updates on for ${nWord(r.changed.length, 'app')}${r.skipped.length ? ' - skipped: ' + r.skipped.join('; ') : ''}.` : r.error, !r.ok, r.ok ? [{ label: 'Undo', run: () => undoLast() }] : []);
  await loadApps(); loadHome();
}
// Microsoft's WinGet PowerShell module: exact winget answers whatever Windows' language. Installed for this user only.
function installWingetModule() {
  return new Promise(resolve => {
    runDialog('Install the WinGet PowerShell module', 'Microsoft.WinGet.Client, from the PowerShell Gallery, for your user');
    runJob({}, (ok, res, after) => {
      toast(ok && after && after.module ? 'WinGet module installed - winget is now asked through it, in any language.' : ok ? 'Installed, but the module could not be loaded yet - restart the app.' : 'The WinGet module could not be installed - see the log.', !ok);
      loadHome(); resolve();
    }, { path: '/api/winget-module-install', log: 'runLog', startText: 'Installing Microsoft.WinGet.Client...' }).then(started => { if (!started) resolve(); });
  });
}
async function takeVersionsForManaged() {
  const names = apps.filter(a => a.wingetId && a.managed && !a.version).map(a => a.name);
  if (!names.length) return;
  toast(`Asking winget for the current version of ${nWord(names.length, 'app')}...`);
  const w = await api('/api/checks-winget', {});
  if (!w.ok) { toast(w.error, true); return; }
  const r = await api('/api/winget-take-version', { names });
  if (!r.ok) { toast(r.error, true); return; }
  await loadApps(); loadHome();
  const inIntune = (r.deployed || []);
  toast(`${nWord(r.changed.length, 'app')} now start from winget's current version${r.skipped.length ? ' - skipped: ' + r.skipped.join('; ') : ''}.${inIntune.length ? ` Send ${inIntune.length} of them to Intune again so Intune installs that version: ${inIntune.join(', ')}.` : ''}`);
}

// Winget-AutoUpdate is no longer used: apps still installing through it (or depending on it) move to managed updates.
async function wauSwitch() {
  const p = await api('/api/wau-switch', { preview: true });
  if (!p.ok) { toast(p.error, true); return; }
  if (!p.apps.length) { toast('No app uses Winget-AutoUpdate any more.'); loadHome(); return; }
  const managedDefault = !(prefs && prefs.defaults && prefs.defaults.wingetInstallMethod === 'Winget');
  const noV = p.apps.filter(a => !a.hasVersion).map(a => a.app), dep = p.apps.filter(a => a.deployed).map(a => a.app);
  if (!(await ask(`Switch ${nWord(p.apps.length, 'app')} from Winget-AutoUpdate to ${managedDefault ? 'managed updates' : 'the winget command'}?\n\n${p.apps.slice(0, 12).map(a => a.app).join(', ')}${p.apps.length > 12 ? ', ...' : ''}\n\n` +
    (managedDefault ? `Each installs its App version with winget from then on, and new versions go to the pilot groups first.` : 'Each installs with the winget command from then on (Settings: Winget apps install with).') + ` Their dependency on Winget-AutoUpdate is removed.` +
    (managedDefault && noV.length ? ` ${noV.length} have no App version yet - those in Intune install the newest until then, the others can't be sent until they have one (Pin newest in their side panel).` : '') +
    (dep.length ? ` The ${dep.length} in Intune get the new commands sent.` : ''), { ok: 'Switch them' }))) return;
  const r = await api('/api/wau-switch', {});
  if (!r.ok) { toast(r.error, true); return; }
  await loadApps();
  const msg = `Switched ${nWord(r.changed.length, 'app')} away from Winget-AutoUpdate.` + ((r.byHand || []).length ? ` Not switched - their commands run Winget-Install.ps1 for several or other IDs, so they're left to you (editor, Install with): ${r.byHand.join(', ')}.` : '');
  const dropped = ((r.carried || []).length ? ` Kept the extra winget options WAU passed (editor, Install & detection): ${r.carried.join('; ')}.` : '') +
    ((r.dropped || []).length ? ` Left out options winget's own command can't take - check these install as you want: ${r.dropped.join('; ')}.` : '');
  const ids = ((r.tookId || []).length ? ` Winget ID taken from the WAU command (none was set): ${r.tookId.join('; ')}.` : '') +
    ((r.mismatch || []).length ? ` Not switched - the WAU command installs another Winget ID than the app has (${r.mismatch.join('; ')}). Set the Winget ID you want in the editor (App), then Switch them again.` : '');
  // Nothing changed: nothing to undo.
  if (!r.changed.length) { toast(msg + ids, (r.byHand || []).length + (r.mismatch || []).length > 0); loadHome(); return; }
  if (r.deployed.length) {
    const done = await runEach(r.deployed, name => ({ name, metadataOnly: true }), { path: '/api/deploy-start', startText: 'Sending settings for ' });
    toast(`${msg}${ids}${dropped} Pushed to Intune for ${done.length} of ${r.deployed.length}.`, done.length < r.deployed.length, [{ label: 'Undo', run: () => undoLast() }]);
  } else toast(msg + ids + dropped, (r.mismatch || []).length > 0, [{ label: 'Undo', run: () => undoLast() }]);
  loadHome();
}

async function portalStore() {
  if (!(await ask("Set Company Portal up as the Microsoft Store app?\n\nWhy: Company Portal only exists in the Microsoft Store. Packaged as a winget command it often fails on devices (the Store source in system context), and it can't be pinned to a version anyway. Intune's own Store app type is the way Microsoft recommends: the Store installs it, keeps it updated, and Intune reports its status correctly.\n\nWhat happens: its Winget ID becomes 9WZDNCRFJ3PZ, and Send to Intune creates it as that Store app type. Nothing to package.\n\nSkip this if Company Portal already reaches your devices another way (Autopilot, your Windows image, a Store app made in Intune by hand) - then remove it from the catalog instead.", { ok: 'Set it up' }))) return;
  const r = await api('/api/portal-store', {});
  if (!r.ok) { toast(r.error, true); return; }
  await loadApps();
  toast(r.changed.length ? `${r.changed.join(', ')} is a Store app now - Send to Intune creates it.` : 'Nothing to change.', false, r.changed.length ? [{ label: 'Send to Intune', run: () => openDeploy(r.changed) }, { label: 'Undo', run: () => undoLast() }] : []);
  loadHome();
}
