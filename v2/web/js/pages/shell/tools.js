// Tabs « Sélecteurs et exports » (TRV-242 to TRV-246, TRV-054, TRV-055), « Automatisation » (TRV-067 to TRV-069) and
// « Démonstration » (TRV-047, TRV-048) of the shell centre.
import { icon } from '../../icons.js';
import { esc, errorText, relTime } from '../../ui.js';
import { state, quietCall, trackedCall } from '../../shell/store.js';
import { pickOu, pickObject, pickFile } from '../../shell/pickers.js';
import { exportRows, importCsv } from '../../shell/exports.js';
import { notify } from '../../shell/notify.js';
import { statusBadge } from '../../shell/glyphs.js';
import { operationSummary } from '../../shell/summary.js';

const NBSP = ' ';

function sizeText(bytes) {
  if (!Number.isFinite(bytes)) return '';
  if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(1).replace('.', ',')}${NBSP}Mo`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)}${NBSP}Ko`;
  return `${bytes}${NBSP}octets`;
}

export function renderTools(panel) {
  panel.innerHTML = `<div class="sh-tools">
    <section class="card sh-tool">
      <header class="card-head"><span class="card-icon">${icon('folder')}</span><h3>Sélecteur d’OU partagé</h3></header>
      <p class="muted">Arbre lu à l’ouverture de chaque branche, recherche par nom, favoris du domaine, portée avec ou sans sous-OU, résumé avant validation et revérification du choix.</p>
      <div class="sh-tool-actions"><button class="btn sm primary" type="button" data-tool="ou">${icon('folder')}Choisir une OU</button></div>
      <div class="sh-tool-result" data-result="ou"></div>
    </section>
    <section class="card sh-tool">
      <header class="card-head"><span class="card-icon">${icon('search')}</span><h3>Sélecteur d’objet intégré</h3></header>
      <p class="muted">Utilisateurs, postes ou OU de tout le domaine : 2 caractères au moins, 100 résultats ; le DN et le GUID sont revérifiés avant que le choix soit transmis.</p>
      <div class="sh-tool-actions"><button class="btn sm primary" type="button" data-tool="object">${icon('search')}Chercher un objet</button></div>
      <div class="sh-tool-result" data-result="object"></div>
    </section>
    <section class="card sh-tool">
      <header class="card-head"><span class="card-icon">${icon('file')}</span><h3>Importer un CSV</h3></header>
      <p class="muted">Fichier choisi dans le sélecteur intégré (dossiers locaux seulement, 500 entrées) ; séparateur détecté : point-virgule de Domenia ou virgule d’un autre outil.</p>
      <div class="sh-tool-actions"><button class="btn sm primary" type="button" data-tool="import">${icon('file')}Choisir un fichier CSV</button><button class="btn sm ghost" type="button" data-tool="file">${icon('folder')}Parcourir les fichiers</button></div>
      <div class="sh-tool-result" data-result="import"></div>
    </section>
    <section class="card sh-tool">
      <header class="card-head"><span class="card-icon">${icon('download')}</span><h3>Exports</h3>
        <span class="meta"><button class="btn sm ghost" type="button" data-tool="open">${icon('folder')}Ouvrir le dossier</button></span></header>
      <p class="muted">CSV à point-virgule en UTF-8 avec BOM, en-têtes français, formules neutralisées, colonnes secrètes retenues et textes ressemblant à un secret masqués ; jamais d’écrasement.</p>
      <div class="sh-tool-actions"><button class="btn sm subtle" type="button" data-tool="export">${icon('download')}Exporter un exemple</button><button class="btn sm ghost" type="button" data-tool="summary">${icon('eye')}Résumé d’opération</button></div>
      <div class="sh-tool-result" data-result="exports" aria-busy="true"><p class="sh-loading"><span class="k-spin"></span>Dossier des exports…</p></div>
    </section>
  </div>`;
  const result = (name) => panel.querySelector(`[data-result="${name}"]`);
  const paintExports = async () => {
    const box = result('exports');
    try {
      const listing = await quietCall('shell.export.list');
      box.removeAttribute('aria-busy');
      if (!listing) { box.innerHTML = '<p class="faint">Exports indisponibles dans cet aperçu.</p>'; return; }
      box.innerHTML = `<p class="sh-folder-line">${icon('folder')}<span>${esc(listing.folder)}</span></p>${listing.items.length
        ? `<ol class="sh-file-list">${listing.items.slice(0, 8).map((f) => `<li>${icon('file')}<span class="mono">${esc(f.fileName)}</span><span class="faint">${esc(sizeText(f.size))} · ${esc(relTime(f.at) ?? '')}</span></li>`).join('')}</ol>`
        : '<p class="faint">Aucun export pour l’instant.</p>'}`;
    } catch (err) {
      box.removeAttribute('aria-busy');
      box.innerHTML = `<p class="sh-pick-error">${esc(errorText(err))}</p>`;
    }
  };
  panel.addEventListener('click', async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-tool]') : null;
    if (!b) return;
    const tool = b.dataset.tool;
    if (tool === 'ou') {
      const r = await pickOu({ title: 'Choisir une OU', effect: 'Démonstration du sélecteur partagé : rien n’est appliqué.' });
      result('ou').innerHTML = r ? `<div class="sh-pick-chosen"><div><span class="sh-pick-label">OU choisie et revérifiée</span><strong>${esc(r.name)}</strong><span class="sh-pick-path">${esc(r.path)} · ${r.subtree ? 'sous-OU comprises' : 'sans les sous-OU'}</span></div></div>` : '<p class="faint">Aucune OU choisie.</p>';
    }
    if (tool === 'object') {
      const r = await pickObject({ title: 'Chercher un objet' });
      result('object').innerHTML = r ? `<div class="sh-pick-chosen"><div><span class="sh-pick-label">${esc(r.kindLabel)} revérifié</span><strong>${esc(r.name)}</strong><span class="sh-pick-path">${esc(r.detail ?? '')} · ${esc(r.path)}</span></div></div>` : '<p class="faint">Aucun objet choisi.</p>';
    }
    if (tool === 'import') {
      const table = await importCsv();
      result('import').innerHTML = table ? `<p>${statusBadge('confirmé', { label: `${table.total} ligne${table.total > 1 ? 's' : ''} · séparateur « ${table.delimiter} »` })}${table.truncated ? ' <span class="faint">(lignes au-delà de 5 000 non reprises, signalé)</span>' : ''}</p>
        <div class="sh-table-scroll"><table class="table"><thead><tr>${table.headers.slice(0, 8).map((h) => `<th scope="col">${esc(h)}</th>`).join('')}</tr></thead><tbody>${table.rows.slice(0, 6).map((r) => `<tr>${r.slice(0, 8).map((c) => `<td>${esc(c)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>` : '<p class="faint">Aucun fichier lu.</p>';
    }
    if (tool === 'file') {
      const f = await pickFile({ title: 'Parcourir les fichiers' });
      result('import').innerHTML = f ? `<p class="mono">${esc(f.path)}</p>` : '<p class="faint">Aucun fichier choisi.</p>';
    }
    if (tool === 'open') {
      const r = await quietCall('shell.export.open', { fileName: null }).catch(() => null);
      if (r && !r.opened) notify('Dossier des exports indisponible : cette session ne garde rien sur le disque (capture ou essai).', { tone: 'info' });
    }
    if (tool === 'export') {
      const session = state.session;
      await exportRows({
        name: 'exemple-interface',
        headers: ['Réglage', 'Valeur', 'Remarque'],
        rows: [
          ['Thème', state.prefs.theme, ''],
          ['Animations', state.prefs.motion, ''],
          ['Domaine', session?.domain?.dnsName ?? '', ''],
          ['Compte', session?.account?.login ?? '', ''],
          ['Formule neutralisée', '=1+1', 'commence par « = » : apostrophe ajoutée'],
          ['Texte masqué', 'password=exemple', 'ressemble à un secret : masqué'],
        ],
      });
      paintExports();
    }
    if (tool === 'summary') {
      const s = operationSummary('Réinitialiser le mot de passe (exemple)', [
        { name: 'NewPassword', label: 'Nouveau mot de passe', value: 'exemple-non-envoyé' },
        { name: 'MustChange', label: 'Changer à la prochaine connexion', value: true, default: false },
        { name: 'Unlock', label: 'Déverrouiller aussi le compte', value: false, default: false, influences: true },
        { name: 'Comment', label: 'Commentaire du reçu', value: 'Appel 4521', advanced: true },
      ]);
      result('exports').innerHTML = `<div class="sh-summary"><strong>${esc(s.operation)}</strong><ul>${s.lines.map((l) => `<li><span>${esc(l.label)}</span><strong>${esc(l.value)}</strong>${l.advanced ? '<span class="k-badge">option avancée</span>' : ''}</li>`).join('')}</ul><p class="faint">Les options repliées sont listées ; une valeur sensible affiche « (masqué) » même sans indication de l’appelant.</p></div>`;
    }
  });
  paintExports();
}

export function renderAutomation(panel) {
  panel.innerHTML = `<div class="sh-auto">
    <section class="card sh-auto-contract" aria-busy="true"><p class="sh-loading"><span class="k-spin"></span>Contrat de l’interface automatisable…</p></section>
    <section class="card sh-auto-try">
      <header class="card-head"><span class="card-icon">${icon('command')}</span><h3>Vérifier une commande</h3></header>
      <form class="k-form sh-auto-form" data-auto-form>
        <label class="k-field w-half"><span class="k-label">Commande</span><select class="input k-select" name="command">
          <option value="postes">postes</option><option value="etat">etat</option><option value="version">version</option><option value="observations">observations</option><option value="associations">associations</option><option value="requetes">requetes</option><option value="dossier">dossier</option></select></label>
        <label class="k-field w-half"><span class="k-label">Format</span><select class="input k-select" name="format"><option value="">Par défaut</option><option value="Json">JSON</option><option value="Csv">CSV</option></select></label>
        <label class="k-field w-full"><span class="k-label">OU (périmètre)</span><span class="sh-auto-ou"><input class="input mono" name="ou" placeholder="OU=Paris,OU=Postes,DC=example,DC=local" autocomplete="off" spellcheck="false"><button class="btn sm ghost" type="button" data-auto-pick>${icon('folder')}Choisir</button></span></label>
        <label class="k-field w-half"><span class="k-label">Noms de postes</span><input class="input mono" name="computers" placeholder="PC-PAR-0001, PC-PAR-0002" autocomplete="off" spellcheck="false"></label>
        <label class="k-field w-half"><span class="k-label">Limite de lignes</span><input class="input" name="limit" type="number" min="0" max="5000" placeholder="1 000 par défaut"></label>
        <div class="k-form-actions"><button class="btn primary" type="submit">${icon('play')}Vérifier et prévisualiser</button></div>
      </form>
      <div class="sh-auto-out" data-auto-out><p class="faint">La vérification suit les règles de la ligne de commande : périmètre exigé et unique, bornes, codes de sortie. L’aperçu est limité à 100 lignes.</p></div>
    </section>
  </div>`;
  quietCall('shell.automation.contract').then((c) => {
    const box = panel.querySelector('.sh-auto-contract');
    box.removeAttribute('aria-busy');
    if (!c) { box.innerHTML = '<p class="faint">Contrat indisponible dans cet aperçu.</p>'; return; }
    box.innerHTML = `<header class="card-head"><span class="card-icon">${icon('database')}</span><h3>${esc(c.contract)}</h3><span class="meta">${esc(c.transport)}</span></header>
      <div class="sh-auto-grid">
        <div><h4 class="sh-sub">Commandes</h4><table class="table"><thead><tr><th scope="col">Commande</th><th scope="col">Nature</th><th scope="col">Formats</th><th scope="col">Périmètre</th></tr></thead>
          <tbody>${c.commands.map((cmd) => `<tr><td class="mono"><strong>${esc(cmd.name)}</strong><span class="sh-auto-desc">${esc(cmd.description)}</span></td><td>${esc(cmd.kind)}</td><td>${esc(cmd.formats.join(', '))}</td><td>${cmd.perimeter ? statusBadge('attention', { label: 'Exigé' }) : statusBadge('vide', { label: 'Aucun' })}</td></tr>`).join('')}</tbody></table></div>
        <div><h4 class="sh-sub">Codes de sortie</h4><dl class="sh-kv">${c.exitCodes.map((x) => `<div class="sh-kv-row"><dt><strong class="mono">${x.code}</strong> ${esc(x.name)}</dt><dd>${esc(x.meaning)}</dd></div>`).join('')}</dl>
          <h4 class="sh-sub">Bornes</h4><p>${esc(`${new Intl.NumberFormat('fr-FR').format(c.limits.defaultRows)} lignes par défaut, ${new Intl.NumberFormat('fr-FR').format(c.limits.maxRows)} au plus, ${c.limits.maxNames} noms au plus.`)}</p>
          <h4 class="sh-sub">Règles</h4><ul class="sh-bullets">${c.rules.map((r) => `<li>${esc(r)}</li>`).join('')}</ul></div>
      </div>`;
  }).catch((err) => { const box = panel.querySelector('.sh-auto-contract'); box.removeAttribute('aria-busy'); box.innerHTML = `<p class="sh-pick-error">${esc(errorText(err))}</p>`; });
  const form = panel.querySelector('[data-auto-form]');
  panel.querySelector('[data-auto-pick]').addEventListener('click', async () => {
    const r = await pickOu({ title: 'Périmètre de la commande', subtree: 'forced', effect: 'La commande portera sur cette OU et ses sous-OU.' });
    if (r) form.elements.ou.value = r.dn;
  });
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const out = panel.querySelector('[data-auto-out]');
    const values = Object.fromEntries(new FormData(form));
    out.innerHTML = '<p class="sh-loading" aria-busy="true"><span class="k-spin"></span>Vérification…</p>';
    try {
      const r = await trackedCall('shell.automation.preview', {
        command: values.command, format: values.format || null, ou: values.ou?.trim() || null,
        computers: values.computers?.trim() ? values.computers.split(',').map((x) => x.trim()).filter(Boolean) : null,
        guids: null, limit: values.limit ? Number(values.limit) : null,
      });
      out.innerHTML = `<p>${statusBadge(r.valid ? 'confirmé' : 'refusé', { label: r.valid ? 'Commande valide · code 0' : `Refusée · code ${r.exitCode}` })} <span>${esc(r.summary)}</span></p>
        ${r.output ? `<pre class="sh-auto-pre mono" tabindex="0" aria-label="Réponse de la commande">${esc(r.output.length > 20000 ? `${r.output.slice(0, 20000)}\n…` : r.output)}</pre>` : ''}`;
    } catch (err) {
      out.innerHTML = `<p class="sh-pick-error">${esc(errorText(err))}</p>`;
    }
  });
}

export function renderDemonstration(panel) {
  panel.innerHTML = `<div class="sh-demo">
    <section class="card sh-demo-cov" aria-busy="true"><p class="sh-loading"><span class="k-spin"></span>Annuaire de démonstration…</p></section>
    <section class="card">
      <header class="card-head"><span class="card-icon">${icon('zap')}</span><h3>Comportement de la simulation</h3></header>
      <ul class="sh-bullets">
        <li>Les opérations répondent dans les formes exactes du mode annuaire, après une latence réaliste et annulable.</li>
        <li>Une opération réseau que l’annuaire fictif ne sert pas est refusée explicitement : « Non disponible en simulation ».</li>
        <li>Un objet introuvable est dit introuvable ; le compte refusé de la démonstration répond « accès refusé » dans les sélecteurs.</li>
        <li>Aucun réseau, aucun mot de passe : les écritures ne modifient qu’une surcouche en mémoire, et leurs reçus sont marqués « simulé ».</li>
        <li>Le domaine example.local ne peut entrer en collision avec aucun domaine réel du labo.</li>
      </ul>
    </section>
  </div>`;
  quietCall('shell.demo.coverage').then((c) => {
    const box = panel.querySelector('.sh-demo-cov');
    box.removeAttribute('aria-busy');
    if (!c?.available) {
      box.innerHTML = `<header class="card-head"><span class="card-icon">${icon('zap')}</span><h3>Annuaire de démonstration</h3></header><p class="muted">${esc(c?.summary ?? 'Disponible en simulation.')}</p>`;
      return;
    }
    box.innerHTML = `<header class="card-head"><span class="card-icon">${icon('zap')}</span><h3>Annuaire de démonstration</h3><span class="meta">${statusBadge(c.present === c.total ? 'confirmé' : 'partiel', { label: `${c.present}${NBSP}/${NBSP}${c.total} catégories` })}</span></header>
      <p class="muted">${esc(c.summary)}</p>
      <ol class="sh-fixtures">${c.fixtures.map((f) => `<li data-present="${f.present}">${statusBadge(f.present ? 'confirmé' : 'vide', { label: f.present ? 'Présent' : 'Absent' })}<div><strong>${esc(f.label)}</strong><span class="faint">${esc(f.detail)}</span></div><span class="sh-fixture-n num">${new Intl.NumberFormat('fr-FR').format(f.count)}</span></li>`).join('')}</ol>`;
  }).catch((err) => { const box = panel.querySelector('.sh-demo-cov'); box.removeAttribute('aria-busy'); box.innerHTML = `<p class="sh-pick-error">${esc(errorText(err))}</p>`; });
}
