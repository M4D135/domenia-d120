// Appearance and visual contract (TRV-008 to TRV-011, TRV-063) and accessibility (TRV-001 to TRV-003): theme, motion and
// display choices, the 14 status glyphs, the categorical chart series, the live WCAG contrast of the theme shown, the five
// rules of the shared kit, Windows high contrast, announcements and the local check of an interface.
import { icon } from '../../icons.js';
import { esc } from '../../ui.js';
import { state, setPrefs, on } from '../../shell/store.js';
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

function choice(name, value, options) {
  return `<div class="segmented sh-choice" role="radiogroup" aria-label="${esc(name)}">${options.map(([id, label, ic]) => `<button type="button" role="radio" data-pref="${esc(name)}" data-value="${id}" aria-checked="${value === id}">${ic ? icon(ic) : ''}${esc(label)}</button>`).join('')}</div>`;
}

// Heights of the sample columns (share of the tallest), fixed so that two captures give the same image.
const SERIES_SAMPLE = [0.62, 0.9, 0.48, 0.74, 0.56, 0.82, 0.4, 0.68];

export function renderAppearance(panel) {
  let painted = false;
  const paint = () => {
    const p = state.prefs;
    const contrast = measureContrast();
    const passed = contrast.results.filter((r) => r.passed).length;
    panel.innerHTML = `<div class="sh-appear">
      <section class="card sh-appear-prefs">
        <header class="card-head"><span class="card-icon">${icon('sun')}</span><h3>Apparence de l’interface</h3><span class="meta">Mémorisée sur ce poste</span></header>
        <div class="sh-pref-row wide"><div><strong>Thème</strong><p class="faint">Clair, sombre, contraste élevé, ou celui de Windows (contraste élevé de Windows reconnu).</p></div>
          ${choice('theme', p.theme, [['light', 'Clair', 'sun'], ['dark', 'Sombre', 'moon'], ['contrast', 'Contraste', 'contrast'], ['system', 'Windows', 'monitor']])}</div>
        <div class="sh-pref-row wide"><div><strong>Animations</strong><p class="faint">Riches par défaut ; « Réduites » ramène chaque durée à presque rien.</p></div>
          ${choice('motion', p.motion, [['full', 'Riches', 'sparkles'], ['reduced', 'Réduites', 'pause'], ['system', 'Windows', 'monitor']])}</div>
        <div class="sh-pref-row"><div><strong>Profil d’affichage</strong><p class="faint">Expert montre les vues détaillées par défaut ; depuis Essentiel, la palette les montre pour une consultation.</p></div>
          ${choice('profile', p.profile, [['essentiel', 'Essentiel'], ['expert', 'Expert']])}</div>
        <div class="sh-pref-row"><div><strong>Infobulles d’aide</strong><p class="faint">Textes du catalogue au survol et au focus clavier (350${NBSP}ms, 20${NBSP}s au plus).</p></div>
          <label class="sh-switch-line"><input type="checkbox" class="switch" data-pref-bool="helpTips"${p.helpTips ? ' checked' : ''}><span>${p.helpTips ? 'Actives' : 'Coupées'}</span></label></div>
      </section>
      <section class="card sh-appear-contrast">
        <header class="card-head"><span class="card-icon">${icon('contrast')}</span><h3>Contraste du thème affiché</h3>
          <span class="meta">${statusBadge(contrast.failures ? 'attention' : 'confirmé', { label: `${passed}${NBSP}/${NBSP}${contrast.results.length} paires conformes` })}</span></header>
        <p class="muted">Rapports WCAG 2.x des ${CONTRAST_PAIRS.length} paires de couleurs réellement peintes, tronqués au centième : 4,5${NBSP}:${NBSP}1 pour le texte, 3${NBSP}:${NBSP}1 pour les grands textes et les graphiques. Plus faible${NBSP}: <strong>${ratioText(contrast.minimum)}${NBSP}:${NBSP}1</strong>.</p>
        <div class="sh-contrast-table" role="table" aria-label="Contraste des paires de couleurs">
          <div class="sh-contrast-row head" role="row"><span role="columnheader">Paire</span><span role="columnheader">Exemple</span><span role="columnheader">Rapport</span><span role="columnheader">Seuil</span><span role="columnheader">État</span></div>
          ${contrast.results.map((r, n) => `<div class="sh-contrast-row" role="row" data-n="${n}"><span role="cell">${esc(r.label)}<span class="mono faint">${esc(r.fg)} / ${esc(r.bg)}</span></span>
            <span role="cell"><span class="sh-swatch-pair" data-fg="${esc(r.fg)}" data-bg="${esc(r.bg)}">Aa</span></span>
            <span role="cell" class="num"><strong>${esc(r.text)}</strong></span><span role="cell" class="num faint">${String(r.required).replace('.', ',')}</span>
            <span role="cell">${statusBadge(r.passed ? 'confirmé' : 'attention', { label: r.passed ? 'Conforme' : 'Sous le seuil' })}</span></div>`).join('')}
        </div>
      </section>
      <section class="card sh-appear-glyphs">
        <header class="card-head"><span class="card-icon">${icon('check')}</span><div class="sh-card-titles"><h3>États : symbole, mot et couleur</h3><p class="sh-card-sub">La couleur n’est jamais seule porteuse du sens.</p></div></header>
        <div class="sh-glyph-grid">${STATUS_GLYPHS.map((g) => statusBadge(g.word)).join('')}</div>
        <p class="faint">Un état inconnu s’affiche « Inconnu », jamais comme un succès ; les alias français et anglais sont reconnus sans casse ni accents.</p>
      </section>
      <section class="card sh-appear-series">
        <header class="card-head"><span class="card-icon">${icon('activity')}</span><div class="sh-card-titles"><h3>Couleurs des séries de graphiques</h3><p class="sh-card-sub">Huit teintes de catégorie ; le jaune, le vert et le rouge restent réservés aux états.</p></div></header>
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
    if (painted) panel.querySelector('.sh-appear')?.classList.add('quiet');
    painted = true;
  };
  panel.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-pref]') : null;
    if (!b) return;
    const name = b.dataset.pref;
    if (name === 'theme') document.querySelector(`.theme-switch button[data-set="${b.dataset.value}"]`)?.click();
    else if (name === 'motion') { setPrefs({ motion: b.dataset.value }); document.documentElement.dataset.motion = b.dataset.value; }
    else setPrefs({ [name]: b.dataset.value });
  });
  panel.addEventListener('change', (e) => {
    const t = e.target;
    if (t instanceof HTMLInputElement && t.dataset.prefBool) setPrefs({ [t.dataset.prefBool]: t.checked });
  });
  paint();
  // The contrast is measured again after a change of theme or of preferences.
  const offPrefs = on('prefs', () => setTimeout(paint, 60));
  const observer = new MutationObserver(() => setTimeout(paint, 520));
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  return () => { offPrefs(); observer.disconnect(); };
}

export function renderAccessibility(panel) {
  const forced = matchMedia('(forced-colors: active)').matches;
  const run = () => {
    const findings = auditAccessibility(document.querySelector('.shell') ?? document);
    const box = panel.querySelector('[data-audit]');
    const alerts = findings.filter((f) => f.severity === 'alert').length;
    box.innerHTML = findings.length
      ? `<p>${statusBadge(alerts ? 'erreur' : 'attention', { label: `${findings.length} point${findings.length > 1 ? 's' : ''} à revoir` })}</p><ol class="sh-audit">${findings.slice(0, 40).map((f) => `<li data-tone="${f.severity}"><strong>${esc(f.text)}</strong>${f.target ? `<span class="mono">${esc(f.target)}</span>` : ''}</li>`).join('')}</ol>`
      : `<div class="sh-empty-mini">${icon('check')}<p><strong>Aucun point relevé</strong> dans la coque et cet écran.</p><p class="faint">Noms accessibles, motifs des contrôles grisés, étiquettes, identifiants et ordre de tabulation.</p></div>`;
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
        <li><kbd>Tab</kbd> parcourt la page ; le lien « Aller au contenu » saute la navigation.</li>
        <li><kbd>F1</kbd> ouvre l’aide de l’élément qui a le focus, motif d’un bouton grisé compris.</li>
        <li>Les panneaux et dialogues gardent le focus et le rendent à leur fermeture.</li>
        <li>Le menu se redimensionne au clavier depuis sa poignée (flèches, Entrée pour la largeur par défaut).</li>
      </ul>
    </section>
    <section class="card sh-a11y-audit">
      <header class="card-head"><span class="card-icon">${icon('eye')}</span><h3>Contrôle de l’interface</h3>
        <button class="btn sm subtle" type="button" data-run-audit>${icon('refresh')}Relancer le contrôle</button></header>
      <p class="muted">Contrôle local de la coque et de cet écran. Sur un autre écran, la palette propose « Contrôler l’accessibilité de cet écran ».</p>
      <div data-audit></div>
    </section>
  </div>`;
  panel.querySelector('[data-run-audit]').addEventListener('click', run);
  setTimeout(run, 50);
}
