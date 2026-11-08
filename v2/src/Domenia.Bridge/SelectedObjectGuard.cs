using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Common selected-object publication boundary. Index checks are local; no added network probe.</summary>
internal static class SelectedObjectGuard
{
    internal static OperationDefinition Bind(EngineContext context, OperationDefinition definition)
    {
        if (definition.Name is not ("fiche.read" or "relations.subject" or "assistance.subject.read")) return definition;
        var inner = definition.Handler;
        return definition with { Handler = async (args, bridge, token) =>
        {
            var before = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            using var selection = SelectionReadScope.Enter(context);
            var reader = context.Readers.Find<IFicheReader>();
            var dn = args.ValueKind == JsonValueKind.Object && args.TryGetProperty("dn", out var item) && item.ValueKind == JsonValueKind.String ? item.GetString() : null;
            if (dn is null && args.ValueKind == JsonValueKind.Object && args.TryGetProperty("ref", out item) && item.ValueKind == JsonValueKind.String
                && item.GetString() is { } reference && reference.Contains('=')) dn = reference;
            var previous = await Indexed(reader, dn, token).ConfigureAwait(false);
            var result = await inner(args, bridge, token).ConfigureAwait(false);
            var after = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            if (SelectionIdentity.ReaderKey(before) != SelectionIdentity.ReaderKey(after)) throw Changed();
            selection.RequireCurrent();
            var generation = selection.Generation;
            var identity = result switch
            {
                FicheSheet sheet => SelectionIdentity.Capture(before, Parse(sheet.Identity.Guid), sheet.Identity.Kind, sheet.Identity.Dn,
                    sheet.Identity.Name, sheet.Identity.Sam, sheet.Identity.Sid, generation),
                RelationSubjectView view => SelectionIdentity.Capture(before, Parse(view.Subject.Guid), view.Subject.Kind.ToString().ToLowerInvariant(),
                    view.Subject.Dn, view.Subject.Name, view.Subject.Login, previous?.Sid, generation),
                SubjectView view => SelectionIdentity.Capture(before, Parse(view.Card.Guid), view.Card.Kind.ToString().ToLowerInvariant(),
                    view.Card.Dn, view.Card.Name, view.Card.Login, previous?.Sid, generation),
                _ => null,
            };
            if (identity is null || previous is not null && previous.ObjectGuid != identity.ObjectGuid) throw Changed();
            var current = await Indexed(reader, identity.Dn, token).ConfigureAwait(false);
            if (previous is not null && current is null || current is not null && (current.ObjectGuid != identity.ObjectGuid
                || current.Kind.ToString().ToLowerInvariant() != identity.Kind
                || identity.Sid is not null && current.Sid is not null && !string.Equals(identity.Sid, current.Sid, StringComparison.OrdinalIgnoreCase))) throw Changed();
            // Index lookup can yield; check the account again before publishing the sealed object.
            if (SelectionIdentity.ReaderKey(before) != SelectionIdentity.ReaderKey(await context.Directory.GetSessionAsync(token).ConfigureAwait(false))) throw Changed();
            selection.RequireCurrent();
            return result switch
            {
                FicheSheet sheet => sheet with { Selection = identity },
                RelationSubjectView view => view with { Selection = identity },
                SubjectView view => view with { Selection = identity },
                _ => throw Changed(),
            };
        } };
    }
    private static Guid Parse(string value) => Guid.TryParse(value, out var id) ? id : Guid.Empty;
    private static async Task<FicheSummary?> Indexed(IFicheReader? reader, string? dn, CancellationToken token)
    {
        if (reader is null || dn is null) return null;
        var index = await reader.IndexAsync([dn], token).ConfigureAwait(false);
        var rows = index.Values.Where(v => DistinguishedName.AreEqual(v.Dn, dn)).Take(2).ToArray();
        if (rows.Length > 1) throw Changed();
        return rows.SingleOrDefault();
    }
    private static DomeniaOperationException Changed() => new("selection.changed", "Objet, compte ou session modifié ; résultat écarté. Relisez la sélection.");
}
