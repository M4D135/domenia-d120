using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Closed presentation metadata from the admitted handler, without request arguments or results.</summary>
public sealed record OperationTaskStarted(string TaskId, string Label, string Priority, bool Cancellable);

/// <summary>
/// Follows every operation of the registry in the activity of the session (<see cref="OperationActivity"/>, docs/ops/operations.md
/// § 3): its start, the events it publishes, its end and its duration. Wrapping happens once, when the registry is built
/// (<see cref="OperationModules.CreateRegistry(EngineContext, IEnumerable{IOperationModule}, QueueTiming)"/>); the handler is called exactly as
/// before, with the same arguments and the same answer, and every exception goes on unchanged. Reads receive a cancellation of their
/// own, linked to the lifetime of the application, so the operator can stop them from Opérations; writes keep the lifetime and
/// are never stopped. Nothing of the request is recorded but its name: no argument, no result, no message.
/// </summary>
public static class OperationTracking
{
    /// <summary>
    /// The definition followed by the activity of <paramref name="context"/>. The local reads of the Opérations screen itself are not
    /// followed (they refresh it every few seconds); its writes and network reads are.
    /// </summary>
    public static OperationDefinition Track(EngineContext context, OperationDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(definition);
        var activity = OperationActivity.From(context);
        var kind = KindOf(definition.Class);
        activity.Declare(definition.Name, kind, definition.Description);
        if (!IsTracked(definition))
        {
            return definition with { Handler = async (args, bridge, token) =>
            {
                using var measurements = OperationsMeasurements.Enter(activity);
                return await definition.Handler(args, bridge, token).ConfigureAwait(false);
            } };
        }
        var inner = definition.Handler;
        return definition with
        {
            Handler = async (arguments, bridge, cancellationToken) =>
            {
                ActivityTask? observed = null;
                Guard(activity, () => observed = activity.Begin(definition.Name, kind, cancellationToken, bridge.RequestId, definition.Foreground));
                if (observed is null) return await inner(arguments, bridge, cancellationToken).ConfigureAwait(false);
                using var task = observed;
                task.RecordAdmission(bridge.AdmissionWaitMs, bridge.AdmissionPromoted);
                // A real admitted handler, identified by the host; the page can stop only this task through the guarded endpoint.
                if (definition.Foreground)
                    Guard(activity, () => bridge.Publish("tracking", new OperationTaskStarted(task.Id, activity.LabelOf(definition.Name),
                        definition.Priority.ToString().ToLowerInvariant(), ActivityRules.IsStoppable(kind))));
                using var phases = OperationPhases.Enter(task);
                using var measurements = OperationsMeasurements.Enter(activity);
                var forward = new BridgeContext(response => Forward(activity, task, bridge, response), bridge.RequestId, bridge.Operation)
                { ReadQueue = bridge.ReadQueue, WithdrawQueued = bridge.WithdrawQueued, SharedRead = bridge.SharedRead,
                  AdmissionWaitMs = bridge.AdmissionWaitMs, AdmissionPromoted = bridge.AdmissionPromoted };
                try
                {
                    object? result;
                    using (bridge.SharedRead ? OperationPhases.Measure(OperationPhase.SharedRead) : null)
                        result = await inner(arguments, forward, task.Token).ConfigureAwait(false);
                    Settle(activity, task, definition, result);
                    return result;
                }
                catch (Exception exception)
                {
                    Record(activity, task, exception);
                    throw;
                }
            },
        };
    }

    /// <summary>Kind of the task of an operation class.</summary>
    public static TaskKind KindOf(OperationClass operationClass) => operationClass switch
    {
        OperationClass.Local => TaskKind.Local,
        OperationClass.LocalRead => TaskKind.LocalRead,
        OperationClass.NetworkRead => TaskKind.NetworkRead,
        OperationClass.LocalWrite => TaskKind.LocalWrite,
        _ => TaskKind.Write,
    };

    /// <summary>Every operation but the local reads and computations of the Opérations screen (its own refreshes).</summary>
    public static bool IsTracked(OperationDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(definition);
        return !(definition.Name.StartsWith(OperationsScreen + ".", StringComparison.Ordinal) && definition.Class is OperationClass.Local or OperationClass.LocalRead);
    }

    private const string OperationsScreen = "operations";

    /// <summary>Constant-time counts of known row contracts only; no reflection, serialization or enumeration. A scalar
    /// status/progress publication has no row count, not an invented one. Repeated publications count transmitted rows.</summary>
    public static long? PublishedRowsOf(object? result) => result switch
    {
        null => 0,
        System.Collections.ICollection items => items.Count,
        SearchPage page => page.Rows.Length,
        SearchResult page => page.Rows.Length,
        SearchReconcile page => page.Rows.Length,
        SearchMeasures page => page.Rows.Length,
        IndexSearchPage page => page.Rows.Length,
        _ => null,
    };

    /// <summary>Records an event published by the operation, then sends it to the page exactly as the operation did.</summary>
    private static void Forward(OperationActivity activity, ActivityTask task, BridgeContext bridge, BridgeResponse response)
    {
        var name = response.Operation.Length > bridge.Operation.Length + 1 ? response.Operation[(bridge.Operation.Length + 1)..] : response.Operation;
        Guard(activity, () =>
        {
            if (response.Data is WriteStageEvent stage)
            {
                task.Step(stage.Label, sequential: true);
            }
            else
            {
                task.Step("Étape " + FrenchText.Quote(name), sequential: false);
            }
        });
        bridge.Publish(name, response.Data);
    }

    /// <summary>
    /// End of a request that answered. Only the receipt of write.execute says how a write really ended (an unknown outcome is never a
    /// success); a read that hands back a receipt (write.receipts.get, write.receipts.verify, even on a receipt still to verify) is a
    /// read that answered, with its own label. Remote requests (network reads, writes) also record the estimated bytes received.
    /// </summary>
    private static void Settle(OperationActivity activity, ActivityTask task, OperationDefinition definition, object? result) => Guard(activity, () =>
    {
        long? bytes = null;
        if (definition.Class is OperationClass.NetworkRead or OperationClass.Write)
            Guard(activity, () => bytes = BytesOf(result));
        if (result is ReceiptView receipt && string.Equals(definition.Name, WriteCircuit.ExecuteOperation, StringComparison.Ordinal))
        {
            task.Rename(receipt.Label);
            var (outcome, category) = receipt.Pending
                ? (TaskOutcome.Unknown, WriteErrors.OutcomeUnknown)
                : receipt.Result == WriteResult.NotApplied
                    ? (TaskOutcome.Failed, receipt.Error?.Code ?? "write.notApplied")
                    : receipt.Verification == VerificationState.Mismatch
                        ? (TaskOutcome.Unknown, "write.mismatch")
                        : (TaskOutcome.Succeeded, (string?)null);
            task.Complete(outcome, category, 1, bytes);
            return;
        }
        // A broken optional counter is not a failed handler. Preserve its actual successful result and mark volume unknown.
        long volume = -1;
        Guard(activity, () => volume = VolumeOf(result));
        task.Complete(TaskOutcome.Succeeded, null, volume, bytes,
            volumeComplete: result is not SearchResult { Interrupted: true } and not SearchResult { LimitReached: true }
                and not SearchPage { Interrupted: true } and not SearchPage { More: true } and not SyncReadResult { Complete: false },
            calibration: result is SyncReadResult sync ? SyncCalibrationRules.Observe(sync) : null);
    });

    /// <summary>
    /// Estimated volume received by a remote request (Domenia 1 BytesEstimated): the size of its answer in the JSON of the contract,
    /// counted without keeping the text. Null when it cannot be measured (never 0 invented).
    /// </summary>
    public static long? BytesOf(object? result)
    {
        if (result is null)
        {
            return null;
        }
        try
        {
            using var counter = new CountingStream();
            JsonSerializer.Serialize(counter, result, result.GetType(), BridgeJson.Options);
            return counter.Length;
        }
        catch (Exception exception) when (exception is NotSupportedException or InvalidOperationException or JsonException)
        {
            return null;
        }
    }

    /// <summary>A write-only stream that only counts the bytes written to it.</summary>
    private sealed class CountingStream : Stream
    {
        private long length;

        public override bool CanRead => false;

        public override bool CanSeek => false;

        public override bool CanWrite => true;

        public override long Length => length;

        public override long Position
        {
            get => length;
            set => throw new NotSupportedException();
        }

        public override void Flush()
        {
            // Nothing is kept: nothing to flush.
        }

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => length += count;

        public override void Write(ReadOnlySpan<byte> buffer) => length += buffer.Length;
    }

    private static void Record(OperationActivity activity, ActivityTask task, Exception exception) => Guard(activity, () =>
    {
        switch (exception)
        {
            case OperationCanceledException:
                task.Complete(TaskOutcome.Stopped, task.StopRequested ? "operation.stopped" : "operation.cancelled", -1);
                break;
            case BridgeOperationException refused:
                task.Complete(TaskOutcome.Refused, refused.Code, -1);
                break;
            case DomeniaOperationException expected:
                task.Complete(ActivityRules.OutcomeOfCode(expected.Code), expected.Code, -1);
                break;
            default:
                task.Complete(TaskOutcome.Failed, "operation.failed", -1);
                break;
        }
    });

    /// <summary>
    /// Number of items handed back, read without enumerating anything (Domenia 1 Get-DomeniaOutputVolume): a collection gives its
    /// count, a result carrying a collection (rows, receipts, items…) gives that count, anything else counts as one; nothing as 0.
    /// </summary>
    public static long VolumeOf(object? result)
    {
        switch (result)
        {
            case SyncReadResult read:
                return read.Read;
            case null:
                return 0;
            case string or ValueType when result is not System.Collections.ICollection:
                return 1;
            case System.Collections.ICollection collection:
                return collection.Count;
        }
        string[] names = ["Rows", "Receipts", "Items", "Results", "Entries", "Lines", "Recent", "Children"];
        var type = result.GetType();
        foreach (var name in names)
        {
            if (type.GetProperty(name)?.GetValue(result) is System.Collections.ICollection inner)
            {
                return inner.Count;
            }
        }
        return 1;
    }

    /// <summary>An incident of the tracking never breaks the operation: it is counted and traced (code only).</summary>
    private static void Guard(OperationActivity activity, Action action)
    {
        try
        {
            action();
        }
#pragma warning disable CA1031 // Tracking is an observer: whatever happens there, the operation itself must go on unchanged.
        catch (Exception exception)
#pragma warning restore CA1031
        {
#pragma warning disable CA1031 // Even a broken diagnostic sink must leave the original handler outcome untouched.
            try { activity.Fault(exception); } catch (Exception) { }
#pragma warning restore CA1031
        }
    }
}
