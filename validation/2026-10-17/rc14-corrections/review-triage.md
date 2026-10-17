# Triage de la revue indépendante (Spark, lecture seule, 2026-10-17)

Source : `review-independent-spark.md` (même dossier), diff audité `review-diff.txt`.
Règle projet : une sortie du Spark est un brouillon à vérifier, pas une preuve. Chaque constat a donc été
confronté au code réel du dépôt (chemins et lignes vérifiés dans cette session). Le verdict « corrections
requises avant ré-épinglage » est examiné constat par constat ci-dessous.

## Constats rejetés comme non-défauts (vérifiés dans le code)

- **#1 « Source posée même sans compte observé » (bloquant selon la revue)** — la lecture
  `Win32_ComputerSystem.UserName` a réellement retourné (propriété lue, valeur vide). `Source` décrit la source
  de la lecture réellement exécutée, et le `Detail` du cas `NoConsole` (Live.Model ligne 581) dit explicitement
  « Lecture réussie : aucun compte renvoyé pour la console ». Aucune certitude de compte n'est affichée :
  `User` reste vide et `CurrentUser` n'est posé que sur `Observed` (ligne 96). Rejeté.
- **#2 « échec → Source/Transport anciens conservés via presenceOnly » (majeur)** — `$presenceOnly` n'est vrai
  que pour `Outcome='PresenceOnly'` (Live.Model ligne 66), c'est-à-dire une demande ping seule, jamais un échec
  (`Timeout`/`Unavailable` gardent leur outcome et prennent les champs vides du résultat). Conserver la mesure
  précédente sur un ping seul est la règle pré-existante (« ping seul conserve »), exercée par les bancs
  point 10 et 127. Rejeté.
- **#4 « $selectedGuid/$selectedCreated non définis dans Refresh-AssociationContext » (majeur)** — définis dans
  la fonction elle-même, `Domenia-Core.ps1:17956-17958`, avant tout usage (17962, 17967, 17983, 17987). Le diff
  ne les montrait pas car ce sont des lignes pré-existantes au patch. Rejeté.
- **#5 « Get-LinksForComputer filtre peut-être déjà les liens Unknown » (majeur)** — le banc dédié
  `Test-DomeniaLinkIdentity.ps1` (22 assertions, 0 échec) exerce les fonctions réelles : un lien hérité sans GUID
  est bien retourné et annoté « identité non vérifiable » dans la grille, l'index et le résumé ; seul un lien
  d'une autre identité prouvée est filtré. Rejeté.
- **#6 « préservation d'IdentityState/Presence après throw non prouvée » (majeur)** — le catch externe du worker
  (Live.Model lignes 582-591) ne reconstruit pas `$answer` : il pose `Outcome`/`Detail` et remplit les sondes
  d'erreurs, sans toucher à `IdentityState` ni `Presence`. La mutation de `$answer` par `Set-LiveIdentityMismatch`
  (portée dynamique PowerShell, le scriptblock du worker définit `$answer` au niveau appelant) a été vérifiée
  séparément par exécution d'un scriptblock jumeau : l'état survit au `throw`. Rejeté comme défaut ; la
  recommandation de test ouvrier réel reste notée en reste-à-faire Windows.
- **#13 « prédicats de famille sensibles à la casse » (mineur)** — les valeurs de `family` de
  `domenia_domain_metadata` sont écrites par le code en constantes (`Directory`/`Presence`/`Inventory`,
  Engine.Worker:680) et les prédicats d'usage ajoutés sont identiques à ceux des suppressions de maintenance
  pré-existantes (Storage.Worker:1662 et 1679). Cohérent avec la convention existante. Rejeté.
- **#15 « deux relevés sans FormatVersion comparés comme même format » (mineur)** — deux relevés sans
  `FormatVersion` sont tous deux d'avant la v2, donc du même ancien format de jeton : les comparer entre eux est
  correct, et v2 (ou absent) face à v3 donne bien `-1` contre `3` → Inconnu/Limitée. Le comportement est le bon.
  Rejeté.
- **#20 « test Point 78 non déterministe si Board utilise Get-Date » (observation)** — `Board` a un paramètre
  `[datetime]$At=$now` (Test-DomeniaHealthAdvanced.ps1:26) avec `$now` fixe du banc. Déterministe. Rejeté.

## Constats reconnus, documentés sans changement de code (choix assumés et déjà exercés)

- **#3 grille/index sans `CreatedUtc` (majeur selon la revue)** — limitation documentée dès le tour 5 et reprise
  dans EXECUTION.json : la grille ne connaît pas la date de création ; un lien hérité sans GUID y reste visible
  mais annoncé « identité non vérifiable », jamais présenté comme une association ordinaire ni comme « aucun
  lien ». C'est l'objectif du point 9 ; passer `whenCreated` par ligne imposerait une lecture par ligne sur le fil
  UI, explicitement écartée.
- **#8 octets de catégorie à -1 dès la table partagée présente (majeur selon la revue)** — choix honnête :
  dbstat mesure des pages entières de la table partagée, tout total partiel serait un double comptage ou une
  estimation inventée. Le total de catégorie est déclaré inconnu (-1), jamais faux. Exercé par le cas
  « RC14 StorageUsage ».
- **#12 familles non listées non comptées (mineur)** — même prédicat que les suppressions de maintenance
  existantes ; le cas de test l'affirme explicitement (« the unlisted family in none »). Si une nouvelle famille
  apparaît, elle relèvera d'une décision de catégorisation, pas d'un comptage silencieux.
- **#16 Transport posé même si la lecture ne retourne aucune instance (mineur)** — la requête a réellement été
  exécutée et a retourné sur la session CIM/DCOM ; « Transport » documente le transport réellement exécuté, pas
  la présence de données. `Transport` n'affirme jamais une valeur de poste.
- **#9/#10 note affichée sur nom vide / unicité après concaténation (mineurs)** — cas limites d'affichage de
  listes déjà triées par nom ; la note ne s'ajoute que sur `Unknown` avec GUID d'objet. Aucun changement ce tour
  pour ne pas élargir le périmètre ; à observer lors de la qualification Windows.
- **#11 Get-AssociationForRow ne regarde que le premier lien (mineur)** — comportement pré-existant au patch
  (`Select-Object -First 1` inchangé) ; le patch ajoute la note sur le lien retourné, sans modifier la sélection.
- **#7 test P-CD-09 (majeur selon la revue)** — le cas P-CD-09 est un test de câblage (champs dits illisibles en
  échec) ; son commentaire dit honnêtement que ses fixtures sans GUID n'atteignent pas l'annotation. La preuve
  comportementale de l'annotation est le banc dédié `Test-DomeniaLinkIdentity.ps1`, pas P-CD-09. Le garde-fou «
  échouer si le nœud AST est absent » est une amélioration de robustesse du banc, notée en reste-à-faire.
- **#17 « Erreur de ping » forcé dans Fail-DomeniaLiveProbe (mineur)** — ligne pré-existante au patch (seuls
  Source/Transport/IdentityState y ont été vidés) ; hors périmètre des cinq points, à traiter séparément si
  David le décide.

## Constats sans effet (observations)

- **#18 portée de `$answer`** — vérifiée par exécution (mutation de référence depuis la portée appelante) ; la
  fragilité « si l'appel est déplacé dans un runspace » est théorique : le corps du worker s'exécute dans un
  seul scriptblock.
- **#19 sondes seules avec `Win32_ComputerSystem` nul** — conforme à « comparaison impossible = comportement
  antérieur » ; la vue affiche alors « Identité du poste : inconnue », jamais une vérification.
- **#21/#22/#23 couverture de tests incomplète sur des cas secondaires** (plusieurs suspensions actives, total
  dbstat d'autres tables, comportement dans WiringRelations) — reste-à-faire honnête, pas des défauts.
- **#24 aucune incompatibilité PS 5.1 visible** — concordant avec `Test-DomeniaPs51Compat.ps1` (337 fichiers,
  0 erreur).

## Décision

Aucune correction de code requise par la revue après vérification : les deux constats bloquant/majeurs qui la
fondaient (#1, #2, #4, #5, #6) sont infirmés par le code réel, pièces à l'appui ci-dessus. Le ré-épinglage des
contrats worker (`tools/update_worker_contracts.py --apply`) et la suite de livraison (SUIVI, packs, commit,
bundle) peuvent s'enchaîner. Les limites reconnues (#3, #8, #12, #16, #9, #10, #11, #7, #21, #22, #23) restent
dans EXECUTION.json et sont rappelées ici ; la qualification Windows 5.1 reste due pour tout le lot.
