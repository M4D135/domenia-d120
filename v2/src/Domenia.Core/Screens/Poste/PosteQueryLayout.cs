using System.Text.Json;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Core.Poste;

public sealed record PosteQueryPlacement(bool Applied, bool Persistent, string Summary);

/// <summary>Explicit placement of Atelier links. Ordinary saved recipes never create cards.</summary>
public static class PosteQueryLayout
{
    public static bool Contains(PosteLayoutView layout, string widgetId, string rootDn) => layout.Valid && layout.Items.Any(i =>
        i.Source == FleetWidgetSource.Query && i.QueryBinding is { } binding && binding.LibraryWidgetId == widgetId
        && binding.DomainKey == QueryLibrary.RootKey(rootDn));

    public static async Task<PosteQueryPlacement> PlaceAsync(IPreferenceStore preferences, string rootDn, QueryWidgetLink expected,
        string expectedFingerprint, Func<QueryLibraryContent> readLibrary, CancellationToken token, DateTimeOffset? now = null)
    {
        if (preferences is not IAtomicPreferenceStore atomic) throw new InvalidDataException("Cet environnement ne permet pas l’ajout atomique au tableau.");
        if (expected.Board != "computer") throw new InvalidDataException("Ce widget n’appartient pas au tableau Poste.");
        var alreadyPlaced = false;
        await atomic.UpdateAsync(PosteBoardLayouts.PreferenceKey("Computer"), current =>
        {
            token.ThrowIfCancellationRequested();
            var content = readLibrary(); // Requalify after waiting for the preference mutex, never while awaiting a UI decision.
            var widget = content.Widgets.SingleOrDefault(w => w.Id == expected.Id);
            if (widget is null || widget != expected) throw new InvalidDataException("Widget modifié pendant l’attente ; relisez la bibliothèque.");
            var record = content.Records.SingleOrDefault(r => r.Id == widget.RecipeId)
                ?? throw new InvalidDataException("Requête absente de la bibliothèque.");
            var binding = Binding(widget, record, rootDn);
            if (binding.Fingerprint != expectedFingerprint) throw new InvalidDataException("Révision modifiée pendant l’attente ; ajout refusé.");
            var key = BoardQueryBindings.Key(binding);
            _ = BoardQueryBindings.Resolve(binding, key, content, rootDn, "Computer");
            var items = PosteBoardLayouts.ReadForUpdate(current, "Computer");
            if (current is null)
            {
                // Before a custom layout exists, the real Poste page displays these explicit library widget links.
                // Preserve that visible set when first materializing its layout; ordinary library recipes add nothing.
                foreach (var shown in content.Widgets.Where(w => w.Board == "computer"))
                {
                    var shownRecord = content.Records.SingleOrDefault(r => r.Id == shown.RecipeId);
                    if (shownRecord is null || !QueryLibrary.Displayable(shown, shownRecord.Recipe.Target)) continue;
                    var shownBinding = Binding(shown, shownRecord, rootDn);
                    _ = BoardQueryBindings.Resolve(shownBinding, BoardQueryBindings.Key(shownBinding), content, rootDn, "Computer");
                    items = items.Add(Card(shown, shownBinding));
                }
            }
            var existing = items.SingleOrDefault(i => i.QueryBinding is { } linked && linked.LibraryWidgetId == widget.Id && linked.DomainKey == binding.DomainKey);
            alreadyPlaced = current is not null && existing is not null;
            if (existing is null) items = items.Add(Card(widget, binding));
            // Repeated clicks preserve the user's title, pause, group, visual and position; [] receives exactly this card.
            return PosteBoardLayouts.Next(current, "Computer", PosteBoardLayouts.Normalize("Computer", items), now ?? DateTimeOffset.UtcNow);
        }, token).ConfigureAwait(false);
        return new(true, preferences.Persistent, alreadyPlaced ? "Widget déjà présent ; ordre, titre, présentation et pause conservés."
            : preferences.Persistent ? "Widget ajouté à la disposition Poste." : "Widget ajouté au tableau Poste pour cette session.");
    }

    public static Task<JsonElement?> RemoveAsync(IPreferenceStore preferences, string rootDn, string widgetId, CancellationToken token, DateTimeOffset? now = null)
    {
        if (preferences is not IAtomicPreferenceStore atomic) throw new InvalidDataException("Retrait atomique de la carte indisponible.");
        return atomic.UpdateAsync(PosteBoardLayouts.PreferenceKey("Computer"), current => current is null ? null :
            PosteBoardLayouts.Next(current, "Computer", PosteBoardLayouts.ReadForUpdate(current, "Computer").Where(i =>
                i.QueryBinding is not { } linked || linked.LibraryWidgetId != widgetId || linked.DomainKey != QueryLibrary.RootKey(rootDn)).ToArray(), now ?? DateTimeOffset.UtcNow), token);
    }

    public static (BoardQueryBinding Binding, QueryLibraryRecord Record, CompiledQuery Query) Resolve(FleetLayoutItem item,
        QueryLibraryContent library, string rootDn)
    {
        var binding = item.QueryBinding;
        if (!BoardQueryBindings.Valid(binding, item.Key) || binding is null || binding.DomainKey != QueryLibrary.RootKey(rootDn))
            throw new InvalidDataException("Liaison de requête invalide ou appartenant à un autre domaine.");
        if (binding.LibraryWidgetId is { } id)
        {
            var widget = library.Widgets.SingleOrDefault(w => w.Id == id && w.Board == "computer" && w.RecipeId == binding.RecipeId)
                ?? throw new InvalidDataException("Widget retiré de l’atelier ; retirez sa carte ou ajoutez de nouveau le widget explicitement.");
            var record = library.Records.SingleOrDefault(r => r.Id == binding.RecipeId)
                ?? throw new InvalidDataException("Requête absente de la bibliothèque.");
            // The library's explicit revision migration is authoritative for native widgets; never choose record.Revision implicitly.
            binding = Binding(widget, record, rootDn);
        }
        var resolved = BoardQueryBindings.Resolve(binding, BoardQueryBindings.Key(binding), library, rootDn, "Computer");
        return (binding, resolved.Record, resolved.Query);
    }

    private static FleetLayoutItem Card(QueryWidgetLink widget, BoardQueryBinding binding) => new("q-" + widget.Id,
        FleetWidgetSource.Query, BoardQueryBindings.Key(binding), widget.Visual == "text" ? "Text" : "Verdict", "M", widget.Title, false, "Requêtes") { QueryBinding = binding };

    private static BoardQueryBinding Binding(QueryWidgetLink widget, QueryLibraryRecord record, string rootDn)
    {
        var hash = record.Revision == widget.BoundRevision ? record.Fingerprint
            : record.History.SingleOrDefault(h => h.Revision == widget.BoundRevision)?.Fingerprint
                ?? throw new InvalidDataException("Révision liée non conservée ; confirmez une nouvelle révision dans l’atelier.");
        return new(QueryLibrary.RootKey(rootDn), record.Id, widget.BoundRevision, hash, record.Revision, record.Name, false)
            { LibraryWidgetId = widget.Id };
    }
}
