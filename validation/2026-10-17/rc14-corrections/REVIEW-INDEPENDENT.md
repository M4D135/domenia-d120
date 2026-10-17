# Revue indépendante — Domenia RC1.17.14 (session OpenCode distincte, spark/spark-local)

- Périmètre : `git diff HEAD` (10 fichiers), 3 bancs nouveaux (`Test-DomeniaLinkIdentity.ps1`, `Test-DomeniaLiveTransport.ps1`, `Test-DomeniaLiveIdentity.ps1`), contenu de `validation/2026-10-17/rc14-corrections/`. Lecture seule stricte dans `repo/` ; aucun test VM, aucun scan, aucun appel réseau/cloud, aucun `kbza ask`.
- `reviewed_head` : `31fe5846e5f6a9b821a23df10c23e5d46370addd`
- `diff_sha256` : `98b31d94fe1b14587e95a6007daf1cfd5e40b6b87062d727516b9b40274b8f57` (sha256 de la sortie de `git diff HEAD` à la fin de la revue)
- Les références « diff:L » renvoient aux lignes du fichier de diff tel que produit par `git diff HEAD` (644 lignes).
- **Drift constaté pendant la revue** : le diff audité d'abord (`25db9321…`, 644 lignes) a été modifié en cours de session par une écriture concurrente portant uniquement sur `EXECUTION.json` (documentation du point 4 et du ré-épinglage StorageUsage ; apparition de `review-triage.md`, `review-diff.txt`, `review-independent-spark.md` dans le dossier de validation). Les 9 fichiers de code et les 3 bancs sont identiques octet pour octet entre les deux états : les verdicts de cette revue portent sans changement sur les deux états ; le hash retenu est celui de l'état final.

## Point 4 — StorageUsage : split Presence/Inventory/Directory, octets partagés non double comptés

**Verdict : accepté** (constat de procédure annexé).

Lignes de diff citées :
- diff:L488, L493 — `domenia_domain_metadata` ajouté aux catégories `Observations` et `Index`.
- diff:L501-505 — `$sharedTablePredicates=@{ Observations="WHERE family IN ('Presence','Inventory')"; Index="WHERE family='Directory'" }` — prédicats constants, jamais dérivés du payload.
- diff:L520-525 — pour `domenia_domain_metadata` : `Rows` compté avec le filtre de famille, `$bytes=-1L` (les pages dbstat sont des pages pleine table ; les octets restent inconnus, jamais réattribués).
- diff:L512 — table tolérée absente (ancienne base) : `Rows=0`, `Bytes=0`, `State='Absent'`.

Raison : le leste de la table partagée n'est jamais additionné deux fois (Bytes=-1 dans les deux catégories ; l'agrégat de catégorie propage -1, vérifié dans le code du worker à `Domenia-Storage.Worker.ps1:1567`, hors diff mais inchangé) ; la somme des `Rows` compte chaque ligne une seule fois et la famille non listée (`AdSchema`) dans aucune catégorie. Banc `RC14 StorageUsage…` : 8 assertions, 0 échec (`point4-test.json`, pwsh 7.4.6 Linux, non qualifiant).

Constat : `python3 tools/update_worker_contracts.py` (contrôle hors Windows, lecture seule) signale `StorageUsage` et `RegistryFingerprint` en `ReviewedChangesRequired` — le ré-épinglage est dû. L'état initial du diff ne documentait ce ré-épinglage que pour LiveConsole/LocalStore/LiveSelectedPing ; la mise à jour concurrente de `EXECUTION.json` intervenue pendant la revue ajoute la mention « Ré-épinglage du contrat worker StorageUsage … après revue indépendante » dans le `remaining` du point concerné. Constat donc résorbé dans l'état final ; le ré-épinglage lui-même reste à exécuter (attendu : la revue indépendante est précisément le geste préalable).

## Point 78 — empreinte de politique = ActiveSuspensions seules, FormatVersion 3, Compare = Inconnu si version différente

**Verdict : accepté** (constat annexé).

Lignes de diff citées :
- diff:L267-270 — le jeton de politique ne hache plus que `ActiveSuspensions=@($p.Suspensions|Where-Object{$null -ne (Get-DomeniaHealthSuspension $p $_.RuleId $NowUtc)}|ForEach-Object{[pscustomobject]@{RuleId=…;Reason=…;UntilUtc=…}}|Sort-Object RuleId)` ; le champ `Suspensions` (toutes, y compris expirées) disparaît du jeton.
- diff:L279 — `FormatVersion=3`.
- diff:L290-291 — dans `Compare-DomeniaHealthSnapshots` : sonde locale `$format` (TryParse, défaut -1) ; si les deux relevés n'ont pas le même format, `$policyHash='Unknown'` + limite nommée « comparaison des règles limitée aux compteurs » → `policyStatus='Inconnu'` (diff:L292), jamais « Règles modifiés ».

Raison : purge d'une suspension expirée = empreinte inchangée ; édition d'une suspension active = empreinte modifiée nommée « Règles » ; v2 contre v3 = « Inconnu »/« Limitée ». `Get-DomeniaHealthSuspension` accepte bien un troisième paramètre optionnel `$NowUtc` (`Domenia-HealthRules.Model.ps1:512-513`, hors diff, signature compatible 5.1) — l'appel avec `$NowUtc` est valide et ancre l'activité à l'heure de calcul. Banc `RC14 Point 78` : 6 assertions, 0 échec (`point78-test.json`, pwsh7 Linux, non qualifiant).

Constat : `point78-regression.json` (suite HealthAdvanced complète, rejouée hors VM) montre 1 échec sur 13 : « Suspension validates UTC expiry… », dans `ConvertTo-DomeniaHealthSuspensions` (`Domenia-HealthRules.Model.ps1:507`) — zone que le diff ne touche pas. La baseline `baseline-5.1-r1-summary.json` ne contient pas la suite HealthAdvanced : le caractère préexistant de cet échec ne peut pas être établi depuis le dépôt. À rejouer sous Windows 5.1 avant toute conclusion ; rien dans le diff ne fournit de mécanisme de régression sur ce cas.

## Point 9 — identité de lien non vérifiable annotee, jamais remplacée par « aucun lien »

**Verdict : accepté** (constat mineur annexé).

Lignes de diff citées :
- diff:L113-121 — nouvelle fonction `Get-DomeniaLinkIdentityNote` : sans GUID d'objet, retourne `''` (rien n'est affirmé) ; sinon annote `' · identité non vérifiable'` seulement quand `Test-DomeniaLinkIdentity`.Match = `Unknown`.
- diff:L133 (Get-AssociationForRow, colonne grille), L170 et L180 (Get-SelectedAssociationSummary), L195 et L201 (Get-DomeniaIndexAssociationText), L215 et L228 (Set-RowAssociationMetadata), L238 et L248/L255 (Refresh-AssociationContext) — la règle de la fiche est appliquée à toutes les vues d'association ; un lien dont l'identité n'est pas établie est annoncé, jamais présenté comme association ordinaire.
- diff:L161/L177 — `Get-LinksForComputer`/`Get-LinksForUser` reçoivent `-CreatedUtc $selectedCreated`, lu uniquement depuis l'entrée déjà chargée (diff:L152-153) : aucune lecture ajoutée au fil UI.

Raison : les trois états sont distingués — identité établie (association simple), non vérifiable (annotée), ancienne identité prouvée (filtrée, cohérent avec la fiche ; « Aucun utilisateur lie » n'apparaît que quand la liste de liens est vide, pas pour masquer un Unknown). Banc dédié `Test-DomeniaLinkIdentity.ps1` : fonctions réelles du cœur extraites par AST, liens en mémoire, 0 échec (`point9-test.json`, pwsh7 Linux, non qualifiant) ; `Test-DomeniaWiringRelations.ps1` (diff:L641) et `Test-Domenia.ps1` (diff:L547) chargent l'aide pour ne pas casser les bancs existants.

Constat mineur : `EXECUTION.json` (diff:L29) attribue au banc « 22 assertions » alors que `point9-test.json` (et le code du banc) en compte 16. Le rapport JSON est exact ; la phrase du suivi est à corriger.

## Point 10 — Transport/Source posés seulement après lecture confirmée, un échec ne prétend pas un transport

**Verdict : accepté.**

Lignes de diff citées :
- diff:L334-335 — le worker initialise `Source=''`, `Transport=''` (plus de `Source='CIM/DCOM · Win32_ComputerSystem.UserName'` anticipé).
- diff:L383-384 — `$answer.Transport='CIM/DCOM'` posé dans `Invoke-WSharedRead` seulement après qu'un `Get-CimInstance` a réellement retourné ; diff:L442 (lecture ProductType) et diff:L450-451 (énumération de détails) idem.
- diff:L399-400 — `$answer.Source='CIM/DCOM · Win32_ComputerSystem.UserName'` posé uniquement après la lecture confirmée de `Win32_ComputerSystem.UserName`.
- diff:L304 — `ConvertTo-DomeniaLiveObservation` propage `Transport` (ping seul : valeur de la dernière mesure conservée, jamais inventée).
- diff:L314-325 — vue : `Transport : inconnu (donnée ancienne ou lecture non confirmée)` / `Source : inconnue` quand absent.
- diff:L459-466 — `Fail-DomeniaLiveProbe` : `Source=''`, `Transport=''`, `IdentityState=''` sur échec ; le dernier compte observé n'est pas remplacé.
- diff:L479 — `Transport` ajouté à la liste blanche de persistance SQLite.

Raison : la chaîne complète (pose après lecture, propagation, affichage, persistance, échec discret) est couverte par `Test-DomeniaLiveTransport.ps1` : 20 assertions, 0 échec (`point10-test.json`), rejouée sans régression après le patch 127 (`point127-regression.json`, mêmes 20 assertions). Le contrôle textuel du code réel du worker (diff du banc, L99-104) vérifie l'ordre initialisation/lecture. Non qualifiant hors Windows ; ré-épinglage LiveConsole/LiveSelectedPing/LocalStore explicitement porté en `remaining` (diff:L59) — constant `ReviewedChangesRequired` confirmé par le contrôle hors Windows.

## Point 127 — identité hote vérifiée avant les sondes, incoherence = rejet nommé sans panne inventee, Presence conservee

**Verdict : accepté.**

Lignes de diff citées :
- diff:L344-369 — `Get-LiveHostIdentityCheck` renvoie `@{Comparable;Mismatch}` : cible adresse IP, réponse nulle ou sans noms = `Comparable=$false` (comparaison impossible, jamais un refus, jamais une vérification) ; les identités acceptées (libellé DNS, NetBIOS tronqué à 15, cn face à un nom long, `Name` seul) sont conservées ; `Get-LiveHostMismatch` devient l'enveloppe (diff:L370).
- diff:L371-376 — `Set-LiveIdentityMismatch` : `IdentityState='Incohérente'` ; si `Presence` commence par « En ligne », le fait brut ICMP est conservé en tête du détail et une note « identité du poste contredite, présence conservée comme fait brut » est ajoutée. Aucune mutation de `Presence`.
- diff:L421-433 — porte d'identité des sondes seules : à défaut de `$system` déjà vérifié, lecture `Win32_ComputerSystem (Name, DNSHostName)` sur la même session via la lecture partagée, avant tout plan de sondes (vérifié dans le fichier : porte ligne 495, plan ligne 509) ; incohérence confirmée = `Set-LiveIdentityMismatch` puis `throw` nominal (« Le poste qui répond à … se nomme … », aucune donnée attribuée), pas une panne réseau ; comparaison possible = `IdentityState='Vérifiée'`.
- diff:L394-397 et L410-413 — mêmes règles sur les chemins console et inventaire.
- diff:L479 et L91 — `IdentityState` propagé (`ConvertTo-DomeniaLiveObservation`, diff:L304), persisté (liste blanche) et affiché (diff:L319-323 : confirmée / incohérente / inconnue, trois états explicites).

Raison : `Test-DomeniaLiveIdentity.ps1` exerce les fonctions réelles extraites par AST du corps épinglé (mêmes poste/autre poste/adresse/nulle/sans noms/cn tronqué/Name seul ; `Set-LiveIdentityMismatch` sur la vraie forme de réponse, avec et sans ping ; persistance `"IdentityState":"Incohérente"` ; ordre porte-avant-plan dans le code texte du worker) : 31 assertions, 0 échec (`point127-test.json`, pwsh7 Linux, non qualifiant). Le banc Point 10 rejoué après patch reste vert.

## PS 5.1 / secrets

- BOM UTF-8 présent et fins de ligne LF sur les 9 fichiers `.ps1` modifiés et les 3 bancs nouveaux (contrôle `od`/`grep \r`, hors diff).
- Aucune syntaxe PowerShell 6/7 dans le diff : pas de ternaire, `??`, `&&`/`||`, `-Parallel`, `TryAdd`, `GetRelativePath` ; `[int]::TryParse`, `-in`, `[ordered]`, `Sort-Object <prop>`, interpolations `$(…)` sont 5.1-valides ; les accents des nouveaux textes d'interface utilisent `ʼ` (U+02BC) ou l'échappement backtick, pas de guillemets typographiques délimiteurs.
- Aucun mot de passe, jeton ou secret dans le diff, les bancs ou `validation/2026-10-17/rc14-corrections/` (uniquement GUID factices `00000000-…`/`11111111-…`, domaines `example.invalid`/`dc=test`).
- Les rapports de validation sont explicitement marqués « pwsh7 Linux, non qualifiant » ; aucun ne prétend une preuve 5.1. Conformément à la décision du 2026-10-17 consignée dans `EXECUTION.json` (diff:L13), aucun test VM n'a été exécuté et rien n'est déclaré `acceptance_passed`.

## Verdict global

**constats** — les cinq points (4, 78, 9, 10, 127) sont **acceptés** sur le fond : le diff corrige réellement les comportements visés, sans régression visible dans le périmètre lisible, sans secret, en écriture compatible 5.1. Constats accompagnant l'acceptation, aucun ne constituant une régression :
1. ré-épinglage des contrats worker dû (`LiveConsole`, `LocalStore`, `LiveSelectedPing`, `StorageUsage`, `RegistryFingerprint`) — documenté dans `EXECUTION.json` à l'état final du diff (la mention StorageUsage a été ajoutée par l'écriture concurrente de fin de session) ; à exécuter après la revue ;
2. échec préexistant-non-confirmé « Suspension validates UTC expiry » sous pwsh7 (zone non touchée, suite absente de la baseline) — à rejouer sous Windows 5.1 ;
3. écart de comptage d'assertions (22 annoncés / 16 réels) pour le banc Point 9 dans `EXECUTION.json` (toujours présent à l'état final du diff) ;
4. écriture concurrente dans le dépôt pendant la revue (voir « Drift constaté ») : à prendre en compte pour lier un rapport à un hash, lier le rapport au hash final `98b31d94…`.

Aucune qualification Windows : la preuve 5.1 liée au ZIP de livraison reste à produire, comme le dit le suivi.
