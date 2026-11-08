import { openDialog } from '../kit/dialog.js';
import { esc, errorText } from '../ui.js';
import { saveReadingPrefs } from '../pages/parametres/interface.js';

const APPLIED = 'domenia.configuration.interface.applied';
export function applyImportedInterface(result, setPrefs, storage = localStorage) {
  const id = result?.interfaceId ?? result?.id;
  const values = result?.interface ?? result?.values;
  if (!id || !values) return false;
  try { if (storage.getItem(APPLIED) === id) return false; } catch { /* Session can still use the explicitly imported interface. */ }
  setPrefs(values);
  const reading = {};
  if (typeof values.logWrap === 'boolean') reading.logWrap = values.logWrap;
  if ([10, 11, 12, 14, 16, 18].includes(values.logSize)) reading.logSize = values.logSize;
  if (Object.keys(reading).length) saveReadingPrefs(reading);
  try { storage.setItem(APPLIED, id); } catch { /* No persistence is claimed when the private profile cannot persist. */ }
  return true;
}

export function configurationPreviewMarkup(preview) {
  return `<p>${esc(preview.summary ?? '')}</p><p>SHA-256 du texte : <span class="code">${esc(preview.sha256)}</span></p>
    ${preview.changes?.length ? `<table class="pr-table"><thead><tr><th>Réglage</th><th>Avant</th><th>Après</th></tr></thead><tbody>${preview.changes.map(c => `<tr><td>${esc(c.key)}</td><td>${esc(c.before ?? 'Non défini')}</td><td>${esc(c.after)}</td></tr>`).join('')}</tbody></table>` : '<p>Aucune clé métier ne change.</p>'}
    ${preview.interface ? `<p>Interface incluse : ${esc(JSON.stringify(preview.interface))}.</p>` : '<p>Interface actuelle conservée.</p>'}
    <p>Aucune connexion AD, lecture de partage, collecte ni suppression n’est déclenchée par l’import.</p>`;
}

/** Boot and explicit settings entry use the same real server proposal; close is a persisted refusal for this build+SHA. */
export async function proposePackConfiguration(call, setPrefs, notify, alive = () => true) {
  const status = await call('settings.configuration.seed.status');
  if (!alive()) return;
  if (status.problem) { notify(status.problem, { tone: 'warn' }); return; }
  if (status.automaticallyApplied) {
    applyImportedInterface(status.application, setPrefs);
    notify(status.message, { tone: 'ok' }); return;
  }
  if (!status.needsDecision) return;
  const preview = await call('settings.configuration.preview', { text: status.document.text });
  if (!alive()) return;
  const dialog = openDialog({ title: 'Configuration proposée avec cette version', icon: 'sliders', size: 'lg',
    body: `<p>${esc(status.message)}</p><p>Fichier livré : <span class="code">${esc(status.sourceSha256)}</span></p>${configurationPreviewMarkup(preview)}`,
    actions: [{ id: 'decline', label: 'Conserver mes réglages', safe: true }, { id: 'apply', label: 'Sauvegarder et remplacer ces réglages', primary: true }] });
  const answer = await dialog.result;
  if (!alive()) return;
  const result = await call('settings.configuration.seed.decide', { decisionId: status.decisionId, sourceSha256: status.sourceSha256,
    fingerprint: preview.fingerprint, apply: answer === 'apply' });
  if (!alive()) return;
  applyImportedInterface(result, setPrefs);
  notify(result.summary, { tone: result.applied ? 'ok' : 'info' });
}

export async function startConfigurationDefaults(call, setPrefs, notify) {
  try {
    const imported = await call('settings.configuration.interface');
    applyImportedInterface(imported, setPrefs);
    await proposePackConfiguration(call, setPrefs, notify);
  } catch (err) {
    if (err?.code !== 'operation.unknown') notify(`Configuration distribuée non appliquée : ${errorText(err)} Vous pouvez reprendre l’aperçu dans Paramètres, Configuration à diffuser.`, { tone: 'warn' });
  }
}
