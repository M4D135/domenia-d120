// Atelier de requêtes: shared helpers (texts, tones, store of the draft and of the frozen preview, bridge calls).
// Contract: docs/ops/requetes.md. Every read goes through ctx.call; nothing here touches the network or the disk.
import { glyph } from '../../kit/glyphs.js';
import { esc, errorText, formatNumber, relTime, formatDateTime } from '../../ui.js';

export { esc, glyph, formatNumber, relTime, formatDateTime };

export const NBSP = ' ';
export const NNBSP = ' ';

export const SOURCE_TONE = {
  ad: 'ad', local: 'local', observation: 'seen', probe: 'probe', instance: 'probe', detail: 'seen', ldap: 'ldap',
};
export const SOURCE_LABEL = {
  ad: 'Annuaire AD', local: 'Calcul local', observation: 'Relevé du poste', probe: 'Sonde WMI', instance: 'Instance de sonde', detail: 'SELECT mémorisé', ldap: 'LDAP',
};
export const VERDICTS = {
  match: { label: 'Correspond', short: 'Correspondants', tone: 'ok', icon: 'check' },
  unknown: { label: 'Inconnu', short: 'Inconnus', tone: 'warn', icon: 'info' },
  noMatch: { label: 'Ne correspond pas', short: 'Non correspondants', tone: 'off', icon: 'x' },
  outside: { label: 'Hors sélection', short: 'Hors sélection', tone: 'off', icon: 'minus' },
};
export const TARGETS = [
  { id: 'computer', label: 'Postes', icon: 'monitor', noun: ['poste', 'postes'] },
  { id: 'user', label: 'Utilisateurs', icon: 'user', noun: ['compte', 'comptes'] },
  { id: 'group', label: 'Groupes', icon: 'group', noun: ['groupe', 'groupes'] },
];
export const OPERATOR_LABEL = {
  equal: 'est égal à', notEqual: 'est différent de', contains: 'contient', startsWith: 'commence par', endsWith: 'se termine par',
  greater: 'est supérieur à', greaterOrEqual: 'est supérieur ou égal à', less: 'est inférieur à', lessOrEqual: 'est inférieur ou égal à',
  isMissing: 'est absent', isPresent: 'est renseigné',
};
export const OPERATOR_SHORT = {
  equal: '=', notEqual: '≠', contains: 'contient', startsWith: 'commence par', endsWith: 'finit par',
  greater: '>', greaterOrEqual: '≥', less: '<', lessOrEqual: '≤', isMissing: 'absent', isPresent: 'renseigné',
};

/** Camel-case key of an enum value sent by the engine (« GreaterOrEqual » or « greaterOrEqual »). */
export const key = (v) => (typeof v === 'string' && v ? v[0].toLowerCase() + v.slice(1) : v);

export function plural(n, one, many) {
  return `${formatNumber(Number(n) || 0)}${NBSP}${Math.abs(Number(n)) >= 2 ? many : one}`;
}

export const num = (v, d = 0) => (Number.isFinite(v) ? formatNumber(v, d) : '—');

export function nounOf(target) {
  return (TARGETS.find((t) => t.id === key(target)) ?? TARGETS[0]).noun;
}

export const pct = (part, total) => (total > 0 ? Math.round((1000 * part) / total) / 10 : 0);

/** Readable value of a condition (« 8 Go », « Oui », « « Windows 11 » », parameter). */
export function valueText(value, field) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'object' && value.parameter) return `paramètre ${value.parameter}`;
  if (typeof value === 'boolean') return value ? 'Oui' : 'Non';
  const choice = field?.choices?.find((c) => String(c.value) === String(value) && typeof c.value === typeof value);
  if (choice) return choice.name;
  if (typeof value === 'number') {
    const unit = { Go: 'Go', Mo: 'Mo', Jours: 'j', '%': '%', 'Mbit/s': 'Mbit/s', MHz: 'MHz' }[field?.unit];
    return `${formatNumber(value, Number.isInteger(value) ? 0 : 2)}${unit ? NBSP + unit : ''}`;
  }
  return `«${NBSP}${value}${NBSP}»`;
}

export function clauseText(clause, field) {
  const name = field?.name ?? clause.field;
  const op = key(clause.operator);
  if (clause.field === 'ldap.filter') return `Filtre LDAP ${clause.value ?? ''}`;
  if (op === 'isMissing' || op === 'isPresent') return `${name} ${OPERATOR_LABEL[op]}`;
  return `${name} ${OPERATOR_LABEL[op] ?? op} ${valueText(clause.value, field)}`;
}

export function sourcePill(source) {
  const s = key(source);
  return `<span class="rq-src" data-src="${esc(SOURCE_TONE[s] ?? 'ad')}">${esc(SOURCE_LABEL[s] ?? s)}</span>`;
}

export function verdictPill(verdict, size = '') {
  const v = VERDICTS[verdict] ?? VERDICTS.unknown;
  return `<span class="rq-verdict ${size}" data-v="${esc(verdict)}">${glyph(v.icon)}${esc(v.label)}</span>`;
}

export const skLines = (...widths) => `<div class="rq-sk">${widths.map((w) => `<span class="skeleton rq-skl w${w}"></span>`).join('')}</div>`;

export function emptyState(icon, title, text, action = '') {
  return `<div class="empty rq-empty"><div class="art">${glyph(icon)}</div><h3>${esc(title)}</h3>${text ? `<p>${esc(text)}</p>` : ''}${action}</div>`;
}

export function dateText(iso) {
  return formatDateTime(iso) ?? '—';
}

export function ago(iso, prefix = '') {
  const t = relTime(iso);
  return t ? `${prefix}${t}` : '—';
}

/** Deep copy of a recipe (plain JSON). */
export const clone = (o) => (o === null || o === undefined ? o : JSON.parse(JSON.stringify(o)));

export function newId() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export function emptyRecipe(target = 'computer') {
  const name = { computer: 'Tous les postes recensés', user: 'Tous les comptes utilisateurs recensés', group: 'Tous les groupes recensés' }[target] ?? 'Nouvelle requête';
  return {
    format: 'Domenia.Query/3', id: newId(), name, target, junction: 'all', clauses: [], groupBy: null, refinements: [],
    probeSelection: null, objectIds: null, parameters: [], parameterValues: null, expression: null, coherenceHours: null, readDefinition: null,
  };
}

/** Store of the screen: draft, catalogs, validation, frozen preview, scope; listeners per topic. */
export function createStore(ctx) {
  const listeners = new Map();
  const store = {
    ctx,
    alive: true,
    recipe: emptyRecipe(),
    version: 0,
    catalogs: new Map(),
    validation: null,
    evaluation: null,
    evaluating: false,
    scope: null,
    saved: null,
    readOnlyLdap: false,
    on(topic, fn) {
      if (!listeners.has(topic)) listeners.set(topic, new Set());
      listeners.get(topic).add(fn);
      return () => listeners.get(topic)?.delete(fn);
    },
    emit(topic, data) {
      for (const fn of [...(listeners.get(topic) ?? [])]) {
        try { fn(data); } catch (err) { console.error(err); }
      }
    },
    /** Calls the engine; refusals come back as { error } with the engine's French message, never thrown. */
    async call(op, args) {
      try {
        return { data: await ctx.call(op, args) };
      } catch (err) {
        if (!err?.code) console.error(err);
        return { error: err, message: errorText(err, 'L’opération a échoué : le détail est dans le journal technique.') };
      }
    },
    /** Catalog of a target, read once; the same promise is returned (resolvedCatalog decorates it). */
    catalog(target) {
      const t = key(target) ?? 'computer';
      if (!store.catalogs.has(t)) store.catalogs.set(t, ctx.call('requetes.catalog', { target: t }).catch((err) => { store.catalogs.delete(t); throw err; }));
      return store.catalogs.get(t);
    },
    setRecipe(recipe, { origin = 'edit', quiet = false } = {}) {
      store.recipe = recipe;
      store.version += 1;
      if (!quiet) store.emit('recipe', { origin });
    },
    toast(message, tone = 'info') {
      ctx.toast(message, { tone });
    },
  };
  return store;
}

/** Resolves a catalog once: map by id and the instance fields. */
export async function resolvedCatalog(store, target) {
  const promise = store.catalog(target);
  const data = await promise;
  if (!promise.resolved) {
    const byId = new Map();
    for (const f of data.fields) byId.set(f.id, f);
    for (const f of data.instanceFields ?? []) byId.set(f.id, f);
    for (const f of data.ldapFields ?? []) byId.set(f.id, f);
    promise.resolved = { data, byId };
  }
  return promise.resolved;
}

/** Field of the current target, from the catalog already read (raw LDAP attributes get a generated entry). */
export function fieldOf(store, id, target = store.recipe.target) {
  const promise = store.catalogs.get(key(target) ?? 'computer');
  const resolved = promise?.resolved;
  if (!resolved) return null;
  if (resolved.byId.has(id)) return resolved.byId.get(id);
  if (id === 'ldap.filter') return { id, name: 'Filtre LDAP', kind: 'text', source: 'ldap', unit: 'Texte', operators: ['equal'], choices: [] };
  if (typeof id === 'string' && id.startsWith('ldap:')) {
    return { id, name: `LDAP · ${id.slice(5)}`, kind: 'text', source: 'ldap', unit: 'Texte', choices: [],
      operators: ['equal', 'notEqual', 'contains', 'startsWith', 'endsWith', 'greaterOrEqual', 'lessOrEqual', 'isMissing', 'isPresent'] };
  }
  return null;
}

/** Parts of a distinguished name, top first (RFC 4514 escapes kept): « Paris › Postes ». */
export function dnParts(dn) {
  const parts = [];
  let current = '';
  for (let i = 0; i < (dn ?? '').length; i += 1) {
    const c = dn[i];
    if (c === '\\' && i + 1 < dn.length) { current += c + dn[i + 1]; i += 1; continue; }
    if (c === ',') { parts.push(current); current = ''; continue; }
    current += c;
  }
  if (current) parts.push(current);
  return parts.map((p, n) => {
    const at = p.indexOf('=');
    return { type: p.slice(0, at).trim().toUpperCase(), value: p.slice(at + 1).trim().replace(/\\(.)/g, '$1'), dn: parts.slice(n).join(',') };
  });
}

/** Download-free export: copies a text to the clipboard (the page never writes a file itself). */
export async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const area = document.createElement('textarea');
    area.value = text;
    area.className = 'rq-offscreen';
    document.body.appendChild(area);
    area.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch { ok = false; }
    area.remove();
    return ok;
  }
}

/** Applies data-* CSS variables (CSP: no style attribute). */
export function vars(scope) {
  scope.querySelectorAll('[data-w]').forEach((el) => el.style.setProperty('--w', `${Math.max(0, Math.min(100, Number(el.dataset.w) || 0))}%`));
  scope.querySelectorAll('[data-depth]').forEach((el) => el.style.setProperty('--depth', String(Number(el.dataset.depth) || 0)));
  scope.querySelectorAll('[data-i]').forEach((el) => el.style.setProperty('--i', el.dataset.i));
  scope.querySelectorAll('[data-p]').forEach((el) => el.style.setProperty('--p', String(Math.max(0, Math.min(1, Number(el.dataset.p) || 0)))));
}
