// Secrets: LAPS password and BitLocker recovery keys of the workstation. Metadata first (a read on a gesture), then one
// value at a time on its own gesture, shown 30 s, extended once at most, wiped from the page at the deadline. A value is
// never journalled, kept, exported nor sent back to the engine; the clipboard copy is emptied after 30 s.
import { writeClipboard } from '../../kit/index.js';
import { reveal, toast, announce } from '../../ui.js';
import { esc, ico, rel, chip, empty, failure, cardHead, section, facts, fold, errorText, NBSP, int } from './common.js';

const CLIPBOARD_SECONDS = 30;

/** Renders the Secrets view; returns its cleanup. */
export function renderSecrets(panel, state) {
  let alive = true;
  const local = {
    laps: null, lapsError: null, lapsBusy: false,
    keys: null, keysError: null, keysBusy: false, filter: '',
    shown: null, // { kind, reveal, until, extended, timer, keyDn }
    busyKey: null,
  };
  let clipboardTimer = 0;

  const paint = () => {
    const d = state.data;
    const s = d.secrets;
    panel.innerHTML = `<div class="ps-secrets">
      <section class="ps-secret-banner reveal" data-tone="${s.bitLockerDenied || s.lapsDenied ? 'warn' : 'info'}">
        <span class="ps-secret-banner-ico">${ico('key')}</span>
        <div><b>${esc(s.text)}</b><span>${esc(`Lecture avec ${s.identity}`)} · ${esc(s.identityReason)}</span></div>
        <ul class="ps-secret-rules" aria-label="Règles d’affichage">
          <li>${ico('eye')}Une valeur à la fois, 30${NBSP}s</li><li>${ico('clock')}Une prolongation</li><li>${ico('lock')}Jamais journalisée ni exportée</li></ul>
      </section>
      ${section('Mot de passe et clés de récupération', 'Métadonnées sur votre demande, valeur sur un second geste')}
      <div class="ps-grid">
        <section class="card ps-card span-5 reveal" data-slot="laps"></section>
        <section class="card ps-card span-7 reveal" data-slot="bitlocker"></section>
      </div>
    </div>`;
    paintLaps();
    paintKeys();
    reveal(panel);
  };

  const slot = (name) => panel.querySelector(`[data-slot="${name}"]`);

  // ---------- LAPS ----------

  const paintLaps = () => {
    const host = slot('laps');
    if (!host) return;
    const d = state.data;
    const s = d.secrets;
    const v = local.laps;
    const head = cardHead('lock', 'Mot de passe LAPS', esc(s.lapsKind), v ? `<button class="btn ghost xs" type="button" data-act="laps"${local.lapsBusy ? ' disabled' : ''}>${ico('refresh')}Relire</button>` : '', v?.tone ?? 'info');
    if (local.shown?.kind === 'laps') { host.innerHTML = head + shownMarkup(local.shown); paintCountdown(); return; }
    if (local.lapsBusy) { host.innerHTML = `${head}<div class="ps-sk-stack" aria-busy="true"><span class="skeleton ps-sk w70"></span><span class="skeleton ps-sk w85"></span><span class="skeleton ps-sk w55"></span></div>`; return; }
    if (local.lapsError) { host.innerHTML = head + failure(local.lapsError, { retry: 'laps' }); return; }
    if (!v) {
      const exp = s.lapsExpiration ? `<p class="ps-note${s.lapsExpired ? ' warn' : ''}">${ico('clock')}Expiration ${s.lapsExpired ? 'dépassée' : 'prévue'} ${rel(s.lapsExpiration)} (annuaire).</p>` : '';
      host.innerHTML = `${head}<div class="ps-secret-idle"><div class="ps-vault" aria-hidden="true">${ico('lock')}</div>
        <p>Lisez d’abord l’état LAPS du poste (métadonnées seulement)${NBSP}; le mot de passe ne se lit que sur un second geste.</p>${exp}
        <button class="btn primary sm" type="button" data-act="laps">${ico('eye')}Lire l’état LAPS</button></div>`;
      return;
    }
    host.innerHTML = `${head}<p class="ps-secret-state">${chip(v.tone, v.stateLabel)} ${esc(v.message)}</p>${facts(v.facts, { compact: true })}
      <div class="ps-row-actions">${v.canReveal ? `<button class="btn primary sm" type="button" data-act="lapsReveal">${ico('eye')}Afficher le mot de passe (30${NBSP}s)</button>` : ''}</div>
      ${v.offerOtherAccount ? `<p class="ps-note warn">${ico('user')}Votre compte n’a pas ce droit${NBSP}: la lecture avec un autre compte (invite Windows) arrive avec le mode annuaire.</p>` : ''}
      <p class="ps-note">${ico('info')}Lu ${rel(v.readAt)} avec ${esc(v.identity)}.</p>`;
  };

  const readLaps = async () => {
    local.lapsBusy = true;
    local.lapsError = null;
    paintLaps();
    try {
      local.laps = await state.call('poste.laps', { dn: state.dn });
      // The summary of the header and of the banner (non-secret index) follows the read.
      state.reload().catch((err) => console.error(err));
    } catch (err) {
      local.lapsError = err;
    } finally {
      local.lapsBusy = false;
      if (alive) paintLaps();
    }
  };

  const revealLaps = async () => {
    hide(false);
    const btn = slot('laps')?.querySelector('[data-act="lapsReveal"]');
    if (btn) { btn.disabled = true; btn.setAttribute('aria-busy', 'true'); }
    try {
      const r = await state.call('poste.laps.reveal', { dn: state.dn });
      if (!alive) return;
      show('laps', r, null);
    } catch (err) {
      toast(errorText(err), { tone: 'alert' });
      paintLaps();
    }
  };

  // ---------- BitLocker ----------

  const paintKeys = () => {
    const host = slot('bitlocker');
    if (!host) return;
    const s = state.data.secrets;
    const list = local.keys;
    const head = cardHead('shield', 'Clés de récupération BitLocker', list ? esc(list.statusText) : s.bitLockerKeys != null ? `${int(s.bitLockerKeys)} clé${s.bitLockerKeys > 1 ? 's' : ''} lors de la dernière lecture` : 'Non lues dans cette session',
      list ? `<button class="btn ghost xs" type="button" data-act="keys"${local.keysBusy ? ' disabled' : ''}>${ico('refresh')}Relire</button>` : '', list?.readState === 'refused' ? 'warn' : 'info');
    if (local.shown?.kind === 'bitlocker') { host.innerHTML = head + shownMarkup(local.shown); paintCountdown(); return; }
    if (local.keysBusy) { host.innerHTML = `${head}<div class="ps-sk-stack" aria-busy="true"><span class="skeleton ps-sk w85"></span><span class="skeleton ps-sk w70"></span><span class="skeleton ps-sk w85"></span></div>`; return; }
    if (local.keysError) { host.innerHTML = head + failure(local.keysError, { retry: 'keys' }); return; }
    if (!list) {
      host.innerHTML = `${head}<div class="ps-secret-idle"><div class="ps-vault" aria-hidden="true">${ico('shield')}</div>
        <p>Liste les objets de récupération sous le poste (un niveau, 256 au plus), sans lire aucune clé.</p>
        ${s.bitLockerDenied ? `<p class="ps-note warn">${ico('alert')}Une lecture précédente a été refusée pour votre compte.</p>` : ''}
        <button class="btn primary sm" type="button" data-act="keys">${ico('eye')}Lire les clés du poste</button></div>`;
      return;
    }
    if (list.readState === 'refused') {
      host.innerHTML = `${head}${empty({ icon: 'lock', tone: 'warn', title: 'Lecture refusée pour ce compte', text: list.statusText })}${facts(list.facts, { compact: true })}`;
      return;
    }
    const needle = normalizeId(local.filter);
    const rows = list.keys.filter((k) => !needle || normalizeId(k.recoveryId).startsWith(needle) || normalizeId(k.recoveryId).includes(needle));
    host.innerHTML = `${head}
      <div class="ps-key-search"><label class="visually-hidden" for="ps-key-q">Identifiant de récupération</label>
        <span class="k-input-ico">${ico('search')}<input id="ps-key-q" class="input mono" type="search" data-input="filter" value="${esc(local.filter)}" placeholder="Identifiant de récupération (8 premiers caractères)" autocomplete="off" spellcheck="false" maxlength="48"></span>
        <span class="ps-key-count" aria-live="polite">${int(rows.length)} / ${int(list.keys.length)}</span></div>
      ${list.keys.length === 0 ? empty({ icon: 'shield', title: 'Aucune clé visible sous ce poste', text: list.statusText }) : rows.length === 0 ? empty({ icon: 'search', title: 'Aucune clé ne correspond', text: 'Vérifiez l’identifiant affiché sur l’écran de récupération du poste (tirets et accolades ignorés).' })
        : `<ul class="ps-keys">${rows.map((k, n) => `<li class="ps-key reveal" data-i="${n}"><span class="ps-key-ico">${ico('key')}</span>
            <div class="ps-key-body"><b class="mono">${highlightId(k.recoveryId, needle)}</b><span>${esc(k.volume)} · ${esc(k.created)}</span></div>
            <button class="btn sm" type="button" data-act="keyReveal" data-key="${esc(k.dn)}"${local.busyKey === k.dn ? ' disabled aria-busy="true"' : ''}>${ico('eye')}Afficher la clé</button></li>`).join('')}</ul>`}
      <p class="ps-note">${ico('info')}${esc(list.columnHeader)} · lu ${rel(list.readAt)} avec ${esc(list.identity)}.</p>`;
    reveal(host);
  };

  const readKeys = async () => {
    local.keysBusy = true;
    local.keysError = null;
    paintKeys();
    try {
      local.keys = await state.call('poste.bitlocker.list', { dn: state.dn });
      state.reload().catch((err) => console.error(err));
    } catch (err) {
      local.keysError = err;
    } finally {
      local.keysBusy = false;
      if (alive) paintKeys();
    }
  };

  const revealKey = async (keyDn) => {
    hide(false);
    local.busyKey = keyDn;
    paintKeys();
    try {
      const r = await state.call('poste.bitlocker.reveal', { dn: state.dn, key: keyDn });
      if (!alive) return;
      local.busyKey = null;
      show('bitlocker', r, keyDn);
    } catch (err) {
      local.busyKey = null;
      toast(errorText(err), { tone: 'alert' });
      paintKeys();
    }
  };

  // ---------- One revealed value ----------

  const show = (kind, r, keyDn) => {
    local.shown = { kind, reveal: r, until: Date.now() + r.revealSeconds * 1000, total: r.revealSeconds, extended: 0, keyDn };
    if (kind === 'laps') paintLaps(); else paintKeys();
    announce(`${kind === 'laps' ? 'Mot de passe' : 'Clé de récupération'} affiché pour ${r.revealSeconds} secondes.`);
  };

  /** Wipes the value from the page (deadline, « Masquer », another reveal, leaving the view). */
  const hide = (repaint = true) => {
    const was = local.shown;
    if (!was) return;
    local.shown = null;
    if (repaint && alive) {
      if (was.kind === 'laps') paintLaps(); else paintKeys();
    }
  };

  const extend = () => {
    const s = local.shown;
    if (!s || s.extended >= s.reveal.extensions) return;
    s.extended += 1;
    s.until = Math.max(s.until, Date.now()) + s.reveal.extensionSeconds * 1000;
    s.total = Math.max(1, Math.round((s.until - Date.now()) / 1000));
    if (s.kind === 'laps') paintLaps(); else paintKeys();
    announce(`Affichage prolongé de ${s.reveal.extensionSeconds} secondes.`);
  };

  const copy = async () => {
    const s = local.shown;
    if (!s) return;
    const value = s.reveal.value ?? s.reveal.blocks.map((b) => b.digits).join('-');
    try {
      if (!(await writeClipboard(value))) { toast('Copie impossible : le presse-papiers a refusé la valeur.', { tone: 'alert' }); return; }
      clearTimeout(clipboardTimer);
      clipboardTimer = setTimeout(() => { writeClipboard(''); }, CLIPBOARD_SECONDS * 1000);
      toast(`Copié pour ${CLIPBOARD_SECONDS}${NBSP}s, puis presse-papiers vidé. ${s.reveal.clipboardLimit}`, { tone: 'warn', life: 7000 });
    } catch (err) {
      toast(errorText(err), { tone: 'alert' });
    }
  };

  const paintCountdown = () => {
    const s = local.shown;
    if (!s) return;
    const left = Math.max(0, Math.ceil((s.until - Date.now()) / 1000));
    const host = panel.querySelector('[data-slot="shown"]');
    if (!host) return;
    host.querySelector('.ps-countdown .arc')?.style.setProperty('--p', String(Math.min(1, left / Math.max(1, s.total))));
    const t = host.querySelector('[data-left]');
    if (t) t.textContent = String(left);
    host.dataset.urgent = left <= 5 ? 'true' : 'false';
  };

  const tick = () => {
    const s = local.shown;
    if (!s) return;
    if (Date.now() >= s.until) { hide(); announce('Valeur masquée.'); return; }
    paintCountdown();
  };

  const onClick = (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-act]') : null;
    if (!b || !panel.contains(b) || b.disabled) return;
    const act = b.dataset.act;
    if (act === 'laps') readLaps();
    else if (act === 'lapsReveal') revealLaps();
    else if (act === 'keys') readKeys();
    else if (act === 'keyReveal') revealKey(b.dataset.key);
    else if (act === 'hide') hide();
    else if (act === 'extend') extend();
    else if (act === 'copySecret') copy();
  };
  const onInput = (e) => {
    if (e.target instanceof HTMLInputElement && e.target.dataset.input === 'filter') {
      local.filter = e.target.value;
      const pos = e.target.selectionStart;
      paintKeys();
      const input = panel.querySelector('[data-input="filter"]');
      if (input) { input.focus(); input.setSelectionRange(pos, pos); }
    }
  };
  panel.addEventListener('click', onClick);
  panel.addEventListener('input', onInput);
  paint();
  const timer = setInterval(() => { if (alive) tick(); }, 250);
  const offConsole = state.on('console', () => { if (alive) { hide(false); paint(); } });
  // Leaving the view hides the value at once (the tab panel stays in the page).
  const onVisibility = () => { if (document.hidden) hide(); };
  document.addEventListener('visibilitychange', onVisibility);
  const offTab = state.on('viewChange', (id) => { if (id !== 'secrets') hide(); });
  if (state.essai === 'laps') readLaps();
  else if (state.essai === 'bitlocker') readKeys();

  return () => {
    alive = false;
    local.shown = null;
    clearInterval(timer);
    offConsole();
    offTab();
    document.removeEventListener('visibilitychange', onVisibility);
    panel.removeEventListener('click', onClick);
    panel.removeEventListener('input', onInput);
  };
}

function shownMarkup(s) {
  const r = s.reveal;
  const left = Math.max(0, Math.ceil((s.until - Date.now()) / 1000));
  const p = Math.min(1, left / Math.max(1, s.total));
  const value = r.kind === 'laps'
    ? `<div class="ps-secret-value mono" aria-label="Mot de passe, caractère par caractère">${[...(r.value ?? '')].map((ch) => `<span data-c="${/[0-9]/.test(ch) ? 'd' : /[A-Za-z]/.test(ch) ? (ch === ch.toUpperCase() ? 'u' : 'l') : 's'}">${esc(ch)}</span>`).join('')}</div>`
    : `<ol class="ps-blocks">${r.blocks.map((b) => `<li><span class="ps-block-n">${esc(b.label)}</span><b class="mono">${esc(b.digits)}</b></li>`).join('')}</ol>`;
  const canExtend = s.extended < r.extensions;
  return `<div class="ps-shown" data-slot="shown" data-kind="${esc(r.kind)}" role="region" aria-label="${esc(r.kind === 'laps' ? 'Mot de passe affiché' : 'Clé de récupération affichée')}">
    <div class="ps-shown-top">
      <div class="ps-countdown sm" data-tone="warn" role="timer" aria-label="Secondes avant masquage">
        <svg viewBox="0 0 120 120" aria-hidden="true"><circle class="trk" cx="60" cy="60" r="50"/><circle class="arc" cx="60" cy="60" r="50" pathLength="100" data-p="${p.toFixed(3)}"/></svg>
        <div class="ps-countdown-c"><b data-left>${left}</b><span>s</span></div></div>
      <div class="ps-shown-id"><b>${esc(r.kind === 'laps' ? `Compte ${r.identifier}` : `Identifiant ${r.identifier}`)}</b><span>${esc(r.computer)}${r.simulated ? ' · valeur fictive' : ''}</span></div>
    </div>
    ${value}
    <p class="ps-note${r.simulated ? '' : ' warn'}">${ico(r.simulated ? 'sparkles' : 'alert')}${esc(r.notice)}</p>
    <div class="ps-row-actions wrap">
      <button class="btn sm primary" type="button" data-act="copySecret">${ico('copy')}Copier (vidé après ${CLIPBOARD_SECONDS}${NBSP}s)</button>
      <button class="btn sm" type="button" data-act="extend"${canExtend ? '' : ' disabled'}>${ico('clock')}${canExtend ? `Prolonger de ${r.extensionSeconds}${NBSP}s` : 'Prolongation utilisée'}</button>
      <button class="btn ghost sm" type="button" data-act="hide">${ico('eyeOff')}Masquer</button></div></div>`;
}

/** Recovery identifier without dashes, braces nor case (tolerant search, Domenia 1 point 58). */
function normalizeId(text) {
  return fold(String(text ?? '')).replace(/[^0-9a-z]/g, '');
}

function highlightId(id, needle) {
  if (!needle) return esc(id);
  // Marks the characters of the identifier that match the start of the search, dashes kept.
  let left = needle.length;
  let out = '';
  const started = normalizeId(id).startsWith(needle);
  for (const ch of id) {
    if (started && left > 0 && /[0-9a-z]/i.test(ch)) { out += `<mark>${esc(ch)}</mark>`; left -= 1; } else out += esc(ch);
  }
  if (!started) return esc(id);
  return out;
}
