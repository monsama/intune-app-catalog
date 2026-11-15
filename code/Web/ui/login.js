// Intune App Catalog - the sign-in page of the server version (the container).
// The session's token goes where the desktop app keeps its start token (sessionStorage), and the app opens.
'use strict';
(function () {
  const $ = id => document.getElementById(id);
  const why = { takenover: 'You were signed out: the admin signed in from another browser.', expired: 'Your session ended after a while without use - sign in again.', signedout: 'Signed out.', signin: '' };
  const r = new URLSearchParams(location.search).get('why') || '';
  if (why[r]) { $('loginWhy').textContent = why[r]; $('loginWhy').hidden = false; }
  // Theme as the app has it (remembered per browser).
  try { const t = localStorage.getItem('theme'); if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t; } catch (e) { }
  const post = (path, body) => fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) }).then(x => x.json());
  post('/api/hello').then(h => {
    if (h && h.version) $('loginVer').textContent = 'v' + h.version;
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
