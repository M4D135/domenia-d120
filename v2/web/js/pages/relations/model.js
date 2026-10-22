// Utilisateurs et postes: vocabulary of the qualifications (Domenia 1 D043: a badge and its rule, never a percentage),
// the steps of the in-page association (port of RelationRules.Step and Refusal, Domenia 1 D045), small markup helpers and
// formatting shared by the modules of the screen. No bridge call here.
import { glyph } from '../../kit/glyphs.js';
import { esc, int, count, NBSP } from '../../kit/util.js';
import { relTime, formatDateTime } from '../../ui.js';

/** Qualification badges, in the order of the facets (keys of the contract, docs/ops/relations.md). */
export const BADGES = {
  declared: { label: 'Déclaré', icon: 'pin', tone: 'ok', tip: 'Association déclarée par un opérateur dans Domenia.' },
  observed: { label: 'Observé', icon: 'eye', tone: 'info', tip: 'Session lue sur le poste à la date indiquée. Une observation ne vaut pas affectation.' },
  history: { label: 'Historique', icon: 'history', tone: 'off', tip: 'Ouverture de session ancienne relevée dans un journal ou un profil. Historique, pas présence actuelle.' },
  imported: { label: 'Importé', icon: 'download', tone: 'info', tip: 'Ligne reprise d’un fichier importé. Exactitude dépendante du fichier source.' },
  hint: { label: 'Indice', icon: 'tag', tone: 'off', tip: 'Attribut AD ou inventaire qui suggère un lien, sans observation de session.' },
  contradictory: { label: 'Contradictoire', icon: 'alert', tone: 'alert', tip: 'Affectation déclarée et session observée désignent des comptes différents pour ce poste. Les deux sont gardées, avec leur nature : aucune fusion automatique.' },
  toCheck: { label: 'À vérifier', icon: 'info', tone: 'warn', tip: 'Origine non reconnue : à vérifier avant de s’y fier.' },
};

/** Facets of « Toutes les associations »: six natures (their sum is the total) and the contradiction mark. */
export const BADGE_ORDER = ['declared', 'observed', 'history', 'imported', 'hint', 'contradictory', 'toCheck'];

/** Natures only (an association keeps its nature; a contradiction is a mark beside it). */
export const NATURES = ['declared', 'observed', 'history', 'imported', 'hint', 'toCheck'];

/** Grid enum options of the qualification column (filter by list): the natures. */
export const BADGE_OPTIONS = NATURES.map((id) => ({ value: id, label: BADGES[id].label, tone: BADGES[id].tone }));

/** Badge pill (colour by data-badge, page stylesheet). */
export function badge(id, { label, size = '', tip } = {}) {
  const b = BADGES[id] ?? BADGES.toCheck;
  const text = label ?? b.label;
  return `<span class="rel-badge${size ? ` ${size}` : ''}" data-badge="${esc(id in BADGES ? id : 'toCheck')}" data-tip="${esc(tip ?? b.tip)}">${glyph(b.icon)}<span>${esc(text)}</span></span>`;
}

/** Nature badge of a row, with the contradiction mark and the « session » tag beside it (never in place of the nature). */
export function qualification(row, { size = 'sm' } = {}) {
  const mark = row.contradicted ? `<span class="rel-contra-mark" data-tip="${esc(BADGES.contradictory.tip)}">${glyph('alert')}<span>Contradiction</span></span>` : '';
  const session = row.persistence === 'session' ? `<span class="rel-session-tag" data-tip="Observée pendant cette session, pas encore enregistrée.">${glyph('clock')}<span>Session</span></span>` : '';
  return `<span class="rel-qual">${badge(row.badge, { size, tip: row.rule })}${mark}${session}</span>`;
}

/** Small coloured dot of a badge (legends). */
export function dot(id) {
  return `<span class="rel-dot" data-badge="${esc(id in BADGES ? id : 'toCheck')}" aria-hidden="true"></span>`;
}

/** Avatar of a user (initials) or a workstation (screen icon). */
export function avatar(kind, name, cls = '') {
  if (kind === 'computer') return `<span class="rel-avatar pc ${cls}" aria-hidden="true">${glyph('monitor')}</span>`;
  const parts = String(name ?? '').replace(/\(.*?\)/g, '').trim().split(/[\s.\-_]+/).filter(Boolean);
  const initials = ((parts[0]?.[0] ?? '?') + (parts.length > 1 ? parts.at(-1)[0] : '')).toUpperCase();
  return `<span class="rel-avatar ${cls}" aria-hidden="true">${esc(initials)}</span>`;
}

const SHORT_DATE = new Intl.DateTimeFormat('fr-FR', { day: '2-digit', month: '2-digit', year: 'numeric' });
const SHORT_DATE_TIME = new Intl.DateTimeFormat('fr-FR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });

/**
 * Readable date of a proof: relative within two days (« il y a 3 h », « hier »), the local date beyond (« 08/10/2026 »), so a
 * month never reads like a minute. Null without date.
 */
export function dateText(iso, { time = false } = {}) {
  const t = Date.parse(iso ?? '');
  if (Number.isNaN(t)) return null;
  if (Math.abs(Date.now() - t) < 2 * 86400_000) return relTime(iso);
  return (time ? SHORT_DATE_TIME : SHORT_DATE).format(t);
}

/** « il y a 3 h » or « 08/10/2026 » with the full date in the tip; « — » without date (never a zero). */
export function when(iso, prefix = '') {
  const text = dateText(iso);
  if (!text) return '<span class="rel-none" aria-label="non renseigné">—</span>';
  return `<time datetime="${esc(iso)}" data-tip="${esc(formatDateTime(iso) ?? '')}">${esc(prefix + text)}</time>`;
}

/** Operating system without its edition (« Windows Server 2025 » for « Windows Server 2025 Standard »). */
export function shortOs(os) {
  return String(os ?? '').replace(/\s+(Standard|Datacenter|Professionnel|Professional|Entreprise|Enterprise|Famille|Home|Education|Éducation|Pro)\b.*$/i, '').trim();
}

/** Number with its noun (French plural rule), as text. */
export const nouns = (n, one, many) => count(n, one, many);

export { int, esc, NBSP };

/** Operator text of an error; browser errors (no code) are logged and replaced by a French sentence. */
export function errText(err, fallback = 'Erreur interne de l’interface.') {
  if (!err?.code) console.error(err);
  return err && err.code && err.message ? String(err.message) : fallback;
}

/** Is a route parameter usable as a subject reference (DN, identifier or workstation name)? */
export function cleanRef(value) {
  const v = typeof value === 'string' ? value.trim() : '';
  return v.length > 0 && v.length <= 2048 ? v : null;
}

/** Workstation names of a list handed over by another screen (« liste=PC-PAR-0042,PC-PAR-0043 »): 50 at most. */
export function loadedList(value) {
  if (typeof value !== 'string') return [];
  return [...new Set(value.split(',').map((x) => x.trim()).filter((x) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/.test(x)))].slice(0, 50);
}

/** Readable pair « j.martin → PC-PAR-0042 ». */
export const pair = (user, computer) => `${user} → ${computer}`;

/** Status pill of an attempt or a candidate (tone of the contract). */
export function tonePill(tone, label) {
  const t = ['ok', 'warn', 'alert', 'info', 'off'].includes(tone) ? tone : 'off';
  return `<span class="k-pill ${t} sm"><span class="k-pill-dot" aria-hidden="true"></span>${esc(label)}</span>`;
}

/** Empty state with a floating illustration, a title, a text and optional buttons (trusted markup). */
export function empty(icon, title, text, actions = '') {
  return `<div class="rel-empty"><div class="rel-empty-art">${glyph(icon)}<span class="rel-empty-orbit" aria-hidden="true"></span></div>
    <h3>${esc(title)}</h3><p>${esc(text)}</p>${actions ? `<div class="rel-empty-actions">${actions}</div>` : ''}</div>`;
}

/** Skeleton lines (the router waits until no .skeleton is left before signalling the screen as ready). */
export const sk = (cls) => `<span class="skeleton rel-sk ${cls}"></span>`;

// ---------------------------------------------------------------------------------------------- association steps

/**
 * Steps of the in-page association (Domenia 1 Step-DomeniaAssociationState, mirrored from RelationRules.Step): idle → searching
 * → candidate → pending → verifying → saved or failed. A refused event keeps the state and says why in one sentence.
 * @param {'idle'|'searching'|'candidate'|'pending'|'verifying'|'saved'|'failed'} state
 * @param {'search'|'results'|'pick'|'confirm'|'verified'|'verifyFailed'|'cancel'|'subjectChanged'|'reset'} event
 * @returns {{ state: string, accepted: boolean, reason: string }}
 */
export function associationStep(state, event) {
  const next = (() => {
    switch (event) {
      case 'reset': case 'subjectChanged': return 'idle';
      case 'cancel': return ['searching', 'candidate', 'pending', 'verifying', 'failed'].includes(state) ? 'idle' : null;
      case 'search': return ['idle', 'candidate', 'failed', 'saved'].includes(state) ? 'searching' : null;
      case 'results': return state === 'searching' ? 'candidate' : null;
      case 'pick': return ['candidate', 'saved', 'failed'].includes(state) ? 'pending' : null;
      case 'confirm': return state === 'pending' ? 'verifying' : null;
      case 'verified': return state === 'verifying' ? 'saved' : null;
      case 'verifyFailed': return state === 'verifying' ? 'failed' : null;
      default: return null;
    }
  })();
  return next ? { state: next, accepted: true, reason: '' } : { state, accepted: false, reason: associationRefusal(state, event) };
}

const C = `${NBSP}: `;

/** One French sentence per refused step (Domenia 1 Get-DomeniaAssociationRefusal, mirrored from RelationRules.Refusal). */
export function associationRefusal(state, event) {
  if (event === 'pick') {
    if (state === 'pending') return `Une association attend déjà sa confirmation${C}confirmez-la ou annulez-la avant d’en choisir une autre.`;
    if (state === 'verifying') return `Vérification en cours${C}attendez son résultat avant de choisir une autre ligne.`;
    if (state === 'searching') return `Recherche en cours${C}attendez les résultats avant de choisir une ligne.`;
    return `Cette liste n’est plus active (détection arrêtée, interrompue ou aucune lancée)${C}relancez la détection ou la recherche, puis choisissez une ligne.`;
  }
  if (event === 'confirm') return state === 'verifying' ? `Vérification déjà en cours${C}attendez son résultat.` : `Confirmation impossible${C}choisissez d’abord une ligne dans les résultats.`;
  if (event === 'search' && (state === 'pending' || state === 'verifying')) return `Une association attend sa confirmation${C}confirmez-la ou annulez-la avant une nouvelle recherche.`;
  if (event === 'search' && state === 'searching') return `Une recherche est déjà en cours${C}attendez son résultat ou arrêtez-la.`;
  if (event === 'results') return `Résultats ignorés${C}aucune recherche n’est en cours.`;
  if (event === 'verified' || event === 'verifyFailed') return `Résultat de vérification ignoré${C}aucune vérification n’est en cours.`;
  if (event === 'cancel') return `Rien à annuler${C}aucune association en cours.`;
  return 'Action impossible à cette étape de l’association.';
}

/**
 * While a target is searched or awaits its confirmation, a new selection does not replace the subject (Domenia 1
 * Resolve-DomeniaRelationSubjectChange, mirrored from RelationRules.SubjectChange). Returns the reason, or '' when allowed.
 */
export function subjectChangeRefusal(state) {
  if (state === 'pending' || state === 'verifying') return `Une association attend sa confirmation${C}confirmez ou annulez avant de changer de sujet.`;
  if (state === 'searching') return `Recherche d’une cible en cours${C}le sujet de départ est conservé.`;
  return '';
}
