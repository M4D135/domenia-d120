// Paramètres › Apparence (PAR-004 to PAR-009, PAR-051): theme with live previews, animations with a demonstration, zoom of the
// whole window (native zoom of WebView2, kept by the host), density of the lists and Essentiel or Expert profile, folded menu,
// help tips and help panel, remembered window, keyboard shortcuts. Theme, animations, menu, profile, density and help tips are
// the preferences of the shell (one store, interface.js); the zoom and the window are local preferences of the engine.
import {
  esc, glyph, card, row, segmented, toggle, notes, sectionHead, paint, syncSegments, pressSegment, radioKeys, rovingTabs, button, setOff, isOff, reported, NBSP, COLON,
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
  { value: 'system', label: 'Windows', icon: 'monitor', tip: 'Réduites seulement si Windows le demande' },
];
const DENSITIES = [
  { value: 'compact', label: 'Compact', icon: 'columns', tip: 'Lignes de 32 pixels' },
  { value: 'normal', label: 'Normal', icon: 'rows', tip: 'Lignes de 40 pixels' },
  { value: 'confortable', label: 'Confort', icon: 'rows', tip: 'Lignes de 48 pixels' },
];
const ZOOM_MIN = 80;
const ZOOM_MAX = 150;
const ZOOM_STEP = 10;
const EXPERT_REASON = `Profil Expert masqué par l’administrateur (UI.AllowExpertProfile${NBSP}=${NBSP}false)${COLON}le profil Essentiel s’applique.`;
const HELP_REASON = 'Le panneau d’aide (F1) est fourni par la coque de Domenia ; il apparaîtra ici dès qu’elle le livrera.';

function themeCard(t, current) {
  const on = t.id === current;
  return `<button type="button" class="pr-theme" role="radio" aria-checked="${on}" tabindex="${on ? 0 : -1}" data-theme-choice="${t.id}">
    <span class="pr-theme-art" data-art="${t.id}" aria-hidden="true">
      <span class="pr-mini-nav"><i></i><i></i><i></i></span>
      <span class="pr-mini-main"><span class="pr-mini-hero"></span><span class="pr-mini-row"><i></i><i></i><i></i></span><span class="pr-mini-line"></span></span>
    </span>
    <span class="pr-theme-text"><b>${esc(t.label)}</b><span>${esc(t.sub)}</span></span>
    <span class="pr-theme-check" aria-hidden="true">${glyph('check')}</span>
  </button>`;
}

/** Zoom slider: one focusable slider (no button inside), its decorative steps, and − / value / + beside it. */
function zoomControl(w) {
  const zoom = w?.zoom ?? 100;
  const off = !w || !w.available;
  const reason = !w ? 'Zoom réglé par l’hôte de Domenia : indisponible dans l’aperçu du navigateur.' : (w.reason ?? '');
  const pct = ((zoom - ZOOM_MIN) / (ZOOM_MAX - ZOOM_MIN)) * 100;
  const ticks = Array.from({ length: (ZOOM_MAX - ZOOM_MIN) / ZOOM_STEP + 1 }, (_, n) => {
    const v = ZOOM_MIN + n * ZOOM_STEP;
    return `<span class="pr-tick${v === zoom ? ' on' : ''}${v === 100 ? ' base' : ''}" data-tick="${v}"></span>`;
  }).join('');
  return `<div class="pr-zoom${off ? ' off' : ''}" data-setting="zoom">
    ${button('zoom-out', '', 'minus', { kind: 'ghost', disabled: off || zoom <= ZOOM_MIN, reason: off ? reason : 'Zoom minimal (80 %).', extra: ` aria-label="Réduire le zoom (Ctrl −)"` })}
    <div class="pr-zoom-track" role="slider" tabindex="${off ? -1 : 0}" aria-label="Zoom de l’interface" aria-valuemin="${ZOOM_MIN}" aria-valuemax="${ZOOM_MAX}" aria-valuenow="${zoom}"
      aria-valuetext="${zoom}${NBSP}%"${off ? ` aria-disabled="true" data-tip="${esc(reason)}"` : ''}>
      <span class="pr-zoom-fill" data-w="${pct}"></span><span class="pr-zoom-ticks" aria-hidden="true">${ticks}</span>
    </div>
    ${button('zoom-in', '', 'plus', { kind: 'ghost', disabled: off || zoom >= ZOOM_MAX, reason: off ? reason : 'Zoom maximal (150 %).', extra: ` aria-label="Agrandir le zoom (Ctrl +)"` })}
    ${button('zoom-reset', `${zoom}${NBSP}%`, '', { disabled: off || zoom === 100, reason: off ? reason : 'Déjà à 100 %.', extra: ' aria-label="Revenir à 100 % (Ctrl 0)"' })}
  </div>`;
}

function densityPreview(density) {
  const rows = [['PC-PAR-0042', 'En ligne', 'ok'], ['PC-LYO-0108', 'Disque presque plein', 'warn'], ['PC-BOR-0017', 'En ligne', 'ok'], ['PC-NAN-0233', 'Hors ligne depuis 3 j', 'off']]
    .map(([n, s, t], i) => `<span class="pr-dens-row" data-i="${i}"><i class="pr-dot" data-tone="${t}"></i><b>${n}</b><span>${s}</span></span>`).join('');
  return `<div class="pr-dens" data-density="${esc(density)}" aria-hidden="true">${rows}</div>`;
}

function shortcutList(shell) {
  const base = [
    ['Ctrl K', 'Palette de commandes et recherche'], ['Ctrl B', 'Replier ou déplier le menu'], ['Alt 1 à 9', 'Aller à un écran du menu'],
    ['Ctrl +  Ctrl −  Ctrl 0', 'Zoom de la fenêtre, sur tout clavier'], ['Ctrl + molette', 'Zoom de la fenêtre'], ['/', 'Rechercher un réglage (cet écran)'],
  ];
  const more = shell ? [
    ['Ctrl T', 'Changer de thème'], ['F1', 'Aide de l’élément qui a le focus'], ['Maj ?', 'Liste des raccourcis'], ['F5', 'Actualiser l’écran'],
    ['Ctrl F', 'Rechercher dans l’écran'], ['Ctrl I', 'Base locale (Données et cache)'], ['Alt ←  Alt →', 'Écran précédent, écran suivant'],
  ] : [];
  return [...base, ...more];
}

function markup(p, w, o) {
  const theme = card({
    id: 'theme', title: 'Thème', sub: 'Partagé par toutes les fenêtres de Domenia ; repeint sans rien relire', iconName: 'sun', cls: 'pr-wide',
    body: `<div class="pr-themes" role="radiogroup" aria-label="Thème" data-setting="theme">${THEMES.map((t) => themeCard(t, p.theme)).join('')}</div>
      <p class="pr-hint">${glyph('info')}<span>Avec « Suivre Windows », le contraste élevé de Windows bascule de lui-même sur le thème contrasté.${o.shell ? ` Raccourci${COLON}Ctrl${NBSP}T.` : ''}</span></p>`,
  });
  const motion = card({
    id: 'motion', title: 'Animations', sub: 'Riches par défaut ; réglage de l’opérateur', iconName: 'sparkles',
    body: `<div data-setting="motion">${segmented('motion', 'Animations', MOTIONS, p.motion)}</div>
      <div class="pr-motion-demo" aria-hidden="true"><span class="pr-orbit"><i></i><i></i><i></i></span><span class="pr-bars"><i></i><i></i><i></i><i></i><i></i></span><span class="pr-glint"></span></div>
      <p class="pr-motion-state" data-slot="motion-state"></p>`,
  });
  const layout = card({
    id: 'layout', title: 'Disposition et aide', sub: 'Menu, infobulles, panneau d’aide et fenêtre', iconName: 'panel',
    body: row({ label: 'Menu replié en icônes', desc: `Garde le menu étroit. Sur une fenêtre étroite, il se replie de lui-même le temps qu’il faut, sans changer ce choix. Ctrl${NBSP}B.`, control: toggle('nav', 'Menu replié en icônes', p.navCollapsed), setting: 'nav' })
      + row({ label: 'Infobulles d’aide', desc: 'Titre et texte d’aide au survol et au focus clavier.', control: toggle('tips', 'Infobulles d’aide', p.helpTips), setting: 'help' })
      + row({
        label: 'Panneau d’aide', desc: o.shell ? 'À côté du travail, ou par-dessus sur une fenêtre étroite ; le focus revient au bouton à sa fermeture. F1.' : HELP_REASON,
        control: button('help-open', 'Ouvrir l’aide', 'info', { disabled: !o.shell, reason: HELP_REASON, extra: o.shell ? ' aria-keyshortcuts="F1"' : '' }),
      })
      + `<div data-slot="window">${windowRow(w)}</div>`,
  });
  const expertDesc = 'Expert montre en plus les vues techniques (vue brute du journal, empreintes, plans SQLite, noms des réglages, détails des contrôles). Ce choix ne donne aucun droit.';
  const reading = card({
    id: 'reading', title: 'Lisibilité', sub: 'Zoom, densité et profil, mémorisés pour ce poste', iconName: 'eye', cls: 'pr-wide',
    body: `<div class="pr-legible">
        <div class="pr-legible-part" data-setting="zoom-part"><div class="pr-legible-head"><b>Zoom de l’interface</b><span>${esc(w?.text ?? 'De 80 à 150 %, par pas de 10 ; toute la fenêtre suit.')}</span></div>
          <div data-slot="zoom">${zoomControl(w)}</div></div>
        <div class="pr-legible-part" data-setting="density"><div class="pr-legible-head"><b>Densité des listes</b><span>Compact, normal ou confort${COLON}ne change ni les filtres ni les droits.</span></div>
          ${segmented('density', 'Densité', DENSITIES, p.density)}<div class="pr-dens-wrap" data-slot="density">${densityPreview(p.density)}</div></div>
        <div class="pr-legible-part" data-setting="profile"><div class="pr-legible-head"><b>Profil</b><span>${esc(expertDesc)}</span></div>
          ${segmented('profile', 'Profil', [{ value: 'essentiel', label: 'Essentiel', icon: 'user' }, { value: 'expert', label: 'Expert', icon: 'tools', disabled: !o.allowExpert, tip: o.allowExpert ? '' : EXPERT_REASON }], p.profile)}
          ${o.allowExpert ? (o.once ? `<p class="pr-hint accent">${glyph('eye')}<span>Vue Expert ponctuelle, ouverte depuis la palette${COLON}elle ne change pas ce profil.</span></p>` : '') : `<p class="pr-hint warn">${glyph('lock')}<span>${esc(EXPERT_REASON)}</span></p>`}</div>
      </div>`,
  });
  const keys = shortcutList(o.shell);
  const shortcuts = card({
    id: 'keys', title: 'Raccourcis', sub: 'Au clavier, partout dans Domenia', iconName: 'command', cls: 'pr-wide',
    body: `<ul class="pr-keys">${keys.map(([k, v], n) => `<li data-j="${n}"><span class="pr-kbds">${k.split('  ').map((x) => `<kbd>${esc(x)}</kbd>`).join('')}</span><span>${esc(v)}</span></li>`).join('')}</ul>`,
  });
  return `${sectionHead({ title: 'Apparence', lead: 'Comme vous préférez travailler : couleurs, mouvement, taille et densité. Appliqué tout de suite, mémorisé sur ce poste.', icon: 'sparkles' })}
    <div class="pr-grid">${theme}${motion}${layout}${reading}${shortcuts}
      <div class="pr-footnote reveal">${notes([
        'Thème, animations, menu, profil, densité et infobulles sont les préférences de la coque, gardées dans le profil du moteur web de ce mode ; le zoom et la fenêtre sont gardés par Domenia dans les préférences de ce poste.',
        'La palette de Domenia 1 est conservée ; chaque couleur garde un contraste lisible, et la couleur n’est jamais seule porteuse du sens.',
      ])}</div>
    </div>`;
}

function windowRow(w) {
  const remembered = w?.remembered === true;
  return row({
    label: 'Fenêtre mémorisée', desc: w ? `${w.window} Rendue à sa place au démarrage, ramenée sur un écran si son moniteur a disparu.` : 'Taille, position et état agrandi, gardés par l’hôte de Domenia.', setting: 'window',
    control: button('window-forget', 'Oublier', 'undo', { kind: 'ghost', disabled: !w?.available || !remembered, reason: !w ? 'Indisponible dans l’aperçu du navigateur.' : !w.available ? (w.reason ?? '') : 'Aucune fenêtre mémorisée.' }),
  });
}

export function mount(host, sctx) {
  const prefs = sctx.prefs;
  let p = prefs.get();
  let w = null;
  const o = { shell: !!prefs.help, allowExpert: sctx.allowExpert(), once: sctx.ctx?.expert === true && p.profile !== 'expert' };
  let alive = true;

  function draw() {
    host.innerHTML = markup(p, w, o);
    paint(host);
    reveal(host);
    requestAnimationFrame(() => syncSegments(host));
    motionState();
  }

  const motionState = () => {
    const el = host.querySelector('[data-slot="motion-state"]');
    if (!el) return;
    const windowsReduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
    const m = document.documentElement.dataset.motion;
    const effective = m === 'reduced' || (m === 'system' && windowsReduced) ? 'réduites' : 'riches';
    el.innerHTML = `${glyph(effective === 'riches' ? 'zap' : 'pause')}<span>Animations ${effective} en ce moment · Windows ${windowsReduced ? 'demande' : 'ne demande pas'} des animations réduites.</span>`;
    host.querySelector('.pr-motion-demo')?.classList.toggle('still', effective !== 'riches');
  };

  draw();

  // UI.AllowExpertProfile: the administrator may hide Expert, which forces Essentiel (PAR-005).
  sctx.config().then(() => {
    if (!alive) return;
    o.allowExpert = sctx.allowExpert();
    if (!o.allowExpert && p.profile === 'expert') p = prefs.set({ profile: 'essentiel' });
    draw();
  });
  sctx.call('settings.window').then((view) => { if (!alive) return; w = view; sctx.setZoom(view.zoom); paintZoom(); paintWindow(); })
    .catch((err) => { if (err?.code !== 'preview.engineRequired') console.error(err); });

  function paintZoom() {
    const slot = host.querySelector('[data-slot="zoom"]');
    if (!slot) return;
    slot.innerHTML = zoomControl(w);
    paint(slot);
  }

  function paintWindow() {
    const slot = host.querySelector('[data-slot="window"]');
    if (!slot) return;
    slot.innerHTML = windowRow(w);
    paint(slot);
  }

  async function setZoom(value) {
    if (!w?.available) { if (w?.reason) sctx.toast(w.reason, { tone: 'info' }); return; }
    const zoom = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, Math.round(value / ZOOM_STEP) * ZOOM_STEP));
    if (zoom === w.zoom) return;
    const focused = document.activeElement?.closest?.('.pr-zoom-track') ? '.pr-zoom-track' : null;
    try {
      w = await sctx.call('settings.window.zoom.set', { percent: zoom });
      if (!alive) return;
      sctx.setZoom(w.zoom);
      paintZoom();
      if (focused) host.querySelector(focused)?.focus();
    } catch (err) {
      sctx.toast(reported(err), { tone: 'warn' });
    }
  }

  function trackValue(e, track) {
    const r = track.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (e.clientX - r.left) / Math.max(1, r.width)));
    return ZOOM_MIN + Math.round((ratio * (ZOOM_MAX - ZOOM_MIN)) / ZOOM_STEP) * ZOOM_STEP;
  }

  const onClick = async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    // A control greyed by the administrator (GuiElementPolicy) never acts, whatever part of it is clicked.
    if (t?.closest('[data-policy="disabled"]')) return;
    const theme = t?.closest('[data-theme-choice]');
    if (theme) {
      if (isOff(theme)) return;
      const id = theme.dataset.themeChoice;
      p = prefs.set({ theme: id });
      host.querySelectorAll('[data-theme-choice]').forEach((b) => b.setAttribute('aria-checked', String(b.dataset.themeChoice === id)));
      rovingTabs(host.querySelector('.pr-themes'));
      theme.classList.remove('pr-pop');
      void theme.offsetWidth;
      theme.classList.add('pr-pop');
      sctx.refreshAppearanceTile();
      return;
    }
    const seg = t?.closest('.pr-seg button[data-value]');
    if (seg) {
      const group = seg.closest('.pr-seg');
      const value = seg.dataset.value;
      if (isOff(seg)) {
        if (group.dataset.seg === 'profile' && value === 'expert') sctx.toast(EXPERT_REASON, { tone: 'warn' });
        return;
      }
      if (group.dataset.seg === 'motion') { p = prefs.set({ motion: value }); setTimeout(motionState, 30); }
      else if (group.dataset.seg === 'density') {
        p = prefs.set({ density: value });
        const slot = host.querySelector('[data-slot="density"]');
        if (slot) { slot.innerHTML = densityPreview(value); paint(slot); }
      } else if (group.dataset.seg === 'profile') {
        p = prefs.set({ profile: value });
        sctx.toast(value === 'expert' ? 'Profil Expert : vues techniques affichées dans tous les écrans. Aucun droit n’est ajouté.' : 'Profil Essentiel : vues techniques masquées ; une vue ouverte en Expert revient à sa vue lisible.', { tone: 'info', life: 3600 });
      }
      pressSegment(group, value);
      sctx.refreshAppearanceTile();
      return;
    }
    const track = t?.closest('.pr-zoom-track');
    if (track && track.getAttribute('aria-disabled') !== 'true') { setZoom(trackValue(e, track)); return; }
    const btn = t?.closest('[data-act]');
    if (!btn || isOff(btn)) return;
    const act = btn.dataset.act;
    if (act === 'zoom-in') setZoom((w?.zoom ?? 100) + ZOOM_STEP);
    else if (act === 'zoom-out') setZoom((w?.zoom ?? 100) - ZOOM_STEP);
    else if (act === 'zoom-reset') setZoom(100);
    else if (act === 'help-open') prefs.help?.open();
    else if (act === 'window-forget') {
      try {
        w = await sctx.call('settings.window.forget');
        paintWindow();
        sctx.toast('Fenêtre oubliée : taille et position par défaut au prochain démarrage.', { tone: 'ok' });
      } catch (err) { sctx.toast(reported(err), { tone: 'warn' }); }
    }
  };
  const onChange = (e) => {
    const input = e.target instanceof HTMLInputElement ? e.target : null;
    if (!input?.matches('[data-toggle]') || input.disabled) return;
    if (input.dataset.toggle === 'nav') p = prefs.set({ navCollapsed: input.checked });
    else if (input.dataset.toggle === 'tips') {
      p = prefs.set({ helpTips: input.checked });
      sctx.toast(input.checked ? 'Infobulles d’aide affichées.' : 'Infobulles d’aide coupées ; F1 reste disponible.', { tone: 'info', life: 2600 });
    }
  };
  const onKey = (e) => {
    if (e.target instanceof Element && e.target.closest('[data-policy="disabled"]')) return;
    if (radioKeys(e)) return;
    const track = e.target instanceof Element ? e.target.closest('.pr-zoom-track') : null;
    if (!track || track.getAttribute('aria-disabled') === 'true') return;
    const map = { ArrowRight: ZOOM_STEP, ArrowUp: ZOOM_STEP, ArrowLeft: -ZOOM_STEP, ArrowDown: -ZOOM_STEP, PageUp: 20, PageDown: -20 };
    if (e.key in map) { e.preventDefault(); setZoom((w?.zoom ?? 100) + map[e.key]); } else if (e.key === 'Home') { e.preventDefault(); setZoom(ZOOM_MIN); } else if (e.key === 'End') { e.preventDefault(); setZoom(ZOOM_MAX); }
  };
  const offPrefs = prefs.on(() => {
    p = prefs.get();
    host.querySelectorAll('[data-theme-choice]').forEach((b) => b.setAttribute('aria-checked', String(b.dataset.themeChoice === p.theme)));
    const themes = host.querySelector('.pr-themes');
    if (themes) rovingTabs(themes);
    const navToggle = host.querySelector('[data-toggle="nav"]');
    if (navToggle) navToggle.checked = p.navCollapsed;
    const tips = host.querySelector('[data-toggle="tips"]');
    if (tips) tips.checked = p.helpTips;
    for (const [name, value] of [['motion', p.motion], ['density', p.density], ['profile', p.profile]]) {
      const group = host.querySelector(`[data-seg="${name}"]`);
      if (group && group.querySelector('[aria-checked="true"]')?.dataset.value !== value) pressSegment(group, value);
    }
    motionState();
  });
  host.addEventListener('click', onClick);
  host.addEventListener('change', onChange);
  host.addEventListener('keydown', onKey);
  setOff(host.querySelector('[data-act="help-open"]'), !o.shell, HELP_REASON);

  return {
    zoomChanged(view) { w = view; paintZoom(); },
    destroy() {
      alive = false;
      offPrefs();
      host.removeEventListener('click', onClick);
      host.removeEventListener('change', onChange);
      host.removeEventListener('keydown', onKey);
    },
  };
}
