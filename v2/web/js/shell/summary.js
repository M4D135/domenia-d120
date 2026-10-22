// Operation summary before execution (TRV-061) and masking of secret-looking text (Domenia 1 Get-DomeniaOperationSummary,
// Test-DomeniaShellSensitiveOption, Protect-DomeniaSecretText). Pure: no DOM, no bridge (tests/web/shell).

const NBSP = '\u00A0';

/**
 * Masks what looks like a secret before a text reaches the clipboard (support copy) or a journal: BitLocker recovery
 * passwords, Bearer and Basic authorizations, JSON members, « clé=valeur » and « clé : valeur » forms, password switches.
 */
export function protectText(text) {
  let t = String(text ?? '');
  if (!t) return '';
  t = t.replace(/(?<!\d)(?:\d{6}-){7}\d{6}(?!\d)/g, '[clé de récupération masquée]');
  t = t.replace(/\b(Bearer|Basic)\s+[A-Za-z0-9_.~+/=-]+/gi, '$1 ***');
  t = t.replace(/("(?:password|passwd|pwd|pass|p|motdepasse|secret|token|api[_-]?key|apikey|client[_-]?secret)"\s*:\s*)("(?:\\.|[^"\\])*"|[^,}\s]+)/gi, '$1"***"');
  t = t.replace(/\b(password|passwd|pwd|pass|motdepasse|mot\s+de\s+passe|secret|token|authorization|api[_-]?key|apikey|client[_-]?secret)(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s;,]+)/gi, '$1$2***');
  t = t.replace(/(^|\s)([-/](?:p|rp|pass|password|pwd))(?:\s+|[:=])("[^"]*"|'[^']*'|\S+)/gi, '$1$2 ***');
  return t;
}

const SECRET_ATTRIBUTE = /^(?:unicodePwd|userPassword|unixUserPassword|clearTextPassword|dBCSPwd|supplementalCredentials|ntPwdHistory|lmPwdHistory|currentValue|priorValue|pekList|trustAuthIncoming|trustAuthOutgoing|ms-Mcs-AdmPwd|msLAPS-.+|msFVE-RecoveryPassword|msFVE-KeyPackage|msDS-ManagedPassword.*|msDS-KeyCredentialLink)$/i;
const SENSITIVE_WORDS = /\b(pass|passe|password|passwd|passphrase|pwd|motdepasse|secrets?|tokens?|jetons?|apikey|credentials?|cl(e|é)s?|pin|laps|recovery|r(e|é)cup(e|é)ration)\b|\bmot\s+de\s+passe\b|\bapi\s+key\b|\bbit\s*locker\b/i;

/** Directory attributes that carry a secret: never a value in an export, a summary or a copy. */
export function isSecretAttribute(name) {
  return SECRET_ATTRIBUTE.test(String(name ?? '').trim());
}

/**
 * An option whose value must not be shown: flagged, or named or labelled like a secret (fail closed). A yes/no or a date
 * carries no secret and stays visible (« Changer le mot de passe : Oui »).
 */
export function isSensitiveOption(option) {
  if (!option) return false;
  if (option.sensitive === true) return true;
  const v = option.value;
  if (typeof v === 'boolean' || v instanceof Date) return false;
  const words = `${option.name ?? ''} ${option.label ?? ''}`.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/[_\-.:/]/g, ' ');
  return SENSITIVE_WORDS.test(words) || isSecretAttribute(option.name);
}

/** Display text of a value: Oui/Non, list joined, date jj/mm/aaaa hh:mm, one bounded line. */
export function valueText(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'boolean') return value ? 'Oui' : 'Non';
  if (value instanceof Date) {
    const p = (n) => String(n).padStart(2, '0');
    return `${p(value.getDate())}/${p(value.getMonth() + 1)}/${value.getFullYear()} ${p(value.getHours())}:${p(value.getMinutes())}`;
  }
  if (Array.isArray(value)) return flat(value.map(valueText).join(', '), 160);
  if (typeof value === 'number') return new Intl.NumberFormat('fr-FR').format(value);
  if (typeof value === 'object') return flat(JSON.stringify(value), 160);
  return flat(String(value), 160);
}

function flat(text, max) {
  const t = String(text ?? '').replace(/\s+/g, ' ').trim();
  return t.length <= max ? t : `${t.slice(0, max - 1).trimEnd()}…`;
}

/**
 * Every value that changes what an operation does, listed before execution, folded options included (folding changes the
 * form, never the summary); sensitive values show « (masqué) ».
 * @param {string} operation
 * @param {Array<{ name?: string, label?: string, value?: any, default?: any, influences?: boolean, advanced?: boolean, sensitive?: boolean }>} options
 * @param {{ collapsed?: boolean }} [o]
 * @returns {{ operation: string, lines: Array<{ name: string, label: string, value: string, advanced: boolean, changed: boolean }>, text: string, collapsed: boolean, foldedListed: number }}
 */
export function operationSummary(operation, options = [], { collapsed = true } = {}) {
  const lines = [];
  let folded = 0;
  for (const option of options) {
    if (!option) continue;
    const name = String(option.name ?? '');
    const label = flat(option.label || name, 80);
    const value = valueText(option.value);
    const def = valueText(option.default);
    const influences = option.influences !== false;
    const advanced = option.advanced === true;
    const changed = value !== def;
    if (!influences && !changed) continue;
    if (advanced && collapsed) folded += 1;
    let shown = protectText(value);
    if (isSensitiveOption(option)) shown = '(masqué)';
    else if (!shown) shown = 'Non défini';
    lines.push({ name, label, value: shown, advanced, changed });
  }
  const op = flat(operation, 120);
  const text = lines.length
    ? `${op}${NBSP}: ${lines.map((l) => `${l.label}${NBSP}: ${l.value}`).join(' · ')}`
    : `${op}${NBSP}: aucune option particulière.`;
  return { operation: op, lines, text, collapsed, foldedListed: folded };
}
