// Intune App Catalog - web interface: finding the way. Each app's stage and next step, the
// side panel, "Ready to deploy?" in the editor, getting started, the "?" explanations, the
// release timeline, and the job tray. Loaded last but one (before app.js starts the page).
'use strict';

// ---------------------------------------------------------------- an app's stage and its next step
const onApp = (a, act) => { selected.clear(); selected.add(a.name); lastClicked = a.name; renderApps(); menuAction(act); };
async function takeVersionFor(a) {
  toast(`Asking winget for ${a.name}'s current version...`);
  const w = await api('/api/checks-winget', {});
  if (!w.ok) { toast(w.error, true); return; }
  const r = await api('/api/winget-take-version', { names: [a.name] });
  await loadApps();
  toast(r.ok && r.changed.length ? `${a.name} starts from ${(apps.find(x => x.name === a.name) || {}).version}.` : (r.error || (r.skipped || []).join('; ') || 'winget had no version for it.'), !(r.ok && r.changed.length),
    r.ok && r.changed.length ? [{ label: 'Send to Intune', run: () => openDeploy([a.name]) }] : []);
}
function stageOf(a) {
  const own = !a.wingetId;
  if (tenantState(a) === 'missing') return { key: 'tenant', label: 'Other tenant', cls: 'warn', why: 'Its App ID belongs to another tenant - copied catalog?', next: { label: 'Clear App ID', title: 'Forget the link, so Send to Intune creates it in this tenant', run: () => onApp(a, 'clearid') } };
  if (/issue|Check failed/.test(a.audit || '')) return { key: 'look', label: 'Needs a look', cls: 'warn', why: 'Intune differs from the catalog (last check).', next: { label: 'Checks', title: 'See what differs and fix it', run: () => showView('checks') } };
  if (own && a.packageMissing) return { key: 'draft', label: 'Draft', cls: 'muted', why: 'Its installer isn\'t packaged yet.', next: { label: 'Build', title: 'Build the .intunewin from its packages folder', run: () => onApp(a, 'package') } };
  if (needsAttention(a)) return { key: 'look', label: 'Needs a look', cls: 'warn', why: (a.status || '').split('; ').map(p => statusLabel[p] || p).join('; '), next: { label: 'Edit', title: 'Open it in the editor', run: () => openEditor(a.name) } };
  if (!a.hasAppId) {
    if (a.managed && !own && !a.version) return { key: 'draft', label: 'Draft', cls: 'muted', why: 'Managed updates: it needs the version to start from.', next: { label: 'Set version', title: "Take winget's current version", run: () => takeVersionFor(a) } };
    return { key: 'ready', label: 'Ready to send', cls: 'info', why: 'Everything is set - not in Intune yet.', next: { label: 'Send to Intune', title: 'Create it in Intune', run: () => openDeploy([a.name]) } };
  }
  if (a.pilotVersion) return { key: 'pilot', label: `In pilot ${a.pilotVersion}`, cls: 'warn', why: `${a.pilotVersion} is with the pilot groups; everyone else has ${a.version || 'the current version'}.`, next: { label: 'Promote...', title: 'Give it to everyone (shows how the pilot went first)', run: () => promoteRelease(a.name) } };
  if (a.managed && a.newerOnWinget) return { key: 'everyone', label: 'Everyone', cls: 'ok', why: `winget has ${a.wingetVersion}.`, next: { label: 'Release...', title: `Release ${a.wingetVersion} to the pilot groups first`, run: () => openRelease(a.name) } };
  return { key: 'everyone', label: a.managed ? 'Everyone' : 'In Intune', cls: 'ok', why: a.managed ? `Everyone gets ${a.version || 'it'}; new versions go to the pilot groups first.` : 'In Intune, installing winget\'s latest (no managed updates).' };
}
function stageCell(a) {
  const s = stageOf(a);
  const pill = el('span', { class: 'pill ' + s.cls, text: s.label, title: [s.why, a.status ? 'Status: ' + a.status : ''].filter(Boolean).join('\n') });
  if (!s.next) return pill;
  return el('span', { class: 'stage' }, pill, el('button', { class: 'btn small next', text: s.next.label, title: s.next.title, onclick: e => { e.stopPropagation(); s.next.run(); } }));
}

// ---------------------------------------------------------------- the toolbar's next step, and the side panel
let panelSeq = 0, panelTimer = 0;
function updatePanel() {
  const sel = [...selected].map(n => apps.find(a => a.name === n)).filter(Boolean);
  const b = $('btnNext');
  if (sel.length === 1 && stageOf(sel[0]).next) { const s = stageOf(sel[0]); b.hidden = false; b.textContent = s.next.label; b.title = s.next.title; b.onclick = () => s.next.run(); }
  else if (sel.length > 1 && sel.every(a => stageOf(a).key === 'ready')) { b.hidden = false; b.textContent = `Send ${sel.length} apps`; b.title = 'All of them are ready to deploy'; b.onclick = () => openDeploy(sel.map(a => a.name)); }
  else b.hidden = true;
  const p = $('appPanel');
  if (sel.length !== 1) { p.hidden = true; return; }
  clearTimeout(panelTimer); panelTimer = setTimeout(() => fillPanel(sel[0]), 120);
}
async function fillPanel(a) {
  const seq = ++panelSeq, p = $('appPanel'), s = stageOf(a);
  const r = await api('/api/app-get', { name: a.name });
  if (seq !== panelSeq) return;
  const app = r.ok ? r.app : {};
  const fact = (k, v) => v ? el('div', { class: 'kv' }, el('span', { class: 'k', text: k }), el('span', { text: v })) : '';
  // Quick edits right here: a group added or taken off, the version - saved at once (the editor isn't needed).
  const quick = async body => { const x = await api('/api/app-quick', { name: a.name, ...body }); if (!x.ok) { toast(x.error, true); return false; } toast('Saved.'); await loadApps(); return true; };
  const inline = (btn, label, value, save) => {
    const inp = el('input', { class: 'qedit', value: value || '', 'aria-label': label, placeholder: label, list: 'qGroupList',
      onkeydown: async e => { if (e.key === 'Enter') { e.preventDefault(); if (await save(inp.value.trim())) return; } else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); inp.replaceWith(btn); btn.focus(); } } });
    inp.addEventListener('blur', () => setTimeout(() => { if (inp.isConnected && !inp.value.trim()) inp.replaceWith(btn); }, 150));
    btn.replaceWith(inp); inp.focus(); inp.select();
  };
  const groups = (k, field, list, always) => (list || []).length || always ? el('div', { class: 'kv' }, el('span', { class: 'k', text: k }), el('span', { class: 'gedit' },
    ...(list || []).map(g => el('span', { class: 'chip static editable' }, g, el('button', { type: 'button', class: 'x', text: '×', 'aria-label': `Take ${g} off ${k}`, title: `Take ${g} off ${k}`, onclick: () => quick({ field, remove: g }) }))),
    (() => { const b = el('button', { type: 'button', class: 'chip addchip', text: '+ Add', 'aria-label': `Add a group to ${k}`, title: `Add a group to ${k}`, onclick: () => inline(b, `Group for ${k}`, '', v => v ? quick({ field, add: v }) : false) }); return b; })())) : '';
  const known = [...new Set(apps.flatMap(x => x.groups || []))].sort();
  const btn = (text, title, run, primary) => el('button', { class: 'btn small' + (primary ? ' primary' : ''), text, title, onclick: run });
  const pilot = (app.releases || []).find(x => x.state === 'pilot');
  p.replaceChildren(
    el('div', { class: 'phead' }, iconFor(a), el('h2', { text: a.name }), el('button', { class: 'btn small ghost', text: 'Close', title: 'Close this panel', onclick: () => { selected.clear(); renderApps(); } })),
    el('div', { class: 'pstage' }, el('span', { class: 'pill ' + s.cls, text: s.label }), el('span', { class: 'muted', text: ' ' + (s.why || '') })),
    s.next ? el('div', { class: 'pnext' }, btn(s.next.label, s.next.title, s.next.run, true), el('span', { class: 'muted', text: 'Next step' })) : '',
    app.managedUpdates ? releaseTimeline(pilot ? pilot.ring : (a.hasAppId ? 99 : -1), !!(pilot && pilot.fastTrack)) : '',
    el('div', { class: 'pfacts' },
      (() => {
        const text = [a.version || '(none)', a.pilotVersion ? `pilot ${a.pilotVersion}` : '', a.newerOnWinget ? `winget has ${a.wingetVersion}` : '', (a.previousVersions || []).length ? `kept: ${a.previousVersions.join(', ')}` : ''].filter(Boolean).join(' - ');
        const canEdit = app.hasMetadata && !(app.managedUpdates && a.hasAppId);
        const b = canEdit ? el('button', { type: 'button', class: 'btn small ghost', text: 'Change', 'aria-label': 'Change the version', title: 'Change the App version here', onclick: () => inline(b, 'App version', a.version, v => quick({ field: 'appVersion', value: v })) }) : '';
        return el('div', { class: 'kv' }, el('span', { class: 'k', text: 'Version' }), el('span', {}, text, ' ', b));
      })(),
      fact('Source', a.wingetId ? `winget: ${a.wingetId}` : 'its own installer (Packages folder)'),
      fact('Updates', app.managedUpdates ? 'managed - pilot first' : 'winget\'s latest, untested'),
      fact('In Intune', a.hasAppId ? (a.type || 'yes') : 'not yet'),
      groups('Required', 'requiredFor', app.requiredFor, true), groups('Available', 'availableFor', app.availableFor, true), groups('Uninstall', 'uninstallFor', app.uninstallFor), groups('Excluded', 'excludeFor', app.excludeFor),
      el('datalist', { id: 'qGroupList' }, ...known.map(g => el('option', { value: g }))),
      fact('Last check', a.audit)),
    el('div', { class: 'pacts' }, btn('Edit', 'Open it in the editor', () => openEditor(a.name)),
      a.hasAppId ? btn('Install status', 'Every device\'s install state', () => openStatus(a.name)) : '',
      !a.wingetId ? btn('Test in Sandbox', 'Install, detect and uninstall it in Windows Sandbox', () => openSandbox(a.name)) : '',
      btn('More...', 'Every action for this app', () => $('btnMore').click())));
  p.hidden = false;
}

// ---------------------------------------------------------------- the release timeline: Pilot > rings > Everyone
function releaseTimeline(current, fast, rings) {
  const names = rings || ['Pilot', ...((prefs && prefs.releaseRings) || []).map(r => r.name)];
  const all = fast ? ['Pilot (fast track)', 'Everyone'] : [...names, 'Everyone'];
  const at = current >= 99 ? all.length - 1 : fast && current >= 0 ? 0 : current;
  return el('ol', { class: 'timeline', 'aria-label': 'Release stages' }, ...all.map((n, i) => el('li', { class: i < at ? 'done' : i === at ? 'now' : '', 'aria-current': i === at ? 'step' : null, text: n })));
}

// ---------------------------------------------------------------- "Ready to deploy?" in the editor
function updateReady() {
  if (!$('dlgApp').open && !$('readyList')) return;
  const wid = $('aWinget').value.trim(), own = !wid, row = apps.find(a => a.name === editingName);
  const groups = ['gRequired', 'gAvailable'].some(id => $(id).value.trim());
  const det = $('xType').value;
  const items = [
    [!!$('aName').value.trim(), 'A name', 'aName'],
    own ? [!!(row && !row.packageMissing), row && !row.packageMissing ? 'Its installer is packaged' : 'Its installer packaged (Packages\\<name>, then Package)', null]
      : [true, `Installs from winget (${wid})`, 'aWinget'],
    own ? [!!$('mInstallCommand').value.trim(), 'An install command', 'mInstallCommand'] : [true, 'Install command - made for winget', null],
    own ? [!!det, det ? 'A detection rule' : 'A detection rule (Deploy settings)', 'xType'] : [true, 'Detection - made for winget', null],
    $('aManaged').checked ? [!!$('mAppVersion').value.trim(), 'A version (managed updates install exactly it)', 'mAppVersion'] : null,
    [groups, groups ? 'Groups that get it' : 'Groups that get it - none yet, so nobody gets it', 'gRequired'],
  ].filter(Boolean);
  const done = items.filter(i => i[0]).length;
  $('readyBox').querySelector('h3').textContent = done === items.length ? 'Ready to send to Intune' : `Ready to send? ${done} of ${items.length}`;
  $('readyBox').classList.toggle('allok', done === items.length);
  $('readyList').replaceChildren(...items.map(([ok, text, field]) => el('li', { class: ok ? 'ok' : 'todo' },
    el('span', { class: 'mark', 'aria-hidden': 'true', text: ok ? '✓' : '!' }),
    field && !ok ? el('button', { type: 'button', class: 'linkish', text, title: 'Go to the field', onclick: () => { edPageFor($(field)); $(field).focus(); } }) : el('span', { text: (ok ? '' : 'Missing: ') + text }))));
}
$('appForm').addEventListener('input', () => updateReady());
$('appForm').addEventListener('change', () => updateReady());

// ---------------------------------------------------------------- the "?" explanations
const glossary = {
  managed: 'Managed updates: the app installs one fixed version. A new version goes to the pilot groups first (a new Intune app that updates the old one), and to everyone once it works there - nothing changes on devices without you, or the nightly run, saying so.',
  detection: 'The detection rule is how Intune tells the app is installed: an MSI product code, a file or registry value (by version, best), or a script. Without one Intune can\'t report or update the app.',
  assignments: 'Required: installed by itself on these groups\' devices. Available: offered in the Company Portal to install. Uninstall: removed from these devices. Excluded: never gets it, whatever the other lists say.',
  rings: 'Release rings: groups a new version reaches one after another - the pilot groups, then each ring, then everyone - each after the release rule says the last one went well.',
  fasttrack: 'Fast track: for a security fix. The new version is judged after a few hours instead of days, skips the rings and goes to everyone once the pilot devices are fine.',
  supersedence: 'Supersedence: this app replaces older Intune apps - as an update (devices that have the old one get this one) or by uninstalling the old one first.',
};
const helpPop = el('div', { class: 'helppop', role: 'note', hidden: true });
document.body.append(helpPop);
let helpFor = null;
document.addEventListener('click', e => {
  const b = e.target.closest('button.help');
  if (!b) { if (!e.target.closest('.helppop')) { helpPop.hidden = true; if (helpFor) helpFor.setAttribute('aria-expanded', 'false'); helpFor = null; } return; }
  e.preventDefault(); e.stopPropagation();
  if (helpFor === b) { helpPop.hidden = true; b.setAttribute('aria-expanded', 'false'); helpFor = null; return; }
  const host = b.closest('dialog[open]') || document.body;
  if (helpPop.parentElement !== host) host.append(helpPop);
  helpPop.textContent = glossary[b.dataset.help] || '';
  const r = b.getBoundingClientRect(), hr = host === document.body ? { left: 0, top: 0 } : host.getBoundingClientRect();
  helpPop.style.left = Math.max(8, Math.min(r.left - hr.left, (host === document.body ? innerWidth : hr.width) - 340)) + (host === document.body ? scrollX : host.scrollLeft) + 'px';
  helpPop.style.top = (r.bottom - hr.top + 6 + (host === document.body ? scrollY : host.scrollTop)) + 'px';
  helpPop.hidden = false; if (helpFor) helpFor.setAttribute('aria-expanded', 'false'); helpFor = b; b.setAttribute('aria-expanded', 'true');
}, true);
document.addEventListener('keydown', e => { if (e.key === 'Escape' && !helpPop.hidden) { helpPop.hidden = true; if (helpFor) { helpFor.setAttribute('aria-expanded', 'false'); helpFor.focus(); } helpFor = null; e.stopPropagation(); } }, true);
for (const b of document.querySelectorAll('button.help')) b.setAttribute('aria-expanded', 'false');

// ---------------------------------------------------------------- the job tray
$('btnRunHide').addEventListener('click', () => $('dlgRun').close());
$('jobChip').addEventListener('click', () => { if (!$('dlgRun').open) $('dlgRun').show(); });
$('dlgRun').addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); $('dlgRun').close(); } });

// ---------------------------------------------------------------- getting started (Home)
function renderSetup(steps) {
  const left = (steps || []).filter(s => !s.done), go = { 'settings:connection': () => showSettings('connection'), 'settings:packaging': () => showSettings('packaging'), 'settings:updates': () => showSettings('updates'),
    'settings:automation': () => showSettings('automation'), add: () => openAdd(), 'apps:notdeployed': () => { showView('apps'); $('filter').value = 'notdeployed'; renderApps(); updateViewButtons(); } };
  $('homeSetup').hidden = !steps || !left.length;
  if (!steps || !left.length) return;
  const done = steps.length - left.length;
  $('setupTitle').textContent = `Getting started - ${done} of ${steps.length} done`;
  $('setupBar').style.width = Math.round(100 * done / steps.length) + '%';
  const first = steps.findIndex(s => !s.done);
  // Only the steps still open, in full; the done ones as one short line under them.
  $('setupList').replaceChildren(...steps.map((s, i) => s.done ? null : el('li', { class: i === first ? 'now' : '' },
    el('span', { class: 'mark', 'aria-hidden': 'true', text: String(i + 1) }),
    el('div', { class: 'body' }, el('b', { text: s.title }), el('span', { class: 'muted', text: s.text })),
    go[s.go] ? el('button', { class: 'btn small' + (i === first ? ' primary' : ''), text: i === first ? 'Do it' : 'Go', onclick: go[s.go] }) : '')).filter(Boolean));
  const doneSteps = steps.filter(s => s.done);
  $('setupDone').replaceChildren(...(doneSteps.length ? [el('span', { class: 'muted', text: 'Done: ' }), ...doneSteps.map(s => el('span', { class: 'donechip', text: '✓ ' + s.title }))] : []));
}

// ---------------------------------------------------------------- the catalog and Intune, side by side
// The catalog is the source of truth: everything in Intune should be in it, and the strip says
// what isn't - apps only in the catalog (not deployed yet) and only in Intune (made in the
// portal: add them to the catalog, or delete them there).
const windowsTypes = /^(win32LobApp|winGetApp|windowsMicrosoftEdgeApp|officeSuiteApp|windowsMobileMSI|windowsUniversalAppX|windowsStoreApp|microsoftStoreForBusinessApp|windowsWebApp|webApp|windowsAppX|win32CatalogApp)$/;
const typeName = t => ({ win32LobApp: 'Win32', winGetApp: 'Store', windowsMicrosoftEdgeApp: 'Edge', officeSuiteApp: 'Microsoft 365', windowsMobileMSI: 'MSI (LOB)', windowsUniversalAppX: 'AppX', windowsStoreApp: 'Store (old)', microsoftStoreForBusinessApp: 'Store for Business', windowsWebApp: 'Web link', webApp: 'Web link', win32CatalogApp: 'Win32 (catalog)' })[t] || t;
let showIntuneOnly = false;
function intuneOnly() {
  if (!intuneApps) return { win: [], other: 0 };
  const known = new Set(apps.flatMap(a => [String(a.appId || '').toLowerCase(), ...(a.releaseIds || [])]).filter(Boolean));
  const rest = intuneApps.filter(x => !known.has(String(x.id).toLowerCase()));
  return { win: rest.filter(x => windowsTypes.test(x.type || '')), other: rest.filter(x => !windowsTypes.test(x.type || '')).length };
}
function intuneOnlyRows(q) {
  if (!showIntuneOnly) return [];
  return intuneOnly().win.filter(x => !q || x.name.toLowerCase().includes(q)).sort((a, b) => a.name.localeCompare(b.name)).map(x => el('tr', { class: 'ghost', title: `In Intune only (App ID ${x.id}) - not managed by the catalog` },
    el('td', { class: 'name', text: x.name }), el('td', { class: 'mono src', text: typeName(x.type) }), el('td', {}), el('td', { class: 'muted', text: '-' }),
    el('td', {}, el('span', { class: 'stage' }, el('span', { class: 'pill muted', text: 'Only in Intune' }),
      el('button', { class: 'btn small next', text: 'Add to catalog', title: 'Read its settings and groups from Intune into the catalog', onclick: e => { e.stopPropagation(); addFromIntune([{ appId: x.id, app: x.name }]); } })))));
}
function renderWhere() {
  const bar = $('whereBar');
  if (!apps.length && !intuneApps) { bar.hidden = true; return; }
  const inCat = apps.length, deployed = apps.filter(a => a.hasAppId && tenantState(a) !== 'missing').length, notDeployed = apps.filter(a => !a.hasAppId).length;
  const io = intuneOnly(), f = $('filter').value;
  const chip = (n, label, cls, pressed, title, onclick) => el('button', { type: 'button', class: 'wchip ' + (cls || ''), 'aria-pressed': String(!!pressed), title, onclick }, el('b', { text: String(n) }), el('span', { text: label }));
  bar.replaceChildren(
    chip(inCat, 'in the catalog', '', f === 'all' && !showIntuneOnly, 'Every app the catalog manages - click to show them all', () => { $('filter').value = 'all'; showIntuneOnly = false; renderApps(); updateViewButtons(); }),
    intuneApps ? chip(deployed, 'of them in Intune', '', f === 'deployed', 'Catalog apps that are in this tenant', () => { $('filter').value = 'deployed'; showIntuneOnly = false; renderApps(); updateViewButtons(); }) : '',
    chip(notDeployed, 'only in the catalog', notDeployed ? 'info' : '', f === 'notdeployed', 'Not in Intune yet - select them and Send to Intune', () => { $('filter').value = 'notdeployed'; showIntuneOnly = false; renderApps(); updateViewButtons(); }),
    intuneApps ? chip(io.win.length, 'only in Intune', io.win.length ? 'warn' : '', showIntuneOnly, 'Windows apps in Intune that the catalog doesn\'t manage (made in the portal) - add them to the catalog, or delete them in Intune', () => { showIntuneOnly = !showIntuneOnly; renderApps(); }) : '',
    el('span', { class: 'wnote', text: intuneApps ? `Intune read at ${intuneAt}${io.other ? ` - ${io.other} app(s) for other platforms not counted` : ''}.` : (state && state.configured ? 'Reading Intune...' : 'Not connected - Intune isn\'t compared.') }));
  bar.hidden = false;
}


// ---------------------------------------------------------------- the editor's parts, as pages
// A tab bar at the top of the editor; each tab shows its part only. Everything stays in one form,
// so Save still saves every part - a required field on another page brings that page up.
(function editorPages() {
  const form = $('appForm'), dlg = $('dlgApp'), dsec = $('deploySec');
  const [left, right] = form.querySelectorAll(':scope > .formgrid > section');
  const [dLeft, dRight] = dsec.querySelectorAll(':scope > .formgrid > section');
  const names = ['Basics', 'Who gets it', 'Details', 'Install & detection', 'Requirements', 'Dependencies'];
  const pageOf = new Map();
  const assign = (section, start, switches) => { let p = start; for (const c of section.children) { const sw = switches.find(([test]) => test(c)); if (sw) p = sw[1]; pageOf.set(c, p); } };
  assign(left, 0, [[c => c.matches('h3.withtool'), 1]]);
  assign(right, 2, [[c => c.matches('.ready'), 0], [c => c.tagName === 'H3', 2]]);
  assign(dLeft, 3, [[c => c.tagName === 'H3' && /Detection rule/.test(c.textContent), 3], [c => c.tagName === 'H3' && /Dependencies/.test(c.textContent), 5]]);
  for (const c of dRight.children) pageOf.set(c, 4);
  let cur = 0;
  const bar = el('nav', { class: 'edtabs', 'aria-label': 'Parts of the app' }, ...names.map((name, i) => el('button', { type: 'button', class: 'edtab', 'data-i': i, text: name, onclick: () => {
    setPage(i);
    const f = [...pageOf].find(([c, p]) => p === i && !c.matches('.ready, h3') && c.querySelector('input:not([type=checkbox]):not([hidden]), select, textarea, .chipinput'));
    const field = f && f[0].querySelector('input:not([type=checkbox]):not([hidden]), select, textarea, .chipinput');
    if (field) setTimeout(() => field.focus({ preventScroll: true }), 30);
  } })));
  const mark = i => [...bar.children].forEach((b, k) => b.setAttribute('aria-current', k === i ? 'true' : 'false'));
  function setPage(i) {
    cur = i;
    for (const [c, p] of pageOf) c.classList.toggle('offpage', p !== i);
    for (const s of [left, right, dLeft, dRight]) {
      s.classList.toggle('offpage', ![...s.children].some(c => pageOf.get(c) === i));
      [...s.children].forEach(c => c.classList.remove('pgfirst'));
      const first = [...s.children].find(c => pageOf.get(c) === i); if (first) first.classList.add('pgfirst');
    }
    dsec.classList.toggle('offpage', i < 3);
    if (i >= 3) dsec.open = true;
    mark(i); dlg.scrollTop = 0;
  }
  // The page a field is on, brought up - for "go to the field" links and a required field left empty.
  window.edPageFor = elm => { let n = elm; while (n && !pageOf.has(n)) n = n.parentElement; if (n && pageOf.get(n) !== cur) setPage(pageOf.get(n)); };
  form.addEventListener('invalid', e => edPageFor(e.target), true);
  form.insertBefore(bar, form.querySelector('.formgrid'));
  dlg.addEventListener('close', () => setPage(0));
  setPage(0);
})();
