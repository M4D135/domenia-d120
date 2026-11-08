# Coalescence Bridge — lot Codex 018

Développement du 25 octobre 2026, branche `v2`. Relecture statique locale et revue root ; **aucune compilation ni exécution de tests sur le Mac**. Seize tests C# écrits, non exécutés. Compilation Windows à orchestrer par root. Ce lot ne déclare pas la parité globale TRV-126 terminée.

## Périmètre livré

Quatre lectures déclarées par le serveur : `directory.ou.children`, `directory.ou.search`, `search.containers`, `schema.read`. Cette dernière correspond à `AdSchemaRead` : paramètres vides, limites fixes 8 000 attributs / 3 000 classes / 90 s (150 s au service), connexion LDAP de session, pas de secret, objet vivant ou identifiant de résultat transmis. Son catalogue reste celui du service de schéma, lié à sa session ; la coalescence n’ajoute aucun cache.

La clé associe l’opération, sa classe, sa déclaration de priorité/fournisseur/exigences, le type JSON et l’empreinte des paramètres canoniques, ainsi que l’identité de source/session/compte/contrôleur/périmètre effectif et les générations des comptes. L’instance d’admission appartient à un seul dispatcher dans un seul processus. Les paramètres `null`, absents et `{}` restent distincts : aucune demande mal formée ne peut hériter du succès d’un appel valide. `ShareRead` vaut faux par défaut ; une déclaration hors liste, une écriture, un plan ou des arguments sensibles sont refusés.

Un seul groupe obtient l’admission et appelle le handler. Chaque abonné conserve son identifiant, sa réponse et son annulation. Les abonnés en attente occupent chacun une des **32** places existantes. Limites supplémentaires : **32 groupes**, **64 abonnés par groupe**, **128 abonnés au total**. Ni argument, ni cible, ni identité de session ne sont ajoutés au snapshot d’activité.

Un abonné qui part ne coupe pas le travail des autres. Le départ du dernier demande l’annulation du groupe ; sa place reste détenue jusqu’au retour réel du handler et de ses callbacks d’annulation. Le groupe en fermeture refuse toute nouvelle jonction/demande identique, sans rejeu automatique. Un groupe promu dont tous les abonnés partent avant l’invocation rend sa place sans appeler le handler. Le retrait UI par requestId reste limité aux demandes encore en file ; aucun succès d’arrêt n’est fabriqué après admission.

L’âge et l’ordre initiaux du groupe sont conservés après départ du premier abonné. Des priorités/exigences différentes créent des groupes différents. Le départ et la publication du résultat sont requalifiés localement ; les lectures locales de qualification peuvent toucher le disque. Les captures initiales, de rafraîchissement et de revalidation partagent désormais une borne réelle de 32, conservée même si leur attente est annulée alors que le fournisseur continue.

## Audit des autres correspondances TRV-126

Exclusions conservatrices après lecture des handlers et de leurs services :

| Opérations D1 | Correspondances v2 examinées | Ce qui manque pour un partage sûr |
| --- | --- | --- |
| AdConsistencyScan | `audit.identities.scan` | Sélection LDAP ciblée et comparaison à la copie locale ; générations effectives à sceller. |
| AdHealthRead, DcServicesRead | `audit.dc.probe`, `audit.dc.services` | Liste de contrôleurs autorisés mémorisée et choix de compte/transport à qualifier. |
| DelegationRead, GroupPathRead, PasswordPolicyRead | `audit.object.acl`, `.tokenGroups`, `.groups`, `.membership`, `.policy` | `AdReadAccess` peut consommer un compte temporaire ciblé ; ACL/graphes et slot d’audit ont aussi leur propre état. La seule génération globale ne scelle pas un bail à usage unique. |
| DirectoryAbsenceCheck | `synchro.absences.check` | Lot de lecture et propositions d’absences vivants ; pas une requête pure décrite par `{}`. |
| EmbeddedDirectoryLookup | `shell.lookup`, `.lookup.verify`, `shell.ou.resolve` | Version de copie locale pour lookup ; sélection LDAP ciblée pour verify/resolve. |
| GpoAppliedRead, GpoLinksRead | `audit.object.gpoApplied`, `.gpoLinks` | Croisement avec les résultats RSoP/liens conservés dans le slot d’audit. |
| MachineIdentityRead | `audit.object.machineIdentity` | Identité cible locale, sélection de compte et contexte des sondes à qualifier ensemble. |
| OpenAdObject | `fiche.read`, `.attributes` | Cache/session de fiche et configuration de filtrage des attributs, avec relecture explicite qui invalide le cache. |
| LockoutDiagnosis, LogonByDcRead | `fiche.lockouts`, `.logonByDc` | Fiche connue, politique de verrouillage/choix de compte et données locales ; le lecteur d’événements peut continuer après son attente. |
| RelationHistoryRead | `audit.object.history`, `.relations`, `fiche.relations` | État local des associations/historique absent de l’empreinte actuelle. |
| SessionsList | `poste.sessions` | WTS peut finir après `WaitAsync` ; il faut un signal de fin physique avant de retirer un groupe et permettre le suivant. |

Le compteur physique commun reste distinct du nombre de groupes Bridge. Le présent lot ne prétend ni terminer la couverture physique de tous les chemins, ni rendre les appels WTS tuables.

## Tests écrits

Seize cas couvrent : départ du premier abonné avec un seul bail physique ; fermeture après départ du dernier et refus de remplacement ; identité changée avant publication ; séparation payload/session/dispatcher ; 32 abonnés réellement en file et promotion unique après retrait du premier ; expiration sans handler ; retrait de tous après promotion mais avant invocation ; jeton annulé après admission alors que l’abonné reste inscrit ; fermeture du dispatcher avant invocation ; bornes 64/128/32 ; vieillissement et exigences ; liste fermée et exclusions ; 32 qualifications réellement pendantes après annulation ; arguments invalides/null/trop grands ; vrai `SchemaService` avec progression et statut individuels. Barrières explicites et horloge injectée, aucun appel AD/réseau. Les délais courts des attentes de test sont des garde-fous d’échec, pas une preuve par temporisation.

Fichiers : `BridgeAdmission.cs`, `BridgeSharedReads.cs`, `BridgeDispatcher.cs`, `BridgeScheduling.cs`, `OperationRegistry.cs`, `BridgeSharedReadTests.cs`, ce rapport. Pas de modification des pages Poste/Logiciels, de Store/SharedPark, des lecteurs AD ou de leur état.
