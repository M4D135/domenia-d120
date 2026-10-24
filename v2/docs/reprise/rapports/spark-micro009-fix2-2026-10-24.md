# SPARK-READY-009-FIX2 — un seul défaut corrigé : exposants Unicode, pas indices

MICRO009-FIX2 exécuté en session native neuve (la précédente, `ses_e941beb2effe7KMR6RmRPrSo3l`, a terminé naturellement après son
rapport FIX1 ; historique et fichiers conservés, non rechargés). Mandat, deux sources exactes jointes et journal VM049 lus :
Debug et Release réussis, 0 avertissement / 0 erreur, 33 s, suites non exécutées. Socles006/007/008 déjà intégrés, non refaits.
Corrections FIX1 conservées telles quelles : lien symbolique réel à la place de `CreateJunction`, `File.GetAttributes` à la place
de la sentinelle `Attributes = -1`, gardes d'ambiguïté serveur/partage UNC, vérifications d'annulation finales. Aucun build,
aucun test exécuté ici, aucune dépendance téléchargée, aucun service/runtime/réseau modifié, aucun commit, push, reset ni clean.

## Défaut confirmé et correctif de points de code

La liste `ReservedDeviceNames` de `SharedParkRemoteReader` alignait six entrées sur les **indices** U+2081/U+2082/U+2083
(`\u2081` ₁, `\u2082` ₂, `\u2083` ₃, SUBSCRIPT ONE/TWO/THREE) au lieu des **exposants** U+00B9/U+00B2/U+00B3
(`\u00B9` ¹, `\u00B2` ², `\u00B3` ³, SUPERSCRIPT ONE/TWO/THREE) que Windows réserve réellement avec `COM`/`LPT`. Double effet
inverse : `COM₁.tsv` et `LPT₃.tsv`, noms ordinaires, étaient refusés, alors que `COM¹.tsv` et `LPT³.tsv`, vrais noms réservés,
passaient.

Les six entrées sont remplacées par les exposants exacts, dans le même ordre COM¹ COM² COM³ LPT¹ LPT² LPT³, et le commentaire
anglais de `QualifiedComponent` dit désormais « superscripts » en nommant les deux familles de points de code. La comparaison reste
`OrdinalIgnoreCase` : elle ne replie pas un exposant en chiffre, les six entrées sont donc bien nécessaires, et elle ne replie pas
davantage un indice en chiffre — c'est ce qui rend les indices acceptables. Les U+2081/U+2082/U+2083 cessent d'être classés
réservés par cette règle ; ils n'ont jamais été des caractères interdits, ni des caractères de contrôle.

Source primaire (déjà vérifiée, aucune navigation) :
https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file — noms réservés `COM¹`/`COM²`/`COM³` et `LPT¹`/`LPT²`/`LPT³`.

## Cas de régression

Test `Dos_reserved_device_names_are_refused_in_any_component`, purement lexical (aucun accès disque ni réseau, comme avant) :

- refus des **six** vrais noms réservés avec extension : `COM¹.tsv`, `COM².tsv`, `COM³.tsv`, `LPT¹.tsv`, `LPT².tsv`, `LPT³.tsv`
  (écrits en échappements `\u00B9`/`\u00B2`/`\u00B3` pour qu'aucun éditeur ni copier-coller ne remplace un caractère par son
  voisin visuellement identique) ;
- assertions explicites d'acceptation des voisins ordinaires : `COM₁.tsv` (U+2081) et `LPT₃.tsv` (U+2083) sont qualifiés et
  rendus canoniques, plus la phrase de cause qui nomme l'indice concerné ;
- assertions préexistantes inchangées : `CON` comme répertoire, `nul.tsv`, `COM2.tsv` refusés ; `console.tsv` et `COMX.tsv` admis.

Les treize autres tests sont inchangés, notamment les gardes de protection (base active et sidecars, fichier de configuration,
descendants de répertoire protégé, listes `default` et hors limites) et les gardes de lecture (octets et empreinte d'origine,
vide présent distinct d'absent, parent absent, cible dossier, données invalides sans réécriture, annulation préalable, lien
symbolique de répertoire refusé). Rien n'est affaibli. Le reste du chemin (serveur, partage, autres composants) reste qualifié
par les mêmes règles d'ambiguïté.

## Fichiers modifiés (uniquement les deux sources009)

- `v2/src/Domenia.Store/Sqlite/SharedParkRemoteReader.cs` — les six entrées réservées en exposants U+00B9/U+00B2/U+00B3, et le
  commentaire `QualifiedComponent` qui distingue exposants réservés et indices ordinaires.
- `v2/tests/Domenia.Tests/SharedParkRemoteReadTests.cs` — **14 tests écrits, non exécutés** : six refus d'exposants, deux
  acceptations d'indices, refus et acceptations antérieurs conservés.

Le rapport `SPARK-READY-009-FIX1.md` reste en l'état comme preuve historique ; il n'est ni réécrit ni supprimé. Sa ligne sur les
« exposants 1/2/3 (U+2081…U+2083) » décrivait le défaut corrigé ici.

## Limites inchangées et honnêtes

Un build vert ne prouve pas que les suites passent : **toutes les suites restent non exécutées**, réservées à la phase finale
dans la VM Windows. Gardes de lecture avant/après, jamais verrou, CAS ni atomicité ; aucune publication, aucune écriture, aucune
création en lecture, aucune configuration lue ; relecture sous verrou, identité physique, double CAS, aperçu expirant/spool borné
et intention durable restent au lot de publication. Codec006, lecteur007, fusion008, wrapper SharedPark non compilable et quatre
WIP natifs intacts ; `dev/` en lecture seule, WAPT exclu. Aucun accès AD ni SMB dans ce lot.

## Attente

Codex relit, recompile Debug/Release **uniquement dans la VM Windows**, préserve les changements concurrents déjà présents dans
l'arbre et renvoie les diagnostics à cette session. Le mandat ne termine que le défaut Unicode009 ; le projet reste incomplet
(aperçu expirant/spool borné, intention/publication/vérification durable, raccordements annuaire/simulation/UI et reste du
catalogue, puis validation dans les deux VM et publication v2.0.0 seulement si tout est vert).
