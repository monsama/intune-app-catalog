// Intune App Catalog - web interface: the Apps list, the app editor and its deploy settings, Deploy, Push groups, Batch edit and the More menu.
// Loaded after core.js (shared helpers and state); app.js starts the page.
'use strict';

// ---------------------------------------------------------------- apps
let apps = [], sortKey = 'name', sortDesc = false, lastClicked = null;
const selected = new Set();
let visible = [];

// What each status means and what to do about it, for the pill's tooltip.
const statusHelp = {
  'Deployed': 'In Intune - the catalog has its App ID.',
  'No App ID': 'Not in Intune yet, and no settings of its own: Deploy uses the default values. If it is already in Intune, Checks offers to link it.',
  'Metadata saved - ready to deploy': 'Not in Intune yet. Its own settings are saved - Deploy creates it with them.',
  'Package missing': 'Its .intunewin isn\'t in the packages folder - More > Package builds it, or Settings > Packaging for Winget apps.',
  'Custom package': 'Has a Winget ID but deploys its own .intunewin instead of the shared Winget package.',
};
function statusPill(row) {
  const s = row.status || '';
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
  const why = {
    package: 'Winget apps use the shared package (Settings > Packaging).', pull: 'Only for apps already in Intune (with an App ID).',
    pushsettings: 'Only for apps already in Intune (with an App ID).', status: one ? 'This app isn\'t in Intune yet.' : 'Select exactly one app that is in Intune.',
    batchedit: 'Select one or more apps first.', addgroups: 'Select one or more apps first.', removegroups: 'Select one or more apps first.',
    copyid: one ? 'This app has no App ID yet.' : 'Select exactly one app.', clearid: one ? 'This app has no App ID.' : 'Select exactly one app.',
    delete: 'None of the selected apps is in Intune.', remove: 'Select exactly one app.',
  };
  for (const b of menu.querySelectorAll('button')) setEnabled(b, !!enable[b.dataset.act], why[b.dataset.act]);
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
