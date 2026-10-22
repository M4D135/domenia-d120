using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Which LAPS attribute carries the expiration date. Only dates exist in Domenia, never a password.</summary>
public enum LapsKind
{
    None,
    Legacy,
    Windows,
}

public sealed record DomainController(string DnsName, string? Site);

/// <summary>
/// Default domain policy. <see cref="ComplexityRequired"/> is bit 0x1 of pwdProperties (DOMAIN_PASSWORD_COMPLEX): when it is
/// off, the controller accepts a password without three character classes and Domenia does not ask for them either.
/// </summary>
public sealed record DomainPasswordPolicy(
    TimeSpan MaxPasswordAge,
    int MinPasswordLength,
    int PasswordHistoryLength,
    int LockoutThreshold,
    TimeSpan LockoutDuration,
    TimeSpan LockoutObservationWindow,
    bool ComplexityRequired = true);

/// <summary>Domain identity; <see cref="Containers"/> are the default containers (CN=Users…), which are not OUs.</summary>
public sealed record DomainInfo(
    string DnsName,
    string NetbiosName,
    string RootDn,
    string DomainSid,
    ImmutableArray<DomainController> Controllers,
    DomainPasswordPolicy PasswordPolicy,
    ImmutableArray<string> Containers);

public sealed record DirectoryOu(
    Guid ObjectGuid,
    string DistinguishedName,
    string Name,
    string? Description,
    string? ManagedByDn,
    DateTimeOffset WhenCreated,
    DateTimeOffset WhenChanged,
    long UsnChanged);

/// <summary>User object with the attributes Domenia 1 reads; large integers stay FILETIME values (see <see cref="AdValues"/>).</summary>
public sealed record DirectoryUser(
    Guid ObjectGuid,
    string Sid,
    string DistinguishedName,
    string Cn,
    string SamAccountName,
    string? UserPrincipalName,
    string? DisplayName,
    string? GivenName,
    string? Surname,
    string? Mail,
    string? Title,
    string? Department,
    string? Office,
    string? TelephoneNumber,
    string? ManagerDn,
    string? Description,
    string? EmployeeId,
    int UserAccountControl,
    int? ComputedAccountControl,
    long? LockoutTime,
    int? BadPasswordCount,
    long? PasswordLastSet,
    long? PasswordExpiryComputed,
    long? LastLogonTimestamp,
    long? AccountExpires,
    DateTimeOffset WhenCreated,
    DateTimeOffset WhenChanged,
    long UsnChanged,
    int? AdminCount,
    int PrimaryGroupId,
    ImmutableArray<string> MemberOf);

public sealed record DirectoryComputer(
    Guid ObjectGuid,
    string Sid,
    string DistinguishedName,
    string Name,
    string? DnsHostName,
    string SamAccountName,
    string? Description,
    string? Location,
    string? ManagedByDn,
    string? OperatingSystem,
    string? OperatingSystemVersion,
    int UserAccountControl,
    long? LastLogonTimestamp,
    long? PasswordLastSet,
    DateTimeOffset WhenCreated,
    DateTimeOffset WhenChanged,
    long UsnChanged,
    LapsKind Laps,
    long? LapsExpiration,
    int PrimaryGroupId,
    ImmutableArray<string> MemberOf);

public sealed record DirectoryGroup(
    Guid ObjectGuid,
    string Sid,
    string DistinguishedName,
    string Name,
    string SamAccountName,
    int GroupType,
    string? Description,
    string? Mail,
    string? ManagedByDn,
    int? AdminCount,
    ImmutableArray<string> Members,
    ImmutableArray<string> MemberOf,
    DateTimeOffset WhenCreated,
    DateTimeOffset WhenChanged,
    long UsnChanged);

/// <summary>Immutable picture of a directory at one read.</summary>
public sealed record DirectorySnapshot(
    DomainInfo Domain,
    DateTimeOffset ReadAt,
    bool Complete,
    ImmutableArray<DirectoryOu> OrganizationalUnits,
    ImmutableArray<DirectoryUser> Users,
    ImmutableArray<DirectoryComputer> Computers,
    ImmutableArray<DirectoryGroup> Groups)
{
    /// <summary>The branch actually read; null retains the historical full-domain snapshot format.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public ScopeSelection? Coverage { get; init; }

    /// <summary>Whether the recorded branch includes the requested branch and its depth, independently of truncation.</summary>
    public bool IncludesScope(ScopeSelection requested) => Coverage is null
        || ScopeRules.SameScope(Coverage, requested)
        || (Coverage.Subtree && (ScopeRules.SameScope(Coverage, requested with { Subtree = true }) || ScopeRules.Contains(Coverage, requested.Dn)));

    /// <summary>A complete read of an OU is never a complete census of its parent or of the domain.</summary>
    public bool CoversScope(ScopeSelection requested) => Complete && IncludesScope(requested);

    /// <summary>Directory objects counted by the local base: OUs, users, computers and groups.</summary>
    public int ObjectCount => OrganizationalUnits.Length + Users.Length + Computers.Length + Groups.Length;
}
