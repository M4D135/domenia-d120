using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Tests;

internal static class AccueilOperationsBatchTests
{
    [Test]
    public static async Task Active_home_refresh_is_projected_and_stale_id_cannot_stop_it()
    {
        var bridge = new SimulatedBridge();
        using var context = bridge.Context;
        await bridge.CallAsync("session.setScope", "{\"dn\":\"OU=Postes,DC=example,DC=local\",\"subtree\":true}");
        var service = AccueilService.From(context);
        var plan = await service.PlanRefreshAsync("presence", CancellationToken.None);
        SurveyState? observed = null;
        await service.RunRefreshAsync(plan.Id, false, progress =>
        {
            if (progress.State != "running" || observed is not null) { return; }
            observed = service.OperationsRefresh();
            Check.NotNull(observed, "lot Accueil visible dès le début réel de l’étape");
            Check.Equal("accueil-" + plan.Id, observed!.Id, "identifiant lié à ce plan et séparé des relevés Recherche");
            Check.True(observed.Open, "lot toujours actif");
            Check.Equal(-1, observed.Done, "progression inconnue ne devient pas zéro terminé");
            Check.Throws<DomeniaOperationException>(() => service.StopOperationsRefresh("accueil-" + WritePlans.NewId()), "ancien ID ne stoppe pas ce lot");
            Check.False(service.OperationsRefresh()!.StopRequested, "lot actuel intact après refus");
            Check.True(service.StopOperationsRefresh(observed.Id).StopRequested, "arrêt exact accepté");
        }, CancellationToken.None);
        Check.NotNull(observed, "étape réellement observée");
        Check.Null(service.OperationsRefresh(), "lot retiré après fin effective, pas au clic Arrêter");
    }

    [Test]
    public static async Task Home_batch_remains_visible_through_persistence_and_alongside_a_list_survey()
    {
        var store = new BlockingRunsStore();
        var bridge = new SimulatedBridge(preferences: store);
        using var context = bridge.Context;
        await bridge.CallAsync("session.setScope", "{\"dn\":\"OU=Postes,DC=example,DC=local\",\"subtree\":true}");
        var initial = SimulatedBridge.Json(await bridge.CallAsync("operations.runs"));
        var count = initial.GetProperty("offer").GetProperty("remaining").GetInt32();
        await bridge.CallAsync("operations.survey.resume", JsonSerializer.Serialize(new { remaining = count }));
        var service = AccueilService.From(context);
        var plan = await service.PlanRefreshAsync("presence", CancellationToken.None);
        var running = service.RunRefreshAsync(plan.Id, false, _ => { }, CancellationToken.None);
        await store.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        try
        {
            var home = service.OperationsRefresh();
            Check.NotNull(home, "fin des sondes ne retire pas le lot avant la sauvegarde");
            Check.Equal(SurveyPhase.Saving, home!.Phase, "phase d’enregistrement réelle");
            Check.Equal(1, home.PendingSaves, "un enregistrement effectivement en attente");
            var view = SimulatedBridge.Json(await bridge.CallAsync("operations.runs"));
            Check.Equal(2, view.GetProperty("active").GetArrayLength(), "Accueil et relevé de liste visibles ensemble");
            var activity = SimulatedBridge.Json(await bridge.CallAsync("operations.activity"));
            Check.Equal(2, activity.GetProperty("open").EnumerateArray().Count(r => r.GetProperty("kind").GetString() == "batch"), "deux tâches scalaires, aucune cible publiée");
            var bad = await bridge.CallAsync("operations.survey.stop", JsonSerializer.Serialize(new { id = "accueil-" + WritePlans.NewId() }));
            Check.Equal(OperationActivity.TaskUnknown, bad.Error!.Code, "arrêt UI lié au lot réellement affiché");
            Check.True(service.OperationsRefresh()!.Open, "persistance encore active après refus");
        }
        finally { store.Release.TrySetResult(); }
        await running;
        Check.Null(service.OperationsRefresh(), "disparaît seulement quand la sauvegarde est revenue");
    }

    private sealed class BlockingRunsStore : IPreferenceStore
    {
        private readonly MemoryPreferenceStore memory = new();
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Persistent => true;
        public bool TryGet(string key, out JsonElement value) => memory.TryGet(key, out value);
        public async Task SetAsync(string key, JsonElement? value, CancellationToken cancellationToken)
        {
            if (key.StartsWith(AccueilService.RunsPreference, StringComparison.Ordinal))
            { Started.TrySetResult(); await Release.Task.WaitAsync(cancellationToken).ConfigureAwait(false); }
            await memory.SetAsync(key, value, cancellationToken).ConfigureAwait(false);
        }
    }
}
