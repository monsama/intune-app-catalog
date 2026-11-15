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
  if (on) d.style.transform = '';
  const b = d.querySelector('.wctl .wc-max'); if (!b) return;
  b.title = on ? 'Restore' : 'Maximize'; b.setAttribute('aria-label', b.title); b.innerHTML = on ? wcIcon.restore : wcIcon.max;
}
// Minimized = closed but kept: the page works while it waits. Its "close" isn't passed on, so nothing tidies up after it.
function wcMinimize(d) { d.classList.add('minimized'); d.close(); wcTray(); }
function wcRestore(d) { d.classList.remove('minimized'); if (!d.open) d.showModal(); wcTray(); }
window.addEventListener('close', e => { if (e.target instanceof HTMLDialogElement && e.target.classList.contains('minimized')) e.stopImmediatePropagation(); }, true);
// A minimized dialog the app opens again (its button, Ctrl+K) is simply restored.
const wcShow = HTMLDialogElement.prototype.showModal;
HTMLDialogElement.prototype.showModal = function () { const was = this.classList.contains('minimized'); this.classList.remove('minimized'); if (!this.open) wcShow.call(this); if (was) wcTray(); };

function wcTray() {
  let tray = document.getElementById('dlgTray');
  const mins = [...document.querySelectorAll('dialog.minimized')];
  if (!mins.length) { if (tray) tray.remove(); return; }
  if (!tray) { tray = el('div', { id: 'dlgTray', role: 'group', 'aria-label': 'Minimized windows' }); document.body.appendChild(tray); }
  tray.replaceChildren(...mins.map(d => el('span', { class: 'tray-chip' },
    el('button', { type: 'button', class: 'tray-open', text: wcTitle(d), title: `${wcTitle(d)}: restore`, onclick: () => wcRestore(d) }),
    el('button', { type: 'button', class: 'tray-x', text: '×', title: 'Close', 'aria-label': `Close ${wcTitle(d)}`, onclick: () => wcClose(d) }))));
}

function wcMovable(d, head) {
  let x = 0, y = 0;
  head.classList.add('movable');
  head.addEventListener('pointerdown', e => {
    if (e.button !== 0 || d.classList.contains('maxed') || e.target.closest('button, input, select, textarea, a, .wctl') || matchMedia('(max-width: 760px)').matches) return;
    e.preventDefault();
    const sx = e.clientX, sy = e.clientY, x0 = x, y0 = y;
    head.setPointerCapture(e.pointerId);
    const move = ev => {
      x = x0 + ev.clientX - sx; y = y0 + ev.clientY - sy;
      d.style.transform = `translate(${x}px, ${y}px)`;
      // The title stays reachable: its top inside the window, some of it across.
      const r = d.getBoundingClientRect();
      const dx = r.right < 140 ? 140 - r.right : r.left > innerWidth - 140 ? innerWidth - 140 - r.left : 0, dy = r.top < 0 ? -r.top : r.top > innerHeight - 48 ? innerHeight - 48 - r.top : 0;
      if (dx || dy) { x += dx; y += dy; d.style.transform = `translate(${x}px, ${y}px)`; }
    };
    const up = () => { head.removeEventListener('pointermove', move); head.removeEventListener('pointerup', up); head.removeEventListener('pointercancel', up); };
    head.addEventListener('pointermove', move); head.addEventListener('pointerup', up); head.addEventListener('pointercancel', up);
  });
  head.addEventListener('dblclick', e => { if (!e.target.closest('button, input, select, textarea, a, .wctl')) wcMax(d); });
  // Each opening starts in the middle again, at its normal size.
  d.addEventListener('close', () => { if (!d.classList.contains('minimized')) { x = 0; y = 0; d.style.transform = ''; wcMax(d, false); } });
}

for (const d of document.querySelectorAll('dialog')) {
  if (wcNo.has(d.id)) continue;
  const strip = el('span', { class: 'wctl' });
  strip.innerHTML = `<button type="button" class="wc-min" title="Minimize" aria-label="Minimize">${wcIcon.min}</button><button type="button" class="wc-max" title="Maximize" aria-label="Maximize">${wcIcon.max}</button><button type="button" class="wc-close" title="Close (Esc)" aria-label="Close">${wcIcon.close}</button>`;
  strip.querySelector('.wc-min').addEventListener('click', () => wcMinimize(d));
  strip.querySelector('.wc-max').addEventListener('click', () => wcMax(d));
  strip.querySelector('.wc-close').addEventListener('click', () => wcClose(d));
  // Last in the dialog: opening it focuses its first field, not Minimize.
  d.classList.add('haswctl'); d.append(strip);
  const head = d.querySelector('.addhead, .trayhead') || d.querySelector('h2');
  if (head) { head.classList.add('wtitle'); wcMovable(d, head); }
}
