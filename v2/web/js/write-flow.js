// Write circuit of the page (docs/WRITES.md § 7): plan, plan panel, confirmation of the kit, execution, receipt.
// Every screen that writes calls runWrite(ctx, { plan, args }) and nothing else: this module never writes by itself (the
// engine runs the plan once, with its receipt and its re-read), never retries anything, and says at each step what was
// sent. Styles: css/write-flow.css (loaded by index.html, the panel can open from any screen).
import { onEvent } from './bridge.js';
import { openDrawer, confirmWrite, pill, glyph, setVars, NBSP } from './kit/index.js';
import { esc, errorText, toast, announce, formatDateTime, motionReduced } from './ui.js';

/** Stages of write.execute, in order, with the labels of the engine (WriteCircuit.StageLabel). */
const STAGES = [
  { id: 'checking', label: 'Relecture de l’objet avant l’envoi', icon: 'eye' },
  { id: 'sending', label: 'Reçu enregistré, envoi du changement', icon: 'edit' },
  { id: 'verifying', label: 'Relecture après l’écriture', icon: 'shield' },
];

const KIND_ICONS = { user: 'user', computer: 'monitor', group: 'group', ou: 'ou', database: 'database' };
const TONE_ICONS = { ok: 'check', warn: 'eye', alert: 'alert', info: 'info', off: 'info' };

/** Where the plan writes: the fictitious directory (simulation), the local base of this workstation, or the real directory. */
function targetPill(plan) {
  if (plan.simulated) return pill('accent', 'Simulation · aucun effet réel', { icon: 'sparkles', size: 'sm' });
  // Plans of the local base (target « database ») never touch Active Directory.
  if (plan.target?.kind === 'database') return pill('info', 'Base locale · ce poste', { icon: 'database', size: 'sm' });
  return pill('alert', 'Annuaire réel', { icon: 'zap', size: 'sm' });
}

/** Refusals that happen before anything is sent: a new plan (an explicit gesture) is the way forward. */
const REPLAN = new Set(['write.stale', 'write.tokenExpired', 'write.planUnknown', 'write.tokenUsed', 'write.planChanged', 'write.tokenInvalid', 'write.confirmationMismatch']);
/** Refusals of the engine that mean nothing was sent either (exported: the collective actions of the screens use it too). */
export const NOTHING_SENT = new Set([...REPLAN, 'write.targetPending', 'write.receiptsPending', 'write.nothingToDo', 'write.targetUnknown', 'receipt.unavailable',
  'simulation.readOnly', 'write.unavailable', 'source.unavailable', 'arguments.invalid', 'operation.unknown', 'message.size', 'message.json']);

const ADVICE = {
  'write.targetPending': 'Ouvrez Opérations et relisez le reçu en attente\u00A0: la cible sera de nouveau libre dès que la relecture aura tranché.',
  'write.receiptsPending': 'Ouvrez Opérations et relisez ou revoyez le reçu en attente\u00A0: tant qu’une opération reste à vérifier, aucune nouvelle écriture ne part (comme dans Domenia\u00A01).',
  'receipt.unavailable': 'Le reçu doit être enregistré avant tout envoi. Vérifiez l’espace disque et les droits du dossier de données, puis préparez de nouveau l’écriture.',
  'write.nothingToDo': 'L’objet est déjà dans l’état demandé\u00A0: aucune écriture n’est nécessaire.',
  'write.targetUnknown': 'Relisez l’objet depuis l’écran d’origine\u00A0: il a peut-être été supprimé ou déplacé.',
  'source.unavailable': 'Les écritures réelles arrivent avec la lecture de l’annuaire (vague 3). Essayez le circuit en simulation.',
};

/** Address of a receipt in Opérations (the toast link and the receipt panel use it). */
export function receiptHref(id) {
  return `#/operations?recu=${encodeURIComponent(id)}`;
}

/**
 * Runs the whole circuit for one write: asks the plan, shows it, confirms it with the kit (typed name when the plan asks
 * for it), executes it once, shows the receipt and toasts it. Resolves with the receipt (write.execute), or null when the
 * operator cancels or the engine refuses before sending. Never resent automatically.
 * @param {{ call: (op: string, args?: object) => Promise<any> }} ctx  Context of the screen (ctx.call of the router).
 * @param {{ plan: string, args: object, subtitle?: string, onDone?: (receipt: any) => void, onClosed?: () => void }} options
 *   plan: the « <screen>.<verb>.plan » operation (a read), args: its arguments; onDone: called once with the receipt
 *   (the screen reads its data again); onClosed: called once when the panel closes (a screen that must change its address
 *   after the write waits for it, or the hashchange would close the receipt before it is read).
 * @returns {Promise<any|null>}
 */
export function runWrite(ctx, options) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (!settled) { settled = true; resolve(value); }
    };
    const flow = new WriteFlow(ctx, options, finish);
    flow.start();
  });
}

/**
 * Opens the receipt panel of one receipt (Opérations, the toast link, the reference page #/ecritures): details, plan and
 * « Relire l’objet » (write.receipts.verify: a read, the write is never sent again).
 * @param {{ call: Function }} ctx
 * @param {string} id
 * @param {{ onChange?: (receipt: any) => void }} [o]
 */
export function openReceipt(ctx, id, o = {}) {
  const panel = openDrawer({
    title: 'Reçu d’écriture', subtitle: 'Lecture du reçu…', icon: 'shield', key: 'write.receipt', width: 560, minWidth: 420, maxWidth: 900,
    body: skeletonMarkup(),
  });
  whenOpen(panel).then((opened) => {
    if (!opened) return;
    const foot = footController(panel);
    panel.setBusy(true);
    foot.set([{ id: 'close', label: 'Fermer', safe: true, run: () => panel.close() }]);
    ctx.call('write.receipts.get', { id }).then((receipt) => {
      if (panel.el?.isConnected) bindReceipt(ctx, panel, foot, receipt, o.onChange);
    }).catch((err) => {
      console.error(err);
      if (!panel.el?.isConnected) return;
      panel.setBusy(false);
      panel.setTitle('Reçu d’écriture', 'Lecture impossible');
      panel.body.innerHTML = failureMarkup(err, { title: 'Reçu illisible', sent: false, verb: true });
    });
  });
  return panel;
}

/**
 * Shows a state of the circuit from data already in hand, without any call (the reference page #/ecritures and the
 * captures): 'run' shows the execution at its first stage, 'receipt' a receipt. Nothing is read, nothing is written.
 * @param {'run'|'receipt'} state
 * @param {any} data  A plan (run) or a receipt (receipt), with the shapes of the contract.
 */
export function previewWrite(state, data) {
  const plan = state === 'run' ? data : data.plan;
  const panel = openDrawer({
    title: plan.title, subtitle: `${plan.target.kindLabel} · ${plan.target.name}`, icon: 'shield', key: 'write.plan', width: 580, minWidth: 440, maxWidth: 960,
    body: skeletonMarkup(),
  });
  whenOpen(panel).then((opened) => {
    if (!opened) return;
    const foot = footController(panel);
    if (state === 'run') {
      panel.setBusy(true);
      panel.body.innerHTML = runMarkup(plan);
      markSteps(panel.body.querySelector('.wf-steps'), 1);
      foot.set([]);
    } else {
      showReceipt(panel, data);
      foot.set([{ id: 'close', label: 'Fermer', safe: true, run: () => panel.close() }]);
    }
  });
  return panel;
}

/**
 * Resolves true once a drawer is really open (a modal drawer already open makes the request wait, docs/KIT.md § 4.3),
 * false when it is withdrawn first (screen left, closed while waiting).
 */
function whenOpen(panel) {
  if (panel.body) return Promise.resolve(true);
  return new Promise((resolve) => {
    let done = false;
    panel.closed.then(() => { if (!done) { done = true; resolve(false); } });
    const poll = () => {
      if (done) return;
      if (panel.body) { done = true; resolve(true); return; }
      setTimeout(poll, 120);
    };
    poll();
  });
}

/** Shows a receipt in a drawer with its buttons; « Relire l’objet » re-reads in place (a read, never a new write). */
function bindReceipt(ctx, panel, foot, receipt, onChange) {
  showReceipt(panel, receipt);
  const reread = () => {
    panel.setBusy(true);
    foot.set([{ id: 'close', label: 'Fermer', safe: true, run: () => panel.close() }]);
    announce('Relecture de l’objet…');
    ctx.call('write.receipts.verify', { id: receipt.id }).then((next) => {
      toast(`Relecture${NBSP}: ${next.verificationLabel.toLowerCase()}.`, { tone: next.tone, life: 5200 });
      onChange?.(next);
      if (panel.el?.isConnected) bindReceipt(ctx, panel, foot, next, onChange);
    }).catch((err) => {
      console.error(err);
      toast(`Relecture impossible${NBSP}: ${errorText(err)}`, { tone: 'alert', life: 7000 });
      if (panel.el?.isConnected) bindReceipt(ctx, panel, foot, receipt, onChange);
    });
  };
  foot.set([
    { id: 'close', label: 'Fermer', safe: true, run: () => panel.close() },
    { id: 'reread', label: receipt.pending ? 'Relire l’objet pour trancher' : 'Relire l’objet', icon: 'refresh', primary: receipt.pending, run: reread },
    { id: 'ops', label: 'Voir dans Opérations', icon: 'activity', href: receiptHref(receipt.id) },
  ]);
}

// ---------------------------------------------------------------- the flow of one write

class WriteFlow {
  constructor(ctx, options, finish) {
    this.ctx = ctx;
    this.options = options;
    this.finish = finish;
    this.locked = false;
    this.detached = false;
    this.timer = 0;
    this.stopStages = () => {};
  }

  start() {
    this.panel = openDrawer({
      title: 'Préparation de l’écriture', subtitle: this.options.subtitle ?? 'Relecture de l’objet…', icon: 'shield',
      key: 'write.plan', width: 580, minWidth: 440, maxWidth: 960, body: skeletonMarkup(),
      onClose: () => this.closed(),
    });
    whenOpen(this.panel).then((opened) => {
      if (!opened) return;
      this.foot = footController(this.panel);
      // Échap does not close the panel while the write runs (the write goes to the end; the receipt shows here).
      this.panel.el.addEventListener('keydown', (e) => {
        if (this.locked && e.key === 'Escape') {
          e.preventDefault();
          e.stopPropagation();
          announce('Écriture en cours\u00A0: le panneau reste ouvert jusqu’au reçu.');
        }
      }, true);
      this.plan();
    });
  }

  closed() {
    clearInterval(this.timer);
    this.detached = true;
    this.options.onClosed?.();
    // A write under way still ends with its receipt and its toast; anything else ends with nothing sent.
    if (!this.locked) this.finish(null);
  }

  plan() {
    const { panel } = this;
    panel.setBusy(true);
    panel.setTitle('Préparation de l’écriture', this.options.subtitle ?? 'Relecture de l’objet…');
    panel.body.innerHTML = skeletonMarkup();
    this.foot.set([{ id: 'cancel', label: 'Annuler', safe: true, run: () => panel.close() }]);
    this.ctx.call(this.options.plan, this.options.args).then((planned) => {
      if (this.detached) return;
      this.planned = planned;
      this.showPlan();
    }).catch((err) => {
      console.error(err);
      if (this.detached) return;
      this.fail(err, { sent: false });
    });
  }

  showPlan() {
    const { panel } = this;
    const { plan } = this.planned;
    panel.setBusy(false);
    panel.setTitle(plan.title, `${plan.target.kindLabel} · ${plan.target.name}`);
    panel.body.innerHTML = planMarkup(plan);
    bindMore(panel.body);
    this.foot.set([
      { id: 'cancel', label: 'Annuler', safe: true, run: () => panel.close() },
      { id: 'confirm', label: plan.confirmation.typedNameRequired ? 'Confirmer avec le nom…' : 'Confirmer…', icon: 'edit', danger: true, run: () => this.confirm() },
    ]);
    announce(`${plan.title}${NBSP}: plan prêt, ${plan.changes.length} changement${plan.changes.length > 1 ? 's' : ''}. ${plan.confirmation.reason}`);
    this.countdown(plan);
  }

  /** Live validity of the plan (five minutes): a bar that shrinks, then the plan is said expired and cannot be confirmed. */
  countdown(plan) {
    clearInterval(this.timer);
    const end = Date.parse(plan.expiresAt);
    const total = Math.max(1, end - Date.parse(plan.createdAt));
    const host = this.panel.body.querySelector('.wf-expiry');
    const text = host?.querySelector('b');
    const bar = host?.querySelector('.wf-expiry-bar i');
    const tick = () => {
      const left = end - Date.now();
      if (!host?.isConnected) { clearInterval(this.timer); return; }
      if (left <= 0) {
        clearInterval(this.timer);
        host.classList.add('expired');
        host.querySelector('.wf-expiry-text').textContent = 'Plan expiré\u00A0: relisez l’objet pour préparer une nouvelle écriture.';
        if (bar) setVars(bar, { '--p': '0' });
        this.foot.set([
          { id: 'cancel', label: 'Fermer', safe: true, run: () => this.panel.close() },
          { id: 'replan', label: 'Préparer de nouveau', icon: 'refresh', primary: true, run: () => this.plan() },
        ]);
        announce('Plan expiré\u00A0: préparez de nouveau l’écriture.');
        return;
      }
      if (text) text.textContent = duration(left);
      if (bar) setVars(bar, { '--p': String(Math.max(0, Math.min(1, left / total))) });
      host.classList.toggle('late', left < 60_000);
    };
    tick();
    this.timer = setInterval(tick, 1000);
  }

  async confirm() {
    const { plan, token } = this.planned;
    let typedName = null;
    const answer = await confirmWrite({
      title: plan.title,
      message: plan.summary,
      target: plan.confirmation.typedNameRequired ? plan.confirmation.typedName : plan.target.name,
      targetKind: plan.target.kindLabel,
      targetDetail: plan.target.dn,
      changes: plan.changes.map((c) => ({ label: c.label, before: c.before ?? '', after: c.after ?? '' })),
      details: plan.details,
      typed: plan.confirmation.typedNameRequired,
      onTyped: (text) => { typedName = text; },
      badge: plan.simulated ? 'Écriture simulée · annuaire fictif' : 'Écriture dans l’annuaire',
      confirmLabel: plan.simulated ? 'Confirmer (simulation)' : 'Confirmer l’écriture',
    });
    if (answer !== 'confirm' || this.detached) return;
    this.execute(plan, token, typedName);
  }

  execute(plan, token, typedName) {
    const { panel } = this;
    clearInterval(this.timer);
    this.locked = true;
    panel.el?.classList.add('wf-locked');
    panel.setBusy(true);
    panel.setTitle(plan.title, `Écriture en cours · ${plan.target.name}`);
    panel.body.innerHTML = runMarkup(plan);
    this.foot.set([]);
    const steps = panel.body.querySelector('.wf-steps');
    let reached = -1;
    const advance = (stage) => {
      const index = STAGES.findIndex((s) => s.id === stage);
      if (index <= reached || !steps?.isConnected) return;
      reached = index;
      markSteps(steps, index);
      announce(STAGES[index].label);
    };
    advance('checking');
    // Events of this write (one write at a time: the engine serializes them, and the panel is modal).
    this.stopStages = onEvent('write.execute:stage', (data) => advance(data?.stage));
    const args = { planId: plan.id, token, typedName };
    this.ctx.call('write.execute', args).then((receipt) => {
      this.stopStages();
      this.locked = false;
      this.done(receipt, steps);
    }).catch((err) => {
      this.stopStages();
      this.locked = false;
      console.error(err);
      if (this.detached) {
        toast(errorText(err, 'Écriture\u00A0: issue inconnue, consultez Opérations.'), { tone: 'alert', life: 8000 });
        this.finish(null);
        return;
      }
      panel.el?.classList.remove('wf-locked');
      this.fail(err, { sent: !NOTHING_SENT.has(err?.code) });
    });
  }

  done(receipt, steps) {
    const { panel } = this;
    toastReceipt(receipt);
    this.options.onDone?.(receipt);
    this.finish(receipt);
    if (this.detached) return;
    panel.el?.classList.remove('wf-locked');
    const show = () => {
      if (panel.el?.isConnected) bindReceipt(this.ctx, panel, this.foot, receipt, this.options.onDone);
    };
    // The steps finish their animation before the receipt replaces them (immediate when motion is reduced).
    if (steps?.isConnected && !motionReduced()) {
      markSteps(steps, STAGES.length);
      setTimeout(show, 520);
    } else {
      show();
    }
  }

  fail(err, { sent }) {
    const { panel } = this;
    panel.setBusy(false);
    const code = err?.code ?? '';
    panel.setTitle(sent ? 'Issue à vérifier' : 'Rien n’a été envoyé', this.planned?.plan?.target?.name ?? this.options.subtitle ?? '');
    panel.body.innerHTML = failureMarkup(err, { title: sent ? 'Issue incertaine' : 'Rien n’a été envoyé', sent });
    const buttons = [{ id: 'close', label: 'Fermer', safe: true, run: () => panel.close() }];
    if (code === 'write.targetPending' || code === 'write.receiptsPending' || sent) {
      buttons.push({ id: 'ops', label: 'Ouvrir Opérations', icon: 'activity', href: code === 'write.receiptsPending' || code === 'write.targetPending' ? '#/operations?onglet=recus&filtre=a-verifier' : '#/operations' });
    }
    if (REPLAN.has(code) || code === 'receipt.unavailable') {
      buttons.push({ id: 'replan', label: 'Préparer de nouveau', icon: 'refresh', primary: true, run: () => this.plan() });
    }
    this.foot.set(buttons);
    announce(`${sent ? 'Issue incertaine' : 'Rien n’a été envoyé'}${NBSP}: ${errorText(err)}`, { assertive: true });
    if (!REPLAN.has(code) && code !== 'receipt.unavailable') this.finish(null);
  }
}

// ---------------------------------------------------------------- shared pieces

/** Footer buttons of a drawer, replaced at each step; one delegated listener. Safe answer at the left. */
function footController(panel) {
  let handlers = new Map();
  panel.foot?.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-wf]') : null;
    if (!b || b.disabled) return;
    handlers.get(b.dataset.wf)?.();
  });
  return {
    set(buttons) {
      handlers = new Map(buttons.filter((b) => b.run).map((b) => [b.id, b.run]));
      if (!panel.foot) return;
      panel.foot.hidden = buttons.length === 0;
      panel.foot.innerHTML = buttons.map((b) => {
        const cls = `btn${b.primary ? ' primary' : ''}${b.danger ? ' danger' : ''}${!b.primary && !b.danger ? ' subtle' : ''}${b.safe ? ' wf-safe' : ''}`;
        const inner = `${b.icon ? glyph(b.icon) : ''}${esc(b.label)}`;
        return b.href
          ? `<a class="${cls}" href="${esc(b.href)}" data-wf-link="${esc(b.id)}">${inner}</a>`
          : `<button class="${cls}" type="button" data-wf="${esc(b.id)}">${inner}</button>`;
      }).join('');
      panel.foot.classList.add('wf-foot');
    },
  };
}

function showReceipt(panel, receipt) {
  panel.setBusy(false);
  panel.setTitle(receipt.title, `${receipt.target.kindLabel} · ${receipt.target.name}`);
  panel.body.innerHTML = receiptMarkup(receipt);
  bindMore(panel.body);
}

function toastReceipt(receipt) {
  const simulated = receipt.simulated ? ` Simulation${NBSP}: aucun effet réel.` : '';
  const text = `${receipt.label} · ${receipt.target.name}${NBSP}: ${receipt.verificationLabel.toLowerCase()}.${simulated}`;
  const el = toast(text, { tone: receipt.tone, life: 8000 });
  const body = el?.querySelector('.toast-body');
  if (body) {
    const a = document.createElement('a');
    a.className = 'toast-link';
    a.href = receiptHref(receipt.id);
    a.textContent = 'Voir le reçu dans Opérations';
    body.append(a);
  }
}

function markSteps(steps, index) {
  steps.querySelectorAll('.wf-step').forEach((li, n) => {
    li.dataset.state = n < index ? 'done' : n === index ? 'active' : 'todo';
    if (n < index) li.setAttribute('aria-label', `${STAGES[n].label}${NBSP}: fait`);
    else li.removeAttribute('aria-label');
  });
}

function bindMore(scope) {
  scope.querySelectorAll('.wf-more').forEach((button) => {
    button.addEventListener('click', () => {
      const pre = scope.querySelector(`#${CSS.escape(button.getAttribute('aria-controls'))}`);
      const open = button.getAttribute('aria-expanded') !== 'true';
      button.setAttribute('aria-expanded', String(open));
      if (pre) pre.hidden = !open;
    });
  });
  for (const el of scope.querySelectorAll('[data-i]')) setVars(el, { '--i': el.dataset.i });
}

/** « 4 min 05 s », « 42 s ». */
function duration(ms) {
  const s = Math.ceil(ms / 1000);
  const m = Math.floor(s / 60);
  const r = s % 60;
  return m > 0 ? `${m}${NBSP}min ${String(r).padStart(2, '0')}${NBSP}s` : `${r}${NBSP}s`;
}

let uidCounter = 0;
const uid = (p) => `${p}${(uidCounter += 1).toString(36)}`;

// ---------------------------------------------------------------- markup (data always through esc())

function skeletonMarkup() {
  return `<div class="wf wf-skeleton" aria-busy="true" aria-label="Lecture en cours">
    <div class="skeleton wf-sk-target"></div><div class="skeleton wf-sk-line"></div><div class="skeleton wf-sk-line short"></div>
    <div class="skeleton wf-sk-table"></div><div class="skeleton wf-sk-line"></div></div>`;
}

function planMarkup(plan) {
  const id = uid('wfp');
  const t = plan.target;
  const rows = plan.changes.map((c, n) => `<div class="wf-diff-row" role="row" data-i="${n}">
      <span class="wf-diff-label" role="cell">${esc(c.label)}<small class="mono">${esc(c.attribute)}</small></span>
      <span class="wf-diff-before" role="cell"><span class="wf-strike">${esc(c.before || '(vide)')}</span></span>
      <span class="wf-diff-arrow" aria-hidden="true">${glyph('chevronRight')}</span>
      <span class="wf-diff-after" role="cell"><span class="wf-after">${esc(c.after || '(vide)')}</span></span>
    </div>`).join('');
  const risks = plan.risks.map((r, n) => `<li class="wf-risk" data-tone="${esc(r.tone)}" data-i="${n}">${glyph(TONE_ICONS[r.tone] ?? 'info')}<span>${esc(r.text)}</span></li>`).join('');
  const confirmation = plan.confirmation.typedNameRequired
    ? pill('warn', 'Saisie du nom exigée', { icon: 'key', size: 'sm' })
    : pill('info', 'Confirmation simple', { icon: 'check', size: 'sm' });
  const reversible = plan.reversibility.reversible
    ? pill('ok', plan.reversibility.label, { icon: 'undo', size: 'sm' })
    : pill('off', plan.reversibility.label, { icon: 'lock', size: 'sm' });
  return `<div class="wf wf-plan">
    <section class="wf-target${plan.simulated ? ' simulated' : ''}">
      <span class="wf-target-icon">${glyph(KIND_ICONS[t.kind] ?? 'object')}</span>
      <div class="wf-target-main">
        <span class="wf-kicker">${esc(t.kindLabel)}</span>
        <b class="wf-target-name">${esc(t.name)}</b>
        <span class="wf-dn mono" data-tip="${esc(t.dn)}">${esc(t.dn)}</span>
      </div>
      <div class="wf-target-pills">${targetPill(plan)}${confirmation}${reversible}</div>
    </section>
    <p class="wf-summary">${esc(plan.summary)}</p>
    <section class="wf-block" aria-labelledby="${id}-c">
      <h3 class="wf-h" id="${id}-c">Changement${plan.changes.length > 1 ? 's' : ''} prévu${plan.changes.length > 1 ? 's' : ''}<span class="wf-count">${plan.changes.length}</span></h3>
      <div class="wf-diff" role="table" aria-labelledby="${id}-c">
        <div class="wf-diff-head" role="row"><span role="columnheader">Élément</span><span role="columnheader">Avant</span><span aria-hidden="true"></span><span role="columnheader">Après</span></div>
        ${rows}
      </div>
    </section>
    ${risks ? `<section class="wf-block" aria-labelledby="${id}-r"><h3 class="wf-h" id="${id}-r">Points à vérifier avant de confirmer</h3><ul class="wf-risks">${risks}</ul></section>` : ''}
    <dl class="wf-facts">
      <div><dt>Confirmation</dt><dd>${esc(plan.confirmation.reason)}</dd></div>
      <div><dt>Retour arrière</dt><dd>${esc(plan.reversibility.detail)}</dd></div>
      <div><dt>Contrôleur</dt><dd class="mono">${esc(plan.controller ?? '—')}</dd></div>
      <div><dt>Opérateur</dt><dd class="mono">${esc(plan.operator)}</dd></div>
    </dl>
    <section class="wf-expiry" aria-live="off">
      <span class="wf-expiry-icon">${glyph('clock')}</span>
      <span class="wf-expiry-text">Plan valable encore <b>5${NBSP}min 00${NBSP}s</b>${NBSP}; au-delà, l’objet sera relu avant une nouvelle écriture.</span>
      <span class="wf-expiry-bar" aria-hidden="true"><i></i></span>
    </section>
    <div class="wf-tech">
      <button class="wf-more" type="button" aria-expanded="false" aria-controls="${id}-d">${glyph('chevronRight')}Détails techniques</button>
      <pre class="wf-pre mono" id="${id}-d" hidden>${esc(plan.details)}</pre>
    </div>
  </div>`;
}

function runMarkup(plan) {
  const steps = STAGES.map((s, n) => `<li class="wf-step" data-stage="${s.id}" data-state="todo" data-i="${n}">
      <span class="wf-step-dot" aria-hidden="true">${glyph('check')}<span class="wf-step-ring"></span></span>
      <span class="wf-step-text">${esc(s.label)}</span></li>`).join('');
  return `<div class="wf wf-run" aria-busy="true">
    <div class="wf-orbit" aria-hidden="true"><span class="wf-core">${glyph('shield')}</span><i></i><i></i><i></i></div>
    <h3 class="wf-run-title">${plan.simulated ? 'Écriture simulée en cours' : 'Écriture en cours'}</h3>
    <p class="wf-run-sub">Le reçu est enregistré avant l’envoi${NBSP}; l’écriture part une seule fois et va jusqu’au bout, puis l’objet est relu.</p>
    <ol class="wf-steps">${steps}</ol>
  </div>`;
}

function receiptMarkup(r) {
  const id = uid('wfr');
  const icon = r.pending ? 'eye' : TONE_ICONS[r.tone] ?? 'info';
  const pills = [
    pill(r.tone, r.verificationLabel, { icon: r.verification === 'verified' ? 'shield' : r.pending ? 'eye' : 'info', size: 'sm' }),
    r.simulated ? pill('accent', 'Simulation · aucun effet réel', { icon: 'sparkles', size: 'sm' }) : '',
    r.pending ? pill('warn', 'Bloque toutes les nouvelles écritures', { icon: 'lock', size: 'sm', pulse: true }) : '',
  ].join('');
  const trail = (r.details ?? []).map((d, n) => `<li class="wf-trail-item" data-i="${n}"><span class="wf-trail-dot" aria-hidden="true"></span>
      <div><b>${esc(d.label)}</b><p>${esc(d.value)}</p></div></li>`).join('');
  const when = (iso) => esc(formatDateTime(iso) ?? '—');
  return `<div class="wf wf-receipt" data-tone="${esc(r.tone)}">
    <div class="wf-medal" data-tone="${esc(r.tone)}" aria-hidden="true">
      <span class="wf-medal-halo"></span><span class="wf-medal-ring"></span>
      <span class="wf-medal-icon">${glyph(icon)}</span>
      <span class="wf-burst"><i></i><i></i><i></i><i></i><i></i><i></i></span>
    </div>
    <h3 class="wf-receipt-title">${esc(r.resultLabel)}</h3>
    <div class="wf-receipt-pills">${pills}</div>
    <p class="wf-summary">${esc(r.summary)}</p>
    ${r.error ? `<p class="wf-error" role="note">${glyph('alert')}<span>${esc(r.error.message)}</span></p>` : ''}
    ${trail ? `<ol class="wf-trail" aria-label="Étapes du reçu">${trail}</ol>` : ''}
    <dl class="wf-facts wf-meta">
      <div><dt>Opération</dt><dd>${esc(r.label)}</dd></div>
      <div><dt>Cible</dt><dd>${esc(r.target.name)}<span class="wf-dn mono">${esc(r.target.dn)}</span></dd></div>
      <div><dt>Contrôleur</dt><dd class="mono">${esc(r.controller ?? '—')}</dd></div>
      <div><dt>Opérateur</dt><dd class="mono">${esc(r.operator)}</dd></div>
      <div><dt>Envoyée le</dt><dd>${when(r.sentAt)}</dd></div>
      <div><dt>Relue le</dt><dd>${when(r.verifiedAt)}</dd></div>
      <div><dt>Reçu</dt><dd class="mono">${esc(r.id)}</dd></div>
      <div><dt>Empreinte du plan</dt><dd class="mono">${esc((r.plan?.fingerprint ?? '').slice(0, 12) || '—')}</dd></div>
    </dl>
    ${r.plan?.details ? `<div class="wf-tech">
      <button class="wf-more" type="button" aria-expanded="false" aria-controls="${id}-d">${glyph('chevronRight')}Plan exécuté</button>
      <pre class="wf-pre mono" id="${id}-d" hidden>${esc(r.plan.details)}</pre></div>` : ''}
  </div>`;
}

function failureMarkup(err, { title, sent, verb = false }) {
  const code = err?.code ?? '';
  const tone = sent ? 'warn' : code === 'write.nothingToDo' ? 'info' : 'alert';
  const message = errorText(err, sent
    ? 'L’écriture a peut-être été envoyée\u00A0: consultez son reçu dans Opérations avant toute nouvelle tentative.'
    : 'Erreur de l’interface\u00A0: rien n’a été envoyé.');
  const advice = sent
    ? 'Rien n’est renvoyé automatiquement. Ouvrez Opérations\u00A0: le reçu dit ce qui est parti et permet de relire l’objet.'
    : ADVICE[code] ?? (REPLAN.has(code) ? 'Préparez de nouveau l’écriture\u00A0: l’objet sera relu et un nouveau plan proposé.' : '');
  return `<div class="wf wf-fail" data-tone="${tone}" role="alert">
    <div class="wf-medal" data-tone="${tone}" aria-hidden="true"><span class="wf-medal-halo"></span><span class="wf-medal-ring"></span>
      <span class="wf-medal-icon">${glyph(sent ? 'eye' : code === 'write.nothingToDo' ? 'info' : 'alert')}</span></div>
    <h3 class="wf-receipt-title">${esc(code === 'write.nothingToDo' ? 'Rien à faire' : title)}</h3>
    <p class="wf-summary">${esc(message)}</p>
    ${advice ? `<p class="wf-advice">${esc(advice)}</p>` : ''}
    ${verb ? '' : `<p class="wf-code mono">${esc(code || 'interface')}</p>`}
  </div>`;
}
