using System.Collections.Immutable;
using System.Security;

namespace Domenia.Core;

/// <summary>
/// Read interface of the Comptes screen (docs/ops/comptes.md): the accounts of a scope, the detail of one account, its lockout
/// events and the candidates of a collective action. Served by the simulated directory now (Domenia.Simulation,
/// Screens/SimulatedAccountsReader.cs), by Active Directory in wave 3 (bounded LDAP reads on the session controller, after the
/// operator's gesture; the security log of the PDC emulator for the lockouts). Read only by construction.
/// </summary>
public interface IAccountsReader : IScreenReader
{
    /// <summary>Accounts of the scope (never the whole domain: the caller refuses the root), with counts and policy.</summary>
    Task<AccountsList> ListAsync(AccountsScope scope, CancellationToken cancellationToken);

    /// <summary>Detail of the account at this DN; accounts.unknown when no user account has it.</summary>
    Task<AccountsDetail> DetailAsync(string dn, string? operatorDn, CancellationToken cancellationToken);

    /// <summary>
    /// The account at this DN and its 4740 events of the last <paramref name="hours"/> hours, filtered on its SID only (PDC
    /// emulator, or the bound controller, which is said). accounts.unknown when no user account has this DN.
    /// </summary>
    Task<(DirectoryUser User, DomainInfo Domain, LockoutEventsRead Read)> LockoutEventsAsync(string dn, int hours, CancellationToken cancellationToken);

    /// <summary>The users at these DNs as read now (a null user: DN unknown), in the order given.</summary>
    Task<ImmutableArray<AccountsBatchCandidate>> CandidatesAsync(IReadOnlyList<string> dns, CancellationToken cancellationToken);

    /// <summary>Clock and time zone of the source (dates of the rules: the reference of the simulation, the workstation in directory mode).</summary>
    (DateTimeOffset Now, TimeZoneInfo Zone, bool Simulated) Clock { get; }
}

/// <summary>
/// Access reads of the Comptes page (Domenia 1 CPT-002, CPT-013 to CPT-018, CPT-021): one explicit validation of a proposed
/// account (LDAP bind, or a CIM session for a local account of a workstation), one light read of a workstation with the
/// workstation account, and the refusals already known at startup. Simulation: the fictitious directory answers (no password
/// exists there: only the account and its state are checked, and the answer says so). Directory mode: wave 3.
/// </summary>
public interface IAccountsAccessReader : IScreenReader
{
    /// <summary>Validates one account once; the password is a read-only copy owned by the caller.</summary>
    Task<CredentialAnswer> ValidateAsync(CredentialRequest request, SecureString password, CancellationToken cancellationToken);

    /// <summary>
    /// One light read (Win32_OperatingSystem.Caption) of one workstation with the credential the workstation operations take:
    /// a read-only copy of a secondary or temporary account (owned by the caller), or the session itself. Only an explicit
    /// success is « observed »; an account the source does not know is « authRejected ».
    /// </summary>
    Task<RemoteProbeAnswer> ProbeAsync(string computer, RemoteProbeCredential credential, CancellationToken cancellationToken);

    /// <summary>Refusals the source already knows when the session starts (simulation: one fictitious refusal of a LAPS read).</summary>
    Task<ImmutableArray<AccessRequestSeed>> InitialRequestsAsync(CancellationToken cancellationToken);

    /// <summary>SID of the account of the session as the directory confirmed it (aliases of « En ce moment »), or null.</summary>
    Task<string?> SessionSidAsync(CancellationToken cancellationToken);

    /// <summary>Whether this source can open a new session without closing Domenia (CPT-007).</summary>
    bool SessionSwitchAvailable { get; }

    /// <summary>
    /// « Changer de compte » (CPT-007): one explicit authentication of the proposed account; on success the source opens the new
    /// session (same domain) and answers its identity. Nothing is replayed; the caller starts a new epoch.
    /// </summary>
    Task<SessionOpenAnswer> OpenSessionAsync(CredentialRequest request, SecureString password, CancellationToken cancellationToken);

    /// <summary>
    /// Correction of the connection password (CPT-008), once the same identity is confirmed: the source replaces the secret of
    /// the session in memory (SecureString up to the Windows API), stops the reads started with the former one and says whether
    /// another copy of the refused password remains. accounts.correctionUnavailable when the session holds no password.
    /// </summary>
    Task<ConnectionSecretSwap> SwapConnectionPasswordAsync(SecureString password, CancellationToken cancellationToken);

    /// <summary>Whether this source answers with fictitious data (simulation).</summary>
    bool Simulated { get; }

    /// <summary>When the session of this source started (connection time shown by the connection card), or null when unknown.</summary>
    DateTimeOffset? SessionStartedAt { get; }
}
