// Rights tab: estimate of the effective rights of the session account on the object (FIC-003, Start-PermissionAnalysis):
// ten capabilities in two balanced columns, allowed, denied or undetermined (always with the reason), each with the access entry
// that decides it (improvement). An estimate only: the controller stays the final authority. Read on the operator’s gesture.
import { glyph, pill, writeClipboard, int } from '../../kit/index.js';
import { esc, errorText, toast, applyVars } from '../../ui.js';
import { failure, skeleton, emptyNote, stamp, NBSP } from './common.js';

const ICONS = { read: 'eye', edit: 'edit', account: 'user', password: 'key', group: 'group', move: 'ou', delete: 'trash', create: 'plus', secrets: 'lock', acl: 'shield' };
const TONES = { allowed: 'ok', denied: 'alert', unknown: 'off' };

/**
 * @param {HTMLElement} panel
 * @param {any} S
 */
export function mountRights(panel, S) {
  let data = null;
  let busy = false;

  function render() {
    const action = S.sheet.actions.find((a) => a.id === 'rights');
    const off = action && !action.available ? ` aria-disabled="true" data-tip="${esc(action.reason ?? '')}"` : '';
    const head = `<div class="fi-rights-head card fi-card">
        <span class="card-icon">${glyph('shield')}</span>
        <div class="fi-card-titles"><h3>Droits effectifs du compte de session</h3><p class="fi-card-sub">Estimation d’après la liste d’accès de l’objet et les groupes de votre compte (y compris Tout le monde et Utilisateurs authentifiés)</p></div>
        <div class="fi-rights-actions">${data && !data.error ? `<button class="btn sm ghost" type="button" data-r="copy">${glyph('copy')}Copier le rapport</button>` : ''}
          ${data ? `<button class="btn sm fi-net" type="button" data-r="run"${off}>${glyph('refresh')}Estimer de nouveau</button>` : ''}</div>
      </div>`;
    let body;
    if (busy) body = `<div class="fi-caps">${Array.from({ length: 10 }, () => `<div class="fi-cap">${skeleton(2)}</div>`).join('')}</div>`;
    else if (data?.error) body = `<section class="card fi-card">${failure(data.error, { title: 'Estimation impossible' })}</section>`;
    else if (data) {
      const d = data;
      const counts = { allowed: 0, denied: 0, unknown: 0 };
      d.rows.forEach((r) => { counts[r.state] = (counts[r.state] ?? 0) + 1; });
      body = `<div class="fi-rights-sum fi-enter">
          <span class="fi-count-chip ok">${glyph('check')}<b>${int(counts.allowed)}</b> autorisé${counts.allowed > 1 ? 's' : ''}</span>
          <span class="fi-count-chip alert">${glyph('x')}<b>${int(counts.denied)}</b> refusé${counts.denied > 1 ? 's' : ''}</span>
          <span class="fi-count-chip">${glyph('info')}<b>${int(counts.unknown)}</b> indéterminé${counts.unknown > 1 ? 's' : ''}</span>
          <span class="fi-faint">Propriétaire${NBSP}: <b>${esc(d.owner)}</b> · ${int(d.matchingAces)} entrée${d.matchingAces > 1 ? 's' : ''} pour votre compte · ${esc(stamp(d.readAt))}</span></div>
        <div class="fi-caps">${d.rows.map((r, n) => `<article class="fi-cap fi-enter" data-state="${esc(r.state)}" data-tone="${TONES[r.state] ?? 'off'}" data-j="${n}">
            <span class="fi-cap-ico">${glyph(ICONS[r.id] ?? 'shield')}</span>
            <div class="fi-cap-body"><span class="fi-cap-head"><b>${esc(r.capability)}</b>${pill(TONES[r.state] ?? 'off', r.stateLabel, { size: 'sm' })}</span>
              <span class="fi-cap-detail">${esc(r.detail)}</span>
              ${r.ace ? `<span class="fi-cap-ace">${glyph('key')}<span>${esc(r.ace)}</span></span>` : ''}</div></article>`).join('')}</div>
        <p class="fi-note">${glyph('info')}${esc(d.note)}</p>`;
    } else {
      body = `<section class="card fi-card fi-rights-empty">${emptyNote('shield', 'Estimation non demandée', 'La lecture de la liste d’accès part seulement sur votre clic. Le contrôleur reste l’autorité finale : seul un refus réel verrouille une action.',
        `<button class="btn subtle fi-net" type="button" data-r="run"${off}>${glyph('shield')}Estimer les droits effectifs</button>`)}</section>`;
    }
    panel.innerHTML = `<div class="fi-rights">${head}${body}</div>`;
    applyVars(panel);
  }

  async function run() {
    busy = true;
    render();
    try {
      data = await S.ctx.call('fiche.rights', { dn: S.sheet.identity.dn });
    } catch (err) {
      data = { error: err };
    }
    busy = false;
    if (S.alive) render();
  }

  const onClick = async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const b = t?.closest('[data-r], [data-retry]');
    if (!b) return;
    if (b.getAttribute('aria-disabled') === 'true') { toast(b.dataset.tip || 'Indisponible.', { tone: 'info' }); return; }
    if (b.dataset.r === 'copy' && data?.report) {
      const ok = await writeClipboard(data.report);
      toast(ok ? 'Rapport des droits copié.' : 'Copie impossible.', { tone: ok ? 'ok' : 'warn', life: 2600 });
      return;
    }
    run();
  };
  panel.addEventListener('click', onClick);
  render();
  return {
    run,
    /** Gesture: estimate now; route state: show and highlight the button only. */
    focus({ run: now = true } = {}) {
      if (now) { run(); return; }
      const b = panel.querySelector('[data-r="run"]');
      b?.classList.remove('fi-focus');
      void b?.offsetWidth;
      b?.classList.add('fi-focus');
      b?.focus({ preventScroll: true });
    },
    update() { if (!busy) render(); },
    refresh() { data = null; render(); },
    destroy() { panel.removeEventListener('click', onClick); },
  };
}

export { errorText };
