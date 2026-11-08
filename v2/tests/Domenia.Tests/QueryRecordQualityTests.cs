using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class QueryRecordQualityTests
{
    [Test]
    public static void A_fresh_presence_never_renews_inventory_or_console_clocks()
    {
        var pc = Fixtures.Computer("PC1");
        var old = TimeSpan.FromDays(31);
        var dataset = HomeQueryDraftTests.Dataset(pc, Fixtures.Observe(pc, Fixtures.Presence(true, TimeSpan.Zero), Fixtures.Disk(100, 30, old)), new(@"TEST\user", Fixtures.Now - old, null));
        var record = QueryRecordBuilder.Computer(dataset, pc.ObjectGuid, Fixtures.Now)!;
        Check.Equal("En ligne", record.Value("presence") as string, "présence récente utilisable");
        Check.Equal("Expiré", record.State("diskFreePercent"), "inventaire périmé, pas zéro");
        Check.Equal("Expiré", record.State("user"), "console périmée indépendamment");
        Check.True(record.Value("diskFreePercent") is null && record.Value("user") is null, "aucune valeur inconnue transformée en mesure");
        Check.Equal(Fixtures.Now, record.Clocks["presence"], "horloge présence");
        Check.Equal(Fixtures.Now - old, record.Clocks["inventory"], "horloge inventaire conservée");
        Check.Equal(Fixtures.Now - old, record.Clocks["console"], "horloge console conservée");
    }

    [Test]
    public static void Record_builder_keeps_expiry_boundary_failures_partial_reads_and_future_dates_explicit()
    {
        var pc = Fixtures.Computer("PC1");
        QueryRecord Build(PresenceMeasure presence, InventoryMeasure? inventory = null) =>
            QueryRecordBuilder.Computer(HomeQueryDraftTests.Dataset(pc, Fixtures.Observe(pc, presence, inventory)), pc.ObjectGuid, Fixtures.Now)!;
        Check.Equal("Disponible", Build(Fixtures.Presence(true, TimeSpan.FromDays(30))).State("presence"), "30 jours exacts encore utilisables");
        Check.Equal("Expiré", Build(Fixtures.Presence(true, TimeSpan.FromDays(30) + TimeSpan.FromSeconds(1))).State("presence"), "au-delà de 30 jours");
        foreach (var (state, label) in new[] { (MeasureState.Error, "Erreur de lecture"), (MeasureState.Incomplete, "Lecture incomplète"), (MeasureState.Refused, "Accès refusé") })
        {
            var record = Build(Fixtures.Presence(true, TimeSpan.Zero) with { State = state });
            Check.Equal(label, record.State("presence"), "cause conservée");
            Check.True(record.Value("presence") is null, "échec sans valeur inventée");
        }
        Check.Equal("Date de relevé inconnue", Build(Fixtures.Presence(true, TimeSpan.FromMinutes(-6))).State("presence"), "date future de plus de cinq minutes non admise");
        var partial = Build(Fixtures.Presence(true, TimeSpan.Zero), Fixtures.Disk(100, 30, TimeSpan.Zero) with { State = MeasureState.Incomplete });
        Check.Equal("Lecture incomplète", partial.State("diskFreePercent"), "qualité inventaire explicite");
        Check.True(partial.Value("diskFreePercent") is null, "inventaire incomplet jamais utilisé comme zéro");
    }
}
