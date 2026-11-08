using System.Collections.Immutable;

namespace Domenia.Core.Queries;

/// <summary>Only invented engine-owned input. No content, file, URL, folder or authority parameter can enter this adapter.</summary>
public static class QueryReferenceDemo
{
    public static async Task<QueryImportPlan> PrepareAsync(EngineContext context, QueryLibrary library, CancellationToken token)
    {
        var access = library.DemonstrationAccess(context); // Validates simulation and the concrete MemoryQueryLibraryStore before any read.
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        var root = session.Domain?.RootDn ?? throw QueryReferenceCodec.Bad("Domaine fictif absent.");
        var first = QueryRecipe.Empty(id: "demo.reference.local") with { Name = "Fictif — contrôle conservé localement" };
        var initial = await library.FindAsync(root, first.Id, token).ConfigureAwait(false);
        if (initial is null)
        { initial = (await library.SaveAsync(root, first, "Fictif — corrections locales", "Correction inventée à protéger lors du partage.", 0, "update", null, token).ConfigureAwait(false)).Record; }
        var second = QueryRecipe.Empty(id: "demo.reference.new") with { Name = "Fictif — nouveau contrôle de référence" };
        var text = QueryReferenceCodec.Write("Démonstration fictive", 1, QueryLibrary.RootKey(root), initial.CreatedAt,
            [new(first with { Name = "Fictif — proposition de l’équipe" }, "Fictif — équipe", "Proposition fictive ; conflit volontaire."),
             new(second, "Fictif — équipe", "Ajout fictif ; aucun objet réel ni serveur contacté.")]);
        return await library.ExamineReferencePatchAsync(root, text, access, token).ConfigureAwait(false);
    }

    public static async Task<ImmutableArray<QueryReferenceReceipt>> HistoryAsync(EngineContext context, QueryLibrary library, CancellationToken token)
    {
        var access = library.DemonstrationAccess(context);
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        return await library.ReferenceHistoryAsync(session.Domain?.RootDn ?? throw QueryReferenceCodec.Bad("Domaine fictif absent."), access, token).ConfigureAwait(false);
    }
}
