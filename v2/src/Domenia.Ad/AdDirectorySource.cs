using System.Collections.Immutable;
using System.Security.Principal;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using Domenia.Core.Poste;

namespace Domenia.Ad;

/// <summary>
/// The directory source of the directory mode (Active Directory of the domain of the computer, Windows session). Nothing is read
/// in the constructor or in local session reads. The first explicit network operation connects once (RootDSE, domain object,
/// account of the session: bounded, never retried in a loop). The directory picture is read on an explicit
/// request (« Actualiser » of the home page): users, groups, OUs and computers of the selected branch, paged, 100 000 per kind at most;
/// workstation measures (presence, light inventory) only on the working OU, never on the domain root. Read only by
/// construction: the write executors of Domenia.Ad are the only writers, through <see cref="Connection"/>.
/// </summary>
public sealed partial class AdDirectorySource : IDirectorySource, IDirectoryRefreshPreparation, IAccountContextSource, ILocalSessionSnapshotSource, IDirectoryWriteLeaseSource, IDisposable
{
    public const int MaxObjectsPerKind = 100_000;

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
            if (localMaintenanceRequested || localMaintenance) { throw WriteErrors.Refusal(WriteErrors.Stale, "Maintenance locale en cours ; préparez un nouveau plan après sa fin."); }
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
            if (account is { } identity && !string.Equals(identity.Login, expectedAccount, StringComparison.OrdinalIgnoreCase))
            { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Identité de transport différente du compte choisi."); }
            return connection is AdConnection actual ? actual.CopyCredential() : SessionCredentialCopy?.Invoke()
                ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Compte du transport natif indisponible.");
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
        using var cleanup = CommitConnectionAdoption(candidate, known, identity, expectedEpoch, correction);
    }

    /// <summary>Memory-only commit. The returned retirement owns old resources and must be disposed outside caller locks.</summary>
    internal IDisposable CommitConnectionAdoption(IAdConnection candidate, DomainInfo known, AdSessionIdentity identity, long expectedEpoch, bool correction)
    {
        IAdConnection previous;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (connectionRetirements.Count >= 4) throw new DomeniaOperationException(AdErrors.Timeout, "Le nettoyage de connexions précédentes reste non confirmé ; aucune nouvelle session adoptée.");
            if (writeLeases != 0) { throw new DomeniaOperationException(AccountAccess.WritePending, "Une écriture est en cours ; la connexion actuelle est conservée."); }
            if (epoch != expectedEpoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée pendant la validation : connexion écartée."); }
            var before = domain ?? state?.Directory.Domain;
            if (before is not null && (!DistinguishedName.AreEqual(before.RootDn, known.RootDn) || before.DomainSid != known.DomainSid)
                || before is null && joinedDomain is not null && !joinedDomain.Equals(known.DnsName, StringComparison.OrdinalIgnoreCase)
                || identity.Sid is null || identity.Identity.Dn is null
                || correction && (accountSid is null || accountSid != identity.Sid))
            { throw new DomeniaOperationException(AccountAccess.ContextRefused, "Domaine ou identité de connexion non confirmé : session conservée."); }
            previous = connection;
            connection = candidate;
            connectionLogin = identity.Identity.Login;
            domain = known;
            account = identity.Identity;
            accountSid = identity.Sid;
            rights = identity.Rights;
            administration = identity.Administration;
            ClearAdministrationProofs();
            SetConnectionPrincipal(identity);
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
            var cleanup = new ConnectionRetirement(this, ReferenceEquals(previous, candidate) ? null : previous, AdSyncState.Detach(this));
            connectionRetirements.Add(cleanup);
            return cleanup;
        }
    }

    public TimeProvider Clock { get; }

    public IDirectoryCache? LocalStore { get; }

    internal string? SessionSid { get { lock (gate) { return accountSid; } } }
    internal DateTimeOffset? SessionStartedAt { get { lock (gate) { return sessionStartedAt; } } }

    public bool CanPrepareDirectoryRefresh => LocalStore is IPreparedDirectoryCache;

    public async Task<DirectoryBackupReceipt> PrepareDirectoryRefreshAsync(CancellationToken cancellationToken)
    {
        await EnsureCollectionStorageAsync(cancellationToken).ConfigureAwait(false);
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
            var request = OperationRequests.CurrentRequest?.Reference ?? Guid.NewGuid().ToString("N");
            var identity = new CollectionWriteContext(request, before.Facts.StoreId, KnownDomain?.RootDn ?? "", generation);
            if (patch.CollectionContext is not null && patch.CollectionContext != identity)
                throw new InvalidDataException("Le relevé appartient à une autre requête de collecte.");
            using var admission = CollectionWrites.Enter(identity, () => Epoch == generation && FleetDetails.Facts.StoreId == identity.StoreId);
            var qualified = patch with { CollectionContext = identity };
            var saved = LocalStore is IAccueilCache cache ? await cache.SaveFleetAsync(qualified, token).ConfigureAwait(false) : before.Merge(qualified);
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

    /// <summary>One atomic origin for explicit navigation reads, after DomainAsync has connected.</summary>
    internal (DomainInfo Domain, long Epoch, IAdConnection Connection) CaptureTreeRead()
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            return (domain ?? throw new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage), epoch, connection);
        }
    }


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

    public SessionSnapshot? PeekSession() { lock (gate) { return disposed ? null : SessionSnapshotLocked(); } }

    public async Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken)
    {
        var generation = Epoch;
        try { await LoadLocalAsync(cancellationToken).ConfigureAwait(false); }
        catch (IOException) when (LocalStore is ILocalStoreInspection)
        {
            // Session identity is needed to confirm a restore even when the cache cannot be loaded. Only a proven
            // SQLite corruption qualifies; arbitrary I/O failures and unsupported schemas still escape. Other cache
            // consumers keep failing, localLoaded stays false, and no empty cache is published as a successful read.
            var inspection = await ((ILocalStoreInspection)LocalStore).InspectLocalStoreAsync(false, true, cancellationToken).ConfigureAwait(false);
            if (!inspection.Available || !inspection.Maintenance.Recovery) { throw; }
            lock (gate)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                if (epoch != generation) { throw; }
                return SessionSnapshotLocked() with { Store = new(null, 0, false) };
            }
        }
        lock (gate) { return SessionSnapshotLocked(); }
    }

    // Call only under gate. Local maintenance must validate the source without waiting on its own loading semaphore.
    private SessionSnapshot SessionSnapshotLocked()
    {
        var directory = state?.Directory;
        var store = directory is null ? new StoreStatus(null, 0, false) : new StoreStatus(directory.ReadAt == DateTimeOffset.MinValue ? null : directory.ReadAt, directory.ObjectCount, directory.Complete);
        var explicitLogin = connectionLogin;
        var login = account?.Login ?? explicitLogin ?? accountLogin();
        var authentication = explicitLogin is null
            ? new AuthenticationInfo(AuthenticationMethod.WindowsSession, null, domain is null ? "Session Windows" : "Session Windows (négociation, signée et chiffrée)")
            : new AuthenticationInfo(AuthenticationMethod.ExplicitCredentials, null, domain is null ? "Compte explicite" : "Compte explicite (négociation, signée et chiffrée)");
        if (domain is null)
        {
            return new SessionSnapshot(
                ConnectionState.Disconnected,
                directory is not null ? new DomainIdentity(string.IsNullOrWhiteSpace(directory.Domain.DnsName) ? joinedDomain : directory.Domain.DnsName,
                    directory.Domain.NetbiosName, directory.Domain.RootDn) : joinedDomain is null ? null : new DomainIdentity(joinedDomain, null, null),
                null,
                account ?? new AccountIdentity(login, null, null, null),
                authentication,
                null,
                new RightsInfo(RightsLevel.Unknown, SessionTexts.RightsLabel(RightsLevel.Unknown), true, failure ?? "Droits évalués à la connexion à l’annuaire."),
                true,
                store,
                epoch) { Administration = AdministrationOverride ?? AdministrationIdentity.Unknown, StoreId = fleet.Facts.StoreId is { Length: 64 } id ? id : null,
                    DirectoryAvailability = (connection as IAdReachability)?.Availability ?? DirectoryAvailabilitySnapshot.Unknown };
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
            true,
            store,
            epoch) { Administration = AdministrationOverride ?? administration, StoreId = fleet.Facts.StoreId is { Length: 64 } storeId ? storeId : null,
                DirectoryAvailability = (connection as IAdReachability)?.Availability ?? DirectoryAvailabilitySnapshot.Unknown };
    }

    internal void ValidateSyncOrigin(WritePlanOrigin origin)
    {
        ArgumentNullException.ThrowIfNull(origin);
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (localMaintenanceRequested || localMaintenance || !origin.Matches(SessionSnapshotLocked()))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée depuis l’aperçu ; aucune publication autorisée."); }
        }
    }

    public async Task<SessionSnapshot> ConnectAsync(CancellationToken cancellationToken)
    {
        await EnsureConnectedAsync(retry: true, cancellationToken).ConfigureAwait(false);
        return await GetSessionAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken)
    {
        using var phase = OperationPhases.Measure(OperationPhase.LocalRead);
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
            var accounts = LocalStore is IDomainAccountCache accountCache ? await accountCache.ReadDomainAccountsAsync(token).ConfigureAwait(false) : null;
            var readings = LocalStore is IAccueilCache cache ? await cache.ReadFleetAsync(token).ConfigureAwait(false) : CachedFleet.Empty("session");
            lock (gate)
            {
                if (epoch != generation) { return; }
                fleet = readings;
                if (loaded is not null && (state is null || reloadDirectoryAtEpoch == generation))
                {
                    state = (state ?? Empty(domain ?? loaded.Domain)) with { Directory = domain is null ? loaded : loaded with { Domain = domain },
                        DirectoryCommit = null, Observations = readings.Observations };
                }
                reloadDirectoryAtEpoch = null;
                if (accounts is not null)
                {
                    var known = domain ?? loaded?.Domain ?? accounts.Domain;
                    if (!DistinguishedName.AreEqual(known.RootDn, accounts.Domain.RootDn))
                    { throw new InvalidDataException("Compteurs d’un autre domaine."); }
                    state = (state ?? Empty(known)) with { DomainAccounts = accounts };
                }
                localLoaded = true;
            }
        }
        finally { loadingLocal.Release(); }
    }

    /// <summary>Publishes a point read only after its durable acknowledgement; shares the refresh lock with census reads.</summary>
    internal async Task<DirectorySnapshot> RememberObjectsAsync(DirectorySnapshot objects, long generation, CancellationToken token)
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
                return saved;
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
        await EnsureCollectionStorageAsync(cancellationToken).ConfigureAwait(false);
        if (family == MeasureFamily.DomainAccounts)
        {
            return await RefreshDomainAccountsAsync(cancellationToken).ConfigureAwait(false);
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
                        string readLogin;
                        lock (gate) { readLogin = account?.Login ?? connectionLogin ?? accountLogin(); }
                        var (snapshot, committed) = await ReadStoredDirectoryAsync(known, scope, generation, readLogin, cancellationToken).ConfigureAwait(false);
                        await savingFleet.WaitAsync(cancellationToken).ConfigureAwait(false);
                        try
                        {
                            // The directory transaction can invalidate measurements of recreated/rebound computer identities.
                            // Adopt that committed projection before deciding which workstation data can be reused.
                            var refreshedFleet = LocalStore is IAccueilCache fleetCache
                                ? await fleetCache.ReadFleetAsync(cancellationToken).ConfigureAwait(false) : null;
                            lock (gate)
                            {
                                if (epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "La session a changé avant la publication du relevé."); }
                                var current = state ?? Empty(known);
                                if (refreshedFleet is not null) { fleet = refreshedFleet; }
                                state = current with
                                {
                                    Directory = snapshot,
                                    Observations = fleet.Observations,
                                    DirectoryCommit = committed,
                                    Journal = Add(current.Journal, "Annuaire relu" + FrenchText.Colon + FrenchText.Count(snapshot.ObjectCount, "objet", "objets") + (snapshot.Complete ? "" : " (limite atteinte, lecture incomplète)") + ".", snapshot.Complete ? Tone.Info : Tone.Warn),
                                };
                                return state;
                            }
                        }
                        finally { savingFleet.Release(); }
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
            ClearAdministrationProofs(rotate: false);
            epoch++;
        }
        AdSyncState.Release(this);
        Connection.Dispose();
        DrainConnectionRetirements();
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
            administration = AdministrationIdentity.Unknown;
            ClearAdministrationProofs();
            failure = null;
            failedAt = null;
            state = null;
            localLoaded = false;
            fleet = CachedFleet.Empty("session");
            epoch++;
        }
        AdSyncState.Release(this);
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
        if (!IsExplicitSession) WindowsSessionChoice.RequireAvailable();
        using (AuthenticationTrace.Step(AuthenticationStage.SessionQueue))
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
                cancellationToken.ThrowIfCancellationRequested();
                lock (gate)
                {
                    if (epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la connexion : résultat écarté."); }
                    domain = read;
                    account = resolved.Identity;
                    accountSid = resolved.Sid;
                    rights = resolved.Rights;
                    administration = resolved.Administration;
                    ClearAdministrationProofs();
                    SetConnectionPrincipal(resolved);
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
        if (explicitLogin is null && DesktopSidOverride is { } desktopSid)
        {
            sid = desktopSid();
        }
        else if (explicitLogin is null)
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

    /// <summary>Completed presence readings are committed in bounded batches, including when another target fails or is cancelled.</summary>
    private async Task<DirectoryState> MeasureAsync(DomainInfo known, ScopeSelection scope, bool inventory, CancellationToken cancellationToken, IReadOnlySet<Guid>? exactTargets = null, IReadOnlyDictionary<Guid, QueryComputerIdentity>? expectedIdentities = null, long? expectedEpoch = null)
    {
        if (probe is null) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Collecteur de postes indisponible : aucun poste contacté."); }
        using var stopWork = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cancellationToken = stopWork.Token;
        DirectoryState current; long generation;
        lock (gate)
        {
            current = state ?? Empty(known); generation = epoch;
            if (expectedEpoch is not null && expectedEpoch != generation)
            { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée depuis le plan ; aucun poste contacté."); }
            if (expectedIdentities is not null)
            {
                var actual = AdComputerIndex.For(current.Directory);
                if (expectedIdentities.Any(pair => actual.Find(pair.Key) is not { } computer || !pair.Value.Matches(computer)
                    || !ScopeRules.Contains(scope, computer.DistinguishedName)))
                { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Population confirmée modifiée ; préparez un nouveau relevé. Aucun poste contacté."); }
            }
        }
        if (current.Directory.Computers.IsDefaultOrEmpty)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Relisez d’abord l’annuaire : aucun poste connu dans l’OU de travail."); }
        var allowUnanswered = CollectionNetworkPolicy.Read(AccountContext?.Preferences);
        var retryPolicy = CollectionRetryPolicy.Read(AccountContext?.Preferences);
        var measuredSince = Clock.GetUtcNow();
        var candidates = exactTargets is null ? current.Directory.Computers.AsEnumerable()
            : exactTargets.Select(AdComputerIndex.For(current.Directory).Find).OfType<DirectoryComputer>();
        var targets = CampaignBranches.Order(candidates.Where(c => ScopeRules.Contains(scope, c.DistinguishedName) && !AdValues.IsDisabled(c.UserAccountControl)
            && (exactTargets is null || !inventory || current.Observations.Find(c.ObjectGuid) is { } o && CollectionNetworkPolicy.Eligible(o.Presence, allowUnanswered)))).ToArray();
        // ICMP and DNS carry no credential: presence never asks for workstation administration (David, 09/11/2026).
        if (inventory && targets.Length > 0)
        { await AdWorkstationAccess.RequireNetworkIdentityAsync(this, targets[0].DnsHostName ?? targets[0].Name, cancellationToken, readOnly: true).ConfigureAwait(false); }
        var remoteSettings = await RemoteCollectionSettings.EffectiveAsync(AccountContext, cancellationToken).ConfigureAwait(false);
        using var transientScope = inventory ? TransientReadAuthorization.Begin(remoteSettings, targets.Select(c => c.ObjectGuid)) : null;
        var results = new WorkstationObservation?[targets.Length];
        var notAdmitted = 0;
        var stoppedReadings = 0;
        var facts = new System.Collections.Concurrent.ConcurrentDictionary<Guid, MachineFacts>();
        var pendingMeasures = new System.Collections.Concurrent.ConcurrentQueue<WorkstationObservation>();
        using var flushing = new SemaphoreSlim(1, 1);
        using var committing = new SemaphoreSlim(1, 1);
        System.Runtime.ExceptionServices.ExceptionDispatchInfo? writeFailure = null;
        var lastSave = Clock.GetTimestamp();
        async Task CommitAsync(FleetCachePatch patch)
        {
            await committing.WaitAsync(CancellationToken.None).ConfigureAwait(false);
            try
            {
                writeFailure?.Throw();
                try { await SaveFleetAsync(patch, generation, CancellationToken.None).ConfigureAwait(false); }
                catch (Exception ex)
                {
                    // One storage failure closes admission; never turn a full disk into thousands of automatic retries.
                    writeFailure = System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(ex);
                    await stopWork.CancelAsync().ConfigureAwait(false);
                    throw;
                }
            }
            finally { committing.Release(); }
        }
        async Task FlushAsync(bool final = false)
        {
            if (pendingMeasures.IsEmpty) { return; }
            await flushing.WaitAsync(CancellationToken.None).ConfigureAwait(false);
            try
            {
                writeFailure?.Throw();
                if (!final && pendingMeasures.Count < 32 && Clock.GetElapsedTime(lastSave) < TimeSpan.FromSeconds(inventory ? 5 : 2)) { return; }
                var batch = ImmutableArray.CreateBuilder<WorkstationObservation>();
                while (pendingMeasures.TryDequeue(out var row)) { batch.Add(row); }
                if (batch.Count == 0) { return; }
                var ids = batch.Select(o => o.ComputerGuid).ToHashSet();
                await CommitAsync(FleetCachePatch.Empty with
                {
                    Observations = new(Clock.GetUtcNow(), batch.ToImmutable()),
                    Machines = inventory ? ids.Where(facts.ContainsKey).ToImmutableDictionary(id => id, id => facts[id]) : ImmutableDictionary<Guid, MachineFacts>.Empty,
                }).ConfigureAwait(false);
                lastSave = Clock.GetTimestamp();
            }
            finally { flushing.Release(); }
        }
        var parallel = inventory ? Math.Min(InventoryParallel, CollectionSettingsRules.Read(AccountContext?.Preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var collectionSettings) == true
            ? collectionSettings : null, []).Budgets.GetValueOrDefault(CollectionSettingsRules.Concurrency, 4)) : PingParallel;
        using var limit = new SemaphoreSlim(parallel);
        // A small worker window permits retry backoff without creating one suspended task per directory object.
        var work = Parallel.ForEachAsync(targets.Select((computer, index) => (computer, index)), new ParallelOptions
        { MaxDegreeOfParallelism = inventory ? parallel * 4 : parallel, CancellationToken = cancellationToken }, async (target, workerToken) =>
        {
            var (computer, index) = target;
            await limit.WaitAsync(cancellationToken).ConfigureAwait(false);
            var ownsSlot = true;
            var stoppedBeforeQualification = false;
            var inventoryQualified = false;
            try
            {
                if (Epoch != generation) { throw new OperationCanceledException("La session a changé.", cancellationToken); }
                var host = computer.DnsHostName ?? computer.Name;
                if (inventory) { await AdWorkstationAccess.RequireNetworkIdentityAsync(this, host, cancellationToken, readOnly: true).ConfigureAwait(false); }
                var before = current.Observations.Find(computer.ObjectGuid);
                var presence = before?.Presence ?? PresenceMeasure.Unread;
                var measured = before?.Inventory ?? InventoryMeasure.Unread;
                // Keep one admitted pair for every native retry. The local preview admits the single one-shot
                // first; neither resource is selected again when a read is resumed.
                using var retainedAccess = exactTargets is not null && inventory && CollectionNetworkPolicy.Eligible(presence, allowUnanswered)
                    && probe is ICredentialWorkstationFactsProbe
                    ? await AdWorkstationReadAccess.AcquireAsync(this, host, computer.DistinguishedName, cancellationToken).ConfigureAwait(false) : null;
                // Ping only needs the selected directory lease; never acquire a machine password for ICMP.
                using var ownedDirectory = exactTargets is not null && retainedAccess is null
                    ? await AdReadAccess.AcquireAsync(this, CredentialRules.Directory, computer.DistinguishedName, cancellationToken).ConfigureAwait(false) : null;
                var directory = retainedAccess?.Directory ?? ownedDirectory;
                async Task ConfirmDirectory(CancellationToken currentToken)
                {
                    if (directory is null) { return; }
                    var actual = await AdQueryAccess.QualifyAsync(this, directory, computer, currentToken).ConfigureAwait(false);
                    if (!QueryComputerIdentity.Of(computer).Matches(actual) || AdValues.IsDisabled(actual.UserAccountControl))
                    { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité ou activation du poste modifiée depuis le plan ; résultat écarté."); }
                    directory.EnsureCurrent();
                    if (Epoch != generation) { throw new OperationCanceledException("La session a changé.", cancellationToken); }
                }
                await ConfirmDirectory(cancellationToken).ConfigureAwait(false);
                if (!inventory || exactTargets is null && presence.Answered != true)
                {
                    if (probe is IWorkstationPresenceProbe qualified)
                        presence = await qualified.ReadPresenceAsync(host, PingTimeout, presence.LastOnlineAt, cancellationToken).ConfigureAwait(false);
                    else
                    {
                        // Compatibility for older/custom probes. Production supplies the qualified contract above.
                        var answered = await probe.PingAsync(host, PingTimeout, cancellationToken).ConfigureAwait(false);
                        var at = Clock.GetUtcNow();
                        presence = new PresenceMeasure(MeasureState.Known, answered, at, answered ? at : presence.LastOnlineAt);
                    }
                    if (exactTargets is null) { results[index] = new(computer.ObjectGuid, presence, measured); }
                }
                if (inventory && CollectionNetworkPolicy.Eligible(presence, allowUnanswered))
                {
                    if (probe is ICredentialWorkstationFactsProbe authenticated)
                    {
                        using var ownedMachine = retainedAccess is null ? await AdWorkstationAccess.AcquireAsync(this, host, cancellationToken, readOnly: true).ConfigureAwait(false) : null;
                        var access = retainedAccess?.Machine ?? ownedMachine!;
                        var read = await new CollectionReadRetry(Clock, retryPolicy).RunAsync(async token =>
                        {
                            if (!ownsSlot) { await limit.WaitAsync(token).ConfigureAwait(false); ownsSlot = true; }
                            await access.BeforeContactAsync(this, host, token).ConfigureAwait(false);
                            await ConfirmDirectory(token).ConfigureAwait(false);
                            await access.BeforeContactAsync(this, host, token).ConfigureAwait(false);
                            var value = await (authenticated is IConfiguredWorkstationFactsProbe configured
                                ? configured.ReadFactsAsync(host, InventoryTimeout, token, access.Credential, access.Settings, retainPartialOnCancellation: true)
                                : authenticated.ReadFactsAsync(host, InventoryTimeout, token, access.Credential)).ConfigureAwait(false);
                            access.EnsureCurrent();
                            if (value.Inventory.State == MeasureState.Refused || value.AuthenticationRejected)
                                access.Refused(host, "Inventaire léger", value.AuthenticationRejected);
                            try
                            {
                                token.ThrowIfCancellationRequested();
                                await ConfirmDirectory(token).ConfigureAwait(false);
                            }
                            catch (OperationCanceledException) when (token.IsCancellationRequested)
                            {
                                // The native task has physically ended. Retain its received values without a new
                                // LDAP request, but do not claim a complete or qualified console/BIOS observation.
                                stoppedBeforeQualification = true;
                                directory?.EnsureCurrent(); access.EnsureCurrent();
                                if (CurrentDirectory is not { } latest || !latest.Computers.Any(c => c.ObjectGuid == computer.ObjectGuid
                                    && QueryComputerIdentity.Of(computer).Matches(c)))
                                    throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité locale modifiée pendant l’arrêt ; résultats écartés.");
                                value = value with
                                {
                                    Inventory = value.Inventory with { State = MeasureState.Incomplete },
                                    Facts = value.Facts with { ConsoleUser = null, ConsoleAt = null, BiosAt = null,
                                        WmiState = MeasureState.Incomplete, WmiError = "Lecture arrêtée ; mesures partielles conservées sans qualification AD finale." },
                                    RetryFailure = CollectionReadFailure.Cancelled,
                                };
                            }
                            return value;
                        }, value => new(value.AuthenticationRejected ? CollectionReadFailure.CredentialRejected
                            : value.Inventory.State == MeasureState.Refused ? CollectionReadFailure.AccessDenied : value.RetryFailure,
                            value.ReadPhysicallyCompleted,
                            RecentPresence(presence) && (value.ReportedName is null || WorkstationIdentity.Matches(computer, value.ReportedName, value.HostIdentity))),
                            () => { access.EnsureCurrent(); directory?.EnsureCurrent(); }, TimeSpan.FromSeconds(45), cancellationToken,
                            acknowledge: async value =>
                            {
                                // Persist only values whose native identity was qualified. Failure metadata may be
                                // retained without assigning data returned by an unidentified machine to this GUID.
                                var identified = WorkstationIdentity.Matches(computer, value.ReportedName, value.HostIdentity);
                                var observed = identified ? value.Inventory : new InventoryMeasure(MeasureState.Incomplete, Clock.GetUtcNow(), null, null, null, null, null, null, null);
                                var machine = identified ? value.Facts : new MachineFacts(null, null, null, null, MeasureState.Incomplete, Clock.GetUtcNow(), "Lecture incomplète ; identité CIM non confirmée.");
                                await CommitAsync(FleetCachePatch.Empty with
                                {
                                    Observations = new(Clock.GetUtcNow(), [new(computer.ObjectGuid, presence, observed)]),
                                    Machines = ImmutableDictionary<Guid, MachineFacts>.Empty.Add(computer.ObjectGuid, machine),
                                }).ConfigureAwait(false);
                            }, onRetry: decision =>
                            {
                                // Backoff owns no native worker and must not hold one of the six campaign admissions.
                                if (ownsSlot) { limit.Release(); ownsSlot = false; }
                                AccountContext?.Log.Info(decision.Reason);
                            }).ConfigureAwait(false);
                        access.EnsureCurrent();
                        if (!stoppedBeforeQualification && read.ReadPhysicallyCompleted && !read.AuthenticationRejected
                            && read.Inventory.State is not MeasureState.Known and not MeasureState.NotRead
                            && (read.ReportedName is null || WorkstationIdentity.Matches(computer, read.ReportedName, read.HostIdentity))
                            && TransientReadAuthorization.Covers(access.Settings, computer.ObjectGuid))
                        {
                            var fallback = await new AdPosteReader(this).ReadCampaignFallbackAsync(computer, access, cancellationToken).ConfigureAwait(false);
                            if (fallback is not null) { read = CampaignInventoryMerge.Combine(computer, read, fallback); }
                        }
                        inventoryQualified = !stoppedBeforeQualification;
                        if (read.ReportedName is null && read.Inventory.State == MeasureState.NotRead)
                        { measured = read.Inventory; facts[computer.ObjectGuid] = read.Facts; }
                        else if (!WorkstationIdentity.Matches(computer, read.ReportedName, read.HostIdentity))
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
                else if (inventory)
                {
                    // No inventory was sent: preserve its existing payload and date, even when old. The separate
                    // attempt metadata explains the failed prerequisite without manufacturing a fresh inventory.
                    var at = Clock.GetUtcNow();
                    facts[computer.ObjectGuid] = new(null, null, null, null, MeasureState.NotRead, at,
                        "Inventaire non envoyé : " + (presence.Diagnostic?.Text ?? "présence du poste non confirmée."));
                }
                if (stoppedBeforeQualification)
                {
                    results[index] = new(computer.ObjectGuid, presence, measured);
                    Interlocked.Increment(ref stoppedReadings);
                    return;
                }
                if (!inventoryQualified) { await ConfirmDirectory(cancellationToken).ConfigureAwait(false); }
                results[index] = new(computer.ObjectGuid, presence, measured);
            }
            catch (DomeniaOperationException ex) when (ex.Code is MachineErrors.AccountPaused or AccountAccess.ContextRefused or "machine.busy" or "operation.physicalBusy" or "operation.siteBusy")
            {
                var at = Clock.GetUtcNow();
                var before = current.Observations.Find(computer.ObjectGuid);
                if (ex.Code is "operation.physicalBusy" or "operation.siteBusy")
                {
                    Interlocked.Increment(ref notAdmitted);
                    // No admission is neither an offline observation nor a failed inventory that was never requested.
                    var presence = inventory ? before?.Presence ?? PresenceMeasure.Unread
                        : new PresenceMeasure(MeasureState.Incomplete, null, at, before?.Presence.LastOnlineAt);
                    var measured = inventory ? new InventoryMeasure(MeasureState.Incomplete, at, null, null, null, null, null, null, null)
                        : before?.Inventory ?? InventoryMeasure.Unread;
                    results[index] = new(computer.ObjectGuid, presence, measured);
                    if (inventory) facts[computer.ObjectGuid] = new(null, null, null, null, MeasureState.Incomplete, at, ex.Message);
                }
                else
                {
                    var refused = ex.Code is MachineErrors.AccountPaused or AccountAccess.ContextRefused;
                    var status = refused ? MeasureState.Refused : MeasureState.Incomplete;
                    results[index] = new(computer.ObjectGuid, before?.Presence ?? PresenceMeasure.Unread, new(status, at, null, null, null, null, null, null, null));
                    facts[computer.ObjectGuid] = new(null, null, null, null, status, at, refused ? "Compte en pause ou contexte refusé ; aucun essai envoyé." : ex.Message);
                }
            }
            catch
            {
                if (exactTargets is not null) { results[index] = null; facts.TryRemove(computer.ObjectGuid, out _); }
                throw;
            }
            finally
            {
                try
                {
                    if (results[index] is { } completedMeasure)
                    {
                        pendingMeasures.Enqueue(completedMeasure);
                        await FlushAsync().ConfigureAwait(false);
                    }
                }
                finally { if (ownsSlot) limit.Release(); }
            }
        });
        var interrupted = false;
        System.Runtime.ExceptionServices.ExceptionDispatchInfo? failure = null;
        try { await work.ConfigureAwait(false); }
        catch (OperationCanceledException) { interrupted = true; }
        catch (Exception ex) { failure = System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(ex); }
        interrupted |= stoppedReadings > 0 || cancellationToken.IsCancellationRequested;
        var completed = results.OfType<WorkstationObservation>().ToImmutableArray();
        // A cancelled or failed network read still acknowledges its qualified neighbours. A failed writer is never retried.
        if (writeFailure is null) { await FlushAsync(final: true).ConfigureAwait(false); }
        else { failure = writeFailure; }
        lock (gate)
        {
            if (epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "La session a changé pendant le relevé."); }
            var latest = state ?? Empty(known);
            var count = inventory ? facts.Values.Count(f => f.WmiState == MeasureState.Known) : completed.Count(o => o.Presence.Answered == true);
            // A definitive answer of this pass about a name (PresenceOutcomes) is named, never counted as an unconfirmed reading.
            var definitive = inventory ? "" : PresenceOutcomes.DefinitiveText(completed.Select(o => o.Presence), measuredSince);
            var unconfirmed = inventory ? facts.Values.Count(f => f.WmiState != MeasureState.Known)
                : completed.Count(o => !o.Presence.HasReading && !PresenceOutcomes.Definitive(o.Presence, measuredSince));
            var label = (inventory ? "Inventaire léger" : "Présence mesurée") + FrenchText.Colon + FrenchText.Integer(count) + " sur " + FrenchText.Integer(completed.Length)
                + " (OU " + scope.Label + ")" + (interrupted ? " · collecte interrompue, relevés terminés conservés." : ".")
                + (failure is not null ? " Collecte partiellement échouée ; relevés terminés conservés." : "")
                + (definitive.Length > 0 ? " " + definitive + FrenchText.Colon + "aucun test ICMP envoyé, présence inconnue." : "")
                + (unconfirmed > 0 ? " " + FrenchText.Count(unconfirmed, "lecture non confirmée" + FrenchText.Nbsp + "; consultez son diagnostic.",
                    "lectures non confirmées" + FrenchText.Nbsp + "; consultez leur diagnostic.") : "")
                + (notAdmitted > 0 ? " · " + FrenchText.Integer(notAdmitted) + " lectures non envoyées : budgets occupés ou suspendus." : "");
            state = latest with { Observations = fleet.Observations, Journal = Add(latest.Journal, label, failure is not null || interrupted || notAdmitted > 0 || unconfirmed > 0 ? Tone.Warn : Tone.Info) };
            failure?.Throw();
            if (interrupted) { throw new OperationCanceledException(cancellationToken); }
            return state;
        }
    }

    private ImmutableArray<JournalEntry> Add(ImmutableArray<JournalEntry> journal, string label, Tone tone) =>
        [new JournalEntry(Clock.GetUtcNow(), label, tone), .. journal.IsDefault ? [] : journal.Take(199)];

    internal bool RecentPresence(PresenceMeasure presence) => presence is { HasReading: true, Answered: true, CheckedAt: { } at }
        && Clock.GetUtcNow() >= at && Clock.GetUtcNow() - at <= CollectionReadRetry.MaximumDuration;

    private DirectoryState Empty(DomainInfo known) =>
        new(new DirectorySnapshot(known, DateTimeOffset.MinValue, false, [], [], [], []), FleetObservations.Empty, [], []);
}
