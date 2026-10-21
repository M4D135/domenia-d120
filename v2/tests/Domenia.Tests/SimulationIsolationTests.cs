using System.Reflection;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class SimulationIsolationTests
{
    private static readonly string[] ForbiddenAssemblies =
    [
        "System.DirectoryServices", "System.Management", "System.Net", "Microsoft.Web.WebView2",
        "Domenia.Ad", "Domenia.Inventory", "Domenia.Store", "Domenia.Bridge", "Domenia.Engine",
    ];

    [Test]
    public static void Simulation_references_only_core_and_the_base_library()
    {
        foreach (var assembly in new[] { typeof(SimulatedDirectorySource).Assembly, typeof(DashboardCalculator).Assembly })
        {
            var names = assembly.GetReferencedAssemblies().Select(a => a.Name ?? "").ToList();
            foreach (var name in names)
            {
                Check.False(ForbiddenAssemblies.Any(f => name.StartsWith(f, StringComparison.OrdinalIgnoreCase)), $"{assembly.GetName().Name} ne doit pas référencer {name}");
            }
        }
        Check.True(typeof(SimulatedDirectorySource).Assembly.GetReferencedAssemblies().Any(a => a.Name == "Domenia.Core"), "référence à Domenia.Core");
    }

    [Test]
    public static void Directory_source_has_no_write_method()
    {
        string[] verbs = ["Write", "Set", "Delete", "Move", "Reset", "Unlock", "Enable", "Disable", "Add", "Remove", "Create", "Update"];
        foreach (var method in typeof(IDirectorySource).GetMethods())
        {
            Check.False(verbs.Any(v => method.Name.StartsWith(v, StringComparison.Ordinal)), "méthode d’écriture : " + method.Name);
        }
        Check.True(typeof(IDirectorySource).IsAssignableFrom(typeof(SimulatedDirectorySource)), "la simulation est une source d’annuaire");
    }

    [Test]
    public static void Simulation_screen_readers_depend_on_the_simulated_source_only()
    {
        var readers = typeof(SimulatedDirectorySource).Assembly.GetExportedTypes().Where(t => typeof(IScreenReader).IsAssignableFrom(t) && t.IsClass).ToList();
        Check.True(readers.Count >= 1, "au moins un lecteur d’écran simulé");
        foreach (var reader in readers)
        {
            var parameters = reader.GetConstructors().Single().GetParameters();
            Check.True(parameters.Length == 1 && parameters[0].ParameterType == typeof(SimulatedDirectorySource), "construit sur la source simulée : " + reader.Name);
            Check.Equal("Domenia.Simulation", reader.Namespace, "espace de noms de la simulation : " + reader.Name);
        }
    }

    [Test]
    public static async Task Responses_and_snapshot_carry_no_secret()
    {
        var bridge = new SimulatedBridge();
        var responses = new List<JsonElement>
        {
            SimulatedBridge.Json(await bridge.CallAsync("session.info")),
            SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary")),
            SimulatedBridge.Json(await bridge.CallAsync("dashboard.widget.refresh", "{\"id\":\"watchlist\"}")),
            SimulatedBridge.Json(await bridge.CallAsync("directory.ou.children", "{\"dn\":null}")),
            SimulatedBridge.Json(await bridge.CallAsync("directory.ou.search", "{\"text\":\"comptes\"}")),
            SimulatedBridge.Json(await bridge.CallAsync("session.setScope", "{\"dn\":\"OU=Paris,OU=Postes,DC=example,DC=local\",\"subtree\":true}")),
        };
        using (var info = JsonDocument.Parse(JsonSerializer.Serialize(AppInfoBuilder.Build(ModeResolver.Resolve(["--simulation"], null, () => new DomainJoinInfo(DomainJoinState.Unknown, null)), "10", "windows"), BridgeJson.Options)))
        {
            responses.Add(info.RootElement.Clone());
        }
        foreach (var response in responses)
        {
            AssertNoSecretName(response, insideWidgets: false);
        }

        Type[] records = [typeof(DirectoryUser), typeof(DirectoryComputer), typeof(DirectoryGroup), typeof(DirectoryOu), typeof(DomainInfo), typeof(InventoryMeasure), typeof(PresenceMeasure)];
        foreach (var property in records.SelectMany(t => t.GetProperties(BindingFlags.Public | BindingFlags.Instance)))
        {
            var name = property.Name;
            Check.False(name.Contains("BitLocker", StringComparison.OrdinalIgnoreCase) || name.Contains("Recovery", StringComparison.OrdinalIgnoreCase)
                || name.Contains("Secret", StringComparison.OrdinalIgnoreCase), "aucune clé ni secret : " + name);
            if (name.Contains("Laps", StringComparison.OrdinalIgnoreCase))
            {
                Check.True(name is "Laps" or "LapsExpiration", "LAPS : date d’expiration seulement, " + name);
            }
            Check.False(name.Equals("Password", StringComparison.OrdinalIgnoreCase) || name.Contains("AdmPwd", StringComparison.OrdinalIgnoreCase), "aucun mot de passe : " + name);
        }
    }

    private static void AssertNoSecretName(JsonElement element, bool insideWidgets)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    // Widget identifiers (such as « passwordsExpiring ») are keys of « widgets », not data fields.
                    if (!insideWidgets)
                    {
                        foreach (var word in new[] { "password", "pwd", "secret" })
                        {
                            Check.False(property.Name.Contains(word, StringComparison.OrdinalIgnoreCase), "nom de propriété JSON : " + property.Name);
                        }
                    }
                    AssertNoSecretName(property.Value, insideWidgets: !insideWidgets && property.Name == "widgets");
                }
                break;
            case JsonValueKind.Array:
                foreach (var item in element.EnumerateArray())
                {
                    AssertNoSecretName(item, insideWidgets: false);
                }
                break;
            default:
                break;
        }
    }
}
