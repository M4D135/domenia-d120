using Domenia.Bridge;
using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.App;

internal sealed partial class MainForm
{
    private volatile bool transitionFenced;
    private bool transitionDispatcherWithdrawn;

    private BridgeDispatcher CreateDispatcher()
    {
        var result = new BridgeDispatcher(composition.Registry, PostToPage, definition => transitionFenced
            ? new BridgeError("session.suspended", "Contexte suspendu pour une transition ; aucune nouvelle opération lancée.")
            : composition.Admission(definition));
        result.ReportIncident = composition.ReportIncident;
        result.Refused += (code, operation) => TechnicalLog.Warning($"Message de l’interface refusé : {code}" + (operation is null ? "." : $" ({operation})."));
        return result;
    }

    /// <summary>UI thread, after the control request has returned. An active write is never cancelled or hidden.</summary>
    private async Task<bool> PrepareTransitionAsync(CancellationToken token)
    {
        if (transitionFenced || checkingClose || IsDisposed) return false;
        transitionFenced = true;
        webView.Enabled = false;
        PublishWindowActivity(force: true);
        try
        {
            if (mode == AppMode.Directory) closingTasks ??= RemoteTaskReadRunner.SuspendNewReads();
            var decision = await Task.Run(() => closingWrites.PrepareCloseAsync(token), token).ConfigureAwait(true);
            if (!decision.Allowed || mode == AppMode.Directory && decision.ConfirmationRequired)
                throw new DomeniaOperationException("session.busy", decision.Detail);
            dispatcher.Dispose(); // only after the write circuit accepted the fence; writes retain their original token
            transitionDispatcherWithdrawn = true;
            await Settings.HostWindow.SuspendAsync(token).ConfigureAwait(true);
            foreach (var row in composition.Activity.Snapshot().Open.Where(row => row.CanStop && !row.Operation.StartsWith("settings.demo.", StringComparison.Ordinal)))
            {
                try { composition.Activity.Stop(row.Id); }
                catch (DomeniaOperationException ex) when (ex.Code == OperationActivity.TaskUnknown) { }
            }
            // Includes local saves and providers still completing after their UI request was cancelled.
            // The control operation only scheduled this method, so its own task can finish independently.
            var pending = inFlight.Values.ToArray();
            if (pending.Length > 0) await Task.WhenAll(pending).WaitAsync(TimeSpan.FromSeconds(15), token).ConfigureAwait(true);
            if (composition.Activity.Snapshot().Open.Length != 0) throw new DomeniaOperationException("session.busy", "Une opération n’a pas encore terminé ; le contexte reste ouvert.");
            if (PhysicalWorkBudget.Snapshot().Outstanding != 0) throw new DomeniaOperationException("session.busy", "Un fournisseur termine encore son travail physique ; le contexte reste ouvert.");
            if (mode == AppMode.Directory && await CheckRemoteTasksAsync(token).ConfigureAwait(true) is { } warning)
                throw new DomeniaOperationException("session.busy", warning);
            await composition.SuspendSensitiveWindowsAsync(token).ConfigureAwait(true);
            token.ThrowIfCancellationRequested();
            return true;
        }
#pragma warning disable CA1031 // Any preparation failure must restore the previous context; the error remains in the local log.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            if (ex is not (DomeniaOperationException or IOException or UnauthorizedAccessException or OperationCanceledException or TimeoutException))
                TechnicalLog.Error("Préparation de transition interrompue.", ex);
            ResumeTransition();
            if (!IsDisposed) MessageBox.Show(this, ex is DomeniaOperationException ? ex.Message : "Les opérations n’ont pas toutes terminé. Le contexte précédent reste ouvert ; réessayez après leur fin.",
                "Transition différée", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return false;
        }
    }

    private void ResumeTransition()
    {
        if (!transitionFenced) return;
        CancelCloseChecks();
        Settings.HostWindow.Resume();
        if (transitionDispatcherWithdrawn) { dispatcher = CreateDispatcher(); transitionDispatcherWithdrawn = false; }
        transitionFenced = false;
        if (!IsDisposed) { webView.Enabled = true; PublishWindowActivity(force: true); }
    }
}
