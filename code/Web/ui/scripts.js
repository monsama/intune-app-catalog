// Intune App Catalog - web interface: the Platform scripts page.
// Loaded after core.js (shared helpers and state); app.js starts the page.
'use strict';

// ---------------------------------------------------------------- platform scripts
let scripts = [], scriptsLoaded = false, scriptSel = null, scriptOrig = null;
async function loadScripts() {
  scriptsLoaded = true;
  $('scriptNote').textContent = 'Reading the scripts...';
  const r = await api('/api/scripts');
  if (!r.ok) { $('scriptNote').textContent = r.error; return; }
  scripts = r.rows || [];
  const notes = [r.tenantRead ? 'PowerShell scripts Intune runs on enrolled Windows devices, with the local copies kept beside the catalog.' : r.tenantError];
  if (r.localErrors && r.localErrors.length) notes.push('Unreadable local files: ' + r.localErrors.join('; '));
  $('scriptNote').textContent = notes.join(' ');
  $('scriptNote').className = 'sub' + (r.tenantRead ? '' : ' warntext');
  $('btnScriptsSave').disabled = !r.tenantRead;
  if (scriptSel && !scripts.some(x => x.displayName === scriptSel.displayName && x.id === scriptSel.id)) scriptSel = null;
  renderScripts();
}
function renderScripts() {
  const q = $('scriptSearch').value.trim().toLowerCase();
  const rows = scripts.filter(x => !q || (x.displayName + ' ' + x.fileName + ' ' + x.description).toLowerCase().includes(q));
  const pill = t => el('span', { class: 'pill ' + (t === 'Saved' ? 'ok' : /^Differs/.test(t) ? 'warn' : /^Local/.test(t) ? 'info' : 'muted'), text: t });
  $('scriptBody').replaceChildren(...rows.map(x => {
    const tr = el('tr', { 'aria-selected': String(scriptSel === x), title: x.description || x.displayName },
      el('td', { text: x.displayName }), el('td', { class: 'mono', text: x.fileName }), el('td', { text: x.runAs }), el('td', { text: x.runAs32Bit }),
      el('td', { text: x.signature }), el('td', { text: x.modified }), el('td', {}, pill(x.local)));
    tr.addEventListener('click', () => { scriptSel = x; renderScripts(); });
    tr.addEventListener('dblclick', () => { scriptSel = x; openScript(x); });
    return tr;
  }));
  $('scriptCount').textContent = `${rows.length} of ${scripts.length}`;
  $('scriptEmpty').hidden = scripts.length > 0;
  $('btnScriptEdit').disabled = !scriptSel;
  $('btnScriptDelete').disabled = !scriptSel;
  $('btnScriptStatus').disabled = !scriptSel || !scriptSel.id;
}
$('scriptSearch').addEventListener('input', renderScripts);
$('btnScriptsReload').addEventListener('click', loadScripts);
$('btnScriptsFolder').addEventListener('click', async () => { const r = await api('/api/open', { target: 'scripts-folder' }); if (!r.ok) toast(r.error, true); });
$('btnScriptNew').addEventListener('click', () => openScript(null));
$('btnScriptEdit').addEventListener('click', () => scriptSel && openScript(scriptSel));
$('btnScriptStatus').addEventListener('click', () => scriptSel && openScriptStatus(scriptSel));
$('btnScriptsSave').addEventListener('click', async () => {
  const b = $('btnScriptsSave'); b.disabled = true; toast('Reading every script in full...');
  const r = await api('/api/scripts-save-local');
  b.disabled = false;
  if (!r.ok) { toast(r.error, true); return; }
  toast(r.message + (r.failed && r.failed.length ? ` ${r.failed.length} could not be read - see Activity.` : ''), r.failed && r.failed.length);
  loadScripts();
});
$('btnScriptDelete').addEventListener('click', async () => {
  const x = scriptSel; if (!x) return;
  if (!x.id) {
    if (!confirm(`Delete the local copy of "${x.displayName}"?\n\nThis script isn't in Intune${x.local === 'Local copy' ? ' (or Intune was not read)' : ''}, so only the file goes.`)) return;
    const r = await api('/api/script-delete', { name: x.displayName });
    toast(r.ok ? 'Local copy deleted.' : r.error, !r.ok); scriptSel = null; loadScripts(); return;
  }
  if (!confirm(`Permanently delete the platform script "${x.displayName}" from Intune?\n\nDevices that already ran it keep whatever it did - Intune only stops running it. Any local copy stays.`)) return;
  runDialog('Delete platform script', x.displayName);
  runJob({ id: x.id, name: x.displayName }, ok => { toast(ok ? `${x.displayName} was deleted from Intune.` : 'Delete failed - see the log.', !ok); scriptSel = null; loadScripts(); },
    { path: '/api/script-delete', log: 'runLog', startText: `Deleting ${x.displayName}...` });
});

function fillScript(s) {
  $('sName').value = s.displayName || ''; $('sDescription').value = s.description || ''; $('sFile').value = s.fileName || '';
  $('sRunAs').value = s.runAsAccount === 'user' ? 'user' : 'system'; $('s32').checked = !!s.runAs32Bit; $('sSig').checked = !!s.enforceSignatureCheck;
  $('sGroups').value = (s.groups || []).join('\n'); $('sContent').value = s.scriptContent || '';
  // Groups that couldn't be read must not be sent as "none" - that would remove every assignment.
  $('sAssign').checked = s.groupsKnown !== false && !!(s.groups && s.groups.length);
  $('sAssign').disabled = s.groupsKnown === false;
  $('sAssignNote').textContent = s.groupsKnown === false ? "The script's groups couldn't be read, so they can't be sent - fix the Group.Read.All permission, then reopen." : "Replaces the script's assignments in Intune - an empty list removes them all.";
}
async function openScript(row) {
  $('scriptErr').hidden = true; $('scriptLog').hidden = true; $('scriptLog').textContent = '';
  scriptOrig = row ? { id: row.id, name: row.displayName } : { id: '', name: '' };
  $('scriptTitle').textContent = row ? row.displayName : 'New platform script';
  $('scriptWhere').textContent = row ? (row.id ? 'In Intune' + (row.local !== 'Not saved here' ? ' - a local copy is kept too.' : '.') : 'Only a local copy - Save to Intune creates it there.') : 'Save locally to keep it as a draft, or Save to Intune to create it there.';
  $('btnScriptIntune').textContent = row && row.id ? 'Save to Intune' : 'Create in Intune';
  fillScript({ runAsAccount: 'system' });
  $('dlgScript').showModal();
  if (row) {
    $('sContent').value = 'Loading...';
    const r = await api('/api/script-get', row.id ? { id: row.id } : { name: row.displayName });
    if (!r.ok) { $('sContent').value = ''; $('scriptErr').textContent = 'Could not load the script: ' + r.error; $('scriptErr').hidden = false; return; }
    fillScript(r.script);
  }
}
$('sLoad').addEventListener('change', async e => {
  const f = e.target.files[0]; if (!f) return;
  if (f.size > 200000) { toast('That file is larger than the 200 KB Intune accepts.', true); return; }
  $('sContent').value = (await f.text()).replace(/^﻿/, '');
  if (!$('sFile').value) $('sFile').value = f.name;
  e.target.value = '';
});
function readScript() {
  return { id: scriptOrig.id, displayName: $('sName').value, description: $('sDescription').value, fileName: $('sFile').value, runAsAccount: $('sRunAs').value,
    runAs32Bit: $('s32').checked, enforceSignatureCheck: $('sSig').checked, scriptContent: $('sContent').value, groups: lines('sGroups') };
}
async function saveScript(destination) {
  $('scriptErr').hidden = true;
  const body = { script: readScript(), originalName: scriptOrig.name, destination, assignGroups: $('sAssign').checked && !$('sAssign').disabled };
  if (destination === 'Intune' && body.assignGroups && !body.script.groups.length && !confirm('The group list is empty - saving removes every assignment this script has in Intune. Continue?')) return;
  if (destination === 'Local') {
    const r = await api('/api/script-save', body);
    if (!r.ok) { $('scriptErr').textContent = r.error; $('scriptErr').hidden = false; return; }
    toast('Saved locally - nothing was sent to Intune.'); $('dlgScript').close(); loadScripts(); return;
  }
  $('scriptLog').hidden = false; $('scriptLog').textContent = '';
  const started = await runJob(body, (ok, res) => {
    if (ok) { toast(`${body.script.displayName} saved to Intune.`); $('dlgScript').close(); }
    else { $('scriptErr').textContent = (res && res.error) || 'It did not finish - see the log.'; $('scriptErr').hidden = false; }
    loadScripts();
  }, { path: '/api/script-save', log: 'scriptLog', startText: 'Sending to Intune...' });
  if (!started) $('scriptLog').hidden = true;
}
$('btnScriptLocal').addEventListener('click', () => saveScript('Local'));
$('btnScriptIntune').addEventListener('click', () => saveScript('Intune'));

async function openScriptStatus(x) {
  $('sStatusTitle').textContent = 'Run status - ' + x.displayName;
  $('sStatusSummary').textContent = 'Reading how the script went on each device...';
  $('sStatusRows').replaceChildren();
  $('dlgScriptStatus').showModal();
  const r = await api('/api/script-runstatus', { id: x.id });
  if (!r.ok) { $('sStatusSummary').textContent = r.error; return; }
  $('sStatusSummary').textContent = r.summary;
  $('sStatusRows').replaceChildren(...r.rows.map(y => el('tr', {}, el('td', { text: y.device }), el('td', { text: y.user }),
    el('td', {}, el('span', { class: 'pill ' + (y.state === 'Success' ? 'ok' : y.state === 'Failed' ? 'err' : 'muted'), text: y.state })),
    el('td', { class: 'v', text: y.result }), el('td', { class: 'chg', text: y.error }), el('td', { text: y.lastRun }))));
}
