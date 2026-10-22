using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>A fresh read of one object: the entry, when and where it was read, and how many sensitive attributes were left out.</summary>
public sealed record FicheRead(FicheEntry Entry, DateTimeOffset ReadAt, string? Controller, int HiddenSensitive);

/// <summary>Projection of one object kept in the local base (FIC-030): shown at once, replaced by the directory read.</summary>
public sealed record FicheLocalRead(FicheEntry Entry, DateTimeOffset ReadAt);

/// <summary>Direct children of an OU or a container, bounded (2 000), with the reason of a partial read.</summary>
public sealed record FicheChildren(string Dn, ImmutableArray<string> Dns, bool Complete, string? Note);

/// <summary>What links an object to others: manager, reports, managedBy, what it manages, user/workstation associations.</summary>
public sealed record FicheRelationsRead(string? ManagerDn, ImmutableArray<string> Reports, string? ManagedByDn, ImmutableArray<string> Manages, ImmutableArray<FicheAssociation> Associations);

/// <summary>
/// Reads of the « Fiche » screen (docs/ops/fiche.md). Served by the fictitious directory in simulation (memory, no network, no
/// disk), by Active Directory and the local base in directory mode (wave 3). Read only by construction: no method writes,
/// writes go through the write circuit (docs/WRITES.md). The reads marked « network » run only after an explicit gesture of
/// the operator and are bounded to one object; the « local » ones never leave the workstation.
/// </summary>
public interface IFicheReader : IScreenReader
{
    /// <summary>Local: projection of the object in the local base, or null (unknown, or no base). Never reads the network.</summary>
    Task<FicheLocalRead?> PreviewAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Network: the object read on the controller with the list of safe attributes. Refused with fiche.unknown when absent.</summary>
    Task<FicheRead> ReadAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Network: the object read by its GUID (identity checks of the write executors and of the reread), or null.</summary>
    Task<FicheEntry?> ReadByGuidAsync(Guid objectGuid, CancellationToken cancellationToken);

    /// <summary>Local: names, kinds and places of the given DNs in the local index (exact DN, case ignored); unknown DNs are absent.</summary>
    Task<IReadOnlyDictionary<string, FicheSummary>> IndexAsync(IReadOnlyCollection<string> dns, CancellationToken cancellationToken);

    /// <summary>Local: objects whose name, account, UPN or mail holds the text (accents and case ignored), of the given kinds.</summary>
    Task<ImmutableArray<FicheSummary>> SearchLocalAsync(string text, IReadOnlyCollection<FicheKind> kinds, int limit, CancellationToken cancellationToken);

    /// <summary>Network: direct children of an OU or a container (one level), bounded.</summary>
    Task<FicheChildren> ChildrenAsync(string dn, int limit, CancellationToken cancellationToken);

    /// <summary>Local: relations of the object from the local base (manager, reports, managedBy, associations).</summary>
    Task<FicheRelationsRead> RelationsAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Local: last committed measures of a workstation (presence, console account, inventory), or null.</summary>
    Task<FicheObservation?> ObservationAsync(string computerDn, CancellationToken cancellationToken);

    /// <summary>Local: last quick inventory stored in the local base for a workstation (no read of the workstation), or null.</summary>
    Task<FicheInventoryReading?> StoredInventoryAsync(string computerDn, CancellationToken cancellationToken);

    /// <summary>Network: memberOf edges around the object (GroupPathRead), bounded to 2 000 groups and 16 levels.</summary>
    Task<FicheGroupGraph> GroupGraphAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Network: 4740 events of the account on the PDC emulator, its SID only, within the window.</summary>
    Task<FicheLockoutRead> LockoutEventsAsync(string dn, int hours, int maxEvents, CancellationToken cancellationToken);

    /// <summary>Network: lastLogon and logonCount of the object on each controller of the domain (50 at most).</summary>
    Task<FicheLogonReadings> LogonReadingsAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Network: one ping of the workstation (no credential), result committed under its GUID.</summary>
    Task<FichePresenceReading> PingAsync(string computerDn, CancellationToken cancellationToken);

    /// <summary>Network: sessions of the workstation (WTS, consultation only).</summary>
    Task<FicheSessionsReading> SessionsAsync(string computerDn, CancellationToken cancellationToken);

    /// <summary>Network: quick inventory of the workstation (CIM/WMI), committed then read back.</summary>
    Task<FicheInventoryReading> InventoryAsync(string computerDn, CancellationToken cancellationToken);

    /// <summary>Network: the password policy that applies to the account (msDS-ResultantPSO, then the domain policy).</summary>
    Task<FichePolicyReading> PasswordPolicyAsync(string userDn, CancellationToken cancellationToken);

    /// <summary>Network: the security descriptor of the object and the SIDs of the session token (rights estimate).</summary>
    Task<FicheSecurityReading> SecurityAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Network: replication metadata of the object (attribute, date, originating controller, version).</summary>
    Task<ImmutableArray<FicheAttributeChange>> AttributeHistoryAsync(string dn, CancellationToken cancellationToken);
}

/// <summary>Error codes and messages of the « Fiche » screen.</summary>
public static class FicheErrors
{
    public const string Unknown = "fiche.unknown";
    public const string UnknownMessage = "Objet introuvable dans l’annuaire : rien n’a été lu.";

    public const string Ambiguous = "fiche.ambiguous";
    public const string AmbiguousMessage = "Plusieurs objets correspondent : précisez le nom (identifiant, DOMAINE\\compte, UPN ou DN). Rien n’a été ouvert.";

    public const string NotFound = "fiche.notFound";
    public const string NotFoundMessage = "Aucun objet de la base locale ne correspond exactement : lancez une recherche globale. Rien n’a été lu sur le réseau.";

    public const string NotApplicable = "fiche.notApplicable";

    public const string Protected = "fiche.protected";

    public const string Refused = "fiche.refused";

    public const string Invalid = "fiche.invalid";

    public static DomeniaOperationException Error(string code, string message) => new(code, message);
}
