# SPARK-READY-010-FIX1 — compilation, handle propriétaire unique, expiration et identité de réservation

MICRO010-FIX1 exécuté dans la session native courante, à partir du mandat, de la revue complète du 24 octobre, du journal VM051
(Debug en échec sur deux CS1503, 0 avertissement, Release non tenté, aucune suite exécutée, aucun commit010) et des deux sources
010 complètes jointes. Les six points de la revue sont corrigés, uniquement dans les deux fichiers010. Aucun fichier de référence,
aucun autre WIP, aucun consommateur touché ; pas de raccordement, pas de stub de publication. Aucun build, aucun test exécuté ici,
aucune dépendance téléchargée, aucun service/runtime/réseau modifié, aucun commit, push, reset ni clean.

## Points réellement corrigés

1. **Deux CS1503** — les deux `JsonDocument.Parse(raw.AsSpan(0, …))` deviennent `raw.AsMemory(0, …)` (surcharge mémoire réellement
   disponible). Aucune assertion de fond modifiée : les mêmes champs d’en-tête sont vérifiés.

2. **Lecteurs de test compatibles** — les trois `File.ReadAllBytes(lease.Path)` sont remplacés par un lecteur de test borné
   `ReadHeld(path, lease.Bytes)` qui ouvre `FileAccess.Read` avec `FileShare.ReadWrite | FileShare.Delete`, exactement le partage
   compatible déjà employé par `NativeSyncSpoolTests` pour un fichier ainsi tenu. La protection du handle de production est
   inchangée (ReadWrite, `FileShare.Read`, `DeleteOnClose`) et la lecture reste **physique** : taille réelle, SHA recalculé sur les
   octets du disque, en-tête réellement parsé — jamais remplacée par la seule `Metadata`. Le test d’expiration attend désormais
   **une** lease active (et non huit), avec la réservation exactement égale à la taille du fichier `late` et les huit fichiers
   supprimés.

3. **Expiration fermée par la lecture elle-même** — `Read` balaye d’abord les leases expirées, **y compris la sienne** : une lease
   expirée est refusée (`InvalidDataException` nommant l’expiration) **et** physiquement fermée, son fichier supprimé, sa
   réservation rendue. Le contrôle d’horizon est refait une fois le verrou `gate` pris, puis à nouveau juste avant de remettre les
   octets. Régression réelle ajoutée (`An_expired_lease_is_refused_and_physically_closed_by_a_read_alone`) : `TestClock` avancé, un
   seul appel `Read`, sans `Stage` ni `Dispose` préalable → refus + fichier supprimé + compte et octets libérés. Aucun délai réel.

4. **Réservation identifiée par jeton, plus par chemin** — chaque admission produit un `Reservation(path, token, bytes, expiresAt,
   clock, lease)` ; `Attach`, `Release` et `Dispose` vérifient que le jeton enregistré à ce chemin est bien le leur, et `Dispose`
   ne rend sa réservation qu’une seule fois (`Interlocked.Exchange`). Une vieille lease ne peut plus rien faire sur le lot suivant.
   Le balayage ne retire **jamais** un slot encore en cours de `Stage` (`Lease is null`) : son propriétaire le libère lui-même, et
   ses octets ne sont jamais annoncés libres avant la fermeture physique. Chaque slot est évalué avec **son** `TimeProvider`.
   Verrouillage circulaire évité : `CloseExpired` ne ferme les leases qu’après avoir relâché `Admission`, et aucun chemin ne prend
   `gate` en tenant `Admission`. Régressions ajoutées : `A_stale_lease_can_never_release_the_reservation_of_the_same_path` (Stage A,
   Dispose A, Stage B mêmes IDs donc même chemin, deuxième Dispose A, B toujours compté, réservation exactement la sienne,
   relisible, fichier tenu) et `Two_components_with_their_own_clocks_never_expire_each_other` (horloge de l’un avancée de 30 minutes,
   l’autre lease reste comptée, présente et relisible). Bornes 8 / 128 Mio inchangées, aucune éviction active, aucune reprise
   automatique.

5. **Création unique avec la sécurité, handle jamais relâché** — plus de `CreateNew` fermé puis ACL par nom puis `FileMode.Open`.
   Une seule création par `FileSystemAclExtensions.Create(new FileInfo(path), FileMode.CreateNew, FileSystemRights.ReadWrite,
   FileShare.Read, 64 Kio, SequentialScan | DeleteOnClose, fileSecurity)` : le DACL privé est posé **à** la création, ce même handle
   ReadWrite sans partage écriture/suppression est conservé jusqu’à `Dispose`, et la DACL est relue **depuis ce handle** par
   `GetAccessControl(FileStream)` — plus aucune ACL lue ou écrite par nom sur un objet remplaçable, plus de fichier vide abandonné
   sans handle `DeleteOnClose` si la protection échoue. Protections du répertoire local et reparse conservées
   (`CompatibleDirectoryCache.ValidateLocalPath` avant et après création du dossier, contrôle reparse du répertoire). Aucun fichier
   n’est supprimé par nom : la fermeture du handle possédé fait seule disparaître le fichier. En cas d’échec après création, le
   handle possédé est fermé et la réservation rendue, sans jamais effacer un fichier préexistant. Régression ajoutée
   (`A_preexisting_sentinel_at_the_spool_path_is_never_touched`) : sentinelle préexistante sur le chemin du spool → `CreateNew`
   refuse, sentinelle intacte octet par octet, aucune lease admise, réservation rendue. Le test écriture/suppression concurrente est
   conservé et renforcé (troisième tentative : ouverture `FileMode.Truncate` refusée).

6. **Domaine validé par le parseur existant** — `Bind` appelle `DistinguishedName.Parse` (aucune normalisation silencieuse : la
   chaîne reçue reste liée telle quelle) et refuse en `InvalidDataException` tout défaut traduit depuis `FormatException`, ainsi
   qu’un DN sans aucun RDN ou portant un RDN de type ou de valeur vide. `=invalide` est désormais refusé. Quatre cas malformés
   contenant `=` sont ajoutés : `=invalide`, `DC=test,=local`, `DC=test,DC=`, `DC=a+DC=b,DC=local`. Bornes de chaînes, empreintes et
   identifiants inchangées ; aucun accès AD.

## API finale (inchangée en surface, deux ajouts internes)

```
SharedParkPreviewSpool(string spoolRoot, TimeProvider clock)
  string Root { get; }
  Task<SharedParkPreviewFile> StageAsync(SharedParkPreviewContext, SharedParkMergePreview, TimeSpan lifetime, CancellationToken)
  SharedParkPreviewFile Stage(...)

SharedParkPreviewFile : IDisposable
  SharedParkPreviewMetadata Metadata { get; }   string Path { get; }   long Bytes { get; }
  int Rows { get; }   long PayloadBytes { get; }   string Sha256 { get; }
  Task<byte[]> ReadProposedAsync(string expectedSessionId, long expectedEpoch, CancellationToken)

SharedParkPreviewFile.Reservation            // slot propriétaire : Path, Token, Bytes, ExpiresAt, Clock, Lease
Admit(...) -> Reservation ; Attach(path, reservation, lease) ; Release(reservation) ; CloseExpired()
SharedParkPreviewFile.ReservedBytes / ActiveLeases    // diagnostics de réservation, pour les tests
```

## Tests

**17 tests écrits, aucun exécuté** (13 repris, 4 ajoutés : expiration fermée par une lecture seule, vieille lease sans prise sur le
même chemin, deux horloges qui ne s’expirent pas mutuellement, sentinelle préexistante intacte). Exécution réservée à la phase
finale dans la VM Windows.

## Limites restantes, non masquées

- Aucun test n’atteint la borne de **128 Mio** (il faudrait huit spools de 16 Mio) : elle est appliquée par la même admission
  atomique et sa comptabilité est assertée, ce n’est pas un résultat vert.
- Aucun scénario multiutilisateur : le DACL privé et sa relecture depuis le handle ne sont exercés que par le processus propriétaire.
- La fenêtre de création est réduite à un appel mais le spool reste un fichier temporaire : **ni journal durable, ni CAS, ni reçu**.
  Relecture physique de la base et du TSV, requalification des chemins, garde maintenance/époque, sauvegardes vérifiées, intention
  durable, verrou sans vol, double CAS, remplacement atomique, relecture, commit/reçu restent obligatoires avant toute publication.
- Pas de raccordement du Core à ses trois tableaux, pas de publication, pas de base, pas d’AD à ce lot.

## Suite

Codex revoit et compile Debug/Release dans la VM Windows, préserve les changements concurrents de l’arbre et renvoie les
diagnostics à cette session. **SharedPark n’est pas terminé** : restent le raccordement de l’aperçu aux lecteurs006–009 avec
référence compacte, le protocole durable/publication/vérification, annuaire/simulation/UI sous `synchro.store`, puis le reste du
master prompt/catalogue et la recette finale dans les deux VM avant release.
