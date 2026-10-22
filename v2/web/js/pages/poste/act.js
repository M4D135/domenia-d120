// Intervenir: what acts on the workstation or on its account, always through the write circuit (plan, confirmation,
// receipt, re-read) and never replayed automatically. The authorization of intervention (1 to 15 min, this workstation
// only) gates the program run; the Windows tools are opened by the launcher of the administration workstation (Windows
// asks the password of the operations account itself) or their command is copied, never with a password; the suite tools
// (Pesto, FILPRO) only receive declared, validated context fields, after their fingerprint is checked.
import { openDrawer, openDialog, confirmDialog, field, writeClipboard, debounce } from '../../kit/index.js';
import { runWrite } from '../../write-flow.js';
import { mountMachineAccount } from '../machine/panel.js';
import { reveal, toast, announce } from '../../ui.js';
import { esc, ico, rel, chip, empty, failure, cardHead, section, facts, paintMeters, errorText, NBSP, int, count, formatDateTime } from './common.js';

const MINUTES = [1, 2, 5, 10, 15];

const TOOLS = [
  { id: 'rdp', label: 'Bureau à distance', icon: 'monitor', key: 'mstsc', hint: 'Ouvre une session à distance : l’utilisateur connecté est déconnecté sur un poste client.' },
  { id: 'c', label: 'Dossier C$', icon: 'folder', key: 'unc', hint: 'Partage administratif du disque système, avec le compte d’exploitation quand il est déclaré (invite Windows).' },
  { id: 'compmgmt', label: 'Gestion de l’ordinateur', icon: 'settings', key: 'computerManagement', hint: 'Console MMC : disques, utilisateurs locaux, partages.' },
  { id: 'eventvwr', label: 'Observateur d’événements', icon: 'file', key: 'eventViewer', hint: 'Journaux du poste à distance (RPC requis).' },
  { id: 'services', label: 'Services', icon: 'tools', key: 'services', hint: 'Console des services du poste à distance (RPC requis).' },
];

/** Renders the Intervenir view; returns its cleanup. */
export function renderAct(panel, state) {
  let alive = true;
  const off = [];
  const local = { commands: null, span: null, account: null };

  const paint = () => {
    const d = state.data;
    const o = d.options;
    panel.innerHTML = `<div class="ps-act">
      ${section('Autorisation et actions sur le poste', 'Chaque action prépare un plan, demande votre confirmation, puis relit le résultat')}
      <div class="grid ps-grid">
        <section class="card ps-card ps-consent-card span-5 reveal" data-slot="consent"></section>
        <section class="card ps-card span-7 reveal">${cardHead('zap', 'Actions à distance', `Sur ${esc(d.computer.name)} · ${presenceText(d)}`)}
          <div class="ps-actions" data-slot="actions">${actionTiles(state)}</div></section>
      </div>
      ${section('Compte ordinateur dans l’annuaire', 'Écritures dans l’annuaire, relues après l’envoi')}
      <div class="grid ps-grid">
        <section class="card ps-card span-6 reveal">${accountCard(state)}</section>
        <section class="card ps-card span-6 reveal">${groupsCard(state)}</section>
      </div>
      ${section('Outils et commandes', o.operationsAccount ? `Compte d’exploitation${NBSP}: ${o.operationsAccount}` : 'Sans compte d’exploitation déclaré')}
      <div class="grid ps-grid">
        <section class="card ps-card span-7 reveal" data-slot="tools">${toolsCard(state, local)}</section>
        <section class="card ps-card span-5 reveal" data-slot="suite">${suiteCard(state)}</section>
      </div>
    </div>`;
    paintConsentCard();
    // MAC-002: the sentence « Opérations poste : … » in the card of the connection tools, mounted again with the card.
    local.account?.destroy();
    const accountHost = panel.querySelector('[data-slot="machine-account"]');
    local.account = accountHost ? mountMachineAccount(accountHost, state.ctx, { target: d.computer.name, show: 'sentence' }) : null;
    reveal(panel);
  };

  const paintConsentCard = () => {
    const host = panel.querySelector('[data-slot="consent"]');
    if (host) { host.innerHTML = consentCard(state, local); paintMeters(host); }
    reveal(host ?? panel);
  };

  const tick = () => {
    const c = state.data?.consent?.intervention;
    const host = panel.querySelector('[data-slot="consent"]');
    if (!host) return;
    const ring = host.querySelector('[data-countdown]');
    if (!c?.active || !c.until) {
      if (ring) paintConsentCard();
      return;
    }
    const left = Math.max(0, Math.round((Date.parse(c.until) - Date.now()) / 1000));
    if (left <= 0) {
      state.data.consent.intervention = { ...c, active: false };
      state.emit('consent', state.data.consent);
      return;
    }
    if (!ring) { paintConsentCard(); return; }
    const total = Math.max(left, (local.span ?? 5) * 60);
    ring.querySelector('.arc')?.style.setProperty('--p', String(left / total));
    const t = host.querySelector('[data-left]');
    if (t) t.textContent = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
  };

  const grant = async (kind) => {
    const select = panel.querySelector('[data-slot="consent"] select[name="minutes"]');
    const minutes = Number(select?.value ?? 5) || 5;
    const isRun = kind === 'intervention';
    const ok = await confirmDialog({
      title: isRun ? `Autoriser une intervention sur ce poste (${minutes}${NBSP}min)${NBSP}?` : 'Autoriser une seule lecture de repli\u00A0?',
      message: isRun
        ? `Pendant ${minutes}${NBSP}min, et sur ${state.data.computer.name} seulement, les actions qui laissent une trace sur le poste (tâche planifiée unique pour exécuter un programme) deviennent possibles. Chacune demandera encore sa propre confirmation. Rien n’est lancé maintenant.`
        : `Une seule lecture, sur ${state.data.computer.name} seulement, pourra passer par une tâche planifiée unique si CIM (DCOM et WinRM) refuse : inventaire, logiciels, diagnostic ou détection de l’utilisateur. Elle laisse une trace sur le poste. Rien n’est lancé maintenant.`,
      confirmLabel: 'Autoriser',
      icon: isRun ? 'zap' : 'shield',
    });
    if (!ok || !alive) return;
    try {
      const r = await state.call('poste.consent.grant', { dn: state.dn, kind, minutes });
      if (isRun) local.span = minutes;
      state.data.consent = r.consent;
      state.emit('consent', r.consent);
      announce(isRun ? `Intervention autorisée pour ${minutes} minutes.` : 'Lecture de repli autorisée.');
    } catch (err) {
      toast(errorText(err), { tone: 'alert' });
    }
  };

  const revoke = async (kind) => {
    try {
      const r = await state.call('poste.consent.revoke', { dn: state.dn, kind });
      state.data.consent = r.consent;
      state.emit('consent', r.consent);
      toast(kind === 'intervention' ? 'Autorisation d’intervention retirée.' : 'Lecture de repli retirée.', { tone: 'info' });
    } catch (err) {
      toast(errorText(err), { tone: 'alert' });
    }
  };

  const copyCommand = async (key, label) => {
    try {
      local.commands ??= await state.call('poste.commands', { dn: state.dn });
      if (!(await writeClipboard(local.commands[key]))) { toast('Copie impossible : le presse-papiers a refusé la commande.', { tone: 'alert' }); return; }
      toast(key === 'psRemote' ? local.commands.psStatus : `${label}${NBSP}: commande copiée.`, { tone: 'ok' });
    } catch (err) {
      toast(errorText(err), { tone: 'alert' });
    }
  };

  const openTool = async (tool) => {
    try {
      const r = await state.call('poste.tool.open', { dn: state.dn, tool });
      toast(r.text, { tone: r.launched ? 'ok' : 'info', life: r.simulated ? 7000 : 4800 });
    } catch (err) {
      toast(errorText(err), { tone: 'warn' });
    }
  };

  const onClick = async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-act]') : null;
    if (!b || !panel.contains(b) || b.disabled) return;
    if (b.getAttribute('aria-disabled') === 'true') { if (b.dataset.tip) toast(b.dataset.tip, { tone: 'info' }); return; }
    const act = b.dataset.act;
    const d = state.data;
    if (act === 'grant') grant(b.dataset.kind ?? 'intervention');
    else if (act === 'revoke') revoke(b.dataset.kind ?? 'intervention');
    else if (act === 'history') openHistory(state);
    else if (act === 'restart') openRestart(state);
    else if (act === 'restartCancel') runWrite(state.ctx, { plan: 'poste.restartCancel.plan', args: { dn: state.dn }, subtitle: d.computer.name, onDone: () => state.reload() });
    else if (act === 'gpupdate') runWrite(state.ctx, { plan: 'poste.gpupdate.plan', args: { dn: state.dn }, subtitle: d.computer.name, onDone: () => state.reload() });
    else if (act === 'wake') runWrite(state.ctx, { plan: 'poste.wake.plan', args: { dn: state.dn }, subtitle: d.computer.name, onDone: () => state.reload() });
    else if (act === 'run') {
      if (!d.consent?.intervention?.active) {
        toast('Accordez d’abord l’autorisation d’intervention (carte de gauche)\u00A0: elle vaut pour ce seul poste.', { tone: 'warn' });
        panel.querySelector('[data-slot="consent"] [data-act="grant"]')?.focus();
        return;
      }
      openRun(state);
    } else if (act === 'services') state.go('inventaire', 'services');
    else if (act === 'sessions') state.go('inventaire', 'sessions');
    else if (act === 'account') runWrite(state.ctx, { plan: 'poste.account.plan', args: { dn: state.dn, enable: b.dataset.enable === 'true' }, subtitle: d.computer.name, onDone: () => state.reload() });
    else if (act === 'rename') openRename(state);
    else if (act === 'move') openMove(state);
    else if (act === 'profile') openProfile(state);
    else if (act === 'groupAdd') openGroupAdd(state);
    else if (act === 'groupRemove') runWrite(state.ctx, { plan: 'poste.group.plan', args: { dn: state.dn, group: b.dataset.group, add: false }, subtitle: d.computer.name, onDone: () => state.reload() });
    else if (act === 'copy') copyCommand(b.dataset.key, b.dataset.label ?? '');
    else if (act === 'tool') openTool(b.dataset.tool);
    else if (act === 'suite') openSuite(state, b.dataset.tool);
    else if (act === 'suiteLaunch') launchSuite(state, b.dataset.tool);
    else if (act === 'fiche') state.ctx.navigate('fiche', { dn: state.dn });
  };
  const onChange = (e) => {
    if (e.target instanceof HTMLSelectElement && e.target.name === 'minutes') local.span = Number(e.target.value) || 5;
  };
  panel.addEventListener('click', onClick);
  panel.addEventListener('change', onChange);
  paint();
  off.push(state.on('console', () => { if (alive) { local.commands = null; paint(); } }));
  off.push(state.on('consent', () => {
    if (!alive) return;
    paintConsentCard();
    const actions = panel.querySelector('[data-slot="actions"]');
    if (actions) actions.innerHTML = actionTiles(state);
  }));
  off.push(state.on('run', (r) => { if (alive && r?.what === 'restart') openRestart(state); }));
  const timer = setInterval(() => { if (alive) tick(); }, 1000);
  if (state.panneau === 'redemarrer') openRestart(state);
  else if (state.panneau === 'executer' && state.data.consent?.intervention?.active) openRun(state);
  else if (state.panneau === 'groupe') openGroupAdd(state);
  else if (state.panneau === 'deplacer') openMove(state);
  else if (state.panneau === 'fiche') openProfile(state);

  return () => {
    alive = false;
    clearInterval(timer);
    off.forEach((fn) => fn());
    local.account?.destroy();
    panel.removeEventListener('click', onClick);
    panel.removeEventListener('change', onChange);
  };
}

// ---------- Cards ----------

function presenceText(d) {
  const p = d.header.presence;
  return p.state === 'online' ? 'répond au ping' : p.state === 'offline' ? 'ne répond pas au ping' : 'présence non vérifiée';
}

function consentCard(state, local) {
  const c = state.data.consent ?? {};
  const run = c.intervention ?? { active: false, text: '' };
  const fallback = c.readFallback ?? { active: false, text: '' };
  const left = run.active && run.until ? Math.max(0, Math.round((Date.parse(run.until) - Date.now()) / 1000)) : 0;
  const total = Math.max(left, (local.span ?? 5) * 60);
  const p = run.active ? left / total : 0;
  const options = MINUTES.map((m) => ({ value: String(m), label: `${m}${NBSP}min` }));
  const ring = `<div class="ps-countdown" data-countdown data-tone="${run.active ? 'ok' : 'off'}" role="img" aria-label="${esc(run.active ? run.text : 'Aucune autorisation active')}">
      <svg viewBox="0 0 120 120" aria-hidden="true"><circle class="trk" cx="60" cy="60" r="50"/><circle class="arc" cx="60" cy="60" r="50" pathLength="100" data-p="${p.toFixed(3)}"/></svg>
      <div class="ps-countdown-c">${run.active ? `<b data-left>${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}</b><span>restantes</span>` : `${ico('lock')}<span>verrouillé</span>`}</div></div>`;
  const body = run.active
    ? `<p class="ps-consent-text"><b>Intervention autorisée</b> jusqu’à ${esc(formatTime(run.until))} sur ce seul poste. Chaque action demande encore sa confirmation.</p>
       <div class="ps-row-actions"><button class="btn sm" type="button" data-act="revoke" data-kind="intervention">${ico('x')}Retirer maintenant</button>
       <button class="btn ghost sm" type="button" data-act="grant" data-kind="intervention">${ico('refresh')}Prolonger</button></div>`
    : `<p class="ps-consent-text">${run.otherComputer ? `Une autorisation est active sur <b>${esc(run.otherComputer)}</b>, pas sur ce poste. ` : ''}Exécuter un programme sur le poste demande une autorisation d’intervention, limitée dans le temps et à ce seul poste.</p>
       <div class="ps-consent-form">${field({ name: 'minutes', label: 'Durée', type: 'select', value: String(local.span ?? 5), options, width: 'third' })}
       <button class="btn primary sm" type="button" data-act="grant" data-kind="intervention">${ico('zap')}Autoriser une intervention</button></div>`;
  return `${cardHead('shield', 'Autorisation d’intervention', 'Pour ce poste, de 1 à 15 minutes', `<button class="btn ghost xs" type="button" data-act="history">${ico('history')}Historique</button>`, run.active ? 'ok' : 'info')}
    <div class="ps-consent-body">${ring}<div class="ps-consent-main">${body}</div></div>
    <div class="ps-consent-fallback" data-active="${fallback.active ? 'true' : 'false'}">${ico('layers')}<div><b>Lecture de repli</b><span>${esc(fallback.active ? fallback.text : 'Si CIM (DCOM et WinRM) refuse, une seule lecture peut passer par une tâche planifiée unique, qui laisse une trace sur le poste. Sans cette autorisation, la lecture rend « non lu ».')}</span></div>
      ${fallback.active ? `<button class="btn sm" type="button" data-act="revoke" data-kind="readFallback">${ico('x')}Retirer</button>` : `<button class="btn sm ps-fallback-btn" type="button" data-act="grant" data-kind="readFallback" data-tip="Laisse une trace sur le poste : une tâche planifiée unique, créée puis supprimée">${ico('shield')}Autoriser une lecture de repli…</button>`}</div>`;
}

function formatTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

function actionTiles(state) {
  const d = state.data;
  const o = d.options;
  const online = d.header.presence.state === 'online';
  const consent = d.consent?.intervention?.active === true;
  const tiles = [
    { act: 'restart', icon: 'restart', tone: 'alert', title: 'Redémarrer…', text: 'Différé avec message (5 à 60 min) ou immédiat. Les sessions ouvertes sont lues avant.',
      chips: [chip(o.useWinRm ? 'info' : 'warn', o.useWinRm ? 'WinRM' : 'Immédiat seulement', o.useWinRm ? 'Le redémarrage différé passe par WinRM.' : 'WinRM désactivé par la configuration : seul le redémarrage immédiat est possible.')] },
    { act: 'restartCancel', icon: 'undo', tone: 'info', title: 'Annuler un redémarrage', text: 'Annule un redémarrage différé encore en attente (shutdown /a).', chips: [] },
    { act: 'gpupdate', icon: 'gpo', tone: 'accent', title: 'Actualiser les stratégies', text: 'gpupdate /force par WinRM, sans fermer la session de l’utilisateur.',
      disabled: !o.useWinRm, reason: 'WinRM est désactivé par la configuration (Remote.UseWinRM).', chips: [] },
    { act: 'run', icon: 'terminal', tone: consent ? 'ok' : 'warn', title: 'Exécuter un programme…', text: 'Tâche planifiée unique, créée puis supprimée, en arrière-plan ou dans la session ouverte.',
      chips: [consent ? chip('ok', 'Autorisé') : chip('warn', 'Autorisation requise', 'Accordez l’autorisation d’intervention pour ce poste.')] },
    { act: 'wake', icon: 'wake', tone: 'info', title: 'Réveiller le poste', text: online ? 'Le poste répond déjà au ping : un réveil est inutile.' : 'Paquet Wake-on-LAN vers ce seul poste, sous-réseau autorisé.',
      disabled: !o.wakeOnLan, reason: o.wakeReason, chips: o.wakeOnLan ? [chip('info', `${o.wakeNetworks.length} réseau${o.wakeNetworks.length > 1 ? 'x' : ''} autorisé${o.wakeNetworks.length > 1 ? 's' : ''}`, o.wakeNetworks.join(', '))] : [] },
    { act: 'services', icon: 'tools', tone: 'accent', title: 'Services du poste', text: 'Démarrer, redémarrer ou arrêter un service depuis la liste lue.', chips: [], nav: true },
  ];
  return tiles.map((t, n) => `<button class="ps-action spot" type="button" data-act="${t.act}" data-tone="${t.tone}" data-i="${n}"${t.disabled ? ` aria-disabled="true" data-tip="${esc(t.reason)}"` : ''}>
      <span class="ps-action-ico">${ico(t.icon)}</span>
      <span class="ps-action-body"><b>${esc(t.title)}</b><span>${esc(t.disabled ? t.reason : t.text)}</span>
      ${t.chips.length ? `<span class="ps-action-chips">${t.chips.join('')}</span>` : ''}</span>
      <span class="ps-action-go" data-kind="${t.nav ? 'nav' : t.disabled ? 'lock' : 'go'}" aria-hidden="true">${ico(t.nav ? 'chevronRight' : t.disabled ? 'lock' : 'arrowUp')}</span></button>`).join('');
}

function accountCard(state) {
  const c = state.data.computer;
  const enabled = c.enabled;
  const status = enabled === true ? chip('ok', 'Compte actif') : enabled === false ? chip('alert', 'Compte désactivé') : chip('warn', 'État non lu');
  const action = enabled === true
    ? `<button class="btn sm danger" type="button" data-act="account" data-enable="false">${ico('power')}Désactiver le compte…</button>`
    : enabled === false ? `<button class="btn sm" type="button" data-act="account" data-enable="true">${ico('power')}Activer le compte…</button>` : `<span class="ps-note warn">${ico('alert')}userAccountControl illisible : relisez la fiche avant toute action sur le compte.</span>`;
  const line = (label, value, tip = '') => `<div class="ps-kv"><span>${esc(label)}</span><b${tip ? ` data-tip="${esc(tip)}"` : ''}>${value}</b></div>`;
  return `${cardHead('monitor', 'Objet ordinateur', esc(c.accountText), status, enabled === false ? 'alert' : 'info')}
    <div class="ps-kvs">
      ${line('Nom (sAMAccountName)', `<span class="mono">${esc(c.samAccountName)}</span>`)}
      ${line('Emplacement dans l’annuaire', esc(c.ou.path), c.ou.dn)}
      ${line('Description', c.description ? esc(c.description) : '<span class="ps-faint">Non renseignée</span>')}
      ${line('Emplacement physique', c.location ? esc(c.location) : '<span class="ps-faint">Non renseigné</span>')}
      ${line('Géré par', c.managedBy ? esc(c.managedBy.name) : '<span class="ps-faint">Personne</span>', c.managedBy?.dn ?? '')}
    </div>
    <div class="ps-row-actions wrap">${action}
      <button class="btn sm" type="button" data-act="profile">${ico('edit')}Modifier la fiche…</button>
      <button class="btn sm" type="button" data-act="rename">${ico('tag')}Renommer…</button>
      <button class="btn sm" type="button" data-act="move">${ico('ou')}Déplacer…</button>
      <button class="btn ghost sm" type="button" data-act="fiche">${ico('external')}Fiche complète</button></div>`;
}

function groupsCard(state) {
  const c = state.data.computer;
  const groups = c.groups ?? [];
  const list = groups.length
    ? `<ul class="ps-groups">${groups.map((g, n) => `<li class="ps-group reveal" data-i="${n}"><span class="ps-group-ico">${ico('group')}</span><span class="ps-group-name" data-tip="${esc(g.dn)}">${esc(g.name)}</span>
        <button class="btn ghost xs icon-only" type="button" data-act="groupRemove" data-group="${esc(g.dn)}" aria-label="Retirer ${esc(c.name)} du groupe ${esc(g.name)}" data-tip="Retirer du groupe…">${ico('minus')}</button></li>`).join('')}</ul>`
    : empty({ icon: 'group', title: 'Aucun groupe explicite', text: 'Le poste n’est membre que de son groupe principal (Ordinateurs du domaine), qui n’est pas listé ici.' });
  return `${cardHead('group', 'Groupes du poste', `${count(groups.length, 'groupe explicite', 'groupes explicites')} (memberOf)`, `<button class="btn sm" type="button" data-act="groupAdd">${ico('plus')}Ajouter…</button>`)}
    ${list}
    <p class="ps-note">${ico('info')}Une appartenance s’applique au prochain démarrage du poste (jeton Kerberos de l’ordinateur).</p>`;
}

function toolsCard(state, local) {
  const launcher = state.host.toolLauncher === true;
  const o = state.data.options;
  const why = 'Aucun lanceur d’outils dans cet affichage : copiez la commande.';
  const tip = state.simulation ? 'Simulation : la commande qui serait lancée est montrée, rien n’est ouvert vers un poste fictif.' : 'Ouvert depuis ce poste d’administration';
  const row = (t) => `<li class="ps-tool"><span class="ps-tool-ico">${ico(t.icon)}</span>
      <div class="ps-tool-body"><b>${esc(t.label)}</b><span>${esc(t.hint)}</span></div>
      <div class="ps-tool-actions"><button class="btn ghost sm" type="button" data-act="copy" data-key="${t.key}" data-label="${esc(t.label)}">${ico('copy')}Copier</button>
      <button class="btn sm" type="button" data-act="tool" data-tool="${t.id}"${launcher ? ` data-tip="${esc(tip)}"` : ` aria-disabled="true" data-tip="${esc(why)}"`}>${ico('external')}Ouvrir</button></div></li>`;
  return `${cardHead('terminal', 'Outils Windows et PowerShell', 'Ouverts depuis le poste d’administration, ou commandes prêtes à coller ; jamais de mot de passe copié')}
    <ul class="ps-tools">${TOOLS.map(row).join('')}</ul>
    <div class="ps-ps">
      <div class="ps-ps-account" data-slot="machine-account"></div>
      <div class="ps-ps-line"><span class="ps-ps-label">${ico('terminal')}Session PowerShell distante</span><button class="btn sm" type="button" data-act="copy" data-key="psRemote" data-label="Enter-PSSession">${ico('copy')}Copier Enter-PSSession</button></div>
      <div class="ps-ps-line"><span class="ps-ps-label">${ico('play')}Commande ponctuelle</span><button class="btn sm" type="button" data-act="copy" data-key="invokeCommand" data-label="Invoke-Command">${ico('copy')}Copier Invoke-Command</button></div>
      <p class="ps-note">${ico('lock')}${o.operationsAccount ? `Avec le compte ${esc(o.operationsAccount)}${NBSP}: Windows demandera son mot de passe, qui n’est jamais copié ni enregistré.` : 'Aucun compte d’exploitation déclaré : la commande utilise votre session Windows.'}</p>
    </div>`;
}

function suiteCard(state) {
  const tools = state.data.options.suiteTools ?? [];
  const launcher = state.host.toolLauncher === true;
  return `${cardHead('sparkles', 'Outils de la suite', 'Ouverture avec le contexte du poste : champs déclarés par l’outil seulement')}
    <ul class="ps-suite">${tools.map((t) => {
      const canOpen = t.configured && launcher;
      const why = !t.configured ? t.reason : 'Aucun lanceur d’outils dans cet affichage.';
      return `<li class="ps-suite-row" data-configured="${t.configured ? 'true' : 'false'}"><span class="ps-suite-logo" aria-hidden="true">${esc(t.label.slice(0, 1))}</span>
      <div><b>${esc(t.label)}</b><span>${esc(t.configured ? `Champs possibles${NBSP}: ${t.fields.join(', ')}` : t.reason)}</span></div>
      <div class="ps-suite-actions"><button class="btn ghost sm" type="button" data-act="suite" data-tool="${esc(t.id)}">${ico('eye')}Voir le plan</button>
      <button class="btn sm" type="button" data-act="suiteLaunch" data-tool="${esc(t.id)}"${canOpen ? '' : ` aria-disabled="true" data-tip="${esc(why)}"`}>${ico('external')}Ouvrir</button></div></li>`;
    }).join('')}</ul>
    <p class="ps-note">${ico('shield')}Avant toute ouverture : empreinte SHA-256 de l’exécutable comparée à la configuration, contrat suite-contract.json relu${NBSP}; sans contrat reconnu, l’outil s’ouvre sans argument.</p>`;
}

// ---------- Drawers ----------

function openHistory(state) {
  const dr = openDrawer({ title: 'Autorisations de la session', subtitle: 'Accordées, retirées, expirées ou utilisées', icon: 'history', key: 'poste.drawer', width: 520 });
  dr.el.classList.add('poste-drw');
  dr.body.innerHTML = `<div class="ps-sk-stack" aria-busy="true"><span class="skeleton ps-sk w85"></span><span class="skeleton ps-sk w70"></span><span class="skeleton ps-sk w55"></span></div>`;
  state.call('poste.consent.history').then((list) => {
    dr.body.innerHTML = list.length
      ? `<ol class="ps-history">${list.slice().reverse().map((h) => `<li data-kind="${esc(h.kind)}"><span class="ps-history-dot" aria-hidden="true"></span><div><b>${esc(h.action)}</b> · ${esc(h.kind === 'intervention' ? 'Intervention' : 'Lecture de repli')} · ${esc(h.computer)}
          <span class="ps-faint">${esc(formatDateTime(h.at) ?? '')}${h.detail ? ` · ${esc(h.detail)}` : ''}</span></div></li>`).join('')}</ol>`
      : empty({ icon: 'history', title: 'Aucune autorisation dans cette session', text: 'Les autorisations accordées, retirées ou expirées s’affichent ici, avec leur heure.' });
  }).catch((err) => { dr.body.innerHTML = failure(err, { retry: '' }); });
}

/** Restart panel: sessions read first, delayed with a message (WinRM) or immediate (typed confirmation). */
function openRestart(state) {
  const d = state.data;
  const o = d.options;
  const minutes = (o.restartMinutes?.length ? o.restartMinutes : [5, 15, 30, 60]);
  const def = Math.round((o.restartDelaySeconds ?? 300) / 60);
  const dr = openDrawer({
    title: `Redémarrer ${d.computer.name}`,
    subtitle: 'Les sessions ouvertes sont lues avant tout plan',
    icon: 'power',
    key: 'poste.drawer',
    width: 560,
    focusFirst: true,
    actions: [
      { id: 'cancel', label: 'Fermer', run: (ctl) => ctl.close() },
      { id: 'go', label: 'Préparer le redémarrage', icon: 'power', danger: true, run: (ctl) => submit(ctl) },
    ],
  });
  dr.el.classList.add('poste-drw');
  // « Maintenant » is never chosen by default (Domenia 1 PST-013): delayed when WinRM allows it, otherwise nothing.
  dr.body.innerHTML = `<form class="k-form ps-form" data-form="restart" novalidate>
      <div class="ps-restart-sessions" data-slot="sessions" aria-busy="true">${ico('users')}<div><b>Sessions ouvertes</b><span>Lecture des sessions du poste…</span></div></div>
      ${field({ name: 'mode', label: 'Mode', type: 'radio', value: o.useWinRm ? 'delayed' : '', options: [
        { value: 'delayed', label: 'Différé, avec un message à l’utilisateur', disabled: !o.useWinRm },
        { value: 'now', label: 'Immédiat et forcé, sans message (le travail non enregistré est perdu)' },
      ] })}
      <div class="ps-delayed" data-slot="delayed">
        ${field({ name: 'minutes', label: 'Délai', type: 'select', value: String(minutes.includes(def) ? def : minutes[0]), options: minutes.map((m) => ({ value: String(m), label: `${m}${NBSP}minutes` })), width: 'half' })}
        ${field({ name: 'message', label: 'Message affiché sur le poste', type: 'textarea', maxLength: 400, placeholder: 'Laisser vide pour le message par défaut (délai et conseil d’enregistrer).', hint: 'Affiché par Windows dans la session ouverte. 400 caractères au plus.' })}
      </div>
      ${o.useWinRm ? '' : `<p class="ps-note warn">${ico('alert')}WinRM est désactivé par la configuration : le redémarrage différé est indisponible. Choisissez explicitement « Immédiat » si l’utilisateur est prévenu.</p>`}
      <p class="ps-note">${ico('shield')}Rien n’est envoyé avant la confirmation du plan. Un redémarrage immédiat demande de taper le nom du poste.</p>
    </form>`;
  const form = dr.body.querySelector('form');
  const go = dr.foot?.querySelector('[data-id="go"]');
  const sync = () => {
    const mode = form.querySelector('input[name="mode"]:checked')?.value ?? '';
    form.querySelector('[data-slot="delayed"]').hidden = mode !== 'delayed';
    if (go) {
      go.disabled = !mode;
      if (mode) go.removeAttribute('data-tip'); else go.dataset.tip = 'Choisissez d’abord le mode du redémarrage.';
    }
  };
  form.addEventListener('change', sync);
  form.addEventListener('submit', (e) => e.preventDefault());
  sync();
  state.call('poste.restart.sessions', { dn: state.dn }).then((r) => {
    const host = dr.body.querySelector('[data-slot="sessions"]');
    if (!host) return;
    host.removeAttribute('aria-busy');
    host.dataset.tone = !r.known ? 'warn' : r.count > 0 ? 'alert' : 'ok';
    host.innerHTML = `${ico(!r.known ? 'alert' : r.count > 0 ? 'users' : 'check')}<div><b>${esc(!r.known ? 'Sessions non lues' : r.count > 0 ? `${int(r.count)} session${r.count > 1 ? 's' : ''} ouverte${r.count > 1 ? 's' : ''}` : 'Aucune session ouverte')}</b>
      <span>${esc(r.text)}</span>${r.lines?.length ? `<ul>${r.lines.map((l) => `<li>${esc(l)}</li>`).join('')}</ul>` : ''}</div>`;
  }).catch((err) => {
    const host = dr.body.querySelector('[data-slot="sessions"]');
    if (host) { host.removeAttribute('aria-busy'); host.dataset.tone = 'warn'; host.innerHTML = `${ico('alert')}<div><b>Sessions non lues</b><span>${esc(errorText(err))}</span></div>`; }
  });

  function submit(ctl) {
    const mode = form.querySelector('input[name="mode"]:checked')?.value ?? '';
    if (!mode) { toast('Choisissez d’abord le mode du redémarrage : rien n’est choisi pour vous.', { tone: 'warn' }); return; }
    const args = { dn: state.dn, mode };
    if (mode === 'delayed') {
      args.minutes = Number(form.querySelector('select[name="minutes"]').value);
      const message = form.querySelector('textarea[name="message"]').value.trim();
      if (message) args.message = message;
    }
    ctl.close();
    runWrite(state.ctx, { plan: 'poste.restart.plan', args, subtitle: d.computer.name, onDone: () => state.reload() });
  }
}

/** Program run panel (authorization of intervention required, checked again by the engine). */
function openRun(state) {
  const d = state.data;
  const user = d.live?.consoleUser?.login ?? d.association.user?.login ?? '';
  const dr = openDrawer({
    title: `Exécuter un programme sur ${d.computer.name}`,
    subtitle: 'Tâche planifiée unique, créée puis supprimée',
    icon: 'play',
    key: 'poste.drawer',
    width: 560,
    focusFirst: true,
    actions: [
      { id: 'cancel', label: 'Fermer', run: (ctl) => ctl.close() },
      { id: 'go', label: 'Préparer l’exécution', icon: 'play', primary: true, run: (ctl) => submit(ctl) },
    ],
  });
  dr.el.classList.add('poste-drw');
  dr.body.innerHTML = `<form class="k-form ps-form" novalidate>
      ${field({ name: 'command', label: 'Programme', required: true, mono: true, maxLength: 260, placeholder: 'C:\\Windows\\System32\\notepad.exe', hint: 'Chemin complet d’un exécutable (.exe, .cmd, .bat, .ps1) présent sur le poste.' })}
      ${field({ name: 'arguments', label: 'Arguments', mono: true, maxLength: 1024, hint: 'Gardés en mémoire jusqu’à l’envoi seulement : ni le plan ni le reçu ne les contiennent (longueur seule). Évitez tout secret : la tâche planifiée les voit pendant son exécution.' })}
      ${field({ name: 'mode', label: 'Où', type: 'radio', value: 'system', options: [
        { value: 'system', label: 'En arrière-plan, compte système, sans fenêtre' },
        { value: 'interactive', label: 'Dans la session ouverte d’un utilisateur' },
      ] })}
      <div data-slot="user">${field({ name: 'user', label: 'Compte de la session', value: user, mono: true, maxLength: 120, placeholder: 'DOMAINE\\identifiant', width: 'half' })}</div>
      ${field({ name: 'elevated', label: 'Niveau le plus élevé', type: 'switch', value: true })}
      <p class="ps-note">${ico('info')}L’exécution du programme n’est pas vérifiée : seul l’envoi de la tâche l’est.</p>
    </form>`;
  const form = dr.body.querySelector('form');
  const sync = () => { form.querySelector('[data-slot="user"]').hidden = form.querySelector('input[name="mode"]:checked')?.value !== 'interactive'; };
  form.addEventListener('change', sync);
  form.addEventListener('submit', (e) => e.preventDefault());
  sync();

  function submit(ctl) {
    const value = (n) => form.querySelector(`[name="${n}"]`);
    const command = value('command').value.trim();
    if (!command) { value('command').focus(); toast('Indiquez le programme à exécuter.', { tone: 'warn' }); return; }
    const mode = form.querySelector('input[name="mode"]:checked')?.value ?? 'system';
    const args = { dn: state.dn, mode, command, elevated: value('elevated').checked };
    const a = value('arguments').value.trim();
    if (a) args.arguments = a;
    if (mode === 'interactive') args.user = value('user').value.trim();
    ctl.close();
    runWrite(state.ctx, { plan: 'poste.run.plan', args, subtitle: d.computer.name, onDone: () => state.reload() });
  }
}

function openRename(state) {
  const c = state.data.computer;
  const dr = openDrawer({
    title: `Renommer ${c.name} dans l’annuaire`,
    subtitle: 'Objet ordinateur seulement',
    icon: 'tag',
    key: 'poste.drawer',
    width: 520,
    focusFirst: true,
    actions: [
      { id: 'cancel', label: 'Fermer', run: (ctl) => ctl.close() },
      { id: 'go', label: 'Préparer le renommage', icon: 'edit', primary: true, run: (ctl) => submit(ctl) },
    ],
  });
  dr.el.classList.add('poste-drw');
  dr.body.innerHTML = `<form class="k-form ps-form" novalidate>
      ${field({ name: 'name', label: 'Nouveau nom de l’objet (CN)', value: c.name, required: true, mono: true, maxLength: 63, pattern: '[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?', patternMessage: 'Lettres, chiffres et tirets, 63 caractères au plus, sans tiret au début ni à la fin.' })}
      <p class="ps-note">${ico('info')}Seul le nom de l’objet change dans l’annuaire : le nom de compte (${esc(c.samAccountName)}), le nom DNS et le nom Windows du poste restent, il continue de s’authentifier.</p>
      <p class="ps-note warn">${ico('alert')}Les listes afficheront le nouveau nom pour un poste qui garde son nom Windows : renommez le poste lui-même par ailleurs si c’est le but.</p>
    </form>`;
  const form = dr.body.querySelector('form');
  form.addEventListener('submit', (e) => e.preventDefault());
  function submit(ctl) {
    const input = form.querySelector('input[name="name"]');
    const name = input.value.trim();
    if (!/^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(name)) { input.focus(); toast('Nom refusé : lettres, chiffres et tirets, 63 caractères au plus, sans tiret au début ni à la fin.', { tone: 'warn' }); return; }
    if (name.toUpperCase() === c.name.toUpperCase()) { toast('Le nom est inchangé : rien à préparer.', { tone: 'info' }); return; }
    ctl.close();
    runWrite(state.ctx, { plan: 'poste.rename.plan', args: { dn: state.dn, name }, subtitle: c.name, onDone: () => afterMove(state) });
  }
}

/** After a rename or a move the DN changes: the console is opened again by name. */
async function afterMove(state) {
  try {
    const list = await state.call('poste.list', { text: state.data.computer.name, limit: 5 });
    const row = list.rows.find((r) => r.guid === state.data.computer.guid) ?? null;
    if (row && row.dn !== state.dn) { state.ctx.navigate('poste', { dn: row.dn, vue: 'intervenir' }); return; }
  } catch (err) {
    console.error(err);
  }
  await state.reload().catch((err) => toast(errorText(err), { tone: 'warn' }));
}

function openMove(state) {
  const c = state.data.computer;
  let chosen = null;
  const dr = openDrawer({
    title: `Déplacer ${c.name}`,
    subtitle: `Depuis ${c.ou.path}`,
    icon: 'ou',
    key: 'poste.drawer',
    width: 560,
    focusFirst: true,
    actions: [
      { id: 'cancel', label: 'Fermer', run: (ctl) => ctl.close() },
      { id: 'go', label: 'Préparer le déplacement', icon: 'ou', primary: true, run: (ctl) => submit(ctl) },
    ],
  });
  dr.el.classList.add('poste-drw');
  dr.body.innerHTML = `<div class="ps-picklist">
      ${field({ name: 'q', label: 'OU de destination', type: 'search', placeholder: 'Nom ou chemin de l’OU (au moins 2 caractères)', maxLength: 100 })}
      <ul class="ps-pick" role="listbox" aria-label="OU trouvées" data-slot="list"></ul>
      <p class="ps-note">${ico('info')}Les stratégies de groupe de la nouvelle OU s’appliquent au prochain démarrage du poste.</p></div>`;
  const list = dr.body.querySelector('[data-slot="list"]');
  const input = dr.body.querySelector('input[name="q"]');
  list.innerHTML = `<li class="ps-pick-empty">${esc('Tapez une partie du nom de l’OU.')}</li>`;
  let seq = 0;
  const search = debounce(async () => {
    const text = input.value.trim();
    const n = ++seq;
    if (text.length < 2) { list.innerHTML = `<li class="ps-pick-empty">Tapez au moins 2 caractères.</li>`; return; }
    list.setAttribute('aria-busy', 'true');
    try {
      const rows = await state.call('directory.ou.search', { text });
      if (n !== seq) return;
      list.innerHTML = rows.length ? rows.map((r) => `<li role="option" tabindex="0" aria-selected="false" data-dn="${esc(r.dn)}"${r.dn === c.ou.dn ? ' aria-disabled="true"' : ''}>${ico('ou')}<span><b>${esc(r.name)}</b><small>${esc(r.path)}${r.dn === c.ou.dn ? ' · OU actuelle' : ''}</small></span></li>`).join('')
        : '<li class="ps-pick-empty">Aucune OU ne correspond.</li>';
    } catch (err) {
      if (n === seq) list.innerHTML = `<li class="ps-pick-empty">${esc(errorText(err))}</li>`;
    } finally {
      if (n === seq) list.removeAttribute('aria-busy');
    }
  }, 220);
  input.addEventListener('input', search);
  const pick = (li) => {
    if (!li || li.getAttribute('aria-disabled') === 'true') return;
    list.querySelectorAll('[aria-selected="true"]').forEach((x) => x.setAttribute('aria-selected', 'false'));
    li.setAttribute('aria-selected', 'true');
    chosen = { dn: li.dataset.dn, name: li.querySelector('b')?.textContent ?? '' };
  };
  list.addEventListener('click', (e) => pick(e.target instanceof Element ? e.target.closest('li[data-dn]') : null));
  list.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(e.target instanceof Element ? e.target.closest('li[data-dn]') : null); } });
  function submit(ctl) {
    if (!chosen) { toast('Choisissez l’OU de destination dans la liste.', { tone: 'warn' }); input.focus(); return; }
    ctl.close();
    runWrite(state.ctx, { plan: 'poste.move.plan', args: { dn: state.dn, ou: chosen.dn }, subtitle: c.name, onDone: () => afterMove(state) });
  }
}

function openGroupAdd(state) {
  const c = state.data.computer;
  const member = new Set((c.groups ?? []).map((g) => g.dn.toLowerCase()));
  let chosen = null;
  const dr = openDrawer({
    title: `Ajouter ${c.name} à un groupe`,
    subtitle: 'Groupes de l’annuaire',
    icon: 'group',
    key: 'poste.drawer',
    width: 520,
    focusFirst: true,
    actions: [
      { id: 'cancel', label: 'Fermer', run: (ctl) => ctl.close() },
      { id: 'go', label: 'Préparer l’ajout', icon: 'plus', primary: true, run: (ctl) => submit(ctl) },
    ],
  });
  dr.el.classList.add('poste-drw');
  dr.body.innerHTML = `<div class="ps-picklist">
      ${field({ name: 'q', label: 'Groupe', type: 'search', placeholder: 'Nom du groupe', maxLength: 100 })}
      <ul class="ps-pick" role="listbox" aria-label="Groupes trouvés" data-slot="list"></ul></div>`;
  const list = dr.body.querySelector('[data-slot="list"]');
  const input = dr.body.querySelector('input[name="q"]');
  let seq = 0;
  const search = async () => {
    const n = ++seq;
    list.setAttribute('aria-busy', 'true');
    try {
      const rows = await state.call('poste.groups.search', { text: input.value.trim() });
      if (n !== seq) return;
      list.innerHTML = rows.length ? rows.map((g) => {
        const already = member.has(g.dn.toLowerCase());
        return `<li role="option" tabindex="0" aria-selected="false" data-dn="${esc(g.dn)}"${already ? ' aria-disabled="true"' : ''}>${ico('group')}<span><b>${esc(g.name)}</b><small>${esc(already ? 'Déjà membre' : g.dn)}</small></span></li>`;
      }).join('') : '<li class="ps-pick-empty">Aucun groupe ne correspond.</li>';
    } catch (err) {
      if (n === seq) list.innerHTML = `<li class="ps-pick-empty">${esc(errorText(err))}</li>`;
    } finally {
      if (n === seq) list.removeAttribute('aria-busy');
    }
  };
  input.addEventListener('input', debounce(search, 200));
  search();
  const pick = (li) => {
    if (!li || li.getAttribute('aria-disabled') === 'true') return;
    list.querySelectorAll('[aria-selected="true"]').forEach((x) => x.setAttribute('aria-selected', 'false'));
    li.setAttribute('aria-selected', 'true');
    chosen = { dn: li.dataset.dn };
  };
  list.addEventListener('click', (e) => pick(e.target instanceof Element ? e.target.closest('li[data-dn]') : null));
  list.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(e.target instanceof Element ? e.target.closest('li[data-dn]') : null); } });
  function submit(ctl) {
    if (!chosen) { toast('Choisissez un groupe dans la liste.', { tone: 'warn' }); input.focus(); return; }
    ctl.close();
    runWrite(state.ctx, { plan: 'poste.group.plan', args: { dn: state.dn, group: chosen.dn, add: true }, subtitle: c.name, onDone: () => state.reload() });
  }
}

function openProfile(state) {
  const c = state.data.computer;
  const assoc = state.data.association.user;
  const options = [{ value: '', label: 'Personne' }];
  if (c.managedBy) options.push({ value: c.managedBy.dn, label: `${c.managedBy.name} (actuel)` });
  if (assoc?.dn && assoc.dn !== c.managedBy?.dn) options.push({ value: assoc.dn, label: `${assoc.name} (utilisateur associé, ${state.data.association.badgeLabel.toLowerCase()})` });
  const dr = openDrawer({
    title: `Fiche de ${c.name}`,
    subtitle: 'Description, emplacement, géré par',
    icon: 'edit',
    key: 'poste.drawer',
    width: 560,
    focusFirst: true,
    actions: [
      { id: 'cancel', label: 'Fermer', run: (ctl) => ctl.close() },
      { id: 'go', label: 'Préparer l’enregistrement', icon: 'check', primary: true, run: (ctl) => submit(ctl) },
    ],
  });
  dr.el.classList.add('poste-drw');
  dr.body.innerHTML = `<form class="k-form ps-form" novalidate>
      ${field({ name: 'description', label: 'Description', value: c.description ?? '', maxLength: 1024, hint: 'Visible dans l’annuaire et dans les listes de Domenia.' })}
      ${field({ name: 'location', label: 'Emplacement physique', value: c.location ?? '', maxLength: 1024, placeholder: 'Bâtiment, étage, bureau' })}
      ${field({ name: 'managedBy', label: 'Géré par', type: 'select', value: c.managedBy?.dn ?? '', options })}
      ${assoc && !assoc.dn ? `<p class="ps-note">${ico('info')}L’utilisateur associé (${esc(assoc.name)}) n’a pas de nom distinctif connu : il ne peut pas être choisi comme gestionnaire.</p>` : ''}
      <p class="ps-note">${ico('shield')}Seuls les attributs modifiés sont envoyés ; l’objet est relu juste avant et juste après.</p>
    </form>`;
  const form = dr.body.querySelector('form');
  form.addEventListener('submit', (e) => e.preventDefault());
  function submit(ctl) {
    const v = (n) => form.querySelector(`[name="${n}"]`).value.trim();
    const args = { dn: state.dn };
    if (v('description') !== (c.description ?? '')) args.description = v('description');
    if (v('location') !== (c.location ?? '')) args.location = v('location');
    if (v('managedBy') !== (c.managedBy?.dn ?? '')) args.managedBy = v('managedBy');
    if (Object.keys(args).length === 1) { toast('Aucun changement : rien à préparer.', { tone: 'info' }); return; }
    ctl.close();
    runWrite(state.ctx, { plan: 'poste.profile.plan', args, subtitle: c.name, onDone: () => state.reload() });
  }
}

async function openSuite(state, tool) {
  try {
    const r = await state.call('poste.suite.plan', { dn: state.dn, tool });
    const p = r.plan;
    const rows = p.arguments.length
      ? `<ul class="ps-suite-args">${p.arguments.map((a) => `<li class="mono">${esc(a)}</li>`).join('')}</ul>`
      : `<p class="ps-note">${ico('info')}Aucun argument : l’outil s’ouvrirait sans contexte.</p>`;
    const omitted = p.omitted.length ? `<p class="ps-note warn">${ico('alert')}Champs écartés${NBSP}: ${esc(p.omitted.join(' · '))}</p>` : '';
    const dialog = openDialog({
      title: `Ouvrir ${r.tool.label} avec ce poste`,
      subtitle: r.tool.configured ? 'Plan d’ouverture' : 'Outil non configuré',
      icon: 'sparkles',
      size: 'md',
      body: `<div class="poste-drw ps-dlg"><p class="k-dlg-text">${esc(r.text)}</p>${p.reason ? `<p class="ps-note">${ico('info')}${esc(p.reason)}</p>` : ''}${rows}${omitted}</div>`,
      actions: r.canLaunch
        ? [{ id: 'close', label: 'Fermer', safe: true }, { id: 'launch', label: `Ouvrir ${r.tool.label}`, primary: true }]
        : [{ id: 'close', label: 'Fermer', safe: true, primary: true }],
    });
    const answer = await dialog.result;
    if (answer === 'launch') launchSuite(state, tool);
  } catch (err) {
    toast(errorText(err), { tone: 'alert' });
  }
}

/** Opens a suite tool through the launcher of the host (fingerprint and contract checked there); nothing in simulation. */
async function launchSuite(state, tool) {
  try {
    const r = await state.call('poste.suite.launch', { dn: state.dn, tool });
    toast([r.text, ...(r.checks ?? [])].join(' '), { tone: r.launched ? 'ok' : 'info', life: 7000 });
  } catch (err) {
    toast(errorText(err), { tone: 'warn' });
  }
}
