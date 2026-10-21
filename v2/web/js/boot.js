// Boot guard, loaded as a classic script in <head> (CSP: external file, no inline script).
// 1. Applies the saved theme and motion before the first paint (same keys and rules as app.js).
// 2. If the interface never starts (a module fails to load or to parse), stops the boot animation and says so.
(() => {
  const root = document.documentElement;
  const THEMES = ['light', 'dark', 'contrast', 'system'];
  const MOTIONS = ['full', 'reduced', 'system'];
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem('domenia.prefs.v1') ?? '{}') ?? {}; } catch { saved = {}; }
  const theme = THEMES.includes(saved.theme) ? saved.theme : 'system';
  const motion = MOTIONS.includes(saved.motion) ? saved.motion : 'full';
  let resolved = theme;
  if (theme === 'system') {
    if (matchMedia('(forced-colors: active), (prefers-contrast: more)').matches) resolved = 'contrast';
    else resolved = matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  root.dataset.theme = resolved;
  root.dataset.themePref = theme;
  root.dataset.motion = motion;

  const START_TIMEOUT_MS = 20_000;
  const fail = (text) => {
    const p = document.querySelector('#app > .boot');
    if (!p || p.classList.contains('failed')) return;
    p.classList.add('failed');
    p.setAttribute('role', 'alert');
    p.textContent = text;
  };
  // Capture phase: script and stylesheet load errors do not bubble. Only acts while the boot screen is shown.
  window.addEventListener('error', (e) => {
    if (!document.querySelector('#app > .boot')) return;
    console.error('Démarrage de l’interface en échec', e.error ?? e.target);
    fail('Domenia n’a pas pu démarrer : un fichier de l’interface est manquant ou illisible. Fermez puis relancez l’application.');
  }, true);
  setTimeout(() => {
    fail('Domenia ne démarre pas : l’interface n’a pas répondu. Fermez puis relancez l’application.');
  }, START_TIMEOUT_MS);
})();
