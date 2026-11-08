// Panels of the top bar and the menu foot: notification centre (TRV-172 improvement: closed banners of the session are kept),
// operations of the session (TRV-049), session details (TRV-051 improvement) and « À propos de Domenia » (TRV-052).
import { activityInspection } from '../pages/operations/activity-watch.js';
import { icon } from '../icons.js';
import { onEvent } from '../bridge.js';
import { esc, relTime, formatDateTime, formatTime, copyText, announce } from '../ui.js';
import { openDrawer } from '../kit/index.js';
import { state, quietCall, on, simulation } from './store.js';
import { runningTasks, stopFirstTask, elapsedText } from './tasks.js';
import { blockedTime } from './sheets.js';
import { openPopover, closePopover } from './popover.js';
import { notes, markAllRead, clearNotes, supportText, unreadCount } from './notify.js';
import { followRoute } from './help.js';
import { pulse } from './pulse.js';
import { markOf, linesAfter } from '../pages/parametres/pure.js';

const NBSP = ' ';
const TONE_ICONS = { ok: 'check', info: 'info', warn: 'alert', alert: 'alert', off: 'info' };
const TONE_WORDS = { ok: 'Terminé', info: 'Information', warn: 'Attention', alert: 'Erreur', off: 'Information' };

let go = () => {};
let journal = () => {};

/** app.js hands the navigation function (route id, params). */
export function setNavigator(fn) { go = fn; }

/** Same profile-aware action as Ctrl+L, supplied by the shell. */
export function setJournalOpener(fn) { journal = fn; }

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
let journalDisplayMark = null;

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
  const all = activity?.journal ?? [];
  const ordered = all.slice().reverse().map(l => ({ ...l, text: l.label, level: l.tone }));
  const lines = linesAfter(ordered, journalDisplayMark).reverse();
  if (!lines.length) {
    list.innerHTML = `<div class="sh-empty-mini">${icon('activity')}<p><strong>Aucune opération</strong> enregistrée dans cette session.</p><p class="faint">Actualisations, changements d’OU de travail, écritures et exports s’inscrivent ici.</p></div>`;
    return;
  }
  list.innerHTML = `<ol class="sh-journal">${lines.map((l) => `<li data-tone="${esc(l.tone)}"><span class="dot" aria-hidden="true"></span><span class="sh-journal-label">${esc(l.label)}</span><time datetime="${esc(l.at)}" title="${esc(formatDateTime(l.at) ?? '')}">${esc(formatTime(l.at) ?? '')}</time></li>`).join('')}</ol>
    <div class="sh-pop-foot"><button class="btn sm subtle" type="button" data-act-ops>${icon('activity')}Ouvrir Opérations</button><button class="btn sm ghost" type="button" data-clear-journal>Effacer l’affichage</button></div>`;
  list.querySelector('[data-clear-journal]').addEventListener('click', () => {
    journalDisplayMark = markOf(ordered); markAllRead(); paintJournal(list);
  });
  list.querySelector('[data-act-ops]').addEventListener('click', () => { closePopover(); go('operations', { onglet: 'journal' }); });
}

// ---------- Operations of the session ----------

// Reconcile this bounded panel in place: unchanged text (including a selection), focused controls and row identity survive ticks.
function patchActivity(parent, next) {
  const keyed = new Map([...parent.children].filter((n) => n.dataset.activityKey).map((n) => [n.dataset.activityKey, n]));
  let cursor = parent.firstChild;
  for (const fresh of [...next.childNodes]) {
    const key = fresh.nodeType === Node.ELEMENT_NODE ? fresh.dataset.activityKey : null;
    let current = key ? keyed.get(key) : cursor;
    if (current && (current.nodeType !== fresh.nodeType || current.nodeName !== fresh.nodeName
        || (!key && current.nodeType === Node.ELEMENT_NODE && current.dataset.activityKey))) current = null;
    if (!current) { parent.insertBefore(fresh, cursor); continue; }
    if (current !== cursor) parent.insertBefore(current, cursor);
    if (fresh.nodeType === Node.ELEMENT_NODE) {
      for (const attr of [...current.attributes]) if (!fresh.hasAttribute(attr.name)) current.removeAttribute(attr.name);
      for (const attr of [...fresh.attributes]) if (current.getAttribute(attr.name) !== attr.value) current.setAttribute(attr.name, attr.value);
      patchActivity(current, fresh);
    } else if (current.nodeValue !== fresh.nodeValue) current.nodeValue = fresh.nodeValue;
    cursor = current.nextSibling;
  }
  while (cursor) { const nextNode = cursor.nextSibling; cursor.remove(); cursor = nextNode; }
}

/** Opens the operations of the session under the « Opérations » button. */
export function openActivity(anchor, refresh, {
  call = quietCall, events = onEvent, clock = pulse,
  visible = () => document.visibilityState === 'visible', now = Date.now,
} = {}) {
  return openPopover(anchor, {
    id: 'activity',
    title: 'Opérations de la session',
    width: 400,
    render(body, ctl) {
      body.innerHTML = '<div class="sh-loading" aria-busy="true"><span class="k-spin"></span>Lecture de l’activité…</div>';
      // OPE-015: the tasks of the engine come from operations.center (live duration, counters of the batches, stop of a read;
      // a write is never stopped); OPE-026: the pill says the object and the operation of the oldest receipt to verify.
      let center = null;
      let queue = null;
      let alive = true;
      let reloading = null;
      let dirty = false;
      let taskPage = 0;
      let last = null;
      const withdrawing = new Set();
      const stopping = new Set();
      const queuedRows = () => queue?.reads?.slice(0, 32) ?? [];
      const queuedSection = (rows = queuedRows()) => queue ? `<h3 class="sh-sub">Lectures avant envoi</h3>
        ${rows.length ? `<ol class="sh-tasks" data-activity-key="queue-list">${rows.map((q) => `<li data-activity-key="queue:${esc(q.requestId)}"><span class="sh-task-l">${esc(q.label || q.operation)}<span class="faint"> · Lecture · En attente</span></span><span class="sh-task-t mono">${esc(elapsedText(q.waitedSeconds * 1000))}</span><span class="sh-task-p"><button class="btn xs ghost" type="button" data-queue-cancel="${esc(q.requestId)}"${withdrawing.has(q.requestId) ? ' disabled' : ''} aria-label="Retirer cette lecture avant envoi">${icon('x')}Retirer</button></span></li>`).join('')}</ol>`
          : `<p class="faint">${queuedRows().length ? 'Lectures en attente sur une autre page.' : 'Aucune lecture dans la file de cette fenêtre.'}</p>`}` : '<p class="faint">File d’attente non lue pour l’instant.</p>';
      const engineTasks = () => (center?.open ?? []).filter((t) => t.state !== 'completed').slice(0, 64);
      const taskRow = (t) => {
        const since = Date.parse(t.startedAt);
        const live = Number.isFinite(since) ? elapsedText(Math.max(0, now() - since)) : t.durationText;
        const counters = t.progress ? ` · ${t.progress.counters || `${t.progress.done}/${t.progress.total}`}` : '';
        const stop = t.canStop ? `<button class="btn xs ghost" type="button" data-engine-stop="${esc(t.id)}"${stopping.has(t.id) ? ' disabled' : ''} aria-label="Demander l’arrêt de ${esc(t.label)}">${icon('x')}Arrêter</button>`
          : (t.stopReason ? `<span class="faint" data-tip="${esc(t.stopReason)}">${icon('lock')}</span>` : '');
        return `<li data-activity-key="engine:${esc(t.id)}" data-tone="${esc(t.tone)}"><span class="sh-task-l" data-tip="${esc([t.detail || t.label, t.access].filter(Boolean).join(' · '))}">${esc(t.label)}<span class="faint">${NBSP}· ${esc(t.kindLabel)} · ${esc(t.stateLabel)}${esc(counters)}</span></span><span class="sh-task-t mono">${esc(live)}</span><span class="sh-task-p">${stop}</span></li>`;
      };
      const update = (html) => {
        const template = document.createElement('template');
        template.innerHTML = html;
        const scroll = body.scrollTop;
        const focus = body.contains(document.activeElement) ? document.activeElement : null;
        const selection = window.getSelection();
        const selected = selection && body.contains(selection.anchorNode) && body.contains(selection.focusNode)
          ? [selection.anchorNode, selection.anchorOffset, selection.focusNode, selection.focusOffset] : null;
        patchActivity(body, template.content);
        if (focus && body.contains(focus) && document.activeElement !== focus) focus.focus({ preventScroll: true });
        if (selected && body.contains(selected[0]) && body.contains(selected[2])) {
          const size = (node) => node.nodeType === Node.TEXT_NODE ? node.length : node.childNodes.length;
          selection.setBaseAndExtent(selected[0], Math.min(selected[1], size(selected[0])), selected[2], Math.min(selected[3], size(selected[2])));
        }
        body.scrollTop = scroll;
      };
      const paint = (a) => {
        if (!alive) return;
        if (!a) {
          update(`<div class="sh-empty-mini">${icon('activity')}<p><strong>Activité indisponible</strong> dans cet aperçu.</p></div>${queuedSection()}`);
          return;
        }
        const r = a.receipts;
        // Short labels of one line each: the three tiles keep the same height.
        const tile = (label, value, tone, sub, tip) => `<div class="sh-tile" data-tone="${tone}"${tip ? ` data-tip="${esc(tip)}"` : ''}><span class="sh-tile-v">${esc(value)}</span><span class="sh-tile-l">${esc(label)}</span><span class="sh-tile-s">${esc(sub ?? '')}</span></div>`;
        const rows = [
          ...queuedRows().map((row) => ({ kind: 'queue', row })),
          ...engineTasks().map((row) => ({ kind: 'engine', row })),
          ...runningTasks().slice(0, 64).map((row) => ({ kind: 'interface', row })),
        ];
        const pages = Math.max(1, Math.ceil(rows.length / 64));
        taskPage = Math.min(taskPage, pages - 1);
        const shown = rows.slice(taskPage * 64, (taskPage + 1) * 64);
        const tasks = shown.filter((r) => r.kind === 'interface').map((r) => r.row);
        const engines = shown.filter((r) => r.kind === 'engine').map((r) => r.row);
        const queued = shown.filter((r) => r.kind === 'queue').map((r) => r.row);
        const blocked = blockedTime();
        update(`<div class="sh-activity">
          <div class="sh-tiles">
            ${tile('En cours', a.tasks.running, a.tasks.running ? 'info' : 'off', a.tasks.running > 1 ? 'lectures' : 'lecture', 'Lectures en cours dans le moteur')}
            ${tile('En attente', queue ? `${queue.waiting}/${queue.limit}` : '—', queue?.waiting ? 'info' : 'off', queue ? 'avant envoi' : 'non lue', 'File bornée de cette fenêtre, sans worker encore lancé')}
            ${tile('À vérifier', r.available ? r.pending : '—', !r.available ? 'warn' : r.pending ? 'warn' : 'ok', r.available ? `${r.total} reçu${r.total > 1 ? 's' : ''}` : 'illisibles', 'Reçus d’écriture qui attendent leur relecture')}
          </div>
          ${a.tasks.running ? '<div class="sh-progress" role="progressbar" aria-label="Lectures en cours"><span></span></div>' : ''}
          <p class="sh-activity-detail">${esc(a.detail)}</p>
          ${queuedSection(queued)}
          ${engines.length ? `<h3 class="sh-sub" data-activity-key="engine-title">Tâches du moteur</h3><ol class="sh-tasks" data-activity-key="engine-list">${engines.map(taskRow).join('')}</ol>` : ''}
          ${tasks.length ? `<h3 class="sh-sub" data-activity-key="interface-title">Tâches de l’interface</h3><ol class="sh-tasks" data-activity-key="interface-list">${tasks.map((t) => `<li data-activity-key="ui:${esc(t.id)}"><span class="sh-task-l">${t.stopping ? 'Arrêt demandé · ' : ''}${esc(t.label)}</span><span class="sh-task-p mono">${t.progress === null ? '' : `${Math.round(t.progress * 100)} %`}</span><span class="sh-task-t mono">${esc(elapsedText(now() - t.started))}</span></li>`).join('')}</ol>${tasks.some((t) => t.cancellable && !t.stopping) ? `<button class="btn sm subtle" type="button" data-task-stop>${icon('x')}Demander l’arrêt de la première tâche</button>` : ''}` : ''}
          ${pages > 1 ? `<div class="sh-pop-foot" data-activity-key="pagination" aria-label="Pages des tâches">
            <button class="btn xs subtle" type="button" data-task-page="-1"${taskPage === 0 ? ' disabled' : ''}>Précédentes</button>
            <span class="faint">${taskPage + 1}/${pages} · ${rows.length} tâches</span>
            <button class="btn xs subtle" type="button" data-task-page="1"${taskPage === pages - 1 ? ' disabled' : ''}>Suivantes</button>
          </div>` : ''}
          <h3 class="sh-sub">Dernières opérations</h3>
          ${a.journal.length ? `<ol class="sh-journal">${a.journal.slice(0, 8).map((l) => `<li data-tone="${esc(l.tone)}"><span class="dot" aria-hidden="true"></span><span class="sh-journal-label">${esc(l.label)}</span><time datetime="${esc(l.at)}">${esc(formatTime(l.at) ?? '')}</time></li>`).join('')}</ol>` : `<div class="sh-empty-mini">${icon('activity')}<p><strong>Aucune opération</strong> dans cette session.</p></div>`}
          ${blocked.count ? `<p class="faint sh-activity-blocked">${blocked.count} panneau${blocked.count > 1 ? 'x' : ''} modal${blocked.count > 1 ? 'aux' : ''} cette session, interface bloquée ${Math.round(blocked.ms / 1000)} s au total.</p>` : ''}
          <div class="sh-pop-foot" data-activity-key="footer">
            <button class="btn sm subtle" type="button" data-go="journal">${icon('activity')}Journal</button>
            <button class="btn sm subtle" type="button" data-go="verifier"${r.pending ? (center?.pill?.oldest ? ` data-tip="${esc(`Plus ancien${NBSP}: ${center.pill.oldest.label} · ${center.pill.oldest.target}`)}"` : '') : ' aria-disabled="true" data-reason="Aucun reçu à vérifier."'}>${icon('shield')}Vérifier les reçus</button>
            <button class="btn sm primary" type="button" data-go="operations">${icon('activity')}Ouvrir Opérations</button>
          </div>
        </div>`);
      };
      const reload = () => {
        if (!alive || !visible()) return Promise.resolve();
        if (reloading) { dirty = true; return reloading; }
        // These three operations read local session state only. Await every response even on failure,
        // so a slow local reader cannot leave orphan requests behind the next tick.
        reloading = Promise.allSettled([refresh(), call('operations.center'), call('operations.queue.read')])
          .then((results) => {
            if (!alive) return;
            const [a, c, q] = results.map((r) => r.status === 'fulfilled' ? r.value : null);
            center = c; queue = q; last = a;
            if (visible()) paint(a);
            if (results.some((r) => r.status === 'rejected')) throw new Error('Activité locale momentanément illisible.');
          })
          .finally(() => {
            reloading = null;
            if (dirty && alive) { dirty = false; reload().catch(() => {}); }
          });
        return reloading;
      };
      body.addEventListener('click', (e) => {
        if (!alive) return;
        const page = e.target instanceof Element ? e.target.closest('[data-task-page]') : null;
        if (page) { taskPage = Math.max(0, taskPage + Number(page.dataset.taskPage)); paint(last); return; }
        const queued = e.target instanceof Element ? e.target.closest('[data-queue-cancel]') : null;
        if (queued) {
          const requestId = queued.dataset.queueCancel;
          if (withdrawing.has(requestId)) return;
          withdrawing.add(requestId); queued.disabled = true;
          call('operations.queue.cancel', { requestId }).then((r) => {
            if (alive) announce(r?.message ?? 'Retrait non confirmé.');
          }).catch(() => { if (alive) announce('Retrait non confirmé ; la lecture peut déjà avoir été admise.'); })
            .finally(() => { withdrawing.delete(requestId); reload().catch(() => {}); });
          return;
        }
        if (e.target instanceof Element && e.target.closest('[data-task-stop]')) { stopFirstTask(); reload().catch(() => {}); return; }
        const engineStop = e.target instanceof Element ? e.target.closest('[data-engine-stop]') : null;
        if (engineStop) {
          const id = engineStop.dataset.engineStop;
          if (stopping.has(id)) return;
          stopping.add(id); engineStop.disabled = true;
          call('operations.task.stop', { id }).then((r) => { if (alive) announce(r?.text ?? 'Arrêt non confirmé.'); })
            .catch(() => { if (alive) announce('Arrêt impossible pour cette tâche.'); })
            .finally(() => { stopping.delete(id); reload().catch(() => {}); });
          return;
        }
        const b = e.target instanceof Element ? e.target.closest('[data-go]') : null;
        if (!b || b.getAttribute('aria-disabled') === 'true') return;
        ctl.close();
        if (b.dataset.go === 'journal') { journal(); return; }
        if (b.dataset.go === 'verifier') go('operations', { filtre: 'verifier' }); else go('operations', { onglet: engineTasks().length ? 'taches' : 'recus' });
      });
      const unsubscribe = events('bridge.queue.changed', (event) => { if (!activityInspection(event?.operation)) reload().catch(() => {}); });
      const stopPulse = clock.every('shell.activity-panel', 1000, reload);
      reload().catch(() => {});
      return () => { alive = false; dirty = false; stopPulse(); unsubscribe(); };
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
      // The identifier is in the monospaced font; the display name under it keeps the font of the text.
      const row = (label, value, sub = '', mono = false) => `<div class="sh-kv-row"><dt>${esc(label)}</dt><dd>${value ? `<span${mono ? ' class="mono"' : ''}>${esc(value)}</span>` : '<span class="faint">—</span>'}${sub ? `<span class="sh-kv-sub">${esc(sub)}</span>` : ''}</dd></div>`;
      const sim = simulation();
      const cache = s.cache;
      body.innerHTML = `<div class="sh-session">
        <div class="sh-session-state" data-tone="${status.tone}"><span class="dot pulse" aria-hidden="true"></span><span>${esc(status.text)}</span></div>
        <dl class="sh-kv">
          ${row('Mode', app?.modeLabel ?? (simulation() ? 'Simulation' : 'Annuaire'), app?.modeDetail ?? '')}
          ${row('Domaine', s.domain?.dnsName ?? '', s.domain?.netbiosName ? `NetBIOS ${s.domain.netbiosName}` : '')}
          ${row('Contrôleur interrogé', s.controller?.dnsName ?? '', s.controller?.site ? `Site ${s.controller.site}` : '')}
          ${row('Compte', s.account?.login ?? '', s.account?.displayName ?? '', true)}
          ${row('Authentification', s.authentication?.label ?? '')}
          ${row('Droits estimés du compte', s.rights?.label ?? '', s.rights?.estimated ? `Déduits des groupes, non vérifiés par l’annuaire${s.rights.detail ? ` · ${s.rights.detail}` : ''}` : s.rights?.detail ?? '')}
          ${row('Écritures de la session', s.readOnly ? 'Lecture seule par défaut' : (sim ? 'Essai sur l’annuaire fictif' : s.connection?.state === 'connected' ? 'Sur confirmation, droits à vérifier' : 'Indisponibles sans connexion'), s.readOnly ? 'Lecture seule au repos ; toute opération autorisée exige son plan, sa confirmation et son jeton.' : sim ? `Surcouche en mémoire, indépendante des droits du compte : rien n’atteint un annuaire réel.` : 'Chaque écriture passe par un plan, une confirmation, un reçu et une relecture.')}
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
