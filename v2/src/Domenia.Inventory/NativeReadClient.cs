using System.IO.Pipes;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>One fixed host/transport/account, one child and one sequential request at a time; no replay or fallback.</summary>
internal sealed class NativeReadClient : IDisposable
{
    private readonly NativeReadHello hello;
    private readonly CancellationToken token;
    private readonly TimeProvider clock;
    private readonly AdaptiveReadBudget adaptive;
    private readonly ITechnicalJournal? journal;
    private readonly Func<IDisposable?>? starting;
    private RemoteProbeCredential? credential;
    private NamedPipeServerStream? pipe;
    private NativeReadProcess? process;
    private AdaptiveReadBudget.Lease? site;
    private readonly bool borrowedAdmission;
    private readonly IDisposable? resource;
    private NativeReadDiagnostics.ExitObservation? childExit;
    private bool closed;
    internal int? ProcessId => process?.Id;
    internal NativeReadClient(NativeReadHello hello, RemoteProbeCredential? credential, CancellationToken token, TimeProvider? clock = null, AdaptiveReadBudget? adaptive = null, ITechnicalJournal? journal = null, Func<IDisposable?>? starting = null)
    {
        NativeIsolationPlan.CheckHello(hello, credential?.Password is not null);
        if (!hello.Session && (credential is not { Session: false } supplied || !string.Equals(hello.Account, supplied.Account, StringComparison.Ordinal)))
        { throw new InvalidDataException("Compte natif non lié à la session demandée."); }
        this.hello = hello; this.token = token; this.clock = clock ?? TimeProvider.System; this.adaptive = adaptive ?? AdaptiveReadBudget.Cim;
        this.journal = journal; this.starting = starting;
        borrowedAdmission = WmiReadWorkers.HasPhysicalAdmission;
        site = WmiReadWorkers.SiteAdmission;
        this.credential = credential is null ? null : new(credential.Account, credential.Password?.Copy(), credential.Session);
        resource = RuntimeResources.Register(RuntimeResourceKind.NativeSession, () => { process?.RequestStop(); return Task.CompletedTask; });
    }

    internal NativeReadReply Read(NativeReadRequest request) => ReadAsync(request).GetAwaiter().GetResult();

    internal async Task<NativeReadReply> ReadAsync(NativeReadRequest request, string workerMode = NativeReadWorkerHost.Argument)
    {
        ObjectDisposedException.ThrowIf(closed, this);
        NativeIsolationPlan.CheckRequest(request); token.ThrowIfCancellationRequested();
        var started = clock.GetTimestamp();
        var queuedAt = started;
        var queueMilliseconds = WmiReadWorkers.TakeQueueMilliseconds();
        long? executingAt = null;
        long? startupMs = null;
        var outcome = ReadPerformanceOutcome.Failure;
        var sent = false;
        var requestWriteCompleted = false;
        var stage = NativeReadStage.Admission;
        CancellationToken requestDeadline = default;
        NativeReadFailureEvidence? failure = null;
        IDisposable? admission = null;
        try
        {
            site?.RequireContinuation();
            if (pipe is null && !borrowedAdmission)
            {
                site = PhysicalWorkBudget.InWriteContext ? null : await adaptive.AcquireAsync(hello.Host, token).ConfigureAwait(false);
                admission = await PhysicalWorkBudget.AcquireAsync(PhysicalWorkRoute.Cim, token).ConfigureAwait(false);
            }
            token.ThrowIfCancellationRequested();
            site?.RequireContinuation();
            if (pipe is null && !borrowedAdmission) { queueMilliseconds += ReadPerformance.Milliseconds(clock.GetElapsedTime(queuedAt)); }
            executingAt = clock.GetTimestamp();
            // Waiting for local capacity is not a native query, and neither is starting the reading process: on the bench
            // workstation a cold start took several seconds and ate the first query's budget, so a WinRM refusal answered
            // in 4 s was cut as « sans réponse » (11/11/2026). Startup has its own bound; the query deadline starts once the
            // child is ready. The child's own query delay answers « Interrompu » for one source; only a child silent past
            // that margin is stopped.
            if (pipe is null)
            {
                using var startup = new CancellationTokenSource(CimBudgets.WorkerStartup, clock);
                // Neither progress nor silence of the workstation: the owner's idle ceiling is paused up to the handshake.
                using var pausedIdle = starting?.Invoke();
                requestDeadline = startup.Token;
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token, startup.Token);
                stage = NativeReadStage.WorkerStart;
                var startupAt = clock.GetTimestamp();
                var name = "Domenia.NativeRead." + Guid.NewGuid().ToString("N");
                pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly, 16_384, 16_384);
                var reserved = admission;
                admission = null; // Start now owns admission, including launch failure and confirmed OS exit.
                process = NativeReadProcess.Start(name, workerMode, reserved);
                // While the child starts: the reply of the first request is then read without building serializer metadata.
                NativeReadProtocol.Prime();
                stage = NativeReadStage.PipeConnect;
                await pipe.WaitForConnectionAsync(deadline.Token).ConfigureAwait(false);
                stage = NativeReadStage.Handshake;
                NativeReadProcess.VerifyClient(pipe, process.Id);
                await NativeReadProtocol.WriteAsync(pipe, hello, NativeReadProtocol.RequestLimit, deadline.Token).ConfigureAwait(false);
                await NativeReadProtocol.WritePasswordAsync(pipe, credential?.Password, deadline.Token).ConfigureAwait(false);
                if (!await NativeReadProtocol.ReadAsync<bool>(pipe, 32, deadline.Token).ConfigureAwait(false)) { throw new InvalidDataException("Processus natif non prêt."); }
                startupMs = ReadPerformance.Milliseconds(clock.GetElapsedTime(startupAt));
                var ready = FormattableString.Invariant($"Processus de lecture natif prêt en {startupMs} ms (transport {hello.Transport}, préparation comprise).");
                if (startupMs > 2000) { journal?.Info(ready); } else { journal?.Trace(ready); }
            }
            NativeReadReply response;
            using (var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(request.BudgetMs) + CimBudgets.GiveUpMargin, clock))
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(token, timeout.Token))
            {
                requestDeadline = timeout.Token;
                sent = true; started = clock.GetTimestamp();
                stage = NativeReadStage.RequestWrite;
                await NativeReadProtocol.WriteAsync(pipe, request, NativeReadProtocol.RequestLimit, deadline.Token).ConfigureAwait(false);
                requestWriteCompleted = true;
                stage = NativeReadStage.ResponseRead;
                response = await NativeReadProtocol.ReadAsync<NativeReadReply>(pipe, NativeReadProtocol.ResponseLimit, deadline.Token).ConfigureAwait(false);
            }
            stage = NativeReadStage.ResponseValidate;
            if (response.Failed) { throw new InvalidDataException("Lecture native non aboutie."); }
            var status = response.Reading?.Status ?? response.Registry?.Status ?? response.User?.Access.Status;
            outcome = response.Trial is { } measuredTrial
                ? measuredTrial.Outcome switch { "Observed" => ReadPerformanceOutcome.Success, "AuthRejected" or "Denied" => ReadPerformanceOutcome.Refused, _ => ReadPerformanceOutcome.Failure }
                : PerformanceOutcome(status);
            site?.Report(token.IsCancellationRequested ? AdaptiveReadOutcome.Cancelled : response.Trial is { } trial
                ? TrialOutcome(trial) : AdaptiveReadBudget.Classify(status), clock.GetElapsedTime(started));
            return response;
        }
        catch (OperationCanceledException ex) when (!token.IsCancellationRequested)
        {
            failure = NativeReadFailureEvidence.Capture(hello.Transport, request, stage, queuedAt, executingAt,
                clock, token, requestDeadline, requestWriteCompleted, ex);
            if (sent) site?.Report(AdaptiveReadOutcome.Timeout, clock.GetElapsedTime(started));
            Dispose();
            throw new TimeoutException("Budget de lecture native atteint ; sortie du processus confirmée après fermeture.");
        }
        catch (Exception ex)
        {
            failure = NativeReadFailureEvidence.Capture(hello.Transport, request, stage, queuedAt, executingAt,
                clock, token, requestDeadline, requestWriteCompleted, ex);
            outcome = token.IsCancellationRequested ? ReadPerformanceOutcome.Cancelled : ReadPerformanceOutcome.Failure;
            if (sent && !token.IsCancellationRequested) site?.Report(false, clock.GetElapsedTime(started));
            Dispose();
            throw;
        }
        finally
        {
            admission?.Dispose();
            // Facts were captured before cleanup; publish only after the child and admission have been released.
            if (failure is { } observed)
            {
                journal?.Warning(observed.Format() + " " + (childExit?.Format()
                    ?? "childPhase=absent; childType=absent; childHresult=absent; childWin32=absent; childExitCode=absent; parentTerminationRequested=absent."));
            }
            if (executingAt is { } measuredAt)
                ReadPerformance.Publish(new(PerformanceMethod(request), request.Kind.ToString(), queueMilliseconds,
                    ReadPerformance.Milliseconds(clock.GetElapsedTime(measuredAt)), outcome) { StartupMs = startupMs });
        }
    }

    private ReadPerformanceMethod PerformanceMethod(NativeReadRequest request) => request.Kind switch
    {
        NativeReadKind.Registry or NativeReadKind.RegistryUser => ReadPerformanceMethod.Registry,
        NativeReadKind.Events => ReadPerformanceMethod.SecurityLog,
        NativeReadKind.Appx or NativeReadKind.Inventory or NativeReadKind.WinRmUser => ReadPerformanceMethod.WinRm,
        NativeReadKind.LocalAdmins => ReadPerformanceMethod.WindowsRpc,
        NativeReadKind.Diagnostic => request.Diagnostic switch
        {
            DiagnosticTransport.WinRm => ReadPerformanceMethod.WinRm,
            DiagnosticTransport.TaskScheduler => ReadPerformanceMethod.ScheduledTask,
            _ => ReadPerformanceMethod.WindowsRpc,
        },
        _ => hello.Transport == InventoryTransport.WinRm ? ReadPerformanceMethod.WinRm : ReadPerformanceMethod.WmiDcom,
    };

    internal static ReadPerformanceOutcome PerformanceOutcome(SourceStatus? status) => status switch
    {
        SourceStatus.Ok or SourceStatus.Empty => ReadPerformanceOutcome.Success,
        SourceStatus.Partial => ReadPerformanceOutcome.Partial,
        SourceStatus.Refused => ReadPerformanceOutcome.Refused,
        SourceStatus.Interrupted => ReadPerformanceOutcome.Cancelled,
        _ => ReadPerformanceOutcome.Failure,
    };

    internal static AdaptiveReadOutcome TrialOutcome(NativeTrialReading trial) => trial.Category is "Disabled" or "CredentialsRejected" or "CredentialMissing" or "AccountState" or "AccessDenied" or "Target" or "Network"
        ? AdaptiveReadOutcome.Neutral : trial.Outcome switch
        {
            "Observed" => AdaptiveReadOutcome.Success,
            "AuthRejected" or "Denied" or "Unreachable" => AdaptiveReadOutcome.Neutral,
            "Timeout" => AdaptiveReadOutcome.Timeout,
            _ => AdaptiveReadOutcome.Failure,
        };

    public void Dispose()
    {
        if (closed) { return; }
        // Keep both the secret and the physical slot until exit was observed, even when the reply pipe failed.
        process?.Stop();
        if (process?.ExitObservation is { } observedExit) { childExit = observedExit; }
        try { pipe?.Dispose(); }
        finally
        {
            pipe = null;
            try { credential?.Dispose(); }
            finally { credential = null; process?.Dispose(); process = null; if (!borrowedAdmission) site?.Dispose(); site = null; closed = true; resource?.Dispose(); }
        }
    }
}
