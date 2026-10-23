using System.Collections.Immutable;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Accounts Domenia works with (Domenia 1 CPT-001 to CPT-021, Domenia-Access.UI.ps1, Domenia-Accounts.*.ps1): the connection
/// account (read only), the secondary accounts for the workstations and for the secrets, the temporary accounts accepted after
/// a refusal with their lease, the accesses waiting for the operator, the pauses after a refused authentication (by account
/// key, as Domenia 1: every resource that uses the paused account shows it), the refusals recorded for the lockout diagnosis,
/// and the single validation running at a time. Passwords are kept as read-only <see cref="SecureString"/> copies, disposed
/// when they are replaced, forgotten or expire; names only reach the page, never a secret. Nothing here is tested by itself:
/// an account without a recorded refusal is « Aucun refus enregistré », never « valide ». No change while a write is running or
/// waiting for its re-read (an account is never changed under a write). « Changer de compte » starts a new session epoch: every
/// account, refusal and result of the former one is forgotten. Thread safe.
/// </summary>
public sealed class AccountAccess : IDisposable
{
    /// <summary>Validation of one account (Domenia 1: 12 s in the Comptes page).</summary>
    public const int ValidationTimeoutSeconds = 12;

    /// <summary>Trial of the workstation account on one workstation (Domenia 1: 30 s at most).</summary>
    public const int TrialTimeoutSeconds = 30;

    /// <summary>Refusals kept for the lockout diagnosis (Domenia 1: the 64 last of the session).</summary>
    public const int RefusalCapacity = 64;

    public const string ValidationBusy = "accounts.validationBusy";
    public const string WritePending = "accounts.writePending";
    public const string ContextRefused = "accounts.credentialContext";
    public const string RequestUnknown = "accounts.requestUnknown";
    public const string KeyUnknown = "accounts.keyUnknown";
    public const string CorrectionUnavailable = "accounts.correctionUnavailable";
    public const string ReloginUnavailable = "accounts.reloginUnavailable";
    public const string TrialBusy = "accounts.trialBusy";
    public const string ComputerUnknown = "accounts.computerUnknown";
    public const string EpochChanged = "accounts.epochChanged";

    public const string RememberedPrefix = "accounts.remembered.";

    private static readonly JsonSerializerOptions ValueJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    /// <summary>Refusal kinds of an authentication: they pause the account (the access denied of a right does not).</summary>
    private static readonly HashSet<string> AuthenticationKinds = new(StringComparer.Ordinal)
    {
        "logonFailure", "badCredentials", "locked", "passwordExpired", "mustChange", "disabled", "accountExpired", "restricted",
    };

    private readonly IDirectorySource directory;
    private readonly IAccountsAccessReader? reader;
    private readonly IAccountsConfigurationReader? settings;
    private readonly IPreferenceStore preferences;
    private readonly OperationJournal journal;
    private readonly TimeProvider clock;
    private readonly ITechnicalJournal log;
    private readonly AppMode mode;
    private readonly Func<CancellationToken, Task<int>> pendingWrites;
    private readonly Lock gate = new();
    private readonly SemaphoreSlim validationGate = new(1, 1);
    private readonly Dictionary<AccessUsage, Held> secondary = [];
    private readonly Dictionary<string, Temporary> temporary = new(StringComparer.Ordinal);
    private readonly Dictionary<string, AccessRequest> pending = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Fault> faults = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> sids = new(StringComparer.Ordinal);
    private readonly List<DomeniaRefusal> refusals = [];
    private AccountsConfiguration? configuration;
    private SessionSnapshot? lastSession;
    private bool sessionSidRead;
    private long epoch = 1;
    private long revision = 1;
    private RemoteTrial? lastTrial;
    private Running? running;
    private int trialRunning;
    private long generation;
    private bool seeded;
    private int requestCounter;

    public AccountAccess(
        IDirectorySource directory,
        IAccountsAccessReader? reader,
        IPreferenceStore preferences,
        OperationJournal journal,
        TimeProvider clock,
        ITechnicalJournal log,
        AppMode mode,
        Func<CancellationToken, Task<int>> pendingWrites,
        IAccountsConfigurationReader? settings = null)
    {
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(preferences);
        ArgumentNullException.ThrowIfNull(journal);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        ArgumentNullException.ThrowIfNull(pendingWrites);
        this.directory = directory;
        this.reader = reader;
        this.settings = settings;
        this.preferences = preferences;
        this.journal = journal;
        this.clock = clock;
        this.log = log;
        this.mode = mode;
        this.pendingWrites = pendingWrites;
    }

    /// <summary>The access state shared by the modules of the context.</summary>
    public static AccountAccess From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new AccountAccess(c.Directory, c.Readers.Find<IAccountsAccessReader>(), c.Preferences, c.Journal, c.Clock, c.Log, c.Mode,
            async ct =>
            {
                try
                {
                    return (await WriteCircuit.From(c).ListAsync(ct).ConfigureAwait(false)).Pending;
                }
                catch (DomeniaOperationException)
                {
                    // Receipts unreadable for now: no account change under a write that may be uncertain (fail closed).
                    return 1;
                }
            },
            c.Readers.Find<IAccountsConfigurationReader>()));
    }

    /// <summary>Settings of Domenia.config.json in force for the accounts (defaults of Domenia 1 without the file).</summary>
    public async Task<AccountsConfiguration> ConfigurationAsync(CancellationToken cancellationToken)
    {
        lock (gate)
        {
            if (configuration is not null)
            {
                return configuration;
            }
        }
        var read = settings is null ? AccountsConfiguration.Defaults : await settings.CurrentAsync(cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            configuration ??= read;
            return configuration;
        }
    }

    /// <summary>accounts.access.state: everything the Accès tab shows. Never reads the network.</summary>
    public async Task<AccessOverview> OverviewAsync(CancellationToken cancellationToken)
    {
        var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
        await SeedAsync(cancellationToken).ConfigureAwait(false);
        await LearnSessionSidAsync(session, cancellationToken).ConfigureAwait(false);
        var config = await ConfigurationAsync(cancellationToken).ConfigureAwait(false);
        var now = clock.GetUtcNow();
        var rootKey = RootHash(session);
        var remoteRemembered = Remembered(rootKey, "remote");
        var secretsRemembered = Remembered(rootKey, "secrets") ?? Latest(Remembered(rootKey, "laps"), Remembered(rootKey, "bitlocker"));
        List<AccessRequest> waiting;
        lock (gate)
        {
            waiting = [.. pending.Values];
        }
        // Preferences are read outside the lock (a first read may touch the disk).
        var requestRemembered = waiting.ToDictionary(r => r.Id, r => RequestRemembered(rootKey, r), StringComparer.Ordinal);
        lock (gate)
        {
            Sweep(now);
            var connection = Connection(session);
            var machine = MachineAccount(session);
            var secretsAccount = secondary.TryGetValue(AccessUsage.Secrets, out var secretsHeld) ? secretsHeld.Login : null;
            var identities = ImmutableArray.Create(
                new AccessIdentity("directory", "Annuaire", session.Account.Login, connection.ModeLabel),
                new AccessIdentity("remote", "Postes", machine.Account, machine.Origin),
                new AccessIdentity("secrets", "Secrets LAPS et BitLocker", secretsAccount ?? "Compte AD courant", secretsAccount is null ? "même compte que l’annuaire" : "compte Secrets de la page Comptes"));
            var inUse = InUseRows(session, connection, machine);
            var memory = MemoryRows(session, now);
            var pendingRows = pending.Values.OrderBy(p => p.At)
                .Select(p => p with { Remembered = requestRemembered.GetValueOrDefault(p.Id)?.Account })
                .ToImmutableArray();
            var validation = running is Running r
                ? new AccessValidationState(true, r.Usage, r.Label, r.StartedAt, ValidationTimeoutSeconds)
                : new AccessValidationState(false, null, null, null, ValidationTimeoutSeconds);
            var summaryParts = new List<string>
            {
                memory.Length == 0 ? "Aucun compte temporaire en mémoire" : FrenchText.Count(memory.Length, "compte en mémoire", "comptes en mémoire"),
                pendingRows.Length == 0 ? "aucun accès à revoir" : FrenchText.Count(pendingRows.Length, "accès à revoir", "accès à revoir"),
            };
            if (faults.Count > 0)
            {
                summaryParts.Add(FrenchText.Count(faults.Count, "compte en pause", "comptes en pause"));
            }
            return new AccessOverview(
                connection,
                identities,
                pendingRows,
                CredentialRules.PendingLimit,
                inUse,
                memory,
                Secondary(session, AccessUsage.Remote, remoteRemembered),
                Secondary(session, AccessUsage.Secrets, secretsRemembered),
                validation,
                lastTrial,
                new LeasePolicy(config.AlternateCredentialIdleMinutes, CredentialRules.MinLeaseMinutes, CredentialRules.MaxLeaseMinutes),
                Vault(),
                refusals.Count,
                generation,
                string.Join(" · ", summaryParts) + ".",
                mode == AppMode.Simulation)
            {
                Revision = revision,
                Epoch = epoch,
                RevealSeconds = AccountsConfiguration.RevealSeconds,
            };
        }
    }

    /// <summary>
    /// accounts.access.revision (CPT-010: refreshed each second only when the content changed): the revision of the state, the
    /// minute of a lease that counts down, and the counts of the shell badge (CPT-001). Never reads the network.
    /// </summary>
    public async Task<AccessRevision> RevisionAsync(CancellationToken cancellationToken)
    {
        await SeedAsync(cancellationToken).ConfigureAwait(false);
        var now = clock.GetUtcNow();
        lock (gate)
        {
            Sweep(now);
            var counting = temporary.Values.Any(t => t.Lease.Mode == LeaseMode.Inactivity);
            var oldest = pending.Values.OrderBy(p => p.Interactive ? 0 : 1).ThenBy(p => p.At).FirstOrDefault();
            return new AccessRevision(
                revision,
                counting ? now.ToUnixTimeSeconds() / 60 : 0,
                pending.Count,
                oldest?.Id,
                oldest is null ? null : oldest.Operation + " · " + oldest.ScopeLabel + (oldest.Target is null ? "" : " · " + oldest.Target),
                temporary.Count,
                faults.Count,
                running is not null,
                epoch);
        }
    }

    /// <summary>accounts.access.test: validates a secondary account without activating it (CPT-014 « Tester »).</summary>
    public async Task<AccessValidation> TestAsync(AccessUsage usage, string login, SecureString password, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(login);
        ArgumentNullException.ThrowIfNull(password);
        var scope = usage == AccessUsage.Remote ? CredentialRules.Remote : CredentialRules.Laps;
        return await ValidateAsync(CredentialRules.UsageLabel(usage) + " (test)", CredentialRules.UsageId(usage), new CredentialRequest(login, scope, null), password, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// accounts.access.activate (CPT-013, CPT-014): one validation, then the account replaces only the temporary accounts of its
    /// resources (D051) and their refusals; its own pause is lifted (a validation that succeeds lifts the pause of this account
    /// only, TRV-221); the identifier (never the password) is remembered for this domain (CPT-016).
    /// </summary>
    public async Task<AccessChange> ActivateAsync(AccessUsage usage, string login, SecureString password, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(login);
        ArgumentNullException.ThrowIfNull(password);
        await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
        var scope = usage == AccessUsage.Remote ? CredentialRules.Remote : CredentialRules.Laps;
        var startEpoch = Epoch();
        var result = await ValidateAsync(CredentialRules.UsageLabel(usage), CredentialRules.UsageId(usage), new CredentialRequest(login, scope, null), password, cancellationToken).ConfigureAwait(false);
        if (result.Success)
        {
            var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
            var identity = result.Identity ?? login.Trim();
            var copy = password.Copy();
            copy.MakeReadOnly();
            var now = clock.GetUtcNow();
            lock (gate)
            {
                EnsureEpochLocked(startEpoch, copy);
                if (secondary.Remove(usage, out var previous))
                {
                    previous.Dispose();
                }
                secondary[usage] = new Held(identity, copy, now, result.Controller);
                foreach (var resource in CredentialRules.ResourcesOf(usage))
                {
                    if (temporary.Remove(resource, out var replaced))
                    {
                        faults.Remove(Key(session, replaced.Login, null));
                        replaced.Dispose();
                    }
                    foreach (var key in pending.Where(p => p.Value.Scope == resource).Select(p => p.Key).ToList())
                    {
                        pending.Remove(key);
                    }
                }
                faults.Remove(Key(session, identity, null));
                AccountChangedLocked();
            }
            await RememberAsync(RootHash(session), CredentialRules.UsageId(usage), identity, now, cancellationToken).ConfigureAwait(false);
            journal.Add(new JournalEntry(now, CredentialRules.UsageLabel(usage) + " activé" + FrenchText.Colon + identity + " (droits sur la ressource non certifiés par ce test)", Tone.Info));
            log.Info($"Compte secondaire {CredentialRules.UsageId(usage)} activé après validation.");
        }
        return new AccessChange(result, await OverviewAsync(cancellationToken).ConfigureAwait(false));
    }

    /// <summary>accounts.access.clear: back to the connection account for this usage (« Effacer »); its pause goes with it.</summary>
    public async Task<AccessOverview> ClearAsync(AccessUsage usage, CancellationToken cancellationToken)
    {
        await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
        var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
        bool removed;
        lock (gate)
        {
            removed = secondary.Remove(usage, out var previous);
            if (removed)
            {
                faults.Remove(Key(session, previous!.Login, null));
                previous.Dispose();
                AccountChangedLocked();
            }
        }
        if (removed)
        {
            journal.Add(new JournalEntry(clock.GetUtcNow(), CredentialRules.UsageLabel(usage) + " effacé" + FrenchText.Colon + "retour au compte de connexion", Tone.Info));
        }
        return await OverviewAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// accounts.access.recover (CPT-002): another account for the resource of a waiting access, checked for its context
    /// (CPT-003) before any call, validated once, then kept for that resource (and target) only, with its lease (CPT-004).
    /// The identifier is remembered for that resource (RemoteLocal:&lt;poste&gt; for a local account, never the Postes account).
    /// Nothing is replayed: the operator starts the action again himself.
    /// </summary>
    public async Task<AccessChange> RecoverAsync(string requestId, string login, SecureString password, LeaseMode leaseMode, int minutes, string? target, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(requestId);
        ArgumentNullException.ThrowIfNull(login);
        ArgumentNullException.ThrowIfNull(password);
        await SeedAsync(cancellationToken).ConfigureAwait(false);
        await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
        AccessRequest request;
        lock (gate)
        {
            request = pending.GetValueOrDefault(requestId)
                ?? throw new DomeniaOperationException(RequestUnknown, "Cet accès n’est plus en attente" + FrenchText.Colon + "rien n’a été changé.");
        }
        var startEpoch = Epoch();
        var scopeTarget = request.Scope == CredentialRules.Remote ? target ?? request.Target : null;
        var result = await ValidateAsync("Autre compte pour " + request.ScopeLabel, "recover", new CredentialRequest(login, request.Scope, scopeTarget), password, cancellationToken).ConfigureAwait(false);
        if (result.Success)
        {
            var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
            var identity = result.Identity ?? login.Trim();
            var now = clock.GetUtcNow();
            var local = request.Scope == CredentialRules.Remote && scopeTarget is not null && CredentialRules.IsLocalAccount(login, scopeTarget);
            var key = local ? CredentialRules.RemoteLocalPrefix + CredentialRules.MachineKey(scopeTarget).ToUpperInvariant() : request.Scope;
            var copy = password.Copy();
            copy.MakeReadOnly();
            lock (gate)
            {
                EnsureEpochLocked(startEpoch, copy);
                if (temporary.Remove(key, out var replaced))
                {
                    faults.Remove(Key(session, replaced.Login, scopeTarget));
                    replaced.Dispose();
                }
                temporary[key] = new Temporary(identity, scopeTarget, copy, CredentialRules.NewLease(key, identity, leaseMode, minutes, epoch, now));
                foreach (var stale in pending.Where(p => p.Value.Scope == request.Scope).Select(p => p.Key).ToList())
                {
                    pending.Remove(stale);
                }
                faults.Remove(Key(session, identity, scopeTarget));
                AccountChangedLocked();
            }
            await RememberAsync(RootHash(session), RememberUsageFor(request.Scope, scopeTarget, local ? login : null), identity, now, cancellationToken).ConfigureAwait(false);
            journal.Add(new JournalEntry(now, "Autre compte validé pour " + request.ScopeLabel + FrenchText.Colon + identity + "\u00A0; relancez l’action vous-même", Tone.Info));
            log.Info("Compte temporaire accepté après un refus (aucun secret conservé hors mémoire).");
        }
        return new AccessChange(result, await OverviewAsync(cancellationToken).ConfigureAwait(false));
    }

    /// <summary>accounts.access.dismiss: the operator keeps the current account; the waiting access is closed.</summary>
    public async Task<AccessOverview> DismissAsync(string requestId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(requestId);
        await SeedAsync(cancellationToken).ConfigureAwait(false);
        AccessRequest? removed;
        lock (gate)
        {
            pending.Remove(requestId, out removed);
            if (removed is not null)
            {
                revision++;
            }
        }
        if (removed is null)
        {
            throw new DomeniaOperationException(RequestUnknown, "Cet accès n’est plus en attente" + FrenchText.Colon + "rien n’a été changé.");
        }
        journal.Add(new JournalEntry(clock.GetUtcNow(), "Accès à revoir écarté" + FrenchText.Colon + removed.ScopeLabel + ", compte actuel conservé", Tone.Info));
        return await OverviewAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// accounts.access.forget (CPT-011): forgets one account kept in memory (« temporary:&lt;ressource&gt; » or
    /// « secondary:remote|secrets ») and clears the refusals tied to it: the resource goes back to the configured account. The
    /// key is checked again at the click. An operation already sent keeps its copy and is never interrupted.
    /// </summary>
    public async Task<AccessOverview> ForgetAsync(string key, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(key);
        await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
        var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
        string? label = null;
        lock (gate)
        {
            if (key.StartsWith("temporary:", StringComparison.Ordinal) && temporary.Remove(key["temporary:".Length..], out var gone))
            {
                faults.Remove(Key(session, gone.Login, gone.Target));
                gone.Dispose();
                label = CredentialRules.ScopeLabel(key["temporary:".Length..]);
            }
            else if (key.StartsWith("secondary:", StringComparison.Ordinal) && CredentialRules.TryParseUsage(key["secondary:".Length..], out var usage) && secondary.Remove(usage, out var held))
            {
                faults.Remove(Key(session, held.Login, null));
                held.Dispose();
                label = CredentialRules.UsageLabel(usage);
            }
            if (label is not null)
            {
                AccountChangedLocked();
            }
        }
        if (label is null)
        {
            throw new DomeniaOperationException(KeyUnknown, "Ce compte n’est plus en mémoire" + FrenchText.Colon + "rien n’a été changé.");
        }
        journal.Add(new JournalEntry(clock.GetUtcNow(), "Compte oublié" + FrenchText.Colon + label + " (refus liés effacés, retour au compte configuré)", Tone.Info));
        return await OverviewAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// accounts.access.forgetAll (CPT-005): forgets every temporary account at once, with the refusals tied to them. The page
    /// asks for a confirmation first; refused while a write waits for its re-read.
    /// </summary>
    public async Task<AccessOverview> ForgetAllAsync(CancellationToken cancellationToken)
    {
        await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
        var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
        int count;
        lock (gate)
        {
            count = temporary.Count;
            foreach (var item in temporary.Values)
            {
                faults.Remove(Key(session, item.Login, item.Target));
                item.Dispose();
            }
            temporary.Clear();
            if (count > 0)
            {
                AccountChangedLocked();
            }
        }
        if (count > 0)
        {
            journal.Add(new JournalEntry(clock.GetUtcNow(), "Comptes temporaires oubliés" + FrenchText.Colon + FrenchText.Integer(count), Tone.Info));
        }
        return await OverviewAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>accounts.access.cancel: stops the validation running now (the previous account is kept).</summary>
    public bool CancelValidation()
    {
        lock (gate)
        {
            if (running is not Running r)
            {
                return false;
            }
            r.Cancel.Cancel();
            return true;
        }
    }

    /// <summary>
    /// accounts.connection.correct (CPT-008): the password of the connection account, corrected in place for the SAME identity
    /// only (account key compared). The source replaces the secret of the session and stops the reads started with the former
    /// one; the pause of this account only is lifted, unless another copy of the refused password remains (the pause is then
    /// kept as it is). Refused in simulation (no password in the session), for a Windows session (corrected in Windows) and
    /// without a directory reader (wave 3).
    /// </summary>
    public async Task<AccessValidation> CorrectConnectionAsync(SecureString password, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(password);
        var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
        var correction = Connection(session).Correction;
        if (!correction.Available || reader is null)
        {
            throw new DomeniaOperationException(CorrectionUnavailable, correction.Reason ?? "Correction indisponible.");
        }
        await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
        var startEpoch = Epoch();
        var result = await ValidateAsync("Correction du compte de connexion", "directory", new CredentialRequest(session.Account.Login, CredentialRules.Directory, null), password, cancellationToken).ConfigureAwait(false);
        if (!result.Success)
        {
            return result;
        }
        var sessionKey = Key(session, session.Account.Login, null);
        var same = result.Identity is string identity && string.Equals(Key(session, identity, null), sessionKey, StringComparison.Ordinal);
        if (!same)
        {
            var (message, hint) = ("Identité différente de celle de la session" + FrenchText.Colon + "rien n’est remplacé.", "Pour un autre compte, utilisez « Changer de compte ».");
            return result with { Success = false, Kind = "identityMismatch", Message = message, Hint = hint, Tone = Tone.Alert };
        }
        var swap = await reader.SwapConnectionPasswordAsync(password, cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            if (epoch != startEpoch)
            {
                throw new DomeniaOperationException(EpochChanged, "La session a changé pendant la correction" + FrenchText.Colon + "rien n’est remplacé.");
            }
            if (!swap.OtherRefusedCopy)
            {
                faults.Remove(sessionKey);
            }
            foreach (var key in pending.Where(p => p.Value.Scope == CredentialRules.Directory).Select(p => p.Key).ToList())
            {
                pending.Remove(key);
            }
            AccountChangedLocked();
        }
        var stopped = swap.StoppedReads > 0 ? " " + FrenchText.Count(swap.StoppedReads, "lecture partie avec l’ancien mot de passe arrêtée", "lectures parties avec l’ancien mot de passe arrêtées") + "." : "";
        var kept = swap.OtherRefusedCopy ? " Une autre copie du mot de passe refusé subsiste" + FrenchText.Colon + "la pause est conservée telle quelle." : "";
        journal.Add(new JournalEntry(clock.GetUtcNow(), "Mot de passe du compte de connexion corrigé sans reconnecter Domenia", Tone.Ok));
        return result with
        {
            Message = "Mot de passe corrigé pour " + session.Account.Login + "." + stopped + kept,
            Hint = "Si ce mot de passe est enregistré dans le coffre Windows, ressaisissez-le à la prochaine connexion.",
        };
    }

    /// <summary>
    /// accounts.connection.switch (CPT-007, « Changer de compte » sans fermer Domenia): refused while a write waits for its
    /// re-read; the context is checked, ONE authentication of the proposed account opens the new session (same domain), then a
    /// new session epoch starts: secondary and temporary accounts, accesses to review, pauses, refusals and the last trial of the
    /// former session are forgotten, and any result of the former epoch is dropped. Nothing is written in the settings except
    /// the identifier for this domain (names only). Cancelling the form has no effect.
    /// </summary>
    public async Task<AccessSwitch> SwitchAsync(string login, SecureString password, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(login);
        ArgumentNullException.ThrowIfNull(password);
        var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
        var relogin = Connection(session).Relogin;
        if (!relogin.Available || reader is null)
        {
            throw new DomeniaOperationException(ReloginUnavailable, relogin.Reason ?? "Changement de compte indisponible.");
        }
        await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
        var now = clock.GetUtcNow();
        if (password.Length == 0 || string.IsNullOrWhiteSpace(login))
        {
            var (m, h) = CredentialRules.FailureText("input");
            return new AccessSwitch(new AccessValidation(false, "input", m, h, null, null, Tone.Warn, RightsNote(), reader.Simulated, now), null, Epoch());
        }
        string[] known = [.. new[] { session.Domain?.NetbiosName, session.Domain?.DnsName }.OfType<string>()];
        var context = CredentialRules.CheckContext(CredentialRules.Directory, login, null, known);
        if (!context.Valid)
        {
            throw new DomeniaOperationException(ContextRefused, context.Reason + " Aucun essai n’a été envoyé.");
        }
        if (!await validationGate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        {
            throw new DomeniaOperationException(ValidationBusy, "Une validation est déjà en cours" + FrenchText.Colon + "une seule à la fois. Attendez son résultat ou annulez-la.");
        }
        SessionOpenAnswer opened;
        try
        {
            using var cancel = new CancellationTokenSource();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(ValidationTimeoutSeconds), clock);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, cancel.Token, timeout.Token);
            lock (gate)
            {
                running = new Running("relogin", "Changement de compte", now, cancel);
                revision++;
            }
            try
            {
                opened = await reader.OpenSessionAsync(new CredentialRequest(login, CredentialRules.Directory, null), password, linked.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                opened = new SessionOpenAnswer(new CredentialAnswer(false, timeout.IsCancellationRequested ? "timeout" : "cancelled", null, null, null), null);
            }
            finally
            {
                lock (gate)
                {
                    running = null;
                    revision++;
                }
            }
        }
        finally
        {
            validationGate.Release();
        }
        var at = clock.GetUtcNow();
        var answer = opened.Answer;
        if (!answer.Success || opened.Identity is null)
        {
            var kind = answer.Success ? "identityMismatch" : answer.Kind;
            var (message, hint) = CredentialRules.FailureText(kind);
            RecordRefusal(session, kind, login, null, at);
            log.Info($"Changement de compte refusé ({kind}).");
            return new AccessSwitch(new AccessValidation(false, kind, message, hint + (answer.Detail is null ? "" : " " + answer.Detail), null, answer.Controller,
                kind is "cancelled" or "timeout" ? Tone.Warn : Tone.Alert, RightsNote(), reader.Simulated, at), null, Epoch());
        }
        long next;
        lock (gate)
        {
            next = NewEpochLocked();
        }
        var fresh = await SessionAsync(cancellationToken).ConfigureAwait(false);
        await RememberAsync(RootHash(fresh), "directory", opened.Identity.Login, at, cancellationToken).ConfigureAwait(false);
        journal.Add(new JournalEntry(at, "Changement de compte" + FrenchText.Colon + opened.Identity.Login + " (nouvelle session\u00A0; comptes et refus de la session précédente oubliés)", Tone.Info));
        log.Info("Changement de compte" + FrenchText.Colon + "nouvelle époque de session.");
        var simulatedNote = reader.Simulated ? " Simulation" + FrenchText.Colon + "l’annuaire fictif ne contient aucun mot de passe, seul l’état du compte est vérifié." : "";
        var result = new AccessValidation(true, "ok", "Session ouverte avec " + opened.Identity.Login + (answer.Controller is null ? "." : " (contrôleur " + answer.Controller + ")."),
            "Les vues sont relues pour la nouvelle session\u00A0; rien n’est rejoué." + simulatedNote, opened.Identity.Login, answer.Controller, Tone.Ok, RightsNote(), reader.Simulated, at);
        return new AccessSwitch(result, opened.Identity.Login, next);
    }

    /// <summary>
    /// accounts.access.tryRemote (CPT-015): one light read of one workstation with the account the workstation operations take
    /// (local temporary account of that workstation, temporary account, Postes account, else the session), as a read-only copy
    /// given to the read; the lease of a temporary account counts this use (CPT-004). One trial at a time; no scan, no ping, no
    /// console, no intrusive fallback. Only an explicit success says « OK »; a result of another session is dropped.
    /// </summary>
    public async Task<RemoteTrial> TryRemoteAsync(string computer, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(computer);
        if (reader is null)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        }
        if (Interlocked.CompareExchange(ref trialRunning, 1, 0) != 0)
        {
            throw new DomeniaOperationException(TrialBusy, "Un essai est déjà en cours" + FrenchText.Colon + "attendez son verdict.");
        }
        try
        {
            var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
            var target = computer.Trim();
            RemoteProbeCredential credential;
            string origin;
            long startEpoch;
            lock (gate)
            {
                var now = clock.GetUtcNow();
                Sweep(now);
                startEpoch = epoch;
                (credential, origin) = WorkstationCredentialLocked(session, target, now);
            }
            RemoteProbeAnswer answer;
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(TrialTimeoutSeconds), clock);
                using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeout.Token);
                try
                {
                    answer = await reader.ProbeAsync(target, credential, linked.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (timeout.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
                {
                    answer = new RemoteProbeAnswer("timeout", "timeout", null, null);
                }
            }
            finally
            {
                credential.Password?.Dispose();
            }
            var (verdict, success, text) = CredentialRules.TrialVerdict(answer, target, credential.Account);
            var trial = new RemoteTrial(target, credential.Account, origin, verdict, success, text, answer.Caption, CredentialRules.TrialTone(verdict), clock.GetUtcNow(), reader.Simulated);
            lock (gate)
            {
                if (epoch != startEpoch)
                {
                    throw new DomeniaOperationException(EpochChanged, "La session a changé pendant l’essai" + FrenchText.Colon + "son résultat est ignoré.");
                }
                lastTrial = trial;
                revision++;
            }
            journal.Add(new JournalEntry(trial.At, "Essai du compte poste sur " + trial.Computer + FrenchText.Colon + (success ? "accès administrateur OK" : "non concluant ou refusé"), success ? Tone.Ok : Tone.Warn));
            return trial;
        }
        finally
        {
            Volatile.Write(ref trialRunning, 0);
        }
    }

    /// <summary>accounts.remembered.forget (CPT-016 improvement): forgets the identifier remembered for a usage (name only).</summary>
    public async Task<AccessOverview> ForgetRememberedAsync(AccessUsage usage, CancellationToken cancellationToken)
    {
        var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
        if (RootHash(session) is string root)
        {
            // The Secrets account is remembered for LAPS and BitLocker too (Domenia 1): forgotten for all of them.
            string[] usages = usage == AccessUsage.Remote ? ["remote"] : ["secrets", "laps", "bitlocker"];
            foreach (var key in usages.Select(u => RememberedPrefix + u + "." + root))
            {
                if (!preferences.TryGet(key, out _))
                {
                    continue;
                }
                try
                {
                    await preferences.SetAsync(key, null, cancellationToken).ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    log.Warning($"Préférences non enregistrées (identifiant oublié) : {ex.GetType().Name}.");
                    journal.Add(new JournalEntry(clock.GetUtcNow(), "Préférences non enregistrées" + FrenchText.Colon + "l’identifiant est oublié pour cette session seulement", Tone.Warn));
                }
            }
            lock (gate)
            {
                revision++;
            }
        }
        return await OverviewAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Records a refusal of a resource (for the modules that read with these accounts, wave 3): one waiting access per resource
    /// and target (16 at most, the oldest background notice goes first); a refused AUTHENTICATION pauses the account (its key:
    /// the account the resource used, or the one it uses now), which every resource using that account then shows; a denied
    /// right only opens the access to review. The refusal is kept for the lockout diagnosis. No raw error, payload or credential
    /// is stored.
    /// </summary>
    public void RegisterRefusal(string scope, string operation, string? target, string kind, string? accountKey, bool interactive)
    {
        ArgumentNullException.ThrowIfNull(scope);
        ArgumentNullException.ThrowIfNull(operation);
        ArgumentNullException.ThrowIfNull(kind);
        var now = clock.GetUtcNow();
        lock (gate)
        {
            AddRequestLocked(new AccessRequestSeed(scope, operation, target, kind, now), interactive);
            var key = accountKey ?? (lastSession is SessionSnapshot session ? KeyInUseLocked(session, scope, target) : "?" + scope);
            if (AuthenticationKinds.Contains(kind))
            {
                faults[key] = new Fault(scope, now);
            }
            refusals.Add(new DomeniaRefusal(now, key, kind));
            while (refusals.Count > RefusalCapacity)
            {
                refusals.RemoveAt(0);
            }
            revision++;
        }
    }

    /// <summary>
    /// The credential a read of <paramref name="scope"/> takes now (wave 3 reads): a read-only copy of the temporary or secondary
    /// account (the caller disposes it; the read keeps its copy even if the account is forgotten meanwhile), or null for the
    /// session. Each call counts as one use of the lease of a temporary account (the inactivity delay starts again; a one-shot
    /// account is spent): a passive display never extends a lease (CPT-004).
    /// </summary>
    public RemoteProbeCredential? AcquireForRead(string scope, string? target)
    {
        ArgumentNullException.ThrowIfNull(scope);
        lock (gate)
        {
            var now = clock.GetUtcNow();
            Sweep(now);
            if (lastSession is not SessionSnapshot session)
            {
                return null;
            }
            if (scope == CredentialRules.Remote && target is not null)
            {
                var (credential, _) = WorkstationCredentialLocked(session, target, now);
                return credential.Session ? null : credential;
            }
            if (temporary.TryGetValue(scope, out var temp))
            {
                return UseLocked(scope, temp, now);
            }
            var usage = scope is CredentialRules.Laps or CredentialRules.BitLocker ? AccessUsage.Secrets : scope == CredentialRules.Remote ? AccessUsage.Remote : (AccessUsage?)null;
            if (usage is AccessUsage u && secondary.TryGetValue(u, out var held))
            {
                var copy = held.Secret.Copy();
                copy.MakeReadOnly();
                return new RemoteProbeCredential(held.Login, copy, false);
            }
            return null;
        }
    }

    /// <summary>Refusals recorded during this session (for the lockout diagnosis).</summary>
    public ImmutableArray<DomeniaRefusal> Refusals()
    {
        lock (gate)
        {
            return [.. refusals];
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            foreach (var held in secondary.Values)
            {
                held.Dispose();
            }
            secondary.Clear();
            foreach (var item in temporary.Values)
            {
                item.Dispose();
            }
            temporary.Clear();
            running?.Cancel.Dispose();
            running = null;
        }
        validationGate.Dispose();
    }

    private long Epoch()
    {
        lock (gate)
        {
            return epoch;
        }
    }

    /// <summary>A result of a former epoch is dropped (its copy of the secret disposed): « Changer de compte » came in between.</summary>
    private void EnsureEpochLocked(long startEpoch, SecureString copy)
    {
        if (epoch == startEpoch)
        {
            return;
        }
        copy.Dispose();
        throw new DomeniaOperationException(EpochChanged, "La session a changé pendant la validation" + FrenchText.Colon + "son résultat est ignoré.");
    }

    /// <summary>A new session epoch: every account, access, pause, refusal and result of the former session is forgotten.</summary>
    private long NewEpochLocked()
    {
        foreach (var held in secondary.Values)
        {
            held.Dispose();
        }
        secondary.Clear();
        foreach (var item in temporary.Values)
        {
            item.Dispose();
        }
        temporary.Clear();
        pending.Clear();
        faults.Clear();
        refusals.Clear();
        sids.Clear();
        lastTrial = null;
        lastSession = null;
        sessionSidRead = false;
        // The fictitious refusal of the start belongs to the former session: it is not seeded again.
        seeded = true;
        epoch++;
        AccountChangedLocked();
        return epoch;
    }

    private void AccountChangedLocked()
    {
        generation++;
        revision++;
    }

    private async Task<SessionSnapshot> SessionAsync(CancellationToken cancellationToken)
    {
        var session = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            lastSession = session;
        }
        return session;
    }

    private async Task LearnSessionSidAsync(SessionSnapshot session, CancellationToken cancellationToken)
    {
        if (reader is null)
        {
            return;
        }
        lock (gate)
        {
            if (sessionSidRead)
            {
                return;
            }
        }
        var sid = await reader.SessionSidAsync(cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            sessionSidRead = true;
            if (sid is not null)
            {
                sids[Key(session, session.Account.Login, null)] = sid;
            }
        }
    }

    private async Task<AccessValidation> ValidateAsync(string label, string usage, CredentialRequest request, SecureString password, CancellationToken cancellationToken)
    {
        var now = clock.GetUtcNow();
        if (reader is null)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        }
        if (password.Length == 0 || string.IsNullOrWhiteSpace(request.Login))
        {
            var (m, h) = CredentialRules.FailureText("input");
            return new AccessValidation(false, "input", m, h, null, null, Tone.Warn, RightsNote(), reader.Simulated, now);
        }
        var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
        string[] known = [.. new[] { session.Domain?.NetbiosName, session.Domain?.DnsName }.OfType<string>()];
        var context = CredentialRules.CheckContext(request.Scope, request.Login, request.Target, known);
        if (!context.Valid)
        {
            throw new DomeniaOperationException(ContextRefused, context.Reason + " Aucun essai n’a été envoyé.");
        }
        if (!await validationGate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        {
            throw new DomeniaOperationException(ValidationBusy, "Une validation est déjà en cours" + FrenchText.Colon + "une seule à la fois. Attendez son résultat ou annulez-la.");
        }
        try
        {
            await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
            using var cancel = new CancellationTokenSource();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(ValidationTimeoutSeconds), clock);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, cancel.Token, timeout.Token);
            lock (gate)
            {
                running = new Running(usage, label, now, cancel);
                revision++;
            }
            CredentialAnswer answer;
            try
            {
                answer = await reader.ValidateAsync(request, password, linked.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                answer = new CredentialAnswer(false, timeout.IsCancellationRequested ? "timeout" : "cancelled", null, null, null);
            }
            finally
            {
                lock (gate)
                {
                    running = null;
                    revision++;
                }
            }
            var at = clock.GetUtcNow();
            if (answer.Success && !string.IsNullOrWhiteSpace(answer.BindUser))
            {
                if (answer.Sid is string sid)
                {
                    lock (gate)
                    {
                        sids[Key(session, answer.BindUser, request.Target)] = sid;
                    }
                }
                var simulatedNote = reader.Simulated ? " Simulation" + FrenchText.Colon + "l’annuaire fictif ne contient aucun mot de passe, seul l’état du compte est vérifié." : "";
                return new AccessValidation(true, "ok", "Identité validée" + FrenchText.Colon + answer.BindUser + (answer.Controller is null ? "." : " (contrôleur " + answer.Controller + ")."),
                    (answer.Detail ?? "") + simulatedNote, answer.BindUser, answer.Controller, Tone.Ok, RightsNote(), reader.Simulated, at);
            }
            var kind = answer.Success ? "identityMismatch" : answer.Kind;
            var (message, hint) = CredentialRules.FailureText(kind);
            RecordRefusal(session, kind, request.Login, request.Target, at);
            log.Info($"Validation de compte refusée ({kind}).");
            return new AccessValidation(false, kind, message, hint + (answer.Detail is null ? "" : " " + answer.Detail), null, answer.Controller,
                kind is "cancelled" or "timeout" ? Tone.Warn : Tone.Alert, RightsNote(), reader.Simulated, at);
        }
        finally
        {
            validationGate.Release();
        }
    }

    /// <summary>A refused authentication is kept for the lockout diagnosis (64 at most); it never pauses the account by itself.</summary>
    private void RecordRefusal(SessionSnapshot session, string kind, string login, string? target, DateTimeOffset at)
    {
        if (!AuthenticationKinds.Contains(kind))
        {
            return;
        }
        var key = Key(session, login, target);
        lock (gate)
        {
            refusals.Add(new DomeniaRefusal(at, key, kind));
            while (refusals.Count > RefusalCapacity)
            {
                refusals.RemoveAt(0);
            }
            revision++;
        }
    }

    private static string RightsNote() => "Droits sur la ressource non certifiés par ce test" + FrenchText.Colon + "seule l’identité est vérifiée (droits poste et secrets non testés).";

    private async Task EnsureNoWriteAsync(CancellationToken cancellationToken)
    {
        if (await pendingWrites(cancellationToken).ConfigureAwait(false) > 0)
        {
            throw new DomeniaOperationException(WritePending, "Une écriture reste à vérifier" + FrenchText.Colon + "aucun compte ne peut être changé avant sa relecture dans Opérations.");
        }
    }

    private async Task SeedAsync(CancellationToken cancellationToken)
    {
        lock (gate)
        {
            if (seeded || reader is null)
            {
                return;
            }
        }
        var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
        var seeds = await reader!.InitialRequestsAsync(cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            if (seeded)
            {
                return;
            }
            seeded = true;
            foreach (var seed in seeds)
            {
                AddRequestLocked(seed, false);
                var key = KeyInUseLocked(session, seed.Scope, seed.Target);
                if (AuthenticationKinds.Contains(seed.Kind))
                {
                    faults[key] = new Fault(seed.Scope, seed.At);
                }
                refusals.Add(new DomeniaRefusal(seed.At, key, seed.Kind));
            }
            revision++;
        }
    }

    private void AddRequestLocked(AccessRequestSeed seed, bool interactive)
    {
        var existing = pending.Values.FirstOrDefault(p => p.Scope == seed.Scope && string.Equals(p.Target, seed.Target, StringComparison.OrdinalIgnoreCase));
        if (existing is not null)
        {
            pending[existing.Id] = existing with { At = seed.At, Interactive = existing.Interactive || interactive };
            return;
        }
        if (pending.Count >= CredentialRules.PendingLimit)
        {
            // Bounded list: the oldest background notice goes first; the request waiting for the operator stays.
            var victim = pending.Values.OrderBy(p => p.Interactive).ThenBy(p => p.At).First();
            pending.Remove(victim.Id);
        }
        var id = "acc" + (++requestCounter).ToString(System.Globalization.CultureInfo.InvariantCulture);
        pending[id] = new AccessRequest(id, seed.Scope, CredentialRules.ScopeLabel(seed.Scope), seed.Operation, seed.Target, seed.Kind, CredentialRules.KindLabel(seed.Kind), seed.At, interactive);
    }

    /// <summary>Forgets the expired temporary accounts (Invoke-DomeniaAccessLeaseSweep).</summary>
    private void Sweep(DateTimeOffset now)
    {
        foreach (var key in temporary.Where(t => !CredentialRules.CheckLease(t.Value.Lease, epoch, now).Usable).Select(t => t.Key).ToList())
        {
            if (temporary.Remove(key, out var gone))
            {
                gone.Dispose();
                AccountChangedLocked();
                journal.Add(new JournalEntry(now, "Compte temporaire expiré et oublié" + FrenchText.Colon + CredentialRules.ScopeLabel(key), Tone.Info));
            }
        }
    }

    /// <summary>One use of a temporary account by a read leaving now: a read-only copy, the lease counts the use.</summary>
    private RemoteProbeCredential UseLocked(string key, Temporary temp, DateTimeOffset now)
    {
        var copy = temp.Secret.Copy();
        copy.MakeReadOnly();
        temporary[key] = temp with { Lease = CredentialRules.Use(temp.Lease, now) };
        revision++;
        return new RemoteProbeCredential(temp.Login, copy, false);
    }

    /// <summary>
    /// Credential of the workstation operations on <paramref name="computer"/> (Get-DomeniaMachineAccountInUse order): the local
    /// temporary account of that workstation, the temporary account, the Postes account, else the session.
    /// </summary>
    private (RemoteProbeCredential Credential, string Origin) WorkstationCredentialLocked(SessionSnapshot session, string computer, DateTimeOffset now)
    {
        var localKey = CredentialRules.RemoteLocalPrefix + CredentialRules.MachineKey(computer).ToUpperInvariant();
        if (temporary.TryGetValue(localKey, out var local))
        {
            return (UseLocked(localKey, local, now), "compte local temporaire de ce poste");
        }
        if (temporary.TryGetValue(CredentialRules.Remote, out var temp))
        {
            return (UseLocked(CredentialRules.Remote, temp, now), "compte temporaire accepté après un refus");
        }
        if (secondary.TryGetValue(AccessUsage.Remote, out var held))
        {
            var copy = held.Secret.Copy();
            copy.MakeReadOnly();
            return (new RemoteProbeCredential(held.Login, copy, false), "compte Postes de la page Comptes");
        }
        return (new RemoteProbeCredential(session.Account.Login, null, true),
            session.Authentication.Method == AuthenticationMethod.WindowsSession ? "session Windows" : "compte de connexion");
    }

    private ConnectionCard Connection(SessionSnapshot session)
    {
        var c = FrenchText.Colon;
        var connected = session.Connection != ConnectionState.Disconnected;
        var (modeId, modeLabel) = session.Authentication.Method switch
        {
            AuthenticationMethod.None => ("demo", "Simulation, annuaire fictif"),
            AuthenticationMethod.WindowsSession => ("windows", "Session Windows"),
            _ => ("explicit", "Compte saisi à la connexion"),
        };
        AccountsAction correction = session.Authentication.Method switch
        {
            AuthenticationMethod.None => new AccountsAction(false, "Simulation" + c + "la session n’utilise aucun mot de passe, il n’y a rien à corriger."),
            AuthenticationMethod.WindowsSession => new AccountsAction(false, "Session Windows" + c + "son mot de passe se corrige dans Windows. Pour un autre compte, utilisez « Changer de compte »."),
            _ when reader is null => new AccountsAction(false, DomeniaErrors.SourceUnavailableMessage),
            _ => new AccountsAction(true, null),
        };
        var relogin = reader is { SessionSwitchAvailable: true }
            ? new AccountsAction(true, null)
            : new AccountsAction(false, "Changer de compte sans fermer Domenia arrive avec la connexion à l’annuaire (Domenia.Ad, vague 3)" + c + "relancez Domenia pour l’instant.");
        var parts = new List<string> { modeLabel };
        if (session.Controller?.DnsName is string dc)
        {
            parts.Add("contrôleur " + dc);
        }
        if (session.Domain?.DnsName is string dns)
        {
            parts.Add("domaine " + dns);
        }
        return new ConnectionCard(
            connected,
            connected ? session.Account.Login : "Aucune identité active",
            session.Account.DisplayName,
            modeId,
            modeLabel,
            session.Controller?.DnsName,
            session.Controller?.Site,
            session.Domain?.DnsName,
            session.Domain?.NetbiosName,
            reader?.SessionStartedAt,
            session.Authentication.Label,
            connected ? string.Join(" · ", parts) : "Aucune connexion à l’annuaire" + c + "utilisez « Changer de compte ».",
            correction,
            relogin);
    }

    /// <summary>Account the next workstation operation takes (Get-DomeniaMachineAccountInUse order: temporary, Postes, connection).</summary>
    private (string Account, string Origin) MachineAccount(SessionSnapshot session)
    {
        if (temporary.TryGetValue(CredentialRules.Remote, out var temp))
        {
            return (temp.Login, "compte temporaire accepté après un refus");
        }
        if (secondary.TryGetValue(AccessUsage.Remote, out var held))
        {
            return (held.Login, "compte Postes de la page Comptes");
        }
        return session.Authentication.Method == AuthenticationMethod.WindowsSession
            ? (session.Account.Login, "session Windows")
            : (session.Account.Login, "compte de connexion");
    }

    /// <summary>Key of the account a resource uses now (for a refusal that did not name its account).</summary>
    private string KeyInUseLocked(SessionSnapshot session, string scope, string? target)
    {
        if (scope == CredentialRules.Remote || scope.StartsWith(CredentialRules.RemoteLocalPrefix, StringComparison.Ordinal))
        {
            var localKey = target is null ? null : CredentialRules.RemoteLocalPrefix + CredentialRules.MachineKey(target).ToUpperInvariant();
            if (localKey is not null && temporary.TryGetValue(localKey, out var local))
            {
                return Key(session, local.Login, target);
            }
            return Key(session, MachineAccount(session).Account, null);
        }
        if (temporary.TryGetValue(scope, out var temp))
        {
            return Key(session, temp.Login, temp.Target);
        }
        if (scope is CredentialRules.Laps or CredentialRules.BitLocker && secondary.TryGetValue(AccessUsage.Secrets, out var held))
        {
            return Key(session, held.Login, null);
        }
        return Key(session, session.Account.Login, null);
    }

    private static string Key(SessionSnapshot session, string login, string? target) =>
        CredentialRules.AccountKey(login, session.Domain?.DnsName, session.Domain?.NetbiosName, target);

    /// <summary>The pause of an account: its own, or the one of an account with the same SID (confirmed by the directory).</summary>
    private Fault? PausedLocked(string key)
    {
        if (faults.TryGetValue(key, out var own))
        {
            return own;
        }
        if (sids.TryGetValue(key, out var sid))
        {
            foreach (var (other, fault) in faults)
            {
                if (sids.TryGetValue(other, out var otherSid) && string.Equals(sid, otherSid, StringComparison.OrdinalIgnoreCase))
                {
                    return fault;
                }
            }
        }
        return null;
    }

    private ImmutableArray<AccessInUseRow> InUseRows(SessionSnapshot session, ConnectionCard connection, (string Account, string Origin) machine)
    {
        var rows = ImmutableArray.CreateBuilder<AccessInUseRow>();
        var seen = new List<(string Resource, string Key)>();
        var directoryOrigin = session.Authentication.Method switch
        {
            AuthenticationMethod.None => "simulation, annuaire fictif",
            AuthenticationMethod.WindowsSession => "session Windows",
            _ => "compte de connexion",
        };
        rows.Add(Row("Annuaire", CredentialRules.Directory, connection.Identity, Key(session, session.Account.Login, null), directoryOrigin,
            connection.Correction.Available ? new AccessRowAction("correct", "Corriger", null) : null));
        foreach (var key in temporary.Keys.Where(k => k.StartsWith(CredentialRules.DirectoryOperationPrefix, StringComparison.Ordinal)).Order(StringComparer.Ordinal))
        {
            var temp = temporary[key];
            rows.Add(Row(CredentialRules.ScopeLabel(key), key, temp.Login, Key(session, temp.Login, temp.Target), "compte temporaire accepté après un refus", new AccessRowAction("forget", "Oublier", "temporary:" + key)));
        }
        rows.Add(Row("Postes (WMI, C$, consoles)", CredentialRules.Remote, machine.Account, Key(session, machine.Account, null), machine.Origin, new AccessRowAction("try", "Essayer sur un poste", null)));
        foreach (var key in temporary.Keys.Where(k => k.StartsWith(CredentialRules.RemoteLocalPrefix, StringComparison.Ordinal)).Order(StringComparer.Ordinal))
        {
            var temp = temporary[key];
            rows.Add(Row(CredentialRules.ScopeLabel(key), key, temp.Login, Key(session, temp.Login, temp.Target), "compte local temporaire de ce poste", new AccessRowAction("forget", "Oublier", "temporary:" + key)));
        }
        var secrets = secondary.GetValueOrDefault(AccessUsage.Secrets);
        foreach (var (label, key) in new[] { ("Secrets" + FrenchText.Colon + "LAPS", CredentialRules.Laps), ("Secrets" + FrenchText.Colon + "BitLocker", CredentialRules.BitLocker) })
        {
            string account;
            string origin;
            string accountKey;
            if (temporary.TryGetValue(key, out var temp))
            {
                account = temp.Login;
                origin = "compte temporaire accepté après un refus";
                accountKey = Key(session, temp.Login, temp.Target);
            }
            else if (secrets is not null)
            {
                account = secrets.Login;
                origin = "compte Secrets de la page Comptes";
                accountKey = Key(session, secrets.Login, null);
            }
            else
            {
                account = connection.Identity;
                origin = "même compte que l’annuaire";
                accountKey = Key(session, session.Account.Login, null);
            }
            rows.Add(Row(label, key, account, accountKey, origin, new AccessRowAction("activate", "Compte Secrets", "secrets")));
        }
        return rows.ToImmutable();

        AccessInUseRow Row(string resource, string scope, string account, string accountKey, string origin, AccessRowAction? action)
        {
            var request = pending.Values.Where(p => p.Scope == scope).OrderBy(p => p.At).FirstOrDefault();
            var recover = request is not null ? new AccessRowAction("recover", "Utiliser un autre compte", request.Id) : null;
            AccessInUseRow row;
            if (PausedLocked(accountKey) is not null)
            {
                var where = origin == "même compte que l’annuaire" ? directoryOrigin : origin;
                row = new AccessInUseRow(resource, scope, account, origin, "En pause après un refus" + FrenchText.Colon + CredentialRules.FixFor(where) + ".", Tone.Warn, recover ?? action);
            }
            else if (request is not null)
            {
                row = new AccessInUseRow(resource, scope, account, origin, request.KindLabel + " à revoir" + FrenchText.Colon + "utilisez un autre compte pour cette ressource, ou gardez le compte actuel.", Tone.Warn, recover);
            }
            else
            {
                var alias = seen.FindIndex(s => !string.Equals(s.Key, accountKey, StringComparison.Ordinal) && SameSid(s.Key, accountKey));
                row = alias >= 0
                    ? new AccessInUseRow(resource, scope, account, origin, "Même compte que " + seen[alias].Resource + " (SID confirmé par l’annuaire).", Tone.Ok, action)
                    : new AccessInUseRow(resource, scope, account, origin, "Aucun refus enregistré.", Tone.Ok, action);
            }
            seen.Add((resource, accountKey));
            return row;
        }
    }

    private bool SameSid(string a, string b) =>
        sids.TryGetValue(a, out var first) && sids.TryGetValue(b, out var second) && string.Equals(first, second, StringComparison.OrdinalIgnoreCase);

    private ImmutableArray<AccessMemoryRow> MemoryRows(SessionSnapshot session, DateTimeOffset now)
    {
        var rows = ImmutableArray.CreateBuilder<AccessMemoryRow>();
        foreach (var usage in new[] { AccessUsage.Remote, AccessUsage.Secrets })
        {
            if (secondary.TryGetValue(usage, out var held))
            {
                var paused = PausedLocked(Key(session, held.Login, null)) is not null;
                rows.Add(new AccessMemoryRow("secondary:" + CredentialRules.UsageId(usage), CredentialRules.UsageLabel(usage), held.Login,
                    usage == AccessUsage.Remote ? "compte Postes de la page Comptes" : "compte Secrets de la page Comptes",
                    "jusqu’à « Effacer » ou la fin de la session", -1, true, paused ? "En pause après un refus." : "Aucun refus enregistré.",
                    paused ? Tone.Warn : Tone.Ok));
            }
        }
        foreach (var (key, item) in temporary.OrderBy(t => t.Key, StringComparer.Ordinal))
        {
            var remaining = CredentialRules.Remaining(item.Lease, epoch, now);
            var origin = key.StartsWith(CredentialRules.RemoteLocalPrefix, StringComparison.Ordinal) ? "compte local temporaire de ce poste" : "compte temporaire accepté après un refus";
            var paused = PausedLocked(Key(session, item.Login, item.Target)) is not null;
            rows.Add(new AccessMemoryRow("temporary:" + key, CredentialRules.ScopeLabel(key), item.Login, origin, remaining.Text, remaining.Minutes, remaining.Usable,
                paused ? "En pause après un refus." : "Aucun refus enregistré.", paused ? Tone.Warn : Tone.Ok));
        }
        return rows.ToImmutable();
    }

    private SecondaryAccount Secondary(SessionSnapshot session, AccessUsage usage, RememberedAccount? remembered)
    {
        var resources = CredentialRules.ResourcesOf(usage);
        if (secondary.TryGetValue(usage, out var held))
        {
            var paused = PausedLocked(Key(session, held.Login, null)) is not null;
            return new SecondaryAccount(usage, CredentialRules.UsageLabel(usage), held.Login, true, held.ActivatedAt, held.Controller,
                paused ? "En pause après un refus" + FrenchText.Colon + "ressaisissez son mot de passe puis « Activer »." : "Actif, validé par l’annuaire" + FrenchText.Colon + "droits sur la ressource non certifiés par ce test.",
                paused ? Tone.Warn : Tone.Ok, remembered, resources);
        }
        return new SecondaryAccount(usage, CredentialRules.UsageLabel(usage), null, false, null, null,
            usage == AccessUsage.Remote ? "Aucun compte Postes" + FrenchText.Colon + "les opérations sur les postes utilisent le compte de connexion." : "Aucun compte Secrets" + FrenchText.Colon + "LAPS et BitLocker utilisent le compte de connexion.",
            Tone.Off, remembered, resources);
    }

    private VaultState Vault() => mode == AppMode.Simulation
        ? new VaultState(false, "Indisponible en simulation, comme dans Domenia 1" + FrenchText.Colon + "aucun mot de passe n’est enregistré sur ce PC.")
        : new VaultState(false, "Coffre Windows (Gestionnaire d’identification) en attente de décision de David et du branchement natif" + FrenchText.Colon + "aucun mot de passe n’est enregistré.");

    private static string? RootHash(SessionSnapshot session)
    {
        if (session.Domain?.RootDn is not string root)
        {
            return null;
        }
        try
        {
            var canonical = DistinguishedName.Format(DistinguishedName.Parse(root)).ToUpperInvariant();
            return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)))[..16];
        }
        catch (FormatException)
        {
            return null;
        }
    }

    /// <summary>
    /// Usage under which an identifier is remembered (Domenia 1: Directory, Remote, Laps, BitLocker, AD:&lt;opération&gt;,
    /// RemoteLocal:&lt;poste&gt;): a local account of a workstation never prefills the Postes account.
    /// </summary>
    private static string RememberUsageFor(string scope, string? target, string? localLogin)
    {
        if (scope.StartsWith(CredentialRules.RemoteLocalPrefix, StringComparison.Ordinal)
            || (scope == CredentialRules.Remote && localLogin is not null && target is not null))
        {
            var machine = scope.StartsWith(CredentialRules.RemoteLocalPrefix, StringComparison.Ordinal) ? scope[CredentialRules.RemoteLocalPrefix.Length..] : target!;
            return "remoteLocal." + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(CredentialRules.MachineKey(machine))))[..12];
        }
        return scope switch
        {
            CredentialRules.Laps => "laps",
            CredentialRules.BitLocker => "bitlocker",
            CredentialRules.Remote => "remote",
            CredentialRules.Directory => "directory",
            _ when scope.StartsWith(CredentialRules.DirectoryOperationPrefix, StringComparison.Ordinal)
                => "operation." + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(scope)))[..12],
            _ => "other",
        };
    }

    /// <summary>Identifier to prefill « Utiliser un autre compte » for a waiting access: its resource (and workstation) first.</summary>
    private RememberedAccount? RequestRemembered(string? root, AccessRequest request)
    {
        if (request.Scope == CredentialRules.Remote && request.Target is not null)
        {
            return Latest(Remembered(root, RememberUsageFor(CredentialRules.RemoteLocalPrefix + request.Target, request.Target, null)), Remembered(root, "remote"));
        }
        return Remembered(root, RememberUsageFor(request.Scope, request.Target, null));
    }

    private static RememberedAccount? Latest(RememberedAccount? a, RememberedAccount? b) =>
        a is null ? b : b is null ? a : a.LastUsedAt >= b.LastUsedAt ? a : b;

    private RememberedAccount? Remembered(string? root, string usage)
    {
        if (root is null || !preferences.TryGet(RememberedPrefix + usage + "." + root, out var value) || value.ValueKind != JsonValueKind.Object)
        {
            return null;
        }
        if (!value.TryGetProperty("account", out var account) || account.ValueKind != JsonValueKind.String
            || !value.TryGetProperty("lastUsedAt", out var at) || at.ValueKind != JsonValueKind.String
            || !DateTimeOffset.TryParse(at.GetString(), System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out var when))
        {
            return null;
        }
        var name = account.GetString()!;
        return CredentialRules.IsWellFormed(name) ? new RememberedAccount(name, when.ToUniversalTime()) : null;
    }

    private async Task RememberAsync(string? root, string usage, string account, DateTimeOffset at, CancellationToken cancellationToken)
    {
        if (root is null)
        {
            return;
        }
        var element = JsonSerializer.SerializeToElement(new StoredAccount(account, at.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", System.Globalization.CultureInfo.InvariantCulture)), ValueJson);
        try
        {
            await preferences.SetAsync(RememberedPrefix + usage + "." + root, element, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Préférences non enregistrées (identifiant mémorisé) : {ex.GetType().Name}.");
            journal.Add(new JournalEntry(clock.GetUtcNow(), "Identifiant non mémorisé" + FrenchText.Colon + "il vaut pour cette session seulement", Tone.Warn));
        }
        lock (gate)
        {
            revision++;
        }
    }

    private sealed record Held(string Login, SecureString Secret, DateTimeOffset ActivatedAt, string? Controller) : IDisposable
    {
        private readonly IDisposable tracked = SecureCredentialCopies.Track(Secret);
        public void Dispose() { tracked.Dispose(); Secret.Dispose(); }
    }

    private sealed record Temporary(string Login, string? Target, SecureString Secret, CredentialLease Lease) : IDisposable
    {
        private readonly IDisposable tracked = SecureCredentialCopies.Track(Secret);
        public void Dispose() { tracked.Dispose(); Secret.Dispose(); }
    }

    private sealed record Fault(string Scope, DateTimeOffset At);

    private sealed record Running(string Usage, string Label, DateTimeOffset StartedAt, CancellationTokenSource Cancel);

    private sealed record StoredAccount(string Account, string LastUsedAt);
}
