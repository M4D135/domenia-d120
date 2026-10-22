// Side panels of the workshop: coverage and dates of the sources, collection plan of the missing measures, export ready
// to copy or save, complete distribution, OU of the workshop. Every network read waits for an explicit confirmation.
import {
  esc, glyph, plural, num, dateText, vars, emptyState, NBSP, skLines, ago, TARGETS, key,
} from './shared.js';
import { openDrawer, confirmDialog, createTree, writeClipboard } from '../../kit/index.js';
import { formatNumber } from '../../ui.js';

function bar(part, total, tone) {
  const w = total > 0 ? Math.round((1000 * part) / total) / 10 : 0;
  return `<span class="rq-mini" data-tone="${tone}"><span class="rq-mini-fill" data-w="${w}"></span></span>`;
}

/** « Vérifier les informations disponibles »: coverage, clocks of the sources and proposed window (no collection). */
export async function openCoverage(store, { onApply, onPlan } = {}) {
  const panel = openDrawer({
    title: 'Couverture et dates des informations',
    subtitle: 'Calcul local, aucune collecte',
    icon: 'gauge',
    key: 'requetes.coverage',
    width: 760,
    body: `<div class="rq-dr">${skLines(40, 90, 70, 85, 60)}</div>`,
    actions: [{ id: 'close', label: 'Fermer', run: (p) => p.close() }],
  });
  panel.setBusy(true);
  const res = await store.call('requetes.coverage', { recipe: store.recipe });
  panel.setBusy(false);
  if (!store.alive) return;
  const body = panel.body.querySelector('.rq-dr');
  if (res.error) { body.innerHTML = emptyState('alert', 'Couverture indisponible', res.message); return; }
  const c = res.data;
  const rows = c.rows.map((r, n) => {
    const total = c.total || 1;
    return `<tr data-i="${n}"><th scope="row">${esc(r.name)}<small>${esc(r.source)}</small></th>
      <td>${num(r.available)}${bar(r.available, total, 'ok')}</td><td>${num(r.expired)}</td><td>${num(r.error)}</td><td>${num(r.partial)}</td><td>${num(r.unread)}</td></tr>`;
  }).join('');
  const times = c.sources.filter((s) => s.oldest).map((s) => [Date.parse(s.oldest), Date.parse(s.newest)]).flat();
  const min = Math.min(...times);
  const max = Math.max(...times, min + 1);
  const span = Math.max(1, max - min);
  const frise = c.sources.map((s, n) => {
    const a = s.oldest ? ((Date.parse(s.oldest) - min) / span) * 100 : 0;
    const b = s.newest ? ((Date.parse(s.newest) - min) / span) * 100 : 0;
    return `<div class="rq-frise-row" data-i="${n}"><span class="rq-frise-label">${esc(s.source)}${s.volatile ? `<em>instantanée</em>` : ''}</span>
      <span class="rq-frise-track">${s.oldest ? `<span class="rq-frise-seg" data-x="${a.toFixed(1)}" data-w="${Math.max(1.2, b - a).toFixed(1)}" data-tip="${esc(`${dateText(s.oldest)} → ${dateText(s.newest)}`)}"></span>` : '<span class="rq-frise-none">Aucune date</span>'}</span>
      <span class="rq-frise-count">${plural(s.dated, 'daté', 'datés')} · ${plural(s.missing, 'sans date', 'sans date')}</span></div>`;
  }).join('');
  const proposal = c.proposal;
  const same = proposal.hours !== null && Number(store.recipe.coherenceHours) === Number(proposal.hours);
  body.innerHTML = `
    <div class="rq-cov-kpis">
      <div class="rq-cov-kpi"><b>${num(c.total)}</b><span>objets examinés</span></div>
      <div class="rq-cov-kpi ok"><b>${num(c.complete)}</b><span>avec toutes les informations</span></div>
      <div class="rq-cov-kpi warn"><b>${num(c.incomplete)}</b><span>incomplets</span></div>
      <div class="rq-cov-kpi info"><b>${num(c.mixedPeriod)}</b><span>dates écartées de plus de ${esc(String(c.coherenceHours))}${NBSP}h</span></div>
    </div>
    <h3 class="rq-dr-h">Disponibilité de chaque information</h3>
    ${c.rows.length ? `<div class="rq-table-wrap"><table class="table rq-table"><thead><tr><th>Information</th><th>Disponible</th><th>Expirée</th><th>Erreur</th><th>Incomplète</th><th>Non lue</th></tr></thead><tbody>${rows}</tbody></table></div>`
      : '<p class="rq-note">La requête n’utilise aucune information : rien à couvrir.</p>'}
    <h3 class="rq-dr-h">Dates de chaque source</h3>
    ${c.sources.length ? `<div class="rq-frise">${frise}${times.length ? `<div class="rq-frise-axis"><span>${esc(dateText(new Date(min).toISOString()))}</span><span>${esc(dateText(new Date(max).toISOString()))}</span></div>` : ''}</div>` : '<p class="rq-note">Aucune source datée.</p>'}
    <div class="rq-proposal ${proposal.needed ? 'needed' : ''}">${glyph(proposal.needed ? 'clock' : 'check')}<div><b>${proposal.needed ? 'Fenêtre commune' : 'Une seule période'}</b><p>${esc(proposal.text)}</p></div>
      ${proposal.hours ? `<button type="button" class="btn sm primary rq-apply-window"${same ? ' disabled' : ''}>Appliquer la fenêtre proposée au brouillon</button>` : ''}</div>
    <p class="rq-note">Fenêtre comparée : ${esc(c.windowSource === 'Recette' ? 'celle de la requête' : 'référence de 24 h (la requête n’en fixe pas)')}. Un ping ne rajeunit jamais l’inventaire ni une sonde : chaque canal garde sa date.</p>
    ${onPlan ? `<div class="rq-dr-actions"><button type="button" class="btn sm subtle rq-open-plan">${glyph('wifi')}Collecter seulement les données manquantes…</button></div>` : ''}`;
  vars(body);
  body.querySelectorAll('[data-x]').forEach((el) => el.style.setProperty('--x', `${el.dataset.x}%`));
  body.querySelector('.rq-apply-window')?.addEventListener('click', () => { onApply?.(proposal.hours); panel.close(); });
  body.querySelector('.rq-open-plan')?.addEventListener('click', () => { panel.close(); onPlan?.(); });
}

/** Reuse windows of the measures already read (Domenia 1 « fenêtres de réutilisation »): cache minutes and age in days. */
const REUSE = [
  { id: 'none', label: 'Toujours relire', cache: 0, days: 0 },
  { id: '15m', label: 'Moins de 15 minutes', cache: 15, days: 0 },
  { id: '1h', label: 'Moins d’une heure', cache: 60, days: 0 },
  { id: '4h', label: 'Moins de 4 heures', cache: 240, days: 0 },
  { id: '1d', label: 'Moins d’un jour', cache: 1440, days: 0 },
  { id: '7d', label: 'Moins de 7 jours', cache: 1440, days: 7 },
  { id: '30d', label: 'Moins de 30 jours', cache: 1440, days: 30 },
];

/** « Collecter seulement les données manquantes »: local plan, then the confirmed read of exactly that plan. */
export async function openPlan(store, { onDone, intro = null } = {}) {
  let reuse = '15m';
  let token = 0;
  const panel = openDrawer({
    title: 'Plan de collecte des informations manquantes',
    subtitle: 'Préparé localement · rien n’est lu avant votre confirmation',
    icon: 'wifi',
    key: 'requetes.plan',
    width: 680,
    body: `<div class="rq-dr">${intro ? `<p class="rq-plan-intro">${glyph('sparkles')}<span>${esc(intro)}</span></p>` : ''}<label class="rq-reuse"><span>Réutiliser les mesures déjà relevées</span><span class="k-select sm"><select class="input rq-reuse-select" aria-label="Fenêtre de réutilisation des mesures">
      ${REUSE.map((r) => `<option value="${r.id}"${r.id === reuse ? ' selected' : ''}>${esc(r.label)}</option>`).join('')}</select></span></label>
      <div class="rq-plan-body">${skLines(50, 80, 65, 90)}</div></div>`,
    actions: [{ id: 'close', label: 'Fermer', run: (p) => p.close() }],
  });
  const body = panel.body.querySelector('.rq-plan-body');
  panel.body.querySelector('.rq-reuse-select').addEventListener('change', (e) => { reuse = e.target.value; load(); });

  async function load() {
    const my = ++token;
    const win = REUSE.find((r) => r.id === reuse) ?? REUSE[1];
    panel.setBusy(true);
    body.setAttribute('aria-busy', 'true');
    const res = await store.call('requetes.collect.plan', { recipe: store.recipe, cacheMinutes: win.cache, reuseDays: win.days });
    panel.setBusy(false);
    body.removeAttribute('aria-busy');
    if (!store.alive || my !== token) return;
    if (res.error) { body.innerHTML = emptyState(res.error.code === 'query.collectRefused' ? 'database' : 'alert', 'Rien à collecter', res.message); return; }
    render(res.data);
  }

  function render({ plan, ticket }) {
    const w = plan.workload;
    const tone = { Faible: 'ok', 'Modéré': 'warn', 'Élevé': 'alert' }[w.level] ?? 'info';
    body.innerHTML = `
      <div class="rq-plan-head">
        <div class="rq-plan-big"><b>${num(plan.targets.length)}</b><span>${plan.targets.length > 1 ? 'postes à relire' : 'poste à relire'}</span></div>
        <div class="rq-plan-facts">
          <span class="k-pill ${tone}">${glyph('gauge')}Coût ${esc(w.level.toLowerCase())}</span>
          <span class="k-pill off">${plural(plan.total, 'examiné', 'examinés')}</span>
          <span class="k-pill ok">${plural(plan.reused, 'déjà à jour', 'déjà à jour')}</span>
          ${plan.disabled ? `<span class="k-pill off">${plural(plan.disabled, 'désactivé exclu', 'désactivés exclus')}</span>` : ''}
          ${plan.ping ? '<span class="k-pill info">Ping</span>' : ''}${plan.inventory ? '<span class="k-pill info">Inventaire</span>' : ''}${plan.console ? '<span class="k-pill info">Console</span>' : ''}
          ${plan.probeIds.length ? `<span class="k-pill info">${plural(plan.probeIds.length, 'sonde', 'sondes')}</span>` : ''}
          ${plan.detail ? `<span class="k-pill info" data-tip="${esc(plan.detail.canonicalQuery)}">SELECT ${esc(plan.detail.className)}</span>` : ''}
        </div>
      </div>
      <ul class="rq-plan-lines">${plan.text.split('\n').map((l) => `<li>${esc(l)}</li>`).join('')}</ul>
      ${plan.fieldCounts.length ? `<h3 class="rq-dr-h">Informations les plus manquantes</h3><ul class="rq-plan-fields">${plan.fieldCounts.slice(0, 8).map((f, n) => `<li data-i="${n}"><span>${esc(f.name)}</span><b>${num(f.missing)}</b>${bar(f.missing, plan.targets.length, 'warn')}</li>`).join('')}</ul>` : ''}
      <p class="rq-note">${glyph('shield')}Lecture seule, bornée à l’OU du périmètre ; chaque poste ne relit que ses mesures manquantes ou plus anciennes que la fenêtre choisie. Le plan est figé : exactement ces postes et ces mesures seront lus, une seule fois.</p>
      <div class="rq-dr-actions"><button type="button" class="btn primary rq-run-plan"${plan.targets.length ? '' : ' disabled'}>${glyph('play')}Lancer le relevé de ${plural(plan.targets.length, 'poste', 'postes')}…</button></div>`;
    vars(body);
    body.querySelector('.rq-run-plan')?.addEventListener('click', async (e) => {
      const ok = await confirmDialog({
        title: 'Lancer le relevé ?',
        message: `${plural(plan.targets.length, 'poste sera contacté', 'postes seront contactés')} en lecture seule (coût ${w.level.toLowerCase()}). Rien n’est écrit sur les postes ni dans l’annuaire.`,
        confirmLabel: 'Lancer le relevé',
        icon: 'wifi',
      });
      if (!ok) return;
      const btn = e.target.closest('button');
      btn.disabled = true;
      btn.innerHTML = '<span class="k-spin" aria-hidden="true"></span>Relevé en cours…';
      body.setAttribute('aria-busy', 'true');
      const run = await store.call('requetes.collect.run', { ticket });
      body.removeAttribute('aria-busy');
      if (!store.alive) return;
      if (run.error) { store.toast(run.message, 'warn'); btn.innerHTML = 'Plan dépensé : préparez-le de nouveau'; return; }
      store.toast(run.data.text, run.data.result?.failed ? 'warn' : 'ok');
      panel.close();
      onDone?.();
    });
  }

  load();
}

/**
 * Export ready (prepared by the engine, kept under a token): preview, facts, save into the Exports folder of the Domenia data
 * (with its metadata), or copy the whole content. The page never writes a file itself.
 */
export function openExport(store, result, { title = 'Export prêt', onSaved } = {}) {
  const preview = result.preview ?? result.content ?? '';
  const metadata = result.kind === 'results';
  const panel = openDrawer({
    title,
    subtitle: result.fileName,
    icon: 'download',
    key: 'requetes.export',
    width: 720,
    body: `<div class="rq-dr">
      <p class="rq-export-text">${esc(result.text ?? '')}</p>
      ${result.recomputed ? `<p class="rq-export-warn">${glyph('alert')}<span>${esc(result.recomputed)}</span></p>` : ''}
      <div class="rq-export-facts">${result.rows !== undefined && result.kind !== 'script' ? `<span class="k-pill info">${plural(result.rows, result.kind === 'pack' ? 'requête' : 'ligne', result.kind === 'pack' ? 'requêtes' : 'lignes')}</span>` : ''}
        ${result.bytes !== undefined ? `<span class="k-pill off">${esc(sizeText(result.bytes))}</span>` : ''}
        ${result.sha256 ? `<span class="k-pill off rq-mono">SHA-256 ${esc(result.sha256.slice(0, 16))}…</span>` : ''}
        ${metadata ? `<span class="k-pill ${result.secretsMasked ? 'warn' : 'ok'}">${glyph('lock')}${result.secretsMasked ? plural(result.secretsMasked, 'valeur secrète masquée', 'valeurs secrètes masquées') : 'Aucune valeur secrète'}</span>` : ''}</div>
      <pre class="rq-code">${esc(preview)}${result.truncated ? '\n…' : ''}</pre>
      ${result.truncated ? `<p class="rq-note">${glyph('info')}Extrait des ${num(6000)} premiers caractères : le fichier enregistré et la copie contiennent tout.</p>` : ''}
      ${metadata ? `<label class="rq-check rq-exp-meta"><input type="checkbox" class="k-checkbox" checked><span><b>Enregistrer aussi les métadonnées</b><small>${esc(result.metadataFileName ?? '')} : population, définition, dates des sources, empreinte</small></span></label>` : ''}
      <div class="rq-dr-actions">
        <button type="button" class="btn primary rq-exp-save">${glyph('download')}Enregistrer dans Exports</button>
        <button type="button" class="btn subtle rq-exp-copy">${glyph('copy')}Copier le contenu</button>
      </div>
      <p class="rq-note rq-exp-where">${glyph('folder')}Dossier : %LOCALAPPDATA%\\Domenia\\Exports (UTF-8 ; « ; » pour les CSV ; formules neutralisées ; nombre de lignes revérifié à l’écriture).</p>
    </div>`,
    actions: [{ id: 'close', label: 'Fermer', run: (p) => p.close() }],
  });
  const body = panel.body;
  body.querySelector('.rq-exp-save').addEventListener('click', async (e) => {
    const btn = e.currentTarget;
    btn.disabled = true;
    const withMeta = body.querySelector('.rq-exp-meta input')?.checked ?? false;
    const res = await store.call('requetes.export.save', { token: result.token, metadata: withMeta });
    if (res.error) { btn.disabled = false; store.toast(res.message, 'warn'); return; }
    const saved = res.data.saved;
    body.querySelector('.rq-exp-where').innerHTML = `${glyph('check')}Enregistré : <span class="rq-mono">${esc(saved.path)}</span>${saved.metadataPath ? ` et <span class="rq-mono">${esc(saved.metadataPath.split('\\').pop())}</span>` : ''}`;
    body.querySelector('.rq-exp-where').classList.add('ok');
    btn.innerHTML = `${glyph('check')}Enregistré`;
    store.toast(`Fichier enregistré (${saved.fileName}).`, 'ok');
    onSaved?.(res.data);
  });
  body.querySelector('.rq-exp-copy').addEventListener('click', async () => {
    let text = result.content;
    if (typeof text !== 'string') {
      const res = await store.call('requetes.export.content', { token: result.token });
      if (res.error) { store.toast(res.message, 'warn'); return; }
      text = res.data.content;
    }
    await writeClipboard(text);
    store.toast('Contenu copié dans le presse-papiers.', 'ok');
  });
}

function sizeText(bytes) {
  if (bytes < 1024) return `${num(bytes)}${NBSP}o`;
  if (bytes < 1024 * 1024) return `${formatNumber(bytes / 1024, 1)}${NBSP}Kio`;
  return `${formatNumber(bytes / (1024 * 1024), 1)}${NBSP}Mio`;
}

/** Complete distribution, filterable, by pages of 100; « Afficher ces postes » makes a segment of one value. */
export async function openGroups(store, evaluationId, { onShow } = {}) {
  let offset = 0;
  let text = '';
  const panel = openDrawer({
    title: 'Répartition complète',
    subtitle: 'Toutes les valeurs, exactes',
    icon: 'columns',
    key: 'requetes.groups',
    width: 720,
    body: `<div class="rq-dr"><label class="rq-search">${glyph('search')}<input type="search" class="input sm" maxlength="256" placeholder="Filtrer les valeurs…" aria-label="Filtrer les valeurs"></label>
      <div class="rq-groups-host">${skLines(90, 80, 70, 60)}</div>
      <div class="rq-pager"><button type="button" class="btn xs subtle rq-prev">${glyph('chevronLeft')}Valeurs précédentes</button><span class="rq-pager-text"></span><button type="button" class="btn xs subtle rq-next">Valeurs suivantes${glyph('chevronRight')}</button></div></div>`,
    actions: [{ id: 'close', label: 'Fermer', run: (p) => p.close() }],
  });
  const body = panel.body;
  const host = body.querySelector('.rq-groups-host');
  async function load() {
    host.setAttribute('aria-busy', 'true');
    const res = await store.call('requetes.preview.groups', { evaluationId, text: text || null, offset, limit: 100 });
    host.removeAttribute('aria-busy');
    if (!store.alive) return;
    if (res.error) { host.innerHTML = emptyState('alert', 'Répartition indisponible', res.message); return; }
    const { page, fieldName } = res.data;
    panel.setTitle('Répartition complète', `${fieldName} · ${plural(page.categoryCount, 'valeur', 'valeurs')} · ${plural(page.matched, 'objet correspondant', 'objets correspondants')}`);
    host.innerHTML = page.rows.length ? `<table class="table rq-table"><thead><tr><th>Rang</th><th>Valeur</th><th>Objets</th><th>Part</th><th></th></tr></thead><tbody>${page.rows.map((r, n) => `<tr data-i="${n}">
      <td>${r.missing ? '—' : num(r.rank)}</td><th scope="row">${esc(r.label)}</th><td>${num(r.count)}</td><td>${formatNumber(r.share, 1)}${NBSP}%${bar(r.count, page.matched, 'info')}</td>
      <td><button type="button" class="btn xs ghost" data-show="${n}">${glyph('eye')}Afficher ces objets</button></td></tr>`).join('')}</tbody></table>` : emptyState('search', 'Aucune valeur', 'Aucune valeur ne contient ce texte.');
    vars(host);
    body.querySelector('.rq-prev').disabled = !page.hasPrevious;
    body.querySelector('.rq-next').disabled = !page.hasNext;
    body.querySelector('.rq-pager-text').textContent = page.filtered ? `${formatNumber(page.offset + 1)} à ${formatNumber(Math.min(page.offset + page.limit, page.filtered))} sur ${formatNumber(page.filtered)}` : '';
    host.querySelectorAll('[data-show]').forEach((b) => b.addEventListener('click', () => {
      const r = page.rows[Number(b.dataset.show)];
      panel.close();
      onShow?.({ label: r.label, missing: r.missing, value: r.value, excluded: [] });
    }));
  }
  let timer = 0;
  body.querySelector('input').addEventListener('input', (e) => { clearTimeout(timer); timer = setTimeout(() => { text = e.target.value.trim(); offset = 0; load(); }, 220); });
  body.querySelector('.rq-prev').addEventListener('click', () => { offset = Math.max(0, offset - 100); load(); });
  body.querySelector('.rq-next').addEventListener('click', () => { offset += 100; load(); });
  load();
}

/** Scope of the workshop: the working OU, or an OU of its own chosen in the tree (remembered per domain). */
export function openScope(store, { onChange } = {}) {
  let chosen = null;
  let subtree = true;
  const scope = store.scope;
  const panel = openDrawer({
    title: 'Périmètre de l’atelier',
    subtitle: scope?.workshop ? `OU propre à l’atelier · ${scope.workshop.label}` : 'Suit l’OU de travail',
    icon: 'ou',
    side: 'left',
    key: 'requetes.scope',
    width: 520,
    body: `<div class="rq-dr rq-scope-dr">
      <p class="rq-note">L’aperçu se calcule localement sur ce périmètre ; la collecte des postes refuse tout le domaine.</p>
      <div class="rq-scope-tree"></div>
      <label class="rq-check"><input type="checkbox" class="k-checkbox rq-scope-sub" checked> Inclure les sous-OU</label>
      <p class="rq-scope-chosen" aria-live="polite">Choisissez une OU dans l’arbre.</p>
    </div>`,
    actions: [
      { id: 'follow', label: 'Suivre l’OU de travail', run: async (p) => { await apply(null); p.close(); } },
      { id: 'domain', label: 'Tout le domaine…', run: async (p) => { if (await wholeDomain()) p.close(); } },
      { id: 'apply', label: 'Choisir cette OU', primary: true, run: async (p) => { if (!chosen) { store.toast('Choisissez une OU dans l’arbre.', 'warn'); return; } await apply(chosen); p.close(); } },
    ],
  });
  /** The whole domain is never picked by a click in the tree (KIT 1.1): an explicit choice, with its limits said first. */
  async function wholeDomain() {
    const ok = await confirmDialog({
      title: 'Consulter tout le domaine ?',
      message: 'L’aperçu se calcule localement sur tous les objets du domaine de la base locale. La collecte des postes reste refusée sur tout le domaine : choisissez une OU pour relever des mesures.',
      confirmLabel: 'Consulter tout le domaine',
      icon: 'alert',
    });
    if (!ok || !rootDn) return false;
    await apply({ dn: rootDn, name: 'Tout le domaine' });
    return true;
  }

  async function apply(node) {
    const res = await store.call('requetes.scope.set', { dn: node?.dn ?? null, subtree });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    store.scope = res.data.scope;
    store.emit('scope', store.scope);
    store.toast(node ? `Périmètre de l’atelier : ${node.name}.` : 'Le périmètre suit l’OU de travail.', 'ok');
    onChange?.();
  }
  let rootDn = null;
  const toNode = (ou) => ({ id: ou.dn, label: ou.name, hint: `${formatNumber(ou.counts.computers)} postes · ${formatNumber(ou.counts.users)} comptes`, leaf: !ou.hasChildren, data: ou });
  const tree = createTree(panel.body.querySelector('.rq-scope-tree'), {
    label: 'Unités d’organisation',
    height: '420px',
    roots: async () => {
      const r = await store.ctx.call('directory.ou.children', { dn: null });
      rootDn = r.parent.dn;
      return [{ id: r.parent.dn, label: r.parent.name, icon: 'domain', hint: 'Domaine : « Tout le domaine… » en bas', selectable: false, children: r.children.map(toNode), data: { dn: r.parent.dn, name: r.parent.name, path: r.parent.path } }];
    },
    load: async (node) => (await store.ctx.call('directory.ou.children', { dn: node.id })).children.map(toNode),
    onSelect: (node) => {
      if (node.data?.dn === rootDn) return;
      chosen = node.data;
      panel.body.querySelector('.rq-scope-chosen').textContent = `OU choisie : ${node.data.path ?? node.data.name}`;
    },
  });
  panel.body.querySelector('.rq-scope-sub').addEventListener('change', (e) => { subtree = e.target.checked; });
  panel.closed.then(() => tree.destroy());
}

/**
 * « Ouvrir » (Domenia 1 « Charger »): the 100 personal recipes revised most recently, filterable without accents, then the
 * whole library. Choosing one loads it into the draft; nothing is read on the network.
 */
export function openRecent(store, { onPick, onLibrary } = {}) {
  let rows = [];
  let text = '';
  const panel = openDrawer({
    title: 'Ouvrir une requête',
    subtitle: 'Les 100 requêtes enregistrées les plus récentes',
    icon: 'history',
    key: 'requetes.recent',
    width: 620,
    body: `<div class="rq-dr"><label class="rq-search">${glyph('search')}<input type="search" class="input" maxlength="120" placeholder="Filtrer par nom ou catégorie…" aria-label="Filtrer les requêtes récentes"></label>
      <ol class="rq-recent" aria-label="Requêtes récentes">${Array.from({ length: 4 }, () => `<li>${skLines(70, 40)}</li>`).join('')}</ol></div>`,
    actions: [
      { id: 'library', label: 'Bibliothèque complète…', run: (p) => { p.close(); onLibrary?.(); } },
      { id: 'close', label: 'Fermer', run: (p) => p.close() },
    ],
  });
  const list = panel.body.querySelector('.rq-recent');
  function paint() {
    const terms = text.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').split(/\s+/).filter(Boolean);
    const shown = rows.filter((r) => terms.every((t) => `${r.name} ${r.category}`.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').includes(t)));
    list.innerHTML = shown.length ? shown.map((r, n) => {
      const target = TARGETS.find((t) => t.id === key(r.target)) ?? TARGETS[0];
      return `<li data-i="${Math.min(n, 18)}"><button type="button" class="rq-recent-item" data-id="${esc(r.id)}">
        <span class="rq-recent-ico">${glyph(target.icon)}</span><span class="rq-recent-main"><b>${esc(r.name)}</b><small>${esc(r.category)} · révision ${esc(String(r.revision))}${r.widgets ? ` · ${plural(r.widgets, 'widget', 'widgets')}` : ''}</small></span>
        <span class="rq-recent-at">${esc(ago(r.updatedAt))}</span></button></li>`;
    }).join('') : `<li class="rq-note">${glyph('info')}${rows.length ? 'Aucune requête récente ne contient ce texte.' : 'Aucune requête enregistrée pour ce domaine : les modèles livrés sont dans la bibliothèque.'}</li>`;
    vars(list);
  }
  list.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-id]') : null;
    if (!b) return;
    const row = rows.find((r) => r.id === b.dataset.id);
    panel.close();
    if (row) onPick?.(row);
  });
  let timer = 0;
  panel.body.querySelector('input').addEventListener('input', (e) => { clearTimeout(timer); timer = setTimeout(() => { text = e.target.value.trim(); paint(); }, 150); });
  (async () => {
    list.setAttribute('aria-busy', 'true');
    const res = await store.call('requetes.library.list', { source: 'personal', sort: 'recent', limit: 100 });
    list.removeAttribute('aria-busy');
    if (!store.alive) return;
    if (res.error) { list.innerHTML = `<li>${emptyState('alert', 'Bibliothèque indisponible', res.message)}</li>`; return; }
    rows = res.data.rows;
    paint();
  })();
}
