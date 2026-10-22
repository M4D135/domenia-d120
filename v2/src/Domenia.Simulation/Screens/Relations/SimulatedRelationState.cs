using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Users and workstations of the fictitious directory for the relations (the local index of the simulation): by GUID first,
/// by name only for legacy links without GUID (Domenia 1 Get-DomeniaLinkLookupName).
/// </summary>
internal sealed class SimulatedRelationLookup : IRelationDirectoryLookup
{
    private readonly Dictionary<Guid, RelationObject> users = [];
    private readonly Dictionary<string, RelationObject> usersByLogin = new(StringComparer.Ordinal);
    private readonly Dictionary<Guid, RelationObject> computers = [];
    private readonly Dictionary<string, RelationObject> computersByName = new(StringComparer.Ordinal);
    private readonly Dictionary<string, RelationObject> byDn = new(StringComparer.OrdinalIgnoreCase);

    public SimulatedRelationLookup(DirectorySnapshot directory)
    {
        ArgumentNullException.ThrowIfNull(directory);
        Directory = directory;
        foreach (var user in directory.Users)
        {
            var detail = string.Join(" · ", new[] { user.Title, user.Department }.Where(t => !string.IsNullOrWhiteSpace(t)));
            var item = new RelationObject(RelationSubjectKind.User, user.ObjectGuid, user.DistinguishedName, user.DisplayName ?? user.Cn, user.SamAccountName,
                detail.Length == 0 ? user.Description : detail, !AdValues.IsDisabled(user.UserAccountControl), AdValues.FromFileTime(user.LastLogonTimestamp),
                user.WhenCreated, user.Sid, user.UserPrincipalName);
            users[user.ObjectGuid] = item;
            usersByLogin.TryAdd(RelationRules.LoginKey(user.SamAccountName), item);
            byDn[user.DistinguishedName] = item;
        }
        foreach (var computer in directory.Computers)
        {
            var item = new RelationObject(RelationSubjectKind.Computer, computer.ObjectGuid, computer.DistinguishedName, computer.Name, computer.Name,
                computer.OperatingSystem, !AdValues.IsDisabled(computer.UserAccountControl), AdValues.FromFileTime(computer.LastLogonTimestamp),
                computer.WhenCreated, computer.Sid, null);
            computers[computer.ObjectGuid] = item;
            computersByName.TryAdd(RelationRules.ComputerKey(computer.Name), item);
            byDn[computer.DistinguishedName] = item;
        }
    }

    public DirectorySnapshot Directory { get; }

    public IEnumerable<RelationObject> Users => users.Values;

    public IEnumerable<RelationObject> Computers => computers.Values;

    public RelationObject? User(Guid? guid, string login) =>
        guid is Guid g ? users.GetValueOrDefault(g) : usersByLogin.GetValueOrDefault(RelationRules.LoginKey(login));

    public RelationObject? Computer(Guid? guid, string name) =>
        guid is Guid g ? computers.GetValueOrDefault(g) : computersByName.GetValueOrDefault(RelationRules.ComputerKey(name));

    public RelationObject? UserByLogin(string login) => usersByLogin.GetValueOrDefault(RelationRules.LoginKey(login));

    public RelationObject? ComputerByName(string name) => computersByName.GetValueOrDefault(RelationRules.ComputerKey(name));

    /// <summary>The object named by a DN, a sAMAccountName or a workstation name (exact, case ignored).</summary>
    public RelationObject? Find(string reference)
    {
        ArgumentNullException.ThrowIfNull(reference);
        var value = reference.Trim();
        if (value.Contains('=', StringComparison.Ordinal))
        {
            if (byDn.TryGetValue(value, out var exact))
            {
                return exact;
            }
            try
            {
                return byDn.Values.FirstOrDefault(o => DistinguishedName.AreEqual(o.Dn, value));
            }
            catch (FormatException)
            {
                return null;
            }
        }
        return UserByLogin(value) ?? ComputerByName(value);
    }

    public DirectoryUser? DirectoryUser(Guid guid) => Directory.Users.FirstOrDefault(u => u.ObjectGuid == guid);

    public DirectoryComputer? DirectoryComputer(Guid guid) => Directory.Computers.FirstOrDefault(c => c.ObjectGuid == guid);
}

/// <summary>
/// Association store of the simulation and the session memory of the relations screen, one per simulated source (shared by
/// <see cref="SimulatedRelationsReader"/> and <see cref="SimulatedRelationChangeExecutor"/>). Memory only, never persisted: a new
/// session starts from the seed again (docs/WRITES.md § 5). Results of the network reads (detections, session reads,
/// harvests, orphan checks, import previews) are kept 15 minutes so that a plan of the write circuit names them instead of
/// receiving them from the page. Thread safe.
/// </summary>
internal sealed class SimulatedRelationState
{
    public static readonly TimeSpan ResultLifetime = TimeSpan.FromMinutes(15);

    public const int JournalCapacity = 500;

    private const int ResultCapacity = 64;

    private static readonly ConditionalWeakTable<SimulatedDirectorySource, SimulatedRelationState> States = new();

    private readonly SimulatedDirectorySource source;
    private readonly Lock gate = new();
    private readonly Lazy<SimulatedRelationSeed.Seed> seed;
    private ImmutableDictionary<string, StoredRelation>? store;
    private ImmutableList<RelationJournalRecord>? journal;
    private long version;
    private readonly Dictionary<string, StoredRelation> session = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (StoredRelation Record, string? Note, string? Restores)> pending = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (DateTimeOffset Expires, object Value)> results = new(StringComparer.Ordinal);
    private readonly Dictionary<Guid, DateTimeOffset> sweepReadings = [];
    private DateTimeOffset? readingsForgottenAt;
    private (DirectorySnapshot Snapshot, SimulatedRelationLookup Lookup)? lookup;
    private string? probing;

    private SimulatedRelationState(SimulatedDirectorySource source)
    {
        this.source = source;
        seed = new Lazy<SimulatedRelationSeed.Seed>(
            () => SimulatedRelationSeed.Build(source.World, source.World.Directory, source.ScreenStream("relations")),
            LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public static SimulatedRelationState For(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        return States.GetValue(source, static s => new SimulatedRelationState(s));
    }

    public SimulatedDirectorySource Source => source;

    public DateTimeOffset Now => source.Clock.GetUtcNow();

    public TimeZoneInfo Zone => source.World.TimeZone;

    /// <summary>Number of changes applied to the store since the start of the session.</summary>
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

    /// <summary>The stored associations, by key.</summary>
    public ImmutableDictionary<string, StoredRelation> Store
    {
        get
        {
            lock (gate)
            {
                return store ??= seed.Value.Store;
            }
        }
    }

    /// <summary>The local journal, oldest first (500 lines at most).</summary>
    public ImmutableList<RelationJournalRecord> Journal
    {
        get
        {
            lock (gate)
            {
                return journal ??= seed.Value.Journal;
            }
        }
    }

    /// <summary>Observations of the session not saved (persistence « Session uniquement »).</summary>
    public ImmutableArray<StoredRelation> Session
    {
        get
        {
            lock (gate)
            {
                return [.. session.Values];
            }
        }
    }

    /// <summary>Lookups over the directory as the session sees it (writes of the session applied).</summary>
    public SimulatedRelationLookup Lookup()
    {
        var directory = source.CurrentDirectory;
        lock (gate)
        {
            if (lookup is { } known && ReferenceEquals(known.Snapshot, directory))
            {
                return known.Lookup;
            }
        }
        var built = new SimulatedRelationLookup(directory);
        lock (gate)
        {
            lookup = (directory, built);
        }
        return built;
    }

    /// <summary>Keeps a result for 15 minutes; returns its identifier (32 hexadecimal characters).</summary>
    public string Remember(object value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var id = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
        var now = Now;
        lock (gate)
        {
            foreach (var key in results.Where(r => r.Value.Expires <= now).Select(r => r.Key).ToList())
            {
                results.Remove(key);
            }
            while (results.Count >= ResultCapacity)
            {
                results.Remove(results.MinBy(r => r.Value.Expires).Key);
            }
            results[id] = (now + ResultLifetime, value);
        }
        return id;
    }

    /// <summary>
    /// A result kept by <see cref="Remember"/>; relation.expired when unknown, expired or of another type. With
    /// <paramref name="extend"/>, its lifetime starts again (observations saved batch after batch never expire halfway).
    /// </summary>
    public T Recall<T>(string id, bool extend = false) where T : class
    {
        ArgumentNullException.ThrowIfNull(id);
        var now = Now;
        lock (gate)
        {
            if (results.TryGetValue(id, out var entry) && entry.Expires > now && entry.Value is T value)
            {
                if (extend)
                {
                    results[id] = (now + ResultLifetime, entry.Value);
                }
                return value;
            }
        }
        throw new DomeniaOperationException(RelationErrors.Expired, RelationErrors.ExpiredMessage);
    }

    /// <summary>The observation sets still kept (not expired), with their expiry, most recent first.</summary>
    public ImmutableArray<(string Id, SimulatedObservationSet Set, DateTimeOffset Expires)> ObservationSets()
    {
        var now = Now;
        lock (gate)
        {
            return [.. results.Where(r => r.Value.Expires > now && r.Value.Value is SimulatedObservationSet)
                .OrderByDescending(r => r.Value.Expires)
                .Select(r => (r.Key, (SimulatedObservationSet)r.Value.Value, r.Value.Expires))];
        }
    }

    /// <summary>Keys of the observations of the session not saved yet.</summary>
    public ImmutableHashSet<string> SessionKeys()
    {
        lock (gate)
        {
            return session.Keys.ToImmutableHashSet(StringComparer.Ordinal);
        }
    }

    /// <summary>Keeps a record drafted for a plan, found again by its fingerprint at execution.</summary>
    public void Hold(StoredRelation record, string? note = null, string? restores = null)
    {
        ArgumentNullException.ThrowIfNull(record);
        lock (gate)
        {
            pending[RelationRules.Fingerprint(record)] = (record, note, restores);
        }
    }

    /// <summary>Keeps the note of a removal (journal) by the fingerprint of the association removed.</summary>
    public void HoldNote(StoredRelation removed, string note)
    {
        ArgumentNullException.ThrowIfNull(removed);
        lock (gate)
        {
            pending[RelationRules.Fingerprint(removed)] = (removed, note, null);
        }
    }

    public bool HasRecord(string fingerprint)
    {
        lock (gate)
        {
            return pending.ContainsKey(fingerprint);
        }
    }

    /// <summary>
    /// Applies a confirmed plan to the store: the preconditions are checked again under the same lock as the change (another
    /// instance may have changed the store since the circuit checked them), then one journal line per change; the
    /// observations saved leave the session list. A stale plan throws write.stale and changes nothing.
    /// </summary>
    public RelationChangeResult Commit(WritePlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var now = Now;
        lock (gate)
        {
            var current = store ??= seed.Value.Store;
            var check = RelationChange.Check(plan, current, pending.ContainsKey);
            if (!check.Current)
            {
                throw new DomeniaOperationException(WriteErrors.Stale, check.Detail);
            }
            var result = RelationChange.Apply(plan, current,
                fingerprint => pending.TryGetValue(fingerprint, out var held) ? held.Record : null,
                fingerprint => pending.TryGetValue(fingerprint, out var held) ? (held.Note, held.Restores) : (null, null),
                now,
                () => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)));
            store = result.Store;
            var lines = (journal ??= seed.Value.Journal).AddRange(result.Journal);
            if (lines.Count > JournalCapacity)
            {
                lines = lines.RemoveRange(0, lines.Count - JournalCapacity);
            }
            journal = lines;
            // Only an observation that was just recorded leaves the memory of the session: a removal of the stored association
            // never erases a newer unsaved observation of the same key, nor one whose fingerprint differs from what was saved.
            foreach (var line in result.Journal)
            {
                if (line.Action is RelationJournalAction.Added or RelationJournalAction.Refreshed or RelationJournalAction.Restored
                    && session.TryGetValue(line.Key, out var observed)
                    && pending.ContainsKey(RelationRules.Fingerprint(observed)))
                {
                    session.Remove(line.Key);
                }
            }
            if (result.Applied > 0)
            {
                version++;
            }
            return result;
        }
    }

    /// <summary>Adds observations of the session (shown as « Session uniquement » until saved); returns how many keys were new.</summary>
    public int Observe(IEnumerable<StoredRelation> observations)
    {
        ArgumentNullException.ThrowIfNull(observations);
        var added = 0;
        lock (gate)
        {
            foreach (var observation in observations)
            {
                var key = RelationRules.Key(observation);
                if (!session.ContainsKey(key))
                {
                    added++;
                }
                session[key] = observation;
            }
        }
        return added;
    }

    /// <summary>Marks a probe as running; false when another one already runs (one detection at a time).</summary>
    public bool BeginProbe(string planId)
    {
        lock (gate)
        {
            if (probing is not null)
            {
                return false;
            }
            probing = planId;
            return true;
        }
    }

    public void EndProbe(string planId)
    {
        lock (gate)
        {
            if (probing == planId)
            {
                probing = null;
            }
        }
    }

    /// <summary>Last console reading of a workstation by a relevé, a session read or a harvest of this session.</summary>
    public DateTimeOffset? LastReading(Guid computer)
    {
        lock (gate)
        {
            return sweepReadings.TryGetValue(computer, out var at) ? at : null;
        }
    }

    /// <summary>Records a reading of the parc (Domenia 1 ParkState); an older date never replaces a newer one.</summary>
    public void Read(Guid computer, DateTimeOffset at)
    {
        lock (gate)
        {
            if (!sweepReadings.TryGetValue(computer, out var known) || known < at)
            {
                sweepReadings[computer] = at;
            }
        }
    }

    /// <summary>
    /// Instant of the last « Oublier les relevés »: console relations stored before it no longer count as relevés (the parc
    /// memory of Domenia 1 is separate from the associations).
    /// </summary>
    public DateTimeOffset? ReadingsForgottenAt
    {
        get
        {
            lock (gate)
            {
                return readingsForgottenAt;
            }
        }
    }

    /// <summary>
    /// The relevé memory as the sweep sees it: readings of the session, and console relations of the store not older than the
    /// last reset. Returns the count, a fingerprint of the readings and the oldest date.
    /// </summary>
    public (int Count, string Fingerprint, DateTimeOffset? Oldest) Readings()
    {
        var stored = Store;
        lock (gate)
        {
            var all = new Dictionary<Guid, DateTimeOffset>(sweepReadings);
            foreach (var relation in stored.Values.Where(r => r.Kind == RelationKind.Console && r.ComputerGuid is not null && r.When is not null
                && (readingsForgottenAt is null || r.When > readingsForgottenAt)))
            {
                var guid = relation.ComputerGuid!.Value;
                if (!all.TryGetValue(guid, out var known) || known < relation.When!.Value)
                {
                    all[guid] = relation.When!.Value;
                }
            }
            var text = string.Join(";", all.OrderBy(p => p.Key).Select(p => p.Key.ToString("N") + "=" + p.Value.UtcTicks.ToString(System.Globalization.CultureInfo.InvariantCulture)));
            var print = Convert.ToHexStringLower(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(text)));
            return (all.Count, print, all.Count == 0 ? null : all.Values.Min());
        }
    }

    /// <summary>Empties the relevé memory (« Oublier les relevés »); returns how many readings were forgotten.</summary>
    public int ForgetReadings()
    {
        var (count, _, _) = Readings();
        lock (gate)
        {
            sweepReadings.Clear();
            readingsForgottenAt = Now;
            version++;
        }
        return count;
    }
}
