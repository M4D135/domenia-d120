using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;

namespace Domenia.Bridge;

public sealed class ReferenceDistributionOperations : IOperationModule
{
    public string Screen => "requetes";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        var service = QueryReferenceDistribution.From(context);
        return [
            new("requetes.reference.distribution.list", OperationClass.NetworkRead, async (args, _, token) => await RequetesArgs.Guard(async () =>
            { BridgeArguments.RequireNone(args); return await Read(() => service.ListAsync(token)).ConfigureAwait(false); }).ConfigureAwait(false),
                "Lit explicitement SHA256SUMS.txt du dossier de diffusion mémorisé ; ne copie ni n’applique aucun patch."),
            new("requetes.reference.distribution.read", OperationClass.NetworkRead, async (args, _, token) => await RequetesArgs.Guard(async () =>
            { var values = BridgeArguments.ReadObject(args, ["id"]); return await Read(() => service.ReadAsync(RequetesArgs.Id32(values, "id"), token)).ConfigureAwait(false); }).ConfigureAwait(false),
                "Copie un patch sélectionné en mémoire bornée, vérifie ses deux empreintes puis prépare l’aperçu ; aucune écriture dans le partage."),
        ];
    }
    private static async Task<T> Read<T>(Func<Task<T>> action)
    {
        try { return await action().ConfigureAwait(false); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { throw new Domenia.Core.Queries.QueryDefinitionException("Lecture du dossier de diffusion impossible ou interrompue (accès, fichier absent, lien ou réseau). Aucune bibliothèque modifiée ; réessayez explicitement."); }
    }
}
