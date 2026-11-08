using System.Collections.Immutable;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Bridge;

public sealed partial class SearchOperations
{
    private static async Task<SearchCatalog> RecipeCatalogAsync(EngineContext context, SearchCatalog delivered, CancellationToken token)
    {
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        if (session.Domain?.RootDn is not { } root) { return delivered; }
        var library = await RequetesServices.Library(context).ReadAsync(root, token).ConfigureAwait(false);
        var favorites = SearchMemory.From(context).QueryFavorites();
        var entries = library.Records.Where(r => !r.Archived && r.Recipe.Target == QueryTarget.Computer).Select(r =>
            new SearchCatalogEntry("recipe:" + r.Id, r.Name, "Recettes enregistrées · " + r.Category, "Bibliothèque locale", "Postes", r.Description,
                "Calcul local sur la copie de l’annuaire et les relevés conservés ; au plus 20 000 lignes affichées.", "", favorites.Contains("recipe:" + r.Id), true)
            { Recipe = new(r.Id, r.Revision, r.Fingerprint, root, "match", r.UpdatedAt) }).ToImmutableArray();
        await RequireSameSession(context, session, token).ConfigureAwait(false);
        return delivered with { Entries = delivered.Entries.AddRange(entries), Favorites = delivered.Favorites + entries.Count(e => e.Favorite),
            Note = delivered.Note + " Les recettes de postes enregistrées utilisent leur révision affichée et les SELECT déjà mémorisés, sans collecte." + (library.Unreadable > 0 ? " Certaines recettes illisibles ne sont pas proposées." : "") };
    }

    private static IEnumerable<OperationDefinition> RecipeOperations(EngineContext context)
    {
        var service = SearchService.From(context);
        return
        [
            new("search.recipe.run", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var v = BridgeArguments.ReadObject(args, ["id", "revision", "fingerprint", "domain", "dn", "subtree", "verdict", "limit"]);
                var id = BridgeArguments.GetString(v, "id");
                if (!QueryRecipeJson.IdPattern().IsMatch(id)) { throw BridgeArguments.Invalid("Identifiant de recette invalide."); }
                if (!v.TryGetValue("revision", out var number) || number.ValueKind != System.Text.Json.JsonValueKind.Number || !number.TryGetInt64(out var revision) || revision < 1)
                { throw BridgeArguments.Invalid("Révision de recette invalide."); }
                var fingerprint = BridgeArguments.GetString(v, "fingerprint");
                if (fingerprint.Length != 64 || fingerprint.Any(c => !char.IsAsciiHexDigitLower(c))) { throw BridgeArguments.Invalid("Empreinte de recette invalide."); }
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(v, "dn"), "dn");
                var expectedRoot = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(v, "domain"), "domain");
                var expectedSession = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
                if (expectedSession.Domain?.RootDn is not { } root || !DistinguishedName.AreEqual(root, expectedRoot))
                { throw new DomeniaOperationException(SearchErrors.ViewUnknown, "Le catalogue appartient à un autre domaine ; rouvrez-le dans cette session."); }
                var result = await service.RecipeAsync(RequetesServices.Library(context), id, revision, fingerprint, dn, BridgeArguments.GetBoolean(v, "subtree"),
                    OptionalString(v, "verdict") ?? "match", Limit(v), ct).ConfigureAwait(false);
                await RequireSameSession(context, expectedSession, ct).ConfigureAwait(false);
                return result;
            }, "Calcule une recette enregistrée sur l’OU explicitement choisie ; copie locale et SELECT mémorisés seulement, révision vérifiée."),
            new("search.recipe.more", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var v = BridgeArguments.ReadObject(args, ArgsListIdLimit);
                return await service.RecipeMoreAsync(Hex32(v, "listId"), Int(v, "limit", null, 1, SearchLimits.MaxLimit), ct).ConfigureAwait(false);
            }, "Page suivante du même résultat figé, sans réévaluation ni lecture distante."),
            new("search.query.rows", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
                var selected = QueryWorkshop.From(context).Search;
                if (selected is null || selected.Target != QueryTarget.Computer || !selected.Matches(session))
                { throw new DomeniaOperationException(SearchErrors.ListUnknown, "Aucune sélection de postes qualifiée dans cette session."); }
                var result = await service.SelectionAsync(selected.Ids.Select(Guid.Parse).ToArray(), selected.RecipeName, selected.At, ct, computersOnly: true).ConfigureAwait(false);
                await RequireSameSession(context, session, ct).ConfigureAwait(false);
                return result;
            }, "Liste locale des GUID figés par l’Atelier, sélection vide comprise ; domaine et session requalifiés."),
        ];
    }

    private static async Task RequireSameSession(EngineContext context, SessionSnapshot expected, CancellationToken token)
    {
        var current = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        if (current.Epoch != expected.Epoch || current.Domain?.RootDn is not { } root || expected.Domain?.RootDn is not { } previous
            || !DistinguishedName.AreEqual(root, previous) || !string.Equals(current.Account.Login, expected.Account.Login, StringComparison.OrdinalIgnoreCase))
        { throw new DomeniaOperationException(SearchErrors.ListUnknown, "Session modifiée pendant la lecture locale."); }
    }
}
