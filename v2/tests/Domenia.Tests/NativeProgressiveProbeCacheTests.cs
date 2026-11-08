using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;
using ProbeReading = Domenia.Core.Accueil.ProbeReading;

namespace Domenia.Tests;

internal static class NativeProgressiveProbeCacheTests
{
    [Test]
    public static async Task Committed_probe_batches_survive_stop_and_cold_reopen_before_the_remaining_hosts_finish()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("progressive.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        var computers = Enumerable.Range(0, 40).Select(i => Fixtures.Computer("PC" + i.ToString("D2"))).ToArray();
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: computers), scope, "DC1", default);
        await database.SaveFleetAsync(FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [.. computers.Select(pc => Fixtures.Observe(pc, Fixtures.Presence(true, TimeSpan.Zero)))]) }, default);
        var wrapper = new ObservedCache(new SqliteDirectoryCache(database));
        using var stop = new CancellationTokenSource();
        using (var ldap = new AdBoundaryTests.RecordingAdConnection())
        using (var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: wrapper) { AdministrationOverride = AdBoundaryTests.NativeAdministrator })
        {
            var held = computers.Skip(32).Select(p => p.ObjectGuid).ToHashSet();
            var reader = new AdAccueilReader(source) { ProbeOverride = async (pc, _, token) =>
            {
                if (held.Contains(pc.ObjectGuid)) await Task.Delay(Timeout.InfiniteTimeSpan, token);
                return ImmutableDictionary<string, ProbeReading>.Empty.Add("hw.model", new(MeasureState.Known, Fixtures.Now, ["Model"], null) { DefinitionHash = ProbeDefinitionIdentity.Of(ProbeCatalog.Find("hw.model")!) });
            } };
            var running = reader.CollectProbesAsync(["hw.model"], scope, computers.Select(p => p.ObjectGuid).ToArray(), stop.Token);
            try
            {
                await wrapper.Committed.Task.WaitAsync(TimeSpan.FromSeconds(15));
                var visible = await new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed()).ReadFleetAsync(default);
                Check.Equal(32, visible.Probes.ByProbe["hw.model"].Count, "32 succès visibles par une autre connexion avant la fin de campagne");
                Check.False(running.IsCompleted, "les dernières lectures restent physiquement en cours");
            }
            finally { stop.Cancel(); }
            await Check.ThrowsAsync<OperationCanceledException>(() => running, "arrêt conservé");
        }
        var cold = new SqliteDirectoryCache(new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed()));
        var stored = await cold.ReadFleetAsync(default);
        var missing = computers.Where(p => !stored.Probes.ByProbe["hw.model"].ContainsKey(p.ObjectGuid)).Select(p => p.ObjectGuid).ToArray();
        Check.Equal(8, missing.Length, "aucune perte et aucun succès inventé après réouverture");
        using var nextLdap = new AdBoundaryTests.RecordingAdConnection();
        using var next = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: nextLdap, localStore: cold) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        var contacts = 0;
        var resumed = new AdAccueilReader(next) { ProbeOverride = (_, _, _) => { Interlocked.Increment(ref contacts); return Task.FromResult(ImmutableDictionary<string, ProbeReading>.Empty.Add("hw.model", new(MeasureState.Known, Fixtures.Now, ["Model"], null) { DefinitionHash = ProbeDefinitionIdentity.Of(ProbeCatalog.Find("hw.model")!) })); } };
        await resumed.CollectProbesAsync(["hw.model"], scope, missing, default);
        Check.Equal(8, contacts, "uniquement les postes restants envoyés");
        Check.Equal(40, (await cold.ReadFleetAsync(default)).Probes.ByProbe["hw.model"].Count, "fusion durable complète");
        Check.True(wrapper.Writes <= 2, "transactions groupées, pas une écriture par sonde");
    }

    private sealed class ObservedCache(SqliteDirectoryCache inner) : IDirectoryCache, IAccueilCache
    {
        public TaskCompletionSource Committed { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int Writes { get; private set; }
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => inner.ReadAsync(token);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) => inner.SaveAsync(snapshot, scope, controller, token);
        public Task<CachedFleet> ReadFleetAsync(CancellationToken token) => inner.ReadFleetAsync(token);
        public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken token) => inner.ReadFleetHistoryAsync(scope, token);
        public async Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken token)
        {
            var saved = await inner.SaveFleetAsync(patch, token); Writes++;
            if (saved.Probes.ByProbe.GetValueOrDefault("hw.model")?.Count >= 32) Committed.TrySetResult();
            return saved;
        }
    }
}
