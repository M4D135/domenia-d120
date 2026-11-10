import { esc, glyph, card, facts, notes, sectionHead, paint, errorBlock, size, when, reported } from './common.js';
import { confirmDialog } from '../../kit/dialog.js';
import { reveal } from '../../ui.js';

const HEAD = { title: 'Mises à jour', lead: 'Choisissez une source, contrôlez le pack, puis confirmez son installation. Aucune recherche ni installation automatique.', icon: 'download', tone: 'accent' };

export function mount(host, sctx) {
  let alive = true, busy = false, view = null, failure = null;
  let stopReveal = () => {};
  function paintContent() { paint(host); stopReveal = reveal(host); }
  const button = (action, text, disabled = false, primary = false) => `<button type="button" class="btn sm ${primary ? 'primary' : 'subtle'}" data-update="${action}"${busy || disabled || view?.busy ? ' disabled' : ''}>${text}</button>`;
  function draw(error = failure) {
    if (!alive) return;
    stopReveal();
    if (!view) { host.innerHTML = `${sectionHead(HEAD)}${error ? errorBlock(error) : '<p role="status">Lecture de l’état local…</p>'}`; paintContent(); return; }
    const candidate = view.candidate;
    host.innerHTML = `${sectionHead(HEAD)}${error ? errorBlock(error) : ''}
      ${view.demonstration ? `<p class="pr-hint" role="status">${glyph('info')}<span><strong>Démonstration — données fictives.</strong> Les sources, la copie, l’installation et le retour arrière sont simulés dans cet espace.</span></p>` : ''}
      <div class="pr-grid">${card({ id: 'source', title: 'Source et version', iconName: 'download', body:
        `${facts([['Version installée', view.installedVersion], ['Dossier de diffusion', view.folder || 'Non configuré']])}
        <div class="pr-actions">${button('folder-pick', 'Choisir le dossier', !view.available)}${button('folder', 'Rechercher dans le dossier', !view.available || !view.folder)}${button('local', 'Sélectionner un ZIP PROD', !view.available)}</div>
        <p class="pr-hint">${glyph('info')}<span>Un dossier de diffusion contient le ZIP PROD et SHA256SUMS.txt. L’accès utilise la session Windows et reste en lecture seule.</span></p>` })}
      ${card({ id: 'candidate', title: 'Pack proposé', iconName: 'shield', body: candidate
        ? `${facts([['Version', candidate.version], ['Source', candidate.provenance], ['Archive', candidate.fileName], ['Taille', size(candidate.bytes)], ['SHA-256 publié', candidate.sha256]])}
          <div class="pr-actions">${button('prepare', view.demonstration ? 'Simuler la préparation' : 'Copier et vérifier', !view.available, !view.prepared)}</div>`
        : '<p>Aucune version sélectionnée. Une recherche n’installe rien et ne change jamais de source automatiquement.</p>' })}
      ${card({ id: 'installation', title: 'Vérification et installation', iconName: 'check', body:
        `<p role="status" data-update-message>${esc(view.message)}</p>${busy ? '<p role="status">Opération demandée en cours…</p>' : ''}
        ${view.prepared ? `<p>Confirmation valable jusqu’au ${esc(when(view.expiresAt))}.</p><div class="pr-actions">${button('install', view.demonstration ? 'Confirmer la mise à jour fictive' : 'Fermer et installer', !view.available, true)}</div>` : ''}
        ${view.preparationFolder ? `<p>Copie locale conservée : <span class="mono">${esc(view.preparationFolder)}</span></p>` : ''}
        ${view.demonstration ? `<div class="pr-actions">${button('rollback', 'Simuler le retour arrière')}</div>` : '<p>Après une interruption, utilisez le bilan et l’assistant de reprise avec la transaction conservée. Le retour arrière des binaires ne restaure aucune base.</p>'}
        ${notes(view.advice)}` })}</div>`;
    paintContent();
  }
  async function load() {
    try { const value = await sctx.call('settings.update.status'); if (alive) { view = value; draw(); } }
    catch (err) { if (alive) draw(err); }
  }
  async function act(action) {
    if (!alive || busy || view?.busy) return;
    busy = true; failure = null; draw();
    try {
      if (action === 'install') {
        const captured = view?.confirmation;
        const yes = await confirmDialog({ title: view.demonstration ? 'Mise à jour fictive' : 'Fermer Domenia et installer',
          message: view.demonstration ? 'Seule la version fictive de cet espace changera. Aucun binaire ne sera remplacé.'
            : `Installer Domenia ${view.candidate?.version} depuis ${view.candidate?.provenance} ? La fenêtre se fermera après la fin des opérations. L’assistant contrôlera le démarrage et conservera les preuves en cas d’échec.`,
          confirmLabel: view.demonstration ? 'Simuler' : 'Fermer et installer' });
        if (!alive || !yes || !captured) return;
        const result = await sctx.call('settings.update.install', { confirmation: captured });
        if (alive) sctx.toast(result.message, { tone: result.simulated ? 'ok' : 'info' });
        await load();
      } else {
        const operation = action === 'folder-pick' ? 'settings.update.folder' : action === 'prepare' ? 'settings.update.prepare'
          : action === 'rollback' ? 'settings.update.demoRollback' : 'settings.update.check';
        const value = await sctx.call(operation, ['folder', 'local'].includes(action) ? { source: action } : {});
        if (alive) view = value;
      }
    } catch (err) {
      if (alive) { failure = err; sctx.toast(reported(err), { tone: 'warn' }); await load(); draw(); }
      return;
    } finally { busy = false; if (alive) draw(); }
    if (alive) draw();
  }
  const click = (event) => {
    const target = event.target instanceof Element ? event.target.closest('[data-update]') : null;
    if (target && !target.disabled) act(target.dataset.update);
    else if (event.target instanceof Element && event.target.closest('[data-act="retry"]')) load();
  };
  host.addEventListener('click', click); draw(); load();
  return { destroy() { alive = false; stopReveal(); host.removeEventListener('click', click); } };
}
