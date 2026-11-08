// Optional, deterministic local guidance. No model, service, polling or automatic action.
import { esc } from '../kit/util.js';
const SUGGESTIONS = {
  accueil: [['Créer un widget', 'widget'], ['Comprendre les valeurs anciennes ou manquantes', 'fraîcheur'], ['Organiser les sections', 'accueil']],
  requetes: [['Partir d’une requête prête', 'bibliothèque'], ['Comprendre une information WMI', 'WMI'], ['Afficher la répartition dans un widget', 'répartition']],
  poste: [['Choisir le compte du poste', 'compte poste'], ['Comprendre un refus de lecture', 'diagnostic'], ['Réutiliser un relevé conservé', 'cache']],
  rechercher: [['Affiner la recherche', 'recherche'], ['Limiter le périmètre à une OU', 'OU'], ['Vérifier les postes de la liste', 'vérifier']],
  parametres: [['Adapter la collecte au réseau', 'collecte'], ['Conserver les données locales', 'sauvegarde'], ['Choisir l’OU de travail', 'OU']],
};
export function localGuidance(state) {
  if (state.policy?.localAssistant !== true) return [];
  if (state.reach?.offline) return [['Retrouver les dernières données conservées', 'cache'], ['Comprendre la connexion au domaine', 'connexion']];
  return SUGGESTIONS[state.page?.id] ?? [['Comprendre cet écran', state.page?.label || 'interface'], ['Comprendre un contrôle grisé', 'droits']];
}
export function paintLocalAssistant(host, state, search) {
  const suggestions = localGuidance(state);
  host.hidden = suggestions.length === 0;
  host.replaceChildren();
  if (!suggestions.length) return;
  host.innerHTML = '<h3>Aide guidée</h3><p class="faint">Suggestions locales pour votre écran. Chaque choix ouvre un sujet d’aide.</p><ol class="sh-help-topics"></ol>';
  const list = host.querySelector('ol');
  for (const [label, query] of suggestions) {
    const li = document.createElement('li');
    li.innerHTML = `<button class="sh-help-hit" type="button"><span class="sh-help-hit-t">${esc(label)}</span></button>`;
    li.querySelector('button').addEventListener('click', () => search(query)); list.append(li);
  }
}
