// « 3. Enregistrer »: category and description (the name is the title of the screen, renamed there); local library with
// revisions (save, copy, archive, history and restore of a revision) after an impact review of the linked elements
// (widgets, links that can no longer be shown, favourites of Recherche, health rules); widgets of the dashboards with a live
// preview evaluated on the local data; test of the draft on a single object; read-only scripts. Library writes are local
// (LocalWrite, its own file) with a receipt read back from the disk; nothing is ever written to the directory.
import { mountRevisionHistory } from './history.js';
import {
  esc, glyph, key, plural, verdictPill, emptyState, skLines, vars, dateText, VERDICTS, nounOf, NBSP,
} from './shared.js';
import { openExport } from './drawers.js';
import { openDialog, confirmDialog, debounce } from '../../kit/index.js';
import { reveal, announce, donut, applyVars, formatNumber } from '../../ui.js';

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

const KIND_LABEL = { widget: 'Widget', orphan: 'Lien sans affichage', view: 'Recherche', health: 'Santé' };

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
  const st = { categories: [], widgets: [], testToken: 0, findToken: 0, busy: false, visual: 'kpi', board: 'fleet', titleTouched: false, previews: new Map() };
  panel.innerHTML = `<div class="grid rq-save">
    <div class="rq-col span-7">
      <section class="card rq-identity spot reveal" aria-labelledby="rq-id-title">
        <div class="card-head"><span class="card-icon">${glyph('star')}</span><div class="rq-head-titles"><h3 id="rq-id-title">Requête enregistrée</h3>
          <p class="rq-sub">Bibliothèque locale de ce domaine : révisions conservées, rien n’est écrit dans l’annuaire.</p></div><span class="meta rq-rev-state"></span></div>
        <div class="rq-id-name"><span class="rq-id-k">Nom</span><b class="rq-id-v"></b><button type="button" class="btn xs ghost rq-id-rename">${glyph('edit')}Renommer</button></div>
        <div class="rq-form">
          <label class="rq-lbl">Catégorie<input type="text" class="input rq-save-cat" maxlength="80" list="rq-cat-list" autocomplete="off" placeholder="Mes requêtes"><datalist id="rq-cat-list"></datalist></label>
          <label class="rq-lbl wide">Description<textarea class="input rq-save-desc" rows="2" maxlength="500" placeholder="À quoi sert la requête, qui la lit, quand la relancer…"></textarea></label>
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
          <p class="rq-sub">Enregistré avec la requête, lié à sa révision ; ses données manquantes se collectent aussitôt, après votre confirmation.</p></div></div>
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
          <p class="rq-sub">Rien ne s’exécute à l’export ; aucun script ne modifie l’annuaire.</p></div></div>
        <div class="rq-script-grid">
          <button type="button" class="rq-script" data-format="powershell">${glyph('command')}<b>Script PowerShell</b><span>Évalue toute la requête sur un export JSON, ou lit les candidats de l’annuaire</span></button>
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
    } else if (s.libraryChanged) {
      host.innerHTML = `<span class="k-pill warn sm"><span class="k-pill-dot"></span>Bibliothèque à la révision ${s.libraryChanged}</span>`;
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
    $('.rq-id-v').textContent = r.name ?? '';
    if (document.activeElement !== $('.rq-save-cat')) $('.rq-save-cat').value = store.saved?.category ?? $('.rq-save-cat').value ?? '';
    if (document.activeElement !== $('.rq-save-desc') && store.saved?.description !== undefined) $('.rq-save-desc').value = store.saved.description ?? '';
    // The widget title follows the name of the query until the operator types one of their own.
    if (!st.titleTouched && document.activeElement !== $('.rq-w-title')) $('.rq-w-title').value = r.name ?? '';
    const v = store.validation;
    $('.rq-save-check').innerHTML = !v ? '' : v.valid
      ? `<p class="rq-ok-line">${glyph('check')}${esc(v.conditionCount ? plural(v.conditionCount, 'condition', 'conditions') : 'Aucune condition (tout le périmètre)')} · format ${esc(v.format)} · ${esc(v.fingerprint?.slice(0, 12) ?? '')}</p>`
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

  $('.rq-id-rename').addEventListener('click', () => api.rename());
  $('.rq-w-title').addEventListener('input', () => { st.titleTouched = true; });

  async function loadCategories() {
    const res = await store.call('requetes.library.list', { target: key(store.recipe.target), limit: 1 });
    if (!store.alive || res.error) return;
    st.categories = res.data.categories;
    $('#rq-cat-list').innerHTML = st.categories.map((c) => `<option value="${esc(c)}"></option>`).join('');
    if (!res.data.persistent) {
      $('.rq-save-check').insertAdjacentHTML('beforeend', `<p class="rq-warn-line">${glyph('info')}Ce mode n’enregistre rien sur le disque (capture ou test) : la bibliothèque vaut pour cette session.</p>`);
    }
  }

  function payload(mode) {
    const s = store.saved;
    return {
      recipe: store.recipe,
      category: $('.rq-save-cat').value.trim() || null,
      description: $('.rq-save-desc').value.trim(),
      expectedRevision: mode === 'copy' || !s || s.source !== 'personal' || s.archived ? 0 : s.revision,
      mode,
    };
  }

  function showReceipt(data, verb, action = null) {
    const box = $('.rq-receipt');
    const r = data.receipt;
    box.hidden = false;
    box.className = `rq-receipt ${r.readBack ? 'ok' : 'warn'}`;
    const notes = [];
    if (data.migratedWidgets) notes.push(plural(data.migratedWidgets, 'widget suit la nouvelle révision', 'widgets suivent la nouvelle révision'));
    if (data.droppedWidgets?.length) notes.push(plural(data.droppedWidgets.length, 'widget retiré (cible incompatible)', 'widgets retirés (cible incompatible)'));
    box.innerHTML = `<span class="rq-receipt-mark">${glyph(r.readBack ? 'check' : 'alert')}</span><div class="rq-receipt-text"><b>${esc(verb)} : « ${esc(data.name)} », révision ${esc(String(data.revision))}</b>
      <span>${esc(r.text)}${notes.length ? ` ${esc(notes.join(' ; '))}.` : ''}</span><small class="rq-mono">${esc(r.fingerprint?.slice(0, 16) ?? '')} · ${esc(dateText(r.savedAt))}${r.persisted ? '' : ' · non persistant'}${r.storeId ? ` · base ${esc(r.storeId.slice(0, 12))} · stockage ${esc(String(r.storeRevision ?? 'inconnu'))}` : ''}</small></div>
      ${action ? `<button type="button" class="btn xs subtle rq-receipt-act">${glyph(action.icon)}${esc(action.label)}</button>` : ''}`;
    if (action) box.querySelector('.rq-receipt-act').addEventListener('click', action.run, { once: true });
    box.classList.remove('pop');
    void box.offsetWidth;
    box.classList.add('pop');
    announce(`${verb} : révision ${data.revision}.`);
  }

  /**
   * Adopts what the engine wrote. A draft modified during the write is never overwritten (Domenia 1): the revision becomes
   * the base of that newer draft, which stays as the operator left it.
   */
  function adopt(data, version, extra = {}) {
    store.saved = {
      id: data.id, revision: data.revision, fingerprint: data.fingerprint ?? data.receipt?.fingerprint, source: 'personal', archived: false,
      category: data.category ?? ($('.rq-save-cat').value.trim() || 'Mes requêtes'), description: data.description ?? $('.rq-save-desc').value.trim(), name: data.name, ...extra,
    };
    if (data.recipe && store.version === version) store.setRecipe(data.recipe, { origin: 'saved' });
    else if (store.version !== version) store.toast('Le brouillon a changé pendant l’enregistrement : vos dernières modifications sont gardées, non enregistrées.', 'info');
    store.emit('saved', store.saved);
  }

  async function impactOf(id, draft) {
    const res = await store.call('requetes.library.impact', { id, ...(draft ? { recipe: draft } : {}) });
    if (res.error) { store.toast(res.message, 'warn'); return null; }
    return res.data;
  }

  function impactBody(impact, intro) {
    const rows = impact.rows.map((r) => `<tr data-kind="${esc(r.kind)}"><td><span class="rq-kind" data-kind="${esc(r.kind)}">${esc(KIND_LABEL[r.kind] ?? r.kind)}</span></td><th scope="row">${esc(r.name)}</th><td>${esc(r.element)}</td><td>${esc(r.link)}</td></tr>`).join('');
    const changes = impact.changes.map((c) => `<li><b>${esc(c.element)}</b><span class="rq-before">${esc(c.before || '—')}</span>${glyph('chevronRight')}<span class="rq-after">${esc(c.after || '—')}</span></li>`).join('');
    const counts = [impact.widgets ? plural(impact.widgets, 'widget', 'widgets') : '', impact.orphans ? plural(impact.orphans, 'lien sans affichage', 'liens sans affichage') : '',
      impact.views ? plural(impact.views, 'vue de Recherche', 'vues de Recherche') : '', impact.alerts ? plural(impact.alerts, 'règle de santé', 'règles de santé') : ''].filter(Boolean);
    return `<div class="rq-impact"><p>${esc(intro)}</p>
      ${counts.length ? `<div class="rq-impact-counts">${counts.map((c) => `<span class="chip sm">${esc(c)}</span>`).join('')}</div>` : ''}
      ${changes ? `<h4>Différences avec la révision ${esc(String(impact.currentRevision))}</h4><ul class="rq-diff">${changes}</ul>` : ''}
      ${rows ? `<h4>Éléments qui utilisent cette requête</h4><div class="rq-table-wrap"><table class="table rq-table"><thead><tr><th>Type</th><th>Nom</th><th>Élément</th><th>Lien</th></tr></thead><tbody>${rows}</tbody></table></div>` : ''}
      <p class="rq-note">${glyph('shield')}Rien n’est écrit avant votre choix ; la requête et ses liens partent ensuite dans la même écriture. Les règles de santé gardent leur révision.</p></div>`;
  }

  /**
   * Impact review (Domenia 1 PnlQueryImpact): lists the elements that use the saved recipe, then offers the choices of the
   * action asked — save or widget: update the linked elements, keep the saved recipe and write a copy, or cancel; archive:
   * archive and remove the widgets, or cancel. The draft must not change during the review.
   */
  async function review(action, id, draft) {
    const version = store.version;
    const impact = await impactOf(id, draft);
    if (!impact) return null;
    if (action !== 'archive' && (!impact.hasConsumers || !impact.changed)) return { choice: 'update', impact };
    const archive = action === 'archive';
    const dlg = openDialog({
      title: archive ? `Archiver « ${store.saved?.name ?? store.recipe.name} » ?` : 'Revue d’impact',
      subtitle: archive ? 'La requête et ses révisions restent dans les archives ; la restauration remet ses widgets.' : `« ${draft?.name ?? store.recipe.name} » · révision ${impact.currentRevision}`,
      icon: archive ? 'trash' : 'alert',
      tone: archive ? 'danger' : undefined,
      size: 'lg',
      body: impactBody(impact, archive
        ? (impact.widgets ? `${plural(impact.widgets, 'widget sera retiré', 'widgets seront retirés')} des tableaux de bord, dans la même écriture que l’archivage.` : 'Aucun widget n’utilise cette requête.')
        : 'Des éléments évaluent la révision enregistrée. Choisissez comment les traiter.'),
      actions: archive
        ? [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'archive', label: impact.widgets ? 'Archiver et retirer les widgets' : 'Archiver', icon: 'trash', danger: true }]
        : [
          { id: 'cancel', label: 'Annuler', safe: true },
          { id: 'copy', label: action === 'widget' ? 'Garder l’ancienne, copie avec le widget' : 'Garder l’ancienne, enregistrer une copie', icon: 'copy' },
          { id: 'migrate', label: action === 'widget' ? 'Mettre à jour les éléments et ajouter le widget' : 'Mettre à jour les éléments liés', icon: 'refresh', primary: true },
        ],
    });
    const answer = await dlg.result;
    if (!answer || answer === 'cancel') { store.toast('Rien n’a été écrit : la requête et ses éléments liés restent inchangés.', 'info'); return null; }
    if (store.version !== version) {
      store.toast('Le brouillon a changé pendant la revue : relancez l’enregistrement pour revoir les éléments liés.', 'warn');
      return null;
    }
    return { choice: answer, impact };
  }

  async function refreshRevision(id) {
    const fresh = await store.call('requetes.library.get', { id });
    if (!fresh.error && store.saved?.id === id) {
      store.saved = { ...store.saved, revision: fresh.data.revision, fingerprint: fresh.data.fingerprint, libraryChanged: null, archived: fresh.data.archived };
      store.emit('saved', store.saved);
    }
  }

  async function onRefused(res, s) {
    if (res.error.code === 'query.revisionChanged' && s?.id) {
      store.toast(res.message, 'warn');
      const ok = await confirmDialog({ title: 'La requête a changé', message: 'Une autre révision a été enregistrée depuis votre lecture. Relire la révision actuelle comme base de votre brouillon (vos modifications sont gardées) ?', confirmLabel: 'Relire la révision actuelle', icon: 'history' });
      if (ok) await refreshRevision(s.id);
      return;
    }
    store.toast(res.message, 'warn');
  }

  async function save(mode = 'update') {
    if (st.busy) return;
    const body = payload(mode);
    const s = store.saved;
    let chosen = mode;
    if (mode === 'update' && s?.source === 'personal' && !s.archived) {
      const decision = await review('save', s.id, body.recipe);
      if (!decision) return;
      chosen = decision.choice;
      body.mode = chosen === 'update' ? 'update' : chosen;
      if (chosen === 'copy') body.expectedRevision = 0;
    }
    const version = store.version;
    st.busy = true;
    $('.rq-save-go').classList.add('busy');
    const res = await store.call('requetes.library.save', body);
    st.busy = false;
    $('.rq-save-go').classList.remove('busy');
    if (!store.alive) return;
    if (res.error) { await onRefused(res, s); return; }
    adopt(res.data, version);
    showReceipt(res.data, chosen === 'copy' ? 'Copie enregistrée' : chosen === 'migrate' ? 'Révision enregistrée, éléments liés mis à jour' : 'Enregistrée');
    loadWidgets();
  }

  async function archive() {
    const s = store.saved;
    if (!s || s.source !== 'personal') return;
    const decision = await review('archive', s.id, null);
    if (!decision) return;
    const res = await store.call('requetes.library.archive', { id: s.id, expectedRevision: s.revision });
    if (res.error) { await onRefused(res, s); return; }
    store.saved = { ...s, revision: res.data.revision, archived: true };
    store.emit('saved', store.saved);
    const removed = res.data.removedWidgets ?? [];
    showReceipt(res.data, removed.length ? `Archivée, ${plural(removed.length, 'widget retiré', 'widgets retirés')}` : 'Archivée', {
      label: 'Annuler l’archivage',
      icon: 'undo',
      run: async () => {
        const back = await store.call('requetes.library.restore', { id: s.id, expectedRevision: res.data.revision, restoreWidgets: true });
        if (back.error) { store.toast(back.message, 'warn'); return; }
        store.saved = { ...store.saved, revision: back.data.revision, archived: false };
        store.emit('saved', store.saved);
        showReceipt(back.data, back.data.restoredWidgets?.length ? `Restaurée avec ${plural(back.data.restoredWidgets.length, 'widget', 'widgets')}` : 'Restaurée');
        loadWidgets();
      },
    });
    loadWidgets();
  }

  async function history() {
    const s = store.saved;
    if (!s || s.source !== 'personal') return;
    const res = await store.call('requetes.library.get', { id: s.id });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    const d = res.data;
    const dlg = openDialog({
      title: 'Révisions',
      subtitle: `« ${d.name} » · révision actuelle ${d.revision}`,
      icon: 'history',
      size: 'md',
      body: `<div class="rq-history"></div><p class="rq-note">${glyph('info')}Restaurer une révision crée une nouvelle révision ; les anciennes définitions et leur provenance sont conservées.</p>`,
      onOpen: (el) => vars(el),
    });
    mountRevisionHistory(dlg.body.querySelector('.rq-history'), d, { onRestore: async (rev) => {
      let mode = 'update';
      const inherited = d.consumers.filter((c) => c.kind.startsWith('legacy'));
      if (d.widgets.length) {
        const answer = await openDialog({
          title: `Restaurer la révision ${rev} ?`,
          subtitle: `${plural(d.widgets.length, 'widget évalue', 'widgets évaluent')} la révision ${d.revision}`,
          icon: 'undo',
          body: `<p>Sa définition devient une nouvelle révision. Les widgets liés peuvent la suivre, ou garder leur révision actuelle.</p>${inherited.length ? `<p>${esc(plural(inherited.length, 'liaison Domenia 1 reste', 'liaisons Domenia 1 restent'))} à la révision d’origine ; aucune disposition héritée n’est installée automatiquement.</p>` : ''}`,
          actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'update', label: 'Restaurer sans les widgets' }, { id: 'migrate', label: 'Restaurer et mettre à jour les widgets', primary: true }],
        }).result;
        if (!answer || answer === 'cancel') return;
        mode = answer;
      } else {
        const ok = await confirmDialog({ title: `Restaurer la révision ${rev} ?`, message: 'Sa définition et sa provenance deviennent une nouvelle révision ; l’historique est conservé.'
          + (inherited.length ? ' Les liaisons Domenia 1 restent attachées à leur révision d’origine.' : ''), confirmLabel: 'Restaurer cette révision', icon: 'undo' });
        if (!ok) return;
      }
      const version = store.version;
      const back = await store.call('requetes.library.revert', { id: d.id, revision: rev, expectedRevision: d.revision, mode });
      if (back.error) { store.toast(back.message, 'warn'); return; }
      dlg.close('done');
      adopt(back.data, version);
      showReceipt(back.data, `Révision ${rev} restaurée`);
      loadWidgets();
    } });
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
    panel.querySelectorAll('.rq-visuals [data-visual]').forEach((x) => x.setAttribute('aria-checked', String(x === b)));
    b.classList.remove('picked');
    void b.offsetWidth;
    b.classList.add('picked');
  }));
  $('.rq-visuals').addEventListener('keydown', (e) => {
    if (!['ArrowLeft', 'ArrowRight'].includes(e.key)) return;
    const list = [...panel.querySelectorAll('.rq-visuals [data-visual]')];
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
    const base = payload('update');
    const s = store.saved;
    let mode = 'update';
    if (s?.source === 'personal' && !s.archived) {
      const decision = await review('widget', s.id, base.recipe);
      if (!decision) return;
      mode = decision.choice;
      if (mode === 'copy') base.expectedRevision = 0;
    }
    const version = store.version;
    const res = await store.call('requetes.widget.save', { recipe: base.recipe, board: st.board, visual: st.visual, title, expectedRevision: base.expectedRevision, category: base.category, mode });
    if (res.error) { await onRefused(res, s); return; }
    adopt(res.data, version);
    showReceipt(res.data, 'Widget ajouté');
    loadWidgets();
    // Domenia 1: a widget just added collects its missing data at once — here the plan opens, and nothing is read before
    // the operator confirms it.
    if (res.data.remote && key(res.data.recipe?.target) === 'computer') {
      api.plan(`Le widget « ${title} » vient d’être ajouté : voici les mesures qui lui manquent. Rien n’est lu avant votre confirmation.`);
    }
  }
  $('.rq-w-add').addEventListener('click', addWidget);

  /** Live preview of a widget of the general board, evaluated on the local data with the revision it is bound to. */
  function widgetArt(w, ev) {
    if (!ev) return `<div class="rq-wp-art">${skLines(60, 40)}</div>`;
    if (ev.error) return `<div class="rq-wp-art err"><small>${esc(ev.error)}</small></div>`;
    const c = ev.counts;
    const share = c.population ? Math.round((1000 * c.matched) / c.population) / 10 : 0;
    if (w.visual === 'kpi') return `<div class="rq-wp-art kpi"><b>${formatNumber(c.matched)}</b><span>${formatNumber(share, 1)}${NBSP}% de ${formatNumber(c.population)}</span><i class="rq-wp-bar"><i data-w="${share}"></i></i></div>`;
    if (w.visual === 'text') return `<div class="rq-wp-art text"><p>${esc(ev.text)}</p></div>`;
    if (w.visual === 'pie') {
      return `<div class="rq-wp-art pie">${donut([{ value: c.matched, tone: 'ok' }, { value: c.unknown, tone: 'warn' }, { value: c.noMatch, tone: 'off' }], { center: `<b>${formatNumber(c.matched)}</b>`, label: ev.text })}</div>`;
    }
    const items = (ev.groups?.items ?? []).slice(0, 5);
    if (!items.length) return `<div class="rq-wp-art text"><p>${esc(ev.text)}</p></div>`;
    const max = Math.max(1, ...items.map((i) => i.value));
    return `<div class="rq-wp-art ${w.visual === 'column' ? 'cols' : 'bars'}">${items.map((i, n) => `<span class="rq-wp-item" data-i="${n}" data-tip="${esc(`${i.label} : ${formatNumber(i.value)}`)}"><i data-w="${(100 * i.value / max).toFixed(1)}"></i><small>${esc(i.label)}</small></span>`).join('')}</div>`;
  }

  async function evaluateWidget(w) {
    if (w.board !== 'fleet' || !w.displayable) return;
    const res = await store.call('requetes.widget.evaluate', { id: w.id });
    if (!store.alive) return;
    st.previews.set(w.id, res.error ? { error: res.message } : res.data);
    const host = panel.querySelector(`.rq-w-items [data-wid="${CSS.escape(w.id)}"] .rq-wp`);
    if (!host) return;
    host.innerHTML = widgetArt(w, st.previews.get(w.id));
    vars(host);
    applyVars(host);
  }

  async function loadWidgets() {
    const host = $('.rq-w-list');
    const res = await store.call('requetes.widget.list', {});
    if (!store.alive) return;
    if (res.error) { host.innerHTML = `<p class="rq-note">${esc(res.message)}</p>`; return; }
    st.widgets = res.data;
    st.previews.clear();
    if (!st.widgets.length) {
      host.innerHTML = `<p class="rq-note">${glyph('info')}Aucun widget de requête pour l’instant.</p>`;
      return;
    }
    host.innerHTML = `<h4 class="rq-mini-title">Widgets enregistrés <span class="k-badge">${st.widgets.length}</span></h4><ul class="rq-w-items">${st.widgets.map((w, n) => `<li data-i="${n}" data-wid="${esc(w.id)}" class="${w.warn ? 'warn' : ''}">
      <div class="rq-wp" aria-hidden="true">${w.board === 'fleet' && w.displayable ? widgetArt(w, null) : `<div class="rq-wp-art icon">${glyph(w.board === 'computer' ? 'object' : 'gauge')}</div>`}</div>
      <div class="rq-w-main"><b>${esc(w.title)}</b><span>${esc(w.recipeName ?? '—')} · ${esc(VISUALS.find((v) => v.id === w.visual)?.label ?? w.visual)} · ${esc(BOARDS.find((b) => b.id === w.board)?.label ?? w.board)}</span>
        <small>${esc(w.state)}</small></div>
      <button type="button" class="btn xs ghost icon" data-remove="${esc(w.id)}" aria-label="Retirer le widget ${esc(w.title)}" data-tip="Retirer le widget">${glyph('x')}</button></li>`).join('')}</ul>`;
    vars(host);
    for (const w of st.widgets) evaluateWidget(w);
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
    const [one] = nounOf(store.recipe.target);
    list.innerHTML = res.data.length ? res.data.map((o, n) => `<li role="option" tabindex="-1" data-id="${esc(o.id)}" data-i="${n}">
      <span class="avatar ${key(store.recipe.target) === 'computer' ? 'pc' : ''}">${glyph({ computer: 'monitor', user: 'user', group: 'group' }[key(store.recipe.target)] ?? 'object')}</span>
      <div><b>${esc(o.name)}</b><span>${esc(o.os ?? o.dn)}</span></div>${o.active === false ? '<span class="k-pill off sm">Désactivé</span>' : ''}</li>`).join('')
      : `<li class="rq-note">Aucun ${esc(one)} dont le nom contient « ${esc(text)} ».</li>`;
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
    openExport(store, res.data, { title: b.querySelector('b').textContent });
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
      find.cancel();
    },
  };
}
