// Paramètres › Apparence (PAR-004 to PAR-009): theme with live previews, animations with a demonstration, zoom of the
// content, density of the lists, Essentiel or Expert profile, folded menu and help panel, keyboard shortcuts. These are
// preferences of the interface (web profile of the mode, never the directory); the shell applies them at once.
import {
  esc, glyph, card, row, segmented, toggle, notes, sectionHead, paint, syncSegments, pressSegment, NBSP,
} from './common.js';
import { reveal } from '../../ui.js';

const THEMES = [
  { id: 'light', label: 'Clair', sub: 'Fond lumineux, contrastes doux' },
  { id: 'dark', label: 'Sombre', sub: 'Fond profond, reposant le soir' },
  { id: 'contrast', label: 'Contraste élevé', sub: 'Cadres nets, couleurs franches' },
  { id: 'system', label: 'Suivre Windows', sub: 'Clair, sombre ou contraste selon Windows' },
];
const MOTIONS = [
  { value: 'full', label: 'Riches', icon: 'sparkles', tip: 'Fond vivant, entrées en cascade, graphiques qui se tracent' },
  { value: 'reduced', label: 'Réduites', icon: 'pause', tip: 'Chaque écran s’affiche directement dans son état final' },
  { value: 'system', label: 'Suivre Windows', icon: 'monitor', tip: 'Réduites seulement si Windows le demande' },
];
const ZOOM_MIN = 80;
const ZOOM_MAX = 150;
const UI_KEY = 'domenia.ui.v1';
const PREF_KEY = 'domenia.prefs.v1';

/** Shell preferences, through the shell API of app.js when present; otherwise the same storage keys. */
function shellApi(sctx) {
  const root = document.documentElement;
  const readUi = () => { try { return JSON.parse(localStorage.getItem(UI_KEY) ?? '{}') ?? {}; } catch { return {}; } };
  if (sctx.shell) return sctx.shell;
  return {
    prefs: () => {
      const ui = readUi();
      return {
        theme: root.dataset.themePref ?? 'system', motion: root.dataset.motion ?? 'full',
        navCollapsed: !!document.querySelector('.shell.nav-collapsed'), zoom: Number.isInteger(ui.zoom) ? ui.zoom : 100,
        density: ui.density === 'compact' ? 'compact' : 'confort', profile: ui.profile === 'expert' ? 'expert' : 'essentiel', ui,
      };
    },
    setTheme: (id) => document.querySelector(`.theme-switch button[data-set="${id}"]`)?.click(),
    setMotion: (id) => {
      let p = {};
      try { p = JSON.parse(localStorage.getItem(PREF_KEY) ?? '{}') ?? {}; } catch { p = {}; }
      try { localStorage.setItem(PREF_KEY, JSON.stringify({ ...p, motion: id })); } catch { /* session only */ }
      root.dataset.motion = id;
    },
    setCollapsed: (on) => {
      const shell = document.querySelector('.shell');
      if (shell && shell.classList.contains('nav-collapsed') !== on) document.querySelector('.nav-toggle')?.click();
    },
    setUi: (patch) => {
      const ui = { ...readUi(), ...patch };
      try { localStorage.setItem(UI_KEY, JSON.stringify(ui)); } catch { /* session only */ }
      window.dispatchEvent(new CustomEvent('domenia:ui-prefs'));
      return ui;
    },
  };
}

function themeCard(t, current) {
  const on = t.id === current;
  return `<button type="button" class="pr-theme" role="radio" aria-checked="${on}" data-theme-choice="${t.id}">
    <span class="pr-theme-art" data-art="${t.id}" aria-hidden="true">
      <span class="pr-mini-nav"><i></i><i></i><i></i></span>
      <span class="pr-mini-main"><span class="pr-mini-hero"></span><span class="pr-mini-row"><i></i><i></i><i></i></span><span class="pr-mini-line"></span></span>
    </span>
    <span class="pr-theme-text"><b>${esc(t.label)}</b><span>${esc(t.sub)}</span></span>
    <span class="pr-theme-check" aria-hidden="true">${glyph('check')}</span>
  </button>`;
}

function zoomControl(zoom) {
  const pct = ((zoom - ZOOM_MIN) / (ZOOM_MAX - ZOOM_MIN)) * 100;
  const ticks = Array.from({ length: (ZOOM_MAX - ZOOM_MIN) / 10 + 1 }, (_, n) => {
    const v = ZOOM_MIN + n * 10;
    return `<button type="button" class="pr-tick${v === zoom ? ' on' : ''}${v === 100 ? ' base' : ''}" data-zoom="${v}" aria-label="Zoom ${v}${NBSP}%" data-tip="${v}${NBSP}%"></button>`;
  }).join('');
  return `<div class="pr-zoom" data-setting="zoom">
    <button type="button" class="btn icon sm" data-act="zoom-out" aria-label="Réduire le zoom" data-tip="Réduire (Ctrl −)"${zoom <= ZOOM_MIN ? ' disabled' : ''}>${glyph('minus')}</button>
    <div class="pr-zoom-track" role="slider" tabindex="0" aria-label="Zoom de l’interface" aria-valuemin="${ZOOM_MIN}" aria-valuemax="${ZOOM_MAX}" aria-valuenow="${zoom}" aria-valuetext="${zoom}${NBSP}%">
      <span class="pr-zoom-fill" data-w="${pct}"></span><span class="pr-zoom-ticks">${ticks}</span>
    </div>
    <button type="button" class="btn icon sm" data-act="zoom-in" aria-label="Agrandir le zoom" data-tip="Agrandir (Ctrl +)"${zoom >= ZOOM_MAX ? ' disabled' : ''}>${glyph('plus')}</button>
    <button type="button" class="btn sm pr-zoom-value" data-act="zoom-reset" data-tip="Revenir à 100 % (Ctrl 0)">${zoom}${NBSP}%</button>
  </div>`;
}

function densityPreview(density) {
  const rows = ['PC-PAR-0042', 'PC-LYO-0108', 'PC-BOR-0017'].map((n, i) => `<span class="pr-dens-row" data-i="${i}"><i class="pr-dot" data-tone="${['ok', 'warn', 'ok'][i]}"></i><b>${n}</b><span>${['En ligne', 'Disque presque plein', 'En ligne'][i]}</span></span>`).join('');
  return `<div class="pr-dens" data-density="${esc(density)}" aria-hidden="true">${rows}</div>`;
}

function markup(p, allowExpert, expertReason) {
  const theme = card({
    id: 'theme', title: 'Thème', sub: 'Partagé par toutes les fenêtres de Domenia ; repeint sans rien relire', iconName: 'sun', cls: 'pr-wide',
    body: `<div class="pr-themes" role="radiogroup" aria-label="Thème" data-setting="theme">${THEMES.map((t) => themeCard(t, p.theme)).join('')}</div>
      <p class="pr-hint">${glyph('info')}<span>Le contraste élevé de Windows bascule automatiquement sur le thème contrasté quand vous suivez Windows. Raccourci : choisissez dans la palette (Ctrl${NBSP}K).</span></p>`,
  });
  const motion = card({
    id: 'motion', title: 'Animations', sub: 'Riches par défaut ; réglage de l’opérateur', iconName: 'sparkles',
    body: `<div data-setting="motion">${segmented('motion', 'Animations', MOTIONS, p.motion)}</div>
      <div class="pr-motion-demo" aria-hidden="true"><span class="pr-orbit"><i></i><i></i><i></i></span><span class="pr-bars"><i></i><i></i><i></i><i></i><i></i></span><span class="pr-glint"></span></div>
      <p class="pr-motion-state" data-slot="motion-state"></p>`,
  });
  const reading = card({
    id: 'reading', title: 'Lisibilité', sub: 'Zoom, densité et profil, mémorisés pour ce poste', iconName: 'eye',
    body: row({ label: 'Zoom de l’interface', desc: 'De 80 à 150 %, par pas de 10 ; le menu et la barre du haut gardent leur taille. Ctrl + molette, Ctrl +, Ctrl − et Ctrl 0 aussi.', control: zoomControl(p.zoom), setting: 'zoom' })
      + row({
        label: 'Densité des listes', desc: 'Confort ou compact ; ne change ni les filtres ni les droits.', setting: 'density',
        control: segmented('density', 'Densité', [{ value: 'confort', label: 'Confort', icon: 'rows' }, { value: 'compact', label: 'Compact', icon: 'columns' }], p.density),
      })
      + `<div class="pr-dens-wrap">${densityPreview(p.density)}</div>`
      + row({
        label: 'Profil', desc: 'Expert montre en plus les vues techniques (brut, droits, WMI, classes et GUID, détails des diagnostics). Ce choix ne donne aucun droit.', setting: 'profile',
        control: segmented('profile', 'Profil', [{ value: 'essentiel', label: 'Essentiel', icon: 'user' }, { value: 'expert', label: 'Expert', icon: 'tools', tip: allowExpert ? '' : expertReason }], p.profile),
      })
      + (allowExpert ? '' : `<p class="pr-hint warn">${glyph('lock')}<span>${esc(expertReason)}</span></p>`),
  });
  const layout = card({
    id: 'layout', title: 'Disposition', sub: 'Menu et panneau d’aide', iconName: 'panel',
    body: row({ label: 'Menu replié en icônes', desc: 'Garde le menu étroit ; sur un écran étroit, il se replie de lui-même sans changer ce choix. Ctrl B.', control: toggle('nav', 'Menu replié en icônes', p.navCollapsed), setting: 'nav' })
      + row({ label: 'Panneau d’aide à droite', desc: 'Votre choix est mémorisé ; le panneau d’aide contextuelle s’ouvrira selon ce réglage dès qu’il sera livré.', control: toggle('help', 'Panneau d’aide à droite', p.ui?.helpVisible === true), setting: 'help' }),
  });
  const keys = [
    ['Ctrl K', 'Palette de commandes et recherche'], ['Ctrl B', 'Replier ou déplier le menu'], ['Alt 1 à 9', 'Aller à un écran du menu'],
    ['Ctrl +  Ctrl −  Ctrl 0', 'Zoom de l’interface'], ['Ctrl + molette', 'Zoom de l’interface, par pas de 10'], ['/', 'Rechercher un réglage (cet écran)'],
  ];
  const shortcuts = card({
    id: 'keys', title: 'Raccourcis', sub: 'Au clavier, partout dans Domenia', iconName: 'command',
    body: `<ul class="pr-keys">${keys.map(([k, v], n) => `<li data-j="${n}"><span class="pr-kbds">${k.split('  ').map((x) => `<kbd>${esc(x)}</kbd>`).join('')}</span><span>${esc(v)}</span></li>`).join('')}</ul>`,
  });
  return `${sectionHead({ title: 'Apparence', lead: 'Comme vous préférez travailler : couleurs, mouvement, taille et densité. Appliqué tout de suite, mémorisé sur ce poste.', icon: 'sparkles' })}
    <div class="pr-grid">${theme}${motion}${reading}${layout}${shortcuts}
      <div class="pr-footnote reveal">${notes(['Ces réglages vivent dans le profil du moteur web de ce mode (simulation et annuaire ne les partagent pas) ; ils partent avec l’export des préférences.', 'La palette de Domenia 1 est conservée ; chaque couleur garde un contraste lisible, et la couleur n’est jamais seule porteuse du sens.'])}</div>
    </div>`;
}

export function mount(host, sctx) {
  const api = shellApi(sctx);
  let p = api.prefs();
  let allowExpert = true;
  const expertReason = 'Profil Expert masqué par l’administrateur (UI.AllowExpertProfile = false) : le profil Essentiel s’applique.';
  host.innerHTML = markup(p, allowExpert, expertReason);
  paint(host);
  const stopReveal = reveal(host);
  requestAnimationFrame(() => syncSegments(host));

  const motionState = () => {
    const el = host.querySelector('[data-slot="motion-state"]');
    if (!el) return;
    const windowsReduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
    const m = document.documentElement.dataset.motion;
    const effective = m === 'reduced' || (m === 'system' && windowsReduced) ? 'réduites' : 'riches';
    el.innerHTML = `${glyph(effective === 'riches' ? 'zap' : 'pause')}<span>Animations ${effective} en ce moment · Windows ${windowsReduced ? 'demande' : 'ne demande pas'} des animations réduites.</span>`;
    host.querySelector('.pr-motion-demo')?.classList.toggle('still', effective !== 'riches');
  };
  motionState();

  // UI.AllowExpertProfile: the administrator may hide Expert, which forces Essentiel (PAR-005).
  sctx.call('settings.config').then((config) => {
    if (!sctx.alive() || config.allowExpertProfile !== false) return;
    allowExpert = false;
    if (p.profile === 'expert') api.setUi({ profile: 'essentiel' });
    p = api.prefs();
    host.innerHTML = markup(p, allowExpert, expertReason);
    paint(host);
    reveal(host);
    requestAnimationFrame(() => syncSegments(host));
    motionState();
    host.querySelector('[data-seg="profile"] button[data-value="expert"]')?.setAttribute('disabled', '');
  }).catch((err) => console.error('Configuration illisible pour le profil', err));

  function setZoom(value) {
    const zoom = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, Math.round(value / 10) * 10));
    api.setUi({ zoom });
    p = api.prefs();
    const wrap = host.querySelector('.pr-zoom');
    if (wrap) {
      wrap.outerHTML = zoomControl(zoom);
      paint(host.querySelector('.pr-zoom').parentElement);
    }
    sctx.refreshAppearanceTile();
  }

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const theme = t?.closest('[data-theme-choice]');
    if (theme) {
      const id = theme.dataset.themeChoice;
      api.setTheme(id);
      host.querySelectorAll('[data-theme-choice]').forEach((b) => b.setAttribute('aria-checked', String(b.dataset.themeChoice === id)));
      theme.classList.remove('pr-pop');
      void theme.offsetWidth;
      theme.classList.add('pr-pop');
      sctx.refreshAppearanceTile();
      return;
    }
    const seg = t?.closest('.pr-seg button[data-value]');
    if (seg && !seg.disabled) {
      const group = seg.closest('.pr-seg');
      const value = seg.dataset.value;
      if (group.dataset.seg === 'motion') { api.setMotion(value); setTimeout(motionState, 30); }
      else if (group.dataset.seg === 'density') {
        api.setUi({ density: value });
        host.querySelector('.pr-dens')?.setAttribute('data-density', value);
      } else if (group.dataset.seg === 'profile') {
        if (value === 'expert' && !allowExpert) { sctx.toast(expertReason, { tone: 'warn' }); return; }
        api.setUi({ profile: value });
        sctx.toast(value === 'expert' ? 'Profil Expert : vues techniques affichées. Aucun droit n’est ajouté.' : 'Profil Essentiel : vues techniques masquées.', { tone: 'info', life: 3200 });
      }
      pressSegment(group, value);
      sctx.refreshAppearanceTile();
      return;
    }
    const tick = t?.closest('[data-zoom]');
    if (tick) { setZoom(Number(tick.dataset.zoom)); return; }
    const act = t?.closest('[data-act]')?.dataset.act;
    if (act === 'zoom-in') setZoom((p.zoom ?? 100) + 10);
    else if (act === 'zoom-out') setZoom((p.zoom ?? 100) - 10);
    else if (act === 'zoom-reset') setZoom(100);
  };
  const onChange = (e) => {
    const input = e.target instanceof HTMLInputElement ? e.target : null;
    if (!input?.matches('[data-toggle]')) return;
    if (input.dataset.toggle === 'nav') api.setCollapsed(input.checked);
    else if (input.dataset.toggle === 'help') {
      api.setUi({ helpVisible: input.checked });
      sctx.toast(input.checked ? 'Panneau d’aide : affiché dès sa livraison. Choix mémorisé.' : 'Panneau d’aide : masqué. Choix mémorisé.', { tone: 'info', life: 3000 });
    }
  };
  const onKey = (e) => {
    const track = e.target instanceof Element ? e.target.closest('.pr-zoom-track') : null;
    if (!track) return;
    const map = { ArrowRight: 10, ArrowUp: 10, ArrowLeft: -10, ArrowDown: -10 };
    if (e.key in map) { e.preventDefault(); setZoom((p.zoom ?? 100) + map[e.key]); host.querySelector('.pr-zoom-track')?.focus(); }
    else if (e.key === 'Home') { e.preventDefault(); setZoom(ZOOM_MIN); host.querySelector('.pr-zoom-track')?.focus(); }
    else if (e.key === 'End') { e.preventDefault(); setZoom(ZOOM_MAX); host.querySelector('.pr-zoom-track')?.focus(); }
  };
  const onPrefs = () => {
    p = api.prefs();
    host.querySelectorAll('[data-theme-choice]').forEach((b) => b.setAttribute('aria-checked', String(b.dataset.themeChoice === p.theme)));
    const nav = host.querySelector('[data-toggle="nav"]');
    if (nav) nav.checked = !!p.navCollapsed;
    const z = host.querySelector('.pr-zoom-track');
    if (z && Number(z.getAttribute('aria-valuenow')) !== p.zoom) setZoom(p.zoom);
    motionState();
  };
  const observer = new MutationObserver(onPrefs);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme-pref', 'data-motion'] });
  const shellObserver = new MutationObserver(onPrefs);
  const shellEl = document.querySelector('.shell');
  if (shellEl) shellObserver.observe(shellEl, { attributes: true, attributeFilter: ['class'] });
  window.addEventListener('domenia:ui-prefs', onPrefs);
  host.addEventListener('click', onClick);
  host.addEventListener('change', onChange);
  host.addEventListener('keydown', onKey);

  return {
    destroy() {
      stopReveal();
      observer.disconnect();
      shellObserver.disconnect();
      window.removeEventListener('domenia:ui-prefs', onPrefs);
      host.removeEventListener('click', onClick);
      host.removeEventListener('change', onChange);
      host.removeEventListener('keydown', onKey);
    },
  };
}

