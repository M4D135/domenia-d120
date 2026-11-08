using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

internal static class WriteConsultationTests
{
    [Test]
    public static async Task Active_send_and_uncertain_receipt_block_reads_without_replaying_the_write()
    {
        var (context, circuit, executor, _) = WriteCircuitTests.FakeCircuit(); using var owned = context;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var release = new ManualResetEventSlim();
        executor.OnExecute = _ => { entered.SetResult(); if (!release.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException(); return new(WriteResult.Unknown, "Réponse perdue."); };
        executor.OnVerify = _ => new(VerificationState.Unknown, "Relecture indisponible.");
        var plan = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        var execution = Task.Run(() => circuit.ExecuteAsync(plan.Plan.Id, plan.Token, null, null, CancellationToken.None));
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.EnsureConsultationAllowedAsync(CancellationToken.None), "consultation pendant envoi");
            Check.Equal("read.writeBusy", refused.Code, "motif exact");
            Check.True((await circuit.ListAsync(CancellationToken.None)).InFlight, "état transmis à la navigation");
        }
        finally { release.Set(); }
        var receipt = await execution;
        var pending = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.EnsureConsultationAllowedAsync(CancellationToken.None), "consultation incertaine");
        Check.Equal("read.receiptsPending", pending.Code, "reçu à vérifier");
        executor.OnVerify = _ => new(VerificationState.Verified, "Objet relu.");
        await circuit.VerifyAsync(receipt.Id, CancellationToken.None);
        await circuit.EnsureConsultationAllowedAsync(CancellationToken.None);
        Check.Equal(1, executor.Executes, "résolution par lecture uniquement");
    }

    [Test]
    public static async Task A_read_overlapping_a_completed_write_is_discarded_and_unreadable_receipts_fail_closed()
    {
        var (context, circuit, _, _) = WriteCircuitTests.FakeCircuit(); using var owned = context;
        var before = await circuit.EnsureConsultationAllowedAsync(CancellationToken.None);
        var planned = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.EnsureConsultationUnchangedAsync(before, CancellationToken.None), "retour antérieur jamais accepté après écriture");
        var (badContext, badCircuit, _, _) = WriteCircuitTests.FakeCircuit(new FailingReceiptStore(int.MaxValue, failReads: true)); using var badOwned = badContext;
        await Check.ThrowsAsync<DomeniaOperationException>(() => badCircuit.EnsureConsultationAllowedAsync(CancellationToken.None), "état illisible ne vaut pas libre");
        foreach (var operation in new[] { "search.preload", "search.view", "requetes.preview.page", "requetes.collect.run", "machine.account.use", "poste.account.other" })
            Check.True(OperationReadGuards.RequiresGuard(operation), operation);
        foreach (var operation in new[] { "write.receipts.list", "write.receipts.verify", "operations.receipt.review", "search.survey.stop" })
            Check.False(OperationReadGuards.RequiresGuard(operation), "résolution et arrêt accessibles : " + operation);
    }
}
