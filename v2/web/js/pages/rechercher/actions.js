// Rechercher · actions on the rows: context menu of Domenia 1 (open, assistance, recheck, associated object, parent OU,
// copies for a ticket), actions of a multiple selection, surveys of the list (three graduated readings, exact targets and
// numbered confirmation, progress, stop, outcome pills that filter), the single recheck, the grouped network diagnostic,
// the comparison of two to eight objects and the unlock of an account through the write circuit.
// Domenia 1 RCH-002, RCH-062, RCH-076, RCH-078 to RCH-099, RCH-125 to RCH-131.
import { glyph } from '../../kit/glyphs.js';
import { openMenu } from '../../kit/menu.js';
import { openDialog } from '../../kit/dialog.js';
import { openDrawer } from '../../kit/drawer.js';
import { pill } from '../../kit/status.js';
import { writeClipboard } from '../../kit/util.js';
import { onEvent } from '../../bridge.js';
import { runWrite } from '../../write-flow.js';
import { toast, announce, errorText } from '../../ui.js';
import { esc, int, count, quote, COLON, NBSP, KINDS, ticketText, selectionText, parentDn, dateText } from './text.js';

const MODES = [
  { id: 'ping', label: 'Qui répond ?', icon: 'wifi', detail: 'Un ping par poste, échos envoyés en parallèle. Aucune lecture de session.' },
  { id: 'console', label: 'Qui est connecté ?', icon: 'users', detail: 'Ping puis utilisateur connecté à la console (CIM), quatre postes à la fois.' },
  { id: 'analyse', label: 'Matériel et widgets', icon: 'chip', detail: 'Ping, utilisateur connecté, relevé WMI léger et requêtes des widgets des tableaux de bord.' },
  { id: 'complete', label: 'Relevé complet', icon: 'layers', detail: 'Relevé léger plus correctifs, démarrage, services, TPM, BIOS et numéro de série ; jamais Win32_Product ni les processus.' },
  { id: 'unaddressed', label: 'Postes sans adresse', icon: 'hash', detail: 'Seulement les postes sans adresse connue, laissés après les autres dans un relevé normal.' },
];

/**
 * @param {any} ctx
 * @param {any} S  page state: results, preview, side, readOnly(), browse(dn), search(text, opts), recent(row), lastMode
 */
export function createActions(ctx, S) {
  let run = null; // survey in progress: { runId, total, stop }

  const single = (rows, row) => (rows.length <= 1 ? (row ?? rows[0] ?? null) : null);
  const pcsOf = (rows) => rows.filter((r) => r.kind === 'computer' && !r.flags?.disabled);
  const comparable = (rows) => rows.length >= 2 && rows.length <= 8 && new Set(rows.map((r) => r.kind)).size === 1 && ['computer', 'user'].includes(rows[0].kind);

  function copy(text, what) {
    writeClipboard(text).then((ok) => toast(ok ? `${what} copié.` : `Copie impossible${COLON}le presse-papiers est indisponible.`, { tone: ok ? 'ok' : 'warn', life: 2600 }));
  }

  function copyTicket(rows) {
    if (!rows.length) return;
    // One readable line per object: no GUID, no DN, secrets masked before the clipboard (Domenia 1 SP-05).
    copy(ticketText(rows), rows.length > 1 ? `Texte pour un ticket (${count(rows.length, 'ligne', 'lignes')})` : 'Texte pour un ticket');
  }

  // ---------- Context menu and selection bar ----------

  function contextMenu({ rows, row }) {
    const list = rows.length ? rows : row ? [row] : [];
    const one = single(list, row);
    const pcs = pcsOf(list);
    const isPc = one?.kind === 'computer';
    const linkable = one && (one.kind === 'user' || isPc);
    const many = 'Une seule ligne à la fois.';
    const items = [
      { heading: one ? one.name : selectionText(list.length, list.filter((r) => r.kind === 'computer').length) },
      { label: one ? `Ouvrir la fiche de ${one.name}` : 'Ouvrir la fiche', icon: 'object', kbd: 'Entrée', disabled: !one, reason: many, run: () => S.open(one) },
      { label: 'Assistance poste', icon: 'lifebuoy', disabled: !isPc, reason: one ? 'Réservé aux postes.' : many, run: () => S.go('assistance', one) },
      { label: 'Ouvrir dans Poste', icon: 'monitor', disabled: !isPc, reason: one ? 'Réservé aux postes.' : many, run: () => S.go('poste', one) },
      { label: 'Utilisateurs et postes', icon: 'link', disabled: !linkable, reason: one ? 'Réservé aux utilisateurs et aux postes.' : many, run: () => S.go('relations', one) },
      { label: 'Revérifier ce poste (un ping)', icon: 'wifi', kind: 'network', disabled: !isPc || one.flags.disabled, reason: !one ? many : !isPc ? 'Réservé aux postes.' : 'Poste désactivé.', run: () => recheck(one) },
      { label: isPc ? 'Rechercher l’utilisateur associé' : 'Rechercher le poste associé', icon: 'search', disabled: !one?.association, reason: one ? 'Aucune association mémorisée.' : many, run: () => S.searchAssociated(one) },
      { label: 'Ouvrir l’OU parente', icon: 'ou', disabled: !one, reason: many, run: () => S.browse(parentDn(one.dn)) },
      '-',
      { label: list.length > 1 ? `Copier pour un ticket (${int(list.length)})` : 'Copier pour un ticket', icon: 'copy', disabled: !list.length, reason: 'Aucune ligne.', run: () => copyTicket(list) },
      { label: 'Copier une valeur', icon: 'copy', disabled: !one, reason: many, items: one ? [
        { label: 'Le nom', disabled: !one.name, run: () => copy(one.name, 'Nom') },
        { label: 'Le compte', disabled: !one.login, reason: 'Valeur vide.', run: () => copy(one.login, 'Compte') },
        { label: 'L’UPN ou le DNS', disabled: !one.upn, reason: 'Valeur vide.', run: () => copy(one.upn, 'UPN ou nom DNS') },
        { label: 'Le chemin (DN)', run: () => copy(one.dn, 'Chemin LDAP') },
        { label: 'Le GUID', run: () => copy(one.id, 'GUID') },
      ] : [] },
      '-',
      { label: 'Vérifier', icon: 'wifi', kind: 'network', disabled: !pcs.length, reason: 'Aucun poste actif.', items: MODES.slice(0, 3).map((m) => ({ label: `${m.label}`, icon: m.icon, run: () => survey(m.id, list, 'selection') })) },
      { label: 'Comparer', icon: 'split', disabled: !comparable(list), reason: 'Deux à huit objets d’un même type (postes ou comptes).', run: () => compare(list) },
      { label: 'Diagnostic réseau', icon: 'activity', kind: 'network', disabled: !pcs.length, reason: 'Aucun poste actif.', run: () => netdiag(list) },
      { label: 'Épingler l’OU parente', icon: 'star', disabled: !one, reason: many, run: () => S.pin(parentDn(one.dn)) },
    ];
    if (one?.kind === 'user' && (one.flags.locked || one.flags.lockToCheck)) {
      items.push('-', { label: 'Déverrouiller le compte…', icon: 'lock', kind: 'write', danger: true, disabled: S.readOnly(), reason: 'Lecture seule.', run: () => unlock(one) });
    }
    return items;
  }

  function selectionActions(rows) {
    const pcs = pcsOf(rows);
    return [
      { label: `Pinger ${pcs.length ? int(pcs.length) : ''}`.trim(), icon: 'wifi', disabled: !pcs.length, reason: 'Aucun poste actif dans la sélection.', run: (sel) => survey('ping', sel, 'selection') },
      { label: `Qui est connecté${NBSP}?`, icon: 'users', disabled: !pcs.length, reason: 'Aucun poste actif dans la sélection.', run: (sel) => survey('console', sel, 'selection') },
      { label: 'Comparer', icon: 'split', disabled: !comparable(rows), reason: 'Deux à huit objets d’un même type.', run: (sel) => compare(sel) },
      { label: 'Diagnostic réseau', icon: 'activity', disabled: !pcs.length, reason: 'Aucun poste actif dans la sélection.', run: (sel) => netdiag(sel) },
      { label: 'Copier pour un ticket', icon: 'copy', run: (sel) => copyTicket(sel) },
      { label: 'Exporter', icon: 'csv', run: () => S.results.grid.exportCsv('selected') },
    ];
  }

  /** « Vérifier la liste ▾ »: the last reading chosen in the session, or the choice of the three graduated readings. */
  function surveyMenu(anchor) {
    const r = S.results.result();
    const rows = S.results.grid.getVisibleRows();
    const pcs = pcsOf(rows);
    openMenu(anchor, [
      { heading: pcs.length ? `${count(pcs.length, 'poste actif affiché', 'postes actifs affichés')}` : 'Aucun poste actif affiché' },
      ...MODES.map((m) => ({ label: m.label, icon: m.icon, hint: m.id === S.lastMode ? 'dernier choix' : '', disabled: !pcs.length || (r?.view && !r.view.surveyAllowed), reason: r?.view?.reason || 'Aucun poste actif dans la liste.', run: () => survey(m.id, null, 'list') })),
      '-',
      { label: 'Ce que lit chaque relevé', icon: 'info', run: () => openDialog({ title: 'Relevés de la liste', icon: 'wifi', size: 'md',
        body: `<ul data-page="rechercher" class="rch-modes">${MODES.map((m) => `<li>${glyph(m.icon)}<span><b>${esc(m.label)}</b><small>${esc(m.detail)}</small></span></li>`).join('')}</ul><p data-page="rechercher" class="rch-dlg-note">Une confirmation chiffrée précède toute lecture ; jamais tout le domaine, 500 postes au plus ; arrêt possible à tout moment.</p>` }) },
    ], { label: 'Vérifier la liste', placement: 'bottom-start' });
  }

  // ---------- Surveys ----------

  function surveyContext(scope, rows) {
    const r = S.results.result();
    const f = S.results.filters();
    const visible = S.results.grid.getVisibleRows();
    return {
      scope: scope === 'list' ? 'results' : 'selection',
      global: r?.scope.mode === 'global',
      hasTerm: !!r?.text,
      wholeDomain: !!(r?.scope.wholeDomain || (r?.view && !r.view.surveyAllowed)),
      hasFilter: !!(f.quick || f.facets.length || f.presence),
      coversList: scope !== 'list' && rows.length === visible.length,
      scopeLabel: r ? (r.scope.mode === 'global' ? r.scope.chip : r.scope.path.split(`${NBSP}› `).at(-1)) : null,
      subtree: r?.scope.subtree ?? true,
      listLimit: r?.limitReached ? r.limit : 0,
    };
  }

  async function survey(mode, rows, scope) {
    if (run) { toast('Un relevé de la liste est déjà en cours : arrêtez-le ou attendez sa fin.', { tone: 'warn' }); return; }
    S.lastMode = mode;
    let list = rows;
    if (!list) {
      const visible = S.results.grid.getVisibleRows();
      if (S.results.scopeMode === 'selected') {
        const ids = new Set(visible.map((v) => v.id));
        list = S.results.grid.getSelection().filter((x) => ids.has(x.id));
        scope = 'selection';
      } else list = visible;
    }
    if (!list.length) { toast('Aucune ligne à relever.', { tone: 'warn' }); return; }
    const context = surveyContext(scope, list);
    let plan;
    try {
      plan = await ctx.call('search.survey.plan', { mode, ids: list.map((x) => x.id).slice(0, 5000), context });
    } catch (err) {
      toast(`Relevé impossible${COLON}${errorText(err)}`, { tone: 'alert' });
      return;
    }
    const ok = await confirmSurvey(plan);
    if (!ok) return;
    await execute(mode, plan, context);
  }

  function confirmSurvey(plan) {
    const allowed = plan.admission.allowed;
    const targets = plan.targets;
    const body = `<div data-page="rechercher" class="rch-survey-plan">
      ${allowed ? '' : `<p class="rch-refusal">${glyph('alert')}${esc(plan.admission.reason)}</p>`}
      <ol class="rch-survey-lines">${plan.lines.map((l, n) => `<li data-j="${n}"><span class="rch-line-n">${n + 1}</span>${esc(l)}</li>`).join('')}</ol>
      <div class="rch-survey-cols">
        <section><h4>${glyph('monitor')}Postes lus <span class="k-badge info">${int(targets.length)}</span></h4>
          <ul class="rch-targets">${targets.slice(0, 500).map((t) => `<li><span>${esc(t.name)}</span>${t.address ? `<small class="mono">${esc(t.address)}</small>` : '<small>sans adresse connue</small>'}</li>`).join('') || '<li class="none">Aucun poste.</li>'}</ul></section>
        <section><h4>${glyph('eyeOff')}Lignes écartées <span class="k-badge off">${int(plan.excluded.length)}</span></h4>
          <ul class="rch-targets excluded">${plan.excluded.map((x) => `<li><span>${esc(x.name)}</span><small>${esc(x.reason)}</small></li>`).join('') || '<li class="none">Aucune ligne écartée.</li>'}</ul></section>
      </div>
      ${allowed && plan.typedCountRequired ? `<label class="rch-typed">Au-delà de 100 postes, saisissez le nombre de postes pour confirmer${COLON}<input class="input mono" inputmode="numeric" autocomplete="off" aria-label="Nombre de postes à relever"></label>` : ''}
      <p class="rch-dlg-note">${glyph('info')}Lecture seule : rien n’est modifié sur les postes. Une absence de réponse au ping ne prouve pas qu’un poste est éteint.</p>
    </div>`;
    const dlg = openDialog({
      title: plan.title, subtitle: `${count(plan.targets.length, 'poste', 'postes')} · ${plan.estimate}`, icon: 'wifi', size: 'lg', body,
      actions: allowed
        ? [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'go', label: plan.confirmText, icon: 'wifi', primary: true, disabled: plan.typedCountRequired }]
        : [{ id: 'cancel', label: 'Fermer', safe: true, primary: true }],
    });
    dlg.body.querySelectorAll('[data-j]').forEach((x) => x.style.setProperty('--j', x.dataset.j));
    const typed = dlg.body.querySelector('.rch-typed input');
    typed?.addEventListener('input', () => dlg.setDisabled('go', typed.value.replace(/\s/g, '') !== String(targets.length)));
    return dlg.result.then((id) => id === 'go');
  }

  async function execute(mode, plan, context) {
    const ids = plan.targets.map((t) => t.id);
    const total = ids.length;
    const label = MODES.find((m) => m.id === mode)?.label ?? 'Relevé';
    S.results.updateRows(S.results.rows().filter((x) => ids.includes(x.id)), { pending: true });
    run = { runId: null, total };
    let stopAsked = false;
    const notice = (p, done = false) => S.results.setNotice('survey', {
      tone: done ? (p.errors ? 'warn' : 'ok') : 'info', icon: done ? 'check' : 'wifi',
      html: `<div class="rch-progress"><div class="rch-progress-top"><b>${esc(label)}</b><span class="num">${esc(p.text)}</span></div>
        <div class="rch-progress-bar${done ? ' done' : ''}" role="progressbar" aria-valuemin="0" aria-valuemax="${total}" aria-valuenow="${p.done}" aria-label="Relevé de la liste"><span class="rch-progress-fill"></span></div></div>`,
      actions: done
        ? [{ id: 'online', label: `${int(p.online)} en ligne` }, { id: 'noReply', label: `${int(p.noReply)} sans réponse` }, { id: 'error', label: `${count(p.errors, 'erreur', 'erreurs')}` }]
        : [{ id: 'stop', label: stopAsked ? 'Arrêt demandé…' : `Arrêter (${int(p.done)}/${int(total)})`, icon: 'pause' }],
      dismiss: done,
      run: (act) => {
        if (act === 'stop' && run?.runId && !stopAsked) {
          stopAsked = true;
          ctx.call('search.survey.stop', { runId: run.runId }).then((r) => announce(r.message)).catch((err) => console.error(err));
          notice(p);
        } else if (['online', 'noReply', 'error'].includes(act)) S.filterPresence(act);
      },
    });
    const paintBar = (p) => {
      const bar = document.querySelector('.rch-notice[data-id="survey"] .rch-progress-fill');
      bar?.style.setProperty('--p', String(total ? p.done / total : 1));
    };
    notice({ done: 0, text: `0/${int(total)}`, online: 0, noReply: 0, errors: 0 });
    const off = onEvent('search.survey.run:progress', (p) => {
      if (!run) return;
      if (!run.runId) run.runId = p.runId;
      if (p.runId !== run.runId) return;
      const changed = p.batch.map((b) => {
        const row = S.results.rows().find((x) => x.id === b.id);
        return row ? { ...row, presence: b.presence, console: b.console ?? row.console, _pending: false } : null;
      }).filter(Boolean);
      if (changed.length) S.results.updateRows(changed);
      notice(p);
      paintBar(p);
    });
    try {
      const result = await ctx.call('search.survey.run', { mode, ids, context });
      S.results.updateRows(result.rows);
      S.preview.update(result.rows.find((x) => x.id === S.preview.current()?.id));
      const p = { done: result.done, text: result.text, online: result.online, noReply: result.noReply, errors: result.errors };
      notice(p, true);
      paintBar(p);
      toast(`${label}${COLON}${result.text}`, { tone: result.stopped || result.errors ? 'warn' : 'ok', life: 6000 });
    } catch (err) {
      S.results.setNotice('survey', { tone: 'alert', icon: 'alert', html: `Relevé non lancé${COLON}${esc(errorText(err))}`, dismiss: true });
      S.results.updateRows(S.results.rows().filter((x) => ids.includes(x.id)).map((x) => ({ ...x, _pending: false })));
    } finally {
      off();
      run = null;
    }
  }

  async function recheck(row) {
    S.results.updateRows([row], { pending: true });
    try {
      const fresh = await ctx.call('search.recheck', { id: row.id });
      S.results.updateRows([fresh]);
      S.preview.update(fresh);
      toast(`${fresh.name}${COLON}${fresh.presence?.label ?? 'relevé fait'}${fresh.console?.state === 'seen' ? ` · ${fresh.console.user}` : ''}`, { tone: fresh.presence?.state === 'online' ? 'ok' : 'warn' });
    } catch (err) {
      S.results.updateRows([{ ...row, _pending: false }]);
      toast(`Revérification impossible${COLON}${errorText(err)}`, { tone: 'alert' });
    }
  }

  // ---------- Network diagnostic ----------

  async function netdiag(rows) {
    const pcs = pcsOf(rows);
    const others = rows.length - pcs.length;
    const head = pcs.slice(0, 50);
    const ok = await openDialog({
      title: 'Diagnostic réseau groupé', subtitle: `${count(head.length, 'poste', 'postes')} · un écho puis les ports 445, 135, 5985 et 5986`, icon: 'activity', size: 'md',
      body: `<div data-page="rechercher" class="rch-survey-plan"><ul class="rch-targets">${head.map((r) => `<li><span>${esc(r.name)}</span>${r.address?.ip ? `<small class="mono">${esc(r.address.ip)}</small>` : '<small>sans adresse relevée</small>'}</li>`).join('')}</ul>
        ${others || pcs.length > 50 ? `<p class="rch-dlg-note">${glyph('eyeOff')}${others ? `${count(others, 'ligne écartée', 'lignes écartées')} (pas un poste actif)` : ''}${pcs.length > 50 ? ` · ${count(pcs.length - 50, 'poste', 'postes')} au-delà de 50, non testés` : ''}.</p>` : ''}
        <p class="rch-dlg-note">${glyph('info')}Poste après poste, aucun compte envoyé, rien modifié ; arrêt au délai sans résultat partiel.</p></div>`,
      actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'go', label: `Diagnostiquer ${count(head.length, 'poste', 'postes')}`, icon: 'activity', primary: true, disabled: !head.length }],
    }).result;
    if (ok !== 'go') return;
    const drawer = openDrawer({ title: 'Diagnostic réseau', subtitle: 'Lecture en cours…', icon: 'activity', width: 820, key: 'rechercher.diag', body: `<div data-page="rechercher" class="rch-diag" aria-busy="true">${'<span class="skeleton sk sk-line w85"></span>'.repeat(6)}</div>` });
    try {
      const res = await ctx.call('search.netdiag', { ids: head.map((r) => r.id) });
      const portHead = ['445 SMB', '135 RPC', '5985 WinRM', '5986 WinRM HTTPS'];
      drawer.setTitle('Diagnostic réseau', res.summary);
      drawer.body.innerHTML = `<div data-page="rechercher" class="rch-diag">
        <div class="rch-diag-top"><p>${esc(res.summary)}</p><button class="btn sm" type="button" data-copy>${glyph('copy')}Copier le rapport</button></div>
        <div class="rch-diag-wrap"><table class="table rch-diag-table"><thead><tr><th>Poste</th><th>Adresse</th><th>Ping</th>${portHead.map((h) => `<th>${esc(h)}</th>`).join('')}<th>Synthèse</th></tr></thead>
        <tbody>${res.lines.map((l, n) => `<tr data-j="${Math.min(n, 20)}"><td><b>${esc(l.name)}</b></td><td class="mono">${esc(l.address ?? '—')}</td><td>${pill(l.ping.tone, l.ping.label, { size: 'sm', tip: l.ping.detail })}</td>`
          + `${l.ports.map((p) => `<td>${pill(p.tone, p.label, { size: 'sm', dot: true })}</td>`).join('')}<td class="rch-diag-sum ${esc(l.tone)}">${esc(l.summary)}</td></tr>`).join('')}</tbody></table></div>
        ${res.excluded.length ? `<p class="rch-dlg-note">${glyph('eyeOff')}Écartés${COLON}${esc(res.excluded.map((x) => `${x.name} (${x.reason})`).join(', '))}</p>` : ''}
        <p class="rch-dlg-note">${glyph('info')}Relevé du ${esc(dateText(res.at))}. Un port fermé ou filtré ne prouve pas que le service manque ; une absence de réponse ne prouve pas que le poste est éteint.</p>
      </div>`;
      drawer.body.querySelectorAll('[data-j]').forEach((x) => x.style.setProperty('--j', x.dataset.j));
      drawer.body.querySelector('[data-copy]')?.addEventListener('click', () => copy(res.report, 'Rapport du diagnostic'));
    } catch (err) {
      drawer.setTitle('Diagnostic réseau', 'Non lancé');
      drawer.body.innerHTML = `<p data-page="rechercher" class="rch-prev-err">${glyph('alert')}${esc(errorText(err))}</p>`;
    }
  }

  // ---------- Comparison ----------

  async function compare(rows) {
    if (!comparable(rows)) { toast('Comparez de deux à huit objets d’un même type (postes ou comptes).', { tone: 'warn' }); return; }
    const drawer = openDrawer({ title: 'Comparaison', subtitle: `${count(rows.length, 'objet', 'objets')} · base locale`, icon: 'split', width: Math.min(1100, 360 + rows.length * 190), maxWidth: 1400, key: 'rechercher.comparer',
      body: `<div data-page="rechercher" class="rch-cmp" aria-busy="true">${'<span class="skeleton sk sk-line w85"></span>'.repeat(8)}</div>` });
    try {
      const res = await ctx.call('search.compare', { ids: rows.map((r) => r.id) });
      const head = res.objects.map((o) => `<th scope="col"><span class="rch-cmp-obj">${glyph(KINDS[o.kind]?.icon ?? 'object')}${esc(o.name)}</span></th>`).join('');
      let family = '';
      const body = res.lines.map((l, n) => {
        const fam = l.family !== family ? `<tr class="rch-cmp-fam"><th colspan="${res.objects.length + 2}">${esc(l.family)}</th></tr>` : '';
        family = l.family;
        return `${fam}<tr class="rch-cmp-row ${esc(l.difference)}" data-j="${Math.min(n, 24)}"><th scope="row">${esc(l.property)}</th>`
          + `<td class="rch-cmp-verdict">${l.comparison ? pill({ different: 'warn', unknown: 'off', dateOnly: 'info', same: 'ok' }[l.difference] ?? 'off', l.comparison, { size: 'sm', dot: true }) : ''}</td>`
          + `${l.values.map((v) => `<td class="${v.known ? '' : 'unknown'}"><span class="rch-cmp-v${l.property === 'Identité AD' ? ' mono id' : ''}">${esc(v.text)}</span>${new Set(l.values.map((x) => x.date)).size > 1 ? `<small>${esc(v.date)}</small>` : ''}</td>`).join('')}</tr>`;
      }).join('');
      drawer.setTitle('Comparaison', res.summary);
      drawer.body.innerHTML = `<div data-page="rechercher" class="rch-cmp">
        <div class="rch-cmp-top"><label class="rch-cmp-diff"><input class="switch" type="checkbox" role="switch"><span>Différences seulement</span></label>
          <span class="rch-cmp-tally">${pill('warn', `${int(res.different)} différentes`, { size: 'sm' })}${pill('ok', `${int(res.same)} identiques`, { size: 'sm' })}${pill('off', `${int(res.unknown)} incomplètes`, { size: 'sm' })}</span></div>
        <div class="rch-cmp-wrap"><table class="table rch-cmp-table"><thead><tr><th scope="col">Propriété</th><th scope="col">Comparaison</th>${head}</tr></thead><tbody>${body}</tbody></table></div>
        <p class="rch-dlg-note">${glyph('info')}Chaque valeur garde sa date (affichée quand elle diffère d’un objet à l’autre) ; une valeur non lue n’est jamais « identique ». Aucune relecture.</p>
      </div>`;
      drawer.body.querySelectorAll('[data-j]').forEach((x) => x.style.setProperty('--j', x.dataset.j));
      const diff = drawer.body.querySelector('.rch-cmp-diff input');
      diff.addEventListener('change', () => drawer.body.querySelector('.rch-cmp').classList.toggle('only-diff', diff.checked));
    } catch (err) {
      drawer.setTitle('Comparaison', 'Impossible');
      drawer.body.innerHTML = `<p data-page="rechercher" class="rch-prev-err">${glyph('alert')}${esc(errorText(err))}</p>`;
    }
  }

  // ---------- Unlock through the write circuit ----------

  async function unlock(row) {
    // Plan read by the engine, confirmation, receipt written before the change, read again afterwards (docs/WRITES.md).
    const receipt = await runWrite(ctx, { plan: 'accounts.unlock.plan', args: { dn: row.dn }, subtitle: row.name });
    if (receipt) {
      try {
        const reread = await ctx.call('search.revalidate', { ids: [row.id] });
        S.results.updateRows(reread.rows);
        S.preview.update(reread.rows[0]);
      } catch (err) {
        console.error(err);
      }
    }
  }

  return { contextMenu, selectionActions, surveyMenu, survey, recheck, netdiag, compare, copyTicket, unlock, busy: () => !!run };
}

export { quote };
