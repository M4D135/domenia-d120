using System.Collections.Immutable;

namespace Domenia.Core;

// Account of the workstation operations (docs/ops/schema.md « Comptes machine », Domenia 1 UX-15, UI-27, FO-19, SE-16:
// MAC-001 to MAC-003). Names only: a password never appears in any of these records.

/// <summary>
/// Where the account of the next workstation operation comes from, in the order of the worker context
/// (Domenia 1 Get-DomeniaMachineAccountInUse): the first configured source wins.
/// </summary>
public enum MachineAccountSource
{
    TemporaryLocal,
    Temporary,
    Typed,
    Remote,
    Connection,
    Windows,
}

/// <summary>Where the account of the secrets reads (LAPS, BitLocker) comes from, in order.</summary>
public enum SecretsAccountSource
{
    Temporary,
    Secrets,
    Directory,
}

/// <summary>State of one level of a cascade.</summary>
public enum MachineLevelState
{
    /// <summary>The first configured level: it serves the next operation.</summary>
    Active,

    /// <summary>Configured, but an earlier level wins.</summary>
    Available,

    /// <summary>Nothing configured at this level.</summary>
    Empty,

    /// <summary>Level of one workstation, and no workstation is chosen.</summary>
    NotApplicable,
}

/// <summary>
/// The account of the next workstation operation in words (Domenia 1 Get-DomeniaMachineAccountLabel): Short feeds the pill,
/// Long the sentences, Pill the text of the « Compte poste » pill. Names only, never a secret.
/// </summary>
public sealed record MachineAccountLabel(MachineAccountSource Source, string Account, string Origin, string Short, string Long, string Pill);

/// <summary>A refusal recorded for an account: the next workstation operation with it is refused until it is validated.</summary>
public sealed record MachineAccountPause(string Account, DateTimeOffset At, string Reason);

/// <summary>One level of the cascade, for the visual of the rule (improvement of MAC-001).</summary>
public sealed record MachineAccountLevel(
    int Rank,
    string Source,
    string Title,
    string Origin,
    string? Account,
    MachineLevelState State,
    string StateLabel,
    Tone Tone,
    string Detail,
    bool Paused,
    string? PauseReason);

/// <summary>The account in service, with its pause after a refusal (improvement of MAC-002).</summary>
public sealed record MachineAccountInUse(
    MachineAccountSource Source,
    string Account,
    string Origin,
    string Short,
    string Long,
    string Pill,
    string Tip,
    int Rank,
    bool Paused,
    string? PauseReason,
    Tone Tone);

/// <summary>The account of the secrets reads and its cascade.</summary>
public sealed record SecretsAccountState(string Account, string Origin, string Long, ImmutableArray<MachineAccountLevel> Levels);

/// <summary>Presence of a workstation as last recorded (no read here).</summary>
public sealed record MachinePresence(string State, string Label, Tone Tone, DateTimeOffset? CheckedAt);

/// <summary>A workstation of the directory, as the panel shows it.</summary>
public sealed record MachineWorkstation(
    Guid Id,
    string Name,
    string? DnsHostName,
    string Dn,
    string Path,
    string? OperatingSystem,
    bool Enabled,
    MachinePresence Presence);

/// <summary>The account typed for the session (names and dates only).</summary>
public sealed record MachineTypedAccount(string Account, DateTimeOffset Since, bool WithCredential);

/// <summary>
/// What one light read on one workstation answered (Domenia 1 LiveConsole: Outcome, error text, category of
/// Get-DomeniaErrorDecision, caption of Win32_OperatingSystem).
/// </summary>
public sealed record MachineTrialObservation(string Outcome, string? ErrorText, string? Category, string? Caption, MachineWorkstation? Workstation);

/// <summary>Verdict of an access trial (Domenia 1 Get-DomeniaRemoteAccessTrialVerdict).</summary>
public enum MachineTrialVerdict
{
    AdminOk,
    Denied,
    Rejected,
    AccountState,
    Unreachable,
    Unknown,
}

/// <summary>One access trial of the session.</summary>
public sealed record MachineTrialResult(
    MachineTrialVerdict Verdict,
    bool Success,
    string Text,
    Tone Tone,
    string Computer,
    string Account,
    string Origin,
    string? Caption,
    bool Candidate,
    bool Simulated,
    DateTimeOffset At);

/// <summary>
/// Result of machine.account.state and of the changes (docs/ops/schema.md § 12). No JSON name carries « password », « pwd » or
/// « secret » (SIMULATION.md § 9, test 43): the secrets cascade is « confidentialReads », the password « credential ».
/// </summary>
public sealed record MachineAccountState(
    MachineAccountInUse InUse,
    string Sentence,
    string? TargetName,
    MachineWorkstation? Target,
    ImmutableArray<MachineAccountLevel> Levels,
    SecretsAccountState ConfidentialReads,
    MachineTypedAccount? Typed,
    bool CredentialRequired,
    string CredentialNote,
    long Generation,
    bool Simulated,
    ImmutableArray<MachineTrialResult> Trials,
    ImmutableArray<string> Safeguards);

/// <summary>Result of machine.account.trial: the verdict and the state after it (a refusal pauses the account).</summary>
public sealed record MachineTrialOutcome(MachineTrialResult Trial, MachineAccountState State);

/// <summary>Error codes of the workstation account (docs/ops/schema.md § 16).</summary>
public static class MachineErrors
{
    public const string AccountInvalid = "machine.accountInvalid";
    public const string AccountInvalidMessage = "Identifiant non reconnu : écrivez DOMAINE\\nom, POSTE\\nom, .\\nom ou nom@domaine. Rien n’a changé.";

    public const string AccountEmpty = "machine.accountEmpty";
    public const string AccountEmptyMessage = "Compte poste vide : rien n’a changé.";

    public const string PasswordMissing = "machine.passwordMissing";
    public const string PasswordMissingMessage = "Mot de passe du compte poste vide : rien n’a changé.";

    public const string PasswordRefused = "machine.passwordRefused";
    public const string PasswordRefusedMessage = "Simulation : aucun mot de passe n’est demandé ni gardé. Laissez le champ vide.";

    public const string TargetUnknown = "machine.targetUnknown";
    public const string TargetUnknownMessage = "Poste introuvable dans l’annuaire : aucun essai n’est parti.";

    public const string TargetMissing = "machine.targetMissing";
    public const string TargetMissingMessage = "Choisissez d’abord un poste : l’essai porte sur un seul poste, jamais sur une liste.";
}
