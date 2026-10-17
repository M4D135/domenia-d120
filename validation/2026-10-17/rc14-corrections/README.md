# RC1.17.14 — cinq corrections restantes, 17 octobre 2026

Travail demandé par David : corriger les cinq points restants (4, 78, 9, 10, 127) en full Spark via OpenCode CLI, mettre le suivi à jour, sans aucun test VM, puis commit et bundle en vue du push GitHub par le Mac. Base : `31fe5846e5f6a9b821a23df10c23e5d46370addd` (RC1.17.13). Moteur : spark/spark-local via OpenCode exclusivement ; la revue indépendante a été lancée par le superviseur dans une session OpenCode distincte en lecture seule.

## Corrections livrées

- **Point 4 — occupation de la base** : `Get-DomeniaStorageUsageWorkerCode` (worker `StorageUsage`) compte désormais `domenia_domain_metadata` dans les catégories cohérentes avec la purge des familles (Presence/Inventory et Directory), sans double comptage, et accepte une ancienne base sans cette table.
- **Point 78 — empreinte des règles de santé** : le jeton de politique de `Set-DomeniaHealthSnapshotMetadata` ne hache plus que les suspensions actives (RuleId/Reason/UntilUtc triés) filtrées sur l'heure de calcul ; purger une suspension expirée ne change plus l'empreinte. `FormatVersion` passe à 3 ; face à un relevé d'un autre `FormatVersion`, `Compare-DomeniaHealthSnapshots` déclare `PolicyHash` « Inconnu » (catégorie « Limitée », note dans `Limits`) au lieu d'un faux « Règles modifiées ».
- **Point 9 — identité des associations** : la règle de la fiche est centralisée dans `Get-DomeniaLinkIdentityNote` ; colonne Association de la grille, résumé de sélection et contexte d'association annotent désormais « identité non vérifiable » pour les liens sans GUID dont l'identité n'est pas établie, sans jamais remplacer un état inconnu par « aucun lien » ; les liens d'une autre identité prouvée restent filtrés en amont ; le résumé passe `whenCreated` lu depuis l'entrée déjà chargée (aucune lecture ajoutée au fil UI).
- **Point 10 — transport réellement utilisé** : le worker Live ne pré-remplit plus `Source` ; le nouveau champ `Transport` n'est posé à `CIM/DCOM` qu'après une lecture CIM réellement revenue ; le paquet d'échec de `Fail-DomeniaLiveProbe` n'affirme plus de fournisseur ; la vue affiche « Transport : CIM/DCOM » ou « Transport : inconnu (donnée ancienne ou lecture non confirmée) » ; `Transport` est propagé par `ConvertTo-DomeniaLiveObservation` (ping seul conserve) et persisté par la liste blanche du résumé SQLite.
- **Point 127 — identité des sondes seules et présence** : `Get-LiveHostIdentityCheck` rend si la comparaison était possible (`Comparable`) ; à défaut de console ou d'inventaire vérifié, le worker lit `Win32_ComputerSystem` (Name, DNSHostName) sur la même session via la lecture partagée avant tout plan de sondes ; incohérence confirmée = rejet nominal (aucune valeur attribuée à la cible) ; le ping reste un fait brut : `Presence='En ligne'` est conservée, `PresenceDetail` note l'identité contredite et `IdentityState='Incoherente'` est posé, propagé à la vue (« Identité du poste : confirmée / incohérente / inconnue ») et à la persistance.

## Bancs comportementaux ciblés (hors VM, pwsh 7.4.6 Linux — non qualifiants pour PowerShell 5.1)

| Banc | Résultat | Rapport |
| --- | --- | --- |
| `Test-DomeniaStorageMaintenance.ps1 -CaseFilter 'RC14 StorageUsage'` (vraie base SQLite temporaire) | 1 cas, 8 assertions, 0 échec | `point4-test.json` |
| `Test-DomeniaHealthAdvanced.ps1 -CaseFilter 'RC14 Point 78'` | 1 cas, 6 assertions, 0 échec | `point78-test.json` |
| `Test-DomeniaHealthAdvanced.ps1` (régression) | 12/13, identique à HEAD sans le patch (échec préexistant `ConvertTo-DomeniaHealthSuspensions` sous pwsh7 Linux) | `point78-regression.json` |
| `Test-DomeniaLinkIdentity.ps1 -CaseFilter 'RC14 Point 9'` (nouveau banc, fonctions réelles du cœur extraites par AST, liens en mémoire) | 1 cas, 22 assertions, 0 échec | `point9-test.json` |
| `Test-DomeniaLiveTransport.ps1 -CaseFilter 'RC14 Point 10'` (nouveau banc, worker épinglé inclus) | 1 cas, 20 assertions, 0 échec | `point10-test.json` |
| `Test-DomeniaLiveIdentity.ps1 -CaseFilter 'RC14 Point 127'` (nouveau banc, porte d'identité des sondes) | 1 cas, 31 assertions, 0 échec | `point127-test.json` |
| `Test-DomeniaLiveTransport.ps1` (régression après point 127) | 1 cas, 20 assertions, 0 échec | `point127-regression.json` |

Fumées ciblées complémentaires : `point9-smoke.txt` (5/5), `point10-smoke.json` (9/9, script `point10-smoke.ps1`).

## Revue indépendante

Rapport de la session OpenCode distincte en lecture seule (superviseur) : `REVIEW-INDEPENDENT.md` — **les cinq points acceptés, aucun bloquant**, trois constats annexes confrontés au dépôt (deux reconnus sans changement de code : ré-épinglage dû, échec pwsh7 préexistant à trancher sous 5.1 ; un infirmé : comptage des assertions du banc point 9). Trace du brouillon de revue antérieur écarté par décision superviseur (revue jamais via `kbza ask`) : `review-independent-spark.md`, `review-diff.txt`, `review-triage.md`.

## Contrôles hors Windows (aucun test VM, décision David du 17 octobre)

| Contrôle | Résultat |
| --- | --- |
| `Test-DomeniaPs51Compat.ps1 -Root dev` | 337 fichiers, 0 erreur |
| `validate_powershell_static.py` | PASS |
| Parsing AST des fichiers modifiés + here-strings épinglées | 0 erreur ; UTF-8 BOM/LF conservés |
| `update_worker_contracts.py --apply` (après revue acceptée) | LiveConsole/LiveSelectedPing `1E707756…`, LocalStore `DAA5DD65…`, StorageUsage `C3634994…` ; empreinte du registre `972AFB69…` ; `ReviewedChangesRequired` vide (94 opérations) ; dérive préexistante RegistryFingerprint soldée |
| `licence_inventory.py --check`, `doc_sync.py --check` | PASS (`Publishable: false` : captures et licences NonEtablie, connu) |
| Packs RC14 `build_packages.py` (PROD+DEV) | ReleaseGuard PASS, `Publishable: false` faute de rapport Windows 5.1 lié aux ZIP |

## Qualification encore ouverte

Aucune exécution sous Windows PowerShell 5.1 de ces correctifs et bancs (tests VM interdits par la consigne) : `acceptance_passed` reste faux et les packs ne sont pas publishables. L'échec pwsh7 « Suspension validates UTC expiry » (préexistant, hors du patch) reste à trancher sous 5.1. Qualification humaine, domaine réel, captures, licences et signature restent ouverts, hors périmètre de ces cinq corrections.
