namespace Domenia.Core;

public sealed record WriteCloseState(bool Allowed, bool ConfirmationRequired, int Pending, int Unreadable, string Detail);

public sealed partial class WriteCircuit
{
    private bool closing;

    /// <summary>Fences new sends before reading receipts. A queued confirmation cannot overtake a successful close check.</summary>
    public async Task<WriteCloseState> PrepareCloseAsync(CancellationToken cancellationToken)
    {
        lock (gate)
        {
            if (InFlight)
            {
                return new(false, false, 0, 0, "Une écriture attend encore son résultat et sa relecture. Attendez son reçu avant de fermer Domenia.");
            }
            closing = true;
        }
        try
        {
            var (all, unreadable) = await ReadAsync(WriteErrors.ReceiptsUnreadableMessage, cancellationToken).ConfigureAwait(false);
            var pending = all.Count(WriteReceipts.IsPending);
            return new(true, pending > 0 || unreadable > 0, pending, unreadable,
                pending > 0 || unreadable > 0
                    ? "Des reçus restent à vérifier ou ne peuvent pas être lus. Fermer ne rejoue ni n’annule les écritures ; vérifiez leurs reçus dans Opérations au prochain démarrage."
                    : "Aucune écriture en cours ni reçu incertain.");
        }
        catch (Exception ex) when (ex is DomeniaOperationException or IOException or UnauthorizedAccessException or OperationCanceledException or ObjectDisposedException)
        {
            log.Warning("État des reçus non confirmé à la fermeture (" + ex.GetType().Name + ").");
            return new(true, true, 0, 1, "L’état des reçus ne peut pas être confirmé. Des écritures peuvent rester à vérifier dans Opérations au prochain démarrage.");
        }
    }

    public void CancelClose()
    {
        lock (gate) { closing = false; }
    }

    private void EnsureOpenLocked()
    {
        if (closing) { throw WriteErrors.Refusal("write.closing", "Fermeture de Domenia en préparation ; aucun nouvel envoi autorisé."); }
    }
}
