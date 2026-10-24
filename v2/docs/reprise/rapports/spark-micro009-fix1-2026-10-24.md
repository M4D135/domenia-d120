# SPARK-READY-009-FIX1 — lecture qualifiée : quatre corrections, deux sources touchées

MICRO009-FIX1 exécuté à partir du mandat, du journal VM048 (Debug en échec sur CS1061, zéro avertissement ; Release non tenté),
des deux sources exactes jointes et de la revue sourcée. Socles006/007/008 non refaits, wrapper non compilable et quatre WIP
natifs intacts, aucun autre fichier touché. Aucun build, aucun test exécuté ici.

## Corrections réellement appliquées

1. **CS1061 (fixture de reparse)** — `DirectoryInfo.CreateJunction` (inexistant dans le SDK installé) remplacé par
   `Directory.CreateSymbolicLink` pour un vrai lien de répertoire temporaire, libéré uniquement dans le `finally`. Scénario et
   messages renommés en « lien symbolique » : rien ne prétend créer une jonction avec un lien. L'échec de création de la fixture
   n'est pas avalé : il fait échouer le test, sans le transformer en succès.
2. **Absence terminale faussement classée reparse** — `QualifyTerminal` et `QualifyDirectory` lisent désormais les attributs par
   `File.GetAttributes` (lève une vraie exception), plus jamais `FileInfo.Attributes`/`DirectoryInfo.Attributes` et leur sentinelle
   `(FileAttributes)(-1)`. Seule `FileNotFoundException` est tolérée pour le terminal (absence réelle, `Exists=false`) ; parent
   manquant/inaccessible et toute autre erreur d'accès ou de réseau restent des échecs enveloppés, jamais convertis en absence.
   Aucune utilisation de `Exists` pour qualifier. Le test existant « vide présent distinct d'absent » exerce exactement ce chemin
   (l'absent ne passe plus par le bit reparse) ; ses assertions sont inchangées.
3. **Qualification lexicale des noms UNC et exposants DOS** — les règles d'ambiguïté (jamais vide, jamais dot/dotdot, pas
   d'espace ni point final, pas de caractère interdit, pas de nom DOS réservé) sont appliquées aux noms de serveur et de partage
   comme aux composants, via un contrôle unique `QualifiedComponent` ; aucune normalisation silencieuse. Noms réservés complétés
   par COM/LPT avec exposants 1/2/3 (U+2081…U+2083). Nouveaux cas de régression purs, réseau jamais ouvert : `\\serveur\..\…`,
   `\\..\partage\…`, `\\serveur\partage.\…`, `\\serveur\partage \…`, `\\serveur.\…`, `\\CON\…`, `\\serveur\con\…`,
   `COM₁.tsv`, `LPT₃.tsv` refusés ; voisins ordinaires conservés : `\\serveur.local\partage.données\parc.tsv`, `COMX.tsv`,
   `console.tsv` admis.
4. **Annulation finale** — jeton vérifié avant l'accès terminal dans `QualifyTree` et immédiatement avant le retour de
   `ReadAsync`, après la seconde requalification. Aucun test temporisé instable ajouté, codec inchangé.

## Fichiers modifiés (uniquement les deux sources009)

- `v2/src/Domenia.Store/Sqlite/SharedParkRemoteReader.cs` — points 2, 3, 4 (+ commentaires documentant la sentinelle évitée et
  les règles serveur/partage).
- `v2/tests/Domenia.Tests/SharedParkRemoteReadTests.cs` — **14 tests écrits, non exécutés** : fixture en lien symbolique
  renommée, un nouveau test d'ambiguïté serveur/partage, cas exposants et voisins ajoutés au test des noms réservés.

## Limites inchangées et honnêtes

Gardes de lecture avant/après, jamais verrou, CAS ni atomicité ; aucune publication, aucune écriture, aucune création en
lecture, aucune configuration lue ; relecture sous verrou, identité physique, double CAS, aperçu expirant et intention durable
restent au lot de publication. Tests exécutables seulement dans la VM Windows en phase finale.

## Attente

Codex relit et recompile Debug/Release dans la VM avant toute intégration, et renvoie les diagnostics à cette session.
