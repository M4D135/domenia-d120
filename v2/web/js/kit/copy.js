// One-click copy with visual feedback: the icon turns into a check with a burst, the tip says « Copié ».
// Values sit in a data attribute (escaped); secrets never go through this button.
import { glyph } from './glyphs.js';
import { esc, writeClipboard, announce, motionReduced } from './util.js';

const FEEDBACK_MS = 1600;

/**
 * Markup of a copy button. bindCopy() on an ancestor makes it work.
 * @param {string} value                     Text copied.
 * @param {{ label?: string, done?: string, text?: string, size?: 'sm'|'xs' }} [opts]  done: feedback (« Chemin copié »).
 * @returns {string}
 */
export function copyButton(value, { label = 'Copier', done = 'Copié', text = '', size = 'xs' } = {}) {
  const cls = text ? `btn ghost ${size === 'sm' ? 'sm' : 'xs'} k-copy with-text` : `btn ghost icon ${size === 'sm' ? 'sm' : 'xs'} k-copy`;
  return `<button class="${cls}" type="button" data-copy="${esc(value)}" data-done="${esc(done)}" aria-label="${esc(label)}" data-tip="${esc(label)}">`
    + `<span class="k-copy-ico" aria-hidden="true">${glyph('copy', 'a')}${glyph('check', 'b')}</span>${text ? `<span>${esc(text)}</span>` : ''}</button>`;
}

/**
 * Delegated handler for every copy button inside scope.
 * @param {HTMLElement|Document} scope
 * @returns {() => void} unbind
 */
export function bindCopy(scope) {
  const onClick = (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-copy]') : null;
    if (!b || !(scope instanceof Document ? true : scope.contains(b))) return;
    e.preventDefault();
    e.stopPropagation();
    const done = b.dataset.done || 'Copié';
    writeClipboard(b.dataset.copy ?? '').then((ok) => {
      const label = b.getAttribute('aria-label') ?? 'Copier';
      b.classList.remove('copied', 'failed');
      if (!motionReduced()) void b.offsetWidth;
      b.classList.add(ok ? 'copied' : 'failed');
      b.dataset.tip = ok ? done : 'Copie impossible';
      announce(ok ? `${done} dans le presse-papiers.` : 'Copie impossible : le presse-papiers est indisponible.');
      clearTimeout(Number(b.dataset.timer ?? 0));
      b.dataset.timer = String(setTimeout(() => {
        b.classList.remove('copied', 'failed');
        b.dataset.tip = label;
      }, FEEDBACK_MS));
    });
  };
  scope.addEventListener('click', onClick);
  return () => scope.removeEventListener('click', onClick);
}
