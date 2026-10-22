// Rechercher · actions on the rows: context menu of Domenia 1 grouped by subject (open, network, copies), actions of a
// multiple selection, surveys of the list (three graduated readings planned by the engine from the list itself, exact
// targets and numbered confirmation with profile, budgets and collection window, progress, stop, detailed state, outcome
// pills that filter, resume plan), the single recheck and the check on click, the grouped network diagnostic, the
// comparison of two to eight objects and the unlock of an account through the write circuit.
// Domenia 1 RCH-002, RCH-062, RCH-076, RCH-078 to RCH-099, RCH-117, RCH-125 to RCH-131.
import { glyph } from '../../kit/glyphs.js';
import { openMenu } from '../../kit/menu.js';
import { openDialog } from '../../kit/dialog.js';
import { openDrawer } from '../../kit/drawer.js';
import { pill } from '../../kit/status.js';
import { writeClipboard } from '../../kit/util.js';
import { onEvent } from '../../bridge.js';
import { runWrite } from '../../write-flow.js';
import { toast, announce, errorText } from '../../ui.js';
import { esc, int, count, quote, COLON, NBSP, KINDS, ticketText, maskSecrets, selectionText, parentDn, dateText, ticketOuPath, associatedAccount } from './text.js';

export const MODES = [
  { id: 'ping', label: 'Qui répond ?', icon: 'wifi', detail: 'Un ping par poste, échos envoyés en parallèle. Aucune lecture de session.' },
  { id: 'console', label: 'Qui est connecté ?', icon: 'users', detail: 'Ping puis utilisateur connecté à la console (CIM), quatre postes à la fois.' },
  { id: 'analyse', label: 'Matériel et widgets', icon: 'chip', detail: 'Ping, utilisateur connecté, relevé WMI léger et requêtes des widgets des tableaux de bord.' },
  { id: 'complete', label: 'Relevé complet', icon: 'layers', detail: 'Relevé léger plus correctifs, démarrage, services, TPM, BIOS et numéro de série ; jamais Win32_Product ni les processus.' },
  { id: 'unaddressed', label: 'Postes sans adresse', icon: 'hash', detail: 'Seulement les postes sans adresse connue, laissés après les autres dans un relevé normal.' },
];
export const modeLabel = (id) => MODES.find((m) => m.id === id)?.label ?? 'Relevé';

/**
 * @param {any} ctx
 * @param {any} S  page state: results, preview, readOnly(), open(row), go(route, row), browse(dn), searchAssociated(row), pin(dn),
 *   filterPresence(state), lastMode, onRunChange(), onSuspended(reason), resume, setResume(resume)
 */
export function createActions(ctx, S) {
  let run = null; // survey in progress: { runId, total, done, mode, stopAsked }
  let clickGen = 0;

  const single = (rows, row) => (rows.length <= 1 ? (row ?? rows[0] ?? null) : null);
  const pcsOf = (rows) => rows.filter((r) => r.kind === 'computer' && !r.flags?.disabled);
  const comparable = (rows) => rows.length >= 2 && rows.length <= 8 && new Set(rows.map((r) => r.kind)).size === 1 && ['computer', 'user'].includes(rows[0].kind);
  const listId = () => S.results.result()?.listId ?? null;
  /** A list listed on the whole domain is never surveyed, not even a selection of it (RCH-117): the reason, or ''. */
  const blocked = () => { const v = S.results.result()?.view; return v && !v.surveyAllowed ? v.reason : ''; };
  // During a survey, the readings of the menus, the selection bar and the preview are greyed with their reason: only the main
  // button « Arrêter (n/m) » of the list stops it (a choice in a menu never stops it silently).
  const RUNNING = `Un relevé est déjà en cours${NBSP}: «${NBSP}Arrêter${NBSP}» de la liste l’arrête.`;
  const busyReason = () => (run ? RUNNING : blocked());
  // Only the selected rows that are shown are processed (RCH-097, RCH-126): a selected row hidden by a filter is excluded from
  // the surveys, the diagnostic, the copies and the exports, and the operator is told how many.
  function visibleOf(rows) {
    const shown = new Set(S.results.grid.getVisibleRows().map((v) => v.id));
    const kept = (rows ?? []).filter((r) => shown.has(r.id));
    const hidden = (rows?.length ?? 0) - kept.length;
    if (hidden > 0) toast(`${count(hidden, 'ligne sélectionnée masquée', 'lignes sélectionnées masquées')} par un filtre${COLON}exclue${hidden > 1 ? 's' : ''}.`, { tone: 'info', life: 4200 });
    return kept;
  }

  function copy(text, what) {
    writeClipboard(text).then((ok) => toast(ok ? `${what} copié.` : `Copie impossible${COLON}le presse-papiers est indisponible.`, { tone: ok ? 'ok' : 'warn', life: 2600 }));
  }

  function copyTicket(given) {
    const rows = visibleOf(given);
    if (!rows.length) return;
    // One readable line per object: no GUID, no DN, secrets masked before the clipboard (Domenia 1 SP-05).
    copy(ticketText(rows), rows.length > 1 ? `Texte pour un ticket (${count(rows.length, 'ligne', 'lignes')})` : 'Texte pour un ticket');
  }

  /** Summary of the stored fiche, one property per line, secrets masked (Domenia 1 « résumé de fiche »). */
  function summaryText(row) {
    const lines = [
      [KINDS[row.kind]?.label ?? 'Objet', row.name],
      ['Nom affiché', row.display],
      ['Compte', row.kind === 'computer' ? associatedAccount(row) : row.login],
      [row.kind === 'computer' ? 'Nom DNS' : 'UPN', row.upn],
      ['Courriel', row.mail],
      ['État', row.state?.label],
      ['OU', ticketOuPath(row.dn)],
      ['Système', row.os],
      ['Présence', row.presence ? `${row.presence.label}${row.presence.checkedAt ? ` (${dateText(row.presence.checkedAt)})` : ''}` : ''],
      ['Utilisateur console', row.console?.state === 'seen' ? row.console.user : ''],
      ['Association', row.association ? `${row.association.label} (${row.association.qualification}, ${row.association.source})` : ''],
      ['Dernière connexion', row.lastLogon ? `${dateText(row.lastLogon, false)} (à 14 jours près)` : ''],
      ['Description', row.description],
    ].filter(([, v]) => v);
    return maskSecrets(lines.map(([k, v]) => `${k}${COLON}${String(v).replace(/[\r\n\t]+/g, ' ')}`).join('\r\n'));
  }

  function allValues(row) {
    const pairs = [['Nom', row.name], ['Type', row.kindLabel], ['Nom affiché', row.display], ['Compte', row.login], ['UPN / DNS', row.upn], ['Courriel', row.mail],
      ['État', row.state?.label], ['Système', row.os], ['Version', row.osVersion], ['Description', row.description], ['Emplacement', row.container],
      ['Dernière connexion', row.lastLogon ? dateText(row.lastLogon) : ''], ['Modifié', row.changed ? dateText(row.changed) : ''], ['Créé', row.created ? dateText(row.created) : ''],
      ['Chemin (DN)', row.dn], ['GUID', row.id]].filter(([, v]) => v);
    return maskSecrets(pairs.map(([k, v]) => `${k}\t${String(v).replace(/[\r\n\t]+/g, ' ')}`).join('\r\n'));
  }

  // ---------- Context menu and selection bar ----------

  /** Row menu grouped by subject (RCH-076): open, open in, network, copies; the write comes last, marked. */
  function contextMenu({ rows, row }) {
    const list = rows.length ? rows : row ? [row] : [];
    const one = single(list, row);
    const pcs = pcsOf(list);
    const isPc = one?.kind === 'computer';
    const linkable = one && (one.kind === 'user' || isPc);
    const many = 'Une seule ligne à la fois.';
    const stop = blocked();
    const items = [
      { heading: one ? one.name : selectionText(list.length, list.filter((r) => r.kind === 'computer').length) },
      { label: one ? 'Ouvrir la fiche' : 'Ouvrir la fiche (une ligne)', icon: 'object', kbd: 'Entrée', disabled: !one, reason: many, run: () => S.open(one) },
      { label: 'Ouvrir dans', icon: 'external', disabled: !one, reason: many, items: one ? [
        { label: 'Assistance poste (Intervenir)', icon: 'lifebuoy', disabled: !isPc, reason: 'Réservé aux postes.', run: () => S.go('assistance', one) },
        { label: 'Poste', icon: 'monitor', disabled: !isPc, reason: 'Réservé aux postes.', run: () => S.go('poste', one) },
        { label: 'Utilisateurs et postes', icon: 'link', disabled: !linkable, reason: 'Réservé aux utilisateurs et aux postes.', run: () => S.go('relations', one) },
        '-',
        { label: 'Afficher l’OU parente', icon: 'ou', kind: 'network', hint: 'remplace la liste', run: () => S.browse(parentDn(one.dn)) },
      ] : [] },
      { label: isPc ? 'Rechercher l’utilisateur associé' : 'Rechercher le poste associé', icon: 'search', disabled: !one?.association, reason: one ? 'Aucune association mémorisée.' : many, run: () => S.searchAssociated(one) },
      { label: 'Réseau', icon: 'wifi', kind: 'network', disabled: !pcs.length || !!busyReason(), reason: busyReason() || 'Aucun poste actif.', items: [
        { label: 'Revérifier ce poste (ping et utilisateur)', icon: 'refresh', disabled: !isPc || one.flags.disabled, reason: !one ? many : !isPc ? 'Réservé aux postes.' : 'Poste désactivé.', run: () => recheck(one) },
        '-',
        ...MODES.slice(0, 3).map((m) => ({ label: `${m.label}${list.length > 1 ? ` (${int(pcs.length)})` : ''}`, icon: m.icon, run: () => survey(m.id, list, 'selection') })),
        '-',
        { label: 'Diagnostic réseau', icon: 'activity', run: () => netdiag(list) },
      ] },
      { label: list.length > 1 ? `Comparer (${int(list.length)})` : 'Comparer', icon: 'split', disabled: !comparable(list), reason: 'Deux à huit objets d’un même type (postes ou comptes).', run: () => compare(list) },
      '-',
      { label: 'Copier', icon: 'copy', disabled: !list.length, reason: 'Aucune ligne.', items: [
        { label: list.length > 1 ? `Pour un ticket (${int(list.length)} lignes)` : 'Pour un ticket', icon: 'copy', run: () => copyTicket(list) },
        { label: 'Résumé de fiche', icon: 'file', disabled: !one, reason: many, run: () => copy(summaryText(one), 'Résumé de fiche') },
        '-',
        { label: 'Le nom', disabled: !one, reason: many, run: () => copy(one.name, 'Nom') },
        { label: 'Le compte', disabled: !one || !(one.kind === 'computer' ? associatedAccount(one) : one.login), reason: one ? 'Valeur vide.' : many, run: () => copy(one.kind === 'computer' ? associatedAccount(one) : one.login, 'Compte') },
        { label: 'L’UPN ou le nom DNS', disabled: !one?.upn, reason: one ? 'Valeur vide.' : many, run: () => copy(one.upn, 'UPN ou nom DNS') },
        { label: 'Le chemin (DN)', disabled: !one, reason: many, run: () => copy(one.dn, 'Chemin LDAP') },
        { label: 'Le GUID', disabled: !one, reason: many, run: () => copy(one.id, 'GUID') },
        { label: 'Toutes les valeurs', disabled: !one, reason: many, run: () => copy(allValues(one), 'Valeurs de la ligne') },
        '-',
        ...(S.actionMode?.('export') === 'hidden' ? [] : [{ label: S.results.scopeMode === 'selected' ? 'Exporter la sélection en CSV…' : 'Exporter la liste affichée en CSV…', icon: 'csv', disabled: S.actionMode?.('export') === 'disabled', reason: 'Fonction désactivée dans la configuration de l’application.', run: () => S.exportList(S.results.scopeMode) }]),
      ] },
      { label: 'Épingler l’OU parente', icon: 'star', disabled: !one || !/^OU=/i.test(parentDn(one.dn) ?? ''), reason: one ? `Le parent est un conteneur (CN=…)${NBSP}: seules les OU s’épinglent.` : many, run: () => S.pin(parentDn(one.dn)) },
    ];
    if (one?.kind === 'user' && (one.flags.locked || one.flags.lockToCheck)) {
      // A write, marked as such (pencil) and last; not destructive: no danger tone (kit § 2.6).
      items.push('-', { label: 'Déverrouiller le compte…', icon: 'lock', kind: 'write', hint: 'écriture', disabled: S.readOnly(), reason: 'Lecture seule.', run: () => unlock(one) });
    }
    return items;
  }

  function selectionActions(rows) {
    const pcs = pcsOf(rows);
    const stop = busyReason();
    return [
      { label: `Pinger ${pcs.length ? int(pcs.length) : ''}`.trim(), icon: 'wifi', disabled: !pcs.length || !!stop, reason: stop || 'Aucun poste actif dans la sélection.', run: (sel) => survey('ping', sel, 'selection') },
      { label: `Qui est connecté${NBSP}?`, icon: 'users', disabled: !pcs.length || !!stop, reason: stop || 'Aucun poste actif dans la sélection.', run: (sel) => survey('console', sel, 'selection') },
      { label: 'Comparer', icon: 'split', disabled: !comparable(rows), reason: 'Deux à huit objets d’un même type.', run: (sel) => compare(sel) },
      { label: 'Diagnostic réseau', icon: 'activity', disabled: !pcs.length || !!stop, reason: stop || 'Aucun poste actif dans la sélection.', run: (sel) => netdiag(sel) },
      ...(S.actionMode?.('export') === 'hidden' ? [] : [{ label: 'Exporter…', icon: 'csv', disabled: S.actionMode?.('export') === 'disabled', reason: 'Fonction désactivée dans la configuration de l’application.', run: () => S.exportList('selected') }]),
      { label: 'Copier pour un ticket', icon: 'copy', run: (sel) => copyTicket(sel) },
    ];
  }

  /** Choices of « Vérifier la liste ▾ »: the graduated readings, the last one of the session marked. */
  function surveyItems() {
    const r = S.results.result();
    const rows = S.results.grid.getVisibleRows();
    const pcs = pcsOf(rows);
    const stop = blocked();
    return [
      { heading: pcs.length ? `${count(pcs.length, 'poste actif affiché', 'postes actifs affichés')}` : 'Aucun poste actif affiché' },
      ...MODES.map((m) => ({ label: m.label, icon: m.icon, hint: m.id === S.lastMode && S.chosen ? 'dernier choix' : '', disabled: !pcs.length || !!stop, reason: stop || 'Aucun poste actif dans la liste.', run: () => { S.chosen = true; survey(m.id, null, 'list'); } })),
      '-',
      { label: 'Relire les mesures enregistrées', icon: 'database', disabled: !r, reason: 'Aucune liste.', run: () => S.rereadMeasures() },
      { label: 'Ce que lit chaque relevé', icon: 'info', run: () => openDialog({ title: 'Relevés de la liste', icon: 'wifi', size: 'md',
        body: `<ul data-page="rechercher" class="rch-modes">${MODES.map((m) => `<li>${glyph(m.icon)}<span><b>${esc(m.label)}</b><small>${esc(m.detail)}</small></span></li>`).join('')}</ul><p data-page="rechercher" class="rch-dlg-note">${glyph('info')}Une confirmation chiffrée précède toute lecture ; jamais tout le domaine, 500 postes au plus ; arrêt possible à tout moment.</p>` }) },
    ];
  }

  // ---------- Surveys ----------

  async function survey(mode, rows, scope, { resume = false } = {}) {
    if (run) { toast(RUNNING, { tone: 'info', life: 3600 }); return; }
    const id = listId();
    if (!id) { toast('Aucune liste à relever.', { tone: 'warn' }); return; }
    S.lastMode = mode;
    let list = rows ? visibleOf(rows) : rows;
    if (!list && !resume) {
      const visible = S.results.grid.getVisibleRows();
      if (S.results.scopeMode === 'selected') {
        const ids = new Set(visible.map((v) => v.id));
        list = S.results.grid.getSelection().filter((x) => ids.has(x.id));
        scope = 'selection';
      } else list = visible;
    }
    if (!resume && !list.length) { toast('Aucune ligne à relever.', { tone: 'warn' }); return; }
    let plan;
    try {
      plan = await ctx.call('search.survey.plan', resume ? { mode, listId: id, resume: true } : { mode, listId: id, ids: list.map((x) => x.id).slice(0, 5000), scope: scope === 'list' ? 'results' : 'selection' });
    } catch (err) {
      toast(`Relevé impossible${COLON}${errorText(err)}`, { tone: 'alert' });
      return;
    }
    const typed = await confirmSurvey(plan);
    if (typed === null) return;
    await execute(plan, typed);
  }

  /** Confirmation of a plan: three lines, the details of the collection, exact targets, numbered button; null when cancelled. */
  function confirmSurvey(plan) {
    const allowed = plan.admission.allowed;
    const targets = plan.targets;
    const body = `<div data-page="rechercher" class="rch-survey-plan">
      ${allowed ? '' : `<p class="rch-refusal">${glyph('alert')}${esc(plan.admission.reason)}</p>`}
      ${plan.outsideWindow ? `<p class="rch-window">${glyph('clock')}${esc(plan.details.find((d) => d.startsWith('Hors fenêtre')) ?? '')}</p>` : ''}
      <ol class="rch-survey-lines">${plan.lines.map((l, n) => `<li data-j="${n}"><span class="rch-line-n">${n + 1}</span>${esc(l)}</li>`).join('')}</ol>
      <details class="rch-survey-details" open><summary>${glyph('sliders')}Profil, budgets et fenêtre de collecte</summary>
        <ul>${plan.details.filter((d) => !d.startsWith('Hors fenêtre')).map((d) => `<li>${esc(d)}</li>`).join('')}</ul></details>
      <div class="rch-survey-cols">
        <section><h4>${glyph('monitor')}Postes lus <span class="k-badge info">${int(targets.length)}</span></h4>
          <ul class="rch-targets">${targets.slice(0, 500).map((t) => `<li><span>${esc(t.name)}</span>${t.address ? `<small class="mono">${esc(t.address)}</small>` : '<small>sans adresse connue</small>'}</li>`).join('') || '<li class="none">Aucun poste.</li>'}</ul></section>
        <section><h4>${glyph('eyeOff')}Lignes écartées <span class="k-badge off">${int(plan.excluded.length)}</span></h4>
          <ul class="rch-targets excluded">${plan.excluded.map((x) => `<li><span>${esc(x.name)}</span><small>${esc(x.reason)}</small></li>`).join('') || '<li class="none">Aucune ligne écartée.</li>'}</ul></section>
      </div>
      ${allowed && plan.typedCountRequired ? `<label class="rch-typed">Au-delà de 100 postes, saisissez le nombre de postes pour confirmer${COLON}<input class="input mono" inputmode="numeric" autocomplete="off" aria-label="Nombre de postes à relever"></label>` : ''}
      <p class="rch-dlg-note">${glyph('info')}Lecture seule : rien n’est modifié sur les postes. Une absence de réponse au ping ne prouve pas qu’un poste est éteint. Ce plan vaut dix minutes, pour un seul lancement.</p>
    </div>`;
    const dlg = openDialog({
      title: plan.title, subtitle: `${count(plan.targets.length, 'poste', 'postes')} · ${plan.estimate}`, icon: 'wifi', size: 'lg', body,
      actions: allowed
        ? [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'go', label: plan.confirmText, icon: 'wifi', primary: true, disabled: plan.typedCountRequired }]
        : [{ id: 'cancel', label: 'Fermer', safe: true, primary: true }],
    });
    dlg.body.querySelectorAll('[data-j]').forEach((x) => x.style.setProperty('--j', x.dataset.j));
    const input = dlg.body.querySelector('.rch-typed input');
    input?.addEventListener('input', () => dlg.setDisabled('go', input.value.replace(/\s/g, '') !== String(targets.length)));
    // The typed count goes to the engine, which checks it again before any read.
    return dlg.result.then((choice) => (choice === 'go' ? (input ? Number.parseInt(input.value.replace(/\s/g, ''), 10) : null) ?? -1 : null))
      .then((v) => (v === -1 ? undefined : v));
  }

  function statusHtml(status) {
    return status?.lines?.length ? `<ul class="rch-status">${status.lines.map((l) => `<li>${esc(l)}</li>`).join('')}</ul>` : '';
  }

  async function execute(plan, typedCount) {
    const ids = plan.targets.map((t) => t.id);
    const total = ids.length;
    const label = plan.modeLabel;
    S.results.updateRows(S.results.rows().filter((x) => ids.includes(x.id)), { pending: true });
    run = { runId: null, total, done: 0, mode: plan.mode, stopAsked: false };
    S.onRunChange?.();
    let last = { done: 0, text: `0/${int(total)}`, status: null };
    const notice = (p, done = false, result = null) => S.results.setNotice('survey', {
      tone: done ? (p.errors || result?.stopped ? 'warn' : 'ok') : 'info', icon: done ? (result?.stopped ? 'pause' : 'check') : 'wifi',
      html: `<div class="rch-progress"><div class="rch-progress-top"><b>${esc(label)}</b><span class="num">${esc(p.text)}</span></div>
        <div class="rch-progress-bar${done ? ' done' : ''}" role="progressbar" aria-valuemin="0" aria-valuemax="${total}" aria-valuenow="${p.done}" aria-label="Relevé de la liste"><span class="rch-progress-fill"></span></div></div>`,
      more: statusHtml(p.status),
      actions: done
        ? [{ id: 'online', label: `${int(p.online)} en ligne`, pressed: S.results.state.presence === 'online', tip: 'Filtre la liste ; un second clic retire le filtre' },
          { id: 'noReply', label: `${int(p.noReply)} sans réponse`, pressed: S.results.state.presence === 'noReply', tip: 'Filtre la liste ; un second clic retire le filtre' },
          { id: 'error', label: count(p.errors, 'erreur', 'erreurs'), pressed: S.results.state.presence === 'error', tip: 'Filtre la liste ; un second clic retire le filtre' }]
        : [{ id: 'stop', label: run?.stopAsked ? 'Arrêt demandé…' : `Arrêter (${int(p.done)}/${int(total)})`, icon: 'pause' }],
      dismiss: done,
      run: (act) => {
        if (act === 'stop') stopRun();
        else if (['online', 'noReply', 'error'].includes(act)) { S.filterPresence(act); notice(p, true, result); }
      },
    });
    const paintBar = (p) => {
      const bar = document.querySelector('.rch-notice[data-id="survey"] .rch-progress-fill');
      bar?.style.setProperty('--p', String(total ? p.done / total : 1));
    };
    // While the survey reads, the notice is updated in place: no entrance replayed at every batch, the bar glides, the focus
    // stays on « Arrêter » and the « Détails » the operator opened stay open (detailed state, RCH-099).
    const patch = (p) => {
      const el = S.results.noticeEl('survey');
      if (!el || !el.querySelector('[data-act="stop"]')) { notice(p); return; }
      const num = el.querySelector('.rch-progress-top .num');
      if (num) num.textContent = p.text;
      el.querySelector('.rch-progress-bar')?.setAttribute('aria-valuenow', String(p.done));
      const stopBtn = el.querySelector('[data-act="stop"]');
      const label = [...stopBtn.childNodes].reverse().find((n) => n.nodeType === Node.TEXT_NODE);
      const text = run?.stopAsked ? 'Arrêt demandé…' : `Arrêter (${int(p.done)}/${int(total)})`;
      if (label && label.textContent !== text) label.textContent = text;
      S.results.setNoticeMore('survey', statusHtml(p.status));
    };
    notice({ done: 0, text: `0/${int(total)}`, online: 0, noReply: 0, errors: 0, status: null });
    const off = onEvent('search.survey.run:progress', (p) => {
      if (!run) return;
      if (!run.runId) run.runId = p.runId;
      if (p.runId !== run.runId) return;
      run.done = p.done;
      const changed = p.batch.map((b) => {
        const row = S.results.rows().find((x) => x.id === b.id);
        return row ? { ...row, presence: b.presence, console: b.console ?? row.console, _pending: false } : null;
      }).filter(Boolean);
      if (changed.length) S.results.updateRows(changed);
      last = p;
      patch(p);
      paintBar(p);
      S.onRunChange?.();
    });
    try {
      const result = await ctx.call('search.survey.run', { planId: plan.planId, typedCount: typedCount ?? null });
      S.results.updateRows(result.rows);
      S.preview.update(result.rows.find((x) => x.id === S.preview.current()?.id));
      const p = { done: result.done, text: result.text, online: result.online, noReply: result.noReply, errors: result.errors, status: result.status };
      notice(p, true, result);
      paintBar(p);
      S.setResume?.(result.resume ?? null);
      if (result.status?.suspended) S.onSuspended?.();
      toast(`${label}${COLON}${result.text}`, { tone: result.stopped || result.errors ? 'warn' : 'ok', life: 6000 });
    } catch (err) {
      S.results.setNotice('survey', { tone: 'alert', icon: 'alert', html: `Relevé non lancé${COLON}${esc(errorText(err))}`, more: statusHtml(last.status), dismiss: true });
      S.results.updateRows(S.results.rows().filter((x) => ids.includes(x.id)).map((x) => ({ ...x, _pending: false })));
    } finally {
      off();
      run = null;
      S.onRunChange?.();
    }
  }

  function stopRun() {
    if (!run) return;
    if (!run.runId || run.stopAsked) { announce('Arrêt déjà demandé : le lot en cours se termine.'); return; }
    run.stopAsked = true;
    ctx.call('search.survey.stop', { runId: run.runId }).then((r) => announce(r.message)).catch((err) => console.error(err));
    S.onRunChange?.();
  }

  /** One ping and the console user of one workstation (explicit), or the check on click (silent unless it fails). */
  async function recheck(row, { mode = 'console', onClick = false } = {}) {
    S.results.updateRows([row], { pending: true });
    try {
      const fresh = await ctx.call('search.recheck', { id: row.id, mode, listId: listId(), onClick });
      S.results.updateRows([fresh]);
      S.preview.update(fresh);
      if (!onClick) toast(`${fresh.name}${COLON}${fresh.presence?.label ?? 'relevé fait'}${fresh.console?.state === 'seen' ? ` · ${fresh.console.user}` : ''}`, { tone: fresh.presence?.state === 'online' ? 'ok' : 'warn' });
      else announce(`${fresh.name}${COLON}${fresh.presence?.label ?? 'relevé fait'}.`);
      if (fresh.console?.state === 'denied') S.onSuspended?.();
    } catch (err) {
      S.results.updateRows([{ ...row, _pending: false }]);
      if (err?.code === 'search.checksSuspended') { S.onSuspended?.(err.message); return; }
      toast(`Revérification impossible${COLON}${errorText(err)}`, { tone: 'alert' });
    }
  }

  /** « Vérifier au clic » (RCH-078): one intention 180 ms after the click, the newest click only. */
  function checkOnClick(row, withConsole) {
    const my = ++clickGen;
    setTimeout(() => {
      if (my !== clickGen || run) return;
      const sel = S.results.grid.getSelection();
      if (sel.length !== 1 || sel[0].id !== row.id || blocked()) return;
      recheck(row, { mode: withConsole ? 'console' : 'ping', onClick: true });
    }, 180);
  }

  // ---------- Network diagnostic ----------

  async function netdiag(given) {
    const stop = blocked();
    if (stop) { toast(stop, { tone: 'warn' }); return; }
    const rows = visibleOf(given);
    if (!rows.length) return;
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
      const res = await ctx.call('search.netdiag', { listId: listId(), ids: head.map((r) => r.id) });
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

  return {
    contextMenu, selectionActions, surveyItems, survey, stopRun, recheck, checkOnClick, netdiag, compare, copyTicket, unlock, blocked,
    busy: () => !!run, runState: () => (run ? { done: run.done, total: run.total, stopAsked: run.stopAsked, mode: run.mode } : null),
  };
}

export { quote };
