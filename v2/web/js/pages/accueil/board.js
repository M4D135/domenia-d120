// Accueil: fleet board of the working OU (Domenia 1 « Tableau de bord du parc »): widgets grouped by section, every
// figure opening its exact workstations, and the layout the operator shapes (add, remove, reorder by dragging or with
// Alt + arrows, size, representation, title, pause), kept in the local preferences (accueil.layout.save, LocalWrite).
// Data: accueil.board (LocalRead, computed from the local base, no network) and accueil.layout (docs/ops/accueil.md § 3-5).
import { glyph } from '../../kit/glyphs.js';
import { openMenu } from '../../kit/menu.js';
import { createCommandBar } from '../../kit/commandbar.js';
import { openDialog } from '../../kit/dialog.js';
import { field, createForm } from '../../kit/form.js';
import { esc, formatNumber, countUp, reveal, motionReduced, cssMs, announce } from '../../ui.js';
import { NBSP, plural, tone, paint, reported, sk, skStack, localStamp, isNum } from './shared.js';
import { widgetBody, widgetGlyph, visualFor } from './charts.js';
import { chooseBoardVersion } from '../board-history.js';
import { createBoardTransfer } from '../board-transfer.js';
import { createWidgetCollections } from './widget-collections.js';
import { sectionName, sectionsOf, placeWidget, moveSection, renameSection } from './board-organization.js';

const SIZE_LABEL = { S: 'Compacte', M: 'Moyenne', L: 'Large' };
const VISUAL_LABEL = {
  Kpi: 'Chiffre clé', Gauge: 'Jauge', Pie: 'Anneau', Bar: 'Barres', Column: 'Histogramme', Line: 'Courbe', Text: 'Liste',
  List: 'Liste de points', HealthSummary: 'Score et points', Health: 'Score',
};
const VISUALS = {
  value: ['Kpi', 'Text'], distribution: ['Pie', 'Bar', 'Column', 'Text', 'Kpi'], series: ['Column', 'Bar', 'Text', 'Kpi'],
  timeline: ['Line', 'Column', 'Text'], list: ['List'], health: ['HealthSummary', 'Health', 'Kpi'],
};
const UNDO_MAX = 10;

/** Key of the board entry of a layout item (builtin key, « probe:<id> », « query:<id> »). */
export const entryKey = (item) => (item.source === 'probe' ? `probe:${item.key}` : item.source === 'query' ? `query:${item.key}` : item.key);
const wire = (i) => ({ id: i.id || null, source: i.source, key: i.key, visual: i.visual, size: i.size, title: i.title ?? null, paused: Boolean(i.paused), group: i.group ?? '', ...(i.height ? { height: i.height } : {}), ...(i.hidden ? { hidden: true } : {}), ...(i.queryBinding ? { queryBinding: i.queryBinding } : {}) });

/**
 * @param {HTMLElement} host  Section that receives the board.
 * @param {{
 *   ctx: any,
 *   onTargets: (key: string, label: string) => void,
 *   onAction: (id: string, entry: any) => void,
 *   onTool: (id: string) => void,
 *   onComputed: (board: any, layout: any) => void,
 *   onState?: (state: 'running'|'ready'|'error', board?: any, err?: any) => void,
 * }} o
 */
export function createBoard(host, o) {
  const { ctx } = o;
  const st = {
    board: null, layout: null, editing: false, undo: [], redo: [], writing: false, busy: false, alive: true, token: 0, saving: Promise.resolve(),
    loading: false, since: null, error: null, lastView: null,
  };
  const transfer = createBoardTransfer((op, args) => ctx.call(op, args), () => st.alive);
  let transferring = false;
  const sigs = new Map(); // item id → signature of what its card shows (unchanged cards are left alone)
  let stopReveal = () => {};
  let seq = 0;
  let sinceTimer = null;

  host.innerHTML = `<div class="fw-bar reveal">
      <div class="fw-pop" aria-live="polite">${skStack('sk-line w55', 'sk-line w40')}</div>
      <div class="fw-tools"></div>
      <p class="fw-edit-note" hidden>${glyph('grip')}<span>Glissez la poignée pour déplacer un widget (ou Alt + flèches au clavier). Son crayon permet de changer la taille, la représentation et le titre. Ajoutez d’autres widgets avec « Ajouter un widget », puis choisissez « Terminer ». Chaque changement est mémorisé.</span></p>
    </div>
    <details class="fw-collect-queue" data-widget-queue hidden></details>
    <div class="fw-groups" aria-busy="true">${skeletonGroups()}</div>`;
  const groupsEl = host.querySelector('.fw-groups');
  // The page-level reveal() ran before this bar existed: observe it here, or it keeps the hidden entrance state.
  const stopBarReveal = reveal(host);
  const popEl = host.querySelector('.fw-pop');
  const collections = createWidgetCollections({ ctx, host, isAlive: () => st.alive, onChanged: () => load({ quiet: true }) });

  // Commands of the board (KIT § 4.6): one Tab stop, arrows between the commands, what does not fit goes into « Plus ». No
  // primary command here: the primary action of the screen is « Tout actualiser » of the header. Everything is local
  // (calculation from the local base, layout, panels): no network command in this bar.
  function toolItems() {
    return [
      { id: 'recompute', label: st.loading ? 'Calcul en cours…' : 'Recalculer la vue', icon: 'refresh', pinned: true, disabled: st.loading,
        reason: `Calcul en cours${NBSP}: la vue se met à jour depuis la base locale.`, run: () => load({ quiet: false }) },
      { id: 'edit', label: st.editing ? 'Terminer' : 'Modifier l’accueil', icon: 'sliders', pinned: true, run: () => setEditing(!st.editing) },
      ...(st.editing && st.undo.length ? [{ id: 'undo', label: 'Annuler', icon: 'undo', pinned: true, run: () => undo() }] : []),
      ...(st.editing && st.redo.length ? [{ id: 'redo', label: 'Rétablir', icon: 'refresh', pinned: true, run: () => redo() }] : []),
      { id: 'versions', label: 'Versions précédentes', icon: 'history', disabled: !st.layout?.history?.length, reason: 'Aucune version précédente conservée.', run: () => restoreVersion() },
      { id: 'catalog', label: 'Ajouter un widget', icon: 'plus', pinned: true, run: () => o.onTool('catalog') },
      ...(st.editing ? [{ id: 'section', label: 'Nouvelle section', icon: 'layers', pinned: true, disabled: !st.layout?.items.length, reason: 'Ajoutez un premier widget pour créer une section.', run: () => editSection() }] : []),
      { id: 'presets', label: 'Dispositions', icon: 'layers', items: presetItems() },
      { id: 'import-file', label: 'Importer une disposition', icon: 'folder', run: () => transferLayout('import') },
      { id: 'export-file', label: 'Exporter la disposition', icon: 'download', run: () => transferLayout('export') },
      { id: 'migrate-d1', label: 'Reprendre la disposition D1', icon: 'history', run: () => migrateD1() },
      { id: 'search', label: 'Ouvrir les postes dans Rechercher', icon: 'search', disabled: st.loading || !st.board?.revision || !o.onOpenSearch?.(true),
        reason: `Attendez le calcul d’une OU de travail${NBSP}: seuls ses postes exacts seront ouverts.`, run: () => o.onOpenSearch?.(false) },
      { id: 'explain', label: 'Comprendre le score', icon: 'gauge', run: () => o.onTool('explain') },
      { id: 'health', label: 'Règles de santé', icon: 'shield', run: () => o.onTool('health') },
      { id: 'analysis', label: 'Analyse', icon: 'split', run: () => o.onTool('analysis') },
      { id: 'provenance', label: 'Provenance', icon: 'history', run: () => o.onTool('provenance') },
    ].map(item => st.writing || transferring ? { ...item, disabled: true, reason: 'Enregistrement de la disposition en cours.' } : item);
  }
  const bar = createCommandBar(host.querySelector('.fw-tools'), { label: 'Outils du tableau du parc', size: 'sm', items: toolItems(), moreLabel: 'Plus d’outils du tableau' });
  const syncBar = () => { if (st.alive) bar.setItems(toolItems()); };

  async function migrateD1() {
    try {
      const preview = await ctx.call('shell.interface.migration.preview');
      if (!st.alive) return;
      const fleet = preview.boards?.find((b) => b.board === 'Fleet');
      const boardLabels = { Fleet: 'Parc', Computer: 'Poste', Software: 'Logiciels' };
      const canApply = preview.available && !preview.fleetChoiceExists && fleet?.state === 'ready';
      const body = document.createElement('div');
      body.innerHTML = `<p>Reprenez votre tableau du parc de Domenia 1 dans Accueil. Les fichiers D1 restent intacts.</p>
        ${preview.reason ? `<p>${esc(preview.reason)}</p>` : ''}
        ${preview.fleetChoiceExists ? '<p>Une disposition D2 ou une migration est déjà enregistrée, même vide. Elle sera conservée.</p>' : ''}
        ${preview.sourcePath ? `<p>Source locale : <span class="code">${esc(preview.sourcePath)}</span></p>` : ''}
        ${fleet?.teamSource ? `<p>Configuration d’équipe : <span class="code">${esc(fleet.teamSource.path)}</span></p>` : ''}
        <ul>${(preview.boards ?? []).map((b) => `<li><strong>${esc(boardLabels[b.board] ?? 'Tableau')}</strong> — ${esc(b.summary)}${b.state === 'ready' ? ` (${formatNumber(b.count)} widgets)` : ''}</li>`).join('')}</ul>
        ${(preview.warnings ?? []).map((w) => `<p>${esc(w)}</p>`).join('')}
        ${fleet?.state === 'ready' && fleet.items.length ? `<ol>${fleet.items.map((i) => `<li>${esc(i.title || i.queryBinding?.name || i.key)}${i.queryBinding ? ` — révision ${i.queryBinding.revision} · empreinte ${esc(i.queryBinding.fingerprint)}${i.queryBinding.currentRevisionProposed ? ' · nouvelle liaison à confirmer' : ' · liaison D1 conservée'}` : ''}${i.paused ? ' — en pause' : ''}</li>`).join('')}</ol>` : ''}`;
      const d = openDialog({ title: 'Disposition Domenia 1', icon: 'history', size: 'md', body,
        actions: [{ id: 'cancel', label: 'Fermer', safe: true }, ...(canApply ? [{ id: 'apply', label: fleet?.queryBindingsSha256 ? 'Importer dans Accueil et lier les révisions' : 'Importer dans Accueil', primary: true }] : [])] });
      if (await d.result !== 'apply' || !st.alive) return;
      const result = await ctx.call('shell.interface.migrate', { sourceSha256: preview.sourceSha256,
        ...(fleet?.teamSource ? { configurationSha256: fleet.teamSource.sha256 } : {}),
        ...(fleet?.queryBindingsSha256 ? { queryBindingsSha256: fleet.queryBindingsSha256 } : {}) });
      if (!st.alive) return;
      st.undo = []; st.redo = [];
      ctx.toast(result.summary, { tone: result.applied ? 'ok' : 'info' });
      await load();
    } catch (err) {
      if (st.alive) ctx.toast(reported(err), { tone: 'warn' });
    }
  }

  function skeletonGroups() {
    const card = (size) => `<article class="card fw size-${size}">${skStack('sk-line w40', 'sk-title w55', 'sk-line w85')}</article>`;
    return `<section class="fw-skeleton"><h3 class="fw-group-title">${sk('sk-line w25')}</h3><div class="fw-grid">${['S', 'S', 'S', 'S', 'M', 'M', 'M'].map(card).join('')}</div></section>`;
  }

  // ---------- Loading ----------

  async function load({ quiet = true, periodic = false, afterWrite = false } = {}) {
    if (st.writing && !afterWrite || periodic && st.loading) return;
    const my = ++st.token;
    setLoading(true);
    o.onState?.('running');
    try {
      const layout = await ctx.call('accueil.layout');
      const board = await ctx.call('accueil.board'); // Its active cards depend on the freshly read persisted layout.
      if (!st.alive || my !== st.token) return;
      collections.scope(board.scope);
      st.board = board;
      st.layout = layout;
      st.error = null;
      paintAll();
      o.onComputed?.(board, layout);
      o.onState?.('ready', board);
      if (!quiet) ctx.toast('Tableau du parc recalculé depuis la base locale, sans lecture réseau.', { tone: 'ok', life: 2400 });
      return true;
    } catch (err) {
      if (!st.alive || my !== st.token) return;
      st.error = err;
      paintError(err);
      o.onState?.('error', null, err);
      if (periodic) throw err;
      return false;
    } finally {
      if (my === st.token && st.alive) setLoading(false);
    }
  }

  // « Calcul en cours depuis » (improvement of ACC-032): the bar says since when, the cards stay readable underneath.
  function setLoading(on) {
    st.loading = on;
    st.since = on ? (st.since ?? new Date()) : null;
    if (on) groupsEl.setAttribute('aria-busy', 'true'); else groupsEl.removeAttribute('aria-busy');
    host.classList.toggle('updating', on && Boolean(st.board));
    syncBar();
    bar.setBusy('recompute', on);
    sinceTimer?.();
    sinceTimer = null;
    paintSince();
    if (on) sinceTimer = ctx.pulse.every('board.elapsed', 1000, paintSince);
  }

  function paintSince() {
    const el = host.querySelector('.fw-since');
    if (!el) return;
    if (!st.loading || !st.since) { el.hidden = true; return; }
    const secs = Math.max(0, Math.round((Date.now() - st.since.getTime()) / 1000));
    el.hidden = false;
    el.textContent = `Calcul en cours depuis ${new Intl.DateTimeFormat('fr-FR', { hour: '2-digit', minute: '2-digit', second: '2-digit' }).format(st.since)} (${formatNumber(secs)}${NBSP}s)`;
  }

  function paintError(err) {
    popEl.innerHTML = '';
    sigs.clear();
    groupsEl.innerHTML = `<div class="card fw-error reveal" role="alert">${glyph('alert')}<div><h3>Tableau du parc indisponible</h3><p>${esc(reported(err))}</p>`
      + `${err?.code ? `<span class="code">${esc(err.code)}</span>` : ''}${st.board ? '<p class="fw-error-note">Les chiffres affichés auparavant peuvent dater de la lecture précédente.</p>' : ''}</div>`
      + `<button class="btn sm" type="button" data-fw-retry>${glyph('refresh')}Réessayer</button></div>`;
    stopReveal();
    stopReveal = reveal(groupsEl);
  }

  /**
   * Last view of the same base and OU (ACC-035, cache first): while the first calculation runs, its figures fill grey tiles
   * presented as not recalculated; they go away as soon as the board arrives.
   */
  function showLastView(v) {
    st.lastView = v;
    if (st.board || st.error || !v?.available || !st.loading) return;
    const tile = (label, value, sub) => `<div class="fw-last-tile"><span class="fw-last-k">${esc(label)}</span><b class="num">${isNum(value) && value >= 0 ? formatNumber(value) : '—'}</b>${sub ? `<span class="fw-last-sub">${esc(sub)}</span>` : ''}</div>`;
    groupsEl.innerHTML = `<section class="fw-last" aria-label="Dernière vue enregistrée, non recalculée">
        <p class="fw-last-head">${glyph('history')}<span><b>Dernière vue</b> · ${esc(localStamp(v.computedAt))} · non recalculée</span><span class="k-spin" aria-hidden="true"></span><span class="fw-last-run">Calcul en cours depuis la base locale…</span></p>
        <div class="fw-last-tiles">${tile('Postes actifs', v.machines, v.scopeLabel ?? '')}${tile('À traiter', v.problems, 'au calcul enregistré')}</div>
        <p class="fw-last-note">${esc(String(v.text ?? '').split('\n').slice(1, 2).join(' '))}</p></section>${skeletonGroups()}`;
  }

  // ---------- Painting ----------

  function populationLine(b) {
    const p = b.population ?? {};
    const parts = [
      `<b class="num">${formatNumber(p.machines ?? 0)}</b>${NBSP}${(p.machines ?? 0) > 1 ? 'comptes ordinateur' : 'compte ordinateur'}`,
      `${formatNumber(p.enabled ?? 0)}${NBSP}activés`,
      `${formatNumber(p.disabled ?? 0)}${NBSP}désactivés`,
    ];
    if (p.unknown) parts.push(`${formatNumber(p.unknown)}${NBSP}état inconnu`);
    // Freshness of the branch (ACC-020): the last complete AD read covering it, a partial attempt or a date in the future.
    const d = b.directory;
    const dirTone = d?.clockInvalid ? 'alert' : d?.partial || d?.status === 'missing' ? 'warn' : '';
    const dirText = !d ? '' : d.at ? `AD lu le ${localStamp(d.at)}${d.partial ? ', tentative partielle depuis' : ''}` : d.partial ? 'lecture AD partielle seulement' : 'aucune lecture AD complète de la branche';
    const dirPart = dirText ? ` · <span class="fw-pop-dir"${dirTone ? ` data-tone="${dirTone}"` : ''} data-tip="${esc(`${d.text}${d.sourceDn ? ` · lu depuis ${d.sourceDn}` : ''} · le nombre de comptes ordinateur inclut les désactivés.`)}">${esc(dirText)}${d.clockInvalid ? `${NBSP}· date future ignorée` : ''}</span>` : '';
    return `<p class="fw-pop-main">${glyph('ou')}<span>${esc(b.scopeLabel ?? '')}</span><span class="dot-sep" aria-hidden="true"></span>${parts.join('<span class="dot-sep" aria-hidden="true"></span>')}</p>`
      + `<p class="fw-pop-sub" data-tip="${esc(b.summary ?? '')}">Calculé le ${esc(localStamp(b.computedAt))} depuis la base locale, sans lecture réseau${b.scope?.subtree ? ' · sous-OU comprises' : ' · cette OU seulement'}${st.layout?.customized ? ' · disposition personnalisée' : ''}${dirPart}</p>`
      + '<p class="fw-since" aria-live="polite" hidden></p>';
  }

  function groupsOf(items) {
    return sectionsOf(items);
  }

  /** Signature of what a card shows: an unchanged card is never repainted (no flicker, no counter from 0). */
  function signature(item, entry) {
    const b = st.board;
    const wide = entry && (entry.kind === 'health' || entry.kind === 'list' || entry.kind === 'value');
    return JSON.stringify([item, entry ?? null, wide ? [b.health, b.population] : null]);
  }

  function cardClass(item, entry) {
    const dimensions = `size-${item.size}${item.height ? ` height-${item.height}` : ''}${item.hidden ? ' is-hidden' : ''}`;
    if (!entry) return `card fw ${dimensions}`;
    const v = visualFor(entry, item);
    return [`card fw spot ${dimensions} v-${v.toLowerCase()} k-${entry.kind}`, entry.tone === 'off' || !entry.measured ? 'is-dim' : '', item.paused ? 'is-paused' : ''].filter(Boolean).join(' ');
  }

  function cardInner(item, entry, uid) {
    const b = st.board;
    if (!entry) {
      return `${head(item, { title: item.title ?? item.key, kind: 'value' })}<div class="fw-body"><div class="fw-empty">${glyph('info')}<span>Widget non calculé pour ce périmètre.</span></div></div><p class="fw-collect-progress" data-widget-progress aria-live="polite" hidden></p><button class="btn sm ghost" type="button" data-fw-collect="${esc(item.id)}" ${item.paused ? 'disabled' : ''}>Collecter ce widget</button>`;
    }
    const v = visualFor(entry, item);
    let body;
    try {
      body = widgetBody(entry, item, b, uid);
    } catch (err) {
      console.error(`Widget « ${item.key} » : affichage impossible`, err, entry);
      body = `<div class="fw-empty">${glyph('alert')}<span>Données inattendues${NBSP}: ce widget ne peut pas s’afficher. Les autres widgets ne sont pas concernés.</span></div>`;
    }
    const action = `<button class="btn sm ghost" type="button" data-fw-collect="${esc(item.id)}" ${item.paused ? 'disabled' : ''} data-tip="Préparer les seules mesures manquantes de ce widget et confirmer le nombre de postes">${glyph('refresh')}Actualiser ce widget</button>`;
    const open = entry.targetsKey && (entry.targets ?? 0) > 0 && v !== 'Kpi'
      ? `<button class="btn sm ghost fw-see" type="button" data-targets="${esc(entry.targetsKey)}" data-targets-label="${esc(entry.title)}">${glyph('monitor')}${plural(entry.targets, 'poste', 'postes')}</button>` : '';
    return `<span class="fw-accent" aria-hidden="true"></span>${head(item, entry, uid)}<div class="fw-body">${body}</div>`
      + `<p class="fw-collect-progress" data-widget-progress aria-live="polite" hidden></p><footer class="fw-foot">${v === 'HealthSummary' ? '<span class="fw-detail"></span>' : `<p class="fw-detail">${esc(entry.detail)}</p>`}${action || open ? `<div class="fw-foot-act">${action}${open}</div>` : ''}</footer>`;
  }

  /** Writes the card of one item (new article, or the same article updated in place). */
  function fillCard(card, item, n) {
    const entry = st.board.entries?.[entryKey(item)] ?? null;
    seq += 1;
    const uid = `fwg-${seq}`;
    const fresh = !card.dataset.item;
    const keep = card.classList.contains('revealed') || card.classList.contains('in') ? (card.classList.contains('revealed') ? ' revealed' : ' reveal in') : (fresh ? ' reveal' : '');
    card.className = cardClass(item, entry) + keep;
    card.dataset.item = item.id;
    card.dataset.j = String(n);
    if (entry) { card.dataset.entry = entry.key; card.setAttribute('aria-labelledby', `${uid}-t`); } else { delete card.dataset.entry; card.removeAttribute('aria-labelledby'); }
    if (entry?.tone && entry.tone !== 'off') card.dataset.tone = tone(entry.tone); else delete card.dataset.tone;
    card.innerHTML = cardInner(item, entry, uid);
    sigs.set(item.id, signature(item, entry));
  }

  function head(item, entry, uid = '') {
    const title = item.title ?? entry.title;
    const chips = [];
    for (const source of [...new Set(Array.isArray(entry.sources) ? entry.sources.filter(value => typeof value === 'string' && value) : [])]) {
      chips.push(`<span class="fw-source" data-tip="${esc(`Source des données${NBSP}: ${source}`)}">${esc(source)}</span>`);
    }
    if (item.hidden) chips.push('<span class="k-pill sm off">Masqué</span>');
    if (item.paused) chips.push('<span class="k-pill sm warn" data-tip="Non relevé à la prochaine actualisation ; la dernière valeur reste affichée">En pause</span>');
    else if (entry.tone === 'off' && entry.measured) chips.push('<span class="k-pill sm off" data-tip="Mesure ancienne ou couverture partielle">Ancien</span>');
    if (entry.subtitle && entry.measured) chips.push(`<span class="fw-cov" data-tip="${esc(entry.subtitle)}">${esc(entry.subtitle)}</span>`);
    return `<header class="fw-head">
        <button class="fw-grip" type="button" data-fw-grip aria-label="Déplacer «${NBSP}${esc(title)}${NBSP}» (Alt + flèches)" data-tip="Glisser pour déplacer · Alt + flèches">${glyph('grip')}</button>
        <span class="fw-ico" aria-hidden="true">${glyph(widgetGlyph(entry, item))}</span>
        <div class="fw-titles"><h4${uid ? ` id="${uid}-t"` : ''}>${esc(title)}</h4>${chips.length ? `<div class="fw-chips">${chips.join('')}</div>` : ''}</div>
        <button class="btn ghost icon sm fw-menu" type="button" data-fw-menu aria-haspopup="menu" aria-label="Modifier le widget ${esc(title)}" data-tip="Modifier le widget">${glyph('edit')}</button>
      </header>`;
  }

  /**
   * Fills the rows of a section (« remplir la rangée automatiquement »): items are placed in order on a 12-column grid, then the
   * room left on each row goes to its smallest cards, each one growing to twice its size at most. Three grids, one per width
   * band of the stylesheet (--span-w ≥ 1500 px, --span-m ≥ 1000 px, --span-n below).
   */
  function rowSpans(items, base) {
    const spans = items.map((i) => base[i.size] ?? base.M);
    const rows = [];
    let row = [];
    let used = 0;
    spans.forEach((span, n) => {
      if (used + span > 12 && row.length) { rows.push(row); row = []; used = 0; }
      row.push(n);
      used += span;
    });
    if (row.length) rows.push(row);
    for (const r of rows) {
      let left = 12 - r.reduce((sum, n) => sum + spans[n], 0);
      while (left > 0) {
        const grow = r.filter((n) => spans[n] < Math.min(12, 2 * (base[items[n].size] ?? base.M)));
        if (!grow.length) break;
        const n = grow.reduce((a, b) => (spans[b] <= spans[a] ? b : a));
        spans[n] += 1;
        left -= 1;
      }
    }
    return spans;
  }

  function applySpans(grid, items) {
    const wide = rowSpans(items, { S: 3, M: 6, L: 12 });
    const mid = rowSpans(items, { S: 4, M: 6, L: 12 });
    const narrow = rowSpans(items, { S: 6, M: 12, L: 12 });
    [...grid.children].forEach((card, n) => {
      if (n >= items.length) return;
      card.style.setProperty('--span-w', String(wide[n]));
      card.style.setProperty('--span-m', String(mid[n]));
      card.style.setProperty('--span-n', String(narrow[n]));
    });
  }

  /**
   * Board painted from its data, keeping the DOM (ACC-037: computed again every 15 s during a refresh): sections and cards are
   * matched by name and item id; an unchanged card is left alone; a changed one is rewritten in place without its entrance and
   * its figures count from their previous value; only new cards enter.
   */
  function paintAll() {
    if (drag) clearDrag();
    const b = st.board;
    const items = (st.layout?.items ?? []).filter(item => st.editing || !item.hidden);
    popEl.innerHTML = populationLine(b);
    paint(popEl);
    paintSince();
    groupsEl.querySelector('.fw-last')?.remove();
    groupsEl.querySelectorAll(':scope > .fw-skeleton, :scope > .fw-error, :scope > .fw-empty-board').forEach((x) => x.remove());
    if (st.layout?.valid === false) {
      sigs.clear();
      groupsEl.innerHTML = `<div class="card fw-error" role="alert"><h3>Disposition conservée sans modification</h3><p>${esc(st.layout.reason)}</p></div>`;
      return;
    }
    if (!items.length) {
      sigs.clear();
      const hidden = st.layout?.items?.some(item => item.hidden);
      groupsEl.innerHTML = `<div class="card fw-error fw-empty-board reveal">${glyph('layers')}<div><h3>${hidden ? 'Widgets masqués' : 'Aucun widget'}</h3><p>${hidden ? 'Choisissez « Modifier l’accueil » pour réafficher vos widgets.' : `La disposition est vide${NBSP}: ajoutez des widgets du catalogue ou rétablissez la disposition livrée.`}</p></div>`
        + `<button class="btn sm primary" type="button" data-fw-tool="catalog">${glyph('plus')}Ajouter un widget</button></div>`;
      stopReveal();
      stopReveal = reveal(groupsEl);
      return;
    }
    const hints = Array.isArray(b.hints) ? b.hints : [];
    const groups = groupsOf(items);
    const wanted = new Set(groups.map((g) => g.name));
    groupsEl.querySelectorAll(':scope > .fw-group').forEach((sec) => { if (!wanted.has(sec.dataset.group)) sec.remove(); });
    const changed = [];
    const added = [];
    let prev = null;
    groups.forEach((g, gi) => {
      let sec = [...groupsEl.querySelectorAll(':scope > .fw-group')].find((x) => x.dataset.group === g.name);
      if (!sec) {
        sec = document.createElement('section');
        sec.className = 'fw-group';
        sec.dataset.group = g.name;
        sec.innerHTML = `<h3 class="fw-group-title"><span data-group-name></span><span class="fw-group-count"></span><button type="button" class="btn ghost icon sm fw-section-menu" data-fw-section aria-haspopup="menu">${glyph('edit')}</button></h3><div class="fw-hints"></div><div class="fw-grid"></div>`;
      }
      if ((prev ? prev.nextElementSibling : groupsEl.firstElementChild) !== sec) {
        if (prev) prev.after(sec); else groupsEl.prepend(sec);
      }
      prev = sec;
      sec.dataset.i = String(gi);
      sec.setAttribute('aria-labelledby', `fwg-h-${gi}`);
      const title = sec.querySelector('.fw-group-title');
      title.id = `fwg-h-${gi}`;
      title.querySelector('[data-group-name]').textContent = g.name;
      title.querySelector('.fw-group-count').textContent = plural(g.items.length, 'widget', 'widgets');
      const sectionButton = title.querySelector('[data-fw-section]');
      sectionButton.setAttribute('aria-label', `Modifier la section ${g.name}`);
      sectionButton.dataset.tip = 'Modifier la section';
      const hintsEl = sec.querySelector('.fw-hints');
      const hintHtml = hints.filter((h) => h.group === g.name).map((h) => `<div class="fw-hint">${glyph('info')}<span>${esc(h.text)}</span>`
        + `${h.action ? `<button class="btn sm" type="button" data-fw-action="${esc(h.action.id)}" data-tip="${esc(h.action.tip)}">${glyph('refresh')}${esc(h.action.label)}</button>` : ''}</div>`).join('');
      if (hintsEl.innerHTML !== hintHtml) hintsEl.innerHTML = hintHtml;
      const grid = sec.querySelector('.fw-grid');
      const ids = new Set(g.items.map((i) => i.id));
      grid.querySelectorAll(':scope > .card.fw').forEach((c) => { if (!ids.has(c.dataset.item)) { sigs.delete(c.dataset.item); c.remove(); } });
      let before = null;
      g.items.forEach((item, n) => {
        let card = [...grid.children].find((c) => c.dataset.item === item.id);
        const entry = b.entries?.[entryKey(item)] ?? null;
        if (!card) {
          card = document.createElement('article');
          fillCard(card, item, n);
          added.push(card);
        } else if (sigs.get(item.id) !== signature(item, entry)) {
          const previous = currentValues(card);
          fillCard(card, item, n);
          // Kept until the next change: the rewritten content never replays its entrance (no flicker every 15 s).
          card.classList.add('is-update');
          changed.push([card, previous]);
        } else {
          card.dataset.j = String(n);
        }
        if ((before ? before.nextElementSibling : grid.firstElementChild) !== card) {
          if (before) before.after(card); else grid.prepend(card);
        }
        before = card;
      });
      applySpans(grid, g.items);
    });
    // Hints of a section without widget on the board stay visible under the last section.
    groupsEl.querySelector(':scope > .fw-hints-rest')?.remove();
    const orphan = hints.filter((h) => !items.some((i) => (i.group || 'Autres widgets') === h.group));
    if (orphan.length) {
      groupsEl.insertAdjacentHTML('beforeend', `<div class="fw-hints-rest">${orphan.map((h) => `<div class="fw-hint">${glyph('info')}<span><b>${esc(h.group)}</b> · ${esc(h.text)}</span>`
        + `${h.action ? `<button class="btn sm" type="button" data-fw-action="${esc(h.action.id)}">${glyph('refresh')}${esc(h.action.label)}</button>` : ''}</div>`).join('')}</div>`);
    }
    paint(groupsEl);
    host.classList.toggle('editing', st.editing);
    changed.forEach(([card, previous]) => runCounters(card, 0, previous));
    // Only the new cards enter (one observer at a time: the previous one is stopped first).
    if (added.length) {
      stopReveal();
      stopReveal = reveal(groupsEl, { onIn: (el, n) => runCounters(el, n) });
    }
    added.filter((el) => !el.classList.contains('reveal')).forEach((el) => runCounters(el, 0));
    collections.paint();
  }

  function currentValues(card) {
    const map = new Map();
    card.querySelectorAll('[data-count]').forEach((el, k) => map.set(k, Number(el.textContent.replace(/[^\d,.-]/g, '').replace(',', '.'))));
    return map;
  }

  function runCounters(card, n, previous = null) {
    const delay = previous ? 0 : n * cssMs('--stagger', 55) + 160;
    card.querySelectorAll('[data-count]').forEach((el, k) => {
      const from = previous?.get(k);
      countUp(el, Number(el.dataset.count), { decimals: Number(el.dataset.dec ?? 0), suffix: el.dataset.suffix ?? '', delay, from: Number.isFinite(from) ? from : 0 });
    });
  }

  // ---------- Layout changes ----------

  const itemOf = (id) => st.layout?.items.find((i) => i.id === id) ?? null;

  async function commitLayout(operation, args, { recompute = false, message = '', undoable = true } = {}) {
    if (!st.layout || st.layout.valid === false || st.writing) return false;
    const before = st.layout.items;
    const expectedChoiceToken = args.expectedChoiceToken ?? st.layout.choiceToken;
    st.writing = true; syncBar();
    const run = async () => {
      try {
        const saved = await ctx.call(operation, { ...args, expectedChoiceToken });
        if (!st.alive) return false;
        if (undoable && JSON.stringify(before.map(wire)) !== JSON.stringify(saved.items.map(wire))) {
          st.undo.push({ items: before, expectedToken: saved.choiceToken }); if (st.undo.length > UNDO_MAX) st.undo.shift(); st.redo = [];
        }
        st.layout = saved;
        paintAll();
        if (recompute) await load({ afterWrite: true });
        if (message) announce(message);
        return saved;
      } catch (err) {
        if (!st.alive) return false;
        await load({ afterWrite: true }); // Refusal shows the actual latest choice, never an optimistic old list.
        ctx.toast(reported(err), { tone: 'alert' });
        return false;
      } finally { st.writing = false; syncUndo(); }
    };
    st.saving = run();
    return st.saving;
  }

  async function save(items, options = {}) {
    if (!st.layout || st.writing) return false;
    if (JSON.stringify(items.map(wire)) === JSON.stringify(st.layout.items.map(wire))) return st.layout;
    return commitLayout('accueil.layout.save', { items: items.map(wire) }, options);
  }

  function syncUndo() { syncBar(); }

  async function historyStep(backwards) {
    const from = backwards ? st.undo : st.redo; const to = backwards ? st.redo : st.undo;
    if (!st.alive) return;
    const step = from.at(-1); if (!step || st.writing) return;
    if (step.expectedToken !== st.layout.choiceToken) { ctx.toast('Une autre disposition a été appliquée ; ancienne annulation refusée.', { tone: 'warn' }); return; }
    const before = st.layout.items;
    const saved = await save(step.items, { recompute: true, message: backwards ? 'Dernière modification annulée.' : 'Modification rétablie.', undoable: false });
    if (saved) {
      from.pop(); to.push({ items: before, expectedToken: saved.choiceToken }); if (to.length > UNDO_MAX) to.shift();
      if (from.length) from.at(-1).expectedToken = saved.choiceToken;
      syncUndo();
    }
  }
  const undo = () => historyStep(true);
  const redo = () => historyStep(false);

  async function restoreVersion() {
    if (!st.layout || st.writing) return;
    const shown = st.layout;
    const versionId = await chooseBoardVersion(shown, 'Parc');
    if (!versionId || !st.alive) return;
    // The snapshot reviewed in the dialog must still be the one the operator is restoring over.
    if (st.layout.choiceToken !== shown.choiceToken) { ctx.toast('La disposition a changé ; rouvrez les versions.', { tone: 'warn' }); return; }
    await commitLayout('accueil.layout.restore', { versionId }, { recompute: true, message: 'Disposition restaurée ; choix précédent conservé dans les versions.' });
  }

  function patch(id, change, opts) {
    const items = st.layout.items.map((i) => (i.id === id ? { ...i, ...change } : i));
    return save(items, opts);
  }

  async function remove(id) {
    const it = itemOf(id);
    if (!it) return;
    const title = cardTitle(id);
    if (!await save(st.layout.items.filter((i) => i.id !== id), { recompute: false, message: `Widget « ${title} » retiré.` })) return;
    collections.cancelWidget(id);
    // The undo stack is filled outside edit mode too: the toast offers the step itself instead of pointing to the bar.
    // The action is bound to this removal: a later change on top of the stack must not be reverted in its place.
    const step = st.undo.at(-1);
    const undoThis = () => {
      if (!st.alive) return;
      if (st.undo.at(-1) !== step) { ctx.toast('Une autre modification a suivi ; utilisez « Annuler » dans « Modifier l’accueil ».', { tone: 'warn' }); return; }
      undo();
    };
    ctx.toast(`Widget « ${title} » retiré du tableau.`, { tone: 'info', life: 6000, actions: [{ label: 'Annuler', icon: 'undo', run: undoThis }] });
  }

  /** Moves an item within its section; delta -1 / +1. */
  async function move(id, delta, { focus = true } = {}) {
    const items = [...st.layout.items];
    const at = items.findIndex((i) => i.id === id);
    if (at < 0) return;
    const group = items[at].group;
    let to = at + delta;
    while (to >= 0 && to < items.length && items[to].group !== group) to += delta;
    if (to < 0 || to >= items.length) { announce('Déjà au bout de la section.'); return; }
    const before = rects();
    const [it] = items.splice(at, 1);
    items.splice(to, 0, it);
    if (!await save(items, { message: `${cardTitle(id)}${NBSP}: position ${positionInGroup(items, id)}.` })) return;
    flip(before);
    if (focus) host.querySelector(`[data-item="${CSS.escape(id)}"] [data-fw-grip]`)?.focus({ preventScroll: false });
  }

  const positionInGroup = (items, id) => {
    const it = items.find((i) => i.id === id);
    const list = items.filter((i) => i.group === it.group);
    return `${list.indexOf(it) + 1} sur ${list.length}`;
  };

  const cardTitle = (id) => {
    const it = itemOf(id);
    if (!it) return 'Widget';
    return it.title ?? st.board?.entries?.[entryKey(it)]?.title ?? it.key;
  };

  // FLIP: cards glide from their old place to the new one (transform only).
  function rects() {
    const map = new Map();
    groupsEl.querySelectorAll('.card.fw[data-item]').forEach((el) => map.set(el.dataset.item, el.getBoundingClientRect()));
    return map;
  }

  function flip(before) {
    if (motionReduced()) return;
    groupsEl.querySelectorAll('.card.fw[data-item]').forEach((el) => {
      const r0 = before.get(el.dataset.item);
      if (!r0) return;
      const r1 = el.getBoundingClientRect();
      const dx = r0.left - r1.left;
      const dy = r0.top - r1.top;
      if (!dx && !dy) return;
      el.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: 'none' }], { duration: 420, easing: 'cubic-bezier(.2,.9,.25,1)' });
    });
  }

  async function rename(id) {
    const it = itemOf(id);
    if (!it) return;
    const entry = st.board?.entries?.[entryKey(it)];
    const original = entry && it.title ? null : entry?.title;
    const form = document.createElement('form');
    form.dataset.page = 'accueil';
    form.className = 'acc-surface k-form fw-rename';
    form.innerHTML = field({
      name: 'title', label: 'Titre affiché', value: it.title ?? entry?.title ?? '', maxLength: 80,
      hint: `Vide${NBSP}: titre d’origine${original ? ` («${NBSP}${original}${NBSP}»)` : ''}. 80 caractères au plus.`,
    });
    let text = null;
    const d = openDialog({
      title: 'Renommer le widget', icon: 'edit', size: 'sm', body: form,
      actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'ok', label: 'Renommer', primary: true }],
    });
    const f = createForm(form, { onSubmit: (values) => { text = String(values.title ?? '').trim(); d.close('ok'); } });
    form.querySelector('input')?.select();
    const r = await d.result;
    if (r === 'ok' && text === null && f.validate()) text = String(f.values().title ?? '').trim();
    f.destroy?.();
    if (r !== 'ok' || text === null) return;
    patch(id, { title: text || null }, { message: 'Titre du widget changé.' });
  }

  async function editQuery(item) {
    try {
      // A layout key identifies a widget, not necessarily its saved query. Never open an unrelated draft.
      const recipeId = item.queryBinding?.recipeId
        ?? (await ctx.call('requetes.widget.list')).find(w => w.id === item.key && w.board === 'fleet')?.recipeId;
      if (!st.alive) return;
      if (!recipeId) { ctx.toast('Le lien vers cette requête est absent. Retrouvez-la dans l’Atelier de requêtes.', { tone: 'warn' }); return; }
      ctx.navigate('requetes', { recette: recipeId, onglet: 'creer' });
    } catch (err) { if (st.alive) ctx.toast(reported(err), { tone: 'warn' }); }
  }

  async function editSection(name = null, widgetId = null) {
    if (!st.layout?.items.length || st.writing) return;
    const token = st.layout.choiceToken;
    const groups = groupsOf(st.layout.items);
    const form = document.createElement('form'); form.className = 'k-form';
    form.innerHTML = field({ name: 'section', label: 'Nom de la section', value: name ?? '', required: true, maxLength: 80 })
      + (name === null && !widgetId ? field({ name: 'widget', label: 'Premier widget', type: 'select', required: true,
        value: st.layout.items[0].id, options: st.layout.items.map(item => ({ value: item.id, label: `${cardTitle(item.id)} · ${sectionName(item)}` })),
        hint: 'Ce widget sera déplacé dans la nouvelle section. Vous pourrez ensuite en ajouter d’autres.' }) : '');
    const d = openDialog({ title: name === null ? 'Nouvelle section' : 'Renommer la section', icon: 'layers', size: 'sm', body: form,
      actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'save', label: name === null ? 'Créer la section' : 'Renommer', primary: true }] });
    const f = createForm(form, { rules: { section: value => !String(value).trim() ? 'Saisissez un nom.'
      : groups.some(group => group.name === String(value).trim() && group.name !== name) ? 'Cette section existe déjà.' : null }, onSubmit: () => d.close('save') });
    d.el.querySelector('[data-id="save"]').addEventListener('click', event => { if (!f.validate()) event.stopPropagation(); });
    form.querySelector('input')?.select();
    const result = await d.result; const values = f.values(); f.destroy();
    if (result !== 'save' || !st.alive) return;
    if (token !== st.layout.choiceToken) { ctx.toast('La disposition a changé ; rouvrez la section.', { tone: 'warn' }); return; }
    const next = String(values.section).trim();
    const items = name === null ? placeWidget(st.layout.items, widgetId ?? values.widget, next) : renameSection(st.layout.items, name, next);
    await save(items, { message: name === null ? `Section « ${next} » créée.` : `Section renommée « ${next} ».` });
  }

  async function relocate(id, section, beforeId = null) {
    const before = rects();
    if (await save(placeWidget(st.layout.items, id, section, beforeId), { message: `${cardTitle(id)} déplacé dans « ${section} ».` })) flip(before);
  }

  function sectionMenu(button) {
    if (!st.layout || st.writing || transferring) return;
    const name = button.closest('[data-group]')?.dataset.group;
    const groups = groupsOf(st.layout.items); const at = groups.findIndex(group => group.name === name);
    if (at < 0) return;
    const group = groups[at]; const hidden = group.items.every(item => item.hidden);
    openMenu(button, [
      { label: 'Renommer la section…', icon: 'edit', run: () => editSection(name) },
      { label: 'Monter la section', icon: 'arrowUp', disabled: at === 0, reason: 'Première section.', run: () => save(moveSection(st.layout.items, name, -1), { message: `Section « ${name} » déplacée.` }) },
      { label: 'Descendre la section', icon: 'arrowDown', disabled: at === groups.length - 1, reason: 'Dernière section.', run: () => save(moveSection(st.layout.items, name, 1), { message: `Section « ${name} » déplacée.` }) },
      '-', { label: hidden ? 'Afficher la section' : 'Masquer la section', icon: hidden ? 'eye' : 'eyeOff', run: () => save(st.layout.items.map(item => sectionName(item) === name ? { ...item, hidden: !hidden } : item), { message: `Section « ${name} » ${hidden ? 'affichée' : 'masquée'}.` }) },
    ], { label: `Modifier la section ${name}` });
  }

  function cardMenu(button) {
    if (!st.layout || st.writing || transferring) return;
    const card = button.closest('[data-item]');
    const id = card?.dataset.item;
    const it = itemOf(id);
    if (!it) return;
    const entry = st.board?.entries?.[entryKey(it)];
    const kind = entry?.kind ?? 'value';
    const current = entry ? visualFor(entry, it) : it.visual;
    const visuals = (VISUALS[kind] ?? ['Kpi']).map((v) => ({
      label: VISUAL_LABEL[v] ?? v, radio: `v-${id}`, checked: v === current,
      run: () => { if (v !== current) patch(id, { visual: v }, { message: `Représentation : ${VISUAL_LABEL[v]}.` }); },
    }));
    const sizes = ['S', 'M', 'L'].map((s) => ({
      label: SIZE_LABEL[s], radio: `s-${id}`, checked: it.size === s,
      run: () => { if (s !== it.size) patch(id, { size: s }, { message: `Taille : ${SIZE_LABEL[s]}.` }); },
    }));
    const heights = [['', 'Automatique'], ['S', 'Compacte'], ['M', 'Moyenne'], ['L', 'Grande']].map(([height, label]) => ({
      label, radio: `h-${id}`, checked: (it.height ?? '') === height,
      run: () => patch(id, { height: height || null }, { message: `Hauteur${NBSP}: ${label}.` }),
    }));
    const items = [];
    if (it.source === 'query') items.push({ label: 'Modifier la requête…', icon: 'edit', run: () => editQuery(it) });
    if (entry?.targetsKey && (entry.targets ?? 0) > 0) {
      items.push({ label: `Voir les ${plural(entry.targets, 'poste', 'postes')}`, icon: 'monitor', run: () => o.onTargets(entry.targetsKey, entry.title) });
    }
    items.push({ label: 'Actualiser ce widget', icon: 'refresh', hint: 'confirmation', disabled: it.paused, reason: 'Widget suspendu.', run: () => collections.collect(it, 'refresh') });
    if (it.source === 'probe') items.push({ label: 'Contrat de la sonde…', icon: 'file', run: () => o.onTool(`probe:${it.key}`) });
    if (items.length) items.push('-');
    items.push({ label: 'Représentation', icon: 'columns', items: visuals }, { label: 'Largeur', icon: 'sliders', items: sizes },
      { label: 'Hauteur', icon: 'sliders', items: heights }, '-');
    items.push({ label: 'Déplacer vers une section', icon: 'layers', items: [
      ...groupsOf(st.layout.items).map(group => ({ label: group.name, disabled: group.name === sectionName(it), reason: 'Section actuelle.', run: () => relocate(id, group.name) })),
      '-', { label: 'Nouvelle section…', icon: 'plus', run: () => editSection(null, id) },
    ] });
    items.push({ label: 'Renommer…', icon: 'edit', run: () => rename(id) });
    items.push({ label: it.hidden ? 'Afficher le widget' : 'Masquer le widget', icon: it.hidden ? 'eye' : 'eyeOff', run: () => patch(id, { hidden: !it.hidden }, { message: it.hidden ? 'Widget affiché.' : 'Widget masqué. Retrouvez-le dans « Modifier l’accueil ».' }) });
    if (it.source === 'probe' || it.source === 'query') {
      items.push({
        label: it.paused ? 'Reprendre le relevé' : 'Mettre en pause', icon: it.paused ? 'play' : 'pause', hint: 'sonde',
        run: async () => {
          const saved = await patch(id, { paused: !it.paused }, { message: it.paused ? 'Relevé repris.' : 'Widget en pause.' });
          if (saved && it.paused) void collections.collect(itemOf(id), 'resume');
          else if (saved) collections.cancelWidget(id);
        },
      });
    }
    items.push(
      { label: 'Monter', icon: 'arrowUp', kbd: 'Alt ↑', run: () => move(id, -1, { focus: false }) },
      { label: 'Descendre', icon: 'arrowDown', kbd: 'Alt ↓', run: () => move(id, 1, { focus: false }) },
      '-',
      { label: 'Retirer du tableau', icon: 'trash', danger: true, run: () => remove(id) },
    );
    openMenu(button, items, { label: `Modifier le widget ${entry?.title ?? it.key}` });
  }

  async function transferLayout(kind) {
    if (!st.layout?.valid || st.writing || transferring) return;
    const choice = st.layout.choiceToken;
    transferring = true; syncBar();
    try {
      if (kind === 'export') {
        const result = await ctx.call('shell.board.export', { board: 'Fleet', expectedChoiceToken: choice });
        if (st.alive) ctx.toast(result.summary, { tone: result.saved ? 'ok' : 'info' });
      } else {
        const request = await transfer.prepare(kind, 'Fleet', choice);
        if (request && st.alive) await commitLayout(request.operation, request.args, { recompute: true, message: 'Disposition enregistrée ; version précédente conservée.' });
      }
    } catch (err) { if (st.alive) ctx.toast(reported(err), { tone: 'warn' }); }
    finally { transferring = false; syncBar(); }
  }

  function presetItems() {
    const run = async (preset) => {
      if (await commitLayout('accueil.layout.reset', preset ? { preset: preset.id } : {}, { recompute: true }))
        ctx.toast(preset ? `Disposition « ${preset.label} » appliquée : ses widgets passent en tête.` : 'Disposition livrée rétablie.', { tone: 'ok', life: 3000 });
    };
    const presets = [
      { id: 'support', label: 'Assistance', hint: 'points, santé, présence' },
      { id: 'inventory', label: 'Inventaire', hint: 'comptes, systèmes, modèles' },
      { id: 'health', label: 'Santé', hint: 'santé, disques, redémarrages' },
    ];
    return [
      { heading: 'Dispositions prédéfinies' },
      ...presets.map((p) => ({ label: p.label, hint: p.hint, icon: 'layers', run: () => run(p) })),
      '-',
      { label: 'Par défaut (équipe ou livré)', icon: 'undo', run: () => transferLayout('default') },
      { label: 'Rétablir la disposition livrée', icon: 'undo', disabled: !st.layout?.customized, reason: 'La disposition livrée est déjà affichée.', run: () => run(null) },
    ];
  }

  function setEditing(on) {
    st.editing = Boolean(on);
    host.querySelector('.fw-edit-note').hidden = !st.editing;
    host.classList.toggle('editing', st.editing);
    if (st.board && st.layout) paintAll();
    syncUndo();
    announce(st.editing ? 'Mode personnalisation : poignées de déplacement affichées.' : 'Personnalisation terminée.');
  }

  // ---------- Dragging (pointer) ----------

  let drag = null;

  function onPointerDown(e) {
    const grip = e.target instanceof Element ? e.target.closest('[data-fw-grip]') : null;
    if (!grip || e.button !== 0 || !st.editing || st.writing) return;
    const card = grip.closest('.card.fw[data-item]');
    if (!card) return;
    e.preventDefault();
    // preventDefault also cancels the focus move: the grip takes it, so Alt + arrows follow the click.
    grip.focus({ preventScroll: true });
    const grid = card.parentElement;
    const r = card.getBoundingClientRect();
    drag = { card, grid, grip, id: card.dataset.item, choiceToken: st.layout.choiceToken, startX: e.clientX, startY: e.clientY, dx: r.left - e.clientX, dy: r.top - e.clientY, moved: false, pointer: e.pointerId };
    grip.setPointerCapture(e.pointerId);
    grip.addEventListener('pointermove', onPointerMove);
    grip.addEventListener('pointerup', onPointerUp, { once: true });
    grip.addEventListener('pointercancel', onPointerUp, { once: true });
  }

  function onPointerMove(e) {
    if (!drag) return;
    const tx = e.clientX - drag.startX;
    const ty = e.clientY - drag.startY;
    if (!drag.moved && Math.hypot(tx, ty) < 6) return;
    if (!drag.moved) { drag.moved = true; drag.card.classList.add('dragging'); host.classList.add('is-dragging'); }
    drag.card.style.setProperty('--dx', `${tx}px`);
    drag.card.style.setProperty('--dy', `${ty}px`);
    // A section header is also a drop target: moving its last card out never traps another card there.
    const section = [...groupsEl.querySelectorAll(':scope > .fw-group')].find(el => {
      const r = el.getBoundingClientRect(); return e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom;
    });
    const targetGrid = section?.querySelector('.fw-grid');
    if (!targetGrid) return;
    const under = [...targetGrid.querySelectorAll(':scope > .card.fw[data-item]')].find((c) => {
      if (c === drag.card) return false;
      const r = c.getBoundingClientRect();
      return e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom;
    });
    if (!under && targetGrid === drag.grid) return;
    const before = rects();
    const cards = [...targetGrid.children];
    const from = cards.indexOf(drag.card);
    const to = cards.indexOf(under);
    if (!under) targetGrid.append(drag.card);
    else if (targetGrid === drag.grid && from < to) under.after(drag.card);
    else under.before(drag.card);
    drag.grid = targetGrid;
    // The dragged card keeps following the pointer from its new place.
    const r0 = before.get(drag.id);
    const r1 = drag.card.getBoundingClientRect();
    drag.startX += r1.left - r0.left;
    drag.startY += r1.top - r0.top;
    drag.card.style.setProperty('--dx', `${e.clientX - drag.startX}px`);
    drag.card.style.setProperty('--dy', `${e.clientY - drag.startY}px`);
    flipExcept(before, drag.card);
  }

  function flipExcept(before, skip) {
    if (motionReduced()) return;
    groupsEl.querySelectorAll('.card.fw[data-item]').forEach((el) => {
      if (el === skip) return;
      const r0 = before.get(el.dataset.item);
      const r1 = el.getBoundingClientRect();
      if (!r0) return;
      const dx = r0.left - r1.left;
      const dy = r0.top - r1.top;
      if (dx || dy) el.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: 'none' }], { duration: 320, easing: 'cubic-bezier(.2,.9,.25,1)' });
    });
  }

  function clearDrag() {
    const d = drag;
    drag = null;
    if (!d) return null;
    d.grip.removeEventListener('pointermove', onPointerMove);
    d.grip.removeEventListener('pointerup', onPointerUp);
    d.grip.removeEventListener('pointercancel', onPointerUp);
    if (d.grip.hasPointerCapture?.(d.pointer)) d.grip.releasePointerCapture(d.pointer);
    d.card.classList.remove('dragging');
    host.classList.remove('is-dragging');
    d.card.style.removeProperty('--dx');
    d.card.style.removeProperty('--dy');
    return d;
  }

  function onPointerUp(e) {
    const d = clearDrag();
    if (!d) return;
    if (e.type === 'pointercancel' || d.choiceToken !== st.layout.choiceToken) { paintAll(); return; }
    if (!d.moved) return;
    const items = [...groupsEl.querySelectorAll(':scope > .fw-group')].flatMap(section =>
      [...section.querySelectorAll('.card.fw[data-item]')].map(card => ({ ...itemOf(card.dataset.item), group: section.dataset.group })));
    if (items.length !== st.layout.items.length || new Set(items.map(item => item.id)).size !== items.length) { paintAll(); return; }
    save(items, { message: `${cardTitle(d.id)} déplacé dans « ${sectionName(items.find(item => item.id === d.id))} ».` });
  }

  // ---------- Events ----------

  host.addEventListener('pointerdown', onPointerDown);
  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    if (t.closest('[data-fw-grip]')) return;
    const targets = t.closest('[data-targets]');
    if (targets) { o.onTargets(targets.dataset.targets, targets.dataset.targetsLabel ?? ''); return; }
    const collect = t.closest('[data-fw-collect]');
    if (collect) { const item = itemOf(collect.dataset.fwCollect); if (item && !collect.disabled) void collections.collect(item, 'refresh'); return; }
    const action = t.closest('[data-fw-action]');
    if (action) {
      const key = action.closest('[data-entry]')?.dataset.entry;
      o.onAction(action.dataset.fwAction, key ? st.board?.entries?.[key] : null);
      return;
    }
    const menu = t.closest('[data-fw-menu]');
    if (menu) { cardMenu(menu); return; }
    const section = t.closest('[data-fw-section]');
    if (section) { sectionMenu(section); return; }
    if (t.closest('[data-fw-retry]')) { load(); return; }
    const tool = t.closest('[data-fw-tool]');
    if (tool) o.onTool(tool.dataset.fwTool);
  });
  host.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && !e.altKey && e.target instanceof Element && !e.target.closest('input,textarea,[contenteditable="true"]')) {
      if (e.key.toLowerCase() === 'z') { e.preventDefault(); if (e.shiftKey) redo(); else undo(); return; }
      if (e.key.toLowerCase() === 'y') { e.preventDefault(); redo(); return; }
    }
    const grip = e.target instanceof Element ? e.target.closest('[data-fw-grip]') : null;
    const card = e.target instanceof Element ? e.target.closest('.card.fw[data-item]') : null;
    if (card && e.key === 'F5') { e.preventDefault(); e.stopPropagation(); const item = itemOf(card.dataset.item); if (item) void collections.collect(item, 'refresh'); return; }
    if (!card || !e.altKey || e.ctrlKey || e.metaKey) return;
    const delta = { ArrowUp: -1, ArrowLeft: -1, ArrowDown: 1, ArrowRight: 1 }[e.key];
    if (!delta) return;
    e.preventDefault();
    if (!st.editing) setEditing(true);
    move(card.dataset.item, delta, { focus: Boolean(grip) });
  });

  return {
    load,
    board: () => st.board,
    layout: () => st.layout,
    editing: () => st.editing,
    setEditing,
    /** Adds widgets at the end of their section (catalog). */
    async add(list) {
      if (!st.layout) return;
      const previousIds = new Set(st.layout.items.map(item => item.id));
      const items = [...st.layout.items];
      for (const w of list) {
        const at = items.map((i) => i.group).lastIndexOf(w.group);
        const item = { id: '', source: w.source, key: w.key, visual: w.visual, size: w.size, title: null, paused: false, group: w.group, ...(w.queryBinding ? { queryBinding: w.queryBinding } : {}) };
        if (at >= 0) items.splice(at + 1, 0, item); else items.push(item);
      }
      const saved = await save(items, { recompute: true, message: `${plural(list.length, 'widget ajouté', 'widgets ajoutés')}.` });
      if (saved && st.alive) for (const item of saved.items.filter(item => !previousIds.has(item.id))) void collections.collect(item, 'add');
    },
    has: (source, key) => Boolean(st.layout?.items.some((i) => i.source === source && i.key === key)),
    count: () => st.layout?.items.length ?? 0,
    max: () => st.layout?.max ?? 64,
    showLastView,
    loading: () => st.loading,
    /** Commands of the bar computed again (working OU changed: « Ouvrir les postes dans Rechercher »). */
    refreshTools: syncBar,
    destroy() {
      st.alive = false;
      clearDrag();
      collections.destroy();
      transfer.destroy();
      stopReveal();
      stopBarReveal();
      sinceTimer?.();
      bar.destroy();
    },
  };
}
