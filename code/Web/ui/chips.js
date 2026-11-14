// Intune App Catalog - web interface: group boxes as chips. Each "one group per line" box
// becomes a row of group chips (x removes one) and an "Add a group" field: type, pick a
// suggestion or press Enter (also comma, semicolon, a pasted list). The text box stays,
// hidden, as the value everything else reads and writes - setting it redraws the chips.
'use strict';

const chipBoxes = ['gRequired', 'gAvailable', 'gUninstall', 'gExclude', 'adRequired', 'adAvailable', 'pilotGroups', 'favGroups', 'sGroups'];
// -opts: what = 'a group' | 'an app' | 'an address' (the placeholder), list = () => suggestions (a datalist: apps), check = text => '' or why it can't be one.
function chipify(id, opts = {}) {
  const ta = typeof id === 'string' ? $(id) : id; if (!ta || ta._chips) return;
  id = ta.id;
  const isInput = ta.tagName === 'INPUT', sep = isInput ? ', ' : '\n';
  const proto = Object.getOwnPropertyDescriptor(isInput ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype, 'value');
  const lines = () => proto.get.call(ta).split(isInput ? /[\n,;]+/ : '\n').map(s => s.trim()).filter(Boolean);
  const what = opts.what || 'a group';
  const label = (ta.closest('label') && ta.closest('label').firstChild && ta.closest('label').firstChild.textContent.trim()) || (ta.getAttribute('aria-label') || 'Groups');
  const input = el('input', { id: id + 'Chips', class: 'chipinput', placeholder: lines().length ? 'Add...' : `Add ${what}...`, 'aria-label': `${label}: add ${what}`, autocomplete: 'off', spellcheck: 'false' });
  if (opts.list) { const dl = el('datalist', { id: id + 'List' }); input.setAttribute('list', id + 'List'); input.addEventListener('focus', () => dl.replaceChildren(...opts.list().map(v => el('option', { value: v })))); ta.after(dl); }
  const box = el('div', { class: 'chipbox', id: id + 'Box', onclick: e => { if (e.target === box) input.focus(); } });
  input._source = ta;
  const set = list => { proto.set.call(ta, list.join(sep)); ta.dispatchEvent(new Event('input', { bubbles: true })); ta.dispatchEvent(new Event('change', { bubbles: true })); render(); };
  const render = () => {
    const list = lines();
    box.replaceChildren(...list.map(g => el('span', { class: 'chip tag', title: g }, el('span', { class: 't', text: g }),
      el('button', { type: 'button', class: 'x', text: '×', 'aria-label': `Remove ${g}`, title: `Remove ${g}`, onclick: e => { e.preventDefault(); set(lines().filter(x => x !== g)); input.focus(); } }))), input);
    input.placeholder = list.length ? 'Add...' : `Add ${what}...`;
  };
  input._addChip = text => {
    const have = lines(), add = String(text).split(/[\n,;]+/).map(s => s.trim()).filter(Boolean);
    for (const g of add) {
      const why = opts.check ? opts.check(g) : '';
      if (why) { toast(why, true); continue; }
      if (!have.some(h => h.toLowerCase() === g.toLowerCase())) have.push(g);
    }
    input.value = ''; set(have);
  };
  input.addEventListener('keydown', e => {
    if (['Enter', ',', ';', 'Tab'].includes(e.key)) {
      // The suggestion list picks its highlighted group itself.
      if (typeof gpList !== 'undefined' && !gpList.hidden && gpBox === input) return;
      if (!input.value.trim()) return;
      e.preventDefault(); input._addChip(input.value);
    }
    else if (e.key === 'Backspace' && !input.value && lines().length) { e.preventDefault(); set(lines().slice(0, -1)); }
  });
  input.addEventListener('paste', e => { const t = (e.clipboardData || window.clipboardData).getData('text'); if (/[\n,;]/.test(t)) { e.preventDefault(); input._addChip(t); } });
  input.addEventListener('blur', () => setTimeout(() => { if (input.value.trim() && document.activeElement !== input && !(typeof gpList !== 'undefined' && !gpList.hidden && gpBox === input)) input._addChip(input.value); }, 200));
  // Code that sets the box (filling the editor, a profile, Undo) redraws the chips.
  Object.defineProperty(ta, 'value', { configurable: true, get() { return proto.get.call(ta); }, set(v) { proto.set.call(ta, v); render(); } });
  ta.hidden = true; ta.tabIndex = -1; ta._chips = true;
  ta.after(box);
  render();
  if (!opts.what) { input.dataset.kind = 'group'; if (typeof gpAttach === 'function') gpAttach(input); }
  return input;
}
for (const id of chipBoxes) chipify(id);
chipify('alTo', { what: 'an address', check: t => /^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(t) ? '' : `'${t}' isn't an email address.` });
chipify('dDeps', { what: 'an app', list: () => apps.map(a => a.name) });

// ---------------------------------------------------------------- return codes as rows: code + what it means
const codeTypes = [['success', 'Success'], ['softReboot', 'Success - restart later'], ['hardReboot', 'Success - restart now'], ['retry', 'Retry'], ['failed', 'Failed']];
function codeRows(id) {
  const ta = $(id); if (!ta || ta._rows) return;
  const proto = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
  const parse = () => proto.get.call(ta).split('\n').map(s => s.trim()).filter(Boolean).map(l => { const m = /^(-?\d+)\s*[=:]\s*(\w+)$/.exec(l); return m ? { code: m[1], type: m[2] } : { code: l, type: 'success' }; });
  const box = el('div', { class: 'coderows', id: id + 'Rows' });
  const write = () => { proto.set.call(ta, [...box.querySelectorAll('.coderow')].map(r => `${r.querySelector('input').value.trim()} = ${r.querySelector('select').value}`).filter(l => !/^ =/.test(l)).join('\n')); ta.dispatchEvent(new Event('input', { bubbles: true })); ta.dispatchEvent(new Event('change', { bubbles: true })); };
  const row = (code, type) => {
    const r = el('div', { class: 'coderow' },
      el('input', { type: 'text', inputmode: 'numeric', value: code, 'aria-label': 'Exit code', placeholder: 'e.g. 0', pattern: '-?\\d+', oninput: write }),
      el('select', { 'aria-label': 'What the exit code means', onchange: write }, ...codeTypes.map(([v, t]) => el('option', { value: v, text: t, selected: v === type }))),
      el('button', { type: 'button', class: 'btn small ghost', text: 'Remove', 'aria-label': `Remove exit code ${code || ''}`.trim(), onclick: () => { r.remove(); write(); } }));
    return r;
  };
  const render = () => box.replaceChildren(...parse().map(x => row(x.code, x.type)), el('button', { type: 'button', class: 'btn small', text: 'Add a return code', onclick: () => { const r = row('', 'success'); box.insertBefore(r, box.lastChild); r.querySelector('input').focus(); } }));
  Object.defineProperty(ta, 'value', { configurable: true, get() { return proto.get.call(ta); }, set(v) { proto.set.call(ta, v); render(); } });
  ta.hidden = true; ta.tabIndex = -1; ta._rows = true;
  ta.after(box); render();
}
for (const id of ['xCodes', 'dCodes', 'bCodes']) codeRows(id);

// ---------------------------------------------------------------- release rings as rows: a name + its groups
function ringRows(id) {
  const ta = $(id); if (!ta || ta._rows) return;
  const proto = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
  let n = 0;
  const parse = () => proto.get.call(ta).split('\n').map(s => s.trim()).filter(Boolean).map(l => { const m = /^([^:]+):\s*(.*)$/.exec(l); return m ? { name: m[1].trim(), groups: m[2].split(',').map(g => g.trim()).filter(Boolean) } : { name: l, groups: [] }; });
  const box = el('div', { class: 'ringrows', id: id + 'Rows' });
  const write = () => { proto.set.call(ta, [...box.querySelectorAll('.ringrow')].map(r => { const nm = r.querySelector('.rname').value.trim(), gs = r.querySelector('textarea').value.split('\n').map(s => s.trim()).filter(Boolean); return nm || gs.length ? `${nm}: ${gs.join(', ')}` : ''; }).filter(Boolean).join('\n')); };
  const row = (name, groups) => {
    const t = el('textarea', { id: `${id}G${++n}`, 'aria-label': `Groups of ring ${name || 'new'}`, rows: 1 });
    const r = el('div', { class: 'ringrow' }, el('span', { class: 'muted rnum' }), el('input', { class: 'rname', value: name, placeholder: 'Ring name, e.g. Early adopters', 'aria-label': 'Ring name', oninput: write }), t,
      el('button', { type: 'button', class: 'btn small ghost', text: 'Remove', 'aria-label': `Remove ring ${name || ''}`.trim(), onclick: () => { r.remove(); write(); number(); } }));
    t.value = groups.join('\n'); t.addEventListener('input', write);
    setTimeout(() => chipify(t), 0);
    return r;
  };
  const number = () => [...box.querySelectorAll('.ringrow .rnum')].forEach((s, i) => { s.textContent = `Ring ${i + 2}`; });
  const render = () => { box.replaceChildren(...parse().map(x => row(x.name, x.groups)), el('button', { type: 'button', class: 'btn small', text: 'Add a ring', onclick: () => { const r = row('', []); box.insertBefore(r, box.lastChild); number(); r.querySelector('.rname').focus(); } })); number(); };
  Object.defineProperty(ta, 'value', { configurable: true, get() { return proto.get.call(ta); }, set(v) { proto.set.call(ta, v); render(); } });
  ta.hidden = true; ta.tabIndex = -1; ta._rows = true;
  ta.after(box); render();
}
ringRows('releaseRings');
