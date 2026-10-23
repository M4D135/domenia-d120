// Tab « Relevés » (Domenia 1 OPE-017, OPE-027 to OPE-029): the survey in progress with its phases (Préparation, Lecture AD,
// À confirmer, En cours, Enregistrement), its counters and its stop, the interrupted survey that can be resumed (only its remaining
// workstations, after the confirmation of their count and scope), abandoned or postponed, and the last run of each family and OU
// of the local base. Measures already received are kept; nothing is replayed.
import { esc, errorText, toast, announce } from '../../ui.js';
import { createGrid, createFilterBar, confirmDialog, pill, glyph, writeClipboard, NBSP } from '../../kit/index.js';
import { count, int, cardHead, emptyState, errorBox, fullDate, repaint, unpaint, skeletonLines } from './common.js';

const TYPE_OPTIONS = [
  { value: 'directory', label: 'Objets AD', tone: 'info' },
  { value: 'presence', label: 'Ping', tone: 'info' },
  { value: 'inventory', label: 'WMI', tone: 'info' },
];
const STATUS_OPTIONS = [
  { value: 'success', label: 'Réussi', tone: 'ok' },
  { value: 'partial', label: 'Partiel', tone: 'warn' },
  { value: 'cancelled', label: 'Arrêté', tone: 'off' },
  { value: 'error', label: 'En échec', tone: 'alert' },
];
const COLUMNS = [
  { id: 'attemptAt', label: 'Date', type: 'date', width: 118, required: true },
  { id: 'ou', label: 'OU', width: 198, required: true, html: (v, r) => `<span class="op-cell-target"><span class="op-cell-ico" aria-hidden="true">${glyph('ou')}</span><span data-tip="${esc(r.ouDn)}">${esc(v)}</span></span>` },
  { id: 'family', label: 'Type', type: 'enum', width: 108, options: TYPE_OPTIONS },
  { id: 'status', label: 'État', type: 'enum', width: 116, options: STATUS_OPTIONS },
  { id: 'counts', label: 'Postes ou objets lus', width: 240, html: (v) => (v ? `<span class="op-cell-2l" data-tip="${esc(v)}">${esc(v)}</span>` : '—') },
  { id: 'successAt', label: 'Dernière réussite', type: 'date', width: 170 },
  { id: 'reason', label: 'Motif', width: 340, html: (v) => (v ? `<span class="op-cell-2l" data-tip="${esc(v)}">${esc(v)}</span>` : '—') },
  { id: 'ouDn', label: 'Chemin (DN)', width: 300, mono: true, hidden: true },
];
const FACETS = [
  { id: 'directory', label: 'Objets AD', tone: 'info' },
  { id: 'presence', label: 'Ping', tone: 'info' },
  { id: 'inventory', label: 'WMI', tone: 'info' },
  { id: 'problems', label: 'Partiels ou en échec', tone: 'warn' },
];

/**
 * @param {HTMLElement} host
 * @param {{ ctx: any, demo: boolean, silent: Function, onOffer: (offer: any) => void }} env
 */
export function createRuns(host, env) {
  const { ctx } = env;
  let alive = true;
  let view = null;
  let pressed = new Set();
  let busy = false;

  host.innerHTML = `<div class="op-runs">
    <div class="grid">
      <section class="card span-6 op-survey-card spot" data-card="current" aria-busy="true">${skeletonLines(4)}</section>
      <section class="card span-6 op-offer-card spot" data-card="offer" aria-busy="true">${skeletonLines(4)}</section>
    </div>
    <div class="op-sec"><h3>Derniers relevés par OU</h3><span class="op-sec-note">Le plus récent en haut · seul ce qui a été enregistré est affiché</span></div>
    <div class="op-rn-filters"></div>
    <div class="op-rn-grid"></div>
    <p class="op-note" data-runs-note></p>
  </div>`;

  const grid = createGrid(host.querySelector('.op-rn-grid'), {
    key: 'operations.releves',
    label: 'Derniers relevés par OU',
    rowId: (r) => r.id,
    selection: 'single',
    loading: true,
    height: '420px',
    columns: COLUMNS,
    quickPlaceholder: 'Filtrer les relevés (OU, motif…)',
    empty: { icon: 'wifi', title: 'Aucun relevé enregistré', text: 'Les relevés des postes (ping, WMI) et les lectures de l’annuaire s’inscrivent ici à leur fin.' },
    onExport: (csv, info) => {
      if (env.demo) { writeClipboard(csv).then(() => toast(`Exemple local${NBSP}: CSV copié, rien n’est enregistré.`, { tone: 'info' })); return; }
      ctx.call('operations.export.save', { subject: 'releves', csv }).then((r) => toast(r.saved ? `${count(info.rows, 'relevé exporté', 'relevés exportés')}${NBSP}: ${r.name}` : r.message, { tone: r.saved ? 'ok' : 'info', life: 6000 }))
        .catch((err) => toast(`Export impossible${NBSP}: ${errorText(err)}`, { tone: 'alert' }));
    },
  });
  const filters = createFilterBar(host.querySelector('.op-rn-filters'), {
    label: 'Filtres des relevés',
    facets: FACETS.map((f) => ({ ...f, count: 0 })),
    onToggle: (id, on) => { if (on) pressed.add(id); else pressed.delete(id); paintRows(); },
    onClear: () => { pressed = new Set(); paintRows(); },
  });

  host.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-run-act]') : null;
    if (b && !b.disabled) act(b.dataset.runAct, b);
  });

  function load(silent = false) {
    const call = silent ? env.silent : ctx.call;
    return call('operations.runs').then((next) => {
      if (!alive) return;
      view = next;
      paint();
      env.onOffer?.(next.offer, next.current);
    }).catch((err) => {
      console.error(err);
      if (!alive) return;
      ['current', 'offer'].forEach((id) => {
        const card = host.querySelector(`[data-card="${id}"]`);
        card.removeAttribute('aria-busy');
        unpaint(card);
        card.innerHTML = errorBox(errorText(err, 'Relevés illisibles.'));
      });
      grid.setError(errorText(err, 'Relevés illisibles.'), { retry: () => load(false) });
    });
  }

  function paint() {
    const current = host.querySelector('[data-card="current"]');
    const offer = host.querySelector('[data-card="offer"]');
    current.removeAttribute('aria-busy');
    offer.removeAttribute('aria-busy');
    repaint(current, currentMarkup(view));
    repaint(offer, offerMarkup(view));
    host.querySelector('[data-runs-note]').textContent = view.note;
    paintRows();
  }

  function paintRows() {
    if (!view) return;
    const all = view.rows ?? [];
    filters.setFacets(FACETS.map((f) => ({ ...f, pressed: pressed.has(f.id), count: all.filter((r) => (f.id === 'problems' ? r.status === 'partial' || r.status === 'error' : r.family === f.id)).length })));
    const types = ['directory', 'presence', 'inventory'].filter((t) => pressed.has(t));
    const rows = all.filter((r) => (!types.length || types.includes(r.family)) && (!pressed.has('problems') || r.status === 'partial' || r.status === 'error'));
    grid.setRows(rows, { keepSelection: true, keepScroll: true });
    filters.setSummary(`${count(rows.length, 'relevé', 'relevés')} sur ${int(all.length)}`);
  }

  async function act(what, button) {
    if (busy) return;
    const offer = view?.offer;
    try {
      busy = true;
      button?.setAttribute('aria-busy', 'true');
      if (what === 'resume' && offer?.resumable) {
        const ok = await confirmDialog({
          title: 'Reprendre le relevé interrompu ?',
          message: `${count(offer.remaining, 'poste restant', 'postes restants')} de l’OU ${offer.scopeName} (${offer.type}) seront lus${NBSP}; les autres ne sont pas relus. Les mesures déjà enregistrées restent. Le relevé peut être arrêté à tout moment.`,
          confirmLabel: `Lire ${count(offer.remaining, 'poste', 'postes')}`,
          icon: 'wifi',
        });
        if (!ok) return;
        const state = await ctx.call('operations.survey.resume', { remaining: offer.remaining, ...(offer.resumeToken ? { token: offer.resumeToken } : {}) });
        toast(`Relevé repris${NBSP}: ${state.type} · ${state.scopeName}, ${count(state.total, 'poste', 'postes')} à lire.`, { tone: 'info' });
      } else if (what === 'stop') {
        const state = await ctx.call('operations.survey.stop');
        if (state) toast(`Arrêt demandé${NBSP}: les mesures reçues sont gardées, les postes restants seront proposés de nouveau.`, { tone: 'warn', life: 6000 });
      } else if (what === 'forget' && offer?.resumable) {
        const ok = await confirmDialog({
          title: 'Abandonner le relevé interrompu ?',
          message: `Le relevé de l’OU ${offer.scopeName} ne sera plus proposé. Les ${int(offer.total - offer.remaining)} mesures déjà lues restent dans la base locale.`,
          confirmLabel: 'Abandonner', danger: true,
        });
        if (!ok) return;
        await ctx.call('operations.survey.forget');
        toast(`Relevé abandonné${NBSP}: les mesures déjà lues restent.`, { tone: 'info' });
      } else if (what === 'later') {
        await ctx.call('operations.survey.postpone');
        announce('Reprise remise à plus tard. Elle reste proposée dans Relevés.');
      }
      await load(true);
    } catch (err) {
      console.error(err);
      toast(errorText(err, 'Action impossible.'), { tone: 'alert', life: 6500 });
    } finally {
      busy = false;
      button?.removeAttribute('aria-busy');
    }
  }

  load(false);
  return {
    refresh: (silent = true) => load(silent),
    running: () => view?.current?.open === true,
    resume: () => act('resume', null),
    destroy() { alive = false; grid.destroy(); filters.destroy?.(); },
  };
}

function ring(p) {
  const pct = Math.max(0, Math.min(100, p * 100));
  return `<svg class="op-ring" viewBox="0 0 120 120" aria-hidden="true"><circle class="op-ring-track" cx="60" cy="60" r="50" pathLength="100"/>
    <circle class="op-ring-fill" cx="60" cy="60" r="50" pathLength="100" stroke-dasharray="${pct.toFixed(1)} 100"/></svg>`;
}

function currentMarkup(view) {
  const s = view.current;
  if (!view.available) {
    return `${cardHead('wifi', 'Relevé en cours', '')}${emptyState('wifi', 'Relevés non branchés', view.note)}`;
  }
  if (!s || !s.open) {
    const ended = s && !s.open
      ? `<p class="op-survey-ended">${glyph(s.phase === 'done' ? 'check' : 'info')}<span>Dernier lot${NBSP}: ${esc(s.type)} · ${esc(s.scopeName)} — ${esc(s.phaseLabel)}, ${esc(s.status)}</span></p>`
      : '';
    return `${cardHead('wifi', 'Relevé en cours', 'Actualisation d’OU ou relevé de liste')}${emptyState('check', 'Aucun relevé en cours', 'Un relevé lancé depuis un écran apparaît ici avec sa progression et son arrêt.')}${ended}`;
  }
  const p = s.total ? s.done / s.total : 0;
  const order = [['preparing', 'Préparation'], ['readingDirectory', 'Lecture AD'], ['confirming', 'À confirmer'], ['running', 'En cours'], ['saving', 'Enregistrement']];
  const at = s.phase === 'stopping' ? 3 : order.findIndex(([code]) => code === s.phase);
  const steps = order.map(([code, label], n) => `<li data-state="${n < at ? 'done' : n === at ? 'current' : 'todo'}" data-i="${n}"><span class="op-batch-dot" aria-hidden="true">${n < at ? glyph('check') : ''}</span><span>${esc(label)}</span></li>`).join('');
  const counters = [['Non confirmés', s.failed], ['Erreurs de ping', s.pingErrors], ['En cours', s.inFlight], ['Enregistrements en attente', s.pendingSaves], ['Non relus faute de capacité', s.skipped]]
    .map(([label, value]) => `<li data-zero="${Number(value ?? 0) === 0}"><b>${esc(int(value ?? 0))}</b><span>${esc(label)}</span></li>`).join('');
  return `${cardHead('wifi', 'Relevé en cours', `${s.type} · ${s.scopeName}`, pill(s.stopRequested ? 'warn' : 'info', s.phaseLabel, { spin: !s.stopRequested, size: 'sm' }))}
    <div class="op-batch op-survey-batch"><ol class="op-batch-steps" aria-label="Phases du relevé">${steps}</ol><ul class="op-batch-counters" aria-label="Compteurs du relevé">${counters}</ul></div>
    <div class="op-survey">
      <div class="op-survey-ring" data-phase="${esc(s.phase)}">${ring(p)}<div class="op-survey-center"><b>${int(s.done)}<small>/${int(s.total)}</small></b><span>postes</span></div></div>
      <div class="op-survey-text">
        <p>${esc(s.status)}</p>
        <dl class="op-facts compact"><div><dt>Lancé le</dt><dd>${esc(fullDate(s.startedAt))}</dd></div><div><dt>Postes du lot</dt><dd>${int(s.total)}</dd></div></dl>
        <div class="op-survey-actions"><button class="btn subtle sm" type="button" data-run-act="stop"${s.stopRequested ? ' disabled' : ''}>${glyph('pause')}${s.stopRequested ? 'Arrêt demandé' : 'Arrêter le relevé'}</button></div>
      </div>
    </div>`;
}

function offerMarkup(view) {
  const o = view.offer;
  if (!view.available || !o) {
    return `${cardHead('history', 'Relevé interrompu', '')}${emptyState('history', 'Aucune reprise possible', view.available ? 'Aucun relevé interrompu à reprendre.' : 'La reprise des relevés arrive avec la collecte (vague 3).')}`;
  }
  if (!o.resumable) {
    return `${cardHead('history', 'Relevé interrompu', 'Reprise d’un relevé arrêté ou interrompu')}${emptyState('check', 'Rien à reprendre', o.reason)}`;
  }
  const read = o.total - o.remaining;
  const p = o.total ? read / o.total : 0;
  return `${cardHead('history', 'Relevé interrompu', `${o.type} · ${o.scopeName}`, pill('warn', `${int(o.remaining)} restant${o.remaining > 1 ? 's' : ''}`, { icon: 'pause', size: 'sm' }))}
    <div class="op-offer">
      <div class="op-offer-bar" role="progressbar" aria-label="Postes déjà lus" aria-valuemin="0" aria-valuemax="${o.total}" aria-valuenow="${read}">
        <svg viewBox="0 0 100 10" preserveAspectRatio="none" aria-hidden="true"><rect class="op-offer-bg" width="100" height="10" rx="5"/><rect class="op-offer-fg" width="${(p * 100).toFixed(1)}" height="10" rx="5"/></svg>
        <span>${int(read)} lus sur ${int(o.total)}</span></div>
      <p>${esc(o.reason)}</p>
      <div class="op-offer-actions">
        <button class="btn primary sm" type="button" data-run-act="resume">${glyph('play')}Reprendre…</button>
        <button class="btn subtle sm" type="button" data-run-act="forget">${glyph('x')}Abandonner…</button>
        ${o.offered ? '' : `<button class="btn ghost sm" type="button" data-run-act="later">${glyph('clock')}Plus tard</button>`}
      </div>
    </div>`;
}
