using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class PosteDisplayParityTests
{
    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(v => v.Name, v => v.Value));

    [Test]
    public static void Graphics_projection_never_turns_missing_zero_or_invalid_mode_into_a_resolution()
    {
        var rows = new[] { Row(("DeviceID", "GPU0"), ("Name", "Graphique réel"), ("CurrentHorizontalResolution", 1920U), ("CurrentVerticalResolution", 1080U), ("DriverVersion", "1.2")),
            Row(("DeviceID", "GPU1"), ("CurrentHorizontalResolution", 0U), ("CurrentVerticalResolution", 1080U)),
            Row(("Name", "GPU2"), ("CurrentHorizontalResolution", uint.MaxValue), ("CurrentVerticalResolution", "inconnu")) };
        var projected = WmiWorkstationReader.ProjectVideoControllers(new(InventoryCategories.Displays, SourceStatus.Ok, "Lu", 1, rows), TestClock.Reference);
        Check.Equal(SourceStatus.Partial, projected.Status, "champs absents signalés");
        Check.Equal<int?>(1920, projected.Controllers[0].Width, "vraie résolution horizontale");
        Check.Equal<int?>(1080, projected.Controllers[0].Height, "vraie résolution verticale");
        Check.Null(projected.Controllers[1].Width, "zéro n’est pas une résolution");
        Check.Null(projected.Controllers[2].Width, "valeur hors plage inconnue");
        Check.Equal("Résolution non lue", PosteDisplaySummary.Resolution(projected.Controllers[1]), "pas de paire inventée");
        var refused = WmiWorkstationReader.ProjectVideoControllers(new(InventoryCategories.Displays, SourceStatus.Refused, "Refus", 1, rows), TestClock.Reference);
        Check.Equal(0, refused.Controllers.Length, "aucune valeur exposée sous source refusée");
    }

    [Test]
    public static async Task Explicit_inventory_reads_video_once_and_keeps_EDID_separate_with_cache_and_native_transport_roundtrip()
    {
        var clock = TestClock.Fixed(); var queries = new List<string>();
        var reader = new WmiWorkstationReader(clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
            { RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, query, _) =>
                {
                    queries.Add(query);
                    return query.Contains("FROM Win32_VideoController", StringComparison.Ordinal)
                        ? [Row(("DeviceID", "GPU0"), ("Name", "Carte réelle"), ("CurrentHorizontalResolution", 2560U), ("CurrentVerticalResolution", 1440U), ("DriverVersion", "2.3"))] : [];
                } },
        };
        var snapshot = await reader.ReadAsync("PC1", WorkstationReading.Quick, null, CancellationToken.None);
        Check.Equal(1, queries.Count(q => q.Contains("FROM Win32_VideoController", StringComparison.Ordinal)), "une acquisition physique explicite");
        Check.Equal(0, snapshot.Displays.Length, "aucun moniteur EDID inventé depuis la carte graphique");
        Check.Equal(clock.GetUtcNow(), snapshot.VideoControllers!.At, "preuve datée");
        var cached = JsonSerializer.Deserialize<InventorySnapshot>(JsonSerializer.Serialize(snapshot))!;
        Check.Equal("Carte réelle", cached.VideoControllers!.Controllers.Single().Name, "cache JSON conserve le type optionnel");
        using var stream = new MemoryStream();
        await NativeReadProtocol.WriteAsync(stream, snapshot, NativeReadProtocol.ResponseLimit, CancellationToken.None); stream.Position = 0;
        var transported = await NativeReadProtocol.ReadAsync<InventorySnapshot>(stream, NativeReadProtocol.ResponseLimit, CancellationToken.None);
        Check.Equal<int?>(2560, transported.VideoControllers!.Controllers.Single().Width, "transport natif strict compatible");
        var summary = PosteDisplaySummary.Build(transported, TimeZoneInfo.Utc);
        Check.Equal("Carte réelle", summary.Value, "vraie carte sur le tableau");
        Check.Contains(FrenchText.Integer(2560) + " × " + FrenchText.Integer(1440) + " pixels", summary.Detail!, "résolution déclarée exposée");
        var without = snapshot with { VideoControllers = null };
        Check.False(JsonSerializer.Serialize(without).Contains("VideoControllers", StringComparison.Ordinal), "ancien format sans propriété conservé");
        Check.Equal("Non lu", PosteDisplaySummary.Build(without, TimeZoneInfo.Utc).Value, "ancien cache ne devient pas une absence constatée");
        Check.Null(snapshot.WithStatus([InventoryCategories.Displays], SourceStatus.Refused, "Refus").VideoControllers, "refus explicite retire toute valeur graphique");
    }
}
