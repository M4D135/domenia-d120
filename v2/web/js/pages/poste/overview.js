// « Vue d’ensemble » of the workstation console: points of attention (the score itself is in the header), live state and
// associated user, identity, resources and computer account, disks, protection and counts, activity, details of the
// protection. Built from poste.open (no network read); the live state, the detection of the user and the logons per
// controller are read only on their button. Laid out on the 12 columns of the kit (.grid, .span-*): the cards of a row
// share their height, the stacked ones share the height of their column.
import { gauge, animateGauges, bindCopy, timeline, bindTimeline, writeClipboard } from '../../kit/index.js';
import { runWrite } from '../../write-flow.js';
import {
  esc, ico, rel, fact, facts, cardHead, section, empty, failure, chip, meter, paintMeters, donut, paintDonuts, sheetLines,
  progressMarkup, setProgress, NBSP, int, count, pct, freePct, size, errorText,
} from './common.js';
import { reveal as revealCards, toast } from '../../ui.js';

const LEVEL_ICON = { alert: 'alert', warn: 'eye', info: 'info' };
const VIEW_LABEL = { ensemble: 'Vue d’ensemble', inventaire: 'Inventaire', diagnostic: 'Diagnostic', releves: 'Sondes et relevés', intervenir: 'Intervenir', secrets: 'Secrets' };

export function renderOverview(panel, state) {
  let alive = true;
  const off = [];
  panel.classList.add('ps-overview');

  const paint = () => {
    const d = state.data;
    const b = d.board;
    const inv = d.inventory;
    panel.innerHTML = `<div class="grid ps-grid">
      ${healthCard(b)}
      <div class="span-5 ps-stack">${liveCard(d, state)}${associationCard(d)}</div>
      ${section('Le poste', inv ? `${inv.modeLabel} ${inv.ageText} · ${inv.origin}` : 'Annuaire seulement : aucun inventaire')}
      <div class="span-6 ps-stack">${sheetCard('chip', b.identity, b.hints, 'identite')}${resourcesCard(b)}</div>
      ${adCard(d)}
      ${section('Disques et protection', 'Seuils partagés avec le parc (règles de santé)')}
      ${disksCard(b)}
      ${protectionCard(b)}
      ${b.counts?.length ? countsCard(b) : inventoryCard(d)}
      ${b.activity ? section('Activité', b.deep ? 'Inventaire complet : services, processus, journal Système' : 'Inventaire rapide : l’inventaire complet ajoute processus et journal') : ''}
      ${b.activity ? activityCard(b) : ''}
      ${b.sections?.length ? section('Détails de la protection', 'BitLocker, pare-feu, antivirus, redémarrage, mises à jour, Secure Boot, certificats') : ''}
      ${b.sections?.length ? `<div class="ps-sections span-12">${b.sections.map(sectionCard).join('')}</div>` : ''}
      ${d.notes?.length ? `<section class="card ps-card span-12 reveal">${cardHead('info', 'Notes', 'Ce que la console sait de plus')}${facts(d.notes)}</section>` : ''}
    </div>`;
    paintMeters(panel);
    paintDonuts(panel);
    animateGauges(panel);
    bindCopy(panel);
    bindTimeline(panel);
    revealCards(panel);
  };

  async function live() {
    const host = panel.querySelector('[data-slot="live-body"]');
    panel.querySelectorAll('[data-act="live"]').forEach((b) => b.setAttribute('disabled', ''));
    if (host) { host.setAttribute('aria-busy', 'true'); host.innerHTML = progressMarkup(); }
    try {
      await state.call('poste.live', { dn: state.dn });
      if (alive) await state.reload();
    } catch (err) {
      if (alive && host) { host.removeAttribute('aria-busy'); host.innerHTML = failure(err, { retry: 'live' }); }
    }
  }

  async function detect() {
    const host = panel.querySelector('[data-slot="detect"]');
    if (!host) return;
    host.hidden = false;
    host.setAttribute('aria-busy', 'true');
    host.innerHTML = `${progressMarkup()}<div class="ps-row-actions"><button class="btn ghost sm" type="button" data-act="stopDetect">${ico('pause')}Arrêter</button></div>`;
    const stop = state.progress('poste.lastUser.detect', (p) => setProgress(host, p));
    state.refreshRunning();
    try {
      const r = await state.call('poste.lastUser.detect', { dn: state.dn });
      if (!alive) return;
      host.removeAttribute('aria-busy');
      host.innerHTML = `<p class="ps-verdict-line" data-tone="${r.verified ? 'ok' : 'info'}">${ico(r.verified ? 'check' : 'info')}<span>${esc(r.verdict)}</span></p>
        <ol class="ps-attempts">${r.attempts.map((a) => `<li data-tone="${esc(a.tone)}"><span class="ps-attempt-n">${int(a.order)}</span><div><b>${esc(a.method)}</b><span>${esc(a.statusLabel)} · ${esc(a.detail)}</span></div><span class="ps-attempt-ms">${int(a.durationMs)}${NBSP}ms</span></li>`).join('')}</ol>`;
      state.data.association = r.association;
      const assoc = panel.querySelector('[data-slot="assoc-text"]');
      if (assoc) assoc.textContent = r.association.text;
    } catch (err) {
      if (alive) { host.removeAttribute('aria-busy'); host.innerHTML = failure(err, { retry: 'detect' }); }
    } finally {
      stop();
      state.refreshRunning();
    }
  }

  async function logons() {
    const host = panel.querySelector('[data-slot="logons"]');
    if (!host) return;
    host.hidden = false;
    host.setAttribute('aria-busy', 'true');
    host.innerHTML = progressMarkup();
    try {
      const r = await state.call('poste.logonByDc', { dn: state.dn });
      if (!alive) return;
      host.removeAttribute('aria-busy');
      host.innerHTML = `<p class="ps-verdict-line" data-tone="${r.controllers.every((x) => x.state === 'observed') ? 'ok' : 'warn'}">${ico('server')}<span>${esc(r.text)}</span></p>
        <ul class="ps-dcs">${r.controllers.map((x) => `<li data-tone="${x.state === 'observed' ? 'ok' : 'warn'}">${ico('server')}<b class="mono">${esc(x.controller)}</b><span>${esc(x.site ?? '')}</span><span>${esc(x.text)}</span></li>`).join('')}</ul>${facts(r.facts, { compact: true })}`;
    } catch (err) {
      if (alive) { host.removeAttribute('aria-busy'); host.innerHTML = failure(err, { retry: 'logons' }); }
    }
  }

  function accountWrite(enable) {
    runWrite(state.ctx, { plan: 'poste.account.plan', args: { dn: state.dn, enable }, subtitle: state.data.computer.name, onDone: () => state.reload() });
  }

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-act],[data-route],[data-copy]') : null;
    if (!t || !panel.contains(t) || t.disabled) return;
    if (t.dataset.copy) { writeClipboard(t.dataset.copy).then(() => toast('Copié.', { tone: 'ok', life: 1800 })); return; }
    if (t.dataset.route) {
      const [view, tab] = t.dataset.route.split('/');
      state.go(view, tab || undefined);
      return;
    }
    const act = t.dataset.act;
    if (act === 'live') live();
    else if (act === 'detect') detect();
    else if (act === 'stopDetect') state.stop('detection');
    else if (act === 'logons') logons();
    else if (act === 'fiche') state.ctx.navigate('fiche', { dn: state.data.association.user?.dn ?? state.dn });
    else if (act === 'fiche-poste') state.ctx.navigate('fiche', { dn: state.dn });
    else if (act === 'enable') accountWrite(true);
    else if (act === 'disable') accountWrite(false);
    else if (act === 'inventory.quick' || act === 'inventory.deep') { state.go('inventaire', 'materiel'); state.emit('run', { what: 'inventory', deep: act === 'inventory.deep' }); }
    else if (act === 'software') state.go('inventaire', 'logiciels');
  };
  panel.addEventListener('click', onClick);
  off.push(() => panel.removeEventListener('click', onClick));
  off.push(state.on('console', () => { if (alive) paint(); }));
  paint();
  if (state.essai === 'live') live();
  else if (state.essai === 'detection') detect();
  else if (state.essai === 'connexions') logons();
  return () => { alive = false; off.forEach((fn) => fn()); };
}

// ---------- Cards ----------

/** Points of attention (Domenia 1 computer.attention): the list, what is not counted and why, the rules and thresholds applied. */
function healthCard(b) {
  const h = b.health;
  const points = h.points ?? [];
  const list = points.length
    ? `<ol class="ps-points" data-long="${points.length > 7 ? '1' : '0'}">${points.map((p, n) => `<li class="ps-point" data-level="${esc(p.level)}" data-i="${n}"><span class="ps-point-mark" aria-hidden="true">${ico(LEVEL_ICON[p.level] ?? 'info')}</span>
        <span class="ps-point-text">${esc(p.text)}</span>
        ${p.route ? `<button class="btn ghost sm ps-point-go" type="button" data-route="${esc(p.route.view)}/${esc(p.route.tab ?? '')}" data-tip="${esc(p.route.label)}">${esc(VIEW_LABEL[p.route.view] ?? p.route.label)}${ico('chevronRight')}</button>` : ''}</li>`).join('')}</ol>`
    : empty({ icon: h.state === 'off' ? 'info' : 'check', title: h.title, text: h.badge ? 'Aucun problème établi sur ce qui a été lu : ce n’est pas un bon état prouvé.' : 'Aucun point à vérifier sur ce poste.', tone: h.state === 'off' ? 'off' : 'ok' });
  const thresholds = (h.thresholds ?? []).map((t) => `<li><span>${esc(t.label)}</span><b>${int(t.value)}${NBSP}${esc(t.unit)}</b></li>`).join('');
  const notes = (h.policyNotes ?? []).map((n) => `<li>${esc(n)}</li>`).join('');
  const sum = [
    h.alerts ? `<span class="ps-sum" data-tone="alert"><b>${int(h.alerts)}</b>${esc(h.alerts > 1 ? 'critiques' : 'critique')}</span>` : '',
    h.warnings ? `<span class="ps-sum" data-tone="warn"><b>${int(h.warnings)}</b>à surveiller</span>` : '',
    h.information ? `<span class="ps-sum" data-tone="info"><b>${int(h.information)}</b>${esc(h.information > 1 ? 'informations' : 'information')}</span>` : '',
  ].join('');
  return `<section class="card ps-card ps-health span-7 reveal" data-slot="health" data-tone="${esc(h.state)}">
    ${cardHead('shield', 'Points d’attention', esc(h.detail), h.badgeAction ? `<button class="btn sm" type="button" data-act="${esc(h.badgeAction)}">${ico('layers')}${h.badgeAction === 'inventory.deep' ? 'Inventaire complet' : 'Inventaire rapide'}</button>` : '', h.state)}
    <div class="ps-health-top">
      <span class="ps-health-score" data-tone="${esc(h.state)}">${h.score == null ? esc(h.verdict) : `<b>${int(h.score)}</b><small>/100</small> · ${esc(h.verdict)}`}</span>
      ${sum ? `<span class="ps-health-sums">${sum}</span>` : ''}
    </div>
    ${h.badge ? `<p class="ps-badge-line" data-tone="info">${ico('info')}<span>${esc(h.badge)}</span></p>` : ''}
    ${list}
    <div class="ps-health-more">
      ${h.suppressed?.length ? `<details class="ps-more"><summary>${esc(count(h.suppressed.length, 'point non compté', 'points non comptés'))}</summary><ul class="ps-sup">${h.suppressed.map((p) => `<li>${esc(p.text)} <em>${esc(p.reason ?? '')}</em></li>`).join('')}</ul></details>` : ''}
      <details class="ps-more"><summary>Règles et seuils appliqués</summary><p class="ps-faint">${esc(h.policyOrigin)}</p>
        ${notes ? `<ul class="ps-sup">${notes}</ul>` : ''}<ul class="ps-thresholds">${thresholds}</ul>
        <p class="ps-faint">Score : 100 − 25 par point critique − 10 par point à surveiller.</p></details>
    </div></section>`;
}

function liveCard(d) {
  const live = d.live;
  const body = live
    ? facts(live.facts)
    : empty({ icon: 'ping', title: 'État en direct non lu', text: 'Présence (un ping), durée de fonctionnement, utilisateur de la console et sessions, lus sur votre geste seulement.', action: { id: 'live', label: 'Actualiser l’état', icon: 'refresh' }, actionKind: 'primary' });
  return `<section class="card ps-card ps-live-card reveal">
    ${cardHead('ping', 'État en direct', live ? rel(live.at, 'Lu ') : 'Ping, durée de fonctionnement, utilisateur de la console', live ? `<button class="btn ghost sm" type="button" data-act="live" data-tip="Relire l’état (lecture réseau)">${ico('refresh')}Relire</button>` : '')}
    <div data-slot="live-body">${body}</div></section>`;
}

function associationCard(d) {
  const a = d.association;
  const history = a.history?.length
    ? `<details class="ps-more"><summary>Historique des associations (${int(a.history.length)})</summary>${timeline(a.history.map((h) => ({ when: h.at, title: h.user, text: `${h.source} · ${h.detail}`, tone: 'info', icon: 'user' })))}</details>` : '';
  return `<section class="card ps-card ps-assoc ps-grow reveal">
    ${cardHead('link', 'Utilisateur associé', `<span class="chip ${esc(a.tone)}">${esc(a.badgeLabel)}</span>`)}
    ${a.user ? `<div class="ps-assoc-user"><span class="avatar ps-initials" aria-hidden="true">${esc(initials(a.user.name))}</span><div><b>${esc(a.user.name)}</b><span class="mono">${esc(a.user.login)}</span></div></div>` : ''}
    <p class="ps-assoc-text" data-slot="assoc-text">${esc(a.text)}</p>
    ${a.identityProven ? '' : `<p class="ps-badge-line" data-tone="warn">${ico('alert')}<span>Identité non vérifiable : lien hérité sans GUID ou ancien détenteur du nom.</span></p>`}
    <div class="ps-row-actions">${a.user?.dn ? `<button class="btn sm" type="button" data-act="fiche">${ico('user')}Ouvrir la fiche</button>` : ''}
      <button class="btn sm" type="button" data-act="detect" data-tip="Association locale d’abord, puis CIM, LogonUI, WinRM, profils (lecture réseau, 25 s au plus)">${ico('search')}Détecter à nouveau</button></div>
    <div class="ps-sub-result" data-slot="detect" hidden></div>
    ${history}
  </section>`;
}

function initials(name) {
  return String(name ?? '').split(/[\s-]+/).filter(Boolean).slice(0, 2).map((p) => p[0].toUpperCase()).join('');
}

function sheetCard(iconName, sheet, hints, hintKey) {
  if (!sheet) {
    const hint = (hints ?? []).find((h) => h.section === hintKey);
    return `<section class="card ps-card reveal">${cardHead(iconName, 'Identité du poste', 'Matériel et système')}
      ${empty({ icon: 'layers', title: 'Section vide', text: hint?.text ?? 'Lancez un inventaire.', action: hint?.action ? { id: hint.action, label: hint.actionLabel, icon: 'layers' } : null })}</section>`;
  }
  return `<section class="card ps-card reveal" data-tone="${esc(sheet.state ?? '')}">${cardHead(iconName, sheet.title, esc(sheet.value + (sheet.detail ? ` · ${sheet.detail}` : '')))}${sheetLines(sheet)}</section>`;
}

function adCard(d) {
  const c = d.computer;
  const sheet = d.board.adAccount;
  const action = c.userAccountControl == null
    ? `<p class="ps-badge-line" data-tone="warn">${ico('alert')}<span>${esc(c.accountText)} Relisez la fiche du poste avant toute action sur le compte.</span></p>`
    : c.enabled
      ? `<button class="btn sm ps-write" type="button" data-act="disable" data-tip="Écriture : plan, confirmation avec le nom, reçu, relecture">${ico('power')}Désactiver le compte…</button>`
      : `<button class="btn sm ps-write" type="button" data-act="enable" data-tip="Écriture : plan, confirmation, reçu, relecture">${ico('power')}Activer le compte…</button>`;
  return `<section class="card ps-card span-6 reveal" data-tone="${esc(sheet.state ?? '')}">
    ${cardHead('object', sheet.title, esc(`${sheet.value}${sheet.detail ? ` · ${sheet.detail}` : ''}`), `<button class="btn ghost sm" type="button" data-act="fiche-poste" data-tip="Fiche complète du compte ordinateur">${ico('object')}Fiche</button>`)}
    ${sheetLines(sheet)}
    <div class="ps-row-actions">${action}<button class="btn sm" type="button" data-act="logons" data-tip="lastLogon lu sur chaque contrôleur (lecture réseau)">${ico('server')}Connexions par contrôleur</button></div>
    <div class="ps-sub-result" data-slot="logons" hidden></div>
  </section>`;
}

function resourcesCard(b) {
  const r = b.resources;
  if (!r) {
    return `<section class="card ps-card ps-grow reveal">${cardHead('cpu', 'Ressources', 'Mémoire, processeur, batterie')}
      ${empty({ icon: 'cpu', title: 'Non mesurées', text: 'Lancez un inventaire pour mesurer la mémoire, le processeur et la batterie.', action: { id: 'inventory.quick', label: 'Inventaire rapide', icon: 'layers' } })}</section>`;
  }
  const g = (m, label, unitTip) => gauge({ value: m ? m.percent : null, label, caption: m ? m.detail : unitTip, tone: m ? (m.state === 'warn' ? 'warn' : m.state === 'alert' ? 'alert' : 'ok') : undefined });
  return `<section class="card ps-card ps-grow reveal">${cardHead('cpu', 'Ressources', 'Au moment de l’inventaire')}
    <div class="ps-gauges">${g(r.memory, 'Mémoire utilisée', 'Non mesurée')}${g(r.cpu, 'Charge processeur', 'Non mesurée')}
      ${r.battery ? g(r.battery, 'Batterie', '') : `<div class="ps-nobattery">${ico('plug')}<span>${esc(r.batteryText ?? 'Batterie non lue')}</span></div>`}</div>
    ${r.text ? `<p class="ps-faint">${esc(r.text)}</p>` : ''}</section>`;
}

function disksCard(b) {
  const disks = b.disks;
  if (!disks?.system) {
    return `<section class="card ps-card span-4 reveal" data-section="disques">${cardHead('disk', 'Disques', 'Espace libre')}
      ${empty({ icon: 'disk', title: 'Non lus', text: 'Lancez un inventaire pour lire les volumes.', action: { id: 'inventory.quick', label: 'Inventaire rapide', icon: 'layers' } })}</section>`;
  }
  const s = disks.system;
  const used = 100 - (s.freePercent ?? 0);
  const center = `<b>${esc(freePct(s.freePercent))}</b><span>libres</span>`;
  return `<section class="card ps-card span-4 reveal" data-section="disques" data-tone="${esc(s.state)}">${cardHead('disk', 'Disques', esc(disks.othersText))}
    <div class="ps-disk">
      ${donut([{ value: used, tone: s.state === 'ok' ? 'info' : s.state }, { value: s.freePercent ?? 0, tone: 'off' }], { label: `Disque ${s.name}${NBSP}: ${freePct(s.freePercent)} libres`, center })}
      <div class="ps-disk-text"><b class="mono">${esc(s.name)}</b><span>${esc(s.text)}</span>${chip(s.state, s.state === 'alert' ? 'Critique' : s.state === 'warn' ? 'À surveiller' : 'Espace suffisant')}</div>
    </div>
    ${disks.others.length ? `<ul class="ps-volumes">${disks.others.map((v) => `<li><span class="mono">${esc(v.name)}</span>${meter(1 - (v.freePercent ?? 0) / 100, v.state === 'ok' ? 'info' : v.state, `${v.name}${NBSP}: ${freePct(v.freePercent)} libres`)}<span>${esc(freePct(v.freePercent))} libres</span></li>`).join('')}</ul>` : ''}
  </section>`;
}

function protectionCard(b) {
  const p = b.protection;
  const unread = p.lines.filter((l) => l.state === 'off').length;
  return `<section class="card ps-card span-4 reveal" data-tone="${esc(p.state ?? '')}">${cardHead('shield', p.title, esc(`${p.value} · ${p.detail ?? ''}`))}
    <ul class="ps-check">${p.lines.map((l) => `<li data-tone="${esc(l.state ?? 'info')}"><span class="ps-check-mark" aria-hidden="true">${ico(l.state === 'ok' ? 'check' : l.state === 'off' ? 'minus' : l.state === 'alert' ? 'alert' : l.state === 'warn' ? 'eye' : 'info')}</span>
      <span class="ps-check-label">${esc(l.label)}</span><span class="ps-check-value">${esc(l.value)}</span></li>`).join('')}</ul>
    ${unread ? `<p class="ps-faint">Un contrôle non lu n’est jamais compté comme conforme.</p>` : ''}
    ${unread === p.lines.length ? `<div class="ps-row-actions"><button class="btn sm" type="button" data-act="inventory.quick">${ico('layers')}Inventaire rapide</button></div>` : ''}</section>`;
}

/** Without inventory, the third card of the row offers the two inventories (Domenia 1 PST-108: the action that fills it). */
function inventoryCard(d) {
  return `<section class="card ps-card span-4 ps-inv-cta reveal">${cardHead('layers', 'Inventaire du poste', d.noInventoryText ?? 'Aucun inventaire dans la base locale ni dans cette session')}
    <ul class="ps-inv-choices">
      <li><button class="ps-inv-choice" type="button" data-act="inventory.quick"><span class="ps-inv-choice-ico">${ico('layers')}</span><span><b>Inventaire rapide</b><small>≈ 1 min, 55${NBSP}s au plus : système, matériel, disques, sécurité, logiciels</small></span>${ico('chevronRight')}</button></li>
      <li><button class="ps-inv-choice" type="button" data-act="inventory.deep"><span class="ps-inv-choice-ico">${ico('layers')}</span><span><b>Inventaire complet</b><small>≈ 3 min, 150${NBSP}s au plus : ajoute processus, journal Système, tâches, certificats</small></span>${ico('chevronRight')}</button></li>
    </ul>
    <p class="ps-faint">Lecture réseau sur votre geste seulement ; le résultat devient le dernier inventaire du poste.</p></section>`;
}

function activityCard(b) {
  const a = b.activity;
  const total = a.services.reduce((s, x) => s + x.value, 0);
  const services = a.services.length
    ? `<div class="ps-act-col"><h4>${esc(count(a.servicesTotal, 'service', 'services'))}</h4><div class="ps-act-services">${donut(a.services.map((x) => ({ value: x.value, tone: x.tone })), { label: 'Répartition des services', center: `<b>${int(total)}</b><span>services</span>` })}
        <ul class="ps-legend">${a.services.map((x) => `<li data-tone="${esc(x.tone)}"><span class="ps-dot" data-tone="${esc(x.tone)}" aria-hidden="true"></span><span>${esc(x.label)}</span><b>${int(x.value)}</b></li>`).join('')}</ul></div>
        <button class="btn ghost sm" type="button" data-route="inventaire/services">${ico('chevronRight')}Lire les services</button></div>` : '';
  const max = Math.max(1, ...a.processes.map((p) => p.value));
  const processes = a.processes.length
    ? `<div class="ps-act-col"><h4>Processus les plus gros</h4><ul class="ps-bars">${a.processes.map((p, n) => `<li data-i="${n}"><span class="ps-bar-name">${esc(p.name)}</span>${meter(p.value / max, 'accent', p.text)}<span class="ps-bar-val">${esc(p.text)}</span></li>`).join('')}</ul>
        <p class="ps-faint">${esc(a.processesMeasure)}</p></div>`
    : `<div class="ps-act-col">${empty({ icon: 'activity', title: 'Processus non lus', text: a.hint ?? 'L’inventaire complet ajoute les processus.', action: { id: 'inventory.deep', label: 'Inventaire complet', icon: 'layers' } })}</div>`;
  const events = `<div class="ps-act-col"><h4>Journal Système (3 jours)</h4>${a.events.length
    ? `<ul class="ps-events">${a.events.map((e) => `<li data-tone="${e.level === 'warn' ? 'warn' : 'info'}"><span class="ps-dot" data-tone="${e.level === 'warn' ? 'warn' : 'info'}" aria-hidden="true"></span><span>${esc(e.source)}</span><b>${int(e.count)}</b></li>`).join('')}</ul>`
    : ''}<p class="ps-faint">${esc(a.eventsText)}</p></div>`;
  return `<section class="card ps-card span-12 reveal">${cardHead('activity', 'Activité du poste', 'Services, processus et erreurs du journal Système')}<div class="ps-activity">${services}${processes}${events}</div></section>`;
}

function countsCard(b) {
  return `<section class="card ps-card span-4 reveal">${cardHead('hash', 'Comptages de l’inventaire', 'Une source qui a répondu sans élément vaut « 0 »')}
    <div class="ps-tiles">${b.counts.map((t) => `<div class="ps-tile" data-tone="${esc(t.state ?? '')}" tabindex="0" data-tip="${esc(t.detail)}">
      <b>${t.value == null ? '—' : int(t.value)}</b><span>${esc(t.label)}</span><small>${esc(t.detail)}</small></div>`).join('')}</div></section>`;
}

function sectionCard(s) {
  return `<details class="card ps-card ps-detail reveal" data-tone="${esc(s.state)}">
    <summary><span class="ps-detail-mark" aria-hidden="true">${ico(s.state === 'ok' ? 'check' : s.state === 'off' ? 'minus' : 'eye')}</span><span class="ps-detail-title">${esc(s.title)}</span>
      <span class="ps-detail-value">${esc(s.value)}</span><span class="ps-detail-chev" aria-hidden="true">${ico('chevronDown')}</span></summary>
    <p class="ps-faint">${esc(s.detail)}</p>${facts(s.facts)}</details>`;
}

export { fact, size, errorText, pct };
