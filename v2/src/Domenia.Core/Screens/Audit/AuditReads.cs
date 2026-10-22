using System.Collections.Immutable;

namespace Domenia.Core;

// Raw reads of the AD audit, as the readers return them (Domenia 1: the pinned workers of Domenia-AdAudit.Worker.ps1). The
// simulated reader builds them from the fictitious directory; Domenia.Ad will build the same records from LDAP, CIM and
// DNS (docs/ops/audit.md, « Mode annuaire »). What a reading proves is decided by the pure rules of this folder.

/// <summary>Kind of the object an audit read is about.</summary>
public enum AuditObjectKind
{
    User,
    Computer,
    Group,
    OrganizationalUnit,
    Domain,
    Other,
}

/// <summary>State of a read that may be refused or unavailable (« an unread value stays unknown »).</summary>
public enum ReadState
{
    Read,
    Empty,
    Refused,
    Unavailable,
    NotRead,
}

/// <summary>State of a fact (New-DomeniaFact): Constaté, Estimé, Refusé, Indisponible, Inconnu.</summary>
public enum FactState
{
    Observed,
    Estimated,
    Refused,
    Unavailable,
    Unknown,
}

/// <summary>Interval of a policy: a value, « never » (explicit 0 or Int64.MinValue), or not read (never « no limit »).</summary>
public enum AdIntervalState
{
    Value,
    Never,
    Unread,
}

public sealed record AdInterval(AdIntervalState State, TimeSpan? Span)
{
    public static AdInterval Unread { get; } = new(AdIntervalState.Unread, null);

    public static AdInterval NeverExpires { get; } = new(AdIntervalState.Never, null);

    public static AdInterval Of(TimeSpan span) => new(AdIntervalState.Value, span);
}

/// <summary>The object an audit is about, frozen at the gesture (New-DomeniaAdAuditTarget).</summary>
public sealed record AuditTarget(
    string Dn,
    AuditObjectKind Kind,
    string Name,
    string? SamAccountName,
    Guid? ObjectGuid,
    string? Sid,
    string? DnsHostName,
    int? PrimaryGroupId,
    string? Description);

/// <summary>
/// Object named by a security check, a scan or a group (bounded list of the analysis, never the whole directory). Privileged:
/// an account protected by AdminSDHolder (adminCount = 1) or a member of a privileged group, as the reader established it; the
/// grading of a check reads this flag, never the wording of Detail.
/// </summary>
public sealed record AuditObjectRef(
    string Dn,
    string Name,
    AuditObjectKind Kind,
    string? SamAccountName,
    bool? Enabled,
    DateTimeOffset? LastLogon,
    DateTimeOffset? PasswordLastSet,
    string? Detail,
    bool Privileged = false);

// ---------------------------------------------------------------- domain overview (AUD-023) and local totals (AUD-022)

/// <summary>One line of a section of the domain overview (« Annuaire », « Rôles FSMO »…), already in words.</summary>
public sealed record OverviewItemRead(string Label, string Value, Tone? Tone = null);

/// <summary>One section of the domain overview; a refused section never stops the others.</summary>
public sealed record OverviewSectionRead(string Id, string Title, ReadState State, string? Message, ImmutableArray<OverviewItemRead> Items);

/// <summary>
/// Raw result of one security check: the objects found by its bounded search (at most <see cref="Limit"/>), the total
/// count when the server says it, and a scalar value for the checks that read one attribute (krbtgt age, quota…).
/// </summary>
public sealed record SecurityCheckRead(
    string Id,
    ReadState State,
    string? Message,
    ImmutableArray<AuditObjectRef> Objects,
    int Total,
    int Limit,
    long? Value,
    string? ValueText);

public sealed record DomainOverviewRead(
    string Controller,
    DateTimeOffset ReadAt,
    long DurationMs,
    ImmutableArray<OverviewSectionRead> Sections,
    ImmutableArray<SecurityCheckRead> Checks);

/// <summary>Objects of one type and state in the local copy (LocalIndexRead FleetStats).</summary>
public sealed record LocalTypeCount(string Type, bool Disabled, long Count);

public sealed record LocalTotalsRead(ReadState State, string? Message, DateTimeOffset? LastSyncAt, bool Complete, bool Simulated, ImmutableArray<LocalTypeCount> Types);

// ---------------------------------------------------------------- password policy (AUD-011)

public sealed record PsoRead(
    string Dn,
    string Name,
    int? Precedence,
    int? MinLength,
    int? History,
    bool? Complexity,
    bool? Reversible,
    AdInterval MaxAge,
    AdInterval MinAge,
    int? LockoutThreshold,
    AdInterval LockoutDuration,
    AdInterval ObservationWindow,
    int AppliesTo);

public sealed record DomainPolicyRead(
    int? MinLength,
    int? History,
    AdInterval MaxAge,
    AdInterval MinAge,
    int? LockoutThreshold,
    AdInterval LockoutDuration,
    AdInterval ObservationWindow,
    int? PasswordProperties,
    int? MachineAccountQuota);

/// <summary>PasswordPolicyRead worker: user attributes, msDS-ResultantPSO, the PSO it names, the domain policy.</summary>
public sealed record PasswordPolicyRead(
    string Dn,
    string Controller,
    DateTimeOffset ReadAt,
    int UserAccountControl,
    int? ComputedAccountControl,
    long? PasswordLastSet,
    long? PasswordExpiryComputed,
    string? ResultantPso,
    string? ResultantError,
    PsoRead? Pso,
    DomainPolicyRead? Domain,
    int PsoVisibleCount);

// ---------------------------------------------------------------- nested groups (AUD-012, AUD-013)

public sealed record GroupNodeRead(string Dn, string Name, string? Sid, int? AdminCount, ImmutableArray<string> Parents, bool Partial);

public sealed record UnreadGroupRead(string Dn, string Reason);

public sealed record PrimaryGroupRead(string? Dn, string? Name, string? Sid);

/// <summary>GroupPathRead worker (Expand): memberOf of the object, then of each group, bounded.</summary>
public sealed record GroupGraphRead(
    string Dn,
    string Controller,
    DateTimeOffset ReadAt,
    long ElapsedMs,
    ImmutableArray<string> StartParents,
    bool StartComplete,
    string? StartNote,
    ImmutableArray<GroupNodeRead> Nodes,
    ImmutableArray<UnreadGroupRead> Unread,
    PrimaryGroupRead? PrimaryGroup,
    bool Truncated,
    string? TruncatedReason);

/// <summary>GroupPathRead worker (Confirm): the controller's transitive membership test (LDAP_MATCHING_RULE_IN_CHAIN).</summary>
public sealed record MembershipRead(string Dn, string GroupDn, bool? Member, string? Error, string Controller, DateTimeOffset ReadAt);

// ---------------------------------------------------------------- delegations (AUD-021, AUD-014, AUD-015)

/// <summary>One access entry as read (ActiveDirectoryAccessRule), rights as their enumeration names.</summary>
public sealed record AceRead(
    string Sid,
    bool Allow,
    string Rights,
    Guid? ObjectType,
    Guid? InheritedObjectType,
    bool IsInherited,
    string InheritanceType);

public sealed record AclRead(
    string Dn,
    ReadState State,
    string? Message,
    int Total,
    bool Truncated,
    int MaxAces,
    ImmutableArray<AceRead> Aces,
    string? OwnerSid,
    bool Protected,
    ImmutableDictionary<string, string> SidNames,
    string? SidNamesError,
    ImmutableDictionary<Guid, string> GuidNames,
    string Controller,
    DateTimeOffset ReadAt);

/// <summary>tokenGroups of ONE trustee (domain account or group only).</summary>
public sealed record TokenGroupsRead(string Sid, string? Name, ReadState State, string? Message, ImmutableArray<string> GroupSids, string Controller, DateTimeOffset ReadAt);

// ---------------------------------------------------------------- group policy (AUD-016, AUD-017)

public sealed record GpoContainerRead(string Dn, string? GpLink, int GpOptions, ReadState State, string? Message);

public sealed record GpoRead(Guid Guid, string Name, int? Flags, DateTimeOffset? WhenChanged);

public sealed record GpoLinksRead(
    ImmutableArray<GpoContainerRead> Containers,
    ImmutableArray<GpoRead> Gpos,
    ReadState NamesState,
    string? NamesError,
    string Controller,
    DateTimeOffset ReadAt);

public sealed record RsopGpoRead(Guid? Guid, string? Name, bool? AccessDenied, bool? FilterAllowed, bool? Enabled);

public sealed record RsopLinkRead(Guid? Guid, string? Som, long? AppliedOrder);

/// <summary>RSoP read by CIM (root\rsop\computer). Null lists are an incomplete answer, never « nothing applied ».</summary>
public sealed record RsopRead(
    string Computer,
    ReadState State,
    string? Message,
    ImmutableArray<RsopGpoRead>? Gpos,
    ImmutableArray<RsopLinkRead>? Links,
    string? LinksError,
    DateTimeOffset ReadAt);

// ---------------------------------------------------------------- workstation identity (AUD-018)

public sealed record DnsResolutionRead(ReadState State, ImmutableArray<string> Addresses, string? PtrName, string? Message);

public sealed record ReportedIdentityRead(ReadState State, string? ComputerName, string? DnsHostName, string? Domain, string? Message);

public sealed record MachineIdentityRead(string Name, DnsResolutionRead Resolution, ReportedIdentityRead Reported, DateTimeOffset ReadAt);

// ---------------------------------------------------------------- relations (AUD-019, AUD-020)

/// <summary>Nature of an association, from its source (Get-DomeniaRelationKind).</summary>
public enum RelationKind
{
    Declared,
    Console,
    RemoteSession,
    History,
    Imported,
    Clue,
}

public sealed record RelationRecord(RelationKind Kind, string UserLogin, Guid? UserGuid, string Computer, Guid? ComputerGuid, string Source, DateTimeOffset? When);

public sealed record RelationHistoryRow(string UserLogin, string Computer, string Source, RelationKind Kind, bool? VerifiedInAd, DateTimeOffset? ObservedAt, string? Details);

public sealed record RelationHistoryRead(ReadState State, string? Message, int Total, int Limit, ImmutableArray<RelationHistoryRow> Rows);

// ---------------------------------------------------------------- controllers (AUD-004 to AUD-008)

public sealed record ControllerRead(string Name, string DnsHostName, string? OperatingSystem, string? Site, bool ReadOnly, string Dn);

public sealed record ControllerListRead(ImmutableArray<ControllerRead> Controllers, bool Truncated, string? Pdc, string? PdcError, string Controller, DateTimeOffset ReadAt);

/// <summary>One inbound replication link (DS_REPL_NEIGHBOR), dates in UTC; 1601 already turned into « never ».</summary>
public sealed record ReplicationNeighborRead(
    string NamingContext,
    string Partner,
    DateTimeOffset? LastSuccess,
    DateTimeOffset? LastAttempt,
    long LastResult,
    long ConsecutiveFailures,
    bool Never);

public sealed record ControllerProbeRead(
    string Controller,
    ImmutableArray<string> Addresses,
    string? DnsError,
    bool? Ldap,
    bool? Kerberos,
    ReadState RootDse,
    string? RootDseError,
    DateTimeOffset? CurrentTime,
    DateTimeOffset? LocalTime,
    bool? IsSynchronized,
    long? HighestUsn,
    ReadState Replication,
    string? ReplicationError,
    ImmutableArray<ReplicationNeighborRead> Neighbors);

public sealed record ControllerProbesRead(
    ImmutableArray<ControllerProbeRead> Results,
    ImmutableArray<string> SrvRecords,
    ReadState SrvState,
    string? SrvError,
    string? Pdc,
    DateTimeOffset ReadAt);

public sealed record ServiceStateRead(string Name, string State, string StartMode);

public sealed record ControllerServicesRead(string Controller, ReadState State, string? Message, ImmutableArray<ServiceStateRead> Services);

public sealed record ControllerServicesReads(ImmutableArray<ControllerServicesRead> Results, int BudgetSeconds, long ElapsedMs, DateTimeOffset ReadAt);

/// <summary>One attribute's replication metadata (msDS-ReplAttributeMetaData).</summary>
public sealed record ReplicationMetadataRead(string Attribute, int Version, DateTimeOffset? ChangedAt, string? OriginatingController, long LocalUsn, long OriginatingUsn);

public sealed record ControllerReadingRead(
    string Controller,
    bool Reachable,
    string? Error,
    ImmutableDictionary<string, ImmutableArray<string>> Attributes,
    ImmutableArray<ReplicationMetadataRead> Metadata);

public sealed record ObjectComparisonRead(string Dn, string Name, ImmutableArray<ControllerReadingRead> Readings, DateTimeOffset ReadAt);

// ---------------------------------------------------------------- identities of an OU (AUD-009)

public sealed record IdentityScanObject(
    Guid ObjectGuid,
    string Dn,
    string Name,
    AuditObjectKind Kind,
    string? SamAccountName,
    string? UserPrincipalName,
    string? Mail,
    string? EmployeeId,
    string? DnsHostName,
    int UserAccountControl);

public sealed record IdentityScanRead(string BaseDn, bool Subtree, int Limit, ImmutableArray<IdentityScanObject> Objects, bool Truncated, string Controller, DateTimeOffset ReadAt);

public sealed record LocalNameRead(Guid ObjectGuid, string Name);

/// <summary>Names of the local copy for the scanned names (LocalIndexRead ResolveNames), 1 000 of each kind at most.</summary>
public sealed record LocalNamesRead(ReadState State, string? Message, ImmutableArray<LocalNameRead> Computers, ImmutableArray<LocalNameRead> Users, int Compared, int Total, bool Simulated);
