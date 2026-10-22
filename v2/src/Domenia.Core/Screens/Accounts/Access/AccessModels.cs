using System.Collections.Immutable;
using System.Security;

namespace Domenia.Core;

/// <summary>Secondary accounts of the Comptes page (Domenia 1 CPT-013, CPT-014): workstations, and LAPS and BitLocker secrets.</summary>
public enum AccessUsage
{
    Remote,
    Secrets,
}

/// <summary>Lifetime of a temporary account accepted after a refusal (Domenia 1 CPT-004, D054).</summary>
public enum LeaseMode
{
    /// <summary>Usable while it is used: expires after N minutes without a new use (30 by default, 1 to 480).</summary>
    Inactivity,

    /// <summary>Until the end of the session.</summary>
    Session,

    /// <summary>One use only.</summary>
    OneShot,
}

/// <summary>Lease of a temporary account: bound to the session epoch; a passive read never extends it.</summary>
public sealed record CredentialLease(
    string Scope,
    string Account,
    LeaseMode Mode,
    int InactivityMinutes,
    long Epoch,
    DateTimeOffset CreatedAt,
    DateTimeOffset LastUsedAt,
    int Uses,
    bool Forgotten);

/// <summary>Verdict of a lease for a new use.</summary>
public sealed record LeaseCheck(bool Usable, string Reason);

/// <summary>Remaining life of a lease in words, in whole minutes rounded up (changes once a minute).</summary>
public sealed record LeaseRemaining(bool Usable, int Minutes, string Text);

/// <summary>Form of an account name typed by the operator.</summary>
public enum AccountNameForm
{
    /// <summary>DOMAINE\compte, POSTE\compte or .\compte.</summary>
    DownLevel,

    /// <summary>compte@domaine.</summary>
    Upn,

    /// <summary>A bare name, without domain.</summary>
    Bare,
}

/// <summary>An account name split in its parts (authority: domain, workstation or « . »).</summary>
public sealed record AccountName(AccountNameForm Form, string Authority, string Name);

/// <summary>Whether an account may be proposed for a resource and a target, and why not (refused before any call).</summary>
public sealed record CredentialContextCheck(bool Valid, string Reason);

/// <summary>An access refused by a resource, waiting for the operator (Domenia 1 CPT-001: one per resource and target, 16 at most).</summary>
public sealed record AccessRequest(
    string Id,
    string Scope,
    string ScopeLabel,
    string Operation,
    string? Target,
    string Kind,
    string KindLabel,
    DateTimeOffset At,
    bool Interactive)
{
    /// <summary>Identifier remembered for this resource and target (names only), to prefill « Utiliser un autre compte ».</summary>
    public string? Remembered { get; init; }
}

/// <summary>A refusal a source reports at startup (simulation: fictitious refusal to try the recovery flow).</summary>
public sealed record AccessRequestSeed(string Scope, string Operation, string? Target, string Kind, DateTimeOffset At);

/// <summary>One row of « En ce moment » (CPT-010): the account each resource takes for its next operation, and its state.</summary>
public sealed record AccessInUseRow(
    string Resource,
    string ResourceKey,
    string Account,
    string Origin,
    string State,
    Tone StateTone,
    AccessRowAction? Action);

/// <summary>Direct action of a row towards the one place where its state is settled (CPT-010 improvement).</summary>
public sealed record AccessRowAction(string Id, string Label, string? Argument);

/// <summary>One account kept in memory (CPT-011): resource, name, remaining life and state.</summary>
public sealed record AccessMemoryRow(
    string Key,
    string Resource,
    string Account,
    string Origin,
    string Remaining,
    int Minutes,
    bool Usable,
    string State,
    Tone StateTone);

/// <summary>Identifier remembered for a usage (names only, never a password) and its last use (CPT-016).</summary>
public sealed record RememberedAccount(string Account, DateTimeOffset LastUsedAt);

/// <summary>State of a secondary account card (CPT-013, CPT-014).</summary>
public sealed record SecondaryAccount(
    AccessUsage Usage,
    string Label,
    string? Account,
    bool Active,
    DateTimeOffset? ActivatedAt,
    string? Controller,
    string Status,
    Tone StatusTone,
    RememberedAccount? Remembered,
    ImmutableArray<string> Resources);

/// <summary>The read-only card of the connection account (CPT-006).</summary>
public sealed record ConnectionCard(
    bool Connected,
    string Identity,
    string? DisplayName,
    string Mode,
    string ModeLabel,
    string? Controller,
    string? Site,
    string? Domain,
    string? Netbios,
    DateTimeOffset? Since,
    string Authentication,
    string Detail,
    AccountsAction Correction,
    AccountsAction Relogin);

/// <summary>One of the three identities used (CPT-012): directory, workstations, secrets.</summary>
public sealed record AccessIdentity(string Id, string Label, string Account, string Origin);

/// <summary>The validation running now (CPT-021: one at a time).</summary>
public sealed record AccessValidationState(bool Busy, string? Usage, string? Label, DateTimeOffset? StartedAt, int TimeoutSeconds);

/// <summary>Last trial of the workstation account on a workstation (CPT-015).</summary>
public sealed record RemoteTrial(
    string Computer,
    string Account,
    string Origin,
    string Verdict,
    bool Success,
    string Text,
    string? Caption,
    Tone Tone,
    DateTimeOffset At,
    bool Simulated);

/// <summary>Whether the Windows credential vault can be used for the secondary accounts (CPT-017).</summary>
public sealed record VaultState(bool Available, string Reason);

/// <summary>Default lease of the temporary accounts (Security.AlternateCredentialIdleMinutes).</summary>
public sealed record LeasePolicy(int DefaultMinutes, int MinMinutes, int MaxMinutes);

/// <summary>Result of accounts.access.state.</summary>
public sealed record AccessOverview(
    ConnectionCard Connection,
    ImmutableArray<AccessIdentity> Identities,
    ImmutableArray<AccessRequest> Pending,
    int PendingLimit,
    ImmutableArray<AccessInUseRow> InUse,
    ImmutableArray<AccessMemoryRow> Memory,
    SecondaryAccount Remote,
    SecondaryAccount Secrets,
    AccessValidationState Validation,
    RemoteTrial? LastTrial,
    LeasePolicy Lease,
    VaultState Vault,
    int Refusals,
    long Generation,
    string Summary,
    bool Simulated)
{
    /// <summary>Revision of the state (accounts.access.revision): the page reads the state again only when it changes.</summary>
    public long Revision { get; init; }

    /// <summary>Session epoch: a new one starts with « Changer de compte »; a result of another epoch is dropped.</summary>
    public long Epoch { get; init; }

    /// <summary>Seconds a password shown in clear stays visible (Domenia 1 TRV-219).</summary>
    public int RevealSeconds { get; init; } = AccountsConfiguration.RevealSeconds;
}

/// <summary>
/// accounts.access.revision: what the shell badge and the Accès tab poll each second (names and counts only): the revision of
/// the state, the minute when a lease counts down, the accesses to review and the accounts kept in memory.
/// </summary>
public sealed record AccessRevision(
    long Revision,
    long LeaseMinute,
    int Pending,
    string? OldestPendingId,
    string? OldestPendingLabel,
    int Temporaries,
    int Paused,
    bool Validating,
    long Epoch);

/// <summary>The credential a trial on a workstation uses (CPT-015): a read-only copy, or the session itself (no copy).</summary>
public sealed record RemoteProbeCredential(string Account, SecureString? Password, bool Session);

/// <summary>What a source answers to « Changer de compte » (CPT-007): the validation and the identity of the new session.</summary>
public sealed record SessionOpenAnswer(CredentialAnswer Answer, AccountIdentity? Identity);

/// <summary>
/// What a source did with the corrected password of the connection account (CPT-008): replaced in memory, the reads started
/// with the former one stopped, and whether another copy of the refused password is still held elsewhere (the pause is then
/// kept as it is).
/// </summary>
public sealed record ConnectionSecretSwap(bool Replaced, int StoppedReads, bool OtherRefusedCopy);

/// <summary>Result of accounts.connection.switch: the validation, the new identity and the new epoch.</summary>
public sealed record AccessSwitch(AccessValidation Result, string? Identity, long Epoch);

/// <summary>A credential validation request: who, for which resource, on which workstation.</summary>
public sealed record CredentialRequest(string Login, string Scope, string? Target);

/// <summary>
/// What the source answered to one validation (an explicit authentication with the identity that bound, and its SID when the
/// directory confirmed it).
/// </summary>
public sealed record CredentialAnswer(bool Success, string Kind, string? BindUser, string? Controller, string? Detail, string? Sid = null);

/// <summary>Result of a validation for the page (CPT-021): verdict, identity, controller and what was not tested.</summary>
public sealed record AccessValidation(
    bool Success,
    string Kind,
    string Message,
    string Hint,
    string? Identity,
    string? Controller,
    Tone Tone,
    string RightsNote,
    bool Simulated,
    DateTimeOffset At);

/// <summary>Validation and the state after it (activate, recover).</summary>
public sealed record AccessChange(AccessValidation Result, AccessOverview State);

/// <summary>What a source answers to one light read of a workstation with the workstation account (CPT-015).</summary>
public sealed record RemoteProbeAnswer(string Outcome, string? Category, string? Caption, string? Error);
