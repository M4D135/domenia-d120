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
        var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache)
        { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        await source.ReadLocalAsync(CancellationToken.None); return (source, ldap);
    }
    private static WmiWorkstationReader Inventory(Func<string, string?> account) => new(TestClock.Fixed())
    {
        SessionFactory = (host, budget, token) => new(host, budget, TestClock.Fixed(), cancellationToken: token)
        {
            ReadOverride = (_, _, _) => [new WmiInstance(new Dictionary<string, object?> { ["Name"] = host.Split('.')[0], ["DNSHostName"] = host.Split('.')[0], ["Domain"] = "test.local", ["UserName"] = account(host) })],
            RegistryOverride = (_, _) => throw new InvalidOperationException("Pas de repli registre."),
        },
    };
    private static EngineContext NativeContext(AdDirectorySource source)
    {
        var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "test", null, "test.local", []), source,
            new MemoryPreferenceStore(), source.Clock, new RecordingJournal());
        // The recording LDAP transport cannot provide a Windows credential. Select an owned fictitious
        // machine account through the real cascade instead of bypassing the native admission guards.
        using var password = PasswordSecrets.FromText("relation-probe-fixture");
        MachineAccountService.From(context).UseRemote(@"TEST\probe", password.Copy());
        return context;
    }
    private static Task<RelationDetectionPlan> Plan(AdRelationsReader reader, params string[] pcs) => reader.SweepPlanAsync(new(50, null, pcs), CancellationToken.None);

    [Test]
    public static async Task Native_probe_keeps_dns_failure_distinct_from_silent_echo_in_the_saved_pass()
    {
        using var folder = new TemporaryFolder(); var (source, _) = await Open(folder); using var owned = source;
        using var context = NativeContext(source);
        var reader = new AdRelationsReader(source)
        {
            PresenceReaderOverride = new(source.Clock)
            { ResolveOverride = (_, _) => Task.FromException<System.Net.IPAddress[]>(new System.Net.Sockets.SocketException((int)System.Net.Sockets.SocketError.HostNotFound)) },
            InventoryReaderOverride = _ => throw new InvalidOperationException("No console after DNS failure."),
        };
        var plan = await Plan(reader, "PC1");
        var result = await reader.ProbeAsync(plan.Id!, null, CancellationToken.None, CancellationToken.None);
        Check.False(result.Complete, "échec de transport ne réussit pas la détection");
        Check.Contains("présence non confirmée", result.Message, "bilan explicite");
        Check.False(result.Message.Contains("poste sans réponse ICMP", StringComparison.Ordinal), "aucun ping muet supposé");
        var attempt = result.Attempts.Single();
        Check.Equal("ERREUR", attempt.Status, "erreur DNS distincte d’un délai ICMP");
        Check.Contains("non résolu", attempt.Detail, "cause affichée");
        var passes = await ((IRelationSweepCache)source.LocalStore!).ReadRelationSweepsAsync(CancellationToken.None);
        Check.Equal("ERREUR", passes.Rows.Single().Status, "passage sauvegardé sans PING_MUET inventé");
    }

    [Test]
    public static async Task A_probe_one_shot_is_owned_by_the_first_planned_target_even_if_its_ping_is_silent()
    {
        foreach (var firstAnswers in new[] { true, false })
        {
            using var folder = new TemporaryFolder(); var (cached, _) = await Open(folder); using var heldCache = cached;
            var pcs = new[] { Fixtures.Computer("PC1"), Fixtures.Computer("PC2") };
            var ldap = new AdBoundaryTests.RecordingAdConnection
            { SearchAnswer = q => pcs.FirstOrDefault(pc => DistinguishedName.AreEqual(pc.DistinguishedName, q.BaseDn)) is { } pc ? [AdPosteNetworkTests.Entry(pc)] : [] };
            using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(),
                connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cached.LocalStore)
            { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
            source.AdoptConnection(ldap, Fixtures.Domain, new(new(@"TEST\operator", "operator", "Opérateur", "CN=operator," + Fixtures.People),
                Fixtures.Domain.DomainSid + "-1001", new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), source.Epoch, false);
            using var context = new EngineContext(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Unknown, null)), source,
                new MemoryPreferenceStore(), source.Clock, new RecordingJournal());
            using var password = PasswordSecrets.FromText("probe-one-shot-fixture");
            var machine = MachineAccountService.From(context); machine.UseRemote(@"TEST\fallback", password.Copy());
            var session = await source.GetSessionAsync(CancellationToken.None);
            machine.AcceptTemporary(session, null, @"TEST\once", password.Copy(), MachineLeaseMode.OneShot);
            var contacted = new List<string>();
            var reader = new AdRelationsReader(source)
            {
                PingOverride = (host, _) => Task.FromResult(!host.StartsWith("pc1", StringComparison.OrdinalIgnoreCase) || firstAnswers),
                InventoryReaderOverride = _ => Inventory(host => { contacted.Add(host); machine.Resolve(session, host); return null; }),
            };
            var plan = await Plan(reader, "PC1", "PC2");
            var read = await reader.ProbeAsync(plan.Id!, null, CancellationToken.None, CancellationToken.None);
            Check.Equal(firstAnswers ? "pc1.test.local" : "", string.Join(',', contacted), "aucune console suivante avec le compte de repli");
            Check.True(read.Counters!.Stopped, "le relevé exige un nouveau geste après l’usage unique");
            Check.Equal(firstAnswers ? 0 : 1, read.Counters.Unreachable, "silence ICMP de la première cible conservé");
            Check.Contains("Bail à usage unique engagé pour la première cible", read.Message, "borne réelle expliquée même si la première cible n’a pas répondu");
            Check.Contains("aucun compte de repli", read.Message, "motif distinct d’un changement de session");
        }
    }

    [Test]
    public static async Task Native_probe_reads_only_the_confirmed_list_once_and_reports_ping_empty_and_qualified_console_separately()
    {
        using var folder = new TemporaryFolder(); var (source, ldap) = await Open(folder); using var owned = source;
        using var context = NativeContext(source);
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
        var passes = await ((IRelationSweepCache)source.LocalStore!).ReadRelationSweepsAsync(CancellationToken.None);
        Check.Equal(3, passes.Rows.Length, "chaque passage confirmé mémorisé");
        Check.Equal("PING_MUET", passes.Rows.Single(r => r.Computer == "PC3").Status, "silence ICMP ne devient pas une session vide");
        Check.True(passes.Rows.All(r => r.Attempts == 1 && r.ComputerGuid is not null), "identités et tentatives sans doublon de rejeu");
    }

    [Test]
    public static async Task Clearing_pass_memory_during_a_probe_does_not_resurrect_old_generation_rows_or_discard_qualified_relations()
    {
        using var folder = new TemporaryFolder(); var (source, _) = await Open(folder); using var owned = source;
        using var context = NativeContext(source);
        var cache = (SqliteDirectoryCache)source.LocalStore!; var snapshot = await cache.ReadRelationSweepsAsync(CancellationToken.None);
        var pc = Fixtures.Computer("PC3");
        await cache.ApplyRelationSweepsAsync(new(snapshot.StoreId, WritePlans.NewId(), snapshot.Generation,
            [new(pc.ObjectGuid, pc.DistinguishedName, "PC3", Fixtures.Now.AddDays(-1), "ERREUR", null)]), CancellationToken.None);
        var reader = new AdRelationsReader(source)
        {
            PingOverride = (_, _) =>
            {
                using var sql = new SqliteDatabase(cache.Database.Path, false);
                sql.Execute("DELETE FROM park_state;"); sql.Execute("UPDATE domenia_v2_sweep_state SET generation=generation+1 WHERE id=1;");
                return Task.FromResult(true);
            },
            InventoryReaderOverride = _ => Inventory(_ => @"TEST\alice"),
        };
        var plan = await Plan(reader, "PC1"); var read = await reader.ProbeAsync(plan.Id!, null, CancellationToken.None, CancellationToken.None);
        Check.True(read.Partial, "mémoire non confirmée annoncée"); Check.Equal(1, read.Savable, "relation qualifiée indépendante de la mémoire du parc");
        Check.Equal(0L, (await cache.ReadRelationSweepsAsync(CancellationToken.None)).Total, "ancien passage non réintroduit après effacement");
        Check.Contains("mémoire effacée", read.Message, "raison visible");
    }

    [Test]
    public static async Task Operator_stop_keeps_finished_native_observations_and_does_not_read_the_next_console()
    {
        using var folder = new TemporaryFolder(); var (source, _) = await Open(folder); using var owned = source;
        using var context = NativeContext(source);
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
        using var context = NativeContext(source);
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
        using var context = NativeContext(source);
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
        using var context = NativeContext(source);
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
        using var context = NativeContext(source);
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
        using var context = NativeContext(source);
        var began = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var calls = 0;
        var reader = new AdRelationsReader(source) { PingOverride = async (_, token) => { began.TrySetResult(); await release.Task.WaitAsync(token); return true; },
            InventoryReaderOverride = _ => Inventory(_ => { calls++; return @"TEST\alice"; }) };
        var first = await Plan(reader, "PC1"); var second = await Plan(reader, "PC2");
        var running = reader.ProbeAsync(first.Id!, null, CancellationToken.None, CancellationToken.None);
        try
        {
            // Surface an admission failure directly instead of disguising it as a timeout of the ping barrier.
            if (await Task.WhenAny(began.Task, running).WaitAsync(TimeSpan.FromSeconds(5)) == running) await running;
            await began.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ProbeAsync(second.Id!, null, CancellationToken.None, CancellationToken.None), "une seule sonde active");
        }
        finally { release.TrySetResult(); }
        await running;
        Check.Equal(1, (await reader.ProbeAsync(second.Id!, null, CancellationToken.None, CancellationToken.None)).Savable, "plan non consommé par le refus occupé");
        var expired = await Plan(reader, "PC3"); ((FixedTimeProvider)source.Clock).Advance(TimeSpan.FromMinutes(16));
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ProbeAsync(expired.Id!, null, CancellationToken.None, CancellationToken.None), "expiration");
        Check.Equal(2, calls, "aucun contact au plan expiré");
    }
}
