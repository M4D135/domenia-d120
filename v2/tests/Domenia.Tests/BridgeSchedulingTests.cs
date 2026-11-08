using System.Collections.Concurrent;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>Deterministic admission transitions with an injected clock. No handler/network is needed for capacity tests; dispatcher cases use gates.</summary>
internal static class BridgeSchedulingTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly JsonElement Empty = JsonSerializer.SerializeToElement(new { });
    private static Task<object?> Answer(JsonElement _, BridgeContext __, CancellationToken ___) => Task.FromResult<object?>(true);
    private static OperationDefinition Read(string name = "test.read", OperationPriority priority = OperationPriority.Explicit,
        OperationProvider provider = OperationProvider.Directory, string? replacement = null) => new(name, OperationClass.NetworkRead, Answer, "Lecture de test")
        { Scheduling = new(priority, provider, [], ReplacementKey: replacement) };
    private static OperationDefinition Immediate(string name = "test.immediate", OperationClass kind = OperationClass.NetworkRead)
        => new(name, kind, Answer, "Demande immédiate");
    private static Task<BridgeAdmission.Lease> Enter(BridgeAdmission admission, string id, OperationDefinition? operation = null, CancellationToken token = default)
        => admission.EnterAsync(id, operation ?? Read(), Empty, token, () => { });
    private static BridgeAdmission NewAdmission(FixedTimeProvider? clock = null)
        => new(clock ?? TestClock.Fixed(), _ => Task.FromResult(new BridgeSessionStamp("session-a", "site-a")));
    private static async Task<List<BridgeAdmission.Lease>> Hold(BridgeAdmission admission, int count, OperationDefinition? definition = null)
    {
        var result = new List<BridgeAdmission.Lease>();
        for (var i = 0; i < count; i++) { result.Add(await Enter(admission, "held-" + i, definition ?? Immediate())); }
        return result;
    }
    private static void Release(IEnumerable<BridgeAdmission.Lease> held) { foreach (var lease in held) { lease.Dispose(); } }
    private static string Message(string id, string op, object? args = null) => JsonSerializer.Serialize(new { id, op, args = args ?? new { } });
    private static BridgeResponse Final(ConcurrentQueue<BridgeResponse> sent, string id) => sent.Last(r => r.Id == id && r.Kind is "error" or "result");

    [Test]
    public static async Task Exactly_32_reads_wait_and_the_33rd_is_refused_without_reserving_an_id()
    {
        using var admission = NewAdmission();
        var held = await Hold(admission, BridgeAdmission.NetworkLimit);
        using var cancel = new CancellationTokenSource();
        var waiting = Enumerable.Range(0, 32).Select(i => Enter(admission, "queued-" + i, token: cancel.Token)).ToArray();
        try
        {
            Check.Equal(32, admission.Load.Queued, "exactement 32 lectures attendent sans worker");
            Check.True(waiting.All(t => !t.IsCompleted), "aucune lecture n’a obtenu de place");
            var refused = await Check.ThrowsAsync<BridgeOperationException>(() => Enter(admission, "overflow"), "33e lecture refusée");
            Check.Equal("operation.queueFull", refused.Code, "refus explicite de file pleine");
            Check.Equal(BridgeAdmission.NetworkLimit, admission.Load.Network, "aucun dépassement réseau");
            cancel.Cancel();
            foreach (var task in waiting) { await Check.ThrowsAsync<OperationCanceledException>(() => task, "retrait de chaque demande annulée"); }
            Check.Equal(0, admission.Load.Queued, "toutes les entrées et inscriptions sont libérées");
            var retry = Enter(admission, "overflow");
            held[0].Dispose();
            using var accepted = await retry.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally { cancel.Cancel(); Release(held); }
    }

    [Test]
    public static async Task Queued_cancellation_releases_the_id_without_removing_a_new_request_with_the_same_id()
    {
        using var admission = NewAdmission();
        var held = await Hold(admission, 8);
        using var cancel = new CancellationTokenSource();
        var old = Enter(admission, "same", token: cancel.Token);
        cancel.Cancel();
        var next = Enter(admission, "same");
        try
        {
            await Check.ThrowsAsync<OperationCanceledException>(() => old, "la première demande est annulée avant envoi");
            Check.Equal(1, admission.Load.Queued, "la nouvelle demande homonyme reste inscrite");
            held[0].Dispose();
            using var lease = await next.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(0, admission.Load.Queued, "la nouvelle demande est admise une seule fois");
        }
        finally { Release(held); }
    }

    [Test]
    public static async Task Duplicate_ids_cover_the_queue_as_well_as_running_requests()
    {
        using var admission = NewAdmission();
        var held = await Hold(admission, 8);
        using var cancel = new CancellationTokenSource();
        var waiting = Enter(admission, "queued", token: cancel.Token);
        try
        {
            var duplicate = await Check.ThrowsAsync<BridgeOperationException>(() => Enter(admission, "queued"), "doublon en attente refusé");
            Check.Equal("operation.duplicate", duplicate.Code, "la file participe à l’unicité des identifiants");
            Check.Equal(1, admission.Load.Queued, "le doublon n’occupe aucune autre place");
        }
        finally { cancel.Cancel(); Release(held); }
        await Check.ThrowsAsync<OperationCanceledException>(() => waiting, "nettoyage de la seule demande en attente");
    }

    [Test]
    public static async Task Explicit_then_selection_then_background_are_promoted_in_priority_and_arrival_order()
    {
        using var admission = NewAdmission();
        var held = await Hold(admission, 8);
        var background = Enter(admission, "background", Read(priority: OperationPriority.Background));
        var selection = Enter(admission, "selection", Read(priority: OperationPriority.Selection));
        var first = Enter(admission, "explicit-1");
        var second = Enter(admission, "explicit-2");
        try
        {
            held[0].Dispose();
            using var one = await first.WaitAsync(TimeSpan.FromSeconds(5));
            Check.False(second.IsCompleted || selection.IsCompleted || background.IsCompleted, "la première explicite part seule");
            one.Dispose();
            using var two = await second.WaitAsync(TimeSpan.FromSeconds(5));
            Check.False(selection.IsCompleted || background.IsCompleted, "ordre d’arrivée entre priorités égales");
            two.Dispose();
            using var selected = await selection.WaitAsync(TimeSpan.FromSeconds(5));
            Check.False(background.IsCompleted, "sélection avant fond");
            selected.Dispose(); held[1].Dispose(); held[2].Dispose();
            using var low = await background.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally { Release(held); }
    }

    [Test]
    public static async Task Background_reserves_two_network_places_and_aging_can_use_one_after_30_seconds()
    {
        var clock = TestClock.Fixed();
        using var admission = NewAdmission(clock);
        var held = await Hold(admission, 7);
        var waiting = Enter(admission, "aged", Read(priority: OperationPriority.Background));
        try
        {
            clock.Advance(TimeSpan.FromSeconds(29)); await admission.RefreshAsync();
            Check.False(waiting.IsCompleted, "le fond respecte les places réservées avant 30 secondes");
            clock.Advance(TimeSpan.FromSeconds(1)); await admission.RefreshAsync();
            using var aged = await waiting.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(8, admission.Load.Network, "un seul fond âgé prend une place réservée sans dépasser huit");
        }
        finally { Release(held); }
    }

    [Test]
    public static async Task An_aged_background_precedes_newer_foreground_only_when_no_background_is_running()
    {
        var clock = TestClock.Fixed();
        using var admission = NewAdmission(clock);
        var held = await Hold(admission, 8);
        var background = Enter(admission, "background", Read(priority: OperationPriority.Background));
        var explicitRead = Enter(admission, "explicit");
        try
        {
            clock.Advance(TimeSpan.FromSeconds(30)); held[0].Dispose();
            using var aged = await background.WaitAsync(TimeSpan.FromSeconds(5));
            Check.False(explicitRead.IsCompleted, "l’unique fond âgé progresse sous charge");
            aged.Dispose();
            using var next = await explicitRead.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally { Release(held); }
    }

    [Test]
    public static async Task A_read_expires_at_120_seconds_before_any_slot_is_released()
    {
        var clock = TestClock.Fixed();
        using var admission = NewAdmission(clock);
        var held = await Hold(admission, 8);
        var waiting = Enter(admission, "expired");
        try
        {
            clock.Advance(TimeSpan.FromSeconds(119)); await admission.RefreshAsync();
            Check.False(waiting.IsCompleted, "encore en attente avant la borne");
            clock.Advance(TimeSpan.FromSeconds(1)); await admission.RefreshAsync();
            var error = await Check.ThrowsAsync<BridgeOperationException>(() => waiting, "expiration sans attendre un résultat réseau");
            Check.Equal("operation.queueExpired", error.Code, "retrait avant envoi");
            Check.Equal(0, admission.Load.Queued, "entrée expirée retirée");
            Check.Equal(8, admission.Load.Network, "les vrais handlers restent comptés");
        }
        finally { Release(held); }
    }

    [Test]
    public static async Task A_changed_session_withdraws_the_queue_and_is_checked_again_at_real_start()
    {
        var stamp = new BridgeSessionStamp("epoch-1", "controller-1");
        using var admission = new BridgeAdmission(TestClock.Fixed(), _ => Task.FromResult(stamp));
        var held = await Hold(admission, 8);
        var waiting = Enter(admission, "stale");
        try
        {
            stamp = new("epoch-2", "controller-2"); await admission.RefreshAsync();
            var error = await Check.ThrowsAsync<BridgeOperationException>(() => waiting, "session différente retire la file");
            Check.Equal("operation.contextChanged", error.Code, "preuve de refus de contexte");
            held[0].Dispose();
            using var next = await Enter(admission, "fresh");
            stamp = new("epoch-3", "controller-2");
            var late = await Check.ThrowsAsync<BridgeOperationException>(() => admission.RevalidateAsync(next, None), "dernier contrôle au départ réel");
            Check.Equal("operation.contextChanged", late.Code, "un changement après promotion reste refusé");
        }
        finally { Release(held); }
    }

    [Test]
    public static async Task A_new_selection_replaces_only_an_older_queued_selection()
    {
        using var admission = NewAdmission();
        var held = await Hold(admission, 8);
        var definition = Read(priority: OperationPriority.Selection, replacement: "object");
        var old = Enter(admission, "old", definition);
        var next = Enter(admission, "new", definition);
        try
        {
            var error = await Check.ThrowsAsync<BridgeOperationException>(() => old, "ancienne sélection remplacée");
            Check.Equal("operation.superseded", error.Code, "pas une annulation de travail déjà exécuté");
            Check.Equal(1, admission.Load.Queued, "une seule sélection attend");
            held[0].Dispose(); using var selected = await next.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally { Release(held); }
    }

    [Test]
    public static async Task Writes_get_one_immediate_reserved_place_and_are_never_queued_even_with_read_metadata()
    {
        using var admission = NewAdmission();
        var held = await Hold(admission, BridgeAdmission.OrdinaryLimit, Immediate(kind: OperationClass.Local));
        var write = Immediate("test.write", OperationClass.Write) with { Scheduling = new(OperationPriority.Background, OperationProvider.Directory, []) };
        try
        {
            using var reserved = await Enter(admission, "write", write);
            var refused = await Check.ThrowsAsync<BridgeOperationException>(() => Enter(admission, "write-overflow", write), "écriture saturée refusée immédiatement");
            Check.Equal("operation.busy", refused.Code, "aucune écriture différée");
            var localWrite = write with { Name = "test.localWrite", Class = OperationClass.LocalWrite };
            await Check.ThrowsAsync<BridgeOperationException>(() => Enter(admission, "local-write", localWrite), "écriture locale jamais en file");
            using var stop = await Enter(admission, "stop", Immediate("test.stop", OperationClass.Local));
            Check.Equal(0, admission.Load.Queued, "aucune écriture conservée dans la file");
            Check.Equal(1, admission.Load.Control, "l’arrêt reste admis à saturation");
        }
        finally { Release(held); }
    }

    [Test]
    public static async Task Provider_background_budget_is_enforced_and_aging_adds_at_most_one_read()
    {
        var clock = TestClock.Fixed();
        using var admission = NewAdmission(clock);
        var held = await Hold(admission, 4, Read());
        var waiting = Enter(admission, "background", Read(priority: OperationPriority.Background));
        try
        {
            Check.False(waiting.IsCompleted, "quatre lectures Directory saturent son budget de fond malgré une place globale");
            clock.Advance(TimeSpan.FromSeconds(30)); await admission.RefreshAsync();
            using var aged = await waiting.WaitAsync(TimeSpan.FromSeconds(5));
            using var cancel = new CancellationTokenSource();
            var second = Enter(admission, "second", Read(priority: OperationPriority.Background), cancel.Token);
            clock.Advance(TimeSpan.FromSeconds(30)); await admission.RefreshAsync();
            Check.False(second.IsCompleted, "le fond déjà actif interdit une deuxième exception de vieillissement");
            cancel.Cancel(); await Check.ThrowsAsync<OperationCanceledException>(() => second, "retrait de la seconde lecture");
        }
        finally { Release(held); }
    }

    [Test]
    public static async Task Failures_pause_only_background_then_recovery_widens_after_success_without_retrying_failures()
    {
        var clock = TestClock.Fixed();
        using var admission = NewAdmission(clock);
        var explicitRead = Read(provider: OperationProvider.Cim);
        for (var i = 0; i < 2; i++)
        {
            using var failed = await Enter(admission, "failure-" + i, explicitRead);
            failed.Complete(new TimeoutException());
        }
        var background = explicitRead with { Scheduling = new(OperationPriority.Background, OperationProvider.Cim, []) };
        var first = Enter(admission, "recovery-1", background);
        var second = Enter(admission, "recovery-2", background);
        var third = Enter(admission, "recovery-3", background);
        clock.Advance(TimeSpan.FromSeconds(30)); await admission.RefreshAsync();
        Check.False(first.IsCompleted || second.IsCompleted || third.IsCompleted, "aging ne franchit jamais la pause de 60 secondes");
        using (var voluntary = await Enter(admission, "voluntary", explicitRead))
        { voluntary.Complete(new UnauthorizedAccessException()); }
        Check.False(first.IsCompleted, "refus d’accès n’efface pas une pause de la cible et n’escalade pas la panne");
        clock.Advance(TimeSpan.FromSeconds(30)); await admission.RefreshAsync();
        using var one = await first.WaitAsync(TimeSpan.FromSeconds(5));
        Check.False(second.IsCompleted || third.IsCompleted, "une seule lecture repart après la pause");
        one.Complete(null); one.Dispose();
        using var two = await second.WaitAsync(TimeSpan.FromSeconds(5));
        using var three = await third.WaitAsync(TimeSpan.FromSeconds(5));
        Check.Equal(2, admission.Load.Network, "une réponse réussie élargit la reprise à deux lectures");
        Check.Equal(0, admission.Load.Queued, "les anciennes demandes échouées ne sont jamais recréées");
    }

    [Test]
    public static async Task Credential_rejection_blocks_the_same_identity_until_a_new_session_is_captured()
    {
        var stamp = new BridgeSessionStamp("account-generation-1", "site");
        using var admission = new BridgeAdmission(TestClock.Fixed(), _ => Task.FromResult(stamp));
        using (var refused = await Enter(admission, "first"))
        { refused.Complete(new DomeniaOperationException("account.rejected", "Refus de test")); }
        var blocked = await Check.ThrowsAsync<BridgeOperationException>(() => Enter(admission, "second"), "même compte refusé même pour un geste explicite");
        Check.Equal("operation.credentialsBlocked", blocked.Code, "aucun nouvel envoi d’un compte rejeté");
        stamp = new("account-generation-2", "site");
        using var changed = await Enter(admission, "new-account");
        Check.Equal(1, admission.Load.Network, "le changement explicite de génération est une nouvelle admission");
    }

    [Test]
    public static async Task Dispatcher_announces_queueing_then_calls_the_handler_once_after_release()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var full = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sent = new ConcurrentQueue<BridgeResponse>(); var calls = 0;
        var held = Immediate() with { Handler = async (_, _, _) =>
        { if (Interlocked.Increment(ref calls) == 8) { full.SetResult(); } await release.Task; return true; } };
        var queuedCalls = 0;
        var read = Read() with { Handler = (_, _, _) => { Interlocked.Increment(ref queuedCalls); return Task.FromResult<object?>(true); } };
        using var dispatcher = new BridgeDispatcher(new OperationRegistry([held, read]), sent.Enqueue);
        var pending = Enumerable.Range(0, 8).Select(i => dispatcher.HandleAsync(Message("held-" + i, held.Name), None)).ToArray();
        try
        {
            await full.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var queued = dispatcher.HandleAsync(Message("queued", read.Name), None);
            Check.Equal("event", sent.Single(r => r.Id == "queued").Kind, "attente explicitement publiée");
            Check.Equal(0, queuedCalls, "aucun handler avant admission réelle");
            release.SetResult(); await queued.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(1, queuedCalls, "un seul départ de la demande en attente");
            Check.Equal("result", Final(sent, "queued").Kind, "résultat final du seul handler");
        }
        finally { release.TrySetResult(); await Task.WhenAll(pending); }
    }

    [Test]
    public static async Task Dispatcher_requalifies_context_on_the_actual_worker_before_invoking_the_handler()
    {
        var captures = 0; var calls = 0; var sent = new ConcurrentQueue<BridgeResponse>();
        var read = Read() with { Handler = (_, _, _) => { calls++; return Task.FromResult<object?>(true); } };
        var registry = new OperationRegistry([read], TestClock.Fixed(), _ => Task.FromResult(
            new BridgeSessionStamp(Interlocked.Increment(ref captures) < 3 ? "before" : "after", "site")));
        using var dispatcher = new BridgeDispatcher(registry, sent.Enqueue);
        await dispatcher.HandleAsync(Message("changed", read.Name), None);
        Check.Equal(0, calls, "le changement entre promotion et worker empêche le handler");
        Check.Equal("operation.contextChanged", Final(sent, "changed").Error!.Code, "dernier contrôle de contexte effectif");
        Check.Equal(0, dispatcher.AdmissionLoad.Running, "place libérée après refus de contexte");
    }

    [Test]
    public static async Task Oversized_unknown_or_sensitive_queue_arguments_never_reach_the_handler()
    {
        var calls = 0; var sent = new ConcurrentQueue<BridgeResponse>();
        var read = Read() with { Scheduling = new(OperationPriority.Explicit, OperationProvider.Directory, ["values"]),
            Handler = (_, _, _) => { calls++; return Task.FromResult<object?>(true); } };
        using var dispatcher = new BridgeDispatcher(new OperationRegistry([read]), sent.Enqueue);
        await dispatcher.HandleAsync(Message("secret", read.Name, new { password = "private-value" }), None);
        Check.Equal(DomeniaErrors.ArgumentsInvalid, Final(sent, "secret").Error!.Code, "les propriétés inconnues ne sont pas conservées");
        await dispatcher.HandleAsync(Message("large", read.Name, new { values = new string('x', 17_000) }), None);
        Check.Equal("operation.queuePayload", Final(sent, "large").Error!.Code, "enveloppe de lecture bornée à 16 Kio");
        Check.Equal(0, calls, "aucun handler lancé pour les demandes refusées");
        Check.Equal(0, dispatcher.AdmissionLoad.Queued, "aucune donnée sensible mise en attente");
        Check.Throws<ArgumentException>(() => new OperationRegistry([read with { Scheduling = new(OperationPriority.Explicit, OperationProvider.Directory, ["credential"]) }]),
            "une déclaration de lecture sensible est refusée à la composition");
    }

    [Test]
    public static async Task Cancellation_does_not_release_a_running_handler_that_has_not_finished()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sent = new ConcurrentQueue<BridgeResponse>();
        var read = Read() with { Handler = async (_, _, _) => { entered.SetResult(); await release.Task; return true; } };
        using var dispatcher = new BridgeDispatcher(new OperationRegistry([read]), sent.Enqueue);
        using var cancel = new CancellationTokenSource();
        var pending = dispatcher.HandleAsync(Message("running", read.Name), cancel.Token);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5)); cancel.Cancel();
            Check.Equal(1, dispatcher.AdmissionLoad.Running, "l’appel qui ignore encore l’arrêt garde sa place physique de handler");
            Check.False(pending.IsCompleted, "aucune fin fabriquée par l’admission");
        }
        finally { release.TrySetResult(); await pending; }
        Check.Equal(0, dispatcher.AdmissionLoad.Running, "la fin réelle libère la place");
        Check.Equal("operation.cancelled", Final(sent, "running").Error!.Code, "l’annulation demandée n’est pas transformée en succès tardif");
    }

    [Test]
    public static void The_operation_table_keeps_writes_plans_and_unknown_reads_out_of_the_queue()
    {
        Check.True(BridgeScheduling.Eligible(BridgeScheduling.Declare(Read("directory.ou.children") with { Scheduling = null })), "lecture annuaire connue raccordée");
        Check.False(BridgeScheduling.Eligible(BridgeScheduling.Declare(Immediate("accounts.unlock.plan", OperationClass.LocalRead))), "plan jamais différé");
        Check.False(BridgeScheduling.Eligible(BridgeScheduling.Declare(Immediate("write.execute", OperationClass.Write))), "écriture jamais différée");
        Check.False(BridgeScheduling.Eligible(BridgeScheduling.Declare(Immediate("unknown.read"))), "absence de déclaration ne fabrique pas d’éligibilité");
    }

    [Test]
    public static async Task A_suspended_qualification_still_expires_a_queued_read_at_120_seconds_without_a_handler()
    {
        var clock = TestClock.Fixed();
        var hanging = new TaskCompletionSource<BridgeSessionStamp>(TaskCreationOptions.RunContinuationsAsynchronously);
        var handlerCalls = 0;
        var read = Read() with { Handler = (_, _, _) => { Interlocked.Increment(ref handlerCalls); return Task.FromResult<object?>(true); } };
        using var admission = new BridgeAdmission(clock, _ => hanging.Task);
        var held = await Hold(admission, 8);
        var waiting = Enter(admission, "suspended", read);
        var stuck = admission.RefreshAsync();   // the shared qualification suspends: the single-flight guard stays held
        try
        {
            Check.Equal(1, admission.Load.Queued, "une lecture attend, aucune place libérée");
            clock.Advance(TimeSpan.FromSeconds(120));
            await admission.RefreshAsync();   // a tick must expire even while the qualification is suspended
            var error = await Check.ThrowsAsync<BridgeOperationException>(() => waiting, "retrait observable sans handler");
            Check.Equal("operation.queueExpired", error.Code, "expiration sous qualification suspendue, et non une exception générique");
            Check.Equal(0, handlerCalls, "aucun handler lancé pour une lecture jamais admise");
            Check.Equal(8, admission.Load.Network, "aucune libération mensongère d’un travail encore actif");
        }
        finally { hanging.TrySetResult(new BridgeSessionStamp("late", "site")); Release(held); }
        await stuck;
    }

    [Test]
    public static async Task A_withdrawal_reaches_the_caller_while_the_shared_refresh_is_suspended()
    {
        var clock = TestClock.Fixed();
        var handlerCalls = 0;
        var read = Read() with { Handler = (_, _, _) => { Interlocked.Increment(ref handlerCalls); return Task.FromResult<object?>(true); } };
        var suspended = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var hanging = new TaskCompletionSource<BridgeSessionStamp>(TaskCreationOptions.RunContinuationsAsynchronously);
        var captures = 0;
        using var admission = new BridgeAdmission(clock, _ =>
        {
            if (Interlocked.Increment(ref captures) == 1) { return Task.FromResult(new BridgeSessionStamp("session-a", "site-a")); }
            suspended.TrySetResult();   // the first capture is immediate, the shared refresh is the one that suspends
            return hanging.Task;
        });
        var held = await Hold(admission, 8);
        var waiting = Enter(admission, "suspended-refresh", read);
        await suspended.Task.WaitAsync(TimeSpan.FromSeconds(5));
        try
        {
            Check.Equal(1, admission.Load.Queued, "la lecture attend pendant que la capture globale est suspendue");
            clock.Advance(TimeSpan.FromSeconds(120));
            await admission.RefreshAsync();   // a tick must expire even while the shared capture is suspended
            var error = await Check.ThrowsAsync<BridgeOperationException>(() => waiting, "le retrait est observable sans attendre la capture globale");
            Check.Equal("operation.queueExpired", error.Code, "expiration sous refresh suspendu, et non une exception générique");
            Check.False(hanging.Task.IsCompleted, "l’appelant est libéré avant toute résolution de la seconde capture");
            Check.Equal(0, admission.Load.Queued, "l’entrée expirée est retirée de la file");
            Check.Equal(0, handlerCalls, "aucun handler lancé pour une lecture jamais admise");
            Check.Equal(8, admission.Load.Network, "les huit handlers actifs gardent leur place physique");
        }
        finally { hanging.TrySetResult(new BridgeSessionStamp("late", "site")); Release(held); }
    }

    [Test]
    public static async Task A_local_cancellation_reaches_the_caller_while_the_shared_refresh_is_suspended()
    {
        var clock = TestClock.Fixed();
        var suspended = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var hanging = new TaskCompletionSource<BridgeSessionStamp>(TaskCreationOptions.RunContinuationsAsynchronously);
        var captures = 0;
        using var admission = new BridgeAdmission(clock, _ =>
        {
            if (Interlocked.Increment(ref captures) == 1) { return Task.FromResult(new BridgeSessionStamp("session-a", "site-a")); }
            suspended.TrySetResult();
            return hanging.Task;
        });
        var held = await Hold(admission, 8);
        using var cancel = new CancellationTokenSource();
        var waiting = Enter(admission, "cancelled-refresh", token: cancel.Token);
        await suspended.Task.WaitAsync(TimeSpan.FromSeconds(5));
        try
        {
            cancel.Cancel();
            await Check.ThrowsAsync<OperationCanceledException>(() => waiting, "retrait local observable sans attendre la capture globale");
            Check.False(hanging.Task.IsCompleted, "aucune résolution fabriquée de la capture suspendue");
            Check.Equal(0, admission.Load.Queued, "l’entrée annulée est retirée sans place fabriquée");
            Check.Equal(8, admission.Load.Network, "les huit handlers actifs gardent leur place physique");
        }
        finally { hanging.TrySetResult(new BridgeSessionStamp("late", "site")); Release(held); }
    }

    [Test]
    public static async Task A_provider_that_ignores_cancellation_cannot_grow_unbounded_pending_qualifications()
    {
        var clock = TestClock.Fixed();
        var never = new TaskCompletionSource<BridgeSessionStamp>(TaskCreationOptions.RunContinuationsAsynchronously);   // ignores cancellation
        using var admission = new BridgeAdmission(clock, _ => never.Task);
        var held = await Hold(admission, 8);
        var rotations = 0; string? refusal = null;
        for (var i = 0; i < BridgeAdmission.QueueLimit + 4 && refusal is null; i++)
        {
            using var cancel = new CancellationTokenSource();
            var task = Enter(admission, "rotate-" + i, token: cancel.Token);
            cancel.Cancel();
            try { await task; }
            catch (OperationCanceledException) { rotations++; }
            catch (BridgeOperationException ex) { refusal = ex.Code; }
        }
        Check.Equal("operation.busy", refusal ?? "", "les qualifications pendantes sont bornées même si le fournisseur ignore l’annulation");
        Check.True(rotations <= BridgeAdmission.QueueLimit, "au plus une file de captures est conservée en suspens");
        never.TrySetResult(new BridgeSessionStamp("drain", "site"));
        Release(held);
    }

    [Test]
    public static async Task A_capture_throwing_synchronously_returns_its_reservation_and_removes_only_its_entry()
    {
        var clock = TestClock.Fixed();
        var attempts = 0;
        using var admission = new BridgeAdmission(clock, _ =>
        {
            if (Interlocked.Increment(ref attempts) <= 2 * BridgeAdmission.QueueLimit) { throw new InvalidOperationException("préambule de capture en panne"); }
            return Task.FromResult(new BridgeSessionStamp("session-a", "site-a"));
        });
        var held = await Hold(admission, 8);
        try
        {
            for (var i = 0; i < 2 * BridgeAdmission.QueueLimit; i++)
            {
                var failure = await Check.ThrowsAsync<InvalidOperationException>(() => Enter(admission, "reuse"), "le throw synchrone du fournisseur remonte à l’appelant");
                Check.Contains("préambule de capture en panne", failure.Message, "le motif réel de l’appelant est conservé, jamais une exception générique");
                Check.Equal(0, admission.Load.Queued, "l’entrée du throw est retirée exactement une fois");
            }
            Check.Equal(8, admission.Load.Network, "aucune place n’a été prise ni rendue pendant l’orage de captures");
            held[0].Dispose();
            using var recovered = await Enter(admission, "reuse").WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(8, admission.Load.Network, "la réservation rendue permet une admission réelle après plus de trente-deux échecs");
            Check.Equal(0, admission.Load.Queued, "le même identifiant est réutilisable, aucune entrée ne survit aux captures en panne");
        }
        finally { Release(held); }
    }

    [Test]
    public static async Task The_capture_delegate_is_invoked_outside_the_gate_that_protects_the_queue()
    {
        var clock = TestClock.Fixed();
        var stamp = new BridgeSessionStamp("session-a", "site-a");
        var handlerCalls = 0;
        var read = Read() with { Handler = (_, _, _) => { Interlocked.Increment(ref handlerCalls); return Task.FromResult<object?>(true); } };
        var insidePreamble = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releasePreamble = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var preambleLeft = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var parked = 0; var blockedThread = -1; string? preambleFailure = null;
        using var admission = new BridgeAdmission(clock, captureToken =>
        {
            // only the capture started by the dedicated blocked thread parks; periodic timer captures on other threads stay immediate
            if (Environment.CurrentManagedThreadId == Volatile.Read(ref blockedThread) && Interlocked.CompareExchange(ref parked, 1, 0) == 0)
            {
                insidePreamble.TrySetResult();
                if (!releasePreamble.Task.Wait(TimeSpan.FromSeconds(10))) { preambleFailure = "le préambule ciblé n’a jamais été libéré avant l’échéance de la garde bornée"; }
                preambleLeft.TrySetResult();
            }
            return Task.FromResult(stamp);
        });
        var held = await Hold(admission, 8);
        using var pendingCancel = new CancellationTokenSource();
        var pending = Enter(admission, "pending", read, pendingCancel.Token);   // the queued read the other thread will withdraw
        var blocked = Task.Run(() =>
        {
            Volatile.Write(ref blockedThread, Environment.CurrentManagedThreadId);   // identity of the thread owning the targeted preamble
            return Enter(admission, "blocked", read);
        });
        Task<(int Queued, bool Withdrawn, int Network)>? interferer = null;
        (int Queued, bool Withdrawn, int Network) seen = default;
        try
        {
            await insidePreamble.Task.WaitAsync(TimeSpan.FromSeconds(5));   // barrier 1: the targeted preamble really runs on its own thread
            interferer = Task.Run<(int Queued, bool Withdrawn, int Network)>(
                () => (admission.Load.Queued, admission.CancelQueued("pending"), admission.Load.Network));
            seen = await interferer.WaitAsync(TimeSpan.FromSeconds(5));     // barrier 2: another thread, bounded guard, never a sleep
            Check.Equal(1, admission.Load.Queued, "seule la lecture à la capture suspendue attend encore, l’autre a été retirée");
            Check.Equal(8, admission.Load.Network, "les huit handlers déjà actifs gardent leur place physique pendant le préambule");
            Check.False(preambleLeft.Task.IsCompleted, "le préambule ciblé n’a pas quitté son thread quand le thread interférent a terminé");
            Check.False(releasePreamble.Task.IsCompleted, "tout ceci est obtenu avant toute libération du préambule");
        }
        catch (TimeoutException)
        {
            throw new TestFailureException(insidePreamble.Task.IsCompleted
                ? "préambule du fournisseur atteint, mais un autre thread n’a pu ni lire la file ni retirer une lecture en file : la porte de l’admission est tenue pendant l’invocation"
                : "le préambule ciblé n’a jamais été atteint sur le thread dédié de blocked");
        }
        finally
        {
            releasePreamble.TrySetResult();                 // the targeted preamble always leaves, even after a failed assertion
            admission.CancelQueued("blocked");
            admission.CancelQueued("pending");              // idempotent: only a queued read is withdrawn, never a started one
            var drained = Task.WhenAll(blocked, interferer ?? Task.CompletedTask, pending).ContinueWith(static task => { _ = task.Exception; },
                CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
            admission.Dispose();                            // closing the window withdraws every still queued read: no Enter task can survive
            await drained;
            Release(held);
        }
        Check.True(preambleFailure is null, preambleFailure ?? "le préambule ciblé a été libéré dans la garde bornée");
        Check.True(preambleLeft.Task.IsCompleted, "le préambule ciblé a bien quitté son thread dédié");
        Check.Equal(1, parked, "une seule capture a été ciblée, les captures périodiques de minuterie sont restées immédiates");
        Check.Equal(2, seen.Queued, "la file reste lisible depuis un autre thread pendant le préambule du fournisseur");
        Check.True(seen.Withdrawn, "le retrait local d’une autre lecture en file reste possible pendant le préambule");
        Check.Equal(8, seen.Network, "aucune place n’a été prise ni rendue mensongèrement pendant l’interleaving");
        var cancelled = await Check.ThrowsAsync<OperationCanceledException>(() => pending, "le vrai motif du retrait revient à l’appelant");
        Check.Equal(pendingCancel.Token, cancelled.CancellationToken, "le retrait vient du retrait local de cette seule lecture");
        Check.Equal(0, handlerCalls, "aucun handler lancé pour les deux lectures jamais admises");
        Check.Equal(0, admission.Load.Queued, "aucune demande bloquée ne survit à l’interleaving");
    }

    [Test]
    public static async Task Dispatcher_cancels_only_a_queued_read_before_its_real_start()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sent = new ConcurrentQueue<BridgeResponse>(); var calls = 0;
        var held = Immediate() with { Handler = async (_, _, _) => { if (Interlocked.Increment(ref calls) == 8) { entered.SetResult(); } await release.Task; return true; } };
        var queuedOp = Read("test.queued") with { Handler = (_, _, _) => Task.FromResult<object?>(true) };
        using var dispatcher = new BridgeDispatcher(new OperationRegistry([held, queuedOp]), sent.Enqueue);
        var pending = Enumerable.Range(0, 8).Select(i => dispatcher.HandleAsync(Message("held-" + i, held.Name), None)).ToArray();
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var waiting = dispatcher.HandleAsync(Message("queued", queuedOp.Name), None);
            Check.Equal(1, dispatcher.AdmissionLoad.Queued, "la lecture est en file avant toute décision");
            Check.True(dispatcher.CancelQueued("queued"), "retrait local avant le départ réel");
            await waiting.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal("operation.cancelled", Final(sent, "queued").Error!.Code, "retrait avant départ publié, jamais un résultat fabriqué");
            Check.False(dispatcher.CancelQueued("held-0"), "un handler déjà parti n’est jamais déclaré annulé par le dispatcher");
            Check.False(dispatcher.CancelQueued("absent"), "une demande inconnue n’est jamais inventée");
            Check.Equal(8, dispatcher.AdmissionLoad.Running, "les huit handlers actifs gardent leur place physique");
        }
        finally { release.TrySetResult(); await Task.WhenAll(pending); }
    }

    [Test]
    public static async Task The_stamp_follows_the_working_ou_even_when_the_source_epoch_is_unchanged()
    {
        var clock = TestClock.Fixed();
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock,
            new RecordingJournal(), ScreenReaders.Discover(source, [typeof(SimulatedDirectorySource).Assembly]));
        var sent = new ConcurrentQueue<BridgeResponse>();
        // Only session operations belong to this test. Composing the full SimulatedBridge also starts SyncOperations'
        // local startup read on a detached worker, whose physical lease could outlive this test and pollute the next one.
        using var dispatcher = new BridgeDispatcher(new OperationRegistry(new SessionOperations().CreateOperations(context),
            clock, token => BridgeScheduling.Capture(context, token)), sent.Enqueue);
        var epoch = (await context.Directory.GetSessionAsync(None)).Epoch;
        await dispatcher.HandleAsync(Message("postes", "session.setScope", new { dn = "OU=Postes,DC=example,DC=local", subtree = true }), None);
        Check.Equal("result", Final(sent, "postes").Kind, "première OU réellement choisie");
        var postes = await BridgeScheduling.Capture(context, None);
        await dispatcher.HandleAsync(Message("paris", "session.setScope", new { dn = "OU=Paris,OU=Postes,DC=example,DC=local", subtree = true }), None);
        Check.Equal("result", Final(sent, "paris").Kind, "seconde OU réellement choisie");
        var paris = await BridgeScheduling.Capture(context, None);
        Check.True(postes.Identity != paris.Identity, "deux OU de travail différentes donnent deux empreintes distinctes");
        Check.Equal(epoch, (await context.Directory.GetSessionAsync(None)).Epoch, "la sélection locale n’a pas bougé l’epoch de la source");
    }
}
