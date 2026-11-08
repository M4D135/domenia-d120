// Explicit file/default transfer for the three real boards; a preview is never an application.
import { openDialog } from '../kit/dialog.js';
import { esc } from '../ui.js';
import { importJson } from '../shell/exports.js';

const labels = { Fleet: 'Accueil', Computer: 'Poste', Software: 'Logiciels' };
export function createBoardTransfer(call, isAlive, chooseFile = importJson) {
  let dialog = null;
  let pending = false;
  let disposed = false;
  const alive = () => !disposed && isAlive();
  async function prepare(kind, board, expectedChoiceToken) {
    if (!alive() || pending) return null;
    pending = true;
    try {
      const file = kind === 'import' ? await chooseFile(`Importer une disposition · ${labels[board]}`) : null;
      if (!alive() || kind === 'import' && !file) return null;
      const preview = await call(`shell.board.${kind}.preview`, { board, ...(file ? { text: file.text } : {}) });
      if (!alive()) return null;
      const body = document.createElement('div');
      body.innerHTML = `<p>${esc(preview.summary)}</p><p>Cette confirmation remplace le choix affiché, même s’il est vide. Le choix remplacé reste dans les cinq versions précédentes.</p>
        ${file ? `<p>Fichier : ${esc(file.fileName)} · original conservé.</p>` : `<p>Origine : ${esc(preview.source)}.</p>`}
        <p>SHA-256 ${file ? 'du texte UTF-8' : 'de la source'} : <span class="code">${esc(preview.sha256 ?? preview.sourceSha256)}</span></p>
        ${preview.items.length ? `<ol>${preview.items.map(i => `<li>${esc(i.title || i.queryBinding?.name || i.key)}${i.group ? ` · ${esc(i.group)}` : ''}${i.paused ? ' · en pause' : ''}${i.queryBinding ? ` · révision ${i.queryBinding.revision} · ${esc(i.queryBinding.fingerprint)}` : ''}</li>`).join('')}</ol>` : '<p>Tableau volontairement vide.</p>'}
        ${preview.needsQueryConsent ? '<label><input type="checkbox" data-board-bind> Je confirme les révisions proposées. Cette liaison n’autorise aucune exécution distante.</label>' : ''}`;
      dialog = openDialog({ title: `${kind === 'import' ? 'Importer' : 'Rétablir le défaut'} · ${labels[board]}`, icon: 'layers', size: 'md', body,
        actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'apply', label: kind === 'import' ? 'Importer cette disposition' : 'Appliquer ce défaut', primary: true, disabled: Boolean(preview.needsQueryConsent) }] });
      const confirm = body.querySelector('[data-board-bind]');
      confirm?.addEventListener('change', () => { body.closest('.k-dlg')?.querySelector('[data-id="apply"]')?.toggleAttribute('disabled', !confirm.checked); });
      if (await dialog.result !== 'apply' || !alive() || preview.needsQueryConsent && !confirm?.checked) return null;
      return { operation: `shell.board.${kind}.apply`, args: { board, expectedChoiceToken,
        ...(file ? { text: file.text, sha256: preview.sha256, allowQueryProposal: Boolean(confirm?.checked),
          ...(preview.queryBindingsSha256 ? { queryBindingsSha256: preview.queryBindingsSha256 } : {}), ...(preview.sessionStamp ? { sessionStamp: preview.sessionStamp } : {}) }
          : { sourceSha256: preview.sourceSha256 }) } };
    } finally { pending = false; dialog = null; }
  }
  return { prepare, destroy() { disposed = true; dialog?.close('cancel'); dialog = null; } };
}
