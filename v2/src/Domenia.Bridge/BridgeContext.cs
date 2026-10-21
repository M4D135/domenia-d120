namespace Domenia.Bridge;

/// <summary>Everything a handler may use besides its arguments: event publication towards the page.</summary>
public sealed class BridgeContext(Action<BridgeResponse> publish, string requestId, string operation)
{
    public string RequestId { get; } = requestId;
    public string Operation { get; } = operation;

    /// <summary>Pushes an event (progress, partial results) to the page for this request.</summary>
    public void Publish(string eventName, object? data) =>
        publish(new BridgeResponse(RequestId, "event", Operation + ":" + eventName, data));
}
