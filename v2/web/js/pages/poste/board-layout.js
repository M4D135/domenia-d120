import { boardActivity } from './board-activity.js';
// Persisted layouts of real workstation/software cards. Paused and hidden cards never invoke their renderer.
import { openDialog } from '../../kit/dialog.js';
import { esc, toast } from '../../ui.js';
import { ico, errorText } from './common.js';
import { chooseBoardVersion } from '../board-history.js';
import { createBoardTransfer } from '../board-transfer.js';

const VISUALS = { Kpi: 'Chiffre ou valeur clé', Gauge: 'Jauge', Pie: 'Anneau', Bar: 'Barres', Column: 'Histogramme', Text: 'Liste', List: 'Points', HealthSummary: 'Score et points', Health: 'Score', Sheet: 'Fiche', Checklist: 'Liste d’état', Table: 'Tableau', Verdict: 'Verdict du poste' };

export function createBoardLayout(host, state, board, changed) {
  let alive = true;
  let view = null;
  let error = null;
  let serial = 0;
  const undo = []; const redo = [];
  let writing = false;
  const remember = (before, saved) => {
    if (JSON.stringify(before.items) === JSON.stringify(saved.items)) return;
    undo.push({ items: before.items, expectedToken: saved.choiceToken });
    if (undo.length > 10) undo.shift();
    redo.length = 0;
  };
  const title = board === 'Computer' ? 'Poste' : 'Logiciels';
  const transfer = createBoardTransfer((op, args) => state.call(op, args), () => alive);
  function paintActivity() {
    if (!alive || !view) return;
    for (const card of host.querySelectorAll('[data-layout-item]')) {
      const item = view.items.find(item => item.id === card.dataset.layoutItem);
      const line = card.querySelector('[data-board-progress]');
      if (!item || !line) continue;
      const text = boardActivity(item, board, state);
      line.textContent = text; line.hidden = !text;
      card.classList.toggle('is-collecting', Boolean(text));
    }
  }
  const offActivity = [state.on?.('reading', paintActivity), state.on?.('running', paintActivity)].filter(Boolean);
  const defaults = () => (view?.catalog ?? []).filter((d) => d.default !== false).map((d) => ({ id: `b-${d.key}`, source: d.source ?? 'builtin', key: d.key,
    visual: d.visual, size: d.size, title: null, paused: false, group: '' }));
  async function load() {
    try {
      const loaded = await state.call('poste.layout.get', { board });
      if (alive) { view = loaded; error = null; changed(); }
    } catch (err) { if (alive) { error = errorText(err); changed(); } }
  }
  const definition = (i) => view?.catalog.find((d) => d.key === i.key && (d.source ?? 'builtin') === i.source);
  const visuals = (i) => definition(i)?.visuals?.length ? definition(i).visuals : i.source === 'query' ? ['Verdict', 'Text'] : [definition(i)?.visual ?? i.visual];
  async function edit() {
    if (!view || writing) return;
    const shown = view;
    const expectedChoiceToken = shown.choiceToken;
    let items = view.items.map((i) => ({ ...i }));
    let draggedId = null;
    const body = document.createElement('div');
    body.className = 'ps-layout-editor';
    const paint = () => {
      body.innerHTML = `<p>Déplacez les cartes avec leur poignée ou les boutons Monter et Descendre. Retirer une carte la masque ; mettre une carte en pause suspend son affichage sans modifier les données du poste.</p>
        ${!view.valid ? `<p class="ps-faint">${esc(view.reason)}</p>` : ''}
        <ol>${items.map((i, n) => `<li data-layout-row="${n}"><div class="ps-layout-edit-title"><label>Titre <input maxlength="80" data-field="title" value="${esc(i.title ?? '')}" placeholder="${esc(view.catalog.find((d) => d.key === i.key && (d.source ?? 'builtin') === i.source)?.title ?? i.queryBinding?.name ?? '')}"></label>
          <label>Section <input maxlength="80" data-field="group" value="${esc(i.group ?? '')}" placeholder="Sans section"></label>
          <label>Présentation <select data-field="visual">${visuals(i).map((v) => `<option value="${v}"${i.visual === v ? ' selected' : ''}>${esc(VISUALS[v] ?? v)}</option>`).join('')}</select></label>
          <label>Taille <select data-field="size">${[['S', 'Compacte'], ['M', 'Moyenne'], ['L', 'Large']].map(([v, label]) => `<option value="${v}"${i.size === v ? ' selected' : ''}>${label}</option>`).join('')}</select></label>
          <label><input type="checkbox" data-field="paused"${i.paused ? ' checked' : ''}> En pause</label></div>
          <div class="ps-row-actions"><button class="btn xs ps-layout-drag" type="button" draggable="true" data-drag-handle aria-label="Déplacer la carte ${n + 1}">Déplacer</button><button class="btn xs" type="button" data-move="-1"${n === 0 ? ' disabled' : ''}>Monter</button><button class="btn xs" type="button" data-move="1"${n === items.length - 1 ? ' disabled' : ''}>Descendre</button><button class="btn xs" type="button" data-remove>Retirer</button></div></li>`).join('')}</ol>
        ${!items.length ? '<p>Tableau volontairement vide.</p>' : ''}
        <div class="ps-row-actions"><label>Ajouter une carte <select data-add-key>${view.catalog.map((d) => `<option value="${esc(d.key)}">${esc(d.title)}</option>`).join('')}</select></label>
        <button class="btn sm" type="button" data-add${items.length >= 64 ? ' disabled' : ''}>Ajouter</button><button class="btn sm" type="button" data-defaults>Disposition livrée</button></div>`;
    };
    const capture = () => {
      body.querySelectorAll('[data-layout-row]').forEach((row) => {
        const item = items[Number(row.dataset.layoutRow)];
        item.title = row.querySelector('[data-field="title"]').value.trim() || null;
        item.group = row.querySelector('[data-field="group"]').value.trim();
        item.visual = row.querySelector('[data-field="visual"]').value;
        item.size = row.querySelector('[data-field="size"]').value;
        item.paused = row.querySelector('[data-field="paused"]').checked;
      });
    };
    const clearDrag = () => {
      draggedId = null;
      body.querySelectorAll('.ps-layout-drop').forEach((row) => row.classList.remove('ps-layout-drop'));
    };
    body.addEventListener('dragstart', (e) => {
      const handle = e.target instanceof Element ? e.target.closest('[data-drag-handle]') : null;
      if (!handle || !e.dataTransfer) { e.preventDefault(); return; }
      capture();
      draggedId = items[Number(handle.closest('[data-layout-row]').dataset.layoutRow)]?.id ?? null;
      if (!draggedId) { e.preventDefault(); return; }
      e.dataTransfer.effectAllowed = 'move';
      e.dataTransfer.setData('text/plain', draggedId);
    });
    body.addEventListener('dragover', (e) => {
      const row = e.target instanceof Element ? e.target.closest('[data-layout-row]') : null;
      if (!draggedId || !row) return;
      e.preventDefault();
      if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
      body.querySelectorAll('.ps-layout-drop').forEach((old) => old.classList.remove('ps-layout-drop'));
      row.classList.add('ps-layout-drop');
    });
    body.addEventListener('drop', (e) => {
      const row = e.target instanceof Element ? e.target.closest('[data-layout-row]') : null;
      if (!draggedId || !row) return; // External files/text never become a card.
      e.preventDefault();
      capture();
      const from = items.findIndex((i) => i.id === draggedId);
      const to = Number(row.dataset.layoutRow);
      if (from >= 0 && to >= 0 && to < items.length && from !== to) items.splice(to, 0, items.splice(from, 1)[0]);
      clearDrag();
      paint();
      body.querySelector(`[data-layout-row="${to}"] [data-drag-handle]`)?.focus();
    });
    body.addEventListener('dragend', clearDrag);
    body.addEventListener('click', (e) => {
      const button = e.target instanceof Element ? e.target.closest('button') : null;
      if (!button || button.disabled || button.hasAttribute('data-drag-handle')) return;
      clearDrag();
      capture();
      const row = button.closest('[data-layout-row]');
      const n = row ? Number(row.dataset.layoutRow) : -1;
      if (button.hasAttribute('data-remove')) items.splice(n, 1);
      else if (button.dataset.move) {
        const next = n + Number(button.dataset.move);
        if (next >= 0 && next < items.length) [items[n], items[next]] = [items[next], items[n]];
      } else if (button.hasAttribute('data-add')) {
        const d = view.catalog.find((c) => c.key === body.querySelector('[data-add-key]').value);
        if (d && items.length < 64) items.push({ id: `local-${Date.now().toString(16)}-${++serial}`, source: d.source ?? 'builtin', key: d.key,
          visual: d.visual, size: d.size, title: null, paused: false, group: '' });
      } else if (button.hasAttribute('data-defaults')) items = defaults();
      paint();
    });
    paint();
    const dialog = openDialog({ title: `Disposition · ${title}`, icon: 'sliders', size: 'lg', body,
      actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'save', label: 'Enregistrer', primary: true }] });
    if (await dialog.result !== 'save' || !alive) return;
    capture();
    writing = true;
    try {
      const saved = await state.call('poste.layout.save', { board, items, expectedChoiceToken });
      if (alive) { remember(shown, saved); view = saved; error = null; changed(); toast('Disposition enregistrée.', { tone: 'ok' }); }
    } catch (err) { if (alive) { await load(); toast(errorText(err), { tone: 'warn' }); } }
    finally { writing = false; if (alive) changed(); }
  }
  async function applyPreset(preset) {
    if (!view?.valid || writing) return;
    const before = view;
    writing = true; changed();
    try {
      const saved = await state.call('poste.layout.preset', { board, preset, expectedChoiceToken: before.choiceToken });
      if (alive) { remember(before, saved); view = saved; error = null; changed(); toast('Préréglage appliqué ; les autres cartes sont conservées.', { tone: 'ok' }); }
    } catch (err) { if (alive) { await load(); toast(errorText(err), { tone: 'warn' }); } }
    finally { writing = false; if (alive) changed(); }
  }
  async function transferLayout(kind) {
    if (!view?.valid || writing) return;
    const shown = view;
    writing = true; changed();
    try {
      if (kind === 'export') {
        const result = await state.call('shell.board.export', { board, expectedChoiceToken: shown.choiceToken });
        if (alive) toast(result.summary, { tone: result.saved ? 'ok' : 'info' });
        return;
      }
      const request = await transfer.prepare(kind, board, shown.choiceToken);
      if (!request || !alive) return;
      const saved = await state.call(request.operation, request.args);
      if (alive) { remember(shown, saved); view = saved; error = null; toast('Disposition enregistrée ; version précédente conservée.', { tone: 'ok' }); }
    } catch (err) { if (alive) { await load(); toast(errorText(err), { tone: 'warn' }); } }
    finally { writing = false; if (alive) changed(); }
  }
  async function migrate() {
    try {
      const preview = await state.call('shell.interface.migration.preview');
      if (!alive) return;
      const proposal = preview.boards?.find((b) => b.board === board);
      const permitted = preview.available && proposal?.state === 'ready' && !proposal.choiceExists;
      const body = `<p>Reprenez la disposition ${esc(title)} de Domenia 1. Les fichiers historiques restent intacts.</p>
        <p>${esc(preview.reason ?? proposal?.summary ?? 'Aucune disposition locale trouvée.')}</p>
        ${proposal?.choiceExists ? '<p>Un choix Domenia 2 existe déjà, même vide. Il sera conservé.</p>' : ''}
        ${preview.sourcePath ? `<p>Source : <span class="code">${esc(preview.sourcePath)}</span></p>` : ''}
        ${proposal?.teamSource ? `<p>Configuration d’équipe : <span class="code">${esc(proposal.teamSource.path)}</span></p>` : ''}
        ${(preview.warnings ?? []).map((w) => `<p>${esc(w)}</p>`).join('')}
        ${proposal?.state === 'ready' ? `<ol>${proposal.items.map((i) => `<li>${esc(i.title || view?.catalog.find((d) => d.key === i.key && (d.source ?? 'builtin') === i.source)?.title || i.queryBinding?.name || 'Carte')}${i.queryBinding ? ` — révision ${i.queryBinding.revision} · empreinte ${esc(i.queryBinding.fingerprint)}${i.queryBinding.currentRevisionProposed ? ' · nouvelle liaison à confirmer' : ' · liaison de Domenia 1 conservée'}` : ''}${i.paused ? ' — en pause' : ''}</li>`).join('')}</ol>${proposal.items.length ? '' : '<p>Le tableau restera volontairement vide.</p>'}` : ''}`;
      const dialog = openDialog({ title: `Importer la disposition de Domenia 1 · ${title}`, icon: 'history', size: 'md', body,
        actions: [{ id: 'cancel', label: 'Fermer', safe: true }, ...(permitted ? [{ id: 'apply', label: proposal?.queryBindingsSha256 ? 'Importer et lier ces révisions' : 'Importer', primary: true }] : [])] });
      if (await dialog.result !== 'apply' || !alive) return;
      const result = await state.call('shell.interface.migrate', { board, sourceSha256: preview.sourceSha256,
        ...(proposal?.teamSource ? { configurationSha256: proposal.teamSource.sha256 } : {}),
        ...(proposal?.queryBindingsSha256 ? { queryBindingsSha256: proposal.queryBindingsSha256 } : {}) });
      if (alive) { await load(); toast(result.summary, { tone: result.applied ? 'ok' : 'info' }); }
    } catch (err) { if (alive) toast(errorText(err), { tone: 'warn' }); }
  }
  async function restoreVersion() {
    if (!view?.valid || writing) return;
    const shown = view;
    const versionId = await chooseBoardVersion(shown, title);
    if (!versionId || !alive) return;
    writing = true;
    try {
      const saved = await state.call('poste.layout.restore', { board, versionId, expectedChoiceToken: shown.choiceToken });
      if (alive) { remember(shown, saved); view = saved; error = null; changed(); toast('Disposition restaurée. Le choix précédent reste dans les versions.', { tone: 'ok' }); }
    } catch (err) { if (alive) { await load(); toast(errorText(err), { tone: 'warn' }); } }
    finally { writing = false; if (alive) changed(); }
  }
  async function historyStep(backwards) {
    if (!view?.valid || writing) return;
    const from = backwards ? undo : redo; const to = backwards ? redo : undo;
    const step = from.at(-1); if (!step) return;
    if (step.expectedToken !== view.choiceToken) { toast('Une autre disposition a été appliquée ; ancienne annulation refusée.', { tone: 'warn' }); return; }
    const before = view;
    writing = true;
    try {
      const saved = await state.call('poste.layout.save', { board, items: step.items, expectedChoiceToken: step.expectedToken });
      if (!alive) return;
      from.pop(); to.push({ items: before.items, expectedToken: saved.choiceToken });
      if (to.length > 10) to.shift();
      if (from.length) from.at(-1).expectedToken = saved.choiceToken;
      view = saved; error = null;
      toast(backwards ? 'Disposition précédente rétablie.' : 'Modification rétablie.', { tone: 'ok' });
    } catch (err) { if (alive) { await load(); toast(errorText(err), { tone: 'warn' }); } }
    finally { writing = false; if (alive) changed(); }
  }
  const clicked = (e) => {
    const button = e.target instanceof Element ? e.target.closest('[data-layout-edit],[data-layout-import],[data-layout-retry],[data-layout-history],[data-layout-undo],[data-layout-redo],[data-layout-preset],[data-layout-transfer]') : null;
    if (!button || !host.contains(button) || button.disabled || writing) return;
    if (button.hasAttribute('data-layout-edit')) edit();
    else if (button.hasAttribute('data-layout-import')) migrate();
    else if (button.dataset.layoutTransfer) transferLayout(button.dataset.layoutTransfer);
    else if (button.dataset.layoutPreset) applyPreset(button.dataset.layoutPreset);
    else if (button.hasAttribute('data-layout-history')) restoreVersion();
    else if (button.hasAttribute('data-layout-undo')) historyStep(true);
    else if (button.hasAttribute('data-layout-redo')) historyStep(false);
    else load();
  };
  const keydown = (event) => {
    if (!(event.ctrlKey || event.metaKey) || event.altKey || !(event.target instanceof Element) || event.target.closest('input,textarea,[contenteditable="true"]')) return;
    if (event.key.toLowerCase() === 'z') { event.preventDefault(); historyStep(!event.shiftKey); }
    else if (event.key.toLowerCase() === 'y') { event.preventDefault(); historyStep(false); }
  };
  host.addEventListener('click', clicked); host.addEventListener('keydown', keydown);
  return {
    load,
    toolbar: () => `<div class="ps-layout-tools"><span>Tableau ${esc(title)}</span><button class="btn sm" type="button" data-layout-edit${view && !writing ? '' : ' disabled'}>${ico('sliders')}Personnaliser</button>
      <button class="btn sm" type="button" data-layout-undo${undo.length && !writing ? '' : ' disabled'}>Annuler</button>
      <button class="btn sm" type="button" data-layout-redo${redo.length && !writing ? '' : ' disabled'}>Rétablir</button>
      <button class="btn sm" type="button" data-layout-history${view?.valid && view.history?.length && !writing ? '' : ' disabled'}>${ico('history')}Versions précédentes</button>
      ${[['support', 'Assistance'], ['inventory', 'Inventaire'], ...(board === 'Computer' ? [['health', 'Santé']] : [])].map(([id, label]) => `<button class="btn sm" type="button" data-layout-preset="${id}"${writing || !view?.valid ? ' disabled' : ''}>${esc(label)}</button>`).join('')}
      ${[['default', 'Par défaut'], ['import', 'Importer un fichier'], ['export', 'Exporter']].map(([id, label]) => `<button class="btn sm" type="button" data-layout-transfer="${id}"${writing || !view?.valid ? ' disabled' : ''}>${esc(label)}</button>`).join('')}
      <button class="btn sm" type="button" data-layout-import>${ico('history')}Importer depuis Domenia 1</button></div>`,
    render: (renderer) => {
      if (error) return `<p class="span-12" role="alert">${esc(error)} <button class="btn sm" type="button" data-layout-retry>Relire la disposition</button></p>`;
      if (!view) return '<p class="span-12" role="status">Lecture de la disposition locale…</p>';
      if (!view.valid) return `<p class="span-12" role="alert">${esc(view.reason)}</p>`;
      if (!view.items.length) return '<p class="span-12 ps-layout-empty">Tableau volontairement vide. « Personnaliser » permet d’ajouter des cartes.</p>';
      let previousGroup = null;
      return view.items.map((i) => {
        const definition = view.catalog.find((d) => d.key === i.key && (d.source ?? 'builtin') === i.source);
        const label = i.title || definition?.title || i.queryBinding?.name || 'Carte';
        const body = i.paused ? `<section class="card ps-card ps-layout-paused"><h3>${esc(label)}</h3><p>En pause · aucun affichage des nouvelles valeurs.</p></section>` : renderer(i, label);
        const progress = boardActivity(i, board, state);
        const heading = i.group && i.group !== previousGroup ? `<h3 class="span-12 ps-layout-group">${esc(i.group)}</h3>` : '';
        previousGroup = i.group;
        return `${heading}<div data-layout-visual="${esc(i.visual)}" class="ps-layout-widget span-${i.size === 'S' ? 4 : i.size === 'L' ? 12 : 6}" data-layout-item="${esc(i.id)}" data-layout-key="${esc(i.key)}">${body}<p class="ps-faint" data-board-progress role="status"${progress ? '' : ' hidden'}>${esc(progress)}</p></div>`;
      }).join('');
    },
    get stored() { return Boolean(view?.stored); },
    get ready() { return Boolean(view?.valid && !error); },
    destroy() { alive = false; offActivity.forEach(off => off()); transfer.destroy(); host.removeEventListener('click', clicked); host.removeEventListener('keydown', keydown); },
  };
}
