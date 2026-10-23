using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdOperationsReaderTests
{
    [Test]
    public static async Task Operations_cold_reads_neither_create_database_nor_contact_domain()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("operations.db"), Fixtures.Root, TestClock.Fixed());
        using var connection = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection, localStore: new SqliteDirectoryCache(db));
        using var reader = new AdOperationsReader(source);
        var runs = await reader.RunsAsync(CancellationToken.None);
        Check.Equal(0, runs.Rows.Length, "aucun relevé inventé"); Check.Null(runs.Offer, "aucune reprise inventée");
        Check.Equal(0, (await reader.HistoryAsync(CancellationToken.None)).Length, "aucune durée inventée");
        Check.Equal(0, (await reader.ProviderStatesAsync(CancellationToken.None)).Length, "aucun fournisseur bloqué inventé");
        Check.Equal(0, connection.Calls, "aucun contact réseau"); Check.False(File.Exists(db.Path), "base absente reste absente");
    }

    [Test]
    public static async Task Durable_progress_survives_reopen_and_keeps_only_unread_targets()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var db = new DomeniaDatabase(folder.File("operations.db"), Fixtures.Root, clock); var cache = new SqliteDirectoryCache(db);
        using var connection = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", clock, connection: connection, localStore: cache);
        using var reader = new AdOperationsReader(source); var id = Guid.NewGuid().ToString("D"); var targets = Targets();
        await reader.BeginCollectionAsync(id, new(Fixtures.Postes, "Postes", true), SurveyMode.Ping, targets, CancellationToken.None);
        await reader.ProgressCollectionAsync(id, [Guid.Parse(targets[0].Id)], 0, CancellationToken.None);
        await reader.FinishCollectionAsync(id, true, CancellationToken.None);
        var reopened = new DomeniaDatabase(db.Path, Fixtures.Root, clock); var durable = await reopened.ReadOperationsAsync(CancellationToken.None);
        Check.Equal(1, durable.Survey!.Completed.Length, "succès enregistré avant l’interruption");
        using var fresh = new AdOperationsReader(source);
        var runs = await fresh.RunsAsync(CancellationToken.None);
        Check.Equal(1, runs.Offer!.Remaining, "seul le poste non lu est proposé");
        Check.True(runs.Offer.Resumable, "reprise proposée sans démarrer");
        Check.Equal(OperationsCollectionStatus.Cancelled, runs.Rows.Single().Status, "interruption visible");
        Check.Equal(0, connection.Calls, "réouverture sans sondes");
        Check.True(fresh.PostponeSurvey()!.Offered, "plus tard conserve l’offre sans relancer");
        await fresh.ForgetSurveyAsync(CancellationToken.None);
        Check.Null((await reopened.ReadOperationsAsync(CancellationToken.None)).Survey, "abandon supprime seulement le plan");
        Check.Equal(1, (await reopened.ReadOperationsAsync(CancellationToken.None)).Runs.Length, "historique conservé");
    }

    [Test]
    public static async Task Stale_resume_token_is_refused_before_LDAP_or_probe()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("operations.db"), Fixtures.Root, TestClock.Fixed());
        using var connection = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection, localStore: new SqliteDirectoryCache(db));
        using var first = new AdOperationsReader(source); var id = Guid.NewGuid().ToString("D");
        await first.BeginCollectionAsync(id, new(Fixtures.Postes, "Postes", true), SurveyMode.Ping, Targets(), CancellationToken.None);
        await first.FinishCollectionAsync(id, true, CancellationToken.None);
        using var reader = new AdOperationsReader(source); var offer = (await reader.RunsAsync(CancellationToken.None)).Offer!;
        var before = await db.ReadOperationsAsync(CancellationToken.None);
        await db.UpdateOperationsAsync(before.Revision, before with { Revision = before.Revision + 1 }, CancellationToken.None);
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ResumeSurveyAsync(offer.Remaining, offer.ResumeToken!, CancellationToken.None), "offre périmée");
        Check.Equal("operations.surveyChanged", error.Code, "la révision est contrôlée même à nombre égal");
        Check.Equal(0, connection.Calls, "aucun contact");
    }

    [Test]
    public static async Task Progress_cannot_regress_or_claim_an_unplanned_identity()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("operations.db"), Fixtures.Root, TestClock.Fixed());
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: new SqliteDirectoryCache(db));
        using var reader = new AdOperationsReader(source); var id = Guid.NewGuid().ToString("D"); var target = Guid.Parse(Targets()[0].Id);
        await reader.BeginCollectionAsync(id, new(Fixtures.Postes, "Postes", true), SurveyMode.Ping, Targets(), CancellationToken.None);
        await reader.ProgressCollectionAsync(id, [target], 0, CancellationToken.None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ProgressCollectionAsync(id, [], 0, CancellationToken.None), "régression refusée");
        await Check.ThrowsAsync<InvalidDataException>(() => reader.ProgressCollectionAsync(id, [target, Guid.NewGuid()], 0, CancellationToken.None), "identité étrangère");
        Check.Equal(1, (await db.ReadOperationsAsync(CancellationToken.None)).Survey!.Completed.Length, "état durable conservé");
    }

    [Test]
    public static async Task Operations_store_rejects_CAS_conflict_and_tampered_payload()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("operations.db"), Fixtures.Root, TestClock.Fixed()); var cache = new SqliteDirectoryCache(db);
        var before = await cache.ReadOperationsAsync(CancellationToken.None);
        await cache.UpdateOperationsAsync(0, before with { Revision = 1 }, CancellationToken.None);
        await Check.ThrowsAsync<InvalidDataException>(() => cache.UpdateOperationsAsync(0, before with { Revision = 1 }, CancellationToken.None), "écriture concurrente");
        using (var sql = new SqliteDatabase(db.Path, readOnly: false)) { sql.Execute("UPDATE domenia_v2_operations SET payload='{}' WHERE id=1;"); }
        await Check.ThrowsAsync<InvalidDataException>(() => cache.ReadOperationsAsync(CancellationToken.None), "empreinte incorrecte");
    }

    [Test]
    public static async Task Directory_checks_stop_after_refusal_and_never_bypass_transport()
    {
        using var connection = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection);
        await source.RefreshAsync(MeasureFamily.Directory, new(Fixtures.People, "Personnes", true), CancellationToken.None);
        connection.Searches.Clear(); connection.SearchAnswer = _ => throw new DomeniaOperationException(AdErrors.Credentials, AdErrors.CredentialsMessage);
        var checks = await new AdDirectoryChecks(source).CheckDirectoryAsync(true, CancellationToken.None);
        Check.Equal(1, connection.Searches.Count, "aucun nouvel essai après identifiants refusés");
        Check.Equal(1, checks.Count(r => r.Status == CheckStatus.Error), "refus visible");
        Check.True(checks.Skip(2).All(r => r.Status == CheckStatus.Info), "contrôles suivants non lancés");
    }

    [Test]
    public static void Persisted_survey_refuses_foreign_scope_duplicates_and_negative_counters()
    {
        var checkpoint = new OperationsSurveyCheckpoint(Guid.NewGuid().ToString("D"), Fixtures.Root, new(Fixtures.Postes, "Postes", true), SurveyMode.Ping,
            Targets(), [], Fixtures.Now, Fixtures.Now, true, 0);
        var state = new OperationsLocalState("test", Fixtures.Root, 0, [], [], checkpoint);
        OperationsPersistence.Validate(state);
        foreach (var bad in new[] { checkpoint with { Targets = [Targets()[0], Targets()[0]] }, checkpoint with { Failed = -1 },
            checkpoint with { Scope = new("OU=Postes,DC=foreign,DC=local", "Autre domaine", true) } })
        { Check.Throws<InvalidDataException>(() => OperationsPersistence.Validate(state with { Survey = bad }), "plan invalide"); }
    }
    [Test]
    public static void Legacy_collection_keeps_unknown_counters_and_prior_success()
    {
        var row = new Dictionary<string, object?>
        {
            ["family"] = "Inventory", ["status"] = "Cancelled", ["request_key"] = "onelevel:" + Fixtures.Postes,
            ["attempt_at"] = Fixtures.Now.ToString("O"), ["success_at"] = Fixtures.Now.AddDays(-1).ToString("O"),
            ["payload"] = "null", ["attempt_payload"] = "null", ["error"] = "Interrompu",
        };
        var read = DomeniaDatabase.ParseLegacyOperation(row);
        Check.Null(read.Done, "aucun zéro inventé pour un compteur absent");
        Check.False(read.Subtree, "profondeur héritée");
        Check.Equal<DateTimeOffset?>(Fixtures.Now.AddDays(-1), read.SuccessAt, "dernière réussite conservée");
        row["attempt_at"] = "2026-10-23T12:00:00";
        Check.Throws<InvalidDataException>(() => DomeniaDatabase.ParseLegacyOperation(row), "date sans fuseau refusée");
    }

    private static ImmutableArray<SurveyTarget> Targets() => [new(Fixtures.IdOf("pc1").ToString("D"), "PC1", "CN=PC1," + Fixtures.Postes, null), new(Fixtures.IdOf("pc2").ToString("D"), "PC2", "CN=PC2," + Fixtures.Postes, null)];
}
