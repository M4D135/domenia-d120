// « Mise à jour » workspace: coverage of the base by scope (complete reads, attempts that stopped early, old reads), the
// directory checkpoint, the limits of a pass and where they come from, the verified backup and the state of the storage, the
// storage receipts of the session. Built from synchro.overview only (local read); its buttons only choose a scope or open the
// estimate of a read.
import {
  esc, glyph, pill, int, count, NBSP, toneOf, cardHead, button, paint, ago, emptyBlock, shortHash, stamp,
} from './common.js';
import { duration } from './run.js';

const DAY = 86_400_000;
const AXIS_DAYS = 14;

function scopesMarkup(o, now) {
  const list = o.scopes ?? [];
  if (!list.length) return emptyBlock('layers', 'Aucune lecture enregistrée', `Choisissez une OU puis mettez-la à jour${NBSP}: sa couverture apparaîtra ici.`);
  const current = o.scope?.dn?.toLowerCase();
  const limit = o.limits.fullRebuildDays;
  return `<ol class="sy-cover" aria-label="Couverture de la base par périmètre">${list.map((s, n) => {
    const age = Math.max(0, (now - Date.parse(s.at)) / DAY);
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
          <span class="sy-age-text">${ago(s.at, now)}</span>
          <div class="sy-age-axis" aria-hidden="true"><span class="sy-age-limit" data-x="${Math.min(100, (limit / AXIS_DAYS) * 100).toFixed(1)}"></span><span class="sy-age-dot" data-x="${x.toFixed(1)}"></span></div>
        </div>
        <div class="sy-cover-act">${use}</div>
      </li>`;
  }).join('')}</ol>
  <p class="sy-axis-note">${glyph('clock')}<span>Axe de ${AXIS_DAYS}${NBSP}jours${NBSP}; le trait marque le seuil de recensement (${count(limit, 'jour', 'jours')}).</span></p>`;
}

function checkpointMarkup(o, now) {
  const c = o.checkpoint;
  const facts = c ? `<dl class="sy-facts three">
      <div><dt>Contrôleur</dt><dd class="mono">${esc(c.controller)}</dd></div>
      <div><dt>USN validé</dt><dd class="mono">${int(c.usn)}</dd></div>
      <div><dt>Lu</dt><dd>${ago(c.at, now)}</dd></div>
      <div><dt>Instance</dt><dd class="mono" data-tip="invocationID ${esc(c.invocationId)}">${esc(c.invocationId.slice(0, 8))}…</dd></div>
      <div><dt>Objets comptés</dt><dd>${int(c.count)}</dd></div>
      <div><dt>Périmètre</dt><dd>Domaine entier</dd></div>
    </dl>` : emptyBlock('hash', 'Aucun repère', 'La première lecture complète du domaine posera le repère des mises à jour incrémentielles.', '', true);
  return `${facts}
    <p class="sy-rule">${glyph('shield')}<span>Réutilisé seulement sur le même contrôleur et la même instance, avec un USN validé. Au moindre doute${NBSP}: lecture complète.</span></p>`;
}

function limitsMarkup(o) {
  const l = o.limits;
  return `<div class="sy-limits">
      <div><span>${glyph('clock')}Budget de temps</span><b>${esc(l.budgetText)}</b><small>Index.BudgetMs</small></div>
      <div><span>${glyph('layers')}Quota d’objets</span><b>${l.maxObjects > 0 ? int(l.maxObjects) : 'Sans quota'}</b><small>Index.MaxObjects</small></div>
      <div><span>${glyph('history')}Délai maximal</span><b>${esc(duration(l.timeoutSeconds * 1000))}</b><small>budget + 2${NBSP}min</small></div>
      <div><span>${glyph('calendar')}Recensement conseillé</span><b>${count(l.fullRebuildDays, 'jour', 'jours')}</b><small>Index.FullRebuildDays</small></div>
    </div>
    <p class="sy-source">${glyph('file')}<span>${esc(l.source)}</span></p>`;
}

function backupMarkup(o) {
  const b = o.backup;
  const st = o.storage;
  const flags = [
    st?.maintenance ? pill('warn', 'Maintenance en cours', { size: 'sm', icon: 'tools' }) : '',
    st?.writerSuspended ? pill('alert', 'Enregistrement suspendu', { size: 'sm', icon: 'pause' }) : '',
  ].join('');
  return `<div class="sy-backup" data-tone="${b.due ? 'warn' : 'ok'}">
      <span class="sy-backup-ico">${glyph('shield')}</span>
      <div><b>${b.lastAt ? `Sauvegarde vérifiée le ${esc(stamp(b.lastAt))}` : 'Aucune sauvegarde vérifiée'}</b><p>${esc(b.text)}</p></div>
    </div>
    <div class="sy-space" data-state="${esc(st?.spaceState ?? 'unknown')}">${glyph('database')}<span>${esc(st?.spaceText ?? '')}</span>${flags}</div>
    <details class="sy-details"><summary>${glyph('info')}Détails de la base et de la fraîcheur</summary><p>${esc(o.details)}</p>
      <ul class="sy-freshness">${(o.freshness ?? []).map((l) => `<li>${esc(l)}</li>`).join('')}</ul></details>`;
}

function receiptsMarkup(o, now) {
  const list = o.receipts ?? [];
  if (!list.length) {
    return emptyBlock('shield', 'Aucun enregistrement dans cette session', `Chaque lecture enregistrée laisse ici son reçu${NBSP}: lignes et empreinte vérifiées avant la transaction, base relue après.`, '', true);
  }
  const kinds = { index: 'Lecture de l’annuaire', absences: 'Vérification des disparitions', gaps: 'Objets manquants', park: 'Relevé partagé' };
  return `<ul class="sy-receipts">${list.map((r, n) => `<li data-i="${n}">
      <span class="sy-receipt-ico" data-tone="${r.verified ? 'ok' : 'warn'}">${glyph(r.verified ? 'check' : 'eye')}</span>
      <div><b>${esc(r.label)}</b><span>${esc(kinds[r.kind] ?? r.kind)} · ${count(r.count, 'ligne', 'lignes')} · ${ago(r.at, now)}</span><small>${esc(r.text)}</small></div>
      <code class="sy-hash" data-tip="${esc(r.sha256)}">${esc(shortHash(r.sha256))}</code>
    </li>`).join('')}</ul>`;
}

/** Renders the workspace in its panel; returns its cleanup. */
export function renderUpdate(panel, screen) {
  panel.classList.add('sy-ws', 'sy-ws-update');
  const draw = (o) => {
    if (!o) return;
    const now = screen.now();
    const scopeButton = o.scope.isDomain
      ? button('Choisir l’OU à relire…', { sm: true, icon: 'tree', kind: 'network', data: { up: 'choose-read' }, disabled: !o.readiness.ready, tip: o.readiness.ready ? `Le domaine entier n’est pas une OU de mise à jour${NBSP}: choisissez l’OU à relire.` : (o.readiness.reason ?? '') })
      : button('Mettre à jour l’OU choisie…', { sm: true, icon: 'refresh', kind: 'network', data: { up: 'read' }, disabled: !o.readiness.ready, tip: o.readiness.ready ? `Lecture complète de ${o.scope.label} et de ses sous-OU, après estimation.` : (o.readiness.reason ?? '') });
    // Two balanced columns: what the base covers and what was stored (left), how a pass works and the point of return (right).
    panel.innerHTML = `<div class="sy-ws-grid">
      <div class="sy-col span-7">
        <section class="sy-card" data-i="0">${cardHead('layers', 'Couverture par périmètre', 'Lectures complètes, tentatives coupées et lectures anciennes', scopeButton)}${scopesMarkup(o, now)}</section>
        <section class="sy-card" data-i="2">${cardHead('shield', 'Reçus de stockage', 'Enregistrements confirmés de cette session, empreinte vérifiée')}${receiptsMarkup(o, now)}</section>
      </div>
      <div class="sy-col span-5">
        <section class="sy-card" data-i="1">${cardHead('hash', 'Repère de synchronisation', 'Base des mises à jour incrémentielles du domaine')}${checkpointMarkup(o, now)}</section>
        <section class="sy-card" data-i="3">${cardHead('sliders', 'Limites d’une passe', 'Coupée, une passe ne remplace jamais une base plus complète')}${limitsMarkup(o)}</section>
        <section class="sy-card" data-i="4">${cardHead('database', 'Sauvegarde et stockage', 'Point de retour avant chaque geste qui réécrit la base')}${backupMarkup(o)}</section>
      </div>
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
    else if (t.dataset.up === 'choose-read') screen.chooseScope({ read: true });
  };
  panel.addEventListener('click', onClick);
  return () => { off(); panel.removeEventListener('click', onClick); };
}
