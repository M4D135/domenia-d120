using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class PosteDetailProjectionTests
{
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));
    private static WmiWorkstationReader Reader(Func<string, IEnumerable<WmiInstance>> rows)
    {
        var clock = TestClock.Fixed();
        return new(clock) { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
        { ReadOverride = (_, query, _) => query.Contains("SELECT Name, DNSHostName, Domain FROM Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"))] : rows(query) } };
    }

    [Test]
    public static async Task Native_probe_projection_keeps_complete_rows_with_explicit_byte_and_cell_limits()
    {
        var native = Reader(_ => Enumerable.Range(0, 100).Select(i => Row(("DeviceID", "C:"), ("VolumeName", i + new string('é', 1500)), ("Size", 100L), ("FreeSpace", 0L))));
        var read = await native.ReadProbesAsync("PC1", ["disk.volumes"], null, default);
        var values = read.Values["disk.volumes"];
        Check.False(values.Complete, "la borne d’octets n’est pas une réussite complète");
        Check.True(values.OmittedRows > 0, "lignes hors budget comptabilisées");
        Check.Equal(100, values.Rows.Length + values.OmittedRows, "toutes les lignes reçues sont comptées");
        Check.True(System.Text.Encoding.UTF8.GetByteCount(JsonSerializer.Serialize(values.Rows)) < PosteProbeCache.ProjectionBytes, "projection inférieure à 96 Kio");
        var known = Reader(_ => [Row(("SMBIOSBIOSVersion", new string('x', 3000)), ("ReleaseDate", new DateTimeOffset(2025, 1, 2, 14, 0, 0, TimeSpan.FromHours(2))))]);
        var dates = (await known.ReadProbesAsync("PC1", ["hw.biosdetails"], null, default)).Values["hw.biosdetails"];
        Check.Equal(1, dates.Rows.Length, "une instance contenant une date CLR traverse aussi la garde CIM");
        var definition = ProbeCatalog.Find("hw.biosdetails")!;
        Check.Equal(3000, dates.Rows[0][definition.Properties.IndexOf("SMBIOSBIOSVersion")].GetString()!.Length, "valeur sous 16 Kio conservée intégralement");
        Check.Equal("2025-01-02T12:00:00.0000000Z", dates.Rows[0][definition.Properties.IndexOf("ReleaseDate")].GetString(), "offset connu normalisé en UTC");
        var unknown = Reader(_ => [Row(("ReleaseDate", new DateTime(2025, 1, 2, 14, 0, 0, DateTimeKind.Unspecified)))]);
        var uncertain = (await unknown.ReadProbesAsync("PC1", ["hw.biosdetails"], null, default)).Values["hw.biosdetails"];
        Check.Equal(1, uncertain.Rows.Length, "la date inconnue écarte une cellule, pas toute la ligne");
        Check.Equal(JsonValueKind.Null, uncertain.Rows[0][definition.Properties.IndexOf("ReleaseDate")].ValueKind, "aucun fuseau horaire inventé");
        Check.Equal(1, uncertain.OmittedCells, "date sans offset explicitement écartée");
    }

    [Test]
    public static void Details_support_two_thousand_stored_rows_and_selected_pages_up_to_five_hundred()
    {
        var definition = ProbeCatalog.Find("disk.volumes")!;
        var rows = Enumerable.Range(0, 2000).Select(i => definition.Properties.Select(p => JsonSerializer.SerializeToElement<object?>(p == "DeviceID" ? i.ToString(System.Globalization.CultureInfo.InvariantCulture) : null)).ToImmutableArray()).ToImmutableArray();
        var hash = ProbeDefinitionIdentity.Of(definition);
        var store = new ProbeStore("PC1", null, [new(definition.Id, ProbeState.Read, Fixtures.Now, Fixtures.Now, null, 2000) { DefinitionHash = hash }], [], [], [], Fixtures.Now)
        { ReportedName = "PC1", HostIdentity = new("PC1.test.local", "PC1", "PC1", "test.local"), Values = ImmutableDictionary<string, ProbeValues>.Empty.Add(definition.Id, new(Fixtures.Now, true, rows) { DefinitionHash = hash, Columns = definition.Properties }) };
        PosteProbeCache.Validate(store, Fixtures.Now);
        var page = PosteProbeDetails.Build(store, definition, 4, TimeZoneInfo.Utc, Fixtures.Now, 500);
        Check.Equal(500, page.Rows.Length, "page choisie de cinq cents lignes");
        Check.Equal(4, page.Pages, "pagination de toutes les deux mille lignes");
        Check.Equal("1500", page.Rows[0][0], "offset exact de la quatrième page");
        Check.Equal("1999", page.Rows[^1][0], "dernière ligne conservée");
        Check.Throws<ArgumentOutOfRangeException>(() => PosteProbeDetails.Build(store, definition, 1, TimeZoneInfo.Utc, Fixtures.Now, 501), "borne de page fermée");
    }
}
