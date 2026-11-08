using Domenia.Core;
using Domenia.Core.Queries;
using System.Text.Json;

namespace Domenia.Bridge.Operations.Requetes;

internal static class QueryReferenceContext
{
    internal static bool IsReference(string content)
    {
        try
        {
            using var document = JsonDocument.Parse(content, new JsonDocumentOptions { MaxDepth = 64 });
            return document.RootElement.ValueKind == JsonValueKind.Object && document.RootElement.TryGetProperty("format", out var format)
                && format.ValueKind == JsonValueKind.String && format.GetString()?.StartsWith("Domenia.ReferencePatch/", StringComparison.Ordinal) == true;
        }
        catch (JsonException) { throw new DomeniaOperationException(QueryErrors.PackInvalid, "Pack illisible : JSON invalide, aucune modification."); }
    }
    internal static async Task<QueryReferenceAccess> Capture(EngineContext context, CancellationToken token)
    {
        // Guard before even bootstrapping the source or opening a library. The page cannot supply the mode or authority.
        if (context.Mode == AppMode.Simulation || context.Directory.Kind == DirectorySourceKind.Simulation)
        { throw new QueryDefinitionException("Diffusion de références réelles indisponible en démonstration ; aucun partage ni bibliothèque réelle ouvert."); }
        var source = context.Directory;
        var session = await source.GetSessionAsync(token).ConfigureAwait(false);
        var selection = AccountAccess.From(context).SelectionVersion;
        if (session.Domain?.RootDn is null) { throw new QueryDefinitionException("Domaine de la session indisponible."); }
        if (source is not IDirectoryWriteLeaseSource leases) { throw new QueryDefinitionException("Cette source ne fournit pas de bail de session qualifié ; patch refusé."); }
        return new QueryReferenceAccess(context, () =>
        {
            // This synchronous source gate checks the captured epoch/account and refuses ongoing maintenance. Never call
            // GetSessionAsync under a SQLite write transaction: a concurrent maintenance may already hold loadingLocal.
            using var check = leases.AcquireWriteLease(session);
            if (AccountAccess.From(context).SelectionVersion != selection)
            { throw new QueryDefinitionException("Source, compte ou session modifié depuis l’aperçu ; préparez une nouvelle lecture du patch."); }
        }, () => leases.AcquireWriteLease(session));
    }
}
