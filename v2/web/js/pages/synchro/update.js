// « Mise à jour » workspace: coverage of the base by scope (complete reads, attempts that stopped early, old reads), the
// directory checkpoint and the limits of a pass, the storage receipts of the session and the verified backup. Built from
// synchro.overview only (local read); its buttons only choose a scope or open the estimate of a read.
import {
  esc, icon, glyph, pill, int, count, NBSP, toneOf, cardHead, button, paint, ago, emptyBlock, shortHash, when,
} from './common.js';
import { duration } from './run.js';

const DAY = 86_400_000;
const AXIS_DAYS = 14;

function scopesMarkup(o) {
  const list = o.scopes ?? [];
  if (!list.length) return emptyBlock('layers', 'Aucune lecture enregistrée', 'Choisissez une OU puis mettez-la à jour\u00A0: sa couverture apparaîtra ici.');
  const current = o.scope?.dn?.toLowerCase();
  return `<ol class="sy-cover" aria-label="Couverture de la base par périmètre">${list.map((s, n) => {
    const age = Math.max(0, (Date.now() - Date.parse(s.at)) / DAY);
    const x = Math.min(100, (age / AXIS_DAYS) * 100);
    const isDomain = s.key.endsWith('directory');
    const isCurrent = !isDomain && s.dn.toLowerCase() === current;
    const use = !isDomain && !isCurrent ? button('Choisir', { sm: true, ghost: true, icon: 'tree', data: { up: 'scope', dn: s.dn }, tip: `Prendre ${s.label} comme périmètre de mise à jour` }) : '';
    return `<li class="sy-cover-row${isCurrent ? ' current' : ''}" data-tone="${toneOf(s.tone)}" data-i="${n}">
        <span class="sy-cover-ico">${glyph(isDomain ? 'domain' : 'ou')}</span>
        <div class="sy-cover-main">
          <div class="sy-cover-line"><b>${esc(s.label)}</b>${pill(toneOf(s.tone), s.stateLabel, { size: 'sm' })}${isCurrent ? pill('accent', 'Périmètre actuel', { size: 'sm' }) : ''}</div>
          <span class="sy-cover-path">${esc(s.path)}</span>
          <p>${esc(s.detail)}</p>
        </div>
        <div class="sy-cover-age">
          <span class="sy-age-text">${ago(s.at)}</span>
          <div class="sy-age-axis" aria-hidden="true"><span class="sy-age-limit"></span><span class="sy-age-dot" data-x="${x.toFixed(1)}"></span></div>
        </div>
        <div class="sy-cover-act">${use}</div>
      </li>`;
  }).join('')}</ol>
  <p class="sy-axis-note">${glyph('clock')}<span>Axe de ${AXIS_DAYS}${NBSP}jours${NBSP}; le trait marque le seuil de recensement (${int(o.limits.fullRebuildDays)}${NBSP}jours, Index.FullRebuildDays).</span></p>`;
}

function checkpointMarkup(o) {
  const c = o.checkpoint;
  const limits = o.limits;
  const facts = c ? `<dl class="sy-facts">
      <div><dt>Contrôleur</dt><dd class="mono">${esc(c.controller)}</dd></div>
      <div><dt>Instance (invocationID)</dt><dd class="mono" data-tip="${esc(c.invocationId)}">${esc(c.invocationId.slice(0, 8))}…</dd></div>
      <div><dt>USN validé</dt><dd class="mono">${int(c.usn)}</dd></div>
      <div><dt>Lu</dt><dd>${ago(c.at)}</dd></div>
      <div><dt>Objets comptés</dt><dd>${int(c.count)}</dd></div>
      <div><dt>Périmètre</dt><dd>Domaine entier</dd></div>
    </dl>` : emptyBlock('hash', 'Aucun repère', 'La première lecture complète du domaine posera le repère des mises à jour incrémentielles.');
  return `${facts}
    <div class="sy-rule">${glyph('shield')}<p>Le repère n’est réutilisé que sur le même contrôleur et la même instance, avec un USN réellement validé et une base qui contient encore ce qu’il comptait. Au moindre doute, la lecture est complète${NBSP}; aucun USN n’est reporté d’un contrôleur à l’autre.</p></div>
    <h4 class="sy-sub">Limites d’une passe</h4>
    <div class="sy-limits">
      <div><span>${glyph('clock')}Budget de temps</span><b>${esc(limits.budgetText)}</b><small>Index.BudgetMs · ${int(limits.budgetMs)}${NBSP}ms</small></div>
      <div><span>${glyph('layers')}Quota d’objets</span><b>${limits.maxObjects > 0 ? int(limits.maxObjects) : 'Sans quota'}</b><small>Index.MaxObjects</small></div>
      <div><span>${glyph('history')}Délai maximal</span><b>${esc(duration(limits.timeoutSeconds * 1000))}</b><small>budget + 2${NBSP}min</small></div>
      <div><span>${glyph('calendar')}Recensement conseillé</span><b>${count(limits.fullRebuildDays, 'jour', 'jours')}</b><small>Index.FullRebuildDays</small></div>
    </div>`;
}

function receiptsMarkup(o) {
  const list = o.receipts ?? [];
  if (!list.length) {
    return emptyBlock('shield', 'Aucun enregistrement dans cette session', 'Chaque lecture enregistrée laisse ici son reçu de stockage\u00A0: lignes et empreinte vérifiées avant la transaction, base relue après.');
  }
  const kinds = { index: 'Lecture de l’annuaire', absences: 'Vérification des disparitions', gaps: 'Objets manquants', park: 'Relevé partagé' };
  return `<ul class="sy-receipts">${list.map((r, n) => `<li data-i="${n}">
      <span class="sy-receipt-ico" data-tone="${r.verified ? 'ok' : 'warn'}">${glyph(r.verified ? 'check' : 'eye')}</span>
      <div><b>${esc(r.label)}</b><span>${esc(kinds[r.kind] ?? r.kind)} · ${count(r.count, 'ligne', 'lignes')} · ${ago(r.at)}</span><small>${esc(r.text)}</small></div>
      <code class="sy-hash" data-tip="${esc(r.sha256)}">${esc(shortHash(r.sha256))}</code>
    </li>`).join('')}</ul>`;
}

function backupMarkup(o) {
  const b = o.backup;
  const partial = o.partial ? `<div class="sy-callout" data-tone="warn">${icon('alert')}<p><b>Dernière passe incomplète</b>${esc(o.partial.charAt(0).toUpperCase() + o.partial.slice(1))}</p></div>` : '';
  return `<div class="sy-backup" data-tone="${b.due ? 'warn' : 'ok'}">
      <span class="sy-backup-ico">${glyph('shield')}</span>
      <div><b>${b.lastAt ? `Sauvegarde vérifiée ${esc(when(b.lastAt))}` : 'Aucune sauvegarde vérifiée'}</b><p>${esc(b.text)}</p></div>
    </div>
    ${partial}
    <details class="sy-details"><summary>${glyph('info')}Détails du stockage et de la synchronisation</summary><p>${esc(o.details)}</p>
      <ul class="sy-freshness">${(o.freshness ?? []).map((l) => `<li>${esc(l)}</li>`).join('')}</ul></details>`;
}

/** Renders the workspace in its panel; returns its cleanup. */
export function renderUpdate(panel, screen) {
  panel.classList.add('sy-ws', 'sy-ws-update');
  const draw = (o) => {
    if (!o) return;
    panel.innerHTML = `<div class="sy-ws-grid">
      <section class="sy-card span-7" data-i="0">${cardHead('layers', 'Couverture par périmètre', 'Lectures complètes, tentatives coupées et lectures anciennes de la base', button('Mettre à jour l’OU choisie…', { sm: true, icon: 'refresh', kind: 'network', data: { up: 'read' }, disabled: !o.readiness.ready || o.scope.isDomain, tip: o.scope.isDomain ? 'Choisissez d’abord une OU.' : (o.readiness.reason ?? '') }))}${scopesMarkup(o)}</section>
      <section class="sy-card span-5" data-i="1">${cardHead('hash', 'Repère de synchronisation', 'Base des mises à jour incrémentielles du domaine')}${checkpointMarkup(o)}</section>
      <section class="sy-card span-7" data-i="2">${cardHead('shield', 'Reçus de stockage', 'Enregistrements confirmés de cette session, empreinte vérifiée')}${receiptsMarkup(o)}</section>
      <section class="sy-card span-5" data-i="3">${cardHead('database', 'Sauvegarde et stockage', 'Point de retour avant chaque geste qui réécrit la base')}${backupMarkup(o)}</section>
    </div>`;
    panel.querySelectorAll('[data-x]').forEach((n) => n.style.setProperty('--x', n.dataset.x));
    paint(panel);
  };
  draw(screen.overview);
  const off = screen.on('overview', draw);
  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-up]') : null;
    if (!t || t.disabled) return;
    if (t.dataset.up === 'scope') screen.setScope(t.dataset.dn);
    else if (t.dataset.up === 'read') screen.startRead('ou');
  };
  panel.addEventListener('click', onClick);
  return () => { off(); panel.removeEventListener('click', onClick); };
}
