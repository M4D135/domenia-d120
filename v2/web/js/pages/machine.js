// Comptes machine (Domenia 1 MAC-001 to MAC-003, with CPT-015 for the trial): which account the next operation on a
// workstation takes (C$, consoles, inventory, diagnostic, sessions), by one rule shown level by level; the account typed for
// the session in the « Compte poste » panel (memory only); the light access trial on one chosen workstation; and the account
// of the secrets reads. Names only on this screen: a password never comes back from the engine. Contract: docs/ops/schema.md
// § 10 to 16.
//
// Parameters: poste=<nom du poste> (workstation of the rule and of the trial) · panneau=compte (opens the panel) ·
// essai=1 (simulation only, with poste: runs the trial at once for captures and scenarios; in directory mode the trial always
// waits for the click).
import { glyph } from '../kit/glyphs.js';
import { esc, int, NBSP, debounce, uid } from '../kit/util.js';
import { applyVars, reveal, toast, announce, formatDateTime, relTime } from '../ui.js';
import { cascadeMarkup, toggleLevel, SOURCE_ICONS } from './machine/cascade.js';
import { machinePill, openMachineAccountPanel, watchMachineAccount } from './machine/panel.js';

/** The screen has its own stylesheet (css/pages/machine.css), loaded by the router. */
export const stylesheet = true;

const ORBS = '<div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>';
const sk = (cls = '') => `<span class="skeleton mac-sk ${cls}"></span>`;

function errText(err, fallback = 'Erreur interne de l’interface.') {
  return err && err.code && err.message ? String(err.message) : fallback;
}

function skeleton() {
  return `<div class="page mac">
    <section class="hero mac-hero reveal" data-slot="hero"><span class="glow-ring hero-ring" aria-hidden="true"></span>${ORBS}
      <div class="mac-hero-grid"><div class="mac-hero-main"><div class="mac-sk-stack">${sk('w25')}${sk('mac-sk-title w45')}${sk('w85')}${sk('w70')}</div></div>
        <aside class="mac-inuse"><div class="mac-sk-stack">${sk('mac-sk-avatar')}${sk('w70')}${sk('w55')}</div></aside></div>
    </section>
    <div class="mac-sec reveal"><h2>Règle de choix</h2><span class="sec-note">Le premier compte disponible sert la prochaine opération</span></div>
    <div class="grid">
      <section class="card span-12 mac-rule reveal" data-slot="rule"><div class="mac-sk-stack">${sk('w40')}${sk('w100 mac-sk-row')}${sk('w100 mac-sk-row')}${sk('w100 mac-sk-row')}</div></section>
    </div>
    <div class="mac-sec reveal"><h2>Essai d’accès</h2><span class="sec-note">Choisir un poste, essayer, relire les essais de la session</span></div>
    <div class="grid">
      <section class="card span-12 mac-trial-card reveal" data-slot="trial"><div class="mac-sk-stack">${sk('w55')}${sk('w100 mac-sk-row')}</div></section>
      <section class="card span-12 mac-safe reveal" data-slot="safeguards"></section>
    </div>
  </div>`;
}

function heroMain(state) {
  const typed = state.typed;
  return `<div class="mac-hero-main">
    <div class="eyebrow">${glyph('chip')}<span>Opérations sur les postes</span></div>
    <h1 class="gradient-text">Comptes machine</h1>
    <p class="lead">Le compte que prendra la prochaine opération sur un poste (C$, consoles, inventaire, diagnostic, sessions), choisi par la même règle que les opérations. Un compte saisi ici reste en mémoire pour la session, jamais sur le disque.</p>
    <div class="chips">
      ${[
    `<span class="chip ${state.inUse.paused ? 'warn' : 'ok'}" data-generation="${esc(String(state.generation))}" data-tip="${esc(`Génération ${int(state.generation)}${NBSP}: chaque changement de compte en ouvre une nouvelle, et une opération lancée avec l’ancien compte s’arrête.`)}">${glyph(state.inUse.paused ? 'pause' : 'check')}${esc(state.inUse.paused ? 'En pause après un refus' : 'Compte prêt')}</span>`,
    typed ? `<span class="chip info" data-tip="${esc(`Saisi ${relTime(typed.since) ?? ''}`)}">${glyph('key')}Compte poste saisi</span>` : '<span class="chip">' + glyph('user') + 'Aucun compte poste saisi</span>',
    state.simulated ? `<span class="chip info" data-tip="${esc(state.credentialNote)}">${glyph('sparkles')}Simulation${NBSP}: aucun mot de passe</span>` : `<span class="chip" data-tip="${esc(state.credentialNote)}">${glyph('lock')}SecureString jusqu’à l’API Windows</span>`,
  ].map((c, n) => c.replace('class="chip', `data-j="${n}" class="chip`)).join('')}
    </div>
    <div class="hero-row">
      <button class="btn primary" type="button" data-act="panel">${glyph('key')}Saisir un compte poste…</button>
      ${typed ? `<button class="btn" type="button" data-act="forget">${glyph('undo')}Revenir au compte de connexion</button>` : ''}
      <button class="btn" type="button" data-act="trial-focus">${glyph('wifi')}Essayer sur un poste…</button>
    </div>
  </div>`;
}

function inUseCard(state) {
  const u = state.inUse;
  return `<aside class="mac-inuse ${u.paused ? 'paused' : ''}" aria-label="Compte en service">
    <div class="mac-avatar" aria-hidden="true"><span class="halo"></span><span class="mac-orbit"></span>${glyph(SOURCE_ICONS[u.source] ?? 'user')}</div>
    <span class="mac-k">Compte en service · niveau ${esc(String(u.rank))} sur 6</span>
    <div class="mac-pill-row">${machinePill(u, { size: 'lg' })}</div>
    <span class="mac-origin">${esc(u.source === 'windows' ? u.account : u.origin)}</span>
    ${u.paused ? `<p class="mac-pause">${glyph('pause')}<span>${esc(`En pause après un refus${NBSP}: ${u.pauseReason ?? ''}`)}</span></p>` : ''}
  </aside>`;
}

function targetCard(state, id) {
  const w = state.target;
  const named = state.targetName;
  const info = w
    ? `<div class="mac-ws">
        <span class="mac-ws-ico">${glyph('monitor')}</span>
        <div class="mac-ws-body"><b>${esc(w.name)}</b><span class="mono">${esc(w.dnsHostName ?? '—')}</span><span class="path">${esc(w.path)}</span></div>
        <button class="btn ghost icon sm" type="button" data-act="clear-target" aria-label="Retirer le poste" data-tip="Retirer le poste">${glyph('x')}</button>
      </div>
      <dl class="mac-ws-facts">
        <div><dt>Système</dt><dd>${esc(w.operatingSystem ?? '—')}</dd></div>
        <div><dt>Présence</dt><dd><span class="mac-dot ${esc(w.presence.tone)}" aria-hidden="true"></span>${esc(w.presence.label)}${w.presence.checkedAt ? ` <small>${esc(relTime(w.presence.checkedAt) ?? '')}</small>` : ''}</dd></div>
        <div><dt>Compte ordinateur</dt><dd>${w.enabled ? 'Activé' : '<span class="warn">Désactivé</span>'}</dd></div>
      </dl>`
    : named
      ? `<p class="mac-note warn">${glyph('alert')}<span>${esc(`${named} est introuvable dans l’annuaire${state.simulated ? ' fictif' : ''} : la règle s’applique sans compte local de poste.`)}</span></p>
        <div class="mac-near" data-near="${esc(named)}" hidden><span class="mac-near-k">Postes proches</span><div class="mac-near-list"></div></div>`
      : `<p class="mac-note">${glyph('info')}<span>Sans poste choisi, le niveau 1 (compte local accepté pour un poste) ne s’applique pas.</span></p>`;
  return `<div class="card-head"><span class="card-icon">${glyph('monitor')}</span><h3>Pour un poste précis</h3><span class="meta">Base locale, jamais le réseau</span></div>
    <div class="mac-search">
      ${glyph('search')}<input class="input mac-search-input" type="text" role="combobox" aria-expanded="false" aria-haspopup="listbox" placeholder="Nom du poste, par exemple PC-PAR" aria-label="Chercher un poste" aria-controls="${id}-list" aria-autocomplete="list" autocomplete="off" spellcheck="false" maxlength="64">
    </div>
    <ul class="mac-suggest" id="${id}-list" role="listbox" aria-label="Postes trouvés" hidden></ul>
    ${info}`;
}

function trialCard(state, id) {
  const target = state.target?.name ?? null;
  const trials = state.trials ?? [];
  return `<div class="mac-trial-grid">
    <div class="mac-target">${targetCard(state, id)}</div>
    <div class="mac-trial-main">
      <div class="card-head"><span class="card-icon">${glyph('wifi')}</span><h3>Essai d’accès</h3><span class="meta">${esc(target ? `Poste ${target}` : 'Aucun poste choisi')}</span></div>
      <p class="mac-trial-lead">Une seule lecture légère (système du poste, Win32_OperatingSystem) avec le compte en service${NBSP}: elle dit si l’accès administrateur est accepté, sans rien changer et sans balayer d’autres postes. Un refus met le compte en pause, un essai réussi le valide.</p>
      <div class="mac-trial-actions">
        <button class="btn primary" type="button" data-act="trial"${target ? '' : ' aria-disabled="true" data-tip="Choisissez d’abord un poste à gauche."'}>${glyph('play')}Essayer l’accès${target ? ` sur ${esc(target)}` : ''}<span class="mac-net" aria-hidden="true">${glyph('wifi')}</span></button>
        <span class="mac-trial-with">${glyph(SOURCE_ICONS[state.inUse.source] ?? 'user')}<span>${esc(state.inUse.long)}</span></span>
      </div>
      <div class="mac-trial-result" aria-live="polite"></div>
    </div>
    <div class="mac-history">
      <div class="card-head"><span class="card-icon">${glyph('history')}</span><h3>Essais de la session</h3>${trials.length ? `<span class="n">${esc(int(trials.length))}</span>` : ''}</div>
      ${trials.length ? `<ol class="mac-trials">${trials.map((t, j) => `<li class="${esc(t.tone)}" data-j="${j}">
          <span class="mark" aria-hidden="true">${glyph(t.success ? 'check' : t.verdict === 'unreachable' ? 'wifiOff' : 'alert')}</span>
          <div><b>${esc(t.computer)}</b> <span class="who">${esc(t.account)}${t.candidate ? ' · à valider' : ''}</span><p>${esc(t.text)}</p></div>
          <time datetime="${esc(t.at)}" data-tip="${esc(formatDateTime(t.at) ?? '')}">${esc(relTime(t.at) ?? '')}</time>
        </li>`).join('')}</ol>`
    : `<div class="mac-empty">${glyph('history')}<span>Aucun essai dans cette session${NBSP}: rien n’est essayé sans votre clic.</span></div>`}
    </div>
  </div>`;
}

function ruleCard(state) {
  const s = state.confidentialReads;
  return `<div class="mac-rule-grid">
    <div class="mac-rule-ops">
      <div class="card-head"><span class="card-icon">${glyph('layers')}</span><h3>Compte des opérations poste</h3>
        <span class="meta">${esc(state.targetName ? `Pour ${state.targetName}` : 'Tous postes')}</span></div>
      ${cascadeMarkup(state.levels, { label: 'Ordre de choix du compte des opérations poste' })}
    </div>
    <div class="mac-rule-secrets">
      <div class="card-head"><span class="card-icon">${glyph('shield')}</span><h3>Secrets (LAPS, BitLocker)</h3><span class="meta">${esc(s.account || s.origin)}</span></div>
      <p class="mac-trial-lead">La lecture d’un secret prend son propre compte, dans cet ordre. Domenia ne montre que des dates d’expiration, jamais un mot de passe ni une clé.</p>
      ${cascadeMarkup(s.levels, { label: 'Ordre de choix du compte des secrets', compact: true })}
    </div>
  </div>`;
}

function safeguardsCard(state) {
  return `<div class="card-head"><span class="card-icon">${glyph('lock')}</span><h3>Précautions</h3><span class="meta">Reprises de Domenia 1, appliquées par le moteur</span></div>
    <ul class="mac-safeguards">${state.safeguards.map((s, j) => `<li data-j="${j}">${glyph('check')}<span>${esc(s)}</span></li>`).join('')}</ul>`;
}

export function render(main, ctx) {
  main.innerHTML = skeleton();
  const page = main.querySelector('.page');
  const hero = page.querySelector('.mac-hero');
  const id = uid('mac');
  let alive = true;
  let state = null;
  let target = (ctx.params.poste ?? '').trim() || null;
  let panelOpen = false;
  let searchRequest = 0;
  let stopWatch = () => {};
  // Verdict of the last trial on this screen: kept when the cards are repainted (a change seen by the watch, the panel).
  let lastResult = '';
  const stops = [reveal(page), () => stopWatch()];

  function remember() {
    const params = target ? { poste: target } : {};
    try { history.replaceState(null, '', ctx.link('machine', params)); } catch (err) { console.error(err); }
  }

  function paint({ flash = false } = {}) {
    hero.querySelector('.mac-hero-grid')?.remove();
    hero.insertAdjacentHTML('beforeend', `<div class="mac-hero-grid">${heroMain(state)}${inUseCard(state)}</div>`);
    if (flash) hero.querySelector('.mac-inuse')?.classList.add('changed');
    page.querySelector('.mac-rule').innerHTML = ruleCard(state);
    page.querySelector('.mac-trial-card').innerHTML = trialCard(state, id);
    page.querySelector('.mac-trial-result').innerHTML = lastResult;
    page.querySelector('.mac-safe').innerHTML = safeguardsCard(state);
    const targetHost = page.querySelector('.mac-target');
    applyVars(page);
    bindSearch(targetHost);
    suggestNear(targetHost);
  }

  // A name of the address that matches no workstation: the workstations whose name starts the same way, to pick one.
  async function suggestNear(host) {
    const near = host.querySelector('[data-near]');
    if (!near) return;
    const name = near.getAttribute('data-near') ?? '';
    const stem = name.includes('-') ? name.slice(0, name.lastIndexOf('-')) : name.slice(0, Math.max(2, name.length - 2));
    try {
      const found = await ctx.call('machine.workstations.search', { text: stem });
      if (!alive || !found.length || !near.isConnected) return;
      near.querySelector('.mac-near-list').innerHTML = found.slice(0, 6).map((w, j) => `<button class="mac-near-item" type="button" data-j="${j}" data-pick="${esc(w.name)}"><span class="mac-dot ${esc(w.presence.tone)}" aria-hidden="true"></span>${esc(w.name)}</button>`).join('');
      applyVars(near);
      near.hidden = false;
    } catch (err) {
      console.error(err);
    }
  }

  /** Follows the account from the version shown: a change made elsewhere (another screen, the engine) reloads the state. */
  function watch() {
    stopWatch();
    stopWatch = watchMachineAccount({
      target,
      since: state?.version ?? null,
      onChange: (w, first) => { if (alive && !first && w.version !== state?.version) load({ flash: true }); },
    });
  }

  async function load({ flash = false } = {}) {
    try {
      state = await ctx.call('machine.account.state', { target });
      if (!alive) return;
      paint({ flash });
      watch();
    } catch (err) {
      if (!alive) return;
      hero.querySelector('.mac-hero-grid')?.remove();
      hero.insertAdjacentHTML('beforeend', `<div class="mac-hero-grid"><div class="mac-hero-main"><div class="eyebrow">${glyph('chip')}<span>Opérations sur les postes</span></div>
        <h1 class="gradient-text">Comptes machine</h1><p class="lead" role="alert">${esc(errText(err, 'État du compte poste illisible.'))}</p>
        <div class="hero-row"><button class="btn" type="button" data-act="retry">${glyph('refresh')}Réessayer</button></div></div></div>`);
    }
  }

  function openPanel() {
    if (!state || panelOpen) return;
    panelOpen = true;
    const panel = openMachineAccountPanel(ctx, {
      state, target,
      onChange: (next) => { if (!alive) return; state = next; paint({ flash: true }); },
    });
    panel.closed.then(() => { panelOpen = false; });
  }

  async function forget() {
    try {
      state = await ctx.call('machine.account.forget', { target });
      if (!alive) return;
      paint({ flash: true });
      toast(`Compte poste oublié. ${state.sentence}`, { tone: 'info' });
    } catch (err) {
      toast(errText(err, 'Oubli impossible.'), { tone: 'alert' });
    }
  }

  async function trial() {
    if (!state?.target) return;
    const host = page.querySelector('.mac-trial-result');
    const button = page.querySelector('[data-act="trial"]');
    button?.setAttribute('aria-busy', 'true');
    button?.setAttribute('aria-disabled', 'true');
    host.innerHTML = `<div class="mac-trial running"><span class="k-spin" aria-hidden="true"></span><span>${esc(`Essai en cours sur ${state.target.name} avec ${state.inUse.long}…`)}</span></div>`;
    try {
      const r = await ctx.call('machine.account.trial', { target });
      if (!alive) return;
      state = r.state;
      lastResult = `<div class="mac-trial ${esc(r.trial.tone)} big">${glyph(r.trial.success ? 'check' : 'alert')}<div><b>${esc(r.trial.text)}</b>${r.trial.simulated ? `<span>Essai simulé${NBSP}: aucun poste contacté, l’annuaire fictif répond.</span>` : ''}</div></div>`;
      paint();
      announce(r.trial.text);
    } catch (err) {
      if (!alive) return;
      host.innerHTML = `<div class="mac-trial alert">${glyph('alert')}<span>${esc(errText(err, 'Essai non lancé.'))}</span></div>`;
      button?.removeAttribute('aria-busy');
      button?.removeAttribute('aria-disabled');
    }
  }

  function chooseTarget(name) {
    target = name || null;
    lastResult = '';
    remember();
    load();
  }

  // ---------------------------------------------------------------- workstation search (local base, typed text only)
  function bindSearch(host) {
    const input = host.querySelector('.mac-search-input');
    const list = host.querySelector('.mac-suggest');
    if (!input || !list) return;
    let items = [];
    let active = -1;
    const close = () => { list.hidden = true; input.setAttribute('aria-expanded', 'false'); active = -1; input.removeAttribute('aria-activedescendant'); };
    const mark = () => {
      list.querySelectorAll('[role="option"]').forEach((li, n) => li.setAttribute('aria-selected', String(n === active)));
      if (active >= 0) input.setAttribute('aria-activedescendant', `${id}-o${active}`); else input.removeAttribute('aria-activedescendant');
    };
    const search = debounce(async (text) => {
      const my = ++searchRequest;
      if (!text.trim()) { close(); return; }
      try {
        items = await ctx.call('machine.workstations.search', { text });
        if (!alive || my !== searchRequest) return;
        list.innerHTML = items.length
          ? items.map((w, n) => `<li role="option" id="${id}-o${n}" data-name="${esc(w.name)}" data-j="${n}" aria-selected="false">
              <span class="mac-dot ${esc(w.presence.tone)}" aria-hidden="true"></span><b>${esc(w.name)}</b><span class="path">${esc(w.path)}</span></li>`).join('')
          : `<li class="none" role="option" aria-disabled="true">${esc(`Aucun poste ne contient ${text.trim()}.`)}</li>`;
        applyVars(list);
        list.hidden = false;
        input.setAttribute('aria-expanded', 'true');
        active = items.length ? 0 : -1;
        mark();
      } catch (err) {
        if (!alive) return;
        list.innerHTML = `<li class="none" role="option" aria-disabled="true">${esc(errText(err, 'Recherche impossible.'))}</li>`;
        list.hidden = false;
      }
    }, 220);
    input.addEventListener('input', () => search(input.value));
    input.addEventListener('keydown', (e) => {
      if (list.hidden) return;
      if (e.key === 'ArrowDown') { e.preventDefault(); active = Math.min(items.length - 1, active + 1); mark(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); active = Math.max(0, active - 1); mark(); }
      else if (e.key === 'Enter' && active >= 0 && items[active]) { e.preventDefault(); chooseTarget(items[active].name); }
      else if (e.key === 'Escape') { e.preventDefault(); close(); }
    });
    input.addEventListener('blur', () => setTimeout(close, 160));
    list.addEventListener('pointerdown', (e) => {
      const li = e.target instanceof Element ? e.target.closest('[data-name]') : null;
      if (li) { e.preventDefault(); chooseTarget(li.getAttribute('data-name')); }
    });
  }

  page.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    if (t.closest('[data-machine-pill]')) { openPanel(); return; }
    if (toggleLevel(t)) return;
    const pick = t.closest('[data-pick]');
    if (pick) { chooseTarget(pick.getAttribute('data-pick')); return; }
    const b = t.closest('[data-act]');
    if (!b || b.getAttribute('aria-disabled') === 'true') return;
    const act = b.getAttribute('data-act');
    if (act === 'panel') openPanel();
    else if (act === 'forget') forget();
    else if (act === 'trial') trial();
    else if (act === 'clear-target') chooseTarget(null);
    else if (act === 'retry') load();
    else if (act === 'trial-focus') {
      const input = page.querySelector('.mac-search-input');
      if (state?.target) page.querySelector('.mac-trial-card')?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      else { input?.scrollIntoView({ behavior: 'smooth', block: 'center' }); setTimeout(() => input?.focus(), 300); }
    }
  });

  (async () => {
    await load();
    if (!alive || !state) return;
    if (ctx.params.panneau === 'compte') openPanel();
    if (ctx.params.essai === '1' && state.target) {
      if (state.simulated) trial();
      else toast('Essai demandé par l’adresse : cliquez « Essayer l’accès » pour le lancer.', { tone: 'info' });
    }
  })();

  return () => {
    alive = false;
    stops.forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
  };
}

