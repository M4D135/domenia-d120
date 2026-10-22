// Comptes screen: pure rules of the page (no DOM, no bridge, no import), so tests/web can run them in Node or in the
// WebView2 engine: live checks of a typed password (same rules as AccountPasswordReset.CheckPolicy), the password
// generator, the reasons of the greyed expiration actions, the CSV of a collective preview, and the decision of
// prefilling a field without ever overwriting what the operator typed (Domenia 1 CPT-016).

const NBSP = ' ';
const NNBSP = ' ';

/** Characters of a generated password: no look-alikes (O 0, I l 1), every class present. */
export const PASSWORD_SETS = ['ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#$%&*+-=?@_'];

/** Longest password the engine admits (AccountPasswordReset.MaxLength). */
export const PASSWORD_MAX = 256;

/** Whole number with the thousands separated by U+202F (FrenchText.Integer). */
export function int(n) {
  const digits = String(Math.abs(Math.trunc(Number(n) || 0))).replace(/\B(?=(\d{3})+(?!\d))/g, NNBSP);
  return n < 0 ? `−${digits}` : digits;
}

/**
 * Live checks of a typed password, the same rules as the engine (AccountPasswordReset.CheckPolicy): the minimum length of
 * the domain (1 at least, like the engine: Math.Max(1, minLength)); the three classes and the name only when the domain asks
 * for complexity (pwdProperties); then the confirmation. Never keeps the password.
 * @returns {{ id: string, label: string, met: boolean }[]}
 */
export function passwordChecks(value, confirm, { sam, name, minLength, complexity = true }) {
  const v = String(value ?? '');
  const min = Math.max(1, Math.trunc(Number(minLength)) || 1);
  const checks = [{ id: 'length', label: `${int(min)}${NBSP}${min >= 2 ? 'caractères' : 'caractère'} au moins`, met: v.length >= min && v.length <= PASSWORD_MAX }];
  if (complexity) {
    const classes = [/[A-ZÀ-ÖØ-Þ]/u.test(v), /[a-zß-öø-ÿ]/u.test(v), /\d/.test(v), /[^\p{L}\p{N}]/u.test(v)].filter(Boolean).length;
    const lower = v.toLocaleLowerCase('fr');
    const tokens = String(name ?? '').split(/[,.\-_\s#'’\t]+/).filter((t) => t.length >= 3).map((t) => t.toLocaleLowerCase('fr'));
    const hasName = (sam && sam.length >= 3 && lower.includes(String(sam).toLocaleLowerCase('fr'))) || tokens.some((t) => lower.includes(t));
    checks.push({ id: 'classes', label: 'Trois types parmi majuscules, minuscules, chiffres et symboles', met: classes >= 3 });
    checks.push({ id: 'name', label: 'Ni le nom du compte ni une partie du nom affiché', met: v.length > 0 && !hasName });
  }
  checks.push({ id: 'match', label: 'Confirmation identique', met: v.length > 0 && v === confirm });
  return checks;
}

/**
 * Strength score of a typed password, 0 to 4 (bars of the form): the share of the domain rules met, plus one from
 * 16 characters on. 0 for an empty field.
 */
export function passwordScore(value, checks) {
  const v = String(value ?? '');
  if (!v) return 0;
  const base = checks.filter((c) => c.id !== 'match');
  return Math.min(4, Math.round((base.filter((c) => c.met).length / Math.max(1, base.length)) * 3) + (v.length >= 16 ? 1 : 0));
}

/**
 * A random password of `length` characters (16 by default, 4 at least) with the four classes, drawn with
 * crypto.getRandomValues without modulo bias; never sent before « Préparer ».
 */
export function generatePassword(length = 16, random = globalThis.crypto) {
  const size = Math.min(PASSWORD_MAX, Math.max(PASSWORD_SETS.length, Math.trunc(length) || 16));
  const all = PASSWORD_SETS.join('');
  const pick = (set) => {
    const max = 256 - (256 % set.length);
    const buf = new Uint8Array(1);
    for (;;) {
      random.getRandomValues(buf);
      if (buf[0] < max) return set[buf[0] % set.length];
    }
  };
  const chars = PASSWORD_SETS.map(pick);
  while (chars.length < size) chars.push(pick(all));
  for (let i = chars.length - 1; i > 0; i--) {
    const buf = new Uint32Array(1);
    random.getRandomValues(buf);
    const j = buf[0] % (i + 1);
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }
  return chars.join('');
}

/**
 * Why an expiration action is greyed (the kit: a greyed action says why): the engine reason first (krbtgt, session
 * account…), then the state of the account for « Supprimer l’expiration ».
 * @returns {{ set: string|null, never: string|null }}
 */
export function expirationReasons(actions, state) {
  const blocked = !actions?.expiration?.available ? (actions?.expiration?.reason ?? 'Expiration indisponible pour ce compte.') : null;
  return {
    set: blocked,
    never: blocked ?? (state?.accountExpiresAt ? null : `Le compte n’a aucune expiration${NBSP}: rien à supprimer.`),
  };
}

/** One CSV cell (KIT § 4.1): semicolon separated, quotes doubled, a cell starting with = + - @ neutralised. */
export function csvCell(value) {
  let text = value == null ? '' : String(value);
  if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`;
  return /[;"\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

/**
 * CSV of a collective preview (TRV-229 improvement « exporter en CSV »): every target with what it receives, then every
 * named exclusion with its reason. French headers, semicolons, CRLF; no secret ever (the preview holds none).
 */
export function previewCsv(preview) {
  const lines = [['Rang', 'Nom', 'Compte', 'DN', 'Changement', 'Avant', 'Après', 'Statut'].map(csvCell).join(';')];
  (preview?.targets ?? []).forEach((t, n) => {
    lines.push([n + 1, t.name, t.sam, t.dn, t.change, t.before ?? '', t.after ?? '', 'Retenu'].map(csvCell).join(';'));
  });
  (preview?.excluded ?? []).forEach((x) => {
    lines.push(['', x.name, '', x.dn ?? '', '', '', '', `Exclu${NBSP}: ${x.reason}`].map(csvCell).join(';'));
  });
  return lines.join('\r\n');
}

/**
 * Whether a field may take a value read asynchronously (remembered identifier, current account): never when the operator
 * typed in it since it was drawn, nor while it has the focus (Domenia 1 CPT-016: « une lecture asynchrone n’écrase jamais un
 * texte tapé entre-temps »).
 * @param {{ value: string, dirty: boolean, focused: boolean }} field
 */
export function mayPrefill(field) {
  return !field.dirty && !field.focused;
}

const pad2 = (n) => String(n).padStart(2, '0');

/** Local « yyyy-MM-dd » of a Date. */
export function isoOfDate(d) {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/** Local Date of a real day « yyyy-MM-dd », or null (31/02 is not a day). */
export function dateOfIso(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso ?? ''));
  if (!m) return null;
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  return d.getMonth() === Number(m[2]) - 1 && d.getDate() === Number(m[3]) ? d : null;
}

/** « 20/11/2026 » of « 2026-11-20 », or ''. */
export function frenchDay(iso) {
  const d = dateOfIso(iso);
  return d ? `${pad2(d.getDate())}/${pad2(d.getMonth() + 1)}/${d.getFullYear()}` : '';
}

/**
 * Local day « yyyy-MM-dd » of a typed French date (« 20/11/2026 », « 20112026 », « 20-11-2026 », « 2026-11-20 »), or null
 * when the text is not a real day between 1601 and 9999.
 */
export function parseFrenchDay(text) {
  const t = String(text ?? '').trim();
  let m = /^(\d{1,2})[/.\- ](\d{1,2})[/.\- ](\d{4})$/.exec(t) ?? /^(\d{2})(\d{2})(\d{4})$/.exec(t);
  let y; let mo; let d;
  if (m) { [, d, mo, y] = m.map(Number); } else {
    m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(t);
    if (!m) return null;
    [, y, mo, d] = m.map(Number);
  }
  if (y < 1601 || y > 9999) return null;
  const date = new Date(y, mo - 1, d);
  return date.getFullYear() === y && date.getMonth() === mo - 1 && date.getDate() === d ? isoOfDate(date) : null;
}
