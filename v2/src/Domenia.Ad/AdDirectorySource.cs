using System.Collections.Immutable;
using System.Security.Principal;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Ad;

/// <summary>
/// The directory source of the directory mode (Active Directory of the domain of the computer, Windows session). Nothing is read
/// in the constructor or in local session reads. The first explicit network operation connects once (RootDSE, domain object,
/// account of the session: bounded, never retried in a loop). The directory picture is read on an explicit
/// request (« Actualiser » of the home page): users, groups, OUs and computers of the selected branch, paged, 50 000 per kind at most;
/// workstation measures (presence, light inventory) only on the working OU, never on the domain root. Read only by
/// construction: the write executors of Domenia.Ad are the only writers, through <see cref="Connection"/>.
/// </summary>
public sealed partial class AdDirectorySource : IDirectorySource, IDirectoryRefreshPreparation, IAccountContextSource, IDirectoryWriteLeaseSource, IDisposable
{
    public const int MaxObjectsPerKind = 50_000;

    /// <summary>After a failed connection, reads wait this long before trying again (never a loop on an absent controller).</summary>
    public static readonly TimeSpan RetryAfter = TimeSpan.FromSeconds(30);

    private static readonly TimeSpan PingTimeout = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan InventoryTimeout = TimeSpan.FromSeconds(15);
    private const int PingParallel = 16;
    private const int InventoryParallel = 6;

    private readonly string? joinedDomain;
    private readonly Func<string> accountLogin;
    private readonly IWorkstationProbe? probe;
    private readonly SemaphoreSlim connecting = new(1, 1);
    private readonly SemaphoreSlim refreshing = new(1, 1);
    private readonly SemaphoreSlim loadingLocal = new(1, 1);
    private readonly SemaphoreSlim savingFleet = new(1, 1);
    private CachedFleet fleet = CachedFleet.Empty("session");
    private bool localLoaded;
    private readonly Lock gate = new();
    private DomainInfo? domain;
    private AccountIdentity? account;
    private string? accountSid;
    private DateTimeOffset? sessionStartedAt;
    private RightsInfo? rights;
    private string? failure;
    private string failureCode = AdErrors.NotConnected;
    private DateTimeOffset? failedAt;
    private DirectoryState? state;
    private long epoch;
    private bool disposed;
    private string? connectionLogin;
    private int writeLeases;
    public IDisposable AcquireWriteLease(SessionSnapshot expected)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (localMaintenance) { throw WriteErrors.Refusal(WriteErrors.Stale, "Maintenance locale en cours ; préparez un nouveau plan après sa fin."); }
            if (epoch != expected.Epoch || account is { } current && current.Login != expected.Account.Login)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée avant les préconditions ; aucune écriture envoyée."); }
            writeLeases++;
            return new WriteLease(this);
        }
    }
    private sealed class WriteLease(AdDirectorySource source) : IDisposable
    {
        private AdDirectorySource? owner = source;
        public void Dispose() { if (Interlocked.Exchange(ref owner, null) is { } active) { lock (active.gate) { active.writeLeases--; } } }
    }
    internal EngineContext? AccountContext { get; private set; }
    public void BindAccountContext(EngineContext context)
    {
        lock (gate)
        {
            if (AccountContext is not null && !ReferenceEquals(AccountContext, context)) { throw new InvalidOperationException("Directory source already belongs to an account context."); }
            AccountContext = context;
        }
    }

    internal AdCredentialCopy CopySessionCredential(long expectedEpoch, string expectedAccount)
    {
        lock (gate)
        {
            if (epoch != expectedEpoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée avant le départ de la lecture."); }
            if (connection is not AdConnection actual) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Compte du transport natif indisponible."); }
            if (account is { } identity && !string.Equals(identity.Login, expectedAccount, StringComparison.OrdinalIgnoreCase))
            { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Identité de transport différente du compte choisi."); }
            return actual.CopyCredential();
        }
    }

    public AdDirectorySource(string? joinedDomain, Func<string> accountLogin, TimeProvider clock, IWorkstationProbe? probe = null, IAdConnection? connection = null, IDirectoryCache? localStore = null)
    {
        ArgumentNullException.ThrowIfNull(accountLogin);
        ArgumentNullException.ThrowIfNull(clock);
        this.joinedDomain = joinedDomain;
        this.accountLogin = accountLogin;
        this.probe = probe;
        Clock = clock;
        LocalStore = localStore;
        this.connection = connection ?? AdConnectionFactory.Create(new AdConnectionOptions(null, joinedDomain));
        connectionLogin = (this.connection as AdConnection)?.ExplicitLogin;
    }

    public DirectorySourceKind Kind => DirectorySourceKind.ActiveDirectory;

    /// <summary>The LDAP connection of the session (opened on first use).</summary>
    private IAdConnection connection;
    public IAdConnection Connection { get { lock (gate) { return connection; } } }

    internal DomainInfo? KnownDomain { get { lock (gate) { return domain ?? state?.Directory.Domain; } } }
    internal string? JoinedDomain => joinedDomain;
    internal bool IsExplicitSession { get { lock (gate) { return connectionLogin is not null; } } }

    /// <summary>Adopts an already authenticated connection atomically; a late result can never replace a newer session.</summary>
    internal void AdoptConnection(IAdConnection candidate, DomainInfo known, AdSessionIdentity identity, long expectedEpoch, bool correction)
    {
        IAdConnection previous;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (writeLeases != 0) { throw new DomeniaOperationException(AccountAccess.WritePending, "Une écriture est en cours ; la connexion actuelle est conservée."); }
            if (epoch != expectedEpoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée pendant la validation : connexion écartée."); }
            var before = domain ?? state?.Directory.Domain;
            if (before is not null && (!DistinguishedName.AreEqual(before.RootDn, known.RootDn) || before.DomainSid != known.DomainSid)
                || before is null && joinedDomain is not null && !joinedDomain.Equals(known.DnsName, StringComparison.OrdinalIgnoreCase)
                || identity.Sid is null || identity.Identity.Dn is null
                || correction && (accountSid is null || accountSid != identity.Sid))
            { throw new DomeniaOperationException(AdErrors.Credentials, "Domaine ou identité de connexion non confirmé : session conservée."); }
            previous = connection;
            connection = candidate;
            connectionLogin = identity.Identity.Login;
            domain = known;
            account = identity.Identity;
            accountSid = identity.Sid;
            rights = identity.Rights;
            failure = null;
            failedAt = null;
            if (!correction)
            {
                sessionStartedAt = Clock.GetUtcNow();
                state = null;
                localLoaded = false;
                fleet = CachedFleet.Empty("session");
            }
            epoch++;
        }
        previous.Dispose();
    }

    public TimeProvider Clock { get; }

    public IDirectoryCache? LocalStore { get; }

    internal string? SessionSid { get { lock (gate) { return accountSid; } } }
    internal DateTimeOffset? SessionStartedAt { get { lock (gate) { return sessionStartedAt; } } }

    public bool CanPrepareDirectoryRefresh => LocalStore is IPreparedDirectoryCache;

    public async Task<DirectoryBackupReceipt> PrepareDirectoryRefreshAsync(CancellationToken cancellationToken)
    {
        if (LocalStore is not IPreparedDirectoryCache cache)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Sauvegarde locale vérifiée indisponible : aucune relecture AD lancée."); }
        try { return await cache.PrepareAsync(cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Sauvegarde locale non vérifiée ou espace disque insuffisant : aucune relecture AD lancée."); }
    }

    internal CachedFleet FleetDetails { get { lock (gate) { return fleet; } } }

    internal async Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, long generation, CancellationToken token)
    {
        await savingFleet.WaitAsync(token).ConfigureAwait(false);
        try
        {
            CachedFleet before;
            lock (gate)
            {
                if (epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant le relevé : publication annulée."); }
                before = fleet;
            }
            var saved = LocalStore is IAccueilCache cache ? await cache.SaveFleetAsync(patch, token).ConfigureAwait(false) : before.Merge(patch);
            lock (gate)
            {
                if (epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant l’enregistrement : publication annulée."); }
                fleet = saved;
                if (state is not null) { state = state with { Observations = saved.Observations }; }
                return saved;
            }
        }
        finally { savingFleet.Release(); }
    }

    internal long Epoch
    {
        get
        {
            lock (gate)
            {
                return epoch;
            }
        }
    }

    /// <summary>Local time zone of the session (dates shown and typed by the operator).</summary>
    public TimeZoneInfo Zone => Clock.LocalTimeZone;

    /// <summary>DNS name of the controller in use, once connected.</summary>
    public string? ControllerName => Connection.Server;

    /// <summary>Last directory picture read in this session, or null before the first read.</summary>
    public DirectorySnapshot? CurrentDirectory
    {
        get
        {
            lock (gate)
            {
                return state?.Directory;
            }
        }
    }

    /// <summary>Last observations of the workstations measured in this session.</summary>
    public FleetObservations CurrentObservations
    {
        get
        {
            lock (gate)
            {
                return state?.Observations ?? FleetObservations.Empty;
            }
        }
    }

    /// <summary>The domain (identity, controllers, password policy): read once, at the first need.</summary>
    public async Task<DomainInfo> DomainAsync(CancellationToken cancellationToken)
    {
        await EnsureConnectedAsync(retry: true, cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            return domain ?? throw new DomeniaOperationException(AdErrors.NotConnected, failure ?? AdErrors.NotConnectedMessage);
        }
    }

    public async Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken)
    {
        await LoadLocalAsync(cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            var directory = state?.Directory;
            var store = directory is null || directory.ReadAt == DateTimeOffset.MinValue ? new StoreStatus(null, 0, false) : new StoreStatus(directory.ReadAt, directory.ObjectCount, directory.Complete);
            var explicitLogin = connectionLogin;
            var login = account?.Login ?? explicitLogin ?? accountLogin();
            var authentication = explicitLogin is null
                ? new AuthenticationInfo(AuthenticationMethod.WindowsSession, null, domain is null ? "Session Windows" : "Session Windows (négociation, signée et chiffrée)")
                : new AuthenticationInfo(AuthenticationMethod.ExplicitCredentials, null, domain is null ? "Compte explicite" : "Compte explicite (négociation, signée et chiffrée)");
            if (domain is null)
            {
                return new SessionSnapshot(
                    ConnectionState.Disconnected,
                    directory is not null ? new DomainIdentity(directory.Domain.DnsName, directory.Domain.NetbiosName, directory.Domain.RootDn) : joinedDomain is null ? null : new DomainIdentity(joinedDomain, null, null),
                    null,
                    account ?? new AccountIdentity(login, null, null, null),
                    authentication,
                    null,
                    new RightsInfo(RightsLevel.Unknown, SessionTexts.RightsLabel(RightsLevel.Unknown), true, failure ?? "Droits évalués à la connexion à l’annuaire."),
                    false,
                    store,
                    epoch);
            }
            var controller = ControllerName is { } server ? new ControllerIdentity(server, domain.Controllers.FirstOrDefault(c => string.Equals(c.DnsName, server, StringComparison.OrdinalIgnoreCase))?.Site) : null;
            return new SessionSnapshot(
                ConnectionState.Connected,
                new DomainIdentity(domain.DnsName, domain.NetbiosName, domain.RootDn),
                controller,
                account ?? new AccountIdentity(login, null, null, null),
                authentication,
                null,
                rights ?? new RightsInfo(RightsLevel.Unknown, SessionTexts.RightsLabel(RightsLevel.Unknown), true, "Droits non mesurés ; vérification nécessaire sur chaque objet."),
                false,
                store,
                epoch);
        }
    }

    public async Task<SessionSnapshot> ConnectAsync(CancellationToken cancellationToken)
    {
        await EnsureConnectedAsync(retry: true, cancellationToken).ConfigureAwait(false);
        return await GetSessionAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken)
    {
        await LoadLocalAsync(cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            if (state is not null) { return state; }
            var known = domain ?? throw new DomeniaOperationException(AdErrors.NotConnected, failure ?? AdErrors.NotConnectedMessage);
            return state = Empty(known);
        }
    }

    private async Task LoadLocalAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (LocalStore is null) { return; }
        await loadingLocal.WaitAsync(token).ConfigureAwait(false);
        try
        {
            lock (gate) { if (localLoaded) { return; } }
            var generation = Epoch;
            var loaded = LocalStore is IObjectDirectoryCache objects ? await objects.ReadKnownAsync(token).ConfigureAwait(false) : await LocalStore.ReadAsync(token).ConfigureAwait(false);
            var readings = LocalStore is IAccueilCache cache ? await cache.ReadFleetAsync(token).ConfigureAwait(false) : CachedFleet.Empty("session");
            lock (gate)
            {
                if (epoch != generation) { return; }
                fleet = readings;
                if (loaded is not null && state is null)
                {
                    state = Empty(domain ?? loaded.Domain) with { Directory = domain is null ? loaded : loaded with { Domain = domain }, Observations = readings.Observations };
                }
                localLoaded = true;
            }
        }
        finally { loadingLocal.Release(); }
    }

    /// <summary>Publishes a point read only after its durable acknowledgement; shares the refresh lock with census reads.</summary>
    internal async Task RememberObjectsAsync(DirectorySnapshot objects, long generation, CancellationToken token)
    {
        await LoadLocalAsync(token).ConfigureAwait(false);
        await refreshing.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (Epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la lecture : publication annulée."); }
            DirectorySnapshot saved;
            if (LocalStore is IObjectDirectoryCache cache)
            {
                saved = await cache.SaveObjectsAsync(objects, ControllerName, token).ConfigureAwait(false);
            }
            else if (LocalStore is not null)
            {
                throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "La base locale ne permet pas de conserver les lectures ciblées.");
            }
            else
            {
                var old = CurrentDirectory;
                if (old is null) { saved = objects; }
                else
                {
                    var dates = old.ObjectReadAt ?? SearchRowFactory.Candidates(old).ToImmutableDictionary(c => c.Id, _ => old.ReadAt);
                    var next = SearchRowFactory.Candidates(objects).Where(c => objects.ReadAt >= dates.GetValueOrDefault(c.Id, DateTimeOffset.MinValue)).Select(c => c.Id).ToHashSet();
                    foreach (var id in next) { dates = dates.SetItem(id, objects.ReadAt); }
                    saved = old with
                    {
                        Complete = false, ObjectReadAt = dates,
                        OrganizationalUnits = Merge(old.OrganizationalUnits, [.. objects.OrganizationalUnits.Where(o => next.Contains(o.ObjectGuid))], o => o.ObjectGuid),
                        Users = Merge(old.Users, [.. objects.Users.Where(o => next.Contains(o.ObjectGuid))], o => o.ObjectGuid),
                        Computers = Merge(old.Computers, [.. objects.Computers.Where(o => next.Contains(o.ObjectGuid))], o => o.ObjectGuid),
                        Groups = Merge(old.Groups, [.. objects.Groups.Where(o => next.Contains(o.ObjectGuid))], o => o.ObjectGuid),
                        Contacts = old.Contacts is null && objects.Contacts is null ? null
                            : Merge(old.Contacts ?? [], [.. (objects.Contacts ?? []).Where(o => next.Contains(o.ObjectGuid))], o => o.ObjectGuid),
                    };
                }
            }
            lock (gate)
            {
                if (epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée avant la publication du relevé."); }
                state = (state ?? Empty(objects.Domain)) with { Directory = saved };
            }
        }
        finally { refreshing.Release(); }
    }

    internal async Task<DirectoryDeletionLinks> ForgetDeletedAsync(WriteTarget target, DateTimeOffset observedAt, CancellationToken token)
    {
        var id = Guid.ParseExact(target.ObjectGuid, "D");
        await LoadLocalAsync(token).ConfigureAwait(false);
        await refreshing.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var removed = LocalStore is IDirectoryDeletionCache cache
                ? await cache.ApplyDeletionAsync(target, observedAt, token).ConfigureAwait(false) : new DirectoryDeletionLinks(0, 0);
            lock (gate)
            {
                if (state is { } old)
                {
                    var directory = old.Directory;
                    state = old with { Directory = directory with
                    {
                        Complete = false, OrganizationalUnits = [.. directory.OrganizationalUnits.Where(o => o.ObjectGuid != id)],
                        Users = [.. directory.Users.Where(o => o.ObjectGuid != id)], Computers = [.. directory.Computers.Where(o => o.ObjectGuid != id)],
                        Groups = [.. directory.Groups.Where(o => o.ObjectGuid != id)], Contacts = directory.Contacts is null ? null : [.. directory.Contacts.Value.Where(o => o.ObjectGuid != id)],
                        ObjectReadAt = directory.ObjectReadAt?.Remove(id),
                    } };
                }
            }
            if (AccountContext is { } context)
            {
                (context.Readers.Find<IFicheReader>() as AdFicheReader)?.Forget(id);
                FicheSession.From(context).Forget(target.Dn, id);
            }
            return removed;
        }
        finally { refreshing.Release(); }
    }

    private static ImmutableArray<T> Merge<T>(ImmutableArray<T> before, ImmutableArray<T> after, Func<T, Guid> identity) =>
        [.. before.Concat(after).GroupBy(identity).Select(g => g.Last())];

    public async Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken cancellationToken)
    {
        if (family == MeasureFamily.LocalComputation)
        {
            return await ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        }
        // Refuse a missing branch even before connecting; all network measurements need an explicit branch.
        if (scope is null)
        {
            throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, DomeniaErrors.ScopeTooWideMessage);
        }
        var known = await DomainAsync(cancellationToken).ConfigureAwait(false);
        AdDirectoryReader.EnsureScope(scope, known.RootDn);
        await LoadLocalAsync(cancellationToken).ConfigureAwait(false);
        await refreshing.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            switch (family)
            {
                case MeasureFamily.Directory:
                    {
                        var generation = Epoch;
                        if (CanPrepareDirectoryRefresh) { await PrepareDirectoryRefreshAsync(cancellationToken).ConfigureAwait(false); }
                        var snapshot = await AdDirectoryReader.ReadSnapshotAsync(Connection, known, scope, MaxObjectsPerKind, Clock, cancellationToken).ConfigureAwait(false);
                        if (Epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "La session a changé pendant la lecture ; recommencez le geste."); }
                        if (LocalStore is not null) { await LocalStore.SaveAsync(snapshot, scope, ControllerName, cancellationToken).ConfigureAwait(false); }
                        lock (gate)
                        {
                            if (epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "La session a changé avant la publication du relevé."); }
                            var current = state ?? Empty(known);
                            state = current with
                            {
                                Directory = snapshot,
                                Journal = Add(current.Journal, "Annuaire relu" + FrenchText.Colon + FrenchText.Count(snapshot.ObjectCount, "objet", "objets") + (snapshot.Complete ? "" : " (limite atteinte, lecture incomplète)") + ".", snapshot.Complete ? Tone.Info : Tone.Warn),
                            };
                            return state;
                        }
                    }
                case MeasureFamily.Presence:
                    return await MeasureAsync(known, scope!, inventory: false, cancellationToken).ConfigureAwait(false);
                case MeasureFamily.Inventory:
                    return await MeasureAsync(known, scope!, inventory: true, cancellationToken).ConfigureAwait(false);
                default:
                    lock (gate)
                    {
                        return state ??= Empty(known);
                    }
            }
        }
        finally
        {
            refreshing.Release();
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) { return; }
            disposed = true;
            epoch++;
        }
        AdSyncState.Release(this);
        Connection.Dispose();
        connecting.Dispose();
        refreshing.Dispose();
        loadingLocal.Dispose();
        savingFleet.Dispose();
    }

    /// <summary>Forgets the connection state so that the next call connects again (« Reconnecter », account changed).</summary>
    public void Reset()
    {
        lock (gate)
        {
            if (writeLeases != 0) { throw new DomeniaOperationException(AccountAccess.WritePending, "Une écriture est en cours ; la session actuelle est conservée."); }
            domain = null;
            account = null;
            accountSid = null;
            sessionStartedAt = null;
            rights = null;
            failure = null;
            failedAt = null;
            state = null;
            localLoaded = false;
            fleet = CachedFleet.Empty("session");
            epoch++;
        }
    }

    /// <summary>
    /// Connects once. After a failure, nothing is tried again by the session (<paramref name="retry"/> false) nor by a read
    /// within <see cref="RetryAfter"/>: the same refusal is answered at once.
    /// </summary>
    private async Task EnsureConnectedAsync(bool retry, CancellationToken cancellationToken)
    {
        lock (gate)
        {
            if (domain is not null)
            {
                return;
            }
            if (failedAt is { } at && (!retry || Clock.GetUtcNow() - at < RetryAfter))
            {
                throw new DomeniaOperationException(failureCode, failure ?? AdErrors.NotConnectedMessage);
            }
        }
        await connecting.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            lock (gate)
            {
                if (domain is not null)
                {
                    return;
                }
                // A call that waited behind a failed attempt gets its answer, it does not try again at once.
                if (failedAt is { } at && Clock.GetUtcNow() - at < RetryAfter)
                {
                    throw new DomeniaOperationException(failureCode, failure ?? AdErrors.NotConnectedMessage);
                }
            }
            var generation = Epoch;
            try
            {
                var read = await AdDirectoryReader.ReadDomainAsync(Connection, cancellationToken).ConfigureAwait(false);
                var resolved = await ReadAccountAsync(read, cancellationToken).ConfigureAwait(false);
                lock (gate)
                {
                    if (epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la connexion : résultat écarté."); }
                    domain = read;
                    account = resolved.Identity;
                    accountSid = resolved.Sid;
                    rights = resolved.Rights;
                    sessionStartedAt = Clock.GetUtcNow();
                    failure = null;
                    failedAt = null;
                    epoch++;
                }
            }
            catch (DomeniaOperationException ex)
            {
                lock (gate)
                {
                    if (epoch == generation)
                    {
                        failure = ex.Message;
                        failureCode = ex.Code;
                        failedAt = Clock.GetUtcNow();
                    }
                }
                throw;
            }
        }
        finally
        {
            connecting.Release();
        }
    }

    /// <summary>The account of the Windows session in the directory (by its SID) and the rights estimated from its groups.</summary>
    private async Task<AdSessionIdentity> ReadAccountAsync(DomainInfo known, CancellationToken cancellationToken)
    {
        var explicitLogin = (Connection as AdConnection)?.ExplicitLogin;
        string? sid = null;
        if (explicitLogin is null)
        {
            using var identity = WindowsIdentity.GetCurrent();
            sid = identity.User?.Value;
        }
        return await AdSessionIdentity.ReadAsync(Connection, known, explicitLogin ?? accountLogin(), sid, explicitLogin is not null, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>The exact targets of the confirmed refresh: no additional ping and no expansion of its set.</summary>
    internal async Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlySet<Guid> targets, CancellationToken token)
    {
        var known = await DomainAsync(token).ConfigureAwait(false);
        AdDirectoryReader.EnsureScope(scope, known.RootDn);
        await LoadLocalAsync(token).ConfigureAwait(false);
        await refreshing.WaitAsync(token).ConfigureAwait(false);
        try { return await MeasureAsync(known, scope, true, token, targets).ConfigureAwait(false); }
        finally { refreshing.Release(); }
    }

    internal Task<DirectoryState> ReadPresenceAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, CancellationToken token) =>
        ReadFrozenMeasuresAsync(scope, targets, expectedEpoch, false, token);

    internal Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, CancellationToken token) =>
        ReadFrozenMeasuresAsync(scope, targets, expectedEpoch, true, token);

    private async Task<DirectoryState> ReadFrozenMeasuresAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, bool inventory, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(targets);
        // Copy the caller's selection before the first await; subsequent mutations cannot enlarge the confirmed population.
        var frozen = targets.ToImmutableDictionary();
        var known = await DomainAsync(token).ConfigureAwait(false);
        AdDirectoryReader.EnsureScope(scope, known.RootDn);
        await LoadLocalAsync(token).ConfigureAwait(false);
        await refreshing.WaitAsync(token).ConfigureAwait(false);
        try { return await MeasureAsync(known, scope, inventory, token, frozen.Keys.ToHashSet(), frozen, expectedEpoch).ConfigureAwait(false); }
        finally { refreshing.Release(); }
    }

    /// <summary>Completed readings are committed together, including when the remaining targets were cancelled.</summary>
    private async Task<DirectoryState> MeasureAsync(DomainInfo known, ScopeSelection scope, bool inventory, CancellationToken cancellationToken, IReadOnlySet<Guid>? exactTargets = null, IReadOnlyDictionary<Guid, QueryComputerIdentity>? expectedIdentities = null, long? expectedEpoch = null)
    {
        if (probe is null) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Collecteur de postes indisponible : aucun poste contacté."); }
        DirectoryState current; long generation;
        lock (gate)
        {
            current = state ?? Empty(known); generation = epoch;
            if (expectedEpoch is not null && expectedEpoch != generation)
            { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée depuis le plan ; aucun poste contacté."); }
            if (expectedIdentities is not null)
            {
                var actual = current.Directory.Computers.ToDictionary(c => c.ObjectGuid);
                if (expectedIdentities.Any(pair => !actual.TryGetValue(pair.Key, out var computer) || !pair.Value.Matches(computer)
                    || !ScopeRules.Contains(scope, computer.DistinguishedName)))
                { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Population confirmée modifiée ; préparez un nouveau relevé. Aucun poste contacté."); }
            }
        }
        if (current.Directory.Computers.IsDefaultOrEmpty)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Relisez d’abord l’annuaire : aucun poste connu dans l’OU de travail."); }
        var previous = current.Observations.Workstations.ToDictionary(w => w.ComputerGuid);
        var targets = current.Directory.Computers.Where(c => ScopeRules.Contains(scope, c.DistinguishedName) && !AdValues.IsDisabled(c.UserAccountControl)
            && (exactTargets is null || exactTargets.Contains(c.ObjectGuid) && (!inventory || previous.TryGetValue(c.ObjectGuid, out var o) && o.Presence.HasReading && o.Presence.Answered == true))).ToArray();
        var results = new WorkstationObservation?[targets.Length];
        var facts = new System.Collections.Concurrent.ConcurrentDictionary<Guid, MachineFacts>();
        using var limit = new SemaphoreSlim(inventory ? InventoryParallel : PingParallel);
        var tasks = targets.Select(async (computer, index) =>
        {
            await limit.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                if (Epoch != generation) { throw new OperationCanceledException("La session a changé.", cancellationToken); }
                // Ping only needs the selected directory lease; never acquire a machine password for ICMP.
                using var directory = exactTargets is not null
                    ? await AdReadAccess.AcquireAsync(this, CredentialRules.Directory, computer.DistinguishedName, cancellationToken).ConfigureAwait(false) : null;
                async Task ConfirmDirectory()
                {
                    if (directory is null) { return; }
                    var actual = await AdQueryAccess.QualifyAsync(this, directory, computer, cancellationToken).ConfigureAwait(false);
                    if (!QueryComputerIdentity.Of(computer).Matches(actual) || AdValues.IsDisabled(actual.UserAccountControl))
                    { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité ou activation du poste modifiée depuis le plan ; résultat écarté."); }
                    directory.EnsureCurrent();
                    if (Epoch != generation) { throw new OperationCanceledException("La session a changé.", cancellationToken); }
                }
                await ConfirmDirectory().ConfigureAwait(false);
                var host = computer.DnsHostName ?? computer.Name;
                previous.TryGetValue(computer.ObjectGuid, out var before);
                var presence = before?.Presence ?? PresenceMeasure.Unread;
                var measured = before?.Inventory ?? InventoryMeasure.Unread;
                if (!inventory || exactTargets is null && presence.Answered != true)
                {
                    var answered = await probe.PingAsync(host, PingTimeout, cancellationToken).ConfigureAwait(false);
                    var at = Clock.GetUtcNow();
                    presence = new PresenceMeasure(MeasureState.Known, answered, at, answered ? at : presence.LastOnlineAt);
                    if (exactTargets is null) { results[index] = new(computer.ObjectGuid, presence, measured); }
                }
                if (inventory && presence.HasReading && presence.Answered == true)
                {
                    if (probe is ICredentialWorkstationFactsProbe authenticated)
                    {
                        using var access = await AdWorkstationAccess.AcquireAsync(this, host, cancellationToken).ConfigureAwait(false);
                        var read = await (authenticated is IConfiguredWorkstationFactsProbe configured
                            ? configured.ReadFactsAsync(host, InventoryTimeout, cancellationToken, access.Credential, access.Settings)
                            : authenticated.ReadFactsAsync(host, InventoryTimeout, cancellationToken, access.Credential)).ConfigureAwait(false);
                        access.EnsureCurrent();
                        if (read.Inventory.State == MeasureState.Refused) { access.Refused(host, "Inventaire léger", read.AuthenticationRejected); }
                        if (read.ReportedName is null && read.Inventory.State == MeasureState.NotRead)
                        { measured = read.Inventory; facts[computer.ObjectGuid] = read.Facts; }
                        else if (!WorkstationIdentity.Matches(computer, read.ReportedName))
                        {
                            measured = new(MeasureState.Incomplete, Clock.GetUtcNow(), null, null, null, null, null, null, null);
                            facts[computer.ObjectGuid] = new(null, null, null, null, MeasureState.Incomplete, Clock.GetUtcNow(), "Identité CIM non confirmée ; mesures non associées au poste.");
                        }
                        else { measured = read.Inventory; facts[computer.ObjectGuid] = read.Facts; }
                    }
                    else if (probe is IWorkstationFactsProbe detailed)
                    {
                        var read = await detailed.ReadFactsAsync(host, InventoryTimeout, cancellationToken).ConfigureAwait(false);
                        measured = read.Inventory;
                        facts[computer.ObjectGuid] = read.Facts;
                    }
                    else
                    {
                        measured = await probe.ReadInventoryAsync(host, InventoryTimeout, cancellationToken).ConfigureAwait(false);
                        facts[computer.ObjectGuid] = new(null, null, null, null, measured.State, measured.CheckedAt, measured.HasReading ? null : "Inventaire non lu.");
                    }
                }
                await ConfirmDirectory().ConfigureAwait(false);
                results[index] = new(computer.ObjectGuid, presence, measured);
            }
            catch (DomeniaOperationException ex) when (ex.Code is MachineErrors.AccountPaused or AccountAccess.ContextRefused or "machine.busy")
            {
                var at = Clock.GetUtcNow();
                var refused = ex.Code != "machine.busy";
                var status = refused ? MeasureState.Refused : MeasureState.Incomplete;
                var presence = previous.GetValueOrDefault(computer.ObjectGuid)?.Presence ?? PresenceMeasure.Unread;
                results[index] = new(computer.ObjectGuid, presence, new(status, at, null, null, null, null, null, null, null));
                facts[computer.ObjectGuid] = new(null, null, null, null, status, at, refused ? "Compte en pause ou contexte refusé ; aucun essai envoyé." : "Lectures précédentes encore en cours ; aucun essai envoyé.");
            }
            catch
            {
                if (exactTargets is not null) { results[index] = null; facts.TryRemove(computer.ObjectGuid, out _); }
                throw;
            }
            finally { limit.Release(); }
        }).ToArray();
        var interrupted = false;
        try { await Task.WhenAll(tasks).ConfigureAwait(false); }
        catch (OperationCanceledException) { interrupted = true; }
        var completed = results.OfType<WorkstationObservation>().ToImmutableArray();
        if (!completed.IsEmpty)
        {
            var patch = FleetCachePatch.Empty with { Observations = new(Clock.GetUtcNow(), completed), Machines = facts.ToImmutableDictionary() };
            // A cancelled network read must still acknowledge its completed local measurements. SQLite remains bounded.
            await SaveFleetAsync(patch, generation, CancellationToken.None).ConfigureAwait(false);
        }
        lock (gate)
        {
            if (epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "La session a changé pendant le relevé."); }
            var latest = state ?? Empty(known);
            var count = inventory ? facts.Values.Count(f => f.WmiState == MeasureState.Known) : completed.Count(o => o.Presence.Answered == true);
            var label = (inventory ? "Inventaire léger" : "Présence mesurée") + FrenchText.Colon + FrenchText.Integer(count) + " sur " + FrenchText.Integer(completed.Length)
                + " (OU " + scope.Label + ")" + (interrupted ? " · collecte interrompue, relevés terminés conservés." : ".");
            state = latest with { Observations = fleet.Observations, Journal = Add(latest.Journal, label, interrupted ? Tone.Warn : Tone.Info) };
            if (interrupted) { throw new OperationCanceledException(cancellationToken); }
            return state;
        }
    }

    private ImmutableArray<JournalEntry> Add(ImmutableArray<JournalEntry> journal, string label, Tone tone) =>
        [new JournalEntry(Clock.GetUtcNow(), label, tone), .. journal.IsDefault ? [] : journal.Take(199)];

    private DirectoryState Empty(DomainInfo known) =>
        new(new DirectorySnapshot(known, DateTimeOffset.MinValue, false, [], [], [], []), FleetObservations.Empty, [], []);
}
