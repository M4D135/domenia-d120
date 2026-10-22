// Tab « Statistiques » (Domenia 1 OPE-002): one row per operation of the bridge with its measures (session and, when the source
// keeps them, earlier sessions): count, average and median duration, 95th percentile, time per item, estimated network volume,
// throughput, fallback rate and remote attempts (Domenia 1 Complete-DomeniaOperationStatsUi), success rate, last run; exportable
// in CSV. A column with nothing measured stays empty, never 0. The grid runs no action.
import { esc, errorText, toast } from '../../ui.js';
import { createGrid, glyph, writeClipboard, NBSP } from '../../kit/index.js';
import { duration, count, int, cardHead } from './common.js';

const KIND_OPTIONS = [
  { value: 'local', label: 'Calcul local', tone: 'off' },
  { value: 'localRead', label: 'Lecture locale', tone: 'info' },
  { value: 'networkRead', label: 'Lecture réseau', tone: 'info' },
  { value: 'localWrite', label: 'Écriture locale', tone: 'ok' },
  { value: 'write', label: 'Écriture', tone: 'warn' },
  { value: 'batch', label: 'Lot de collecte', tone: 'info' },
];
const ms = (v) => (Number.isFinite(v) ? duration(v) : '—');

/** « 820 o », « 12,4 ko », « 3,1 Mo » (Domenia 1 Format-DomeniaByteEstimate), or « — » when not measured. */
function bytes(v) {
  if (!Number.isFinite(v)) return '—';
  if (v < 1024) return `${int(Math.round(v))}${NBSP}o`;
  if (v < 1024 * 1024) return `${(v / 1024).toLocaleString('fr-FR', { maximumFractionDigits: 1 })}${NBSP}ko`;
  return `${(v / (1024 * 1024)).toLocaleString('fr-FR', { maximumFractionDigits: 1 })}${NBSP}Mo`;
}

/** Throughput like Domenia 1: « 1,25 Mbit/s » from 125 000 octets per second, « 64,0 kbit/s » below. */
function bandwidth(v) {
  if (!Number.isFinite(v) || v <= 0) return '—';
  return v >= 125_000
    ? `${((v * 8) / 1_000_000).toLocaleString('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}${NBSP}Mbit/s`
    : `${((v * 8) / 1000).toLocaleString('fr-FR', { minimumFractionDigits: 1, maximumFractionDigits: 1 })}${NBSP}kbit/s`;
}

const COLUMNS = [
  { id: 'label', label: 'Opération', width: 210, required: true, html: (v, r) => `<span data-tip="${esc(r.operation)}">${esc(v)}</span>` },
  { id: 'operation', label: 'Code', width: 220, mono: true, hidden: true },
  { id: 'kind', label: 'Type', type: 'enum', width: 132, options: KIND_OPTIONS },
  { id: 'samples', label: 'Mesures', type: 'number', width: 116, align: 'end', format: (v) => int(v) },
  { id: 'sessionSamples', label: 'Cette session', type: 'number', width: 130, align: 'end', format: (v) => int(v), hidden: true },
  { id: 'averageMs', label: 'Moyenne', type: 'number', width: 118, tip: 'Durée moyenne d’une exécution.', align: 'end', format: ms },
  { id: 'medianMs', label: 'Médiane', type: 'number', width: 116, align: 'end', format: ms },
  { id: 'p95Ms', label: '95e centile', type: 'number', width: 128, align: 'end', format: ms, tip: 'Affiché à partir de 20 mesures.' },
  { id: 'perItemMs', label: 'Par élément', type: 'number', width: 136, align: 'end', format: ms },
  { id: 'averageItems', label: 'Volume moyen', type: 'number', width: 120, align: 'end', format: (v) => (Number.isFinite(v) ? v.toLocaleString('fr-FR', { maximumFractionDigits: 1 }) : '—'), hidden: true },
  {
    id: 'successPercent', label: 'Réussite', type: 'number', width: 112, align: 'end',
    // An SVG width attribute (no style, no CSS variable): the rows of the virtual grid are drawn as they scroll in.
    html: (v) => (Number.isFinite(v)
      ? `<span class="op-rate" data-tone="${v >= 95 ? 'ok' : v >= 80 ? 'warn' : 'alert'}"><svg viewBox="0 0 100 6" preserveAspectRatio="none" aria-hidden="true"><rect class="op-rate-bg" width="100" height="6" rx="3"/><rect class="op-rate-fg" width="${Math.max(0, Math.min(100, v)).toFixed(1)}" height="6" rx="3"/></svg><b>${v.toLocaleString('fr-FR', { maximumFractionDigits: 1 })}${NBSP}%</b></span>`
      : '—'),
    csv: (v) => (Number.isFinite(v) ? String(v).replace('.', ',') : ''),
  },
  { id: 'averageBytes', label: 'Réseau (estimé)', type: 'number', width: 140, align: 'end', format: bytes, tip: 'Volume moyen reçu par une lecture distante ou une écriture, estimé d’après la taille de sa réponse.', csv: (v) => (Number.isFinite(v) ? String(Math.round(v)) : '') },
  { id: 'bytesPerSecond', label: 'Débit', type: 'number', width: 122, align: 'end', format: bandwidth, csv: (v) => (Number.isFinite(v) ? String(Math.round(v)) : '') },
  { id: 'fallbackPercent', label: '% de repli', type: 'number', width: 116, align: 'end', format: (v) => (Number.isFinite(v) ? `${v.toLocaleString('fr-FR', { maximumFractionDigits: 1 })}${NBSP}%` : '—'), tip: 'Transports de repli sur les tentatives distantes : Domenia 2 n’en utilise aucun.', csv: (v) => (Number.isFinite(v) ? String(v).replace('.', ',') : '') },
  { id: 'remoteAttempts', label: 'Tentatives distantes', type: 'number', width: 160, align: 'end', format: (v) => (v > 0 ? int(v) : '—'), tip: 'Requêtes parties vers l’annuaire ou un poste ; jamais de nouvelle tentative automatique.' },
  { id: 'lastRun', label: 'Dernière', type: 'date', width: 108 },
];

/**
 * @param {HTMLElement} host
 * @param {{ ctx: any, demo: boolean }} env
 */
export function createStats(host, env) {
  const { ctx } = env;
  let alive = true;
  host.innerHTML = `<section class="card op-stats-card">
      ${cardHead('layers', 'Statistiques des opérations', 'Mesures de chaque opération du pont', '<span data-stats-sum></span>')}
      <div class="op-stats-grid"></div>
      <p class="op-note" data-stats-note></p>
    </section>`;
  const grid = createGrid(host.querySelector('.op-stats-grid'), {
    key: 'operations.statistiques',
    label: 'Statistiques des opérations',
    rowId: (r) => r.operation,
    selection: 'single',
    loading: true,
    height: '520px',
    columns: COLUMNS,
    quickPlaceholder: 'Filtrer les opérations…',
    empty: { icon: 'layers', title: 'Aucune mesure pour l’instant', text: 'Chaque opération ajoute une mesure à sa fin.' },
    onExport: (csv, info) => {
      if (env.demo) { writeClipboard(csv).then(() => toast(`Exemple local${NBSP}: CSV copié, rien n’est enregistré.`, { tone: 'info' })); return; }
      ctx.call('operations.export.save', { subject: 'statistiques', csv }).then((r) => toast(r.saved ? `${count(info.rows, 'ligne exportée', 'lignes exportées')}${NBSP}: ${r.name}` : r.message, { tone: r.saved ? 'ok' : 'info', life: 6000 }))
        .catch((err) => toast(`Export impossible${NBSP}: ${errorText(err)}`, { tone: 'alert' }));
    },
  });
  const refresh = document.createElement('button');
  refresh.type = 'button';
  refresh.className = 'btn sm subtle';
  refresh.innerHTML = `${glyph('refresh')}Actualiser`;
  refresh.addEventListener('click', () => load(false));
  grid.slot.append(refresh);

  function load(silent = false) {
    if (!silent) grid.setLoading(true);
    return ctx.call('operations.stats').then((stats) => {
      if (!alive) return;
      host.querySelector('[data-stats-sum]').textContent = stats.summary;
      host.querySelector('[data-stats-note]').textContent = stats.note;
      grid.setRows(stats.rows, { keepSelection: true, keepScroll: true });
    }).catch((err) => {
      console.error(err);
      if (!alive) return;
      grid.setError(errorText(err, 'Statistiques illisibles.'), { retry: () => load(false) });
    });
  }

  load(false);
  return { refresh: load, destroy() { alive = false; grid.destroy(); } };
}
