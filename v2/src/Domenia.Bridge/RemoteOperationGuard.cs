using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Bridge;

internal static class RemoteOperationGuard
{
    private static readonly (string Operation, string Kind)[] Actions =
    [
        ("restart", PosteRemoteWrites.RestartKind), ("restartCancel", PosteRemoteWrites.RestartCancelKind),
        ("gpupdate", PosteRemoteWrites.GpUpdateKind), ("service", PosteRemoteWrites.ServiceKind),
        ("run", PosteRemoteWrites.RunKind), ("wake", PosteRemoteWrites.WakeKind),
    ];
    internal static OperationDefinition Bind(EngineContext context, OperationDefinition definition)
    {
        var kind = Actions.FirstOrDefault(a => definition.Name == "poste." + a.Operation + ".plan").Kind;
        if (kind is null && definition.Name != "poste.open") return definition;
        var inner = definition.Handler;
        return definition with { Handler = async (args, bridge, token) =>
        {
            var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            var inFlight = WriteCircuit.From(context).InFlight; var pending = 0; var cancelPending = 0; var unreadable = 0;
            try
            {
                var targetDn = args.ValueKind == JsonValueKind.Object && args.TryGetProperty("dn", out var dn) && dn.ValueKind == JsonValueKind.String ? dn.GetString() : null;
                var circuit = WriteCircuit.From(context);
                (pending, cancelPending, unreadable) = await circuit.RemotePendingAsync(session, targetDn, token).ConfigureAwait(false);
                inFlight |= circuit.InFlight;
            }
            catch (OperationCanceledException) { throw; }
            catch { unreadable = 1; }
            RemoteWriteDecision Decision(string action, bool winrm) => RemoteWriteAccess.Evaluate(context.Mode, session,
                inFlight, action == PosteRemoteWrites.RestartCancelKind ? cancelPending : pending, unreadable, winrm, context.Configuration.Poste.Options.UseWinRm, context.Writers.ForKind(action) is not null);
            if (kind is not null)
            {
                if (args.ValueKind == JsonValueKind.Object && args.TryGetProperty("mode", out var suppliedMode) && suppliedMode.ValueKind != JsonValueKind.String)
                    throw BridgeArguments.Invalid("Le mode d’intervention doit être un texte déclaré.");
                var winrm = kind is PosteRemoteWrites.GpUpdateKind or PosteRemoteWrites.RestartCancelKind || kind == PosteRemoteWrites.RestartKind
                    && !(args.ValueKind == JsonValueKind.Object && args.TryGetProperty("mode", out var mode) && mode.GetString() == "now");
                Decision(kind, winrm).Require();
                return await inner(args, bridge, token).ConfigureAwait(false);
            }
            var result = await inner(args, bridge, token).ConfigureAwait(false);
            return result is PosteConsole console ? console with { RemoteActions = Actions.ToDictionary(a => a.Operation,
                a => Decision(a.Kind, a.Kind is PosteRemoteWrites.GpUpdateKind or PosteRemoteWrites.RestartCancelKind), StringComparer.Ordinal) } : result;
        } };
    }
}
