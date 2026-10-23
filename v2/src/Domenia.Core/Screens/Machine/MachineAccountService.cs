using System.Collections.Immutable;
using System.Diagnostics;
using System.Security;

namespace Domenia.Core;

/// <summary>
/// Accounts of the workstation operations for this session (Domenia 1 $script:MachineCredential, RemoteAdminCredential,
/// AccessState): kept in memory only, never written to the disk, never logged; passwords as read-only SecureString copies until
/// the Windows API. One rule picks the account of the next operation (<see cref="MachineAccountRules.Cascade"/>); every change
/// moves the account generation (point 44) so that an operation started with the previous account stops instead of mixing two.
/// The machine screen sets the typed account; the slots of the Comptes page (Postes, Secrets) and of the access recovery
/// (temporary accounts) are set through the same service.
/// <para>
/// Temporary accounts carry a lease (Domenia 1 D054): bound to the session and the domain they were given for, spent by one use,
/// at the end of the session or after a delay without use; an unusable lease is forgotten at the next check (Get-DomeniaRetryCredential).
/// A refusal pauses one place of the cascade (its source and the account generation that filled it), never every account of the
/// same name; the next operation with a paused account is refused until a trial validates it.
/// </para>
/// </summary>
public sealed class MachineAccountService : IDisposable
{
    /// <summary>Longest wait of machine.account.watch before it answers « unchanged ».</summary>
    public static readonly TimeSpan WatchTimeout = TimeSpan.FromSeconds(25);

    private const string TemporaryLocalKind = "temporaryLocal";
    private const string TemporaryKind = "temporary";
    private const string TypedKind = "typed";
    private const string RemoteKind = "remote";
    private const string SecretsKind = "secrets";
    private const string SecretsTemporaryKind = "secretsTemporary";

    private readonly EngineContext context;
    private readonly Lock gate = new();
    private readonly Dictionary<string, Slot> temporaryLocal = new(StringComparer.OrdinalIgnoreCase);

    // Pauses by place of the cascade (Slot.Place, or the connection, Windows and directory accounts by name and source).
    private readonly Dictionary<string, MachineAccountPause> pauses = new(StringComparer.Ordinal);
    private readonly List<MachineTrialResult> trials = [];
    private TaskCompletionSource changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Slot? typed;
    private Slot? remote;
    private Slot? temporary;
    private Slot? secrets;
    private Slot? secretsTemporary;
    private long generation;
    private long version;
    private long slotIds;
    private bool disposed;
    private AccessMachineSnapshot? accessState;
    private SessionSnapshot? machineSession;
    private string? machineTarget;

    private MachineAccountService(EngineContext context) => this.context = context;

    /// <summary>The single instance of the context.</summary>
    public static MachineAccountService From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new MachineAccountService(c));
    }

    /// <summary>Account generation: moves with every change of an account in use.</summary>
    public long Generation
    {
        get
        {
            lock (gate)
            {
                if (machineSession is { } session) { SyncAccessLocked(session, machineTarget); }
                return generation;
            }
        }
    }

    /// <summary>Change counter: moves with every change the page may show (accounts, leases, pauses, trials).</summary>
    public long Version
    {
        get
        {
            lock (gate)
            {
                return version;
            }
        }
    }

    // ---------------------------------------------------------------- reads

    /// <summary>The state of the cascade, for the workstation <paramref name="target"/> when one is chosen.</summary>
    public async Task<MachineAccountState> StateAsync(string? target, CancellationToken cancellationToken)
    {
        var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var key = MachineAccountRules.MachineKey(target);
        MachineWorkstation? workstation = null;
        if (key is not null && context.Readers.Find<IMachineAccountReader>() is { } reader)
        {
            workstation = await reader.FindWorkstationAsync(target!.Trim(), cancellationToken).ConfigureAwait(false);
        }
        return Build(session, key is null ? null : target!.Trim(), workstation);
    }

    /// <summary>The account the next operation on <paramref name="target"/> takes (Get-DomeniaMachineAccountInUse).</summary>
    public MachineAccountLabel Resolve(SessionSnapshot session, string? target)
    {
        ArgumentNullException.ThrowIfNull(session);
        var now = context.Clock.GetUtcNow();
        var sessionKey = MachineAccountRules.SessionKey(session);
        MachineAccountRules.CascadeInput input;
        List<(Slot Slot, string Reason)> dropped;
        lock (gate)
        {
            dropped = SweepLocked(sessionKey, now);
            input = InputLocked(session, MachineAccountRules.MachineKey(target), sessionKey, now);
        }
        Forget(dropped);
        var (_, inUse) = MachineAccountRules.Cascade(input);
        return MachineAccountRules.Label(inUse.Source, inUse.Account);
    }

    /// <summary>
    /// Account and password copy for one operation on <paramref name="target"/> (vague 3: workers of the workstations), with the
    /// place of the cascade it comes from, so that a refusal pauses that place only (<see cref="RecordRefusal"/>). A paused account is
    /// refused (machine.accountPaused) unless <paramref name="forTrial"/>: the access trial is the way to validate it. A temporary
    /// account leaves with the operation: this use extends its lease, and spends a one-shot lease. The caller disposes the copy;
    /// null for the Windows session, which needs no password. Never sent to the page.
    /// </summary>
    public MachineOperationCredential CredentialFor(SessionSnapshot session, string? target, bool forTrial = false)
    {
        ArgumentNullException.ThrowIfNull(session);
        var now = context.Clock.GetUtcNow();
        var sessionKey = MachineAccountRules.SessionKey(session);
        var key = MachineAccountRules.MachineKey(target);
        List<(Slot Slot, string Reason)> dropped = [];
        try
        {
            lock (gate)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                dropped = SweepLocked(sessionKey, now);
                var input = InputLocked(session, key, sessionKey, now);
                var (_, inUse) = MachineAccountRules.Cascade(input);
                if (inUse.Paused && !forTrial)
                {
                    throw new DomeniaOperationException(MachineErrors.AccountPaused, MachineErrors.AccountPausedMessage);
                }
                if (accessState is { } shared && shared.Slots.TryGetValue(inUse.Source, out var external)
                    && string.Equals(external.Account, inUse.Account, StringComparison.OrdinalIgnoreCase))
                {
                    var credential = AccountAccess.From(context).AcquireMachineSlot(session, target, shared, inUse.Source, external, forTrial);
                    SyncAccessLocked(session, target); // account for a consumed one-shot lease before the read leaves
                    return credential with { Generation = generation };
                }
                var slot = inUse.Source switch
                {
                    MachineAccountSource.TemporaryLocal => key is null ? null : temporaryLocal.GetValueOrDefault(key),
                    MachineAccountSource.Temporary => temporary,
                    MachineAccountSource.Typed => typed,
                    MachineAccountSource.Remote => remote,
                    _ => null,
                };
                if (slot?.Lease is { } lease)
                {
                    slot.Lease = MachineAccountRules.UseLease(lease, now);
                    BumpLocked();
                }
                var place = slot?.Place ?? NamedPlace(inUse.Source, inUse.Account);
                return new MachineOperationCredential(inUse.Source, MachineAccountRules.ForTarget(inUse.Account, target), slot?.CopyPassword(), place) { Generation = generation };
            }
        }
        finally
        {
            Forget(dropped);
        }
    }

    /// <summary>
    /// Waits until the change counter differs from <paramref name="since"/> (null: answers at once), <paramref name="timeout"/> at
    /// most, and returns it. An inactivity lease that expires meanwhile is forgotten and counts as a change. Memory only: no read.
    /// </summary>
    public async Task<long> WaitForChangeAsync(long? since, SessionSnapshot session, TimeSpan timeout, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        var sessionKey = MachineAccountRules.SessionKey(session);
        var started = Stopwatch.GetTimestamp();
        while (true)
        {
            var now = context.Clock.GetUtcNow();
            Task signal;
            long current;
            DateTimeOffset? expiry;
            List<(Slot Slot, string Reason)> dropped;
            lock (gate)
            {
                if (disposed)
                {
                    return version;
                }
                dropped = SweepLocked(sessionKey, now);
                SyncAccessLocked(session, machineTarget);
                current = version;
                signal = changed.Task;
                expiry = NextExpiryLocked();
            }
            Forget(dropped);
            var left = timeout - Stopwatch.GetElapsedTime(started);
            if (since is null || current != since.Value || left <= TimeSpan.Zero)
            {
                return current;
            }
            // Wake up at the next lease expiry (one second after it, at least one second from now), never after the timeout.
            var wait = expiry is { } at
                ? TimeSpan.FromTicks(Math.Clamp((at - now).Ticks + TimeSpan.TicksPerSecond, Math.Min(TimeSpan.TicksPerSecond, left.Ticks), left.Ticks))
                : left;
            // Accounts can change from the Comptes screen; observe its local revision without extending a lease.
            if (wait > TimeSpan.FromSeconds(1)) { wait = TimeSpan.FromSeconds(1); }
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var delay = Task.Delay(wait, stop.Token);
            await Task.WhenAny(signal, delay).ConfigureAwait(false);
            await stop.CancelAsync().ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
        }
    }

    // ---------------------------------------------------------------- typed account (panel « Compte poste »)

    /// <summary>
    /// Uses a typed account for the workstation operations, in memory only (Set-MachineCredentialFromUi). The password is a
    /// read-only SecureString owned by the service from now on (null in simulation, which asks for none). A new place: a pause of
    /// the previous typed account does not follow it.
    /// </summary>
    public void UseTyped(string account, SecureString? password)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        Replace(ref typed, TypedKind, account, password, null);
        context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Compte poste saisi pour la session (en mémoire seulement)", Tone.Info));
    }

    /// <summary>Forgets the typed account (Clear-MachineCredential); the next level of the cascade takes over.</summary>
    public bool ForgetTyped()
    {
        if (!Replace(ref typed, TypedKind, null, null, null))
        {
            return false;
        }
        context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Compte poste oublié" + FrenchText.Colon + "retour au compte configuré", Tone.Info));
        return true;
    }

    // ---------------------------------------------------------------- slots of the Comptes page and of the access recovery

    /// <summary>Postes account of the Comptes page (CPT-013), after its validation by that page.</summary>
    public void UseRemote(string account, SecureString? password)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        Replace(ref remote, RemoteKind, account, password, null);
    }

    public void ClearRemote() => Replace(ref remote, RemoteKind, null, null, null);

    /// <summary>Secrets account of the Comptes page (CPT-014).</summary>
    public void UseSecrets(string account, SecureString? password)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        Replace(ref secrets, SecretsKind, account, password, null);
    }

    public void ClearSecrets() => Replace(ref secrets, SecretsKind, null, null, null);

    /// <summary>
    /// Temporary account accepted after a refusal: for one workstation (local account) or for every workstation, with its lease
    /// bound to <paramref name="session"/> (one use, the session, or <paramref name="idleMinutes"/> without use).
    /// </summary>
    public void AcceptTemporary(
        SessionSnapshot session, string? computer, string account, SecureString? password,
        MachineLeaseMode mode = MachineLeaseMode.Inactivity, int idleMinutes = MachineAccountRules.DefaultIdleMinutes)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        var lease = MachineAccountRules.NewLease(mode, idleMinutes, MachineAccountRules.SessionKey(session), context.Clock.GetUtcNow());
        if (MachineAccountRules.MachineKey(computer) is not { } key)
        {
            Replace(ref temporary, TemporaryKind, account, password, lease);
            return;
        }
        password?.MakeReadOnly();
        Slot? previous;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            previous = temporaryLocal.GetValueOrDefault(key);
            temporaryLocal[key] = NewSlotLocked(TemporaryLocalKind, account, password, lease);
            if (previous is not null)
            {
                pauses.Remove(previous.Place);
            }
            generation++;
            BumpLocked();
        }
        previous?.Dispose();
    }

    public void ForgetTemporary(string? computer)
    {
        if (MachineAccountRules.MachineKey(computer) is not { } key)
        {
            Replace(ref temporary, TemporaryKind, null, null, null);
            return;
        }
        Slot? previous;
        lock (gate)
        {
            temporaryLocal.Remove(key, out previous);
            if (previous is not null)
            {
                pauses.Remove(previous.Place);
                generation++;
                BumpLocked();
            }
        }
        previous?.Dispose();
    }

    /// <summary>Temporary account of the secrets reads, accepted after a refusal of LAPS or BitLocker, with its lease.</summary>
    public void AcceptSecretsTemporary(
        SessionSnapshot session, string account, SecureString? password,
        MachineLeaseMode mode = MachineLeaseMode.Inactivity, int idleMinutes = MachineAccountRules.DefaultIdleMinutes)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        var lease = MachineAccountRules.NewLease(mode, idleMinutes, MachineAccountRules.SessionKey(session), context.Clock.GetUtcNow());
        Replace(ref secretsTemporary, SecretsTemporaryKind, account, password, lease);
    }

    public void ForgetSecretsTemporary() => Replace(ref secretsTemporary, SecretsTemporaryKind, null, null, null);

    // ---------------------------------------------------------------- refusals and trials

    /// <summary>
    /// A refusal pauses one place of the cascade (<see cref="MachineOperationCredential.Place"/>, credential guard): it stays paused
    /// until a trial validates it. Another place holding the same name is not touched.
    /// </summary>
    public void RecordRefusal(string place, string account, string reason)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(place);
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        lock (gate)
        {
            pauses[place] = new MachineAccountPause(account.Trim(), context.Clock.GetUtcNow(), reason);
            BumpLocked();
        }
    }

    /// <summary>A success validates the place: its pause ends.</summary>
    public void ClearPause(string place)
    {
        ArgumentNullException.ThrowIfNull(place);
        lock (gate)
        {
            if (pauses.Remove(place))
            {
                BumpLocked();
            }
        }
    }

    /// <summary>
    /// Records a trial of the session (newest first, eight kept). With the place of the account in service, a refusal of the
    /// identifiers or of the account pauses that place and an administrator access validates it; a candidate account (to
    /// validate, not in service) has no place: its verdict never pauses nor releases the account in service, even of the same name.
    /// </summary>
    public void RecordTrial(MachineTrialResult trial, string? place, string accountTried)
    {
        ArgumentNullException.ThrowIfNull(trial);
        ArgumentNullException.ThrowIfNull(accountTried);
        if (place is not null) { AccountAccess.From(context).RecordMachineTrial(place, accountTried, trial); }
        lock (gate)
        {
            trials.Insert(0, trial);
            if (trials.Count > MachineAccountRules.MaxTrials)
            {
                trials.RemoveRange(MachineAccountRules.MaxTrials, trials.Count - MachineAccountRules.MaxTrials);
            }
            if (place is not null && accountTried.Length > 0)
            {
                if (trial.Verdict is MachineTrialVerdict.Rejected or MachineTrialVerdict.AccountState)
                {
                    pauses[place] = new MachineAccountPause(accountTried.Trim(), trial.At, trial.Text);
                }
                else if (trial.Verdict == MachineTrialVerdict.AdminOk)
                {
                    pauses.Remove(place);
                }
            }
            BumpLocked();
        }
    }

    public void Dispose()
    {
        List<Slot> slots;
        lock (gate)
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            slots = [.. new[] { typed, remote, temporary, secrets, secretsTemporary }.OfType<Slot>(), .. temporaryLocal.Values];
            typed = remote = temporary = secrets = secretsTemporary = null;
            temporaryLocal.Clear();
            changed.TrySetResult();
        }
        foreach (var slot in slots)
        {
            slot.Dispose();
        }
    }

    // ---------------------------------------------------------------- state

    /// <summary>Builds the state for the page (names only).</summary>
    public MachineAccountState Build(SessionSnapshot session, string? target, MachineWorkstation? workstation)
    {
        ArgumentNullException.ThrowIfNull(session);
        var simulation = context.Directory.Kind == DirectorySourceKind.Simulation;
        var now = context.Clock.GetUtcNow();
        var sessionKey = MachineAccountRules.SessionKey(session);
        var directoryAccount = DirectoryAccount(session);
        MachineAccountRules.CascadeInput input;
        SecretsAccountState secretsState;
        MachineTypedAccount? typedAccount;
        long generationNow;
        long versionNow;
        ImmutableArray<MachineTrialResult> trialsNow;
        List<(Slot Slot, string Reason)> dropped;
        lock (gate)
        {
            dropped = SweepLocked(sessionKey, now);
            input = InputLocked(session, MachineAccountRules.MachineKey(target), sessionKey, now);
            ImmutableArray<MachineAccountPause?> secretsPauses =
            [
                secretsTemporary is null ? null : pauses.GetValueOrDefault(secretsTemporary.Place),
                secrets is null ? null : pauses.GetValueOrDefault(secrets.Place),
                pauses.GetValueOrDefault(NamedPlace("directory", directoryAccount)),
            ];
            secretsState = MachineAccountRules.SecretsCascade(
                accessState?.SecretsTemporary?.Account ?? secretsTemporary?.Account, accessState?.Secrets?.Account ?? secrets?.Account, directoryAccount,
                [accessState?.SecretsTemporary?.Pause ?? secretsPauses[0], accessState?.Secrets?.Pause ?? secretsPauses[1], secretsPauses[2]],
                accessState?.SecretsTemporary?.Remaining ?? (secretsTemporary is null ? null : MachineAccountRules.LeaseRemaining(secretsTemporary.Lease, sessionKey, now).Text));
            typedAccount = typed is null ? null : new MachineTypedAccount(typed.Account, typed.Since, typed.HasPassword);
            generationNow = generation;
            versionNow = version;
            trialsNow = [.. trials];
        }
        Forget(dropped);
        var (levels, inUse) = MachineAccountRules.Cascade(input);
        var label = MachineAccountRules.Label(inUse.Source, inUse.Account);
        return new MachineAccountState(
            inUse, MachineAccountRules.Sentence(label), MachineAccountRules.MachineKey(target) is null ? null : target!.Trim(), workstation, levels, secretsState,
            typedAccount, !simulation, CredentialNote(simulation), generationNow, versionNow, simulation, trialsNow, Safeguards(simulation));
    }

    private MachineAccountRules.CascadeInput InputLocked(SessionSnapshot session, string? key, string sessionKey, DateTimeOffset now)
    {
        SyncAccessLocked(session, key);
        var external = accessState!.Slots;
        var externalLocal = external.GetValueOrDefault(MachineAccountSource.TemporaryLocal);
        var externalTemporary = external.GetValueOrDefault(MachineAccountSource.Temporary);
        var externalRemote = external.GetValueOrDefault(MachineAccountSource.Remote);
        var connection = session.Authentication.Method == AuthenticationMethod.ExplicitCredentials ? session.Account.Login : null;
        var windows = WindowsAccount(session);
        var local = key is null ? null : temporaryLocal.GetValueOrDefault(key);
        string?[] places =
        [
            local?.Place, temporary?.Place, typed?.Place, remote?.Place,
            connection is null ? null : NamedPlace(MachineAccountSource.Connection, connection), NamedPlace(MachineAccountSource.Windows, windows),
        ];
        return new MachineAccountRules.CascadeInput(
            externalLocal?.Account ?? local?.Account, externalTemporary?.Account ?? temporary?.Account, typed?.Account, externalRemote?.Account ?? remote?.Account, connection, windows,
            key is not null, context.Directory.Kind == DirectorySourceKind.Simulation,
            [externalLocal?.Pause ?? Pause(places[0]), externalTemporary?.Pause ?? Pause(places[1]), Pause(places[2]), externalRemote?.Pause ?? Pause(places[3]),
                external.GetValueOrDefault(MachineAccountSource.Connection)?.Pause ?? Pause(places[4]), external.GetValueOrDefault(MachineAccountSource.Windows)?.Pause ?? Pause(places[5])],
            externalLocal?.Remaining ?? (local is null ? null : MachineAccountRules.LeaseRemaining(local.Lease, sessionKey, now).Text),
            externalTemporary?.Remaining ?? (temporary is null ? null : MachineAccountRules.LeaseRemaining(temporary.Lease, sessionKey, now).Text));
        MachineAccountPause? Pause(string? place) => place is null ? null : pauses.GetValueOrDefault(place);
    }

    private void SyncAccessLocked(SessionSnapshot session, string? target)
    {
        var next = AccountAccess.From(context).MachineSnapshot(session, target);
        var identityChanged = machineSession is { } earlier && SessionIdentity.Key(earlier) != SessionIdentity.Key(session);
        if (accessState is { } previous && (previous.Epoch != next.Epoch
            || identityChanged))
        {
            foreach (var slot in new[] { typed, remote, temporary, secrets, secretsTemporary }.OfType<Slot>().Concat(temporaryLocal.Values)) { slot.Dispose(); }
            typed = remote = temporary = secrets = secretsTemporary = null;
            temporaryLocal.Clear(); pauses.Clear(); trials.Clear();
        }
        if (accessState is { } prior && (prior.Generation != next.Generation || prior.Epoch != next.Epoch || identityChanged)) { generation++; }
        if (accessState is { } old && (old.Revision != next.Revision || old.Epoch != next.Epoch || identityChanged)) { BumpLocked(); }
        accessState = next; machineSession = session; machineTarget = target;
    }

    /// <summary>
    /// Forgets the temporary accounts whose lease no longer allows a new use (another session or domain, spent, idle too long),
    /// like Get-DomeniaRetryCredential; returns them so that the caller disposes them outside the lock.
    /// </summary>
    private List<(Slot Slot, string Reason)> SweepLocked(string sessionKey, DateTimeOffset now)
    {
        List<(Slot Slot, string Reason)> dropped = [];
        foreach (var (key, slot) in temporaryLocal.ToList())
        {
            var check = MachineAccountRules.CheckLease(slot.Lease, sessionKey, now);
            if (!check.Usable)
            {
                temporaryLocal.Remove(key);
                dropped.Add((slot, check.Reason));
            }
        }
        if (temporary is not null)
        {
            var check = MachineAccountRules.CheckLease(temporary.Lease, sessionKey, now);
            if (!check.Usable)
            {
                dropped.Add((temporary, check.Reason));
                temporary = null;
            }
        }
        if (secretsTemporary is not null)
        {
            var check = MachineAccountRules.CheckLease(secretsTemporary.Lease, sessionKey, now);
            if (!check.Usable)
            {
                dropped.Add((secretsTemporary, check.Reason));
                secretsTemporary = null;
            }
        }
        if (dropped.Count > 0)
        {
            foreach (var (slot, _) in dropped)
            {
                pauses.Remove(slot.Place);
            }
            generation++;
            BumpLocked();
        }
        return dropped;
    }

    /// <summary>Disposes the temporary accounts forgotten by a check and says so in the journal (without their names).</summary>
    private void Forget(List<(Slot Slot, string Reason)> dropped)
    {
        foreach (var (slot, reason) in dropped)
        {
            slot.Dispose();
            context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Compte temporaire oublié" + FrenchText.Colon + reason.TrimEnd('.'), Tone.Info));
        }
    }

    /// <summary>Earliest instant an inactivity lease stops being usable, if nothing uses it before.</summary>
    private DateTimeOffset? NextExpiryLocked()
    {
        DateTimeOffset? next = null;
        List<Slot?> slots = [.. temporaryLocal.Values, temporary, secretsTemporary];
        foreach (var slot in slots)
        {
            if (slot?.Lease is { } lease && MachineAccountRules.LeaseExpiry(lease) is { } at && (next is null || at < next))
            {
                next = at;
            }
        }
        return next;
    }

    private void BumpLocked()
    {
        version++;
        var previous = changed;
        changed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        previous.TrySetResult();
    }

    private static string NamedPlace(MachineAccountSource source, string account) => NamedPlace(source.ToString(), account);

    private static string NamedPlace(string source, string account) => source.ToLowerInvariant() + "|" + account.Trim().ToLowerInvariant();

    /// <summary>
    /// Account of the Windows session: the session account in simulation (never the real Windows account, so captures show no
    /// real name), the process account in directory mode.
    /// </summary>
    private string WindowsAccount(SessionSnapshot session)
    {
        if (context.Directory.Kind == DirectorySourceKind.Simulation || session.Authentication.Method != AuthenticationMethod.ExplicitCredentials)
        {
            return session.Account.Login;
        }
        return Environment.UserDomainName + "\\" + Environment.UserName;
    }

    /// <summary>Account of the directory reads: the connection account, otherwise the Windows session.</summary>
    private string DirectoryAccount(SessionSnapshot session) =>
        session.Authentication.Method == AuthenticationMethod.ExplicitCredentials ? session.Account.Login : WindowsAccount(session);

    private static string CredentialNote(bool simulation) => simulation
        ? "Simulation : aucun mot de passe n’est demandé. Le compte est gardé par son nom, en mémoire, pour essayer la règle et l’essai d’accès sur l’annuaire fictif."
        : "Le mot de passe est saisi dans une fenêtre native et gardé en SecureString en lecture seule jusqu’à l’API Windows. Il ne passe pas par la page et reste en mémoire pour cette session seulement.";

    private static ImmutableArray<string> Safeguards(bool simulation)
    {
        var list = new List<string>
        {
            "Le compte poste vaut pour cette session : jamais enregistré sur le disque, jamais journalisé.",
            "En mode annuaire, le mot de passe reste dans la fenêtre native puis en SecureString jusqu’à l’API Windows ; il ne passe ni par la page ni par la ligne de commande.",
            "Fermer le panneau, Échap ou un clic à côté ne changent rien : un mot de passe saisi sans " + FrenchText.Quote("Utiliser ce compte") + " est effacé.",
            "Chaque changement de compte ouvre une nouvelle génération : une opération lancée avec l’ancien compte s’arrête au lieu de mélanger deux comptes.",
            "L’essai d’accès lit seulement le système du poste choisi, sur votre clic : un seul poste, aucun balayage, aucune autre méthode.",
            "Un refus met en pause ce compte, à cette place de la règle : la prochaine opération avec lui est refusée tant qu’un essai réussi ne l’a pas validé.",
            "Un compte temporaire accepté après un refus a un bail : une seule utilisation, la session, ou 30 min sans utilisation ; il ne sert jamais dans une autre session ni pour un autre domaine.",
        };
        if (simulation)
        {
            list.Add("Simulation : aucun mot de passe n’est demandé, aucun poste n’est contacté ; l’essai lit l’annuaire fictif.");
        }
        return [.. list];
    }

    /// <summary>Replaces one slot (null account: forgets it). Returns whether something changed.</summary>
    private bool Replace(ref Slot? slot, string kind, string? account, SecureString? password, MachineLease? lease)
    {
        password?.MakeReadOnly();
        Slot? previous;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            previous = slot;
            slot = string.IsNullOrWhiteSpace(account) ? null : NewSlotLocked(kind, account, password, lease);
            if (previous is null && slot is null)
            {
                return false;
            }
            if (previous is not null)
            {
                pauses.Remove(previous.Place);
            }
            generation++;
            BumpLocked();
        }
        previous?.Dispose();
        return true;
    }

    private Slot NewSlotLocked(string kind, string account, SecureString? password, MachineLease? lease) =>
        new(kind, ++slotIds, account.Trim(), password, context.Clock.GetUtcNow()) { Lease = lease };

    /// <summary>
    /// One account in memory: its place in the cascade (kind and id: a new account of the same name is a new place), its name, its
    /// read-only password, since when it is used and its lease (temporary accounts only).
    /// </summary>
    private sealed class Slot(string kind, long id, string account, SecureString? password, DateTimeOffset since) : IDisposable
    {
        private readonly IDisposable tracked = SecureCredentialCopies.Track(password);
        public string Place { get; } = kind + "#" + id.ToString(System.Globalization.CultureInfo.InvariantCulture);

        public string Account { get; } = account;

        public DateTimeOffset Since { get; } = since;

        public MachineLease? Lease { get; set; }

        public bool HasPassword => password is not null;

        /// <summary>A read-only copy for one operation; the caller disposes it.</summary>
        public SecureString? CopyPassword()
        {
            if (password is null)
            {
                return null;
            }
            var copy = password.Copy();
            copy.MakeReadOnly();
            return copy;
        }

        public void Dispose() { tracked.Dispose(); password?.Dispose(); }
    }
}
