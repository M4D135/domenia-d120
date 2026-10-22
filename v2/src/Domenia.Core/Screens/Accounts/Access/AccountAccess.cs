using System.Collections.Immutable;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Accounts Domenia works with (Domenia 1 CPT-001 to CPT-021, Domenia-Access.UI.ps1, Domenia-Accounts.*.ps1): the connection
/// account (read only), the secondary accounts for the workstations and for the secrets, the temporary accounts accepted after
/// a refusal with their lease, the accesses waiting for the operator, the refusals recorded for the lockout diagnosis, and the
/// single validation running at a time. Passwords are kept as read-only <see cref="SecureString"/> copies, disposed when they
/// are replaced, forgotten or expire; names only reach the page, never a secret. Nothing here is tested by itself: an account
/// without a recorded refusal is « Aucun refus enregistré », never « valide ». No change while a write is running or waiting
/// for its re-read (an account is never changed under a write). Thread safe.
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
    public const string TrialBusy = "accounts.trialBusy";
    public const string ComputerUnknown = "accounts.computerUnknown";

    public const string RememberedPrefix = "accounts.remembered.";

    private static readonly JsonSerializerOptions ValueJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private readonly IDirectorySource directory;
    private readonly IAccountsAccessReader? reader;
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
    private readonly HashSet<string> faults = new(StringComparer.Ordinal);
    private readonly List<DomeniaRefusal> refusals = [];
    private readonly long epoch = 1;
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
        Func<CancellationToken, Task<int>> pendingWrites)
    {
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(preferences);
        ArgumentNullException.ThrowIfNull(journal);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        ArgumentNullException.ThrowIfNull(pendingWrites);
        this.directory = directory;
        this.reader = reader;
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
            }));
    }

    /// <summary>accounts.access.state: everything the Accès tab shows. Never reads the network.</summary>
    public async Task<AccessOverview> OverviewAsync(CancellationToken cancellationToken)
    {
        var session = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        await SeedAsync(cancellationToken).ConfigureAwait(false);
        var now = clock.GetUtcNow();
        var rootKey = RootHash(session);
        var remembered = new Dictionary<AccessUsage, RememberedAccount?>
        {
            [AccessUsage.Remote] = Remembered(rootKey, "remote"),
            [AccessUsage.Secrets] = Remembered(rootKey, "secrets"),
        };
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
            var memory = MemoryRows(now);
            var pendingRows = pending.Values.OrderBy(p => p.At).ToImmutableArray();
            var validation = running is Running r
                ? new AccessValidationState(true, r.Usage, r.Label, r.StartedAt, ValidationTimeoutSeconds)
                : new AccessValidationState(false, null, null, null, ValidationTimeoutSeconds);
            var summaryParts = new List<string>();
            summaryParts.Add(memory.Length == 0 ? "Aucun compte temporaire en mémoire" : FrenchText.Count(memory.Length, "compte en mémoire", "comptes en mémoire"));
            summaryParts.Add(pendingRows.Length == 0 ? "aucun accès à revoir" : FrenchText.Count(pendingRows.Length, "accès à revoir", "accès à revoir"));
            return new AccessOverview(
                connection,
                identities,
                pendingRows,
                CredentialRules.PendingLimit,
                inUse,
                memory,
                Secondary(AccessUsage.Remote, remembered[AccessUsage.Remote]),
                Secondary(AccessUsage.Secrets, remembered[AccessUsage.Secrets]),
                validation,
                lastTrial,
                new LeasePolicy(CredentialRules.DefaultLeaseMinutes, CredentialRules.MinLeaseMinutes, CredentialRules.MaxLeaseMinutes),
                Vault(),
                refusals.Count,
                generation,
                string.Join(" · ", summaryParts) + ".",
                mode == AppMode.Simulation);
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
    /// resources (D051) and their refusals; the identifier (never the password) is remembered for this domain (CPT-016).
    /// </summary>
    public async Task<AccessChange> ActivateAsync(AccessUsage usage, string login, SecureString password, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(login);
        ArgumentNullException.ThrowIfNull(password);
        await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
        var scope = usage == AccessUsage.Remote ? CredentialRules.Remote : CredentialRules.Laps;
        var result = await ValidateAsync(CredentialRules.UsageLabel(usage), CredentialRules.UsageId(usage), new CredentialRequest(login, scope, null), password, cancellationToken).ConfigureAwait(false);
        if (result.Success)
        {
            var identity = result.Identity ?? login.Trim();
            var copy = password.Copy();
            copy.MakeReadOnly();
            var now = clock.GetUtcNow();
            lock (gate)
            {
                if (secondary.Remove(usage, out var previous))
                {
                    previous.Secret.Dispose();
                }
                secondary[usage] = new Held(identity, copy, now, result.Controller);
                foreach (var resource in CredentialRules.ResourcesOf(usage))
                {
                    if (temporary.Remove(resource, out var replaced))
                    {
                        replaced.Secret.Dispose();
                    }
                    faults.Remove(resource);
                    foreach (var key in pending.Where(p => p.Value.Scope == resource).Select(p => p.Key).ToList())
                    {
                        pending.Remove(key);
                    }
                }
                generation++;
            }
            var session = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
            await RememberAsync(RootHash(session), CredentialRules.UsageId(usage), identity, now, cancellationToken).ConfigureAwait(false);
            journal.Add(new JournalEntry(now, CredentialRules.UsageLabel(usage) + " activé" + FrenchText.Colon + identity + " (droits sur la ressource non certifiés par ce test)", Tone.Info));
            log.Info($"Compte secondaire {CredentialRules.UsageId(usage)} activé après validation.");
        }
        return new AccessChange(result, await OverviewAsync(cancellationToken).ConfigureAwait(false));
    }

    /// <summary>accounts.access.clear: back to the connection account for this usage (« Effacer »).</summary>
    public async Task<AccessOverview> ClearAsync(AccessUsage usage, CancellationToken cancellationToken)
    {
        await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
        bool removed;
        lock (gate)
        {
            removed = secondary.Remove(usage, out var previous);
            if (removed)
            {
                previous!.Secret.Dispose();
                generation++;
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
        var scopeTarget = request.Scope == CredentialRules.Remote ? target ?? request.Target : null;
        var result = await ValidateAsync("Autre compte pour " + request.ScopeLabel, "recover", new CredentialRequest(login, request.Scope, scopeTarget), password, cancellationToken).ConfigureAwait(false);
        if (result.Success)
        {
            var identity = result.Identity ?? login.Trim();
            var now = clock.GetUtcNow();
            var key = request.Scope == CredentialRules.Remote && scopeTarget is not null && CredentialRules.IsLocalAccount(login, scopeTarget)
                ? CredentialRules.RemoteLocalPrefix + CredentialRules.MachineKey(scopeTarget).ToUpperInvariant()
                : request.Scope;
            var copy = password.Copy();
            copy.MakeReadOnly();
            lock (gate)
            {
                if (temporary.Remove(key, out var replaced))
                {
                    replaced.Secret.Dispose();
                }
                temporary[key] = new Temporary(identity, copy, CredentialRules.NewLease(key, identity, leaseMode, minutes, epoch, now));
                foreach (var stale in pending.Where(p => p.Value.Scope == request.Scope).Select(p => p.Key).ToList())
                {
                    pending.Remove(stale);
                }
                faults.Remove(request.Scope);
                generation++;
            }
            var session = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
            var usage = request.Scope switch
            {
                CredentialRules.Laps => "laps",
                CredentialRules.BitLocker => "bitlocker",
                CredentialRules.Remote => "remote",
                _ => "directory",
            };
            await RememberAsync(RootHash(session), usage, identity, now, cancellationToken).ConfigureAwait(false);
            journal.Add(new JournalEntry(now, "Autre compte validé pour " + request.ScopeLabel + FrenchText.Colon + identity + " ; relancez l’action vous-même", Tone.Info));
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
    /// « secondary:remote|secrets »). An operation already sent keeps its copy and is never interrupted.
    /// </summary>
    public async Task<AccessOverview> ForgetAsync(string key, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(key);
        await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
        string? label = null;
        lock (gate)
        {
            if (key.StartsWith("temporary:", StringComparison.Ordinal) && temporary.Remove(key["temporary:".Length..], out var gone))
            {
                gone.Secret.Dispose();
                label = CredentialRules.ScopeLabel(key["temporary:".Length..]);
            }
            else if (key.StartsWith("secondary:", StringComparison.Ordinal) && CredentialRules.TryParseUsage(key["secondary:".Length..], out var usage) && secondary.Remove(usage, out var held))
            {
                held.Secret.Dispose();
                label = CredentialRules.UsageLabel(usage);
            }
            if (label is not null)
            {
                generation++;
            }
        }
        if (label is null)
        {
            throw new DomeniaOperationException(KeyUnknown, "Ce compte n’est plus en mémoire" + FrenchText.Colon + "rien n’a été changé.");
        }
        journal.Add(new JournalEntry(clock.GetUtcNow(), "Compte oublié" + FrenchText.Colon + label, Tone.Info));
        return await OverviewAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>accounts.access.forgetAll (CPT-005): forgets every temporary account at once.</summary>
    public async Task<AccessOverview> ForgetAllAsync(CancellationToken cancellationToken)
    {
        await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
        int count;
        lock (gate)
        {
            count = temporary.Count;
            foreach (var item in temporary.Values)
            {
                item.Secret.Dispose();
            }
            temporary.Clear();
            if (count > 0)
            {
                generation++;
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
    /// only. Refused in simulation (no password in the session), for a Windows session (corrected in Windows) and without a
    /// directory reader (wave 3).
    /// </summary>
    public async Task<AccessValidation> CorrectConnectionAsync(SecureString password, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(password);
        var session = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var correction = Connection(session).Correction;
        if (!correction.Available)
        {
            throw new DomeniaOperationException(CorrectionUnavailable, correction.Reason ?? "Correction indisponible.");
        }
        await EnsureNoWriteAsync(cancellationToken).ConfigureAwait(false);
        var result = await ValidateAsync("Correction du compte de connexion", "directory", new CredentialRequest(session.Account.Login, CredentialRules.Directory, null), password, cancellationToken).ConfigureAwait(false);
        if (!result.Success)
        {
            return result;
        }
        var same = result.Identity is string identity && string.Equals(
            CredentialRules.AccountKey(identity, session.Domain?.DnsName, session.Domain?.NetbiosName, null),
            CredentialRules.AccountKey(session.Account.Login, session.Domain?.DnsName, session.Domain?.NetbiosName, null), StringComparison.Ordinal);
        if (!same)
        {
            var (message, hint) = ("Identité différente de celle de la session" + FrenchText.Colon + "rien n’est remplacé.", "Pour un autre compte, utilisez «\u00A0Changer de compte\u00A0».");
            return result with { Success = false, Kind = "identityMismatch", Message = message, Hint = hint, Tone = Tone.Alert };
        }
        lock (gate)
        {
            faults.Remove(CredentialRules.Directory);
            foreach (var key in pending.Where(p => p.Value.Scope == CredentialRules.Directory).Select(p => p.Key).ToList())
            {
                pending.Remove(key);
            }
            generation++;
        }
        journal.Add(new JournalEntry(clock.GetUtcNow(), "Mot de passe du compte de connexion corrigé sans reconnecter Domenia", Tone.Ok));
        return result;
    }

    /// <summary>
    /// accounts.access.tryRemote (CPT-015): one light read of one workstation with the account the workstation operations take.
    /// One trial at a time; no scan, no ping, no console, no intrusive fallback. Only an explicit success says « OK ».
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
            var session = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
            (string Account, string Origin) machine;
            lock (gate)
            {
                Sweep(clock.GetUtcNow());
                var local = temporary.GetValueOrDefault(CredentialRules.RemoteLocalPrefix + CredentialRules.MachineKey(computer).ToUpperInvariant());
                machine = local is not null ? (local.Login, "compte local temporaire de ce poste") : MachineAccount(session);
            }
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(TrialTimeoutSeconds), clock);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeout.Token);
            RemoteProbeAnswer answer;
            try
            {
                answer = await reader.ProbeAsync(computer.Trim(), machine.Account, linked.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (timeout.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                answer = new RemoteProbeAnswer("timeout", "timeout", null, null);
            }
            var (verdict, success, text) = CredentialRules.TrialVerdict(answer, computer.Trim(), machine.Account);
            var trial = new RemoteTrial(computer.Trim(), machine.Account, machine.Origin, verdict, success, text, answer.Caption, CredentialRules.TrialTone(verdict), clock.GetUtcNow(), reader.Simulated);
            lock (gate)
            {
                lastTrial = trial;
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
        var session = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        if (RootHash(session) is string root)
        {
            var key = RememberedPrefix + CredentialRules.UsageId(usage) + "." + root;
            if (preferences.TryGet(key, out _))
            {
                try
                {
                    await preferences.SetAsync(key, null, cancellationToken).ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    log.Warning($"Préférences non enregistrées (identifiant oublié)\u00A0: {ex.GetType().Name}.");
                    journal.Add(new JournalEntry(clock.GetUtcNow(), "Préférences non enregistrées" + FrenchText.Colon + "l’identifiant est oublié pour cette session seulement", Tone.Warn));
                }
            }
        }
        return await OverviewAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Records a refusal of a resource (for the modules that will read with these accounts, wave 3): one waiting access per
    /// resource and target (16 at most, the oldest background notice goes first), the resource paused, and the refusal kept
    /// for the lockout diagnosis. No raw error, payload or credential is stored.
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
            faults.Add(scope);
            refusals.Add(new DomeniaRefusal(now, accountKey, kind));
            while (refusals.Count > RefusalCapacity)
            {
                refusals.RemoveAt(0);
            }
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
                held.Secret.Dispose();
            }
            secondary.Clear();
            foreach (var item in temporary.Values)
            {
                item.Secret.Dispose();
            }
            temporary.Clear();
            running?.Cancel.Dispose();
            running = null;
        }
        validationGate.Dispose();
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
        var session = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
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
                }
            }
            var at = clock.GetUtcNow();
            if (answer.Success && !string.IsNullOrWhiteSpace(answer.BindUser))
            {
                var simulatedNote = reader.Simulated ? " Simulation" + FrenchText.Colon + "l’annuaire fictif ne contient aucun mot de passe, seul l’état du compte est vérifié." : "";
                return new AccessValidation(true, "ok", "Identité validée" + FrenchText.Colon + answer.BindUser + (answer.Controller is null ? "." : " (contrôleur " + answer.Controller + ")."),
                    (answer.Detail ?? "") + simulatedNote, answer.BindUser, answer.Controller, Tone.Ok, RightsNote(), reader.Simulated, at);
            }
            var kind = answer.Success ? "identityMismatch" : answer.Kind;
            var (message, hint) = CredentialRules.FailureText(kind);
            if (kind is "badCredentials" or "locked" or "passwordExpired" or "mustChange" or "disabled" or "accountExpired")
            {
                var key = CredentialRules.AccountKey(request.Login, session.Domain?.DnsName, session.Domain?.NetbiosName, request.Target);
                lock (gate)
                {
                    refusals.Add(new DomeniaRefusal(at, key, kind));
                    while (refusals.Count > RefusalCapacity)
                    {
                        refusals.RemoveAt(0);
                    }
                }
            }
            log.Info($"Validation de compte refusée ({kind}).");
            return new AccessValidation(false, kind, message, hint + (answer.Detail is null ? "" : " " + answer.Detail), null, answer.Controller,
                kind is "cancelled" or "timeout" ? Tone.Warn : Tone.Alert, RightsNote(), reader.Simulated, at);
        }
        finally
        {
            validationGate.Release();
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
                faults.Add(seed.Scope);
                refusals.Add(new DomeniaRefusal(seed.At, null, seed.Kind));
            }
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
                gone.Secret.Dispose();
                journal.Add(new JournalEntry(now, "Compte temporaire expiré et oublié" + FrenchText.Colon + CredentialRules.ScopeLabel(key), Tone.Info));
            }
        }
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
            AuthenticationMethod.WindowsSession => new AccountsAction(false, "Session Windows" + c + "son mot de passe se corrige dans Windows. Pour un autre compte, utilisez «\u00A0Changer de compte\u00A0»."),
            _ when reader is null => new AccountsAction(false, DomeniaErrors.SourceUnavailableMessage),
            _ => new AccountsAction(true, null),
        };
        var relogin = new AccountsAction(false, mode == AppMode.Simulation
            ? "Simulation" + c + "la session fictive ne change pas de compte. Le changement de compte sans fermer Domenia arrive avec la connexion à l’annuaire."
            : "Changer de compte sans fermer Domenia arrive avec la connexion à l’annuaire (vague 3)" + c + "relancez Domenia pour l’instant.");
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
            connected ? string.Join(" · ", parts) : "Aucune connexion à l’annuaire" + c + "utilisez «\u00A0Changer de compte\u00A0».",
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

    private ImmutableArray<AccessInUseRow> InUseRows(SessionSnapshot session, ConnectionCard connection, (string Account, string Origin) machine)
    {
        var rows = ImmutableArray.CreateBuilder<AccessInUseRow>();
        var directoryOrigin = session.Authentication.Method switch
        {
            AuthenticationMethod.None => "simulation, annuaire fictif",
            AuthenticationMethod.WindowsSession => "session Windows",
            _ => "compte de connexion",
        };
        rows.Add(Row("Annuaire", CredentialRules.Directory, connection.Identity, directoryOrigin, connection.Correction.Available ? new AccessRowAction("correct", "Corriger", null) : null));
        foreach (var key in temporary.Keys.Where(k => k.StartsWith(CredentialRules.DirectoryOperationPrefix, StringComparison.Ordinal)).Order(StringComparer.Ordinal))
        {
            rows.Add(Row(CredentialRules.ScopeLabel(key), key, temporary[key].Login, "compte temporaire accepté après un refus", new AccessRowAction("forget", "Oublier", "temporary:" + key)));
        }
        rows.Add(Row("Postes (WMI, C$, consoles)", CredentialRules.Remote, machine.Account, machine.Origin, new AccessRowAction("try", "Essayer sur un poste", null)));
        var secrets = secondary.GetValueOrDefault(AccessUsage.Secrets);
        foreach (var (label, key) in new[] { ("Secrets" + FrenchText.Colon + "LAPS", CredentialRules.Laps), ("Secrets" + FrenchText.Colon + "BitLocker", CredentialRules.BitLocker) })
        {
            string account;
            string origin;
            if (temporary.TryGetValue(key, out var temp))
            {
                account = temp.Login;
                origin = "compte temporaire accepté après un refus";
            }
            else if (secrets is not null)
            {
                account = secrets.Login;
                origin = "compte Secrets de la page Comptes";
            }
            else
            {
                account = connection.Identity;
                origin = "même compte que l’annuaire";
            }
            var request = pending.Values.FirstOrDefault(p => p.Scope == key);
            rows.Add(Row(label, key, account, origin, request is not null ? new AccessRowAction("recover", "Utiliser un autre compte", request.Id) : new AccessRowAction("activate", "Compte Secrets", "secrets")));
        }
        return rows.ToImmutable();

        AccessInUseRow Row(string resource, string key, string account, string origin, AccessRowAction? action)
        {
            if (faults.Contains(key))
            {
                var where = origin == "même compte que l’annuaire" ? directoryOrigin : origin;
                var request = pending.Values.FirstOrDefault(p => p.Scope == key);
                return new AccessInUseRow(resource, key, account, origin, "En pause après un refus" + FrenchText.Colon + CredentialRules.FixFor(where) + ".", Tone.Warn,
                    request is not null ? new AccessRowAction("recover", "Utiliser un autre compte", request.Id) : action);
            }
            return new AccessInUseRow(resource, key, account, origin, "Aucun refus enregistré.", Tone.Ok, action);
        }
    }

    private ImmutableArray<AccessMemoryRow> MemoryRows(DateTimeOffset now)
    {
        var rows = ImmutableArray.CreateBuilder<AccessMemoryRow>();
        foreach (var usage in new[] { AccessUsage.Remote, AccessUsage.Secrets })
        {
            if (secondary.TryGetValue(usage, out var held))
            {
                rows.Add(new AccessMemoryRow("secondary:" + CredentialRules.UsageId(usage), CredentialRules.UsageLabel(usage), held.Login,
                    usage == AccessUsage.Remote ? "compte Postes de la page Comptes" : "compte Secrets de la page Comptes",
                    "jusqu’à «\u00A0Effacer\u00A0» ou la fin de la session", -1, true, faults.Overlaps(CredentialRules.ResourcesOf(usage)) ? "En pause après un refus." : "Aucun refus enregistré.",
                    faults.Overlaps(CredentialRules.ResourcesOf(usage)) ? Tone.Warn : Tone.Ok));
            }
        }
        foreach (var (key, item) in temporary.OrderBy(t => t.Key, StringComparer.Ordinal))
        {
            var remaining = CredentialRules.Remaining(item.Lease, epoch, now);
            var origin = key.StartsWith(CredentialRules.RemoteLocalPrefix, StringComparison.Ordinal) ? "compte local temporaire de ce poste" : "compte temporaire accepté après un refus";
            rows.Add(new AccessMemoryRow("temporary:" + key, CredentialRules.ScopeLabel(key), item.Login, origin, remaining.Text, remaining.Minutes, remaining.Usable,
                faults.Contains(key) ? "En pause après un refus." : "Aucun refus enregistré.", faults.Contains(key) ? Tone.Warn : Tone.Ok));
        }
        return rows.ToImmutable();
    }

    private SecondaryAccount Secondary(AccessUsage usage, RememberedAccount? remembered)
    {
        var resources = CredentialRules.ResourcesOf(usage);
        if (secondary.TryGetValue(usage, out var held))
        {
            var paused = faults.Overlaps(resources);
            return new SecondaryAccount(usage, CredentialRules.UsageLabel(usage), held.Login, true, held.ActivatedAt, held.Controller,
                paused ? "En pause après un refus" + FrenchText.Colon + "ressaisissez son mot de passe puis «\u00A0Activer\u00A0»." : "Actif, validé par l’annuaire" + FrenchText.Colon + "droits sur la ressource non certifiés par ce test.",
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
            log.Warning($"Préférences non enregistrées (identifiant mémorisé)\u00A0: {ex.GetType().Name}.");
            journal.Add(new JournalEntry(clock.GetUtcNow(), "Identifiant non mémorisé" + FrenchText.Colon + "il vaut pour cette session seulement", Tone.Warn));
        }
    }

    private sealed record Held(string Login, SecureString Secret, DateTimeOffset ActivatedAt, string? Controller);

    private sealed record Temporary(string Login, SecureString Secret, CredentialLease Lease);

    private sealed record Running(string Usage, string Label, DateTimeOffset StartedAt, CancellationTokenSource Cancel);

    private sealed record StoredAccount(string Account, string LastUsedAt);
}
