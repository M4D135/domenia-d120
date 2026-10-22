// Assistance · pure text helpers of the screen (no DOM, no bridge): French counts, initials, readable DN paths and names,
// readable attribute values (FILETIME and generalized times become a local date, the raw value stays available). Same
// rules as Domenia.Core AssistanceText and AttributeValues; tests in tests/web/assistance-format.test.mjs.

export const NBSP = ' ';
export const COLON = `${NBSP}: `;

const FILETIME_EPOCH_MS = 11_644_473_600_000n;
const NEVER = 9_223_372_036_854_775_807n;
const FILE_TIMES = new Set(['lockouttime', 'pwdlastset', 'accountexpires', 'lastlogontimestamp', 'lastlogon', 'badpasswordtime', 'msds-userpasswordexpirytimecomputed']);
const GENERALIZED = new Set(['whencreated', 'whenchanged']);
const DN_NAMES = new Set(['manager', 'managedby', 'memberof', 'directreports', 'primarygroup']);
const pad = (n) => String(n).padStart(2, '0');

/** Integer with U+202F between thousands and the minus sign U+2212 (FrenchText.Integer). */
export function int(n) {
  const digits = String(Math.abs(Math.trunc(Number(n) || 0))).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  return n < 0 ? `−${digits}` : digits;
}

/** Number and noun joined by a no-break space; 0 and 1 take the singular (FrenchText). */
export function plural(n, one, many) {
  return `${int(n)}${NBSP}${Math.abs(n) >= 2 ? many : one}`;
}

/** Initials of a person, or the number of a workstation (« PC-LYO-0042 » → « 42 »). */
export function initials(name, kind) {
  const text = String(name ?? '').trim();
  if (kind === 'computer') {
    const m = /(\d{1,4})$/.exec(text);
    return m ? String(Number(m[1])) : text.slice(0, 2).toUpperCase();
  }
  const parts = text.split(/[\s'’-]+/).filter(Boolean);
  return ((parts[0]?.[0] ?? '') + (parts.length > 1 ? parts[parts.length - 1][0] : '')).toUpperCase() || '?';
}

/** RDN of a distinguished name, unescaped (RFC 4514 backslash escapes), in order: [« CN=Cédric Carré », « OU=Lyon », …]. */
export function dnParts(dn) {
  const parts = [];
  let cur = '';
  const text = String(dn ?? '');
  for (let n = 0; n < text.length; n++) {
    const c = text[n];
    if (c === '\\' && n + 1 < text.length) { cur += text[n + 1]; n += 1; continue; }
    if (c === ',') { parts.push(cur.trim()); cur = ''; continue; }
    cur += c;
  }
  if (cur.trim()) parts.push(cur.trim());
  return parts.filter(Boolean);
}

/** Readable path of a DN, without the domain nor the object itself: « Utilisateurs › Lyon › Commercial ». */
export function dnPath(dn) {
  return dnParts(dn).slice(1).filter((p) => !/^DC=/i.test(p)).map((p) => p.slice(p.indexOf('=') + 1)).reverse().join(`${NBSP}› `);
}

/** Value of the first RDN (« CN=Cédric Carré,OU=… » → « Cédric Carré »), or the text itself when it is not a DN. */
export function dnName(dn) {
  const first = dnParts(dn)[0] ?? '';
  const at = first.indexOf('=');
  return at > 0 ? first.slice(at + 1) : String(dn ?? '');
}

/** True when the text looks like a distinguished name (« CN=…,DC=… »). */
export function isDn(text) {
  return /^(CN|OU|DC|O|L)=[^,]+,/i.test(String(text ?? ''));
}

/** FILETIME (100 ns since 1601) as an ISO date; null for 0, « never » or an unreadable value. */
export function fileTimeToIso(raw) {
  if (!/^\d{1,19}$/.test(String(raw ?? '').trim())) return null;
  const value = BigInt(String(raw).trim());
  if (value === 0n || value >= NEVER) return null;
  const ms = value / 10000n - FILETIME_EPOCH_MS;
  const date = new Date(Number(ms));
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

/** Local date and time of an ISO date: « 22/10/2026 03:19 ». */
export function localStamp(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/**
 * Readable form of one captured value. kind: 'date' (FILETIME or generalized time, with its ISO date), 'special' (0 or
 * « never » of a FILETIME), 'dn' (a distinguished name: its first RDN as name), or 'text'. raw is always the value as captured.
 * @returns {{ kind: 'date'|'special'|'dn'|'text', text: string, raw: string, iso?: string }}
 */
export function readableValue(attribute, value) {
  const raw = String(value ?? '');
  const name = String(attribute ?? '').toLowerCase();
  if (FILE_TIMES.has(name) && /^\d{1,19}$/.test(raw.trim())) {
    const n = BigInt(raw.trim());
    if (n === 0n) {
      const text = name === 'lockouttime' ? 'aucun verrouillage' : name === 'pwdlastset' ? 'changement exigé à la prochaine ouverture de session' : 'jamais';
      return { kind: 'special', text, raw };
    }
    if (n >= NEVER) return { kind: 'special', text: 'jamais', raw };
    const iso = fileTimeToIso(raw);
    if (iso) return { kind: 'date', text: localStamp(iso), raw, iso };
  }
  if (GENERALIZED.has(name)) {
    const t = Date.parse(raw);
    if (!Number.isNaN(t)) {
      const iso = new Date(t).toISOString();
      return { kind: 'date', text: localStamp(iso), raw, iso };
    }
  }
  if ((DN_NAMES.has(name) || name === 'distinguishedname') && isDn(raw)) {
    return { kind: 'dn', text: name === 'distinguishedname' ? raw : dnName(raw), raw };
  }
  return { kind: 'text', text: raw, raw };
}

/** True for a value without space (an identifier, a DNS name): it must not break at its hyphens. */
export function isIdentifier(text) {
  const value = String(text ?? '');
  return value.length > 0 && value.length <= 80 && !/\s/.test(value);
}

/** Names of a pasted list: one per line, or separated by commas, semicolons or spaces; blanks and duplicates removed. */
export function parseNames(text) {
  const seen = new Set();
  const names = [];
  for (const raw of String(text ?? '').split(/[\s,;]+/)) {
    const name = raw.trim();
    if (!name || seen.has(name.toLowerCase())) continue;
    seen.add(name.toLowerCase());
    names.push(name);
  }
  return names;
}

/**
 * Address of the view of a step on another screen (route contract of docs/KIT.md § 3.1): Fiche « tab », Poste « onglet »,
 * Audit AD « tab=objet » and its inner view « vue ».
 */
export function stepRoute(view, dn) {
  if (view.screen === 'fiche') return { screen: 'fiche', params: { dn, tab: view.section } };
  if (view.screen === 'audit') return { screen: 'audit', params: { tab: 'objet', dn, vue: view.section } };
  return { screen: view.screen, params: { dn, onglet: view.section } };
}

/** An argument of the shown command, quoted when it holds a space or a quote. */
export const quoteArg = (text) => (/[\s"]/.test(text) ? `"${String(text).replace(/"/g, '\\"')}"` : String(text));

/**
 * The command line equivalent to an offline dossier (docs/ops/assistance.md § 6.1). perimeter: { postes?: string[],
 * ou?: string, guids?: string[] } (one of them); sections: the optional sections chosen among all (null = all, so no
 * « --sections »); « etat,postes » alone writes none of them. Empty without a perimeter.
 */
export function dossierCommand(perimeter, sections, allSections, simulation) {
  let scope = '';
  if (perimeter?.postes?.length) scope = `--postes ${perimeter.postes.map(quoteArg).join(',')}`;
  else if (perimeter?.ou) scope = `--ou ${quoteArg(perimeter.ou)}`;
  else if (perimeter?.guids?.length) scope = `--guids ${perimeter.guids.join(',')}`;
  if (!scope) return '';
  const all = !sections || sections.length === allSections.length;
  const chosen = all ? '' : ` --sections ${sections.length ? sections.join(',') : 'etat,postes'}`;
  return `Domenia.exe dossier --sortie "<dossier local>" ${scope}${chosen}${simulation ? ' --simulation' : ''}`;
}
