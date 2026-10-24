# SPARK-READY-008-FIX1 — compilation CS1503 et deux défauts de revue corrigés

Snapshot046 Debug : 1 erreur CS1503 (SharedParkMergeTests.cs:166), 0 avertissement. Correctif appliqué aux deux seuls fichiers
autorisés, à partir des sources exactes jointes (MICRO008-FIX1-SOURCES.txt) et du journal VM046. Rien d’autre touché ; lots006/007
non refaits ; aucun build/test exécuté ici ; wrapper `CompatibleDirectoryCache.SharedPark.cs` et quatre WIP natifs intacts.

## Éditions

1. `v2/tests/Domenia.Tests/SharedParkMergeTests.cs` — ligne 166 : `rows.Reverse()` et `remote.Reverse()` (résultats `IEnumerable`)
   sont matérialisés explicitement dans le type attendu : `LocalRows([.. rows.Reverse()])` et `[.. remote.Reverse()]`. Scénario
   d’ordre inversé inchangé (mêmes lignes, mêmes gagnantes, mêmes octets encodés).
2. `v2/src/Domenia.Store/Sqlite/SharedParkMerge.cs` — `SelectLocalWinners` refuse désormais la génération d’en-tête :
   `local.Generation < 0` refusé, et `local.Generation != sweeps.Generation` refusé (message nommant la divergence), en plus du
   contrôle existant sur `sweeps.Generation`. Aucune donnée modifiée : c’est une cohérence de données, pas un CAS physique — la
   relecture physique, la liaison `Exists`/store/domaine/révision/génération/SHA et le contrôle d’époque restent au raccordement
   suivant, avant toute écriture ; l’empreinte de résumé n’est toujours pas prise pour preuve.
3. `v2/src/Domenia.Store/Sqlite/SharedParkMerge.cs` — `Preview` vérifie le jeton avant la phase tri/matérialisation/encodage de
   validation, puis de nouveau immédiatement avant le retour : une annulation déjà acquise en fin de qualification ne peut plus
   produire un succès. Aucun changement au codec006 ni à son contrat ; vérifications existantes (entrée et dans chaque parcours)
   conservées.
4. `v2/tests/Domenia.Tests/SharedParkMergeTests.cs` — test pur ciblé ajouté, `The_header_generation_must_match_the_carried_survey` :
   génération d’en-tête positive identique admise ; négative avec relevé valide refusée ; positive divergente refusée (en dessous
   comme au-dessus). Aucun test temporisé non déterministe ajouté ; le test d’annulation préalable est conservé tel quel.

## Comportements008 conservés

Sélection par nom/date, égalité locale GUID puis `StorageKey` ordinal, stricte priorité de date distante, égalité gardant le local,
préservation des identités/compteurs/sources, bornes réelles 50 000/16 Mio mesurées par le codec sans troncature, refus des
données ambiguës (doublons distants, dates absente/sentinelle/future, contrôle/U+FEFF, instantané incohérent, tableau default),
zéro disque/réseau/écriture/verrou, aucune mutation de l’instantané.

## Attente

Compilation Debug/Release par Codex dans la VM Windows (snapshot suivant), diagnostics renvoyés à cette même session. La fusion
compilée ne termine pas SharedPark : lecture explicite du partage avec chemins/reparse qualifiés, preuve/aperçu expirant,
intention/publication/vérification durables et raccordements restent à faire.
