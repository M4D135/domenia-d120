// Detail pane of the schema browser: a class (inheritance and auxiliary classes, then the attributes an object may carry, then
// how to target it in a filter) or an attribute (how to use it in a filter first, then its flags, its definition and the
// classes that declare it). The essential part comes first, the figures stay on one line. Data from schema.class and
// schema.attribute (docs/ops/schema.md § 5 and 6); rendering only, the browser wires the gestures.
import { createGrid } from '../../kit/grid.js';
import { applyVars } from '../../ui.js';
import {
  glyph, esc, int, count, NBSP, chip, codeLine, sk, indexTone, categoryTone, KIND_ICONS,
} from './model.js';

/** Placeholder shown before any choice. */
export function placeholder(kind) {
  const attributes = kind === 'attributes';
  return `<div class="sch-detail-empty">
    <div class="sch-orbit" aria-hidden="true"><span class="orb-ring o1"></span><span class="orb-ring o2"></span><span class="core">${glyph(attributes ? 'tag' : 'layers')}</span></div>
    <h3>${attributes ? 'Choisissez un attribut' : 'Choisissez une classe'}</h3>
    <p>${attributes
    ? 'Son exemple de critère de filtre, son type, son nombre de valeurs et ses index s’affichent ici.'
    : 'Tous les attributs qu’un objet de cette classe peut porter, sa chaîne d’héritage et ses classes auxiliaires s’affichent ici.'}</p>
    <ul class="sch-tips">
      <li>${glyph('search')}<span>Filtrez la liste par nom ou par description${NBSP}: rien n’est relu.</span></li>
      <li>${glyph('sort')}<span>Flèches ↑ ↓ pour parcourir, Entrée pour ouvrir.</span></li>
    </ul>
  </div>`;
}

export function skeleton() {
  return `<div class="sch-detail-sk" aria-busy="true">
    <div class="sch-dhead">${sk('sch-sk-ico')}<div class="sch-sk-stack">${sk('w30')}${sk('sch-sk-title w55')}${sk('w85')}</div></div>
    <div class="sch-sk-stack">${sk('w100 sch-sk-block')}${sk('w70')}${sk('w85')}${sk('w55')}</div>
  </div>`;
}

function head({ icon, kind, kicker, name, description, chips, oid }) {
  return `<header class="sch-dhead">
    <span class="sch-dicon ${kind}">${glyph(icon)}</span>
    <div class="sch-dtitles">
      <div class="sch-dkicker">${esc(kicker)}</div>
      <h3 class="sch-dname">${esc(name)}<button class="btn ghost icon xs sch-copy" type="button" data-copy="${esc(name)}" aria-label="Copier le nom LDAP" data-tip="Copier le nom LDAP">${glyph('copy')}</button></h3>
      ${description ? `<p class="sch-ddesc">${esc(description)}</p>` : '<p class="sch-ddesc muted">Aucune description dans le schéma.</p>'}
      <div class="sch-dchips">${chips}${oid ? `<span class="sch-oid" data-tip="Identifiant d’objet (OID) de la définition">OID ${esc(oid)}</span>` : ''}</div>
    </div>
  </header>`;
}

/** Figures on one line: « 145 possibles · 7 obligatoires · 138 facultatifs ». */
function figures(items) {
  return `<p class="sch-figures">${items.map(([value, one, many, tone], j) => `<span class="f${tone ? ` ${tone}` : ''}" data-j="${j}"><b>${esc(int(value))}</b> ${esc(value > 1 ? many : one)}</span>`).join('<span class="sep" aria-hidden="true">·</span>')}</p>`;
}

// ---------------------------------------------------------------- class

// Narrow pane: the star says « obligatoire » (its column stays in the chooser), the type takes the width left.
const ATTRIBUTE_COLUMNS = [
  {
    id: 'name', label: 'Attribut', required: true, width: 150, mono: true,
    html: (v, r) => `<span class="sch-attr-cell${r.defunct ? ' defunct' : ''}">${r.required ? `<span class="sch-req" aria-label="Obligatoire" data-tip="Obligatoire">${glyph('star')}</span>` : ''}<span class="n">${esc(v)}</span></span>`,
  },
  {
    id: 'required', label: 'Obligatoire', type: 'enum', width: 116, hidden: true,
    get: (r) => (r.required ? 'oui' : 'non'),
    options: [{ value: 'oui', label: 'Obligatoire', tone: 'accent' }, { value: 'non', label: 'Facultatif', tone: 'off' }],
  },
  {
    id: 'indexText', label: 'Index', type: 'enum', width: 124,
    options: [
      { value: 'Indexé', label: 'Indexé', tone: 'ok' }, { value: 'Indexé, sous-chaîne comprise', label: 'Sous-chaîne', tone: 'ok' },
      { value: 'Non indexé', label: 'Non indexé', tone: 'off' }, { value: 'Calculé, non filtrable', label: 'Calculé', tone: 'warn' },
    ],
  },
  { id: 'values', label: 'Valeurs', width: 90, hidden: true },
  { id: 'inGlobalCatalog', label: 'Catalogue global', type: 'bool', width: 130, hidden: true },
  { id: 'origin', label: 'Défini par', width: 160, mono: true, hidden: true },
  { id: 'description', label: 'Description', width: 320, hidden: true },
  { id: 'syntaxLabel', label: 'Type', width: 110 },
];

/**
 * Renders a class into host. Returns { destroy, grid }.
 * @param {HTMLElement} host @param {any} d SchemaClassDetail
 * @param {{ onAttribute: (name: string) => void, onSelectAttribute?: (row: any) => void }} handlers
 */
export function renderClass(host, d, handlers) {
  const supers = [...d.superclasses].reverse();
  const auxiliaries = d.lineage.filter((l) => l.relation === 'auxiliary');
  const missingNote = d.missing.length
    ? `<p class="sch-note warn">${glyph('alert')}<span>${esc(count(d.missing.length, 'attribut est cité par la classe mais absent du schéma lu', 'attributs sont cités par la classe mais absents du schéma lu'))}${NBSP}: ${esc(d.missing.join(', '))}.</span></p>` : '';
  const walkNote = d.walkTruncated
    ? `<p class="sch-note warn">${glyph('alert')}<span>Parcours arrêté à 256 classes (boucle du schéma)${NBSP}: la liste peut être incomplète.</span></p>` : '';
  host.innerHTML = `<article class="sch-detail cls">
    ${head({
    icon: 'layers', kind: 'cls', kicker: `Classe · ${d.categoryLabel}`, name: d.name, description: d.description, oid: d.oid,
    chips: chip(categoryTone(d.categoryLabel), d.categoryLabel) + (d.defunct ? chip('alert', 'Obsolète', { icon: 'alert', tip: 'Classe désactivée : aucun nouvel objet ne peut en être.' }) : ''),
  })}
    <section class="sch-block sch-lineage" aria-label="Chaîne d’héritage et classes auxiliaires">
      <ol class="sch-chain" aria-label="Chaîne d’héritage, de top à ${esc(d.name)}">
        ${supers.map((name, j) => `<li data-j="${j}"><button class="sch-node${name === d.name ? ' now' : ''}" type="button" data-goto-class="${esc(name)}"${name === d.name ? ' aria-current="true"' : ''}>${esc(name)}</button></li>`).join('')}
      </ol>
      ${auxiliaries.length ? `<div class="sch-aux"><span class="sch-aux-k">${glyph('plus')}Auxiliaires</span>${auxiliaries.map((a, j) => `<button class="sch-node aux${a.known ? '' : ' unknown'}" type="button" data-j="${j}" data-goto-class="${esc(a.name)}" data-tip="${esc(a.known ? `Ajoutée par ${a.via}` : 'Absente du schéma lu')}">${esc(a.name)}</button>`).join('')}</div>` : ''}
      <span class="sch-walk">${esc(count(d.chain.length, 'classe parcourue', 'classes parcourues'))}, auxiliaires comprises</span>
    </section>
    ${missingNote}${walkNote}
    <section class="sch-block sch-attrs">
      <div class="sch-attrs-head">
        <h4>Attributs possibles</h4>
        ${figures([
    [d.attributes.length, 'possible', 'possibles'],
    [d.requiredCount, 'obligatoire', 'obligatoires', 'accent'],
    [d.optionalCount, 'facultatif', 'facultatifs'],
  ])}
      </div>
      <div class="sch-attr-grid"></div>
    </section>
    <section class="sch-block sch-filterbox">
      <h4>Cibler cette classe dans un filtre</h4>
      <div class="sch-filter-rows">
        <span class="sch-label">Direct</span>${codeLine(d.filter, { label: 'Copier le filtre' })}
        <span class="sch-label good">${glyph('check')}Recommandé</span>${codeLine(d.recommendedFilter, { label: 'Copier le filtre recommandé' })}
      </div>
      ${d.recommendedNote ? `<p class="sch-note warn">${glyph('alert')}<span>${esc(d.recommendedNote)}</span></p>` : ''}
      <div class="sch-filter-foot">
        <p class="sch-advice">${glyph('info')}<span>${esc(d.filterAdvice)}</span></p>
        <button class="btn sm" type="button" data-analyze="${esc(d.recommendedFilter)}">${glyph('gauge')}Analyser le filtre recommandé</button>
      </div>
    </section>
    ${d.subclasses.length ? `<section class="sch-block"><h4>Classes dérivées</h4><div class="sch-node-row">${d.subclasses.map((s, j) => `<button class="sch-node" type="button" data-j="${j}" data-goto-class="${esc(s)}">${esc(s)}</button>`).join('')}</div></section>` : ''}
  </article>`;
  applyVars(host);
  const grid = createGrid(host.querySelector('.sch-attr-grid'), {
    key: 'schema.classe.attributs.v2',
    label: `Attributs possibles de la classe ${d.name}`,
    columns: ATTRIBUTE_COLUMNS,
    rowId: (r) => r.name,
    selection: 'single',
    density: 'compact',
    height: 'fill',
    quickPlaceholder: 'Filtrer ces attributs…',
    empty: { icon: 'tag', title: 'Aucun attribut', text: 'Cette classe ne déclare aucun attribut, même par héritage.' },
    onActivate: (row) => handlers.onAttribute(row.name),
    onSelectionChange: (rows) => handlers.onSelectAttribute?.(rows[0] ?? null),
    contextMenu: ({ row }) => [
      { label: 'Ouvrir le détail', icon: 'tag', kbd: 'Entrée', disabled: !row, reason: 'Choisissez une ligne.', run: () => handlers.onAttribute(row.name) },
    ],
  });
  grid.setRows(d.attributes);
  return { grid, destroy: () => grid.destroy() };
}

// ---------------------------------------------------------------- attribute

/** « Indexé » → « indexé », but « RODC » or « ANR » keep their capitals. */
const lowerFirst = (text) => (/^[A-ZÀ-Ý][a-zà-ÿ]/.test(text) ? text[0].toLowerCase() + text.slice(1) : text);

/** Flags that are set, as pills; the others on one muted line (the full set of Domenia 1 stays readable). */
function flagRow(flags) {
  const on = flags.filter((f) => f.on);
  const off = flags.filter((f) => !f.on);
  return `<div class="sch-flags" aria-label="Indicateurs de l’attribut">
      ${on.length ? on.map((f, j) => `<span class="sch-flag ${esc(f.tone)}" data-j="${j}" data-tip="${esc(f.tip)}">${glyph('check')}${esc(f.label)}</span>`).join('') : '<span class="muted">Aucun indicateur particulier.</span>'}
    </div>
    ${off.length ? `<p class="sch-flags-off"><span class="k">Sans${NBSP}:</span> ${off.map((f) => `<span data-tip="${esc(f.tip)}">${esc(lowerFirst(f.label))}</span>`).join(', ')}.</p>` : ''}`;
}

function fact(label, value, { mono = false, sub = '' } = {}) {
  const shown = value === null || value === undefined || value === '' ? '<span class="none" aria-label="non renseigné">—</span>' : esc(value);
  return `<div class="sch-fact"><dt>${esc(label)}</dt><dd class="${mono ? 'mono' : ''}">${shown}${sub ? `<small>${esc(sub)}</small>` : ''}</dd></div>`;
}

/**
 * Renders an attribute into host.
 * @param {HTMLElement} host @param {any} d SchemaAttributeDetail
 * @param {{ backClass?: string|null }} o
 */
export function renderAttribute(host, d, o) {
  const tone = indexTone(d.indexText);
  const insertReason = d.insertReason ?? '';
  host.innerHTML = `<article class="sch-detail attr">
    ${o.backClass ? `<button class="sch-back" type="button" data-goto-class="${esc(o.backClass)}">${glyph('chevronLeft')}Retour à la classe ${esc(o.backClass)}</button>` : ''}
    ${head({
    icon: KIND_ICONS[d.kind] ?? 'tag', kind: 'attr', kicker: `Attribut · ${d.syntaxLabel}`, name: d.name, description: d.description, oid: d.oid,
    chips: chip(tone, d.indexText, { icon: tone === 'ok' ? 'zap' : undefined })
      + chip('off', d.valuesLabel)
      + (d.inGlobalCatalog ? chip('info', 'Catalogue global', { icon: 'domain' }) : '')
      + (d.constructed ? chip('warn', 'Calculé', { icon: 'sparkles' }) : '')
      + (d.defunct ? chip('alert', 'Obsolète', { icon: 'alert' }) : ''),
  })}
    <section class="sch-block sch-hint">
      <h4>Dans un filtre LDAP</h4>
      ${d.hint.example ? `<div class="sch-hint-row"><div class="sch-hint-ex"><span class="sch-label">Exemple de critère, à compléter</span>${codeLine(d.hint.example, { label: 'Copier l’exemple' })}</div>
        <button class="btn sm primary" type="button" data-insert="${esc(d.name)}"${d.insertable ? '' : ` aria-disabled="true" data-tip="${esc(insertReason)}"`}>${glyph('plus')}Ajouter au filtre</button></div>` : ''}
      ${d.insertable ? '' : `<p class="sch-reason">${glyph('info')}<span>${esc(insertReason)}</span></p>`}
      <ul class="sch-notes">${d.hint.notes.map((n, j) => `<li data-j="${j}">${glyph(n.startsWith('Attribut indexé') ? 'zap' : n.startsWith('Attribut obsolète') || n.startsWith('Attribut calculé') ? 'alert' : 'info')}<span>${esc(n)}</span></li>`).join('')}</ul>
    </section>
    <section class="sch-block"><h4>Indicateurs</h4>${flagRow(d.flags)}</section>
    <section class="sch-block">
      <h4>Définition</h4>
      <dl class="sch-facts">
        ${fact('Syntaxe', d.syntaxLabel, { sub: d.syntax })}
        ${fact('Valeurs', d.valuesLabel)}
        ${fact('Index', d.indexText)}
        ${fact('Plage', d.rangeLabel)}
        ${fact('Lien', d.linkLabel)}
        ${fact('Syntaxe XOM (oMSyntax)', d.omSyntax === null ? null : String(d.omSyntax), { mono: true })}
      </dl>
    </section>
    <section class="sch-block">
      <h4>Classes qui le déclarent <span class="sch-h4-note">${esc(d.usedByTotal ? count(d.usedByTotal, 'classe', 'classes') : 'aucune')}</span></h4>
      ${d.usedBy.length
    ? `<div class="sch-node-row">${d.usedBy.map((u, j) => `<button class="sch-node${u.required ? ' req' : ''}" type="button" data-j="${j}" data-goto-class="${esc(u.name)}" data-tip="${esc(u.required ? 'Obligatoire dans cette classe' : 'Facultatif dans cette classe')}">${u.required ? glyph('star') : ''}${esc(u.name)}</button>`).join('')}${d.usedByTotal > d.usedBy.length ? `<span class="sch-more">et ${esc(int(d.usedByTotal - d.usedBy.length))} autres</span>` : ''}</div>`
    : '<p class="muted">Aucune classe du schéma lu ne déclare cet attribut elle-même.</p>'}
    </section>
  </article>`;
  applyVars(host);
  return { destroy: () => {} };
}
