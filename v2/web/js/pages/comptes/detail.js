// Comptes screen: detail pane of one account (accounts.detail) with its support band (FIC-048), its actions (unlock, reset
// the password, enable or disable, forced change, expiration: every write through runWrite, docs/WRITES.md) and its tabs:
// overview, password (reset form with live policy checks, the password never leaves the page before « Préparer »),
// lockouts (read on an explicit gesture), expiration and identity.
import {
  glyph, pill, createTabs, createCommandBar, kvSection, bindKv, copyButton, bindCopy, setVars, NBSP,
} from '../../kit/index.js';
import { esc, announce, copyText, formatNumber, motionReduced } from '../../ui.js';
import { runWrite } from '../../write-flow.js';
import {
  avatar, paintAvatars, statusPill, relSpan, when, dayText, isoDay, daysTo, plural, emptyState, skeletonLines,
  errorSentence, LOCK_LABELS, LOCK_TONES, PASSWORD_LABELS, PASSWORD_TONES,
} from './shared.js';
import { lockoutIntro, bindLockouts } from './lockouts.js';

const TABS = ['apercu', 'mdp', 'verrouillages', 'expiration', 'identite'];
const ACTION_TABS = { mdp: 'mdp', verrouillages: 'verrouillages', expiration: 'expiration', identite: 'identite' };
// Characters of a generated password: no look-alikes (O 0, I l 1), every class present.
const SETS = ['ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#$%&*+-=?@_'];

/** Live checks of a typed password, the same rules as the engine (AccountPasswordReset.CheckPolicy). */
export function passwordChecks(value, confirm, { sam, name, minLength }) {
  const v = String(value ?? '');
  const classes = [/[A-ZÀ-ÖØ-Þ]/u.test(v), /[a-zß-öø-ÿ]/u.test(v), /\d/.test(v), /[^\p{L}\p{N}]/u.test(v)].filter(Boolean).length;
  const lower = v.toLocaleLowerCase('fr');
  const tokens = String(name ?? '').split(/[,.\-_\s#'’\t]+/).filter((t) => t.length >= 3).map((t) => t.toLocaleLowerCase('fr'));
  const hasName = (sam && sam.length >= 3 && lower.includes(sam.toLocaleLowerCase('fr'))) || tokens.some((t) => lower.includes(t));
  return [
    { id: 'length', label: `${formatNumber(minLength)}${NBSP}caractères au moins`, met: v.length >= minLength && v.length <= 256 },
    { id: 'classes', label: 'Trois types parmi majuscules, minuscules, chiffres et symboles', met: classes >= 3 },
    { id: 'name', label: 'Ni le nom du compte ni une partie du nom affiché', met: v.length > 0 && !hasName },
    { id: 'match', label: 'Confirmation identique', met: v.length > 0 && v === confirm },
  ];
}

/** A random password of 16 characters with the four classes (crypto.getRandomValues, never sent before « Préparer »). */
export function generatePassword(length = 16) {
  const all = SETS.join('');
  const pick = (set) => {
    const max = 256 - (256 % set.length);
    const buf = new Uint8Array(1);
    for (;;) {
      crypto.getRandomValues(buf);
      if (buf[0] < max) return set[buf[0] % set.length];
    }
  };
  const chars = SETS.map(pick);
  while (chars.length < length) chars.push(pick(all));
  for (let i = chars.length - 1; i > 0; i--) {
    const buf = new Uint32Array(1);
    crypto.getRandomValues(buf);
    const j = buf[0] % (i + 1);
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }
  return chars.join('');
}

/**
 * Creates the detail pane in host.
 * @param {HTMLElement} host
 * @param {{ call: Function, navigate: Function, toast: Function }} ctx
 * @param {{ onChanged: (dn: string) => void, onPick?: (dn: string) => void, simulated?: () => boolean }} o
 */
export function createDetail(host, ctx, o) {
  let current = null;
  let detail = null;
  let token = 0;
  let tabs = null;
  let bar = null;
  let lockouts = null;
  let pendingAction = null;
  const cleanups = [];

  const placeholder = () => {
    host.innerHTML = `<div class="cpt-detail cpt-detail-empty">${emptyState({
      iconName: 'user', title: 'Choisissez un compte',
      text: 'Son état calculé par le contrôleur, son mot de passe, ses verrouillages et les actions possibles s’affichent ici. Rien n’est modifié sans plan ni confirmation.',
    })}<ul class="cpt-hints"><li>${glyph('search')}<span>Filtrez la liste ou cliquez une tuile pour cibler les comptes à traiter.</span></li>
      <li>${glyph('lock')}<span>Un compte verrouillé propose le déverrouillage et la lecture de ses verrouillages.</span></li>
      <li>${glyph('layers')}<span>Sélectionnez plusieurs comptes pour une action par lot, avec aperçu exact.</span></li></ul></div>`;
  };

  function teardown() {
    lockouts?.stop();
    lockouts = null;
    tabs?.destroy();
    tabs = null;
    bar?.destroy();
    bar = null;
    cleanups.splice(0).forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
  }

  async function show(row, { action = null } = {}) {
    if (!row) { current = null; detail = null; teardown(); placeholder(); return; }
    const same = current?.dn === row.dn;
    current = row;
    pendingAction = action;
    const my = ++token;
    if (!same) {
      teardown();
      host.innerHTML = `<div class="cpt-detail" aria-busy="true">
        <div class="cpt-d-head">${avatar(row.name, row.guid, 'xl')}<div class="cpt-d-titles"><h2>${esc(row.name)}</h2><p class="mono">${esc(row.sam)}</p></div></div>
        ${skeletonLines(6)}</div>`;
      paintAvatars(host);
    } else {
      host.querySelector('.cpt-detail')?.setAttribute('aria-busy', 'true');
    }
    try {
      const d = await ctx.call('accounts.detail', { dn: row.dn });
      if (my !== token) return;
      detail = d;
      render(d, same);
    } catch (err) {
      console.error(err);
      if (my !== token) return;
      teardown();
      host.innerHTML = `<div class="cpt-detail">${emptyState({ iconName: 'alert', title: 'Détail indisponible', text: errorSentence(err, 'Le compte n’a pas pu être lu.'), tone: 'alert' })}</div>`;
    }
  }

  function reload() {
    if (current) show(current);
  }

  function bandMarkup(d) {
    const b = d.band;
    if (!b) {
      return `<div class="cpt-band ok" role="status"><span class="cpt-band-ico">${glyph('check')}</span><div class="cpt-band-text"><b>Rien à signaler</b>
        <span>Selon ${esc(d.controller ?? 'le contrôleur')} : ni verrouillage, ni mot de passe expiré, ni essai erroné récent.</span></div></div>`;
    }
    const actions = b.actions.map((a) => {
      if (a === 'unlock') return `<button class="btn sm danger" type="button" data-act="unlock">${glyph('edit')}Déverrouiller maintenant…</button>`;
      if (a === 'lockouts') return `<button class="btn sm" type="button" data-act="lockouts">${glyph('lock')}Lire les verrouillages (4740)</button>`;
      if (a === 'reset') return `<button class="btn sm" type="button" data-act="reset">${glyph('key')}Réinitialiser le mot de passe…</button>`;
      return '';
    }).join('');
    const facts = b.facts.map((f) => `<li data-tone="${esc(f.tone)}" ${f.limit ? `data-tip="${esc(f.limit)}" tabindex="0"` : ''}><span>${esc(f.label)}</span><b>${esc(f.value)}</b>${f.limit ? `<span class="visually-hidden"> · ${esc(f.limit)}</span>` : ''}</li>`).join('');
    return `<div class="cpt-band ${esc(b.tone)}" role="status">
      <span class="cpt-band-ico">${glyph(b.tone === 'alert' ? 'lock' : b.tone === 'off' ? 'power' : b.tone === 'warn' ? 'alert' : 'info')}</span>
      <div class="cpt-band-text"><b>${esc(b.title)}</b><span>${esc(b.detail)}</span>
        ${facts ? `<ul class="cpt-band-facts">${facts}</ul>` : ''}
        ${actions ? `<div class="cpt-band-actions">${actions}</div>` : ''}</div></div>`;
  }

  function headMarkup(d) {
    const a = d.account;
    const sub = [a.title, a.department, a.office].filter(Boolean).join(' · ');
    const pills = [
      statusPill(a, 'md'),
      a.enabled ? '' : pill('off', 'Désactivé', { icon: 'power', size: 'sm' }),
      a.privileged ? pill('warn', 'À privilèges', { icon: 'shield', size: 'sm', tip: 'adminCount = 1 : toute écriture demande la saisie du nom' }) : '',
      d.simulated ? pill('accent', 'Annuaire fictif', { icon: 'sparkles', size: 'sm' }) : '',
    ].filter(Boolean).join('');
    return `<header class="cpt-d-head">
      ${avatar(a.name, a.guid, 'xl')}
      <div class="cpt-d-titles"><h2>${esc(a.name)}</h2>
        <p class="cpt-d-sam"><span class="mono">${esc(a.sam)}</span>${copyButton(a.sam, { label: 'Copier le compte', done: 'Copié' })}${a.upn ? `<span class="cpt-d-upn">${esc(a.upn)}</span>` : ''}</p>
        ${sub ? `<p class="cpt-d-sub">${esc(sub)}</p>` : ''}</div>
      <div class="cpt-d-pills">${pills}</div>
    </header>`;
  }

  function render(d, keepTab) {
    const previousTab = keepTab ? tabs?.current() : null;
    teardown();
    host.innerHTML = `<div class="cpt-detail" data-tone="${esc(d.account.tone)}">
      ${headMarkup(d)}
      ${bandMarkup(d)}
      <div class="cpt-d-actions"></div>
      <div class="cpt-d-tabs"></div>
    </div>`;
    paintAvatars(host);
    cleanups.push(bindCopy(host));
    bindBand();
    commands(d);
    const wanted = ACTION_TABS[pendingAction] ?? previousTab ?? 'apercu';
    tabs = createTabs(host.querySelector('.cpt-d-tabs'), {
      label: 'Détail du compte',
      key: 'comptes.detail.tab',
      selected: wanted,
      tabs: [
        { id: 'apercu', label: 'Aperçu', icon: 'eye', render: (p) => overview(p, d) },
        { id: 'mdp', label: 'Mot de passe', icon: 'key', tone: PASSWORD_TONES[d.passwordInfo.class], render: (p) => password(p, d) },
        { id: 'verrouillages', label: 'Verrouillages', icon: 'lock', count: d.account.lock === 'unlocked' ? null : 1, tone: LOCK_TONES[d.account.lock], render: (p) => lockoutTab(p, d) },
        { id: 'expiration', label: 'Expiration', icon: 'calendar', render: (p) => expiration(p, d) },
        { id: 'identite', label: 'Identité', icon: 'user', render: (p) => identity(p, d) },
      ],
    });
    if (wanted && TABS.includes(wanted)) tabs.select(wanted);
    if (ACTION_TABS[pendingAction]) requestAnimationFrame(() => reveal(host.querySelector('.cpt-d-tabs')));
    if (pendingAction === 'mdp') host.querySelector('.cpt-pwd input')?.focus({ preventScroll: true });
    if (pendingAction === 'verrouillages' && o.autoRead?.()) lockouts?.read();
    pendingAction = null;
    host.querySelector('.cpt-detail')?.removeAttribute('aria-busy');
  }

  function bindBand() {
    host.querySelector('.cpt-band')?.addEventListener('click', (e) => {
      const b = e.target.closest('[data-act]');
      if (!b) return;
      if (b.dataset.act === 'unlock') write('unlock');
      if (b.dataset.act === 'lockouts') { openTab('verrouillages'); lockouts?.read(); }
      if (b.dataset.act === 'reset') openPasswordTab();
    });
  }

  /** Scrolls the detail pane (the host scrolls, never the page) so that el sits near its top. */
  function reveal(el, offset = 10) {
    if (!el || !host.isConnected) return;
    const delta = el.getBoundingClientRect().top - host.getBoundingClientRect().top - offset;
    host.scrollTo({ top: Math.max(0, host.scrollTop + delta), behavior: motionReduced() ? 'auto' : 'smooth' });
  }

  function openTab(id) {
    tabs?.select(id);
    reveal(host.querySelector('.cpt-d-tabs'));
  }

  function openPasswordTab() {
    openTab('mdp');
    host.querySelector('.cpt-pwd input')?.focus({ preventScroll: true });
  }

  function commands(d) {
    const a = d.actions;
    const acc = d.account;
    const lockedish = acc.lock !== 'unlocked';
    // The support band already offers « Déverrouiller maintenant » first: the bar then leads with the password.
    const inBand = new Set(d.band?.actions ?? []);
    const unlockFirst = lockedish && !inBand.has('unlock');
    const items = [];
    if (lockedish) items.push({ id: 'unlock', label: 'Déverrouiller…', icon: 'lock', kind: 'write', danger: true, primary: unlockFirst, overflow: !unlockFirst, disabled: !a.unlock.available, reason: a.unlock.reason, run: () => write('unlock') });
    items.push({ id: 'reset', label: 'Réinitialiser le mot de passe…', icon: 'key', kind: 'write', primary: !unlockFirst, disabled: !a.resetPassword.available, reason: a.resetPassword.reason, run: openPasswordTab });
    items.push(acc.enabled
      ? { id: 'disable', label: 'Désactiver…', icon: 'power', kind: 'write', danger: true, disabled: !a.disable.available, reason: a.disable.reason, run: () => write('disable') }
      : { id: 'enable', label: 'Activer…', icon: 'power', kind: 'write', disabled: !a.enable.available, reason: a.enable.reason, run: () => write('enable') });
    items.push({ id: 'mustChange', label: 'Imposer un nouveau mot de passe…', icon: 'refresh', kind: 'write', overflow: true, disabled: !a.mustChange.available, reason: a.mustChange.reason, run: () => write('mustChange') });
    items.push({ id: 'expiration', label: 'Expiration du compte…', icon: 'calendar', kind: 'write', overflow: true, disabled: !a.expiration.available, reason: a.expiration.reason, run: () => openTab('expiration') });
    items.push({ id: 'lockouts', label: 'Lire les verrouillages', icon: 'wifi', kind: 'network', overflow: true, disabled: !a.lockouts.available, reason: a.lockouts.reason, run: () => { openTab('verrouillages'); lockouts?.read(); } });
    items.push({ id: 'fiche', label: 'Ouvrir la fiche', icon: 'object', overflow: true, run: () => ctx.navigate('fiche', { dn: acc.dn }) });
    items.push({ id: 'copyDn', label: 'Copier le DN', icon: 'copy', overflow: true, run: async () => { if (await copyText(acc.dn)) ctx.toast('DN copié.', { tone: 'ok', life: 2200 }); } });
    bar = createCommandBar(host.querySelector('.cpt-d-actions'), { label: 'Actions du compte', items, size: 'sm' });
  }

  /** Runs one write of the circuit; the screen reads the account again once the receipt is in. */
  function write(kind, extra = {}) {
    if (!detail) return null;
    const acc = detail.account;
    const plans = {
      unlock: 'accounts.unlock.plan', enable: 'accounts.enable.plan', disable: 'accounts.disable.plan',
      mustChange: 'accounts.mustChange.plan', expiration: 'accounts.expiration.plan', password: 'accounts.password.plan',
    };
    const args = { dn: acc.dn, ...extra };
    const flow = runWrite(ctx, { plan: plans[kind], args, subtitle: `Compte utilisateur · ${acc.name}`, onDone: () => o.onChanged(acc.dn) });
    return flow;
  }

  // ---------------------------------------------------------------- tabs

  function overview(panel, d) {
    const s = d.state;
    const p = d.passwordInfo;
    const lockSub = s.lockedAt ? `${s.lock === 'locked' ? 'Depuis' : 'Le'} ${when(s.lockedAt)}${s.lockEndsAt ? ` · fin prévue vers ${when(s.lockEndsAt)}` : ''}` : '';
    const options = [
      s.passwordNeverExpires ? 'Mot de passe sans expiration' : '',
      s.smartCardRequired ? 'Carte à puce exigée' : '',
      s.passwordNotRequired ? 'Mot de passe non requis' : '',
    ].filter(Boolean);
    const expiresIn = daysTo(p.expiresAt);
    const meter = p.percent != null ? `<div class="cpt-pmeter" data-tone="${esc(p.tone)}" role="meter" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${p.percent}" aria-label="Durée de validité du mot de passe déjà écoulée">
        <span class="cpt-pmeter-fill" data-p="${p.percent / 100}"></span></div>` : '';
    panel.innerHTML = `<div class="cpt-d-pane">
      <div class="cpt-tiles">
        <div class="cpt-tile" data-tone="${esc(LOCK_TONES[s.lock])}"><span class="cpt-tile-k">${glyph('lock')}Verrouillage</span><b>${esc(LOCK_LABELS[s.lock])}</b><span>${esc(lockSub || (s.badPasswordCount ? plural(s.badPasswordCount, 'essai erroné', 'essais erronés') : 'Aucun essai erroné'))}</span></div>
        <div class="cpt-tile" data-tone="${esc(p.tone)}"><span class="cpt-tile-k">${glyph('key')}Mot de passe</span><b>${esc(PASSWORD_LABELS[p.class])}</b><span>${p.expiresAt ? esc(`${expiresIn < 0 ? 'Expiré le' : 'Expire le'} ${dayText(p.expiresAt)}${p.estimated ? ' (estimé)' : ''}`) : esc(p.class === 'mustChange' ? 'Demandé à la prochaine connexion' : 'Aucune date d’expiration')}</span>${meter}</div>
        <div class="cpt-tile" data-tone="${s.accountExpired ? 'alert' : s.accountExpiresAt ? 'warn' : 'ok'}"><span class="cpt-tile-k">${glyph('calendar')}Compte</span><b>${esc(s.disabled ? 'Désactivé' : s.accountExpired ? 'Expiré' : 'Activé')}</b><span>${esc(s.accountExpiresAt ? `Expiration le ${dayText(s.accountExpiresAt)}` : 'Aucune expiration')}</span></div>
        <div class="cpt-tile" data-tone="${s.lastLogon ? 'info' : 'off'}"><span class="cpt-tile-k">${glyph('activity')}Dernière connexion</span><b>${relSpan(s.lastLogon, { none: 'Jamais enregistrée' })}</b><span>À 14 jours près (lastLogonTimestamp)</span></div>
      </div>
      <div class="cpt-kv">${kvSection({ id: 'etat', title: 'État calculé par le contrôleur', icon: 'shield', items: [
        { label: 'Essais erronés', value: s.badPasswordCount == null ? null : formatNumber(s.badPasswordCount), sub: `Compteur propre à ${d.controller ?? 'ce contrôleur'}, non répliqué`, tone: s.badPasswordCount ? 'warn' : undefined },
        { label: 'Seuil de verrouillage', value: d.policy.lockoutThreshold ? plural(d.policy.lockoutThreshold, 'essai', 'essais') : 'Aucun', sub: d.policy.lockoutMinutes ? `Verrouillage de ${formatNumber(d.policy.lockoutMinutes)}${NBSP}min` : '' },
        { label: 'Options du compte', value: options.length ? options.join(' · ') : 'Aucune option particulière' },
        { label: 'Groupes', value: plural(d.groups.count, 'groupe', 'groupes'), sub: d.groups.privileged.length ? `À privilèges : ${d.groups.privileged.join(', ')}` : 'Aucun groupe à privilèges', tone: d.groups.privileged.length ? 'warn' : undefined },
        { label: 'Lu', value: when(d.readAt), sub: d.controller ? `Contrôleur ${d.controller}` : '' },
      ] })}</div>
    </div>`;
    panel.querySelectorAll('[data-p]').forEach((el) => setVars(el, { '--p': el.dataset.p }));
    const sheet = bindKv(panel, { key: 'comptes.detail' });
    cleanups.push(() => sheet.destroy());
  }

  function password(panel, d) {
    const p = d.passwordInfo;
    const acc = d.account;
    const locked = acc.lock !== 'unlocked';
    panel.innerHTML = `<div class="cpt-d-pane">
      <div class="cpt-pwd-summary" data-tone="${esc(p.tone)}">
        <div class="cpt-pwd-ring" aria-hidden="true"><svg viewBox="0 0 120 120"><circle class="track" cx="60" cy="60" r="50"/><circle class="arc" cx="60" cy="60" r="50" pathLength="100"/></svg>
          <span>${p.percent != null ? `${formatNumber(Math.round(p.percent))}${NBSP}%` : '—'}</span></div>
        <div class="cpt-pwd-facts">
          <b>${esc(PASSWORD_LABELS[p.class])}</b>
          <span>${p.lastSet ? `Changé le ${esc(dayText(p.lastSet))}${p.ageDays != null ? ` (il y a ${esc(plural(p.ageDays, 'jour', 'jours'))})` : ''}` : 'Jamais changé ou à changer'}</span>
          <span>${p.expiresAt ? `${daysTo(p.expiresAt) < 0 ? 'Expiré le' : 'Expire le'} ${esc(dayText(p.expiresAt))}${p.estimated ? ' · date estimée par la stratégie' : ' · date calculée par le contrôleur'}` : 'Aucune expiration'}</span>
          <span class="cpt-muted">Stratégie : ${esc(d.policy.label)}</span>
        </div>
      </div>
      <form class="cpt-pwd" novalidate autocomplete="off">
        <h3>${glyph('key')}Réinitialiser le mot de passe</h3>
        <div class="cpt-pwd-grid">
          <div class="k-field"><label for="cpt-pwd-new">Nouveau mot de passe</label>
            <div class="cpt-pwd-input"><input class="input mono" id="cpt-pwd-new" type="password" autocomplete="new-password" spellcheck="false" maxlength="256" data-pwd="new">
              <button class="btn ghost icon sm" type="button" data-reveal="new" aria-label="Afficher le mot de passe" aria-pressed="false" data-tip="Afficher">${glyph('eye')}</button></div></div>
          <div class="k-field"><label for="cpt-pwd-confirm">Confirmation</label>
            <div class="cpt-pwd-input"><input class="input mono" id="cpt-pwd-confirm" type="password" autocomplete="new-password" spellcheck="false" maxlength="256" data-pwd="confirm">
              <button class="btn ghost icon sm" type="button" data-reveal="confirm" aria-label="Afficher la confirmation" aria-pressed="false" data-tip="Afficher">${glyph('eye')}</button></div></div>
        </div>
        <div class="cpt-pwd-tools">
          <button class="btn sm" type="button" data-generate>${glyph('sparkles')}Générer un mot de passe</button>
          <span class="cpt-pwd-strength" aria-hidden="true"><i></i><i></i><i></i><i></i></span>
          <span class="cpt-pwd-strength-text" aria-live="polite"></span>
        </div>
        <ul class="cpt-pwd-rules" aria-label="Règles du mot de passe"></ul>
        <div class="cpt-pwd-options">
          <label class="k-check-row"><input class="k-checkbox" type="checkbox" data-must checked><span>Changement obligatoire à la prochaine connexion</span></label>
          <label class="k-check-row${locked ? '' : ' off'}"><input class="k-checkbox" type="checkbox" data-unlock ${locked ? 'checked' : 'disabled'}><span>Déverrouiller ensuite${locked ? '' : ' (compte non verrouillé)'}</span></label>
        </div>
        <p class="cpt-pwd-note">${glyph('shield')}Le mot de passe ne quitte la page qu’à « Préparer » : il est alors gardé en mémoire protégée pour ce seul plan, jamais dans le plan, le reçu ni le journal. Le contrôleur vérifie aussi l’historique (${formatNumber(d.policy.passwordHistory)}).</p>
        <div class="cpt-pwd-foot">
          <button class="btn danger" type="submit" ${d.actions.resetPassword.available ? '' : `disabled data-tip="${esc(d.actions.resetPassword.reason ?? '')}"`}>${glyph('edit')}Préparer la réinitialisation…</button>
          <button class="btn subtle" type="button" data-must-only ${d.actions.mustChange.available ? '' : `disabled data-tip="${esc(d.actions.mustChange.reason ?? '')}"`}>${glyph('refresh')}Imposer un nouveau mot de passe…</button>
        </div>
      </form>
    </div>`;
    const ring = panel.querySelector('.cpt-pwd-ring .arc');
    if (ring) setVars(ring, { '--p': String((p.percent ?? 0) / 100) });
    const form = panel.querySelector('.cpt-pwd');
    const inputNew = panel.querySelector('[data-pwd="new"]');
    const inputConfirm = panel.querySelector('[data-pwd="confirm"]');
    const rules = panel.querySelector('.cpt-pwd-rules');
    const strength = panel.querySelector('.cpt-pwd-strength');
    const strengthText = panel.querySelector('.cpt-pwd-strength-text');
    const policy = { sam: acc.sam, name: acc.name, minLength: d.policy.minPasswordLength || 12 };
    const update = () => {
      const checks = passwordChecks(inputNew.value, inputConfirm.value, policy);
      rules.innerHTML = checks.map((c) => `<li class="${c.met ? 'met' : ''}">${glyph(c.met ? 'check' : 'dot')}<span>${esc(c.label)}</span><span class="visually-hidden">${c.met ? ' : respectée' : ' : non respectée'}</span></li>`).join('');
      const score = inputNew.value ? checks.slice(0, 3).filter((c) => c.met).length + (inputNew.value.length >= 16 ? 1 : 0) : 0;
      strength.dataset.score = String(score);
      strengthText.textContent = !inputNew.value ? '' : ['Très faible', 'Faible', 'Moyen', 'Bon', 'Robuste'][score];
      return checks;
    };
    update();
    form.addEventListener('input', update);
    panel.querySelectorAll('[data-reveal]').forEach((b) => b.addEventListener('click', () => {
      const input = panel.querySelector(`[data-pwd="${b.dataset.reveal}"]`);
      const shown = input.type === 'text';
      input.type = shown ? 'password' : 'text';
      b.setAttribute('aria-pressed', String(!shown));
      b.innerHTML = glyph(shown ? 'eye' : 'eyeOff');
      b.dataset.tip = shown ? 'Afficher' : 'Masquer';
    }));
    panel.querySelector('[data-generate]').addEventListener('click', () => {
      const value = generatePassword(16);
      inputNew.value = value;
      inputConfirm.value = value;
      inputNew.type = 'text';
      inputConfirm.type = 'text';
      panel.querySelectorAll('[data-reveal]').forEach((b) => { b.setAttribute('aria-pressed', 'true'); b.innerHTML = glyph('eyeOff'); b.dataset.tip = 'Masquer'; });
      update();
      announce('Mot de passe généré et affiché : transmettez-le par un canal sûr.');
    });
    panel.querySelector('[data-must-only]').addEventListener('click', () => write('mustChange'));
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const checks = update();
      const missing = checks.filter((c) => !c.met);
      if (missing.length) {
        ctx.toast(`Mot de passe à revoir : ${missing.map((c) => c.label.toLocaleLowerCase('fr')).join(' ; ')}.`, { tone: 'warn', life: 6000 });
        (missing[0].id === 'match' ? inputConfirm : inputNew).focus();
        return;
      }
      const args = {
        password: inputNew.value,
        mustChange: panel.querySelector('[data-must]').checked,
        unlock: panel.querySelector('[data-unlock]').checked,
      };
      const receipt = await write('password', args);
      args.password = '';
      if (receipt) {
        if (inputNew.isConnected) { inputNew.value = ''; inputConfirm.value = ''; update(); }
      }
    });
  }

  function lockoutTab(panel, d) {
    panel.innerHTML = `<div class="cpt-d-pane cpt-lk">${lockoutIntro(d.account, 168)}<div class="cpt-lk-out"></div></div>`;
    if (!d.actions.lockouts.available) {
      panel.querySelector('.cpt-lk-out').innerHTML = `<p class="cpt-inline-error">${glyph('info')}${esc(d.actions.lockouts.reason ?? '')}</p>`;
      panel.querySelector('[data-lk-read]').disabled = true;
      return;
    }
    lockouts = bindLockouts(panel, ctx, d.account, { onRead: () => requestAnimationFrame(() => reveal(panel.querySelector('.cpt-lk-report'), 12)) });
  }

  function expiration(panel, d) {
    const s = d.state;
    const now = new Date();
    const plus = (days) => { const x = new Date(now); x.setDate(x.getDate() + days); return isoDay(x); };
    const yearEnd = isoDay(new Date(now.getFullYear(), 11, 31));
    const current = s.accountExpiresAt ? `Expire le ${dayText(s.accountExpiresAt)}${s.accountExpired ? ' : compte expiré' : ''}` : 'Aucune expiration';
    panel.innerHTML = `<div class="cpt-d-pane">
      <div class="cpt-exp-now" data-tone="${s.accountExpired ? 'alert' : s.accountExpiresAt ? 'warn' : 'ok'}">${glyph('calendar')}<div><b>${esc(current)}</b>
        <span>L’expiration bloque l’ouverture de session sans désactiver le compte ; ses groupes et son mot de passe ne changent pas.</span></div></div>
      <form class="cpt-exp" novalidate>
        <div class="k-field"><label for="cpt-exp-date">Le compte expire le (à 0${NBSP}h, heure locale)</label>
          <input class="input" id="cpt-exp-date" type="date" min="${isoDay(now)}" value="${s.accountExpiresAt ? isoDay(new Date(s.accountExpiresAt)) : plus(30)}"></div>
        <div class="cpt-exp-quick" role="group" aria-label="Dates rapides">
          <button class="btn xs subtle" type="button" data-day="${plus(7)}">+ 7 jours</button>
          <button class="btn xs subtle" type="button" data-day="${plus(30)}">+ 30 jours</button>
          <button class="btn xs subtle" type="button" data-day="${plus(90)}">+ 90 jours</button>
          <button class="btn xs subtle" type="button" data-day="${yearEnd}">31 décembre</button>
        </div>
        <p class="cpt-exp-last" aria-live="polite"></p>
        <div class="cpt-pwd-foot">
          <button class="btn danger" type="submit" ${d.actions.expiration.available ? '' : 'disabled'}>${glyph('edit')}Fixer l’expiration…</button>
          <button class="btn subtle" type="button" data-never ${s.accountExpiresAt && d.actions.expiration.available ? '' : 'disabled data-tip="Le compte n’a aucune expiration."'}>${glyph('x')}Supprimer l’expiration…</button>
        </div>
      </form>
    </div>`;
    const input = panel.querySelector('#cpt-exp-date');
    const last = panel.querySelector('.cpt-exp-last');
    const describe = () => {
      const v = input.value;
      if (!v) { last.textContent = ''; return; }
      const [y, m, day] = v.split('-').map(Number);
      const prev = new Date(y, m - 1, day - 1);
      last.textContent = `Dernier jour d’ouverture de session : ${String(prev.getDate()).padStart(2, '0')}/${String(prev.getMonth() + 1).padStart(2, '0')}/${prev.getFullYear()}.`;
    };
    describe();
    input.addEventListener('input', describe);
    panel.querySelectorAll('[data-day]').forEach((b) => b.addEventListener('click', () => { input.value = b.dataset.day; describe(); }));
    panel.querySelector('.cpt-exp').addEventListener('submit', (e) => {
      e.preventDefault();
      if (!/^\d{4}-\d{2}-\d{2}$/.test(input.value)) { ctx.toast('Choisissez une date d’expiration.', { tone: 'warn' }); input.focus(); return; }
      write('expiration', { date: input.value });
    });
    panel.querySelector('[data-never]').addEventListener('click', () => write('expiration', { date: null }));
  }

  function identity(panel, d) {
    const id = d.identity;
    const acc = d.account;
    panel.innerHTML = `<div class="cpt-d-pane"><div class="cpt-kv">${kvSection({ id: 'identite', title: 'Identité', icon: 'user', items: [
      { label: 'Nom affiché', value: id.displayName },
      { label: 'Prénom', value: id.givenName },
      { label: 'Nom', value: id.surname },
      { label: 'Courriel', value: id.mail, copy: true },
      { label: 'Téléphone', value: id.telephone },
      { label: 'Matricule', value: id.employeeId, mono: true },
      { label: 'Responsable', html: id.manager ? `<button class="cpt-link" type="button" data-pick="${esc(id.manager.dn)}">${esc(id.manager.name)}</button>` : undefined, value: id.manager ? undefined : null },
      { label: 'Description', value: id.description, wide: true },
    ] })}${kvSection({ id: 'technique', title: 'Identifiants techniques', icon: 'hash', items: [
      { label: 'Chemin (DN)', value: acc.dn, mono: true, copy: true, wide: true },
      { label: 'GUID', value: acc.guid, mono: true, copy: true, wide: true },
      { label: 'SID', value: id.sid, mono: true, copy: true, wide: true },
      { label: 'Créé', value: when(id.created) },
      { label: 'Modifié', value: when(id.changed), sub: `USN ${formatNumber(id.usn)}` },
    ] })}</div></div>`;
    const sheet = bindKv(panel, { key: 'comptes.identite' });
    cleanups.push(() => sheet.destroy());
    panel.querySelector('[data-pick]')?.addEventListener('click', (e) => o.onPick?.(e.currentTarget.dataset.pick));
  }

  placeholder();
  return {
    show,
    reload,
    current: () => current,
    open: (action) => { if (action === 'mdp') openPasswordTab(); else if (ACTION_TABS[action]) openTab(ACTION_TABS[action]); },
    write,
    destroy: () => { token++; teardown(); },
  };
}
