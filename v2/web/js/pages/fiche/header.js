// Header of the fiche: kind, name, state pills, origin and freshness, DN breadcrumb, command bar, support band of a user
// (FIC-048) and the key figures of the object. Updated in place when the fiche is read again (FIC-031).
import { createCommandBar, createDnBreadcrumb, freshness, startFreshness, glyph, pill, NBSP, int } from '../../kit/index.js';
import { esc, applyVars } from '../../ui.js';
import { avatar, kindOf, statePills, plural } from './common.js';

const ACTION_ICONS = {
  edit: 'edit', unlock: 'lock', resetPassword: 'key', expirePassword: 'key', expiration: 'calendar', options: 'sliders', enable: 'power',
  disable: 'power', move: 'ou', groupAdd: 'group', memberAdd: 'plus', createOu: 'plus', setScope: 'pin', delete: 'trash', lockouts: 'lock',
  logonByDc: 'server', compare: 'split', callSheet: 'lifebuoy', openPoste: 'monitor', presence: 'wifi', rights: 'shield', reread: 'refresh',
  copySummary: 'copy', openParent: 'ou',
};

const GROUPS = [
  { heading: 'Modifier', ids: ['edit', 'unlock', 'enable', 'disable', 'expirePassword', 'resetPassword', 'expiration', 'options', 'move', 'groupAdd', 'memberAdd', 'createOu'] },
  { heading: 'Lire sur le réseau', ids: ['lockouts', 'logonByDc', 'presence', 'rights', 'compare'] },
  { heading: 'Aller à', ids: ['callSheet', 'openPoste', 'openParent', 'setScope', 'copySummary'] },
  { heading: 'Zone sensible', ids: ['delete'] },
];

/**
 * @param {HTMLElement} host
 * @param {any} S  Screen state (fiche.js).
 */
export function mountHeader(host, S) {
  let bar = null;
  let crumbs = null;

  function primaryId(sheet) {
    const usable = (id) => sheet.actions.find((a) => a.id === id && a.available);
    if (sheet.identity.kind === 'user' && sheet.account?.lock === 'locked' && usable('unlock')) return 'unlock';
    if (usable('edit')) return 'edit';
    return 'reread';
  }

  function commands(sheet) {
    const primary = primaryId(sheet);
    const byId = new Map(sheet.actions.map((a) => [a.id, a]));
    const cmd = (a, extra = {}) => ({
      id: a.id, label: a.label, icon: ACTION_ICONS[a.id], kind: a.kind === 'write' ? 'write' : a.kind === 'network' ? 'network' : 'local',
      disabled: !a.available, reason: a.reason ?? undefined, danger: a.danger && a.id !== primary, run: () => S.act(a.id), ...extra,
    });
    const items = [];
    const p = byId.get(primary);
    if (p) items.push(cmd(p, { primary: true, danger: false, pinned: true }));
    if (sheet.identity.kind === 'computer' && byId.has('openPoste')) items.push(cmd(byId.get('openPoste')));
    const menu = [];
    for (const g of GROUPS) {
      const list = g.ids.map((id) => byId.get(id)).filter((a) => a && a.id !== primary);
      if (!list.length) continue;
      if (menu.length) menu.push('-');
      menu.push({ heading: g.heading });
      for (const a of list) {
        menu.push({ label: a.label, icon: ACTION_ICONS[a.id], danger: !!a.danger, disabled: !a.available, reason: a.reason ?? undefined, run: () => S.act(a.id) });
      }
    }
    items.push({ id: 'more', label: 'Actions', icon: 'more', items: menu, pinned: true });
    if (byId.has('reread')) items.push(cmd(byId.get('reread'), { iconOnly: true, kbd: 'F5', pinned: true, label: 'Relire depuis l’annuaire' }));
    if (byId.has('copySummary')) items.push(cmd(byId.get('copySummary'), { iconOnly: true, pinned: true }));
    return items;
  }

  function origin(sheet) {
    const o = sheet.origin;
    if (o.preview) {
      return `<span class="fi-origin preview" data-tip="${esc(o.detail)}">${glyph('database')}<span>Aperçu local</span><span class="fi-origin-pulse" aria-hidden="true"></span></span>`;
    }
    const label = o.source === 'simulation' ? 'Annuaire fictif' : 'Annuaire';
    return `<span class="fi-origin live" data-tip="${esc(o.detail)}">${glyph(o.source === 'simulation' ? 'sparkles' : 'server')}<span>${esc(label)}${o.controller ? ` · ${esc(o.controller)}` : ''}</span></span>`
      + freshness(o.readAt, { label: 'Lu', staleAfter: 15 * 60_000, source: o.controller ?? label });
  }

  function band(sheet) {
    const b = sheet.band;
    if (!b) return '';
    const buttons = [
      b.unlock ? `<button class="btn sm primary" type="button" data-band="unlock">${glyph('lock')}Déverrouiller maintenant</button>` : '',
      b.lockouts ? `<button class="btn sm" type="button" data-band="lockouts">${glyph('history')}Lire les verrouillages (4740)</button>` : '',
    ].join('');
    return `<section class="fi-band reveal" data-tone="${esc(b.tone)}" role="status">
      <span class="fi-band-ico">${glyph(b.tone === 'alert' ? 'alert' : 'eye')}</span>
      <div class="fi-band-body"><p class="fi-band-alerts">${b.alerts.map((a, n) => `<span class="fi-band-alert" data-j="${n}">${esc(a)}</span>`).join('<span class="fi-band-dot" aria-hidden="true">·</span>')}</p>
        ${b.limits ? `<p class="fi-band-limits">${esc(b.limits)}</p>` : ''}</div>
      ${buttons ? `<div class="fi-band-actions">${buttons}</div>` : ''}
    </section>`;
  }

  function stats(sheet) {
    const id = sheet.identity;
    const a = sheet.account;
    const c = sheet.counts;
    const tiles = [];
    const tile = (icon, label, value, sub, tone, tab, extra = '') => tiles.push({ icon, label, value, sub, tone, tab, extra });
    if (id.kind === 'user') {
      tile('shield', 'Compte', a?.disabled ? 'Désactivé' : a?.lock === 'locked' ? 'Verrouillé' : 'Activé',
        a?.lock === 'locked' ? a.lockLabel : a?.accountExpiresLabel ?? '', a?.disabled || a?.lock === 'locked' ? 'alert' : 'ok', 'compte');
      // The value already gives the date: the sub keeps only what it adds (« dans 55 jours »).
      tile('key', 'Mot de passe', a ? passwordShort(a) : '—', a?.passwordExpires ? (/\(([^)]+)\)\s*$/.exec(a.passwordLabel ?? '')?.[1] ?? a.passwordLabel) : a?.passwordLabel ?? '', a?.passwordTone ?? 'off', 'compte');
      tile('clock', 'Dernière connexion', a?.logon?.approx ? dateShort(a.logon.approx) : 'Aucune', a?.logon?.badge ?? 'Valeur approximative (répliquée)', a?.logon?.badgeTone ?? 'off', 'compte');
      tile('group', 'Groupes directs', c.groups != null ? int(c.groups) : '—', groupSub(sheet), privilegedTone(sheet), 'groupes');
      tile('monitor', 'Poste associé', sheet.linked?.[0]?.name ?? 'Aucun', (sheet.presence?.label ?? '').replace(/\s*\(poste associé [^)]*\)/, ''), presenceTone(sheet.presence), 'relations');
    } else if (id.kind === 'computer') {
      const os = sheet.sections.find((s) => s.id === 'systeme')?.items.find((i) => i.key === 'operatingSystem');
      tile('monitor', 'Système', os?.sub ?? os?.value ?? '—', os?.value ?? '', 'info', 'general');
      tile('wifi', 'Présence', sheet.presence?.label ?? 'Non relevée', sheet.presence?.detail ?? '', presenceTone(sheet.presence), 'general');
      tile('clock', 'Dernière connexion', a?.logon?.approx ? dateShort(a.logon.approx) : 'Aucune', a?.logon?.badge ?? '', a?.logon?.badgeTone ?? 'off', 'compte');
      tile('key', 'Mot de passe machine', a?.passwordTone === 'warn' ? 'Ancien' : 'À jour', a?.passwordLabel ?? '', a?.passwordTone ?? 'off', 'compte');
      tile('user', 'Utilisateur associé', sheet.linked?.[0]?.name ?? 'Aucun', sheet.linked?.[0] ? `${sheet.linked[0].evidenceLabel}` : 'Aucune association connue', sheet.linked?.length ? 'accent' : 'off', 'relations');
    } else if (id.kind === 'group') {
      const type = sheet.sections[0]?.items.find((i) => i.key === 'groupType')?.value ?? 'Groupe';
      const typeMatch = /^Groupe de (sécurité|distribution) (.+)$/.exec(type);
      tile('users', 'Membres directs', c.members != null ? int(c.members) : '—', 'Attribut member', 'info', 'membres');
      tile('group', 'Membre de', c.groups != null ? int(c.groups) : '—', c.groups ? plural(c.groups, 'groupe parent', 'groupes parents') : 'Aucun groupe parent', 'accent', 'groupes');
      tile('tag', 'Type', typeMatch ? (typeMatch[1] === 'sécurité' ? 'Sécurité' : 'Distribution') : type, typeMatch ? `Portée : ${typeMatch[2]}` : '', typeMatch?.[1] === 'sécurité' ? 'info' : 'off', 'general');
      tile('user', 'Géré par', sheet.manager?.name ?? 'Personne', sheet.manager?.detail ?? '', sheet.manager ? 'ok' : 'off', 'relations');
    } else if (id.kind === 'ou' || id.kind === 'container') {
      tile('layers', 'Objets directs', c.children != null ? int(c.children) : '—', 'Lecture d’un seul niveau', 'info', 'membres');
      const gpo = sheet.states.find((s) => s.id === 'gpo');
      tile('shield', 'Stratégies liées', gpo ? gpo.label.split(NBSP)[0].split(' ')[0] : '0', gpo ? 'Attribut gPLink' : 'Aucune stratégie liée', gpo ? 'accent' : 'off', 'attributs');
      tile('user', 'Géré par', sheet.manager?.name ?? 'Personne', sheet.manager?.detail ?? '', sheet.manager ? 'ok' : 'off', 'relations');
      tile('clock', 'Modifiée', id.changed ? dateShort(id.changed) : '—', 'whenChanged', 'off', 'historique');
    } else {
      const item = (key) => sheet.sections.flatMap((s) => s.items).find((i) => i.key === key);
      tile('object', 'Société', item('company')?.value ?? '—', item('title')?.value ?? '', 'info', 'general');
      tile('link', 'Messagerie', item('mail')?.value ?? '—', '', 'accent', 'general');
      tile('clock', 'Téléphone', item('telephoneNumber')?.value ?? '—', item('mobile')?.value ?? '', 'off', 'general');
      tile('group', 'Listes de diffusion', c.groups != null ? int(c.groups) : '—', '', 'off', 'groupes');
    }
    return `<div class="fi-stats" data-count="${tiles.length}">${tiles.map((t, n) => `<button type="button" class="fi-stat spot tilt reveal" data-tab="${esc(t.tab)}" data-tone="${esc(t.tone)}" data-j="${n}" aria-label="${esc(`${t.label} : ${t.value}${t.sub ? `, ${t.sub}` : ''}`)}">
      <span class="fi-stat-top"><span class="fi-stat-ico">${glyph(t.icon)}</span><span class="fi-stat-label">${esc(t.label)}</span></span>
      <span class="fi-stat-value">${esc(t.value)}</span>
      <span class="fi-stat-sub">${esc(t.sub || ' ')}</span>
      <span class="fi-stat-bar" aria-hidden="true"></span></button>`).join('')}</div>`;
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
            <p class="fi-subtitle">${esc(id.subtitle)}</p>
            <div class="fi-states">${statePills(sheet.states)}</div>
          </div>
        </div>
        <div class="fi-hero-side"><div class="fi-cmd"></div>
          ${id.sam ? `<p class="fi-ids"><span class="mono" data-tip="Identifiant (sAMAccountName)">${esc(id.sam)}</span>${id.upn ? `<span class="mono" data-tip="Nom de connexion (UPN)">${esc(id.upn)}</span>` : ''}</p>` : ''}
        </div>
      </div>
      <div class="fi-crumbs"></div>
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
  }

  host.innerHTML = markup(S.sheet);
  wire(S.sheet);

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const stat = t.closest('.fi-stat[data-tab]');
    if (stat) { S.selectTab(stat.dataset.tab); return; }
    const b = t.closest('[data-band]');
    if (b) S.act(b.dataset.band);
  };
  host.addEventListener('click', onClick);

  return {
    update(sheet) {
      // Same object: the header is repainted in place (no entrance again), the command bar follows the new actions.
      host.innerHTML = markup(sheet).replaceAll(' reveal', ' revealed');
      wire(sheet);
      host.querySelector('.fi-hero')?.classList.add('refreshed');
    },
    setBusy(on) {
      host.querySelector('.fi-hero')?.classList.toggle('busy', !!on);
      if (on) host.querySelector('.fi-hero')?.setAttribute('aria-busy', 'true');
      else host.querySelector('.fi-hero')?.removeAttribute('aria-busy');
    },
    destroy() {
      host.removeEventListener('click', onClick);
      bar?.destroy?.();
      crumbs?.destroy?.();
    },
  };
}

function dateShort(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '—';
  const pad = (n) => String(n).padStart(2, '0');
  return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()}`;
}

function passwordShort(a) {
  if (a.mustChange) return 'À changer';
  if (a.passwordTone === 'alert') return 'Expiré';
  if (a.options?.some((o) => o.id === 'passwordNeverExpires' && o.on)) return 'Sans expiration';
  if (a.passwordExpires) return `Expire le ${dateShort(a.passwordExpires)}`;
  return 'Valide';
}

function groupSub(sheet) {
  const privileged = sheet.states.some((s) => s.id === 'protected');
  return privileged ? 'Compte à privilèges (adminCount = 1)' : 'memberOf, groupe principal à part';
}

function privilegedTone(sheet) {
  return sheet.states.some((s) => s.id === 'protected') ? 'accent' : 'info';
}

function presenceTone(p) {
  if (!p) return 'off';
  return p.state === 'online' ? 'ok' : p.state === 'offline' ? 'warn' : 'off';
}

export { pill };
