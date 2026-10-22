# Spark 02 — Accueil & Rechercher : mode annuaire réel (lecteurs Domenia.Ad)

Agent : OpenCode (relève). Branche : `spark/02-ad-accueil-rechercher`. Arbre : `../sp-02-ad-accueil-rechercher`.
Dernière mise à jour : 22/10/2026, session de reprise après échec de la vérification automatique.

## État de la compilation / des tests

- Compilation VM : non relancée à ce point (dernier état connu : branche à `62e2180`, compile).
- Tests : non exécutés (décision du 21/10 : tests écrits au fil du code, exécutés à la toute fin).

## Fait

- (commit à venir) création de ce fichier de suivi.

## Reste à faire

1. Lire les interfaces cibles (`IAccueilReader`, `ISearchReader`) et les briques `Domenia.Ad` / `Domenia.Inventory`.
2. Implémenter `AdAccueilReader` (lecteur réel Accueil) dans `v2/src/Domenia.Ad/Screens/`.
3. Implémenter `AdSearchReader` (lecteur réel Rechercher) dans `v2/src/Domenia.Ad/Screens/`.
4. Enregistrer les deux lecteurs comme les lecteurs de simulation (découverte automatique `ScreenReaders.Discover`,
   constructeur public unique prenant `AdDirectorySource`, cf. `docs/PLATFORM.md` § 1 et `AdDirectoryTreeReader`).
5. Tests unitaires sans AD réel (`v2/tests/Domenia.Tests/`).
6. Build VM `bash v2/tools/vm.sh s02 build` → 0 erreur, 0 avertissement.

## Questions

- (aucune pour l'instant)
