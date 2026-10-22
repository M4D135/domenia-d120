// Keyboard shortcuts (TRV-178 to TRV-180; Domenia 1 Get-DomeniaKeyboardShortcuts, Get-DomeniaShortcutListText, Get-DomeniaBoardKeyGesture):
// one catalogue for the key handler of app.js, the palette and the overlay (Maj+? or F1 then « Raccourcis »). A shortcut
// typed in a text field keeps its meaning there (Ctrl+Z undoes the typing); no shortcut ever changes the profile.
import { esc, fold, copyText, announce } from '../ui.js';
import { openDialog } from '../kit/index.js';

const NBSP = ' ';

/** [id, keys (display), label, scope]. Scopes: window, list, board, panel. */
export const SHORTCUTS = Object.freeze([
  ['palette', ['Ctrl K', 'Ctrl P'], 'Ouvrir la palette de commandes', 'window'],
  ['search', ['Ctrl F'], 'Aller à la recherche', 'window'],
  ['dashboard', ['Ctrl D'], 'Ouvrir l’accueil', 'window'],
  ['journal', ['Ctrl L'], 'Ouvrir le journal de la session (notifications et opérations)', 'window'],
  ['index', ['Ctrl I'], 'Ouvrir l’index local (Paramètres › Stockage)', 'window'],
  ['theme', ['Ctrl T'], 'Changer de thème clair ou sombre', 'window'],
  ['summary', ['Ctrl Maj C'], 'Copier le résumé de l’objet choisi', 'window'],
  ['refresh', ['F5'], 'Actualiser l’écran (ou le widget qui a le focus)', 'window'],
  ['help', ['F1'], 'Ouvrir l’aide sur l’élément actif', 'window'],
  ['shortcuts', ['Maj ?'], 'Afficher les raccourcis clavier', 'window'],
  ['nav', ['Ctrl B'], 'Replier ou déplier le menu', 'window'],
  ['screen', ['Alt 1…9'], 'Aller à l’écran 1 à 9 du menu', 'window'],
  ['back', ['Alt ←'], 'Écran précédent', 'window'],
  ['forward', ['Alt →'], 'Écran suivant', 'window'],
  ['escape', ['Échap'], 'Fermer le panneau ouvert, ou effacer la saisie de la recherche', 'window'],
  ['list-move', ['↑ ↓', 'Pg↑ Pg↓', 'Ctrl Début', 'Ctrl Fin'], 'Ligne active et sélection', 'list'],
  ['list-cell', ['← →', 'Début', 'Fin'], 'Cellule active', 'list'],
  ['list-extend', ['Maj ↑ ↓'], 'Étendre la sélection', 'list'],
  ['list-all', ['Ctrl A'], 'Tout sélectionner (Échap vide la sélection)', 'list'],
  ['list-open', ['Entrée'], 'Ouvrir la ligne', 'list'],
  ['list-menu', ['Maj F10', 'Menu'], 'Menu contextuel de la ligne', 'list'],
  ['list-copy', ['Ctrl C'], 'Copier la sélection (avec les en-têtes)', 'list'],
  ['list-undo', ['Ctrl Z'], 'Annuler la dernière présentation de la liste', 'list'],
  ['board-refresh', ['F5'], 'Actualiser le widget qui a le focus', 'board'],
  ['board-copy', ['Ctrl C'], 'Copier le widget en texte, pour un ticket', 'board'],
  ['board-menu', ['Maj F10'], 'Menu du widget', 'board'],
  ['board-move', ['Alt ← →', 'Alt Début', 'Alt Fin'], 'Déplacer le widget (mode Personnaliser)', 'board'],
  ['board-size', ['Alt Maj ← →'], 'Changer la taille du widget (mode Personnaliser)', 'board'],
  ['board-remove', ['Suppr'], 'Retirer le widget (mode Personnaliser)', 'board'],
  ['board-undo', ['Ctrl Z', 'Ctrl Y'], 'Annuler ou rétablir un changement de disposition', 'board'],
  ['panel-close', ['Échap'], 'Fermer le panneau ou le dialogue', 'panel'],
  ['panel-tab', ['Tab', 'Maj Tab'], 'Circuler dans le panneau (le focus y reste)', 'panel'],
  ['panel-size', ['← →', 'Maj ← →'], 'Redimensionner un panneau depuis sa poignée', 'panel'],
]);

export const SCOPES = Object.freeze({
  window: 'Partout dans la fenêtre',
  list: 'Dans une liste ou une grille',
  board: 'Dans un tableau de bord',
  panel: 'Dans un panneau ou un dialogue',
});

/** Keys of a shortcut by id (the first form), for the palette and the menus. */
export function keysOf(id) {
  return SHORTCUTS.find((s) => s[0] === id)?.[1][0] ?? '';
}

/** Every shortcut, one per line, for the clipboard (Domenia 1 Get-DomeniaShortcutListText). */
export function shortcutListText() {
  const lines = [];
  for (const [scope, title] of Object.entries(SCOPES)) {
    lines.push(title);
    for (const [, keys, label, s] of SHORTCUTS) if (s === scope) lines.push(`  ${keys.join(' ou ')}${NBSP}: ${label}`);
  }
  return lines.join('\r\n');
}

function kbds(keys) {
  return keys.map((k) => `<span class="sh-keys-combo">${k.split(' ').map((p) => `<kbd>${esc(p)}</kbd>`).join('')}</span>`).join('<span class="sh-keys-or">ou</span>');
}

/** Markup of the shortcut reference (overlay and Centre de l’interface). */
export function shortcutsMarkup() {
  return `<div class="sh-keys">
    <label class="sh-keys-find"><span class="visually-hidden">Filtrer les raccourcis</span>
      <input class="input" type="search" placeholder="Filtrer : thème, copier, menu…" data-keys-filter autocomplete="off" spellcheck="false"></label>
    <div class="sh-keys-groups">${Object.entries(SCOPES).map(([scope, title]) => `<section class="sh-keys-group" data-scope="${scope}">
      <h3>${esc(title)}</h3><dl>${SHORTCUTS.filter((s) => s[3] === scope).map(([id, keys, label]) => `<div class="sh-keys-row" data-id="${id}" data-text="${esc(fold(`${label} ${keys.join(' ')}`))}"><dt>${kbds(keys)}</dt><dd>${esc(label)}</dd></div>`).join('')}</dl>
    </section>`).join('')}</div>
    <p class="sh-keys-none" hidden>Aucun raccourci ne correspond.</p>
  </div>`;
}

/** Wires the filter of a shortcut reference. */
export function bindShortcuts(scope) {
  const input = scope.querySelector('[data-keys-filter]');
  if (!input) return;
  input.addEventListener('input', () => {
    const q = fold(input.value.trim());
    let shown = 0;
    scope.querySelectorAll('.sh-keys-row').forEach((row) => {
      const on = !q || row.dataset.text.includes(q);
      row.hidden = !on;
      if (on) shown += 1;
    });
    scope.querySelectorAll('.sh-keys-group').forEach((g) => { g.hidden = !g.querySelector('.sh-keys-row:not([hidden])'); });
    scope.querySelector('.sh-keys-none').hidden = shown > 0;
  });
}

/** Overlay of the shortcuts (in-page dialog). */
export function openShortcuts() {
  const dlg = openDialog({
    title: 'Raccourcis clavier',
    subtitle: 'Tous les gestes du clavier, par endroit. Un raccourci tapé dans un champ de texte y garde son sens.',
    icon: 'command',
    size: 'lg',
    body: shortcutsMarkup(),
    actions: [
      { id: 'copy', label: 'Copier l’aide-mémoire', icon: 'copy' },
      { id: 'close', label: 'Fermer', primary: true, safe: true },
    ],
  });
  bindShortcuts(dlg.body);
  dlg.el.classList.add('sh-keys-dialog');
  dlg.result.then((id) => {
    if (id === 'copy') copyText(shortcutListText()).then((ok) => announce(ok ? 'Aide-mémoire des raccourcis copié.' : 'Copie impossible.'));
  });
  return dlg;
}
