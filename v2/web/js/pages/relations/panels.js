// Utilisateurs et postes · side panels: « Ajouter » (manual search of a target, detection of the workstations of a user,
// session of a workstation), import with preview, orphan check, harvest of the controller journal, relevé of the working OU
// and the precautions of the screen. Every network read starts on an explicit click; a detection shows the exact list of
// workstations before contacting any; every change is a plan of the write circuit, opened once the panel is closed (one
// modal panel at a time). Content carries data-page="relations" so the page stylesheet scopes it (docs/KIT.md § 3).
import { openDrawer } from '../../kit/drawer.js';
import { createGrid } from '../../kit/grid.js';
import { glyph } from '../../kit/glyphs.js';
import { uid } from '../../kit/util.js';
import { onEvent } from '../../bridge.js';
import { applyVars, announce, countUp, progressTo, formatDateTime, inkFollow } from '../../ui.js';
import { badge, avatar, esc, int, nouns, NBSP, errText, tonePill, empty, sk } from './model.js';

const KIND_TAG = {
  network: `<span class="rel-kind net" data-tip="Lecture réseau : part seulement sur ce clic">${glyph('wifi')}réseau</span>`,
  write: `<span class="rel-kind wr" data-tip="Écriture locale : plan, confirmation et reçu avant tout changement">${glyph('edit')}écriture</span>`,
};

function shell(inner) {
  return `<div class="rel-panel" data-page="relations">${inner}</div>`;
}

/** Resolves once the drawer is really open (a request waits while another modal panel is open). */
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
      ctl.foot.innerHTML = buttons.map((b) => `<button class="btn${b.primary ? ' primary' : ''}${b.danger ? ' danger' : ''}${!b.primary && !b.danger ? ' subtle' : ''}" type="button" data-rf="${esc(b.id)}"${b.disabled ? ' disabled' : ''}${b.reason ? ` data-tip="${esc(b.reason)}"` : ''}>${b.icon ? glyph(b.icon) : ''}${esc(b.label)}${b.kind ? KIND_TAG[b.kind] : ''}</button>`).join('');
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
  ['Couples lus', 'Utilisateur → poste trouvés, déjà connus signalés : rien n’est encore enregistré.'],
  ['Enregistrement', 'Plan relu, confirmation et reçu ; une association existante n’est jamais écrasée.'],
];
const DETECT_STEPS = [
  ['Lecture de l’annuaire', 'Compte relu, associations connues, managedBy et mentions du compte : aucun poste contacté.'],
  ['Postes à interroger', 'La liste exacte du périmètre, 50 postes au plus, avant toute sonde.'],
  ['Détection et résultat', 'Console de chaque poste, compteurs en direct, puis enregistrement des consoles confirmées sur votre confirmation.'],
];
const SWEEP_STEPS = [
  ['Postes à relever', 'La liste exacte des postes, avant tout contact.'],
  ['Relevé', 'Console de chaque poste, compteurs en direct, arrêt possible à tout moment.'],
  ['Enregistrement', 'Les consoles confirmées, par plan, confirmation et reçu.'],
];

/** REL-029: refused workstations are said, never retried; another account is the operator’s explicit choice. */
function refusalNote(res) {
  const refused = res?.counters?.refused ?? 0;
  if (!refused) return '';
  return `<p class="rel-note warn rel-refused">${glyph('lock')}<span>${nouns(refused, 'poste a refusé', 'postes ont refusé')} la lecture avec le compte de la session : aucune nouvelle tentative. Pour ces postes, ouvrez une session avec un compte autorisé, puis relancez vous-même la détection.</span></p>`;
}

function attemptsMarkup(attempts) {
  if (!attempts?.length) return '';
  return `<details class="rel-attempts"><summary>${glyph('sliders')}Détail des tentatives (${int(attempts.length)})</summary>
    <ol>${attempts.map((a, j) => `<li data-j="${Math.min(j, 20)}">${tonePill(a.tone, a.statusLabel)}<div><b>${esc(a.method)}</b>${a.target ? `<span class="mono">${esc(a.target)}</span>` : ''}<p>${esc(a.detail)}</p></div>
      <span class="rel-att-ms">${int(a.durationMs)}${NBSP}ms</span></li>`).join('')}</ol></details>`;
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
    ? [{ id: 'detecter', label: 'Détecter les postes', icon: 'wifi' }, { id: 'rechercher', label: 'Rechercher un poste', icon: 'search' }]
    : [{ id: 'session', label: 'Lire la session', icon: 'monitor' }, { id: 'rechercher', label: 'Rechercher un utilisateur', icon: 'search' }];
  let current = modes.some((m) => m.id === mode) ? mode : modes[0].id;
  const ctl = openDrawer({
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
  let stopProbe = null;
  whenOpen(ctl).then((opened) => {
    if (!opened) return;
    const foot = footer(ctl);
    const host = ctl.body.querySelector('.rel-add-body');
    const seg = ctl.body.querySelector('.rel-add-modes');
    const ink = inkFollow(seg, 'button', 'button[aria-pressed="true"]');
    seg.addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-mode]') : null;
      if (!b || b.dataset.mode === current) return;
      stopProbe?.();
      current = b.dataset.mode;
      seg.querySelectorAll('[data-mode]').forEach((x) => x.setAttribute('aria-pressed', String(x.dataset.mode === current)));
      ink.update();
      paint();
    });
    ctl.closed.then(() => { stopProbe?.(); ink.stop(); });
    const paint = () => {
      if (current === 'rechercher') searchMode(app, ctl, host, foot, subject);
      else if (current === 'detecter') stopProbe = detectMode(app, ctl, host, foot, subject);
      else sessionMode(app, ctl, host, foot, subject);
    };
    paint();
  });
  return ctl;
}

const STATES = [
  { id: 'searching', label: 'Recherche' },
  { id: 'candidate', label: 'Choix' },
  { id: 'pending', label: 'Confirmation' },
  { id: 'saved', label: 'Plan et reçu' },
];

function stepper(state) {
  const at = STATES.findIndex((s) => s.id === state);
  return `<ol class="rel-steps" aria-label="Étapes de l’association">${STATES.map((s, i) => `<li class="${i < at ? 'done' : i === at ? 'now' : ''}" data-j="${i}"${i === at ? ' aria-current="step"' : ''}><span class="rel-step-mark" aria-hidden="true">${i < at ? glyph('check') : i + 1}</span>${esc(s.label)}</li>`).join('')}</ol>`;
}

function searchMode(app, ctl, host, foot, subject) {
  const isUser = subject.kind === 'user';
  const fieldId = uid('relsearch');
  let state = 'idle';
  let rows = [];
  let chosen = null;
  let request = 0;
  host.innerHTML = `<div class="rel-mode">
    <div class="rel-steps-host">${stepper('searching')}</div>
    <form class="rel-search" novalidate>
      <label class="visually-hidden" for="${fieldId}">${isUser ? 'Poste à associer' : 'Utilisateur à associer'}</label>
      <span class="rel-search-ico" aria-hidden="true">${glyph('search')}</span>
      <input class="input" id="${fieldId}" type="search" autocomplete="off" spellcheck="false" maxlength="100"
        placeholder="${isUser ? 'Nom ou nom DNS du poste' : 'Identifiant, nom ou UPN'}">
      <button class="btn" type="submit">${glyph('search')}Rechercher${KIND_TAG.network}</button>
    </form>
    <p class="rel-status" role="status">Recherche dans tout le domaine, sur votre geste${NBSP}; le sujet reste ${esc(subject.login)}.</p>
    <div class="rel-search-hint"><span class="rel-hint-art" aria-hidden="true">${glyph(isUser ? 'monitor' : 'user')}</span>
      <p>${isUser ? 'Exemples' : 'Exemples'}${NBSP}: <span class="mono">${isUser ? 'PC-PAR-0042' : 'j.martin'}</span>, <span class="mono">${isUser ? 'pt-lyo' : 'martin'}</span>. Deux caractères au moins, puis Entrée. La cible choisie est relue au moment du plan.</p></div>
    <ul class="rel-results" role="listbox" aria-label="${isUser ? 'Postes trouvés' : 'Utilisateurs trouvés'}"></ul>
    <div class="rel-confirm" hidden></div>
  </div>`;
  const input = host.querySelector('input');
  const status = host.querySelector('.rel-status');
  const list = host.querySelector('.rel-results');
  const confirm = host.querySelector('.rel-confirm');
  const setState = (next) => {
    state = next;
    host.querySelector('.rel-steps-host').innerHTML = stepper(next === 'idle' ? 'searching' : next);
    applyVars(host);
    paintFoot();
  };
  function paintFoot() {
    foot.set([
      { id: 'close', label: 'Fermer', run: () => ctl.close() },
      { id: 'associate', label: isUser ? 'Associer ce poste' : 'Associer cet utilisateur', icon: 'link', primary: true, kind: 'write',
        disabled: state !== 'pending', reason: state !== 'pending' ? 'Choisissez d’abord une ligne dans les résultats.' : '', run: associate },
    ]);
  }
  function associate() {
    if (!chosen) return;
    const target = chosen;
    ctl.close();
    app.plan('relations.associate.plan', { dn: subject.dn, target: target.dn }, `${subject.login} → ${target.login}`);
  }
  // A new term invalidates the results and the association prepared from them (Domenia 1 REL-001).
  input.addEventListener('input', () => {
    if (!rows.length && !chosen) return;
    rows = []; chosen = null; list.innerHTML = ''; confirm.hidden = true;
    setState('idle');
    status.textContent = 'Nouveau terme : relancez la recherche.';
  });
  host.querySelector('form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (text.length < 2) { status.textContent = 'Saisissez au moins deux caractères.'; input.focus(); return; }
    const my = ++request;
    chosen = null; confirm.hidden = true;
    host.querySelector('.rel-search-hint')?.remove();
    setState('searching');
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
      status.textContent = res.message;
      setState(rows.length ? 'candidate' : 'idle');
      announce(res.message);
    } catch (err) {
      if (my !== request) return;
      list.removeAttribute('aria-busy');
      list.innerHTML = '';
      status.textContent = `Recherche non confirmée${NBSP}: ${errText(err)}`;
      setState('idle');
    }
  });
  const pick = (li) => {
    const row = rows.find((r) => r.dn === li.dataset.dn);
    if (!row || state === 'searching') return;
    chosen = row;
    list.querySelectorAll('.rel-result').forEach((x) => { const on = x === li; x.classList.toggle('chosen', on); x.setAttribute('aria-selected', String(on)); });
    const user = isUser ? subject : row;
    const computer = isUser ? row : subject;
    confirm.hidden = false;
    confirm.innerHTML = `<div class="rel-confirm-card">
      <div class="rel-confirm-pair">${avatar('user', user.name, 'md')}<span class="rel-confirm-line" aria-hidden="true"><span></span></span>${avatar('computer', computer.name, 'md')}</div>
      <p class="rel-confirm-text"><b>${esc(user.login)}</b> → <b>${esc(computer.name)}</b> · ${badge('declared', { size: 'sm' })} (Saisie manuelle)</p>
      <p class="rel-confirm-note">${glyph('lock')}Association locale à Domenia${NBSP}: Active Directory n’est pas modifié. Le sujet et la cible sont relus au moment du plan, puis vous confirmez.</p>
      ${row.alreadyLinked ? `<p class="rel-confirm-note warn">${glyph('info')}Une relation existe déjà entre eux${NBSP}: une affectation déclarée s’ajoute à côté, ou met à jour sa date si elle existait.</p>` : ''}
    </div>`;
    confirm.classList.remove('in'); void confirm.offsetWidth; confirm.classList.add('in');
    setState('pending');
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
    <p class="rel-probe-text">Lecture des consoles du périmètre confirmé…</p>
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
      ${associate && c.associable && c.dn ? `<button class="btn xs" type="button" data-associate="${esc(c.dn)}" data-tip="Préparer son association déclarée">${glyph('link')}Associer</button>` : ''}</div></li>`).join('')}</ul>`;
}

function detectMode(app, ctl, host, foot, subject) {
  let stop = null;
  const scopeLabel = app.scopeLabel();
  host.innerHTML = `<div class="rel-mode rel-detect">
    <section class="rel-step-card">
      <h3><span class="rel-step-n">1</span>Périmètre</h3>
      <div class="rel-radios" role="radiogroup" aria-label="Périmètre de détection">
        <label class="rel-radio"><input class="k-radio" type="radio" name="scope" value="candidates" checked><span><b>Postes connus et candidats de l’annuaire</b><small>Associations mémorisées, managedBy, mentions du compte.</small></span></label>
        <label class="rel-radio"><input class="k-radio" type="radio" name="scope" value="ou"><span><b>OU de travail${scopeLabel ? ` · ${esc(scopeLabel)}` : ''}</b><small>Postes de l’OU explicite, jamais le domaine entier.</small></span></label>
      </div>
      <div class="rel-inline">
        <label class="rel-num"><span>Postes au plus</span><input class="input" type="number" name="limit" min="1" max="50" value="20"></label>
        <label class="rel-switch"><input class="switch" type="checkbox" role="switch" name="kerberos"><span>Indices Kerberos du contrôleur (7 jours)</span></label>
      </div>
      <p class="rel-note">${glyph('shield')}Rien n’est sondé à cette étape${NBSP}: l’annuaire est lu, puis la liste exacte des postes à interroger vous est montrée avant tout contact.</p>
    </section>
    <div class="rel-detect-out">${upcoming(DETECT_STEPS, 2)}</div>
  </div>`;
  const out = host.querySelector('.rel-detect-out');
  applyVars(out);
  const values = () => ({
    scope: host.querySelector('input[name="scope"]:checked')?.value ?? 'candidates',
    limit: Math.max(1, Math.min(50, Number(host.querySelector('input[name="limit"]').value) || 20)),
    kerberos: host.querySelector('input[name="kerberos"]').checked,
  });
  const setFoot = (buttons) => foot.set([{ id: 'close', label: 'Fermer', run: () => ctl.close() }, ...buttons]);
  setFoot([{ id: 'collect', label: 'Lire l’annuaire', icon: 'search', primary: true, kind: 'network', run: collect }]);

  async function collect() {
    const v = values();
    out.innerHTML = `<section class="rel-step-card" aria-busy="true">${sk('w40')}${sk('w85')}${sk('w70')}${sk('w55')}</section>`;
    setFoot([{ id: 'collect', label: 'Lecture de l’annuaire…', icon: 'search', primary: true, disabled: true }]);
    try {
      const res = await app.ctx.call('relations.detect.collect', { dn: subject.dn, scope: v.scope, ouDn: null, computers: [], limit: v.limit, kerberos: v.kerberos });
      showCollect(res);
    } catch (err) {
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
        <h3><span class="rel-step-n">3</span>Périmètre à confirmer</h3>
        ${plan.allowed ? `<p>${esc(plan.text)}</p><ul class="rel-plan-targets">${plan.targets.map((t, j) => `<li data-j="${Math.min(j, 24)}" data-tip="${esc(t.source)}">${glyph('monitor')}${esc(t.computer)}</li>`).join('')}</ul>`
          : `<p class="rel-note warn">${glyph('info')}${esc(plan.reason)} ${esc(plan.zeroMeaning)}</p>`}
      </section>`;
    applyVars(out);
    bindAssociate(out);
    setFoot(plan.allowed
      ? [{ id: 'run', label: `Lancer la détection (${int(plan.targets.length)})`, icon: 'play', primary: true, kind: 'network', run: () => probe(plan) }]
      : [{ id: 'collect', label: 'Relire l’annuaire', icon: 'refresh', kind: 'network', run: collect }]);
  }

  function probe(plan) {
    const probeHost = document.createElement('section');
    probeHost.className = 'rel-step-card in';
    out.prepend(probeHost);
    probeHost.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    setFoot([{ id: 'stop', label: 'Arrêter', icon: 'pause', danger: true, run: () => { stop?.(); setFoot([{ id: 'stopping', label: 'Arrêt demandé…', disabled: true }]); } }]);
    stop = runProbe(app, probeHost, plan.id, plan.targets.length, (res, err) => {
      stop = null;
      if (err) {
        probeHost.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}Détection non terminée${NBSP}: ${esc(errText(err))} Les liens existants sont conservés.</p>`;
        setFoot([{ id: 'collect', label: 'Relire l’annuaire', icon: 'refresh', kind: 'network', run: collect }]);
        return;
      }
      probeHost.innerHTML = `<h3><span class="rel-step-n">4</span>Résultat${res.counters?.stopped ? ' partiel' : ''}</h3><p class="rel-status">${esc(res.message)}</p>
        ${refusalNote(res)}${candidatesMarkup(res.candidates)}${attemptsMarkup(res.attempts)}`;
      applyVars(probeHost);
      bindAssociate(probeHost);
      announce(res.message);
      app.touch();
      setFoot(res.savable > 0
        ? [{ id: 'save', label: `Enregistrer ${nouns(res.savable, 'console confirmée', 'consoles confirmées')}`, icon: 'check', primary: true, kind: 'write', run: () => { ctl.close(); app.plan('relations.observations.plan', { resultId: res.resultId, keys: [] }, 'Consoles confirmées'); } }]
        : [{ id: 'collect', label: 'Nouvelle détection', icon: 'refresh', kind: 'network', run: collect }]);
    });
  }

  function bindAssociate(scope) {
    scope.querySelectorAll('[data-associate]').forEach((b) => b.addEventListener('click', () => {
      const dn = b.dataset.associate;
      ctl.close();
      app.plan('relations.associate.plan', { dn: subject.dn, target: dn }, `${subject.login} → ${b.closest('.rel-cand')?.querySelector('b')?.textContent ?? ''}`);
    }));
  }
  return () => stop?.();
}

function sessionMode(app, ctl, host, foot, subject) {
  host.innerHTML = `<div class="rel-mode">
    <section class="rel-step-card">
      <h3>${glyph('monitor')}Session console de ${esc(subject.name)}</h3>
      <p>Lit l’utilisateur console du poste (Win32_ComputerSystem par CIM/DCOM, 4${NBSP}s), puis contrôle son identité${NBSP}: un compte local, d’un autre domaine ou non qualifié n’est jamais le compte AD.</p>
      <p class="rel-note">${glyph('shield')}Geste explicite${NBSP}: une seule lecture, aucun rejeu. Rien n’est enregistré sans votre confirmation.</p>
    </section>
    <div class="rel-session-out"></div></div>`;
  const out = host.querySelector('.rel-session-out');
  const set = (buttons) => foot.set([{ id: 'close', label: 'Fermer', run: () => ctl.close() }, ...buttons]);
  async function read() {
    out.innerHTML = `<section class="rel-step-card" aria-busy="true"><div class="rel-scan" aria-hidden="true"><span></span></div>${sk('w70')}${sk('w55')}</section>`;
    set([{ id: 'read', label: 'Lecture…', icon: 'monitor', primary: true, disabled: true }]);
    try {
      const res = await app.ctx.call('relations.computer.read', { dn: subject.dn });
      const o = res.observed;
      out.innerHTML = `<section class="rel-step-card in rel-session-card${o?.match ? ' ok' : ''}">
        ${o ? `<div class="rel-session-who">${avatar('user', o.userName ?? o.login, 'lg')}<div><span class="rel-k">Compte console</span><b>${esc(o.userName ?? o.login)}</b><span class="mono">${esc(o.account)}</span></div>
          ${badge(o.badge, { label: o.badgeLabel })}</div>
          <p class="rel-session-check ${o.match ? 'ok' : 'warn'}">${glyph(o.match ? 'shield' : 'alert')}${esc(o.reason)}</p>` : ''}
        <p class="rel-status">${esc(res.message)}</p>${attemptsMarkup(res.attempts)}</section>`;
      applyVars(out);
      app.touch();
      announce(res.message);
      set(res.savable
        ? [{ id: 'save', label: 'Enregistrer l’observation', icon: 'check', primary: true, kind: 'write', run: () => { ctl.close(); app.plan('relations.observations.plan', { resultId: res.resultId, keys: [] }, 'Session observée'); } },
          { id: 'again', label: 'Relire', icon: 'refresh', kind: 'network', run: read }]
        : [{ id: 'again', label: 'Relire', icon: 'refresh', primary: true, kind: 'network', run: read }]);
    } catch (err) {
      out.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}${esc(errText(err))}</p>`;
      set([{ id: 'read', label: 'Lire la session', icon: 'monitor', primary: true, kind: 'network', run: read }]);
    }
  }
  set([{ id: 'read', label: 'Lire la session de ce poste', icon: 'monitor', primary: true, kind: 'network', run: read }]);
}

// ====================================================================================================== Import

const ADAPTERS = [
  { id: 'csv', label: 'CSV générique', accept: '.csv,text/csv', max: 8 * 1024 * 1024, text: 'Colonnes UserLogin (ou User, Username, SamAccountName) et Computer (ou ComputerName, Hostname), date ISO facultative When.' },
  { id: 'glpi', label: 'Export GLPI (CSV)', accept: '.csv,text/csv', max: 8 * 1024 * 1024, text: 'Liste des ordinateurs GLPI : Nom, Usager (ou Login), date du dernier inventaire, numéro de série, entité.' },
  { id: 'osquery', label: 'Résultats osquery (JSON)', accept: '.json,.jsonl,.log,application/json', max: 2 * 1024 * 1024, text: 'Table logged_in_users : journal osqueryd (une ligne JSON par événement) ou tableau d’osqueryi --json avec hostname.' },
];
const CATEGORIES = [
  { id: 'Valide', tone: 'ok' }, { id: 'Conflit', tone: 'alert' }, { id: 'Rejet', tone: 'alert' }, { id: 'Doublon', tone: 'off' },
  { id: 'Déjà connue', tone: 'info' }, { id: 'Inconnue', tone: 'warn' }, { id: 'Reportée', tone: 'warn' },
];
const PART = 500_000;

/** Import of associations with a preview (Domenia 1 CO-08, points 137 and 138). */
export function openImportPanel(app, lastImport) {
  const ctl = openDrawer({
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
    applyVars(root);
    root.querySelector('[data-undo]')?.addEventListener('click', () => { ctl.close(); app.undoImport(lastImport.batchId); });
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
      const buttons = [{ id: 'close', label: 'Annuler', run: () => ctl.close() }];
      if (preview) buttons.push({ id: 'import', label: `Importer ${nouns(preview.ready, 'association', 'associations')}`, icon: 'check', primary: true, kind: 'write', disabled: preview.ready === 0, reason: preview.ready === 0 ? 'Aucune ligne valide à importer.' : '', run: doImport });
      else buttons.push({ id: 'preview', label: 'Prévisualiser', icon: 'eye', primary: true, disabled: !file, reason: file ? '' : 'Choisissez d’abord un fichier.', run: doPreview });
      foot.set(buttons);
    }
    async function doPreview() {
      if (!file) return;
      const a = adapter();
      out.innerHTML = `<section class="rel-step-card" aria-busy="true"><div class="rel-bar"><span class="rel-bar-fill"></span></div><p class="rel-status">Lecture du fichier…</p>${sk('w85')}${sk('w70')}</section>`;
      foot.set([{ id: 'close', label: 'Annuler', run: () => ctl.close() }, { id: 'preview', label: 'Aperçu…', primary: true, disabled: true }]);
      try {
        const text = await file.text();
        if (text.length > a.max) throw Object.assign(new Error(`Fichier trop volumineux pour un aperçu ${a.label} : ${int(text.length)} caractères, limite ${int(a.max)}. Découpez le fichier ou filtrez l’export.`), { code: 'relation.importTooLarge' });
        const id = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, '0')).join('');
        const parts = Math.max(1, Math.ceil(text.length / PART));
        const bar = out.querySelector('.rel-bar-fill');
        for (let i = 0; i < parts; i++) {
          await app.ctx.call('relations.import.stage', { id, part: i, parts, text: text.slice(i * PART, (i + 1) * PART) });
          progressTo(bar, (i + 1) / parts);
        }
        out.querySelector('.rel-status').textContent = 'Aperçu et vérification dans l’index local, sans accès réseau…';
        preview = await app.ctx.call('relations.import.preview', { id, adapter: a.id, fileName: file.name });
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
      const grid = createGrid(out.querySelector('.rel-import-grid'), {
        key: 'relations.import.apercu', label: 'Aperçu de l’import', rowId: (r) => String(r.record), selection: 'none', height: '360px',
        columns: [
          { id: 'record', label: 'N°', type: 'number', width: 70 },
          { id: 'user', label: 'Utilisateur', mono: true, width: 150 },
          { id: 'computer', label: 'Poste', mono: true, width: 140 },
          { id: 'category', label: 'Décision', type: 'enum', width: 130, options: CATEGORIES.map((k) => ({ value: k.id, label: k.id, tone: k.tone })) },
          { id: 'reason', label: 'Motif', width: 380 },
        ],
      });
      grid.setRows(preview.rows);
      ctl.closed.then(() => grid.destroy());
    }
    function doImport() {
      if (!preview) return;
      const id = preview.id;
      ctl.close();
      app.plan('relations.import.plan', { previewId: id }, 'Import');
    }
    paintFoot();
  });
  return ctl;
}

// ====================================================================================================== Orphelines

/** Orphan links: checked against the directory, listed with their reason, removed only once confirmed (Domenia 1 UX-40). */
export function openOrphansPanel(app) {
  const ctl = openDrawer({
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
    const paintFoot = (selected = 0) => foot.set(check && check.rows.length
      ? [{ id: 'close', label: 'Fermer', run: () => ctl.close() },
        { id: 'remove', label: `Retirer ${nouns(selected, 'association', 'associations')}`, icon: 'trash', danger: true, kind: 'write', disabled: selected === 0 || selected > 64,
          reason: selected === 0 ? 'Cochez au moins une association orpheline à retirer.' : selected > 64 ? '64 au plus par retrait.' : '', run: remove }]
      : [{ id: 'close', label: 'Fermer', run: () => ctl.close() }, { id: 'check', label: check ? 'Contrôler de nouveau' : 'Contrôler dans l’annuaire', icon: 'search', primary: true, kind: 'network', run: run }]);
    async function run() {
      out.innerHTML = `<section class="rel-step-card" aria-busy="true"><div class="rel-scan" aria-hidden="true"><span></span></div>${sk('w70')}${sk('w85')}</section>`;
      foot.set([{ id: 'check', label: 'Contrôle…', primary: true, disabled: true }]);
      try {
        check = await app.ctx.call('relations.orphans.check', {});
        out.innerHTML = `<section class="rel-step-card in"><p class="rel-status">${esc(check.summary)}</p>${check.rows.length ? '<div class="rel-orph-grid"></div>' : empty('check', 'Aucune orpheline', 'Toutes les associations vérifiées désignent un compte et un poste présents.')}</section>`;
        if (check.rows.length) {
          grid = createGrid(out.querySelector('.rel-orph-grid'), {
            key: 'relations.orphelines', label: 'Associations orphelines', rowId: (r) => r.key, selection: 'multi', height: '420px',
            columns: [
              { id: 'userLogin', label: 'Utilisateur', mono: true, width: 150 },
              { id: 'computer', label: 'Poste', mono: true, width: 140 },
              { id: 'reason', label: 'Motif', width: 320 },
              { id: 'source', label: 'Source', width: 180 },
              { id: 'when', label: 'Date', type: 'date', width: 130 },
            ],
            onSelectionChange: (rows) => paintFoot(rows.length),
          });
          grid.setRows(check.rows);
          grid.select(check.rows.filter((r) => r.selected).map((r) => r.key));
          paintFoot(check.rows.filter((r) => r.selected).length);
          ctl.closed.then(() => grid?.destroy());
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
    function remove() {
      const keys = grid ? grid.getSelectedIds() : [];
      if (!keys.length || !check) return;
      const id = check.id;
      ctl.close();
      app.plan('relations.orphans.plan', { checkId: id, keys }, 'Orphelines');
    }
    paintFoot();
  });
  return ctl;
}

// ====================================================================================================== Moisson

/** Harvest of the controller journal (Domenia 1 REL-030): impact estimated and confirmed, couples saved by a plan. */
export function openHarvestPanel(app) {
  const ctl = openDrawer({
    title: 'Moisson du journal du contrôleur', subtitle: 'Événements 4768, 4769 et 4624, aucun poste contacté', icon: 'history',
    key: 'relations.moisson', width: 760, minWidth: 520, maxWidth: 1200,
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
  whenOpen(ctl).then((opened) => {
    if (!opened) return;
    const foot = footer(ctl);
    const root = ctl.body;
    const out = root.querySelector('.rel-harvest-out');
    applyVars(out);
    let estimate = null;
    let result = null;
    let grid = null;
    const read = () => ({
      days: Math.max(1, Math.min(30, Number(root.querySelector('input[name="days"]').value) || 7)),
      maxEvents: Math.max(200, Math.min(20000, Number(root.querySelector('input[name="max"]').value) || 5000)),
    });
    root.querySelectorAll('input[type="number"]').forEach((i) => i.addEventListener('input', () => { estimate = null; result = null; out.innerHTML = upcoming(HARVEST_STEPS, 2); applyVars(out); paint(); }));
    function paint(selected = 0) {
      if (result) {
        foot.set([{ id: 'close', label: 'Fermer', run: () => ctl.close() },
          { id: 'save', label: `Enregistrer ${nouns(selected, 'couple', 'couples')}`, icon: 'check', primary: true, kind: 'write', disabled: selected === 0 || selected > 64, reason: selected > 64 ? '64 au plus par enregistrement.' : 'Cochez les couples à enregistrer.', run: save }]);
      } else if (estimate) {
        foot.set([{ id: 'close', label: 'Annuler', run: () => ctl.close() }, { id: 'run', label: 'Lancer la moisson', icon: 'play', primary: true, kind: 'network', run }]);
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
        out.querySelector('.rel-harvest-run').outerHTML = `<section class="rel-step-card in"><h3><span class="rel-step-n">3</span>Couples lus · rien d’enregistré</h3>
          <p class="rel-status">${esc(result.message)}</p><div class="rel-harvest-grid"></div></section>`;
        grid = createGrid(out.querySelector('.rel-harvest-grid'), {
          key: 'relations.moisson', label: 'Couples utilisateur-poste du journal', rowId: (r) => r.key, selection: 'multi', height: '380px',
          columns: [
            { id: 'userLogin', label: 'Utilisateur', mono: true, width: 140 },
            { id: 'computer', label: 'Poste', mono: true, width: 130 },
            { id: 'lastSeen', label: 'Dernier', type: 'date', width: 120 },
            { id: 'events', label: 'Événements', type: 'number', width: 110 },
            { id: 'eventIds', label: 'Identifiants', width: 140 },
            { id: 'known', label: 'Déjà connu', type: 'bool', width: 110 },
          ],
          onSelectionChange: (rows) => paint(rows.length),
        });
        grid.setRows(result.couples);
        const fresh = result.couples.filter((c) => !c.known).slice(0, 64).map((c) => c.key);
        grid.select(fresh);
        paint(fresh.length);
        ctl.closed.then(() => grid?.destroy());
        app.touch();
        announce(result.message);
      } catch (err) {
        out.querySelector('.rel-harvest-run').outerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}${esc(errText(err))}</p>`;
        estimate = null;
        paint();
      }
    }
    function save() {
      const keys = grid ? grid.getSelectedIds() : [];
      if (!keys.length || !result) return;
      const id = result.resultId;
      ctl.close();
      app.plan('relations.observations.plan', { resultId: id, keys }, 'Moisson du journal');
    }
    paint();
  });
  return ctl;
}

// ====================================================================================================== Relevé du parc

/** Incremental relevé of the working OU (Domenia 1 REL-031): priority queue shown, then the consoles read on a click. */
export function openSweepPanel(app) {
  const ctl = openDrawer({
    title: 'Relevé des consoles de l’OU de travail', subtitle: app.scopeLabel() ? `OU ${app.scopeLabel()}` : 'OU de travail', icon: 'monitor',
    key: 'relations.releve', width: 680, minWidth: 480, maxWidth: 1100,
    body: shell(`<div class="rel-sweep">
      <section class="rel-step-card"><h3><span class="rel-step-n">1</span>File de priorité</h3>
        <p>Les postes jamais relevés d’abord, puis les relevés les plus anciens${NBSP}; un poste qui ne s’est pas réauthentifié depuis son dernier relevé n’est pas redemandé. Jamais le domaine entier.</p>
        <div class="rel-inline"><label class="rel-num"><span>Postes au plus</span><input class="input" type="number" name="limit" min="1" max="50" value="20"></label></div></section>
      <div class="rel-sweep-out">${upcoming(SWEEP_STEPS, 2)}</div></div>`),
    actions: [],
  });
  let stop = null;
  whenOpen(ctl).then((opened) => {
    if (!opened) return;
    const foot = footer(ctl);
    const out = ctl.body.querySelector('.rel-sweep-out');
    applyVars(out);
    ctl.closed.then(() => stop?.());
    const set = (buttons) => foot.set([{ id: 'close', label: 'Fermer', run: () => ctl.close() }, ...buttons]);
    async function prepare() {
      const limit = Math.max(1, Math.min(50, Number(ctl.body.querySelector('input[name="limit"]').value) || 20));
      try {
        const plan = await app.ctx.call('relations.sweep.plan', { limit });
        out.innerHTML = `<section class="rel-step-card in rel-plan ${plan.allowed ? '' : 'refused'}"><h3><span class="rel-step-n">2</span>Postes à relever</h3>
          ${plan.allowed ? `<p>${esc(plan.text)}</p><ul class="rel-plan-targets">${plan.targets.map((t, j) => `<li data-j="${Math.min(j, 24)}" data-tip="${esc(t.source)}">${glyph('monitor')}${esc(t.computer)}</li>`).join('')}</ul>`
            : `<p class="rel-note warn">${glyph('info')}${esc(plan.reason)}</p>`}</section>`;
        applyVars(out);
        set(plan.allowed ? [{ id: 'run', label: `Lancer le relevé (${int(plan.targets.length)})`, icon: 'play', primary: true, kind: 'network', run: () => run(plan) }] : [{ id: 'prepare', label: 'Préparer la file', icon: 'refresh', run: prepare }]);
      } catch (err) {
        out.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}${esc(errText(err))}</p>`;
        set([{ id: 'prepare', label: 'Préparer la file', icon: 'refresh', primary: true, run: prepare }]);
      }
    }
    function run(plan) {
      const probeHost = document.createElement('section');
      probeHost.className = 'rel-step-card in';
      out.prepend(probeHost);
      set([{ id: 'stop', label: 'Arrêter', icon: 'pause', danger: true, run: () => { stop?.(); set([{ id: 'stopping', label: 'Arrêt demandé…', disabled: true }]); } }]);
      stop = runProbe(app, probeHost, plan.id, plan.targets.length, (res, err) => {
        stop = null;
        if (err) {
          probeHost.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}${esc(errText(err))}</p>`;
          set([{ id: 'prepare', label: 'Préparer la file', icon: 'refresh', run: prepare }]);
          return;
        }
        probeHost.innerHTML = `<h3><span class="rel-step-n">3</span>Relevé${res.counters?.stopped ? ' partiel' : ''}</h3><p class="rel-status">${esc(res.message)}</p>${refusalNote(res)}${candidatesMarkup(res.candidates, { associate: false })}${attemptsMarkup(res.attempts)}`;
        applyVars(probeHost);
        app.touch();
        set(res.savable > 0
          ? [{ id: 'save', label: `Enregistrer ${nouns(res.savable, 'console relevée', 'consoles relevées')}`, icon: 'check', primary: true, kind: 'write', run: () => { ctl.close(); app.plan('relations.observations.plan', { resultId: res.resultId, keys: [] }, 'Relevé du parc'); } }]
          : [{ id: 'prepare', label: 'Préparer une nouvelle file', icon: 'refresh', run: prepare }]);
      });
    }
    set([{ id: 'prepare', label: 'Préparer la file', icon: 'sliders', primary: true, run: prepare }]);
  });
  return ctl;
}

// ====================================================================================================== Aide

/** Precautions of the screen (Domenia 1 « ? » of Relations, REL-048). */
export function openHelpPanel() {
  const items = [
    ['shield', 'Associations locales', 'Une association est une donnée de Domenia : Active Directory n’est jamais modifié, ni par un ajout, ni par un retrait, ni par un import.'],
    ['eye', 'Observer n’est pas affecter', 'Une session observée ne devient jamais une affectation déclarée ; les deux restent visibles côte à côte. Un historique ne contredit jamais une affectation.'],
    ['alert', 'Contradictions conservées', 'Quand l’affectation déclarée et la session observée désignent des comptes différents, le poste est marqué « Contradictoire » : rien n’est fusionné ni retiré.'],
    ['key', 'Identité par GUID', 'Un lien porteur de GUID n’appartient qu’à cet objet ; un nom recyclé n’hérite jamais de l’historique d’un autre. Sans GUID, l’identité est dite non vérifiable.'],
    ['wifi', 'Aucune sonde sans geste', 'La détection lit d’abord l’annuaire, montre la liste exacte des postes, puis seulement « Lancer la détection » contacte les postes, 50 au plus, sans jamais substituer le domaine entier.'],
    ['edit', 'Chaque changement a son reçu', 'Ajouter, retirer, restaurer, importer, annuler un import, nettoyer : un plan relu, une confirmation, un reçu, une relecture. Jamais rejoué automatiquement.'],
    ['undo', 'Tout se restaure', 'Chaque retrait est journalisé et restaurable ; un import porte un lot qui s’annule même après un redémarrage.'],
  ].map(([i, t, x]) => [i, t, x.replace(/ ([:;!?])/g, `${NBSP}$1`)]);
  return openDrawer({
    title: 'Précautions des relations', subtitle: 'Ce que l’écran garantit', icon: 'info', key: 'relations.aide', width: 560,
    body: shell(`<ul class="rel-help">${items.map(([i, t, x], j) => `<li data-j="${j}"><span class="rel-help-ico">${glyph(i)}</span><div><b>${esc(t)}</b><p>${esc(x)}</p></div></li>`).join('')}</ul>`),
    actions: [{ id: 'close', label: 'Fermer', primary: true, run: (p) => p.close() }],
  });
}
