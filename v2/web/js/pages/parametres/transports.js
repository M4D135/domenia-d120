import { esc, errorText } from '../../ui.js';

export function mount(host, ctx) {
  let alive = true; let saving = false; let value;
  const labels = {
    useCim: 'Lectures CIM / WMI', useWinRm: 'Autoriser WinRM déjà configuré sur le poste',
    useRemoteRegistry: 'Lire le registre distant', allowRemoteArtifacts: 'Activer les collectes ponctuelles',
    useTaskFallback: 'Tâche planifiée temporaire', usePsExecFallback: 'PsExec approuvé',
    useWmiProcess: 'Processus local lancé par WMI', useWinRmScript: 'Script local lancé par WinRM',
  };
  const checkbox = key => `<label class="pr-text"><input type="checkbox" name="${key}"${value[key] ? ' checked' : ''}> ${esc(labels[key])}</label>`;
  function choices(key, label, items) {
    return `<label class="pr-text">${esc(label)} <select class="input" name="${key}">${items.map(([id, title]) => `<option value="${id}"${value[key] === id ? ' selected' : ''}>${esc(title)}</option>`).join('')}</select></label>`;
  }
  function draw() {
    host.innerHTML = `<header class="pr-section-head"><h2>Lectures distantes</h2><p>Choisissez comment Domenia lit vos postes. Enregistrer ces réglages ne lance aucune collecte.</p></header>
      <form data-remote-settings><section class="card"><h3>Lectures directes</h3>${checkbox('useCim')}${checkbox('useWinRm')}${checkbox('useRemoteRegistry')}
      ${choices('directMode', 'Transport CIM', [['auto', 'Automatique selon les transports autorisés'], ['dcom', 'WMI / DCOM'], ['winrm', 'CIM / WinRM']])}
      <p>Automatique privilégie WinRM lorsqu’il est autorisé, sinon DCOM. Un refus d’identifiants suspend le compte ; aucun autre compte n’est essayé.</p></section>
      <section class="card"><h3>Collectes ponctuelles</h3><p>Désactivées par défaut. Après activation, Domenia peut déposer un script temporaire, le lancer et récupérer son résultat. Chaque exécution et son nettoyage sont suivis dans la base locale.</p>
      ${checkbox('allowRemoteArtifacts')}
      <fieldset data-transient-options><legend>Méthodes autorisées</legend>${checkbox('useTaskFallback')}${checkbox('usePsExecFallback')}${checkbox('useWmiProcess')}${checkbox('useWinRmScript')}
      ${choices('transientMode', 'Déclenchement', [['manual', 'Manuel : autoriser chaque poste'], ['automatic', 'Automatique dans le périmètre demandé']])}
      ${choices('transientMethod', 'Méthode', [['auto', 'Choisir une méthode autorisée avant le lancement'], ['task', 'Tâche planifiée'], ['psexec', 'PsExec'], ['wmi', 'Processus WMI'], ['winrm', 'Script WinRM']])}
      <label class="pr-text">Postes au plus par campagne en mode automatique <input class="input" name="automaticTargetLimit" type="number" min="1" max="100000" step="1" value="${value.automaticTargetLimit}"></label></fieldset>
      <p>Deux exécutions ponctuelles au plus simultanément. Le dépôt utilise le partage ADMIN$. Aucun agent résident. Une exécution dont l’issue ou le nettoyage reste incertain n’est pas relancée avec une autre méthode. PsExec nécessite son exécutable approuvé et le contexte Windows intégré. WMI et WinRM exécutent le programme avec le compte administrateur choisi.</p></section>
      <section class="card"><h3>Compte utilisé</h3><p>Une identité d’administration confirmée est requise avant toute lecture distante. Un compte ordinaire conserve la lecture de l’annuaire. Vous pouvez valider un autre compte pour la fonction concernée ; seul son identifiant peut être mémorisé.</p><p>Les essais de compte et la validation d’un administrateur local utilisent actuellement WMI / DCOM. Le choix WinRM exclusif bloque ces essais : aucun essai DCOM caché.</p></section>
      <button class="btn primary" type="submit">Enregistrer</button><p role="status" data-remote-status></p></form>`;
    enabled();
  }
  function enabled() { const box = host.querySelector('[name=allowRemoteArtifacts]'); host.querySelector('[data-transient-options]').disabled = !box.checked; }
  const change = e => { if (e.target.name === 'allowRemoteArtifacts') enabled(); };
  const submit = async e => {
    if (!e.target.matches('[data-remote-settings]')) return;
    e.preventDefault(); if (saving) return;
    const form = e.target; const next = { ...value };
    Object.keys(labels).forEach(key => { next[key] = form.elements[key].checked; });
    ['directMode', 'transientMode', 'transientMethod'].forEach(key => { next[key] = form.elements[key].value; });
    next.automaticTargetLimit = Number(form.elements.automaticTargetLimit.value);
    saving = true; form.querySelector('button').disabled = true;
    try { value = await ctx.call('settings.remoteCollection.set', next); if (alive) { draw(); host.querySelector('[data-remote-status]').textContent = 'Réglages enregistrés. Ils s’appliqueront aux prochaines lectures.'; } }
    catch (err) { if (alive) host.querySelector('[data-remote-status]').textContent = errorText(err); }
    finally { saving = false; if (alive) form.querySelector('button').disabled = false; }
  };
  host.addEventListener('change', change); host.addEventListener('submit', submit);
  ctx.call('settings.remoteCollection').then(result => { if (alive) { value = result; draw(); } }).catch(err => { if (alive) host.innerHTML = `<p role="alert">${esc(errorText(err))}</p>`; });
  return { destroy() { alive = false; host.removeEventListener('change', change); host.removeEventListener('submit', submit); } };
}
