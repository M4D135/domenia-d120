// Domenia 2 · Atelier de requêtes (Domenia 1 lot « requetes », REQ-001 to REQ-069). A guided flow « 1. Créer » →
// « 2. Aperçu » → « 3. Enregistrer », and the tools around it: library, catalog of the informations, packs, advanced WMI and
// the cmdlet reference. The draft lives in one store shared by the views; every change is validated by the engine and kept
// as a local draft with the revision it comes from. Reads are local; remote reads (collection, WMI) wait for an explicit
// gesture. Contract: docs/ops/requetes.md. Route parameters: onglet, recette (template or library id), cible, ldap,
// apercu=1, poste, retour (screen to come back to), retourParams (its route parameters) and retourFocus (id of its control).
import {
  esc, glyph, key, plural, TARGETS, createStore, emptyRecipe, formatNumber, ago, vars, dnParts,
} from './requetes/shared.js';
import { mountCompose } from './requetes/compose.js';
import { mountPreview } from './requetes/preview.js';
import { mountSave } from './requetes/save.js';
import { mountLibrary } from './requetes/library.js';
import { mountCatalog } from './requetes/catalog.js';
import { mountShare } from './requetes/share.js';
import { mountWmi } from './requetes/wmi.js';
import { mountReference } from './requetes/reference.js';
import { openCoverage, openPlan, openScope, openRecent } from './requetes/drawers.js';
import { createCommandBar, confirmDialog, debounce } from '../kit/index.js';
import { reveal, inkFollow, announce } from '../ui.js';

export const stylesheet = true;

const FLOW = [
  { id: 'creer', n: 1, label: 'Créer', hint: 'Conditions et filtre LDAP', icon: 'sliders' },
  { id: 'apercu', n: 2, label: 'Aperçu', hint: 'Évaluation locale', icon: 'eye' },
  { id: 'enregistrer', n: 3, label: 'Enregistrer', hint: 'Bibliothèque et widgets', icon: 'star' },
];
const TOOLS = [
  { id: 'bibliotheque', label: 'Bibliothèque', icon: 'database' },
  { id: 'informations', label: 'Informations', icon: 'layers' },
  { id: 'partage', label: 'Partage', icon: 'link' },
  { id: 'wmi', label: 'WMI avancé', icon: 'chip' },
  { id: 'reference', label: 'Référence', icon: 'command' },
];
const ALL = [...FLOW, ...TOOLS].map((t) => t.id);
const RING = '<span class="glow-ring" aria-hidden="true"></span>';
const ORBS = '<div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>';

/** Route parameters of the origin screen, passed as « a=1&b=2 » (2 048 characters at most, plain values only; exported for tests/web). */
export function originParams(raw) {
  if (typeof raw !== 'string' || !raw || raw.length > 2048) return {};
  const out = {};
  for (const pair of raw.split('&')) {
    const at = pair.indexOf('=');
    if (at <= 0) continue;
    try {
      const name = decodeURIComponent(pair.slice(0, at));
      if (/^[a-zA-Z][a-zA-Z0-9]{0,31}$/.test(name)) out[name] = decodeURIComponent(pair.slice(at + 1));
    } catch {
      // A malformed pair is ignored: the screen opens without it.
    }
  }
  return out;
}

/** After going back, gives the focus to the control the origin named (once it is rendered, 2 s at most). */
function restoreFocus(id) {
  if (typeof id !== 'string' || !/^[A-Za-z][\w-]{0,63}$/.test(id)) return;
  const started = performance.now();
  const tick = () => {
    const el = document.getElementById(id);
    if (el && typeof el.focus === 'function') { el.focus(); return; }
    if (performance.now() - started < 2000) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

export function render(main, ctx) {
  const params = ctx.params ?? {};
  const store = createStore(ctx);
  const views = new Map();
  const st = {
    tab: ALL.includes(params.onglet) ? params.onglet : 'creer', ink: null, validateToken: 0, target: key(store.recipe.target),
    compact: Boolean(params.recette || params.ldap || params.onglet || params.apercu), draftAt: null, renaming: false,
  };
  // « retour » names the screen that opened the workshop (Accueil, Recherche, Fiche…): one gesture brings the operator back to
  // that screen, its tab (« retourParams ») and the control that had the focus (« retourFocus »).
  const origin = typeof params.retour === 'string' && params.retour !== 'requetes' ? (ctx.pages ?? []).find((p) => p.id === params.retour) : null;

  main.innerHTML = `<div class="page rq-page">
    <section class="hero rq-hero reveal">${RING}${ORBS}
      <div class="rq-hero-grid">
        <div class="rq-hero-main">
          <div class="eyebrow">${glyph('database')}<span>Atelier de requêtes</span><span class="rq-eyebrow-note">Lecture seule · évaluation locale</span>
            ${origin ? `<button type="button" class="btn xs subtle rq-back">${glyph('chevronLeft')}Revenir à l’écran ${esc(origin.label)}</button>` : ''}</div>
          <div class="rq-title-row">
            <h1 class="rq-title" id="rq-title"><span class="rq-title-text"></span></h1>
            <label class="visually-hidden" for="rq-name">Nom de la requête</label>
            <input id="rq-name" class="rq-title-input" type="text" maxlength="120" autocomplete="off" spellcheck="true" hidden>
            <button type="button" class="btn xs ghost icon rq-rename" aria-label="Renommer la requête" data-tip="Renommer la requête">${glyph('edit')}</button>
          </div>
          <p class="lead rq-lead"></p>
          <div class="rq-hero-row">
            <div class="segmented rq-target" role="radiogroup" aria-label="Cible de la requête"><span class="thumb" aria-hidden="true"></span>
              ${TARGETS.map((t) => `<button type="button" role="radio" data-target="${t.id}" aria-checked="false">${glyph(t.icon)}<span>${esc(t.label)}</span><b class="rq-target-n"></b></button>`).join('')}</div>
            <div class="rq-cmds"></div>
          </div>
          <div class="rq-hero-chips"></div>
        </div>
        <aside class="rq-scope-card" aria-labelledby="rq-scope-k"></aside>
      </div>
    </section>

    <nav class="rq-rail reveal" aria-label="Étapes et outils de l’atelier">
      <div class="rq-flow" role="tablist" aria-label="Étapes">
        <span class="rq-flow-line" aria-hidden="true"><span class="rq-flow-fill"></span></span>
        ${FLOW.map((f) => `<button type="button" role="tab" class="rq-flow-step" id="rq-tab-${f.id}" data-tab="${f.id}" aria-controls="rq-panel-${f.id}" aria-selected="false" tabindex="-1">
          <span class="rq-flow-mark"><span class="rq-flow-num">${f.n}</span>${glyph('check', 'rq-flow-done')}</span><span class="rq-flow-text"><b>${esc(f.label)}</b><small>${esc(f.hint)}</small></span></button>`).join('')}
      </div>
      <div class="rq-tools" role="tablist" aria-label="Outils"><span class="ink" aria-hidden="true"></span>
        ${TOOLS.map((t) => `<button type="button" role="tab" class="rq-tool" id="rq-tab-${t.id}" data-tab="${t.id}" aria-controls="rq-panel-${t.id}" aria-selected="false" tabindex="-1">${glyph(t.icon)}<span>${esc(t.label)}</span></button>`).join('')}
      </div>
    </nav>

    <div class="rq-panels">${ALL.map((id) => `<section class="rq-panel" id="rq-panel-${id}" role="tabpanel" aria-labelledby="rq-tab-${id}" data-panel="${id}" hidden></section>`).join('')}</div>
  </div>`;
  const $ = (sel) => main.querySelector(sel);

  // ---------- Hero: title (the only h1), target, scope, commands ----------

  main.querySelector('.rq-back')?.addEventListener('click', () => {
    const focus = params.retourFocus;
    ctx.navigate(origin.id, originParams(params.retourParams));
    restoreFocus(focus);
  });

  function paintName() {
    const name = store.recipe.name ?? '';
    $('.rq-title-text').textContent = name;
    $('.rq-title').classList.toggle('long', name.length > 42);
    if (!st.renaming) $('#rq-name').value = name;
  }
  function startRename() {
    st.renaming = true;
    const input = $('#rq-name');
    input.value = store.recipe.name ?? '';
    input.hidden = false;
    $('.rq-title').hidden = true;
    $('.rq-rename').hidden = true;
    input.focus();
    input.select();
  }
  function stopRename(commit) {
    if (!st.renaming) return;
    const input = $('#rq-name');
    const name = input.value.trim();
    st.renaming = false;
    input.hidden = true;
    $('.rq-title').hidden = false;
    $('.rq-rename').hidden = false;
    if (commit && name && name !== store.recipe.name) {
      store.setRecipe({ ...store.recipe, name }, { origin: 'name' });
      announce(`Requête renommée : ${name}.`);
    }
    paintName();
  }
  $('.rq-rename').addEventListener('click', startRename);
  $('.rq-title').addEventListener('dblclick', startRename);
  $('#rq-name').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); stopRename(true); $('.rq-rename').focus(); }
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); stopRename(false); $('.rq-rename').focus(); }
  });
  $('#rq-name').addEventListener('blur', () => stopRename(true));

  const targetInk = inkFollow($('.rq-target'), '[data-target]', '[aria-checked="true"]');
  function paintTarget() {
    const t = key(store.recipe.target);
    main.querySelectorAll('[data-target]').forEach((b) => b.setAttribute('aria-checked', String(b.dataset.target === t)));
    targetInk.update();
    main.dataset.target = t;
  }
  main.querySelectorAll('.rq-target [data-target]').forEach((b) => b.addEventListener('click', async () => {
    const t = b.dataset.target;
    if (t === key(store.recipe.target)) return;
    const r = store.recipe;
    const hasConditions = (r.clauses?.length ?? 0) > 0 || !!r.expression;
    if (hasConditions) {
      const ok = await confirmDialog({ title: 'Changer de cible ?', message: `Les critères de « ${r.name} » portent sur une autre cible : un brouillon vide pour les ${TARGETS.find((x) => x.id === t).label.toLowerCase()} les remplace. Enregistrez d’abord la requête pour la garder.`, confirmLabel: 'Changer de cible', icon: 'alert' });
      if (!ok) { paintTarget(); return; }
    }
    setRecipe(emptyRecipe(t), { origin: 'target', saved: null });
  }));

  /** Path of an OU as clickable steps, the domain first (same reading as the OU card of the Accueil). */
  function crumbs(scope, s) {
    if (!scope?.dn) return '';
    const parts = dnParts(scope.dn);
    const domain = parts.filter((p) => p.type === 'DC').map((p) => p.value).join('.') || s.domain?.dnsName || '';
    const steps = [{ name: domain, root: true }, ...parts.filter((p) => p.type !== 'DC').reverse().map((p) => ({ name: p.value }))];
    return `<nav class="rq-crumbs-ou" aria-label="Chemin du périmètre"><ol>${steps.map((c, n) => `<li data-j="${n}">${n === steps.length - 1
      ? `<span class="rq-crumb-ou now" aria-current="location">${esc(c.name)}</span>`
      : `<button type="button" class="rq-crumb-ou" data-act="scope" data-tip="${esc(c.root ? 'Choisir une OU depuis la racine du domaine' : `Choisir une OU depuis ${c.name}`)}">${esc(c.name)}</button>`}</li>`).join('')}</ol></nav>`;
  }

  function paintScope() {
    const s = store.scope;
    const card = $('.rq-scope-card');
    if (!s) {
      card.innerHTML = `<div class="rq-sk"><span class="skeleton rq-skl w40"></span><span class="skeleton rq-skl w70"></span><span class="skeleton rq-skl w85"></span></div>`;
      return;
    }
    const eff = s.effective;
    const counts = s.counts ?? {};
    const b = s.base;
    const read = b ? `${b.source.replace(/ \(aucune lecture réseau\)$/, '')} · lecture ${ago(b.readAt)} · ${plural(b.objects, 'objet', 'objets')}${b.complete ? '' : ' · lecture partielle'}` : 'Base locale non lue : l’aperçu sera vide.';
    card.innerHTML = `<div class="rq-scope-top"><span class="rq-scope-ico">${glyph('ou')}</span><span class="rq-scope-k" id="rq-scope-k">${s.workshop ? 'Périmètre de l’atelier' : 'OU de travail'}</span>
        ${s.wholeDomain ? '<span class="k-pill warn sm">Tout le domaine</span>' : eff && !eff.subtree ? '<span class="k-pill info sm">Cette OU seulement</span>' : '<span class="k-pill info sm">Sous-OU comprises</span>'}</div>
      <div class="rq-scope-name">${esc(eff?.label ?? s.domain?.dnsName ?? 'Domaine')}</div>
      ${crumbs(eff, s)}
      <div class="rq-scope-foot">
        ${s.accountsInDomain ? `<span class="chip sm rq-scope-accounts" data-tip="${esc(`Les comptes et les groupes sont lus dans tout le domaine ${s.domain?.dnsName ?? ''}, sur la base locale ; les postes suivent le périmètre.`)}">${glyph('users')}Comptes et groupes : domaine entier</span>` : ''}
        <span class="rq-scope-note" data-tip="${esc(read)}">${glyph('database')}${esc(read)}</span>
      </div>
      <button type="button" class="btn sm subtle rq-scope-btn" data-act="scope" aria-label="Changer de périmètre" data-tip="Changer de périmètre">${glyph('ou')}<span>Changer de périmètre…</span></button>`;
    vars(card);
    card.querySelectorAll('[data-j]').forEach((el) => el.style.setProperty('--j', el.dataset.j));
    main.querySelectorAll('.rq-target [data-target]').forEach((btn) => {
      const n = counts[btn.dataset.target];
      btn.querySelector('.rq-target-n').textContent = n !== undefined ? formatNumber(n) : '';
    });
  }
  $('.rq-scope-card').addEventListener('click', (e) => {
    if (!(e.target instanceof Element) || !e.target.closest('[data-act="scope"]')) return;
    const card = $('.rq-scope-card');
    openScope(store, { onChange: () => { card.classList.remove('changed'); void card.offsetWidth; card.classList.add('changed'); } });
  });

  async function loadScope() {
    const res = await store.call('requetes.scope', undefined);
    if (!store.alive) return;
    if (res.error) {
      $('.rq-scope-card').innerHTML = `<p class="rq-note">${glyph('alert')}${esc(res.message)}</p>`;
      return;
    }
    store.scope = res.data;
    paintScope();
    store.emit('scope', store.scope);
  }

  /** The hero folds once the operator works on a query: the work area comes first, the onboarding sentence goes. */
  function paintHero() {
    const r = store.recipe;
    const empty = !(r.clauses?.length) && !r.expression && !store.saved;
    if (!empty) st.compact = true;
    const compact = st.compact || !FLOW.some((f) => f.id === st.tab);
    $('.rq-hero').classList.toggle('compact', compact);
    $('.rq-lead').textContent = 'Composez une requête en conditions ou en filtre LDAP, vérifiez-la sur les données locales, puis enregistrez-la ou partagez-la.';
  }

  function paintChips() {
    const v = store.validation;
    const s = store.saved;
    const chips = [];
    if (s?.source === 'template') chips.push(`<span class="chip">${glyph('sparkles')}Modèle livré</span>`);
    else if (s?.source === 'personal') chips.push(`<span class="chip${s.libraryChanged ? ' warn' : ''}" data-tip="${esc(s.libraryChanged ? `La bibliothèque est passée à la révision ${s.libraryChanged} depuis ce brouillon : l’enregistrement demandera de la relire.` : '')}">${glyph('star')}Révision ${esc(String(s.revision))}${s.archived ? ' · archivée' : ''}${s.libraryChanged ? ' · bibliothèque modifiée' : ''}</span>`);
    else chips.push(`<span class="chip">${glyph('edit')}Brouillon</span>`);
    if (st.draftAt) chips.push(`<span class="chip" data-tip="Brouillon de la dernière session, repris tel quel">${glyph('history')}Repris ${esc(ago(st.draftAt))}</span>`);
    if (v?.valid && v.conditionCount) chips.push(`<span class="chip ok">${glyph('check')}${plural(v.conditionCount, 'condition', 'conditions')}</span>`);
    else if (v?.valid) chips.push(`<span class="chip warn" data-tip="Sans condition, tous les objets du périmètre correspondent.">${glyph('info')}Aucune condition : tout le périmètre</span>`);
    else if (v) chips.push(`<span class="chip alert">${glyph('alert')}À corriger</span>`);
    if (v?.ldap) chips.push(`<span class="chip" data-tip="${esc(v.ldap.exact ? 'Le filtre LDAP sélectionne exactement les mêmes correspondants que l’aperçu.' : 'Le filtre LDAP lit les candidats ; les autres conditions sont évaluées localement.')}">${glyph('hash')}${v.ldap.exact ? 'Filtre LDAP exact' : 'LDAP + conditions locales'}</span>`);
    if (store.recipe.coherenceHours) chips.push(`<span class="chip">${glyph('clock')}Cohérence ${esc(String(store.recipe.coherenceHours))}${' '}h</span>`);
    if (store.evaluation) chips.push(`<span class="chip info">${glyph('eye')}Aperçu ${esc(ago(store.evaluation.evaluatedAt))}</span>`);
    $('.rq-hero-chips').innerHTML = chips.map((c, n) => c.replace('<span class="chip', `<span data-j="${n}" class="chip`)).join('');
    main.querySelectorAll('.rq-hero-chips [data-j]').forEach((el) => el.style.setProperty('--j', el.dataset.j));
  }

  const cmdbar = createCommandBar($('.rq-cmds'), {
    label: 'Actions de la requête',
    items: [
      { id: 'preview', label: 'Calculer l’aperçu', icon: 'play', primary: true, kbd: 'Ctrl Entrée', run: () => runPreview() },
      { id: 'new', label: 'Nouvelle requête', icon: 'plus', run: () => newRecipe() },
      { id: 'open', label: 'Ouvrir…', icon: 'history', kbd: 'Ctrl O', run: () => openRecentDrawer() },
      { id: 'save', label: 'Enregistrer', icon: 'star', kbd: 'Ctrl S', run: () => goto('enregistrer') },
      { id: 'library', label: 'Bibliothèque complète', icon: 'database', overflow: true, run: () => goto('bibliotheque') },
      { id: 'coverage', label: 'Couverture et dates…', icon: 'gauge', overflow: true, run: () => openCoverage(store, { onApply: applyCoherence, onPlan: plan }) },
      { id: 'collect', label: 'Collecter les données manquantes…', icon: 'wifi', kind: 'network', overflow: true, run: plan },
      { id: 'search-clear', label: 'Retirer la sélection figée de Recherche', icon: 'x', overflow: true, run: clearSearch },
    ],
  });

  // ---------- Recipe, validation, draft ----------

  function setRecipe(recipe, { origin: from = 'load', saved } = {}) {
    if (saved !== undefined) store.saved = saved;
    if (from === 'load' || from === 'target') { store.evaluation = null; store.emit('evaluation', null); st.draftAt = null; }
    store.setRecipe(recipe, { origin: from });
    paintTarget();
    paintName();
    if (saved !== undefined) store.emit('saved', store.saved);
  }

  const validate = debounce(async () => {
    const my = ++st.validateToken;
    const res = await store.call('requetes.validate', { recipe: store.recipe });
    if (!store.alive || my !== st.validateToken) return;
    if (res.error) {
      store.validation = { valid: false, errors: [res.message], warnings: [], summary: [], parameters: [], conditionCount: 0, ldap: null, outline: [] };
    } else {
      store.validation = res.data;
      if (store.saved?.pendingFingerprint && res.data.fingerprint) {
        store.saved = { ...store.saved, fingerprint: res.data.fingerprint, pendingFingerprint: false };
      }
    }
    store.emit('validation', store.validation);
    paintChips();
  }, 220);

  /** The draft is kept with the revision it comes from: reopened, an older revision is detected before any save. */
  const keepDraft = debounce(async () => {
    const s = store.saved;
    const base = s && (s.source === 'personal' || s.source === 'template') ? { id: s.id, source: s.source, revision: s.revision ?? 0, fingerprint: s.fingerprint ?? null } : null;
    await store.call('requetes.draft.keep', { recipe: store.recipe, base });
  }, 1500);

  // ---------- Preview and collection ----------

  async function runPreview() {
    validate.flush();
    if (store.validation && !store.validation.valid) {
      store.toast(store.validation.errors?.[0] ?? 'La requête n’est pas valide.', 'warn');
      goto('creer');
      return;
    }
    st.compact = true;
    goto('apercu');
    store.evaluating = true;
    store.emit('evaluating');
    const res = await store.call('requetes.preview', { recipe: store.recipe, limit: 5000, verdict: 'auto' });
    store.evaluating = false;
    if (!store.alive) return;
    if (res.error) { store.emit('evaluation-error', res.message); return; }
    store.evaluation = res.data;
    store.emit('evaluation', res.data);
    paintChips();
    paintFlow();
  }

  function applyCoherence(hours) {
    store.setRecipe({ ...store.recipe, coherenceHours: hours });
    store.toast(`Fenêtre de cohérence de ${hours}${' '}h appliquée au brouillon.`, 'ok');
  }

  function plan(intro = null) {
    if (key(store.recipe.target) !== 'computer') { store.toast('La collecte ne concerne que les postes.', 'info'); return; }
    openPlan(store, { intro, onDone: () => { if (store.evaluation) runPreview(); } });
  }

  async function clearSearch() {
    const res = await store.call('requetes.search.clear', {});
    if (res.error) { store.toast(res.message, 'warn'); return; }
    store.toast(res.data.cleared ? 'Sélection figée de Recherche retirée.' : 'Aucune sélection figée pour Recherche.', 'info');
  }

  async function newRecipe() {
    const dirty = ((store.recipe.clauses?.length ?? 0) > 0 || !!store.recipe.expression) && !store.saved;
    if (dirty) {
      const ok = await confirmDialog({ title: 'Nouvelle requête ?', message: 'Le brouillon actuel n’est pas enregistré : il sera remplacé par une requête vide.', confirmLabel: 'Nouvelle requête', icon: 'plus' });
      if (!ok) return;
    }
    setRecipe(emptyRecipe(key(store.recipe.target)), { origin: 'load', saved: null });
    goto('creer');
    announce('Nouvelle requête vide.');
  }

  function savedOf(detail) {
    return detail.source === 'template'
      ? { id: detail.id, source: 'template', revision: 0, fingerprint: detail.fingerprint }
      : { id: detail.id, source: 'personal', revision: detail.revision, archived: detail.archived, category: detail.category, description: detail.description, name: detail.name, fingerprint: detail.fingerprint, pendingFingerprint: true };
  }

  /** Loads a library or template detail (requetes.library.get) into the draft. Never an archive (« Utiliser » is refused). */
  function load(detail, { preview = false } = {}) {
    if (detail.archived) { store.toast('Requête archivée : restaurez-la d’abord pour l’utiliser.', 'warn'); return; }
    setRecipe(detail.recipe, { origin: 'load', saved: savedOf(detail) });
    st.compact = true;
    store.toast(`« ${detail.name} » chargée dans l’atelier.`, 'ok');
    if (preview) runPreview(); else goto('creer');
  }

  function loadRecipe(recipe, { origin: from = 'load', saved = null } = {}) {
    setRecipe(recipe, { origin: from, saved });
  }

  async function openRecentDrawer() {
    openRecent(store, {
      onPick: async (row) => {
        const res = await store.call('requetes.library.get', { id: row.id });
        if (res.error) { store.toast(res.message, 'warn'); return; }
        load(res.data);
      },
      onLibrary: () => goto('bibliotheque'),
    });
  }

  // ---------- Tabs ----------

  const api = {
    goto: (id) => goto(id),
    runPreview,
    openCoverage: () => openCoverage(store, { onApply: applyCoherence, onPlan: plan }),
    plan,
    load,
    loadRecipe,
    rename: () => { window.scrollTo?.({ top: 0 }); main.scrollTo?.({ top: 0, behavior: 'smooth' }); startRename(); },
    useField: (id) => { goto('creer'); views.get('creer')?.useField?.(id); },
    navigate: (id, p) => ctx.navigate(id, p),
  };

  function mount(id) {
    if (views.has(id)) return;
    const panel = $(`[data-panel="${id}"]`);
    let view = null;
    try {
      if (id === 'creer') view = mountCompose(panel, store, api);
      else if (id === 'apercu') view = mountPreview(panel, store, api);
      else if (id === 'enregistrer') view = mountSave(panel, store, api);
      else if (id === 'bibliotheque') view = mountLibrary(panel, store, api);
      else if (id === 'informations') view = mountCatalog(panel, store, api);
      else if (id === 'partage') view = mountShare(panel, store, api);
      else if (id === 'wmi') view = mountWmi(panel, store, api, { computerName: params.poste ?? null });
      else if (id === 'reference') view = mountReference(panel, store, api);
    } catch (err) {
      console.error(err);
      panel.innerHTML = `<div class="empty rq-empty"><div class="art">${glyph('alert')}</div><h3>Vue indisponible</h3><p>Le détail est dans le journal technique.</p></div>`;
    }
    views.set(id, view);
  }

  function paintFlow() {
    const at = FLOW.findIndex((f) => f.id === st.tab);
    const done = { creer: !!store.validation?.valid, apercu: !!store.evaluation, enregistrer: store.saved?.source === 'personal' };
    main.querySelectorAll('.rq-flow-step').forEach((b, n) => {
      b.classList.toggle('done', done[b.dataset.tab] && b.dataset.tab !== st.tab);
      b.classList.toggle('past', at >= 0 && n < at);
    });
    $('.rq-flow-fill').style.setProperty('--p', String(at < 0 ? 0 : at / (FLOW.length - 1)));
    main.querySelector('.rq-flow').classList.toggle('away', at < 0);
  }

  function goto(id, { focus = false } = {}) {
    if (!ALL.includes(id)) return;
    if (id !== st.tab && st.tab !== 'creer') st.compact = true;
    st.tab = id;
    mount(id);
    main.querySelectorAll('[role="tab"][data-tab]').forEach((b) => {
      const on = b.dataset.tab === id;
      b.setAttribute('aria-selected', String(on));
      b.tabIndex = on ? 0 : -1;
    });
    main.querySelectorAll('[data-panel]').forEach((p) => {
      const on = p.dataset.panel === id;
      if (on && p.hidden) { p.hidden = false; p.classList.remove('enter'); void p.offsetWidth; p.classList.add('enter'); } else if (!on) p.hidden = true;
    });
    st.ink?.update();
    paintHero();
    paintFlow();
    if (focus) main.querySelector(`#rq-tab-${id}`)?.focus();
    try {
      const next = { ...params, onglet: id === 'creer' ? null : id, apercu: null };
      history.replaceState(history.state, '', ctx.link('requetes', next));
    } catch (err) {
      console.error(err);
    }
  }

  main.querySelector('.rq-rail').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-tab]') : null;
    if (b) { st.compact = true; goto(b.dataset.tab); }
  });
  main.querySelector('.rq-rail').addEventListener('keydown', (e) => {
    if (!['ArrowRight', 'ArrowLeft', 'Home', 'End'].includes(e.key)) return;
    const tabs = [...main.querySelectorAll('[role="tab"][data-tab]')];
    const at = tabs.findIndex((t) => t.dataset.tab === st.tab);
    const next = e.key === 'Home' ? 0 : e.key === 'End' ? tabs.length - 1 : (at + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length;
    e.preventDefault();
    goto(tabs[next].dataset.tab, { focus: true });
  });
  st.ink = inkFollow($('.rq-tools'), '[data-tab]', '[aria-selected="true"]');

  function onKey(e) {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') { e.preventDefault(); runPreview(); }
    if ((e.ctrlKey || e.metaKey) && (e.key === 's' || e.key === 'S')) { e.preventDefault(); goto('enregistrer'); }
    if ((e.ctrlKey || e.metaKey) && (e.key === 'o' || e.key === 'O')) { e.preventDefault(); openRecentDrawer(); }
    if (e.key === 'F2' && !st.renaming && !(e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement)) { e.preventDefault(); startRename(); }
  }
  main.addEventListener('keydown', onKey);

  const offs = [
    store.on('recipe', ({ origin: from }) => {
      // A new target (button, loaded recipe, LDAP text naming users or groups) reloads the catalogs of the views.
      const target = key(store.recipe.target);
      if (target !== st.target) { st.target = target; store.emit('target', target); }
      validate();
      if (from !== 'draft') keepDraft();
      paintName();
      paintTarget();
      paintChips();
      paintHero();
    }),
    store.on('saved', () => { keepDraft(); paintChips(); paintFlow(); paintHero(); }),
    store.on('validation', paintFlow),
    store.on('scope', paintScope),
  ];

  // ---------- Start ----------

  /** The draft of the last session, with the revision it came from compared to the library now. */
  async function resumeDraft(data) {
    let saved = null;
    const base = data.base;
    if (base?.source === 'personal') {
      const res = await store.call('requetes.library.get', { id: base.id });
      if (!res.error && !res.data.archived) {
        saved = { ...savedOf(res.data), revision: base.revision, fingerprint: base.fingerprint ?? null, pendingFingerprint: !base.fingerprint };
        if (res.data.revision !== base.revision) saved.libraryChanged = res.data.revision;
      }
    } else if (base?.source === 'template') {
      saved = { id: base.id, source: 'template', revision: 0, fingerprint: base.fingerprint ?? null };
    }
    if (!store.alive) return;
    st.draftAt = data.savedAt ?? null;
    setRecipe(data.recipe, { origin: 'draft', saved });
  }

  async function start() {
    const target = ['computer', 'user', 'group'].includes(params.cible) ? params.cible : null;
    let loaded = false;
    if (params.recette) {
      const res = await store.call('requetes.library.get', { id: params.recette });
      if (!store.alive) return;
      if (res.error) store.toast(res.message, 'warn');
      else if (res.data.archived) store.toast('Requête archivée : restaurez-la depuis la bibliothèque pour l’utiliser.', 'warn');
      else {
        setRecipe(res.data.recipe, { origin: 'load', saved: savedOf(res.data) });
        loaded = true;
      }
    }
    if (!loaded && params.ldap) {
      const base = emptyRecipe(target ?? 'computer');
      const res = await store.call('requetes.ldap.read', { text: params.ldap, recipe: base });
      if (!store.alive) return;
      if (!res.error && res.data.valid) { setRecipe(res.data.recipe, { origin: 'load', saved: null }); loaded = true; } else store.toast(res.error ? res.message : `Filtre LDAP refusé : ${res.data.error}`, 'warn');
    }
    if (!loaded && target) { setRecipe(emptyRecipe(target), { origin: 'load', saved: null }); loaded = true; }
    if (!loaded) {
      const res = await store.call('requetes.draft.get', undefined);
      if (!store.alive) return;
      if (!res.error && res.data?.recipe) await resumeDraft(res.data);
      else setRecipe(store.recipe, { origin: 'draft', saved: null });
    }
    if (params.apercu === '1') runPreview();
  }

  paintName();
  paintTarget();
  paintScope();
  paintChips();
  goto(st.tab);
  const stopReveal = reveal(main);
  loadScope();
  start();

  return () => {
    store.alive = false;
    validate.cancel();
    keepDraft.flush();
    main.removeEventListener('keydown', onKey);
    offs.forEach((off) => off());
    targetInk.stop();
    st.ink?.stop();
    cmdbar.destroy();
    stopReveal();
    for (const view of views.values()) {
      try { view?.destroy?.(); } catch (err) { console.error(err); }
    }
  };
}
