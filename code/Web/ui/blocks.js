'use strict';
// ---------------------------------------------------------------- blocks (2.26)
// The install and uninstall commands and the detection script as blocks: locked ones (what the tool writes the same
// way for every app) and editable ones (this app's values). The server reads them from the commands and writes them
// back (/api/install-blocks, /api/install-compose, ...) - the commands in the fields stay the one truth, Save saves
// them as before. "Edit as text" turns a command into the app's own (kept exactly as typed).
// And the package scripts (Install.ps1, ...) edited in a code editor with locked lines, checked as you type.

const blockState = { install: null, detection: null, installText: false, detectionText: false, seq: 0, dseq: 0 };

// One bar of blocks. onChange(values) when an editable block changes; onAction(file) for a script block.
function renderBlockBar(host, model, opts = {}) {
  const { onChange, onAction, onText, textMode } = opts;
  host.replaceChildren();
  host.hidden = !model || model.form === 'none' || model.form === 'rule';
  if (host.hidden) return;
  const head = el('div', { class: 'bhead' });
  if (model.own || textMode) {
    head.append(el('span', { class: 'bown', text: textMode && !model.own ? 'Edited as text - your own command, kept exactly as typed.' : (model.note || 'Your own command, kept exactly as typed.') }));
    host.append(head);
    return;
  }
  head.append(el('span', { class: 'bform', text: { winget: 'Winget', msi: 'MSI', exe: 'Installer (.exe)', script: 'PowerShell script', psadt: 'PSADT 4', managed: 'Managed release', installed: 'Installed app' }[model.form] || model.form }),
    el('span', { class: 'bkey' }, el('span', { class: 'k lock', text: 'fixed' }), el('span', { class: 'k edit', text: "this app's" }), el('span', { class: 'k link', text: 'set elsewhere' })),
    el('button', { type: 'button', class: 'btn small ghost', text: 'Edit as text', title: 'Write the command yourself - it is then your own, kept exactly as typed (the blocks come back when it is one of their forms again)', onclick: onText }));
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
  let part = '';
  for (const b of model.blocks) {
    if (b.part !== part) {
      if (part && b.part === 'uninstall') card.append(el('div', { class: 'bsec', text: 'Uninstall' }));
      part = b.part;
    }
    const tip = b.help || '';
    const lab = el('span', { class: 'blab' }, b.label);
    if (b.kind === 'lock') card.append(el('div', { class: 'blk lock', title: tip || 'Fixed - the tool writes this the same way for every app.' }, lab, el('span', { class: 'bval', text: b.text })));
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
        ? el('select', { 'aria-label': b.label, onchange: e => { values[b.id] = e.target.value; fire(); } }, ...b.choices.map(c => el('option', { value: c.value, text: c.label })))
        : el('input', { value: b.value ?? '', 'aria-label': b.label, spellcheck: 'false', onchange: e => { values[b.id] = e.target.value; fire(); } });
      if (b.type === 'select') input.value = b.value ?? '';
      card.append(el('label', { class: 'blk edit', title: tip }, lab, el('span', { class: 'bval' }, input)));
    }
    else if (b.kind === 'list') {
      const items = (b.value || []).map(x => ({ name: x.name, value: x.value }));
      values[b.id] = items;
      const named = b.choices && b.choices.length && typeof b.choices[0] === 'string';
      const val = el('span', { class: 'bval chips' });
      items.forEach((it, i) => {
        const v = el('input', { value: it.value, placeholder: 'value', 'aria-label': `${it.name} value`, spellcheck: 'false', size: Math.max(5, Math.min(36, String(it.value).length + 1)), onchange: e => { it.value = e.target.value; fire(); } });
        const n = named ? el('span', { class: 'bopt', text: it.name }) : el('input', { class: 'bname', value: it.name, placeholder: 'NAME', 'aria-label': 'Property name', spellcheck: 'false', size: Math.max(5, it.name.length + 1), onchange: e => { it.name = e.target.value; fire(); } });
        val.append(el('span', { class: 'bchip' }, n, el('span', { class: 'beq', text: named ? ' ' : '=' }), v, el('button', { type: 'button', class: 'bx', 'aria-label': `Remove ${it.name}`, title: 'Remove', text: '×', onclick: () => { items.splice(i, 1); fire(); } })));
      });
      const free = named ? b.choices.filter(c => !items.some(x => x.name === c)) : [''];
      if (free.length) {
        val.append(named
          ? el('select', { class: 'badd', 'aria-label': `Add to ${b.label}`, title: tip, onchange: e => { if (!e.target.value) return; items.push({ name: e.target.value, value: '' }); fire(); } },
            el('option', { value: '', text: '+ Add' }), ...free.map(c => el('option', { value: c, text: c })))
          : el('button', { type: 'button', class: 'badd', text: '+ Add', title: tip, onclick: () => { items.push({ name: '', value: '' }); fire(); } }));
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
async function refreshBlocks() {
  const seq = ++blockState.seq, r = await api('/api/install-blocks', instFields());
  if (seq !== blockState.seq || !r.ok) return;
  blockState.install = r;
  // Back to blocks once the typed command is one of their forms again.
  if (blockState.installText && !r.own) blockState.installText = false;
  setCommandsReadOnly(!r.own && !blockState.installText);
  renderBlockBar($('instBlocks'), r, {
    textMode: blockState.installText,
    onText: () => { blockState.installText = true; setCommandsReadOnly(false); renderBlockBar($('instBlocks'), { ...r, own: true, note: 'Edited as text - your own command, kept exactly as typed.' }, {}); $('mInstallCommand').focus(); },
    onChange: async values => {
      const c = await api('/api/install-compose', { ...instFields(), form: r.form, values });
      if (!c.ok) { toast(c.error, true); refreshBlocks(); return; }
      for (const [id, v] of [['mInstallCommand', c.install], ['mUninstallCommand', c.uninstall]]) { $(id).value = v; $(id).dispatchEvent(new Event('input', { bubbles: true })); }
      refreshBlocks();
    },
    onAction: file => openScriptEditor({ name: editingName, file })
  });
  // The 2.25 field for winget options is a block now.
  const wo = document.querySelector('.methodrow .wopts'); if (wo) wo.hidden = true;
  if ($('aWingetOptsInfo')) $('aWingetOptsInfo').hidden = true;
}
const blocksSoon = (() => { let t = 0; return () => { clearTimeout(t); t = setTimeout(refreshBlocks, 250); }; })();
for (const id of ['aWinget', 'mInstallCommand', 'mUninstallCommand']) $(id).addEventListener('input', blocksSoon);
$('xContext').addEventListener('change', blocksSoon);

// ---------------------------------------------------------------- detection script
async function refreshDetectionBlocks() {
  const host = $('detBlocks');
  if ($('xType').value !== 'Script') { host.hidden = true; $('xScript').readOnly = false; $('xScript').classList.remove('preview'); return; }
  const seq = ++blockState.dseq, r = await api('/api/detection-blocks', { script: $('xScript').value });
  if (seq !== blockState.dseq || !r.ok) return;
  blockState.detection = r;
  if (blockState.detectionText && !r.own) blockState.detectionText = false;
  const ro = !r.own && !blockState.detectionText;
  $('xScript').readOnly = ro; $('xScript').classList.toggle('preview', ro);
  renderBlockBar(host, r.form === 'none' ? null : r, {
    textMode: blockState.detectionText,
    onText: () => { blockState.detectionText = true; $('xScript').readOnly = false; $('xScript').classList.remove('preview'); renderBlockBar(host, { ...r, own: true, note: 'Edited as text - your own script, kept exactly as typed.' }, {}); $('xScript').focus(); },
    onChange: async values => {
      const c = await api('/api/detection-compose', { script: $('xScript').value, form: r.form, values });
      if (!c.ok) { toast(c.error, true); refreshDetectionBlocks(); return; }
      $('xScript').value = c.script; $('xScript').dispatchEvent(new Event('input', { bubbles: true }));
      // The managed release's detection reads this name again at the next release (Name on devices).
      if (r.form === 'managed' && $('arDetected')) $('arDetected').value = c.detectedName;
      refreshDetectionBlocks();
    },
    onAction: () => {}
  });
  // An own script: the code editor, with the parse check.
  if (r.own || blockState.detectionText) host.append(el('div', { class: 'brow' }, el('button', { type: 'button', class: 'btn small', text: 'Open in the code editor', onclick: () => openScriptEditor({ detection: true }) })));
}
const detSoon = (() => { let t = 0; return () => { clearTimeout(t); t = setTimeout(refreshDetectionBlocks, 250); }; })();
$('xScript').addEventListener('input', detSoon);
$('xType').addEventListener('change', detSoon);
$('dlgApp').addEventListener('close', () => { blockState.installText = false; blockState.detectionText = false; });

// ---------------------------------------------------------------- the code editor
// A textarea over a highlighted copy of its text, with line numbers. Locked lines (the version marker the
// detection rule reads) can't be changed: the editor refuses edits there, the server checks again on save.
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
  const lines = text.split(/\r?\n/), locked = new Set();
  lines.forEach((l, i) => {
    if (/^\s*AppVersion\s*=\s*'/.test(l)) { locked.add(i); return; }
    if (!/IntuneAppCatalog\\Apps\\/.test(l)) return;
    locked.add(i);
    if (i > 0 && /^\s*#.*version marker/.test(lines[i - 1])) locked.add(i - 1);
    if (i + 1 < lines.length && /^\s*Set-ItemProperty\b.*-Name\s+Version\b/.test(lines[i + 1])) locked.add(i + 1);
  });
  return locked;
}

const se = { name: '', file: '', hash: '', original: '', locked: new Set(), errors: [], detection: false, checkSeq: 0 };
function scriptDialog() {
  let d = $('dlgCode');
  if (d) return d;
  d = el('dialog', { id: 'dlgCode', class: 'wide scriptdlg', 'aria-labelledby': 'seTitle' },
    el('div', { class: 'sehead' }, el('h2', { id: 'seTitle' }), el('div', { class: 'setabs', id: 'seTabs', role: 'tablist' })),
    el('p', { class: 'sub', id: 'seSub' }),
    el('div', { class: 'sefind', id: 'seFind', hidden: true }, el('input', { type: 'search', id: 'seFindText', placeholder: 'Find (Enter: next)', 'aria-label': 'Find in the script' }), el('span', { class: 'muted', id: 'seFindCount' })),
    el('div', { class: 'code' }, el('div', { class: 'gutter', id: 'seGutter', 'aria-hidden': 'true' }), el('div', { class: 'codearea' },
      el('pre', { class: 'hl', id: 'seHl', 'aria-hidden': 'true' }),
      el('textarea', { id: 'seText', spellcheck: 'false', wrap: 'off', 'aria-label': 'Script', autocomplete: 'off', autocorrect: 'off', autocapitalize: 'off' }))),
    el('div', { class: 'sestatus', id: 'seStatus', 'aria-live': 'polite' }),
    el('ul', { class: 'seerrors', id: 'seErrors' }),
    el('div', { class: 'actions split' },
      el('div', {}, el('button', { type: 'button', class: 'btn', id: 'sePrev', text: 'Previous version', title: 'Load the copy kept in Backups at the last save (nothing is saved until you save)' }),
        el('button', { type: 'button', class: 'btn', id: 'seBuild', text: 'Build package', hidden: true, title: "Build the app's .intunewin again with the saved scripts" })),
      el('div', {}, el('button', { type: 'button', class: 'btn', id: 'seClose', text: 'Close' }), el('button', { type: 'button', class: 'btn primary', id: 'seSave', text: 'Save', title: 'Ctrl+S' }))));
  document.body.append(d);
  const ta = $('seText');
  ta.addEventListener('input', () => { paintScript(); checkSoon(); });
  ta.addEventListener('scroll', () => { $('seHl').scrollTop = ta.scrollTop; $('seHl').scrollLeft = ta.scrollLeft; $('seGutter').scrollTop = ta.scrollTop; });
  ta.addEventListener('beforeinput', e => {
    if (!se.locked.size) return;
    const text = ta.value, lineAt = p => text.slice(0, p).split('\n').length - 1;
    const a = lineAt(ta.selectionStart), b = lineAt(ta.selectionEnd);
    // Deleting backwards from a line's start joins it to the locked line above; forwards from its end, to the one below.
    const back = e.inputType === 'deleteContentBackward' && ta.selectionStart === ta.selectionEnd && ta.selectionStart > 0 && text[ta.selectionStart - 1] === '\n';
    const fwd = e.inputType === 'deleteContentForward' && ta.selectionStart === ta.selectionEnd && text[ta.selectionStart] === '\n';
    for (let l = a - (back ? 1 : 0); l <= b + (fwd ? 1 : 0); l++) {
      if (se.locked.has(l)) { e.preventDefault(); status('That line is locked - the version marker the detection rule reads. A release changes it.', true); return; }
    }
  });
  ta.addEventListener('keydown', e => {
    if (e.key === 'Tab' && !e.ctrlKey && !e.altKey) { e.preventDefault(); document.execCommand('insertText', false, '    '); }
    else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); saveScript(); }
    else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); $('seFind').hidden = false; $('seFindText').focus(); $('seFindText').select(); }
  });
  $('seFindText').addEventListener('keydown', e => {
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
    ta.value = r.text; paintScript(); checkSoon(); status(`Previous version from ${r.at} loaded - Save keeps it.`);
  });
  $('seBuild').addEventListener('click', () => {
    const name = se.name;
    runDialog('Package', `Building ${name}'s .intunewin with the saved scripts.`);
    runJob({ names: [name] }, ok => { toast(ok ? `${name}'s package is built.` : 'Packaging failed - see the log.', !ok); $('seBuild').hidden = ok; loadApps(); }, { path: '/api/package-start', log: 'runLog', startText: 'Packaging...' });
  });
  return d;
}
const lineHeight = () => parseFloat(getComputedStyle($('seText')).lineHeight) || 18;
function status(text, bad) { const s = $('seStatus'); s.textContent = text; s.classList.toggle('err', !!bad); }
function paintScript() {
  const text = $('seText').value;
  se.locked = se.detection ? new Set() : lockedLinesOf(text);
  $('seHl').innerHTML = highlightPs(text);
  const lines = text.split('\n'), bad = new Set(se.errors.map(x => x.line - 1));
  $('seGutter').replaceChildren(...lines.map((_, i) => el('div', { class: (se.locked.has(i) ? 'lk' : '') + (bad.has(i) ? ' bad' : ''), text: String(i + 1) })));
  // Locked lines tinted behind the text.
  const lh = lineHeight(), pad = 8;
  $('seHl').style.backgroundImage = se.locked.size ? [...se.locked].map(i => `linear-gradient(var(--lockbg), var(--lockbg))`).join(',') : 'none';
  $('seHl').style.backgroundSize = [...se.locked].map(() => `100% ${lh}px`).join(',');
  $('seHl').style.backgroundPosition = [...se.locked].map(i => `0 ${pad + i * lh}px`).join(',');
  $('seHl').style.backgroundRepeat = 'no-repeat';
  $('seSave').disabled = text === se.original || se.errors.length > 0;
}
const checkSoon = (() => { let t = 0; return () => { clearTimeout(t); t = setTimeout(checkScript, 450); }; })();
async function checkScript() {
  const seq = ++se.checkSeq, text = $('seText').value;
  const r = await api('/api/package-script-check', { old: se.detection ? '' : se.original, text });
  if (seq !== se.checkSeq || !r.ok) return;
  se.errors = r.errors || [];
  $('seErrors').replaceChildren(...se.errors.slice(0, 8).map(x => el('li', {}, el('button', { type: 'button', class: 'linkbtn', text: `Line ${x.line}:`, onclick: () => goLine(x.line, x.column) }), ' ' + x.message)));
  if (r.valid) status(se.detection ? 'Parses. Apply puts it into the detection rule (Save in the app editor saves it).' : (text === se.original ? 'Parses. Locked lines (grey) are the version marker the detection rule reads.' : 'Parses - not saved yet (Ctrl+S).'));
  else status(r.error, true);
  paintScript();
}
function goLine(line, col) {
  const ta = $('seText'), lines = ta.value.split('\n');
  const pos = lines.slice(0, line - 1).reduce((n, l) => n + l.length + 1, 0) + Math.max(0, (col || 1) - 1);
  ta.focus(); ta.setSelectionRange(pos, pos); ta.scrollTop = Math.max(0, (line - 1) * lineHeight() - ta.clientHeight / 2);
}

async function openScriptEditor({ name, file, detection }) {
  const d = scriptDialog();
  se.detection = !!detection; se.errors = [];
  $('seBuild').hidden = true;
  $('sePrev').hidden = se.detection;
  $('seSave').textContent = se.detection ? 'Apply' : 'Save';
  if (se.detection) {
    se.name = ''; se.file = ''; se.hash = ''; se.original = $('xScript').value;
    $('seTitle').textContent = 'Detection script';
    $('seSub').textContent = 'Runs as SYSTEM on the device. Installed: write something to the output and exit 0. Not installed: write nothing.';
    $('seTabs').replaceChildren();
  } else {
    const r = await api('/api/package-script', { name, file });
    if (!r.ok) { toast(r.error, true); return; }
    // A textarea keeps line ends as \n: compared that way, an unchanged file isn't "changed" (the server writes Windows line ends).
    Object.assign(se, { name, file, hash: r.hash, original: r.text.replace(/\r\n?/g, '\n') });
    $('seTitle').textContent = `${file} - ${name}`;
    $('seSub').textContent = `In ${r.folder}. Runs as SYSTEM from the package folder. Saving keeps the earlier one in Backups; the package needs building again.`;
    $('seTabs').replaceChildren(...r.files.map(f => el('button', { type: 'button', role: 'tab', class: 'setab', 'aria-selected': String(f === file), text: f, onclick: async () => { if (f === se.file || !(await leaveScript())) return; openScriptEditor({ name, file: f }); } })));
  }
  $('seText').value = se.original;
  paintScript(); checkScript();
  if (!d.open) d.showModal();
  $('seText').focus(); $('seText').setSelectionRange(0, 0); $('seText').scrollTop = 0;
}
async function leaveScript() {
  return $('seText').value === se.original || ask(`Discard your changes to ${se.detection ? 'the detection script' : se.file}?`, { ok: 'Discard', danger: true });
}
async function closeScript() { if (await leaveScript()) $('dlgCode').close(); }
async function saveScript() {
  const text = $('seText').value;
  if ($('seSave').disabled) return;
  if (se.detection) {
    $('xScript').value = text; $('xScript').dispatchEvent(new Event('input', { bubbles: true }));
    se.original = text; $('dlgCode').close(); toast('Detection script applied - Save the app to keep it.');
    return;
  }
  $('seSave').disabled = true;
  const r = await api('/api/package-script-save', { name: se.name, file: se.file, text, hash: se.hash });
  if (!r.ok) { status(r.error, true); se.errors = r.errors || se.errors; paintScript(); if (r.conflict) $('seSave').disabled = true; return; }
  se.hash = r.hash; se.original = text;
  status(`Saved. The earlier ${se.file} is in Backups - build the package so devices get it.`);
  $('seBuild').hidden = false;
  paintScript();
}
