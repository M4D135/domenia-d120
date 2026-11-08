// REL-05 (2.0.7): a leading icon stays above its field in panels, dialogs and pages, whatever the field carries (a tooltip
// of the sheets, of the policy or of the page, the shake of an error). Hit testing follows the paint order, so the icon is
// made hit-testable for the check only.
import { test, ok, eq } from './harness.mjs';

const CSS = ['tokens.css', 'base.css', 'layout.css', 'motion.css', 'components.css', 'shell.css', 'kit.css',
  'pages/accueil.css', 'pages/relations.css', 'pages/requetes.css', 'pages/poste.css'];

async function sheets() {
  const links = [];
  for (const file of CSS) {
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = new URL(`../../web/css/${file}`, import.meta.url).href;
    const loaded = new Promise((resolve, reject) => { link.onload = resolve; link.onerror = () => reject(new Error(`CSS non chargé : ${file}`)); });
    document.head.append(link);
    links.push(link);
    await loaded;
  }
  return () => links.forEach((l) => l.remove());
}

const SVG = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>';

// The structures of the screens: the icon first, then the field.
const FIELDS = {
  'k-gsearch (grid.js)': `<div class="k-gbar"><label class="k-gsearch">${SVG}<input class="k-gq" type="search" placeholder="Filtrer les lignes…"></label></div>`,
  'k-tree-search (tree.js)': `<div class="k-tree"><label class="k-tree-search">${SVG}<input type="search" placeholder="Rechercher une branche…"></label></div>`,
  'sh-pick-find (pickers.js)': `<div class="sh-pick-row"><label class="sh-pick-find">${SVG}<input class="input" type="search" placeholder="Chercher une OU"></label></div>`,
  'k-input-ico (form.js)': `<div class="k-field"><div class="k-control"><span class="k-input-ico">${SVG}<input class="input" type="search" placeholder="OU"></span></div></div>`,
  'sh-help-search (help-panel.js)': `<div class="sh-help-search">${SVG}<input class="input" type="search" placeholder="Aide"></div>`,
  'cat-search (accueil/tools.js)': `<div data-page="accueil"><label class="cat-search">${SVG}<input type="search" placeholder="Sondes"></label></div>`,
  'rel-search (relations/panels.js)': `<div class="rel-panel" data-page="relations"><form class="rel-search"><span class="rel-search-ico">${SVG}</span><input class="input" type="search" placeholder="Poste"><button class="btn" type="button">Rechercher</button></form></div>`,
  'rq-search (requetes)': `<label class="rq-search">${SVG}<input class="input" type="search" placeholder="Valeurs"></label>`,
  'ps-search.sm (poste)': `<div class="poste-drw"><label class="ps-search sm">${SVG}<input class="input" type="search" placeholder="Poste"></label></div>`,
};

function layer(kind) {
  const el = document.createElement('div');
  el.className = kind === 'drawer' ? 'k-drw-layer right' : 'k-dlg-layer';
  el.innerHTML = kind === 'drawer'
    ? `<div class="k-drw" style="--k-dw: 560px"><div class="k-drw-body">${Object.values(FIELDS).map((f) => `<div>${f}</div>`).join('')}</div></div>`
    : `<div class="k-dlg"><div class="k-dlg-body">${Object.values(FIELDS).map((f) => `<div>${f}</div>`).join('')}</div></div>`;
  return el;
}

function iconOf(field) {
  const box = field.closest('label, form, .k-input-ico, .sh-help-search, .k-gsearch');
  return box.querySelector('.rel-search-ico') ?? box.querySelector(':scope > svg');
}

function onTop(icon) {
  icon.scrollIntoView({ block: 'center' });
  icon.style.pointerEvents = 'auto';
  const r = icon.getBoundingClientRect();
  const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
  icon.style.pointerEvents = '';
  return icon === hit || icon.contains(hit);
}

test('REL-05 : la loupe reste au-dessus du champ, même avec une infobulle (panneau, dialogue)', async () => {
  const drop = await sheets();
  // The poste rules only apply while the poste screen is shown (pages/poste.css).
  const page = document.createElement('main');
  page.className = 'main';
  page.dataset.page = 'poste';
  page.hidden = true;
  document.body.append(page);
  const root = document.documentElement;
  const before = { theme: root.dataset.theme, tips: root.classList.contains('js-tips') };
  root.classList.add('js-tips'); // Real shell: tips.js replaces the CSS bubbles.
  try {
    for (const theme of ['light', 'dark', 'contrast']) {
      document.documentElement.dataset.theme = theme;
      for (const kind of ['drawer', 'dialog']) {
        const el = layer(kind);
        document.body.append(el);
        el.getAnimations({ subtree: true }).forEach((a) => { try { a.finish(); } catch { /* an endless animation keeps running */ } });
        const names = Object.keys(FIELDS);
        el.querySelectorAll('input').forEach((input, n) => {
          input.dataset.tip = 'Saisie de ce panneau. Annuler ne valide aucune modification.';
          eq(getComputedStyle(input).position, 'static', `${names[n]} : champ non positionné par son infobulle (${kind}, ${theme})`);
          ok(onTop(iconOf(input)), `${names[n]} : loupe visible au-dessus du champ (${kind}, ${theme})`);
        });
        el.remove();
      }
    }
  } finally {
    page.remove();
    if (before.theme === undefined) delete root.dataset.theme; else root.dataset.theme = before.theme;
    if (!before.tips) root.classList.remove('js-tips');
    drop();
  }
});

test('REL-05 : :where garde la position propre de la poignée et de l’interrupteur', async () => {
  const drop = await sheets();
  const host = document.createElement('div');
  host.innerHTML = '<div class="k-drw-layer right"><div class="k-drw"><div class="k-drw-grip" data-tip="Glisser pour élargir"></div></div></div>'
    + '<input class="switch" type="checkbox" data-tip="Désactivé par l’administrateur (GuiElementPolicy).">'
    + '<span data-tip="Infobulle">Texte</span>';
  document.body.append(host);
  try {
    eq(getComputedStyle(host.querySelector('.k-drw-grip')).position, 'absolute', 'poignée du panneau toujours absolue');
    eq(getComputedStyle(host.querySelector('.switch')).position, 'relative', 'interrupteur toujours positionné pour son curseur');
    eq(getComputedStyle(host.querySelector('span[data-tip]')).position, 'relative', 'un élément non saisissable à infobulle reste positionné');
  } finally {
    host.remove();
    drop();
  }
});

test('REL-05 : la loupe d’un champ du kit reste visible pendant la secousse d’erreur', async () => {
  const drop = await sheets();
  const host = document.createElement('div');
  host.innerHTML = `<div class="k-field is-error"><div class="k-control"><span class="k-input-ico">${SVG}<input class="input" type="search" placeholder="OU"></span></div></div>`;
  document.body.append(host);
  try {
    const input = host.querySelector('input');
    const shake = input.getAnimations().find((a) => a.animationName === 'k-shake');
    ok(shake, 'secousse d’erreur présente');
    shake.pause();
    shake.currentTime = 90;
    ok(onTop(host.querySelector('.k-input-ico > svg')), 'loupe au-dessus du champ pendant la secousse');
  } finally {
    host.remove();
    drop();
  }
});
