using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed record RemoteTaskReadResult(Guid OperationId, WorkstationUserReading Reading, bool CleanupConfirmed, bool WorkerPending, string Notice);

/// <summary>A prepared, one-use read with its own worker/credential lifetime, durable claim, and unconditional scoped cleanup.</summary>
public sealed partial class RemoteTaskReadRunner(TimeProvider clock)
{
    private static readonly SemaphoreSlim Slots = new(2, 2);
    private static readonly ConcurrentDictionary<string, byte> Hosts = new(StringComparer.OrdinalIgnoreCase);
    internal Func<RemoteTaskReadPlan, RemoteProbeCredential?, IRemoteTaskReadBackend>? BackendOverride { get; init; }
    internal static readonly TimeSpan Budget = TimeSpan.FromSeconds(35);

    public static RemoteTaskReadPlan PreparePlan(DirectoryComputer computer, string storeId, string account, DateTimeOffset now)
        => RemoteTaskReadProgram.Plan(computer, storeId, account, now);

    public async Task<RemoteTaskReadResult> RunAsync(RemoteTaskReadPlan plan, IRemoteTaskReadJournal journal, RemoteProbeCredential? credential,
        Func<CancellationToken, Task<bool>> authorizeArtifacts, CancellationToken cancellationToken)
    {
        RemoteTaskReadRules.Validate(plan, clock.GetUtcNow());
        ArgumentNullException.ThrowIfNull(journal); ArgumentNullException.ThrowIfNull(authorizeArtifacts);
        if (RemoteTaskReadProgram.Hash(RemoteTaskReadProgram.Script(plan)) != plan.ScriptSha256)
        { throw new InvalidDataException("Empreinte du programme différente ; aucun contact."); }
        if (credential is { Session: false } && (credential.Password is null || !CredentialRules.IsWellFormed(credential.Account)))
        { throw new DomeniaOperationException(MachineErrors.PasswordMissing, "Compte de lecture incomplet ; aucun contact."); }
        cancellationToken.ThrowIfCancellationRequested();
        if (!Hosts.TryAdd(plan.Host, 0)) { throw Busy(); }
        if (!Slots.Wait(0)) { Hosts.TryRemove(plan.Host, out _); throw Busy(); }
        RemoteProbeCredential? owned = null; CancellationTokenSource? timeout = null; CancellationTokenSource? stop = null;
        Task<RemoteTaskReadResult> work;
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
                    { return Run(plan, journal, copy, authorizeArtifacts, stopping.Token); }
                }
                finally { stopping.Dispose(); deadline.Dispose(); Hosts.TryRemove(plan.Host, out _); Slots.Release(); }
            }, CancellationToken.None);
        }
        catch { owned?.Dispose(); stop?.Dispose(); timeout?.Dispose(); Hosts.TryRemove(plan.Host, out _); Slots.Release(); throw; }
        try { return await work.WaitAsync(Budget + TimeSpan.FromSeconds(5), clock, cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is OperationCanceledException or TimeoutException)
        {
            // The worker owns the token sources, credential and host slot until native calls and cleanup really finish.
            _ = work.ContinueWith(t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return new(plan.Id, Empty(SourceStatus.Interrupted, "Attente arrêtée ; le worker termine son nettoyage avec le compte d’origine."), false, true,
                "Le résultat et le nettoyage ne sont pas confirmés ici. Le journal local garde l’opération " + plan.Id.ToString("N") + ".");
        }
    }

    private RemoteTaskReadResult Run(RemoteTaskReadPlan plan, IRemoteTaskReadJournal journal, RemoteProbeCredential? credential,
        Func<CancellationToken, Task<bool>> authorizeArtifacts, CancellationToken token)
    {
        RemoteTaskReadRecord? record = null; IRemoteTaskReadBackend? backend = null;
        var claimed = false; var cleanup = new RemoteTaskReadCleanup(true, true, "Aucun artefact tenté.");
        var reading = Empty(SourceStatus.Error, "Lecture non aboutie."); var notice = ""; var received = false;
        var elapsed = Stopwatch.StartNew(); var executionId = Guid.NewGuid();
        try
        {
            token.ThrowIfCancellationRequested();
            record = journal.PrepareTaskReadAsync(plan, token).GetAwaiter().GetResult();
            if (record.Revision != 1 || record.Completion is not null) { throw new InvalidDataException("Cette opération a déjà été engagée ; aucun second lancement."); }
            // A distinct claimant loses the CAS, even if its machine and account are identical.
            record = journal.CompleteTaskReadAsync(plan.Id, 1,
                new(clock.GetUtcNow(), false, false, false, "Lecture engagée ; aucune issue déduite avant le reçu final.") { ExecutionId = executionId }, token).GetAwaiter().GetResult();
            claimed = true;
            backend = BackendOverride?.Invoke(plan, credential) ?? new RemoteTaskReadBackend(plan, credential);
            backend.Preflight(token);
            if (!authorizeArtifacts(token).GetAwaiter().GetResult()) { throw new DomeniaOperationException("poste.fallback.consent", "Autorisation ponctuelle absente ou expirée ; aucun artefact créé."); }
            token.ThrowIfCancellationRequested(); backend.Start(token);
            while (true)
            {
                token.ThrowIfCancellationRequested();
                var json = backend.ReadResult();
                if (json is not null) { reading = RemoteTaskReadProgram.Parse(json, plan, clock.GetUtcNow()); received = true; break; }
                if (backend.Finished)
                {
                    // The atomic rename may have completed immediately before the state read.
                    json = backend.ReadResult();
                    if (json is not null) { reading = RemoteTaskReadProgram.Parse(json, plan, clock.GetUtcNow()); received = true; }
                    else { reading = Empty(SourceStatus.Error, "Tâche terminée sans résultat lié à cette lecture."); }
                    break;
                }
                token.WaitHandle.WaitOne(150);
            }
        }
        catch (OperationCanceledException) { reading = Empty(SourceStatus.Interrupted, "Arrêt ou budget de lecture atteint ; nettoyage demandé."); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Win32Exception or COMException or JsonException or DecoderFallbackException or DomeniaOperationException)
        {
            var code = ex is Win32Exception native ? native.NativeErrorCode : ex.HResult;
            var rejected = WindowsAuthenticationErrors.IsRejected(code);
            var refused = rejected || ex is UnauthorizedAccessException || code is 5 or 1314 or unchecked((int)0x80070005);
            reading = Empty(refused ? SourceStatus.Refused : SourceStatus.Error, ex is DomeniaOperationException or InvalidDataException
                ? PosteText.Flat(ex.Message, 512) : "Lecture distante non aboutie (code 0x" + code.ToString("X8") + ").");
            reading = reading with { Access = reading.Access with { AuthenticationRejected = rejected } };
        }
        finally
        {
            if (backend is not null)
            {
                try
                {
                    cleanup = backend.Cleanup(() =>
                    {
                        if (!claimed || record is null) { throw new InvalidDataException("Arrêt sans revendication durable ; artefacts conservés."); }
                        using var checkpoint = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                        record = journal.CompleteTaskReadAsync(plan.Id, record.Revision,
                            new(clock.GetUtcNow(), received, true, false, "Arrêt confirmé ; suppression des artefacts encore à vérifier.") { ExecutionId = executionId }, checkpoint.Token).GetAwaiter().GetResult();
                    });
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Win32Exception or COMException or OperationCanceledException)
                { cleanup = new(false, false, "Nettoyage indisponible (code 0x" + ex.HResult.ToString("X8") + ")."); }
                finally { backend.Dispose(); }
            }
            if (claimed && record is not null)
            {
                using var save = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                try
                {
                    journal.CompleteTaskReadAsync(plan.Id, record.Revision,
                        new(clock.GetUtcNow(), received, cleanup.Stopped, cleanup.Removed, cleanup.Detail) { ExecutionId = executionId }, save.Token).GetAwaiter().GetResult();
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or OperationCanceledException)
                { notice = "Reçu final non enregistré ; l’opération reste en attente dans la base (code 0x" + ex.HResult.ToString("X8") + ")."; }
            }
        }
        var clean = claimed && cleanup.Stopped && cleanup.Removed && notice.Length == 0;
        var detail = reading.Access.Detail + " " + cleanup.Detail;
        if (!clean && reading.Access.Status is SourceStatus.Ok or SourceStatus.Empty) { reading = reading with { Access = reading.Access with { Status = SourceStatus.Partial } }; }
        return new(plan.Id, reading with { Access = reading.Access with { Detail = detail, DurationMs = (int)Math.Min(elapsed.ElapsedMilliseconds, int.MaxValue) } }, clean, false, notice);
    }

    private static WorkstationUserReading Empty(SourceStatus status, string detail) => new(null, new("TaskFallback", status, detail, 0, 0, InventoryTransport.ScheduledTask), []);
    private static DomeniaOperationException Busy() => new("machine.busy", "Une lecture par tâche se termine encore ; aucun nouveau travail mis en attente.");
}
