// Intune App Catalog - web interface: the Apps list, the app editor and its deploy settings, Deploy, Push groups, Batch edit and the More menu.
// Loaded after core.js (shared helpers and state); app.js starts the page.
'use strict';

// ---------------------------------------------------------------- apps
let apps = [], sortKey = 'name', sortDesc = false, lastClicked = null;
const selected = new Set();
let visible = [];

// What each status means and what to do about it, for the pill's tooltip.
const statusHelp = {
  'Deployed': 'In Intune - this tenant has an app with its App ID.',
  'Not in this tenant': 'The catalog has an App ID, but the tenant you are connected to has no such app - the catalog was copied from another tenant, or the app was deleted in Intune. Clear the App ID (banner above, or More > Clear App ID) and Deploy it here.',
  'Has App ID': 'The catalog has an App ID - not yet checked against Intune (no connection, or Intune could not be read).',
  'No App ID': 'Not in Intune yet, and no settings of its own: Deploy uses the default values. If it is already in Intune, Checks offers to link it.',
  'Metadata saved - ready to deploy': 'Not in Intune yet. Its own settings are saved - Deploy creates it with them.',
  'Package missing': 'Its .intunewin isn\'t in the packages folder - More > Package builds it, or Settings > Packaging for Winget apps.',
  'Custom package': 'Has a Winget ID but deploys its own .intunewin instead of the shared Winget package.',
};
// A list to pick apps from (dependencies): the chosen ones as chips on top
// (x removes one), a filter, one app per row. The checkboxes keep their
// data attribute, so whoever reads the choice doesn't change.
function appPicker(box, names, chosen, attr, emptyText, label = 'Installed first:') {
  const chips = el('div', { class: 'depchips', 'aria-live': 'polite' });
  const filter = el('input', { type: 'search', class: 'depfilter', placeholder: `Filter ${names.length} apps`, 'aria-label': 'Filter the apps' });
  const rows = names.map(n => {
    const cb = el('input', { type: 'checkbox', [attr]: n, checked: chosen.has(n) });
    return { n, li: el('li', {}, el('label', {}, cb, el('span', { text: n }))), cb };
  });
  const showChips = () => {
    const on = rows.filter(r => r.cb.checked);
    chips.replaceChildren(...(on.length ? [el('span', { class: 'deplabel', text: label }), ...on.map(r => el('span', { class: 'depchip' }, r.n,
      el('button', { type: 'button', 'aria-label': `Remove ${r.n}`, title: `Remove ${r.n}`, text: '×', onclick: () => { r.cb.checked = false; r.cb.dispatchEvent(new Event('change', { bubbles: true })); } })))]
      : [el('span', { class: 'muted', text: emptyText })]));
  };
  for (const r of rows) r.cb.addEventListener('change', showChips);
  filter.addEventListener('input', () => { const q = filter.value.trim().toLowerCase(); for (const r of rows) r.li.hidden = !!q && !r.n.toLowerCase().includes(q); });
  if (!names.length) { box.replaceChildren(el('span', { class: 'muted', text: 'No other apps in the catalog.' })); return; }
  box.replaceChildren(chips, filter, el('ul', { class: 'deprows' }, rows.map(r => r.li)));
  showChips();
}

// The ids of the apps in the connected tenant (lower case), or null while not known.
let intuneIds = null;
function tenantState(a) {
  if (!a.hasAppId) return '';
  if (!intuneIds) return 'unchecked';
  return intuneIds.has(String(a.appId).toLowerCase()) ? 'present' : 'missing';
}
async function loadIntuneIds(force) {
  if (!state || !state.configured) { intuneIds = null; renderApps(); return; }
  const r = await api('/api/intune-apps', { force: !!force });
  intuneIds = r.ok ? new Set((r.ids || []).map(x => String(x).toLowerCase())) : null;
  renderApps();
}
function statusPill(row) {
  const s = row.status || '';
  const t = tenantState(row);
  if (t === 'missing') return el('span', { class: 'pill warn', text: 'Not in this tenant' + (s ? '; ' + s : ''), title: statusHelp['Not in this tenant'] });
  if (!s && t === 'unchecked') return el('span', { class: 'pill muted', text: 'Has App ID', title: statusHelp['Has App ID'] });
  if (!s) return el('span', { class: 'pill ok', text: 'Deployed', title: statusHelp.Deployed });
  const parts = s.split('; ');
  const good = parts.every(p => p === 'Metadata saved - ready to deploy' || p === 'Custom package');
  const cls = good ? (parts.includes('Metadata saved - ready to deploy') ? 'ok' : 'info') : 'warn';
  return el('span', { class: 'pill ' + cls, text: s, title: parts.map(p => statusHelp[p]).filter(Boolean).join('\n') });
}
function auditPill(text) {
  if (!text) return '';
  if (/issue|Check failed/.test(text)) return el('span', { class: 'pill warn', text, title: 'The last time Checks read this app in detail, the catalog and Intune differed - Checks shows what and offers the fix.' });
  if (/^OK/.test(text)) return el('span', { class: 'pill ok', text, title: 'The last detailed check found the catalog and Intune the same.' });
  return el('span', { class: 'pill muted', text, title: 'Checks with "read every deployed app in detail" compares this app field by field.' });
}
function needsAttention(a) {
  return tenantState(a) === 'missing' || (a.status && !/^(Metadata saved - ready to deploy|Custom package)(; Custom package)?$/.test(a.status)) || /issue|Check failed/.test(a.audit || '');
}
const filters = {
  all: () => true,
  attention: needsAttention,
  deployed: a => tenantState(a) === 'present' || tenantState(a) === 'unchecked',
  notdeployed: a => !a.hasAppId,
  nogroups: a => !(a.groups || []).length,
  notintenant: a => tenantState(a) === 'missing',
  pkgmissing: a => a.packageMissing,
  winget: a => !!a.wingetId,
  custom: a => !a.wingetId,
};
function sortValue(a, k) {
  if (k === 'groups') return a.required * 10000 + a.available * 100 + a.uninstall;
  return String(a[k] || '').toLowerCase();
}
// The search box: words match names and Winget IDs; group:text (or group:"two words") the apps assigned to a group whose name contains it.
function parseSearch(raw) {
  const groupRe = /(?:^|\s)group:("([^"]*)"?|\S*)/ig;
  const groups = [...raw.matchAll(groupRe)].map(m => (m[2] !== undefined ? m[2] : m[1]).toLowerCase()).filter(Boolean);
  return { text: raw.replace(groupRe, ' ').trim().toLowerCase(), groups };
}
function renderApps() {
  const { text: q, groups: gq } = parseSearch($('search').value);
  const f = currentFilter();
  const list = apps.filter(a => f(a) && (!q || (a.name + ' ' + a.wingetId).toLowerCase().includes(q))
    && gq.every(g => (a.groups || []).some(x => x.toLowerCase().includes(g))));
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
  $('grid').hidden = apps.length === 0;  updateTenantBanner();
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
  const notInIntune = [...selected].filter(s => !(apps.find(a => a.name === s) || {}).hasAppId);
  setEnabled($('btnEditApp'), n === 1, n === 0 ? 'Select an app first.' : 'Select exactly one app to edit.');
  setEnabled($('btnDeploy'), n > 0, 'Select one or more apps first.');
  setEnabled($('btnPush'), n > 0 && notInIntune.length === 0, n === 0 ? 'Select one or more apps first.' : `Only apps already in Intune - deploy ${notInIntune.length === 1 ? notInIntune[0] : notInIntune.length + ' of the selected apps'} first.`);
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
  $('btnAppHistory').hidden = !name;
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
const fieldLabel = { appName: 'name', appId: 'App ID', wingetId: 'Winget ID', requiredFor: 'Required', availableFor: 'Available', uninstallFor: 'Uninstall', excludeFor: 'Excluded', settings: 'Intune details or deploy settings' };
$('btnAppHistory').addEventListener('click', async () => {
  const name = editingName;
  const r = await api('/api/app-backups', { name });
  if (!r.ok) { toast(r.error, true); return; }
  $('histTitle').textContent = `Earlier versions of ${name}`;
  $('histNote').textContent = r.backups.length ? '' : 'No earlier version kept yet - one is kept the next time this app is saved.';
  $('histRows').replaceChildren(...r.backups.map(b => el('tr', {},
    el('td', { text: b.when }),
    el('td', { text: b.changed.length ? b.changed.map(c => fieldLabel[c] || c).join(', ') : 'nothing - same as now' }),
    el('td', {}, el('button', { class: 'btn small', text: 'Restore', title: b.changed.length ? 'Put this version back as the app\'s file' : 'Same as the app is now - nothing to restore', disabled: !b.changed.length, onclick: async () => {
      if (!(await ask(`Restore ${name} as it was on ${b.when}?\n\nOnly the catalog changes - Deploy or Push sends it to Intune. The current version is kept as a copy, so this can be undone the same way.`, { ok: 'Restore', danger: false }))) return;
      const x = await api('/api/app-restore', { name, id: b.id });
      if (!x.ok) { toast(x.error, true); return; }
      toast(`${name} restored to ${b.when}.`);
      $('dlgHistory').close(); $('dlgApp').close(); await loadApps(); openEditor(x.name);
    } })))));
  $('dlgHistory').showModal();
});
$('btnRemoveApp').addEventListener('click', async () => {
  if (!(await ask(`Remove "${editingName}" from the catalog?\n\nOnly the catalog changes - nothing in Intune. A copy of its file goes to the Backups folder.`))) return;
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
  loadIntuneIds(false);
  loadUndo();
}

// ---------------------------------------------------------------- saved views (this window's own storage)
function savedViews() { try { return JSON.parse(localStorage.getItem('savedViews') || '[]'); } catch (e) { return []; } }
function storeViews(v) { try { localStorage.setItem('savedViews', JSON.stringify(v)); } catch (e) { toast('Views can\'t be kept in this window.', true); } }
function renderViewOptions() {
  const v = savedViews();
  $('savedViews').replaceChildren(...v.map(x => el('option', { value: 'view:' + x.name, text: x.name })));
  $('savedViews').hidden = !v.length;
}
const activeView = () => { const v = $('filter').value; return v.startsWith('view:') ? savedViews().find(x => 'view:' + x.name === v) || null : null; };
function currentFilter() { const sv = activeView(); return filters[sv ? sv.filter : $('filter').value] || filters.all; }
function updateViewButtons() {
  const sv = activeView();
  $('btnDeleteView').hidden = !sv;
  $('btnSaveView').hidden = !!sv || ($('filter').value === 'all' && !$('search').value.trim());
}
$('btnSaveView').addEventListener('click', async () => {
  const sel = $('filter').selectedOptions[0];
  const suggest = [sel && sel.value !== 'all' ? sel.textContent : '', $('search').value.trim()].filter(Boolean).join(', ');
  const name = ((await askText('Name of this view\n\nIt keeps the search and the filter, and appears under Saved views in the list.', suggest, 'Save')) || '').trim();
  if (!name) return;
  const v = savedViews().filter(x => x.name !== name);
  v.push({ name, filter: $('filter').value, search: $('search').value.trim() });
  v.sort((a, b) => a.name.localeCompare(b.name));
  storeViews(v); renderViewOptions(); $('filter').value = 'view:' + name; updateViewButtons();
  toast(`Saved the view "${name}".`);
});
$('btnDeleteView').addEventListener('click', async () => {
  const sv = activeView(); if (!sv) return;
  if (!(await ask(`Delete the view "${sv.name}"?\n\nOnly the saved view goes - no app changes.`))) return;
  storeViews(savedViews().filter(x => x.name !== sv.name)); renderViewOptions();
  $('filter').value = 'all'; $('search').value = ''; renderApps(); updateViewButtons();
});
renderViewOptions();

// ---------------------------------------------------------------- undo the last bulk change
let undoInfo = null, undoHidden = '';
const undoKey = u => u ? `${u.label}|${u.time}|${u.count}` : '';
async function loadUndo() {
  const r = await api('/api/undo-info');
  undoInfo = r.ok ? r.undo : null;
  $('undoBanner').hidden = !undoInfo || undoHidden === undoKey(undoInfo);
  if (undoInfo) $('undoText').textContent = `${undoInfo.label} changed ${undoInfo.count} app${undoInfo.count === 1 ? '' : 's'} at ${undoInfo.time}.`;
}
async function undoLast() {
  await loadUndo();
  if (!undoInfo) { toast('There is no bulk change to undo.', true); return; }
  const u = undoInfo, list = u.apps.slice(0, 15).join('\n') + (u.apps.length > 15 ? `\n... and ${u.apps.length - 15} more` : '');
  if (!(await ask(`Undo "${u.label}" (${u.time})?\n\nThese ${u.count} app file(s) get back what they had before:\n${list}\n\nA file changed since (an editor save, a deploy's App ID) is left alone. Intune isn't touched - if you already pushed, push again afterwards.`, { ok: 'Undo', danger: false }))) return;
  const r = await api('/api/undo-last');
  if (!r.ok) { toast(r.error, true); return; }
  toast(`Undid "${r.label}": ${r.restored.length} app(s) restored.${r.skipped.length ? ' Left alone: ' + r.skipped.join(', ') + '.' : ''}`, r.skipped.length > 0);
  await loadApps();
  if (groupsLoaded) loadGroups();
}
$('btnUndo').addEventListener('click', undoLast);
$('btnUndoHide').addEventListener('click', () => { undoHidden = undoKey(undoInfo); $('undoBanner').hidden = true; });

// ---------------------------------------------------------------- the Catalog menu (the whole catalog)
const catMenu = $('catalogMenu');
function placeMenu(m, x, y) {
  m.hidden = false;
  const r = m.getBoundingClientRect();
  m.style.left = Math.max(8, Math.min(x, innerWidth - r.width - 8)) + 'px';
  m.style.top = Math.min(y, innerHeight - r.height - 8) + 'px';
  const first = m.querySelector('button:not(:disabled)'); if (first) first.focus();
}
// Arrow keys move between a menu's items; Escape closes it (every .menu).
for (const m of document.querySelectorAll('.menu')) m.addEventListener('keydown', e => {
  if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
  e.preventDefault();
  const items = [...m.querySelectorAll('button:not(:disabled)')], i = items.indexOf(document.activeElement);
  items[(i + (e.key === 'ArrowDown' ? 1 : items.length - 1)) % items.length].focus();
});
$('btnCatalog').addEventListener('click', async e => {
  e.stopPropagation();
  closeMenu();
  setEnabled(catMenu.querySelector('[data-cact=undo]'), !!undoInfo, 'Nothing to undo - no bulk change since the app started.');
  setEnabled(catMenu.querySelector('[data-cact=replace]'), apps.some(a => (a.groups || []).length), 'No app is assigned to a group.');
  setEnabled(catMenu.querySelector('[data-cact=export]'), apps.length > 0, 'The catalog is empty.');
  const r = $('btnCatalog').getBoundingClientRect();
  placeMenu(catMenu, r.right - 240, r.bottom + 4);
});
document.addEventListener('click', e => { if (!catMenu.contains(e.target)) catMenu.hidden = true; });
document.addEventListener('keydown', e => { if (e.key === 'Escape' && !catMenu.hidden) { catMenu.hidden = true; $('btnCatalog').focus(); } });
catMenu.addEventListener('click', e => {
  const b = e.target.closest('button'); if (!b || b.disabled) return;
  catMenu.hidden = true;
  ({ export: exportCsv, import: openCsvImport, replace: () => openReplace({}), undo: undoLast,
    reload: () => { loadApps(); loadState(); }, folder: () => openFolder('catalog-folder') })[b.dataset.cact]();
});
// Apps whose App ID the connected tenant doesn't know: a banner says so, with one button for all of them.
function updateTenantBanner() {
  const missing = apps.filter(a => tenantState(a) === 'missing');
  $('tenantBanner').hidden = missing.length === 0;
  $('tenantBannerText').textContent = missing.length === apps.filter(a => a.hasAppId).length && missing.length > 1
    ? `None of the ${missing.length} App IDs in this catalog exist in the tenant you're connected to - was the catalog copied from another tenant?`
    : `${missing.length} app${missing.length === 1 ? ' has an App ID' : 's have App IDs'} this tenant doesn't know - copied from another tenant, or deleted in Intune.`;
}
$('btnTenantShow').addEventListener('click', () => { $('filter').value = 'notintenant'; renderApps(); });
$('btnTenantClear').addEventListener('click', async () => {
  const names = apps.filter(a => tenantState(a) === 'missing').map(a => a.name);
  if (!names.length) return;
  if (!(await ask(`Clear the App ID of ${names.length} app${names.length === 1 ? '' : 's'}?\n\nOnly the catalog changes - their settings, groups and packages stay, and they read "ready to deploy". Deploy then creates them in this tenant. Each file is kept as a copy first (Earlier versions...).`, { ok: 'Clear App IDs', danger: false }))) return;
  const r = await api('/api/clear-appids', { names });
  toast(r.ok ? `Cleared ${r.cleared.length} App ID(s).` : r.error, !r.ok);
  if ($('filter').value === 'notintenant') $('filter').value = 'all';
  await loadApps();
});
for (const th of document.querySelectorAll('.grid th')) th.addEventListener('click', () => {
  if (sortKey === th.dataset.sort) sortDesc = !sortDesc; else { sortKey = th.dataset.sort; sortDesc = false; }
  renderApps();
});
let searchTimer = null;
$('search').addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(renderApps, 120); });
$('filter').addEventListener('change', () => {
  const sv = activeView();
  if (sv) $('search').value = sv.search || '';
  renderApps(); updateViewButtons();
});
$('search').addEventListener('input', updateViewButtons);
document.addEventListener('keydown', e => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f' && !$('viewApps').hidden) { e.preventDefault(); $('search').focus(); }
  if (e.key === 'F5') { e.preventDefault(); loadApps(); loadState(); }
  // Ctrl+S in the app editor saves it (the form's own submit, with its checks).
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's' && $('dlgApp').open) { e.preventDefault(); $('appForm').requestSubmit(); return; }
  listKeys(e);
});
// The Apps list by keyboard - only while nothing else has the keys: no
// dialog or menu open, and no field focused (typing is never taken over).
function listKeys(e) {
  if ($('viewApps').hidden || document.querySelector('dialog[open]') || document.querySelector('.menu:not([hidden])')) return;
  if (e.target.closest && e.target.closest('input, textarea, select, [contenteditable]')) return;
  if (!visible.length) return;
  const ctrl = e.ctrlKey || e.metaKey;
  const show = n => { const r = [...$('gridBody').children].find(t => t.dataset.name === n); if (r) r.scrollIntoView({ block: 'nearest' }); };
  const select = (n, extend) => {
    if (!extend) selected.clear();
    if (extend && lastClicked && visible.includes(lastClicked)) {
      const anchor = visible.indexOf(lastClicked), to = visible.indexOf(n);
      selected.clear();
      for (const x of visible.slice(Math.min(anchor, to), Math.max(anchor, to) + 1)) selected.add(x);
    } else { selected.add(n); lastClicked = n; }
    for (const r of $('gridBody').children) r.classList.toggle('sel', selected.has(r.dataset.name));
    updateActions(); show(n); cursor = n;
  };
  const at = visible.indexOf(cursor && visible.includes(cursor) ? cursor : (lastClicked && visible.includes(lastClicked) ? lastClicked : visible[0]));
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    const next = selected.size === 0 ? 0 : Math.max(0, Math.min(visible.length - 1, at + (e.key === 'ArrowDown' ? 1 : -1)));
    select(visible[next], e.shiftKey);
  }
  else if (e.key === 'Home' || e.key === 'End') { e.preventDefault(); select(visible[e.key === 'Home' ? 0 : visible.length - 1], e.shiftKey); }
  else if (ctrl && e.key.toLowerCase() === 'a') {
    e.preventDefault(); selected.clear(); for (const n of visible) selected.add(n);
    for (const r of $('gridBody').children) r.classList.toggle('sel', true); updateActions();
  }
  else if (e.key === 'Enter' && selected.size === 1) { e.preventDefault(); openEditor([...selected][0]); }
  else if (e.key === 'Delete' && selected.size === 1) { e.preventDefault(); menuAction('remove'); }
}
let cursor = null;

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
  appPicker($('xDeps'), editorApps, deps, 'data-dep', 'None - this app installs on its own.');
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
let deployPlan = [], deployResults = {}, deployStop = false, deployRunning = false;
function setDeployStatus(name, cls, text, detail) {
  const row = [...$('deployRows').children].find(r => r.dataset.name === name);
  if (row) row.lastChild.replaceChildren(el('span', { class: 'pill ' + cls, text, title: detail || '' }), detail ? el('span', { class: 'why', text: detail }) : '');
}
// "3 of 10 - 2 done, 1 failed" and the bar, from deployResults.
function deployProgress() {
  const ready = deployPlan.filter(a => a.ready), res = ready.map(a => deployResults[a.name]).filter(Boolean);
  const n = k => res.filter(x => x === k).length;
  $('deployProgress').hidden = false;
  $('deployBar').style.width = (ready.length ? Math.round(100 * res.length / ready.length) : 0) + '%';
  $('deployProgressText').textContent = `${res.length} of ${ready.length}` + [[n('ok'), 'done'], [n('failed'), 'failed'], [n('skipped'), 'skipped'], [n('stopped'), 'not started']].filter(x => x[0]).map(x => ` - ${x[0]} ${x[1]}`).join('');
}
$('btnDeploy').addEventListener('click', async () => {
  const r = await api('/api/deploy-plan', { names: [...selected] });
  if (!r.ok) { toast(r.error, true); return; }
  deployPlan = r.apps; deployResults = {};
  $('deployRows').replaceChildren(...deployPlan.map(a => el('tr', { 'data-name': a.name },
    el('td', { text: a.name }), el('td', { text: a.update ? 'Update settings' : 'Create' }),
    el('td', {}, a.ready ? el('span', { class: 'pill muted', text: 'Waiting' }) : el('span', { class: 'pill warn', text: 'Skipped', title: a.reason }), a.ready ? '' : el('span', { class: 'why', text: a.reason })))));
  if (r.circular && r.circular.length) toast('These depend on each other in a circle: ' + r.circular.join(', '), true);
  $('deployLog').textContent = r.note ? r.note + '\n' : '';
  $('deployProgress').hidden = true; $('btnDeployStop').hidden = true; $('btnDeployRetry').hidden = true;
  const n = deployPlan.filter(a => a.ready).length;
  $('btnDeployGo').textContent = n === 1 ? 'Deploy 1 app' : `Deploy ${n} apps`;
  $('btnDeployGo').disabled = n === 0;
  $('dlgDeploy').showModal();
});
// One app: deploy, then push its groups when the step asks for it. Resolves with whether the deploy worked.
function deployOne(name) {
  return new Promise(resolve => {
    runJob({ name }, async (ok, result, after) => {
      if (!ok) { resolve({ ok: false, error: (result && result.error) || 'see the log' }); return; }
      if (after && after.pushGroups) {
        setDeployStatus(name, 'info', 'Pushing groups...');
        const started = await runJob({ names: [name], mode: 'AfterDeploy' }, ok2 => resolve({ ok: true, groups: ok2 }),
          { path: '/api/push-start', log: 'deployLog', startText: `Pushing ${name}'s groups...` });
        if (!started) resolve({ ok: true, groups: false });
        return;
      }
      resolve({ ok: true, groups: null });
    }, { path: '/api/deploy-start', log: 'deployLog', startText: `Deploying ${name}...` }).then(started => { if (!started) resolve({ ok: false, error: 'another action was still running' }); });
  });
}
// Runs the queue in plan order. An app whose dependency failed (or was skipped) is skipped, saying which.
async function runDeployQueue(names) {
  deployRunning = true; deployStop = false;
  $('btnDeployGo').disabled = true; $('btnDeployRetry').hidden = true; $('btnDeployStop').hidden = false; $('btnDeployStop').disabled = false;
  for (const name of names) delete deployResults[name];
  for (const name of names) setDeployStatus(name, 'muted', 'Waiting');
  deployProgress();
  const plan = Object.fromEntries(deployPlan.map(a => [a.name, a]));
  const notOk = n => ['failed', 'skipped', 'stopped'].includes(deployResults[n]) || (plan[n] && !plan[n].ready);
  for (const name of names) {
    if (deployStop) { deployResults[name] = 'stopped'; setDeployStatus(name, 'muted', 'Not started', 'Stopped before this app.'); continue; }
    const blocker = ((plan[name] && plan[name].deps) || []).find(notOk);
    if (blocker) { deployResults[name] = 'skipped'; setDeployStatus(name, 'warn', 'Skipped', `Needs ${blocker}, which wasn't deployed.`); deployProgress(); continue; }
    setDeployStatus(name, 'info', 'Running...');
    const r = await deployOne(name);
    deployResults[name] = r.ok ? 'ok' : 'failed';
    if (!r.ok) setDeployStatus(name, 'err', 'Failed', r.error);
    else setDeployStatus(name, r.groups === false ? 'warn' : 'ok', r.groups === true ? 'Done, groups pushed' : r.groups === false ? 'Done, groups failed' : 'Done', r.groups === false ? 'Push groups again from the toolbar.' : '');
    deployProgress();
  }
  deployRunning = false;
  $('btnDeployStop').hidden = true;
  const ready = deployPlan.filter(a => a.ready).map(a => a.name);
  const retry = ready.filter(n => ['failed', 'skipped', 'stopped'].includes(deployResults[n]));
  $('btnDeployRetry').hidden = !retry.length;
  $('btnDeployRetry').textContent = retry.length ? `Retry ${retry.length}` : 'Retry failed';
  $('btnDeployGo').textContent = 'Done';
  const okN = ready.filter(n => deployResults[n] === 'ok').length;
  toast(`Deploy finished: ${okN} of ${ready.length} done${retry.length ? `, ${retry.length} to retry` : ''}.`, okN < ready.length);
  loadApps();
}
$('btnDeployGo').addEventListener('click', () => runDeployQueue(deployPlan.filter(a => a.ready).map(a => a.name)));
$('btnDeployRetry').addEventListener('click', () => runDeployQueue(deployPlan.filter(a => a.ready && ['failed', 'skipped', 'stopped'].includes(deployResults[a.name])).map(a => a.name)));
$('btnDeployStop').addEventListener('click', () => { deployStop = true; $('btnDeployStop').disabled = true; toast('Stopping after the app that is running.'); });
$('dlgDeploy').addEventListener('cancel', e => { if (deployRunning) { e.preventDefault(); toast('Deploying - use "Stop after this app" first, or wait.', true); } });
$('btnDeployClose').addEventListener('click', e => { if (deployRunning) { e.stopImmediatePropagation(); toast('Deploying - use "Stop after this app" first, or wait.', true); } }, true);

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

// ---------------------------------------------------------------- batch edit, add/remove groups
function openBatch(names) {
  batchNames = names;
  $('batchTitle').textContent = `Batch edit - ${names.length} app(s)`;
  $('batchText').textContent = `Tick the fields to change on ${names.join(', ')}. Everything else stays as each app has it.`;
  for (const c of document.querySelectorAll('[data-bf]')) c.checked = false;
  $('bDepMode').value = 'add';
  $('bMinOs').replaceChildren(...((prefs && prefs.minOsChoices) || [{ value: 'W10_22H2', label: 'Windows 10 22H2' }]).map(o => el('option', { value: o.value, text: o.label || o.value })));
  $('bMinOs').value = 'W10_22H2';
  appPicker($('bDeps'), apps.map(a => a.name), new Set(), 'data-bdep', 'None - tick the apps to install first.');
  $('batchErr').hidden = true; $('batchLog').hidden = true; $('batchLog').textContent = '';
  $('btnBatchGo').disabled = false;
  batchReset();
  $('dlgBatch').showModal();
}
// The first click on the button shows what would change; any change to the form goes back to that.
let batchPreviewed = false;
function batchReset() {
  batchPreviewed = false;
  $('batchPreview').hidden = true; $('batchPreview').replaceChildren();
  $('btnBatchGo').textContent = 'Preview changes';
}
$('dlgBatch').addEventListener('input', e => { if (!e.target.closest('#batchPreview') && e.target.id !== 'bPush') batchReset(); });
$('dlgBatch').addEventListener('change', e => { if (!e.target.closest('#batchPreview') && e.target.id !== 'bPush') batchReset(); });
// Field names as the editor shows them, for the previews.
const fieldNames = { requiredFor: 'Required', availableFor: 'Available', uninstallFor: 'Uninstall', excludeFor: 'Excluded', dependencies: 'Dependencies',
  description: 'Description', publisher: 'Publisher', owner: 'Owner', developer: 'Developer', notes: 'Notes', informationUrl: 'Information URL', privacyUrl: 'Privacy URL',
  architecture: 'Architecture', minOSKey: 'Minimum OS', installContext: 'Install for', installTimeMinutes: 'Install time (min)', deviceRestartBehavior: 'Restart',
  installCommand: 'Install command', uninstallCommand: 'Uninstall command', minDiskSpaceMB: 'Min. disk space (MB)', minMemoryMB: 'Min. memory (MB)', minProcessors: 'Min. CPUs',
  minCpuSpeedMHz: 'Min. CPU speed (MHz)', allowAvailableUninstall: 'Uninstall from Company Portal', isFeatured: 'Featured in Company Portal', returnCodes: 'Return codes' };
// A preview table: the old and new value of each field that changes, per app.
function previewTable(box, changes, empty, labels = fieldNames) {
  if (!changes.length) { box.replaceChildren(el('p', { class: 'muted', text: empty })); box.hidden = false; return; }
  let last = '';
  const shown = changes.slice(0, 400);
  box.replaceChildren(el('div', { class: 'tablewrap short' }, el('table', { class: 'plan' },
    el('thead', {}, el('tr', {}, el('th', { text: 'App' }), el('th', { text: 'Field' }), el('th', { text: 'Now' }), el('th', { text: 'New' }))),
    el('tbody', {}, ...shown.map(c => { const first = c.app !== last; last = c.app; return el('tr', { class: first ? 'first' : '' },
      el('td', { class: 'name', text: first ? c.app : '' }), el('td', { text: labels[c.field] || c.field }),
      el('td', { class: 'chg rem', text: c.old || '(empty)' }), el('td', { class: 'chg add', text: c.new || '(empty)' })); })))),
    changes.length > shown.length ? el('p', { class: 'muted', text: `... and ${changes.length - shown.length} more changes.` }) : '');
  box.hidden = false;
  box.scrollIntoView({ block: 'nearest' });
}
let batchNames = [];
for (const box of document.querySelectorAll('.bfield')) box.addEventListener('input', e => { if (!e.target.matches('[data-bf], .depfilter')) { const c = box.querySelector('[data-bf]'); if (c) c.checked = true; } });
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
  if ('dependencies' in changes) changes.dependenciesMode = $('bDepMode').value;
  return changes;
}
$('btnBatchGo').addEventListener('click', async () => {
  $('batchErr').hidden = true;
  if (!batchPreviewed) {
    const p = await api('/api/batch-edit', { names: batchNames, changes: readBatch(), preview: true });
    if (!p.ok) { $('batchErr').textContent = p.error; $('batchErr').hidden = false; return; }
    previewTable($('batchPreview'), p.changes, 'Nothing would change - every selected app already has these values.');
    const apps = new Set(p.changes.map(c => c.app)).size;
    if (!p.changes.length) return;
    batchPreviewed = true;
    $('btnBatchGo').textContent = `Apply ${p.changes.length} change${p.changes.length === 1 ? '' : 's'} to ${apps} app${apps === 1 ? '' : 's'}`;
    return;
  }
  const r = await api('/api/batch-edit', { names: batchNames, changes: readBatch() });
  if (!r.ok) { $('batchErr').textContent = r.error; $('batchErr').hidden = false; return; }
  batchReset();
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
    replacegroup: sel.some(a => (a.groups || []).length), copyid: anyId, clearid: anyId, delete: anyId, remove: any };
  const why = {
    package: 'Winget apps use the shared package (Settings > Packaging).', pull: 'Only for apps already in Intune (with an App ID).',
    pushsettings: 'Only for apps already in Intune (with an App ID).', status: one ? 'This app isn\'t in Intune yet.' : 'Select exactly one app that is in Intune.',
    batchedit: 'Select one or more apps first.', addgroups: 'Select one or more apps first.', removegroups: 'Select one or more apps first.',
    replacegroup: any ? 'None of the selected apps is assigned to a group.' : 'Select one or more apps first.',
    copyid: 'None of the selected apps has an App ID.', clearid: 'None of the selected apps has an App ID.',
    delete: 'None of the selected apps is in Intune.', remove: 'Select one or more apps first.',
  };
  for (const b of menu.querySelectorAll('button')) setEnabled(b, !!enable[b.dataset.act], why[b.dataset.act]);
  menu.querySelector('[data-act=package]').textContent = !any ? 'Package every app with its own installer' : enable.package ? `Package ${sel.length > 1 ? 'the selected apps' : 'this app'} (build .intunewin)` : 'Package (Winget apps use the shared package)';
  const ids = sel.filter(a => a.hasAppId).length;
  menu.querySelector('[data-act=copyid]').textContent = ids > 1 ? `Copy ${ids} App IDs` : 'Copy App ID';
  menu.querySelector('[data-act=clearid]').textContent = ids > 1 ? `Clear ${ids} App IDs...` : 'Clear App ID...';
  menu.querySelector('[data-act=remove]').textContent = sel.length > 1 ? `Remove ${sel.length} apps from catalog...` : 'Remove from catalog...';
  catMenu.hidden = true;
  placeMenu(menu, x, y);
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
menu.addEventListener('click', e => {
  const b = e.target.closest('button'); if (!b || b.disabled) return;
  closeMenu();
  menuAction(b.dataset.act);
});
// One More-menu action on the selected apps (also the Delete key: 'remove').
async function menuAction(act) {
  const names = [...selected], one = oneSelected(), sel = () => names.map(n => apps.find(a => a.name === n)).filter(Boolean);
  switch (act) {
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
    case 'replacegroup': openReplace({ names }); break;
    case 'copyid': {
      const ids = sel().filter(a => a.hasAppId).map(a => a.appId);
      try { await navigator.clipboard.writeText(ids.join('\n')); toast(ids.length > 1 ? `Copied ${ids.length} App IDs.` : 'Copied ' + ids[0]); } catch (err) { toast('Could not copy: ' + ids.join(', '), true); }
      break;
    }
    case 'clearid': {
      const ids = sel().filter(a => a.hasAppId).map(a => a.name);
      if (!(await ask(`Clear ${ids.length === 1 ? `${ids[0]}'s App ID` : `the App IDs of ${ids.length} apps`} in the catalog?\n\nOnly the catalog changes; the app${ids.length === 1 ? ' stays' : 's stay'} in Intune. Undo takes it back.`))) return;
      const r = await api('/api/clear-appids', { names: ids }); toast(r.ok ? `Cleared ${r.cleared.length} App ID(s).` : r.error, !r.ok); loadApps();
      break;
    }
    case 'delete': {
      const del = sel().filter(a => a.hasAppId).map(a => a.name);
      if (!(await ask(`Delete ${del.length === 1 ? `"${del[0]}"` : `these ${del.length} apps`} from Intune?\n\n${del.length > 1 ? del.join('\n') + '\n\n' : ''}Their assignments go with them - devices that have them keep them installed, but Intune stops managing them. The catalog entries stay, without an App ID.`))) return;
      runDialog('Delete from Intune', del.join(', '));
      const done = await runEach(del, name => ({ name }), { path: '/api/delete-intune', log: 'runLog', startText: 'Deleting ' });
      toast(`Deleted ${done.length} of ${del.length} app(s) from Intune.`, done.length < del.length); loadApps();
      break;
    }
    case 'remove': {
      if (!(await ask(`Remove ${names.length === 1 ? `"${names[0]}"` : `${names.length} apps`} from the catalog?\n\n${names.length > 1 ? names.slice(0, 15).join('\n') + (names.length > 15 ? `\n... and ${names.length - 15} more` : '') + '\n\n' : ''}Only the catalog changes - nothing in Intune. A copy of each file goes to the Backups folder.`))) return;
      const failed = [];
      for (const n of names) { const r = await api('/api/app-remove', { name: n }); if (r.ok) selected.delete(n); else failed.push(`${n}: ${r.error}`); }
      toast(failed.length ? 'Not removed: ' + failed.join('; ') : `Removed ${names.length} app(s) from the catalog.`, failed.length > 0); loadApps();
      break;
    }
  }
}

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

// ---------------------------------------------------------------- replace a group (catalog only)
let replaceNames = [];
function openReplace({ names = [], old = '' }) {
  replaceNames = names;
  const pool = names.length ? apps.filter(a => names.includes(a.name)) : apps;
  const used = [...new Set(pool.flatMap(a => a.groups || []))].sort((a, b) => a.localeCompare(b));
  if (!used.length) { toast('None of these apps is assigned to a group.', true); return; }
  $('rpTitle').textContent = names.length ? `Replace a group on ${names.length} app${names.length === 1 ? '' : 's'}` : 'Replace a group';
  $('rpText').textContent = 'Every assignment to the old group - Required, Available, Uninstall and Excluded - names the new one instead, in the catalog. Entra ID isn\'t touched (Rename on the Groups page renames a group there). Push groups sends it to Intune.';
  $('rpOld').replaceChildren(...used.map(g => el('option', { value: g, text: g })));
  if (old && used.some(g => g.toLowerCase() === old.toLowerCase())) $('rpOld').value = used.find(g => g.toLowerCase() === old.toLowerCase());
  const known = [...new Set(apps.flatMap(a => a.groups || []).concat((prefs && prefs.favoriteGroups) || []))].sort();
  $('rpKnown').replaceChildren(...known.map(g => el('option', { value: g })));
  $('rpNew').value = ''; $('rpErr').hidden = true;
  const count = () => { const o = $('rpOld').value.toLowerCase(); const n = pool.filter(a => (a.groups || []).some(g => g.toLowerCase() === o)).length; $('rpCount').textContent = `${n} app${n === 1 ? '' : 's'} use it.`; };
  $('rpOld').onchange = count; count();
  $('dlgReplace').showModal(); $('rpNew').focus();
}
$('rpNew').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); $('btnReplaceGo').click(); } });
$('btnReplaceGo').addEventListener('click', async () => {
  const oldName = $('rpOld').value, newName = $('rpNew').value.trim();
  if (!newName) { $('rpErr').textContent = 'Type the new group name.'; $('rpErr').hidden = false; return; }
  const r = await api('/api/replace-group', { old: oldName, new: newName, names: replaceNames });
  if (!r.ok) { $('rpErr').textContent = r.error; $('rpErr').hidden = false; return; }
  $('dlgReplace').close();
  toast(`Replaced ${oldName} with ${newName} on ${r.changed.length} app(s) in the catalog.`);
  await loadApps();
  if (groupsLoaded) { await loadGroups(); if (group && group.name.toLowerCase() === oldName.toLowerCase()) openGroup(newName); }
  if (r.deployed.length && await ask(`Push groups for the ${r.deployed.length} deployed app(s) now?\n\n${r.deployed.join('\n')}`, { ok: 'Push groups', danger: false })) openPushGroups(r.deployed);
});

// ---------------------------------------------------------------- CSV export and import
async function exportCsv() {
  const r = await api('/api/csv-export');
  if (!r.ok) { toast(r.error, true); return; }
  // A byte-order mark, so Excel reads the file as UTF-8 (umlauts, accents).
  const url = URL.createObjectURL(new Blob(['﻿' + r.text], { type: 'text/csv;charset=utf-8' }));
  const a = el('a', { href: url, download: `intune-app-catalog-${new Date().toISOString().slice(0, 10)}.csv` });
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
  toast(`Exported ${r.count} app(s) to your Downloads folder. Edit in Excel, save as CSV, then Catalog > Import from CSV.`);
}
let csvText = '', csvChanges = [];
function openCsvImport() {
  csvText = ''; csvChanges = [];
  $('csvFile').value = ''; $('csvName').textContent = '';
  $('csvPreview').hidden = true; $('csvErr').hidden = true; $('csvNote').textContent = ''; $('csvLog').hidden = true; $('csvLog').textContent = ''; $('csvPushRow').hidden = true;
  $('btnCsvGo').disabled = true; $('btnCsvGo').textContent = 'Apply';
  $('dlgCsv').showModal();
}
$('csvFile').addEventListener('change', async () => {
  const f = $('csvFile').files[0];
  $('csvErr').hidden = true; $('btnCsvGo').disabled = true; $('csvPreview').hidden = true;
  if (!f) return;
  if (f.size > 5 * 1024 * 1024) { $('csvErr').textContent = 'The file is too large for a catalog (over 5 MB).'; $('csvErr').hidden = false; return; }
  csvText = await f.text();
  $('csvName').textContent = 'Reading...';
  const r = await api('/api/csv-import', { text: csvText, preview: true });
  $('csvName').textContent = '';
  if (!r.ok) { $('csvErr').textContent = r.error; $('csvErr').hidden = false; return; }
  csvChanges = r.changes;
  const notes = [];
  $('csvNote').textContent = '';
  if (r.errors.length) notes.push('Fix these rows first: ' + r.errors.join('; '));
  if (r.notFound.length) notes.push(`Not in the catalog, skipped: ${r.notFound.join(', ')}.`);
  if (r.ignoredColumns.length) notes.push(`Columns that aren't read: ${r.ignoredColumns.join(', ')}.`);
  previewTable($('csvPreview'), r.changes, 'Nothing differs from the catalog.');
  $('csvNote').textContent = notes.filter(n => !n.startsWith('Fix')).join(' ');
  if (r.errors.length) { $('csvErr').textContent = notes[0]; $('csvErr').hidden = false; }
  const n = new Set(r.changes.map(c => c.app)).size;
  $('btnCsvGo').disabled = !r.changes.length || r.errors.length > 0;
  $('btnCsvGo').textContent = r.changes.length ? `Apply ${r.changes.length} change${r.changes.length === 1 ? '' : 's'} to ${n} app${n === 1 ? '' : 's'}` : 'Apply';
  const deployedTouched = r.apps.filter(a => apps.some(x => x.name === a && x.hasAppId));
  $('csvPushRow').hidden = !deployedTouched.length;
});
$('btnCsvGo').addEventListener('click', async () => {
  $('btnCsvGo').disabled = true;
  const r = await api('/api/csv-import', { text: csvText });
  if (!r.ok) { $('csvErr').textContent = r.error; $('csvErr').hidden = false; return; }
  toast(`Imported ${r.changes.length} change(s) on ${r.apps.length} app(s). Undo takes it back.`);
  await loadApps();
  if (groupsLoaded) loadGroups();
  const groupFields = ['requiredFor', 'availableFor', 'uninstallFor', 'excludeFor'];
  const meta = r.deployed.filter(a => r.changes.some(c => c.app === a && !groupFields.includes(c.field)));
  const grp = r.deployed.filter(a => r.changes.some(c => c.app === a && groupFields.includes(c.field)));
  if ($('csvPush').checked && meta.length) {
    $('csvLog').hidden = false;
    const done = await runEach(meta, name => ({ name, metadataOnly: true }), { path: '/api/deploy-start', log: 'csvLog', startText: 'Pushing ' });
    toast(`Settings pushed for ${done.length} of ${meta.length} app(s).`, done.length < meta.length);
  }
  $('btnCsvGo').textContent = 'Done';
  if (grp.length && await ask(`Push groups for the ${grp.length} deployed app(s) whose groups changed?\n\n${grp.join('\n')}`, { ok: 'Push groups', danger: false })) { $('dlgCsv').close(); openPushGroups(grp); }
});
