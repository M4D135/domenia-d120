// Contextual help of the shell (TRV-004 to TRV-007): the 820 topics of the Domenia 1 catalogue (help-catalog.js, generated
// by tools/gen_help.py), topics registered by the screens of Domenia 2, the presentation of a tooltip by role, the closed
// catalogue of the reasons of a greyed control and the closed catalogue of safe routes. API documented in docs/SHELL.md.
// A help text is always a static label: never the value of a control.
import { fold } from '../ui.js';
import { emit, state } from './store.js';

const NBSP = ' ';

let catalogue = null;     // Map name → topic, once loaded
let loading = null;
const registered = new Map(); // topics of Domenia 2 screens (same shape)

/** Neutral topic of a control unknown to the catalogue (Domenia 1 Get-DomeniaUxHelpEntry). */
export const NEUTRAL = Object.freeze({
  name: '', title: 'Aide', kind: 'zone', area: 'interface',
  text: `Consultez le libellé et les actions de cette zone. Aucun contenu saisi n’est recopié dans cette aide.`,
});

/** Loads the generated catalogue once (dynamic import: nothing is fetched before the first need). */
export function loadHelp() {
  if (catalogue) return Promise.resolve(catalogue);
  if (!loading) {
    loading = import('./help-catalog.js').then((m) => {
      const map = new Map();
      for (const [name, title, text, kind, area] of m.HELP_TOPICS) {
        map.set(name, Object.freeze({ name, title, text, kind, area, folded: fold(`${title} ${text} ${name}`) }));
      }
      catalogue = map;
      areas = m.HELP_AREAS;
      source = m.HELP_SOURCE;
      emit('help-loaded', map.size);
      return map;
    }).catch((err) => {
      loading = null;
      console.error(err);
      throw err;
    });
  }
  return loading;
}

let areas = [];
let source = null;

export function helpAreas() { return areas; }
export function helpSource() { return source; }
export function helpLoaded() { return !!catalogue; }

/**
 * Adds or replaces the help of a control of Domenia 2 (not in the Domenia 1 catalogue). Static texts only.
 * @param {string} key @param {{ title: string, text: string, kind?: string, area?: string }} topic
 */
export function registerHelp(key, topic) {
  if (!/^[A-Za-z][A-Za-z0-9_.:-]{0,79}$/.test(String(key ?? '')) || !topic?.title || !topic?.text) {
    console.warn('Aide non enregistrée : clé ou texte manquant', key);
    return;
  }
  registered.set(key, Object.freeze({
    name: key, title: String(topic.title), text: String(topic.text), kind: topic.kind ?? 'zone',
    area: topic.area ?? state.page?.id ?? 'interface', folded: fold(`${topic.title} ${topic.text} ${key}`),
  }));
}

/** Topic of a key once the catalogue is loaded (synchronous; null when not loaded yet or unknown). */
export function topicNow(key) {
  if (!key) return null;
  return registered.get(key) ?? catalogue?.get(key) ?? null;
}

/** Topic of a key (loads the catalogue when needed); the neutral topic for an unknown key. */
export async function topic(key) {
  if (registered.has(key)) return registered.get(key);
  try { await loadHelp(); } catch { return NEUTRAL; }
  return catalogue.get(key) ?? NEUTRAL;
}

/**
 * Searches the topics: every word must appear (accents, case and apostrophes ignored), titles first.
 * @param {string} query @param {{ area?: string, limit?: number }} [o]
 */
export function searchTopics(query, { area = '', limit = 30 } = {}) {
  const all = [...registered.values(), ...(catalogue?.values() ?? [])];
  const words = fold(String(query ?? '')).replace(/[’'ʼ]/g, ' ').split(/\s+/).filter(Boolean);
  const scored = [];
  for (const t of all) {
    if (area && t.area !== area) continue;
    if (!words.every((w) => t.folded.includes(w))) continue;
    const title = fold(t.title);
    const rank = !words.length ? 2 : title.startsWith(words[0]) ? 0 : words.every((w) => title.includes(w)) ? 1 : 2;
    scored.push({ t, rank });
  }
  // Titles that start with a figure (« 0 classe », a counter of Domenia 1) come after the words.
  const figure = (t) => (/^\d/.test(t.title) ? 1 : 0);
  scored.sort((a, b) => a.rank - b.rank || figure(a.t) - figure(b.t) || a.t.title.localeCompare(b.t.title, 'fr'));
  return { total: scored.length, items: scored.slice(0, limit).map((s) => s.t) };
}

/** Topics of a screen, in the order of the catalogue. */
export function topicsOfArea(area, limit = 12) {
  const out = [];
  for (const t of [...registered.values(), ...(catalogue?.values() ?? [])]) {
    if (t.area === area) out.push(t);
    if (out.length >= limit) break;
  }
  return out;
}

// ---------- Presentation by role (Domenia 1 Get-DomeniaHelpPresentation, UI-10) ----------

const CONTAINER_TAGS = new Set(['SECTION', 'ARTICLE', 'MAIN', 'NAV', 'ASIDE', 'FORM', 'FIELDSET', 'TABLE', 'UL', 'OL']);
const CONTAINER_ROLES = new Set(['grid', 'tree', 'treegrid', 'list', 'listbox', 'tabpanel', 'region', 'group', 'table', 'log', 'tablist']);

/** Role of an element for its help: container (no tooltip), iconButton (first sentence) or control (whole text). */
export function helpRole(el, kind) {
  const explicit = el?.dataset?.helpRole;
  if (explicit === 'container' || explicit === 'iconButton' || explicit === 'control') return explicit;
  if (el instanceof Element) {
    const role = el.getAttribute('role') ?? '';
    if (CONTAINER_TAGS.has(el.tagName) || CONTAINER_ROLES.has(role) || el.classList.contains('card')) return 'container';
    if ((el.tagName === 'BUTTON' || role === 'button' || el.tagName === 'A') && !el.textContent.trim()) return 'iconButton';
    if (el.tagName === 'TEXTAREA' && el.readOnly) return 'container';
    return 'control';
  }
  return kind === 'list' || kind === 'zone' ? 'container' : 'control';
}

/** Tooltip of a topic for a role: none for a container, first sentence for an icon button, the whole text otherwise. */
export function presentation(text, role) {
  const full = String(text ?? '').trim();
  if (role === 'container') return { tip: '', help: full };
  if (role === 'iconButton') {
    let cut = -1;
    for (const mark of ['. ', `${NBSP}; `, ' ; ', `${NBSP}? `, '? ', `${NBSP}! `, '! ']) {
      const at = full.indexOf(mark);
      if (at > 0 && (cut < 0 || at < cut)) cut = at;
    }
    if (cut > 0) {
      let tip = full.slice(0, cut).trimEnd();
      if (!/[.?!]$/.test(tip)) tip += '.';
      return { tip, help: full };
    }
  }
  return { tip: full, help: full };
}

// ---------- Reasons of a greyed control (Domenia 1 Get-DomeniaDisabledHelp, D088, TRV-006) ----------

/** Closed catalogue of the reasons: text after « Action : », and the route that unblocks (when one exists). */
export const DISABLED_REASONS = Object.freeze({
  readOnly: { text: 'Lecture seule active : les modifications sont désactivées.', route: 'lecture-seule' },
  noSelection: { text: 'Sélectionnez d’abord un objet.', route: 'rechercher' },
  wrongType: { text: 'Action réservée à un autre type d’objet.', route: 'rechercher' },
  busy: { text: 'Une écriture est en cours ou à vérifier.', route: 'operations-verifier' },
  refused: { text: 'Refusé par la ressource pour ce compte.', route: 'comptes' },
  stale: { text: 'Données en cache : une relecture est nécessaire avant de modifier.', route: 'fiche-relire' },
  offline: { text: 'Hors ligne : seules les données déjà lues sont consultables.', route: 'operations-verifier' },
  prerequisite: { text: 'Prérequis non rempli sur ce poste ou sur la cible.', route: 'apropos' },
  pending: { text: 'Une opération précédente reste à vérifier sur cette cible.', route: 'operations-verifier' },
  running: { text: 'Opération en cours, action de nouveau disponible à sa fin.', route: 'operations' },
});

/** Closed catalogue of the optional details (no free text: a field value can never reach a tooltip). */
export const DISABLED_DETAILS = Object.freeze({
  needsUser: 'Sélectionnez un utilisateur.',
  needsWorkstation: 'Sélectionnez un poste.',
  needsGroup: 'Sélectionnez un groupe.',
  readInProgress: 'Lecture en cours sur cette cible.',
  writeInProgress: 'Écriture en cours sur cette cible.',
  receiptToReview: 'Un reçu attend sa vérification.',
  cacheOnly: 'Valeurs issues du cache local.',
  otherAccountNeeded: 'Un autre compte est nécessaire pour cette ressource.',
  remoteAccessUnavailable: 'Accès distant non disponible pour ce poste.',
  toolMissing: 'Outil d’administration non installé sur ce poste.',
  featureDisabled: 'Fonction désactivée dans la configuration.',
  requiredFieldEmpty: 'Un champ obligatoire est vide.',
  simulation: 'Non disponible en simulation : aucune connexion au poste ni à l’annuaire.',
  memoryOnly: 'Cette session ne garde rien sur le disque (capture ou essai) : aucun dossier à ouvrir.',
  policyHidden: 'Masqué par l’administrateur dans Domenia.config.json.',
});

/**
 * Explanation of a greyed control: « Action : motif. Détail. » and its route. An unknown reason or detail is refused (thrown):
 * only codes of the catalogues are accepted, so no value can leak into a tooltip.
 */
export function disabledHelp(action, reason, detail = '') {
  const r = DISABLED_REASONS[reason];
  if (!r) throw new Error(`Motif hors catalogue : ${reason}`);
  if (detail && !DISABLED_DETAILS[detail]) throw new Error('Motif détaillé hors catalogue : seul un code du catalogue est accepté.');
  const label = String(action ?? '').replace(/\s+/g, ' ').trim().slice(0, 60) || 'Action';
  const text = `${label}${NBSP}: ${r.text}${detail ? ` ${DISABLED_DETAILS[detail]}` : ''}`;
  return { action: label, reason, detail, short: text.slice(0, 160), help: `${text.slice(0, 160)} F1${NBSP}: aide détaillée.`, route: r.route };
}

// ---------- Safe routes (Domenia 1 Resolve-DomeniaCapabilityRoute, TRV-007) ----------

/**
 * Closed catalogue of the places an explanation or a message may send the operator to. Navigation only: nothing is read,
 * authorized or started by a route.
 */
export const ROUTES = Object.freeze({
  rechercher: { label: 'Rechercher', page: 'rechercher', params: {}, focus: 'search' },
  comptes: { label: 'Comptes', page: 'comptes', params: {} },
  'fiche-droits': { label: 'Fiche › Permissions', page: 'fiche', params: { tab: 'droits' } },
  'operations-verifier': { label: 'Opérations à vérifier', page: 'operations', params: { filtre: 'verifier' } },
  stockage: { label: 'Base autonome › Stockage', page: 'parametres', params: { section: 'stockage' } },
  'comparer-saisies': { label: 'Comparer les saisies', page: 'fiche', params: { panneau: 'comparer' } },
  'assistance-intervenir': { label: 'Assistance poste › Intervenir', page: 'poste', params: { onglet: 'intervenir' } },
  'lecture-seule': { label: 'Protection lecture seule', panel: 'session' },
  'fiche-relire': { label: 'Fiche › Relire', page: 'fiche', params: { relire: '1' } },
  operations: { label: 'Opérations', panel: 'activity' },
  journal: { label: 'Journal de la session', panel: 'journal' },
  apropos: { label: 'À propos et compatibilité', panel: 'about' },
  parametres: { label: 'Paramètres', page: 'parametres', params: {} },
  aide: { label: 'Centre d’aide', page: 'shell', params: { onglet: 'aide' } },
});

/** Route named by a message (Domenia 1 Get-DomeniaMessageRoute, generalized: TRV-166 improvement). */
export function routeOfText(text) {
  const t = String(text ?? '');
  if (/Assistance poste\s*[›>]\s*Intervenir/.test(t)) return 'assistance-intervenir';
  if (/Fiche\s*[›>]\s*(Permissions|Droits)/.test(t)) return 'fiche-droits';
  if (/Base autonome\s*[›>]\s*Stockage/.test(t)) return 'stockage';
  if (/(reçus?|opérations?) à vérifier|relisez son reçu dans Opérations/i.test(t)) return 'operations-verifier';
  if (/Comparer les saisies/.test(t)) return 'comparer-saisies';
  if (/\bdans (l’écran )?«?\s?Comptes\s?»?/.test(t)) return 'comptes';
  if (/\bdans (l’écran )?«?\s?Paramètres\s?»?/.test(t)) return 'parametres';
  return '';
}

let routeRunner = null;

/** app.js hands the function that follows a route (navigation or a shell panel). */
export function setRouteRunner(fn) { routeRunner = fn; }

/** Follows a route of the catalogue; false when the code is unknown. */
export function followRoute(code) {
  const r = ROUTES[code];
  if (!r || !routeRunner) return false;
  routeRunner(code, r);
  return true;
}
