# Domenia 2 — écritures : plan, confirmation, reçu, relecture

Ce document dit comment Domenia 2 écrit, et comment un écran ajoute une écriture sans rien affaiblir. Le contrat des
opérations est dans [`OPERATIONS.md`](OPERATIONS.md) § 12, l’organisation du moteur dans [`PLATFORM.md`](PLATFORM.md), la
simulation dans [`SIMULATION.md`](SIMULATION.md). Mis en place le 22 octobre 2026, avec un exemple complet de bout en bout :
**déverrouiller un compte** (`accounts.unlock.plan`). Tests écrits, non exécutés (décision de David du 21/10 : à la toute
fin) ; compilation Debug et Release vérifiée dans la VM, 0 avertissement.

## 1. Principes

Les règles de sécurité de Domenia 1 sont reprises telles quelles et resserrées :

| Règle | Dans Domenia 2 |
|---|---|
| Lecture seule par défaut | Une **seule** opération de classe `Write` existe : `write.execute`. Les gardes d’admission des deux modes refusent toute autre écriture avant son gestionnaire (`AdmissionGuards.IsWriteCircuit`) ; un test vérifie que le registre réel n’en déclare pas d’autre. Les écrans ne déclarent que des **plans** (des lectures). |
| Aucune écriture sans plan | `write.execute` n’accepte qu’un plan scellé par le moteur, identifié, à jour et confirmé. Le plan fige la cible exacte (DN et GUID), le contrôleur, le compte, le mode, les changements ordonnés et leurs valeurs brutes, avec une empreinte SHA-256 (Domenia 1 TRV-213, TRV-227). |
| Confirmation explicite | Jeton à **usage unique**, lié à l’empreinte du plan, valable **5 minutes** ; nom de la cible à saisir quand le plan l’exige (compte à privilèges pour le déverrouillage), **revérifié par le moteur** (TRV-186 amélioré : élévation par écriture, pas de mode global). |
| Reçu de chaque écriture | Le reçu est écrit **avant** l’envoi : sans reçu durable, rien ne part (TRV-281, fail closed). Il est complété par le résultat puis par la relecture. |
| Relecture ensuite | Chaque écriture se termine par une relecture de la cible (postcondition, OPE-009) : `verified`, `mismatch` ou `unknown`. Le code de retour n’est jamais une preuve. |
| Jamais rejouée | Ni le moteur, ni la page, ni un redémarrage, ni un reçu ne renvoient une écriture. Un jeton ne sert qu’une fois, même si l’écriture est refusée ensuite ; un double clic part une fois (TRV-232). La page ne réessaie jamais `write.execute`. |
| Incertitude bloquante | Une écriture partie sans issue connue (application fermée, erreur après l’envoi) **bloque toutes les nouvelles écritures** jusqu’à une relecture qui tranche ou une revue manuelle, jamais levée par le temps ni par un redémarrage (Domenia 1 `Assert-WriteAllowed`, `Get-DomeniaReceiptSummary`, OPE-025, OPE-026, TRV-230, TRV-231) ; sa propre cible est refusée en premier (`write.targetPending`), les autres objets avec `write.receiptsPending`. Les lectures, la relecture et la revue restent possibles. |
| Préconditions relues | Juste avant l’envoi, l’exécuteur relit la cible : même objet, même place, mêmes valeurs « avant » ; sinon rien n’est envoyé (`write.stale`, TRV-228, TRV-235). |
| Une écriture à la fois | Le circuit sérialise les écritures (canal unique, TRV-214) ; une écriture commencée n’est jamais interrompue (elle reçoit `CancellationToken.None`). |
| Aucun secret | Un plan ne contient jamais de secret ; le jeton n’est écrit nulle part (ni reçu, ni journal) ; le journal technique ne reçoit que des codes et des nombres (ni DN, ni nom). Les mots de passe des écritures à venir restent en `SecureString` jusqu’à l’API Windows (§ 6, étape 9). |
| Jamais tout le domaine | Un plan vise exactement **un** objet. Une écriture collective a son propre plan avec un aperçu exact, scellé par le moteur (TRV-229) : en place pour les comptes (`accounts.batch.preview`, `confirm`, `plan`, [`ops/comptes.md`](ops/comptes.md) § 3.5), puis un plan, un jeton, un reçu et une relecture par cible. |
| Simulation sans effet réel | Décision de David du 21/10 : en simulation, `write.execute` est admis et ses exécuteurs écrivent dans une **surcouche en mémoire** de l’annuaire fictif, vue par toutes les lectures, jamais enregistrée. Les reçus sont marqués « simulé ». |

## 2. Architecture

```text
page        web/js/write-flow.js   runWrite : plan → panneau du plan → confirmWrite (kit) → write.execute → reçu, toast
            web/js/pages/ecritures.js  écran caché #/ecritures : référence du circuit et des reçus
pont        Domenia.Bridge/Operations/AccountUnlockOperations.cs  accounts.unlock.plan (lecture)
            Domenia.Bridge/Operations/WriteOperations.cs          write.execute (Write), write.receipts.list / get / verify
            AdmissionGuards                                        Write admis pour write.execute seulement
Core        Writes/WriteModels.cs       plan, brouillon, cible, changements, risques, reçu, vues
            Writes/WritePlans.cs        scellement (identifiant, compte, mode, dates, empreinte, détails techniques)
            Writes/ConfirmationTokens.cs  jetons à usage unique liés à l’empreinte, 5 min
            Writes/WriteExecutors.cs    IWriteExecutor (Check, Execute, Verify) et découverte par source
            Writes/WriteCircuit.cs      le canal unique : plan, exécution, reçus, relectures
            Writes/WriteReceipts.cs     règles des reçus en mots clairs (ton, à vérifier, phrases)
            Writes/IReceiptStore.cs     magasin des reçus (MemoryReceiptStore pour la capture, l’E2E et les tests)
            Writes/Accounts/AccountUnlock.cs  règles pures du déverrouillage + IAccountUnlockExecutor
Simulation  SimulatedDirectoryOverlay.cs           surcouche en mémoire (par GUID)
            Writes/SimulatedAccountUnlockExecutor.cs  déverrouillage sur la surcouche
Store       Receipts/FileReceiptStore.cs  receipts.jsonl / receipts-simulation.jsonl, ajout atomique
Ad          vague 3 : les mêmes interfaces d’exécuteur, sur Active Directory
```

`EngineContext` porte deux services de plus : `Writers` (exécuteurs servis par la source du mode, trouvés par réflexion
comme les lecteurs d’écran, `WriteExecutors.Discover`) et `Receipts` (magasin des reçus du mode). `WriteCircuit.From(context)`
est le service partagé du contexte, comme `DashboardService.From`.

## 3. Plan et jeton

1. L’écran appelle `<écran>.<verbe>.plan` (une lecture : `LocalRead` en simulation, `NetworkRead` en mode annuaire, car le
   plan relit l’objet sur le contrôleur après le geste de l’opérateur).
2. L’exécuteur du type relit la cible et rend un **brouillon** (`WritePlanDraft`) : type (`account.unlock`), titre
   (« Déverrouiller le compte »), libellé (« Déverrouillage du compte »), résumé, cible (`WriteTarget` : type, libellé, nom,
   DN, GUID, compte), changements (`WriteChange` : attribut, libellé, nature `replace|clear|add|remove|move|reset`, avant
   et après en clair, valeurs brutes), risques (`WriteRisk` : ton `warn|alert|info`, texte), confirmation
   (`WriteConfirmation` : saisie exigée ou non, nom à saisir, raison), réversibilité (`WriteReversibility`), contrôleur.
   Il ne lève que des refus attendus : `write.targetUnknown`, `write.nothingToDo`.
3. `WriteCircuit.PlanAsync` refuse si aucun exécuteur de ce mode ne sert le type (`source.unavailable`), si un reçu
   incertain tient la cible (`write.targetPending`) ou un autre objet (`write.receiptsPending` : toutes les nouvelles écritures
   attendent), ou si les reçus sont illisibles (`receipt.unavailable`) ; sinon il
   **scelle** le plan (`WritePlans.Seal`) : identifiant (32 hexadécimaux aléatoires), opérateur (compte de la session), mode,
   `createdAt` à la seconde, `expiresAt` = `createdAt` + 5 min, empreinte, détails techniques repliés (TRV-225).
4. L’empreinte est le SHA-256 d’un JSON canonique de tout ce dont l’écriture dépend : identifiant, type, cible (DN, GUID,
   compte), contrôleur, opérateur, mode, exigence de saisie et nom, dates, et pour chaque changement l’attribut, la nature et
   les valeurs brutes. Les textes pour l’opérateur (titre, résumé, risques) n’y entrent pas.
5. Le jeton est 32 octets aléatoires en base64url (43 caractères). Le moteur ne garde que `SHA-256(jeton | empreinte)` : un
   jeton ne vaut que pour le plan exact qui l’a fait naître. Il part avec le plan dans la réponse (`{ plan, token }`) et
   n’est écrit nulle part ailleurs.

À l’exécution (`write.execute { planId, token, typedName? }`), dans cet ordre, rien n’est envoyé au moindre écart :

| Contrôle | Refus |
|---|---|
| plan connu de cette session | `write.planUnknown` |
| jeton pas encore utilisé | `write.tokenUsed` |
| jeton conforme à l’empreinte recalculée du plan | `write.tokenInvalid` (ou `write.planChanged` si le plan ne correspond plus à son empreinte) |
| moins de 5 minutes | `write.tokenExpired` |
| nom saisi identique, casse comprise, quand le plan l’exige (le plan est alors dépensé) | `write.confirmationMismatch` |
| premier à consommer le jeton (double clic, deux pages) | `write.tokenUsed` |
| aucune écriture incertaine sur la cible | `write.targetPending` |
| aucune écriture incertaine sur un autre objet | `write.receiptsPending` |
| préconditions relues juste avant l’envoi | `write.stale` (message de l’exécuteur) |
| reçu version 1 durablement écrit | `receipt.unavailable` |

Un jeton invalide ne dépense pas le plan (un jeton de 256 bits ne se devine pas) ; tout refus après sa vérification le
dépense.

## 4. Reçus

### 4.1 Versions et états

Un reçu est une suite de **versions** du même identifiant ; la plus récente fait foi.

| Version | Écrite | Contenu |
|---|---|---|
| 1 | **avant** l’envoi | plan complet, `result` = `sent`, `verification` = `unknown`, détail « Préconditions » |
| 2 | après l’envoi | `result` = `applied` (écrit), `noChange` (déjà dans l’état demandé : rien envoyé), `notApplied` (refus attendu avant tout changement, avec `error`) ou `unknown` (issue inconnue, `error` = `write.outcomeUnknown`) ; détail « Envoi » |
| 3 et suivantes | après chaque relecture | `verification` = `verified`, `mismatch` ou `unknown`, `verifiedAt` ; détail « Relecture » |
| 3 et suivantes | après une revue manuelle (`operations.receipts.review`, `WriteCircuit.ReviewAsync`) | `verification` = `reviewed` (« Revue manuelle », ton `info`, jamais un succès), détail « Revue manuelle » avec le motif (12 à 240 caractères, jamais un secret) et le compte de la session ; seulement pour un reçu à vérifier (`receipt.resolved` sinon) |

Un reçu est **à vérifier** (`pending`) tant que sa requête est partie sans issue connue (`sent` ou `unknown`) et qu’aucune
relecture n’a tranché (`verification` = `unknown`). Il bloque alors **toutes** les nouvelles écritures (sa cible :
`write.targetPending`, les autres objets : `write.receiptsPending`, comme Domenia 1) ; `write.receipts.verify` relit l’objet
et le débloque dès que la relecture conclut (`verified` : l’écriture a bien eu lieu, `mismatch` : elle n’a pas eu lieu), ou une
revue manuelle le résout (`reviewed`). Une relecture ultérieure qui ne prouve rien garde la revue ; une relecture conclusive la
remplace. Quand le dernier reçu à vérifier est tranché, le journal technique écrit « Incertitude levée uniquement après
vérification ou revue explicite des reçus durables » (WARN) et le journal des opérations « Écritures de nouveau admises ». Un
reçu `sent` retrouvé au démarrage suivant est donc incertain et bloquant, jamais renvoyé (TRV-231).

Tons et libellés (`WriteReceipts`, pur) : `applied`/`noChange` + `verified` → `ok` ; + `mismatch` → `alert` ; + `unknown`
→ `warn` ; `reviewed` → `info` (« Revue manuelle ») ; `notApplied` → `alert` (ou `info` si la relecture trouve l’état attendu) ;
à vérifier → `warn`. Chaque reçu a une phrase pour l’opérateur ; la liste a la sienne (Domenia 1 `Get-DomeniaReceiptSummary` :
« Une opération reste à vérifier : les nouvelles écritures sont bloquées jusqu’à sa vérification ou sa revue. Rien n’est renvoyé
automatiquement. », « Aucune écriture à vérifier. 3 reçus conservés ; rien n’est renvoyé automatiquement. »).

### 4.2 Stockage (`FileReceiptStore`, classe `LocalWrite`)

- `%LOCALAPPDATA%\Domenia\receipts.jsonl` en mode annuaire, `receipts-simulation.jsonl` en simulation (jamais partagés) ;
  en mémoire seulement en mode capture, en mode E2E et sans dossier de données (`MemoryReceiptStore`).
- Une ligne par version : `{"format":"domenia.receipt","version":1,"receipt":{…}}`, UTF-8 sans BOM, 64 Kio au plus.
- **Ajout atomique** : sous un verrou commun à tous les processus Domenia de la machine (mutex nommé
  `Global\Domenia.Receipts.<empreinte du chemin>`, 5 s d’attente au plus), la ligne entière est écrite d’un seul appel sur
  un flux `WriteThrough` puis vidée sur le disque. Une ligne coupée par un arrêt brutal (sans saut de ligne final) est
  fermée par l’ajout suivant : elle n’avale jamais l’enregistrement suivant.
- **Lecture incrémentale** : seuls les octets ajoutés depuis la dernière lecture sont lus (une autre instance qui ajoute
  est donc vue) ; une dernière ligne incomplète attend la lecture suivante ; un fichier raccourci est relu depuis le début.
- Une ligne illisible est comptée (`unreadable` de la liste) et tracée une fois, jamais fatale : la seule ligne qu’un arrêt
  peut couper est celle en cours d’écriture, et la version 1 d’un reçu est complète avant tout envoi.
- Un fichier illisible pour l’instant (verrouillé, accès refusé, plus de 64 Mio) refuse **toute** écriture (fail closed) :
  `receipt.unavailable`.
- Une version 2 ou suivante que le disque refuse vaut pour la session (le circuit la garde en mémoire) et le journal des
  opérations le dit (« Reçu d’écriture non enregistré sur le disque »). Sur le disque, le reçu reste alors à sa version 1,
  donc incertain et bloquant au démarrage suivant : prudent par construction.

## 5. Simulation : surcouche en mémoire

- `SimulatedDirectorySource.Overlay` (`SimulatedDirectoryOverlay`) garde, par GUID, les objets changés par les écritures de
  la session. **Toutes** les lectures de la source la voient : `ReadLocalAsync` et `RefreshAsync` (Accueil),
  `CurrentDirectory` (lecteurs d’écran et exécuteurs). Le monde généré (`World`) ne change jamais, son empreinte non plus.
- Jamais enregistrée : un nouveau lancement repart de l’annuaire généré (les reçus, eux, restent dans
  `receipts-simulation.jsonl`, marqués « simulé »).
- Seuls les exécuteurs de `Domenia.Simulation` changent la surcouche (méthodes `internal`, par exemple
  `SimulatedDirectorySource.UpdateUser`) ; `IDirectorySource` n’a toujours aucune méthode d’écriture. La surcouche porte les
  utilisateurs aujourd’hui ; ordinateurs, groupes et OU s’y ajoutent avec leur première écriture, sur le même modèle.
- **Un lecteur d’écran simulé lit `source.CurrentDirectory`, jamais `source.World.Directory`** (sinon il ne verrait pas les
  écritures de la session). `SimulatedDirectoryTreeReader` reconstruit son arbre quand `Overlay.Version` change.
- Délais réalistes et déterministes par étape (`latency/screen/write/plan|check|execute|verify`), aucun avec
  `SimulationLatency.None`.
- La garde de simulation admet `write.execute` (surcouche seulement) ; toute autre opération `Write` reste refusée
  (`simulation.readOnly`). `session.info.readOnly` vaut donc `false` en simulation ; la bannière le dit.

## 6. Ajouter une écriture à un écran

Exemple réel : le déverrouillage d’un compte (`account.unlock`). Un écran ne touche ni au circuit, ni aux gardes, ni à la
composition.

1. **Contrat.** Écrire `<écran>.<verbe>.plan` dans `OPERATIONS.md` § 12 (arguments, erreurs propres, type d’écriture) avant
   le code. Le résultat est toujours `{ plan, token }` (§ 12.1) ; l’exécution est toujours `write.execute`.
2. **Règles pures** dans `Domenia.Core/Writes/<Domaine>/<Verbe>.cs` (modèle : `AccountUnlock`) : `Draft` (brouillon à partir
   de l’objet lu : changements avec valeurs brutes, risques, confirmation, réversibilité), `Check` (préconditions : même
   GUID, même DN, valeurs « avant » inchangées ; un objet déjà dans l’état demandé reste valable et ne sera pas écrit),
   `Apply` (l’objet après l’écriture, pour la simulation), `Verify` (postcondition par relecture). Aucune horloge ni
   culture lue en interne : `now` et le fuseau sont des entrées. Textes avec `FrenchText` (U+00A0 avant « : »).
3. **Interface d’exécuteur** à côté, dans Core : `public interface I<Verbe>Executor : IWriteExecutor` avec la lecture qui
   bâtit le plan (`Task<WritePlanDraft> PlanAsync(string dn, CancellationToken)` pour le déverrouillage). Aucune autre
   méthode : `CheckAsync`, `ExecuteAsync` et `VerifyAsync` sont celles de `IWriteExecutor`, appelées par le circuit seulement.
4. **Exécuteur de simulation** dans `Domenia.Simulation/Writes/Simulated<Verbe>Executor.cs` : classe publique, un seul
   constructeur public qui prend `SimulatedDirectorySource` et ne lit rien. Il lit `source.CurrentDirectory`, écrit par les
   méthodes `internal` de la source (`UpdateUser` ; ajouter `UpdateComputer`, `UpdateGroup`… à la surcouche au premier
   besoin), attend `source.SimulateScreenLatencyAsync("write/<étape>", …)`. Il est trouvé tout seul
   (`WriteExecutors.Discover`).
5. **Module** dans `Domenia.Bridge/Operations/` : une opération de lecture, jamais `Write` :

   ```csharp
   var readClass = context.Mode == AppMode.Simulation ? OperationClass.LocalRead : OperationClass.NetworkRead;
   new OperationDefinition("accounts.unlock.plan", readClass, async (args, _, ct) =>
   {
       var values = BridgeArguments.ReadObject(args, ["dn"]);
       var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
       var draft = await context.Writers.Require<IAccountUnlockExecutor>().PlanAsync(dn, ct).ConfigureAwait(false);
       return await WriteCircuit.From(context).PlanAsync(draft, ct).ConfigureAwait(false);
   }, "Plan du déverrouillage d’un compte…");
   ```

   Sans exécuteur pour la source du mode (mode annuaire tant que `Domenia.Ad` n’existe pas), `Require<T>()` refuse avec
   `source.unavailable`.
6. **Page** : l’action est marquée écriture (`kind: 'write'`, `danger: true` si destructrice) et appelle

   ```js
   import { runWrite } from '../write-flow.js';
   await runWrite(ctx, { plan: 'accounts.unlock.plan', args: { dn }, onDone: () => reload() });
   ```

   Rien d’autre : panneau du plan, confirmation, exécution, reçu et toast sont ceux du circuit (§ 7).
7. **Aperçu dans un navigateur** : la même opération dans `web/js/mock-writes.js` (mêmes formes et textes).
8. **Tests** dans `tests/Domenia.Tests/` (modèles : `AccountUnlockTests`, `WriteCircuitTests`) : règles pures (brouillon,
   risques, confirmation, préconditions, application, relecture), forme JSON exacte du plan, exécution de bout en bout par
   le pont réel (`SimulatedBridge` : reçu `applied`/`verified`, surcouche, Accueil, journal, étapes poussées), refus
   (`write.nothingToDo`, `write.targetUnknown`, arguments), plan exécuté une seule fois, plan d’un objet changé entre-temps.
9. **Exécuteur réel** (vague 3) dans `Domenia.Ad` : `Ad<Verbe>Executor(<source AD>)`, même interface.
   - `PlanAsync` : lecture fraîche de l’objet sur le contrôleur de la session (aucune donnée du cache local : TRV-161).
   - `CheckAsync` : relecture **sur le même contrôleur** juste avant l’envoi ; un attribut absent de la relecture n’est pas
     un attribut vide.
   - `ExecuteAsync` : une seule requête ; écriture conditionnelle quand c’est possible (TRV-234 : suppression de l’ancienne
     valeur et ajout de la nouvelle dans la même requête LDAP ; codes 16, 19, 20 = conflit → `DomeniaOperationException`
     `write.conflict`, résultat « non appliquée ») ; un refus de droits avant tout changement → `DomeniaOperationException`
     (non appliquée) ; pas de réponse, code client ou toute autre exception → issue inconnue (le circuit la marque
     `unknown`, jamais renvoyée). Aucun nouvel essai, aucune valeur dans le journal ; mot de passe en `SecureString` jusqu’à
     l’API Windows, jamais dans le plan (le plan dit « remplacé par la nouvelle valeur saisie, ni affichée ni conservée »).
   - `VerifyAsync` : relecture sur le même contrôleur ; relecture sur un autre contrôleur dite (réplication).

## 7. Page : `web/js/write-flow.js`

- `runWrite(ctx, { plan, args, subtitle?, onDone? })` → promesse du reçu (ou `null` : annulé, refusé avant l’envoi).
  1. Panneau latéral modal du kit (`openDrawer`), squelette pendant la lecture du plan.
  2. **Plan** : carte de la cible (type, nom, DN, pastilles simulation, confirmation, retour arrière), résumé, tableau
     avant → après animé (lignes en cascade, ancienne valeur barrée à la main, flèche, nouvelle valeur qui s’allume),
     points à vérifier par ton, faits (confirmation, retour arrière, contrôleur, opérateur), **validité** du plan en direct
     (barre qui se vide, alerte à moins d’une minute, plan expiré : « Préparer de nouveau »), détails techniques repliés.
  3. **Confirmation** : `confirmWrite` du kit, avec saisie du nom si le plan l’exige (`typed`), le nom saisi étant passé au
     moteur qui le revérifie (`onTyped`) ; sinon confirmation simple dans le même dialogue (changements, détails, badge
     « Écriture simulée · annuaire fictif » en simulation).
  4. **Exécution** : panneau verrouillé (ni bouton de fermeture, ni Échap, ni clic sur le voile), trois étapes animées
     pilotées par l’événement `write.execute:stage` (relecture avant l’envoi, reçu et envoi, relecture après).
  5. **Reçu** : médaille au ton du reçu, résultat et relecture en pastilles, phrase, fil des étapes (préconditions, envoi,
     relecture), faits (cible, contrôleur, opérateur, dates, identifiant du reçu, empreinte du plan), plan exécuté replié ;
     « Relire l’objet » (`write.receipts.verify`) et « Voir dans Opérations ». Un **toast** au ton du reçu porte le lien
     « Voir le reçu dans Opérations » (`#/operations?recu=<id>` : l’écran Opérations ouvre ce reçu).
  - Refus : « Rien n’a été envoyé » (code et conseil, « Préparer de nouveau » pour un plan périmé ou expiré) ; erreur
    imprévue après la confirmation : « Issue incertaine », lien vers Opérations, rien n’est renvoyé.
- `openReceipt(ctx, id, { onChange })` : panneau d’un reçu (pour Opérations et le lien du toast), avec relecture en place.
- `receiptHref(id)` : adresse d’un reçu dans Opérations.
- Écran caché **`#/ecritures`** (comme `#/kit`) : les cinq temps du circuit, l’exemple de référence, les derniers reçus.
  `?etape=plan` ouvre le plan de l’exemple, `?etape=confirmation` le plan puis sa confirmation (captures) ; ni l’un ni
  l’autre n’exécute rien.
- Styles : `css/write-flow.css` (chargé par `index.html`), `css/pages/ecritures.css`. Animations en `transform`, `opacity`
  et `filter` seulement, jetons de durée, boucles arrêtées en animations réduites, cadres au lieu des halos en contraste
  élevé. Annonces au lecteur d’écran à chaque étape.

## 8. Tests écrits (exécutés à la fin, dans la VM)

| Fichier | Couvre |
|---|---|
| `WriteCircuitTests` | forme exacte du plan et du reçu ; exécution de bout en bout sur la surcouche (Accueil, journal, étapes, liste, détail) ; plan exécuté une fois ; jeton expiré, inventé, mal formé ; arguments ; compte non verrouillé, poste, DN mal formé ; second plan d’un compte déverrouillé entre-temps (`noChange`) ; mode annuaire sans exécuteur ; saisie du nom revérifiée et plan dépensé ; préconditions changées ; issue inconnue qui bloque la cible jusqu’à la relecture ; aucun envoi sans reçu durable ; version refusée par le disque ; double envoi ; jeton et données d’annuaire absents des reçus et du journal technique ; surcouche jamais enregistrée ; découverte des exécuteurs ; gardes (seule `write.execute` est admise) ; empreinte et jetons ; mots des reçus |
| `AccountUnlockTests` | brouillon (compte standard, compte à privilèges, verrouillage expiré, à vérifier, compte désactivé, mot de passe à changer), refus « rien à faire », préconditions, changement appliqué, postcondition |
| `ReceiptStoreTests` | une ligne par version et la dernière gagne (relu à l’identique, plan intact), deux instances, ligne coupée fermée par l’ajout suivant, lignes illisibles comptées, fichier raccourci, fichier trop gros, noms et verrou |
| mis à jour | `DashboardOperationsTests` (registre réel : une seule écriture, `write.execute`, admise dans les deux modes ; `readOnly` faux en simulation), `PlatformTests` (modules et opérations du pont), `WorkingScopeTests` (`readOnly`) |

## 9. Reste à faire

- Pastille « opérations à vérifier » de la barre supérieure (écran shell, sur `operations.center`) ; l’écran Opérations la porte
  déjà dans son en-tête, sa tuile et son onglet (OPE-025, OPE-026, `docs/ops/operations.md`).
- Compensation pré-remplie dans la fiche (`compenser=<reçu>`, OPE-010), compaction et archive des reçus (TRV-283), protection du
  dossier des reçus (TRV-282).
- Écritures suivantes des écrans (fiche, activation, mot de passe, groupes, déplacement, actions distantes), chacune par la
  recette du § 6 ; surcouche étendue aux ordinateurs, groupes et OU au premier besoin.
- Mode écriture global de Domenia 1 (TRV-186) : remplacé ici par la confirmation de chaque écriture ; à confirmer par David.
- Exécuteurs réels dans `Domenia.Ad` (vague 3), puis essais réels dans `OU=Domenia-Tests` du labo (décision du 21/10,
  vague 4).

## 10. Session et résultat de transport (23 octobre 2026)

Le brouillon réel porte l’origine de sa lecture en mémoire seulement. Le circuit refuse de le sceller ou de l’envoyer si l’époque, le domaine, le compte ou le mode d’authentification ont changé. Même une reconnexion du même compte invalide les anciens plans. Pendant préconditions, envoi et relecture, un bail de la source AD empêche la bascule et la réinitialisation de la connexion. Un traitement en préconditions est déjà signalé comme une écriture en cours aux accès.

Seule une réponse LDAP d’échec définitive permet de conclure à un refus du contrôleur. Une coupure, un délai client ou une fermeture après envoi conserve une issue inconnue, sans diagnostic serveur brut et sans répétition automatique. La relecture et le reçu restent obligatoires. Quatre tests de ces gardes sont écrits et compilés ; leur exécution reste prévue à la recette finale.

## 11. Exécuteurs Comptes annuaire (23 octobre 2026)

Les contrats de déverrouillage, activation, désactivation, changement imposé et expiration ont un exécuteur AD découvert automatiquement, commun à Comptes et Fiche. Chaque plan porte son origine de session. Le compte réel de session protège la désactivation de soi ; un opérateur transmis par la page ne peut pas le remplacer. Les comptes système, valeurs nécessaires illisibles, GUID remplacés, contrôleurs différents et protections devenues plus fortes sont refusés avant envoi.

Les requêtes ciblent la forme GUID du DN, documentée par [MS-ADTS, formes alternatives de DN](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-adts/92a54869-38d7-4e71-a3be-5f67a0dcdd7e). UAC et expiration retirent la valeur exactement relue et ajoutent la valeur confirmée dans une même requête Modify, sans contrôle permissif : une valeur concurrente doit provoquer un refus, sans écrasement. Ce mécanisme reste à qualifier sur le contrôleur du labo. Les attributs pilotés par AD `lockoutTime` et `pwdLastSet` sont remis à zéro après une relecture fraîche ; cette lecture et la modification ne constituent pas une transaction atomique. Aucun support de contrôle assertion n’est supposé.

La postcondition est relue par GUID sur le même contrôleur. Une absence de l’état calculé du verrouillage reste inconnue ; un mot de passe devenu sans expiration ne prouve pas qu’un changement est effectivement imposé. Le cache est actualisé ; un échec du stockage local est séparé de la preuve LDAP. Six tests sont écrits et compilés, sans exécution avant la recette finale.
