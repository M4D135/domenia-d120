using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;
using ScalarCatalog = Domenia.Core.Accueil.ProbeCatalog;
using DetailedCatalog = Domenia.Core.Poste.ProbeCatalog;
using ScalarReading = Domenia.Core.Accueil.ProbeReading;

namespace Domenia.Tests;

internal static class ProbeDefinitionCacheTests
{
    [Test]
    public static void Definition_identity_covers_query_projection_order_and_interpretation_but_not_display_labels()
    {
        var scalar = ScalarCatalog.Find("hw.model")!;
        var hash = ProbeDefinitionIdentity.Of(scalar);
        Check.Equal(hash, ProbeDefinitionIdentity.Of(scalar with { Name = "Autre présentation" }), "présentation seule sans collecte supplémentaire");
        Check.False(hash == ProbeDefinitionIdentity.Of(scalar with { Class = "Other_Class" }), "autre fournisseur");
        Check.False(hash == ProbeDefinitionIdentity.Of(scalar with { Transform = "Year" }), "autre interprétation");
        var detailed = DetailedCatalog.Find("disk.volumes")!;
        Check.False(ProbeDefinitionIdentity.Of(detailed) == ProbeDefinitionIdentity.Of(detailed with { Properties = [.. detailed.Properties.Reverse()] }), "ordre des colonnes fait partie du contrat");
        Check.False(ProbeDefinitionIdentity.Current(scalar, null), "mesure historique sans empreinte ne devient pas actuelle");
        var builtin = new FrozenProbe(scalar.Id, scalar);
        Check.True(ReferenceEquals(scalar, builtin.RuntimeDefinition), "la définition embarquée originale traverse chaque poste sans copie");
        var personal = new FrozenProbe("custom." + new string('a', 64), scalar);
        Check.True(ReferenceEquals(personal.RuntimeDefinition, personal.RuntimeDefinition), "la projection personnelle est matérialisée une fois par déclaration figée");
        var changed = personal with { Key = "custom." + new string('b', 64) };
        Check.False(ReferenceEquals(personal.RuntimeDefinition, changed.RuntimeDefinition), "un clone modifié ne conserve pas la projection de l’ancienne clé");
        Check.Equal(changed.Key, changed.RuntimeDefinition.Id, "clé réellement exécutée");
    }

    [Test]
    public static async Task Real_CIM_readers_attach_the_executed_definition_and_column_names_to_partial_and_complete_values()
    {
        var clock = TestClock.Fixed();
        var reader = new WmiWorkstationReader(clock)
        { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
            { ReadOverride = (_, sql, _) => sql.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
                ? [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "PC1", ["DNSHostName"] = "PC1", ["Domain"] = "test.local" })]
                : [new WmiInstance(new Dictionary<string, object?> { ["DeviceID"] = "C:", ["Size"] = 1000L, ["FreeSpace"] = 0L })] } };
        var read = await reader.ReadProbesAsync("PC1", ["disk.volumes"], null, CancellationToken.None);
        var definition = DetailedCatalog.Find("disk.volumes")!;
        Check.Equal(ProbeDefinitionIdentity.Of(definition), read.Values[definition.Id].DefinitionHash, "déclaration réellement envoyée");
        Check.True(read.Values[definition.Id].Columns.SequenceEqual(definition.Properties), "colonnes exactes gardées avec les cellules");
        var scalar = ScalarCatalog.Find("hw.model")!;
        var result = WmiFleetProbeReader.Project(scalar, new("hw.model", SourceStatus.Ok, "Lu", 1,
            [new WmiInstance(new Dictionary<string, object?> { ["Model"] = "Model" })]), Fixtures.Now);
        Check.Equal(ProbeDefinitionIdentity.Of(scalar), result.DefinitionHash, "projection scalaire qualifiée aussi");
    }

    [Test]
    public static async Task Native_cache_preserves_old_columns_but_never_reinterprets_them_under_a_different_catalog()
    {
        using var folder = new TemporaryFolder();
        var computer = Fixtures.Computer("PC1");
        var db = new DomeniaDatabase(folder.File("probe.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [computer]), new(Fixtures.Postes, "Postes", true), null, CancellationToken.None);
        var original = WorkstationDetailedProbeTests.Store("disk.volumes", Fixtures.Now, ("DeviceID", "C:"), ("Size", 1000L), ("FreeSpace", 0L));
        var legacy = original with
        {
            Probes = [.. original.Probes.Select(s => s with { DefinitionHash = null })],
            Values = original.Values.SetItem("disk.volumes", original.Values["disk.volumes"] with { DefinitionHash = null, Columns = default }),
        };
        await db.SaveFleetAsync(FleetCachePatch.Empty with { WorkstationProbes = ImmutableDictionary<Guid, ProbeStore>.Empty.Add(computer.ObjectGuid, legacy) }, CancellationToken.None);
        var cold = (await new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed()).ReadFleetAsync(CancellationToken.None)).WorkstationProbes[computer.ObjectGuid];
        Check.Equal(1, cold.Values["disk.volumes"].Rows.Length, "ancien contenu conservé après redémarrage");
        var projection = WmiWorkstationReader.ProjectProbes(cold);
        Check.Equal(ProbeState.NotRead, projection.Probes.Single().State, "pas de succès actuel inventé");
        Check.Equal(0, projection.Data!.Volumes.Length, "aucun calcul sur ancien ordre de colonnes inconnu");
        var detail = PosteProbeDetails.Build(projection, DetailedCatalog.Find("disk.volumes")!, 1, TestClock.Paris, Fixtures.Now);
        Check.Equal(1, detail.Total, "relevé brut encore consultable");
        Check.Equal("Valeur 1", detail.Columns[0], "aucun faux nom de colonne");
        Check.Contains("historique", detail.Provenance, "limite présentée");
        var failed = original with { CollectedAt = Fixtures.Now.AddMinutes(1), Values = ImmutableDictionary<string, ProbeValues>.Empty,
            Probes = [new("disk.volumes", ProbeState.Failed, null, Fixtures.Now.AddMinutes(1), "Refus", 0) { DefinitionHash = original.Probes[0].DefinitionHash }] };
        var merged = PosteProbeCache.Merge(cold, failed);
        Check.Equal(1, merged.Values["disk.volumes"].Rows.Length, "un échec de la nouvelle définition conserve l’ancien relevé");
        Check.Null(merged.Probes.Single().LastSuccess, "succès de l’ancienne définition non attribué à la nouvelle");
        Check.Null(merged.Probes.Single().DataAt, "ancienne donnée n’est pas celle du nouveau contrat");
        Check.Equal("Valeur 1", PosteProbeDetails.Build(merged, DetailedCatalog.Find("disk.volumes")!, 1, TestClock.Paris, Fixtures.Now.AddMinutes(1)).Columns[0],
            "l’empreinte de la nouvelle tentative ne qualifie pas les anciennes cellules");
        var permuted = original with { Values = original.Values.SetItem("disk.volumes", original.Values["disk.volumes"] with { Columns = [.. original.Values["disk.volumes"].Columns.Reverse()] }) };
        Check.Throws<InvalidDataException>(() => PosteProbeCache.Validate(permuted, Fixtures.Now), "colonnes permutées incompatibles avec l’empreinte déclarée");
    }

    [Test]
    public static async Task Scalar_reuse_aggregation_and_native_merge_keep_one_historical_version_without_claiming_it_current()
    {
        using var folder = new TemporaryFolder();
        var computer = Fixtures.Computer("PC1");
        var definition = ScalarCatalog.Find("hw.model")!;
        var identity = Domenia.Core.Queries.QueryComputerIdentity.Of(computer);
        var actual = new ScalarReading(MeasureState.Known, Fixtures.Now, ["Model"], null)
        { DefinitionHash = ProbeDefinitionIdentity.Of(definition), Identity = identity };
        var old = actual with { DefinitionHash = new string('a', 64) };
        var policy = new CollectionCachePolicy(CollectionSettingsRules.Default);
        Check.True(policy.Probe(definition.Id, actual, identity, Fixtures.Now), "définition actuelle réemployée");
        Check.False(policy.Probe(definition.Id, old, identity, Fixtures.Now), "définition différente doit être relue");
        Check.Equal(0, ScalarCatalog.Measure(definition, [(computer.ObjectGuid, old)], "Bar", Fixtures.Now).Machines, "ancienne définition exclue du widget");
        var raw = PosteScalarProbeCards.Build(definition, old, 1, Fixtures.Now, TestClock.Paris);
        Check.Equal(ProbeState.NotRead, raw.Status.State, "fiche brute sans succès courant");
        Check.Equal("Model", raw.Rows.Single().Single(), "ancienne valeur consultable");
        var db = new DomeniaDatabase(folder.File("scalar.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [computer]), new(Fixtures.Postes, "Postes", true), null, CancellationToken.None);
        ProbeReadings Reads(ScalarReading value) => new(ImmutableDictionary<string, ImmutableDictionary<Guid, ScalarReading>>.Empty.Add(definition.Id, ImmutableDictionary<Guid, ScalarReading>.Empty.Add(computer.ObjectGuid, value)));
        await db.SaveFleetAsync(FleetCachePatch.Empty with { Probes = Reads(old) }, CancellationToken.None);
        var failure = actual with { State = MeasureState.Refused, At = Fixtures.Now.AddMinutes(1), Values = [], Error = "Refus", FailureStatus = SourceStatus.Refused };
        await db.SaveFleetAsync(FleetCachePatch.Empty with { Probes = Reads(failure) }, CancellationToken.None);
        await db.SaveFleetAsync(FleetCachePatch.Empty with { Probes = Reads(failure) }, CancellationToken.None);
        var cold = (await new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed()).ReadFleetAsync(CancellationToken.None)).Probes.ByProbe[definition.Id][computer.ObjectGuid];
        Check.Equal("Model", cold.Historical!.Values.Single(), "précédente valeur conservée et bornée après deux échecs");
        Check.Equal(old.At, cold.Historical.At, "historique non rajeuni");
        Check.Equal(old.DefinitionHash, cold.Historical.DefinitionHash, "ancienne définition explicitement liée");
        Check.False(policy.Probe(definition.Id, cold, identity, Fixtures.Now.AddMinutes(1)), "historique jamais réutilisé comme succès");
        Check.Equal(0, ScalarCatalog.Measure(definition, [(computer.ObjectGuid, cold)], "Bar", Fixtures.Now.AddMinutes(1)).Machines, "historique hors agrégat");
        var confirmedEmpty = cold with { State = MeasureState.Known, Error = null, Values = [] };
        Check.Equal(0, PosteScalarProbeCards.Build(definition, confirmedEmpty, 1, Fixtures.Now.AddMinutes(1), TestClock.Paris).Total,
            "un nouveau relevé vide confirmé ne réaffiche pas l’ancienne valeur comme résultat courant");
    }
}
