using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Core;

/// <summary>A local calculation reference, never a credential, execution permission or collection request.</summary>
public sealed record BoardQueryBinding(string DomainKey, string RecipeId, long Revision, string Fingerprint,
    long ObservedRevision, string Name, bool CurrentRevisionProposed)
{
    // Only an explicit Atelier placement creates this link. D1 bindings remain pinned to their imported revision.
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? LibraryWidgetId { get; init; }
}

public static class BoardQueryBindings
{
    public static string Key(BoardQueryBinding binding) => "d1q-" + Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(
        new { binding.DomainKey, binding.RecipeId, binding.Revision, binding.Fingerprint })));

    public static bool Valid(BoardQueryBinding? binding, string key) => binding is not null && binding.RecipeId is { Length: > 0 and <= 80 }
        && binding.RecipeId.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.') && key.Length is > 0 and <= 80 && key.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.')
        && binding.Revision > 0 && binding.ObservedRevision >= binding.Revision
        && Hash(binding.DomainKey) && Hash(binding.Fingerprint) && binding.Name is { Length: > 0 and <= 200 }
        && !binding.Name.Any(char.IsControl) && key == Key(binding)
        && (binding.LibraryWidgetId is null || binding.LibraryWidgetId is { Length: 32 }
            && binding.LibraryWidgetId.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f')));

    private static bool Hash(string? text) => text is { Length: 64 } && text.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));

    public static (QueryLibraryRecord Record, CompiledQuery Query) Resolve(BoardQueryBinding binding, string key,
        QueryLibraryContent library, string rootDn, string board, Func<QueryRecipe, CompiledQuery>? compile = null)
    {
        if (!Valid(binding, key) || QueryLibrary.RootKey(rootDn) != binding.DomainKey)
        { throw new InvalidDataException("Liaison de requête invalide ou appartenant à un autre domaine."); }
        var record = library.Records.SingleOrDefault(r => r.Id == binding.RecipeId);
        if (record is null || record.Archived) { throw new InvalidDataException("Requête liée absente ou archivée ; aucun calcul courant."); }
        var recipe = QueryLibrary.RevisionRecipe(record, binding.Revision)
            ?? throw new InvalidDataException("Révision liée absente ; aucune révision courante choisie implicitement.");
        var fingerprint = record.Revision == binding.Revision ? record.Fingerprint
            : record.History.Single(h => h.Revision == binding.Revision).Fingerprint;
        var query = compile is null ? QueryEngine.Compile(recipe) : compile(recipe);
        if (fingerprint != binding.Fingerprint || query.Fingerprint != binding.Fingerprint)
        { throw new InvalidDataException("Empreinte de la révision liée modifiée ; aucun calcul."); }
        if (board == "Computer" && query.Target != QueryTarget.Computer)
        { throw new InvalidDataException("Cette requête ne porte pas sur les postes."); }
        return (record, query);
    }
}

public static partial class LegacyBoardLayouts
{
    public static void ConfirmPreview(LegacyBoardPreview before, LegacyBoardPreview current, string board)
    {
        var selected = current.Boards.Single(p => p.Board == board);
        var original = before.Boards.Single(p => p.Board == board);
        if (current.SourcePath != before.SourcePath || current.SourceSha256 != before.SourceSha256 || current.SourceKind != before.SourceKind
            || selected.State != "ready" || selected.TeamSource?.Sha256 != original.TeamSource?.Sha256
            || selected.QueryBindingsSha256 != original.QueryBindingsSha256)
        { throw new InvalidDataException("Sources D1 ou révisions liées modifiées pendant l’attente ; relisez l’aperçu avant d’importer."); }
    }

    /// <summary>Resolves only explicit Query rows from the settings. Library contents never create extra widgets.</summary>
    public static LegacyBoardPreview BindQueries(LegacyBoardPreview preview, QueryLibraryContent library, string rootDn)
    {
        LegacyBoardProposal Bind(LegacyBoardProposal proposal)
        {
            if (proposal.State != "needsQueryBinding") return proposal;
            try
            {
                var items = proposal.Items.Select(item =>
                {
                    if (item.Source != FleetWidgetSource.Query) return item;
                    var record = library.Records.SingleOrDefault(r => r.Id == item.Key)
                        ?? throw new InvalidDataException("Importez d’abord la recette D1 dans la bibliothèque D2 ; aucune recette n’est créée par une disposition.");
                    var links = library.Consumers.Where(c => c.Kind == "legacy" + proposal.Board && c.Id == item.Id && c.RecipeId == item.Key).ToArray();
                    if (links.Length > 1) throw new InvalidDataException("Plusieurs liaisons historiques concurrentes pour cette carte.");
                    var revision = links.Length == 1 ? links[0].BoundRevision : record.Revision;
                    var fingerprint = record.Revision == revision ? record.Fingerprint : record.History.SingleOrDefault(h => h.Revision == revision)?.Fingerprint
                        ?? throw new InvalidDataException("Révision D1 liée non importée dans la bibliothèque D2.");
                    var binding = new BoardQueryBinding(QueryLibrary.RootKey(rootDn), record.Id, revision, fingerprint,
                        record.Revision, record.Name, links.Length == 0);
                    var boundKey = BoardQueryBindings.Key(binding);
                    _ = BoardQueryBindings.Resolve(binding, boundKey, library, rootDn, proposal.Board);
                    return item with { Key = boundKey, QueryBinding = binding };
                }).ToImmutableArray();
                var digest = QueryBindingsSha(proposal.Board, items);
                return proposal with { State = "ready", Items = items, QueryBindingsSha256 = digest,
                    Summary = proposal.Summary + " Confirmez les révisions et empreintes affichées : elles seront liées à ces cartes, pour calcul local seulement."
                        + (items.Any(i => i.QueryBinding?.CurrentRevisionProposed == true)
                            ? " Certaines cartes D1 n’ont pas de liaison conservée : leur révision actuelle est proposée et nécessite votre confirmation explicite." : "") };
            }
            catch (Exception ex) when (ex is InvalidDataException or QueryDefinitionException or InvalidOperationException)
            { return proposal with { State = "incompatible", Count = 0, Items = [], Summary = ex.Message, QueryBindingsSha256 = null }; }
        }
        return preview with { Boards = [.. preview.Boards.Select(Bind)] };
    }

    public static string QueryBindingsSha(string board, IEnumerable<FleetLayoutItem> items) => Convert.ToHexStringLower(SHA256.HashData(
        JsonSerializer.SerializeToUtf8Bytes(new { board, bindings = items.Where(i => i.Source == FleetWidgetSource.Query)
            .Select(i => new { i.Id, i.Key, i.QueryBinding }).ToArray() }, Json)));
}
