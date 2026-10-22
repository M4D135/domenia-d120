// Catalog of the schema screen (SCH-001 to SCH-003): classes or attributes of the schema read in this session in a virtual
// grid, filtered like Domenia 1 Find-DomeniaAdSchemaEntries (a substring of the name OR of the description, case ignored, after
// a pause of 250 ms, every match counted by the engine), and the detail of the chosen entry beside it, in a resizable
// master-detail split. Before the read, the same card shows what the read goes through and follows it stage by stage; a read
// again shows its stages in the head of the card.
import { createGrid } from '../../kit/grid.js';
import { createSplit } from '../../kit/split.js';
import { debounce, writeClipboard, uid, clamp } from '../../kit/util.js';
import { applyVars, toast, announce } from '../../ui.js';
import { glyph, esc, int, count, NBSP, quote, errText, CATEGORY_TONES, STAGES } from './model.js';
import { placeholder, skeleton, renderClass, renderAttribute } from './detail.js';

/** Rows asked at once: the whole catalog of a usual schema; the total stays exact beyond. */
const LIST_LIMIT = 5000;
/** Longest filter text (SchemaRules.MaxListText). */
const TEXT_MAX = 128;
/** Pause after typing, as Domenia 1 (Request-DomeniaAdSchemaListUpdate). */
const FILTER_DELAY_MS = 250;
const DETAIL_DELAY_MS = 120;

/** Shortcuts once the schema is read: the classes an administrator opens most. */
const QUICK_CLASSES = ['user', 'computer', 'group', 'organizationalUnit', 'contact', 'msDS-GroupManagedServiceAccount'];

const CLASS_COLUMNS = [
  { id: 'name', label: 'Classe', required: true, width: 230, mono: true },
  {
    id: 'nature', label: 'Catégorie', type: 'enum', width: 132,
    options: Object.entries(CATEGORY_TONES).map(([value, tone]) => ({ value, label: value, tone })),
  },
  { id: 'subClassOf', label: 'Hérite de', width: 170, mono: true, hidden: true },
  { id: 'description', label: 'Description', width: 240 },
];

/** Glyphs after the name of an attribute: catalogue global, confidential, constructed (columns hidden by default). */
function attributeName(v, r) {
  const marks = [
    r.inGlobalCatalog ? `<span class="m gc" data-tip="Répliqué dans le catalogue global">${glyph('domain')}</span>` : '',
    r.confidential ? `<span class="m conf" data-tip="Confidentiel">${glyph('lock')}</span>` : '',
    r.constructed ? `<span class="m calc" data-tip="Calculé${NBSP}: ne se filtre pas">${glyph('sparkles')}</span>` : '',
  ].join('');
  return `<span class="sch-attr-cell${r.defunct ? ' defunct' : ''}"><span class="n">${esc(v)}</span>${marks ? `<span class="sch-marks">${marks}</span>` : ''}</span>`;
}

const ATTRIBUTE_COLUMNS = [
  { id: 'name', label: 'Attribut', required: true, width: 204, mono: true, html: attributeName },
  { id: 'nature', label: 'Type', width: 130, html: (v, r) => (r.defunct ? '<span class="sch-defunct">Obsolète</span>' : esc(v)) },
  { id: 'values', label: 'Valeurs', width: 112, get: (r) => (r.singleValued ? 'Une' : 'Plusieurs') },
  {
    id: 'indexText', label: 'Index', type: 'enum', width: 134,
    options: [
      { value: 'Indexé', label: 'Indexé', tone: 'ok' }, { value: 'Indexé, sous-chaîne comprise', label: 'Sous-chaîne', tone: 'ok' },
      { value: 'Non indexé', label: 'Non indexé', tone: 'off' }, { value: 'Calculé, non filtrable', label: 'Calculé', tone: 'warn' },
    ],
  },
  { id: 'inGlobalCatalog', label: 'Catalogue global', type: 'bool', width: 120, hidden: true },
  { id: 'confidential', label: 'Confidentiel', type: 'bool', width: 116, hidden: true },
  { id: 'constructed', label: 'Calculé', type: 'bool', width: 100, hidden: true },
  { id: 'description', label: 'Description', width: 200 },
];

function unreadMarkup(status) {
  const failed = status?.lastError;
  return `<div class="sch-unread">
    <div class="sch-unread-art" aria-hidden="true">
      <span class="node n1">${glyph('layers')}</span><span class="node n2">${glyph('tag')}</span><span class="node n3">${glyph('key')}</span>
      <span class="link l1"></span><span class="link l2"></span><span class="core">${glyph('tree')}</span>
    </div>
    <div class="sch-unread-body">
      <div class="sch-unread-head">
        <h3>Le catalogue apparaîtra ici</h3>
        <p>Après la lecture, sur votre geste («${NBSP}Lire le schéma${NBSP}» en haut de l’écran)${NBSP}: les classes et les attributs du contrôleur de la session, filtrables par nom ou description, avec le détail de chacun.</p>
      </div>
      ${failed ? `<p class="sch-note alert" role="alert">${glyph('alert')}<span>${esc(failed)}</span></p>` : ''}
      <ol class="sch-steps" aria-label="Étapes de la lecture">${STAGES.map((s, n) => `<li data-stage="${s.id}" data-j="${n}"><span class="num" aria-hidden="true">${n + 1}</span><div><b>${esc(s.label)}</b><span>${esc(s.text)}</span></div><span class="dot" aria-hidden="true"></span></li>`).join('')}</ol>
      <p class="sch-reason">${glyph('shield')}<span>${esc(`Lecture bornée${NBSP}: ${int(status?.limits?.attributes ?? 8000)} attributs, ${int(status?.limits?.classes ?? 3000)} classes et ${int(status?.limits?.seconds ?? 90)} secondes au plus.`)}</span></p>
    </div>
  </div>`;
}

/**
 * Creates the catalog card in host.
 * @param {HTMLElement} host
 * @param {any} ctx
 * @param {{ kind: string, className: string|null, attributeName: string|null, onRoute: (change: Object) => void,
 *   onSelected: () => void, onAnalyze: (filter: string) => void, onInsert: (name: string) => void }} o
 */
export function createCatalog(host, ctx, o) {
  const id = uid('sch-cat');
  host.innerHTML = `<div class="sch-cat">
    <div class="sch-cat-head">
      <div class="segmented sch-kind" role="group" aria-label="Classes ou attributs"><span class="thumb" aria-hidden="true"></span>
        <button type="button" data-kind="classes" aria-pressed="false">${glyph('layers')}Classes<span class="k-badge" data-count="classes">—</span></button>
        <button type="button" data-kind="attributes" aria-pressed="false">${glyph('tag')}Attributs<span class="k-badge" data-count="attributes">—</span></button>
      </div>
      <label class="sch-search" for="${id}-q">${glyph('search')}<span class="visually-hidden">Filtrer sur le nom ou la description, sans lecture réseau</span>
        <input id="${id}-q" class="sch-search-input" type="search" maxlength="${TEXT_MAX}" autocomplete="off" spellcheck="false" disabled
          aria-describedby="${id}-found" placeholder="Filtrer${NBSP}: nom ou description"></label>
      <span class="sch-found" id="${id}-found" aria-live="polite"></span>
      <span class="sch-cat-note" data-tip="Comme Domenia 1${NBSP}: le texte est cherché dans le nom et la description, sur ce poste, dans le schéma déjà lu.">${glyph('shield')}<span>Filtre local, aucune lecture réseau</span></span>
      <ol class="sch-progress" aria-label="Lecture du schéma en cours" hidden>${STAGES.map((s) => `<li data-stage="${s.id}"><span class="dot" aria-hidden="true"></span>${esc(s.short)}</li>`).join('')}</ol>
    </div>
    <div class="sch-cat-quick" hidden>
      <span class="sch-quick-k">${glyph('layers')}Classes courantes</span>
      ${QUICK_CLASSES.map((name, j) => `<button class="sch-node" type="button" data-j="${j}" data-quick-class="${esc(name)}">${esc(name)}</button>`).join('')}
    </div>
    <div class="sch-cat-body"></div>
  </div>`;
  const body = /** @type {HTMLElement} */ (host.querySelector('.sch-cat-body'));
  const kindBar = /** @type {HTMLElement} */ (host.querySelector('.sch-kind'));
  const thumb = /** @type {HTMLElement} */ (kindBar.querySelector('.thumb'));
  const search = /** @type {HTMLInputElement} */ (host.querySelector('.sch-search-input'));
  const found = /** @type {HTMLElement} */ (host.querySelector('.sch-found'));
  const progress = /** @type {HTMLElement} */ (host.querySelector('.sch-progress'));
  const quick = /** @type {HTMLElement} */ (host.querySelector('.sch-cat-quick'));
  let alive = true;
  let kind = o.kind === 'attributes' ? 'attributes' : 'classes';
  let read = false;
  let grid = null;
  let detailHost = null;
  let detailCleanup = null;
  let detailRequest = 0;
  let listRequest = 0;
  // Unfiltered results, for the counts of the switch and the first view of each kind.
  const lists = { classes: null, attributes: null };
  // What the detail shows: { kind: 'class'|'attribute', name, backClass }.
  let shown = null;
  // Attribute offered to the filter workbench: { name, insertable, reason }.
  let chosenAttribute = null;
  const pendingSelect = { classes: o.className, attributes: o.attributeName };

  function moveThumb() {
    const active = kindBar.querySelector('button[aria-pressed="true"]');
    if (!active) return;
    thumb.style.setProperty('--x', `${active.offsetLeft - 3}px`);
    thumb.style.setProperty('--w', `${active.offsetWidth}px`);
  }

  function markKind() {
    kindBar.querySelectorAll('button[data-kind]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.kind === kind)));
    search.placeholder = kind === 'classes' ? `Filtrer les classes${NBSP}: nom ou description` : `Filtrer les attributs${NBSP}: nom ou description`;
    requestAnimationFrame(moveThumb);
  }

  function setCount(which, total) {
    const badge = kindBar.querySelector(`[data-count="${which}"]`);
    if (badge) {
      badge.textContent = total === null ? '—' : int(total);
      badge.classList.toggle('has', total !== null);
      badge.classList.remove('bump'); void badge.offsetWidth; badge.classList.add('bump');
    }
  }

  /** « 47 classes » without a filter, the summary of the engine with one (« 12 classes trouvées. »). */
  function showFound(result) {
    if (!result) { found.textContent = ''; found.className = 'sch-found'; return; }
    const filtered = !!result.text;
    found.textContent = filtered ? result.summary : count(result.total, kind === 'classes' ? 'classe' : 'attribut', kind === 'classes' ? 'classes' : 'attributs');
    found.className = `sch-found${filtered ? ' on' : ''}${result.total > result.shown ? ' warn' : ''}`;
  }

  // ---------------------------------------------------------------- unread / reading

  function showUnread(status) {
    destroyBrowser();
    body.innerHTML = unreadMarkup(status);
    applyVars(body);
    quick.hidden = true;
    search.disabled = true;
    showFound(null);
  }

  /** Follows a read: the stage under way pulses, the previous ones are ticked; null ends it. */
  function setStage(stage) {
    const at = STAGES.findIndex((s) => s.id === stage);
    progress.hidden = !read || stage === null;
    for (const list of [progress, body.querySelector('.sch-steps')]) {
      if (!list) continue;
      [...list.querySelectorAll('li')].forEach((li, n) => {
        li.classList.toggle('done', at >= 0 && n < at);
        li.classList.toggle('now', n === at);
      });
    }
    body.querySelector('.sch-unread')?.classList.toggle('reading', stage !== null);
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
    detailHost = null;
  }

  function buildBrowser() {
    destroyBrowser();
    const list = document.createElement('div');
    list.className = 'sch-list-pane';
    detailHost = document.createElement('div');
    detailHost.className = 'sch-detail-pane';
    body.innerHTML = '<div class="sch-split"></div>';
    // Detail proportional to the card (about a third), so the list keeps its columns without a sideways scroll.
    const width = body.clientWidth || 1200;
    createSplit(body.querySelector('.sch-split'), {
      a: list, b: detailHost, fixed: 'b', size: clamp(Math.round(width * 0.36), 380, 520), min: 340, max: 900,
      key: 'schema.detail.v2', label: 'Largeur du détail', collapsible: false,
    });
    grid = createGrid(list, {
      key: `schema.${kind}.v2`,
      label: kind === 'classes' ? 'Classes du schéma lu' : 'Attributs du schéma lu',
      columns: kind === 'classes' ? CLASS_COLUMNS : ATTRIBUTE_COLUMNS,
      rowId: (r) => r.name,
      selection: 'single',
      density: 'compact',
      height: 'fill',
      loading: true,
      // The page filters like Domenia 1 (name or description, through the engine): the quick filter of the grid, which looks
      // in every visible column, is not offered. The filters per column stay (explicit, one column each).
      quickFilter: false,
      empty: { icon: 'search', title: 'Aucune entrée', text: 'Le schéma lu ne contient aucune entrée de ce type.' },
      onSelectionChange: (rows) => { if (rows[0]) queueDetail(rows[0]); },
      onActivate: (row) => { queueDetail(row, 0); detailHost?.querySelector('.sch-detail')?.focus?.(); },
      contextMenu: ({ row }) => [
        { label: 'Copier le nom LDAP', icon: 'copy', disabled: !row, reason: 'Choisissez une ligne.', run: () => copy(row.name) },
        ...(kind === 'attributes' ? [{
          label: 'Ajouter au filtre', icon: 'plus',
          disabled: !row || row.constructed || row.defunct,
          reason: !row ? 'Choisissez une ligne.' : row.constructed ? 'Attribut calculé : il ne se filtre pas.' : row.defunct ? 'Attribut obsolète : il ne sert pas dans une nouvelle requête.' : undefined,
          run: () => o.onInsert(row.name),
        }] : []),
        ...(kind === 'classes' ? [{ label: 'Analyser le filtre de la classe', icon: 'gauge', disabled: !row, reason: 'Choisissez une ligne.', run: () => o.onAnalyze(`(objectClass=${row.name})`) }] : []),
      ],
    });
    detailHost.innerHTML = placeholder(kind);
    detailHost.addEventListener('click', onDetailClick);
  }

  async function loadList(which, text = '') {
    const result = await ctx.call('schema.list', { kind: which, text: text || null, limit: LIST_LIMIT });
    if (!alive) return null;
    if (!text) {
      lists[which] = result;
      setCount(which, result.total);
    }
    return result;
  }

  /** The text of the field, trimmed, at most 128 characters (the field refuses more; a pasted text is cut, and the page says so). */
  function filterText() {
    const raw = search.value.trim();
    if (raw.length > TEXT_MAX) {
      search.value = raw.slice(0, TEXT_MAX);
      toast(`Filtre limité à ${int(TEXT_MAX)} caractères${NBSP}: la suite est ignorée.`, { tone: 'warn', life: 3200 });
    }
    return search.value.trim();
  }

  // Domenia 1: the list follows the text after a pause of 250 ms; the engine counts every match.
  async function applyFilter() {
    if (!read || !grid) return;
    const text = filterText();
    const my = ++listRequest;
    try {
      const result = text ? await loadList(kind, text) : lists[kind] ?? await loadList(kind);
      if (!alive || !grid || my !== listRequest || !result) return;
      grid.setEmpty(text
        ? { icon: 'search', title: 'Aucune entrée', text: `Aucun${kind === 'classes' ? 'e classe' : ' attribut'} ne contient ${quote(text)} dans son nom ou sa description.` }
        : { icon: 'search', title: 'Aucune entrée', text: 'Le schéma lu ne contient aucune entrée de ce type.' });
      grid.setRows(result.rows, { keepSelection: true });
      showFound(result);
      if (text) announce(result.summary);
    } catch (err) {
      if (!alive || my !== listRequest) return;
      toast(errText(err, 'Filtre impossible.'), { tone: 'alert' });
    }
  }
  const filterLater = debounce(applyFilter, FILTER_DELAY_MS);

  async function showKind(next, { select } = {}) {
    kind = next;
    markKind();
    o.onRoute({ vue: kind === 'attributes' ? 'attributs' : null });
    if (!read) return;
    buildBrowser();
    const text = filterText();
    const my = ++listRequest;
    try {
      const all = lists[kind] ?? await loadList(kind);
      const result = text ? await loadList(kind, text) : all;
      if (!alive || !grid || !result || my !== listRequest) return;
      grid.setRows(result.rows);
      showFound(result);
      if (result.total > result.shown) toast(result.summary, { tone: 'warn' });
      const wanted = select ?? pendingSelect[kind];
      pendingSelect[kind] = null;
      const exact = wanted ? result.rows.find((r) => r.name.toLowerCase() === wanted.toLowerCase()) : null;
      if (exact) {
        grid.select([exact.name]);
        queueDetail({ name: exact.name }, 0);
      } else if (wanted) {
        queueDetail({ name: wanted }, 0);
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
      announce(`Classe ${d.name}${NBSP}: ${count(d.attributes.length, 'attribut possible', 'attributs possibles')}.`);
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
      detailCleanup = renderAttribute(detailHost, d, { backClass }).destroy;
      detailHost.scrollTop = 0;
      announce(`Attribut ${d.name}${NBSP}: ${d.summary}.`);
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
    const row = grid?.getVisibleRows?.().find((r) => r.name.toLowerCase() === name.toLowerCase());
    if (row) grid.select([row.name]);
    openClass(name);
  }

  function goToAttribute(name) {
    if (!name) return;
    const row = kind === 'attributes' ? grid?.getVisibleRows?.().find((r) => r.name.toLowerCase() === name.toLowerCase()) : null;
    if (row) grid.select([row.name]);
    openAttribute(name, kind === 'classes' && shown?.kind === 'class' ? shown.name : shown?.backClass ?? null);
  }

  kindBar.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('button[data-kind]') : null;
    if (b && b.dataset.kind !== kind) showKind(b.dataset.kind);
  });
  quick.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-quick-class]') : null;
    if (b) goToClass(b.getAttribute('data-quick-class'));
  });
  search.addEventListener('input', () => filterLater());
  search.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); filterLater.cancel?.(); applyFilter(); }
    else if (e.key === 'Escape' && search.value) { e.preventDefault(); e.stopPropagation(); search.value = ''; filterLater.cancel?.(); applyFilter(); }
    else if (e.key === 'ArrowDown' && grid) { e.preventDefault(); grid.focus(); }
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
      quick.hidden = false;
      search.disabled = false;
      applyVars(quick);
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
      filterLater.cancel?.();
      ro?.disconnect();
      destroyBrowser();
    },
  };
}
