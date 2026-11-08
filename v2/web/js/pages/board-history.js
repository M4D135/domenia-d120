import { openDialog } from '../kit/dialog.js';
import { esc } from '../ui.js';

/** Only returns the explicitly chosen ID. The caller must submit the unchanged choice token to its real board handler. */
export async function chooseBoardVersion(view, title) {
  const versions = view?.history ?? [];
  if (!versions.length) return null;
  const body = document.createElement('div');
  const stamp = v => v.savedAt ? new Date(v.savedAt).toLocaleString('fr-FR') : 'Date de l’ancienne disposition inconnue';
  body.innerHTML = `<p>Restaurez une des cinq dispositions précédentes. Le choix actuel sera conservé dans l’historique. Aucune collecte ne sera lancée.</p>
    <label>Version <select data-board-version>${versions.map(v => `<option value="${esc(v.id)}">${esc(stamp(v))} · ${v.items.length} carte${v.items.length > 1 ? 's' : ''}</option>`).join('')}</select></label>
    <div data-board-version-preview></div>`;
  const selected = () => versions.find(v => v.id === body.querySelector('[data-board-version]').value);
  const paint = () => {
    const version = selected();
    body.querySelector('[data-board-version-preview]').innerHTML = `<p class="code">Empreinte : ${esc(version.sha256)}</p>
      ${version.items.length ? `<ol>${version.items.map(i => `<li>${esc(i.title || i.queryBinding?.name || i.key)}${i.group ? ` · ${esc(i.group)}` : ''}${i.paused ? ' · en pause' : ''}${i.queryBinding ? (i.queryBinding.libraryWidgetId ? ` · liaison de l’atelier, origine r${i.queryBinding.revision}` : ` · révision épinglée ${i.queryBinding.revision}`) : ''}</li>`).join('')}</ol>` : '<p>Tableau volontairement vide.</p>'}
      <p>Les requêtes restent soumises à leurs liaisons actuelles et aux données locales disponibles. Une recette retirée ne sera pas recréée.</p>`;
  };
  body.querySelector('[data-board-version]').addEventListener('change', paint); paint();
  const dialog = openDialog({ title: `Versions · ${title}`, icon: 'history', size: 'md', body,
    actions: [{ id: 'cancel', label: 'Fermer', safe: true }, { id: 'restore', label: 'Restaurer cette disposition', primary: true }] });
  return await dialog.result === 'restore' ? selected().id : null;
}
