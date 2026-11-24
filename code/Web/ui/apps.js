// Intune App Catalog - web interface: the Apps list, the app editor and its deploy settings, Deploy, Send groups, Batch edit and the More menu.
// Loaded after core.js (shared helpers and state); app.js starts the page.
'use strict';

// ---------------------------------------------------------------- apps
let apps = [], sortKey = 'name', sortDesc = false, lastClicked = null;
const selected = new Set();
let visible = [];

// What each status means and what to do about it, for the pill's tooltip.
const statusHelp = {
  'Deployed': 'In Intune - this tenant has an app with its App ID.',
  'Not in this tenant': 'The catalog has an App ID, but the tenant you are connected to has no such app - the catalog was copied from another tenant, or the app was deleted in Intune. Clear the App ID (banner above, or More > Clear App ID) and Send it to Intune here.',
  'Has App ID': 'The catalog has an App ID - not yet checked against Intune (no connection, or Intune could not be read).',
  'No App ID': 'Not in Intune yet, and no settings of its own: Send to Intune uses the default values. If it is already in Intune, Checks offers to link it.',
  'Metadata saved - ready to deploy': 'Not in Intune yet. Its own settings are saved - Send to Intune creates it with them.',
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

// App icons: fetched once per icon (iconTag changes when the icon does), shown in the list.
const iconCache = new Map();
let iconsWanted = new Set(), iconTimer = null;
// No icon (yet): the app's first letter on a colour of its own - a placeholder that reads as an icon, not as a checkbox.
function iconLetter(name) {
  const t = String(name || '?').trim(), letter = (t.match(/[A-Za-z0-9]/) || ['?'])[0].toUpperCase();
  let h = 0; for (const ch of t) h = (h * 31 + ch.charCodeAt(0)) % 360;
  // Through the style object: the page's Content-Security-Policy refuses inline style attributes.
  const n = el('span', { class: 'appicon none', 'aria-hidden': 'true', text: letter }); n.style.setProperty('--h', h); return n;
}
function iconFor(a) {
  if (!a.hasIcon) return iconLetter(a.name);
  const c = iconCache.get(a.name);
  if (c && c.tag === a.iconTag) return el('img', { class: 'appicon', src: c.url, alt: '' });
  iconsWanted.add(a.name); clearTimeout(iconTimer); iconTimer = setTimeout(loadIcons, 50);
  return iconLetter(a.name);
}
async function loadIcons() {
  const names = [...iconsWanted]; iconsWanted = new Set();
  if (!names.length) return;
  const r = await api('/api/app-icons', { names });
  if (!r.ok) return;
  for (const n of names) { const a = apps.find(x => x.name === n); if (a && r.icons[n]) iconCache.set(n, { tag: a.iconTag, url: r.icons[n] }); }
  for (const tr of $('gridBody').children) {
    const c = iconCache.get(tr.dataset.name), span = tr.firstChild && tr.firstChild.firstChild;
    if (c && span && span.classList && span.classList.contains('none')) span.replaceWith(el('img', { class: 'appicon', src: c.url, alt: '' }));
  }
}

// The ids of the apps in the connected tenant (lower case), or null while not known.
let intuneIds = null, intuneApps = null, intuneAt = '';
function tenantState(a) {
  if (!a.hasAppId) return '';
  if (!intuneIds) return 'unchecked';
  return intuneIds.has(String(a.appId).toLowerCase()) ? 'present' : 'missing';
}
async function loadIntuneIds(force) {
  if (!state || !state.configured) { intuneIds = null; renderApps(); return; }
  const r = await api('/api/intune-apps', { force: !!force });
  intuneIds = r.ok ? new Set((r.ids || []).map(x => String(x).toLowerCase())) : null;
  intuneApps = r.ok ? (r.apps || []) : null; intuneAt = r.ok ? r.at : '';
  renderApps();
}
// An MSI line-of-business app in Intune - by the type Intune has now (the live list), else by the catalog's label.
const isLobMsi = a => !!a.appId && ((intuneApps || []).some(x => x.id === String(a.appId).toLowerCase() && x.type === 'windowsMobileMSI') || /line-of-business/.test(a.type || ''));
// Intune's app types, short for the list (the full name is the cell's tooltip).
const shortType = t => ({ 'Windows app (Win32)': 'Win32', 'Windows MSI line-of-business app': 'MSI (line-of-business)', 'Microsoft Store app (new)': 'Store', 'Microsoft 365 Apps (Windows 10 and later)': 'Microsoft 365' })[t] || t || '';
// What the server's status words are shown as - the same meaning, in the words the rest of the page uses.
const statusLabel = { 'No App ID': 'Not in Intune yet', 'Metadata saved - ready to deploy': 'Not in Intune yet - own settings', 'Custom package': 'Winget ID + own package' };
function statusPill(row) {
  if (row.retiringSince) return el('span', { class: 'pill err', text: 'Retiring', title: `Being uninstalled from its groups since ${row.retiringSince} - More > Retire shows how far, and finishes it.` });
  const s = row.status || '';
  const t = tenantState(row);
  if (t === 'missing') return el('span', { class: 'pill warn', text: 'Not in this tenant' + (s ? '; ' + s.split('; ').map(p => statusLabel[p] || p).join('; ') : ''), title: statusHelp['Not in this tenant'] });
  if (!s && t === 'unchecked') return el('span', { class: 'pill muted', text: 'Has App ID', title: statusHelp['Has App ID'] });
  if (!s) return el('span', { class: 'pill ok', text: 'In Intune', title: statusHelp.Deployed });
  const parts = s.split('; ');
  const plain = parts.every(p => p === 'No App ID' || p === 'Metadata saved - ready to deploy' || p === 'Custom package');
  const cls = !plain ? 'warn' : parts.includes('No App ID') ? 'muted' : 'info';
  return el('span', { class: 'pill ' + cls, text: parts.map(p => statusLabel[p] || p).join('; '), title: parts.map(p => statusHelp[p]).filter(Boolean).join('\n') });
}
function auditPill(text, row) {
  if (!text) return '';
  if (row && tenantState(row) === 'missing') return el('span', { class: 'pill muted', text: 'Other tenant', title: `${text} - from the tenant this App ID belongs to, not the one connected now.` });
  if (/issue|Check failed/.test(text)) return el('span', { class: 'pill warn', text, title: 'The last time Checks read this app in detail, the catalog and Intune differed - Checks shows what and offers the fix.' });
  if (/^OK/.test(text)) return el('span', { class: 'pill ok', text, title: 'The last detailed check found the catalog and Intune the same.' });
  return el('span', { class: 'pill muted', text, title: 'Checks with "read every deployed app in detail" compares this app field by field.' });
}
function needsAttention(a) {
  // Not being deployed yet isn't a problem in itself ("No App ID"); a stale App ID, a missing package or an audit finding is.
  return tenantState(a) === 'missing' || (a.status && !a.status.split('; ').every(p => ['No App ID', 'Metadata saved - ready to deploy', 'Custom package'].includes(p))) || (tenantState(a) !== 'missing' && /issue|Check failed/.test(a.audit || ''));
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
  newer: a => !!a.newerOnWinget,
  managed: a => !!a.managed,
  pilot: a => !!a.pilotVersion,
};
function sortValue(a, k) {
  if (k === 'groups') return a.required * 10000 + a.available * 100 + a.uninstall;
  // The stage column sorts by stage (the order an app goes through), not by its status text.
  if (k === 'status') { const order = ['busy', 'tenant', 'look', 'unsent', 'draft', 'msapp', 'retire', 'ready', 'pilot', 'everyone']; const i = order.indexOf(stageOf(a).key); return String(i < 0 ? 9 : i) + (a.name || '').toLowerCase(); }
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
  // "only in Intune": just those apps - not the catalog's with them added below.
  const list = (typeof showIntuneOnly !== 'undefined' && showIntuneOnly) ? [] : apps.filter(a => f(a) && (!q || (a.name + ' ' + a.wingetId).toLowerCase().includes(q))
    && gq.every(g => (a.groups || []).some(x => x.toLowerCase().includes(g))));
  list.sort((x, y) => {
    const a = sortValue(x, sortKey), b = sortValue(y, sortKey);
    const c = typeof a === 'number' ? a - b : a.localeCompare(b, undefined, { numeric: true });
    return sortDesc ? -c : c;
  });
  visible = list.map(a => a.name);
  for (const n of [...selected]) if (!apps.some(a => a.name === n)) selected.delete(n);
  const body = $('gridBody');
  body.replaceChildren(...[...list.map(a => {
    const tr = el('tr', { 'data-name': a.name, class: selected.has(a.name) ? 'sel' : '', title: a.appId ? 'App ID ' + a.appId : 'Not in Intune yet' },
      el('td', { class: 'name' }, el('input', { type: 'checkbox', class: 'rowpick', 'aria-label': `Select ${a.name}`, title: 'Select - several at once (Shift: a range)', checked: selected.has(a.name),
        onclick: e => { e.stopPropagation(); pickRow(a.name, e.target.checked, e.shiftKey); }, ondblclick: e => e.stopPropagation() }), iconFor(a), el('span', { class: 'nm', text: a.name, title: a.name.length > 40 ? a.name : null })),
      el('td', { class: 'mono src', text: a.office && !a.wingetId ? 'Microsoft 365 Apps' : a.msHint && !a.wingetId ? 'Microsoft (Intune)' : !a.wingetId ? 'own installer' : isStoreId(a.wingetId) ? `${a.wingetId} (Store)` : a.wingetId,
        title: a.office && !a.wingetId ? `Intune's own Microsoft 365 Apps - ${a.officeText}` : !a.wingetId ? 'Its own installer (Packages folder)' + (a.type ? ` - ${a.type} in Intune` : '') : isStoreId(a.wingetId) ? 'A Microsoft Store app - Intune\'s own Store type: no package, the Store installs and updates it' : `winget package ${a.wingetId}` }),
      el('td', { class: 'num' }, el('span', { class: 'vcell' }, ...versionCell(a))),
      el('td', { title: `Required: ${a.required}, Available: ${a.available}, Uninstall: ${a.uninstall}`, class: a.required + a.available ? '' : 'muted', text: a.required + a.available + a.uninstall ? `${(a.groups || []).length} group${(a.groups || []).length === 1 ? '' : 's'}` : 'nobody yet' }),
      el('td', {}, stageCell(a)),
      el('td', { class: 'mono appidcol', text: a.appId ? a.appId.slice(0, 8) + '…' : '', title: a.appId || 'Not in Intune yet' }));
    tr.addEventListener('click', e => selectRow(a.name, e));
    tr.addEventListener('dblclick', () => openEditor(a.name));
    return tr;
  }), ...(typeof intuneOnlyRows === 'function' ? intuneOnlyRows(q) : [])]);
  if (typeof renderWhere === 'function') renderWhere();
  $('count').textContent = showIntuneOnly ? `${intuneOnly().win.length} only in Intune` : list.length === apps.length ? `${apps.length} app${apps.length === 1 ? '' : 's'}` : `${list.length} of ${apps.length} app${apps.length === 1 ? '' : 's'}`;
  for (const th of document.querySelectorAll('#grid th[data-sort]')) {
    th.classList.toggle('sorted', th.dataset.sort === sortKey);
    th.classList.toggle('desc', th.dataset.sort === sortKey && sortDesc);
  }
  syncSel(); updateActions();
  // "only in Intune" shows its rows also with an empty catalog (adding them is how a new catalog starts).
  $('emptyState').hidden = apps.length > 0 || showIntuneOnly;
  $('grid').hidden = apps.length === 0 && !showIntuneOnly;  updateTenantBanner();
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
  syncSel();
  updateActions();
}
// The selection drawn: the rows, their checkboxes, and the header's (all, none, or some: a dash).
function syncSel() {
  for (const r of $('gridBody').children) { const on = selected.has(r.dataset.name); r.classList.toggle('sel', on); const cb = r.querySelector('input.rowpick'); if (cb) cb.checked = on; }
  const all = $('pickAll'); if (!all) return;
  const n = visible.filter(x => selected.has(x)).length;
  all.checked = n > 0 && n === visible.length; all.indeterminate = n > 0 && n < visible.length;
}
// A row's checkbox: that app in or out, the others stay (Shift: the range from the last one picked).
function pickRow(name, on, range) {
  if (range && lastClicked && visible.includes(lastClicked)) {
    const [i, j] = [visible.indexOf(lastClicked), visible.indexOf(name)].sort((x, y) => x - y);
    for (const n of visible.slice(i, j + 1)) { if (on) selected.add(n); else selected.delete(n); }
  } else { if (on) selected.add(name); else selected.delete(name); }
  lastClicked = name;
  syncSel(); updateActions();
}
function updateActions() {
  if (typeof updatePanel === 'function') updatePanel();
  const n = selected.size;
  const notInIntune = [...selected].filter(s => !(apps.find(a => a.name === s) || {}).hasAppId);
  setEnabled($('btnEditApp'), n === 1, n === 0 ? 'Select an app first.' : 'Select exactly one app to edit.');
  setEnabled($('btnDeploy'), n > 0, 'Select one or more apps first.');
  setEnabled($('btnPush'), n > 0 && notInIntune.length === 0, n === 0 ? 'Select one or more apps first.' : `Only apps already in Intune - deploy ${notInIntune.length === 1 ? notInIntune[0] : notInIntune.length + ' of the selected apps'} first.`);
  $('btnDeploy').textContent = n > 1 ? `Send ${n} to Intune` : 'Send to Intune';
  $('btnPush').textContent = n > 1 ? `Send groups (${n})` : 'Send groups';
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
  $('aFilter').value = a.assignmentFilter || ''; $('aFilterMode').value = a.assignmentFilterMode === 'exclude' ? 'exclude' : 'include'; $('filterNote').textContent = '';
  for (const [k, id] of Object.entries(metaIds)) $(id).value = (a.metadata && a.metadata[k]) || '';
  $('metaNote').textContent = a.hasMetadata ? '' : '(not set yet - the defaults are used when it is deployed)';
  fillDeploy(a.deploy);
  setEditorIcon(a.icon || null, 'keep');
  $('aManaged').checked = !!a.managedUpdates;
  const own = a.releaseRule || {};
  $('arDays').value = own.days ?? ''; $('arFailed').value = own.maxFailedPercent ?? ''; $('arMin').value = own.minInstalled ?? ''; $('arDetected').value = a.detectedName || ''; $('arAuto').checked = !!a.autoRelease; $('arUrl').value = a.downloadUrl || ''; $('aWatch').value = a.watchWinget || '';
  const pol = (prefs && prefs.releasePolicy) || {};
  $('arDays').placeholder = pol.Days ?? 3; $('arFailed').placeholder = pol.MaxFailedPercent ?? 5; $('arMin').placeholder = pol.MinInstalled ?? 1;
  ruleFoldReset();
  const rel = a.releases || [], pilot = rel.find(r => r.state === 'pilot'), prev = rel.filter(r => r.state === 'previous');
  $('aManagedNote').textContent = [pilot ? `- ${pilot.version} in pilot` : '', prev.length ? `- superseded: ${prev.map(r => r.version).join(', ')}` : ''].filter(Boolean).join(' ');
  showManagedState(); refreshMethod();
  // The commands as blocks (blocks.js) - for every kind of app.
  if (window.refreshBlocks) refreshBlocks(true);
  $('appError').hidden = true;
  if (typeof updateReady === 'function') setTimeout(updateReady, 0);
}

// Managed updates need a Winget ID; while one is ticked, the install commands and detection follow the App version.
// Installs from (2.38.20): Winget, its own installer or the Microsoft Store - the Winget ID field only where it means
// something (an own installer has none), named for what goes in it.
let editorSrc = 'own';
function srcFromField() { const v = $('aWinget').value.trim(); return !v ? null : isStoreId(v) ? 'store' : 'winget'; }
// Microsoft 365 Apps (2.38.21): Intune's own Office app - its settings as the server keeps them (Get-OfficeDefaultSettings, -AppKeys, -Channels).
const officeChannels = [['monthlyEnterprise', 'Monthly Enterprise Channel - once a month (recommended)'], ['current', 'Current Channel - new features as they come'],
  ['deferred', 'Semi-Annual Enterprise Channel - twice a year'], ['firstReleaseCurrent', 'Current Channel (Preview)'], ['firstReleaseDeferred', 'Semi-Annual Enterprise Channel (Preview)']];
const officeApps = [['word', 'Word'], ['excel', 'Excel'], ['powerPoint', 'PowerPoint'], ['outlook', 'Outlook'], ['oneNote', 'OneNote'], ['teams', 'Teams'], ['oneDrive', 'OneDrive'],
  ['access', 'Access'], ['publisher', 'Publisher (retired)'], ['visio', 'Visio (needs its own licence)'], ['groove', 'OneDrive for Business (Groove, old)'], ['lync', 'Skype for Business (retired)'],
  ['infoPath', 'InfoPath (retired)'], ['sharePointDesigner', 'SharePoint Designer (retired)'], ['bing', 'Bing search in the browser']];
const officeDefaults = () => ({ channel: 'monthlyEnterprise', architecture: 'x64', locales: [], excluded: ['bing', 'groove', 'infoPath', 'lync', 'publisher', 'sharePointDesigner', 'visio'], sharedActivation: false, removeOlder: true });
$('oChannel').replaceChildren(...officeChannels.map(([v, t]) => el('option', { value: v, text: t })));
$('oApps').replaceChildren(...officeApps.map(([k, t]) => el('label', { class: 'chk' }, el('input', { type: 'checkbox', 'data-oapp': k }), t)));
function fillOffice(o) {
  const s = { ...officeDefaults(), ...(o || {}) };
  $('oChannel').value = s.channel; $('oArch').value = s.architecture === 'x86' ? 'x86' : 'x64';
  $('oLocales').value = (s.locales || []).join(', ');
  for (const c of document.querySelectorAll('[data-oapp]')) c.checked = !(s.excluded || []).includes(c.dataset.oapp);
  $('oShared').checked = !!s.sharedActivation; $('oRemoveOlder').checked = s.removeOlder !== false;
}
// Linked to Intune's own Microsoft 365 Apps but without its settings here (2.38.23): they are read from Intune, so the
// next send keeps the tenant's channel, languages and apps instead of overwriting them with the defaults.
async function officeFromIntune() {
  const row = apps.find(a => a.name === editingName);
  if (!row || !row.hasAppId || row.office) return;
  const r = await api('/api/office-from-intune', { name: editingName });
  if (editorSrc !== 'office') return;
  if (r.ok && r.found) { fillOffice(r.office); toast(`${editingName}'s Microsoft 365 settings were read from Intune - change what you need, then Save.`); }
  else if (r.ok && r.type) toast(`${editingName} is a ${r.type} in Intune - it can't become Microsoft 365 Apps in place. Clear its App ID to create Microsoft 365 Apps as a new app.`, true);
  else if (!r.ok) toast(`Its settings couldn't be read from Intune (${r.error}) - the usual ones are shown; check them before you send.`, true);
}
function readOffice() {
  return { channel: $('oChannel').value, architecture: $('oArch').value, locales: $('oLocales').value.split(/[\s,;]+/).map(x => x.trim().toLowerCase()).filter(Boolean),
    excluded: [...document.querySelectorAll('[data-oapp]')].filter(c => !c.checked).map(c => c.dataset.oapp), sharedActivation: $('oShared').checked, removeOlder: $('oRemoveOlder').checked };
}
function showSrc() {
  for (const b of document.querySelectorAll('.srcpick [data-src]')) b.setAttribute('aria-checked', String(b.dataset.src === editorSrc));
  const office = editorSrc === 'office';
  $('aWingetRow').hidden = editorSrc === 'own' || office;
  // Microsoft 365: its settings instead of managed updates, a release rule and a package - Microsoft updates it on its channel.
  $('aOfficeBox').hidden = !office;
  // A Store app neither (2.38.23) - the Store updates it.
  $('aManaged').parentElement.hidden = office || editorSrc === 'store';
  if (office || editorSrc === 'store') $('aManaged').checked = false;
  // Microsoft's app: its publisher, when nothing is set yet.
  if (office && !$('mPublisher').value.trim()) { $('mPublisher').value = 'Microsoft'; if (!$('mDeveloper').value.trim()) $('mDeveloper').value = 'Microsoft'; }
  if (office) { $('aManaged').checked = false; $('aRuleBox').hidden = true; $('aPkgInfo').hidden = true; $('aWatchRow').hidden = true; if ($('aMethodRow')) $('aMethodRow').hidden = true; }
  if (window.edSrcChanged) edSrcChanged();
  $('aWingetLbl').textContent = editorSrc === 'store' ? 'Store product ID' : 'Winget ID';
  $('aWinget').placeholder = editorSrc === 'store' ? 'e.g. 9WZDNCRFJ3PZ' : 'e.g. 7zip.7zip';
}
for (const b of document.querySelectorAll('.srcpick [data-src]')) b.addEventListener('click', () => {
  const was = editorSrc, now = b.dataset.src, f = srcFromField();
  editorSrc = now;
  // What doesn't fit the new choice goes (an own installer has no ID; a Winget ID isn't a Store ID).
  if (f && f !== now) { $('aWinget').value = ''; $('aWinget').dispatchEvent(new Event('input', { bubbles: true })); }
  showManagedState(); if (now === 'office') { if (was !== now) { $('oChannel').focus(); officeFromIntune(); } } else if (now !== 'own' && was !== now) $('aWinget').focus();
  if (typeof updateReady === 'function') updateReady();
});
function showManagedState() {
  const f = srcFromField(); if (f) editorSrc = f; else if (!['winget', 'store', 'office'].includes(editorSrc)) editorSrc = 'own';
  showSrc();
  if (editorSrc === 'office') return;
  const has = !!$('aWinget').value.trim();
  appVerPick.hide(!has || isStoreId($('aWinget').value.trim()));
  $('aRuleBox').hidden = !$('aManaged').checked;
  $('arAutoRow').hidden = has; $('arUrlRow').hidden = has; $('aWatchRow').hidden = has;
  $('aManaged').parentElement.title = has ? 'Install a fixed version (the App version) and release new versions to the pilot groups first - Settings > Updates'
    : 'Release new versions of this package to the pilot groups first. Needs a detection rule that compares a version (MSI, or file/registry by version) - a release updates it to the new version.';
}
$('aWinget').addEventListener('input', showManagedState);
// The release rule as one line (2.31.0) - most apps follow Settings' rule; Change brings the fields out.
$('aRuleBox').querySelector('legend').after(el('div', { class: 'foldsum', id: 'arSum' }, el('span', { class: 'fstext' }),
  el('button', { type: 'button', class: 'btn small', text: 'Change', 'aria-label': 'Change the release rule', onclick: () => { $('aRuleBox').classList.remove('folded'); $('arDays').focus(); } })));
function ruleSummary() {
  const v = id => $(id).value.trim() || $(id).placeholder, own = ['arDays', 'arFailed', 'arMin'].some(id => $(id).value.trim()), min = +v('arMin');
  const parts = [`${own ? "This app's own rule" : 'The rule from Settings'}: ${v('arDays')} days per ring, at most ${v('arFailed')} % failed, at least ${min} device${min === 1 ? '' : 's'}`];
  if (!$('aWinget').value.trim() && $('arAuto').checked) parts.push('releases a newer installer by itself');
  if ($('arDetected').value.trim()) parts.push(`on devices as "${$('arDetected').value.trim()}"`);
  $('arSum').querySelector('.fstext').textContent = parts.join(' · ');
}
function ruleFoldReset() { $('aRuleBox').classList.add('folded'); ruleSummary(); }
for (const id of ['arDays', 'arFailed', 'arMin', 'arUrl', 'arDetected', 'aWinget']) $(id).addEventListener('input', ruleSummary);
$('arAuto').addEventListener('change', ruleSummary);
// A field of the rule asked for (a required one left empty, a "go to the field" link): the rule comes out.
$('aRuleBox').addEventListener('invalid', () => $('aRuleBox').classList.remove('folded'), true);
$('aManaged').addEventListener('change', showManagedState);

// ---------------------------------------------------------------- Install with (Winget apps)
// Which form the commands are, and in plain words which version devices get.
let methodSeq = 0, methodTimer = null, editorInstaller = null, editorWingetOffers = '';
// An own-package app: which installer (and version) Package builds and Deploy uploads, next to the App version.
function showPkgInfo() {
  const box = $('aPkgInfo'), v = $('mAppVersion').value.trim(), i = editorInstaller, row = apps.find(a => a.name === editingName);
  // Not for Microsoft's own apps (nothing to package) - and only for an app with a name already saved.
  box.hidden = !!$('aWinget').value.trim() || !editingName || !!(row && row.msHint) || editorSrc === 'office';
  if (box.hidden) return;
  const script = /\.ps1\b/i.test($('mInstallCommand').value) && !/\.(msi|exe)\b/i.test($('mInstallCommand').value);
  const managedLocked = !!(row && row.managed && row.appId && i && i.found);
  // Upload: an installer or a .zip of its folder, or the folder itself (2.34.0) - works on the server too; drop it here as well.
  const acts = managedLocked ? el('span', { class: 'pkgacts muted', text: 'A new installer of an app with managed updates goes through Release new version (Updates), pilot first.' })
    : el('span', { class: 'pkgacts' },
      el('button', { type: 'button', class: 'btn small' + (i && i.found ? '' : ' primary'), id: 'btnAppInstaller', text: i && i.found ? 'Upload another...' : 'Upload an installer or .zip...', title: 'An .msi or .exe, or a .zip of its folder - it goes into the app\'s packages folder', onclick: () => $('aInstallerFile').click() }),
      el('button', { type: 'button', class: 'btn small', id: 'btnAppFolder', text: 'Upload a folder...', title: 'A whole folder - the installer with its other files (transforms, config files); all of it goes into the package', onclick: () => $('aInstallerFolder').click() }),
      SERVER || !(i && i.folder) ? '' : el('span', { class: 'muted', text: `or put the files in ${i.folder}` }));
  let text;
  if (!i || !i.found) {
    const lob = row && isLobMsi(row) ? "In Intune this is an MSI line-of-business app: Intune can't turn it into Win32 and never gives the .msi back - Send to Intune creates it as a Win32 app with its groups, then you retire the MSI app. " : '';
    text = script ? 'A script app - Package builds the files in its packages folder into the .intunewin that Send to Intune uploads.'
      : lob + 'No installer yet - upload the .msi or .exe (or its whole folder, or a .zip of it): what is still empty (the commands, the detection rule, the version) is filled in from it; Package then builds the .intunewin that Send to Intune uploads.';
  } else {
    const iv = i.version || '(no version in the file)';
    text = `Installer: ${i.file}, version ${iv} - Package builds its folder into the .intunewin that Send to Intune uploads. App version: ${v || '(none)'}.` +
      (i.version && v && i.version !== v ? ` They differ - a release of the new installer sets the App version (More > Release new version), or correct it on Details.` : '');
  }
  box.replaceChildren(el('span', { text }), acts, pkgFilesView());
}
// The files in its packages folder (what goes into the package): each one's size, which is the setup file, delete one.
let pkgFiles = null;
async function loadPkgFiles() {
  const name = editingName; pkgFiles = null;
  if (!name || $('aWinget').value.trim()) { showPkgInfo(); return; }
  const r = await api('/api/package-files', { name });
  if (editingName !== name) return;
  pkgFiles = r.ok ? r : null; showPkgInfo();
}
function pkgFilesView() {
  const r = pkgFiles; if (!r || !r.files.length) return '';
  const setup = (editorInstaller && editorInstaller.found ? editorInstaller.file : '') || r.setupFile || '';
  const row = f => el('li', {}, el('span', { class: 'pfpath mono', text: f.path, title: f.path }), el('span', { class: 'muted', text: fmtMB(f.size) }),
    f.path.toLowerCase() === setup.toLowerCase() ? el('span', { class: 'pill ok', text: 'setup', title: 'The setup file Package uses' })
      // Not the uninstall script (2.38.0): it was offered as a setup file too.
      : /\.(msi|exe|ps1)$/i.test(f.path) && !/(^|[\\/])uninstall\.ps1$/i.test(f.path) ? el('button', { type: 'button', class: 'linkish', text: 'Use as setup', title: 'Package uses this file as the setup file', onclick: () => setPkgSetup(f.path) }) : el('span'),
    // 2.38.17: scripts and the text files a setup reads (directly in the folder) open in the code editor.
    !/[\\/]/.test(f.path) && /\.(ps1|cfg|ini|xml|txt|cmd|bat|inf|iss|json|reg|config)$/i.test(f.path) && f.size <= 262144
      ? el('button', { type: 'button', class: 'linkish', text: 'Open', title: `Show and edit ${f.path} in the code editor`, onclick: () => openScriptEditor({ name: editingName, file: f.path }) }) : '',
    el('button', { type: 'button', class: 'bx', text: '×', title: `Delete ${f.path} from the packages folder`, 'aria-label': `Delete ${f.path}`, onclick: () => deletePkgFile(f.path) }));
  const d = el('details', { class: 'pkgfiles' }, el('summary', { text: `Files in its packages folder - ${r.files.length}, ${fmtMB(r.total)}${r.package ? ` · package built ${fmtWhen(r.package.modified)}` : ''}` }),
    el('ul', {}, ...r.files.slice(0, 300).map(row)), r.files.length > 300 ? el('p', { class: 'muted', text: `... and ${r.files.length - 300} more.` }) : '');
  d.open = !!pkgFilesOpen; d.addEventListener('toggle', () => { pkgFilesOpen = d.open; });
  return d;
}
let pkgFilesOpen = false;
async function refreshPkg(name) {
  const g = await api('/api/app-get', { name });
  if (g.ok && editingName === name) editorInstaller = g.installer || null;
  await loadPkgFiles();
}
async function deletePkgFile(path) {
  const name = editingName;
  if (!(await ask(`Delete ${path} from the packages folder?\n\nIt is left out of the next package. Backups don't keep package files - this can't be undone.`, { ok: 'Delete', danger: true }))) return;
  const r = await api('/api/package-file-delete', { name, path });
  if (!r.ok) { toast(r.error, true); return; }
  toast(`${path} deleted.`); refreshPkg(name);
}
async function setPkgSetup(path) {
  const name = editingName, r = await api('/api/package-setup', { name, path });
  if (!r.ok) { toast(r.error, true); return; }
  toast(`${path} is the setup file now - Package builds with it; check the install command on Install & detection.`); refreshPkg(name);
}
// An installer, a .zip or a folder for the app open in the editor (2.33.0, folders 2.34.0): uploaded, then the
// review - its files, the setup file, replace or add to what is there - then into its packages folder.
const installerFile = el('input', { type: 'file', id: 'aInstallerFile', multiple: true, hidden: true, 'aria-label': 'Installer, .zip or files to upload' });
const installerFolder = el('input', { type: 'file', id: 'aInstallerFolder', webkitdirectory: true, multiple: true, hidden: true, 'aria-label': 'Folder to upload' });
document.body.append(installerFile, installerFolder);
installerFile.addEventListener('change', () => { const p = pickFromFiles([...installerFile.files]); installerFile.value = ''; if (p) editorUpload(p); });
installerFolder.addEventListener('change', () => { const p = pickFromFolderInput(installerFolder); installerFolder.value = ''; if (p) editorUpload(p); });
for (const ev of ['dragenter', 'dragover']) $('aPkgInfo').addEventListener(ev, e => { if ([...(e.dataTransfer.items || [])].some(i => i.kind === 'file')) { e.preventDefault(); e.stopPropagation(); $('aPkgInfo').classList.add('over'); } });
for (const ev of ['dragleave', 'drop']) $('aPkgInfo').addEventListener(ev, () => $('aPkgInfo').classList.remove('over'));
$('aPkgInfo').addEventListener('drop', async e => { e.preventDefault(); e.stopPropagation(); const p = await pickFromDrop(e.dataTransfer); if (p) editorUpload(p); });
async function editorUpload(pick) {
  const name = editingName, box = $('aPkgInfo');
  if (!name) return;
  // 2.38.19: an app that has its package already takes any file (login.xml, a .cfg next to the setup) - it goes in as a
  // file of the folder, never as a new installer; the setup file stays as it is.
  if (pick && pick.file && !/\.(msi|exe|zip)$/i.test(pick.file.name)) pick = { folderName: pick.file.name.replace(/\.[^.]+$/, ''), files: [{ file: pick.file, path: pick.file.name }], extraOnly: true };
  if (!isPickable(pick)) { toast('Choose an .msi or .exe installer, a .zip of its folder, the folder itself - or several files at once.', true); return; }
  if (editorState() !== editorSnapshot) { toast('Save your changes first - the upload fills in what the saved app still lacks.', true); return; }
  const say = t => { for (const b of box.querySelectorAll('button')) b.disabled = true; box.firstChild.textContent = t; };
  const f = await uploadPick(pick, say);
  if (!$('dlgApp').open || editingName !== name) { if (f.uploadId) api('/api/upload-cancel', { uploadId: f.uploadId }); return; }
  if (!f.ok) { toast(f.error, true); showPkgInfo(); return; }
  const have = (pkgFiles && pkgFiles.files.length) || 0;
  const choice = await pkgUploadReview(f, have);
  if (!choice) { api('/api/upload-cancel', { uploadId: f.uploadId }); showPkgInfo(); return; }
  const r = await api('/api/app-installer', { name, uploadId: f.uploadId, mode: choice.mode });
  if (!r.ok) { toast(r.error, true); api('/api/upload-cancel', { uploadId: f.uploadId }); showPkgInfo(); return; }
  if (!$('dlgApp').open || editingName !== name) return;
  toast(`${f.folder ? `${r.files} file(s) from ${r.fileName}` : r.fileName} in its packages folder${r.filled.length ? ' - filled in ' + r.filled.join(', ') : ''}. Package builds it next.`, false, [{ label: 'Package now', run: () => { $('dlgApp').close(); buildAdded(name); } }]);
  await loadApps(); $('dlgApp').close(); openEditor(name);
}
// The review of an upload for an app: what came, which file is the setup file (a folder), replace or add (files there already).
function pkgUploadReview(f, have) {
  return new Promise(resolve => {
    const dlg = $('dlgPkgUp');
    $('puFacts').textContent = f.folder ? `${f.fileName}: ${f.fileCount} file${f.fileCount === 1 ? '' : 's'}, ${fmtMB(f.size)} - all of them go into its packages folder and into its package.` : `${f.fileName}, ${fmtMB(f.size)}.`;
    // Files added next to the setup (no installer among them): no setup file to choose - the one there stays.
    $('puSetupRow').hidden = !f.folder || !(f.candidates || []).length;
    const fill = x => {
      if (f.folder) { $('puSetup').replaceChildren(el('option', { value: '', text: '(none - I write the commands)' }), ...(x.candidates || []).map(c => el('option', { value: c, text: c }))); $('puSetup').value = x.setup || ''; }
      const extra = f.folder && !(x.candidates || []).length && have > 0;
      $('puWill').textContent = extra ? 'They go next to what is there - the setup file, the commands and the detection rule stay as they are.'
        : x.installCommand ? `Install command (when it has none yet): ${x.installCommand}` : 'No install command is proposed - write it in the editor (Install & detection).';
      $('puNotes').replaceChildren(...(extra ? [] : (x.notes || [])).map(n => el('li', { text: n })));
    };
    fill(f);
    $('puSetup').onchange = async () => { const r = await api('/api/upload-setup', { uploadId: f.uploadId, setup: $('puSetup').value }); if (r.ok) fill(r); else toast(r.error, true); };
    $('puModeRow').hidden = !have;
    $('puReplaceText').textContent = `Replace the ${have} file${have === 1 ? '' : 's'} there`;
    $('puAdd').checked = true;
    const done = v => { dlg.onclose = null; if (dlg.open) dlg.close(); resolve(v); };
    $('puGo').onclick = () => done({ mode: have ? ($('puReplace').checked ? 'replace' : 'add') : '' });
    $('puCancel').onclick = () => done(null);
    dlg.onclose = () => done(null);
    dlg.showModal(); $('puGo').focus();
  });
}
const methodBody = extra => ({ wingetId: $('aWinget').value.trim(), context: $('xContext').value, version: $('mAppVersion').value.trim(), install: $('mInstallCommand').value, uninstall: $('mUninstallCommand').value, ...extra });
function methodText(m, pinned) {
  const v = $('mAppVersion').value.trim(), w = editorWingetOffers, now = w ? ` Winget has ${w} now (last check).` : '';
  if (m === 'Managed') return !v ? "Installs the App version with winget - but there's no App version yet: set one (Pin newest in the side panel) before deploying."
    : `Installs exactly ${pinned || v} (the App version), with winget. Newer versions reach devices only when you release them: pilot groups first, then everyone.` + (w && w !== v ? ` Winget has ${w} now - release it on Updates.` : '');
  if (m === 'WAU') return "Still installs through Winget-AutoUpdate, which this catalog no longer uses. Choose Managed updates (or the winget command) - Home switches all such apps at once.";
  if (m === 'Winget') return 'Installs whatever version winget has at that moment - nothing is pinned. Nothing updates it afterwards.' + now;
  return 'The install command was edited by hand, so it is left as it is - check it for which version it installs. Choosing a method here replaces it.';
}
async function refreshMethod() {
  showPkgInfo();
  const id = $('aWinget').value.trim(), row = $('aMethodRow');
  // Store apps (12-character IDs) are Intune's own Store type - no commands.
  row.hidden = !id || /^[0-9A-Z]{12}$/.test(id);
  if (row.hidden) return;
  const seq = ++methodSeq, r = await api('/api/winget-commands', methodBody());
  if (seq !== methodSeq || !r.ok) return;
  let m = r.current || 'Custom';
  // Managed ticked: Save pins the commands to the App version, whatever they are now.
  if ($('aManaged').checked) m = 'Managed'; else if (m === 'Managed') m = 'Custom';
  $('aMethod').value = m; $('aMethodInfo').textContent = methodText(m, r.pinned);
  if (r.current === 'Managed' || r.current === 'Winget') genFor = { id, method: r.current };
}
// The Winget ID the commands were generated for (and how): a new ID writes them again for it - unless they were
// edited by hand since, then they stay as typed (and the blocks show them as the app's own).
let genFor = null;
$('dlgApp').addEventListener('close', () => { genFor = null; });
$('aWinget').addEventListener('change', async () => {
  const id = $('aWinget').value.trim(), g = genFor;
  if (!g || !id || id === g.id || isStoreId(id)) return;
  const was = await api('/api/winget-commands', methodBody({ wingetId: g.id }));
  if (!was.ok || was.current !== g.method || $('aWinget').value.trim() !== id) return;
  const r = await api('/api/winget-commands', methodBody({ method: g.method }));
  if (!r.ok || $('aWinget').value.trim() !== id) return;
  for (const [f, v] of [['mInstallCommand', r.install], ['mUninstallCommand', r.uninstall]]) { $(f).value = v; $(f).dispatchEvent(new Event('input', { bubbles: true })); }
  // Generated for this ID now (2.38.3) - at once, not only when the refresh 300 ms later says so: a second change in
  // between (back to the first ID) found "the same ID" and left the commands on the one in between.
  genFor = { ...g, id };
  refreshMethod();
});
const methodSoon = () => { clearTimeout(methodTimer); methodTimer = setTimeout(refreshMethod, 300); };
for (const id of ['aWinget', 'mAppVersion', 'mInstallCommand', 'mUninstallCommand']) $(id).addEventListener('input', methodSoon);
$('xContext').addEventListener('change', methodSoon);
$('aManaged').addEventListener('change', methodSoon);
$('aMethod').addEventListener('change', () => applyMethod());
// Install for decides --scope machine: generated commands are written again for it (own ones are left as typed).
$('xContext').addEventListener('change', () => { if (!$('aMethodRow').hidden && ['Managed', 'Winget'].includes($('aMethod').value)) applyMethod(); });
async function applyMethod() {
  const m = $('aMethod').value, before = await api('/api/winget-commands', methodBody());
  if (before.ok && !before.current && $('mInstallCommand').value.trim() && !(await ask('Replace the install and uninstall commands?\n\nThey were edited by hand - choosing a method writes the generated ones instead.', { ok: 'Replace' }))) { refreshMethod(); return; }
  // The extra winget options in the commands stay (the server reads them back from the install command).
  const r = await api('/api/winget-commands', methodBody({ method: m }));
  if (!r.ok) { toast(r.error, true); refreshMethod(); return; }
  $('aManaged').checked = m === 'Managed'; showManagedState();
  for (const [id, v] of [['mInstallCommand', r.install], ['mUninstallCommand', r.uninstall]]) { $(id).value = v; $(id).dispatchEvent(new Event('input', { bubbles: true })); }
  refreshMethod();
}

// ---------------------------------------------------------------- unsaved changes (editor)
// Escape or Cancel with changes asks first; saving or removing closes it without asking.
let editorSnapshot = '';
const editorState = () => [...$('appForm').querySelectorAll('input, textarea, select')].filter(e => e.id !== 'aMethod' && !e.closest('.blockbar')).map(e => e.type === 'checkbox' ? e.checked : e.value).join('\u0001') + '\u0001' + iconChange +
  // A block typed in but not written into the commands yet counts as a change too.
  '\u0001' + [...document.querySelectorAll('#dlgApp .blockbar input')].filter(i => i.value !== i.defaultValue).length + '\u0001' + editorSrc;
async function closeEditorAsking() {
  if (editorState() !== editorSnapshot && !(await ask(`Discard your changes to ${editingName || 'the new app'}?\n\nNothing you changed in this dialog is saved.`, { ok: 'Discard', danger: true }))) return;
  $('dlgApp').close();
}
$('dlgApp').addEventListener('cancel', e => { e.preventDefault(); if (!$('dlgAsk').open) closeEditorAsking(); });
$('btnAppCancel').addEventListener('click', closeEditorAsking);

// ---------------------------------------------------------------- the app's icon (editor)
let editorIcon = null, iconChange = 'keep';
function setEditorIcon(icon, change) {
  editorIcon = icon; iconChange = change;
  $('aIcon').hidden = !icon; $('aIconNone').hidden = !!icon;
  if (icon) $('aIcon').src = `data:${icon.type};base64,${icon.value}`; else $('aIcon').removeAttribute('src');
  setEnabled($('btnIconRemove'), !!icon, 'This app has no icon in the catalog.');
  setEnabled($('btnIconIntune'), !!editingName && !!$('aAppId').value.trim() && !!(state && state.configured), !editingName ? 'Save the app first.' : 'Only for an app that is in Intune (with an App ID) and a connection.');
}
// A picked image: anything larger than 512 px is scaled down (PNG), so the file stays small; at most 750 KB.
function readIconFile(f) {
  return new Promise((resolve, reject) => {
    if (!/^image\/(png|jpeg)$/.test(f.type)) { reject(new Error('Choose a PNG or JPEG image.')); return; }
    const reader = new FileReader();
    reader.onerror = () => reject(new Error('The file could not be read.'));
    reader.onload = () => {
      const img = new Image();
      img.onerror = () => reject(new Error('That is not an image the browser can read.'));
      img.onload = () => {
        let url = reader.result, type = f.type;
        if (img.width > 512 || img.height > 512) {
          const k = 512 / Math.max(img.width, img.height), c = document.createElement('canvas');
          c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
          c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
          url = c.toDataURL('image/png'); type = 'image/png';
        }
        const value = url.slice(url.indexOf(',') + 1);
        if (value.length * 3 / 4 > 750000) { reject(new Error('The image is larger than 750 KB - use a smaller one.')); return; }
        resolve({ type, value });
      };
      img.src = reader.result;
    };
    reader.readAsDataURL(f);
  });
}
$('btnIconPick').addEventListener('click', () => $('aIconFile').click());
$('aIconFile').addEventListener('change', async () => {
  const f = $('aIconFile').files[0]; $('aIconFile').value = '';
  if (!f) return;
  try { setEditorIcon(await readIconFile(f), 'set'); } catch (e) { toast(e.message, true); }
});
$('btnIconIntune').addEventListener('click', async () => {
  const r = await api('/api/app-icon-intune', { name: editingName });
  if (!r.ok) { toast(r.error, true); return; }
  setEditorIcon(r.icon, 'set'); toast('Took the icon from Intune - Save keeps it.');
});
$('btnIconRemove').addEventListener('click', () => setEditorIcon(null, 'remove'));
// Choose image... and one menu for the rest (from Intune, find one, remove) - a real menu: what can't be done yet
// says why right in it (a drop-down hid that in a tooltip, so picking it seemed to do nothing).
foldIntoMenu(['btnIconIntune', 'btnIconFind', 'btnIconRemove'], { id: 'aIconMore', title: 'Take the icon from Intune, find one, or remove it' });

// ---------------------------------------------------------------- supersedence (editor, Deploy settings)
let editorIntuneApps = [];
function supRow(s = { appId: '', name: '', type: 'update' }) {
  const known = editorIntuneApps.some(a => a.appId.toLowerCase() === (s.appId || '').toLowerCase());
  const sel = el('select', { 'aria-label': 'The app this one supersedes', 'data-sup': '' },
    el('option', { value: '', text: 'Choose an app...' }),
    ...editorIntuneApps.map(a => el('option', { value: a.appId, text: a.name })),
    s.appId && !known ? el('option', { value: s.appId, text: `${s.name || s.appId} (${intuneIds && !intuneIds.has(s.appId.toLowerCase()) ? 'not in this tenant' : 'by App ID'})` }) : '',
    el('option', { value: '__other', text: 'Another app in Intune - type its App ID...' }));
  sel.value = s.appId ? (known ? editorIntuneApps.find(a => a.appId.toLowerCase() === s.appId.toLowerCase()).appId : s.appId) : '';
  const other = el('input', { placeholder: 'App ID (GUID) from Intune', 'aria-label': 'App ID of the superseded app', class: 'mono', hidden: true, 'data-supid': '' });
  sel.addEventListener('change', () => { other.hidden = sel.value !== '__other'; if (!other.hidden) other.focus(); });
  const type = el('select', { 'aria-label': 'What happens to the old app', 'data-suptype': '', title: 'Update: devices with the old app get this one. Replace: the old app is uninstalled first.' },
    el('option', { value: 'update', text: 'Update it' }), el('option', { value: 'replace', text: 'Replace it (uninstall the old one)' }));
  type.value = s.type === 'replace' ? 'replace' : 'update';
  const rm = el('button', { type: 'button', class: 'btn small', text: 'Remove', title: 'This app no longer supersedes it' });
  const row = el('div', { class: 'suprow' }, sel, other, type, rm);
  row.dataset.name = s.name || '';
  rm.addEventListener('click', () => { row.remove(); deployTouched = true; showSupState(); });
  return row;
}
function showSupState() {
  const on = $('xSupSet').checked;
  $('xSup').hidden = !on;
  setEnabled($('btnSupAdd'), on && $('xSup').children.length < 10, on ? 'Intune allows at most 10.' : 'Tick "Set supersedence from the catalog" first.');
  if (on && !$('xSup').children.length) $('xSup').replaceChildren(el('p', { class: 'muted', text: 'Supersedes nothing - saving clears what Intune has. Add an app, or untick to leave Intune\'s alone.' }));
}
$('xSupSet').addEventListener('change', showSupState);
$('btnSupAdd').addEventListener('click', () => {
  const p = $('xSup').querySelector('p'); if (p) p.remove();
  const r = supRow(); $('xSup').append(r); r.querySelector('select').focus(); deployTouched = true; showSupState();
});
function readSupersedence() {
  return [...$('xSup').querySelectorAll('.suprow')].map(r => {
    const sel = r.querySelector('[data-sup]'), id = sel.value === '__other' ? r.querySelector('[data-supid]').value.trim() : sel.value;
    const name = sel.value === '__other' ? '' : (editorIntuneApps.find(a => a.appId === sel.value) || {}).name || r.dataset.name;
    return { appId: id, name, type: r.querySelector('[data-suptype]').value };
  }).filter(s => s.appId);
}
let editingVersion = '';
async function openEditor(name) {
  // A minimised editor comes back as it was (2.38.23: its "Installs from" too - reset first, Microsoft 365 was lost on Save).
  if (wcResume('dlgApp')) return;
  appVerPick.reset(); editorSrc = name ? 'own' : 'winget';   // a new app starts on Winget (most are)
  editingName = name || ''; editingVersion = '';
  if (name) {
    const r = await api('/api/app-get', { name });
    if (!r.ok) { toast(r.error, true); return; }
    editorApps = r.appNames || []; editorMinOs = r.minOsChoices || []; editorIntuneApps = r.intuneApps || [];
    editingVersion = r.version || '';
    editorInstaller = r.installer || null; editorWingetOffers = r.wingetOffers || '';
    setTimeout(loadPkgFiles, 0);
    if (r.app.office && !r.app.wingetId) editorSrc = 'office';
    fillOffice(r.app.office);
    fillEditor(r.app);
    $('knownGroups').textContent = r.knownGroups.length ? 'Groups used in this catalog: ' + r.knownGroups.join(', ') : '';
    $('appTitle').textContent = 'Edit ' + name;
  } else {
    editorInstaller = null; editorWingetOffers = ''; fillOffice(null);
    editorApps = apps.map(a => a.name); editorMinOs = (prefs && prefs.minOsChoices) || [];
    editorIntuneApps = apps.filter(a => a.hasAppId).map(a => ({ name: a.name, appId: a.appId }));
    // A new app starts with the default profile's groups (Settings > Apps & defaults).
    const dp = defaultProfile();
    fillEditor({ ...(dp ? { requiredFor: dp.required, availableFor: dp.available, excludeFor: dp.exclude } : {}), hasMetadata: false, managedUpdates: !!(prefs && prefs.defaults && prefs.defaults.wingetInstallMethod === 'Managed'), deploy: prefs && prefs.defaults ? { ...prefs.defaults, detection: { type: '' }, dependencies: prefs.defaults.defaultDependencyAppNames || [] } : null });
    $('knownGroups').textContent = '';
    $('appTitle').textContent = 'Add an app';
  }
  $('btnRemoveApp').hidden = !name;
  $('btnAppHistory').hidden = !name;
  $('dlgApp').showModal();
  if (typeof fillBtnSync === 'function') fillBtnSync();
  editorSnapshot = editorState();
  $('aName').focus();
}
// Assignment filters: the tenant's, loaded once when the box is first used.
let filtersLoaded = false;
$('aFilter').addEventListener('focus', async () => {
  if (filtersLoaded) return; filtersLoaded = true;
  const r = await api('/api/filters');
  const list = (r.ok && r.filters) || [];
  $('filterList').replaceChildren(...list.map(f => el('option', { value: f.name, text: `${f.platform === 'windows10AndLater' ? 'Windows' : f.platform}${f.rule ? ' - ' + f.rule.slice(0, 80) : ''}` })));
  if (r.note) $('filterNote').textContent = r.note; else if (!list.length) $('filterNote').textContent = 'No assignment filters in Intune yet (Tenant administration > Filters).';
});
$('btnAddApp').addEventListener('click', () => openAdd());
$('btnEditApp').addEventListener('click', () => { if (selected.size === 1) openEditor([...selected][0]); });
$('appForm').addEventListener('submit', async e => {
  e.preventDefault();
  // A block still being typed in (Save clicked, Ctrl+S) is written into the commands first.
  if (window.blocksFlush) await blocksFlush();
  const app = {
    appName: $('aName').value, wingetId: $('aWinget').value, appId: $('aAppId').value,
    requiredFor: lines('gRequired'), availableFor: lines('gAvailable'), uninstallFor: lines('gUninstall'), excludeFor: lines('gExclude'),
    assignmentFilter: $('aFilter').value.trim(), assignmentFilterMode: $('aFilterMode').value,
    metadata: Object.fromEntries(Object.entries(metaIds).map(([k, id]) => [k, $(id).value])),
  };
  if (deployTouched) app.deploy = readDeploy();
  app.iconChange = iconChange; if (iconChange === 'set') app.icon = editorIcon;
  app.managedUpdates = $('aManaged').checked;
  app.releaseRule = { days: $('arDays').value.trim(), maxFailedPercent: $('arFailed').value.trim(), minInstalled: $('arMin').value.trim() };
  app.detectedName = $('arDetected').value.trim();
  app.autoRelease = $('arAuto').checked && !$('aWinget').value.trim(); app.downloadUrl = $('arUrl').value.trim();
  app.watchWinget = $('aWatch').value.trim();
  // Microsoft 365 Apps (2.38.21): its settings - false takes them away (another source was chosen).
  app.office = editorSrc === 'office' && !app.wingetId.trim() ? readOffice() : false;
  if (app.office) { app.managedUpdates = false; app.autoRelease = false; }
  const r = await api('/api/app-save', { originalName: editingName, version: editingVersion, app });
  if (!r.ok) {
    const p = $('appError'); p.textContent = r.error; p.hidden = false;
    // What it is about may be folded away: the release rule (the download address), or a part of Install & detection.
    if (/download address/i.test(r.error)) $('aRuleBox').classList.remove('folded');
    else if (window.edRevealFor) edRevealFor(r.error);
    return;
  }
  $('dlgApp').close();
  selected.clear(); selected.add(r.name); lastClicked = r.name;
  await loadApps();
  // Saved in the catalog only: when Intune now has something older, say so - with the send it takes.
  const row = apps.find(x => x.name === r.name);
  if (row && row.hasAppId && row.unsent) {
    const s = row.unsent.split(',');
    toast(`${r.name} saved in the catalog - Intune still has the old ${s.join(' and ')}.`, false,
      [s.includes('settings') ? { label: 'Send settings now', run: () => sendSettingsNow([r.name]) } : { label: 'Send groups now', run: () => sendGroupsNow([r.name]) }]);
  }
});
const fieldLabel = { appName: 'name', appId: 'App ID', wingetId: 'Winget ID', requiredFor: 'Required', availableFor: 'Available', uninstallFor: 'Uninstall', excludeFor: 'Excluded', settings: 'Intune details or deploy settings' };
$('btnAppHistory').addEventListener('click', async () => {
  const name = editingName;
  const r = await api('/api/app-backups', { name });
  if (!r.ok) { toast(r.error, true); return; }
  $('histTitle').textContent = `History of ${name}`;
  loadChanges(name);
  $('histNote').textContent = r.backups.length ? '' : 'No earlier version kept yet - one is kept the next time this app is saved.';
  $('histRows').replaceChildren(...r.backups.map(b => el('tr', {},
    el('td', {}, backupWhen(b), b.verified ? '' : el('span', { class: 'pill muted', text: 'not verified', title: "Not recorded by the catalog (from before 2.23, or put in the Backups folder by hand) - it can be compared, but isn't restored" })),
    el('td', { text: b.changed.length ? b.changed.map(c => fieldLabel[c] || c).join(', ') : 'nothing - same as now' }),
    el('td', { class: 'act' }, el('button', { class: 'btn small', text: 'Compare', title: 'What the save at that time changed, and that version next to now', onclick: () => compareVersion(name, b) }), ' ', el('button', { class: 'btn small', text: 'Restore', title: !b.verified ? "Not verified - this copy isn't one the catalog recorded, so it isn't restored" : b.changed.length ? 'Put this version back as the app\'s file' : 'Same as the app is now - nothing to restore', disabled: !b.verified || !b.changed.length || null, onclick: async () => {
      if (!(await ask(`Restore ${name} as it was on ${backupWhen(b)}?\n\nOnly the catalog changes - Send to Intune sends it there. The current version is kept as a copy, so this can be undone the same way.`, { ok: 'Restore', danger: false }))) return;
      const x = await api('/api/app-restore', { name, id: b.id });
      if (!x.ok) { toast(x.error, true); return; }
      toast(`${name} restored to ${backupWhen(b)}.`);
      $('dlgHistory').close(); $('dlgApp').close(); await loadApps(); openEditor(x.name);
    } })))));
  $('histCompare').hidden = true;
  $('dlgHistory').showModal();
});
// The change history: one line per change, newest first.
const histField = f => f.startsWith('metadata.') ? (({ description: 'Description', publisher: 'Publisher', appVersion: 'App version', owner: 'Owner', developer: 'Developer', informationUrl: 'Information URL', privacyUrl: 'Privacy URL',
  installCommand: 'Install command', uninstallCommand: 'Uninstall command', notes: 'Notes', detectionRule: 'Detection rule', returnCodes: 'Return codes', dependencies: 'Dependencies', supersedes: 'Supersedence', isFeatured: 'Featured' })[f.slice(9)] || f.slice(9))
  : (f === 'appName' ? 'Name' : fieldLabel[f] || ({ assignmentFilter: 'Assignment filter', assignmentFilterMode: 'Filter mode', managedUpdates: 'Managed updates', releases: 'Releases', releaseRule: 'Release rule', icon: 'Icon', autoRelease: 'Release by itself', downloadUrl: 'Download URL', retiringSince: 'Retiring since' })[f] || f);
// A backup's time in the viewer's time (the server sends it with its offset), and which copy of that second it is.
const backupWhen = b => (b.at ? fmtWhen(b.at) : b.when) + (b.seq > 1 ? ` (${b.seq})` : '');
async function loadChanges(name) {
  skeleton($('histChanges'), 1, 3); $('histChangesNote').textContent = '';
  const r = await api('/api/app-history', { name });
  if (!r.ok) { $('histChangesNote').textContent = r.error; $('histChanges').replaceChildren(); return; }
  $('histChangesNote').textContent = r.entries.length ? '' : 'Nothing recorded yet - changes are recorded from this version of the app on.';
  $('histChanges').replaceChildren(...r.entries.map(e => el('li', { class: e.kind === 'intune' ? 'intune' : '' },
    el('div', { class: 'thead' }, el('time', { text: fmtWhen(e.at) }), el('span', { class: 'pill ' + (e.kind === 'intune' ? 'info' : 'muted'), text: e.kind === 'intune' ? 'Intune' : 'Catalog' }),
      el('span', { class: 'muted', text: e.source }), e.app !== name ? el('span', { class: 'muted', text: `(as ${e.app})` }) : '',
      e.canUndo ? el('button', { class: 'btn small', text: 'Undo', title: 'Put the fields this change changed back - only those not changed again since', onclick: async () => {
        if (!(await ask(`Undo this change to ${name}?\n\n${e.changes.filter(c => c.revertable).map(c => `${histField(c.field)}: back to ${c.before || '(empty)'}`).join('\n')}\n\nOnly the catalog changes - Send to Intune sends it there.`, { ok: 'Undo' }))) return;
        const x = await api('/api/history-undo', { name, id: e.id });
        if (!x.ok) { toast(x.error, true); return; }
        toast(`Undone: ${x.undone.map(histField).join(', ')}${x.skipped.length ? ` - left alone: ${x.skipped.join('; ')}` : ''}`);
        $('dlgHistory').close(); $('dlgApp').close(); await loadApps(); openEditor(name);
      } }) : ''),
    e.text ? el('div', { text: e.text }) : '',
    e.changes.length ? el('ul', { class: 'changes' }, ...e.changes.map(c => el('li', {}, el('strong', { text: histField(c.field) + ': ' }),
      el('span', { class: 'old', text: c.before || '(empty)' }), ' → ', el('span', { class: 'new', text: c.after || '(empty)' })))) : '')));
}
async function compareVersion(name, b) {
  const r = await api('/api/app-compare', { name, id: b.id });
  if (!r.ok) { toast(r.error, true); return; }
  const rows = list => list.map(c => ({ app: '', field: c.field, old: c.old, new: c.new }));
  $('histCmpTitle').textContent = `What the save on ${r.at ? fmtWhen(r.at) : r.when} changed`;
  previewTable($('histSave'), rows(r.thatSave), 'Nothing - that save left the file as it was.', { ...fieldNames, appName: 'Name', appId: 'App ID', wingetId: 'Winget ID', icon: 'Icon', supersedes: 'Supersedence', detectionRule: 'Detection rule', appVersion: 'App version', isFeatured: 'Featured' });
  previewTable($('histNow'), rows(r.versusNow).map(x => ({ ...x })), 'The same as now.', { ...fieldNames, appName: 'Name', appId: 'App ID', wingetId: 'Winget ID', icon: 'Icon', supersedes: 'Supersedence', detectionRule: 'Detection rule', appVersion: 'App version', isFeatured: 'Featured' });
  for (const th of $('histNow').querySelectorAll('th')) { if (th.textContent === 'Now') th.textContent = 'That version'; else if (th.textContent === 'New') th.textContent = 'Now'; }
  for (const th of $('histSave').querySelectorAll('th')) { if (th.textContent === 'Now') th.textContent = 'Before'; else if (th.textContent === 'New') th.textContent = 'After'; }
  $('histCompare').hidden = false;
  $('histCompare').scrollIntoView({ block: 'nearest' });
}
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
  updateViewButtons();   // Save view... only when there's a search or filter to keep
  $('emptyPath').textContent = r.path || '';
  if (r.failed && r.failed.length) toast(`${r.failed.length} file(s) in the catalog could not be read: ${r.failed.join(', ')}`, true);
  renderApps();
  loadIntuneIds(false);
  loadUndo();
  // Every change re-reads the catalog: Home follows it.
  if (typeof refreshHomeSoon === 'function') refreshHomeSoon();
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
let undoInfo = null;
async function loadUndo() {
  const r = await api('/api/undo-info');
  undoInfo = r.ok ? r.undo : null;
  // No bar over the list: a dot on Recent changes says a bulk change can be undone (the panel has it).
  $('recentDot').hidden = !undoInfo;
  $('btnRecent').title = undoInfo ? `Recent changes - "${undoInfo.label}" (${undoInfo.count} app${undoInfo.count === 1 ? '' : 's'}, ${undoInfo.time}) can be undone` : 'Recent changes - every change to the catalog, with Undo';
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
  if ($('dlgRecent').open) openRecent();
}

// ---------------------------------------------------------------- Recent changes: the catalog's history, with Undo
let recentData = null;
const recentOpen = new Set();   // the entries opened - kept open when the list is read again (after an Undo)
const rFieldName = { appName: 'Name', wingetId: 'Winget ID', appId: 'App ID', requiredFor: 'Required', availableFor: 'Available', uninstallFor: 'Uninstall', excludeFor: 'Excluded', managedUpdates: 'Managed updates', releases: 'Releases',
  'metadata.appVersion': 'App version', 'metadata.installCommand': 'Install command', 'metadata.uninstallCommand': 'Uninstall command', 'metadata.detectionRule': 'Detection rule', 'metadata.dependencies': 'Dependencies', 'metadata.description': 'Description', 'metadata.owner': 'Owner', 'metadata.publisher': 'Publisher' };
const rField = f => rFieldName[f] || f.replace(/^metadata\./, '').replace(/([a-z])([A-Z])/g, '$1 $2').replace(/^./, c => c.toUpperCase());
function whenText(iso) {
  const d = new Date(iso); if (isNaN(d)) return iso;
  return fmtWhen(d);
}
async function openRecent() {
  if (!$('dlgRecent').open) { if (wcResume('dlgRecent')) return; $('recentFilter').value = ''; }
  $('recentNote').textContent = 'Reading...';
  if (!$('dlgRecent').open) $('dlgRecent').showModal();
  const r = await api('/api/catalog-history', { limit: 300 });
  if (!r.ok) { $('recentNote').textContent = r.error; return; }
  recentData = r; renderRecent();
}
function renderRecent() {
  const r = recentData; if (!r) return;
  const u = r.undo, box = $('recentUndo');
  box.hidden = !u;
  if (u) box.replaceChildren(el('div', {}, el('b', { text: `Last bulk change: ${u.label}` }), el('span', { class: 'muted', text: ` - ${u.count} app${u.count === 1 ? '' : 's'}, ${u.time}` })),
    el('button', { class: 'btn small', text: 'Undo it', title: 'Put back each app file as it was before this change - files changed since are left alone', onclick: undoLast }));
  const q = $('recentFilter').value.trim().toLowerCase();
  const groups = r.groups.filter(g => !q || [g.source, g.text, ...g.items.flatMap(i => [i.app, ...i.changes.map(c => rField(c.field))])].join(' ').toLowerCase().includes(q));
  $('recentNote').textContent = groups.length ? `${groups.length} change${groups.length === 1 ? '' : 's'}${q ? ' match' : ''}` : '';
  const undoOne = async (i) => {
    if (!(await ask(`Undo this change to ${i.app}?\n\n${i.changes.filter(c => c.revertable).map(c => `${rField(c.field)}: back to ${c.before || '(empty)'}`).join('\n')}\n\nFields changed again since are left alone. Intune isn't touched.`, { ok: 'Undo' }))) return;
    const x = await api('/api/history-undo', { name: i.app, id: i.id });
    toast(x.ok ? `${i.app}: undone (${x.undone.map(rField).join(', ')}).${x.skipped.length ? ' Left alone: ' + x.skipped.join('; ') : ''}` : x.error, !x.ok);
    if (x.ok) { await loadApps(); openRecent(); }
  };
  const change = c => el('li', {}, el('span', { class: 'f', text: rField(c.field) }), el('span', { class: 'v' }, el('span', { class: 'b', text: c.before || '(empty)' }), el('span', { class: 'arr', text: '→', 'aria-label': 'to' }), el('span', { class: 'a', text: c.after || '(empty)' })));
  // The app's name over its changes - unless the group's line already names that one app.
  const item = (i, named) => el('div', { class: 'ritem' }, el('div', { class: 'rapp' }, named ? '' : el('b', { text: i.app }), i.kind === 'intune' ? el('span', { class: 'pill info', text: 'Intune' }) : '',
      i.canUndo ? el('button', { class: 'btn small ghost', text: 'Undo', title: 'Put these fields back as they were', onclick: () => undoOne(i) }) : ''),
    i.changes.length ? el('ul', { class: 'rchanges' }, ...i.changes.slice(0, 12).map(change), i.changes.length > 12 ? el('li', { class: 'muted', text: `... ${i.changes.length - 12} more` }) : '') : '');
  $('recentList').replaceChildren(...(groups.length ? groups.map(g => {
    const apps = [...new Set(g.items.map(i => i.app))];
    const what = g.text || [...new Set(g.items.flatMap(i => i.changes.map(c => rField(c.field))))].slice(0, 4).join(', ') || 'Changed';
    const head = el('summary', {}, el('span', { class: 'rwhen', text: whenText(g.at) }), el('span', { class: 'rsrc', text: g.by ? `${g.source} · ${g.by}` : g.source, title: g.by ? `By ${g.by}, from ${g.source}` : g.source }),
      el('span', { class: 'rwhat', text: what }), el('span', { class: 'rapps muted', text: apps.length === 1 ? apps[0] : `${apps.length} apps: ${apps.slice(0, 3).join(', ')}${apps.length > 3 ? ', ...' : ''}` }));
    const key = g.items[0] && g.items[0].id;
    const d = el('details', { open: recentOpen.has(key) || (!recentOpen.size && g.count === 1 && groups.indexOf(g) < 3) }, head, el('div', { class: 'rbody' }, ...g.items.map(i => item(i, apps.length === 1))));
    d.addEventListener('toggle', () => { if (d.open) recentOpen.add(key); else recentOpen.delete(key); });
    return el('li', {}, d);
  }) : [el('li', { class: 'muted rempty', text: q ? 'No change matches.' : 'No changes yet.' })]));
}
$('recentFilter').addEventListener('input', renderRecent);
$('btnRecent').addEventListener('click', openRecent);

// ---------------------------------------------------------------- the Catalog menu (the whole catalog)
const catMenu = $('catalogMenu');
// Buttons folded into one "More" menu (2.32.0): the buttons stay (their handlers, enabled state and titles are the
// truth) - hidden; the menu's items click them. The menu button goes where the first of them was.
function foldIntoMenu(ids, opts = {}) {
  const btns = ids.map(id => $(id)).filter(Boolean); if (!btns.length) return null;
  const menu = el('div', { class: 'menu', role: 'menu' }); menu.hidden = true; document.body.append(menu);
  const more = el('button', { type: 'button', class: 'btn' + (opts.cls ? ' ' + opts.cls : ''), id: opts.id || null, 'aria-haspopup': 'menu', 'aria-expanded': 'false', text: opts.text || 'More \u25BE', title: opts.title || btns.map(b => b.textContent.trim()).join(', ') });
  const close = () => { menu.hidden = true; more.setAttribute('aria-expanded', 'false'); };
  more.addEventListener('click', e => {
    e.stopPropagation();
    if (!menu.hidden) { close(); return; }
    // An item that can't be used right now says why under its name (its button's title - setEnabled puts the reason there).
    menu.replaceChildren(...btns.filter(b => !b.classList.contains('gone')).map(b => el('button', { role: 'menuitem', title: b.title, disabled: b.disabled, onclick: () => { close(); b.click(); } },
      el('span', { text: b.textContent.trim() }), b.disabled && b.title ? el('small', { class: 'why', text: b.title }) : '')));
    const r = more.getBoundingClientRect(); placeMenu(menu, r.right - 260, r.bottom + 4); more.setAttribute('aria-expanded', 'true');
  });
  menu.addEventListener('keydown', e => {
    if (e.key === 'Escape') { close(); more.focus(); return; }
    menuStep(e, menu);
  });
  document.addEventListener('click', e => { if (!menu.hidden && !menu.contains(e.target)) close(); });
  btns[0].before(more); for (const b of btns) b.hidden = true;
  return more;
}
// A small menu under -anchor (2.37.0): [text, title, run] each; closes on a choice, Escape or a click elsewhere.
function popMenu(anchor, items) {
  // Its button again: closes it.
  const open = document.querySelector('.menu.pop');
  if (open) { open.remove(); anchor.setAttribute('aria-expanded', 'false'); if (open.__anchor === anchor) return; }
  const menu = el('div', { class: 'menu pop', role: 'menu' }); menu.__anchor = anchor;
  anchor.setAttribute('aria-haspopup', 'menu'); anchor.setAttribute('aria-expanded', 'true');
  // Focus goes back to the button only after Escape or a choice - a click elsewhere keeps it where it went (2.38.0).
  const close = back => { if (!menu.isConnected) return; menu.remove(); anchor.setAttribute('aria-expanded', 'false'); document.removeEventListener('click', away, true); if (back) anchor.focus(); };
  const away = e => { if (!menu.contains(e.target) && e.target !== anchor) close(false); };
  menu.append(...items.map(([text, title, run]) => el('button', { role: 'menuitem', type: 'button', title, text, onclick: () => { close(true); run(); } })));
  menu.addEventListener('keydown', e => {
    if (e.key === 'Escape') { e.stopPropagation(); close(true); return; }
    menuStep(e, menu);
  });
  // Tab out of it: it closes (Escape couldn't reach it any more).
  menu.addEventListener('focusout', e => { if (!menu.contains(e.relatedTarget) && e.relatedTarget) close(false); });
  document.body.append(menu);
  const r = anchor.getBoundingClientRect(); placeMenu(menu, r.left, r.bottom + 4);
  setTimeout(() => document.addEventListener('click', away, true), 0);
  menu.querySelector('button').focus();
}
// A text Reload button as the round icon the Apps page has.
function reloadIcon(id) {
  const b = $(id); if (!b) return;
  b.classList.add('iconbtn'); b.setAttribute('aria-label', 'Reload');
  b.innerHTML = '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/></svg>';
}
function placeMenu(m, x, y) {
  m.hidden = false;
  const r = m.getBoundingClientRect();
  m.style.left = Math.max(8, Math.min(x, innerWidth - r.width - 8)) + 'px';
  m.style.top = Math.max(8, Math.min(y, innerHeight - r.height - 8)) + 'px';
  const first = m.querySelector('button:not(:disabled)'); if (first) first.focus();
}
// Arrow keys move between a menu's items, Home and End to the first and last (2.38.0) - only items that are shown
// and can be used (the More menu hides what can't apply). True when it handled the key.
function menuStep(e, m) {
  if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) return false;
  const items = [...m.querySelectorAll('button:not(:disabled)')].filter(b => !b.hidden && b.offsetParent !== null), i = items.indexOf(document.activeElement);
  if (!items.length) return false;   // a menu of checkboxes and radios (Columns): the keys are theirs
  e.preventDefault();
  const to = e.key === 'Home' ? 0 : e.key === 'End' ? items.length - 1 : (i + (e.key === 'ArrowDown' ? 1 : items.length - 1)) % items.length;
  items[to].focus();
  return true;
}
for (const m of document.querySelectorAll('.menu')) m.addEventListener('keydown', e => menuStep(e, m));
$('btnCatalog').addEventListener('click', async e => {
  e.stopPropagation();
  closeMenu();
  setEnabled(catMenu.querySelector('[data-cact=undo]'), !!undoInfo, 'Nothing to undo - no bulk change since the app started.');
  setEnabled(catMenu.querySelector('[data-cact=replace]'), apps.some(a => (a.groups || []).length), 'No app is assigned to a group.');
  setEnabled(catMenu.querySelector('[data-cact=export]'), apps.length > 0, 'The catalog is empty.');
  const conn = !!(state && state.configured);
  setEnabled(catMenu.querySelector('[data-cact=tenantsetup]'), conn && apps.length > 0, conn ? 'The catalog is empty.' : 'Set up the connection in Settings first.');
  setEnabled(catMenu.querySelector('[data-cact=overview]'), conn && apps.some(a => a.hasAppId), conn ? 'No app in the catalog is in Intune yet.' : 'Set up the connection in Settings first.');
  setEnabled(catMenu.querySelector('[data-cact=wingetcheck]'), apps.some(a => a.wingetId), 'No app in the catalog has a Winget ID.');
  const r = $('btnCatalog').getBoundingClientRect();
  placeMenu(catMenu, r.right - 240, r.bottom + 4);
});
document.addEventListener('click', e => { if (!catMenu.contains(e.target)) catMenu.hidden = true; });
document.addEventListener('keydown', e => { if (e.key === 'Escape' && !catMenu.hidden) { catMenu.hidden = true; $('btnCatalog').focus(); } });
catMenu.addEventListener('click', e => {
  const b = e.target.closest('button'); if (!b || b.disabled) return;
  catMenu.hidden = true;
  ({ export: exportCsv, import: openCsvImport, fillall: () => fillDetails([]), replace: () => openReplace({}), undo: undoLast, recent: openRecent, tenantsetup: openTenantSetup, overview: openOverview, retired: openRetired, suggest: openSuggest, matrix: openMatrix, wingetcheck: checkWingetVersions,
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
$('btnTenantClear') && $('btnTenantClear').addEventListener('click', async () => {
  const names = apps.filter(a => tenantState(a) === 'missing').map(a => a.name);
  if (!names.length) return;
  if (!(await ask(`Clear the App ID of ${names.length} app${names.length === 1 ? '' : 's'}?\n\nOnly the catalog changes - their settings, groups and packages stay, and they read "ready to deploy". Send to Intune then creates them in this tenant. Each file is kept as a copy first (Earlier versions...).`, { ok: 'Clear App IDs', danger: false }))) return;
  const r = await api('/api/clear-appids', { names });
  toast(r.ok ? `Cleared ${r.cleared.length} App ID(s).` : r.error, !r.ok);
  if ($('filter').value === 'notintenant') $('filter').value = 'all';
  await loadApps();
});
// Only the Apps list sorts by its headers (2.38.16: a click on a Checks header set the sort to nothing).
for (const th of document.querySelectorAll('#grid th[data-sort]')) th.addEventListener('click', () => {
  if (sortKey === th.dataset.sort) sortDesc = !sortDesc; else { sortKey = th.dataset.sort; sortDesc = false; }
  renderApps();
});
let searchTimer = null;
$('search').addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(renderApps, 120); });
$('filter').addEventListener('change', () => {
  showIntuneOnly = false;
  const sv = activeView();
  if (sv) $('search').value = sv.search || '';
  renderApps(); updateViewButtons();
});
$('search').addEventListener('input', updateViewButtons);
document.addEventListener('keydown', e => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f' && !$('viewApps').hidden && !document.querySelector('dialog[open]:not(#dlgRun):not(.minimized)')) { e.preventDefault(); $('search').focus(); }
  if (e.key === 'F5') { e.preventDefault(); loadApps(); loadState(); }
  // Ctrl+S in the app editor saves it (the form's own submit, with its checks).
  // Only when the editor is the dialog on top - not under a question, the history or the code editor.
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's' && $('dlgApp').open && wcStack.filter(d => d.open && !d.classList.contains('minimized')).pop() === $('dlgApp')) { e.preventDefault(); $('appForm').requestSubmit(); return; }
  listKeys(e);
});
// The Apps list by keyboard - only while nothing else has the keys: no
// dialog or menu open, and no field focused (typing is never taken over).
function listKeys(e) {
  if ($('viewApps').hidden || document.querySelector('dialog[open]:not(#dlgRun)') || document.querySelector('.menu:not([hidden])')) return;
  // ... nor a button, link or summary - Enter and Delete there mean that control, not the list.
  if (e.target.closest && e.target.closest('input, textarea, select, [contenteditable], button, a, summary, .menu, .banner')) return;
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
    syncSel();
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
    syncSel(); updateActions();
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
  if (window.refreshDetectionBlocks) refreshDetectionBlocks();
}
$('xType').addEventListener('change', showDetFields);
function fillDeploy(d) {
  deployTouched = false;
  $('deploySec').open = false;
  if (!d) d = { detection: { type: '' }, architecture: ['x64'], installContext: 'System', minOSKey: 'W10_22H2', installTimeMinutes: 60, deviceRestartBehavior: 'basedOnReturnCode', returnCodes: [], dependencies: [] };
  const x = d.detection || { type: '' };
  $('xType').value = x.type || ''; $('xScript').value = x.script || ''; $('xProductCode').value = x.productCode || '';
  setTimeout(() => { if (typeof checkProductCodes === 'function') checkProductCodes(); }, 0);
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
  $('xSupSet').checked = !!d.supersedesSet;
  $('xSup').replaceChildren(...(d.supersedes || []).map(s => supRow(s)));
  showSupState();
  if (window.edFoldsReset) edFoldsReset();
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
    supersedesSet: $('xSupSet').checked, supersedes: readSupersedence(),
  };
}

// ---------------------------------------------------------------- deploy
let deployPlan = [], deployResults = {}, deployStop = false, deployRunning = false;
function setDeployStatus(name, cls, text, detail) {
  const row = [...$('deployRows').children].find(r => r.dataset.name === name);
  // The package's warnings stay under its status while it is sent (2.38.0) - they went with the first status change.
  const plan = (deployPlan || []).find(a => a.name === name), warns = plan && plan.ready ? (plan.warnings || []) : [];
  if (row) row.lastChild.replaceChildren(el('span', { class: 'pill ' + cls, text, title: detail || '' }), detail ? el('span', { class: 'why', text: detail }) : '',
    ...warns.map(w => el('span', { class: 'why pkgwarn', text: '⚠ ' + w })));
}
// "3 of 10 - 2 done, 1 failed" and the bar, from deployResults.
function deployProgress() {
  const ready = deployPlan.filter(a => a.ready), res = ready.map(a => deployResults[a.name]).filter(Boolean);
  const n = k => res.filter(x => x === k).length;
  $('deployProgress').hidden = false;
  $('deployBar').style.width = (ready.length ? Math.round(100 * res.length / ready.length) : 0) + '%';
  $('deployProgressText').textContent = `${res.length} of ${ready.length}` + [[n('ok'), 'done'], [n('failed'), 'failed'], [n('skipped'), 'skipped'], [n('stopped'), 'not started']].filter(x => x[0]).map(x => ` - ${x[0]} ${x[1]}`).join('');
}
$('btnDeploy').addEventListener('click', () => openDeploy([...selected]));
async function openDeploy(names, opts = {}) {
  if (wcResume('dlgDeploy')) return;
  $('btnDeployClose').textContent = 'Cancel';
  const r = await api('/api/deploy-plan', { names });
  if (!r.ok) { toast(r.error, true); return; }
  deployPlan = r.apps; deployResults = {};
  $('deployRows').replaceChildren(...deployPlan.map(a => el('tr', { 'data-name': a.name },
    el('td', { text: a.name }), el('td', {}, el('span', { text: a.replacesLob ? 'Create as Win32' : a.update ? 'Send settings' : 'Create' }), a.replacesLob ? el('span', { class: 'why', text: a.note }) : ''),
    el('td', {}, a.ready ? el('span', { class: 'pill muted', text: 'Waiting' }) : el('span', { class: 'pill warn', text: 'Not ready', title: a.reason }), a.ready ? '' : el('span', { class: 'why', text: a.reason }),
      // 2.36.0: what doesn't fit together in its package - it can be sent, but likely isn't what was meant.
      ...(a.ready ? (a.warnings || []).map(w => el('span', { class: 'why pkgwarn', text: '⚠ ' + w })) : [])))));
  if (r.circular && r.circular.length) toast('These depend on each other in a circle: ' + r.circular.join(', '), true);
  $('deployLog').textContent = r.note ? r.note + '\n' : '';
  $('deployProgress').hidden = true; $('btnDeployStop').hidden = true; $('btnDeployRetry').hidden = true;
  const n = deployPlan.filter(a => a.ready).length;
  $('btnDeployGo').textContent = n === 1 ? 'Send 1 app' : `Send ${n} apps`; $('btnDeployGo').title = 'Create or update the ready apps in Intune, in this order';
  $('btnDeployGo').disabled = n === 0; $('btnDeployClose').hidden = false; $('dpGroups').disabled = false;
  $('dlgDeploy').showModal();
  // The send is what's here to do - not the folded log, which a dialog's first stop would otherwise be.
  (n ? $('btnDeployGo') : $('btnDeployClose')).focus();
  // From Add and send's summary: the send starts at once (the summary was the review).
  if (opts.autostart && n) runDeployQueue(deployPlan.filter(a => a.ready).map(a => a.name));
}
// One app: deploy, then push its groups when the step asks for it. Resolves with whether the deploy worked.
function deployOne(name) {
  return new Promise(resolve => {
    runJob({ name, sendGroups: $('dpGroups').checked }, async (ok, result, after) => {
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
    else setDeployStatus(name, r.groups === false ? 'warn' : 'ok', r.groups === true ? 'Done, groups pushed' : r.groups === false ? 'Done, groups failed' : 'Done', r.groups === false ? 'Send groups again from the toolbar.' : '');
    deployProgress();
  }
  deployRunning = false; $('btnDeployClose').textContent = 'Close';
  $('btnDeployStop').hidden = true;
  const ready = deployPlan.filter(a => a.ready).map(a => a.name);
  const retry = ready.filter(n => ['failed', 'skipped', 'stopped'].includes(deployResults[n]));
  $('btnDeployRetry').hidden = !retry.length;
  $('btnDeployRetry').textContent = retry.length ? `Retry ${retry.length}` : 'Retry failed';
  // Done closes the dialog (2.38.8 - it was a switched-off label: it looked like a button and did nothing). Set after
  // the job runner gives its buttons back, so it isn't switched off again.
  const done = () => { const b = $('btnDeployGo'); b.textContent = 'Done'; delete b.dataset.jobWas; b.disabled = false; b.title = 'Close - the results stay in the list and in Recent changes'; };
  done(); setTimeout(done, 0);
  // One way out (Done), and the send's own option isn't offered again once it's over (Retry keeps it as it was).
  $('btnDeployClose').hidden = true; $('dpGroups').disabled = !retry.length;
  $('btnDeployGo').focus();
  const okN = ready.filter(n => deployResults[n] === 'ok').length;
  toast(`Send to Intune finished: ${okN} of ${ready.length} done${retry.length ? `, ${retry.length} to retry` : ''}.`, okN < ready.length);
  loadApps();
}
$('btnDeployGo').addEventListener('click', () => {
  if (deployRunning) return;
  if ($('btnDeployGo').textContent === 'Done') { $('dlgDeploy').close(); return; }
  runDeployQueue(deployPlan.filter(a => a.ready).map(a => a.name));
});
$('btnDeployRetry').addEventListener('click', () => !deployRunning && runDeployQueue(deployPlan.filter(a => a.ready && ['failed', 'skipped', 'stopped'].includes(deployResults[a.name])).map(a => a.name)));
$('btnDeployStop').addEventListener('click', () => { deployStop = true; $('btnDeployStop').disabled = true; toast('Stopping after the app that is running.'); });
$('dlgDeploy').addEventListener('cancel', e => { if (deployRunning) { e.preventDefault(); toast('Deploying - use "Stop after this app" first, or wait.', true); } });
$('btnDeployClose').addEventListener('click', e => { if (deployRunning) { e.stopImmediatePropagation(); toast('Deploying - use "Stop after this app" first, or wait.', true); } }, true);

// ---------------------------------------------------------------- send groups
let pushNames = [];
$('btnPush').addEventListener('click', () => openPushGroups([...selected]));
async function openPushGroups(names) {
  if (wcResume('dlgPush')) return;
  pushNames = names;
  $('pushRows').replaceChildren(el('tr', {}, el('td', { colspan: 3, class: 'muted', text: 'Reading the current assignments in Intune...' })));
  $('pushLog').textContent = '';
  $('btnPushGo').disabled = true;
  $('btnPushClose').hidden = false;
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
  // Done (after it worked) closes - it used to run Apply again.
  if ($('btnPushGo').textContent === 'Done') { $('btnPushGo').closest('dialog').close(); return; }
  $('btnPushGo').disabled = true;
  await runJob({ names: pushNames, mode: 'Apply' }, ok => {
    toast(ok ? 'Groups pushed to Intune.' : 'Send groups failed - see the log.', !ok);
    if (ok) { const done = () => { const b = $('btnPushGo'); b.textContent = 'Done'; delete b.dataset.jobWas; b.disabled = false; }; done(); setTimeout(done, 0); $('btnPushClose').hidden = true; $('btnPushGo').focus(); loadApps(); if (typeof checksRefresh === 'function') checksRefresh(pushNames); }
  }, { path: '/api/push-start', log: 'pushLog', startText: 'Applying...' });
});

// ---------------------------------------------------------------- batch edit, add/remove groups
function openBatch(names) {
  if (wcResume('dlgBatch')) return;
  batchNames = names;
  $('batchTitle').textContent = `Batch edit - ${names.length} app(s)`;
  $('batchText').textContent = `Tick the fields to change on ${names.join(', ')}. Everything else stays as each app has it.`;
  for (const c of document.querySelectorAll('[data-bf]')) c.checked = false;
  $('bDepMode').value = 'add';
  $('bMinOs').replaceChildren(...((prefs && prefs.minOsChoices) || [{ value: 'W10_22H2', label: 'Windows 10 22H2' }]).map(o => el('option', { value: o.value, text: o.label || o.value })));
  $('bMinOs').value = 'W10_22H2';
  appPicker($('bDeps'), apps.map(a => a.name).filter(n => !names.includes(n)), new Set(), 'data-bdep', 'None - tick the apps to install first.');
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
  const shown = changes.slice(0, 400), withApp = changes.some(c => c.app);
  box.replaceChildren(el('div', { class: 'tablewrap short' }, el('table', { class: 'plan' },
    el('thead', {}, el('tr', {}, withApp ? el('th', { text: 'App' }) : '', el('th', { text: 'Field' }), el('th', { text: 'Now' }), el('th', { text: 'New' }))),
    el('tbody', {}, ...shown.map(c => { const first = withApp && c.app !== last; last = c.app; return el('tr', { class: first ? 'first' : '' },
      withApp ? el('td', { class: 'name', text: first ? c.app : '' }) : '', el('td', { text: labels[c.field] || c.field }),
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
    publisher: () => $('bPublisher').value, owner: () => $('bOwner').value, developer: () => $('bDeveloper').value,
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
  if (wcResume('dlgGroupsBatch')) return;
  gbMode = mode; gbNames = names;
  const sel = names.map(n => apps.find(a => a.name === n)).filter(Boolean);
  $('gbTitle').textContent = mode === 'add' ? 'Add groups' : 'Remove groups';
  $('gbText').textContent = (mode === 'add' ? 'Adds these groups to ' : 'Removes these groups from ') + `${names.join(', ')} - in the catalog. Send groups sends them to Intune.`;
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
  menuOpener = document.activeElement && document.activeElement !== document.body ? document.activeElement : null;
  const one = oneSelected();
  const sel = [...selected].map(n => apps.find(a => a.name === n)).filter(Boolean);
  const any = sel.length > 0, anyId = sel.some(a => a.hasAppId);
  const enable = { edit: !!one, duplicate: !!one, deploy: any, pushgroups: anyId, package: !any || sel.some(a => !a.wingetId), pull: anyId, pushsettings: anyId, status: !!(one && one.hasAppId), batchedit: any, addgroups: any, removegroups: any,
    replacegroup: sel.some(a => (a.groups || []).length), copyid: anyId, clearid: anyId, delete: anyId, remove: any, retire: !!(one && (one.hasAppId || one.retiringSince)),
    takeversion: sel.some(a => a.wingetId && a.wingetVersion && a.newerOnWinget && !(a.managed && a.hasAppId)),
    watchfetch: !!(one && !one.wingetId && one.watchWinget),
    filldetails: sel.some(a => a.wingetId && !isStoreId(a.wingetId)),
    release: !!(one && one.managed && one.hasAppId && !one.pilotVersion), promote: !!(one && one.pilotVersion), withdraw: !!(one && one.pilotVersion),
    managed: any,
    rollback: !!(one && one.managed && (one.previousVersions || []).length && !one.pilotVersion), cleanup: !!(one && (one.previousVersions || []).length > 1) };
  const why = {
    edit: 'Select exactly one app.', duplicate: 'Select exactly one app.', filldetails: 'Only for Winget apps - their details come from winget.', watchfetch: one ? 'Only for an own package that watches a winget package for new versions (the editor: Winget package to watch).' : 'Select exactly one app.', pushgroups: 'None of the selected apps is in Intune yet.',
    package: 'Winget apps use the shared package (Settings > Packaging).', pull: 'Only for apps already in Intune (with an App ID).',
    pushsettings: 'Only for apps already in Intune (with an App ID).', status: one ? 'This app isn\'t in Intune yet.' : 'Select exactly one app that is in Intune.',
    deploy: 'Select one or more apps first.', batchedit: 'Select one or more apps first.', addgroups: 'Select one or more apps first.', removegroups: 'Select one or more apps first.',
    replacegroup: any ? 'None of the selected apps is assigned to a group.' : 'Select one or more apps first.',
    copyid: 'None of the selected apps has an App ID.', clearid: 'None of the selected apps has an App ID.',
    delete: 'None of the selected apps is in Intune.', remove: 'Select one or more apps first.',
    retire: one ? 'This app isn\'t in Intune - Remove from catalog is enough.' : 'Select exactly one app.',
    takeversion: sel.some(a => a.managed && a.hasAppId) ? 'Apps in Intune with managed updates get a new version through Release new version.' : apps.some(a => a.wingetVersion) ? 'winget offers nothing newer for the selected apps.' : 'Ask winget first: Catalog > Check winget for new versions.',
    release: !one ? 'Select exactly one app.' : !one.managed ? 'Turn managed updates on first (More > Managed updates on).' : !one.hasAppId ? 'Send it to Intune first - that is its first release.' : 'A version is in pilot already - promote or withdraw it first.',
    promote: one ? 'No version of this app is in pilot.' : 'Select exactly one app.', withdraw: one ? 'No version of this app is in pilot.' : 'Select exactly one app.',
    managed: 'Select one or more apps first.',
    rollback: !one ? 'Select exactly one app.' : one.pilotVersion ? 'A version is in pilot - promote or withdraw it first.' : 'No earlier release of this app is kept in Intune.',
    cleanup: !one ? 'Select exactly one app.' : 'Only one superseded version (or none) - it is kept for rollback.',
  };
  for (const b of menu.querySelectorAll('button')) setEnabled(b, !!enable[b.dataset.act], why[b.dataset.act]);
  // 2.37.0: what can never apply to the selected apps isn't listed at all - greyed out with a reason stays only
  // what could be made to apply (send it first, select one). A section with nothing left loses its heading too.
  if (any) {
    const own = sel.some(a => !a.wingetId && !a.office), winget = sel.some(a => a.wingetId && !isStoreId(a.wingetId));
    // Store and Microsoft 365 apps (2.38.23): Microsoft or the Store updates them - no managed updates or releases.
    const versioned = sel.some(a => !(a.wingetId && isStoreId(a.wingetId)) && !(a.office && !a.wingetId) && !(a.msHint && !a.wingetId));
    const never = {
      package: !own, watchfetch: !own, takeversion: !winget, filldetails: !winget, managed: !versioned, release: !versioned,
      promote: !sel.some(a => a.pilotVersion), withdraw: !sel.some(a => a.pilotVersion),
      rollback: !sel.some(a => (a.previousVersions || []).length), cleanup: !sel.some(a => (a.previousVersions || []).length > 1),
    };
    for (const b of menu.querySelectorAll('button[data-act]')) b.hidden = !!never[b.dataset.act];
  } else for (const b of menu.querySelectorAll('button[data-act]')) b.hidden = false;
  // Headings and rules follow what is left in their section.
  let head = null, rule = null, shown = 0;
  const settle = () => { if (head) head.hidden = !shown; if (rule) rule.hidden = !shown; };
  for (const n of [...menu.children]) {
    if (n.tagName === 'HR') { settle(); rule = n; head = null; shown = 0; }
    else if (n.classList.contains('mhead')) head = n;
    else if (n.tagName === 'BUTTON' && !n.hidden) shown++;
  }
  settle();
  // No rule before the first section that is shown.
  const firstShown = [...menu.children].find(n => !n.hidden); if (firstShown && firstShown.tagName === 'HR') firstShown.hidden = true;
  menu.querySelector('[data-act=package]').textContent = !any ? 'Package every app with its own installer' : enable.package ? `Package ${sel.length > 1 ? 'the selected apps' : 'this app'} (build .intunewin)` : 'Package (Winget apps use the shared package)';
  const allManaged = sel.length && sel.every(a => a.managed);
  menu.querySelector('[data-act=managed]').textContent = allManaged ? 'Managed updates off...' : 'Managed updates on...';
  menu.querySelector('[data-act=managed]').dataset.on = allManaged ? '0' : '1';
  const ids = sel.filter(a => a.hasAppId).length;
  menu.querySelector('[data-act=copyid]').textContent = ids > 1 ? `Copy ${ids} App IDs` : 'Copy App ID';
  menu.querySelector('[data-act=clearid]').textContent = ids > 1 ? `Clear ${ids} App IDs...` : 'Clear App ID...';
  menu.querySelector('[data-act=remove]').textContent = sel.length > 1 ? `Remove ${sel.length} apps from catalog...` : 'Remove from catalog...';
  catMenu.hidden = true;
  placeMenu(menu, x, y);
}
// Escape gives focus back to what opened it (2.38.0) - the More button, the panel's More..., the row.
let menuOpener = null;
function closeMenu(back) { const was = !menu.hidden; menu.hidden = true; if (back && was && menuOpener && menuOpener.isConnected) menuOpener.focus(); }
$('btnMore').addEventListener('click', e => { e.stopPropagation(); const r = $('btnMore').getBoundingClientRect(); openMenu(r.left, r.bottom + 4); });
$('gridBody').addEventListener('contextmenu', e => {
  const tr = e.target.closest('tr'); if (!tr) return;
  e.preventDefault();
  if (!selected.has(tr.dataset.name)) selectRow(tr.dataset.name, {});
  openMenu(e.clientX, e.clientY);
});
document.addEventListener('click', e => { if (!menu.contains(e.target)) closeMenu(); });
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeMenu(true); });

function runDialog(title, text) {
  $('runTitle').textContent = title; $('runText').textContent = text || ''; $('runLog').textContent = '';
  // A tray in the corner, not a modal: keep working while it runs (Hide - the button at the top brings it back).
  // Above a dialog that's open (the app editor, the code editor), it opens on top of it - otherwise it would be hidden under it.
  if (!$('dlgRun').open) { if (document.querySelector('dialog[open]:modal:not(.minimized)')) $('dlgRun').showModal(); else $('dlgRun').show(); }
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
    case 'deploy': openDeploy(names); break;
    case 'pull': openPull(names); break;
    case 'pushsettings': pushSettings(sel().filter(a => a.hasAppId).map(a => a.name)); break;
    case 'batchedit': if (!prefs) await loadPrefs(); openBatch(names); break;
    case 'filldetails': fillDetails(names); break;
    case 'addgroups': if (!prefs) await loadPrefs(); openGroupsBatch('add', names); break;
    case 'removegroups': openGroupsBatch('remove', names); break;
    case 'status': openStatus(one.name); break;
    case 'retire': openRetire(one.name); break;
    case 'edit': openEditor(one.name); break;
    case 'duplicate': duplicateApp(one.name); break;
    case 'watchfetch': fetchWatched(one.name); break;
    case 'pushgroups': openPushGroups(names); break;
    case 'replacegroup': openReplace({ names }); break;
    case 'release': openRelease(one.name); break;
    case 'promote': promoteRelease(one.name); break;
    case 'withdraw': withdrawRelease(one.name); break;
    case 'rollback': rollbackRelease(one.name); break;
    case 'cleanup': {
      const keep = one.previousVersions.slice(-1)[0], del = one.previousVersions.slice(0, -1);
      if (!(await ask(`Delete ${del.length} superseded version${del.length === 1 ? '' : 's'} of ${one.name} from Intune?\n\n${del.join(', ')}\n\nThey have no assignments; devices keep what they have installed. ${keep} is kept so you can roll back.`))) return;
      const r = await api('/api/release-cleanup', { name: one.name });
      toast(r.ok ? `Deleted ${r.removed.join(', ')} from Intune; kept ${r.kept.join(', ')}.` : r.error, !r.ok); loadApps();
      break;
    }
    case 'managed': {
      const on = menu.querySelector('[data-act=managed]').dataset.on === '1', ws = sel().map(a => a.name);
      if (!(await ask(`Managed updates ${on ? 'on' : 'off'} for ${ws.length} app${ws.length === 1 ? '' : 's'}?\n\n${on ? 'Each installs exactly its App version, and new versions go to the pilot groups first (More > Release new version). Winget apps: the install command and detection rule follow the App version (set one with More > Take winget\'s version before the first deploy). Own packages: their detection rule must compare a version - a release updates it. Send settings sends the change to apps already in Intune.' : 'Their commands stay pinned to the current version until you change the install method (the editor\'s Install with).'} Undo takes it back.`, { ok: on ? 'Turn on' : 'Turn off', danger: false }))) return;
      const r = await api('/api/managed-updates', { names: ws, on });
      toast(r.ok ? `Managed updates ${on ? 'on' : 'off'} for ${r.changed.length} app(s).${r.skipped.length ? ' Skipped: ' + r.skipped.join(', ') : ''}` : r.error, !r.ok); loadApps();
      break;
    }
    case 'takeversion': {
      const take = sel().filter(a => a.wingetId && a.newerOnWinget);
      if (!(await ask(`Pin winget's newest version for ${take.length} app${take.length === 1 ? '' : 's'}?\n\n${take.map(a => `${a.name}: ${a.version || '(none)'} → ${a.wingetVersion}`).join('\n')}\n\nManaged apps then install exactly this version (their command and detection follow it) - send the ones in Intune again. Apps on the winget command only show it as their version. Undo takes it back.`, { ok: 'Take version', danger: false }))) return;
      const r = await api('/api/winget-take-version', { names: take.map(a => a.name) });
      if (!r.ok) { toast(r.error, true); return; }
      toast(`App version updated on ${r.changed.length} app(s).${r.skipped.length ? ' Skipped: ' + r.skipped.join(', ') : ''}`);
      await loadApps();
      if (r.deployed.length && await ask(`Send the settings of the ${r.deployed.length} app(s) in Intune now?\n\n${r.deployed.join('\n')}`, { ok: 'Push settings', danger: false })) pushSettings(r.deployed);
      break;
    }
    case 'copyid': {
      const ids = sel().filter(a => a.hasAppId).map(a => a.appId);
      try { await navigator.clipboard.writeText(ids.join('\n')); toast(ids.length > 1 ? `Copied ${ids.length} App IDs.` : 'Copied ' + ids[0]); } catch (err) { toast('Could not copy: ' + ids.join(', '), true); }
      break;
    }
    case 'clearid': {
      const ids = sel().filter(a => a.hasAppId).map(a => a.name);
      if (!(await ask(`Clear ${ids.length === 1 ? `${ids[0]}'s App ID` : `the App IDs of ${ids.length} apps`} in the catalog?\n\nOnly the catalog changes - Intune isn't touched. Settings, groups and packages stay, and the app can be deployed again (here or in another tenant). Undo takes it back.`, { ok: 'Clear App IDs', danger: false }))) return;
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
// 2.38.8: each differing field is a choice between its two values - click the one to keep (Intune's is picked) -
// instead of a "Keep catalog" tick; the log folds away unless something failed.
function pullCount() {
  const rows = [...document.querySelectorAll('#pullReview tr[data-field]')];
  const fromIntune = rows.filter(r => r.dataset.pick === 'intune').length;
  $('btnPullApply').textContent = rows.length ? `Save to catalog (${fromIntune} from Intune, ${rows.length - fromIntune} kept)` : 'Save to catalog';
}
function pullPick(tr, side) {
  tr.dataset.pick = side;
  for (const td of tr.querySelectorAll('td.pick')) {
    const on = td.dataset.side === side;
    td.classList.toggle('on', on);
    td.querySelector('input').checked = on;
  }
  pullCount();
}
function openPull(names) {
  if (wcResume('dlgPull')) return;
  $('pullText').textContent = `Reading ${names.length === 1 ? names[0] : names.length + ' apps'} from Intune... Anything that matches (or the catalog has no value for) is taken at once; whatever differs is shown here to choose.`;
  $('pullReview').replaceChildren(); $('pullLog').textContent = ''; $('pullLogBox').open = false; $('btnPullApply').hidden = true; pullPending = '';
  $('dlgPull').showModal(); $('dlgPull').querySelector('[data-close]').focus();
  runJob({ names }, (ok, res, after) => {
    if (!ok || !after) { $('pullText').textContent = 'Reading from Intune failed - the log says why.'; $('pullLogBox').open = true; return; }
    const msg = [];
    if (after.applied && after.applied.length) msg.push(`Taken from Intune: ${after.applied.join(', ')}.`);
    // Applied at once (nothing to choose): Checks asks again about them.
    if (after.applied && after.applied.length && typeof checksRefresh === 'function') checksRefresh(after.applied);
    if (after.failed && after.failed.length) { msg.push(`Could not read: ${after.failed.join('; ')}.`); $('pullLogBox').open = true; }
    const review = after.review || [];
    if (review.length) msg.push('These differ - click the value to keep for each (Intune’s is picked). Nothing in Intune changes.');
    else if (!msg.length) msg.push('The catalog already matches Intune - nothing to change.');
    $('pullText').textContent = msg.join(' ');
    pullPending = after.pending || '';
    let n = 0;
    $('pullReview').replaceChildren(...review.map(r => {
      const rows = r.diffs.map(d => {
        const group = `pull${n++}`;
        const cell = (side, value) => {
          const id = `${group}-${side}`;
          const td = el('td', { class: 'pick v', 'data-side': side },
            el('label', { for: id }, el('input', { type: 'radio', name: group, id, 'aria-label': `${d.field}: keep the ${side === 'intune' ? 'Intune' : 'catalog'} value` }), el('span', { text: value === '' || value === null || value === undefined ? '(blank)' : String(value) })));
          td.addEventListener('click', () => pullPick(tr, side));
          td.querySelector('input').addEventListener('change', () => pullPick(tr, side));
          return td;
        };
        const tr = el('tr', { 'data-field': d.field }, el('td', { class: 'f', text: d.field }), cell('catalog', d.local), cell('intune', d.intune));
        pullPick(tr, 'intune');
        return tr;
      });
      const all = side => el('button', { type: 'button', class: 'btn small', text: side === 'intune' ? 'All from Intune' : 'Keep all', onclick: () => rows.forEach(tr => pullPick(tr, side)) });
      return el('div', { class: 'pullapp', 'data-app': r.app },
        el('div', { class: 'pullhead' }, el('h3', { text: r.app }), rows.length > 1 ? el('span', { class: 'pullall' }, all('catalog'), all('intune')) : ''),
        el('table', {}, el('thead', {}, el('tr', {}, el('th', { text: 'Field' }), el('th', { text: 'Catalog' }), el('th', { text: 'Intune' }))), el('tbody', {}, ...rows)));
    }));
    $('btnPullApply').hidden = !pullPending;
    pullCount();
    // The first choice to make, else the way out - not the folded log.
    const firstPick = document.querySelector('#pullReview input:checked');
    (firstPick || (pullPending ? $('btnPullApply') : $('dlgPull').querySelector('[data-close]'))).focus();
    loadApps();
  }, { path: '/api/pull-start', log: 'pullLog', startText: 'Reading from Intune...' });
}
$('btnPullApply').addEventListener('click', async () => {
  const keep = {};
  for (const box of document.querySelectorAll('#pullReview .pullapp')) keep[box.dataset.app] = [...box.querySelectorAll('tr[data-pick="catalog"]')].map(tr => tr.dataset.field);
  const r = await api('/api/pull-apply', { pending: pullPending, keep });
  if (!r.ok) { toast(r.error, true); return; }
  $('dlgPull').close(); toast('Saved to the catalog.'); loadApps();
  if (typeof checksRefresh === 'function') checksRefresh(Object.keys(keep));
});

// ---------------------------------------------------------------- retiring an app
let retiring = '';
async function openRetire(name) {
  if (wcResume('dlgRetire')) return;
  retiring = name;
  $('retireTitle').textContent = `Retire ${name}`;
  $('retireGroups').textContent = ''; $('retireProgress').textContent = 'Reading...'; $('retireProgress').className = '';
  for (const id of ['btnRetireStart', 'btnRetireFinish', 'btnRetireRefresh']) $(id).hidden = true;
  if (!$('dlgRetire').open) $('dlgRetire').showModal();
  const r = await api('/api/retire-status', { name });
  if (!r.ok) { $('retireProgress').textContent = r.error; return; }
  const g = r.groups || [];
  if (!r.retiringSince) {
    $('retireGroups').textContent = g.length ? `Uninstalled from: ${g.join(', ')}.` : 'It has no groups - nothing to uninstall.';
    $('retireProgress').textContent = r.inIntune ? '' : 'It isn\'t in Intune.';
    $('btnRetireStart').hidden = !g.length || !r.inIntune; $('btnRetireFinish').hidden = !!g.length && r.inIntune;
    return;
  }
  $('retireGroups').textContent = `Being retired since ${r.retiringSince} - uninstalled from: ${g.join(', ') || 'no groups'}.`;
  const p = r.progress;
  $('retireProgress').textContent = r.note || (p ? p.text : '');
  $('retireProgress').className = p && p.done ? 'ok' : '';
  $('btnRetireRefresh').hidden = false; $('btnRetireFinish').hidden = false;
}
$('btnRetireRefresh').addEventListener('click', () => openRetire(retiring));
$('btnRetireStart').addEventListener('click', async () => {
  const name = retiring;
  if (!(await ask(`Uninstall ${name} from every device of its groups?\n\n${$('retireGroups').textContent}\n\nIts groups in the catalog become Uninstall too. Nothing is deleted yet.`, { ok: 'Uninstall', danger: true }))) return;
  $('dlgRetire').close();
  runDialog(`Retire ${name}`, 'Its groups get it as Uninstall.');
  runJob({ name }, ok => { toast(ok ? `${name} is being uninstalled - finish the retirement once the devices report it gone (More > Retire).` : `Retiring ${name} failed - nothing changed. See the log.`, !ok); loadApps(); },
    { path: '/api/retire-start', log: 'runLog', startText: 'Retiring...' });
});
$('btnRetireFinish').addEventListener('click', async () => {
  const name = retiring, a = apps.find(x => x.name === name);
  const still = /still have it/.test($('retireProgress').textContent);
  if (!(await ask(`Delete ${name} from Intune and remove it from the catalog?\n\n${still ? 'Some devices still have it - deleting it now leaves it on them, unmanaged.\n\n' : ''}A copy is archived (Catalog > Retired apps).`, { ok: 'Delete and archive', danger: true }))) return;
  $('dlgRetire').close();
  if (!a || !a.hasAppId) {
    const r = await api('/api/retire-finish', { name });
    toast(r.ok ? `${name} is retired and archived.` : r.error, !r.ok); loadApps(); return;
  }
  runDialog(`Finish retiring ${name}`, 'Deleting it from Intune, then archiving it.');
  runJob({ name }, ok => { toast(ok ? `${name} is retired: deleted from Intune and archived.` : `Deleting ${name} from Intune failed - it stays in the catalog. See the log.`, !ok); loadApps(); },
    { path: '/api/retire-finish', log: 'runLog', startText: 'Deleting...' });
});
async function openRetired() {
  if (wcResume('dlgRetired')) return;
  skeleton($('retiredRows'), 3, 2); $('retiredNote').textContent = '';
  $('dlgRetired').showModal();
  const r = await api('/api/retired-list');
  if (!r.ok) { $('retiredNote').textContent = r.error; $('retiredRows').replaceChildren(); return; }
  $('retiredNote').textContent = r.apps.length ? '' : 'No app has been retired yet (More > Retire).';
  $('retiredRows').replaceChildren(...r.apps.map(x => el('tr', {}, el('td', { text: x.name || x.id }), el('td', { text: x.retired }),
    el('td', { class: 'act' }, el('button', { class: 'btn small', text: 'Restore', onclick: async () => {
      const y = await api('/api/retired-restore', { id: x.id });
      if (!y.ok) { toast(y.error, true); return; }
      $('dlgRetired').close(); toast(`${y.name} is back in the catalog - set its groups and send it to Intune to use it again.`); await loadApps(); openEditor(y.name);
    } })))));
}

// ---------------------------------------------------------------- install status
async function openStatus(name) {
  if (wcResume('dlgStatus')) return;
  $('statusTitle').textContent = 'Install status - ' + name;
  $('statusSummary').textContent = 'Reading Intune’s install status report...';
  skeleton($('statusRows'), 7, 4); $('statusErrors').hidden = true;
  $('dlgStatus').showModal();
  const r = await api('/api/install-status', { name });
  if (!r.ok) { $('statusSummary').textContent = r.error; $('statusRows').replaceChildren(); return; }
  // 2.38.9: who its groups target but hasn't reported yet - listed as "Waiting for report", after those that did.
  const waitN = r.waiting || 0, reported = (r.rows || []).length - waitN;
  $('statusSummary').textContent = (reported ? String(r.summary).replace(/\.?\s*$/, '.') : 'No device has reported yet.') + (r.truncated ? ' (Only the first rows are shown.)' : '')
    + (waitN ? ` ${waitN} more in its groups haven't reported yet - a Required one appears once its device checks in and tries the app (Company Portal > Sync speeds it up), an Available one once its user installs it from the Company Portal.` : '')
    + ((r.targetNotes || []).length ? ' ' + r.targetNotes.join(' ') : '');
  const top = r.topErrors || [];
  $('statusErrors').hidden = !top.length;
  $('statusErrList').replaceChildren(...top.map(e => el('li', {}, el('strong', { text: `${e.count} × ${e.hex}` }), ` ${e.meaning} `, el('span', { class: 'muted', text: e.fix }))));
  // Nothing reported yet: one line in the table saying so and why, not empty column headings (2.38.8).
  if (!r.rows.length) { $('statusRows').replaceChildren(el('tr', {}, el('td', { colspan: 7, class: 'muted', text: 'No device has reported yet, and its groups list no device or user here. Intune lists a device once it has checked in and tried the app - usually within an hour or two of the assignment.' }))); return; }
  $('statusRows').replaceChildren(...r.rows.map(x => el('tr', { class: x.waiting ? 'waiting' : '' }, el('td', { text: x.device || '-' }), el('td', { text: x.user || '-' }),
    el('td', {}, el('span', { class: 'pill ' + (/fail/i.test(x.state) ? 'err' : /install/i.test(x.state) && !/not/i.test(x.state) ? 'ok' : 'muted'), text: x.state })),
    el('td', { text: x.detail }), el('td', { class: 'chg', text: x.error, title: x.meaning ? `${x.meaning}\n\n${x.fix}` : '' }, x.meaning ? el('div', { class: 'muted small', text: x.meaning }) : ''), el('td', { text: x.version }), el('td', { text: x.lastSeen }))));
}

// ---------------------------------------------------------------- the list's columns and row height (kept in this browser)
(function listLook() {
  const menu = $('listLook'), btn = $('btnListLook'), grid = $('grid');
  let look = { hidden: [], density: 'comfortable' };
  try { look = { ...look, ...JSON.parse(localStorage.getItem('listLook') || '{}') }; } catch (e) { }
  const apply = () => {
    for (const c of [2, 3, 4, 5]) grid.classList.toggle('hide-' + c, look.hidden.includes(c));
    // The App ID column is off unless asked for (a list saved before it existed doesn't get it all of a sudden).
    grid.classList.toggle('hide-6', !look.showAppId);
    const idBox = menu.querySelector('[data-col="6"]'); if (idBox) idBox.checked = !!look.showAppId;
    grid.classList.toggle('dense', look.density === 'compact');
    for (const i of menu.querySelectorAll('[data-col]')) if (i.dataset.col !== '6') i.checked = !look.hidden.includes(+i.dataset.col);
    for (const i of menu.querySelectorAll('[name=density]')) i.checked = i.value === look.density;
  };
  const save = () => { try { localStorage.setItem('listLook', JSON.stringify(look)); } catch (e) { } apply(); };
  menu.addEventListener('change', e => {
    const t = e.target;
    if (t.dataset.col === '6') { look.showAppId = t.checked; save(); return; }
    if (t.dataset.col) look.hidden = t.checked ? look.hidden.filter(c => c !== +t.dataset.col) : [...look.hidden, +t.dataset.col];
    if (t.name === 'density') look.density = t.value;
    save();
  });
  const close = () => { menu.hidden = true; btn.setAttribute('aria-expanded', 'false'); };
  btn.addEventListener('click', e => {
    e.stopPropagation();
    if (!menu.hidden) { close(); return; }
    const r = btn.getBoundingClientRect();
    menu.hidden = false; btn.setAttribute('aria-expanded', 'true');
    menu.style.left = Math.max(8, Math.min(r.left, innerWidth - menu.offsetWidth - 8)) + 'px'; menu.style.top = (r.bottom + 4) + 'px';
    const first = menu.querySelector('input'); if (first) first.focus();
  });
  menu.addEventListener('click', e => e.stopPropagation());
  document.addEventListener('click', close);
  menu.addEventListener('keydown', e => { if (e.key === 'Escape') { e.stopPropagation(); close(); btn.focus(); } });
  menu.addEventListener('focusout', e => { if (!menu.contains(e.relatedTarget) && e.relatedTarget !== btn) close(); });
  addEventListener('scroll', e => { if (!menu.hidden && !menu.contains(e.target)) close(); }, true);
  apply();
})();

// The Version column: one clear answer to "which version do devices get?".
// Managed (pinned): the fixed version with a lock - and an arrow when winget has a newer one to release.
// The winget command: "newest" - devices get whatever winget has (its version today in grey); nothing to release.
const lockSvg = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>';
function versionCell(a) {
  const pilot = a.pilotVersion ? el('span', { class: 'pill warn newer', text: 'pilot ' + a.pilotVersion, title: `${a.pilotVersion} is released to the pilot groups. More > Promote version in pilot gives it to everyone.` }) : '';
  if (a.msHint && !a.wingetId) return [el('span', { class: 'muted', text: '-', title: a.msHint })];
  if (a.office && !a.wingetId) return [el('span', { class: 'muted', text: 'Microsoft 365', title: 'Microsoft updates it on its update channel - no version to set.' })];
  if (a.wingetId && isStoreId(a.wingetId)) return [el('span', { class: 'muted', text: 'Store', title: 'The Microsoft Store installs and updates it - no version to set.' })];
  // An own package watching a winget package (2.36.0): an arrow when winget has a newer one - Get new installer fetches it.
  const watched = !a.wingetId && a.watchWinget && a.newerOnWinget && !pilot ? el('span', { class: 'pill info newer', text: '→ ' + a.wingetVersion, title: `winget (${a.watchWinget}) has ${a.wingetVersion} - More > Get new installer puts it in its folder, then release it.` }) : '';
  if (!a.wingetId) return a.version ? [el('span', { class: 'vpin', title: `Its package installs ${a.version} - a new installer goes out with Release new version (managed) or Package + Send.` }, a.version), pilot, watched]
    : [el('span', { class: 'muted', text: 'not set', title: 'No App version yet. The editor shows the installer version in its package folder (Basics); Details > App version sets it.' })];
  if (a.managed) {
    if (!a.version) return [el('span', { class: 'vwarn', text: 'not pinned yet', title: a.hasAppId ? 'Managed updates, but no App version yet: Set version (winget\'s current one) - until then it installs the newest.' : "Managed updates need the version to pin before it can be sent to Intune: Set version (winget's current one)." })];
    const lock = el('span', { class: 'vlock' }); lock.innerHTML = lockSvg;
    return [el('span', { class: 'vpin', title: `Pinned: devices install exactly ${a.version}. A new version reaches them only when it's released (pilot first).` }, lock, a.version), pilot,
      !pilot && a.newerOnWinget ? el('span', { class: 'pill info newer', text: '→ ' + a.wingetVersion, title: `winget offers ${a.wingetVersion} - ${a.hasAppId ? 'Release new version sends it to the pilot groups first' : "Take winget's version pins it instead"}.` }) : ''];
  }
  return [el('span', { class: 'vnewest', title: `Not pinned: devices get whatever winget has when they install${a.wingetVersion ? ` (${a.wingetVersion} at the last check)` : ''}. Turn managed updates on to pin a version and release new ones to the pilot groups first.` }, 'newest',
    a.wingetVersion ? el('span', { class: 'muted vnow', text: ` · ${a.wingetVersion}` }) : '')];
}

// A "Pick..." list beside a version field: winget's versions, newest first (asked when it's opened, per Winget ID).
// A dropdown of its own - a browser's suggestion list filters by what's typed, so a filled field would offer only itself.
function verPicker(selId, inputId, wingetId) {
  const sel = $(selId); let loadedFor = '';
  const load = async () => {
    const id = wingetId(); if (!id || isStoreId(id) || loadedFor === id) return;
    loadedFor = id; sel.replaceChildren(el('option', { value: '', text: 'Asking winget...' }));
    const r = await api('/api/winget-versions', { id });
    if (!r.ok) { loadedFor = ''; sel.replaceChildren(el('option', { value: '', text: 'Pick...' }), el('option', { value: '', disabled: true, text: `winget: ${r.error}` })); return; }
    sel.replaceChildren(el('option', { value: '', text: 'Pick...' }), ...r.versions.slice(0, 60).map((v, i) => el('option', { value: v, text: i === 0 ? `${v} - newest` : v })));
  };
  sel.addEventListener('pointerdown', load); sel.addEventListener('focus', load);
  sel.addEventListener('change', () => { if (sel.value) { const f = $(inputId); f.value = sel.value; f.dispatchEvent(new Event('input', { bubbles: true })); } sel.value = ''; });
  return { reset: () => { loadedFor = ''; sel.replaceChildren(el('option', { value: '', text: 'Pick...' })); }, hide: on => { sel.hidden = on; } };
}
const appVerPick = verPicker('mAppVersionPick', 'mAppVersion', () => $('aWinget').value.trim());
const relVerPick = verPicker('relVersionPick', 'relVersion', () => { const a = apps.find(x => x.name === relName); return a && relInfo && relInfo.kind !== 'package' ? a.wingetId : ''; });
$('aWinget').addEventListener('input', () => { appVerPick.reset(); appVerPick.hide(!$('aWinget').value.trim() || isStoreId($('aWinget').value.trim())); });

// Publisher, owner and developer: the names the catalog already uses, to pick (typing a new one still works).
let catValuesAt = 0;
async function fillCatalogValues() {
  if (Date.now() - catValuesAt < 30000) return; catValuesAt = Date.now();
  const r = await api('/api/catalog-values'); if (!r.ok) return;
  for (const [list, vals] of [['pubList', r.publisher], ['ownerList', r.owner], ['devList', r.developer]]) $(list).replaceChildren(...vals.map(v => el('option', { value: v })));
}
for (const id of ['mPublisher', 'mOwner', 'mDeveloper', 'bPublisher', 'bOwner', 'bDeveloper', 'aiPublisher', 'asPublisher', 'apVendor']) $(id).addEventListener('focus', fillCatalogValues);

// App ID: picked, not typed - a typo would link the app to the wrong Intune app (or none).
function fillAppLink() {
  const sel = $('aAppLink'), cur = $('aAppId').value.trim();
  const known = typeof intuneOnly === 'function' ? intuneOnly().win : [];
  sel.replaceChildren(el('option', { value: '', text: cur ? 'Change...' : 'Link...' }),
    ...(cur ? [el('option', { value: '__unlink', text: 'Unlink (Send to Intune then creates a new app)' })] : []),
    ...(known.length ? [el('optgroup', { label: 'Windows apps in Intune the catalog doesn\'t manage' }, ...known.slice().sort((x, y) => x.name.localeCompare(y.name)).map(x => el('option', { value: x.id, text: x.name })))] : []),
    el('option', { value: '__type', text: 'Type or paste an App ID...' }));
}
$('aAppLink').addEventListener('focus', fillAppLink);
$('aAppLink').addEventListener('pointerdown', fillAppLink);
$('aAppLink').addEventListener('change', () => {
  const v = $('aAppLink').value, f = $('aAppId');
  if (v === '__unlink') f.value = '';
  else if (v === '__type') { f.readOnly = false; f.focus(); f.select(); }
  else if (v) f.value = v;
  $('aAppLink').value = '';
  f.dispatchEvent(new Event('input', { bubbles: true }));
});
$('aAppId').addEventListener('blur', () => { $('aAppId').readOnly = true; });

$('dlgRecent').addEventListener('wcrestore', () => openRecent());

// The header's checkbox: every app in this view, or none.
(function pickAllBox() {
  const th = document.querySelector('#grid th[data-sort="name"]');
  const cb = el('input', { type: 'checkbox', id: 'pickAll', class: 'rowpick', 'aria-label': 'Select every app in this view', title: 'Select every app in this view, or none',
    onclick: e => { e.stopPropagation(); const on = e.target.checked; for (const n of visible) { if (on) selected.add(n); else selected.delete(n); } syncSel(); updateActions(); } });
  th.prepend(cb);
})();

// Reload: the catalog, and Intune's App IDs and install state, read again.
$('btnAppsReload').addEventListener('click', async () => {
  const b = $('btnAppsReload'); b.disabled = true; b.classList.add('spin');
  try { await Promise.all([loadApps(), loadIntuneIds(true), loadState()]); toast('Read again.'); } finally { b.disabled = false; b.classList.remove('spin'); }
});

// Fill in details: the Intune fields still empty, from winget (and the owner from Settings) - the catalog only;
// for apps already in Intune, Changes to send then offers the send.
async function fillDetails(names) {
  const all = !names.length;
  if (all && !(await ask('Fill in the missing details of every Winget app?\n\nPublisher, description, information and privacy links and developer come from winget, the owner from Settings - only where a field is still empty. The App version is never changed. winget is asked once per app, which takes a moment.', { ok: 'Fill them in' }))) return;
  toast(`Asking winget about ${all ? 'every Winget app' : names.length + ' app(s)'}...`);
  const r = await api('/api/fill-details', { names });
  if (!r.ok) { toast(r.error, true); return; }
  await loadApps();
  const n = r.filled.length, sent = r.filled.filter(f => (apps.find(a => a.name === f.name) || {}).hasAppId).map(f => f.name);
  const msg = n ? `Filled in ${n} of ${r.asked} app(s): ${r.filled.slice(0, 4).map(f => `${f.name} (${f.fields.join(', ')})`).join('; ')}${n > 4 ? '; ...' : ''}.` : `Nothing to fill in - the ${r.asked} app(s) have their details already, or winget has none.`;
  const failed = r.failed.length ? ` Not asked or unknown to winget: ${r.failed.slice(0, 4).join('; ')}${r.failed.length > 4 ? '; ...' : ''}.` : '';
  // What winget's entries don't have - Home stops asking for it; it can still be typed in the editor.
  const lack = (r.lacking || []).length ? ` winget has no ${r.lacking.slice(0, 4).map(l => `${l.fields.join(', ')} for ${l.name}`).join('; ')}${r.lacking.length > 4 ? '; ...' : ''} - type ${r.lacking.length === 1 && r.lacking[0].fields.length === 1 ? 'it' : 'them'} in the editor if you want them.` : '';
  toast(msg + failed + lack + (sent.length ? ` ${sent.length} of them are in Intune - send their settings.` : ''), !!r.failed.length && !n,
    [n ? { label: 'Undo', run: () => undoLast() } : null, sent.length ? { label: 'Send settings', run: () => sendSettingsNow(sent) } : null]);
}

// The editor's Fill from winget: the empty Intune details filled from winget - into the form, saved with Save.
$('btnFillWinget').addEventListener('click', async () => {
  const b = $('btnFillWinget'), id = $('aWinget').value.trim();
  if (!id) return;
  b.disabled = true; const label = b.textContent; b.textContent = 'Asking winget...';
  try {
    const r = await api('/api/fill-preview', { id, name: $('aName').value.trim(), publisher: $('mPublisher').value, description: $('mDescription').value, informationUrl: $('mInformationUrl').value, privacyUrl: $('mPrivacyUrl').value, developer: $('mDeveloper').value, owner: $('mOwner').value });
    if (!r.ok) { toast(r.error, true); return; }
    const ids = { publisher: 'mPublisher', description: 'mDescription', informationUrl: 'mInformationUrl', privacyUrl: 'mPrivacyUrl', developer: 'mDeveloper', owner: 'mOwner' };
    const done = Object.entries(r.fill || {}).filter(([k]) => ids[k]).map(([k, v]) => { const f = $(ids[k]); f.value = v; f.dispatchEvent(new Event('input', { bubbles: true })); f.classList.add('justfilled'); setTimeout(() => f.classList.remove('justfilled'), 1600); return fieldLabelFor(k); });
    toast(done.length ? `Filled from winget: ${done.join(', ')} - Save keeps it.` : 'Nothing to fill - these fields have values already, or winget has none for them.');
  } finally { b.disabled = false; b.textContent = label; }
});
function fieldLabelFor(k) { return { publisher: 'publisher', description: 'description', informationUrl: 'information URL', privacyUrl: 'privacy URL', developer: 'developer', owner: 'owner' }[k] || k; }
// Shown for a Winget app only (the button needs an ID to ask winget about).
const fillBtnSync = () => { $('btnFillWinget').hidden = !$('aWinget').value.trim(); };
$('aWinget').addEventListener('input', fillBtnSync);
$('dlgApp').addEventListener('focusin', fillBtnSync);
// Batch edit brought back from the tray: a preview made before may be out of date (the apps changed meanwhile).
$('dlgBatch').addEventListener('wcrestore', () => { if (!$('batchPreview').hidden) batchReset(); });

// ---------------------------------------------------------------- product code: detection and uninstall
// An MSI app is found by its product code and removed by it. After an update (a new MSI) both must be the new one:
// detection on the old code says "not installed" for ever, an uninstall with the old one removes nothing. Not tied
// together silently (they can differ on purpose) - the editor says when they differ and offers either one.
const guidRx = /\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?/;
const normGuid = g => { const m = String(g || '').match(guidRx); return m ? '{' + m[0].replace(/[{}]/g, '').toUpperCase() + '}' : ''; };
function checkProductCodes() {
  const box = $('xPcNote'); if (!box) return;
  const det = $('xType').value === 'Msi' ? normGuid($('xProductCode').value) : '';
  const un = $('mUninstallCommand').value, inUn = /msiexec/i.test(un) ? normGuid(un) : '';
  const was = box.hidden;
  box.hidden = !(det && inUn && det !== inUn);
  // The checklist names it too (it is visible on every page of the editor).
  if (was !== box.hidden && typeof updateReady === 'function') setTimeout(updateReady, 0);
  if (box.hidden) return;
  $('xPcText').textContent = `The uninstall command removes ${inUn}, but detection looks for ${det}. After an MSI update both should be the new product code.`;
  $('btnPcToUninst').textContent = `Uninstall ${det}`; $('btnPcToUninst').title = `Put ${det} into the uninstall command too`;
  $('btnPcToDet').textContent = `Detect ${inUn}`; $('btnPcToDet').title = `Look for ${inUn} in the detection rule too`;
}
$('btnPcToUninst').addEventListener('click', () => {
  const f = $('mUninstallCommand'), det = normGuid($('xProductCode').value);
  f.value = f.value.replace(guidRx, det); f.dispatchEvent(new Event('input', { bubbles: true }));
  if (window.refreshBlocks) refreshBlocks();
  checkProductCodes();
});
$('btnPcToDet').addEventListener('click', () => {
  const f = $('xProductCode'); f.value = normGuid($('mUninstallCommand').value); f.dispatchEvent(new Event('input', { bubbles: true }));
  if (window.refreshDetectionBlocks) refreshDetectionBlocks();
  checkProductCodes();
});
$('appForm').addEventListener('input', checkProductCodes);
$('appForm').addEventListener('change', checkProductCodes);

// Duplicate an app (2.35.0): its settings and groups under a new name - not its App ID, releases or package files.
// Get new installer (2.36.0): winget's newest installer of the package it watches, SHA256-checked, into its folder - then the release.
async function fetchWatched(name) {
  toast(`Asking winget about ${name}'s newest installer...`);
  const c = await api('/api/watch-check', { name });
  if (!c.ok) { toast(c.error, true); return; }
  if (!c.newer) { toast(`winget's newest is ${c.latest} - ${c.folderVersion ? `the installer in the folder is ${c.folderVersion}` : `the app is ${c.current || 'on no version yet'}`}. Nothing newer to get.`); return; }
  if (!(await ask(`Get ${name}'s new installer?\n\nwinget has ${c.latest} (the app: ${c.current || 'no version'}${c.folderVersion ? `, its folder: ${c.folderVersion}` : ''}). It is downloaded from\n${c.url}\nand used only if it is an installer of the same type with the SHA256 winget gives${c.signerCheck ? ', signed by the same publisher as the one there' : " (its signature can't be checked here - Windows does that)"}${c.file ? ` - it replaces ${c.file}, so the commands still find it` : ''}.`, { ok: 'Get it' }))) return;
  toast(`Downloading ${c.latest}...`);
  const r = await api('/api/watch-fetch', { name });
  if (!r.ok) { toast(r.error, true); return; }
  await loadApps();
  if (r.managed) { toast(`${r.version} is in its folder (${r.file}) - release it to the pilot groups.`); openRelease(name); }
  else toast(`${r.version} is in its folder (${r.file}). Set the App version to ${r.version} (the editor), then build the package and send it.`, false, [{ label: 'Open it', run: () => openEditor(name) }]);
}
async function duplicateApp(name) {
  let n = 2; while (apps.some(a => a.name.toLowerCase() === `${name} (${n})`.toLowerCase())) n++;
  const newName = await ask(`Duplicate ${name}\n\nA new app with its settings and groups (commands, detection, requirements, return codes, icon). Not its App ID, releases or package files - it is new to Intune. The name of the new app:`, { ok: 'Duplicate', input: `${name} (${n})`, danger: false });
  if (!newName) return;
  const r = await api('/api/app-duplicate', { name, newName: String(newName).trim() });
  if (!r.ok) { toast(r.error, true); return; }
  await loadApps(); selected.clear(); selected.add(r.name); renderApps(); updateViewButtons();
  toast(`${r.name} is a copy of ${name} - change what differs.`, false, [{ label: 'Open it', run: () => openEditor(r.name) }]);
  openEditor(r.name);
}
