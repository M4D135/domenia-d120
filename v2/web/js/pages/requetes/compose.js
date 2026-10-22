// « 1. Créer »: visual builder (information, condition, typed value with live unit conversion, contextual help), simple
// criteria in AND / OR, advanced tree (AND / OR / NOT groups, collections of probe instances), parameters, coherence
// window, and the LDAP text kept in sync with the conditions in both directions. The raw LDAP attributes of the schema are
// informations of the builder too (« ldap:<attribut> », LDAP semantics). Every change is validated by the engine
// (requetes.validate); nothing is read from the directory here.
import { createFieldCombo } from './combo.js';
import { createLdapEditor } from './ldap-editor.js';
import {
  esc, glyph, key, clone, clauseText, valueText, sourcePill, fieldOf, resolvedCatalog, OPERATOR_LABEL, plural, vars, emptyState, NBSP,
} from './shared.js';
import { writeClipboard, debounce } from '../../kit/util.js';
import { reveal, announce } from '../../ui.js';

const OPERATORS = {
  text: ['equal', 'notEqual', 'contains', 'startsWith', 'endsWith', 'isMissing', 'isPresent'],
  number: ['equal', 'notEqual', 'greater', 'greaterOrEqual', 'less', 'lessOrEqual', 'isMissing', 'isPresent'],
  boolean: ['equal', 'notEqual', 'isMissing', 'isPresent'],
};
const NO_VALUE = new Set(['isMissing', 'isPresent']);
const PRESENCE = new Set(['isMissing', 'isPresent']);

const opsOf = (field) => (field?.operators?.length ? field.operators.map(key) : OPERATORS[key(field?.kind)] ?? OPERATORS.text);

function nodeLabel(node, store) {
  const k = key(node.kind);
  if (k === 'clause') return clauseText(node.clause, fieldOf(store, node.clause?.field));
  if (k === 'all') return 'Toutes les conditions (ET)';
  if (k === 'any') return 'Au moins une condition (OU)';
  if (k === 'not') return 'Le groupe suivant ne correspond pas (NON)';
  const q = { all: 'Toutes les instances', none: 'Aucune instance' }[key(node.quantifier)] ?? 'Au moins une instance';
  return `${q} de «${NBSP}${fieldOf(store, node.collectionField)?.name ?? node.collectionField}${NBSP}»`;
}

/** Every node of a condition tree with its path (« /0/2 »), depth and owning collection (exported for tests/web). */
export function walk(node, path = '', depth = 0, out = [], collection = null) {
  if (!node) return out;
  out.push({ node, path, depth, collection });
  const k = key(node.kind);
  const inner = k === 'collection' ? String(node.collectionField ?? '').replace(/^probe:/, '') : collection;
  (node.children ?? []).forEach((child, i) => walk(child, `${path}/${i}`, depth + 1, out, inner));
  return out;
}

/** Node at a path of a tree, with its parent and index (exported for tests/web). */
export function nodeAt(root, path) {
  if (!path) return { node: root, parent: null, index: -1 };
  let node = root;
  let parent = null;
  let index = -1;
  for (const part of path.split('/').filter(Boolean)) {
    parent = node;
    index = Number(part);
    node = node?.children?.[index];
  }
  return { node, parent, index };
}

const group = (kind, children = []) => ({ kind, clause: null, children, collectionField: null, quantifier: null });

/**
 * The group that receives a new element: the selection when it is AND / OR, the inside of NOT / collection (wrapped in an AND
 * group when needed), else its parent. Mutates the tree given (a copy of the draft). Exported for tests/web.
 */
export function targetGroupPath(expr, path) {
  const { node } = nodeAt(expr, path);
  const k = key(node?.kind);
  if (k === 'all' || k === 'any') return path;
  if (k === 'not' || k === 'collection') {
    if (!node.children?.length) node.children = [group('all')];
    const inner = node.children[0];
    if (!['all', 'any'].includes(key(inner.kind))) node.children = [group('all', [inner])];
    return `${path}/0`;
  }
  return path.split('/').slice(0, -1).join('/');
}

/** Mounts the « Créer » view; returns a cleanup. */
export function mountCompose(panel, store, api) {
  const st = {
    field: null,
    operator: 'equal',
    raw: '',
    preview: null,
    editIndex: -1,
    selectedPath: '',
    selectedCrit: -1,
    ldapDirty: false,
    ldapUnlocked: false,
    combo: null,
    editor: null,
    fields: [],
    collections: [],
    instanceFields: [],
  };
  panel.innerHTML = `<div class="grid rq-compose">
    <div class="rq-col span-7">
      <section class="card rq-builder spot reveal" aria-labelledby="rq-builder-title">
        <div class="card-head"><span class="card-icon">${glyph('sliders')}</span><div class="rq-head-titles"><h3 id="rq-builder-title">Condition</h3>
          <p class="rq-sub">Choisissez une information, une condition et une valeur : la valeur retenue s’affiche avant l’ajout.</p></div>
          <span class="meta rq-builder-target"></span></div>
        <div class="rq-builder-body">
          <div class="rq-step"><span class="rq-step-n">1</span><div class="rq-step-main"><span class="rq-step-label">Information</span><div class="rq-field-host"></div></div></div>
          <div class="rq-step"><span class="rq-step-n">2</span><div class="rq-step-main"><span class="rq-step-label">Condition</span><div class="rq-ops" role="radiogroup" aria-label="Condition"></div></div></div>
          <div class="rq-step"><span class="rq-step-n">3</span><div class="rq-step-main"><span class="rq-step-label">Valeur</span><div class="rq-value-host"></div>
            <p class="rq-conv" aria-live="polite"></p></div></div>
        </div>
        <div class="rq-help" aria-live="polite"></div>
        <div class="rq-builder-actions">
          <button class="btn primary rq-add" type="button">${glyph('plus')}<span>Ajouter le critère</span></button>
          <button class="btn subtle rq-add-tree" type="button" data-tip="Ajoute ce critère au groupe sélectionné des conditions avancées">${glyph('layers')}Au groupe sélectionné</button>
          <button class="btn ghost rq-cancel-edit" type="button" hidden>${glyph('x')}Annuler la modification</button>
        </div>
      </section>

      <section class="card rq-criteria spot reveal" aria-labelledby="rq-crit-title">
        <div class="card-head"><span class="card-icon">${glyph('filter')}</span><div class="rq-head-titles"><h3 id="rq-crit-title">Vos critères</h3>
          <p class="rq-sub rq-crit-sub"></p></div>
          <div class="segmented rq-junction" role="group" aria-label="Combinaison des critères"><span class="thumb" aria-hidden="true"></span>
            <button type="button" data-j="all" aria-pressed="true">Toutes (ET)</button><button type="button" data-j="any" aria-pressed="false">Au moins une (OU)</button></div></div>
        <ol class="rq-crit-list" aria-label="Critères de la requête"></ol>
        <div class="rq-segment" hidden></div>
      </section>

      <section class="card rq-advanced spot reveal">
        <details class="rq-fold" data-fold="advanced">
          <summary><span class="card-icon">${glyph('tree')}</span><span class="rq-fold-title"><b>Conditions avancées</b><span>Groupes ET, OU, NON et conditions sur une même instance de sonde</span></span><span class="rq-fold-badge"></span>${glyph('chevronDown', 'rq-fold-chev')}</summary>
          <div class="rq-fold-body">
            <div class="rq-tree-tools" role="toolbar" aria-label="Arbre de conditions">
              <div class="rq-tree-group" role="group" aria-label="Ajouter"><span class="rq-tree-k">Ajouter</span>
                <button class="btn xs subtle" type="button" data-tree="all">${glyph('plus')}Groupe ET</button>
                <button class="btn xs subtle" type="button" data-tree="any">${glyph('plus')}Groupe OU</button>
                <button class="btn xs subtle" type="button" data-tree="not">${glyph('plus')}Groupe NON</button>
                <button class="btn xs subtle" type="button" data-tree="clause">${glyph('plus')}Critère choisi</button></div>
              <div class="rq-tree-group end" role="group" aria-label="Élément sélectionné">
                <button class="btn xs ghost icon" type="button" data-tree="up" aria-label="Monter" data-tip="Monter">${glyph('arrowUp')}</button>
                <button class="btn xs ghost icon" type="button" data-tree="down" aria-label="Descendre" data-tip="Descendre">${glyph('arrowDown')}</button>
                <button class="btn xs ghost" type="button" data-tree="remove">${glyph('trash')}Retirer</button>
                <button class="btn xs ghost" type="button" data-tree="clear">${glyph('x')}Tout effacer</button></div>
            </div>
            <div class="rq-tree" role="tree" aria-label="Conditions avancées"></div>
            <div class="rq-collection">
              <h4>Condition sur une collection d’instances</h4>
              <div class="rq-collection-row coll">
                <label class="rq-mini-field wide"><span>Collection de la sonde</span><span class="k-select sm"><select class="input rq-coll-probe"></select></span></label>
                <label class="rq-mini-field"><span>Quantificateur</span><span class="k-select sm"><select class="input rq-coll-q">
                  <option value="any">Au moins une instance</option><option value="all">Toutes les instances</option><option value="none">Aucune instance</option></select></span></label>
                <button class="btn xs subtle rq-coll-add" type="button">${glyph('plus')}Ajouter la collection</button>
              </div>
              <div class="rq-collection-row inst">
                <label class="rq-mini-field wide"><span>Propriété de l’instance</span><span class="k-select sm"><select class="input rq-inst-field"></select></span></label>
                <label class="rq-mini-field"><span>Condition</span><span class="k-select sm"><select class="input rq-inst-op"></select></span></label>
                <label class="rq-mini-field"><span>Valeur</span><input class="input sm rq-inst-val" type="text" maxlength="4096" placeholder="Valeur"></label>
                <button class="btn xs subtle rq-inst-add" type="button">${glyph('plus')}Critère d’instance</button>
              </div>
              <p class="rq-note">Les propriétés viennent de la même instance de la sonde ; une collection partielle ou non lue reste inconnue.</p>
            </div>
          </div>
        </details>
      </section>

      <section class="card rq-params spot reveal">
        <details class="rq-fold" data-fold="params">
          <summary><span class="card-icon">${glyph('tag')}</span><span class="rq-fold-title"><b>Paramètres réutilisables</b><span>Une valeur à changer sans recréer la requête</span></span><span class="rq-fold-badge"></span>${glyph('chevronDown', 'rq-fold-chev')}</summary>
          <div class="rq-fold-body">
            <div class="rq-param-list"></div>
            <div class="rq-param-new">
              <p class="rq-param-from rq-note">${glyph('info')}<span class="rq-param-from-text">Sélectionnez un critère dans « Vos critères » : il devient un paramètre nommé.</span></p>
              <div class="rq-param-fields">
                <label class="rq-mini-field"><span>Nom technique</span><input class="input sm rq-param-name" type="text" maxlength="64" placeholder="Seuil"></label>
                <label class="rq-mini-field"><span>Libellé affiché</span><input class="input sm rq-param-label" type="text" maxlength="80" placeholder="Seuil d’espace libre"></label>
                <label class="rq-mini-field num" hidden><span>Minimum</span><input class="input sm rq-param-min" type="text" inputmode="decimal" maxlength="32" placeholder="Aucun"></label>
                <label class="rq-mini-field num" hidden><span>Maximum</span><input class="input sm rq-param-max" type="text" inputmode="decimal" maxlength="32" placeholder="Aucun"></label>
              </div>
              <div class="rq-param-acts">
                <button class="btn xs subtle rq-param-add" type="button">${glyph('plus')}Paramétrer le critère sélectionné</button>
                <button class="btn xs ghost rq-param-freeze" type="button">${glyph('pin')}Fixer les valeurs actuelles</button>
              </div>
            </div>
          </div>
        </details>
      </section>

      <section class="card rq-coherence spot reveal">
        <details class="rq-fold" data-fold="coherence">
          <summary><span class="card-icon">${glyph('clock')}</span><span class="rq-fold-title"><b>Cohérence des dates sources</b><span>Écart maximal entre les dates des informations d’un objet</span></span><span class="rq-fold-badge"></span>${glyph('chevronDown', 'rq-fold-chev')}</summary>
          <div class="rq-fold-body">
            <div class="rq-coh-row">
              <label class="field"><span>Écart maximal (heures)</span><input class="input sm rq-coh-hours" type="number" min="1" max="8760" step="1" placeholder="Aucune contrainte"></label>
              <button class="btn xs subtle rq-coh-apply" type="button">Appliquer la fenêtre</button>
              <button class="btn xs ghost rq-coh-clear" type="button">Aucune contrainte</button>
              <button class="btn xs subtle rq-coh-check" type="button">${glyph('gauge')}Vérifier les informations disponibles…</button>
            </div>
            <p class="rq-note">Au-delà de l’écart, ou si une date manque, le verdict devient Inconnu : un ping ne rajeunit jamais un inventaire.</p>
          </div>
        </details>
      </section>
    </div>

    <aside class="rq-col rq-side span-5" aria-label="Filtre et résumé">
      <section class="card rq-ldap-card spot reveal" aria-labelledby="rq-ldap-title">
        <div class="card-head"><span class="card-icon">${glyph('hash')}</span><div class="rq-head-titles"><h3 id="rq-ldap-title">Filtre LDAP</h3>
          <p class="rq-sub">Synchronisé avec les critères, dans les deux sens.</p></div><span class="meta rq-ldap-state"></span></div>
        <div class="rq-ldap-host"></div>
        <p class="rq-ldap-msg" aria-live="polite"></p>
        <div class="rq-ldap-local" hidden></div>
        <div class="rq-ldap-actions">
          <button class="btn xs subtle rq-ldap-copy" type="button">${glyph('copy')}Copier le filtre</button>
          <button class="btn xs subtle rq-ldap-cmd" type="button">${glyph('command')}Copier la commande PowerShell</button>
          <button class="btn xs ghost rq-ldap-unlock" type="button" hidden>${glyph('edit')}Modifier le texte quand même</button>
        </div>
        <details class="rq-prefilter"><summary>Filtre envoyé au contrôleur en mode annuaire</summary><code class="rq-mono rq-prefilter-text"></code>
          <p class="rq-note">Sur-ensemble de tout objet qui peut correspondre ou rester inconnu ; chaque objet lu est ensuite réévalué localement.</p></details>
      </section>

      <section class="card rq-summary-card spot reveal" aria-labelledby="rq-sum-title">
        <div class="card-head"><span class="card-icon">${glyph('object')}</span><div class="rq-head-titles"><h3 id="rq-sum-title">Résumé</h3><p class="rq-sub rq-sum-format"></p></div><span class="meta rq-sum-state"></span></div>
        <ul class="rq-issues" aria-live="polite"></ul>
        <ol class="rq-outline"></ol>
        <label class="field rq-groupby"><span>Répartition</span><span class="k-select sm"><select class="input rq-groupby-select" aria-label="Répartition"></select></span>
          <small>Compteur simple, ou répartition par une information (OS, version, OU, modèle, sonde…).</small></label>
        <div class="rq-sum-actions">
          <button class="btn primary rq-go-preview" type="button">${glyph('play')}Voir l’aperçu local</button>
          <button class="btn subtle rq-go-save" type="button">Enregistrer ou réutiliser${NBSP}→</button>
        </div>
      </section>
    </aside>
  </div>`;
  const $ = (sel) => panel.querySelector(sel);
  const stopReveal = reveal(panel);

  // ---------- Builder ----------

  /** Comparisons first, then the presence tests in a group of their own: a line break falls between the two, never inside. */
  function renderOps() {
    const ops = opsOf(st.field);
    if (!ops.includes(st.operator)) st.operator = ops[0];
    const button = (op) => `<button type="button" role="radio" aria-checked="${op === st.operator}" data-op="${op}" tabindex="${op === st.operator ? 0 : -1}">${esc(OPERATOR_LABEL[op] ?? op)}</button>`;
    const compare = ops.filter((op) => !PRESENCE.has(op));
    const presence = ops.filter((op) => PRESENCE.has(op));
    $('.rq-ops').innerHTML = `<span class="rq-ops-group">${compare.map(button).join('')}</span>${presence.length ? `<span class="rq-ops-group presence">${presence.map(button).join('')}</span>` : ''}`;
  }

  function renderValue() {
    const host = $('.rq-value-host');
    const f = st.field;
    const kind = key(f?.kind);
    if (!f || NO_VALUE.has(st.operator)) {
      host.innerHTML = `<input class="input" type="text" disabled aria-label="Valeur" placeholder="${f ? 'Aucune valeur pour ce test' : 'Choisissez d’abord une information'}">`;
      st.raw = '';
    } else if (kind === 'boolean') {
      const on = st.raw === 'false' ? 'false' : 'true';
      st.raw = on;
      host.innerHTML = `<div class="segmented rq-bool" role="group" aria-label="Valeur"><span class="thumb" aria-hidden="true"></span>
        <button type="button" data-b="true" aria-pressed="${on === 'true'}">Oui</button><button type="button" data-b="false" aria-pressed="${on === 'false'}">Non</button></div>`;
    } else if (f.choices?.length && st.operator !== 'contains' && st.operator !== 'startsWith' && st.operator !== 'endsWith') {
      const values = f.choices.map((c) => String(c.value));
      if (!values.includes(st.raw)) st.raw = values[0];
      host.innerHTML = `<span class="k-select"><select class="input rq-val-select" aria-label="Valeur">${f.choices.map((c) => `<option value="${esc(String(c.value))}"${String(c.value) === st.raw ? ' selected' : ''}>${esc(c.name)}</option>`).join('')}</select></span>`;
    } else {
      host.innerHTML = `<input class="input rq-val-input${kind === 'number' ? ' num' : ''}" type="text" maxlength="4096" aria-label="Valeur" autocomplete="off" spellcheck="false"
        placeholder="${esc(f.example ? `Exemple : ${f.example}` : kind === 'number' ? 'Nombre, par exemple 8 Go ou 10,5' : 'Texte')}" value="${esc(st.raw)}">`;
    }
    updateConversion();
  }

  const preview = debounce(async () => {
    const f = st.field;
    if (!f || key(f.kind) !== 'number' || NO_VALUE.has(st.operator) || !st.raw.trim()) { st.preview = null; paintConversion(); return; }
    const res = await store.call('requetes.value.preview', { target: store.recipe.target, field: f.id, text: st.raw });
    if (!store.alive) return;
    st.preview = res.data ?? { valid: false, text: res.message };
    paintConversion();
  }, 160);

  function paintConversion() {
    const el = $('.rq-conv');
    const p = st.preview;
    el.className = `rq-conv${p ? (p.valid ? ' ok' : ' bad') : ''}`;
    el.textContent = p?.text ?? (st.field && key(st.field.kind) === 'number' && !NO_VALUE.has(st.operator) ? `Unité attendue${NBSP}: ${st.field.unit}. Unités usuelles acceptées (Go, Mo, To, jours, heures, %, Mbit/s, MHz).` : '');
  }

  function updateConversion() {
    st.preview = null;
    paintConversion();
    preview();
  }

  function renderHelp() {
    const f = st.field;
    $('.rq-help').innerHTML = f ? `<div class="rq-help-head">${sourcePill(f.source)}<b>${esc(f.name)}</b><span class="rq-help-type">${esc(f.unit && f.unit !== f.typeLabel ? `${f.typeLabel} · ${f.unit}` : f.typeLabel)}</span></div>
      <p>${esc(f.description)}</p>
      <dl class="rq-help-grid"><div><dt>Coût de lecture</dt><dd>${esc(f.cost)}</dd></div><div><dt>Fraîcheur</dt><dd>${esc(f.freshness)}</dd></div>
      ${f.example ? `<div><dt>Exemple</dt><dd>${esc(f.example)}</dd></div>` : ''}<div><dt>Obtenir l’information</dt><dd>${esc(f.collection)}</dd></div></dl>`
      : `<p class="rq-help-empty">${glyph('info')}L’aide de l’information choisie s’affiche ici : source, unité, coût de lecture et règle de fraîcheur.</p>`;
  }

  function setField(f, { keep = false } = {}) {
    st.field = f;
    if (!keep) { st.raw = ''; st.operator = opsOf(f)[0]; }
    renderOps();
    renderValue();
    renderHelp();
  }

  function builderClause() {
    const f = st.field;
    if (!f) { store.toast('Choisissez une information.', 'warn'); return null; }
    const op = st.operator;
    let value = null;
    if (!NO_VALUE.has(op)) {
      const kind = key(f.kind);
      if (kind === 'boolean') value = st.raw !== 'false';
      else if (kind === 'number') {
        if (!st.raw.trim()) { store.toast('Saisissez une valeur numérique.', 'warn'); return null; }
        if (st.preview && !st.preview.valid) { store.toast(st.preview.text, 'warn'); return null; }
        value = st.preview?.valid && Number.isFinite(st.preview.value) ? st.preview.value : st.raw.trim();
      } else {
        const choice = f.choices?.find((c) => String(c.value) === st.raw);
        value = choice ? choice.value : st.raw;
        if ((op === 'contains' || op === 'startsWith' || op === 'endsWith') && !String(value).length) { store.toast('Saisissez le texte cherché.', 'warn'); return null; }
      }
    }
    return { field: f.id, operator: op, value };
  }

  function edit(mutate, message) {
    const next = clone(store.recipe);
    mutate(next);
    store.setRecipe(next);
    if (message) announce(message);
  }

  $('.rq-ops').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-op]') : null;
    if (!b) return;
    st.operator = b.dataset.op;
    renderOps();
    renderValue();
  });
  $('.rq-ops').addEventListener('keydown', (e) => {
    if (!['ArrowRight', 'ArrowLeft'].includes(e.key)) return;
    const ops = opsOf(st.field);
    const at = ops.indexOf(st.operator);
    st.operator = ops[(at + (e.key === 'ArrowRight' ? 1 : -1) + ops.length) % ops.length];
    renderOps();
    renderValue();
    $(`.rq-ops [data-op="${st.operator}"]`)?.focus();
    e.preventDefault();
  });
  $('.rq-value-host').addEventListener('input', (e) => {
    if (e.target instanceof HTMLInputElement) { st.raw = e.target.value; updateConversion(); }
  });
  $('.rq-value-host').addEventListener('change', (e) => {
    if (e.target instanceof HTMLSelectElement) st.raw = e.target.value;
  });
  $('.rq-value-host').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-b]') : null;
    if (!b) return;
    st.raw = b.dataset.b;
    renderValue();
  });
  $('.rq-value-host').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.target instanceof HTMLInputElement) { e.preventDefault(); $('.rq-add').click(); }
  });
  $('.rq-add').addEventListener('click', () => {
    const clause = builderClause();
    if (!clause) return;
    if (st.editIndex >= 0) {
      const at = st.editIndex;
      edit((r) => { r.clauses[at] = clause; }, 'Critère mis à jour.');
      stopEditing();
      return;
    }
    edit((r) => { r.clauses.push(clause); }, `Critère ajouté${NBSP}: ${clauseText(clause, st.field)}`);
    flashLast();
  });
  $('.rq-cancel-edit').addEventListener('click', stopEditing);

  function stopEditing() {
    st.editIndex = -1;
    $('.rq-add span').textContent = 'Ajouter le critère';
    $('.rq-cancel-edit').hidden = true;
    panel.querySelector('.rq-builder').classList.remove('editing');
  }

  function startEditing(index) {
    const clause = store.recipe.clauses[index];
    const f = fieldOf(store, clause.field);
    if (!f || clause.field === 'ldap.filter') { store.toast('Ce filtre LDAP brut se modifie dans le texte LDAP, à droite.', 'info'); return; }
    st.editIndex = index;
    st.combo?.setValue(f.id);
    st.field = f;
    st.operator = key(clause.operator);
    st.raw = clause.value === null || clause.value === undefined ? '' : typeof clause.value === 'object' ? '' : String(clause.value);
    renderOps();
    renderValue();
    renderHelp();
    $('.rq-add span').textContent = 'Mettre à jour le critère';
    $('.rq-cancel-edit').hidden = false;
    const card = panel.querySelector('.rq-builder');
    card.classList.add('editing');
    card.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  function flashLast() {
    requestAnimationFrame(() => panel.querySelector('.rq-crit-row:last-child')?.classList.add('fresh'));
  }

  // ---------- Criteria ----------

  function renderCriteria() {
    const r = store.recipe;
    const list = $('.rq-crit-list');
    const j = key(r.junction) === 'any' ? 'any' : 'all';
    panel.querySelectorAll('.rq-junction button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.j === j)));
    junctionInk();
    const [one, many] = { computer: ['poste', 'postes'], user: ['compte', 'comptes'], group: ['groupe', 'groupes'] }[key(r.target)] ?? ['objet', 'objets'];
    const tree = !!r.expression;
    $('.rq-crit-sub').textContent = r.clauses.length
      ? `${plural(r.clauses.length, 'critère', 'critères')} · ${j === 'any' ? 'au moins un doit être vrai' : 'tous doivent être vrais'}${tree ? ' · et les conditions avancées' : ''}`
      : tree ? 'Aucun critère simple : les conditions avancées ci-dessous décident.' : `Aucun critère : tous les ${many} du périmètre correspondent.`;
    void one;
    if (!r.clauses.length) {
      list.innerHTML = tree
        ? `<li class="rq-crit-empty">${glyph('tree')}<span>Cette requête s’écrit en conditions avancées (groupes ET, OU, NON ou collection d’instances) : elles sont ouvertes plus bas.</span></li>`
        : `<li class="rq-crit-empty">${glyph('sparkles')}<span>Ajoutez un critère ci-dessus, chargez un modèle de la bibliothèque ou saisissez un filtre LDAP à droite.</span></li>`;
    } else {
      list.innerHTML = r.clauses.map((c, i) => {
        const f = fieldOf(store, c.field);
        const op = key(c.operator);
        const raw = c.field === 'ldap.filter';
        const val = NO_VALUE.has(op) ? '' : raw ? String(c.value ?? '') : valueText(c.value, f);
        return `<li class="rq-crit-row${i === st.selectedCrit ? ' selected' : ''}" data-i="${i}" data-src="${esc(f ? (f.source === 'observation' ? 'seen' : key(f.source)) : 'ad')}">
          <span class="rq-crit-bar" aria-hidden="true"></span>
          <button type="button" class="rq-crit-main" data-act="select" aria-pressed="${i === st.selectedCrit}">
            ${i > 0 ? `<span class="rq-join">${j === 'any' ? 'OU' : 'ET'}</span>` : '<span class="rq-join first">SI</span>'}
            <span class="rq-crit-field">${esc(f?.name ?? c.field)}</span>
            ${raw ? '' : `<span class="rq-crit-op">${esc(OPERATOR_LABEL[op] ?? op)}</span>`}
            ${val ? `<span class="rq-crit-val${raw ? ' rq-mono' : ''}">${esc(val)}</span>` : ''}
          </button>
          <span class="rq-crit-tools">${f ? sourcePill(f.source) : ''}
            <button type="button" class="btn ghost xs icon" data-act="edit" aria-label="Modifier ce critère" data-tip="Modifier">${glyph('edit')}</button>
            <button type="button" class="btn ghost xs icon" data-act="remove" aria-label="Retirer ce critère" data-tip="Retirer">${glyph('x')}</button></span>
        </li>`;
      }).join('');
      vars(list);
    }
    renderSegment();
  }

  function renderSegment() {
    const r = store.recipe;
    const host = $('.rq-segment');
    const parts = [];
    for (const c of r.refinements ?? []) parts.push(clauseText(c, fieldOf(store, c.field)));
    if (r.probeSelection) parts.push(`Segment de sonde ${r.probeSelection.key} (${r.probeSelection.mode})`);
    if (Array.isArray(r.objectIds)) parts.push(`Sélection figée de ${plural(r.objectIds.length, 'GUID', 'GUID')}`);
    host.hidden = !parts.length;
    host.innerHTML = parts.length ? `<div class="rq-segment-in">${glyph('layers')}<div><b>Segment actif (ET)</b><span>${parts.map(esc).join(' · ')}</span></div>
      <button type="button" class="btn xs ghost rq-seg-clear">${glyph('x')}Retirer le segment</button></div>` : '';
  }

  $('.rq-crit-list').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-act]') : null;
    const row = b?.closest('.rq-crit-row');
    if (!b || !row) return;
    const i = Number(row.dataset.i);
    if (b.dataset.act === 'remove') {
      if (st.editIndex === i) stopEditing();
      const removed = store.recipe.clauses[i];
      edit((r) => { r.clauses.splice(i, 1); }, `Critère retiré${NBSP}: ${clauseText(removed, fieldOf(store, removed.field))}`);
    } else if (b.dataset.act === 'edit') {
      startEditing(i);
    } else {
      st.selectedCrit = st.selectedCrit === i ? -1 : i;
      renderCriteria();
      paintParamSource();
    }
  });
  $('.rq-segment').addEventListener('click', (e) => {
    if (!(e.target instanceof Element) || !e.target.closest('.rq-seg-clear')) return;
    edit((r) => { r.refinements = []; r.probeSelection = null; r.objectIds = null; }, 'Segment retiré.');
  });
  $('.rq-junction').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-j]') : null;
    if (!b || key(store.recipe.junction) === b.dataset.j) return;
    edit((r) => { r.junction = b.dataset.j; }, b.dataset.j === 'any' ? 'Au moins un critère doit être vrai.' : 'Tous les critères doivent être vrais.');
  });

  function junctionInk() {
    const seg = $('.rq-junction');
    const on = seg.querySelector('[aria-pressed="true"]');
    const thumb = seg.querySelector('.thumb');
    if (!on || !thumb) return;
    thumb.style.setProperty('--x', `${on.offsetLeft - 3}px`);
    thumb.style.setProperty('--w', `${on.offsetWidth}px`);
  }

  // ---------- Advanced tree ----------

  function renderTree() {
    const r = store.recipe;
    const rows = walk(r.expression);
    const host = $('.rq-tree');
    panel.querySelector('[data-fold="advanced"] .rq-fold-badge').innerHTML = rows.length ? `<span class="k-badge info">${rows.length}</span>` : '';
    if (!rows.length) {
      st.selectedPath = '';
      host.innerHTML = `<p class="rq-tree-empty">${glyph('tree')}Aucun groupe : ajoutez un groupe ET, OU ou NON pour composer des conditions imbriquées (8 niveaux, 256 éléments au plus).</p>`;
    } else {
      if (!rows.some((x) => x.path === st.selectedPath)) st.selectedPath = rows[0].path;
      host.innerHTML = rows.map((x, n) => {
        const k = key(x.node.kind);
        return `<div class="rq-node" role="treeitem" aria-level="${x.depth + 1}" aria-selected="${x.path === st.selectedPath}" tabindex="${x.path === st.selectedPath ? 0 : -1}" data-path="${esc(x.path)}" data-kind="${esc(k)}" data-depth="${x.depth}" data-i="${n}">
          <span class="rq-node-guide" aria-hidden="true"></span><span class="rq-node-kind">${k === 'clause' ? glyph('filter') : esc({ all: 'ET', any: 'OU', not: 'NON', collection: 'COLL.' }[k] ?? k)}</span>
          <span class="rq-node-label">${esc(nodeLabel(x.node, store))}</span></div>`;
      }).join('');
      vars(host);
    }
    renderInstanceControls();
  }

  function selectedNode() {
    return st.selectedPath === null ? null : nodeAt(store.recipe.expression, st.selectedPath);
  }

  function collectionOfSelection() {
    const rows = walk(store.recipe.expression);
    const sel = rows.find((x) => x.path === st.selectedPath);
    if (!sel) return null;
    if (key(sel.node.kind) === 'collection') return { path: sel.path, probe: String(sel.node.collectionField).replace(/^probe:/, '') };
    if (sel.collection) {
      const owner = rows.filter((x) => key(x.node.kind) === 'collection' && sel.path.startsWith(`${x.path}/`)).pop();
      return owner ? { path: owner.path, probe: sel.collection } : null;
    }
    return null;
  }

  function treeAdd(element) {
    const next = clone(store.recipe);
    if (!next.expression) {
      next.expression = group('all', [element]);
      store.setRecipe(next);
      st.selectedPath = '/0';
      return;
    }
    const at = targetGroupPath(next.expression, st.selectedPath ?? '');
    const { node } = nodeAt(next.expression, at);
    if (!node || !['all', 'any'].includes(key(node.kind))) { store.toast('Sélectionnez un groupe ET ou OU.', 'warn'); return; }
    node.children = [...(node.children ?? []), element];
    st.selectedPath = `${at}/${node.children.length - 1}`;
    store.setRecipe(next);
  }

  panel.querySelector('.rq-tree-tools').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-tree]') : null;
    if (!b) return;
    const act = b.dataset.tree;
    if (act === 'all' || act === 'any') treeAdd(group(act));
    else if (act === 'not') treeAdd({ kind: 'not', clause: null, children: [group('all')], collectionField: null, quantifier: null });
    else if (act === 'clause') {
      const clause = builderClause();
      if (!clause) return;
      if (String(clause.field).startsWith('instance:')) { store.toast('Une propriété d’instance s’ajoute dans un groupe de collection.', 'warn'); return; }
      treeAdd({ kind: 'clause', clause, children: [], collectionField: null, quantifier: null });
    } else if (act === 'clear') {
      if (!store.recipe.expression) return;
      edit((r) => { r.expression = null; }, 'Arbre de conditions effacé.');
    } else if (act === 'remove' || act === 'up' || act === 'down') {
      const next = clone(store.recipe);
      if (!next.expression) return;
      const { parent, index } = nodeAt(next.expression, st.selectedPath);
      if (!parent) {
        if (act === 'remove') { next.expression = null; store.setRecipe(next); }
        return;
      }
      if (act === 'remove') {
        if (['not', 'collection'].includes(key(parent.kind)) && parent.children.length <= 1) {
          store.toast('Ce groupe exige un élément : retirez plutôt le groupe NON ou la collection entière.', 'warn');
          return;
        }
        parent.children.splice(index, 1);
        st.selectedPath = st.selectedPath.split('/').slice(0, -1).join('/');
      } else {
        const other = act === 'up' ? index - 1 : index + 1;
        if (other < 0 || other >= parent.children.length) return;
        [parent.children[index], parent.children[other]] = [parent.children[other], parent.children[index]];
        st.selectedPath = `${st.selectedPath.split('/').slice(0, -1).join('/')}/${other}`;
      }
      store.setRecipe(next);
    }
  });
  $('.rq-tree').addEventListener('click', (e) => {
    const row = e.target instanceof Element ? e.target.closest('.rq-node') : null;
    if (!row) return;
    st.selectedPath = row.dataset.path;
    renderTree();
    $(`.rq-node[data-path="${CSS.escape(st.selectedPath)}"]`)?.focus();
  });
  $('.rq-tree').addEventListener('keydown', (e) => {
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End', 'Delete'].includes(e.key)) return;
    e.preventDefault();
    if (e.key === 'Delete') { panel.querySelector('[data-tree="remove"]').click(); return; }
    const rows = [...panel.querySelectorAll('.rq-node')];
    const at = rows.findIndex((x) => x.dataset.path === st.selectedPath);
    const next = e.key === 'Home' ? 0 : e.key === 'End' ? rows.length - 1 : Math.max(0, Math.min(rows.length - 1, at + (e.key === 'ArrowDown' ? 1 : -1)));
    st.selectedPath = rows[next]?.dataset.path ?? st.selectedPath;
    renderTree();
    $(`.rq-node[data-path="${CSS.escape(st.selectedPath)}"]`)?.focus();
  });

  function renderInstanceControls() {
    const probe = $('.rq-coll-probe');
    if (!probe.options.length) probe.innerHTML = st.collections.map((c) => `<option value="${esc(c.id)}">${esc(c.name)}</option>`).join('') || '<option value="">Aucune collection</option>';
    const coll = collectionOfSelection();
    const fieldSel = $('.rq-inst-field');
    const fields = coll ? st.instanceFields.filter((f) => f.id.startsWith(`instance:${coll.probe}:`)) : [];
    fieldSel.disabled = !coll;
    $('.rq-inst-add').disabled = !coll;
    fieldSel.innerHTML = fields.length ? fields.map((f) => `<option value="${esc(f.id)}">${esc(f.name)}</option>`).join('') : '<option value="">Sélectionnez une collection dans l’arbre</option>';
    renderInstanceOps();
  }

  function renderInstanceOps() {
    const f = st.instanceFields.find((x) => x.id === $('.rq-inst-field').value);
    $('.rq-inst-op').innerHTML = opsOf(f).map((op) => `<option value="${op}">${esc(OPERATOR_LABEL[op])}</option>`).join('');
  }

  $('.rq-inst-field').addEventListener('change', renderInstanceOps);
  $('.rq-coll-add').addEventListener('click', () => {
    const field = $('.rq-coll-probe').value;
    if (!field) return;
    treeAdd({ kind: 'collection', clause: null, children: [group('all')], collectionField: field, quantifier: $('.rq-coll-q').value });
  });
  $('.rq-inst-add').addEventListener('click', () => {
    const coll = collectionOfSelection();
    const fieldId = $('.rq-inst-field').value;
    if (!coll || !fieldId) return;
    const op = $('.rq-inst-op').value;
    const raw = $('.rq-inst-val').value;
    const f = st.instanceFields.find((x) => x.id === fieldId);
    let value = null;
    if (!NO_VALUE.has(op)) {
      if (key(f?.kind) === 'boolean') value = /^(oui|vrai|true|1)$/i.test(raw.trim());
      else if (key(f?.kind) === 'number') value = Number(raw.replace(',', '.'));
      else value = raw;
      if (key(f?.kind) === 'number' && !Number.isFinite(value)) { store.toast('Saisissez un nombre pour cette propriété.', 'warn'); return; }
    }
    const next = clone(store.recipe);
    const { node } = nodeAt(next.expression, coll.path);
    if (!node.children?.length) node.children = [group('all')];
    node.children[0].children = [...(node.children[0].children ?? []), { kind: 'clause', clause: { field: fieldId, operator: op, value }, children: [], collectionField: null, quantifier: null }];
    store.setRecipe(next);
    $('.rq-inst-val').value = '';
  });

  // ---------- Parameters ----------

  /** Typed number of a bound typed by the operator (« 8 », « 10,5 »), null when empty; NaN when unreadable. */
  const bound = (text) => (text.trim() ? Number(text.trim().replace(/\s/g, '').replace(',', '.')) : null);

  /** The criterion selected in « Vos critères » becomes the source of a new parameter; numbers take bounds. */
  function paintParamSource() {
    const clause = store.recipe.clauses?.[st.selectedCrit];
    const f = clause ? fieldOf(store, clause.field) : null;
    $('.rq-param-from-text').textContent = clause
      ? `Critère choisi : ${clauseText(clause, f)}`
      : 'Sélectionnez un critère dans « Vos critères » : il devient un paramètre nommé, sa valeur se change ici.';
    const numeric = key(f?.kind) === 'number';
    panel.querySelectorAll('.rq-param-new .num').forEach((el) => { el.hidden = !numeric; });
    $('.rq-param-add').disabled = !clause;
  }

  function paramInput(d, f, current) {
    if (key(f?.kind) === 'boolean' || f?.choices?.length) {
      const choices = f.choices?.length ? f.choices : [{ name: 'Oui', value: true }, { name: 'Non', value: false }];
      return `<span class="k-select sm"><select class="input rq-param-value" data-name="${esc(d.name)}">${choices.map((c) => `<option value="${esc(String(c.value))}"${String(c.value) === String(current) ? ' selected' : ''}>${esc(c.name)}</option>`).join('')}</select></span>`;
    }
    return `<input class="input sm rq-param-value" data-name="${esc(d.name)}" type="text" maxlength="4096" autocomplete="off" spellcheck="false" value="${esc(current === null || current === undefined ? '' : String(current))}">`;
  }

  function renderParams() {
    const rows = store.validation?.parameters ?? [];
    const defs = store.recipe.parameters ?? [];
    panel.querySelector('[data-fold="params"] .rq-fold-badge').innerHTML = defs.length ? `<span class="k-badge accent">${defs.length}</span>` : '';
    paintParamSource();
    const host = $('.rq-param-list');
    if (!defs.length) {
      host.innerHTML = `<p class="rq-note">${glyph('info')}Aucun paramètre : une valeur paramétrée se change sans recréer la requête (et sans toucher à ses autres critères).</p>`;
      return;
    }
    host.innerHTML = defs.map((d, n) => {
      const row = rows.find((x) => x.name === d.name);
      const f = fieldOf(store, d.field);
      const current = store.recipe.parameterValues?.[d.name] ?? d.default;
      const scopeKind = d.field === 'dn' ? 'dn' : d.field === 'site' ? 'site' : null;
      return `<div class="rq-param-row" data-name="${esc(d.name)}" data-i="${n}">
        <div class="rq-param-id"><b>${esc(row?.label ?? d.label ?? d.name)}</b><span><span class="rq-mono">${esc(d.name)}</span> · ${esc(f?.name ?? d.field)}</span></div>
        <div class="rq-param-edit">${paramInput(d, f, current)}
          <button type="button" class="btn xs subtle" data-param="apply" data-name="${esc(d.name)}">Appliquer la valeur</button>
          ${scopeKind ? `<button type="button" class="btn xs ghost" data-param="scope" data-name="${esc(d.name)}" data-tip="${esc(scopeKind === 'dn' ? 'Insère le chemin AD de l’OU suivie' : 'Insère le nom de l’OU suivie')}">${glyph('ou')}OU de travail</button>` : ''}
          <button type="button" class="btn xs ghost icon" data-param="remove" data-name="${esc(d.name)}" aria-label="Retirer le paramètre ${esc(d.name)}" data-tip="Retirer le paramètre">${glyph('x')}</button></div>
        <p class="rq-param-check" data-check="${esc(d.name)}" aria-live="polite">${esc(row?.hint ?? '')}</p></div>`;
    }).join('');
    vars(host);
  }

  /**
   * Live check of a parameter value before « Appliquer » (Domenia 1 LblQueryParameterCheck): numbers converted by the engine
   * (units included) and checked against the bounds, texts checked for length. Returns the typed value, or undefined.
   */
  async function checkParam(name) {
    const def = (store.recipe.parameters ?? []).find((p) => p.name === name);
    const input = panel.querySelector(`.rq-param-value[data-name="${CSS.escape(name)}"]`);
    const out = panel.querySelector(`[data-check="${CSS.escape(name)}"]`);
    const apply = panel.querySelector(`[data-param="apply"][data-name="${CSS.escape(name)}"]`);
    if (!def || !input || !out) return undefined;
    const f = fieldOf(store, def.field);
    const say = (text, tone) => { out.textContent = text; out.className = `rq-param-check ${tone}`; if (apply) apply.disabled = tone === 'bad'; };
    if (key(f?.kind) === 'boolean') { say(input.value === 'true' ? 'Valeur retenue : Oui' : 'Valeur retenue : Non', 'ok'); return input.value === 'true'; }
    if (f?.choices?.length) {
      const choice = f.choices.find((c) => String(c.value) === input.value);
      say(`Valeur retenue : ${choice?.name ?? input.value}`, 'ok');
      return choice ? choice.value : input.value;
    }
    const text = input.value;
    if (!text.trim()) { say('Renseignez une valeur.', 'bad'); return undefined; }
    if (key(f?.kind) === 'number') {
      const res = await store.call('requetes.value.preview', { target: store.recipe.target, field: def.field, text });
      if (!store.alive) return undefined;
      const p = res.data;
      if (!p?.valid || !Number.isFinite(p.value)) { say(p?.text || res.message || 'Nombre illisible.', 'bad'); return undefined; }
      if (def.minimum !== null && def.minimum !== undefined && p.value < def.minimum) { say(`${p.text} : en dessous du minimum (${valueText(def.minimum, f)}).`, 'bad'); return undefined; }
      if (def.maximum !== null && def.maximum !== undefined && p.value > def.maximum) { say(`${p.text} : au-dessus du maximum (${valueText(def.maximum, f)}).`, 'bad'); return undefined; }
      say(p.text || `Valeur retenue : ${valueText(p.value, f)}`, 'ok');
      return p.value;
    }
    if (text.length > 4096) { say('Texte limité à 4 096 caractères.', 'bad'); return undefined; }
    say(`Valeur retenue : ${valueText(text, f)}`, 'ok');
    return text;
  }
  const checkLater = debounce((name) => { checkParam(name); }, 200);
  $('.rq-param-list').addEventListener('input', (e) => {
    const input = e.target instanceof HTMLElement ? e.target.closest('.rq-param-value') : null;
    if (input) checkLater(input.dataset.name);
  });
  $('.rq-param-list').addEventListener('change', (e) => {
    const input = e.target instanceof HTMLElement ? e.target.closest('select.rq-param-value') : null;
    if (input) checkParam(input.dataset.name);
  });

  $('.rq-param-add').addEventListener('click', () => {
    const name = $('.rq-param-name').value.trim();
    const label = $('.rq-param-label').value.trim();
    const i = st.selectedCrit;
    if (i < 0 || !store.recipe.clauses[i]) { store.toast('Sélectionnez d’abord un critère dans « Vos critères ».', 'warn'); return; }
    if (!/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(name)) { store.toast('Nom technique : une lettre, puis lettres, chiffres ou _ (64 au plus).', 'warn'); $('.rq-param-name').focus(); return; }
    if ((store.recipe.parameters ?? []).some((p) => p.name === name)) { store.toast('Ce nom de paramètre existe déjà.', 'warn'); return; }
    if ((store.recipe.parameters ?? []).length >= 32) { store.toast('32 paramètres au plus par requête.', 'warn'); return; }
    const clause = store.recipe.clauses[i];
    if (NO_VALUE.has(key(clause.operator)) || (clause.value && typeof clause.value === 'object')) { store.toast('Ce critère n’a pas de valeur à paramétrer.', 'warn'); return; }
    const f = fieldOf(store, clause.field);
    let minimum = null;
    let maximum = null;
    if (key(f?.kind) === 'number') {
      minimum = bound($('.rq-param-min').value);
      maximum = bound($('.rq-param-max').value);
      if (Number.isNaN(minimum) || Number.isNaN(maximum)) { store.toast('Bornes : nombres décimaux seulement (10 ou 10,5).', 'warn'); return; }
      if (minimum !== null && maximum !== null && minimum > maximum) { store.toast('Le minimum dépasse le maximum.', 'warn'); return; }
      if (typeof clause.value === 'number' && ((minimum !== null && clause.value < minimum) || (maximum !== null && clause.value > maximum))) {
        store.toast('La valeur actuelle du critère sort des bornes choisies.', 'warn');
        return;
      }
    }
    edit((r) => {
      r.parameters = [...(r.parameters ?? []), { name, field: clause.field, default: clause.value, label: label || null, minimum, maximum }];
      r.clauses[i] = { ...clause, value: { parameter: name } };
    }, `Paramètre ${name} créé.`);
    $('.rq-param-name').value = '';
    $('.rq-param-label').value = '';
    $('.rq-param-min').value = '';
    $('.rq-param-max').value = '';
  });
  $('.rq-param-freeze').addEventListener('click', () => {
    const r = store.recipe;
    if (!(r.parameters ?? []).length) return;
    const values = Object.fromEntries((r.parameters ?? []).map((p) => [p.name, r.parameterValues?.[p.name] ?? p.default]));
    const fix = (c) => (c?.value && typeof c.value === 'object' && c.value.parameter ? { ...c, value: values[c.value.parameter] } : c);
    const fixNode = (n) => (n ? { ...n, clause: n.clause ? fix(n.clause) : n.clause, children: (n.children ?? []).map(fixNode) } : n);
    edit((x) => {
      x.clauses = x.clauses.map(fix);
      x.refinements = (x.refinements ?? []).map(fix);
      x.expression = fixNode(x.expression);
      x.parameters = [];
      x.parameterValues = null;
    }, 'Valeurs des paramètres fixées.');
  });
  $('.rq-param-list').addEventListener('click', async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-param]') : null;
    if (!b) return;
    const name = b.dataset.name;
    const r = store.recipe;
    const def = (r.parameters ?? []).find((p) => p.name === name);
    if (!def) return;
    if (b.dataset.param === 'apply') {
      const value = await checkParam(name);
      if (value === undefined) { store.toast('Valeur refusée : voir le contrôle sous le champ.', 'warn'); return; }
      edit((x) => { x.parameterValues = { ...(x.parameterValues ?? {}), [name]: value }; }, `Valeur du paramètre ${name} appliquée.`);
    } else if (b.dataset.param === 'scope') {
      const scope = store.scope?.effective;
      if (!scope || store.scope?.wholeDomain) { store.toast('Aucune OU suivie : le domaine entier ne sert pas de paramètre.', 'warn'); return; }
      const value = def.field === 'site' ? scope.label : scope.dn;
      edit((x) => { x.parameterValues = { ...(x.parameterValues ?? {}), [name]: value }; }, `Paramètre ${name} : ${scope.label}.`);
    } else {
      const fix = (c) => (c?.value && typeof c.value === 'object' && c.value.parameter === name ? { ...c, value: def.default } : c);
      const fixNode = (n) => (n ? { ...n, clause: n.clause ? fix(n.clause) : n.clause, children: (n.children ?? []).map(fixNode) } : n);
      edit((x) => {
        x.clauses = x.clauses.map(fix);
        x.refinements = (x.refinements ?? []).map(fix);
        x.expression = fixNode(x.expression);
        x.parameters = x.parameters.filter((p) => p.name !== name);
        if (x.parameterValues) delete x.parameterValues[name];
      }, `Paramètre ${name} retiré.`);
    }
  });

  // ---------- Coherence ----------

  function renderCoherence() {
    const h = store.recipe.coherenceHours;
    const input = $('.rq-coh-hours');
    if (document.activeElement !== input) input.value = h ?? '';
    panel.querySelector('[data-fold="coherence"] .rq-fold-badge').innerHTML = h ? `<span class="k-badge info">${esc(String(h))}${NBSP}h</span>` : '';
  }
  $('.rq-coh-apply').addEventListener('click', () => {
    const h = Number($('.rq-coh-hours').value);
    if (!(h > 0 && h <= 8760)) { store.toast('Saisissez un écart de plus de 0 et d’au plus 8 760 heures.', 'warn'); return; }
    edit((r) => { r.coherenceHours = h; }, `Fenêtre de cohérence : ${h} heures.`);
  });
  $('.rq-coh-clear').addEventListener('click', () => edit((r) => { r.coherenceHours = null; }, 'Aucune contrainte de cohérence.'));
  $('.rq-coh-check').addEventListener('click', () => api.openCoverage());

  // ---------- LDAP ----------

  st.editor = createLdapEditor($('.rq-ldap-host'), { label: 'Filtre LDAP de la requête', onInput: () => { st.ldapDirty = true; paintLdapState('typing'); readLdap(); } });

  const readLdap = debounce(async () => {
    const text = st.editor.text();
    if (!text.trim()) { paintLdapState('empty'); return; }
    const version = store.version;
    const res = await store.call('requetes.ldap.read', { text, recipe: store.recipe });
    if (!store.alive) return;
    if (res.error) { paintLdapState('error', res.message); return; }
    const reading = res.data;
    if (!reading.valid) {
      st.editor.setError(reading.position);
      paintLdapState('error', reading.error);
      return;
    }
    st.editor.clearError();
    if (version !== store.version && !st.editor.typing()) return;
    st.ldapDirty = false;
    store.setRecipe(reading.recipe, { origin: 'ldap' });
    paintLdapState('synced', reading.warnings?.join(' ') ?? '');
  }, 450);

  function paintLdapState(state, message = '') {
    const pillHtml = {
      synced: '<span class="k-pill ok sm"><span class="k-pill-dot"></span>Synchronisé</span>',
      typing: '<span class="k-pill info sm"><span class="k-spin" aria-hidden="true"></span>Lecture du texte…</span>',
      error: '<span class="k-pill alert sm"><span class="k-pill-dot"></span>Filtre refusé</span>',
      partial: '<span class="k-pill warn sm"><span class="k-pill-dot"></span>Partie annuaire</span>',
      empty: '<span class="k-pill off sm"><span class="k-pill-dot"></span>Vide</span>',
    }[state] ?? '';
    $('.rq-ldap-state').innerHTML = pillHtml;
    const msg = $('.rq-ldap-msg');
    msg.textContent = message;
    msg.className = `rq-ldap-msg ${state}`;
  }

  function renderLdap() {
    const v = store.validation;
    const ldap = v?.ldap;
    const local = $('.rq-ldap-local');
    if (!ldap) {
      if (v && !v.valid) paintLdapState('error', v.errors?.[0] ?? '');
      return;
    }
    const partial = !ldap.exact;
    const locked = partial && !st.ldapUnlocked;
    st.editor.setLocked(locked);
    $('.rq-ldap-unlock').hidden = !locked;
    if (!st.ldapDirty && !st.editor.typing()) st.editor.setText(ldap.pretty, { flash: true });
    $('.rq-prefilter-text').textContent = ldap.preFilter;
    local.hidden = !(ldap.residual?.length || ldap.notes?.length);
    local.innerHTML = `${ldap.residual?.length ? `<b>${glyph('layers')}Évalué localement après la lecture</b><ul>${ldap.residual.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>` : ''}
      ${ldap.notes?.length ? `<ul class="rq-ldap-notes">${ldap.notes.map((x) => `<li>${glyph('info')}${esc(x)}</li>`).join('')}</ul>` : ''}`;
    if (!st.ldapDirty) paintLdapState(partial ? 'partial' : 'synced', partial ? 'Le texte montre les conditions que l’annuaire sait évaluer ; les autres restent locales.' : '');
  }

  $('.rq-ldap-copy').addEventListener('click', async () => {
    const text = store.validation?.ldap?.filter ?? st.editor.text();
    await writeClipboard(text);
    store.toast('Filtre LDAP copié.', 'ok');
  });
  $('.rq-ldap-cmd').addEventListener('click', async () => {
    const cmd = store.validation?.command;
    if (!cmd) { store.toast('La requête n’est pas valide : rien à copier.', 'warn'); return; }
    await writeClipboard(cmd);
    store.toast('Commande PowerShell copiée (lecture seule).', 'ok');
  });
  $('.rq-ldap-unlock').addEventListener('click', () => {
    st.ldapUnlocked = true;
    st.editor.setLocked(false);
    $('.rq-ldap-unlock').hidden = true;
    st.editor.focus();
    store.toast('Modifier le texte remplacera les conditions par le seul filtre LDAP.', 'warn');
  });

  // ---------- Summary ----------

  function renderSummary() {
    const v = store.validation;
    const issues = $('.rq-issues');
    const stateEl = $('.rq-sum-state');
    if (!v) { stateEl.innerHTML = '<span class="k-pill info sm"><span class="k-spin"></span>Validation…</span>'; return; }
    // A valid draft without condition is not « all good »: every object matches, said in the same tone as the warning below.
    stateEl.innerHTML = !v.valid ? '<span class="k-pill alert sm"><span class="k-pill-dot"></span>À corriger</span>'
      : v.conditionCount ? '<span class="k-pill ok sm"><span class="k-pill-dot"></span>Critères valides</span>'
        : '<span class="k-pill warn sm"><span class="k-pill-dot"></span>Sans condition</span>';
    $('.rq-sum-format').textContent = v.valid ? `${v.conditionCount ? plural(v.conditionCount, 'condition', 'conditions') : 'Aucune condition'} · format ${v.format}${v.fingerprint ? ` · empreinte ${v.fingerprint.slice(0, 12)}` : ''}` : 'La requête ne peut pas être évaluée en l’état.';
    issues.innerHTML = [...(v.errors ?? []).map((t) => `<li class="err">${glyph('alert')}${esc(t)}</li>`), ...(v.warnings ?? []).map((t) => `<li class="warn">${glyph('info')}${esc(t)}</li>`)].join('');
    const quiet = ['Aucune contrainte', 'Aucune', 'Aucun'];
    const items = [];
    for (const line of v.summary ?? []) {
      if (['Nom', 'Répartition', 'Cible'].includes(line.element)) continue;
      if (line.element === 'Conditions avancées') {
        // The tree keeps its shape: guides and kinds, as in « Conditions avancées » (never ASCII depth marks).
        if (v.outline?.length) items.push({ element: line.element, tree: v.outline });
        continue;
      }
      line.values.filter((val) => val && !quiet.includes(val)).forEach((val, n) => items.push({ element: line.element, val, cont: n > 0 }));
    }
    const kind = (k) => ({ all: 'ET', any: 'OU', not: 'NON', collection: 'COLL.' }[key(k)] ?? '');
    $('.rq-outline').innerHTML = items.map((x, n) => (x.tree
      ? `<li data-i="${n}" class="tree"><span>${esc(x.element)}</span><ol class="rq-mini-tree">${x.tree.map((r) => `<li data-depth="${r.depth}" data-kind="${esc(key(r.kind))}"><span class="rq-mt-guide" aria-hidden="true"></span>${kind(r.kind) ? `<span class="rq-mt-kind">${kind(r.kind)}</span>` : `<span class="rq-mt-dot" aria-hidden="true"></span>`}<span class="rq-mt-label">${esc(r.label)}</span></li>`).join('')}</ol></li>`
      : `<li data-i="${n}"${x.cont ? ' class="cont"' : ''}><span>${x.cont ? '' : esc(x.element)}</span><b>${esc(x.val)}</b></li>`)).join('');
    vars($('.rq-outline'));
    $('.rq-go-preview').disabled = !v.valid;
  }

  function renderGroupBy() {
    const sel = $('.rq-groupby-select');
    const current = store.recipe.groupBy ?? '';
    const groupable = st.fields.filter((f) => f.groupable);
    sel.innerHTML = `<option value="">Compteur d’objets (pas de répartition)</option>${groupable.map((f) => `<option value="${esc(f.id)}"${f.id === current ? ' selected' : ''}>${esc(f.name)}</option>`).join('')}`;
    sel.value = current;
  }
  $('.rq-groupby-select').addEventListener('change', (e) => {
    const value = e.target.value || null;
    edit((r) => { r.groupBy = value; }, value ? 'Répartition choisie.' : 'Compteur d’objets.');
  });
  $('.rq-go-preview').addEventListener('click', () => api.runPreview());
  $('.rq-go-save').addEventListener('click', () => api.goto('enregistrer'));

  // ---------- Catalog and events ----------

  async function loadCatalog() {
    const target = key(store.recipe.target);
    $('.rq-builder-target').innerHTML = `<span class="k-pill info sm">${glyph({ computer: 'monitor', user: 'user', group: 'group' }[target] ?? 'object')}${esc({ computer: 'Postes', user: 'Utilisateurs', group: 'Groupes' }[target])}</span>`;
    try {
      const { data } = await resolvedCatalog(store, target);
      if (!store.alive) return;
      // The raw LDAP attributes of the schema are informations of the builder too (their own category, LDAP semantics).
      st.fields = [...data.fields, ...(data.ldapFields ?? [])];
      st.collections = data.collections ?? [];
      st.instanceFields = data.instanceFields ?? [];
      $('.rq-coll-probe').innerHTML = '';
      const keep = st.field && st.fields.some((f) => f.id === st.field.id) ? st.field.id : null;
      if (!st.combo) {
        st.combo = createFieldCombo($('.rq-field-host'), {
          label: 'Information à filtrer',
          fields: st.fields,
          value: keep,
          onChange: (f) => setField(f),
          onBrowse: () => api.goto('informations'),
        });
      } else {
        st.combo.setFields(st.fields, keep);
      }
      if (!keep) {
        const first = st.fields.find((f) => f.id === 'os') ?? st.fields.find((f) => f.id === 'department') ?? st.fields.find((f) => f.id === 'scope') ?? null;
        setField(first);
        st.combo.setValue(first?.id ?? null);
      }
      renderGroupBy();
      renderAll();
    } catch (err) {
      console.error(err);
      $('.rq-field-host').innerHTML = emptyState('alert', 'Catalogue indisponible', 'Le catalogue des informations n’a pas pu être lu.');
    }
  }

  function renderAll() {
    renderCriteria();
    renderTree();
    renderParams();
    renderCoherence();
    renderSummary();
    renderLdap();
  }

  /** Puts an information of the catalog in the builder and focuses the value (Utiliser cette information). */
  function useField(id) {
    const f = st.fields.find((x) => x.id === id);
    if (!f) return;
    st.combo?.setValue(id);
    setField(f);
    requestAnimationFrame(() => panel.querySelector('.rq-value-host input:not([disabled]), .rq-value-host select, .rq-value-host button')?.focus());
  }

  const offs = [
    store.on('recipe', ({ origin }) => {
      if (origin !== 'ldap') st.ldapDirty = false;
      if (origin === 'load' || origin === 'target') { st.ldapUnlocked = false; st.selectedCrit = -1; stopEditing(); }
      if (origin === 'load' || origin === 'draft') applyFolds();
      renderCriteria();
      renderTree();
      renderParams();
      renderCoherence();
      $('.rq-groupby-select').value = store.recipe.groupBy ?? '';
    }),
    store.on('validation', () => { renderSummary(); renderParams(); renderLdap(); renderTree(); }),
    store.on('target', () => { st.field = null; loadCatalog(); }),
    store.on('scope', () => renderParams()),
  ];

  /** A loaded recipe shows what it uses: advanced conditions, parameters and coherence unfold when present. */
  function applyFolds() {
    panel.querySelector('[data-fold="advanced"]').open = !!store.recipe.expression;
    panel.querySelector('[data-fold="params"]').open = (store.recipe.parameters ?? []).length > 0;
    panel.querySelector('[data-fold="coherence"]').open = !!store.recipe.coherenceHours;
  }

  renderHelp();
  renderOps();
  renderValue();
  applyFolds();
  loadCatalog();

  return {
    useField,
    destroy() {
      offs.forEach((off) => off());
      stopReveal();
      st.combo?.destroy();
    },
  };
}
