using System.Collections.Immutable;

namespace Domenia.Core;

public enum ConnectionState
{
    Simulated,
    Connected,
    Disconnected,
}

public enum AuthenticationMethod
{
    None,
    WindowsSession,
    ExplicitCredentials,
}

public enum AuthenticationProtocol
{
    Kerberos,
    Ntlm,
}

public enum RightsLevel
{
    Read,
    Delegated,
    Admin,
    Unknown,
}

public enum CacheState
{
    Fresh,
    Aging,
    Stale,
    Empty,
}

public sealed record DomainIdentity(string? DnsName, string? NetbiosName, string? RootDn);

public sealed record ControllerIdentity(string DnsName, string? Site);

public sealed record AccountIdentity(string Login, string? DisplayName, string? GivenName, string? Dn);

public sealed record AuthenticationInfo(AuthenticationMethod Method, AuthenticationProtocol? Protocol, string Label);

public sealed record RightsInfo(RightsLevel Level, string Label, bool Estimated, string Detail);

/// <summary>State of the local base: last directory read, objects held, and whether the read stopped at its limit.</summary>
public sealed record StoreStatus(DateTimeOffset? LastReadAt, int Objects, bool Complete);

/// <summary>
/// What a source knows about the session, without any read. <see cref="Epoch"/> is the connection generation: it changes at
/// every connection of the session, even with the same account and domain (Domenia 1 $script:DomeniaSessionEpoch); 0 while the
/// session is fixed for the life of the process.
/// </summary>
public sealed record SessionSnapshot(
    ConnectionState Connection,
    DomainIdentity? Domain,
    ControllerIdentity? Controller,
    AccountIdentity Account,
    AuthenticationInfo Authentication,
    ScopeSelection? Scope,
    RightsInfo Rights,
    bool ReadOnly,
    StoreStatus Store,
    long Epoch = 0);

public sealed record SessionConnection(ConnectionState State, string Label);

public sealed record TaskCounters(int Running, int Queued);

public sealed record CacheInfo(CacheState State, string Label, DateTimeOffset? LastReadAt, int Objects, bool Complete);

public sealed record OnboardingStep(string Id, string Label, bool Done);

public sealed record OnboardingInfo(ImmutableArray<OnboardingStep> Steps, int Completed, int Total);

/// <summary>Result of session.info (docs/OPERATIONS.md § 3).</summary>
public sealed record SessionInfo(
    SessionConnection Connection,
    DomainIdentity? Domain,
    ControllerIdentity? Controller,
    AccountIdentity Account,
    AuthenticationInfo Authentication,
    ScopeSelection? Scope,
    RightsInfo Rights,
    bool ReadOnly,
    TaskCounters Tasks,
    CacheInfo Cache,
    OnboardingInfo Onboarding);

/// <summary>Fixed operator texts of the session.</summary>
public static class SessionTexts
{
    public static string ConnectionLabel(ConnectionState state) => state switch
    {
        ConnectionState.Simulated => "Annuaire simulé",
        ConnectionState.Connected => "Annuaire connecté",
        _ => "Annuaire non connecté",
    };

    public static string CacheLabel(CacheState state) => state switch
    {
        CacheState.Fresh => "À jour",
        CacheState.Aging => "À relire bientôt",
        CacheState.Stale => "Ancienne",
        _ => "Vide",
    };

    public static string RightsLabel(RightsLevel level) => level switch
    {
        RightsLevel.Read => "Lecture",
        RightsLevel.Delegated => "Délégués",
        RightsLevel.Admin => "Administration",
        _ => "Non évalués",
    };
}
