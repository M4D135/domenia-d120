using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Bridge;

public sealed class PostePersonalProbeOperations : IOperationModule
{
    public string Screen => "poste";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        var service = PostePersonalProbes.From(context);
        return
        [
            new("poste.personalProbe.plan", OperationClass.LocalRead, async (args, _, token) =>
            {
                var values = BridgeArguments.ReadObject(args, ["dn", "computer", "item"]);
                if (!Guid.TryParse(BridgeArguments.GetString(values, "computer"), out var guid) || guid == Guid.Empty)
                { throw BridgeArguments.Invalid("Identité exacte du poste attendue."); }
                return await service.PlanAsync(BridgeArguments.GetString(values, "dn"), guid, BridgeArguments.GetString(values, "item"), token).ConfigureAwait(false);
            }, "Prépare la lecture d’une carte personnelle active avec son contrat et sa version exacts ; aucun contact réseau.", ServedInSimulation: true),
            new("poste.personalProbe.discard", OperationClass.Local, (args, _, token) =>
            {
                token.ThrowIfCancellationRequested();
                var values = BridgeArguments.ReadObject(args, ["id"]);
                service.Discard(BridgeArguments.GetString(values, "id"));
                return Task.FromResult<object?>(new { discarded = true });
            }, "Abandonne la préparation en mémoire sans collecte.", ServedInSimulation: true),
            new("poste.personalProbe.run", OperationClass.NetworkRead, async (args, _, token) =>
            {
                var values = BridgeArguments.ReadObject(args, ["id", "confirmed"]);
                if (!values.TryGetValue("confirmed", out var confirmation) || confirmation.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                { throw BridgeArguments.Invalid("Confirmation explicite attendue."); }
                return await service.RunAsync(BridgeArguments.GetString(values, "id"), confirmation.GetBoolean(), token).ConfigureAwait(false);
            }, "Lit seulement la projection personnelle confirmée pour l’identité exacte du poste et relit son enregistrement local.", ServedInSimulation: true),
        ];
    }
}
