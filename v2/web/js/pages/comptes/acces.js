// Comptes screen, tab « Accès de Domenia » (Domenia 1 CPT-001 to CPT-018, CPT-021): accesses to review after a refusal,
// the connection account (read only, correction in place), the identities used, the accounts in service, the secondary
// accounts (workstations, secrets) with their validation, the trial on a workstation and the accounts kept in memory.
// Passwords are typed in the page, sent once to the engine (accounts.access.*: SecureString up to the Windows API) and
// cleared from the fields at once; only names come back.
import { glyph, pill, openDrawer, copyButton, bindCopy, NBSP } from '../../kit/index.js';
import { esc, announce, formatNumber, toast } from '../../ui.js';
import { relSpan, when, plural, emptyState, skeletonLines, errorSentence, whenOpen } from './shared.js';

const RESOURCE_ICONS = { Directory: 'database', Remote: 'monitor', ReadLaps: 'key', ReadBitLocker: 'shield' };
const REFRESH_MS = 30_000;

function resourceIcon(key) {
  if (String(key).startsWith('RemoteLocal|')) return 'monitor';
  if (String(key).startsWith('AD:')) return 'database';
  return RESOURCE_ICONS[key] ?? 'link';
}

/** A password field with its reveal button (CSP: no inline handler; wired by bindReveal). */
function passwordField(id, label, { hint = '', disabled = false } = {}) {
  return `<div class="k-field"><label for="${id}">${esc(label)}</label>
    <div class="cpt-pwd-input"><input class="input mono" id="${id}" type="password" autocomplete="off" spellcheck="false" maxlength="256" data-secret${disabled ? ' disabled' : ''}>
      <button class="btn ghost icon sm" type="button" data-reveal aria-label="Afficher le mot de passe" aria-pressed="false" data-tip="Afficher"${disabled ? ' disabled' : ''}>${glyph('eye')}</button></div>
    ${hint ? `<p class="k-hint">${esc(hint)}</p>` : ''}</div>`;
}

function bindReveal(scope) {
  scope.querySelectorAll('[data-reveal]').forEach((b) => b.addEventListener('click', () => {
    const input = b.parentElement.querySelector('input');
    const shown = input.type === 'text';
    input.type = shown ? 'password' : 'text';
    b.setAttribute('aria-pressed', String(!shown));
    b.innerHTML = glyph(shown ? 'eye' : 'eyeOff');
    b.dataset.tip = shown ? 'Afficher' : 'Masquer';
  }));
}

/** Validation progress of a card (12 s at most), with « Annuler » (accounts.access.cancel). */
function progressMarkup(label) {
  return `<div class="cpt-validating" role="status"><span class="cpt-validating-bar" aria-hidden="true"><i></i></span>
    <span>${esc(label)}</span><button class="btn xs subtle" type="button" data-cancel-validation>${glyph('x')}Annuler</button></div>`;
}

function resultMarkup(r) {
  return `<div class="cpt-result" data-tone="${esc(r.tone)}">${glyph(r.success ? 'check' : 'alert')}<div><b>${esc(r.message)}</b>
    ${r.hint ? `<span>${esc(r.hint)}</span>` : ''}<span class="cpt-result-note">${esc(r.rightsNote)}</span></div></div>`;
}

/**
 * Mounts the tab in panel. Returns { refresh, destroy }.
 * @param {HTMLElement} panel @param {any} ctx @param {{ params: any, setCount: (n: number) => void }} page
 */
export function mountAcces(panel, ctx, page) {
  let state = null;
  let alive = true;
  let timer = 0;
  let unbindCopy = () => {};
  let focusedCorrection = false;
  panel.innerHTML = `<div class="cpt-acces" aria-busy="true">${skeletonLines(8)}</div>`;

  async function refresh() {
    try {
      const next = await ctx.call('accounts.access.state');
      if (!alive) return;
      render(next);
    } catch (err) {
      console.error(err);
      if (!alive) return;
      panel.innerHTML = `<div class="cpt-acces">${emptyState({ iconName: 'alert', title: 'Comptes de Domenia indisponibles', text: errorSentence(err), tone: 'alert' })}</div>`;
    }
  }

  function render(s) {
    state = s;
    page.setCount(s.pending.length);
    unbindCopy();
    const c = s.connection;
    panel.innerHTML = `<div class="cpt-acces">
      ${s.pending.length ? pendingCard(s) : ''}
      <div class="grid">
        <section class="card span-7 cpt-conn reveal in" aria-labelledby="cpt-conn-t">${connectionCard(c, s)}</section>
        <section class="card span-5 cpt-ids reveal in" aria-labelledby="cpt-ids-t">
          <div class="card-head"><span class="card-icon">${glyph('users')}</span><div class="cpt-head-titles"><h3 id="cpt-ids-t">Identités utilisées</h3><span>Noms seulement : une identité active ne confirme pas ses droits</span></div></div>
          <ul class="cpt-ids-list">${s.identities.map((i) => `<li data-id="${esc(i.id)}"><span class="cpt-ids-ico">${glyph(i.id === 'directory' ? 'database' : i.id === 'remote' ? 'monitor' : 'key')}</span>
            <span class="cpt-ids-main"><span class="cpt-ids-k">${esc(i.label)}</span><b class="mono">${esc(i.account)}</b><span class="cpt-ids-o">${esc(i.origin)}</span></span></li>`).join('')}</ul>
        </section>
        <section class="card span-12 cpt-now reveal in" aria-labelledby="cpt-now-t">
          <div class="card-head"><span class="card-icon">${glyph('activity')}</span><div class="cpt-head-titles"><h3 id="cpt-now-t">En ce moment</h3><span>Compte que prendra la prochaine opération de chaque ressource ; rien n’y est testé</span></div>
            <span class="meta">${pill(s.inUse.some((r) => r.stateTone !== 'ok') ? 'warn' : 'ok', s.inUse.some((r) => r.stateTone !== 'ok') ? 'Ressource en pause' : 'Aucun refus enregistré', { size: 'sm' })}</span></div>
          <div class="cpt-now-table" role="table" aria-label="Comptes en service">
            <div class="cpt-now-row head" role="row"><span role="columnheader">Ressource</span><span role="columnheader">Compte</span><span role="columnheader">Origine</span><span role="columnheader">État</span><span role="columnheader"><span class="visually-hidden">Action</span></span></div>
            ${s.inUse.map((r) => `<div class="cpt-now-row" role="row" data-tone="${esc(r.stateTone)}">
              <span role="cell" class="cpt-now-res">${glyph(resourceIcon(r.resourceKey))}<b>${esc(r.resource)}</b></span>
              <span role="cell" class="mono">${esc(r.account)}</span>
              <span role="cell" class="cpt-muted">${esc(r.origin)}</span>
              <span role="cell" class="cpt-now-state"><span class="dot" data-tone="${esc(r.stateTone)}"></span>${esc(r.state)}</span>
              <span role="cell">${r.action ? `<button class="btn xs subtle" type="button" data-row-action="${esc(r.action.id)}" data-arg="${esc(r.action.argument ?? '')}">${esc(r.action.label)}</button>` : ''}</span></div>`).join('')}
          </div>
        </section>
        <section class="card span-6 cpt-second reveal in" data-usage="remote" aria-labelledby="cpt-second-remote">${secondaryCard(s.remote, s, 'remote')}</section>
        <section class="card span-6 cpt-second reveal in" data-usage="secrets" aria-labelledby="cpt-second-secrets">${secondaryCard(s.secrets, s, 'secrets')}</section>
        <section class="card span-12 cpt-memory reveal in" aria-labelledby="cpt-mem-t">${memoryCard(s)}</section>
      </div>
      <p class="cpt-acces-foot">${glyph('info')}${esc(s.summary)} Un compte accepté après un refus ne sert qu’à sa ressource (et à son poste) ; aucune écriture n’est jamais rejouée.</p>
    </div>`;
    unbindCopy = bindCopy(panel);
    bindReveal(panel);
    wire();
    if (page.params.corriger === 'connexion' && !focusedCorrection) {
      focusedCorrection = true;
      const field = panel.querySelector('#cpt-correct-pwd');
      panel.querySelector('.cpt-conn').classList.add('flash');
      field?.scrollIntoView({ block: 'center' });
      field?.focus({ preventScroll: true });
      announce('Compte de connexion refusé : saisissez son mot de passe actuel puis « Corriger le mot de passe », ou « Changer de compte ».');
    }
    if (page.params.acces && !panel.dataset.opened) {
      panel.dataset.opened = '1';
      const req = s.pending.find((p) => p.id === page.params.acces) ?? (page.params.acces === 'premier' ? s.pending[0] : null);
      if (req) recover(req);
    }
  }

  function pendingCard(s) {
    return `<section class="card cpt-pending reveal in" aria-labelledby="cpt-pending-t">
      <div class="card-head"><span class="card-icon">${glyph('bell')}</span><div class="cpt-head-titles"><h3 id="cpt-pending-t">Accès à revoir</h3>
        <span>${esc(plural(s.pending.length, 'accès refusé', 'accès refusés'))} · ${formatNumber(s.pendingLimit)} au plus, un par ressource et cible ; les autres fonctions restent disponibles</span></div>
        <span class="meta">${pill('warn', `${formatNumber(s.pending.length)}`, { icon: 'bell', size: 'sm' })}</span></div>
      <ul class="cpt-pending-list">${s.pending.map((p) => `<li data-req="${esc(p.id)}">
        <span class="cpt-pending-ico">${glyph(resourceIcon(p.scope))}</span>
        <span class="cpt-pending-main"><b>${esc(p.operation)}</b><span>${esc(p.scopeLabel)}${p.target ? ` · <span class="mono">${esc(p.target)}</span>` : ''} · ${esc(p.kindLabel)}</span></span>
        <span class="cpt-pending-when">${relSpan(p.at)}</span>
        <span class="cpt-pending-actions"><button class="btn sm primary" type="button" data-recover="${esc(p.id)}">${glyph('user')}Utiliser un autre compte…</button>
          <button class="btn sm subtle" type="button" data-dismiss="${esc(p.id)}">Garder le compte actuel</button></span></li>`).join('')}</ul>
    </section>`;
  }

  function connectionCard(c, s) {
    const modePill = c.mode === 'demo' ? pill('accent', c.modeLabel, { icon: 'sparkles', size: 'sm' }) : pill('info', c.modeLabel, { icon: c.mode === 'windows' ? 'monitor' : 'key', size: 'sm' });
    return `<div class="card-head"><span class="card-icon">${glyph('user')}</span><div class="cpt-head-titles"><h3 id="cpt-conn-t">Compte de connexion</h3><span>Identité liée à l’annuaire, en lecture seule</span></div><span class="meta">${modePill}</span></div>
      <div class="cpt-conn-id"><span class="cpt-conn-ring" aria-hidden="true">${glyph('shield')}</span>
        <div><b class="mono">${esc(c.identity)}</b>${copyButton(c.identity, { label: 'Copier l’identité', done: 'Copiée' })}<span>${esc(c.displayName ?? '')}</span></div></div>
      <dl class="cpt-conn-facts">
        <div><dt>Contrôleur</dt><dd>${esc(c.controller ?? '—')}${c.site ? `<span>Site ${esc(c.site)}</span>` : ''}</dd></div>
        <div><dt>Domaine</dt><dd>${esc(c.domain ?? '—')}${c.netbios ? `<span>NetBIOS ${esc(c.netbios)}</span>` : ''}</dd></div>
        <div><dt>Authentification</dt><dd>${esc(c.authentication)}</dd></div>
        <div><dt>Connecté</dt><dd>${c.since ? relSpan(c.since, { prefix: '' }) : '—'}${c.since ? `<span>${esc(when(c.since) ?? '')}</span>` : ''}</dd></div>
      </dl>
      <div class="cpt-conn-correct${c.correction.available ? '' : ' off'}">
        <h4>${glyph('key')}Corriger le mot de passe sans reconnecter</h4>
        <p>Après un changement de mot de passe dans l’annuaire : une seule validation du même compte, puis le nouveau mot de passe remplace l’ancien en mémoire.</p>
        <form class="cpt-inline-form" data-form="correct" novalidate autocomplete="off">
          ${passwordField('cpt-correct-pwd', 'Mot de passe actuel du compte de connexion', { disabled: !c.correction.available })}
          <button class="btn" type="submit" ${c.correction.available ? '' : `disabled data-tip="${esc(c.correction.reason ?? '')}"`}>${glyph('check')}Corriger le mot de passe</button>
        </form>
        ${c.correction.available ? '' : `<p class="cpt-reason">${glyph('info')}${esc(c.correction.reason ?? '')}</p>`}
        <div class="cpt-form-out" data-out="correct"></div>
      </div>
      <div class="card-actions"><button class="btn subtle" type="button" data-relogin ${c.relogin.available ? '' : `aria-disabled="true" data-tip="${esc(c.relogin.reason ?? '')}"`}>${glyph('refresh')}Changer de compte</button>
        ${c.relogin.available ? '' : `<span class="cpt-muted cpt-small">${esc(c.relogin.reason ?? '')}</span>`}</div>`;
  }

  function secondaryCard(acc, s, usage) {
    const remote = usage === 'remote';
    const remembered = acc.remembered
      ? `<div class="cpt-remembered">${glyph('pin')}<span>Identifiant mémorisé : <b class="mono">${esc(acc.remembered.account)}</b> · utilisé ${relSpan(acc.remembered.lastUsedAt)}</span>
          <button class="btn xs subtle" type="button" data-forget-remembered="${usage}">Oublier</button></div>` : '';
    const trial = remote ? `<div class="cpt-trial">
        <h4>${glyph('monitor')}Essayer sur un poste</h4>
        <p>Une seule lecture légère (Win32_OperatingSystem) du poste choisi avec le compte que prendront les opérations sur les postes ; ni balayage, ni ping, ni console.</p>
        <form class="cpt-inline-form" data-form="trial" novalidate autocomplete="off">
          <div class="k-field"><label for="cpt-trial-pc">Nom du poste</label><input class="input mono" id="cpt-trial-pc" type="text" maxlength="253" spellcheck="false" placeholder="PC-PAR-0001" value="${esc(s.lastTrial?.computer ?? '')}"></div>
          <button class="btn" type="submit">${glyph('wifi')}Essayer</button>
        </form>
        <div class="cpt-form-out" data-out="trial">${s.lastTrial ? trialMarkup(s.lastTrial) : ''}</div></div>` : '';
    return `<div class="card-head"><span class="card-icon">${glyph(remote ? 'monitor' : 'key')}</span><div class="cpt-head-titles"><h3 id="cpt-second-${usage}">${esc(acc.label)}</h3>
        <span>${remote ? 'Opérations distantes : WMI, partage C$, consoles' : 'Lecture des secrets LAPS et BitLocker'}</span></div>
        <span class="meta">${pill(acc.statusTone, acc.active ? 'Actif' : 'Non défini', { icon: acc.active ? 'check' : 'info', size: 'sm' })}</span></div>
      <p class="cpt-second-status" data-tone="${esc(acc.statusTone)}">${acc.active ? `<b class="mono">${esc(acc.account)}</b> · activé ${relSpan(acc.activatedAt)}${acc.controller ? ` · validé par ${esc(acc.controller)}` : ''}<br>` : ''}${esc(acc.status)}</p>
      ${remembered}
      <form class="cpt-second-form" data-form="${usage}" novalidate autocomplete="off">
        <div class="k-field"><label for="cpt-${usage}-login">Identifiant</label>
          <input class="input mono" id="cpt-${usage}-login" type="text" spellcheck="false" maxlength="260" autocomplete="off" placeholder="DOMAINE\\compte ou compte@domaine" value="${esc(acc.account ?? acc.remembered?.account ?? '')}"></div>
        ${passwordField(`cpt-${usage}-pwd`, 'Mot de passe')}
        <label class="k-check-row off" data-tip="${esc(s.vault.reason)}"><input class="k-checkbox" type="checkbox" disabled><span>Mémoriser sur ce PC (coffre Windows)</span></label>
        <div class="cpt-second-actions">
          <button class="btn subtle" type="button" data-test="${usage}">${glyph('eye')}Tester</button>
          <button class="btn primary" type="submit">${glyph('check')}Activer</button>
          ${acc.active ? `<button class="btn subtle" type="button" data-clear="${usage}">${glyph('x')}Effacer</button>` : ''}
        </div>
      </form>
      <div class="cpt-form-out" data-out="${usage}"></div>
      <p class="cpt-small cpt-muted">${glyph('shield')}La validation vérifie l’identité dans l’annuaire, pas les droits sur ${remote ? 'les postes' : 'LAPS et BitLocker'}. Le mot de passe reste en mémoire protégée, jamais sur le disque.</p>
      ${trial}`;
  }

  function trialMarkup(t) {
    return `<div class="cpt-result" data-tone="${esc(t.tone)}">${glyph(t.success ? 'check' : 'alert')}<div><b>${esc(t.text)}</b>
      <span>Compte : <span class="mono">${esc(t.account)}</span> (${esc(t.origin)}) · ${esc(when(t.at) ?? '')}${t.simulated ? ' · poste fictif' : ''}</span></div></div>`;
  }

  function memoryCard(s) {
    const temporaries = s.memory.filter((m) => m.key.startsWith('temporary:')).length;
    return `<div class="card-head"><span class="card-icon">${glyph('clock')}</span><div class="cpt-head-titles"><h3 id="cpt-mem-t">Comptes gardés en mémoire</h3>
        <span>Durée par défaut : ${formatNumber(s.lease.defaultMinutes)}${NBSP}min sans utilisation (de ${formatNumber(s.lease.minMinutes)} à ${formatNumber(s.lease.maxMinutes)}) ; un affichage ne prolonge jamais un compte</span></div>
        <span class="meta"><button class="btn sm subtle" type="button" data-forget-all ${temporaries ? '' : 'disabled data-tip="Aucun compte temporaire en mémoire."'}>${glyph('trash')}Tout oublier</button></span></div>
      ${s.memory.length ? `<ul class="cpt-mem-list">${s.memory.map((m) => `<li data-tone="${esc(m.stateTone)}">
          <span class="cpt-mem-ico">${glyph(m.key.startsWith('secondary:') ? 'pin' : 'clock')}</span>
          <span class="cpt-mem-main"><b>${esc(m.resource)}</b><span class="mono">${esc(m.account)}</span></span>
          <span class="cpt-mem-left">${m.minutes > 0 ? pill(m.minutes <= 5 ? 'warn' : 'info', `${formatNumber(m.minutes)}${NBSP}min`, { icon: 'clock', size: 'sm' }) : ''}<span>${esc(m.remaining)}</span></span>
          <span class="cpt-mem-state">${esc(m.state)}</span>
          <button class="btn xs subtle" type="button" data-forget="${esc(m.key)}">Oublier</button></li>`).join('')}</ul>`
        : `<p class="cpt-mem-empty">${glyph('check')}Aucun compte temporaire ni secondaire en mémoire : toutes les ressources utilisent le compte de connexion.</p>`}`;
  }

  // ---------- Actions ----------

  function out(name) { return panel.querySelector(`[data-out="${name}"]`); }

  async function guarded(name, label, run) {
    const box = out(name);
    const forms = panel.querySelectorAll('form button, form input');
    if (box) box.innerHTML = progressMarkup(label);
    forms.forEach((el) => { el.dataset.wasDisabled = String(el.disabled); el.disabled = true; });
    box?.querySelector('[data-cancel-validation]')?.addEventListener('click', () => ctx.call('accounts.access.cancel').catch((err) => console.error(err)));
    try {
      return await run();
    } catch (err) {
      console.error(err);
      if (box?.isConnected) box.innerHTML = `<div class="cpt-result" data-tone="alert">${glyph('alert')}<div><b>${esc(errorSentence(err))}</b></div></div>`;
      return null;
    } finally {
      forms.forEach((el) => { if (el.isConnected) el.disabled = el.dataset.wasDisabled === 'true'; });
    }
  }

  function readForm(form) {
    const login = form.querySelector('input[type="text"]:not([data-secret])')?.value.trim() ?? '';
    const secret = form.querySelector('[data-secret]');
    return { login, secret };
  }

  async function secondary(usage, activate) {
    const form = panel.querySelector(`[data-form="${usage}"]`);
    const { login, secret } = readForm(form);
    if (!login || !secret.value) { toast('Saisissez l’identifiant et le mot de passe.', { tone: 'warn' }); (login ? secret : form.querySelector('input')).focus(); return; }
    const password = secret.value;
    secret.value = '';
    const result = await guarded(usage, activate ? 'Validation puis activation…' : 'Validation du compte…', () => ctx.call(activate ? 'accounts.access.activate' : 'accounts.access.test', { usage, login, password }));
    if (!result || !alive) return;
    if (activate) {
      render(result.state);
      out(usage).innerHTML = resultMarkup(result.result);
      toast(result.result.success ? `${result.state[usage].label} activé : ${result.result.identity}.` : result.result.message, { tone: result.result.success ? 'ok' : 'alert' });
    } else {
      out(usage).innerHTML = resultMarkup(result);
      announce(result.message);
    }
  }

  function wire() {
    const root = panel.querySelector('.cpt-acces');
    root.addEventListener('click', async (e) => {
      const t = e.target.closest('button');
      if (!t || t.disabled) return;
      if (t.dataset.recover) recover(state.pending.find((p) => p.id === t.dataset.recover));
      else if (t.dataset.dismiss) run(() => ctx.call('accounts.access.dismiss', { id: t.dataset.dismiss }), 'Compte actuel conservé.');
      else if (t.dataset.test) secondary(t.dataset.test, false);
      else if (t.dataset.clear) run(() => ctx.call('accounts.access.clear', { usage: t.dataset.clear }), 'Retour au compte de connexion.');
      else if (t.dataset.forget) run(() => ctx.call('accounts.access.forget', { key: t.dataset.forget }), 'Compte oublié.');
      else if (t.dataset.forgetAll !== undefined) run(() => ctx.call('accounts.access.forgetAll'), 'Comptes temporaires oubliés.');
      else if (t.dataset.forgetRemembered) run(() => ctx.call('accounts.remembered.forget', { usage: t.dataset.forgetRemembered }), 'Identifiant oublié.');
      else if (t.dataset.relogin !== undefined && t.getAttribute('aria-disabled') === 'true') toast(state.connection.relogin.reason ?? '', { tone: 'info', life: 6000 });
      else if (t.dataset.rowAction) rowAction(t.dataset.rowAction, t.dataset.arg);
    });
    root.querySelectorAll('form').forEach((form) => form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const kind = form.dataset.form;
      if (kind === 'remote' || kind === 'secrets') secondary(kind, true);
      else if (kind === 'correct') correct(form);
      else if (kind === 'trial') trial(form);
    }));
  }

  async function run(call, done) {
    try {
      const next = await call();
      if (!alive) return;
      render(next);
      toast(done, { tone: 'ok', life: 2600 });
    } catch (err) {
      console.error(err);
      toast(errorSentence(err), { tone: 'alert' });
    }
  }

  function rowAction(id, arg) {
    if (id === 'recover') recover(state.pending.find((p) => p.id === arg));
    else if (id === 'forget') run(() => ctx.call('accounts.access.forget', { key: arg }), 'Compte oublié.');
    else if (id === 'correct') { const f = panel.querySelector('#cpt-correct-pwd'); f?.scrollIntoView({ block: 'center' }); f?.focus({ preventScroll: true }); }
    else if (id === 'try') { const f = panel.querySelector('#cpt-trial-pc'); f?.scrollIntoView({ block: 'center' }); f?.focus({ preventScroll: true }); }
    else if (id === 'activate') { const f = panel.querySelector(`#cpt-${arg}-login`); f?.scrollIntoView({ block: 'center' }); f?.focus({ preventScroll: true }); }
  }

  async function correct(form) {
    const secret = form.querySelector('[data-secret]');
    if (!secret.value) { secret.focus(); return; }
    const password = secret.value;
    secret.value = '';
    const r = await guarded('correct', 'Validation du même compte…', () => ctx.call('accounts.connection.correct', { password }));
    if (r && alive) { out('correct').innerHTML = resultMarkup(r); if (r.success) refresh(); }
  }

  async function trial(form) {
    const input = form.querySelector('#cpt-trial-pc');
    const computer = input.value.trim();
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$/.test(computer)) { toast('Saisissez un nom de poste valide.', { tone: 'warn' }); input.focus(); return; }
    const box = out('trial');
    box.innerHTML = `<div class="cpt-validating" role="status"><span class="cpt-validating-bar" aria-hidden="true"><i></i></span><span>Lecture légère de ${esc(computer)}…</span></div>`;
    try {
      const t = await ctx.call('accounts.access.tryRemote', { computer });
      if (!alive) return;
      box.innerHTML = trialMarkup(t);
      announce(t.text);
    } catch (err) {
      console.error(err);
      if (box.isConnected) box.innerHTML = `<div class="cpt-result" data-tone="alert">${glyph('alert')}<div><b>${esc(errorSentence(err))}</b></div></div>`;
    }
  }

  /** « Utiliser un autre compte » (CPT-002): panel with the context, the lease and one validation. */
  async function recover(req) {
    if (!req) return;
    const remote = req.scope === 'Remote';
    const body = document.createElement('div');
    body.className = 'cpt-recover';
    body.dataset.page = 'comptes';
    body.innerHTML = `<div class="cpt-recover-head" data-tone="warn">${glyph(resourceIcon(req.scope))}<div><b>${esc(req.operation)}</b>
        <span>${esc(req.scopeLabel)}${req.target ? ` · ${esc(req.target)}` : ''} · ${esc(req.kindLabel)} · ${esc(when(req.at) ?? '')}</span></div></div>
      <p>Le compte proposé ne servira qu’à cette ressource${remote ? ' et à ce poste' : ''}. Les autres fonctions restent disponibles ; aucune écriture n’est rejouée : relancez l’action vous-même ensuite.</p>
      <form class="cpt-recover-form" novalidate autocomplete="off">
        <div class="k-field"><label for="cpt-rec-login">Compte</label><input class="input mono" id="cpt-rec-login" type="text" spellcheck="false" maxlength="260" placeholder="${remote ? 'DOMAINE\\compte, POSTE\\compte ou .\\compte' : 'DOMAINE\\compte ou compte@domaine'}"></div>
        ${passwordField('cpt-rec-pwd', 'Mot de passe')}
        ${remote ? `<div class="k-field"><label for="cpt-rec-target">Poste</label><input class="input mono" id="cpt-rec-target" type="text" maxlength="253" spellcheck="false" value="${esc(req.target ?? '')}"><p class="k-hint">« .\\compte » est complété par ce nom de poste.</p></div>` : ''}
        <fieldset class="k-field cpt-lease"><legend>Durée en mémoire</legend>
          <label class="k-check-row"><input class="k-radio" type="radio" name="lease" value="inactivity" checked><span>Tant qu’il sert : oublié après</span>
            <input class="input cpt-lease-min" type="number" min="${state.lease.minMinutes}" max="${state.lease.maxMinutes}" value="${state.lease.defaultMinutes}" aria-label="Minutes sans utilisation"><span>min sans utilisation</span></label>
          <label class="k-check-row"><input class="k-radio" type="radio" name="lease" value="session"><span>Jusqu’à la fin de la session</span></label>
          <label class="k-check-row"><input class="k-radio" type="radio" name="lease" value="once"><span>Une seule utilisation</span></label>
        </fieldset>
      </form>
      <div class="cpt-form-out" data-rec-out></div>`;
    const panelD = openDrawer({
      title: 'Utiliser un autre compte',
      subtitle: req.scopeLabel,
      icon: 'user',
      key: 'comptes.recover',
      width: 520,
      body,
      focusFirst: true,
      actions: [
        { id: 'cancel', label: 'Garder le compte actuel', run: (p) => p.close() },
        { id: 'ok', label: 'Valider et utiliser', icon: 'check', primary: true, run: () => submit() },
      ],
    });
    if (!(await whenOpen(panelD))) return;
    bindReveal(body);
    body.querySelector('form').addEventListener('submit', (e) => { e.preventDefault(); submit(); });
    async function submit() {
      const login = body.querySelector('#cpt-rec-login').value.trim();
      const secret = body.querySelector('#cpt-rec-pwd');
      const target = remote ? (body.querySelector('#cpt-rec-target').value.trim() || null) : null;
      const lease = body.querySelector('input[name="lease"]:checked')?.value ?? 'inactivity';
      const minutes = Number(body.querySelector('.cpt-lease-min').value) || state.lease.defaultMinutes;
      if (!login || !secret.value) { (login ? secret : body.querySelector('#cpt-rec-login')).focus(); return; }
      const password = secret.value;
      secret.value = '';
      const box = body.querySelector('[data-rec-out]');
      box.innerHTML = progressMarkup('Validation du compte proposé…');
      box.querySelector('[data-cancel-validation]').addEventListener('click', () => ctx.call('accounts.access.cancel').catch((err) => console.error(err)));
      panelD.setBusy(true);
      try {
        const r = await ctx.call('accounts.access.recover', { id: req.id, login, password, lease, minutes: Math.min(state.lease.maxMinutes, Math.max(state.lease.minMinutes, minutes)), target });
        panelD.setBusy(false);
        if (alive) render(r.state);
        if (r.result.success) {
          toast(`Compte validé et gardé pour ${req.scopeLabel} : relancez l’action vous-même.`, { tone: 'ok', life: 6000 });
          panelD.close();
        } else if (body.isConnected) {
          box.innerHTML = resultMarkup(r.result);
        }
      } catch (err) {
        console.error(err);
        panelD.setBusy(false);
        if (body.isConnected) box.innerHTML = `<div class="cpt-result" data-tone="alert">${glyph('alert')}<div><b>${esc(errorSentence(err))}</b></div></div>`;
      }
    }
  }

  refresh();
  timer = setInterval(() => { if (alive && !document.hidden && panel.offsetParent && !panel.querySelector('.cpt-validating')) refresh(); }, REFRESH_MS);
  return {
    refresh,
    destroy: () => { alive = false; clearInterval(timer); unbindCopy(); },
  };
}
