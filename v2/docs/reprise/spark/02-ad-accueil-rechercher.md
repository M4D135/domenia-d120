# Reprise — lot 02 · « Mode annuaire » des écrans Accueil et Rechercher

Branches et arbre : `spark/02-ad-accueil-rechercher`, arbre `../Domenia-D120-team/sp-02-ad-accueil-rechercher`.
Tenu à jour par l'agent Spark à chaque étape. Dernière mise à jour : 23/10/2026 (début de session, après un premier
essai resté sans effet).

## Mission

Implémenter dans `v2/src/Domenia.Ad/Screens/` les lecteurs réels des interfaces `IAccueilReader`
(`Domenia.Core/Screens/Accueil`) et `ISearchReader` (`Domenia.Core/Screens/Search`, écran « Rechercher »), en
s'appuyant sur `AdDirectorySource`, `AdDirectoryReader`, `AdDirectoryMapper` et `WmiWorkstationProbe` déjà présents,
suivant les sections « Mode annuaire » de `docs/ops/accueil.md` (§ 16) et `docs/ops/rechercher.md` (§ 7).
Requêtes LDAP paginées et bornées, budgets, jamais tout le domaine sans garde. Enregistrement automatique comme les
lecteurs de simulation (`ScreenReaders.Discover` : classe publique, un seul constructeur public prenant la source).
Tests unitaires sans AD réel.

## État de la compilation et des tests

- Compilation VM (`bash v2/tools/vm.sh s02 build`) : non relancée à ce jour dans cette session.
- Suite C# : 791/791 sur la branche au départ (vérification automatique du 22/10, commit `62e2180`).

## Fait

| Étape | Fichiers | Commit |
|---|---|---|
| Document de reprise initial | `v2/docs/reprise/spark/02-ad-accueil-rechercher.md` | (ce commit) |

## Reste à faire

1. `AdSearchReader` (`src/Domenia.Ad/Screens/AdSearchReader.cs`) : `ISearchReader` sur LDAP paginé et borné
   (docs/ops/rechercher.md § 7.1 et 7.2) + lectures locales sur l'image de session de `AdDirectorySource`.
2. `AdAccueilReader` (`src/Domenia.Ad/Screens/AdAccueilReader.cs`) : `IAccueilReader` (docs/ops/accueil.md § 16) :
   faits locaux, BitLocker (LDAP borné, jamais la racine, jamais une clé), inventaire ciblé par la sonde.
3. Tests unitaires `tests/Domenia.Tests/AdScreenReadersTests.cs` avec une fausse connexion `IAdConnection` et une
   fausse sonde (aucun AD réel, aucun réseau).
4. Compilation VM `s02 build` jusqu'à 0 erreur et 0 avertissement.

## Choix et limites assumés (à relire par Claude)

- Base locale : `Domenia.Store` (base SQLite) n'existe pas encore (tâche s1). Les lectures « base locale »
  (`CachedAsync`, `SuggestAsync`, `PreviewAsync`, `CompareAsync`, `LocalRowsAsync`, `LocalQueryAsync`) s'appuient sur
  l'image de l'annuaire déjà lue dans la session (`AdDirectorySource.CurrentDirectory`) et les mesures de la session
  (`CurrentObservations`) : rien du tout avant la première lecture de l'annuaire, jamais de réseau pour ces lectures.
- Adresses IPv4/MAC et utilisateur console : portés par `Domenia.Store` et le CIM complet plus tard ; le lecteur réel
  répond « non lu » (absence jamais présentée comme une preuve).
- Sondes de l'Accueil (`CollectProbesAsync`) : le catalogue de sondes exige un lecteur CIM par classe, absent de cette
  version ; chaque lecture est rendue « non lue » avec son motif, jamais un faux chiffre.
- Instantanés quotidiens (`HistoryAsync`) et relevés (`CollectionRun`) : magasin `Domenia.Store` à venir ; rendus vides
  (jamais inventés).
- Tri des listes : par `name` (ordre ordinal insensible à la casse, comme le `caseIgnoreString` d'AD), clé de reprise
  `(name>=<dernière clé>)` ajoutée au filtre, DN déjà chargés écartés — conforme docs/ops/rechercher.md § 7.1.

## Questions (pour la relève ou Claude)

- (aucune à ce jour)
