using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Read interface of the « Audit AD » screen (docs/ops/audit.md). Served by the simulated directory now
/// (Domenia.Simulation, Screens/Audit/SimulatedAuditReader.cs), by Active Directory later. Every method is a bounded read made
/// after an explicit gesture of the operator (network reads in directory mode), except the local ones (target, search,
/// totals of the local copy, relations and history from the local base). Read only, by design: nothing is ever written.
/// </summary>
public interface IAuditReader : IScreenReader
{
    /// <summary>The object of a DN as the local index knows it; null when it is not a known object of the domain.</summary>
    Task<AuditTarget?> FindTargetAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Objects whose name, account or DNS name contains the text (accent and case insensitive), at most the limit.</summary>
    Task<ImmutableArray<AuditTarget>> SearchObjectsAsync(string text, int limit, CancellationToken cancellationToken);

    /// <summary>Group of the domain whose SID ends with this relative identifier (512: Domain Admins), from the local index; null when unknown.</summary>
    Task<AuditTarget?> FindDomainGroupAsync(int rid, CancellationToken cancellationToken);

    /// <summary>Domain overview, section by section, and the bounded searches of the security checks (AUD-023).</summary>
    Task<DomainOverviewRead> DomainOverviewAsync(CancellationToken cancellationToken);

    /// <summary>Totals of the local copy by type with its synchronisation date, never a count of the directory (AUD-022).</summary>
    Task<LocalTotalsRead> LocalTotalsAsync(CancellationToken cancellationToken);

    /// <summary>Controller accounts of the domain (100 at most) and the PDC emulator (AUD-004).</summary>
    Task<ControllerListRead> ControllersAsync(CancellationToken cancellationToken);

    /// <summary>DNS, LDAP 389, Kerberos 88, RootDSE time and inbound replication of 1 to 10 chosen controllers (AUD-005, AUD-006).</summary>
    Task<ControllerProbesRead> ProbeControllersAsync(IReadOnlyList<string> controllers, string? pdc, CancellationToken cancellationToken);

    /// <summary>Directory services of 1 to 10 controllers read by CIM, privileged, within a time budget (AUD-007).</summary>
    Task<ControllerServicesReads> ControllerServicesAsync(IReadOnlyList<string> controllers, int budgetSeconds, CancellationToken cancellationToken);

    /// <summary>One object read on each chosen controller, with its replication metadata (AUD-008).</summary>
    Task<ObjectComparisonRead> CompareObjectAsync(AuditTarget target, IReadOnlyList<string> controllers, CancellationToken cancellationToken);

    /// <summary>Password policy that applies to one user (AUD-011).</summary>
    Task<PasswordPolicyRead> PasswordPolicyAsync(AuditTarget target, CancellationToken cancellationToken);

    /// <summary>Nested memberships: 2 000 groups, 16 levels, 10 seconds at most (AUD-012).</summary>
    Task<GroupGraphRead> NestedGroupsAsync(AuditTarget target, CancellationToken cancellationToken);

    /// <summary>The controller's transitive membership test for one group (AUD-013).</summary>
    Task<MembershipRead> MembershipAsync(AuditTarget target, string groupDn, CancellationToken cancellationToken);

    /// <summary>Owner and DACL (no SACL), 1 000 entries at most, with the names of the SIDs and GUIDs met (AUD-021).</summary>
    Task<AclRead> DelegationsAsync(AuditTarget target, CancellationToken cancellationToken);

    /// <summary>Transitive security groups (tokenGroups) of one trustee of a domain (AUD-015).</summary>
    Task<TokenGroupsRead> TokenGroupsAsync(string sid, CancellationToken cancellationToken);

    /// <summary>gPLink and gPOptions of each container of the chain, then the names and states of the GPOs found (AUD-016).</summary>
    Task<GpoLinksRead> GpoLinksAsync(IReadOnlyList<string> containers, CancellationToken cancellationToken);

    /// <summary>Last result applied on one workstation, read by CIM (RSOP_GPO, RSOP_GPLink) (AUD-017).</summary>
    Task<RsopRead> AppliedPoliciesAsync(AuditTarget target, CancellationToken cancellationToken);

    /// <summary>DNS resolution (forward and reverse) and identity returned by the workstation (AUD-018).</summary>
    Task<MachineIdentityRead> MachineIdentityAsync(AuditTarget target, CancellationToken cancellationToken);

    /// <summary>Associations kept in memory for one user or workstation (stored and of this session), never across GUIDs (AUD-019).</summary>
    Task<ImmutableArray<RelationRecord>> RelationsAsync(AuditTarget target, CancellationToken cancellationToken);

    /// <summary>Stored history of the associations of one user or workstation, local base only (AUD-020).</summary>
    Task<RelationHistoryRead> RelationHistoryAsync(AuditTarget target, int limit, CancellationToken cancellationToken);

    /// <summary>Identity attributes of the users and computers of one OU, bounded, never the whole domain (AUD-009).</summary>
    Task<IdentityScanRead> IdentityScanAsync(string baseDn, bool subtree, int limit, CancellationToken cancellationToken);

    /// <summary>Names of the local copy for the logon and workstation names of a scan (1 000 of each kind at most).</summary>
    Task<LocalNamesRead> LocalNamesAsync(IdentityScanRead scan, CancellationToken cancellationToken);
}
