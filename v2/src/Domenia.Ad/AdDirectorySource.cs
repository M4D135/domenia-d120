using System.Collections.Immutable;
using System.Security.Principal;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>
/// The directory source of the directory mode (Active Directory of the domain of the computer, Windows session). Nothing is read
/// in the constructor. The first call of the session connects once (RootDSE, domain object, account of the session: bounded,
/// never retried in a loop); afterwards the session is answered from memory. The directory picture is read on an explicit
/// request (« Actualiser » of the home page): users, groups, OUs and computers of the domain, paged, 50 000 per kind at most;
/// workstation measures (presence, light inventory) only on the working OU, never on the domain root. Read only by
/// construction: the write executors of Domenia.Ad are the only writers, through <see cref="Connection"/>.
/// </summary>
public sealed class AdDirectorySource : IDirectorySource, IDisposable
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
    private readonly Lock gate = new();
    private DomainInfo? domain;
    private AccountIdentity? account;
    private RightsInfo? rights;
    private string? failure;
    private string failureCode = AdErrors.NotConnected;
    private DateTimeOffset? failedAt;
    private DirectoryState? state;
    private long epoch;

    public AdDirectorySource(string? joinedDomain, Func<string> accountLogin, TimeProvider clock, IWorkstationProbe? probe = null, IAdConnection? connection = null)
    {
        ArgumentNullException.ThrowIfNull(accountLogin);
        ArgumentNullException.ThrowIfNull(clock);
        this.joinedDomain = joinedDomain;
        this.accountLogin = accountLogin;
        this.probe = probe;
        Clock = clock;
        Connection = connection ?? AdConnectionFactory.Create(new AdConnectionOptions(null, joinedDomain));
    }

    public DirectorySourceKind Kind => DirectorySourceKind.ActiveDirectory;

    /// <summary>The LDAP connection of the session (opened on first use).</summary>
    public IAdConnection Connection { get; }

    public TimeProvider Clock { get; }

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
        try
        {
            // The session itself connects once only (first call, or after Reset); afterwards it is answered from memory.
            await EnsureConnectedAsync(retry: false, cancellationToken).ConfigureAwait(false);
        }
        catch (DomeniaOperationException)
        {
            // The session says « not connected » with its reason; nothing else is attempted until the next explicit gesture.
        }
        lock (gate)
        {
            var directory = state?.Directory;
            var store = directory is null || directory.ReadAt == DateTimeOffset.MinValue ? new StoreStatus(null, 0, false) : new StoreStatus(directory.ReadAt, directory.ObjectCount, directory.Complete);
            var login = account?.Login ?? accountLogin();
            if (domain is null)
            {
                return new SessionSnapshot(
                    ConnectionState.Disconnected,
                    joinedDomain is null ? null : new DomainIdentity(joinedDomain, null, null),
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

    public async Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken)
    {
        var known = await DomainAsync(cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            return state ??= Empty(known);
        }
    }

    public async Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken cancellationToken)
    {
        var known = await DomainAsync(cancellationToken).ConfigureAwait(false);
        if (family is MeasureFamily.Presence or MeasureFamily.Inventory)
        {
            ScopeRules.EnsureNotDomainRoot(scope, known.RootDn);
        }
        await refreshing.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            switch (family)
            {
                case MeasureFamily.Directory:
                    {
                        var snapshot = await AdDirectoryReader.ReadSnapshotAsync(Connection, known, known.RootDn, MaxObjectsPerKind, Clock, cancellationToken).ConfigureAwait(false);
                        lock (gate)
                        {
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

    /// <summary>Presence (ping) or light inventory of the computers of the working OU, a few at a time.</summary>
    private async Task<DirectoryState> MeasureAsync(DomainInfo known, ScopeSelection scope, bool inventory, CancellationToken cancellationToken)
    {
        if (probe is null)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Mesure des postes indisponible dans cette version" + FrenchText.Colon + "aucun poste contacté.");
        }
        DirectoryState current;
        lock (gate)
        {
            current = state ?? Empty(known);
        }
        if (current.Directory.Computers.IsDefaultOrEmpty)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Relisez d’abord l’annuaire" + FrenchText.Colon + "aucun poste connu dans l’OU de travail.");
        }
        var targets = current.Directory.Computers.Where(c => InScope(c.DistinguishedName, scope) && !AdValues.IsDisabled(c.UserAccountControl)).ToList();
        var previous = current.Observations.Workstations.ToDictionary(w => w.ComputerGuid);
        var now = Clock.GetUtcNow();
        var results = new WorkstationObservation[targets.Count];
        using var limit = new SemaphoreSlim(inventory ? InventoryParallel : PingParallel);
        var tasks = targets.Select(async (computer, index) =>
        {
            await limit.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                var host = computer.DnsHostName ?? computer.Name;
                previous.TryGetValue(computer.ObjectGuid, out var before);
                var presence = before?.Presence ?? PresenceMeasure.Unread;
                var inventoryMeasure = before?.Inventory ?? InventoryMeasure.Unread;
                if (!inventory || presence.Answered != true)
                {
                    var answered = await probe.PingAsync(host, PingTimeout, cancellationToken).ConfigureAwait(false);
                    presence = new PresenceMeasure(MeasureState.Known, answered, now, answered ? now : presence.LastOnlineAt);
                }
                if (inventory && presence.Answered == true)
                {
                    inventoryMeasure = await probe.ReadInventoryAsync(host, InventoryTimeout, cancellationToken).ConfigureAwait(false);
                }
                results[index] = new WorkstationObservation(computer.ObjectGuid, presence, inventoryMeasure);
            }
            finally
            {
                limit.Release();
            }
        });
        await Task.WhenAll(tasks).ConfigureAwait(false);
        lock (gate)
        {
            var latest = state ?? Empty(known);
            var merged = latest.Observations.Workstations.ToDictionary(w => w.ComputerGuid);
            foreach (var result in results)
            {
                merged[result.ComputerGuid] = result;
            }
            var answered = results.Count(r => r.Presence.Answered == true);
            var label = inventory
                ? "Inventaire léger" + FrenchText.Colon + FrenchText.Count(results.Count(r => r.Inventory.HasReading), "poste lu", "postes lus") + " sur " + FrenchText.Integer(results.Length) + " (OU " + scope.Label + ")."
                : "Présence mesurée" + FrenchText.Colon + FrenchText.Count(answered, "poste répond", "postes répondent") + " sur " + FrenchText.Integer(results.Length) + " (OU " + scope.Label + ").";
            state = latest with
            {
                Observations = new FleetObservations(now, [.. merged.Values]),
                Journal = Add(latest.Journal, label, Tone.Info),
            };
            return state;
        }
    }

    private static bool InScope(string dn, ScopeSelection scope)
    {
        var parent = DistinguishedName.Parent(dn);
        return scope.Subtree
            ? dn.EndsWith("," + scope.Dn, StringComparison.OrdinalIgnoreCase)
            : parent is not null && string.Equals(parent, scope.Dn, StringComparison.OrdinalIgnoreCase);
    }

    private ImmutableArray<JournalEntry> Add(ImmutableArray<JournalEntry> journal, string label, Tone tone) =>
        [new JournalEntry(Clock.GetUtcNow(), label, tone), .. journal.IsDefault ? [] : journal.Take(199)];

    private DirectoryState Empty(DomainInfo known) =>
        new(new DirectorySnapshot(known, DateTimeOffset.MinValue, false, [], [], [], []), FleetObservations.Empty, [], []);
}
