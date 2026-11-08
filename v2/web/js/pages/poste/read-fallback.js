import { confirmDialog } from '../../kit/index.js';
import { errorText } from './common.js';
import { toast } from '../../ui.js';

/** Grants the single fallback read (CIM refused), after the operator confirms it; true when granted. */
export async function grantFallback(state) {
  const ok = await confirmDialog({
    title: 'Autoriser une seule lecture de repli ?',
    message: `Certaines sources CIM ne répondent pas pour ${state.data.computer.name}. Une seule lecture, sur ce poste seulement, pourra passer par une tâche planifiée unique, créée puis supprimée : elle laisse une trace sur le poste et ajoute au plus 45 secondes. Rien n’est lancé avant votre prochain geste.`,
    confirmLabel: 'Autoriser une lecture',
  });
  if (!ok) return false;
  try {
    const r = await state.call('poste.consent.grant', { dn: state.dn, kind: 'readFallback', minutes: 5 });
    state.data.consent = r.consent;
    state.emit('consent', r.consent);
    toast('Lecture de repli autorisée pour la prochaine lecture incomplète par CIM (5 min).', { tone: 'info' });
    return true;
  } catch (err) {
    toast(errorText(err), { tone: 'alert' });
    return false;
  }
}
