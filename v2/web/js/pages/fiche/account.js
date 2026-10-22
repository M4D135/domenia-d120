// Account tab: state (FIC-043, FIC-013), lockout and the 4740 journal (FIC-012, FIC-040, FIC-045), password (FIC-017,
// FIC-014, FIC-050), account expiry (FIC-016), security options of userAccountControl (FIC-015) and the exact logon on each
// controller (FIC-042). Computers: state, machine password, logons and LAPS date. Every write goes through the circuit; the new
// password of a reset is typed or generated in the secure window of the host (SecureString), never in this page.
import { glyph, pill, writeClipboard, startFreshness, NBSP, int } from '../../kit/index.js';
import { esc, errorText, toast, announce, applyVars } from '../../ui.js';
import { write } from './actions.js';
import { card, failure, factRows, skeleton, when, emptyNote, freshChip, stamp, nobr } from './common.js';

const HOURS = [{ v: 24, l: '24 h' }, { v: 72, l: '3 jours' }, { v: 168, l: '7 jours' }, { v: 720, l: '30 jours' }];

/**
 * @param {HTMLElement} panel
 * @param {any} S
 */
export function mountAccount(panel, S) {
  let lockoutsResult = null;
  let logonResult = null;
  let resetOpen = false;
  let hours = 168;

  const act = (id) => S.sheet.actions.find((a) => a.id === id);
  const button = (id, label, icon, { cls = '', primary = false, danger = false, net = false } = {}) => {
    const a = act(id);
    if (!a) return '';
    const off = !a.available;
    return `<button class="btn sm${primary ? ' primary' : ''}${danger ? ' danger' : ''}${net ? ' fi-net' : ''}${a.kind === 'write' ? ' fi-write' : ''} ${cls}" type="button" data-acc="${esc(id)}"${off ? ` aria-disabled="true" data-tip="${esc(a.reason ?? '')}"` : ''}>${glyph(icon)}${esc(label ?? a.label)}</button>`;
  };

  function stateCard(sheet) {
    const a = sheet.account;
    const disabled = a.disabled === true;
    return card({
      id: 'state', icon: 'shield', tone: disabled ? 'alert' : 'ok', title: 'État du compte', sub: a.stateLabel, fresh: freshChip(sheet, 'attributes'),
      body: `<div class="fi-bigstate" data-on="${disabled ? 'false' : 'true'}"><span class="fi-bigstate-ico">${glyph(disabled ? 'power' : 'check')}</span>
          <div><b>${disabled ? 'Désactivé' : 'Activé'}</b><p>${disabled ? 'Le compte ne peut pas ouvrir de session.' : 'Le compte peut ouvrir une session.'}</p></div></div>
        <dl class="fi-mini"><div><dt>Options (userAccountControl)</dt><dd>${esc(a.uacLabel)}</dd></div>
          <div><dt>Valeur brute</dt><dd class="mono">${a.uac != null ? esc(String(a.uac)) : '—'}</dd></div>
          ${a.protected ? `<div><dt>Protection</dt><dd>${pill('accent', 'adminCount = 1', { size: 'sm' })} Objet protégé par AdminSDHolder</dd></div>` : ''}</dl>`,
      foot: disabled ? button('enable', 'Activer le compte…', 'power', { primary: true }) : button('disable', 'Désactiver le compte…', 'power', { danger: true }),
    });
  }

  function lockCard(sheet) {
    const a = sheet.account;
    const tone = a.lock === 'locked' ? 'alert' : a.lock === 'toCheck' ? 'warn' : 'ok';
    const select = `<label class="fi-inline-select">Fenêtre<select class="input" data-hours>${HOURS.map((h) => `<option value="${h.v}"${h.v === hours ? ' selected' : ''}>${esc(h.l)}</option>`).join('')}</select></label>`;
    const state = lockoutsResult?.loading ? `<p class="fi-lock-reading" aria-busy="true">${glyph('history')}Lecture du journal Sécurité de l’émulateur PDC…</p>`
      : lockoutsResult?.data ? `<p class="fi-lock-reading done">${glyph('check')}Journal lu le ${esc(stamp(lockoutsResult.data.readAt))}${NBSP}: le détail suit, sur toute la largeur.</p>` : '';
    return card({
      id: 'lockouts', icon: 'lock', tone, title: 'Verrouillage', sub: a.lockLabel,
      meta: a.badPasswordCount ? pill('warn', `${int(a.badPasswordCount)} essai${a.badPasswordCount > 1 ? 's' : ''} erroné${a.badPasswordCount > 1 ? 's' : ''}`, { size: 'sm' }) : '',
      body: `<dl class="fi-mini">
          <div><dt>État calculé</dt><dd>${esc(a.lockLabel)}</dd></div>
          <div><dt>Dernier verrouillage</dt><dd>${a.lockedAt ? when(a.lockedAt) : '—'}</dd></div>
          <div><dt>Échecs de mot de passe</dt><dd>${a.badPasswordCount != null ? esc(String(a.badPasswordCount)) : '—'}${a.badPasswordAt ? ` · dernier ${when(a.badPasswordAt)}` : ''}</dd></div></dl>
        <p class="fi-note">${glyph('info')}Compteur propre au contrôleur interrogé${NBSP}: il n’est pas répliqué. Le journal 4740 dit quel poste a provoqué un verrouillage${NBSP}; Domenia y rapproche ses propres refus d’authentification juste avant (piste à vérifier, jamais une preuve).</p>
        ${state}`,
      // The unlock stays the primary command of the header: here it is a contextual button, never a second primary.
      foot: `${select}${button('lockouts', 'Lire les verrouillages (4740)', 'history', { net: true })}${a.lock === 'locked' ? button('unlock', 'Déverrouiller…', 'lock', { cls: 'fi-push' }) : ''}`,
    });
  }

  /** Result of the 4740 read, on the whole width (the card above keeps the state and the buttons): events and journal facts. */
  function lockoutsCard() {
    if (!lockoutsResult || lockoutsResult.loading) return '';
    const body = lockoutsResult.error ? failure(lockoutsResult.error, { title: 'Lecture du journal non aboutie' }) : lockoutsMarkup(lockoutsResult.data);
    return `<div class="fi-wide">${card({ id: 'lockoutsResult', icon: 'history', title: 'Journal des verrouillages (4740)', sub: 'Événements du seul SID du compte, lus sur l’émulateur PDC', body })}</div>`;
  }

  function lockoutsMarkup(d) {
    // The controller is the same for every event (the PDC emulator, said in the head): it stays in the tip of the row.
    const rows = d.rows.length ? `<div class="fi-table-wrap"><table class="fi-table"><thead><tr><th>Heure</th><th>Poste à l’origine</th><th>Refus de Domenia</th></tr></thead><tbody>
      ${d.rows.map((r, n) => `<tr data-j="${n}" data-tip="${esc(`Contrôleur${NBSP}: ${r.controller}`)}"><td class="mono">${esc(r.local)}</td><td><b class="fi-nobr">${esc(r.computer)}</b></td>
        <td>${r.domeniaNear ? pill('warn', r.domenia, { size: 'sm', icon: 'alert' }) : `<span class="fi-faint">${esc(r.domenia)}</span>`}</td></tr>`).join('')}</tbody></table></div>`
      : emptyNote('check', 'Aucun verrouillage dans la fenêtre lue', 'Absence dans la fenêtre lue seulement : un journal recyclé peut ne plus contenir les événements anciens.');
    return `<div class="fi-result fi-enter"><div class="fi-result-head">${pill(d.state === 'read' ? 'info' : 'alert', d.state === 'read' ? `Journal lu sur ${d.controller}` : 'Lecture non aboutie', { size: 'sm', icon: 'server' })}
        <span class="fi-faint">${esc(stamp(d.readAt))} · ${esc(String(d.hours))}${NBSP}h${d.truncated ? ' · tronqué' : ''}</span>
        <button class="btn xs ghost" type="button" data-copy-report>${glyph('copy')}Copier le rapport</button></div>
      <div class="fi-lock-detail">${rows}${factRows(d.facts.filter((f) => f.group === 'Journal'))}</div></div>`;
  }

  function passwordCard(sheet) {
    const a = sheet.account;
    const settings = sheet.settings ?? {};
    const length = settings.passwordLength ?? 16;
    const reset = resetOpen ? `<div class="fi-reset fi-enter" role="group" aria-label="Réinitialisation du mot de passe">
        <p class="fi-reset-lead">${glyph('lock')}<span>Le nouveau mot de passe se saisit dans la <b>fenêtre sécurisée de Domenia</b>, hors de cette page${NBSP}: deux saisies que l’on peut révéler, ou un mot de passe généré de ${length}${NBSP}caractères (quatre classes, sans 0/O ni 1/l/I) affiché une fois pour être lu. Il reste en mémoire protégée jusqu’à l’écriture et n’apparaît ni dans la page, ni dans le plan, ni dans le reçu, ni dans le journal.</span></p>
        <label class="fi-switch"><input class="switch" type="checkbox" data-reset-opt="mustChange"${settings.forcePasswordChange === false ? '' : ' checked'}><span>Changement obligatoire à la prochaine ouverture de session${settings.forcePasswordChange === false ? '' : ' <span class="fi-faint">(Security.ForcePasswordChangeOnReset)</span>'}</span></label>
        <label class="fi-switch"><input class="switch" type="checkbox" data-reset-opt="unlock"${a.lock === 'locked' ? ' checked' : ''}><span>Déverrouiller ensuite</span></label>
        <div class="fi-reset-actions"><button class="btn sm ghost" type="button" data-acc="resetClose">Fermer</button>
          <button class="btn sm fi-write" type="button" data-acc="resetGenerate">${glyph('sparkles')}Générer un mot de passe…</button>
          <button class="btn sm danger fi-write" type="button" data-acc="resetType">${glyph('key')}Saisir le mot de passe…</button></div></div>` : '';
    return card({
      id: 'password', icon: 'key', tone: a.passwordTone === 'alert' ? 'alert' : a.passwordTone === 'warn' ? 'warn' : 'ok', title: 'Mot de passe', sub: a.passwordLabel,
      body: `<dl class="fi-mini">
          <div><dt>Dernier changement</dt><dd>${a.passwordLastSet ? when(a.passwordLastSet) : a.mustChange ? 'À changer à la prochaine ouverture de session' : '—'}</dd></div>
          <div><dt>Expiration</dt><dd>${esc(a.passwordLabel)}</dd></div></dl>${reset}`,
      foot: resetOpen ? '' : `${button('expirePassword', 'Imposer un nouveau mot de passe…', 'key')}${button('resetPassword', 'Réinitialiser…', 'key', { danger: true })}`,
    });
  }

  function expiryCard(sheet) {
    const a = sheet.account;
    const avail = act('expiration');
    const off = avail && !avail.available ? ` aria-disabled="true" data-tip="${esc(avail.reason ?? '')}"` : '';
    return card({
      id: 'expiration', icon: 'calendar', tone: a.accountExpiresTone, title: 'Expiration du compte', sub: a.accountExpiresLabel,
      body: `<div class="fi-expiry"><label class="fi-field-label" for="fi-expiry-date">Le compte expire le</label>
        <input id="fi-expiry-date" class="input mono" type="text" inputmode="numeric" maxlength="10" autocomplete="off" spellcheck="false" placeholder="jj/mm/aaaa" aria-describedby="fi-expiry-hint" value="${esc(toFrench(a.accountExpires))}">
        <p id="fi-expiry-hint" class="fi-note">${glyph('info')}Format jj/mm/aaaa, à partir d’aujourd’hui. Comme Domenia 1, le compte cesse de fonctionner dès le début de ce jour (heure locale) ; la valeur est relue après l’écriture.</p></div>`,
      foot: `<button class="btn sm fi-write" type="button" data-acc="expirySet"${off}>${glyph('calendar')}Définir l’expiration…</button>
        <button class="btn sm ghost fi-write" type="button" data-acc="expiryNever"${off || (a.accountNeverExpires ? ' aria-disabled="true" data-tip="Le compte n’expire déjà jamais."' : '')}>${glyph('x')}Jamais…</button>`,
    });
  }

  function optionsCard(sheet) {
    const a = sheet.account;
    const main = a.options.filter((o) => !o.advanced);
    const advanced = a.options.filter((o) => o.advanced);
    const row = (o) => `<label class="fi-option${o.highRisk ? ' risky' : ''}" data-tip="${esc(o.detail)}"><input class="switch" type="checkbox" data-opt="${esc(o.id)}"${o.on ? ' checked' : ''}>
      <span class="fi-option-text"><span>${esc(o.label)}</span><span class="fi-option-detail">${esc(o.detail)}</span></span>${o.highRisk ? pill('alert', 'Risque élevé', { size: 'sm' }) : ''}</label>`;
    const avail = act('options');
    const off = avail && !avail.available ? ` aria-disabled="true" data-tip="${esc(avail.reason ?? '')}"` : '';
    return card({
      id: 'options', icon: 'sliders', title: 'Options de sécurité', sub: 'Seuls les bits changés partent',
      body: `<div class="fi-options">${main.map(row).join('')}</div>
        <details class="fi-advanced"${advanced.some((o) => o.on) ? ' open' : ''}><summary>${glyph('alert')}Options avancées<span class="fi-faint"> · activer l’une d’elles exige la saisie du nom</span></summary>
          <div class="fi-options">${advanced.map(row).join('')}</div></details>`,
      foot: `<span class="fi-opt-count fi-faint">Aucune option modifiée</span><button class="btn sm fi-write" type="button" data-acc="optionsGo" disabled${off}>${glyph('check')}Appliquer les options…</button>`,
    });
  }

  function logonCard(sheet) {
    let result = '';
    if (logonResult?.loading) result = skeleton(3);
    else if (logonResult?.error) result = failure(logonResult.error, { title: 'Lecture par contrôleur non aboutie' });
    else if (logonResult?.data) {
      const d = logonResult.data;
      result = `<div class="fi-result fi-enter"><div class="fi-dc-head">${pill(d.complete ? 'ok' : 'warn', `${d.readCount} contrôleur${d.readCount > 1 ? 's' : ''} lu${d.readCount > 1 ? 's' : ''} sur ${d.knownCount}`, { size: 'sm', icon: 'server' })}
          ${d.mostRecent ? `<span class="fi-dc-best">${glyph('clock')}<b>${esc(stamp(d.mostRecent))}</b> sur ${esc(d.mostRecentController ?? '')}</span>` : ''}
          ${d.logonCount != null ? pill('info', `${int(d.logonCount)} ouvertures (logonCount)`, { size: 'sm' }) : ''}</div>
        <div class="fi-table-wrap"><table class="fi-table"><thead><tr><th>Contrôleur</th><th>Type</th><th>État</th><th>Dernière connexion</th><th>logonCount</th></tr></thead><tbody>
          ${d.rows.map((r, n) => `<tr data-j="${n}"><td class="mono">${esc(r.controller)}</td><td>${esc(r.type)}</td><td>${pill(r.state === 'read' ? 'ok' : 'alert', r.state === 'read' ? 'Lu' : r.state === 'unavailable' ? 'Non joint' : r.state === 'refused' ? 'Refusé' : 'Non lu', { size: 'sm' })}</td>
            <td>${esc(r.value)}</td><td class="num">${r.logonCount != null ? int(r.logonCount) : '—'}</td></tr>`).join('')}</tbody></table></div>
        <p class="fi-note">${glyph('info')}${esc(d.text)} ${esc(d.interval.text)}</p></div>`;
    }
    return card({
      id: 'logonByDc', icon: 'server', title: 'Connexion sur chaque contrôleur', sub: 'lastLogon exact, propre à chaque contrôleur',
      body: `<p class="fi-logon-text">${esc(sheet.account.logon.text)}</p><div class="fi-dc">${result}</div>`,
      foot: button('logonByDc', 'Lire sur chaque contrôleur', 'server', { net: true }),
    });
  }

  function computerCards(sheet) {
    const a = sheet.account;
    const laps = sheet.sections.find((s) => s.id === 'gestion')?.items.find((i) => i.key === 'laps');
    return [
      stateCard(sheet),
      card({
        id: 'machine', icon: 'key', tone: a.passwordTone === 'warn' ? 'warn' : 'ok', title: 'Mot de passe machine', sub: 'Renouvelé automatiquement par le poste',
        body: `<p class="fi-logon-text">${nobr(a.passwordLabel)}</p>${laps ? `<dl class="fi-mini"><div><dt>LAPS</dt><dd>${esc(laps.value ?? '—')}</dd></div></dl><p class="fi-note">${glyph('shield')}${esc(laps.sub ?? '')}</p>` : ''}`,
        foot: button('openPoste', 'Ouvrir dans Poste', 'monitor'),
      }),
      logonCard(sheet),
    ].join('');
  }

  function render() {
    const sheet = S.sheet;
    if (!sheet.account) {
      panel.innerHTML = emptyNote('info', 'Aucun compte', 'Cet objet n’a pas de compte à gérer.');
      return;
    }
    if (sheet.identity.kind === 'computer') {
      panel.innerHTML = `<div class="fi-cards fi-cards-3">${computerCards(sheet)}</div>`;
    } else {
      // Cards paired row by row (equal heights), the journal of the lockouts on the whole width once read.
      panel.innerHTML = `<div class="fi-account">${stateCard(sheet)}${passwordCard(sheet)}${lockCard(sheet)}${expiryCard(sheet)}${lockoutsCard()}${logonCard(sheet)}${optionsCard(sheet)}</div>`;
    }
    panel.querySelectorAll('.fi-card').forEach((c, n) => { c.classList.add('fi-enter'); c.dataset.j = String(n); });
    applyVars(panel);
    startFreshness(panel);
  }

  function changedOptions() {
    const changed = {};
    for (const o of S.sheet.account?.options ?? []) {
      const box = /** @type {HTMLInputElement|null} */ (panel.querySelector(`[data-opt="${CSS.escape(o.id)}"]`));
      if (box && box.checked !== o.on) changed[o.id] = box.checked;
    }
    return changed;
  }

  function syncOptions() {
    const changed = Object.keys(changedOptions()).length;
    const go = /** @type {HTMLButtonElement|null} */ (panel.querySelector('[data-acc="optionsGo"]'));
    if (go && go.getAttribute('aria-disabled') !== 'true') go.disabled = changed === 0;
    const label = panel.querySelector('.fi-opt-count');
    if (label) label.textContent = changed ? `${changed} option${changed > 1 ? 's' : ''} modifiée${changed > 1 ? 's' : ''}` : 'Aucune option modifiée';
  }

  async function readLockouts() {
    lockoutsResult = { loading: true };
    render();
    try {
      const data = await S.ctx.call('fiche.lockouts', { dn: S.sheet.identity.dn, hours });
      lockoutsResult = { data };
      announce(data.recurrence ? `${data.recurrence} verrouillage${data.recurrence > 1 ? 's' : ''} lu${data.recurrence > 1 ? 's' : ''}.` : 'Aucun verrouillage dans la fenêtre lue.');
    } catch (err) {
      lockoutsResult = { error: err };
    }
    if (S.alive) render();
  }

  async function readLogons() {
    logonResult = { loading: true };
    render();
    try {
      logonResult = { data: await S.ctx.call('fiche.logonByDc', { dn: S.sheet.identity.dn }) };
    } catch (err) {
      logonResult = { error: err };
    }
    if (S.alive) render();
  }

  const subtitle = () => `${S.sheet.identity.kindLabel} · ${S.sheet.identity.name}`;
  const done = () => S.reload({ quiet: true, reread: true });

  const onClick = async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    if (t.closest('[data-copy-report]') && lockoutsResult?.data) {
      const ok = await writeClipboard(lockoutsResult.data.report);
      toast(ok ? 'Rapport copié.' : 'Copie impossible.', { tone: ok ? 'ok' : 'warn', life: 2600 });
      return;
    }
    if (t.closest('[data-retry]')) {
      if (t.closest('[data-card="lockouts"], [data-card="lockoutsResult"]')) readLockouts();
      else readLogons();
      return;
    }
    const b = t.closest('[data-acc]');
    if (!b) return;
    if (b.getAttribute('aria-disabled') === 'true') { toast(b.dataset.tip || 'Action indisponible.', { tone: 'info' }); return; }
    const dn = S.sheet.identity.dn;
    switch (b.dataset.acc) {
      case 'enable':
      case 'disable':
      case 'unlock':
      case 'expirePassword':
      case 'openPoste':
        S.act(b.dataset.acc);
        break;
      case 'lockouts': readLockouts(); break;
      case 'logonByDc': readLogons(); break;
      case 'resetPassword': resetOpen = true; render(); panel.querySelector('[data-card="password"]')?.scrollIntoView({ block: 'center', behavior: 'smooth' }); break;
      case 'resetClose': resetOpen = false; render(); break;
      case 'resetType':
      case 'resetGenerate': {
        // The engine opens the secure window while it prepares the plan: the page only sends the options, never a password.
        const mustChange = /** @type {HTMLInputElement} */ (panel.querySelector('[data-reset-opt="mustChange"]')).checked;
        const unlock = /** @type {HTMLInputElement} */ (panel.querySelector('[data-reset-opt="unlock"]')).checked;
        const theme = document.documentElement.dataset.theme === 'light' ? 'light' : document.documentElement.dataset.theme === 'contrast' ? 'contrast' : 'dark';
        const receipt = await write(S.ctx, 'fiche.resetPassword.plan', { dn, mustChange, unlock, generate: b.dataset.acc === 'resetGenerate', theme }, { subtitle: subtitle(), onDone: done });
        if (receipt) { resetOpen = false; render(); }
        break;
      }
      case 'expirySet': {
        const input = /** @type {HTMLInputElement} */ (panel.querySelector('#fi-expiry-date'));
        const value = fromFrench(input.value);
        if (!value) { toast('Saisissez une date valide au format jj/mm/aaaa, à partir d’aujourd’hui.', { tone: 'warn' }); input.focus(); input.setAttribute('aria-invalid', 'true'); return; }
        input.removeAttribute('aria-invalid');
        await write(S.ctx, 'fiche.expiration.plan', { dn, date: value }, { subtitle: subtitle(), onDone: done });
        break;
      }
      case 'expiryNever':
        await write(S.ctx, 'fiche.expiration.plan', { dn, date: null }, { subtitle: subtitle(), onDone: done });
        break;
      case 'optionsGo': {
        const options = changedOptions();
        if (!Object.keys(options).length) return;
        await write(S.ctx, 'fiche.options.plan', { dn, options }, { subtitle: subtitle(), onDone: done });
        break;
      }
      default:
        break;
    }
  };
  const onChange = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    if (t.matches('[data-opt]')) syncOptions();
    if (t.matches('[data-hours]')) hours = Number(/** @type {HTMLSelectElement} */ (t).value) || 168;
  };
  panel.addEventListener('click', onClick);
  panel.addEventListener('change', onChange);
  render();

  return {
    /**
     * Brings a card into view and highlights it; `run` reads now (operator gesture). A route state passes run = false: the read
     * waits for the click on the highlighted button (nothing goes on the network from an address).
     */
    focus(id, { run = true } = {}) {
      if (id === 'lockouts' && run) readLockouts();
      else if (id === 'logonByDc' && run) readLogons();
      else if (id === 'resetPassword') { resetOpen = true; render(); }
      const target = panel.querySelector(`[data-card="${id === 'resetPassword' ? 'password' : id}"]`);
      target?.scrollIntoView({ block: 'center', behavior: 'smooth' });
      target?.classList.remove('fi-focus');
      void target?.offsetWidth;
      target?.classList.add('fi-focus');
      if (!run && (id === 'lockouts' || id === 'logonByDc')) target?.querySelector(`[data-acc="${id}"]`)?.focus({ preventScroll: true });
      if (id === 'expiration') panel.querySelector('#fi-expiry-date')?.focus();
    },
    touch() { startFreshness(panel); },
    update() { render(); },
    refresh() { render(); },
    destroy() {
      panel.removeEventListener('click', onClick);
      panel.removeEventListener('change', onChange);
    },
  };
}

/** « 2026-12-31 » → « 31/12/2026 ». */
function toFrench(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso ?? '');
  return m ? `${m[3]}/${m[2]}/${m[1]}` : '';
}

/** « 31/12/2026 » (or 31.12.2026, 31-12-2026) → « 2026-12-31 » when it is a real calendar day from today on, else null. */
function fromFrench(text) {
  const m = /^\s*(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})\s*$/.exec(text ?? '');
  if (!m) return null;
  const [d, mo, y] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const date = new Date(y, mo - 1, d);
  if (date.getFullYear() !== y || date.getMonth() !== mo - 1 || date.getDate() !== d) return null;
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  if (date < today || y > 9999) return null;
  return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

export { errorText };
