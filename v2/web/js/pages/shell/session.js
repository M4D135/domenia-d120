// Tabs « Raccourcis » (TRV-178 to TRV-180) and « Notifications » (TRV-172 to TRV-174) of the shell centre.
import { icon } from '../../icons.js';
import { esc, copyText, announce, formatTime, relTime } from '../../ui.js';
import { on, quietCall } from '../../shell/store.js';
import { shortcutsMarkup, bindShortcuts, shortcutListText } from '../../shell/shortcuts.js';
import { notes, markAllRead, clearNotes, supportText, exampleNote } from '../../shell/notify.js';
import { followRoute } from '../../shell/help.js';

const NBSP = ' ';
const TONE_ICONS = { ok: 'check', info: 'info', warn: 'alert', alert: 'alert' };
const TONE_WORDS = { ok: 'Terminé', info: 'Information', warn: 'Attention', alert: 'Erreur' };

export function renderShortcutsTab(panel) {
  panel.innerHTML = `<div class="sh-shortcuts-page card">
    <header class="card-head"><span class="card-icon">${icon('command')}</span><h3>Raccourcis clavier</h3>
      <span class="meta"><button class="btn sm subtle" type="button" data-copy-keys>${icon('copy')}Copier l’aide-mémoire</button></span></header>
    <p class="muted">Un raccourci tapé dans un champ de texte y garde son sens (Ctrl Z annule la frappe) ; aucun raccourci ne change le profil d’affichage. La palette (Ctrl K) liste aussi chaque commande avec son raccourci.</p>
    ${shortcutsMarkup()}
  </div>`;
  bindShortcuts(panel);
  panel.querySelector('[data-copy-keys]').addEventListener('click', () => copyText(shortcutListText()).then((ok) => announce(ok ? 'Aide-mémoire des raccourcis copié.' : 'Copie impossible.')));
}

export function renderNotificationsTab(panel) {
  let filter = 'all';
  panel.innerHTML = `<div class="sh-notes-page">
    <section class="card sh-notes-list">
      <header class="card-head"><span class="card-icon">${icon('bell')}</span><h3>Messages de la session</h3>
        <span class="meta"><button class="btn sm ghost" type="button" data-n-act="read">${icon('check')}Tout marquer lu</button><button class="btn sm ghost" type="button" data-n-act="clear">${icon('trash')}Effacer</button></span></header>
      <div class="sh-centre-filters" data-n-filters role="group" aria-label="Filtrer les messages"></div>
      <div class="sh-centre-list" data-n-list></div>
    </section>
    <aside class="sh-notes-side">
      <section class="card">
        <header class="card-head"><span class="card-icon">${icon('sparkles')}</span><h3>Essayer les bannières</h3></header>
        <p class="muted">Montre le comportement des messages : information fermée après 5${NBSP}s (pas sous le pointeur), avertissement et erreur gardés jusqu’à fermeture, même message regroupé (×N), code INC extrait, route « Aller à ».</p>
        <div class="sh-try">
          <button class="btn sm" type="button" data-try="info">${icon('info')}Information</button>
          <button class="btn sm" type="button" data-try="ok">${icon('check')}Terminé</button>
          <button class="btn sm" type="button" data-try="warn">${icon('alert')}Attention avec route</button>
          <button class="btn sm" type="button" data-try="alert">${icon('alert')}Erreur INC avec détail</button>
        </div>
      </section>
      <section class="card">
        <header class="card-head"><span class="card-icon">${icon('activity')}</span><h3>Journal des opérations</h3></header>
        <div data-n-journal aria-busy="true"><p class="sh-loading"><span class="k-spin"></span>Lecture du journal…</p></div>
      </section>
    </aside>
  </div>`;
  const list = panel.querySelector('[data-n-list]');
  const paint = () => {
    const all = notes();
    const counts = { all: all.length, alert: all.filter((n) => n.tone === 'alert').length, warn: all.filter((n) => n.tone === 'warn').length, info: all.filter((n) => n.tone === 'info' || n.tone === 'ok').length };
    panel.querySelector('[data-n-filters]').innerHTML = [['all', 'Tous'], ['alert', 'Erreurs'], ['warn', 'Attention'], ['info', 'Informations']]
      .map(([id, label]) => `<button class="k-facet" type="button" data-n-filter="${id}" aria-pressed="${filter === id}">${esc(label)}<span class="k-facet-n">${counts[id]}</span></button>`).join('');
    const shown = all.filter((n) => filter === 'all' || (filter === 'info' ? n.tone === 'info' || n.tone === 'ok' : n.tone === filter));
    list.innerHTML = shown.length ? shown.map((n) => `<article class="sh-centre-item${n.read ? '' : ' unread'}" data-tone="${n.tone}" data-id="${n.id}">
        <span class="sh-centre-icon">${icon(TONE_ICONS[n.tone] ?? 'info')}</span>
        <div class="sh-centre-main">
          <div class="sh-centre-meta"><span class="sh-centre-kind">${esc(TONE_WORDS[n.tone] ?? '')}</span>${n.code ? `<span class="mono">${esc(n.code)}</span>` : ''}${n.count > 1 ? `<span class="k-badge warn">×${n.count}</span>` : ''}<span>${esc(n.screen)}</span><time datetime="${new Date(n.at).toISOString()}">${esc(relTime(new Date(n.at).toISOString()) ?? '')}</time></div>
          <p class="sh-centre-text">${esc(n.headline)}</p>${n.body ? `<p class="sh-centre-body">${esc(n.body)}</p>` : ''}
          <div class="sh-centre-actions">${n.route ? `<button class="btn xs subtle" type="button" data-n-route>${icon('chevronRight')}Aller à ${esc(n.routeLabel)}</button>` : ''}${n.tone === 'warn' || n.tone === 'alert' ? `<button class="btn xs ghost" type="button" data-n-support>${icon('copy')}Copier pour le support</button>` : ''}${n.detail ? `<details class="sh-centre-detail"><summary>Détail</summary><pre>${esc(n.detail)}</pre></details>` : ''}</div>
        </div></article>`).join('')
      : `<div class="sh-empty-mini">${icon('bell')}<p><strong>Aucun message</strong> ${all.length ? 'pour ce filtre' : 'dans cette session'}.</p><p class="faint">Chaque bannière reste ici après sa fermeture, jusqu’à la fin de la session.</p></div>`;
  };
  panel.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const f = t?.closest('[data-n-filter]');
    if (f) { filter = f.dataset.nFilter; paint(); return; }
    const act = t?.closest('[data-n-act]')?.dataset.nAct;
    if (act === 'read') { markAllRead(); paint(); return; }
    if (act === 'clear') { clearNotes(); paint(); announce('Messages de la session effacés.'); return; }
    const tryTone = t?.closest('[data-try]')?.dataset.try;
    if (tryTone) exampleNote(tryTone);
    const item = t?.closest('.sh-centre-item');
    const n = item ? notes().find((x) => String(x.id) === item.dataset.id) : null;
    if (n && t.closest('[data-n-route]')) followRoute(n.route);
    if (n && t.closest('[data-n-support]')) copyText(supportText(n)).then((ok) => announce(ok ? 'Copié pour le support.' : 'Copie impossible.'));
  });
  paint();
  quietCall('shell.activity').then((a) => {
    const box = panel.querySelector('[data-n-journal]');
    box.removeAttribute('aria-busy');
    const lines = a?.journal ?? [];
    box.innerHTML = lines.length
      ? `<ol class="sh-journal">${lines.slice(0, 14).map((l) => `<li data-tone="${esc(l.tone)}"><span class="dot" aria-hidden="true"></span><span class="sh-journal-label">${esc(l.label)}</span><time datetime="${esc(l.at)}">${esc(formatTime(l.at) ?? '')}</time></li>`).join('')}</ol>`
      : `<div class="sh-empty-mini">${icon('activity')}<p><strong>Aucune opération</strong> dans cette session.</p></div>`;
  }).catch(() => {
    const box = panel.querySelector('[data-n-journal]');
    box.removeAttribute('aria-busy');
    box.innerHTML = '<p class="faint">Journal indisponible dans cet aperçu.</p>';
  });
  return on('notes', paint);
}
