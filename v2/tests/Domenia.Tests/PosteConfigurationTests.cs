using System.Text;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class PosteConfigurationTests
{
    private static PosteConfiguration Parse(string json) => PosteConfiguration.Parse(Encoding.UTF8.GetBytes(json));

    [Test]
    public static void Workstation_configuration_keeps_D1_defaults_and_honours_explicit_false_values()
    {
        var defaults = Parse("{}");
        Check.True(defaults.Options.UseWinRm && defaults.UseCim && defaults.UseRemoteRegistry, "défauts D1");
        Check.False(defaults.Options.WakeOnLan || defaults.UseSecurityLog || defaults.AllowRemoteArtifacts, "gestes intrusifs désactivés par défaut");
        var settings = Parse("""{"remote":{"UseWinRM":false,"UseCim":false,"UseRemoteRegistry":false,"UseProfilesShare":false,"UseTaskFallback":false,"UsePsExecFallback":false,"PortTimeoutMs":99999},"Restart":{"DefaultDelaySeconds":1}}""");
        Check.False(settings.Options.UseWinRm || settings.UseCim || settings.UseRemoteRegistry || settings.UseProfilesShare || settings.UseTaskFallback || settings.UsePsExecFallback, "faux conservés");
        Check.Equal(5000, settings.PortTimeoutMs, "délai TCP borné"); Check.Equal(60, settings.Options.RestartDelaySeconds, "délai de redémarrage borné");
        Check.Equal(2, settings.Warnings.Length, "corrections annoncées");
        settings = Parse("""{"Remote":{"UseWinRM":"false"},"Features":{"WakeOnLan":"true"}}""");
        Check.True(settings.Options.UseWinRm, "texte non pris pour un booléen"); Check.False(settings.Options.WakeOnLan, "pas d’activation par conversion permissive");
        Check.Equal(2, settings.Warnings.Length, "valeurs mal typées annoncées");
    }

    [Test]
    public static void Workstation_configuration_refuses_duplicate_keys_and_does_not_retain_unknown_secret_fields()
    {
        foreach (var json in new[] { "[]", "{", """{"Remote":{"UseWinRM":false,"usewinrm":true}}""", """{"Suite":{},"suite":{}}""" })
        { Check.Equal(ConfigurationFileState.Invalid, Parse(json).State, "fichier ambigu refusé"); }
        var settings = Parse("""{"Remote":{"UseWinRM":false},"Password":"PRIVATE-NEVER-KEEP"}""");
        Check.False(System.Text.Json.JsonSerializer.Serialize(settings).Contains("PRIVATE-NEVER-KEEP", StringComparison.Ordinal), "champ étranger non conservé");
        Check.Equal(ConfigurationFileState.Invalid, PosteConfiguration.Parse(new byte[LegacyConfiguration.MaxBytes + 1]).State, "taille bornée");
    }

    [Test]
    public static void Suite_declarations_require_both_absolute_executable_and_hash_without_resolving_the_file()
    {
        var json = "{\"Suite\":{\"PestoPath\":\"C:\\\\Suite\\\\Pesto.exe\",\"PestoSha256\":\"" + new string('a', 64) + "\",\"FilProPath\":\"relative.exe\",\"FilProSha256\":\"" + new string('b', 64) + "\"}}";
        var tools = Parse(json).Options.SuiteTools;
        Check.True(tools[0].Configured, "déclaration absolue avec empreinte");
        Check.Equal(new string('A', 64), tools[0].Sha256, "empreinte normalisée");
        Check.False(tools[1].Configured, "chemin relatif refusé"); Check.Null(tools[1].Path, "chemin relatif non proposé au lanceur");
        Check.False(Parse("""{"Suite":{"PestoPath":"C:\\Suite\\Pesto.exe"}}""").Options.SuiteTools[0].Configured, "empreinte exigée");
    }

    [Test]
    public static void Wake_configuration_never_expands_a_malformed_or_unaligned_network()
    {
        var settings = Parse("""{"Features":{"WakeOnLan":true},"WakeOnLan":{"AllowedNetworks":["10.0.0.0/8","10.0.0.0/8","10.1.2.3/24","0.0.0.0/0","127.0.0.0/8","192.168.2.0/24",123]}}""");
        Check.True(settings.Options.WakeNetworks.SequenceEqual(["10.0.0.0/8", "192.168.2.0/24"]), "périmètre exact, sans ajout implicite");
        Check.Equal(4, settings.Warnings.Length, "entrées rejetées annoncées");
        settings = Parse("""{"Features":{"WakeOnLan":true}}""");
        Check.True(settings.Options.WakeNetworks.IsEmpty && settings.Options.WakeReason.Contains("Aucun réseau", StringComparison.Ordinal), "activation sans périmètre reste sans cible autorisée");
    }

    [Test]
    public static async Task Disabling_CIM_or_registry_prevents_native_queries_in_all_inventory_paths()
    {
        var calls = 0;
        using var disabled = new CimSession("PC1", TimeSpan.FromSeconds(30), TestClock.Fixed(), transport: InventoryTransport.WinRm)
        {
            ReadsEnabled = false,
            ReadOverride = (_, _, _) => { calls++; throw new InvalidOperationException(); },
            RegistryOverride = (_, _) => { calls++; throw new InvalidOperationException(); },
            AppxOverride = _ => { calls++; throw new InvalidOperationException(); },
            InventoryShellOverride = (_, _) => { calls++; throw new InvalidOperationException(); },
        };
        Check.Equal(SourceStatus.Skipped, disabled.Read("test", @"root\cimv2", "SELECT Name FROM Win32_ComputerSystem", 1).Status, "CIM arrêté avant contact");
        Check.Equal(SourceStatus.Skipped, disabled.ReadRegistry(new(InventoryRegistry.Machine, InventoryRegistry.WindowsVersion, "UBR", RegistryMethod.Dword)).Status, "registre arrêté");
        Check.Equal(SourceStatus.Skipped, disabled.ReadAppx().Status, "shell Appx arrêté");
        Check.Equal(SourceStatus.Skipped, disabled.ReadInventoryShell(InventoryShellRead.Tasks).Status, "shell tâches arrêté");
        Check.Equal(SourceStatus.Skipped, disabled.ReadLocalAdmins().Status, "NetAPI non atteint après garde CIM");
        using var noRegistry = new CimSession("PC1", TimeSpan.FromSeconds(30), TestClock.Fixed())
        { RegistryEnabled = false, RegistryOverride = (_, _) => { calls++; throw new InvalidOperationException(); } };
        Check.Equal(SourceStatus.Skipped, noRegistry.ReadRegistry(new(InventoryRegistry.Machine, InventoryRegistry.WindowsVersion, "UBR", RegistryMethod.Dword)).Status, "registre seul désactivé");
        var off = PosteConfiguration.Defaults with { UseCim = false };
        var probe = new WmiWorkstationProbe(TestClock.Fixed()) { SessionFactory = (_, _, _) => { calls++; throw new InvalidOperationException(); } };
        var light = await probe.ReadFactsAsync("PC1", TimeSpan.FromSeconds(15), CancellationToken.None, null, off);
        Check.False(light.Inventory.HasReading, "aucun faux inventaire léger");
        var fleet = new WmiFleetProbeReader(TestClock.Fixed()) { SessionFactory = (_, _, _) => { calls++; throw new InvalidOperationException(); } };
        _ = await fleet.ReadAsync(Fixtures.Computer("PC1"), [], CancellationToken.None, null, off);
        Check.Equal(0, calls, "aucun moteur natif démarré");
    }

    [Test]
    public static void Local_workstation_configuration_load_distinguishes_absence_and_oversized_file()
    {
        var folder = Path.Combine(Path.GetTempPath(), "Domenia-config-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var file = Path.Combine(folder, "Domenia.config.json");
            Check.Equal(ConfigurationFileState.Absent, PosteSettingsFileReader.Load(file).Value.State, "absence expliquée");
            File.WriteAllText(file, "{\"Remote\":{\"UseWinRM\":false}}");
            Check.False(PosteSettingsFileReader.Load(file).Value.Options.UseWinRm, "réglage réel lu");
            using (var stream = File.OpenWrite(file)) { stream.SetLength(LegacyConfiguration.MaxBytes + 1); }
            Check.Equal(ConfigurationFileState.Invalid, PosteSettingsFileReader.Load(file).Value.State, "taille vérifiée avant lecture");
        }
        finally { Directory.Delete(folder, recursive: true); }
    }
}
