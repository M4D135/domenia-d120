// Visual of the rule that picks the account of the next workstation operation (MAC-001, improvement « schéma visuel de la
// cascade avec la ligne active surlignée »): the levels in the order of the worker context, the first configured one lit,
// the ones it shadows dimmed, the pauses after a refusal marked. Rendering only, from machine.account.state.
import { glyph } from '../../kit/glyphs.js';
import { esc } from '../../kit/util.js';

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
  return `<ol class="mac-cascade${o.compact ? ' compact' : ''}" aria-label="${esc(o.label)}">
    ${levels.map((l, n) => {
    const passed = active >= 0 && n > active;
    // States go in data attributes: a class such as « empty » would take the global empty-state style.
    return `<li class="mac-level" data-state="${esc(l.state)}"${passed ? ' data-shadowed' : ''}${l.paused ? ' data-paused' : ''} data-j="${n}"${l.state === 'active' ? ' aria-current="step"' : ''}>
      <span class="mac-rank" aria-hidden="true"><span>${l.rank}</span></span>
      <span class="mac-level-ico" aria-hidden="true">${glyph(SOURCE_ICONS[l.source] ?? 'user')}</span>
      <div class="mac-level-body">
        <div class="mac-level-top"><b>${esc(l.title)}</b><span class="mac-state ${esc(l.tone)}">${l.paused ? glyph('pause') : l.state === 'active' ? glyph('check') : ''}${esc(l.stateLabel)}</span></div>
        <span class="mac-level-account${l.account ? '' : ' none'}">${l.account ? esc(l.account) : '<span aria-label="non configuré">—</span>'}</span>
        ${o.compact ? '' : `<span class="mac-level-detail">${esc(l.paused && l.pauseReason ? l.pauseReason : l.detail)}</span>`}
      </div>
    </li>`;
  }).join('')}
  </ol>`;
}
