// Utilisateurs et postes: vocabulary of the qualifications (Domenia 1 D043: a badge and its rule, never a percentage),
// small markup helpers and formatting shared by the modules of the screen. No bridge call here.
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
  contradictory: { label: 'Contradictoire', icon: 'alert', tone: 'alert', tip: 'Des sources différentes désignent des comptes différents pour ce poste. Aucune fusion automatique.' },
  toCheck: { label: 'À vérifier', icon: 'info', tone: 'warn', tip: 'Origine non reconnue : à vérifier avant de s’y fier.' },
};

export const BADGE_ORDER = ['declared', 'observed', 'history', 'imported', 'hint', 'contradictory', 'toCheck'];

/** Grid enum options of the qualification column (filter by list). */
export const BADGE_OPTIONS = BADGE_ORDER.map((id) => ({ value: id, label: BADGES[id].label, tone: BADGES[id].tone === 'off' ? 'off' : BADGES[id].tone }));

/** Badge pill (colour by data-badge, page stylesheet). */
export function badge(id, { label, size = '', tip } = {}) {
  const b = BADGES[id] ?? BADGES.toCheck;
  const text = label ?? b.label;
  return `<span class="rel-badge${size ? ` ${size}` : ''}" data-badge="${esc(id in BADGES ? id : 'toCheck')}" data-tip="${esc(tip ?? b.tip)}">${glyph(b.icon)}<span>${esc(text)}</span></span>`;
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

/** « il y a 3 h » with the full date in the tip; « — » without date (never a zero). */
export function when(iso, prefix = '') {
  const rel = relTime(iso);
  if (!rel) return '<span class="rel-none" aria-label="non renseigné">—</span>';
  return `<time datetime="${esc(iso)}" data-tip="${esc(formatDateTime(iso) ?? '')}">${esc(prefix + rel)}</time>`;
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
