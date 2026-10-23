using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class OperationsMeasurementsTests
{
    [Test]
    public static void Publication_requires_a_finished_correlated_request_and_accepts_only_one_finite_interval()
    {
        var activity = new OperationActivity(TestClock.Fixed(), new RecordingJournal(), false);
        using var task = activity.Begin("fiche.read", TaskKind.NetworkRead, CancellationToken.None, "request-one");
        Check.False(activity.RecordPublication("request-one", 10), "une tâche ouverte n’a pas publié sa réponse");
        task.Complete(TaskOutcome.Succeeded, null, 1);
        Check.False(activity.RecordPublication("other", 10), "aucune autre requête attribuée");
        Check.False(activity.RecordPublication("request-one", double.NaN), "NaN refusé");
        Check.False(activity.RecordPublication("request-one", 60001), "mesure bornée");
        Check.True(activity.RecordPublication("request-one", 42), "intervalle de publication corrélé");
        Check.False(activity.RecordPublication("request-one", 99), "un doublon ne remplace pas la mesure");
        var row = activity.Snapshot().Recent.Single();
        var publication = row.Phases.Single(p => p.Phase == "publish");
        Check.True(publication.Measured, "phase mesurée"); Check.Equal(42d, publication.DurationMs, "valeur exacte");
        Check.Contains("attente de rendu", publication.Detail, "limite de l’intervalle dite");
        Check.False(row.Text.Contains("Publication dans l’interface non mesurée", StringComparison.Ordinal), "texte cohérent");
    }

    [Test]
    public static async Task Native_busy_is_counted_in_its_session_and_restored_after_nested_scope()
    {
        var first = new OperationActivity(TestClock.Fixed(), new RecordingJournal(), false);
        var second = new OperationActivity(TestClock.Fixed(), new RecordingJournal(), false);
        using var folder = new TemporaryFolder();
        using var blocker = new SqliteDatabase(folder.File("busy.db"), false);
        blocker.Script("CREATE TABLE items(id INTEGER);"); blocker.Begin();
        using (OperationsMeasurements.Enter(first))
        {
            await Task.Run(() =>
            {
                using var connection = new SqliteDatabase(folder.File("busy.db"), false, busyTimeoutMs: 100);
                Check.Throws<SqliteStoreException>(() => connection.Execute("INSERT INTO items VALUES(1)"), "writer occupé");
            });
            using (OperationsMeasurements.Enter(second)) { OperationsMeasurements.RecordSqliteBusy(); }
            OperationsMeasurements.RecordSqliteBusy();
        }
        OperationsMeasurements.RecordSqliteBusy();
        Check.Equal(2, first.SqliteBusy.Count, "connexion native et retour au premier contexte");
        Check.Equal(1, second.SqliteBusy.Count, "contexte imbriqué isolé");
        Check.Equal(0L, first.InventoriesReused, "aucune économie inventée");
        first.RecordInventoryReused(); Check.Equal(1L, first.InventoriesReused, "inventaire réellement réutilisé");
    }
}
