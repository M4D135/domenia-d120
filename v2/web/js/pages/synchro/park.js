// « Parc » workspace (Domenia 1 points 9, 28 to 30): park survey kept by the base (last probe, status, user seen, attempts),
// its coverage, the survey shared between consoles (read and merged on request, the most recent line wins, written back
// under a lock after confirmation) and « Oublier les relevés » (scanning state only, after a verified backup).
import { createGrid, confirmDialog } from '../../kit/index.js';
import { runWrite } from '../../write-flow.js';
import {
  esc, icon, glyph, pill, int, count, NBSP, toneOf, cardHead, button, paint, ago, errorBlock, skStack, errorText, setVars,
} from './common.js';

const STATUS = {
  session: { label: 'Session ouverte', tone: 'ok', icon: 'user' },
  empty: { label: 'Aucune session', tone: 'info', icon: 'monitor' },
  unreachable: { label: 'Injoignable', tone: 'warn', icon: 'wifiOff' },
  refused: { label: 'Accès refusé', tone: 'alert', icon: 'lock' },
  error: { label: 'Erreur de relevé', tone: 'alert', icon: 'alert' },
};

const COLUMNS = [
  { id: 'computer', label: 'Poste', required: true, width: 170, mono: true },
  { id: 'status', label: 'Statut', type: 'enum', width: 170, options: Object.entries(STATUS).map(([value, s]) => ({ value, label: s.label, tone: s.tone })) },
  { id: 'user', label: 'Utilisateur vu', width: 170, mono: true },
  { id: 'lastProbe', label: 'Dernier passage', type: 'date', width: 190 },
  { id: 'attempts', label: 'Tentatives', type: 'number', width: 140, align: 'end' },
  { id: 'probedBy', label: 'Relevé par', width: 200 },
];

function coverageMarkup(c) {
  const pct = Number.isFinite(c.percent) ? c.percent : null;
  const tone = pct === null ? 'off' : pct >= 70 ? 'ok' : pct >= 40 ? 'warn' : 'alert';
  return `<div class="sy-park-cover">
      <div class="sy-ring" data-tone="${tone}" role="img" aria-label="${esc(pct === null ? 'Couverture non mesurée' : `Couverture du relevé${NBSP}: ${int(Math.round(pct))}${NBSP}%`)}">
        <span class="sy-ring-track" aria-hidden="true"></span><span class="sy-ring-arc" data-ring="${pct === null ? 0 : (pct / 100).toFixed(3)}" aria-hidden="true"></span>
        <span class="sy-ring-center"><b>${pct === null ? '—' : `${int(Math.round(pct))}${NBSP}%`}</b><small>des postes actifs</small></span>
      </div>
      <dl class="sy-park-stats">
        <div><dt>Postes actifs</dt><dd>${c.machines >= 0 ? int(c.machines) : '—'}</dd></div>
        <div><dt>Relevés</dt><dd>${int(c.surveyed)}</dd></div>
        <div><dt>Avec un utilisateur connu</dt><dd>${int(c.withSession)}</dd></div>
        <div><dt>Écartés faute d’activité</dt><dd>${int(c.dormants)}</dd></div>
        <div><dt>Dernier passage</dt><dd>${ago(c.latestAt)}</dd></div>
      </dl>
    </div>
    <p class="sy-muted">${icon('info')}<span>${esc(c.text)}</span></p>`;
}

function distributionMarkup(rows) {
  const counts = Object.keys(STATUS).map((k) => [k, rows.filter((r) => r.status === k).length]).filter(([, n]) => n > 0);
  const total = Math.max(1, counts.reduce((s, [, n]) => s + n, 0));
  return `<div class="sy-bar tall" role="img" aria-label="${esc(counts.map(([k, n]) => `${STATUS[k].label} ${n}`).join(', '))}">${counts.map(([k, n]) => `<span class="sy-bar-seg" data-tone="${STATUS[k].tone}" data-grow="${n}" data-tip="${esc(`${STATUS[k].label}${NBSP}: ${int(n)} (${Math.round((100 * n) / total)}${NBSP}%)`)}"></span>`).join('')}</div>
    <div class="sy-facets" role="group" aria-label="Filtrer par statut">${counts.map(([k, n]) => `<button class="sy-facet" type="button" data-pk="facet" data-status="${k}" data-tone="${STATUS[k].tone}" aria-pressed="false">${glyph(STATUS[k].icon)}<span>${esc(STATUS[k].label)}</span><b>${int(n)}</b></button>`).join('')}</div>`;
}

function sharedMarkup(s) {
  return `<div class="sy-shared">
      <div class="sy-shared-path"><span class="sy-shared-ico">${glyph('folder')}</span><div><b class="mono">${esc(s.path ?? 'Aucun chemin configuré')}</b><small>${s.lastSyncAt ? `Dernière synchronisation ${esc(new Date(s.lastSyncAt).toLocaleString('fr-FR', { dateStyle: 'medium', timeStyle: 'short' }))}` : 'Jamais synchronisé'}</small></div></div>
      <p class="sy-muted" title="${esc(s.text)}">${icon('info')}<span>${s.configured ? 'Lecture et fusion sous verrou (fichier .lock, 12 essais)\u00A0: pour chaque poste, la ligne la plus récente gagne. Rien n’est écrit avant votre confirmation.' : esc(s.text)}</span></p>
      <div class="sy-card-actions">${button('Lire le relevé partagé…', { icon: 'download', kind: 'network', data: { pk: 'shared' }, disabled: !s.configured || !s.canSync, tip: s.configured ? 'Lit et fusionne en mémoire le fichier partagé (verrou, 12 essais)\u00A0; rien n’est écrit avant votre confirmation.' : 'Aucun relevé partagé configuré.' })}</div>
      <div class="sy-job" data-job="shared" hidden></div>
    </div>`;
}

function sharedResultMarkup(r) {
  const rows = r.rows.slice(0, 24).map((x, n) => `<li data-i="${Math.min(n, 18)}" data-tone="${x.winner === 'shared' ? 'info' : 'ok'}"><span class="sy-res-ico">${glyph(x.winner === 'shared' ? 'arrowDown' : 'arrowUp')}</span><div><b class="mono">${esc(x.computer)}</b><p>${esc(x.detail)}</p></div></li>`).join('');
  return `<div class="sy-result-card">
      <div class="sy-job-head"><span class="sy-run-badge pop sm" data-tone="ok">${glyph('check')}</span><b>Partage lu · ${esc(`verrou obtenu au ${r.lockAttempts}e essai`)}</b></div>
      <ul class="sy-res-chips"><li data-tone="info">${glyph('download')}<b>${int(r.received)}</b><span>Lignes reçues</span></li><li data-tone="ok">${glyph('plus')}<b>${int(r.added)}</b><span>Postes ajoutés</span></li><li data-tone="accent">${glyph('refresh')}<b>${int(r.updated)}</b><span>Relevés actualisés</span></li><li data-tone="off">${glyph('layers')}<b>${int(r.kept)}</b><span>À partager</span></li></ul>
      <p class="sy-muted">${icon('info')}<span>${esc(r.text)}</span></p>
      ${rows ? `<details class="sy-res-details"><summary>${glyph('eye')}${esc(`${count(r.rows.length, 'poste diffère', 'postes diffèrent')} entre les deux relevés`)}</summary><ul class="sy-res-list">${rows}</ul></details>` : ''}
      <div class="sy-card-actions">${button('Ignorer', { ghost: true, sm: true, data: { pk: 'dismiss' } })}${button('Fusionner et écrire…', { icon: 'database', primary: true, kind: 'write', data: { pk: 'merge' }, disabled: !r.storable })}</div>
    </div>`;
}

/** Renders the workspace in its panel; returns its cleanup. */
export function renderPark(panel, screen) {
  const ctx = screen.ctx;
  panel.classList.add('sy-ws', 'sy-ws-park');
  let alive = true;
  let data = null;
  let filter = null;
  let shared = null;
  panel.innerHTML = `<div class="sy-ws-grid">
      <section class="sy-card span-5" data-slot="coverage" data-i="0">${cardHead('gauge', 'Couverture du relevé', 'Relevé stocké, sans comptage synchrone')}<div class="sy-slot">${skStack('sk-ring', 'sk-line w70')}</div></section>
      <section class="sy-card span-7" data-slot="shared" data-i="1">${cardHead('folder', 'Relevé partagé entre consoles', 'Le travail est fait une fois pour toutes les consoles')}<div class="sy-slot">${skStack('sk-line w85', 'sk-line w55')}</div></section>
      <section class="sy-card span-12" data-slot="rows" data-i="2">
        ${cardHead('monitor', 'Postes relevés', 'Dernier passage, statut, utilisateur vu et tentatives enregistrés dans la base', button('Relire', { sm: true, ghost: true, icon: 'refresh', data: { pk: 'reload' }, tip: 'Relit le relevé dans la base locale\u00A0; aucune sonde.' }))}
        <div class="sy-dist" data-slot="dist"></div>
        <div class="sy-park-grid"></div>
      </section>
      <section class="sy-card sy-danger span-12" data-i="3">
        <div class="sy-danger-row"><span class="sy-danger-ico">${glyph('trash')}</span>
          <div><h3>Oublier les relevés</h3><p>Efface l’état de balayage du parc de cette base (dernier passage, statut, tentatives), après une sauvegarde vérifiée. Les associations, les observations et l’historique sont conservés${NBSP}; le prochain relevé repartira de zéro.</p></div>
          ${button('Oublier les relevés…', { danger: true, icon: 'trash', kind: 'write', data: { pk: 'reset' } })}</div>
      </section>
    </div>`;
  const grid = createGrid(panel.querySelector('.sy-park-grid'), {
    key: 'synchro.park',
    label: 'Postes du relevé du parc',
    rowId: (r) => r.key,
    selection: 'single',
    loading: true,
    height: '420px',
    columns: COLUMNS,
    empty: { icon: 'monitor', title: 'Aucun relevé du parc', text: 'Les relevés des postes (console, session) apparaîtront ici après une détection ou une moisson du journal.' },
  });

  async function load() {
    try {
      data = await ctx.call('synchro.park.state', {});
      if (!alive) return;
      panel.querySelector('[data-slot="coverage"] .sy-slot').innerHTML = coverageMarkup(data.coverage);
      panel.querySelector('[data-slot="shared"] .sy-slot').innerHTML = sharedMarkup(data.shared);
      panel.querySelector('[data-slot="dist"]').innerHTML = data.rows.length ? distributionMarkup(data.rows) : '';
      grid.setRows(filter ? data.rows.filter((r) => r.status === filter) : data.rows);
      const reset = panel.querySelector('[data-pk="reset"]');
      reset.disabled = data.rows.length === 0;
      reset.dataset.tip = data.rows.length ? `Plan de l’oubli de ${count(data.rows.length, 'relevé', 'relevés')}, à confirmer.` : 'Aucun relevé à oublier.';
      const arc = panel.querySelector('[data-ring]');
      if (arc) setVars(arc, { '--p': arc.dataset.ring });
      if (shared) showShared(shared);
      paint(panel);
    } catch (err) {
      console.error(err);
      if (!alive) return;
      panel.querySelector('[data-slot="coverage"] .sy-slot').innerHTML = errorBlock(err);
      grid.setError(errorText(err), { retry: load });
    }
  }

  function showShared(r) {
    const host = panel.querySelector('[data-job="shared"]');
    if (!host) return;
    host.hidden = false;
    host.innerHTML = sharedResultMarkup(r);
    paint(host);
  }

  async function readShared() {
    const ok = await confirmDialog({
      title: 'Lire le relevé partagé',
      message: `Le fichier partagé ${data?.shared?.path ?? ''} sera lu sous verrou (fichier .lock, 12 essais) puis fusionné en mémoire avec le relevé de cette base${NBSP}: la ligne la plus récente gagne par poste. Rien n’est écrit avant votre confirmation.`,
      confirmLabel: 'Lire le partage',
      icon: 'folder',
    });
    if (!ok || !alive) return;
    const host = panel.querySelector('[data-job="shared"]');
    host.hidden = false;
    host.innerHTML = `<div class="sy-job-card" aria-busy="true"><div class="sy-job-head"><span class="sy-run-badge spin sm" data-tone="info">${icon('sync')}</span><b>Lecture du relevé partagé…</b>${pill('info', 'En cours', { size: 'sm', pulse: true })}</div><div class="sy-meter indeterminate"><span data-fill="0.35"></span></div></div>`;
    paint(host);
    try {
      shared = await ctx.call('synchro.park.shared.read', {});
      if (!alive) return;
      showShared(shared);
    } catch (err) {
      console.error(err);
      host.innerHTML = errorBlock(err, false);
    }
  }

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-pk], [data-retry]') : null;
    if (!t || t.disabled) return;
    if (t.dataset.retry !== undefined) { load(); return; }
    const act = t.dataset.pk;
    if (act === 'reload') load();
    else if (act === 'facet') {
      filter = filter === t.dataset.status ? null : t.dataset.status;
      panel.querySelectorAll('[data-pk="facet"]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.status === filter)));
      grid.setRows(filter ? data.rows.filter((r) => r.status === filter) : data.rows);
    } else if (act === 'shared') readShared();
    else if (act === 'dismiss') { shared = null; const h = panel.querySelector('[data-job="shared"]'); h.hidden = true; h.innerHTML = ''; }
    else if (act === 'merge' && shared) {
      runWrite(ctx, { plan: 'synchro.store.plan', args: { batchId: shared.batchId }, subtitle: 'Relevé du parc · partage', onDone: () => { shared = null; screen.emit('stored', { kind: 'park' }); load(); } });
    } else if (act === 'reset') {
      runWrite(ctx, { plan: 'synchro.park.reset.plan', args: {}, subtitle: 'Relevé du parc', onDone: () => { screen.emit('stored', { kind: 'park' }); load(); } });
    }
  };
  panel.addEventListener('click', onClick);
  load();

  return () => {
    alive = false;
    panel.removeEventListener('click', onClick);
    grid.destroy();
  };
}

void toneOf;
