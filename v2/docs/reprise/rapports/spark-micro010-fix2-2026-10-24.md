# SPARK-READY-010-FIX2 — trois corrections d’API et fermeture réelle avant libération

MICRO010-FIX2 exécuté dans une session native neuve, à partir du mandat FRESH, du journal VM052 complet (Debug en échec sur trois
erreurs, 0 avertissement, Release non tenté, aucune suite exécutée, aucun commit010) et des deux sources010 complètes jointes.
Corrections ciblées dans les deux seuls fichiers010, sans inventaire, sans réécriture générale, sans autre périmètre. Aucun fichier
de référence, aucun autre WIP, aucun consommateur touché ; pas de raccordement, pas de stub de publication. Aucun build, aucun test
exécuté ici, aucune dépendance téléchargée, aucun service/runtime/réseau modifié, aucun commit, push, reset ni clean. `dev/` en
lecture seule, WAPT exclu.

Le rapport `SPARK-READY-010-FIX1.md` est **conservé comme historique** ; le présent rapport réécrit honnêtement le résultat réel,
notamment sur le point 4 de FIX1 qui était affirmé à tort (voir défaut 1 ci-dessous).

## Trois erreurs de compilation VM052 réellement corrigées

1. **CS0117 ligne341 — `Directory.GetAttributes` n’existe pas.** Devient `File.GetAttributes(directory)`, exactement le lecteur déjà
   validé du lot009 (`SharedParkRemoteReader` emploie `File.GetAttributes(directory)`). Le contrôle reparse (`& FileAttributes.ReparsePoint`)
   et le refus des erreurs (l’appel lève et remonte) sont conservés à l’identique ; le dossier vient d’être créé juste au-dessus.

2. **CS0117 ligne345 — `FileSystemRights.ReadWrite` n’existe pas.** La création unique demande désormais les droits explicites
   `FileSystemRights.Read | FileSystemRights.Write | FileSystemRights.Delete | FileSystemRights.Synchronize`. `Read` couvre la
   relecture de la DACL (ReadPermissions) depuis le handle ; `Delete` est requis par `DeleteOnClose` ; `Synchronize` par le handle
   synchrone. `FileShare.Read` est inchangé : le handle de production reste sans partage écriture ni suppression. Vérifié dans les
   sources .NET10 (`FileSystemRights.cs` : Read/Write/Delete/Synchronize distincts, aucun ReadWrite) et la contrainte Windows
   (suppression à fermeture ⇒ DELETE, mode synchrone ⇒ SYNCHRONIZE).

3. **CS1929 ligne446 — `GetAccessControl(FileStream)` ne prend pas `AccessControlSections`.** Devient `held.GetAccessControl()`, la
   surcharge qui reconstruit Access/Owner/Group depuis le `SafeFileHandle`. Aucune réouverture par nom n’est introduite ; la DACL
   reste relue **depuis le handle tenu**, et les contrôles (`AreAccessRulesProtected`, règles non héritées, FullControl, trois
   principaux) sont inchangés.

## Deux défauts de revue réellement corrigés

1. **`CloseExpired` libérait avant la fermeture physique — correction réelle.** Le code FIX1 faisait encore `Active.Remove(path)` et
   `reservedBytes -= slot.Bytes` **avant** de boucler sur `lease.Dispose()` : une admission concurrente pouvait donc reprendre la
   place et les octets pendant que les anciens handles restaient ouverts. Le FIX1 affirmait pourtant (point 4) que « ses octets ne
   sont jamais annoncés libres avant la fermeture physique » — **cette affirmation était fausse dans le code** ; elle est ici rendue
   vraie. Désormais, sous `Admission` le balayage **sélectionne seulement** les leases expirées (sans retirer ni décrémenter), puis
   ferme **hors** de la porte ; chaque `Dispose` ne rend sa réservation **par jeton qu’après** la fermeture physique réelle. Les slots
   `Lease is null` (stage en cours) restent la propriété du `Stage` et ne sont jamais volés. L’idempotence (`Interlocked.Exchange`)
   et l’horloge propre de chaque slot sont conservées. Aucun verrouillage circulaire : `Admission` n’est jamais tenu pendant la
   fermeture, et `gate` n’est jamais pris en tenant `Admission`.

2. **Expiration survenue après le balayage : la relecture ferme désormais sa propre lease.** Si l’horizon passe après le balayage
   initial — pendant l’attente de `gate` ou pendant la relecture physique — les deux contrôles d’horizon de `Read` refusaient bien,
   mais laissaient `stream` et la réservation ouverts. `Read` capture maintenant la cause d’expiration dans les deux chemins (à
   l’entrée du `gate`, et juste avant de remettre les octets), ressort du `gate`, puis appelle `Dispose()` **hors du `gate`** (sinon
   `Dispose` reprendrait le même verrou) : le refus de cette opération ferme son propre fichier tenu et rend sa propre réservation par
   jeton, sans jamais remettre un octet expiré. Les refus non liés à l’expiration (session, époque, taille, en-tête, empreinte)
   gardent leur comportement antérieur ; `Stage` (auto-vérification à l’instant de la création) n’emprunte pas ce chemin.

## Régression de comportement ajoutée (une seule)

`An_expiration_seen_at_the_gate_closes_the_lease_and_frees_its_own_reservation` : une réservation est admise **sans être attachée**
(`Lease is null`, exactement le cas que le balayage doit laisser intact), un handle `DeleteOnClose` détient réellement le fichier,
l’horloge est avancée au-delà de l’horizon, puis un seul `ReadProposedAsync`. Comme le balayage ne peut pas fermer ce spool, **seule
la relecture expirée** doit le fermer : le test asserte le refus nommant l’expiration, la suppression physique du fichier, et le
retour exact de la place et des octets (`ActiveLeases` 1→0, `ReservedBytes` → 0), avec un second `Dispose` qui ne rend rien. Aucun
sommeil, aucune dépendance à un nombre arbitraire d’appels internes ; le point de synchronisation est la divergence entre le verdict
du balayage (slot non attaché laissé seul) et le refus au `gate`. Sans le défaut 2 corrigé, le refus laisserait le fichier tenu et la
réservation comptée, et le test échouerait.

## Tests

**18 tests écrits, aucun exécuté** : les 17 de FIX1 sont **conservés sans modification** de leurs assertions (y compris les tests
d’expiration et les assertions de suppression/comptabilité), plus la **seule** régression ci-dessus. Exécution réservée à la phase
finale dans la VM Windows.

## Limites restantes, non masquées

- Compilation et suites **non exécutées ici** : le vert reste à confirmer par Codex dans la VM (Debug puis Release), comme pour052.
- La borne de **128 Mio** n’est atteinte par aucun test (il faudrait huit spools de 16 Mio) : appliquée par la même admission
  atomique et assertée en comptabilité, ce n’est pas un résultat vert.
- La correction du défaut 1 est un resserrement de **fenêtre concurrentielle** : le test ajouté prouve que le refus ferme et rend la
  réservation quand le balayage laisse le slot seul, mais la course exacte « admission pendant la fermeture » reste un comportement
  d’ordonnancement non déterministe, non asserté.
- Aucun scénario multiutilisateur : le DACL privé et sa relecture depuis le handle ne sont exercés que par le processus propriétaire.
- Le spool reste un fichier temporaire : **ni journal durable, ni CAS, ni reçu**. Relecture physique de la base et du TSV,
  requalification des chemins, garde maintenance/époque, sauvegardes vérifiées, intention durable, verrou sans vol, double CAS,
  remplacement atomique, relecture, commit/reçu restent obligatoires avant toute publication.
- Pas de raccordement du Core à ses trois tableaux, pas de publication, pas de base, pas d’AD à ce lot.

## Suite

Codex revoit, compile Debug **puis** Release dans la VM Windows, préserve les changements concurrents de l’arbre et renvoie le journal
complet à cette session. **SharedPark n’est pas terminé** : restent le raccordement de l’aperçu aux lecteurs006–009 avec référence
compacte, le protocole durable/publication/vérification, annuaire/simulation/UI sous `synchro.store`, puis le reste du master
prompt/catalogue et la recette finale dans les deux VM avant release.
