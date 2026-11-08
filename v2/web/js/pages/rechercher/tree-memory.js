// Layout keys follow ShellInterfaceRules.IsLayoutKey: ASCII punctuation only, at most 100 characters.
// The domain DN belongs in the layout values, never in a key rejected by the engine on every tree gesture.
export async function treeMemoryKey(rootDn) {
  const root = String(rootDn ?? '').trim().toLowerCase();
  if (!root) throw new Error('Domaine absent : mémoire de l’arbre indisponible.');
  const bytes = new TextEncoder().encode(root);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return `rechercher.tree.${Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('')}`;
}
