using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Bridge;

public sealed partial class PosteOperations
{
    private static IEnumerable<OperationDefinition> TaskReadOperations(EngineContext context, OperationClass planClass)
    {
        yield return new OperationDefinition("poste.read.pending", OperationClass.LocalRead, async (args, _, ct) =>
        {
            var dn = Dn(args, []);
            var reader = context.Readers.Find<IPosteTaskReadJournalReader>();
            return reader is null ? System.Collections.Immutable.ImmutableArray<RemoteTaskPending>.Empty
                : await reader.PendingTaskReadsAsync(dn.Dn, ct).ConfigureAwait(false);
        }, "Lectures par tâche de ce poste dont le nettoyage reste à confirmer ; journal local uniquement.");

        yield return new OperationDefinition("poste.read.cleanup.plan", planClass, async (args, _, ct) =>
        {
            var dn = Dn(args, ["operationId"]);
            if (!Guid.TryParseExact(BridgeArguments.GetString(dn.Values, "operationId"), "D", out var id) || id == Guid.Empty)
            { throw BridgeArguments.Invalid("Identifiant de lecture invalide."); }
            var draft = await context.Writers.Require<IPosteTaskCleanupExecutor>().PlanAsync(dn.Dn, id, ct).ConfigureAwait(false);
            return await WriteCircuit.From(context).PlanAsync(draft, ct).ConfigureAwait(false);
        }, "Plan explicite de nettoyage des seuls artefacts d’une lecture enregistrée, après vérification du poste et du compte d’origine.");
    }
}
