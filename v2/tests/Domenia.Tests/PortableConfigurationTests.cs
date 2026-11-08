using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class PortableConfigurationTests
{
    [Test]
    public static void Export_selected_allowlist_including_working_OU_and_valid_interface_roundtrips_without_local_identity()
    {
        var scope = WorkingScope.PreferencePrefix + new string('a', 64);
        var values = new Dictionary<string, JsonElement>
        {
            [scope] = JsonSerializer.SerializeToElement(new { dn = "OU=Equipe,DC=example,DC=invalid", subtree = true }),
            [PreferenceApproval.WindowKey] = JsonSerializer.SerializeToElement(new { secret = "never-export" }),
            [SettingsViewRules.ConnectionKey] = JsonSerializer.SerializeToElement(new { user = "local-account" }),
            ["future.option"] = JsonSerializer.SerializeToElement("future-value"),
        };
        var selected = PortableConfiguration.WithDefaults(values).Keys.Where(PreferenceApproval.IsApproved).ToArray();
        var ui = JsonSerializer.SerializeToElement(new { theme = "dark", motion = "reduced", profile = "essentiel", density = "normal", navCollapsed = true, helpTips = false, logWrap = true, logSize = 14 });
        var exported = PortableConfiguration.Export(values, selected, ui, "Annuaire", TestClock.Reference);
        var read = PortableConfiguration.Read(exported.Text);
        Check.Equal(5, read.Values.Count, "allowlist entière, y compris OU explicitement choisie et valeurs par défaut");
        Check.True(JsonElement.DeepEquals(values[scope], read.Values[scope]), "DN et booléen conservés exactement, indépendamment de l’indentation de l’export");
        Check.Equal("dark", read.Interface!.Value.GetProperty("theme").GetString(), "interface validée conservée");
        Check.True(exported.Excluded.Contains(PreferenceApproval.WindowKey) && exported.Excluded.Contains(SettingsViewRules.ConnectionKey), "exclusions affichables par noms");
        Check.False(exported.Text.Contains("never-export", StringComparison.Ordinal) || exported.Text.Contains("local-account", StringComparison.Ordinal), "aucun contenu local exclu dans le fichier");
        Check.Equal(exported.Sha256, read.Sha256, "empreinte UTF8 stable");
    }

    [Test]
    public static void Working_OU_is_not_exported_without_the_explicit_selection()
    {
        var key = WorkingScope.PreferencePrefix + new string('b', 64);
        var values = new Dictionary<string, JsonElement> { [key] = JsonSerializer.SerializeToElement(new { dn = "OU=Equipe,DC=example,DC=invalid", subtree = false }) };
        var export = PortableConfiguration.Export(values, [PreferenceApproval.ZoomKey], null, "Annuaire", TestClock.Reference);
        Check.Equal(1, PortableConfiguration.Read(export.Text).Values.Count, "uniquement la sélection opérateur");
        Check.True(export.Excluded.Contains(key), "OU exclue annoncée");
    }

    [Test]
    public static void Seed_rejects_unknown_local_nested_secret_and_invalid_interface_fields_whole()
    {
        var original = PortableConfiguration.Export(new Dictionary<string, JsonElement>(), [PreferenceApproval.ZoomKey], null, "Annuaire", TestClock.Reference).Text;
        foreach (var change in new Action<JsonObject>[]
        {
            root => root["future"] = true,
            root => root["values"]![SettingsViewRules.ConnectionKey] = new JsonObject { ["login"] = "no" },
            root => root["values"]![StoragePolicyRules.PreferenceKey] = new JsonObject { ["automaticBackup"] = false, ["password"] = "no" },
            root => root["values"]![WorkingScope.PreferencePrefix + new string('a', 64)] = new JsonObject { ["dn"] = "OU=Equipe,DC=example,DC=invalid", ["password"] = "no" },
            root => root["interface"] = new JsonObject { ["theme"] = "invented" },
            root => root["interface"] = new JsonObject { ["recentPages"] = new JsonArray("#/fiche?dn=private") },
            root => root["version"] = 2,
        })
        {
            var document = JsonNode.Parse(original)!.AsObject(); change(document);
            Check.Throws<InvalidDataException>(() => PortableConfiguration.Read(document.ToJsonString()), "aucune reprise partielle d’une configuration inconnue");
        }
        Check.Throws<InvalidDataException>(() => PortableConfiguration.Read(original.Replace("\"values\":", "\"values\":{},\"values\":", StringComparison.Ordinal)), "doublons refusés");
        Check.Throws<InvalidDataException>(() => PortableConfiguration.Read(new string(' ', PortableConfiguration.MaxBytes + 1)), "borne UTF8");
    }

    [Test]
    public static void Local_seed_file_is_bounded_preserves_exact_bytes_and_distinguishes_text_and_file_hash_with_BOM()
    {
        using var folder = new TemporaryFolder(); var path = folder.File(PortableConfiguration.FileName);
        Check.True(PortableConfigurationFile.Read(path, CancellationToken.None) is null, "absence réelle");
        var exported = PortableConfiguration.Export(new Dictionary<string, JsonElement>(), [PreferenceApproval.ZoomKey], null, "Annuaire", TestClock.Reference);
        File.WriteAllText(path, exported.Text, new UTF8Encoding(true));
        var before = File.ReadAllBytes(path);
        var read = PortableConfigurationFile.Read(path, CancellationToken.None) ?? throw new TestFailureException("Source absente.");
        Check.Equal(exported.Sha256, read.Document.Sha256, "texte sans BOM qualifié");
        Check.False(read.FileSha256 == read.Document.Sha256, "SHA de fichier exact distinct du texte");
        Check.True(before.SequenceEqual(File.ReadAllBytes(path)), "source jamais réécrite");
        File.WriteAllBytes(path, new byte[PortableConfiguration.MaxBytes + 1]);
        Check.Throws<InvalidDataException>(() => PortableConfigurationFile.Read(path, CancellationToken.None), "aucune allocation non bornée");
    }
}
