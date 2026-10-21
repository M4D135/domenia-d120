using System.Text.Json;

namespace Domenia.Bridge;

/// <summary>Validates every message coming from the page and runs the matching declared operation.</summary>
public sealed class BridgeDispatcher(OperationRegistry registry, Action<BridgeResponse> publish)
{
    /// <summary>Largest message accepted from the page; larger ones are refused before parsing.</summary>
    public const int MaxMessageLength = 1_048_576;

    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = false };

    /// <summary>Handles one raw JSON message. Never throws: malformed or unknown requests are answered with an error.</summary>
    public async Task HandleAsync(string json, CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(json) || json.Length > MaxMessageLength)
        {
            publish(new BridgeResponse(null, "error", "bridge", null, new BridgeError("message.size", "Message de l’interface refusé : taille non admise.")));
            return;
        }
        BridgeRequest? request;
        try
        {
            request = JsonSerializer.Deserialize<BridgeRequest>(json, JsonOptions);
        }
        catch (JsonException)
        {
            publish(new BridgeResponse(null, "error", "bridge", null, new BridgeError("message.json", "Message de l’interface illisible.")));
            return;
        }
        if (request is null || string.IsNullOrWhiteSpace(request.Id) || request.Id.Length > 64)
        {
            publish(new BridgeResponse(null, "error", "bridge", null, new BridgeError("message.id", "Message de l’interface sans identifiant valide.")));
            return;
        }
        if (!OperationRegistry.IsValidName(request.Operation) || !registry.TryGet(request.Operation, out var definition))
        {
            publish(new BridgeResponse(request.Id, "error", request.Operation ?? "", null, new BridgeError("operation.unknown", "Opération inconnue : rien n’a été exécuté.")));
            return;
        }
        var context = new BridgeContext(publish, request.Id, definition.Name);
        try
        {
            var data = await definition.Handler(request.Arguments, context, cancellationToken).ConfigureAwait(false);
            publish(new BridgeResponse(request.Id, "result", definition.Name, data));
        }
        catch (OperationCanceledException)
        {
            publish(new BridgeResponse(request.Id, "error", definition.Name, null, new BridgeError("operation.cancelled", "Opération annulée.")));
        }
        catch (BridgeOperationException ex)
        {
            publish(new BridgeResponse(request.Id, "error", definition.Name, null, new BridgeError(ex.Code, ex.Message)));
        }
#pragma warning disable CA1031 // The page must always get an answer; the exception is traced by the host.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            UnhandledError?.Invoke(definition.Name, ex);
            publish(new BridgeResponse(request.Id, "error", definition.Name, null, new BridgeError("operation.failed", "L’opération a échoué. Le détail technique est dans le journal.")));
        }
    }

    /// <summary>Raised for an unexpected handler failure, so the host writes it to the technical journal.</summary>
    public event Action<string, Exception>? UnhandledError;
}

/// <summary>Expected failure of an operation, shown to the operator as is (French message, stable code).</summary>
public sealed class BridgeOperationException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
