// « Fiche » screen (#/fiche?dn=…&tab=…&open=…): the card of one directory object — user, computer, group, OU or contact —
// with its header (kind, name, state pills, DN breadcrumb, actions), its tabs (general, account, groups, members,
// relations, rights, attributes, history, call sheet) and its writes through the write circuit. Domenia 1: FIC-001 to
// FIC-050 and lot R40 (Domenia-CallSheet). Contract: docs/ops/fiche.md. The local projection is shown first (fiche.preview),
// the directory read replaces it (fiche.read); nothing is read on the network without the operator’s gesture.
import { createTabs, confirmDialog, writeClipboard, glyph } from '../kit/index.js';
import { esc, errorText, toast, announce, applyVars, reveal } from '../ui.js';
import { write, pickObject, pickOu } from './fiche/actions.js';
import { failure, skeleton } from './fiche/common.js';
import { mountHeader } from './fiche/header.js';
import { mountGeneral } from './fiche/general.js';
import { mountAccount } from './fiche/account.js';
import { mountGroups, openCompare } from './fiche/groups.js';
import { mountMembers, createOu } from './fiche/members.js';
import { mountRelations } from './fiche/relations.js';
import { mountRights } from './fiche/rights.js';
import { mountAttributes } from './fiche/attributes.js';
import { mountHistory } from './fiche/history.js';
import { mountCallSheet } from './fiche/callsheet.js';
import { renderEmpty } from './fiche/empty.js';

export const stylesheet = true;

const TAB_ICONS = { general: 'object', compte: 'key', groupes: 'group', membres: 'users', relations: 'link', droits: 'shield', attributs: 'hash', historique: 'history', appel: 'lifebuoy' };
const MOUNTS = { general: mountGeneral, compte: mountAccount, groupes: mountGroups, membres: mountMembers, relations: mountRelations, droits: mountRights, attributs: mountAttributes, historique: mountHistory, appel: mountCallSheet };

// Saisies left on a fiche that was quit without saving: said once on the next fiche (Domenia 1 FIC-009).
let abandoned = null;

export function render(main, ctx) {
  const dn = ctx.params.dn ?? '';
  if (!dn && ctx.params.q) return resolveThenOpen(main, ctx);
  if (!dn) return renderEmpty(main, ctx);
  if (abandoned) {
    toast(`Les saisies de la fiche ${abandoned} n’ont pas été enregistrées : rien n’est parti.`, { tone: 'warn', life: 7000 });
    abandoned = null;
  }

  main.innerHTML = `<div class="page fi-page" data-kind="loading">
    <div class="fi-head-host">${headSkeleton()}</div>
    <div class="fi-body-host">${tabsSkeleton()}</div>
  </div>`;
  const page = /** @type {HTMLElement} */ (main.querySelector('.fi-page'));
  const headHost = /** @type {HTMLElement} */ (main.querySelector('.fi-head-host'));
  const bodyHost = /** @type {HTMLElement} */ (main.querySelector('.fi-body-host'));

  /** Screen state shared with the tab modules. */
  const S = {
    ctx,
    dn,
    params: ctx.params,
    main,
    sheet: null,
    live: false,
    alive: true,
    header: null,
    tabs: null,
    mounted: new Map(),
    draft: null,
    routeDone: false,
    stopReveal: () => {},
    /** Opens another fiche (or this one with other parameters). */
    open(target, params = {}) {
      if (S.draft?.count && target !== S.dn) abandoned = S.sheet?.identity?.name ?? 'précédente';
      ctx.navigate('fiche', { dn: target, ...params });
    },
    /** Reads the fiche again from the directory (after a write or on demand). */
    reload: (o = {}) => load({ ...o, again: true }),
    /** Runs an action of the fiche by its id (header, band, tabs, route). */
    act: (id, arg) => runAction(S, id, arg),
    /** Selects a tab. */
    selectTab(id) { S.tabs?.select(id); },
    /** Tells every mounted tab that the fiche changed. */
    notify() { for (const m of S.mounted.values()) m.update?.(S.sheet); },
  };

  async function load({ again = false, quiet = false } = {}) {
    if (!again) {
      // Local projection first (FIC-030): shown at once, marked as such, without probes nor writes.
      ctx.call('fiche.preview', { dn }).then((preview) => {
        if (!S.alive || S.live || !preview) return;
        show(preview);
      }).catch((err) => console.error(err));
    } else {
      S.header?.setBusy(true);
    }
    try {
      const sheet = await ctx.call('fiche.read', { dn });
      if (!S.alive) return;
      // Identity check (FIC-033): the GUID captured at the selection (route « guid ») or shown by the local preview must be the
      // one read; otherwise the DN now names another object, which is said, never silently swapped.
      const expected = String(S.params.guid || (!S.live && S.sheet ? S.sheet.identity.guid : '')).toLowerCase();
      if (expected && sheet.identity.guid.toLowerCase() !== expected) {
        toast('Objet remplacé depuis la sélection : ce DN désigne maintenant un autre objet (GUID différent). La fiche affiche l’objet relu ; actualisez la liste d’origine.', { tone: 'warn', life: 10000 });
      }
      S.live = true;
      show(sheet, { again, quiet });
      if (!again) ctx.call('fiche.recent.add', { dn: sheet.identity.dn }).catch((err) => console.error(err));
    } catch (err) {
      if (!S.alive) return;
      console.error(err);
      if (S.sheet && again) {
        toast(`Relecture impossible : ${errorText(err)} Rien n’a été modifié.`, { tone: 'warn' });
        S.header?.setBusy(false);
        return;
      }
      page.dataset.kind = 'error';
      headHost.innerHTML = '';
      bodyHost.innerHTML = `<section class="card fi-card fi-fatal">${failure(err, { title: err?.code === 'fiche.unknown' ? 'Objet introuvable' : 'Fiche illisible' })}
        <div class="fi-fatal-actions"><button class="btn" type="button" data-back>${glyph('search')}Rechercher un objet</button></div></section>`;
      bodyHost.querySelector('[data-retry]')?.addEventListener('click', () => { bodyHost.innerHTML = tabsSkeleton(); load(); });
      bodyHost.querySelector('[data-back]')?.addEventListener('click', () => ctx.navigate('fiche', {}));
    } finally {
      S.header?.setBusy(false);
    }
  }

  // First display builds header and tabs; a later one updates them in place when only display fields changed (FIC-031).
  function show(sheet, { again = false, quiet = false } = {}) {
    const previous = S.sheet;
    S.sheet = sheet;
    page.dataset.kind = sheet.identity.kind;
    if (!previous || previous.identity.kind !== sheet.identity.kind || tabsChanged(previous, sheet)) {
      build(sheet);
      openRoute();
      return;
    }
    openRoute();
    S.header.update(sheet);
    if (previous.signature === sheet.signature && !previous.origin.preview) {
      // Identity, state, memberships and links unchanged: only the display fields that changed are repainted.
      S.notify();
      if (again && !quiet) announce('Fiche relue : aucun changement d’état.');
      return;
    }
    S.notify();
    for (const m of S.mounted.values()) if (again) m.refresh?.();
    if (again && !quiet) announce('Fiche relue depuis l’annuaire.');
  }

  function build(sheet) {
    S.header?.destroy();
    S.tabs?.destroy();
    for (const m of S.mounted.values()) m.destroy?.();
    S.mounted.clear();
    S.header = mountHeader(headHost, S);
    const wanted = S.params.tab && sheet.tabs.some((t) => t.id === S.params.tab) ? S.params.tab : sheet.landing;
    bodyHost.innerHTML = '<div class="fi-tabs"></div>';
    S.tabs = createTabs(bodyHost.querySelector('.fi-tabs'), {
      label: `Onglets de la fiche ${sheet.identity.name}`,
      selected: wanted,
      tabs: sheet.tabs.map((t) => ({
        id: t.id,
        label: t.label,
        icon: TAB_ICONS[t.id],
        count: Number.isFinite(t.count) ? t.count : null,
        render: (panel) => {
          const mount = MOUNTS[t.id];
          if (!mount) return undefined;
          panel.classList.add('fi-panel');
          const controller = mount(panel, S);
          S.mounted.set(t.id, controller);
          return () => { controller.destroy?.(); S.mounted.delete(t.id); };
        },
      })),
      onChange: (id) => {
        page.dataset.tab = id;
        // The tab follows the address without a new history entry, so that a reload or a link reopens it.
        const params = new URLSearchParams(location.hash.split('?')[1] ?? '');
        params.set('tab', id);
        params.delete('open');
        history.replaceState(null, '', `#/fiche?${params.toString()}`);
      },
    });
    S.tabs.select(wanted);
    page.dataset.tab = S.tabs.current();
    applyVars(page);
    S.stopReveal();
    S.stopReveal = reveal(page);
  }

  // Route states (captures, links: « open »): opened once, after the directory read.
  function openRoute() {
    if (S.routeDone || !S.live || !S.params.open) return;
    S.routeDone = true;
    const open = S.params.open;
    setTimeout(() => { if (S.alive) runAction(S, `route:${open}`); }, 80);
  }

  load();

  const onKey = (e) => {
    if (e.key === 'F5' && !e.ctrlKey && !e.altKey && !e.metaKey) {
      e.preventDefault();
      S.reload();
    }
  };
  document.addEventListener('keydown', onKey);
  return () => {
    S.alive = false;
    if (S.draft?.count) abandoned = S.sheet?.identity?.name ?? 'précédente';
    document.removeEventListener('keydown', onKey);
    S.stopReveal();
    S.header?.destroy();
    S.tabs?.destroy();
  };
}

/** #/fiche?q=… (links and captures): the object designated exactly in the local base opens in place of this address. */
function resolveThenOpen(main, ctx) {
  let alive = true;
  main.innerHTML = `<div class="page fi-page" data-kind="loading"><div class="fi-head-host">${headSkeleton()}</div><div class="fi-body-host">${tabsSkeleton()}</div></div>`;
  ctx.call('fiche.resolve', { text: ctx.params.q }).then((found) => {
    if (!alive) return;
    const params = { ...ctx.params, dn: found.dn };
    delete params.q;
    location.replace(ctx.link('fiche', params));
  }).catch((err) => {
    if (!alive) return;
    main.innerHTML = `<div class="page fi-page"><section class="card fi-card fi-fatal">${failure(err, { title: 'Objet introuvable', retry: false })}
      <div class="fi-fatal-actions"><button class="btn" type="button" data-search>${glyph('search')}Rechercher « ${esc(ctx.params.q)} »</button></div></section></div>`;
    main.querySelector('[data-search]')?.addEventListener('click', () => ctx.navigate('rechercher', { q: ctx.params.q }));
  });
  return () => { alive = false; };
}

function tabsChanged(a, b) {
  return a.tabs.map((t) => t.id).join() !== b.tabs.map((t) => t.id).join();
}

function headSkeleton() {
  return `<section class="fi-hero fi-hero-sk" aria-busy="true"><div class="fi-hero-grid"><div class="fi-id">
    <span class="skeleton fi-sk-avatar"></span><div class="fi-sk-stack"><span class="skeleton fi-sk-line w25"></span><span class="skeleton fi-sk-title"></span>
    <span class="skeleton fi-sk-line w55"></span><span class="skeleton fi-sk-line w40"></span></div></div></div></section>
    <div class="fi-stats">${Array.from({ length: 4 }, () => `<div class="fi-stat">${skeleton(3)}</div>`).join('')}</div>`;
}

function tabsSkeleton() {
  return `<div class="fi-tabs-sk"><div class="fi-sk-tabs">${Array.from({ length: 6 }, () => '<span class="skeleton fi-sk-tab"></span>').join('')}</div>
    <div class="fi-sk-grid"><section class="card fi-card">${skeleton(6)}</section><section class="card fi-card">${skeleton(5)}</section></div></div>`;
}

/** Plan of one write, then a re-read of the fiche once the receipt is in (the receipt panel stays open). */
function writeAndReload(S, plan, args, subtitle) {
  return write(S.ctx, plan, args, { subtitle, onDone: () => S.reload({ quiet: true }) });
}

/** Actions of the fiche (header, band, tabs and route states « open »). */
async function runAction(S, id, arg) {
  const sheet = S.sheet;
  if (!sheet) return;
  const dn = sheet.identity.dn;
  const name = sheet.identity.name;
  const action = sheet.actions.find((a) => a.id === id);
  if (action && !action.available) {
    toast(action.reason ?? 'Action indisponible.', { tone: 'info' });
    return;
  }
  const subtitle = `${sheet.identity.kindLabel} · ${name}`;
  switch (id) {
    case 'edit':
      S.selectTab('general');
      setTimeout(() => S.mounted.get('general')?.edit?.(), 30);
      return;
    case 'unlock':
      await writeAndReload(S, 'accounts.unlock.plan', { dn }, subtitle);
      return;
    case 'enable':
    case 'disable':
      await writeAndReload(S, 'fiche.enable.plan', { dn, enabled: id === 'enable' }, subtitle);
      return;
    case 'expirePassword':
      await writeAndReload(S, 'fiche.expirePassword.plan', { dn }, subtitle);
      return;
    case 'resetPassword':
    case 'expiration':
    case 'options':
      S.selectTab('compte');
      setTimeout(() => S.mounted.get('compte')?.focus?.(id), 30);
      return;
    case 'move': {
      const target = await pickOu(S.ctx, {
        title: `Déplacer ${name}`, subtitle: 'Choisir l’OU de destination', confirm: 'Préparer le déplacement',
        current: sheet.identity.parentDn ?? undefined,
        note: 'Le DN et le GUID de l’objet sont capturés maintenant et revérifiés avant l’envoi.',
      });
      if (target) await writeAndReload(S, 'fiche.move.plan', { dn, target: target.dn }, subtitle);
      return;
    }
    case 'groupAdd': {
      const group = await pickObject(S.ctx, {
        title: `Ajouter ${name} à un groupe`, subtitle: 'Choisir un groupe du domaine', kinds: ['group'], placeholder: 'Nom du groupe…',
        exclude: arg?.exclude ?? [],
      });
      if (group) await writeAndReload(S, 'fiche.membership.plan', { group: group.dn, member: dn, add: true }, `Groupe · ${group.name}`);
      return;
    }
    case 'memberAdd': {
      const member = await pickObject(S.ctx, {
        title: `Ajouter un membre à ${name}`, subtitle: 'Utilisateur, ordinateur, groupe ou contact', kinds: ['user', 'computer', 'group', 'contact'],
        exclude: arg?.exclude ?? [],
      });
      if (member) await writeAndReload(S, 'fiche.membership.plan', { group: dn, member: member.dn, add: true }, subtitle);
      return;
    }
    case 'removeFrom':
      if (arg?.group) await writeAndReload(S, 'fiche.membership.plan', { group: arg.group, member: arg.member ?? dn, add: false }, `Groupe · ${arg.groupName ?? ''}`);
      return;
    case 'createOu':
      await createOu(S);
      return;
    case 'setScope': {
      try {
        const info = await S.ctx.call('session.setScope', { dn, subtree: true });
        toast(`OU de travail : ${info?.scope?.label ?? name} et ses sous-OU. Choix mémorisé dans les préférences de Domenia.`, { tone: 'ok' });
      } catch (err) {
        toast(`OU de travail inchangée : ${errorText(err)}`, { tone: 'warn' });
      }
      return;
    }
    case 'delete': {
      const ok = await confirmDialog({
        title: `Supprimer ${name} ?`,
        message: 'La suppression est définitive et non récursive. Le plan suivant vous demandera de saisir le nom exact de l’objet avant tout envoi.',
        confirmLabel: 'Préparer la suppression', danger: true, icon: 'trash',
      });
      if (ok) await write(S.ctx, 'fiche.delete.plan', { dn }, { subtitle, onDone: (receipt) => { if (receipt?.result === 'applied') S.ctx.navigate('fiche', {}); } });
      return;
    }
    case 'lockouts':
      S.selectTab('compte');
      setTimeout(() => S.mounted.get('compte')?.focus?.('lockouts'), 30);
      return;
    case 'logonByDc':
      S.selectTab('compte');
      setTimeout(() => S.mounted.get('compte')?.focus?.('logonByDc'), 30);
      return;
    case 'presence':
      S.selectTab('general');
      setTimeout(() => S.mounted.get('general')?.presence?.(), 30);
      return;
    case 'rights':
      S.selectTab('droits');
      setTimeout(() => S.mounted.get('droits')?.run?.(), 30);
      return;
    case 'compare':
      openCompare(S);
      return;
    case 'callSheet':
      S.selectTab('appel');
      return;
    case 'openPoste':
      S.ctx.navigate('poste', { dn });
      return;
    case 'reread':
      await S.reload();
      return;
    case 'copySummary':
      writeClipboard(sheet.summary).then((ok) => toast(ok ? 'Résumé copié.' : 'Copie impossible.', { tone: ok ? 'ok' : 'warn', life: 2600 }));
      return;
    case 'openParent':
      if (sheet.identity.parentDn) S.open(sheet.identity.parentDn);
      return;
    default:
      if (id.startsWith('route:')) {
        routeState(S, id.slice(6));
      }
  }
}

/** States opened by the address (« open »): edit, move, groupAdd, nested groups, compare, raw editor, reads… */
function routeState(S, state) {
  const map = {
    edit: () => runAction(S, 'edit'),
    move: () => runAction(S, 'move'),
    groupAdd: () => runAction(S, 'groupAdd'),
    memberAdd: () => runAction(S, 'memberAdd'),
    createOu: () => runAction(S, 'createOu'),
    compare: () => openCompare(S, S.params.other ?? ''),
    lockouts: () => runAction(S, 'lockouts'),
    logonByDc: () => runAction(S, 'logonByDc'),
    rights: () => runAction(S, 'rights'),
    presence: () => runAction(S, 'presence'),
    nested: () => { S.selectTab('groupes'); setTimeout(() => S.mounted.get('groupes')?.nested?.(), 40); },
    why: () => { S.selectTab('groupes'); setTimeout(() => S.mounted.get('groupes')?.why?.(), 400); },
    raw: () => { S.selectTab('attributs'); setTimeout(() => S.mounted.get('attributs')?.focusEditor?.(), 40); },
    reset: () => runAction(S, 'resetPassword'),
    options: () => runAction(S, 'options'),
    expiration: () => runAction(S, 'expiration'),
    triage: () => { S.selectTab('appel'); setTimeout(() => S.mounted.get('appel')?.read?.('triage'), 400); },
  };
  const fn = map[state];
  if (fn) fn();
  else console.warn(`État de fiche inconnu : ${esc(state)}`);
}
