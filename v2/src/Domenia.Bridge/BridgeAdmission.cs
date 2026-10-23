namespace Domenia.Bridge;

/// <summary>Bounded per-window admission. Saturated gestures are refused, never replayed later with a different session.</summary>
internal sealed class BridgeAdmission
{
    internal const int NetworkLimit = 8;
    internal const int OrdinaryLimit = 48;
    internal const int ControlLimit = 4;
    private readonly Lock gate = new();
    private readonly HashSet<string> ids = new(StringComparer.Ordinal);
    private int network;
    private int ordinary;
    private int control;

    internal IDisposable? Enter(string id, OperationDefinition operation, out BridgeError? refusal)
    {
        var isControl = operation.Name.EndsWith(".stop", StringComparison.Ordinal) || operation.Name.EndsWith(".cancel", StringComparison.Ordinal);
        var isNetwork = operation.Class == OperationClass.NetworkRead;
        lock (gate)
        {
            if (ids.Contains(id))
            {
                refusal = new("operation.duplicate", "Cette demande est déjà en cours ; aucun second envoi."); return null;
            }
            if (isControl ? control >= ControlLimit : ordinary >= OrdinaryLimit || isNetwork && network >= NetworkLimit)
            {
                refusal = new("operation.busy", "Trop d’opérations sont déjà en cours. Attendez leur résultat, puis recommencez ce geste ; rien n’est mis en attente."); return null;
            }
            ids.Add(id);
            if (isControl) { control++; } else { ordinary++; if (isNetwork) { network++; } }
        }
        refusal = null; return new Lease(this, id, isControl, isNetwork);
    }

    private sealed class Lease(BridgeAdmission owner, string id, bool isControl, bool isNetwork) : IDisposable
    {
        private BridgeAdmission? active = owner;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref active, null) is not { } scope) { return; }
            lock (scope.gate)
            {
                scope.ids.Remove(id);
                if (isControl) { scope.control--; } else { scope.ordinary--; if (isNetwork) { scope.network--; } }
            }
        }
    }
}
