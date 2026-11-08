import { test, eq, ok } from './harness.mjs';
import { protectDemoFiles } from '../../web/js/shell/demo-files.js';

test('Démonstration isolée : garde capture avant le picker natif et avant le FileReader de la page', () => {
  const root = document.createElement('div'); document.body.append(root);
  const input = document.createElement('input'); input.type = 'file'; root.append(input);
  let mode = { modeReason: 'demonstration' }; let read = 0; const notes = [];
  const dispose = protectDemoFiles(() => mode, text => notes.push(text), root);
  root.addEventListener('change', () => read++); root.addEventListener('drop', () => read++);
  try {
    const click = new MouseEvent('click', { bubbles: true, cancelable: true }); input.dispatchEvent(click);
    ok(click.defaultPrevented, 'pas de dialogue fichier natif');
    input.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
    const drop = new Event('drop', { bubbles: true, cancelable: true });
    Object.defineProperty(drop, 'dataTransfer', { value: { files: [{}], items: [{ kind: 'file' }] } });
    input.dispatchEvent(drop);
    eq(read, 0, 'aucun handler de lecture de page atteint');
    eq(notes.length, 3, 'raison explicite à chaque tentative');
    mode = { modeReason: 'argument' };
    input.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
    eq(read, 1, 'simulation historique/E2E préservée');
  } finally { dispose(); root.remove(); }
});

test('Garde fichiers : informations de mode absentes refusées, texte collé explicite non lu comme fichier', () => {
  const root = document.createElement('div'); const input = document.createElement('input'); input.type = 'file'; root.append(input);
  let handled = 0; const dispose = protectDemoFiles(() => null, () => {}, root);
  root.addEventListener('paste', () => handled++);
  try {
    const click = new MouseEvent('click', { bubbles: true, cancelable: true }); input.dispatchEvent(click);
    ok(click.defaultPrevented, 'pas de fenêtre avant qualification du mode');
    const paste = new Event('paste', { bubbles: true, cancelable: true });
    Object.defineProperty(paste, 'clipboardData', { value: { files: [], items: [{ kind: 'string' }] } });
    input.dispatchEvent(paste); eq(handled, 1, 'saisie explicite reste disponible en mémoire');
  } finally { dispose(); }
});
