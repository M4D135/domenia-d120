# Suivi — SP-03 « Mode annuaire réel des écrans Fiche et Comptes »

Branche : `spark/03-ad-fiche-comptes`. Arbre : `../Domenia-D120-team/sp-03-ad-fiche-comptes`.
Tenu à jour à chaque étape par le Spark (OpenCode, modèle local). Un agent interrompu reprend ici, en lisant ce fichier
en premier.

## 0. Quoi et comment

- Mission : lecteurs réels dans `v2/src/Domenia.Ad/Screens/` et exécuteurs d’écriture LDAP réels dans
  `v2/src/Domenia.Ad/Writes/` pour les écrans Fiche et Comptes, selon `docs/WRITES.md` et les sections « Mode annuaire »
  de `docs/ops/fiche.md` (§ 5) et `docs/ops/comptes.md` (§ 7) ; plus CPT-017 (coffre Windows, P/Invoke) par gestes
  explicites, indisponible en simulation. Tests unitaires sans AD réel.
- Compilation : `bash v2/tools/vm.sh s03 build` (lot `s03`, VM Windows, jamais le Mac). Tests exécutés à la toute fin
  (décision de David du 21/10) : ici ils sont écrits et compilés.
- Interdits appliqués : aucune écriture dans l’Active Directory, aucune exécution en mode annuaire, aucun `dotnet` sur le
  Mac, aucun push, aucune modification hors `v2/`, aucune dépendance nouvelle, rien sur WAPT.

## 1. Lecture faite avant de coder

`REPRISE.md` § 0, § 4 bis et § 5 ; `v2/CLAUDE.md` ; `docs/DECISIONS.md` ; `docs/PLATFORM.md` ; `docs/OPERATIONS.md` ;
`docs/WRITES.md` ; `docs/ops/fiche.md` ; `docs/ops/comptes.md`. Puis le code : `Domenia.Ad` (`Ldap/AdContracts.cs`,
`Ldap/AdConnection.cs`, `AdDirectorySource.cs`, `AdDirectoryReader.cs`, `AdDirectoryMapper.cs`,
`Checks/AdDirectoryChecks.cs`, `Screens/AdDirectoryTreeReader.cs`), `Domenia.Core/Writes/*` (contrats des exécuteurs et
règles pures), `Domenia.Simulation/Writes/*` (modèles des exécuteurs de simulation),
`Domenia.Simulation/Screens/SimulatedAccountsReader.cs`, `Domenia.Simulation/Screens/Fiche/*`,
`Domenia.Bridge/Operations/{FicheOperations,AccountsOperations,AccountsAccessOperations,AccountUnlockOperations}.cs`,
`Domenia.App/Composition.cs` (tout se découvre par réflexion : aucun fichier partagé à toucher).
Référence CPT-017 côté Domenia 1 (lecture seule) : `dev/wad/modules/Domenia-CredentialVault.Native.cs` et
`dev/wad/docs/credential-vault.txt`.

## 2. Interprétation de la mission (à valider)

La mission énumère les écritures à brancher : déverrouillage, réinitialisation de mot de passe (`SecureString` jusqu’à
l’API), activation et désactivation, expiration, changement au prochain logon, groupes, déplacement, renommage.
Lecture retenue : un exécuteur LDAP réel par **opération** citée, sur les deux écrans de la mission.

| Opération citée | Type d’écriture | Exécuteur réel ajouté |
|---|---|---|
| déverrouillage | `account.unlock` | `AdAccountUnlockExecutor` |
| activation / désactivation (Comptes, utilisateurs) | `account.enable`, `account.disable` | `AdAccountEnableExecutor`, `AdAccountDisableExecutor` |
| activation / désactivation (Fiche, utilisateur ou ordinateur) | `account.enabled` | `AdAccountEnabledExecutor` |
| expiration du compte | `account.expiration` | `AdAccountExpirationExecutor` |
| changement au prochain logon | `account.mustChangePassword` | `AdAccountMustChangePasswordExecutor` |
| expiration du mot de passe (`pwdLastSet = 0`, Fiche) | `password.expire` | `AdPasswordExpireExecutor` |
| réinitialisation du mot de passe (Comptes) | `account.resetPassword` | `AdAccountPasswordResetExecutor` |
| réinitialisation du mot de passe (Fiche, fenêtre sécurisée de l’hôte) | `password.reset` | `AdPasswordResetExecutor` |
| groupes | `group.member` | `AdGroupMemberExecutor` |
| déplacement | `object.move` | `AdObjectMoveExecutor` |
| renommage | `poste.rename` (seul renommage existant à ce jour, objet ordinateur) | `AdPosteRenameExecutor` |

Restent **sans exécuteur réel** — donc refusés `source.unavailable` en mode annuaire, comme avant cette mission, et
affichés indisponibles avec leur motif : `object.update`, `attribute.raw`, `account.options`, `object.delete`,
`ou.create`, `poste.accountState`, `poste.profile`, `poste.group`, `poste.move`, et les écritures distantes du Poste
(WMI). Ils ne sont pas dans l’énumération de la mission ; les demander explicitement avant de les écrire.

## 3. Fait

| Étape | Fichiers | Commit | État |
|---|---|---|---|
| Lecture des docs et du code ; build de référence | — | — | `bash v2/tools/vm.sh s03 build` (Debug) sur l’arbre intact : 0 erreur, 0 avertissement |
| Suivi de relève (ce fichier) | `docs/reprise/spark/03-ad-fiche-comptes.md` | (1er commit) | écrit |

## 4. Reste à faire

- [ ] `Domenia.Ad/Screens/AdAccountsReader.cs` : `IAccountsReader` + `IAccountsAccessReader` (comptes.md § 7.1, 7.2, 7.4).
- [ ] `Domenia.Ad/Screens/AdFicheReader.cs` : `IFicheReader` (fiche.md § 5.1, 5.2).
- [ ] `Domenia.Ad/Writes/` : les exécuteurs du tableau § 2.
- [ ] CPT-017 : coffre Windows (`CredRead`, `CredWrite`, `CredDelete`), règles pures de la cible dans Core,
      implémentation P/Invoke dans `Domenia.Engine`, gestes explicites de l’écran Comptes, indisponible en simulation.
- [ ] Tests unitaires sans AD réel : fausse `IAdConnection` en mémoire (lecteurs et exécuteurs), règles du coffre,
      refus en simulation.
- [ ] Docs : § 7 de `ops/comptes.md`, § 5 de `ops/fiche.md`, § 12 d’`OPERATIONS.md` pour les opérations du coffre.

## 5. Questions (arbitraires ou en attente)

1. **Coffre Windows, dans quel assemblage ?** Retenue : interface `ICredentialVault` et règles pures de la cible dans
   `Domenia.Core` (testables sans Windows), implémentation P/Invoke dans `Domenia.Engine` (brique du moteur, référencée
   par les tests ; `Domenia.Ad` reste réservé à l’annuaire, `Domenia.App` n’est pas référencé par les tests). Si David
   préfère un autre endroit, déplacer `Engine/Security/WindowsCredentialVault.cs` suffit.
2. **Refus d’authentification pour la fiche (`fiche.lockouts`, FIC-045)** : un lecteur d’écran ne reçoit que la source du
   mode (règle de découverte : un seul constructeur, un seul paramètre) et n’atteint donc pas `AccountAccess`. En mode
   annuaire, `RefusalsAsync` rend une liste vide (rien n’est inventé). Le rapprochement des refus demanderait un
   branchement dans `Composition.cs` (fichier partagé, hors mission). À trancher.
3. **Sessions et inventaire du poste depuis la fiche** (`fiche.callSheet.read sessions` et `triage`, WTS et CIM) :
   l’inventaire complet du poste appartient à l’écran Poste. `SessionsAsync` et `InventoryAsync` répondent
   `source.unavailable` avec leur motif ; `PingAsync` est servi par la sonde déjà branchée sur la source. À confirmer.
4. **Aperçu local (`fiche.preview`, FIC-030) et index local** : la base SQLite (compatible Domenia 1) n’est pas encore
   branchée (tâche distincte). L’aperçu rend `null` — contractuellement admis (« ou `null` sans projection locale ») — et
   l’index local est servi par l’image de l’annuaire déjà lue dans la session.

## 6. Compilation et tests

- Build de référence avant tout changement : `bash v2/tools/vm.sh s03 build` → **0 erreur, 0 avertissement** (Debug).
- Chaque étape commitée est compilée dans la VM (jamais sur le Mac) ; Release vérifiée à la fin.
- Aucun test exécuté (décision du 21/10 : à la toute fin) ; les tests sont écrits et compilés.
