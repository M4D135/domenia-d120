// Secrets: LAPS password and BitLocker recovery keys of the workstation, and the non-secret index of the working OU.
// Metadata first (a read on a gesture), then one value at a time on its own gesture, shown 30 s (one extension) in the
// secure window of the application: the value never enters this page, a response, a journal, a receipt or an export
// (OPERATIONS.md § 1.2). The window masks it when it loses the focus, wipes it at the deadline, and protects its copy
// (emptied after 30 s only if the clipboard still holds it). This view follows the window by its state, never its value.
import { createGrid, confirmDialog } from '../../kit/index.js';
import { reveal, toast, announce } from '../../ui.js';
import { esc, ico, rel, chip, empty, failure, cardHead, section, facts, errorText, NBSP, int, count, fitGrid, saveExport, formatDateTime } from './common.js';

/** Renders the Secrets view; returns its cleanup. */
export function renderSecrets(panel, state) {
  let alive = true;
  const local = {
    laps: null, lapsError: null, lapsBusy: false,
    keys: null, keysError: null, keysBusy: false, filter: '',
    shown: null, // { kind, identifier, until, extensionsLeft, masked } — never the value
    busy: null,
    index: null, indexBusy: false, indexError: null,
  };
  let indexGrid = null;
  const noWindow = 'Aucune fenêtre sécurisée dans cet affichage (aperçu ou tests) : aucune valeur ne peut être montrée.';

  const paint = () => {
    const d = state.data;
    const s = d.secrets;
    panel.innerHTML = `<div class="ps-secrets">
      <section class="ps-secret-banner reveal" data-tone="${s.bitLockerDenied || s.lapsDenied ? 'warn' : 'info'}">
        <span class="ps-secret-banner-ico">${ico('key')}</span>
        <div><b>${esc(s.text)}</b><span>${esc(`Lecture avec ${s.identity}`)} · ${esc(s.identityReason)}</span></div>
        <ul class="ps-secret-rules" aria-label="Règles d’affichage">
          <li>${ico('eye')}Une valeur à la fois, 30${NBSP}s</li><li>${ico('clock')}Une prolongation</li><li>${ico('lock')}Fenêtre sécurisée, jamais dans la page</li></ul>
      </section>
      ${section('Mot de passe et clés de récupération', 'Métadonnées sur votre demande, valeur sur un second geste')}
      <div class="grid ps-grid">
        <section class="card ps-card span-5 reveal" data-slot="laps"></section>
        <section class="card ps-card span-7 reveal" data-slot="bitlocker"></section>
      </div>
      ${section('Index des secrets de l’OU de travail', 'Clés BitLocker comptées et expirations LAPS, jamais une valeur')}
      <div class="grid ps-grid"><section class="card ps-card span-12 reveal" data-slot="index"></section></div>
    </div>`;
    paintLaps();
    paintKeys();
    paintIndex();
    reveal(panel);
  };

  const slot = (name) => panel.querySelector(`[data-slot="${name}"]`);
  const canReveal = () => state.host.secretWindow === true;

  // ---------- The value shown in the secure window (state only) ----------

  const shownMarkup = (kind) => {
    const s = local.shown;
    if (!s || s.kind !== kind) return '';
    const left = Math.max(0, Math.ceil((Date.parse(s.until) - Date.now()) / 1000));
    const p = Math.min(1, left / Math.max(1, s.total));
    return `<div class="ps-shown" data-slot="shown" data-kind="${esc(kind)}" data-masked="${s.masked ? 'true' : 'false'}" role="region" aria-label="Valeur affichée dans la fenêtre sécurisée">
      <div class="ps-shown-top">
        <div class="ps-countdown sm" data-tone="warn" role="timer" aria-label="Secondes avant effacement">
          <svg viewBox="0 0 120 120" aria-hidden="true"><circle class="trk" cx="60" cy="60" r="50"/><circle class="arc" cx="60" cy="60" r="50" pathLength="100" data-p="${p.toFixed(3)}"/></svg>
          <div class="ps-countdown-c"><b data-left>${left}</b><span>s</span></div></div>
        <div class="ps-shown-id"><b>${esc(kind === 'laps' ? `Compte ${s.identifier}` : `Identifiant ${s.keyGuid ?? s.identifier}`)}</b>
          <span data-shown-text>${esc(s.masked ? 'Valeur masquée : la fenêtre sécurisée a perdu le focus. Cliquez sur « Réafficher » dans la fenêtre.' : 'Valeur affichée dans la fenêtre sécurisée, au-dessus de Domenia.')}</span></div>
      </div>
      <ul class="ps-shown-rules"><li>${ico('copy')}Copie protégée, vidée après 30${NBSP}s si elle n’a pas changé</li><li>${ico('clock')}${esc(s.extensionsLeft > 0 ? 'Une prolongation possible dans la fenêtre' : 'Prolongation utilisée')}</li><li>${ico('eyeOff')}Masquée hors du focus, effacée à l’échéance</li></ul>
      ${s.simulated ? `<p class="ps-note">${ico('sparkles')}Valeur fictive de la simulation.</p>` : ''}
      <div class="ps-row-actions"><button class="btn sm" type="button" data-act="hide">${ico('eyeOff')}Masquer maintenant</button></div></div>`;
  };

  const hide = async (quiet = false) => {
    if (!local.shown) return;
    local.shown = null;
    if (alive) { paintLaps(); paintKeys(); }
    try {
      await state.call('poste.secret.hide');
      if (!quiet) announce('Valeur effacée de la fenêtre sécurisée.');
    } catch (err) { console.error(err); }
  };

  const follow = async () => {
    if (!local.shown || !alive) return;
    try {
      const w = await state.call('poste.secret.state');
      if (!alive || !local.shown) return;
      if (!w.open) {
        const kind = local.shown.kind;
        local.shown = null;
        if (kind === 'laps') paintLaps(); else paintKeys();
        announce(w.text);
        return;
      }
      const changed = w.masked !== local.shown.masked || w.extensionsLeft !== local.shown.extensionsLeft;
      local.shown.until = w.until;
      local.shown.masked = w.masked;
      if (w.extensionsLeft !== local.shown.extensionsLeft) local.shown.total = Math.max(1, Math.round((Date.parse(w.until) - Date.now()) / 1000));
      local.shown.extensionsLeft = w.extensionsLeft;
      if (changed) { if (local.shown.kind === 'laps') paintLaps(); else paintKeys(); }
    } catch (err) { console.error(err); }
  };

  const tick = () => {
    const s = local.shown;
    const host = panel.querySelector('[data-slot="shown"]');
    if (!s || !host) return;
    const left = Math.max(0, Math.ceil((Date.parse(s.until) - Date.now()) / 1000));
    host.querySelector('.ps-countdown .arc')?.style.setProperty('--p', String(Math.min(1, left / Math.max(1, s.total))));
    const t = host.querySelector('[data-left]');
    if (t) t.textContent = String(left);
    host.dataset.urgent = left <= 5 ? 'true' : 'false';
  };

  const shown = (kind, r) => {
    local.shown = { kind, identifier: r.identifier, keyGuid: r.keyGuid, until: r.until, total: r.revealSeconds, extensionsLeft: r.extensions, masked: false, simulated: r.simulated };
    if (kind === 'laps') paintLaps(); else paintKeys();
    announce(`${kind === 'laps' ? 'Mot de passe' : 'Clé de récupération'} affiché ${r.revealSeconds} secondes dans la fenêtre sécurisée.`);
  };

  // ---------- LAPS ----------

  const accountIssue = (err) => ['ad.credentials', 'ad.accessDenied', 'machine.accountPaused', 'poste.refused', 'poste.lapsDecryptDenied'].includes(err?.code);

  const paintLaps = () => {
    const host = slot('laps');
    if (!host) return;
    const s = state.data.secrets;
    const v = local.laps;
    const head = cardHead('lock', 'Mot de passe LAPS', esc(s.lapsKind), v ? `<button class="btn ghost sm" type="button" data-act="laps"${local.lapsBusy ? ' disabled' : ''}>${ico('refresh')}Relire</button>` : '', v?.tone ?? 'info');
    if (local.shown?.kind === 'laps') { host.innerHTML = head + shownMarkup('laps'); paintRing(host); return; }
    if (local.lapsBusy) { host.innerHTML = `${head}<div class="ps-sk-stack" aria-busy="true"><span class="skeleton ps-sk w70"></span><span class="skeleton ps-sk w85"></span><span class="skeleton ps-sk w55"></span></div>`; return; }
    if (local.lapsError) { host.innerHTML = head + failure(local.lapsError, { retry: 'laps' }) + (accountIssue(local.lapsError) ? '<button class="btn sm" type="button" data-act="other" data-resource="laps">Proposer un autre compte</button>' : ''); return; }
    const other = (v?.offerOtherAccount || s.lapsDenied) ? `<div class="ps-other"><p class="ps-note warn">${ico('user')}Valeur non visible ou accès refusé pour ${esc(v?.identity ?? s.identity)}${NBSP}: un autre compte peut être proposé, pour LAPS sur ce poste seulement.</p>
        <button class="btn sm" type="button" data-act="other" data-resource="laps">${ico('user')}Proposer un autre compte</button></div>` : '';
    if (!v) {
      const exp = s.lapsExpiration ? `<p class="ps-note${s.lapsExpired ? ' warn' : ''}">${ico('clock')}Expiration ${s.lapsExpired ? 'dépassée' : 'prévue'} ${rel(s.lapsExpiration)} (annuaire).</p>` : '';
      host.innerHTML = `${head}<div class="ps-secret-idle"><div class="ps-vault" aria-hidden="true">${ico('lock')}</div>
        <p>Lisez d’abord l’état LAPS du poste (métadonnées seulement)${NBSP}; le mot de passe ne se lit que sur un second geste.</p>${exp}
        <button class="btn sm" type="button" data-act="laps">${ico('eye')}Lire l’état LAPS</button></div>${other}`;
      return;
    }
    const revealBtn = v.canReveal
      ? `<button class="btn sm" type="button" data-act="lapsReveal"${canReveal() ? '' : ` aria-disabled="true" data-tip="${esc(noWindow)}"`}${local.busy === 'laps' ? ' disabled aria-busy="true"' : ''}>${ico('eye')}Afficher le mot de passe (30${NBSP}s)</button>` : '';
    const prerequisite = v.state === 'prerequisite' ? `<button class="btn ghost sm" type="button" data-act="prerequisite">${ico('settings')}Ouvrir${NBSP}: Paramètres</button>` : '';
    host.innerHTML = `${head}<p class="ps-secret-state">${chip(v.tone, v.stateLabel)} ${esc(v.message)}</p>${facts(v.facts, { compact: true })}
      ${revealBtn || prerequisite ? `<div class="ps-row-actions">${revealBtn}${prerequisite}</div>` : ''}${v.offerOtherAccount ? other : ''}
      <p class="ps-note">${ico('info')}Lu ${rel(v.readAt)} avec ${esc(v.identity)}.</p>`;
  };

  const readLaps = async () => {
    local.lapsBusy = true;
    local.lapsError = null;
    paintLaps();
    try {
      local.laps = await state.call('poste.laps', { dn: state.dn });
      // The summary of the banner (non-secret index) follows the read.
      state.reload().catch((err) => console.error(err));
    } catch (err) {
      local.lapsError = err;
    } finally {
      local.lapsBusy = false;
      if (alive) paintLaps();
    }
  };

  const revealLaps = async () => {
    if (!canReveal()) { toast(noWindow, { tone: 'warn' }); return; }
    await hide(true);
    local.busy = 'laps';
    paintLaps();
    try {
      const r = await state.call('poste.laps.reveal', { dn: state.dn });
      if (!alive) return;
      local.busy = null;
      shown('laps', r);
    } catch (err) {
      local.busy = null;
      if (accountIssue(err) && local.laps) local.laps = { ...local.laps, canReveal: false, offerOtherAccount: true, tone: 'warn', stateLabel: err.code === 'poste.lapsDecryptDenied' ? 'Déchiffrement refusé' : 'Lecture non aboutie', message: errorText(err) };
      toast(errorText(err), { tone: 'alert' });
      paintLaps();
    }
  };

  // ---------- BitLocker ----------

  /** Recovery identifier without dashes, braces nor case (tolerant search, Domenia 1 point 58). */
  const norm = (text) => String(text ?? '').toUpperCase().replace(/[^0-9A-F]/g, '');

  const matchesOf = (list) => {
    const needle = norm(local.filter);
    return list.keys.filter((k) => !needle || norm(k.keyGuid).startsWith(needle) || norm(k.recoveryId).startsWith(needle));
  };

  const paintKeys = () => {
    const host = slot('bitlocker');
    if (!host) return;
    const s = state.data.secrets;
    const list = local.keys;
    const head = cardHead('shield', 'Clés de récupération BitLocker', list ? esc(list.statusText) : s.bitLockerKeys != null ? esc(`${count(s.bitLockerKeys, 'clé', 'clés')} lors de la dernière lecture`) : 'Non lues',
      list ? `<button class="btn ghost sm" type="button" data-act="keys"${local.keysBusy ? ' disabled' : ''}>${ico('refresh')}Relire</button>` : '', list?.readState === 'refused' ? 'warn' : 'info');
    if (local.shown?.kind === 'bitlocker') { host.innerHTML = head + shownMarkup('bitlocker'); paintRing(host); return; }
    if (local.keysBusy) { host.innerHTML = `${head}<div class="ps-sk-stack" aria-busy="true"><span class="skeleton ps-sk w85"></span><span class="skeleton ps-sk w70"></span><span class="skeleton ps-sk w85"></span></div>`; return; }
    if (local.keysError) { host.innerHTML = head + failure(local.keysError, { retry: 'keys' }) + (accountIssue(local.keysError) ? '<button class="btn sm" type="button" data-act="other" data-resource="bitlocker">Proposer un autre compte</button>' : ''); return; }
    const other = `<div class="ps-other"><p class="ps-note warn">${ico('user')}Valeur non visible ou accès refusé pour ce compte${NBSP}: un autre compte peut être proposé, pour BitLocker sur ce poste seulement.</p>
      <button class="btn sm" type="button" data-act="other" data-resource="bitlocker">${ico('user')}Proposer un autre compte</button></div>`;
    if (!list) {
      host.innerHTML = `${head}<div class="ps-secret-idle"><div class="ps-vault" aria-hidden="true">${ico('shield')}</div>
        <p>Liste les objets de récupération sous le poste (un niveau, 256 au plus), sans lire aucune clé.</p>
        <button class="btn sm" type="button" data-act="keys">${ico('eye')}Lire les clés du poste</button></div>${s.bitLockerDenied ? other : ''}`;
      return;
    }
    if (list.readState === 'refused') {
      host.innerHTML = `${head}${empty({ icon: 'lock', tone: 'warn', title: 'Lecture refusée pour ce compte', text: list.statusText })}${facts(list.facts, { compact: true })}${other}`;
      return;
    }
    const rows = matchesOf(list);
    const needle = norm(local.filter);
    const unique = needle.length > 0 && rows.length === 1 ? rows[0] : null;
    host.innerHTML = `${head}
      <div class="ps-key-search"><label class="visually-hidden" for="ps-key-q">Identifiant de récupération affiché par le poste</label>
        <span class="k-input-ico">${ico('search')}<input id="ps-key-q" class="input ps-key-input" type="search" data-input="filter" value="${esc(local.filter)}" placeholder="Identifiant de récupération affiché par le poste (8 caractères suffisent)" autocomplete="off" spellcheck="false" maxlength="48"></span>
        <span class="ps-key-count" aria-live="polite">${int(rows.length)} / ${int(list.keys.length)}</span></div>
      ${unique ? `<p class="ps-badge-line" data-tone="ok">${ico('check')}<span>Une seule clé correspond${NBSP}: elle est sélectionnée.</span></p>` : ''}
      ${list.keys.length === 0 ? empty({ icon: 'shield', title: 'Aucune clé visible sous ce poste', text: list.statusText }) : rows.length === 0 ? empty({ icon: 'search', title: 'Aucune clé ne correspond', text: 'Vérifiez l’identifiant affiché sur l’écran de récupération du poste (tirets et accolades ignorés).' })
        : `<ul class="ps-keys">${rows.map((k, n) => `<li class="ps-key" data-i="${n}"${unique === k ? ' data-selected="true"' : ''}><span class="ps-key-ico">${ico('key')}</span>
            <div class="ps-key-body"><b class="mono" data-tip="Identifiant de récupération complet (msFVE-RecoveryGuid)">${highlightId(k.keyGuid, needle)}</b><span>${esc(k.volume)} · ${esc(k.created)}</span></div>
            <button class="btn sm${unique === k ? ' primary' : ''}" type="button" data-act="keyReveal" data-key="${esc(k.dn)}" data-guid="${esc(k.keyGuid)}"${canReveal() ? '' : ` aria-disabled="true" data-tip="${esc(noWindow)}"`}${local.busy === k.dn ? ' disabled aria-busy="true"' : ''}>${ico('eye')}Afficher la clé</button></li>`).join('')}</ul>`}
      <p class="ps-note">${ico('info')}${esc(list.columnHeader)} · lu ${rel(list.readAt)} avec ${esc(list.identity)}.</p>
      ${list.offerOtherAccount ? other : ''}`;
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

  const revealKey = async (keyDn, guid) => {
    if (!canReveal()) { toast(noWindow, { tone: 'warn' }); return; }
    await hide(true);
    local.busy = keyDn;
    paintKeys();
    try {
      // The identifier read back with the key must be the one chosen here (Domenia 1 Mismatch): otherwise no value.
      const r = await state.call('poste.bitlocker.reveal', { dn: state.dn, key: keyDn, expectedId: guid });
      if (!alive) return;
      local.busy = null;
      shown('bitlocker', r);
    } catch (err) {
      local.busy = null;
      if (accountIssue(err) && local.keys) local.keys = { ...local.keys, offerOtherAccount: true };
      toast(errorText(err), { tone: 'alert' });
      paintKeys();
    }
  };

  const otherAccount = async (resource) => {
    const ok = await confirmDialog({
      title: 'Proposer un autre compte ?',
      message: `Une fenêtre sécurisée demandera un autre compte pour la lecture ${resource === 'laps' ? 'LAPS' : 'BitLocker'} de ${state.data.computer.name}. Le compte restera en mémoire pour ce poste et cette ressource, pendant 30 minutes d’inactivité. Le mot de passe ne passe jamais par cette page. Aucune révélation ne sera relancée automatiquement.`,
      confirmLabel: 'Proposer un autre compte',
    });
    if (!ok || !alive) return;
    try {
      const r = await state.call('poste.account.other', { dn: state.dn, resource, theme: document.documentElement.dataset.theme ?? 'dark' });
      toast(r.text, { tone: r.accepted ? 'ok' : 'info', life: 7000 });
      if (r.accepted) {
        if (resource === 'laps') { local.laps = null; local.lapsError = null; } else { local.keys = null; local.keysError = null; }
        await state.reload();
        if (alive) { if (resource === 'laps') paintLaps(); else paintKeys(); }
      }
    } catch (err) {
      toast(errorText(err), { tone: 'alert' });
    }
  };

  // ---------- Index of the working OU (PST-066) ----------

  const paintIndex = () => {
    const host = slot('index');
    if (!host) return;
    const idx = local.index;
    indexGrid?.destroy();
    indexGrid = null;
    const head = cardHead('database', 'Index des secrets', idx ? esc(idx.summary) : 'Présence de clés BitLocker et expiration LAPS de chaque poste de l’OU de travail (50 000 postes au plus)',
      `${idx ? `<button class="btn ghost sm" type="button" data-act="indexExport">${ico('csv')}Exporter</button>` : ''}<button class="btn sm" type="button" data-act="index"${local.indexBusy ? ' disabled aria-busy="true"' : ''} data-tip="Lecture de l’annuaire bornée à l’OU de travail, sur ce clic">${ico('refresh')}${idx ? 'Relire l’index' : 'Indexer l’OU de travail'}</button>`);
    if (local.indexBusy) { host.innerHTML = `${head}<div class="ps-sk-stack" aria-busy="true"><span class="skeleton ps-sk w85"></span><span class="skeleton ps-sk w70"></span></div>`; return; }
    if (local.indexError) { host.innerHTML = head + failure(local.indexError, { retry: 'index' }); return; }
    if (!idx) {
      host.innerHTML = `${head}${empty({ icon: 'database', title: 'Index non lu', text: 'Un compte déjà lu n’est jamais remplacé par le zéro d’une lecture qui ne voit rien ; les métadonnées d’un ancien détenteur du même nom sont écartées. Aucune clé ni aucun mot de passe.' })}`;
      return;
    }
    host.innerHTML = `${head}<div class="ps-index-sums">
        <span class="ps-sum" data-tone="ok"><b>${int(idx.withKeys)}</b>présences BitLocker datées</span><span class="ps-sum" data-tone="off"><b>${int(idx.withoutKeys)}</b>sans objet visible</span>
        <span class="ps-sum" data-tone="alert"><b>${int(idx.refused)}</b>${esc(idx.refused > 1 ? 'lectures refusées' : 'lecture refusée')}</span><span class="ps-sum" data-tone="warn"><b>${int(idx.lapsExpired)}</b>LAPS échu</span>
        <span class="ps-sum" data-tone="info"><b>${int(idx.lapsMissing)}</b>expirations LAPS non visibles</span>
        ${idx.unknown > 0 ? `<span class="ps-sum" data-tone="off"><b>${int(idx.unknown)}</b>lectures BitLocker non concluantes</span>` : ''}</div><div data-slot="index-grid"></div>`;
    indexGrid = createGrid(host.querySelector('[data-slot="index-grid"]'), {
      key: 'poste.secrets.index',
      label: 'Index des secrets de l’OU',
      rowId: (r) => r.dn,
      selection: 'single',
      columns: [
        { id: 'computer', label: 'Poste', required: true, width: 170, mono: true },
        { id: 'bitLockerKeys', label: 'Clés BitLocker', type: 'number', width: 140 },
        { id: 'bitLockerState', label: 'Lecture BitLocker', type: 'enum', width: 170, options: [
          { value: 'observed', label: 'Objets visibles', tone: 'ok' }, { value: 'estimated', label: 'Présence datée ou partielle', tone: 'info' }, { value: 'refused', label: 'Refusée', tone: 'alert' }, { value: 'unknown', label: 'Non concluante', tone: 'off' }, { value: 'unavailable', label: 'Non aboutie', tone: 'off' }] },
        { id: 'bitLockerReadAt', label: 'Constat BitLocker', type: 'date', width: 170 },
        { id: 'detail', label: 'Précision de lecture', width: 320 },
        { id: 'lapsExpiration', label: 'Expiration LAPS', type: 'date', width: 170 },
        { id: 'lapsExpired', label: 'LAPS échu', type: 'bool', width: 120 },
        { id: 'lapsKind', label: 'Type LAPS', width: 140, format: (v) => (v === 'Windows' ? 'Windows LAPS' : v === 'Legacy' ? 'LAPS historique' : v === 'None' ? 'Aucun' : v === 'Unknown' ? 'Non déterminé' : v) },
        { id: 'dn', label: 'Chemin (DN)', mono: true, hidden: true, width: 420 },
      ],
      empty: { icon: 'database', title: 'Aucun poste', text: 'Aucun poste dans l’OU de travail.' },
      onActivate: (row) => state.ctx.navigate('poste', { dn: row.dn, vue: 'secrets' }),
      contextMenu: ({ row }) => [{ label: 'Ouvrir la console de ce poste', icon: 'monitor', disabled: !row, run: () => state.ctx.navigate('poste', { dn: row.dn, vue: 'secrets' }) }],
    });
    indexGrid.setRows(idx.rows);
    fitGrid(indexGrid, idx.rows.length, { max: 460 });
  };

  const readIndex = async () => {
    local.indexBusy = true;
    local.indexError = null;
    paintIndex();
    try {
      local.index = await state.call('poste.secrets.index');
    } catch (err) {
      local.indexError = err;
    } finally {
      local.indexBusy = false;
      if (alive) paintIndex();
    }
  };

  const onClick = (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-act]') : null;
    if (!b || !panel.contains(b) || b.disabled) return;
    const act = b.dataset.act;
    if (b.getAttribute('aria-disabled') === 'true') { toast(b.dataset.tip ?? noWindow, { tone: 'info' }); return; }
    if (act === 'laps') readLaps();
    else if (act === 'lapsReveal') revealLaps();
    else if (act === 'keys') readKeys();
    else if (act === 'keyReveal') revealKey(b.dataset.key, b.dataset.guid);
    else if (act === 'hide') hide();
    else if (act === 'other') otherAccount(b.dataset.resource);
    else if (act === 'prerequisite') state.ctx.navigate('parametres', { section: 'comptes' });
    else if (act === 'index') readIndex();
    else if (act === 'indexExport' && indexGrid) saveExport(state, 'secrets', [{ part: 'liste', csv: indexGrid.toCsv({ scope: 'visible' }) }]);
  };
  const onInput = (e) => {
    if (e.target instanceof HTMLInputElement && e.target.dataset.input === 'filter') {
      local.filter = e.target.value;
      const pos = e.target.selectionStart;
      paintKeys();
      const input = panel.querySelector('[data-input="filter"]');
      if (input) { input.focus(); input.setSelectionRange(pos, pos); }
      if (local.keys && norm(local.filter).length > 0) {
        const rows = matchesOf(local.keys);
        if (rows.length === 1) announce(`Une seule clé correspond : ${rows[0].keyGuid}, sélectionnée.`);
      }
    }
  };
  panel.addEventListener('click', onClick);
  panel.addEventListener('input', onInput);
  paint();
  const timer = setInterval(() => { if (alive) tick(); }, 250);
  const poll = setInterval(() => { if (alive) follow(); }, 1000);
  // Another workstation or another console reading: the value is wiped from the window first.
  const offConsole = state.on('console', () => { if (alive) paint(); });
  // Leaving the view wipes the value at once (the panel stays in the page).
  const offTab = state.on('viewChange', (id) => { if (id !== 'secrets') hide(true); });
  if (state.essai === 'laps') readLaps();
  else if (state.essai === 'bitlocker') readKeys();
  else if (state.essai === 'index') readIndex();

  return () => {
    alive = false;
    if (local.shown) state.call('poste.secret.hide').catch((err) => console.error(err));
    local.shown = null;
    clearInterval(timer);
    clearInterval(poll);
    offConsole();
    offTab();
    indexGrid?.destroy();
    panel.removeEventListener('click', onClick);
    panel.removeEventListener('input', onInput);
  };
}

function paintRing(host) {
  requestAnimationFrame(() => host.querySelectorAll('[data-p]').forEach((el) => el.style.setProperty('--p', el.dataset.p)));
}

/** Marks the characters of the full identifier that match the start of the search (dashes and braces kept). */
function highlightId(id, needle) {
  const text = String(id ?? '');
  if (!needle) return esc(text);
  const plain = text.toUpperCase().replace(/[^0-9A-F]/g, '');
  if (!plain.startsWith(needle)) return esc(text);
  let left = needle.length;
  let out = '';
  for (const ch of text) {
    if (left > 0 && /[0-9a-f]/i.test(ch)) { out += `<mark>${esc(ch)}</mark>`; left -= 1; } else out += esc(ch);
  }
  return out;
}

export { formatDateTime };
