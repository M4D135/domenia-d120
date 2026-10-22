// Header of the fiche: kind, name, identifiers, state pills, origin and freshness, command bar (one primary action, one
// « Actions » menu ordered Aller à, Lire sur le réseau, Modifier, Zone sensible, each entry marked), DN breadcrumb with its menu
// (FIC-039: copy the DN or the name, open the parent), the support band of a user (FIC-048) and the key figures of the object,
// shown on every tab with the tile of the current tab highlighted. Updated in place when the fiche is read again (FIC-031).
import { createCommandBar, createDnBreadcrumb, freshness, startFreshness, glyph, openMenu, writeClipboard, NBSP, int } from '../../kit/index.js';
import { esc, applyVars, toast } from '../../ui.js';
import { avatar, kindOf, statePills, plural, day, stamp, nobr, presenceWords, ficon } from './common.js';

const ACTION_ICONS = {
  edit: 'edit', unlock: 'lock', resetPassword: 'key', expirePassword: 'key', expiration: 'calendar', options: 'sliders', enable: 'power',
  disable: 'power', move: 'ou', groupAdd: 'group', memberAdd: 'plus', createOu: 'plus', setScope: 'pin', delete: 'trash', lockouts: 'lock',
  logonByDc: 'server', compare: 'split', callSheet: 'lifebuoy', openPoste: 'monitor', presence: 'wifi', rights: 'shield', reread: 'refresh',
  copySummary: 'copy', openParent: 'ou', support: 'lifebuoy',
};

// Reads first, writes after, the destructive one last (KIT § 2.6.6: a write is never the first entry of a menu).
const GROUPS = [
  { heading: 'Aller à', ids: ['callSheet', 'support', 'openPoste', 'openParent', 'setScope', 'copySummary'] },
  { heading: 'Lire sur le réseau', ids: ['lockouts', 'logonByDc', 'presence', 'rights', 'compare'] },
  { heading: 'Modifier', ids: ['edit', 'unlock', 'enable', 'disable', 'expirePassword', 'resetPassword', 'expiration', 'options', 'move', 'groupAdd', 'memberAdd', 'createOu'] },
  { heading: 'Zone sensible', ids: ['delete'] },
];

/**
 * @param {HTMLElement} host
 * @param {any} S  Screen state (fiche.js).
 */
export function mountHeader(host, S) {
  let bar = null;
  let crumbs = null;
  let shown = '';

  function primaryId(sheet) {
    const usable = (id) => sheet.actions.find((a) => a.id === id && a.available);
    if (sheet.identity.kind === 'user' && sheet.account?.lock === 'locked' && usable('unlock')) return 'unlock';
    if (usable('edit')) return 'edit';
    return 'reread';
  }

  /** Actions of the sheet, plus « Résumé support » for a user (a local view of the facts already read). */
  function actionsOf(sheet) {
    const list = [...sheet.actions];
    if (sheet.identity.kind === 'user' && sheet.support?.length) list.push({ id: 'support', label: 'Résumé support', kind: 'local', available: true, reason: null, danger: false });
    return list;
  }

  function commands(sheet) {
    const primary = primaryId(sheet);
    const actions = actionsOf(sheet);
    const byId = new Map(actions.map((a) => [a.id, a]));
    const kindOfAction = (a) => (a.kind === 'write' ? 'write' : a.kind === 'network' ? 'network' : undefined);
    const items = [];
    const p = byId.get(primary);
    if (p) {
      items.push({ id: p.id, label: p.label, icon: ACTION_ICONS[p.id], kind: kindOfAction(p), primary: true, pinned: true, disabled: !p.available, reason: p.reason ?? undefined, run: () => S.act(p.id) });
    }
    const menu = [];
    for (const g of GROUPS) {
      const list = g.ids.map((id) => byId.get(id)).filter((a) => a && a.id !== primary && a.id !== 'reread');
      if (!list.length) continue;
      if (menu.length) menu.push('-');
      menu.push({ heading: g.heading });
      for (const a of list) {
        menu.push({ label: a.label, icon: ACTION_ICONS[a.id], kind: kindOfAction(a), danger: !!a.danger, disabled: !a.available, reason: a.reason ?? undefined, run: () => S.act(a.id) });
      }
    }
    items.push({ id: 'more', label: 'Actions', icon: 'more', items: menu, pinned: true });
    if (byId.has('reread')) items.push({ id: 'reread', label: 'Relire depuis l’annuaire', icon: 'refresh', kind: 'network', iconOnly: true, kbd: 'F5', pinned: true, run: () => S.act('reread') });
    if (byId.has('copySummary')) items.push({ id: 'copySummary', label: 'Copier le résumé', icon: 'copy', iconOnly: true, pinned: true, run: () => S.act('copySummary') });
    return items;
  }

  function origin(sheet) {
    const o = sheet.origin;
    // FIC-030: the date of the local values stays visible while the directory read runs.
    if (o.preview) {
      const at = o.readAt ? ` · valeurs du ${esc(stamp(o.readAt))}` : '';
      return `<span class="fi-origin preview" data-tip="${esc(o.detail)}">${glyph('database')}<span>Aperçu local${at}, relecture en cours</span><span class="fi-origin-pulse" aria-hidden="true"></span></span>`;
    }
    const label = o.source === 'simulation' ? 'Annuaire fictif' : 'Annuaire';
    return `<span class="fi-origin live" data-tip="${esc(o.detail)}">${glyph(o.source === 'simulation' ? 'sparkles' : 'server')}<span>${esc(label)}${o.controller ? ` · ${esc(o.controller)}` : ''}</span></span>`
      + freshness(o.readAt, { label: 'Lu', staleAfter: (sheet.freshness.find((f) => f.nature === 'attributes')?.validitySeconds || 900) * 1000, source: o.controller ?? label });
  }

  function band(sheet) {
    const b = sheet.band;
    if (!b) return '';
    // FIC-048: the band offers the unlock and the 4740 read as subtle shortcuts; the header command bar keeps the primary action.
    return `<section class="fi-band reveal" data-tone="${esc(b.tone)}" role="status">
      <span class="fi-band-ico">${glyph(b.tone === 'alert' ? 'alert' : 'eye')}</span>
      <div class="fi-band-body"><p class="fi-band-alerts">${b.alerts.map((a, n) => `<span class="fi-band-alert" data-j="${n}">${esc(a)}</span>`).join('<span class="fi-band-dot" aria-hidden="true">·</span>')}</p>
        ${b.limits ? `<p class="fi-band-limits">${esc(b.limits)}</p>` : ''}</div>
      ${b.unlock || b.lockouts ? `<div class="fi-band-actions">
        ${b.unlock ? `<button class="btn sm subtle fi-write" type="button" data-band="unlock" data-tip="Écriture${NBSP}: plan, confirmation, reçu et relecture">${glyph('lock')}Déverrouiller maintenant…<span class="fi-write-mark" aria-hidden="true">${glyph('edit')}</span><span class="visually-hidden">, écriture</span></button>` : ''}
        ${b.lockouts ? `<button class="btn sm ghost is-net" type="button" data-band="lockouts" data-tip="Lit le journal Sécurité des contrôleurs (4740)${NBSP}: lecture réseau, sur ce clic seulement">${glyph('history')}Lire les verrouillages (4740)<span class="k-cmd-net" aria-hidden="true"></span><span class="visually-hidden">, lecture réseau</span></button>` : ''}
        <button class="btn sm ghost" type="button" data-band="lockCard">${glyph('chevronRight')}Voir le verrouillage</button></div>` : ''}
    </section>`;
  }

  function stats(sheet) {
    const id = sheet.identity;
    const a = sheet.account;
    const c = sheet.counts;
    const tiles = [];
    const tile = (icon, label, value, sub, tone, tab) => tiles.push({ icon, label, value, sub, tone, tab });
    if (id.kind === 'user') {
      const locked = a?.lock === 'locked';
      tile('shield', 'Compte', a?.disabled ? 'Désactivé' : locked ? 'Verrouillé' : 'Activé', a?.accountExpiresLabel ?? '', a?.disabled || locked ? 'alert' : 'ok', 'compte');
      tile('key', 'Mot de passe', a ? passwordShort(a) : '—', a?.passwordLastSet ? `Changé le ${day(a.passwordLastSet)}` : a?.mustChange ? 'À la prochaine ouverture de session' : '', a?.passwordTone ?? 'off', 'compte');
      tile('clock', 'Dernière connexion', a?.logon?.approx ? day(a.logon.approx) : 'Aucune', a?.logon?.badge ?? 'Valeur répliquée, à 14 jours près', a?.logon?.badgeTone ?? 'off', 'compte');
      tile('group', 'Groupes directs', c.groups != null ? int(c.groups) : '—', sheet.states.some((s) => s.id === 'protected') ? 'Compte à privilèges (adminCount = 1)' : 'Groupe principal à part', sheet.states.some((s) => s.id === 'protected') ? 'accent' : 'info', 'groupes');
      tile('monitor', 'Poste associé', sheet.linked?.[0]?.name ?? 'Aucun', presenceShort(sheet.presence), presenceTone(sheet.presence), 'relations');
    } else if (id.kind === 'computer') {
      const os = sheet.sections.find((s) => s.id === 'systeme')?.items.find((i) => i.key === 'operatingSystem');
      tile('monitor', 'Système', os?.sub ?? os?.value ?? '—', os?.sub ? os?.value ?? '' : '', 'info', 'general');
      tile('wifi', 'Présence', presenceValue(sheet.presence), sheet.presence?.checkedAt ? `Relevé le ${stamp(sheet.presence.checkedAt)}` : 'Aucun relevé exploitable', presenceTone(sheet.presence), 'general');
      tile('clock', 'Dernière connexion', a?.logon?.approx ? day(a.logon.approx) : 'Aucune', a?.logon?.badge ?? '', a?.logon?.badgeTone ?? 'off', 'compte');
      tile('key', 'Mot de passe machine', a?.passwordTone === 'warn' ? 'Ancien' : 'À jour', a?.passwordLastSet ? `Renouvelé le ${day(a.passwordLastSet)}` : 'Date non lue', a?.passwordTone ?? 'off', 'compte');
      tile('user', 'Utilisateur associé', sheet.linked?.[0]?.name ?? 'Aucun', sheet.linked?.[0] ? sheet.linked[0].evidenceLabel : 'Aucune association connue', sheet.linked?.length ? 'accent' : 'off', 'relations');
    } else if (id.kind === 'group') {
      const type = sheet.sections[0]?.items.find((i) => i.key === 'groupType')?.value ?? 'Groupe';
      const typeMatch = /^Groupe de (sécurité|distribution) (.+)$/.exec(type);
      tile('users', 'Membres directs', c.members != null ? int(c.members) : '—', 'Attribut member, lu par plages', 'info', 'membres');
      tile('group', 'Membre de', c.groups != null ? int(c.groups) : '—', c.groups ? plural(c.groups, 'groupe parent', 'groupes parents') : 'Aucun groupe parent', 'accent', 'groupes');
      tile('tag', 'Type', typeMatch ? (typeMatch[1] === 'sécurité' ? 'Sécurité' : 'Distribution') : type, typeMatch ? `Étendue${NBSP}: ${typeMatch[2]}` : '', typeMatch?.[1] === 'sécurité' ? 'info' : 'off', 'general');
      tile('user', 'Géré par', sheet.manager?.name ?? 'Personne', sheet.manager?.detail ?? 'Attribut managedBy vide', sheet.manager ? 'ok' : 'off', 'relations');
    } else if (id.kind === 'ou' || id.kind === 'container') {
      tile('layers', 'Objets directs', c.children != null ? int(c.children) : '—', 'Index local, un seul niveau', 'info', 'membres');
      const gpo = sheet.states.find((s) => s.id === 'gpo');
      tile('shield', 'Stratégies liées', gpo ? gpo.label.split(NBSP)[0].split(' ')[0] : '0', gpo ? 'Attribut gPLink' : 'Aucune stratégie liée', gpo ? 'accent' : 'off', 'attributs');
      tile('user', 'Géré par', sheet.manager?.name ?? 'Personne', sheet.manager?.detail ?? 'Attribut managedBy vide', sheet.manager ? 'ok' : 'off', 'relations');
      tile('clock', 'Modifiée le', id.changed ? day(id.changed) : '—', 'Attribut whenChanged', 'off', 'historique');
    } else {
      const item = (key) => sheet.sections.flatMap((s) => s.items).find((i) => i.key === key);
      tile('building', 'Société', item('company')?.value ?? '—', item('title')?.value ?? '', 'info', 'general');
      tile('mail', 'Messagerie', item('mail')?.value ?? '—', 'Adresse de messagerie', 'accent', 'general');
      tile('phone', 'Téléphone', item('telephoneNumber')?.value ?? '—', item('mobile')?.value ? `Mobile${NBSP}: ${item('mobile').value}` : '', 'off', 'general');
      tile('group', 'Listes de diffusion', c.groups != null ? int(c.groups) : '—', 'Groupes dont le contact est membre', 'off', 'groupes');
    }
    return `<div class="fi-stats" data-count="${tiles.length}">${tiles.map((t, n) => `<button type="button" class="fi-stat spot reveal" data-tab="${esc(t.tab)}" data-tone="${esc(t.tone)}" data-j="${n}" aria-label="${esc(`${t.label}${NBSP}: ${t.value}${t.sub ? `, ${t.sub}` : ''}. Ouvre l’onglet correspondant.`)}">
      <span class="fi-stat-top"><span class="fi-stat-ico">${ficon(t.icon)}</span><span class="fi-stat-label">${esc(t.label)}</span></span>
      <span class="fi-stat-value">${nobr(t.value)}</span>
      <span class="fi-stat-sub">${nobr(t.sub || ' ')}</span>
      <span class="fi-stat-bar" aria-hidden="true"></span></button>`).join('')}</div>`;
  }

  function ids(sheet) {
    const id = sheet.identity;
    const chips = [];
    if (id.sam) chips.push(`<span class="fi-idchip mono" data-tip="Identifiant (sAMAccountName)">${glyph('user')}${esc(id.sam)}</span>`);
    if (id.upn) chips.push(`<span class="fi-idchip mono" data-tip="Nom de connexion (UPN)">${ficon('mail')}${esc(id.upn)}</span>`);
    return chips.join('');
  }

  function markup(sheet) {
    const id = sheet.identity;
    const k = kindOf(id.kind);
    const presence = sheet.presence ? ` data-presence="${esc(sheet.presence.state)}"` : '';
    return `<section class="fi-hero reveal" data-kind="${esc(k.hue)}">
      <span class="glow-ring fi-ring" aria-hidden="true"></span>
      <div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>
      <span class="fi-hero-busy" aria-hidden="true"></span>
      <div class="fi-hero-grid">
        <div class="fi-id">
          <div class="fi-avatar-wrap"${presence}>${avatar(id.kind, id.initials, 'xl')}<span class="fi-presence-dot" aria-hidden="true"></span></div>
          <div class="fi-id-text">
            <p class="fi-eyebrow"><span class="fi-kind">${glyph(k.icon)}${esc(id.kindLabel)}</span>${origin(sheet)}</p>
            <h1 class="fi-name gradient-text">${esc(id.name)}</h1>
            <p class="fi-subtitle">${nobr(id.subtitle)}</p>
            <div class="fi-states">${statePills(sheet.states)}${ids(sheet)}</div>
          </div>
        </div>
        <div class="fi-hero-side"><div class="fi-cmd"></div></div>
      </div>
      <div class="fi-crumbs-row"><div class="fi-crumbs"></div>
        <button class="btn ghost icon sm fi-dn-menu" type="button" aria-haspopup="menu" aria-label="Menu du nom distinctif" data-tip="Copier le DN ou le nom, ouvrir le parent">${glyph('more')}</button></div>
    </section>
    ${band(sheet)}
    ${stats(sheet)}`;
  }

  function wire(sheet) {
    bar?.destroy?.();
    crumbs?.destroy?.();
    bar = createCommandBar(host.querySelector('.fi-cmd'), { label: `Actions de la fiche ${sheet.identity.name}`, items: commands(sheet) });
    crumbs = createDnBreadcrumb(host.querySelector('.fi-crumbs'), { dn: sheet.identity.dn, onNavigate: (dn) => S.open(dn), copy: true, maxVisible: 6, label: 'Emplacement de l’objet' });
    applyVars(host);
    startFreshness(host);
    markTab(S.tabs?.current?.() ?? sheet.landing);
  }

  function markTab(tab) {
    host.querySelectorAll('.fi-stat[data-tab]').forEach((t) => t.classList.toggle('active', t.dataset.tab === tab));
  }

  function dnMenu(button) {
    const id = S.sheet.identity;
    const copy = (text, done) => writeClipboard(text).then((ok) => toast(ok ? done : 'Copie impossible.', { tone: ok ? 'ok' : 'warn', life: 2400 }));
    openMenu(button, [
      { heading: 'Nom distinctif' },
      { label: 'Copier le DN', icon: 'copy', run: () => copy(id.dn, 'DN copié.') },
      { label: 'Copier le nom', icon: 'copy', run: () => copy(id.name, 'Nom copié.') },
      { label: 'Ouvrir le parent', icon: 'ou', disabled: !id.parentDn || /^DC=/i.test(id.dn), reason: 'La racine du domaine n’a pas de parent dans l’annuaire.', run: () => S.open(id.parentDn) },
    ], { label: 'Menu du nom distinctif', placement: 'bottom-end' });
  }

  host.innerHTML = markup(S.sheet);
  shown = headerKey(S.sheet);
  wire(S.sheet);

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const stat = t.closest('.fi-stat[data-tab]');
    if (stat) { S.selectTab(stat.dataset.tab, { scroll: true }); return; }
    const b = t.closest('[data-band]');
    // Domenia 1 (FIC-048): « Déverrouiller maintenant » and « Lire les verrouillages (4740) » act from the band directly.
    if (b) { S.act(b.dataset.band); return; }
    const dn = t.closest('.fi-dn-menu');
    if (dn) dnMenu(dn);
  };
  host.addEventListener('click', onClick);

  return {
    /** Same object read again: repainted only when what the header shows changed (FIC-031), never with its entrance again. */
    update(sheet) {
      const key = headerKey(sheet);
      if (key === shown) {
        const fresh = host.querySelector('.fi-origin + .k-fresh');
        if (fresh) { fresh.dataset.at = sheet.origin.readAt; startFreshness(host); }
        return false;
      }
      shown = key;
      host.innerHTML = markup(sheet).replaceAll(' reveal', ' revealed');
      wire(sheet);
      host.querySelector('.fi-hero')?.classList.add('refreshed');
      return true;
    },
    markTab,
    setBusy(on) {
      const hero = host.querySelector('.fi-hero');
      hero?.classList.toggle('busy', !!on);
      if (on) hero?.setAttribute('aria-busy', 'true');
      else hero?.removeAttribute('aria-busy');
    },
    destroy() {
      host.removeEventListener('click', onClick);
      bar?.destroy?.();
      crumbs?.destroy?.();
    },
  };
}

/** What the header shows, without the date of the read (an identical header is never repainted). */
function headerKey(sheet) {
  const { origin, freshness, ...rest } = sheet;
  return JSON.stringify([rest.identity, rest.states, rest.band, rest.account, rest.counts, rest.presence, rest.linked?.[0], rest.manager, rest.actions, origin.preview, origin.controller,
    rest.sections.find((s) => s.id === 'systeme'), freshness?.length]);
}

function passwordShort(a) {
  if (a.mustChange) return 'À changer';
  if (a.passwordTone === 'alert') return 'Expiré';
  if (a.options?.some((o) => o.id === 'passwordNeverExpires' && o.on)) return 'Sans expiration';
  if (a.passwordExpires) return `Expire le ${day(a.passwordExpires)}`;
  return 'Valide';
}

function presenceValue(p) {
  if (!p) return 'Non relevée';
  if (p.state === 'online') return 'En ligne';
  if (p.state === 'offline') return 'Sans réponse';
  return p.checkedAt ? presenceWords(p) : 'Non relevée';
}

function presenceShort(p) {
  if (!p) return 'Présence non relevée';
  return p.checkedAt ? `${presenceWords(p)}, relevé le ${stamp(p.checkedAt)}` : presenceWords(p);
}

function presenceTone(p) {
  if (!p) return 'off';
  return p.state === 'online' ? 'ok' : p.state === 'offline' ? 'warn' : 'off';
}
