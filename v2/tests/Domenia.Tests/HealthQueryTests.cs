using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using ProbeReading = Domenia.Core.Queries.ProbeReading;

namespace Domenia.Tests;

internal static class HealthQueryTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static QueryRecipe Recipe() => QueryRecipe.Empty() with { Name = "Disque faible", Clauses = [new("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(10))] };

    [Test]
    public static async Task Frozen_query_alert_preserves_match_no_match_unknown_and_rejects_tampering()
    {
        using var library = new QueryLibrary(new MemoryQueryLibraryStore(), new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
        var saved = await library.SaveAsync(Fixtures.Root, Recipe(), null, null, 0, "update", null, None);
        var binding = HealthQueryRules.Freeze(saved.Record, saved.Record.Revision);
        Check.True(HealthQueryRules.Valid(binding), "définition et empreinte concordantes");
        Check.False(HealthQueryRules.Valid(binding with { Fingerprint = new string('0', 64) }), "empreinte altérée refusée");
        var a = Fixtures.Computer("PC-LOW"); var b = Fixtures.Computer("PC-OK"); var c = Fixtures.Computer("PC-UNKNOWN");
        var directory = Fixtures.Snapshot(computers: [a, b, c]);
        var observations = new FleetObservations(TestClock.Reference, [Fixtures.Observe(a, inventory: Fixtures.Disk(1000, 50, TimeSpan.Zero)), Fixtures.Observe(b, inventory: Fixtures.Disk(1000, 800, TimeSpan.Zero))]);
        var dataset = new QueryDataset(directory, observations, ImmutableDictionary<Guid, ImmutableArray<ProbeReading>>.Empty,
            ImmutableDictionary<Guid, ConsoleReading>.Empty, ImmutableDictionary<Guid, char>.Empty, ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>>.Empty, 1, "test local", true);
        var content = await library.ReadAsync(Fixtures.Root, None);
        var snapshot = new FleetQuerySnapshot(content, dataset, null);
        var states = HealthQueryRules.Evaluate(binding, snapshot, new ScopeSelection(Fixtures.Postes, "Postes", true), TestClock.Reference);
        Check.Equal(MatchState.Match, states[a.ObjectGuid], "disque faible correspondant");
        Check.Equal(MatchState.NoMatch, states[b.ObjectGuid], "disque suffisant non correspondant");
        Check.Equal(MatchState.Unknown, states[c.ObjectGuid], "absence de relevé inconnue, jamais saine");
        var rule = new CustomHealthRule("custom.00000000000000000000000000000001", "Disque faible", "Query", "Matches", 0, "Warn", true) { Query = binding };
        var policy = HealthPolicy.Default with { DisabledRules = [.. HealthRules.Catalog.Select(r => r.Id)], CustomRules = [rule] };
        var book = HealthPolicyBook.Empty(Fixtures.Root) with { Default = policy };
        var input = new FleetBoardInput(new DirectoryState(directory, observations, [], []), new ScopeSelection(Fixtures.Postes, "Postes", true), Fixtures.Root, "example.local", book,
            AccueilFacts.Empty("test-local"), null, ProbeReadings.Empty, FleetCatalog.DefaultLayout(), [], TestClock.Reference, TimeZoneInfo.Utc, Queries: snapshot);
        var board = FleetBoardCalculator.Compute(input);
        Check.Equal(1, board.Board.Health.Healthy, "une seule non-correspondance prouvée est saine");
        Check.Equal(1, board.Board.Health.Problems, "la correspondance devient un point d’attention");
        Check.Equal(1, board.Board.Health.Unassessed, "relevé absent exclu du score sain");
        Check.True(board.Targets[board.Board.Health.UnknownKey].SequenceEqual([c.ObjectGuid]), "clic inconnu identique au dénominateur");
        await library.ArchiveAsync(Fixtures.Root, saved.Record.Id, saved.Record.Revision, None);
        var archived = new FleetQuerySnapshot(await library.ReadAsync(Fixtures.Root, None), dataset, null);
        Check.Equal(0, HealthQueryRules.Evaluate(binding, archived, new ScopeSelection(Fixtures.Postes, "Postes", true), TestClock.Reference).Count, "archive devenue inconnue pour tous les postes");
        Check.Equal(3, FleetBoardCalculator.Compute(input with { Queries = archived }).Board.Health.Unassessed, "archive ne transforme aucun ancien résultat en poste sain");
    }

    [Test]
    public static async Task Health_policy_round_trip_keeps_the_exact_definition_revision_and_dependency()
    {
        var bridge = new SimulatedBridge();
        var library = RequetesServices.Library(bridge.Context);
        var root = (await bridge.Source.GetSessionAsync(None)).Domain?.RootDn ?? throw new TestFailureException("Domaine de simulation absent.");
        var saved = await library.SaveAsync(root, Recipe(), null, null, 0, "update", null, None);
        var service = AccueilService.From(bridge.Context);
        var binding = await service.FreezeHealthQueryAsync(saved.Record.Id, 1, None);
        var custom = new CustomHealthRule("custom.00000000000000000000000000000001", "Disque faible figé", "Query", "Matches", 0, "Warn", true) { Query = binding };
        var policy = HealthPolicy.Default with { CustomRules = [custom] };
        var book = HealthRules.SetScopePolicy(HealthPolicyBook.Empty(root), "", policy, TestClock.Reference);
        var read = HealthPolicyJson.ReadBook(HealthPolicyJson.Write(book), root, TestClock.Reference);
        Check.Equal(binding, read.Default.CustomRules.Single().Query, "définition exacte conservée à la relecture des préférences");
        using var corrupt = JsonDocument.Parse(HealthPolicyJson.Write(book).GetRawText().Replace(binding.Fingerprint, new string('0', 64), StringComparison.Ordinal));
        var unreadable = HealthPolicyJson.ReadBook(corrupt.RootElement, root, TestClock.Reference).Default.CustomRules.Single();
        Check.True(unreadable.Enabled && unreadable.Query?.Problem is not null, "référence altérée conservée explicitement inconnue, jamais supprimée du calcul");
        using var parsed = JsonDocument.Parse(JsonSerializer.Serialize(HealthPolicyJson.PolicyValue(policy)));
        Check.Contains("recipeId", parsed.RootElement.GetProperty("customRules")[0].GetProperty("query").GetRawText(), "contrat JSON camelCase stable");
        await service.SaveHealthAsync(null, policy, None);
        var content = await library.ReadAsync(root, None);
        var consumer = content.Consumers.Single(c => c.Kind == "health");
        Check.Equal(binding.Revision, consumer.BoundRevision, "dépendance liée à la révision figée");
        await service.SaveHealthAsync(null, policy with { CustomRules = [] }, None);
        Check.False((await library.ReadAsync(root, None)).Consumers.Any(c => c.Kind == "health"), "retrait enregistré libère sa propre dépendance");
        await library.ArchiveAsync(root, saved.Record.Id, 1, None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => service.SaveHealthAsync(null, policy, None), "une requête archivée ne peut être confirmée comme alerte active");
    }
}
