using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>An object deleted from the fictitious directory, still visible among the deleted objects (isDeleted).</summary>
internal sealed record Tombstone(Guid ObjectGuid, string Name, IndexObjectType Type, string LastKnownParent, DateTimeOffset DeletedAt, bool Recycled);

/// <summary>Marker of the last pass that stopped at a limit (Domenia 1 preference Index.Partial).</summary>
internal sealed record PartialMarker(DateTimeOffset At, int Count, string? Reason, long Limit, string ScopeDn);

/// <summary>A result kept by the engine until its storage plan runs, or until it expires.</summary>
internal abstract record HeldBatch(string Id, string Kind, string Label, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, int Count);

/// <summary>A read of the directory (one OU, the changes of the domain, or the whole domain) with its rows.</summary>
internal sealed record IndexBatch(
    string Id,
    string Label,
    DateTimeOffset CreatedAt,
    DateTimeOffset ExpiresAt,
    SyncTarget Target,
    SyncScope Scope,
    SyncReadMode Mode,
    bool Complete,
    SyncCut? Cut,
    string Controller,
    string? InvocationId,
    long HighestUsn,
    ImmutableArray<IndexRecord> Rows,
    ImmutableArray<CensusGapRecord> Census,
    string Sha256,
    bool Rebuild,
    string LapsSchema) : HeldBatch(Id, "index", Label, CreatedAt, ExpiresAt, Rows.Length);

/// <summary>A verification of disappeared objects.</summary>
internal sealed record AbsenceBatch(string Id, string Label, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, string Server, ImmutableDictionary<Guid, AbsenceOutcome> Outcomes, string Sha256)
    : HeldBatch(Id, "absences", Label, CreatedAt, ExpiresAt, Outcomes.Count);

/// <summary>A read by GUID of the census gaps.</summary>
internal sealed record GapBatch(string Id, string Label, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, string Server, ImmutableDictionary<Guid, GapOutcome> Outcomes, string Sha256)
    : HeldBatch(Id, "gaps", Label, CreatedAt, ExpiresAt, Outcomes.Count);

/// <summary>A read of the shared park survey, merged in memory, with the fingerprints of both sides when it was read.</summary>
internal sealed record ParkSharedBatch(string Id, string Label, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, ImmutableDictionary<string, ParkEntry> Merged,
    string LocalSha, string SharedSha, int Added, int Replaced, int Received, string Sha256) : HeldBatch(Id, "park", Label, CreatedAt, ExpiresAt, Merged.Count);

/// <summary>An estimate confirmed by the page before a read.</summary>
internal sealed record EstimateRecord(SyncEstimate Estimate, SyncEstimateRequest Request, long MaxObjects, int BudgetMs);

/// <summary>A snapshot capture planned, waiting for write.execute.</summary>
internal sealed record PendingCapture(string Id, string Label, SyncScope Scope, SnapshotCoverageProof Coverage, string Sha256, int Count, DateTimeOffset At);

/// <summary>The read in progress (one at a time).</summary>
internal sealed class RunState(string runId, SyncTarget target, string scopeLabel, DateTimeOffset startedAt) : IDisposable
{
    public string RunId { get; } = runId;
    public SyncTarget Target { get; } = target;
    public string ScopeLabel { get; } = scopeLabel;
    public DateTimeOffset StartedAt { get; } = startedAt;
    public SyncPhase Phase { get; set; } = SyncPhase.Backup;
    public CancellationTokenSource Stop { get; } = new();

    public void Dispose() => Stop.Dispose();
}

/// <summary>
/// The local base of the simulation, shared by the screen reader and the write executor of the same source (one per
/// <see cref="SimulatedDirectorySource"/>). Derived once from the generated world (<see cref="SimulatedSyncSeed"/>), then
/// changed only by the storage plans run by write.execute; never saved: a new start rebuilds it from the seed. Every field is
/// read and written under <see cref="Gate"/>.
/// </summary>
internal sealed class SimulatedSyncState
{
    /// <summary>A result of a read is kept this long for its storage plan (Domenia 1: no storage without its batch).</summary>
    public static readonly TimeSpan BatchLifetime = TimeSpan.FromMinutes(15);

    private static readonly ConditionalWeakTable<SimulatedDirectorySource, SimulatedSyncState> States = new();

    private SimulatedSyncState(SimulatedDirectorySource source) => Source = source;

    /// <summary>The state of this source, created on first use (cheap: the seed runs at the first read).</summary>
    public static SimulatedSyncState For(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        return States.GetValue(source, static s => new SimulatedSyncState(s));
    }

    public SimulatedDirectorySource Source { get; }

    public Lock Gate { get; } = new();

    private bool seeded;

    public Dictionary<Guid, IndexRecord> Rows { get; private set; } = [];

    public List<SyncStateEntry> SyncStates { get; } = [];

    public SyncCheckpoint? Checkpoint { get; set; }

    public List<AbsenceRecord> Absences { get; } = [];

    public List<CensusGapRecord> Gaps { get; } = [];

    /// <summary>Census gaps still missing from the base (an identity added since by another read is no longer a gap).</summary>
    public List<CensusGapRecord> OpenGaps() => [.. Gaps.Where(g => !Rows.ContainsKey(g.ObjectGuid))];

    public List<SnapshotRecord> Snapshots { get; } = [];

    public Dictionary<string, ParkEntry> Park { get; private set; } = new(StringComparer.Ordinal);

    public Dictionary<string, ParkEntry> SharedFile { get; private set; } = new(StringComparer.Ordinal);

    public string SharedPath { get; set; } = "";

    public DateTimeOffset? SharedLastSync { get; set; }

    public Dictionary<Guid, Tombstone> Tombstones { get; } = [];

    /// <summary>User-workstation associations of the base: workstation name (upper case) to user logins.</summary>
    public Dictionary<string, SortedSet<string>> LinksByComputer { get; } = new(StringComparer.Ordinal);

    /// <summary>Workstation names (upper case) by user login (lower case).</summary>
    public Dictionary<string, SortedSet<string>> LinksByUser { get; } = new(StringComparer.Ordinal);

    public int Dormants { get; set; }

    public DateTimeOffset? LastBackupAt { get; set; }

    public long Generation { get; set; } = 1;

    public PartialMarker? Partial { get; set; }

    public List<SyncStorageReceipt> StorageReceipts { get; } = [];

    public Dictionary<string, HeldBatch> Batches { get; } = new(StringComparer.Ordinal);

    public Dictionary<string, EstimateRecord> Estimates { get; } = new(StringComparer.Ordinal);

    public Dictionary<string, PendingCapture> Captures { get; } = new(StringComparer.Ordinal);

    public RunState? Run { get; set; }

    private int commits;

    /// <summary>
    /// True while at least one storage commit holds the base (reads with a short wait answer « busy », Domenia 1 point 4). A
    /// counter, so two commits that overlap never clear it too early. Read without the gate for the short wait of a search;
    /// every decision is taken again under the gate.
    /// </summary>
    public bool Committing => Volatile.Read(ref commits) > 0;

    /// <summary>A commit starts (call <see cref="EndCommit"/> in a finally).</summary>
    public void BeginCommit() => Interlocked.Increment(ref commits);

    public void EndCommit() => Interlocked.Decrement(ref commits);

    private int maintenance;

    /// <summary>True while a maintenance of the base runs (a verified backup in the simulation): new passes wait.</summary>
    public bool Maintenance => Volatile.Read(ref maintenance) > 0;

    public void BeginMaintenance() => Interlocked.Increment(ref maintenance);

    public void EndMaintenance() => Interlocked.Decrement(ref maintenance);

    /// <summary>Failed local writes in a row (Domenia 1 Persistence.Failures); the simulation never fails a write, it stays at 0.</summary>
    public int WriterFailures { get; set; }

    /// <summary>LAPS schema of the fictitious domain as the last read of the schema found it (Domenia 1 $lapsSchema).</summary>
    public string LapsSchema { get; set; } = SyncIndex.LapsSchemaUnknown;

    /// <summary>A workstation result on its way (a park probe of the session) that lands while the stored survey is read again.</summary>
    public ParkProbe? InFlightProbe { get; set; }

    /// <summary>Results kept while the stored survey is read again (Domenia 1 DomeniaParkDeferred), applied after it.</summary>
    public ImmutableArray<ParkProbe> DeferredProbes { get; set; } = [];

    /// <summary>True while the stored park survey is read again.</summary>
    public bool ParkReloading { get; set; }

    /// <summary>One synchronisation of the shared survey at a time: a second request waits and is made after it (Domenia 1).</summary>
    public SemaphoreSlim SharedGate { get; } = new(1, 1);

    /// <summary>Attempts during which another console holds the lock of the shared file (the next read finds it free).</summary>
    public int SharedLockHeldFor { get; set; } = 1;

    /// <summary>Whether the share of the shared survey answers (the fictitious file server always does).</summary>
    public bool SharedReachable { get; set; } = true;

    public string DomainDn { get; private set; } = "";

    public string DomainName { get; private set; } = "";

    public string Controller { get; private set; } = "";

    public string InvocationId { get; private set; } = "";

    public string Operator { get; private set; } = "";

    public DateTimeOffset Reference { get; private set; }

    public TimeZoneInfo Zone { get; private set; } = TimeZoneInfo.Utc;

    /// <summary>Seeds the base from the generated world the first time; call under <see cref="Gate"/>.</summary>
    public void EnsureSeeded()
    {
        if (seeded)
        {
            return;
        }
        var world = Source.World;
        DomainDn = world.Directory.Domain.RootDn;
        DomainName = world.Directory.Domain.DnsName;
        Controller = world.Session.Controller?.DnsName ?? world.Directory.Domain.Controllers[0].DnsName;
        Operator = world.Session.Account.Login;
        Reference = world.Reference;
        Zone = world.TimeZone;
        SimulatedSyncSeed.Fill(this, world, Source.ScreenStream("synchro"));
        seeded = true;
    }

    public void SetRows(Dictionary<Guid, IndexRecord> rows) => Rows = rows;

    public void SetPark(Dictionary<string, ParkEntry> park) => Park = park;

    public void SetSharedFile(Dictionary<string, ParkEntry> shared) => SharedFile = shared;

    public void SetInvocation(string invocationId) => InvocationId = invocationId;

    /// <summary>Puts or replaces one coverage line (one per key).</summary>
    public void PutSyncState(SyncStateEntry entry)
    {
        SyncStates.RemoveAll(e => string.Equals(e.Key, entry.Key, StringComparison.OrdinalIgnoreCase));
        SyncStates.Add(entry);
    }

    /// <summary>Removes expired batches, estimates and captures (call under the gate).</summary>
    public void Purge(DateTimeOffset now)
    {
        foreach (var key in Batches.Where(b => b.Value.ExpiresAt <= now).Select(b => b.Key).ToList())
        {
            Batches.Remove(key);
        }
        foreach (var key in Estimates.Where(e => e.Value.Estimate.ExpiresAt <= now).Select(e => e.Key).ToList())
        {
            Estimates.Remove(key);
        }
        foreach (var key in Captures.Where(c => c.Value.At + BatchLifetime <= now).Select(c => c.Key).ToList())
        {
            Captures.Remove(key);
        }
    }

    /// <summary>Association text of an index row (Domenia 1 Get-DomeniaIndexAssociationText).</summary>
    public string? Association(IndexRecord row)
    {
        if (row.Type == IndexObjectType.Computer)
        {
            return LinksByComputer.TryGetValue(SyncPark.Key(row.Name), out var users) && users.Count > 0 ? string.Join(", ", users) : null;
        }
        var login = (row.Login ?? "").ToLowerInvariant();
        return login.Length > 0 && LinksByUser.TryGetValue(login, out var computers) && computers.Count > 0 ? string.Join(", ", computers) : null;
    }

    public int LinkCount => LinksByComputer.Values.Sum(v => v.Count);

    /// <summary>Records a storage receipt (the six most recent are shown).</summary>
    public void AddReceipt(SyncStorageReceipt receipt)
    {
        StorageReceipts.Insert(0, receipt);
        if (StorageReceipts.Count > 12)
        {
            StorageReceipts.RemoveRange(12, StorageReceipts.Count - 12);
        }
    }

    /// <summary>SHA-256 of the park survey (one line per workstation), the precondition of a reset or a merge.</summary>
    public static string ParkFingerprint(IReadOnlyDictionary<string, ParkEntry> park)
    {
        var text = string.Join('\n', park.OrderBy(p => p.Key, StringComparer.Ordinal)
            .Select(p => p.Key + "|" + p.Value.LastProbe.UtcTicks.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + p.Value.Status + "|" + p.Value.User + "|" + p.Value.Attempts));
        return Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(text)));
    }
}
