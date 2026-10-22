// Comptes screen: collective action on accounts (Domenia 1 TRV-229, docs/WRITES.md § 1 « une écriture collective aura son
// propre plan avec un aperçu exact »). Local component of the screen. The engine computes the exact preview and SEALS it
// (accounts.batch.preview: targets, motivated exclusions, impact, number to type, collective plan { id, fingerprint, count }).
// The operator may untick targets (a new exact preview is then sealed for the kept ones) and copy the preview as CSV. The
// confirmation of the kit asks for the number of accounts from two on, and the ENGINE checks it again (accounts.batch.confirm).
// Only then does each sealed target get its own plan (accounts.batch.plan: once per target, its GUID compared with the seal,
// read again on the controller) and run once through write.execute, with its receipt and its re-read. One after the other;
// an uncertain outcome stops the rest; nothing is ever replayed. A stop request never interrupts the write under way.
// Closing the panel while the preview is read stops that read (accounts.batch.cancel): nothing was prepared.
import { openDrawer, confirmWrite, glyph, pill, setVars, NBSP } from '../../kit/index.js';
import { esc, errorText, announce, formatNumber, toast, copyText } from '../../ui.js';
import { receiptHref, NOTHING_SENT as CIRCUIT_NOTHING_SENT } from '../../write-flow.js';
import { plural, isoDay, whenOpen, longDay } from './shared.js';
import { previewCsv } from './rules.js';
import { createDateField } from './datefield.js';

/** Most accounts a selection or a link hands to one collective action (the engine admits 5 000 DN per preview). */
export const MAX_BATCH = 5000;

/** Refusals of a plan or of write.execute that mean nothing was sent: those of the circuit, and those of the sealed batch. */
const NOTHING_SENT = new Set([...CIRCUIT_NOTHING_SENT, 'accounts.protectedAccount', 'accounts.batchUnknown', 'accounts.batchExpired',
  'accounts.batchUnconfirmed', 'accounts.batchIssued', 'accounts.batchTargetChanged', 'accounts.batchTypedName', 'accounts.batchCountMismatch',
  'operation.cancelled']);
/** Refusals that end the whole batch (the seal is gone): the remaining targets get no plan. */
const BATCH_GONE = new Set(['accounts.batchUnknown', 'accounts.batchExpired', 'accounts.batchUnconfirmed']);

const ACTIONS = {
  unlock: { label: 'Déverrouiller', icon: 'lock' },
  enable: { label: 'Activer', icon: 'power' },
  disable: { label: 'Désactiver', icon: 'power', danger: true },
  mustChange: { label: 'Imposer un nouveau mot de passe', icon: 'refresh' },
  expiration: { label: 'Fixer l’expiration', icon: 'calendar' },
};

/** Ticket of a preview read (8 to 40 letters, digits or dashes), so the page can stop it. */
function newTicket() {
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Opens the collective action panel for the selected rows.
 * @param {{ call: Function }} ctx
 * @param {{ action: string, rows: any[], onDone?: (receipts: any[]) => void }} o
 */
export function openBatch(ctx, { action, rows, onDone }) {
  const meta = ACTIONS[action];
  let locked = false;
  let stop = false;
  let preview = null;
  let date = null;
  let reading = null; // ticket of the preview read under way
  let dns = rows.slice(0, MAX_BATCH).map((r) => r.dn);
  const unticked = new Set();
  const body = document.createElement('div');
  body.className = 'cpt-batch';
  body.dataset.page = 'comptes';
  const panel = openDrawer({
    title: `${meta.label} · action par lot`,
    subtitle: plural(dns.length, 'compte sélectionné', 'comptes sélectionnés'),
    icon: 'layers',
    key: 'comptes.batch',
    width: 640,
    minWidth: 480,
    maxWidth: 1000,
    body,
    onClose: () => {
      if (locked) stop = true;
      // Panel closed during the preview: its read stops (nothing was prepared).
      if (reading) ctx.call('accounts.batch.cancel', { ticket: reading }).catch((err) => console.error(err));
      reading = null;
    },
  });

  const foot = (buttons) => {
    if (!panel.foot) return;
    panel.foot.hidden = buttons.length === 0;
    panel.foot.innerHTML = buttons.map((b) => (b.href
      ? `<a class="btn${b.primary ? ' primary' : ' subtle'}" href="${esc(b.href)}">${b.icon ? glyph(b.icon) : ''}${esc(b.label)}</a>`
      : `<button class="btn${b.primary ? ' primary' : ''}${b.danger ? ' danger' : ''}${!b.primary && !b.danger ? ' subtle' : ''}" type="button" data-b="${esc(b.id)}"${b.disabled ? ` disabled data-tip="${esc(b.reason ?? '')}"` : ''}>${b.icon ? glyph(b.icon) : ''}${esc(b.label)}${b.write ? '<span class="cpt-wmark" aria-hidden="true">' + glyph('edit') + '</span>' : ''}</button>`)).join('');
    panel.foot.onclick = (e) => {
      const btn = e.target instanceof Element ? e.target.closest('[data-b]') : null;
      if (btn && !btn.disabled) buttons.find((b) => b.id === btn.dataset.b)?.run?.();
    };
  };

  const start = async () => {
    if (!(await whenOpen(panel))) return;
    // Échap does not close the panel while the writes run (each write goes to its end; the summary shows here).
    panel.el.addEventListener('keydown', (e) => {
      if (locked && e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); announce(`Écritures en cours${NBSP}: le panneau reste ouvert jusqu’au bilan.`); }
    }, true);
    if (rows.length > MAX_BATCH) toast(`Lot limité aux ${formatNumber(MAX_BATCH)} premiers comptes sur ${formatNumber(rows.length)}.`, { tone: 'warn', life: 7000 });
    if (action === 'expiration') chooseDate(); else loadPreview();
  };

  function chooseDate() {
    const now = new Date();
    const plus = (days) => { const x = new Date(now); x.setDate(x.getDate() + days); return isoDay(x); };
    body.innerHTML = `<div class="cpt-batch-step"><span class="cpt-batch-num">1</span><div>
        <h3>Date d’expiration</h3><p>Tous les comptes retenus expireront à 0${NBSP}h ce jour-là (heure locale), ou n’expireront plus.</p>
        <div class="k-field"><label for="cpt-batch-date">Expire le (à 0${NBSP}h, heure locale)</label><div class="cpt-exp-field"></div></div>
        <div class="cpt-exp-said" id="cpt-batch-said" aria-live="polite"></div>
        <label class="k-check-row"><input class="k-checkbox" type="checkbox" data-never><span>Supprimer l’expiration (n’expire plus)</span></label>
      </div></div>`;
    const never = body.querySelector('[data-never]');
    const said = body.querySelector('#cpt-batch-said');
    // French date field (JJ/MM/AAAA and its calendar), never the format of the native control.
    const field = createDateField(body.querySelector('.cpt-exp-field'), { id: 'cpt-batch-date', value: plus(30), describedBy: 'cpt-batch-said', onChange: () => describe() });
    // The date in French words, and the risk of a past date (the engine admits it: « expiré dès l’écriture »).
    function describe() {
      if (never.checked) { said.innerHTML = `<span class="cpt-muted">Les comptes retenus n’expireront plus.</span>`; said.dataset.tone = 'info'; return; }
      const value = field.value() ?? '';
      const day = longDay(value);
      if (!day) { said.innerHTML = '<span class="cpt-muted">Saisissez une date au format JJ/MM/AAAA ou choisissez-la dans le calendrier.</span>'; said.dataset.tone = 'info'; return; }
      const past = value <= isoDay(now);
      said.innerHTML = `<b>${glyph('calendar')}Expirent le ${esc(day)} à 0${NBSP}h</b>`
        + (past ? `<span class="cpt-exp-risk">${glyph('alert')}Date passée ou d’aujourd’hui${NBSP}: les comptes seront expirés dès l’écriture.</span>` : '');
      said.dataset.tone = past ? 'alert' : 'info';
    }
    describe();
    never.addEventListener('change', () => { field.disable(never.checked); describe(); });
    foot([
      { id: 'cancel', label: 'Annuler', run: () => panel.close() },
      { id: 'next', label: 'Voir l’aperçu exact', icon: 'eye', primary: true, run: () => {
        if (!never.checked && !field.value()) { field.focus(); toast('Saisissez une date au format JJ/MM/AAAA.', { tone: 'warn' }); return; }
        date = never.checked ? null : field.value();
        loadPreview();
      } },
    ]);
  }

  async function loadPreview() {
    panel.setBusy(true);
    body.innerHTML = `<div class="cpt-batch-wait" role="status"><span class="k-spin" aria-hidden="true"></span>Relecture des ${formatNumber(dns.length)}${NBSP}comptes et calcul de l’aperçu exact…</div>`;
    foot([{ id: 'cancel', label: 'Annuler', run: () => panel.close() }]);
    const ticket = newTicket();
    reading = ticket;
    try {
      const args = { action, dns, ticket };
      if (action === 'expiration') args.date = date;
      const next = await ctx.call('accounts.batch.preview', args);
      if (reading !== ticket) return; // closed, or replaced by another read
      reading = null;
      if (!panel.el?.isConnected) return;
      preview = next;
      unticked.clear();
      showPreview();
    } catch (err) {
      if (reading !== ticket) return;
      reading = null;
      console.error(err);
      if (!panel.el?.isConnected) return;
      panel.setBusy(false);
      body.innerHTML = `<p class="cpt-inline-error">${glyph('alert')}${esc(errorText(err, `Aperçu impossible${NBSP}: rien n’a été préparé.`))}</p>`;
      foot([{ id: 'close', label: 'Fermer', run: () => panel.close() }, { id: 'again', label: 'Relire l’aperçu', icon: 'refresh', primary: true, run: loadPreview }]);
    }
  }

  function targetRow(t, n) {
    const off = unticked.has(t.dn);
    return `<li data-j="${n}" class="${off ? 'off' : ''}"><label class="cpt-batch-pick" data-tip="${off ? 'Remettre dans le lot' : 'Retirer du lot'}">
        <input class="k-checkbox" type="checkbox" data-dn="${esc(t.dn)}" ${off ? '' : 'checked'} aria-label="${esc(`${t.name}${NBSP}: garder dans le lot`)}"></label>
      <b>${esc(t.name)}</b><span class="mono">${esc(t.sam)}</span>
      <span class="cpt-batch-change"><s>${esc(t.before ?? '')}</s>${glyph('chevronRight')}<em>${esc(t.after ?? '')}</em></span></li>`;
  }

  function showPreview() {
    const p = preview;
    panel.setBusy(false);
    panel.setTitle(p.title, p.simulated ? 'Annuaire fictif · écritures simulées' : 'Écritures dans l’annuaire');
    const shown = p.targets.slice(0, p.shown);
    const more = p.count > p.shown ? `<button class="btn xs subtle" type="button" data-all>${glyph('rows')}Afficher les ${formatNumber(p.count)}${NBSP}comptes</button>` : '';
    const groups = p.excludedGroups.map((gr) => `<li><span>${esc(gr.reason)}</span><b>${formatNumber(gr.count)}</b></li>`).join('');
    const risks = p.risks.map((r) => `<li data-tone="${esc(r.tone)}">${glyph(r.tone === 'alert' ? 'alert' : r.tone === 'warn' ? 'eye' : 'info')}<span>${esc(r.text)}</span></li>`).join('');
    const seal = p.batch ? `<span class="cpt-batch-seal" data-tip="${esc(`Empreinte de la liste exacte${NBSP}: ${p.batch.fingerprint}`)}" tabindex="0">${glyph('shield')}Aperçu scellé par le moteur · ${esc(p.batch.fingerprint.slice(0, 12))}</span>` : '';
    body.innerHTML = `<div class="cpt-batch-hero" data-tone="${p.count ? (action === 'disable' ? 'alert' : 'warn') : 'off'}">
        <span class="cpt-batch-count">${formatNumber(p.count)}</span>
        <div><b>${esc(p.count === 1 ? 'compte exact, et seulement lui' : p.count ? 'comptes exacts, et seulement eux' : 'aucun compte à traiter')}</b><span>${esc(p.impact)}</span>${seal}</div>
        ${p.simulated ? pill('accent', 'Simulation', { icon: 'sparkles', size: 'sm' }) : ''}
      </div>
      ${risks ? `<ul class="cpt-batch-risks">${risks}</ul>` : ''}
      ${p.count ? `<section class="cpt-batch-sec"><div class="cpt-batch-sec-head"><h3>${glyph('check')}Cibles et ce que chacune reçoit</h3>
          <button class="btn xs subtle" type="button" data-csv data-tip="Cibles et exclusions, copiées en CSV pour un tableur">${glyph('csv')}Copier en CSV</button></div>
        <p class="cpt-batch-hint">Décochez un compte pour le retirer du lot${NBSP}: un nouvel aperçu exact est alors calculé et scellé pour les comptes gardés.</p>
        <ol class="cpt-batch-list">${shown.map(targetRow).join('')}</ol>${more}
        <div class="cpt-batch-reseal" hidden></div></section>` : ''}
      ${p.excludedCount ? `<section class="cpt-batch-sec"><h3>${glyph('x')}${esc(plural(p.excludedCount, 'compte exclu', 'comptes exclus'))}</h3><ul class="cpt-batch-groups">${groups}</ul></section>` : ''}
      <details class="cpt-batch-details"><summary>${glyph('chevronRight')}Détail complet</summary><pre>${esc(p.details)}</pre></details>`;
    body.querySelectorAll('[data-j]').forEach((el) => setVars(el, { '--j': String(Math.min(16, Number(el.dataset.j))) }));
    body.querySelector('[data-all]')?.addEventListener('click', (e) => {
      body.querySelector('.cpt-batch-list').innerHTML = p.targets.map(targetRow).join('');
      e.currentTarget.remove();
    });
    body.querySelector('[data-csv]')?.addEventListener('click', async () => {
      const csv = previewCsv(p);
      if (await copyText(csv)) toast(`Aperçu copié en CSV (${plural(p.count + p.excludedCount, 'ligne', 'lignes')})${NBSP}: collez-le dans un tableur.`, { tone: 'ok' });
      else toast('Copie impossible dans le presse-papiers.', { tone: 'warn' });
    });
    body.querySelector('.cpt-batch-list')?.addEventListener('change', (e) => {
      const box = e.target instanceof HTMLInputElement ? e.target : null;
      if (!box?.dataset.dn) return;
      if (box.checked) unticked.delete(box.dataset.dn); else unticked.add(box.dataset.dn);
      box.closest('li')?.classList.toggle('off', !box.checked);
      paintFoot();
    });
    paintFoot();
    announce(`${p.title}${NBSP}: ${p.lines[0] ?? ''}`);
  }

  /** Footer of the preview: confirm the sealed list, or seal a new one without the unticked accounts. */
  function paintFoot() {
    const p = preview;
    const reseal = body.querySelector('.cpt-batch-reseal');
    const kept = p.targets.filter((t) => !unticked.has(t.dn));
    if (unticked.size) {
      if (reseal) {
        reseal.hidden = false;
        reseal.innerHTML = `${glyph('info')}<span>${esc(plural(unticked.size, 'compte retiré', 'comptes retirés'))}${NBSP}: l’aperçu scellé ne vaut plus. Calculez l’aperçu des ${esc(plural(kept.length, 'compte gardé', 'comptes gardés'))}.</span>`;
      }
      foot([
        { id: 'cancel', label: 'Annuler', run: () => panel.close() },
        { id: 'reseal', label: 'Calculer le nouvel aperçu', icon: 'refresh', primary: true, disabled: kept.length === 0, reason: 'Gardez au moins un compte.', run: () => {
          dns = kept.map((t) => t.dn);
          panel.setTitle(`${meta.label} · action par lot`, plural(dns.length, 'compte gardé', 'comptes gardés'));
          loadPreview();
        } },
      ]);
      return;
    }
    if (reseal) reseal.hidden = true;
    foot([
      { id: 'cancel', label: 'Annuler', run: () => panel.close() },
      { id: 'confirm', label: p.confirmation === 'typed' ? 'Confirmer avec le nombre…' : 'Confirmer…', icon: meta.icon, write: true,
        primary: !meta.danger, danger: !!meta.danger, disabled: p.count === 0 || !p.batch, reason: p.count === 0 ? 'Aucun compte à traiter.' : 'Aperçu non scellé.', run: confirm },
    ]);
  }

  async function confirm() {
    const p = preview;
    const typed = p.confirmation === 'typed';
    let typedCount = null;
    const answer = await confirmWrite({
      title: p.title,
      message: `${p.impact} Le moteur revérifie le nombre saisi, puis chaque compte reçoit son propre plan, relu juste avant l’envoi, avec son reçu et sa relecture${NBSP}; une issue incertaine arrête la suite.`,
      target: typed ? p.typedCount : p.targets[0].name,
      targetKind: typed ? 'Nombre de comptes à saisir' : 'Compte',
      targetDetail: typed ? `${formatNumber(p.count)}${NBSP}comptes exacts, ${formatNumber(p.excludedCount)}${NBSP}exclus` : p.targets[0].dn,
      changes: [{ label: p.actionLabel, before: p.targets[0].before ?? '', after: p.targets[0].after ?? '' }],
      details: p.details,
      typed,
      onTyped: (text) => { typedCount = text; },
      badge: p.simulated ? 'Écritures simulées · annuaire fictif' : 'Écritures dans l’annuaire',
      confirmLabel: p.simulated ? 'Lancer (simulation)' : 'Lancer les écritures',
    });
    if (answer !== 'confirm' || !panel.el?.isConnected) return;
    // The engine checks the typed number again; a wrong number spends the seal (the preview is to be read again).
    try {
      panel.setBusy(true);
      await ctx.call('accounts.batch.confirm', { id: p.batch.id, typedCount: typed ? typedCount : null });
      panel.setBusy(false);
    } catch (err) {
      console.error(err);
      panel.setBusy(false);
      if (!panel.el?.isConnected) return;
      body.insertAdjacentHTML('afterbegin', `<p class="cpt-inline-error">${glyph('alert')}${esc(errorText(err, `Confirmation refusée${NBSP}: rien n’a été préparé.`))}</p>`);
      foot([{ id: 'close', label: 'Fermer', run: () => panel.close() }, { id: 'again', label: 'Relire l’aperçu', icon: 'refresh', primary: true, run: loadPreview }]);
      return;
    }
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
    foot([{ id: 'stop', label: 'Arrêter après le compte en cours', icon: 'pause', run: () => { stop = true; announce(`Arrêt demandé${NBSP}: le compte en cours va jusqu’au bout.`); foot([]); } }]);
    let halted = null;
    for (let n = 0; n < p.targets.length; n++) {
      if (stop) { halted = 'stopped'; break; }
      setRow(n, 'busy', 'Relecture et plan…');
      let planned;
      try {
        // The plan of a sealed target only, once: the engine compares its GUID with the seal.
        planned = await ctx.call('accounts.batch.plan', { id: p.batch.id, index: n });
      } catch (err) {
        console.error(err);
        const skip = err?.code === 'write.nothingToDo' || err?.code === 'accounts.batchTypedName';
        setRow(n, skip ? 'skip' : 'fail', errorText(err, `Plan impossible${NBSP}: rien n’a été envoyé.`));
        bump(skip ? 'info' : 'alert');
        if (BATCH_GONE.has(err?.code)) { halted = 'expired'; break; }
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
        setRow(n, sent ? 'warn' : 'fail', sent ? `Issue incertaine${NBSP}: consultez Opérations.` : errorText(err, 'Rien n’a été envoyé.'));
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
    const notRun = `Non lancé${NBSP}: ${halted === 'uncertain' ? 'suite arrêtée' : halted === 'expired' ? 'lot expiré' : 'arrêt demandé'}`;
    body.querySelectorAll('.cpt-run-row[data-state="wait"]').forEach((li) => { li.dataset.state = 'off'; li.querySelector('.cpt-run-state').textContent = notRun; });
    const tone = tally.warn ? 'warn' : tally.alert ? 'alert' : tally.ok ? 'ok' : 'info';
    const sentence = halted === 'uncertain'
      ? `Une issue est incertaine${NBSP}: la suite a été arrêtée et rien n’est rejoué. Relisez le reçu dans Opérations.`
      : halted === 'expired' ? `Le lot scellé a expiré${NBSP}: les comptes restants n’ont reçu aucun plan. Relisez l’aperçu pour les traiter.`
        : halted === 'stopped' ? `Arrêt demandé${NBSP}: les comptes restants n’ont pas été traités.` : 'Toutes les cibles ont été traitées, chacune avec son reçu.';
    body.querySelector('.cpt-run').insertAdjacentHTML('afterbegin', `<div class="cpt-run-sum" data-tone="${tone}">${glyph(tone === 'ok' ? 'check' : tone === 'info' ? 'info' : 'alert')}<div><b>Bilan</b><span>${esc(sentence)}</span></div></div>`);
    panel.setTitle(p.title, 'Bilan');
    foot([
      { id: 'close', label: 'Fermer', run: () => panel.close() },
      { id: 'ops', label: 'Voir dans Opérations', icon: 'activity', href: '#/operations' },
    ]);
    toast(`${p.actionLabel}${NBSP}: ${plural(tally.ok, 'écriture vérifiée', 'écritures vérifiées')}${tally.warn ? `, ${plural(tally.warn, 'à vérifier', 'à vérifier')}` : ''}${p.simulated ? `. Simulation${NBSP}: aucun effet réel.` : '.'}`, { tone, life: 8000 });
    announce(sentence);
    onDone?.(receipts);
  }

  start();
  return panel;
}
