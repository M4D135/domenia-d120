// Safeguards of the interface: requests waiting for an answer, shown in a panel at the top of the content without any window
// nor modal loop (TRV-058; Domenia 1 Request-DomeniaInlineConfirmation), which hold only the writes of their scope (TRV-059;
// Domenia 1 Test-DomeniaInlineRequestBlocks), and the global handler of interface faults (TRV-064; Domenia 1
// Register-DomeniaDispatcherExceptionHandler, Write-DomeniaSwallowed): every fault is counted, reported to the technical
// journal (kind, screen, place and count only, never a message), and the operator is told once a minute at most per screen.
import { icon } from '../icons.js';
import { esc, announce } from '../ui.js';
import { state, quietCall, sessionMark } from './store.js';
import { notify } from './notify.js';
import { confirmDialog, confirmWrite } from '../kit/index.js';

const NBSP = ' ';

// ---------- Requests waiting for an answer ----------

const requests = new Set();
let seq = 0;

/**
 * Registers a request waiting for the operator (a confirmation, a choice). While it waits, navigation, reads, selection and
 * other targets stay available; only the writes and edits of its scope wait. A request without a scope holds every write
 * (fail closed). Returns `end()` to call once it is answered or withdrawn.
 * @param {{ scope?: string, label?: string }} [o]
 */
export function beginRequest({ scope = '', label = '' } = {}) {
  const r = { id: ++seq, scope: String(scope ?? ''), label: String(label ?? ''), at: Date.now() };
  requests.add(r);
  return { id: r.id, end: () => requests.delete(r) };
}

/** True when a waiting request holds this action (« write » or « edit ») on this scope. */
export function requestBlocks(action, scope = '') {
  if (action !== 'write' && action !== 'edit') return false;
  for (const r of requests) {
    if (!r.scope) return true;
    if (r.scope.toLowerCase() === String(scope ?? '').toLowerCase()) return true;
  }
  return false;
}

export function pendingRequests() { return [...requests]; }

let expertProbe = () => false;

/** app.js hands the test of the expert view of the screen shown (technical details reserved to Expert). */
export function setExpertProbe(fn) { expertProbe = typeof fn === 'function' ? fn : () => false; }

/** The request shown in the page: { settle(answer), panel } or null. */
let current = null;

/**
 * Withdraws the request shown, without running anything (a newer request, a change of session, the window closing).
 * @param {string} [why] sentence announced and shown in the journal
 */
export function withdrawRequest(why = '') {
  if (!current) return false;
  const c = current;
  current = null;
  c.settle(null, why);
  return true;
}

/** Pure decision on a typed confirmation (Domenia 1 Update-DomeniaInlineTypedState): case sensitive, exact. */
export function typedState(typed, target) {
  const value = String(typed ?? '');
  const expected = String(target ?? '');
  if (!expected) return { matched: true, invalid: false };
  return { matched: value === expected, invalid: value !== '' && !expected.startsWith(value) };
}

function host() {
  return document.querySelector('.shell .sh-request-host');
}

/**
 * Request with one continuation, shown in a panel at the top of the content (TRV-058): title, message (2 000 characters at
 * most), changes before and after, folded technical details (reserved to the expert view with `detailsExpert`), exact typed
 * name when the plan asks for it (case sensitive, paste refused), optional third answer, danger or normal style, optional
 * impact (« 3 objets »). No window, no modal loop: the page stays usable, only the writes of its scope wait (TRV-059). The
 * safe answer has the focus, Échap cancels, Entrée never confirms a request not read (the confirmation is never focused
 * first). A newer request withdraws the previous one; a request answered after the session changed expires without running
 * anything. The continuation runs once at most. Without the shell (start-up failure), the dialog of the kit is the fallback.
 * @param {{ scope?: string, scopeLabel?: string, title: string, message: string, danger?: boolean, confirmLabel?: string,
 *   cancelLabel?: string, impact?: string, write?: { target: string, targetKind?: string, targetDetail?: string, typed?: boolean,
 *   badge?: string }, changes?: Array<{label: string, before?: string, after?: string}>, details?: string,
 *   detailsExpert?: boolean, alternate?: { label: string }, onConfirm?: () => unknown, onAlternate?: () => unknown }} o
 * @returns {Promise<'confirm'|'alternate'|null>}
 */
export async function ask(o) {
  const message = String(o.message ?? '').slice(0, 2000);
  const mark = sessionMark();
  const box = host();
  let answer = null;
  if (!box) {
    const r = beginRequest({ scope: o.scope, label: o.title });
    try {
      if (o.write || o.changes?.length || o.details || o.alternate) {
        answer = await confirmWrite({
          title: o.title, message, target: o.write?.target ?? '', targetKind: o.write?.targetKind, targetDetail: o.write?.targetDetail,
          typed: o.write ? o.write.typed !== false : false, badge: o.write?.badge, changes: o.changes, details: o.details,
          confirmLabel: o.confirmLabel, alternate: o.alternate,
        });
      } else {
        answer = (await confirmDialog({ title: o.title, message, danger: !!o.danger, confirmLabel: o.confirmLabel, cancelLabel: o.cancelLabel })) ? 'confirm' : null;
      }
    } finally {
      r.end();
    }
  } else {
    if (current) {
      const previous = current.title;
      withdrawRequest(`Demande précédente retirée${NBSP}: ${previous}. Rien n’a été exécuté.`);
    }
    answer = await showInline(box, { ...o, message });
  }
  if (answer && sessionMark() !== mark) {
    notify(`Demande expirée${NBSP}: la session a changé pendant l’attente${NBSP}; rien n’a été exécuté.`, { tone: 'warn', key: 'request-expired' });
    return null;
  }
  if (answer === 'confirm') await o.onConfirm?.();
  if (answer === 'alternate') await o.onAlternate?.();
  return answer;
}

function showInline(box, o) {
  return new Promise((resolve) => {
    const r = beginRequest({ scope: o.scope, label: o.title });
    const id = `sh-req-${r.id}`;
    const typed = o.write ? o.write.typed !== false : false;
    const target = o.write?.target ?? '';
    const showDetails = !!o.details && (!o.detailsExpert || expertProbe());
    const changes = (o.changes ?? []).slice(0, 20).map((c) => `<li><span class="sh-request-change-l">${esc(c.label)}</span>`
      + `${c.before !== undefined ? `<span class="sh-request-before">${esc(c.before || '—')}</span>` : ''}`
      + `${c.before !== undefined && c.after !== undefined ? `<span class="sh-request-arrow" aria-hidden="true">→</span><span class="visually-hidden"> devient </span>` : ''}`
      + `${c.after !== undefined ? `<span class="sh-request-after">${esc(c.after || '—')}</span>` : ''}</li>`).join('');
    const scopeLabel = String(o.scopeLabel ?? target ?? '').slice(0, 120);
    const panel = document.createElement('section');
    panel.className = 'sh-request';
    panel.dataset.tone = o.danger || o.write ? 'danger' : 'normal';
    panel.setAttribute('role', 'region');
    panel.setAttribute('aria-labelledby', `${id}-t`);
    panel.setAttribute('aria-describedby', `${id}-m`);
    panel.innerHTML = `<span class="sh-request-icon" aria-hidden="true">${icon(o.danger || o.write ? 'shield' : 'info')}</span>
      <div class="sh-request-body">
        <div class="sh-request-head">
          <span class="sh-request-badge">${icon('clock')}Demande en attente${scopeLabel ? ` · ${esc(scopeLabel)}` : ''}</span>
          ${o.impact ? `<span class="sh-request-impact">${esc(o.impact)}</span>` : ''}
        </div>
        <h2 id="${id}-t">${esc(o.title)}</h2>
        <p class="sh-request-text" id="${id}-m">${esc(o.message)}</p>
        ${o.write ? `<div class="sh-request-target"><span class="sh-request-kind">${esc(o.write.targetKind ?? 'Cible')}</span><b class="mono">${esc(target)}</b>${o.write.targetDetail ? `<span class="mono faint">${esc(o.write.targetDetail)}</span>` : ''}</div>` : ''}
        ${changes ? `<ul class="sh-request-changes" aria-label="Changements prévus">${changes}</ul>` : ''}
        ${showDetails ? `<div class="sh-request-details"><button class="btn ghost xs" type="button" data-req="details" aria-expanded="false" aria-controls="${id}-d">${icon('chevronRight')}Détails techniques</button><pre class="sh-request-pre mono" id="${id}-d" hidden>${esc(o.details)}</pre></div>` : ''}
        ${typed ? `<div class="sh-request-typed"><label for="${id}-in">Pour confirmer, saisissez «${NBSP}${esc(target)}${NBSP}»</label>
          <div class="sh-request-inrow"><input class="input mono" id="${id}-in" type="text" autocomplete="off" spellcheck="false" aria-describedby="${id}-h" data-req="typed"><span class="sh-request-ok" aria-hidden="true">${icon('check')}</span></div>
          <p class="sh-request-hint" id="${id}-h">Respectez les majuscules. Le collage est désactivé pour cette saisie.</p></div>` : ''}
        <p class="sh-request-note">${icon('info')}<span>La page reste utilisable${NBSP}: navigation, lectures et autres cibles sont libres${NBSP}; seules les écritures de ${scopeLabel ? 'cette cible' : 'la session'} attendent votre réponse.</span></p>
      </div>
      <div class="sh-request-actions">
        <button class="btn subtle" type="button" data-req="cancel">${esc(o.cancelLabel ?? 'Annuler')}</button>
        ${o.alternate ? `<button class="btn" type="button" data-req="alternate">${esc(o.alternate.label)}</button>` : ''}
        <button class="btn ${o.danger || o.write ? 'danger' : 'primary'}" type="button" data-req="confirm"${typed ? ' disabled' : ''}>${icon(o.write ? 'lock' : 'check')}${esc(o.confirmLabel ?? (o.write ? 'Confirmer l’écriture' : 'Confirmer'))}</button>
      </div>`;
    const restore = document.activeElement instanceof HTMLElement && !box.contains(document.activeElement) ? document.activeElement : null;
    let done = false;
    const settle = (answer, why = '') => {
      if (done) return;
      done = true;
      r.end();
      if (current?.panel === panel) current = null;
      document.removeEventListener('keydown', onDocKey, true);
      panel.classList.add('leaving');
      const remove = () => { panel.remove(); box.closest('.shell')?.classList.toggle('has-request', !!box.querySelector('.sh-request:not(.leaving)')); };
      panel.addEventListener('animationend', remove, { once: true });
      setTimeout(remove, 500);
      if (panel.contains(document.activeElement)) (restore?.isConnected ? restore : document.getElementById('main'))?.focus({ preventScroll: true });
      if (why) { announce(why); notify(why, { tone: 'info', key: `request-withdrawn|${o.title}` }); }
      resolve(answer);
    };
    const input = panel.querySelector('[data-req="typed"]');
    const confirm = panel.querySelector('[data-req="confirm"]');
    if (input) {
      const row = panel.querySelector('.sh-request-typed');
      const hint = panel.querySelector('.sh-request-hint');
      input.addEventListener('input', () => {
        const st = typedState(input.value, target);
        row.classList.toggle('ok', st.matched);
        input.setAttribute('aria-invalid', String(st.invalid));
        confirm.disabled = !st.matched;
      });
      const refuse = (e) => {
        e.preventDefault();
        hint.textContent = `Le collage est désactivé${NBSP}: saisissez le nom lettre par lettre.`;
        hint.classList.add('warn');
        announce('Le collage est désactivé : saisissez le nom.');
      };
      input.addEventListener('paste', refuse);
      input.addEventListener('drop', refuse);
      input.addEventListener('keydown', (e) => {
        if (e.key !== 'Enter') return;
        e.preventDefault();
        if (typedState(input.value, target).matched) settle('confirm');
      });
    }
    panel.addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-req]') : null;
      if (!b || b.disabled) return;
      const act = b.dataset.req;
      if (act === 'cancel') settle(null);
      else if (act === 'alternate') settle('alternate');
      else if (act === 'confirm') settle('confirm');
      else if (act === 'details') {
        const pre = panel.querySelector('.sh-request-pre');
        const open = b.getAttribute('aria-expanded') !== 'true';
        b.setAttribute('aria-expanded', String(open));
        pre.hidden = !open;
      }
    });
    panel.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && !e.defaultPrevented) { e.preventDefault(); e.stopPropagation(); settle(null); }
    });
    // Échap from the page itself (focus on the body or the content area, no dialog open) also answers « Annuler ».
    const onDocKey = (e) => {
      if (e.key !== 'Escape' || e.defaultPrevented) return;
      const a = document.activeElement;
      if (a === document.body || a?.id === 'main') { e.preventDefault(); settle(null); }
    };
    document.addEventListener('keydown', onDocKey, true);
    box.appendChild(panel);
    box.closest('.shell')?.classList.add('has-request');
    current = { panel, title: o.title, settle };
    // The safe answer has the focus; the panel is announced by its title and message.
    requestAnimationFrame(() => panel.querySelector('[data-req="cancel"]')?.focus({ preventScroll: true }));
    announce(`Demande en attente${NBSP}: ${o.title}.`, { assertive: true });
  });
}

// ---------- Faults of the interface ----------

const NOTICE_INTERVAL_MS = 60_000;
const REPORT_DELAY_MS = 1500;
const lastNotice = new Map();
const pending = new Map(); // `${kind}|${route}|${place}` → count
let reportTimer = 0;
let total = 0;
let nestedTotal = 0;
let swallowedTotal = 0;
let inHandler = false;
let nestedQueue = 0;

export function faultCount() { return total; }
export function swallowedCount() { return swallowedTotal; }

function routeName() {
  const id = state.page?.id;
  return id && /^[a-z][a-z0-9-]{0,29}$/.test(id) ? id : 'demarrage';
}

function queueReport(kind, place = '') {
  const key = `${kind}|${routeName()}|${place}`;
  pending.set(key, (pending.get(key) ?? 0) + 1);
  clearTimeout(reportTimer);
  reportTimer = setTimeout(flush, REPORT_DELAY_MS);
}

function record(kind) {
  if (inHandler) {
    // A fault raised while another one is being handled is never lost: it is told once the first one is done.
    nestedQueue += 1;
    return;
  }
  inHandler = true;
  try {
    total += 1;
    queueReport(kind);
    const route = routeName();
    const now = Date.now();
    if (now - (lastNotice.get(route) ?? 0) >= NOTICE_INTERVAL_MS) {
      lastNotice.set(route, now);
      notify(`Erreur interne de l’interface sur cet écran${NBSP}: l’action en cours n’a peut-être pas abouti. Le détail technique est dans le journal${NBSP}; rechargez l’écran (F5) si l’affichage paraît incomplet.`, { tone: 'warn', key: `fault|${route}` });
    }
  } catch (err) {
    console.error(err);
  } finally {
    inHandler = false;
  }
  if (nestedQueue) setTimeout(tellNested, 0);
}

function tellNested() {
  const n = nestedQueue;
  if (!n) return;
  nestedQueue = 0;
  total += n;
  nestedTotal += n;
  for (let i = 0; i < Math.min(n, 100); i += 1) queueReport('nested');
  notify(`${n > 1 ? `${n} autres erreurs internes sont survenues` : 'Une autre erreur interne est survenue'} pendant le traitement de la précédente${NBSP}: elles sont inscrites au journal technique.`, { tone: 'warn', key: `fault-nested|${routeName()}` });
}

export function nestedCount() { return nestedTotal; }

const swallowedSeen = new Map(); // place → last report time

/**
 * Traces an error swallowed on purpose (Domenia 1 Write-DomeniaSwallowed): never shown, counted, and reported to the
 * technical journal once a minute at most per place of the code. Only the place is sent, never the message.
 * @param {string} place identifier of the code (« board.copy », « help-panel.guide »)
 */
export function swallowed(place, err) {
  const where = /^[A-Za-z][A-Za-z0-9._-]{0,63}$/.test(String(place ?? '')) ? String(place) : 'inconnu';
  swallowedTotal += 1;
  if (err) console.debug('Erreur ignorée volontairement', where, err);
  const now = Date.now();
  if (now - (swallowedSeen.get(where) ?? 0) < NOTICE_INTERVAL_MS) return;
  swallowedSeen.set(where, now);
  queueReport('swallowed', where);
}

function flush() {
  for (const [key, count] of pending) {
    const [kind, route, place] = key.split('|');
    quietCall('shell.fault', { kind, route, count: Math.min(count, 10_000), place: place || null }).catch((err) => console.warn('Erreur non signalée au journal', err));
  }
  pending.clear();
}

/** Installs the global handlers (after the shell is built; boot.js covers the start). */
export function installFaultHandlers() {
  window.addEventListener('error', (e) => {
    // Resource loading errors (capture phase of boot.js) and errors without a script are not faults of the interface.
    if (!(e instanceof ErrorEvent) || !e.error) return;
    record('error');
  });
  window.addEventListener('unhandledrejection', (e) => {
    const reason = e.reason;
    // A refusal of the bridge is a French message already shown by its screen: not a fault of the interface.
    if (reason && typeof reason === 'object' && reason.code) return;
    record('rejection');
  });
}
