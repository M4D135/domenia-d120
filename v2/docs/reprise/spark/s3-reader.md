Écris la lecture de l'annuaire en mode annuaire : `v2/src/Domenia.Ad/Directory/AdDirectoryReader.cs` et
`v2/src/Domenia.Ad/Directory/AdDirectoryMapper.cs` (espace de noms `Domenia.Ad`), en utilisant UNIQUEMENT l'interface
`IAdConnection` et `AdEntry` du contrat fourni (`AdContracts.cs`, à ne pas modifier) et les modèles du cœur fournis
(`DirectoryModels.cs` : `DomainInfo`, `DomainController`, `DomainPasswordPolicy`, `DirectoryOu`, `DirectoryUser`,
`DirectoryComputer`, `DirectoryGroup`, `DirectorySnapshot`, `LapsKind` ; `AdValues`, `DistinguishedName` du cœur).

1. `AdDirectoryMapper` (public static) :
   - listes d'attributs `public static readonly string[] OuAttributes, UserAttributes, ComputerAttributes, GroupAttributes`
     exactement nécessaires aux records ;
   - `public static DirectoryOu? Ou(AdEntry e)`, `DirectoryUser? User(AdEntry e)`, `DirectoryComputer? Computer(AdEntry e)`,
     `DirectoryGroup? Group(AdEntry e)` : null quand objectGUID manque. Correspondances : objectGUID→ObjectGuid (AdEntry.Guid),
     objectSid→Sid (AdEntry.Sid), distinguishedName, cn, name, sAMAccountName, userPrincipalName, displayName, givenName, sn,
     mail, title, department, physicalDeliveryOfficeName→Office, telephoneNumber, manager→ManagerDn, description,
     employeeID→EmployeeId, userAccountControl, msDS-User-Account-Control-Computed (souvent absent en recherche de sous-arbre :
     null alors), lockoutTime, badPwdCount, pwdLastSet, msDS-UserPasswordExpiryTimeComputed (même remarque),
     lastLogonTimestamp, accountExpires, whenCreated, whenChanged (AdEntry.Time ; si absent : DateTimeOffset.MinValue),
     uSNChanged, adminCount, primaryGroupID, memberOf ; ordinateur : name, dNSHostName, location, managedBy,
     operatingSystem, operatingSystemVersion ; LAPS : `ms-Mcs-AdmPwdExpirationTime` → LapsKind.Legacy, `msLAPS-PasswordExpirationTime`
     → LapsKind.Windows (le second l'emporte), LapsExpiration = la valeur FILETIME ; groupe : groupType, member→Members,
     memberOf. Les grands entiers restent des valeurs FILETIME (long), 0 et 9223372036854775807 compris (le cœur les interprète).
2. `AdDirectoryReader` (public static) :
   - `public static async Task<DomainInfo> ReadDomainAsync(IAdConnection connection, CancellationToken cancellationToken)` :
     RootDSE ; objet domaine (lecture de base sur defaultNamingContext : objectSid, maxPwdAge, minPwdLength, pwdHistoryLength,
     lockoutThreshold, lockoutDuration, lockOutObservationWindow, pwdProperties, wellKnownObjects) ; durées AD négatives en
     intervalles de 100 ns → `TimeSpan.FromTicks(-valeur)` (0 ou long.MinValue → TimeSpan.Zero) ; ComplexityRequired = bit 0x1
     de pwdProperties ; nom NetBIOS : recherche sous `CN=Partitions,<configurationNamingContext>`, filtre
     `(&(objectClass=crossRef)(nCName=<rootDn>))`, attributs nETBIOSName et dnsRoot (dnsRoot = DnsName ; à défaut, déduit des
     composants DC= du DN) ; contrôleurs : recherche sous `CN=Sites,<configurationNamingContext>` des objets `server`
     (attributs dNSHostName, distinguishedName) : le site est le CN situé deux niveaux au-dessus (CN=<serveur>,CN=Servers,
     CN=<site>,CN=Sites,…) ; conteneurs par défaut : DN extraits de wellKnownObjects (« B:32:<guid>:<dn> ») qui ne sont pas des OU ;
     `DomainSid` = SID du domaine.
   - `public static async Task<DirectorySnapshot> ReadSnapshotAsync(IAdConnection connection, DomainInfo domain, string baseDn,
     int maxObjectsPerKind, TimeProvider clock, CancellationToken cancellationToken)` : quatre recherches paginées de
     sous-arbre sous `baseDn` (OU : `(objectClass=organizationalUnit)` ; utilisateurs : `(&(objectCategory=person)(objectClass=user))` ;
     ordinateurs : `(objectCategory=computer)` ; groupes : `(objectCategory=group)`), `SizeLimit = maxObjectsPerKind + 1` pour
     savoir si la limite est dépassée (alors `Complete = false` et la liste est coupée à la limite) ; `ReadAt = clock.GetUtcNow()`.
   - `public static async Task<DirectoryOu?> ReadOuAsync(...)`, `ReadUserAsync`, `ReadComputerAsync`, `ReadGroupAsync`
     (`IAdConnection connection, string dn, CancellationToken`) : lecture fraîche d'un objet (lecture de base, avec cette fois
     msDS-User-Account-Control-Computed et msDS-UserPasswordExpiryTimeComputed pour un utilisateur).
   - `public static async Task<AdEntry?> FindBySamAccountNameAsync(IAdConnection connection, string rootDn, string sam, IReadOnlyList<string> attributes, CancellationToken)`
     et `FindByGuidAsync(... Guid guid ...)` (filtre `(objectGUID=\xx\xx…)` échappé octet par octet).
   - Échappement des valeurs de filtre LDAP (RFC 4515 : `* ( ) \ NUL`) dans une méthode `public static string Escape(string value)`.

Contraintes : aucun avertissement, `ConfigureAwait(false)`, aucune donnée inventée : un attribut absent reste null.
