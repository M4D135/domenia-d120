using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class WorkstationQuickDiagTests
{
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));

    private static WmiWorkstationReader Reader(List<string> queries, bool servicesRefused = false, bool duplicateVolume = false)
    {
        var clock = TestClock.Fixed();
        return new(clock) { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
        {
            ReadOverride = (_, query, _) =>
            {
                queries.Add(query);
                if (query.Contains("Win32_ComputerSystem", StringComparison.Ordinal)) { return [Row(("Name", "PC1"))]; }
                if (query.Contains("Win32_OperatingSystem", StringComparison.Ordinal))
                { return [Row(("Caption", "Windows 11"), ("Version", "10.0"), ("LastBootUpTime", "20261020120000.000000+000"))]; }
                if (query.Contains("Win32_LogicalDisk", StringComparison.Ordinal))
                {
                    var row = Row(("DeviceID", "C:"), ("Size", 100_000_000_000L), ("FreeSpace", 25_000_000_000L));
                    return duplicateVolume ? [row, row] : [row];
                }
                if (servicesRefused) { throw new UnauthorizedAccessException(); }
                return [Row(("Name", "Winmgmt"), ("State", "Running"), ("StartMode", "Auto"))];
            },
            RegistryOverride = (_, _) => throw new InvalidOperationException("Le diagnostic rapide ne lit aucun registre"),
            InventoryShellOverride = (_, _) => throw new InvalidOperationException("Le diagnostic rapide ne crée aucun shell"),
        } };
    }

    [Test]
    public static async Task Quick_diagnosis_uses_four_bounded_queries_without_software_registry_or_shells()
    {
        var queries = new List<string>();
        var reading = await Reader(queries).ReadAsync("PC1", WorkstationReading.QuickDiagnostic, null, CancellationToken.None);
        Check.Equal(4, queries.Count, "identité, un OS, un volume, services sélectionnés");
        Check.Equal(1, queries.Count(q => q.Contains("Win32_OperatingSystem", StringComparison.Ordinal)), "démarrage et OS partagent le même relevé");
        Check.True(queries.Single(q => q.Contains("Win32_LogicalDisk", StringComparison.Ordinal)).Contains("WHERE DeviceID='C:'", StringComparison.Ordinal), "volume annoncé uniquement");
        var raw = AdPosteReader.QuickRaw(reading, [(135, true), (445, false), (5985, true)], 1500);
        var view = PosteDiagnostics.QuickFacts("PC1", raw, Fixtures.Now, TestClock.Paris, "reader");
        Check.True(view.Complete, "cinq contrôles réellement concluants"); Check.Equal(5, view.Facts.Length, "cinq faits");
        Check.True(raw.ServiceResults.Single(r => r.Name == "Winmgmt").Present, "service lu");
        Check.False(raw.ServiceResults.Single(r => r.Name == "RpcSs").Present, "absence seulement après liste complète");
    }

    [Test]
    public static async Task Refused_management_services_do_not_become_missing_services()
    {
        var reading = await Reader([], servicesRefused: true).ReadAsync("PC1", WorkstationReading.QuickDiagnostic, null, CancellationToken.None);
        var raw = AdPosteReader.QuickRaw(reading, [(135, true), (445, true), (5985, true)], 2000);
        Check.Equal(SourceStatus.Refused, raw.Services!.Status, "refus conservé");
        Check.Equal(0, raw.ServiceResults.Length, "aucune fausse absence");
        Check.False(PosteDiagnostics.QuickFacts("PC1", raw, Fixtures.Now, TestClock.Paris, "reader").Complete, "résumé incomplet");
    }

    [Test]
    public static async Task Ambiguous_disk_and_partial_ports_never_create_a_complete_diagnosis()
    {
        var reading = await Reader([], duplicateVolume: true).ReadAsync("PC1", WorkstationReading.QuickDiagnostic, null, CancellationToken.None);
        Check.Equal(0, reading.Volumes.Length, "pas de choix arbitraire parmi deux volumes C:");
        var raw = AdPosteReader.QuickRaw(reading, [(135, true), (445, null), (5985, false)], 2000);
        Check.Null(raw.SizeBytes, "espace disque non conclu"); Check.Equal(SourceStatus.Partial, raw.Ports!.Status, "port interrompu reste inconnu");
        var view = PosteDiagnostics.QuickFacts("PC1", raw, Fixtures.Now, TestClock.Paris, "reader");
        Check.False(view.Complete, "deux contrôles incomplets");
        Check.True(view.Facts.Single(f => f.Label == "Ports 135/445/5985").Limit!.Contains("partielle", StringComparison.Ordinal), "limite visible même si deux ports ont répondu");
    }

    [Test]
    public static async Task Partial_sources_with_some_valid_fields_still_prevent_the_complete_flag()
    {
        var reading = await Reader([]).ReadAsync("PC1", WorkstationReading.QuickDiagnostic, null, CancellationToken.None);
        var raw = AdPosteReader.QuickRaw(reading, [(135, true), (445, true), (5985, true)], 2000);
        raw = raw with { System = new(SourceStatus.Partial, "OS partiellement lu") };
        var view = PosteDiagnostics.QuickFacts("PC1", raw, Fixtures.Now, TestClock.Paris, "reader");
        Check.False(view.Complete, "valeurs utiles ne rendent pas la source complète");
        Check.Equal(FactState.Observed, view.Facts[0].State, "valeur lue conservée");
        Check.True(view.Facts[0].Limit!.Contains("partielle", StringComparison.Ordinal), "limite de la source conservée");
    }
}
