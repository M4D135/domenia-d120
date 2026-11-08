Implémente l'accès LDAP de `Domenia.Ad` (projet `v2/src/Domenia.Ad`, espace de noms `Domenia.Ad`) défini par le contrat
`AdContracts.cs` fourni (interface `IAdConnection`, `AdEntry`, `AdSearchRequest`, `AdModification`, `AdRootDse`,
`AdConnectionOptions`, `AdErrors`). NE MODIFIE PAS `AdContracts.cs`. Paquet disponible : System.DirectoryServices.Protocols
(déjà référencé par le projet). Les exceptions de sortie sont toujours `Domenia.Core.DomeniaOperationException(code, message)`
avec les codes et messages de `AdErrors`.

Fichiers à produire :
1. `v2/src/Domenia.Ad/Ldap/AdConnection.cs` : `public sealed class AdConnection : IAdConnection`
   - constructeur `AdConnection(AdConnectionOptions options)` : ne se connecte PAS ; la première opération ouvre la connexion
     (verrou `SemaphoreSlim`, une seule ouverture même en appels concurrents) :
     `new LdapDirectoryIdentifier(options.Server ?? options.DomainDnsName, 389, fullyQualifiedDnsHostName: true, connectionless: false)`
     (serveur et domaine null : domaine de l'ordinateur), `AuthType.Negotiate`, `SessionOptions.ProtocolVersion = 3`,
     `Signing = true`, `Sealing = true`, `ReferralChasing = ReferralChasingOptions.None`, `Timeout = options.ConnectTimeout`,
     `Credential` = options.Credential, sinon la session Windows ; `Bind()` ; puis lecture du RootDSE (base vide, scope Base,
     filtre `(objectClass=*)`) : `Server` = dnsHostName.
   - Toutes les requêtes synchrones (`SendRequest`) tournent sur le pool (`Task.Run`) avec `request.TimeLimit` et le délai
     de la requête ; l'annulation est vérifiée entre les pages et avant chaque requête.
   - `SearchAsync` : `SearchRequest` + `PageResultRequestControl(PageSize)` jusqu'au cookie vide ou `SizeLimit` atteint ;
     `SearchOption.DomainScope` pour éviter les références ; valeurs binaires lues en `byte[]` pour les attributs de la liste
     `BinaryAttributes` (objectGUID, objectSid, sIDHistory, tokenGroups, nTSecurityDescriptor, thumbnailPhoto, jpegPhoto,
     userCertificate, msExchMailboxGuid, msDS-GenerationId, logonHours, msDS-AllowedToActOnBehalfOfOtherIdentity), texte pour
     les autres (`GetValues(typeof(string))`).
   - Récupération par plages : un attribut rendu sous la forme « member;range=0-1499 » est complété par des lectures de base
     successives (« member;range=1500-* », etc.) jusqu'à la borne « * », et toutes les valeurs sont rangées sous « member ».
   - `ReadAsync` : recherche de base ; `null` si l'objet n'existe pas (code 32).
   - `ModifyAsync` (`ModifyRequest` + `DirectoryAttributeModification`, valeurs string ou byte[] ; liste vide pour effacer),
     `RenameAsync` (`ModifyDNRequest`, deleteOldRdn true), `AddAsync` (`AddRequest`), `DeleteAsync` (`DeleteRequest`).
   - Correspondance des erreurs (`LdapException.ErrorCode`, `DirectoryOperationException.Response.ResultCode`) :
     49 → Credentials ; 50 → AccessDenied ; 32 → NoSuchObject ; 51/52/81/91 → Unavailable ; 85 et `TimeoutException` → Timeout ;
     19/21 → Constraint ; 53 → Unwilling ; 68 → Exists ; autres → Failed. Le code numérique et le message du serveur vont dans
     une propriété du journal technique : expose un événement `public static event Action<string>? TechnicalTrace;` qui reçoit
     « LDAP <opération> : code N » (jamais un DN complet, jamais une valeur), appelé à chaque échec.
   - `Dispose` libère la connexion et le sémaphore.
2. `v2/src/Domenia.Ad/Ldap/AdConnectionFactory.cs` : `public static class AdConnectionFactory { public static IAdConnection Create(AdConnectionOptions options); }`.

Contraintes : aucun avertissement de compilation (TreatWarningsAsErrors, AnalysisLevel latest) : `ConfigureAwait(false)`,
`StringComparison` explicite, pas de `catch` trop large sans `#pragma warning disable CA1031` justifié, `CultureInfo.InvariantCulture`.
Les mots de passe ne sont jamais lus ni copiés hors de `NetworkCredential`.
