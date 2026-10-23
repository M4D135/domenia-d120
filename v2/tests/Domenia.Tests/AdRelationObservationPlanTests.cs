using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdRelationObservationPlanTests
{
    private static StoredRelation Observation(string computer = "PC1") => new("alice", Fixtures.User("alice").ObjectGuid, Fixtures.User("alice").DistinguishedName,
        computer, Fixtures.Computer(computer).ObjectGuid, Fixtures.Computer(computer).DistinguishedName, RelationKind.Console, "Console CIM/DCOM",
        Fixtures.Now.AddMinutes(-1), "Observation native qualifiée", true, null, null);
    private static WritePlan Bind(IRelationChangeExecutor executor, WritePlanDraft draft, AdDirectorySource source)
    {
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, source.Clock.GetUtcNow(), source.Zone);
        ((IWritePlanBinder)executor).Bind(draft, plan); return plan;
    }

    [Test]
    public static async Task Native_relation_executor_is_discovered_and_saves_shared_observations_in_confirmed_64_item_batches()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        using var writers = WriteExecutors.Discover(source, [typeof(AdDirectorySource).Assembly]); var executor = writers.Require<IRelationChangeExecutor>();
        var session = AdRelationSession.For(source);
        for (var i = 1; i <= 65; i++) { session.ObserveValidated(Observation("PC" + i), source.Epoch); }
        var first = await executor.PlanObservationsAsync(RelationChange.SessionResultId, [], CancellationToken.None);
        Check.Equal(64, first.Changes.Length, "premier lot borné"); var firstPlan = Bind(executor, first, source); await executor.ExecuteAsync(firstPlan, CancellationToken.None);
        Check.False((await executor.CheckAsync(firstPlan, CancellationToken.None)).Current, "préparation consommée et libérée après envoi");
        var next = await executor.PlanObservationsAsync(RelationChange.SessionResultId, [], CancellationToken.None);
        Check.Equal(1, next.Changes.Length, "suite seulement"); await executor.ExecuteAsync(Bind(executor, next, source), CancellationToken.None);
        Check.Equal(65L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "65 observations durables");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanObservationsAsync(RelationChange.SessionResultId, [], CancellationToken.None), "rien à rejouer");
        Check.Equal(0, ldap.Searches.Count, "confirmation locale sans relecture réseau implicite");
    }

    [Test]
    public static async Task Observation_plans_never_replace_declarations_or_more_recent_stored_readings()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source) VALUES('PC1','bob','PC1','Saisie manuelle');"); }
        var session = AdRelationSession.For(source); session.ObserveValidated(Observation(), source.Epoch);
        using var executor = new AdRelationChangeExecutor(source);
        var draft = await executor.PlanObservationsAsync(RelationChange.SessionResultId, [RelationRules.Key(Observation())], CancellationToken.None);
        await executor.ExecuteAsync(Bind(executor, draft, source), CancellationToken.None);
        Check.Equal(2L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "déclaration conservée à côté de l’observation");
        var old = Observation() with { When = Fixtures.Now.AddDays(-1), Details = "Ancien relevé" };
        var held = AdRelationResults.For(source).Remember(id => new AdRelationObservationSet(id, "Ancien relevé", ImmutableDictionary.CreateRange(StringComparer.Ordinal,
            [KeyValuePair.Create(RelationRules.Key(old), old)])), source.Epoch);
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanObservationsAsync(held.Id, [], CancellationToken.None), "ancienne date ne remplace pas le relevé récent");
        Check.Equal(Observation().When, (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single(r => r.Relation.Kind == RelationKind.Console).Relation.When, "date conservée");
    }

    [Test]
    public static async Task Observation_plan_ids_and_keys_cannot_supply_new_or_unqualified_records()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        using var executor = new AdRelationChangeExecutor(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanObservationsAsync("invented", [], CancellationToken.None), "résultat inventé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanObservationsAsync(RelationChange.SessionResultId, [RelationRules.Key(Observation())], CancellationToken.None), "clé seule ne crée pas une observation");
        var invalid = Observation() with { UserGuid = null };
        var held = AdRelationResults.For(source).Remember(id => new AdRelationObservationSet(id, "Résultat incohérent", ImmutableDictionary.CreateRange(StringComparer.Ordinal,
            [KeyValuePair.Create(RelationRules.Key(invalid), invalid)])), source.Epoch);
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanObservationsAsync(held.Id, [], CancellationToken.None), "identité non qualifiée refusée même dans un résultat interne");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucune ligne fabriquée");
    }
}
