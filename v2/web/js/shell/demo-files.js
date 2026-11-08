// The isolated demo never opens a real browser file picker or lets a page read dropped local files.
// Its explicit import path is the host picker, whose roots are the private fictitious exports.
export function protectDemoFiles(info, tell, root = document) {
  const blocked = () => !info() || info().modeReason === 'demonstration';
  const refuse = (event) => {
    event.preventDefault(); event.stopImmediatePropagation();
    tell('Démonstration — choisissez un export fictif dans le sélecteur de Domenia ; aucun fichier réel n’est lu.');
  };
  const input = event => {
    if (!blocked()) return;
    const node = event.target instanceof Element ? event.target.closest('input[type="file"]') : null;
    if (!node) return;
    if (event.type === 'change') node.value = '';
    refuse(event);
  };
  const transferred = event => {
    if (!blocked()) return;
    const data = event.dataTransfer ?? event.clipboardData;
    if (data?.files?.length || [...(data?.items ?? [])].some(item => item.kind === 'file')) refuse(event);
  };
  root.addEventListener('click', input, true);
  root.addEventListener('change', input, true);
  root.addEventListener('drop', transferred, true);
  root.addEventListener('paste', transferred, true);
  return () => {
    root.removeEventListener('click', input, true);
    root.removeEventListener('change', input, true);
    root.removeEventListener('drop', transferred, true);
    root.removeEventListener('paste', transferred, true);
  };
}
