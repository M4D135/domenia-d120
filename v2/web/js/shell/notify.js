// Notifications of the shell (TRV-172 to TRV-174): banners in the page, never a window. Information and success close after
// 5 s unless they carry a detail or several paragraphs (and stay under the pointer or the focus); warnings and errors stay
// until closed. Three banners at most, the oldest leaves first. The same message updates its banner (×N, update time); an
// INC-XXXX code is extracted. Every banner stays in the session journal of the notification centre after it closes.
import { icon } from '../icons.js';
import { esc, announce, motionReduced, copyText } from '../ui.js';
import { emit, state } from './store.js';
import { followRoute, routeOfText, ROUTES } from './help.js';
import { protectText } from './summary.js';

const MAX_VISIBLE = 3;
const AUTO_CLOSE_MS = 5000;
const MAX_JOURNAL = 200;
const TONE_ALIASES = { ok: 'ok', success: 'ok', info: 'info', off: 'info', accent: 'info', warn: 'warn', warning: 'warn', alert: 'alert', error: 'alert' };
const KIND_LABELS = { ok: 'Terminé', info: 'Information', warn: 'Attention', alert: 'Erreur' };
const TONE_ICONS = { ok: 'check', info: 'info', warn: 'alert', alert: 'alert' };
const COUNTER_WORDS = { alert: 'même erreur', warn: 'même avertissement' };

/** Session journal of the notifications, most recent first. */
const journal = [];
let seq = 0;
let openCentre = null;

/** app.js hands the function that opens the notification centre (« Ouvrir le journal »). */
export function setCentreOpener(fn) { openCentre = fn; }

/**
 * What a banner shows and how long it stays (Domenia 1 Get-DomeniaBannerPlan): headline (first paragraph), body (the other
 * paragraphs), INC code, automatic closing (0 = stays).
 */
export function bannerPlan(tone, message, detail = '') {
  const text = String(message ?? '').trim();
  const code = (/\bINC-[0-9A-F]{4}\b/.exec(text) ?? [''])[0];
  const paragraphs = text.split(/(?:\r?\n[ \t]*){2,}/).map((p) => p.trim()).filter(Boolean);
  const headline = paragraphs[0] ?? '';
  const body = paragraphs.slice(1).join('\n\n');
  const sticky = tone === 'alert' || tone === 'warn' || paragraphs.length > 1 || String(detail ?? '').trim() !== '';
  return { headline, body, code, autoClose: sticky ? 0 : AUTO_CLOSE_MS };
}

export function notes() { return journal; }

export function unreadCount() { return journal.filter((n) => !n.read).length; }

export function markAllRead() {
  let changed = false;
  for (const n of journal) if (!n.read) { n.read = true; changed = true; }
  if (changed) emit('notes', journal);
}

export function clearNotes() {
  journal.length = 0;
  emit('notes', journal);
}

/** Text copied for the support (Domenia 1 Get-DomeniaBannerSupportText): code, date, occurrences, message, detail, masked. */
export function supportText(n) {
  const lines = [
    `Domenia – incident ${n.code || 'sans code'}`,
    `Date : ${new Date(n.at).toLocaleString('fr-FR')}`,
  ];
  if (n.count > 1) lines.push(`Occurrences : ${n.count}`);
  lines.push(`Écran : ${n.screen || '—'}`);
  lines.push(`Message : ${n.message}`);
  if (n.detail) lines.push('Détail :', n.detail);
  lines.push('Journal technique : %LOCALAPPDATA%\\Domenia\\logs\\domenia.log (rechercher l’heure ou le code).');
  return protectText(lines.join('\r\n'));
}

/**
 * Shows a banner.
 * @param {string} message French text; a blank line separates the headline from the rest.
 * @param {{ tone?: string, life?: number, detail?: string, key?: string, route?: string, routeLabel?: string,
 *   folder?: () => void, folderLabel?: string, actions?: Array<{ label: string, icon?: string, run: () => void }> }} [o]
 * @returns {object} the record of the journal (its element is `el` while it is shown)
 */
export function notify(message, o = {}) {
  const tone = TONE_ALIASES[o.tone] ?? 'info';
  const plan = bannerPlan(tone, message, o.detail);
  const key = o.key || plan.code || `${tone}|${String(message ?? '').trim()}`;
  const existing = journal.find((n) => n.key === key && n.el?.isConnected && !n.closed);
  if (existing) {
    existing.count += 1;
    existing.at = Date.now();
    existing.detail = String(o.detail ?? existing.detail ?? '');
    existing.read = false;
    refreshOccurrence(existing, plan, o);
    announce(String(message ?? ''), { assertive: tone === 'alert' });
    emit('notes', journal);
    return existing;
  }
  const routeCode = o.route && ROUTES[o.route] ? o.route : (o.route === undefined ? routeOfText(message) : '');
  const n = {
    id: ++seq, key, tone, kind: KIND_LABELS[tone], message: String(message ?? '').trim(), headline: plan.headline, body: plan.body,
    detail: String(o.detail ?? ''), code: plan.code, count: 1, at: Date.now(), firstAt: Date.now(), route: routeCode,
    routeLabel: o.routeLabel ?? (routeCode ? ROUTES[routeCode].label : ''), folder: typeof o.folder === 'function' ? o.folder : null,
    folderLabel: o.folderLabel ?? 'Ouvrir le dossier', actions: Array.isArray(o.actions) ? o.actions : [], read: false, closed: false,
    screen: state.page?.label ?? '', el: null, timer: 0, pinned: false, left: 0, started: 0,
  };
  journal.unshift(n);
  if (journal.length > MAX_JOURNAL) journal.length = MAX_JOURNAL;
  show(n, Number.isFinite(o.life) && o.life > 0 && plan.autoClose > 0 ? o.life : plan.autoClose);
  announce(n.message, { assertive: tone === 'alert' });
  emit('notes', journal);
  return n;
}

function host() { return document.querySelector('.toasts'); }

function show(n, life) {
  const region = host();
  if (!region) return;
  const visible = journal.filter((x) => x.el?.isConnected && !x.closed);
  while (visible.length >= MAX_VISIBLE) close(visible.pop(), false);
  const el = document.createElement('div');
  el.className = 'toast sh-note';
  el.dataset.tone = n.tone;
  el.setAttribute('role', 'group');
  el.setAttribute('aria-label', `${n.kind} : ${n.headline}`);
  el.innerHTML = `<span class="toast-icon">${icon(TONE_ICONS[n.tone])}</span>
    <div class="toast-body">
      <div class="sh-note-head"><span class="sh-note-kind">${esc(n.kind)}</span>${n.code ? `<span class="sh-note-code mono">${esc(n.code)}</span>` : ''}<span class="sh-note-count" hidden></span></div>
      <p class="sh-note-text">${esc(n.headline)}</p>
      ${n.body ? `<div class="sh-note-more">${esc(n.body).replace(/\n/g, '<br>')}</div>` : ''}
      <pre class="sh-note-detail" hidden></pre>
      <div class="sh-note-actions"></div>
    </div>
    <button class="btn ghost icon sm toast-close" type="button" aria-label="Fermer le message" data-tip="Fermer : il reste dans le journal de la session">${icon('x')}</button>
    <span class="bar" aria-hidden="true"></span>`;
  n.el = el;
  renderActions(n);
  const tones = { ok: 'var(--ok-mark)', info: 'var(--info-mark)', warn: 'var(--warn-mark)', alert: 'var(--alert-mark)' };
  el.style.setProperty('--tone', tones[n.tone]);
  region.appendChild(el);
  el.querySelector('.toast-close').addEventListener('click', () => close(n, true));
  el.addEventListener('pointerenter', () => pause(n));
  el.addEventListener('pointerleave', () => resume(n));
  el.addEventListener('focusin', () => pause(n));
  el.addEventListener('focusout', (e) => { if (!(e.relatedTarget instanceof Node && el.contains(e.relatedTarget))) resume(n); });
  if (life > 0) {
    n.left = life;
    el.style.setProperty('--life', `${life}ms`);
    resume(n);
  } else {
    el.classList.add('sticky');
  }
}

function renderActions(n) {
  const box = n.el?.querySelector('.sh-note-actions');
  if (!box) return;
  // One row: the actions that lead somewhere keep their words; « Copier pour le support » and « Ouvrir le journal » are
  // compact icon buttons at the end of the row (their names stay for the screen reader and in the tooltip).
  const buttons = [];
  if (n.route) buttons.push({ id: 'route', label: `Aller à ${n.routeLabel}`, icon: 'chevronRight', tip: `Ouvre ${n.routeLabel}. Rien n’est autorisé ni lancé par ce clic.` });
  for (const [i, a] of n.actions.entries()) buttons.push({ id: `custom-${i}`, label: a.label, icon: a.icon });
  if (n.folder) buttons.push({ id: 'folder', label: n.folderLabel, icon: 'folder', tip: 'Ouvre l’Explorateur sur le dossier des exports.' });
  if (n.detail) buttons.push({ id: 'detail', label: 'Voir le détail', icon: 'eye', tip: 'Affiche ou masque le détail de ce message.' });
  if (n.tone === 'warn' || n.tone === 'alert') {
    buttons.push({ id: 'support', label: 'Copier pour le support', icon: 'copy', tip: 'Copier pour le support : code, heure, message et détail, secrets connus masqués.', compact: true });
    buttons.push({ id: 'journal', label: 'Ouvrir le journal', icon: 'activity', tip: 'Ouvrir le journal des notifications de la session.', compact: true });
  }
  box.hidden = !buttons.length;
  box.innerHTML = buttons.map((b) => (b.compact
    ? `<button class="btn xs ghost icon sh-note-mini" type="button" data-act="${b.id}" aria-label="${esc(b.label)}" data-tip="${esc(b.tip)}">${icon(b.icon)}</button>`
    : `<button class="btn xs subtle" type="button" data-act="${b.id}"${b.tip ? ` data-tip="${esc(b.tip)}"` : ''}>${b.icon ? icon(b.icon) : ''}<span>${esc(b.label)}</span></button>`)).join('');
  box.onclick = (e) => {
    const b = e.target instanceof Element ? e.target.closest('button[data-act]') : null;
    if (b) runAction(n, b.dataset.act, b);
  };
}

function runAction(n, act, button) {
  if (act === 'route') {
    if (followRoute(n.route)) close(n, true);
  } else if (act === 'folder') {
    n.folder?.();
  } else if (act === 'detail') {
    const pre = n.el.querySelector('.sh-note-detail');
    pre.textContent = n.detail;
    pre.hidden = !pre.hidden;
    const label = button.querySelector('span');
    if (label) label.textContent = pre.hidden ? 'Voir le détail' : 'Masquer le détail';
    button.setAttribute('aria-expanded', String(!pre.hidden));
    // A detail being read keeps its banner open.
    n.pinned = true;
    pause(n);
  } else if (act === 'support') {
    copyText(supportText(n)).then((ok) => announce(ok ? `Incident ${n.code || 'sans code'} copié pour le support.` : 'Copie impossible.'));
  } else if (act === 'journal') {
    openCentre?.('notifications');
  } else if (act.startsWith('custom-')) {
    n.actions[Number(act.slice(7))]?.run?.();
  }
}

function refreshOccurrence(n, plan, o) {
  const el = n.el;
  if (!el) return;
  const counter = el.querySelector('.sh-note-count');
  counter.textContent = COUNTER_WORDS[n.tone] ? `${COUNTER_WORDS[n.tone]} ×${n.count}` : `mis à jour à ${new Date(n.at).toLocaleTimeString('fr-FR')}`;
  counter.hidden = false;
  el.classList.remove('bump');
  void el.offsetWidth;
  el.classList.add('bump');
  if (o.detail && !el.querySelector('[data-act="detail"]')) renderActions(n);
  if (plan.autoClose <= 0) { n.pinned = true; pause(n); return; }
  if (!n.pinned && !el.matches(':hover')) {
    clearTimeout(n.timer);
    n.timer = 0;
    n.left = plan.autoClose;
    resume(n);
  }
}

function pause(n) {
  if (!n.timer) return;
  clearTimeout(n.timer);
  n.timer = 0;
  n.left -= performance.now() - n.started;
  n.el?.classList.add('paused');
}

function resume(n) {
  if (n.timer || n.pinned || n.closed || !n.left || !n.el) return;
  if (n.el.matches(':hover') || n.el.contains(document.activeElement)) return;
  n.started = performance.now();
  n.el.classList.remove('paused');
  n.timer = setTimeout(() => close(n, false), Math.max(800, n.left));
}

/** Closes a banner; its text stays in the journal of the session. */
export function close(n, byOperator) {
  if (!n?.el || n.closed) return;
  n.closed = true;
  if (byOperator) n.read = true;
  clearTimeout(n.timer);
  const el = n.el;
  n.el = null;
  if (el.contains(document.activeElement)) document.getElementById('main')?.focus({ preventScroll: true });
  if (motionReduced()) { el.remove(); emit('notes', journal); return; }
  el.classList.add('leaving');
  el.addEventListener('animationend', () => el.remove(), { once: true });
  setTimeout(() => el.remove(), 800);
  emit('notes', journal);
}

/** Banner whose destination is a button (Domenia 1 Show-DomeniaRouteNotice, TRV-174). */
export function routeNotice(text, routeCode, tone = 'warn') {
  return notify(text, { tone, route: routeCode });
}

/**
 * Example banners of the shell (« Essayer les bannières », « ?coque=exemples » for the guides and captures): fixed texts,
 * no real data, nothing read nor written.
 */
export function exampleNote(tone) {
  if (tone === 'info') return notify(`Exemple d’information : ce message se ferme seul après 5 secondes, sauf sous le pointeur.`, { tone: 'info' });
  if (tone === 'ok') return notify(`Exemple de réussite : 12 lignes exportées dans Domenia-OU-Postes-exemple.csv.`, { tone: 'ok' });
  if (tone === 'warn') return notify(`Exemple d’avertissement : une écriture précédente reste à vérifier sur cet objet ; relisez son reçu avant d’en préparer une autre.`, { tone: 'warn', route: 'operations-verifier' });
  if (tone === 'alert') {
    return notify(`Exemple d’erreur INC-4F2A : la lecture n’a pas abouti.\n\nRien n’a été modifié ; réessayez ou copiez le message pour le support.`, {
      tone: 'alert', detail: `Détail technique d’exemple (aucune donnée réelle) : code 0x8007203A, contrôleur DC01.example.local, durée 8 s.`,
    });
  }
  return null;
}
