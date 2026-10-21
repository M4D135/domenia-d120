// Hidden #/ecritures screen (outside the navigation, like #/kit): reference of the write circuit (docs/WRITES.md) for the
// screens being ported and for the captures. It explains the five stages, runs the reference example (unlock an account,
// accounts.unlock.plan) through web/js/write-flow.js, and lists the receipts (write.receipts.list, get, verify).
// Parameters: ?etape=plan opens the plan of the example (a read), ?etape=confirmation opens the plan then its
// confirmation dialog; ?etape=execution, recu and recu-incertain show those states from local sample data (no call).
// None ever executes anything: a write always needs the operator's click on « Confirmer ».
import { icon } from '../icons.js';
import { esc, applyVars, reveal, errorText, formatDateTime, relTime } from '../ui.js';
import { glyph, pill, NBSP } from '../kit/index.js';
import { runWrite, openReceipt, previewWrite } from '../write-flow.js';

export const meta = { label: 'Circuit d’écriture', icon: 'shield' };
export const stylesheet = true;

/** Account of the fictitious directory locked at generation (docs/SIMULATION.md § 4.4). */
const EXAMPLE_DN = 'CN=Camille Bernard,OU=Commercial,OU=Lyon,OU=Utilisateurs,DC=example,DC=local';
const SHOWN = 8;

const STEPS = [
  { icon: 'eye', title: 'Plan', text: 'L’objet est relu, le changement décrit avant et après, les risques dits. Rien n’est écrit.' },
  { icon: 'key', title: 'Confirmation', text: `Plan figé par son empreinte, jeton à usage unique valable 5${NBSP}min, nom à saisir si nécessaire.` },
  { icon: 'file', title: 'Reçu', text: `Le reçu est enregistré sur le disque avant l’envoi${NBSP}: sans lui, rien ne part.` },
  { icon: 'zap', title: 'Envoi', text: 'Une seule fois, jamais interrompu, jamais rejoué. En simulation, l’annuaire fictif seulement.' },
  { icon: 'shield', title: 'Relecture', text: `L’objet est relu pour prouver l’effet${NBSP}: vérifiée, écart, ou à vérifier.` },
];

// Sample plan and receipts of the previews (?etape=execution|recu|recu-incertain): local data, the shapes of the contract.
function sample(state) {
  const now = Date.now();
  const iso = (t) => new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const target = { kind: 'user', kindLabel: 'Compte utilisateur', name: 'Camille Bernard', dn: EXAMPLE_DN, objectGuid: '6f1c2b7e-9a43-4d1e-8c55-2b7d90e4a1c3', samAccountName: 'c.bernard' };
  const plan = {
    id: '5b0e4c1d9a7f42e8b3c6d1a0f9e8d7c6', kind: 'account.unlock', title: 'Déverrouiller le compte', label: 'Déverrouillage du compte',
    summary: `Camille Bernard pourra de nouveau ouvrir une session${NBSP}: lockoutTime remis à zéro sur DC01.example.local.`, target,
    changes: [{ attribute: 'lockoutTime', label: 'Verrouillage', kind: 'clear', before: 'Verrouillé depuis 18:08', after: 'Déverrouillé', beforeValue: '134055412800000000', afterValue: '0' }],
    risks: [], confirmation: { typedNameRequired: false, typedName: null, reason: 'Confirmation simple.' },
    reversibility: { reversible: false, label: 'Sans retour arrière', detail: 'Un déverrouillage ne se défait pas.' },
    controller: 'DC01.example.local', operator: 'EXAMPLE\\j.martin', mode: 'simulation', simulated: true,
    createdAt: iso(now - 40_000), expiresAt: iso(now + 260_000), fingerprint: '3f2a9c41b7e05d6a8c1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c',
    details: `Opération${NBSP}: account.unlock\nEmpreinte du plan${NBSP}: 3f2a9c41b7e0 (exemple)`,
  };
  if (state === 'execution') return plan;
  const pending = state === 'recu-incertain';
  return {
    id: '9c8b7a6f5e4d43c2b1a0f9e8d7c6b5a4', kind: plan.kind, title: plan.title, label: plan.label, target,
    at: iso(now - 4000), sentAt: iso(now - 6000), completedAt: pending ? null : iso(now - 5000), verifiedAt: pending ? null : iso(now - 4000),
    operator: plan.operator, controller: plan.controller, mode: 'simulation', simulated: true,
    result: pending ? 'unknown' : 'applied', resultLabel: pending ? 'Issue inconnue, à vérifier' : 'Appliquée (simulation)',
    verification: pending ? 'unknown' : 'verified', verificationLabel: pending ? 'Non vérifiée' : 'Vérifiée par relecture',
    pending, tone: pending ? 'warn' : 'ok',
    summary: pending
      ? `Issue inconnue après l’envoi${NBSP}: vérifiez par une relecture. Rien n’est renvoyé automatiquement. Les nouvelles écritures sur cet objet restent bloquées jusqu’à la vérification.`
      : `Écriture appliquée et vérifiée par relecture. Simulation${NBSP}: annuaire fictif en mémoire, aucun effet réel.`,
    error: pending ? { code: 'write.outcomeUnknown', message: `Issue inconnue après l’envoi${NBSP}: vérifiez l’objet par une relecture avant toute nouvelle écriture. Rien n’est renvoyé automatiquement.` } : null,
    details: [
      { label: 'Préconditions', value: `Compte relu sur DC01.example.local${NBSP}: toujours verrouillé, DN et GUID inchangés.` },
      ...(pending ? [] : [
        { label: 'Envoi', value: 'lockoutTime remis à zéro dans l’annuaire fictif (en mémoire, aucun effet réel), comme le ferait DC01.example.local.' },
        { label: 'Relecture', value: `lockoutTime = 0 relu sur DC01.example.local${NBSP}: compte déverrouillé.` },
      ]),
    ],
    plan,
  };
}

function markup() {
  const steps = STEPS.map((s, n) => `<li class="wfd-step" data-i="${n}">
      <span class="wfd-step-num" aria-hidden="true">${n + 1}</span>
      <span class="wfd-step-icon">${icon(s.icon)}</span>
      <h3>${esc(s.title)}</h3><p>${esc(s.text)}</p></li>`).join('');
  return `<div class="page wfd">
    <header class="page-header reveal">
      <div class="head-row"><span class="page-icon">${icon('shield')}</span>
        <div class="titles"><h1 class="gradient-text">Circuit d’écriture</h1>
          <p class="subtitle">Plan, confirmation, reçu, relecture : la seule porte des écritures, pour tous les écrans</p></div></div>
    </header>
    <section class="card span-12 wfd-flow reveal" aria-labelledby="wfd-flow-t">
      <div class="card-head"><span class="card-icon">${icon('activity')}</span><h3 id="wfd-flow-t">Les cinq temps d’une écriture</h3>
        <span class="meta">${pill('ok', 'Lecture seule par défaut', { icon: 'lock', size: 'sm' })}${pill('info', 'Jamais rejouée', { icon: 'refresh', size: 'sm' })}</span></div>
      <ol class="wfd-steps">${steps}</ol>
    </section>
    <div class="grid">
      <section class="card span-7 wfd-try reveal" aria-labelledby="wfd-try-t">
        <div class="card-head"><span class="card-icon">${glyph('edit')}</span><h3 id="wfd-try-t">Essayer l’exemple de référence</h3>
          <span class="meta wfd-mode"></span></div>
        <p class="wfd-lead">Déverrouiller un compte : plan relu dans l’annuaire, confirmation du kit, exécution unique, reçu et relecture.
          Les écrans s’en inspirent (<span class="mono">docs/WRITES.md</span>).</p>
        <form class="wfd-form" novalidate>
          <div class="k-field">
            <label for="wfd-dn">Compte verrouillé (nom distinctif)</label>
            <input class="input mono" id="wfd-dn" name="dn" type="text" autocomplete="off" spellcheck="false" value="${esc(EXAMPLE_DN)}" aria-describedby="wfd-dn-h">
            <p class="k-hint" id="wfd-dn-h">Camille Bernard est verrouillée dans l’annuaire fictif. Un autre DN est relu de même : le plan dit s’il y a quelque chose à faire.</p>
          </div>
          <div class="wfd-actions">
            <button class="btn danger" type="submit">${glyph('edit')}Déverrouiller…</button>
            <span class="wfd-note">${glyph('info')}Un plan ne modifie rien${NBSP}; seule la confirmation envoie l’écriture.</span>
          </div>
        </form>
      </section>
      <section class="card span-5 wfd-receipts reveal" aria-labelledby="wfd-rec-t">
        <div class="card-head"><span class="card-icon">${icon('file')}</span><h3 id="wfd-rec-t">Derniers reçus</h3>
          <span class="meta"><button class="btn ghost sm" type="button" data-reload>${icon('refresh')}Actualiser</button></span></div>
        <p class="wfd-summary" aria-live="polite"></p>
        <ul class="wfd-list" aria-busy="true">${'<li class="wfd-row"><span class="skeleton wfd-sk"></span></li>'.repeat(3)}</ul>
      </section>
    </div>
    <span class="wfd-auto" hidden></span>
  </div>`;
}

function rowMarkup(r, n) {
  const at = formatDateTime(r.at) ?? '';
  return `<li class="wfd-row" data-i="${n}">
    <button class="wfd-row-btn" type="button" data-id="${esc(r.id)}" data-tone="${esc(r.tone)}">
      <span class="wfd-row-dot" aria-hidden="true"></span>
      <span class="wfd-row-main"><b>${esc(r.label)}</b><span>${esc(r.target.name)}</span></span>
      <span class="wfd-row-pills">${pill(r.tone, r.verificationLabel, { size: 'sm' })}${r.simulated ? pill('accent', 'Simulé', { size: 'sm' }) : ''}</span>
      <time datetime="${esc(r.at)}" data-tip="${esc(at)}">${esc(relTime(r.at) ?? at)}</time>
    </button></li>`;
}

export function render(main, ctx) {
  let alive = true;
  main.innerHTML = markup();
  applyVars(main);
  const stopReveal = reveal(main);
  const form = main.querySelector('.wfd-form');
  const input = /** @type {HTMLInputElement} */ (main.querySelector('#wfd-dn'));
  const list = main.querySelector('.wfd-list');
  const summary = main.querySelector('.wfd-summary');

  ctx.app?.then((info) => {
    if (!alive) return;
    const host = main.querySelector('.wfd-mode');
    if (info?.mode === 'annuaire') {
      host.innerHTML = pill('warn', 'Mode annuaire', { icon: 'zap', size: 'sm', tip: `Les écritures réelles arrivent avec la lecture de l’annuaire (vague 3)${NBSP}: le plan répondra «${NBSP}source indisponible${NBSP}».` });
    } else {
      host.innerHTML = pill('accent', 'Simulation · aucun effet réel', { icon: 'sparkles', size: 'sm' });
    }
  });

  const loadReceipts = () => {
    list.setAttribute('aria-busy', 'true');
    return ctx.call('write.receipts.list').then((data) => {
      if (!alive) return;
      summary.textContent = data.summary;
      const rows = data.receipts.slice(0, SHOWN);
      list.innerHTML = rows.length
        ? rows.map(rowMarkup).join('')
        : `<li class="wfd-empty">${icon('file')}<span>Aucun reçu pour l’instant${NBSP}: lancez l’essai ci-contre.</span></li>`;
      applyVars(list);
    }).catch((err) => {
      console.error(err);
      if (!alive) return;
      summary.textContent = '';
      list.innerHTML = `<li class="wfd-empty alert">${icon('alert')}<span>${esc(errorText(err, 'Reçus illisibles.'))}</span></li>`;
    }).finally(() => {
      if (alive) list.removeAttribute('aria-busy');
    });
  };

  const start = () => {
    const dn = input.value.trim();
    if (!dn) {
      input.focus();
      return Promise.resolve(null);
    }
    return runWrite(ctx, { plan: 'accounts.unlock.plan', args: { dn }, subtitle: 'Déverrouillage du compte', onDone: () => { if (alive) loadReceipts(); } });
  };

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    start();
  });
  main.querySelector('[data-reload]').addEventListener('click', () => loadReceipts());
  list.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('.wfd-row-btn') : null;
    if (b) openReceipt(ctx, b.dataset.id, { onChange: () => { if (alive) loadReceipts(); } });
  });

  loadReceipts();

  // Captures (docs/CAPTURE.md): open the plan, or the plan and its confirmation, then signal readiness. Reads only.
  let watch = null;
  const step = ctx.params?.etape;
  if (step === 'execution' || step === 'recu' || step === 'recu-incertain') {
    const marker = main.querySelector('.wfd-auto');
    marker.setAttribute('aria-busy', 'true');
    const began = performance.now();
    watch = setInterval(() => {
      if (!alive) { clearInterval(watch); return; }
      if (document.querySelector('.k-drw-layer, .k-dlg-layer') && performance.now() - began < 3000) return;
      clearInterval(watch);
      previewWrite(step === 'execution' ? 'run' : 'receipt', sample(step));
      setTimeout(() => marker.removeAttribute('aria-busy'), 900);
    }, 120);
  } else if (step === 'plan' || step === 'confirmation') {
    const marker = main.querySelector('.wfd-auto');
    marker.setAttribute('aria-busy', 'true');
    // A panel of the previous screen may still be closing: a request made now would wait behind it and be withdrawn
    // with it (docs/KIT.md § 4.3), so the example starts once no panel nor dialog is left.
    let started = false;
    const began = performance.now();
    watch = setInterval(() => {
      if (!alive) { clearInterval(watch); return; }
      if (!started) {
        if (document.querySelector('.k-drw-layer, .k-dlg-layer') && performance.now() - began < 3000) return;
        started = true;
        start();
        return;
      }
      const confirm = document.querySelector('.wf-foot [data-wf="confirm"]');
      const ready = step === 'plan' ? document.querySelector('.wf-plan') : document.querySelector('.k-dlg .k-cw-target');
      if (step === 'confirmation' && confirm && !document.querySelector('.k-dlg')) confirm.click();
      if (ready || document.querySelector('.wf-fail') || performance.now() - began > 15_000) {
        clearInterval(watch);
        marker.removeAttribute('aria-busy');
      }
    }, 150);
  }

  return () => {
    alive = false;
    clearInterval(watch);
    stopReveal();
  };
}
