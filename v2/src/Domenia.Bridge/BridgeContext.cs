namespace Domenia.Bridge;

/// <summary>Everything a handler may use besides its arguments: event publication towards the page.</summary>
public sealed class BridgeContext(Action<BridgeResponse> publish, string requestId, string operation)
{
    public string RequestId { get; } = requestId;
    public string Operation { get; } = operation;
    // Capabilities come from this dispatcher's own context, never a global registry or a page-supplied session identifier.
    internal bool SharedRead { get; init; }
    internal double? AdmissionWaitMs { get; init; }
    internal bool AdmissionPromoted { get; init; }
    internal BridgeContext WithAdmission(double? milliseconds, bool promoted) => new(publish, RequestId, Operation)
    {
        SharedRead = SharedRead, ReadQueue = ReadQueue, WithdrawQueued = WithdrawQueued,
        AdmissionWaitMs = milliseconds, AdmissionPromoted = promoted,
    };
    internal Func<BridgeQueueSnapshot>? ReadQueue { get; init; }
    internal Func<string, bool>? WithdrawQueued { get; init; }

    /// <summary>Pushes an event (progress, partial results) to the page for this request.</summary>
    public void Publish(string eventName, object? data) =>
        publish(new BridgeResponse(RequestId, "event", Operation + ":" + eventName, data));
}
