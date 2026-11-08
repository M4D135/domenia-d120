using System.Collections.Immutable;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class QueryRefreshTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static QueryRecipe Recipe() => QueryRecipe.Empty() with { Name = "Mesure disque", Clauses = [new("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(10))] };
    private static QueryDataset Dataset(DirectorySnapshot directory, FleetObservations observations) => new(directory, observations,
        ImmutableDictionary<Guid, ImmutableArray<Domenia.Core.Queries.ProbeReading>>.Empty, ImmutableDictionary<Guid, ConsoleReading>.Empty,
        ImmutableDictionary<Guid, char>.Empty, ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>>.Empty, 1, "test", true);

    [Test]
    public static async Task Query_refresh_dispatches_3500_exact_targets_in_parallel_with_one_frozen_account_selection()
    {
        var computers = Enumerable.Range(0, 3500).Select(i => Fixtures.Computer("PC-QUERY-" + i)).ToArray();
        var requests = computers.Select(pc => new QueryMeasureRequest([pc.ObjectGuid], false, true, false, [])
        { ExpectedIdentities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(pc.ObjectGuid, QueryComputerIdentity.Of(pc)) }).ToImmutableArray();
        var counts = new System.Collections.Concurrent.ConcurrentDictionary<Guid, int>();
        var active = 0; var peak = 0; var confirmed = 0;
        var firstWave = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var reader = new DispatchReader(async (request, token) =>
        {
            Check.True(request.OnlyOutcome, "la campagne ne demande pas de recalcul global par poste");
            Check.Equal(7L, request.ExpectedEpoch!.Value, "session figée");
            Check.Equal(11L, request.ExpectedAccountVersion!.Value, "compte AD figé pour toute la file");
            Check.Equal(13L, request.ExpectedMachineGeneration!.Value, "compte poste figé pour toute la file");
            Check.False(request.Presence, "aucun second ping");
            var id = request.Computers.Single();
            Check.Equal(id, request.ExpectedIdentities!.Single().Value.Guid, "identité portée par le lecteur de chaque poste");
            counts.AddOrUpdate(id, 1, (_, n) => n + 1);
            var current = Interlocked.Increment(ref active);
            int observed; do { observed = Volatile.Read(ref peak); if (observed >= current) break; } while (Interlocked.CompareExchange(ref peak, current, observed) != observed);
            // Hold the first readers until the configured parallel wave actually exists. Task.Yield
            // alone can resume the same worker before another one is scheduled on a busy CI host.
            if (current == 4) firstWave.TrySetResult();
            await firstWave.Task.WaitAsync(TimeSpan.FromSeconds(10), token);
            token.ThrowIfCancellationRequested();
            Interlocked.Decrement(ref active);
            return new(1, 1, 0, 0, 0, Fixtures.Now);
        });
        var result = await QueryRefreshDispatcher.RunAsync(reader, requests, 4, 7, 11, 13,
            (_, _) => { Interlocked.Increment(ref confirmed); return Task.CompletedTask; }, None).WaitAsync(TimeSpan.FromSeconds(30));
        Check.Equal(3500, result.Answered, "toutes les cibles aboutissent");
        Check.Equal(3500, result.Requested, "compteurs complets"); Check.Equal(0, result.Failed, "aucun faux échec de saturation");
        Check.Equal(3500, confirmed, "garde de contexte avant chaque demande");
        Check.Equal(3500, counts.Count, "population exacte"); Check.True(counts.Values.All(v => v == 1), "aucun rejeu");
        Check.True(peak is > 1 and <= 4, "parallélisme réglé réellement observé");
    }

    [Test]
    public static async Task Query_refresh_cancellation_waits_for_already_started_readers_and_never_starts_the_queue_tail()
    {
        using var stop = new CancellationTokenSource();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var physicalEnd = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var reader = new DispatchReader(async (_, _) =>
        {
            if (Interlocked.Increment(ref calls) == 2) started.TrySetResult();
            await physicalEnd.Task;
            return new(1, 1, 0, 0, 0, Fixtures.Now);
        });
        var requests = Enumerable.Range(0, 20).Select(i => new QueryMeasureRequest([Fixtures.IdOf("Q" + i)], false, true, false, [])).ToImmutableArray();
        var running = QueryRefreshDispatcher.RunAsync(reader, requests, 2, 1, 2, 3, (_, _) => Task.CompletedTask, stop.Token);
        try
        {
            await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
            stop.Cancel();
            Check.False(running.IsCompleted, "annulation ne libère pas le travail physique");
            Check.Equal(2, Volatile.Read(ref calls), "aucune nouvelle cible pendant arrêt");
        }
        finally { physicalEnd.TrySetResult(); }
        await Check.ThrowsAsync<OperationCanceledException>(() => running, "arrêt après la fin des lecteurs");
        Check.Equal(2, calls, "queue restante non envoyée");
    }

    [Test]
    public static async Task Query_refresh_admission_refusal_keeps_an_already_authorized_one_shot_read_alive()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var refused = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0; var guards = 0;
        var reader = new DispatchReader(async (_, token) =>
        {
            Interlocked.Increment(ref calls); entered.TrySetResult();
            await refused.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check.False(token.IsCancellationRequested, "un refus de la cible suivante n’annule pas le bail déjà accordé");
            return new(1, 1, 0, 0, 0, Fixtures.Now);
        });
        var requests = Enumerable.Range(0, 12).Select(i => new QueryMeasureRequest([Fixtures.IdOf("SINGLE" + i)], false, true, false, [])).ToImmutableArray();
        await Check.ThrowsAsync<DomeniaOperationException>(() => QueryRefreshDispatcher.RunAsync(reader, requests, 2, 1, 2, 3,
            async (_, _) =>
            {
                if (Interlocked.Increment(ref guards) == 1) return;
                await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
                refused.TrySetResult();
                throw new DomeniaOperationException(AccountAccess.EpochChanged, "Bail consommé ; aucune autre sélection.");
            }, None), "refus transmis après fin de la lecture autorisée");
        Check.Equal(1, calls, "un seul poste réellement lu, aucun repli sur la session Windows");
    }

    private sealed class DispatchReader(Func<QueryMeasureRequest, CancellationToken, Task<QueryMeasureResult>> read) : IQueryWorkshopReader
    {
        public Task<QueryDataset> DatasetAsync(CancellationToken token) => throw new InvalidOperationException("Pas de recalcul de dataset par poste.");
        public Task<QueryMeasureResult> MeasureAsync(QueryMeasureRequest request, CancellationToken token) => read(request, token);
    }

    [Test]
    public static async Task Refresh_freezes_library_revisions_and_refuses_missing_or_archived_consumers()
    {
        using var library = new QueryLibrary(new MemoryQueryLibraryStore(), new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
        var first = await library.SaveAsync(Fixtures.Root, Recipe(), null, null, 0, "update", new("fleet", "kpi", "Disques"), None);
        var item = new FleetLayoutItem("test", FleetWidgetSource.Query, first.Widget!.Id, "Kpi", "M", "Disques", false, "Requêtes");
        var content = await library.ReadAsync(Fixtures.Root, None);
        var frozen = QueryRefreshRules.Freeze(content, [item], []).Single();
        await library.SaveAsync(Fixtures.Root, first.Record.Recipe, "Autre catégorie", null, 1, "update", null, None);
        QueryRefreshRules.Confirm(await library.ReadAsync(Fixtures.Root, None), frozen);
        Check.Equal(1L, frozen.Revision, "révision initiale toujours liée, aucune adoption de la suivante");
        Check.Throws<DomeniaOperationException>(() => QueryRefreshRules.Freeze(content, [item with { Key = "absent" }], []), "lien absent refuse tout plan");
        Check.Equal(0, QueryRefreshRules.Freeze(content, [item with { Key = "absent", Paused = true }], []).Length, "widget suspendu ne déclenche aucun plan");
        Check.Equal(0, QueryRefreshRules.Freeze(content, [item with { Key = "absent", Hidden = true }], []).Length, "widget masqué exclu avant résolution de sa recette, aucun plan inutile");
        await library.ArchiveAsync(Fixtures.Root, first.Record.Id, 2, None);
        var archived = await library.ReadAsync(Fixtures.Root, None);
        Check.Throws<DomeniaOperationException>(() => QueryRefreshRules.Confirm(archived, frozen), "archive entre préparation et exécution refuse le réseau");
    }

    [Test]
    public static void Query_refresh_uses_only_frozen_online_identities_and_reuses_fresh_information()
    {
        var a = Fixtures.Computer("PC-A"); var b = Fixtures.Computer("PC-B"); var added = Fixtures.Computer("PC-AJOUTE");
        var directory = Fixtures.Snapshot(computers: [a, b, added]);
        var observations = new FleetObservations(TestClock.Reference, [Fixtures.Observe(a, inventory: Fixtures.Disk(1000, 500, TimeSpan.Zero))]);
        var dataset = Dataset(directory, observations); var compiled = QueryEngine.Compile(Recipe());
        var frozen = new FrozenFleetQuery(compiled.Normalized.Id, 1, compiled.Fingerprint, compiled.Normalized);
        var identities = new[] { a, b }.ToImmutableDictionary(c => c.ObjectGuid, QueryComputerIdentity.Of);
        var online = new HashSet<Guid> { a.ObjectGuid, b.ObjectGuid, added.ObjectGuid };
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        var requests = QueryRefreshRules.Requests(frozen, dataset, scope, identities, online, TestClock.Reference, false);
        Check.Equal(1, requests.Length, "seul le poste figé sans information demande une lecture");
        Check.Equal(b.ObjectGuid, requests[0].Computers.Single(), "nouveau poste exclu même s’il est en ligne");
        Check.True(requests[0].Inventory && !requests[0].Presence, "inventaire demandé, aucun second ping");
        var forced = QueryRefreshRules.Requests(frozen, dataset, scope, identities, online, TestClock.Reference, true);
        Check.Equal(2, forced.Length, "Tout relire garde la population figée");
        Check.Equal(0, QueryRefreshRules.Requests(frozen, dataset, scope, identities, new HashSet<Guid>(), TestClock.Reference, true).Length, "aucune WMI sans ping positif du plan");
        Check.Equal(2, QueryRefreshRules.Requests(frozen, dataset, scope, identities, online, TestClock.Reference, false, cacheMinutes: 0).Length, "réglage zéro respecte la relecture même hors Tout relire");
        var moved = b with { DistinguishedName = "CN=PC-B,OU=Autre," + Fixtures.Root };
        var changed = dataset with { Directory = Fixtures.Snapshot(computers: [a, moved, added]) };
        Check.Throws<DomeniaOperationException>(() => QueryRefreshRules.Requests(frozen, changed, new ScopeSelection(Fixtures.Root, "Domaine", true), identities, online, TestClock.Reference, true), "déplacement après plan refusé");
        Check.False(identities[b.ObjectGuid].Matches(b with { WhenCreated = b.WhenCreated.AddSeconds(1) }), "réincarnation du GUID refusée");
        Check.False(identities[b.ObjectGuid].Matches(b with { DnsHostName = "autre.test.local" }), "cible DNS remplacée refusée");
    }

    [Test]
    public static async Task Real_query_widget_prepares_an_explicit_refresh_stage_in_simulation()
    {
        var bridge = new SimulatedBridge();
        var session = await bridge.Source.GetSessionAsync(None);
        await WorkingScope.From(bridge.Context).SetAsync(session, await RequetesOperationsTests.WorkstationsOuAsync(bridge), true, None);
        var root = session.Domain?.RootDn ?? throw new TestFailureException("Domaine de simulation absent.");
        var library = RequetesServices.Library(bridge.Context); var service = AccueilService.From(bridge.Context);
        var saved = await library.SaveAsync(root, Recipe(), null, null, 0, "update", null, None);
        var linked = await service.BindQueryAsync(saved.Record.Id, 1, None);
        await service.SaveLayoutAsync([linked.Item], None);
        var plan = await service.PlanRefreshAsync("inventory", None);
        Check.True(plan.Stages.Any(s => s.Id == "queries"), "vraie collecte complémentaire préparée, pas refus inconditionnel");
        Check.True(plan.Warnings.Any(w => w.Contains(saved.Record.Fingerprint[..12], StringComparison.Ordinal)), "empreinte confirmée visible dans le plan");
        var version = (await bridge.Context.Readers.Find<IQueryWorkshopReader>()!.DatasetAsync(None)).Version;
        _ = await service.PlanRefreshAsync("inventory", None);
        Check.Equal(version, (await bridge.Context.Readers.Find<IQueryWorkshopReader>()!.DatasetAsync(None)).Version, "préparer deux plans ne collecte rien");
    }
    [Test]
    public static async Task Frozen_presence_measures_only_selected_computers_and_refuses_replaced_identity()
    {
        var bridge = new SimulatedBridge();
        var session = await bridge.Source.GetSessionAsync(None);
        var dn = await RequetesOperationsTests.WorkstationsOuAsync(bridge);
        var scope = new ScopeSelection(dn, "Postes", true);
        var before = await bridge.Source.ReadLocalAsync(None);
        var chosen = before.Directory.Computers.First(c => ScopeRules.Contains(scope, c.DistinguishedName) && !AdValues.IsDisabled(c.UserAccountControl));
        var identities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(chosen.ObjectGuid, QueryComputerIdentity.Of(chosen));
        var reader = bridge.Context.Readers.Find<IAccueilReader>() ?? throw new TestFailureException("Lecteur Accueil absent.");
        var after = await reader.ReadPresenceAsync(scope, identities, session.Epoch, None);
        Check.Equal(TestClock.Reference, after.Observations.Workstations.Single(o => o.ComputerGuid == chosen.ObjectGuid).Presence.CheckedAt, "poste explicitement sélectionné mesuré");
        var previous = before.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        Check.True(after.Observations.Workstations.Where(o => o.ComputerGuid != chosen.ObjectGuid).All(o => previous[o.ComputerGuid] == o), "dates et valeurs des postes non sélectionnés intactes");
        var replaced = identities.SetItem(chosen.ObjectGuid, identities[chosen.ObjectGuid] with { Created = chosen.WhenCreated.AddSeconds(1) });
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadPresenceAsync(scope, replaced, session.Epoch, None), "réincarnation refuse avant mesure");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadInventoryAsync(scope, identities, session.Epoch + 1, None), "nouvelle session ne rejoue pas un ancien plan");
    }

}
