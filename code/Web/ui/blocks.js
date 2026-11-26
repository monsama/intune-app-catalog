'use strict';
// ---------------------------------------------------------------- blocks (2.26)
// The install and uninstall commands and the detection script as blocks: locked ones (what the tool writes the same
// way for every app), editable ones (this app's values) and linked ones (set in another field). The server reads them
// from the commands and writes them back (/api/install-blocks, /api/install-compose, ...) - the commands in the fields
// stay the one truth, Save saves them as before. "Edit as text" makes a command the app's own, kept exactly as typed.
// And the package scripts (Install.ps1, ...) edited in a code editor with locked lines, checked as you type.
// One scope of its own: nothing here can clash with another page's names (scripts.js has its own saveScript).
(() => {
const bs = { inst: null, det: null, instText: false, detText: false, seq: 0, dseq: 0, cseq: 0, app: '' };

// The block that has the focus and its caret, so a redraw puts both back.
function keepFocus(host) {
  const a = document.activeElement;
  if (!a || !host.contains(a) || !a.dataset.bid) return () => {};
  const id = a.dataset.bid, s = a.selectionStart, e = a.selectionEnd;
  return () => { const n = host.querySelector(`[data-bid="${CSS.escape(id)}"]`); if (n) { n.focus(); try { if (s != null) n.setSelectionRange(s, e); } catch (x) { } } };
}
// A field in the block being typed in (changed, not yet left): no redraw under the fingers.
const typingIn = host => { const a = document.activeElement; return !!(a && host.contains(a) && a.tagName === 'INPUT' && a.value !== a.defaultValue); };

// The command fields / script under the blocks: folded away while the blocks show them, open when they are the only
// way to see or change it (no blocks, edited as text, your own). Folded or opened again only when that changes.
function setRawShown(host, mode) {
  const raw = $(host.id === 'instBlocks' ? 'instRaw' : 'detRaw'); if (!raw) return;
  raw.classList.toggle('plain', mode === 'plain');
  if (raw.dataset.mode !== mode) { raw.open = mode !== 'blocks'; raw.dataset.mode = mode; }
}
// A linked block changed right in the row: the control writes into the field it is linked to (the one truth - Save,
// the method's own checks and the commands follow from there, as when it is changed in that field).
function setLinked(id, v, opts) {
  const f = $(id); if (!f || f.value === v) return;
  f.value = v;
  f.dispatchEvent(new Event('input', { bubbles: true })); f.dispatchEvent(new Event('change', { bubbles: true }));
  // The field may say no (Managed without a version, a hand-edited command kept): the row shows what it is then.
  if (opts.onLinked) setTimeout(opts.onLinked, 1200);
}
function inlineLink(b, card, tip, opts) {
  const row = (...val) => card.append(el('div', { class: 'blk edit inline', title: tip }, el('span', { class: 'blab' }, b.label), el('span', { class: 'bval' }, ...val)));
  if (b.link === 'aWinget' && b.id === 'cmd') {
    // winget install --id [Winget ID] -e ... : only the ID is this app's.
    const id = $('aWinget').value.trim(), at = b.text.indexOf(' ' + id + ' ');
    if (!id || at < 0) return false;
    const input = el('input', { value: id, 'data-bid': 'wingetId', 'aria-label': 'Winget ID', spellcheck: 'false', size: Math.max(12, id.length + 2),
      onchange: e => { const v = e.target.value.trim(); if (v) setLinked('aWinget', v, opts); else e.target.value = $('aWinget').value; } });
    row(el('span', { class: 'bpre', text: b.text.slice(0, at + 1) }), input, el('span', { class: 'bpre', text: b.text.slice(at + id.length + 1) }));
    return true;
  }
  if (b.link === 'aMethod') {
    const pinned = /pinned/.test(b.text), cur = $('aMethod').value;
    if (cur !== 'Managed' && cur !== 'Winget' && cur !== 'Self') return false;   // an own command: the method row explains it
    const sel = el('select', { 'data-bid': 'method', 'aria-label': 'Version - install with', onchange: e => setLinked('aMethod', e.target.value, opts) },
      el('option', { value: 'Managed', text: pinned ? b.text : 'pinned to the App version (managed updates)' }),
      el('option', { value: 'Winget', text: 'the newest winget has' }));
    sel.value = pinned ? 'Managed' : 'Winget';
    row(sel); return true;
  }
  if (b.link === 'xContext') {
    const sel = el('select', { 'data-bid': 'context', 'aria-label': 'Install for', onchange: e => setLinked('xContext', e.target.value, opts) },
      el('option', { value: 'System', text: 'the device (--scope machine)' }), el('option', { value: 'User', text: 'the signed-in user' }));
    sel.value = $('xContext').value === 'User' ? 'User' : 'System';
    row(sel); return true;
  }
  return false;
}
function renderBlockBar(host, model, opts = {}) {
  const { onChange, onAction, onText, onBlocks, textMode } = opts;
  host.replaceChildren();
  host.hidden = !model || model.form === 'none' || model.form === 'rule';
  setRawShown(host, host.hidden ? 'plain' : (model.own || textMode) ? 'text' : 'blocks');
  if (host.hidden) return;
  const head = el('div', { class: 'bhead' });
  if (model.own || textMode) {
    head.append(el('span', { class: 'bown', text: textMode ? `Edited as text - your own ${opts.what || 'command'}, kept exactly as typed.` : (model.note || 'Your own command, kept exactly as typed.') }));
    // Back to blocks only when what's typed is one of their forms (nothing typed is lost).
    if (textMode && !model.own && onBlocks) head.append(el('button', { type: 'button', class: 'btn small ghost', text: 'Back to blocks', title: 'Show it as blocks again - it is one of their forms', onclick: onBlocks }));
    if (opts.what !== 'script') head.append(el('button', { type: 'button', class: 'btn small', text: 'Open in the code editor', title: 'Both commands with colours, a find and the 1024-character count', onclick: () => openScriptEditor({ command: 'install' }) }));
    host.append(head);
    return;
  }
  head.append(el('span', { class: 'bform', text: { winget: 'Winget', msi: 'MSI', exe: 'Installer (.exe)', script: 'PowerShell script', psadt: 'PSADT 4', managed: 'Managed release', installed: 'Installed app' }[model.form] || model.form }),
    model.note ? el('span', { class: 'bnote', text: model.note }) : '',
    // An older generated form: rewritten in today's form in one click (the same values - nothing else changes).
    model.form === 'winget' && /older form/.test(model.note || '') && onChange ? el('button', { type: 'button', class: 'btn small', text: "Write today's form", title: 'The same Winget ID, version, scope and options - written the way the app writes them now', onclick: () => { const o = model.blocks.find(b => b.id === 'options'); onChange({ options: (o && o.value) || [] }); } }) : '',
    el('button', { type: 'button', class: 'btn small ghost', text: 'Edit as text', title: 'Write it yourself - it is then your own, kept exactly as typed', onclick: onText }));
  host.append(head);
  const values = {};
  // A list entry without its name or value yet stays here until it has both - only complete values go to the server.
  const fire = () => {
    const incomplete = model.blocks.some(b => b.kind === 'list' && (values[b.id] || []).some(x => !String(x.name).trim() || !String(x.value).trim()));
    if (!incomplete) { onChange({ ...values }); return; }
    renderBlockBar(host, { ...model, blocks: model.blocks.map(b => b.id in values ? { ...b, value: values[b.id] } : b) }, opts);
    const empty = [...host.querySelectorAll('.brec input')].find(i => !i.value.trim()); if (empty) empty.focus();
  };
  // One row per block: its label (with a lock, pencil or link icon) on the left, its value on the right.
  const where = { aMethod: 'Install with', xContext: 'Install for', mAppVersion: 'App version', aWinget: 'Winget ID' };
  const card = el('div', { class: 'brec' });
  host.append(card);
  // The fixed parts (the same for every app) folded into one line - this app's values and links stay in view.
  const fixedN = model.blocks.filter(b => b.kind === 'lock').length;
  let showFixed = false; try { showFixed = localStorage.getItem('blocksShowFixed') === '1'; } catch (e) { }
  card.classList.toggle('showfixed', showFixed);
  if (fixedN) card.append(el('button', { type: 'button', class: 'bfixed', 'aria-expanded': String(showFixed),
    text: showFixed ? `Hide the ${fixedN} fixed part${fixedN === 1 ? '' : 's'}` : `${fixedN} fixed part${fixedN === 1 ? '' : 's'} - the same for every app`,
    title: 'What the tool writes the same way for every app - shown for reading, not for changing',
    onclick: e => { const on = !card.classList.contains('showfixed'); card.classList.toggle('showfixed', on); try { localStorage.setItem('blocksShowFixed', on ? '1' : '0'); } catch (x) { }
      e.currentTarget.setAttribute('aria-expanded', String(on)); e.currentTarget.textContent = on ? `Hide the ${fixedN} fixed part${fixedN === 1 ? '' : 's'}` : `${fixedN} fixed part${fixedN === 1 ? '' : 's'} - the same for every app`; } }));
  let part = '';
  for (const b of model.blocks) {
    if (b.part !== part) {
      // The Uninstall heading: folded with the fixed parts when all of the uninstall is fixed (a winget uninstall).
      const onlyFixed = !model.blocks.some(x => x.part === b.part && x.kind !== 'lock');
      if (part && b.part === 'uninstall') card.append(el('div', { class: 'bsec' + (onlyFixed ? ' onlyfixed' : ''), text: 'Uninstall' }));
      part = b.part;
    }
    const tip = b.help || '';
    const lab = el('span', { class: 'blab' }, b.label);
    if (b.kind === 'lock') card.append(el('div', { class: 'blk lock', title: tip || 'Fixed - the tool writes this the same way for every app.' }, lab, el('span', { class: 'bval', text: b.text })));
    else if (b.kind === 'link' && b.part !== 'detection' && inlineLink(b, card, tip, opts)) { /* changed right here */ }
    else if (b.kind === 'link') {
      const go = () => { const t = $(b.link); if (t) { if (window.edPageFor) edPageFor(t); t.focus(); } };
      card.append(el('div', { class: 'blk link', title: tip }, lab, el('span', { class: 'bval', text: b.text }),
        el('button', { type: 'button', class: 'bgo', text: `${where[b.link] || 'Set elsewhere'} ›`, title: `Set in ${where[b.link] || 'another field'} - go there`, onclick: go })));
    }
    else if (b.kind === 'action') card.append(el('div', { class: 'blk action', title: tip }, lab, el('span', { class: 'bval', text: b.text }),
      el('button', { type: 'button', class: 'btn small', text: `Edit ${b.value}`, title: `Open ${b.value} in the code editor`, onclick: () => onAction(b.value) })));
    else if (b.kind === 'edit') {
      values[b.id] = b.value ?? '';
      const input = b.type === 'select'
        ? el('select', { 'data-bid': b.id, 'aria-label': b.label, onchange: e => { values[b.id] = e.target.value; fire(); } }, ...b.choices.map(c => el('option', { value: c.value, text: c.label })))
        : el('input', { value: b.value ?? '', 'data-bid': b.id, 'aria-label': b.label, spellcheck: 'false', onchange: e => { values[b.id] = e.target.value; fire(); } });
      if (b.type === 'select') input.value = b.value ?? '';
      card.append(el('label', { class: 'blk edit', title: tip }, lab, el('span', { class: 'bval' }, input)));
    }
    else if (b.kind === 'list') {
      const items = (b.value || []).map(x => ({ name: x.name, value: x.value }));
      values[b.id] = items;
      const named = b.choices && b.choices.length && typeof b.choices[0] === 'string';
      const val = el('span', { class: 'bval chips' });
      items.forEach((it, i) => {
        const v = el('input', { value: it.value, 'data-bid': `${b.id}:${i}:v`, placeholder: 'value', 'aria-label': `${it.name} value`, spellcheck: 'false', size: Math.max(5, Math.min(36, String(it.value).length + 1)), onchange: e => { it.value = e.target.value; fire(); } });
        const n = named ? el('span', { class: 'bopt', text: it.name }) : el('input', { class: 'bname', value: it.name, 'data-bid': `${b.id}:${i}:n`, placeholder: 'NAME', 'aria-label': 'Property name', spellcheck: 'false', size: Math.max(5, it.name.length + 1), onchange: e => { it.name = e.target.value; fire(); } });
        val.append(el('span', { class: 'bchip' }, n, el('span', { class: 'beq', text: named ? ' ' : '=' }), v, el('button', { type: 'button', class: 'bx', 'aria-label': `Remove ${it.name}`, title: 'Remove', text: '×', onclick: () => { items.splice(i, 1); fire(); } })));
      });
      const free = named ? b.choices.filter(c => !items.some(x => x.name === c)) : [''];
      if (free.length) {
        val.append(named
          ? el('select', { class: 'badd', 'data-bid': `${b.id}:add`, 'aria-label': `Add to ${b.label}`, title: tip, onchange: e => { if (!e.target.value) return; items.push({ name: e.target.value, value: '' }); fire(); } },
            el('option', { value: '', text: '+ Add' }), ...free.map(c => el('option', { value: c, text: c })))
          : el('button', { type: 'button', class: 'badd', text: '+ Add', title: tip, 'data-bid': `${b.id}:add`, onclick: () => { items.push({ name: '', value: '' }); fire(); } }));
      }
      if (!items.length) val.prepend(el('span', { class: 'bnone', text: 'none' }));
      card.append(el('div', { class: 'blk list', title: tip }, lab, val));
    }
  }
}


// ---------------------------------------------------------------- install and uninstall commands
const instFields = () => ({ wingetId: $('aWinget').value.trim(), install: $('mInstallCommand').value, uninstall: $('mUninstallCommand').value, context: $('xContext').value });
function setCommandsReadOnly(on) {
  for (const id of ['mInstallCommand', 'mUninstallCommand']) { $(id).readOnly = on; $(id).classList.toggle('preview', on); }
}
function setFields(pairs) { for (const [id, v] of pairs) { $(id).value = v; $(id).dispatchEvent(new Event('input', { bubbles: true })); } }
// Writing a block's change back: one answer at a time, and only into the app it was asked for.
async function compose(path, body, apply) {
  const run = composeNow(path, body, apply);
  bs.pending = run;
  try { return await run; } finally { if (bs.pending === run) bs.pending = null; }
}
async function composeNow(path, body, apply) {
  const seq = ++bs.cseq, app = bs.app;
  const c = await api(path, body);
  if (seq !== bs.cseq || app !== bs.app || !$('dlgApp').open) return;
  if (!c.ok) { toast(c.error, true); return false; }
  apply(c); return true;
}
async function refreshBlocks(opening) {
  if (opening) { bs.app = editingName || ''; bs.instText = false; bs.detText = false; }
  const host = $('instBlocks');
  const seq = ++bs.seq, r = await api('/api/install-blocks', instFields());
  if (seq !== bs.seq || !r.ok) return;
  const same = bs.inst && JSON.stringify(bs.inst) === JSON.stringify(r);
  bs.inst = r;
  // Edit as text stays until the editor closes or Back to blocks - typing passes through the blocks' forms on the way.
  setCommandsReadOnly(!r.own && !bs.instText);
  if (same && (typingIn(host) || host.contains(document.activeElement))) return;
  const restore = keepFocus(host);
  renderBlockBar(host, r, {
    textMode: bs.instText,
    onText: () => { bs.instText = true; setCommandsReadOnly(false); renderBlockBar(host, r, { textMode: true, onBlocks: backToBlocks }); openScriptEditor({ command: 'install' }); },
    onBlocks: backToBlocks,
    onChange: values => compose('/api/install-compose', { ...instFields(), form: r.form, values }, c => setFields([['mInstallCommand', c.install], ['mUninstallCommand', c.uninstall]])).then(ok => { if (ok === false) refreshBlocks(); }),
    onAction: file => openScriptEditor({ name: editingName, file }),
    onLinked: () => { bs.inst = null; refreshBlocks(); }
  });
  restore();
}
function backToBlocks() { bs.instText = false; bs.inst = null; refreshBlocks(); }
const blocksSoon = (() => { let t = 0; return () => { clearTimeout(t); t = setTimeout(() => refreshBlocks(), 300); }; })();
for (const id of ['aWinget', 'mInstallCommand', 'mUninstallCommand']) $(id).addEventListener('input', blocksSoon);
$('xContext').addEventListener('change', blocksSoon);

// ---------------------------------------------------------------- detection script
async function refreshDetectionBlocks() {
  const host = $('detBlocks');
  if ($('xType').value !== 'Script') { host.hidden = true; $('xScript').readOnly = false; $('xScript').classList.remove('preview'); return; }
  const seq = ++bs.dseq, r = await api('/api/detection-blocks', { script: $('xScript').value });
  if (seq !== bs.dseq || !r.ok) return;
  const same = bs.det && JSON.stringify(bs.det) === JSON.stringify(r);
  bs.det = r;
  const ro = !r.own && !bs.detText;
  $('xScript').readOnly = ro; $('xScript').classList.toggle('preview', ro);
  if (same && (typingIn(host) || host.contains(document.activeElement))) return;
  const restore = keepFocus(host);
  const back = () => { bs.detText = false; bs.det = null; refreshDetectionBlocks(); };
  renderBlockBar(host, r.form === 'none' ? null : r, {
    what: 'script', textMode: bs.detText, onBlocks: back,
    onText: () => { bs.detText = true; $('xScript').readOnly = false; $('xScript').classList.remove('preview'); refreshDetectionBlocks(); openScriptEditor({ detection: true }); },
    onChange: values => compose('/api/detection-compose', { script: $('xScript').value, form: r.form, values }, c => {
      setFields([['xScript', c.script]]);
      // The managed release's detection is written from this name again at the next release (Name on devices).
      if (r.form === 'managed' && $('arDetected')) $('arDetected').value = c.detectedName;
    }).then(ok => { if (ok === false) refreshDetectionBlocks(); }),
    onAction: () => {}
  });
  // An own script (or one edited as text): the code editor, with the parse check.
  if (!host.hidden && (r.own || bs.detText)) host.append(el('div', { class: 'bfoot' }, el('button', { type: 'button', class: 'btn small', text: 'Open in the code editor', title: 'Line numbers, colours and a parse check as you type', onclick: () => openScriptEditor({ detection: true }) })));
  restore();
}
const detSoon = (() => { let t = 0; return () => { clearTimeout(t); t = setTimeout(refreshDetectionBlocks, 300); }; })();
$('xScript').addEventListener('input', detSoon);
$('xType').addEventListener('change', detSoon);
$('dlgApp').addEventListener('close', () => { if ((se.detection || se.command) && $('dlgCode') && $('dlgCode').open && !$('dlgCode').classList.contains('minimized')) $('dlgCode').close(); });
$('dlgApp').addEventListener('close', () => { bs.instText = false; bs.detText = false; bs.inst = null; bs.det = null; bs.app = ''; bs.cseq++; });

// ---------------------------------------------------------------- the code editor
// A textarea over a highlighted copy of its text, with line numbers. Locked lines (the version marker the
// detection rule reads) can't be changed: edits there are refused as they're typed, and anything that still
// gets through (drop, IME, a paste) is taken back; the server checks again on save.
const PS_KEYWORDS = /^(if|elseif|else|foreach|for|while|do|until|switch|function|param|return|try|catch|finally|throw|exit|break|continue|begin|process|end|in|trap|filter|class)$/i;
function escHtml(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
function highlightPs(text) {
  // One pass over the text: comments, strings, variables, words, numbers - everything else as it is.
  const re = /(<#[\s\S]*?(?:#>|$))|(#[^\n]*)|('(?:[^']|'')*'?)|("(?:[^"`]|`.)*"?)|(\$\{[^}]*\}|\$[\w:]+)|(\b[A-Za-z]+-[A-Za-z]+\b)|(-[A-Za-z]+\b)|(\b\d[\d.]*\b)|(\b[A-Za-z_]\w*\b)/g;
  let out = '', last = 0, m;
  while ((m = re.exec(text))) {
    out += escHtml(text.slice(last, m.index));
    const t = escHtml(m[0]);
    const cls = m[1] || m[2] ? 'c' : m[3] || m[4] ? 's' : m[5] ? 'v' : m[6] ? 'f' : m[7] ? 'p' : m[8] ? 'n' : PS_KEYWORDS.test(m[0]) ? 'k' : '';
    out += cls ? `<span class="${cls}">${t}</span>` : t;
    last = re.lastIndex;
  }
  return out + escHtml(text.slice(last)) + '\n';
}
// The same rule as the server's Get-PackageScriptLockedLines.
function lockedLinesOf(text) {
  const lines = text.split('\n'), locked = new Set();
  lines.forEach((l, i) => {
    if (/^\s*AppVersion\s*=\s*'/.test(l)) { locked.add(i); return; }
    if (!/IntuneAppCatalog\\Apps\\/.test(l)) return;
    locked.add(i);
    if (i > 0 && /^\s*#.*version marker/.test(lines[i - 1])) locked.add(i - 1);
    if (i + 1 < lines.length && /^\s*Set-ItemProperty\b.*-Name\s+Version\b/.test(lines[i + 1])) locked.add(i + 1);
  });
  return locked;
}
const lockedText = text => { const l = text.split('\n'), set = lockedLinesOf(text); return [...set].sort((a, b) => a - b).map(i => l[i]).join('\n'); };

const se = { name: '', file: '', hash: '', original: '', locked: new Set(), errors: [], detection: false, command: '', cmds: null, cmdOrig: null, checkSeq: 0, good: '', want: '', conflict: false, saved: true, lastStatus: '' };
function codeDialog() {
  let d = $('dlgCode');
  if (d) return d;
  d = el('dialog', { id: 'dlgCode', class: 'wide scriptdlg', 'aria-labelledby': 'seTitle' },
    el('div', { class: 'sehead' }, el('h2', { id: 'seTitle' }), el('div', { class: 'setabs', id: 'seTabs', role: 'group', 'aria-label': 'Package scripts' })),
    el('p', { class: 'sub', id: 'seSub' }),
    el('div', { class: 'sefind', id: 'seFind', hidden: true }, el('input', { type: 'search', id: 'seFindText', placeholder: 'Find (Enter: next, Esc: close)', 'aria-label': 'Find in the script' }), el('span', { class: 'muted', id: 'seFindCount' })),
    el('div', { class: 'code' }, el('div', { class: 'gutter', id: 'seGutter', 'aria-hidden': 'true' }), el('div', { class: 'codearea' },
      el('pre', { class: 'hl', id: 'seHl', 'aria-hidden': 'true' }),
      el('textarea', { id: 'seText', spellcheck: 'false', wrap: 'off', 'aria-label': 'Script - Tab indents, Shift+Tab moves on', 'aria-describedby': 'seStatus', autocomplete: 'off', autocorrect: 'off', autocapitalize: 'off' }))),
    el('div', { class: 'sestatus', id: 'seStatus', role: 'status' }),
    el('ul', { class: 'seerrors', id: 'seErrors' }),
    el('div', { class: 'actions split' },
      el('div', {}, el('button', { type: 'button', class: 'btn', id: 'sePrev', text: 'Previous version', title: 'Load the copy kept in Backups at the last save (nothing is saved until you save)' }),
        el('button', { type: 'button', class: 'btn', id: 'seBuild', text: 'Build package', hidden: true, title: "Build the app's .intunewin again with the saved scripts" })),
      el('div', {}, el('span', { class: 'muted sehint', text: 'Tab indents · Shift+Tab moves on · Ctrl+S saves · Ctrl+F finds' }),
        el('button', { type: 'button', class: 'btn', id: 'seClose', text: 'Close' }), el('button', { type: 'button', class: 'btn primary', id: 'seSave', text: 'Save', title: 'Ctrl+S' }))));
  document.body.append(d);
  if (window.wcSetup) wcSetup(d);
  const ta = $('seText');
  ta.addEventListener('input', () => {
    // Whatever got past the checks below (a drop, an IME, a paste of a marker line): the locked lines are put back.
    // A command is one line - Intune takes no line breaks in it.
    if (se.command && /\n/.test(ta.value)) { const pos = ta.selectionStart - 1; ta.value = ta.value.replace(/\r?\n/g, ' '); ta.setSelectionRange(pos, pos); }
    if (se.command) { se.cmds[se.command] = ta.value; se.good = ta.value; }
    else if (!se.detection && lockedText(ta.value) !== se.want) {
      const pos = Math.min(ta.selectionStart, se.good.length); ta.value = se.good; ta.setSelectionRange(pos, pos);
      status('The locked lines (the version marker the detection rule reads) stay as they are - a release changes them.', true);
    } else se.good = ta.value;
    paintScript(); checkSoon();
  });
  ta.addEventListener('scroll', () => { $('seHl').scrollTop = ta.scrollTop; $('seHl').scrollLeft = ta.scrollLeft; $('seGutter').scrollTop = ta.scrollTop; });
  // Refused before it happens: any edit that touches a locked line, or joins a line to one.
  const touchesLocked = inputType => {
    if (!se.locked.size) return false;
    const text = ta.value, lineAt = p => text.slice(0, p).split('\n').length - 1;
    let a = lineAt(ta.selectionStart), b = lineAt(ta.selectionEnd);
    if (inputType.startsWith('delete') && ta.selectionStart === ta.selectionEnd) {
      const p = ta.selectionStart;
      if (/Backward/.test(inputType) && (p === 0 || text[p - 1] === '\n' || /Line|Word/.test(inputType))) a = Math.max(0, a - (p === 0 || text[p - 1] === '\n' ? 1 : 0));
      if (/Forward/.test(inputType) && (text[p] === '\n' || p === text.length || /Line|Word/.test(inputType))) b = b + (text[p] === '\n' ? 1 : 0);
    }
    for (let l = a; l <= b; l++) if (se.locked.has(l)) return true;
    return false;
  };
  ta.addEventListener('beforeinput', e => {
    if (e.inputType === 'insertFromDrop' && se.locked.size) { e.preventDefault(); status("Drag and drop isn't taken here - cut and paste instead.", true); return; }
    if (touchesLocked(e.inputType)) { e.preventDefault(); status('That line is locked - the version marker the detection rule reads. A release changes it.', true); }
  });
  ta.addEventListener('keydown', e => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); e.stopPropagation(); saveScript(); return; }
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); e.stopPropagation(); $('seFind').hidden = false; $('seFindText').focus(); $('seFindText').select(); return; }
    // Tab indents; Shift+Tab moves on to the buttons (no keyboard trap).
    if (e.key === 'Tab' && !e.shiftKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault();
      if (touchesLocked('insertText')) { status('That line is locked - the version marker the detection rule reads.', true); return; }
      document.execCommand('insertText', false, '    ');
    }
  });
  $('seFindText').addEventListener('keydown', e => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); e.stopPropagation(); saveScript(); return; }
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); $('seFind').hidden = true; ta.focus(); return; }
    if (e.key !== 'Enter') return;
    e.preventDefault();
    const q = $('seFindText').value.toLowerCase(); if (!q) return;
    const t = ta.value.toLowerCase(), from = ta.selectionEnd;
    let i = t.indexOf(q, from); if (i < 0) i = t.indexOf(q);
    $('seFindCount').textContent = i < 0 ? 'not found' : `${t.split(q).length - 1} found`;
    if (i >= 0) { ta.focus(); ta.setSelectionRange(i, i + q.length); const line = t.slice(0, i).split('\n').length - 1; ta.scrollTop = Math.max(0, line * lineHeight() - ta.clientHeight / 2); }
  });
  $('seSave').addEventListener('click', saveScript);
  $('seClose').addEventListener('click', closeScript);
  d.addEventListener('cancel', e => { e.preventDefault(); closeScript(); });
  $('sePrev').addEventListener('click', async () => {
    const r = await api('/api/package-script-previous', { name: se.name, file: se.file });
    if (!r.ok) { status(r.error, true); return; }
    if (ta.value !== se.original && !(await ask('Replace what you typed with the previous version?', { ok: 'Replace' }))) return;
    ta.value = r.text.replace(/\r\n?/g, '\n'); se.good = ta.value; paintScript(); checkSoon(); status(`Previous version from ${r.at} loaded - Save keeps it.`);
  });
  $('seBuild').addEventListener('click', async () => {
    const name = se.name;
    if ($('seText').value !== se.original && !(await ask("Build with the saved scripts? What you typed since isn't saved - it won't be in the package, and the editor closes for the build.", { ok: 'Build' }))) return;
    // The progress window is under this one otherwise: the editor closes (everything in it is saved).
    se.original = $('seText').value; $('dlgCode').close();
    runDialog('Package', `Building ${name}'s .intunewin with the saved scripts.`);
    runJob({ names: [name] }, ok => { toast(ok ? `${name}'s package is built.` : 'Packaging failed - see the log.', !ok); if (ok) $('seBuild').hidden = true; loadApps(); }, { path: '/api/package-start', log: 'runLog', startText: 'Packaging...' });
  });
  return d;
}
const lineHeight = () => parseFloat(getComputedStyle($('seText')).lineHeight) || 19;
// Said once per change (role=status reads it out): not again for every keystroke.
function status(text, bad) { const s = $('seStatus'); s.classList.toggle('err', !!bad); if (se.lastStatus === text) return; se.lastStatus = text; s.textContent = text; }
function paintScript() {
  const text = $('seText').value;
  se.locked = se.detection || se.command || se.plain ? new Set() : lockedLinesOf(text);
  if (se.plain) $('seHl').textContent = text + '\n'; else $('seHl').innerHTML = highlightPs(text);
  const lines = text.split('\n'), bad = new Set(se.errors.map(x => x.line - 1));
  $('seGutter').replaceChildren(...lines.map((_, i) => el('div', { class: (se.locked.has(i) ? 'lk' : '') + (bad.has(i) ? ' bad' : ''), title: se.locked.has(i) ? 'Locked - the version marker the detection rule reads' : null, text: String(i + 1) })));
  // Locked lines tinted behind the text.
  const lh = lineHeight(), pad = 8, rows = [...se.locked];
  const hl = $('seHl').style;
  hl.backgroundImage = rows.length ? rows.map(() => 'linear-gradient(var(--lockbg), var(--lockbg))').join(',') : 'none';
  hl.backgroundSize = rows.map(() => `100% ${lh}px`).join(',');
  hl.backgroundPosition = rows.map(i => `0 ${pad + i * lh}px`).join(',');
  hl.backgroundRepeat = 'no-repeat';
  if (se.command) {
    const changed = se.cmds.install !== se.cmdOrig.install || se.cmds.uninstall !== se.cmdOrig.uninstall, long = ['install', 'uninstall'].filter(k => se.cmds[k].length > 1024);
    $('seSave').disabled = !changed || long.length > 0 || !se.cmds.install.trim();
    $('seSave').title = long.length ? `The ${long.join(' and ')} command is longer than Intune's 1024 characters` : !se.cmds.install.trim() ? 'The install command is empty' : changed ? 'Ctrl+S' : 'Nothing changed yet';
    status(`${se.command === 'install' ? 'Install' : 'Uninstall'} command: ${text.length} of 1024 characters${text.length > 1024 ? ' - too long for Intune' : ''}. Apply puts both into the app (Save in the app editor keeps them).`, text.length > 1024);
    return;
  }
  $('seSave').disabled = text === se.original || se.errors.length > 0 || se.conflict;
  $('seSave').title = se.conflict ? 'Changed by someone else since you opened it - close and open it again' : se.errors.length ? "It doesn't parse - see the lines below" : text === se.original ? 'Nothing changed yet' : 'Ctrl+S';
}
const checkSoon = (() => { let t = 0; return () => { clearTimeout(t); t = setTimeout(checkScript, 450); }; })();
async function checkScript() {
  if (se.command) { se.errors = []; $('seErrors').replaceChildren(); paintScript(); return; }
  const seq = ++se.checkSeq, text = $('seText').value;
  const r = await api('/api/package-script-check', { old: se.detection ? '' : se.original, text, file: se.detection ? '' : se.file });
  if (seq !== se.checkSeq || !r.ok) return;
  se.errors = r.errors || [];
  $('seErrors').replaceChildren(...se.errors.slice(0, 8).map(x => el('li', {}, el('button', { type: 'button', class: 'linkbtn', text: `Line ${x.line}:`, onclick: () => goLine(x.line, x.column) }), ' ' + x.message)));
  if (se.conflict) status("Someone else changed this file since you opened it - close it and open it again (copy what you typed first).", true);
  else if (r.valid && se.plain) status(text === se.original ? (/\.(xml|config)$/i.test(se.file) ? 'Well-formed XML.' : 'A text file of the package.') : 'Not saved yet.');
  else if (r.valid) status(se.detection ? 'Parses. Apply puts it into the detection rule (Save in the app editor keeps it).' : (text === se.original ? 'Parses. Grey lines are locked - the version marker the detection rule reads.' : 'Parses - not saved yet.'));
  else status(r.error, true);
  paintScript();
}
function goLine(line, col) {
  const ta = $('seText'), lines = ta.value.split('\n');
  const pos = lines.slice(0, line - 1).reduce((n, l) => n + l.length + 1, 0) + Math.max(0, (col || 1) - 1);
  ta.focus(); ta.setSelectionRange(pos, pos); ta.scrollTop = Math.max(0, (line - 1) * lineHeight() - ta.clientHeight / 2);
}

async function openScriptEditor({ name, file, detection, command }) {
  const d = codeDialog();
  // Minimized with the same script: brought back as it was. Another one: what was typed is asked about first.
  if (d.classList.contains('minimized')) {
    if ((command && se.command && se.forApp === (editingName || '')) || (detection && se.detection && se.forApp === (editingName || '')) || (!detection && !command && !se.detection && !se.command && se.name === name && se.file === file)) { wcResume('dlgCode'); return; }
    wcResume('dlgCode');
    if (!(await leaveScript())) return;
  }
  // Already open on the commands: just the other one of the two.
  if (command && d.open && se.command && se.forApp === (editingName || '')) { showCommand(command); return; }
  // 2.38.17: a text file of the package (SilentClient.cfg, setup.ini, login.xml) - no PowerShell colours, checks or locked lines.
  Object.assign(se, { detection: !!detection, command: command || '', errors: [], conflict: false, lastStatus: '', plain: !detection && !command && !!file && !/\.ps1$/i.test(file) });
  d.classList.toggle('cmdmode', !!command);
  $('seText').setAttribute('wrap', command ? 'soft' : 'off');
  $('seBuild').hidden = true;
  $('sePrev').hidden = se.detection || !!se.command;
  $('seSave').textContent = se.detection || se.command ? 'Apply' : 'Save';
  if (se.command) {
    // Bound to the app open in the editor now, like the detection script.
    const now = { install: $('mInstallCommand').value, uninstall: $('mUninstallCommand').value };
    Object.assign(se, { name: '', file: '', hash: '', forApp: editingName || '', cmds: { ...now }, cmdOrig: { ...now } });
    $('seTitle').textContent = 'Install and uninstall commands';
    $('seSub').textContent = "Your own commands - kept exactly as typed. Each is one line; Intune runs it as SYSTEM from the package folder and takes at most 1024 characters.";
    showCommand(command);
    if (!d.open) d.showModal();
    return;
  }
  if (se.detection) {
    // Bound to the app open in the editor now: Apply never writes into another app's detection.
    Object.assign(se, { name: '', file: '', hash: '', forApp: editingName || '', original: $('xScript').value.replace(/\r\n?/g, '\n') });
    $('seTitle').textContent = 'Detection script';
    $('seSub').textContent = 'Runs as SYSTEM on the device. Installed: write something to the output and exit 0. Not installed: write nothing.';
    $('seTabs').replaceChildren();
  } else {
    const r = await api('/api/package-script', { name, file });
    if (!r.ok) { toast(r.error, true); return; }
    // A textarea keeps line ends as \n: compared that way, an unchanged file isn't "changed" (the server writes Windows line ends).
    Object.assign(se, { name, file, hash: r.hash, original: r.text.replace(/\r\n?/g, '\n') });
    $('seTitle').textContent = `${file} - ${name}`;
    $('seSub').textContent = se.plain ? `In ${r.folder}. A file of the package (its setup or the app reads it) - saved in the encoding it has. Saving keeps the earlier one in Backups; the package needs building again.` : `In ${r.folder}. Runs as SYSTEM from the package folder. Saving keeps the earlier one in Backups; the package needs building again.`;
    $('seTabs').replaceChildren(...r.files.map(f => el('button', { type: 'button', class: 'setab', 'aria-pressed': String(f === file), text: f, title: `Open ${f}`, onclick: async () => { if (f === se.file || !(await leaveScript())) return; openScriptEditor({ name, file: f }); } })));
  }
  se.want = lockedText(se.original); se.good = se.original;
  $('seText').value = se.original;
  $('seFind').hidden = true;
  paintScript(); checkScript();
  if (!d.open) d.showModal();
  $('seText').focus(); $('seText').setSelectionRange(0, 0); $('seText').scrollTop = 0;
}
// The commands mode: two tabs, one command each; what's typed in one is kept while the other is shown.
function showCommand(which) {
  se.command = which;
  $('seTabs').replaceChildren(...['install', 'uninstall'].map(k => el('button', { type: 'button', class: 'setab', 'aria-pressed': String(k === which), text: k === 'install' ? 'Install command' : 'Uninstall command', onclick: () => { if (k !== se.command) showCommand(k); } })));
  se.original = se.cmdOrig[which]; se.good = se.cmds[which]; se.want = '';
  $('seText').value = se.cmds[which];
  $('seFind').hidden = true;
  paintScript();
  $('seText').focus(); $('seText').setSelectionRange(0, 0); $('seText').scrollLeft = 0;
}
async function leaveScript() {
  if (se.command) return (se.cmds.install === se.cmdOrig.install && se.cmds.uninstall === se.cmdOrig.uninstall) || ask('Discard your changes to the commands?', { ok: 'Discard', danger: true });
  return $('seText').value === se.original || ask(`Discard your changes to ${se.detection ? 'the detection script' : se.file}?`, { ok: 'Discard', danger: true });
}
async function closeScript() { if (await leaveScript()) $('dlgCode').close(); }
async function saveScript() {
  const text = $('seText').value;
  if ($('seSave').disabled) return;
  if (se.command) {
    if (!$('dlgApp').open || (editingName || '') !== se.forApp) { status('The app these commands belong to was closed - they can no longer be applied. Copy what you need, then close.', true); return; }
    setFields([['mInstallCommand', se.cmds.install], ['mUninstallCommand', se.cmds.uninstall]]);
    se.cmdOrig = { ...se.cmds }; se.original = text; $('dlgCode').close(); toast('Commands applied - Save the app to keep them.');
    return;
  }
  if (se.detection) {
    if (!$('dlgApp').open || (editingName || '') !== se.forApp) { status('The app this detection script belongs to was closed - it can no longer be applied. Copy what you need, then close.', true); return; }
    setFields([['xScript', text]]);
    se.original = text; $('dlgCode').close(); toast('Detection script applied - Save the app to keep it.');
    return;
  }
  $('seSave').disabled = true;
  const r = await api('/api/package-script-save', { name: se.name, file: se.file, text, hash: se.hash });
  if (!r.ok) {
    if (r.conflict) se.conflict = true;
    se.errors = r.errors || se.errors;
    status(r.error, true); paintScript();
    return;
  }
  se.hash = r.hash; se.original = text; se.want = lockedText(text);
  status(`Saved. The earlier ${se.file} is in Backups - build the package so devices get it.`);
  $('seBuild').hidden = false;
  paintScript();
}

// Before the editor saves: a block typed in but not left yet is written into the commands, and every write is waited for.
async function blocksFlush() {
  const a = document.activeElement;
  if (a && a.closest && a.closest('#dlgApp .blockbar') && 'value' in a && a.value !== a.defaultValue) a.dispatchEvent(new Event('change', { bubbles: true }));
  for (let i = 0; i < 3 && bs.pending; i++) await bs.pending.catch(() => {});
}
window.blocksFlush = blocksFlush;
window.refreshBlocks = refreshBlocks;
window.refreshDetectionBlocks = refreshDetectionBlocks;
window.openScriptEditor = openScriptEditor;
})();
