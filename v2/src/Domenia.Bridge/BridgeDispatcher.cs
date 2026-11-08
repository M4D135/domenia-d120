using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Validates every message coming from the page and runs the matching declared operation. The optional admission guard is
/// evaluated before the handler (simulation: Write refused, NetworkRead refused unless served by the simulated source).
/// Every refusal is reported through <see cref="Refused"/> so the host can trace it.
/// </summary>
public sealed class BridgeDispatcher(OperationRegistry registry, Action<BridgeResponse> publish, Func<OperationDefinition, BridgeError?>? admission = null) : IDisposable
{
    private readonly BridgeAdmission capacity = new(registry.Clock, registry.CaptureSession, registry.QueueTiming, registry.Activity);
    internal (int Running, int Queued, int Network, int Control) AdmissionLoad => capacity.Load;
    internal Task RefreshAdmissionAsync() => capacity.RefreshAsync();

    /// <summary>Withdraws one of this dispatcher's own queued reads before it starts. True only when removed before the real
    /// start; a handler that already began keeps its slot and is stopped only by its own token, never reported as cancelled here.
    /// The activity panel calls this capability through its own request context.</summary>
    public bool CancelQueued(string requestId) => capacity.CancelQueued(requestId);

    /// <summary>Withdraws queued reads; active handlers still hold their slots until their real completion.</summary>
    public void Dispose() => capacity.Dispose();
    /// <summary>Largest message accepted from the page; larger ones are refused before parsing.</summary>
    public const int MaxMessageLength = 1_048_576;

    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = false };

    /// <summary>Handles one raw JSON message. Never throws: malformed or unknown requests are answered with an error.</summary>
    public async Task HandleAsync(string json, CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(json) || json.Length > MaxMessageLength)
        {
            Refuse(null, "bridge", null, new BridgeError("message.size", "Message de l’interface refusé\u00A0: taille non admise."));
            return;
        }
        BridgeRequest? request;
        try
        {
            request = JsonSerializer.Deserialize<BridgeRequest>(json, JsonOptions);
        }
        catch (JsonException)
        {
            // The parser message may quote the page input: only the code is reported.
            Refuse(null, "bridge", null, new BridgeError("message.json", "Message de l’interface illisible."));
            return;
        }
        if (request is null || string.IsNullOrWhiteSpace(request.Id) || request.Id.Length > 64)
        {
            Refuse(null, "bridge", null, new BridgeError("message.id", "Message de l’interface sans identifiant valide."));
            return;
        }
        if (!OperationRegistry.IsValidName(request.Operation) || !registry.TryGet(request.Operation, out var definition))
        {
            // A well-formed name (dotted ASCII, 64 characters at most) is reported; anything else is not.
            var traced = OperationRegistry.IsValidName(request.Operation) ? request.Operation : null;
            Refuse(request.Id, request.Operation ?? "", traced, new BridgeError("operation.unknown", "Opération inconnue\u00A0: rien n’a été exécuté."));
            return;
        }
        if (admission?.Invoke(definition) is BridgeError refusal)
        {
            Refuse(request.Id, definition.Name, definition.Name, refusal);
            return;
        }
        if (BridgeScheduling.Eligible(definition) && System.Text.Encoding.UTF8.GetByteCount(json) > BridgeScheduling.MessageLimit(definition))
        {
            Refuse(request.Id, definition.Name, definition.Name, new("operation.queuePayload", $"Lecture refusée : plus de {BridgeScheduling.MessageLimit(definition) / 1024} Kio de demande conservée pour l’admission."));
            return;
        }
        // Do not retain the original serialized envelope across a bounded wait. Only the parsed bounded read arguments remain.
        json = string.Empty;
        using var requestTrace = OperationTracking.IsTracked(definition) ? registry.Activity?.BeginRequest(definition.Name) : null;
        using var requestScope = OperationRequests.Enter(requestTrace);
        void PublishTracked(BridgeResponse response)
        {
            if (requestTrace is null) publish(response);
            else
            {
                long? rows = null;
#pragma warning disable CA1031 // A counter is an observer, including a custom collection's Count implementation.
                try { rows = OperationTracking.PublishedRowsOf(response.Data); }
                catch (Exception diagnostic) { DiagnosticFailure(diagnostic); }
#pragma warning restore CA1031
                requestTrace.Publish(() => publish(response), rows);
            }
        }
        var context = new BridgeContext(PublishTracked, request.Id, definition.Name) { ReadQueue = capacity.Snapshot, WithdrawQueued = capacity.CancelQueued };
        BridgeAdmission.Lease? slot = null;
        Exception? failure = null;
        try
        {
            slot = await capacity.EnterAsync(request.Id, definition, request.Arguments, cancellationToken,
                () => context.Publish("queued", new { state = "queued", message = "Lecture en attente, aucun envoi effectué.", maximumSeconds = registry.QueueTiming.MaxQueueWaitSeconds }), PublishTracked).ConfigureAwait(false);
            if (slot.Entry.QueueWaitMs is double waitMs) requestTrace?.Admission(waitMs);
            if (BridgeScheduling.Eligible(definition)) { context.Publish("admitted", new { state = "admitted" }); }
            object? data;
            if (slot.Entry.Shared is not null)
            {
                var sharedContext = new BridgeContext(response => capacity.PublishShared(slot, response, publish), request.Id, definition.Name) { SharedRead = true };
                var execution = capacity.ShareAsync(slot, (origin, token) => ExecuteAsync(definition, request.Arguments, sharedContext, origin, token, shared: true));
                requestTrace?.SharedRequest(slot.Entry.Shared.RequestTrace);
                // Only this subscriber stops waiting. The group's independent token is cancelled after the last subscriber
                // detaches; that group still owns its one admission slot until real handler completion.
                data = await execution.WaitAsync(cancellationToken).ConfigureAwait(false);
            }
            else { data = await ExecuteAsync(definition, request.Arguments, context, slot.Entry, cancellationToken, shared: false).ConfigureAwait(false); }
            cancellationToken.ThrowIfCancellationRequested();
            PublishTracked(new BridgeResponse(request.Id, "result", definition.Name, data));
            requestTrace?.Outcome(TaskOutcome.Succeeded);
        }
        catch (OperationCanceledException ex)
        {
            failure = ex;
            requestTrace?.Outcome(TaskOutcome.Stopped);
            PublishTracked(new BridgeResponse(request.Id, "error", definition.Name, null, Failure(definition.Name, "operation.cancelled", "Opération annulée.", ex)));
        }
        catch (BridgeOperationException ex)
        {
            failure = ex;
            // Arguments refused by the operation's schema (arguments.invalid).
            requestTrace?.Outcome(TaskOutcome.Refused);
            Refuse(request.Id, definition.Name, definition.Name, Failure(definition.Name, ex.Code, ex.Message, ex), PublishTracked);
        }
        catch (DomeniaOperationException ex)
        {
            failure = ex;
            requestTrace?.Outcome(ActivityRules.OutcomeOfCode(ex.Code));
            var reference = ex.Code is "operation.cancelled" or "arguments.invalid" ? "" : IncidentReference(definition.Name, ex);
            PublishTracked(new BridgeResponse(request.Id, "error", definition.Name, null, Failure(definition.Name, ex.Code, ex.Message + reference, ex)));
        }
#pragma warning disable CA1031 // The page must always get an answer; the exception is traced by the host.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            failure = ex;
            requestTrace?.Outcome(TaskOutcome.Failed);
            var reference = IncidentReference(definition.Name, ex);
            try { UnhandledError?.Invoke(definition.Name, ex); }
            catch (Exception diagnostic) { DiagnosticFailure(diagnostic); }
            PublishTracked(new BridgeResponse(request.Id, "error", definition.Name, null, Failure(definition.Name, "operation.failed", "L’opération a échoué. Le détail technique est dans le journal." + reference, ex)));
        }
        finally { slot?.Complete(failure); slot?.Dispose(); }
    }

    private static BridgeError Failure(string operation, string code, string message, Exception exception) => new(code, message)
    { Decision = OperationFailure.Classify(exception, code), Requirement = OperationRequirements.ForBridge(operation) };

    private Task<object?> ExecuteAsync(OperationDefinition definition, JsonElement arguments, BridgeContext context,
        BridgeAdmission.Entry origin, CancellationToken token, bool shared)
        // Never cancel scheduling of this delegate: it owns the shared group's completion and must always run its cleanup.
        => Task.Run(async () =>
        {
            await capacity.RevalidateAsync(origin, token).ConfigureAwait(false);
            if (admission?.Invoke(definition) is BridgeError changed) { throw new BridgeOperationException(changed.Code, changed.Message); }
            token.ThrowIfCancellationRequested();
            var readSeconds = registry.QueueTiming.ReadSeconds(definition.Name);
            if (origin.Priority == OperationPriority.Background) readSeconds = Math.Min(readSeconds ?? int.MaxValue, BridgeScheduling.Budget(definition.Scheduling!.Provider).TimeoutSeconds);
            // Logical cancellation asks the actual reader to stop; its physical reservation survives until real completion.
            using var deadline = definition.Class == OperationClass.NetworkRead && readSeconds is int seconds
                ? new CancellationTokenSource(TimeSpan.FromSeconds(seconds), registry.Clock) : null;
            using var linked = deadline is null ? null : CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
            var executionToken = linked?.Token ?? token;
            var capabilities = definition.Class == OperationClass.NetworkRead && registry.CaptureCapabilities is { } capture
                ? await capture(executionToken).ConfigureAwait(false) : null;
            using var capabilityScope = WorkstationCapabilityMemory.Enter(capabilities);
            using var physicalPolicy = PhysicalWorkBudget.Enter(origin.Priority switch
            {
                OperationPriority.Write => PhysicalWorkPriority.Write,
                OperationPriority.Background => PhysicalWorkPriority.Background,
                OperationPriority.Selection => PhysicalWorkPriority.Selection,
                _ => PhysicalWorkPriority.Explicit,
            }, registry.Clock.GetUtcNow() - origin.ScheduledAt >= registry.QueueTiming.Aging, registry.QueueTiming.MaxOutstanding);
            try
            {
                var answer = await definition.Handler(arguments, context.WithAdmission(origin.QueueWaitMs, origin.QueuePromoted), executionToken).ConfigureAwait(false);
                executionToken.ThrowIfCancellationRequested();
                if (shared)
                {
                    // One final local identity/source/scope qualification for all subscribers. Results from a former
                    // account or generation never become successful responses merely because the read itself completed.
                    await capacity.RevalidateAsync(origin, executionToken).ConfigureAwait(false);
                    if (admission?.Invoke(definition) is BridgeError changedAtEnd)
                    { throw new BridgeOperationException(changedAtEnd.Code, changedAtEnd.Message); }
                }
                return answer;
            }
            catch (OperationCanceledException) when (deadline?.IsCancellationRequested == true && !token.IsCancellationRequested)
            { throw new DomeniaOperationException("network.timeout", "Délai de lecture configuré dépassé ; aucun nouvel essai automatique."); }
        }, CancellationToken.None);

    /// <summary>Raised for an unexpected handler failure, so the host writes it to the technical journal.</summary>
    public event Action<string, Exception>? UnhandledError;
    public Func<string, Exception, string>? ReportIncident { get; set; }

    private string IncidentReference(string operation, Exception error)
    {
        string? incident = null;
#pragma warning disable CA1031 // The incident sink is observational; retain the original error if it fails.
        try { incident = ReportIncident?.Invoke(operation, error); }
        catch (Exception diagnostic) { DiagnosticFailure(diagnostic); }
#pragma warning restore CA1031
        return incident is { Length: 36 } && incident.StartsWith("INC-", StringComparison.Ordinal) && incident[4..].All(char.IsAsciiHexDigit)
            ? " Référence " + incident.ToUpperInvariant() + "." : "";
    }

    private void DiagnosticFailure(Exception diagnostic)
    {
#pragma warning disable CA1031 // A failed incident writer must not prevent the original error response.
        try { registry.Activity?.Fault(diagnostic); } catch (Exception) { }
#pragma warning restore CA1031
    }

    /// <summary>
    /// Raised for every refused message with the error code and the operation name when it is declared or well formed
    /// (otherwise null). Never carries the content of the message.
    /// </summary>
    public event Action<string, string?>? Refused;

    private void Refuse(string? id, string operation, string? tracedOperation, BridgeError error, Action<BridgeResponse>? target = null)
    {
        Refused?.Invoke(error.Code, tracedOperation);
        error = error with { Decision = error.Decision ?? OperationFailure.FromCode(error.Code), Requirement = error.Requirement ?? OperationRequirements.ForBridge(operation) };
        (target ?? publish)(new BridgeResponse(id, "error", operation, null, error));
    }
}

/// <summary>Expected failure of an operation, shown to the operator as is (French message, stable code).</summary>
public sealed class BridgeOperationException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
