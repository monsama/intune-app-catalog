// Intune App Catalog - web interface: minimize, maximize and close in every dialog's top right corner, as in the
// other NOBS apps. A minimized dialog keeps what was typed in it and waits as a chip at the bottom right (its name
// restores it, x closes it); maximized it fills the window. A dialog moves by its title, and a double-click on the
// title maximizes it. Close goes through the dialog's own "cancel" (unsaved changes, a running step), as Escape does.
'use strict';

const wcNo = new Set(['dlgAsk', 'dlgPalette', 'dlgRun']);
const wcSvg = p => `<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${p}</svg>`;
const wcIcon = { min: wcSvg('<path d="M5 12h14"/>'), max: wcSvg('<rect x="4.5" y="4.5" width="15" height="15" rx="1"/>'), restore: wcSvg('<rect x="8" y="4" width="12" height="12" rx="1"/><path d="M4 8v12h12"/>'), close: wcSvg('<path d="M6 6l12 12M18 6L6 18"/>') };
const wcTitle = d => { const h = d.querySelector('h2'); return (h && h.textContent.trim()) || d.getAttribute('aria-label') || 'Dialog'; };

// Closing "like Escape": the dialog's cancel handlers may say no (unsaved changes, a step still running).
function wcClose(d) {
  if (d.classList.contains('minimized')) wcRestore(d);
  const ev = new Event('cancel', { cancelable: true });
  if (d.dispatchEvent(ev)) d.close();
}
function wcMax(d, on = !d.classList.contains('maxed')) {
  d.classList.toggle('maxed', on);
  if (on) wcUnplace(d);
  const b = d.querySelector('.wctl .wc-max'); if (!b) return;
  b.title = on ? 'Restore' : 'Maximize'; b.setAttribute('aria-label', b.title); b.innerHTML = on ? wcIcon.restore : wcIcon.max;
}
// Minimized = closed but kept: the page works while it waits. Its "close" isn't passed on, so nothing tidies up after it.
function wcMinimize(d) { d.classList.add('minimized'); d.close(); wcTray(); }
function wcRestore(d) { d.classList.remove('minimized'); if (!d.open) d.showModal(); wcTray(); d.dispatchEvent(new Event('wcrestore')); }
// Opening a dialog that waits minimized brings it back as it was - never refilled over what's in it (a half-edited app,
// a deploy still running). The opener stops when this says true.
function wcResume(id) {
  const d = document.getElementById(id);
  if (!d || !d.classList.contains('minimized')) return false;
  wcRestore(d);
  toast(`${wcTitle(d)} was minimized - here it is, as you left it. Close it to open it for something else.`);
  return true;
}
window.addEventListener('close', e => { if (e.target instanceof HTMLDialogElement && e.target.classList.contains('minimized')) e.stopImmediatePropagation(); }, true);
// A minimized dialog the app opens again (its button, Ctrl+K) is simply restored.
const wcShow = HTMLDialogElement.prototype.showModal;
// Modal dialogs in the order they were opened - the last one is on top (the page order says nothing about that).
const wcStack = [];
HTMLDialogElement.prototype.showModal = function () { const was = this.classList.contains('minimized'); this.classList.remove('minimized'); if (!this.open) { wcShow.call(this); const i = wcStack.indexOf(this); if (i >= 0) wcStack.splice(i, 1); wcStack.push(this); } if (was) wcTray(); else wcTrayTop(); };
window.addEventListener('close', e => { const i = wcStack.indexOf(e.target); if (i >= 0) wcStack.splice(i, 1); }, true);
// The chips stay usable while another dialog is open: an open modal dialog makes the rest of the page inert, so the
// tray goes into the topmost one (and back to the page when none is open).
function wcTrayTop() {
  const t = document.getElementById('dlgTray'); if (!t) return;
  const top = wcStack.filter(d => d.open && d.matches(':modal')).pop();
  const host = top || document.body;
  if (t.parentElement !== host) host.append(t);
}
window.addEventListener('close', () => setTimeout(wcTrayTop, 0), true);

function wcTray() {
  let tray = document.getElementById('dlgTray');
  const mins = [...document.querySelectorAll('dialog.minimized')];
  if (!mins.length) { if (tray) tray.remove(); return; }
  if (!tray) { tray = el('div', { id: 'dlgTray', role: 'group', 'aria-label': 'Minimized windows' }); document.body.appendChild(tray); }
  tray.replaceChildren(...mins.map(d => el('span', { class: 'tray-chip' },
    el('button', { type: 'button', class: 'tray-open', text: wcTitle(d), title: `${wcTitle(d)}: restore`, onclick: () => wcRestore(d) }),
    el('button', { type: 'button', class: 'tray-x', text: '×', title: 'Close', 'aria-label': `Close ${wcTitle(d)}`, onclick: () => wcClose(d) }))));
  wcTrayTop();
}

// Moved by position (left/top), not a transform: a transform would make the dialog the frame of everything fixed inside it (the tray).
function wcPlace(d, left, top) { Object.assign(d.style, { margin: '0', left: left + 'px', top: top + 'px', right: 'auto', bottom: 'auto' }); }
function wcUnplace(d) { for (const k of ['margin', 'left', 'top', 'right', 'bottom', 'transform']) d.style[k] = ''; }
function wcMovable(d, head) {
  head.classList.add('movable');
  head.addEventListener('pointerdown', e => {
    if (e.button !== 0 || d.classList.contains('maxed') || e.target.closest('button, input, select, textarea, a, .wctl') || matchMedia('(max-width: 760px)').matches) return;
    e.preventDefault();
    const r0 = d.getBoundingClientRect(), sx = e.clientX, sy = e.clientY;
    wcPlace(d, r0.left, r0.top);
    head.setPointerCapture(e.pointerId);
    const move = ev => {
      // The title stays reachable: its top inside the window, some of it across.
      let l = r0.left + ev.clientX - sx, t = r0.top + ev.clientY - sy;
      l = Math.min(Math.max(l, 140 - r0.width), innerWidth - 140); t = Math.min(Math.max(t, 0), innerHeight - 48);
      wcPlace(d, l, t);
    };
    const up = () => { head.removeEventListener('pointermove', move); head.removeEventListener('pointerup', up); head.removeEventListener('pointercancel', up); };
    head.addEventListener('pointermove', move); head.addEventListener('pointerup', up); head.addEventListener('pointercancel', up);
  });
  head.addEventListener('dblclick', e => { if (!e.target.closest('button, input, select, textarea, a, .wctl')) wcMax(d); });
  // Each opening starts in the middle again, at its normal size.
  d.addEventListener('close', () => { if (!d.classList.contains('minimized')) { wcUnplace(d); wcMax(d, false); } });
}

// Minimize, maximize and close, and moving by the title - for every dialog, also one made later (wcSetup).
function wcSetup(d) {
  if (wcNo.has(d.id) || d.classList.contains('haswctl')) return;
  const strip = el('span', { class: 'wctl' });
  strip.innerHTML = `<button type="button" class="wc-min" title="Minimize" aria-label="Minimize">${wcIcon.min}</button><button type="button" class="wc-max" title="Maximize" aria-label="Maximize">${wcIcon.max}</button><button type="button" class="wc-close" title="Close (Esc)" aria-label="Close">${wcIcon.close}</button>`;
  strip.querySelector('.wc-min').addEventListener('click', () => wcMinimize(d));
  strip.querySelector('.wc-max').addEventListener('click', () => wcMax(d));
  strip.querySelector('.wc-close').addEventListener('click', () => wcClose(d));
  // Last in the dialog: opening it focuses its first field, not Minimize.
  d.classList.add('haswctl'); d.append(strip);
  // A long dialog scrolls (the editor with a section open): the buttons stay in its top right corner, in sight.
  d.addEventListener('scroll', () => { strip.style.top = (10 + d.scrollTop) + 'px'; }, { passive: true });
  d.addEventListener('close', () => { strip.style.top = ''; });
  const head = d.querySelector('.addhead, .trayhead') || d.querySelector('h2');
  if (head) { head.classList.add('wtitle'); wcMovable(d, head); }
}
for (const d of document.querySelectorAll('dialog')) wcSetup(d);
window.wcSetup = wcSetup;
