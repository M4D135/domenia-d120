// « Sondes et relevés » of the workstation console: the fifteen interpreted readings of Domenia 1 built from the probes
// stored for the workstation (catalog of 33 probes), each with its date and freshness; the forecast of the system volume
// drawn with its history; the approved BIOS version of the model; the details of one probe in a side panel. Reading the
// stored values never queries the workstation; « Actualiser les sondes » reads them once, on its button.
import { openDrawer, createGrid } from '../../kit/index.js';
import {
  esc, ico, rel, facts, cardHead, empty, failure, chip, scoreRing, paintMeters, progressMarkup, setProgress, NBSP, int, size, errorText, formatDateTime,
} from './common.js';
import { reveal as revealCards, toast, measureDraw } from '../../ui.js';

const STATE_TONE = { read: 'ok', partial: 'warn', refused: 'alert', absent: 'off', failed: 'warn', notRead: 'off' };

export function renderReadings(panel, state) {
  let alive = true;
  let data = null;
  panel.classList.add('ps-readings');
  panel.innerHTML = `<div class="ps-grid"><section class="card ps-card span-12 reveal" data-slot="head" aria-busy="true">${cardHead('probe', 'Sondes et relevés', 'Lecture des relevés enregistrés…')}</section><div class="span-12" data-slot="body"></div></div>`;

  const paint = () => {
    if (!data) return;
    const head = panel.querySelector('[data-slot="head"]');
    head.removeAttribute('aria-busy');
    const total = data.readings.length;
    const fresh = Math.round((data.fresh / Math.max(1, total)) * 100);
    head.innerHTML = `<div class="ps-read-head">
      <div class="ps-read-ring">${scoreRing(fresh, data.stale > 0 ? 'warn' : data.unread > total / 2 ? 'off' : 'ok', `${data.fresh} lectures récentes sur ${total}`, { text: `${int(data.fresh)}/${int(total)}`, unit: 'récentes' })}</div>
      <div class="ps-read-text"><h3>Relevés datés du poste</h3><p>${esc(data.summary)}</p>
        <div class="ps-read-chips">${chip(data.fresh ? 'ok' : '', `${int(data.fresh)} récente(s)`)}${chip(data.aging ? 'warn' : '', `${int(data.aging)} vieillissante(s)`)}${chip(data.stale ? 'alert' : '', `${int(data.stale)} périmée(s)`)}${chip('', `${int(data.unread)} non lue(s)`)}
          ${data.collectedAt ? `<span class="ps-faint">Dernier relevé ${rel(data.collectedAt)}</span>` : ''}</div></div>
      <div class="ps-read-actions"><button class="btn primary" type="button" data-act="collect">${ico('refresh')}Actualiser les sondes</button>
        <button class="btn ghost" type="button" data-act="stop" hidden>${ico('pause')}Arrêter</button>
        <button class="btn" type="button" data-act="catalog">${ico('database')}Catalogue des sondes</button></div></div>
      <div data-slot="progress" hidden>${progressMarkup()}</div>`;
    paintMeters(head);
    const body = panel.querySelector('[data-slot="body"]');
    const forecast = data.readings.find((r) => r.id === 'volumes')?.forecast;
    body.innerHTML = `${forecast ? forecastCard(forecast) : ''}<div class="ps-read-grid">${data.readings.map(card).join('')}</div>`;
    paintMeters(body);
    measureDraw(body);
    revealCards(panel);
  };

  async function load() {
    try {
      data = await state.call('poste.readings', { dn: state.dn });
      if (alive) paint();
    } catch (err) {
      if (!alive) return;
      const head = panel.querySelector('[data-slot="head"]');
      head.removeAttribute('aria-busy');
      head.innerHTML = failure(err, { retry: 'reload' });
    }
  }

  async function collect() {
    const progress = panel.querySelector('[data-slot="progress"]');
    progress.hidden = false;
    panel.querySelector('[data-act="collect"]').disabled = true;
    panel.querySelector('[data-act="stop"]').hidden = false;
    const stop = state.progress('poste.probes.collect', (p) => setProgress(progress, p));
    try {
      data = await state.call('poste.probes.collect', { dn: state.dn });
      if (!alive) return;
      paint();
      toast(`Sondes relevées sur ${state.data.computer.name}.`, { tone: 'ok' });
    } catch (err) {
      if (!alive) return;
      toast(errorText(err), { tone: err?.code === 'poste.cancelled' ? 'info' : 'warn' });
      paint();
    } finally {
      stop();
    }
  }

  async function bios(action) {
    try {
      data = await state.call('poste.bios.reference', { dn: state.dn, action });
      if (!alive) return;
      paint();
      toast(action === 'approve' ? 'Version BIOS approuvée pour ce modèle (réglage local du domaine).' : 'Référence BIOS du modèle retirée.', { tone: 'ok' });
    } catch (err) {
      toast(errorText(err), { tone: 'warn' });
    }
  }

  panel.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-act],[data-probe]') : null;
    if (!t || !panel.contains(t)) return;
    if (t.dataset.probe) { openProbe(state, t.dataset.probe); return; }
    const act = t.dataset.act;
    if (act === 'collect') collect();
    else if (act === 'reload') load();
    else if (act === 'stop') state.call('poste.collect.stop', { dn: state.dn }).then((r) => toast(r.text, { tone: 'info' }));
    else if (act === 'catalog') openCatalog(data);
    else if (act === 'approve' || act === 'remove') bios(act);
  });
  load().then(() => { if (state.essai === 'sondes' && alive) collect(); });
  return () => { alive = false; };
}

function card(r, n) {
  const probes = r.probes.map((p) => `<button class="ps-probe" type="button" data-probe="${esc(p.id)}" data-tone="${STATE_TONE[p.state] ?? 'off'}" data-tip="${esc(`${p.name} · ${p.stateLabel}${p.lastSuccess ? ` · ${formatDateTime(p.lastSuccess)}` : ''}`)}"><span class="ps-dot" data-tone="${STATE_TONE[p.state] ?? 'off'}" aria-hidden="true"></span><span class="mono">${esc(p.id)}</span></button>`).join('');
  const bios = r.bios ? `<div class="ps-bios" data-tone="${esc(r.bios.tone)}"><div><b>${esc(modelLabel(r.bios.manufacturer, r.bios.model))}</b><span>Version lue ${esc(r.bios.observed)}${r.bios.reference ? ` · approuvée ${esc(r.bios.reference)}` : ''}</span></div>
      <div class="ps-row-actions">${r.bios.canApprove ? `<button class="btn sm" type="button" data-act="approve" data-tip="Réglage local du domaine : aucune action sur le poste">${ico('check')}Approuver cette version pour ce modèle</button>` : ''}
      ${r.bios.canRemove ? `<button class="btn ghost sm" type="button" data-act="remove">${ico('x')}Retirer la référence du modèle</button>` : ''}</div></div>` : '';
  return `<section class="card ps-card ps-reading reveal" data-tone="${esc(r.state)}" data-i="${n}">
    ${cardHead(r.icon, r.title, `<span class="ps-fresh" data-tone="${esc(r.state)}"><span class="ps-dot" data-tone="${esc(r.state)}" aria-hidden="true"></span>${esc(r.stateLabel)}</span>`)}
    ${facts(r.facts, { compact: true })}${bios}
    <div class="ps-probes" aria-label="Sondes lues">${probes}</div></section>`;
}

/** Maker and model once (« HP EliteDesk », not « HP HP EliteDesk »), as PosteText.Model on the engine side. */
function modelLabel(maker, model) {
  const brand = String(maker ?? '').trim().split(' ')[0].replace(/[,.]$/, '');
  const name = String(model ?? '').trim();
  return !brand || name.toLowerCase().startsWith(brand.toLowerCase()) ? name : `${maker} ${name}`.trim();
}

/** The forecast of the system volume: stored samples, regression line and saturation, drawn in SVG (no external chart). */
function forecastCard(f) {
  const samples = f.samples ?? [];
  let chart = '';
  if (samples.length >= 2) {
    const W = 1180; const H = 230; const P = 30;
    const t0 = Date.parse(samples[0].at);
    const tEnd = f.saturationAt && f.status === 'Forecast' ? Date.parse(f.saturationAt) : Date.parse(samples[samples.length - 1].at);
    const t1 = Math.max(tEnd, Date.parse(samples[samples.length - 1].at)) || t0 + 1;
    // The free space is drawn against the size of the volume when it is known (the fill then reads as the free share).
    const maxFree = (Number.isFinite(f.sizeBytes) && f.sizeBytes > 0 ? f.sizeBytes : Math.max(...samples.map((s) => s.freeBytes)) * 1.08) || 1;
    const x = (t) => P + ((t - t0) / Math.max(1, t1 - t0)) * (W - 2 * P);
    const y = (v) => H - P - (v / maxFree) * (H - 2 * P);
    const points = samples.map((s) => `${x(Date.parse(s.at)).toFixed(1)},${y(s.freeBytes).toFixed(1)}`);
    const area = `M${points[0]} L${points.join(' L')} L${x(Date.parse(samples[samples.length - 1].at)).toFixed(1)},${H - P} L${x(t0).toFixed(1)},${H - P} Z`;
    let trend = '';
    if (Number.isFinite(f.slopeBytesPerDay) && Number.isFinite(f.interceptBytes)) {
      const at = (t) => f.interceptBytes + f.slopeBytesPerDay * ((t - t0) / 86_400_000);
      trend = `<path class="ps-fc-trend draw" d="M${x(t0).toFixed(1)},${y(Math.max(0, at(t0))).toFixed(1)} L${x(t1).toFixed(1)},${y(Math.max(0, at(t1))).toFixed(1)}"/>`;
    }
    const dots = samples.map((s, n) => `<circle class="ps-fc-dot" cx="${x(Date.parse(s.at)).toFixed(1)}" cy="${y(s.freeBytes).toFixed(1)}" r="3.2" data-i="${n}"><title>${esc(`${formatDateTime(s.at)} : ${size(s.freeBytes)} libres`)}</title></circle>`).join('');
    const sat = f.status === 'Forecast' && f.saturationAt ? `<line class="ps-fc-sat" x1="${x(tEnd).toFixed(1)}" x2="${x(tEnd).toFixed(1)}" y1="${P}" y2="${H - P}"/><text class="ps-fc-label" x="${(x(tEnd) - 6).toFixed(1)}" y="${P + 12}" text-anchor="end">saturation</text>` : '';
    chart = `<svg class="ps-fc" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(`Historique de l’espace libre de ${f.volume} : ${f.text}`)}">
      <defs><linearGradient id="ps-fc-g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" class="g0"/><stop offset="1" class="g1"/></linearGradient></defs>
      <line class="ps-fc-axis" x1="${P}" x2="${W - P}" y1="${H - P}" y2="${H - P}"/>
      <path class="ps-fc-area" d="${area}" fill="url(#ps-fc-g)"/><path class="ps-fc-line draw" d="M${points.join(' L')}"/>${trend}${sat}${dots}
      <text class="ps-fc-label" x="${P}" y="${H - 8}">${esc(formatDateTime(samples[0].at)?.slice(0, 10) ?? '')}</text>
      <text class="ps-fc-label" x="${W - P}" y="${H - 8}" text-anchor="end">${esc(formatDateTime(new Date(t1).toISOString())?.slice(0, 10) ?? '')}</text></svg>`;
  }
  return `<section class="card ps-card ps-forecast reveal" data-tone="${esc(f.tone)}">${cardHead('disk', `Prévision de saturation de ${f.volume}`, esc(f.text), chip(f.tone, f.status === 'Forecast' ? (f.daysLeft < 30 ? 'Moins de 30 jours' : 'Prévision') : f.status === 'Stable' ? 'Stable' : f.status === 'BeyondHorizon' ? 'Au-delà de deux ans' : 'Aucune prévision'))}
    ${chart || empty({ icon: 'disk', title: 'Historique insuffisant', text: 'Il faut au moins 4 relevés sur 14 jours, une taille constante et un ajustement de 0,6.' })}
    <p class="ps-faint">${int(f.count)} relevé(s) sur ${esc(String(Math.floor(f.spanDays)))} jour(s) · régression linéaire (R² ${f.fit == null ? '—' : esc(f.fit.toFixed(2).replace('.', ','))}) · horizon de deux ans · au plus un relevé toutes les 6${NBSP}h, 60 gardés.</p></section>`;
}

/** Side panel of one probe: interpreted reading, stored values (100 rows a page), contract and provenance. */
function openProbe(state, probeId) {
  const body = document.createElement('div');
  body.className = 'poste-drw ps-probe-panel';
  body.innerHTML = `<div aria-busy="true">${progressMarkup()}</div>`;
  const panel = openDrawer({ title: probeId, subtitle: 'Valeurs enregistrées · aucune requête au poste', icon: 'database', key: 'poste.probe', width: 720, minWidth: 460, maxWidth: 1100, body });
  let grid = null;
  const load = async (page) => {
    try {
      const r = await state.call('poste.probe.details', { dn: state.dn, probe: probeId, page });
      panel.setTitle(r.probe.name, `${r.probe.namespace}\\${r.probe.class} · ${r.statusLabel}`);
      body.innerHTML = `<p class="ps-verdict-line" data-tone="${STATE_TONE[r.status.state] ?? 'off'}">${ico('clock')}<span>${esc(r.provenance)}</span></p>
        ${r.interpreted.length ? `<h4 class="ps-mini-title">Lecture interprétée</h4>${facts(r.interpreted, { compact: true })}` : ''}
        <h4 class="ps-mini-title">Valeurs brutes (${int(r.total)} ligne(s), page ${int(r.page)} sur ${int(r.pages)})</h4><div data-grid></div>
        ${r.pages > 1 ? `<div class="ps-row-actions"><button class="btn sm" type="button" data-page="${r.page - 1}"${r.page <= 1 ? ' disabled' : ''}>Page précédente</button><button class="btn sm" type="button" data-page="${r.page + 1}"${r.page >= r.pages ? ' disabled' : ''}>Page suivante</button></div>` : ''}
        <details class="ps-more"><summary>Contrat de la sonde</summary><dl class="ps-sheet">
          <div class="ps-sheet-row"><dt>Classe</dt><dd class="mono">${esc(`${r.probe.namespace}\\${r.probe.class}`)}</dd></div>
          <div class="ps-sheet-row"><dt>Propriétés</dt><dd class="mono">${esc(r.probe.properties.join(', '))}</dd></div>
          ${r.probe.filter ? `<div class="ps-sheet-row"><dt>Filtre</dt><dd class="mono">${esc(r.probe.filter)}</dd></div>` : ''}
          <div class="ps-sheet-row"><dt>Description</dt><dd>${esc(r.probe.description)}</dd></div>
          <div class="ps-sheet-row"><dt>Limites</dt><dd>${esc(r.probe.limitations)}</dd></div>
          <div class="ps-sheet-row"><dt>Valeur inconnue</dt><dd>${esc(r.probe.unknownMeaning)}</dd></div>
          <div class="ps-sheet-row"><dt>Coût</dt><dd>${r.probe.slow ? 'Lente : signalée dans l’éditeur' : 'Rapide'}</dd></div></dl></details>`;
      grid?.destroy();
      grid = createGrid(body.querySelector('[data-grid]'), {
        key: `poste.sonde.${probeId}`,
        label: 'Valeurs de la sonde',
        rowId: (row) => row.__i,
        height: '300px',
        columns: r.columns.map((c, n) => ({ id: `c${n}`, label: c, width: 160, mono: true })),
        empty: { icon: 'database', title: 'Aucune valeur enregistrée', text: r.provenance },
      });
      grid.setRows(r.rows.map((row, i) => Object.fromEntries([['__i', String(i)], ...row.map((v, n) => [`c${n}`, v ?? ''])])));
      body.querySelectorAll('[data-page]').forEach((b) => b.addEventListener('click', () => load(Number(b.dataset.page))));
    } catch (err) {
      body.innerHTML = failure(err, { retry: null });
    }
  };
  load(1);
  panel.closed.then(() => grid?.destroy());
}

/** Side panel of the catalog of the 33 probes (read only: the list of allowed classes). */
function openCatalog(data) {
  const body = document.createElement('div');
  body.className = 'poste-drw ps-catalog';
  const catalog = data?.catalog ?? [];
  const byCategory = [...new Set(catalog.map((p) => p.category))];
  body.innerHTML = `<p class="ps-faint">${int(catalog.length)} sondes en lecture seule, documentation vérifiée le 13/10/2026 ; aucune méthode WMI n’est jamais invoquée. Chaque sonde ouvre sa lecture interprétée.</p>
    ${byCategory.map((cat) => `<h4 class="ps-mini-title">${esc(cat)}</h4><ul class="ps-cat-list">${catalog.filter((p) => p.category === cat).map((p) => `<li><div><b>${esc(p.name)}</b><span class="mono">${esc(p.id)} · ${esc(p.class)}</span></div>${p.slow ? chip('warn', 'Lente') : ''}${p.reading ? chip('info', p.reading) : ''}</li>`).join('')}</ul>`).join('')}`;
  openDrawer({ title: 'Catalogue des sondes', subtitle: 'ProbeCatalog de Domenia 1, schéma 1', icon: 'database', key: 'poste.catalogue', width: 620, minWidth: 420, maxWidth: 1000, body });
}
