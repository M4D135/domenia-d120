// Accessibility of the shell (TRV-002, TRV-003): announcements made once (an unchanged text is not announced again), and a
// local check of the screen shown — controls without an accessible name, greyed controls without a reason (Domenia 1
// Get-DomeniaMissingDisabledHelp), fields without a label, duplicate identifiers, positive tab orders. Nothing is sent.
import { announce } from '../ui.js';

const last = new Map();

/**
 * Announces a text in a polite (or assertive) live region, once per key: the same text for the same key is not announced
 * again (Domenia 1 Send-DomeniaUxLiveChange).
 */
export function announceOnce(key, text, { assertive = false } = {}) {
  const t = String(text ?? '').trim();
  if (!t || last.get(key) === t) return false;
  last.set(key, t);
  announce(t, { assertive });
  return true;
}

/** Accessible name of an element, as a screen reader would read it (short form). */
export function accessibleName(el) {
  const labelled = el.getAttribute('aria-labelledby');
  if (labelled) {
    const text = labelled.split(/\s+/).map((id) => document.getElementById(id)?.textContent ?? '').join(' ').trim();
    if (text) return text;
  }
  const aria = el.getAttribute('aria-label');
  if (aria?.trim()) return aria.trim();
  if (el.id) {
    const label = document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
    if (label?.textContent.trim()) return label.textContent.trim();
  }
  const wrap = el.closest('label');
  if (wrap?.textContent.trim()) return wrap.textContent.trim();
  if (el.title?.trim()) return el.title.trim();
  if (el.placeholder?.trim?.()) return el.placeholder.trim();
  const own = el.textContent?.trim();
  return own || '';
}

function describe(el) {
  const name = accessibleName(el);
  const tag = el.tagName.toLowerCase();
  const role = el.getAttribute('role');
  return `${role ?? tag}${name ? ` « ${name.slice(0, 50)} »` : ''}${el.id ? ` #${el.id}` : ''}${el.dataset?.command ? ` [${el.dataset.command}]` : ''}`;
}

/**
 * Checks a part of the page. Findings: { rule, severity ('alert'|'warn'), text, target }.
 * @param {ParentNode} scope
 */
export function auditAccessibility(scope = document) {
  const findings = [];
  const add = (rule, severity, text, el) => findings.push({ rule, severity, text, target: el ? describe(el) : '' });
  const interactive = scope.querySelectorAll('button, a[href], [role="button"], [role="menuitem"], [role="tab"], [role="option"], [role="checkbox"], [role="switch"], input, select, textarea');
  for (const el of interactive) {
    if (el.closest('[hidden], [aria-hidden="true"]') || el.type === 'hidden') continue;
    if (!accessibleName(el)) add('name', 'alert', 'Contrôle sans nom accessible : un lecteur d’écran ne peut pas le nommer.', el);
    const disabled = el.disabled === true || el.getAttribute('aria-disabled') === 'true';
    if (disabled && !el.dataset.reason && !el.dataset.tip && !el.getAttribute('aria-description') && !el.title && !el.closest('[data-tip]')) {
      add('reason', 'warn', 'Contrôle grisé sans motif : l’opérateur ne sait pas pourquoi (info-bulle, F1).', el);
    }
    if (Number(el.getAttribute('tabindex')) > 0) add('tabindex', 'warn', 'Ordre de tabulation forcé (tabindex positif) : l’ordre de lecture est faussé.', el);
  }
  for (const el of scope.querySelectorAll('input:not([type="hidden"]), select, textarea')) {
    if (el.closest('[hidden]')) continue;
    if (!accessibleName(el)) add('label', 'alert', 'Champ sans étiquette.', el);
  }
  const ids = new Map();
  for (const el of scope.querySelectorAll('[id]')) ids.set(el.id, (ids.get(el.id) ?? 0) + 1);
  for (const [id, n] of ids) if (n > 1) add('duplicate', 'warn', `Identifiant « ${id} » présent ${n} fois : les liens d’étiquette et de description sont ambigus.`, null);
  for (const img of scope.querySelectorAll('img')) {
    if (!img.hasAttribute('alt')) add('alt', 'alert', 'Image sans texte de remplacement.', img);
  }
  for (const svg of scope.querySelectorAll('svg')) {
    if (svg.closest('[aria-hidden="true"]') || svg.getAttribute('aria-hidden') === 'true' || svg.getAttribute('role') === 'img' || svg.closest('button, a, [role="button"]')) continue;
    if (!svg.closest('.svg-defs')) add('svg', 'warn', 'Dessin sans rôle ni masquage (aria-hidden ou role="img" attendu).', svg);
  }
  return findings;
}
