// Comptes screen (docs/ops/comptes.md): management of the user accounts of the section scope (lockout diagnosis, unlock,
// password reset, enable and disable, expiration, collective actions) and the accounts Domenia itself works with
// (connection, secondary accounts, accesses to review, rights and transports). Hero with the scope of the section, three
// tabs, each mounted on its first display.
// Parameters: vue=gestion|acces|droits, compte=<sAMAccountName or DN> (opens its detail), action=mdp|verrouillages|
// expiration|identite, lire=1 (reads the lockouts at once, simulation only), filtre=<facet>, lot=deverrouiller|activer|
// desactiver|imposer|expiration (opens the collective action on the matching accounts), perimetre=choisir (opens the scope
// panel), corriger=connexion (CPT-009), acces=<id>|premier (opens « Utiliser un autre compte »).
import { glyph, createTabs, pill } from '../kit/index.js';
import { esc, reveal, announce } from '../ui.js';
import { mountGestion } from './comptes/gestion.js';
import { mountAcces } from './comptes/acces.js';
import { mountDroits } from './comptes/droits.js';
import { openScopePicker } from './comptes/scope.js';
import { relSpan, skeletonLines, errorSentence } from './comptes/shared.js';

/** The screen has its own stylesheet (css/pages/comptes.css), loaded by the router. */
export const stylesheet = true;

const VIEWS = { gestion: 'gestion', acces: 'acces', droits: 'droits' };
const longDate = new Intl.DateTimeFormat('fr-FR', { weekday: 'long', day: 'numeric', month: 'long' });
const RING = '<span class="glow-ring hero-ring" aria-hidden="true"></span>';
const ORBS = '<div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>';

function crumbs(path) {
  const parts = String(path ?? '').split(/\s*›\s*/).filter(Boolean);
  return parts.length ? `<ol class="cpt-crumbs" aria-label="Chemin du périmètre">${parts.map((p, n) => `<li data-j="${n}"${n === parts.length - 1 ? ' aria-current="location"' : ''}>${esc(p)}</li>`).join('')}</ol>` : '';
}

function scopeCard(scope) {
  if (!scope) {
    return `<div class="cpt-scope-top"><span class="cpt-scope-ico">${glyph('ou')}</span><span class="cpt-scope-k">Périmètre des comptes</span></div>
      <div class="cpt-scope-name">Aucun périmètre</div><p class="cpt-scope-note">Annuaire non connecté.</p>`;
  }
  const origin = scope.origin === 'section'
    ? pill('accent', 'Choix de la section', { icon: 'pin', size: 'sm', tip: 'Mémorisé pour ce domaine ; les autres sections gardent l’OU de travail' })
    : pill('info', 'OU de travail', { icon: 'ou', size: 'sm', tip: 'Défaut de toutes les sections sans choix propre' });
  return `<div class="cpt-scope-top"><span class="cpt-scope-ico">${glyph('ou')}</span><span class="cpt-scope-k" id="cpt-scope-k">Périmètre des comptes</span>${origin}</div>
    <div class="cpt-scope-name">${esc(scope.label)}</div>
    ${crumbs(scope.path)}
    <p class="cpt-scope-note">${scope.subtree ? 'Sous-OU comprises' : 'Cette OU seulement'} · jamais tout le domaine</p>
    <div class="cpt-scope-btns"><button class="btn sm" type="button" data-scope-pick aria-haspopup="dialog">${glyph('ou')}Changer de périmètre</button>
      ${scope.origin === 'section' ? `<button class="btn sm ghost" type="button" data-scope-reset>${glyph('undo')}Revenir à l’OU de travail</button>` : ''}</div>`;
}

function heroChips(session, list, sim) {
  const chips = [];
  if (session?.account?.login) chips.push(`<span class="chip" data-tip="Compte utilisé pour l’annuaire">${glyph('user')}<span class="mono">${esc(session.account.login)}</span></span>`);
  if (session?.controller?.dnsName) chips.push(`<span class="chip" data-tip="Contrôleur lu">${glyph('server')}${esc(session.controller.dnsName)}${session.controller.site ? ` · ${esc(session.controller.site)}` : ''}</span>`);
  if (list?.readAt) chips.push(`<span class="chip info">${glyph(sim ? 'sparkles' : 'database')}${relSpan(list.readAt, { prefix: sim ? 'Annuaire fictif · lu ' : 'Lu ' })}</span>`);
  if (list?.policy) chips.push(`<span class="chip" data-tip="Stratégie de mot de passe et de verrouillage du domaine">${glyph('key')}${esc(list.policy.label)}</span>`);
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
  let alive = true;

  main.innerHTML = `<div class="page cpt">
    <section class="hero cpt-hero reveal" data-slot="hero">${RING}${ORBS}
      <div class="cpt-hero-grid">
        <div class="cpt-hero-main">
          <div class="eyebrow">${glyph('users')}<span>Gestion des comptes</span><span class="cpt-eyebrow-date">${esc(longDate.format(new Date()))}</span></div>
          <h1 class="gradient-text">Comptes</h1>
          <p class="lead">Verrouillages, mots de passe, activation et expiration des comptes du périmètre. Aucune écriture sans plan relu, confirmation, reçu et relecture ; jamais rejouée.</p>
          <div class="chips cpt-chips"></div>
          <div class="hero-row">
            <button class="btn primary" type="button" data-reload>${glyph('refresh')}Actualiser la liste</button>
            <button class="btn" type="button" data-go-locked>${glyph('lock')}Voir les verrouillés</button>
          </div>
        </div>
        <aside class="cpt-scope-card" aria-labelledby="cpt-scope-k">${skeletonLines(4)}</aside>
      </div>
    </section>
    <div class="cpt-tabs-host reveal"></div>
  </div>`;
  const stopReveal = reveal(main);

  const simulated = () => app?.mode === 'simulation' || app?.webViewRuntime === 'apercu' || session?.connection?.state === 'simulated';

  function paintHero() {
    const h1 = main.querySelector('.cpt-hero h1');
    if (scope) h1.textContent = `Comptes · OU ${scope.label}`;
    main.querySelector('.cpt-chips').innerHTML = heroChips(session, list, simulated());
    main.querySelectorAll('.cpt-chips [data-j]').forEach((el) => el.style.setProperty('--j', el.dataset.j));
    const card = main.querySelector('.cpt-scope-card');
    card.innerHTML = scopeCard(scope);
    card.querySelectorAll('[data-j]').forEach((el) => el.style.setProperty('--j', el.dataset.j));
  }

  async function loadScope() {
    try {
      scope = await ctx.call('accounts.scope.get');
      if (alive) paintHero();
    } catch (err) {
      console.error(err);
      if (alive) main.querySelector('.cpt-scope-card').innerHTML = `<p class="cpt-inline-error">${glyph('alert')}${esc(errorSentence(err))}</p>`;
    }
  }

  async function pickScope() {
    const next = await openScopePicker(ctx, { current: scope });
    if (!next || !alive) return;
    scope = next;
    paintHero();
    main.querySelector('.cpt-scope-card').classList.add('changed');
    setTimeout(() => main.querySelector('.cpt-scope-card')?.classList.remove('changed'), 1100);
    ctx.toast(`Périmètre des comptes : ${next.label}${next.subtree ? ' et ses sous-OU' : ''}.`, { tone: 'ok' });
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
      paintHero();
      const urgent = next.counts.locked + next.counts.lockToCheck;
      tabs?.setCount('gestion', next.counts.total, urgent ? 'alert' : 'off');
    },
    onScope: () => loadScope(),
    pickScope,
    setCount: (n) => tabs?.setCount('acces', n || null, 'warn'),
  };

  main.querySelector('.cpt').addEventListener('click', async (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    if (b.matches('[data-scope-pick]')) pickScope();
    else if (b.matches('[data-scope-reset]')) {
      try {
        scope = await ctx.call('accounts.scope.reset');
        paintHero();
        ctx.toast('Retour à l’OU de travail pour les comptes.', { tone: 'info' });
        gestion?.reload();
      } catch (err) {
        console.error(err);
        ctx.toast(errorSentence(err), { tone: 'alert' });
      }
    } else if (b.matches('[data-reload]')) {
      tabs?.select('gestion');
      gestion?.reload();
      announce('Liste des comptes relue.');
    } else if (b.matches('[data-go-locked]')) {
      ctx.navigate('comptes', { vue: 'gestion', filtre: 'locked' });
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
    paintHero();
    const scopeLoaded = loadScope();
    tabs = createTabs(main.querySelector('.cpt-tabs-host'), {
      label: 'Sections de l’écran Comptes',
      key: params.vue ? undefined : 'comptes.vue',
      selected: VIEWS[params.vue] ?? 'gestion',
      tabs: [
        { id: 'gestion', label: 'Comptes de l’OU', icon: 'users', render: (p) => { gestion = mountGestion(p, ctx, page); } },
        { id: 'acces', label: 'Accès de Domenia', icon: 'key', render: (p) => { acces = mountAcces(p, ctx, page); } },
        { id: 'droits', label: 'Droits et transports', icon: 'shield', render: (p) => { droits = mountDroits(p, ctx); } },
      ],
    });
    if (params.perimetre === 'choisir') scopeLoaded.then(() => { if (alive) pickScope(); });
  });

  return () => {
    alive = false;
    stopReveal();
    gestion?.destroy();
    acces?.destroy();
    droits?.destroy();
    tabs?.destroy();
  };
}

