using System.Runtime.InteropServices;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdRelationProbeTests
{
    private sealed class Progress(Action<RelationProbeProgress> callback) : IProgress<RelationProbeProgress>
    { public void Report(RelationProbeProgress value) => callback(value); }
    private static async Task<(AdDirectorySource Source, AdBoundaryTests.RecordingAdConnection Ldap)> Open(TemporaryFolder folder)
    {
        var db = new DomeniaDatabase(folder.File("probe.db"), Fixtures.Root, TestClock.Fixed()); var cache = new SqliteDirectoryCache(db);
        var pcs = Enumerable.Range(1, 3).Select(i => Fixtures.Computer("PC" + i)).ToArray(); var user = Fixtures.User("alice");
        await cache.SaveObjectsAsync(Fixtures.Snapshot(users: [user], computers: pcs), null, CancellationToken.None);
        var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => pcs.FirstOrDefault(pc => DistinguishedName.AreEqual(pc.DistinguishedName, q.BaseDn)) is { } pc
            ? [AdPosteNetworkTests.Entry(pc)] : [AdRelationDirectoryTests.User(user)] };
        var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.ReadLocalAsync(CancellationToken.None); return (source, ldap);
    }
    private static WmiWorkstationReader Inventory(Func<string, string?> account) => new(TestClock.Fixed())
    {
        SessionFactory = (host, budget, token) => new(host, budget, TestClock.Fixed(), cancellationToken: token)
        {
            ReadOverride = (_, _, _) => [new WmiInstance(new Dictionary<string, object?> { ["Name"] = host.Split('.')[0], ["UserName"] = account(host) })],
            RegistryOverride = (_, _) => throw new InvalidOperationException("Pas de repli registre."),
        },
    };
    private static Task<RelationDetectionPlan> Plan(AdRelationsReader reader, params string[] pcs) => reader.SweepPlanAsync(new(50, null, pcs), CancellationToken.None);

    [Test]
    public static async Task Native_probe_reads_only_the_confirmed_list_once_and_reports_ping_empty_and_qualified_console_separately()
    {
        using var folder = new TemporaryFolder(); var (source, ldap) = await Open(folder); using var owned = source;
        var contacted = new List<string>(); var pinged = new List<string>(); var progress = new List<RelationProbeProgress>();
        var reader = new AdRelationsReader(source)
        {
            PingOverride = (host, _) => { pinged.Add(host); return Task.FromResult(!host.StartsWith("pc3", StringComparison.OrdinalIgnoreCase)); },
            InventoryReaderOverride = _ => Inventory(host => { contacted.Add(host); return host.StartsWith("pc1", StringComparison.OrdinalIgnoreCase) ? @"TEST\alice" : null; }),
        };
        var plan = await Plan(reader, "PC1", "PC2", "PC3");
        var read = await reader.ProbeAsync(plan.Id!, new Progress(progress.Add), CancellationToken.None, CancellationToken.None);
        Check.True(read.Within, "périmètre respecté"); Check.False(read.Complete, "ping non concluant empêche un résultat complet");
        Check.Equal(1, read.Counters!.Confirmed, "une console AD"); Check.Equal(1, read.Counters.NoSession, "champ réellement vide"); Check.Equal(1, read.Counters.Unreachable, "silence ICMP distinct");
        Check.Equal("pc1.test.local,pc2.test.local", string.Join(',', contacted), "aucune console pour le ping muet");
        Check.Equal(3, pinged.Count, "ping seulement des trois cibles"); Check.Equal(3, progress.Count, "progression après chaque cible");
        Check.Equal(1, read.Savable, "preuve native qualifiée"); Check.Equal(1, (await reader.PendingAsync(CancellationToken.None)).Sets.Single(s => s.ResultId == read.ResultId).Remaining, "résultat en attente visible");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ProbeAsync(plan.Id!, null, CancellationToken.None, CancellationToken.None), "périmètre consommé non rejoué");
        Check.Equal(2, contacted.Count, "aucun nouvel essai après rejeu"); Check.Equal(5, ldap.Searches.Count, "validations nécessaires uniquement");
    }

    [Test]
    public static async Task Operator_stop_keeps_finished_native_observations_and_does_not_read_the_next_console()
    {
        using var folder = new TemporaryFolder(); var (source, _) = await Open(folder); using var owned = source;
        using var stop = new CancellationTokenSource(); var calls = 0;
        var reader = new AdRelationsReader(source) { PingOverride = (_, _) => Task.FromResult(true), InventoryReaderOverride = _ => Inventory(_ => { calls++; return @"TEST\alice"; }) };
        var plan = await Plan(reader, "PC1", "PC2", "PC3");
        var read = await reader.ProbeAsync(plan.Id!, new Progress(_ => stop.Cancel()), stop.Token, CancellationToken.None);
        Check.Equal(1, calls, "arrêt avant deuxième console"); Check.True(read.Partial, "résultat partiel explicite"); Check.True(read.Counters!.Stopped, "compteurs arrêtés");
        Check.Equal(1, read.Savable, "première observation conservée");
        using var executor = new AdRelationChangeExecutor(source);
        Check.Equal(1, (await executor.SaveObservationsAsync(CancellationToken.None)).Saved, "première preuve mémorisable après arrêt");
        var next = await Plan(reader, "PC2");
        Check.Equal(1, (await reader.ProbeAsync(next.Id!, null, CancellationToken.None, CancellationToken.None)).Savable, "verrou de sonde libéré après arrêt");
    }

    [Test]
    public static async Task Native_probe_stops_after_the_first_authentication_rejection_without_other_console_attempts()
    {
        using var folder = new TemporaryFolder(); var (source, ldap) = await Open(folder); using var owned = source; var calls = 0;
        var reader = new AdRelationsReader(source) { PingOverride = (_, _) => Task.FromResult(true),
            InventoryReaderOverride = _ => Inventory(_ => { calls++; throw new COMException("Identité refusée", unchecked((int)0x8007052E)); }) };
        var plan = await Plan(reader, "PC1", "PC2", "PC3");
        var read = await reader.ProbeAsync(plan.Id!, null, CancellationToken.None, CancellationToken.None);
        Check.True(read.Counters!.Stopped, "rejet arrêtant la file"); Check.Equal(1, read.Counters.Refused, "rejet compté");
        Check.Equal(1, calls, "aucun autre compte ou poste essayé"); Check.Equal(1, ldap.Searches.Count, "aucune recherche utilisateur après rejet");
        Check.True(read.Attempts.Any(a => a.Status == "AUTH_REJETEE"), "rejet visible"); Check.Equal(0, read.Savable, "aucune relation");
    }

    [Test]
    public static async Task Probe_refuses_a_changed_DNS_before_CIM_and_does_not_substitute_another_host()
    {
        using var folder = new TemporaryFolder(); var (source, ldap) = await Open(folder); using var owned = source; var contacted = new List<string>();
        var normal = ldap.SearchAnswer;
        ldap.SearchAnswer = q => DistinguishedName.AreEqual(q.BaseDn, Fixtures.Computer("PC1").DistinguishedName)
            ? [AdPosteNetworkTests.Entry(Fixtures.Computer("PC1") with { DnsHostName = "pc1.changed.test.local" })] : normal!(q);
        var reader = new AdRelationsReader(source) { PingOverride = (_, _) => Task.FromResult(true), InventoryReaderOverride = _ => Inventory(host => { contacted.Add(host); return @"TEST\alice"; }) };
        var plan = await Plan(reader, "PC1", "PC2");
        var read = await reader.ProbeAsync(plan.Id!, null, CancellationToken.None, CancellationToken.None);
        Check.Equal("pc2.test.local", contacted.Single(), "nouveau DNS non contacté"); Check.True(read.Partial, "identité devenue non concluante");
        Check.Equal(1, read.Savable, "autre cible confirmée conservée"); Check.Equal(1, read.Counters!.Unreachable, "cible modifiée comptée");
    }

    [Test]
    public static async Task Native_probe_preserves_observations_when_other_previews_fill_the_result_pool_during_the_read()
    {
        using var folder = new TemporaryFolder(); var (source, _) = await Open(folder); using var owned = source;
        var pool = AdRelationResults.For(source);
        var reader = new AdRelationsReader(source) { PingOverride = (_, _) =>
        {
            for (var i = 0; i < 16; i++) { pool.Remember(_ => new object(), source.Epoch); }
            return Task.FromResult(true);
        }, InventoryReaderOverride = _ => Inventory(_ => @"TEST\alice") };
        var plan = await Plan(reader, "PC1");
        var read = await reader.ProbeAsync(plan.Id!, null, CancellationToken.None, CancellationToken.None);
        Check.Equal(RelationChange.SessionResultId, read.ResultId, "résultat regroupé sans cacher la lecture");
        Check.Equal(1, read.Savable, "preuve conservée"); Check.Contains("regroupées", read.Message, "regroupement annoncé");
        using var writer = new AdRelationChangeExecutor(source);
        Check.Equal(1, (await writer.SaveObservationsAsync(CancellationToken.None)).Saved, "mémorisation toujours possible");
    }

    [Test]
    public static async Task Probe_already_stopped_contacts_no_directory_or_workstation_and_consumes_its_plan()
    {
        using var folder = new TemporaryFolder(); var (source, ldap) = await Open(folder); using var owned = source;
        var reader = new AdRelationsReader(source)
        {
            PingOverride = (_, _) => throw new InvalidOperationException("Aucun ping après arrêt."),
            InventoryReaderOverride = _ => throw new InvalidOperationException("Aucune console après arrêt."),
        };
        var plan = await Plan(reader, "PC1"); using var stop = new CancellationTokenSource(); stop.Cancel();
        var read = await reader.ProbeAsync(plan.Id!, null, stop.Token, CancellationToken.None);
        Check.True(read.Counters!.Stopped, "arrêt explicite"); Check.True(read.Partial, "périmètre non sondé");
        Check.Equal(0, ldap.Calls, "aucun annuaire contacté"); Check.Equal(0, read.Savable, "aucune observation fabriquée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ProbeAsync(plan.Id!, null, CancellationToken.None, CancellationToken.None), "nouveau geste après arrêt requis");
    }

    [Test]
    public static async Task Probe_busy_does_not_consume_the_other_plan_and_expired_ids_contact_nothing()
    {
        using var folder = new TemporaryFolder(); var (source, _) = await Open(folder); using var owned = source;
        var began = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var calls = 0;
        var reader = new AdRelationsReader(source) { PingOverride = async (_, token) => { began.TrySetResult(); await release.Task.WaitAsync(token); return true; },
            InventoryReaderOverride = _ => Inventory(_ => { calls++; return @"TEST\alice"; }) };
        var first = await Plan(reader, "PC1"); var second = await Plan(reader, "PC2");
        var running = reader.ProbeAsync(first.Id!, null, CancellationToken.None, CancellationToken.None);
        await began.Task.WaitAsync(TimeSpan.FromSeconds(5));
        try { await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ProbeAsync(second.Id!, null, CancellationToken.None, CancellationToken.None), "une seule sonde active"); }
        finally { release.TrySetResult(); }
        await running;
        Check.Equal(1, (await reader.ProbeAsync(second.Id!, null, CancellationToken.None, CancellationToken.None)).Savable, "plan non consommé par le refus occupé");
        var expired = await Plan(reader, "PC3"); ((FixedTimeProvider)source.Clock).Advance(TimeSpan.FromMinutes(16));
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ProbeAsync(expired.Id!, null, CancellationToken.None, CancellationToken.None), "expiration");
        Check.Equal(2, calls, "aucun contact au plan expiré");
    }
}
