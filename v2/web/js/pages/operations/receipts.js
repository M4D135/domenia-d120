// Tab « Reçus d’écriture » (Domenia 1 OPE-009, OPE-010, OPE-011, OPE-022 to OPE-026): receipts of the write circuit, uncertain
// ones first, filtered by state, in a grid with the detail of the selected receipt beside it (what the re-read proves, the
// re-read itself, the manual review, the compensation, the trail of the receipt), and the rules of the circuit below. A re-read is
// a read: the write is never sent again. Nothing here is ever replayed.
import { esc, errorText, toast, announce, applyVars, reveal } from '../../ui.js';
import {
  createGrid, createSplit, createFilterBar, openDialog, confirmDialog, pill, glyph, writeClipboard, NBSP,
} from '../../kit/index.js';
import {
  silentCall, fullDate, toneMark, emptyState, errorBox, sectionHead, cardHead, count, int, maskSecrets, looksSecret, paintVars,
} from './common.js';
import { sampleReceipts, sampleDetail } from './demo.js';

const STATES = [
  { value: 'aVerifier', label: 'À vérifier', tone: 'warn' },
  { value: 'verifiee', label: 'Vérifiée', tone: 'ok' },
  { value: 'ecart', label: 'Écart', tone: 'alert' },
  { value: 'revue', label: 'Revue manuelle', tone: 'info' },
  { value: 'nonAppliquee', label: 'Non appliquée', tone: 'alert' },
  { value: 'dejaFaite', label: 'Déjà faite', tone: 'off' },
  { value: 'nonVerifiee', label: 'Non vérifiée', tone: 'warn' },
];
const KIND_ICONS = { user: 'user', computer: 'monitor', group: 'group', ou: 'ou' };
const REVIEW_MIN = 12;
const REVIEW_MAX = 240;

/** State of a receipt for the grid and its filters. */
function stateOf(r) {
  if (r.pending) return 'aVerifier';
  if (r.verification === 'reviewed') return 'revue';
  if (r.result === 'notApplied') return 'nonAppliquee';
  if (r.result === 'noChange') return 'dejaFaite';
  if (r.verification === 'mismatch') return 'ecart';
  if (r.verification === 'verified') return 'verifiee';
  return 'nonVerifiee';
}

const COLUMNS = [
  { id: 'state', label: 'État', type: 'enum', width: 150, required: true, get: stateOf, options: STATES, tip: 'Les reçus à vérifier viennent toujours en premier.' },
  { id: 'label', label: 'Opération', width: 222, required: true },
  {
    id: 'target', label: 'Objet', width: 178, get: (r) => r.target?.name ?? '',
    html: (v, r) => `<span class="op-cell-target"><span class="op-cell-ico" aria-hidden="true">${glyph(KIND_ICONS[r.target?.kind] ?? 'object')}</span><span data-tip="${esc(r.target?.dn ?? '')}">${esc(v)}</span></span>`,
  },
  { id: 'at', label: 'Dernière version', type: 'date', width: 128 },
  { id: 'operator', label: 'Compte', width: 160, mono: true, hidden: true },
  { id: 'controller', label: 'Contrôleur', width: 170, mono: true, hidden: true },
  { id: 'resultLabel', label: 'Résultat de l’envoi', width: 190, hidden: true },
  { id: 'verificationLabel', label: 'Relecture', width: 180, hidden: true },
  {
    id: 'mode', label: 'Mode', type: 'enum', width: 120, hidden: true, get: (r) => (r.simulated ? 'simulation' : 'annuaire'),
    options: [{ value: 'simulation', label: 'Simulé', tone: 'info' }, { value: 'annuaire', label: 'Annuaire réel', tone: 'warn' }],
  },
  { id: 'dn', label: 'Chemin (DN)', width: 320, mono: true, hidden: true, get: (r) => r.target?.dn ?? '' },
  { id: 'id', label: 'Reçu', width: 280, mono: true, hidden: true },
];

const FACETS = [
  { id: 'aVerifier', label: 'À vérifier', tone: 'warn' },
  { id: 'verifiee', label: 'Vérifiées', tone: 'ok' },
  { id: 'ecart', label: 'Écarts', tone: 'alert' },
  { id: 'revue', label: 'Revues', tone: 'info' },
  { id: 'nonAppliquee', label: 'Non appliquées', tone: 'alert' },
];

/**
 * @param {HTMLElement} host
 * @param {{ ctx: any, demo: boolean, onCounts: (c: {pending: number, total: number, unreadable: number, readable: boolean}) => void, params: any }} env
 */
export function createReceipts(host, env) {
  const { ctx, demo } = env;
  let alive = true;
  let all = [];
  let summary = '';
  let pressed = new Set(env.params?.filtre === 'a-verifier' ? ['aVerifier'] : []);
  let selectedId = env.params?.recu ?? null;
  let detailToken = 0;
  let current = null; // detail of the selected receipt

  host.innerHTML = `<div class="op-receipts">
    <div class="op-rc-summary" aria-live="polite"><span class="op-rc-summary-ico">${glyph('shield')}</span><span class="op-rc-summary-text">Lecture des reçus…</span></div>
    <div class="op-rc-filters"></div>
    <div class="op-rc-split"></div>
    ${sectionHead('Règles du circuit d’écriture', 'Preuves par relecture, compensations et séquences préparées')}
    <div class="op-rules" data-rules aria-busy="true"><div class="grid">${[1, 2, 3].map(() => '<section class="card span-4 op-rule-card"><span class="skeleton op-sk-line w70"></span><span class="skeleton op-sk-line w90"></span><span class="skeleton op-sk-line w55"></span></section>').join('')}</div></div>
  </div>`;
  const summaryText = host.querySelector('.op-rc-summary-text');
  const summaryBox = host.querySelector('.op-rc-summary');

  const listPane = document.createElement('div');
  listPane.className = 'op-rc-list';
  const detailPane = document.createElement('div');
  detailPane.className = 'op-rc-detail';
  detailPane.innerHTML = detailEmpty();
  const split = createSplit(host.querySelector('.op-rc-split'), { a: listPane, b: detailPane, key: 'operations.recus.detail', size: 470, min: 360, max: 760, label: 'Taille du détail du reçu' });

  const grid = createGrid(listPane, {
    key: 'operations.recus',
    label: 'Reçus d’écriture',
    rowId: (r) => r.id,
    selection: 'single',
    loading: true,
    height: 'fill',
    columns: COLUMNS,
    quickPlaceholder: 'Filtrer les reçus (objet, opération, compte…)',
    empty: { icon: 'shield', title: 'Aucun reçu d’écriture', text: 'Chaque écriture confirmée laisse ici un reçu, écrit avant l’envoi puis relu. Rien n’est jamais renvoyé automatiquement.' },
    onActiveChange: (row) => { if (row) select(row.id, false); },
    onActivate: (row) => select(row.id, true),
    contextMenu: ({ row }) => [
      { label: 'Afficher le détail', icon: 'eye', disabled: !row, run: () => select(row.id, true) },
      { label: 'Relire l’objet…', icon: 'refresh', disabled: !row || demo, reason: demo ? 'Exemple local : rien n’est relu.' : '', run: () => reread(row.id) },
      { label: 'Consigner une revue…', icon: 'edit', disabled: !row?.pending, reason: 'Seul un reçu à vérifier se revoit.', run: () => openReview(row.id) },
      '-',
      { label: 'Copier le détail', icon: 'copy', disabled: !row, run: () => copyDetail(row) },
      { label: 'Ouvrir la fiche de l’objet', icon: 'object', disabled: !row?.target?.dn, run: () => ctx.navigate('fiche', { dn: row.target.dn }) },
    ],
    onExport: (csv, info) => exportCsv(csv, info),
  });
  const refreshButton = document.createElement('button');
  refreshButton.type = 'button';
  refreshButton.className = 'btn sm subtle';
  refreshButton.innerHTML = `${glyph('refresh')}Actualiser les reçus`;
  refreshButton.addEventListener('click', () => load(false));
  grid.slot.append(refreshButton);

  const filters = createFilterBar(host.querySelector('.op-rc-filters'), {
    label: 'Filtres des reçus',
    facets: FACETS.map((f) => ({ ...f, count: 0, pressed: pressed.has(f.id) })),
    onToggle: (id, on) => { if (on) pressed.add(id); else pressed.delete(id); paint(); },
    onClear: () => { pressed = new Set(); paint(); },
  });

  // ---------------------------------------------------------------- data

  function fetchList(silent) {
    if (demo) return Promise.resolve(sampleReceipts());
    return silent ? silentCall('write.receipts.list') : ctx.call('write.receipts.list');
  }

  function load(silent = false) {
    if (!silent) grid.setLoading(true);
    return fetchList(silent).then((list) => {
      if (!alive) return;
      all = list.receipts ?? [];
      summary = list.summary ?? '';
      summaryText.textContent = demo ? `${summary} Exemple local${NBSP}: aucune donnée réelle.` : summary;
      summaryBox.dataset.tone = list.pending > 0 ? 'warn' : list.unreadable > 0 ? 'info' : 'ok';
      env.onCounts({ pending: list.pending ?? 0, total: list.total ?? all.length, unreadable: list.unreadable ?? 0, readable: true });
      paint();
      const chosen = selectedId ? all.find((r) => r.id === selectedId) : null;
      if (chosen) {
        // A new version of the open receipt (re-read or reviewed elsewhere) reopens its detail.
        if (!current || current.receipt.id !== selectedId || current.receipt.at !== chosen.at) openDetail(selectedId);
        grid.select([selectedId]);
      } else if (all.length && !silent) {
        // The first receipt (an uncertain one when there is one) opens by itself: the detail is never an empty column.
        selectedId = null;
        select(all[0].id, false);
        grid.select([all[0].id]);
      } else if (!all.length && (current || selectedId || !detailPane.dataset.empty)) {
        selectedId = null;
        current = null;
        detailPane.dataset.empty = 'true';
        detailPane.innerHTML = detailEmpty(true);
        paintVars(detailPane);
      }
    }).catch((err) => {
      console.error(err);
      if (!alive) return;
      summaryText.textContent = errorText(err, 'Reçus illisibles.');
      summaryBox.dataset.tone = 'alert';
      env.onCounts({ pending: 0, total: 0, unreadable: 0, readable: false });
      grid.setError(errorText(err, 'Reçus illisibles pour l’instant.'), { retry: () => load(false) });
    });
  }

  function paint() {
    const counts = Object.fromEntries(FACETS.map((f) => [f.id, all.filter((r) => stateOf(r) === f.id).length]));
    filters.setFacets(FACETS.map((f) => ({ ...f, count: counts[f.id], pressed: pressed.has(f.id) })));
    const rows = pressed.size ? all.filter((r) => pressed.has(stateOf(r))) : all;
    grid.setRows(rows, { keepSelection: true, keepScroll: true });
    filters.setSummary(pressed.size ? `→ ${count(rows.length, 'reçu affiché', 'reçus affichés')} sur ${int(all.length)}` : count(all.length, 'reçu conservé', 'reçus conservés'));
  }

  function select(id, focusDetail) {
    if (!id) return;
    if (selectedId === id) {
      if (focusDetail) detailPane.querySelector('.op-dt-title')?.focus({ preventScroll: true });
      return;
    }
    selectedId = id;
    openDetail(id, focusDetail);
  }

  function openDetail(id, focusDetail = false) {
    const my = ++detailToken;
    delete detailPane.dataset.empty;
    detailPane.setAttribute('aria-busy', 'true');
    detailPane.innerHTML = detailSkeleton();
    const sample = demo ? all.find((r) => r.id === id) : null;
    const read = demo ? Promise.resolve(sample ? sampleDetail(sample) : null) : ctx.call('operations.receipts.detail', { id });
    read.then((detail) => {
      if (!alive || my !== detailToken) return;
      detailPane.removeAttribute('aria-busy');
      if (!detail) { detailPane.innerHTML = detailEmpty(); return; }
      current = detail;
      detailPane.innerHTML = detailMarkup(detail, demo);
      applyVars(detailPane);
      bindDetail(detailPane);
      if (focusDetail) detailPane.querySelector('.op-dt-title')?.focus({ preventScroll: true });
    }).catch((err) => {
      console.error(err);
      if (!alive || my !== detailToken) return;
      detailPane.removeAttribute('aria-busy');
      detailPane.innerHTML = `<div class="op-dt">${errorBox(errorText(err, 'Reçu illisible.'), 'detail')}</div>`;
      detailPane.querySelector('[data-retry]')?.addEventListener('click', () => openDetail(id));
    });
  }

  function bindDetail(scope) {
    scope.querySelectorAll('[data-dt-act]').forEach((b) => b.addEventListener('click', () => {
      if (b.getAttribute('aria-disabled') === 'true' || b.getAttribute('aria-busy') === 'true') {
        announce(b.dataset.tip || 'Action indisponible.');
        return;
      }
      const act = b.dataset.dtAct;
      const id = current?.receipt?.id;
      if (!id) return;
      if (act === 'reread') reread(id);
      else if (act === 'review') openReview(id);
      else if (act === 'copy') copyDetail(current.receipt);
      else if (act === 'fiche') ctx.navigate('fiche', { dn: current.receipt.target.dn });
      else if (act === 'compensate') compensate();
    }));
    scope.querySelectorAll('.op-more').forEach((button) => button.addEventListener('click', () => {
      const target = scope.querySelector(`#${CSS.escape(button.getAttribute('aria-controls'))}`);
      const open = button.getAttribute('aria-expanded') !== 'true';
      button.setAttribute('aria-expanded', String(open));
      if (target) target.hidden = !open;
    }));
  }

  // ---------------------------------------------------------------- actions

  async function reread(id) {
    if (demo) { toast(`Exemple local${NBSP}: rien n’est relu.`, { tone: 'info' }); return; }
    const receipt = all.find((r) => r.id === id) ?? current?.receipt;
    const ok = await confirmDialog({
      title: 'Relire l’objet maintenant ?',
      message: `${receipt?.target?.name ?? 'L’objet'} sera relu sur ${receipt?.controller ?? 'le contrôleur de la session'}${receipt?.simulated ? ' (annuaire fictif)' : ''}. Seule une lecture part${NBSP}: l’écriture n’est jamais renvoyée. Le reçu reçoit une nouvelle version avec ce que la relecture constate.`,
      confirmLabel: 'Relire maintenant',
      icon: 'refresh',
    });
    if (!ok || !alive) return;
    const button = detailPane.querySelector('[data-dt-act="reread"]');
    button?.setAttribute('aria-busy', 'true');
    button?.classList.add('busy');
    announce('Relecture de l’objet…');
    try {
      const next = await ctx.call('write.receipts.verify', { id });
      toast(`Relecture${NBSP}: ${next.verificationLabel.toLowerCase()}.`, { tone: next.tone, life: 5600 });
      await load(true);
      if (selectedId === id) openDetail(id);
    } catch (err) {
      console.error(err);
      toast(`Relecture impossible${NBSP}: ${errorText(err)}`, { tone: 'alert', life: 7000 });
      button?.removeAttribute('aria-busy');
      button?.classList.remove('busy');
    }
  }

  function openReview(id) {
    const receipt = all.find((r) => r.id === id) ?? current?.receipt;
    if (!receipt?.pending) { toast(`Ce reçu est déjà résolu${NBSP}: aucune revue n’est nécessaire.`, { tone: 'info' }); return null; }
    const templates = (current?.receipt?.id === id ? current.actions.templates : null) ?? sampleDetail(receipt).actions.templates;
    const body = document.createElement('div');
    body.className = 'op-review';
    body.dataset.page = 'operations';
    body.innerHTML = `<div class="op-review-target">${toneMark('warn', 'eye')}<div><b>${esc(receipt.label)} · ${esc(receipt.target.name)}</b>
        <span>${esc(receipt.resultLabel)} · ${esc(fullDate(receipt.at))}</span></div></div>
      <p class="op-review-lead">Décrivez le contrôle que vous avez fait avec un autre outil. Le reçu deviendra «${NBSP}Revue manuelle${NBSP}»${NBSP}: ce n’est jamais une vérification automatique, et rien n’est renvoyé.</p>
      <div class="op-review-templates" role="group" aria-label="Motifs fréquents">${templates.map((t, n) => `<button type="button" class="op-template" data-t="${n}">${glyph('plus')}<span>${esc(t)}</span></button>`).join('')}</div>
      <div class="k-field op-review-field">
        <label for="op-review-reason">Contrôle réalisé</label>
        <textarea class="input" id="op-review-reason" maxlength="${REVIEW_MAX * 2}" rows="4" spellcheck="true" aria-describedby="op-review-count"></textarea>
        <div class="op-review-meter" aria-hidden="true"><i></i></div>
        <p class="op-review-count" id="op-review-count" aria-live="polite"></p>
      </div>
      <p class="op-review-note">${glyph('lock')}<span>Jamais de mot de passe, de clé ni de jeton dans un motif${NBSP}: le moteur refuse ce qui y ressemble.</span></p>`;
    const dialog = openDialog({
      title: 'Consigner une revue manuelle',
      subtitle: 'Le reçu cessera de bloquer les écritures sur cet objet.',
      icon: 'edit',
      size: 'md',
      body,
      actions: [
        { id: 'cancel', label: 'Annuler', safe: true },
        { id: 'ok', label: 'Consigner la revue', icon: 'check', primary: true, disabled: true },
      ],
    });
    const area = /** @type {HTMLTextAreaElement} */ (body.querySelector('textarea'));
    const countEl = body.querySelector('.op-review-count');
    const meter = body.querySelector('.op-review-meter i');
    const check = () => {
      const text = area.value.trim();
      const n = text.length;
      let message;
      let valid = false;
      if (n === 0) message = `Décrivez le contrôle réalisé${NBSP}: ${REVIEW_MIN} à ${REVIEW_MAX} caractères.`;
      else if (n < REVIEW_MIN) message = `${count(n, 'caractère', 'caractères')}${NBSP}: ${REVIEW_MIN} au minimum.`;
      else if (n > REVIEW_MAX) message = `${count(n, 'caractère', 'caractères')}${NBSP}: ${REVIEW_MAX} au maximum.`;
      else if (looksSecret(text)) message = `Le motif ressemble à un secret${NBSP}: décrivez le contrôle sans recopier de mot de passe, de clé ni de jeton.`;
      else { valid = true; message = `${int(n)} / ${REVIEW_MAX} caractères.`; }
      countEl.textContent = message;
      countEl.dataset.tone = valid ? 'ok' : n === 0 ? 'info' : 'warn';
      meter?.style.setProperty('--p', String(Math.min(1, n / REVIEW_MAX)));
      meter?.parentElement?.setAttribute('data-tone', valid ? 'ok' : n > REVIEW_MAX ? 'alert' : 'warn');
      dialog.setDisabled('ok', !valid || demo);
      return valid;
    };
    body.querySelector('.op-review-templates').addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-t]') : null;
      if (!b) return;
      area.value = templates[Number(b.dataset.t)] ?? '';
      area.focus();
      area.setSelectionRange(area.value.length, area.value.length);
      check();
    });
    area.addEventListener('input', check);
    check();
    setTimeout(() => area.focus({ preventScroll: true }), 60);
    dialog.result.then(async (answer) => {
      if (answer !== 'ok' || !alive) return;
      if (demo) { toast(`Exemple local${NBSP}: aucune revue n’est consignée.`, { tone: 'info' }); return; }
      try {
        const detail = await ctx.call('operations.receipts.review', { id, reason: area.value.trim() });
        toast(`Revue consignée${NBSP}: ${detail.receipt.label} · ${detail.receipt.target.name}. Le reçu ne bloque plus l’objet.`, { tone: 'info', life: 6000 });
        await load(true);
        selectedId = id;
        current = detail;
        detailPane.innerHTML = detailMarkup(detail, demo);
        applyVars(detailPane);
        bindDetail(detailPane);
      } catch (err) {
        console.error(err);
        toast(`Revue non consignée${NBSP}: ${errorText(err)}`, { tone: 'alert', life: 7000 });
      }
    });
    return dialog;
  }

  function copyDetail(receipt) {
    if (!receipt) return;
    const lines = [
      `${receipt.label} · ${receipt.target?.name ?? ''}`,
      `Résultat${NBSP}: ${receipt.resultLabel} · Relecture${NBSP}: ${receipt.verificationLabel}`,
      `Envoyée le ${fullDate(receipt.sentAt)} · Contrôleur ${receipt.controller ?? '—'} · Compte ${receipt.operator}`,
      receipt.summary,
      ...(receipt.details ?? []).map((d) => `${d.label}${NBSP}: ${d.value}`),
      `Reçu ${receipt.id}`,
    ];
    writeClipboard(maskSecrets(lines.join('\r\n'))).then((ok) => toast(ok
      ? `Détail du reçu copié. Le nom de la cible y figure${NBSP}: relisez avant tout envoi.`
      : `Copie impossible${NBSP}: le presse-papiers est indisponible.`, { tone: ok ? 'ok' : 'warn' }));
  }

  function compensate() {
    const detail = current;
    if (!detail?.compensation?.offered) return;
    const changes = detail.compensation.changes.map((c) => `${c.label}${NBSP}: ${c.before ?? '—'} → ${c.after ?? '—'}`).join(' ; ');
    toast(`Préparez la compensation dans la fiche${NBSP}: ${changes}. Elle passera par son propre plan, sa confirmation, son reçu et sa relecture.`, { tone: 'info', life: 9000 });
    ctx.navigate('fiche', { dn: detail.receipt.target.dn });
  }

  function exportCsv(csv, info) {
    if (demo) { writeClipboard(csv).then(() => toast(`Exemple local${NBSP}: CSV copié, rien n’est enregistré.`, { tone: 'info' })); return; }
    ctx.call('operations.export.save', { subject: 'recus', csv }).then((result) => {
      toast(result.saved ? `${count(info.rows, 'reçu exporté', 'reçus exportés')}${NBSP}: ${result.name}` : result.message, { tone: result.saved ? 'ok' : 'info', life: 6000 });
    }).catch((err) => toast(`Export impossible${NBSP}: ${errorText(err)}`, { tone: 'alert' }));
  }

  // ---------------------------------------------------------------- rules of the circuit

  function loadRules() {
    const box = host.querySelector('[data-rules]');
    ctx.call('operations.rules').then((rules) => {
      if (!alive) return;
      box.removeAttribute('aria-busy');
      box.innerHTML = rulesMarkup(rules);
      applyVars(box);
      reveal(box);
    }).catch((err) => {
      console.error(err);
      if (!alive) return;
      box.removeAttribute('aria-busy');
      box.innerHTML = errorBox(errorText(err, 'Règles illisibles.'));
    });
  }

  load(false);
  loadRules();

  return {
    refresh: (silent = true) => load(silent),
    select: (id) => select(id, true),
    showPending: () => { pressed = new Set(['aVerifier']); paint(); },
    openReview: () => {
      const target = all.find((r) => r.pending);
      return target ? openReview(target.id) : null;
    },
    destroy() {
      alive = false;
      grid.destroy();
      split.destroy?.();
      filters.destroy?.();
    },
  };
}

// ---------------------------------------------------------------- markup

/** A DN breaks only after its commas, never in the middle of a name. */
function breakable(text) {
  return esc(text).replace(/,/g, ',<wbr>');
}

function detailEmpty(none = false) {
  if (!none) {
    return `<div class="op-dt op-dt-empty">${emptyState('shield', 'Choisissez un reçu', 'Son détail s’affiche ici : ce que la relecture prouve, les étapes du reçu, la revue manuelle et la compensation.')}</div>`;
  }
  const steps = [
    ['eye', 'Plan', 'L’objet est relu, le changement décrit avant et après. Rien n’est écrit.'],
    ['key', 'Confirmation', 'Plan figé par son empreinte, jeton à usage unique de 5 minutes.'],
    ['file', 'Reçu', 'Écrit sur le disque avant l’envoi : sans lui, rien ne part.'],
    ['zap', 'Envoi', 'Une seule fois, jamais interrompu, jamais rejoué.'],
    ['shield', 'Relecture', 'L’objet est relu : vérifiée, écart, ou à vérifier ici.'],
  ];
  return `<div class="op-dt op-dt-howto"><div class="op-howto-head"><span class="op-howto-ico" aria-hidden="true">${glyph('shield')}</span>
      <div><span class="op-kicker">Aucun reçu pour l’instant</span><h3 class="op-dt-title" tabindex="-1">Comment naît un reçu</h3></div></div>
    <ol class="op-howto">${steps.map(([i, t, d], n) => `<li data-i="${n}"><span class="op-howto-n" aria-hidden="true">${glyph(i)}</span><div><b>${n + 1}. ${t}</b><p>${d}</p></div></li>`).join('')}</ol>
    <p class="op-dt-selection">Chaque écriture d’un écran (Fiche, Comptes…) passe par ce circuit et laisse ici son reçu, à vérifier en premier.</p>
    <a class="btn subtle sm op-howto-link" href="#/ecritures">${glyph('play')}Voir le circuit de référence</a></div>`;
}

function detailSkeleton() {
  return `<div class="op-dt" aria-busy="true"><div class="op-dt-head"><span class="skeleton op-sk-medal"></span><div class="op-sk-stack"><span class="skeleton op-sk-line w70"></span><span class="skeleton op-sk-line w40"></span></div></div>
    <span class="skeleton op-sk-line w90"></span><span class="skeleton op-sk-line w85"></span><span class="skeleton op-sk-block"></span><span class="skeleton op-sk-line w55"></span></div>`;
}

function detailMarkup(detail, demo) {
  const r = detail.receipt;
  const rule = detail.rule;
  const comp = detail.compensation;
  const actions = detail.actions;
  const icon = r.pending ? 'eye' : { ok: 'check', alert: 'alert', info: 'info', warn: 'eye' }[r.tone] ?? 'info';
  const pills = [
    pill(r.tone, r.verificationLabel, { icon: r.verification === 'verified' ? 'shield' : r.pending ? 'eye' : r.verification === 'reviewed' ? 'edit' : 'info', size: 'sm' }),
    r.simulated ? pill('accent', 'Simulation · aucun effet réel', { icon: 'sparkles', size: 'sm' }) : pill('warn', 'Annuaire réel', { icon: 'zap', size: 'sm' }),
    r.pending ? pill('warn', 'Bloque les écritures sur cet objet', { icon: 'lock', size: 'sm', pulse: true }) : '',
    demo ? pill('off', 'Exemple local', { icon: 'info', size: 'sm' }) : '',
  ].join('');
  const trail = (r.details ?? []).map((d, n) => `<li class="op-trail-item" data-i="${n}" data-kind="${esc(d.label === 'Revue manuelle' ? 'review' : d.label === 'Relecture' ? 'read' : d.label === 'Envoi' ? 'send' : 'check')}">
      <span class="op-trail-dot" aria-hidden="true">${glyph(d.label === 'Revue manuelle' ? 'edit' : d.label === 'Relecture' ? 'eye' : d.label === 'Envoi' ? 'zap' : 'shield')}</span>
      <div><b>${esc(d.label)}</b><p>${esc(d.value)}</p></div></li>`).join('');
  const changes = (r.plan?.changes ?? []).map((c, n) => `<div class="op-diff-row" data-i="${n}"><span class="op-diff-label">${esc(c.label)}<small class="mono">${esc(c.attribute)}</small></span>
      <span class="op-diff-before">${esc(c.before ?? '(vide)')}</span><span class="op-diff-arrow" aria-hidden="true">${glyph('chevronRight')}</span><span class="op-diff-after">${esc(c.after ?? '(vide)')}</span></div>`).join('');
  const compChanges = comp.changes?.length
    ? `<div class="op-diff op-diff-inverse">${comp.changes.map((c, n) => `<div class="op-diff-row" data-i="${n}"><span class="op-diff-label">${esc(c.label)}<small class="mono">${esc(c.attribute)}</small></span>
        <span class="op-diff-before">${esc(c.before ?? '(vide)')}</span><span class="op-diff-arrow" aria-hidden="true">${glyph('undo')}</span><span class="op-diff-after">${esc(c.after ?? '(vide)')}</span></div>`).join('')}</div>`
    : '';
  const verifyReason = actions.canVerify ? '' : ` aria-disabled="true" data-tip="${esc(actions.verifyWhy ?? '')}"`;
  const reviewReason = actions.canReview ? '' : ` aria-disabled="true" data-tip="${esc(actions.reviewWhy ?? '')}"`;
  const id = `op-dt-${r.id.slice(0, 8)}`;
  return `<article class="op-dt" data-tone="${esc(r.tone)}" aria-labelledby="${id}-t">
    <header class="op-dt-head">
      <span class="op-medal" data-tone="${esc(r.tone)}" aria-hidden="true"><span class="op-medal-halo"></span><span class="op-medal-ring"></span><span class="op-medal-icon">${glyph(icon)}</span></span>
      <div class="op-dt-titles"><span class="op-kicker">${esc(r.label)}</span>
        <h3 class="op-dt-title" id="${id}-t" tabindex="-1">${esc(r.resultLabel)}</h3>
        <span class="op-dt-target">${glyph({ user: 'user', computer: 'monitor', group: 'group', ou: 'ou' }[r.target.kind] ?? 'object')}<b>${esc(r.target.name)}</b><span>${esc(r.target.kindLabel)}</span></span></div>
    </header>
    <div class="op-dt-pills">${pills}</div>
    <p class="op-dt-summary">${esc(r.summary)}</p>
    ${r.error ? `<p class="op-dt-error" role="note">${glyph('alert')}<span>${esc(r.error.message)}</span></p>` : ''}
    <div class="op-dt-actions">
      <button class="btn ${r.pending ? 'primary' : 'subtle'} sm" type="button" data-dt-act="reread"${verifyReason}>${glyph('refresh')}${r.pending ? 'Relire pour trancher…' : 'Relire l’objet…'}</button>
      <button class="btn subtle sm" type="button" data-dt-act="review"${reviewReason}>${glyph('edit')}Consigner une revue…</button>
      <button class="btn ghost sm" type="button" data-dt-act="copy">${glyph('copy')}Copier</button>
      <button class="btn ghost sm" type="button" data-dt-act="fiche">${glyph('object')}Fiche</button>
    </div>
    <p class="op-dt-selection">${esc(actions.selection)}</p>
    <section class="op-proof" aria-labelledby="${id}-p">
      <span class="op-proof-ico" aria-hidden="true">${glyph('shield')}</span>
      <div><h4 id="${id}-p">Preuve attendue · ${esc(rule.proof)}</h4><p>${esc(rule.check)}</p>
        <small>Le code de retour de la requête n’est jamais une preuve${NBSP}: seule la relecture de l’objet sur le contrôleur fait foi.${rule.partial ? ' Une relecture conforme ne prouve pas la cause : jamais plus que « partiel ».' : ''}</small></div>
    </section>
    ${changes ? `<section class="op-dt-block"><h4>Changement${(r.plan?.changes?.length ?? 0) > 1 ? 's' : ''} du plan</h4><div class="op-diff">${changes}</div></section>` : ''}
    ${trail ? `<section class="op-dt-block"><h4>Étapes du reçu</h4><ol class="op-trail">${trail}</ol></section>` : ''}
    <dl class="op-facts">
      <div><dt>Compte</dt><dd class="mono">${esc(r.operator)}</dd></div>
      <div><dt>Contrôleur</dt><dd class="mono">${esc(r.controller ?? '—')}</dd></div>
      <div><dt>Envoyée le</dt><dd>${esc(fullDate(r.sentAt))}</dd></div>
      <div><dt>Relue le</dt><dd>${esc(r.verifiedAt ? fullDate(r.verifiedAt) : '—')}</dd></div>
      <div class="wide"><dt>Chemin (DN)</dt><dd class="mono op-dn">${breakable(r.target.dn)}</dd></div>
      <div class="wide"><dt>Reçu</dt><dd class="mono">${esc(r.id)}</dd></div>
    </dl>
    <section class="op-comp" data-offered="${comp.offered ? 'true' : 'false'}" aria-labelledby="${id}-c">
      <div class="op-comp-head">${glyph(comp.offered ? 'undo' : 'lock')}<h4 id="${id}-c">Compensation</h4>${comp.offered ? pill('ok', 'Possible', { size: 'sm' }) : pill('off', 'Non proposée', { size: 'sm' })}</div>
      <p>${esc(comp.reason)}</p>${compChanges}
      ${comp.offered ? `<button class="btn subtle sm" type="button" data-dt-act="compensate">${glyph('object')}Préparer l’annulation dans la fiche</button>` : ''}
    </section>
    ${r.plan?.details ? `<div class="op-tech"><button class="op-more" type="button" aria-expanded="false" aria-controls="${id}-d">${glyph('chevronRight')}Plan exécuté (détails techniques)</button>
      <pre class="op-pre mono" id="${id}-d" hidden>${esc(r.plan.details)}</pre></div>` : ''}
  </article>`;
}

function rulesMarkup(rules) {
  const kinds = rules.kinds.map((k, n) => `<li class="op-kind" data-i="${n}"><span class="op-kind-proof">${esc(k.proof)}</span>
      <div class="op-kind-main"><b>${esc(k.label)}</b><span class="mono">${esc(k.kind)}</span><p>${esc(k.check)}</p></div>
      ${k.available ? pill('ok', 'Servie', { size: 'sm', tip: 'Son exécuteur est branché dans ce mode.' }) : pill('off', 'À venir', { size: 'sm', tip: 'Aucun exécuteur dans ce mode pour l’instant.' })}</li>`).join('');
  const compensable = rules.kinds.filter((k) => k.compensable);
  const refused = rules.kinds.filter((k) => !k.compensable);
  const comps = `<h4 class="op-comp-h">Compensables</h4><ul class="op-comp-list">${compensable.map((k) => `<li data-ok="true">${glyph('undo')}<span>${esc(k.label)}</span></li>`).join('')}</ul>
    <h4 class="op-comp-h">Jamais compensés</h4>
    <ul class="op-comp-chips">${refused.map((k) => `<li data-tip="${esc(k.compensation)}" tabindex="0">${glyph('lock')}<span>${esc(k.label)}</span></li>`).join('')}</ul>
    <p class="op-comp-why">Mot de passe, suppression, création, déverrouillage, renommage et actions à distance${NBSP}: aucun inverse sûr. Survolez un nom pour la raison.</p>`;
  const cycles = rules.lifecycles.map((v, n) => `<article class="op-cycle" data-i="${n}"><header><b>${esc(v.plan.title)}</b><span>${esc(v.plan.summary)}</span></header>
      <ol class="op-cycle-steps">${v.plan.steps.map((s, i) => `<li data-available="${v.available[i] ? 'true' : 'false'}"><span class="op-cycle-n">${s.id}</span><span class="op-cycle-t">${esc(s.title)}</span>
        ${v.available[i] ? '' : `<span class="op-cycle-soon" data-tip="${esc('Écriture ' + s.writeKind + ' à venir dans ce mode.')}">à venir</span>`}</li>`).join('')}</ol>
      <p class="op-cycle-note">${esc(v.note)}</p></article>`).join('');
  return `<p class="op-rules-note">${esc(rules.note)}</p><div class="grid">
    <section class="card span-5 op-rule-card reveal">${cardHead('eye', 'Preuves par relecture', 'Ce que relit chaque type d’écriture')}<ul class="op-kinds">${kinds}</ul></section>
    <section class="card span-3 op-rule-card reveal">${cardHead('undo', 'Compensations', 'Nouvelle écriture, jamais automatique')}${comps}</section>
    <section class="card span-4 op-rule-card reveal">${cardHead('layers', 'Séquences de cycle de vie', 'Une étape incertaine bloque la suite, jamais rejouée')}<div class="op-cycles">${cycles}</div></section>
  </div>`;
}

export { stateOf };
