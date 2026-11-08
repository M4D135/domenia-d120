# L01 — relecture croisée (Spark, 2026-11-02)

Méthode : **lecture seule**, deux passes indépendantes (exécuteurs et preuve d'envoi ; conservation
des reçus, tests et documents). **Aucune compilation, aucun test exécuté** : la machine de
développement n'a ni `dotnet` ni `node`, et le poste de qualification a été formaté (voir
`v2/docs/reprise/QUALIFICATION-SANS-POSTE-20261102.md`). Chaque constat est donc une lecture à
confirmer par un build dès qu'un moyen d'exécution existe. Ce document ne qualifie rien et ne
remplace pas `L01.md`.

Aucun défaut **bloquant** n'a été trouvé sur le périmètre. Un défaut **majeur** (incertain, modèle
de menace) et plusieurs mineurs restent ouverts, plus onze affirmations du lot sans couverture de
test.

## Défauts à corriger

| # | sévérité | endroit | constat | attendu |
| --- | --- | --- | --- | --- |
| 1 | MAJEUR (incertain) | `v2/src/Domenia.Store/Receipts/FileReceiptStore.cs:181-184` | un append `Version > 1` dont l'ancêtre n'est ni sur disque ni dans `known` est accepté : le reçu « Sent durable avant tout contact » peut disparaître et laisser la version suivante seule et saine à la lecture | refuser tout append `Version > 1` sans ancêtre visible sur disque **ou** dans `known` ; n'autoriser le saut que depuis une version antérieure connue |
| 2 | MINEUR | `WriteCircuit.cs:557-561` (`PurgeLocked`) | l'éviction de capacité (64 plans) libère la réservation avant la fin réelle ou l'expiration : après 64 plans distincts, une demande identique déjà réservée peut obtenir un second plan (TRV-232 à la préparation) | conserver la réservation jusqu'à expiration, ou refuser d'évincer un plan non expiré |
| 3 | MINEUR | `RemoteOperationGuard.cs:29-32` vs `WriteReceiptStates.BlocksWrite` | la garde d'interface est plus lâche que l'admission (ni `Reversibility.Reversible`, ni `Mode`/`Simulated`, ni lien unique `remote.cancelPlan` ; contrôleur comparé à la session au lieu du plan) : l'UI peut annoncer une annulation admissible que le circuit refusera | aligner le prédicat sur `BlocksWrite` (ou factoriser) |
| 4 | MINEUR | `FileReceiptStore.cs:183-184` + `FileReceiptStore.Read.cs:82-84` | l'append identique octet pour octet est refusé alors que la lecture pliait ces doublons : une reprise qui rejoue un append identique produit un faux incident de disque, sans test | accepter l'append idempotent, ou documenter et tester |
| 5 | MINEUR | `WriteCircuit.Recovery.cs:15-19` + `Composition.cs:95-96` | toute `IOException` de lecture déclenche l'alerte « Reçus illisibles au démarrage », y compris pour un registre **lisible** mais saturé (plus de 512 reçus non résolus, plus de 64 Mio) ; `GetAwaiter().GetResult()` bloque le démarrage jusqu'à ~2 × délai de verrou | distinguer l'illisible du saturé ; borner/annuler l'attente au démarrage |
| 6 | MINEUR | `AdConnection.cs:738-740` | la branche « codes 16 et 20 » n'appelle ni `MapFailure` ni le trace de repli : la trace technique du refus disparaît pour ces deux codes | tracer le code dans le chemin prouvé |
| 7 | MINEUR | `WritePlans.cs:228` | `ReferenceUsn <= 0` est signalé comme « Nature de changement inconnue » | séparer les deux messages |
| 8 | MINEUR | `WriteReceipts.cs:5-10`, `WriteCircuit.cs:13` | commentaires périmés : la doc annonce un blocage limité à la cible alors que les écritures sont retenues globalement (`ReceiptsPending`), et un plafond fixe de « five minutes » alors que la durée est réglable de 1 à 5 minutes | corriger les commentaires, pas le comportement |
| 9 | MINEUR | `v2/web/js/write-flow.js:424-433` vs `WriteCircuit.Outcome` | le commentaire affirme l'alignement avec `WriteCircuit.Outcome` mais diverge pour (sent, verified, non pendant) ; `write-flow-focus.test.mjs:257` verrouille la divergence par son assertion | aligner les libellés (sans affaiblir l'assertion) ou corriger le commentaire |
| 10 | MINEUR | `L01.md:15` | « table de transitions monotone partagée par les constructeurs et la conservation sur disque » n'est vrai que pour `IsKnown`/`AllowsDelivery` : `Completed`, `Verified`, `Reviewed` portent leurs gardes en ligne et n'appellent pas `CanFollow` | faire passer les constructeurs par la table partagée, ou rectifier l'affirmation |
| 11 | MINEUR | `WriteReceiptStateTests.cs:49-58` | le test de deux instances passe aussi en exécution séquentielle : il prouve l'admission durable, pas l'exclusion pendant la section critique | renforcer (barrière dans le store, ou deux processus) sans retirer l'assertion existante |

Constats **incertains** à trancher avec l'auteur : `AdAccountWriteExecutors.cs:130-145` ne compare
jamais explicitement `user.ObjectGuid` à `plan.Target.ObjectGuid` (l'invariant GUID+DN n'est assuré
que par l'USN scellé et l'adressage `<GUID=…>`) ; `WriteCircuit.cs:102-116` réutilise l'horloge
capturée avant l'attente réseau pour la purge et l'émission de jeton (peut produire un faux
`write.reserved`, dans le sens conservateur) ; `WriteCircuit.cs:339` (préexistant) émet l'étape
`Sending` entre l'append `Sent` durable et `BeginAttempt()` ; l'amnésie du dictionnaire `known`
par instance (lignes supprimées + processus neuf = historique sain vide) contredit l'affirmation de
`features.json` TRV-231 sans `unreadable`.

## Points vérifiés sans défaut

- **Preuve d'envoi** : un seul `BeginAttempt()` (circuit, avec `using` et restauration du parent) ;
  un seul `Sent()` de production, dans `AdConnection.SendRequestAsync` juste avant `SendRequest`,
  après le basculement `sent` ; aucun exécuteur simulé n'appelle `Sent()` ni `BeginAttempt` ; les
  exécuteurs multi-requêtes donnent `Sends > 1`, donc leur refus n'est jamais traité comme une
  preuve de rejet.
- **Absence de rejeu** : jeton à usage unique, `Recall`/`Executed`/`InUse`, `WriteReceipts.Completed`
  refuse toute seconde issue ; `Delivered` réservé aux quatre actions distantes
  (`GpUpdate`, `Run`, `Wake`, `RestartCancel`) et converti en `Unknown` ailleurs ou sans
  `CleanupConfirmed` ; aucune relecture infructueuse n'efface une preuve ni ne crée un `NotApplied`.
- **TRV-228** : durée scellée réellement bornée 1 à 5 minutes (défaut 5), horloge UTC et temps
  monotone contrôlés à quatre endroits (avant précontrôle, après la file, avant reçu, après append
  durable) ; horloge reculée ou plan expiré ne déclenchent ni précontrôle ni envoi.
- **TRV-231** : l'inspection de démarrage n'appelle ni jeton, ni plan, ni envoi, ni relecture réseau,
  et s'exécute avant la création du registre et du shell.
- **TRV-237** : aucune autorisation créée par une erreur — `EnsureWritesFreeAsync` refuse dès
  `unreadable != 0`, `RemoteWriteAccess.Evaluate` bloque au-delà de zéro reçu illisible,
  `AdTransportPrerequisites.Require()` s'exécute avant toute connexion, `AdWriteReadProof` est
  fermé côté défaut (refus, callback, DACL spécialisée ou marqueur de schéma manquant = inconnu,
  jamais un vide inventé).
- **Verrou machine** : lecture des reçus, admission de la version 1 et append dans la même section
  critique ; le rejet de transition n'écrit rien et conserve les preuves.
- **Faux exécuteurs** : l'appel à `DirectoryWriteEvidence.Sent()` dans
  `DirectoryCapabilityRefusalTests` joue le contact natif (même rôle que `SendRequestAsync`) et
  n'esquive aucun garde-fou ; sa face négative (exception sans preuve d'envoi → `Unknown`, jamais
  `NotApplied`) est couverte.
- **Sélecteur critique** : `WriteReceiptStateTests` et `DirectoryNativeWriteBoundaryTests` ajoutés à
  `CriticalTestSelection.Classes` sans exiger de domaine réel ; aucun retrait.
- **Compilation (lecture)** : tous les symboles nouveaux invoqués existent (`WriteResult.Delivered`,
  `VerificationState.Reviewed`, `DomeniaOperationException.DirectoryResultCode`, `WriteTarget` et
  `WriteChange` avec leurs nouveaux membres positionnels, `AdEntry.*`, `FicheEntry.IsKnown`,
  `WriteReceiptStates.*`) et les `using` nécessaires sont présents.

## Affirmations du lot sans couverture de test

1. Conditions fines de l'exception d'annulation du redémarrage différé : opérateur, contrôleur,
   `Mode`/`Simulated` différents, plan non réversible, empreinte erronée, deux changements
   `remote.cancelPlan`.
2. « Avertissement dans Opérations si incertains ou illisibles » : le contenu du journal de
   `RecoverAsync` n'est asserté ni en branche avertissement, ni en branche alerte.
3. Revers d'horloge au niveau du reçu (bornage `when < receipt.At`).
4. Rejets de `CanFollow` : préfixe `Details` raccourci ou altéré, changement de `SentAt`, `Operator`,
   `Mode`, `Simulated`, disparition de `CompletedAt`/`VerifiedAt`.
5. Libération de réservation **à expiration**, et course de deux instances sur la réservation
   (mémoire, mono-processus).
6. `AdTransportPrerequisites.Require()` (paresse et intégration à `EnsureConnectedAsync`).
7. Éviction de capacité des plans et son interaction avec réservations et jetons.
8. Garde-fous de saturation du store (plus de 512 reçus non résolus, budget 64 Mio).
9. TRV-237 « chaque modification exige sa nouvelle confirmation » (aucune assertion nouvelle).
10. `DirectoryWriteEvidence.Attempt` : `Dispose` avec tentative imbriquée non disposée, `RecordSend`
    propagé aux parents après `Dispose`.
11. Rejet de `Verified(..., Reviewed)` et de `Reviewed` sur un reçu non pendant ou illisible.

## Suite donnée à ce lot

Aucune de ces corrections ne peut être validée ici : la liste est à traiter par l'auteur du lot avec
un build disponible, puis requalifiée (sélection critique, suite complète, packs) sur un moyen
d'exécution rétabli. Tant que ce n'est pas fait, `L01.md` garde son état « code et tests en
relecture croisée » et le lot reste non intégré à `master`.
