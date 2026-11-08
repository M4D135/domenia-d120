// Personal declarative probes: read, edit, inspect the exact proposed document, then explicitly save it locally.
// Adding a widget and collecting its values remain separate operator actions in the normal catalogue.
import { openDialog } from '../../kit/dialog.js';
import { glyph } from '../../kit/glyphs.js';
import { pill } from '../../kit/status.js';
import { esc, formatNumber } from '../../ui.js';
import { importJson } from '../../shell/exports.js';
import { reported, surface } from './shared.js';

const MAX_DOCUMENT = 262144;
const EXAMPLE = JSON.stringify({
  SchemaVersion: 1,
  Probes: [{
    Id: 'custom.manufacturer', Category: 'Personnelles', Name: 'Fabricant déclaré',
    Namespace: 'root\\cimv2', Class: 'Win32_ComputerSystem', Properties: ['Manufacturer'],
    Filter: '', Mode: 'First', Transform: 'Text', Visual: 'Bar', Slow: true, SkipOnDc: true,
    Origin: 'Personnalisée', Description: 'Fabricant rapporté par le fournisseur.',
    Rights: 'Compte autorisé sur la cible.', Compatibility: 'Windows avec CIMWin32.',
    UnknownMeaning: 'Absence ou refus : inconnu.', Limitations: 'Matériel présenté à Windows seulement.',
    SourceUrls: ['https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem'],
    Fields: [{ Name: 'Manufacturer', CimType: 'string', Kind: 'Text', IsArray: false, Unit: '', Description: 'Nom rapporté.' }],
    Behavior: { Reads: 'CIM', Writes: false, Code: 'Aucun', Methods: [], Target: 'Liste de postes explicitement choisie.' },
    Privilege: { Level: 'AdministrateurLocal', Text: 'Délégation à qualifier : administrateur local exigé par cette déclaration.' },
    Cost: { Level: 'Léger', Reason: 'Une instance ; collecte conservée explicite.' },
  }],
}, null, 2);

const fits = (text) => text.length <= MAX_DOCUMENT && new TextEncoder().encode(text).byteLength <= MAX_DOCUMENT;
const sizeMessage = 'Le document dépasse 256 Kio en UTF-8 ou 262 144 caractères. Son contenu reste intact ; réduisez-le avant de le prévisualiser.';

function contractMarkup(contract) {
  const c = contract ?? {};
  const sections = new Map();
  for (const line of c.lines ?? []) {
    if (!sections.has(line.section)) sections.set(line.section, []);
    sections.get(line.section).push(line.value);
  }
  return `<p class="pp-description">${esc(c.summary ?? '')}</p><div class="ct-pills">`
    + `${pill(c.valid ? 'ok' : 'alert', c.valid ? 'Contrat valide' : 'Contrat incomplet', { icon: c.valid ? 'check' : 'alert' })}`
    + `${pill('info', `Droits : ${c.privilegeLevel ?? 'Non déclarés'}`, { icon: 'key' })}`
    + `${pill(c.costLevel === 'Lourd' ? 'warn' : 'off', `Coût : ${c.costLevel ?? 'Non déclaré'}`, { icon: 'gauge' })}</div>`
    + `${(c.errors ?? []).map((text) => `<p class="ct-msg alert">${glyph('alert')}${esc(text)}</p>`).join('')}`
    + `${(c.warnings ?? []).map((text) => `<p class="ct-msg warn">${glyph('info')}${esc(text)}</p>`).join('')}`
    + `<div class="ct-sections">${[...sections].map(([title, values]) => `<section><h4>${esc(title)}</h4><ul>${values.map((text) => `<li>${esc(text)}</li>`).join('')}</ul></section>`).join('')}</div>`;
}

function previewBody(preview) {
  return surface('pp-preview', `<p>${formatNumber(preview.addedCount)} nouvelle(s) définition(s), ${formatNumber(preview.existingCount)} déjà connue(s). `
    + `Le profil contiendra ${formatNumber(preview.totalCount)} définition(s) sur ${formatNumber(preview.capacity)}.</p>`
    + '<p class="pp-description">L’enregistrement garde les versions existantes. Une modification crée une nouvelle version ; les widgets déjà présents gardent leur sonde. Aucune collecte ne démarre ici.</p>'
    + `${(preview.warnings ?? []).map((text) => `<p class="ct-msg warn">${glyph('info')}${esc(text)}</p>`).join('')}`
    + `<div class="pp-candidates">${(preview.candidates ?? []).map((entry) => `<article class="pp-candidate"><h3>${esc(entry.name)}</h3>`
      + `<p class="pp-description">${esc(entry.category)} · ${entry.existing ? 'Version déjà enregistrée' : 'Nouvelle version'}</p>`
      + contractMarkup(entry.contract)
      + `<details class="pp-fingerprint"><summary>Identité de cette version</summary><p>Identifiant déclaré : <code>${esc(entry.id)}</code></p>`
      + `<p>Empreinte : <code>${esc(entry.fingerprint)}</code></p><p>Clé des widgets : <code>${esc(entry.key)}</code></p></details></article>`).join('')}</div>`);
}

/** The picker only supplies editable text. The backend validates the document and binds its exact preview to apply. */
export function createPersonalProbes(host, { ctx, onApplied = () => {}, isAlive = () => true, chooseFile = importJson }) {
  let disposed = false;
  let busy = false;
  let loading = false;
  let applying = false;
  let catalog = null;
  let choiceValid = false;
  let revision = 0;
  let request = 0;
  let dialog = null;
  const alive = () => !disposed && isAlive();

  host.innerHTML = '<details class="pp-manager"><summary>Sondes personnalisées <span data-personal-count></span></summary><div class="pp-body">'
    + '<p class="cat-lead">Créez une déclaration CIM en lecture seule ou chargez un document JSON. Examinez les droits, le coût et le sens d’une valeur inconnue avant de l’enregistrer dans ce profil.</p>'
    + '<div class="pp-saved" data-personal-saved></div>'
    + '<div class="pp-actions"><button type="button" class="btn sm" data-personal-action="import">Charger un JSON</button>'
    + '<button type="button" class="btn sm ghost" data-personal-action="example">Utiliser l’exemple</button>'
    + '<button type="button" class="btn sm ghost" data-personal-action="reload">Actualiser le catalogue local</button></div>'
    + '<label class="pp-editor-label">Déclaration JSON<textarea class="pp-editor" data-personal-editor rows="16" spellcheck="false" autocomplete="off" autocapitalize="off" placeholder="Collez une déclaration ou utilisez l’exemple à adapter."></textarea></label>'
    + '<p class="pp-description">256 Kio UTF-8 maximum. Les versions existantes sont conservées ; aucun widget n’est réaffecté automatiquement. Enregistrer une sonde ne lance aucune collecte.</p>'
    + '<div class="pp-actions"><button type="button" class="btn sm primary" data-personal-action="preview">Prévisualiser les sondes</button></div>'
    + '<p class="pp-feedback" data-personal-feedback role="status" aria-live="polite"></p></div></details>';
  const editor = host.querySelector('[data-personal-editor]');
  const feedback = host.querySelector('[data-personal-feedback]');

  function message(text, tone = 'info') {
    feedback.textContent = text;
    feedback.dataset.tone = tone;
  }

  function controls() {
    if (!alive()) return;
    for (const button of host.querySelectorAll('button')) {
      button.disabled = busy || loading
        || (button.dataset.personalAction === 'preview' && (!choiceValid || !editor.value.trim()));
    }
    editor.readOnly = applying;
    host.querySelector('.pp-body').setAttribute('aria-busy', String(busy || loading));
  }

  function drawSaved() {
    const entries = catalog?.entries ?? [];
    host.querySelector('[data-personal-count]').textContent = catalog ? `· ${formatNumber(entries.length)} / ${formatNumber(catalog.capacity)}` : '';
    host.querySelector('[data-personal-saved]').innerHTML = catalog
      ? `${catalog.persistent === false ? '<p class="ct-msg warn">Catalogue en mémoire pour cette session ; la persistance sur disque n’est pas confirmée.</p>' : ''}`
        + (entries.length ? `<details class="pp-versions"><summary>Versions déjà enregistrées (${formatNumber(entries.length)})</summary><div class="pp-version-list">${entries.map((entry) => `<article class="pp-version"><h4>${esc(entry.name)}</h4>`
          + `<p class="pp-description">${esc(entry.category)} · Empreinte ${esc(String(entry.fingerprint ?? '').slice(0, 12))}</p>`
          + `<div class="ct-pills">${pill('info', `Droits : ${entry.contract?.privilegeLevel ?? 'Non déclarés'}`, { icon: 'key' })}`
          + `${pill(entry.contract?.costLevel === 'Lourd' ? 'warn' : 'off', `Coût : ${entry.contract?.costLevel ?? 'Non déclaré'}`, { icon: 'gauge' })}</div>`
          + `<button type="button" class="btn sm ghost" data-personal-edit="${esc(entry.key)}">Préparer une nouvelle version</button></article>`).join('')}</div></details>`
        : '<p class="pp-description">Aucune sonde personnalisée enregistrée dans ce profil.</p>')
      : '<p class="pp-description">Catalogue local indisponible. Le document en cours peut rester dans l’éditeur.</p>';
    controls();
  }

  async function reload() {
    if (!alive() || busy || loading) return false;
    loading = true;
    const turn = ++request;
    controls();
    try {
      const value = await ctx.call('accueil.probes.personal');
      if (!alive() || turn !== request) return false;
      catalog = value;
      choiceValid = typeof value?.choiceToken === 'string' && value.choiceToken.length > 0;
      drawSaved();
      message(choiceValid ? 'Catalogue local actualisé. Le document en cours est conservé.' : 'Le catalogue ne fournit pas de choix vérifiable ; l’enregistrement est indisponible.', choiceValid ? 'info' : 'warn');
      return choiceValid;
    } catch (err) {
      if (!alive() || turn !== request) return false;
      choiceValid = false;
      drawSaved();
      message(reported(err), 'warn');
      return false;
    } finally {
      if (alive() && turn === request) { loading = false; controls(); }
    }
  }

  function edit(text, explanation) {
    editor.value = text;
    revision += 1;
    dialog?.close(null);
    message(explanation);
    controls();
    editor.focus();
  }

  async function importDocument() {
    if (!alive() || busy || loading) return;
    busy = true;
    const originalRevision = revision;
    controls();
    try {
      const file = await chooseFile('Charger des sondes personnalisées');
      if (!alive() || !file) return;
      if (revision !== originalRevision) { message('Le document a changé pendant le choix du fichier. Il est conservé ; chargez de nouveau le fichier si nécessaire.', 'warn'); return; }
      if (typeof file.text !== 'string') { message('Le fichier ne contient pas de document JSON lisible.', 'warn'); return; }
      if (!fits(file.text)) { message(sizeMessage, 'warn'); return; }
      edit(file.text, `« ${file.fileName ?? 'Document JSON'} » chargé dans l’éditeur. Prévisualisez son contenu avant de l’enregistrer.`);
    } catch (err) {
      if (alive()) message(reported(err), 'warn');
    } finally {
      if (alive()) { busy = false; controls(); }
    }
  }

  async function preview() {
    if (!alive() || busy || loading || !choiceValid) return;
    const document = editor.value;
    if (!document.trim()) return;
    if (!fits(document)) { message(sizeMessage, 'warn'); return; }
    const originalRevision = revision;
    const expectedChoiceToken = catalog.choiceToken;
    const current = () => alive() && revision === originalRevision && editor.value === document && catalog?.choiceToken === expectedChoiceToken;
    busy = true;
    controls();
    message('Validation locale de la déclaration…');
    try {
      const view = await ctx.call('accueil.probes.preview', { document, expectedChoiceToken });
      if (!current()) return;
      if (view?.choiceToken !== expectedChoiceToken || !/^[a-f0-9]{64}$/i.test(view.documentSha256 ?? '')) {
        choiceValid = false;
        message('L’aperçu ne correspond pas au catalogue consulté. Actualisez le catalogue local et prévisualisez de nouveau le document.', 'warn');
        return;
      }
      const canApply = view.addedCount > 0 && view.candidates?.length > 0 && view.candidates.every((entry) => entry.contract?.valid === true);
      const confirmation = openDialog({
        title: 'Enregistrer les sondes personnalisées', subtitle: 'Catalogue local du profil · aucune collecte', icon: 'file', size: 'lg', body: previewBody(view),
        actions: [{ id: 'cancel', label: 'Revenir à l’éditeur', safe: true }, { id: 'apply', label: 'Enregistrer ces sondes', primary: true, disabled: !canApply }],
      });
      dialog = confirmation;
      const answer = await confirmation.result;
      if (dialog === confirmation) dialog = null;
      if (!current() || answer !== 'apply' || !canApply) {
        if (current()) message(canApply ? 'Aperçu fermé. Le document reste disponible dans l’éditeur.' : 'Toutes les versions sont déjà connues, ou un contrat est incomplet. Aucune écriture effectuée.');
        return;
      }
      applying = true;
      controls();
      message('Enregistrement local du document confirmé…');
      const result = await ctx.call('accueil.probes.apply', { document, expectedChoiceToken, expectedDocumentSha256: view.documentSha256 });
      if (!alive()) return;
      catalog = result?.catalog ?? null;
      choiceValid = typeof catalog?.choiceToken === 'string' && catalog.choiceToken.length > 0;
      drawSaved();
      const confirmed = result?.receipt?.readBack === true && result?.receipt?.persistent === true;
      const receipt = result?.receipt?.text || 'La persistance du catalogue n’a pas été confirmée.';
      message(`${receipt} Choisissez ensuite « Ajouter » dans le catalogue pour créer un widget ; aucune collecte n’a été lancée par cet import.`, confirmed ? 'ok' : 'warn');
      try { await onApplied(catalog); }
      catch (err) {
        if (alive()) message(`${receipt} Le catalogue affiché n’a pas pu être rafraîchi : ${reported(err)} Rouvrez le catalogue pour consulter les sondes enregistrées.`, 'warn');
      }
    } catch (err) {
      if (!alive()) return;
      if (err?.code === 'probes.changed') choiceValid = false;
      message(`${reported(err)}${err?.code === 'probes.changed' ? ' Actualisez le catalogue local puis prévisualisez à nouveau. Le document en cours est conservé.' : ''}`, 'warn');
    } finally {
      if (alive()) { applying = false; busy = false; controls(); }
    }
  }

  const onInput = () => {
    revision += 1;
    dialog?.close(null);
    message('Document modifié. Prévisualisez cette version avant de l’enregistrer.');
    controls();
  };
  const onClick = (event) => {
    const button = event.target instanceof Element ? event.target.closest('button') : null;
    if (!button || button.disabled || !host.contains(button)) return;
    const action = button.dataset.personalAction;
    if (action === 'reload') void reload();
    else if (action === 'import') void importDocument();
    else if (action === 'example') edit(EXAMPLE, 'Exemple à adapter : vérifiez la classe, les propriétés, les droits et les limites de votre sonde. Aucune version n’est enregistrée.');
    else if (action === 'preview') void preview();
    else if (button.dataset.personalEdit) {
      const entry = catalog?.entries?.find((item) => item.key === button.dataset.personalEdit);
      if (entry?.document) edit(entry.document, `Version de « ${entry.name} » chargée. Une modification créera une nouvelle version ; les widgets existants conserveront leur sonde.`);
    }
  };
  editor.addEventListener('input', onInput);
  host.addEventListener('click', onClick);
  const ready = reload();
  return {
    ready, reload,
    destroy() {
      disposed = true;
      request += 1;
      dialog?.close(null);
      dialog = null;
      editor.removeEventListener('input', onInput);
      host.removeEventListener('click', onClick);
    },
  };
}
