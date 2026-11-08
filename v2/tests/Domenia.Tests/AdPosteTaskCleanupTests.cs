using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class AdPosteTaskCleanupTests
{
    private static WritePlan Bind(AdPosteTaskCleanupExecutor executor, WritePlanDraft draft, AdDirectorySource source)
    {
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, source.Clock.GetUtcNow(), source.Zone);
        executor.Bind(draft, plan); return plan;
    }

    [Test]
    public static async Task Cleanup_journal_is_local_and_explicit_plan_cannot_restart_the_read()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var remote = RemoteTaskReadRunner.PreparePlan(Fixtures.Computer("PC1"), db.StoreId, @"TEST\operator", Fixtures.Now);
        await db.PrepareTaskReadAsync(remote, CancellationToken.None);
        await db.CompleteTaskReadAsync(remote.Id, 1, new(Fixtures.Now, true, true, false, "Réponse reçue, fichiers restants.") { ExecutionId = Guid.NewGuid() }, CancellationToken.None);
        var reader = new AdPosteReader(source); var reads = ldap.Searches.Count;
        Check.Equal(remote.Id, (await reader.PendingTaskReadsAsync(remote.ComputerDn, CancellationToken.None)).Single().Id, "opération locale affichée");
        Check.Equal(reads, ldap.Searches.Count, "affichage sans LDAP");
        var backend = new RemoteTaskReadTests.Backend(remote);
        var executor = new AdPosteTaskCleanupExecutor(source) { RunnerFactory = () => new(source.Clock) { BackendOverride = (_, _) => backend } };
        var draft = await executor.PlanAsync(remote.ComputerDn, remote.Id, CancellationToken.None);
        Check.Equal("pc1", draft.Confirmation.TypedName?.ToLowerInvariant(), "confirmation du poste exact");
        Check.Equal(0, backend.RecoveryConnections + backend.Starts, "plan sans contact machine");
        var plan = Bind(executor, draft, source);
        Check.True((await executor.CheckAsync(plan, CancellationToken.None)).Current, "plan encore courant");
        Check.Equal(WriteResult.Applied, (await executor.ExecuteAsync(plan, CancellationToken.None)).Result, "nettoyage confirmé");
        Check.Equal(0, backend.Starts + backend.Preflights, "aucune lecture rejouée");
        Check.Equal(1, backend.RecoveryConnections, "une connexion de nettoyage");
        var fresh = new AdPosteTaskCleanupExecutor(source);
        Check.Equal(VerificationState.Verified, (await fresh.VerifyAsync(plan, CancellationToken.None)).State, "vérification durable sans préparation en mémoire");
        Check.True((await db.ReadTaskReadAsync(remote.Id, CancellationToken.None))!.Completion!.ResultReceived, "résultat original conservé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "plan consommé non rejoué");
    }

    [Test]
    public static async Task Cleanup_refuses_new_DC_status_or_unreadable_flags_before_contacting_the_machine()
    {
        foreach (var unreadable in new[] { false, true })
        {
            using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
            var pc = Fixtures.Computer("PC1"); var remote = RemoteTaskReadRunner.PreparePlan(pc, db.StoreId, @"TEST\operator", Fixtures.Now);
            await db.PrepareTaskReadAsync(remote, CancellationToken.None);
            var executor = new AdPosteTaskCleanupExecutor(source) { RunnerFactory = () => throw new InvalidOperationException("Aucun contact autorisé.") };
            var entry = AdPosteNetworkTests.Entry(pc with { UserAccountControl = pc.UserAccountControl | 8192 });
            if (unreadable) { entry = new(entry.DistinguishedName, entry.AttributeNames.Where(n => n != "userAccountControl").ToDictionary(n => n, entry.Raw)); }
            ldap.SearchAnswer = _ => [entry];
            await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanAsync(remote.ComputerDn, remote.Id, CancellationToken.None), "rôle machine non confirmé");
            Check.Equal(1L, (await db.ReadTaskReadAsync(remote.Id, CancellationToken.None))!.Revision, "journal inchangé");
        }
    }

    [Test]
    public static async Task Cleanup_plan_is_bound_to_operator_and_expires_without_mutating_the_pending_record()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var remote = RemoteTaskReadRunner.PreparePlan(Fixtures.Computer("PC1"), db.StoreId, @"TEST\operator", Fixtures.Now);
        await db.PrepareTaskReadAsync(remote, CancellationToken.None);
        var executor = new AdPosteTaskCleanupExecutor(source); var draft = await executor.PlanAsync(remote.ComputerDn, remote.Id, CancellationToken.None);
        var wrong = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\another", AppMode.Directory, source.Clock.GetUtcNow(), source.Zone);
        Check.Throws<DomeniaOperationException>(() => executor.Bind(draft, wrong), "autre opérateur refusé");
        var plan = Bind(executor, draft, source); ((FixedTimeProvider)source.Clock).Advance(WritePlans.Lifetime + TimeSpan.FromSeconds(1));
        Check.False((await executor.CheckAsync(plan, CancellationToken.None)).Current, "plan périmé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "plan périmé non envoyé");
        Check.Equal(1L, (await db.ReadTaskReadAsync(remote.Id, CancellationToken.None))!.Revision, "aucune annulation implicite de l’attente");
    }

    [Test]
    public static async Task Cleanup_detects_a_concurrent_receipt_change_and_recreated_directory_identity()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var pc = Fixtures.Computer("PC1"); var remote = RemoteTaskReadRunner.PreparePlan(pc, db.StoreId, @"TEST\operator", Fixtures.Now);
        await db.PrepareTaskReadAsync(remote, CancellationToken.None);
        var executor = new AdPosteTaskCleanupExecutor(source) { RunnerFactory = () => throw new InvalidOperationException("Plan périmé : aucun contact.") };
        var plan = Bind(executor, await executor.PlanAsync(remote.ComputerDn, remote.Id, CancellationToken.None), source);
        await db.CompleteTaskReadAsync(remote.Id, 1, new(Fixtures.Now, false, false, false, "Autre exécution revendiquée.") { ExecutionId = Guid.NewGuid() }, CancellationToken.None);
        Check.False((await executor.CheckAsync(plan, CancellationToken.None)).Current, "nouveau reçu détecté");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "ancien plan sans effet");
        ldap.SearchAnswer = _ => [AdPosteNetworkTests.Entry(pc with { ObjectGuid = Guid.NewGuid() })];
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanAsync(remote.ComputerDn, remote.Id, CancellationToken.None), "même DN recréé refusé");
    }
}
