using System.ComponentModel;
using System.Runtime.InteropServices;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class RemoteTaskReadRunner
{
    /// <summary>Explicit cleanup of a durable operation; never registers, starts or repeats its read.</summary>
    public async Task<RemoteTaskCleanupResult> RecoverCleanupAsync(RemoteTaskReadPlan plan, IRemoteTaskReadJournal journal,
        RemoteProbeCredential? credential, Func<CancellationToken, Task<bool>> authorizeCleanup, CancellationToken cancellationToken)
    {
        RemoteTaskReadRules.Validate(plan, clock.GetUtcNow());
        ArgumentNullException.ThrowIfNull(journal); ArgumentNullException.ThrowIfNull(authorizeCleanup);
        if (RemoteTaskReadProgram.Hash(RemoteTaskReadProgram.Script(plan)) != plan.ScriptSha256)
        { throw new InvalidDataException("Programme de lecture différent ; aucun nettoyage distant."); }
        if (credential is { Session: false } && (credential.Password is null || !CredentialRules.IsWellFormed(credential.Account)))
        { throw new DomeniaOperationException(MachineErrors.PasswordMissing, "Compte de nettoyage incomplet ; aucun contact."); }
        cancellationToken.ThrowIfCancellationRequested();
        Admit(plan.Host);
        RemoteProbeCredential? owned = null; CancellationTokenSource? timeout = null; CancellationTokenSource? stop = null;
        Task<RemoteTaskCleanupResult> work;
        try
        {
            owned = credential is null ? null : new(credential.Account, credential.Password?.Copy(), credential.Session);
            timeout = new(Budget, clock); stop = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token, cancellationToken);
            var copy = owned; var deadline = timeout; var stopping = stop;
            work = Task.Run(() =>
            {
                try
                {
                    using (copy) using (SecureCredentialCopies.Track(copy?.Password))
                    { return Recover(plan, journal, copy, authorizeCleanup, stopping.Token); }
                }
                finally { stopping.Dispose(); deadline.Dispose(); Hosts.TryRemove(plan.Host, out _); Slots.Release(); }
            }, CancellationToken.None);
        }
        catch { owned?.Dispose(); stop?.Dispose(); timeout?.Dispose(); Hosts.TryRemove(plan.Host, out _); Slots.Release(); throw; }
        try { return await work.WaitAsync(Budget + TimeSpan.FromSeconds(5), clock, cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is OperationCanceledException or TimeoutException)
        {
            _ = work.ContinueWith(t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return new(plan.Id, false, false, true, "Attente arrêtée ; le nettoyage reste suivi par son worker et son reçu local. Aucune lecture relancée.");
        }
    }

    private RemoteTaskCleanupResult Recover(RemoteTaskReadPlan plan, IRemoteTaskReadJournal journal, RemoteProbeCredential? credential,
        Func<CancellationToken, Task<bool>> authorizeCleanup, CancellationToken token)
    {
        RemoteTaskReadRecord? record = null;
        var cleanup = new RemoteTaskReadCleanup(false, false, "Nettoyage non entrepris.");
        try
        {
            record = journal.ReadTaskReadAsync(plan.Id, token).GetAwaiter().GetResult()
                ?? throw new InvalidDataException("Opération absente du journal local ; aucun nettoyage distant.");
            if (record.Plan != plan) { throw new InvalidDataException("Identité de l’opération modifiée ; aucun nettoyage distant."); }
            if (!record.CleanupRequired) { return new(plan.Id, true, true, false, record.Completion!.Detail); }
            if (!authorizeCleanup(token).GetAwaiter().GetResult())
            { throw new DomeniaOperationException("poste.cleanup.consent", "Nettoyage non confirmé pour ce poste et cette opération."); }
            token.ThrowIfCancellationRequested();
            if (record.Completion is null)
            {
                // Winning this CAS also prevents a worker from claiming the prepared read later.
                var cancelled = journal.CompleteTaskReadAsync(plan.Id, record.Revision,
                    new(clock.GetUtcNow(), false, true, true, "Préparation annulée avant revendication ; aucun artefact créé.") { ExecutionId = Guid.NewGuid() }, token).GetAwaiter().GetResult();
                return new(plan.Id, true, true, false, cancelled.Completion!.Detail);
            }
            var received = record.Completion.ResultReceived;
            var executionId = record.Completion.ExecutionId;
            void Save(bool stopped, bool removed, string detail)
            {
                using var save = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                record = journal.CompleteTaskReadAsync(plan.Id, record.Revision,
                    new(clock.GetUtcNow(), received, stopped, removed, detail) { ExecutionId = executionId }, save.Token).GetAwaiter().GetResult();
            }
            using var backend = BackendOverride?.Invoke(plan, credential) ?? new RemoteTaskReadBackend(plan, credential);
            backend.PrepareCleanup(record.Completion, token);
            token.ThrowIfCancellationRequested();
            cleanup = backend.Cleanup(() => Save(true, false, "Arrêt confirmé et enregistré ; nettoyage des artefacts à terminer."));
            Save(cleanup.Stopped || record.Completion!.ExecutionStopped, cleanup.Removed, cleanup.Detail);
            return new(plan.Id, record.Completion!.ExecutionStopped, record.Completion.ArtifactsRemoved, false, record.Completion.Detail);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Win32Exception or COMException or DomeniaOperationException or OperationCanceledException)
        {
            var detail = ex is InvalidDataException or DomeniaOperationException ? PosteText.Flat(ex.Message, 512)
                : ex is OperationCanceledException ? "Nettoyage interrompu ; état non confirmé conservé dans le journal."
                : "Nettoyage non confirmé (code 0x" + ex.HResult.ToString("X8") + ") ; aucun nouvel envoi automatique.";
            return new(plan.Id, record?.Completion?.ExecutionStopped == true || cleanup.Stopped, false, false, detail);
        }
    }
}
