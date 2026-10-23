// Comptes screen, tab « Accès de Domenia » (Domenia 1 CPT-001 to CPT-018, CPT-021): accesses to review after a refusal,
// the connection account (read only, correction in place, « Changer de compte »), the identities used, the accounts in
// service, the secondary accounts (workstations, secrets) with their validation, the trial on a workstation and the
// accounts kept in memory. Real credentials use the native secure window; simulation keeps fictitious page input.
// Only names, verdicts and single-use vault tickets return to the page.
//
// The tab is built ONCE; afterwards only its state zones are repainted (pending, connection facts, identities, « En ce
// moment », statuses, memory), never a form: an identifier or a password being typed in another card is never erased
// (Domenia 1 CPT-006 « ne réécrit jamais les champs en cours de saisie », CPT-016 « une lecture asynchrone n’écrase jamais un
// texte tapé »). The page asks accounts.access.revision each second while the tab is shown and reads the state again only
// when it changed (CPT-010: refreshed each second when the content changes; a lease that counts down changes each minute).
import { glyph, pill, openDrawer, copyButton, bindCopy, confirmDialog, NBSP } from '../../kit/index.js';
import { esc, announce, formatNumber, toast } from '../../ui.js';
import { relSpan, when, plural, emptyState, skeletonLines, errorSentence, whenOpen, bindReveal, accessChanged } from './shared.js';
import { mayPrefill } from './rules.js';

const RESOURCE_ICONS = { Directory: 'database', Remote: 'monitor', ReadLaps: 'key', ReadBitLocker: 'shield' };
const POLL_MS = 1000;

function resourceIcon(key) {
  if (String(key).startsWith('RemoteLocal|')) return 'monitor';
  if (String(key).startsWith('AD:')) return 'database';
  return RESOURCE_ICONS[key] ?? 'link';
}

/** A password field with its reveal button (CSP: no inline handler; wired by bindReveal of shared.js). */
function webPasswordField(id, label, { hint = '', disabled = false } = {}) {
  return `<div class="k-field"><label for="${id}">${esc(label)}</label>
    <div class="cpt-pwd-input"><input class="input mono" id="${id}" type="password" autocomplete="off" spellcheck="false" maxlength="256" data-secret${disabled ? ' disabled' : ''}>
      <button class="btn ghost icon sm" type="button" data-reveal aria-label="Afficher le mot de passe quelques secondes" aria-pressed="false"${disabled ? ' disabled' : ''}>${glyph('eye')}</button></div>
    ${hint ? `<p class="k-hint">${esc(hint)}</p>` : ''}</div>`;
}

/** Validation progress of a card (12 s at most), with « Annuler » (accounts.access.cancel). */
function progressMarkup(label) {
  return `<div class="cpt-validating" role="status"><span class="cpt-validating-bar" aria-hidden="true"><i></i></span>
    <span>${esc(label)}</span><button class="btn xs subtle" type="button" data-cancel-validation>${glyph('x')}Annuler</button></div>`;
}

function resultMarkup(r) {
  return `<div class="cpt-result" data-tone="${esc(r.tone)}">${glyph(r.success ? 'check' : 'alert')}<div><b>${esc(r.message)}</b>
    ${r.hint ? `<span>${esc(r.hint)}</span>` : ''}${r.rightsNote ? `<span class="cpt-result-note">${esc(r.rightsNote)}</span>` : ''}</div></div>`;
}

function errorMarkup(err) {
  return `<div class="cpt-result" data-tone="alert">${glyph('alert')}<div><b>${esc(errorSentence(err))}</b></div></div>`;
}

/**
 * Mounts the tab in panel. Returns { refresh, destroy }.
 * @param {HTMLElement} panel @param {any} ctx
 * @param {{ params: any, setCount: (n: number) => void, onSession?: () => void }} page
 */
export function mountAcces(panel, ctx, page) {
  const nativeEntry = () => !page.simulated();
  const passwordField = (id, label, options) => nativeEntry()
    ? `<p id="${id}" class="k-hint" tabindex="-1">Le mot de passe sera demandé dans une fenêtre sécurisée après ce formulaire.</p>`
    : webPasswordField(id, label, options);
  async function credentialCall(operation, args) {
    const values = { ...args };
    if (nativeEntry()) {
      delete values.password;
      values.theme = document.documentElement.dataset.theme === 'light' ? 'light' : document.documentElement.dataset.theme === 'contrast' ? 'contrast' : 'dark';
    }
    const result = await ctx.call(operation, values);
    const validation = result.result ?? result;
    if (validation.vaultSaveTicket) {
      const ticket = validation.vaultSaveTicket;
      delete validation.vaultSaveTicket;
      try {
        const receipt = await ctx.call('accounts.vault.save', { ticket });
        validation.hint = `${validation.hint ?? ''} ${receipt.message}`.trim();
        if (!receipt.complete) validation.tone = 'warn';
      } catch (error) {
        validation.hint = `${validation.hint ?? ''} Compte validé, mais coffre non enregistré : ${errorSentence(error)}`.trim();
        validation.tone = 'warn';
      }
    }
    return result;
  }
  let state = null;
  let alive = true;
  let built = false;
  let busy = 0; // validations started from this tab (forms stay occupied, CPT-021)
  let timer = 0;
  let polling = false;
  let seen = { revision: null, leaseMinute: null, epoch: null };
  let unbindCopy = () => {};
  let peek = null;
  let focusedCorrection = false;
  let wantedRequest = null; // « Accès à revoir » of the header: the request to open once the state is read
  const dirty = new Set(); // fields typed by the operator since they were drawn: never prefilled again
  panel.innerHTML = `<div class="cpt-acces" aria-busy="true">${skeletonLines(8)}</div>`;

  // ---------------------------------------------------------------- reads

  async function refresh() {
    try {
      const next = await ctx.call('accounts.access.state');
      if (!alive) return;
      apply(next);
    } catch (err) {
      console.error(err);
      if (!alive) return;
      if (!built) panel.innerHTML = `<div class="cpt-acces">${emptyState({ iconName: 'alert', title: 'Comptes de Domenia indisponibles', text: errorSentence(err), tone: 'alert' })}</div>`;
      else zone('foot').innerHTML = `${glyph('alert')}<span>${esc(errorSentence(err))}</span>`;
    }
  }

  /** Each second while the tab is shown: the state is read again only when its revision (or a lease minute) changed. */
  async function poll() {
    if (polling || !alive || document.hidden || !panel.offsetParent || !built) return;
    polling = true;
    try {
      const r = await ctx.call('accounts.access.revision');
      if (!alive) return;
      page.setCount(r.pending);
      if (r.revision !== seen.revision || r.leaseMinute !== seen.leaseMinute || r.epoch !== seen.epoch) {
        const sessionChanged = seen.epoch !== null && r.epoch !== seen.epoch;
        seen = { revision: r.revision, leaseMinute: r.leaseMinute, epoch: r.epoch };
        await refresh();
        if (sessionChanged) page.onSession?.();
      }
    } catch (err) {
      console.error(err);
    } finally {
      polling = false;
    }
  }

  function apply(s) {
    state = s;
    seen = { ...seen, revision: s.revision, epoch: s.epoch };
    page.setCount(s.pending.length);
    if (!built) build(s);
    update(s);
    openFromParams(s);
  }

  // ---------------------------------------------------------------- layout (built once)

  const zone = (name) => panel.querySelector(`[data-zone="${name}"]`);
  const out = (name) => panel.querySelector(`[data-out="${name}"]`);
  const painted = new Map();
  /** Repaints a state zone only when its markup changed: its entrance animations never replay for nothing. */
  const paint = (name, html) => {
    if (painted.get(name) === html) return;
    painted.set(name, html);
    const el = zone(name);
    if (el) el.innerHTML = html;
  };

  function build(s) {
    built = true;
    panel.innerHTML = `<div class="cpt-acces">
      <div class="cpt-acces-pending" data-zone="pending"></div>
      <div class="grid">
        <section class="card span-7 cpt-conn reveal in" aria-labelledby="cpt-conn-t">
          <div data-zone="conn"></div>
          <div class="cpt-conn-correct">
            <h4>${glyph('key')}Corriger le mot de passe sans reconnecter</h4>
            <p>Après un changement de mot de passe dans l’annuaire${NBSP}: une seule validation du même compte, puis le nouveau mot de passe remplace l’ancien en mémoire et les lectures parties avec l’ancien sont arrêtées.</p>
            <form class="cpt-inline-form" data-form="correct" novalidate autocomplete="off">
              ${passwordField('cpt-correct-pwd', 'Mot de passe actuel du compte de connexion')}
              <button class="btn" type="submit" data-submit="correct">${glyph('check')}Corriger le mot de passe</button>
            </form>
            <p class="cpt-reason" data-zone="correct-reason" hidden></p>
            <div class="cpt-form-out" data-out="correct"></div>
          </div>
          <div class="card-actions cpt-conn-actions"><button class="btn" type="button" data-relogin>${glyph('refresh')}Changer de compte…</button>${nativeEntry() ? `<button class="btn subtle" type="button" data-vault-forget="directory">${glyph('key')}Oublier dans le coffre…</button>` : ''}
            <span class="cpt-muted cpt-small" data-zone="relogin-reason"></span></div>
        </section>
        <section class="card span-5 cpt-ids reveal in" aria-labelledby="cpt-ids-t">
          <div class="card-head"><span class="card-icon">${glyph('users')}</span><div class="cpt-head-titles"><h3 id="cpt-ids-t">Identités utilisées</h3><span>Noms seulement${NBSP}: une identité active ne confirme pas ses droits</span></div></div>
          <ul class="cpt-ids-list" data-zone="ids"></ul>
        </section>
        <section class="card span-12 cpt-now reveal in" aria-labelledby="cpt-now-t">
          <div class="card-head"><span class="card-icon">${glyph('activity')}</span><div class="cpt-head-titles"><h3 id="cpt-now-t">En ce moment</h3><span>Compte que prendra la prochaine opération de chaque ressource${NBSP}; rien n’y est testé</span></div>
            <span class="meta" data-zone="now-meta"></span></div>
          <div class="cpt-now-table" role="table" aria-label="Comptes en service">
            <div class="cpt-now-row head" role="row"><span role="columnheader">Ressource</span><span role="columnheader">Compte</span><span role="columnheader">Origine</span><span role="columnheader">État</span><span role="columnheader"><span class="visually-hidden">Action</span></span></div>
            <div class="cpt-now-body" role="rowgroup" data-zone="now"></div>
          </div>
        </section>
        ${['remote', 'secrets'].map((usage) => secondaryShell(usage, s)).join('')}
        <section class="card span-12 cpt-memory reveal in" aria-labelledby="cpt-mem-t">
          <div class="card-head"><span class="card-icon">${glyph('clock')}</span><div class="cpt-head-titles"><h3 id="cpt-mem-t">Comptes gardés en mémoire</h3>
            <span data-zone="mem-sub"></span></div>
            <span class="meta"><button class="btn sm subtle" type="button" data-forget-all>${glyph('trash')}Tout oublier…</button></span></div>
          <div data-zone="memory"></div>
        </section>
      </div>
      <p class="cpt-acces-foot" data-zone="foot"></p>
    </div>`;
    peek = bindReveal(panel, { seconds: s.revealSeconds || 5 });
    unbindCopy = bindCopy(panel);
    // A field typed by the operator is never overwritten by a later read (CPT-016).
    panel.addEventListener('input', (e) => { if (e.target instanceof HTMLInputElement && e.target.id) dirty.add(e.target.id); });
    wire();
  }

  function secondaryShell(usage, s) {
    const remote = usage === 'remote';
    const trial = remote ? `<div class="cpt-trial">
        <h4>${glyph('monitor')}Essayer sur un poste</h4>
        <p>Une seule lecture légère (Win32_OperatingSystem) du poste choisi avec le compte que prendront les opérations sur les postes${NBSP}; ni balayage, ni ping, ni console.</p>
        <form class="cpt-inline-form" data-form="trial" novalidate autocomplete="off">
          <div class="k-field"><label for="cpt-trial-pc">Nom du poste</label><input class="input mono" id="cpt-trial-pc" type="text" maxlength="253" spellcheck="false" placeholder="PC-PAR-0001"></div>
          <button class="btn" type="submit" data-submit="trial">${glyph('wifi')}Essayer</button>
        </form>
        <div class="cpt-form-out" data-out="trial"></div></div>` : '';
    return `<section class="card span-6 cpt-second reveal in" data-usage="${usage}" aria-labelledby="cpt-second-${usage}">
      <div class="card-head"><span class="card-icon">${glyph(remote ? 'monitor' : 'key')}</span><div class="cpt-head-titles"><h3 id="cpt-second-${usage}">${esc(remote ? 'Compte Postes' : 'Compte Secrets')}</h3>
        <span>${remote ? `Opérations distantes${NBSP}: WMI, partage C$, consoles` : 'Lecture des secrets LAPS et BitLocker'}</span></div>
        <span class="meta" data-zone="${usage}-pill"></span></div>
      <p class="cpt-second-status" data-zone="${usage}-status"></p>
      <div data-zone="${usage}-remembered"></div>
      <form class="cpt-second-form" data-form="${usage}" novalidate autocomplete="off">
        <div class="k-field"><label for="cpt-${usage}-login">Identifiant</label>
          <input class="input mono" id="cpt-${usage}-login" type="text" spellcheck="false" maxlength="260" autocomplete="off" placeholder="DOMAINE\\compte ou compte@domaine"></div>
        ${passwordField(`cpt-${usage}-pwd`, 'Mot de passe')}
        ${nativeEntry() ? `<p class="k-hint">La fenêtre sécurisée propose le coffre Windows après validation.</p><button class="btn xs subtle" type="button" data-vault-forget="${usage}">Oublier dans le coffre…</button>` : `<label class="k-check-row off" data-tip="${esc(s.vault.reason)}"><input class="k-checkbox" type="checkbox" disabled><span>Mémoriser sur ce PC (coffre Windows)</span></label>`}
        <div class="cpt-second-actions">
          <span data-zone="${usage}-clear"></span>
          <button class="btn subtle" type="button" data-test="${usage}">${glyph('eye')}Tester</button>
          <button class="btn" type="submit" data-submit="${usage}">${glyph('check')}Activer</button>
        </div>
      </form>
      <div class="cpt-form-out" data-out="${usage}"></div>
      <p class="cpt-small cpt-muted">${glyph('shield')}La validation vérifie l’identité dans l’annuaire, pas les droits sur ${remote ? 'les postes' : 'LAPS et BitLocker'}. Le mot de passe reste en mémoire protégée ; seule une mémorisation choisie explicitement utilise le coffre Windows.</p>
      ${trial}
    </section>`;
  }

  // ---------------------------------------------------------------- state zones (repainted, never a form)

  function update(s) {
    unbindCopy();
    const c = s.connection;
    paint('pending', s.pending.length ? pendingCard(s) : '');
    paint('conn', connectionFacts(c));
    // Correction form: only its availability changes (the typed password stays).
    const correctReason = zone('correct-reason');
    correctReason.hidden = c.correction.available;
    correctReason.innerHTML = c.correction.available ? '' : `${glyph('info')}${esc(c.correction.reason ?? '')}`;
    panel.querySelector('.cpt-conn-correct').classList.toggle('off', !c.correction.available);
    setFormEnabled('correct', c.correction.available, c.correction.reason);
    const relogin = panel.querySelector('[data-relogin]');
    relogin.setAttribute('aria-disabled', String(!c.relogin.available));
    if (c.relogin.available) delete relogin.dataset.tip; else relogin.dataset.tip = c.relogin.reason ?? '';
    zone('relogin-reason').textContent = c.relogin.available ? 'Une validation, nouvelle session, rien n’est rejoué.' : (c.relogin.reason ?? '');
    paint('ids', s.identities.map((i) => `<li data-id="${esc(i.id)}"><span class="cpt-ids-ico">${glyph(i.id === 'directory' ? 'database' : i.id === 'remote' ? 'monitor' : 'key')}</span>
      <span class="cpt-ids-main"><span class="cpt-ids-k">${esc(i.label)}</span><b class="mono">${esc(i.account)}</b><span class="cpt-ids-o">${esc(i.origin)}</span></span></li>`).join(''));
    const paused = s.inUse.some((r) => r.stateTone !== 'ok');
    paint('now-meta', pill(paused ? 'warn' : 'ok', paused ? 'Ressource en pause ou à revoir' : 'Aucun refus enregistré', { size: 'sm' }));
    paint('now', s.inUse.map((r) => `<div class="cpt-now-row" role="row" data-tone="${esc(r.stateTone)}">
      <span role="cell" class="cpt-now-res">${glyph(resourceIcon(r.resourceKey))}<b>${esc(r.resource)}</b></span>
      <span role="cell" class="mono cpt-ellipsis" data-tip="${esc(r.account)}">${esc(r.account)}</span>
      <span role="cell" class="cpt-muted">${esc(r.origin)}</span>
      <span role="cell" class="cpt-now-state"><span class="dot" data-tone="${esc(r.stateTone)}"></span><span>${esc(r.state)}</span></span>
      <span role="cell">${r.action ? `<button class="btn xs subtle" type="button" data-row-action="${esc(r.action.id)}" data-arg="${esc(r.action.argument ?? '')}">${esc(r.action.label)}</button>` : ''}</span></div>`).join(''));
    for (const usage of ['remote', 'secrets']) paintSecondary(s[usage], usage);
    paintTrial(s);
    const temporaries = s.memory.filter((m) => m.key.startsWith('temporary:')).length;
    zone('mem-sub').textContent = `Durée par défaut${NBSP}: ${formatNumber(s.lease.defaultMinutes)}${NBSP}min sans utilisation (de ${formatNumber(s.lease.minMinutes)} à ${formatNumber(s.lease.maxMinutes)})${NBSP}; un affichage ne prolonge jamais un compte`;
    const forgetAll = panel.querySelector('[data-forget-all]');
    forgetAll.disabled = temporaries === 0 || busy > 0;
    if (temporaries) delete forgetAll.dataset.tip; else forgetAll.dataset.tip = 'Aucun compte temporaire en mémoire.';
    paint('memory', memoryList(s));
    painted.delete('foot');
    zone('foot').innerHTML = `${glyph('info')}<span>${esc(s.summary)} Un compte accepté après un refus ne sert qu’à sa ressource (et à son poste)${NBSP}; aucune écriture n’est jamais rejouée.</span>`;
    panel.querySelector('.cpt-acces')?.removeAttribute('aria-busy');
    unbindCopy = bindCopy(panel);
  }

  function pendingCard(s) {
    // The oldest access is the one « Accès » of Domenia 1 opened first: its button is the main action of the tab.
    return `<section class="card cpt-pending reveal in" aria-labelledby="cpt-pending-t">
      <div class="card-head"><span class="card-icon">${glyph('bell')}</span><div class="cpt-head-titles"><h3 id="cpt-pending-t">Accès à revoir</h3>
        <span>${esc(plural(s.pending.length, 'accès refusé', 'accès refusés'))} · ${formatNumber(s.pendingLimit)} au plus, un par ressource et cible${NBSP}; les autres fonctions restent disponibles</span></div>
        <span class="meta">${pill('warn', formatNumber(s.pending.length), { icon: 'bell', size: 'sm' })}</span></div>
      <ul class="cpt-pending-list">${s.pending.map((p, n) => `<li data-req="${esc(p.id)}">
        <span class="cpt-pending-ico">${glyph(resourceIcon(p.scope))}</span>
        <span class="cpt-pending-main"><b>${esc(p.operation)}</b><span>${esc(p.scopeLabel)}${p.target ? ` · <span class="mono">${esc(p.target)}</span>` : ''} · ${esc(p.kindLabel)}</span></span>
        <span class="cpt-pending-when">${relSpan(p.at)}</span>
        <span class="cpt-pending-actions"><button class="btn sm subtle" type="button" data-dismiss="${esc(p.id)}">Garder le compte actuel</button>
          <button class="btn sm${n === 0 ? ' primary' : ''}" type="button" data-recover="${esc(p.id)}">${glyph('user')}Utiliser un autre compte…</button></span></li>`).join('')}</ul>
    </section>`;
  }

  function connectionFacts(c) {
    const modePill = c.mode === 'demo' ? pill('accent', c.modeLabel, { icon: 'sparkles', size: 'sm' }) : pill('info', c.modeLabel, { icon: c.mode === 'windows' ? 'monitor' : 'key', size: 'sm' });
    return `<div class="card-head"><span class="card-icon">${glyph('user')}</span><div class="cpt-head-titles"><h3 id="cpt-conn-t">Compte de connexion</h3><span>Identité réellement liée à l’annuaire, en lecture seule</span></div><span class="meta">${modePill}</span></div>
      <div class="cpt-conn-id"><span class="cpt-conn-ring" aria-hidden="true">${glyph('shield')}</span>
        <div><b class="mono">${esc(c.identity)}</b>${c.connected ? copyButton(c.identity, { label: 'Copier l’identité', done: 'Copiée' }) : ''}<span>${esc(c.connected ? (c.displayName ?? '') : c.detail)}</span></div></div>
      <dl class="cpt-conn-facts">
        <div><dt>Contrôleur</dt><dd>${esc(c.controller ?? '—')}${c.site ? `<span>Site ${esc(c.site)}</span>` : ''}</dd></div>
        <div><dt>Domaine</dt><dd>${esc(c.domain ?? '—')}${c.netbios ? `<span>NetBIOS ${esc(c.netbios)}</span>` : ''}</dd></div>
        <div><dt>Authentification</dt><dd>${esc(c.authentication)}</dd></div>
        <div><dt>Connecté</dt><dd>${c.since ? relSpan(c.since, { prefix: '' }) : '—'}${c.since ? `<span>${esc(when(c.since) ?? '')}</span>` : ''}</dd></div>
      </dl>`;
  }

  function paintSecondary(acc, usage) {
    paint(`${usage}-pill`, pill(acc.statusTone, acc.active ? 'Actif' : 'Non défini', { icon: acc.active ? 'check' : 'info', size: 'sm' }));
    const status = zone(`${usage}-status`);
    status.dataset.tone = acc.statusTone;
    status.innerHTML = `${acc.active ? `<b class="mono">${esc(acc.account)}</b> · activé ${relSpan(acc.activatedAt)}${acc.controller ? ` · validé par ${esc(acc.controller)}` : ''}<br>` : ''}${esc(acc.status)}`;
    paint(`${usage}-remembered`, acc.remembered
      ? `<div class="cpt-remembered">${glyph('pin')}<span>Identifiant mémorisé${NBSP}: <b class="mono">${esc(acc.remembered.account)}</b> · utilisé ${relSpan(acc.remembered.lastUsedAt)}</span>
          <button class="btn xs subtle" type="button" data-forget-remembered="${usage}">Oublier</button></div>` : '');
    paint(`${usage}-clear`, acc.active ? `<button class="btn subtle" type="button" data-clear="${usage}"${busy ? ' disabled' : ''}>${glyph('x')}Effacer</button>` : '');
    // The identifier is prefilled (active account, else the remembered one) only if the operator has not typed in it.
    prefill(`cpt-${usage}-login`, acc.account ?? acc.remembered?.account ?? '');
  }

  function paintTrial(s) {
    prefill('cpt-trial-pc', s.lastTrial?.computer ?? '', { onlyIfEmpty: true });
    const box = out('trial');
    // The last trial is drawn once per trial (a fresh one replaces it), never repainted for nothing.
    if (box && s.lastTrial && !box.querySelector('.cpt-validating') && box.dataset.trialAt !== s.lastTrial.at) {
      box.innerHTML = trialMarkup(s.lastTrial);
      box.dataset.trialAt = s.lastTrial.at;
    }
  }

  function prefill(id, value, { onlyIfEmpty = false } = {}) {
    const input = panel.querySelector(`#${id}`);
    if (!input) return;
    if (!mayPrefill({ value: input.value, dirty: dirty.has(id), focused: document.activeElement === input })) return;
    if (onlyIfEmpty && input.value) return;
    if (input.value !== value) input.value = value;
  }

  function setFormEnabled(name, on, reason) {
    const form = panel.querySelector(`[data-form="${name}"]`);
    if (!form || busy) return;
    form.querySelectorAll('input, button').forEach((el) => { el.disabled = !on; });
    const submit = form.querySelector('[type="submit"]');
    if (submit) { if (on) delete submit.dataset.tip; else submit.dataset.tip = reason ?? ''; }
  }

  function trialMarkup(t) {
    return `<div class="cpt-result" data-tone="${esc(t.tone)}">${glyph(t.success ? 'check' : 'alert')}<div><b>${esc(t.text)}</b>
      <span>Compte${NBSP}: <span class="mono">${esc(t.account)}</span> (${esc(t.origin)}) · ${esc(when(t.at) ?? '')}${t.simulated ? ' · poste fictif' : ''}</span></div></div>`;
  }

  function memoryList(s) {
    return s.memory.length ? `<ul class="cpt-mem-list">${s.memory.map((m) => `<li data-tone="${esc(m.stateTone)}">
        <span class="cpt-mem-ico">${glyph(m.key.startsWith('secondary:') ? 'pin' : 'clock')}</span>
        <span class="cpt-mem-main"><b>${esc(m.resource)}</b><span class="mono">${esc(m.account)}</span></span>
        <span class="cpt-mem-left">${m.minutes > 0 ? pill(m.minutes <= 5 ? 'warn' : 'info', `${formatNumber(m.minutes)}${NBSP}min`, { icon: 'clock', size: 'sm' }) : ''}<span>${esc(m.remaining)}</span></span>
        <span class="cpt-mem-state"><span class="dot" data-tone="${esc(m.stateTone)}"></span>${esc(m.state)}</span>
        <button class="btn xs subtle" type="button" data-forget="${esc(m.key)}" data-tip="Rend la main au compte configuré et efface les refus liés">Oublier</button></li>`).join('')}</ul>`
      : `<p class="cpt-mem-empty">${glyph('check')}Aucun compte temporaire ni secondaire en mémoire${NBSP}: toutes les ressources utilisent le compte de connexion.</p>`;
  }

  // ---------------------------------------------------------------- actions

  /** Opens « Utiliser un autre compte » for a request (the oldest one when it is gone), now or once the state is read. */
  function openRequest(id) {
    if (!state) { wantedRequest = id ?? 'premier'; return; }
    const req = state.pending.find((p) => p.id === id) ?? state.pending[0];
    if (req) recover(req); else toast('Aucun accès à revoir.', { tone: 'info' });
  }

  function openFromParams(s) {
    if (wantedRequest) {
      const id = wantedRequest;
      wantedRequest = null;
      openRequest(id);
    }
    if (page.params.corriger === 'connexion' && !focusedCorrection) {
      focusedCorrection = true;
      const field = panel.querySelector('#cpt-correct-pwd');
      panel.querySelector('.cpt-conn').classList.add('flash');
      field?.scrollIntoView({ block: 'center' });
      field?.focus({ preventScroll: true });
      announce(`Compte de connexion refusé${NBSP}: saisissez son mot de passe actuel puis «${NBSP}Corriger le mot de passe${NBSP}», ou «${NBSP}Changer de compte${NBSP}».`);
    }
    if (page.params.acces && !panel.dataset.opened) {
      panel.dataset.opened = '1';
      const req = s.pending.find((p) => p.id === page.params.acces) ?? (page.params.acces === 'premier' ? s.pending[0] : null);
      if (req) recover(req);
    }
    if (page.params['compte-connexion'] === 'changer' && !panel.dataset.relogin) {
      panel.dataset.relogin = '1';
      if (s.connection.relogin.available) relogin(); else toast(s.connection.relogin.reason ?? '', { tone: 'info', life: 6000 });
    }
  }

  /** Runs a validation of this tab: every form of the page is occupied meanwhile (CPT-021), « Annuler » stops it. */
  async function guarded(name, label, run) {
    const box = out(name);
    const controls = [...panel.querySelectorAll('form button, form input')];
    if (box) box.innerHTML = progressMarkup(label);
    const before = controls.map((el) => el.disabled);
    controls.forEach((el) => { el.disabled = true; });
    busy += 1;
    box?.querySelector('[data-cancel-validation]')?.addEventListener('click', () => ctx.call('accounts.access.cancel').catch((err) => console.error(err)));
    try {
      return await run();
    } catch (err) {
      console.error(err);
      if (box?.isConnected) box.innerHTML = errorMarkup(err);
      return null;
    } finally {
      busy -= 1;
      controls.forEach((el, n) => { if (el.isConnected) el.disabled = before[n]; });
      if (state && alive) update(state);
    }
  }

  async function secondary(usage, activate) {
    const form = panel.querySelector(`[data-form="${usage}"]`);
    const loginInput = form.querySelector(`#cpt-${usage}-login`);
    const secret = form.querySelector('[data-secret]');
    const login = loginInput.value.trim();
    if (!login || (!nativeEntry() && !secret?.value)) { toast('Saisissez l’identifiant et le mot de passe.', { tone: 'warn' }); (login ? secret : loginInput)?.focus(); return; }
    const password = secret?.value;
    if (secret) secret.value = '';
    peek?.hideAll();
    const result = await guarded(usage, activate ? 'Validation puis activation…' : 'Validation du compte…', () => credentialCall(activate ? 'accounts.access.activate' : 'accounts.access.test', { usage, login, password }));
    if (!result || !alive) return;
    if (activate) {
      if (result.result.success) dirty.delete(`cpt-${usage}-login`);
      apply(result.state);
      out(usage).innerHTML = resultMarkup(result.result);
      toast(result.result.success ? `${result.state[usage].label} activé${NBSP}: ${result.result.identity}.` : result.result.message, { tone: result.result.success ? 'ok' : 'alert' });
      accessChanged();
    } else {
      out(usage).innerHTML = resultMarkup(result);
      announce(result.message);
    }
  }

  function wire() {
    const root = panel.querySelector('.cpt-acces');
    root.addEventListener('click', async (e) => {
      const t = e.target instanceof Element ? e.target.closest('button') : null;
      if (!t || t.disabled) return;
      if (t.dataset.vaultForget) { await forgetVault(t.dataset.vaultForget); }
      else if (t.dataset.recover) recover(state.pending.find((p) => p.id === t.dataset.recover));
      else if (t.dataset.dismiss) run(() => ctx.call('accounts.access.dismiss', { id: t.dataset.dismiss }), 'Compte actuel conservé.');
      else if (t.dataset.test) secondary(t.dataset.test, false);
      else if (t.dataset.clear) run(() => ctx.call('accounts.access.clear', { usage: t.dataset.clear }), 'Retour au compte de connexion.');
      else if (t.dataset.forget) run(() => ctx.call('accounts.access.forget', { key: t.dataset.forget }), 'Compte oublié, refus liés effacés.');
      else if (t.dataset.forgetAll !== undefined) forgetAll();
      else if (t.dataset.forgetRemembered) {
        dirty.delete(`cpt-${t.dataset.forgetRemembered}-login`);
        run(() => ctx.call('accounts.remembered.forget', { usage: t.dataset.forgetRemembered }), 'Identifiant oublié.');
      } else if (t.dataset.relogin !== undefined) {
        if (t.getAttribute('aria-disabled') === 'true') toast(state.connection.relogin.reason ?? '', { tone: 'info', life: 6000 }); else relogin();
      } else if (t.dataset.rowAction) rowAction(t.dataset.rowAction, t.dataset.arg);
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
      apply(next);
      toast(done, { tone: 'ok', life: 2600 });
      accessChanged();
    } catch (err) {
      console.error(err);
      toast(errorSentence(err), { tone: 'alert' });
    }
  }

  async function forgetVault(usage) {
    const initial = usage === 'directory' ? state.connection.identity : panel.querySelector(`#cpt-${usage}-login`)?.value.trim();
    const body = document.createElement('div');
    body.innerHTML = `<p>Supprime uniquement les entrées de ce compte pour ${usage === 'directory' ? 'la connexion annuaire' : usage === 'remote' ? 'les postes' : 'LAPS et BitLocker'}. Le compte en mémoire reste actif.</p>
      <div class="k-field"><label for="cpt-vault-account">Identifiant exact mémorisé</label><input id="cpt-vault-account" class="input mono" type="text" spellcheck="false" maxlength="256" value="${esc(initial ?? '')}"><p class="k-hint">Les formes DOMAINE\\compte et compte@domaine ont chacune leur entrée.</p></div>
      ${usage === 'remote' ? '<div class="k-field"><label for="cpt-vault-target">Poste (pour un compte local)</label><input id="cpt-vault-target" class="input mono" type="text" maxlength="253"></div>' : ''}
      <div role="status" data-vault-result></div>`;
    const drawer = openDrawer({ title: 'Oublier dans le coffre Windows', icon: 'key', key: 'accounts-vault-forget', width: 480, body,
      actions: [{ id: 'cancel', label: 'Annuler', run: (p) => p.close() }, { id: 'forget', label: 'Oublier dans le coffre', icon: 'trash', run: async () => {
        const login = body.querySelector('#cpt-vault-account').value.trim();
        const target = body.querySelector('#cpt-vault-target')?.value.trim() || null;
        if (!login) { body.querySelector('#cpt-vault-account').focus(); return; }
        drawer.setBusy(true);
        try {
          const receipt = await ctx.call('accounts.vault.delete', { usage, login, target });
          body.querySelector('[data-vault-result]').textContent = receipt.message;
          toast(receipt.message, { tone: receipt.complete ? 'ok' : 'warn' });
          if (receipt.complete) drawer.close();
        } catch (error) { body.querySelector('[data-vault-result]').textContent = errorSentence(error); }
        finally { drawer.setBusy(false); }
      } }],
    });
  }

  /** « Tout oublier » (CPT-005): asks first, like Domenia 1 (safeguard « Confirmation »). */
  async function forgetAll() {
    const temporaries = state.memory.filter((m) => m.key.startsWith('temporary:'));
    if (!temporaries.length) return;
    const ok = await confirmDialog({
      title: `Oublier tous les comptes temporaires${NBSP}?`,
      message: `${plural(temporaries.length, 'compte temporaire sera oublié', 'comptes temporaires seront oubliés')} avec les refus liés${NBSP}: ${temporaries.map((m) => m.account).join(', ')}. Les ressources reprennent le compte configuré${NBSP}; une opération déjà partie garde sa copie et n’est pas interrompue. Les comptes Postes et Secrets restent.`,
      confirmLabel: 'Tout oublier',
      danger: true,
    });
    if (!ok || !alive) return;
    run(() => ctx.call('accounts.access.forgetAll'), 'Comptes temporaires oubliés, refus liés effacés.');
  }

  function rowAction(id, arg) {
    const focus = (sel) => { const f = panel.querySelector(sel); f?.scrollIntoView({ block: 'center', behavior: 'smooth' }); f?.focus({ preventScroll: true }); };
    if (id === 'recover') recover(state.pending.find((p) => p.id === arg));
    else if (id === 'forget') run(() => ctx.call('accounts.access.forget', { key: arg }), 'Compte oublié, refus liés effacés.');
    else if (id === 'correct') focus('#cpt-correct-pwd');
    else if (id === 'try') focus('#cpt-trial-pc');
    else if (id === 'activate') focus(`#cpt-${arg}-login`);
  }

  async function correct(form) {
    const secret = form.querySelector('[data-secret]');
    if (!nativeEntry() && !secret?.value) { secret?.focus(); return; }
    const password = secret?.value;
    if (secret) secret.value = '';
    peek?.hideAll();
    const r = await guarded('correct', 'Validation du même compte…', () => credentialCall('accounts.connection.correct', { password }));
    if (r && alive) {
      out('correct').innerHTML = resultMarkup(r);
      if (r.success) { refresh(); accessChanged(); }
    }
  }

  async function trial(form) {
    const input = form.querySelector('#cpt-trial-pc');
    const computer = input.value.trim();
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$/.test(computer)) { toast('Saisissez un nom de poste valide.', { tone: 'warn' }); input.focus(); return; }
    const box = out('trial');
    box.innerHTML = `<div class="cpt-validating" role="status"><span class="cpt-validating-bar" aria-hidden="true"><i></i></span><span>Lecture légère de ${esc(computer)}…</span></div>`;
    const submit = form.querySelector('[type="submit"]');
    submit.disabled = true;
    try {
      const t = await ctx.call('accounts.access.tryRemote', { computer });
      if (!alive) return;
      box.innerHTML = trialMarkup(t);
      box.dataset.trialAt = t.at;
      announce(t.text);
    } catch (err) {
      console.error(err);
      if (box.isConnected) box.innerHTML = errorMarkup(err);
    } finally {
      if (submit.isConnected) submit.disabled = false;
    }
  }

  /** A drawer with a login (prefilled), a password and its reveal, wired to one submit. */
  function credentialDrawer({ title, subtitle, icon, key, ids, intro, login, loginPlaceholder, extra = '', okLabel, cancelLabel = 'Annuler', onSubmit }) {
    const body = document.createElement('div');
    body.className = 'cpt-recover';
    body.dataset.page = 'comptes';
    body.innerHTML = `${intro}
      <form class="cpt-recover-form" novalidate autocomplete="off">
        <div class="k-field"><label for="${ids}-login">Compte</label><input class="input mono" id="${ids}-login" type="text" spellcheck="false" maxlength="260" placeholder="${esc(loginPlaceholder)}" value="${esc(login ?? '')}"></div>
        ${passwordField(`${ids}-pwd`, 'Mot de passe')}
        ${extra}
      </form>
      <div class="cpt-form-out" data-drw-out></div>`;
    const drawer = openDrawer({
      title, subtitle, icon, key, width: 520, body, focusFirst: true,
      actions: [
        { id: 'cancel', label: cancelLabel, run: (p) => p.close() },
        { id: 'ok', label: okLabel, icon: 'check', primary: true, run: () => submit() },
      ],
    });
    let drawerPeek = null;
    whenOpen(drawer).then((opened) => {
      if (!opened) return;
      drawerPeek = bindReveal(body, { seconds: state?.revealSeconds || 5 });
      body.querySelector('form').addEventListener('submit', (e) => { e.preventDefault(); submit(); });
      // A prefilled account: the cursor goes to the password.
      body.querySelector(login ? `#${ids}-pwd` : `#${ids}-login`)?.focus();
    });
    drawer.closed?.then(() => drawerPeek?.destroy());
    async function submit() {
      const loginInput = body.querySelector(`#${ids}-login`);
      const secret = body.querySelector(`#${ids}-pwd`);
      const value = loginInput.value.trim();
      if (!value || (!nativeEntry() && !secret?.value)) { (value ? secret : loginInput)?.focus(); return; }
      const password = nativeEntry() ? undefined : secret.value;
      if (!nativeEntry()) secret.value = '';
      drawerPeek?.hideAll();
      const box = body.querySelector('[data-drw-out]');
      box.innerHTML = progressMarkup('Validation du compte proposé…');
      box.querySelector('[data-cancel-validation]').addEventListener('click', () => ctx.call('accounts.access.cancel').catch((err) => console.error(err)));
      drawer.setBusy(true);
      try {
        await onSubmit({ login: value, password, body, box, drawer });
      } catch (err) {
        // A refused context (local account for the directory…) is an answer shown in the panel, not a fault.
        if (err?.code !== 'accounts.credentialContext') console.error(err);
        if (body.isConnected) box.innerHTML = errorMarkup(err);
      } finally {
        drawer.setBusy(false);
      }
    }
    return drawer;
  }

  /** « Utiliser un autre compte » (CPT-002): context, lease and one validation; the remembered identifier is proposed. */
  function recover(req) {
    if (!req) return;
    const remote = req.scope === 'Remote';
    credentialDrawer({
      title: 'Utiliser un autre compte',
      subtitle: req.scopeLabel,
      icon: 'user',
      key: 'comptes.recover',
      ids: 'cpt-rec',
      login: req.remembered ?? '',
      loginPlaceholder: remote ? 'DOMAINE\\compte, POSTE\\compte ou .\\compte' : 'DOMAINE\\compte ou compte@domaine',
      okLabel: 'Valider et utiliser',
      cancelLabel: 'Garder le compte actuel',
      intro: `<div class="cpt-recover-head" data-tone="warn">${glyph(resourceIcon(req.scope))}<div><b>${esc(req.operation)}</b>
          <span>${esc(req.scopeLabel)}${req.target ? ` · ${esc(req.target)}` : ''} · ${esc(req.kindLabel)} · ${esc(when(req.at) ?? '')}</span></div></div>
        <p>Le compte proposé ne servira qu’à cette ressource${remote ? ' et à ce poste' : ''}. Les autres fonctions restent disponibles${NBSP}; aucune écriture n’est rejouée${NBSP}: relancez l’action vous-même ensuite.</p>
        ${req.remembered ? `<p class="cpt-small cpt-muted">${glyph('pin')}Identifiant mémorisé pour cette ressource, proposé${NBSP}; le mot de passe n’est jamais conservé.</p>` : ''}`,
      extra: `${remote ? `<div class="k-field"><label for="cpt-rec-target">Poste</label><input class="input mono" id="cpt-rec-target" type="text" maxlength="253" spellcheck="false" value="${esc(req.target ?? '')}"><p class="k-hint">«${NBSP}.\\compte${NBSP}» est complété par ce nom de poste.</p></div>` : ''}
        <fieldset class="k-field cpt-lease"><legend>Durée en mémoire</legend>
          <label class="k-check-row"><input class="k-radio" type="radio" name="lease" value="inactivity" checked><span>Tant qu’il sert${NBSP}: oublié après</span>
            <input class="input cpt-lease-min" type="number" min="${state.lease.minMinutes}" max="${state.lease.maxMinutes}" value="${state.lease.defaultMinutes}" aria-label="Minutes sans utilisation"><span>min sans utilisation</span></label>
          <label class="k-check-row"><input class="k-radio" type="radio" name="lease" value="session"><span>Jusqu’à la fin de la session</span></label>
          <label class="k-check-row"><input class="k-radio" type="radio" name="lease" value="once"><span>Une seule utilisation</span></label>
        </fieldset>`,
      onSubmit: async ({ login, password, body, box, drawer }) => {
        const target = remote ? (body.querySelector('#cpt-rec-target').value.trim() || null) : null;
        const lease = body.querySelector('input[name="lease"]:checked')?.value ?? 'inactivity';
        const minutes = Number(body.querySelector('.cpt-lease-min').value) || state.lease.defaultMinutes;
        const r = await credentialCall('accounts.access.recover', { id: req.id, login, password, lease, minutes: Math.min(state.lease.maxMinutes, Math.max(state.lease.minMinutes, minutes)), target });
        if (alive) apply(r.state);
        if (r.result.success) {
          toast(`Compte validé et gardé pour ${req.scopeLabel}${NBSP}: relancez l’action vous-même.`, { tone: 'ok', life: 6000 });
          accessChanged();
          drawer.close();
        } else if (body.isConnected) {
          box.innerHTML = resultMarkup(r.result);
        }
      },
    });
  }

  /**
   * « Changer de compte » (CPT-007): the form is prefilled with the current account; one validation opens the new session;
   * the accounts, accesses, pauses and refusals of the former session are forgotten and the views read again. Refused while a
   * write waits for its re-read. Nothing is replayed.
   */
  function relogin() {
    const c = state.connection;
    credentialDrawer({
      title: 'Changer de compte',
      subtitle: c.domain ? `Domaine ${c.domain}` : 'Nouvelle session',
      icon: 'refresh',
      key: 'comptes.relogin',
      ids: 'cpt-relogin',
      login: c.connected ? c.identity : '',
      loginPlaceholder: 'DOMAINE\\compte ou compte@domaine',
      okLabel: 'Ouvrir la session',
      intro: `<div class="cpt-recover-head" data-tone="info">${glyph('user')}<div><b>Session actuelle${NBSP}: ${esc(c.identity)}</b>
          <span>${esc(c.detail)}</span></div></div>
        <ul class="cpt-relogin-effects">
          <li>${glyph('check')}<span>Une seule validation du compte proposé, sur le contrôleur de la session${NBSP}; même domaine.</span></li>
          <li>${glyph('trash')}<span>Comptes Postes, Secrets et temporaires, accès à revoir, pauses et refus de la session actuelle sont oubliés.</span></li>
          <li>${glyph('refresh')}<span>Les vues sont relues pour la nouvelle session${NBSP}; rien n’est rejoué, aucune écriture ne repart.</span></li>
        </ul>
        ${state.validation?.busy ? `<p class="cpt-reason">${glyph('info')}Une validation est en cours${NBSP}: attendez son résultat.</p>` : ''}`,
      onSubmit: async ({ login, password, box, body, drawer }) => {
        const r = await credentialCall('accounts.connection.switch', { login, password });
        if (!r.result.success) { if (body.isConnected) box.innerHTML = resultMarkup(r.result); return; }
        toast(`${r.result.message} ${r.result.hint ?? ''}`.trim(), { tone: 'ok', life: 7000 });
        drawer.close();
        dirty.clear();
        accessChanged();
        // The views follow the new session: the screen reads its chips and its list again (and the shell, when it listens).
        window.dispatchEvent(new CustomEvent('domenia:session-changed'));
        await refresh();
      },
    });
  }

  refresh();
  timer = setInterval(poll, POLL_MS);
  return {
    refresh,
    openRequest,
    destroy: () => { alive = false; clearInterval(timer); unbindCopy(); peek?.destroy(); },
  };
}
