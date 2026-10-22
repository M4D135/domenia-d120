// Comptes screen: collective action on accounts (Domenia 1 TRV-229). Local component of the screen (kit request: a
// « runBatchWrite » of web/js/write-flow.js): the engine computes the exact preview (accounts.batch.preview: targets,
// motivated exclusions, impact, number to type), the operator confirms with the kit (number of accounts typed from two on),
// then each target gets its OWN plan (read again on the controller) and runs once through write.execute, with its receipt
// and its re-read. One after the other; an uncertain outcome stops the rest; nothing is ever replayed. A stop request
// never interrupts the write under way.
import { openDrawer, confirmWrite, glyph, pill, setVars, NBSP } from '../../kit/index.js';
import { esc, errorText, announce, formatNumber, toast } from '../../ui.js';
import { receiptHref } from '../../write-flow.js';
import { plural, isoDay, whenOpen } from './shared.js';

/** Refusals of a plan or of write.execute that mean nothing was sent (same list as write-flow.js). */
const NOTHING_SENT = new Set(['write.stale', 'write.tokenExpired', 'write.planUnknown', 'write.tokenUsed', 'write.planChanged',
  'write.tokenInvalid', 'write.confirmationMismatch', 'write.targetPending', 'write.nothingToDo', 'write.targetUnknown',
  'receipt.unavailable', 'simulation.readOnly', 'write.unavailable', 'source.unavailable', 'arguments.invalid', 'operation.unknown',
  'message.size', 'message.json', 'accounts.protectedAccount']);

const ACTIONS = {
  unlock: { label: 'Déverrouiller', icon: 'lock' },
  enable: { label: 'Activer', icon: 'power' },
  disable: { label: 'Désactiver', icon: 'power' },
  mustChange: { label: 'Imposer un nouveau mot de passe', icon: 'refresh' },
  expiration: { label: 'Fixer l’expiration', icon: 'calendar' },
};

/**
 * Opens the collective action panel for the selected rows.
 * @param {{ call: Function }} ctx
 * @param {{ action: string, rows: any[], onDone?: () => void }} o
 */
export function openBatch(ctx, { action, rows, onDone }) {
  const meta = ACTIONS[action];
  let locked = false;
  let stop = false;
  let preview = null;
  let date = null;
  const body = document.createElement('div');
  body.className = 'cpt-batch';
    body.dataset.page = 'comptes';
  const panel = openDrawer({
    title: `${meta.label} · action par lot`,
    subtitle: plural(rows.length, 'compte sélectionné', 'comptes sélectionnés'),
    icon: 'layers',
    key: 'comptes.batch',
    width: 620,
    minWidth: 460,
    maxWidth: 1000,
    body,
    onClose: () => { if (locked) stop = true; },
  });

  const foot = (buttons) => {
    if (!panel.foot) return;
    panel.foot.hidden = buttons.length === 0;
    panel.foot.innerHTML = buttons.map((b) => (b.href
      ? `<a class="btn${b.primary ? ' primary' : ' subtle'}" href="${esc(b.href)}">${b.icon ? glyph(b.icon) : ''}${esc(b.label)}</a>`
      : `<button class="btn${b.primary ? ' primary' : ''}${b.danger ? ' danger' : ''}${!b.primary && !b.danger ? ' subtle' : ''}" type="button" data-b="${esc(b.id)}"${b.disabled ? ' disabled' : ''}>${b.icon ? glyph(b.icon) : ''}${esc(b.label)}</button>`)).join('');
    panel.foot.onclick = (e) => {
      const btn = e.target.closest('[data-b]');
      if (btn && !btn.disabled) buttons.find((b) => b.id === btn.dataset.b)?.run?.();
    };
  };

  const start = async () => {
    if (!(await whenOpen(panel))) return;
    // Échap does not close the panel while the writes run (each write goes to its end; the summary shows here).
    panel.el.addEventListener('keydown', (e) => {
      if (locked && e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); announce('Écritures en cours : le panneau reste ouvert jusqu’au bilan.'); }
    }, true);
    if (action === 'expiration') chooseDate(); else loadPreview();
  };

  function chooseDate() {
    const now = new Date();
    const plus = (days) => { const x = new Date(now); x.setDate(x.getDate() + days); return isoDay(x); };
    body.innerHTML = `<div class="cpt-batch-step"><span class="cpt-batch-num">1</span><div>
        <h3>Date d’expiration</h3><p>Tous les comptes retenus expireront à 0${NBSP}h ce jour-là (heure locale), ou n’expireront plus.</p>
        <div class="k-field"><label for="cpt-batch-date">Expire le</label><input class="input" id="cpt-batch-date" type="date" min="${isoDay(now)}" value="${plus(30)}"></div>
        <label class="k-check-row"><input class="k-checkbox" type="checkbox" data-never><span>Supprimer l’expiration (n’expire plus)</span></label>
      </div></div>`;
    const input = body.querySelector('#cpt-batch-date');
    const never = body.querySelector('[data-never]');
    never.addEventListener('change', () => { input.disabled = never.checked; });
    foot([
      { id: 'cancel', label: 'Annuler', run: () => panel.close() },
      { id: 'next', label: 'Voir l’aperçu exact', icon: 'eye', primary: true, run: () => {
        if (!never.checked && !/^\d{4}-\d{2}-\d{2}$/.test(input.value)) { input.focus(); return; }
        date = never.checked ? null : input.value;
        loadPreview();
      } },
    ]);
  }

  async function loadPreview() {
    panel.setBusy(true);
    body.innerHTML = `<div class="cpt-batch-wait"><span class="k-spin" aria-hidden="true"></span>Relecture des ${formatNumber(rows.length)}${NBSP}comptes et calcul de l’aperçu exact…</div>`;
    foot([{ id: 'cancel', label: 'Annuler', run: () => panel.close() }]);
    try {
      const args = { action, dns: rows.map((r) => r.dn) };
      if (action === 'expiration') args.date = date;
      preview = await ctx.call('accounts.batch.preview', args);
      if (!panel.el?.isConnected) return;
      showPreview();
    } catch (err) {
      console.error(err);
      if (!panel.el?.isConnected) return;
      panel.setBusy(false);
      body.innerHTML = `<p class="cpt-inline-error">${glyph('alert')}${esc(errorText(err, 'Aperçu impossible : rien n’a été préparé.'))}</p>`;
    }
  }

  function showPreview() {
    const p = preview;
    panel.setBusy(false);
    panel.setTitle(p.title, p.simulated ? 'Annuaire fictif · écritures simulées' : 'Écritures dans l’annuaire');
    const targets = p.targets.slice(0, p.shown).map((t, n) => `<li data-j="${n}"><b>${esc(t.name)}</b><span class="mono">${esc(t.sam)}</span>
        <span class="cpt-batch-change"><s>${esc(t.before ?? '')}</s>${glyph('chevronRight')}<em>${esc(t.after ?? '')}</em></span></li>`).join('');
    const more = p.count > p.shown ? `<button class="btn xs subtle" type="button" data-all>${glyph('rows')}Afficher les ${formatNumber(p.count)}${NBSP}comptes</button>` : '';
    const groups = p.excludedGroups.map((gr) => `<li><span>${esc(gr.reason)}</span><b>${formatNumber(gr.count)}</b></li>`).join('');
    const risks = p.risks.map((r) => `<li data-tone="${esc(r.tone)}">${glyph(r.tone === 'alert' ? 'alert' : r.tone === 'warn' ? 'eye' : 'info')}<span>${esc(r.text)}</span></li>`).join('');
    body.innerHTML = `<div class="cpt-batch-hero" data-tone="${p.count ? (action === 'disable' ? 'alert' : 'warn') : 'off'}">
        <span class="cpt-batch-count">${formatNumber(p.count)}</span>
        <div><b>${esc(p.count === 1 ? 'compte exact, et seulement lui' : p.count ? 'comptes exacts, et seulement eux' : 'aucun compte à traiter')}</b><span>${esc(p.impact)}</span></div>
        ${p.simulated ? pill('accent', 'Simulation', { icon: 'sparkles', size: 'sm' }) : ''}
      </div>
      ${risks ? `<ul class="cpt-batch-risks">${risks}</ul>` : ''}
      ${p.count ? `<section class="cpt-batch-sec"><h3>${glyph('check')}Cibles et ce que chacune reçoit</h3><ol class="cpt-batch-list">${targets}</ol>${more}</section>` : ''}
      ${p.excludedCount ? `<section class="cpt-batch-sec"><h3>${glyph('x')}${esc(plural(p.excludedCount, 'compte exclu', 'comptes exclus'))}</h3><ul class="cpt-batch-groups">${groups}</ul></section>` : ''}
      <details class="cpt-batch-details"><summary>${glyph('chevronRight')}Détail complet</summary><pre>${esc(p.details)}</pre></details>`;
    body.querySelectorAll('[data-j]').forEach((el) => setVars(el, { '--j': String(Math.min(16, Number(el.dataset.j))) }));
    body.querySelector('[data-all]')?.addEventListener('click', (e) => {
      const list = body.querySelector('.cpt-batch-list');
      list.innerHTML = p.targets.map((t) => `<li><b>${esc(t.name)}</b><span class="mono">${esc(t.sam)}</span><span class="cpt-batch-change"><s>${esc(t.before ?? '')}</s>${glyph('chevronRight')}<em>${esc(t.after ?? '')}</em></span></li>`).join('');
      e.currentTarget.remove();
    });
    foot([
      { id: 'cancel', label: 'Annuler', run: () => panel.close() },
      { id: 'confirm', label: p.confirmation === 'typed' ? 'Confirmer avec le nombre…' : 'Confirmer…', icon: 'edit', danger: true, disabled: p.count === 0, run: confirm },
    ]);
    announce(`${p.title} : ${p.lines[0]}`);
  }

  async function confirm() {
    const p = preview;
    const typed = p.confirmation === 'typed';
    const answer = await confirmWrite({
      title: p.title,
      message: `${p.impact} Chaque compte reçoit son propre plan, relu juste avant l’envoi, avec son reçu et sa relecture ; une issue incertaine arrête la suite.`,
      target: typed ? p.typedCount : p.targets[0].name,
      targetKind: typed ? 'Nombre de comptes à saisir' : 'Compte',
      targetDetail: typed ? `${formatNumber(p.count)}${NBSP}comptes exacts, ${formatNumber(p.excludedCount)}${NBSP}exclus` : p.targets[0].dn,
      changes: [{ label: p.actionLabel, before: p.targets[0].before ?? '', after: p.targets[0].after ?? '' }],
      details: p.details,
      typed,
      badge: p.simulated ? 'Écritures simulées · annuaire fictif' : 'Écritures dans l’annuaire',
      confirmLabel: p.simulated ? 'Lancer (simulation)' : 'Lancer les écritures',
    });
    if (answer !== 'confirm' || !panel.el?.isConnected) return;
    run();
  }

  async function run() {
    const p = preview;
    locked = true;
    stop = false;
    panel.el?.classList.add('wf-locked');
    panel.setTitle(p.title, 'Écritures en cours');
    const rowsHtml = p.targets.map((t, n) => `<li class="cpt-run-row" data-n="${n}" data-state="wait"><span class="cpt-run-mark" aria-hidden="true"></span>
      <b>${esc(t.name)}</b><span class="cpt-run-state">En attente</span></li>`).join('');
    body.innerHTML = `<div class="cpt-run">
        <div class="cpt-run-head"><div class="progress" role="progressbar" aria-label="Avancement des écritures" aria-valuemin="0" aria-valuemax="${p.count}" aria-valuenow="0"><span></span></div>
          <p class="cpt-run-count" aria-live="polite">0 sur ${formatNumber(p.count)}</p></div>
        <ul class="cpt-run-tally"><li data-k="ok">${glyph('check')}<b>0</b><span>appliquées et vérifiées</span></li><li data-k="info">${glyph('info')}<b>0</b><span>déjà faites ou écartées</span></li>
          <li data-k="alert">${glyph('alert')}<b>0</b><span>refusées</span></li><li data-k="warn">${glyph('eye')}<b>0</b><span>à vérifier</span></li></ul>
        <ol class="cpt-run-list">${rowsHtml}</ol></div>`;
    const tally = { ok: 0, info: 0, alert: 0, warn: 0 };
    const receipts = [];
    const bump = (k) => { tally[k] += 1; const li = body.querySelector(`.cpt-run-tally [data-k="${k}"] b`); if (li) li.textContent = formatNumber(tally[k]); };
    const bar = body.querySelector('.progress');
    const setRow = (n, state, text, href) => {
      const li = body.querySelector(`.cpt-run-row[data-n="${n}"]`);
      if (!li) return;
      li.dataset.state = state;
      li.querySelector('.cpt-run-state').innerHTML = href ? `<a href="${esc(href)}">${esc(text)}</a>` : esc(text);
      if (state === 'busy') li.scrollIntoView({ block: 'nearest' });
    };
    foot([{ id: 'stop', label: 'Arrêter après le compte en cours', icon: 'pause', run: () => { stop = true; announce('Arrêt demandé : le compte en cours va jusqu’au bout.'); foot([]); } }]);
    let halted = null;
    for (let n = 0; n < p.targets.length; n++) {
      if (stop) { halted = 'stopped'; break; }
      const t = p.targets[n];
      setRow(n, 'busy', 'Relecture et plan…');
      let planned;
      try {
        const args = { dn: t.dn };
        if (action === 'expiration') args.date = p.date;
        planned = await ctx.call(p.planOperation, args);
      } catch (err) {
        console.error(err);
        setRow(n, err?.code === 'write.nothingToDo' ? 'skip' : 'fail', errorText(err, 'Plan impossible : rien n’a été envoyé.'));
        bump(err?.code === 'write.nothingToDo' ? 'info' : 'alert');
        continue;
      }
      if (planned.plan.confirmation.typedNameRequired) {
        setRow(n, 'skip', 'Saisie du nom exigée : à traiter seul, rien n’a été envoyé.');
        bump('info');
        continue;
      }
      setRow(n, 'busy', 'Reçu enregistré, envoi…');
      try {
        const receipt = await ctx.call('write.execute', { planId: planned.plan.id, token: planned.token, typedName: null });
        receipts.push(receipt);
        const state = receipt.pending ? 'warn' : receipt.tone === 'ok' ? 'ok' : receipt.result === 'noChange' ? 'skip' : receipt.tone === 'alert' ? 'fail' : 'warn';
        setRow(n, state, `${receipt.resultLabel} · ${receipt.verificationLabel.toLocaleLowerCase('fr')}`, receiptHref(receipt.id));
        bump(state === 'ok' ? 'ok' : state === 'skip' ? 'info' : state === 'fail' ? 'alert' : 'warn');
        if (receipt.pending || receipt.result === 'unknown') { halted = 'uncertain'; break; }
      } catch (err) {
        console.error(err);
        const sent = !NOTHING_SENT.has(err?.code);
        setRow(n, sent ? 'warn' : 'fail', sent ? 'Issue incertaine : consultez Opérations.' : errorText(err, 'Rien n’a été envoyé.'));
        bump(sent ? 'warn' : 'alert');
        if (sent) { halted = 'uncertain'; break; }
      }
      const done = n + 1;
      bar.setAttribute('aria-valuenow', String(done));
      setVars(bar.firstElementChild, { '--p': String(done / p.count) });
      body.querySelector('.cpt-run-count').textContent = `${formatNumber(done)} sur ${formatNumber(p.count)}`;
    }
    locked = false;
    panel.el?.classList.remove('wf-locked');
    body.querySelectorAll('.cpt-run-row[data-state="wait"]').forEach((li) => { li.dataset.state = 'off'; li.querySelector('.cpt-run-state').textContent = halted === 'uncertain' ? 'Non lancé : suite arrêtée' : 'Non lancé : arrêt demandé'; });
    const tone = tally.warn ? 'warn' : tally.alert ? 'alert' : tally.ok ? 'ok' : 'info';
    const sentence = halted === 'uncertain'
      ? 'Une issue est incertaine : la suite a été arrêtée et rien n’est rejoué. Relisez le reçu dans Opérations.'
      : halted === 'stopped' ? 'Arrêt demandé : les comptes restants n’ont pas été traités.' : 'Toutes les cibles ont été traitées, chacune avec son reçu.';
    body.querySelector('.cpt-run').insertAdjacentHTML('afterbegin', `<div class="cpt-run-sum" data-tone="${tone}">${glyph(tone === 'ok' ? 'check' : tone === 'info' ? 'info' : 'alert')}<div><b>Bilan</b><span>${esc(sentence)}</span></div></div>`);
    panel.setTitle(p.title, 'Bilan');
    foot([
      { id: 'close', label: 'Fermer', run: () => panel.close() },
      { id: 'ops', label: 'Voir dans Opérations', icon: 'activity', href: '#/operations' },
    ]);
    toast(`${p.actionLabel} : ${plural(tally.ok, 'écriture vérifiée', 'écritures vérifiées')}${tally.warn ? `, ${plural(tally.warn, 'à vérifier', 'à vérifier')}` : ''}${p.simulated ? '. Simulation : aucun effet réel.' : '.'}`, { tone, life: 8000 });
    announce(sentence);
    onDone?.(receipts);
  }

  start();
  return panel;
}
