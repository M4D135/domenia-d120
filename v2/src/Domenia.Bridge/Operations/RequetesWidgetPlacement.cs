using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries;

namespace Domenia.Bridge;

public sealed partial class RequetesOperations
{
    private static async Task<PosteQueryPlacement> PlacePosteWidgetAsync(EngineContext context, QueryLibrary library, Session session,
        QueryWidgetLink widget, string fingerprint, CancellationToken token)
    {
        try
        {
            // The layout callback runs under the atomic preference writer. Never re-enter its read gate.
            var personal = await Domenia.Core.Accueil.ProfileProbeCatalog.ReadAsync(context.Preferences, token).ConfigureAwait(false);
            return await PosteQueryLayout.PlaceAsync(context.Preferences, session.Root, widget, fingerprint, () =>
            {
                var current = context.Directory.GetSessionAsync(token).GetAwaiter().GetResult();
                if (current.Domain?.RootDn is not { } root || !DistinguishedName.AreEqual(root, session.Root)
                    || current.Epoch != session.Snapshot.Epoch
                    || !string.Equals(current.Account.Login, session.Snapshot.Account.Login, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Session remplacée ; ajout au tableau refusé.");
                var content = library.ReadAsync(session.Root, token).GetAwaiter().GetResult();
                if (content.Unreadable > 0) throw new InvalidDataException("Bibliothèque partiellement illisible ; ajout au tableau refusé.");
                var record = content.Records.SingleOrDefault(r => r.Id == widget.RecipeId)
                    ?? throw new InvalidDataException("Requête du widget absente de la bibliothèque.");
                var recipe = QueryLibrary.RevisionRecipe(record, widget.BoundRevision)
                    ?? throw new InvalidDataException("Révision du widget absente de la bibliothèque.");
                QueryPersonalProbes.Confirm(QueryEngine.Compile(recipe), personal.Entries);
                return content;
            }, token, context.Clock.GetUtcNow()).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException or JsonException or QueryDefinitionException or DomeniaOperationException)
        {
            // The recipe/widget write has its own durable receipt. Never claim the second store was committed too.
            return new(false, context.Preferences.Persistent, "Widget conservé dans la bibliothèque ; ajout au tableau Poste non appliqué. " + ex.Message);
        }
    }
}
