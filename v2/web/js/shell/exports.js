// Common export engine (TRV-054, TRV-055): CSV with semicolons, UTF-8 with BOM, visible columns in their order with French
// headers, formula-like cells neutralized, secret columns withheld and secret-looking text masked by the engine, named
// « Domenia-<OU ou poste>-AAAAMMJJ-HHmm.csv » in the exports folder, never overwritten. The banner announces the rows
// written and what was masked, with « Ouvrir le dossier ». Imports read a file chosen in the embedded picker (delimiter found).
import { errorText } from '../ui.js';
import { quietCall, trackedCall } from './store.js';
import { notify } from './notify.js';
import { pickFile } from './pickers.js';

function announceExport(result) {
  notify(result.message, {
    tone: 'ok',
    key: `export|${result.fileName}`,
    folder: result.stored === 'disque' ? () => quietCall('shell.export.open', { fileName: result.fileName }).catch((err) => notify(errorText(err), { tone: 'warn' })) : null,
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
 * Exports a table through the engine.
 * @param {{ name: string, headers: string[], rows: Array<Array<string|number|boolean|null>>, secretColumns?: number[] }} o
 */
export async function exportRows(o) {
  try {
    return announceExport(await trackedCall('shell.export.save', { kind: 'csv', name: o.name, headers: o.headers, rows: o.rows, secretColumns: o.secretColumns ?? [] }));
  } catch (err) {
    return fail(err);
  }
}

/** Exports a CSV text already built (grid of the kit: grid.toCsv()), masked again by the engine. */
export async function exportCsvText(name, text) {
  try {
    const clean = String(text ?? '').replace(/^\uFEFF/, '');
    return announceExport(await trackedCall('shell.export.save', { kind: 'csv', name, text: clean }));
  } catch (err) {
    return fail(err);
  }
}

/** Exports a JSON document (board layout, settings). */
export async function exportJson(name, value) {
  try {
    return announceExport(await trackedCall('shell.export.save', { kind: 'json', name, text: JSON.stringify(value, null, 2) }));
  } catch (err) {
    return fail(err);
  }
}

/** Adapter for the grid of the kit: createGrid(host, { onExport: gridExporter('OU Postes') }). */
export function gridExporter(name) {
  return (csv) => exportCsvText(name, csv);
}

/** Lets the operator choose a CSV file and reads it (delimiter found). Resolves { fileName, delimiter, headers, rows, total, truncated } or null. */
export async function importCsv(title = 'Importer un fichier CSV') {
  const file = await pickFile({ filter: 'csv', title });
  if (!file) return null;
  try {
    return await trackedCall('shell.files.read', { path: file.path, kind: 'csv' });
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
    return await trackedCall('shell.files.read', { path: file.path, kind: 'json' });
  } catch (err) {
    notify(errorText(err), { tone: 'warn' });
    return null;
  }
}
