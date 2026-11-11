// Intune App Catalog - web interface: start-up. Loaded last (see index.html).
'use strict';

// ---------------------------------------------------------------- start
(async function start() {
  let v = 'apps'; try { v = localStorage.getItem('view') || 'apps'; } catch (e) { }
  showView(v);
  await pollServerLog();
  await loadState();
  if (state && !state.configured) showView('settings');
  await loadApps();
  loadPrefs();
  // Settings > Automatic checks: Checks runs once when the app opens; the tab
  // shows how many findings there are, and the page stays where it was.
  if (state && state.configured && state.startup && state.startup.drift) {
    $('chkDetails').checked = !!state.startup.fullAudit;
    await runChecks();
    if (findings.length) $('tabChecks').dataset.count = findings.length;
    if (findings.length) activity(`${stamp()} Checks at start: ${findings.length} finding(s) - see Checks.`);
  }
})();
