// Paramètres: hero with the health of the application, a sliding section rail and one section at a time (Apparence,
// Connexion et périmètre, Données et cache, Budgets réseau, Journaux, Préférences, Configuration, Démonstration, À propos).
// Contract: docs/ops/parametres.md. The address carries the section (#/parametres?section=donnees&onglet=sauvegardes) and
// an open state for links and captures (&ouvrir=ou|apercu|plan|import|fenetre|diagnostic). Nothing reads the network:
// every operation of the screen is local (preferences, local base, files of the application).
import { icon } from '../icons.js';
import { glyph } from '../kit/glyphs.js';
import { esc, reveal, relTime, announce, fold, motionReduced } from '../ui.js';
import { makeCall, paint, syncSegments, int, size, NBSP, reported } from './parametres/common.js';

/** The screen has its own stylesheet (css/pages/parametres.css), loaded by the router. */
export const stylesheet = true;

const SECTIONS = [
  { id: 'apparence', label: 'Apparence', desc: 'Thème, animations, zoom, densité', icon: 'sparkles', tone: 'accent', load: () => import('./parametres/apparence.js') },
  { id: 'connexion', label: 'Connexion et périmètre', desc: 'Compte, droits, OU de travail', icon: 'user', tone: 'info', load: () => import('./parametres/connexion.js') },
  { id: 'donnees', label: 'Données et cache', desc: 'Base locale, sauvegardes, conservation', icon: 'database', tone: 'ok', load: () => import('./parametres/donnees.js') },
  { id: 'collecte', label: 'Budgets réseau', desc: 'Profil, fraîcheur, fenêtre, plafonds', icon: 'wifi', tone: 'warn', load: () => import('./parametres/collecte.js') },
  { id: 'journaux', label: 'Journaux', desc: 'Journal technique et opérations', icon: 'file', tone: 'info', load: () => import('./parametres/journaux.js') },
  { id: 'preferences', label: 'Préférences', desc: 'Exporter, importer, réinitialiser', icon: 'sliders', tone: 'accent', load: () => import('./parametres/preferences.js') },
  { id: 'configuration', label: 'Configuration', desc: 'Réglages de l’administrateur', icon: 'tools', tone: 'off', load: () => import('./parametres/configuration.js') },
  { id: 'demonstration', label: 'Démonstration', desc: 'Mode simulation et garanties', icon: 'play', tone: 'accent', load: () => import('./parametres/demonstration.js') },
  { id: 'apropos', label: 'À propos', desc: 'Version, compatibilité, composants', icon: 'info', tone: 'info', load: () => import('./parametres/apropos.js') },
];

// Settings index of the search box: label, words, section and the row to light up (data-setting).
const INDEX = [
  ['Thème clair, sombre ou contraste élevé', 'theme couleurs sombre clair contraste windows', 'apparence', 'theme'],
  ['Animations riches, réduites ou suivre Windows', 'animations mouvement réduire', 'apparence', 'motion'],
  ['Zoom de l’interface', 'zoom taille agrandir réduire ctrl molette', 'apparence', 'zoom'],
  ['Densité des listes', 'densite compact confort lignes', 'apparence', 'density'],
  ['Profil Essentiel ou Expert', 'profil expert essentiel avance', 'apparence', 'profile'],
  ['Menu replié en icônes', 'menu navigation replier ctrl b', 'apparence', 'nav'],
  ['Panneau d’aide', 'aide panneau help', 'apparence', 'help'],
  ['Se souvenir de mon identifiant', 'identifiant connexion login coffre', 'connexion', 'remember'],
  ['OU de travail', 'ou perimetre racine domaine scope', 'connexion', 'scope'],
  ['Sauvegarder maintenant', 'sauvegarde backup copie', 'donnees', 'backup'],
  ['Sauvegarde automatique', 'sauvegarde planifiee automatique copies', 'donnees', 'schedule'],
  ['Conservation des mesures', 'conservation retention purger anciennes mesures jours', 'donnees', 'retention'],
  ['Purger des données locales', 'purge vider index observations historique', 'donnees', 'purge'],
  ['Mesurer le stockage', 'mesurer taille espace disque usage', 'donnees', 'measure'],
  ['Contrôler l’intégrité de la base', 'integrite controle quick_check sqlite', 'donnees', 'integrity'],
  ['Déplacer ou restaurer la base', 'deplacer restaurer bascule assistant', 'donnees', 'assistant'],
  ['Politique des données locales', 'politique donnees telemetrie emplacement', 'donnees', 'policy'],
  ['Reprendre les données de Domenia 1', 'reprise migration anciennes donnees domenia 1', 'donnees', 'legacy'],
  ['Profil de collecte', 'profil reseau lent depannage standard', 'collecte', 'profile'],
  ['Durées de fraîcheur', 'fraicheur reutilisation duree ping inventaire', 'collecte', 'freshness'],
  ['Fenêtre de collecte', 'fenetre horaires heures creuses travaux de fond', 'collecte', 'window'],
  ['Plafond des widgets et relevés', 'plafond postes parallele concurrence wmi essais', 'collecte', 'budgets'],
  ['Journal technique', 'journal log erreurs domenia.log', 'journaux', 'technical'],
  ['Lecture du journal', 'suivre erreurs retour ligne taille texte', 'journaux', 'reading'],
  ['Exporter les préférences', 'exporter preferences copier', 'preferences', 'export'],
  ['Importer des préférences', 'importer preferences coller', 'preferences', 'import'],
  ['Réinitialiser les préférences', 'reinitialiser remettre defaut', 'preferences', 'reset'],
  ['Configuration effective', 'configuration domenia.config.json valeurs provenance', 'configuration', 'config'],
  ['Commutateurs de fonctionnalités', 'features commutateurs wake on lan', 'configuration', 'features'],
  ['Réglages de sécurité', 'securite secrets presse-papiers mot de passe', 'configuration', 'security'],
  ['Mode simulation', 'simulation demonstration fictif graine', 'demonstration', 'mode'],
  ['Compatibilité du poste', 'compatibilite windows dotnet webview2', 'apropos', 'compatibility'],
  ['Composants livrés', 'composants versions sha-256 licences', 'apropos', 'components'],
].map(([label, words, section, setting]) => ({ label, words: fold(`${label} ${words}`), section, setting }));

const RING = '<span class="glow-ring hero-ring" aria-hidden="true"></span>';
const ORBS = '<div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>';

function themeLabel() {
  const pref = document.documentElement.dataset.themePref;
  const map = { light: 'Clair', dark: 'Sombre', contrast: 'Contraste élevé', system: 'Suivre Windows' };
  return map[pref] ?? 'Suivre Windows';
}

function motionLabel() {
  const m = document.documentElement.dataset.motion;
  return m === 'reduced' ? 'animations réduites' : m === 'system' ? 'animations de Windows' : 'animations riches';
}

function heroMarkup() {
  const nav = SECTIONS.map((s, n) => `<li><button type="button" class="pr-nav-item" data-section="${s.id}" data-j="${n}" aria-current="false">
      <span class="pr-nav-ico" data-tone="${s.tone}">${glyph(s.icon)}</span>
      <span class="pr-nav-text"><span class="pr-nav-label">${esc(s.label)}</span><span class="pr-nav-desc">${esc(s.desc)}</span></span>
      <span class="pr-nav-badge" data-badge="${s.id}" hidden></span></button></li>`).join('');
  const tile = (id, label, iconName, section) => `<button type="button" class="pr-pulse-tile" data-pulse="${id}" data-go-section="${section}" aria-busy="true">
      <span class="pr-pulse-ico">${glyph(iconName)}</span><span class="pr-pulse-k">${esc(label)}</span>
      <span class="pr-pulse-v"><span class="skeleton pr-sk w70"></span></span><span class="pr-pulse-s"></span></button>`;
  return `<div class="page pr-page">
    <section class="hero pr-hero reveal">${RING}${ORBS}
      <div class="pr-hero-grid">
        <div class="pr-hero-main">
          <div class="eyebrow">${icon('settings')}<span>Réglages de Domenia</span></div>
          <h1 class="gradient-text">Paramètres</h1>
          <p class="lead">Apparence, connexion, base locale, collecte, journaux et préférences : tout ce que Domenia garde sur ce poste, et rien qui parte ailleurs.</p>
          <div class="chips pr-chips" data-slot="chips"></div>
          <div class="pr-search" role="search">
            <span class="pr-search-box">${glyph('search')}<input type="search" class="input" id="pr-search" placeholder="Rechercher un réglage…" autocomplete="off" spellcheck="false"
              role="combobox" aria-expanded="false" aria-controls="pr-search-list" aria-autocomplete="list" aria-label="Rechercher un réglage"><kbd>/</kbd></span>
            <ul class="pr-search-list" id="pr-search-list" role="listbox" aria-label="Réglages trouvés" hidden></ul>
          </div>
        </div>
        <aside class="pr-pulse" aria-label="État de l’application">
          ${tile('appearance', 'Apparence', 'sparkles', 'apparence')}
          ${tile('store', 'Base locale', 'database', 'donnees')}
          ${tile('compat', 'Compatibilité', 'shield', 'apropos')}
          ${tile('journal', 'Journal technique', 'file', 'journaux')}
        </aside>
      </div>
    </section>
    <div class="pr-layout">
      <nav class="pr-nav reveal" aria-label="Sections des paramètres"><span class="pr-nav-pill" aria-hidden="true"></span><ul>${nav}</ul></nav>
      <div class="pr-content" data-slot="content" tabindex="-1"></div>
    </div>
  </div>`;
}

export function render(main, ctx) {
  const call = makeCall(ctx);
  const st = { alive: true, section: null, mounted: null, token: 0, app: null };
  const params = ctx.params ?? {};
  main.innerHTML = heroMarkup();
  paint(main);
  const stopReveal = reveal(main);
  const content = main.querySelector('[data-slot="content"]');
  const nav = main.querySelector('.pr-nav');
  const pill = nav.querySelector('.pr-nav-pill');

  // ----- Hero: chips and health tiles -----

  function setTile(id, value, sub, toneName, tip = '') {
    const t = main.querySelector(`[data-pulse="${id}"]`);
    if (!t) return;
    t.removeAttribute('aria-busy');
    t.dataset.tone = toneName;
    t.querySelector('.pr-pulse-v').textContent = value;
    t.querySelector('.pr-pulse-s').textContent = sub;
    if (tip) t.dataset.tip = tip; else delete t.dataset.tip;
    paint(t);
    t.classList.remove('pr-bump');
    void t.offsetWidth;
    t.classList.add('pr-bump');
  }

  function paintAppearanceTile() {
    const z = ctx.shell?.prefs?.().zoom ?? 100;
    setTile('appearance', themeLabel(), `${motionLabel()} · zoom ${z}${NBSP}%`, 'accent');
  }

  function paintChips(app) {
    const host = main.querySelector('[data-slot="chips"]');
    if (!host) return;
    const sim = app?.mode === 'simulation' || app?.webViewRuntime === 'apercu';
    const chips = [
      `<span class="chip ${sim ? 'info' : 'ok'}" data-j="0">${glyph(sim ? 'sparkles' : 'server')}${esc(sim ? 'Simulation' : 'Annuaire Active Directory')}</span>`,
      app?.version ? `<span class="chip" data-j="1">${glyph('logo')}Domenia ${esc(app.version)}</span>` : '',
      `<span class="chip" data-j="2" data-tip="Préférences, reçus et journal restent dans le dossier de données de ce poste">${glyph('lock')}Données locales seulement</span>`,
    ];
    host.innerHTML = chips.join('');
    paint(host);
  }

  function setBadge(id, text, toneName = 'off') {
    const b = main.querySelector(`[data-badge="${id}"]`);
    if (!b) return;
    if (text === null || text === undefined || text === '') { b.hidden = true; return; }
    b.hidden = false;
    b.textContent = String(text);
    b.dataset.tone = toneName;
    paint(b);
  }

  async function loadPulse() {
    paintAppearanceTile();
    const jobs = [
      call('settings.storage').then((s) => {
        if (!st.alive) return;
        if (!s.available) { setTile('store', 'Pas encore branchée', 'mode annuaire de cette version', 'off', s.unavailableReason ?? ''); return; }
        const last = s.backups?.find((b) => b.verified);
        const parts = (s.location?.text ?? '').split(' · ');
        setTile('store', parts[1] ?? (s.simulated ? 'Base fictive' : 'Base locale'),
          last ? `${s.simulated ? 'base fictive · ' : ''}sauvegardée ${relTime(last.at) ?? ''}` : 'aucune sauvegarde vérifiée', s.location?.alert ? 'warn' : 'ok', s.location?.text ?? '');
        if (s.location?.alert) setBadge('donnees', '!', 'warn');
      }),
      call('settings.about').then((a) => {
        if (!st.alive) return;
        const c = a.compatibility;
        // « prévu, jamais testé » → « Prévu » with « jamais testé » before the system in the second line.
        const [head, ...rest] = c.overallLabel.split(', ');
        setTile('compat', head.charAt(0).toUpperCase() + head.slice(1), [rest.join(', '), a.identity.operatingSystem].filter(Boolean).join(' · '), c.tone, c.text);
      }),
      call('settings.logs').then((l) => {
        if (!st.alive) return;
        const errors = l.file.errors;
        setTile('journal', errors ? `${int(errors)} erreur${errors > 1 ? 's' : ''}` : 'Aucune erreur', l.file.exists ? `${size(l.file.bytes)} · ${int(l.session.length)} opération${l.session.length > 1 ? 's' : ''}` : 'journal pas encore écrit', errors ? 'alert' : 'ok');
        setBadge('journaux', errors ? errors : '', errors ? 'alert' : 'off');
      }),
    ];
    const ids = ['store', 'compat', 'journal'];
    await Promise.allSettled(jobs.map((j, n) => j.catch((err) => {
      console.error(err);
      const t = main.querySelector(`[data-pulse="${ids[n]}"]`);
      if (!t || !st.alive) return;
      t.removeAttribute('aria-busy');
      t.querySelector('.pr-pulse-v').textContent = '—';
      t.querySelector('.pr-pulse-s').textContent = reported(err);
      t.dataset.tone = 'warn';
    })));
  }

  // ----- Section rail -----

  function movePill(item) {
    if (!item) return;
    pill.style.setProperty('--y', `${item.offsetTop}px`);
    pill.style.setProperty('--h', `${item.offsetHeight}px`);
    pill.classList.add('on');
  }

  function markNav(id) {
    nav.querySelectorAll('.pr-nav-item').forEach((b) => {
      const on = b.dataset.section === id;
      b.setAttribute('aria-current', on ? 'page' : 'false');
      if (on) movePill(b);
    });
  }

  function writeAddress(id, extra = {}) {
    const q = new URLSearchParams();
    q.set('section', id);
    for (const [k, v] of Object.entries(extra)) if (v) q.set(k, v);
    history.replaceState(null, '', `#/parametres?${q.toString()}`);
  }

  const sctx = {
    ctx,
    call,
    toast: ctx.toast,
    shell: ctx.shell ?? null,
    app: () => st.app,
    badge: setBadge,
    tile: setTile,
    refreshAppearanceTile: paintAppearanceTile,
    alive: () => st.alive,
    address: (extra) => writeAddress(st.section, extra),
    go: (id, opts) => show(id, opts),
  };

  async function show(id, { focus = false, open = null, tab = null, setting = null, first = false } = {}) {
    const section = SECTIONS.find((s) => s.id === id) ?? SECTIONS[0];
    const my = ++st.token;
    if (st.section === section.id && !first) {
      if (setting) highlight(setting);
      return;
    }
    st.section = section.id;
    markNav(section.id);
    if (!first) writeAddress(section.id, tab ? { onglet: tab } : {});
    const leaving = content.firstElementChild;
    if (leaving && !motionReduced()) {
      leaving.classList.add('pr-leave');
      await new Promise((r) => setTimeout(r, 140));
    }
    if (my !== st.token || !st.alive) return;
    try { st.mounted?.destroy?.(); } catch (err) { console.error(err); }
    st.mounted = null;
    const host = document.createElement('div');
    host.className = 'pr-section pr-enter';
    host.dataset.section = section.id;
    content.replaceChildren(host);
    let mod;
    try {
      mod = await section.load();
    } catch (err) {
      console.error(err);
      host.innerHTML = `<div class="pr-error" role="alert"><span class="pr-error-art">${icon('alert')}</span><div><b>Section indisponible</b><p>Le module de cette section n’a pas pu être chargé.</p></div></div>`;
      return;
    }
    if (my !== st.token || !st.alive) return;
    st.mounted = mod.mount(host, sctx, { open, tab, params }) ?? null;
    if (setting) setTimeout(() => highlight(setting), 420);
    if (focus) content.focus({ preventScroll: true });
    announce(`Section ${section.label}`);
  }

  function highlight(setting) {
    const target = content.querySelector(`[data-setting="${CSS.escape(setting)}"]`);
    if (!target) return;
    target.scrollIntoView({ block: 'center', behavior: motionReduced() ? 'auto' : 'smooth' });
    target.classList.remove('pr-flash');
    void target.offsetWidth;
    target.classList.add('pr-flash');
    target.querySelector('button, input, select, [tabindex]')?.focus({ preventScroll: true });
  }

  // ----- Search of a setting -----

  const search = main.querySelector('#pr-search');
  const list = main.querySelector('#pr-search-list');
  let hits = [];
  let active = -1;

  function renderHits() {
    const q = fold(search.value.trim());
    hits = q ? INDEX.filter((x) => q.split(/\s+/).every((w) => x.words.includes(w))).slice(0, 8) : [];
    active = hits.length ? 0 : -1;
    list.innerHTML = hits.length
      ? hits.map((h, n) => {
        const s = SECTIONS.find((x) => x.id === h.section);
        return `<li role="option" id="pr-hit-${n}" aria-selected="${n === active}" data-hit="${n}">${glyph(s.icon)}<span class="pr-hit-label">${esc(h.label)}</span><span class="pr-hit-sec">${esc(s.label)}</span></li>`;
      }).join('')
      : (q ? '<li class="pr-hit-none" role="option" aria-disabled="true">Aucun réglage ne correspond.</li>' : '');
    list.hidden = !q;
    search.setAttribute('aria-expanded', String(!!q));
    if (active >= 0) search.setAttribute('aria-activedescendant', `pr-hit-${active}`); else search.removeAttribute('aria-activedescendant');
  }

  function choose(n) {
    const h = hits[n];
    if (!h) return;
    search.value = '';
    renderHits();
    show(h.section, { setting: h.setting });
  }

  search.addEventListener('input', renderHits);
  search.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      if (!hits.length) return;
      e.preventDefault();
      active = (active + (e.key === 'ArrowDown' ? 1 : -1) + hits.length) % hits.length;
      list.querySelectorAll('[data-hit]').forEach((li) => li.setAttribute('aria-selected', String(Number(li.dataset.hit) === active)));
      search.setAttribute('aria-activedescendant', `pr-hit-${active}`);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      choose(active);
    } else if (e.key === 'Escape' && search.value) {
      e.stopPropagation();
      search.value = '';
      renderHits();
    }
  });
  list.addEventListener('pointerdown', (e) => {
    const li = e.target instanceof Element ? e.target.closest('[data-hit]') : null;
    if (li) { e.preventDefault(); choose(Number(li.dataset.hit)); }
  });
  search.addEventListener('blur', () => setTimeout(() => { if (!search.matches(':focus')) { list.hidden = true; search.setAttribute('aria-expanded', 'false'); } }, 120));

  // « / » focuses the search of the settings (outside text fields).
  const onKey = (e) => {
    if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey) return;
    const t = e.target;
    if (t instanceof HTMLElement && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
    e.preventDefault();
    search.focus();
  };
  document.addEventListener('keydown', onKey);

  // ----- Events -----

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const item = t?.closest('.pr-nav-item');
    if (item) { show(item.dataset.section, { focus: false }); return; }
    const tile = t?.closest('[data-go-section]');
    if (tile && main.contains(tile)) show(tile.dataset.goSection);
  };
  const onNavKey = (e) => {
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp' && e.key !== 'Home' && e.key !== 'End') return;
    const items = [...nav.querySelectorAll('.pr-nav-item')];
    const at = items.indexOf(document.activeElement);
    if (at < 0) return;
    e.preventDefault();
    const next = e.key === 'Home' ? 0 : e.key === 'End' ? items.length - 1 : (at + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
    items[next].focus();
  };
  main.addEventListener('click', onClick);
  nav.addEventListener('keydown', onNavKey);
  const onTheme = () => { paintAppearanceTile(); syncSegments(main); };
  window.addEventListener('domenia:ui-prefs', onTheme);
  const observer = new MutationObserver(onTheme);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'data-motion', 'data-theme-pref'] });
  const ro = 'ResizeObserver' in window ? new ResizeObserver(() => markNav(st.section)) : null;
  ro?.observe(nav);
  const ticker = setInterval(() => {
    main.querySelectorAll('[data-rel]').forEach((el) => {
      const text = relTime(el.dataset.rel);
      if (text) el.textContent = `${el.dataset.prefix ?? ''}${text}`;
    });
  }, 30_000);

  // ----- Start -----

  ctx.app?.then((app) => {
    if (!st.alive) return;
    st.app = app;
    paintChips(app);
  });
  paintChips(null);
  loadPulse();
  const first = SECTIONS.some((s) => s.id === params.section) ? params.section : 'apparence';
  show(first, { first: true, open: params.ouvrir ?? null, tab: params.onglet ?? null });

  return () => {
    st.alive = false;
    st.token++;
    clearInterval(ticker);
    stopReveal();
    observer.disconnect();
    ro?.disconnect();
    document.removeEventListener('keydown', onKey);
    main.removeEventListener('click', onClick);
    nav.removeEventListener('keydown', onNavKey);
    window.removeEventListener('domenia:ui-prefs', onTheme);
    try { st.mounted?.destroy?.(); } catch (err) { console.error(err); }
  };
}

