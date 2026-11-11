using System.Buffers.Binary;
using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Security;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class NativeReadWorkerTests
{
    private static NativeReadHello Hello => new("PC-TEST", InventoryTransport.Dcom, 60_000, true, null, false, false);
    private static NativeReadRequest Query => new(NativeReadKind.Query, 20_000)
    { Category = "Fixture", Namespace = @"root\cimv2", Query = "SELECT Name FROM Win32_ComputerSystem", MaxItems = 1 };

    [Test]
    public static async Task Native_protocol_round_trips_WMI_types_without_losing_unsigned_values_or_arrays()
    {
        using var stream = new MemoryStream();
        var row = new WmiInstance(new Dictionary<string, object?>
        { ["Name"] = "PC-TEST", ["Enabled"] = true, ["Count"] = uint.MaxValue, ["Large"] = ulong.MaxValue,
            ["Ports"] = new ushort[] { 1, 80 }, ["Names"] = new[] { "a", "b" }, ["Missing"] = null });
        await NativeReadProtocol.WriteAsync(stream, new NativeReadReply(Reading: new("Fixture", SourceStatus.Partial, "Partiel", 1, [row])), NativeReadProtocol.ResponseLimit, default);
        stream.Position = 0;
        var result = (await NativeReadProtocol.ReadAsync<NativeReadReply>(stream, NativeReadProtocol.ResponseLimit, default)).Reading!;
        Check.Equal(SourceStatus.Partial, result.Status, "statut exact");
        var actual = result.Instances.Single();
        Check.Equal("PC-TEST", actual.Text("Name"), "texte"); Check.Equal(true, actual.Bool("Enabled"), "booléen");
        Check.Equal((long)uint.MaxValue, actual.Number("Count"), "uint"); Check.Equal(ulong.MaxValue, (ulong)actual.Raw("Large")!, "ulong");
        Check.Equal("1,80", string.Join(',', actual.Ints("Ports")), "tableau numérique");
        Check.Equal("a,b", string.Join(',', actual.Strings("Names")), "tableau texte"); Check.Null(actual.Raw("Missing"), "inconnu conservé");
    }

    [Test]
    public static async Task Native_protocol_registry_arrays_keep_the_registry_read_contract()
    {
        using var stream = new MemoryStream();
        await NativeReadProtocol.WriteAsync(stream, new NativeReadReply(Registry: new(SourceStatus.Ok, true, new[] { "one", "two" }, "Lu", 0)), 4096, default);
        stream.Position = 0;
        var read = (await NativeReadProtocol.ReadAsync<NativeReadReply>(stream, 4096, default)).Registry!;
        Check.True(read.Found, "présence"); Check.Equal("one,two", string.Join(',', read.Strings), "string[] attendu par collecteur");
    }

    [Test]
    public static async Task Native_protocol_rejects_oversize_and_version_before_reading_payload()
    {
        foreach (var (version, length) in new[] { (1, NativeReadProtocol.ResponseLimit + 1), (2, 1), (1, -1) })
        {
            var header = new byte[8]; BinaryPrimitives.WriteInt32LittleEndian(header, version); BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(4), length);
            using var stream = new MemoryStream(header);
            await Check.ThrowsAsync<InvalidDataException>(() => NativeReadProtocol.ReadFrameAsync(stream, NativeReadProtocol.ResponseLimit, default), "entête seul refusé");
            Check.Equal(8L, stream.Position, "aucune charge utile attendue");
        }
    }

    [Test]
    public static async Task Native_protocol_refuses_nested_objects_and_unbounded_instance_values()
    {
        using var stream = new MemoryStream();
        var huge = new WmiInstance(new Dictionary<string, object?> { ["Name"] = new string('x', 32769) });
        await Check.ThrowsAsync<JsonException>(() => NativeReadProtocol.WriteAsync(stream, huge, NativeReadProtocol.ResponseLimit, default), "texte borné avant émission");
        Check.Equal(0L, stream.Length, "aucun fragment émis avant sérialisation complète");
        using var malformed = new MemoryStream();
        await NativeReadProtocol.WriteFrameAsync(malformed, System.Text.Encoding.UTF8.GetBytes("{\"Name\":{\"nested\":1}}"), 100, default);
        malformed.Position = 0;
        await Check.ThrowsAsync<JsonException>(() => NativeReadProtocol.ReadAsync<WmiInstance>(malformed, 100, default), "objet natif arbitraire refusé");
    }

    [Test]
    public static async Task Native_secret_uses_its_separate_bounded_frame_and_retains_exact_characters()
    {
        using var secret = new SecureString(); foreach (var ch in "Aç\uD83D\uDD12z") { secret.AppendChar(ch); } secret.MakeReadOnly();
        using var stream = new MemoryStream(); await NativeReadProtocol.WritePasswordAsync(stream, secret, default); stream.Position = 0;
        using var actual = await NativeReadProtocol.ReadPasswordAsync(stream, default);
        Check.Equal(secret.Length, actual!.Length, "unités UTF16 exactes");
        using var repeated = new MemoryStream(); await NativeReadProtocol.WritePasswordAsync(repeated, actual, default);
        Check.True(stream.ToArray().SequenceEqual(repeated.ToArray()), "octets exacts, pas de conversion en string");
        using var odd = new MemoryStream(); await NativeReadProtocol.WriteFrameAsync(odd, new byte[] { 1 }, 8192, default); odd.Position = 0;
        await Check.ThrowsAsync<InvalidDataException>(() => NativeReadProtocol.ReadPasswordAsync(odd, default), "UTF16 incomplet refusé");
    }

    [Test]
    public static void Native_closed_requests_refuse_writes_MSI_and_arbitrary_registry_paths()
    {
        Query.Check(); // Positive setup: ordinary SELECT is admitted.
        foreach (var query in new[] { "SELECT Name FROM Win32_Product", "DELETE FROM Win32_ComputerSystem", "SELECT Password FROM Win32_UserAccount" })
        { Check.Throws<InvalidDataException>(() => (Query with { Query = query }).Check(), "lecture dangereuse refusée"); }
        Check.Throws<InvalidDataException>(() => (Query with { Kind = (NativeReadKind)999 }).Check(), "action inconnue");
        Check.Throws<InvalidDataException>(() => new NativeReadRequest(NativeReadKind.Registry, 1000)
        { Registry = new(InventoryRegistry.Machine, @"SAM\Domains", "secret", RegistryMethod.String) }.Check(), "registre fermé");
        Check.Throws<InvalidDataException>(() => (Query with { BudgetMs = 300_001 }).Check(), "délai borné");
    }

    [Test]
    public static async Task Native_real_child_disabled_read_is_local_and_process_is_gone_before_quota_returns()
    {
        var before = NativeReadProcess.Running; var journal = new NativeFailureJournal();
        var client = new NativeReadClient(Hello, null, default, adaptive: new AdaptiveReadBudget(TimeProvider.System), journal: journal);
        try
        {
            var reply = await client.ReadAsync(Query);
            Check.Equal(SourceStatus.Skipped, reply.Reading!.Status, "garde désactivée exécutée dans vrai enfant sans WMI");
            Check.Equal(before + 1, NativeReadProcess.Running, "place conservée entre appels");
            using var child = Process.GetProcessById(client.ProcessId!.Value);
            var second = await client.ReadAsync(Query);
            Check.Equal(SourceStatus.Skipped, second.Reading!.Status, "seconde lecture");
            Check.Equal(child.Id, client.ProcessId!.Value, "même enfant, même compte");
            client.Dispose();
            Check.True(child.HasExited, "sortie OS confirmée avant retour Dispose");
            Check.Equal(before, NativeReadProcess.Running, "place rendue après sortie");
            Check.Equal(0, journal.Warnings.Count, "aucune trace d’échec pour deux réponses normales");
        }
        finally { client.Dispose(); }
    }

    [Test]
    public static async Task Native_cancellation_kills_a_child_blocked_after_request_and_never_replays_it()
    {
        var before = NativeReadProcess.Running; var journal = new NativeFailureJournal();
        var adaptive = new AdaptiveReadBudget(TimeProvider.System);
        using var stop = new CancellationTokenSource();
        var id = Guid.NewGuid().ToString("N");
        using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, @"Local\Domenia.NativeFixture." + id);
        using var client = new NativeReadClient(Hello, null, stop.Token, adaptive: adaptive, journal: journal);
        var reading = client.ReadAsync(Query, NativeReadWorkerFixture.Prefix + id);
        Check.True(await Task.Run(() => ready.WaitOne(TimeSpan.FromSeconds(10))), "l’enfant a lu la requête avant annulation");
        using var child = Process.GetProcessById(client.ProcessId!.Value);
        Check.False(child.HasExited, "enfant effectivement bloqué"); Check.Equal(before + 1, NativeReadProcess.Running, "place occupée");
        stop.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => reading, "annulation effective");
        Check.True(child.HasExited, "fin physique avant exception"); Check.Equal(before, NativeReadProcess.Running, "quota rendu");
        Check.Equal(0, adaptive.Snapshot(Hello.Host).Active, "place adaptative rendue après fin physique");
        Check.Equal(0, adaptive.Snapshot(Hello.Host).Failures, "annulation sans pénalité du site");
        await Check.ThrowsAsync<ObjectDisposedException>(() => client.ReadAsync(Query), "aucun redémarrage implicite");
        var warning = journal.Warnings.Single();
        Check.Equal(before, journal.RunningAtWarning.Single(), "trace publiée après sortie physique");
        Check.True(warning.Contains("callerCancellation=True; requestDeadline=False", StringComparison.Ordinal), "annulation appelante distincte du délai");
        Check.Contains("parentTerminationRequested=True", warning, "terminaison parent observée, distincte d’une sortie spontanée");
        Check.Contains("childType=absent", warning, "aucune exception enfant inventée pour un enfant bloqué terminé");
        Check.True(warning.Contains("budgetMs=20000;", StringComparison.Ordinal), "budget de la requête, pas celui de la session");
        CheckWriteBoundary(warning);
        Check.False(warning.Contains(Hello.Host, StringComparison.Ordinal) || warning.Contains(Query.Query!, StringComparison.Ordinal), "ni cible ni requête dans le journal");
    }

    [Test]
    public static async Task Native_explicit_credential_copy_survives_caller_disposal_until_child_ends()
    {
        var id = Guid.NewGuid().ToString("N");
        using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, @"Local\Domenia.NativeFixture." + id);
        using var stop = new CancellationTokenSource();
        var password = new SecureString(); foreach (var c in Guid.NewGuid().ToString("N")) { password.AppendChar(c); } password.MakeReadOnly();
        using var comparison = password.Copy();
        var credential = new RemoteProbeCredential("TEST\\reader", password, false);
        using var client = new NativeReadClient(Hello with { Session = false, Account = credential.Account }, credential, stop.Token, adaptive: new AdaptiveReadBudget(TimeProvider.System));
        credential.Dispose();
        Check.True(SecureCredentialCopies.Contains(comparison), "copie cliente suivie après destruction de l’original");
        var reading = client.ReadAsync(Query, NativeReadWorkerFixture.Prefix + id);
        Check.True(await Task.Run(() => ready.WaitOne(TimeSpan.FromSeconds(10))), "secret arrivé à l’enfant après destruction de la copie appelante");
        using var child = Process.GetProcessById(client.ProcessId!.Value);
        stop.Cancel(); await Check.ThrowsAsync<OperationCanceledException>(() => reading, "arrêt");
        Check.True(child.HasExited, "credentials détenus jusqu’à fin physique");
        Check.False(SecureCredentialCopies.Contains(comparison), "copie suivie libérée après fin physique seulement");
    }

    [Test]
    public static async Task Native_deadline_stops_the_blocked_process_without_waiting_for_real_time()
    {
        var id = Guid.NewGuid().ToString("N"); var clock = new DeadlineClock(); var adaptive = new AdaptiveReadBudget(clock);
        var journal = new NativeFailureJournal(); var before = NativeReadProcess.Running;
        var request = new NativeReadRequest(NativeReadKind.Registry, 3000)
        { Registry = new(InventoryRegistry.Machine, InventoryRegistry.UpdatePolicy, "WUServer", RegistryMethod.String) };
        using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, @"Local\Domenia.NativeFixture." + id);
        using var client = new NativeReadClient(Hello, null, default, clock, adaptive, journal);
        var reading = client.ReadAsync(request, NativeReadWorkerFixture.Prefix + id);
        Check.True(await Task.Run(() => ready.WaitOne(TimeSpan.FromSeconds(10))), "requête reçue avant expiration");
        using var child = Process.GetProcessById(client.ProcessId!.Value);
        clock.Advance(TimeSpan.FromMilliseconds(request.BudgetMs));
        Check.False(reading.IsCompleted, "le délai propre de l’enfant garde sa marge avant l’arrêt");
        clock.Advance(CimBudgets.GiveUpMargin);
        await Check.ThrowsAsync<TimeoutException>(() => reading, "délai déterministe");
        Check.True(child.HasExited, "délai n’est pas une simple fin d’attente du Task");
        Check.Equal(0, adaptive.Snapshot(Hello.Host).Active, "pas de place rendue avant la sortie OS");
        Check.Equal(1, adaptive.Snapshot(Hello.Host).Failures, "délai d’une requête effectivement envoyée mesuré");
        await Check.ThrowsAsync<ObjectDisposedException>(() => client.ReadAsync(request), "aucun rejeu après délai");
        var warning = journal.Warnings.Single();
        Check.Equal(before, journal.RunningAtWarning.Single(), "trace après restitution physique");
        Check.True(warning.Contains("kind=Registry;", StringComparison.Ordinal) && warning.Contains("budgetMs=3000; elapsedMs=5000; executionMs=5000;", StringComparison.Ordinal), "budget et durées exacts avant nettoyage");
        Check.True(warning.Contains("callerCancellation=False; requestDeadline=True", StringComparison.Ordinal), "expiration propre sans annulation appelante");
        Check.True(warning.Contains("exception=System.OperationCanceledException;", StringComparison.Ordinal)
            || warning.Contains("exception=System.Threading.Tasks.TaskCanceledException;", StringComparison.Ordinal), "exception observée avant conversion en TimeoutException");
        Check.True(warning.Contains("registry=UpdatePolicy/WUServer.", StringComparison.Ordinal), "appel registre identifié par un libellé fermé");
        CheckWriteBoundary(warning);
    }

    [Test]
    public static async Task Native_request_silent_past_its_deadline_hands_the_next_sources_to_a_fresh_child_a_bounded_number_of_times()
    {
        // Bench of 11/11/2026: one Defender query silent past its deadline stopped the child and the 14 sources after it were lost.
        var id = Guid.NewGuid().ToString("N"); var clock = new DeadlineClock(); var journal = new NativeFailureJournal();
        using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, @"Local\Domenia.NativeFixture." + id);
        using var session = new CimSession("PCR" + id[..8], TimeSpan.FromMinutes(5), clock, journal)
        { NativeWorkerMode = NativeReadWorkerFixture.Prefix + id, NativeClock = clock };
        string[] classes = ["Win32_BIOS", "Win32_Processor", "Win32_OperatingSystem", "Win32_ComputerSystemProduct"];
        for (var attempt = 0; attempt <= CimSession.NativeRestartLimit; attempt++)
        {
            ready.Reset();
            var query = "SELECT Name FROM " + classes[attempt];
            var reading = Task.Run(() => session.Read("Fixture", @"root\cimv2", query, 1, TimeSpan.FromSeconds(3), allowProjectionReuse: false));
            Check.True(await Task.Run(() => ready.WaitOne(TimeSpan.FromSeconds(10))), "requête reçue par le processus de lecture");
            clock.Advance(TimeSpan.FromSeconds(3) + CimBudgets.GiveUpMargin);
            var result = await reading;
            Check.Equal(SourceStatus.Interrupted, result.Status, "requête sans réponse dite interrompue, jamais rejouée");
            var fresh = attempt < CimSession.NativeRestartLimit;
            Check.Equal(fresh, result.Detail.Contains("processus neuf", StringComparison.Ordinal), fresh ? "la suite est confiée à un processus neuf" : "plafond de processus neufs atteint");
        }
        Check.Equal(CimSession.NativeRestartLimit, journal.Infos.Count(line => line.Contains("processus neuf", StringComparison.Ordinal)), "chaque processus neuf est consigné");
        ready.Reset();
        var after = session.Read("Fixture", @"root\cimv2", "SELECT Name FROM " + classes[^1], 1, TimeSpan.FromSeconds(3), allowProjectionReuse: false);
        Check.False(ready.WaitOne(0), "au-delà du plafond, aucun processus n’est lancé");
        Check.Equal(SourceStatus.Interrupted, after.Status, "source suivante dite non lue");
        Check.Contains("Lecture native non reçue", after.Detail, "aucun nouvel appel après le plafond");
        Check.Equal(CimSession.NativeRestartLimit + 1, journal.Warnings.Count, "un relevé par processus arrêté, aucun pour la source non envoyée");
    }

    [Test]
    public static async Task Native_physical_limit_queues_the_thirteenth_child_until_a_real_process_exits()
    {
        Check.Equal(0, NativeReadProcess.Running, "précondition : aucune fuite de processus d’un test précédent");
        var clients = new List<NativeReadClient>(); var processes = new List<Process>();
        try
        {
            for (var i = 0; i < NativeReadProcess.Limit; i++)
            {
                var client = new NativeReadClient(Hello, null, default, adaptive: new AdaptiveReadBudget(TimeProvider.System)); clients.Add(client);
                Check.Equal(SourceStatus.Skipped, (await client.ReadAsync(Query)).Reading!.Status, "vrai enfant prêt, aucun appel réseau");
                processes.Add(Process.GetProcessById(client.ProcessId!.Value));
            }
            Check.Equal(12, NativeReadProcess.Running, "12 enfants vivants comptés");
            Check.True(processes.All(p => !p.HasExited), "pas de faux quota basé sur des tâches terminées");
            using var waiting = new NativeReadClient(Hello, null, default, adaptive: new AdaptiveReadBudget(TimeProvider.System));
            var pending = waiting.ReadAsync(Query);
            Check.False(pending.IsCompleted, "attente locale avant tout lancement");
            Check.Null(waiting.ProcessId, "aucun treizième processus");
            Check.Equal(12, NativeReadProcess.Running, "aucune restitution d’une place occupée");
            clients[0].Dispose();
            Check.True(processes[0].HasExited, "place rendue après sortie réelle");
            Check.Equal(SourceStatus.Skipped, (await pending.WaitAsync(TimeSpan.FromSeconds(20))).Reading!.Status, "lecture admise sans perdre la cible");
            Check.Equal(12, NativeReadProcess.Running, "plafond toujours respecté");
            waiting.Dispose();
            foreach (var client in clients) { client.Dispose(); }
            Check.True(processes.All(p => p.HasExited), "tous réellement terminés"); Check.Equal(0, NativeReadProcess.Running, "toutes places restituées après sortie");
        }
        finally { foreach (var client in clients) { client.Dispose(); } foreach (var process in processes) { process.Dispose(); } }
    }

    [Test]
    public static async Task Native_adaptive_wait_keeps_the_existing_child_until_exit_and_launches_the_next_only_after_release()
    {
        var adaptive = new AdaptiveReadBudget(TimeProvider.System, 1);
        var before = NativeReadProcess.Running;
        using var first = new NativeReadClient(Hello, null, default, adaptive: adaptive);
        Check.Equal(SourceStatus.Skipped, (await first.ReadAsync(Query)).Reading!.Status, "premier enfant réel, lectures distantes désactivées");
        using var child = Process.GetProcessById(first.ProcessId!.Value);
        using var next = new NativeReadClient(Hello with { Host = "PC-SECOND" }, null, default, adaptive: adaptive);
        var waiting = next.ReadAsync(Query);
        Check.False(waiting.IsCompleted, "place en attente avant lancement"); Check.Null(next.ProcessId, "aucun deuxième enfant créé");
        Check.Equal(before + 1, NativeReadProcess.Running, "enfant existant conservé entre appels");
        first.Dispose(); Check.True(child.HasExited, "sortie OS effective avant restitution");
        Check.Equal(SourceStatus.Skipped, (await waiting).Reading!.Status, "seconde lecture explicitement demandée admise après libération");
        Check.Equal(1, adaptive.Snapshot(Hello.Host).Active, "une seule place acquise");
        next.Dispose(); Check.Equal(before, NativeReadProcess.Running, "plus aucun enfant");
    }

    [Test]
    public static async Task Native_adaptive_cancel_before_admission_never_starts_a_child_or_penalizes_the_source()
    {
        var adaptive = new AdaptiveReadBudget(TimeProvider.System, 1); using var held = adaptive.Acquire(Hello.Host);
        var before = NativeReadProcess.Running; var journal = new NativeFailureJournal(); using var stop = new CancellationTokenSource();
        using var client = new NativeReadClient(Hello, null, stop.Token, adaptive: adaptive, journal: journal);
        var reading = client.ReadAsync(Query); Check.False(reading.IsCompleted, "attente réelle d’admission");
        Check.Null(client.ProcessId, "aucun PID créé avant admission"); stop.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => reading, "annulation de la demande en attente");
        Check.Equal(before, NativeReadProcess.Running, "aucun processus lancé");
        Check.Equal(1, adaptive.Snapshot(Hello.Host).Active, "place tierce toujours détenue");
        Check.Equal(0, adaptive.Snapshot(Hello.Host).Failures, "aucune mesure d’échec inventée");
        var warning = journal.Warnings.Single();
        Check.True(warning.Contains("stage=Admission;", StringComparison.Ordinal) && warning.Contains("executionMs=absent;", StringComparison.Ordinal), "attente locale sans exécution native inventée");
        Check.True(warning.Contains("callerCancellation=True; requestDeadline=False; requestWriteCompleted=False;", StringComparison.Ordinal), "aucun délai ni envoi pendant l’admission");
        Check.Equal(before, journal.RunningAtWarning.Single(), "aucun enfant au moment de la trace");
    }

    [Test]
    public static async Task Native_adaptive_queue_does_not_spend_the_network_deadline_or_penalize_the_source()
    {
        var clock = new DeadlineClock(); var adaptive = new AdaptiveReadBudget(clock, 1);
        using var held = adaptive.Acquire(Hello.Host); var before = NativeReadProcess.Running;
        using var client = new NativeReadClient(Hello, null, default, clock, adaptive);
        var reading = client.ReadAsync(Query); Check.False(reading.IsCompleted, "attente avant lancement");
        clock.Advance(TimeSpan.FromMilliseconds(Query.BudgetMs * 10));
        Check.False(reading.IsCompleted, "attente locale distincte du budget réseau");
        Check.Null(client.ProcessId, "aucun PID"); Check.Equal(before, NativeReadProcess.Running, "aucun enfant créé");
        Check.Equal(1, adaptive.Snapshot(Hello.Host).Active, "place tierce conservée");
        Check.Equal(0, adaptive.Snapshot(Hello.Host).Failures, "aucune mesure de santé inventée pendant l’attente");
        held.Dispose();
        Check.Equal(SourceStatus.Skipped, (await reading.WaitAsync(TimeSpan.FromSeconds(20))).Reading!.Status, "la requête garde son budget complet après admission");
    }

    [Test]
    public static async Task Native_adaptive_suspension_refuses_a_following_request_and_reclaims_only_after_child_exit()
    {
        var adaptive = new AdaptiveReadBudget(TimeProvider.System);
        adaptive.ObserveAddress(Hello.Host, System.Net.IPAddress.Parse("192.0.2.10"));
        using var client = new NativeReadClient(Hello, null, default, adaptive: adaptive);
        Check.Equal(SourceStatus.Skipped, (await client.ReadAsync(Query)).Reading!.Status, "enfant réel prêt sans lecture distante");
        using var child = Process.GetProcessById(client.ProcessId!.Value);
        using (var peer = adaptive.Acquire(Hello.Host)) for (var i = 0; i < 3; i++) peer.Report(false, TimeSpan.FromMilliseconds(100));
        var failure = await Check.ThrowsAsync<DomeniaOperationException>(() => client.ReadAsync(Query), "requête suivante non envoyée à la source suspendue");
        Check.Equal("operation.siteBusy", failure.Code, "cause exacte");
        Check.True(child.HasExited, "enfant conservé réellement arrêté avant retour du refus");
        Check.Equal(0, adaptive.Snapshot(Hello.Host).Active, "place rendue après fin physique");
        Check.Equal("open", adaptive.Snapshot(Hello.Host).State, "refus d’admission sans guérison implicite");
    }

    [Test]
    public static async Task Native_write_context_keeps_its_separate_admission_even_when_the_read_site_is_suspended()
    {
        var adaptive = new AdaptiveReadBudget(TimeProvider.System);
        adaptive.ObserveAddress(Hello.Host, System.Net.IPAddress.Parse("192.0.2.10"));
        using (var failed = adaptive.Acquire(Hello.Host)) for (var i = 0; i < 3; i++) failed.Report(false, TimeSpan.FromMilliseconds(10));
        using var write = PhysicalWorkBudget.Enter(PhysicalWorkPriority.Write);
        using var client = new NativeReadClient(Hello, null, default, adaptive: adaptive);
        Check.Equal(SourceStatus.Skipped, (await client.ReadAsync(Query)).Reading!.Status, "lecture du circuit écritures indépendante du budget de fond");
        Check.Equal(0, adaptive.Snapshot(Hello.Host).Active, "aucune place de lecture empruntée");
        Check.Equal("open", adaptive.Snapshot(Hello.Host).State, "le circuit écriture ne guérit pas le site");
    }

    [Test]
    public static async Task Native_private_pipe_refuses_wrong_parent_PID_without_receiving_a_secret()
    {
        var name = "Domenia.NativeRead." + Guid.NewGuid().ToString("N");
        using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var connect = client.ConnectAsync(deadline.Token); await server.WaitForConnectionAsync(deadline.Token); await connect;
        NativeReadProcess.VerifyClient(server, Environment.ProcessId); NativeReadProcess.VerifyServer(client, Environment.ProcessId);
        Check.Throws<UnauthorizedAccessException>(() => NativeReadProcess.VerifyClient(server, -1), "faux enfant");
        Check.Throws<UnauthorizedAccessException>(() => NativeReadProcess.VerifyServer(client, -1), "faux parent");
    }

    [Test]
    public static void Native_worker_entry_refuses_nonlocal_or_unbounded_pipe_names()
    {
        Check.True(NativeReadWorkerHost.ValidPipeName("Domenia.NativeRead." + Guid.NewGuid().ToString("N")), "nom privé valide");
        foreach (var name in new[] { @"\\server\pipe\x", "Domenia.NativeRead...", "Domenia.NativeRead." + new string('x', 32), "" })
        { Check.False(NativeReadWorkerHost.ValidPipeName(name), "nom refusé"); }
        Check.Equal(2, NativeReadWorkerHost.Run([NativeReadWorkerHost.Argument, "bad", "1"]), "pas de connexion pour nom invalide");
    }

    [Test]
    public static void Native_failure_evidence_keeps_codes_and_closed_registry_labels_without_payload_or_exception_text()
    {
        const string privateText = "DO-NOT-LOG-target-account-query-value";
        var error = new Win32Exception(5, privateText + "\r\nsecond-line"); error.Data["detail"] = privateText;
        var clock = new DeadlineClock(); clock.Advance(TimeSpan.FromMilliseconds(125));
        foreach (var (registry, label) in new (RegistryRequest, string)[]
        {
            (new(InventoryRegistry.Machine, InventoryRegistry.UpdatePolicy.ToLowerInvariant(), "wuserver", RegistryMethod.String), "UpdatePolicy/WUServer"),
            (new(InventoryRegistry.Machine, InventoryRegistry.UpdatePolicy + @"\AU", "UseWUServer", RegistryMethod.Dword), "UpdatePolicy/AU/UseWUServer"),
            (new(InventoryRegistry.Machine, InventoryRegistry.UpdateInstall, "LastSuccessTime", RegistryMethod.String), "UpdateInstall/LastSuccessTime"),
            (new(InventoryRegistry.Users, InventoryRegistry.UpdatePolicy, "WUServer", RegistryMethod.String), "Other"),
            (new(InventoryRegistry.Machine, InventoryRegistry.UpdatePolicy, "WUServer", RegistryMethod.Dword), "Other"),
            (new(InventoryRegistry.Machine, privateText, privateText, RegistryMethod.String), "Other"),
        })
        {
            var request = new NativeReadRequest(NativeReadKind.Registry, 3000)
            { Registry = registry, Category = privateText, Namespace = privateText, Query = privateText, ExpectedComputerName = privateText };
            var evidence = NativeReadFailureEvidence.Capture(InventoryTransport.Dcom, request, NativeReadStage.WorkerStart,
                0, null, clock, default, default, false, error);
            var warning = evidence.Format();
            Check.Equal(125L, evidence.ElapsedMs, "capture au point d’échec");
            Check.Null(evidence.ExecutionMs, "aucune durée d’exécution inventée");
            Check.Equal(error.HResult, evidence.HResult, "code original conservé");
            Check.Equal(5, evidence.NativeErrorCode!.Value, "code Windows original");
            Check.True(warning.Contains("exception=System.ComponentModel.Win32Exception;", StringComparison.Ordinal)
                && warning.Contains("win32=0x00000005;", StringComparison.Ordinal), "type et code sans texte arbitraire");
            Check.True(warning.Contains("registry=" + label + ".", StringComparison.Ordinal), "projection fermée du registre");
            Check.False(warning.Contains(privateText, StringComparison.Ordinal) || warning.Contains(registry.Key, StringComparison.Ordinal), "aucune charge utile, clé brute, donnée d’exception ou cible");
            Check.False(warning.Any(char.IsControl), "une seule ligne");
            Check.True(warning.Length < 900, "trace bornée");
            clock.Advance(TimeSpan.FromMilliseconds(1000));
            Check.Equal(warning, evidence.Format(), "nettoyage ultérieur sans modifier les faits capturés");
            clock = new DeadlineClock(); clock.Advance(TimeSpan.FromMilliseconds(125));
        }
    }

    private static void CheckWriteBoundary(string warning)
    {
        // The child can signal readiness before the parent's asynchronous write continuation resumes.
        Check.True(warning.Contains("stage=RequestWrite;", StringComparison.Ordinal)
            || warning.Contains("stage=ResponseRead;", StringComparison.Ordinal), "frontière réellement atteinte après réception par l’enfant");
        var completed = warning.Contains("stage=ResponseRead;", StringComparison.Ordinal);
        Check.True(warning.Contains("requestWriteCompleted=" + completed + ";", StringComparison.Ordinal), "fin de l’écriture distincte de son commencement");
    }

    private sealed class NativeFailureJournal : ITechnicalJournal
    {
        internal List<string> Warnings { get; } = [];
        internal List<int> RunningAtWarning { get; } = [];
        public void Trace(string message) { }
        internal List<string> Infos { get; } = [];
        public void Info(string message) => Infos.Add(message);
        public void Error(string message, Exception exception) { }
        public void Warning(string message) { Warnings.Add(message); RunningAtWarning.Add(NativeReadProcess.Running); }
    }

    private sealed class DeadlineClock : TimeProvider
    {
        private readonly List<DeadlineTimer> timers = [];
        private long ticks;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() { lock (timers) { return ticks; } }
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new DeadlineTimer(this, callback, state); timer.Change(dueTime, period);
            lock (timers) { timers.Add(timer); } return timer;
        }
        internal void Advance(TimeSpan time)
        {
            DeadlineTimer[] copy; lock (timers) { ticks += time.Ticks; copy = [.. timers]; }
            foreach (var timer in copy) { timer.Fire(); }
        }
        private sealed class DeadlineTimer(DeadlineClock owner, TimerCallback callback, object? state) : ITimer
        {
            private long due = long.MaxValue;
            public bool Change(TimeSpan dueTime, TimeSpan period)
            { lock (owner.timers) { due = dueTime == Timeout.InfiniteTimeSpan ? long.MaxValue : owner.ticks + dueTime.Ticks; } return true; }
            internal void Fire()
            { lock (owner.timers) { if (due > owner.ticks) { return; } due = long.MaxValue; } callback(state); }
            public void Dispose() { lock (owner.timers) { due = long.MaxValue; } }
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
}

/// <summary>Test executable only. No native call or network: acknowledge a private request, signal readiness, then block.
/// Its process is intentionally killed by the production owner; it cannot be selected by any application operation.</summary>
internal static class NativeReadWorkerFixture
{
    internal const string Prefix = "--native-read-fixture-";
    internal static bool IsRequested(string[] args) => args.Length > 0 && args[0].StartsWith(Prefix, StringComparison.Ordinal);
    internal static async Task<int> RunAsync(string[] args)
    {
        if (args.Length != 3 || !Guid.TryParseExact(args[0][Prefix.Length..], "N", out _) || !NativeReadWorkerHost.ValidPipeName(args[1]) || !int.TryParse(args[2], out var parent)) { return 2; }
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var pipe = new NamedPipeClientStream(".", args[1], PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.ConnectAsync(deadline.Token); NativeReadProcess.VerifyServer(pipe, parent);
        var hello = await NativeReadProtocol.ReadAsync<NativeReadHello>(pipe, NativeReadProtocol.RequestLimit, deadline.Token);
        using var password = await NativeReadProtocol.ReadPasswordAsync(pipe, deadline.Token);
        if (hello.Session != (password is null) || !hello.Session && password?.Length != 32) { return 2; }
        await NativeReadProtocol.WriteAsync(pipe, true, 32, deadline.Token);
        var request = await NativeReadProtocol.ReadAsync<NativeReadRequest>(pipe, NativeReadProtocol.RequestLimit, deadline.Token); request.Check();
        using var ready = EventWaitHandle.OpenExisting(@"Local\Domenia.NativeFixture." + args[0][Prefix.Length..]); ready.Set();
        using var blocked = new ManualResetEvent(false); blocked.WaitOne(); return 0;
    }
}
