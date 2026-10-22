using System.Collections.Immutable;

namespace Domenia.Core;

// Results of the audit.* operations (docs/ops/audit.md): what the page receives, texts already in French. Built from the
// raw reads by the pure rules of this folder; serialized with the contract rules (camelCase, null fields written).

/// <summary>Severity of a finding: Critique, Élevée, Moyenne, Faible, Information.</summary>
public enum Severity
{
    Critical,
    High,
    Medium,
    Low,
    Info,
}

public enum PolicyState
{
    Applies,
    None,
    Unreadable,
}

public enum ControllerVerdict
{
    Clear,
    Check,
    NotRead,
}

public enum EstimateResult
{
    Allowed,
    Denied,
    Partial,
    NotGranted,
}

public enum GpoOutcome
{
    Applied,
    NotApplied,
    Filtered,
    Disabled,
    Unproven,
}

public enum IdentityCoherence
{
    Coherent,
    Unverified,
    Incoherent,
}

/// <summary>One explainable fact: value, state, source and limit (New-DomeniaFact, AUD-002).</summary>
public sealed record AuditFact(string Label, string Value, FactState State, string StateLabel, string? Source, string? Limit);

public sealed record AuditAvailability(bool Allowed, string? Reason);

public sealed record AuditReadsAvailability(
    AuditAvailability Policy,
    AuditAvailability Groups,
    AuditAvailability Acl,
    AuditAvailability GpoLinks,
    AuditAvailability GpoApplied,
    AuditAvailability MachineIdentity,
    AuditAvailability Relations,
    AuditAvailability Comparison);

public sealed record AuditTargetView(
    string Dn,
    AuditObjectKind Kind,
    string KindLabel,
    string Name,
    string? SamAccountName,
    string? ObjectGuid,
    string? Sid,
    string? DnsHostName,
    string Path,
    string? Description,
    AuditReadsAvailability Availability);

// ---------------------------------------------------------------- domain overview and findings

public sealed record AuditScore(int Value, Tone Tone, string Label, string Detail);

public sealed record SeverityCounts(int Critical, int High, int Medium, int Low, int Info, int Passed);

public sealed record AuditFinding(
    string Id,
    Severity Severity,
    string SeverityLabel,
    Tone Tone,
    string Category,
    string Title,
    string Summary,
    int Count,
    string CountLabel,
    bool Passed,
    ReadState State,
    string Source,
    string Limit,
    string Advice,
    AuditObjectKind? ObjectKind,
    bool Explorable,
    bool Truncated,
    int? Delta,
    ImmutableArray<string> Examples);

/// <summary>One control of the catalogue, shown before the first analysis (what it reads and how it is graded at worst).</summary>
public sealed record AuditCheck(string Id, string Category, string Title, Severity Severity, string SeverityLabel, Tone Tone, string Source, string Advice);

public sealed record AuditSectionItem(string Label, string Value, Tone? Tone);

public sealed record AuditSection(string Id, string Title, string Icon, ReadState State, string StateLabel, Tone Tone, string? Message, ImmutableArray<AuditSectionItem> Items);

public sealed record AuditPrevious(DateTimeOffset ReadAt, int Score, int Delta, string Label);

public sealed record AuditOverview(
    DateTimeOffset ReadAt,
    string Controller,
    long DurationMs,
    AuditScore Score,
    SeverityCounts Counts,
    ImmutableArray<AuditFinding> Findings,
    ImmutableArray<AuditSection> Sections,
    int Refused,
    int Anomalies,
    string Summary,
    AuditPrevious? Previous);

public sealed record AuditObjectRow(
    string Dn,
    string Name,
    AuditObjectKind Kind,
    string KindLabel,
    string? SamAccountName,
    bool? Enabled,
    DateTimeOffset? LastLogon,
    DateTimeOffset? PasswordLastSet,
    string? Detail,
    string Container);

public sealed record AuditFindingObjects(
    string Id,
    string Title,
    Severity Severity,
    string SeverityLabel,
    int Total,
    int Shown,
    bool Truncated,
    int Limit,
    DateTimeOffset ReadAt,
    string Summary,
    ImmutableArray<AuditObjectRow> Rows);

public sealed record AuditTotalRow(string Type, string Label, long Count, long Disabled);

public sealed record AuditLocalTotals(ReadState State, string StateLabel, DateTimeOffset? LastSyncAt, bool Complete, bool Simulated, long Total, ImmutableArray<AuditTotalRow> Types, string Summary);

// ---------------------------------------------------------------- controllers

public sealed record AuditControllerRow(string DnsName, string Name, string? Site, string? OperatingSystem, ImmutableArray<string> Roles, bool Pdc, bool ReadOnly, string Dn);

public sealed record AuditControllerList(ImmutableArray<AuditControllerRow> Controllers, string? Pdc, bool Truncated, string Summary, DateTimeOffset ReadAt);

public sealed record AuditHealthRow(
    string Controller,
    ControllerVerdict Verdict,
    string VerdictLabel,
    Tone Tone,
    bool? Ldap,
    bool? Kerberos,
    string Reach,
    string Time,
    double? SkewSeconds,
    string Synchronized,
    string Replication,
    long? Failures,
    string Dns,
    ImmutableArray<string> Reasons,
    string Detail);

public sealed record AuditNeighborRow(
    string Controller,
    string Partner,
    string Partition,
    DateTimeOffset? LastSuccess,
    string LastSuccessLabel,
    DateTimeOffset? LastAttempt,
    string LastAttemptLabel,
    string Result,
    long Failures,
    bool Never,
    Tone Tone);

public sealed record AuditHealth(ImmutableArray<AuditHealthRow> Rows, ImmutableArray<AuditNeighborRow> Neighbors, ImmutableArray<AuditFact> Facts, string Summary, DateTimeOffset ReadAt);

public sealed record AuditServiceRow(string Controller, string? Service, string State, string StartMode, string Finding, Tone Tone);

public sealed record AuditServices(ImmutableArray<AuditServiceRow> Rows, int Skipped, int BudgetSeconds, string Summary, DateTimeOffset ReadAt);

public sealed record AuditComparisonCell(string Controller, string Value, int? Version, DateTimeOffset? ChangedAt, string? Origin);

public sealed record AuditComparisonRow(string Attribute, bool Identical, ImmutableArray<AuditComparisonCell> Values);

public sealed record AuditComparison(
    string Dn,
    string Name,
    ImmutableArray<string> Controllers,
    ImmutableArray<AuditComparisonRow> Rows,
    int Differences,
    bool Comparable,
    ImmutableArray<string> NotRead,
    string Note,
    string Summary,
    DateTimeOffset ReadAt);

// ---------------------------------------------------------------- object reads

public sealed record AuditPolicy(string Dn, PolicyState State, bool PolicyKnown, string Summary, ImmutableArray<AuditFact> Facts, DateTimeOffset? ExpiresAt, string Controller, DateTimeOffset ReadAt);

public sealed record AuditGroupRow(string Dn, string Name, int Depth, string Via, ImmutableArray<string> Path, string State, Tone Tone, bool Cycle, bool Privileged);

public sealed record AuditUnreadGroup(string Dn, string Name, string Reason);

public sealed record AuditPrimaryGroup(string? Dn, string? Name, string? Sid, string Text);

public sealed record AuditGraphNode(string Id, string Label, int Depth, string Kind, bool Privileged, bool Cycle, bool Unread);

public sealed record AuditGraphEdge(string From, string To, bool Cycle);

public sealed record AuditGraph(ImmutableArray<AuditGraphNode> Nodes, ImmutableArray<AuditGraphEdge> Edges);

public sealed record AuditGroups(
    string Dn,
    ImmutableArray<AuditGroupRow> Rows,
    ImmutableArray<string> Cycles,
    ImmutableArray<AuditUnreadGroup> Unread,
    AuditPrimaryGroup? PrimaryGroup,
    bool Truncated,
    int Direct,
    int Nested,
    int MaxDepth,
    int Privileged,
    string Summary,
    AuditGraph Graph,
    string Controller,
    DateTimeOffset ReadAt,
    long ElapsedMs);

public sealed record AuditMembership(string Dn, string GroupDn, string GroupName, bool? Member, bool Certain, ImmutableArray<string> Path, string Text, bool Confirmed, string? Error);

public sealed record AuditAceRow(
    int Index,
    string Trustee,
    string Sid,
    bool Allow,
    string Type,
    string Rights,
    string Target,
    string AppliesTo,
    string Origin,
    string Scope,
    bool Explicit,
    bool OnObject,
    bool DomainAccount,
    string? Risk);

public sealed record AuditTrustee(string Sid, string Name, int Entries, bool DomainAccount);

public sealed record AuditAcl(
    string Dn,
    ReadState State,
    string StateLabel,
    string? Owner,
    string? OwnerSid,
    bool Protected,
    int Total,
    bool Truncated,
    int MaxAces,
    int Explicit,
    int Inherited,
    int Deny,
    ImmutableArray<AuditAceRow> Rows,
    ImmutableArray<AuditTrustee> Trustees,
    string Summary,
    string Limit,
    string Controller,
    DateTimeOffset ReadAt);

public sealed record AuditRightRow(string Id, string Label, EstimateResult Result, string ResultLabel, Tone Tone, string? DecidedBy);

public sealed record AuditEstimate(
    string Dn,
    string Sid,
    string Trustee,
    bool IncludesGroups,
    ReadState GroupsState,
    string? GroupsMessage,
    int GroupCount,
    ImmutableArray<AuditRightRow> Rows,
    string Limits,
    string Summary);

public sealed record AuditGpoRow(
    string Name,
    string? Guid,
    string LinkedTo,
    string? LinkedToDn,
    string Link,
    string Enforced,
    string Inheritance,
    string Expected,
    GpoOutcome Outcome,
    string Result,
    FactState ResultState,
    string Proof,
    string GpoStatus,
    Tone Tone);

public sealed record AuditGpo(
    string Dn,
    ImmutableArray<string> Chain,
    ImmutableArray<AuditGpoRow> Rows,
    ImmutableArray<AuditFact> Facts,
    bool LinksRead,
    bool AppliedProven,
    FactState RsopState,
    string? Computer,
    string Summary,
    DateTimeOffset? LinksReadAt,
    DateTimeOffset? RsopReadAt);

public sealed record AuditMachineIdentity(
    string Dn,
    IdentityCoherence State,
    string StateLabel,
    Tone Tone,
    string Summary,
    ImmutableArray<string> Reasons,
    ImmutableArray<string> Warnings,
    ImmutableArray<AuditFact> Facts,
    string? Address,
    string? Expected,
    string? Reported,
    DateTimeOffset ReadAt);

public sealed record AuditRelationLine(string Fact, string Value, string Badge, string BadgeLabel, string Rule);

public sealed record AuditRelations(string Dn, bool Applicable, ImmutableArray<AuditRelationLine> Lines, int Declared, int Observed, int History, string Text);

public sealed record AuditHistoryRow(DateTimeOffset? At, string DateLabel, string User, string Computer, string Nature, string Badge, string Rule, string Source, string VerifiedInAd, string Details);

public sealed record AuditHistory(string Dn, ReadState State, string StateLabel, int Total, int Shown, int Limit, ImmutableArray<AuditHistoryRow> Rows, string Summary);

// ---------------------------------------------------------------- identities of an OU

public sealed record AuditIdentityObject(string Name, string? Dn);

public sealed record AuditIdentityFinding(string Id, string Category, string Element, ImmutableArray<AuditIdentityObject> Objects, string ObjectsText, string Conclusion, string Limit, Tone Tone);

public sealed record AuditCategoryCount(string Category, int Count);

public sealed record AuditIdentities(
    string BaseDn,
    string Path,
    bool Subtree,
    int Limit,
    int Objects,
    bool Truncated,
    ImmutableArray<AuditIdentityFinding> Findings,
    ImmutableArray<AuditCategoryCount> Categories,
    ReadState LocalIndex,
    string LocalIndexText,
    string Summary,
    string Controller,
    DateTimeOffset ReadAt);
