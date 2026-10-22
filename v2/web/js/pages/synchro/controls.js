// « Contrôles » workspace (Domenia 1 Contrôles tab, points 22 to 24): census advice of the scope (never starts anything),
// identities of the last census missing from the base (read by GUID on request), objects a complete read did not see again
// (verified by GUID on request: only an isDeleted entry proves a deletion), shown for the scope or for the whole domain.
// Every directory read asks a confirmation first, shows its progress, and keeps its result until the operator stores it
// through the write circuit or drops it.
import { onEvent } from '../../bridge.js';
import { createGrid, confirmDialog } from '../../kit/index.js';
import { runWrite } from '../../write-flow.js';
import {
  esc, icon, glyph, pill, int, count, NBSP, toneOf, cardHead, button, paint, errorBlock, skStack, errorText, typeGlyph, fitGrid, latest, stamp,
} from './common.js';

const STATUS = {
  notSeen: { label: 'Non revu, à vérifier', tone: 'warn', icon: 'eye' },
  visible: { label: 'De nouveau visible', tone: 'ok', icon: 'check' },
  moved: { label: 'Déplacé', tone: 'info', icon: 'split' },
  deleted: { label: 'Suppression constatée', tone: 'alert', icon: 'trash' },
  notFound: { label: 'Introuvable', tone: 'off', icon: 'search' },
  invisible: { label: 'Invisible pour ce compte', tone: 'off', icon: 'eyeOff' },
  unconfirmed: { label: 'Vérification impossible', tone: 'warn', icon: 'alert' },
};
const CENSUS_ICONS = { recent: 'check', due: 'clock', partial: 'alert', absent: 'info', clock: 'alert', gap: 'users' };
const CENSUS_LABELS = { recent: 'À jour', due: 'Recensement dû', partial: 'Incomplet', absent: 'Jamais complet', clock: 'Horloge douteuse', gap: 'Objets manquants' };

/** The complete read behind the advice: when, from which scope, against which threshold (from the overview). */
function coverageFacts(o) {
  const cov = o?.coverage;
  if (!cov) return '';
  return `<dl class="sy-facts three sy-census-facts">
      <div><dt>Lecture complète</dt><dd>${cov.at ? esc(stamp(cov.at)) : 'Jamais'}</dd></div>
      <div><dt>Source</dt><dd>${esc(cov.sourceLabel ?? '—')}</dd></div>
      <div><dt>Seuil</dt><dd>${esc(count(o.limits?.fullRebuildDays ?? 7, 'jour', 'jours'))}</dd></div>
    </dl>`;
}

function censusMarkup(c, scope, ready, reason, o) {
  const tone = toneOf(c.tone);
  const age = Number.isFinite(c.ageDays) ? `${c.ageDays < 1 ? 'moins d’un jour' : count(c.ageDays, 'jour', 'jours')} · seuil ${count(c.maxAgeDays, 'jour', 'jours')}` : `seuil ${count(c.maxAgeDays, 'jour', 'jours')}`;
  // Domenia 1: « demande une OU si aucune n’est choisie ». With the domain as scope, the gesture opens the OU choice first.
  const action = scope.isDomain
    ? button('Choisir l’OU à relire en entier…', { icon: 'tree', kind: 'network', primary: c.due, data: { ct: 'choose' }, disabled: !ready, tip: ready ? `Le domaine entier n’est pas une OU de mise à jour${NBSP}: choisissez l’OU, puis confirmez son estimation.` : reason })
    : button('Relire l’OU choisie en entier…', { icon: 'refresh', kind: 'network', primary: c.due, data: { ct: 'read' }, disabled: !ready, tip: ready ? `Lecture complète des utilisateurs et postes de l’OU et de ses sous-OU${NBSP}: seule une lecture complète repère disparus et déplacés. Rien n’est modifié dans l’annuaire.` : reason });
  return `<div class="sy-census" data-tone="${tone}">
      <span class="sy-census-ring" aria-hidden="true"><span>${glyph(CENSUS_ICONS[c.state] ?? 'info')}</span></span>
      <div class="sy-census-main">
        <div class="sy-census-line">${pill(tone, CENSUS_LABELS[c.state] ?? 'Recensement', { size: 'sm' })}<span class="sy-census-age">${esc(age)}</span></div>
        <p>${esc(c.text)}</p>
        <p class="sy-muted">${icon('info')}<span>Seule une lecture complète repère les disparus et les objets devenus visibles sans modification${NBSP}; Domenia la conseille, ne la lance jamais seule.</span></p>
      </div>
    </div>
    ${coverageFacts(o)}
    <div class="sy-card-actions">${c.gapCount > 0 && c.state !== 'gap' ? `<span class="sy-gap-hint">${glyph('users')}${esc(count(c.gapCount, 'identité recensée manque', 'identités recensées manquent'))}</span>` : ''}${action}</div>`;
}

function gapsMarkup(g) {
  const list = g.rows.slice(0, 6).map((r, n) => `<li data-i="${n}">${glyph('user')}<span><b>${esc(r.name || r.guid)}</b><small>${esc(r.location || '—')}</small></span></li>`).join('');
  return `<p class="sy-gap-summary">${esc(g.summary)}</p>
    ${g.total ? `<ul class="sy-gap-list">${list}</ul>` : ''}
    <div class="sy-card-actions">${g.total > 6 ? `<span class="sy-more">${esc(`et ${count(g.total - 6, 'autre identité', 'autres identités')}`)}</span>` : ''}${button('Lire les objets manquants…', { icon: 'download', kind: 'network', data: { ct: 'gaps' }, disabled: !g.canRead, tip: g.canRead ? 'Lit par leur GUID, après confirmation, jusqu’à 200 objets que le dernier recensement a trouvés dans l’AD mais pas dans la base. Ni relecture de tout le domaine, ni modification de l’annuaire.' : 'Aucun objet manquant à lire.' })}</div>
    <div class="sy-job" data-job="gaps" hidden></div>`;
}

/** Facets by status, counted on the rows shown (scope or whole domain). */
function facetsMarkup(rows, filter) {
  const chips = Object.entries(STATUS).map(([status, s]) => [status, s, rows.filter((r) => r.status === status).length]).filter(([, , n]) => n > 0)
    .map(([status, s, n]) => `<button class="sy-facet" type="button" data-facet="${esc(status)}" data-tone="${s.tone}" aria-pressed="${filter === status}">${glyph(s.icon)}<span>${esc(s.label)}</span><b>${int(n)}</b></button>`).join('');
  return `<div class="sy-facets" role="group" aria-label="Filtrer par état">${chips}</div>`;
}

/** Scope of the list: the objects last seen in the scope of the screen, or every disappearance of the domain. */
function scopeToggle(scope, absences, wide) {
  if (scope.isDomain) return '';
  return `<div class="segmented sy-seg" role="group" aria-label="Portée de la liste">
      <button type="button" data-abs="scope" aria-pressed="${!wide}">${esc(scope.label)}<b>${int(absences.inScope)}</b></button>
      <button type="button" data-abs="domain" aria-pressed="${wide}">Tout le domaine<b>${int(absences.total)}</b></button>
    </div>`;
}

function jobMarkup(title, progress) {
  const pct = Number.isFinite(progress?.percent) ? progress.percent : null;
  return `<div class="sy-job-card" aria-busy="true">
      <div class="sy-job-head"><span class="sy-run-badge spin sm" data-tone="info">${icon('sync')}</span><b>${esc(title)}</b>${pill('info', 'En cours', { size: 'sm', pulse: true })}</div>
      <div class="sy-meter${pct === null ? ' indeterminate' : ''}"><span data-fill="${pct === null ? '0.35' : (pct / 100).toFixed(3)}"></span></div>
      <p aria-live="polite">${esc(progress?.text ?? 'Préparation…')}</p>
    </div>`;
}

function checkResultMarkup(r) {
  const chips = r.counts.map((c) => {
    const s = STATUS[c.status] ?? STATUS.notSeen;
    return `<li data-tone="${s.tone}">${glyph(s.icon)}<b>${int(c.count)}</b><span>${esc(s.label)}</span></li>`;
  }).join('');
  const rows = r.rows.slice(0, 40).map((x, n) => {
    const s = STATUS[x.status] ?? STATUS.notSeen;
    return `<li data-tone="${s.tone}" data-i="${Math.min(n, 18)}"><span class="sy-res-ico">${glyph(s.icon)}</span><div><b>${esc(x.name)}</b>${pill(s.tone, s.label, { size: 'sm' })}<p>${esc(x.text)}</p>${x.proof ? `<small>${esc(x.proof)}</small>` : ''}</div></li>`;
  }).join('');
  return `<div class="sy-result-card">
      <div class="sy-job-head"><span class="sy-run-badge pop sm" data-tone="ok">${glyph('check')}</span><b>${esc(r.summary)}</b></div>
      <ul class="sy-res-chips">${chips}</ul>
      <p class="sy-muted">${icon('shield')}<span>${esc(r.deletedProbeText)} Contrôleur${NBSP}: ${esc(r.server)}.</span></p>
      <details class="sy-res-details"><summary>${glyph('eye')}Détail des ${int(r.checked)} vérifications</summary><ul class="sy-res-list">${rows}</ul></details>
      <div class="sy-card-actions">${button('Ignorer', { ghost: true, sm: true, data: { ct: 'dismiss-check' } })}${button('Enregistrer les résultats…', { icon: 'database', primary: true, kind: 'write', data: { ct: 'store-check' } })}</div>
    </div>`;
}

function gapResultMarkup(r) {
  const rows = r.rows.slice(0, 30).map((x, n) => `<li data-tone="${toneOf(x.tone)}" data-i="${Math.min(n, 18)}"><span class="sy-res-ico">${glyph(x.status === 'visible' ? 'plus' : x.status === 'notFound' ? 'eyeOff' : 'clock')}</span><div><b>${esc(x.name || x.guid)}</b>${pill(toneOf(x.tone), x.label, { size: 'sm' })}<p>${esc(x.text)}</p></div></li>`).join('');
  return `<div class="sy-result-card">
      <div class="sy-job-head"><span class="sy-run-badge pop sm" data-tone="ok">${glyph('check')}</span><b>${esc(r.summary)}</b></div>
      <ul class="sy-res-chips"><li data-tone="ok">${glyph('plus')}<b>${int(r.added)}</b><span>À ajouter</span></li><li data-tone="off">${glyph('eyeOff')}<b>${int(r.gone)}</b><span>Plus visibles</span></li><li data-tone="warn">${glyph('clock')}<b>${int(r.unread)}</b><span>Non lus</span></li></ul>
      <details class="sy-res-details"><summary>${glyph('eye')}Détail des ${int(r.asked)} lectures</summary><ul class="sy-res-list">${rows}</ul></details>
      <div class="sy-card-actions">${button('Ignorer', { ghost: true, sm: true, data: { ct: 'dismiss-gaps' } })}${button('Ajouter à la base…', { icon: 'database', primary: true, kind: 'write', data: { ct: 'store-gaps' }, disabled: !r.storable })}</div>
    </div>`;
}

const COLUMNS = [
  { id: 'status', label: 'État', type: 'enum', width: 180, options: Object.entries(STATUS).map(([value, s]) => ({ value, label: s.label, tone: s.tone })) },
  { id: 'name', label: 'Nom', required: true, width: 172 },
  { id: 'typeLabel', label: 'Type', width: 104, html: (v, r) => `<span class="sy-type">${glyph(typeGlyph(r.type))}${esc(v)}</span>` },
  { id: 'location', label: 'Dernier emplacement', width: 200, tip: 'Dernier emplacement connu dans la base locale' },
  { id: 'noticedAt', label: 'Non revu le', type: 'date', dateStyle: 'datetime', width: 138 },
  { id: 'checkedAt', label: 'Vérifié le', type: 'date', dateStyle: 'datetime', width: 138, hidden: true },
  { id: 'detail', label: 'Détail', width: 280 },
  { id: 'lastDn', label: 'Dernier DN', mono: true, hidden: true, width: 380 },
  { id: 'foundDn', label: 'Nouveau DN', mono: true, hidden: true, width: 380 },
  { id: 'guid', label: 'GUID', mono: true, hidden: true, width: 300 },
];

/** Renders the workspace in its panel; returns its cleanup. */
export function renderControls(panel, screen) {
  const ctx = screen.ctx;
  panel.classList.add('sy-ws', 'sy-ws-controls');
  const answers = latest();
  let data = null;
  let filter = null;
  let wide = false;
  let check = null;
  let gaps = null;
  let alive = true;
  let unsub = () => {};
  let asked = false;
  panel.innerHTML = `<div class="sy-ws-grid">
      <section class="sy-card span-6" data-slot="census" data-i="0">${cardHead('shield', 'Recensement du périmètre', 'Conseil de lecture complète, jamais lancée seule')}<div class="sy-slot">${skStack('sk-line w70', 'sk-line w85', 'sk-line w55')}</div></section>
      <section class="sy-card span-6" data-slot="gaps" data-i="1">${cardHead('users', 'Objets recensés absents de la base', 'Dernier recensement du domaine')}<div class="sy-slot">${skStack('sk-line w85', 'sk-line w55')}</div></section>
      <section class="sy-card span-12" data-slot="absences" data-i="2">
        ${cardHead('eyeOff', 'Objets disparus', 'Non revus par une lecture complète\u00A0: retirés de la copie, jamais déclarés supprimés',
          `${button('Actualiser la liste', { sm: true, ghost: true, icon: 'refresh', data: { ct: 'reload' }, tip: 'Relit la liste dans la base locale\u00A0; aucune lecture de l’annuaire.' })}${button('Vérifier les disparitions…', { sm: true, icon: 'eye', kind: 'network', data: { ct: 'check' } })}`)}
        <div class="sy-abs-top"></div>
        <div class="sy-job" data-job="check" hidden></div>
        <div class="sy-abs-grid"></div>
      </section>
    </div>`;
  const grid = createGrid(panel.querySelector('.sy-abs-grid'), {
    key: 'synchro.absences.v3',
    label: 'Objets disparus',
    rowId: (r) => r.guid,
    selection: 'single',
    loading: true,
    height: '360px',
    columns: COLUMNS,
    empty: { icon: 'check', title: 'Aucune disparition', text: 'Un objet qu’une lecture complète ne retrouve plus apparaîtra ici au lieu d’être déclaré supprimé.' },
    onActivate: (row) => { if (row.foundDn) ctx.navigate('fiche', { dn: row.foundDn }); },
    contextMenu: ({ row }) => [{ label: 'Ouvrir la fiche (nouvel emplacement)', icon: 'object', disabled: !row?.foundDn, reason: 'Objet non retrouvé dans l’annuaire.', run: () => ctx.navigate('fiche', { dn: row.foundDn }) }],
  });

  const slot = (name) => panel.querySelector(`[data-slot="${name}"] .sy-slot`);

  /** Rows of the list: the scope of the screen (last seen inside it) or the whole domain. */
  const rowsShown = () => (wide || data.scope.isDomain ? data.absences.rows : data.absences.rows.filter((r) => r.inScope));

  function paintAbsences() {
    const a = data.absences;
    const rows = rowsShown();
    if (filter && !rows.some((r) => r.status === filter)) filter = null;
    const top = panel.querySelector('.sy-abs-top');
    // The engine summarizes the domain; the scope view says what it shows and how many remain elsewhere.
    const summary = data.scope.isDomain || wide
      ? a.summary
      : `${count(rows.length, 'objet vu', 'objets vus')} pour la dernière fois dans ${data.scope.label}, sur ${count(a.total, 'disparition', 'disparitions')} du domaine${NBSP}; la vérification relit les ${count(a.pending, 'objet', 'objets')} non revus ou non confirmés du domaine.`;
    top.innerHTML = `<div class="sy-abs-bar">${scopeToggle(data.scope, a, wide)}${facetsMarkup(rows, filter)}</div>
      <p class="sy-abs-summary">${esc(summary)}</p>`;
    const shown = filter ? rows.filter((r) => r.status === filter) : rows;
    grid.setRows(shown);
    fitGrid(grid, shown.length, { min: 4, max: 10 });
    grid.setEmpty(rows.length === 0 && a.total > 0
      ? { icon: 'check', title: 'Aucune disparition dans ce périmètre', text: `Les ${count(a.total, 'disparition', 'disparitions')} du domaine sont ailleurs${NBSP}: «${NBSP}Tout le domaine${NBSP}» les montre.` }
      : null);
  }

  function paintAll() {
    if (!data) return;
    const o = screen.overview;
    slot('census').innerHTML = censusMarkup(data.census, data.scope, o?.readiness?.ready !== false, o?.readiness?.reason ?? '', o);
    slot('gaps').innerHTML = gapsMarkup(data.gaps);
    if (gaps) showGapResult(gaps);
    const checkBtn = panel.querySelector('[data-ct="check"]');
    if (checkBtn) {
      checkBtn.disabled = !data.absences.canCheck;
      checkBtn.dataset.tip = data.absences.canCheck ? `Relit par leur GUID, après confirmation, jusqu’à 200 objets non revus du domaine${NBSP}: dans le domaine, puis parmi les objets supprimés. Rien n’est modifié dans l’annuaire.` : 'Aucun objet à vérifier.';
    }
    paintAbsences();
    paint(panel);
  }

  async function load() {
    const my = answers.next();
    try {
      const next = await ctx.call('synchro.controls', screen.scopeArgs());
      // An answer of an older request or of an older generation of the base never repaints a newer list.
      if (!alive || !answers.keep(my, next.generation)) return;
      data = next;
      paintAll();
      if (asked) { asked = false; runCheck(); }
    } catch (err) {
      console.error(err);
      if (!alive || !answers.keep(my)) return;
      for (const name of ['census', 'gaps']) slot(name).innerHTML = errorBlock(err);
      grid.setError(errorText(err), { retry: load });
    }
  }

  function job(name, title) {
    const host = panel.querySelector(`[data-job="${name}"]`);
    host.hidden = false;
    host.innerHTML = jobMarkup(title, null);
    paint(host);
    return (p) => {
      if (!host.isConnected) return;
      host.innerHTML = jobMarkup(title, p);
      paint(host);
    };
  }

  async function runCheck() {
    if (!data?.absences.canCheck) return;
    const n = Math.min(200, data.absences.pending);
    const ok = await confirmDialog({
      title: 'Vérifier les disparitions',
      message: `${count(n, 'objet non revu sera relu', 'objets non revus seront relus')} par leur GUID dans le domaine, puis parmi les objets supprimés visibles par ce compte. Lecture seule${NBSP}: rien n’est modifié dans l’annuaire. Le résultat attend votre confirmation pour être enregistré${NBSP}; une suppression n’est retenue qu’avec sa preuve.`,
      confirmLabel: 'Lancer la vérification',
      icon: 'eye',
    });
    if (!ok || !alive) return;
    const update = job('check', 'Vérification des disparitions');
    unsub();
    unsub = onEvent('synchro.absences.check:progress', (p) => update(p));
    try {
      check = await ctx.call('synchro.absences.check', {});
      unsub();
      if (!alive) return;
      const host = panel.querySelector('[data-job="check"]');
      host.innerHTML = checkResultMarkup(check);
      paint(host);
    } catch (err) {
      unsub();
      console.error(err);
      const host = panel.querySelector('[data-job="check"]');
      host.innerHTML = errorBlock(err, false);
    }
  }

  async function runGaps() {
    if (!data?.gaps.canRead) return;
    const n = Math.min(200, data.gaps.total);
    const ok = await confirmDialog({
      title: 'Lire les objets manquants',
      message: `${count(n, 'objet recensé mais absent', 'objets recensés mais absents')} de la base locale ${n > 1 ? 'seront lus' : 'sera lu'} par leur GUID dans le domaine (attributs de la base autonome seulement). Lecture seule${NBSP}: rien n’est modifié dans l’annuaire. Un objet lu pourra être ajouté à la base après votre confirmation${NBSP}; un objet que la lecture ne renvoie plus quitte la liste, sans conclusion.`,
      confirmLabel: 'Lancer la lecture',
      icon: 'download',
    });
    if (!ok || !alive) return;
    const update = job('gaps', 'Lecture des objets manquants');
    unsub();
    unsub = onEvent('synchro.gaps.read:progress', (p) => update(p));
    try {
      gaps = await ctx.call('synchro.gaps.read', {});
      unsub();
      if (!alive) return;
      showGapResult(gaps);
    } catch (err) {
      unsub();
      console.error(err);
      const host = panel.querySelector('[data-job="gaps"]');
      host.innerHTML = errorBlock(err, false);
    }
  }

  function showGapResult(r) {
    const host = panel.querySelector('[data-job="gaps"]');
    if (!host) return;
    host.hidden = false;
    host.innerHTML = gapResultMarkup(r);
    paint(host);
  }

  function store(batchId, kind) {
    runWrite(ctx, {
      plan: 'synchro.store.plan',
      args: { batchId },
      subtitle: kind === 'gaps' ? 'Base locale · objets manquants' : 'Base locale · disparitions',
      onDone: () => {
        if (kind === 'gaps') gaps = null; else check = null;
        const host = panel.querySelector(`[data-job="${kind === 'gaps' ? 'gaps' : 'check'}"]`);
        if (host) { host.hidden = true; host.innerHTML = ''; }
        screen.emit('stored', { kind });
        load();
      },
    });
  }

  /** « Ignorer »: the engine drops the kept result too (it is no longer offered for storage). */
  function dismiss(kind) {
    const kept = kind === 'gaps' ? gaps : check;
    if (kind === 'gaps') gaps = null; else check = null;
    const h = panel.querySelector(`[data-job="${kind}"]`);
    h.hidden = true;
    h.innerHTML = '';
    if (kept?.batchId) ctx.call('synchro.read.discard', { batchId: kept.batchId }).catch((err) => console.error(err));
  }

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-ct], [data-facet], [data-abs], [data-retry]') : null;
    if (!t || t.disabled) return;
    if (t.dataset.retry !== undefined) { load(); return; }
    if (t.dataset.facet) {
      filter = filter === t.dataset.facet ? null : t.dataset.facet;
      paintAbsences();
      paint(panel.querySelector('.sy-abs-top'));
      return;
    }
    if (t.dataset.abs) {
      wide = t.dataset.abs === 'domain';
      filter = null;
      paintAbsences();
      paint(panel.querySelector('.sy-abs-top'));
      return;
    }
    const act = t.dataset.ct;
    if (act === 'reload') load();
    else if (act === 'check') runCheck();
    else if (act === 'gaps') runGaps();
    else if (act === 'read') screen.startRead('ou');
    else if (act === 'choose') screen.chooseScope({ read: true });
    else if (act === 'store-check' && check) store(check.batchId, 'absences');
    else if (act === 'store-gaps' && gaps) store(gaps.batchId, 'gaps');
    else if (act === 'dismiss-check') dismiss('check');
    else if (act === 'dismiss-gaps') dismiss('gaps');
  };
  panel.addEventListener('click', onClick);
  const offScope = screen.on('scope', () => { wide = false; filter = null; load(); });
  const offStored = screen.on('stored', (r) => { if (!r?.kind) load(); });
  const offAsk = screen.on('ask', (what) => { if (what !== 'check') return; if (data) runCheck(); else asked = true; });
  load();

  return () => {
    alive = false;
    unsub();
    offScope();
    offStored();
    offAsk();
    panel.removeEventListener('click', onClick);
    grid.destroy();
  };
}
