using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Lock situation of an account as the screen shows it (Get-DomeniaAccountState and the lockoutTime rule).</summary>
public enum AccountLock
{
    Unlocked,
    Locked,

    /// <summary>lockoutTime is set but the computed state is unreadable: never reported as locked (Domenia 1).</summary>
    ToCheck,

    /// <summary>lockoutTime is still set, the controller says the account is no longer locked (duration elapsed).</summary>
    Expired,
}

/// <summary>Main status of one account row, from the most to the least urgent (one pill per row).</summary>
public enum AccountStatus
{
    Locked,
    LockToCheck,
    Disabled,
    AccountExpired,
    PasswordExpired,
    MustChange,
    Expiring,
    Ok,
}

/// <summary>Scope of the Comptes section: its own choice, else the working OU of the session (decision of 21/10).</summary>
public enum AccountsScopeOrigin
{
    /// <summary>Chosen in the Comptes screen and remembered for this domain.</summary>
    Section,

    /// <summary>The working OU of the session (default of every section without a choice of its own).</summary>
    Working,
}

/// <summary>Scope of the account list: OU, its readable path, sub-OUs or not, and where the choice comes from.</summary>
public sealed record AccountsScope(string Dn, string Label, string Path, bool Subtree, AccountsScopeOrigin Origin);

/// <summary>Domain password and lockout policy in plain numbers (default domain policy).</summary>
public sealed record AccountsPolicy(
    int MaxPasswordAgeDays,
    int MinPasswordLength,
    int PasswordHistory,
    int LockoutThreshold,
    int LockoutMinutes,
    int ObservationMinutes,
    string Label);

/// <summary>Counts of the accounts of the scope (exact, from the same rules as the rows).</summary>
public sealed record AccountsCounts(
    int Total,
    int Enabled,
    int Disabled,
    int Locked,
    int LockToCheck,
    int LockExpired,
    int PasswordExpired,
    int PasswordExpiring,
    int MustChange,
    int NeverExpires,
    int AccountExpired,
    int AccountExpiring,
    int Privileged,
    int NeverLoggedOn,
    int Stale);

/// <summary>One account of the list (docs/ops/comptes.md, accounts.list). No secret, only dates.</summary>
public sealed record AccountsRow(
    string Dn,
    string Guid,
    string Sam,
    string Name,
    string? Upn,
    string? Title,
    string? Department,
    string? Office,
    string Ou,
    bool Enabled,
    AccountLock Lock,
    DateTimeOffset? LockedAt,
    int? BadPasswordCount,
    PasswordClass Password,
    DateTimeOffset? PasswordLastSet,
    DateTimeOffset? PasswordExpiresAt,
    bool PasswordEstimated,
    DateTimeOffset? AccountExpiresAt,
    bool AccountExpired,
    DateTimeOffset? LastLogon,
    bool Privileged,
    AccountStatus Status,
    string StatusLabel,
    Tone Tone);

/// <summary>An OU that holds user accounts, proposed when the scope holds none (the working OU is often « Postes »).</summary>
public sealed record AccountsScopeSuggestion(string Dn, string Name, string Path, int Users);

/// <summary>
/// Result of accounts.list. <see cref="TooWide"/>: the scope is the whole domain, no account was read (never the whole domain);
/// the suggestions propose the OUs that hold accounts.
/// </summary>
public sealed record AccountsList(
    AccountsScope Scope,
    bool TooWide,
    DateTimeOffset ReadAt,
    string? Controller,
    bool Simulated,
    AccountsPolicy Policy,
    AccountsCounts Counts,
    ImmutableArray<AccountsRow> Rows,
    bool Truncated,
    int Limit,
    ImmutableArray<AccountsScopeSuggestion> Suggestions);

/// <summary>Identity block of the detail of an account.</summary>
public sealed record AccountsIdentity(
    string Cn,
    string? DisplayName,
    string? GivenName,
    string? Surname,
    string? Mail,
    string? Telephone,
    string? EmployeeId,
    AccountsLink? Manager,
    string? Description,
    string Sid,
    DateTimeOffset Created,
    DateTimeOffset Changed,
    long Usn);

/// <summary>A linked object (manager): its DN and its readable name when it is known.</summary>
public sealed record AccountsLink(string Dn, string Name);

/// <summary>Password block: dates, class and the share of the maximum age already used (null when unknown).</summary>
public sealed record AccountsPassword(
    DateTimeOffset? LastSet,
    DateTimeOffset? ExpiresAt,
    bool Estimated,
    PasswordClass Class,
    string Label,
    int? AgeDays,
    int MaxAgeDays,
    double? Percent,
    Tone Tone);

/// <summary>Computed state of the account (FIC-043): flags and their dates.</summary>
public sealed record AccountsState(
    bool Disabled,
    AccountLock Lock,
    DateTimeOffset? LockedAt,
    DateTimeOffset? LockEndsAt,
    int? BadPasswordCount,
    bool PasswordExpired,
    bool PasswordNeverExpires,
    bool PasswordNotRequired,
    bool SmartCardRequired,
    bool Privileged,
    DateTimeOffset? AccountExpiresAt,
    bool AccountExpired,
    DateTimeOffset? LastLogon);

/// <summary>One fact of the support band or of the lockout report: what was read, from where, and its limit.</summary>
public sealed record AccountsFact(string Label, string Value, Tone Tone, string? Source, string? Limit, string? Hypothesis);

/// <summary>
/// Support band of an account (FIC-048): only what the controller answered, with the actions that make sense now
/// (« unlock », « lockouts », « reset »). Null when nothing is worth saying.
/// </summary>
public sealed record AccountsBand(Tone Tone, string Title, string Detail, ImmutableArray<AccountsFact> Facts, ImmutableArray<string> Actions);

/// <summary>Whether an action can be prepared now, and why not (the page shows the reason on the greyed control).</summary>
public sealed record AccountsAction(bool Available, string? Reason);

/// <summary>The account actions of the screen and their availability.</summary>
public sealed record AccountsActions(
    AccountsAction Unlock,
    AccountsAction Enable,
    AccountsAction Disable,
    AccountsAction ResetPassword,
    AccountsAction MustChange,
    AccountsAction Expiration,
    AccountsAction Lockouts);

/// <summary>Group memberships of the account: count, and the privileged groups by name.</summary>
public sealed record AccountsGroups(int Count, int PrimaryGroupId, ImmutableArray<string> Privileged);

/// <summary>Result of accounts.detail.</summary>
public sealed record AccountsDetail(
    AccountsRow Account,
    AccountsIdentity Identity,
    AccountsState State,
    AccountsPassword PasswordInfo,
    AccountsBand? Band,
    AccountsActions Actions,
    AccountsGroups Groups,
    AccountsPolicy Policy,
    string? Controller,
    DateTimeOffset ReadAt,
    bool Simulated);

/// <summary>How the security log of the lockout report was read.</summary>
public enum LockoutReadState
{
    Read,
    Refused,
    Unavailable,
}

/// <summary>A Domenia refusal near a lockout event (FIC-045): a lead to check, never a proof.</summary>
public sealed record LockoutDomeniaMatch(bool Near, int? Seconds, bool Ambiguous, string Label);

/// <summary>One lockout event 4740 of the account.</summary>
public sealed record LockoutEvent(DateTimeOffset At, string CallerComputer, string Controller, LockoutDomeniaMatch Domenia);

/// <summary>A computer at the origin of lockouts and how many it caused in the window.</summary>
public sealed record LockoutOrigin(string Computer, int Count, double Share);

/// <summary>Account of a lockout report.</summary>
public sealed record LockoutAccount(string Dn, string Name, string Sam, string Sid);

/// <summary>Result of accounts.lockouts (FIC-040, FIC-045).</summary>
public sealed record LockoutReport(
    LockoutAccount Account,
    string Server,
    string ServerSource,
    string ServerLabel,
    int Hours,
    DateTimeOffset From,
    DateTimeOffset To,
    int MaxEvents,
    bool Truncated,
    LockoutReadState State,
    ImmutableArray<LockoutEvent> Events,
    ImmutableArray<LockoutOrigin> Origins,
    ImmutableArray<AccountsFact> Facts,
    AccountLock Verdict,
    string Summary,
    bool Simulated);

/// <summary>A refusal of authentication recorded by Domenia (credential guard), used to explain lockouts.</summary>
public sealed record DomeniaRefusal(DateTimeOffset At, string? AccountKey, string Kind);

/// <summary>Raw lockout event as the source reads it (before the correlation with the Domenia refusals).</summary>
public sealed record LockoutEventRead(DateTimeOffset At, string CallerComputer, string Controller);

/// <summary>What a source returns for the lockout events of one account.</summary>
public sealed record LockoutEventsRead(
    LockoutReadState State,
    string Server,
    bool PdcEmulator,
    ImmutableArray<LockoutEventRead> Events,
    bool Truncated);

/// <summary>Collective actions of the screen (TRV-229).</summary>
public enum AccountsBatchAction
{
    Unlock,
    Enable,
    Disable,
    MustChange,
    Expiration,
}

/// <summary>One exact target of a collective action and what it receives.</summary>
public sealed record AccountsBatchTarget(string Dn, string Guid, string Name, string Sam, string Change, string? Before, string? After, int Index);

/// <summary>A candidate left out of a collective action, with its reason.</summary>
public sealed record AccountsBatchExclusion(string? Dn, string Name, string Reason);

/// <summary>Exclusions grouped by reason, largest group first.</summary>
public sealed record AccountsBatchGroup(string Reason, int Count);

/// <summary>Result of accounts.batch.preview: the exact list, the exclusions, the impact and the confirmation to give.</summary>
public sealed record AccountsBatchPreview(
    AccountsBatchAction Action,
    string ActionLabel,
    string Title,
    string Kind,
    string PlanOperation,
    int Count,
    string Confirmation,
    string? TypedCount,
    ImmutableArray<AccountsBatchTarget> Targets,
    int Shown,
    ImmutableArray<AccountsBatchExclusion> Excluded,
    ImmutableArray<AccountsBatchGroup> ExcludedGroups,
    int ExcludedCount,
    string Impact,
    ImmutableArray<WriteRisk> Risks,
    ImmutableArray<string> Lines,
    string Details,
    int Limit,
    DateOnly? Date,
    bool Simulated);

/// <summary>A candidate of a collective action as read from the directory (null user: DN unknown).</summary>
public sealed record AccountsBatchCandidate(string Dn, DirectoryUser? User);
