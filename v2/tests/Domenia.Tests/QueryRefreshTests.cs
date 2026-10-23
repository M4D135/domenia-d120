using System.Collections.Immutable;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class QueryRefreshTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static QueryRecipe Recipe() => QueryRecipe.Empty() with { Name = "Mesure disque", Clauses = [new("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(10))] };
    private static QueryDataset Dataset(DirectorySnapshot directory, FleetObservations observations) => new(directory, observations,
        ImmutableDictionary<Guid, ImmutableArray<Domenia.Core.Queries.ProbeReading>>.Empty, ImmutableDictionary<Guid, ConsoleReading>.Empty,
        ImmutableDictionary<Guid, char>.Empty, ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>>.Empty, 1, "test", true);

    [Test]
    public static async Task Refresh_freezes_library_revisions_and_refuses_missing_or_archived_consumers()
    {
        using var library = new QueryLibrary(new MemoryQueryLibraryStore(), new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
        var first = await library.SaveAsync(Fixtures.Root, Recipe(), null, null, 0, "update", new("fleet", "kpi", "Disques"), None);
        var item = new FleetLayoutItem("test", FleetWidgetSource.Query, first.Widget!.Id, "Kpi", "M", "Disques", false, "Requêtes");
        var content = await library.ReadAsync(Fixtures.Root, None);
        var frozen = QueryRefreshRules.Freeze(content, [item], []).Single();
        await library.SaveAsync(Fixtures.Root, first.Record.Recipe, "Autre catégorie", null, 1, "update", null, None);
        QueryRefreshRules.Confirm(await library.ReadAsync(Fixtures.Root, None), frozen);
        Check.Equal(1L, frozen.Revision, "révision initiale toujours liée, aucune adoption de la suivante");
        Check.Throws<DomeniaOperationException>(() => QueryRefreshRules.Freeze(content, [item with { Key = "absent" }], []), "lien absent refuse tout plan");
        Check.Equal(0, QueryRefreshRules.Freeze(content, [item with { Key = "absent", Paused = true }], []).Length, "widget suspendu ne déclenche aucun plan");
        await library.ArchiveAsync(Fixtures.Root, first.Record.Id, 2, None);
        var archived = await library.ReadAsync(Fixtures.Root, None);
        Check.Throws<DomeniaOperationException>(() => QueryRefreshRules.Confirm(archived, frozen), "archive entre préparation et exécution refuse le réseau");
    }

    [Test]
    public static void Query_refresh_uses_only_frozen_online_identities_and_reuses_fresh_information()
    {
        var a = Fixtures.Computer("PC-A"); var b = Fixtures.Computer("PC-B"); var added = Fixtures.Computer("PC-AJOUTE");
        var directory = Fixtures.Snapshot(computers: [a, b, added]);
        var observations = new FleetObservations(TestClock.Reference, [Fixtures.Observe(a, inventory: Fixtures.Disk(1000, 500, TimeSpan.Zero))]);
        var dataset = Dataset(directory, observations); var compiled = QueryEngine.Compile(Recipe());
        var frozen = new FrozenFleetQuery(compiled.Normalized.Id, 1, compiled.Fingerprint, compiled.Normalized);
        var identities = new[] { a, b }.ToImmutableDictionary(c => c.ObjectGuid, QueryComputerIdentity.Of);
        var online = new HashSet<Guid> { a.ObjectGuid, b.ObjectGuid, added.ObjectGuid };
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        var requests = QueryRefreshRules.Requests(frozen, dataset, scope, identities, online, TestClock.Reference, false);
        Check.Equal(1, requests.Length, "seul le poste figé sans information demande une lecture");
        Check.Equal(b.ObjectGuid, requests[0].Computers.Single(), "nouveau poste exclu même s’il est en ligne");
        Check.True(requests[0].Inventory && !requests[0].Presence, "inventaire demandé, aucun second ping");
        var forced = QueryRefreshRules.Requests(frozen, dataset, scope, identities, online, TestClock.Reference, true);
        Check.Equal(2, forced.Length, "Tout relire garde la population figée");
        Check.Equal(0, QueryRefreshRules.Requests(frozen, dataset, scope, identities, new HashSet<Guid>(), TestClock.Reference, true).Length, "aucune WMI sans ping positif du plan");
        var moved = b with { DistinguishedName = "CN=PC-B,OU=Autre," + Fixtures.Root };
        var changed = dataset with { Directory = Fixtures.Snapshot(computers: [a, moved, added]) };
        Check.Throws<DomeniaOperationException>(() => QueryRefreshRules.Requests(frozen, changed, new ScopeSelection(Fixtures.Root, "Domaine", true), identities, online, TestClock.Reference, true), "déplacement après plan refusé");
        Check.False(identities[b.ObjectGuid].Matches(b with { WhenCreated = b.WhenCreated.AddSeconds(1) }), "réincarnation du GUID refusée");
        Check.False(identities[b.ObjectGuid].Matches(b with { DnsHostName = "autre.test.local" }), "cible DNS remplacée refusée");
    }

    [Test]
    public static async Task Real_query_widget_prepares_an_explicit_refresh_stage_in_simulation()
    {
        var bridge = new SimulatedBridge();
        var session = await bridge.Source.GetSessionAsync(None);
        await WorkingScope.From(bridge.Context).SetAsync(session, await RequetesOperationsTests.WorkstationsOuAsync(bridge), true, None);
        var root = session.Domain?.RootDn ?? throw new TestFailureException("Domaine de simulation absent.");
        var library = RequetesServices.Library(bridge.Context); var service = AccueilService.From(bridge.Context);
        var saved = await library.SaveAsync(root, Recipe(), null, null, 0, "update", null, None);
        var linked = await service.BindQueryAsync(saved.Record.Id, 1, None);
        await service.SaveLayoutAsync([linked.Item], None);
        var plan = await service.PlanRefreshAsync("inventory", None);
        Check.True(plan.Stages.Any(s => s.Id == "queries"), "vraie collecte complémentaire préparée, pas refus inconditionnel");
        Check.True(plan.Warnings.Any(w => w.Contains(saved.Record.Fingerprint[..12], StringComparison.Ordinal)), "empreinte confirmée visible dans le plan");
        var version = (await bridge.Context.Readers.Find<IQueryWorkshopReader>()!.DatasetAsync(None)).Version;
        _ = await service.PlanRefreshAsync("inventory", None);
        Check.Equal(version, (await bridge.Context.Readers.Find<IQueryWorkshopReader>()!.DatasetAsync(None)).Version, "préparer deux plans ne collecte rien");
    }
    [Test]
    public static async Task Frozen_presence_measures_only_selected_computers_and_refuses_replaced_identity()
    {
        var bridge = new SimulatedBridge();
        var session = await bridge.Source.GetSessionAsync(None);
        var dn = await RequetesOperationsTests.WorkstationsOuAsync(bridge);
        var scope = new ScopeSelection(dn, "Postes", true);
        var before = await bridge.Source.ReadLocalAsync(None);
        var chosen = before.Directory.Computers.First(c => ScopeRules.Contains(scope, c.DistinguishedName) && !AdValues.IsDisabled(c.UserAccountControl));
        var identities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(chosen.ObjectGuid, QueryComputerIdentity.Of(chosen));
        var reader = bridge.Context.Readers.Find<IAccueilReader>() ?? throw new TestFailureException("Lecteur Accueil absent.");
        var after = await reader.ReadPresenceAsync(scope, identities, session.Epoch, None);
        Check.Equal(TestClock.Reference, after.Observations.Workstations.Single(o => o.ComputerGuid == chosen.ObjectGuid).Presence.CheckedAt, "poste explicitement sélectionné mesuré");
        var previous = before.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        Check.True(after.Observations.Workstations.Where(o => o.ComputerGuid != chosen.ObjectGuid).All(o => previous[o.ComputerGuid] == o), "dates et valeurs des postes non sélectionnés intactes");
        var replaced = identities.SetItem(chosen.ObjectGuid, identities[chosen.ObjectGuid] with { Created = chosen.WhenCreated.AddSeconds(1) });
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadPresenceAsync(scope, replaced, session.Epoch, None), "réincarnation refuse avant mesure");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadInventoryAsync(scope, identities, session.Epoch + 1, None), "nouvelle session ne rejoue pas un ancien plan");
    }

}
