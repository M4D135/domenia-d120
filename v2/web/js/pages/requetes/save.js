// « 3. Enregistrer »: name, category and description; local library with revisions (save, copy, archive, history and
// restore of a revision) after an impact review of the linked widgets and of the selection of Recherche; widgets of the
// dashboards with a visual preview; test of the draft on a single object; read-only scripts. Library writes are local
// preferences (LocalWrite) with a re-read receipt; nothing is ever written to the directory.
import {
  esc, glyph, key, plural, verdictPill, emptyState, skLines, vars, dateText, ago, VERDICTS, nounOf,
} from './shared.js';
import { openExport } from './drawers.js';
import { openDialog, confirmDialog, debounce } from '../../kit/index.js';
import { reveal, announce } from '../../ui.js';

const VISUALS = [
  { id: 'kpi', label: 'Chiffre clé', tip: 'Un nombre et sa part de la population.' },
  { id: 'text', label: 'Phrase', tip: 'Une phrase lisible : « 12 postes sur 140 ».' },
  { id: 'bar', label: 'Barres', tip: 'Répartition en barres horizontales (10 valeurs).' },
  { id: 'column', label: 'Colonnes', tip: 'Répartition en colonnes.' },
  { id: 'pie', label: 'Anneau', tip: 'Correspondants, inconnus et non correspondants.' },
];

const BOARDS = [
  { id: 'fleet', label: 'Tableau de bord du parc', icon: 'monitor' },
  { id: 'computer', label: 'Fiche d’un poste', icon: 'object' },
];

function visualArt(id) {
  // Pure CSS art: the shapes are spans animated in transform and opacity.
  const n = { kpi: 0, text: 0, bar: 5, column: 6, pie: 0 }[id];
  if (id === 'kpi') return '<span class="rq-vis-art kpi"><b>128</b><i></i></span>';
  if (id === 'text') return '<span class="rq-vis-art text"><i></i><i></i><i></i></span>';
  if (id === 'pie') return '<span class="rq-vis-art pie"><span></span></span>';
  return `<span class="rq-vis-art ${id}">${Array.from({ length: n }, (_, k) => `<i data-i="${k}"></i>`).join('')}</span>`;
}

const TEST_HINT = `<div class="rq-t-hint">${glyph('search')}<p><b>Choisissez un objet de la base locale</b>Deux lettres du nom suffisent : 20 objets au plus sont proposés, puis le verdict et son explication s’affichent ici, condition par condition.</p></div>`;

export function mountSave(panel, store, api) {
  const st = { categories: [], widgets: [], testToken: 0, findToken: 0, busy: false, visual: 'kpi', board: 'fleet', titleTouched: false };
  panel.innerHTML = `<div class="grid rq-save">
    <div class="rq-col span-7">
      <section class="card rq-identity spot reveal" aria-labelledby="rq-id-title">
        <div class="card-head"><span class="card-icon">${glyph('star')}</span><div class="rq-head-titles"><h3 id="rq-id-title">Requête enregistrée</h3>
          <p class="rq-sub">Bibliothèque locale de ce domaine : révisions conservées, rien n’est écrit dans l’annuaire.</p></div><span class="meta rq-rev-state"></span></div>
        <div class="rq-form">
          <label class="rq-lbl">Nom<input type="text" class="input rq-save-name" maxlength="120" autocomplete="off" spellcheck="true"></label>
          <label class="rq-lbl">Catégorie<input type="text" class="input rq-save-cat" maxlength="80" list="rq-cat-list" autocomplete="off" placeholder="Mes requêtes"><datalist id="rq-cat-list"></datalist></label>
          <label class="rq-lbl wide">Description<textarea class="input rq-save-desc" rows="3" maxlength="500" placeholder="À quoi sert la requête, qui la lit, quand la relancer…"></textarea></label>
        </div>
        <div class="rq-save-check" aria-live="polite"></div>
        <div class="rq-save-actions">
          <button type="button" class="btn primary rq-save-go">${glyph('star')}<span>Enregistrer</span></button>
          <button type="button" class="btn subtle rq-save-copy">${glyph('copy')}Enregistrer une copie</button>
          <button type="button" class="btn ghost rq-save-history">${glyph('history')}Révisions…</button>
          <span class="rq-spacer"></span>
          <button type="button" class="btn ghost rq-save-archive">${glyph('trash')}Archiver…</button>
        </div>
        <div class="rq-receipt" hidden role="status"></div>
      </section>

      <section class="card rq-widgets spot reveal" aria-labelledby="rq-w-title">
        <div class="card-head"><span class="card-icon">${glyph('gauge')}</span><div class="rq-head-titles"><h3 id="rq-w-title">Widget de tableau de bord</h3>
          <p class="rq-sub">Le widget évalue la révision enregistrée sur les données locales ; une nouvelle révision demande votre accord.</p></div></div>
        <div class="rq-w-form">
          <label class="rq-lbl">Titre du widget<input type="text" class="input rq-w-title" maxlength="80" autocomplete="off"></label>
          <div class="rq-lbl"><span>Tableau</span><div class="segmented rq-boards" role="radiogroup" aria-label="Tableau de bord">${BOARDS.map((b) => `<button type="button" role="radio" data-board="${b.id}" aria-checked="${b.id === 'fleet'}">${glyph(b.icon)}${esc(b.label)}</button>`).join('')}</div></div>
        </div>
        <div class="rq-visuals" role="radiogroup" aria-label="Visuel du widget">${VISUALS.map((v, n) => `<button type="button" class="rq-vis" role="radio" data-visual="${v.id}" aria-checked="${v.id === 'kpi'}" data-i="${n}" data-tip="${esc(v.tip)}">
          ${visualArt(v.id)}<span class="rq-vis-label">${esc(v.label)}</span></button>`).join('')}</div>
        <div class="rq-save-actions"><button type="button" class="btn primary rq-w-add">${glyph('plus')}Enregistrer et ajouter le widget</button><span class="rq-w-hint rq-note"></span></div>
        <div class="rq-w-list"></div>
      </section>
    </div>

    <div class="rq-col span-5">
      <section class="card rq-test spot reveal" aria-labelledby="rq-t-title">
        <div class="card-head"><span class="card-icon">${glyph('object')}</span><div class="rq-head-titles"><h3 id="rq-t-title">Tester sur un objet</h3>
          <p class="rq-sub">Évalue le brouillon sur un seul objet de la base locale, sans lecture réseau.</p></div></div>
        <label class="rq-search">${glyph('search')}<input type="search" class="input rq-t-find" maxlength="100" placeholder="Nom de l’objet…" aria-label="Chercher un objet à tester" autocomplete="off"></label>
        <ul class="rq-t-found" role="listbox" aria-label="Objets trouvés"></ul>
        <div class="rq-t-result" aria-live="polite">${TEST_HINT}</div>
      </section>

      <section class="card rq-scripts spot reveal" aria-labelledby="rq-s-title">
        <div class="card-head"><span class="card-icon">${glyph('file')}</span><div class="rq-head-titles"><h3 id="rq-s-title">Exporter la définition</h3>
          <p class="rq-sub">Scripts en lecture seule : aucun ne modifie l’annuaire.</p></div></div>
        <div class="rq-script-grid">
          <button type="button" class="rq-script" data-format="powershell">${glyph('command')}<b>Script PowerShell</b><span>Commenté, Get-AD* -LDAPFilter, partie annuaire seulement</span></button>
          <button type="button" class="rq-script" data-format="json">${glyph('file')}<b>Recette JSON</b><span>Format Domenia, relisible par l’import</span></button>
          <button type="button" class="rq-script" data-format="ldap">${glyph('hash')}<b>Filtre LDAP</b><span>Texte RFC 4515 indenté</span></button>
          <button type="button" class="rq-script" data-format="command">${glyph('copy')}<b>Commande</b><span>Une ligne à coller dans une console</span></button>
        </div>
      </section>
    </div>
  </div>`;
  const $ = (sel) => panel.querySelector(sel);

  // ---------- Identity and revision ----------

  function savedState() {
    const s = store.saved;
    const host = $('.rq-rev-state');
    if (!s) {
      host.innerHTML = '<span class="k-pill off sm"><span class="k-pill-dot"></span>Brouillon non enregistré</span>';
    } else if (s.source === 'template') {
      host.innerHTML = `<span class="k-pill info sm">${glyph('sparkles')}Modèle livré · copie à l’enregistrement</span>`;
    } else if (s.archived) {
      host.innerHTML = `<span class="k-pill warn sm">${glyph('history')}Archivée · révision ${s.revision}</span>`;
    } else {
      const changed = store.validation?.fingerprint && s.fingerprint && store.validation.fingerprint !== s.fingerprint;
      host.innerHTML = changed
        ? `<span class="k-pill warn sm"><span class="k-pill-dot"></span>Modifiée depuis la révision ${s.revision}</span>`
        : `<span class="k-pill ok sm"><span class="k-pill-dot"></span>Révision ${s.revision} enregistrée</span>`;
    }
    const personal = s && s.source === 'personal';
    $('.rq-save-history').disabled = !personal;
    $('.rq-save-archive').disabled = !personal || s.archived;
    $('.rq-save-go span').textContent = personal && !s.archived ? 'Enregistrer une nouvelle révision' : 'Enregistrer';
  }

  function fillForm() {
    const r = store.recipe;
    if (document.activeElement !== $('.rq-save-name')) $('.rq-save-name').value = r.name ?? '';
    if (document.activeElement !== $('.rq-save-cat')) $('.rq-save-cat').value = store.saved?.category ?? $('.rq-save-cat').value ?? '';
    if (document.activeElement !== $('.rq-save-desc') && store.saved?.description !== undefined) $('.rq-save-desc').value = store.saved.description ?? '';
    // The widget title follows the name of the query until the operator types one of their own.
    if (!st.titleTouched && document.activeElement !== $('.rq-w-title')) $('.rq-w-title').value = r.name ?? '';
    const v = store.validation;
    $('.rq-save-check').innerHTML = !v ? '' : v.valid
      ? `<p class="rq-ok-line">${glyph('check')}${esc(plural(v.conditionCount, 'condition', 'conditions'))} · format ${esc(v.format)} · ${esc(v.fingerprint?.slice(0, 12) ?? '')}</p>`
      : `<p class="rq-err-line">${glyph('alert')}${esc(v.errors?.[0] ?? 'La requête n’est pas valide.')}</p>`;
    $('.rq-save-go').disabled = !v?.valid;
    $('.rq-save-copy').disabled = !v?.valid;
    $('.rq-w-add').disabled = !v?.valid;
    const computer = key(r.target) === 'computer';
    $('.rq-boards [data-board="computer"]').disabled = !computer;
    if (!computer && st.board === 'computer') setBoard('fleet');
    $('.rq-w-hint').textContent = st.board === 'computer' ? 'Sur la fiche d’un poste, le widget dit si ce poste correspond.' : 'Le widget compte les objets du périmètre de l’Accueil.';
    savedState();
  }

  const syncName = debounce(() => {
    const name = $('.rq-save-name').value.trim();
    if (!name || name === store.recipe.name) return;
    store.setRecipe({ ...store.recipe, name }, { origin: 'name' });
  }, 350);
  $('.rq-save-name').addEventListener('input', syncName);
  $('.rq-w-title').addEventListener('input', () => { st.titleTouched = true; });

  async function loadCategories() {
    const res = await store.call('requetes.library.list', { target: key(store.recipe.target), limit: 1 });
    if (!store.alive || res.error) return;
    st.categories = res.data.categories;
    $('#rq-cat-list').innerHTML = st.categories.map((c) => `<option value="${esc(c)}"></option>`).join('');
    if (!res.data.persistent) {
      $('.rq-save-check').insertAdjacentHTML('beforeend', `<p class="rq-warn-line">${glyph('info')}Préférences non persistantes dans cette session : la bibliothèque sera perdue à la fermeture.</p>`);
    }
  }

  function payload(mode) {
    const s = store.saved;
    return {
      recipe: { ...store.recipe, name: $('.rq-save-name').value.trim() || store.recipe.name },
      category: $('.rq-save-cat').value.trim() || null,
      description: $('.rq-save-desc').value.trim() || null,
      expectedRevision: mode === 'copy' || !s || s.source !== 'personal' ? 0 : s.revision,
      mode,
    };
  }

  function showReceipt(data, verb, action = null) {
    const box = $('.rq-receipt');
    const r = data.receipt;
    box.hidden = false;
    box.className = `rq-receipt ${r.readBack ? 'ok' : 'warn'}`;
    box.innerHTML = `<span class="rq-receipt-mark">${glyph(r.readBack ? 'check' : 'alert')}</span><div class="rq-receipt-text"><b>${esc(verb)} : « ${esc(data.name)} », révision ${esc(String(data.revision))}</b>
      <span>${esc(r.text)}</span><small class="rq-mono">${esc(r.fingerprint?.slice(0, 16) ?? '')} · ${esc(dateText(r.savedAt))}${r.persisted ? '' : ' · non persistant'}</small></div>
      ${action ? `<button type="button" class="btn xs subtle rq-receipt-act">${glyph(action.icon)}${esc(action.label)}</button>` : ''}`;
    if (action) box.querySelector('.rq-receipt-act').addEventListener('click', action.run, { once: true });
    box.classList.remove('pop');
    void box.offsetWidth;
    box.classList.add('pop');
    announce(`${verb} : révision ${data.revision}.`);
  }

  function adopt(data, extra = {}) {
    store.saved = { id: data.id, revision: data.revision, fingerprint: data.fingerprint ?? data.receipt?.fingerprint, source: 'personal', archived: false, category: data.category ?? $('.rq-save-cat').value.trim(), description: $('.rq-save-desc').value.trim(), name: data.name, ...extra };
    if (data.recipe) store.setRecipe(data.recipe, { origin: 'saved', quiet: false });
    store.emit('saved', store.saved);
  }

  async function impactReview(id, draft) {
    const res = await store.call('requetes.library.impact', { id, ...(draft ? { recipe: draft } : {}) });
    if (res.error) { store.toast(res.message, 'warn'); return null; }
    return res.data;
  }

  function impactBody(impact, intro) {
    const rows = impact.rows.map((r) => `<tr><td>${esc(r.kind)}</td><th scope="row">${esc(r.name)}</th><td>${esc(r.element)}</td><td>${esc(r.link)}</td></tr>`).join('');
    const changes = impact.changes.map((c) => `<li><b>${esc(c.element)}</b><span class="rq-before">${esc(c.before || '—')}</span>${glyph('chevronRight')}<span class="rq-after">${esc(c.after || '—')}</span></li>`).join('');
    return `<div class="rq-impact"><p>${esc(intro)}</p>
      ${changes ? `<h4>Différences avec la révision ${esc(String(impact.currentRevision))}</h4><ul class="rq-diff">${changes}</ul>` : ''}
      ${rows ? `<h4>Éléments qui utilisent cette requête</h4><div class="rq-table-wrap"><table class="table rq-table"><thead><tr><th>Type</th><th>Nom</th><th>Élément</th><th>Lien</th></tr></thead><tbody>${rows}</tbody></table></div>` : ''}</div>`;
  }

  async function save(mode = 'update') {
    if (st.busy) return;
    const body = payload(mode);
    const s = store.saved;
    let chosen = mode;
    if (mode === 'update' && s?.source === 'personal' && !s.archived) {
      const impact = await impactReview(s.id, body.recipe);
      if (!impact) return;
      if (impact.hasConsumers && impact.changed) {
        const dlg = openDialog({
          title: 'Revue d’impact',
          subtitle: `« ${body.recipe.name} » · ${plural(impact.widgets, 'widget lié', 'widgets liés')}${impact.views ? ` · ${plural(impact.views, 'vue', 'vues')}` : ''}`,
          icon: 'alert',
          size: 'lg',
          body: impactBody(impact, 'Des éléments évaluent la révision actuelle. Choisissez comment les traiter : rien n’est modifié avant votre choix.'),
          actions: [
            { id: 'cancel', label: 'Annuler', safe: true },
            { id: 'copy', label: 'Enregistrer une copie', icon: 'copy' },
            { id: 'migrate', label: 'Nouvelle révision et mise à jour des widgets', icon: 'refresh', primary: true },
          ],
        });
        const answer = await dlg.result;
        if (!answer || answer === 'cancel') return;
        chosen = answer;
        body.mode = answer;
        if (answer === 'copy') body.expectedRevision = 0;
      }
    }
    st.busy = true;
    $('.rq-save-go').classList.add('busy');
    const res = await store.call('requetes.library.save', body);
    st.busy = false;
    $('.rq-save-go').classList.remove('busy');
    if (!store.alive) return;
    if (res.error) {
      if (res.error.code === 'query.revisionChanged') {
        store.toast(res.message, 'warn');
        const fresh = await store.call('requetes.library.get', { id: s.id });
        if (!fresh.error) store.saved = { ...store.saved, revision: fresh.data.revision };
        savedState();
      } else store.toast(res.message, 'warn');
      return;
    }
    adopt(res.data);
    showReceipt(res.data, chosen === 'copy' ? 'Copie enregistrée' : chosen === 'migrate' ? 'Révision enregistrée, widgets mis à jour' : 'Enregistrée');
    loadWidgets();
  }

  async function archive() {
    const s = store.saved;
    if (!s || s.source !== 'personal') return;
    const impact = await impactReview(s.id, null);
    if (!impact) return;
    const dlg = openDialog({
      title: `Archiver « ${s.name ?? store.recipe.name} » ?`,
      subtitle: 'La requête et ses révisions restent dans les archives.',
      icon: 'trash',
      tone: 'danger',
      body: impactBody(impact, impact.widgets ? `${plural(impact.widgets, 'widget sera retiré', 'widgets seront retirés')} des tableaux de bord ; la restauration les remet.` : 'Aucun widget n’utilise cette requête.'),
      actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'archive', label: 'Archiver', icon: 'trash', danger: true }],
    });
    if (await dlg.result !== 'archive') return;
    const res = await store.call('requetes.library.archive', { id: s.id, expectedRevision: s.revision });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    store.saved = { ...s, revision: res.data.revision, archived: true };
    const removed = res.data.removedWidgets ?? [];
    showReceipt(res.data, removed.length ? `Archivée, ${plural(removed.length, 'widget retiré', 'widgets retirés')}` : 'Archivée', {
      label: 'Annuler l’archivage',
      icon: 'undo',
      run: async () => {
        const back = await store.call('requetes.library.restore', { id: s.id, expectedRevision: res.data.revision, widgets: removed });
        if (back.error) { store.toast(back.message, 'warn'); return; }
        store.saved = { ...store.saved, revision: back.data.revision, archived: false };
        showReceipt(back.data, removed.length ? 'Restaurée avec ses widgets' : 'Restaurée');
        savedState();
        loadWidgets();
      },
    });
    savedState();
    loadWidgets();
  }

  async function history() {
    const s = store.saved;
    if (!s || s.source !== 'personal') return;
    const res = await store.call('requetes.library.get', { id: s.id });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    const d = res.data;
    // The kept history holds the previous revisions; the current one heads the list.
    const list = [{ revision: d.revision, savedAt: d.updatedAt, fingerprint: store.saved?.fingerprint ?? '' }, ...[...d.history].sort((a, b) => b.revision - a.revision)];
    const dlg = openDialog({
      title: 'Révisions',
      subtitle: `« ${d.name} » · révision actuelle ${d.revision}`,
      icon: 'history',
      size: 'md',
      body: `<ol class="rq-revs">${list.map((h, n) => `<li data-i="${n}"><span class="rq-rev-n">${esc(String(h.revision))}</span><div><b>${h.revision === d.revision ? 'Révision actuelle' : `Révision ${esc(String(h.revision))}`}</b>
        <span>${esc(dateText(h.savedAt))}${h.fingerprint ? ` · <span class="rq-mono">${esc(h.fingerprint.slice(0, 12))}</span>` : ''}</span></div>
        ${h.revision === d.revision ? '' : `<button type="button" class="btn xs subtle" data-rev="${h.revision}">${glyph('undo')}Restaurer</button>`}</li>`).join('')}</ol>
        <p class="rq-note">${glyph('info')}Restaurer une révision crée une nouvelle révision : l’historique n’est jamais réécrit (5 révisions gardées).</p>`,
      onOpen: (el) => vars(el),
    });
    dlg.body.addEventListener('click', async (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-rev]') : null;
      if (!b) return;
      const rev = Number(b.dataset.rev);
      const ok = await confirmDialog({ title: `Restaurer la révision ${rev} ?`, message: 'Sa définition devient une nouvelle révision ; les widgets liés demanderont votre accord.', confirmLabel: 'Restaurer cette révision', icon: 'undo' });
      if (!ok) return;
      const back = await store.call('requetes.library.revert', { id: d.id, revision: rev, expectedRevision: d.revision });
      if (back.error) { store.toast(back.message, 'warn'); return; }
      dlg.close('done');
      adopt(back.data);
      showReceipt(back.data, `Révision ${rev} restaurée`);
    });
  }

  $('.rq-save-go').addEventListener('click', () => save('update'));
  $('.rq-save-copy').addEventListener('click', () => save('copy'));
  $('.rq-save-archive').addEventListener('click', archive);
  $('.rq-save-history').addEventListener('click', history);

  // ---------- Widgets ----------

  function setBoard(id) {
    st.board = id;
    panel.querySelectorAll('[data-board]').forEach((b) => b.setAttribute('aria-checked', String(b.dataset.board === id)));
    fillForm();
  }
  panel.querySelectorAll('[data-board]').forEach((b) => b.addEventListener('click', () => setBoard(b.dataset.board)));
  panel.querySelectorAll('[data-visual]').forEach((b) => b.addEventListener('click', () => {
    st.visual = b.dataset.visual;
    panel.querySelectorAll('[data-visual]').forEach((x) => x.setAttribute('aria-checked', String(x === b)));
    b.classList.remove('picked');
    void b.offsetWidth;
    b.classList.add('picked');
  }));
  $('.rq-visuals').addEventListener('keydown', (e) => {
    if (!['ArrowLeft', 'ArrowRight'].includes(e.key)) return;
    const list = [...panel.querySelectorAll('[data-visual]')];
    const at = list.findIndex((x) => x.dataset.visual === st.visual);
    const next = list[(at + (e.key === 'ArrowRight' ? 1 : list.length - 1)) % list.length];
    next.click();
    next.focus();
  });

  async function addWidget() {
    const title = $('.rq-w-title').value.trim();
    if (!title) { store.toast('Donnez un titre au widget.', 'warn'); $('.rq-w-title').focus(); return; }
    if (['bar', 'column'].includes(st.visual) && !store.recipe.groupBy) {
      store.toast('Les barres et colonnes demandent une répartition : choisissez-la dans « Créer ».', 'warn');
      return;
    }
    const base = payload('migrate');
    const res = await store.call('requetes.widget.save', { recipe: base.recipe, board: st.board, visual: st.visual, title, expectedRevision: base.expectedRevision, category: base.category });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    adopt(res.data);
    showReceipt(res.data, 'Widget ajouté');
    loadWidgets();
  }
  $('.rq-w-add').addEventListener('click', addWidget);

  async function loadWidgets() {
    const host = $('.rq-w-list');
    const res = await store.call('requetes.widget.list', {});
    if (!store.alive) return;
    if (res.error) { host.innerHTML = `<p class="rq-note">${esc(res.message)}</p>`; return; }
    st.widgets = res.data;
    if (!st.widgets.length) {
      host.innerHTML = `<p class="rq-note">${glyph('info')}Aucun widget de requête pour l’instant.</p>`;
      return;
    }
    host.innerHTML = `<h4 class="rq-mini-title">Widgets enregistrés <span class="k-badge">${st.widgets.length}</span></h4><ul class="rq-w-items">${st.widgets.map((w, n) => `<li data-i="${n}" class="${w.warn ? 'warn' : ''}">
      <span class="rq-w-ico" data-visual="${esc(w.visual)}">${glyph(w.board === 'computer' ? 'object' : 'gauge')}</span>
      <div class="rq-w-main"><b>${esc(w.title)}</b><span>${esc(w.recipeName ?? '—')} · ${esc(VISUALS.find((v) => v.id === w.visual)?.label ?? w.visual)} · ${esc(BOARDS.find((b) => b.id === w.board)?.label ?? w.board)}</span>
        <small>${esc(w.state)}</small></div>
      <button type="button" class="btn xs ghost icon" data-remove="${esc(w.id)}" aria-label="Retirer le widget ${esc(w.title)}" data-tip="Retirer le widget">${glyph('x')}</button></li>`).join('')}</ul>`;
    vars(host);
  }
  $('.rq-w-list').addEventListener('click', async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-remove]') : null;
    if (!b) return;
    const w = st.widgets.find((x) => x.id === b.dataset.remove);
    const ok = await confirmDialog({ title: `Retirer le widget « ${w?.title ?? ''} » ?`, message: 'La requête reste dans la bibliothèque ; seul le widget disparaît du tableau de bord.', confirmLabel: 'Retirer le widget', icon: 'x' });
    if (!ok) return;
    const res = await store.call('requetes.widget.remove', { id: b.dataset.remove });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    store.toast(res.data.removed ? 'Widget retiré.' : 'Widget déjà absent.', 'ok');
    loadWidgets();
  });

  // ---------- Test on one object ----------

  const find = debounce(async () => {
    const text = $('.rq-t-find').value.trim();
    const list = $('.rq-t-found');
    if (text.length < 2) { list.innerHTML = ''; return; }
    const my = ++st.findToken;
    list.setAttribute('aria-busy', 'true');
    const res = await store.call('requetes.objects.find', { text, target: key(store.recipe.target) });
    list.removeAttribute('aria-busy');
    if (!store.alive || my !== st.findToken) return;
    if (res.error) { list.innerHTML = `<li class="rq-note">${esc(res.message)}</li>`; return; }
    const [, many] = nounOf(store.recipe.target);
    list.innerHTML = res.data.length ? res.data.map((o, n) => `<li role="option" tabindex="-1" data-id="${esc(o.id)}" data-i="${n}">
      <span class="avatar ${key(store.recipe.target) === 'computer' ? 'pc' : ''}">${glyph({ computer: 'monitor', user: 'user', group: 'group' }[key(store.recipe.target)] ?? 'object')}</span>
      <div><b>${esc(o.name)}</b><span>${esc(o.os ?? o.dn)}</span></div>${o.active === false ? '<span class="k-pill off sm">Désactivé</span>' : ''}</li>`).join('')
      : `<li class="rq-note">Aucun ${esc(many.replace(/s$/, ''))} dont le nom contient « ${esc(text)} ».</li>`;
    vars(list);
  }, 250);
  $('.rq-t-find').addEventListener('input', find);
  $('.rq-t-find').addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); $('.rq-t-found [data-id]')?.focus(); }
  });
  $('.rq-t-found').addEventListener('keydown', (e) => {
    const items = [...panel.querySelectorAll('.rq-t-found [data-id]')];
    const at = items.indexOf(document.activeElement);
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); items[Math.max(0, Math.min(items.length - 1, at + (e.key === 'ArrowDown' ? 1 : -1)))]?.focus(); }
    if (e.key === 'Enter' && at >= 0) { e.preventDefault(); test(items[at].dataset.id); }
  });
  $('.rq-t-found').addEventListener('click', (e) => {
    const li = e.target instanceof Element ? e.target.closest('[data-id]') : null;
    if (li) test(li.dataset.id);
  });

  async function test(id) {
    const host = $('.rq-t-result');
    if (!store.validation?.valid) { store.toast('La requête n’est pas valide : corrigez-la avant de la tester.', 'warn'); return; }
    panel.querySelectorAll('.rq-t-found [data-id]').forEach((x) => x.setAttribute('aria-selected', String(x.dataset.id === id)));
    const my = ++st.testToken;
    host.innerHTML = `<div aria-busy="true">${skLines(70, 90, 60)}</div>`;
    const res = await store.call('requetes.object.test', { recipe: store.recipe, id });
    if (!store.alive || my !== st.testToken) return;
    if (res.error) { host.innerHTML = emptyState('alert', 'Test impossible', res.message); return; }
    const t = res.data;
    host.innerHTML = `<div class="rq-t-card" data-v="${esc(t.verdict)}">
      <header><div><b>${esc(t.name)}</b><span class="rq-mono">${esc(t.dn)}</span></div>${t.verdict === 'outside' ? '<span class="k-pill off sm">Hors sélection</span>' : verdictPill(t.verdict)}</header>
      <p class="rq-t-label">${esc(t.label)}${t.inScope ? '' : ' · hors du périmètre de l’atelier (évalué quand même)'}</p>
      <ol class="rq-why">${t.explanation.map((r, n) => `<li class="rq-why-row" data-v="${esc(r.verdictKey)}" data-depth="${r.depth}" data-i="${n}">
        <span class="rq-why-mark" aria-hidden="true">${glyph(VERDICTS[r.verdictKey]?.icon ?? 'info')}</span>
        <div class="rq-why-main"><b>${esc(r.condition)}</b><span>Valeur : ${esc(r.value || '—')} · ${esc(r.state)}</span></div><span class="rq-why-verdict">${esc(r.verdict)}</span></li>`).join('')}</ol></div>`;
    vars(host);
  }

  // ---------- Scripts ----------

  panel.querySelectorAll('.rq-script').forEach((b) => b.addEventListener('click', async () => {
    if (!store.validation?.valid) { store.toast('La requête n’est pas valide : rien à exporter.', 'warn'); return; }
    const searchBase = store.scope?.effective && !store.scope.wholeDomain ? store.scope.effective.dn : null;
    const res = await store.call('requetes.script', { recipe: store.recipe, format: b.dataset.format, searchBase });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    openExport(store, { ...res.data, text: b.dataset.format === 'powershell' ? 'Script en lecture seule : il interroge l’annuaire avec le filtre LDAP de la requête ; les conditions locales (relevés, sondes) restent dans Domenia.' : '' }, { title: b.querySelector('b').textContent });
  }));

  const offs = [
    store.on('recipe', fillForm),
    store.on('validation', fillForm),
    store.on('saved', fillForm),
    store.on('target', () => { $('.rq-t-found').innerHTML = ''; $('.rq-t-result').innerHTML = TEST_HINT; loadCategories(); }),
  ];
  vars(panel);
  const stopReveal = reveal(panel);
  fillForm();
  loadCategories();
  loadWidgets();

  return {
    destroy() {
      offs.forEach((off) => off());
      stopReveal();
    },
  };
}
