// Visual of the rule that picks the account of the next workstation operation (MAC-001, improvement « schéma visuel de la
// cascade avec la ligne active surlignée »): the levels in the order of the worker context, the first configured one lit,
// the ones it shadows dimmed, the pauses after a refusal marked. A level with nothing configured folds to one line (its title
// and its state); its explanation opens on demand. Rendering only, from machine.account.state.
import { glyph } from '../../kit/glyphs.js';
import { esc, uid } from '../../kit/util.js';

/** Icon of a source (MachineAccountSource / SecretsAccountSource, camelCase). */
export const SOURCE_ICONS = {
  temporaryLocal: 'monitor', temporary: 'clock', typed: 'key', remote: 'users', connection: 'link', windows: 'user',
  secrets: 'shield', directory: 'domain',
};

/**
 * @param {Array<any>} levels  MachineAccountLevel[]
 * @param {{ label: string, compact?: boolean }} o
 */
export function cascadeMarkup(levels, o) {
  const active = levels.findIndex((l) => l.state === 'active');
  const id = uid('mac-lv');
  return `<ol class="mac-cascade${o.compact ? ' compact' : ''}" aria-label="${esc(o.label)}">
    ${levels.map((l, n) => {
    const passed = active >= 0 && n > active;
    const quiet = !l.account && (l.state === 'empty' || l.state === 'notApplicable');
    const detail = l.paused && l.pauseReason ? l.pauseReason : l.detail;
    // States go in data attributes: a class such as « empty » would take the global empty-state style.
    const attrs = `class="mac-level${quiet ? ' quiet' : ''}" data-state="${esc(l.state)}"${passed ? ' data-shadowed' : ''}${l.paused ? ' data-paused' : ''} data-j="${n}"${l.state === 'active' ? ' aria-current="step"' : ''}`;
    const state = `<span class="mac-state ${esc(l.tone)}">${l.paused ? glyph('pause') : l.state === 'active' ? glyph('check') : ''}${esc(l.stateLabel)}</span>`;
    if (quiet) {
      const more = o.compact ? '' : `<button class="mac-level-more" type="button" data-level-more aria-expanded="false" aria-controls="${id}-${n}" aria-label="${esc(`Détail du niveau ${l.rank}`)}" data-tip="${esc(detail)}">${glyph('info')}</button>`;
      return `<li ${attrs}>
      <span class="mac-rank" aria-hidden="true"><span>${l.rank}</span></span>
      <span class="mac-level-ico" aria-hidden="true">${glyph(SOURCE_ICONS[l.source] ?? 'user')}</span>
      <div class="mac-level-body">
        <div class="mac-level-top"><b>${esc(l.title)}</b>${more}${state}</div>
        ${o.compact ? '' : `<span class="mac-level-detail" id="${id}-${n}" hidden>${esc(detail)}</span>`}
      </div>
    </li>`;
    }
    return `<li ${attrs}>
      <span class="mac-rank" aria-hidden="true"><span>${l.rank}</span></span>
      <span class="mac-level-ico" aria-hidden="true">${glyph(SOURCE_ICONS[l.source] ?? 'user')}</span>
      <div class="mac-level-body">
        <div class="mac-level-top"><b>${esc(l.title)}</b>${state}</div>
        <span class="mac-level-account">${esc(l.account ?? '')}</span>
        ${o.compact ? '' : `<span class="mac-level-detail">${esc(detail)}</span>`}
      </div>
    </li>`;
  }).join('')}
  </ol>`;
}

/** Opens or folds the explanation of a quiet level (delegated click of the page). Returns whether the click was handled. */
export function toggleLevel(target) {
  const button = target instanceof Element ? target.closest('[data-level-more]') : null;
  if (!button) return false;
  const detail = document.getElementById(button.getAttribute('aria-controls') ?? '');
  if (!detail) return true;
  const open = button.getAttribute('aria-expanded') !== 'true';
  button.setAttribute('aria-expanded', String(open));
  detail.hidden = !open;
  button.closest('.mac-level')?.classList.toggle('open', open);
  return true;
}
