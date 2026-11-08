using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed record RemoteTaskReadResult(Guid OperationId, WorkstationUserReading Reading, bool CleanupConfirmed, bool WorkerPending, string Notice)
{
    public InventorySnapshot? Inventory { get; init; }
    public WorkstationSoftwareReading? Software { get; init; }
}

/// <summary>A prepared, one-use read with its own worker/credential lifetime, durable claim, and unconditional scoped cleanup.</summary>
public sealed partial class RemoteTaskReadRunner(TimeProvider clock)
{
    private static readonly SemaphoreSlim Slots = new(2, 2);
    private static readonly ConcurrentDictionary<string, byte> Hosts = new(StringComparer.OrdinalIgnoreCase);
    internal Func<RemoteTaskReadPlan, RemoteProbeCredential?, IRemoteTaskReadBackend>? BackendOverride { get; init; }
    internal static readonly TimeSpan Budget = TimeSpan.FromSeconds(35);

    public static RemoteTaskReadPlan PreparePlan(DirectoryComputer computer, string storeId, string account, DateTimeOffset now,
        RemoteTaskReadKind kind = RemoteTaskReadKind.UserIdentity, SoftwareRequest? software = null)
        => RemoteTaskReadProgram.Plan(computer, storeId, account, now, kind, software);

    public async Task<RemoteTaskReadResult> RunAsync(RemoteTaskReadPlan plan, IRemoteTaskReadJournal journal, RemoteProbeCredential? credential,
        Func<CancellationToken, Task<bool>> authorizeArtifacts, CancellationToken cancellationToken)
    {
        RemoteTaskReadRules.Validate(plan, clock.GetUtcNow());
        if (plan.Transport == RemoteReadTransport.PsExec) { RemotePsExecPlan.Validate(plan, credential); }
        ArgumentNullException.ThrowIfNull(journal); ArgumentNullException.ThrowIfNull(authorizeArtifacts);
        if (RemoteTaskReadProgram.Hash(RemoteTaskReadProgram.Script(plan)) != plan.ScriptSha256)
        { throw new InvalidDataException("Empreinte du programme différente ; aucun contact."); }
        if (credential is { Session: false } && (credential.Password is null || !CredentialRules.IsWellFormed(credential.Account)))
        { throw new DomeniaOperationException(MachineErrors.PasswordMissing, "Compte de lecture incomplet ; aucun contact."); }
        cancellationToken.ThrowIfCancellationRequested();
        Admit(plan.Host);
        IDisposable physical;
        try { physical = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Network); }
        catch { Hosts.TryRemove(plan.Host, out _); Slots.Release(); throw; }
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
                finally { stopping.Dispose(); deadline.Dispose(); Hosts.TryRemove(plan.Host, out _); Slots.Release(); physical.Dispose(); }
            }, CancellationToken.None);
        }
        catch { owned?.Dispose(); stop?.Dispose(); timeout?.Dispose(); Hosts.TryRemove(plan.Host, out _); Slots.Release(); physical.Dispose(); throw; }
        try { return await work.WaitAsync(Budget + TimeSpan.FromSeconds(5), clock, cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is OperationCanceledException or TimeoutException)
        {
            // The worker owns the token sources, credential and host slot until native calls and cleanup really finish.
            _ = work.ContinueWith(t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return new(plan.Id, TransportReading(plan, Empty(SourceStatus.Interrupted, "Attente arrêtée ; le worker termine son nettoyage avec le compte d’origine.")), false, true,
                "Le résultat et le nettoyage ne sont pas confirmés ici. Le journal local garde l’opération " + plan.Id.ToString("N") + ".");
        }
    }

    private RemoteTaskReadResult Run(RemoteTaskReadPlan plan, IRemoteTaskReadJournal journal, RemoteProbeCredential? credential,
        Func<CancellationToken, Task<bool>> authorizeArtifacts, CancellationToken token)
    {
        RemoteTaskReadRecord? record = null; IRemoteTaskReadBackend? backend = null;
        var claimed = false; var cleanup = new RemoteTaskReadCleanup(true, true, "Aucun artefact tenté.");
        InventorySnapshot? inventory = null; WorkstationSoftwareReading? software = null;
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
            backend = CreateBackend(plan, credential);
            backend.Preflight(token);
            // The callback consumes the one-use read authorization exactly once, after preflight and before any artefact.
            var authorization = authorizeArtifacts(token).GetAwaiter().GetResult();
            var decision = TransportPolicy.FallbackAllowed(plan.Transport.ToString(), intrusive: true, consentGiven: false, isRead: true, readConsentGiven: authorization);
            if (!decision.Allowed)
            {
                // Le refus porte d’abord sur l’autorisation de lecture : la nommer, sinon l’opérateur ne voit que
                // le transport et ne sait pas qu’il manque une autorisation pour cette lecture seule.
                var cause = authorization ? decision.Reason : "Autorisation de lecture absente ; " + decision.Reason;
                throw new DomeniaOperationException("poste.fallback.consent", cause + " Aucun artefact créé.");
            }
            token.ThrowIfCancellationRequested(); backend.Start(token);
            while (true)
            {
                token.ThrowIfCancellationRequested();
                var json = backend.ReadResult();
                if (json is not null) { var parsed = RemoteTaskReadProgram.ParseResult(json, plan, clock.GetUtcNow()); reading = parsed.Reading; inventory = parsed.Inventory; software = parsed.Software; received = true; break; }
                if (backend.Finished)
                {
                    // The atomic rename may have completed immediately before the state read.
                    json = backend.ReadResult();
                    if (json is not null) { var parsed = RemoteTaskReadProgram.ParseResult(json, plan, clock.GetUtcNow()); reading = parsed.Reading; inventory = parsed.Inventory; software = parsed.Software; received = true; }
                    else { reading = Empty(SourceStatus.Error, "Tâche terminée sans résultat lié à cette lecture."); }
                    break;
                }
                token.WaitHandle.WaitOne(150);
            }
        }
        catch (OperationCanceledException) { reading = Empty(SourceStatus.Interrupted, "Arrêt ou budget de lecture atteint ; nettoyage demandé."); }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or Win32Exception or COMException or JsonException or DecoderFallbackException or DomeniaOperationException or System.Management.ManagementException or System.Xml.XmlException or TimeoutException)
        {
            var code = ex is Win32Exception native ? native.NativeErrorCode : ex.HResult;
            var rejected = WindowsAuthenticationErrors.IsRejected(code);
            var refused = rejected || ex is UnauthorizedAccessException || code is 5 or 1314 or unchecked((int)0x80070005);
            reading = Empty(refused ? SourceStatus.Refused : ex is TimeoutException ? SourceStatus.Interrupted : SourceStatus.Error, ex is DomeniaOperationException or InvalidDataException
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
                catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or Win32Exception or COMException or OperationCanceledException)
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
                catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or OperationCanceledException)
                { notice = "Reçu final non enregistré ; l’opération reste en attente dans la base (code 0x" + ex.HResult.ToString("X8") + ")."; }
            }
        }
        ReadPerformance.Publish(new(plan.Transport switch { RemoteReadTransport.PsExec => ReadPerformanceMethod.PsExec,
            RemoteReadTransport.WmiProcess => ReadPerformanceMethod.WmiProcess, RemoteReadTransport.WinRmScript => ReadPerformanceMethod.WinRmScript,
            _ => ReadPerformanceMethod.ScheduledTask },
            "TransientRead", 0, ReadPerformance.Milliseconds(elapsed.Elapsed), NativeReadClient.PerformanceOutcome(reading.Access.Status)));
        var clean = claimed && cleanup.Stopped && cleanup.Removed && notice.Length == 0;
        var detail = reading.Access.Detail + " " + cleanup.Detail;
        return new(plan.Id, TransportReading(plan, reading with { Access = reading.Access with { Detail = detail, DurationMs = (int)Math.Min(elapsed.ElapsedMilliseconds, int.MaxValue) } }), clean, false, notice)
        { Inventory = TransportInventory(plan, inventory is null ? null : inventory with { DurationMs = (int)Math.Min(elapsed.ElapsedMilliseconds, int.MaxValue) }), Software = TransportSoftware(plan, software) };
    }

    private static WorkstationUserReading Empty(SourceStatus status, string detail) => new(null, new("TaskFallback", status, detail, 0, 0, InventoryTransport.ScheduledTask), []);
    private static DomeniaOperationException Busy() => new("machine.busy", "Une lecture par tâche se termine encore ; aucun nouveau travail mis en attente.");
}
