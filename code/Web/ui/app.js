// Intune App Catalog - web interface: start-up. Loaded last (see index.html).
'use strict';

// ---------------------------------------------------------------- start
(async function start() {
  let v = 'home'; try { v = localStorage.getItem('view') || 'home'; } catch (e) { }
  showView(v);
  // The log and the state at once - the page is usable as soon as both are in.
  await Promise.all([pollServerLog(), loadState()]);
  if (state && !state.configured) showSettings('connection');
  await loadApps();
  loadPrefs();
  // Steps still running from before a reload (or another tab): shown again,
  // and finished here as if they had been started from this page.
  const running = await api('/api/jobs');
  for (const j of (running.ok && running.jobs) || []) {
    runDialog('Still running', `${j.kind} - started before this page was opened. Its output follows; the result is saved when it ends.`);
    followJob(j.job, ok => { toast(ok ? `${j.kind}: finished.` : `${j.kind}: failed - see the log.`, !ok); loadApps(); },
      { log: 'runLog', startText: `Following: ${j.kind}` });
    break;   // one at a time, like everything the page starts; the server finishes any others
  }
  // Settings > Automatic checks: Checks runs once when the app opens; the tab
  // shows how many findings there are, and the page stays where it was.
  if (state && state.configured && state.startup && state.startup.drift) {
    $('chkDetails').checked = !!state.startup.fullAudit;
    await runChecks();
    // Only this check at start follows "full check at start": a Run checks afterwards compares everything again (2.38.20 -
    // the box stayed off, and every later check skipped the settings and groups in Intune).
    $('chkDetails').checked = true;
    const shownN = shownFindings().length;
    if (shownN) $('tabChecks').dataset.count = shownN;
    if (shownN) activity(`${stamp()} Checks at start: ${shownN} finding(s) - see Checks.`);
  }
})();
