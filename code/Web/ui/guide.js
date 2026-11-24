// Intune App Catalog - web interface: finding the way. Each app's stage and next step, the
// side panel, "Ready to deploy?" in the editor, getting started, the "?" explanations, the
// release timeline, and the job tray. Loaded last but one (before app.js starts the page).
'use strict';

// ---------------------------------------------------------------- an app's stage and its next step
const onApp = (a, act) => { selected.clear(); selected.add(a.name); lastClicked = a.name; renderApps(); menuAction(act); };
async function takeVersionFor(a) {
  // Only this app is asked about (not every app), and the toast says which version it pinned - the side panel's Version lists the others.
  toast(`Asking winget for ${a.name}'s versions...`);
  const w = await api('/api/winget-versions', { id: a.wingetId });
  if (!w.ok || !w.versions.length) { toast(w.error || 'winget had no version for it.', true); return; }
  const r = await api('/api/app-quick', { name: a.name, field: 'appVersion', value: w.versions[0] });
  await loadApps();
  toast(r.ok ? `${a.name} is pinned to ${w.versions[0]} (winget's newest). Another version: pick it under Version in the side panel.` : r.error, !r.ok,
    r.ok ? [{ label: 'Send to Intune', run: () => openDeploy([a.name]) }] : []);
}
const isWauApp = a => /^\s*(Romanitho\.)?winget[\s\-_.]*auto[\s\-_]*update\s*$/i.test(a.name || '') || /^Romanitho\.Winget-AutoUpdate$/i.test(a.wingetId || '');
// How the app gets new versions, in words - the same for the stage, the panel and the editor.
function updatesText(a, managed) {
  if (managed) return 'managed - pilot first';
  if (a.msHint && !a.wingetId) return 'Microsoft keeps it updated (created in Intune)';
  if (a.office && !a.wingetId) return 'Microsoft keeps it updated on its update channel';
  if (a.wingetId && isStoreId(a.wingetId)) return 'the Microsoft Store keeps it updated';
  if (!a.wingetId) return 'its own installer - the version you package';
  return "winget's newest at install time, not updated afterwards";
}
function stageOf(a) {
  // Microsoft 365 Apps (2.38.21): no installer, command or detection of its own - like a Store app.
  const own = !a.wingetId && !a.office;
  // Another admin (or another window) is changing it right now: no next step until that's done.
  if (a.busy) return { key: 'busy', label: 'Being changed', cls: 'warn', why: `Being changed right now by ${a.busy}. The list shows the result once it's done (Reload).` };
  if (tenantState(a) === 'missing') return { key: 'tenant', label: 'Other tenant', cls: 'warn', why: 'Its App ID belongs to another tenant - copied catalog?', next: { label: 'Clear App ID', title: 'Forget the link, so Send to Intune creates it in this tenant', run: () => onApp(a, 'clearid') } };
  if (isWauApp(a)) return { key: 'retire', label: 'Retire', cls: 'muted', why: a.hasAppId ? 'Winget-AutoUpdate - replaced by managed updates. Retire it to take it off the devices.' : 'Winget-AutoUpdate - replaced by managed updates. It isn\'t in Intune from this catalog: remove it from the catalog.', next: a.hasAppId ? { label: 'Retire...', title: 'Uninstall it from its groups\' devices, then delete it from Intune', run: () => onApp(a, 'retire') } : null };
  // Nothing to do here for it (it's added in Intune itself) - no "next step" button that only opens the editor again.
  if (a.msHint && !a.hasAppId) return { key: 'msapp', label: 'Microsoft app', cls: 'muted', why: a.msHint };
  if (/issue|Check failed/.test(a.audit || '')) return { key: 'look', label: 'Needs a look', cls: 'warn', why: 'Intune differs from the catalog (last check).', next: { label: 'Checks', title: 'See what differs and fix it', run: () => showChecksFor(a.name) } };
  if (own && !a.hasAppId && !a.hasInstall) return { key: 'draft', label: 'Draft', cls: 'muted', why: 'It needs an install command (editor: Install & detection).', next: { label: 'Edit', title: 'Set its install command', run: () => openEditor(a.name) } };
  if (own && !a.hasAppId && !a.hasDetection) return { key: 'draft', label: 'Draft', cls: 'muted', why: 'It needs a detection rule - Send to Intune refuses an own package without one.', next: { label: 'Edit', title: 'Set its detection rule (Install & detection)', run: () => openEditor(a.name) } };
  if (own && a.packageMissing) return { key: 'draft', label: 'Draft', cls: 'muted', why: 'Its installer isn\'t packaged yet.', next: { label: 'Build', title: 'Build the .intunewin from its packages folder', run: () => onApp(a, 'package') } };
  if (needsAttention(a)) return { key: 'look', label: 'Needs a look', cls: 'warn', why: (a.status || '').split('; ').map(p => statusLabel[p] || p).join('; '), next: { label: 'Edit', title: 'Open it in the editor', run: () => openEditor(a.name) } };
  // Changed in the catalog since it was last sent: the send it needs is the next step.
  if (a.hasAppId && a.unsent) {
    const s = a.unsent.split(','), what = s.map(x => x === 'settings' ? 'its settings' : 'its groups').join(' and ');
    return { key: 'unsent', label: 'Changes to send', cls: 'warn', why: `Changed in the catalog since it was last sent: ${what}. Intune still has the old ones.`,
      next: s.includes('settings') ? { label: 'Send settings', title: 'Send its settings to Intune (no package upload, groups untouched)', run: () => sendSettingsNow([a.name]) }
        : { label: 'Send groups', title: 'Send its groups to Intune', run: () => sendGroupsNow([a.name]) } };
  }
  if (!a.hasAppId) {
    if (a.managed && !own && !a.version) return { key: 'draft', label: 'Draft', cls: 'muted', why: 'Managed updates: it needs the version to start from.', next: { label: 'Pin newest', title: "Pin winget's newest version (another one: Version in the side panel)", run: () => takeVersionFor(a) } };
    // As the editor's "Ready to send?" list: no group yet means Intune would have it for nobody.
    if (!(a.groups || []).length) return { key: 'ready', label: 'Ready - no groups', cls: 'warn', why: 'Everything else is set - but no group gets it yet, so in Intune nobody would have it. Who gets it is in the editor.', next: { label: 'Groups...', title: 'Set who gets it (editor: Who gets it)', run: () => openEditor(a.name) } };
    return { key: 'ready', label: 'Ready to send', cls: 'info', why: 'Everything is set - not in Intune yet.', next: { label: 'Send to Intune', title: 'Create it in Intune', run: () => openDeploy([a.name]) } };
  }
  if (a.pilotVersion) {
    // As on Updates: a ring still to go is the next step; everyone only after the last ring (or on the fast track).
    const rings = 1 + ((prefs && prefs.releaseRings) || []).length, next = !a.pilotFast && (a.pilotRing || 0) < rings - 1;
    const p = { version: a.pilotVersion, ring: a.pilotRing || 0, ringCount: rings, ringName: (a.pilotRing || 0) === 0 ? 'Pilot' : ((((prefs && prefs.releaseRings) || [])[(a.pilotRing || 0) - 1] || {}).name || `Ring ${(a.pilotRing || 0) + 1}`) };
    return { key: 'pilot', label: `In pilot ${a.pilotVersion}`, cls: 'warn', why: `${a.pilotVersion} is with ${p.ringName === 'Pilot' ? 'the pilot groups' : p.ringName}; everyone else has ${a.version || 'the current version'}.`,
      next: next ? { label: 'Next ring...', title: 'Give it to the next release ring too', run: () => advanceRelease(a.name, p) } : { label: 'Promote...', title: 'Give it to everyone (shows how the pilot went first)', run: () => promoteRelease(a.name) } };
  }
  // An own package watching winget (2.36.0): the new installer is fetched first, then released.
  if (a.managed && a.newerOnWinget && !a.wingetId && a.watchWinget) return { key: 'everyone', label: 'Everyone', cls: 'ok', why: `winget (${a.watchWinget}) has ${a.wingetVersion}.`, next: { label: 'Get new installer...', title: `Download ${a.wingetVersion} into its folder, then release it`, run: () => fetchWatched(a.name) } };
  if (a.managed && a.newerOnWinget) return { key: 'everyone', label: 'Everyone', cls: 'ok', why: `winget has ${a.wingetVersion}.`, next: { label: 'Release...', title: `Release ${a.wingetVersion} to the pilot groups first`, run: () => openRelease(a.name) } };
  return { key: 'everyone', label: a.managed ? 'Everyone' : 'In Intune', cls: 'ok', why: a.managed ? `Everyone gets ${a.version || 'it'}; new versions go to the pilot groups first.` : `In Intune - ${updatesText(a, false)}.` };
}
function stageCell(a) {
  const s = stageOf(a);
  // Changes to send (2.38.8): pointing at it shows what changed since the last send, field by field.
  const pill = s.key === 'unsent'
    ? unsentPill(a, s)
    : el('span', { class: 'pill ' + s.cls, text: s.label, title: [s.why, a.status ? 'Status: ' + a.status : ''].filter(Boolean).join('\n') });
  if (!s.next) return pill;
  return el('span', { class: 'stage' }, pill, el('button', { class: 'btn small next', text: s.next.label, title: s.next.title, tabindex: '-1', onclick: e => { e.stopPropagation(); s.next.run(); } }));
}

function unsentPill(a, s) {
  // Reachable by Tab (2.38.12) - the card is the only place that says what changed.
  const b = el('button', { type: 'button', class: 'pill pillbtn ' + s.cls, text: s.label, 'aria-haspopup': 'dialog', 'aria-expanded': 'false', 'aria-controls': 'cmpCard',
    'aria-label': `${s.label} - show what changed since the last send` });
  return hoverCardOn(b, async still => {
    const r = await api('/api/unsent-diff', { name: a.name });
    if (!still()) return;
    if (!r.ok) { toast(r.error, true); return; }
    const parts = a.unsent.split(',');
    hcOpen(b, { title: `${a.name} - changes to send`, sub: `${s.why}`, left: 'Intune has (last sent)', right: 'Catalog now',
      rows: r.rows.map(x => ({ field: x.field, left: x.sent, right: x.now })),
      empty: 'Only the order or spacing changed - nothing a person would see.',
      note: r.fromHistory ? 'From the change history - it was last sent by an earlier version · Esc closes' : 'Long values are shortened here · Esc closes',
      buttons: [
        ...(parts.includes('settings') ? [el('button', { type: 'button', class: 'btn small primary', text: 'Send settings', onclick: () => { hcClose(); sendSettingsNow([a.name]); } })] : []),
        ...(parts.includes('groups') ? [el('button', { type: 'button', class: 'btn small' + (parts.includes('settings') ? '' : ' primary'), text: 'Send groups', onclick: () => { hcClose(); sendGroupsNow([a.name]); } })] : []),
        el('button', { type: 'button', class: 'btn small', text: 'Edit', onclick: () => { hcClose(); openEditor(a.name); } })] });
  });
}

// ---------------------------------------------------------------- the toolbar's next step, and the side panel
let panelSeq = 0, panelTimer = 0;
function updatePanel() {
  const sel = [...selected].map(n => apps.find(a => a.name === n)).filter(Boolean);
  const b = $('btnNext');
  // "Send to Intune" is the toolbar's own button already - not shown twice.
  // The next step is on the app's row and in the side panel - the toolbar keeps its own buttons, so nothing jumps.
  b.hidden = true;
  const p = $('appPanel');
  // Not exactly one app: a panel still on its way for an earlier click is dropped too.
  if (sel.length !== 1) { clearTimeout(panelTimer); panelSeq++; if (sel.length > 1) multiPanel(sel); else p.hidden = true; return; }
  clearTimeout(panelTimer); panelTimer = setTimeout(() => fillPanel(sel[0]), 120);
}
let panelRefocus = '';
async function fillPanel(a) {
  const seq = ++panelSeq, p = $('appPanel'), s = stageOf(a);
  const r = await api('/api/app-get', { name: a.name });
  if (seq !== panelSeq || selected.size !== 1 || !selected.has(a.name)) return;
  const app = r.ok ? r.app : {};
  const fact = (k, v) => v ? el('div', { class: 'kv' }, el('span', { class: 'k', text: k }), el('span', { text: v })) : '';
  // Quick edits right here: a group added or taken off, the version - saved at once (the editor isn't needed).
  const quick = async (body, refocus) => { const x = await api('/api/app-quick', { name: a.name, ...body }); if (!x.ok) { toast(x.error, true); return false; }
    // A script app's marker follows the version: its package has to be built again before it's sent.
    if ((x.scripts || []).length) toast(`Saved. ${x.scripts.join(', ')} now ${x.scripts.length === 1 ? 'writes' : 'write'} the new version - build the package again before sending it.`, false, [{ label: 'Build', run: () => onApp(a, 'package') }]); else toast('Saved.'); panelRefocus = refocus || ''; await loadApps(); return true; };
  const inline = (btn, label, value, save) => {
    const inp = el('input', { class: 'qedit', value: value || '', 'aria-label': label, placeholder: label, list: 'qGroupList',
      onkeydown: async e => { if (e.key === 'Enter') { e.preventDefault(); if (await save(inp.value.trim())) return; } else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); inp.replaceWith(btn); btn.focus(); } } });
    inp.addEventListener('blur', () => setTimeout(() => { if (inp.isConnected && !inp.value.trim()) inp.replaceWith(btn); }, 150));
    btn.replaceWith(inp); inp.focus(); inp.select();
  };
  const groups = (k, field, list, always) => (list || []).length || always ? el('div', { class: 'kv' }, el('span', { class: 'k', text: k }), el('span', { class: 'gedit' },
    ...(list || []).map(g => el('span', { class: 'chip static editable' }, g, el('button', { type: 'button', class: 'x', text: '×', 'aria-label': `Take ${g} off ${k}`, title: `Take ${g} off ${k}`, onclick: () => quick({ field, remove: g }, `Add a group to ${k}`) }))),
    (() => { const b = el('button', { type: 'button', class: 'chip addchip', text: '+ Add', 'aria-label': `Add a group to ${k}`, title: `Add a group to ${k}`, onclick: () => inline(b, `Group for ${k}`, '', v => v ? quick({ field, add: v }, `Add a group to ${k}`) : false) }); return b; })())) : '';
  const known = [...new Set(apps.flatMap(x => x.groups || []))].sort();
  const btn = (text, title, run, primary) => el('button', { class: 'btn small' + (primary ? ' primary' : ''), text, title, onclick: run });
  const pilot = (app.releases || []).find(x => x.state === 'pilot');
  const msOnly = !!(a.msHint && !a.wingetId), noVersion = msOnly || !!(a.office && !a.wingetId) || !!(a.wingetId && isStoreId(a.wingetId));
  p.replaceChildren(
    el('div', { class: 'phead' }, iconFor(a), el('h2', { text: a.name }), el('button', { class: 'btn small ghost', text: 'Close', title: 'Close this panel', onclick: () => { selected.clear(); renderApps(); } })),
    el('div', { class: 'pstage' }, el('span', { class: 'pill ' + s.cls, text: s.label }), el('span', { class: 'muted', text: ' ' + (s.why || '') })),
    s.next ? el('div', { class: 'pnext' }, el('span', { class: 'muted', text: 'Next step:' }), btn(s.next.label, s.next.title, s.next.run, true)) : '',
    // 2.33.0: it replaced an MSI line-of-business app as Win32 - that one is still in Intune until it is retired.
    a.lobToRetire ? el('div', { class: 'plob' }, el('span', { text: 'The MSI line-of-business app this one replaces is still in Intune. Once this Win32 app has its groups, retire it: devices keep the software - this app finds it by the same MSI product code.' }),
      btn('Retire the MSI app...', 'Delete the old MSI line-of-business app from Intune', () => retireLobApp(a.name))) : '',
    // An MSI line-of-business app in Intune, not moved yet: what to do.
    !a.lobToRetire && a.hasAppId && isLobMsi(a) ? el('div', { class: 'plob' }, el('span', { text: "In Intune it is an MSI line-of-business app - it can't be updated as Win32, and Intune never gives the .msi back. Upload the .msi in the editor (Basics), Package it, then Send to Intune creates it as a Win32 app with its groups." })) : '',
    app.managedUpdates ? releaseTimeline(pilot ? pilot.ring : (a.hasAppId ? 99 : -1), !!(pilot && pilot.fastTrack)) : '',
    el('div', { class: 'pfacts' },
      // No version to pick for an app Microsoft or the Store keeps up to date - the row isn't shown at all.
      noVersion ? '' : (() => {
        const base = a.version ? (a.managed ? `${a.version} (pinned)` : a.version) : a.wingetId && !isStoreId(a.wingetId) ? (a.managed ? 'not pinned yet' : 'newest') : '(none)';
        const text = [base, a.pilotVersion ? `pilot ${a.pilotVersion}` : '', a.newerOnWinget ? `winget has ${a.wingetVersion}` : '', (a.previousVersions || []).length ? `kept: ${a.previousVersions.join(', ')}` : ''].filter(Boolean).join(' - ');
        // A Winget app without settings of its own gets them (the defaults) with the version picked.
        const canEdit = (app.hasMetadata || (a.wingetId && !isStoreId(a.wingetId))) && !(app.managedUpdates && a.hasAppId);
        const extra = [a.pilotVersion ? `pilot ${a.pilotVersion}` : '', (a.previousVersions || []).length ? `kept: ${a.previousVersions.join(', ')}` : ''].filter(Boolean).join(' · ');
        if (!canEdit) return el('div', { class: 'kv' }, el('span', { class: 'k', text: 'Version' }), el('span', {}, [base, extra].filter(Boolean).join(' · ')));
        // One steady field: the version as it is now; opening it lists winget's versions (asked the first time) - nothing moves.
        const sel = el('select', { class: 'pver', 'aria-label': 'App version', title: 'Pick the App version - winget\'s versions, newest first' }, el('option', { value: '', text: base }));
        let loaded = false;
        const load = async () => {
          if (loaded) return; loaded = true;
          const opts = [];
          if (a.wingetId && !isStoreId(a.wingetId)) {
            const wait = el('option', { value: '', disabled: true, text: 'Asking winget...' }); sel.append(wait);
            const r = await api('/api/winget-versions', { id: a.wingetId });
            wait.remove();
            if (r.ok) r.versions.slice(0, 40).forEach((v, i) => { if (v !== a.version) opts.push([v, i === 0 ? `${v} · newest` : v]); });
            else opts.push(['', `winget: ${r.error}`]);
          }
          for (const v of (a.previousVersions || [])) if (v !== a.version && !opts.some(o => o[0] === v)) opts.push([v, `${v} · kept from an earlier release`]);
          sel.append(...opts.map(([v, t]) => el('option', { value: v, text: t, disabled: !v })), el('option', { value: '__other', text: 'Other - type it...' }));
        };
        sel.addEventListener('pointerdown', load); sel.addEventListener('focus', load); sel.addEventListener('keydown', load);
        sel.addEventListener('change', async () => {
          const v = sel.value;
          if (v === '__other') { const inp = el('input', { class: 'pver', value: a.version || '', 'aria-label': 'App version', placeholder: 'e.g. 24.09' });
            inp.addEventListener('keydown', async e => { if (e.key === 'Enter') { e.preventDefault(); const t = inp.value.trim(); if (t && t !== a.version) await quick({ field: 'appVersion', value: t }, 'App version'); else { sel.value = ''; inp.replaceWith(sel); } } else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); inp.replaceWith(sel); sel.value = ''; sel.focus(); } });
            inp.addEventListener('blur', () => setTimeout(() => { if (inp.isConnected) { sel.value = ''; inp.replaceWith(sel); } }, 150));
            sel.replaceWith(inp); inp.focus(); inp.select(); return; }
          if (v) { sel.disabled = true; if (!(await quick({ field: 'appVersion', value: v }, 'App version'))) { sel.disabled = false; sel.value = ''; } }
        });
        return el('div', { class: 'kv' }, el('span', { class: 'k', text: 'Version' }), el('span', { class: 'pverwrap' }, sel, extra ? el('span', { class: 'muted pverx', text: extra }) : ''));
      })(),
      fact('Source', a.office && !a.wingetId ? `Microsoft 365 Apps: ${a.officeText}` : a.msHint && !a.wingetId ? 'Microsoft (created in Intune)' : a.wingetId && isStoreId(a.wingetId) ? `Microsoft Store: ${a.wingetId}` : a.wingetId ? `winget: ${a.wingetId}` : 'its own installer (Packages folder)'),
      fact('Updates', updatesText(a, app.managedUpdates || a.managed)),
      // The App ID in full, with Copy and Open in Intune - the app's page in the Intune admin center.
      a.hasAppId && a.appId ? el('div', { class: 'kv' }, el('span', { class: 'k', text: 'In Intune' }), el('span', { class: 'pappid' },
        el('span', { text: a.type || 'yes' }), el('code', { class: 'appid', text: a.appId, title: 'The Intune App ID' }),
        el('span', { class: 'idacts' }, btn('Copy', 'Copy the App ID', async () => { try { await navigator.clipboard.writeText(a.appId); toast('App ID copied.'); } catch (e) { toast('Could not copy - select the ID and copy it by hand.', true); } }),
          btn('Open in Intune', "This app's page in the Intune admin center", async () => { const r = await api('/api/open', { target: 'intune-app', name: a.name }); if (!r.ok) toast(r.error, true); }))))
        : fact('In Intune', a.hasAppId ? (a.type || 'yes') : 'not yet'),
      // A Microsoft app that isn't in Intune from here has nothing to send its groups to: no group fields until it is.
      ...(msOnly && !a.hasAppId ? [] : [groups('Required', 'requiredFor', app.requiredFor, true), groups('Available', 'availableFor', app.availableFor, true), groups('Uninstall', 'uninstallFor', app.uninstallFor), groups('Excluded', 'excludeFor', app.excludeFor)]),
      el('datalist', { id: 'qGroupList' }, ...known.map(g => el('option', { value: g }))),
      fact('Last check', a.audit)),
    el('div', { class: 'pacts' }, btn('Edit', 'Open it in the editor', () => openEditor(a.name)),
      a.hasAppId ? btn('Install status', 'Every device\'s install state', () => openStatus(a.name)) : '',
      // Opened right here (the same click reaching the page would close the menu again at once).
      btn('More...', 'Every action for this app', e => { e.stopPropagation(); const r = e.currentTarget.getBoundingClientRect(); openMenu(r.left, r.bottom + 4); })));
  p.hidden = false;
  if (panelRefocus) { const t = [...p.querySelectorAll('[aria-label]')].find(x => x.getAttribute('aria-label') === panelRefocus); panelRefocus = ''; if (t) t.focus(); }
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
  const store = !own && isStoreId(wid), office = own && editorSrc === 'office', ms = own && !office && row && row.msHint;
  const items = office ? [
    [!!$('aName').value.trim(), 'A name', 'aName'],
    [true, 'Microsoft 365 Apps - Microsoft installs and updates it; no commands or detection', null],
    [[...document.querySelectorAll('[data-oapp]')].some(c => c.checked), 'At least one app installed', 'oChannel'],
    [groups, groups ? 'Groups that get it' : 'Groups that get it - none yet, so nobody gets it', 'gRequired'],
  ] : ms ? [
    [!!$('aName').value.trim(), 'A name', 'aName'],
    // Microsoft's own apps (2.38.22): what to do, as a one-click step - not a "Missing:" line that only says why.
    /company\s*portal/i.test($('aName').value) ? [false, 'Its Store ID 9WZDNCRFJ3PZ - Company Portal is sent as a Microsoft Store app', null,
      { label: 'Use Store ID 9WZDNCRFJ3PZ', run: () => { editorSrc = 'store'; $('aWinget').value = '9WZDNCRFJ3PZ'; $('aWinget').dispatchEvent(new Event('input', { bubbles: true })); } }]
      : /^(microsoft\s+)?(365|office)\b|^microsoft 365 apps/i.test($('aName').value.trim()) ? [false, 'Its Microsoft 365 settings - sent as Intune\'s own Microsoft 365 Apps', null,
      { label: 'Install from Microsoft 365', run: () => { const b = document.querySelector('.srcpick [data-src="office"]'); if (b) b.click(); } }]
      : [true, `In Intune as ${row.type || 'its own app type'} - nothing to package`, null],
    ...(row.hasAppId ? [[groups, groups ? 'Groups that get it' : 'Groups that get it - none yet, so nobody gets it', 'gRequired']] : []),
  ] : store ? [
    [!!$('aName').value.trim(), 'A name', 'aName'],
    [true, `Microsoft Store app (${wid}) - the Store installs and updates it; no commands or detection`, null],
    [groups, groups ? 'Groups that get it' : 'Groups that get it - none yet, so nobody gets it', 'gRequired'],
  ] : [
    [!!$('aName').value.trim(), 'A name', 'aName'],
    own ? (() => {
      // The command naming another installer than the one in its packages folder (an MSI file block changed):
      // the package has the old one - not "packaged" until that file is there and packaged again.
      // By file name - the installer may sit in a subfolder (Setup\\setup.exe, uploaded with its folder).
      const named = ($('mInstallCommand').value.match(/([^\s"'\\/]+\.(?:msi|exe))\b/i) || [])[1], have = editorInstaller && editorInstaller.file && String(editorInstaller.file).split(/[\\/]/).pop();
      if (named && have && named.toLowerCase() !== String(have).toLowerCase() && !/^(msiexec|cmd|powershell)\.exe$/i.test(named))
        return [false, `The command installs ${named}, the packages folder has ${have} - put ${named} there, then Package`, 'mInstallCommand'];
      return [!!(row && !row.packageMissing), row && !row.packageMissing ? 'Its installer is packaged' : 'Its installer packaged (Packages\\<name>, then Package)', null];
    })()
      : [true, `Installs from winget (${wid})`, 'aWinget'],
    own ? [!!$('mInstallCommand').value.trim(), 'An install command', 'mInstallCommand'] : [true, 'Install command - made for winget', null],
    own ? [!!det, det ? 'A detection rule' : 'A detection rule (Install & detection)', 'xType'] : [true, 'Detection - made for winget', null],
    // Detection and uninstall naming different MSI product codes (one updated, the other not): Install & detection says more.
    own && $('xPcNote') && !$('xPcNote').hidden ? [false, 'Detection and uninstall use different product codes', 'xProductCode'] : null,
    $('aManaged').checked ? [!!$('mAppVersion').value.trim(), 'A version (managed updates install exactly it)', 'mAppVersion'] : null,
    [groups, groups ? 'Groups that get it' : 'Groups that get it - none yet, so nobody gets it', 'gRequired'],
  ].filter(Boolean);
  const done = items.filter(i => i[0]).length;
  $('readyBox').querySelector('h3').textContent = done === items.length ? 'Ready to send to Intune' : `Ready to send? ${done} of ${items.length}`;
  $('readyBox').classList.toggle('allok', done === items.length);
  $('readyList').replaceChildren(...items.map(([ok, text, field, act]) => el('li', { class: ok ? 'ok' : 'todo' },
    el('span', { class: 'mark', 'aria-hidden': 'true', text: ok ? '✓' : '!' }),
    act && !ok ? el('span', {}, text, ' ', el('button', { type: 'button', class: 'btn small', text: act.label, onclick: () => { act.run(); updateReady(); } }))
    : field && !ok ? el('button', { type: 'button', class: 'linkish', text, title: 'Go to the field', onclick: () => { const f = $(field); edPageFor(f); const d = f.closest('details'); if (d) d.open = true; ((f.hidden && $(field + 'Chips')) || f).focus(); } }) : el('span', { text: (ok ? '' : 'Missing: ') + text }))));
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
    'settings:automation': () => showSettings('automation'), 'settings:permissions': checkPermissionsNow, add: () => openAdd(), 'apps:notdeployed': () => { showView('apps'); $('filter').value = 'notdeployed'; renderApps(); updateViewButtons(); } };
  $('homeSetup').hidden = !steps || !left.length;
  if (!steps || !left.length) return;
  const done = steps.length - left.length;
  $('setupTitle').textContent = `Getting started - ${done} of ${steps.length} done`;
  $('setupBar').style.width = Math.round(100 * done / steps.length) + '%';
  const first = steps.findIndex(s => !s.done);
  // Every step in its place, 1 to the last: the done ones ticked and short (their title), the open ones in full with
  // their button - the next one marked.
  $('setupList').replaceChildren(...steps.map((s, i) => s.done
    ? el('li', { class: 'done', title: s.text }, el('span', { class: 'mark', 'aria-hidden': 'true', text: '✓' }),
      el('div', { class: 'body' }, el('b', { text: s.title }), el('span', { class: 'sr', text: ' - done' })), '')
    : el('li', { class: i === first ? 'now' : '' },
      el('span', { class: 'mark', 'aria-hidden': 'true', text: String(i + 1) }),
      el('div', { class: 'body', title: s.tip || '' }, el('b', { text: s.title }), el('span', { class: 'muted', text: s.text })),
      go[s.go] ? el('button', { class: 'btn small' + (i === first ? ' primary' : ''), text: s.button || 'Open', onclick: go[s.go] }) : '')));
  $('setupDone').replaceChildren();
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
    chip(notDeployed, 'not in Intune yet', notDeployed ? 'info' : '', f === 'notdeployed', 'Not in Intune yet - select them and Send to Intune', () => { $('filter').value = 'notdeployed'; showIntuneOnly = false; renderApps(); updateViewButtons(); }),
    intuneApps ? chip(io.win.length, 'only in Intune', io.win.length ? 'warn' : '', showIntuneOnly, 'Windows apps in Intune that the catalog doesn\'t manage (made in the portal) - add them to the catalog, or delete them in Intune', () => { showIntuneOnly = !showIntuneOnly; if (showIntuneOnly) { selected.clear(); updatePanel(); } renderApps(); updateViewButtons(); }) : '',
    el('span', { class: 'wnote' + (intuneApps ? ' live' : ''), text: intuneApps ? `Intune read at ${intuneAt}${io.other ? ` - ${io.other} app(s) for other platforms not counted` : ''}.` : (state && state.configured ? 'Reading Intune...' : 'Not connected - Intune isn\'t compared.') }));
  bar.hidden = false;
}


// ---------------------------------------------------------------- the editor's parts, as pages
// A tab bar at the top of the editor; each tab shows its part only. Everything stays in one form,
// so Save still saves every part - a required field on another page brings that page up.
(function editorPages() {
  const form = $('appForm'), dlg = $('dlgApp'), dsec = $('deploySec');
  const [left, right] = form.querySelectorAll(':scope > .formgrid > section');
  const [dLeft, dRight] = dsec.querySelectorAll(':scope > .formgrid > section');
  const names = ['Basics', 'Who gets it', 'Details', 'Install & detection'];
  const pageOf = new Map();
  // Install & detection holds all of how it installs: the commands, the detection rule, the requirements, then the
  // dependencies and supersedence (moved under the requirements - one column, in the order they are looked at).
  const depStart = [...dLeft.children].find(c => c.tagName === 'H3' && /Dependencies/.test(c.textContent));
  for (let c = depStart, n; c; c = n) { n = c.nextElementSibling; dRight.append(c); }
  // Folded parts: what most apps never change shows as one line with Change - the fields come out when asked for.
  const folds = { det: [], req: [], dep: [] };
  const foldHead = (sec, test, g) => {
    let on = false;
    for (const c of [...sec.children]) {
      if (c.tagName === 'H3' && test(c)) { on = true; c.after(el('div', { class: 'foldsum', 'data-sum': g }, el('span', { class: 'fstext' }),
        el('button', { type: 'button', class: 'btn small', text: g === 'det' ? 'Set a rule of its own' : 'Change', 'aria-label': g === 'det' ? 'Set a detection rule of its own' : `Change ${c.firstChild.textContent.trim().toLowerCase()}`, onclick: () => unfold(g, true) }))); continue; }
      if (c.tagName === 'H3' && on && g !== 'dep') break;
      if (on) { c.dataset.fold = g; folds[g].push(c); }
    }
  };
  foldHead(dLeft, c => /Detection rule/.test(c.textContent), 'det');
  foldHead(dRight, c => /Requirements/.test(c.textContent), 'req');
  foldHead(dRight, c => /Dependencies/.test(c.textContent), 'dep');
  const grid = dsec.querySelector(':scope > .formgrid');
  let detOwn = false;   // "Set a rule of its own" (or a rule chosen): detection stays out until the editor closes
  function unfold(g, focus) {
    if (g === 'det' && focus) detOwn = true;
    if (!grid.classList.contains('f-' + g)) return;
    grid.classList.remove('f-' + g);
    if (focus) { const f = folds[g].map(c => c.matches('input, select, textarea') ? c : c.querySelector('input:not([type=search]), select, textarea')).find(Boolean); if (f) f.focus(); }
  }
  const optText = id => { const s = $(id); return s.selectedOptions[0] ? s.selectedOptions[0].textContent : s.value; };
  function foldSummaries() {
    const id = $('aWinget').value.trim();
    grid.querySelector('[data-sum="det"] .fstext').textContent = !id && typeof editorSrc !== 'undefined' && editorSrc === 'office' ? 'Microsoft 365 Apps - Intune detects it itself.'
      : typeof isStoreId === 'function' && isStoreId(id) ? 'A Store app - Intune detects it itself.' : `Made for winget - installed when winget lists ${id}.`;
    const arch = [...document.querySelectorAll('[data-xarch]')].filter(c => c.checked).map(c => c.dataset.xarch);
    const n = v => +($(v).value || 0), codes = $('xCodes').value.split('\n').filter(l => l.trim()).length;
    const req = [`${optText('xMinOs')} or newer`, arch.length ? arch.join(', ') : 'no architecture', $('xContext').value === 'User' ? 'for the signed-in user' : 'for the device',
      `${$('xTime').value || 60} min`, `restart: ${optText('xRestart').toLowerCase()}`];
    if (n('xDisk') || n('xMem') || n('xCpus') || n('xSpeed')) req.push('hardware minimums');
    if (codes) req.push(`${codes} return code${codes === 1 ? '' : 's'}`);
    if ($('xUninstall').checked) req.push('uninstall in Company Portal');
    grid.querySelector('[data-sum="req"] .fstext').textContent = req.join(' · ');
    const deps = document.querySelectorAll('#xDeps [data-dep]:checked').length, sup = $('xSup').querySelectorAll('.suprow').length;
    grid.querySelector('[data-sum="dep"] .fstext').textContent = [deps ? `${deps} app${deps === 1 ? '' : 's'} installed first` : 'Installs on its own',
      $('xSupSet').checked ? (sup ? `replaces ${sup} older app${sup === 1 ? '' : 's'}` : 'replaces nothing') : 'supersedence as Intune has it'].join(' · ');
  }
  // On opening an app: folded again; detection only for a winget app whose rule is made for it.
  // A save refused for something in a folded part (the server says what): that part comes out, on its page.
  window.edRevealFor = msg => {
    const m = String(msg || ''), hit = [[/supersed|depend/i, 'dep'], [/detection|product code|registry|file detection/i, 'det'],
      [/install time|architecture|return code|disk|memory|processor|cpu|operating system|minimum os|restart/i, 'req']].find(([re]) => re.test(m));
    if (hit) { unfold(hit[1]); setPage(3); }
  };
  // A Microsoft Store app (2.38.3): no commands and no detection of its own - the Store does both; the fields went
  // on showing (empty, or a rule made for winget) while "Ready to send?" said it needs none.
  const storeState = () => {
    const st = (typeof isStoreId === 'function' && isStoreId($('aWinget').value.trim())) || (typeof editorSrc !== 'undefined' && editorSrc === 'office' && !$('aWinget').value.trim()), was = $('dlgApp').classList.contains('is-store');
    $('dlgApp').classList.toggle('is-store', st);
    if (st !== was) { try { setPage(cur); } catch (e) { } }   // the page's sections follow (not before the editor is set up)
    // Store, Microsoft 365 and Microsoft's own apps in Intune (2.38.22): no Install & detection tab - no commands, detection,
    // requirements or dependencies are sent for them. Details stay: the description, publisher and links go to Intune.
    try {
      const row = typeof editingName !== 'undefined' && editingName ? apps.find(a => a.name === editingName) : null;
      const special = st || !!(!$('aWinget').value.trim() && row && row.msHint);
      bar.children[3].hidden = special;
      $('dlgApp').classList.toggle('is-special', special);
      if (special && cur === 3) setPage(0);
    } catch (e) { }
    return st;
  };
  window.edFoldsReset = () => {
    const id = $('aWinget').value.trim();
    detOwn = false;
    const store = storeState();
    grid.classList.toggle('f-det', (!!id || store) && (store || !$('xType').value));
    grid.classList.add('f-req', 'f-dep');
    foldSummaries();
  };
  form.addEventListener('input', foldSummaries); form.addEventListener('change', foldSummaries);
  // Installs from changed (2.38.21): Microsoft 365 folds the commands and detection away like a Store app; another choice brings them back.
  window.edSrcChanged = () => { const st = storeState(); if (st) grid.classList.add('f-det'); else if (!$('aWinget').value.trim()) unfold('det'); foldSummaries(); };
  // A rule set, or the winget ID cleared: the detection fields are what is needed.
  $('xType').addEventListener('change', () => { if ($('xType').value) { detOwn = true; unfold('det'); } });
  // A winget ID typed in (a new app): its detection is made for winget - folded, unless a rule of its own was asked for.
  $('aWinget').addEventListener('input', () => { const store = storeState(); if (!$('aWinget').value.trim()) unfold('det'); else if (store || (!detOwn && !$('xType').value)) grid.classList.add('f-det'); });
  const assign = (section, start, switches) => { let p = start; for (const c of section.children) { const sw = switches.find(([test]) => test(c)); if (sw) p = sw[1]; pageOf.set(c, p); } };
  assign(left, 0, [[c => c.matches('h3.withtool'), 1]]);
  assign(right, 2, [[c => c.matches('.ready'), 0], [c => c.tagName === 'H3', 2]]);
  for (const c of [...dLeft.children, ...dRight.children]) pageOf.set(c, 3);
  // The install and uninstall commands belong with the detection rule.
  pageOf.set($('instRaw'), 3);
  pageOf.set($('instBlocks'), 3);
  let cur = 0;
  const bar = el('nav', { class: 'edtabs', 'aria-label': 'Parts of the app' }, ...names.map((name, i) => el('button', { type: 'button', class: 'edtab', 'data-i': i, text: name, onclick: () => {
    setPage(i);
    const sel = 'input:not([type=checkbox]):not([hidden]), select, textarea:not([hidden]), .chipinput';
    const f = [...pageOf].find(([c, p]) => p === i && !c.matches('.ready, h3') && c.querySelector(sel));
    const field = f && f[0].querySelector(sel);
    // Only while the tab still has the focus - a field clicked right after keeps it (typing went to the wrong field).
    const tab = document.activeElement;
    if (field) setTimeout(() => { if (document.activeElement === tab || document.activeElement === document.body) field.focus({ preventScroll: true }); }, 30);
  } })));
  const mark = i => [...bar.children].forEach((b, k) => b.setAttribute('aria-current', k === i ? 'true' : 'false'));
  function setPage(i) {
    cur = i;
    for (const [c, p] of pageOf) c.classList.toggle('offpage', p !== i);
    for (const s of [left, right, dLeft, dRight]) {
      // A Store app's command parts are hidden: a section holding only them is empty, so it goes too (2.38.3).
      const shownHere = c => pageOf.get(c) === i && !($('dlgApp').classList.contains('is-store') && (c.id === 'instRaw' || c.id === 'instBlocks'));
      s.classList.toggle('offpage', ![...s.children].some(shownHere));
      [...s.children].forEach(c => c.classList.remove('pgfirst'));
      const first = [...s.children].find(c => pageOf.get(c) === i); if (first) first.classList.add('pgfirst');
    }
    dsec.classList.toggle('offpage', i < 3);
    // Basics: the "Ready to send?" box is a narrow column beside the fields, not half the window.
    left.parentElement.classList.toggle('pg0', i === 0);
    form.dataset.pg = String(i);
    if (i >= 3) dsec.open = true;
    mark(i); dlg.scrollTop = 0;
  }
  // The page a field is on, brought up - for "go to the field" links and a required field left empty.
  window.edPageFor = elm => { let n = elm; while (n && !pageOf.has(n)) n = n.parentElement; if (n && pageOf.get(n) !== cur) setPage(pageOf.get(n)); const f = elm && elm.closest('[data-fold]'); if (f) unfold(f.dataset.fold); };
  form.addEventListener('invalid', e => { edPageFor(e.target); const d = e.target.closest('details.rawcmds'); if (d) d.open = true; }, true);
  form.insertBefore(bar, form.querySelector('.formgrid'));
  dlg.addEventListener('close', () => setPage(0));
  setPage(0);
})();


// Several apps selected: the panel stays (nothing shifts) with what they are and what can be done to all of them.
function multiPanel(sel) {
  const p = $('appPanel'), names = sel.map(a => a.name), inIntune = sel.filter(a => a.hasAppId).length;
  const btn = (text, title, run, primary) => el('button', { class: 'btn small' + (primary ? ' primary' : ''), text, title, onclick: run });
  p.replaceChildren(
    el('div', { class: 'phead' }, el('h2', { text: `${sel.length} apps selected` }), el('button', { class: 'btn small ghost', text: 'Clear', title: 'Select none', onclick: () => { selected.clear(); renderApps(); updateViewButtons(); } })),
    el('div', { class: 'pfacts' },
      el('div', { class: 'kv' }, el('span', { class: 'k', text: 'In Intune' }), el('span', { text: `${inIntune} of ${sel.length}` })),
      el('div', { class: 'kv' }, el('span', { class: 'k', text: 'Managed' }), el('span', { text: `${sel.filter(a => a.managed).length} of ${sel.length}` })),
      el('div', { class: 'kv' }, el('span', { class: 'k', text: 'Apps' }), el('span', { class: 'muted', text: names.slice(0, 12).join(', ') + (names.length > 12 ? `, ... ${names.length - 12} more` : '') }))),
    el('div', { class: 'pacts' }, btn('Send to Intune', 'Create or update them in Intune', () => openDeploy(names), true),
      btn('Add groups...', 'Add groups to all of them', () => openGroupsBatch('add', names)), btn('Batch edit...', 'Change fields on all of them', () => openBatch(names)),
      btn('More...', 'Every action for the selected apps', () => $('btnMore').click())));
  p.hidden = false;
}

// Sending what changed since the last send (Changes to send): its settings, or its groups - then the list is read again.
async function sendSettingsNow(names) {
  runDialog('Send settings to Intune', names.join(', '));
  const done = await runEach(names, name => ({ name, metadataOnly: true }), { path: '/api/deploy-start', log: 'runLog', startText: 'Sending settings for ' });
  toast(`Settings sent for ${done.length} of ${names.length} app(s).`, done.length < names.length); loadApps();
}
async function sendGroupsNow(names) {
  runDialog('Send groups to Intune', names.join(', '));
  const done = await runEach(names, name => ({ names: [name], mode: 'AfterDeploy' }), { path: '/api/push-start', log: 'runLog', startText: 'Sending groups for ' });
  toast(`Groups sent for ${done.length} of ${names.length} app(s).`, done.length < names.length); loadApps();
}

// Retire the MSI line-of-business app a Win32 app replaced (2.33.0): asked first, checked again on the server.
async function retireLobApp(name) {
  const a = apps.find(x => x.name === name); if (!a || !a.lobToRetire) return;
  if (!(await ask(`Delete the old MSI line-of-business app from Intune?\n\n${a.lobToRetire}\n\nIts assignments go with it. Devices keep the software: the Win32 app "${name}" finds it by the same MSI product code, so nothing is uninstalled. Make sure the Win32 app has its groups first.`, { ok: 'Delete the MSI app', danger: true }))) return;
  const r = await api('/api/lob-retire', { name });
  if (!r.ok) { toast(r.error, true); return; }
  toast(r.gone ? 'The MSI app was already gone from Intune.' : 'The MSI line-of-business app is deleted from Intune - the Win32 app replaces it.');
  await loadApps();
}
