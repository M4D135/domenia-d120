// Common export engine (TRV-054, TRV-055): CSV with semicolons, UTF-8 with BOM, visible columns in their order with French
// headers, formula-like cells neutralized, secret columns withheld and secret-looking text masked by the engine, named
// « Domenia-<OU ou poste>-AAAAMMJJ-HHmm.csv » in the exports folder, never overwritten. With `chooseLocation`, the save mode
// of the embedded picker places the file (local folder, « Remplacer » bound to the file listed; TRV-244). The banner
// announces the rows written and what was masked, with « Ouvrir le dossier ». Imports read a file chosen in the embedded
// picker (delimiter found), from a local folder or from a share listed on request.
import { errorText } from '../ui.js';
import { quietCall, trackedCall } from './store.js';
import { notify } from './notify.js';
import { pickFile } from './pickers.js';

function announceExport(result) {
  notify(result.message, {
    tone: 'ok',
    key: `export|${result.fileName}`,
    folder: result.stored === 'disque' && result.folder?.startsWith('%LOCALAPPDATA%')
      ? () => quietCall('shell.export.open', { fileName: result.fileName }).catch((err) => notify(errorText(err), { tone: 'warn' }))
      : null,
  });
  return result;
}

function fail(err) {
  if (err?.code === 'operation.unknown') {
    notify('Export indisponible dans cet aperçu : il passe par l’application.', { tone: 'info' });
    return null;
  }
  notify(errorText(err, 'Export impossible.'), { tone: 'alert' });
  return null;
}

/**
 * Asks the place of the file when the screen wants it (save mode of the picker), or keeps the exports folder. Resolves
 * { target } (null target: exports folder) or null when the operator cancelled.
 */
async function placeOf(kind, fileName, chooseLocation) {
  if (!chooseLocation) return { target: null };
  const place = await pickFile({ mode: 'save', filter: kind, name: fileName, title: kind === 'json' ? 'Enregistrer le document sous' : 'Enregistrer la liste sous' });
  if (!place) return null;
  return { target: { folder: place.folder, fileName: place.name, replace: place.replace } };
}

/** « Domenia-<sujet>-AAAAMMJJ-HHmm.<ext> » proposed in the save mode (the engine names files the same way). */
export function suggestedFileName(name, kind, at = new Date()) {
  const clean = String(name ?? '').trim().replace(/[^\p{L}\p{Nd}._-]+/gu, '-').replace(/^[-.]+|[-.]+$/g, '').slice(0, 60).replace(/[-.]+$/g, '') || 'export';
  const p = (n) => String(n).padStart(2, '0');
  return `Domenia-${clean}-${at.getFullYear()}${p(at.getMonth() + 1)}${p(at.getDate())}-${p(at.getHours())}${p(at.getMinutes())}.${kind}`;
}

/**
 * Exports a table through the engine.
 * @param {{ name: string, headers: string[], rows: Array<Array<string|number|boolean|null>>, secretColumns?: number[], chooseLocation?: boolean }} o
 */
export async function exportRows(o) {
  try {
    const place = await placeOf('csv', suggestedFileName(o.name, 'csv'), o.chooseLocation);
    if (!place) return null;
    return announceExport(await trackedCall('shell.export.save', { kind: 'csv', name: o.name, headers: o.headers, rows: o.rows, secretColumns: o.secretColumns ?? [], target: place.target }));
  } catch (err) {
    return fail(err);
  }
}

/** Exports a CSV text already built (grid of the kit: grid.toCsv()), read again and written by the rules of the engine. */
export async function exportCsvText(name, text, { chooseLocation = false } = {}) {
  try {
    const clean = String(text ?? '').replace(/^﻿/, '');
    const place = await placeOf('csv', suggestedFileName(name, 'csv'), chooseLocation);
    if (!place) return null;
    return announceExport(await trackedCall('shell.export.save', { kind: 'csv', name, text: clean, target: place.target }));
  } catch (err) {
    return fail(err);
  }
}

/** Exports a JSON document (board layout, settings). */
export async function exportJson(name, value, { chooseLocation = false } = {}) {
  try {
    const place = await placeOf('json', suggestedFileName(name, 'json'), chooseLocation);
    if (!place) return null;
    return announceExport(await trackedCall('shell.export.save', { kind: 'json', name, text: JSON.stringify(value, null, 2), target: place.target }));
  } catch (err) {
    return fail(err);
  }
}

/** Adapter for the grid of the kit: createGrid(host, { onExport: gridExporter('OU Postes') }). */
export function gridExporter(name, options) {
  return (csv) => exportCsvText(name, csv, options);
}

function readChosen(file, kind) {
  return trackedCall(file.share ? 'shell.files.shareRead' : 'shell.files.read', { path: file.path, kind });
}

/** Lets the operator choose a CSV file and reads it (delimiter found). Resolves { fileName, delimiter, headers, rows, total, truncated } or null. */
export async function importCsv(title = 'Importer un fichier CSV') {
  const file = await pickFile({ filter: 'csv', title });
  if (!file) return null;
  try {
    return await readChosen(file, 'csv');
  } catch (err) {
    notify(errorText(err), { tone: 'warn' });
    return null;
  }
}

/** Lets the operator choose a JSON file and reads it (1 MB at most). Resolves { fileName, text } or null. */
export async function importJson(title = 'Importer un fichier JSON') {
  const file = await pickFile({ filter: 'json', title });
  if (!file) return null;
  try {
    return await readChosen(file, 'json');
  } catch (err) {
    notify(errorText(err), { tone: 'warn' });
    return null;
  }
}
