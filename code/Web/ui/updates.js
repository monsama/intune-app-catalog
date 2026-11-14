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
  if (!updRows.length) skeleton($('updBody'), 8, 4);
  try {
    const r = await api('/api/updates-overview');
    if (!r.ok) { $('updNote').textContent = r.error; return; }
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
      ...(r.inventory ? [tile(String(s.olderDevices), 'devices with an older version (inventory)', s.olderDevices ? 'warn' : 'ok', 'From Intune\'s inventory of apps on devices - also versions installed by hand')] : []));
    $('updEmpty').hidden = r.rows.length > 0;
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
    else acts.push(el('span', { class: 'muted', text: 'Send it to Intune first' }));
    const verdict = p && pillFor[p.action];
    const devices = x.installed === null ? el('span', { class: 'muted', text: x.deployed ? '-' : 'not deployed' })
      : el('span', { title: `${x.installed} installed, ${x.failed} failed, ${x.pending} pending, ${x.notInstalled} not installed` }, `${x.installed}`, el('span', { class: 'muted', text: ` of ${x.installed + x.failed + x.pending + x.notInstalled}` }), x.failed ? el('button', { type: 'button', class: 'pill err newer linkpill', text: `${x.failed} failed`, title: 'Why? Every device\'s state, and the errors explained', onclick: () => openStatus(x.name) }) : '');
    const where = p ? releaseTimeline(p.ring, p.fastTrack, updRings) : '';
    return el('tr', {},
      el('td', { class: 'name' }, x.name, el('span', { class: 'muted', text: (x.kind === 'package' ? ' (own package)' : '') + (x.ownRule ? ' - own rule' : '') + (x.autoRelease ? ' - released automatically' : '') })),
      el('td', { class: 'num', text: x.current || '-' }),
      el('td', {}, devices),
      el('td', {}, p ? [el('span', { class: 'mono', text: p.version }), ' ', where, verdict ? el('span', { class: 'pill ' + verdict[0], text: verdict[1], title: p.reason }) : el('span', { class: 'muted', text: '(no counts yet)' }), el('div', { class: 'why', text: p.reason || `since ${p.at}` })] : el('span', { class: 'muted', text: '-' })),
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
  const a = await releaseStep({ name, step: 'advance' }, '/api/release-assign', 'runLog', 'Assigning it to the next ring\'s groups...');
  if (!a.ok) { toast(`Giving it to the next ring failed - nothing else changed. ${a.error || ''}`, true); return; }
  const r = await api('/api/release-advanced', { name });
  toast(r.ok ? `${name} ${r.version} is in ${r.ringName} now.` : r.error, !r.ok);
  loadApps();
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
$('btnUpdExport').addEventListener('click', () => {
  if (!updRows.length) { toast('Nothing to export.', true); return; }
  const q = v => { const t = v === null || v === undefined ? '' : String(v); return /^[=+\-@\t\r]/.test(t) ? `"'${t.replace(/"/g, '""')}"` : `"${t.replace(/"/g, '""')}"`; };
  const head = ['App', 'Kind', 'Current version', 'Installed', 'Failed', 'Pending', 'Not installed', 'On current (%)', 'Release version', 'Released', 'Ring', 'Fast track', 'Release installed', 'Release failed', 'Release rule', 'Why', 'Available', 'Devices on older versions', 'Superseded'];
  const lines = [head.map(q).join(';'), ...updRows.map(x => { const p = x.pilot; return [x.name, x.kind, x.current, x.installed, x.failed, x.pending, x.notInstalled, x.onCurrentPercent,
    p && p.version, p && p.at, p && p.ringName, p && (p.fastTrack ? 'yes' : 'no'), p && p.installed, p && p.failed, p && p.action, p && p.reason, x.available, x.older && x.older.devices, x.previous.join(' | ')].map(q).join(';'); })];
  const url = URL.createObjectURL(new Blob(['﻿' + lines.join('\r\n') + '\r\n'], { type: 'text/csv;charset=utf-8' }));
  const a = el('a', { href: url, download: `managed-updates-${new Date().toISOString().slice(0, 10)}.csv` });
  document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 10000);
  toast(`Exported ${updRows.length} app(s) to your Downloads folder.`);
});
// After a release action's dialogs close, the page shows the new state.
for (const d of ['dlgRun', 'dlgRelease', 'dlgAsk']) $(d).addEventListener('close', () => { if (!$('viewUpdates').hidden) setTimeout(() => loadUpdates(true), 300); });
