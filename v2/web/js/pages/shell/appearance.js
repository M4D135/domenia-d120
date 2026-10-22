// Appearance and visual contract (TRV-008 to TRV-011, TRV-063) and accessibility (TRV-001 to TRV-003): theme, motion, profile
// and display choices, the 14 status glyphs, the categorical chart series with their edges, the live WCAG contrast of the
// theme shown, the five rules of the shared kit, Windows high contrast, announcements and the local check of an interface.
// The tab is drawn once; a change of preference or of theme updates it in place, so the keyboard focus never leaves the
// choice the operator is on. The choices are radio groups with a roving tab stop and the arrow keys (APG pattern).
import { icon } from '../../icons.js';
import { esc, announce } from '../../ui.js';
import { state, setPrefs, on, expertAllowed } from '../../shell/store.js';
import { STATUS_GLYPHS, statusBadge } from '../../shell/glyphs.js';
import { measureContrast, ratioText, CHART_SERIES, CONTRAST_PAIRS } from '../../shell/contrast.js';
import { auditAccessibility } from '../../shell/a11y.js';

const NBSP = ' ';
const RULES = [
  ['shield', 'L’apparence ne donne aucun droit', 'Un bouton affiché n’autorise rien : chaque écriture repasse par le plan, la confirmation, le reçu et la relecture.'],
  ['key', 'Aucun mot de passe dans l’aide, les journaux ou les préférences', 'Les textes d’aide sont des libellés fixes ; les secrets restent en SecureString jusqu’à l’API Windows.'],
  ['pause', 'Un arrêt demandé n’est pas une annulation confirmée', 'L’état « Arrêt demandé » reste distinct de « Annulé » tant que le moteur ne l’a pas constaté.'],
  ['check', 'Terminé ne veut pas dire vérifié', '« Vérifié » n’apparaît qu’après une relecture qui confirme l’état attendu.'],
  ['refresh', 'Aucune modification rejouée automatiquement', 'Ni au démarrage, ni depuis un reçu, ni depuis la palette : une écriture part une fois, sur votre geste.'],
];

const CHOICES = {
  theme: [['light', 'Clair', 'sun'], ['dark', 'Sombre', 'moon'], ['contrast', 'Contraste', 'contrast'], ['system', 'Windows', 'monitor']],
  motion: [['full', 'Riches', 'sparkles'], ['reduced', 'Réduites', 'pause'], ['system', 'Windows', 'monitor']],
  profile: [['essentiel', 'Essentiel', ''], ['expert', 'Expert', '']],
};
const GROUP_LABELS = { theme: 'Thème', motion: 'Animations', profile: 'Profil d’affichage' };

function choice(name, value) {
  return `<div class="segmented sh-choice" role="radiogroup" aria-label="${esc(GROUP_LABELS[name])}" data-group="${name}">${CHOICES[name].map(([id, label, ic]) => `<button type="button" role="radio" data-pref="${name}" data-value="${id}" aria-checked="${value === id}" tabindex="${value === id ? 0 : -1}">${ic ? icon(ic) : ''}${esc(label)}</button>`).join('')}</div>`;
}

/**
 * Next radio of a group for a key (APG radio group): arrows wrap, Début and Fin go to the ends; disabled radios are skipped.
 * Pure (tests/web/shell/appearance.test.mjs). Returns the index, or -1 when the key does not move.
 */
export function radioMove(key, index, count, disabled = []) {
  const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[key];
  const usable = (n) => !disabled.includes(n);
  if (key === 'Home') { for (let n = 0; n < count; n += 1) if (usable(n)) return n; return -1; }
  if (key === 'End') { for (let n = count - 1; n >= 0; n -= 1) if (usable(n)) return n; return -1; }
  if (!step) return -1;
  for (let k = 1; k <= count; k += 1) {
    const n = (index + step * k + count * k) % count;
    if (usable(n)) return n;
  }
  return -1;
}

// Heights of the sample columns (share of the tallest), fixed so that two captures give the same image.
const SERIES_SAMPLE = [0.62, 0.9, 0.48, 0.74, 0.56, 0.82, 0.4, 0.68];

export function renderAppearance(panel) {
  const p = state.prefs;
  panel.innerHTML = `<div class="sh-appear">
    <section class="card sh-appear-prefs">
      <header class="card-head"><span class="card-icon">${icon('sun')}</span><h3>Apparence de l’interface</h3><span class="meta">Mémorisée sur ce poste</span></header>
      <div class="sh-pref-row wide"><div><strong>Thème</strong><p class="faint">Clair, sombre, contraste élevé, ou celui de Windows (contraste élevé de Windows reconnu).</p></div>${choice('theme', p.theme)}</div>
      <div class="sh-pref-row wide"><div><strong>Animations</strong><p class="faint">Riches par défaut${NBSP}; «${NBSP}Réduites${NBSP}» ramène chaque durée à presque rien.</p></div>${choice('motion', p.motion)}</div>
      <div class="sh-pref-row"><div><strong>Profil d’affichage</strong><p class="faint" data-profile-note>Expert montre les vues détaillées par défaut${NBSP}; depuis Essentiel, la palette les montre pour une consultation.</p></div>${choice('profile', p.profile)}</div>
      <div class="sh-pref-row"><div><strong>Infobulles d’aide</strong><p class="faint">Textes du catalogue au survol et au focus clavier (350${NBSP}ms, 20${NBSP}s au plus).</p></div>
        <label class="sh-switch-line"><input type="checkbox" class="switch" data-pref-bool="helpTips"${p.helpTips ? ' checked' : ''}><span data-bool-label="helpTips">${p.helpTips ? 'Actives' : 'Coupées'}</span></label></div>
      <div class="sh-pref-row"><div><strong>Bandeau du mode</strong><p class="faint">Simulation ou aperçu${NBSP}: le bandeau sous la barre du haut peut se replier dans la puce du mode. L’avertissement des écritures réelles reste toujours affiché.</p></div>
        <label class="sh-switch-line"><input type="checkbox" class="switch" data-pref-bool="bannerShown"${p.bannerCompact ? '' : ' checked'}><span data-bool-label="bannerShown">${p.bannerCompact ? 'Replié' : 'Affiché'}</span></label></div>
    </section>
    <section class="card sh-appear-contrast">
      <header class="card-head"><span class="card-icon">${icon('contrast')}</span><h3>Contraste du thème affiché</h3><span class="meta" data-contrast-badge></span></header>
      <p class="muted" data-contrast-lead></p>
      <div class="sh-contrast-table" role="table" aria-label="Contraste des paires de couleurs">
        <div class="sh-contrast-row head" role="row"><span role="columnheader">Paire</span><span role="columnheader">Exemple</span><span role="columnheader">Rapport</span><span role="columnheader">Seuil</span><span role="columnheader">État</span></div>
        ${CONTRAST_PAIRS.map(([label, fg, bg], n) => `<div class="sh-contrast-row" role="row" data-n="${n}"><span role="cell">${esc(label)}<span class="mono faint">${esc(fg)} / ${esc(bg)}</span></span>
          <span role="cell"><span class="sh-swatch-pair" data-fg="${esc(fg)}" data-bg="${esc(bg)}">Aa</span></span>
          <span role="cell" class="num"><strong data-ratio></strong></span><span role="cell" class="num faint" data-required></span>
          <span role="cell" data-state></span></div>`).join('')}
      </div>
    </section>
    <section class="card sh-appear-glyphs">
      <header class="card-head"><span class="card-icon">${icon('check')}</span><div class="sh-card-titles"><h3>États${NBSP}: symbole, mot et couleur</h3><p class="sh-card-sub">La couleur n’est jamais seule porteuse du sens.</p></div></header>
      <div class="sh-glyph-grid">${STATUS_GLYPHS.map((g) => statusBadge(g.word)).join('')}</div>
      <p class="faint">Un état inconnu s’affiche «${NBSP}Inconnu${NBSP}», jamais comme un succès${NBSP}; les alias français et anglais sont reconnus sans casse ni accents.</p>
    </section>
    <section class="card sh-appear-series">
      <header class="card-head"><span class="card-icon">${icon('activity')}</span><div class="sh-card-titles"><h3>Couleurs des séries de graphiques</h3><p class="sh-card-sub">Huit teintes de catégorie, chacune avec un bord plus foncé (3${NBSP}:${NBSP}1 en thème clair)${NBSP}; le jaune, le vert et le rouge restent réservés aux états.</p></div></header>
      <div class="sh-series-demo" role="img" aria-label="Exemple : une colonne par série, dans l’ordre des huit couleurs">${SERIES_SAMPLE.map((h, n) => `<span class="sh-series-col s${n + 1}" data-p="${h}" data-i="${n}"></span>`).join('')}</div>
      <div class="sh-series">${CHART_SERIES.map(([token, name], n) => `<span class="sh-series-item"><span class="sh-swatch s${n + 1}"></span>${esc(name)}<span class="mono faint">${esc(token)}</span></span>`).join('')}</div>
    </section>
    <section class="card sh-appear-rules">
      <header class="card-head"><span class="card-icon">${icon('shield')}</span><h3>Règles du kit d’interface</h3><span class="meta">Opposables à chaque écran</span></header>
      <ol class="sh-rules">${RULES.map(([ic, title, text]) => `<li><span class="sh-rule-icon">${icon(ic)}</span><div><strong>${esc(title)}</strong><p class="faint">${esc(text)}</p></div></li>`).join('')}</ol>
    </section>
  </div>`;
  panel.querySelectorAll('.sh-swatch-pair').forEach((el) => {
    el.style.setProperty('color', `var(${el.dataset.fg})`);
    el.style.setProperty('background', `var(${el.dataset.bg})`);
  });
  panel.querySelectorAll('.sh-contrast-row[data-n]').forEach((el) => el.style.setProperty('--i', String(Math.min(20, Number(el.dataset.n)))));
  panel.querySelectorAll('.sh-series-col').forEach((el) => { el.style.setProperty('--p', el.dataset.p); el.style.setProperty('--i', el.dataset.i); });

  // ---------- In-place updates ----------

  const paintChoices = () => {
    const prefs = state.prefs;
    const values = { theme: prefs.theme, motion: prefs.motion, profile: prefs.profile === 'expert' && expertAllowed() ? 'expert' : 'essentiel' };
    for (const [name, value] of Object.entries(values)) {
      panel.querySelectorAll(`[data-group="${name}"] [role="radio"]`).forEach((b) => {
        const on = b.dataset.value === value;
        b.setAttribute('aria-checked', String(on));
        b.tabIndex = on ? 0 : -1;
      });
    }
    const expert = panel.querySelector('[data-group="profile"] [data-value="expert"]');
    if (!expertAllowed()) {
      expert.setAttribute('aria-disabled', 'true');
      expert.dataset.reason = `Profil Expert masqué par l’administrateur${NBSP}: UI.AllowExpertProfile vaut faux dans Domenia.config.json.`;
      panel.querySelector('[data-profile-note]').textContent = 'L’administrateur a masqué le profil Expert sur ce poste : le profil Essentiel est appliqué.';
    } else {
      expert.removeAttribute('aria-disabled');
      delete expert.dataset.reason;
    }
    const tips = panel.querySelector('[data-pref-bool="helpTips"]');
    tips.checked = prefs.helpTips;
    panel.querySelector('[data-bool-label="helpTips"]').textContent = prefs.helpTips ? 'Actives' : 'Coupées';
    const banner = panel.querySelector('[data-pref-bool="bannerShown"]');
    banner.checked = !prefs.bannerCompact;
    panel.querySelector('[data-bool-label="bannerShown"]').textContent = prefs.bannerCompact ? 'Replié' : 'Affiché';
  };

  const paintContrast = () => {
    const contrast = measureContrast();
    const passed = contrast.results.filter((r) => r.passed).length;
    panel.querySelector('[data-contrast-badge]').innerHTML = statusBadge(contrast.failures ? 'attention' : 'confirmé', { label: `${passed}${NBSP}/${NBSP}${contrast.results.length} paires conformes` });
    panel.querySelector('[data-contrast-lead]').innerHTML = `Rapports WCAG 2.x des ${CONTRAST_PAIRS.length} paires de couleurs réellement peintes, tronqués au centième${NBSP}: 4,5${NBSP}:${NBSP}1 pour le texte, 3${NBSP}:${NBSP}1 pour les grands textes et les graphiques. Plus faible${NBSP}: <strong>${ratioText(contrast.minimum)}${NBSP}:${NBSP}1</strong>.`;
    contrast.results.forEach((r, n) => {
      const row = panel.querySelector(`.sh-contrast-row[data-n="${n}"]`);
      if (!row) return;
      row.dataset.passed = String(r.passed);
      row.querySelector('[data-ratio]').textContent = r.text;
      row.querySelector('[data-required]').textContent = String(r.required).replace('.', ',');
      row.querySelector('[data-state]').innerHTML = statusBadge(r.passed ? 'confirmé' : 'attention', { label: r.passed ? 'Conforme' : 'Sous le seuil' });
    });
  };

  const apply = (name, value) => {
    if (name === 'theme') { document.querySelector(`.theme-switch button[data-set="${value}"]`)?.click(); return; }
    if (name === 'motion') { setPrefs({ motion: value }); document.documentElement.dataset.motion = value; return; }
    if (name === 'profile') {
      if (value === 'expert' && !expertAllowed()) { announce('Profil Expert masqué par l’administrateur.'); return; }
      setPrefs({ profile: value });
    }
  };

  panel.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-pref]') : null;
    if (!b || b.getAttribute('aria-disabled') === 'true') return;
    apply(b.dataset.pref, b.dataset.value);
  });
  // Arrow keys move the choice inside a group and keep the focus on the radio chosen.
  panel.addEventListener('keydown', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[role="radio"][data-pref]') : null;
    if (!b) return;
    const radios = [...b.closest('[role="radiogroup"]').querySelectorAll('[role="radio"]')];
    const disabled = radios.map((r, n) => (r.getAttribute('aria-disabled') === 'true' ? n : -1)).filter((n) => n >= 0);
    const next = radioMove(e.key, radios.indexOf(b), radios.length, disabled);
    if (next < 0) {
      if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); if (b.getAttribute('aria-disabled') !== 'true') apply(b.dataset.pref, b.dataset.value); }
      return;
    }
    e.preventDefault();
    radios.forEach((r, n) => { r.tabIndex = n === next ? 0 : -1; });
    radios[next].focus();
    apply(radios[next].dataset.pref, radios[next].dataset.value);
  });
  panel.addEventListener('change', (e) => {
    const t = e.target;
    if (!(t instanceof HTMLInputElement) || !t.dataset.prefBool) return;
    if (t.dataset.prefBool === 'bannerShown') setPrefs({ bannerCompact: !t.checked });
    else setPrefs({ [t.dataset.prefBool]: t.checked });
  });

  paintChoices();
  paintContrast();
  // The contrast is measured again once the new theme is painted (after the cross-fade of the window).
  let timer = 0;
  const offPrefs = on('prefs', () => { paintChoices(); clearTimeout(timer); timer = setTimeout(paintContrast, 80); });
  const offPolicy = on('policy', paintChoices);
  const observer = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(() => { paintChoices(); paintContrast(); }, 520); });
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  return () => { clearTimeout(timer); offPrefs(); offPolicy(); observer.disconnect(); };
}

export function renderAccessibility(panel) {
  const forced = matchMedia('(forced-colors: active)').matches;
  const run = () => {
    const findings = auditAccessibility(document.querySelector('.shell') ?? document);
    const box = panel.querySelector('[data-audit]');
    const alerts = findings.filter((f) => f.severity === 'alert').length;
    box.innerHTML = findings.length
      ? `<p>${statusBadge(alerts ? 'erreur' : 'attention', { label: `${findings.length} point${findings.length > 1 ? 's' : ''} à revoir` })}</p><ol class="sh-audit">${findings.slice(0, 40).map((f) => `<li data-tone="${f.severity}"><strong>${esc(f.text)}</strong>${f.target ? `<span class="mono">${esc(f.target)}</span>` : ''}</li>`).join('')}</ol>`
      : `<div class="sh-empty-mini">${icon('check')}<p><strong>Aucun point relevé</strong> dans l’interface commune et cet écran.</p><p class="faint">Noms accessibles, motifs des contrôles grisés, étiquettes, identifiants et ordre de tabulation.</p></div>`;
  };
  panel.innerHTML = `<div class="sh-a11y">
    <section class="card">
      <header class="card-head"><span class="card-icon">${icon('contrast')}</span><h3>Contraste élevé de Windows</h3><span class="meta">${statusBadge(forced ? 'information' : 'vide', { label: forced ? 'Actif' : 'Inactif' })}</span></header>
      <p class="muted">Avec un thème contrasté de Windows (Noir, Blanc, Désert…), chaque couleur de la palette prend la couleur système de son rôle (fond, texte, sélection, lien). Le passage d’un thème contrasté à un autre est suivi sans redémarrer. États et catégories se lisent alors par leurs mots et symboles.</p>
    </section>
    <section class="card">
      <header class="card-head"><span class="card-icon">${icon('bell')}</span><h3>Annonces au lecteur d’écran</h3></header>
      <ul class="sh-bullets">
        <li>Titre de l’écran affiché, à chaque changement d’écran.</li>
        <li>Messages des bannières (les erreurs en priorité) et état de la session quand il change, une seule fois.</li>
        <li>Résultats d’un filtre, d’un tri, d’une copie, d’une sélection dans les listes du kit.</li>
        <li>Un texte inchangé n’est jamais annoncé de nouveau.</li>
      </ul>
    </section>
    <section class="card">
      <header class="card-head"><span class="card-icon">${icon('command')}</span><h3>Clavier partout</h3></header>
      <ul class="sh-bullets">
        <li><kbd>Tab</kbd> parcourt la page${NBSP}; le lien «${NBSP}Aller au contenu${NBSP}» saute la navigation.</li>
        <li><kbd>F1</kbd> ouvre l’aide de l’élément qui a le focus, motif d’un bouton grisé compris.</li>
        <li>Les panneaux et dialogues gardent le focus et le rendent à leur fermeture${NBSP}; <kbd>Entrée</kbd> y lance le bouton principal.</li>
        <li>Le menu se redimensionne au clavier depuis sa poignée (flèches, Entrée pour la largeur par défaut).</li>
      </ul>
    </section>
    <section class="card sh-a11y-audit">
      <header class="card-head"><span class="card-icon">${icon('eye')}</span><h3>Contrôle de l’interface</h3>
        <button class="btn sm subtle" type="button" data-run-audit>${icon('refresh')}Relancer le contrôle</button></header>
      <p class="muted">Contrôle local de l’interface commune et de cet écran. Sur un autre écran, la palette propose «${NBSP}Contrôler l’accessibilité de cet écran${NBSP}».</p>
      <div data-audit></div>
    </section>
  </div>`;
  panel.querySelector('[data-run-audit]').addEventListener('click', run);
  setTimeout(run, 50);
}
