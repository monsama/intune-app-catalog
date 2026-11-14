// Intune App Catalog - web interface: the Catalog menu's tools and managed-update actions -
// replacing a group, CSV, winget's newest versions, setting up a tenant, install status of
// every app, release / promote / withdraw / roll back, apps worth adding. Loaded after apps.js.
'use strict';

// ---------------------------------------------------------------- replace a group (catalog only)
let replaceNames = [];
function openReplace({ names = [], old = '' }) {
  replaceNames = names;
  const pool = names.length ? apps.filter(a => names.includes(a.name)) : apps;
  const used = [...new Set(pool.flatMap(a => a.groups || []))].sort((a, b) => a.localeCompare(b));
  if (!used.length) { toast('None of these apps is assigned to a group.', true); return; }
  $('rpTitle').textContent = names.length ? `Replace a group on ${names.length} app${names.length === 1 ? '' : 's'}` : 'Replace a group';
  $('rpText').textContent = 'Every assignment to the old group - Required, Available, Uninstall and Excluded - names the new one instead, in the catalog. Entra ID isn\'t touched (Rename on the Groups page renames a group there). Send groups sends it to Intune.';
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
  if (r.deployed.length && await ask(`Send groups for the ${r.deployed.length} deployed app(s) now?\n\n${r.deployed.join('\n')}`, { ok: 'Send groups', danger: false })) openPushGroups(r.deployed);
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
  $('btnCsvGo').disabled = true; $('btnCsvGo').textContent = 'Apply'; $('btnCsvClose').textContent = 'Cancel';
  $('dlgCsv').showModal();
}
$('csvFile').addEventListener('change', async () => {
  const f = $('csvFile').files[0];
  $('csvErr').hidden = true; $('btnCsvGo').disabled = true; $('csvPreview').hidden = true;
  if (!f) return;
  if (f.size > 5 * 1024 * 1024) { $('csvErr').textContent = 'The file is too large for a catalog (over 5 MB).'; $('csvErr').hidden = false; return; }
  // UTF-8 (what Export writes); a file Excel re-saved in its default "CSV" (Windows-1252) is read as that instead of turning umlauts into �.
  const buf = await f.arrayBuffer();
  try { csvText = new TextDecoder('utf-8', { fatal: true }).decode(buf); } catch (e) { csvText = new TextDecoder('windows-1252').decode(buf); }
  $('csvName').textContent = 'Reading...';
  const r = await api('/api/csv-import', { text: csvText, preview: true });
  $('csvName').textContent = '';
  if (!r.ok) { $('csvErr').textContent = r.error; $('csvErr').hidden = false; return; }
  csvChanges = r.changes;
  const notes = [];
  $('csvNote').textContent = '';
  if (r.errors.length) notes.push('Fix these rows first: ' + r.errors.join('; '));
  if (r.notFound.length) notes.push(`Not in the catalog, skipped: ${r.notFound.join(', ')}.`);
  for (const w of r.warnings || []) notes.push(w);
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
  $('btnCsvClose').textContent = 'Close';
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
  if (grp.length && await ask(`Send groups for the ${grp.length} deployed app(s) whose groups changed?\n\n${grp.join('\n')}`, { ok: 'Send groups', danger: false })) { $('dlgCsv').close(); openPushGroups(grp); }
});

// ---------------------------------------------------------------- winget: newest versions
async function checkWingetVersions() {
  const n = apps.filter(a => a.wingetId).length;
  toast(`Asking winget about ${n} app(s) - about a second each...`);
  const r = await api('/api/checks-winget', {});
  if (!r.ok) { toast(r.error, true); return; }
  await loadApps();
  const newer = apps.filter(a => a.newerOnWinget).length;
  toast(newer ? `winget offers a newer version for ${newer} app(s) - showing them.` : 'No app has a newer version on winget than the catalog records.');
  if (newer) { $('filter').value = 'newer'; renderApps(); updateViewButtons(); }
}

// ---------------------------------------------------------------- set up this tenant
let tsData = null;
async function openTenantSetup() {
  if (!$('dlgTenantSetup').open) $('dlgTenantSetup').showModal();
  $('tsSteps').replaceChildren(el('li', { class: 'muted', text: 'Reading the tenant...' }));
  const r = await api('/api/tenant-setup');
  if (!r.ok) { $('tsSteps').replaceChildren(el('li', { class: 'formerror', text: r.error })); return; }
  tsData = r;
  const list = names => names.length ? el('details', {}, el('summary', { text: names.length > 1 ? `the ${names.length} apps` : names[0] }), el('p', { class: 'muted', text: names.join(', ') })) : '';
  const glist = names => names.length ? el('details', {}, el('summary', { text: `the ${names.length} group${names.length === 1 ? '' : 's'}` }), el('p', { class: 'muted', text: names.join(', ') })) : '';
  // state: 'todo', 'done', 'unknown' (couldn't be checked) or 'check' (always worth running, never "done").
  const step = (n, title, state, doneText, text, more, buttons) => {
    const isNext = n === firstTodo;
    return el('li', { class: 'ts ' + (state === 'todo' ? (isNext ? 'next' : 'todo') : state) },
      el('span', { class: 'tsmark', 'aria-hidden': 'true', text: state === 'done' ? '✓' : state === 'unknown' ? '?' : String(n) }),
      el('div', { class: 'tsbody' }, el('h3', {}, title, el('span', { class: 'sr', text: { todo: ' - to do', done: ' - done', unknown: ' - not checked', check: '' }[state] })),
        el('p', { class: 'sub', text: state === 'done' ? doneText : text }), state === 'done' ? '' : more),
      el('div', { class: 'tsact' }, ...(state === 'done' ? [] : buttons.map((b, k) => el('button', { class: 'btn' + (isNext && k === 0 ? ' primary' : ''), text: b[0], title: b[1], onclick: b[2] })))));
  };
  const ready = r.notDeployed.filter(n => !r.notReady.some(x => x.name === n));
  const states = [r.stale.length ? 'todo' : 'done', r.groupsNote ? 'unknown' : r.missingGroups.length ? 'todo' : 'done', r.notDeployed.length ? 'todo' : 'done', r.pushGroups.length ? 'check' : 'done'];
  const firstTodo = states.findIndex(x => x === 'todo') + 1;
  const reasons = r.notReady.length ? el('details', {}, el('summary', { text: `${r.notReady.length} not ready yet - why` }), el('ul', { class: 'tsreasons' }, ...r.notReady.map(x => el('li', {}, el('b', { text: x.name }), ' - ' + x.reason)))) : '';
  $('tsText').textContent = firstTodo ? `${r.apps} apps in the catalog. What the connected tenant still needs, in order - each step asks or previews before it changes anything.` : `The ${r.apps} apps are set up in this tenant${r.pushGroups.length ? ' - send groups any time to check the assignments' : ''}.`;
  $('tsSteps').replaceChildren(
    step(1, 'Clear App IDs from another tenant', states[0], 'No App ID points at an app this tenant doesn\'t have.',
      `${r.stale.length} app${r.stale.length === 1 ? ' has an App ID' : 's have App IDs'} this tenant doesn't know. Clearing them (catalog only, Undo works) lets them be deployed here; supersedence pointing at the old tenant's apps goes with them.`, list(r.stale),
      [[`Clear ${r.stale.length} App ID${r.stale.length === 1 ? '' : 's'}`, 'Clear these App IDs in the catalog - Intune isn\'t touched', async () => {
        if (!(await ask(`Clear ${r.stale.length} App ID(s) in the catalog?\n\nThey point at apps this tenant doesn't have. Settings, groups and packages stay. Undo takes it back.`, { ok: 'Clear App IDs', danger: false }))) return;
        const x = await api('/api/clear-appids', { names: r.stale }); toast(x.ok ? `Cleared ${x.cleared.length} App ID(s).` : x.error, !x.ok); await loadApps(); openTenantSetup();
      }]]),
    step(2, 'Create the groups in Entra ID', states[1], 'Every group the catalog assigns to exists in Entra ID.',
      r.groupsNote ? `Not checked - ${r.groupsNote}` : `${r.missingGroups.length} group${r.missingGroups.length === 1 ? '' : 's'} the apps are assigned to ${r.missingGroups.length === 1 ? "doesn't" : "don't"} exist yet. They are created empty - add members (or nested groups) on the Groups page afterwards, or the assignments still reach nobody.`, glist(r.missingGroups),
      r.groupsNote ? [['Check again', 'Read Entra ID again', () => openTenantSetup()]] : [
        [`Create ${r.missingGroups.length} group${r.missingGroups.length === 1 ? '' : 's'}`, 'Create them as empty security groups', () => createGroups(r.missingGroups, () => openTenantSetup())],
        ['Open Groups', 'The Groups page, showing the groups Entra ID doesn\'t have - to create them one by one and add members', () => { $('dlgTenantSetup').close(); showView('groups'); $('groupShow').value = 'missing'; if (groupsLoaded) renderGroupList(); }]]),
    step(3, 'Send the apps to Intune', states[2], 'Every app in the catalog is in Intune.',
      `${r.notDeployed.length} app${r.notDeployed.length === 1 ? ' isn\'t' : 's aren\'t'} in Intune yet - ${ready.length} ready to deploy${r.notReady.length ? `, ${r.notReady.length} not ready` : ''}. Send to Intune runs them in dependency order.${r.sharedMissing ? ' The shared Winget package isn\'t built yet: Settings > Packaging & folders builds it - every Winget app needs it.' : ''}`,
      el('div', {}, list(r.notDeployed), reasons),
      [[`Send ${ready.length} app${ready.length === 1 ? '' : 's'}...`, 'Opens Send to Intune for the apps that are ready - nothing starts until you confirm there', () => openDeploy(ready.length ? ready : r.notDeployed)],
        ...(r.sharedMissing ? [['Open Packaging', 'Settings > Packaging & folders: download the packaging tool and build the shared Winget package', () => { $('dlgTenantSetup').close(); showSettings('packaging'); }]] : [])]),
    step(4, 'Push the groups', states[3], 'No deployed app has groups to push.',
      `${r.pushGroups.length} deployed app${r.pushGroups.length === 1 ? ' has' : 's have'} groups in the catalog. Deploys push them already (Settings > Apps & defaults); Send groups compares the catalog with Intune and shows what would change - "nothing to change" means it's done.`, list(r.pushGroups),
      [['Send groups...', 'Compare the catalog\'s groups with Intune, then apply', () => openPushGroups(r.pushGroups)]]));
}
$('btnTsRefresh').addEventListener('click', openTenantSetup);
$('btnTenantSetup').addEventListener('click', openTenantSetup);
for (const d of ['dlgDeploy', 'dlgPush', 'dlgRun']) $(d).addEventListener('close', () => { if ($('dlgTenantSetup').open) openTenantSetup(); });

// ---------------------------------------------------------------- install status of every app
let ovRows = [];
async function openOverview() {
  if (!$('dlgOverview').open) $('dlgOverview').showModal();
  skeleton($('ovRows'), 8, 5);
  const r = await api('/api/install-overview');
  if (!r.ok) { $('ovRows').replaceChildren(el('tr', {}, el('td', { colspan: 8, class: 'formerror', text: r.error }))); return; }
  ovRows = r.rows.sort((a, b) => b.failed - a.failed || b.pending - a.pending || a.name.localeCompare(b.name));
  const tot = k => ovRows.reduce((n, x) => n + x[k], 0);
  $('ovNote').textContent = `${ovRows.length} deployed apps, read at ${r.at}: ${tot('installed')} installed, ${tot('failed')} failed, ${tot('pending')} pending (devices).${r.note ? ' ' + r.note : ''}`;
  renderOverview();
}
function renderOverview() {
  const q = $('ovFilter').value.trim().toLowerCase(), failedOnly = $('ovFailedOnly').checked;
  const rows = ovRows.filter(x => (!q || x.name.toLowerCase().includes(q)) && (!failedOnly || x.failed > 0));
  $('ovCount').textContent = `${rows.length} of ${ovRows.length}`;
  const num = (v, cls) => el('td', { class: 'num' + (v && cls ? ' ' + cls : ''), text: String(v) });
  $('ovRows').replaceChildren(...(rows.length ? rows.map(x => {
    const all = x.installed + x.failed + x.pending + x.notInstalled;
    // Widths through the DOM: the page's CSP refuses style attributes.
    const seg = (v, cls) => { if (!all || !v) return ''; const s = el('span', { class: cls }); s.style.width = (100 * v / all).toFixed(1) + '%'; return s; };
    return el('tr', {}, el('td', { class: 'name', text: x.name }),
      ...(x.known ? [num(x.installed, 'ok'), num(x.failed, 'err'), num(x.pending, 'info'), num(x.notInstalled), num(x.notApplicable)]
        : [el('td', { colspan: 5, class: 'muted', text: 'Intune had no counts for this app.' })]),
      el('td', {}, x.known && all ? el('span', { class: 'ovbar', title: `${x.installed} installed, ${x.failed} failed, ${x.pending} pending, ${x.notInstalled} not installed` }, seg(x.installed, 'ok'), seg(x.failed, 'err'), seg(x.pending, 'info'), seg(x.notInstalled, 'none')) : ''),
      el('td', { class: 'act' }, el('button', { class: 'btn small', text: 'Devices...', title: 'Every device\'s state for this app', onclick: () => openStatus(x.name) })));
  }) : [el('tr', {}, el('td', { colspan: 8, class: 'muted', text: ovRows.length ? 'No app matches.' : 'No deployed app.' }))]));
}
$('ovFilter').addEventListener('input', renderOverview);
$('ovFailedOnly').addEventListener('change', renderOverview);
$('btnOvRefresh').addEventListener('click', openOverview);

// ---------------------------------------------------------------- managed updates: release, promote, withdraw
let relName = '', relInfo = null;
async function openRelease(name) {
  const r = await api('/api/release-info', { name });
  if (!r.ok) { toast(r.error, true); return; }
  relName = name; relInfo = r;
  const pkg = r.kind === 'package', inst = r.installer || {};
  $('relTitle').textContent = `Release a new version of ${name}`;
  $('relText').textContent = `Now: ${r.current || '(no version)'} for everyone.${pkg ? (inst.found ? ` The installer in its folder is ${inst.file}${inst.version ? ', version ' + inst.version : ''}.` : ` Put the new installer in ${inst.folder} first.`) : (r.latest ? ` winget offers ${r.latest}.` : ' Catalog > Check winget for new versions finds the newest.')} The new version becomes its own app in Intune ("${name} <version> (pilot)") that updates devices which have ${r.current || 'the current one'}, assigned Required to the pilot groups only. Promote gives it to everyone; Withdraw takes it back.${pkg ? ' Its detection rule is set to the new version' + (inst.productCode ? ' and the MSI\'s product code' : '') + '.' : ''}`;
  const suggest = pkg ? inst.version : r.latest;
  $('relVersion').value = suggest && suggest !== r.current ? suggest : '';
  $('relBuildRow').hidden = !pkg; $('relFolder').textContent = pkg ? `(${inst.folder})` : '';
  $('relProblem').textContent = r.detectionProblem || ''; $('relProblem').hidden = !r.detectionProblem;
  $('relGroups').textContent = r.pilotGroups.length ? `Pilot groups: ${r.pilotGroups.join(', ')}.${(r.rings || []).length > 1 ? ` Then ${r.rings.slice(1).map(x => x.name).join(', then ')}, then everyone.` : ''}` : 'No pilot groups yet - set them in Settings > Updates.';
  $('relFast').checked = false; $('relFastNote').textContent = `(pilot for ${r.fastTrackHours || 4} hours, then everyone)`;
  $('relErr').hidden = true; $('relLog').hidden = true; $('relLog').textContent = '';
  $('btnRelGo').disabled = !r.pilotGroups.length || !!r.detectionProblem; $('btnRelGo').textContent = 'Release to pilot'; $('btnRelClose').textContent = 'Cancel';
  $('dlgRelease').showModal(); $('relVersion').focus();
}
// Runs one release step as a job and resolves with its outcome (like deployOne).
function releaseStep(body, path, log, startText) {
  return new Promise(resolve => {
    runJob(body, (ok, result, after) => resolve({ ok, error: result && result.error, after }), { path, log, startText }).then(started => { if (!started) resolve({ ok: false, error: 'another action was still running' }); });
  });
}
$('btnRelGo').addEventListener('click', async () => {
  const version = $('relVersion').value.trim(), name = relName;
  if (!version) { $('relErr').textContent = 'Type the version to release.'; $('relErr').hidden = false; return; }
  $('relErr').hidden = true; $('relLog').hidden = false; $('btnRelGo').disabled = true;
  if (relInfo && relInfo.kind === 'package' && $('relBuild').checked) {
    const built = await releaseStep({ names: [name] }, '/api/package-start', 'relLog', `Building ${name}'s package...`);
    if (!built.ok) { $('relErr').textContent = built.error || 'Building the package failed - see the log.'; $('relErr').hidden = false; $('btnRelGo').disabled = false; return; }
  }
  const productCode = relInfo && relInfo.kind === 'package' && relInfo.installer ? relInfo.installer.productCode || '' : '';
  const made = await releaseStep({ name, version, productCode, fastTrack: $('relFast').checked }, '/api/release-start', 'relLog', `Creating ${name} ${version} in Intune...`);
  if (!made.ok) { $('relErr').textContent = made.error || 'The release failed - see the log.'; $('relErr').hidden = false; $('btnRelGo').disabled = false; loadApps(); return; }
  const assigned = await releaseStep({ name, step: 'pilot' }, '/api/release-assign', 'relLog', 'Assigning it to the pilot groups...');
  $('btnRelClose').textContent = 'Close'; $('btnRelGo').textContent = 'Done';
  toast(assigned.ok ? `${name} ${version} is released to the pilot groups.` : `${name} ${version} is in Intune, but assigning it to pilot failed - Release again isn't needed: use Promote or Withdraw.`, !assigned.ok);
  loadApps();
});
async function promoteRelease(name) {
  const a = apps.find(x => x.name === name);
  const info = await api('/api/release-info', { name });
  const st = info.ok && info.pilotStatus;
  const verdict = st && st.ok ? `Pilot: ${st.reason}${st.action === 'promote' ? ' The release rule says it is ready.' : st.action === 'advance' ? ' The release rule says it is ready for the next ring - promoting now skips the remaining rings.' : st.action === 'hold' ? ' The release rule says: hold.' : ' The release rule says: wait.'}\n\n` : '';
  if (!(await ask(`Promote ${name} ${a.pilotVersion} to everyone?\n\n${verdict}The version in pilot gets the catalog's groups and becomes the current one (named "${name}" in Intune); ${a.version || 'the current version'} loses its assignments and is kept in Intune as superseded. Devices that have it are updated to ${a.pilotVersion}.\n\nCheck its install status on the pilot devices first (More > Install status...).`, { ok: 'Promote', danger: false }))) return;
  runDialog(`Promote ${name} ${a.pilotVersion}`, 'Assigning the new release to the catalog\'s groups, then taking them off the old one.');
  const p1 = await releaseStep({ name, step: 'promote' }, '/api/release-assign', 'runLog', `Assigning ${a.pilotVersion} to the catalog's groups...`);
  if (!p1.ok) { toast(`Promoting failed - nothing else was changed. ${p1.error || ''}`, true); return; }
  const p2 = await releaseStep({ name, step: 'retire' }, '/api/release-assign', 'runLog', `Taking the groups off ${a.version || 'the old release'}...`);
  const r = await api('/api/release-promoted', { name });
  toast(r.ok ? `${name} ${r.version} is the current release for everyone.${p2.ok ? '' : ' The old release still has its assignments - remove them in Intune.'}${(r.notes || []).length ? ' ' + r.notes.join(' ') : ''}` : r.error, !r.ok || !p2.ok);
  loadApps();
}
async function withdrawRelease(name) {
  const a = apps.find(x => x.name === name);
  if (!(await ask(`Withdraw ${name} ${a.pilotVersion}?\n\nIts app is deleted from Intune. Pilot devices that installed it keep ${a.pilotVersion} (an uninstall isn't sent); everyone else stays on ${a.version || 'the current version'}.`, { ok: 'Withdraw', danger: true }))) return;
  runDialog(`Withdraw ${name} ${a.pilotVersion}`, '');
  const w = await releaseStep({ name, step: 'withdraw' }, '/api/release-assign', 'runLog', 'Taking it off the pilot groups...');
  if (!w.ok) { toast(`Withdrawing failed. ${w.error || ''}`, true); return; }
  const r = await api('/api/release-withdrawn', { name });
  toast(r.ok ? (r.deleted ? `${name} ${a.pilotVersion} withdrawn and deleted from Intune.` : `${name} ${a.pilotVersion} withdrawn, but not deleted from Intune: ${r.error}`) : r.error, !r.ok || !r.deleted);
  loadApps();
}

async function rollbackRelease(name) {
  const a = apps.find(x => x.name === name), back = (a.previousVersions || []).slice(-1)[0];
  if (!(await ask(`Roll ${name} back to ${back}?\n\nThe catalog's groups go back to ${back}, and ${a.version || 'the current version'} loses them (it stays in Intune as superseded). Devices that already have ${a.version || 'the newer version'} keep it - nothing is uninstalled; devices that don't have it yet get ${back}.`, { ok: 'Roll back', danger: false }))) return;
  runDialog(`Roll ${name} back to ${back}`, '');
  const r1 = await releaseStep({ name, step: 'rollback' }, '/api/release-assign', 'runLog', `Assigning ${back} to the catalog's groups...`);
  if (!r1.ok) { toast(`Rolling back failed - nothing else was changed. ${r1.error || ''}`, true); return; }
  const r2 = await releaseStep({ name, step: 'retire' }, '/api/release-assign', 'runLog', `Taking the groups off ${a.version || 'the current release'}...`);
  const r = await api('/api/release-rolledback', { name });
  toast(r.ok ? `${name} is back on ${r.version}.${r2.ok ? '' : ' The newer release still has its assignments - remove them in Intune.'}${(r.notes || []).length ? ' ' + r.notes.join(' ') : ''}` : r.error, !r.ok || !r2.ok);
  loadApps();
}

// ---------------------------------------------------------------- apps worth adding (Intune's inventory)
async function openSuggest() {
  if (!$('dlgSuggest').open) $('dlgSuggest').showModal();
  $('sgRows').replaceChildren(el('tr', {}, el('td', { colspan: 4, class: 'muted', text: 'Reading the inventory of apps on devices...' })));
  const r = await api('/api/inventory-suggestions');
  if (!r.ok) { $('sgRows').replaceChildren(el('tr', {}, el('td', { colspan: 4, class: 'muted', text: r.error }))); return; }
  $('sgNote').textContent = `${r.suggestions.length} app(s) on at least three devices that the catalog doesn't have, from ${r.scanned} inventory entries${r.more ? ' (the first 20 pages)' : ''}. Parts of Windows and drivers are left out.`;
  $('sgRows').replaceChildren(...(r.suggestions.length ? r.suggestions.map(s => el('tr', {},
    el('td', { class: 'name', text: s.name }), el('td', { class: 'num', text: String(s.devices) }), el('td', { class: 'mono', text: s.versions.join(', ') }),
    el('td', { class: 'act' }, el('button', { class: 'btn small', text: 'Add...', title: `Add ${s.name} to the catalog - winget is searched for it`, onclick: () => addSuggested(s.name) }))))
    : [el('tr', {}, el('td', { colspan: 4, class: 'muted', text: 'Nothing to suggest - every app on several devices is in the catalog.' }))]));
}
async function addSuggested(name) {
  $('dlgSuggest').close();
  await openEditor('');
  $('aName').value = name;
  $('btnFindWinget').click();
}
$('btnSgRefresh').addEventListener('click', openSuggest);
