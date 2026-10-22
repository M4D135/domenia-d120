// Domenia 2 · Atelier de requêtes (Domenia 1 lot « requetes », REQ-001 to REQ-069). A guided flow « 1. Créer » →
// « 2. Aperçu » → « 3. Enregistrer », and the tools around it: library, catalog of the informations, packs, advanced WMI and
// the cmdlet reference. The draft lives in one store shared by the views; every change is validated by the engine and kept
// as a local draft. Reads are local; remote reads (collection, WMI) wait for an explicit gesture. Contract:
// docs/ops/requetes.md. Route parameters: onglet, recette (template or library id), cible, ldap, apercu=1, poste, retour.
import {
  esc, glyph, key, plural, TARGETS, createStore, emptyRecipe, formatNumber, ago, vars,
} from './requetes/shared.js';
import { mountCompose } from './requetes/compose.js';
import { mountPreview } from './requetes/preview.js';
import { mountSave } from './requetes/save.js';
import { mountLibrary } from './requetes/library.js';
import { mountCatalog } from './requetes/catalog.js';
import { mountShare } from './requetes/share.js';
import { mountWmi } from './requetes/wmi.js';
import { mountReference } from './requetes/reference.js';
import { openCoverage, openPlan, openScope } from './requetes/drawers.js';
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

export function render(main, ctx) {
  const params = ctx.params ?? {};
  const store = createStore(ctx);
  const views = new Map();
  const st = { tab: ALL.includes(params.onglet) ? params.onglet : 'creer', ink: null, validateToken: 0, target: key(store.recipe.target) };
  // « retour » names the screen that opened the workshop (Accueil, Recherche, Fiche…): one gesture brings the operator back.
  const origin = typeof params.retour === 'string' && params.retour !== 'requetes' ? (ctx.pages ?? []).find((p) => p.id === params.retour) : null;

  main.innerHTML = `<div class="page rq-page">
    <section class="hero rq-hero reveal">${RING}${ORBS}
      <div class="rq-hero-grid">
        <div class="rq-hero-main">
          <div class="eyebrow">${glyph('database')}<span>Atelier de requêtes</span><span class="rq-eyebrow-note">Lecture seule · évaluation locale</span>
            ${origin ? `<button type="button" class="btn xs subtle rq-back">${glyph('chevronLeft')}Revenir à l’écran ${esc(origin.label)}</button>` : ''}</div>
          <label class="visually-hidden" for="rq-name">Nom de la requête</label>
          <input id="rq-name" class="rq-title-input" type="text" maxlength="120" autocomplete="off" spellcheck="true">
          <p class="lead rq-lead">Composez une requête en conditions ou en filtre LDAP, vérifiez-la sur les données locales, puis enregistrez-la ou partagez-la.</p>
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

  // ---------- Hero: name, target, scope, commands ----------

  main.querySelector('.rq-back')?.addEventListener('click', () => ctx.navigate(origin.id, {}));

  function paintName() {
    const input = $('#rq-name');
    if (document.activeElement !== input) input.value = store.recipe.name ?? '';
    input.classList.toggle('long', input.value.length > 38);
  }
  const syncName = debounce(() => {
    const name = $('#rq-name').value.trim();
    if (name && name !== store.recipe.name) store.setRecipe({ ...store.recipe, name }, { origin: 'name' });
  }, 300);
  $('#rq-name').addEventListener('input', syncName);
  $('#rq-name').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); e.currentTarget.blur(); } });
  $('#rq-name').addEventListener('blur', () => { syncName.flush(); if (!$('#rq-name').value.trim()) paintName(); });

  const targetInk = inkFollow($('.rq-target'), '[data-target]', '[aria-checked="true"]');
  function paintTarget() {
    const t = key(store.recipe.target);
    main.querySelectorAll('[data-target]').forEach((b) => b.setAttribute('aria-checked', String(b.dataset.target === t)));
    targetInk.update();
    main.dataset.target = t;
  }
  main.querySelectorAll('[data-target]').forEach((b) => b.addEventListener('click', async () => {
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
    card.innerHTML = `<div class="rq-scope-top"><span class="rq-scope-ico">${glyph('ou')}</span><span class="rq-scope-k" id="rq-scope-k">${s.workshop ? 'Périmètre de l’atelier' : 'OU de travail'}</span>
        ${s.wholeDomain ? '<span class="k-pill warn sm">Tout le domaine</span>' : ''}</div>
      <div class="rq-scope-name">${esc(eff?.label ?? s.domain?.dnsName ?? 'Domaine')}</div>
      <div class="rq-scope-dn rq-mono" data-tip="${esc(eff?.dn ?? '')}">${esc(eff?.dn ?? '')}${eff && !eff.subtree ? ' · sans sous-OU' : ''}</div>
      <dl class="rq-scope-counts">${TARGETS.map((t, n) => `<div data-i="${n}"><dt>${glyph(t.icon)}${esc(t.label)}</dt><dd>${counts[t.id] !== undefined ? formatNumber(counts[t.id]) : '—'}</dd></div>`).join('')}</dl>
      ${s.accountsInDomain ? `<p class="rq-scope-accounts">${glyph('users')}Comptes et groupes : tout le domaine ${esc(s.domain?.dnsName ?? '')} (base locale)</p>` : ''}
      <p class="rq-scope-note">${b ? `${esc(b.source)} · lue ${esc(ago(b.readAt))} · ${plural(b.objects, 'objet', 'objets')}${b.complete ? '' : ' · lecture partielle'}` : 'Base locale non lue : l’aperçu sera vide.'}</p>
      <button type="button" class="btn sm subtle rq-scope-btn">${glyph('ou')}Changer de périmètre…</button>`;
    vars(card);
    main.querySelectorAll('[data-target]').forEach((btn) => {
      const n = counts[btn.dataset.target];
      btn.querySelector('.rq-target-n').textContent = n !== undefined ? formatNumber(n) : '';
    });
    card.querySelector('.rq-scope-btn').addEventListener('click', () => openScope(store, { onChange: () => { card.classList.remove('changed'); void card.offsetWidth; card.classList.add('changed'); } }));
  }

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

  function paintChips() {
    const v = store.validation;
    const s = store.saved;
    const chips = [];
    if (s?.source === 'template') chips.push(`<span class="chip">${glyph('sparkles')}Modèle livré</span>`);
    else if (s?.source === 'personal') chips.push(`<span class="chip">${glyph('star')}Révision ${esc(String(s.revision))}${s.archived ? ' · archivée' : ''}</span>`);
    else chips.push(`<span class="chip">${glyph('edit')}Brouillon</span>`);
    if (v?.valid) chips.push(`<span class="chip ok">${glyph('check')}${v.conditionCount ? plural(v.conditionCount, 'condition', 'conditions') : 'Aucune condition'}</span>`);
    else if (v) chips.push(`<span class="chip warn">${glyph('alert')}À corriger</span>`);
    if (v?.ldap) chips.push(`<span class="chip">${glyph('hash')}${v.ldap.exact ? 'Filtre LDAP exact' : 'LDAP + conditions locales'}</span>`);
    if (store.recipe.coherenceHours) chips.push(`<span class="chip">${glyph('clock')}Cohérence ${esc(String(store.recipe.coherenceHours))}${' '}h</span>`);
    if (store.evaluation) chips.push(`<span class="chip info">${glyph('eye')}Aperçu ${esc(ago(store.evaluation.evaluatedAt))}</span>`);
    $('.rq-hero-chips').innerHTML = chips.map((c, n) => c.replace('<span class="chip', `<span data-j="${n}" class="chip`)).join('');
    main.querySelectorAll('.rq-hero-chips [data-j]').forEach((el) => el.style.setProperty('--j', el.dataset.j));
  }

  const cmdbar = createCommandBar($('.rq-cmds'), {
    label: 'Actions de la requête',
    items: [
      { id: 'preview', label: 'Calculer l’aperçu', icon: 'play', primary: true, kbd: 'Ctrl Entrée', run: () => runPreview() },
      { id: 'new', label: 'Nouvelle requête', icon: 'plus', run: () => newRecipe() },
      { id: 'open', label: 'Ouvrir…', icon: 'database', run: () => goto('bibliotheque') },
      { id: 'save', label: 'Enregistrer', icon: 'star', kbd: 'Ctrl S', run: () => goto('enregistrer') },
      { id: 'coverage', label: 'Couverture et dates…', icon: 'gauge', overflow: true, run: () => openCoverage(store, { onApply: applyCoherence, onPlan: plan }) },
      { id: 'collect', label: 'Collecter les données manquantes…', icon: 'wifi', kind: 'network', overflow: true, run: plan },
      { id: 'search-clear', label: 'Retirer la sélection figée de Recherche', icon: 'x', overflow: true, run: clearSearch },
    ],
  });

  // ---------- Recipe, validation, draft ----------

  function setRecipe(recipe, { origin = 'load', saved } = {}) {
    if (saved !== undefined) store.saved = saved;
    if (origin === 'load' || origin === 'target') { store.evaluation = null; store.emit('evaluation', null); }
    store.setRecipe(recipe, { origin });
    paintTarget();
    paintName();
    if (saved !== undefined) store.emit('saved', store.saved);
  }

  const validate = debounce(async () => {
    const my = ++st.validateToken;
    const res = await store.call('requetes.validate', { recipe: store.recipe });
    if (!store.alive || my !== st.validateToken) return;
    if (res.error) {
      store.validation = { valid: false, errors: [res.message], warnings: [], summary: [], parameters: [], conditionCount: 0, ldap: null };
    } else {
      store.validation = res.data;
      if (store.saved?.pendingFingerprint && res.data.fingerprint) {
        store.saved = { ...store.saved, fingerprint: res.data.fingerprint, pendingFingerprint: false };
      }
    }
    store.emit('validation', store.validation);
    paintChips();
  }, 220);

  const keepDraft = debounce(async () => {
    await store.call('requetes.draft.keep', { recipe: store.recipe });
  }, 1500);

  // ---------- Preview and collection ----------

  async function runPreview() {
    validate.flush();
    if (store.validation && !store.validation.valid) {
      store.toast(store.validation.errors?.[0] ?? 'La requête n’est pas valide.', 'warn');
      goto('creer');
      return;
    }
    goto('apercu');
    store.evaluating = true;
    store.emit('evaluating');
    const res = await store.call('requetes.preview', { recipe: store.recipe });
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
    store.toast(`Fenêtre de cohérence de ${hours}${' '}h appliquée au brouillon.`, 'ok');
  }

  function plan() {
    if (key(store.recipe.target) !== 'computer') { store.toast('La collecte ne concerne que les postes.', 'info'); return; }
    openPlan(store, { onDone: () => { if (store.evaluation) runPreview(); } });
  }

  async function clearSearch() {
    const res = await store.call('requetes.search.clear', {});
    if (res.error) { store.toast(res.message, 'warn'); return; }
    store.toast(res.data.cleared ? 'Sélection figée de Recherche retirée.' : 'Aucune sélection figée pour Recherche.', 'info');
  }

  async function newRecipe() {
    const dirty = (store.recipe.clauses?.length ?? 0) > 0 && !store.saved;
    if (dirty) {
      const ok = await confirmDialog({ title: 'Nouvelle requête ?', message: 'Le brouillon actuel n’est pas enregistré : il sera remplacé par une requête vide.', confirmLabel: 'Nouvelle requête', icon: 'plus' });
      if (!ok) return;
    }
    setRecipe(emptyRecipe(key(store.recipe.target)), { origin: 'load', saved: null });
    goto('creer');
    announce('Nouvelle requête vide.');
  }

  /** Loads a library or template detail (requetes.library.get) into the draft. */
  function load(detail, { preview = false } = {}) {
    setRecipe(detail.recipe, {
      origin: 'load',
      saved: detail.source === 'template'
        ? { id: detail.id, source: 'template', revision: 0 }
        : { id: detail.id, source: detail.source === 'archive' ? 'personal' : detail.source, revision: detail.revision, archived: detail.archived, category: detail.category, description: detail.description, name: detail.name, pendingFingerprint: true },
    });
    store.toast(`« ${detail.name} » chargée dans l’atelier.`, 'ok');
    if (preview) runPreview(); else goto('creer');
  }

  function loadRecipe(recipe, { origin = 'load', saved = null } = {}) {
    setRecipe(recipe, { origin, saved });
  }

  // ---------- Tabs ----------

  const api = {
    goto: (id) => goto(id),
    runPreview,
    openCoverage: () => openCoverage(store, { onApply: applyCoherence, onPlan: plan }),
    load,
    loadRecipe,
    useField: (id) => { goto('creer'); views.get('creer')?.useField?.(id); },
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
    $('.rq-hero').classList.toggle('compact', !FLOW.some((f) => f.id === id));
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
    if (b) goto(b.dataset.tab);
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
  }
  main.addEventListener('keydown', onKey);

  const offs = [
    store.on('recipe', ({ origin }) => {
      // A new target (button, loaded recipe, LDAP text naming users or groups) reloads the catalogs of the views.
      const target = key(store.recipe.target);
      if (target !== st.target) { st.target = target; store.emit('target', target); }
      validate();
      if (origin !== 'draft') keepDraft();
      paintName();
      paintTarget();
      paintChips();
    }),
    store.on('saved', () => { paintChips(); paintFlow(); }),
    store.on('validation', paintFlow),
    store.on('scope', paintScope),
  ];

  // ---------- Start ----------

  async function start() {
    const target = ['computer', 'user', 'group'].includes(params.cible) ? params.cible : null;
    let loaded = false;
    if (params.recette) {
      const res = await store.call('requetes.library.get', { id: params.recette });
      if (!store.alive) return;
      if (res.error) store.toast(res.message, 'warn');
      else {
        const d = res.data;
        setRecipe(d.recipe, { origin: 'load', saved: d.source === 'template' ? { id: d.id, source: 'template', revision: 0 } : { id: d.id, source: d.source === 'archive' ? 'personal' : d.source, revision: d.revision, archived: d.archived, category: d.category, description: d.description, name: d.name, pendingFingerprint: true } });
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
      if (!res.error && res.data?.recipe) {
        setRecipe(res.data.recipe, { origin: 'draft', saved: null });
        if (res.data.savedAt) store.toast(`Brouillon repris (${ago(res.data.savedAt)}).`, 'info');
      } else {
        setRecipe(store.recipe, { origin: 'draft', saved: null });
      }
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
