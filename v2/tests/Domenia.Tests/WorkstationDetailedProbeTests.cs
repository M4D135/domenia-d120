using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;
using DetailedCatalog = Domenia.Core.Poste.ProbeCatalog;

namespace Domenia.Tests;

internal static class WorkstationDetailedProbeTests
{
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));
    private static WmiWorkstationReader Reader(Func<string, IEnumerable<WmiInstance>> query)
    {
        var clock = TestClock.Fixed();
        return new(clock) { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token) { ReadOverride = (_, sql, _) => query(sql) } };
    }

    internal static ProbeStore Store(string id, DateTimeOffset at, params (string Key, object? Value)[] values)
    {
        var map = values.ToDictionary(v => v.Key, v => v.Value); var columns = DetailedCatalog.Find(id)!.Properties;
        var payload = new ProbeValues(at, true, [[.. columns.Select(p => JsonSerializer.SerializeToElement(map.GetValueOrDefault(p)))]]);
        return new("PC1", null, [new(id, ProbeState.Read, at, at, null, 1) { DataAt = at }], [], [], [], at)
        { ReportedName = "PC1", Values = ImmutableDictionary<string, ProbeValues>.Empty.Add(id, payload) };
    }

    [Test]
    public static async Task Detailed_probe_reads_only_requested_columns_and_keeps_numeric_zero()
    {
        var queries = new List<string>();
        var reader = Reader(q => { queries.Add(q); return q.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
            ? [Row(("Name", "PC1"))] : [Row(("DeviceID", "C:"), ("Size", 1000L), ("FreeSpace", 0L), ("Password", "MUST_NOT_BE_COPIED"))]; });
        var result = await reader.ReadProbesAsync("PC1.test.local", ["disk.volumes"], null, CancellationToken.None);
        Check.Equal(2, queries.Count, "identité puis une seule sonde ; aucune source implicite");
        Check.True(queries[1].Contains("WHERE DriveType=3", StringComparison.Ordinal), "filtre du catalogue exact");
        var values = result.Values["disk.volumes"];
        Check.True(values.Complete, "lecture complète");
        Check.Equal(0L, values.Rows[0][4].GetInt64(), "zéro numérique conservé");
        Check.False(JsonSerializer.Serialize(result).Contains("MUST_NOT_BE_COPIED", StringComparison.Ordinal), "colonnes supplémentaires non conservées");
    }

    [Test]
    public static async Task Cancelling_detailed_probe_keeps_rows_already_received_without_claiming_completion()
    {
        using var stop = new CancellationTokenSource();
        IEnumerable<WmiInstance> Answers(string query)
        {
            if (query.Contains("Win32_ComputerSystem", StringComparison.Ordinal)) { yield return Row(("Name", "PC1")); yield break; }
            yield return Row(("DeviceID", "C:"), ("Size", 1000L), ("FreeSpace", 300L));
            stop.Cancel();
            yield return Row(("DeviceID", "D:"), ("Size", 2000L), ("FreeSpace", 1000L));
        }
        var result = await Reader(Answers).ReadProbesAsync("PC1", ["disk.volumes", "hw.memoryusage"], null, stop.Token);
        Check.Equal(1, result.Values["disk.volumes"].Rows.Length, "première ligne conservée");
        Check.False(result.Values["disk.volumes"].Complete, "liste interrompue non complète");
        Check.Equal(SourceStatus.Interrupted, result.Access.Single(a => a.Category == "hw.memoryusage").Status, "sonde suivante inconnue");
    }

    [Test]
    public static async Task Unknown_probe_and_failed_identity_never_contact_additional_providers()
    {
        var calls = 0;
        var reader = Reader(q => { calls++; return [Row(("Name", "OTHER"))]; });
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadProbesAsync("PC1", ["arbitrary.query"], null, CancellationToken.None), "sélection inconnue refusée");
        Check.Equal(0, calls, "aucun contact pour une sélection inconnue");
        var result = await reader.ReadProbesAsync("PC1", ["disk.volumes", "hw.memoryusage"], null, CancellationToken.None);
        Check.Equal(1, calls, "identité étrangère arrête les sondes"); Check.Equal(0, result.Values.Count, "aucune valeur attribuée au mauvais poste");
    }

    [Test]
    public static async Task Detailed_probe_arrays_remain_arrays_and_oversized_values_are_partial()
    {
        var reader = Reader(q => q.Contains("Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC1"))]
            : [Row(("InstanceName", new string('x', 2049)), ("Active", true), ("UserFriendlyName", new ushort[] { 65, 66, 0 }))]);
        var result = await reader.ReadProbesAsync("PC1", ["hw.monitors"], null, CancellationToken.None);
        var row = result.Values["hw.monitors"].Rows[0]; var columns = DetailedCatalog.Find("hw.monitors")!.Properties;
        Check.Equal(JsonValueKind.Array, row[columns.IndexOf("UserFriendlyName")].ValueKind, "tableau EDID exact");
        Check.Equal(JsonValueKind.Null, row[columns.IndexOf("InstanceName")].ValueKind, "identité trop longue non tronquée en faux identifiant");
        Check.False(result.Values["hw.monitors"].Complete, "borne explicitée");
    }

    [Test]
    public static void Probe_merge_keeps_last_success_separate_from_failure_and_details_keep_the_old_date()
    {
        var success = Store("disk.volumes", Fixtures.Now.AddDays(-1), ("DeviceID", "C:"), ("Size", 1000L), ("FreeSpace", 300L));
        var first = PosteProbeCache.Merge(null, success);
        var failure = new ProbeStore("PC1", null, [new("disk.volumes", ProbeState.Refused, null, Fixtures.Now, "Refus", 0)], [], [], [], Fixtures.Now);
        var merged = PosteProbeCache.Merge(first, failure);
        Check.Equal(success.CollectedAt, merged.Probes.Single().LastSuccess, "dernière réussite inchangée");
        Check.Equal(Fixtures.Now, merged.Probes.Single().LastAttempt!.Value, "tentative datée séparée");
        Check.Equal(1, merged.SystemVolumeHistory.Length, "un refus ne crée aucun échantillon");
        var detail = PosteProbeDetails.Build(merged, DetailedCatalog.Find("disk.volumes")!, 1, TimeZoneInfo.Utc, Fixtures.Now);
        Check.Equal(1, detail.Total, "dernières valeurs encore consultables après refus");
        Check.True(detail.Provenance.Contains("dernière tentative", StringComparison.Ordinal), "âge et refus visibles");
        var projected = WmiWorkstationReader.ProjectProbes(merged);
        Check.True(projected.Data!.Volumes.IsEmpty, "anciennes valeurs non interprétées comme mesure courante");
    }

    [Test]
    public static void Probe_histories_are_bounded_and_typed_projection_does_not_turn_zero_into_unknown()
    {
        ProbeStore? store = null;
        for (var n = 100; n >= 0; n--)
        { store = PosteProbeCache.Merge(store, Store("disk.volumes", Fixtures.Now.AddHours(-6 * n), ("DeviceID", "C:"), ("Size", 1000L), ("FreeSpace", (long)n))); }
        Check.Equal(60, store!.SystemVolumeHistory.Length, "soixante échantillons au plus");
        var projection = WmiWorkstationReader.ProjectProbes(store);
        Check.Equal(0L, projection.Data!.Volumes.Single().FreeBytes!.Value, "zéro réel conservé après JSON et projection");
        var duplicate = PosteProbeCache.Merge(store, Store("disk.volumes", Fixtures.Now.AddMinutes(1), ("DeviceID", "C:"), ("Size", 1000L), ("FreeSpace", 0L)));
        Check.Equal(store.SystemVolumeHistory.Last().At, duplicate.SystemVolumeHistory.Last().At, "pas de nouveau point avant six heures");
    }

    [Test]
    public static void Incomplete_monitor_read_does_not_become_the_reference_for_recording_a_change()
    {
        var initial = Store("hw.monitors", Fixtures.Now.AddDays(-2), ("InstanceName", "DISPLAY\\A"), ("Active", true));
        var saved = PosteProbeCache.Merge(null, initial);
        var partial = Store("hw.monitors", Fixtures.Now.AddDays(-1), ("InstanceName", "DISPLAY\\B"), ("Active", true));
        partial = partial with { Values = partial.Values.SetItem("hw.monitors", partial.Values["hw.monitors"] with { Complete = false }),
            Probes = [partial.Probes[0] with { State = ProbeState.Partial, LastSuccess = null }] };
        saved = PosteProbeCache.Merge(saved, partial);
        var same = Store("hw.monitors", Fixtures.Now, ("InstanceName", "DISPLAY\\A"), ("Active", true));
        saved = PosteProbeCache.Merge(saved, same);
        Check.Equal(1, saved.MonitorHistory.Length, "aucun faux changement entre deux ensembles complets identiques");
        Check.Equal(Fixtures.Now, saved.MonitorAt!.Value, "date de comparaison avancée après la lecture complète");
        Check.True(WmiWorkstationReader.CheckProbes(default).Length > 0, "sélection par défaut sans exception");
    }

    [Test]
    public static async Task Detailed_probe_payloads_roundtrip_in_SQLite_and_stale_writers_do_not_replace_newer_probes()
    {
        using var folder = new TemporaryFolder(); var pc = Fixtures.Computer("PC1");
        var db = new DomeniaDatabase(folder.File("detailed.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Postes, "Postes", true), null, CancellationToken.None);
        FleetCachePatch Patch(ProbeStore data) => FleetCachePatch.Empty with { WorkstationProbes = ImmutableDictionary<Guid, ProbeStore>.Empty.Add(pc.ObjectGuid, data) };
        await db.SaveFleetAsync(Patch(Store("disk.volumes", Fixtures.Now, ("DeviceID", "C:"), ("Size", 1000L), ("FreeSpace", 100L))), CancellationToken.None);
        await db.SaveFleetAsync(Patch(Store("hw.memoryusage", Fixtures.Now.AddHours(-1), ("TotalVisibleMemorySize", 1024L), ("FreePhysicalMemory", 200L))), CancellationToken.None);
        await db.SaveFleetAsync(Patch(Store("disk.volumes", Fixtures.Now.AddDays(-1), ("DeviceID", "C:"), ("Size", 1000L), ("FreeSpace", 999L))), CancellationToken.None);
        var stored = (await db.ReadFleetAsync(CancellationToken.None)).WorkstationProbes[pc.ObjectGuid];
        Check.Equal(2, stored.Values.Count, "sondes indépendantes fusionnées");
        Check.Equal(100L, WmiWorkstationReader.ProjectProbes(stored).Data!.Volumes.Single().FreeBytes!.Value, "lecture tardive ne remplace pas une valeur plus récente");
        var malformed = Store("hw.memoryusage", Fixtures.Now.AddDays(1), ("TotalVisibleMemorySize", new { Secret = "rejected" }));
        await Check.ThrowsAsync<InvalidDataException>(() => db.SaveFleetAsync(Patch(malformed), CancellationToken.None), "charge incohérente refusée avant commit");
        Check.Equal(2, (await db.ReadFleetAsync(CancellationToken.None)).WorkstationProbes[pc.ObjectGuid].Values.Count, "transaction précédente conservée");
    }

    [Test]
    public static async Task Detailed_probe_AD_entry_point_persists_before_return_and_reads_cache_without_network()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var contacts = 0;
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Reader(q => { contacts++; return q.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
            ? [Row(("Name", "PC1"))] : [Row(("DeviceID", "C:"), ("Size", 1000L), ("FreeSpace", 0L))]; }) };
        await reader.CollectProbesAsync(pc.DistinguishedName, ["disk.volumes"], null, CancellationToken.None);
        Check.Equal(1, cache.FleetWrites, "enregistrement avant affichage");
        var saved = await reader.ProbeStoreAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal(2, contacts, "ouverture du cache sans contact natif supplémentaire");
        Check.Equal(0L, saved.Data!.Volumes.Single().FreeBytes!.Value, "relecture du résultat enregistré");
    }
}
