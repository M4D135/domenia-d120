// Rechercher · back / forward history of the screen (Domenia 1 New-DomeniaNavHistory, D040): 40 places, the same place
// is never stacked twice, a step back restores the list as it was (rows, sort, selection, scroll, filters, column set)
// without any read; the list is then marked « historique, non relue » with « Actualiser ». RCH-043 to RCH-046.

const CAPACITY = 40;
const MAX_ROWS = 5000;
const MAX_SELECTION = 500;

/** Identity of a place: the same text searched « Partout » or « Dans « Postes » », or for another type, is another place. */
export function placeKey(p) {
  const r = p?.request ?? {};
  return [r.op, r.text, r.scope, r.type, r.match, r.dn, r.subtree, r.id, r.verdict, r.wholeDomain].map((v) => String(v ?? '')).join('|');
}

export function createHistory() {
  const st = { back: [], forward: [], current: null };

  const trim = (place) => ({
    ...place,
    result: place.result ? { ...place.result, rows: place.result.rows.slice(0, MAX_ROWS) } : null,
    view: place.view ? { ...place.view, selection: (place.view.selection ?? []).slice(0, MAX_SELECTION) } : {},
  });

  return {
    /** Records where the operator is; repeating the same place only refreshes it. Returns true when a step was added. */
    push(place) {
      const next = trim(place);
      if (st.current && placeKey(st.current) === placeKey(next)) { st.current = next; return false; }
      if (st.current) {
        st.back.push(st.current);
        while (st.back.length > CAPACITY) st.back.shift();
      }
      st.forward = [];
      st.current = next;
      return true;
    },
    /** Keeps the presentation of the current place up to date (selection, scroll, filters, rows appended). */
    update(patch) {
      if (!st.current) return;
      st.current = trim({ ...st.current, ...patch, view: { ...st.current.view, ...(patch.view ?? {}) } });
    },
    /** One step back or forward: the place to restore, or null. Never starts a read by itself. */
    step(direction) {
      const source = direction === 'back' ? st.back : st.forward;
      const target = direction === 'back' ? st.forward : st.back;
      if (!source.length) return null;
      const place = source.pop();
      if (st.current) target.push(st.current);
      st.current = place;
      return place;
    },
    /** Jumps to a place of the list (index in list()). */
    jump(index) {
      const all = [...st.back, ...(st.current ? [st.current] : []), ...[...st.forward].reverse()];
      const place = all[index];
      if (!place) return null;
      const at = st.back.length;
      if (index === at) return null;
      st.back = all.slice(0, index);
      st.current = place;
      st.forward = all.slice(index + 1).reverse();
      return place;
    },
    /** Places for the list of the steps: older first, current marked. */
    list() {
      const all = [...st.back, ...(st.current ? [st.current] : []), ...[...st.forward].reverse()];
      return all.map((p, n) => ({ label: p.label, kind: p.request?.op, current: n === st.back.length, index: n, at: p.at }));
    },
    current: () => st.current,
    canBack: () => st.back.length > 0,
    canForward: () => st.forward.length > 0,
  };
}
