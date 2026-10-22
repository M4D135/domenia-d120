// Audit AD · « Contrôleurs »: list of the controllers (AUD-004), targeted diagnosis of 1 to 10 of them without
// administrative rights (AUD-005) with inbound replication per partner (AUD-006), privileged read of their directory
// services after a confirmation (AUD-007), and the comparison of the audited object between controllers (AUD-008). An
// unreachable controller is « Non lu », never « en panne »; nothing runs on the controllers.
import { icon } from '../../icons.js';
import { glyph } from '../../kit/glyphs.js';
import { createTabs } from '../../kit/tabs.js';
import { createGrid } from '../../kit/grid.js';
import { confirmDialog } from '../../kit/dialog.js';
import { esc } from '../../ui.js';
import { num, plural, when, factsMarkup, statusMarkup, emptyMarkup, skeletonMarkup, paint, reported, tonePill, fitGrid } from './shared.js';

const MAX = 10;

/**
 * @param {HTMLElement} panel
 * @param {any} app  Page context.
 */
export function createControllersTab(panel, app) {
  const st = { list: null, chosen: new Set(), health: null, services: null, comparison: null, busy: new Map(), status: null, statusTone: 'info', result: 'synthese' };
  let tabs = null;
  const grids = new Map();
  const cleanups = [];

  panel.innerHTML = `<div class="aud-dc">
    <div class="aud-dc-bar card">
      <div class="aud-dc-intro"><h2>Contrôleurs du domaine</h2><p>Listez les contrôleurs, choisissez-en jusqu’à ${MAX}, puis lancez le diagnostic : DNS, ports LDAP et Kerberos, heure, synchronisation et réplication entrante.</p></div>
      <div class="aud-dc-actions"></div>
    </div>
    <div class="aud-dc-status"></div>
    <div class="aud-dc-tiles"></div>
    <div class="aud-dc-results"></div>
  </div>`;
  const actions = panel.querySelector('.aud-dc-actions');
  const statusHost = panel.querySelector('.aud-dc-status');
  const tilesHost = panel.querySelector('.aud-dc-tiles');
  const resultsHost = panel.querySelector('.aud-dc-results');

  function btn(action, label, iconName, { primary = false, disabled = false, reason = '', net = true } = {}) {
    const busy = st.busy.has(action);
    return `<button class="btn ${primary ? 'primary' : 'subtle'}${net ? ' is-net' : ''}" type="button" data-dc="${action}"${busy || disabled ? ' aria-disabled="true"' : ''}
      data-tip="${esc(reason || (net ? 'Lecture réseau : part seulement sur ce clic' : ''))}">${busy ? '<span class="k-spin" aria-hidden="true"></span>' : glyph(iconName)}<span>${esc(label)}</span>${net ? '<span class="k-cmd-net" aria-hidden="true"></span>' : ''}</button>`;
  }

  function renderActions() {
    const n = st.chosen.size;
    const target = app.currentTarget();
    actions.innerHTML = btn('list', st.list ? 'Relire la liste' : 'Lister les contrôleurs', 'server', { primary: !st.list })
      + btn('probe', n ? `Diagnostiquer (${n})` : 'Diagnostiquer la sélection', 'activity', { primary: Boolean(st.list), disabled: !n, reason: n ? '' : 'Choisissez au moins un contrôleur.' })
      + btn('services', 'Lire les services', 'settings', { disabled: !n, reason: n ? 'Sonde privilégiée (droits d’administration), sur confirmation : aucun service n’est démarré ni arrêté.' : 'Choisissez au moins un contrôleur.' })
      + btn('compare', target ? `Comparer ${target.name}` : 'Comparer l’objet', 'split', {
        disabled: !n || !target,
        reason: !target ? 'Choisissez d’abord un objet dans l’onglet Objet.' : !n ? 'Choisissez au moins un contrôleur.' : `Lit ${target.name} sur chaque contrôleur choisi, avec la version et la date d’origine de chaque attribut.`,
      });
  }

  function renderStatus() {
    statusHost.innerHTML = st.status ? statusMarkup(st.status, st.statusTone, { busy: st.busy.size > 0 }) : '';
  }

  function healthOf(dns) {
    return st.health?.rows.find((r) => r.controller.toLowerCase() === dns.toLowerCase()) ?? null;
  }

  function tileMarkup(dc, n) {
    const on = st.chosen.has(dc.dnsName);
    const h = healthOf(dc.dnsName);
    const tone = h ? h.tone : 'off';
    const metric = (label, value, t) => `<li data-tone="${t}"><span>${esc(label)}</span><b>${esc(value)}</b></li>`;
    return `<button type="button" class="aud-dc-tile card spot reveal${on ? ' chosen' : ''}${h ? ' probed' : ''}" role="checkbox" aria-checked="${on}" data-pick="${esc(dc.dnsName)}" data-tone="${tone}" data-i="${n}">
      <span class="aud-dc-check" aria-hidden="true">${glyph('check')}</span>
      <div class="aud-dc-top"><span class="aud-dc-ico" aria-hidden="true">${icon('server')}</span>
        <div class="aud-dc-names"><b>${esc(dc.name)}</b><span class="mono">${esc(dc.dnsName)}</span></div>
        ${h ? `<span class="aud-dc-verdict">${tonePill(h.tone, h.verdictLabel, { icon: h.verdict === 'clear' ? 'check' : h.verdict === 'check' ? 'eye' : 'wifiOff' })}</span>` : ''}</div>
      <div class="aud-dc-meta">${glyph('domain')}<span>${esc(dc.site ?? 'Site non lu')}</span><span class="sep">·</span><span>${esc(dc.operatingSystem ?? '—')}</span></div>
      <div class="aud-dc-roles">${dc.roles.map((r) => `<span class="chip">${esc(r)}</span>`).join('') || '<span class="aud-muted">Aucun rôle particulier</span>'}</div>
      ${h ? `<ul class="aud-dc-metrics" role="list">
        ${metric('LDAP 389', h.ldap === true ? 'oui' : h.ldap === false ? 'non' : '—', h.ldap ? 'ok' : 'off')}
        ${metric('Kerberos 88', h.kerberos === true ? 'oui' : h.kerberos === false ? 'non' : '—', h.kerberos ? 'ok' : 'off')}
        ${metric('Heure', Number.isFinite(h.skewSeconds) ? `${h.skewSeconds > 0 ? '+' : h.skewSeconds < 0 ? '−' : ''}${num(Math.abs(Math.round(h.skewSeconds)))} s` : '—', Number.isFinite(h.skewSeconds) && Math.abs(h.skewSeconds) <= 300 ? 'ok' : 'off')}
        ${metric('Synchronisé', h.synchronized, h.synchronized === 'Oui' ? 'ok' : 'off')}
        ${metric('Échecs', Number.isFinite(h.failures) ? num(h.failures) : '—', h.failures ? 'warn' : 'ok')}
      </ul>` : '<p class="aud-dc-hint">Non diagnostiqué : choisissez-le, puis « Diagnostiquer ».</p>'}
    </button>`;
  }

  function renderTiles() {
    if (st.busy.has('list') && !st.list) { tilesHost.innerHTML = `<div class="aud-dc-grid">${skeletonMarkup(3, 'tile')}${skeletonMarkup(3, 'tile')}</div>`; return; }
    if (!st.list) {
      tilesHost.innerHTML = `<div class="card">${emptyMarkup({
        icon: 'server', title: 'Contrôleurs non lus', text: 'La liste lit les comptes des contrôleurs du domaine (100 au plus) et l’émulateur PDC, sans aucune sonde réseau.',
        action: `<button class="btn primary" type="button" data-dc="list">${glyph('server')}Lister les contrôleurs</button>`,
      })}</div>`;
      return;
    }
    tilesHost.innerHTML = `<div class="aud-dc-head"><h3>${plural(st.list.controllers.length, 'contrôleur', 'contrôleurs')}</h3>
      <span class="aud-muted">${plural(st.chosen.size, 'choisi', 'choisis')} sur ${MAX} au plus</span>
      <button type="button" class="btn ghost sm" data-dc="all">${glyph('check')}Tout choisir</button></div>
      <div class="aud-dc-grid" role="group" aria-label="Contrôleurs à diagnostiquer">${st.list.controllers.map(tileMarkup).join('')}</div>`;
    paint(tilesHost);
    app.reveal(tilesHost);
  }

  function destroyGrids() {
    grids.forEach((g) => g.destroy());
    grids.clear();
  }

  /** A grid sized to the rows it shows, kept for « Copier la vue » (rows as displayed). */
  function resultGrid(name, host, options, rows, max) {
    const fit = fitGrid(max);
    const grid = fit.bind(createGrid(host, { ...options, height: '240px', onFilterChange: fit.onFilterChange }), rows.length);
    grid.setRows(rows);
    grids.set(name, grid);
    return grid;
  }
  const shownRows = (name, rows) => grids.get(name)?.getVisibleRows() ?? rows;

  function renderResults() {
    destroyGrids();
    tabs?.destroy();
    tabs = null;
    if (!st.health && !st.services && !st.comparison) { resultsHost.innerHTML = ''; return; }
    resultsHost.innerHTML = '<div class="card aud-dc-res"></div>';
    tabs = createTabs(resultsHost.querySelector('.aud-dc-res'), {
      label: 'Résultats du diagnostic',
      selected: st.result,
      tabs: [
        { id: 'synthese', label: 'Synthèse', icon: 'activity', count: st.health ? st.health.rows.length : null, tone: st.health?.rows.some((r) => r.verdict === 'check') ? 'warn' : 'ok', disabled: !st.health, reason: 'Lancez d’abord le diagnostic.', render: renderHealth },
        { id: 'replication', label: 'Réplication', icon: 'sync', count: st.health ? st.health.neighbors.length : null, tone: st.health?.neighbors.some((r) => r.failures > 0) ? 'warn' : 'ok', disabled: !st.health, reason: 'Lancez d’abord le diagnostic.', render: renderReplication },
        { id: 'services', label: 'Services', icon: 'settings', count: st.services ? st.services.rows.filter((r) => r.tone === 'warn').length : null, tone: 'warn', disabled: !st.services, reason: 'Lisez d’abord les services.', render: renderServices },
        { id: 'comparaison', label: 'Comparaison', icon: 'split', count: st.comparison ? st.comparison.differences : null, tone: st.comparison?.differences ? 'warn' : 'ok', disabled: !st.comparison, reason: 'Comparez d’abord un objet.', render: renderComparison },
      ],
      onChange: (id) => { st.result = id; },
    });
  }

  function renderHealth(p) {
    const h = st.health;
    p.innerHTML = `<div class="aud-health-cards">${h.rows.map((r, n) => `<article class="aud-health reveal" data-tone="${esc(r.tone)}" data-i="${n}">
        <header>${tonePill(r.tone, r.verdictLabel)}<b class="mono">${esc(r.controller)}</b></header>
        <dl><div><dt>Joignable</dt><dd>${esc(r.reach)}</dd></div><div><dt>Heure</dt><dd>${esc(r.time)}</dd></div><div><dt>Synchronisé</dt><dd>${esc(r.synchronized)}</dd></div>
          <div><dt>Réplication entrante</dt><dd>${esc(r.replication)}</dd></div><div><dt>DNS</dt><dd>${esc(r.dns)}</dd></div></dl>
        ${r.reasons.length ? `<ul class="aud-reasons${r.verdict === 'notRead' ? '' : ' warn'}" role="list">${r.reasons.map((x) => `<li>${glyph(r.verdict === 'notRead' ? 'wifiOff' : 'alert')}${esc(x)}</li>`).join('')}</ul>` : `<p class="aud-ok-line">${glyph('check')}Aucun écart constaté.</p>`}
      </article>`).join('')}</div>
      <h4 class="aud-h4">Enregistrements DNS et écarts calculés</h4>${factsMarkup(h.facts, { compact: true })}
      <p class="aud-foot-note">Lu ${when(h.readAt)}. Un contrôleur injoignable est « Non lu », jamais déclaré en panne.</p>`;
    paint(p);
    app.reveal(p);
  }

  function renderReplication(p) {
    p.innerHTML = '<div class="aud-grid-host"></div><p class="aud-foot-note">Liens de réplication entrants lus sur chaque contrôleur. 1601 = « Jamais » ; un refus de lecture n’est pas une panne.</p>';
    resultGrid('replication', p.querySelector('.aud-grid-host'), {
      key: 'audit.replication.v2', label: 'Liens de réplication entrants', rowId: (r) => `${r.controller}|${r.partner}|${r.partition}`, selection: 'none',
      columns: [
        { id: 'controller', label: 'Contrôleur', width: 170, mono: true },
        { id: 'partner', label: 'Partenaire', width: 110 },
        { id: 'partition', label: 'Partition', width: 250, mono: true },
        { id: 'result', label: 'Résultat', width: 240, html: (v, r) => tonePill(r.tone, v, { fit: true }) },
        { id: 'lastSuccess', label: 'Dernier succès', type: 'date', width: 140, format: (v, r) => (r.never ? 'Jamais' : r.lastSuccessLabel) },
        { id: 'lastAttempt', label: 'Dernière tentative', type: 'date', width: 150 },
        { id: 'failures', label: 'Échecs', type: 'number', width: 100, tip: 'Échecs consécutifs' },
      ],
    }, st.health.neighbors, 480);
  }

  function renderServices(p) {
    p.innerHTML = `${statusMarkup(st.services.summary, st.services.skipped ? 'warn' : 'info')}<div class="aud-grid-host"></div>`;
    resultGrid('services', p.querySelector('.aud-grid-host'), {
      key: 'audit.services.v2', label: 'Services de l’annuaire des contrôleurs', rowId: (r) => `${r.controller}|${r.service}`, selection: 'none',
      columns: [
        { id: 'controller', label: 'Contrôleur', width: 190, mono: true },
        { id: 'service', label: 'Service', width: 120, mono: true },
        { id: 'state', label: 'État', width: 170 },
        { id: 'startMode', label: 'Démarrage', width: 130 },
        { id: 'finding', label: 'Constat', width: 360, html: (v, r) => tonePill(r.tone, v, { fit: true }) },
      ],
    }, st.services.rows, 520);
  }

  function renderComparison(p) {
    const c = st.comparison;
    const head = c.controllers.map((dc) => `<th scope="col">${esc(dc)}</th>`).join('');
    const rows = c.rows.map((r, n) => `<tr class="${r.identical ? '' : 'diff'}" data-i="${n}"><th scope="row">${r.identical ? '' : glyph('alert')}${esc(r.attribute)}</th>
      ${c.controllers.map((dc) => {
        const cell = r.values.find((v) => v.controller === dc);
        if (!cell) return '<td class="aud-muted">Non lu</td>';
        return `<td><span class="val">${esc(cell.value || '—')}</span>${cell.version ? `<small>v${num(cell.version)}${cell.changedAt ? ` · ${when(cell.changedAt)}` : ''}${cell.origin ? ` · origine ${esc(cell.origin)}` : ''}</small>` : ''}</td>`;
      }).join('')}</tr>`).join('');
    p.innerHTML = `${statusMarkup(c.summary, c.differences ? 'warn' : c.comparable ? 'ok' : 'off')}
      <div class="aud-compare-scroll"><table class="table aud-compare"><thead><tr><th scope="col">Attribut</th>${head}</tr></thead><tbody>${rows}</tbody></table></div>
      ${c.notRead.length ? `<ul class="aud-reasons" role="list">${c.notRead.map((x) => `<li>${glyph('wifiOff')}${esc(x)}</li>`).join('')}</ul>` : ''}
      <p class="aud-foot-note">${esc(c.note)} Lu ${when(c.readAt)}.</p>`;
    paint(p);
  }

  function renderAll() {
    renderActions();
    renderStatus();
    renderTiles();
    renderResults();
  }

  // ---------- Reads ----------

  async function call(action, op, args, apply, label) {
    if (st.busy.has(action)) return;
    // Guard of its own kind (« dc-probe »…): a newer list replaces only an older list; a new target never cancels it (AUD-003).
    const token = app.guard.next(`dc-${action}`);
    st.busy.set(action, token);
    st.status = label;
    st.statusTone = 'info';
    app.busy(action, true);
    renderActions();
    renderStatus();
    if (action === 'list') renderTiles();
    try {
      const result = await app.ctx.call(op, args);
      if (!app.alive() || !app.guard.current(token)) return;
      apply(result);
    } catch (err) {
      if (!app.alive() || !app.guard.current(token)) return;
      st.status = reported(err);
      st.statusTone = 'alert';
      app.toast(st.status, { tone: 'alert' });
    } finally {
      // The busy state is released by the read that set it, even when its result is no longer applied.
      if (app.alive() && st.busy.get(action) === token) {
        st.busy.delete(action);
        app.busy(action, false);
        renderAll();
      }
    }
  }

  const chosen = () => [...st.chosen].slice(0, MAX);

  function list() {
    return call('list', 'audit.dc.list', {}, (r) => {
      st.list = r;
      const known = new Set(r.controllers.map((c) => c.dnsName));
      st.chosen = new Set([...st.chosen].filter((c) => known.has(c)));
      st.status = r.summary;
      st.statusTone = 'info';
    }, 'Lecture des comptes des contrôleurs…');
  }

  function probe() {
    const dcs = chosen();
    if (!dcs.length) return null;
    return call('probe', 'audit.dc.probe', { controllers: dcs }, (r) => {
      st.health = r;
      st.result = 'synthese';
      st.status = `${r.summary} Lu ${new Date(r.readAt).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })}.`;
      st.statusTone = r.rows.some((x) => x.verdict === 'check') ? 'warn' : 'ok';
    }, `Diagnostic de ${plural(dcs.length, 'contrôleur', 'contrôleurs')} : DNS, ports, heure et réplication…`);
  }

  async function services() {
    const dcs = chosen();
    if (!dcs.length) return;
    const ok = await confirmDialog({
      title: 'Lire les services des contrôleurs ?',
      message: `Lecture par CIM de l’état des services de l’annuaire sur ${plural(dcs.length, 'contrôleur', 'contrôleurs')}. Cette sonde demande des droits d’administration sur chaque contrôleur ; aucun service n’est démarré ni arrêté.`,
      confirmLabel: 'Lire les services',
    });
    if (!ok || !app.alive()) return;
    await call('services', 'audit.dc.services', { controllers: dcs }, (r) => {
      st.services = r;
      st.result = 'services';
      st.status = r.summary;
      st.statusTone = r.rows.some((x) => x.tone === 'warn') ? 'warn' : 'ok';
    }, `Lecture des services de ${plural(dcs.length, 'contrôleur', 'contrôleurs')}…`);
  }

  function compare() {
    const dcs = chosen();
    const target = app.currentTarget();
    if (!dcs.length || !target) return;
    call('compare', 'audit.dc.compare', { dn: target.dn, controllers: dcs }, (r) => {
      st.comparison = r;
      st.result = 'comparaison';
      st.status = r.summary;
      st.statusTone = r.differences ? 'warn' : 'ok';
    }, `Lecture de ${target.name} sur ${plural(dcs.length, 'contrôleur', 'contrôleurs')}…`);
  }

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const act = t.closest('[data-dc]');
    if (act) {
      if (act.getAttribute('aria-disabled') === 'true') return;
      const a = act.dataset.dc;
      if (a === 'list') list();
      else if (a === 'probe') probe();
      else if (a === 'services') services();
      else if (a === 'compare') compare();
      else if (a === 'all' && st.list) {
        st.chosen = new Set(st.list.controllers.slice(0, MAX).map((c) => c.dnsName));
        renderActions();
        renderTiles();
      }
      return;
    }
    const tile = t.closest('[data-pick]');
    if (tile) {
      const dns = tile.dataset.pick;
      if (st.chosen.has(dns)) st.chosen.delete(dns);
      else if (st.chosen.size >= MAX) { app.toast(`Diagnostic borné à ${MAX} contrôleurs.`, { tone: 'warn' }); return; }
      else st.chosen.add(dns);
      tile.classList.toggle('chosen', st.chosen.has(dns));
      tile.setAttribute('aria-checked', String(st.chosen.has(dns)));
      renderActions();
      tilesHost.querySelector('.aud-dc-head .aud-muted').textContent = `${plural(st.chosen.size, 'choisi', 'choisis')} sur ${MAX} au plus`;
    }
  };
  panel.addEventListener('click', onClick);
  cleanups.push(() => panel.removeEventListener('click', onClick));

  renderAll();

  return {
    /** Gesture by the address (?lancer=diagnostic): lists, chooses every controller (10 at most) and probes them. */
    async launch(kind) {
      await list();
      if (kind === 'diagnostic' && st.list) {
        st.chosen = new Set(st.list.controllers.slice(0, MAX).map((c) => c.dnsName));
        await probe();
      }
    },
    refreshTarget: renderActions,
    sections() {
      const out = [];
      if (st.list) out.push({ title: 'Contrôleurs', summary: st.list.summary, columns: [
        { label: 'Contrôleur', get: (c) => c.dnsName }, { label: 'Site', get: (c) => c.site ?? '' }, { label: 'Système', get: (c) => c.operatingSystem ?? '' }, { label: 'Rôle', get: (c) => c.roles.join(', ') },
      ], rows: st.list.controllers });
      if (st.health) {
        out.push({ title: 'Synthèse du diagnostic', summary: st.health.summary, columns: [
          { label: 'Contrôleur', get: (r) => r.controller }, { label: 'Verdict', get: (r) => r.verdictLabel }, { label: 'Joignable', get: (r) => r.reach }, { label: 'Heure', get: (r) => r.time },
          { label: 'Synchronisé', get: (r) => r.synchronized }, { label: 'Réplication entrante', get: (r) => r.replication }, { label: 'Échecs', get: (r) => r.failures ?? '' }, { label: 'DNS', get: (r) => r.dns }, { label: 'Détail', get: (r) => r.detail },
        ], rows: st.health.rows });
        out.push({ title: 'Faits', columns: [{ label: 'Élément', get: (f) => f.label }, { label: 'Valeur', get: (f) => f.value }, { label: 'État', get: (f) => f.stateLabel }, { label: 'Limite', get: (f) => f.limit ?? '' }], rows: st.health.facts });
        out.push({ title: 'Réplication', columns: [
          { label: 'Contrôleur', get: (r) => r.controller }, { label: 'Partenaire', get: (r) => r.partner }, { label: 'Partition', get: (r) => r.partition }, { label: 'Dernier succès', get: (r) => r.lastSuccessLabel },
          { label: 'Dernière tentative', get: (r) => r.lastAttemptLabel }, { label: 'Résultat', get: (r) => r.result }, { label: 'Échecs consécutifs', get: (r) => r.failures },
        ], rows: shownRows('replication', st.health.neighbors) });
      }
      if (st.services) out.push({ title: 'Services', summary: st.services.summary, columns: [
        { label: 'Contrôleur', get: (r) => r.controller }, { label: 'Service', get: (r) => r.service ?? '' }, { label: 'État', get: (r) => r.state }, { label: 'Démarrage', get: (r) => r.startMode }, { label: 'Constat', get: (r) => r.finding },
      ], rows: shownRows('services', st.services.rows) });
      if (st.comparison) out.push({ title: `Comparaison · ${st.comparison.name}`, summary: st.comparison.summary, columns: [
        { label: 'Attribut', get: (r) => r.attribute }, ...st.comparison.controllers.map((dc) => ({ label: dc, get: (r) => r.values.find((v) => v.controller === dc)?.value ?? 'Non lu' })),
      ], rows: st.comparison.rows });
      return out.length ? out : [{ title: 'Contrôleurs', summary: 'Contrôleurs non lus : rien à copier.' }];
    },
    destroy() {
      destroyGrids();
      tabs?.destroy();
      cleanups.forEach((fn) => fn());
    },
  };
}
