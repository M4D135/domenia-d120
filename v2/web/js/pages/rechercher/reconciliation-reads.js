// A server checkpoint can advance before the page applies its response. Only a completely applied
// response permits the next delta of that same list. Unknown/evicted/new-page lists always reread fully.
export function createReconciliationReads(maximum = 256) {
  const lists = new Map();
  let sequence = 0;
  return {
    begin(listId, wantsIncremental) {
      const incremental = wantsIncremental === true && lists.get(listId)?.accepted === true;
      const ticket = { listId, sequence: ++sequence, incremental };
      lists.delete(listId);
      lists.set(listId, { sequence: ticket.sequence, accepted: false });
      while (lists.size > maximum) lists.delete(lists.keys().next().value);
      return ticket;
    },
    accept(ticket) {
      const current = lists.get(ticket.listId);
      if (!current || current.sequence !== ticket.sequence) return false;
      current.accepted = true;
      return true;
    },
  };
}
