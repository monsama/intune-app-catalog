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
  const cur = $('checkFilter').value, areas = [...new Set(shownFindings().map(f => f.area))].sort();
  $('checkFilter').replaceChildren(el('option', { value: '', text: 'All areas' }), ...areas.map(a => el('option', { value: a, text: a })));
  if (areas.includes(cur)) $('checkFilter').value = cur;
}
// One stage that is a job (details, assignments): resolves when it has ended.
function checkJob(path, body, label) {
  return new Promise(resolve => {
    // The log opens by itself only when a stage fails - otherwise it stays folded, and the findings get the room.
    runJob(body, (ok, res, after) => { if (!(ok && after && after.ok)) $('checkLogBox').open = true; resolve(ok && after && after.ok ? after : null); }, { path, log: 'checkLog', startText: label }).then(started => { if (!started) resolve(null); });
  });
}
async function runChecks(names) {
  if (checksRunning) return;
  checksRunning = true; updateCheckActions();
  // 2.38.13: one change to the list - at the end. While the stages run, what was shown stays, dimmed (a first run
  // shows the last audit's rows that way); before, each stage redrew it and rows came and went for a few seconds.
  const hadRows = shownFindings().length > 0;
  $('checkGrid').classList.add('checking'); $('checkBody').inert = true; $('checkAll').disabled = true; $('checkFilter').disabled = true;
  const b = $('btnRunChecks'); b.disabled = true; b.textContent = 'Checking...';
  $('checkLogBox').open = false; $('checkLog').textContent = '';
  const only = names && names.length ? { names } : {};
  try {
    $('checkNotes').textContent = 'Reading the catalog, Intune and Entra ID...';
    const r = await api('/api/checks-run', only);
    if (!r.ok) { toast(r.error, true); return; }
    if (names && names.length) {
      const set = new Set(names);
      findings = findings.filter(f => !set.has(f.catalogName || f.app)).concat(r.findings || []);
    } else findings = r.findings || [];
    // notes: what was NOT compared; summary: what was.
    const notes = [...(r.notes || [])];
    checkLog(`${stamp()} ${[r.summary || '', ...notes].join(' ').trim()}`);
    if (!hadRows) renderChecks();
    if ($('chkDetails').checked && r.connected && r.deployed > 0) {
      $('checkNotes').textContent = `Reading ${r.deployed} deployed app(s) from Intune in detail - the slowest part...`;
      const d = await checkJob('/api/checks-details', only, 'Reading the deployed apps in detail...');
      // Apps Checks set right in the catalog (a Store app's ID from Intune, 2.38.31): the list shows them as they are now.
      if (d) { mergeFindings(d); if ((d.changed || []).length) { findings = findings.filter(f => !(d.changed.includes(f.app) && f.area === 'Package')); notes.push(`Taken from Intune: ${d.changed.join(', ')} - a Microsoft Store app there, its Store ID is now in the catalog.`); if (typeof loadApps === 'function') loadApps(); } } else notes.push('The detailed check of the deployed apps did not finish - see the log.');
      const a = await checkJob('/api/checks-assign', only, 'Comparing the assignments...');
      if (a) mergeFindings(a); else notes.push('The assignments could not be compared - see the log.');
    }
    // 2.38.20: without the detailed part, the settings and groups in Intune weren't compared at all - "Nothing to fix" said
    // "the catalog and Intune agree" although Home and the apps showed differences (from the nightly run or a full check).
    else if (r.connected && r.deployed > 0) notes.push(`The settings and groups of the ${r.deployed} app(s) in Intune weren't compared - turn on Options > Deployed apps in detail.`);
    if ($('chkWinget').checked && r.winget > 0) {
      $('checkNotes').textContent = `Asking winget about ${r.winget} Winget ID(s)...`;
      checkLog(`${stamp()} Asking winget about ${r.winget} Winget ID(s)...`);
      const w = await api('/api/checks-winget', only);
      if (w.ok) { mergeFindings(w); checkLog(`${stamp()} winget: ${(w.findings || []).length} problem(s).`); }
      else { notes.push(w.error); checkLog(`${stamp()} [WARN] ${w.error}`); }
    }
    // No findings: the empty state says what wasn't compared - the note above doesn't say it again.
    $('checkNotes').textContent = [r.summary || '', ...(findings.length ? notes : [])].join(' ').trim();
    $('checkEmptyList').hidden = true; $('btnRunChecksEmpty').hidden = true;
    // Not everything compared (2.38.23): said in the title - not the green "Nothing to fix" with the catch in small print.
    $('checkEmptyTitle').textContent = notes.length ? 'No findings in what was compared' : 'Nothing to fix';
    $('checkEmptyText').textContent = notes.length ? `Not everything was compared: ${notes.join(' ')}` : 'The catalog, Intune and Entra ID agree.';
    $('checkEmpty').classList.toggle('partial', !!notes.length);
    checkLog(`${stamp()} [OK] Checks finished: ${shownFindings().length} finding(s).`);
    return r;
  } finally {
    checksRunning = false; b.disabled = false; b.textContent = 'Run checks';
    $('checkGrid').classList.remove('checking'); $('checkBody').inert = false; $('checkAll').disabled = false; $('checkFilter').disabled = false;
    setCheckAreas(); renderChecks();
  }
}
$('btnRunChecks').addEventListener('click', () => runChecks());

// Only what the list shows - a finding folded into its Groups row isn't acted on twice.
// What the list shows now (area and app filter too): only those count as selected - a tick on a row filtered away
// doesn't (it said "2 selected" with one row in sight).
const visibleFindings = () => { const area = $('checkFilter').value; return shownFindings().filter(f => (!area || f.area === area) && (!checkApp || (f.catalogName || f.app) === checkApp)); };
const selFindings = () => visibleFindings().filter(f => checkSel.has(keyOf(f)));
// After a fix changed apps in the catalog or Intune: Checks asks again about those apps, so the list shows what is
// still different (not a stale row, nor one dropped too early).
// Only apps Checks knows about: still with a finding, or one just dropped by the fix (most fixes drop it first).
// While a check or a job runs it waits for it - a check started next to a job loses its detail stages.
const checksDropped = new Set();
function checksRefresh(names, tries = 0) {
  const want = [...new Set((names || []).filter(Boolean))].filter(n => checksDropped.has(n) || findings.some(f => (f.catalogName || f.app) === n));
  if (!want.length) return;
  if (checksRunning || (typeof jobRunning !== 'undefined' && jobRunning)) { if (tries < 100) setTimeout(() => checksRefresh(want, tries + 1), 3000); return; }
  for (const n of want) checksDropped.delete(n);
  runChecks(want);
}
const namesWith = (list, action) => [...new Set(list.filter(f => (f.actions || []).includes(action)).map(f => f.catalogName || f.app))];
function updateCheckActions() {
  const sel = selFindings();
  const count = a => namesWith(sel, a).length;
  const set = (id, a, label) => { const n = count(a); setEnabled($(id), !(checksRunning || jobRunning) && n > 0, checksRunning || jobRunning ? 'Wait for the running check or job to finish.' : `Tick findings that offer ${label}.`); $(id).textContent = n > 1 ? `${label} (${n})` : label; };
  { const n = groupsOf(sel).length; setEnabled($('btnFixCreateGroups'), !(checksRunning || jobRunning) && n > 0, checksRunning || jobRunning ? 'Wait for the running check or job to finish.' : 'Tick findings about groups that don\'t exist in Entra ID.'); $('btnFixCreateGroups').textContent = n > 1 ? `Create groups (${n})` : 'Create group'; }
  set('btnFixPull', 'Pull', 'Take from Intune'); set('btnFixPushSettings', 'PushMetadata', 'Send settings'); set('btnFixPushGroups', 'PushGroups', 'Send groups');
  const busy = checksRunning || jobRunning ? 'Wait for the running check or job to finish.' : '';
  setEnabled($('btnFixAdd'), !busy && sel.some(f => (f.actions || []).includes('AddToCatalog')), busy || 'Tick findings that are "In Intune, not in the catalog".');
  setEnabled($('btnFixRecheck'), !busy && sel.length > 0, busy || 'Tick one or more findings first.');
  { const n = sel.filter(comparable).length; setEnabled($('btnFixCompare'), n > 0, 'Tick findings where the catalog and Intune differ.'); $('btnFixCompare').textContent = n > 1 ? `Compare (${n})` : 'Compare'; }
  $('checkSelCount').textContent = sel.length ? `${sel.length} selected` : 'Tick findings to fix several at once';
  // Always there while there are findings (greyed out until something is ticked), so ticking doesn't move the table.
  $('checkFixBar').hidden = !findings.length;
}
// The missing groups named by findings that offer CreateGroup.
const groupsOf = list => [...new Set(list.filter(f => (f.actions || []).includes('CreateGroup') && f.data && f.data.Group).map(f => f.data.Group))];
const dropGroupFindings = made => { for (const f of findings.filter(f => f.data && made.some(g => g.toLowerCase() === String(f.data.Group || '').toLowerCase()))) dropFinding(f); };
$('btnFixCreateGroups').addEventListener('click', () => createGroups(groupsOf(selFindings()), dropGroupFindings));
$('btnFixPull').addEventListener('click', () => openPull(namesWith(selFindings(), 'Pull')));
$('btnFixPushSettings').addEventListener('click', () => pushSettings(namesWith(selFindings(), 'PushMetadata')));
$('btnFixPushGroups').addEventListener('click', () => openPushGroups(namesWith(selFindings(), 'PushGroups')));
$('btnFixAdd').addEventListener('click', () => addFromIntune(selFindings().filter(f => (f.actions || []).includes('AddToCatalog'))));
$('btnFixCompare').addEventListener('click', () => openCompare(selFindings().filter(comparable)));
$('btnFixRecheck').addEventListener('click', () => runChecks([...new Set(selFindings().map(f => f.catalogName || f.app).filter(Boolean))]));
$('checkAll').addEventListener('change', e => {
  for (const f of visibleFindings()) { if (e.target.checked) checkSel.add(keyOf(f)); else checkSel.delete(keyOf(f)); }
  renderChecks();
});

function dropFinding(f) { checksDropped.add(f.catalogName || f.app); findings = findings.filter(x => keyOf(x) !== keyOf(f)); checkSel.delete(keyOf(f)); renderChecks(); }
function fixButtons(f) {
  const out = [], name = f.catalogName || f.app;
  const btn = (text, onclick, title) => out.push(el('button', { class: 'btn small', text, title: title || '', onclick }));
  const fix = async (action, value) => {
    const r = await api('/api/checks-fix', { action, catalogName: name, value });
    if (!r.ok) { toast(r.error, true); return false; }
    toast('Fixed in the catalog.'); dropFinding(f); loadApps(); checksRefresh([name]); return true;
  };
  // One order on every row, so the same fix is always in the same place.
  if (comparable(f)) btn('Compare', () => openCompare([f]), 'See side by side what differs');
  const order = ['RenameFromIntune', 'SetAppId', 'ChooseAppId', 'ClearAppId', 'AddToCatalog', 'CreateGroup', 'OpenGroup', 'Pull', 'PushMetadata', 'PushGroups', 'FindWingetId', 'EditApp', 'Recheck'];
  for (const a of order.filter(x => (f.actions || []).includes(x))) {
    if (a === 'RenameFromIntune' && f.data && f.data.IntuneName) btn('Use Intune’s name', () => fix(a, f.data.IntuneName), f.data.IntuneName);
    else if (a === 'SetAppId' && f.data && f.data.MatchedId) btn('Link to ' + (f.data.MatchedName || 'match'), () => fix(a, f.data.MatchedId));
    else if (a === 'ChooseAppId' && f.data && f.data.Candidates && f.data.Candidates.length && !(f.data.MatchedId)) {
      const sel = el('select', { 'aria-label': 'Intune app' }, ...f.data.Candidates.map(c => el('option', { value: c.id, text: c.displayName })));
      out.push(sel); btn('Link', () => fix('SetAppId', sel.value));
    }
    else if (a === 'ClearAppId') btn('Clear App ID', async () => { if (await ask(`Clear ${f.app}'s App ID? It points at an app that no longer exists in Intune.`)) fix(a); });
    else if (a === 'CreateGroup' && f.data && f.data.Group) btn('Create group', () => createGroups([f.data.Group], dropGroupFindings), `Create "${f.data.Group}" in Entra ID as a security group`);
    else if (a === 'OpenGroup' && f.data && f.data.Group) btn('Open in Groups', () => { showView('groups'); openGroup(f.data.Group); }, 'See which apps use this group, and its members');
    else if (a === 'EditApp') btn('Edit', () => openEditor(name));
    else if (a === 'Pull') btn('Take from Intune', () => openPull([name]), 'Intune is right: take its settings and groups into the catalog');
    else if (a === 'PushMetadata') btn('Send settings', () => pushSettings([name]), 'The catalog is right: send its settings to Intune');
    else if (a === 'PushGroups') btn('Send groups', () => openPushGroups([name]), 'The catalog is right: send its groups to Intune');
    else if (a === 'AddToCatalog') btn('Add to catalog', () => addFromIntune([f]));
    else if (a === 'FindWingetId') btn('Find Winget ID', () => openWinget(f.app, async id => { if (await fix('SetWingetId', id)) runChecks([name]); }));
    else if (a === 'Recheck') btn('Re-check', () => runChecks([name]));
  }
  return el('div', { class: 'fixes' }, ...out);
}
// One app's findings only (from its "Needs a look" on Apps or Home) - a chip says so and x shows all again.
let checkApp = '';
async function showChecksFor(name) {
  window.keepCheckApp = true; showView('checks'); window.keepCheckApp = false; checkApp = name; renderChecks();
  if (!findings.some(f => (f.catalogName || f.app) === name)) await runChecks([name]);
}
// One problem, one row (2.38.6): an "Unknown assignments" finding whose every item is already in the same app's
// "Groups" finding (that list differs - Intune has it, the catalog doesn't) says nothing new, and its fixes are the same.
// What the Groups row can't show - an assignment with a filter, an exclusion, a target the catalog can't hold - stays.
const shownFindings = () => findings.filter(f => !coveredByGroups(f, findings));
function coveredByGroups(f, all) {
  if (f.area !== 'Unknown assignments') return false;
  const name = f.catalogName || f.app;
  const g = all.find(x => x.area === 'Groups' && (x.catalogName || x.app) === name);
  if (!g) return false;
  const lists = {}, split = v => String(v ?? '').split(/,\s*/).map(s => s.trim().toLowerCase()).filter(Boolean);
  for (const d of diffsOf(g)) lists[String(d.field).toLowerCase()] = split(d.remote);
  // The last audit's saved rows (shown while checks run) keep only their text: "1 differ: Required for - catalog:
  // (none) | Intune: [All devices]" and "1 unknown: [required] [All devices]" - read from that, so they fold at once too.
  if (!Object.keys(lists).length)
    for (const m of String(g.problem || '').matchAll(/((?:Required|Available|Uninstall) for) - catalog: .*? \| Intune: (.*?)(?=; (?:Required|Available|Uninstall) for - |$)/gi)) lists[m[1].toLowerCase()] = split(m[2]);
  const itemText = f.intune || String(f.problem || '').replace(/^\d+ unknown:\s*/i, '');
  const items = String(itemText).split(/,\s*(?=\[)/).map(s => s.trim()).filter(Boolean);
  return items.length > 0 && items.every(it => {
    const m = /^\[(required|available|uninstall)\]\s+(.+)$/i.exec(it);
    if (!m || /\(filter:|^EXCLUDE\s/i.test(m[2])) return false;
    return (lists[`${m[1].toLowerCase()} for`] || []).includes(m[2].trim().toLowerCase());
  });
}
function renderChecks() {
  hcClose();
  const area = $('checkFilter').value;
  const list = findings.filter(f => (!area || f.area === area) && (!checkApp || (f.catalogName || f.app) === checkApp) && !coveredByGroups(f, findings));
  let chip = document.getElementById('checkAppChip');
  if (checkApp) {
    if (!chip) { chip = el('span', { class: 'chip tag', id: 'checkAppChip' }); $('checkFilter').after(chip); }
    chip.replaceChildren(el('span', { class: 't', text: `Only ${checkApp}` }), el('button', { type: 'button', class: 'x', text: '×', 'aria-label': 'Show every app', title: 'Show every app', onclick: () => { checkApp = ''; renderChecks(); } }));
  } else if (chip) chip.remove();
  $('checkBody').replaceChildren(...list.map(f => {
    const k = keyOf(f);
    const box = el('input', { type: 'checkbox', 'aria-label': 'Select', checked: checkSel.has(k) });
    box.addEventListener('change', () => { if (box.checked) checkSel.add(k); else checkSel.delete(k); updateCheckActions(); });
    return el('tr', { 'aria-selected': String(checkSel.has(k)) },
      el('td', { class: 'sel' }, box),
      el('td', {}, el('span', { class: 'pill ' + (f.failed ? 'err' : 'warn'), text: f.area })),
      el('td', { class: 'name', text: f.app }),
      el('td', {}, f.problem, f.cached ? el('span', { class: 'muted', text: ` (last audit${f.checkedAt ? ', ' + f.checkedAt : ''})` }) : ''),
      el('td', { class: 'dif' }, diffCell(f)),
      el('td', {}, fixButtons(f)));
  }));
  $('checkAll').checked = list.length > 0 && list.every(f => checkSel.has(keyOf(f)));
  // Filtered to one app (2.38.32): say how many the other apps have - "0 finding(s)" read as "nothing anywhere".
  const hiddenN = checkApp ? shownFindings().filter(f => (f.catalogName || f.app) !== checkApp).length : 0;
  $('checkCount').textContent = findings.length ? `${list.length} finding(s)${hiddenN ? ` - ${hiddenN} more for other apps (x shows all)` : ''}` : '';
  $('checkGrid').hidden = findings.length === 0;
  $('checkEmpty').hidden = findings.length > 0;
  updateCheckActions();
}
$('checkFilter').addEventListener('change', renderChecks);

// ---------------------------------------------------------------- compare (catalog next to Intune)
// The field-by-field values the detail check sent along; dependencies only have their two summary lines.
const diffsOf = f => {
  const d = f.data && f.data.Diffs;
  if (d) return [].concat(d).filter(Boolean).map(x => ({ field: x.Field || x.field || '', local: x.Local !== undefined ? x.Local : x.local, remote: x.Remote !== undefined ? x.Remote : x.remote }));
  if (f.area === 'Dependencies' && (f.catalog || f.intune)) return [{ field: 'Dependencies', local: String(f.catalog || '').split(/,\s*/), remote: String(f.intune || '').split(/,\s*/) }];
  return [];
};
const comparable = f => diffsOf(f).length > 0;
// A value as lines to compare: JSON (detection rule, return codes) is spread out, a script inside it gets its own lines.
function cmpLines(v) {
  if (v === null || v === undefined || v === '') return ['(blank)'];
  if (typeof v === 'string') {
    const t = v.trim();
    if (/^[[{]/.test(t)) { try { return cmpLinesOf(JSON.parse(t)); } catch { /* plain text after all */ } }
    return v.replace(/\r\n?/g, '\n').replace(/\n+$/, '').split('\n');
  }
  return cmpLinesOf(v);
}
function cmpLinesOf(o) {
  if (o === null || o === undefined || o === '') return ['(blank)'];
  if (Array.isArray(o)) return o.length ? o.map(x => x !== null && typeof x === 'object' ? JSON.stringify(x) : String(x)) : ['(none)'];
  if (typeof o !== 'object') return cmpLines(String(o));
  const out = [];
  for (const [k, val] of Object.entries(o)) {
    if (typeof val === 'string' && /[\r\n]/.test(val)) out.push(`${k}:`, ...val.replace(/\r\n?/g, '\n').replace(/\n+$/, '').split('\n').map(l => '    ' + l));
    else if (val !== null && typeof val === 'object') out.push(`${k}: ${JSON.stringify(val)}`);
    else out.push(`${k}: ${val === null || val === undefined || val === '' ? '(blank)' : val}`);
  }
  return out.length ? out : ['(blank)'];
}
// Line diff (longest common subsequence) as side-by-side rows: [left, right, kind] with kind '=', 'chg', 'del' or 'add'.
function cmpRows(a, b) {
  const n = a.length, m = b.length;
  if (n * m > 4e6) return Array.from({ length: Math.max(n, m) }, (_, i) => [a[i], b[i], a[i] === b[i] ? '=' : 'chg']);
  const L = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) L[i][j] = a[i] === b[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  const rows = []; let i = 0, j = 0, dels = [], adds = [];
  const flush = () => { const k = Math.max(dels.length, adds.length); for (let x = 0; x < k; x++) rows.push([dels[x], adds[x], dels[x] !== undefined && adds[x] !== undefined ? 'chg' : dels[x] !== undefined ? 'del' : 'add']); dels = []; adds = []; };
  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) { flush(); rows.push([a[i], b[j], '=']); i++; j++; }
    else if (j < m && (i >= n || L[i][j + 1] >= L[i + 1][j])) adds.push(b[j++]);
    else dels.push(a[i++]);
  }
  flush();
  return rows;
}
// Marks what a line holds that its partner doesn't: the middle between the common start and end.
function cmpCell(text, other, side) {
  if (text === undefined) return el('td', { class: 'v none' });
  if (other === undefined || text === other) return el('td', { class: 'v', text: text === '' ? ' ' : text });
  let s = 0; while (s < text.length && s < other.length && text[s] === other[s]) s++;
  let e = 0; while (e < text.length - s && e < other.length - s && text[text.length - 1 - e] === other[other.length - 1 - e]) e++;
  const mid = text.slice(s, text.length - e);
  return el('td', { class: 'v' }, text.slice(0, s), mid ? el('mark', { class: side, text: mid }) : '', text.slice(text.length - e));
}
let cmpList = [], cmpAt = 0;
function openCompare(list) {
  if (!list.length) return;
  cmpList = list; cmpAt = 0;
  renderCompare();
  if (!$('dlgCompare').open) $('dlgCompare').showModal();
}
function renderCompare() {
  const f = cmpList[cmpAt], diffs = diffsOf(f);
  $('cmpTitle').textContent = `Compare: ${f.app}`;
  $('cmpNote').textContent = `${f.area} - ${f.problem}. Left is the catalog, right is Intune; changed lines are marked.`;
  $('cmpBody').replaceChildren(...diffs.map(d => {
    const rows = cmpRows(cmpLines(d.local), cmpLines(d.remote));
    const changed = rows.filter(r => r[2] !== '=').length;
    // Only whitespace or line endings differ: say so, or the marked lines look the same.
    const wsOnly = rows.every(r => r[2] === '=' || String(r[0] ?? '').trim() === String(r[1] ?? '').trim());
    return el('section', { class: 'cmpfield' },
      el('h3', {}, d.field, el('span', { class: 'muted', text: ` - ${changed} line(s) differ${wsOnly && changed ? ' (spaces only)' : ''}` })),
      el('div', { class: 'tablewrap' }, el('table', { class: 'cmp' },
        el('thead', {}, el('tr', {}, el('th', { text: 'Catalog' }), el('th', { text: 'Intune' }))),
        el('tbody', {}, ...rows.map(([l, r, k]) => el('tr', { class: k === '=' ? '' : k }, cmpCell(l, r, 'del'), cmpCell(r, l, 'add')))))));
  }));
  const nav = $('cmpNav');
  nav.replaceChildren(...(cmpList.length > 1 ? [
    el('button', { class: 'btn small', text: '‹', 'aria-label': 'Previous', disabled: cmpAt === 0, onclick: () => { cmpAt--; renderCompare(); } }),
    el('span', { class: 'muted', text: ` ${cmpAt + 1} of ${cmpList.length} ` }),
    el('button', { class: 'btn small', text: '›', 'aria-label': 'Next', disabled: cmpAt === cmpList.length - 1, onclick: () => { cmpAt++; renderCompare(); } })] : []));
  $('cmpFixes').replaceChildren(...cmpFixButtons(f, 'btn', () => $('dlgCompare').close()));
}
// "Take from Intune" / "Send settings" / "Send groups" for one finding - in Compare and in the hover card.
function cmpFixButtons(f, cls, before) {
  const name = f.catalogName || f.app, acts = f.actions || [];
  const go = fn => () => { before(); fn(); };
  return [
    ...(acts.includes('Pull') ? [el('button', { class: cls, text: 'Take from Intune', title: 'Intune is right: take its values into the catalog', onclick: go(() => openPull([name])) })] : []),
    ...(acts.includes('PushMetadata') ? [el('button', { class: cls, text: 'Send settings', title: 'The catalog is right: send its settings to Intune', onclick: go(() => pushSettings([name])) })] : []),
    ...(acts.includes('PushGroups') ? [el('button', { class: cls, text: 'Send groups', title: 'The catalog is right: send its groups to Intune', onclick: go(() => openPushGroups([name])) })] : [])];
}

// ---------------------------------------------------------------- "Differs": a chip per field + a hover card (2.38.4)
// The row says WHICH fields differ; pointing at them (or Tab + Enter) shows the values side by side - field, catalog,
// Intune - with the changed part marked. The full Compare dialog is one click away for long values.
function diffCell(f) {
  const diffs = diffsOf(f);
  if (!diffs.length) {
    const line = (k, v) => v && !/^\((blank|none)\)$/.test(String(v).trim()) ? el('div', { class: 'dline', title: String(v) }, el('b', { text: k }), String(v)) : '';
    return el('div', { class: 'dlines' }, line('Catalog', f.catalog), line(f.area === 'Entra groups' ? 'Entra ID' : 'Intune', f.intune));
  }
  const names = diffs.map(d => d.field || 'Value'), shown = names.slice(0, names.length > 4 ? 3 : 4);
  const b = el('button', { type: 'button', class: 'difs', 'aria-haspopup': 'dialog', 'aria-expanded': 'false', 'aria-controls': 'cmpCard',
    'aria-label': `${names.length} field(s) differ: ${names.join(', ')} - show side by side` },
    ...shown.map(n => el('span', { class: 'dchip', text: n })), names.length > shown.length ? el('span', { class: 'dchip more', text: `+${names.length - shown.length} more` }) : '');
  return hoverCardOn(b, () => hcShow(f, b));
}
// Any trigger: pointing at it (300 ms) or clicking / tapping it opens the card that show() fills - show may be async
// (it asks the server); from the keyboard the focus moves into the card, so its buttons can be reached.
function hoverCardOn(b, show) {
  let want = false;
  // show(still): still() is false once the pointer has left before an async show is ready - it then doesn't open.
  const open = async kbd => { want = true; await show(() => want); if (!want || hcFor !== b) return; if (kbd) { const first = $('cmpCard').querySelector('button'); if (first) first.focus(); } };
  b.addEventListener('mouseenter', () => { clearTimeout(hcCloseT); clearTimeout(hcOpenT); if (hcFor !== b) hcOpenT = setTimeout(() => open(false), 300); });
  b.addEventListener('mouseleave', () => { want = hcFor === b; clearTimeout(hcOpenT); hcLater(); });
  b.addEventListener('click', e => { e.stopPropagation(); clearTimeout(hcOpenT); open(e.detail === 0); });
  b.addEventListener('keydown', e => { if (e.key === 'Escape' && hcFor === b) { e.preventDefault(); e.stopPropagation(); hcClose(); } });
  return b;
}
let hcFor = null, hcOpenT = 0, hcCloseT = 0;
function hcCard() {
  let c = document.getElementById('cmpCard');
  if (c) return c;
  c = el('div', { class: 'hovercard', id: 'cmpCard', role: 'dialog', 'aria-label': 'What differs', hidden: true });
  c.addEventListener('mouseenter', () => clearTimeout(hcCloseT));
  c.addEventListener('mouseleave', hcLater);
  c.addEventListener('keydown', e => {
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); hcClose(true); return; }
    // Tab past its last button (or Shift+Tab before its first) goes back to what opened it - the card sits at the end
    // of the page, so tabbing on would jump far away from the row (2.38.12).
    if (e.key === 'Tab') {
      const f = [...c.querySelectorAll('button, [href], input, select, textarea')].filter(x => !x.disabled);
      if (!f.length || (!e.shiftKey && document.activeElement === f[f.length - 1]) || (e.shiftKey && document.activeElement === f[0])) { e.preventDefault(); hcClose(true); }
    }
  });
  c.addEventListener('focusout', e => { if (!c.contains(e.relatedTarget) && e.relatedTarget !== hcFor) hcLater(); });
  document.body.append(c);
  document.addEventListener('pointerdown', e => { if (!c.hidden && !c.contains(e.target) && !(hcFor && hcFor.contains(e.target))) hcClose(); });
  window.addEventListener('scroll', () => { if (!c.hidden && !c.contains(document.activeElement)) hcClose(); }, true);
  window.addEventListener('resize', () => hcClose());
  return c;
}
const hcLater = () => { clearTimeout(hcCloseT); hcCloseT = setTimeout(() => hcClose(), 200); };
function hcClose(refocus) {
  clearTimeout(hcOpenT); clearTimeout(hcCloseT);
  const c = document.getElementById('cmpCard');
  if (!c || c.hidden) return;
  const back = refocus && c.contains(document.activeElement) ? hcFor : null;
  c.hidden = true;
  if (hcFor) hcFor.setAttribute('aria-expanded', 'false');
  hcFor = null;
  if (back && back.isConnected) back.focus();
}
// One side's value, short: up to 4 lines of up to 160 characters, and how much more there is.
function hcValue(lines) {
  const keep = lines.slice(0, 4).map(l => l.length > 160 ? l.slice(0, 159) + '…' : l);
  const td = el('td', { class: 'v' }, keep.join('\n'));
  if (lines.length > 4) td.append(el('span', { class: 'more', text: `\n+${lines.length - 4} more line(s)` }));
  return td;
}
function hcShow(f, b) {
  const diffs = diffsOf(f);
  hcOpen(b, { title: `${f.app} - ${f.area}`, sub: `${diffs.length} field(s) differ · left is the catalog, right is Intune`, left: 'Catalog', right: 'Intune',
    rows: diffs.map(d => ({ field: d.field, left: d.local, right: d.remote })),
    buttons: [el('button', { type: 'button', class: 'btn small', text: 'Open full compare', onclick: () => { hcClose(); openCompare([f]); } }), ...cmpFixButtons(f, 'btn small', () => hcClose())] });
}
// The card itself: { title, sub, left, right (the column names), rows: [{ field, left, right }], note, buttons }.
function hcOpen(b, m) {
  const c = hcCard();
  if (hcFor && hcFor !== b) hcFor.setAttribute('aria-expanded', 'false');
  hcFor = b; b.setAttribute('aria-expanded', 'true');
  const blank = t => t === '(blank)' || t === '(none)';
  c.replaceChildren(
    el('header', {}, el('b', { text: m.title }), el('span', { text: m.sub || '' })),
    el('div', { class: 'hcbody' }, m.rows.length ? el('table', { class: 'hc' },
      el('thead', {}, el('tr', {}, el('th', { text: 'Field' }), el('th', { text: m.left }), el('th', { text: m.right }))),
      el('tbody', {}, ...m.rows.map(d => {
        const L = cmpLines(d.left), R = cmpLines(d.right);
        const wsOnly = L.join('\n').trim() === R.join('\n').trim();
        const field = el('td', { class: 'f', text: d.field || 'Value' }, wsOnly ? el('span', { class: 'more', text: ' (spaces only)' }) : '');
        // One line each and not too long: mark the part that differs; otherwise the lines as they are.
        if (L.length === 1 && R.length === 1 && L[0].length <= 300 && R[0].length <= 300 && !blank(L[0]) && !blank(R[0]))
          return el('tr', {}, field, cmpCell(L[0], R[0], 'del'), cmpCell(R[0], L[0], 'add'));
        const side = lines => blank(lines[0]) && lines.length === 1 ? el('td', { class: 'v' }, el('span', { class: 'more', text: lines[0] })) : hcValue(lines);
        return el('tr', {}, field, side(L), side(R));
      }))) : el('p', { class: 'hcempty muted', text: m.empty || 'Nothing to show.' })),
    el('footer', {}, el('span', { class: 'note', text: m.note || 'Long values are shortened here · Esc closes' }), ...(m.buttons || [])));
  c.hidden = false;
  // Below the trigger, inside the window; above it when there's no room below.
  const r = b.getBoundingClientRect(), w = c.offsetWidth, h = c.offsetHeight;
  const left = Math.max(16, Math.min(r.left, window.innerWidth - w - 16));
  let top = r.bottom + 6;
  if (top + h > window.innerHeight - 8 && r.top - h - 6 >= 8) top = r.top - h - 6;
  c.style.left = left + 'px'; c.style.top = Math.max(8, top) + 'px';
}

// Add to catalog: reads the Intune-only apps' settings and groups and adds them.
async function addFromIntune(list) {
  const items = list.map(f => ({ id: f.appId, name: f.app }));
  if (!items.length) return;
  if (!(await ask(`Add ${items.length === 1 ? `"${items[0].name}"` : items.length + ' apps'} from Intune to the catalog?\n\nEach one's settings and groups are read from Intune first. Nothing in Intune changes.`))) return;
  runDialog('Add to catalog', items.map(i => i.name).join(', '));
  runJob({ apps: items }, (ok, res, after) => {
    if (!ok || !after) return;
    const parts = [`Added ${after.added.length} app(s).`];
    if (after.skipped.length) parts.push(`Skipped: ${after.skipped.join('; ')}.`);
    if (after.noGroups.length) parts.push(`Groups couldn't be read for ${after.noGroups.join(', ')} - left empty.`);
    toast(parts.join(' '), !after.added.length);
    for (const f of list) if (after.added.includes(f.app)) dropFinding(f);
    loadApps(); checksRefresh(after.added);
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
  if (!(await ask(`Send the catalog's settings for ${names.length === 1 ? `"${names[0]}"` : names.length + ' apps'} to Intune?\n\nDescription, commands, detection rule, requirements, return codes and dependencies are replaced with the catalog's. No package is uploaded; groups aren't touched.`))) return;
  runDialog('Send settings to Intune', names.join(', '));
  const done = await runEach(names, name => ({ name, metadataOnly: true }), { path: '/api/deploy-start', log: 'runLog', startText: 'Pushing ' });
  toast(`Settings pushed for ${done.length} of ${names.length} app(s).`, done.length < names.length);
  for (const f of findings.filter(f => done.includes(f.catalogName) && (f.actions || []).includes('PushMetadata'))) dropFinding(f);
  loadApps(); checksRefresh(done);
}

// ---------------------------------------------------------------- winget search (Find Winget ID, Add app)
let wingetPick = null;
function openWinget(query, onPick) {
  if (wcResume('dlgWinget')) return;
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
  $('wgRows').replaceChildren(...r.rows.map(x => el('tr', {}, el('td', { text: x.name }), el('td', { class: 'chg wgid' }, ...String(x.id).split('.').flatMap((part, i, all) => i < all.length - 1 ? [part + '.', el('wbr')] : [part])), el('td', { text: x.version }), el('td', { text: x.source }),
    el('td', {}, el('button', { class: 'btn small', text: 'Use', onclick: () => { $('dlgWinget').close(); if (wingetPick) wingetPick(x.id, x); } })))));
}
$('btnWgSearch').addEventListener('click', searchWinget);
$('btnFindWinget').addEventListener('click', () => openWinget($('aName').value.trim() || $('aWinget').value.trim(), (id, x) => {
  $('aWinget').value = id;
  if (!$('aName').value.trim()) $('aName').value = x.name;
  if (!$('mPublisher').value.trim() && id.includes('.')) $('mPublisher').value = id.split('.')[0];
  // As if typed: the Ready list and the own-installer fields follow.
  $('aWinget').dispatchEvent(new Event('input', { bubbles: true }));
}));
$('wgQuery').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); searchWinget(); } });
$('btnRunChecksEmpty').addEventListener('click', () => $('btnRunChecks').click());

// 2.32.0: what Run checks reads, as one Options drop-down next to it (the two switches stay as they were).
{
  const box = el('details', { class: 'optsdrop' }, el('summary', { class: 'btn', text: 'Options', title: 'What Run checks reads: deployed apps in detail, winget' }), el('div', { class: 'optspanel' }));
  const panel = box.querySelector('.optspanel');
  for (const id of ['chkDetails', 'chkWinget']) { const l = $(id).closest('label'); l.classList.remove('inline'); panel.append(l); }
  $('btnRunChecks').after(box);
  document.addEventListener('click', e => { if (box.open && !box.contains(e.target)) box.open = false; });
  box.addEventListener('keydown', e => { if (e.key === 'Escape' && box.open) { e.stopPropagation(); box.open = false; box.querySelector('summary').focus(); } });
}
