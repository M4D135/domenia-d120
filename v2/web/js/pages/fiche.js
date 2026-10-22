// « Fiche » screen (#/fiche?dn=…&tab=…&open=…): the card of one directory object — user, computer, group, OU or contact —
// with its header (kind, name, state pills, DN breadcrumb, actions), its tabs (general, account, groups, members, relations,
// rights, attributes, history, call sheet) and its writes through the write circuit. Domenia 1: FIC-001 to FIC-050 and lot R40
// (Domenia-CallSheet). Contract: docs/ops/fiche.md. The local projection is shown first (fiche.preview), the directory read
// replaces it (fiche.read); nothing is read on the network without the operator’s gesture: a route state (« open ») shows and
// highlights its card and button only (the read itself runs from a route in simulation only, with « run=1 », for captures).
import { createTabs, confirmDialog, openDialog, openDrawer, writeClipboard, glyph, NBSP, dnParent, parseDn } from '../kit/index.js';
import { esc, errorText, toast, announce, applyVars, reveal } from '../ui.js';
import { write, pickObject, pickOu } from './fiche/actions.js';
import { failure, skeleton, supportGroups, supportText, plural, stamp } from './fiche/common.js';
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

// Route states that would read the network: shown and highlighted only, unless the route asks « run=1 » in simulation.
const NETWORK_STATES = new Set(['move', 'compare', 'lockouts', 'logonByDc', 'rights', 'presence', 'nested', 'why', 'triage']);

export function render(main, ctx) {
  const dn = ctx.params.dn ?? '';
  if (!dn && ctx.params.q) return resolveThenOpen(main, ctx);
  if (!dn) return renderEmpty(main, ctx);

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
    // A directory read answered (success or failure): the local preview, slower, is then ignored (never drawn over the read).
    settled: false,
    // GUID refused (FIC-033): the operator chose to open the object read anyway.
    acceptGuid: '',
    stopReveal: () => {},
    /** Opens another fiche (or this one with other parameters); unsaved input is guarded by the router (FIC-007). */
    open(target, params = {}) {
      ctx.navigate('fiche', { dn: target, ...params });
    },
    /** Reads the fiche again from the directory (after a write, or « Relire »: only the cache of this object is forgotten). */
    reload: (o = {}) => load({ ...o, again: true }),
    /** Runs an action of the fiche by its id (header, band, tabs, palette, route). */
    act: (id, arg) => runAction(S, id, arg),
    /** Selects a tab (and brings the tabs into view when a tile of the header was used). */
    selectTab(id, { scroll = false } = {}) {
      if (!S.tabs) return;
      S.tabs.select(id);
      if (scroll) {
        const bar = bodyHost.querySelector('.k-tabs-scroll') ?? bodyHost;
        const box = bar.getBoundingClientRect();
        if (box.top < 0 || box.top > window.innerHeight * 0.6) bar.scrollIntoView({ block: 'start', behavior: 'smooth' });
      }
    },
    /** Runs fn once the tab is mounted (tabs render on their first opening). */
    withTab(id, fn) {
      S.selectTab(id);
      requestAnimationFrame(() => { const m = S.mounted.get(id); if (m && S.alive) fn(m); });
    },
    /**
     * A ping measured from the fiche (« Vérifier la présence ») is a newer observation than the read: the header tile, the
     * avatar dot and the freshness of the presence follow it at once, without another read. Nothing changes without a ping.
     */
    notePresence(r) {
      if (!S.sheet || !r?.computerDn || !r.checkedAt) return;
      const via = S.sheet.identity.kind === 'user' && r.computer ? ` (poste associé ${r.computer})` : '';
      const presence = { state: r.state, label: `${r.label}${via}`, checkedAt: r.checkedAt, computer: r.computer ?? null, computerDn: r.computerDn, detail: `${r.detail} Relevé le ${stamp(r.checkedAt)}.` };
      const freshness = S.sheet.freshness.map((f) => (f.nature === 'presence'
        ? { ...f, state: 'fresh', observedAt: r.checkedAt, ageSeconds: 0, lastAttempt: null, text: `${f.label}${NBSP}: ${stamp(r.checkedAt)}` } : f));
      S.sheet = { ...S.sheet, presence, freshness };
      S.header?.update(S.sheet);
    },
  };

  // Unsaved input (FIC-007, Test-DomeniaDraftNavigation): changing fiche, leaving the screen or reading again asks first. The
  // draft counts the general fields and the account options (UAC, expiry date, password change and unlock boxes); an abandon
  // confirmed puts every tab back to the values read (discard), so the guard is never disarmed while typed values stay shown.
  const draftCount = () => (S.draft?.count ?? 0) + (S.accountDraft?.count ?? 0);
  const dropDraft = () => {
    const count = draftCount();
    if (!count) return Promise.resolve(true);
    return confirmDialog({
      title: 'Saisies non enregistrées',
      message: `${plural(count, 'champ de la fiche a été modifié', 'champs de la fiche ont été modifiés')} sans enregistrement. Abandonner ces saisies pour changer de fiche ou la recharger${NBSP}? Rien n’est envoyé à l’annuaire.`,
      confirmLabel: 'Abandonner les saisies', cancelLabel: 'Continuer la saisie', danger: true, icon: 'undo',
    }).then((ok) => {
      if (ok) {
        for (const m of S.mounted.values()) m.discard?.();
        S.draft = null;
        S.accountDraft = null;
      }
      return !!ok;
    });
  };
  S.dropDraft = dropDraft;
  const releaseGuard = typeof ctx.guardLeave === 'function' ? ctx.guardLeave(() => dropDraft()) : () => {};

  async function load({ again = false, quiet = false, reread = false } = {}) {
    if (!again) {
      // Local projection first (FIC-030): shown at once, marked as such, without probes nor writes.
      ctx.call('fiche.preview', { dn }).then((preview) => {
        if (!S.alive || S.live || S.settled || !preview) return;
        show(preview);
      }).catch((err) => console.error(err));
    } else {
      S.header?.setBusy(true);
    }
    try {
      const sheet = await ctx.call('fiche.read', reread ? { dn, reread: true } : { dn });
      if (!S.alive) return;
      S.settled = true;
      // Identity check (FIC-033, Domenia 1 Assert-DomeniaObjectResultIdentity): the GUID captured at the selection (route
      // « guid ») or shown by the local preview must be the one read; otherwise the DN now names another object. The fiche stays
      // unavailable (no tab, no write) until the operator explicitly opens the object read.
      const expected = String(S.params.guid || (!S.live && S.sheet ? S.sheet.identity.guid : '')).toLowerCase();
      if (expected && sheet.identity.guid.toLowerCase() !== expected && S.acceptGuid !== sheet.identity.guid.toLowerCase()) {
        replaced(sheet, expected);
        return;
      }
      S.live = true;
      show(sheet, { again, quiet });
      if (!again) ctx.call('fiche.recent.add', { dn: sheet.identity.dn }).catch((err) => console.error(err));
    } catch (err) {
      if (!S.alive) return;
      S.settled = true;
      console.error(err);
      if (S.sheet && again) {
        // A read again that fails says only that: after a write, something may well have changed (never « nothing changed »).
        toast(err?.code === 'fiche.unknown'
          ? `Relecture impossible${NBSP}: l’objet n’est plus à ce DN (déplacé, renommé ou supprimé). La fiche affichée date de la lecture précédente.`
          : `Relecture impossible${NBSP}: ${errorText(err)} La fiche affichée date de la lecture précédente.`, { tone: 'warn', life: 8000 });
        S.header?.setBusy(false);
        return;
      }
      fatal(err);
    } finally {
      S.header?.setBusy(false);
    }
  }

  // FIC-033: the DN now names another object than the one chosen. Nothing of it is shown nor writable until the operator asks.
  function replaced(sheet, expected) {
    S.header?.destroy();
    S.tabs?.destroy();
    for (const m of S.mounted.values()) m.destroy?.();
    S.mounted.clear();
    S.header = null;
    S.tabs = null;
    S.sheet = null;
    page.dataset.kind = 'error';
    headHost.innerHTML = '';
    bodyHost.innerHTML = `<section class="card fi-card fi-fatal fi-replaced" role="alert">
      <div class="fi-replaced-ico">${glyph('alert')}</div>
      <h2>Objet remplacé depuis la sélection</h2>
      <p>Ce DN désigne maintenant un autre objet (GUID différent)${NBSP}: <b>${esc(sheet.identity.name)}</b>, ${esc(sheet.identity.kindLabel.toLowerCase())}. L’objet choisi a été supprimé, déplacé ou recréé. Actualisez la liste d’origine${NBSP}; aucune action n’est proposée sur l’objet relu tant que vous ne l’ouvrez pas explicitement.</p>
      <dl class="fi-replaced-ids"><dt>GUID attendu</dt><dd class="mono">${esc(expected)}</dd><dt>GUID relu</dt><dd class="mono">${esc(sheet.identity.guid)}</dd></dl>
      <div class="fi-fatal-actions"><button class="btn" type="button" data-back>${glyph('search')}Rechercher un objet</button>
        <button class="btn subtle" type="button" data-open-read>${glyph('object')}Ouvrir l’objet relu</button></div></section>`;
    bodyHost.querySelector('[data-back]')?.addEventListener('click', () => ctx.navigate('fiche', {}));
    bodyHost.querySelector('[data-open-read]')?.addEventListener('click', () => {
      S.acceptGuid = sheet.identity.guid.toLowerCase();
      S.live = true;
      bodyHost.innerHTML = tabsSkeleton();
      headHost.innerHTML = headSkeleton();
      show(sheet);
    });
    announce(`Objet remplacé depuis la sélection${NBSP}: la fiche reste indisponible.`, { assertive: true });
  }

  // A fiche that cannot be read: header and tabs are destroyed (timers, command bar) before the error is shown.
  function fatal(err) {
    S.header?.destroy();
    S.tabs?.destroy();
    for (const m of S.mounted.values()) m.destroy?.();
    S.mounted.clear();
    S.header = null;
    S.tabs = null;
    S.sheet = null;
    page.dataset.kind = 'error';
    headHost.innerHTML = '';
    bodyHost.innerHTML = `<section class="card fi-card fi-fatal">${failure(err, { title: err?.code === 'fiche.unknown' ? 'Objet introuvable' : 'Fiche illisible' })}
      <div class="fi-fatal-actions"><button class="btn" type="button" data-back>${glyph('search')}Rechercher un objet</button></div></section>`;
    bodyHost.querySelector('[data-retry]')?.addEventListener('click', () => { bodyHost.innerHTML = tabsSkeleton(); load(); });
    bodyHost.querySelector('[data-back]')?.addEventListener('click', () => ctx.navigate('fiche', {}));
  }

  // First display builds header and tabs. A later one repaints nothing when nothing shown changed (FIC-031), only the display
  // fields that changed when identity, state, memberships and links are the same (signature), and the tabs that depend on
  // memberships and links otherwise.
  function show(sheet, { again = false, quiet = false } = {}) {
    const previous = S.sheet;
    S.sheet = sheet;
    page.dataset.kind = sheet.identity.kind;
    if (!previous || previous.identity.kind !== sheet.identity.kind || tabsChanged(previous, sheet)) {
      build(sheet);
      openRoute();
      commands(sheet);
      return;
    }
    openRoute();
    if (displayKey(previous) === displayKey(sheet) && !previous.origin.preview) {
      S.header.update(sheet);
      for (const m of S.mounted.values()) m.touch?.(sheet);
      if (again && !quiet) announce('Fiche relue depuis l’annuaire : aucun changement.');
      return;
    }
    S.header.update(sheet);
    for (const t of sheet.tabs) if (Number.isFinite(t.count)) S.tabs.setCount(t.id, t.count);
    for (const m of S.mounted.values()) m.update?.(sheet, previous);
    if (previous.signature !== sheet.signature || previous.origin.preview) {
      for (const m of S.mounted.values()) if (again || previous.origin.preview) m.refresh?.();
    }
    commands(sheet);
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
        S.header?.markTab(id);
        // The tab follows the address without a new history entry, so that a reload or a link reopens it.
        const params = new URLSearchParams(location.hash.split('?')[1] ?? '');
        params.set('tab', id);
        params.delete('open');
        params.delete('run');
        params.delete('other');
        history.replaceState(null, '', `#/fiche?${params.toString()}`);
      },
    });
    S.tabs.select(wanted);
    page.dataset.tab = S.tabs.current();
    S.header.markTab(S.tabs.current());
    applyVars(page);
    S.stopReveal();
    S.stopReveal = reveal(page);
  }

  // Route states (links, captures: « open »): handled once, after the directory read, then removed from the address so that a
  // return to this address never runs them again.
  function openRoute() {
    if (S.routeDone || !S.live || !S.params.open) return;
    S.routeDone = true;
    const state = S.params.open;
    const params = new URLSearchParams(location.hash.split('?')[1] ?? '');
    params.delete('open');
    params.delete('run');
    params.delete('other');
    history.replaceState(null, '', `#/fiche?${params.toString()}`);
    Promise.resolve(ctx.app).then((info) => {
      if (!S.alive) return;
      const run = !NETWORK_STATES.has(state) || (info?.mode === 'simulation' && S.params.run === '1');
      setTimeout(() => { if (S.alive) routeState(S, state, run); }, 80);
    }).catch((err) => console.error(err));
  }

  // Palette commands of this fiche (FIC-040: palette:lockouts of Domenia 1), replaced at each read, through the API of the shell
  // (ctx.commands.set, docs/SHELL.md § 3); without the shell they are simply not offered.
  const dropCommands = () => ctx.commands?.set?.([]);
  function commands(sheet) {
    if (typeof ctx.commands?.set !== 'function') return;
    const id = sheet.identity;
    const list = [
      { id: 'fiche-reread', label: `Relire la fiche ${id.name}`, icon: 'refresh', kbd: 'F5', keywords: 'fiche relire actualiser annuaire', run: () => S.act('reread') },
      { id: 'fiche-copy', label: 'Copier le résumé de la fiche', icon: 'copy', keywords: 'fiche copier résumé presse-papiers', run: () => S.act('copySummary') },
    ];
    if (id.kind === 'user') {
      list.unshift({ id: 'fiche-lockouts', label: `Lire les verrouillages de ${id.name} (4740)`, icon: 'lock', keywords: 'verrouillages lockouts 4740 journal sécurité compte', run: () => S.act('lockouts') });
      list.push({ id: 'fiche-callsheet', label: 'Ouvrir la fiche d’appel', icon: 'lifebuoy', keywords: 'appel ticket support', run: () => S.act('callSheet') });
      list.push({ id: 'fiche-support', label: 'Résumé support', icon: 'lifebuoy', keywords: 'support faits datés', run: () => S.act('support') });
      list.push({ id: 'fiche-compare', label: 'Comparer les droits avec un autre compte…', icon: 'split', keywords: 'comparer droits groupes', run: () => S.act('compare') });
    }
    if (id.kind === 'computer') list.push({ id: 'fiche-poste', label: 'Ouvrir dans l’écran Poste', icon: 'monitor', keywords: 'poste ordinateur', run: () => S.act('openPoste') });
    ctx.commands.set(list.map((c) => ({ effect: c.id === 'fiche-lockouts' || c.id === 'fiche-reread' ? 'read' : 'local', ...c })));
  }

  load();

  const onKey = (e) => {
    if (e.key !== 'F5' || e.ctrlKey || e.altKey || e.metaKey || e.defaultPrevented) return;
    // F5 belongs to an open panel or dialog first (the tree of the OU picker reads its branch again with it).
    if (document.querySelector('[aria-modal="true"]')) return;
    e.preventDefault();
    if (!S.sheet) return;
    S.act('reread');
  };
  document.addEventListener('keydown', onKey);
  return () => {
    S.alive = false;
    releaseGuard();
    dropCommands();
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
      <div class="fi-fatal-actions"><button class="btn" type="button" data-search>${glyph('search')}Rechercher « ${esc(ctx.params.q)} »</button></div></section></div>`;
    main.querySelector('[data-search]')?.addEventListener('click', () => ctx.navigate('rechercher', { q: ctx.params.q }));
  });
  return () => { alive = false; };
}

function tabsChanged(a, b) {
  return a.tabs.map((t) => t.id).join() !== b.tabs.map((t) => t.id).join();
}

/** What the fiche shows, without the dates of the read: identical keys mean nothing to repaint (FIC-031). */
function displayKey(sheet) {
  const { origin, freshness, support, ...rest } = sheet;
  return JSON.stringify([rest, origin.source, origin.controller, origin.preview, (support ?? []).map((f) => [f.group, f.label, f.value, f.limit])]);
}

function headSkeleton() {
  return `<section class="fi-hero fi-hero-sk" aria-busy="true"><div class="fi-hero-grid"><div class="fi-id">
    <span class="skeleton fi-sk-avatar"></span><div class="fi-sk-stack"><span class="skeleton fi-sk-line w25"></span><span class="skeleton fi-sk-title"></span>
    <span class="skeleton fi-sk-line w55"></span><span class="skeleton fi-sk-line w40"></span></div></div></div></section>
    <div class="fi-stats">${Array.from({ length: 5 }, () => `<div class="fi-stat">${skeleton(3)}</div>`).join('')}</div>`;
}

function tabsSkeleton() {
  return `<div class="fi-tabs-sk"><div class="fi-sk-tabs">${Array.from({ length: 6 }, () => '<span class="skeleton fi-sk-tab"></span>').join('')}</div>
    <div class="fi-sk-grid"><section class="card fi-card">${skeleton(6)}</section><section class="card fi-card">${skeleton(5)}</section></div></div>`;
}

/** Plan of one write, then a re-read of the fiche once the receipt is in (the receipt panel stays open). */
function writeAndReload(S, plan, args, subtitle) {
  return write(S.ctx, plan, args, { subtitle, onDone: () => S.reload({ quiet: true, reread: true }) });
}

/**
 * DN of an object once moved (FIC-018): its own RDN under the destination. The fiche opens there with the GUID captured, so
 * the read checks it is the same object (FIC-033); the old DN is never read again.
 */
export function movedDn(dn, target) {
  const parts = parseDn(dn);
  return parts.length && target ? `${parts[0].rdn},${target}` : '';
}

/** Résumé support of a user (FIC-044): dated facts by rubric, each with its source, reader and date, copyable. */
function openSupport(S) {
  const sheet = S.sheet;
  const body = document.createElement('div');
  body.dataset.page = 'fiche';
  body.className = 'fi-support-drawer';
  body.innerHTML = `<p class="fi-picker-hint">${glyph('info')}Faits lus avec la fiche, chacun avec sa source, le contrôleur qui a répondu et la date de la lecture. La dernière ouverture de session est une valeur répliquée, à 14${NBSP}jours près.</p>
    <div class="fi-support">${supportGroups(sheet.support)}</div>`;
  openDrawer({
    title: 'Résumé support', subtitle: `${sheet.identity.name} · ${sheet.identity.sam ?? ''}`, icon: 'lifebuoy', key: 'fiche.support', width: 560, minWidth: 420, maxWidth: 900, body,
    actions: [
      { id: 'close', label: 'Fermer', run: (p) => p.close() },
      { id: 'copy', label: 'Copier le résumé support', primary: true, run: () => writeClipboard(supportText(sheet.support, sheet.identity.name)).then((ok) => toast(ok ? 'Résumé support copié.' : 'Copie impossible.', { tone: ok ? 'ok' : 'warn', life: 2600 })) },
    ],
  });
  applyVars(body);
}

/** FIC-008: first confirmation in the page (the word SUPPRIMER), the plan then asks for the exact name of the object. */
async function confirmDeleteWord(S) {
  const sheet = S.sheet;
  const children = sheet.counts.children;
  const d = openDialog({
    title: `Supprimer ${sheet.identity.name}${NBSP}?`, icon: 'trash', size: 'sm',
    body: `<div data-page="fiche" class="fi-delete">
      <p class="k-dlg-text">La suppression est définitive et non récursive. Deux confirmations sont demandées${NBSP}: le mot SUPPRIMER ici, puis le nom exact de l’objet dans le plan.</p>
      <ul class="fi-delete-facts">
        <li>${glyph('shield')}Aucune écriture tant que le plan n’est pas confirmé${NBSP}; le plan relit l’objet et ses enfants.</li>
        ${Number.isFinite(children) && children > 0 ? `<li>${glyph('alert')}${esc(plural(children, 'objet direct', 'objets directs'))} dans cette branche${NBSP}: la suppression sera refusée.</li>` : ''}
        <li>${glyph('link')}Les associations locales de l’objet (postes ou comptes associés) sont retirées de la base après la suppression.</li>
      </ul>
      <label class="fi-field-label" for="fi-delete-word">Saisissez SUPPRIMER pour continuer</label>
      <input id="fi-delete-word" class="input mono" type="text" autocomplete="off" spellcheck="false" maxlength="20" aria-describedby="fi-delete-hint">
      <p id="fi-delete-hint" class="fi-faint">En capitales, sans collage.</p></div>`,
    actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'go', label: 'Préparer la suppression', danger: true, disabled: true }],
  });
  const input = /** @type {HTMLInputElement|null} */ (d.el?.querySelector('#fi-delete-word'));
  const go = /** @type {HTMLButtonElement|null} */ (d.el?.querySelector('[data-id="go"]'));
  const sync = () => { if (go) go.disabled = input?.value !== 'SUPPRIMER'; };
  input?.addEventListener('input', sync);
  input?.addEventListener('paste', (e) => e.preventDefault());
  input?.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && input.value === 'SUPPRIMER') { e.preventDefault(); go?.click(); }
  });
  sync();
  return (await d.result) === 'go' && input?.value === 'SUPPRIMER';
}

/** Actions of the fiche (header, band, tabs, palette and route states « open »). */
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
      S.withTab('general', (m) => m.edit?.());
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
      S.withTab('compte', (m) => m.focus?.(id));
      return;
    case 'lockCard':
      S.withTab('compte', (m) => m.focus?.('lockouts', { run: false }));
      return;
    case 'move': {
      // GUID captured now (FIC-018): the plan refuses an object that changed while the picker was open.
      const guid = sheet.identity.guid;
      const target = await pickOu(S.ctx, {
        title: `Déplacer ${name}`, subtitle: 'OU ou conteneur de destination', confirm: 'Préparer le déplacement',
        current: sheet.identity.parentDn ?? undefined,
        note: 'Le DN et le GUID de l’objet sont capturés maintenant et revérifiés par le plan puis avant l’envoi.',
      });
      if (!target) return;
      // After a move applied (or already done), the fiche follows the object to its new DN, read again by its GUID, once the
      // receipt panel is closed: opening the new address at once (hashchange) would close the receipt before it is read.
      let moved = '';
      await write(S.ctx, 'fiche.move.plan', { dn, target: target.dn, guid }, {
        subtitle,
        onDone: (receipt) => {
          const to = receipt && (receipt.result === 'applied' || receipt.result === 'noChange') ? movedDn(dn, target.dn) : '';
          if (to && to.toLowerCase() !== dn.toLowerCase()) moved = to;
          else S.reload({ quiet: true, reread: true });
        },
        onClosed: () => { if (moved) S.open(moved, { guid }); },
      });
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
        toast(`OU de travail${NBSP}: ${info?.scope?.label ?? name} et ses sous-OU. Choix mémorisé dans les préférences de Domenia.`, { tone: 'ok' });
      } catch (err) {
        toast(`OU de travail inchangée${NBSP}: ${errorText(err)}`, { tone: 'warn' });
      }
      return;
    }
    case 'delete': {
      if (!(await confirmDeleteWord(S))) return;
      await write(S.ctx, 'fiche.delete.plan', { dn }, { subtitle, onDone: (receipt) => { if (receipt?.result === 'applied') S.ctx.navigate('fiche', {}); } });
      return;
    }
    case 'lockouts':
      S.withTab('compte', (m) => m.focus?.('lockouts', { run: true }));
      return;
    case 'logonByDc':
      S.withTab('compte', (m) => m.focus?.('logonByDc', { run: true }));
      return;
    case 'presence':
      S.withTab('general', (m) => m.presence?.({ run: true }));
      return;
    case 'rights':
      S.withTab('droits', (m) => m.focus?.({ run: true }));
      return;
    case 'compare':
      openCompare(S);
      return;
    case 'callSheet':
      S.selectTab('appel', { scroll: true });
      return;
    case 'support':
      openSupport(S);
      return;
    case 'openPoste':
      S.ctx.navigate('poste', { dn });
      return;
    case 'reread':
      // Every read again goes through the same rule (header, palette, F5): unsaved input asks first.
      if (await S.dropDraft()) await S.reload({ reread: true });
      return;
    case 'copySummary':
      writeClipboard(sheet.summary).then((ok) => toast(ok ? 'Résumé copié.' : 'Copie impossible.', { tone: ok ? 'ok' : 'warn', life: 2600 }));
      return;
    case 'openParent':
      if (sheet.identity.parentDn) S.open(sheet.identity.parentDn);
      return;
    default:
      break;
  }
}

/**
 * States opened by the address (« open »): edit, move, groupAdd, nested groups, compare, raw editor, reads… A state that would
 * read the network (NETWORK_STATES) runs only when `run` is true (simulation with « run=1 »); otherwise its card and button are
 * shown and highlighted, the read waits for the operator’s click.
 */
function routeState(S, state, run) {
  const map = {
    edit: () => runAction(S, 'edit'),
    move: () => (run ? runAction(S, 'move') : S.header && document.querySelector('.fi-cmd [data-cmd="more"]')?.classList.add('fi-focus')),
    groupAdd: () => runAction(S, 'groupAdd'),
    memberAdd: () => runAction(S, 'memberAdd'),
    createOu: () => runAction(S, 'createOu'),
    compare: () => openCompare(S, S.params.other ?? '', { submit: run }),
    lockouts: () => S.withTab('compte', (m) => m.focus?.('lockouts', { run })),
    logonByDc: () => S.withTab('compte', (m) => m.focus?.('logonByDc', { run })),
    rights: () => S.withTab('droits', (m) => m.focus?.({ run })),
    presence: () => S.withTab('general', (m) => m.presence?.({ run })),
    nested: () => S.withTab('groupes', (m) => m.focus?.('nested', { run })),
    why: () => S.withTab('groupes', (m) => m.focus?.('why', { run })),
    raw: () => S.withTab('attributs', (m) => m.focusEditor?.()),
    reset: () => runAction(S, 'resetPassword'),
    options: () => runAction(S, 'options'),
    expiration: () => runAction(S, 'expiration'),
    support: () => runAction(S, 'support'),
    triage: () => S.withTab('appel', (m) => m.focus?.('triage', { run })),
  };
  const fn = map[state];
  if (fn) fn();
  else console.warn(`État de fiche inconnu${NBSP}: ${esc(state)}`);
}
