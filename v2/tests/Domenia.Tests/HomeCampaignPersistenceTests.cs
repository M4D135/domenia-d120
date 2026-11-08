using System.Collections.Immutable;
using System.Text.Json.Nodes;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using Domenia.Store;

namespace Domenia.Tests;

internal static class HomeCampaignPersistenceTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static HomeCampaignCheckpoint Plan(string storeId) => new(Guid.NewGuid().ToString("D"), storeId, Fixtures.Root, new(Fixtures.Postes, "Postes", true), "inventory",
        ["presence", "inventory"], [], [new(Fixtures.IdOf("home-one"), "CN=PC1," + Fixtures.Postes, Fixtures.Now.AddYears(-1), null, "PC1.test.local", "PC1$", 4096),
            new(Fixtures.IdOf("home-two"), "CN=PC2," + Fixtures.Postes, Fixtures.Now.AddYears(-1), null, "PC2.test.local", "PC2$", 4096)],
        [], [], [], [], Fixtures.Now, Fixtures.Now, null, false, false);

    [Test]
    public static void Home_codec_keeps_frozen_identity_and_refuses_query_text_and_future_format()
    {
        var store = Guid.NewGuid().ToString("D"); var plan = Plan(store);
        var state = new OperationsLocalState(store, Fixtures.Root, 1, [], [], null) { HomeCampaign = plan };
        var encoded = OperationsDocumentCodec.Encode(state);
        Check.Contains(OperationsDocumentCodec.HomeFormat, encoded, "format explicite");
        Check.False(encoded.Contains("CN=PC1", StringComparison.Ordinal), "identités compressées");
        Check.True(plan.Targets.SequenceEqual(OperationsDocumentCodec.Decode(encoded).HomeCampaign!.Targets), "GUID/DN/création/SID/hôte/compte relus");
        var future = JsonNode.Parse(encoded)!; future["state"]!["homeCampaign"]!["format"] = "Domenia.HomeCampaign/2";
        Check.Contains("Version", Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Decode(future.ToJsonString()), "version future").Message, "refus du format");
        var free = JsonNode.Parse(encoded)!; free["state"]!["homeCampaign"]!["queryText"] = "SELECT * FROM Win32_Process";
        Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Decode(free.ToJsonString()), "aucun texte de requête dans le checkpoint");
    }

    [Test]
    public static async Task Home_progress_survives_a_real_SQLite_reopen_without_any_network_or_replay()
    {
        using var x = new Fixture(); var plan = Plan(x.Database.StoreId);
        using (var lease = await x.Reader.BeginHomeCampaignAsync(plan, null, None))
        {
            await lease.SaveAsync([], [plan.Targets[0].Guid], [], Fixtures.Now, None);
            await lease.FinishAsync(false, None);
        }
        var reopened = new DomeniaDatabase(x.Database.Path, Fixtures.Root, TestClock.Fixed());
        var state = await reopened.ReadOperationsAsync(None); var home = state.HomeCampaign!;
        Check.Equal(plan.Id, home.Id, "même plan après redémarrage");
        Check.True(home.PresenceDone.SequenceEqual([plan.Targets[0].Guid]), "un seul bit de présence validé");
        Check.True(home.Interrupted, "interruption durable");
        var offered = await x.Reader.ReadHomeCampaignAsync(None);
        Check.NotNull(offered.Token, "offre liée à la révision locale");
        Check.Equal(0, x.Connection.Calls, "lecture locale et offre n’envoient rien");
    }

    [Test]
    public static async Task Same_lease_excludes_other_search_and_home_campaigns_until_disposed()
    {
        using var x = new Fixture(); var plan = Plan(x.Database.StoreId);
        var lease = await x.Reader.BeginHomeCampaignAsync(plan, null, None);
        try
        {
            using var other = new AdOperationsReader(x.Source);
            var second = await Check.ThrowsAsync<DomeniaOperationException>(() => other.BeginHomeCampaignAsync(Plan(x.Database.StoreId), null, None), "second plan Accueil");
            Check.Equal("operations.surveyBusy", second.Code, "même admission physique");
            var search = await Check.ThrowsAsync<DomeniaOperationException>(() => other.BeginCollectionAsync(Guid.NewGuid().ToString("D"), plan.Scope, SurveyMode.Ping,
                [new(plan.Targets[0].Guid.ToString("D"), "PC1", plan.Targets[0].Dn, null)], None), "relevé Recherche concurrent");
            Check.Equal("operations.surveyBusy", search.Code, "aucun second moteur sur cette base");
            await lease.FinishAsync(false, None);
        }
        finally { lease.Dispose(); }
        using var exclusive = await x.Cache.AcquireOperationsLeaseAsync(None);
        Check.Equal(0, x.Connection.Calls, "admission locale uniquement");
    }

    [Test]
    public static async Task Resume_rejects_an_expanded_or_rebound_identity_and_preserves_original_plan()
    {
        using var x = new Fixture(); var plan = Plan(x.Database.StoreId);
        using (var lease = await x.Reader.BeginHomeCampaignAsync(plan, null, None)) { await lease.FinishAsync(false, None); }
        var saved = await x.Reader.ReadHomeCampaignAsync(None); var original = saved.Plan!; var altered = original with
        { Id = Guid.NewGuid().ToString("D"), Targets = [original.Targets[0] with { Host = "OTHER.test.local" }, original.Targets[1]] };
        await Check.ThrowsAsync<DomeniaOperationException>(() => x.Reader.BeginHomeCampaignAsync(altered, saved.Token, None), "hôte changé derrière le même GUID");
        var read = await x.Reader.ReadHomeCampaignAsync(None);
        Check.Equal(saved.Token, read.Token, "aucun CAS du plan refusé");
        Check.Equal("PC1.test.local", read.Plan!.Targets[0].Host!, "identité conservée");
        var branchesChanged = original with { Id = Guid.NewGuid().ToString("D"), Branches = [original.Scope with { Subtree = false }] };
        await Check.ThrowsAsync<DomeniaOperationException>(() => x.Reader.BeginHomeCampaignAsync(branchesChanged, saved.Token, None), "mêmes cibles mais sélection de branches différente");
        Check.Equal(saved.Token, (await x.Reader.ReadHomeCampaignAsync(None)).Token, "politique de sélection de la reprise conservée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => x.Reader.BeginHomeCampaignAsync(original with { ReadWithoutEcho = !original.ReadWithoutEcho }, saved.Token, None), "admission réseau de reprise modifiée");
    }

    [Test]
    public static async Task Progress_cannot_regress_or_clear_a_plan_with_unfinished_stages()
    {
        using var x = new Fixture(); var plan = Plan(x.Database.StoreId);
        using var lease = await x.Reader.BeginHomeCampaignAsync(plan, null, None);
        await lease.SaveAsync([], [plan.Targets[0].Guid], [], Fixtures.Now, None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => lease.SaveAsync([], [], [], Fixtures.Now, None), "régression de bits");
        await Check.ThrowsAsync<DomeniaOperationException>(() => lease.FinishAsync(true, None), "étapes non terminées");
        Check.NotNull((await x.Reader.ReadHomeCampaignAsync(None)).Plan, "plan non effacé sur fausse fin");
        await lease.SaveAsync(plan.Stages, [.. plan.Targets.Select(t => t.Guid)], [.. plan.Targets.Select(t => t.Guid)], Fixtures.Now, None);
        await lease.FinishAsync(true, None);
        Check.Null((await x.Reader.ReadHomeCampaignAsync(None)).Plan, "seul le plan entièrement terminé est retiré");
    }

    [Test]
    public static async Task Session_change_prevents_new_bits_but_finalization_preserves_the_prior_progress()
    {
        using var x = new Fixture(); var plan = Plan(x.Database.StoreId);
        using var lease = await x.Reader.BeginHomeCampaignAsync(plan, null, None);
        await lease.SaveAsync([], [plan.Targets[0].Guid], [], Fixtures.Now, None);
        x.Source.Reset();
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => lease.SaveAsync([], [.. plan.Targets.Select(t => t.Guid)], [], Fixtures.Now, None), "nouvelle génération refusée");
        Check.Equal(AccountAccess.EpochChanged, error.Code, "bonne frontière");
        await lease.FinishAsync(false, None);
        var saved = (await x.Reader.ReadHomeCampaignAsync(None)).Plan!;
        Check.Equal(1, saved.PresenceDone.Length, "aucun bit ajouté sous une autre session");
        Check.True(saved.Interrupted, "preuve précédente conservée et clôturée");
    }

    [Test]
    public static async Task Stale_home_offer_and_simultaneous_plan_kinds_are_refused()
    {
        using var x = new Fixture(); var plan = Plan(x.Database.StoreId);
        using (var lease = await x.Reader.BeginHomeCampaignAsync(plan, null, None)) { await lease.FinishAsync(false, None); }
        var saved = await x.Reader.ReadHomeCampaignAsync(None); var before = await x.Database.ReadOperationsAsync(None);
        await x.Database.UpdateOperationsAsync(before.Revision, before with { Revision = before.Revision + 1 }, None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => x.Reader.BeginHomeCampaignAsync(saved.Plan! with { Id = Guid.NewGuid().ToString("D") }, saved.Token, None), "offre devenue périmée");
        var both = before with { Survey = new(Guid.NewGuid().ToString("D"), Fixtures.Root, plan.Scope, SurveyMode.Ping,
            [new(plan.Targets[0].Guid.ToString("D"), "PC1", plan.Targets[0].Dn, null)], [], Fixtures.Now, Fixtures.Now, false, 0) };
        Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Encode(both), "deux plans de ressources différentes interdits");
    }

    [Test]
    public static void Presence_bits_without_presence_stage_are_refused_even_with_a_coherent_date()
    {
        var store = Guid.NewGuid().ToString("D"); var plan = Plan(store);
        HomeCampaignRules.Validate(plan, store, Fixtures.Root);
        var noPresence = plan with { Stages = ["inventory"] };
        HomeCampaignRules.Validate(noPresence, store, Fixtures.Root);
        var dated = noPresence with { PresenceStartedAt = noPresence.StartedAt };
        HomeCampaignRules.Validate(dated, store, Fixtures.Root);
        var forged = dated with { PresenceDone = [dated.Targets[0].Guid] };
        var error = Check.Throws<InvalidDataException>(() => HomeCampaignRules.Validate(forged, store, Fixtures.Root), "bits de présence hors étape presence");
        Check.Contains("Progression sans étape qualifiée.", error.Message, "refus exact de la progression étrangère");
    }

    [Test]
    public static async Task Directory_binding_requires_a_current_receipt_and_is_closed_after_workstation_progress()
    {
        using var x = new Fixture();
        var plan = Plan(x.Database.StoreId) with { Mode = "all", Stages = ["backup", "directory", "commit", "presence", "inventory"] };
        using var lease = await x.Reader.BeginHomeCampaignAsync(plan, null, None);
        var snapshot = Fixtures.Snapshot(computers: [Fixtures.Computer("NEW")]) with { Coverage = plan.Scope };
        var unproved = new DirectoryState(snapshot, FleetObservations.Empty, [], []);
        await Check.ThrowsAsync<DomeniaOperationException>(() => lease.BindDirectoryAsync(unproved, None), "aucune cible ajoutée sans reçu du moteur");
        Check.True(lease.State.Targets.SequenceEqual(plan.Targets), "population originale inchangée après refus");
        await lease.SaveAsync([], [plan.Targets[0].Guid], [], Fixtures.Now, None);
        var fabricated = unproved with { DirectoryCommit = new(new(x.Database.StoreId, Fixtures.Root, plan.Scope, snapshot.ReadAt, true,
            Guid.NewGuid().ToString("D"), new string('a', 64), 1, snapshot.ObjectCount, Fixtures.Now), x.Source.Epoch) };
        await Check.ThrowsAsync<DomeniaOperationException>(() => lease.BindDirectoryAsync(fabricated, None), "réaffectation interdite dès le premier ping enregistré");
        Check.Equal(1, lease.State.PresenceDone.Length, "progression originale préservée");
        Check.True(lease.State.Targets.SequenceEqual(plan.Targets), "aucune expansion après début du relevé");
    }

    private sealed class Fixture : IDisposable
    {
        private readonly TemporaryFolder folder = new();
        public DomeniaDatabase Database { get; }
        public SqliteDirectoryCache Cache { get; }
        public AdBoundaryTests.RecordingAdConnection Connection { get; } = new();
        public AdDirectorySource Source { get; }
        public AdOperationsReader Reader { get; }
        public Fixture()
        {
            Database = new(folder.File("home-campaign.db"), Fixtures.Root, TestClock.Fixed()); Cache = new(Database);
            Source = new("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: Connection, localStore: Cache); Reader = new(Source);
        }
        public void Dispose() { Reader.Dispose(); Source.Dispose(); Connection.Dispose(); folder.Dispose(); }
    }
}
