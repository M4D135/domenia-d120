// Session prerequisites are UI facts, never an authorization for a directory operation.
export const directoryReady = (session) => ['connected', 'simulated'].includes(session?.connection?.state);
export const sessionContext = (session) => [session?.connection?.state, session?.account?.login,
  session?.domain?.rootDn, session?.controller?.dnsName, session?.scope?.dn, session?.scope?.subtree].join('|');

export function homePrerequisite(session, connecting = false) {
  if (connecting) return { kind: 'connecting', title: 'Connexion en cours', text: 'Le même essai est suivi dans la fenêtre native. Vous pouvez y demander son annulation ; attendez sa fin avant de réessayer.' };
  if (!directoryReady(session)) return { kind: 'disconnected', title: 'Se connecter à l’annuaire', text: 'Ouvrez une session avec votre identité Windows ou choisissez un autre compte. Aucune lecture de l’OU ne part avant votre demande.', action: 'connect', label: 'Se connecter' };
  if (!session.scope) return { kind: 'scope', title: 'Choisissez une OU de travail', text: 'La connexion est établie. Choisissez le périmètre des postes avant la première lecture ; aucune collecte sur tout le domaine ne sera lancée.', action: 'scope', label: 'Choisir l’OU' };
  return null;
}

// Every entry point shares one physical attempt. Cancellation stays owned by the native window.
export function createSessionConnection({ call, onState = () => {}, onSession = () => {} }) {
  let pending = null;
  return {
    running: () => pending !== null,
    connect() {
      if (pending) return pending;
      pending = Promise.resolve().then(() => call('session.connect'))
        .then(() => call('session.info'))
        .then(session => { onSession(session); return session; })
        .finally(() => { pending = null; onState(false); });
      onState(true);
      return pending;
    },
  };
}

// This enables a plan command only. Rights, scope, confirmation and the one-use token are checked by the engine.
export const writePreparationAvailable = session => directoryReady(session) &&
  (session?.writePlanAvailable === true && ['confirmationPerOperation', 'simulation'].includes(session?.writePolicy)
    || session?.writePlanAvailable === undefined && session?.readOnly === false);
