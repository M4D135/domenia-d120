using Domenia.Core;

namespace Domenia.Tests;

internal static class WriteClosingTests
{
    [Test]
    public static async Task Preparing_close_fences_every_new_send_and_cancelling_close_preserves_confirmation()
    {
        var (context, circuit, executor, _) = WriteCircuitTests.FakeCircuit(); using var owned = context;
        var planned = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        var close = await circuit.PrepareCloseAsync(CancellationToken.None);
        Check.True(close.Allowed && !close.ConfirmationRequired, "fermeture sans reçu incertain");
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None), "envoi après contrôle de fermeture refusé");
        Check.Equal("write.closing", error.Code, "refus explicite");
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None), "nouveau plan bloqué");
        Check.Equal(0, executor.Executes, "aucun envoi concurrent à la fermeture");
        circuit.CancelClose();
        await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
        Check.Equal(1, executor.Executes, "annulation de fermeture sans consommation de confirmation");
    }

    [Test]
    public static async Task Active_write_prevents_close_until_the_actual_executor_has_returned()
    {
        var (context, circuit, executor, _) = WriteCircuitTests.FakeCircuit(); using var owned = context;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var release = new ManualResetEventSlim();
        executor.OnExecute = _ =>
        {
            entered.SetResult();
            if (!release.Wait(TimeSpan.FromSeconds(10))) { throw new TimeoutException("Libération du test absente."); }
            return new(WriteResult.Applied, "Envoi terminé.");
        };
        var planned = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        var execution = Task.Run(() => circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None));
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check.False((await circuit.PrepareCloseAsync(CancellationToken.None)).Allowed, "écriture active non interrompue par fermeture");
            Check.True(circuit.InFlight, "l’envoi reste actif");
        }
        finally { release.Set(); }
        await execution;
        Check.True((await circuit.PrepareCloseAsync(CancellationToken.None)).Allowed, "fermeture après reçu final");
    }

    [Test]
    public static async Task Uncertain_receipt_requires_explicit_close_confirmation_without_replaying_or_verifying_it()
    {
        var (context, circuit, executor, _) = WriteCircuitTests.FakeCircuit(); using var owned = context;
        executor.OnExecute = _ => new(WriteResult.Unknown, "Réponse du contrôleur perdue.");
        executor.OnVerify = _ => new(VerificationState.Unknown, "Contrôleur indisponible.");
        var planned = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
        var before = executor.Verifies;
        var close = await circuit.PrepareCloseAsync(CancellationToken.None);
        Check.True(close.Allowed && close.ConfirmationRequired, "choix explicite nécessaire pour fermer");
        Check.Equal(1, close.Pending, "reçu encore incertain");
        Check.Equal(1, executor.Executes, "aucune réexécution");
        Check.Equal(before, executor.Verifies, "aucune relecture réseau implicite à la fermeture");
    }

    [Test]
    public static async Task Unreadable_receipts_require_close_confirmation_and_keep_sends_fenced()
    {
        var (context, circuit, executor, _) = WriteCircuitTests.FakeCircuit(new FailingReceiptStore(int.MaxValue, failReads: true)); using var owned = context;
        var close = await circuit.PrepareCloseAsync(CancellationToken.None);
        Check.True(close.Allowed && close.ConfirmationRequired && close.Unreadable > 0, "état disque illisible annoncé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None), "plan refusé durant choix de fermeture");
        Check.Equal(0, executor.Executes, "aucun envoi");
    }
}
