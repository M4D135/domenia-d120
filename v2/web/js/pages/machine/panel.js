// « Compte poste » pill and side panel (MAC-002, MAC-003; Domenia 1 UX-15, SE-16, FO-19). Reusable by the Poste screen and
// by the « Se connecter » card of Intervenir:
//   import { mountMachineAccount } from './machine/panel.js';
//   const account = mountMachineAccount(headerSlot, ctx, { target: 'PC-PAR-0042', show: 'pill' });   // or 'sentence', 'both'
//   account.setTarget('PC-PAR-0043'); account.destroy();
// The mounted pill and sentence follow the engine (machine.account.watch, Domenia 1 Timer:Accounts) and are repainted only
// when their text changes. The panel lives in the page (kit drawer, never a window): identifier, password with a 5-second
// read-only reveal, « Utiliser ce compte » (Enter) in memory only, « Revenir au compte de connexion », « Valider sur ce
// poste » (one light read of one workstation), « Fermer ». Échap or a click beside close it without changing anything, and
// the password typed is cleared. The password leaves the page in one message to the engine, which turns it into a read-only
// SecureString at once (docs/ops/schema.md § 12); the field is emptied, no variable keeps it, no reply carries it back.
import { call } from '../../bridge.js';
import { openDrawer } from '../../kit/drawer.js';
import { glyph } from '../../kit/glyphs.js';
import { esc, uid, NBSP } from '../../kit/util.js';
import { applyVars, toast, announce } from '../../ui.js';
import { SOURCE_ICONS } from './cascade.js';

const PEEK_SECONDS = 5;
const STYLE_HREF = 'css/pages/machine.css';

function errText(err, fallback) {
  return err && err.code && err.message ? String(err.message) : fallback;
}

/**
 * The pill « Compte poste : … ▾ » (Pill of machine.account.state.inUse), with its origin in the tip; paused after a refusal:
 * warning tone and pause glyph.
 * @param {any} inUse  MachineAccountInUse
 * @param {{ size?: 'sm'|'md'|'lg' }} [o]
 */
export function machinePill(inUse, o = {}) {
  const icon = inUse.paused ? 'pause' : SOURCE_ICONS[inUse.source] ?? 'user';
  return `<button class="mac-pill${inUse.paused ? ' paused' : ''}${o.size === 'sm' || o.size === 'lg' ? ` ${o.size}` : ''}" type="button" data-machine-pill
    aria-label="${esc(`Compte poste${NBSP}: ${inUse.short}`)}" aria-haspopup="dialog" data-tip="${esc(inUse.tip)}">
    <span class="mac-pill-ico" aria-hidden="true">${glyph(icon)}</span><span class="mac-pill-text">${esc(inUse.pill.replace(/\s*▾$/, ''))}</span>${glyph('chevronDown', 'mac-pill-chev')}</button>`;
}

/** Loads the stylesheet of the panel when it opens from another screen (rules scoped to the panel root). */
function ensureStyles() {
  if (document.querySelector('.main')?.dataset.page === 'machine') return;
  if (document.querySelector(`link[data-machine-panel]`)) return;
  const link = document.createElement('link');
  link.rel = 'stylesheet';
  link.href = STYLE_HREF;
  link.dataset.machinePanel = '';
  document.head.appendChild(link);
}

function nowBox(state) {
  const u = state.inUse;
  return `<div class="mac-now${u.paused ? ' paused' : ''}">
    <span class="mac-now-ico" aria-hidden="true">${glyph(SOURCE_ICONS[u.source] ?? 'user')}</span>
    <div class="mac-now-body"><span class="k">En service · niveau ${esc(String(u.rank))} sur 6</span><b>${esc(state.sentence)}</b>
      ${u.paused ? `<span class="mac-now-pause">${glyph('pause')}${esc(`En pause après un refus${NBSP}: ${u.pauseReason ?? ''}`)}</span>` : ''}</div>
  </div>`;
}

/**
 * Opens the « Compte poste » panel.
 * @param {any} ctx  Page context (ctx.call).
 * @param {{ state: any, target?: string|null, onChange?: (state: any) => void }} o
 * @returns {{ close: () => void, closed: Promise<void> }}
 */
export function openMachineAccountPanel(ctx, o) {
  ensureStyles();
  let state = o.state;
  const target = o.target ?? state?.targetName ?? null;
  const id = uid('mac');
  const simulated = !!state.simulated;
  const body = document.createElement('div');
  body.className = 'mac-panel';
  body.dataset.page = 'machine';
  body.innerHTML = `
    <p class="mac-intro">Sert à C$, aux consoles, à l’inventaire, au diagnostic et aux sessions des postes. Il peut différer du compte de connexion et n’est jamais enregistré sur le disque.</p>
    <div class="mac-now-host" aria-live="polite">${nowBox(state)}</div>
    <div class="mac-fields">
      <label class="mac-label" for="${id}-a">Identifiant</label>
      <input id="${id}-a" class="input mono mac-account" data-policy="TxtMachineAdminUser" type="text" autocomplete="off" spellcheck="false" autocapitalize="off" maxlength="256"
        placeholder="DOMAINE\\nom ou POSTE\\nom" aria-describedby="${id}-ah ${id}-am">
      <p class="mac-hint" id="${id}-ah">Compte administrateur des postes${NBSP}: DOMAINE\\nom, POSTE\\nom, .\\nom ou nom@domaine. Vide, Domenia garde le compte en service affiché au-dessus.</p>
      <p class="mac-msg" id="${id}-am" role="status"></p>
      <label class="mac-label" for="${id}-p">Mot de passe</label>
      <div class="mac-secret">
        <input id="${id}-p" class="input mac-password" data-policy="PwdMachineAdmin" type="password" autocomplete="new-password" spellcheck="false" maxlength="256"
          ${simulated ? 'disabled placeholder="Aucun mot de passe en simulation"' : 'placeholder="Mot de passe du compte poste"'} aria-describedby="${id}-ph">
        <span class="mac-peek" aria-hidden="true"></span>
        <button class="btn icon mac-eye" type="button" data-policy="BtnRevealMachineAdmin" aria-pressed="false" aria-label="Afficher le mot de passe pendant 5 secondes"
          data-tip="Affiche le mot de passe pendant 5 secondes, en lecture seule. Rien n’est copié ni enregistré."${simulated ? ' disabled' : ''}>${glyph('eye')}</button>
      </div>
      <p class="mac-hint" id="${id}-ph">${esc(state.credentialNote)}</p>
    </div>
    <div class="mac-panel-actions">
      <button class="btn" type="button" data-mac="validate">${glyph('wifi')}<span>Valider sur ${esc(target ?? 'un poste')}</span></button>
      <button class="btn ghost" type="button" data-mac="forget" data-policy="BtnClearMachineCredential">${glyph('undo')}Revenir au compte de connexion</button>
    </div>
    <div class="mac-trial-host" aria-live="polite"></div>
    <details class="mac-rules"><summary>${glyph('shield')}Précautions</summary><ul>${state.safeguards.map((s) => `<li>${esc(s)}</li>`).join('')}</ul></details>`;

  const account = /** @type {HTMLInputElement} */ (body.querySelector('.mac-account'));
  const password = /** @type {HTMLInputElement} */ (body.querySelector('.mac-password'));
  if (!simulated) {
    password.disabled = true;
    body.querySelector('.mac-secret').hidden = true;
    body.querySelector(`label[for="${id}-p"]`).hidden = true;
    body.querySelector(`#${id}-ph`).textContent = 'Le mot de passe sera demandé dans une fenêtre native à chaque chargement ou essai explicite.';
  }
  const credentialArgs = (name) => simulated ? { account: name, password: null, target } : {
    account: name, target,
    theme: document.documentElement.dataset.theme === 'light' ? 'light' : document.documentElement.dataset.theme === 'contrast' ? 'contrast' : 'dark',
  };
  const peek = /** @type {HTMLElement} */ (body.querySelector('.mac-peek'));
  const eye = /** @type {HTMLButtonElement} */ (body.querySelector('.mac-eye'));
  const message = /** @type {HTMLElement} */ (body.querySelector('.mac-msg'));
  const trialHost = /** @type {HTMLElement} */ (body.querySelector('.mac-trial-host'));
  let peekTimer = 0;
  let busy = false;

  // SE-16: the typed secret shows for 5 s in a read-only layer over the field (no selection, no copy), then the layer is
  // emptied; typing, a second click or closing hides it at once. The field stays the only holder of the secret.
  function hidePeek() {
    clearTimeout(peekTimer);
    peekTimer = 0;
    peek.textContent = '';
    peek.classList.remove('on');
    eye.setAttribute('aria-pressed', 'false');
    eye.innerHTML = glyph('eye');
  }
  function showPeek() {
    if (peek.classList.contains('on')) { hidePeek(); return; }
    if (!password.value) return;
    peek.textContent = password.value;
    peek.classList.add('on');
    eye.setAttribute('aria-pressed', 'true');
    eye.innerHTML = glyph('eyeOff');
    peekTimer = setTimeout(hidePeek, PEEK_SECONDS * 1000);
  }

  function setMessage(text, tone = '') {
    message.textContent = text ?? '';
    message.className = `mac-msg ${tone}`;
    account.setAttribute('aria-invalid', tone === 'alert' ? 'true' : 'false');
  }

  function refresh(next) {
    state = next;
    const host = body.querySelector('.mac-now-host');
    host.innerHTML = nowBox(state);
    host.firstElementChild?.classList.add('changed');
    body.querySelector('[data-mac="forget"]').toggleAttribute('hidden', !state.typed);
    o.onChange?.(state);
  }

  function updateButtons() {
    const validate = body.querySelector('[data-mac="validate"]');
    if (!target) {
      validate.setAttribute('aria-disabled', 'true');
      validate.dataset.tip = 'Choisissez d’abord un poste dans « Essai d’accès » : la validation porte sur un seul poste.';
    } else {
      validate.removeAttribute('aria-disabled');
      validate.dataset.tip = `Une seule lecture légère du système de ${target}, avec ce compte, avant de l’utiliser.`;
    }
    body.querySelector('[data-mac="forget"]').toggleAttribute('hidden', !state.typed);
  }

  async function use() {
    if (busy) return;
    const name = account.value.trim();
    if (!name) { setMessage('Compte poste vide : rien n’a changé.', 'alert'); account.focus(); return; }
    busy = true;
    panel.setBusy(true);
    try {
      const next = await ctx.call('machine.account.use', credentialArgs(name));
      hidePeek();
      password.value = '';
      setMessage('Compte poste chargé en mémoire uniquement, jamais enregistré.', 'ok');
      refresh(next);
      toast('Compte poste chargé en mémoire uniquement, jamais enregistré.', { tone: 'ok' });
    } catch (err) {
      setMessage(errText(err, 'Compte poste non utilisé.'), err?.code === 'machine.cancelled' ? 'warn' : 'alert');
      (err?.code === 'machine.passwordMissing' ? password : account).focus();
    } finally {
      busy = false;
      panel.setBusy(false);
    }
  }

  async function forget() {
    if (busy) return;
    busy = true;
    panel.setBusy(true);
    try {
      const next = await ctx.call('machine.account.forget', { target });
      hidePeek();
      password.value = '';
      refresh(next);
      setMessage('', '');
      toast(`Compte poste oublié. ${next.sentence}`, { tone: 'info' });
    } catch (err) {
      toast(errText(err, 'Oubli impossible.'), { tone: 'alert' });
    } finally {
      busy = false;
      panel.setBusy(false);
    }
  }

  async function validate() {
    if (busy || !target) return;
    const name = account.value.trim();
    if (!name) { setMessage('Saisissez d’abord le compte à valider.', 'alert'); account.focus(); return; }
    busy = true;
    panel.setBusy(true);
    trialHost.innerHTML = `<div class="mac-trial running"><span class="k-spin" aria-hidden="true"></span><span>Essai en cours sur ${esc(target)} avec ${esc(name)}…</span></div>`;
    try {
      const r = await ctx.call('machine.account.trial', credentialArgs(name));
      trialHost.innerHTML = `<div class="mac-trial ${esc(r.trial.tone)}">${glyph(r.trial.success ? 'check' : 'alert')}<span>${esc(r.trial.text)}${r.trial.simulated ? ` <em>Essai simulé${NBSP}: aucun poste contacté, mot de passe non vérifié.</em>` : ''}</span></div>`;
      refresh(r.state);
      announce(r.trial.text);
    } catch (err) {
      trialHost.innerHTML = `<div class="mac-trial alert">${glyph('alert')}<span>${esc(errText(err, 'Essai non lancé.'))}</span></div>`;
    } finally {
      busy = false;
      panel.setBusy(false);
    }
  }

  body.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-mac]') : null;
    if (!b || b.getAttribute('aria-disabled') === 'true') return;
    const what = b.getAttribute('data-mac');
    if (what === 'forget') forget();
    else if (what === 'validate') validate();
  });
  eye.addEventListener('click', showPeek);
  password.addEventListener('input', hidePeek);
  account.addEventListener('input', () => { if (message.classList.contains('alert')) setMessage('', ''); });
  [account, password].forEach((field) => field.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); use(); }
  }));

  const panel = openDrawer({
    title: 'Compte poste',
    subtitle: target ? `Opérations sur les postes · ${target}` : 'Opérations sur les postes',
    icon: 'key',
    width: 480,
    key: 'machine.compte',
    body,
    focusFirst: true,
    actions: [
      { id: 'close', label: 'Fermer', run: (p) => p.close() },
      { id: 'use', label: 'Utiliser ce compte', icon: 'check', primary: true, run: () => use() },
    ],
    // Closing never changes the account in service: a password typed without « Utiliser ce compte » is dropped.
    onClose: () => { hidePeek(); password.value = ''; account.value = ''; },
  });
  updateButtons();
  applyVars(body);
  // Names of the Domenia 1 controls, for the central policy of the interface elements (PAR-044) when it exists.
  panel.foot?.querySelector('[data-id="use"]')?.setAttribute('data-policy', 'BtnSetMachineCredential');
  panel.foot?.querySelector('[data-id="close"]')?.setAttribute('data-policy', 'BtnMachineAccountClose');
  return panel;
}

const WATCH_RETRY_MS = 2000;
const WATCH_MAX_FAILURES = 3;

/**
 * Follows the account of the workstation operations (machine.account.watch: the engine answers when it changes, 25 s at
 * most, memory only). onChange receives { version, changed, inUse, sentence, generation }, the first time at once. The calls
 * go through the bridge without the busy counter of the screens: a watch never holds the « ready » signal of a capture.
 * Returns the function that stops it.
 * @param {{ target?: string|null, since?: number|null, onChange: (w: any, first: boolean) => void }} o
 */
export function watchMachineAccount(o) {
  let stopped = false;
  let version = Number.isInteger(o.since) ? o.since : null;
  (async () => {
    let failures = 0;
    while (!stopped) {
      try {
        const first = version === null;
        const w = await call('machine.account.watch', { since: version, target: o.target ?? null });
        if (stopped) return;
        failures = 0;
        version = w.version;
        if (first || w.changed) o.onChange(w, first);
      } catch (err) {
        if (stopped) return;
        failures += 1;
        if (failures >= WATCH_MAX_FAILURES) { console.error(err); return; }
        await new Promise((resolve) => { setTimeout(resolve, WATCH_RETRY_MS * failures); });
      }
    }
  })();
  return () => { stopped = true; };
}

/**
 * Mounts the pill « Compte poste : … ▾ » and/or the sentence « Opérations poste : … » in host (header of the Poste screen,
 * « Se connecter » card of Intervenir), kept up to date and repainted only when its text changes. A click on the pill opens
 * the « Compte poste » panel for the same workstation. Names only, never a password.
 * @param {HTMLElement} host
 * @param {any} ctx  Page context (ctx.call).
 * @param {{ target?: string|null, show?: 'pill'|'sentence'|'both', size?: 'sm'|'md'|'lg' }} [o]
 * @returns {{ setTarget: (target: string|null) => void, destroy: () => void }}
 */
export function mountMachineAccount(host, ctx, o = {}) {
  ensureStyles();
  const show = o.show ?? 'pill';
  let target = o.target ?? null;
  let painted = '';
  let stop = () => {};
  let panelOpen = false;
  const root = document.createElement('span');
  root.className = `mac-mount ${show}`;
  root.dataset.page = 'machine';
  host.appendChild(root);

  function paint(w) {
    const key = JSON.stringify([w.inUse.pill, w.inUse.tip, w.inUse.paused, w.sentence]);
    if (key === painted) return;
    painted = key;
    root.innerHTML = (show !== 'sentence' ? machinePill(w.inUse, { size: o.size }) : '')
      + (show !== 'pill' ? `<span class="mac-mount-sentence${w.inUse.paused ? ' paused' : ''}">${w.inUse.paused ? glyph('pause') : ''}${esc(w.sentence)}</span>` : '');
    root.classList.remove('changed'); void root.offsetWidth; root.classList.add('changed');
  }

  function start() {
    stop();
    painted = '';
    stop = watchMachineAccount({ target, onChange: (w) => paint(w) });
  }

  root.addEventListener('click', async (e) => {
    if (!(e.target instanceof Element) || !e.target.closest('[data-machine-pill]') || panelOpen) return;
    panelOpen = true;
    try {
      const state = await ctx.call('machine.account.state', { target });
      openMachineAccountPanel(ctx, { state, target }).closed.then(() => { panelOpen = false; });
    } catch (err) {
      panelOpen = false;
      toast(errText(err, 'État du compte poste illisible.'), { tone: 'alert' });
    }
  });
  start();

  return {
    setTarget(next) { target = next ?? null; start(); },
    destroy() { stop(); root.remove(); },
  };
}
