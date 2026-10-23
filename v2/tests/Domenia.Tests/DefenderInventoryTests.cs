using System.Runtime.InteropServices;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class DefenderInventoryTests
{
    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(v => v.Name, v => v.Value));
    private static WmiWorkstationReader Reader(Func<string, IEnumerable<WmiInstance>> read, Func<RegistryRequest, RegistryReply>? registry = null)
    {
        var clock = TestClock.Fixed();
        return new(clock) { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
        { ReadOverride = (_, q, _) => read(q), RegistryOverride = (r, _) => registry?.Invoke(r) ?? new(2, null) } };
    }

    [Test]
    public static async Task Defender_is_read_without_SecurityCenter_and_its_never_updated_sentinel_is_explained()
    {
        var reader = Reader(q => q.Contains("FROM AntiVirusProduct", StringComparison.Ordinal) ? throw new COMException("not installed", unchecked((int)0x80041010))
            : q.StartsWith("SELECT AMRunningMode", StringComparison.Ordinal) ? [Row(("AMRunningMode", "Normal"))]
            : q.Contains("FROM MSFT_MpComputerStatus", StringComparison.Ordinal) ? [Row(("AntivirusEnabled", true), ("RealTimeProtectionEnabled", true), ("BehaviorMonitorEnabled", true), ("AntivirusSignatureAge", 65535U), ("QuickScanAge", 2U), ("FullScanAge", 65535U))]
            : []);
        var result = await reader.ReadAsync("PC1", WorkstationReading.Quick, null, CancellationToken.None);
        Check.Equal<bool?>(true, result.Defender?.RealTime, "Defender lu malgré le Centre de sécurité absent");
        Check.Equal<bool?>(false, result.Defender!.Passive, "mode normal explicitement lu");
        Check.Equal("Signatures jamais mises à jour", result.Defender.SignaturesText, "sentinelle expliquée");
        Check.Equal(Tone.Warn, result.Defender.ProtectionTone, "aucune protection à jour affirmée");
        var computer = Fixtures.Computer("PC1");
        var header = PosteHeaderRules.Computer(computer, Fixtures.Snapshot(computers: [computer]), new Dictionary<string, string>());
        var board = PosteBoardBuilder.Build(header, result, PosteHealthPolicy.Default, Fixtures.Now, TimeZoneInfo.Utc);
        var text = System.Text.Json.JsonSerializer.Serialize(board);
        Check.True(text.Contains("Defender", StringComparison.Ordinal), "Defender visible");
        var grid = InventoryRows.Build(result, board, "Test", Fixtures.Now, TimeZoneInfo.Utc);
        Check.True(grid.Rows.Any(row => row.Item == "Defender · signatures" && row.Label == "Signatures jamais mises à jour"), "même fait dans la grille et son export");
        Check.False(text.Contains("Aucun produit actif", StringComparison.Ordinal), "absence du Centre de sécurité non assimilée à Defender inactif");
    }

    [Test]
    public static async Task Defender_unknown_states_do_not_become_inactive_or_healthy_and_scan_state_is_not_guessed()
    {
        var reader = Reader(q => q.StartsWith("SELECT AMRunningMode", StringComparison.Ordinal) ? [Row(("AMRunningMode", "EDR Block Mode"))]
            : q.Contains("FROM MSFT_MpComputerStatus", StringComparison.Ordinal) ? [Row(("AntivirusSignatureAge", uint.MaxValue))] : []);
        var result = await reader.ReadAsync("PC1", WorkstationReading.Quick, null, CancellationToken.None);
        var defender = result.Defender!;
        Check.Null(defender.RealTime, "protection inconnue"); Check.Null(defender.SignatureAgeDays, "âge hors domaine inconnu");
        Check.Null(defender.Passive, "EDR Block Mode conservé sans réduction arbitraire à actif/passif");
        Check.Equal("EDR Block Mode", defender.RunningMode, "mode déclaré conservé"); Check.Null(defender.ScanRunning, "aucune analyse en cours déduite de dates passées");
        Check.Equal("Protection en temps réel non établie", defender.ProtectionText, "inconnu n’est pas inactif");
        Check.Equal(Tone.Off, defender.ProtectionTone, "pas de vert sur une protection inconnue");
        Check.Equal(Tone.Warn, (defender with { RealTime = false }).ProtectionTone, "une protection connue inactive reste un avertissement même sans âge");
        Check.Equal(SourceStatus.Partial, result.StatusOf(InventoryCategories.Antivirus), "données incomplètes déclarées");
    }

    [Test]
    public static async Task Windows_revision_and_release_are_declared_only_in_inventory_not_the_short_survey()
    {
        var calls = 0;
        var reader = Reader(q => q.Contains("FROM Win32_OperatingSystem", StringComparison.Ordinal) ? [Row(("Caption", "Windows 11"), ("Version", "10.0.26100"), ("BuildNumber", "26100"))]
            : q.Contains("FROM Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC1"))] : [], r =>
            { calls++; return r.Key != InventoryRegistry.WindowsVersion ? new(2, null) : r.Name == "UBR" ? new(0, 0U) : new(0, "24H2"); });
        var survey = await reader.ReadAsync("PC1", WorkstationReading.Survey, null, CancellationToken.None);
        Check.Equal(0, calls, "aucun registre ajouté au relevé court"); Check.Null(survey.Os!.Revision, "révision non lue reste inconnue");
        var inventory = await reader.ReadAsync("PC1", WorkstationReading.Quick, null, CancellationToken.None);
        Check.Equal<int?>(0, inventory.Os!.Revision, "révision zéro conservée"); Check.Equal("24H2", inventory.Os.DisplayVersion, "version déclarée distincte du build");
    }
}
