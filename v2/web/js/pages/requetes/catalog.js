// « Informations »: catalog of what a query can ask for each target (directory, local computations, readings of the
// workstations, WMI probes), with its source, type, unit, freshness, cost and example; and the LDAP attributes known to the
// engine with their syntax. « Utiliser cette information » puts it in the builder of « Créer ».
import {
  esc, glyph, key, plural, TARGETS, sourcePill, OPERATOR_LABEL, resolvedCatalog,
} from './shared.js';
import { createGrid, createSplit, createTabs, writeClipboard } from '../../kit/index.js';
import { reveal, inkFollow } from '../../ui.js';

const SOURCE_OPTIONS = [
  { value: 'ad', label: 'Annuaire AD', tone: 'info' },
  { value: 'local', label: 'Calcul local', tone: 'ok' },
  { value: 'observation', label: 'Relevé du poste', tone: 'warn' },
  { value: 'probe', label: 'Sonde WMI', tone: 'warn' },
  { value: 'detail', label: 'SELECT mémorisé', tone: 'warn' },
  { value: 'ldap', label: 'LDAP', tone: 'off' },
];

export function mountCatalog(panel, store, api) {
  const st = { target: key(store.recipe.target) ?? 'computer', grid: null, ldapGrid: null, tabs: null, fields: [], token: 0 };
  panel.innerHTML = `<section class="card rq-catalog spot reveal" aria-labelledby="rq-cat-title">
    <div class="card-head"><span class="card-icon">${glyph('layers')}</span><div class="rq-head-titles"><h3 id="rq-cat-title">Informations interrogeables</h3>
      <p class="rq-sub rq-cat-sub">Ce que chaque cible sait dire, d’où vient la valeur et ce qu’elle coûte.</p></div>
      <div class="segmented rq-cat-target" role="radiogroup" aria-label="Cible du catalogue"><span class="thumb" aria-hidden="true"></span>${TARGETS.map((t) => `<button type="button" role="radio" data-target="${t.id}" aria-checked="${t.id === st.target}">${glyph(t.icon)}${esc(t.label)}</button>`).join('')}</div></div>
    <div class="rq-cat-tabs"></div>
  </section>`;
  const $ = (sel) => panel.querySelector(sel);

  const fieldColumns = [
    { id: 'name', label: 'Information', required: true, width: 340, get: (f) => f.name },
    { id: 'source', label: 'Source', type: 'enum', width: 150, get: (f) => key(f.source), options: SOURCE_OPTIONS },
    { id: 'category', label: 'Catégorie', width: 170, get: (f) => f.category },
    { id: 'unit', label: 'Unité', width: 132, get: (f) => f.unit || null },
    { id: 'typeLabel', label: 'Type', width: 110, get: (f) => f.typeLabel },
    { id: 'groupable', label: 'Répartition', type: 'bool', width: 110, get: (f) => !!f.groupable },
    { id: 'ldapAttribute', label: 'Attribut LDAP', mono: true, width: 190, get: (f) => f.ldapAttribute ?? null },
    { id: 'freshness', label: 'Fraîcheur', width: 220, hidden: true, get: (f) => f.freshness },
    { id: 'cost', label: 'Coût', width: 200, hidden: true, get: (f) => f.cost },
    { id: 'technical', label: 'Détail technique', mono: true, width: 300, hidden: true, get: (f) => f.technical ?? null },
    { id: 'id', label: 'Identifiant', mono: true, width: 220, hidden: true, get: (f) => f.id },
    { id: 'description', label: 'Description', width: 380, hidden: true, get: (f) => f.description },
  ];
  const ldapColumns = [
    { id: 'name', label: 'Attribut', required: true, mono: true, width: 240, get: (a) => a.name },
    { id: 'syntax', label: 'Syntaxe', width: 200, get: (a) => a.syntax },
    { id: 'read', label: 'Lu par Domenia', type: 'enum', width: 150, get: (a) => (a.read ? 'yes' : 'no'),
      options: [{ value: 'yes', label: 'Lu et évalué', tone: 'ok' }, { value: 'no', label: 'Non lu (indéfini)', tone: 'warn' }] },
    { id: 'description', label: 'Description', width: 380, get: (a) => a.description },
    { id: 'example', label: 'Exemple', mono: true, width: 260, get: (a) => a.example },
  ];

  function fieldDetail(f) {
    if (!f) return `<div class="rq-detail-empty">${glyph('layers')}<p><b>Choisissez une information</b>Sa source, sa fraîcheur, son coût et un exemple s’affichent ici.</p></div>`;
    const ops = (f.operators ?? []).map((o) => OPERATOR_LABEL[key(o)] ?? o);
    return `<div class="rq-detail-in rq-field-card">
      <header class="rq-detail-head"><span class="avatar">${glyph({ ad: 'database', local: 'zap', observation: 'wifi', probe: 'chip', detail: 'chip', ldap: 'hash' }[key(f.source)] ?? 'info')}</span>
        <div class="rq-detail-titles"><h4>${esc(f.name)}</h4><span>${esc(f.category)}</span></div>${sourcePill(f.source)}</header>
      <p class="rq-lib-desc">${esc(f.description || 'Pas de description.')}</p>
      <div class="rq-detail-actions"><button type="button" class="btn primary sm rq-use-field">${glyph('plus')}Utiliser cette information</button>
        <button type="button" class="btn ghost sm rq-copy-id">${glyph('copy')}Copier l’identifiant</button></div>
      <dl class="rq-facts">
        <div><dt>Type</dt><dd><span>${esc(f.typeLabel)}${f.unit ? ` · ${esc(f.unit)}` : ''}</span></dd></div>
        ${f.example ? `<div><dt>Exemple</dt><dd><span>${esc(f.example)}</span></dd></div>` : ''}
        <div><dt>Fraîcheur</dt><dd><span>${esc(f.freshness)}</span></dd></div>
        <div><dt>Collecte</dt><dd><span>${esc(f.collection)}</span></dd></div>
        <div><dt>Disponibilité</dt><dd><span>${esc(f.availability)}</span></dd></div>
        <div><dt>Coût</dt><dd><span>${esc(f.cost)}</span></dd></div>
        ${f.technical ? `<div><dt>Détail technique</dt><dd><span class="rq-mono">${esc(f.technical)}</span></dd></div>` : ''}
        ${f.ldapAttribute ? `<div><dt>Attribut LDAP</dt><dd><span class="rq-mono">${esc(f.ldapAttribute)}</span></dd></div>` : ''}
        ${ops.length ? `<div><dt>Conditions</dt><dd>${ops.map((o) => `<span class="chip sm">${esc(o)}</span>`).join('')}</dd></div>` : ''}
        ${f.choices?.length ? `<div><dt>Valeurs</dt><dd>${f.choices.slice(0, 24).map((c) => `<span class="chip sm">${esc(c.name)}</span>`).join('')}${f.choices.length > 24 ? `<span class="chip sm">+${f.choices.length - 24}</span>` : ''}</dd></div>` : ''}
      </dl>
      <p class="rq-note">${glyph('info')}Une valeur absente, expirée ou illisible rend la condition « Inconnue » : jamais comptée comme fausse.</p>
    </div>`;
  }

  function mountFields(p) {
    const listNode = document.createElement('div');
    const detailNode = document.createElement('div');
    detailNode.className = 'rq-detail rq-cat-detail';
    detailNode.innerHTML = fieldDetail(null);
    createSplit(p, { a: listNode, b: detailNode, key: 'requetes.informations.detail', size: 440, min: 320, max: 720, label: 'Taille du détail de l’information' });
    st.showField = (f) => {
      detailNode.innerHTML = fieldDetail(f);
      if (!f) return;
      detailNode.querySelector('.rq-use-field')?.addEventListener('click', () => use(f));
      detailNode.querySelector('.rq-copy-id')?.addEventListener('click', async () => { await writeClipboard(f.id); store.toast('Identifiant copié.', 'ok'); });
    };
    const showField = st.showField;
    st.grid = createGrid(listNode, {
      key: 'requetes.informations',
      label: 'Informations interrogeables',
      columns: fieldColumns,
      rowId: (f) => f.id,
      selection: 'single',
      height: '560px',
      loading: true,
      quickPlaceholder: 'Chercher une information…',
      empty: { icon: 'search', title: 'Aucune information', text: 'Aucune information ne correspond à ce texte.' },
      onActiveChange: (f) => showField(f),
      onActivate: (f) => use(f),
      contextMenu: ({ row }) => [{ label: 'Utiliser cette information', icon: 'plus', kbd: 'Entrée', disabled: !row, run: () => use(row) }],
    });
    load();
  }

  function mountLdap(p) {
    st.ldapGrid = createGrid(p, {
      key: 'requetes.attributs',
      label: 'Attributs LDAP connus',
      columns: ldapColumns,
      rowId: (a) => a.name,
      selection: 'single',
      height: '560px',
      loading: true,
      quickPlaceholder: 'Chercher un attribut…',
      contextMenu: ({ row }) => [
        { label: 'Utiliser cet attribut dans une condition', icon: 'plus', kbd: 'Entrée', disabled: !row, run: () => useAttribute(row) },
        { label: 'Copier le nom', icon: 'copy', disabled: !row, run: async () => { await writeClipboard(row.name); store.toast('Nom de l’attribut copié.', 'ok'); } },
      ],
      onActivate: (a) => useAttribute(a),
    });
    load();
  }

  async function load() {
    const my = ++st.token;
    try {
      const { data } = await resolvedCatalog(store, st.target);
      if (!store.alive || my !== st.token) return;
      st.fields = [...data.fields, ...(data.instanceFields ?? [])];
      st.grid?.setRows(st.fields);
      st.showField?.(st.fields[0] ?? null);
      st.ldapGrid?.setRows(data.ldapAttributes ?? []);
      st.tabs?.setCount('fields', st.fields.length);
      st.tabs?.setCount('ldap', (data.ldapAttributes ?? []).length);
      const bySource = new Map();
      for (const f of data.fields) bySource.set(key(f.source), (bySource.get(key(f.source)) ?? 0) + 1);
      $('.rq-cat-sub').textContent = `${plural(data.fields.length, 'information', 'informations')}${data.instanceFields?.length ? ` et ${plural(data.instanceFields.length, 'propriété d’instance', 'propriétés d’instance')}` : ''} · ${[...bySource].map(([s, n]) => `${SOURCE_OPTIONS.find((o) => o.value === s)?.label ?? s} ${n}`).join(' · ')}`;
    } catch (err) {
      console.error(err);
      st.grid?.setError('Le catalogue n’a pas pu être lu.', { retry: load });
    }
  }

  /** A raw LDAP attribute becomes a condition of the visual builder (any target; LDAP semantics: an absent attribute is false). */
  function useAttribute(a) {
    if (!a) return;
    if (!a.read) store.toast(`« ${a.name} » n’est pas conservé par Domenia : sa condition restera inconnue en local, le contrôleur l’évaluera en mode annuaire.`, 'info');
    api.useField(`ldap:${a.name}`);
  }

  function use(f) {
    if (!f) return;
    if (key(f.source) === 'instance' || String(f.id).startsWith('instance:')) {
      store.toast('Une propriété d’instance s’utilise dans « Conditions avancées », sous une collection.', 'info');
    }
    if (st.target !== key(store.recipe.target)) {
      store.toast('Cette information concerne une autre cible : changez la cible de la requête d’abord.', 'warn');
      return;
    }
    api.useField(f.id);
  }

  st.tabs = createTabs($('.rq-cat-tabs'), {
    label: 'Catalogue',
    key: 'requetes.catalogue.onglet',
    tabs: [
      { id: 'fields', label: 'Informations', icon: 'layers', render: mountFields },
      { id: 'ldap', label: 'Attributs LDAP', icon: 'hash', render: mountLdap },
    ],
  });

  panel.querySelectorAll('[data-target]').forEach((b) => b.addEventListener('click', () => {
    st.target = b.dataset.target;
    panel.querySelectorAll('[data-target]').forEach((x) => x.setAttribute('aria-checked', String(x === b)));
    ink.update();
    st.grid?.setLoading(true);
    load();
  }));
  const ink = inkFollow($('.rq-cat-target'), '[data-target]', '[aria-checked="true"]');
  const stopReveal = reveal(panel);
  const offs = [store.on('target', () => {
    const t = key(store.recipe.target);
    if (t === st.target) return;
    panel.querySelector(`[data-target="${t}"]`)?.click();
  })];

  return {
    destroy() {
      offs.forEach((off) => off());
      ink.stop();
      stopReveal();
      st.grid?.destroy();
      st.ldapGrid?.destroy();
      st.tabs?.destroy();
    },
  };
}
