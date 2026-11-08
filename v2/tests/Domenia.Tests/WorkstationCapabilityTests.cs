using System.Runtime.InteropServices;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class WorkstationCapabilityTests
{
    [Test]
    public static void Large_fleet_negative_capabilities_keep_bounded_order_and_invalidate_only_the_changed_host()
    {
        var clock = TestClock.Fixed(); var memory = new WorkstationCapabilityMemory(clock);
        var context = memory.Capture(1, 0, 0, "TEST\\operator", CancellationToken.None);
        for (var i = 0; i < 100_000; i++)
            context.Record("PC-" + i, "DCOM", "Win32_BIOS", WorkstationCapabilityFailure.ClassAbsent, "26100", null);
        Check.Equal(WorkstationCapabilityMemory.Capacity, memory.Count, "cache borné sur cent mille postes");
        Check.Null(context.Find("PC-0", "DCOM", "Win32_BIOS", "26100", null, true), "ancienne entrée évincée");
        Check.True(context.Find("PC-99999", "DCOM", "Win32_BIOS", "26100", null, true) is not null, "dernière entrée conservée");
        context.Record("PC-99999", "DCOM", "Win32_DiskDrive", WorkstationCapabilityFailure.ClassAbsent, "26100", null);
        context.ObserveBuild("PC-99999", "DCOM", "26200");
        Check.Null(context.Find("PC-99999", "DCOM", "Win32_BIOS", "26200", null, true), "classes de l’ancien build invalidées");
        Check.Null(context.Find("PC-99999", "DCOM", "Win32_DiskDrive", "26200", null, true), "toutes les classes du seul poste sont retirées");
        Check.True(context.Find("PC-99998", "DCOM", "Win32_BIOS", "26100", null, true) is not null, "autre poste inchangé");
        context.Success("PC-99998", "DCOM", "Win32_BIOS");
        Check.Null(context.Find("PC-99998", "DCOM", "Win32_BIOS", "26100", null, true), "réussite retire aussi l’index secondaire");
        clock.Advance(TimeSpan.FromDays(8));
        context.Record("NEW", "DCOM", "Win32_BIOS", WorkstationCapabilityFailure.ClassAbsent, "26200", null);
        Check.Equal(1, memory.Count, "expiration nettoyée sans accumuler les anciens index");
    }

    private const string Host = "PC1.test.local", Ns = @"root\cimv2", Class = "root\\cimv2|Win32_BIOS", Transport = "Dcom";
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static void Capability_TTLs_are_exact_and_memory_stays_bounded()
    {
        foreach (var (failure, duration) in new[] { (WorkstationCapabilityFailure.ClassAbsent, TimeSpan.FromDays(7)),
            (WorkstationCapabilityFailure.ProtocolUnreachable, TimeSpan.FromMinutes(15)), (WorkstationCapabilityFailure.RightDenied, TimeSpan.FromHours(1)) })
        {
            var clock = TestClock.Fixed(); var memory = new WorkstationCapabilityMemory(clock); var owner = memory.Capture(1, 0, 0, "TEST\\a", None);
            owner.Record(Host, Transport, Class, failure, "26100", null);
            Check.Equal(failure, owner.Find(Host, Transport, Class, "26100", null, true)!.Failure, "fait effectivement enregistré");
            clock.Advance(duration - TimeSpan.FromTicks(1)); Check.True(owner.Find(Host, Transport, Class, "26100", null, true) is not null, "valide avant échéance");
            clock.Advance(TimeSpan.FromTicks(1)); Check.Null(owner.Find(Host, Transport, Class, "26100", null, true), "expiré exactement à l’échéance");
            for (var i = 0; i <= WorkstationCapabilityMemory.Capacity; i++)
            { owner.Record("PC" + i, Transport, Class, failure, "26100", null); }
            Check.Equal(WorkstationCapabilityMemory.Capacity, memory.Count, "plafond dur");
            Check.Null(owner.Find("PC0", Transport, Class, "26100", null, true), "plus ancien fait évincé");
        }
    }

    [Test]
    public static void Class_absence_skips_the_next_query_without_crediting_progress_or_allocating_a_worker()
    {
        var clock = TestClock.Fixed(); var memory = new WorkstationCapabilityMemory(clock);
        using var scope = WorkstationCapabilityMemory.Enter(memory.Capture(1, 0, 0, "TEST\\a", None));
        var calls = 0;
        using (var first = Session(clock, query =>
        { calls++; return Bootstrap(query) ?? throw new COMException("opaque", unchecked((int)0x80041010)); }))
        {
            Qualify(first);
            var failed = ReadBios(first);
            Check.Equal(SourceStatus.Unavailable, failed.Status, "absence native précise");
            Check.Equal(WorkstationCapabilityFailure.ClassAbsent, failed.CapabilityFailure, "code fermé");
        }
        using var next = Session(clock, query => { calls++; return Bootstrap(query) ?? throw new InvalidOperationException("La classe mémorisée ne doit pas être contactée."); });
        Qualify(next);
        var queries = next.QueriesIssued; var actualCalls = calls; var progress = 0; next.QueryCompleted = () => progress++;
        var skipped = ReadBios(next);
        Check.Equal(SourceStatus.Skipped, skipped.Status, "non relu annoncé");
        Check.Contains("lecture précédente", skipped.Detail, "preuve datée distincte d’une nouvelle absence");
        Check.Equal(actualCalls, calls, "aucun transport"); Check.Equal(queries, next.QueriesIssued, "aucune requête comptée");
        Check.Equal(0, progress, "aucun crédit d’inactivité pour le cache");
    }

    [Test]
    public static void A_really_read_OS_build_invalidates_absent_classes_and_success_forgets_the_fact()
    {
        var clock = TestClock.Fixed(); var memory = new WorkstationCapabilityMemory(clock); var owner = memory.Capture(1, 0, 0, "TEST\\a", None);
        owner.Record(Host, Transport, Class, WorkstationCapabilityFailure.ClassAbsent, "26100", null);
        using var scope = WorkstationCapabilityMemory.Enter(owner);
        var bios = 0;
        using var session = Session(clock, query => Bootstrap(query, "26200") ?? Bios());
        IEnumerable<WmiInstance> Bios() { bios++; return [Row(("SerialNumber", "fixture"))]; }
        Qualify(session);
        Check.Equal(SourceStatus.Ok, ReadBios(session).Status, "nouveau build relu avant la classe");
        Check.Equal(1, bios, "classe réellement interrogée");
        Check.Null(owner.Find(Host, Transport, Class, "26200", null, true), "réussite et nouveau build oublient le fait");
    }

    [Test]
    public static void Account_and_session_changes_retire_old_facts_and_late_owners_cannot_clear_current_refusals()
    {
        var clock = TestClock.Fixed(); var memory = new WorkstationCapabilityMemory(clock);
        var old = memory.Capture(4, 1, 0, "TEST\\a", None);
        old.Record(Host, Transport, Class, WorkstationCapabilityFailure.RightDenied, null, null);
        var next = memory.Capture(4, 2, 0, "TEST\\b", None);
        Check.Null(next.Find(Host, Transport, Class, null, null, false), "nouveau compte ignore le refus précédent");
        next.Record(Host, Transport, Class, WorkstationCapabilityFailure.ProtocolUnreachable, null, null);
        old.Success(Host, Transport, Class); old.Record(Host, Transport, Class, WorkstationCapabilityFailure.RightDenied, null, null);
        Check.Equal(WorkstationCapabilityFailure.ProtocolUnreachable, next.Find(Host, Transport, Class, null, null, false)!.Failure, "propriétaire tardif sans effet");
        var replacement = memory.Capture(5, 0, 0, "TEST\\a", None);
        Check.Equal(0, memory.Count, "nouvelle session repart sans mémoire");
        _ = memory.Capture(4, 9, 9, "TEST\\old", None);
        next.Record(Host, Transport, Class, WorkstationCapabilityFailure.RightDenied, null, null);
        Check.Null(replacement.Find(Host, Transport, Class, null, null, false), "ancienne session ne réactive rien");
    }

    [Test]
    public static void Refusal_and_unreachable_are_not_inferred_as_absent_classes_from_error_text()
    {
        foreach (var (code, status, fact) in new[] { (unchecked((int)0x80070005), SourceStatus.Refused, WorkstationCapabilityFailure.RightDenied),
            (unchecked((int)0x800706BA), SourceStatus.Unreachable, WorkstationCapabilityFailure.ProtocolUnreachable),
            (unchecked((int)0x80004005), SourceStatus.Error, WorkstationCapabilityFailure.None) })
        {
            var clock = TestClock.Fixed(); var memory = new WorkstationCapabilityMemory(clock); var owner = memory.Capture(1, 0, 0, "TEST\\a", None);
            using var scope = WorkstationCapabilityMemory.Enter(owner);
            using var session = Session(clock, _ => throw new COMException("invalid class / classe non valide", code));
            var result = ReadBios(session);
            Check.Equal(status, result.Status, "statut numérique conservé"); Check.Equal(fact, result.CapabilityFailure, "aucune classification par texte");
            Check.Equal(fact != WorkstationCapabilityFailure.None, owner.Find(Host, Transport, Class, null, null, false) is not null, "mémoire seulement sur fait certain");
        }
    }

    [Test]
    public static void A_right_denied_on_one_class_does_not_disable_other_classes_after_identity_was_confirmed()
    {
        var clock = TestClock.Fixed(); var memory = new WorkstationCapabilityMemory(clock);
        using var scope = WorkstationCapabilityMemory.Enter(memory.Capture(1, 0, 0, "TEST\\a", None));
        using var first = Session(clock, query => Bootstrap(query) ?? throw new COMException("opaque", unchecked((int)0x80070005)));
        Qualify(first); Check.Equal(SourceStatus.Refused, ReadBios(first).Status, "refus réel de la classe");
        var otherCalls = 0;
        using var next = Session(clock, query => Bootstrap(query) ?? Other());
        IEnumerable<WmiInstance> Other() { otherCalls++; return [Row(("Name", "CPU"))]; }
        Qualify(next);
        Check.Equal(SourceStatus.Skipped, ReadBios(next).Status, "classe refusée non réessayée");
        Check.Equal(SourceStatus.Ok, next.Read("Cpu", Ns, "SELECT Name FROM Win32_Processor", 1).Status, "autre classe encore lisible");
        Check.Equal(1, otherCalls, "seule l’autre classe a atteint le transport");
    }

    [Test]
    public static void Wrong_identity_cancellation_and_timeout_do_not_poison_capability_memory()
    {
        var clock = TestClock.Fixed(); var memory = new WorkstationCapabilityMemory(clock); var owner = memory.Capture(1, 0, 0, "TEST\\a", None);
        using var scope = WorkstationCapabilityMemory.Enter(owner);
        using (var wrong = Session(clock, query => Bootstrap(query, name: "OTHER") ?? throw new COMException("opaque", unchecked((int)0x8004100E))))
        { Qualify(wrong); Check.Equal(SourceStatus.Unavailable, ReadBios(wrong).Status, "absence native reçue"); }
        Check.Null(owner.Find(Host, Transport, Class, null, null, true), "absence non attribuée à une autre identité");
        using (var timeout = Session(clock, _ => throw new TimeoutException()))
        { Check.Equal(SourceStatus.Interrupted, ReadBios(timeout).Status, "timeout non mémorisé comme absence"); }
        using var stop = new CancellationTokenSource();
        using var cancelled = new CimSession(Host, TimeSpan.FromSeconds(20), clock, cancellationToken: stop.Token)
        { ReadOverride = (_, _, _) => { stop.Cancel(); throw new COMException("opaque", unchecked((int)0x80070005)); } };
        ReadBios(cancelled);
        Check.Equal(0, memory.Count, "aucun fait après annulation ni timeout ni identité divergente");
    }

    [Test]
    public static async Task Full_inventory_really_bypasses_memory_but_keeps_cancellation()
    {
        var clock = TestClock.Fixed(); var memory = new WorkstationCapabilityMemory(clock); var owner = memory.Capture(1, 0, 0, "TEST\\a", None);
        owner.Record(Host, Transport, Class, WorkstationCapabilityFailure.RightDenied, null, null);
        using var scope = WorkstationCapabilityMemory.Enter(owner);
        using var stop = new CancellationTokenSource(); var contacted = false;
        var reader = new WmiWorkstationReader(clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
            { RegistryEnabled = false, ReadOverride = (_, _, _) => { contacted = true; stop.Cancel(); return []; } },
        };
        var result = await reader.ReadSharedAsync(Host, WorkstationReading.Full, null, stop.Token);
        Check.True(contacted, "l’inventaire complet a réellement traversé le refus mémorisé");
        Check.True(result.Access.Any(a => a.Status == SourceStatus.Interrupted), "annulation reste terminale");
        Check.Equal(WorkstationCapabilityFailure.RightDenied, owner.Find(Host, Transport, Class, null, null, false)!.Failure, "lecture annulée ne fabrique pas une réussite");
    }

    [Test]
    public static async Task Closed_native_failure_fact_survives_the_bounded_IPC_reply()
    {
        using var bytes = new MemoryStream();
        var reading = new CimReading("Bios", SourceStatus.Unavailable, "opaque", 1, []) { CapabilityFailure = WorkstationCapabilityFailure.ClassAbsent };
        await NativeReadProtocol.WriteAsync(bytes, new NativeReadReply(Reading: reading), NativeReadProtocol.ResponseLimit, None);
        bytes.Position = 0;
        var received = (await NativeReadProtocol.ReadAsync<NativeReadReply>(bytes, NativeReadProtocol.ResponseLimit, None)).Reading!;
        Check.Equal(WorkstationCapabilityFailure.ClassAbsent, received.CapabilityFailure, "fait renvoyé au moteur hôte");
        Check.Equal(SourceStatus.Unavailable, received.Status, "statut conservé");
    }

    [Test]
    public static async Task Real_Bridge_composition_shares_memory_only_inside_its_EngineContext()
    {
        var module = new CapabilityModule();
        using (var first = Engine())
        {
            var responses = new List<BridgeResponse>();
            using var dispatcher = new BridgeDispatcher(OperationModules.CreateRegistry(first, [module]), responses.Add);
            await dispatcher.HandleAsync(Message("first"), None); await dispatcher.HandleAsync(Message("second"), None);
            Check.True(responses.All(r => r.Error is null), "handlers réellement exécutés");
            Check.True(module.Results.SequenceEqual([SourceStatus.Unreachable, SourceStatus.Skipped]), "seconde lecture retirée avant le transport");
        }
        using var other = Engine();
        using var next = new BridgeDispatcher(OperationModules.CreateRegistry(other, [module]), _ => { });
        await next.HandleAsync(Message("other"), None);
        Check.Equal(SourceStatus.Unreachable, module.Results.Last(), "autre moteur sans fait hérité");
        Check.Null(WorkstationCapabilityMemory.Current, "scope serveur non propagé au caller");
    }

    private static string Message(string id) => JsonSerializer.Serialize(new { id, op = "capability.read", args = new { } });
    private static EngineContext Engine()
    {
        var clock = TestClock.Fixed(); var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        return new(new(AppMode.Directory, ModeReason.Argument, "transport injecté", null, "test.local", []), source, new MemoryPreferenceStore(), clock, new RecordingJournal());
    }
    private sealed class CapabilityModule : IOperationModule
    {
        public string Screen => "capability";
        internal List<SourceStatus> Results { get; } = [];
        public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
        [new("capability.read", OperationClass.NetworkRead, (_, _, _) =>
        {
            Check.True(WorkstationCapabilityMemory.Current is not null, "scope réellement raccordé par le dispatcher");
            using var session = Session(context.Clock, _ => throw new COMException("opaque", unchecked((int)0x800706BA)));
            var result = ReadBios(session); Results.Add(result.Status); return Task.FromResult<object?>(result.Status);
        }, "lecture native injectée")];
    }
    private static CimSession Session(TimeProvider clock, Func<string, IEnumerable<WmiInstance>> read) =>
        new(Host, TimeSpan.FromSeconds(20), clock) { ReadOverride = (_, query, _) => read(query) };
    private static CimReading ReadBios(CimSession session) => session.Read("Bios", Ns, "SELECT SerialNumber FROM Win32_BIOS", 1);
    private static void Qualify(CimSession session)
    {
        Check.Equal(SourceStatus.Ok, session.Read("Os", Ns, "SELECT BuildNumber FROM Win32_OperatingSystem", 1).Status, "build terminé");
        Check.Equal(SourceStatus.Ok, session.Read("Identity", Ns, "SELECT Name FROM Win32_ComputerSystem", 1).Status, "identité terminée");
    }
    private static IEnumerable<WmiInstance>? Bootstrap(string query, string build = "26100", string name = "PC1") =>
        query.Contains("FROM Win32_OperatingSystem", StringComparison.Ordinal) ? [Row(("BuildNumber", build))]
        : query.Contains("FROM Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", name))] : null;
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value, StringComparer.OrdinalIgnoreCase));
}
