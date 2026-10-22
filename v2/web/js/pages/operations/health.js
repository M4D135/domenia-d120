// Tab « Santé du moteur » (Domenia 1 OPE-001, OPE-005, OPE-006, OPE-030 to OPE-036): reactivity of the interface drawn live,
// state of the engine, response times per category with their histogram, explained slowness, local save, SQLite waits, paused
// sources and collection indicators. Local measures of this session only: never a probe of the network.
import { esc, errorText } from '../../ui.js';
import { pill, glyph, NBSP } from '../../kit/index.js';
import { duration, int, count, cardHead, emptyState, errorBox, hour, repaint, unpaint, skeletonLines, toneMark } from './common.js';

const W = 600;
const H = 150;

/**
 * @param {HTMLElement} host
 * @param {{ ctx: any, pulse: any }} env
 */
export function createHealth(host, env) {
  const { ctx, pulse } = env;
  let alive = true;
  host.innerHTML = `<div class="grid op-health">
    <section class="card span-8 op-pulse-card spot" data-card="pulse">
      ${cardHead('activity', 'Réactivité de l’interface', 'Battement d’une seconde dans la page, pendant l’affichage d’Opérations', '<span class="op-live-dot" aria-hidden="true"></span>Mesure locale')}
      <div class="op-pulse-figures">
        <div class="op-figure"><span>Retard habituel</span><b data-pf="p50">—</b><small>médiane</small></div>
        <div class="op-figure"><span>95${NBSP}% des battements</span><b data-pf="p95">—</b><small data-pf="p95n">sous cette valeur</small></div>
        <div class="op-figure"><span>Pire retard</span><b data-pf="max">—</b><small data-pf="count">0 mesure</small></div>
        <div class="op-figure"><span>Tâches longues</span><b data-pf="long">0</b><small>du navigateur</small></div>
      </div>
      <div class="op-pulse-chart" role="img" aria-label="Retard de l’interface sur les 4 dernières minutes">
        <svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" aria-hidden="true">
          <defs><linearGradient id="op-pulse-fill" x1="0" y1="0" x2="0" y2="1"><stop class="op-pf-0" offset="0"/><stop class="op-pf-1" offset="1"/></linearGradient></defs>
          <line class="op-pulse-grid" x1="0" x2="${W}" y1="${H * 0.25}" y2="${H * 0.25}"/><line class="op-pulse-grid" x1="0" x2="${W}" y1="${H * 0.5}" y2="${H * 0.5}"/><line class="op-pulse-grid" x1="0" x2="${W}" y1="${H * 0.75}" y2="${H * 0.75}"/>
          <line class="op-pulse-threshold" x1="0" x2="${W}" y1="0" y2="0" data-threshold/>
          <path class="op-pulse-area" d="" fill="url(#op-pulse-fill)"/><path class="op-pulse-line" d=""/><circle class="op-pulse-dot" r="4" cx="0" cy="${H}"/>
        </svg>
        <span class="op-pulse-scale" data-pf="scale"></span><span class="op-pulse-thr-label" data-pf="thr">Seuil 400${NBSP}ms</span>
        <span class="op-pulse-wait" data-pf="wait">${glyph('clock')}La courbe se remplit seconde après seconde${NBSP}: les 4 dernières minutes y tiennent.</span>
      </div>
      <div class="op-stalls" data-stalls></div>
      <ul class="op-pulse-help">
        <li>${glyph('clock')}<span>Un battement est attendu chaque seconde${NBSP}: son retard mesure le temps pendant lequel l’interface était occupée.</span></li>
        <li>${glyph('zap')}<span>À partir de 400${NBSP}ms, le retard est expliqué par le travail de l’écran qui l’a chevauché, sinon dit «${NBSP}non attribué${NBSP}».</span></li>
        <li>${glyph('info')}<span>Les lectures de l’annuaire et des postes tournent dans le moteur${NBSP}: elles ne ralentissent jamais ce battement.</span></li>
      </ul>
    </section>
    <section class="card span-4 op-engine-card spot" data-card="engine" aria-busy="true">${skeletonLines(6)}</section>
    <section class="card span-12 op-cat-card" data-card="categories" aria-busy="true">${skeletonLines(5)}</section>
    <section class="card span-6 op-slow-card" data-card="slow" aria-busy="true">${skeletonLines(3)}</section>
    <section class="card span-6 op-save-card" data-card="save" aria-busy="true">${skeletonLines(4)}</section>
  </div>`;

  // ---------------------------------------------------------------- live reactivity of the page

  const chart = host.querySelector('.op-pulse-chart svg');
  const figure = (name) => host.querySelector(`[data-pf="${name}"]`);
  function drawPulse(state) {
    if (!alive || !chart) return;
    const values = state.samples;
    const top = Math.max(500, ...values.map((v) => v * 1.25));
    const n = Math.max(2, 240);
    const x = (i) => (W * (i + (n - values.length))) / (n - 1);
    const y = (v) => H - (Math.min(v, top) / top) * (H - 6) - 3;
    let line = '';
    values.forEach((v, i) => { line += `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(v).toFixed(1)} `; });
    const area = values.length > 1 ? `${line}L${x(values.length - 1).toFixed(1)},${H} L${x(0).toFixed(1)},${H} Z` : '';
    chart.querySelector('.op-pulse-line').setAttribute('d', line.trim());
    chart.querySelector('.op-pulse-area').setAttribute('d', area);
    const dot = chart.querySelector('.op-pulse-dot');
    if (values.length) { dot.setAttribute('cx', x(values.length - 1).toFixed(1)); dot.setAttribute('cy', y(values.at(-1)).toFixed(1)); }
    const thr = chart.querySelector('[data-threshold]');
    const ty = y(state.threshold).toFixed(1);
    thr.setAttribute('y1', ty);
    thr.setAttribute('y2', ty);
    figure('p50').textContent = state.p50 == null ? '—' : duration(state.p50);
    figure('p95').textContent = state.p95 == null ? '—' : duration(state.p95);
    figure('p95n').textContent = state.p95 == null ? `à partir de 20 mesures` : 'sous cette valeur';
    figure('max').textContent = state.max == null ? '—' : duration(state.max);
    figure('count').textContent = count(state.count, 'mesure', 'mesures');
    figure('long').textContent = int(state.longTasks);
    figure('scale').textContent = `Échelle${NBSP}: 0 à ${duration(top)}`;
    figure('wait').hidden = values.length >= 12;
    const stalls = host.querySelector('[data-stalls]');
    stalls.innerHTML = state.stalls.length
      ? `<h4>Blocages attribués</h4><ul>${state.stalls.slice(0, 4).map((s) => `<li data-attributed="${s.attributed}">${glyph(s.attributed ? 'zap' : 'info')}<span>${esc(s.attributed
        ? `Interface en retard de ${duration(s.late)} pendant${NBSP}: ${s.culprits.map((c) => `${c.name} (${duration(c.ms)})`).join(' ; ')}.`
        : `Interface en retard de ${duration(s.late)}${NBSP}: aucun travail suivi de l’écran ne l’explique (cause non attribuée${NBSP}: mise en page, rendu ou autre écran).`)}</span><time>${esc(new Date(s.at).toLocaleTimeString('fr-FR'))}</time></li>`).join('')}</ul>`
      : `<p class="op-stalls-none">${glyph('check')}Aucun battement en retard de 400${NBSP}ms ou plus depuis l’ouverture de l’écran.</p>`;
  }

  // ---------------------------------------------------------------- engine figures

  function load(silent = false) {
    const call = silent ? env.silent : ctx.call;
    return Promise.allSettled([call('operations.health'), call('operations.engine')]).then(([h, e]) => {
      if (!alive) return;
      if (h.status === 'fulfilled') paintHealth(h.value); else failCards(['categories', 'slow', 'save'], h.reason);
      if (e.status === 'fulfilled') paintEngine(e.value); else failCards(['engine'], e.reason);
    });
  }

  function failCards(ids, err) {
    console.error(err);
    ids.forEach((id) => {
      const card = host.querySelector(`[data-card="${id}"]`);
      card.removeAttribute('aria-busy');
      unpaint(card);
      card.innerHTML = errorBox(errorText(err, 'Mesures illisibles.'));
    });
  }

  function paintEngine(s) {
    const card = host.querySelector('[data-card="engine"]');
    card.removeAttribute('aria-busy');
    const memory = s.memoryMb == null ? '—' : `${int(Math.round(s.memoryMb))}`;
    repaint(card, `${cardHead('chip', 'État du moteur', `${s.product} ${s.version}`)}
      <div class="op-engine-memory"><span class="op-engine-ring" aria-hidden="true"><i></i></span><div><b>${esc(memory)}<small>${NBSP}Mo</small></b><span>mémoire privée du processus</span></div></div>
      <dl class="op-facts compact">
        <div><dt>Runtime</dt><dd>${esc(s.runtime)} · ${s.is64Bit ? '64 bits' : '32 bits'}</dd></div>
        <div><dt>Système</dt><dd>${esc(s.os)}</dd></div>
        <div><dt>Mode</dt><dd>${esc(s.mode)}${s.readOnly ? ' · lecture seule' : ''}</dd></div>
        <div class="wide"><dt>Écritures</dt><dd>${pill(s.writeTone, s.writeState, { size: 'sm' })}</dd></div>
        <div class="wide"><dt>Reçus</dt><dd>${esc(s.receipts)}</dd></div>
        <div class="wide"><dt>Préférences</dt><dd>${esc(s.preferences)}</dd></div>
        <div><dt>Opérations du pont</dt><dd>${int(s.operations)}</dd></div>
        <div><dt>Tâches actives</dt><dd>${int(s.tasks)}</dd></div>
      </dl>
      ${s.taskLines.length ? `<ul class="op-engine-tasks">${s.taskLines.map((t) => `<li><span class="mono">${esc(t.reference)}</span>${esc(t.text)}</li>`).join('')}</ul>` : ''}
      <ul class="op-engine-notes">${s.notes.map((n) => `<li>${glyph('info')}<span>${esc(n)}</span></li>`).join('')}</ul>`);
  }

  function paintHealth(h) {
    const cats = host.querySelector('[data-card="categories"]');
    cats.removeAttribute('aria-busy');
    const measured = h.categories.filter((c) => c.summary.count > 0).length;
    repaint(cats, `${cardHead('gauge', 'Temps de réponse par catégorie', 'Médiane, 95e centile (à partir de 20 mesures) et maximum · 512 dernières mesures', `${int(measured)} catégorie${measured > 1 ? 's' : ''} mesurée${measured > 1 ? 's' : ''} sur ${h.categories.length}`)}
      <div class="op-cats">${h.categories.map((c, n) => categoryRow(c, n)).join('')}</div>
      <p class="op-note">${esc(h.note)}</p>`);

    const slow = host.querySelector('[data-card="slow"]');
    slow.removeAttribute('aria-busy');
    repaint(slow, `${cardHead('clock', 'Lenteurs expliquées', 'Opérations de plus de 5 s, la plus récente en premier', h.slow.length ? count(h.slow.length, 'lenteur', 'lenteurs') : '')}
      ${h.slow.length
        ? `<ul class="op-slow">${h.slow.map((s, n) => `<li data-i="${n}">${toneMark('warn', 'clock')}<div><p>${esc(s.text)}</p><small>${esc(hour(s.at))} · Réf. <span class="mono">${esc(s.reference)}</span></small></div></li>`).join('')}</ul>`
        : emptyState('check', 'Aucune lenteur relevée', 'Aucune opération n’a dépassé 5 s dans cette session. Une phase non mesurée n’est jamais comptée comme nulle.')}
      ${h.traceFaults > 0 ? `<p class="op-note">${glyph('info')}Suivi des opérations${NBSP}: ${count(h.traceFaults, 'incident de suivi', 'incidents de suivi')}, sans effet sur les opérations elles-mêmes.</p>` : ''}`);

    const save = host.querySelector('[data-card="save"]');
    save.removeAttribute('aria-busy');
    repaint(save, `${cardHead('database', 'Enregistrement local et sources', 'Ce qui est écrit, ce qui attend, ce qui est suspendu')}
      <ul class="op-lines">
        <li data-tone="${esc(h.localSaveTone)}">${toneMark(h.localSaveTone, h.localSaveTone === 'ok' ? 'check' : 'database')}<span>${esc(h.localSave)}</span></li>
        <li data-tone="info">${toneMark('info', 'database')}<span>${esc(h.sqlite)}</span></li>
        ${h.providers.length
          ? h.providers.map((p) => `<li data-tone="warn">${toneMark('warn', 'wifi')}<span>${esc(p)}</span></li>`).join('')
          : `<li data-tone="ok">${toneMark('ok', 'wifi')}<span>Aucune source suspendue ni en reprise${NBSP}: les sources saines ne sont pas listées.</span></li>`}
        ${h.collection.map((c) => `<li data-tone="off">${toneMark('off', 'layers')}<span>${esc(c)}</span></li>`).join('')}
      </ul>`);
  }

  function categoryRow(c, n) {
    const max = Math.max(1, ...c.histogram);
    const bars = c.histogram.map((v, i) => `<span class="op-hbar" data-h="${(v / max).toFixed(3)}" data-i="${i}" data-tip="${esc(`${c.histogramLabels[i]} : ${int(v)}`)}"><i></i></span>`).join('');
    const s = c.summary;
    return `<div class="op-cat" data-i="${n}" data-measured="${s.count > 0}">
      <div class="op-cat-text"><b>${esc(c.label)}</b><p>${esc(c.text.startsWith(c.label) ? c.text.slice(c.label.length).replace(/^\s*:\s*/, '').replace(/^./, (x) => x.toUpperCase()) : c.text)}</p></div>
      <div class="op-cat-figs">
        <span><small>médiane</small><b>${s.p50 == null ? '—' : esc(duration(s.p50))}</b></span>
        <span><small>95${NBSP}%</small><b>${s.p95 == null ? '—' : esc(duration(s.p95))}</b></span>
        <span><small>max</small><b>${s.max == null ? '—' : esc(duration(s.max))}</b></span>
      </div>
      <div class="op-hist" aria-hidden="true">${s.count > 0 ? bars : '<span class="op-hist-none">aucune mesure</span>'}</div>
    </div>`;
  }

  load(false);
  return {
    refresh: (silent = true) => load(silent),
    beat: (state) => drawPulse(state),
    destroy() { alive = false; },
  };
}
