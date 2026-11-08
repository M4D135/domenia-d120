# READY 012A-FIX2 — quatre points de revue ciblés du codec d’intention

Micro-tâche FIX2 terminée côté OpenCode. Édition regroupée des **deux seuls** fichiers
applicatifs (`SharedParkIntentDocument.cs`, `SharedParkIntentDocumentTests.cs`) + ce rapport.
Aucun autre fichier touché. Périmètre pur conservé : aucune I/O (fichier, SQLite, partage, ACL,
processus), aucune compilation ni exécution de test ici. Codex compile060 sous Windows.

La production finale reste identique à la copie compilée059 (build vert Debug/Release, zéro
avertissement/erreur) ; seules les corrections des quatre points de `REVIEW-MICRO012A-FIX1-FINAL.md`
ont été appliquées, plus le durcissement de `ReadDateTime`. Un build vert n’est pas une suite exécutée.

## Quatre points de revue — corrections effectives

1. **Cohérence d’absence des références de sauvegarde.** `Explicit_null_backup_accepted_when_absent`
   ne modifie plus les drapeaux sur un `JsonObject` en conservant le `batchFingerprint` de
   `MakeBatch(true,true)` : `SharedParkIdentity.Fingerprint` inclut `LocalExists`/`RemoteExists`, donc
   `Validate` refusait le document avant l’assertion positive. Un nouvel auxiliaire `IntentNode(batch,
   sqlite, tsv)` construit le batch absent **en amont** et **recalcule** `batchFingerprint` depuis le
   batch réellement sérialisé avant l’enveloppe ; les deux `null` explicites passent maintenant quand
   les drapeaux sont faux. `Missing_backup_key_is_refused` est **scindé** en
   `Missing_sqlite_backup_key_is_refused` et `Missing_tsv_backup_key_is_refused`, chacun sur un document
   par ailleurs valide (batch absent cohérent, l’autre référence présente) pour couvrir séparément
   l’absence de chaque clé.

2. **Taille après échappement réellement atteinte.** `Metadata_that_grows_after_escaping_is_refused`
   passe désormais les identités attendues **égales au batch** (`expectedStoreId = bloat`,
   `expectedDomainDn = bloat`) : le contrôle d’identité passe et c’est bien le contrôle post-sérialisation
   des 64 Kio (après échappement JSON) qui refuse, plus un faux refus d’identité.
   `Oversized_identity_is_refused_before_fingerprint` passe également l’identité attendue cohérente
   (`expectedStoreId = huge`) pour isoler la borne de taille ; le message précis contenant « caractères »
   reste contrôlé et prouve que la borne `EnsureScalarsBounded` se déclenche avant tout calcul d’empreinte.

3. **Empreintes d’absence réelles, purement mémoire.** `Roundtrip_with_real_absence_fingerprints`
   n’utilise plus `Sha("rows")`/`Sha("local")`/`Sha("remote")`. Le relevé d’absence est construit
   uniquement en mémoire depuis les **vraies sources de calcul** (aucun SQLite, aucun fichier) :
   `RowsFingerprint = Convert.ToHexStringLower(SHA256.HashData([]))` (l’empreinte d’une balayure vide,
   `DomeniaDatabase.RelationSweeps.cs:21-22`), `LocalFingerprint = DomeniaDatabase.SharedParkLocalFingerprint(StoreId,
   DomainDn, 0, 0, false, emptySweepFingerprint)` (`DomeniaDatabase.SharedPark.Read.cs:72`, même appel que
   le chemin d’absence `:86`), `RemoteSha256 = SharedParkFile.Hash([])` (`SharedParkFile.cs:109`), drapeaux
   `false` et compteurs à zéro cohérents. L’aller-retour est comparé à l’intention d’origine et les trois
   empreintes d’absence sont vérifiées conservées (jamais repliées sur la chaîne vide). Les deux membres
   internes sont atteints via l’`InternalsVisibleTo("Domenia.Tests")` existant.

4. **Forme UTC canonique réellement vérifiée.** `ReadDateTime` ne se contente plus de
   `TryParseExact(text, "o", …)` : le format standard `o` rend la zone (marqueur `K`) **optionnelle** et
   peut réinterpréter une valeur sans zone via le fuseau de l’hôte. Le test ajoute la comparaison exacte
   `Iso(parsed) != text` après parsing. Comme `Iso(value) = value.UtcDateTime.ToString("o", InvariantCulture)`
   émet toujours la forme UTC normalisée avec suffixe `Z`, la comparaison impose le `Z`, la précision à
   sept chiffres et le calendrier, **sans dépendance au fuseau de la machine**. Les tests négatifs sont
   conservés et restent valides quelle que soit la zone de l’exécution : `Missing_zone_timestamp_is_refused`
   (sans `Z` → refusé car `Iso(parsed)` porte `Z` et une valeur décalée), `Non_utc_timestamp_is_refused`
   (`+02:00` → normalisé en `Z` ≠ texte d’origine), `Date_only_timestamp_is_refused` et
   `Ambiguous_timestamp_is_refused` (rejetés par `TryParseExact`), plus l’aller-retour valide inchangé.

## Tests écrits (40), exécutés : 0

40 méthodes `[Test]` dans `SharedParkIntentDocumentTests` (fixtures UTC fixes, aucune réflexion, aucun
fichier temporaire, empreintes SHA-256 réelles, chemins Windows fictifs). Refus précis
(`ArgumentException` / `InvalidDataException` / `OperationCanceledException`), jamais d’avale-tout. Le
nombre passe de 39 à 40 par la scission de `Missing_backup_key_is_refused` en deux cas distincts. Les cas
structurels et d’horodatage sont fabriqués avec digest recalculé pour que seul le défaut testé se déclenche.

## Attente Codex

Aucun build/test lancé ici (ni Spark ni Mac). Compilation Windows, revue et intégration à la charge de
Codex (retour060). Aucune dépendance/service/runtime/réseau/agent/fournisseur ajouté ; dev/ en lecture
seule, WAPT exclu ; aucun `git commit/push/reset/clean`. `SharedParkIntentJournal` (012B) et la suite
(persistance, sauvegarde, publication) restent à faire — rien n’est annoncé fini.
