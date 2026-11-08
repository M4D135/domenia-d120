using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Bridge;

/// <summary>Local profile import only. The existing widget collection remains the sole network entry point.</summary>
public sealed class PersonalProbeOperations : IOperationModule
{
    public string Screen => "accueil";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        var service = AccueilService.From(context);
        return
        [
            new("accueil.probes.personal", OperationClass.LocalRead, async (args, _, token) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.PersonalProbeCatalogAsync(token).ConfigureAwait(false);
            }, "Définitions personnelles du profil et leurs contrats, sans collecte."),
            new("accueil.probes.preview", OperationClass.LocalRead, async (args, _, token) =>
            {
                var values = BridgeArguments.ReadObject(args, ["document", "expectedChoiceToken"]);
                return await service.PreviewPersonalProbesAsync(Document(BridgeArguments.GetString(values, "document")),
                    Hash(BridgeArguments.GetString(values, "expectedChoiceToken")), token).ConfigureAwait(false);
            }, "Aperçu strict de l’import, versions antérieures conservées ; aucune écriture ni collecte."),
            new("accueil.probes.apply", OperationClass.LocalWrite, async (args, _, token) =>
            {
                var values = BridgeArguments.ReadObject(args, ["document", "expectedChoiceToken", "expectedDocumentSha256"]);
                return await service.ApplyPersonalProbesAsync(Document(BridgeArguments.GetString(values, "document")),
                    Hash(BridgeArguments.GetString(values, "expectedChoiceToken")), Hash(BridgeArguments.GetString(values, "expectedDocumentSha256")), token).ConfigureAwait(false);
            }, "Ajout local des versions de sondes après aperçu ; aucune collecte et aucun widget réaffecté."),
        ];
    }

    private static string Document(string value) => value.Length is > 0 and <= PersonalProbeCatalog.MaximumBytes ? value
        : throw BridgeArguments.Invalid("Document de sondes absent ou supérieur à 256 Kio.");

    private static string Hash(string value) => value.Length == 64 && value.All(c => char.IsAsciiDigit(c) || c is >= 'a' and <= 'f') ? value
        : throw BridgeArguments.Invalid("Empreinte de catalogue ou de document invalide.");
}
