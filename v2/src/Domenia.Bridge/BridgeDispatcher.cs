using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Validates every message coming from the page and runs the matching declared operation. The optional admission guard is
/// evaluated before the handler (simulation: Write refused, NetworkRead refused unless served by the simulated source).
/// Every refusal is reported through <see cref="Refused"/> so the host can trace it.
/// </summary>
public sealed class BridgeDispatcher(OperationRegistry registry, Action<BridgeResponse> publish, Func<OperationDefinition, BridgeError?>? admission = null)
{
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
            // Arguments refused by the operation's schema (arguments.invalid).
            Refuse(request.Id, definition.Name, definition.Name, new BridgeError(ex.Code, ex.Message));
        }
        catch (DomeniaOperationException ex)
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

    /// <summary>
    /// Raised for every refused message with the error code and the operation name when it is declared or well formed
    /// (otherwise null). Never carries the content of the message.
    /// </summary>
    public event Action<string, string?>? Refused;

    private void Refuse(string? id, string operation, string? tracedOperation, BridgeError error)
    {
        Refused?.Invoke(error.Code, tracedOperation);
        publish(new BridgeResponse(id, "error", operation, null, error));
    }
}

/// <summary>Expected failure of an operation, shown to the operator as is (French message, stable code).</summary>
public sealed class BridgeOperationException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
