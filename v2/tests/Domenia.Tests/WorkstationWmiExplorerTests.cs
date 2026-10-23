using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class WorkstationWmiExplorerTests
{
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));
    private static WmiInstance Property(string name, string type = "String", bool key = false) => Row(("Name", name), ("Type", type), ("Key", key), ("Qualifiers", key ? "Key, Read" : "Read"));
    private static string Metadata(object[] rows, string host = "PC1", string ns = @"root\cimv2", string? cls = "Win32_Process", string kind = "Properties", int code = 0) =>
        JsonSerializer.Serialize(new { Format = "Domenia.WmiMetadata/1", Computer = host, Namespace = ns, Class = cls, Kind = kind, Code = code, Partial = false, Rows = rows });

    [Test]
    public static void WMI_metadata_is_bound_to_namespace_class_host_and_hides_sensitive_names()
    {
        var payload = Metadata([new { Name = "Name", Type = "String", Key = false, Qualifiers = "Read" }, new { Name = "Password", Type = "String", Key = false, Qualifiers = "Read" }]);
        var result = CimSession.ParseMetadata(WmiMetadataKind.Properties, @"root\cimv2", "Win32_Process", "PC1.test.local", payload);
        Check.Equal(1, result.Items, "attribut sensible écarté"); Check.Equal("Name", result.Instances[0].Text("Name"), "schéma non secret retenu");
        var duplicates = CimSession.ParseMetadata(WmiMetadataKind.Properties, @"root\cimv2", "Win32_Process", "PC1",
            Metadata([new { Name = "Name", Type = "String", Key = false, Qualifiers = "Read" }, new { Name = "name", Type = "UInt32", Key = true, Qualifiers = "Key" }]));
        Check.Equal(SourceStatus.Partial, duplicates.Status, "propriété ambiguë signalée"); Check.Equal(0, duplicates.Items, "aucun choix arbitraire de définition");
        Check.Throws<JsonException>(() => CimSession.ParseMetadata(WmiMetadataKind.Properties, @"root\other", "Win32_Process", "PC1", payload), "espace différent refusé");
        Check.Throws<JsonException>(() => CimSession.ParseMetadata(WmiMetadataKind.Properties, @"root\cimv2", "Win32_Service", "PC1", payload), "classe différente refusée");
        Check.Throws<JsonException>(() => CimSession.ParseMetadata(WmiMetadataKind.Properties, @"root\cimv2", "Win32_Process", "OTHER", payload), "poste différent refusé");
    }

    [Test]
    public static void WMI_projection_is_explicit_bounded_and_keeps_keys_and_filter_properties()
    {
        var schema = Enumerable.Range(0, 80).Select(n => new WmiProperty("Field" + n, "String", n == 79, "Read")).ToImmutableArray()
            .Add(new("CommandLine", "String", false, "Read")).Add(new("Password", "String", false, "Read")).Add(new("Nested", "Instance", false, "Read"));
        var (query, selected) = WmiWorkstationReader.ExplorerProjection(new(@"root\cimv2", "Custom_Class", "Field78='x'", 25), schema);
        Check.Equal(64, selected.Length, "plafond de propriétés"); Check.True(selected.Any(p => p.Name == "Field79"), "clé conservée");
        Check.True(selected.Any(p => p.Name == "Field78"), "propriété du filtre conservée");
        Check.False(query.Contains('*'), "aucun SELECT étoile envoyé");
        Check.False(query.Contains("CommandLine", StringComparison.Ordinal) || query.Contains("Password", StringComparison.Ordinal) || query.Contains("Nested", StringComparison.Ordinal), "valeurs sensibles et objets imbriqués exclus");
        Check.True(CimQuery.IsReadOnlySelect(query), "garde commune conservée");
    }

    [Test]
    public static async Task WMI_forbidden_queries_are_rejected_before_identity_or_metadata_contact()
    {
        var calls = 0; var clock = TestClock.Fixed();
        var reader = new WmiWorkstationReader(clock) { SessionFactory = (_, _, _) => { calls++; throw new InvalidOperationException("Aucun contact autorisé"); } };
        foreach (var request in new[]
        {
            new WmiRequest(@"root\cimv2", "Win32_Product", null, 25),
            new WmiRequest(@"root\cimv2", "Win32_Process", "CommandLine='private'", 25),
            new WmiRequest(@"root\cimv2", "Win32_UserAccount", null, 25),
            new WmiRequest(@"root\cimv2", "Win32_Process", "Name='x';DELETE FROM Win32_Process", 25),
        })
        { await Check.ThrowsAsync<QueryDefinitionException>(() => reader.ReadWmiQueryAsync("PC1", request, CancellationToken.None), "requête refusée avant contact"); }
        Check.Equal(0, calls, "aucune connexion ni lecture d’identité");
    }

    [Test]
    public static async Task WMI_explorer_projects_only_safe_columns_and_preserves_rows_received_before_stop()
    {
        var clock = TestClock.Fixed(); using var stop = new CancellationTokenSource();
        IEnumerable<WmiInstance> Instances()
        {
            yield return Row(("Name", "first"), ("ProcessId", 42), ("CommandLine", "NEVER-RETAIN"));
            stop.Cancel();
            yield return Row(("Name", "second"), ("ProcessId", 43));
        }
        var reader = new WmiWorkstationReader(clock) { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
        {
            MetadataOverride = (_, _, _, _) => [Property("Name"), Property("ProcessId", "UInt32", true), Property("CommandLine")],
            ReadOverride = (_, query, _) => query.Contains("Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC1"))] : Instances(),
        } };
        var result = await reader.ReadWmiQueryAsync("PC1", new(@"root\cimv2", "Win32_Process", null, 25), stop.Token);
        Check.Equal(SourceStatus.Partial, result.Status, "arrêt partiel"); Check.Equal(1, result.Rows.Length, "ligne déjà reçue conservée");
        Check.True(result.Rows[0].Contains("first"), "première ligne");
        Check.False(result.Rows.SelectMany(r => r).Any(v => v?.Contains("NEVER-RETAIN", StringComparison.Ordinal) == true), "aucun argument de commande publié");
    }

    [Test]
    public static void Native_CIM_limits_and_projection_limits_do_not_turn_oversized_values_into_absence()
    {
        using var session = new CimSession("PC1", TimeSpan.FromSeconds(10), TestClock.Fixed())
        { ReadOverride = (_, _, _) => [Row(("Name", new string('x', 32769)))] };
        var result = session.Read("Test", @"root\cimv2", "SELECT Name FROM Win32_Process", 500);
        Check.Equal(SourceStatus.Partial, result.Status, "première instance hors limites ne signifie pas aucune instance");
        Check.Equal(0, result.Items, "valeur démesurée écartée");
        var partial = false;
        var text = WmiWorkstationReader.ExplorerValue(new string('x', 3000), ref partial);
        Check.True(partial, "troncature affichée"); Check.Equal(2048, text!.Length, "valeur UI bornée");
        partial = false; var cyclic = new object[1]; cyclic[0] = cyclic;
        _ = WmiWorkstationReader.ExplorerValue(cyclic, ref partial);
        Check.True(partial, "tableau récursif borné");
    }

    [Test]
    public static void WMI_metadata_shells_cannot_receive_a_free_fragment_or_invoke_a_requested_class_method()
    {
        var script = WsmanReadChannel.MetadataScript(WmiMetadataKind.Properties, @"root\cimv2", "Win32_Process");
        Check.True(script.Contains("$definition=Get-CimClass", StringComparison.Ordinal), "définition seule");
        Check.False(script.Contains("Invoke-CimMethod", StringComparison.Ordinal), "aucune méthode");
        Check.Throws<ArgumentException>(() => WsmanReadChannel.MetadataScript(WmiMetadataKind.Properties, "root';x", "Win32_Process"), "espace injecté refusé");
        Check.Throws<QueryDefinitionException>(() => WsmanReadChannel.MetadataScript(WmiMetadataKind.Properties, @"root\cimv2", "Win32_Product"), "MSI refusé avant le shell");
        using var disabled = new CimSession("PC1", TimeSpan.FromSeconds(20), TestClock.Fixed()) { ReadsEnabled = false, MetadataOverride = (_, _, _, _) => throw new InvalidOperationException("Contact interdit") };
        Check.Equal(SourceStatus.Skipped, disabled.ReadMetadata(WmiMetadataKind.Classes, @"root\cimv2").Status, "réglage respecté");
    }
}
