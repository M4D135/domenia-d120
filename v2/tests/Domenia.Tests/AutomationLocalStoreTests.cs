using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AutomationLocalStoreTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static AutomationRequest Request(string command, string? ou = null, int limit = 1000, string format = "Json") =>
        ShellAutomation.Validate(command, ou, ou is null && command is "postes" or "observations" or "associations" ? ["PC1"] : [], [], limit, format).Request!;

    [Test]
    public static async Task Legacy_schema_eleven_reads_without_v2_projection_migration_or_any_file_changes()
    {
        using var folder = new TemporaryFolder(); var store = await Seed(folder, Fixtures.Computer("PC1"));
        using (var db = new SqliteDatabase(store.Path, false))
            db.Script("DROP TABLE domenia_v2_objects; DROP TABLE domenia_v2_metadata; DELETE FROM schema_info WHERE key='domenia_schema';");
        var before = Digest(store.Path); var files = Files(folder);
        var answer = await DomeniaDatabase.ReadAutomationAsync(store.Path, Request("postes"), null, TestClock.Fixed(), None);
        Check.Equal("PC1", answer.Items.Single()!["Nom"]!.GetValue<string>(), "lecture directe de l’index D1");
        Check.True(answer.Source["LectureSeule"]!.GetValue<bool>(), "source locale déclarée");
        Check.Equal(before, Digest(store.Path), "octets de base inchangés");
        Check.True(files.SequenceEqual(Files(folder)), "aucun journal, cache, profil ou fichier de migration");
    }

    [Test]
    public static async Task Explicit_OU_is_unicode_case_insensitive_and_wildcards_are_literal()
    {
        using var folder = new TemporaryFolder();
        var chosen = Fixtures.Computer("PC1") with { DistinguishedName = "CN=PC1,OU=Été[*]," + Fixtures.Postes };
        var other = Fixtures.Computer("PC2") with { DistinguishedName = "CN=PC2,OU=ÉtéABC," + Fixtures.Postes };
        var store = await Seed(folder, chosen, other);
        var answer = await DomeniaDatabase.ReadAutomationAsync(store.Path, Request("postes", "OU=été[*]," + Fixtures.Postes), null, TestClock.Fixed(), None);
        Check.Equal(1, answer.Items.Count, "périmètre literal, pas de balayage élargi");
        Check.Equal(chosen.ObjectGuid.ToString("D"), answer.Items[0]!["Guid"]!.GetValue<string>(), "identité GUID exacte");
    }

    [Test]
    public static async Task Real_truncation_uses_a_sentinel_and_neutralized_csv_preserves_dated_local_rows()
    {
        using var folder = new TemporaryFolder();
        var store = await Seed(folder, Fixtures.Computer("PC1") with { Description = "=HYPERLINK(\"x\")" }, Fixtures.Computer("PC2"));
        var answer = await DomeniaDatabase.ReadAutomationAsync(store.Path, Request("postes", Fixtures.Postes, 1, "Csv"), null, TestClock.Fixed(), None);
        Check.Equal(1, answer.Items.Count, "borne exacte"); Check.True(answer.Truncated, "sentinelle réellement lue");
        Check.True(answer.Text().Contains("'=HYPERLINK", StringComparison.Ordinal), "formule CSV neutralisée");
        Check.True(answer.Items[0]!["SynchroniseUtc"] is not null, "date locale conservée");
        var exact = await DomeniaDatabase.ReadAutomationAsync(store.Path, Request("postes", Fixtures.Postes, 2), null, TestClock.Fixed(), None);
        Check.False(exact.Truncated, "deux lignes exactes ne prétendent pas à une troncature");
    }

    [Test]
    public static async Task Observations_include_current_console_inventory_presence_probes_and_choose_latest_family()
    {
        using var folder = new TemporaryFolder(); var computer = Fixtures.Computer("PC1"); var store = await Seed(folder, computer);
        using (var db = new SqliteDatabase(store.Path, false))
            db.Execute("INSERT INTO domenia_observations(object_guid,family,dn,attempt_at,status,payload,revision) VALUES(?1,'Presence',?2,?3,'Known',?4,1);",
                computer.ObjectGuid.ToString("D"), computer.DistinguishedName, Fixtures.Now.AddHours(-1).ToString("O"), "{\"Answered\":false,\"Password\":\"NE-PAS-EXPORTER\"}");
        var machines = ImmutableDictionary<Guid, MachineFacts>.Empty.Add(computer.ObjectGuid, new("TEST\\alice", Fixtures.Now, null, null, MeasureState.Known, Fixtures.Now, null));
        var personalKey = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single().Key;
        var personalAt = Fixtures.Now.AddMinutes(-2);
        var probes = new Domenia.Core.Accueil.ProbeReadings(ImmutableDictionary<string, ImmutableDictionary<Guid, Domenia.Core.Accueil.ProbeReading>>.Empty
            .Add("hw.model", ImmutableDictionary<Guid, Domenia.Core.Accueil.ProbeReading>.Empty.Add(computer.ObjectGuid, new(MeasureState.Known, Fixtures.Now, ["Modèle actuel"], null)))
            .Add(personalKey, ImmutableDictionary<Guid, Domenia.Core.Accueil.ProbeReading>.Empty.Add(computer.ObjectGuid,
                new(MeasureState.Incomplete, personalAt, ["Fabricant partiel"], "Qualification interrompue."))));
        await store.SaveFleetAsync(new(new(Fixtures.Now, [Fixtures.Observe(computer, Fixtures.Presence(true, TimeSpan.Zero), Fixtures.Disk(100, 40, TimeSpan.Zero))]), machines, [], probes), None);
        var before = Digest(store.Path); var files = Files(folder);
        var answer = await DomeniaDatabase.ReadAutomationAsync(store.Path, Request("observations"), null, TestClock.Fixed(), None);
        Check.Equal(5, answer.Items.Count, "quatre familles intégrées et une sonde personnelle, une seule présence fusionnée");
        var presence = answer.Items.Single(i => i!["Famille"]!.GetValue<string>() == "Presence")!;
        Check.True(presence["Donnees"]!["Answered"]!.GetValue<bool>(), "mesure v2 la plus récente retenue");
        Check.True(answer.Text().Contains("alice", StringComparison.Ordinal), "console v2 exportée");
        Check.False(answer.Text().Contains("NE-PAS-EXPORTER", StringComparison.Ordinal), "champs secrets jamais exposés");
        var filtered = await DomeniaDatabase.ReadAutomationAsync(store.Path, Request("observations"), "Probe:hw.model", TestClock.Fixed(), None);
        Check.Equal(1, filtered.Items.Count, "filtre familial appliqué aux deux sources");
        var personal = await DomeniaDatabase.ReadAutomationAsync(store.Path, Request("observations"), "Probe:" + personalKey, TestClock.Fixed(), None);
        var row = personal.Items.Single()!;
        Check.Equal("Probe:" + personalKey, row["Famille"]!.GetValue<string>(), "clé personnelle immuable conservée sans lecture de profil");
        Check.Equal("Fabricant partiel", row["Donnees"]![0]!.GetValue<string>(), "valeur locale réellement reçue exportée");
        Check.Equal(personalAt.ToString("O"), row["TentativeUtc"]!.GetValue<string>(), "date originale conservée");
        Check.Equal("Incomplete", row["Statut"]!.GetValue<string>(), "état partiel non promu en réussite");
        Check.Null(row["ReussiteUtc"], "aucune date de réussite inventée");
        Check.Equal(before, Digest(store.Path), "fusion uniquement en mémoire");
        Check.True(files.SequenceEqual(Files(folder)), "aucun profil ni fichier annexe créé par la lecture personnelle");
    }

    [Test]
    public static async Task Legacy_observation_payload_excludes_nested_secrets_without_inventing_success()
    {
        using var folder = new TemporaryFolder(); var computer = Fixtures.Computer("PC1"); var store = await Seed(folder, computer);
        using (var db = new SqliteDatabase(store.Path, false))
            db.Execute("INSERT INTO domenia_observations(object_guid,family,dn,attempt_at,status,payload,revision) VALUES(?1,'Inventory',?2,?3,'Error',?4,1);",
                computer.ObjectGuid.ToString("D"), computer.DistinguishedName, Fixtures.Now.ToString("O"), "{\"Model\":\"PC\",\"Nested\":{\"Token\":\"SECRET\"}}");
        var answer = await DomeniaDatabase.ReadAutomationAsync(store.Path, Request("observations"), null, TestClock.Fixed(), None);
        Check.Equal("Error", answer.Items.Single()!["Statut"]!.GetValue<string>(), "échec conservé");
        Check.Equal("", answer.Items.Single()!["ReussiteUtc"]!.GetValue<string>(), "aucune date de réussite inventée");
        Check.False(answer.Text().Contains("SECRET", StringComparison.Ordinal), "secret imbriqué exclu");
        Check.True(answer.ExcludedFields.Count > 0, "exclusion signalée");
    }

    [Test]
    public static async Task Current_v2_recipe_library_is_exported_instead_of_empty_legacy_tables()
    {
        using var folder = new TemporaryFolder(); var store = await Seed(folder, Fixtures.Computer("PC1"));
        var recipe = QueryRecipe.Empty(QueryTarget.Computer, "cli-recipe") with { Name = "Requête locale" };
        var compiled = QueryEngine.Compile(recipe);
        var document = JsonSerializer.SerializeToUtf8Bytes(new
        {
            format = QueryLibrary.DocumentFormat, version = QueryLibrary.DocumentVersion, generation = 1, domainKey = QueryLibrary.RootKey(Fixtures.Root),
            recipes = new[] { new { id = recipe.Id, definition = QueryRecipeJson.Write(compiled.Normalized), fingerprint = compiled.Fingerprint,
                revision = 1, archived = false, category = "Mes requêtes", createdAt = Fixtures.Now, updatedAt = Fixtures.Now } },
        });
        await store.UpdateQueryLibraryAsync(QueryLibrary.RootKey(Fixtures.Root), _ => new QueryStoreUpdate(document, false), None);
        var before = Digest(store.Path);
        var answer = await DomeniaDatabase.ReadAutomationAsync(store.Path, Request("requetes"), null, TestClock.Fixed(), None);
        Check.Equal("cli-recipe", answer.Items.Single()!["Id"]!.GetValue<string>(), "bibliothèque courante v2 lue");
        Check.Equal(compiled.Fingerprint, answer.Items.Single()!["Empreinte"]!.GetValue<string>(), "empreinte contrôlée");
        Check.Equal(before, Digest(store.Path), "aucune exécution ni mise à jour de requête");
    }

    [Test]
    public static async Task Personal_recipe_four_exports_its_exact_declaration_without_a_profile_or_any_file_changes()
    {
        using var folder = new TemporaryFolder(); var store = await Seed(folder, Fixtures.Computer("PC1"));
        var probe = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        var declaration = QueryProbeDeclaration.From(probe);
        var recipe = QueryRecipe.Empty(QueryTarget.Computer, "cli-personal") with
        {
            Format = QueryRecipe.FormatV4, Name = "Fabricant personnel",
            Clauses = [new(QueryCatalog.ProbePrefix + probe.Key, QueryOperator.Equal, QueryValue.FromText("Fabricant"))],
            PersonalProbes = [declaration],
        };
        var compiled = QueryEngine.Compile(recipe);
        var document = JsonSerializer.SerializeToUtf8Bytes(new
        {
            format = QueryLibrary.DocumentFormat, version = QueryLibrary.DocumentVersion, generation = 1, domainKey = QueryLibrary.RootKey(Fixtures.Root),
            recipes = new[] { new { id = recipe.Id, definition = QueryRecipeJson.Write(compiled.Normalized), fingerprint = compiled.Fingerprint,
                revision = 1, archived = false, category = "Mes requêtes", createdAt = Fixtures.Now, updatedAt = Fixtures.Now } },
        });
        await store.UpdateQueryLibraryAsync(QueryLibrary.RootKey(Fixtures.Root), _ => new QueryStoreUpdate(document, false), None);
        var before = Digest(store.Path); var files = Files(folder);
        var answer = await DomeniaDatabase.ReadAutomationAsync(store.Path, Request("requetes"), null, TestClock.Fixed(), None);
        var row = answer.Items.Single()!;
        Check.Equal(4, row["VersionDefinition"]!.GetValue<int>(), "version de déclaration reconnue en lecture locale");
        Check.Equal(compiled.Fingerprint, row["Empreinte"]!.GetValue<string>(), "empreinte exacte contrôlée sans exécution");
        var exported = row["Definition"]!["PersonalProbes"]![0]!;
        Check.Equal(probe.Key, exported["Key"]!.GetValue<string>(), "version personnelle conservée");
        Check.Equal(declaration.Document, exported["Document"]!.GetValue<string>(), "contrat canonique exact conservé comme donnée");
        Check.Equal(before, Digest(store.Path), "base inchangée");
        Check.True(files.SequenceEqual(Files(folder)), "aucun profil, journal ou fichier annexe créé");
    }

    [Test]
    public static async Task Wal_or_active_journal_is_refused_before_native_read_without_sidecar_creation()
    {
        using var folder = new TemporaryFolder(); var store = await Seed(folder, Fixtures.Computer("PC1"));
        File.WriteAllText(store.Path + "-journal", "fixture de journal actif");
        var before = Digest(store.Path); var files = Files(folder);
        await Check.ThrowsAsync<InvalidDataException>(() => DomeniaDatabase.ReadAutomationAsync(store.Path, Request("etat"), null, TestClock.Fixed(), None), "journal actif refusé");
        Check.Equal(before, Digest(store.Path), "base inchangée"); Check.True(files.SequenceEqual(Files(folder)), "aucun fichier annexe créé ni effacé");
    }

    private static async Task<DomeniaDatabase> Seed(TemporaryFolder folder, params DirectoryComputer[] computers)
    {
        var store = new DomeniaDatabase(folder.File("local.db"), Fixtures.Root, TestClock.Fixed());
        await store.InitializeAsync(None);
        await store.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [.. computers]), new(Fixtures.Postes, "Postes", true), "DC1.test.local", None);
        return store;
    }
    private static string Digest(string path) => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
    private static string[] Files(TemporaryFolder folder) => Directory.GetFiles(folder.Path, "*", SearchOption.AllDirectories).Order(StringComparer.Ordinal).ToArray();
}
