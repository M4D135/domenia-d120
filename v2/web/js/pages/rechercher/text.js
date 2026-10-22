// Rechercher · texts and pure rules of the page: French wording (FrenchText rules), distinguished names, the live
// analysis of the bar (mirror of SearchText in Domenia.Core: it explains, the engine decides), ticket lines, selection
// statements and empty states. Nothing here reads anything.
import { esc, fold } from '../../ui.js';

export const NBSP = ' ';
export const NNBSP = ' ';
export const COLON = `${NBSP}: `;
export const SEP = `${NBSP}› `;

export const quote = (text) => `«${NBSP}${text}${NBSP}»`;
export function int(n) {
  if (!Number.isFinite(n)) return '—';
  const digits = String(Math.abs(Math.trunc(n))).replace(/\B(?=(\d{3})+(?!\d))/g, NNBSP);
  return n < 0 ? `−${digits}` : digits;
}
/** Number and noun, singular for 0 and 1 (FrenchText.Count). */
export const count = (n, one, many) => `${int(n)} ${Math.abs(n) >= 2 ? many : one}`;
export { esc, fold };

export const MIN_CHARS = 2;
export const DEFAULT_LIMIT = 100;
export const MAX_LIMIT = 20000;

// ---------- Object kinds ----------

export const KINDS = {
  user: { label: 'Utilisateur', plural: 'Utilisateurs', icon: 'user', tone: 'info' },
  computer: { label: 'Poste', plural: 'Postes', icon: 'monitor', tone: 'accent' },
  group: { label: 'Groupe', plural: 'Groupes', icon: 'group', tone: 'ok' },
  ou: { label: 'OU', plural: 'OU', icon: 'ou', tone: 'off' },
};

export const TYPES = [
  { id: 'all', label: 'Tout', noun: 'personne, poste ou groupe', icon: 'layers' },
  { id: 'users', label: 'Personnes', noun: 'personne ou compte', icon: 'user' },
  { id: 'computers', label: 'Postes', noun: 'poste', icon: 'monitor' },
  { id: 'groups', label: 'Groupes', noun: 'groupe', icon: 'group' },
  { id: 'ous', label: 'OU', noun: 'unité d’organisation', icon: 'ou' },
];
export const typeLabel = (id) => (id === 'all' ? 'Tous les types' : TYPES.find((t) => t.id === id)?.label ?? 'Tous les types');

// ---------- Distinguished names (RFC 4514) ----------

/** Splits a DN on unescaped, unquoted commas; escaped commas stay inside their RDN. */
export function splitDn(dn) {
  const parts = [];
  let cur = '';
  let quoted = false;
  const s = String(dn ?? '');
  for (let n = 0; n < s.length; n++) {
    const c = s[n];
    if (c === '\\' && n + 1 < s.length) { cur += c + s[n + 1]; n += 1; continue; }
    if (c === '"') { quoted = !quoted; cur += c; continue; }
    if (c === ',' && !quoted) { if (cur.trim()) parts.push(cur.trim()); cur = ''; continue; }
    cur += c;
  }
  if (cur.trim()) parts.push(cur.trim());
  return parts;
}

/** Value of an RDN, escapes decoded (\, and UTF-8 hex pairs such as \C3\A9). */
export function rdnValue(rdn) {
  let raw = rdn.slice(rdn.indexOf('=') + 1);
  if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) raw = raw.slice(1, -1);
  const bytes = [];
  let out = '';
  const flush = () => { if (bytes.length) { out += new TextDecoder().decode(new Uint8Array(bytes)); bytes.length = 0; } };
  for (let n = 0; n < raw.length; n++) {
    if (raw[n] === '\\' && /^[0-9a-f]{2}$/i.test(raw.slice(n + 1, n + 3))) { bytes.push(parseInt(raw.slice(n + 1, n + 3), 16)); n += 2; continue; }
    flush();
    if (raw[n] === '\\' && n + 1 < raw.length) { out += raw[n + 1]; n += 1; continue; }
    out += raw[n];
  }
  flush();
  return out;
}

const rdnType = (rdn) => rdn.slice(0, Math.max(0, rdn.indexOf('='))).trim().toUpperCase();
export const sameDn = (a, b) => typeof a === 'string' && typeof b === 'string' && a.trim().toLowerCase() === b.trim().toLowerCase();

/** Name of the object a DN designates (its first RDN, decoded). */
export const leafOf = (dn) => { const p = splitDn(dn); return p.length ? rdnValue(p[0]) : String(dn ?? ''); };

/** Parent DN, or '' for a single RDN. */
export function parentDn(dn) {
  const p = splitDn(dn);
  return p.length > 1 ? p.slice(1).join(',') : '';
}

/** OU and container names from the leaf upward, DC components left out. */
export const ouNamesOf = (dn) => splitDn(dn).filter((r) => rdnType(r) !== 'DC').map(rdnValue);

/** Root DN (DC components) of a DN. */
export const rootOf = (dn) => splitDn(dn).filter((r) => rdnType(r) === 'DC').join(',');

/** Readable path « example.local › Postes › Paris ». */
export function pathOf(dn, dnsName) {
  const parts = splitDn(dn);
  const dcs = parts.filter((r) => rdnType(r) === 'DC').map(rdnValue);
  const names = parts.filter((r) => rdnType(r) !== 'DC').map(rdnValue).reverse();
  return [dnsName || dcs.join('.'), ...names].join(SEP);
}

/** True when dn lies under base (sub-OUs included unless direct). */
export function isUnder(dn, base, direct = false) {
  const a = splitDn(dn).map((x) => x.toLowerCase());
  const b = splitDn(base).map((x) => x.toLowerCase());
  if (a.length <= b.length) return false;
  if (direct && a.length !== b.length + 1) return false;
  const off = a.length - b.length;
  return b.every((x, n) => a[off + n] === x);
}

/** Path of the container of an object for a ticket, from the domain down (« Lyon / Postes »), DC left out. */
export const ticketOuPath = (dn) => ouNamesOf(parentDn(dn)).reverse().join(' / ');

// ---------- Live analysis of the bar (mirror of SearchText; the engine decides) ----------

const PREFIXES = {
  utilisateur: 'Utilisateur', user: 'Utilisateur', u: 'Utilisateur',
  poste: 'Poste', pc: 'Poste', machine: 'Poste', ordinateur: 'Poste',
  groupe: 'Groupe', group: 'Groupe', g: 'Groupe',
  mail: 'Mail', email: 'Mail', courriel: 'Mail',
};
const IPV4 = /^(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]\d|\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]\d|\d)){3}$/;
const MAC_SEP = /^[0-9A-Fa-f]{2}([:-])([0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}$/;
const MAC_BARE = /^[0-9A-Fa-f]{12}$/;
const GUID = /^\{?[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}?$/;
const SID = /^S-1-\d+(-\d+){1,14}$/i;
const DN_START = /^(CN|OU|DC)=/i;
const DOWNLEVEL = /^[^\\/\s@]+\\[^\\/\s@]+$/;
const UPN = /^[^@\s]+@[^@\s]+\.[^@\s.]+$/;
const FQDN = /^[a-z0-9]([a-z0-9-]{0,62})(\.[a-z0-9]([a-z0-9-]{0,62})){2,}$/i;

export const words = (text) => String(text ?? '').trim().split(/\s+/).filter(Boolean);
export const isWildcardOnly = (text) => { const v = String(text ?? '').trim(); return v.length > 0 && /^[\s*]+$/.test(v); };

/** IPv4 or MAC address typed alone, normalized (« 00-1A-2B-3C-4D-5E »), or null. */
export function parseAddress(text) {
  const v = String(text ?? '').trim();
  if (!v || /\s/.test(v)) return null;
  if (IPV4.test(v)) return { kind: 'ipv4', value: v, label: 'adresse IP' };
  let hex = '';
  if (MAC_SEP.test(v)) hex = v.replace(/[:-]/g, '');
  else if (MAC_BARE.test(v)) hex = v;
  if (!hex) return null;
  return { kind: 'mac', value: hex.toUpperCase().match(/../g).join('-'), label: 'adresse MAC' };
}

function identifierOf(v) {
  if (!v || (/\s/.test(v) && !DN_START.test(v))) return null;
  if (GUID.test(v)) return { kind: 'guid', exact: true, text: 'GUID reconnu : recherche exacte de cet objet.' };
  if (SID.test(v)) return { kind: 'sid', exact: true, text: 'SID reconnu : recherche exacte de ce compte.' };
  if (DN_START.test(v)) {
    const rdns = splitDn(v);
    if (rdns.length >= 2 && rdns.every((r) => /^(CN|OU|DC)=\S/i.test(r))) return { kind: 'dn', exact: true, text: 'Nom distinctif reconnu : recherche exacte de cet objet.' };
  }
  if (DOWNLEVEL.test(v)) return { kind: 'downlevel', exact: false, text: 'Nom DOMAINE\\compte reconnu : l’identifiant est cherché avec les autres correspondances.' };
  if (UPN.test(v)) return { kind: 'upn', exact: false, text: 'Adresse reconnue : nom de connexion et messagerie cherchés, avec les autres correspondances.' };
  if (FQDN.test(v)) return { kind: 'fqdn', exact: false, text: 'Nom DNS complet reconnu : le poste est cherché avec les autres correspondances.' };
  return null;
}

/** Tokens of the optional syntax: { tokens: [{prefix, kind, value}], free, unknown: [prefix], empty: [prefix] }. */
export function parseSyntax(text) {
  const out = { tokens: [], free: [], unknown: [], empty: [] };
  const re = /(\p{L}+):(?:"([^"]*)"|(\S*))|"([^"]*)"|(\S+)/gu;
  let m;
  while ((m = re.exec(String(text ?? '').trim())) !== null) {
    if (m[1]) {
      const prefix = m[1].toLowerCase();
      const value = (m[2] ?? m[3] ?? '').trim();
      if (PREFIXES[prefix]) {
        if (!value) out.empty.push(prefix); else out.tokens.push({ prefix, kind: PREFIXES[prefix], value });
      } else { out.unknown.push(prefix); out.free.push(m[0]); }
    } else if (m[4] !== undefined) { if (m[4].trim()) out.free.push(m[4].trim()); } else out.free.push(m[5]);
  }
  return out;
}

/**
 * What the bar will do with a text, explained at each key press (Domenia 1 Update-DomeniaSearchHint, RCH-026): recognized
 * tokens, pasted identifier, address, leading wildcard, star alone, too short. Text analysis only: no request.
 * @returns {{ valid: boolean, empty: boolean, kind: string, reason: string, chips: Array<{label: string, tone: string, icon?: string}>, notes: string[] }}
 */
export function analyse(text, { match = 'prefix', minimum = MIN_CHARS } = {}) {
  const v = String(text ?? '').trim();
  const res = { valid: false, empty: !v, kind: 'empty', reason: '', chips: [], notes: [] };
  if (!v) { res.reason = `Saisissez au moins ${int(minimum)} caractères${COLON}un nom, un identifiant, une adresse ou un poste.`; return res; }
  if (isWildcardOnly(v)) { res.reason = `Saisissez au moins un caractère en plus de *${COLON}une étoile seule listerait tout le domaine.`; res.kind = 'refused'; return res; }
  if (v.replace(/\*/g, '').trim().length < minimum) { res.reason = `Saisissez au moins ${int(minimum)} caractères${COLON}un nom, un identifiant, une adresse ou un poste.`; res.kind = 'short'; return res; }
  if (match === 'contains') {
    const list = [...new Set(words(v))];
    if (list.length > 4) { res.reason = 'Saisissez de un à quatre mots pour chercher les noms qui les contiennent.'; res.kind = 'refused'; return res; }
    if (list.some((w) => w.replace(/\*/g, '').length < 2)) { res.reason = 'Chaque mot doit compter au moins 2 caractères pour chercher les noms qui le contiennent.'; res.kind = 'refused'; return res; }
    res.valid = true; res.kind = 'contains';
    res.chips.push({ label: 'Contient', tone: 'accent', icon: 'search' }, ...list.map((w) => ({ label: w, tone: 'off' })));
    res.notes.push('Noms, noms affichés, comptes et noms DNS qui contiennent ces mots : plus lent, l’annuaire parcourt tous les noms du périmètre.');
    return res;
  }
  const address = parseAddress(v);
  if (address) {
    res.valid = true; res.kind = 'address';
    res.chips.push({ label: `${address.label[0].toUpperCase()}${address.label.slice(1)} ${address.value}`, tone: 'info', icon: 'wifi' });
    res.notes.push('Recherche dans les relevés locaux, sans scan réseau. Une adresse peut avoir changé depuis le relevé.');
    return res;
  }
  const id = identifierOf(v);
  if (id?.exact) {
    res.valid = true; res.kind = 'identifier';
    res.chips.push({ label: id.kind.toUpperCase() === 'DN' ? 'Nom distinctif' : id.kind.toUpperCase(), tone: 'accent', icon: 'hash' });
    res.notes.push(`${id.text} Aucun résultat n’est ouvert automatiquement.`);
    return res;
  }
  if (id) { res.chips.push({ label: id.kind === 'upn' ? 'Adresse' : id.kind === 'fqdn' ? 'Nom DNS' : 'DOMAINE\\compte', tone: 'info', icon: 'hash' }); res.notes.push(id.text); }
  const syntax = parseSyntax(v);
  for (const t of syntax.tokens) res.chips.push({ label: `${t.kind}${COLON}${t.value}`, tone: 'accent', icon: t.kind === 'Poste' ? 'monitor' : t.kind === 'Groupe' ? 'group' : t.kind === 'Mail' ? 'file' : 'user' });
  for (const p of syntax.empty) res.notes.push(`Jeton ${quote(`${p}:`)} sans valeur${COLON}ignoré.`);
  for (const p of syntax.unknown) res.notes.push(`${quote(`${p}:`)} n’est pas un jeton reconnu${COLON}cherché comme texte.`);
  const kinds = new Set(syntax.tokens.filter((t) => t.kind !== 'Mail').map((t) => t.kind));
  if (kinds.size > 1) res.notes.push('Plusieurs types demandés : chaque jeton est cherché dans son type.');
  const free = syntax.tokens.length ? syntax.free : words(v);
  if (syntax.tokens.length && free.length) res.chips.push({ label: `texte${COLON}${free.join(' ')}`, tone: 'off' });
  if (!syntax.tokens.length) {
    const ws = words(v);
    if (!ws.some((w) => w.replace(/\*/g, '').length >= minimum)) { res.reason = `Saisissez au moins ${int(minimum)} caractères${COLON}une recherche plus courte parcourrait tout le domaine.`; res.kind = 'short'; return res; }
    res.chips.push(...ws.slice(0, 6).map((w) => ({ label: w.includes('*') ? `${w} (joker)` : `${w}…`, tone: w.startsWith('*') ? 'warn' : 'off' })));
    if (ws.length > 1) res.notes.push('Chaque mot doit figurer au début d’un nom, d’un compte, d’un nom affiché, d’un courriel ou d’un nom DNS.');
  }
  if (words(v).some((w) => w.startsWith('*'))) res.notes.push('Joker en tête : recherche par sous-chaîne, sans index. Elle peut être longue sur un grand domaine ; préférez le début du nom.');
  res.valid = true;
  res.kind = syntax.tokens.length ? 'syntax' : 'default';
  return res;
}

/** Waiting text of the empty field, summary and chip (Domenia 1 Get-DomeniaSearchBarText). */
export function barText(choice, ouName, type) {
  const entry = TYPES.find((t) => t.id === type) ?? TYPES[0];
  const name = String(ouName ?? '').trim() || 'OU choisie';
  const where = choice === 'ou' ? `dans ${quote(name)} et ses sous-OU` : 'dans tout le domaine';
  const chip = choice === 'ou' ? `Dans ${quote(name)}` : 'Partout';
  const noun = entry.noun;
  return {
    placeholder: `${noun[0].toUpperCase()}${noun.slice(1)}, ${where}…`,
    summary: `Recherche · ${chip} · ${typeLabel(entry.id)} · Aucun filtre de liste`,
    chip,
  };
}

// ---------- Tickets, selections, scopes ----------

// Secrets pasted in a description or an account name never leave Domenia (Domenia 1 Protect-DomeniaSecretText).
const SECRET = /\b(mot\s+de\s+passe|mdp|password|passwd|pwd|secret|jeton|token)\b(\s*[:=]\s*|\s+)(\S+)/gi;
export const maskSecrets = (text) => String(text ?? '').replace(SECRET, (all, key, sep) => `${key}${sep}••••••`);

/** One readable line per object for a ticket (Domenia 1 ConvertTo-DomeniaTicketLine): no GUID, no DN, one line. */
export function ticketLine(row) {
  if (!row) return '';
  const flat = (v, max = 120) => String(v ?? '').replace(/[\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max);
  const parts = [{ user: 'Utilisateur', computer: 'Poste', group: 'Groupe', ou: 'OU' }[row.kind] ?? 'Objet'];
  if (row.name) parts.push(flat(row.name));
  const account = row.kind === 'computer' ? row.association?.label : (row.kind === 'user' || row.kind === 'group') ? row.login : '';
  if (account) parts.push(`Compte${COLON}${flat(account)}`);
  if (row.kind === 'computer' && row.presence) {
    const age = row.presence.checkedAt ? ageText(row.presence.checkedAt) : '';
    parts.push(`Présence${COLON}${row.presence.label}${age ? ` (${age})` : ''}`);
    if (row.console?.state === 'seen' && row.console.user) parts.push(`Utilisateur console${COLON}${flat(row.console.user)}`);
  }
  const ou = ticketOuPath(row.dn);
  if (ou) parts.push(`OU${COLON}${flat(ou, 240)}`);
  return parts.join(' · ');
}

export const ticketText = (rows) => maskSecrets(rows.map(ticketLine).filter(Boolean).join('\r\n'));

/** « il y a 2 h », as the age of a measure (Domenia 1 Get-DomeniaLiveAgeText). */
export function ageText(iso, now = Date.now()) {
  const t = Date.parse(iso ?? '');
  if (Number.isNaN(t)) return '';
  const s = (now - t) / 1000;
  if (s < 60) return 'à l’instant';
  if (s < 3600) return `il y a ${Math.floor(s / 60)}${NBSP}min`;
  if (s < 86400) return `il y a ${Math.floor(s / 3600)}${NBSP}h`;
  return `il y a ${Math.floor(s / 86400)}${NBSP}j`;
}

/** « 3 postes sélectionnés », « 3 lignes sélectionnées dont 1 poste » (Domenia 1 Get-DomeniaSearchSelectionText). */
export function selectionText(selected, machines = -1) {
  if (selected <= 0) return 'Aucune ligne sélectionnée';
  if (machines === selected) return `${int(selected)} ${selected > 1 ? 'postes sélectionnés' : 'poste sélectionné'}`;
  let t = `${int(selected)} ${selected > 1 ? 'lignes sélectionnées' : 'ligne sélectionnée'}`;
  if (machines > 0) t += ` dont ${count(machines, 'poste', 'postes')}`;
  return t;
}

/** Sentence of what an export or a survey processes (Domenia 1 Get-DomeniaSearchScopeSummary). */
export function scopeSummary({ mode, visible, loaded, selected, selectedHidden = 0, complete, limit }) {
  const note = complete ? 'liste complète' : `liste limitée à ${int(limit)} lignes${COLON}les objets au-delà ne sont pas inclus`;
  if (mode === 'selected') {
    let t = selected > 0 ? `Lignes sélectionnées${COLON}${selectionText(selected)} sur ${count(visible, 'affichée', 'affichées')}`
      : 'Aucune ligne sélectionnée parmi les lignes affichées : sélectionnez des lignes (Ctrl ou Maj et clic) ou choisissez la liste affichée.';
    if (selectedHidden > 0) t += ` · ${count(selectedHidden, 'ligne sélectionnée masquée', 'lignes sélectionnées masquées')} par un filtre, exclue${selectedHidden > 1 ? 's' : ''}`;
    return t;
  }
  let t = `Liste affichée${COLON}${count(visible, 'ligne', 'lignes')}`;
  const hidden = Math.max(0, loaded - visible);
  if (hidden > 0) t += ` · ${count(hidden, 'ligne chargée masquée', 'lignes chargées masquées')} par les filtres, exclue${hidden > 1 ? 's' : ''}`;
  if (selected > 0) t += ` · sélection de ${count(selected, 'ligne', 'lignes')} non utilisée (la barre de sélection agit sur elle)`;
  return `${t} · ${note}`;
}

/** Empty state of the list (Domenia 1 Get-DomeniaEmptyState): what was (not) read, one next step, never a claim of absence. */
export function emptyState(kind, { query = '', scope = '' } = {}) {
  const scopePart = scope ? ` (${scope})` : '';
  switch (kind) {
    case 'refused': return { icon: 'lock', title: 'Lecture refusée', text: `La lecture a été refusée pour ce compte${scopePart}${COLON}le contenu réel est inconnu.` };
    case 'nosource': return { icon: 'wifiOff', title: 'Aucune source disponible', text: `Aucune source n’a répondu pour cette vue${scopePart}${COLON}rien n’a pu être lu, l’état réel est inconnu.` };
    case 'noresult': return {
      icon: 'search', title: 'Aucun résultat',
      text: `${query ? `Aucun résultat pour ${quote(query)}` : 'Aucun résultat'} dans le périmètre interrogé${scopePart}. Un objet hors de ce périmètre, ou masqué pour ce compte, ne peut pas apparaître ici.`,
    };
    default: return { icon: 'search', title: 'Rien n’a encore été interrogé', text: 'L’affichage vide ne renseigne pas sur l’état réel : saisissez un nom, choisissez une OU ou une requête prête.' };
  }
}

/** Tone of a presence key. */
export const presenceTone = (state) => ({ online: 'ok', noReply: 'warn', error: 'alert' }[state] ?? 'off');

/** Plain text of an ISO date in local time « 21/10/2026 18:14 », or '—'. */
export function dateText(iso, withTime = true) {
  const t = Date.parse(iso ?? '');
  if (Number.isNaN(t)) return '—';
  const d = new Date(t);
  const p = (n) => String(n).padStart(2, '0');
  const day = `${p(d.getDate())}/${p(d.getMonth() + 1)}/${d.getFullYear()}`;
  return withTime ? `${day} ${p(d.getHours())}:${p(d.getMinutes())}` : day;
}
