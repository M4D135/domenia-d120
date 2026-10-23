// Explicit compensation and account sequences. Each sensitive step opens the ordinary write circuit; never a batch execution.
import { glyph, pill, confirmDialog } from '../../kit/index.js';
import { esc, errorText, toast } from '../../ui.js';
import { write, pickObject, pickOu } from './actions.js';

export function mountWorkflows(host, S) {
  let state = null;
  let busy = false;
  let manager = null;
  let destination = null;
  const groups = [];
  host.innerHTML = `<section class="card fi-card fi-workflow">
    ${S.params.compenser ? `<div class="fi-workflow-comp"><h3>${glyph('undo')}Compensation demandée</h3><p>Le reçu sera relu ; l’inverse n’est préparé que si le même objet porte encore les valeurs écrites. Chaque changement demande une nouvelle confirmation.</p><button class="btn" type="button" data-compensate>Relire et préparer l’inverse…</button></div>` : ''}
    ${S.sheet.identity.kind === 'user' ? `<details><summary>Préparer une séquence de cycle de vie</summary>
      <p>Une étape à la fois, avec son plan et son reçu. Une lecture incertaine bloque la suite. Aucun changement ne part à la préparation.</p>
      <form data-sequence class="fi-workflow-form">
        <label>Parcours<select class="input" name="kind"><option value="arrival">Arrivée</option><option value="serviceChange">Changement de service</option><option value="suspension">Suspension</option></select></label>
        <label>Service (facultatif)<input class="input" name="department" maxlength="256"></label>
        <label>Fonction (facultative)<input class="input" name="title" maxlength="256"></label>
        <label>Bureau (facultatif)<input class="input" name="physicalDeliveryOfficeName" maxlength="256"></label>
        <label>Description / motif de suspension<input class="input" name="description" maxlength="1024"></label>
        <p>Un champ laissé vide reste inchangé. Pour une suspension, saisissez le motif ; seuls ce motif, la désactivation et le déplacement éventuel seront préparés.</p>
        <div class="fi-workflow-actions"><button class="btn sm" type="button" data-manager>Choisir un responsable…</button><button class="btn sm" type="button" data-destination>Choisir une destination…</button><button class="btn sm ghost" type="button" data-clear-choices>Retirer les choix</button></div>
        <p data-choices>Aucun responsable ni déplacement demandé.</p>
        <div class="fi-workflow-actions"><button class="btn sm" type="button" data-group="add">Ajouter à un groupe…</button><button class="btn sm" type="button" data-group="remove">Retirer d’un groupe…</button></div><div data-groups></div>
        <button class="btn primary" type="submit">Préparer les étapes…</button>
      </form><div data-progress aria-live="polite"></div></details>` : ''}
    <p data-workflow-error role="status"></p></section>`;
  if (['arrival', 'serviceChange', 'suspension'].includes(S.params.parcours)) {
    const select = host.querySelector('[name="kind"]');
    if (select) { select.value = S.params.parcours; host.querySelector('details').open = true; }
  }
  const error = host.querySelector('[data-workflow-error]');
  const form = host.querySelector('form');
  const fail = (err) => { error.textContent = errorText(err); };
  async function guarded(fn) {
    if (busy || !S.alive) return;
    busy = true; error.textContent = ''; host.setAttribute('aria-busy', 'true');
    host.querySelectorAll('button, input, select').forEach((el) => { el.disabled = true; });
    try { await fn(); } catch (err) { if (S.alive) fail(err); }
    finally {
      busy = false;
      if (S.alive) { host.removeAttribute('aria-busy'); host.querySelectorAll('button, input, select').forEach((el) => { el.disabled = false; }); }
    }
  }
  host.querySelector('[data-compensate]')?.addEventListener('click', () => guarded(async () => {
    let closed = false;
    let target = null;
    const afterClose = () => { if (closed && target && S.alive) S.ctx.navigate('fiche', { dn: target.dn, guid: target.guid }); };
    const receipt = await write(S.ctx, 'fiche.compensation.plan', { id: S.params.compenser, dn: S.sheet.identity.dn },
      { subtitle: 'Compensation · nouvelle écriture', onClosed: () => { closed = true; afterClose(); } });
    if (receipt?.verification === 'verified' && S.alive) {
      target = await S.ctx.call('fiche.compensation.context', { id: receipt.id });
      host.querySelector('.fi-workflow-comp')?.remove(); afterClose();
    }
  }));
  const choices = () => {
    host.querySelector('[data-choices]').textContent = `${manager ? `Responsable : ${manager.name}` : 'Responsable inchangé'} · ${destination ? `Destination : ${destination.name}` : 'Aucun déplacement'}`;
    host.querySelector('[data-groups]').innerHTML = groups.map((g, i) => `<button type="button" class="btn sm ghost" data-drop="${i}">${glyph('x')}${esc(g.kind === 'add' ? 'Ajout' : 'Retrait')} · ${esc(g.name)}</button>`).join('');
  };
  host.querySelector('[data-manager]')?.addEventListener('click', () => guarded(async () => {
    const picked = await pickObject(S.ctx, { title: 'Responsable du compte', kinds: ['user'] });
    if (picked && S.alive) { manager = picked; choices(); }
  }));
  host.querySelector('[data-destination]')?.addEventListener('click', () => guarded(async () => {
    const picked = await pickOu(S.ctx, { title: 'Destination du compte', current: S.sheet.identity.dn });
    if (picked && S.alive) { destination = picked; choices(); }
  }));
  host.querySelector('[data-clear-choices]')?.addEventListener('click', () => { manager = null; destination = null; groups.length = 0; choices(); });
  host.querySelectorAll('[data-group]').forEach((button) => button.addEventListener('click', () => guarded(async () => {
    if (groups.length >= 20) throw new Error('Vingt groupes au plus dans une séquence.');
    const picked = await pickObject(S.ctx, { title: button.dataset.group === 'add' ? 'Ajouter à un groupe' : 'Retirer d’un groupe', kinds: ['group'], exclude: groups.map((g) => g.dn) });
    if (picked && S.alive && !groups.some((g) => g.dn.toLowerCase() === picked.dn.toLowerCase())) { groups.push({ ...picked, kind: button.dataset.group }); choices(); }
  })));
  host.querySelector('[data-groups]')?.addEventListener('click', (event) => {
    const button = event.target.closest('[data-drop]'); if (!button || busy) return;
    groups.splice(Number(button.dataset.drop), 1); choices();
  });
  form?.addEventListener('submit', (event) => {
    event.preventDefault();
    // Capture before disabling the form: disabled controls are absent from FormData.
    const values = new FormData(form); const kind = String(values.get('kind'));
    const fields = Object.fromEntries(['department', 'title', 'physicalDeliveryOfficeName', 'description'].filter((key) => String(values.get(key) ?? '').trim()).map((key) => [key, String(values.get(key)).trim()]));
    if (manager) fields.manager = manager.dn;
    if (kind === 'suspension') {
      for (const key of Object.keys(fields)) if (key !== 'description') delete fields[key];
      if (!fields.description) { fail(new Error('Un motif de suspension est requis.')); return; }
    }
    guarded(async () => {
      state = await S.ctx.call('fiche.lifecycle.create', { kind, dn: S.sheet.identity.dn, guid: S.sheet.identity.guid, fields,
        add: kind === 'suspension' ? [] : groups.filter((g) => g.kind === 'add').map((g) => g.dn),
        remove: kind === 'suspension' ? [] : groups.filter((g) => g.kind === 'remove').map((g) => g.dn), target: destination?.dn ?? null });
      if (S.alive) {
        form.hidden = true;
        const address = new URLSearchParams(location.hash.split('?')[1] ?? ''); address.set('sequence', state.id);
        history.replaceState(null, '', `#/fiche?${address}`);
        paint();
      }
    });
  });
  function paint() {
    if (!S.alive || !state) return;
    const next = state.plan.steps.find((s) => s.state === 'pending');
    const status = { pending: 'À préparer', verified: 'Vérifiée', uncertain: 'À vérifier', failed: 'En échec', skipped: 'Sans changement' };
    host.querySelector('[data-progress]').innerHTML = `<h3>${esc(state.plan.title)} · ${esc(state.name)}</h3><p>Séquence de cette session. Les reçus demeurent conservés après fermeture.</p><ol>${state.plan.steps.map((s) => `<li>${esc(s.title)} ${pill(s.state === 'verified' ? 'ok' : s.state === 'pending' ? 'off' : 'warn', status[s.state] ?? s.state, { size: 'sm' })}${s.note ? `<p>${esc(s.note)}</p>` : ''}</li>`).join('')}</ol>
      ${state.plan.blocked ? `<p>${esc(state.plan.blockReason)}</p>${state.receiptId ? '<button type="button" class="btn" data-receipt>Ouvrir le reçu à vérifier</button><button type="button" class="btn" data-check-receipt>Relire son état après vérification</button>' : ''}`
        : next ? `<button type="button" class="btn primary" data-next>${next.writeKind === 'review' ? 'Relire et confirmer la vérification de la fiche' : 'Préparer cette étape…'}</button>` : '<p>Toutes les étapes sont vérifiées. Rien d’autre ne sera lancé.</p>'}<button type="button" class="btn ghost" data-close-sequence>Fermer cette séquence</button>`;
    host.querySelector('[data-close-sequence]')?.addEventListener('click', () => guarded(async () => {
      if (!await confirmDialog({ title: 'Fermer la séquence ?', message: 'Les étapes restantes ne seront pas lancées. Les reçus existants restent consultables dans Opérations.', confirmLabel: 'Fermer la séquence', icon: 'layers' })) return;
      await S.ctx.call('fiche.lifecycle.close', { id: state.id }); state = null;
      host.querySelector('[data-progress]').innerHTML = ''; form.hidden = false;
      const address = new URLSearchParams(location.hash.split('?')[1] ?? ''); address.delete('sequence');
      history.replaceState(null, '', `#/fiche?${address}`);
    }));
    host.querySelector('[data-receipt]')?.addEventListener('click', () => S.ctx.navigate('operations', { recu: state.receiptId }));
    host.querySelector('[data-check-receipt]')?.addEventListener('click', () => guarded(async () => { state = await S.ctx.call('fiche.lifecycle.record', { id: state.id, receipt: state.receiptId }); paint(); }));
    host.querySelector('[data-next]')?.addEventListener('click', () => guarded(async () => {
      const review = next.writeKind === 'review';
      if (review && !await confirmDialog({ title: 'Fiche vérifiée ?', message: 'Confirmez avoir contrôlé le service, le responsable et le bureau de ce compte. La fiche sera relue ; aucune écriture ne part.', confirmLabel: 'Relire et confirmer', icon: 'eye' })) return;
      const prepared = await S.ctx.call('fiche.lifecycle.prepare', { id: state.id, review });
      state = prepared.workflow;
      if (prepared.write) {
        let closed = false;
        const followMove = () => { if (closed && S.alive && state.dn.toLowerCase() !== S.sheet.identity.dn.toLowerCase()) S.ctx.navigate('fiche', { dn: state.dn, guid: S.sheet.identity.guid, sequence: state.id }); };
        const receipt = await write(S.ctx, 'fiche.lifecycle.plan', { id: state.id },
          { subtitle: `${state.plan.title} · une étape`, onClosed: () => { closed = true; followMove(); } });
        if (receipt) { state = await S.ctx.call('fiche.lifecycle.record', { id: state.id, receipt: receipt.id }); followMove(); }
      } else toast('Étape relue, aucune écriture envoyée.', { tone: 'info' });
      paint();
    }));
  }
  if (S.params.sequence && form) {
    guarded(async () => {
      const kept = await S.ctx.call('fiche.lifecycle.get', { id: S.params.sequence });
      if (!S.alive) return;
      if (kept.dn.toLowerCase() !== S.sheet.identity.dn.toLowerCase()) throw new Error('La séquence porte sur une autre fiche ; ouvrez sa cible actuelle.');
      state = kept; form.hidden = true; host.querySelector('details').open = true; paint();
    });
  }

}
