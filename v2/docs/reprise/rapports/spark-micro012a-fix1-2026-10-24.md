# READY 012A-FIX1 — corrections ciblées du codec d’intention

Micro-tâche FIX1 terminée côté OpenCode. Édition regroupée des **deux seuls** fichiers
applicatifs (`SharedParkIntentDocument.cs`, `SharedParkIntentDocumentTests.cs`) + ce rapport.
Aucun autre fichier touché. Périmètre pur conservé : aucune I/O (fichier, SQLite, partage, ACL,
processus), aucune compilation ni exécution de test ici. Codex compile058 sous Windows.

## Compilation — les trois CS0246 corrigés

`ObjectNode` n’existe pas dans `System.Text.Json.Nodes` ; remplacé par l’API réelle **`JsonObject`**
aux trois signatures (`BatchNode`, `BackupNode`, `ValidIntentNode`) **et** à toutes les constructions
et usages du même fichier (`new JsonObject { … }`, casts `(JsonObject)node["batch"]`). Aucun nouveau
package. Le compilateur s’arrêtait aux lignes 70/80/82 ; tout le fichier a été revu au-delà.

## Six points de revue — corrections effectives

1. **ObjectNode → JsonObject** : fait (ci-dessus).

2. **Contrat d’absence aligné sur les sources compilées.** `Validate` n’exige plus d’empreintes
   vides quand `LocalExists`/`RemoteExists` est faux : `RowsFingerprint`, `LocalFingerprint` et
   `RemoteSha256` sont **toujours** des SHA-256 64 hex (les lecteurs produisent `Hash([])` et le
   `Fingerprint` d’une balayure vide — `AbsentSharedParkLocal`, `SharedParkFile.ReadFile` sur
   FileNotFound). Les drapeaux de présence et les références nulles restent le seul porteur de
   l’absence ; aucune normalisation en chaîne vide, aucun lecteur modifié. `MakeBatch(false…)`
   porte désormais des empreintes d’absence réelles ; nouveau test aller-retour purement mémoire
   `Roundtrip_with_real_absence_fingerprints`.

3. **Schéma complet.** `CheckShape` exige désormais la **présence de toutes** les propriétés de
   chaque objet (enveloppe, intention, lot, références) en plus du refus inconnues/doublons.
   `ReadBackup` requiert la **clé** et n’accepte `null` que comme valeur JSON explicite. Un aperçu
   avec drapeau faux ne peut plus faire disparaître `sqliteBackup`/`tsvBackup`. Nouveaux tests :
   `Missing_backup_key_is_refused` (clé retirée, drapeau faux → refus) et
   `Explicit_null_backup_accepted_when_absent` (null explicite acceptée quand le drapeau est faux).

4. **Bornes avant empreinte/sérialisation.** `EnsureScalarsBounded` borne toute chaîne scalaire
   (`MaxScalarLength = 8192`) **avant** `SharedParkIdentity.Fingerprint` et toute allocation de
   `Build`, donc une identité `StoreId`/`DomainDn` arbitrairement grosse est refusée avant calcul
   d’empreinte. Le contrôle post-sérialisation des 64 Kio reste en filet pour la croissance après
   échappement JSON. Aucun nouveau format imposé pour `StoreId`. Nouveaux tests :
   `Oversized_identity_is_refused_before_fingerprint` (StoreId 100 000 caractères → `ArgumentException`
   précis contenant « caractères ») et `Metadata_that_grows_after_escaping_is_refused` (scalaires à
   la limite brute qui dépassent 64 Kio après échappement → `ArgumentException`).

5. **Qualification lexicale canonique.** `Batch.Path` passe par `IsCanonicalWindowsFilePath`
   (fichier canonique local **ou** UNC, sans racine/partage seul, sans dot/dotdot, sans espace/point
   final, sans caractère interdit, sans nom DOS réservé), calquée sur `SharedParkRemoteReader.QualifiedComponent`
   — purement lexicale, **aucun** appel de lecteur de fichier. La comparaison de collisions porte donc
   sur des chemins canoniques (l’alias `C:\backups\x\..\park.tsv` vs copie `C:\backups\park.tsv` est
   refusé à la qualification). `QualifiedComponent` garde les exposants DOS réservés **U+00B9/²/³**
   (COM¹/LPT²) et ne les confond pas avec les indices ordinaires **U+2081/²/³**. Nouveaux tests :
   `Batch_path_alias_or_root_is_refused` et `Reserved_exponents_and_subscripts_are_handled`.

6. **Horodatages stricts.** `ReadDateTime` utilise `DateTimeOffset.TryParseExact(text, "o",
   InvariantCulture, RoundtripKind)` : seule la forme UTC ronde émise par `Iso` est lue ; date seule,
   zone absente et forme ambiguë sont refusées, jamais résolues contre le fuseau local. `Decode` après
   expiration et toutes les bornes temporelles sont conservés. Nouveaux tests : `Date_only_timestamp_is_refused`,
   `Missing_zone_timestamp_is_refused`, `Ambiguous_timestamp_is_refused` (avec `Non_utc_timestamp_is_refused`
   conservé), tous à digest recalculé.

Le commentaire du record `SharedParkIntent` rappelle que ce format ne prouve aucune copie et que le
futur protocole doit vérifier les sauvegardes avant de persister l’intention.

## Tests écrits (39), exécutés : 0

39 méthodes `[Test]` dans `SharedParkIntentDocumentTests` (fixtures UTC fixes, aucune réflexion,
aucun fichier temporaire, empreintes SHA-256 réelles, chemins Windows fictifs). Refus précis
(`ArgumentException` / `InvalidDataException` / `OperationCanceledException`), jamais d’avale-tout.
Les cas structurels et d’horodatage sont fabriqués avec digest recalculé pour que seul le défaut
testé se déclenche.

## Attente Codex

Aucun build/test lancé ici (ni Spark ni Mac). Compilation Windows, revue et intégration à la charge
de Codex (retour058). Aucune dépendance/service/runtime/réseau/agent/fournisseur ajouté ; dev/ en
lecture seule, WAPT exclu ; aucun `git commit/push/reset/clean`. `SharedParkIntentJournal` (012B) et
la suite (persistance, sauvegarde, publication) restent à faire — rien n’est annoncé fini.
