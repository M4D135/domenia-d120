using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.App;

/// <summary>Visible state of the local log writer; reads only its bounded in-memory counters.</summary>
public sealed class TechnicalJournalOperations : IOperationModule
{
    public string Screen => "shell";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
    [
        new("shell.journal.status", OperationClass.LocalRead, (args, _, _) =>
        {
            BridgeArguments.RequireNone(args);
            return Task.FromResult<object?>(TechnicalLog.Status);
        }, "Disponibilité du journal local, chemin de secours et lignes en attente ou perdues."),
    ];
}
