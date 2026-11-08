// A local durable-receipt check, never a network verification or an implicit retry.
export async function consultationAllowed(call, notify) {
  try {
    const state = await call('write.receipts.list');
    if (!state || typeof state.inFlight !== "boolean" || !Number.isSafeInteger(state.pending) || state.pending < 0 || !Number.isSafeInteger(state.unreadable) || state.unreadable < 0 || state.inFlight || state.pending > 0 || state.unreadable > 0) {
      notify('Une écriture est en cours ou reste à vérifier. Ouvrez son reçu dans Opérations avant de continuer.', { tone: 'warn' });
      return false;
    }
    return true;
  } catch {
    notify('Les reçus ne peuvent pas être vérifiés. Ouvrez Opérations avant de continuer.', { tone: 'warn' });
    return false;
  }
}

export function consultationIdentity(session) {
  return JSON.stringify([session?.domain?.rootDn ?? '', session?.account?.login ?? '', session?.epoch ?? 0,
    session?.storeId ?? null, session?.accessSelectionVersion ?? 0, session?.machineAccountGeneration ?? 0]);
}
