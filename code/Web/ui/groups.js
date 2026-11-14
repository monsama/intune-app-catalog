// Intune App Catalog - web interface: the Groups page.
// Loaded after core.js (shared helpers and state); app.js starts the page.
'use strict';

// ---------------------------------------------------------------- groups
// groups: the catalog's groups; entra: name (lower case) -> id for those Entra ID has, or null while unknown.
// gSel: the names selected in the list (several with Ctrl/Shift); group: the one open on the right.
let groups = [], groupsLoaded = false, group = null, toAdd = new Map();
let entra = null, entraNote = '', gSel = new Set(), gLast = null, favs = [];
const ROLES = { requiredFor: 'Required', availableFor: 'Available', uninstallFor: 'Uninstall', excludeFor: 'Excluded' };
const roleField = role => Object.keys(ROLES).find(k => ROLES[k] === role);
const lc = s => String(s).toLowerCase();
const isFav = name => favs.some(f => lc(f) === lc(name));
const inEntra = name => entra ? entra.has(lc(name)) : null;
async function loadGroups() {
  groupsLoaded = true;
  const r = await api('/api/groups');
  if (!r.ok) { toast(r.error, true); return; }
  groups = r.groups || [];
  favs = r.favorites || [];
  const keep = new Set(groups.map(g => lc(g.name)));
  for (const n of [...gSel]) if (!keep.has(lc(n))) gSel.delete(n);
  renderGroupList();
  loadGroupsStatus();
}
async function loadGroupsStatus() {
  $('groupStatusNote').textContent = 'Checking Entra ID...';
  const r = await api('/api/groups-status');
  entra = null;
  if (r.ok && r.state === 'ok') {
    entra = new Map((r.found || []).map(f => [lc(f.name), f.id]));
    const missing = groups.filter(g => !entra.has(lc(g.name))).length;
    entraNote = missing ? `${missing} of ${groups.length} not in Entra ID` : groups.length ? 'All in Entra ID' : '';
  } else entraNote = r.ok && r.state === 'none' ? 'Not connected - Entra ID not checked' : 'Entra ID not checked: ' + (r.error || r.state || '');
  $('groupStatusNote').textContent = entraNote;
  $('groupStatusNote').title = entraNote;
  renderGroupList();
}
function visibleGroups() {
  const q = lc($('groupSearch').value.trim()), show = $('groupShow').value;
  return groups.filter(g => (!q || lc(g.name).includes(q)) && (!show || !entra || (show === 'missing') === !entra.has(lc(g.name))));
}
function renderGroupList() {
  const rows = visibleGroups();
  const open = group ? lc(group.name) : '';
  const isSel = n => [...gSel].some(x => lc(x) === lc(n));
  $('groupList').replaceChildren(...(rows.length ? rows.map(g => {
    const st = inEntra(g.name);
    const dot = el('span', { class: 'gdot ' + (st === null ? 'unknown' : st ? 'ok' : 'warn'), title: st === null ? 'Entra ID not checked' : st ? 'In Entra ID' : 'Not in Entra ID' });
    const roles = {}; for (const u of g.uses) roles[u.role] = (roles[u.role] || 0) + 1;
    const li = el('li', { role: 'option', 'data-g': g.name, class: lc(g.name) === open ? 'open' : '', 'aria-selected': String(isSel(g.name)),
      title: `${g.name}\n${st === null ? '' : st ? 'In Entra ID' : 'Not in Entra ID'}\n${Object.entries(roles).map(([r, n]) => `${r}: ${n}`).join(', ')}` },
      dot, el('span', { class: 'sr', text: st === null ? '' : st ? 'In Entra ID: ' : 'Not in Entra ID: ' }), el('span', { class: 'n', text: g.name }), isFav(g.name) ? el('span', { class: 'fav', title: 'A favourite - offered first wherever a group is chosen', text: '★' }) : '', el('span', { class: 'c', text: g.apps === 1 ? '1 app' : g.apps + ' apps' }));
    li.addEventListener('click', e => clickGroup(g.name, e));
    li.addEventListener('contextmenu', e => { e.preventDefault(); if (!isSel(g.name)) { gSel = new Set([g.name]); gLast = g.name; renderGroupList(); } openGroupMenu(e.clientX, e.clientY); });
    return li;
  }) : [el('li', { class: 'muted', role: 'option', 'aria-disabled': 'true', 'aria-selected': 'false', text: groups.length ? 'No match - Open looks the name up in Entra ID.' : 'No app is assigned to a group yet.' })]));
  renderGroupSelBar();
}
function clickGroup(name, e) {
  const rows = visibleGroups().map(g => g.name);
  if (e && e.shiftKey && gLast && rows.includes(gLast)) {
    const [a, b] = [rows.indexOf(gLast), rows.indexOf(name)].sort((x, y) => x - y);
    if (!(e.ctrlKey || e.metaKey)) gSel.clear();
    for (const n of rows.slice(a, b + 1)) gSel.add(n);
    renderGroupList(); return;
  }
  if (e && (e.ctrlKey || e.metaKey)) {
    const hit = [...gSel].find(x => lc(x) === lc(name));
    if (hit) gSel.delete(hit); else gSel.add(name);
    gLast = name; renderGroupList(); return;
  }
  gSel = new Set([name]); gLast = name;
  openGroup(name);
}
function renderGroupSelBar() {
  const sel = [...gSel];
  $('groupSelBar').hidden = sel.length < 2;
  if (sel.length < 2) return;
  $('groupSelCount').textContent = `${sel.length} selected`;
  const missing = entra ? sel.filter(n => !entra.has(lc(n))) : [];
  const found = entra ? sel.filter(n => entra.has(lc(n))) : sel;
  setEnabled($('btnGroupSelCreate'), missing.length > 0, entra ? 'Every selected group is in Entra ID already.' : 'Entra ID not checked - connect first.');
  $('btnGroupSelCreate').textContent = missing.length ? `Create ${missing.length}` : 'Create';
  setEnabled($('btnGroupSelDelete'), found.length > 0, 'None of the selected groups is in Entra ID.');
  $('btnGroupSelDelete').textContent = found.length ? `Delete ${found.length}...` : 'Delete...';
}
$('groupSearch').addEventListener('input', renderGroupList);
$('groupShow').addEventListener('change', renderGroupList);
$('groupSearch').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); $('btnGroupOpen').click(); } });
$('btnGroupOpen').addEventListener('click', () => { const n = $('groupSearch').value.trim(); if (n) { gSel = new Set([n]); openGroup(n); } else toast('Type a group name first.', true); });
$('btnGroupsReload').addEventListener('click', () => { loadGroups(); if (group) openGroup(group.name); });
$('btnGroupNew').addEventListener('click', async () => {
  const n = ((await askText('Name of the new security group\n\nNext shows it here first: add members and a description, then Create group creates it in Entra ID.', '', 'Next')) || '').trim();
  if (n) openGroup(n);
});
$('btnGroupSelClear').addEventListener('click', () => { gSel = group ? new Set([group.name]) : new Set(); renderGroupList(); });
$('btnGroupSelCreate').addEventListener('click', () => createGroups([...gSel].filter(n => entra && !entra.has(lc(n)))));
$('btnGroupSelDelete').addEventListener('click', () => deleteGroups([...gSel].filter(n => !entra || entra.has(lc(n)))));

// The list by keyboard: arrows move (Shift extends), Ctrl+A selects all, Delete deletes, Escape clears, the menu key opens the menu.
$('groupList').addEventListener('keydown', e => {
  const rows = visibleGroups().map(g => g.name);
  if (!rows.length) return;
  const cur = rows.findIndex(n => gLast && lc(n) === lc(gLast));
  const go = i => { const n = rows[Math.max(0, Math.min(rows.length - 1, i))]; if (e.shiftKey) { gSel.add(n); gLast = n; renderGroupList(); } else clickGroup(n); scrollGroupIntoView(n); };
  if (e.key === 'ArrowDown') { e.preventDefault(); go(cur + 1); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); go(cur < 0 ? 0 : cur - 1); }
  else if (e.key === 'Home') { e.preventDefault(); go(0); }
  else if (e.key === 'End') { e.preventDefault(); go(rows.length - 1); }
  else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'a') { e.preventDefault(); gSel = new Set(rows); renderGroupList(); }
  else if (e.key === 'Delete' && gSel.size) { e.preventDefault(); deleteGroups([...gSel].filter(n => !entra || entra.has(lc(n)))); }
  else if (e.key === 'Escape' && gSel.size > 1) { e.preventDefault(); $('btnGroupSelClear').click(); }
  else if (e.key === 'ContextMenu' || (e.shiftKey && e.key === 'F10')) {
    e.preventDefault();
    const li = document.querySelector(`#groupList li[aria-selected="true"]`) || $('groupList').firstElementChild;
    const r = li.getBoundingClientRect(); openGroupMenu(r.left + 20, r.bottom);
  }
});
function scrollGroupIntoView(n) { const li = [...document.querySelectorAll('#groupList li[data-g]')].find(x => lc(x.dataset.g) === lc(n)); if (li) li.scrollIntoView({ block: 'nearest' }); }

// ---------------------------------------------------------------- the group menu (right-click)
const gMenu = $('groupMenu');
function openGroupMenu(x, y) {
  const sel = [...gSel], one = sel.length === 1 ? sel[0] : null;
  const missing = entra ? sel.filter(n => !entra.has(lc(n))) : [];
  const found = entra ? sel.filter(n => entra.has(lc(n))) : sel;
  const used = sel.filter(n => groups.some(g => lc(g.name) === lc(n)));
  const b = act => gMenu.querySelector(`[data-gact=${act}]`);
  setEnabled(b('open'), !!one, 'Select exactly one group.');
  const allFav = sel.length && sel.every(isFav);
  b('fav').textContent = allFav ? (sel.length > 1 ? 'Remove from favourites' : 'Remove from favourites') : (sel.length > 1 ? `Add ${sel.length} to favourites` : 'Add to favourites');
  b('fav').dataset.mode = allFav ? 'remove' : 'add';
  b('copy').textContent = sel.length > 1 ? `Copy ${sel.length} names` : 'Copy name';
  setEnabled(b('assign'), !!one, 'Select exactly one group.');
  setEnabled(b('create'), missing.length > 0, entra ? (sel.length > 1 ? 'Every selected group is in Entra ID already.' : 'This group is in Entra ID already.') : 'Entra ID not checked - connect first.');
  b('create').textContent = missing.length > 1 ? `Create ${missing.length} in Entra ID` : 'Create in Entra ID';
  setEnabled(b('rename'), !!one && (!entra || entra.has(lc(one))), one ? 'This group isn\'t in Entra ID - rename it in the apps instead (Batch edit).' : 'Select exactly one group.');
  setEnabled(b('replace'), !!one && used.length > 0, one ? 'No app in the catalog uses this group.' : 'Select exactly one group.');
  setEnabled(b('unassign'), used.length > 0, 'No app in the catalog uses these groups.');
  b('unassign').textContent = used.length > 1 ? `Remove ${used.length} groups from all apps...` : 'Remove from all apps...';
  setEnabled(b('delete'), found.length > 0, sel.length > 1 ? 'None of the selected groups is in Entra ID.' : 'This group isn\'t in Entra ID.');
  b('delete').textContent = found.length > 1 ? `Delete ${found.length} from Entra ID...` : 'Delete from Entra ID...';
  gMenu.hidden = false;
  const r = gMenu.getBoundingClientRect();
  gMenu.style.left = Math.min(x, innerWidth - r.width - 8) + 'px';
  gMenu.style.top = Math.min(y, innerHeight - r.height - 8) + 'px';
  const first = gMenu.querySelector('button:not(:disabled)'); if (first) first.focus();
}
document.addEventListener('click', e => { if (!gMenu.contains(e.target)) gMenu.hidden = true; });
document.addEventListener('keydown', e => { if (e.key === 'Escape' && !gMenu.hidden) { gMenu.hidden = true; $('groupList').focus(); } });
gMenu.addEventListener('click', async e => {
  const b = e.target.closest('button'); if (!b || b.disabled) return;
  gMenu.hidden = true;
  const sel = [...gSel];
  switch (b.dataset.gact) {
    case 'open': openGroup(sel[0]); break;
    case 'copy': try { await navigator.clipboard.writeText(sel.join('\n')); toast(sel.length > 1 ? `Copied ${sel.length} names.` : 'Copied ' + sel[0]); } catch (err) { toast('Could not copy.', true); } break;
    case 'assign': if (!group || lc(group.name) !== lc(sel[0])) await openGroup(sel[0]); openAssign(); break;
    case 'create': createGroups(sel.filter(n => entra && !entra.has(lc(n)))); break;
    case 'rename': if (!group || lc(group.name) !== lc(sel[0])) await openGroup(sel[0]); $('btnGroupRename').click(); break;
    case 'replace': openReplace({ old: sel[0] }); break;
    case 'fav': {
      const next = b.dataset.mode === 'remove' ? favs.filter(f => !sel.some(n => lc(n) === lc(f))) : favs.concat(sel.filter(n => !isFav(n)));
      const r = await api('/api/prefs-save', { favoriteGroups: next });
      if (!r.ok) { toast(r.error, true); break; }
      favs = next; loadPrefs(); renderGroupList();
      toast(b.dataset.mode === 'remove' ? 'Removed from the favourites.' : 'Added to the favourites - offered first wherever a group is chosen.');
      break;
    }
    case 'unassign': unassignGroups(sel.filter(n => groups.some(g => lc(g.name) === lc(n)))); break;
    case 'delete': deleteGroups(sel.filter(n => !entra || entra.has(lc(n)))); break;
  }
});

// ---------------------------------------------------------------- actions on several groups
// Creates each missing group in Entra ID (as a security group, no members), one step each, in the Run dialog.
async function createGroups(names, onDone) {
  if (!names.length) return;
  if (!(await ask(`Create ${names.length === 1 ? `"${names[0]}"` : names.length + ' groups'} in Entra ID?\n\n${names.length > 1 ? names.join('\n') + '\n\n' : ''}Each becomes an empty security group with exactly this name. Add members on the Groups page; push the apps' groups to Intune once they are deployed.`, { ok: 'Create' }))) return;
  runDialog('Create groups in Entra ID', names.join(', '));
  const done = await runEach(names, name => ({ mode: 'Save', name, description: '', memberIds: [] }), { path: '/api/group-job', log: 'runLog', startText: 'Creating ' });
  toast(`Created ${done.length} of ${names.length} group(s) in Entra ID.`, done.length < names.length);
  if (onDone) onDone(done);
  if (groupsLoaded) { await loadGroups(); if (group && done.some(n => lc(n) === lc(group.name))) openGroup(group.name); }
}
async function deleteGroups(names) {
  if (!names.length) return;
  const uses = names.reduce((n, x) => n + ((groups.find(g => lc(g.name) === lc(x)) || { apps: 0 }).apps), 0);
  if (!(await ask(`Delete ${names.length === 1 ? `the group "${names[0]}"` : names.length + ' groups'} from Entra ID?\n\n${names.length > 1 ? names.join('\n') + '\n\n' : ''}${uses ? `Catalog apps name ${names.length === 1 ? 'it' : 'them'} ${uses} time(s) - those assignments stop reaching anyone, and the catalog keeps naming groups that are gone (Remove from all apps takes them off).` : 'No app in the catalog uses them.'} This can't be undone here.`))) return;
  runDialog('Delete groups from Entra ID', names.join(', '));
  runJob({ mode: 'DeleteMany', names }, ok => {
    toast(ok ? `Deleted ${names.length} group(s).` : 'Not every group was deleted - see the log.', !ok);
    if (group && names.some(n => lc(n) === lc(group.name))) openGroup(group.name);
    loadGroups();
  }, { path: '/api/group-job', log: 'runLog', startText: `Deleting ${names.length} group(s)...` });
}
// Takes groups off every catalog app that names them, in every role. Entra ID and Intune don't change.
async function unassignGroups(names) {
  if (!names.length) return;
  const users = [...new Set(groups.filter(g => names.some(n => lc(n) === lc(g.name))).flatMap(g => g.uses.map(u => u.app)))];
  if (!(await ask(`Remove ${names.length === 1 ? `"${names[0]}"` : names.length + ' groups'} from ${users.length} app(s) in the catalog?\n\n${names.length > 1 ? names.join('\n') + '\n\n' : ''}Every assignment to ${names.length === 1 ? 'it' : 'them'} goes: Required, Available, Uninstall and Excluded. Entra ID keeps the group${names.length === 1 ? '' : 's'}; Intune changes when you send groups. Each app's file is backed up first.`))) return;
  const roles = {}; for (const k of Object.keys(ROLES)) roles[k] = names;
  const r = await api('/api/batch-groups', { mode: 'remove', names: users, roles });
  if (!r.ok) { toast(r.error, true); return; }
  toast(`Removed from ${r.changed.length} app(s) in the catalog.${r.deployed.length ? ` ${r.deployed.length} of them are in Intune - push their groups.` : ''}`);
  gSel.clear(); loadApps(); await loadGroups();
  if (group) openGroup(group.name);
  if (r.deployed.length && await ask(`Send groups for the ${r.deployed.length} deployed app(s) now?\n\n${r.deployed.join('\n')}`, { ok: 'Send groups', danger: false })) openPushGroups(r.deployed);
}

// ---------------------------------------------------------------- one group
function setGroupBusy(on) {
  for (const id of ['btnGroupRename', 'btnGroupDelete', 'btnGroupSave', 'btnGroupFind', 'btnGroupCreate']) {
    const needsGroup = !['btnGroupSave', 'btnGroupFind', 'btnGroupCreate'].includes(id);
    setEnabled($(id), !on && !(needsGroup && !(group && group.found)), on ? 'Working...' : 'This group doesn\'t exist in Entra ID yet - Create it first.');
  }
}
async function openGroup(name) {
  $('groupEmpty').hidden = true; $('groupDetail').hidden = false; $('groupLog').hidden = true;
  group = { name, found: false, uses: [] }; toAdd = new Map(); renderAdd(); $('gHits').replaceChildren(); $('gFindNote').textContent = '';
  if (![...gSel].some(x => lc(x) === lc(name))) { gSel = new Set([name]); gLast = name; }
  renderGroupList();
  $('gName').textContent = name; $('gState').className = 'pill muted'; $('gState').textContent = 'Reading...';
  $('gNote').textContent = ''; $('gMissing').hidden = true; $('gDesc').value = ''; $('gMembers').replaceChildren(); $('gCount').textContent = '';
  const local = groups.find(g => lc(g.name) === lc(name));
  renderUses(local ? local.uses : []);
  setGroupBusy(true);
  const r = await api('/api/group-get', { name });
  if (!group || group.name !== name) return;
  if (!r.ok) {
    $('gState').className = 'pill err'; $('gState').textContent = 'Not read';
    setGroupBusy(false);
    $('gNote').textContent = r.error; setEnabled($('btnGroupSave'), false, r.error); setEnabled($('btnGroupCreate'), false, r.error); return;
  }
  group = r;
  if (entra) { if (r.found) entra.set(lc(name), r.id); else entra.delete(lc(name)); renderGroupList(); }
  $('gState').className = 'pill ' + (r.found ? 'ok' : 'warn');
  $('gState').textContent = r.found ? 'In Entra ID' : 'Not in Entra ID';
  $('gNote').textContent = !r.found ? ''
    : r.duplicates > 1 ? `${r.duplicates} groups have this exact name - this shows the first. Intune can't tell them apart by name; rename the others in Entra ID.` : `Object ID ${r.id}`;
  $('gNote').hidden = !$('gNote').textContent;
  $('gMissing').hidden = r.found;
  $('gMissingText').textContent = r.uses.length
    ? `Entra ID has no group with this exact name, so ${r.uses.length === 1 ? 'the assignment below reaches' : `the ${r.uses.length} assignments below reach`} nobody. Create it as a security group - add members on the right first if you like.`
    : 'Entra ID has no group with this exact name. Create it as a security group - add members on the right first if you like.';
  $('gDesc').value = r.description || '';
  $('gCount').textContent = r.found ? `(${r.members.length})` : '';
  $('gMembers').replaceChildren(...(r.members.length ? r.members.map(m => el('tr', {}, el('td', { text: m.name }), el('td', { text: m.type }), el('td', { class: 'chg', text: m.upn }),
    el('td', {}, (() => { const b = el('button', { class: 'btn small danger', text: 'Remove', title: `Remove ${m.name} from this group in Entra ID` }); b.addEventListener('click', () => removeMember(m)); return b; })())))
    : [el('tr', {}, el('td', { class: 'muted', colspan: '4', text: r.found ? 'No members yet - search below to add people, devices or groups.' : 'Not created yet. People you add below become members when it is created.' }))]));
  renderUses(r.uses);
  saveLabel();
  $('btnGroupSave').hidden = !r.found && !toAdd.size;
  setGroupBusy(false);
}

// The catalog apps assigned to the open group: a table with each app's assignment, whether it is in the tenant, and Remove.
function renderUses(uses) {
  group.uses = uses;
  const q = lc($('gUsesFilter').value.trim());
  const count = {}; for (const u of uses) count[u.role] = (count[u.role] || 0) + 1;
  $('gAppsCount').textContent = uses.length ? `(${new Set(uses.map(u => u.app)).size})` : '';
  $('gRoles').replaceChildren(...Object.values(ROLES).filter(r => count[r]).map(r => el('span', { class: 'pill ' + (r === 'Excluded' || r === 'Uninstall' ? 'muted' : 'info'), text: `${r} ${count[r]}` })));
  $('gUsesFilter').hidden = uses.length < 8;
  const rows = uses.filter(u => !q || lc(u.app).includes(q));
  const tenant = u => {
    const a = typeof apps !== 'undefined' ? apps.find(x => x.name === u.app) : null;
    const t = a ? tenantState(a) : '';
    return t === 'present' ? el('span', { class: 'pill ok', text: 'Deployed' }) : t === 'missing' ? el('span', { class: 'pill warn', text: 'Not in this tenant' })
      : t === 'unchecked' ? el('span', { class: 'pill muted', text: 'Has App ID' }) : el('span', { class: 'muted', text: 'Not deployed' });
  };
  $('gUses').replaceChildren(...(rows.length ? rows.map(u => {
    const open = el('button', { class: 'linkbtn', text: u.app, title: `Open ${u.app} in the editor` }); open.addEventListener('click', () => openEditor(u.app));
    const rm = el('button', { class: 'btn small', text: 'Remove', title: `Take this group off ${u.app}'s ${u.role} list in the catalog` }); rm.addEventListener('click', () => unassignOne(u));
    return el('tr', {}, el('td', {}, open), el('td', {}, el('span', { class: 'pill ' + (u.role === 'Excluded' || u.role === 'Uninstall' ? 'muted' : 'info'), text: u.role })), el('td', {}, tenant(u)), el('td', { class: 'act' }, rm));
  }) : [el('tr', {}, el('td', { class: 'muted', colspan: '4', text: uses.length ? 'No app matches the filter.' : 'No app in the catalog is assigned to this group. Assign apps... adds some.' }))]));
  const deployed = [...new Set(uses.map(u => apps.find(x => x.name === u.app)).filter(a => a && tenantState(a) === 'present').map(a => a.name))];
  $('gPushNote').textContent = !uses.length ? '' : deployed.length ? `Changes here are in the catalog; ${deployed.length} of these apps are in Intune.` : 'Changes here are in the catalog. None of these apps is in Intune yet - they get the group when deployed.';
  setEnabled($('btnGroupPush'), deployed.length > 0, 'None of these apps is deployed to this tenant.');
  $('btnGroupPush').onclick = () => openPushGroups(deployed);
  $('btnGroupPush').hidden = !uses.length;
}
$('gUsesFilter').addEventListener('input', () => group && renderUses(group.uses || []));
async function unassignOne(u) {
  const name = group.name, field = roleField(u.role);
  if (!(await ask(`Remove ${name} from ${u.app}?\n\nOnly its ${u.role} assignment in the catalog changes. Intune changes when you send groups.`))) return;
  const r = await api('/api/batch-groups', { mode: 'remove', names: [u.app], roles: { [field]: [name] } });
  if (!r.ok) { toast(r.error, true); return; }
  toast(r.deployed.length ? `Removed. ${u.app} is in Intune - push its groups to apply.` : 'Removed from the app in the catalog.');
  loadApps(); await loadGroups(); openGroup(name);
}
function openAssign() {
  if (!group) return;
  $('gaTitle').textContent = `Assign apps to ${group.name}`;
  const pick = () => {
    const field = $('gaRole').value, have = new Set((group.uses || []).filter(u => u.role === ROLES[field]).map(u => u.app));
    appPicker($('gaPick'), apps.map(a => a.name).filter(n => !have.has(n)).sort((a, b) => a.localeCompare(b)), new Set(), 'data-ga', 'None ticked yet.', 'Assigning:');
  };
  $('gaRole').onchange = pick; pick();
  $('dlgGroupAssign').showModal();
}
$('btnGroupAssign').addEventListener('click', openAssign);
$('btnGroupAssignGo').addEventListener('click', async () => {
  const names = [...document.querySelectorAll('[data-ga]')].filter(c => c.checked).map(c => c.dataset.ga);
  if (!names.length) { toast('Tick at least one app.', true); return; }
  const name = group.name, field = $('gaRole').value;
  const r = await api('/api/batch-groups', { mode: 'add', names, roles: { [field]: [name] } });
  if (!r.ok) { toast(r.error, true); return; }
  $('dlgGroupAssign').close();
  toast(`${name} added to ${r.changed.length} app(s) as ${ROLES[field]}.${r.deployed.length ? ` ${r.deployed.length} are in Intune - push their groups to apply.` : ''}`);
  loadApps(); await loadGroups(); openGroup(name);
});
$('btnGroupCopy').addEventListener('click', async () => { try { await navigator.clipboard.writeText(group.name); toast('Copied ' + group.name); } catch (e) { toast('Could not copy.', true); } });
$('btnGroupCreate').addEventListener('click', () => $('btnGroupSave').click());
// The save button says what it will do: create, add N members, or save the description.
function saveLabel() {
  if (!group) return;
  const n = toAdd.size, m = `${n} member${n === 1 ? '' : 's'}`;
  $('btnGroupSave').textContent = !group.found ? (n ? `Create group with ${m}` : 'Create group') : n ? `Add ${m} and save` : 'Save description';
}
$('gDesc').addEventListener('input', saveLabel);
function renderAdd() {
  if (group && !group.found) $('btnGroupSave').hidden = !toAdd.size;
  saveLabel();
  $('gAddCount').textContent = toAdd.size ? `(${toAdd.size})` : '';
  $('gAdd').replaceChildren(...(toAdd.size ? [...toAdd.values()].map(m => {
    const b = el('button', { class: 'btn small', text: 'Remove' }); b.addEventListener('click', () => { toAdd.delete(m.id); renderAdd(); });
    return el('li', {}, el('span', { class: 'n', text: m.name + (m.upn ? ` (${m.upn})` : '') }), el('span', { class: 'muted', text: m.type }), b);
  }) : [el('li', { class: 'muted', text: 'Nobody yet - search above and Add.' })]));
}
async function findMembers() {
  const q = $('gFind').value.trim();
  if (q.length < 2) { $('gFindNote').textContent = 'Type at least 2 letters.'; return; }
  $('gFindNote').textContent = 'Searching...';
  const r = await api('/api/directory-search', { q });
  if (!r.ok) { $('gFindNote').textContent = r.error; return; }
  const have = new Set((group.members || []).map(m => m.id));
  $('gFindNote').textContent = (r.hits.length ? '' : 'Nothing found. ') + (r.notes || []).join(' ');
  $('gHits').replaceChildren(...r.hits.map(h => {
    const b = el('button', { class: 'btn small', text: have.has(h.id) ? 'Member' : toAdd.has(h.id) ? 'Added' : 'Add' });
    b.disabled = have.has(h.id) || toAdd.has(h.id) || (group.id && h.id === group.id);
    b.addEventListener('click', () => { toAdd.set(h.id, h); b.textContent = 'Added'; b.disabled = true; renderAdd(); });
    return el('li', {}, el('span', { class: 'n', text: h.name + (h.upn ? ` (${h.upn})` : '') }), el('span', { class: 'muted', text: h.type }), b);
  }));
}
$('btnGroupFind').addEventListener('click', findMembers);
$('gFind').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); findMembers(); } });

function groupJob(body, title, onOk) {
  $('groupLog').hidden = false; $('groupLog').textContent = '';
  return runJob(body, (ok, res, after) => { if (ok) onOk(after); }, { path: '/api/group-job', log: 'groupLog', startText: title });
}
$('btnGroupSave').addEventListener('click', () => {
  if (!group) return;
  const name = group.name;
  groupJob({ mode: 'Save', name, description: $('gDesc').value, memberIds: [...toAdd.keys()] }, `${group.found ? 'Updating' : 'Creating'} ${name}...`,
    () => { toast(`${name} is ready.`); loadGroups(); openGroup(name); });
});
async function removeMember(m) {
  if (!(await ask(`Remove ${m.name} from ${group.name}?\n\nApps assigned to this group stop applying to it.`))) return;
  const name = group.name;
  groupJob({ mode: 'RemoveMember', name, groupId: group.id, memberId: m.id }, `Removing ${m.name}...`, () => { toast('Removed.'); openGroup(name); });
}
$('btnGroupRename').addEventListener('click', async () => {
  if (!group || !group.found) return;
  const old = group.name;
  const nn = ((await askText(`New name for "${old}"\n\nEntra ID renames the group (same group, same members), then every app in the catalog that names it follows.`, old, 'Rename')) || '').trim();
  if (!nn || nn === old) return;
  groupJob({ mode: 'Rename', name: old, groupId: group.id, newName: nn }, `Renaming ${old}...`, after => {
    const n = after && after.updated ? after.updated.length : 0;
    toast(`Renamed to ${nn}; ${n} app(s) in the catalog updated.`); $('groupSearch').value = ''; loadGroups(); loadApps(); openGroup(nn);
  });
});
$('btnGroupDelete').addEventListener('click', () => { if (group && group.found) deleteGroups([group.name]); });
$('btnGroupsDelete').addEventListener('click', () => {
  $('gDelLog').hidden = true; $('gDelLog').textContent = ''; $('gDelMore').value = '';
  $('gDelList').replaceChildren(...(groups.length ? groups.map(g => el('label', { class: 'chk' }, el('input', { type: 'checkbox', 'data-gdel': g.name }), `${g.name} `, el('span', { class: 'muted', text: `(${g.apps} app${g.apps === 1 ? '' : 's'})` })))
    : [el('span', { class: 'muted', text: 'No catalog groups - type names below.' })]));
  $('dlgGroupsDelete').showModal();
});
$('btnGroupsDeleteGo').addEventListener('click', async () => {
  const names = [...new Set([...document.querySelectorAll('[data-gdel]')].filter(c => c.checked).map(c => c.dataset.gdel).concat(lines('gDelMore')))];
  if (!names.length) { toast('Tick or type at least one group.', true); return; }
  if (!(await ask(`Delete ${names.length} group(s) from Entra ID?\n\n${names.join('\n')}\n\nApps assigned to them lose those assignments. This can't be undone here.`))) return;
  $('gDelLog').hidden = false;
  runJob({ mode: 'DeleteMany', names }, ok => { toast(ok ? `Deleted ${names.length} group(s).` : 'Not every group was deleted - see the log.', !ok); loadGroups(); },
    { path: '/api/group-job', log: 'gDelLog', startText: `Deleting ${names.length} group(s)...` });
});
