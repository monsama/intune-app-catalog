// Intune App Catalog - web interface: Checks and the Winget search.
// Loaded after core.js (shared helpers and state); app.js starts the page.
'use strict';

// ---------------------------------------------------------------- checks
let findings = [], checkSel = new Set(), checksRunning = false;
const checkLog = t => { const l = $('checkLog'); l.textContent += t.endsWith('\n') ? t : t + '\n'; l.scrollTop = l.scrollHeight; activity(t); };
const keyOf = f => f.key || `${f.area}|${f.catalogName || f.app}|${f.appId}`;
// A stage's fresh findings replace what that stage said before about the same apps (the last audit's cached rows included).
function mergeFindings(r) {
  const names = new Set(r.names || []), areas = new Set(r.areas || []);
  findings = findings.filter(f => !(areas.has(f.area) && names.has(f.catalogName || f.app))).concat(r.findings || []);
}
function setCheckAreas() {
  const cur = $('checkFilter').value, areas = [...new Set(findings.map(f => f.area))].sort();
  $('checkFilter').replaceChildren(el('option', { value: '', text: 'All areas' }), ...areas.map(a => el('option', { value: a, text: a })));
  if (areas.includes(cur)) $('checkFilter').value = cur;
}
// One stage that is a job (details, assignments): resolves when it has ended.
function checkJob(path, body, label) {
  return new Promise(resolve => {
    runJob(body, (ok, res, after) => resolve(ok && after && after.ok ? after : null), { path, log: 'checkLog', startText: label }).then(started => { if (!started) resolve(null); });
  });
}
async function runChecks(names) {
  if (checksRunning) return;
  checksRunning = true; updateCheckActions();
  const b = $('btnRunChecks'); b.disabled = true; b.textContent = 'Checking...';
  $('checkLogBox').open = true; $('checkLog').textContent = '';
  const only = names && names.length ? { names } : {};
  try {
    $('checkNotes').textContent = 'Reading the catalog, Intune and Entra ID...';
    const r = await api('/api/checks-run', only);
    if (!r.ok) { toast(r.error, true); return; }
    if (names && names.length) {
      const set = new Set(names);
      findings = findings.filter(f => !set.has(f.catalogName || f.app)).concat(r.findings || []);
    } else findings = r.findings || [];
    const notes = [...(r.notes || [])];
    checkLog(`${stamp()} ${notes.join(' ')}`);
    renderChecks();
    if ($('chkDetails').checked && r.connected && r.deployed > 0) {
      $('checkNotes').textContent = `Reading ${r.deployed} deployed app(s) from Intune in detail - the slowest part...`;
      const d = await checkJob('/api/checks-details', only, 'Reading the deployed apps in detail...');
      if (d) { mergeFindings(d); renderChecks(); } else notes.push('The detailed check of the deployed apps did not finish - see the log.');
      const a = await checkJob('/api/checks-assign', only, 'Comparing the assignments...');
      if (a) { mergeFindings(a); renderChecks(); } else notes.push('The assignments could not be compared - see the log.');
    }
    if ($('chkWinget').checked && r.winget > 0) {
      $('checkNotes').textContent = `Asking winget about ${r.winget} Winget ID(s)...`;
      checkLog(`${stamp()} Asking winget about ${r.winget} Winget ID(s)...`);
      const w = await api('/api/checks-winget', only);
      if (w.ok) { mergeFindings(w); checkLog(`${stamp()} winget: ${(w.findings || []).length} problem(s).`); }
      else { notes.push(w.error); checkLog(`${stamp()} [WARN] ${w.error}`); }
    }
    $('checkNotes').textContent = notes.join(' ');
    $('checkEmptyTitle').textContent = 'Nothing to fix';
    $('checkEmptyText').textContent = 'The catalog, Intune and Entra ID agree.';
    checkLog(`${stamp()} [OK] Checks finished: ${findings.length} finding(s).`);
  } finally {
    checksRunning = false; b.disabled = false; b.textContent = 'Run checks';
    setCheckAreas(); renderChecks();
  }
}
$('btnRunChecks').addEventListener('click', () => runChecks());

const selFindings = () => findings.filter(f => checkSel.has(keyOf(f)));
const namesWith = (list, action) => [...new Set(list.filter(f => (f.actions || []).includes(action)).map(f => f.catalogName || f.app))];
function updateCheckActions() {
  const sel = selFindings();
  const count = a => namesWith(sel, a).length;
  const set = (id, a, label) => { const n = count(a); setEnabled($(id), !(checksRunning || jobRunning) && n > 0, checksRunning || jobRunning ? 'Wait for the running check or job to finish.' : `Tick findings that offer ${label}.`); $(id).textContent = n > 1 ? `${label} (${n})` : label; };
  set('btnFixPull', 'Pull', 'Pull'); set('btnFixPushSettings', 'PushMetadata', 'Push settings'); set('btnFixPushGroups', 'PushGroups', 'Push groups');
  const busy = checksRunning || jobRunning ? 'Wait for the running check or job to finish.' : '';
  setEnabled($('btnFixAdd'), !busy && sel.some(f => (f.actions || []).includes('AddToCatalog')), busy || 'Tick findings that are "In Intune, not in the catalog".');
  setEnabled($('btnFixRecheck'), !busy && sel.length > 0, busy || 'Tick one or more findings first.');
  $('checkSelCount').textContent = sel.length ? `${sel.length} selected` : '';
}
$('btnFixPull').addEventListener('click', () => openPull(namesWith(selFindings(), 'Pull')));
$('btnFixPushSettings').addEventListener('click', () => pushSettings(namesWith(selFindings(), 'PushMetadata')));
$('btnFixPushGroups').addEventListener('click', () => openPushGroups(namesWith(selFindings(), 'PushGroups')));
$('btnFixAdd').addEventListener('click', () => addFromIntune(selFindings().filter(f => (f.actions || []).includes('AddToCatalog'))));
$('btnFixRecheck').addEventListener('click', () => runChecks([...new Set(selFindings().map(f => f.catalogName || f.app).filter(Boolean))]));
$('checkAll').addEventListener('change', e => {
  const area = $('checkFilter').value;
  for (const f of findings.filter(f => !area || f.area === area)) { if (e.target.checked) checkSel.add(keyOf(f)); else checkSel.delete(keyOf(f)); }
  renderChecks();
});

function dropFinding(f) { findings = findings.filter(x => keyOf(x) !== keyOf(f)); checkSel.delete(keyOf(f)); renderChecks(); }
function fixButtons(f) {
  const out = [], name = f.catalogName || f.app;
  const btn = (text, onclick, title) => out.push(el('button', { class: 'btn small', text, title: title || '', onclick }));
  const fix = async (action, value) => {
    const r = await api('/api/checks-fix', { action, catalogName: name, value });
    if (!r.ok) { toast(r.error, true); return false; }
    toast('Fixed in the catalog.'); dropFinding(f); loadApps(); return true;
  };
  // One order on every row, so the same fix is always in the same place.
  const order = ['RenameFromIntune', 'SetAppId', 'ChooseAppId', 'ClearAppId', 'AddToCatalog', 'Pull', 'PushMetadata', 'PushGroups', 'FindWingetId', 'EditApp', 'Recheck'];
  for (const a of order.filter(x => (f.actions || []).includes(x))) {
    if (a === 'RenameFromIntune' && f.data && f.data.IntuneName) btn('Use Intune’s name', () => fix(a, f.data.IntuneName), f.data.IntuneName);
    else if (a === 'SetAppId' && f.data && f.data.MatchedId) btn('Link to ' + (f.data.MatchedName || 'match'), () => fix(a, f.data.MatchedId));
    else if (a === 'ChooseAppId' && f.data && f.data.Candidates && f.data.Candidates.length && !(f.data.MatchedId)) {
      const sel = el('select', { 'aria-label': 'Intune app' }, ...f.data.Candidates.map(c => el('option', { value: c.id, text: c.displayName })));
      out.push(sel); btn('Link', () => fix('SetAppId', sel.value));
    }
    else if (a === 'ClearAppId') btn('Clear App ID', () => { if (confirm(`Clear ${f.app}'s App ID? It points at an app that no longer exists in Intune.`)) fix(a); });
    else if (a === 'EditApp') btn('Edit', () => openEditor(name));
    else if (a === 'Pull') btn('Pull', () => openPull([name]), 'Intune is right: take its settings and groups into the catalog');
    else if (a === 'PushMetadata') btn('Push settings', () => pushSettings([name]), 'The catalog is right: send its settings to Intune');
    else if (a === 'PushGroups') btn('Push groups', () => openPushGroups([name]), 'The catalog is right: send its groups to Intune');
    else if (a === 'AddToCatalog') btn('Add to catalog', () => addFromIntune([f]));
    else if (a === 'FindWingetId') btn('Find Winget ID', () => openWinget(f.app, async id => { if (await fix('SetWingetId', id)) runChecks([name]); }));
    else if (a === 'Recheck') btn('Re-check', () => runChecks([name]));
  }
  return el('div', { class: 'fixes' }, ...out);
}
function renderChecks() {
  const area = $('checkFilter').value;
  const list = findings.filter(f => !area || f.area === area);
  $('checkBody').replaceChildren(...list.map(f => {
    const k = keyOf(f);
    const box = el('input', { type: 'checkbox', 'aria-label': 'Select', checked: checkSel.has(k) });
    box.addEventListener('change', () => { if (box.checked) checkSel.add(k); else checkSel.delete(k); updateCheckActions(); });
    return el('tr', { 'aria-selected': String(checkSel.has(k)) },
      el('td', { class: 'sel' }, box),
      el('td', {}, el('span', { class: 'pill ' + (f.failed ? 'err' : 'warn'), text: f.area })),
      el('td', { class: 'name', text: f.app }),
      el('td', {}, f.problem, f.cached ? el('span', { class: 'muted', text: ` (last audit${f.checkedAt ? ', ' + f.checkedAt : ''})` }) : ''),
      el('td', { class: 'cmp', text: f.catalog }), el('td', { class: 'cmp', text: f.intune }),
      el('td', {}, fixButtons(f)));
  }));
  $('checkAll').checked = list.length > 0 && list.every(f => checkSel.has(keyOf(f)));
  $('checkCount').textContent = findings.length ? `${list.length} finding(s)` : '';
  $('checkGrid').hidden = findings.length === 0;
  $('checkEmpty').hidden = findings.length > 0;
  updateCheckActions();
}
$('checkFilter').addEventListener('change', renderChecks);

// Add to catalog: reads the Intune-only apps' settings and groups and adds them.
function addFromIntune(list) {
  const items = list.map(f => ({ id: f.appId, name: f.app }));
  if (!items.length) return;
  if (!confirm(`Add ${items.length === 1 ? `"${items[0].name}"` : items.length + ' apps'} from Intune to the catalog?\n\nEach one's settings and groups are read from Intune first. Nothing in Intune changes.`)) return;
  runDialog('Add to catalog', items.map(i => i.name).join(', '));
  runJob({ apps: items }, (ok, res, after) => {
    if (!ok || !after) return;
    const parts = [`Added ${after.added.length} app(s).`];
    if (after.skipped.length) parts.push(`Skipped: ${after.skipped.join('; ')}.`);
    if (after.noGroups.length) parts.push(`Groups couldn't be read for ${after.noGroups.join(', ')} - left empty.`);
    toast(parts.join(' '), !after.added.length);
    for (const f of list) if (after.added.includes(f.app)) dropFinding(f);
    loadApps();
  }, { path: '/api/add-from-intune', log: 'runLog', startText: 'Reading from Intune...' });
}

// Runs one job per name, one after another, in the Run dialog; resolves with the names that worked.
async function runEach(names, body, opts) {
  const done = [];
  for (const name of names) {
    const ok = await new Promise(resolve => {
      runJob(body(name), ok => resolve(ok), { ...opts, startText: (opts.startText || '') + name + '...' }).then(started => { if (!started) resolve(false); });
    });
    if (ok) done.push(name);
  }
  return done;
}
async function pushSettings(names) {
  if (!names.length) return;
  if (!confirm(`Send the catalog's settings for ${names.length === 1 ? `"${names[0]}"` : names.length + ' apps'} to Intune?\n\nDescription, commands, detection rule, requirements, return codes and dependencies are replaced with the catalog's. No package is uploaded; groups aren't touched.`)) return;
  runDialog('Push settings to Intune', names.join(', '));
  const done = await runEach(names, name => ({ name, metadataOnly: true }), { path: '/api/deploy-start', log: 'runLog', startText: 'Pushing ' });
  toast(`Settings pushed for ${done.length} of ${names.length} app(s).`, done.length < names.length);
  for (const f of findings.filter(f => done.includes(f.catalogName) && (f.actions || []).includes('PushMetadata'))) dropFinding(f);
  loadApps();
}

// ---------------------------------------------------------------- winget search (Find Winget ID, Add app)
let wingetPick = null;
function openWinget(query, onPick) {
  wingetPick = onPick;
  $('wgQuery').value = query || ''; $('wgRows').replaceChildren(); $('wgNote').textContent = 'Searches winget’s sources. Pick the package to use its ID.';
  $('dlgWinget').showModal();
  if (query) searchWinget();
}
async function searchWinget() {
  const q = $('wgQuery').value.trim();
  if (q.length < 2) { $('wgNote').textContent = 'Type at least 2 characters.'; return; }
  $('wgNote').textContent = 'Asking winget...'; $('btnWgSearch').disabled = true;
  const r = await api('/api/winget-search', { q });
  $('btnWgSearch').disabled = false;
  if (!r.ok) { $('wgNote').textContent = r.error; return; }
  $('wgNote').textContent = r.rows.length ? `${r.rows.length} package(s). Pick one to use its ID.` : 'winget found nothing - try a shorter name or the publisher.';
  $('wgRows').replaceChildren(...r.rows.map(x => el('tr', {}, el('td', { text: x.name }), el('td', { class: 'chg', text: x.id }), el('td', { text: x.version }), el('td', { text: x.source }),
    el('td', {}, el('button', { class: 'btn small', text: 'Use', onclick: () => { $('dlgWinget').close(); if (wingetPick) wingetPick(x.id, x); } })))));
}
$('btnWgSearch').addEventListener('click', searchWinget);
$('btnFindWinget').addEventListener('click', () => openWinget($('aName').value.trim() || $('aWinget').value.trim(), (id, x) => {
  $('aWinget').value = id;
  if (!$('aName').value.trim()) $('aName').value = x.name;
  if (!$('mPublisher').value.trim() && id.includes('.')) $('mPublisher').value = id.split('.')[0];
}));
$('wgQuery').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); searchWinget(); } });
