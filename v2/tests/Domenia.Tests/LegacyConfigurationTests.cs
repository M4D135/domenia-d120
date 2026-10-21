using System.Text;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class LegacyConfigurationTests
{
    private static readonly Func<DomainJoinInfo> Joined = () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local");

    private static LegacyConfiguration Parse(string text) => LegacyConfiguration.Parse(Encoding.UTF8.GetBytes(text));

    [Test]
    public static void Demo_provider_starts_the_simulation_with_the_configuration_reason()
    {
        var decision = ModeResolver.Resolve([], null, Joined, () => true);
        Check.Equal(AppMode.Simulation, decision.Mode, "simulation");
        Check.Equal(ModeReason.Configuration, decision.Reason, "raison configuration");
        Check.Equal(ModeTexts.DetailConfiguration, decision.Detail, "texte du contrat");
        Check.Equal(ModeTexts.Banner, decision.Banner, "bannière de simulation");
        using var info = JsonDocument.Parse(JsonSerializer.Serialize(AppInfoBuilder.Build(decision, "10", "embarque"), BridgeJson.Options));
        Check.Equal("configuration", info.RootElement.GetProperty("modeReason").GetString(), "texte JSON de la raison");
        Check.Equal("simulation", info.RootElement.GetProperty("mode").GetString(), "mode");
    }

    [Test]
    public static void Configuration_comes_after_the_argument_and_the_variable_and_before_the_join_state()
    {
        var reads = 0;
        bool Demo()
        {
            reads++;
            return true;
        }
        var probes = 0;
        DomainJoinInfo Probe()
        {
            probes++;
            return new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local");
        }
        Check.Equal(ModeReason.Argument, ModeResolver.Resolve(["--simulation"], null, Probe, Demo).Reason, "argument d’abord");
        Check.Equal(ModeReason.Environment, ModeResolver.Resolve([], "1", Probe, Demo).Reason, "variable à 1 ensuite");
        var optOut = ModeResolver.Resolve([], "0", Probe, Demo);
        Check.Equal(AppMode.Directory, optOut.Mode, "DOMENIA_SIMULATION=0 l’emporte sur la configuration");
        Check.Equal(0, reads, "configuration jamais lue quand un réglage plus fort décide");
        Check.Equal(ModeReason.Configuration, ModeResolver.Resolve([], null, Probe, Demo).Reason, "configuration avant la jonction");
        Check.Equal(0, probes, "jonction jamais sondée quand la configuration décide");
        var joined = ModeResolver.Resolve([], null, Probe, () => false);
        Check.Equal(ModeReason.DomainJoined, joined.Reason, "configuration sans démonstration : règle de jonction");
        Check.Equal(ModeReason.DomainJoined, ModeResolver.Resolve([], null, Probe).Reason, "sans lecteur de configuration : comme avant");
    }

    [Test]
    public static void Only_the_json_boolean_true_enables_the_demo_provider()
    {
        Check.True(Parse("""{"Auth":{"DemoProvider":true}}""").DemoProvider, "booléen JSON true");
        Check.True(Parse("""{"auth":{"demoprovider":true},"Streaming":{}}""").DemoProvider, "casse ignorée comme ConvertFrom-Json");
        foreach (var text in new[] { """{"Auth":{"DemoProvider":"true"}}""", """{"Auth":{"DemoProvider":1}}""", """{"Auth":{"DemoProvider":false}}""",
            """{"Auth":{"LoginWindowMode":"Standard"}}""", """{"Auth":true}""", """{"Streaming":{"VerifyUserOnSelection":true}}""", "{}" })
        {
            var result = Parse(text);
            Check.Equal(ConfigurationFileState.Read, result.State, "fichier lu : " + text);
            Check.False(result.DemoProvider, "démonstration non activée : " + text);
        }
        var withBom = LegacyConfiguration.Parse([0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes("""{"Auth":{"DemoProvider":true}}""")]);
        Check.True(withBom.DemoProvider, "marque d’ordre des octets admise (fichiers de Domenia 1)");
    }

    [Test]
    public static void Invalid_files_are_ignored_with_a_fixed_reason()
    {
        foreach (var text in new[] { "{pas du json", "[]", "null", """{"Auth":{"DemoProvider":true}} reste""", """{"Auth":{"DemoProvider":true},}""",
            """{/* commentaire */"Auth":{"DemoProvider":true}}""", """{"Auth":{"DemoProvider":true},"AUTH":{}}""", """{"Auth":{"DemoProvider":true,"demoProvider":false}}""" })
        {
            var result = Parse(text);
            Check.Equal(ConfigurationFileState.Invalid, result.State, "fichier invalide : " + text);
            Check.False(result.DemoProvider, "jamais de démonstration depuis un fichier invalide");
            Check.False(string.IsNullOrEmpty(result.Problem), "raison donnée");
            Check.False(result.Problem!.Contains("DemoProvider\":", StringComparison.Ordinal), "contenu jamais recopié");
        }
        var large = Parse("{\"x\":\"" + new string('a', LegacyConfiguration.MaxBytes) + "\"}");
        Check.Equal(ConfigurationFileState.Invalid, large.State, "plus de 1 Mo");
    }

    [Test]
    public static void File_next_to_the_executable_never_blocks_the_start()
    {
        using var folder = new TemporaryFolder();
        var journal = new RecordingJournal();
        var absent = LegacyConfigurationFile.Read(folder.Path, journal);
        Check.Equal(ConfigurationFileState.Absent, absent.State, "absent");
        Check.True(journal.Lines.Any(l => l.StartsWith("INFO Domenia.config.json absent", StringComparison.Ordinal)), "absence journalisée");

        File.WriteAllText(folder.File(LegacyConfiguration.FileName), """{"Auth":{"DemoProvider":true,"Secret":"motdepasse-a-ne-pas-recopier"}}""", new UTF8Encoding(true));
        var demo = LegacyConfigurationFile.Read(folder.Path, journal);
        Check.True(demo.DemoProvider, "fichier de Domenia 1 avec BOM lu");

        File.WriteAllText(folder.File(LegacyConfiguration.FileName), """{"Auth":{"DemoProvider":true,"Secret":"motdepasse-a-ne-pas-recopier"} oups""");
        var invalid = LegacyConfigurationFile.Read(folder.Path, journal);
        Check.Equal(ConfigurationFileState.Invalid, invalid.State, "fichier invalide");
        Check.False(invalid.DemoProvider, "aucune démonstration");
        Check.True(journal.Lines.Any(l => l.StartsWith("ATTENTION Domenia.config.json ignoré", StringComparison.Ordinal)), "invalidité journalisée");
        Check.False(journal.Lines.Any(l => l.Contains("motdepasse", StringComparison.Ordinal)), "contenu jamais journalisé");
        Check.False(journal.Lines.Any(l => l.Contains(folder.Path, StringComparison.OrdinalIgnoreCase)), "chemin jamais journalisé");

        // A folder in place of the file: unreadable, still never blocking.
        File.Delete(folder.File(LegacyConfiguration.FileName));
        Directory.CreateDirectory(folder.File(LegacyConfiguration.FileName));
        Check.False(LegacyConfigurationFile.Read(folder.Path, journal).DemoProvider, "dossier à la place du fichier");
    }
}
