using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class WriteReceiptStateTests
{
    private static WriteReceipt Sent()
    {
        var plan = WritePlans.Seal(FakeWriteExecutor.Draft(), WritePlans.NewId(), @"TEST\operator", AppMode.Simulation, TestClock.Reference, TimeZoneInfo.Utc);
        return WriteReceipts.Sent(plan, WritePlans.NewId(), TestClock.Reference, new("Précontrôle", "Identité relue"));
    }
    [Test]
    public static void Transport_outcome_is_written_once_and_unknown_reads_cannot_erase_existing_evidence()
    {
        var sent = Sent();
        foreach (var result in new[] { WriteResult.Applied, WriteResult.NotApplied, WriteResult.Unknown })
        {
            var done = WriteReceipts.Completed(sent, new(result, "Réponse"), null, TestClock.Reference);
            Check.True(WriteReceipts.IsPending(done), "sans relecture, incertitude conservée");
            Check.Throws<InvalidOperationException>(() => WriteReceipts.Completed(done, new(WriteResult.Applied, "Autre réponse"), null, TestClock.Reference), "aucune réécriture du résultat");
            var verified = WriteReceipts.Verified(done, new(VerificationState.Verified, "Objet relu"), TestClock.Reference);
            var lost = WriteReceipts.Verified(verified, new(VerificationState.Unknown, "Contrôleur injoignable"), TestClock.Reference);
            Check.Equal(VerificationState.Verified, lost.Verification, "ancienne preuve conservée avec le nouvel échec dans les détails");
            Check.True(WriteReceiptStates.CanFollow(done, lost), "versions sautées après un échec disque admises sans perte de preuve");
            Check.False(WriteReceiptStates.CanFollow(verified, lost with { Result = WriteResult.NoChange }), "un envoi ne devient pas non envoyé");
            Check.False(WriteReceiptStates.CanFollow(verified, lost with { Verification = VerificationState.Unknown }), "preuve jamais effacée");
        }
        Check.True(WriteReceipts.IsPending(sent with { Result = (WriteResult)999 }), "état inconnu bloquant");
        Check.True(WriteReceipts.IsPending(sent with { Verification = (VerificationState)999 }), "vérification inconnue bloquante");
    }
    [Test]
    public static async Task Disk_rejects_illegal_transition_and_cold_reader_counts_injected_transition_as_unreadable()
    {
        using var folder = new TemporaryFolder(); var path = folder.File(FileReceiptStore.SimulationFileName);
        var first = Sent(); var done = WriteReceipts.Completed(first, new(WriteResult.Applied, "Acquittement"), null, TestClock.Reference);
        var forged = done with { Version = done.Version + 1, Result = WriteResult.NotApplied };
        using (var store = new FileReceiptStore(path, new RecordingJournal()))
        {
            await store.AppendAsync(first, default); await store.AppendAsync(done, default);
            await Check.ThrowsAsync<IOException>(() => store.AppendAsync(forged, default), "aucun remplacement du résultat sous verrou machine");
        }
        await using (var stream = new FileStream(path, FileMode.Append, FileAccess.Write)) await stream.WriteAsync(FileReceiptStore.Serialize(forged));
        using var cold = new FileReceiptStore(path, new RecordingJournal()); var read = await cold.ReadAllAsync(default);
        Check.True(read.Unreadable > 0, "transition injectée signalée");
        Check.Equal(WriteResult.Applied, read.Receipts.Single().Result, "dernière preuve légitime conservée");
    }
    [Test]
    public static async Task Concurrent_instances_cannot_both_admit_a_new_send()
    {
        using var folder = new TemporaryFolder(); var path = folder.File(FileReceiptStore.SimulationFileName);
        using var first = new FileReceiptStore(path, new RecordingJournal()); using var second = new FileReceiptStore(path, new RecordingJournal());
        static async Task<bool> Append(FileReceiptStore store)
        { try { await store.AppendAsync(Sent(), default); return true; } catch (IOException) { return false; } }
        // An independent OS owner keeps both writers outside the critical section until their own bound expires.
        await Task.Run(() =>
        {
            using var held = new Mutex(false, FileReceiptStore.LockNameFor(path));
            held.WaitOne();
            try
            {
                var blocked = Task.WhenAll(Append(first), Append(second)).GetAwaiter().GetResult();
                Check.False(blocked.Any(ok => ok), "aucune instance ne franchit le verrou détenu par un autre thread");
            }
            finally { held.ReleaseMutex(); }
        });
        var accepted = await Task.WhenAll(Append(first), Append(second));
        Check.Equal(1, accepted.Count(x => x), "une seule admission durable entre deux instances");
        Check.Equal(1, (await first.ReadAllAsync(default)).Receipts.Length, "un seul reçu d’envoi");
    }
    [Test]
    public static async Task Cold_circuit_restores_uncertainty_without_replaying_or_reconstructing_a_token()
    {
        var store = new MemoryReceiptStore(); var first = Sent(); await store.AppendAsync(first, default);
        var (context, circuit, executor, _) = WriteCircuitTests.FakeCircuit(store); using var owned = context;
        await circuit.RecoverAsync(default);
        Check.True(context.Journal.Snapshot().Any(e => e.Tone == Tone.Warn && e.Label.Contains("Reçus à contrôler", StringComparison.Ordinal)), "avis de reprise visible dans Opérations");
        Check.Equal(1, (await circuit.ListAsync(default)).Pending, "incertitude conservée après reprise");
        Check.Equal(0, executor.Executes, "aucune reprise d’envoi"); Check.Equal(0, executor.Verifies, "pas de relecture réseau automatique");
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(first.Plan.Id, "aucun-jeton-reconstruit", null, null, default), "confirmation absente");
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.PlanAsync(FakeWriteExecutor.Draft(), default), "cible retenue");
    }
    [Test]
    public static async Task Identical_reservation_and_backwards_clock_refuse_before_any_send()
    {
        var (context, circuit, executor, clock) = WriteCircuitTests.FakeCircuit(); using var owned = context;
        var first = await circuit.PlanAsync(FakeWriteExecutor.Draft(), default);
        var otherId = WritePlans.Seal(FakeWriteExecutor.Draft(), WritePlans.NewId(), first.Plan.Operator, AppMode.Simulation, TestClock.Reference.AddMinutes(1), TimeZoneInfo.Utc);
        Check.Equal(WritePlans.ComputeRequestFingerprint(first.Plan), WritePlans.ComputeRequestFingerprint(otherId), "clé indépendante des dates et identifiants");
        var duplicate = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.PlanAsync(FakeWriteExecutor.Draft(), default), "réservation existante");
        Check.Equal("write.reserved", duplicate.Code, "aucun second plan identique réservé");
        clock.Advance(TimeSpan.FromMinutes(-1));
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(first.Plan.Id, first.Token, null, null, default), "horloge reculée");
        var replacement = await circuit.PlanAsync(FakeWriteExecutor.Draft(), default);
        clock.Advance(TimeSpan.FromMinutes(1));
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(first.Plan.Id, first.Token, null, null, default), "une horloge revenue à l’heure ne ressuscite pas le premier plan");
        Check.True(replacement.Plan.Id != first.Plan.Id, "nouvelle confirmation distincte");
        Check.Equal(0, executor.Checks, "refus avant précontrôle réseau"); Check.Equal(0, executor.Executes, "aucun envoi");
    }
    [Test]
    public static void Technical_preview_names_domain_risks_and_keeps_multiline_values_on_one_line()
    {
        var draft = FakeWriteExecutor.Draft() with { Risks = [new(Tone.Warn, "Effet\nannoncé")], Changes = [new("description", "Description", WriteChangeKind.Replace, "Avant", "Après", "a\r\nb", "c\u2028d")] };
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Simulation, TestClock.Reference, TimeZoneInfo.Utc);
        Check.Contains("test.local", plan.Details, "domaine explicite"); Check.Contains("Effet annoncé", plan.Details, "risque aplati");
        Check.Contains("a b → c d", plan.Details, "avant et après lisibles sans nouvelle ligne injectée");
        Check.Equal("a\r\nb", plan.Changes.Single().BeforeValue, "donnée exacte du plan inchangée");
    }
    [Test]
    public static async Task Configured_plan_age_is_effective_and_unreadable_evidence_blocks_preparation()
    {
        var source = new Domenia.Simulation.SimulatedDirectorySource(Domenia.Simulation.SimulationOptions.Default, TestClock.Fixed());
        var clock = TestClock.Fixed(); var executor = new FakeWriteExecutor();
        using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal(),
            writers: WriteExecutors.From([executor]), receipts: new MemoryReceiptStore(),
            configuration: RuntimeConfiguration.Read("""{"Security":{"WritePlanMaxAgeMinutes":1}}"""u8.ToArray(), "test"));
        var circuit = WriteCircuit.From(context); var plan = await circuit.PlanAsync(FakeWriteExecutor.Draft(), default);
        Check.Equal(TimeSpan.FromMinutes(1), plan.Plan.ExpiresAt - plan.Plan.CreatedAt, "durée réellement scellée");
        clock.Advance(TimeSpan.FromMinutes(2));
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(plan.Plan.Id, plan.Token, null, null, default), "expiration configurée");
        Check.Equal(0, executor.Executes, "aucun envoi expiré");
        var (badContext, badCircuit, _, _) = WriteCircuitTests.FakeCircuit(new UnreadableStore()); using var owned = badContext;
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => badCircuit.PlanAsync(FakeWriteExecutor.Draft(), default), "ligne illisible");
        Check.Equal(WriteErrors.ReceiptUnavailable, refused.Code, "refus avant création du plan");
    }
    [Test]
    public static async Task Slow_durable_append_does_not_send_after_the_confirmation_deadline()
    {
        var store = new DelayedReceiptStore();
        var (context, circuit, executor, clock) = WriteCircuitTests.FakeCircuit(store); using var owned = context;
        store.OnFirst = () => clock.Advance(WritePlans.Lifetime);
        executor.OnVerify = _ => new(VerificationState.Unknown, "Aucune relecture concluante");
        var plan = await circuit.PlanAsync(FakeWriteExecutor.Draft(), default);
        var receipt = await circuit.ExecuteAsync(plan.Plan.Id, plan.Token, null, null, default);
        Check.Equal(0, executor.Executes, "délai contrôlé de nouveau après l’écriture disque");
        Check.True(receipt.Pending, "trace durable conservée sans prétendre connaître un effet");
    }
    private sealed class DelayedReceiptStore : IReceiptStore
    {
        private readonly MemoryReceiptStore inner = new();
        internal Action? OnFirst;
        public bool Persistent => true;
        public async Task AppendAsync(WriteReceipt receipt, CancellationToken token)
        { await inner.AppendAsync(receipt, token); if (receipt.Version == 1) OnFirst?.Invoke(); }
        public Task<ReceiptLog> ReadAllAsync(CancellationToken token) => inner.ReadAllAsync(token);
    }
    [Test]
    public static async Task Orphan_completion_cannot_create_history_and_duplicate_completion_does_not_write_twice()
    {
        using var folder = new TemporaryFolder(); var path = folder.File(FileReceiptStore.SimulationFileName);
        using var store = new FileReceiptStore(path, new RecordingJournal());
        var sent = Sent();
        var completed = WriteReceipts.Completed(sent, new(WriteResult.Applied, "Reçu"), null, sent.At);
        var forgedFirst = completed with { Version = 1 };
        Check.Null(FileReceiptStore.Parse(FileReceiptStore.Serialize(forgedFirst)), "une première version ne peut pas être déjà terminée");
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(forgedFirst, default), "version 1 forgée refusée avant écriture");
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(completed, default), "aucun ancêtre connu");
        await store.AppendAsync(sent, default);
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(sent, default), "une version 1 identique ne doit pas autoriser un double envoi");
        await store.AppendAsync(completed, default);
        var bytes = File.ReadAllBytes(path);
        await store.AppendAsync(completed, default);
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(path)), "répéter la conservation ne modifie pas le journal");
    }

    [Test]
    public static async Task Full_plan_table_preserves_live_confirmations_until_expiry_or_execution()
    {
        var (context, circuit, executor, clock) = WriteCircuitTests.FakeCircuit(); using var owned = context;
        var original = await circuit.PlanAsync(FakeWriteExecutor.Draft(), default);
        for (var i = 1; i < WriteCircuit.PlanCapacity; i++)
            await circuit.PlanAsync(FakeWriteExecutor.Draft(Guid.NewGuid().ToString("D")), default);
        var error = await Check.ThrowsAsync<DomeniaOperationException>(
            () => circuit.PlanAsync(FakeWriteExecutor.Draft(Guid.NewGuid().ToString("D")), default), "65e plan refusé");
        Check.Equal("write.planCapacity", error.Code, "aucune confirmation active évincée");
        await circuit.ExecuteAsync(original.Plan.Id, original.Token, null, null, default);
        Check.Equal(1, executor.Executes, "la première confirmation reste valide");
        await circuit.PlanAsync(FakeWriteExecutor.Draft(), default);
        clock.Advance(WritePlans.Lifetime);
        await circuit.PlanAsync(FakeWriteExecutor.Draft(), default);
    }

    [Test]
    public static void Evidence_cannot_lose_details_identity_or_timestamps_after_a_clock_reversal()
    {
        var sent = Sent();
        var done = WriteReceipts.Completed(sent, new(WriteResult.Applied, "Acquittée"), null, sent.At);
        var proof = WriteReceipts.Verified(done, new(VerificationState.Verified, "Relue"), sent.At.AddMinutes(-1));
        Check.Equal(done.At, proof.At, "chronologie conservée malgré le recul de l’horloge");
        var next = WriteReceipts.Verified(proof, new(VerificationState.Unknown, "Non joignable"), sent.At);
        foreach (var broken in new[] { next with { SentAt = next.SentAt.AddSeconds(1) }, next with { Operator = "autre" },
            next with { Mode = "autre" }, next with { Simulated = !next.Simulated }, next with { CompletedAt = null },
            next with { VerifiedAt = null }, next with { Details = [] }, next with { Details = next.Details.SetItem(0, new("Remplacement", "Illégitime")) } })
            Check.False(WriteReceiptStates.CanFollow(proof, broken), "historique contradictoire refusé");
        Check.Throws<InvalidOperationException>(() => WriteReceipts.Verified(proof, new(VerificationState.Reviewed, "auto"), sent.At), "revue humaine jamais inventée");
        Check.Throws<InvalidOperationException>(() => WriteReceipts.Reviewed(proof, "contrôle externe", "autre", sent.At), "reçu déjà conclu");
    }

    [Test]
    public static async Task Concurrent_preparations_share_one_reservation_and_unreadable_store_is_reported_at_startup()
    {
        var (context, circuit, _, _) = WriteCircuitTests.FakeCircuit(); using var owned = context;
        var start = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task<string> Reserve()
        {
            await start.Task;
            try { await circuit.PlanAsync(FakeWriteExecutor.Draft(), default); return "created"; }
            catch (DomeniaOperationException error) { return error.Code; }
        }
        var both = Task.WhenAll(Reserve(), Reserve()); start.SetResult();
        Check.True((await both).Order(StringComparer.Ordinal).SequenceEqual(["created", "write.reserved"]),
            "une seule confirmation réservée pour les deux pages");
        var (failedContext, failedCircuit, _, _) = WriteCircuitTests.FakeCircuit(new FailingReceiptStore(1, failReads: true));
        using var failed = failedContext; await failedCircuit.RecoverAsync(default);
        Check.True(failedContext.Journal.Snapshot().Any(e => e.Tone == Tone.Alert && e.Label.Contains("illisibles", StringComparison.Ordinal)),
            "échec d’accès au journal visible au démarrage");
    }

    [Test]
    public static async Task An_identical_completion_cannot_hide_missing_durable_bytes_from_this_process()
    {
        using var folder = new TemporaryFolder(); var path = folder.File(FileReceiptStore.SimulationFileName);
        using var store = new FileReceiptStore(path, new RecordingJournal());
        var first = Sent();
        var done = WriteReceipts.Verified(WriteReceipts.Completed(first, new(WriteResult.Applied, "Acquittée"), null, first.At),
            new(VerificationState.Verified, "Relue"), first.At);
        await store.AppendAsync(first, default); await store.AppendAsync(done, default);
        File.WriteAllBytes(path, FileReceiptStore.Serialize(Sent()));
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(done, default), "aucun faux succès depuis la copie mémoire");
        Check.True((await store.ReadAllAsync(default)).Unreadable > 0, "disparition détectée même sans première lecture après append");
    }

    [Test]
    public static async Task Startup_opens_even_when_a_local_reader_does_not_honor_its_deadline()
    {
        var store = new SlowReadStore();
        var (context, circuit, executor, _) = WriteCircuitTests.FakeCircuit(store); using var owned = context;
        try
        {
            await circuit.RecoverAsync(default).WaitAsync(TimeSpan.FromSeconds(10));
            Check.False(store.End.Task.IsCompleted, "le shell reprend avant le retour du fournisseur");
            Check.True(context.Journal.Snapshot().Any(e => e.Label.Contains("différé", StringComparison.Ordinal)), "limite visible dans Opérations");
            Check.Equal(0, executor.Executes, "aucun rejeu");
        }
        finally { store.End.TrySetResult(new([], 0)); }
    }
    private sealed class SlowReadStore : IReceiptStore
    {
        internal readonly TaskCompletionSource<ReceiptLog> End = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Persistent => true;
        public Task AppendAsync(WriteReceipt receipt, CancellationToken token) => throw new InvalidOperationException();
        public Task<ReceiptLog> ReadAllAsync(CancellationToken token) => End.Task;
    }

    private sealed class UnreadableStore : IReceiptStore
    {
        public bool Persistent => true;
        public Task AppendAsync(WriteReceipt receipt, CancellationToken token) => throw new InvalidOperationException("Aucun envoi attendu");
        public Task<ReceiptLog> ReadAllAsync(CancellationToken token) => Task.FromResult(new ReceiptLog([], 1));
    }

}
