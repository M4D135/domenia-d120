namespace Domenia.Core;

public sealed partial class WriteCircuit
{
    /// <summary>Startup inspection of local evidence only. Reserved plans and tokens are never reconstructed.</summary>
    public async Task RecoverAsync(CancellationToken cancellationToken)
    {
        var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(2));
        var token = deadline.Token;
        var inspection = Task.Run(() => ListAsync(token));
        try
        {
            var state = await inspection.WaitAsync(token).ConfigureAwait(false);
            if (state.Pending == 0 && state.Unreadable == 0) return;
            log.Warning($"Reprise locale : {state.Pending} reçu(s) à vérifier, {state.Unreadable} preuve(s) illisible(s). Aucun envoi repris.");
            journal.Add(new(clock.GetUtcNow(), "Reçus à contrôler dans Opérations ; aucune commande reprise au démarrage.", Tone.Warn));
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && deadline.IsCancellationRequested)
        {
            journal.Add(new(clock.GetUtcNow(), "Contrôle local des reçus différé. L’admission relira le journal avant tout envoi.", Tone.Warn));
        }
        catch (DomeniaOperationException ex) when (ex.Code == "receipt.capacity")
        {
            journal.Add(new(clock.GetUtcNow(), "Journal des reçus saturé. " + ex.Message, Tone.Alert));
        }
        catch (DomeniaOperationException ex) when (ex.Code == WriteErrors.ReceiptUnavailable)
        {
            // Keep Opérations accessible; all admissions re-read the same store and stay closed on failure.
            journal.Add(new(clock.GetUtcNow(), "Reçus illisibles au démarrage ; écritures bloquées, ouvrez Opérations.", Tone.Alert));
        }
        finally
        {
            // A slow filesystem may finish after the shell opens. Observe its result and retain its token until then.
            _ = inspection.ContinueWith(t => { _ = t.Exception; deadline.Dispose(); }, CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }
    }
}
