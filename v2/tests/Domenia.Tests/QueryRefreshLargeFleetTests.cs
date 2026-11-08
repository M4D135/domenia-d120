using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class QueryRefreshLargeFleetTests
{
    [Test]
    public static void Hundred_thousand_widget_preview_ids_allocate_no_per_host_network_requests()
    {
        var computers = Enumerable.Range(0, 100_000).Select(i => Fixtures.Computer("PREVIEW-" + i)).ToArray();
        var data = Data(computers); var identities = computers.ToDictionary(c => c.ObjectGuid, QueryComputerIdentity.Of);
        var query = QueryEngine.Compile(QueryRecipe.Empty() with { Clauses = [new("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(10))] });
        var frozen = new FrozenFleetQuery(query.Normalized.Id, 1, query.Fingerprint, query.Normalized);
        var selected = identities.Keys.ToHashSet();
        var ids = QueryRefreshRules.MissingTargetIds(frozen, data, new(Fixtures.Postes, "Postes", true), identities, selected,
            Fixtures.Now, 15, CancellationToken.None, new Dictionary<string, int> { ["inventory"] = 300 });
        var before = GC.GetAllocatedBytesForCurrentThread(); var count = 0; var exact = true;
        foreach (var id in ids) { count++; exact &= selected.Contains(id); }
        var allocated = GC.GetAllocatedBytesForCurrentThread() - before;
        Check.Equal(100_000, count, "tous les GUID manquants conservés"); Check.True(exact, "aucune autre identité");
        Check.True(allocated < 256 * 1024, "énumérer les GUID ne crée pas 100000 demandes/tableaux/dictionnaires réseau ; octets=" + allocated);
        var changed = data with { Directory = data.Directory with { Computers = data.Directory.Computers.SetItem(computers.Length - 1, computers[^1] with { WhenCreated = Fixtures.Now }) } };
        Check.Throws<DomeniaOperationException>(() => QueryRefreshRules.MissingTargetIds(frozen, changed, new(Fixtures.Postes, "Postes", true), identities,
            selected, Fixtures.Now, 15, CancellationToken.None, new Dictionary<string, int>()), "dernier poste modifié refuse la préparation entière");
    }

    [Test]
    public static void Widget_query_preview_respects_the_zero_freshness_family_even_with_a_recent_value()
    {
        var computer = Fixtures.Computer("FRESH"); var data = Data([computer]) with
        { Observations = new(Fixtures.Now, [Fixtures.Observe(computer, Fixtures.Presence(true, TimeSpan.Zero), Fixtures.Disk(100, 50, TimeSpan.FromMinutes(1)))]) };
        var query = QueryEngine.Compile(QueryRecipe.Empty() with { Clauses = [new("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(10))] });
        var frozen = new FrozenFleetQuery(query.Normalized.Id, 1, query.Fingerprint, query.Normalized);
        var identities = new Dictionary<Guid, QueryComputerIdentity> { [computer.ObjectGuid] = QueryComputerIdentity.Of(computer) };
        IEnumerable<Guid> Read(int seconds) => QueryRefreshRules.MissingTargetIds(frozen, data, new(Fixtures.Postes, "Postes", true), identities,
            identities.Keys.ToHashSet(), Fixtures.Now, 15, CancellationToken.None, new Dictionary<string, int> { ["inventory"] = seconds });
        Check.Equal(0, Read(300).Count(), "inventaire récent réutilisé");
        Check.True(Read(0).SequenceEqual([computer.ObjectGuid]), "famille à zéro force cette donnée malgré cacheMinutes15");
    }

    [Test]
    public static async Task Hundred_thousand_requests_are_pulled_only_as_bounded_workers_finish()
    {
        const int count = 100_000;
        var produced = 0; var completed = 0; var peakPending = 0;
        IEnumerable<QueryMeasureRequest> Requests()
        {
            for (var i = 0; i < count; i++)
            {
                var ahead = Interlocked.Increment(ref produced) - Volatile.Read(ref completed);
                peakPending = Math.Max(peakPending, ahead);
                yield return new([Fixtures.IdOf("LARGE-" + i)], false, true, false, []);
            }
        }
        var reader = new Reader(async (request, token) =>
        {
            Check.True(request.OnlyOutcome, "aucun dataset global renvoyé par poste");
            Check.True(request.OwnsCampaign && request.ExpectedEpoch == 1, "bail du pipeline explicitement transmis avec son époque");
            await Task.Yield(); token.ThrowIfCancellationRequested();
            Interlocked.Increment(ref completed);
            return new(1, 1, 0, 0, 0, Fixtures.Now);
        });
        var result = await QueryRefreshDispatcher.RunAsync(reader, Requests(), 4, 1, 2, 3, (_, _) => Task.CompletedTask, CancellationToken.None)
            .WaitAsync(TimeSpan.FromSeconds(60));
        Check.Equal(count, result.Answered, "100 000 réponses sans troncature");
        Check.Equal(count, produced, "100 000 demandes créées exactement");
        Check.True(peakPending is > 0 and <= 4, "au plus quatre demandes vivantes, aucune file de 100 000 tâches");
    }

    [Test]
    public static void Hundred_thousand_query_targets_are_planned_in_windows_without_repeated_directory_scans()
    {
        var computers = Enumerable.Range(0, 100_000).Select(i => Fixtures.Computer("BIG-" + i)).ToArray();
        var data = Data(computers);
        var query = QueryEngine.Compile(QueryRecipe.Empty() with { Clauses = [new("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(10))] });
        var frozen = new FrozenFleetQuery(query.Normalized.Id, 1, query.Fingerprint, query.Normalized);
        var identities = computers.ToDictionary(c => c.ObjectGuid, QueryComputerIdentity.Of);
        var requests = QueryRefreshRules.Queue(frozen, data, new(Fixtures.Postes, "Postes", true), identities, identities.Keys.ToHashSet(), Fixtures.Now, false);
        var count = 0;
        foreach (var request in requests)
        {
            Check.True(request.Inventory && !request.Presence, "inventaire manquant seul, pas de second ping");
            Check.Equal(1, request.Computers.Length, "demande unitaire produite à la consommation");
            count++;
        }
        Check.Equal(100_000, count, "population complète");
        var changed = computers.Take(257).ToArray();
        changed[^1] = changed[^1] with { WhenCreated = changed[^1].WhenCreated.AddMinutes(1) };
        Check.Throws<DomeniaOperationException>(() => QueryRefreshRules.Queue(frozen, Data(changed), new(Fixtures.Postes, "Postes", true), identities,
            identities.Keys.ToHashSet(), Fixtures.Now, false), "identité invalide dans la dernière fenêtre refuse la file avant son premier contact");
    }

    [Test]
    public static async Task Hundred_thousand_queue_cancellation_does_not_materialize_the_tail()
    {
        using var stop = new CancellationTokenSource();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var produced = 0; var started = 0;
        IEnumerable<QueryMeasureRequest> Requests()
        {
            for (var i = 0; i < 100_000; i++)
            { Interlocked.Increment(ref produced); yield return new([Fixtures.IdOf("STOP-" + i)], false, true, false, []); }
        }
        var reader = new Reader(async (_, _) =>
        {
            if (Interlocked.Increment(ref started) == 2) entered.TrySetResult();
            await release.Task;
            return new(1, 1, 0, 0, 0, Fixtures.Now);
        });
        var running = QueryRefreshDispatcher.RunAsync(reader, Requests(), 2, 1, 2, 3, (_, _) => Task.CompletedTask, stop.Token);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5)); stop.Cancel();
            Check.False(running.IsCompleted, "les lecteurs physiques gardent leur admission jusqu’à leur fin");
            Check.Equal(2, produced, "la fin de la file n’est même pas construite");
        }
        finally { release.TrySetResult(); }
        await Check.ThrowsAsync<OperationCanceledException>(() => running, "annulation après fin physique");
        Check.Equal(2, started, "aucun autre poste contacté");
    }

    [Test]
    public static async Task Admission_failure_stops_materializing_a_large_queue_without_cancelling_an_authorized_host()
    {
        var produced = 0; var read = 0; var guarded = 0;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var refused = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        IEnumerable<QueryMeasureRequest> Requests()
        {
            for (var i = 0; i < 100_000; i++)
            { Interlocked.Increment(ref produced); yield return new([Fixtures.IdOf("REFUSED-" + i)], false, true, false, []); }
        }
        var reader = new Reader(async (_, token) =>
        {
            Interlocked.Increment(ref read); entered.TrySetResult(); await refused.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check.False(token.IsCancellationRequested, "le refus suivant ne supprime pas le travail autorisé");
            return new(1, 1, 0, 0, 0, Fixtures.Now);
        });
        await Check.ThrowsAsync<DomeniaOperationException>(() => QueryRefreshDispatcher.RunAsync(reader, Requests(), 2, 1, 2, 3, async (_, _) =>
        {
            if (Interlocked.Increment(ref guarded) == 1) return;
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5)); refused.TrySetResult();
            throw new DomeniaOperationException(AccountAccess.EpochChanged, "Contexte remplacé.");
        }, CancellationToken.None), "première erreur transmise après fin du travail physique");
        Check.Equal(1, read, "seul le poste autorisé est contacté");
        Check.True(produced <= 3, "aucune matérialisation de la queue restante après refus");
    }

    [Test]
    public static void Campaign_limits_allow_explicit_large_parks_but_keep_small_defaults_and_finite_deadlines()
    {
        Check.Equal(500, CollectionSettingsRules.Default.Budgets[CollectionSettingsRules.MaxTargets], "défaut prudent conservé");
        Check.Equal(100_000, CollectionSettingsRules.Budget(CollectionSettingsRules.MaxTargets)!.Maximum, "réglage autorise le parc maximal");
        Check.True(SearchSurvey.Admit(100_000, 100_000, false, true, false, true, true, false).Allowed, "sélection explicite 100 000 admise");
        Check.False(SearchSurvey.Admit(100_001, 100_000, false, true, false, true, true, false).Allowed, "borne supérieure conservée");
        Check.Equal(TimeSpan.FromMinutes(10), CollectionCampaignBudget.For(0, 4), "plancher automatique");
        Check.Equal(TimeSpan.FromHours(24), CollectionCampaignBudget.For(100_000, 1), "aucune campagne infinie");
        Check.Equal(TimeSpan.FromMinutes(30), CollectionCampaignBudget.For(100_000, 1, 30), "durée manuelle prioritaire");
    }

    [Test]
    public static void Branch_goals_use_parsed_ancestry_and_do_not_mix_sibling_names_or_escaped_commas()
    {
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        var east = "OU=Est\\, agence," + Fixtures.Postes;
        var west = "OU=Ouest," + Fixtures.Postes;
        var a = Fixtures.Computer("A") with { DistinguishedName = "CN=A,OU=Etage," + east };
        var b = Fixtures.Computer("B") with { DistinguishedName = "CN=B," + west };
        var direct = Fixtures.Computer("DIRECT");
        var groups = CampaignBranches.Summarize(scope, new[] { a, b, direct }.Select(QueryComputerIdentity.Of), new HashSet<Guid> { a.ObjectGuid });
        Check.Equal(3, groups.Length, "deux sous-OU et les postes directs");
        Check.Equal(1, groups.Single(g => g.Scope.Label == "Est, agence").PresenceDone, "objectif affecté à son vrai parent");
        var selected = CampaignBranches.Validate(scope, [new(east, "Est", true), new(Fixtures.Postes, "Direct", false)]);
        Check.True(CampaignBranches.Contains(selected, a.DistinguishedName), "descendant inclus");
        Check.False(CampaignBranches.Contains(selected, b.DistinguishedName), "autre branche exclue");
        Check.Throws<DomeniaOperationException>(() => CampaignBranches.Validate(scope, [new(Fixtures.Postes, "Tout", true), new(east, "Est", true)]), "recouvrement refusé");
    }

    [Test]
    public static void Method_totals_separate_cache_and_monotonic_campaign_time_from_parallel_execution()
    {
        var clock = new Clock(); var metrics = new RefreshPerformance(clock);
        metrics.Add(new(ReadPerformanceMethod.WmiDcom, "Inventory", 50, 200, ReadPerformanceOutcome.Success));
        metrics.Add(new(ReadPerformanceMethod.WmiDcom, "Inventory", 30, 100, ReadPerformanceOutcome.Partial));
        metrics.Add(new(ReadPerformanceMethod.WmiDcom, "Inventory", 999, 999, ReadPerformanceOutcome.Success, CacheHit: true));
        metrics.Reused(42); clock.Ticks = 250;
        var view = metrics.Snapshot(); var row = view.Methods.Single();
        Check.Equal(250L, view.TotalMs, "temps monotone, pas somme des opérations parallèles");
        Check.Equal(2L, row.Reads, "cache séparé des lectures réelles"); Check.Equal(1L, row.CacheHits, "cache compté séparément");
        Check.Equal(80L, row.QueueMs, "attente séparée"); Check.Equal(300L, row.ExecutionMs, "exécution cumulée réelle");
        Check.Equal(1L, row.Incomplete, "partiel ne devient pas réussite"); Check.Equal(42, view.WorkstationsReused, "postes évités distincts des appels natifs");
    }

    private static QueryDataset Data(DirectoryComputer[] computers) => new(Fixtures.Snapshot(computers: computers), new(Fixtures.Now, []),
        ImmutableDictionary<Guid, ImmutableArray<Domenia.Core.Queries.ProbeReading>>.Empty, ImmutableDictionary<Guid, ConsoleReading>.Empty,
        ImmutableDictionary<Guid, char>.Empty, ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>>.Empty, 1, "charge simulée", true);
    private sealed class Reader(Func<QueryMeasureRequest, CancellationToken, Task<QueryMeasureResult>> read) : IQueryWorkshopReader
    {
        public Task<QueryDataset> DatasetAsync(CancellationToken token) => throw new InvalidOperationException("Aucun dataset par poste.");
        public Task<QueryMeasureResult> MeasureAsync(QueryMeasureRequest request, CancellationToken token) => read(request, token);
    }
    private sealed class Clock : TimeProvider
    {
        public long Ticks { get; set; }
        public override long TimestampFrequency => 1000;
        public override long GetTimestamp() => Ticks;
    }
}
