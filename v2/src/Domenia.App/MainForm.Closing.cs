using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.App;

internal sealed partial class MainForm
{
    private readonly WriteCircuit closingWrites;
    private readonly IPosteTaskReadJournalReader? closingTaskJournal;
    private IDisposable? closingTasks;
    private bool closingChecked;
    private bool checkingClose;

    private async void CheckClosing(object? sender, FormClosingEventArgs e)
    {
        if (closingChecked) { return; }
        e.Cancel = true;
        if (checkingClose) { return; }
        checkingClose = true;
        try
        {
            if (mode == AppMode.Directory) { closingTasks ??= RemoteTaskReadRunner.SuspendNewReads(); }
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            var decision = await Task.Run(() => closingWrites.PrepareCloseAsync(limit.Token)).ConfigureAwait(true);
            if (!decision.Allowed)
            {
                CancelCloseChecks();
                TechnicalLog.Warning("Fermeture différée : écriture en cours.");
                if (capture is null && e2e is null)
                { MessageBox.Show(this, decision.Detail, "Écriture en cours", MessageBoxButtons.OK, MessageBoxIcon.Information); }
                return;
            }
            var taskWarning = mode == AppMode.Directory ? await CheckRemoteTasksAsync(limit.Token).ConfigureAwait(true) : null;
            if (decision.ConfirmationRequired || taskWarning is not null)
            {
                var detail = (decision.ConfirmationRequired ? decision.Detail : "") + (taskWarning is null ? "" : "\n\n" + taskWarning);
                TechnicalLog.Warning(detail.Trim());
                if (capture is not null || e2e is not null)
                {
                    // Simulation scenarios deliberately exercise uncertain receipts in memory. Native uncertainty remains a failure.
                    if (mode == AppMode.Directory) { Environment.ExitCode = 2; }
                }
                else if (MessageBox.Show(this, detail.Trim() + "\n\nFermer Domenia malgré cette incertitude ?", "Reçus à vérifier",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
                { CancelCloseChecks(); return; }
            }
            closingChecked = true;
            Close();
        }
        finally { checkingClose = false; }
    }

    private void CancelCloseChecks()
    {
        closingWrites.CancelClose();
        closingTasks?.Dispose(); closingTasks = null;
    }

    private async Task<string?> CheckRemoteTasksAsync(CancellationToken token)
    {
        try
        {
            if (closingTaskJournal is null) { throw new InvalidDataException("Journal des tâches distantes indisponible."); }
            var pending = await Task.Run(() => closingTaskJournal.PendingTaskReadCountAsync(token), token).ConfigureAwait(false);
            return pending == 0 && RemoteTaskReadRunner.ActiveReads == 0 ? null
                : "Des lectures par tâche distante sont encore actives ou attendent leur nettoyage. Fermer peut laisser des artefacts sur les postes ; consultez leurs opérations de nettoyage dans Poste au prochain démarrage.";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or OperationCanceledException or DomeniaOperationException or ObjectDisposedException)
        {
            TechnicalLog.Warning("Nettoyage des tâches distantes non confirmé à la fermeture (" + ex.GetType().Name + ").");
            return "L’état du nettoyage des tâches distantes ne peut pas être relu. Des artefacts peuvent rester sur les postes ; leur absence n’est pas confirmée.";
        }
    }
}
