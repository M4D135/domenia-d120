using System.Collections.Concurrent;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Every refusal of an operation reaches the journal of the session (Domenia 1 Add-DomeniaSupportIncidentFromLog took every
/// WARN and ERROR line of the interface): the Assistance « Incidents » view, the journal of Opérations and the shell explain it.
/// The line holds the operation, the stable code and the message shown to the operator (no secret, no argument). The same
/// refusal of the same operation is written once a minute at most, so that a refused refresh never floods the journal. The
/// Assistance screen journals its own refusals (AssistanceOperations), so its operations are left out here.
/// </summary>
public static class OperationRefusals
{
    private static readonly TimeSpan Quiet = TimeSpan.FromMinutes(1);

    public static OperationDefinition Journal(EngineContext context, OperationDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(definition);
        if (definition.Name.StartsWith("assistance.", StringComparison.Ordinal))
        {
            return definition;
        }
        var inner = definition.Handler;
        var last = context.Shared(static _ => new LastRefusals());
        return definition with
        {
            Handler = async (arguments, bridge, cancellationToken) =>
            {
                try
                {
                    return await inner(arguments, bridge, cancellationToken).ConfigureAwait(false);
                }
                catch (DomeniaOperationException ex)
                {
                    Write(context, last, definition.Name, ex.Code, ex.Message, ex.Code == DomeniaErrors.ArgumentsInvalid ? Tone.Warn : Tone.Alert);
                    throw;
                }
                catch (BridgeOperationException ex)
                {
                    Write(context, last, definition.Name, ex.Code, ex.Message, Tone.Warn);
                    throw;
                }
            },
        };
    }

    private static void Write(EngineContext context, LastRefusals last, string operation, string code, string message, Tone tone)
    {
        var now = context.Clock.GetUtcNow();
        var key = operation + "|" + code;
        if (last.Times.TryGetValue(key, out var at) && now - at < Quiet)
        {
            return;
        }
        last.Times[key] = now;
        var flat = string.Join(' ', (message ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (flat.Length > 300)
        {
            flat = flat[..299] + "…";
        }
        context.Journal.Add(new JournalEntry(now, operation + " · refus " + code + FrenchText.Colon + flat, tone));
    }

    private sealed class LastRefusals
    {
        public ConcurrentDictionary<string, DateTimeOffset> Times { get; } = new(StringComparer.Ordinal);
    }
}
