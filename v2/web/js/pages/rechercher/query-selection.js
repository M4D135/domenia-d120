// The workshop selection is a dated GUID filter, not a name/DN lookup. An explicit empty selection matches nothing.
const guid = (value) => {
  const text = String(value ?? '').replace(/^\{(.+)\}$/, '$1').toLowerCase();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(text) ? text : null;
};
export function prepareQuerySelection(selection, rootDn) {
  if (selection == null) return null;
  if (selection.target !== 'computer' || String(selection.rootDn).toLowerCase() !== String(rootDn).toLowerCase()
      || !/^[0-9a-f]{64}$/.test(selection.fingerprint ?? '') || !Array.isArray(selection.ids) || selection.ids.length > 20000)
    throw new Error('Sélection de requête incompatible avec ce domaine.');
  const ids = new Set(selection.ids.map(guid));
  if (ids.has(null)) throw new Error('Identité invalide dans la sélection de requête.');
  return { ...selection, ids };
}
export function filterQuerySelection(rows, selection) {
  return selection === null ? rows : rows.filter((row) => row.kind === 'computer' && selection.ids.has(guid(row.id)));
}
