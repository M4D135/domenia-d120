// « Relevés » workspace (Domenia 1 point 30): dated copies of the base for a scope, with the proof of their coverage, listed,
// deleted (write circuit, from the menu of the row) and compared two by two (local read: additions, disappearances, moves,
// renames, changed values, exact totals, 500 rows per category). A snapshot holds no password, right or membership and cannot
// restore the directory.
import { createGrid } from '../../kit/index.js';
import { runWrite } from '../../write-flow.js';
import {
  esc, icon, glyph, pill, int, count, NBSP, cardHead, button, paint, errorBlock, skStack, errorText, emptyBlock, stamp, fitGrid, latest,
} from './common.js';

const COVERAGE = {
  complete: { label: 'Complète', tone: 'ok' },
  partial: { label: 'Incomplète', tone: 'warn' },
  unknown: { label: 'Inconnue', tone: 'warn' },
  missing: { label: 'Aucune', tone: 'off' },
};
const NATURE = {
  added: { label: 'Ajouts', one: 'Ajout', tone: 'ok', icon: 'plus' },
  disappeared: { label: 'Disparitions', one: 'Disparition', tone: 'alert', icon: 'minus' },
  moved: { label: 'Déplacements', one: 'Déplacement', tone: 'info', icon: 'split' },
  renamed: { label: 'Renommages', one: 'Renommage', tone: 'info', icon: 'edit' },
  changed: { label: 'Valeurs modifiées', one: 'Valeur modifiée', tone: 'accent', icon: 'sliders' },
};

const LIST_COLUMNS = [
  { id: 'label', label: 'Nom', required: true, width: 192 },
  { id: 'capturedAt', label: 'Date', type: 'date', dateStyle: 'datetime', width: 140 },
  { id: 'objectCount', label: 'Objets', type: 'number', width: 100, align: 'end' },
  { id: 'scopeText', label: 'Périmètre', width: 140 },
  { id: 'coverageState', label: 'Couverture', type: 'enum', width: 134, options: Object.entries(COVERAGE).map(([value, c]) => ({ value, label: c.label, tone: c.tone })) },
  { id: 'coverageText', label: 'Preuve de couverture', width: 360, hidden: true },
  { id: 'rowsSha256', label: 'Empreinte SHA-256', mono: true, hidden: true, width: 300 },
];

const DIFF_COLUMNS = [
  { id: 'nature', label: 'Nature', type: 'enum', width: 150, options: Object.entries(NATURE).map(([value, n]) => ({ value, label: n.one, tone: n.tone })) },
  { id: 'name', label: 'Objet', required: true, width: 170 },
  { id: 'detail', label: 'Détail', width: 236 },
  { id: 'before', label: 'Avant', width: 236 },
  { id: 'after', label: 'Après', width: 236 },
  { id: 'beforeDn', label: 'DN avant', mono: true, hidden: true, width: 360 },
  { id: 'afterDn', label: 'DN après', mono: true, hidden: true, width: 360 },
  { id: 'guid', label: 'GUID', mono: true, hidden: true, width: 300 },
];

function optionList(rows, selected) {
  return rows.map((r) => `<option value="${esc(r.id)}"${r.id === selected ? ' selected' : ''}>${esc(r.display)}</option>`).join('');
}

function countersMarkup(c) {
  const items = [['added', c.added], ['disappeared', c.disappeared], ['moved', c.moved], ['renamed', c.renamed], ['changed', c.changed]];
  const top = Math.max(1, ...items.map(([, n]) => n));
  return `<div class="sy-diff-counters">${items.map(([k, n], i) => `<button class="sy-diff-counter" type="button" data-nature="${k}" data-tone="${NATURE[k].tone}" data-i="${i}" aria-pressed="false"${n ? '' : ' disabled'}>
      <span class="sy-diff-ico">${glyph(NATURE[k].icon)}</span><b class="num">${int(n)}</b><span>${esc(NATURE[k].label)}</span><span class="sy-mini-bar"><span data-fill="${(n / top).toFixed(3)}"></span></span>
    </button>`).join('')}
    <div class="sy-diff-counter calm" data-i="5"><span class="sy-diff-ico">${glyph('check')}</span><b class="num">${int(c.unchanged)}</b><span>Inchangés</span><span class="sy-mini-bar"><span data-fill="1"></span></span></div></div>`;
}

/** Renders the workspace in its panel; returns its cleanup. */
export function renderSnapshots(panel, screen) {
  const ctx = screen.ctx;
  panel.classList.add('sy-ws', 'sy-ws-snapshots');
  const answers = latest();
  const compares = latest();
  let alive = true;
  let snapshots = null;
  let report = null;
  let nature = null;
  let pair = { before: null, after: null };
  let autoCompare = ctx.params.comparer === '1';
  panel.innerHTML = `<div class="sy-ws-grid">
      <div class="sy-callout span-12" data-tone="info" data-i="0">${icon('info')}<p data-slot="notice">Un relevé est une copie datée de la base locale pour un périmètre.</p></div>
      <section class="sy-card span-4" data-slot="capture" data-i="1">${cardHead('layers', 'Nouveau relevé', 'Copie datée du périmètre, sans lecture de l’annuaire')}<div class="sy-slot">${skStack('sk-line w55', 'sk-line w85', 'sk-line w40')}</div></section>
      <section class="sy-card span-8 sy-list-card" data-slot="list" data-i="2">${cardHead('history', 'Relevés enregistrés', 'Du plus récent au plus ancien · clic droit sur un relevé pour le comparer ou le supprimer')}
        <p class="sy-list-text" data-slot="list-text"></p><div class="sy-snap-grid"></div><div class="sy-snap-pick" data-slot="pick" aria-live="polite"></div></section>
      <section class="sy-card span-12" data-slot="compare" data-i="3">
        ${cardHead('split', 'Comparer deux relevés', `Même domaine et même périmètre${NBSP}; totaux exacts, 500 lignes par catégorie`)}
        <div class="sy-compare-bar">
          <label class="sy-field-inline"><span>Avant</span><span class="k-select"><select class="input" data-sn="before" aria-label="Relevé le plus ancien"></select></span></label>
          <button class="btn ghost icon sm" type="button" data-sn="swap" aria-label="Échanger avant et après" data-tip="Échanger avant et après (la comparaison est refaite)">${glyph('split')}</button>
          <label class="sy-field-inline"><span>Après</span><span class="k-select"><select class="input" data-sn="after" aria-label="Relevé le plus récent"></select></span></label>
          ${button('Comparer', { icon: 'split', primary: true, data: { sn: 'compare' }, tip: 'Compare les deux relevés dans la base locale. Aucune lecture de l’annuaire.' })}
        </div>
        <div class="sy-report" data-slot="report"><div class="sy-report-empty">${emptyBlock('split', 'Choisissez deux relevés du même périmètre', `Ajouts, disparitions, déplacements, renommages et valeurs modifiées${NBSP}: aucune disparition n’est une preuve de suppression.`)}</div></div>
      </section>
    </div>`;
  const listGrid = createGrid(panel.querySelector('.sy-snap-grid'), {
    key: 'synchro.snapshots.v3',
    label: 'Relevés enregistrés',
    rowId: (r) => r.id,
    selection: 'single',
    loading: true,
    height: '214px',
    quickFilter: false,
    columns: LIST_COLUMNS,
    empty: { icon: 'layers', title: 'Aucun relevé', text: 'Enregistrez un relevé du périmètre pour pouvoir comparer plus tard.' },
    onSelectionChange: (rows) => paintPick(rows[0] ?? null),
    onActivate: (row) => compareWithLatest(row),
    contextMenu: ({ row }) => [
      { heading: row ? row.label : 'Relevé' },
      { label: 'Comparer avec le plus récent', icon: 'split', disabled: !row || !latestOther(row), reason: 'Aucun autre relevé du même périmètre.', run: () => compareWithLatest(row) },
      { label: `Prendre comme «${NBSP}avant${NBSP}»`, icon: 'history', disabled: !row, reason: 'Aucune ligne.', run: () => setSide('before', row) },
      { label: `Prendre comme «${NBSP}après${NBSP}»`, icon: 'layers', disabled: !row, reason: 'Aucune ligne.', run: () => setSide('after', row) },
      '-',
      { label: 'Supprimer le relevé…', icon: 'trash', danger: true, kind: 'write', disabled: !row, reason: 'Aucune ligne.', run: () => remove(row) },
    ],
  });
  let diffGrid = null;

  /** The selected snapshot and what can be done with it (the menu of the row offers the same). */
  function paintPick(row) {
    const host = panel.querySelector('[data-slot="pick"]');
    if (!row) {
      host.innerHTML = `<p class="sy-pick-hint">${glyph('info')}<span>Choisissez un relevé${NBSP}: double clic pour le comparer au plus récent, clic droit pour ses autres gestes.</span></p>`;
      return;
    }
    const cov = COVERAGE[row.coverageState] ?? COVERAGE.unknown;
    host.innerHTML = `<div class="sy-pick">
        <span class="sy-pick-ico">${glyph('layers')}</span>
        <div><b>${esc(row.label)}</b><small>${esc(stamp(row.capturedAt))} · ${esc(count(row.objectCount, 'objet', 'objets'))} · ${esc(row.scopeText)}</small><small class="sy-pick-proof">${esc(row.coverageText)}</small></div>
        ${pill(cov.tone, `Couverture ${cov.label.toLowerCase()}`, { size: 'sm' })}
        <div class="sy-pick-actions">${button('Comparer au plus récent', { sm: true, icon: 'split', data: { sn: 'compare-latest' }, disabled: !latestOther(row), tip: latestOther(row) ? '' : 'Aucun autre relevé du même périmètre.' })}${button('Supprimer…', { sm: true, ghost: true, danger: true, icon: 'trash', kind: 'write', data: { sn: 'delete' } })}</div>
      </div>`;
    paint(host);
  }

  function captureMarkup(s) {
    return `<div class="sy-capture">
        <label class="sy-capture-label"><span>Nom du relevé <small>(facultatif)</small></span><input class="input" type="text" maxlength="120" data-sn="label" placeholder="Par exemple «${NBSP}Avant migration${NBSP}»" autocomplete="off"></label>
        <div class="sy-capture-scope" data-slot="capture-scope"></div>
        <div class="sy-capture-meter" data-slot="capture-meter"></div>
        ${button('Enregistrer un relevé du périmètre', { icon: 'layers', primary: true, kind: 'write', data: { sn: 'capture' } })}
      </div>`;
  }

  /** Repaints the scope, the counter and the button of the capture card; the name typed by the operator stays. */
  function paintCaptureState() {
    if (!snapshots) return;
    const o = screen.overview;
    const scope = o?.scope;
    const cov = o?.coverage;
    const s = snapshots;
    const full = s.count >= s.max;
    const tone = cov?.status === 'complete' ? 'ok' : 'warn';
    const scopeHost = panel.querySelector('[data-slot="capture-scope"]');
    const meterHost = panel.querySelector('[data-slot="capture-meter"]');
    if (!scopeHost || !meterHost) return;
    scopeHost.innerHTML = `<span class="sy-scope-kicker">${glyph(scope?.isDomain ? 'domain' : 'ou')}Périmètre</span><b>${esc(scope?.label ?? '—')}</b><small>${esc(scope?.path ?? '')}</small>
      ${pill(tone, cov?.status === 'complete' ? 'Couverture complète' : 'Couverture non prouvée', { size: 'sm' })}`;
    meterHost.innerHTML = `<span>${esc(`${int(s.count)} relevés sur ${int(s.max)}`)}</span><span class="sy-mini-bar"><span data-fill="${(s.count / s.max).toFixed(3)}"></span></span>`;
    const b = panel.querySelector('[data-sn="capture"]');
    b.disabled = full;
    b.setAttribute('aria-disabled', String(full));
    b.dataset.tip = full ? `50 relevés au plus par domaine${NBSP}: supprimez un ancien relevé.` : 'Copie datée de la base locale pour le périmètre, avec la preuve de sa couverture. Aucune lecture de l’annuaire.';
    paint(panel.querySelector('[data-slot="capture"]'));
  }

  const sameScope = (a, b) => a.scopeDn.toLowerCase() === b.scopeDn.toLowerCase();
  /** The most recent other snapshot of the same scope, or null. */
  const latestOther = (row) => (snapshots?.rows ?? []).find((r) => r.id !== row.id && sameScope(r, row)) ?? null;

  function choose(rows) {
    const ids = new Set(rows.map((r) => r.id));
    if (!ids.has(pair.after)) pair.after = rows[0]?.id ?? null;
    const after = rows.find((r) => r.id === pair.after);
    if (!ids.has(pair.before) || pair.before === pair.after) {
      pair.before = rows.find((r) => r.id !== pair.after && after && sameScope(r, after))?.id ?? rows.find((r) => r.id !== pair.after)?.id ?? null;
    }
    panel.querySelector('[data-sn="before"]').innerHTML = optionList(rows, pair.before);
    panel.querySelector('[data-sn="after"]').innerHTML = optionList(rows, pair.after);
  }

  function setSide(side, row) {
    if (!row) return;
    pair[side] = row.id;
    panel.querySelector(`[data-sn="${side}"]`).value = row.id;
    panel.querySelector('[data-slot="compare"]').scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  function compareWithLatest(row) {
    const other = row && latestOther(row);
    if (!other) return;
    const [older, newer] = Date.parse(row.capturedAt) <= Date.parse(other.capturedAt) ? [row, other] : [other, row];
    pair = { before: older.id, after: newer.id };
    panel.querySelector('[data-sn="before"]').value = older.id;
    panel.querySelector('[data-sn="after"]').value = newer.id;
    compare();
    panel.querySelector('[data-slot="compare"]').scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  async function load() {
    const my = answers.next();
    try {
      const data = await ctx.call('synchro.controls', screen.scopeArgs());
      if (!alive || !answers.keep(my, data.generation)) return;
      const first = !snapshots;
      snapshots = data.snapshots;
      panel.querySelector('[data-slot="notice"]').textContent = snapshots.notice;
      if (first) panel.querySelector('[data-slot="capture"] .sy-slot').innerHTML = captureMarkup(snapshots);
      paintCaptureState();
      panel.querySelector('[data-slot="list-text"]').textContent = snapshots.text;
      const selected = listGrid.getSelectedIds();
      listGrid.setRows(snapshots.rows, { keepSelection: true });
      fitGrid(listGrid, snapshots.rows.length, { min: 3, max: 7 });
      paintPick(snapshots.rows.find((r) => selected.includes(r.id)) ?? null);
      choose(snapshots.rows);
      paint(panel);
      if (autoCompare && pair.before && pair.after) { autoCompare = false; compare(); }
    } catch (err) {
      console.error(err);
      if (!alive || !answers.keep(my)) return;
      panel.querySelector('[data-slot="capture"] .sy-slot').innerHTML = errorBlock(err);
      listGrid.setError(errorText(err), { retry: load });
    }
  }

  async function compare() {
    pair.before = panel.querySelector('[data-sn="before"]').value || pair.before;
    pair.after = panel.querySelector('[data-sn="after"]').value || pair.after;
    const host = panel.querySelector('[data-slot="report"]');
    if (!pair.before || !pair.after) return;
    const my = compares.next();
    host.innerHTML = `<div aria-busy="true" class="sy-report-loading">${skStack('sk-line w70', 'sk-block w100', 'sk-line w55')}</div>`;
    try {
      const next = await ctx.call('synchro.snapshot.compare', { before: pair.before, after: pair.after });
      if (!alive || !compares.keep(my)) return;
      report = next;
      nature = null;
      showReport();
    } catch (err) {
      console.error(err);
      if (!compares.keep(my)) return;
      report = null;
      host.innerHTML = errorBlock(err, false);
    }
  }

  function showReport() {
    const host = panel.querySelector('[data-slot="report"]');
    diffGrid?.destroy();
    diffGrid = null;
    const r = report;
    if (!r.comparable) {
      host.innerHTML = `<div class="sy-callout" data-tone="warn">${icon('alert')}<p><b>Comparaison impossible</b>${esc(r.reasons.join(' '))}</p></div>`;
      return;
    }
    const warnings = r.warnings.map((w) => `<li data-tone="warn">${icon('alert')}<span>${esc(w)}</span></li>`).join('');
    const side = (row, glyphName) => {
      const cov = COVERAGE[row.coverageState] ?? COVERAGE.unknown;
      return `<span class="sy-pair-side">${glyph(glyphName)}<b>${esc(row.label)}</b><small>${esc(stamp(row.capturedAt))} · ${count(row.objectCount, 'objet', 'objets')}</small>${pill(cov.tone, `Couverture ${cov.label.toLowerCase()}`, { size: 'sm' })}</span>`;
    };
    host.innerHTML = `<div class="sy-report-head">
        <div class="sy-pair">${side(r.before, 'history')}<span class="sy-pair-arrow" aria-hidden="true">${glyph('chevronRight')}</span>${side(r.after, 'layers')}</div>
        ${button('Exporter CSV', { icon: 'csv', sm: true, data: { sn: 'export' }, tip: 'Écrit le rapport de cette comparaison dans le dossier Exports' })}
      </div>
      <div class="sy-report-facts">
        <p class="sy-report-headline">${glyph('layers')}<span>${esc(r.headline)}</span></p>
        <p class="sy-report-overlap">${glyph('info')}<span>${esc(r.overlap)}</span></p>
      </div>
      ${countersMarkup(r.counts)}
      ${warnings ? `<ul class="sy-est-warn">${warnings}</ul>` : ''}
      ${r.truncated ? `<p class="sy-muted">${icon('info')}<span>Affichage limité à ${int(r.limit)} lignes par catégorie${NBSP}; les totaux sont exacts.</span></p>` : ''}
      <div class="sy-diff-grid"></div>`;
    diffGrid = createGrid(host.querySelector('.sy-diff-grid'), {
      key: 'synchro.snapshot.diff.v3',
      label: 'Différences entre les deux relevés',
      rowId: (row, n) => `${row.guid}-${row.nature}-${n}`,
      selection: 'none',
      height: '380px',
      columns: DIFF_COLUMNS,
      rows: r.rows,
      empty: { icon: 'check', title: 'Aucune différence', text: 'Les deux relevés contiennent les mêmes objets, aux mêmes emplacements et avec les mêmes valeurs.' },
    });
    fitGrid(diffGrid, r.rows.length, { min: 4, max: 10 });
    paint(host);
  }

  function filterNature(k) {
    nature = nature === k ? null : k;
    panel.querySelectorAll('.sy-diff-counter[data-nature]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.nature === nature)));
    diffGrid?.setRows(nature ? report.rows.filter((r) => r.nature === nature) : report.rows);
  }

  async function exportReport(btn) {
    if (!report?.comparable) return;
    btn.disabled = true;
    try {
      // The comparison shown, whatever the lists say now.
      const r = await ctx.call('synchro.snapshot.export', { before: report.before.id, after: report.after.id });
      ctx.toast(r.written ? `${count(r.rows, 'ligne exportée', 'lignes exportées')}${NBSP}: ${r.fileName}` : r.text, { tone: r.written ? 'ok' : 'info', life: 6000 });
    } catch (err) {
      console.error(err);
      ctx.toast(`Export non écrit${NBSP}: ${errorText(err)}`, { tone: 'alert' });
    } finally {
      btn.disabled = false;
    }
  }

  function capture() {
    const input = panel.querySelector('[data-sn="label"]');
    const label = input?.value.trim() ?? '';
    runWrite(ctx, {
      plan: 'synchro.snapshot.plan',
      args: { ...(label ? { label: label.slice(0, 120) } : {}), ...screen.scopeArgs() },
      subtitle: 'Relevés de l’annuaire',
      onDone: () => { if (input) input.value = ''; screen.emit('stored', { kind: 'snapshot' }); load(); },
    });
  }

  function remove(row) {
    if (!row) return;
    runWrite(ctx, {
      plan: 'synchro.snapshot.delete.plan',
      args: { id: row.id },
      subtitle: `Relevé${NBSP}: ${row.label}`,
      onDone: () => {
        if (report && (report.before.id === row.id || report.after.id === row.id)) {
          report = null;
          diffGrid?.destroy();
          diffGrid = null;
          panel.querySelector('[data-slot="report"]').innerHTML = '';
        }
        screen.emit('stored', { kind: 'snapshot' });
        load();
      },
    });
  }

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-sn], [data-nature], [data-retry]') : null;
    if (!t || t.disabled) return;
    if (t.dataset.retry !== undefined) { load(); return; }
    if (t.dataset.nature) { filterNature(t.dataset.nature); return; }
    const act = t.dataset.sn;
    if (act === 'compare') compare();
    else if (act === 'swap') {
      const b = panel.querySelector('[data-sn="before"]');
      const a = panel.querySelector('[data-sn="after"]');
      [b.value, a.value] = [a.value, b.value];
      pair = { before: b.value, after: a.value };
      // The report shown always matches the lists: a swap compares again.
      if (report) compare();
    } else if (act === 'export') exportReport(t);
    else if (act === 'capture') capture();
    else if (act === 'delete') remove(listGrid.getSelection()[0]);
    else if (act === 'compare-latest') compareWithLatest(listGrid.getSelection()[0]);
  };
  panel.addEventListener('click', onClick);
  const offScope = screen.on('scope', () => load());
  const offOverview = screen.on('overview', () => paintCaptureState());
  const offAsk = screen.on('ask', (what) => { if (what === 'capture') panel.querySelector('[data-sn="label"]')?.focus(); });
  paintPick(null);
  load();

  return () => {
    alive = false;
    offScope();
    offOverview();
    offAsk();
    panel.removeEventListener('click', onClick);
    listGrid.destroy();
    diffGrid?.destroy();
  };
}
