import { esc, errorText } from '../../ui.js';
import { openDialog } from '../../kit/dialog.js';
import { importJson } from '../../shell/exports.js';
import { readingPrefs } from './interface.js';
import { applyImportedInterface, configurationPreviewMarkup, proposePackConfiguration } from '../../shell/configuration-defaults.js';

export function mount(host, ctx) {
  let alive = true; let busy = false; let options = null; let dialog = null;
  const call = (op, args) => ctx.call(op, args);
  const setPrefs = (values) => { ctx.prefs.set(values); ctx.refreshAppearanceTile?.(); };
  async function load() {
    options = await call('settings.configuration.options');
    if (!alive) return;
    host.innerHTML = `<header class="pr-section-head"><h2>Configuration à diffuser</h2><p>Choisissez les réglages de ce poste à fournir avec ce dossier de Domenia. Un profil vierge les reçoit au démarrage ; un profil existant choisit de les remplacer ou de les conserver au premier lancement de chaque nouvelle version.</p></header>
      ${options.simulated ? '<p role="status">Démonstration : réglages fictifs et exports isolés. Aucun fichier réel de configuration joint au pack n’est lu.</p>' : ''}
      <section class="card"><h3>Réglages inclus</h3><p>Les valeurs effectives livrées sont proposées même lorsqu’aucun choix n’a encore été enregistré. Cochez explicitement chaque OU de travail à partager.</p>
      ${options.choices.map(c => `<label class="pr-text"><input type="checkbox" data-config-key="${esc(c.key)}"${c.selected ? ' checked' : ''}${c.valid ? '' : ' disabled'}> ${esc(c.label)} <span class="code">${esc(c.key)}</span>${c.valid ? '' : ' — valeur invalide, exclue'}<small>${esc(JSON.stringify(c.value))}</small></label>`).join('')}
      <label><input type="checkbox" data-config-ui checked> Interface : thème, animations, menu, profil, densité, aide et lecture du journal</label>
      <h3>Exclusions</h3><p>Identité de connexion, identifiants mémorisés, coffre, secrets, fenêtre, données de parc, plans d’écriture et recettes ne sont jamais joints. Le fichier administrateur Domenia.config.json reste une configuration distincte du pack.</p>
      <ul>${options.excluded.map(k => `<li class="code">${esc(k)}</li>`).join('') || '<li>Aucune autre clé enregistrée.</li>'}</ul>
      <div class="pr-actions"><button class="btn" data-config-action="export">Exporter un fichier</button><button class="btn primary" data-config-action="package">Définir comme configuration par défaut</button></div></section>
      <section class="card"><h3>Importer</h3><p>Le même fichier ${esc(options.fileName)} peut être importé manuellement après aperçu. Le document courant est sauvegardé avant tout remplacement.</p>
      <div class="pr-actions"><button class="btn" data-config-action="import">Importer un fichier</button><button class="btn" data-config-action="seed">Revoir la proposition du pack</button><button class="btn" data-config-action="reload">Relire mes choix</button></div></section>
      <p role="status" data-config-result></p>`;
  }
  // Writing the defaults records this profile's own decision, which changes the preference fingerprint: reread the
  // options so the next export is not refused, and keep the choices visible on the page.
  async function refresh() {
    const valid = new Set(options.choices.filter(c => c.valid).map(c => c.key));
    const kept = new Map([...host.querySelectorAll('[data-config-key]')].filter(input => valid.has(input.dataset.configKey))
      .map(input => [input.dataset.configKey, input.checked]));
    const uiChecked = host.querySelector('[data-config-ui]').checked;
    await load();
    if (!alive) return;
    host.querySelectorAll('[data-config-key]').forEach(input => {
      if (kept.has(input.dataset.configKey) && options.choices.find(c => c.key === input.dataset.configKey)?.valid) input.checked = kept.get(input.dataset.configKey);
    });
    host.querySelector('[data-config-ui]').checked = uiChecked;
  }
  function ui() {
    const raw = ctx.prefs.get(); const read = readingPrefs();
    return { theme: raw.theme, motion: raw.motion, navCollapsed: raw.navCollapsed, profile: raw.profile, density: raw.density, helpTips: raw.helpTips, logWrap: read.logWrap === true, logSize: [10, 11, 12, 14, 16, 18].includes(read.logSize) ? read.logSize : 11 };
  }
  async function exportOrPackage(action) {
    const keys = [...host.querySelectorAll('[data-config-key]:checked')].map(input => input.dataset.configKey);
    const exported = await call('settings.configuration.export', { keys, interface: host.querySelector('[data-config-ui]').checked ? ui() : null, fingerprint: options.fingerprint });
    if (!alive) return;
    dialog = openDialog({ title: action === 'package' ? 'Définir comme configuration par défaut' : 'Exporter la configuration', icon: 'download', size: 'lg',
      body: `<p>${action === 'package' ? `Écrire cette configuration dans <span class="code">wad/${esc(options.fileName)}</span>, à côté du logiciel ouvert : ce dossier devient prêt à diffuser. Le ZIP officiel, le manifeste et les binaires restent intacts. Une configuration déjà présente est d’abord sauvegardée dans vos exports.` : 'Enregistrer la configuration validée dans les exports privés de Domenia.'}</p>
        <p>Inclus : ${esc(exported.included.join(', ') || 'Aucun réglage')}.</p><p>Exclus : ${esc(exported.excluded.join(', ') || 'Aucune autre clé')}.</p>
        <p>SHA-256 : <span class="code">${esc(exported.sha256)}</span></p><details><summary>Configuration exacte</summary><pre>${esc(exported.text)}</pre></details>`,
      actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'confirm', label: action === 'package' ? 'Écrire la configuration par défaut' : 'Exporter ce fichier', primary: true }] });
    if (await dialog.result !== 'confirm' || !alive) return;
    const result = await call(action === 'package' ? 'settings.defaults.package' : 'settings.configuration.save', { text: exported.text });
    if (!alive) return;
    host.querySelector('[data-config-result]').textContent = result.message;
    ctx.toast(result.message, { tone: result.simulated || result.saved === false ? 'info' : 'ok' });
    if (action !== 'package') return;
    await refresh();
    if (alive) host.querySelector('[data-config-result]').textContent = result.message;
  }
  async function importFile() {
    const file = await importJson('Importer une configuration de Domenia');
    if (!file || !alive) return;
    const preview = await call('settings.configuration.preview', { text: file.text });
    if (!alive) return;
    dialog = openDialog({ title: 'Importer la configuration', icon: 'sliders', size: 'lg', body: configurationPreviewMarkup(preview),
      actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'apply', label: 'Sauvegarder et importer', primary: true }] });
    if (await dialog.result !== 'apply' || !alive) return;
    const result = await call('settings.configuration.apply', { text: file.text, fingerprint: preview.fingerprint });
    if (!alive) return;
    applyImportedInterface(result, setPrefs);
    await load();
    if (alive) { host.querySelector('[data-config-result]').textContent = result.summary; ctx.toast(result.summary, { tone: 'ok' }); }
  }
  const clicked = async (event) => {
    const button = event.target instanceof Element ? event.target.closest('[data-config-action]') : null;
    if (!button || busy || !alive) return;
    busy = true; host.querySelectorAll('button,input').forEach(el => { el.disabled = true; });
    try {
      const action = button.dataset.configAction;
      if (action === 'export' || action === 'package') await exportOrPackage(action);
      else if (action === 'import') await importFile();
      else if (action === 'seed') { await proposePackConfiguration(call, setPrefs, ctx.toast, () => alive, true); if (alive) await refresh(); }
      else await load();
    } catch (err) { if (alive) ctx.toast(errorText(err), { tone: 'warn' }); }
    finally { busy = false; dialog = null; if (alive) host.querySelectorAll('button,input').forEach(el => { el.disabled = el.hasAttribute('data-config-key') && !options.choices.find(c => c.key === el.dataset.configKey)?.valid; }); }
  };
  host.addEventListener('click', clicked);
  load().catch(err => { if (alive) host.innerHTML = `<p role="alert">${esc(errorText(err))}</p>`; });
  return { destroy() { alive = false; dialog?.close('cancel'); host.removeEventListener('click', clicked); } };
}
