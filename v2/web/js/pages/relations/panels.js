// Utilisateurs et postes · work panels, docked beside the page: « Ajouter » (manual search of a target with the steps of the
// association, detection of the workstations of a user, session of a workstation), import with preview, orphan check,
// harvest of the controller journal, relevé of the parc, and the precautions of the screen. Docked (not modal): the plan of a
// write opens over them, and they carry on after its receipt (association saved or refused, next batch of observations,
// orphans removed). Every network read starts on an explicit click; a detection shows the exact list of workstations before
// contacting any; every change is a plan of the write circuit. Content carries data-page="relations" so the page stylesheet
// scopes it (docs/KIT.md § 3).
import { openDrawer } from '../../kit/drawer.js';
import { createGrid } from '../../kit/grid.js';
import { createTree } from '../../kit/tree.js';
import { glyph } from '../../kit/glyphs.js';
import { uid, writeClipboard } from '../../kit/util.js';
import { onEvent } from '../../bridge.js';
import { applyVars, announce, countUp, progressTo, formatDateTime, inkFollow, toast } from '../../ui.js';
import {
  badge, avatar, esc, int, nouns, NBSP, errText, tonePill, empty, sk, dateText, associationStep,
} from './model.js';

// Marks of the kit command bar (k-cmd-net, k-cmd-mark): the same sign on every screen, with its words for screen readers.
const KIND_TAG = {
  network: `<span class="k-cmd-net" aria-hidden="true"></span><span class="visually-hidden">, lecture réseau sur ce clic</span>`,
  write: `<span class="k-cmd-mark" aria-hidden="true">${glyph('edit')}</span><span class="visually-hidden">, écriture : plan, confirmation et reçu</span>`,
};
const KIND_TIP = { network: 'Lecture réseau : part seulement sur ce clic', write: 'Écriture locale : plan, confirmation et reçu avant tout changement' };

function shell(inner) {
  return `<div class="rel-panel" data-page="relations">${inner}</div>`;
}

/** A work panel: docked beside the page, so the write circuit (a modal panel) opens over it and it survives the receipt. */
function workDrawer(options) {
  return openDrawer({ ...options, modal: false });
}

/** Resolves once the drawer is really open. */
function whenOpen(ctl) {
  return new Promise((resolve) => {
    let done = false;
    ctl.closed.then(() => { if (!done) { done = true; resolve(false); } });
    const check = () => {
      if (done) return;
      if (ctl.body) { done = true; resolve(true); return; }
      requestAnimationFrame(check);
    };
    check();
  });
}

/** Footer buttons of a panel, replaced as the steps go. */
function footer(ctl) {
  let handlers = new Map();
  ctl.foot.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-rf]') : null;
    if (!b || b.disabled) return;
    handlers.get(b.dataset.rf)?.();
  });
  return {
    set(buttons) {
      handlers = new Map(buttons.filter((b) => b.run).map((b) => [b.id, b.run]));
      ctl.foot.hidden = buttons.length === 0;
      ctl.foot.innerHTML = buttons.map((b) => `<button class="btn${b.primary ? ' primary' : ''}${b.danger ? ' danger' : ''}${!b.primary && !b.danger ? ' subtle' : ''}" type="button" data-rf="${esc(b.id)}"${b.disabled ? ' disabled' : ''}${b.reason ? ` data-tip="${esc(b.reason)}"` : b.kind ? ` data-tip="${esc(KIND_TIP[b.kind])}"` : ''}>${b.icon ? glyph(b.icon) : ''}${esc(b.label)}${b.kind ? KIND_TAG[b.kind] : ''}</button>`).join('');
      ctl.foot.classList.add('rel-foot');
      ctl.foot.dataset.page = 'relations';
    },
  };
}

/** The steps still to come, faded, so an operator sees the whole path before the first gesture. */
function upcoming(steps, start) {
  return `<ol class="rel-upcoming" aria-label="Étapes suivantes">${steps.map(([title, text], i) => `<li data-j="${i}"><span class="rel-step-n">${start + i}</span><div><b>${esc(title)}</b><p>${esc(text)}</p></div></li>`).join('')}</ol>`;
}

const ORPHAN_STEPS = [
  ['Orphelines trouvées', 'Compte ou poste absent, avec le motif et la source ; les 64 premières sont cochées, les sources protégées écartées.'],
  ['Retrait confirmé', 'Plan relu, confirmation et reçu ; chaque retrait reste restaurable depuis le journal.'],
];
const HARVEST_STEPS = [
  ['Impact estimé', 'Nombre d’événements et durée estimés, avant toute lecture du journal.'],
  ['Couples lus', 'Utilisateur → poste trouvés, déjà connus signalés : les nouveaux sont mémorisés automatiquement.'],
  ['Mémorisation par lots', 'Lots de 64 mémorisés dans la base locale sans confirmation, chaque changement tracé au journal ; une association existante n’est jamais écrasée.'],
];
const DETECT_STEPS = [
  ['Lecture de l’annuaire', 'Compte relu (même GUID, même identifiant), associations connues, managedBy et mentions du compte : aucun poste contacté.'],
  ['Postes à interroger', 'La liste exacte du périmètre, 50 postes au plus, avant toute sonde.'],
  ['Détection et résultat', 'Console de chaque poste, compteurs en direct, arrêt au premier refus d’identifiants, puis enregistrement des consoles confirmées sur votre confirmation.'],
];
const SWEEP_STEPS = [
  ['Postes à relever', 'La liste exacte des postes, avant tout contact.'],
  ['Ping puis relevé', 'Ping groupé par lots de 8, puis la console des seuls postes qui répondent ; compteurs en direct, arrêt possible à tout moment.'],
  ['Mémorisation par lots', 'Les consoles relevées sont mémorisées dans la base locale par lots de 64, sans confirmation, et tracées au journal.'],
];

/** Remaining observations of one result, read from the engine (they leave the memory as they are saved). */
async function remainingOf(app, resultId) {
  try {
    const pending = await app.ctx.call('relations.observations.pending');
    const found = pending.sets.find((s) => s.resultId === resultId);
    // An expired result while observations remain is not proof of a successful save.
    return found ? found.remaining : pending.total === 0 ? 0 : null;
  } catch (err) {
    console.error(err);
    return null;
  }
}

/**
 * Footer button shown only when observations are still waiting (a memorization was refused): the engine memorizes them at once
 * into the local base, by batches of 64, without confirmation (choice of 22/10, Domenia 1 REL-014).
 */
function saveButton(remaining, origin) {
  return { id: 'save', label: `Mémoriser maintenant (${int(remaining)})`, icon: 'check', primary: true,
    reason: `${nouns(remaining, 'observation', 'observations')} de ${origin.toLowerCase()} en attente : mémorisation dans la base locale par lots de 64, tracée au journal des associations.` };
}

/**
 * REL-029: refused or rejected resources are named, counted and never retried. Another account is the operator’s explicit
 * choice: Domenia uses the account of its session, so the operator relaunches with an authorised account.
 */
function refusalCard(res) {
  const refused = (res?.attempts ?? []).filter((a) => a.status === 'REFUSE' || a.status === 'AUTH_REJETEE');
  if (!refused.length) return '';
  const names = refused.map((a) => a.target).filter(Boolean);
  const rejected = refused.some((a) => a.status === 'AUTH_REJETEE');
  return `<section class="rel-refused" role="note">
    <h4>${glyph('lock')}Reprise d’accès · ${esc(nouns(refused.length, 'ressource refusée', 'ressources refusées'))}</h4>
    <p>${rejected ? 'Les identifiants de la session ont été rejetés : la lecture s’est arrêtée au premier rejet, aucun autre poste n’a été contacté avec ce compte.' : 'Ces postes refusent la lecture au compte de la session.'} Rien n’est rejoué automatiquement${NBSP}: ouvrez Domenia avec un compte autorisé sur ces ressources, puis relancez vous-même la lecture.</p>
    <ul>${refused.map((a) => `<li>${tonePill(a.tone, a.statusLabel)}<span class="mono">${esc(a.target ?? '—')}</span><span>${esc(a.resource)}</span></li>`).join('')}</ul>
    ${names.length ? `<button class="btn xs" type="button" data-copy-refused="${esc(names.join('\n'))}">${glyph('copy')}Copier la liste</button>` : ''}
    <button class="btn xs subtle" type="button" data-access-requests>${glyph('key')}Choisir un autre compte dans Comptes</button>
  </section>`;
}

function bindRefusal(scope, navigate) {
  // REL-029: each refusal opened an access to review in Comptes (relations.detect.run); the operator chooses the account there.
  scope.querySelectorAll('[data-access-requests]').forEach((b) => b.addEventListener('click', () => navigate?.('comptes', { vue: 'acces' })));
  scope.querySelectorAll('[data-copy-refused]').forEach((b) => b.addEventListener('click', async () => {
    const ok = await writeClipboard(b.dataset.copyRefused);
    toast(ok ? 'Liste des ressources refusées copiée.' : 'Copie impossible : presse-papiers indisponible.', { tone: ok ? 'ok' : 'warn' });
  }));
}

/** « Détail des tentatives » (Domenia 1 DgLinkAttempts): method, status, target, duration, detail and resource. */
function attemptsMarkup(attempts) {
  if (!attempts?.length) return '';
  return `<details class="rel-attempts"><summary>${glyph('sliders')}Détail des tentatives (${int(attempts.length)})</summary>
    <table class="rel-att-table"><thead><tr><th scope="col">Méthode</th><th scope="col">Statut</th><th scope="col">Cible</th><th scope="col">Ressource</th><th scope="col">Durée</th></tr></thead>
    <tbody>${attempts.map((a) => `<tr><th scope="row">${esc(a.method)}<small>${esc(a.detail)}</small></th><td>${tonePill(a.tone, a.statusLabel)}</td>
      <td class="mono">${esc(a.target ?? '—')}</td><td>${esc(a.resource)}</td><td class="num">${int(a.durationMs)}${NBSP}ms</td></tr>`).join('')}</tbody></table></details>`;
}

// ====================================================================================================== Ajouter

/**
 * « Ajouter » panel of a subject: manual search of a target (both directions), detection of the workstations of a user,
 * or the session of a workstation.
 * @param {object} app  Controller of the screen.
 * @param {any} subject The subject (relations.subject → subject).
 * @param {'rechercher'|'detecter'|'session'} mode
 */
export function openAddPanel(app, subject, mode) {
  const isUser = subject.kind === 'user';
  const modes = isUser
    ? [{ id: 'rechercher', label: 'Rechercher un poste', icon: 'search' }, { id: 'detecter', label: 'Détecter les postes', icon: 'wifi' }]
    : [{ id: 'rechercher', label: 'Rechercher un utilisateur', icon: 'search' }, { id: 'session', label: 'Lire la session', icon: 'monitor' }];
  let current = modes.some((m) => m.id === mode) ? mode : modes[0].id;
  const ctl = workDrawer({
    title: 'Ajouter une association', subtitle: `${isUser ? 'Utilisateur' : 'Poste'} · ${subject.login}`, icon: 'link',
    key: 'relations.ajouter', width: 620, minWidth: 460, maxWidth: 1000,
    body: shell(`<div class="rel-add">
      <div class="rel-add-subject">${avatar(subject.kind, subject.name, 'md')}<div><b>${esc(subject.name)}</b><span class="mono">${esc(subject.login)}</span></div>
        <span class="rel-add-arrow" aria-hidden="true">${glyph('link')}</span>
        <span class="rel-add-target-k">${isUser ? 'Postes' : 'Utilisateurs'}</span></div>
      <div class="segmented rel-add-modes" role="group" aria-label="Mode d’ajout"><span class="thumb" aria-hidden="true"></span>${modes.map((m) => `<button type="button" data-mode="${m.id}" aria-pressed="${m.id === current}">${glyph(m.icon)}<span>${esc(m.label)}</span></button>`).join('')}</div>
      <div class="rel-add-body"></div></div>`),
    actions: [],
  });
  let mode$ = null; // controller of the current mode: { state(), stop(), refresh() }
  ctl.associationState = () => mode$?.state?.() ?? 'idle';
  ctl.refresh = () => mode$?.refresh?.();
  whenOpen(ctl).then((opened) => {
    if (!opened) return;
    const foot = footer(ctl);
    const host = ctl.body.querySelector('.rel-add-body');
    const seg = ctl.body.querySelector('.rel-add-modes');
    const ink = inkFollow(seg, 'button', 'button[aria-pressed="true"]');
    seg.addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-mode]') : null;
      if (!b || b.dataset.mode === current) return;
      const busy = mode$?.state?.();
      if (busy === 'pending' || busy === 'verifying') {
        const reason = `Une association attend sa confirmation${NBSP}: confirmez-la ou annulez-la avant de changer de mode.`;
        toast(reason, { tone: 'warn' }); announce(reason);
        return;
      }
      mode$?.stop?.();
      current = b.dataset.mode;
      seg.querySelectorAll('[data-mode]').forEach((x) => x.setAttribute('aria-pressed', String(x.dataset.mode === current)));
      ink.update();
      paint();
    });
    ctl.closed.then(() => { mode$?.stop?.(); ink.stop(); });
    const paint = () => {
      if (current === 'rechercher') mode$ = searchMode(app, ctl, host, foot, subject);
      else if (current === 'detecter') mode$ = detectMode(app, ctl, host, foot, subject);
      else mode$ = sessionMode(app, ctl, host, foot, subject);
    };
    paint();
  });
  return ctl;
}

const STEPS = ['Recherche', 'Choix', 'Confirmation', 'Vérification', 'Enregistrée'];
const STEP_AT = { idle: 0, searching: 0, candidate: 1, pending: 2, verifying: 3, saved: 5, failed: 4 };

function stepper(state) {
  const at = STEP_AT[state] ?? 0;
  const failed = state === 'failed';
  return `<ol class="rel-steps${failed ? ' failed' : ''}" aria-label="Étapes de l’association">${STEPS.map((label, i) => {
    const done = i < at;
    const now = i === at || (failed && i === 4);
    const text = i === 4 && failed ? 'Échec' : label;
    return `<li class="${done ? 'done' : now ? 'now' : ''}${i === 4 && failed ? ' fail' : ''}" data-j="${i}"${now ? ' aria-current="step"' : ''}><span class="rel-step-mark" aria-hidden="true">${done ? glyph('check') : i === 4 && failed ? glyph('x') : i + 1}</span>${esc(text)}</li>`;
  }).join('')}</ol>`;
}

function searchMode(app, ctl, host, foot, subject) {
  const isUser = subject.kind === 'user';
  const fieldId = uid('relsearch');
  let state = 'idle';
  let rows = [];
  let chosen = null;
  let request = 0;
  host.innerHTML = `<div class="rel-mode">
    <div class="rel-steps-host">${stepper('idle')}</div>
    <form class="rel-search" novalidate>
      <label class="visually-hidden" for="${fieldId}">${isUser ? 'Poste à associer' : 'Utilisateur à associer'}</label>
      <span class="rel-search-ico" aria-hidden="true">${glyph('search')}</span>
      <input class="input" id="${fieldId}" type="search" autocomplete="off" spellcheck="false" maxlength="100"
        placeholder="${isUser ? 'Nom ou nom DNS du poste' : 'Identifiant, nom ou UPN'}">
      <button class="btn" type="submit">${glyph('search')}Rechercher${KIND_TAG.network}</button>
    </form>
    <p class="rel-status" role="status">Recherche dans tout le domaine, sur votre geste${NBSP}; le sujet reste ${esc(subject.login)}.</p>
    <div class="rel-search-hint"><span class="rel-hint-art" aria-hidden="true">${glyph(isUser ? 'monitor' : 'user')}</span>
      <p>Exemples${NBSP}: <span class="mono">${isUser ? 'PC-PAR-0042' : 'j.martin'}</span>, <span class="mono">${isUser ? 'pt-lyo' : 'martin'}</span>. Deux caractères au moins, puis Entrée. La cible choisie est relue au moment du plan, GUID compris.</p></div>
    <ul class="rel-results" role="listbox" aria-label="${isUser ? 'Postes trouvés' : 'Utilisateurs trouvés'}"></ul>
    <div class="rel-confirm" hidden></div>
  </div>`;
  const input = host.querySelector('input');
  const status = host.querySelector('.rel-status');
  const list = host.querySelector('.rel-results');
  const confirm = host.querySelector('.rel-confirm');

  /** Applies one event of the association; a refused one keeps the state and says why (Domenia 1 D045). */
  function step(event) {
    const r = associationStep(state, event);
    if (!r.accepted) {
      status.textContent = r.reason;
      status.classList.add('warn');
      announce(r.reason);
      return false;
    }
    status.classList.remove('warn');
    state = r.state;
    host.querySelector('.rel-steps-host').innerHTML = stepper(state);
    applyVars(host);
    list.classList.toggle('inactive', state === 'idle' && rows.length > 0);
    paintFoot();
    return true;
  }

  function paintFoot() {
    const buttons = [{ id: 'close', label: 'Fermer', run: () => ctl.close() }];
    if (state === 'saved' || state === 'failed') {
      buttons.push({ id: 'again', label: 'Nouvelle recherche', icon: 'search', run: () => { step('reset'); reset(); input.focus(); } });
    } else {
      buttons.push({ id: 'associate', label: isUser ? 'Associer ce poste' : 'Associer cet utilisateur', icon: 'link', primary: true, kind: 'write',
        disabled: state !== 'pending', reason: state === 'verifying' ? 'Vérification en cours.' : state !== 'pending' ? 'Choisissez d’abord une ligne dans les résultats.' : '', run: associate });
    }
    foot.set(buttons);
  }

  function reset() {
    rows = []; chosen = null; list.innerHTML = ''; confirm.hidden = true; list.classList.remove('inactive');
  }

  function confirmCard(row, outcome = null) {
    const user = isUser ? subject : row;
    const computer = isUser ? row : subject;
    const tail = outcome === 'saved'
      ? `<p class="rel-confirm-done">${glyph('check')}Association enregistrée, relue et tracée par un reçu. Choisissez une autre ligne pour en ajouter une.</p>`
      : outcome === 'failed'
        ? `<p class="rel-confirm-note warn">${glyph('alert')}Association non enregistrée${NBSP}: plan refusé, annulé ou issue à vérifier (voir le panneau du plan et Opérations). Rien n’est rejoué.</p>`
        : `<p class="rel-confirm-note">${glyph('lock')}Association locale à Domenia${NBSP}: Active Directory n’est pas modifié. Le sujet et la cible sont relus au moment du plan (même GUID), puis vous confirmez.</p>
          ${row.alreadyLinked ? `<p class="rel-confirm-note warn">${glyph('info')}Une relation existe déjà entre eux${NBSP}: une affectation déclarée s’ajoute à côté, ou met à jour sa date si elle existait.</p>` : ''}
          <button class="btn xs ghost rel-confirm-cancel" type="button" data-cancel>${glyph('x')}Annuler ce choix</button>`;
    return `<div class="rel-confirm-card${outcome ? ` ${outcome}` : ''}">
      <div class="rel-confirm-pair">${avatar('user', user.name, 'md')}<span class="rel-confirm-line" aria-hidden="true"><span></span></span>${avatar('computer', computer.name, 'md')}</div>
      <p class="rel-confirm-text"><b>${esc(user.login)}</b> → <b>${esc(computer.name)}</b> · ${badge('declared', { size: 'sm' })} (Saisie manuelle)</p>
      ${tail}
    </div>`;
  }

  function showConfirm(row, outcome) {
    confirm.hidden = false;
    confirm.innerHTML = confirmCard(row, outcome);
    confirm.classList.remove('in'); void confirm.offsetWidth; confirm.classList.add('in');
    confirm.querySelector('[data-cancel]')?.addEventListener('click', () => {
      if (!step('cancel')) return;
      chosen = null;
      confirm.hidden = true;
      list.querySelectorAll('.rel-result').forEach((x) => { x.classList.remove('chosen'); x.setAttribute('aria-selected', 'false'); });
      status.textContent = 'Choix annulé : relancez la recherche pour choisir une autre ligne.';
    });
  }

  async function associate() {
    if (!chosen || !step('confirm')) return;
    const target = chosen;
    status.textContent = 'Vérification du sujet et de la cible dans l’annuaire, puis plan à confirmer…';
    const receipt = await app.plan('relations.associate.plan', { dn: subject.dn, subjectGuid: subject.guid, target: target.dn, targetGuid: target.guid });
    if (!ctl.body?.isConnected) return;
    if (receipt) {
      step('verified');
      status.textContent = `Association ${isUser ? subject.login : target.login} → ${isUser ? target.name : subject.name} enregistrée.`;
      target.alreadyLinked = true;
      list.querySelector(`.rel-result[data-dn="${CSS.escape(target.dn)}"] .rel-result-tags`)?.insertAdjacentHTML('afterbegin', `<span class="rel-tag ok">${glyph('check')}Associé</span>`);
      showConfirm(target, 'saved');
    } else {
      step('verifyFailed');
      status.textContent = 'Association non enregistrée : rien n’a été écrit, ou l’issue est à vérifier dans Opérations.';
      showConfirm(target, 'failed');
    }
  }

  // A new term invalidates the results and the association prepared from them (Domenia 1 REL-001).
  input.addEventListener('input', () => {
    if (!rows.length && !chosen) return;
    if (state === 'pending' || state === 'verifying') return;
    reset();
    if (state !== 'idle') step('reset');
    status.textContent = 'Nouveau terme : relancez la recherche.';
  });
  host.querySelector('form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (text.length < 2) { status.textContent = 'Saisissez au moins deux caractères.'; input.focus(); return; }
    if (!step('search')) return;
    const my = ++request;
    chosen = null; confirm.hidden = true;
    host.querySelector('.rel-search-hint')?.remove();
    list.setAttribute('aria-busy', 'true');
    list.innerHTML = [1, 2, 3].map(() => `<li class="rel-result sk-row">${sk('w55')}${sk('w40')}</li>`).join('');
    status.textContent = `Recherche ${isUser ? 'des postes' : 'des utilisateurs'} dans tout le domaine…`;
    try {
      const res = await app.ctx.call('relations.targets.search', { dn: subject.dn, text });
      if (my !== request) return;
      rows = res.results;
      list.removeAttribute('aria-busy');
      list.innerHTML = rows.map((r, j) => `<li class="rel-result" role="option" aria-selected="false" tabindex="0" data-j="${Math.min(j, 16)}" data-dn="${esc(r.dn)}">
        ${avatar(r.kind, r.name, 'sm')}<div class="rel-result-text"><b>${esc(r.name)}</b><span class="mono">${esc(r.login)}</span>${r.detail ? `<span class="rel-result-detail">${esc(r.detail)}</span>` : ''}</div>
        <span class="rel-result-tags">${r.alreadyLinked ? `<span class="rel-tag ok">${glyph('link')}Déjà associé</span>` : ''}${r.enabled ? '' : `<span class="rel-tag warn">${glyph('power')}Désactivé</span>`}</span>
        <span class="rel-result-radio" aria-hidden="true"></span></li>`).join('');
      applyVars(list);
      step('results');
      status.textContent = res.message;
      announce(res.message);
    } catch (err) {
      if (my !== request) return;
      list.removeAttribute('aria-busy');
      list.innerHTML = '';
      step('cancel');
      status.textContent = `Recherche non confirmée${NBSP}: ${errText(err)}`;
    }
  });
  const pick = (li) => {
    const row = rows.find((r) => r.dn === li.dataset.dn);
    if (!row) return;
    // A refused pick (search under way, association waiting, list no longer active) is said, never silently ignored.
    if (!step('pick')) return;
    chosen = row;
    list.querySelectorAll('.rel-result').forEach((x) => { const on = x === li; x.classList.toggle('chosen', on); x.setAttribute('aria-selected', String(on)); });
    status.textContent = `${row.name} choisi${isUser ? '' : 'e'}${NBSP}: vérifiez puis associez.`;
    showConfirm(row, null);
  };
  list.addEventListener('click', (e) => { const li = e.target instanceof Element ? e.target.closest('.rel-result[data-dn]') : null; if (li) pick(li); });
  list.addEventListener('keydown', (e) => {
    const li = e.target instanceof Element ? e.target.closest('.rel-result[data-dn]') : null;
    if (!li) return;
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(li); }
    if (e.key === 'ArrowDown') { e.preventDefault(); li.nextElementSibling?.focus(); }
    if (e.key === 'ArrowUp') { e.preventDefault(); li.previousElementSibling?.focus(); }
  });
  paintFoot();
  setTimeout(() => input.focus(), 60);
  return { state: () => state, stop: () => { request++; } };
}

// ---------------------------------------------------------------------------------------------- probe (detection, relevé)

/** Live probe of a confirmed plan: progress ring, counters, workstation by workstation; returns a stop function. */
function runProbe(app, host, planId, planned, onDone) {
  let stopped = false;
  host.innerHTML = `<div class="rel-probe" aria-live="polite">
    <div class="rel-probe-ring"><svg viewBox="0 0 120 120" aria-hidden="true"><circle class="track" cx="60" cy="60" r="50"/><circle class="bar" cx="60" cy="60" r="50" pathLength="100"/></svg>
      <div class="rel-probe-center"><b class="num">0</b><span>sur ${int(planned)}</span></div></div>
    <div class="rel-probe-stats">
      <div data-k="confirmed"><b class="num">0</b><span>confirmés</span></div><div data-k="noSession"><b class="num">0</b><span>sans compte</span></div>
      <div data-k="refused"><b class="num">0</b><span>refusés</span></div><div data-k="unreachable"><b class="num">0</b><span>injoignables</span></div>
    </div>
    <p class="rel-probe-text">Lecture des postes du périmètre confirmé…</p>
    <ol class="rel-probe-feed"></ol></div>`;
  const ring = host.querySelector('.rel-probe-ring');
  const feed = host.querySelector('.rel-probe-feed');
  const off = onEvent('relations.detect.run:progress', (d) => {
    if (!d || d.planId !== planId) return;
    const c = d.counters;
    host.querySelector('.rel-probe-center b').textContent = int(c.queried);
    for (const k of ['confirmed', 'noSession', 'refused', 'unreachable']) host.querySelector(`[data-k="${k}"] b`).textContent = int(c[k]);
    ring.style.setProperty('--p', String(planned ? c.queried / planned : 0));
    host.querySelector('.rel-probe-text').textContent = c.text;
    feed.insertAdjacentHTML('afterbegin', `<li class="rel-feed" data-tone="${esc(d.tone)}">${tonePill(d.tone, d.statusLabel)}<b>${esc(d.computer)}</b><span>${esc(d.currentUser ?? '')}</span></li>`);
    while (feed.children.length > 8) feed.lastElementChild.remove();
  });
  app.ctx.call('relations.detect.run', { planId }).then((res) => {
    off();
    onDone(res, null);
  }).catch((err) => {
    off();
    onDone(null, err);
  });
  return () => {
    if (stopped) return;
    stopped = true;
    app.ctx.call('relations.detect.stop', { planId }).then((a) => announce(a.message)).catch((err) => console.error(err));
  };
}

function candidatesMarkup(candidates, { associate = true } = {}) {
  if (!candidates.length) return '';
  return `<ul class="rel-cands">${candidates.map((c, j) => `<li class="rel-cand${c.confirmed ? ' confirmed' : ''}${c.associable ? '' : ' blocked'}" data-j="${Math.min(j, 20)}">
    ${avatar('computer', c.computer, 'sm')}<div class="rel-cand-text"><b>${esc(c.computer)}</b><span class="rel-cand-origin">${esc(c.origins)}</span><p>${esc(c.why)}</p>
      ${c.blocker ? `<p class="rel-cand-block">${glyph('lock')}${esc(c.blocker)}</p>` : ''}</div>
    <div class="rel-cand-side">${c.status ? `<span class="rel-cand-status">${esc(c.status)}</span>` : ''}${badge(c.badge, { size: 'sm', label: c.badgeLabel })}
      ${c.currentUser ? `<span class="mono rel-cand-user">${esc(c.currentUser)}</span>` : ''}${c.observedText ? `<span class="rel-cand-when">${esc(c.observedText)}</span>` : ''}
      <span class="rel-cand-acts">
        ${c.dn ? `<button class="btn xs ghost" type="button" data-fiche="${esc(c.dn)}" data-tip="Ouvrir la fiche du poste">${glyph('external')}Fiche</button>` : ''}
        ${associate && c.associable && c.dn && c.guid ? `<button class="btn xs" type="button" data-associate="${esc(c.dn)}" data-guid="${esc(c.guid)}" data-name="${esc(c.computer)}" data-tip="Préparer son association déclarée (plan, confirmation, reçu)">${glyph('link')}Associer</button>` : ''}
        ${associate && !c.associable && c.blocker ? `<span class="rel-cand-why" data-tip="${esc(c.blocker)}">${glyph('lock')}Non associable</span>` : ''}
      </span></div></li>`).join('')}</ul>`;
}

/** OU picker of a perimeter: the tree of the domain, read one level at a time on opening (never the domain itself). */
function ouPicker(app, host, onPick) {
  host.innerHTML = '<div class="rel-ou-tree"></div><p class="rel-ou-chosen" aria-live="polite"></p>';
  const toNode = (ou) => ({ id: ou.dn, label: ou.name, hint: nouns(ou.counts?.computers ?? 0, 'poste', 'postes'), leaf: !ou.hasChildren, icon: 'ou', data: ou });
  const tree = createTree(host.querySelector('.rel-ou-tree'), {
    label: 'Unités d’organisation du domaine',
    roots: async () => (await app.ctx.call('directory.ou.children', { dn: null })).children.map(toNode),
    load: async (node) => (await app.ctx.call('directory.ou.children', { dn: node.id })).children.map(toNode),
    onSelect: (node) => {
      host.querySelector('.rel-ou-chosen').innerHTML = `${glyph('ou')}OU choisie${NBSP}: <b>${esc(node.data?.path ?? node.label)}</b>`;
      onPick(node.id, node.data?.path ?? node.label);
    },
    height: '240px',
    searchPlaceholder: 'Chercher une OU déjà ouverte…',
  });
  return tree;
}

function detectMode(app, ctl, host, foot, subject) {
  let stop = null;
  let tree = null;
  let chosenOu = null;
  let resultId = null;
  let resultSavable = 0;
  const scopeLabel = app.scopeLabel();
  const loaded = app.loadedComputers();
  host.innerHTML = `<div class="rel-mode rel-detect">
    <section class="rel-step-card">
      <h3><span class="rel-step-n">1</span>Périmètre</h3>
      <div class="rel-radios" role="radiogroup" aria-label="Périmètre de détection">
        <label class="rel-radio"><input class="k-radio" type="radio" name="scope" value="candidates" checked><span><b>Postes connus et candidats de l’annuaire</b><small>Associations mémorisées, managedBy, mentions du compte.</small></span></label>
        <label class="rel-radio${loaded ? '' : ' off'}"><input class="k-radio" type="radio" name="scope" value="loaded"${loaded ? '' : ' disabled'}><span><b>Machines de la liste chargée</b><small>${loaded ? esc(loaded.label) : 'Aucune liste chargée : filtrez « Toutes les associations » ou venez de Rechercher avec une liste de postes.'}</small></span></label>
        <label class="rel-radio"><input class="k-radio" type="radio" name="scope" value="ou"><span><b>OU de travail${scopeLabel ? ` · ${esc(scopeLabel)}` : ''}</b><small>Postes de l’OU de travail, jamais le domaine entier.</small></span></label>
        <label class="rel-radio"><input class="k-radio" type="radio" name="scope" value="other"><span><b>Autre OU explicite</b><small>Choisie dans l’arborescence ; la racine du domaine n’est jamais acceptée.</small></span></label>
      </div>
      <div class="rel-ou-host" hidden></div>
      <div class="rel-inline">
        <label class="rel-num"><span>Postes au plus</span><input class="input" type="number" name="limit" min="1" max="50" value="20"></label>
        <label class="rel-switch"><input class="switch" type="checkbox" role="switch" name="kerberos"><span>Indices Kerberos du contrôleur (7 jours)</span></label>
      </div>
      <p class="rel-note">${glyph('shield')}Rien n’est sondé à cette étape${NBSP}: l’annuaire est lu, puis la liste exacte des postes à interroger vous est montrée avant tout contact.</p>
    </section>
    <div class="rel-detect-out">${upcoming(DETECT_STEPS, 2)}</div>
  </div>`;
  const out = host.querySelector('.rel-detect-out');
  const ouHost = host.querySelector('.rel-ou-host');
  applyVars(out);
  host.querySelectorAll('input[name="scope"]').forEach((r) => r.addEventListener('change', () => {
    const other = host.querySelector('input[name="scope"]:checked')?.value === 'other';
    ouHost.hidden = !other;
    if (other && !tree) tree = ouPicker(app, ouHost, (dn) => { chosenOu = dn; forgetPlan(`OU modifiée${NBSP}: lisez de nouveau l’annuaire.`); });
  }));
  const values = () => ({
    scope: host.querySelector('input[name="scope"]:checked')?.value ?? 'candidates',
    limit: Math.max(1, Math.min(50, Number(host.querySelector('input[name="limit"]').value) || 20)),
    kerberos: host.querySelector('input[name="kerberos"]').checked,
  });
  const setFoot = (buttons) => foot.set([{ id: 'close', label: 'Fermer', run: () => ctl.close() }, ...buttons]);
  const startFoot = () => setFoot([{ id: 'collect', label: 'Lire l’annuaire', icon: 'search', primary: true, kind: 'network', run: collect }]);
  startFoot();
  // A plan is frozen on the choices of step 1 (Domenia 1 BtnRelationPlanCancel): changing the scope, the limit or the Kerberos
  // option, or « Annuler », forgets it; the next step is « Lire l’annuaire » again, never « Lancer » on a stale plan.
  let planShown = false;
  const forgetPlan = (message) => {
    if (!planShown || stop) return;
    planShown = false;
    out.innerHTML = upcoming(DETECT_STEPS, 2);
    applyVars(out);
    startFoot();
    if (message) announce(message);
  };
  host.querySelector('.rel-step-card').addEventListener('change', () => forgetPlan(`Périmètre modifié${NBSP}: lisez de nouveau l’annuaire.`));

  async function collect() {
    const v = values();
    if (v.scope === 'other' && !chosenOu) {
      toast('Choisissez d’abord une OU dans l’arborescence.', { tone: 'info' });
      return;
    }
    out.innerHTML = `<section class="rel-step-card" aria-busy="true">${sk('w40')}${sk('w85')}${sk('w70')}${sk('w55')}</section>`;
    setFoot([{ id: 'collect', label: 'Lecture de l’annuaire…', icon: 'search', primary: true, disabled: true }]);
    const args = {
      dn: subject.dn, guid: subject.guid, login: subject.login,
      scope: v.scope === 'other' ? 'ou' : v.scope,
      ouDn: v.scope === 'other' ? chosenOu : null,
      computers: v.scope === 'loaded' ? (app.loadedComputers()?.names ?? []) : [],
      limit: v.limit, kerberos: v.kerberos,
    };
    try {
      const res = await app.ctx.call('relations.detect.collect', args);
      if (!ctl.body?.isConnected) return;
      showCollect(res);
    } catch (err) {
      if (!ctl.body?.isConnected) return;
      out.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}Détection impossible${NBSP}: ${esc(errText(err))}</p>`;
      setFoot([{ id: 'collect', label: 'Lire l’annuaire', icon: 'search', primary: true, kind: 'network', run: collect }]);
    }
  }

  function showCollect(res) {
    const plan = res.plan;
    out.innerHTML = `<section class="rel-step-card in">
        <h3><span class="rel-step-n">2</span>Annuaire lu · aucun poste contacté</h3>
        <p class="rel-status">${esc(res.message)}</p>
        ${candidatesMarkup(res.candidates)}
        ${res.hints.length ? `<div class="rel-hints"><h4>${glyph('key')}Indices Kerberos (adresses, jamais associées automatiquement)</h4><ul>${res.hints.map((h, j) => `<li data-j="${j}"><span class="mono">${esc(h.address)}</span><span>${esc(h.status)}</span><time>${esc(formatDateTime(h.observedAt) ?? '')}</time></li>`).join('')}</ul></div>` : ''}
        ${attemptsMarkup(res.attempts)}
      </section>
      <section class="rel-step-card rel-plan ${plan.allowed ? '' : 'refused'}">
        <h3><span class="rel-step-n">3</span>Périmètre à confirmer · ${esc(plan.scopeLabel)}</h3>
        ${plan.allowed ? `<p>${esc(plan.text)}</p><ul class="rel-plan-targets">${plan.targets.map((t, j) => `<li data-j="${Math.min(j, 24)}" data-tip="${esc(t.source)}">${glyph('monitor')}${esc(t.computer)}</li>`).join('')}</ul>`
          : `<p class="rel-note warn">${glyph('info')}${esc(plan.reason)} ${esc(plan.zeroMeaning)}</p>`}
      </section>`;
    applyVars(out);
    bindCandidates(out);
    planShown = true;
    setFoot(plan.allowed
      ? [{ id: 'cancel', label: 'Annuler', icon: 'x', run: () => forgetPlan(`Plan oublié${NBSP}: aucun poste n’a été contacté.`) },
        { id: 'run', label: `Lancer la détection (${int(plan.targets.length)})`, icon: 'play', primary: true, kind: 'network', run: () => probe(plan) }]
      : [{ id: 'collect', label: 'Relire l’annuaire', icon: 'refresh', kind: 'network', run: collect }]);
  }

  function probe(plan) {
    // From here the panel shows a detection (its results stay until « Nouvelle détection »), no longer a plan to confirm.
    planShown = false;
    const probeHost = document.createElement('section');
    probeHost.className = 'rel-step-card in';
    out.prepend(probeHost);
    probeHost.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    setFoot([{ id: 'stop', label: 'Arrêter', icon: 'pause', danger: true, run: () => { stop?.(); setFoot([{ id: 'stopping', label: 'Arrêt demandé…', disabled: true }]); } }]);
    stop = runProbe(app, probeHost, plan.id, plan.targets.length, (res, err) => {
      stop = null;
      if (!ctl.body?.isConnected) return;
      if (err) {
        probeHost.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}Détection non terminée${NBSP}: ${esc(errText(err))} Les liens existants sont conservés.</p>`;
        setFoot([{ id: 'collect', label: 'Relire l’annuaire', icon: 'refresh', kind: 'network', run: collect }]);
        return;
      }
      resultId = res.resultId;
      resultSavable = res.savable;
      probeHost.innerHTML = `<h3><span class="rel-step-n">4</span>Résultat${res.counters?.stopped ? ' partiel' : ''}</h3><p class="rel-status">${esc(res.message)}</p>
        ${refusalCard(res)}${candidatesMarkup(res.candidates)}${attemptsMarkup(res.attempts)}`;
      applyVars(probeHost);
      bindCandidates(probeHost);
      bindRefusal(probeHost, (id, p) => app.ctx.navigate(id, p));
      announce(res.message);
      app.touch();
      remainingOf(app, res.resultId).then((left) => { if (ctl.body?.isConnected) resultFoot(left ?? res.savable); });
    });
  }

  function resultFoot(remaining) {
    setFoot(remaining > 0
      ? [{ ...saveButton(remaining, 'la détection'), run: save }, { id: 'collect', label: 'Nouvelle détection', icon: 'refresh', kind: 'network', run: collect }]
      : [{ id: 'collect', label: 'Nouvelle détection', icon: 'refresh', primary: true, kind: 'network', run: collect }]);
  }

  async function save() {
    if (!resultId) return;
    await app.saveBatches(resultId, { origin: 'Détection' });
  }

  function bindCandidates(scope) {
    scope.querySelectorAll('[data-associate]').forEach((b) => b.addEventListener('click', async () => {
      const receipt = await app.plan('relations.associate.plan', { dn: subject.dn, subjectGuid: subject.guid, target: b.dataset.associate, targetGuid: b.dataset.guid });
      if (receipt && b.isConnected) b.outerHTML = `<span class="rel-tag ok">${glyph('check')}Associé</span>`;
    }));
    scope.querySelectorAll('[data-fiche]').forEach((b) => b.addEventListener('click', () => app.openFiche({ dn: b.dataset.fiche })));
  }

  return {
    state: () => 'idle',
    stop: () => stop?.(),
    refresh: async () => {
      if (!resultId || !resultSavable || stop) return;
      const remaining = await remainingOf(app, resultId);
      if (remaining !== null && ctl.body?.isConnected) { resultSavable = remaining; resultFoot(remaining); }
    },
  };
}

function sessionMode(app, ctl, host, foot, subject) {
  let resultId = null;
  host.innerHTML = `<div class="rel-mode">
    <section class="rel-step-card">
      <h3>${glyph('monitor')}Session console de ${esc(subject.name)}</h3>
      <p>Lit l’utilisateur console du poste (Win32_ComputerSystem par CIM/DCOM, 4${NBSP}s), puis contrôle son identité${NBSP}: un compte local, d’un autre domaine ou non qualifié n’est jamais le compte AD.</p>
      <p class="rel-note">${glyph('shield')}Une lecture de console, puis vérification dans l’annuaire. Les observations confirmées sont mémorisées dans la base locale avec leur date et leur source ; les affectations existantes sont conservées.</p>
    </section>
    <div class="rel-session-out"></div></div>`;
  const out = host.querySelector('.rel-session-out');
  const set = (buttons) => foot.set([{ id: 'close', label: 'Fermer', run: () => ctl.close() }, ...buttons]);
  async function read() {
    out.innerHTML = `<section class="rel-step-card" aria-busy="true"><div class="rel-scan" aria-hidden="true"><span></span></div>${sk('w70')}${sk('w55')}</section>`;
    set([{ id: 'read', label: 'Lecture…', icon: 'monitor', primary: true, disabled: true }]);
    try {
      const res = await app.ctx.call('relations.computer.read', { dn: subject.dn });
      if (!ctl.body?.isConnected) return;
      const o = res.observed;
      resultId = res.savable ? res.resultId : null;
      out.innerHTML = `<section class="rel-step-card in rel-session-card${o?.match ? ' ok' : ''}">
        ${o ? `<div class="rel-session-who">${avatar('user', o.userName ?? o.login, 'lg')}<div><span class="rel-k">Compte console</span><b>${esc(o.userName ?? o.login)}</b><span class="mono">${esc(o.account)}</span></div>
          ${badge(o.badge, { label: o.badgeLabel })}</div>
          <p class="rel-session-check ${o.match ? 'ok' : 'warn'}">${glyph(o.match ? 'shield' : 'alert')}${esc(o.reason)}</p>` : ''}
        <p class="rel-status">${esc(res.message)}</p>${refusalCard(res)}${attemptsMarkup(res.attempts)}</section>`;
      applyVars(out);
      bindRefusal(out, (id, p) => app.ctx.navigate(id, p));
      app.touch();
      announce(res.message);
      const left = res.savable ? await remainingOf(app, res.resultId) : 0;
      if (!ctl.body?.isConnected) return;
      if (res.savable && left === 0) out.querySelector('.rel-session-card')?.insertAdjacentHTML('beforeend', `<p class="rel-confirm-done">${glyph('check')}Observation mémorisée dans la base locale et tracée au journal des associations.</p>`);
      paintFoot(left ?? 1);
    } catch (err) {
      if (!ctl.body?.isConnected) return;
      out.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}${esc(errText(err))}</p>`;
      set([{ id: 'read', label: 'Lire la session', icon: 'monitor', primary: true, kind: 'network', run: read }]);
    }
  }
  function paintFoot(remaining) {
    set(remaining > 0
      ? [{ ...saveButton(remaining, 'la lecture de session'), run: () => app.saveBatches(resultId, { origin: 'Lecture de session' }) },
        { id: 'again', label: 'Relire', icon: 'refresh', kind: 'network', run: read }]
      : [{ id: 'again', label: resultId ? 'Relire' : 'Lire de nouveau', icon: 'refresh', primary: true, kind: 'network', run: read }]);
  }
  set([{ id: 'read', label: 'Lire la session de ce poste', icon: 'monitor', primary: true, kind: 'network', run: read }]);
  return {
    state: () => 'idle',
    refresh: async () => {
      if (!resultId) return;
      const remaining = await remainingOf(app, resultId);
      if (remaining !== null && ctl.body?.isConnected) {
        if (remaining === 0 && !out.querySelector('.rel-confirm-done')) out.querySelector('.rel-session-card')?.insertAdjacentHTML('beforeend', `<p class="rel-confirm-done">${glyph('check')}Observation mémorisée dans la base locale et tracée au journal des associations.</p>`);
        paintFoot(remaining);
      }
    },
  };
}

// ====================================================================================================== Import

const ADAPTERS = [
  { id: 'csv', label: 'CSV générique', accept: '.csv,text/csv', max: 8 * 1024 * 1024, maxLabel: `8${NBSP}Mio`, text: 'Colonnes UserLogin (ou User, Username, SamAccountName) et Computer (ou ComputerName, Hostname), date ISO facultative When.' },
  { id: 'glpi', label: 'Export GLPI (CSV)', accept: '.csv,text/csv', max: 8 * 1024 * 1024, maxLabel: `8${NBSP}Mio`, text: 'Liste des ordinateurs GLPI : Nom, Usager (ou Login), date du dernier inventaire, numéro de série, entité.' },
  { id: 'osquery', label: 'Résultats osquery (JSON)', accept: '.json,.jsonl,.log,application/json', max: 2 * 1024 * 1024, maxLabel: `2${NBSP}Mio`, text: 'Table logged_in_users : journal osqueryd (une ligne JSON par événement) ou tableau d’osqueryi --json avec hostname.' },
];
const CATEGORIES = [
  { id: 'Valide', tone: 'ok' }, { id: 'Conflit', tone: 'alert' }, { id: 'Rejet', tone: 'alert' }, { id: 'Doublon', tone: 'off' },
  { id: 'Déjà connue', tone: 'info' }, { id: 'Inconnue', tone: 'warn' }, { id: 'Reportée', tone: 'warn' },
];
const PART = 500_000;

/** Import of associations with a preview (Domenia 1 CO-08, points 137 and 138). */
export function openImportPanel(app, lastImport) {
  const ctl = workDrawer({
    title: 'Importer des associations', subtitle: 'Aperçu complet avant tout enregistrement', icon: 'download',
    key: 'relations.import', width: 760, minWidth: 520, maxWidth: 1200,
    body: shell(`<div class="rel-import">
      ${lastImport ? `<div class="rel-lastimport">${glyph('history')}<div><b>Dernier import${NBSP}: ${esc(lastImport.fileName)}</b><span>${esc(nouns(lastImport.count, 'association', 'associations'))} · ${esc(lastImport.source)} · ${esc(formatDateTime(lastImport.importedAt) ?? '')}</span></div>
        <button class="btn sm danger" type="button" data-undo data-tip="${esc(lastImport.tip)}">${glyph('undo')}Annuler l’import</button></div>` : ''}
      <section class="rel-step-card"><h3><span class="rel-step-n">1</span>Format</h3>
        <div class="rel-adapters" role="radiogroup" aria-label="Format de l’import">${ADAPTERS.map((a, j) => `<label class="rel-adapter" data-j="${j}"><input class="k-radio" type="radio" name="adapter" value="${a.id}"${j === 0 ? ' checked' : ''}><span><b>${esc(a.label)}</b><small>${esc(a.text)}</small></span></label>`).join('')}</div>
      </section>
      <section class="rel-step-card"><h3><span class="rel-step-n">2</span>Fichier</h3>
        <label class="rel-drop"><input type="file" class="visually-hidden" accept="${ADAPTERS[0].accept}">
          <span class="rel-drop-art" aria-hidden="true">${glyph('file')}</span><span class="rel-drop-text"><b>Choisir un fichier</b> ou le déposer ici</span>
          <span class="rel-drop-file"></span></label>
        <p class="rel-note">${glyph('lock')}Le fichier est lu dans la page puis transmis au moteur en mémoire seulement${NBSP}: rien n’est écrit sur le disque, rien ne part sur le réseau. CSV 8${NBSP}Mio, JSON 2${NBSP}Mio, 20${NBSP}000 enregistrements, aperçu de 1${NBSP}000 lignes.</p>
      </section>
      <div class="rel-import-out"></div></div>`),
    actions: [],
  });
  whenOpen(ctl).then((opened) => {
    if (!opened) return;
    const foot = footer(ctl);
    const root = ctl.body;
    const input = root.querySelector('input[type="file"]');
    const drop = root.querySelector('.rel-drop');
    const out = root.querySelector('.rel-import-out');
    let file = null;
    let preview = null;
    let grid = null;
    applyVars(root);
    root.querySelector('[data-undo]')?.addEventListener('click', () => app.undoImport(lastImport.batchId));
    const adapter = () => ADAPTERS.find((a) => a.id === root.querySelector('input[name="adapter"]:checked')?.value) ?? ADAPTERS[0];
    root.querySelectorAll('input[name="adapter"]').forEach((r) => r.addEventListener('change', () => { input.accept = adapter().accept; preview = null; out.innerHTML = ''; paintFoot(); }));
    const choose = (f) => {
      file = f ?? null; preview = null; out.innerHTML = '';
      root.querySelector('.rel-drop-file').textContent = file ? `${file.name} · ${int(Math.ceil(file.size / 1024))}${NBSP}Kio` : '';
      drop.classList.toggle('has-file', Boolean(file));
      paintFoot();
    };
    input.addEventListener('change', () => choose(input.files?.[0]));
    drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('over'); });
    drop.addEventListener('dragleave', () => drop.classList.remove('over'));
    drop.addEventListener('drop', (e) => { e.preventDefault(); drop.classList.remove('over'); choose(e.dataTransfer?.files?.[0]); });
    function paintFoot() {
      const buttons = [{ id: 'close', label: 'Fermer', run: () => ctl.close() }];
      if (preview) buttons.push({ id: 'import', label: `Importer ${nouns(preview.ready, 'association', 'associations')}`, icon: 'check', primary: true, kind: 'write', disabled: preview.ready === 0, reason: preview.ready === 0 ? 'Aucune ligne valide à importer.' : '', run: doImport });
      else buttons.push({ id: 'preview', label: 'Prévisualiser', icon: 'eye', primary: true, disabled: !file, reason: file ? '' : 'Choisissez d’abord un fichier.', run: doPreview });
      foot.set(buttons);
    }
    async function doPreview() {
      if (!file) return;
      const a = adapter();
      // The size is checked before anything is read: a file of hundreds of Mo never freezes the page.
      if (file.size > a.max) {
        out.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}Fichier trop volumineux pour un aperçu ${esc(a.label)}${NBSP}: ${esc(int(Math.ceil(file.size / 1024)))}${NBSP}Kio, limite ${esc(a.maxLabel)}. Découpez le fichier ou filtrez l’export${NBSP}; rien n’a été lu.</p>`;
        return;
      }
      out.innerHTML = `<section class="rel-step-card" aria-busy="true"><div class="rel-bar"><span class="rel-bar-fill"></span></div><p class="rel-status">Lecture du fichier…</p>${sk('w85')}${sk('w70')}</section>`;
      foot.set([{ id: 'close', label: 'Fermer', run: () => ctl.close() }, { id: 'preview', label: 'Aperçu…', primary: true, disabled: true }]);
      try {
        const text = await file.text();
        const id = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, '0')).join('');
        const parts = Math.max(1, Math.ceil(text.length / PART));
        const bar = out.querySelector('.rel-bar-fill');
        for (let i = 0; i < parts; i++) {
          await app.ctx.call('relations.import.stage', { id, part: i, parts, text: text.slice(i * PART, (i + 1) * PART) });
          progressTo(bar, (i + 1) / parts);
        }
        out.querySelector('.rel-status').textContent = 'Aperçu et vérification dans l’index local, sans accès réseau…';
        preview = await app.ctx.call('relations.import.preview', { id, adapter: a.id, fileName: file.name });
        if (!ctl.body?.isConnected) return;
        showPreview();
      } catch (err) {
        preview = null;
        out.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}${esc(errText(err))}</p>`;
      }
      paintFoot();
    }
    function showPreview() {
      const c = preview.counts;
      const counts = { Valide: c.valid, Conflit: c.conflict, Rejet: c.reject, Doublon: c.duplicate, 'Déjà connue': c.known, Inconnue: c.unknown, Reportée: c.deferred };
      out.innerHTML = `<section class="rel-step-card in"><h3><span class="rel-step-n">3</span>Aperçu · rien n’est encore enregistré</h3>
        <div class="rel-import-kpis">${CATEGORIES.map((k, j) => `<div class="rel-ikpi" data-tone="${k.tone}" data-j="${j}"><b class="num" data-count="${counts[k.id]}">0</b><span>${esc(k.id)}</span></div>`).join('')}</div>
        <p class="rel-status">${esc(preview.summary)}</p>${preview.notes.map((n) => `<p class="rel-note">${glyph('info')}${esc(n)}</p>`).join('')}
        <div class="rel-import-grid"></div></section>`;
      applyVars(out);
      out.querySelectorAll('[data-count]').forEach((el, n) => countUp(el, Number(el.dataset.count), { delay: n * 60 }));
      grid?.destroy();
      grid = createGrid(out.querySelector('.rel-import-grid'), {
        key: 'relations.import.apercu', label: 'Aperçu de l’import', rowId: (r) => String(r.record), selection: 'none', height: '360px',
        columns: [
          { id: 'record', label: 'N°', type: 'number', width: 70 },
          { id: 'user', label: 'Utilisateur', mono: true, width: 150 },
          { id: 'computer', label: 'Poste', mono: true, width: 140 },
          { id: 'category', label: 'Décision', type: 'enum', width: 130, options: CATEGORIES.map((k) => ({ value: k.id, label: k.id, tone: k.tone })) },
          { id: 'reason', label: 'Motif', width: 380 },
        ],
        onExport: (csv) => app.exportCsv('import', csv),
      });
      grid.setRows(preview.rows);
    }
    async function doImport() {
      if (!preview) return;
      const done = preview;
      const receipt = await app.plan('relations.import.plan', { previewId: done.id }, `Import · ${done.fileName}`);
      if (!receipt || !ctl.body?.isConnected) return;
      preview = null;
      out.insertAdjacentHTML('afterbegin', `<section class="rel-step-card in rel-import-done"><h3>${glyph('check')}Import enregistré · lot ${esc(done.batchId)}</h3>
        <p class="rel-status">Les associations du fichier ${esc(done.fileName)} sont enregistrées, relues et tracées par un reçu. « Annuler l’import » retire ce lot, même après un redémarrage.</p>
        <div class="rel-inline"><button class="btn sm danger" type="button" data-undo-batch="${esc(done.batchId)}">${glyph('undo')}Annuler cet import${KIND_TAG.write}</button></div></section>`);
      out.querySelector('[data-undo-batch]')?.addEventListener('click', (e) => app.undoImport(e.currentTarget.dataset.undoBatch));
      foot.set([{ id: 'close', label: 'Fermer', primary: true, run: () => ctl.close() }, { id: 'again', label: 'Nouvel import', icon: 'download', run: () => { file = null; input.value = ''; choose(null); } }]);
    }
    ctl.closed.then(() => grid?.destroy());
    paintFoot();
  });
  return ctl;
}

// ====================================================================================================== Orphelines

/** Orphan links: checked against the directory, listed with their reason, removed only once confirmed (Domenia 1 UX-40). */
export function openOrphansPanel(app) {
  const ctl = workDrawer({
    title: 'Associations orphelines', subtitle: 'Compte ou poste absent de l’annuaire', icon: 'trash',
    key: 'relations.orphelines', width: 760, minWidth: 520, maxWidth: 1200,
    body: shell(`<div class="rel-orph">
      <section class="rel-step-card"><h3><span class="rel-step-n">1</span>Contrôle dans l’annuaire</h3>
        <p>Chaque association est confrontée à l’annuaire${NBSP}: un compte ou un poste qui n’y est plus rend le lien orphelin. Un nom absent peut venir d’un renommage${NBSP}: la suppression n’est jamais prouvée.</p>
        <p class="rel-note">${glyph('lock')}Les associations déclarées et importées ne sont jamais proposées. Rien n’est retiré sans confirmation${NBSP}; chaque retrait est journalisé et restaurable.</p></section>
      <div class="rel-orph-out">${upcoming(ORPHAN_STEPS, 2)}</div></div>`),
    actions: [],
  });
  whenOpen(ctl).then((opened) => {
    if (!opened) return;
    const foot = footer(ctl);
    const out = ctl.body.querySelector('.rel-orph-out');
    applyVars(out);
    let check = null;
    let grid = null;
    let removed = 0;
    const paintFoot = (selected = 0) => foot.set(check && check.rows.length
      ? [{ id: 'close', label: 'Fermer', run: () => ctl.close() },
        { id: 'check', label: 'Contrôler de nouveau', icon: 'refresh', kind: 'network', run },
        { id: 'remove', label: `Retirer ${nouns(selected, 'association', 'associations')}`, icon: 'trash', danger: true, kind: 'write', disabled: selected === 0 || selected > 64,
          reason: selected === 0 ? 'Cochez au moins une association orpheline à retirer.' : selected > 64 ? '64 au plus par retrait.' : '', run: remove }]
      : [{ id: 'close', label: 'Fermer', run: () => ctl.close() }, { id: 'check', label: check ? 'Contrôler de nouveau' : 'Contrôler dans l’annuaire', icon: 'search', primary: true, kind: 'network', run }]);
    async function run() {
      out.innerHTML = `<section class="rel-step-card" aria-busy="true"><div class="rel-scan" aria-hidden="true"><span></span></div>${sk('w70')}${sk('w85')}</section>`;
      foot.set([{ id: 'check', label: 'Contrôle…', primary: true, disabled: true }]);
      grid?.destroy(); grid = null;
      try {
        check = await app.ctx.call('relations.orphans.check', {});
        if (!ctl.body?.isConnected) return;
        out.innerHTML = `<section class="rel-step-card in"><p class="rel-status">${esc(check.summary)}</p>${removed ? `<p class="rel-confirm-done">${glyph('check')}${esc(nouns(removed, 'association retirée', 'associations retirées'))} pendant ce panneau, restaurables depuis le journal.</p>` : ''}
          ${check.rows.length ? '<div class="rel-orph-grid"></div>' : empty('check', 'Aucune orpheline', 'Toutes les associations vérifiées désignent un compte et un poste présents.')}</section>`;
        if (check.rows.length) {
          grid = createGrid(out.querySelector('.rel-orph-grid'), {
            key: 'relations.orphelines', label: 'Associations orphelines', rowId: (r) => r.key, selection: 'multi', height: '420px',
            columns: [
              { id: 'userLogin', label: 'Utilisateur', mono: true, width: 150 },
              { id: 'computer', label: 'Poste', mono: true, width: 140 },
              { id: 'reason', label: 'Motif', width: 320 },
              { id: 'source', label: 'Source', width: 180 },
              { id: 'when', label: 'Date', type: 'date', dateStyle: 'datetime', width: 136 },
            ],
            onSelectionChange: (rows) => paintFoot(rows.length),
            onExport: (csv) => app.exportCsv('orphelines', csv),
          });
          grid.setRows(check.rows);
          grid.select(check.rows.filter((r) => r.selected).map((r) => r.key));
          paintFoot(check.rows.filter((r) => r.selected).length);
        } else {
          paintFoot();
        }
        app.touch();
      } catch (err) {
        out.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}${esc(errText(err))}</p>`;
        check = null;
        paintFoot();
      }
    }
    async function remove() {
      const keys = grid ? grid.getSelectedIds() : [];
      if (!keys.length || !check) return;
      const receipt = await app.plan('relations.orphans.plan', { checkId: check.id, keys }, 'Orphelines');
      if (!receipt || !ctl.body?.isConnected) return;
      removed += keys.length;
      // The rows removed leave the list; a new check (a network read) stays the operator’s gesture.
      check = { ...check, rows: check.rows.filter((r) => !keys.includes(r.key)) };
      grid?.setRows(check.rows);
      out.querySelector('.rel-status')?.insertAdjacentHTML('afterend', `<p class="rel-confirm-done">${glyph('check')}${esc(nouns(keys.length, 'association retirée', 'associations retirées'))}, relue${keys.length > 1 ? 's' : ''} et tracée${keys.length > 1 ? 's' : ''} par un reçu. Contrôlez de nouveau pour la suite.</p>`);
      paintFoot(0);
    }
    ctl.closed.then(() => grid?.destroy());
    paintFoot();
  });
  return ctl;
}

// ====================================================================================================== Moisson

/** Harvest of the controller journal (Domenia 1 REL-030): impact estimated and confirmed, couples saved by batches of 64. */
export function openHarvestPanel(app) {
  const ctl = workDrawer({
    title: 'Moisson du journal du contrôleur', subtitle: 'Événements 4768, 4769 et 4624, aucun poste contacté', icon: 'history',
    key: 'relations.moisson', width: 780, minWidth: 520, maxWidth: 1200,
    body: shell(`<div class="rel-harvest">
      <section class="rel-step-card"><h3><span class="rel-step-n">1</span>Fenêtre et limite</h3>
        <div class="rel-inline">
          <label class="rel-num"><span>Jours</span><input class="input" type="number" name="days" min="1" max="30" value="7"></label>
          <label class="rel-num"><span>Événements au plus</span><input class="input" type="number" name="max" min="200" max="20000" step="100" value="5000"></label>
        </div>
        <p class="rel-note">${glyph('shield')}Une seule requête sur le journal Sécurité du contrôleur de la session${NBSP}; les comptes machines sont ignorés, une association existante n’est jamais écrasée.</p></section>
      <div class="rel-harvest-out">${upcoming(HARVEST_STEPS, 2)}</div></div>`),
    actions: [],
  });
  let refresh = null;
  ctl.refresh = () => refresh?.();
  whenOpen(ctl).then((opened) => {
    if (!opened) return;
    const foot = footer(ctl);
    const root = ctl.body;
    const out = root.querySelector('.rel-harvest-out');
    applyVars(out);
    let estimate = null;
    let result = null;
    let grid = null;
    let remaining = 0;
    let selected = 0;
    const read = () => ({
      days: Math.max(1, Math.min(30, Number(root.querySelector('input[name="days"]').value) || 7)),
      maxEvents: Math.max(200, Math.min(20000, Number(root.querySelector('input[name="max"]').value) || 5000)),
    });
    root.querySelectorAll('input[type="number"]').forEach((i) => i.addEventListener('input', () => {
      if (result) return;
      estimate = null; out.innerHTML = upcoming(HARVEST_STEPS, 2); applyVars(out); paint();
    }));
    function paint() {
      if (result) {
        foot.set([{ id: 'close', label: 'Fermer', run: () => ctl.close() },
          { id: 'selection', label: `Enregistrer la sélection (${int(selected)})`, icon: 'check', kind: 'write', disabled: selected === 0 || selected > 64,
            reason: selected > 64 ? '64 au plus par enregistrement : « Tout enregistrer » procède par lots.' : 'Cochez les couples à enregistrer.', run: saveSelection },
          remaining > 0 ? { ...saveButton(remaining, 'la moisson'), id: 'all', run: saveAll } : { id: 'done', label: 'Tout est mémorisé', icon: 'check', disabled: true }]);
      } else if (estimate) {
        foot.set([{ id: 'close', label: 'Fermer', run: () => ctl.close() }, { id: 'run', label: 'Lancer la moisson', icon: 'play', primary: true, kind: 'network', run }]);
      } else {
        foot.set([{ id: 'close', label: 'Fermer', run: () => ctl.close() }, { id: 'estimate', label: 'Estimer l’impact', icon: 'gauge', primary: true, run: estimateIt }]);
      }
    }
    async function estimateIt() {
      try {
        estimate = await app.ctx.call('relations.harvest.estimate', read());
        out.innerHTML = `<section class="rel-step-card in rel-estimate"><h3><span class="rel-step-n">2</span>Impact estimé · à confirmer</h3>
          <div class="rel-import-kpis"><div class="rel-ikpi" data-tone="info"><b class="num">${int(estimate.estimatedEvents)}</b><span>événements</span></div>
            <div class="rel-ikpi" data-tone="info"><b class="num">${int(estimate.estimatedSeconds)}${NBSP}s</b><span>estimées</span></div>
            <div class="rel-ikpi" data-tone="off"><b class="num">${int(estimate.computers)}</b><span>postes concernés</span></div></div>
          <p class="rel-status">${esc(estimate.text)}</p></section>`;
      } catch (err) {
        out.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}${esc(errText(err))}</p>`;
      }
      paint();
    }
    async function run() {
      if (!estimate) return;
      out.insertAdjacentHTML('beforeend', `<section class="rel-step-card rel-harvest-run" aria-busy="true"><div class="rel-scan" aria-hidden="true"><span></span></div>${sk('w70')}${sk('w85')}</section>`);
      foot.set([{ id: 'run', label: 'Moisson en cours…', primary: true, disabled: true }]);
      try {
        result = await app.ctx.call('relations.harvest.run', { estimateId: estimate.id });
        if (!ctl.body?.isConnected) return;
        remaining = result.newCount;
        out.querySelector('.rel-harvest-run').outerHTML = `<section class="rel-step-card in"><h3><span class="rel-step-n">3</span>Couples lus · nouveaux mémorisés</h3>
          <p class="rel-status">${esc(result.message)}</p>
          <div class="rel-harvest-progress"><div class="rel-bar"><span class="rel-bar-fill"></span></div><span class="rel-harvest-left">${esc(nouns(remaining, 'nouveau couple', 'nouveaux couples'))}</span></div>
          <div class="rel-harvest-grid"></div></section>`;
        grid = createGrid(out.querySelector('.rel-harvest-grid'), {
          key: 'relations.moisson', label: 'Couples utilisateur-poste du journal', rowId: (r) => r.key, selection: 'multi', height: '380px',
          columns: [
            { id: 'userLogin', label: 'Utilisateur', mono: true, width: 140 },
            { id: 'computer', label: 'Poste', mono: true, width: 130 },
            { id: 'lastSeen', label: 'Dernier', type: 'date', dateStyle: 'datetime', width: 136 },
            { id: 'events', label: 'Événements', type: 'number', width: 110 },
            { id: 'eventIds', label: 'Identifiants', width: 140 },
            { id: 'known', label: 'Déjà connu', type: 'bool', width: 110 },
          ],
          onSelectionChange: (rows) => { selected = rows.filter((r) => !r.known).length; paint(); },
          onExport: (csv) => app.exportCsv('moisson', csv),
        });
        grid.setRows(result.couples);
        selected = 0;
        paint();
        app.touch();
        await refresh();
        announce(result.message);
      } catch (err) {
        out.querySelector('.rel-harvest-run').outerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}${esc(errText(err))}</p>`;
        estimate = null;
        paint();
      }
    }
    async function saveSelection() {
      const chosen = grid ? grid.getSelection().filter((r) => !r.known) : [];
      if (!chosen.length || !result) return;
      const receipt = await app.plan('relations.observations.plan', { resultId: result.resultId, keys: chosen.map((r) => r.key) }, 'Moisson du journal · sélection');
      // The couples recorded leave the selection and read « Déjà connu »: a second click never plans them again.
      if (grid && receipt && (receipt.result === 'applied' || receipt.result === 'noChange') && ctl.body?.isConnected) {
        const saved = new Set(chosen.map((r) => r.key));
        result.couples = result.couples.map((c) => (saved.has(c.key) ? { ...c, known: true } : c));
        grid.setRows(result.couples, { keepSelection: false, keepScroll: true });
        selected = 0;
        paint();
      }
    }
    function saveAll() {
      if (!result) return;
      app.saveBatches(result.resultId, { origin: 'Moisson du journal' });
    }
    refresh = async () => {
      if (!result) return;
      const left = await remainingOf(app, result.resultId);
      if (left === null || !ctl.body?.isConnected) return;
      remaining = left;
      const total = Math.max(1, result.newCount);
      progressTo(out.querySelector('.rel-harvest-progress .rel-bar-fill'), (total - remaining) / total);
      const text = out.querySelector('.rel-harvest-left');
      if (text) text.textContent = remaining > 0 ? `${int(total - remaining)} sur ${int(total)} mémorisés · ${nouns(remaining, 'reste', 'restent')} ${int(remaining)}` : `${nouns(total, 'nouveau couple mémorisé', 'nouveaux couples mémorisés')} automatiquement`;
      paint();
    };
    ctl.closed.then(() => grid?.destroy());
    paint();
  });
  return ctl;
}

// ====================================================================================================== Relevé du parc

/** Incremental relevé of the parc (Domenia 1 REL-031): priority queue or loaded list, ping by batches, consoles read on a click. */
export function openSweepPanel(app) {
  const loaded = app.loadedComputers();
  const ctl = workDrawer({
    title: 'Relevé des consoles du parc', subtitle: app.scopeLabel() ? `OU de travail ${app.scopeLabel()}` : 'OU de travail', icon: 'monitor',
    key: 'relations.releve', width: 700, minWidth: 480, maxWidth: 1100,
    body: shell(`<div class="rel-sweep">
      <section class="rel-step-card"><h3><span class="rel-step-n">1</span>Périmètre et file de priorité</h3>
        <div class="rel-radios" role="radiogroup" aria-label="Périmètre du relevé">
          <label class="rel-radio"><input class="k-radio" type="radio" name="sweep" value="ou" checked><span><b>OU de travail${app.scopeLabel() ? ` · ${esc(app.scopeLabel())}` : ''}</b><small>Jamais relevés d’abord, puis les relevés les plus anciens${NBSP}; un poste non réauthentifié depuis son relevé n’est pas redemandé.</small></span></label>
          <label class="rel-radio${loaded ? '' : ' off'}"><input class="k-radio" type="radio" name="sweep" value="loaded"${loaded ? '' : ' disabled'}><span><b>Machines de la liste chargée</b><small>${loaded ? esc(loaded.label) : 'Aucune liste chargée : filtrez « Toutes les associations » ou venez de Rechercher avec une liste de postes.'}</small></span></label>
        </div>
        <div class="rel-inline"><label class="rel-num"><span>Postes au plus</span><input class="input" type="number" name="limit" min="1" max="50" value="20"></label></div>
        <p class="rel-note">${glyph('shield')}Jamais le domaine entier${NBSP}; ping groupé par lots de 8 avant toute lecture de session, report au relevé suivant au-delà de la limite.</p></section>
      <div class="rel-sweep-out">${upcoming(SWEEP_STEPS, 2)}</div></div>`),
    actions: [],
  });
  let stop = null;
  let refresh = null;
  ctl.refresh = () => refresh?.();
  whenOpen(ctl).then((opened) => {
    if (!opened) return;
    const foot = footer(ctl);
    const out = ctl.body.querySelector('.rel-sweep-out');
    let resultId = null;
    applyVars(out);
    ctl.closed.then(() => stop?.());
    const forget = { id: 'forget', label: 'Oublier les relevés…', icon: 'trash', kind: 'write', run: () => app.plan('relations.sweep.forget.plan', {}, 'Mémoire des relevés du parc') };
    const set = (buttons) => foot.set([{ id: 'close', label: 'Fermer', run: () => ctl.close() }, ...buttons]);
    async function prepare() {
      const limit = Math.max(1, Math.min(50, Number(ctl.body.querySelector('input[name="limit"]').value) || 20));
      const scope = ctl.body.querySelector('input[name="sweep"]:checked')?.value ?? 'ou';
      try {
        const plan = await app.ctx.call('relations.sweep.plan', { limit, computers: scope === 'loaded' ? (app.loadedComputers()?.names ?? []) : [] });
        if (!ctl.body?.isConnected) return;
        out.innerHTML = `<section class="rel-step-card in rel-plan ${plan.allowed ? '' : 'refused'}"><h3><span class="rel-step-n">2</span>Postes à relever · ${esc(plan.scopeLabel)}</h3>
          ${plan.allowed ? `<p>${esc(plan.text)}</p><ul class="rel-plan-targets">${plan.targets.map((t, j) => `<li data-j="${Math.min(j, 24)}" data-tip="${esc(t.source)}">${glyph('monitor')}${esc(t.computer)}</li>`).join('')}</ul>`
            : `<p class="rel-note warn">${glyph('info')}${esc(plan.reason)}</p>`}</section>`;
        applyVars(out);
        set(plan.allowed ? [forget, { id: 'run', label: `Lancer le relevé (${int(plan.targets.length)})`, icon: 'play', primary: true, kind: 'network', run: () => run(plan) }] : [forget, { id: 'prepare', label: 'Préparer la file', icon: 'refresh', run: prepare }]);
      } catch (err) {
        out.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}${esc(errText(err))}</p>`;
        set([forget, { id: 'prepare', label: 'Préparer la file', icon: 'refresh', primary: true, run: prepare }]);
      }
    }
    function run(plan) {
      const probeHost = document.createElement('section');
      probeHost.className = 'rel-step-card in';
      out.prepend(probeHost);
      set([{ id: 'stop', label: 'Arrêter', icon: 'pause', danger: true, run: () => { stop?.(); set([{ id: 'stopping', label: 'Arrêt demandé…', disabled: true }]); } }]);
      stop = runProbe(app, probeHost, plan.id, plan.targets.length, (res, err) => {
        stop = null;
        if (!ctl.body?.isConnected) return;
        if (err) {
          probeHost.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}${esc(errText(err))}</p>`;
          set([forget, { id: 'prepare', label: 'Préparer la file', icon: 'refresh', run: prepare }]);
          return;
        }
        resultId = res.resultId;
        probeHost.innerHTML = `<h3><span class="rel-step-n">3</span>Relevé${res.counters?.stopped ? ' partiel' : ''}</h3><p class="rel-status">${esc(res.message)}</p>${refusalCard(res)}${candidatesMarkup(res.candidates, { associate: false })}${attemptsMarkup(res.attempts)}`;
        applyVars(probeHost);
        bindRefusal(probeHost, (id, p) => app.ctx.navigate(id, p));
        probeHost.querySelectorAll('[data-fiche]').forEach((b) => b.addEventListener('click', () => app.openFiche({ dn: b.dataset.fiche })));
        app.touch();
        remainingOf(app, res.resultId).then((left) => { if (ctl.body?.isConnected) resultFoot(left ?? res.savable); });
      });
    }
    function resultFoot(remaining) {
      set(remaining > 0
        ? [{ ...saveButton(remaining, 'le relevé'), run: () => app.saveBatches(resultId, { origin: 'Relevé du parc' }) }, { id: 'prepare', label: 'Préparer une nouvelle file', icon: 'refresh', run: prepare }]
        : [forget, { id: 'prepare', label: 'Préparer une nouvelle file', icon: 'refresh', primary: true, run: prepare }]);
    }
    refresh = async () => {
      if (!resultId || stop) return;
      const remaining = await remainingOf(app, resultId);
      if (remaining !== null && ctl.body?.isConnected) resultFoot(remaining);
    };
    set([forget, { id: 'prepare', label: 'Préparer la file', icon: 'sliders', primary: true, run: prepare }]);
  });
  return ctl;
}

// ====================================================================================================== Aide

/** Precautions of the screen (Domenia 1 « ? » of Relations, REL-048). */
export function openHelpPanel() {
  const items = [
    ['shield', 'Associations locales', 'Une association est une donnée de Domenia : Active Directory n’est jamais modifié, ni par un ajout, ni par un retrait, ni par un import.'],
    ['eye', 'Observer n’est pas affecter', 'Une session observée ne devient jamais une affectation déclarée ; les deux restent visibles côte à côte. Un historique ne contredit jamais une affectation.'],
    ['alert', 'Contradictions conservées', 'Quand l’affectation déclarée et la session observée désignent des comptes différents, les deux gardent leur nature et portent la marque « Contradiction » : rien n’est fusionné ni retiré.'],
    ['key', 'Identité par GUID', 'Un lien porteur de GUID n’appartient qu’à cet objet ; un nom recyclé n’hérite jamais de l’historique d’un autre. Sans GUID, l’identité est dite non vérifiable. Une association préparée vérifie que le sujet et la cible portent encore le GUID affiché.'],
    ['wifi', 'Aucune sonde sans geste', 'La détection lit d’abord l’annuaire, montre la liste exacte des postes, puis seulement « Lancer la détection » contacte les postes, 50 au plus, sans jamais substituer le domaine entier ; elle s’arrête au premier refus d’identifiants.'],
    ['layers', 'Mémorisation par lots', 'Les observations (détection, lecture de session, relevé, moisson) sont mémorisées automatiquement dans la base locale par lots de 64, sans confirmation, chaque changement tracé au journal des associations ; Active Directory n’est jamais modifié.'],
    ['edit', 'Chaque changement a son reçu', 'Ajouter, retirer, restaurer, importer, annuler un import, nettoyer, oublier les relevés : un plan relu, une confirmation, un reçu, une relecture. Jamais rejoué automatiquement.'],
    ['undo', 'Tout se restaure', 'Chaque retrait est journalisé et restaurable ; un import porte un lot qui s’annule même après un redémarrage.'],
  ].map(([i, t, x]) => [i, t, x.replace(/ ([:;!?])/g, `${NBSP}$1`)]);
  return openDrawer({
    title: 'Précautions des relations', subtitle: 'Ce que l’écran garantit', icon: 'info', key: 'relations.aide', width: 560,
    body: shell(`<ul class="rel-help">${items.map(([i, t, x], j) => `<li data-j="${j}"><span class="rel-help-ico">${glyph(i)}</span><div><b>${esc(t)}</b><p>${esc(x)}</p></div></li>`).join('')}</ul>`),
    actions: [{ id: 'close', label: 'Fermer', primary: true, run: (p) => p.close() }],
  });
}
