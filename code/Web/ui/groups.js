// Intune App Catalog - web interface: the Groups page.
// Loaded after core.js (shared helpers and state); app.js starts the page.
'use strict';

// ---------------------------------------------------------------- groups
let groups = [], groupsLoaded = false, group = null, toAdd = new Map();
async function loadGroups() {
  groupsLoaded = true;
  const r = await api('/api/groups');
  if (!r.ok) { toast(r.error, true); return; }
  groups = r.groups || [];
  renderGroupList();
}
function renderGroupList() {
  const q = $('groupSearch').value.trim().toLowerCase();
  const rows = groups.filter(g => !q || g.name.toLowerCase().includes(q));
  $('groupList').replaceChildren(...(rows.length ? rows.map(g => {
    const li = el('li', { role: 'option', 'aria-selected': String(!!group && group.name.toLowerCase() === g.name.toLowerCase()), title: g.uses.map(u => `${u.app} (${u.role})`).join('\n') },
      el('span', { class: 'n', text: g.name }), el('span', { class: 'c', text: g.apps === 1 ? '1 app' : g.apps + ' apps' }));
    li.addEventListener('click', () => openGroup(g.name));
    return li;
  }) : [el('li', { class: 'muted', role: 'option', 'aria-disabled': 'true', 'aria-selected': 'false', text: groups.length ? 'No match - Open looks the name up in Entra ID.' : 'No app is assigned to a group yet.' })]));
}
$('groupSearch').addEventListener('input', renderGroupList);
$('groupSearch').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); $('btnGroupOpen').click(); } });
$('btnGroupOpen').addEventListener('click', () => { const n = $('groupSearch').value.trim(); if (n) openGroup(n); else toast('Type a group name first.', true); });
$('btnGroupsReload').addEventListener('click', () => { loadGroups(); if (group) openGroup(group.name); });
$('btnGroupNew').addEventListener('click', async () => {
  const n = ((await askText('Name of the new security group', '', 'Open')) || '').trim();
  if (n) openGroup(n);
});

function setGroupBusy(on) {
  for (const id of ['btnGroupRename', 'btnGroupDelete', 'btnGroupSave', 'btnGroupFind']) {
    const needsGroup = id !== 'btnGroupSave' && id !== 'btnGroupFind';
    setEnabled($(id), !on && !(needsGroup && !(group && group.found)), on ? 'Working...' : 'This group doesn\'t exist in Entra ID yet - Create it first.');
  }
}
async function openGroup(name) {
  $('groupEmpty').hidden = true; $('groupDetail').hidden = false; $('groupLog').hidden = true;
  group = { name, found: false }; toAdd = new Map(); renderAdd(); $('gHits').replaceChildren(); $('gFindNote').textContent = '';
  renderGroupList();
  $('gName').textContent = name; $('gState').className = 'pill muted'; $('gState').textContent = 'Reading...';
  $('gNote').textContent = ''; $('gDesc').value = ''; $('gMembers').replaceChildren(); $('gCount').textContent = ''; $('gUses').replaceChildren();
  setGroupBusy(true);
  const r = await api('/api/group-get', { name });
  if (!group || group.name !== name) return;
  if (!r.ok) {
    $('gState').className = 'pill err'; $('gState').textContent = 'Not read';
    $('gNote').textContent = r.error; $('btnGroupSave').disabled = true; return;
  }
  group = r;
  $('gState').className = 'pill ' + (r.found ? 'ok' : 'warn');
  $('gState').textContent = r.found ? 'In Entra ID' : 'Not in Entra ID';
  $('gNote').textContent = !r.found ? 'No group with this exact name exists yet - Create / update group creates it as a security group.'
    : r.duplicates > 1 ? `${r.duplicates} groups have this exact name - this shows the first. Intune can't tell them apart by name; rename the others in Entra ID.` : `Object ID ${r.id}`;
  $('gDesc').value = r.description || '';
  $('gCount').textContent = r.found ? `(${r.members.length})` : '';
  $('gMembers').replaceChildren(...(r.members.length ? r.members.map(m => el('tr', {}, el('td', { text: m.name }), el('td', { text: m.type }), el('td', { class: 'chg', text: m.upn }),
    el('td', {}, (() => { const b = el('button', { class: 'btn small danger', text: 'Remove' }); b.addEventListener('click', () => removeMember(m)); return b; })())))
    : [el('tr', {}, el('td', { class: 'muted', colspan: '4', text: r.found ? 'No members.' : '-' }))]));
  $('gUses').replaceChildren(...(r.uses.length ? r.uses.map(u => el('li', { text: `${u.app} - ${u.role}` })) : [el('li', { class: 'muted', text: 'No app in the catalog uses this group.' })]));
  $('btnGroupSave').textContent = r.found ? 'Update group' : 'Create group';
  setGroupBusy(false);
}
function renderAdd() {
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
$('btnGroupDelete').addEventListener('click', async () => {
  if (!group || !group.found) return;
  const name = group.name, uses = (group.uses || []).length;
  if (!(await ask(`Delete the group "${name}" from Entra ID?\n\n${uses ? `${uses} catalog assignment(s) name it - those apps lose this assignment in Intune, and the catalog keeps naming a group that is gone.` : 'No app in the catalog uses it.'} This can't be undone here.`))) return;
  groupJob({ mode: 'Delete', name }, `Deleting ${name}...`, () => { toast(`${name} was deleted.`); group = null; $('groupDetail').hidden = true; $('groupEmpty').hidden = false; loadGroups(); });
});
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
