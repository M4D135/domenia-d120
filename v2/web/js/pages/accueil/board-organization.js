/** Sections remain the ordered groups of real widgets: the existing preference history is sufficient. */
export const sectionName = item => item.group || 'Autres widgets';

export function sectionsOf(items) {
  const groups = new Map();
  for (const item of items) {
    const name = sectionName(item);
    if (!groups.has(name)) groups.set(name, []);
    groups.get(name).push(item);
  }
  return [...groups].map(([name, widgets]) => ({ name, items: widgets }));
}

export function placeWidget(items, id, section, beforeId = null) {
  const item = items.find(value => value.id === id);
  if (!item || beforeId === id) return items;
  // Keep the destination's position even when its only card is the one being moved.
  const groups = sectionsOf(items);
  for (const group of groups) group.items = group.items.filter(value => value.id !== id);
  let target = groups.find(group => group.name === section);
  if (!target) { target = { name: section, items: [] }; groups.push(target); }
  const at = target.items.findIndex(value => value.id === beforeId);
  target.items.splice(at < 0 ? target.items.length : at, 0, { ...item, group: section });
  return groups.flatMap(group => group.items);
}

export function moveSection(items, name, delta) {
  const groups = sectionsOf(items);
  const from = groups.findIndex(group => group.name === name); const to = from + delta;
  if (from < 0 || to < 0 || to >= groups.length) return items;
  const [group] = groups.splice(from, 1); groups.splice(to, 0, group);
  return groups.flatMap(value => value.items);
}

export function renameSection(items, name, next) {
  if (!next || next === name || sectionsOf(items).some(group => group.name === next)) return items;
  return sectionsOf(items).flatMap(group => group.items.map(item => group.name === name ? { ...item, group: next } : item));
}
