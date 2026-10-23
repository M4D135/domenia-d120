using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class RemoteTaskReadRecoveryTests
{
    [Test]
    public static async Task Cleanup_after_reopening_preserves_received_result_and_never_restarts_the_task()
    {
        using var folder = new TemporaryFolder(); var (db, plan) = await RemoteTaskReadTests.Open(folder);
        var first = new RemoteTaskReadTests.Backend(plan) { CleanupResult = new(true, false, "Répertoire encore présent.") };
        await new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => first }
            .RunAsync(plan, new SqliteDirectoryCache(db), null, _ => Task.FromResult(true), CancellationToken.None);
        var before = (await db.ReadTaskReadAsync(plan.Id, CancellationToken.None))!;
        Check.True(before.Completion!.ResultReceived, "résultat initial conservé");
        Check.True(before.Completion.ExecutionStopped, "arrêt enregistré avant suppression");
        var reopened = new DomeniaDatabase(folder.File("task.db"), Fixtures.Root, TestClock.Fixed());
        var backend = new RemoteTaskReadTests.Backend(plan);
        var result = await new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend }
            .RecoverCleanupAsync(plan, new SqliteDirectoryCache(reopened), null, _ => Task.FromResult(true), CancellationToken.None);
        Check.True(result.ExecutionStopped && result.ArtifactsRemoved, "nettoyage relu et durable");
        Check.Equal(1, backend.RecoveryConnections, "connexion dédiée au nettoyage");
        Check.Equal(0, backend.Preflights + backend.Starts, "aucune préparation de lancement ni exécution");
        var after = (await reopened.ReadTaskReadAsync(plan.Id, CancellationToken.None))!;
        Check.True(after.Completion!.ResultReceived, "réception indépendante du nettoyage");
        Check.Equal(before.Completion.ExecutionId, after.Completion.ExecutionId, "revendication originale préservée");
        Check.Equal(0, (await reopened.PendingTaskReadsAsync(CancellationToken.None)).Length, "attente levée après preuve");
        await new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => throw new InvalidOperationException("Aucun contact après clôture.") }
            .RecoverCleanupAsync(plan, new SqliteDirectoryCache(reopened), null, _ => throw new InvalidOperationException("Aucun nouvel accord."), CancellationToken.None);
    }

    [Test]
    public static async Task Cleanup_of_unclaimed_preparation_cancels_it_atomically_without_contacting_the_host()
    {
        using var folder = new TemporaryFolder(); var (db, plan) = await RemoteTaskReadTests.Open(folder);
        await db.PrepareTaskReadAsync(plan, CancellationToken.None);
        var runner = new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => throw new InvalidOperationException("Aucun artefact créé.") };
        var result = await runner.RecoverCleanupAsync(plan, new SqliteDirectoryCache(db), null, _ => Task.FromResult(true), CancellationToken.None);
        Check.True(result.ArtifactsRemoved, "préparation annulée sans réseau");
        await Check.ThrowsAsync<InvalidDataException>(() => db.CompleteTaskReadAsync(plan.Id, 1,
            new(Fixtures.Now, false, false, false, "Revendication tardive.") { ExecutionId = Guid.NewGuid() }, CancellationToken.None), "ancienne revendication refusée");
    }

    [Test]
    public static async Task Cleanup_requires_same_durable_identity_and_confirmation_before_connecting()
    {
        using var folder = new TemporaryFolder(); var (db, plan) = await RemoteTaskReadTests.Open(folder);
        await db.PrepareTaskReadAsync(plan, CancellationToken.None);
        var runner = new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => throw new InvalidOperationException("Aucun contact autorisé.") };
        var altered = await runner.RecoverCleanupAsync(plan with { Account = @"TEST\another" }, new SqliteDirectoryCache(db), null, _ => Task.FromResult(true), CancellationToken.None);
        Check.False(altered.ArtifactsRemoved, "autre identité refusée");
        var denied = await runner.RecoverCleanupAsync(plan, new SqliteDirectoryCache(db), null, _ => Task.FromResult(false), CancellationToken.None);
        Check.False(denied.ArtifactsRemoved, "confirmation requise");
        Check.Equal(1L, (await db.ReadTaskReadAsync(plan.Id, CancellationToken.None))!.Revision, "préparation intacte");
    }

    [Test]
    public static async Task Unconfirmed_cleanup_keeps_operation_pending_and_cannot_erase_previous_stop_evidence()
    {
        using var folder = new TemporaryFolder(); var (db, plan) = await RemoteTaskReadTests.Open(folder);
        await db.PrepareTaskReadAsync(plan, CancellationToken.None);
        var stopped = new RemoteTaskReadCompletion(Fixtures.Now, true, true, false, "Arrêt prouvé, artefacts restants.") { ExecutionId = Guid.NewGuid() };
        await db.CompleteTaskReadAsync(plan.Id, 1, stopped, CancellationToken.None);
        var backend = new RemoteTaskReadTests.Backend(plan) { CleanupResult = new(false, false, "Propriété non confirmée.") };
        var result = await new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend }
            .RecoverCleanupAsync(plan, new SqliteDirectoryCache(db), null, _ => Task.FromResult(true), CancellationToken.None);
        Check.False(result.ArtifactsRemoved, "aucune clôture déduite");
        var remaining = (await db.PendingTaskReadsAsync(CancellationToken.None)).Single();
        Check.True(remaining.Completion!.ExecutionStopped && remaining.Completion.ResultReceived, "preuves monotones conservées");
        Check.Equal(0, backend.Starts, "aucune lecture répétée");
    }
}
