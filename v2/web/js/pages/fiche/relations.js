// Relations tab: manager and team (FIC-011, FIC-047), managedBy and what the object manages, associations between users and
// workstations with their evidence badge and rule, never a percentage (FIC-046, FIC-047, Domenia-Relations).
import { glyph, pill, int } from '../../kit/index.js';
import { esc, errorText, applyVars, formatDateTime } from '../../ui.js';
import { avatar, emptyNote, failure, kindOf, skeleton } from './common.js';

/**
 * @param {HTMLElement} panel
 * @param {any} S
 */
export function mountRelations(panel, S) {
  let token = 0;

  const linkRow = (l, n, extra = '') => `<button type="button" class="fi-rel-row" data-open="${esc(l.dn)}" data-j="${n}" data-tip="${esc(l.dn)}">
      ${avatar(l.kind, initialsOf(l.name), 'sm')}<span class="fi-rel-body"><span class="fi-rel-name">${esc(l.name)}</span><span class="fi-rel-sub">${esc(l.detail ?? kindOf(l.kind).label)}</span></span>${extra}
      <span class="fi-rel-go" aria-hidden="true">${glyph('chevronRight')}</span></button>`;

  function markup(r) {
    const me = S.sheet.identity;
    const assoc = r.associations ?? [];
    const evidenceTone = (e) => (e === 'declared' ? 'ok' : e === 'observed' || e === 'remote' ? 'info' : e === 'history' ? 'off' : 'warn');
    const assocRows = assoc.map((a, n) => linkRow({ dn: a.dn, name: a.name, kind: a.kind, detail: `${a.source}${a.when ? ` · ${formatDateTime(a.when) ?? ''}` : ''}` }, n,
      `${a.primary ? `<span class="fi-primary" data-tip="Relation principale : déclarée d’abord, sinon la plus récente">${glyph('star')}</span>` : ''}${pill(evidenceTone(a.evidence), a.evidenceLabel, { size: 'sm', tip: a.rule })}`)).join('');
    const upper = r.manager ?? r.managedBy;
    const upperTitle = me.kind === 'user' || me.kind === 'contact' ? 'Responsable' : 'Géré par';
    const reports = r.reports ?? [];
    const manages = r.manages ?? [];
    // Map below the object: team first, then associations, then managed objects (each object once).
    const seen = new Set();
    const kids = [...reports, ...assoc, ...manages].filter((k) => k?.dn && !seen.has(k.dn.toLowerCase()) && seen.add(k.dn.toLowerCase()));
    return `<div class="fi-rel">
      <div class="fi-rel-map fi-enter" aria-hidden="true">
        <div class="fi-rel-node up${upper ? '' : ' none'}">${upper ? `${avatar(upper.kind, initialsOf(upper.name), 'sm')}<span>${esc(upper.name)}</span>` : `<span>${esc(upperTitle)} : aucun</span>`}</div>
        <span class="fi-rel-line v"></span>
        <div class="fi-rel-node me">${avatar(me.kind, me.initials, 'md')}<span>${esc(me.name)}</span></div>
        ${kids.length ? `<div class="fi-rel-kids">${kids.slice(0, 6).map((k, i) => `<span class="fi-rel-kid" data-j="${i}">${avatar(k.kind, initialsOf(k.name), 'sm')}${esc(k.name)}</span>`).join('')}
          ${kids.length > 6 ? `<span class="fi-rel-kid more" data-j="6">+${int(kids.length - 6)}</span>` : ''}</div>` : ''}
        <div class="fi-rel-fan">
          <span class="fi-rel-count"><b>${int(reports.length)}</b> dans l’équipe</span>
          <span class="fi-rel-count"><b>${int(assoc.length)}</b> association${assoc.length > 1 ? 's' : ''}</span>
          <span class="fi-rel-count"><b>${int(manages.length)}</b> géré${manages.length > 1 ? 's' : ''}</span>
        </div>
      </div>
      <div class="fi-cards fi-cards-2">
        <section class="card fi-card fi-enter" data-j="1"><div class="card-head"><span class="card-icon">${glyph('user')}</span><div class="fi-card-titles"><h3>${esc(upperTitle)}</h3>
          <p class="fi-card-sub">${me.kind === 'user' ? 'Attribut manager' : 'Attribut managedBy'}</p></div></div>
          ${upper ? `<div class="fi-rel-list">${linkRow(upper, 0)}</div>` : emptyNote('user', 'Aucun', 'Se règle depuis l’onglet Général, en mode modification.')}</section>
        <section class="card fi-card fi-enter" data-j="2"><div class="card-head"><span class="card-icon">${glyph(me.kind === 'computer' ? 'user' : 'monitor')}</span>
          <div class="fi-card-titles"><h3>${me.kind === 'computer' ? 'Utilisateurs associés' : 'Postes associés'}</h3><p class="fi-card-sub">Badge et règle de chaque association ; aucun pourcentage</p></div>
          <span class="meta"><span class="chip">${int(assoc.length)}</span></span></div>
          ${assoc.length ? `<div class="fi-rel-list">${assocRows}</div>` : emptyNote('link', 'Aucune association', me.kind === 'user' ? 'Associations illisibles : présence inconnue, pas « aucun poste ».' : 'Aucune association connue.')}</section>
        ${me.kind === 'user' ? `<section class="card fi-card fi-enter" data-j="3"><div class="card-head"><span class="card-icon">${glyph('users')}</span><div class="fi-card-titles"><h3>Équipe</h3>
          <p class="fi-card-sub">Comptes dont ${esc(me.name)} est le responsable</p></div><span class="meta"><span class="chip">${int(reports.length)}</span></span></div>
          ${reports.length ? `<div class="fi-rel-list scroll">${reports.map((l, n) => linkRow(l, n)).join('')}</div>` : emptyNote('users', 'Aucun compte rattaché')}</section>` : ''}
        <section class="card fi-card fi-enter" data-j="4"><div class="card-head"><span class="card-icon">${glyph('shield')}</span><div class="fi-card-titles"><h3>Objets gérés</h3>
          <p class="fi-card-sub">Postes, groupes et OU dont l’objet est le gestionnaire (managedBy)</p></div><span class="meta"><span class="chip">${int(manages.length)}</span></span></div>
          ${manages.length ? `<div class="fi-rel-list scroll">${manages.map((l, n) => linkRow(l, n)).join('')}</div>` : emptyNote('shield', 'Aucun objet géré')}</section>
      </div>
      <p class="fi-note">${glyph('info')}${esc(r.note)}</p></div>`;
  }

  async function load() {
    const my = ++token;
    panel.innerHTML = `<div class="fi-cards fi-cards-2"><section class="card fi-card">${skeleton(5)}</section><section class="card fi-card">${skeleton(5)}</section></div>`;
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

function initialsOf(name) {
  const words = String(name ?? '').split(/[\s,.\-_]+/).filter((w) => /[\p{L}\p{N}]/u.test(w));
  if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
  return words[0] ? words[0].slice(0, 2) : '?';
}

export { errorText };
