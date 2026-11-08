using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class SearchCampaignStopTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(5);

    [Test]
    public static async Task Stopped_partial_batch_keeps_only_the_unacknowledged_target_for_resume()
    {
        using var x = new Fixture(); var plan = await x.Plan();
        var running = x.Service.SurveyRunAsync(plan.PlanId, null, p => x.RunId = p.RunId, None);
        try
        {
            await Task.WhenAll(x.Source.Saved.Task, x.Source.SecondStarted.Task).WaitAsync(Deadline);
            Check.True(x.Service.Stop(x.RunId!).Stopped, "arrêt de la campagne réelle");
            await x.Source.Cancelled.Task.WaitAsync(Deadline);
            Check.False(running.IsCompleted, "annulation ne termine pas la lecture physique retenue");
            var another = await x.Plan();
            var busy = await Check.ThrowsAsync<DomeniaOperationException>(() => x.Service.SurveyRunAsync(another.PlanId, null, _ => { }, None), "admission encore occupée");
            Check.Equal(SearchErrors.SurveyBusy, busy.Code, "pas de libération anticipée");
            x.Source.ReleaseSecond.TrySetResult(); var result = await running.WaitAsync(Deadline);
            Check.Equal(1, result.Done, "premier résultat acquitté conservé malgré Task.WhenAll interrompu");
            Check.Equal(1, result.Resume!.Remaining, "seconde cible seulement");
            var resumed = await x.Service.SurveyPlanAsync(SurveyMode.Ping, plan.ListId, [], SurveyScope.Selection, true, None);
            Check.Equal(x.Source.Second.ToString("D"), resumed.Targets.Single().Id, "GUID non acquitté requalifié");
            Check.True(x.Source.Recorded.SetEquals([x.Source.First]), "acquittement du recorder inchangé");
            Check.True(x.Source.FinishedInterrupted, "fin interrompue enregistrée");
        }
        finally { x.Service.Stop(x.RunId ?? ""); x.Source.ReleaseSecond.TrySetResult(); await Observe(running); }
    }

    [Test]
    public static async Task Service_closure_requests_cancellation_but_waits_for_physical_end_and_final_record()
    {
        using var x = new Fixture(); var plan = await x.Plan();
        var running = x.Service.SurveyRunAsync(plan.PlanId, null, p => x.RunId = p.RunId, None);
        try
        {
            await Task.WhenAll(x.Source.Saved.Task, x.Source.SecondStarted.Task).WaitAsync(Deadline);
            x.Service.Dispose();
            await x.Source.Cancelled.Task.WaitAsync(Deadline);
            Check.False(running.IsCompleted, "fermeture n’annonce pas une fin physique");
            Check.Equal(0, x.Source.Finishes, "pas de clôture du journal avant le retour du lecteur");
            await Check.ThrowsAsync<ObjectDisposedException>(() => x.Service.SurveyRunAsync(plan.PlanId, null, _ => { }, None), "aucun nouveau départ après fermeture");
            x.Source.ReleaseSecond.TrySetResult(); var result = await running.WaitAsync(Deadline);
            Check.True(result.Stopped, "arrêt réellement observé");
            Check.Equal(1, result.Done, "résultat déjà acquitté conservé");
            Check.Equal(1, x.Source.Finishes, "fin du journal après la fin physique");
        }
        finally { x.Source.ReleaseSecond.TrySetResult(); await Observe(running); }
    }

    [Test]
    public static async Task Failed_progress_is_not_silently_included_in_the_next_commit()
    {
        using var x = new Fixture(); x.Source.FailFirstSave = true; x.Source.CancelSecond = false;
        var plan = await x.Plan(); var running = x.Service.SurveyRunAsync(plan.PlanId, null, p => x.RunId = p.RunId, None);
        try
        {
            await Task.WhenAll(x.Source.SaveAttempted.Task, x.Source.SecondStarted.Task).WaitAsync(Deadline);
            x.Source.ReleaseSecond.TrySetResult();
            await Check.ThrowsAsync<InvalidDataException>(() => running, "échec du premier acquittement remonté");
            Check.Equal(2, x.Source.ProgressCalls, "deux réponses physiques ont atteint le recorder");
            Check.True(x.Source.Recorded.SetEquals([x.Source.Second]), "la seconde écriture ne prétend pas acquitter la première");
            Check.True(x.Source.FinishedInterrupted, "journal partiel conservé");
        }
        finally { x.Service.Stop(x.RunId ?? ""); x.Source.ReleaseSecond.TrySetResult(); await Observe(running); }
    }

    private static async Task Observe(Task task) { try { await task.WaitAsync(Deadline); } catch { /* Preserve the assertion failure, but release all local fixture barriers. */ } }
    private sealed class Fixture : IDisposable
    {
        public CampaignSearchSource Source { get; }
        public EngineContext Context { get; }
        public SearchService Service { get; }
        public string? RunId { get; set; }
        private string? listId;
        private Guid[] ids = [];
        public Fixture()
        {
            var clock = TestClock.Fixed(); Source = new(new(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock));
            Context = new(SimulatedBridge.Decision, Source, new MemoryPreferenceStore(), clock, new RecordingJournal(),
                ScreenReaders.Discover(Source, [typeof(CampaignSearchReader).Assembly]));
            Service = SearchService.From(Context);
        }
        public async Task<BoundPlan> Plan()
        {
            if (listId is null)
            {
                const string scope = "OU=Paris,OU=Postes,DC=example,DC=local";
                var found = await Service.BrowseAsync(scope, true, SearchTypeFilter.Computers, 20, None); listId = found.ListId;
                ids = Source.Inner.CurrentDirectory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(new(scope, "Paris", true), c.DistinguishedName))
                    .Where(c => found.Rows.Any(r => r.Id == c.ObjectGuid.ToString("D"))).Take(2).Select(c => c.ObjectGuid).ToArray();
                Check.Equal(2, ids.Length, "deux cibles réelles de la simulation sont dans la liste");
                Source.First = ids[0]; Source.Second = ids[1];
            }
            var plan = await Service.SurveyPlanAsync(SurveyMode.Ping, listId, ids, SurveyScope.Selection, false, None);
            Check.True(plan.Admission.Allowed, "vrai plan admis"); Check.Equal(2, plan.Targets.Length, "les deux cibles sont qualifiées");
            return new(plan.PlanId, listId);
        }
        public void Dispose() { Service.Dispose(); Source.ReleaseSecond.TrySetResult(); Context.Dispose(); }
    }
    private sealed record BoundPlan(string PlanId, string ListId);
}

public sealed class CampaignSearchSource(SimulatedDirectorySource inner) : IDirectorySource
{
    public SimulatedDirectorySource Inner { get; } = inner;
    public Guid First { get; set; }
    public Guid Second { get; set; }
    public bool FailFirstSave { get; set; }
    public bool CancelSecond { get; set; } = true;
    public TaskCompletionSource Saved { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource SaveAttempted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource SecondStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource Cancelled { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource ReleaseSecond { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public HashSet<Guid> Recorded { get; set; } = [];
    public int ProgressCalls { get; set; }
    public int Finishes { get; set; }
    public bool FinishedInterrupted { get; set; }
    public DirectorySourceKind Kind => Inner.Kind;
    public Task<SessionSnapshot> GetSessionAsync(CancellationToken token) => Inner.GetSessionAsync(token);
    public Task<DirectoryState> ReadLocalAsync(CancellationToken token) => Inner.ReadLocalAsync(token);
    public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken token) => Inner.RefreshAsync(family, scope, token);
}

/// <summary>Real simulated reads plus explicitly held physical completion and acknowledgement barriers; no network.</summary>
public sealed class CampaignSearchReader(CampaignSearchSource source) : ISearchReader, IOperationsReader, IOperationsCollectionRecorder
{
    private readonly SimulatedSearchReader search = new(source.Inner);
    private readonly SimulatedOperationsReader operations = new(source.Inner);
    public Task<SearchPage> FindAsync(SearchQuery query, CancellationToken token) => search.FindAsync(query, token);
    public Task<ImmutableArray<SearchContainer>> ContainersAsync(bool counts, CancellationToken token) => search.ContainersAsync(counts, token);
    public Task<SearchPage> CachedAsync(SearchQuery query, CancellationToken token) => search.CachedAsync(query, token);
    public Task<SearchPage> FindAddressAsync(SearchAddress address, int limit, CancellationToken token) => search.FindAddressAsync(address, limit, token);
    public Task<(SearchPage Page, SearchVerdictTotals Totals)> LocalQueryAsync(string queryId, string baseDn, bool subtree, string verdict, int limit, CancellationToken token) => search.LocalQueryAsync(queryId, baseDn, subtree, verdict, limit, token);
    public Task<ImmutableArray<SearchSuggestion>> SuggestAsync(string text, SearchTypeFilter type, int max, CancellationToken token) => search.SuggestAsync(text, type, max, token);
    public Task<SearchPreview?> PreviewAsync(Guid id, CancellationToken token) => search.PreviewAsync(id, token);
    public Task<SearchComparison> CompareAsync(IReadOnlyList<Guid> ids, CancellationToken token) => search.CompareAsync(ids, token);
    public Task<ImmutableArray<SearchRow>> LocalRowsAsync(IReadOnlyList<Guid> ids, CancellationToken token) => search.LocalRowsAsync(ids, token);
    public Task<ImmutableArray<SearchRow>> RereadAsync(IReadOnlyList<Guid> ids, CancellationToken token) => search.RereadAsync(ids, token);
    public Task<string?> ReverseDnsAsync(string ipv4, CancellationToken token) => search.ReverseDnsAsync(ipv4, token);
    public Task<ImmutableArray<SearchLegacySaved>> LegacySavedSearchesAsync(CancellationToken token) => search.LegacySavedSearchesAsync(token);
    public Task<NetworkDiagnosticLine> DiagnoseAsync(Guid id, CancellationToken token) => search.DiagnoseAsync(id, token);
    public async Task<SurveyOutcome> ProbeAsync(Guid id, SurveyMode mode, int run, TimeSpan inventoryReuse, CancellationToken token)
    {
        if (id == source.Second)
        {
            using var cancelled = token.Register(() => source.Cancelled.TrySetResult());
            source.SecondStarted.TrySetResult();
            await source.ReleaseSecond.Task;
            if (source.CancelSecond) { token.ThrowIfCancellationRequested(); }
        }
        return await search.ProbeAsync(id, mode, run, inventoryReuse, token);
    }
    public Task BeginCollectionAsync(string id, ScopeSelection scope, SurveyMode mode, ImmutableArray<SurveyTarget> targets, CancellationToken token) => Task.CompletedTask;
    public Task ProgressCollectionAsync(string id, ImmutableArray<Guid> completed, int failed, CancellationToken token)
    {
        source.ProgressCalls++; source.SaveAttempted.TrySetResult();
        if (source.FailFirstSave && source.ProgressCalls == 1) { throw new InvalidDataException("Acquittement de fixture refusé avant publication."); }
        source.Recorded = completed.ToHashSet(); source.Saved.TrySetResult(); return Task.CompletedTask;
    }
    public Task FinishCollectionAsync(string id, bool interrupted, CancellationToken token)
    { source.Finishes++; source.FinishedInterrupted = interrupted; return Task.CompletedTask; }
    public Task<CollectionRunsView> RunsAsync(CancellationToken token) => operations.RunsAsync(token);
    public SurveyState? CurrentSurvey() => operations.CurrentSurvey();
    public Task<SurveyState> ResumeSurveyAsync(int remaining, CancellationToken token) => operations.ResumeSurveyAsync(remaining, token);
    public SurveyState? StopSurvey() => operations.StopSurvey();
    public Task<SurveyOffer?> ForgetSurveyAsync(CancellationToken token) => operations.ForgetSurveyAsync(token);
    public SurveyOffer? PostponeSurvey() => operations.PostponeSurvey();
    public Task<ImmutableArray<ProviderState>> ProviderStatesAsync(CancellationToken token) => operations.ProviderStatesAsync(token);
    public Task<ImmutableArray<OperationSample>> HistoryAsync(CancellationToken token) => operations.HistoryAsync(token);
    public Task<ImmutableArray<CheckRow>> CheckDirectoryAsync(bool full, CancellationToken token) => operations.CheckDirectoryAsync(full, token);
    public string CollectionProfile => operations.CollectionProfile;
}
