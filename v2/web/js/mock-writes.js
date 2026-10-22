// Browser preview of the write circuit (docs/OPERATIONS.md § 12, docs/WRITES.md): same operations, result shapes, error
// codes and texts as the engine (WriteCircuit, WriteReceipts, AccountUnlock, SimulatedAccountUnlockExecutor), on two
// accounts of the fictitious example.local directory. Plans, tokens, receipts and the overlay live in the memory of the
// page: nothing leaves it, nothing is kept after a reload (the engine keeps its receipts in receipts-simulation.jsonl).
// The helpers of mock.js are handed in, so validation messages stay word for word those of the engine.

const MIN = 60_000;
const LIFETIME = 5 * MIN;
const FILETIME_EPOCH_MS = 11_644_473_600_000;
const STAGE_PAUSE = 260;

/**
 * @param {object} h  Helpers of mock.js: readObject, getString, getOptionalString, requireDistinguishedName, requireNone,
 *   invalid, fail, quote, int, sleep, log, NBSP, REF.
 * @returns {Object<string, (args: any) => any>}
 */
export function createWriteOperations(h) {
  const { readObject, getString, getOptionalString, requireDistinguishedName, requireNone, invalid, fail, quote, int, sleep, log, NBSP, REF } = h;
  const COLON = `${NBSP}: `;
  const iso = (t) => new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const second = (t) => Math.floor(t / 1000) * 1000;
  const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
  const random = (n) => crypto.getRandomValues(new Uint8Array(n));
  const newId = () => hex(random(16));
  const newToken = () => btoa(String.fromCharCode(...random(32))).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
  const fileTime = (t) => String((BigInt(t) + BigInt(FILETIME_EPOCH_MS)) * 10000n);
  const pad = (n) => String(n).padStart(2, '0');
  const local = (t, timeOnly = false) => {
    const d = new Date(t);
    const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    return timeOnly ? time : `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()} à ${time}`;
  };
  const isId = (v) => typeof v === 'string' && /^[0-9a-f]{32}$/.test(v);
  const isToken = (v) => typeof v === 'string' && /^[A-Za-z0-9_-]{43}$/.test(v);
  const keyOf = (dn) => String(dn).toLowerCase();
  const CONTROLLER = 'DC01.example.local';
  const OPERATOR = 'EXAMPLE\\adm-j.martin';

  // Accounts of the preview; the overlay is this array itself (memory of the page).
  const accounts = [
    { name: 'Camille Bernard', sam: 'c.bernard', guid: '6f1c2b7e-9a43-4d1e-8c55-2b7d90e4a1c3',
      dn: 'CN=Camille Bernard,OU=Commercial,OU=Lyon,OU=Utilisateurs,DC=example,DC=local', lockedAt: REF - 18 * MIN, bad: 5 },
    { name: 'Julien Martin', sam: 'j.martin', guid: '0a5e3d21-7c84-4f92-b1a6-5d3e8f20c7b4',
      dn: 'CN=Julien Martin,OU=Informatique,OU=Paris,OU=Utilisateurs,DC=example,DC=local', lockedAt: null, bad: 0 },
  ];
  const plans = new Map(); // id → { plan, token, used }
  const receipts = new Map(); // id → receipt (engine shape of write.receipts.get)
  let busy = Promise.resolve();

  const byDn = (dn) => accounts.find((a) => keyOf(a.dn) === keyOf(dn)) ?? null;
  const byGuid = (guid) => accounts.find((a) => a.guid === guid) ?? null;

  async function fingerprint(plan) {
    const text = JSON.stringify([plan.id, plan.kind, plan.target.dn, plan.target.objectGuid, plan.controller, plan.operator,
      plan.mode, plan.createdAt, plan.expiresAt, plan.changes.map((c) => [c.attribute, c.kind, c.beforeValue, c.afterValue])]);
    if (crypto.subtle) return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))));
    return hex(random(32));
  }

  function details(plan) {
    return [
      `Opération${COLON}${plan.kind}`,
      `Cible${COLON}${plan.target.kindLabel} ${plan.target.name}`,
      `DN${COLON}${plan.target.dn}`,
      `GUID${COLON}${plan.target.objectGuid}`,
      `Compte${COLON}${plan.target.samAccountName}`,
      `Contrôleur${COLON}${plan.controller}`,
      `Opérateur${COLON}${plan.operator}`,
      `Mode${COLON}simulation (annuaire fictif en mémoire, aucun effet réel)`,
      ...plan.changes.map((c) => `Changement${COLON}${c.attribute} (remise à zéro)${COLON}${c.beforeValue} → ${c.afterValue}`),
      `Préparé le${COLON}${local(Date.parse(plan.createdAt))} · valable jusqu’à ${local(Date.parse(plan.expiresAt), true)}`,
      `Empreinte du plan${COLON}${plan.fingerprint.slice(0, 12)}`,
    ].join('\n');
  }

  // accounts.unlock.plan (AccountUnlock.Draft, WriteCircuit.PlanAsync).
  async function unlockPlan(args) {
    const dn = requireDistinguishedName(getString(readObject(args, ['dn']), 'dn'), 'dn');
    await sleep(160);
    const account = byDn(dn);
    if (!account) throw fail('write.targetUnknown', `Ce nom distinctif ne désigne aucun compte utilisateur de l’annuaire fictif${COLON}aucune écriture préparée.`);
    if (!account.lockedAt) throw fail('write.nothingToDo', `Ce compte n’est pas verrouillé${COLON}aucune écriture à préparer.`);
    if ([...receipts.values()].some((r) => r.pending && r.target.objectGuid === account.guid)) {
      throw fail('write.targetPending', `Une écriture précédente sur cet objet reste à vérifier${COLON}relisez son reçu dans Opérations avant d’en préparer une autre.`);
    }
    const now = second(Date.now());
    const plan = {
      id: newId(),
      kind: 'account.unlock',
      title: 'Déverrouiller le compte',
      label: 'Déverrouillage du compte',
      summary: `${account.name} pourra de nouveau ouvrir une session${COLON}lockoutTime remis à zéro sur ${CONTROLLER}.`,
      target: { kind: 'user', kindLabel: 'Compte utilisateur', name: account.name, dn: account.dn, objectGuid: account.guid, samAccountName: account.sam },
      changes: [{ attribute: 'lockoutTime', label: 'Verrouillage', kind: 'clear', before: `Verrouillé depuis le ${local(account.lockedAt)}`, after: 'Déverrouillé', beforeValue: fileTime(account.lockedAt), afterValue: '0' }],
      risks: [
        { tone: 'warn', text: `Vérifiez l’identité du demandeur${COLON}un verrouillage (${int(account.bad)} essais erronés) peut aussi venir d’une tentative d’intrusion ou d’un ancien mot de passe enregistré sur un poste.` },
        { tone: 'info', text: `Le contrôleur remet aussi à zéro le compteur d’essais erronés (${int(account.bad)}).` },
      ],
      confirmation: { typedNameRequired: false, typedName: null, reason: `Confirmation simple${COLON}compte standard${NBSP}; ni droit ni mot de passe modifié.` },
      reversibility: { reversible: false, label: 'Sans retour arrière', detail: `Un déverrouillage ne se défait pas${COLON}le compte ne se verrouille de nouveau qu’après de nouveaux essais erronés. Aucune compensation n’est proposée, comme dans Domenia 1.` },
      controller: CONTROLLER,
      operator: OPERATOR,
      mode: 'simulation',
      simulated: true,
      createdAt: iso(now),
      expiresAt: iso(now + LIFETIME),
      fingerprint: '',
      details: '',
    };
    plan.fingerprint = await fingerprint(plan);
    plan.details = details(plan);
    const token = newToken();
    plans.set(plan.id, { plan, token, used: false });
    return { plan, token };
  }

  function view(receipt) {
    const { pending, result, verification, simulated } = receipt;
    const resultLabel = { sent: 'Envoyée, issue à vérifier', applied: simulated ? 'Appliquée (simulation)' : 'Appliquée', noChange: `Déjà faite${COLON}rien envoyé`, notApplied: 'Non appliquée', unknown: 'Issue inconnue, à vérifier' }[result];
    const verificationLabel = verification === 'verified' ? 'Vérifiée par relecture'
      : verification === 'mismatch' ? (result === 'notApplied' ? `Relue${COLON}objet inchangé` : 'Écart à la relecture')
        : result === 'sent' ? 'Relecture en attente' : 'Non vérifiée';
    const note = simulated ? ` Simulation${COLON}annuaire fictif en mémoire, aucun effet réel.` : '';
    let summary;
    let tone;
    if (pending) {
      summary = `Issue inconnue après l’envoi${COLON}vérifiez par une relecture. Rien n’est renvoyé automatiquement. Les nouvelles écritures sur cet objet restent bloquées jusqu’à la vérification.`;
      tone = 'warn';
    } else if (result === 'applied' && verification === 'verified') {
      summary = `Écriture appliquée et vérifiée par relecture.${note}`; tone = 'ok';
    } else if (result === 'applied' && verification === 'mismatch') {
      summary = `Écriture acceptée, mais la relecture montre un autre état${COLON}vérifiez l’objet avant toute nouvelle écriture. Rien n’est renvoyé automatiquement.${note}`; tone = 'alert';
    } else if (result === 'noChange') {
      summary = `L’objet était déjà dans l’état demandé${COLON}rien n’a été envoyé.`; tone = verification === 'verified' ? 'ok' : 'warn';
    } else {
      summary = `Écriture acceptée, relecture impossible${COLON}relisez ce reçu depuis Opérations pour la vérifier.${note}`; tone = 'warn';
    }
    return { ...receipt, resultLabel: resultLabel ?? result, verificationLabel, summary, tone };
  }

  function row(receipt) {
    const { details: _d, plan: _p, ...rest } = receipt;
    return rest;
  }

  // write.execute (WriteCircuit.ExecuteAsync): token, typed name, preconditions, receipt, write, re-read.
  async function execute(args) {
    const values = readObject(args, ['planId', 'token', 'typedName']);
    const planId = getString(values, 'planId');
    if (!isId(planId)) throw invalid(`${quote('planId')} doit être un identifiant de plan (32 caractères hexadécimaux).`);
    const token = getString(values, 'token');
    if (!isToken(token)) throw invalid(`${quote('token')} doit être un jeton de confirmation.`);
    const typedName = getOptionalString(values, 'typedName');
    if (typedName !== null && typedName.length > 256) throw invalid(`${quote('typedName')} doit faire au plus 256 caractères.`);
    const entry = plans.get(planId);
    if (!entry) throw fail('write.planUnknown', `Plan d’écriture inconnu ou expiré${COLON}rien n’a été envoyé. Préparez de nouveau l’écriture.`);
    if (entry.used) throw fail('write.tokenUsed', `Ce plan a déjà servi${COLON}une écriture ne part qu’une fois et n’est jamais rejouée. Préparez de nouveau l’écriture si besoin.`);
    if (entry.token !== token) throw fail('write.tokenInvalid', `Jeton de confirmation refusé${COLON}rien n’a été envoyé. Préparez de nouveau l’écriture.`);
    if (Date.now() >= Date.parse(entry.plan.expiresAt)) {
      throw fail('write.tokenExpired', `Confirmation expirée (plan de plus de 5${NBSP}min)${COLON}rien n’a été envoyé. Préparez de nouveau l’écriture pour relire l’objet.`);
    }
    entry.used = true;
    const turn = busy.then(() => run(entry.plan));
    busy = turn.catch(() => {});
    return turn;
  }

  async function run(plan) {
    const account = byGuid(plan.target.objectGuid);
    await sleep(STAGE_PAUSE);
    if (!account) throw fail('write.stale', `Le compte n’existe plus dans l’annuaire${COLON}rien n’a été envoyé.`);
    const already = !account.lockedAt;
    if (!already && fileTime(account.lockedAt) !== plan.changes[0].beforeValue) {
      throw fail('write.stale', `Le compte a été verrouillé de nouveau depuis le plan${COLON}relisez-le puis préparez de nouveau l’écriture. Rien n’a été envoyé.`);
    }
    const sentAt = iso(second(Date.now()));
    const detailsList = [{ label: 'Préconditions', value: already ? `Compte relu${COLON}déjà déverrouillé, rien ne sera écrit.` : `Compte relu sur ${CONTROLLER}${COLON}toujours verrouillé, DN et GUID inchangés.` }];
    await sleep(STAGE_PAUSE * 2);
    if (!already) { account.lockedAt = null; account.bad = 0; }
    detailsList.push({ label: 'Envoi', value: already ? `Compte déjà déverrouillé${COLON}aucune écriture.` : `lockoutTime remis à zéro dans l’annuaire fictif (en mémoire, aucun effet réel), comme le ferait ${CONTROLLER}.` });
    const completedAt = iso(second(Date.now()));
    await sleep(STAGE_PAUSE);
    detailsList.push({ label: 'Relecture', value: `lockoutTime = 0 relu sur ${CONTROLLER}${COLON}compte déverrouillé.` });
    const at = iso(second(Date.now()));
    const receipt = view({
      id: newId(), kind: plan.kind, title: plan.title, label: plan.label, target: plan.target,
      at, sentAt, completedAt, verifiedAt: at, operator: plan.operator, controller: plan.controller, mode: plan.mode, simulated: true,
      result: already ? 'noChange' : 'applied', verification: 'verified', pending: false, error: null, details: detailsList, plan,
    });
    receipts.set(receipt.id, receipt);
    log(`${plan.label} (simulation)${COLON}${plan.target.name} · ${already ? 'déjà dans l’état demandé' : 'relecture conforme'}`, 'ok', Date.now());
    return receipt;
  }

  function sorted() {
    return [...receipts.values()].sort((a, b) => Number(b.pending) - Number(a.pending) || (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
  }

  function list(args) {
    requireNone(args);
    const all = sorted();
    const pending = all.filter((r) => r.pending).length;
    const total = all.length;
    let summary;
    if (pending === 1) summary = `Une écriture reste à vérifier${COLON}les nouvelles écritures sur son objet sont bloquées jusqu’à sa relecture. Rien n’est renvoyé automatiquement.`;
    else if (pending > 1) summary = `${int(pending)} écritures restent à vérifier${COLON}les nouvelles écritures sur leurs objets sont bloquées jusqu’à leur relecture. Rien n’est renvoyé automatiquement.`;
    else if (total === 0) summary = 'Aucun reçu d’écriture. Rien n’est renvoyé automatiquement.';
    else if (total === 1) summary = `Aucune écriture à vérifier. Un reçu conservé${NBSP}; rien n’est renvoyé automatiquement.`;
    else summary = `Aucune écriture à vérifier. ${int(total)} reçus conservés${NBSP}; rien n’est renvoyé automatiquement.`;
    return { total, pending, unreadable: 0, truncated: false, summary, receipts: all.map(row) };
  }

  function receiptId(args) {
    const id = getString(readObject(args, ['id']), 'id');
    if (!isId(id)) throw invalid(`${quote('id')} doit être un identifiant de reçu (32 caractères hexadécimaux).`);
    const receipt = receipts.get(id);
    if (!receipt) throw fail('receipt.unknown', `Reçu introuvable${COLON}rien n’a été lu.`);
    return receipt;
  }

  function get(args) {
    return receiptId(args);
  }

  // write.receipts.verify: a read of the account, a new version of the receipt; the write is never sent again.
  async function verify(args) {
    const receipt = receiptId(args);
    await sleep(220);
    const account = byGuid(receipt.target.objectGuid);
    const unlocked = account && !account.lockedAt;
    const at = iso(second(Date.now()));
    const next = view({
      ...receipt,
      at,
      verifiedAt: at,
      verification: account ? (unlocked ? 'verified' : 'mismatch') : 'unknown',
      pending: false,
      details: [...receipt.details, { label: 'Relecture', value: unlocked ? `lockoutTime = 0 relu sur ${CONTROLLER}${COLON}compte déverrouillé.` : `Le compte est encore verrouillé à la relecture sur ${CONTROLLER}.` }],
    });
    receipts.set(next.id, next);
    log(`Relecture du reçu${COLON}${next.label} · ${next.target.name} · ${unlocked ? 'relecture conforme' : 'écart à la relecture'}`, next.tone, Date.now());
    return next;
  }

  return {
    'accounts.unlock.plan': unlockPlan,
    'write.execute': execute,
    'write.receipts.list': list,
    'write.receipts.get': get,
    'write.receipts.verify': verify,
  };
}
