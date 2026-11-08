import { esc, glyph, paint } from './common.js';

const states = new WeakMap();
/** One notice per stable cause; refreshed measurement timestamps do not repeat the announcement. */
export function paintStorageAlert(slot, storage) {
  if (!slot) return;
    const writer = storage?.writer;
    const space = storage?.space;
    // A base proven unreadable: the assistant offers the restore alone, in the tone of an alert.
    const m = storage?.maintenance;
    const unreadable = m?.tone === 'alert' && m.restore && !m.move && !m.resume;
    let html = '';
    if (writer?.canResume) {
      html = `<span class="pr-alert-ico" data-tone="alert">${glyph('alert')}</span><div><b>Enregistrement local suspendu</b><span>${esc(writer.text)}</span></div>
        <button type="button" class="btn sm primary" data-alert-act="writer-resume">${glyph('play')}<span>Reprendre les sauvegardes</span></button>`;
    } else if (unreadable) {
      html = `<span class="pr-alert-ico" data-tone="alert">${glyph('alert')}</span><div><b>Base locale illisible</b><span>${esc(storage.maintenance.text)}</span></div>
        <button type="button" class="btn sm primary" data-alert-go="assistant">${glyph('undo')}<span>Restaurer une sauvegarde…</span></button>`;
    } else if (space?.blocksCollections) {
      html = `<span class="pr-alert-ico" data-tone="warn">${glyph('disk')}</span><div><b>Espace disque ${esc(space.label.toLowerCase())}</b><span>${esc(space.text)}</span></div>
        <button type="button" class="btn sm" data-alert-go="diagnostic">${glyph('gauge')}<span>Voir le diagnostic</span></button>`;
    }
    const key = writer?.canResume ? `writer:${writer.state}:${writer.text}`
      : unreadable ? `unreadable:${m.text}` : space?.blocksCollections ? `space:${space.label}:${space.blocksCollections}` : '';
    if (states.get(slot) === key) return;
    states.set(slot, key);
    slot.hidden = !html;
    slot.innerHTML = html;
    if (html) paint(slot);
}
