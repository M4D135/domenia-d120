using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Store;

namespace Domenia.Tests;

internal static class PostePersonalProbeTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static FleetLayoutItem Card(string key, bool paused = false) => new("team-card", FleetWidgetSource.Probe, key, "Table", "L", "Fabricant personnel", paused, "Équipe");
    private static DirectoryComputer Target(SimulatedBridge bridge) => bridge.Source.CurrentDirectory.Computers.First(c =>
        !AdValues.IsDisabled(c.UserAccountControl) && (c.UserAccountControl & AdValues.ServerTrustAccount) == 0);

    [Test]
    public static async Task Actual_Poste_bridge_exposes_the_profile_version_and_reads_only_after_the_explicit_plan()
    {
        var bridge = new SimulatedBridge(); var home = AccueilService.From(bridge.Context); var computer = Target(bridge);
        var key = (await PersonalProbeFixtures.Import(home, PersonalProbeFixtures.Document())).Catalog.Entries.Single().Key;
        var view = await PosteBoardLayouts.ReadLatestAsync(bridge.Preferences, "Computer", None);
        Check.True(view.Catalog.Any(p => p.Key == key && p.Source == FleetWidgetSource.Probe), "même catalogue de profil disponible dans Personnaliser Poste");
        Check.False((await PosteBoardLayouts.ReadLatestAsync(bridge.Preferences, "Software", None)).Catalog.Any(p => p.Key == key), "pas de sonde dans Logiciels");
        await PosteBoardLayouts.SaveAsync(bridge.Preferences, "Computer", [Card(key)], None);
        Check.Equal(71, PosteBoardLayouts.Read(bridge.Preferences, "Computer").Items.Single().Key.Length, "clé entière indépendante de l’identifiant de carte");
        var localArguments = JsonSerializer.Serialize(new { dn = computer.DistinguishedName, computer = computer.ObjectGuid, probe = key, page = 1 });
        var before = SimulatedBridge.Json(await bridge.CallAsync("poste.layout.probe", localArguments));
        Check.Equal("notRead", before.GetProperty("status").GetProperty("state").GetString(), "carte ajoutée sans collecte");
        Check.Equal(0, before.GetProperty("rows").GetArrayLength(), "aucune valeur inventée");
        Check.True((await bridge.Context.Readers.Require<IAccueilReader>().StoredProbesAsync(None)).ByProbe.IsEmpty, "import, disposition et cache restent sans collecte");
        var plan = SimulatedBridge.Json(await bridge.CallAsync("poste.personalProbe.plan", JsonSerializer.Serialize(new
        { dn = computer.DistinguishedName, computer = computer.ObjectGuid, item = "team-card" })));
        Check.Equal(key, plan.GetProperty("key").GetString(), "plan lié à la version complète");
        Check.Equal("LectureDistanteWmi", plan.GetProperty("contract").GetProperty("privilegeLevel").GetString(), "droit déclaré avant décision");
        Check.Equal("Léger", plan.GetProperty("contract").GetProperty("costLevel").GetString(), "Slow ne devient pas un coût inventé");
        Check.True((await bridge.Context.Readers.Require<IAccueilReader>().StoredProbesAsync(None)).ByProbe.IsEmpty, "plan local sans relevé");
        var id = plan.GetProperty("id").GetString();
        var result = SimulatedBridge.Json(await bridge.CallAsync("poste.personalProbe.run", JsonSerializer.Serialize(new { id, confirmed = true })));
        Check.True(result.GetProperty("receipt").GetProperty("readBack").GetBoolean(), "enregistrement réellement relu");
        Check.Contains("mémoire", result.GetProperty("receipt").GetProperty("text").GetString()!, "simulation non annoncée persistante");
        var page = SimulatedBridge.Json(await bridge.CallAsync("poste.layout.probe", localArguments));
        Check.Equal(key, page.GetProperty("probe").GetProperty("id").GetString(), "carte interprète cette définition exacte");
        Check.True(page.GetProperty("rows").GetArrayLength() > 0, "valeur du lecteur simulé rendue par le vrai consommateur Poste");
        Check.Contains(key, page.GetProperty("provenance").GetString()!, "provenance de version explicite");
        Check.Contains("First / Text", page.GetProperty("provenance").GetString()!, "mode et transformation exposés");
        Check.Equal(0, PosteSession.For(bridge.Source).Running().Length, "admission libérée après relecture");
        Check.Equal("poste.probeChanged", (await bridge.CallAsync("poste.personalProbe.run", JsonSerializer.Serialize(new { id, confirmed = true }))).Error!.Code, "plan consommé une seule fois");
    }

    [Test]
    public static async Task New_alias_version_does_not_reuse_old_values_and_missing_definition_blocks_cached_execution()
    {
        var bridge = new SimulatedBridge(); var home = AccueilService.From(bridge.Context); var computer = Target(bridge);
        var entry = (await PersonalProbeFixtures.Import(home, PersonalProbeFixtures.Document())).Catalog.Entries.Single();
        await PosteBoardLayouts.SaveAsync(bridge.Preferences, "Computer", [Card(entry.Key)], None);
        var service = PostePersonalProbes.From(bridge.Context);
        var plan = await service.PlanAsync(computer.DistinguishedName, computer.ObjectGuid, "team-card", None);
        var read = await service.RunAsync(plan.Id, true, None);
        var changed = (await PersonalProbeFixtures.Import(home, PersonalProbeFixtures.Document("Model"))).Catalog.Entries.Single(p => p.Key != entry.Key);
        Check.Equal(entry.Id, changed.Id, "même alias, autre version immuable");
        var old = (await bridge.Context.Readers.Require<IAccueilReader>().StoredProbesAsync(None)).ByProbe[entry.Key][computer.ObjectGuid];
        Check.False((await bridge.Context.Readers.Require<IAccueilReader>().StoredProbesAsync(None)).ByProbe.ContainsKey(changed.Key), "aucune copie du fabricant sous la clé du modèle");
        var empty = SimulatedBridge.Json(await bridge.CallAsync("poste.layout.probe", JsonSerializer.Serialize(new
        { dn = computer.DistinguishedName, computer = computer.ObjectGuid, probe = changed.Key, page = 1 })));
        Check.Equal(0, empty.GetProperty("rows").GetArrayLength(), "nouvelle version non collectée");
        await bridge.Preferences.SetAsync(PersonalProbeCatalog.PreferenceKey, JsonSerializer.SerializeToElement<object?>(null), None);
        Check.Equal(entry.Key, PosteBoardLayouts.Read(bridge.Preferences, "Computer").Items.Single().Key, "carte absente conservée pour diagnostic");
        var absent = await bridge.CallAsync("poste.layout.probe", JsonSerializer.Serialize(new
        { dn = computer.DistinguishedName, computer = computer.ObjectGuid, probe = entry.Key, page = 1 }));
        Check.Equal("probes.changed", absent.Error!.Code, "valeur en cache ne fournit pas une définition cachée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => service.PlanAsync(computer.DistinguishedName, computer.ObjectGuid, "team-card", None), "absence bloque le plan");
        await Check.ThrowsAsync<DomeniaOperationException>(() => PosteBoardLayouts.SaveAsync(bridge.Preferences, "Computer", [Card(entry.Key)], None), "absence bloque la sauvegarde/import de disposition");
        Check.Equal(old, (await bridge.Context.Readers.Require<IAccueilReader>().StoredProbesAsync(None)).ByProbe[entry.Key][computer.ObjectGuid], "aucune valeur de l’ancienne version réécrite");
        Check.True(read.Receipt.ReadBack, "lecture initiale bien passée par son reçu");
    }

    [Test]
    public static async Task Plan_refuses_pause_changed_identity_changed_account_expiration_and_unconfirmed_runs_before_reader()
    {
        var source = new HomePipelineSource(); using var context = source.Context();
        var key = (await PersonalProbeFixtures.Import(AccueilService.From(context), PersonalProbeFixtures.Document())).Catalog.Entries.Single().Key;
        var computer = source.Current.Directory.Computers.First();
        var service = PostePersonalProbes.From(context);
        async Task<PostePersonalProbePlan> Plan()
        {
            await PosteBoardLayouts.SaveAsync(context.Preferences, "Computer", [Card(key)], None);
            return await service.PlanAsync(computer.DistinguishedName, computer.ObjectGuid, "team-card", None);
        }
        var plan = await Plan();
        await Check.ThrowsAsync<DomeniaOperationException>(() => service.RunAsync(plan.Id, false, None), "confirmation absente");
        plan = await Plan();
        await PosteBoardLayouts.SaveAsync(context.Preferences, "Computer", [Card(key, paused: true)], None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => service.RunAsync(plan.Id, true, None), "carte mise en pause entre aperçu et confirmation");
        plan = await Plan();
        source.Current = source.Current with { Directory = source.Current.Directory with { Computers = source.Current.Directory.Computers.SetItem(0, computer with { DnsHostName = "other.test.local" }) } };
        await Check.ThrowsAsync<DomeniaOperationException>(() => service.RunAsync(plan.Id, true, None), "réaffectation de la cible refusée");
        source.Current = source.Current with { Directory = source.Current.Directory with { Computers = source.Current.Directory.Computers.SetItem(0, computer) } };
        plan = await Plan();
        MachineAccountService.From(context).UseRemote(@"TEST\another", null);
        await Check.ThrowsAsync<DomeniaOperationException>(() => service.RunAsync(plan.Id, true, None), "sélection de compte changée après préparation");
        plan = await Plan(); ((FixedTimeProvider)context.Clock).Advance(TimeSpan.FromMinutes(6));
        await Check.ThrowsAsync<DomeniaOperationException>(() => service.RunAsync(plan.Id, true, None), "plan expiré");
        Check.Equal(0, source.PresenceCalls + source.InventoryCalls, "aucun lecteur ni ping de substitution");
        Check.Equal(0, PosteSession.For(source).Running().Length, "aucune admission résiduelle après refus");
    }

    [Test]
    public static async Task Controllers_and_unrestorable_missing_versions_refuse_without_discarding_the_layout_history()
    {
        var source = new HomePipelineSource(); using var context = source.Context();
        var key = (await PersonalProbeFixtures.Import(AccueilService.From(context), PersonalProbeFixtures.Document())).Catalog.Entries.Single().Key;
        await PosteBoardLayouts.SaveAsync(context.Preferences, "Computer", [Card(key)], None);
        var empty = await PosteBoardLayouts.SaveAsync(context.Preferences, "Computer", [], None);
        var version = empty.History.First(v => v.Items.Any(i => i.Key == key));
        await context.Preferences.SetAsync(PersonalProbeCatalog.PreferenceKey, JsonSerializer.SerializeToElement<object?>(null), None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => PosteBoardLayouts.RestoreAsync(context.Preferences, "Computer", version.Id,
            empty.ChoiceToken, Fixtures.Now, None), "restauration sans définition exacte refusée");
        Check.True(PosteBoardLayouts.Read(context.Preferences, "Computer").Items.IsEmpty, "choix vide conservé");
        await PersonalProbeFixtures.Import(AccueilService.From(context), PersonalProbeFixtures.Document());
        await PosteBoardLayouts.SaveAsync(context.Preferences, "Computer", [Card(key)], None);
        var controller = source.Current.Directory.Computers.First() with { UserAccountControl = AdValues.ServerTrustAccount };
        source.Current = source.Current with { Directory = source.Current.Directory with { Computers = [controller] } };
        await Check.ThrowsAsync<DomeniaOperationException>(() => PostePersonalProbes.From(context).PlanAsync(controller.DistinguishedName, controller.ObjectGuid, "team-card", None), "DC exclu avant tout contact");
        Check.Equal(0, source.PresenceCalls + source.InventoryCalls, "exclusion n’est pas une mesure");
    }

    [Test]
    public static async Task Direct_legacy_migration_requires_the_profile_definition_before_its_conditional_write()
    {
        using var folder = new TemporaryFolder();
        using var preferences = new FilePreferenceStore(folder.File("poste-personal-migration.json"), new RecordingJournal());
        var probe = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        var source = JsonSerializer.SerializeToElement(new Dictionary<string, string>
        { ["Dashboard.Computer.Layout"] = JsonSerializer.Serialize(new[] { Card(probe.Key) }, PosteBoardLayouts.Json) });
        var sha = new string('a', 64);
        var preview = LegacyBoardLayouts.Parse(source, @"C:\D1\Domenia.settings.json", sha);
        await Check.ThrowsAsync<DomeniaOperationException>(() => LegacyBoardLayouts.ApplyAsync(preview, "Computer", sha, preferences, Fixtures.Now, None), "import direct sans définition refusé");
        Check.False(preferences.TryGet(PosteBoardLayouts.PreferenceKey("Computer"), out _), "aucun choix importé partiellement");
        Check.False(preferences.TryGet(PosteBoardLayouts.EvidenceKey("Computer"), out _), "aucune fausse preuve d’import");
        await preferences.SetAsync(PersonalProbeCatalog.PreferenceKey, PersonalProbeCatalog.Merge(PersonalProbeCatalog.Read(null), [probe]), None);
        Check.True(await LegacyBoardLayouts.ApplyAsync(preview, "Computer", sha, preferences, Fixtures.Now, None), "import après installation de la définition exacte");
        Check.Equal(probe.Key, PosteBoardLayouts.Read(preferences, "Computer").Items.Single().Key, "clé71 conservée dans le vrai fichier de préférences");
    }
}
