// Paramètres in the browser preview (no WebView2 host, no engine): the settings of this screen describe the workstation,
// its local base, its files and its logs, which only the engine can read. Rather than inventing a workstation, the
// preview answers every settings.* operation with an explicit refusal: each card shows its error state with « Réessayer »,
// and the appearance settings (theme, motion, zoom, density), which live in the shell, keep working.
const COLON = ' : ';

/** Refusal of the browser preview, with the code and the shape of a bridge error. */
export async function previewCall(op) {
  const err = new Error(`Aperçu navigateur${COLON}« ${String(op)} » lit ce poste par le moteur de Domenia, absent ici. Ouvrez Domenia.exe pour voir cette partie.`);
  err.code = 'preview.engineRequired';
  throw err;
}
