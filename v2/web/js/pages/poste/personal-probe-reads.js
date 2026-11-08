// Explicit per-card reads of immutable personal versions. Preparing/closing a contract never collects.
import { openDialog } from '../../kit/dialog.js';
import { esc, errorText } from './common.js';

const personalKey = (key) => /^custom\.[a-f0-9]{64}$/.test(key ?? '');

function contractBody(plan) {
  const contract = plan.contract ?? {};
  return `<p>${esc(plan.detail)}</p><dl class="ps-sheet"><div class="ps-sheet-row"><dt>Poste exact</dt><dd>${esc(plan.computer)} · ${esc(plan.computerGuid)}</dd></div>`
    + `<div class="ps-sheet-row"><dt>Compte ordinateur</dt><dd>${esc(plan.dn)}</dd></div><div class="ps-sheet-row"><dt>Version de sonde</dt><dd><code>${esc(plan.key)}</code></dd></div>`
    + `<div class="ps-sheet-row"><dt>Droits déclarés</dt><dd>${esc(contract.privilegeLevel ?? 'Non déclarés')}</dd></div>`
    + `<div class="ps-sheet-row"><dt>Coût déclaré</dt><dd>${esc(contract.costLevel ?? 'Non déclaré')}</dd></div></dl>`
    + `<p>${esc(contract.summary ?? '')}</p>`
    + (contract.lines ?? []).map((line) => `<section><h4>${esc(line.section)}</h4><p>${esc(line.value)}</p></section>`).join('')
    + (contract.warnings ?? []).map((text) => `<p>${esc(text)}</p>`).join('')
    + (contract.errors ?? []).map((text) => `<p role="alert">${esc(text)}</p>`).join('');
}

export function createPersonalProbeReads(host, state, { changed, reload, isAlive }) {
  let disposed = false;
  let current = null;
  const messages = new Map();
  const alive = () => !disposed && isAlive();
  const active = (work) => alive() && state.dn === work.dn && state.data?.computer?.guid === work.guid
    && [...host.querySelectorAll('[data-probe-card]')].some((node) => node.dataset.probeCard === work.key && node.dataset.probeWidget === work.item);
  const message = (work, text, tone = 'info') => { if (alive()) { messages.set(work.key, { text, tone }); changed(work.key); } };
  const discard = (work) => {
    if (work.plan && !work.sent && !work.discarded) {
      work.discarded = true;
      Promise.resolve().then(() => state.call('poste.personalProbe.discard', { id: work.plan.id })).catch(() => {});
    }
  };

  async function prepare(key, item) {
    if (!alive() || current || !personalKey(key) || !item) return;
    const work = { key, item, dn: state.dn, guid: state.data?.computer?.guid, plan: null, dialog: null, sent: false, stopping: false };
    if (!active(work)) return;
    current = work;
    message(work, 'Préparation locale du contrat et de la cible…');
    try {
      work.plan = await state.call('poste.personalProbe.plan', { dn: work.dn, computer: work.guid, item });
      if (!active(work) || current !== work) return;
      const plan = work.plan;
      if (plan?.key !== key || plan.widgetId !== item || String(plan.computerGuid).toLowerCase() !== String(work.guid).toLowerCase() || plan.dn !== work.dn || !plan.id) {
        throw new Error('La préparation ne correspond pas à cette carte et à ce poste. Rouvrez le tableau.');
      }
      work.dialog = openDialog({ title: `Relever ${plan.contract?.name ?? 'cette sonde'} sur ${plan.computer}`, subtitle: 'Lecture seule · version personnelle exacte',
        icon: 'filter', size: 'lg', body: contractBody(plan),
        actions: [{ id: 'cancel', label: 'Fermer sans relever', safe: true }, { id: 'read', label: 'Relever cette sonde', primary: true, disabled: plan.contract?.valid !== true }],
        onOpen: (el) => el.classList.add('poste-drw', 'ps-personal-probe-dialog'),
      });
      const answer = await work.dialog.result;
      work.dialog = null;
      if (!active(work) || current !== work || answer !== 'read' || plan.contract?.valid !== true) {
        if (active(work)) message(work, 'Contrat fermé ; aucune collecte lancée.');
        return;
      }
      work.sent = true;
      message(work, 'Lecture de cette version en cours ; le résultat sera enregistré puis relu.');
      const pending = state.call('poste.personalProbe.run', { id: plan.id, confirmed: true });
      state.refreshRunning?.();
      const result = await pending;
      if (!active(work)) return;
      if (result?.key !== key || result.id !== plan.id || result.receipt?.readBack !== true) {
        throw new Error('Le reçu ne confirme pas la relecture de cette version ; relisez son cache.');
      }
      message(work, result.receipt.text, result.page?.status?.state === 'read' ? 'ok' : 'warn');
    } catch (err) {
      if (active(work)) message(work, errorText(err), err?.code === 'poste.cancelled' ? 'info' : 'warn');
    } finally {
      discard(work);
      if (current === work) current = null;
      if (work.sent) state.refreshRunning?.();
      if (active(work)) {
        changed(key);
        if (work.sent) reload(key); // A local cache read also exposes any partial result retained after stop.
      }
    }
  }

  async function stop(work) {
    if (!work?.sent || work.stopping || !active(work)) return;
    work.stopping = true;
    message(work, 'Arrêt demandé ; attente de la fin réelle de la lecture native.');
    try {
      const result = await state.call('poste.collect.stop', { dn: work.dn, kind: 'probes' });
      if (current === work && active(work)) message(work, result.text);
    } catch (err) {
      work.stopping = false;
      if (active(work)) message(work, errorText(err), 'warn');
    }
  }

  const clicked = (event) => {
    const button = event.target instanceof Element ? event.target.closest('[data-personal-probe-read],[data-personal-probe-stop]') : null;
    if (!button || button.disabled || !host.contains(button)) return;
    if (button.hasAttribute('data-personal-probe-stop')) void stop(current);
    else void prepare(button.dataset.personalProbeRead, button.dataset.probeWidget);
  };
  host.addEventListener('click', clicked);
  return {
    actions(key, item) {
      if (!personalKey(key) || !item) return '';
      const feedback = messages.get(key);
      const reading = current?.key === key && current.sent;
      return `<div class="ps-row-actions"><button class="btn sm" type="button" data-personal-probe-read="${esc(key)}" data-probe-widget="${esc(item)}"${current ? ' disabled' : ''}>Contrat et relevé explicite</button>`
        + (reading ? `<button class="btn sm" type="button" data-personal-probe-stop${current.stopping ? ' disabled' : ''}>Arrêter</button>` : '') + '</div>'
        + (feedback ? `<p role="status" data-tone="${esc(feedback.tone)}">${esc(feedback.text)}</p>` : '<p class="ps-faint">Sonde personnelle du profil. Ajouter ou relire cette carte ne collecte aucune donnée.</p>');
    },
    refresh() { if (current && !current.sent && !active(current)) { current.dialog?.close(null); discard(current); } },
    destroy() { disposed = true; current?.dialog?.close(null); if (current) discard(current); host.removeEventListener('click', clicked); },
  };
}
