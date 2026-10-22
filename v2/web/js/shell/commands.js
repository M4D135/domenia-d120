// Command catalogue of the palette (TRV-175, TRV-176; Domenia 1 Get-DomeniaCommandCatalogue, Get-DomeniaPaletteEntries,
// Select-DomeniaPaletteEntries, Get-DomeniaPaletteDecision). Every command is judged against the context (connection,
// selection, object type, read-only, the real state of its button). The palette never writes: a prepared write or a
// protected read only brings its button forward; a read clicks an enabled button; shell actions run directly.
// Screens tag their buttons with data-command="<id>" and may add their own commands (ctx.commands.set).

/** What Entrée does, in the words of the palette. */
export const EFFECT_TEXTS = Object.freeze({
  navigate: 'Ouvre la vue ; rien n’est lu.',
  local: 'Action locale à ce poste ; rien n’est envoyé.',
  read: 'Lecture lancée par Entrée ; aucune écriture.',
  sensitive: 'Amène le bouton à l’écran : la lecture protégée part seulement après votre clic.',
  write: 'Amène le bouton à l’écran : rien n’est écrit sans sa propre confirmation.',
});

const TYPE_LABELS = { user: 'un utilisateur', computer: 'un poste', group: 'un groupe' };

// [id, label, keywords, group, effect, requires, needsConnection, shortcut, route]
const ROWS = [
  ['search', 'Rechercher dans Active Directory', 'trouver nom compte poste', 'Navigation', 'navigate', '', false, 'search', 'rechercher'],
  ['dashboard', 'Ouvrir l’accueil', 'tableau de bord parc', 'Navigation', 'navigate', '', false, 'dashboard', 'accueil'],
  ['operations', 'Afficher les opérations en cours', 'tâches suivi lenteur santé reçus', 'Navigation', 'local', '', false, '', ''],
  ['journal', 'Ouvrir le journal de la session', 'log erreurs historique notifications', 'Navigation', 'local', '', false, 'journal', ''],
  ['index', 'Ouvrir l’index local', 'base locale cache stockage', 'Navigation', 'navigate', '', false, 'index', 'parametres?section=stockage'],
  ['queries', 'Ouvrir l’atelier de requêtes', 'requête filtre parc', 'Navigation', 'navigate', '', false, '', 'requetes'],
  ['accounts', 'Ouvrir Comptes et accès', 'identité compte secondaire laps bitlocker', 'Navigation', 'navigate', '', false, '', 'comptes'],
  ['relations', 'Ouvrir les relations utilisateur et poste', 'association lien poste utilisateur', 'Navigation', 'navigate', '', false, '', 'relations'],
  ['tools', 'Ouvrir l’aide', 'aide outils paramètres', 'Navigation', 'local', '', false, 'help', ''],
  ['shortcuts', 'Afficher les raccourcis clavier', 'clavier touches aide mémoire', 'Aide', 'local', '', false, 'shortcuts', ''],
  ['theme', 'Changer de thème clair ou sombre', 'sombre clair couleurs', 'Présentation', 'local', '', false, 'theme', ''],
  ['undo', 'Annuler la dernière présentation de la liste', 'colonnes tri filtre retour', 'Présentation', 'local', '', false, '', ''],
  ['summary', 'Copier le résumé de l’objet', 'presse-papiers fiche', 'Objet ouvert', 'local', 'selection', false, 'summary', ''],
  ['parent', 'Ouvrir le conteneur parent', 'ou dossier parent', 'Objet ouvert', 'navigate', 'selection', true, '', ''],
  ['reread', 'Relire l’objet depuis l’annuaire', 'actualiser rafraîchir fiche contrôleur', 'Objet ouvert', 'read', 'selection', true, '', ''],
  ['diagnostic', 'Préparer le diagnostic expurgé', 'support export versions mesures', 'Application', 'navigate', '', false, '', 'assistance?onglet=dossier'],
  ['selfcheck', 'Vérifier l’application', 'auto-vérification prérequis compatibilité', 'Application', 'local', '', false, '', ''],
  ['tree', 'Actualiser l’arborescence', 'ou arbre recharger', 'Lecture', 'read', '', true, 'refresh', ''],
  ['batch', 'Diagnostic réseau des postes sélectionnés', 'ping ports smb winrm', 'Lecture', 'read', 'machineRows', true, '', ''],
  ['ping', 'Pinger ce poste', 'réseau joignable', 'Lecture', 'read', 'computer', true, '', ''],
  ['sessions', 'Lire les sessions du poste', 'utilisateur connecté rdp', 'Lecture', 'read', 'computer', true, '', ''],
  ['computerdiag', 'Lancer le diagnostic du poste', 'santé disque services', 'Lecture', 'read', 'computer', true, '', ''],
  ['inventory', 'Lancer l’inventaire rapide du poste', 'matériel wmi', 'Lecture', 'read', 'computer', true, '', ''],
  ['software', 'Charger les logiciels du poste', 'applications installées', 'Lecture', 'read', 'computer', true, '', ''],
  ['lastuser', 'Détecter l’utilisateur du poste', 'session utilisateur', 'Lecture', 'read', 'computer', true, '', ''],
  ['lockouts', 'Lire les verrouillages du compte (4740)', 'verrouillage événement sécurité', 'Lecture', 'read', 'user', true, '', ''],
  ['permissions', 'Analyser les permissions de l’objet', 'acl droits sécurité', 'Lecture', 'read', 'selection', true, '', ''],
  ['laps', 'Lire le mot de passe LAPS', 'administrateur local secret', 'Lecture protégée', 'sensitive', 'computer', true, '', ''],
  ['bitlocker', 'Lire les clés BitLocker', 'récupération secret', 'Lecture protégée', 'sensitive', 'computer', true, '', ''],
  ['useredit', 'Modifier la fiche de l’utilisateur', 'éditer champs', 'Écriture préparée', 'write', 'user', true, '', ''],
  ['unlock', 'Déverrouiller le compte', 'verrouillé débloquer', 'Écriture préparée', 'write', 'user', true, '', ''],
  ['resetpassword', 'Réinitialiser le mot de passe', 'mot de passe changer', 'Écriture préparée', 'write', 'user', true, '', ''],
  ['userenable', 'Activer le compte', 'activer utilisateur', 'Écriture préparée', 'write', 'user', true, '', ''],
  ['userdisable', 'Désactiver le compte', 'désactiver utilisateur', 'Écriture préparée', 'write', 'user', true, '', ''],
  ['usermove', 'Déplacer l’utilisateur', 'ou déplacer', 'Écriture préparée', 'write', 'user', true, '', ''],
  ['useraddgroup', 'Ajouter l’utilisateur à un groupe', 'groupe membre', 'Écriture préparée', 'write', 'user', true, '', ''],
  ['groupadd', 'Ajouter un membre au groupe', 'groupe membre', 'Écriture préparée', 'write', 'group', true, '', ''],
  ['groupremove', 'Retirer un membre du groupe', 'groupe membre', 'Écriture préparée', 'write', 'group', true, '', ''],
  ['computeredit', 'Modifier la fiche du poste', 'description emplacement', 'Écriture préparée', 'write', 'computer', true, '', ''],
  ['computerenable', 'Activer le poste', 'activer ordinateur', 'Écriture préparée', 'write', 'computer', true, '', ''],
  ['computerdisable', 'Désactiver le poste', 'désactiver ordinateur', 'Écriture préparée', 'write', 'computer', true, '', ''],
  ['computermove', 'Déplacer le poste dans une autre OU', 'ou déplacer ordinateur', 'Écriture préparée', 'write', 'computer', true, '', ''],
  ['gpupdate', 'Actualiser les stratégies du poste', 'gpupdate gpo', 'Écriture préparée', 'write', 'computer', true, '', ''],
  ['restart', 'Redémarrer le poste', 'redémarrage reboot', 'Écriture préparée', 'write', 'computer', true, '', ''],
];

/** The closed catalogue of Domenia 1 (44 commands), in its order. */
export const CATALOGUE = Object.freeze(ROWS.map(([id, label, keywords, group, effect, requires, needsConnection, shortcut, route], n) =>
  Object.freeze({ id, label, keywords, group, effect, requires, needsConnection, shortcut, route, order: n + 1, catalogue: true })));

/** Case, accents and apostrophes folded: « detecter » finds « Détecter », « lindex » finds « l’index ». */
export function searchKey(text) {
  return String(text ?? '').toLowerCase().normalize('NFD').replace(/\p{Diacritic}/gu, '')
    .replace(/['’ʼ]/g, '').replace(/[^a-z0-9]+/g, ' ').trim();
}

/**
 * Judges a command against the context (Domenia 1 Get-DomeniaPaletteEntries).
 * @param {object} c command
 * @param {{ connected: boolean, selectionType: string, machineRows: number, readOnly: boolean, simulation: boolean,
 *   control?: (id: string) => { reachable: boolean, enabled: boolean, reason: string } | null, blocked?: (c: object) => string }} ctx
 * @returns {{ available: boolean, reason: string }}
 */
export function judge(c, ctx) {
  if (typeof c.disabled === 'string' && c.disabled) return { available: false, reason: c.disabled };
  if (c.disabled === true) return { available: false, reason: c.reason || 'Action indisponible pour l’instant.' };
  if (c.needsConnection && !ctx.connected) return { available: false, reason: 'Connexion à l’annuaire requise.' };
  if (c.requires === 'selection' && !ctx.selectionType) return { available: false, reason: 'Ouvrez d’abord une fiche.' };
  if (c.requires === 'machineRows' && !(ctx.machineRows > 0)) return { available: false, reason: 'Sélectionnez au moins un poste dans la liste.' };
  if (TYPE_LABELS[c.requires] && ctx.selectionType !== c.requires) return { available: false, reason: `Sélectionnez ${TYPE_LABELS[c.requires]}.` };
  if (c.effect === 'write' && ctx.readOnly) return { available: false, reason: 'Lecture seule : les écritures ne sont pas admises dans ce mode.' };
  const blocked = c.effect === 'write' ? ctx.blocked?.(c) : '';
  if (blocked) return { available: false, reason: blocked };
  if (c.catalogue && !c.route && !c.run && ['read', 'sensitive', 'write'].includes(c.effect)) {
    const control = ctx.control?.(c.id);
    if (!control) return { available: false, reason: 'Action absente de cet écran.' };
    if (!control.reachable) return { available: false, reason: 'Action non affichée pour cette fiche ou ce profil.' };
    if (!control.enabled) return { available: false, reason: control.reason || 'Action indisponible pour l’instant.' };
  }
  return { available: true, reason: '' };
}

/**
 * Filters and orders entries (Domenia 1 Select-DomeniaPaletteEntries): every word must appear; available first, then a label
 * starting with the text, a word of the label starting with it, a keyword starting with it, then the catalogue order.
 * @param {Array<object>} entries each with label, keywords, group, available, order
 * @param {string} query @param {number} [max]
 */
export function selectEntries(entries, query, max = 40) {
  const key = searchKey(query);
  const terms = key.split(' ').filter(Boolean);
  const scored = [];
  for (const e of entries) {
    const hay = ` ${searchKey(`${e.label} ${e.keywords ?? ''} ${e.group ?? ''}`)} `;
    if (!terms.every((t) => hay.includes(t))) continue;
    const label = searchKey(e.label);
    let rank = 3;
    if (!terms.length || label.startsWith(key)) rank = 0;
    else if (` ${label}`.includes(` ${terms[0]}`)) rank = 1;
    else if (hay.includes(` ${terms[0]}`)) rank = 2;
    scored.push({ e, availability: e.available === false ? 1 : 0, rank, order: e.order ?? 999 });
  }
  scored.sort((a, b) => a.availability - b.availability || a.rank - b.rank || a.order - b.order);
  return scored.slice(0, max).map((s) => s.e);
}

/**
 * What happens when an entry is chosen (Domenia 1 Get-DomeniaPaletteDecision). Never a write.
 * @returns {{ action: 'none'|'focus'|'click'|'run', status: string }}
 */
export function decide(entry) {
  if (!entry || entry.available === false) return { action: 'none', status: entry?.reason ? `Indisponible : ${entry.reason}` : 'Choisissez une action disponible.' };
  if (entry.effect === 'write') return { action: 'focus', status: `${entry.label} : bouton prêt, rien n’est encore écrit. L’écriture passe ensuite par sa propre étape de confirmation.` };
  if (entry.effect === 'sensitive') return { action: 'focus', status: `${entry.label} : bouton prêt. La lecture protégée part seulement après votre clic.` };
  if (entry.effect === 'read' && !entry.run) return { action: 'click', status: `${entry.label} : lecture demandée.` };
  return { action: 'run', status: entry.effect === 'read' ? `${entry.label} : lecture demandée.` : '' };
}

/**
 * State of the button of a catalogue command in the page: tagged data-command="<id>" (screens of Domenia 2).
 * @param {string} id @param {ParentNode} [scope]
 */
export function controlOf(id, scope = document) {
  const el = scope.querySelector(`[data-command="${CSS.escape(id)}"]`);
  if (!el) return null;
  const visible = typeof el.checkVisibility === 'function' ? el.checkVisibility() : !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const disabled = el.disabled === true || el.getAttribute('aria-disabled') === 'true' || !!el.closest('[inert]');
  const reason = el.dataset.reason || el.dataset.tip || el.getAttribute('aria-description') || el.title || '';
  return { el, reachable: visible, enabled: !disabled, reason: disabled ? reason : '' };
}
