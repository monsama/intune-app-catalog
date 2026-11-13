// Intune App Catalog - web interface: the Updates page (apps with managed updates).
// Loaded after core.js and apps.js (the release actions live there); app.js starts the page.
'use strict';

let updRows = [], updLoading = false;
async function loadUpdates() {
  if (updLoading) return;
  updLoading = true;
  $('updNote').textContent = 'Reading Intune\'s install counts...';
  try {
    const r = await api('/api/updates-overview');
    if (!r.ok) { $('updNote').textContent = r.error; return; }
    updRows = r.rows;
    $('updNote').textContent = `${r.rows.length} app${r.rows.length === 1 ? '' : 's'} with managed updates${r.notManaged ? `, ${r.notManaged} without` : ''}.${r.connected ? ` Counts read at ${r.at}.` : ' Not connected - no counts from Intune.'}${r.note ? ' ' + r.note : ''}`;
    const s = r.summary;
    const tile = (n, label, cls, title) => el('div', { class: 'stat ' + (cls || ''), title: title || '' }, el('span', { class: 'n', text: n }), el('span', { class: 'l', text: label }));
    $('updTiles').replaceChildren(
      tile(String(s.managed), 'apps with managed updates'),
      tile(String(s.inPilot), s.inPilot ? `in pilot - ${s.ready} ready, ${s.held} on hold` : 'in pilot', s.held ? 'warn' : s.ready ? 'info' : ''),
      tile(String(s.available), 'newer version available', s.available ? 'info' : '', 'Not counting apps that have a version in pilot'),
      tile(s.onCurrentPercent === null ? '-' : s.onCurrentPercent + ' %', `of ${s.devices} devices on the current version`, s.onCurrentPercent !== null && s.onCurrentPercent < 90 ? 'warn' : 'ok'));
    $('updEmpty').hidden = r.rows.length > 0;
    renderUpdates();
  } finally { updLoading = false; }
}
function renderUpdates() {
  const pillFor = { promote: ['ok', 'ready'], wait: ['muted', 'waiting'], hold: ['warn', 'on hold'] };
  $('updBody').replaceChildren(...updRows.map(x => {
    const btn = (text, title, fn) => el('button', { class: 'btn small', text, title, onclick: fn });
    const acts = [];
    if (x.pilot) { acts.push(btn('Promote...', 'Give the pilot release to everyone', () => promoteRelease(x.name)), btn('Withdraw...', 'Delete the pilot release', () => withdrawRelease(x.name))); }
    else if (x.deployed) {
      acts.push(btn('Release...', x.available ? `Release ${x.available} to the pilot groups` : 'Release a new version to the pilot groups', () => openRelease(x.name)));
      if (x.previous.length) acts.push(btn('Roll back...', `Back to ${x.previous[x.previous.length - 1]}`, () => rollbackRelease(x.name)));
    }
    else acts.push(el('span', { class: 'muted', text: 'Deploy it first' }));
    const p = x.pilot, verdict = p && pillFor[p.action];
    const devices = x.installed === null ? el('span', { class: 'muted', text: x.deployed ? '-' : 'not deployed' })
      : el('span', { title: `${x.installed} installed, ${x.failed} failed, ${x.pending} pending, ${x.notInstalled} not installed` }, `${x.installed}`, el('span', { class: 'muted', text: ` of ${x.installed + x.failed + x.pending + x.notInstalled}` }), x.failed ? el('span', { class: 'pill err newer', text: `${x.failed} failed` }) : '');
    return el('tr', {},
      el('td', { class: 'name' }, x.name, el('span', { class: 'muted', text: x.kind === 'package' ? ' (own package)' : '' })),
      el('td', { class: 'num', text: x.current || '-' }),
      el('td', {}, devices),
      el('td', {}, p ? [el('span', { class: 'mono', text: p.version }), ' ', verdict ? el('span', { class: 'pill ' + verdict[0], text: verdict[1], title: p.reason }) : el('span', { class: 'muted', text: '(no counts yet)' }), el('div', { class: 'why', text: p.reason || `since ${p.at}` })] : el('span', { class: 'muted', text: '-' })),
      el('td', {}, x.available ? el('span', { class: 'pill info', text: x.available }) : el('span', { class: 'muted', text: '-' })),
      el('td', { class: 'mono', text: x.previous.length ? x.previous.join(', ') : '-' }),
      el('td', { class: 'act' }, el('div', { class: 'fixes' }, ...acts)));
  }));
}
$('btnUpdReload').addEventListener('click', loadUpdates);
$('btnUpdWinget').addEventListener('click', async () => {
  const b = $('btnUpdWinget'); b.disabled = true;
  toast('Asking winget for the newest versions - about a second per app...');
  try {
    const r = await api('/api/checks-winget', {});
    if (!r.ok) { toast(r.error, true); return; }
    await loadApps(); await loadUpdates();
    toast('winget versions updated.');
  } finally { b.disabled = false; }
});
$('btnUpdExport').addEventListener('click', () => {
  if (!updRows.length) { toast('Nothing to export.', true); return; }
  const q = v => { const t = v === null || v === undefined ? '' : String(v); return /^[=+\-@\t\r]/.test(t) ? `"'${t.replace(/"/g, '""')}"` : `"${t.replace(/"/g, '""')}"`; };
  const head = ['App', 'Kind', 'Current version', 'Installed', 'Failed', 'Pending', 'Not installed', 'On current (%)', 'Pilot version', 'Pilot since', 'Pilot installed', 'Pilot failed', 'Release rule', 'Why', 'Available', 'Superseded'];
  const lines = [head.map(q).join(';'), ...updRows.map(x => [x.name, x.kind, x.current, x.installed, x.failed, x.pending, x.notInstalled, x.onCurrentPercent,
    x.pilot && x.pilot.version, x.pilot && x.pilot.at, x.pilot && x.pilot.installed, x.pilot && x.pilot.failed, x.pilot && x.pilot.action, x.pilot && x.pilot.reason, x.available, x.previous.join(' | ')].map(q).join(';'))];
  const url = URL.createObjectURL(new Blob(['﻿' + lines.join('\r\n') + '\r\n'], { type: 'text/csv;charset=utf-8' }));
  const a = el('a', { href: url, download: `managed-updates-${new Date().toISOString().slice(0, 10)}.csv` });
  document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 10000);
  toast(`Exported ${updRows.length} app(s) to your Downloads folder.`);
});
// After a release action's dialogs close, the page shows the new state.
for (const d of ['dlgRun', 'dlgRelease', 'dlgAsk']) $(d).addEventListener('close', () => { if (!$('viewUpdates').hidden) setTimeout(loadUpdates, 300); });
