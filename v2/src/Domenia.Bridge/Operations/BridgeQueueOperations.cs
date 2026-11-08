using Domenia.Core;

namespace Domenia.Bridge;

public sealed record BridgeQueuedRead(string RequestId, string Operation, string Label, DateTimeOffset QueuedAt, int WaitedSeconds);
public sealed record BridgeQueueSnapshot(int Admitted, int Waiting, int Network, int Controls, int Limit, IReadOnlyList<BridgeQueuedRead> Reads)
{
    /// <summary>Accepted followers of queued or running reads, since this window's dispatcher was created. Not a count of successful results or physical queries.</summary>
    public long SharedReadJoins { get; init; }
}
public sealed record BridgeQueueCancellation(bool Removed, string State, string Message);

/// <summary>Local view and withdrawal of this window's bounded queue. No arguments, target, account or session stamp is exposed.</summary>
public sealed class BridgeQueueOperations : IOperationModule
{
    public string Screen => "operations";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) => Definitions();
    internal static IEnumerable<OperationDefinition> Definitions() =>
    [
        new("operations.queue.read", OperationClass.Local, (args, bridge, token) =>
        {
            BridgeArguments.RequireNone(args); token.ThrowIfCancellationRequested();
            return Task.FromResult<object?>(bridge.ReadQueue?.Invoke() ?? throw Unavailable());
        }, "Lectures en attente avant leur départ"),
        new("operations.queue.cancel", OperationClass.Local, (args, bridge, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["requestId"]);
            var requestId = BridgeArguments.GetString(values, "requestId");
            if (requestId.Length is 0 or > 64 || requestId.Any(char.IsControl)) { throw BridgeArguments.Invalid("Identifiant de demande invalide."); }
            token.ThrowIfCancellationRequested();
            var removed = (bridge.WithdrawQueued ?? throw Unavailable())(requestId);
            return Task.FromResult<object?>(new BridgeQueueCancellation(removed, removed ? "withdrawn" : "notQueued",
                removed ? "Lecture retirée de la file avant envoi."
                    : "Cette lecture est déjà admise, terminée ou absente. Aucun arrêt confirmé ; utilisez son activité si elle est en cours."));
        }, "Retirer une lecture encore en attente"),
    ];

    private static BridgeOperationException Unavailable() => new("operation.queueUnavailable", "La file de cette fenêtre est indisponible.");
}
