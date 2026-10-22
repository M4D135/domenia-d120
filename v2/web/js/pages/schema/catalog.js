// Catalog of the schema screen (SCH-001 to SCH-003): classes or attributes of the schema read in this session in a virtual
// grid (local filter on name and description, every match counted), and the detail of the chosen entry beside it, in a
// resizable master-detail split. Before the read, the same card shows what will be read and follows the read stage by stage.
import { createGrid } from '../../kit/grid.js';
import { createSplit } from '../../kit/split.js';
import { debounce, writeClipboard } from '../../kit/util.js';
import { applyVars, toast, announce } from '../../ui.js';
import { glyph, esc, int, count, NBSP, errText, categoryTone } from './model.js';
import { placeholder, skeleton, renderClass, renderAttribute } from './detail.js';

/** Rows asked at once: the whole catalog of a usual schema; beyond, the filter goes back to the engine. */
const LIST_LIMIT = 5000;
const DETAIL_DELAY_MS = 120;

const CLASS_COLUMNS = [
  { id: 'name', label: 'Classe', required: true, width: 220, mono: true },
  {
    id: 'nature', label: 'Catégorie', type: 'enum', width: 140,
    options: [
      { value: 'Structurelle', label: 'Structurelle', tone: 'info' }, { value: 'Auxiliaire', label: 'Auxiliaire', tone: 'ok' },
      { value: 'Abstraite', label: 'Abstraite', tone: 'off' }, { value: 'Classe 88', label: 'Classe 88', tone: 'off' },
      { value: 'Obsolète', label: 'Obsolète', tone: 'alert' }, { value: 'Inconnue', label: 'Inconnue', tone: 'off' },
    ],
  },
  { id: 'subClassOf', label: 'Hérite de', width: 170, mono: true },
  { id: 'description', label: 'Description', width: 320 },
];

const ATTRIBUTE_COLUMNS = [
  { id: 'name', label: 'Attribut', required: true, width: 230, mono: true },
  { id: 'nature', label: 'Type', width: 170, html: (v, r) => (r.defunct ? '<span class="sch-defunct">Obsolète</span>' : esc(v)) },
  { id: 'values', label: 'Valeurs', width: 104, get: (r) => (r.singleValued ? 'Une' : 'Plusieurs') },
  {
    id: 'indexText', label: 'Index', type: 'enum', width: 150,
    options: [
      { value: 'Indexé', label: 'Indexé', tone: 'ok' }, { value: 'Indexé, sous-chaîne comprise', label: 'Indexé, sous-chaîne', tone: 'ok' },
      { value: 'Non indexé', label: 'Non indexé', tone: 'off' }, { value: 'Calculé, non filtrable', label: 'Calculé', tone: 'warn' },
    ],
  },
  { id: 'inGlobalCatalog', label: 'Catalogue global', type: 'bool', width: 120 },
  { id: 'confidential', label: 'Confidentiel', type: 'bool', width: 116, hidden: true },
  { id: 'constructed', label: 'Calculé', type: 'bool', width: 100, hidden: true },
  { id: 'description', label: 'Description', width: 360 },
];

const STAGES = [
  { id: 'context', label: 'Contexte du schéma', text: 'CN=Schema,CN=Configuration du contrôleur de la session' },
  { id: 'attributes', label: 'Définitions des attributs', text: 'attributeSchema · 8 000 au plus' },
  { id: 'classes', label: 'Définitions des classes', text: 'classSchema · 3 000 au plus' },
];

function emptyMarkup(status) {
  const failed = status?.lastError;
  return `<div class="sch-unread">
    <div class="sch-unread-art" aria-hidden="true">
      <span class="node n1">${glyph('layers')}</span><span class="node n2">${glyph('tag')}</span><span class="node n3">${glyph('key')}</span>
      <span class="link l1"></span><span class="link l2"></span><span class="core">${glyph('tree')}</span>
    </div>
    <div class="sch-unread-body">
      <h3>Le schéma n’est pas encore lu</h3>
      <p>Une seule lecture, sur votre geste, des définitions de classes et d’attributs du contrôleur de la session. Aucune valeur d’objet n’est lue, rien n’est modifié, et le schéma reste en mémoire pour cette session seulement.</p>
      ${failed ? `<p class="sch-note alert" role="alert">${glyph('alert')}<span>${esc(failed)}</span></p>` : ''}
      <ol class="sch-steps" aria-label="Étapes de la lecture">${STAGES.map((s, n) => `<li data-stage="${s.id}" data-j="${n}"><span class="dot" aria-hidden="true"></span><div><b>${esc(s.label)}</b><span>${esc(s.text)}</span></div></li>`).join('')}</ol>
      <div class="sch-unread-actions">
        <button class="btn primary" type="button" data-read>${glyph('download')}Lire le schéma<span class="sch-net" aria-hidden="true">${glyph('wifi')}</span></button>
        <span class="sch-reason">${esc(`Lecture bornée${NBSP}: ${int(status?.limits?.attributes ?? 8000)} attributs, ${int(status?.limits?.classes ?? 3000)} classes, ${int(status?.limits?.seconds ?? 90)} secondes.`)}</span>
      </div>
    </div>
  </div>`;
}

/**
 * Creates the catalog card in host.
 * @param {HTMLElement} host
 * @param {any} ctx
 * @param {{ kind: string, className: string|null, attributeName: string|null, onRead: () => void,
 *   onRoute: (change: Object) => void, onSelected: () => void, onAnalyze: (filter: string) => void, onInsert: (name: string) => void }} o
 */
export function createCatalog(host, ctx, o) {
  host.innerHTML = `<div class="sch-cat">
    <div class="sch-cat-head">
      <div class="segmented sch-kind" role="group" aria-label="Classes ou attributs"><span class="thumb" aria-hidden="true"></span>
        <button type="button" data-kind="classes" aria-pressed="false">${glyph('layers')}Classes<span class="k-badge" data-count="classes">—</span></button>
        <button type="button" data-kind="attributes" aria-pressed="false">${glyph('tag')}Attributs<span class="k-badge" data-count="attributes">—</span></button>
      </div>
      <p class="sch-cat-note">${glyph('shield')}<span>Filtre local sur le nom et la description${NBSP}: aucune lecture réseau.</span></p>
    </div>
    <div class="sch-cat-body"></div>
  </div>`;
  const body = /** @type {HTMLElement} */ (host.querySelector('.sch-cat-body'));
  const kindBar = /** @type {HTMLElement} */ (host.querySelector('.sch-kind'));
  const thumb = /** @type {HTMLElement} */ (kindBar.querySelector('.thumb'));
  let alive = true;
  let kind = o.kind === 'attributes' ? 'attributes' : 'classes';
  let read = false;
  let grid = null;
  let split = null;
  let detailHost = null;
  let detailCleanup = null;
  let detailRequest = 0;
  const lists = { classes: null, attributes: null };
  const totals = { classes: null, attributes: null };
  // What the detail shows: { kind: 'class'|'attribute', name, backClass }.
  let shown = null;
  // Attribute offered to the filter workbench: { name, insertable, reason }.
  let chosenAttribute = null;
  let pendingSelect = { classes: o.className, attributes: o.attributeName };

  function moveThumb() {
    const active = kindBar.querySelector('button[aria-pressed="true"]');
    if (!active) return;
    thumb.style.setProperty('--x', `${active.offsetLeft - 3}px`);
    thumb.style.setProperty('--w', `${active.offsetWidth}px`);
  }

  function markKind() {
    kindBar.querySelectorAll('button[data-kind]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.kind === kind)));
    requestAnimationFrame(moveThumb);
  }

  function setCount(which, total) {
    totals[which] = total;
    const badge = kindBar.querySelector(`[data-count="${which}"]`);
    if (badge) {
      badge.textContent = total === null ? '—' : int(total);
      badge.classList.toggle('has', total !== null);
      badge.classList.remove('bump'); void badge.offsetWidth; badge.classList.add('bump');
    }
  }

  // ---------------------------------------------------------------- unread / reading

  function showUnread(status) {
    destroyBrowser();
    body.innerHTML = emptyMarkup(status);
    applyVars(body);
    body.querySelector('[data-read]')?.addEventListener('click', () => o.onRead());
  }

  /** Follows the read: the stage under way pulses, the previous ones are ticked. */
  function setStage(stage) {
    const steps = [...body.querySelectorAll('.sch-steps li')];
    const at = STAGES.findIndex((s) => s.id === stage);
    steps.forEach((li, n) => {
      li.classList.toggle('done', at >= 0 && n < at);
      li.classList.toggle('now', n === at);
    });
    const button = body.querySelector('[data-read]');
    if (button) {
      button.setAttribute('aria-busy', 'true');
      button.setAttribute('aria-disabled', 'true');
      button.innerHTML = `<span class="k-spin" aria-hidden="true"></span>Lecture en cours…`;
    }
    body.querySelector('.sch-unread')?.classList.add('reading');
  }

  function readFailed(status) {
    showUnread(status);
  }

  // ---------------------------------------------------------------- browser

  function destroyBrowser() {
    detailCleanup?.();
    detailCleanup = null;
    grid?.destroy();
    grid = null;
    split = null;
    detailHost = null;
  }

  function buildBrowser() {
    destroyBrowser();
    const list = document.createElement('div');
    list.className = 'sch-list-pane';
    detailHost = document.createElement('div');
    detailHost.className = 'sch-detail-pane';
    body.innerHTML = '<div class="sch-split"></div>';
    split = createSplit(body.querySelector('.sch-split'), {
      a: list, b: detailHost, fixed: 'b', size: 560, min: 420, max: 980, key: 'schema.detail', label: 'Largeur du détail', collapsible: false,
    });
    grid = createGrid(list, {
      key: `schema.${kind}`,
      label: kind === 'classes' ? 'Classes du schéma lu' : 'Attributs du schéma lu',
      columns: kind === 'classes' ? CLASS_COLUMNS : ATTRIBUTE_COLUMNS,
      rowId: (r) => r.name,
      selection: 'single',
      density: 'compact',
      height: 'fill',
      loading: true,
      quickPlaceholder: kind === 'classes' ? 'Filtrer les classes (nom ou description)…' : 'Filtrer les attributs (nom ou description)…',
      empty: { icon: 'search', title: 'Aucune entrée', text: 'Le schéma lu ne contient aucune entrée de ce type.' },
      onSelectionChange: (rows) => { if (rows[0]) queueDetail(rows[0]); },
      onActivate: (row) => { queueDetail(row, 0); detailHost?.querySelector('.sch-detail')?.focus?.(); },
      onFilterChange: (info) => filterChanged(info),
      contextMenu: ({ row }) => [
        { label: 'Copier le nom LDAP', icon: 'copy', disabled: !row, run: () => copy(row.name) },
        ...(kind === 'attributes' ? [{ label: 'Ajouter au filtre', icon: 'plus', disabled: !row || row.constructed || row.defunct, reason: row?.constructed ? 'Attribut calculé : il ne se filtre pas.' : 'Attribut obsolète.', run: () => o.onInsert(row.name) }] : []),
        ...(kind === 'classes' ? [{ label: 'Analyser le filtre de la classe', icon: 'gauge', disabled: !row, run: () => o.onAnalyze(`(objectClass=${row.name})`) }] : []),
      ],
    });
    detailHost.innerHTML = placeholder(kind);
    detailHost.addEventListener('click', onDetailClick);
  }

  async function loadList(which, text = '') {
    const result = await ctx.call('schema.list', { kind: which, text, limit: LIST_LIMIT });
    if (!alive) return null;
    if (!text) {
      lists[which] = result;
      setCount(which, result.total);
    }
    return result;
  }

  // A catalog larger than the rows sent (more than 5 000 entries) filters through the engine, like Domenia 1.
  const remoteFilter = debounce(async (text) => {
    const result = await loadList(kind, text).catch((err) => { toast(errText(err), { tone: 'alert' }); return null; });
    if (!result || !grid) return;
    grid.setRows(result.rows, { keepSelection: true });
    announce(result.summary);
  }, 250);

  function filterChanged(info) {
    const full = lists[kind];
    if (full && full.total > full.shown) remoteFilter(info.quick);
  }

  async function showKind(next, { select } = {}) {
    kind = next;
    markKind();
    o.onRoute({ vue: kind === 'attributes' ? 'attributs' : null });
    if (!read) return;
    buildBrowser();
    try {
      const result = lists[kind] ?? await loadList(kind);
      if (!alive || !grid || !result) return;
      grid.setRows(result.rows);
      if (result.total > result.shown) toast(result.summary, { tone: 'warn' });
      const wanted = select ?? pendingSelect[kind];
      pendingSelect[kind] = null;
      if (wanted && result.rows.some((r) => r.name.toLowerCase() === wanted.toLowerCase())) {
        const exact = result.rows.find((r) => r.name.toLowerCase() === wanted.toLowerCase()).name;
        grid.select(exact);
        queueDetail({ name: exact }, 0);
      }
    } catch (err) {
      grid?.setError(errText(err, 'Liste illisible.'), { retry: () => showKind(kind) });
    }
  }

  // ---------------------------------------------------------------- detail

  let detailTimer = 0;
  function queueDetail(row, delay = DETAIL_DELAY_MS) {
    clearTimeout(detailTimer);
    detailTimer = setTimeout(() => (kind === 'classes' ? openClass(row.name) : openAttribute(row.name, null)), delay);
  }

  async function openClass(name) {
    if (!detailHost) return;
    const my = ++detailRequest;
    detailCleanup?.();
    detailCleanup = null;
    detailHost.innerHTML = skeleton();
    try {
      const d = await ctx.call('schema.class', { name });
      if (!alive || my !== detailRequest || !detailHost) return;
      shown = { kind: 'class', name: d.name, backClass: null };
      chosenAttribute = null;
      o.onSelected();
      o.onRoute({ classe: d.name, attribut: null });
      const view = renderClass(detailHost, d, {
        onAttribute: (attr) => openAttribute(attr, d.name),
        onSelectAttribute: (r) => {
          chosenAttribute = r ? { name: r.name, insertable: !r.constructed && !r.defunct, reason: r.constructed ? 'Attribut calculé : il ne se filtre pas.' : r.defunct ? 'Attribut obsolète : il ne sert pas dans une nouvelle requête.' : null } : null;
          o.onSelected();
        },
      });
      detailCleanup = view.destroy;
      detailHost.scrollTop = 0;
      announce(`Classe ${d.name} : ${count(d.attributes.length, 'attribut possible', 'attributs possibles')}.`);
    } catch (err) {
      if (!alive || my !== detailRequest || !detailHost) return;
      detailHost.innerHTML = `<div class="sch-detail-empty">${glyph('alert')}<h3>Détail indisponible</h3><p>${esc(errText(err))}</p></div>`;
    }
  }

  async function openAttribute(name, backClass) {
    if (!detailHost) return;
    const my = ++detailRequest;
    detailCleanup?.();
    detailCleanup = null;
    detailHost.innerHTML = skeleton();
    try {
      const d = await ctx.call('schema.attribute', { name });
      if (!alive || my !== detailRequest || !detailHost) return;
      shown = { kind: 'attribute', name: d.name, backClass };
      chosenAttribute = { name: d.name, insertable: d.insertable, reason: d.insertReason };
      o.onSelected();
      o.onRoute(backClass ? { classe: backClass, attribut: d.name } : { attribut: d.name, classe: null });
      detailCleanup = renderAttribute(detailHost, d, { backClass, canInsert: true }).destroy;
      detailHost.scrollTop = 0;
      announce(`Attribut ${d.name} : ${d.summary}.`);
    } catch (err) {
      if (!alive || my !== detailRequest || !detailHost) return;
      detailHost.innerHTML = `<div class="sch-detail-empty">${glyph('alert')}<h3>Détail indisponible</h3><p>${esc(errText(err))}</p></div>`;
    }
  }

  function copy(text) {
    writeClipboard(text).then((ok) => toast(ok ? 'Copié dans le presse-papiers.' : 'Copie impossible.', { tone: ok ? 'ok' : 'warn', life: 2200 }));
  }

  function onDetailClick(e) {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const goClass = t.closest('[data-goto-class]');
    if (goClass) { goToClass(goClass.getAttribute('data-goto-class')); return; }
    const c = t.closest('[data-copy]');
    if (c) { copy(c.getAttribute('data-copy') ?? ''); return; }
    const an = t.closest('[data-analyze]');
    if (an) { o.onAnalyze(an.getAttribute('data-analyze') ?? ''); return; }
    const ins = t.closest('[data-insert]');
    if (ins && ins.getAttribute('aria-disabled') !== 'true') o.onInsert(ins.getAttribute('data-insert') ?? '');
  }

  /** Opens a class: in the class list when it is shown (selected and scrolled to), otherwise after switching to it. */
  function goToClass(name) {
    if (!name) return;
    if (kind !== 'classes') { showKind('classes', { select: name }); return; }
    if (grid && lists.classes?.rows.some((r) => r.name.toLowerCase() === name.toLowerCase())) {
      grid.select(lists.classes.rows.find((r) => r.name.toLowerCase() === name.toLowerCase()).name);
    }
    openClass(name);
  }

  function goToAttribute(name) {
    if (!name) return;
    if (kind === 'attributes' && grid && lists.attributes?.rows.some((r) => r.name.toLowerCase() === name.toLowerCase())) {
      grid.select(lists.attributes.rows.find((r) => r.name.toLowerCase() === name.toLowerCase()).name);
    }
    openAttribute(name, kind === 'classes' && shown?.kind === 'class' ? shown.name : shown?.backClass ?? null);
  }

  kindBar.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('button[data-kind]') : null;
    if (b && b.dataset.kind !== kind) showKind(b.dataset.kind);
  });
  markKind();
  const ro = 'ResizeObserver' in window ? new ResizeObserver(moveThumb) : null;
  ro?.observe(kindBar);

  return {
    /** Schema read (status.read): builds the browser and loads both counts; otherwise the unread card. */
    async setStatus(status) {
      read = !!status?.read;
      if (!read) { setCount('classes', null); setCount('attributes', null); showUnread(status); return; }
      lists.classes = null;
      lists.attributes = null;
      await showKind(kind);
      // The other count, for the switch, without building its view.
      const other = kind === 'classes' ? 'attributes' : 'classes';
      loadList(other).catch((err) => console.error(err));
    },
    setStage,
    readFailed,
    goToClass,
    goToAttribute,
    /** Attribute offered to the workbench, or null. */
    chosen: () => chosenAttribute,
    focusList: () => grid?.focus(),
    destroy() {
      alive = false;
      clearTimeout(detailTimer);
      remoteFilter.cancel();
      ro?.disconnect();
      destroyBrowser();
      split = null;
    },
    categoryTone,
  };
}
