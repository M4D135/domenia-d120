// Relations tab: a map of the object among the others — its manager (or managedBy) above, its team on the left, its associated
// workstations or users on the right, what it manages below — drawn with animated links (transform only), each node opening
// its fiche; then the detail of what exists only: associations with their evidence badge and rule, never a percentage
// (FIC-046, FIC-047, Domenia-Relations), the team and the managed objects. Local base only: nothing read on the network.
import { glyph, pill, int, NBSP } from '../../kit/index.js';
import { esc, errorText, applyVars } from '../../ui.js';
import { avatar, emptyNote, failure, kindOf, skeleton, initialsOf, stamp, plural } from './common.js';

const MAX_NODES = 6;

/**
 * @param {HTMLElement} panel
 * @param {any} S
 */
export function mountRelations(panel, S) {
  let token = 0;

  const evidenceTone = (e) => (e === 'declared' ? 'ok' : e === 'observed' || e === 'remote' ? 'info' : e === 'history' ? 'off' : 'warn');

  const node = (l, n, extra = '') => `<button type="button" class="fi-map-node" data-open="${esc(l.dn)}" data-j="${n}" data-tip="${esc(l.detail ? `${l.detail} · ${l.dn}` : l.dn)}">
      ${avatar(l.kind, initialsOf(l.name), 'sm')}<span class="fi-map-name">${esc(l.name)}</span>${extra}</button>`;

  /** One cluster of the map: its title and count, up to six nodes, « +n » beyond, a ghost when it is empty. */
  function cluster(where, title, icon, items, empty, mapNode = node) {
    const shown = items.slice(0, MAX_NODES);
    return `<div class="fi-map-cluster ${where}${items.length ? '' : ' empty'}" data-where="${where}">
      <span class="fi-map-head">${glyph(icon)}<b>${esc(title)}</b><span class="fi-map-count">${int(items.length)}</span></span>
      ${items.length ? `<div class="fi-map-nodes">${shown.map((l, n) => mapNode(l, n)).join('')}${items.length > MAX_NODES ? `<span class="fi-map-more">+${int(items.length - MAX_NODES)}</span>` : ''}</div>`
        : `<span class="fi-map-ghost">${esc(empty)}</span>`}
    </div>`;
  }

  const linkRow = (l, n, extra = '') => `<button type="button" class="fi-rel-row" data-open="${esc(l.dn)}" data-j="${n}" data-tip="${esc(l.dn)}">
      ${avatar(l.kind, initialsOf(l.name), 'sm')}<span class="fi-rel-body"><span class="fi-rel-name">${esc(l.name)}</span><span class="fi-rel-sub">${esc(l.detail ?? kindOf(l.kind).label)}</span></span>${extra}
      <span class="fi-rel-go" aria-hidden="true">${glyph('chevronRight')}</span></button>`;

  function markup(r) {
    const me = S.sheet.identity;
    const person = me.kind === 'user' || me.kind === 'contact';
    const assoc = r.associations ?? [];
    const upper = r.manager ?? r.managedBy;
    const reports = r.reports ?? [];
    const manages = r.manages ?? [];
    const assocLinks = assoc.map((a) => ({ dn: a.dn, name: a.name, kind: a.kind, detail: `${a.evidenceLabel} · ${a.source}${a.when ? ` · ${stamp(a.when)}` : ''}`, evidence: a.evidence, primary: a.primary }));
    const assocNode = (l, n) => node(l, n, `<span class="fi-map-badge" data-tone="${evidenceTone(l.evidence)}" aria-hidden="true"></span>${l.primary ? `<span class="fi-primary">${glyph('star')}</span>` : ''}`);
    const map = `<section class="fi-map card fi-card fi-enter" aria-label="Carte des relations de ${esc(me.name)}">
      <span class="fi-map-glow" aria-hidden="true"></span>
      <div class="fi-map-grid">
        <div class="fi-map-cell top">${cluster('top', person ? 'Responsable' : 'Géré par', 'user', upper ? [upper] : [], person ? 'Aucun responsable (attribut manager vide)' : 'Personne (attribut managedBy vide)')}</div>
        <span class="fi-map-link v up${upper ? '' : ' faint'}" aria-hidden="true"></span>
        <div class="fi-map-cell left">${cluster('left', 'Équipe', 'users', reports, me.kind === 'user' ? 'Aucun compte rattaché' : 'Sans objet pour ce type')}</div>
        <span class="fi-map-link h left${reports.length ? '' : ' faint'}" aria-hidden="true"></span>
        <div class="fi-map-me" data-kind="${esc(kindOf(me.kind).hue)}">${avatar(me.kind, me.initials, 'md')}<span class="fi-map-me-text"><b>${esc(me.name)}</b><span>${esc(me.kindLabel)}</span></span></div>
        <span class="fi-map-link h right${assoc.length ? '' : ' faint'}" aria-hidden="true"></span>
        <div class="fi-map-cell right">${cluster('right', me.kind === 'computer' ? 'Utilisateurs associés' : 'Postes associés', me.kind === 'computer' ? 'user' : 'monitor', assocLinks,
          me.kind === 'computer' ? 'Aucune association connue' : me.kind === 'user' ? 'Présence inconnue, pas « aucun poste »' : 'Sans objet pour ce type', assocNode)}</div>
        <span class="fi-map-link v down${manages.length ? '' : ' faint'}" aria-hidden="true"></span>
        <div class="fi-map-cell bottom">${cluster('bottom', 'Objets gérés', 'shield', manages, 'Aucun objet géré (managedBy)')}</div>
      </div>
      <div class="fi-map-legend"><span><i data-tone="ok"></i>Déclarée</span><span><i data-tone="info"></i>Observée</span><span><i data-tone="off"></i>Historique</span><span>${glyph('star')}Relation principale</span></div>
    </section>`;
    const details = [];
    if (assoc.length) {
      details.push(`<section class="card fi-card fi-enter" data-j="1"><div class="card-head"><span class="card-icon">${glyph(me.kind === 'computer' ? 'user' : 'monitor')}</span>
        <div class="fi-card-titles"><h3>${me.kind === 'computer' ? 'Utilisateurs associés' : 'Postes associés'}</h3><p class="fi-card-sub">Badge et règle de chaque association, jamais un pourcentage</p></div>
        <span class="meta"><span class="chip">${int(assoc.length)}</span></span></div>
        <div class="fi-rel-list">${assoc.map((a, n) => linkRow({ dn: a.dn, name: a.name, kind: a.kind, detail: `${a.source}${a.when ? ` · ${stamp(a.when)}` : ''} · ${a.rule}` }, n,
          `${a.primary ? `<span class="fi-primary" data-tip="Relation principale${NBSP}: déclarée d’abord, sinon la plus récente">${glyph('star')}</span>` : ''}${pill(evidenceTone(a.evidence), a.evidenceLabel, { size: 'sm', tip: a.rule })}`)).join('')}</div></section>`);
    }
    if (upper) {
      details.push(`<section class="card fi-card fi-enter" data-j="2"><div class="card-head"><span class="card-icon">${glyph('user')}</span><div class="fi-card-titles"><h3>${person ? 'Responsable' : 'Géré par'}</h3>
        <p class="fi-card-sub">${person ? 'Attribut manager' : 'Attribut managedBy'} · se règle en mode modification de l’onglet Général</p></div></div>
        <div class="fi-rel-list">${linkRow(upper, 0)}</div></section>`);
    }
    if (reports.length) {
      details.push(`<section class="card fi-card fi-enter" data-j="3"><div class="card-head"><span class="card-icon">${glyph('users')}</span><div class="fi-card-titles"><h3>Équipe</h3>
        <p class="fi-card-sub">Comptes dont ${esc(me.name)} est le responsable</p></div><span class="meta"><span class="chip">${int(reports.length)}</span></span></div>
        <div class="fi-rel-list scroll">${reports.map((l, n) => linkRow(l, n)).join('')}</div></section>`);
    }
    if (manages.length) {
      details.push(`<section class="card fi-card fi-enter" data-j="4"><div class="card-head"><span class="card-icon">${glyph('shield')}</span><div class="fi-card-titles"><h3>Objets gérés</h3>
        <p class="fi-card-sub">Postes, groupes et OU dont l’objet est le gestionnaire (managedBy)</p></div><span class="meta"><span class="chip">${int(manages.length)}</span></span></div>
        <div class="fi-rel-list scroll">${manages.map((l, n) => linkRow(l, n)).join('')}</div></section>`);
    }
    const total = (upper ? 1 : 0) + reports.length + assoc.length + manages.length;
    return `<div class="fi-rel">${map}
      ${details.length ? `<div class="fi-cards ${details.length > 1 ? 'fi-cards-2' : ''}">${details.join('')}</div>` : ''}
      <p class="fi-note">${glyph('info')}${esc(total ? `${plural(total, 'relation connue', 'relations connues')}. ${r.note}` : `Aucune relation connue dans la base locale. ${r.note}`)}</p></div>`;
  }

  async function load() {
    const my = ++token;
    panel.innerHTML = `<section class="card fi-card fi-map">${skeleton(6)}</section>`;
    try {
      const r = await S.ctx.call('fiche.relations', { dn: S.sheet.identity.dn });
      if (my !== token || !S.alive) return;
      panel.innerHTML = markup(r);
      applyVars(panel);
    } catch (err) {
      if (my !== token) return;
      panel.innerHTML = `<section class="card fi-card">${failure(err)}</section>`;
    }
  }

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const open = t?.closest('[data-open]');
    if (open) { S.open(open.dataset.open); return; }
    if (t?.closest('[data-retry]')) load();
  };
  panel.addEventListener('click', onClick);
  load();
  return { update() {}, refresh: load, destroy() { panel.removeEventListener('click', onClick); } };
}

export { errorText, emptyNote };
