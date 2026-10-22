// Panels of the top bar and the menu foot: notification centre (TRV-172 improvement: closed banners of the session are kept),
// operations of the session (TRV-049), session details (TRV-051 improvement) and « À propos de Domenia » (TRV-052).
import { icon } from '../icons.js';
import { esc, relTime, formatDateTime, formatTime, copyText, announce } from '../ui.js';
import { openDrawer } from '../kit/index.js';
import { state, quietCall, on, simulation } from './store.js';
import { openPopover, closePopover } from './popover.js';
import { notes, markAllRead, clearNotes, supportText, unreadCount } from './notify.js';
import { followRoute } from './help.js';

const NBSP = ' ';
const TONE_ICONS = { ok: 'check', info: 'info', warn: 'alert', alert: 'alert', off: 'info' };
const TONE_WORDS = { ok: 'Terminé', info: 'Information', warn: 'Attention', alert: 'Erreur', off: 'Information' };

let go = () => {};

/** app.js hands the navigation function (route id, params). */
export function setNavigator(fn) { go = fn; }

function dayLabel(t) {
  const d = new Date(t);
  const today = new Date();
  const y = new Date(); y.setDate(today.getDate() - 1);
  if (d.toDateString() === today.toDateString()) return 'Aujourd’hui';
  if (d.toDateString() === y.toDateString()) return 'Hier';
  return d.toLocaleDateString('fr-FR', { weekday: 'long', day: 'numeric', month: 'long' });
}

// ---------- Notification centre ----------

let centreTab = 'notifications';
let centreFilter = 'all';

/** Opens the notification centre under the bell (tab « notifications » or « journal »). */
export function openCentre(anchor, tab = 'notifications') {
  centreTab = tab;
  return openPopover(anchor, {
    id: 'centre',
    title: 'Centre de notifications',
    width: 460,
    head: `<button class="btn ghost xs" type="button" data-centre="read">${icon('check')}Tout marquer lu</button>
      <button class="btn ghost icon xs" type="button" data-centre="clear" aria-label="Effacer les notifications" data-tip="Effacer les notifications de la session">${icon('trash')}</button>`,
    render(body, ctl) {
      ctl.el.querySelector('[data-centre="read"]').addEventListener('click', () => { markAllRead(); paint(); });
      ctl.el.querySelector('[data-centre="clear"]').addEventListener('click', () => { clearNotes(); paint(); announce('Notifications de la session effacées.'); });
      body.innerHTML = `<div class="sh-centre">
        <div class="segmented sh-centre-tabs" role="tablist" aria-label="Contenu du centre">
          <button type="button" role="tab" data-tab="notifications">${icon('bell')}Notifications</button>
          <button type="button" role="tab" data-tab="journal">${icon('activity')}Journal des opérations</button>
        </div>
        <div class="sh-centre-filters" role="group" aria-label="Filtrer les notifications"></div>
        <div class="sh-centre-list" tabindex="-1"></div>
      </div>`;
      const list = body.querySelector('.sh-centre-list');
      const filters = body.querySelector('.sh-centre-filters');
      const paint = async () => {
        body.querySelectorAll('[data-tab]').forEach((b) => {
          b.setAttribute('aria-selected', String(b.dataset.tab === centreTab));
          b.setAttribute('aria-pressed', String(b.dataset.tab === centreTab));
        });
        filters.hidden = centreTab !== 'notifications';
        if (centreTab === 'journal') { await paintJournal(list); return; }
        const all = notes();
        const counts = { all: all.length, alert: all.filter((n) => n.tone === 'alert').length, warn: all.filter((n) => n.tone === 'warn').length, info: all.filter((n) => n.tone === 'info' || n.tone === 'ok').length };
        filters.innerHTML = [['all', 'Toutes'], ['alert', 'Erreurs'], ['warn', 'Attention'], ['info', 'Informations']]
          .map(([id, label]) => `<button class="k-facet" type="button" data-filter="${id}" aria-pressed="${centreFilter === id}">${esc(label)}<span class="k-facet-n">${counts[id]}</span></button>`).join('');
        const shown = all.filter((n) => centreFilter === 'all' || (centreFilter === 'info' ? (n.tone === 'info' || n.tone === 'ok') : n.tone === centreFilter));
        if (!shown.length) {
          list.innerHTML = `<div class="sh-empty-mini">${icon('bell')}<p><strong>Aucune notification</strong> ${all.length ? 'pour ce filtre.' : 'dans cette session.'}</p><p class="faint">Les messages fermés restent ici jusqu’à la fin de la session.</p></div>`;
          return;
        }
        let day = '';
        list.innerHTML = shown.map((n) => {
          const d = dayLabel(n.at);
          const head = d !== day ? `<h3 class="sh-centre-day">${esc(d)}</h3>` : '';
          day = d;
          return `${head}<article class="sh-centre-item${n.read ? '' : ' unread'}" data-tone="${n.tone}" data-id="${n.id}">
            <span class="sh-centre-icon">${icon(TONE_ICONS[n.tone] ?? 'info')}</span>
            <div class="sh-centre-main">
              <div class="sh-centre-meta"><span class="sh-centre-kind">${esc(TONE_WORDS[n.tone] ?? '')}</span>${n.code ? `<span class="mono">${esc(n.code)}</span>` : ''}${n.count > 1 ? `<span class="k-badge ${n.tone === 'alert' ? 'alert' : 'warn'}">×${n.count}</span>` : ''}<time datetime="${new Date(n.at).toISOString()}" title="${esc(formatDateTime(new Date(n.at).toISOString()) ?? '')}">${esc(relTime(new Date(n.at).toISOString()) ?? '')}</time></div>
              <p class="sh-centre-text">${esc(n.headline)}</p>
              ${n.body ? `<p class="sh-centre-body">${esc(n.body)}</p>` : ''}
              <div class="sh-centre-actions">
                ${n.route ? `<button class="btn xs subtle" type="button" data-act="route">${icon('chevronRight')}Aller à ${esc(n.routeLabel)}</button>` : ''}
                ${n.tone === 'warn' || n.tone === 'alert' ? `<button class="btn xs ghost" type="button" data-act="support">${icon('copy')}Copier pour le support</button>` : ''}
                ${n.detail ? `<details class="sh-centre-detail"><summary>Détail</summary><pre>${esc(n.detail)}</pre></details>` : ''}
              </div>
            </div>
          </article>`;
        }).join('');
      };
      body.addEventListener('click', (e) => {
        const t = e.target instanceof Element ? e.target : null;
        const tab = t?.closest('[data-tab]');
        if (tab) { centreTab = tab.dataset.tab; paint(); return; }
        const filter = t?.closest('[data-filter]');
        if (filter) { centreFilter = filter.dataset.filter; paint(); return; }
        const act = t?.closest('[data-act]');
        const item = t?.closest('.sh-centre-item');
        if (!act || !item) return;
        const n = notes().find((x) => String(x.id) === item.dataset.id);
        if (!n) return;
        if (act.dataset.act === 'route') { ctl.close(); followRoute(n.route); }
        if (act.dataset.act === 'support') copyText(supportText(n)).then((ok) => announce(ok ? 'Copié pour le support.' : 'Copie impossible.'));
        if (act.dataset.act === 'open-ops') { ctl.close(); go('operations'); }
      });
      paint();
      // Opening the centre is reading what it shows.
      setTimeout(markAllRead, 1200);
      // The banners are all in the list while the centre is open: they step aside instead of covering it.
      document.documentElement.classList.add('sh-centre-open');
      const off = on('notes', () => { if (centreTab === 'notifications') paint(); });
      return () => { off(); document.documentElement.classList.remove('sh-centre-open'); };
    },
  });
}

async function paintJournal(list) {
  list.innerHTML = '<div class="sh-loading" aria-busy="true"><span class="k-spin"></span>Lecture du journal de la session…</div>';
  let activity = null;
  try { activity = await quietCall('shell.activity'); } catch (err) { console.warn(err); }
  const lines = activity?.journal ?? [];
  if (!lines.length) {
    list.innerHTML = `<div class="sh-empty-mini">${icon('activity')}<p><strong>Aucune opération</strong> enregistrée dans cette session.</p><p class="faint">Actualisations, changements d’OU de travail, écritures et exports s’inscrivent ici.</p></div>`;
    return;
  }
  list.innerHTML = `<ol class="sh-journal">${lines.map((l) => `<li data-tone="${esc(l.tone)}"><span class="dot" aria-hidden="true"></span><span class="sh-journal-label">${esc(l.label)}</span><time datetime="${esc(l.at)}" title="${esc(formatDateTime(l.at) ?? '')}">${esc(formatTime(l.at) ?? '')}</time></li>`).join('')}</ol>
    <div class="sh-pop-foot"><button class="btn sm subtle" type="button" data-act-ops>${icon('activity')}Ouvrir Opérations</button></div>`;
  list.querySelector('[data-act-ops]').addEventListener('click', () => { closePopover(); go('operations'); });
}

// ---------- Operations of the session ----------

/** Opens the operations of the session under the « Opérations » button. */
export function openActivity(anchor, refresh) {
  return openPopover(anchor, {
    id: 'activity',
    title: 'Opérations de la session',
    width: 400,
    render(body, ctl) {
      body.innerHTML = '<div class="sh-loading" aria-busy="true"><span class="k-spin"></span>Lecture de l’activité…</div>';
      const paint = (a) => {
        if (!a) {
          body.innerHTML = `<div class="sh-empty-mini">${icon('activity')}<p><strong>Activité indisponible</strong> dans cet aperçu.</p></div>`;
          return;
        }
        const r = a.receipts;
        const tile = (label, value, tone, sub) => `<div class="sh-tile" data-tone="${tone}"><span class="sh-tile-v">${esc(value)}</span><span class="sh-tile-l">${esc(label)}</span>${sub ? `<span class="sh-tile-s">${esc(sub)}</span>` : ''}</div>`;
        body.innerHTML = `<div class="sh-activity">
          <div class="sh-tiles">
            ${tile('Lectures en cours', a.tasks.running, a.tasks.running ? 'info' : 'off')}
            ${tile('En attente', a.tasks.queued, a.tasks.queued ? 'info' : 'off')}
            ${tile('Reçus à vérifier', r.available ? r.pending : '—', !r.available ? 'warn' : r.pending ? 'warn' : 'ok', r.available ? `${r.total} conservé${r.total > 1 ? 's' : ''}` : 'illisibles')}
          </div>
          ${a.tasks.running ? '<div class="sh-progress" role="progressbar" aria-label="Lectures en cours"><span></span></div>' : ''}
          <p class="sh-activity-detail">${esc(a.detail)}</p>
          <h3 class="sh-sub">Dernières opérations</h3>
          ${a.journal.length ? `<ol class="sh-journal">${a.journal.slice(0, 8).map((l) => `<li data-tone="${esc(l.tone)}"><span class="dot" aria-hidden="true"></span><span class="sh-journal-label">${esc(l.label)}</span><time datetime="${esc(l.at)}">${esc(formatTime(l.at) ?? '')}</time></li>`).join('')}</ol>` : '<p class="faint">Aucune opération dans cette session.</p>'}
          <div class="sh-pop-foot">
            <button class="btn sm subtle" type="button" data-go="verifier"${r.pending ? '' : ' aria-disabled="true" data-reason="Aucun reçu à vérifier."'}>${icon('shield')}Vérifier les reçus</button>
            <button class="btn sm primary" type="button" data-go="operations">${icon('activity')}Ouvrir Opérations</button>
          </div>
        </div>`;
      };
      body.addEventListener('click', (e) => {
        const b = e.target instanceof Element ? e.target.closest('[data-go]') : null;
        if (!b || b.getAttribute('aria-disabled') === 'true') return;
        ctl.close();
        if (b.dataset.go === 'verifier') go('operations', { filtre: 'verifier' }); else go('operations');
      });
      refresh().then(paint).catch(() => paint(null));
    },
  });
}

// ---------- Session ----------

/** Opens the session details under the connection badge (domain, controller, account, rights, scope, base). */
export function openSession(anchor) {
  return openPopover(anchor, {
    id: 'session',
    title: 'Session et connexion',
    width: 420,
    render(body, ctl) {
      const s = state.session;
      const app = state.app;
      if (!s) {
        body.innerHTML = `<div class="sh-empty-mini">${icon('wifiOff')}<p><strong>Session non lue</strong> pour l’instant.</p></div>`;
        return;
      }
      const reach = state.reach;
      const status = reach.offline
        ? { tone: 'alert', text: `Annuaire injoignable${reach.since ? ` depuis ${formatTime(new Date(reach.since).toISOString())}` : ''} · données déjà lues seulement` }
        : reach.slow ? { tone: 'warn', text: 'Dernière requête de l’annuaire : délai dépassé (ce n’est pas une coupure).' }
          : { tone: s.connection.state === 'disconnected' ? 'off' : 'ok', text: s.connection.label };
      const row = (label, value, sub = '', mono = false) => `<div class="sh-kv-row"><dt>${esc(label)}</dt><dd${mono ? ' class="mono"' : ''}>${value ? esc(value) : '<span class="faint">—</span>'}${sub ? `<span class="sh-kv-sub">${esc(sub)}</span>` : ''}</dd></div>`;
      const cache = s.cache;
      body.innerHTML = `<div class="sh-session">
        <div class="sh-session-state" data-tone="${status.tone}"><span class="dot pulse" aria-hidden="true"></span><span>${esc(status.text)}</span></div>
        <dl class="sh-kv">
          ${row('Mode', app?.modeLabel ?? (simulation() ? 'Simulation' : 'Annuaire'), app?.modeDetail ?? '')}
          ${row('Domaine', s.domain?.dnsName ?? '', s.domain?.netbiosName ? `NetBIOS ${s.domain.netbiosName}` : '')}
          ${row('Contrôleur interrogé', s.controller?.dnsName ?? '', s.controller?.site ? `Site ${s.controller.site}` : '')}
          ${row('Compte', s.account?.login ?? '', s.account?.displayName ?? '', true)}
          ${row('Authentification', s.authentication?.label ?? '')}
          ${row('Droits', s.rights?.label ?? '', s.rights?.estimated ? `Estimés${NBSP}: ${s.rights.detail}` : s.rights?.detail ?? '')}
          ${row('Écritures', s.readOnly ? 'Lecture seule' : (simulation() ? 'Écritures d’essai sur l’annuaire fictif' : 'Écritures admises'), s.readOnly ? 'Aucune écriture n’est admise dans ce mode.' : 'Chaque écriture passe par un plan, une confirmation, un reçu et une relecture.')}
          ${row('OU de travail', s.scope ? s.scope.label : '', s.scope ? (s.scope.subtree ? 'Sous-OU comprises' : 'Sans les sous-OU') : '')}
          ${row('Base locale', cache ? `${cache.label}${cache.lastReadAt ? ` · lue ${relTime(cache.lastReadAt)}` : ''}` : '', cache ? `${new Intl.NumberFormat('fr-FR').format(cache.objects)} objets${cache.complete ? '' : ' · lecture incomplète'}` : '')}
        </dl>
        <div class="sh-pop-foot">
          <button class="btn sm subtle" type="button" data-go="ou">${icon('folder')}Changer l’OU de travail</button>
          <button class="btn sm ghost" type="button" data-go="about">${icon('info')}À propos</button>
        </div>
      </div>`;
      body.addEventListener('click', (e) => {
        const b = e.target instanceof Element ? e.target.closest('[data-go]') : null;
        if (!b) return;
        ctl.close();
        if (b.dataset.go === 'ou') go('accueil', { ou: 'choisir' });
        if (b.dataset.go === 'about') openAbout();
      });
    },
  });
}

// ---------- About ----------

/** « À propos de Domenia »: version, engines, compatibility of the workstation (local facts, read once per session). */
export function openAbout() {
  const panel = openDrawer({
    title: 'À propos de Domenia',
    subtitle: 'Version, moteurs et compatibilité de ce poste',
    icon: 'info',
    key: 'shell.apropos',
    width: 520,
    body: '<div class="sh-about" aria-busy="true"><div class="skeleton sk sk-title w55"></div><div class="skeleton sk sk-block"></div></div>',
    actions: [
      { id: 'copy', label: 'Copier pour le support', icon: 'copy', run: () => copyText(text).then((ok) => announce(ok ? 'Informations copiées.' : 'Copie impossible.')) },
      { id: 'close', label: 'Fermer', primary: true, run: (p) => p.close() },
    ],
  });
  let text = '';
  Promise.all([quietCall('shell.about').catch(() => null), quietCall('shell.guide.info', { page: state.page?.id && /^[a-z][a-z0-9-]*$/.test(state.page.id) ? state.page.id : 'accueil' }).catch(() => null)]).then(([about, guide]) => {
    const host = panel.body?.querySelector('.sh-about');
    if (!host) return;
    host.removeAttribute('aria-busy');
    const app = state.app;
    const facts = about?.facts ?? (app ? [
      { label: 'Version de Domenia', value: app.version, tone: 'info' },
      { label: '.NET embarqué', value: app.runtime, tone: 'info' },
      { label: 'Mode', value: app.modeLabel, tone: 'info' },
    ] : []);
    text = [`${about?.name ?? 'Domenia'} ${about?.version ?? app?.version ?? ''}`, ...facts.map((f) => `${f.label}${NBSP}: ${f.value}`), about?.compatibility ?? ''].filter(Boolean).join('\r\n');
    host.innerHTML = `<div class="sh-about-hero">
        <span class="brand-mark sh-about-mark" aria-hidden="true">${icon('logo')}</span>
        <div><h3>Domenia 2</h3><p class="muted">Administration Active Directory · version ${esc(about?.version ?? app?.version ?? '—')}</p></div>
      </div>
      <p class="sh-about-verdict" data-tone="${esc(about?.compatibilityTone ?? 'off')}">${icon(about?.compatibilityTone === 'ok' ? 'check' : 'info')}<span>${esc(about?.compatibility ?? 'Compatibilité non évaluée dans cet aperçu.')}</span></p>
      <dl class="sh-kv">${facts.map((f) => `<div class="sh-kv-row" data-tone="${esc(f.tone)}"><dt>${esc(f.label)}</dt><dd>${esc(f.value)}</dd></div>`).join('')}</dl>
      <h3 class="sh-sub">Guides</h3>
      <p class="muted">${esc(guide?.message ?? 'Guides : chapitre de chaque écran indiqué dans l’aide (F1).')}</p>
      <p class="faint sh-about-rules">Les actions restent sous votre contrôle : aucune lecture réseau ni écriture ne part sans votre geste, et rien n’est rejoué automatiquement.</p>`;
  });
  return panel;
}

export { unreadCount };
