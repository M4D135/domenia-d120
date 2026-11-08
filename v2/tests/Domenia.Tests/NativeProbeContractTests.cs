using System.Security;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Accueil;
using Domenia.Inventory;
using ProbeCatalog = Domenia.Core.Accueil.ProbeCatalog;

namespace Domenia.Tests;

internal static class NativeProbeContractTests
{
    [Test]
    public static async Task Closed_isolation_plan_refuses_unknown_family_before_any_worker_or_capacity_admission()
    {
        var hello = new NativeReadHello("PC1", InventoryTransport.Dcom, 60000, true, null, true, true);
        Check.Equal(11, Enum.GetValues<NativeReadKind>().Length, "toutes les familles doivent être relues lorsqu’une valeur est ajoutée");
        foreach (var kind in Enum.GetValues<NativeReadKind>()) { Check.True(NativeIsolationPlan.Family(kind).Length > 0, "famille déclarée"); }
        Check.Equal(1U, NativeIsolationPlan.ProcessLimit, "un seul processus"); Check.Equal(512UL * 1024 * 1024, NativeIsolationPlan.MemoryLimit, "budget du job réel");
        using var client = new NativeReadClient(hello, null, default);
        await Check.ThrowsAsync<InvalidDataException>(() => client.ReadAsync(new((NativeReadKind)999, 1000)), "action refusée avant admission");
        Check.Null(client.ProcessId, "aucun processus lancé");
        Check.Throws<InvalidDataException>(() => new NativeReadClient(hello with { Session = false, Account = @"TEST\other" }, null, default), "aucune session implicite de repli");
        using var secret = new SecureString(); secret.AppendChar('x');
        using var credential = new RemoteProbeCredential(@"TEST\reader", secret.Copy(), false);
        Check.Throws<InvalidDataException>(() => new NativeReadClient(hello with { Session = false, Account = @"TEST\other" }, credential, default), "compte lié au secret fourni");
    }

    [Test]
    public static async Task Frozen_probe_budget_is_applied_to_the_real_reader_and_shared_projection_uses_twelve_seconds()
    {
        var clock = TestClock.Fixed(); var calls = 0; var reused = 0; TimeSpan? actualBudget = null; TimeSpan? actualQuery = null;
        var reader = new WmiFleetProbeReader(clock)
        {
            ProjectionReused = () => reused++,
            SessionFactory = (host, budget, token) =>
            {
                actualBudget = budget;
                return new(host, budget, clock, cancellationToken: token)
                { ReadOverride = (_, query, limit) =>
                    {
                        calls++;
                        if (query.Contains("Model", StringComparison.Ordinal)) { actualQuery = limit; }
                        return [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "PC1", ["DNSHostName"] = "PC1", ["Domain"] = "test.local", ["Model"] = "Portable", ["TotalPhysicalMemory"] = 1000L })];
                    } };
            },
        };
        var result = await reader.ReadAsync(Fixtures.Computer("PC1"), ["hw.model", "hw.ram"], CancellationToken.None);
        Check.Equal(TimeSpan.FromSeconds(54), actualBudget!.Value, "30 + 2 × 12 appliqué au lecteur");
        Check.Equal(TimeSpan.FromSeconds(12), actualQuery!.Value, "pas de délai de sonde inférieur à dix secondes");
        Check.Equal(2, calls, "identité puis union réelle des deux projections"); Check.Equal(1, reused, "un second appel effectivement évité");
        Check.True(result.Values.All(p => p.State == MeasureState.Known), "valeurs issues du relevé complet");
        Check.Equal(TimeSpan.FromSeconds(42), CimBudgets.ProbesFor(1), "petite sélection");
        Check.Equal(TimeSpan.FromSeconds(300), CimBudgets.ProbesFor(int.MaxValue), "plafond sans débordement arithmétique");
    }

    [Test]
    public static void Scalar_projection_is_bounded_in_escaped_UTF8_and_never_reports_truncated_values_as_complete()
    {
        var definition = ProbeCatalog.Find("hw.model")! with { Mode = "All" };
        var row = new WmiInstance(new Dictionary<string, object?> { ["Model"] = new string('é', 16000) });
        var result = WmiFleetProbeReader.Project(definition, new("model", SourceStatus.Ok, "Lu", 0, Enumerable.Repeat(row, 2000).ToArray()), Fixtures.Now);
        Check.Equal(MeasureState.Incomplete, result.State, "troncature explicite");
        Check.Equal(SourceStatus.Partial, result.FailureStatus!.Value, "statut typé");
        Check.True(result.Values.Length > 0 && result.Values.Length < 2000, "préfixe reçu conservé");
        Check.True(Encoding.UTF8.GetByteCount(JsonSerializer.Serialize(result.Values)) <= CimBudgets.ProbeResultBytes, "vrai JSON échappé dans 256 Kio");
    }

    [Test]
    public static void Progress_diagnostic_names_completed_sources_not_rows_and_keeps_final_times_after_disposal()
    {
        var clock = TestClock.Fixed(); var progress = new NativeReadProgress(clock, TimeSpan.FromSeconds(60), false, default);
        clock.Advance(TimeSpan.FromSeconds(5)); progress.Completed(); clock.Advance(TimeSpan.FromSeconds(20));
        var text = NativeReadProgress.Stopped(progress, "Arrêt utilisateur");
        Check.Contains("25.0 s", text, "temps total observé"); Check.Contains("20.0 s", text, "temps sans nouvelle source");
        Check.Contains("1 source(s) native(s) terminée(s)", text, "compteur réel, aucun compte de lignes inventé");
        Check.Contains("Délai sans nouvelle donnée atteint", text, "cause réelle");
        progress.Dispose(); clock.Advance(TimeSpan.FromHours(1));
        Check.Equal(text, NativeReadProgress.Stopped(progress, "Arrêt utilisateur"), "état final figé");
    }
}
