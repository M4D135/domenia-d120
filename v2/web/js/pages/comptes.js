// Comptes screen (docs/ops/comptes.md): management of the user accounts of the section scope (lockout diagnosis, unlock,
// password reset, enable and disable, expiration, collective actions) and the accounts Domenia itself works with
// (connection, secondary accounts, accesses to review, rights and transports). A compact header (title, scope of the
// section, context chips) leaves the whole height to the work: three tabs, each mounted on its first display.
// Parameters: vue=gestion|acces|droits, compte=<sAMAccountName or DN> (opens its detail), action=mdp|verrouillages|
// expiration|identite, lire=1 (reads the lockouts at once, simulation only), filtre=<facet>, lot=deverrouiller|activer|
// desactiver|imposer|expiration (opens the collective action), perimetre=choisir (opens the scope panel),
// corriger=connexion (CPT-009), acces=<id>|premier (opens « Utiliser un autre compte »), compte-connexion=changer (opens
// « Changer de compte »).
import { glyph, createTabs, NBSP } from '../kit/index.js';
import { esc, reveal, announce } from '../ui.js';
import { mountGestion } from './comptes/gestion.js';
import { mountAcces } from './comptes/acces.js';
import { mountDroits } from './comptes/droits.js';
import { openScopePicker } from './comptes/scope.js';
import { relSpan, errorSentence } from './comptes/shared.js';

/** The screen has its own stylesheet (css/pages/comptes.css), loaded by the router. */
export const stylesheet = true;

const VIEWS = { gestion: 'gestion', acces: 'acces', droits: 'droits' };

/** Scope chip of the header: the OU, its origin and its depth; a click opens the scope panel. */
function scopeChip(scope) {
  if (!scope) {
    return `<span class="cpt-scope-chip off">${glyph('ou')}<span class="cpt-scope-chip-main"><b>Aucun périmètre</b><span>Annuaire non connecté</span></span></span>`;
  }
  const path = String(scope.path ?? '').split(/\s*›\s*/).filter(Boolean).join(' › ');
  const origin = scope.origin === 'section' ? 'Choix de la section' : 'OU de travail';
  return `<button class="cpt-scope-chip" type="button" data-scope-pick aria-haspopup="dialog"
      data-tip="${esc(path || scope.label)} · ${esc(scope.subtree ? 'sous-OU comprises' : 'cette OU seulement')} · jamais tout le domaine">
      <span class="cpt-scope-chip-ico">${glyph('ou')}</span>
      <span class="cpt-scope-chip-main"><b>OU ${esc(scope.label)}</b><span>${esc(origin)} · ${esc(scope.subtree ? 'sous-OU comprises' : 'cette OU seulement')}</span></span>
      <span class="cpt-scope-chip-go">${glyph('chevronDown')}<span class="visually-hidden">Changer de périmètre</span></span>
    </button>${scope.origin === 'section' ? `<button class="btn xs ghost cpt-scope-reset" type="button" data-scope-reset data-tip="Les autres sections gardent l’OU de travail">${glyph('undo')}OU de travail</button>` : ''}`;
}

function contextChips(session, list, sim, tab) {
  const chips = [];
  if (session?.account?.login) chips.push(`<span class="chip" data-tip="Compte utilisé pour l’annuaire">${glyph('user')}<span class="mono">${esc(session.account.login)}</span></span>`);
  if (session?.controller?.dnsName) chips.push(`<span class="chip" data-tip="Contrôleur de la session${session.controller.site ? ` · site ${esc(session.controller.site)}` : ''}">${glyph('server')}${esc(session.controller.dnsName)}</span>`);
  if (tab === 'gestion' && list?.readAt) chips.push(`<span class="chip info">${glyph(sim ? 'sparkles' : 'database')}${relSpan(list.readAt, { prefix: sim ? 'Annuaire fictif · lu ' : 'Lu ' })}</span>`);
  if (tab === 'gestion' && list?.policy) chips.push(`<span class="chip" data-tip="${esc(list.policy.label)}">${glyph('key')}Stratégie${NBSP}: ${esc(String(list.policy.maxPasswordAgeDays))}${NBSP}j · ${esc(String(list.policy.minPasswordLength))}${NBSP}car.</span>`);
  return chips.map((c, n) => c.replace('<span class="chip', `<span data-j="${n}" class="chip`)).join('');
}

export function render(main, ctx) {
  const params = ctx.params ?? {};
  let session = null;
  let app = null;
  let scope = null;
  let list = null;
  let gestion = null;
  let acces = null;
  let droits = null;
  let tabs = null;
  let tab = VIEWS[params.vue] ?? 'gestion';
  let alive = true;

  main.innerHTML = `<div class="page cpt">
    <header class="cpt-head reveal">
      <span class="cpt-head-glow" aria-hidden="true"></span>
      <div class="cpt-head-id">
        <span class="cpt-head-ico" aria-hidden="true">${glyph('users')}</span>
        <div class="cpt-head-titles">
          <h1 class="gradient-text">Comptes</h1>
          <p class="cpt-head-lead">Aucune écriture sans plan relu, confirmation, reçu et relecture${NBSP}; jamais rejouée.</p>
        </div>
      </div>
      <div class="cpt-head-scope"><span class="skeleton cpt-sk-chip"></span></div>
      <div class="cpt-head-chips chips"></div>
      <button class="cpt-access-chip" type="button" data-access-oldest hidden></button>
    </header>
    <div class="cpt-tabs-host"></div>
  </div>`;
  const stopReveal = reveal(main);

  const simulated = () => app?.mode === 'simulation' || app?.webViewRuntime === 'apercu' || session?.connection?.state === 'simulated';

  function paintHead() {
    const host = main.querySelector('.cpt-head-scope');
    host.innerHTML = scopeChip(scope);
    const chips = main.querySelector('.cpt-head-chips');
    chips.innerHTML = contextChips(session, list, simulated(), tab);
    chips.querySelectorAll('[data-j]').forEach((el) => el.style.setProperty('--j', el.dataset.j));
  }

  async function loadScope() {
    try {
      scope = await ctx.call('accounts.scope.get');
      if (alive) paintHead();
    } catch (err) {
      console.error(err);
      if (alive) main.querySelector('.cpt-head-scope').innerHTML = `<p class="cpt-inline-error">${glyph('alert')}${esc(errorSentence(err))}</p>`;
    }
  }

  async function pickScope() {
    const next = await openScopePicker(ctx, { current: scope });
    if (!next || !alive) return;
    scope = next;
    paintHead();
    const chip = main.querySelector('.cpt-scope-chip');
    chip?.classList.add('changed');
    setTimeout(() => chip?.classList.remove('changed'), 1100);
    ctx.toast(`Périmètre des comptes${NBSP}: ${next.label}${next.subtree ? ' et ses sous-OU' : ''}.`, { tone: 'ok' });
    tabs?.select('gestion');
    gestion?.reload();
  }

  const page = {
    params,
    simulated,
    autoLoad: () => simulated(),
    onList: (next) => {
      list = next;
      scope = next.scope;
      paintHead();
      const urgent = next.counts.locked + next.counts.lockToCheck;
      tabs?.setCount('gestion', next.counts.total, urgent ? 'alert' : 'off');
    },
    onScope: () => loadScope(),
    pickScope,
    setCount: (n) => tabs?.setCount('acces', n || null, 'warn'),
    onSession: () => window.dispatchEvent(new CustomEvent('domenia:session-changed')),
  };

  // Accesses to review (CPT-001), visible from every tab of the screen: badge, tip, a click opens the oldest request.
  // accounts.access.revision is local (names and counts only); read every 2 s while the screen is shown.
  let accessTimer = 0;
  let oldest = null;
  async function pollAccess() {
    if (!alive || document.hidden) return;
    try {
      const r = await ctx.call('accounts.access.revision');
      if (!alive) return;
      oldest = r.oldestPendingId;
      tabs?.setCount('acces', r.pending || null, 'warn');
      const label = r.pending === 1 ? '1 accès à revoir' : `${r.pending} accès à revoir`;
      // The « Accès » slot of the top bar keeps the count on every screen (docs/SHELL.md § 9); its click opens Comptes.
      ctx.access?.report?.({ suspended: r.pending, detail: r.pending ? `${label}${r.oldestPendingLabel ? ` · plus ancien${NBSP}: ${r.oldestPendingLabel}` : ''}` : '' });
      const chip = main.querySelector('.cpt-access-chip');
      chip.hidden = r.pending === 0;
      if (r.pending) {
        if (chip.dataset.count !== String(r.pending)) {
          chip.innerHTML = `${glyph('bell')}<b>${esc(String(r.pending))}</b><span>accès à revoir</span>`;
          chip.classList.remove('bump');
          void chip.offsetWidth;
          chip.classList.add('bump');
          chip.dataset.count = String(r.pending);
        }
        chip.dataset.tip = `${label}${r.oldestPendingLabel ? ` · plus ancien${NBSP}: ${r.oldestPendingLabel}` : ''} · ouvrir «${NBSP}Utiliser un autre compte${NBSP}»`;
        chip.setAttribute('aria-label', chip.dataset.tip);
      } else {
        delete chip.dataset.count;
      }
    } catch (err) {
      console.error(err);
    }
  }
  const onAccessChanged = () => pollAccess();
  window.addEventListener('domenia:access-changed', onAccessChanged);

  main.querySelector('.cpt-head').addEventListener('click', async (e) => {
    const b = e.target instanceof Element ? e.target.closest('button') : null;
    if (!b) return;
    if (b.matches('[data-access-oldest]')) {
      tabs?.select('acces');
      acces?.openRequest(oldest);
    } else if (b.matches('[data-scope-pick]')) pickScope();
    else if (b.matches('[data-scope-reset]')) {
      try {
        scope = await ctx.call('accounts.scope.reset');
        paintHead();
        ctx.toast('Retour à l’OU de travail pour les comptes.', { tone: 'info' });
        gestion?.reload();
      } catch (err) {
        console.error(err);
        ctx.toast(errorSentence(err), { tone: 'alert' });
      }
    }
  });

  // ?ou=<DN>: a link « Voir les comptes de cette OU » (Fiche, Accueil) chooses the scope of the section first (local
  // preferences, checked in the local OU index; the root is refused by the engine).
  const chooseFromLink = params.ou
    ? ctx.call('accounts.scope.set', { dn: params.ou, subtree: params.sousou !== 'non' }).catch((err) => {
      console.error(err);
      ctx.toast(errorSentence(err, 'Périmètre non changé.'), { tone: 'warn' });
    })
    : Promise.resolve();

  Promise.all([
    Promise.resolve(ctx.app).then((info) => { app = info; }),
    ctx.call('session.info').then((s) => { session = s; }).catch((err) => console.error(err)),
    chooseFromLink,
  ]).then(() => {
    if (!alive) return;
    paintHead();
    const scopeLoaded = loadScope();
    tabs = createTabs(main.querySelector('.cpt-tabs-host'), {
      label: 'Sections de l’écran Comptes',
      key: params.vue ? undefined : 'comptes.vue',
      selected: tab,
      onChange: (id) => {
        tab = id;
        main.querySelector('.cpt').dataset.tab = id;
        paintHead();
        announce(id === 'gestion' ? 'Comptes de l’OU.' : id === 'acces' ? 'Accès de Domenia.' : 'Droits et transports.');
      },
      tabs: [
        { id: 'gestion', label: 'Comptes de l’OU', icon: 'users', render: (p) => { gestion = mountGestion(p, ctx, page); } },
        { id: 'acces', label: 'Accès de Domenia', icon: 'key', render: (p) => { acces = mountAcces(p, ctx, page); } },
        { id: 'droits', label: 'Droits et transports', icon: 'shield', render: (p) => { droits = mountDroits(p, ctx); } },
      ],
    });
    tab = tabs.current();
    main.querySelector('.cpt').dataset.tab = tab;
    paintHead();
    if (params.perimetre === 'choisir') scopeLoaded.then(() => { if (alive) pickScope(); });
    pollAccess();
    accessTimer = setInterval(pollAccess, 2000);
  });

  // A new session (« Changer de compte », CPT-007): the chips and the list of the accounts are read again for it.
  const onSession = () => ctx.call('session.info').then((s) => {
    if (!alive) return;
    session = s;
    paintHead();
    gestion?.reload();
  }).catch((err) => console.error(err));
  window.addEventListener('domenia:session-changed', onSession);

  return () => {
    alive = false;
    clearInterval(accessTimer);
    window.removeEventListener('domenia:session-changed', onSession);
    window.removeEventListener('domenia:access-changed', onAccessChanged);
    stopReveal();
    gestion?.destroy();
    acces?.destroy();
    droits?.destroy();
    tabs?.destroy();
  };
}

