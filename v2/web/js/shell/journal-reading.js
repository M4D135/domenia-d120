import { state, emit } from './store.js';
import { markAllRead } from './notify.js';
import { markOf, linesAfter, maskNames } from '../pages/parametres/pure.js';
import { openDialog } from '../kit/dialog.js';
import { copyText } from '../ui.js';
import { protectText } from './summary.js';

// Session-only acknowledgements; the file, errors and history are never deleted.
let readMark = null;
let readCount = 0;
let sessionStart = null;
export function acknowledgeJournal(view) {
  sessionStart = view?.file?.sessionStart ?? null;
  readMark = markOf(view?.lines ?? []);
  readCount = view?.file?.sessionErrors ?? 0;
  markAllRead();
  emit('journal-read', null);
}
export function unreadJournalErrors(view) {
  const count = view?.file?.sessionErrors ?? 0;
  if (sessionStart !== (view?.file?.sessionStart ?? null)) return count;
  if (!readMark) return Math.max(0, count - readCount);
  return linesAfter(view?.lines ?? [], readMark).filter((l) => l.level === 'ERREUR'
    && (!sessionStart || !l.at || Date.parse(l.at) >= Date.parse(sessionStart))).length;
}

export function journalMaskNames(snapshot = state) {
  const s = snapshot.session;
  const login = s?.account?.login ?? '';
  const controller = s?.controller?.dnsName ?? '';
  return [s?.domain?.dnsName, s?.domain?.netbiosName, s?.domain?.rootDn,
    controller, controller.split('.')[0], login, login.split('\\').at(-1)?.split('@')[0],
    s?.account?.displayName, s?.account?.dn, snapshot.subject?.name, snapshot.subject?.dn, snapshot.target];
}

/** One frozen text is both previewed and copied. A long preview explicitly announces the unseen remainder. */
export async function copyJournal(text, toast, names = journalMaskNames()) {
  const safe = protectText(String(text ?? ''));
  const masked = maskNames(safe, names);
  const d = openDialog({ title: 'Copier le journal', icon: 'copy', size: 'lg',
    body: '<label class="pr-check"><input type="checkbox" class="k-checkbox" data-mask checked><span>Masquer les noms connus de la session et de l’objet sélectionné</span></label><p class="pr-sub">Relisez cet aperçu avant de partager. D’autres noms internes peuvent rester visibles.</p><p data-preview-limit></p><pre class="pr-copy-preview" data-preview></pre>',
    actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'ok', label: 'Copier', primary: true }] });
  d.body.dataset.page = 'parametres';
  const choice = d.body.querySelector('[data-mask]');
  const value = () => choice.checked ? masked : safe;
  const refresh = () => {
    const selected = value();
    d.body.querySelector('[data-preview]').textContent = selected.slice(0, 20000) || 'Rien à copier.';
    d.body.querySelector('[data-preview-limit]').textContent = selected.length > 20000
      ? `Aperçu limité à 20 000 caractères sur ${selected.length}. La copie contiendra tout le texte.` : 'Aperçu complet du texte à copier.';
  };
  choice.addEventListener('change', refresh); refresh();
  if (await d.result !== 'ok') return;
  const ok = await copyText(value());
  toast(ok ? 'Journal copié.' : 'Copie impossible : presse-papiers indisponible.', { tone: ok ? 'ok' : 'warn' });
}
