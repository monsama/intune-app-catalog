// Intune App Catalog - web interface: the Updates page (apps with managed updates).
// Loaded after core.js and apps.js (the release actions live there); app.js starts the page.
'use strict';

// Reading the counts asks Intune, so a tab switch reuses them for a minute (Reload always asks).
// A load asked for while one is running isn't dropped: it runs once that one ends.
let updRings = null, updRows = [], updLoading = false, updAgain = false, updLoadedAt = 0;
async function loadUpdates(force) {
  if (updLoading) { updAgain = updAgain || force !== false; return; }
  if (!force && updLoadedAt && Date.now() - updLoadedAt < 60000) return;
  updLoading = true;
  $('updNote').textContent = 'Reading Intune\'s install counts...';
  // The placeholder rows under the real header, with its number of columns - the columns don't jump when the rows come.
  if (!updRows.length) { skeleton($('updBody'), $('updGrid').tHead.rows[0].cells.length, 4); tileSkeleton($('updTiles'), 5); }
  try {
    const r = await api('/api/updates-overview');
    if (!r.ok) { $('updNote').textContent = r.error; if (!updRows.length) { $('updBody').replaceChildren(); $('updTiles').replaceChildren(); $('updTiles').hidden = true; } return; }
    updRows = r.rows; updLoadedAt = Date.now(); updRings = (r.rings || []).map(x => x.name);
    const rings = (r.rings || []).length > 1 ? ` Release rings: ${r.rings.map(x => x.name).join(' > ')} > everyone.` : '';
    $('updNote').textContent = `${r.rows.length} app${r.rows.length === 1 ? '' : 's'} with managed updates${r.notManaged ? `, ${r.notManaged} without` : ''}.${r.connected ? ` Counts read at ${r.at}.` : ' Not connected - no counts from Intune.'}${rings}${r.note ? ' ' + r.note : ''}`;
    const s = r.summary;
    const tile = (n, label, cls, title) => el('div', { class: 'stat ' + (cls || ''), title: title || '' }, el('span', { class: 'n', text: n }), el('span', { class: 'l', text: label }));
    $('updTiles').replaceChildren(
      tile(String(s.managed), 'apps with managed updates'),
      tile(String(s.inPilot), s.inPilot ? `in release - ${s.ready} ready, ${s.held} on hold` : 'in release', s.held ? 'warn' : s.ready ? 'info' : ''),
      tile(String(s.available), 'newer version available', s.available ? 'info' : '', 'Not counting apps that have a version in release'),
      tile(s.onCurrentPercent === null ? '-' : s.onCurrentPercent + ' %', `of ${s.devices} devices on the current version`, s.onCurrentPercent !== null && s.onCurrentPercent < 90 ? 'warn' : 'ok'),
      // Always five tiles (the placeholders are five): without the inventory the last one says so.
      r.inventory ? tile(String(s.olderDevices), 'devices with an older version (inventory)', s.olderDevices ? 'warn' : 'ok', 'From Intune\'s inventory of apps on devices - also versions installed by hand')
        : tile('–', 'devices with an older version (inventory)', '', 'Intune\'s app inventory couldn\'t be read - DeviceManagementManagedDevices.Read.All shows it'));
    $('updEmpty').hidden = r.rows.length > 0;
    // No app with managed updates: the message says it - no zero tiles, no empty column headers above it.
    $('updTiles').hidden = !r.rows.length; $('updGrid').tHead.hidden = !r.rows.length;
    renderUpdates();
    loadTrend();
  } finally {
    updLoading = false;
    if (updAgain) { updAgain = false; loadUpdates(true); }
  }
}
function renderUpdates() {
  const pillFor = { promote: ['ok', 'ready'], advance: ['ok', 'ready for next ring'], wait: ['muted', 'waiting'], hold: ['warn', 'on hold'] };
  $('updBody').replaceChildren(...updRows.map(x => {
    const btn = (text, title, fn) => el('button', { class: 'btn small', text, title, onclick: fn });
    const acts = [];
    const p = x.pilot;
    if (p) {
      if (!p.fastTrack && p.ring < p.ringCount - 1) acts.push(btn('Next ring...', `Give it to the next release ring too`, () => advanceRelease(x.name, p)));
      acts.push(btn('Promote...', 'Give it to everyone now', () => promoteRelease(x.name)), btn('Withdraw...', 'Delete this release', () => withdrawRelease(x.name)));
    }
    else if (x.deployed) {
      acts.push(btn('Release...', x.available ? `Release ${x.available} to the pilot groups` : 'Release a new version to the pilot groups', () => openRelease(x.name)));
      if (x.previous.length) acts.push(btn('Roll back...', `Back to ${x.previous[x.previous.length - 1]}`, () => rollbackRelease(x.name)));
    }
    else acts.push(btn('Send to Intune...', 'Create it in Intune first - then its versions are released here', () => openDeploy([x.name])));
    const verdict = p && pillFor[p.action];
    const devices = x.installed === null ? el('span', { class: 'muted', text: x.deployed ? '-' : 'not in Intune yet' })
      : el('span', { title: `${x.installed} installed, ${x.failed} failed, ${x.pending} pending, ${x.notInstalled} not installed` }, `${x.installed}`, el('span', { class: 'muted', text: ` of ${x.installed + x.failed + x.pending + x.notInstalled}` }), x.failed ? el('button', { type: 'button', class: 'pill err newer linkpill', text: `${x.failed} failed`, title: 'Why? Every device\'s state, and the errors explained', onclick: () => openStatus(x.name) }) : '');
    const where = p ? releaseTimeline(p.ring, p.fastTrack, updRings) : '';
    return el('tr', {},
      el('td', { class: 'name' }, x.name, el('span', { class: 'muted', text: (x.kind === 'package' ? ' (own package)' : '') + (x.ownRule ? ' - own rule' : '') + (x.autoRelease ? ' - released automatically' : '') })),
      el('td', { class: 'num' }, x.current || '-', x.download && ['gone', 'notinwinget'].includes(x.download.status)
        ? el('span', { class: 'pill err newer', text: x.download.latestOnly ? 'download gone (latest only)' : 'download gone', title: `${x.download.text}\n(checked ${x.download.at})` })
        : x.download && x.download.status === 'ok' ? el('span', { class: 'dlok', text: '✓', title: `Can still be downloaded (checked ${x.download.at})`, 'aria-label': 'Download checked' }) : ''),
      el('td', {}, devices),
      el('td', {}, p ? [el('span', { class: 'mono', text: p.version }), ' ', where, ' ', verdict ? el('span', { class: 'pill ' + verdict[0], text: verdict[1], title: p.reason }) : el('span', { class: 'muted', text: '(no counts yet)' }), el('div', { class: 'why', text: p.reason || `since ${p.at}` })] : el('span', { class: 'muted', text: '-' })),
      el('td', {}, x.available ? el('span', { class: 'pill info', text: x.available }) : el('span', { class: 'muted', text: '-' }), x.gate ? el('div', { class: 'why', text: `Test tenant: ${x.gate}` }) : ''),
      el('td', {}, x.older ? el('span', { title: x.older.versions.map(v => `${v.version}: ${v.devices}`).join('\n') }, `${x.older.devices} device${x.older.devices === 1 ? '' : 's'}`, el('div', { class: 'why', text: x.older.versions.slice(0, 3).map(v => `${v.version} (${v.devices})`).join(', ') + (x.older.versions.length > 3 ? ', ...' : '') })) : el('span', { class: 'muted', text: '-' })),
      el('td', { class: 'mono', text: x.previous.length ? x.previous.join(', ') : '-' }),
      el('td', { class: 'act' }, el('div', { class: 'fixes' }, ...rowActions(acts))));
  }));
}

// The next release ring: the release keeps its groups and gets the next ring's too.
async function advanceRelease(name, p) {
  if (!(await ask(`Give ${name} ${p.version} to the next release ring?\n\nNow: ${p.ringName} (ring ${p.ring + 1} of ${p.ringCount}). ${p.reason || ''}\n\nThe next ring's groups get it Required, as an update of the current version; the rule's days count again from now.`, { ok: 'Next ring', danger: false }))) return;
  runDialog(`${name} ${p.version}: next ring`, '');
  const a = await releaseStep({ name, flow: 'advance' }, '/api/release-flow', 'runLog', 'Assigning it to the next ring\'s groups...');
  const r = a.after || {};
  if (!r.flowDone) { toast(`Giving it to the next ring failed - nothing else changed. ${a.error || ''}`, true); return; }
  toast(r.ok ? `${name} ${r.version} is in ${r.ringName} now.` : r.error, !r.ok);
  loadApps(); if (!$('viewUpdates').hidden) loadUpdates(true);
}

// ---- the trend: one line, the share of devices on the current version per day (the nightly runs' reports)
let trendPoints = [];
async function loadTrend() {
  const r = await api('/api/updates-trend');
  trendPoints = r.ok ? r.points : [];
  $('updTrend').hidden = trendPoints.length < 2;
  if (trendPoints.length < 2) return;
  $('updTrendTable').tBodies[0].replaceChildren(...trendPoints.slice().reverse().map(p => el('tr', {}, el('td', { text: p.day }), el('td', { class: 'num', text: p.percent + ' %' }), el('td', { class: 'num', text: String(p.devices) }))));
  drawTrend();
}
function drawTrend() {
  const plot = $('updTrendPlot'), w = Math.max(plot.clientWidth || 600, 280), h = 160, m = { l: 40, r: 12, t: 10, b: 24 };
  const n = trendPoints.length, x = i => m.l + (n === 1 ? 0 : i * (w - m.l - m.r) / (n - 1)), y = v => m.t + (100 - v) * (h - m.t - m.b) / 100;
  const ns = 'http://www.w3.org/2000/svg', mk = (t, a) => { const e = document.createElementNS(ns, t); for (const [k, v] of Object.entries(a)) e.setAttribute(k, v); return e; };
  const svg = mk('svg', { viewBox: `0 0 ${w} ${h}`, width: w, height: h, role: 'img', 'aria-label': `Devices on the current version: ${trendPoints[0].percent} % on ${trendPoints[0].day}, ${trendPoints[n - 1].percent} % on ${trendPoints[n - 1].day}` });
  for (const v of [0, 50, 100]) {
    svg.append(mk('line', { x1: m.l, x2: w - m.r, y1: y(v), y2: y(v), class: 'grid' }));
    const t = mk('text', { x: m.l - 6, y: y(v) + 4, 'text-anchor': 'end', class: 'axis' }); t.textContent = v + ' %'; svg.append(t);
  }
  for (const i of [0, n - 1]) { const t = mk('text', { x: x(i), y: h - 6, 'text-anchor': i ? 'end' : 'start', class: 'axis' }); t.textContent = trendPoints[i].day; svg.append(t); }
  svg.append(mk('path', { d: trendPoints.map((p, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(p.percent).toFixed(1)}`).join(''), class: 'line' }));
  const last = trendPoints[n - 1];
  svg.append(mk('circle', { cx: x(n - 1), cy: y(last.percent), r: 4, class: 'dot' }));
  const cross = mk('line', { y1: m.t, y2: h - m.b, class: 'cross', visibility: 'hidden' }), hot = mk('circle', { r: 5, class: 'dot', visibility: 'hidden' });
  svg.append(cross, hot);
  const tip = el('div', { class: 'charttip', hidden: true });
  const hit = mk('rect', { x: m.l, y: 0, width: w - m.l - m.r, height: h, fill: 'transparent' });
  hit.addEventListener('mousemove', e => {
    const box = svg.getBoundingClientRect(), px = (e.clientX - box.left) * w / box.width;
    const i = Math.max(0, Math.min(n - 1, Math.round((px - m.l) * (n - 1) / (w - m.l - m.r)))), p = trendPoints[i];
    for (const [el2, k] of [[cross, 'x1'], [cross, 'x2']]) el2.setAttribute(k, x(i));
    hot.setAttribute('cx', x(i)); hot.setAttribute('cy', y(p.percent)); cross.setAttribute('visibility', 'visible'); hot.setAttribute('visibility', 'visible');
    tip.textContent = `${p.day}: ${p.percent} % of ${p.devices} devices`; tip.hidden = false;
    tip.style.left = Math.min(x(i) * box.width / w, box.width - 180) + 'px'; tip.style.top = '0px';
  });
  hit.addEventListener('mouseleave', () => { cross.setAttribute('visibility', 'hidden'); hot.setAttribute('visibility', 'hidden'); tip.hidden = true; });
  svg.append(hit);
  plot.replaceChildren(svg, tip);
}
window.addEventListener('resize', () => { if (!$('viewUpdates').hidden && trendPoints.length > 1) drawTrend(); });

$('btnUpdReload').addEventListener('click', () => loadUpdates(true));
$('btnUpdWinget').addEventListener('click', async () => {
  const b = $('btnUpdWinget'); b.disabled = true;
  toast('Asking winget for the newest versions - about a second per app...');
  try {
    const r = await api('/api/checks-winget', {});
    if (!r.ok) { toast(r.error, true); return; }
    await loadApps(); await loadUpdates(true);
    toast('winget versions updated.');
  } finally { b.disabled = false; }
});
// 2.37.0: every own package with a newer installer on winget at once - fetched one after another, then each one's next step.
let wtList = [], wtRunning = false;
$('btnUpdWatched').addEventListener('click', async () => {
  const b = $('btnUpdWatched'); b.disabled = true;
  try {
    // The list as it is now (another window may have just set an app to watch winget), then winget.
    await loadApps();
    if (!apps.some(a => !a.wingetId && a.watchWinget)) { toast('No app with its own installer watches a winget package yet - the editor: Winget package to watch.'); return; }
    toast('Asking winget for the newest versions...');
    const r = await api('/api/checks-winget', {});
    if (!r.ok) { toast(r.error, true); return; }
    await loadApps();
    wtList = apps.filter(a => !a.wingetId && a.watchWinget && a.newerOnWinget && !a.pilotVersion);
    if (!wtList.length) { toast('No watched app has a newer version on winget.'); return; }
    $('wtRows').replaceChildren(...wtList.map(a => el('tr', { 'data-name': a.name }, el('td', { text: a.name }),
      el('td', { text: `${a.version || '-'} → ${a.wingetVersion}` }), el('td', {}, el('span', { class: 'pill muted', text: 'Waiting' })))));
    $('wtGo').hidden = false; $('wtGo').disabled = false; $('wtGo').textContent = wtList.length === 1 ? 'Get it' : `Get all ${wtList.length}`;
    $('dlgWatched').showModal();
  } finally { b.disabled = false; }
});
$('wtClose').addEventListener('click', () => { if (!wtRunning) $('dlgWatched').close(); });
// Escape doesn't close it halfway: the downloads go on, and what came of each would be out of sight.
$('dlgWatched').addEventListener('cancel', e => { if (wtRunning) e.preventDefault(); });
$('wtGo').addEventListener('click', async () => {
  if (wtRunning) return;
  wtRunning = true; $('wtGo').disabled = true; $('wtClose').disabled = true;
  let got = 0;
  try {
    for (const a of wtList) {
      const cell = $('wtRows').querySelector(`tr[data-name="${CSS.escape(a.name)}"] td:last-child`);
      cell.replaceChildren(el('span', { class: 'pill info', text: 'Downloading...' }));
      const r = await api('/api/watch-fetch', { name: a.name });
      if (!r.ok) { cell.replaceChildren(el('span', { class: 'pill err', text: 'Failed' }), el('span', { class: 'why', text: r.error })); continue; }
      got++;
      // The next step: a managed app releases it to pilot; any other is packaged and sent with its App version set.
      cell.replaceChildren(el('span', { class: 'pill ok', text: `${r.version} in its folder` }), ' ',
        r.managed ? el('button', { type: 'button', class: 'btn small', text: 'Release...', title: `Release ${r.version} to the pilot groups first`, onclick: () => { $('dlgWatched').close(); openRelease(a.name); } })
          : el('button', { type: 'button', class: 'btn small', text: 'Open', title: `Set the App version to ${r.version}, then build the package and send it`, onclick: () => { $('dlgWatched').close(); openEditor(a.name); } }));
    }
  // Done: only Close is left (2.38.0) - a greyed-out "Done" beside it said nothing.
  } finally { wtRunning = false; $('wtClose').disabled = false; $('wtGo').hidden = true; $('wtClose').focus(); }
  toast(`${got} of ${wtList.length} new installer${wtList.length === 1 ? '' : 's'} in their folders${got ? ' - release or send each from the list' : ''}.`, got < wtList.length);
  await loadApps(); loadUpdates(true);
});
$('btnUpdDownloads').addEventListener('click', async () => {
  const b = $('btnUpdDownloads'); b.disabled = true;
  toast('Checking each pinned version\'s download - a few seconds per app...');
  try {
    const r = await api('/api/download-checks', {});
    if (!r.ok) { toast(r.error, true); return; }
    await loadUpdates(true);
    toast(r.bad ? `${nWord(r.bad, 'app')} can't be installed on new devices any more - see the red marks.` : `All ${r.rows.length} pinned version(s) can still be downloaded.`, !!r.bad);
  } finally { b.disabled = false; }
});
$('btnUpdExport').addEventListener('click', () => {
  if (!updRows.length) { toast('Nothing to export.', true); return; }
  const q = v => { const t = v === null || v === undefined ? '' : String(v); return /^[=+\-@\t\r]/.test(t) ? `"'${t.replace(/"/g, '""')}"` : `"${t.replace(/"/g, '""')}"`; };
  // A compliance report: per app whether it meets the bar (90 % of devices on the pinned version, and that version still downloadable), then a totals row.
  const verdict = x => x.onCurrentPercent === null || x.onCurrentPercent === undefined ? 'no counts'
    : x.download && ['gone', 'notinwinget'].includes(x.download.status) ? 'not compliant (download gone)'
    : x.onCurrentPercent >= 90 ? 'compliant' : 'not compliant';
  const head = ['App', 'Kind', 'Compliance', 'Pinned version', 'Installed', 'Failed', 'Pending', 'Not installed', 'On pinned (%)', 'Download check', 'Release version', 'Released', 'Ring', 'Fast track', 'Release installed', 'Release failed', 'Release rule', 'Why', 'Available', 'Devices on older versions', 'Superseded'];
  const sum = k => updRows.reduce((n, x) => n + (Number(x[k]) || 0), 0), tried = sum('installed') + sum('failed') + sum('pending') + sum('notInstalled');
  const lines = [head.map(q).join(';'), ...updRows.map(x => { const p = x.pilot; return [x.name, x.kind, verdict(x), x.current, x.installed, x.failed, x.pending, x.notInstalled, x.onCurrentPercent,
    x.download ? `${x.download.status} (${x.download.at})` : '', p && p.version, p && p.at, p && p.ringName, p && (p.fastTrack ? 'yes' : 'no'), p && p.installed, p && p.failed, p && p.action, p && p.reason, x.available, x.older && x.older.devices, x.previous.join(' | ')].map(q).join(';'); }),
    [`All ${updRows.length} apps`, '', `${updRows.filter(x => verdict(x) === 'compliant').length} compliant`, '', sum('installed'), sum('failed'), sum('pending'), sum('notInstalled'), tried ? Math.round(1000 * sum('installed') / tried) / 10 : '',
      '', '', '', '', '', '', '', '', '', '', updRows.reduce((n, x) => n + (x.older ? Number(x.older.devices) || 0 : 0), 0), ''].map(q).join(';')];
  const url = URL.createObjectURL(new Blob(['﻿' + lines.join('\r\n') + '\r\n'], { type: 'text/csv;charset=utf-8' }));
  const a = el('a', { href: url, download: `compliance-${new Date().toISOString().slice(0, 10)}.csv` });
  document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 10000);
  toast(`Compliance report for ${nWord(updRows.length, 'app')} saved to your Downloads folder.`);
});
// After a release action's dialogs close, the page shows the new state.
for (const d of ['dlgRun', 'dlgRelease']) $(d).addEventListener('close', () => { if (!$('viewUpdates').hidden) setTimeout(() => loadUpdates(true), 300); });

// 2.32.0: the two occasional actions in one menu; Reload as an icon.
foldIntoMenu(['btnUpdWatched', 'btnUpdDownloads', 'btnUpdExport'], { id: 'btnUpdMore', title: 'Get new installers, check downloads, compliance report' });
reloadIcon('btnUpdReload');

$('btnUpdOpenApps').addEventListener('click', () => showView('apps'));
