using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Store;

namespace Domenia.Tests;

internal static class QueryCacheScaleTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static ProbeReading Probe(string id, string property, string value) => new(id, Fixtures.Now, null, false, false, 1, true,
        [new("0", ImmutableDictionary<string, object?>.Empty.Add(property, value), [])]);
    private static QueryComputerReadings Reading(DirectoryComputer pc, params ProbeReading[] probes) =>
        new(pc.ObjectGuid, pc.DistinguishedName, pc.WhenCreated, [.. probes], []);

    [Test]
    public static async Task Hundred_thousand_query_rows_are_read_without_truncation_and_one_save_does_not_scan_other_workstations()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("large-query.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(db); await db.InitializeAsync(None);
        var pc = Fixtures.Computer("REAL");
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Postes, "Postes", true), "DC1", None);
        await cache.SaveQueryResultAsync(Reading(pc, Probe("hw.model", "Model", "Premier")), None);
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Begin();
            for (var i = 1; i < 100_000; i++)
            {
                var id = new Guid(i, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2);
                var value = new QueryComputerReadings(id, $"CN=PC{i:D6}," + Fixtures.Postes, Fixtures.Now.AddYears(-2), [], []);
                var payload = JsonSerializer.Serialize(value, Json);
                sql.Execute("INSERT INTO domenia_v2_query_results(computer_guid,payload,sha256) VALUES(?1,?2,?3);", id.ToString("D"), payload,
                    Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(payload))));
            }
            sql.Commit();
        }
        var all = await new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed()).ReadQueryResultsAsync(None);
        Check.Equal(100_000, all.Computers.Length, "instantané complet après réouverture, aucun plafond silencieux à 50 000");
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Execute("UPDATE domenia_v2_query_results SET payload='unrelated damaged row' WHERE computer_guid=?1;", new Guid(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2).ToString("D")); }
        var changed = await ((IQueryResultsDeltaStore)cache).SaveQueryResultAsync(Reading(pc, Probe("hw.model", "Model", "Actualisé")), None);
        Check.Equal("Actualisé", changed.Probes.Single().Instances.Single().Values["Model"] as string, "accusé de réception limité au poste réellement écrit");
        await Check.ThrowsAsync<InvalidDataException>(() => db.ReadQueryResultsAsync(None), "un instantané global continue de refuser l’autre ligne altérée, sans annoncer un parc partiel");
        using var verified = new SqliteDatabase(db.Path, true);
        Check.Equal(100_000L, (long)verified.Scalar("SELECT count(*) FROM domenia_v2_query_results;")!, "aucun voisin supprimé pour faire réussir le commit individuel");
    }

    [Test]
    public static async Task New_identity_proofs_apply_only_to_new_probe_readings_and_do_not_promote_legacy_cache()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdQueryNativeTests.QueryCache(Fixtures.Snapshot(computers: [pc]));
        await cache.SaveQueryResultsAsync(Reading(pc, Probe("hw.model", "Model", "Ancien modèle")), None);
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        await AdQueryMemory.For(source).SaveAsync(pc, [Probe("hw.maker", "Manufacturer", "Fabricant")], [], source.Epoch, None);
        var merged = cache.Stored.Computers.Single();
        Check.True(merged.Identity!.Matches(pc), "enveloppe liée à l’identité effectivement lue");
        Check.Null(merged.Probes.Single(p => p.ProbeId == "hw.model").Identity, "ancienne donnée sans preuve garde son TTL historique");
        Check.True(merged.Probes.Single(p => p.ProbeId == "hw.maker").Identity!.Matches(pc), "seule la nouvelle donnée porte une preuve réutilisable");
        var other = pc with { DnsHostName = "replacement.test.local" };
        var changed = Reading(other, Probe("hw.maker", "Manufacturer", "Autre")) with { Identity = QueryComputerIdentity.Of(other) };
        Check.Equal(1, QueryReadingRules.Merge(merged, changed).Probes.Length, "même GUID/DN/création mais hôte différent : aucun ancien modèle transféré");
        var dataset = await new AdQueryWorkshopReader(source).DatasetAsync(None);
        Check.True(dataset.Probes.ContainsKey(pc.ObjectGuid), "lectures qualifiées exposées pour leur poste");
        cache.Directory = Fixtures.Snapshot(computers: [other]);
        source.Reset();
        var rebound = await new AdQueryWorkshopReader(source).DatasetAsync(None);
        Check.False(rebound.Probes.ContainsKey(other.ObjectGuid), "preuve de l’ancien hôte non attribuée à l’hôte de remplacement");
    }

    [Test]
    public static async Task Local_AD_endpoint_change_invalidates_query_cache_even_when_no_fleet_blob_exists()
    {
        using var folder = new TemporaryFolder(); var db = new DomeniaDatabase(folder.File("query-identity.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(db); await db.InitializeAsync(None);
        var pc = Fixtures.Computer("PC1"); var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), scope, "DC1", None);
        var identity = QueryComputerIdentity.Of(pc);
        var reading = Reading(pc, Probe("hw.model", "Model", "Ancien") with { Identity = identity }) with { Identity = identity };
        await cache.SaveQueryResultAsync(reading, None);
        var other = pc with { Sid = Fixtures.Domain.DomainSid + "-90001" };
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [other], readAt: Fixtures.Now), scope, "DC1", None);
        Check.Equal(0, (await cache.ReadQueryResultsAsync(None)).Computers.Length, "nouveau SID invalide le cache indépendant du JSON fleet");
        await Check.ThrowsAsync<InvalidDataException>(() => cache.SaveQueryResultAsync(reading, None), "résultat tardif lié à l’ancien SID refusé");
    }
}
