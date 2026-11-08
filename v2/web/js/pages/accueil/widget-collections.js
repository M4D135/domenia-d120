import { openDialog } from '../../kit/dialog.js';
import { glyph } from '../../kit/glyphs.js';
import { esc } from '../../ui.js';
import { reported, plural, surface } from './shared.js';

export function collectionText(row) {
  if (row.progressUnavailable) return 'Suivi temporairement indisponible · la collecte peut encore être en cours';
  if (row.phase === 'preparing') return 'Recherche des mesures manquantes…';
  if (row.phase === 'confirming') return `Confirmation · ${plural(row.total, 'poste à lire', 'postes à lire')}`;
  if (row.phase === 'queued') return 'En file · après la collecte et le recalcul en cours';
  if (row.phase === 'drawing') return 'Mesures enregistrées · recalcul du tableau';
  if (row.phase === 'directory') return 'Lecture AD de cette OU · sauvegarde et reçu local';
  if (row.phase === 'bitlocker') return 'Lecture de la présence BitLocker · aucune clé lue';
  if (row.phase === 'planning') return 'Vérification des mesures déjà enregistrées…';
  const label = { inventory: 'Inventaire WMI', software: 'Logiciels', probe: 'WMI mémorisé', query: 'Requête', presence: 'Présence réseau', console: 'Session utilisateur' }[row.phase] ?? 'Collecte';
  const counted = Number.isInteger(row.done) && Number.isInteger(row.total) && row.done >= 0 && row.total >= row.done;
  return `${label} · ${counted ? `${row.done}/${row.total}` : 'en cours'}${row.fresh ? ` · ${row.fresh} déjà frais` : ''}${row.failed ? ` · ${row.failed} non confirmés` : ''}`;
}

/** The engine owns admission and cancellation. The page only acknowledges an actually painted local snapshot. */
export function createWidgetCollections({ ctx, host, isAlive, onChanged }) {
  const requests = new Map();
  let rows = [];
  let stopPulse = null;
  let polling = false;
  let alive = true;
  let scopeKey = null;
  let generation = 0;

  function paint() {
    if (!alive || !isAlive()) return;
    const all = [...rows];
    for (const request of requests.values()) if (!all.some(r => r.widgetId === request.widgetId)) all.push(request);
    host.querySelectorAll('[data-item]').forEach(card => {
      const line = card.querySelector('[data-widget-progress]');
      if (!line) return;
      const activity = all.find(row => row.widgetId === card.dataset.item);
      line.hidden = !activity;
      line.textContent = activity ? collectionText(activity) : '';
      card.classList.toggle('is-collecting', Boolean(activity));
    });
    const queue = host.querySelector('[data-widget-queue]');
    if (queue) {
      queue.hidden = all.length === 0;
      queue.innerHTML = all.length ? `<summary>${glyph('activity')}Collectes de widgets · ${all.length}</summary><ul>${all.map(row =>
        `<li><span><b>${esc(row.title || 'Widget')}</b> · ${esc(collectionText(row))}</span>${row.id ? `<button class="btn ghost sm" type="button" data-widget-cancel="${esc(row.id)}">${glyph('x')}${row.phase === 'queued' ? 'Retirer' : 'Arrêter'}</button>` : ''}</li>`).join('')}</ul>` : '';
    }
  }

  function follow() {
    if (!stopPulse) stopPulse = ctx.pulse.every('accueil.widget.collections', 1000, poll, { maxFailures: 3, onError: (error, failures) => {
      reported(error);
      if (failures === 3) {
        stopPulse?.(); stopPulse = null;
        for (const request of requests.values()) request.progressUnavailable = true;
        rows = rows.map(row => ({ ...row, progressUnavailable: true }));
        paint();
      }
    } });
  }

  async function poll() {
    if (polling || !alive || !isAlive()) return;
    polling = true;
    const version = generation;
    try {
      const current = await ctx.call('accueil.widget.state');
      if (!alive || !isAlive() || version !== generation) return;
      rows = Array.isArray(current) ? current : [];
      for (const request of requests.values()) request.progressUnavailable = false;
      paint();
      if (!rows.length && !requests.size) { stopPulse?.(); stopPulse = null; }
    } catch (error) {
      if (alive && isAlive() && version === generation) throw error;
    } finally { polling = false; }
  }

  async function cancel(id) {
    try { await ctx.call('accueil.widget.cancel', { id }); }
    catch (err) { if (alive) ctx.toast(reported(err), { tone: 'warn' }); }
  }

  async function collect(item, gesture = 'refresh') {
    if (!alive || !isAlive() || item.paused || requests.has(item.id)) return;
    const version = generation;
    const request = { widgetId: item.id, title: item.title || item.key, phase: 'preparing', total: 0, done: 0, fresh: 0, failed: 0 };
    requests.set(item.id, request); paint(); follow();
    let plan;
    let drawn = false;
    try {
      plan = await ctx.call('accueil.widget.plan', { widgetId: item.id, gesture });
      if (!alive || !isAlive() || version !== generation) { await cancel(plan.id); return; }
      Object.assign(request, { id: plan.id, title: plan.title, total: plan.targets, fresh: plan.fresh, phase: plan.confirmationRequired ? 'confirming' : 'queued' });
      paint();
      if (plan.confirmationRequired) {
        const scopeRead = plan.kind === 'directory' || plan.kind === 'bitlocker';
        const volume = scopeRead ? `${plural(plan.targets + plan.fresh, 'poste connu localement', 'postes connus localement')} ; nombre d’objets AD à lire inconnu avant la lecture.`
          : `<b>${plural(plan.targets, 'poste à lire', 'postes à lire')}</b> · ${plural(plan.fresh, 'déjà frais', 'déjà frais')}.`;
        const boundary = scopeRead ? 'Lecture AD bornée à cette OU ; de nouveaux objets peuvent être découverts. Aucun poste n’est interrogé.'
          : 'Seules les identités de ce plan sont admises ; les autres widgets ne sont pas collectés.';
        const body = surface('fw-widget-confirm', `<p>${esc(plan.detail)}</p><p>${volume}</p><p>OU ${esc(plan.scope.label)}${plan.scope.subtree ? ' et ses sous-OU' : ''}. ${boundary}</p>`);
        const dialog = openDialog({ title: `Collecter · ${plan.title}`, icon: 'activity', body, actions: [
          { id: 'cancel', label: 'Annuler', safe: true }, { id: 'run', label: 'Lancer la collecte', primary: true },
        ] });
        const answer = await dialog.result;
        if (answer !== 'run' || !alive || !isAlive() || version !== generation) { await cancel(plan.id); return; }
      }
      request.phase = 'queued'; paint();
      const result = await ctx.call('accueil.widget.run', { planId: plan.id, confirmed: Boolean(plan.confirmationRequired) });
      if (!alive || !isAlive() || version !== generation) return;
      request.phase = 'drawing'; request.progressUnavailable = false; paint();
      const rendered = await onChanged();
      if (!alive || !isAlive() || version !== generation || rendered !== true) {
        // A failed redraw cannot start the next automatic request on the old snapshot.
        for (const other of requests.values()) if (other.id && other.id !== plan.id) await cancel(other.id);
        return;
      }
      await ctx.call('accueil.widget.drawn', { id: plan.id });
      drawn = true;
      // The partial result stays in the widget and notification journal; its banner must release the catalogue actions.
      // Distinct plans keep separate receipts instead of pinning a repeated generic warning.
      if (result.failed > 0) ctx.toast(result.detail, { tone: 'warn', life: 6000, key: `widget-collection:${plan.id}` });
    } catch (err) {
      if (alive && isAlive() && version === generation) {
        ctx.toast(reported(err), { tone: 'warn' });
        // A cancelled/partial native stage may have committed measurements before returning its error.
        try { await onChanged(); } catch (drawError) { reported(drawError); }
      }
    } finally {
      if (plan && !drawn) await cancel(plan.id);
      if (requests.get(item.id) === request) requests.delete(item.id);
      rows = rows.filter(row => row.id !== plan?.id);
      paint();
      if (!requests.size && !rows.length) { stopPulse?.(); stopPulse = null; }
    }
  }

  function scope(scope) {
    const next = scope ? `${scope.dn.toLocaleLowerCase('en-US')}|${Boolean(scope.subtree)}` : null;
    if (scopeKey !== null && scopeKey !== next) {
      generation++;
      for (const request of requests.values()) if (request.id) void cancel(request.id);
      requests.clear(); rows = [];
      stopPulse?.(); stopPulse = null;
      paint();
    }
    scopeKey = next;
  }

  const click = event => {
    const button = event.target instanceof Element ? event.target.closest('[data-widget-cancel]') : null;
    if (button) void cancel(button.dataset.widgetCancel);
  };
  host.addEventListener('click', click);
  return {
    collect, paint, scope,
    cancelWidget(widgetId) {
      for (const request of [...requests.values(), ...rows]) if (request.widgetId === widgetId && request.id) void cancel(request.id);
    },
    destroy() {
      alive = false; generation++;
      stopPulse?.(); stopPulse = null;
      host.removeEventListener('click', click);
      for (const request of [...requests.values(), ...rows]) if (request.id) void cancel(request.id);
      rows = [];
    },
  };
}
