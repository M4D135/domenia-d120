using System.Collections.Immutable;

namespace Domenia.Core.Poste;

/// <summary>Presence as the page shows it (Domenia 1 Get-DomeniaComputerPresenceBadge).</summary>
public enum PresenceState
{
    Online,
    Offline,
    Pending,
    Error,
    Unknown,
    Remembered,
}

/// <summary>How an association between a workstation and a user is known (Domenia 1 Get-DomeniaLinkSummaryText).</summary>
public enum AssociationBadge
{
    Declared,
    Observed,
    History,
    Contradictory,
    None,
}

/// <summary>Kind of machine estimated from its name, its chassis and its battery (never asserted).</summary>
public enum MachineKind
{
    Desktop,
    Laptop,
    Server,
    Virtual,
    Unknown,
}

public sealed record DnRef(string Dn, string Name);

public sealed record OuRef(string Dn, string Name, string Path);

public sealed record UserRef(string Name, string Login, string? Dn, Guid? Guid);

/// <summary>A presence test: answer, round trip, address and the time of the test (latest of attempt and answer).</summary>
public sealed record PresenceReading(bool? Answered, int? RoundTripMs, string? Address, DateTimeOffset? CheckedAt, DateTimeOffset? LastOnlineAt, bool Remembered, string Source);

/// <summary>The coloured pill of the header (DS-08): a remembered state never gets a time.</summary>
public sealed record PresenceBadge(PresenceState State, Tone Tone, string Label, string Help, DateTimeOffset? CheckedAt, bool Remembered, int? RoundTripMs);

/// <summary>Computer object as the page needs it: directory attributes only, already read with the object card.</summary>
public sealed record PosteComputer(
    string Dn,
    Guid Guid,
    string Name,
    string? DnsName,
    string SamAccountName,
    string Sid,
    string? OperatingSystem,
    string? OperatingSystemVersion,
    string? Release,
    MachineKind Kind,
    string KindLabel,
    string? Description,
    string? Location,
    DnRef? ManagedBy,
    bool? Enabled,
    int? UserAccountControl,
    string AccountText,
    DateTimeOffset WhenCreated,
    DateTimeOffset WhenChanged,
    DateTimeOffset? PasswordLastSet,
    DateTimeOffset? LastLogonTimestamp,
    string LapsKind,
    DateTimeOffset? LapsExpiration,
    OuRef Ou,
    string? Site,
    ImmutableArray<DnRef> Groups);

/// <summary>Fixed header of the console, common to every view (Domenia 1 Get-DomeniaComputerHeaderView).</summary>
public sealed record PosteHeader(
    string Name,
    string SystemText,
    PresenceBadge Presence,
    UserRef? User,
    string UserText,
    string UserHelp,
    string InventoryText,
    DateTimeOffset? InventoryAt,
    DateTimeOffset? DirectoryReadAt);

/// <summary>One-line summary of the remembered association (Domenia 1 Get-DomeniaLinkSummaryText, point 9).</summary>
public sealed record PosteAssociation(
    UserRef? User,
    AssociationBadge Badge,
    string BadgeLabel,
    Tone Tone,
    string Source,
    DateTimeOffset? At,
    string Rule,
    string Text,
    bool IdentityProven,
    ImmutableArray<AssociationEvent> History);

/// <summary>One step of the history of the associations (improvement: who, when, which source).</summary>
public sealed record AssociationEvent(DateTimeOffset At, string User, string Source, string Detail);

/// <summary>An authorization window of the session (intervention, single fallback read): active until <see cref="Until"/>.</summary>
public sealed record ConsentWindow(bool Active, DateTimeOffset? Until, int RemainingSeconds, string Text, string? OtherComputer);

public sealed record ConsentState(ConsentWindow Intervention, ConsentWindow ReadFallback);

/// <summary>
/// A suite tool (Pesto, FILPRO) and whether it can be opened with context (Domenia 1 point D080, PST-020): its executable
/// (Suite.Pesto, Suite.FilPro) and the SHA-256 expected for it, both checked by the launcher of the host before anything runs.
/// </summary>
public sealed record SuiteTool(string Id, string Label, bool Configured, string Reason, ImmutableArray<string> Fields)
{
    /// <summary>Full path of the executable of the tool (configuration), null when it is not configured.</summary>
    public string? Path { get; init; }

    /// <summary>SHA-256 expected for the executable (configuration), null when none is declared (the launch is then refused).</summary>
    public string? Sha256 { get; init; }
}

/// <summary>Remote settings of the mode (Domenia.config.json in directory mode; fixed values in simulation).</summary>
public sealed record PosteOptions(
    bool UseWinRm,
    bool WakeOnLan,
    string WakeReason,
    ImmutableArray<string> WakeNetworks,
    int RestartDelaySeconds,
    ImmutableArray<int> RestartMinutes,
    string? OperationsAccount,
    ImmutableArray<SuiteTool> SuiteTools,
    string SimulationNote);

/// <summary>Summary of the last non-secret secrets metadata stored for the workstation (PST-065).</summary>
public sealed record SecretsSummary(string Text, int? BitLockerKeys, DateTimeOffset? BitLockerReadAt, string LapsKind, DateTimeOffset? LapsExpiration, bool LapsExpired, string Identity, string IdentityReason, bool BitLockerDenied, bool LapsDenied);

/// <summary>Last live reading of the session (presence, uptime, console user, sessions).</summary>
public sealed record PosteLive(
    PresenceReading Presence,
    DateTimeOffset? LastBoot,
    string? UptimeText,
    UserRef? ConsoleUser,
    string ConsoleText,
    int? Sessions,
    string SessionsText,
    DateTimeOffset At,
    ImmutableArray<PosteFact> Facts);

/// <summary>What the console knows of the last inventory: when, how deep, from the local base or this session.</summary>
public sealed record InventorySummary(DateTimeOffset At, bool Deep, string ModeLabel, string AgeText, string Origin, int Sources, int Refused, int DurationMs, string Transport);

/// <summary>Navigation inside the console (Domenia 1 Resolve-DomeniaComputerViewRoute): view, inner tab, section.</summary>
public sealed record PosteRoute(string View, string? Tab, string? Section, string Label);

/// <summary>Result of poste.open: everything the console shows without any network read.</summary>
public sealed record PosteConsole(
    PosteComputer Computer,
    PosteHeader Header,
    PosteAssociation Association,
    PosteLive? Live,
    InventorySummary? Inventory,
    PosteBoard? Board,
    string? NoInventoryText,
    SecretsSummary Secrets,
    ConsentState Consent,
    PosteOptions Options,
    bool ReadOnly,
    bool Simulated,
    ImmutableArray<PosteFact> Notes);

/// <summary>Health of a workstation in the master list, from the directory and the stored observations only.</summary>
public sealed record PosteRowHealth(Tone Level, int Points, string Label);

/// <summary>One workstation of the master list (poste.list).</summary>
public sealed record PosteRow(
    string Dn,
    Guid Guid,
    string Name,
    string? DnsName,
    bool? Enabled,
    string? Os,
    string? Release,
    MachineKind Kind,
    string? Site,
    string Ou,
    UserRef? User,
    PresenceState Presence,
    string PresenceLabel,
    DateTimeOffset? PresenceAt,
    DateTimeOffset? InventoryAt,
    PosteRowHealth Health);

/// <summary>Result of poste.list: the workstations of the working OU, filtered locally.</summary>
public sealed record PosteList(ScopeSelection? Scope, int Total, int Shown, bool Truncated, string? Text, string Summary, ImmutableArray<PosteRow> Rows);
