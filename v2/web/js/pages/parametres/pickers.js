// Paramètres › Données et cache: choosers of the local base, in the page (never a window of Windows). The destination of a
// copy or a move (Domenia 1 « Enregistrer sous »): proposed name « Domenia-AAAAMMJJ-HHmm.db », proposed folders, a browser
// of the local folders and a live check of the volume (read only). The backup to restore: a verified copy of the registry, a
// copy published earlier, or another .db file of a local disk (the Backups folder of the base proposed). The engine checks
// everything again in the plan; nothing here writes.
import { esc, glyph, pill, when, size, reported, NBSP, COLON } from './common.js';
import { openDialog } from '../../kit/dialog.js';
import { debounce } from '../../kit/util.js';

function folderOf(path) {
  const at = String(path ?? '').lastIndexOf('\\');
  return at > 1 ? path.slice(0, at) : '';
}

function nameOf(path) {
  const at = String(path ?? '').lastIndexOf('\\');
  return at >= 0 ? path.slice(at + 1) : String(path ?? '');
}

function join(folder, name) {
  const f = String(folder ?? '').trim().replace(/\\+$/, '');
  return f ? `${f}\\${String(name ?? '').trim()}` : String(name ?? '').trim();
}

/** Inline browser of the local folders (drives first), filled by settings.folders.browse. */
function browserMarkup() {
  return `<div class="pr-browse" data-browse hidden>
    <div class="pr-browse-head"><button type="button" class="btn sm ghost" data-browse-up>${glyph('arrowUp')}<span>Dossier parent</span></button><span class="mono pr-browse-path" data-browse-path>Disques locaux</span>
      <button type="button" class="btn sm primary" data-browse-pick>${glyph('check')}<span>Choisir ce dossier</span></button></div>
    <ul class="pr-browse-list" data-browse-list role="listbox" aria-label="Dossiers"></ul>
    <p class="pr-sub" data-browse-note></p>
  </div>`;
}

function bindBrowser(root, call, onPick) {
  const box = root.querySelector('[data-browse]');
  const list = root.querySelector('[data-browse-list]');
  const pathEl = root.querySelector('[data-browse-path]');
  const note = root.querySelector('[data-browse-note]');
  let current = null;
  let parent = null;
  async function open(path) {
    list.setAttribute('aria-busy', 'true');
    try {
      const r = await call('settings.folders.browse', path ? { path } : {});
      current = r.path ?? null;
      parent = r.parent ?? null;
      pathEl.textContent = current ?? 'Disques locaux';
      list.innerHTML = r.folders.map((f, n) => `<li role="option" tabindex="${n === 0 ? 0 : -1}" data-folder="${esc(f.path)}">${glyph(current ? 'folder' : 'disk')}<span>${esc(f.name)}</span></li>`).join('')
        || `<li class="pr-browse-none">${esc(r.text)}</li>`;
      note.textContent = r.text;
      root.querySelector('[data-browse-up]').disabled = !current;
      root.querySelector('[data-browse-pick]').disabled = !current;
    } catch (err) {
      note.textContent = reported(err);
    } finally {
      list.removeAttribute('aria-busy');
    }
  }
  root.querySelector('[data-browse-up]').addEventListener('click', () => open(parent));
  root.querySelector('[data-browse-pick]').addEventListener('click', () => { if (current) { onPick(current); box.hidden = true; } });
  list.addEventListener('click', (e) => {
    const li = e.target instanceof Element ? e.target.closest('[data-folder]') : null;
    if (li) open(li.dataset.folder);
  });
  list.addEventListener('keydown', (e) => {
    const items = [...list.querySelectorAll('[data-folder]')];
    const at = items.indexOf(document.activeElement);
    if (e.key === 'Enter' && at >= 0) { e.preventDefault(); open(items[at].dataset.folder); }
    else if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && items.length) {
      e.preventDefault();
      const next = items[Math.max(0, Math.min(items.length - 1, at + (e.key === 'ArrowDown' ? 1 : -1)))];
      items.forEach((li) => li.setAttribute('tabindex', li === next ? '0' : '-1'));
      next.focus();
    } else if (e.key === 'Backspace' && parent !== undefined) { e.preventDefault(); open(parent); }
  });
  return {
    toggle(start) {
      box.hidden = !box.hidden;
      if (!box.hidden) open(start && /^[A-Za-z]:\\/.test(start) ? start : null);
    },
  };
}

/**
 * Destination of a copy (« copy ») or of a move (« move ») of the base. Resolves the full path, or null when cancelled.
 * @param {{ call: Function }} sctx
 * @param {{ purpose: 'copy'|'move', title: string, action: string, hint: string, fallbackName?: string }} o
 */
export async function chooseDestination(sctx, o) {
  let proposal = null;
  try { proposal = await sctx.call('settings.storage.destinations'); } catch (err) { if (err?.code !== 'preview.engineRequired') console.error(err); }
  const name = o.purpose === 'move' ? 'Domenia.db' : proposal?.fileName ?? o.fallbackName ?? 'Domenia.db';
  const firstFolder = proposal?.folders?.[0]?.path ?? '';
  const chips = (proposal?.folders ?? []).map((f) => `<button type="button" class="chip pr-chip-btn" data-folder-chip="${esc(f.path)}" data-tip="${esc(f.path)}">${glyph('folder')}${esc(f.label)}</button>`).join('');
  const body = `<p class="k-dlg-text">${esc(o.hint)}</p>
    <div class="pr-dest-grid">
      <label class="pr-dest"><span>Dossier</span><span class="pr-dest-row"><input class="input mono" type="text" data-dest-folder maxlength="240" value="${esc(firstFolder)}" placeholder="D:\\Domenia" autocomplete="off" spellcheck="false">
        <button type="button" class="btn sm" data-browse-toggle>${glyph('folder')}<span>Parcourir…</span></button></span></label>
      ${chips ? `<div class="pr-dest-chips" aria-label="Dossiers proposés">${chips}</div>` : ''}
      ${browserMarkup()}
      <label class="pr-dest"><span>Nom du fichier</span><input class="input mono" type="text" data-dest-name maxlength="120" value="${esc(name)}" autocomplete="off" spellcheck="false"></label>
      <p class="pr-dest-check" data-dest-check aria-live="polite"></p>
      <p class="pr-sub">Disque local fixe seulement, fichier .db ; partages, lecteurs amovibles, liens et chemins de périphérique refusés. ${o.purpose === 'move' ? 'Un déplacement va toujours vers un nouveau fichier.' : 'Un fichier existant est remplacé par la copie vérifiée.'}</p>
    </div>`;
  const d = openDialog({ title: o.title, icon: o.purpose === 'move' ? 'external' : 'download', size: 'lg', body, actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'ok', label: o.action, primary: true }] });
  const folder = d.body.querySelector('[data-dest-folder]');
  const file = d.body.querySelector('[data-dest-name]');
  const out = d.body.querySelector('[data-dest-check]');
  let last = null;
  const path = () => join(folder.value, file.value);
  const check = debounce(async () => {
    const target = path();
    if (!proposal) { d.setDisabled('ok', !/^[A-Za-z]:\\.+\.db$/i.test(target)); return; }
    try {
      const r = await sctx.call('settings.storage.destination.check', { destination: target, purpose: o.purpose });
      if (target !== path()) return;
      last = r;
      out.dataset.tone = r.ok ? 'ok' : 'warn';
      out.innerHTML = `${glyph(r.ok ? 'check' : 'alert')}<span>${esc(r.ok ? r.text : r.problem)}</span>`;
      d.setDisabled('ok', !r.ok);
    } catch (err) {
      out.dataset.tone = 'warn';
      out.innerHTML = `${glyph('alert')}<span>${esc(reported(err))}</span>`;
      d.setDisabled('ok', true);
    }
  }, 220);
  const browser = bindBrowser(d.body, sctx.call, (picked) => { folder.value = picked; check(); file.focus(); });
  d.body.querySelector('[data-browse-toggle]').addEventListener('click', () => browser.toggle(folder.value.trim()));
  d.body.addEventListener('click', (e) => {
    const chip = e.target instanceof Element ? e.target.closest('[data-folder-chip]') : null;
    if (chip) { folder.value = chip.dataset.folderChip; check(); }
  });
  folder.addEventListener('input', check);
  file.addEventListener('input', check);
  file.addEventListener('keydown', (e) => { if (e.key === 'Enter' && (last?.ok || !proposal)) { e.preventDefault(); d.close('ok'); } });
  d.setDisabled('ok', true);
  check();
  const answer = await d.result;
  return answer === 'ok' ? path() : null;
}

/**
 * The backup to restore: a verified copy of the registry, a copy published to a file, or another .db file. Resolves
 * { backupId } or { file }, or null when cancelled.
 */
export async function chooseRestore(sctx, view) {
  const verified = view.backups.filter((b) => b.verified);
  const exports = view.exports ?? [];
  const item = (value, title, sub, extra = '', checked = false) => `<label class="pr-choose-item"><input type="radio" class="k-radio" name="pr-restore" value="${esc(value)}"${checked ? ' checked' : ''}>
      <span><b class="mono">${esc(title)}</b><span>${sub}</span>${extra}</span></label>`;
  const backups = verified.map((b, n) => item(`id:${b.id}`, b.fileName,
    `${esc(b.kindLabel)} · ${esc(when(b.at))} · ${esc(b.bytesText)} · lot ${esc(String(b.revision))}${b.lastMeasureAt ? ` · dernière mesure ${esc(when(b.lastMeasureAt))}` : ''}`,
    `<span class="pr-choose-pills">${b.preferencesBound ? pill('ok', `${b.preferenceKeys} clé${b.preferenceKeys > 1 ? 's' : ''} jointe${b.preferenceKeys > 1 ? 's' : ''}`, { size: 'sm', icon: 'sliders' }) : pill('off', 'Sans annexe de préférences', { size: 'sm' })}<span class="pr-sub">${esc(b.content)}</span></span>`,
    n === 0)).join('');
  const published = exports.map((x) => item(`file:${x.destination}`, x.destination, `Copie publiée le ${esc(when(x.at))} · ${esc(size(x.bytes))} · SHA-256 ${esc(x.sha256.slice(0, 12))}…`)).join('');
  const body = `<p class="k-dlg-text">Choisissez la sauvegarde à restaurer. Elle est copiée dans un nouveau fichier, contrôlée, puis la session bascule ; elle-même et la base active ne sont jamais écrasées.</p>
    <div class="pr-choose" role="radiogroup" aria-label="Sauvegardes vérifiées">
      ${backups ? `<h4 class="pr-h4">Sauvegardes vérifiées de cette base</h4>${backups}` : ''}
      ${published ? `<h4 class="pr-h4">Copies publiées vers un fichier</h4>${published}` : ''}
      <h4 class="pr-h4">Autre fichier .db</h4>
      <label class="pr-choose-item"><input type="radio" class="k-radio" name="pr-restore" value="other"${!backups ? ' checked' : ''}>
        <span><b>Un fichier sur un disque local</b><span>${view.backupFolder ? `Dossier des sauvegardes proposé${COLON}<span class="mono">${esc(view.backupFolder)}</span>` : 'Chemin complet du fichier .db.'}</span>
        <span class="pr-dest-row"><input class="input mono" type="text" data-restore-file maxlength="260" value="${esc(view.backupFolder ? `${view.backupFolder}\\` : '')}" placeholder="D:\\Domenia\\Domenia-20261021-1430.db" autocomplete="off" spellcheck="false">
          <button type="button" class="btn sm" data-browse-toggle>${glyph('folder')}<span>Parcourir…</span></button></span>
        ${browserMarkup()}</span></label>
    </div>`;
  const d = openDialog({ title: 'Restaurer une sauvegarde', icon: 'undo', size: 'lg', body, actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'ok', label: 'Préparer la restauration', primary: true }] });
  const fileInput = d.body.querySelector('[data-restore-file]');
  const browser = bindBrowser(d.body, sctx.call, (picked) => { fileInput.value = join(picked, nameOf(fileInput.value) || ''); d.body.querySelector('input[value="other"]').checked = true; fileInput.focus(); });
  d.body.querySelector('[data-browse-toggle]').addEventListener('click', () => browser.toggle(folderOf(fileInput.value)));
  fileInput.addEventListener('focus', () => { d.body.querySelector('input[value="other"]').checked = true; });
  const answer = await d.result;
  if (answer !== 'ok') return null;
  const choice = d.body.querySelector('input[name="pr-restore"]:checked')?.value ?? '';
  if (choice.startsWith('id:')) return { backupId: choice.slice(3) };
  if (choice.startsWith('file:')) return { file: choice.slice(5) };
  const typed = fileInput.value.trim();
  if (!typed || typed.endsWith('\\')) {
    sctx.toast(`Indiquez le fichier .db à restaurer${NBSP}: chemin complet sur un disque local.`, { tone: 'warn' });
    return null;
  }
  return { file: typed };
}
