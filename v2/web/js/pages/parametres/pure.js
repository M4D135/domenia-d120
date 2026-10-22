// Paramètres: pure helpers of the screen, without any import nor DOM, so that they can be tested alone (tests/web): names
// of the sections, interface preferences of the shell, reading of the journal (masking, stable mark), sizes in French and the
// plan of the two-column masonry of the card grids.

const NBSP = ' ';

/** Older or shorter names of the sections (links of the shell and of the guides: Ctrl I opens « stockage »). */
export const SECTION_ALIASES = Object.freeze({
  stockage: 'donnees', base: 'donnees', index: 'donnees', cache: 'donnees', sauvegardes: 'donnees', donnees: 'donnees',
  interface: 'apparence', theme: 'apparence', affichage: 'apparence', apparence: 'apparence',
  connexion: 'connexion', perimetre: 'connexion', ou: 'connexion', compte: 'connexion',
  collecte: 'collecte', budgets: 'collecte', reseau: 'collecte', fenetre: 'collecte',
  journaux: 'journaux', journal: 'journaux', logs: 'journaux',
  preferences: 'preferences', reglages: 'preferences',
  configuration: 'configuration', config: 'configuration',
  demonstration: 'demonstration', demo: 'demonstration', simulation: 'demonstration',
  apropos: 'apropos', 'a-propos': 'apropos', about: 'apropos', version: 'apropos',
});

/** The section of an address value (alias accepted, case ignored), or null. */
export function sectionOf(value) {
  const key = String(value ?? '').trim().toLowerCase();
  return Object.prototype.hasOwnProperty.call(SECTION_ALIASES, key) ? SECTION_ALIASES[key] : null;
}

const THEMES = ['light', 'dark', 'contrast', 'system'];
const MOTIONS = ['full', 'reduced', 'system'];
const PROFILES = ['essentiel', 'expert'];
const DENSITIES = ['compact', 'normal', 'confortable'];

/** The interface preferences as the shell normalizes them (same keys, same values, same defaults). */
export function normalizePrefs(raw) {
  const p = raw && typeof raw === 'object' ? raw : {};
  return {
    theme: THEMES.includes(p.theme) ? p.theme : 'system',
    motion: MOTIONS.includes(p.motion) ? p.motion : 'full',
    navCollapsed: p.navCollapsed === true,
    profile: PROFILES.includes(p.profile) ? p.profile : 'essentiel',
    density: DENSITIES.includes(p.density) ? p.density : 'normal',
    helpTips: p.helpTips !== false,
  };
}

/** Values accepted for each interface preference (setters ignore anything else). */
export const PREF_VALUES = Object.freeze({ theme: THEMES, motion: MOTIONS, profile: PROFILES, density: DENSITIES });

/** Density of the shell → density of a kit grid (createGrid: compact | normal | comfortable). */
export const gridDensity = (d) => (d === 'confortable' ? 'comfortable' : d === 'compact' ? 'compact' : 'normal');

/** Best-effort masking of names (DN, DOMAINE\compte, UPN, IPv4, FQDN of three labels or more); file names and versions stay. */
export function maskNames(text) {
  return String(text ?? '')
    .replace(/\b(?:CN|OU|DC)=[^,\s]+(?:,(?:CN|OU|DC)=[^,\s]+)*/gi, '«DN masqué»')
    .replace(/\b[A-Z0-9][A-Z0-9-]{0,14}\\[A-Za-z0-9._$-]+/g, '«compte masqué»')
    .replace(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, '«UPN masqué»')
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '«adresse masquée»')
    .replace(/\b(?:[A-Za-z0-9-]+\.){2,}[A-Za-z]{2,}\b/g, (m) => (/\.(?:dll|exe|json|log|db|png|ps1|js|css)$/i.test(m) || /^\d/.test(m) ? m : '«nom masqué»'));
}

/** Mark of the last line seen when the display is cleared: its time, level and text, and how many identical lines precede it. */
export function markOf(lines) {
  const last = lines.at(-1);
  if (!last) return null;
  const same = (l) => l.at === last.at && l.level === last.level && l.text === last.text;
  return { at: last.at ?? null, level: last.level, text: last.text, rank: lines.filter(same).length };
}

/**
 * Lines written after a mark, in a window that may have slid since: after the same line (same time, level, text and rank)
 * when it is still in the window; otherwise every line dated after it (a line without date is kept). A null mark keeps all.
 */
export function linesAfter(lines, mark) {
  if (!mark) return lines;
  let seen = 0;
  for (let n = 0; n < lines.length; n++) {
    const l = lines[n];
    if (l.at === mark.at && l.level === mark.level && l.text === mark.text) {
      seen++;
      if (seen === mark.rank) return lines.slice(n + 1);
    }
  }
  if (!mark.at) return lines;
  const limit = Date.parse(mark.at);
  return lines.filter((l) => !l.at || Date.parse(l.at) > limit);
}

const numberFormat = new Intl.NumberFormat('fr-FR', { maximumFractionDigits: 1 });

/** « 41,2 Mo » from bytes (unknown: « inconnu »), with a no-break space before the unit. */
export function size(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return 'inconnu';
  if (bytes < 1024) return `${numberFormat.format(bytes)}${NBSP}o`;
  const units = ['Ko', 'Mo', 'Go', 'To'];
  let value = bytes;
  let unit = 'o';
  for (const u of units) {
    value /= 1024;
    unit = u;
    if (value < 1024) break;
  }
  return `${numberFormat.format(Math.round(value * 10) / 10)}${NBSP}${unit}`;
}

/**
 * Plan of the two-column masonry of a card grid: wide cards stay alone on their row; each run of half-width cards between two
 * wide ones goes to two stacks, every card under the shorter stack (order kept inside each stack). Runs of one or two cards
 * stay as they are. Returns, for each item, null (left in place) or the stack 0 or 1 of its run, and the runs found.
 * @param {{ wide: boolean, height: number }[]} items
 * @param {number} gap
 */
export function masonryPlan(items, gap = 0) {
  const stacks = items.map(() => null);
  let run = [];
  const flush = () => {
    if (run.length > 2) {
      const heights = [0, 0];
      for (const n of run) {
        const k = heights[0] <= heights[1] ? 0 : 1;
        stacks[n] = k;
        heights[k] += items[n].height + gap;
      }
    }
    run = [];
  };
  items.forEach((item, n) => { if (item.wide) flush(); else run.push(n); });
  flush();
  return stacks;
}
