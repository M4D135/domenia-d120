using System.Collections.Immutable;
using System.Security.Principal;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Ad;

/// <summary>
/// The directory source of the directory mode (Active Directory of the domain of the computer, Windows session). Nothing is read
/// in the constructor or in local session reads. The first explicit network operation connects once (RootDSE, domain object,
/// account of the session: bounded, never retried in a loop). The directory picture is read on an explicit
/// request (« Actualiser » of the home page): users, groups, OUs and computers of the selected branch, paged, 50 000 per kind at most;
/// workstation measures (presence, light inventory) only on the working OU, never on the domain root. Read only by
/// construction: the write executors of Domenia.Ad are the only writers, through <see cref="Connection"/>.
/// </summary>
public sealed class AdDirectorySource : IDirectorySource, IDirectoryRefreshPreparation, IDisposable
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
    private RightsInfo? rights;
    private string? failure;
    private string failureCode = AdErrors.NotConnected;
    private DateTimeOffset? failedAt;
    private DirectoryState? state;
    private long epoch;

    public AdDirectorySource(string? joinedDomain, Func<string> accountLogin, TimeProvider clock, IWorkstationProbe? probe = null, IAdConnection? connection = null, IDirectoryCache? localStore = null)
    {
        ArgumentNullException.ThrowIfNull(accountLogin);
        ArgumentNullException.ThrowIfNull(clock);
        this.joinedDomain = joinedDomain;
        this.accountLogin = accountLogin;
        this.probe = probe;
        Clock = clock;
        LocalStore = localStore;
        Connection = connection ?? AdConnectionFactory.Create(new AdConnectionOptions(null, joinedDomain));
    }

    public DirectorySourceKind Kind => DirectorySourceKind.ActiveDirectory;

    /// <summary>The LDAP connection of the session (opened on first use).</summary>
    public IAdConnection Connection { get; }

    public TimeProvider Clock { get; }

    public IDirectoryCache? LocalStore { get; }

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
            var login = account?.Login ?? accountLogin();
            if (domain is null)
            {
                return new SessionSnapshot(
                    ConnectionState.Disconnected,
                    directory is not null ? new DomainIdentity(directory.Domain.DnsName, directory.Domain.NetbiosName, directory.Domain.RootDn) : joinedDomain is null ? null : new DomainIdentity(joinedDomain, null, null),
                    null,
                    account ?? new AccountIdentity(login, null, null, null),
                    new AuthenticationInfo(AuthenticationMethod.WindowsSession, null, "Session Windows"),
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
                new AuthenticationInfo(AuthenticationMethod.WindowsSession, AuthenticationProtocol.Kerberos, "Session Windows (Kerberos, signée et chiffrée)"),
                null,
                rights ?? new RightsInfo(RightsLevel.Unknown, SessionTexts.RightsLabel(RightsLevel.Unknown), true, "Droits déduits des groupes à la connexion."),
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
            domain = null;
            account = null;
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
            try
            {
                var read = await AdDirectoryReader.ReadDomainAsync(Connection, cancellationToken).ConfigureAwait(false);
                var (identity, level) = await ReadAccountAsync(read, cancellationToken).ConfigureAwait(false);
                lock (gate)
                {
                    domain = read;
                    account = identity;
                    rights = level;
                    failure = null;
                    failedAt = null;
                    epoch++;
                }
            }
            catch (DomeniaOperationException ex)
            {
                lock (gate)
                {
                    failure = ex.Message;
                    failureCode = ex.Code;
                    failedAt = Clock.GetUtcNow();
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
    private async Task<(AccountIdentity Identity, RightsInfo Rights)> ReadAccountAsync(DomainInfo known, CancellationToken cancellationToken)
    {
        var login = accountLogin();
        string? sid;
        using (var identity = WindowsIdentity.GetCurrent())
        {
            sid = identity.User?.Value;
        }
        if (sid is null)
        {
            return (new AccountIdentity(login, null, null, null), new RightsInfo(RightsLevel.Unknown, SessionTexts.RightsLabel(RightsLevel.Unknown), true, "Compte de la session sans SID lisible."));
        }
        var found = await Connection.SearchAsync(new AdSearchRequest(known.RootDn, "(objectSid=" + sid + ")", AdSearchScope.Subtree, ["displayName", "givenName", "distinguishedName", "adminCount", "memberOf"]) { SizeLimit = 1 }, cancellationToken).ConfigureAwait(false);
        if (found.Count == 0)
        {
            return (new AccountIdentity(login, null, null, null), new RightsInfo(RightsLevel.Unknown, SessionTexts.RightsLabel(RightsLevel.Unknown), true, "Compte de la session absent de ce domaine (compte local ou d’un autre domaine)."));
        }
        var entry = found[0];
        var groups = entry.Strings("memberOf");
        var admin = entry.Int("adminCount") == 1
            || groups.Any(g => g.StartsWith("CN=Domain Admins,", StringComparison.OrdinalIgnoreCase) || g.StartsWith("CN=Admins du domaine,", StringComparison.OrdinalIgnoreCase)
                || g.StartsWith("CN=Enterprise Admins,", StringComparison.OrdinalIgnoreCase) || g.StartsWith("CN=Administrateurs de l’entreprise,", StringComparison.OrdinalIgnoreCase));
        var level = admin ? RightsLevel.Admin : groups.Count > 0 ? RightsLevel.Delegated : RightsLevel.Read;
        var detail = admin ? "Compte protégé (adminCount) ou membre d’un groupe d’administration du domaine." : FrenchText.Count(groups.Count, "groupe direct", "groupes directs") + " ; droits réels vérifiés à chaque écriture.";
        return (new AccountIdentity(login, entry.String("displayName"), entry.String("givenName"), entry.DistinguishedName), new RightsInfo(level, SessionTexts.RightsLabel(level), true, detail));
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

    /// <summary>Completed readings are committed together, including when the remaining targets were cancelled.</summary>
    private async Task<DirectoryState> MeasureAsync(DomainInfo known, ScopeSelection scope, bool inventory, CancellationToken cancellationToken, IReadOnlySet<Guid>? exactTargets = null)
    {
        if (probe is null) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Collecteur de postes indisponible : aucun poste contacté."); }
        DirectoryState current;
        lock (gate) { current = state ?? Empty(known); }
        var generation = Epoch;
        if (current.Directory.Computers.IsDefaultOrEmpty)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Relisez d’abord l’annuaire : aucun poste connu dans l’OU de travail."); }
        var previous = current.Observations.Workstations.ToDictionary(w => w.ComputerGuid);
        var targets = current.Directory.Computers.Where(c => ScopeRules.Contains(scope, c.DistinguishedName) && !AdValues.IsDisabled(c.UserAccountControl)
            && (exactTargets is null || exactTargets.Contains(c.ObjectGuid) && previous.TryGetValue(c.ObjectGuid, out var o) && o.Presence.HasReading && o.Presence.Answered == true)).ToArray();
        var results = new WorkstationObservation?[targets.Length];
        var facts = new System.Collections.Concurrent.ConcurrentDictionary<Guid, MachineFacts>();
        using var limit = new SemaphoreSlim(inventory ? InventoryParallel : PingParallel);
        var tasks = targets.Select(async (computer, index) =>
        {
            await limit.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                if (Epoch != generation) { throw new OperationCanceledException("La session a changé.", cancellationToken); }
                var host = computer.DnsHostName ?? computer.Name;
                previous.TryGetValue(computer.ObjectGuid, out var before);
                var presence = before?.Presence ?? PresenceMeasure.Unread;
                var measured = before?.Inventory ?? InventoryMeasure.Unread;
                if (!inventory || exactTargets is null && presence.Answered != true)
                {
                    var answered = await probe.PingAsync(host, PingTimeout, cancellationToken).ConfigureAwait(false);
                    var at = Clock.GetUtcNow();
                    presence = new PresenceMeasure(MeasureState.Known, answered, at, answered ? at : presence.LastOnlineAt);
                    results[index] = new(computer.ObjectGuid, presence, measured);
                }
                if (inventory && presence.HasReading && presence.Answered == true)
                {
                    if (probe is IWorkstationFactsProbe detailed)
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
                results[index] = new(computer.ObjectGuid, presence, measured);
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
