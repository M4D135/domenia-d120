// Write circuit and dialogs in front of notifications (recette 2.0.5, simulation): after a confirmed write, Échap still
// closes the receipt panel (the footer that held the focus is replaced); a notification that stays (warning, alert)
// does not cover the footer buttons of a centred dialog and stays readable in front of its veil.
import { test, eq, ok, Failure } from './harness.mjs';
import { runWrite, outcome } from '../../web/js/write-flow.js';
import { openDialog, openDrawer } from '../../web/js/kit/index.js';

const NBSP = ' ';
const pause = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

/** Polls until check() returns something truthy (no fixed sleep: the flow resolves through promises and timers). */
async function until(check, what, ms = 4000) {
  const end = performance.now() + ms;
  for (;;) {
    const value = check();
    if (value) return value;
    if (performance.now() > end) throw new Failure(`${what} : délai dépassé`);
    await pause(20);
  }
}

/** Finishes the entrance animations (infinite ones cannot be finished and are left running). */
function settleAnimations() {
  for (const animation of document.getAnimations()) {
    try { animation.finish(); } catch { /* infinite animation: nothing to finish */ }
  }
}

function setMotion(value) {
  if (value === undefined) delete document.documentElement.dataset.motion;
  else document.documentElement.dataset.motion = value;
}

test('Stockage : annuler la confirmation du déplacement ne lance aucune copie', async () => {
  const motion = document.documentElement.dataset.motion;
  let drawer = null;
  const calls = [];
  try {
    setMotion('reduced');
    const now = Date.now();
    const plan = {
      id: 'storage-move-cancel', kind: 'storage.move', title: 'Déplacer la base', summary: 'Copier la base locale puis vérifier la copie.', simulated: false,
      target: { kind: 'localStore', kindLabel: 'Base locale', name: 'Domenia.db', dn: 'C:\\Domenia\\Domenia.db' },
      changes: [{ label: 'Emplacement', attribute: 'store.path', before: 'C:\\Domenia\\Domenia.db', after: 'C:\\Copies\\Domenia.db' }], risks: [],
      confirmation: { typedNameRequired: false, reason: 'Aucun original remplacé.' },
      reversibility: { reversible: true, label: 'Retour possible', detail: 'Ancienne base conservée.' },
      controller: 'local', operator: 'TEST\\operator', details: 'Contrôle de la copie avant sélection.',
      createdAt: new Date(now).toISOString(), expiresAt: new Date(now + 300000).toISOString(),
    };
    const done = runWrite({ call(op) {
      calls.push(op);
      if (op === 'settings.storage.move.plan') return Promise.resolve({ plan, token: 'cancel-only' });
      return Promise.reject(new Error(`Aucune écriture attendue : ${op}`));
    } }, { plan: 'settings.storage.move.plan', args: { destination: 'C:\\Copies\\Domenia.db' } });
    const start = await until(() => document.querySelector('.k-drw-layer .k-drw-foot [data-wf="confirm"]'), 'plan prêt');
    drawer = start.closest('.k-drw'); start.click();
    const confirm = await until(() => document.querySelector('.k-dlg-layer:not(.leaving) .k-dlg-foot [data-id="confirm"]'), 'confirmation locale');
    eq(confirm.textContent.trim(), 'Copier, vérifier puis utiliser la nouvelle base', 'action précise avant envoi');
    const dialog = confirm.closest('.k-dlg-layer');
    ok(dialog.textContent.includes('Écriture dans la base locale'), 'aucune écriture AD annoncée');
    dialog.querySelector('[data-id="cancel"]').click();
    await until(() => !document.querySelector('.k-dlg-layer:not(.leaving)'), 'confirmation annulée');
    drawer.querySelector('.k-drw-foot [data-wf="cancel"]').click();
    eq(await done, null, 'aucun reçu de copie fabriqué');
    eq(calls, ['settings.storage.move.plan'], 'lecture de préparation seule, aucune suspension ou écriture');
  } finally {
    document.querySelectorAll('.k-dlg-layer .k-dlg-x').forEach((x) => x.click());
    drawer?.querySelector('.k-drw-x')?.click();
    await pause(0); setMotion(motion);
  }
});

test('Écriture : Échap ferme le panneau du reçu après une écriture confirmée', async () => {
  const motion = document.documentElement.dataset.motion;
  let drawer = null;
  try {
    // Reduced motion: the receipt replaces the steps at once and the layers leave without waiting for an animation.
    setMotion('reduced');
    const now = Date.now();
    const target = { kind: 'user', kindLabel: 'Utilisateur', name: 'cam.martin', dn: 'CN=cam.martin,OU=Lyon,DC=example,DC=local' };
    const plan = {
      id: 'plan-test-focus', title: 'Modifier la description', summary: 'La description de cam.martin change.', simulated: true, target,
      changes: [{ label: 'Description', attribute: 'description', before: 'Ancienne', after: 'Nouvelle' }], risks: [],
      confirmation: { typedNameRequired: false, reason: 'Écriture simple dans l’annuaire fictif.' },
      reversibility: { reversible: true, label: 'Réversible', detail: 'La valeur précédente est gardée dans le reçu.' },
      controller: 'DC01', operator: 'EXAMPLE\\admin', details: 'description : Ancienne -> Nouvelle',
      createdAt: new Date(now).toISOString(), expiresAt: new Date(now + 300_000).toISOString(),
    };
    const receipt = {
      id: 'recu-test-focus', title: plan.title, label: 'Modifier la description', target, tone: 'ok', verification: 'verified',
      verificationLabel: 'Vérifiée par relecture', resultLabel: 'Appliquée (simulation)', summary: 'La description a été écrite puis relue.',
      simulated: true, pending: false, details: [], controller: 'DC01', operator: 'EXAMPLE\\admin',
      sentAt: new Date(now).toISOString(), verifiedAt: new Date(now).toISOString(), plan: { fingerprint: 'abcdef0123456789', details: plan.details },
    };
    const calls = [];
    const ctx = {
      call(op) {
        calls.push(op);
        if (op === 'test.focus.plan') return Promise.resolve({ plan, token: 'jeton-test' });
        if (op === 'write.execute') return Promise.resolve(receipt);
        return Promise.reject(Object.assign(new Error(`Opération inattendue : ${op}`), { code: 'operation.unknown' }));
      },
    };
    let closed = 0;
    const done = runWrite(ctx, { plan: 'test.focus.plan', args: {}, onClosed: () => { closed += 1; } });
    const confirm = await until(() => document.querySelector('.k-drw-layer .k-drw-foot [data-wf="confirm"]'), 'plan affiché');
    drawer = confirm.closest('.k-drw');
    // The operator's click gives the focus to « Confirmer… »; the confirmation gives it back there when it closes.
    confirm.focus();
    ok(document.activeElement === confirm, 'le bouton « Confirmer… » a le focus avant la confirmation');
    confirm.click();
    const yes = await until(() => document.querySelector('.k-dlg-layer:not(.leaving) .k-dlg-foot [data-id="confirm"]'), 'confirmation ouverte');
    ok(!yes.disabled, 'confirmation simple : le bouton est actif');
    yes.click();
    const result = await done;
    eq(result?.id, 'recu-test-focus', 'le circuit rend le reçu');
    await until(() => drawer.querySelector('.wf-receipt'), 'reçu affiché dans le panneau');
    eq(calls, ['test.focus.plan', 'write.execute'], 'un plan, une seule écriture envoyée');
    ok(drawer.contains(document.activeElement),
      `le focus reste dans le panneau du reçu (actuel : ${document.activeElement?.tagName}.${document.activeElement?.className || ''})`);
    // A real keyboard sends Échap to the focused element.
    document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
    eq(closed, 1, 'Échap ferme le panneau du reçu');
    await until(() => !drawer.isConnected, 'panneau retiré de la page');
    eq(calls.length, 2, 'la fermeture n’envoie rien de plus');
  } finally {
    // A failed run must not leave a modal surface behind (the next tests would find the page inert).
    document.querySelectorAll('.k-dlg-layer .k-dlg-x').forEach((x) => x.click());
    if (drawer?.isConnected) drawer.querySelector('.k-drw-x')?.click();
    await pause(0);
    setMotion(motion);
  }
});

test('Notifications : une alerte qui reste ne couvre pas les boutons d’un dialogue centré, quelle que soit sa hauteur', async () => {
  const motion = document.documentElement.dataset.motion;
  const styles = [];
  let region = null;
  let dialog = null;
  const frame = () => new Promise((resolve) => { requestAnimationFrame(() => requestAnimationFrame(resolve)); });
  try {
    for (const file of ['components.css', 'kit.css']) {
      const css = document.createElement('link'); css.rel = 'stylesheet';
      css.href = new URL(`../../web/css/${file}`, import.meta.url).href;
      styles.push(css);
      await new Promise((resolve, reject) => { css.onload = resolve; css.onerror = () => reject(new Error(`CSS absent : ${file}`)); document.head.append(css); });
    }
    setMotion('reduced');
    // Same markup as a sticky banner of shell/notify.js (warning: it never closes by itself).
    region = document.createElement('div');
    region.className = 'toasts';
    region.setAttribute('role', 'region');
    region.setAttribute('aria-label', 'Notifications');
    region.innerHTML = `<div class="toast sh-note sticky" data-tone="warn" role="group" aria-label="Attention : Intégrité de la base${NBSP}: Défaut.">
      <span class="toast-icon"></span>
      <div class="toast-body"><div class="sh-note-head"><span class="sh-note-kind">Attention</span></div>
        <p class="sh-note-text">Intégrité de la base${NBSP}: Défaut.</p><div class="sh-note-actions"></div></div>
      <button class="btn ghost icon sm toast-close" type="button" aria-label="Fermer le message">×</button></div>`;
    document.body.append(region);
    const note = region.querySelector('.toast');
    ok(document.querySelector('.toasts') === region, 'une seule pile de notifications dans la page (celle que le dialogue mesure)');
    const stackHeight = region.offsetHeight;
    ok(stackHeight > 0, 'la pile de notifications a une hauteur');
    const cases = [
      // A large dialog at its full height: its footer sits low, where the notification column is.
      { name: 'haut', body: Array.from({ length: 40 }, (_, n) => `<p class="k-dlg-text">Sauvegarde vérifiée n° ${n + 1}</p>`).join('') },
      // A short dialog with too little room under it for the stack (recette 2.0.6: « Restaurer une sauvegarde », list
      // capped at 360 px): the stack rises above its footer.
      // (At least what a dialog at its 88vh cap leaves under it, so the margin is reachable in any window.)
      { name: 'court, place insuffisante dessous', below: Math.max(Math.round(stackHeight / 2), Math.ceil(innerHeight * 0.06) + 4) },
      // A short dialog with room under it: the stack stays at its place, entirely under the dialog.
      { name: 'court, place suffisante dessous', below: stackHeight + 60, under: true },
    ];
    for (const c of cases) {
      dialog = openDialog({
        title: 'Restaurer une sauvegarde', size: 'lg', body: c.body ?? '<div data-fill style="height:0"></div>',
        actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'restore', label: 'Préparer la restauration', primary: true }],
      });
      settleAnimations();
      if (c.below !== undefined) {
        // Centred dialog: its height sets the room left under it.
        const fill = dialog.body.querySelector('[data-fill]');
        fill.style.height = `${Math.max(0, innerHeight - 2 * c.below - dialog.el.offsetHeight)}px`;
        await frame();
        const room = innerHeight - dialog.el.getBoundingClientRect().bottom;
        ok(Math.abs(room - c.below) <= 2, `${c.name} : ${Math.round(room)} px sous le dialogue (attendu ${c.below}, fenêtre ${innerWidth}×${innerHeight})`);
        ok(c.under ? room >= stackHeight + 32 : room < stackHeight + 32, `${c.name} : la place sous le dialogue correspond au cas (${Math.round(room)} px pour une pile de ${stackHeight} px)`);
      }
      await frame();
      const noteBox = note.getBoundingClientRect();
      ok(noteBox.width > 0 && noteBox.height > 0, `${c.name} : la notification reste affichée pendant le dialogue`);
      const box = dialog.el.getBoundingClientRect();
      const foot = dialog.el.querySelector('.k-dlg-foot').getBoundingClientRect();
      if (c.under) {
        ok(noteBox.top >= box.bottom - 1, `${c.name} : la notification reste sous le dialogue (notification dès ${Math.round(noteBox.top)}, dialogue jusqu’à ${Math.round(box.bottom)})`);
      } else {
        // Whatever the window width: the stack ends above the footer, so no footer button can be under it.
        ok(noteBox.bottom <= foot.top + 1,
          `${c.name} : la notification finit au-dessus du pied du dialogue (notification ${Math.round(noteBox.top)}–${Math.round(noteBox.bottom)}, pied dès ${Math.round(foot.top)})`);
      }
      for (const button of dialog.el.querySelectorAll('.k-dlg-foot button')) {
        const r = button.getBoundingClientRect();
        for (const x of [r.left + 4, r.left + r.width / 2, r.right - 4]) {
          const y = r.top + r.height / 2;
          const hit = document.elementFromPoint(x, y);
          ok(button.contains(hit),
            `${c.name} : « ${button.textContent.trim()} » reçoit le clic en ${Math.round(x)},${Math.round(y)} (reçu : ${hit?.tagName || 'aucun'}.${hit?.className || ''})`);
        }
      }
      // The alert stays in front of the veil: it can still be read and closed.
      const close = note.querySelector('.toast-close').getBoundingClientRect();
      const onClose = document.elementFromPoint(close.left + close.width / 2, close.top + close.height / 2);
      ok(note.contains(onClose), `${c.name} : la notification reste devant le voile (reçu : ${onClose?.tagName || 'aucun'}.${onClose?.className || ''})`);
      dialog.close(null);
      eq(await dialog.result, null, `${c.name} : le dialogue se ferme sans réponse`);
      dialog = null;
      eq(document.documentElement.style.getPropertyValue('--k-dlg-toasts-bottom'), '', `${c.name} : la mesure est retirée à la fermeture`);
      await pause(0);
    }
  } finally {
    dialog?.close(null);
    await pause(0);
    region?.remove();
    styles.forEach((css) => css.remove());
    setMotion(motion);
  }
});

test('Panneau modal : Échap le ferme encore quand son bouton focalisé disparaît', async () => {
  const motion = document.documentElement.dataset.motion;
  let drawer = null;
  try {
    setMotion('reduced');
    let closed = 0;
    drawer = openDrawer({ title: 'Compte poste', body: '<button type="button" class="btn" data-test-back>Revenir au compte de connexion</button>', onClose: () => { closed += 1; } });
    const back = drawer.body.querySelector('[data-test-back]');
    back.focus();
    ok(document.activeElement === back, 'le bouton du panneau a le focus');
    // The screen replaces its content after the click: the focused button leaves the page and the focus falls to <body>.
    back.remove();
    ok(document.activeElement === document.body || document.activeElement === null, 'le focus est tombé sur la page');
    document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
    eq(closed, 1, 'Échap ferme le panneau du dessus');
    await until(() => !drawer.el.isConnected, 'panneau retiré de la page');
    // Once closed, a later Échap on the page acts on nothing (the listener is gone).
    document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
    eq(closed, 1, 'aucune fermeture en double');
    drawer = null;
  } finally {
    drawer?.close();
    await pause(0);
    setMotion(motion);
  }
});


test('Reçu repris : une relecture concluante clôt Sent sans renvoyer la commande', () => {
  eq(outcome({ result: 'sent', verification: 'verified', pending: false }), 'relecture conforme', 'preuve froide reconnue');
  eq(outcome({ result: 'sent', verification: 'unknown', pending: true }), 'issue à vérifier', 'envoi non confirmé');
  eq(outcome({ result: 'applied', verification: 'unknown', pending: true }), 'issue à vérifier', 'acquittement sans relecture');
  eq(outcome({ result: 'delivered', verification: 'unknown', pending: false }), 'demande livrée, effet non vérifié', 'livraison distincte');
});
