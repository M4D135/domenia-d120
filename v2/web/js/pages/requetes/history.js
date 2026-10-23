import { esc, glyph, dateText, plural } from './shared.js';

/** All retained revisions remain reachable without rendering an unbounded list. */
export function mountRevisionHistory(host, detail, { onRestore = null } = {}) {
  const revisions = [{ revision: detail.revision, savedAt: detail.updatedAt, fingerprint: detail.fingerprint },
    ...[...detail.history].sort((a, b) => b.revision - a.revision)];
  const pageSize = 20;
  let page = 0;
  function render() {
    const first = page * pageSize;
    host.innerHTML = `<ol class="rq-revs compact">${revisions.slice(first, first + pageSize).map((h) => `<li><span class="rq-rev-n">${esc(String(h.revision))}</span><div><b>${h.revision === detail.revision ? 'Révision actuelle' : `Révision ${esc(String(h.revision))}`}</b>
      <span>${esc(dateText(h.savedAt))}${h.fingerprint ? ` · <span class="rq-mono">${esc(h.fingerprint.slice(0, 12))}</span>` : ''}</span></div>
      ${onRestore && h.revision !== detail.revision ? `<button type="button" class="btn xs subtle" data-rev="${esc(String(h.revision))}" aria-label="Restaurer la révision ${esc(String(h.revision))}">${glyph('undo')}Restaurer</button>` : ''}</li>`).join('')}</ol>
      <div class="rq-detail-actions" role="group" aria-label="Pages de l’historique"><button class="btn xs subtle" type="button" data-page="-1"${page === 0 ? ' disabled' : ''}>Plus récentes</button>
      <span aria-live="polite">${first + 1}–${Math.min(first + pageSize, revisions.length)} sur ${esc(plural(revisions.length, 'révision', 'révisions'))}</span>
      <button class="btn xs subtle" type="button" data-page="1"${first + pageSize >= revisions.length ? ' disabled' : ''}>Plus anciennes</button></div>`;
    host.querySelectorAll('[data-page]').forEach((button) => button.addEventListener('click', () => { page += Number(button.dataset.page); render(); }));
    host.querySelectorAll('[data-rev]').forEach((button) => button.addEventListener('click', async () => {
      button.disabled = true;
      try { await onRestore(Number(button.dataset.rev)); } finally { if (button.isConnected) button.disabled = false; }
    }));
  }
  render();
}
