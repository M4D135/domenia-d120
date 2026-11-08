Écris les exécuteurs d'écriture du mode annuaire pour les comptes utilisateurs (écran Comptes et Fiche), dans
`v2/src/Domenia.Ad/Writes/` (espace de noms `Domenia.Ad`). Ils sont l'équivalent RÉEL des exécuteurs de simulation fournis
(`SimulatedAccountWriteExecutors.cs`, `SimulatedAccountUnlockExecutor.cs`) : mêmes interfaces du cœur, mêmes règles du
cœur (`AccountActivation`, `AccountExpiration`, `AccountMustChangePassword`, `AccountPasswordReset`, `AccountUnlock` :
Draft / Check / IsDone / Apply / Verify), mais la lecture et l'écriture passent par LDAP.

API disponibles (déjà écrites ailleurs, utilise-les telles quelles, ne les réécris pas) :
- `IAdConnection` et `AdEntry`, `AdModification`, `AdModificationKind`, `AdErrors` : fichier `AdContracts.cs` fourni.
- `public sealed class AdDirectorySource : IDirectorySource` (Domenia.Ad) avec :
  `IAdConnection Connection { get; }`, `TimeProvider Clock { get; }`, `string? ControllerName { get; }` (contrôleur de la
  session), `Task<DomainInfo> DomainAsync(CancellationToken)`, `TimeZoneInfo Zone { get; }` (fuseau local de la session).
- `public static class AdDirectoryReader` : `Task<DirectoryUser?> ReadUserAsync(IAdConnection connection, string dn, CancellationToken)`
  (lecture fraîche de base, avec les attributs construits) et `Task<AdEntry?> FindByGuidAsync(IAdConnection connection, string rootDn, Guid guid, IReadOnlyList<string> attributes, CancellationToken)`.
- `public static class AdDirectoryMapper` : `string[] UserAttributes`, `DirectoryUser? User(AdEntry e)`.

À produire :
1. `v2/src/Domenia.Ad/Writes/AdUserChanges.cs` : `public static class AdUserChanges` :
   `IReadOnlyList<AdModification> Diff(DirectoryUser before, DirectoryUser after)` : une modification `Replace` par champ
   écrit qui a changé : UserAccountControl → userAccountControl ; LockoutTime → lockoutTime (« 0 ») ; PasswordLastSet →
   pwdLastSet (« 0 » ou « -1 ») ; AccountExpires → accountExpires ; Description, DisplayName, GivenName, Surname, Mail, Title,
   Department, Office (physicalDeliveryOfficeName), TelephoneNumber, EmployeeId (employeeID), ManagerDn (manager),
   UserPrincipalName ; une chaîne vide ou null efface (Replace sans valeur). Les entiers en texte invariant.
2. `v2/src/Domenia.Ad/Writes/AdAccountWriteExecutor.cs` : classe de base abstraite (constructeur `private protected`
   prenant `AdDirectorySource`) avec `ReadForPlanAsync(dn)` (refus `WriteErrors.Refusal(WriteErrors.TargetUnknown, …)` si
   l'objet n'est pas un utilisateur), `ReadForCheckAsync(plan)` et `ReadForVerifyAsync(plan)` (par GUID du plan :
   `plan.Target.ObjectGuid`, texte « D »), et `SendAsync(plan, done, apply, applied, already)` qui : relit le compte par
   GUID ; s'il est déjà dans l'état demandé renvoie `WriteOutcome(WriteResult.NoChange, …)` ; sinon calcule
   `after = apply(user, now, usnFictif)` puis `AdUserChanges.Diff(user, after)` et envoie UNE `ModifyAsync` sur le DN relu ;
   renvoie `WriteOutcome(WriteResult.Applied, applied + " sur " + contrôleur + ".")`. Les erreurs LDAP remontent telles
   quelles (DomeniaOperationException de la connexion) ; jamais de seconde tentative ; l'envoi reçoit
   `CancellationToken.None` (une écriture commencée n'est jamais interrompue).
3. Les exécuteurs (une classe publique scellée chacun, constructeur public UNIQUE prenant `AdDirectorySource`, propriété
   `Kind` identique à la simulation) : `AdAccountEnableExecutor` (IAccountEnableExecutor), `AdAccountDisableExecutor`
   (IAccountDisableExecutor), `AdAccountMustChangePasswordExecutor`, `AdAccountExpirationExecutor`
   (IAccountExpirationExecutor : PlanAsync(string dn, DateOnly? date, …)), `AdAccountUnlockExecutor`
   (IAccountUnlockExecutor), `AdAccountPasswordResetExecutor` (IAccountPasswordResetExecutor, IDisposable) : reprends
   exactement la logique de la version simulée pour les secrets (`PasswordSecrets`), puis écris `unicodePwd` avec la valeur
   `"\"" + motdepasse + "\""` encodée en UTF-16LE (octets), via un `Replace` (réinitialisation par un administrateur) ;
   le tableau d'octets et la copie non gérée de la `SecureString` sont mis à zéro dans un `finally`
   (`Marshal.SecureStringToGlobalAllocUnicode` / `Marshal.ZeroFreeGlobalAllocUnicode`, `CryptographicOperations.ZeroMemory`) ;
   si le plan demande « changer au prochain logon », écris aussi pwdLastSet = 0 dans la même modification.
   Pour chacun : PlanAsync / CheckAsync / ExecuteAsync / VerifyAsync comme la simulation (même signatures, mêmes règles).
4. Aucun test (ces exécuteurs demandent un vrai annuaire).

Contraintes : aucun avertissement (TreatWarningsAsErrors, AnalysisLevel latest), `ConfigureAwait(false)`, aucune donnée
secrète dans un message ; les textes de résultat en français (« userAccountControl écrit sur DC01.cnamts.local. »).
