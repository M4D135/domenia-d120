// Accueil: side panels of the fleet board — « Postes concernés » (exact sets, kit grid), widget and probe catalog, probe
// contract, « Comprendre le score », provenance and collections, and the analysis (comparison, cross tables, manual
// snapshot). Every panel is a kit drawer; every read is local (LocalRead), nothing reaches the network.
import { openDrawer } from '../../kit/drawer.js';
import { openDialog } from '../../kit/dialog.js';
import { createGrid } from '../../kit/grid.js';
import { createTabs } from '../../kit/tabs.js';
import { glyph } from '../../kit/glyphs.js';
import { pill } from '../../kit/status.js';
import { highlight } from '../../kit/util.js';
import { esc, fold, formatNumber, countUp } from '../../ui.js';
import {
  NBSP, isNum, plural, paint, reported, surface, localStamp, copyWithToast, sk, skStack, isRootDn, rememberObject,
} from './shared.js';

const PRESENCE_TONE = { 'En ligne': 'ok', 'Sans réponse': 'warn', 'Non vérifié': 'off' };
const STATE_TONE = { Activé: 'ok', Désactivé: 'off', Inconnu: 'warn' };
const CLOCK_TONE = { success: 'ok', successThenFailure: 'warn', failureOnly: 'alert', incoherent: 'warn', neverRecorded: 'off' };
const CLOCK_LABEL = { success: 'Réussi', successThenFailure: 'Dernier essai en échec', failureOnly: 'Sans réussite complète', incoherent: 'Dates incohérentes', neverRecorded: 'Jamais relevé' };

const loading = (rows = 4) => `<div class="acc-loading" aria-busy="true">${Array.from({ length: rows }, (_, n) => sk(`sk-line ${['w85', 'w70', 'w55', 'w70'][n % 4]}`)).join('')}</div>`;
const failed = (err, retry = 'data-acc-retry') => `<div class="acc-err" role="alert">${glyph('alert')}<span>${esc(reported(err))}</span><button class="btn sm" type="button" ${retry}>${glyph('refresh')}Réessayer</button></div>`;

// ---------- « Postes concernés » ----------

const SCORE_TONE = (v) => (!isNum(v) ? 'off' : v >= 90 ? 'ok' : v >= 60 ? 'warn' : 'alert');

/**
 * Exact workstations of one figure, from the calculation that produced it (accueil.targets), with the score of each workstation
 * (ACC-029: 100 − 25 per critical point − 10 per point to watch). « Ouvrir l’OU dans Rechercher » never sends the domain root
 * (ACC-031) and passes the calculation and the key of the set, for Rechercher to take the exact list once it reads it.
 * @param {{ ctx: any, revision: string, key: string, label: string, scope: any, onReplaced: () => void }} o
 */
export function openTargets(o) {
  const { ctx } = o;
  const host = surface('acc-targets', `<div class="tg-head">${skStack('sk-line w55', 'sk-line w40')}</div><div class="tg-grid"></div>`);
  let grid = null;
  let rows = [];
  const root = !o.scope || isRootDn(o.scope.dn);
  const drawer = openDrawer({
    title: 'Postes concernés', subtitle: o.label, icon: 'monitor', key: 'accueil.targets.v2', width: 980, minWidth: 460, body: host,
    actions: [
      { id: 'copy', label: 'Copier les noms', icon: 'copy', run: () => { if (rows.length) copyWithToast(ctx, rows.map((r) => r.name).join('\r\n'), `${plural(rows.length, 'nom de poste copié', 'noms de postes copiés')} dans le presse-papiers.`); } },
      {
        id: 'search', label: 'Ouvrir l’OU dans Rechercher', icon: 'search',
        run: (d) => {
          if (root) return;
          d.close();
          ctx.navigate('rechercher', { ou: o.scope.dn, sousou: o.scope.subtree ? '1' : '0', type: 'computers', source: 'accueil', revision: o.revision, cle: o.key });
        },
      },
      { id: 'close', label: 'Fermer', primary: true, run: (d) => d.close() },
    ],
    onClose: () => grid?.destroy?.(),
  });
  const searchBtn = drawer.foot?.querySelector('[data-id="search"]');
  if (searchBtn) {
    searchBtn.disabled = root;
    searchBtn.dataset.tip = root ? 'Jamais pour le domaine entier : choisissez une OU de travail.'
      : 'Rechercher s’ouvre sur l’OU de travail ; la liste exacte lui est transmise (calcul et clé de l’ensemble).';
  }
  const gridHost = host.querySelector('.tg-grid');
  grid = createGrid(gridHost, {
    label: `Postes concernés${NBSP}: ${o.label}`,
    key: 'accueil.targets.v2',
    selection: 'multi',
    height: 'fill',
    loading: true,
    rowId: (r) => r.guid,
    quickPlaceholder: 'Filtrer ces postes',
    columns: [
      { id: 'name', label: 'Nom', required: true, width: 150, html: (v) => `<span class="tg-name">${glyph('monitor')}${esc(v)}</span>` },
      {
        id: 'score', label: 'Score', type: 'number', width: 92, align: 'center', tip: 'Score du poste : 100 − 25 par point critique − 10 par point à surveiller ; « — » si le poste n’est pas évalué',
        html: (v, r) => (isNum(v) ? `<span class="tg-score" data-tone="${SCORE_TONE(v)}" data-tip="${esc(`${plural(r.alerts ?? 0, 'point critique', 'points critiques')} · ${plural(r.warnings ?? 0, 'point à surveiller', 'points à surveiller')}`)}"><b class="num">${formatNumber(v)}</b></span>` : '<span class="faint" data-tip="Poste non évalué : données incomplètes">—</span>'),
        csv: (v) => (isNum(v) ? String(v) : ''),
      },
      { id: 'presence', label: 'Présence', type: 'enum', width: 136, options: Object.entries(PRESENCE_TONE).map(([value, t]) => ({ value, label: value, tone: t })) },
      { id: 'system', label: 'Système', width: 224 },
      { id: 'lastLogon', label: 'Dernière connexion', type: 'date', dateStyle: 'date', width: 136, tip: 'lastLogonTimestamp, répliqué à 14 jours près' },
      { id: 'diskFree', label: 'Libre sur C:', type: 'number', decimals: 0, width: 104, align: 'end', format: (v) => (isNum(v) ? `${formatNumber(v)}${NBSP}%` : '—') },
      { id: 'state', label: 'Compte AD', type: 'enum', width: 120, hidden: true, options: Object.entries(STATE_TONE).map(([value, t]) => ({ value, label: value, tone: t })) },
      { id: 'ou', label: 'OU', width: 150, hidden: true },
      { id: 'uptimeDays', label: 'Démarré depuis', type: 'number', width: 120, align: 'end', hidden: true, format: (v) => (isNum(v) ? plural(v, 'jour', 'jours') : '—') },
      { id: 'model', label: 'Modèle', width: 160, hidden: true },
      { id: 'user', label: 'Utilisateur vu', width: 140, hidden: true },
      { id: 'dn', label: 'DN', mono: true, hidden: true, width: 320 },
      { id: 'guid', label: 'GUID', mono: true, hidden: true, width: 280 },
    ],
    empty: { icon: 'check', title: 'Aucun poste', text: 'Ce chiffre ne compte aucun poste dans le calcul affiché.' },
    onActivate: (row) => { rememberObject({ dn: row.dn, name: row.name, kind: 'poste' }); drawer.close(); ctx.navigate('poste', { dn: row.dn }); },
    onExport: (csv, info) => copyWithToast(ctx, csv, `${plural(info.rows, 'ligne copiée', 'lignes copiées')} au format CSV.`),
  });

  (async () => {
    try {
      const r = await ctx.call('accueil.targets', { revision: o.revision, key: o.key });
      rows = Array.isArray(r?.rows) ? r.rows : [];
      drawer.setTitle('Postes concernés', r.label || o.label);
      const scored = rows.filter((x) => isNum(x.score));
      const mean = scored.length ? Math.round(scored.reduce((a, x) => a + x.score, 0) / scored.length) : null;
      host.querySelector('.tg-head').innerHTML = `<p class="tg-count"><b class="num" data-count="${r.total}">0</b> ${r.total > 1 ? 'postes' : 'poste'}`
        + `${r.truncated ? ` · ${formatNumber(rows.length)} affichés (liste bornée)` : ''}${mean !== null ? `<span class="tg-mean" data-tone="${SCORE_TONE(mean)}">Score moyen ${formatNumber(mean)}</span>` : ''}</p>`
        + `<p class="tg-note">${glyph('info')}<span>Liste exacte du calcul affiché${NBSP}: la même population que le chiffre, sans nouvelle lecture. Double-cliquez sur un poste pour ouvrir sa fiche.</span></p>`;
      countUp(host.querySelector('[data-count]'), r.total, { delay: 80 });
      grid.setRows(rows);
    } catch (err) {
      if (err?.code === 'board.replaced') {
        // Domenia 1 (point 73): refusal, board drawn again, message. The board behind is recomputed at once; the panel keeps
        // the message and offers to close and click the figure again on the new calculation.
        host.querySelector('.tg-head').innerHTML = `<div class="acc-err" role="alert">${glyph('refresh')}<span>${esc(reported(err))}</span>`
          + `<button class="btn sm" type="button" data-tg-recompute>${glyph('check')}Fermer et revoir le tableau</button></div>`;
        grid.setRows([]);
        host.querySelector('[data-tg-recompute]').addEventListener('click', () => drawer.close());
        try { o.onReplaced(); } catch (e) { console.error(e); }
        return;
      }
      host.querySelector('.tg-head').innerHTML = '';
      grid.setError(reported(err));
    }
  })();
  return drawer;
}

// ---------- Widget catalog ----------

/**
 * @param {{ ctx: any, board: any, onProbe: (id: string) => void }} o  board: the board API (has, add, count, max).
 */
export function openCatalog(o) {
  const { ctx, board } = o;
  const host = surface('acc-catalog', loading(6));
  let catalog = null;
  let tabs = null;
  const drawer = openDrawer({
    title: 'Ajouter un widget', subtitle: 'Widgets du parc, sondes WMI et requêtes ; la disposition est gardée dans les préférences locales.',
    icon: 'plus', key: 'accueil.catalog', width: 720, minWidth: 420, body: host,
    actions: [{ id: 'close', label: 'Fermer', primary: true, run: (d) => d.close() }],
    onClose: () => tabs?.destroy?.(),
  });

  const added = (source, key) => board.has(source, key);
  const full = () => board.count() >= board.max();

  function addButton(source, key, label) {
    const on = added(source, key);
    return `<button class="btn sm${on ? ' ghost' : ' primary'} cat-add" type="button" data-cat-add="${esc(source)}|${esc(key)}"${on ? ' disabled' : ''} aria-label="${esc(on ? `${label} : déjà sur le tableau` : `Ajouter ${label}`)}">`
      + `${glyph(on ? 'check' : 'plus')}${on ? 'Affiché' : 'Ajouter'}</button>`;
  }

  function widgetsPanel(panel) {
    const count = catalog.groups.reduce((sum, g) => sum + g.widgets.length, 0);
    const item = (w, n) => `<article class="cat-item" data-j="${Math.min(n, 12)}"><div class="cat-text"><h4>${esc(w.title)}</h4><p>${esc(w.description)}</p>`
      + `<div class="cat-tags">${w.visuals.map((v) => `<span class="cat-tag${v === w.visual ? ' on' : ''}">${esc(catalog.visualNames?.[v] ?? v)}</span>`).join('')}`
      + `<span class="cat-tag size">${esc(catalog.sizeNames?.[w.size] ?? w.size)}</span>${w.default ? '<span class="cat-tag def">Livré</span>' : ''}</div></div>`
      + `${addButton('builtin', w.key, w.title)}</article>`;
    const group = (g, gi) => `<section class="cat-group" data-j="${gi}"><h3>${esc(g.name)}</h3><div class="cat-list">${g.widgets.map(item).join('')}</div></section>`;
    panel.innerHTML = `<p class="cat-lead">${plural(count, 'widget', 'widgets')} en ${plural(catalog.groups.length, 'section', 'sections')}, calculés depuis la base locale. `
      + `Chaque chiffre ouvre ses postes exacts.</p>${catalog.groups.map(group).join('')}`;
    paint(panel);
  }

  function probesPanel(panel) {
    panel.innerHTML = `<div class="cat-probe-bar"><label class="cat-search">${glyph('search')}<span class="visually-hidden">Filtrer les sondes</span><input type="search" maxlength="80" placeholder="Filtrer les ${formatNumber(catalog.probeCount)} sondes (nom, classe, catégorie)" autocomplete="off" spellcheck="false"></label>`
      + `<p class="cat-lead">Lues par WMI sur les postes en ligne lors de « Actualiser ping et WMI » ; une sonde en pause n’est plus relevée. Le contrat dit les droits, le coût et les limites.</p></div><div class="cat-probes"></div>`;
    const list = panel.querySelector('.cat-probes');
    const input = panel.querySelector('input');
    const draw = () => {
      const q = fold(input.value.trim());
      const cats = catalog.probes.map((c) => ({ ...c, probes: c.probes.filter((p) => !q || fold(`${p.name} ${p.summary} ${p.category} ${p.id}`).includes(q)) })).filter((c) => c.probes.length);
      const probe = (p) => `<article class="cat-item probe"><div class="cat-text"><h4>${q ? highlight(p.name, q) : esc(p.name)}</h4><p>${esc(p.summary)}</p>`
        + `<div class="cat-tags">${p.visuals.map((v) => `<span class="cat-tag${v === p.visual ? ' on' : ''}">${esc(catalog.visualNames?.[v] ?? v)}</span>`).join('')}`
        + `${p.slow ? '<span class="cat-tag warn" data-tip="Collecte plus longue">Lente</span>' : ''}${p.skipOnDc ? '<span class="cat-tag" data-tip="Jamais lue sur un contrôleur de domaine">Hors contrôleurs</span>' : ''}<span class="cat-tag origin">${esc(p.origin)}</span></div></div>`
        + `<div class="cat-acts"><button class="btn sm ghost" type="button" data-cat-probe="${esc(p.id)}">${glyph('file')}Contrat</button>${addButton('probe', p.id, p.name)}</div></article>`;
      const category = (c, ci) => `<section class="cat-group" data-j="${Math.min(ci, 10)}"><h3>${esc(c.name)} <span class="cat-n">${formatNumber(c.probes.length)}</span></h3><div class="cat-list">${c.probes.map(probe).join('')}</div></section>`;
      list.innerHTML = cats.length ? cats.map(category).join('')
        : `<div class="acc-empty">${glyph('search')}<p>Aucune sonde ne correspond à «${NBSP}${esc(input.value.trim())}${NBSP}».</p></div>`;
      paint(list);
    };
    input.addEventListener('input', draw);
    input.addEventListener('keydown', (e) => { if (e.key === 'Escape' && input.value) { e.preventDefault(); e.stopPropagation(); input.value = ''; draw(); } });
    draw();
  }

  function queriesPanel(panel) {
    const queries = catalog.queries ?? [];
    panel.innerHTML = `<p class="cat-lead">${esc(catalog.queriesText)}</p><div class="cat-list">${queries.map((q) => {
      const on = q.widgetId && added('query', q.widgetId);
      return `<article class="cat-item"><div class="cat-text"><h4>${esc(q.name)}</h4><p>${esc(q.target)} · Révision ${formatNumber(q.revision)} · Empreinte ${esc(q.fingerprint.slice(0, 12))}</p></div>`
        + `<button class="btn sm${on ? ' ghost' : ' primary'}" type="button" data-query-add="${esc(q.id)}"${on ? ' disabled' : ''}>${glyph(on ? 'check' : 'plus')}${on ? 'Affiché' : 'Ajouter'}</button></article>`;
    }).join('')}</div><button class="btn sm" type="button" data-cat-queries>${glyph('external')}Ouvrir l’atelier de requêtes</button>`;
    paint(panel);
  }

  async function load() {
    host.innerHTML = loading(6);
    try {
      catalog = await ctx.call('accueil.widgets.catalog');
    } catch (err) {
      host.innerHTML = failed(err);
      return;
    }
    host.innerHTML = '<div class="cat-tabs"></div>';
    tabs = createTabs(host.querySelector('.cat-tabs'), {
      label: 'Catalogue des widgets', key: 'accueil.catalog',
      tabs: [
        { id: 'widgets', label: 'Widgets du parc', icon: 'layers', count: catalog.groups.reduce((s, g) => s + g.widgets.length, 0), render: widgetsPanel },
        { id: 'probes', label: 'Sondes WMI', icon: 'chip', count: catalog.probeCount, render: probesPanel },
        { id: 'queries', label: 'Requêtes', icon: 'database', count: null, render: queriesPanel },
      ],
    });
  }

  host.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    if (t.closest('[data-acc-retry]')) { load(); return; }
    if (t.closest('[data-cat-queries]')) { drawer.close(); ctx.go('requetes'); return; }
    const queryAdd = t.closest('[data-query-add]');
    if (queryAdd) {
      if (queryAdd.disabled) return;
      const query = catalog.queries?.find((q) => q.id === queryAdd.dataset.queryAdd);
      if (!query || full()) { ctx.toast('Le tableau est complet ; retirez un widget avant d’en ajouter.', { tone: 'warn' }); return; }
      queryAdd.disabled = true;
      try {
        const saved = await ctx.call('accueil.query.bind', { id: query.id, revision: query.revision });
        await board.add([saved.item]);
        if (!board.has('query', saved.item.key)) throw new Error('Lien enregistré dans la bibliothèque ; disposition non enregistrée. Réessayez l’ajout.');
        query.widgetId = saved.item.key;
        queryAdd.textContent = 'Affiché';
        ctx.toast(saved.receipt.text, { tone: saved.receipt.readBack ? 'ok' : 'warn' });
      } catch (err) { queryAdd.disabled = false; ctx.toast(reported(err), { tone: 'warn' }); }
      return;
    }
    const probe = t.closest('[data-cat-probe]');
    if (probe) { o.onProbe(probe.dataset.catProbe); return; }
    const add = t.closest('[data-cat-add]');
    if (!add || add.disabled) return;
    if (full()) { ctx.toast(`Le tableau compte déjà ${formatNumber(board.max())} widgets : retirez-en un avant d’en ajouter.`, { tone: 'warn' }); return; }
    const [source, key] = add.dataset.catAdd.split('|');
    let def;
    if (source === 'builtin') {
      const w = catalog.groups.flatMap((g) => g.widgets).find((x) => x.key === key);
      def = w && { source, key, visual: w.visual, size: w.size, group: w.group, title: w.title };
    } else {
      const p = catalog.probes.flatMap((c) => c.probes).find((x) => x.id === key);
      def = p && { source, key, visual: p.visual, size: 'M', group: 'Relevés des postes', title: p.name };
    }
    if (!def) return;
    // A disabled button drops the focus to the body, where Échap no longer reaches the panel: keep the focus inside it.
    const panel = add.closest('.k-drw');
    add.disabled = true;
    if (panel instanceof HTMLElement) panel.focus({ preventScroll: true });
    add.classList.add('spinning');
    await board.add([def]);
    add.classList.remove('spinning', 'primary');
    add.classList.add('ghost', 'done');
    add.innerHTML = `${glyph('check')}Affiché`;
    ctx.toast(`« ${def.title} » ajouté au tableau du parc${source === 'probe' ? ' : relevé au prochain « Actualiser ping et WMI »' : ''}.`, { tone: 'ok', life: 3200 });
  });

  load();
  return drawer;
}

// ---------- Probe contract ----------

export async function openProbeContract(ctx, id) {
  const body = surface('acc-contract', loading(5));
  const d = openDialog({ title: 'Contrat de la sonde', icon: 'file', size: 'lg', body });
  try {
    const c = await ctx.call('accueil.probe', { id });
    const sections = new Map();
    for (const l of c.lines ?? []) {
      if (!sections.has(l.section)) sections.set(l.section, []);
      sections.get(l.section).push(l.value);
    }
    body.innerHTML = `<header class="ct-head"><h3>${esc(c.name)}</h3><p>${esc(c.summary)}</p><div class="ct-pills">`
      + `${pill(c.valid ? 'ok' : 'alert', c.valid ? 'Contrat valide' : 'Contrat incomplet', { icon: c.valid ? 'check' : 'alert' })}`
      + `${pill('info', `Droits : ${c.privilegeLevel}`, { icon: 'key' })}${pill(c.costLevel === 'Lourd' ? 'warn' : 'off', `Coût : ${c.costLevel}`, { icon: 'gauge' })}${pill('accent', c.origin, { dot: false })}</div></header>`
      + `${(c.errors ?? []).map((x) => `<p class="ct-msg alert">${glyph('alert')}${esc(x)}</p>`).join('')}${(c.warnings ?? []).map((x) => `<p class="ct-msg warn">${glyph('info')}${esc(x)}</p>`).join('')}`
      + `<div class="ct-sections">${[...sections].map(([title, values], n) => `<section data-j="${n}"><h4>${esc(title)}</h4><ul>${values.map((v) => `<li>${esc(v)}</li>`).join('')}</ul></section>`).join('')}</div>`;
    paint(body);
  } catch (err) {
    body.innerHTML = failed(err, '');
  }
  return d;
}

// ---------- « Comprendre le score » ----------

export function openExplain({ ctx, onTargets }) {
  const host = surface('acc-explain', loading(6));
  const drawer = openDrawer({
    title: 'Comprendre le score', subtitle: 'Effet de chaque contrôle sur la santé du parc de l’OU affichée.', icon: 'gauge', key: 'accueil.explain', width: 820, minWidth: 440, body: host,
    actions: [{ id: 'close', label: 'Fermer', primary: true, run: (d) => d.close() }],
  });
  const STATUS = { Activée: 'ok', 'Selon l’OU': 'info', Désactivée: 'off', Suspendue: 'warn' };
  let revision = null;
  async function load() {
    host.innerHTML = loading(6);
    try {
      const x = await ctx.call('accueil.health.explain');
      revision = x.revision || null;
      const stat = (v, label, cls = '') => `<div class="ex-stat ${cls}"><b class="num" data-count="${v}">0</b><span>${esc(label)}</span></div>`;
      host.innerHTML = `<p class="ex-summary">${esc(x.summary)}</p>
        <div class="ex-stats">${stat(x.population, 'postes du périmètre')}${stat(x.assessed, 'évalués', 'ok')}${stat(x.unknown, 'non évalués', 'off')}${stat(x.activeRules, 'contrôles actifs')}${stat(x.suspendedRules, 'suspendus', 'warn')}${stat(x.disabledRules, 'désactivés', 'off')}${stat(x.maskedMachines, 'postes masqués', 'warn')}</div>
        <ol class="ex-rows">${[...x.rows].sort((a, b) => b.machines - a.machines || b.exclusive - a.exclusive).map((r, n) => `<li class="ex-row" data-j="${Math.min(n, 14)}" data-status="${esc(STATUS[r.status] ?? 'off')}">
          <div class="ex-main"><span class="ex-dot" aria-hidden="true"></span><div class="ex-t"><h4>${esc(r.rule)}</h4><p>${esc([r.effect, r.consequence].map((t) => String(t ?? '').trim().replace(/\s*·\s*$/, '')).filter(Boolean).join(' · '))}</p></div>
            ${pill(STATUS[r.status] ?? 'off', r.status, { size: 'sm' })}
            ${r.targetsKey && r.machines ? `<button class="btn sm ghost num" type="button" data-ex-targets="${esc(r.targetsKey)}" data-label="${esc(r.rule)}">${glyph('monitor')}${plural(r.machines, 'poste', 'postes')}</button>` : `<span class="ex-zero num">${plural(r.machines, 'poste', 'postes')}</span>`}</div>
          <dl class="ex-facts"><div><dt>Postes éligibles</dt><dd>${esc(r.eligible)}</dd></div><div><dt>Seul motif pour</dt><dd>${plural(r.exclusive, 'poste', 'postes')}</dd></div>
            <div><dt>Masqués</dt><dd>${r.maskedKey && r.masked ? `<button class="link-btn" type="button" data-ex-targets="${esc(r.maskedKey)}" data-label="${esc(`${r.rule} · masqués`)}">${plural(r.masked, 'poste', 'postes')}</button>` : plural(r.masked, 'poste', 'postes')}</dd></div>
            <div><dt>Observation</dt><dd>${esc(r.observationState)}${r.missingData ? ' · données manquantes' : ''}</dd></div></dl>
          ${r.missingKey && r.missing ? `<div class="ex-missing"><button class="btn sm ghost" type="button" data-ex-targets="${esc(r.missingKey)}" data-label="${esc(`${r.rule} · collecte manquante`)}" data-tip="Ouvre les postes sans la donnée de ce contrôle ; aucune collecte n’est lancée">${glyph('history')}Voir la collecte manquante · ${plural(r.missing, 'poste', 'postes')}</button></div>` : ''}
          <details class="ex-ev"><summary>D’où vient la donnée</summary><dl><div><dt>Source</dt><dd>${esc(r.evidence.source)}</dd></div><div><dt>Observé</dt><dd>${esc(r.evidence.observed)}</dd></div>
            <div><dt>Valeur</dt><dd>${esc(r.evidence.value)}</dd></div><div><dt>Règle</dt><dd>${esc(r.evidence.rule)}</dd></div><div><dt>Relevé</dt><dd>${esc(r.evidence.collection)}</dd></div></dl></details></li>`).join('')}</ol>
        ${x.policies?.length ? `<section class="ex-policies"><h3>Règles appliquées par OU</h3><table class="acc-table"><thead><tr><th scope="col">Portée</th><th scope="col">Postes</th><th scope="col">Suspendus</th><th scope="col">Seuils</th></tr></thead><tbody>`
          + `${x.policies.map((p) => `<tr><td>${esc(p.scope)}</td><td class="num">${formatNumber(p.machines)}</td><td class="num">${formatNumber(p.suspended)}</td><td>${esc(p.thresholds)}</td></tr>`).join('')}</tbody></table></section>` : ''}`;
      paint(host);
      host.querySelectorAll('[data-count]').forEach((el, n) => countUp(el, Number(el.dataset.count), { delay: 80 + n * 40 }));
    } catch (err) {
      host.innerHTML = failed(err);
    }
  }
  // The sets are opened with the calculation this panel explains: a view recomputed meanwhile refuses them (board.replaced).
  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (t?.closest('[data-acc-retry]')) { load(); return; }
    const b = t?.closest('[data-ex-targets]');
    if (b) { drawer.close(); onTargets(b.dataset.exTargets, b.dataset.label ?? '', revision); }
  });
  load();
  return drawer;
}

// ---------- Provenance and collections ----------

const RUN_TONE = { success: 'ok', partial: 'warn', error: 'alert', cancelled: 'warn' };
const STATE_LABEL = { known: 'Relevés', absent: 'Jamais relevés', notRead: 'Non lus', refused: 'Refusés', expired: 'Périmés', incomplete: 'Incomplets', error: 'En erreur' };

export function openProvenance({ ctx }) {
  const host = surface('acc-prov', loading(6));
  let tabs = null;
  let grid = null;
  const drawer = openDrawer({
    title: 'Provenance des chiffres', subtitle: 'Fraîcheur de la base, mesures des postes actifs et horloges des relevés de l’OU.', icon: 'history', key: 'accueil.provenance', width: 820, minWidth: 440, body: host,
    actions: [{ id: 'close', label: 'Fermer', primary: true, run: (d) => d.close() }],
    onClose: () => { grid?.destroy?.(); tabs?.destroy?.(); },
  });

  const family = (f, label, ic) => {
    const share = f.total ? f.count / f.total : 0;
    return `<article class="pv-fam"><header>${glyph(ic)}<h4>${esc(label)}</h4><span class="num">${formatNumber(f.count)}${NBSP}/${NBSP}${formatNumber(f.total)}</span></header>`
      + `<div class="pv-meter" role="meter" aria-label="${esc(label)}" aria-valuemin="0" aria-valuemax="${f.total}" aria-valuenow="${f.count}"><span data-p="${share.toFixed(4)}"></span></div>`
      + `<p>${esc(f.text)}</p>${Object.keys(f.states ?? {}).length ? `<ul class="pv-states">${Object.entries(f.states).map(([k, v]) => `<li><span>${esc(STATE_LABEL[k] ?? k)}</span><b class="num">${formatNumber(v)}</b></li>`).join('')}</ul>` : ''}</article>`;
  };

  // Same four rows in every clock card (head, state, dates, detail), aligned across the cards by the subgrid of the stylesheet.
  const clock = (c, n) => {
    const t = c.warning ? 'warn' : CLOCK_TONE[c.state] ?? (c.success ? 'ok' : 'off');
    const side = (v, label) => (v ? `<div><dt>${esc(label)}</dt><dd>${esc(localStamp(v.at))}${v.inherited ? ' · relevé d’une OU parente' : ''}${v.controller ? ` · ${esc(v.controller)}` : ''}`
      + `${v.targets != null ? ` · ${formatNumber(v.done ?? 0)}${NBSP}/${NBSP}${formatNumber(v.targets)}` : ''}${v.error ? `<span class="sub">${esc(v.error)}</span>` : ''}</dd></div>` : `<div><dt>${esc(label)}</dt><dd>Jamais</dd></div>`);
    return `<article class="pv-clock" data-tone="${t}" data-j="${n}"><header><span class="pv-ico">${glyph('clock')}</span><h4>${esc(c.label)}</h4>${pill(t, CLOCK_LABEL[c.state] ?? 'Inconnu', { size: 'sm' })}</header>`
      + `<p class="pv-state">${esc(c.text || (c.state === 'success' ? 'Aucun écart signalé.' : CLOCK_LABEL[c.state] ?? ''))}</p>`
      + `<dl>${side(c.success, 'Dernier succès')}${side(c.attempt, 'Dernière tentative')}</dl><p class="pv-detail">${esc(c.detail)}</p></article>`;
  };

  function overview(panel, p) {
    const d = p.directory;
    panel.innerHTML = `<div class="pv-dir" data-tone="${d.partial || d.clockInvalid ? 'warn' : d.at ? 'ok' : 'off'}"><span class="pv-ico big">${glyph('database')}</span><div><h3>Base locale</h3><p>${esc(d.text)}</p>`
      + `<p class="faint">${esc(p.scopeText)} · ${esc(p.computedText)}</p></div></div>`
      + `<h3 class="pv-h">Mesures des postes actifs</h3><div class="pv-fams">${family(p.ping, 'Présence (ping)', 'wifi')}${family(p.console, 'Session ouverte', 'user')}${family(p.inventory, 'Inventaire WMI', 'chip')}</div>`
      + `<p class="pv-note">${glyph('info')}<span>${esc(p.observationsText)}</span></p>`
      + `<h3 class="pv-h">Horloges des relevés</h3><div class="pv-clocks">${p.clocks.map(clock).join('')}</div>`
      + `<p class="pv-note${p.runsWarning ? ' warn' : ''}">${glyph(p.runsWarning ? 'alert' : 'info')}<span>${esc(p.runsText)}</span></p>`
      + `${p.bitLockerAt ? `<p class="pv-note">${glyph('lock')}<span>Présence BitLocker lue le ${esc(localStamp(p.bitLockerAt))}.</span></p>` : ''}`;
    paint(panel);
  }

  function runsPanel(panel) {
    panel.innerHTML = '<div class="pv-grid"></div>';
    grid = createGrid(panel.querySelector('.pv-grid'), {
      label: 'Relevés par OU', key: 'accueil.collections', selection: 'none', height: 'fill', loading: true,
      columns: [
        { id: 'at', label: 'Date', type: 'date', dateStyle: 'datetime', width: 150 },
        { id: 'ou', label: 'OU', width: 160, html: (v, r) => `${esc(v)}${r.subtree ? ' <span class="faint">+ sous-OU</span>' : ''}` },
        { id: 'type', label: 'Relevé', width: 150 },
        { id: 'stateLabel', label: 'État', width: 130, html: (v, r) => pill(RUN_TONE[r.status] ?? 'off', v, { size: 'sm' }) },
        { id: 'postes', label: 'Postes', width: 120 },
        { id: 'success', label: 'Dernier succès', type: 'date', dateStyle: 'datetime', width: 150 },
        { id: 'reason', label: 'Motif', width: 220 },
        { id: 'ouDn', label: 'DN', mono: true, hidden: true, width: 300 },
      ],
      empty: { icon: 'history', title: 'Aucun relevé', text: 'Aucune lecture ni collecte enregistrée pour ce domaine.' },
    });
    ctx.call('accueil.collections').then((r) => grid.setRows((r.rows ?? []).map((x, n) => ({ ...x, id: `${x.at}-${n}` }))))
      .catch((err) => grid.setError(reported(err)));
  }

  async function load() {
    host.innerHTML = loading(6);
    let p;
    try {
      p = await ctx.call('accueil.provenance');
    } catch (err) {
      host.innerHTML = failed(err);
      return;
    }
    host.innerHTML = '<div class="pv-tabs"></div>';
    tabs = createTabs(host.querySelector('.pv-tabs'), {
      label: 'Provenance', key: 'accueil.provenance',
      tabs: [
        { id: 'view', label: 'Vue affichée', icon: 'eye', render: (panel) => overview(panel, p) },
        { id: 'runs', label: 'Relevés par OU', icon: 'history', render: runsPanel },
      ],
    });
  }
  host.addEventListener('click', (e) => { if (e.target instanceof Element && e.target.closest('[data-acc-retry]')) load(); });
  load();
  return drawer;
}

// ---------- Analysis: comparison, cross tables, manual snapshot ----------

const VERDICT_TONE = { Stable: 'ok', Réel: 'info', Périmètre: 'warn', Couverture: 'warn', Règles: 'warn', Mixte: 'warn', Limitée: 'off' };
const FACTOR_TONE = { Inchangé: 'ok', Modifié: 'warn', Inconnu: 'off' };

export function openAnalysis({ ctx, onTargets, onSnapshot }) {
  const host = surface('acc-analysis', loading(6));
  let tabs = null;
  let list = null;
  const drawer = openDrawer({
    title: 'Analyse du parc', subtitle: 'Comparer deux relevés, croiser les dimensions, garder un instantané daté.', icon: 'split', key: 'accueil.analysis', width: 900, minWidth: 460, body: host,
    actions: [{ id: 'close', label: 'Fermer', primary: true, run: (d) => d.close() }],
    onClose: () => tabs?.destroy?.(),
  });

  // The engine label already dates daily and current readings; a manual snapshot gets its date and time.
  const option = (s) => {
    const time = localStamp(s.computedAt);
    const suffix = s.kind === 'manual' ? ` · ${time}` : s.kind === 'daily' ? ` · ${time.slice(-5)}` : '';
    return `<option value="${esc(s.id)}">${esc(s.label + suffix)}</option>`;
  };

  function comparePanel(panel) {
    const items = list.items ?? [];
    if (items.length < 2) {
      panel.innerHTML = `<div class="acc-empty wide">${glyph('calendar')}<h3>Un seul relevé</h3><p>Deux relevés au moins sont nécessaires : un instantané quotidien est gardé au premier calcul de chaque jour, et « Instantané » en garde un à la demande.</p></div>`;
      return;
    }
    panel.innerHTML = `<form class="an-pick"><label><span>Avant</span><select class="input acc-select" name="before">${items.map(option).join('')}</select></label>
      <span class="an-arrow" aria-hidden="true">${glyph('chevronRight')}</span>
      <label><span>Après</span><select class="input acc-select" name="after">${items.map(option).join('')}</select></label>
      <button class="btn primary sm" type="submit">${glyph('split')}Comparer</button></form><div class="an-result" aria-live="polite"></div>`;
    const form = panel.querySelector('form');
    // Default comparison: the daily reading of a week ago (or the oldest one) against the current view.
    const weekAgo = new Date(Date.now() - 7 * 86_400_000).toISOString().slice(0, 10);
    const daily = items.filter((x) => x.kind !== 'current');
    form.before.value = (daily.find((x) => String(x.day) <= weekAgo) ?? daily.at(-1) ?? items[0]).id;
    form.after.value = items.find((x) => x.kind === 'current')?.id ?? items.at(-1).id;
    const out = panel.querySelector('.an-result');
    const run = async () => {
      out.innerHTML = loading(4);
      try {
        const c = await ctx.call('accueil.analysis.compare', { before: form.before.value, after: form.after.value });
        const t = VERDICT_TONE[c.category] ?? 'info';
        out.innerHTML = `<div class="an-verdict" data-tone="${t}"><span class="an-badge">${esc(c.category)}</span><p>${esc(c.summary)}</p>${c.swapped ? '<p class="faint">Relevés remis dans l’ordre chronologique.</p>' : ''}</div>`
          + `<ul class="an-factors">${c.factors.map((f, n) => `<li data-j="${n}" data-tone="${FACTOR_TONE[f.status] ?? 'off'}"><b>${esc(f.factor)}</b><span>${esc(f.text)}</span></li>`).join('')}</ul>`
          + `<table class="acc-table an-table"><thead><tr><th scope="col">Mesure</th><th scope="col">${esc(c.beforeLabel)}</th><th scope="col">${esc(c.afterLabel)}</th><th scope="col">Écart</th></tr></thead><tbody>`
          + `${c.rows.map((r) => `<tr><th scope="row">${esc(r.measure)}</th><td class="num">${esc(r.before)}</td><td class="num">${esc(r.after)}</td><td class="num delta-cell${/^\+/.test(r.delta) ? ' up' : /^[-−]/.test(r.delta) ? ' down' : ''}">${esc(r.delta)}</td></tr>`).join('')}</tbody></table>`
          + `${c.limits?.length ? `<ul class="an-limits">${c.limits.map((l) => `<li>${glyph('info')}${esc(l)}</li>`).join('')}</ul>` : ''}`;
        paint(out);
      } catch (err) {
        out.innerHTML = `<div class="acc-err" role="alert">${glyph('alert')}<span>${esc(reported(err))}</span></div>`;
      }
    };
    form.addEventListener('submit', (e) => { e.preventDefault(); run(); });
    run();
  }

  function pivotPanel(panel) {
    const tables = list.tables ?? [];
    panel.innerHTML = `<form class="an-pick"><label><span>Tableau</span><select class="input acc-select" name="table">${tables.map((t) => `<option value="${esc(t.id)}">${esc(t.title)}</option>`).join('')}</select></label>
      <label class="grow"><span>Filtrer les lignes</span><input class="input" name="filter" type="search" maxlength="100" placeholder="Texte contenu dans le libellé" autocomplete="off"></label>
      <button class="btn primary sm" type="submit">${glyph('columns')}Afficher</button></form>
      <div class="an-view" role="group" aria-label="Présentation du tableau croisé"><button class="btn sm ghost" type="button" data-an-view="matrix" aria-pressed="true">${glyph('columns')}Matrice</button>
        <button class="btn sm ghost" type="button" data-an-view="list" aria-pressed="false">${glyph('rows')}Liste des cellules</button>
        <button class="btn sm ghost" type="button" data-an-csv>${glyph('csv')}Copier en CSV</button></div>
      <div class="an-matrix" aria-live="polite"></div>`;
    const form = panel.querySelector('form');
    const out = panel.querySelector('.an-matrix');
    let matrix = null;
    let view = 'matrix';
    // Same rule as the grid of the kit (KIT § 4.1): a cell starting with = + - @ (or a tab, a carriage return) is neutralized
    // by an apostrophe, labels coming from the directory and WMI (OU, model, BIOS version) never become a formula.
    const csvCell = (v) => {
      const raw = String(v ?? '');
      const safe = /^[=+\-@\t\r]/.test(raw) && !/^-?\d+([.,]\d+)?$/.test(raw) ? `'${raw}` : raw;
      // The quote is written \x22 in the patterns: a plain one would read as the start of a text for the spacing check.
      return /[;\x22\n\r]/.test(safe) ? `"${safe.replace(/\x22/g, '""')}"` : safe;
    };
    // Semicolon separated, as the French spreadsheets expect; totals included.
    const csv = (m) => [
      [`${m.rowTitle} \\ ${m.columnTitle}`, ...m.columns, 'Total'],
      ...m.rows.map((r) => [r.label, ...r.counts, r.total]),
      ['Total', ...m.columnTotals, m.grandTotal],
    ].map((line) => line.map(csvCell).join(';')).join('\r\n');
    function listView(m) {
      const cells = m.rows.flatMap((r) => r.counts.map((v, n) => ({ label: `${r.label} · ${m.columns[n]}`, value: v, key: r.keys[n] }))).filter((c) => c.value > 0)
        .sort((a, b) => b.value - a.value);
      const top = Math.max(1, ...cells.map((c) => c.value));
      return `<ul class="an-list">${cells.map((c, n) => `<li data-j="${Math.min(n, 14)}"><button class="an-li" type="button" data-an-key="${esc(c.key ?? '')}" data-label="${esc(c.label)}">`
        + `<span class="name">${esc(c.label)}</span><span class="bar" aria-hidden="true"><span data-p="${(c.value / top).toFixed(4)}"></span></span><b class="num">${formatNumber(c.value)}</b></button></li>`).join('')}</ul>`;
    }
    const run = async () => {
      out.innerHTML = loading(5);
      try {
        const args = { table: form.table.value };
        if (form.filter.value.trim()) args.filter = form.filter.value.trim();
        matrix = await ctx.call('accueil.analysis.pivots', args);
        const m = matrix;
        const top = Math.max(1, ...m.rows.flatMap((r) => r.counts));
        const cell = (v, key, label) => (v
          ? `<td><button class="an-cell" type="button" data-an-key="${esc(key ?? '')}" data-label="${esc(label)}" data-p="${(v / top).toFixed(4)}">${formatNumber(v)}</button></td>`
          : '<td class="zero">·</td>');
        out.innerHTML = `<p class="an-cap">${esc(m.title)} · ${plural(m.total, 'poste', 'postes')}${m.folded ? ` · ${plural(m.folded, 'colonne regroupée dans « Autres colonnes »', 'colonnes regroupées dans « Autres colonnes »')}` : ''}${m.filtered ? ' · filtré' : ''}</p>`
          + (view === 'list' ? listView(m) : `<div class="an-scroll"><table class="acc-table an-pivot"><thead><tr><th scope="col">${esc(m.rowTitle)} \\ ${esc(m.columnTitle)}</th>${m.columns.map((c) => `<th scope="col">${esc(c)}</th>`).join('')}<th scope="col">Total</th></tr></thead><tbody>`
          + m.rows.map((r) => `<tr><th scope="row">${esc(r.label)}</th>${r.counts.map((v, n) => cell(v, r.keys[n], `${r.label} · ${m.columns[n]}`)).join('')}`
            + `<td class="tot"><button class="an-cell tot" type="button" data-an-key="${esc(r.totalKey)}" data-label="${esc(r.label)}">${formatNumber(r.total)}</button></td></tr>`).join('')
          + `</tbody><tfoot><tr><th scope="row">Total</th>${m.columnTotals.map((v, n) => `<td><button class="an-cell tot" type="button" data-an-key="${esc(m.columnKeys[n])}" data-label="${esc(m.columns[n])}">${formatNumber(v)}</button></td>`).join('')}`
          + `<td class="tot"><button class="an-cell tot grand" type="button" data-an-key="${esc(m.grandKey)}" data-label="${esc(m.title)}">${formatNumber(m.grandTotal)}</button></td></tr></tfoot></table></div>`)
          + `<p class="pv-note">${glyph('info')}<span>Chaque poste est dans une seule cellule ; un clic ouvre ses postes exacts.</span></p>`;
        paint(out);
      } catch (err) {
        out.innerHTML = `<div class="acc-err" role="alert">${glyph('alert')}<span>${esc(reported(err))}</span></div>`;
      }
    };
    form.addEventListener('submit', (e) => { e.preventDefault(); run(); });
    form.table.addEventListener('change', run);
    panel.querySelector('.an-view').addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('button') : null;
      if (!b) return;
      if (b.dataset.anCsv !== undefined) { if (matrix) copyWithToast(ctx, csv(matrix), `Tableau « ${matrix.title} » copié au format CSV.`); return; }
      view = b.dataset.anView;
      panel.querySelectorAll('[data-an-view]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
      run();
    });
    out.addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-an-key]') : null;
      if (b && b.dataset.anKey && matrix) { drawer.close(); onTargets(b.dataset.anKey, b.dataset.label ?? '', matrix.revision); }
    });
    run();
  }

  function snapshotPanel(panel) {
    const manual = (list.items ?? []).filter((x) => x.kind === 'manual');
    panel.innerHTML = `<div class="an-snap"><span class="an-snap-ico">${glyph('pin')}</span><div><h3>Instantané daté de la vue actuelle</h3>
      <p>À prendre avant et après une campagne (migration, nettoyage)${NBSP}: il garde les chiffres et les empreintes du périmètre, de la couverture et des règles, pour une comparaison honnête. Rien n’est lu sur le réseau ; il est gardé dans les préférences locales de ce poste (vingt au plus).</p></div></div>
      <form class="an-pick"><label class="grow"><span>Libellé</span><input class="input" name="label" type="text" maxlength="80" placeholder="Avant la migration Windows 11" autocomplete="off"></label>
      <button class="btn primary sm" type="submit">${glyph('pin')}Prendre l’instantané</button></form>
      <h4 class="pv-h">Instantanés manuels</h4>${manual.length ? `<ul class="an-snaps">${manual.map((s) => `<li>${glyph('pin')}<b>${esc(s.label)}</b><span>${esc(localStamp(s.computedAt))}</span></li>`).join('')}</ul>` : '<p class="faint">Aucun instantané manuel pour cette OU.</p>'}`;
    const form = panel.querySelector('form');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const b = form.querySelector('button');
      b.disabled = true;
      try {
        const snap = await ctx.call('accueil.snapshot.take', form.label.value.trim() ? { label: form.label.value.trim() } : {});
        ctx.toast(`Instantané «${NBSP}${snap.label}${NBSP}» enregistré${NBSP}: il apparaît dans «${NBSP}Comparer${NBSP}».`, { tone: 'ok' });
        onSnapshot?.(snap);
        await reload('snapshot');
      } catch (err) {
        ctx.toast(reported(err), { tone: 'alert' });
        b.disabled = false;
      }
    });
  }

  async function reload(selected) {
    host.innerHTML = loading(6);
    try {
      list = await ctx.call('accueil.analysis.snapshots');
    } catch (err) {
      host.innerHTML = failed(err);
      return;
    }
    tabs?.destroy?.();
    host.innerHTML = '<div class="an-tabs"></div>';
    tabs = createTabs(host.querySelector('.an-tabs'), {
      label: 'Analyse du parc', key: 'accueil.analysis', selected,
      tabs: [
        { id: 'compare', label: 'Comparer', icon: 'split', count: list.items?.length ?? 0, render: comparePanel },
        { id: 'pivots', label: 'Tableaux croisés', icon: 'columns', count: list.tables?.length ?? 0, render: pivotPanel },
        { id: 'snapshot', label: 'Instantané', icon: 'pin', render: snapshotPanel },
      ],
    });
  }
  host.addEventListener('click', (e) => { if (e.target instanceof Element && e.target.closest('[data-acc-retry]')) reload(); });
  reload();
  return drawer;
}

