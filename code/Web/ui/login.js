// Intune App Catalog - the sign-in page of the server version (the container).
// The session's token goes where the desktop app keeps its start token (sessionStorage), and the app opens.
'use strict';
(function () {
  const $ = id => document.getElementById(id);
  const why = { takenover: 'You were signed out: someone signed in from another browser.', expired: 'Your session ended after a while without use - sign in again.', signedout: 'Signed out.', signin: '',
    'entra-expired': 'That sign-in took too long or was already used - try again.',
    'entra-cancelled': 'Signing in with Microsoft was cancelled.',
    'entra-failed': "Signing in with Microsoft didn't work - the server's log says why (Settings > Diagnostics, or docker compose logs).",
    'entra-notmember': "Your Microsoft account isn't in the group that may sign in here. An admin adds it in Entra ID.",
    'entra-groupcheck': "Your account couldn't be checked against the sign-in group - the app registration needs GroupMember.Read.All (Settings > Connection).",
    'entra-off': 'Sign in with Microsoft is turned off.', 'entra-noconnection': 'Sign in with Microsoft needs the connection set up first.', 'entra-busy': 'Too many sign-ins at once - try again in a minute.' };
  const r = new URLSearchParams(location.search).get('why') || '';
  if (why[r]) { $('loginWhy').textContent = why[r]; $('loginWhy').hidden = false; if (/^entra-(failed|notmember|groupcheck|off|noconnection|busy)$/.test(r)) $('loginWhy').classList.add('bad'); }
  // Theme as the app has it (remembered per browser).
  // Never chosen (auto): the system's, as the app does it (2.38.3 - the sign-in page was light while the app opened dark).
  let t = ''; try { t = localStorage.getItem('theme') || ''; } catch (e) { }
  document.documentElement.dataset.theme = t === 'light' || t === 'dark' ? t : (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  const post = (path, body) => fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) }).then(x => x.json());
  // Back from signing in with Microsoft: the one-time code in the #fragment (never sent anywhere) is traded for the session.
  const ho = /^#handoff=([0-9a-f]{32})$/.exec(location.hash);
  if (ho) {
    history.replaceState(null, '', location.pathname);
    post('/api/login', { handoff: ho[1] }).then(j => {
      if (j && j.ok && j.token) { try { sessionStorage.setItem('iacTok', j.token); } catch (x) { } location.replace('/'); return; }
      $('loginWhy').textContent = (j && j.error) || 'Signing in did not work.'; $('loginWhy').hidden = false; $('loginWhy').classList.add('bad');
    }).catch(() => { $('loginWhy').textContent = 'The server did not answer.'; $('loginWhy').hidden = false; });
  }
  post('/api/hello').then(h => {
    if (h && h.version) $('loginVer').textContent = 'v' + h.version;
    // The ways in this server offers: Sign in with Microsoft and/or the admin password.
    const si = (h && h.signIn) || { password: true };
    $('loginMs').hidden = !si.entra; $('loginPw').hidden = !si.password; $('loginOr').hidden = !(si.entra && si.password);
    $('loginPassword').required = !!si.password;
    if (si.password && !si.entra) $('loginPassword').focus(); else if (si.entra) $('loginMs').focus();
    // The desktop app has no sign-in: its page gets its token from the app window.
    if (h && !h.server) { $('loginError').textContent = 'This is the desktop app - it opens in its own window. Start it again to get a new one.'; $('loginError').hidden = false; $('loginGo').disabled = true; }
  }).catch(() => {});
  $('loginForm').addEventListener('submit', async e => {
    e.preventDefault();
    const b = $('loginGo'); b.disabled = true; b.textContent = 'Signing in...';
    $('loginError').hidden = true;
    try {
      const j = await post('/api/login', { password: $('loginPassword').value });
      if (j && j.ok && j.token) {
        try { sessionStorage.setItem('iacTok', j.token); } catch (x) { }
        location.replace('/');
        return;
      }
      $('loginError').textContent = (j && j.error) || 'Signing in did not work.';
    } catch (x) { $('loginError').textContent = 'The server did not answer.'; }
    $('loginError').hidden = false; $('loginPassword').select();
    b.disabled = false; b.textContent = 'Sign in';
  });
})();
