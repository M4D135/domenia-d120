// Schéma de l’annuaire (Domenia 1 points 28 and 29, SCH-001 to SCH-008): hero with the status of the schema read in this
// session and its overview, the catalog of classes and attributes with their detail (master-detail), and the workbench that
// analyses the cost of an LDAP filter on this workstation. The schema is read once, on an explicit gesture (schema.read,
// NetworkRead in directory mode), kept in memory for the session and never used for another session or domain; nothing changes
// the schema, nothing reads an object value. Contract: docs/ops/schema.md.
//
// Parameters: vue=classes|attributs · classe=<lDAPDisplayName> · attribut=<lDAPDisplayName> · filtre=<filtre LDAP> ·
// lire=1 (simulation only: reads the fictitious schema at once, for captures and scenarios; in directory mode the read
// always waits for the click).
import { onEvent } from '../bridge.js';
import { openDrawer } from '../kit/drawer.js';
import { applyVars, reveal, countUp, donut, toast, announce } from '../ui.js';
import { glyph, esc, int, count, NBSP, errText, sk, shortDateTime, KIND_SERIES } from './schema/model.js';
import { createCatalog } from './schema/catalog.js';
import { createWorkbench } from './schema/workbench.js';

/** The screen has its own stylesheet (css/pages/schema.css), loaded by the router. */
export const stylesheet = true;

const ORBS = '<div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>';
const LEAD = 'Classes et attributs lus une fois sur le contrôleur de la session : types, nombre de valeurs, index et catalogue global. '
  + 'Domenia ne modifie jamais le schéma et ne lit aucune valeur d’objet.';

function skeleton() {
  return `<div class="page sch">
    <section class="hero sch-hero reveal" data-slot="hero"><span class="glow-ring hero-ring" aria-hidden="true"></span>${ORBS}
      <div class="sch-hero-grid"><div class="sch-hero-main"><div class="sch-sk-stack">${sk('w25')}${sk('sch-sk-title w45')}${sk('w85')}${sk('w70')}</div></div>
        <aside class="sch-overview"><div class="sch-sk-stack">${sk('sch-sk-ring')}${sk('w70')}${sk('w55')}</div></aside></div>
    </section>
    <div class="sch-sec reveal"><h2>Catalogue</h2><span class="sec-note">Classes et attributs du schéma lu</span></div>
    <section class="card sch-catalog reveal" data-slot="catalog"><div class="sch-sk-stack">${sk('w40')}${sk('sch-sk-block w100')}</div></section>
    <div class="sch-sec reveal"><h2>Analyser un filtre LDAP</h2><span class="sec-note">Sur ce poste, sans interroger l’annuaire</span></div>
    <section class="card sch-workbench reveal" id="sch-workbench" data-slot="workbench"></section>
  </div>`;
}

function statusChips(status, app) {
  const chips = [];
  if (status.read) {
    chips.push(`<span class="chip ${status.truncated ? 'warn' : 'ok'}" data-tip="${esc(status.text)}">${glyph(status.truncated ? 'alert' : 'check')}${esc(status.truncated ? 'Lecture incomplète' : 'Schéma lu')}</span>`);
    chips.push(`<span class="chip" data-tip="Contrôleur qui a répondu">${glyph('server')}${esc(status.server ?? '—')}</span>`);
    chips.push(`<span class="chip" data-tip="Date de la lecture, gardée pour cette session">${glyph('clock')}${esc(shortDateTime(status.readAt))}</span>`);
  } else {
    chips.push(`<span class="chip${status.lastError ? ' alert' : ''}">${glyph(status.lastError ? 'alert' : 'info')}${esc(status.lastError ? 'Dernière lecture en échec' : 'Schéma non lu')}</span>`);
  }
  if (status.simulated || app?.mode === 'simulation') {
    chips.push(`<span class="chip info" data-tip="Schéma de l’annuaire fictif : aucune connexion à un contrôleur">${glyph('sparkles')}Annuaire fictif</span>`);
  }
  chips.push(`<span class="chip" data-tip="Aucune écriture possible depuis cet écran${NBSP}: Domenia ne modifie jamais le schéma et ne lit aucune valeur d’objet.">${glyph('lock')}Lecture seule</span>`);
  return chips.map((c, n) => c.replace('class="chip', `data-j="${n}" class="chip`)).join('');
}

function overviewMarkup(status) {
  if (!status.read) {
    const l = status.limits;
    return `<aside class="sch-overview unread" aria-label="Ce que la lecture fera">
      <div class="sch-ov-k">${glyph('shield')}Une lecture bornée, sur votre geste</div>
      <div class="sch-limits">
        <div class="sch-limit" data-j="0"><b>${esc(int(l.attributes))}</b><span>attributs au plus</span></div>
        <div class="sch-limit" data-j="1"><b>${esc(int(l.classes))}</b><span>classes au plus</span></div>
        <div class="sch-limit" data-j="2"><b>${esc(int(l.seconds))}${NBSP}s</b><span>au plus</span></div>
      </div>
      <ul class="sch-promise">
        <li data-j="0">${glyph('check')}<span>Aucune valeur d’objet n’est lue.</span></li>
        <li data-j="1">${glyph('check')}<span>Le schéma n’est jamais modifié.</span></li>
        <li data-j="2">${glyph('check')}<span>Gardé en mémoire pour cette session, avec son contrôleur et sa date.</span></li>
        <li data-j="3">${glyph('check')}<span>Jamais utilisé pour une autre session ni un autre domaine.</span></li>
      </ul>
    </aside>`;
  }
  const st = status.statistics;
  const segments = st.syntaxes.map((s) => ({ value: s.count, cls: KIND_SERIES[s.id] ?? 'sx', key: s.id }));
  const categories = Object.fromEntries(st.categories.map((c) => [c.id, c.count]));
  // Figures on one line each: icon, number, words (« 73 au catalogue global »); the detail in the tip.
  const stat = (j, icon, label, value, { tip = '', tone = '', bar = null, countTo = null } = {}) => `<div class="sch-stat-mini${tone ? ` ${tone}` : ''}" data-j="${j}"${tip ? ` data-tip="${esc(tip)}"` : ''}>
      <span class="ico" aria-hidden="true">${glyph(icon)}</span><b${countTo === null ? '' : ` data-count="${countTo}"`}>${countTo === null ? esc(value) : '0'}</b><span class="k">${esc(label)}</span>
      ${bar === null ? '' : `<span class="bar" aria-hidden="true"><span data-p="${bar.toFixed(3)}"></span></span>`}
    </div>`;
  return `<aside class="sch-overview" aria-label="Vue d’ensemble du schéma lu">
    <div class="sch-ov-top">
      ${donut(segments, { total: status.attributes, center: `<b class="num" data-count="${status.attributes}">0</b><span>attributs</span>`, label: `Familles de syntaxe des ${status.attributes} attributs`, size: 'sch-ring' })}
      <ul class="sch-ov-legend" aria-label="Familles de syntaxe">${st.syntaxes.map((s, j) => `<li data-j="${j}"><span class="sw ${KIND_SERIES[s.id] ?? 'sx'}" aria-hidden="true"></span><span class="name">${esc(s.label)}</span><b>${esc(int(s.count))}</b></li>`).join('')}</ul>
    </div>
    <div class="sch-ov-stats">
      ${stat(0, 'layers', status.classes > 1 ? 'classes' : 'classe', int(status.classes), { countTo: status.classes, tip: `${int(categories.structural ?? 0)} structurelles, ${int(categories.auxiliary ?? 0)} auxiliaires, ${int(categories.abstract ?? 0)} abstraites, ${int(categories.class88 ?? 0)} de 1988` })}
      ${stat(1, 'zap', 'indexés', `${String(st.indexedPercent).replace('.', ',')}${NBSP}%`, { tone: 'ok', bar: st.indexedPercent / 100, tip: `${count(st.indexed, 'attribut indexé', 'attributs indexés')} sur ${int(status.attributes)}` })}
      ${stat(2, 'domain', 'au catalogue global', int(st.inGlobalCatalog), { countTo: st.inGlobalCatalog, tip: 'Attributs répliqués dans le catalogue global de la forêt' })}
      ${stat(3, 'lock', st.confidential > 1 ? 'confidentiels' : 'confidentiel', int(st.confidential), { tone: st.confidential ? 'warn' : '', tip: 'Attributs lisibles seulement avec un droit particulier' })}
      ${stat(4, 'sparkles', st.constructed > 1 ? 'calculés' : 'calculé', int(st.constructed), { tip: `Attributs calculés par le contrôleur à la lecture${NBSP}: jamais un critère de filtre` })}
      ${stat(5, 'alert', st.defunct > 1 ? 'obsolètes' : 'obsolète', int(st.defunct), { tone: st.defunct ? 'alert' : '', tip: 'Attributs et classes désactivés dans le schéma' })}
    </div>
  </aside>`;
}

function heroMarkup(status, app, reading) {
  const readLabel = status.read ? 'Relire le schéma' : 'Lire le schéma';
  // The status sentence repeats the chips once read: shown only when it says more (incomplete read, last failure).
  const sentence = status.lastError ?? (!status.read || status.truncated ? status.text : '');
  return `<div class="sch-hero-grid${status.read ? ' read' : ''}">
    <div class="sch-hero-main">
      <div class="eyebrow">${glyph('tree')}<span>Annuaire · lecture seule</span></div>
      <h1 class="gradient-text">Schéma de l’annuaire</h1>
      ${status.read ? '' : `<p class="lead">${esc(LEAD)}</p>`}
      <div class="chips">${statusChips(status, app)}</div>
      ${sentence ? `<p class="sch-status-text${status.lastError ? ' alert' : status.truncated ? ' warn' : ''}">${esc(sentence)}</p>` : ''}
      <div class="hero-row">
        <button class="btn primary" type="button" data-hero="read"${reading ? ' aria-busy="true" aria-disabled="true"' : ''} data-tip="Lecture explicite des définitions du schéma sur le contrôleur de la session (lecture réseau en mode annuaire)">
          ${reading ? '<span class="k-spin" aria-hidden="true"></span>Lecture en cours…' : `${glyph(status.read ? 'refresh' : 'download')}${readLabel}<span class="sch-net" aria-hidden="true">${glyph('wifi')}</span>`}</button>
        <button class="btn" type="button" data-hero="filter">${glyph('gauge')}Analyser un filtre</button>
        <button class="btn ghost icon" type="button" data-hero="help" aria-label="Comprendre le schéma" data-tip="Comprendre le schéma">${glyph('info')}</button>
      </div>
    </div>
    ${overviewMarkup(status)}
  </div>`;
}

const HELP = [
  ['zap', 'Indexé', 'Le contrôleur répond à une égalité ou à un début de valeur à partir de l’index, sans examiner chaque objet.'],
  ['search', 'Sous-chaîne indexée', 'Un joker en tête (*valeur) utilise aussi l’index ; sans lui, il examine chaque objet du périmètre.'],
  ['domain', 'Catalogue global', 'L’attribut est répliqué dans le catalogue global : une recherche sur toute la forêt le voit.'],
  ['lock', 'Confidentiel', 'Lisible seulement avec un droit particulier : sans lui, un filtre sur cet attribut ne retient aucun objet.'],
  ['sparkles', 'Calculé', 'Calculé par le contrôleur à la lecture : il se lit, il ne sert jamais de critère de filtre.'],
  ['link', 'Lié', 'Lien direct (pair) et lien retour (impair) : le contrôleur tient le lien retour à jour tout seul.'],
  ['layers', 'objectClass ou objectCategory', 'objectClass=user retient aussi les ordinateurs, qui en dérivent ; objectCategory=person cible les personnes et écarte les ordinateurs.'],
];

function openHelp() {
  openDrawer({
    title: 'Comprendre le schéma', subtitle: 'Index, catalogue global, attributs calculés', icon: 'info', width: 460, key: 'schema.aide',
    body: `<div class="sch-help" data-page="schema"><ul>${HELP.map(([icon, title, text]) => `<li><span class="ico">${glyph(icon)}</span><div><b>${esc(title)}</b><p>${esc(text)}</p></div></li>`).join('')}</ul>
      <p class="sch-help-foot">${glyph('shield')}<span>Lecture seule${NBSP}: Domenia ne modifie jamais le schéma, et l’analyse d’un filtre se fait sur ce poste, sans rien envoyer au contrôleur.</span></p></div>`,
    actions: [{ id: 'close', label: 'Fermer', run: (p) => p.close() }],
  });
}

export function render(main, ctx) {
  main.innerHTML = skeleton();
  const page = main.querySelector('.page');
  const hero = /** @type {HTMLElement} */ (page.querySelector('.sch-hero'));
  let alive = true;
  let status = null;
  let session = null;
  let app = null;
  let reading = false;
  const routeParams = { ...ctx.params };
  const stops = [];
  let workbench = null;

  stops.push(reveal(page));

  function remember(change) {
    Object.assign(routeParams, change);
    delete routeParams.lire;
    for (const [k, v] of Object.entries(routeParams)) if (v === null || v === undefined || v === '') delete routeParams[k];
    try { history.replaceState(null, '', ctx.link('schema', routeParams)); } catch (err) { console.error(err); }
  }

  const catalog = createCatalog(page.querySelector('.sch-catalog'), ctx, {
    kind: ctx.params.vue === 'attributs' ? 'attributes' : 'classes',
    className: ctx.params.classe ?? null,
    attributeName: ctx.params.attribut ?? null,
    onRoute: (change) => remember(change),
    onSelected: () => workbench?.refreshInsert(),
    onAnalyze: (filter) => { workbench.setFilter(filter, { focus: false }); scrollToWorkbench(); },
    onInsert: (name) => { workbench.insert(name); scrollToWorkbench(); },
  });
  stops.push(() => catalog.destroy());

  workbench = createWorkbench(page.querySelector('.sch-workbench'), ctx, {
    rootDn: () => session?.domain?.rootDn ?? '',
    status: () => status,
    selected: () => catalog.chosen(),
    onAttribute: (name) => { catalog.goToAttribute(name); page.querySelector('.sch-catalog')?.scrollIntoView({ behavior: 'smooth', block: 'start' }); },
  });
  stops.push(() => workbench.destroy());

  function scrollToWorkbench() {
    page.querySelector('.sch-workbench')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function paintHero() {
    hero.querySelector('.sch-hero-grid')?.remove();
    hero.insertAdjacentHTML('beforeend', heroMarkup(status, app, reading));
    hero.classList.toggle('compact', !!status?.read);
    applyVars(hero);
    hero.querySelectorAll('[data-count]').forEach((el) => countUp(el, Number(el.getAttribute('data-count')) || 0, { delay: 200 }));
  }

  async function read() {
    if (reading) return;
    reading = true;
    paintHero();
    catalog.setStage('context');
    const off = onEvent('schema.read:stage', (data) => { if (alive && data?.stage) catalog.setStage(data.stage); });
    try {
      status = await ctx.call('schema.read');
      if (!alive) return;
      reading = false;
      catalog.setStage(null);
      paintHero();
      await catalog.setStatus(status);
      workbench.refreshInsert();
      workbench.refreshHint();
      if (workbench.value().trim()) workbench.analyze({ quiet: true });
      // The hero and the catalog show the result: no notification over the detail, the screen reader hears it.
      const text = `Schéma lu${NBSP}: ${count(status.classes, 'classe', 'classes')}, ${count(status.attributes, 'attribut', 'attributs')}.`;
      if (status.truncated) toast(`${text} Lecture incomplète${NBSP}: limite atteinte.`, { tone: 'warn', life: 3600 });
      else announce(text);
    } catch (err) {
      if (!alive) return;
      reading = false;
      catalog.setStage(null);
      try { status = await ctx.call('schema.status'); } catch { /* keep the previous status */ }
      if (!alive) return;
      paintHero();
      if (!status?.read) catalog.readFailed({ ...status, lastError: status?.lastError ?? errText(err) });
      workbench.refreshHint();
      toast(errText(err, 'Lecture du schéma impossible.'), { tone: 'alert' });
    } finally {
      off();
    }
  }

  hero.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-hero]') : null;
    if (!b || b.getAttribute('aria-disabled') === 'true') return;
    const what = b.getAttribute('data-hero');
    if (what === 'read') read();
    else if (what === 'filter') { scrollToWorkbench(); setTimeout(() => workbench.focus(), 350); }
    else if (what === 'help') openHelp();
  });

  (async () => {
    try {
      [status, session, app] = await Promise.all([
        ctx.call('schema.status'),
        ctx.call('session.info').catch(() => null),
        Promise.resolve(ctx.app).catch(() => null),
      ]);
      if (!alive) return;
      paintHero();
      await catalog.setStatus(status);
      workbench.refreshHint();
      if (ctx.params.filtre) workbench.setFilter(ctx.params.filtre);
      // lire=1: in simulation only (captures, scenarios); the directory mode always waits for the click.
      if (ctx.params.lire === '1' && !status.read) {
        if (app?.mode === 'simulation') read();
        else toast('Lecture demandée par l’adresse : cliquez « Lire le schéma » pour la lancer.', { tone: 'info' });
      }
    } catch (err) {
      if (!alive) return;
      hero.querySelector('.sch-hero-grid')?.remove();
      hero.insertAdjacentHTML('beforeend', `<div class="sch-hero-grid"><div class="sch-hero-main"><div class="eyebrow">${glyph('tree')}<span>Annuaire · lecture seule</span></div>
        <h1 class="gradient-text">Schéma de l’annuaire</h1><p class="lead" role="alert">${esc(errText(err, 'État du schéma illisible.'))}</p>
        <div class="hero-row"><button class="btn" type="button" data-retry>${glyph('refresh')}Réessayer</button></div></div></div>`);
      hero.querySelector('[data-retry]')?.addEventListener('click', () => ctx.navigate('schema', routeParams));
      page.querySelector('.sch-catalog').innerHTML = '';
    }
  })();

  return () => {
    alive = false;
    stops.forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
  };
}
