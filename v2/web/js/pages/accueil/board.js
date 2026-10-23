// Accueil: fleet board of the working OU (Domenia 1 « Tableau de bord du parc »): widgets grouped by section, every
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

const SIZE_LABEL = { S: 'Compacte', M: 'Moyenne', L: 'Large' };
const VISUAL_LABEL = {
  Kpi: 'Chiffre clé', Gauge: 'Jauge', Pie: 'Anneau', Bar: 'Barres', Column: 'Histogramme', Line: 'Courbe', Text: 'Liste',
  List: 'Liste de points', HealthSummary: 'Score et points', Health: 'Score',
};
const VISUALS = {
  value: ['Kpi', 'Text'], distribution: ['Pie', 'Bar', 'Column', 'Text', 'Kpi'], series: ['Column', 'Bar', 'Text', 'Kpi'],
  timeline: ['Line', 'Column', 'Text'], list: ['List'], health: ['HealthSummary', 'Health', 'Kpi'],
};
const UNDO_MAX = 20;

/** Key of the board entry of a layout item (builtin key, « probe:<id> », « query:<id> »). */
export const entryKey = (item) => (item.source === 'probe' ? `probe:${item.key}` : item.source === 'query' ? `query:${item.key}` : item.key);
const wire = (i) => ({ id: i.id || null, source: i.source, key: i.key, visual: i.visual, size: i.size, title: i.title ?? null, paused: Boolean(i.paused) });

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
    board: null, layout: null, editing: false, undo: [], busy: false, alive: true, token: 0, saving: Promise.resolve(),
    loading: false, since: null, error: null, lastView: null,
  };
  const sigs = new Map(); // item id → signature of what its card shows (unchanged cards are left alone)
  let stopReveal = () => {};
  let seq = 0;
  let sinceTimer = null;

  host.innerHTML = `<div class="fw-bar reveal">
      <div class="fw-pop" aria-live="polite">${skStack('sk-line w55', 'sk-line w40')}</div>
      <div class="fw-tools"></div>
      <p class="fw-edit-note" hidden>${glyph('grip')}<span>Glissez la poignée d’un widget pour le déplacer dans sa section (ou Alt + flèches au clavier) ; son menu change la taille, la représentation, le titre ou le retire. Chaque changement est mémorisé dans les préférences locales.</span></p>
    </div>
    <div class="fw-groups" aria-busy="true">${skeletonGroups()}</div>`;
  const groupsEl = host.querySelector('.fw-groups');
  const popEl = host.querySelector('.fw-pop');

  // Commands of the board (KIT § 4.6): one Tab stop, arrows between the commands, what does not fit goes into « Plus ». No
  // primary command here: the primary action of the screen is « Tout actualiser » of the header. Everything is local
  // (calculation from the local base, layout, panels): no network command in this bar.
  function toolItems() {
    return [
      { id: 'recompute', label: st.loading ? 'Calcul en cours…' : 'Recalculer la vue', icon: 'refresh', pinned: true, disabled: st.loading,
        reason: `Calcul en cours${NBSP}: la vue se met à jour depuis la base locale.`, run: () => load({ quiet: false }) },
      { id: 'edit', label: st.editing ? 'Terminer' : 'Personnaliser', icon: 'sliders', pinned: true, run: () => setEditing(!st.editing) },
      ...(st.editing && st.undo.length ? [{ id: 'undo', label: 'Annuler', icon: 'undo', pinned: true, run: () => undo() }] : []),
      { id: 'catalog', label: 'Ajouter un widget', icon: 'plus', run: () => o.onTool('catalog') },
      { id: 'presets', label: 'Dispositions', icon: 'layers', items: presetItems() },
      { id: 'search', label: 'Ouvrir les postes dans Rechercher', icon: 'search', disabled: !o.onOpenSearch?.(true),
        reason: `Choisissez une OU de travail${NBSP}: Rechercher ne s’ouvre jamais sur tout le domaine.`, run: () => o.onOpenSearch?.(false) },
      { id: 'explain', label: 'Comprendre le score', icon: 'gauge', run: () => o.onTool('explain') },
      { id: 'health', label: 'Règles de santé', icon: 'shield', run: () => o.onTool('health') },
      { id: 'analysis', label: 'Analyse', icon: 'split', run: () => o.onTool('analysis') },
      { id: 'provenance', label: 'Provenance', icon: 'history', run: () => o.onTool('provenance') },
    ];
  }
  const bar = createCommandBar(host.querySelector('.fw-tools'), { label: 'Outils du tableau du parc', size: 'sm', items: toolItems(), moreLabel: 'Plus d’outils du tableau' });
  const syncBar = () => { if (st.alive) bar.setItems(toolItems()); };

  function skeletonGroups() {
    const card = (size) => `<article class="card fw size-${size}">${skStack('sk-line w40', 'sk-title w55', 'sk-line w85')}</article>`;
    return `<section class="fw-skeleton"><h3 class="fw-group-title">${sk('sk-line w25')}</h3><div class="fw-grid">${['S', 'S', 'S', 'S', 'M', 'M', 'M'].map(card).join('')}</div></section>`;
  }

  // ---------- Loading ----------

  async function load({ quiet = true, periodic = false } = {}) {
    if (periodic && st.loading) return;
    const my = ++st.token;
    setLoading(true);
    o.onState?.('running');
    try {
      const [board, layout] = await Promise.all([ctx.call('accueil.board'), ctx.call('accueil.layout')]);
      if (!st.alive || my !== st.token) return;
      st.board = board;
      st.layout = layout;
      st.error = null;
      paintAll();
      o.onComputed?.(board, layout);
      o.onState?.('ready', board);
      if (!quiet) ctx.toast('Tableau du parc recalculé depuis la base locale, sans lecture réseau.', { tone: 'ok', life: 2400 });
    } catch (err) {
      if (!st.alive || my !== st.token) return;
      st.error = err;
      paintError(err);
      o.onState?.('error', null, err);
      if (periodic) throw err;
    } finally {
      if (my === st.token && st.alive) setLoading(false);
    }
  }

  // « Calcul en cours depuis » (improvement of ACC-032): the bar says since when, the cards stay readable underneath.
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
    const order = [];
    const map = new Map();
    for (const item of items) {
      const g = item.group || 'Autres widgets';
      if (!map.has(g)) { map.set(g, []); order.push(g); }
      map.get(g).push(item);
    }
    return order.map((g) => ({ name: g, items: map.get(g) }));
  }

  /** Signature of what a card shows: an unchanged card is never repainted (no flicker, no counter from 0). */
  function signature(item, entry) {
    const b = st.board;
    const wide = entry && (entry.kind === 'health' || entry.kind === 'list' || entry.kind === 'value');
    return JSON.stringify([item, entry ?? null, wide ? [b.health, b.population] : null]);
  }

  function cardClass(item, entry) {
    if (!entry) return `card fw size-${item.size}`;
    const v = visualFor(entry, item);
    return [`card fw spot size-${item.size} v-${v.toLowerCase()} k-${entry.kind}`, entry.tone === 'off' || !entry.measured ? 'is-dim' : '', item.paused ? 'is-paused' : ''].filter(Boolean).join(' ');
  }

  function cardInner(item, entry, uid) {
    const b = st.board;
    if (!entry) {
      return `${head(item, { title: item.title ?? item.key, kind: 'value' })}<div class="fw-body"><div class="fw-empty">${glyph('info')}<span>Widget non calculé pour ce périmètre.</span></div></div>`;
    }
    const v = visualFor(entry, item);
    let body;
    try {
      body = widgetBody(entry, item, b, uid);
    } catch (err) {
      console.error(`Widget « ${item.key} » : affichage impossible`, err, entry);
      body = `<div class="fw-empty">${glyph('alert')}<span>Données inattendues${NBSP}: ce widget ne peut pas s’afficher. Les autres widgets ne sont pas concernés.</span></div>`;
    }
    const action = entry.action
      // Never a primary button in a card (KIT § 2.6: the primary action of the screen is « Tout actualiser »); the BitLocker
      // read goes to the directory and wears the network mark of the kit.
      ? `<button class="btn sm${entry.measured ? ' ghost' : ' subtle'}${entry.action.id === 'bitlocker' ? ' is-net' : ''}" type="button" data-fw-action="${esc(entry.action.id)}" data-tip="${esc(entry.action.id === 'bitlocker' ? `${entry.action.tip} · lecture réseau` : entry.action.tip)}">${glyph(entry.action.id === 'bitlocker' ? 'lock' : 'refresh')}${esc(entry.action.label)}${entry.action.id === 'bitlocker' ? '<span class="k-cmd-net" aria-hidden="true"></span><span class="visually-hidden">, lecture réseau</span>' : ''}</button>` : '';
    const open = entry.targetsKey && (entry.targets ?? 0) > 0 && v !== 'Kpi'
      ? `<button class="btn sm ghost fw-see" type="button" data-targets="${esc(entry.targetsKey)}" data-targets-label="${esc(entry.title)}">${glyph('monitor')}${plural(entry.targets, 'poste', 'postes')}</button>` : '';
    return `<span class="fw-accent" aria-hidden="true"></span>${head(item, entry, uid)}<div class="fw-body">${body}</div>`
      + `<footer class="fw-foot">${v === 'HealthSummary' ? '<span class="fw-detail"></span>' : `<p class="fw-detail">${esc(entry.detail)}</p>`}${action || open ? `<div class="fw-foot-act">${action}${open}</div>` : ''}</footer>`;
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
    const chips = [];
    if (item.paused) chips.push('<span class="k-pill sm warn" data-tip="Non relevé à la prochaine actualisation ; la dernière valeur reste affichée">En pause</span>');
    else if (entry.tone === 'off' && entry.measured) chips.push('<span class="k-pill sm off" data-tip="Mesure ancienne ou couverture partielle">Ancien</span>');
    if (entry.subtitle && entry.measured) chips.push(`<span class="fw-cov" data-tip="${esc(entry.subtitle)}">${esc(entry.subtitle)}</span>`);
    return `<header class="fw-head">
        <button class="fw-grip" type="button" data-fw-grip aria-label="Déplacer «${NBSP}${esc(entry.title)}${NBSP}» (Alt + flèches)" data-tip="Glisser pour déplacer · Alt + flèches">${glyph('grip')}</button>
        <span class="fw-ico" aria-hidden="true">${glyph(widgetGlyph(entry, item))}</span>
        <div class="fw-titles"><h4${uid ? ` id="${uid}-t"` : ''}>${esc(entry.title)}</h4>${chips.length ? `<div class="fw-chips">${chips.join('')}</div>` : ''}</div>
        <button class="btn ghost icon sm fw-menu" type="button" data-fw-menu aria-haspopup="menu" aria-label="Options du widget ${esc(entry.title)}" data-tip="Options du widget">${glyph('more')}</button>
      </header>`;
  }

  /**
   * Fills the rows of a section (« remplir la rangée automatiquement »): items are placed in order on a 12-column grid, then the
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
    const b = st.board;
    const items = st.layout?.items ?? [];
    popEl.innerHTML = populationLine(b);
    paint(popEl);
    paintSince();
    groupsEl.querySelector('.fw-last')?.remove();
    groupsEl.querySelectorAll(':scope > .fw-skeleton, :scope > .fw-error, :scope > .fw-empty-board').forEach((x) => x.remove());
    if (!items.length) {
      sigs.clear();
      groupsEl.innerHTML = `<div class="card fw-error fw-empty-board reveal">${glyph('layers')}<div><h3>Aucun widget</h3><p>La disposition est vide${NBSP}: ajoutez des widgets du catalogue ou rétablissez la disposition livrée.</p></div>`
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
        sec.innerHTML = `<h3 class="fw-group-title"><span></span><span class="fw-group-count"></span></h3><div class="fw-hints"></div><div class="fw-grid"></div>`;
      }
      if ((prev ? prev.nextElementSibling : groupsEl.firstElementChild) !== sec) {
        if (prev) prev.after(sec); else groupsEl.prepend(sec);
      }
      prev = sec;
      sec.dataset.i = String(gi);
      sec.setAttribute('aria-labelledby', `fwg-h-${gi}`);
      const title = sec.querySelector('.fw-group-title');
      title.id = `fwg-h-${gi}`;
      title.firstElementChild.textContent = g.name;
      title.lastElementChild.textContent = plural(g.items.length, 'widget', 'widgets');
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

  /** Saves a new layout. recompute: the board must be computed again (widget added, removed, paused). */
  async function save(items, { recompute = false, message = '', undoable = true } = {}) {
    if (!st.layout) return;
    const before = st.layout.items;
    if (undoable) {
      st.undo.push(before);
      if (st.undo.length > UNDO_MAX) st.undo.shift();
    }
    syncUndo();
    st.layout = { ...st.layout, items };
    if (!recompute) paintAll();
    const run = async () => {
      try {
        const saved = await ctx.call('accueil.layout.save', { items: items.map(wire) });
        if (!st.alive) return;
        st.layout = saved;
        if (recompute) await load(); else popEl.innerHTML = populationLine(st.board);
        if (message) announce(message);
      } catch (err) {
        if (!st.alive) return;
        st.layout = { ...st.layout, items: before };
        if (undoable) st.undo.pop();
        syncUndo();
        paintAll();
        ctx.toast(reported(err), { tone: 'alert' });
      }
    };
    st.saving = st.saving.then(run, run);
    return st.saving;
  }

  function syncUndo() {
    syncBar();
  }

  function undo() {
    const prev = st.undo.pop();
    if (!prev) return;
    const recompute = prev.length !== st.layout.items.length || prev.some((p) => !st.layout.items.some((i) => i.id === p.id && i.paused === p.paused));
    save(prev, { recompute, message: 'Dernière modification annulée.', undoable: false });
    ctx.toast('Dernière modification de la disposition annulée.', { tone: 'info', life: 2400 });
  }

  function patch(id, change, opts) {
    const items = st.layout.items.map((i) => (i.id === id ? { ...i, ...change } : i));
    return save(items, opts);
  }

  function remove(id) {
    const it = itemOf(id);
    if (!it) return;
    const title = cardTitle(id);
    save(st.layout.items.filter((i) => i.id !== id), { recompute: false, message: `Widget « ${title} » retiré.` });
    ctx.toast(`Widget « ${title} » retiré du tableau. « Annuler » le remet${st.editing ? '' : ' (mode Personnaliser)'}.`, { tone: 'info', life: 3600 });
  }

  /** Moves an item within its section; delta -1 / +1. */
  function move(id, delta, { focus = true } = {}) {
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
    save(items, { message: `${cardTitle(id)} : position ${positionInGroup(items, id)}.` });
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
    return st.board?.entries?.[entryKey(it)]?.title ?? it.title ?? it.key;
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

  function cardMenu(button) {
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
    const items = [];
    if (entry?.targetsKey && (entry.targets ?? 0) > 0) {
      items.push({ label: `Voir les ${plural(entry.targets, 'poste', 'postes')}`, icon: 'monitor', run: () => o.onTargets(entry.targetsKey, entry.title) });
    }
    if (entry?.action) items.push({ label: entry.action.label, icon: 'refresh', hint: entry.action.id === 'bitlocker' ? 'réseau' : 'confirmation', run: () => o.onAction(entry.action.id, entry) });
    if (it.source === 'probe') items.push({ label: 'Contrat de la sonde…', icon: 'file', run: () => o.onTool(`probe:${it.key}`) });
    if (items.length) items.push('-');
    items.push({ heading: 'Représentation' }, ...visuals, '-', { heading: 'Taille' }, ...sizes, '-');
    items.push({ label: 'Renommer…', icon: 'edit', run: () => rename(id) });
    if (it.source === 'probe') {
      items.push({
        label: it.paused ? 'Reprendre le relevé' : 'Mettre en pause', icon: it.paused ? 'play' : 'pause', hint: 'sonde',
        run: () => patch(id, { paused: !it.paused }, { message: it.paused ? 'Relevé repris.' : 'Widget en pause.' }),
      });
    }
    items.push(
      { label: 'Monter', icon: 'arrowUp', kbd: 'Alt ↑', run: () => move(id, -1, { focus: false }) },
      { label: 'Descendre', icon: 'arrowDown', kbd: 'Alt ↓', run: () => move(id, 1, { focus: false }) },
      '-',
      { label: 'Retirer du tableau', icon: 'trash', danger: true, run: () => remove(id) },
    );
    openMenu(button, items, { label: `Options de ${entry?.title ?? it.key}` });
  }

  function presetItems() {
    const run = async (preset) => {
      try {
        const before = st.layout?.items;
        const layout = await ctx.call('accueil.layout.reset', preset ? { preset: preset.id } : {});
        if (!st.alive) return;
        if (before) { st.undo.push(before); if (st.undo.length > UNDO_MAX) st.undo.shift(); }
        st.layout = layout;
        syncUndo();
        await load();
        ctx.toast(preset ? `Disposition « ${preset.label} » appliquée : ses widgets passent en tête.` : 'Disposition livrée rétablie.', { tone: 'ok', life: 3000 });
      } catch (err) {
        ctx.toast(reported(err), { tone: 'alert' });
      }
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
      { label: 'Rétablir la disposition livrée', icon: 'undo', disabled: !st.layout?.customized, reason: 'La disposition livrée est déjà affichée.', run: () => run(null) },
    ];
  }

  function setEditing(on) {
    st.editing = Boolean(on);
    host.querySelector('.fw-edit-note').hidden = !st.editing;
    host.classList.toggle('editing', st.editing);
    syncUndo();
    announce(st.editing ? 'Mode personnalisation : poignées de déplacement affichées.' : 'Personnalisation terminée.');
  }

  // ---------- Dragging (pointer) ----------

  let drag = null;

  function onPointerDown(e) {
    const grip = e.target instanceof Element ? e.target.closest('[data-fw-grip]') : null;
    if (!grip || e.button !== 0 || !st.editing) return;
    const card = grip.closest('.card.fw[data-item]');
    if (!card) return;
    e.preventDefault();
    // preventDefault also cancels the focus move: the grip takes it, so Alt + arrows follow the click.
    grip.focus({ preventScroll: true });
    const grid = card.parentElement;
    const r = card.getBoundingClientRect();
    drag = { card, grid, id: card.dataset.item, startX: e.clientX, startY: e.clientY, dx: r.left - e.clientX, dy: r.top - e.clientY, moved: false, pointer: e.pointerId };
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
    // Target: the card of the same section under the pointer.
    const under = [...drag.grid.querySelectorAll(':scope > .card.fw[data-item]')].find((c) => {
      if (c === drag.card) return false;
      const r = c.getBoundingClientRect();
      return e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom;
    });
    if (!under) return;
    const before = rects();
    const cards = [...drag.grid.children];
    const from = cards.indexOf(drag.card);
    const to = cards.indexOf(under);
    if (from < to) under.after(drag.card); else under.before(drag.card);
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
    drag.grid.querySelectorAll(':scope > .card.fw[data-item]').forEach((el) => {
      if (el === skip) return;
      const r0 = before.get(el.dataset.item);
      const r1 = el.getBoundingClientRect();
      if (!r0) return;
      const dx = r0.left - r1.left;
      const dy = r0.top - r1.top;
      if (dx || dy) el.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: 'none' }], { duration: 320, easing: 'cubic-bezier(.2,.9,.25,1)' });
    });
  }

  function onPointerUp(e) {
    const d = drag;
    drag = null;
    if (!d) return;
    e.target.removeEventListener?.('pointermove', onPointerMove);
    d.card.classList.remove('dragging');
    host.classList.remove('is-dragging');
    d.card.style.removeProperty('--dx');
    d.card.style.removeProperty('--dy');
    if (!d.moved) return;
    // New order of this section; the other sections keep theirs.
    const ids = [...d.grid.querySelectorAll(':scope > .card.fw[data-item]')].map((c) => c.dataset.item);
    const group = itemOf(d.id)?.group;
    const queue = ids.map((id) => itemOf(id));
    const items = st.layout.items.map((i) => (i.group === group ? queue.shift() : i));
    if (items.every((i, n) => i.id === st.layout.items[n].id)) return;
    save(items, { message: `${cardTitle(d.id)} : position ${positionInGroup(items, d.id)}.` });
  }

  // ---------- Events ----------

  host.addEventListener('pointerdown', onPointerDown);
  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    if (t.closest('[data-fw-grip]')) return;
    const targets = t.closest('[data-targets]');
    if (targets) { o.onTargets(targets.dataset.targets, targets.dataset.targetsLabel ?? ''); return; }
    const action = t.closest('[data-fw-action]');
    if (action) {
      const key = action.closest('[data-entry]')?.dataset.entry;
      o.onAction(action.dataset.fwAction, key ? st.board?.entries?.[key] : null);
      return;
    }
    const menu = t.closest('[data-fw-menu]');
    if (menu) { cardMenu(menu); return; }
    if (t.closest('[data-fw-retry]')) { load(); return; }
    const tool = t.closest('[data-fw-tool]');
    if (tool) o.onTool(tool.dataset.fwTool);
  });
  host.addEventListener('keydown', (e) => {
    const grip = e.target instanceof Element ? e.target.closest('[data-fw-grip]') : null;
    const card = e.target instanceof Element ? e.target.closest('.card.fw[data-item]') : null;
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
      const items = [...st.layout.items];
      for (const w of list) {
        const at = items.map((i) => i.group).lastIndexOf(w.group);
        const item = { id: '', source: w.source, key: w.key, visual: w.visual, size: w.size, title: null, paused: false, group: w.group };
        if (at >= 0) items.splice(at + 1, 0, item); else items.push(item);
      }
      await save(items, { recompute: true, message: `${plural(list.length, 'widget ajouté', 'widgets ajoutés')}.` });
    },
    has: (source, key) => Boolean(st.layout?.items.some((i) => i.source === source && i.key === key)),
    count: () => st.layout?.items.length ?? 0,
    max: () => st.layout?.max ?? 64,
    showLastView,
    loading: () => st.loading,
    /** Commands of the bar computed again (working OU changed: « Ouvrir les postes dans Rechercher »). */
    refreshTools: syncBar,
    destroy() {
      st.alive = false;
      stopReveal();
      sinceTimer?.();
      bar.destroy();
    },
  };
}
