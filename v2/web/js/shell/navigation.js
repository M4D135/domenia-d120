// Navigation of the shell: history of the screens (TRV-170), back and forward, recent screens, former names of screens
// redirected (TRV-066), global subject chosen by Rechercher only (TRV-169, TRV-171), expert view for one navigation
// (TRV-167). Navigation only: nothing here reads the directory.
import { state, emit, setLists } from './store.js';

// ---------- Former names (Domenia 1 tabs, bookmarks of the guides) ----------

/** Former screen names → current address. */
export const ALIASES = Object.freeze({
  journal: '#/operations',
  index: '#/parametres?section=stockage',
  stockage: '#/parametres?section=stockage',
  outils: '#/parametres',
  reglages: '#/parametres',
  support: '#/assistance',
  atelier: '#/requetes',
  parcourir: '#/rechercher?vue=parcourir',
  fiabilite: '#/operations?filtre=verifier',
  aide: '#/shell?onglet=aide',
  raccourcis: '#/shell?onglet=raccourcis',
  coque: '#/shell',
  interface: '#/shell',
  'tableau-de-bord': '#/accueil',
  dashboard: '#/accueil',
});

/** The current address of a former one (« #/journal » → « #/operations »), or null. Parameters are kept. */
export function aliasOf(hash) {
  const m = /^#\/([a-z0-9-]+)(\?.*)?$/i.exec(String(hash ?? ''));
  if (!m) return null;
  const target = ALIASES[m[1].toLowerCase()];
  if (!target) return null;
  if (!m[2]) return target;
  return target.includes('?') ? `${target}&${m[2].slice(1)}` : target + m[2];
}

// ---------- History ----------

const entries = [];
let position = -1;

/** Records the address shown; recognises a back or forward move. */
export function trackHash(hash) {
  if (!hash) return;
  if (entries[position] === hash) return;
  if (entries[position - 1] === hash) position -= 1;
  else if (entries[position + 1] === hash) position += 1;
  else {
    entries.splice(position + 1);
    entries.push(hash);
    if (entries.length > 100) entries.shift();
    position = entries.length - 1;
  }
  remember(hash);
  emit('history', { canBack: canBack(), canForward: canForward() });
}

export function canBack() { return position > 0; }
export function canForward() { return position >= 0 && position < entries.length - 1; }
export function back() { if (canBack()) history.back(); }
export function forward() { if (canForward()) history.forward(); }

/** Address kept in the recent list: transient shell parameters (?coque=…, ?vue=expert) are dropped. */
export function recentAddress(hash) {
  const m = /^(#\/[a-z0-9-]+)(?:\?(.*))?$/.exec(String(hash ?? ''));
  if (!m) return '';
  const params = new URLSearchParams(m[2] ?? '');
  params.delete('coque');
  params.delete('vue');
  const q = params.toString();
  return q ? `${m[1]}?${q}` : m[1];
}

function remember(hash) {
  if (hash.length > 300 || !/^#\/[a-z0-9-]+/.test(hash) || hash.startsWith('#/kit')) return;
  const kept = recentAddress(hash);
  if (!kept) return;
  const list = [kept, ...state.recentPages.filter((h) => h !== kept)].slice(0, 12);
  setLists({ recentPages: list });
}

/** Readable name of a recent address: page label, then the object named by its DN (« Fiche · Camille Martin »). */
export function describeHash(hash, pages) {
  const m = /^#\/([a-z0-9-]+)(?:\?(.*))?$/.exec(hash);
  if (!m) return { label: hash, icon: 'chevronRight' };
  const page = pages.find((p) => p.id === m[1]);
  const params = new URLSearchParams(m[2] ?? '');
  const dn = params.get('dn');
  const q = params.get('q');
  let detail = '';
  if (dn) detail = rdnValue(dn);
  else if (q) detail = `« ${q.slice(0, 40)} »`;
  else if (params.get('onglet')) detail = params.get('onglet');
  const label = (page?.label ?? m[1]) + (detail ? ` · ${detail}` : '');
  return { label, icon: page?.icon ?? 'chevronRight', id: m[1] };
}

/** First value of a DN (« CN=Camille Martin,OU=… » → « Camille Martin »), escapes removed. */
export function rdnValue(dn) {
  const m = /^[A-Za-z]+=((?:\\.|[^,])+)/.exec(String(dn ?? ''));
  return m ? m[1].replace(/\\(.)/g, '$1') : String(dn ?? '');
}

// ---------- Global subject (Domenia 1 Test-DomeniaSelectorAllowed) ----------

/** Only Rechercher (and its Parcourir view) chooses the subject; the other screens show it. */
export const SUBJECT_PICKERS = Object.freeze(['rechercher']);
const KIND_LABELS = { user: 'Utilisateur', computer: 'Poste', group: 'Groupe', ou: 'OU', contact: 'Contact' };

/**
 * Sets the global subject. Refused (false) from a screen that is not a subject picker: a second picker would create an
 * inconsistent subject.
 * @param {{ kind: string, name: string, dn: string, objectGuid?: string } | null} subject @param {string} fromPage
 */
export function setSubject(subject, fromPage) {
  if (!SUBJECT_PICKERS.includes(fromPage)) {
    console.warn(`Sujet global refusé : seul Rechercher choisit le sujet (demandé par ${fromPage}).`);
    return false;
  }
  if (subject && (!subject.name || !subject.dn)) return false;
  state.subject = subject ? {
    kind: KIND_LABELS[subject.kind] ? subject.kind : 'object', name: String(subject.name).slice(0, 120), dn: String(subject.dn).slice(0, 2048),
    objectGuid: subject.objectGuid ? String(subject.objectGuid) : null,
  } : null;
  publishSubject();
  return true;
}

/** Clears the selection everywhere (TRV-171): nothing of the former object stays shown; nothing is read. */
export function clearSubject() {
  if (!state.subject) return;
  state.subject = null;
  publishSubject();
}

function publishSubject() {
  emit('subject', state.subject);
  window.dispatchEvent(new CustomEvent('domenia:subject', { detail: state.subject }));
}

/** « Poste · PC-COMPTA-014 », or '' without subject. */
export function subjectChip(subject = state.subject) {
  if (!subject) return '';
  return `${KIND_LABELS[subject.kind] ?? 'Fiche'} · ${subject.name}`;
}

/** Plain text of the subject for a ticket (Ctrl+Maj+C): type, name, container path, DN. */
export function subjectSummary(subject = state.subject) {
  if (!subject) return '';
  const parts = String(subject.dn).split(/(?<!\\),/).slice(1).filter((p) => !/^DC=/i.test(p)).map((p) => rdnValue(p)).reverse();
  const lines = [subjectChip(subject)];
  if (parts.length) lines.push(`OU : ${parts.join(' / ')}`);
  lines.push(`DN : ${subject.dn}`);
  return lines.join('\r\n');
}

// ---------- Expert view for one navigation (Domenia 1 Get-DomeniaExpertTabDecision) ----------

/**
 * Decision on an expert view asked from the essential profile: shown for this navigation only, the profile never changes.
 * @param {{ profile: string, allowExpert?: boolean, applies?: boolean, reason?: string }} o
 */
export function expertDecision({ profile, allowExpert = true, applies = true, reason = '' }) {
  if (!applies) return { show: false, temporary: false, changesProfile: false, reason: reason || 'Vue sans objet pour cet écran.' };
  if (!allowExpert) return { show: false, temporary: false, changesProfile: false, reason: 'Vue réservée au profil Expert, masqué par l’administrateur.' };
  if (profile === 'expert') return { show: true, temporary: false, changesProfile: false, reason: '' };
  return { show: true, temporary: true, changesProfile: false, reason: 'Vue experte affichée pour cette consultation ; le profil Essentiel est conservé.' };
}
