using System.Collections.Immutable;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Core.Accueil;

public sealed record FleetQuerySnapshot(QueryLibraryContent? Library, QueryDataset? Dataset, string? Problem);

/// <summary>Local evaluation only. Each chart part keeps the exact GUIDs of the snapshot used to calculate its count.</summary>
public static class FleetQueryWidgets
{
    public static FleetComputation Apply(FleetComputation computed, FleetBoardInput input, FleetQuerySnapshot? snapshot, CancellationToken token = default)
    {
        ArgumentNullException.ThrowIfNull(computed); ArgumentNullException.ThrowIfNull(input);
        var entries = computed.Board.Entries.ToImmutableSortedDictionary(StringComparer.Ordinal).ToBuilder(); var targets = computed.Targets.ToBuilder(); var labels = computed.TargetLabels.ToBuilder();
        foreach (var item in input.Layout.Where(i => i.Source == FleetWidgetSource.Query).DistinctBy(i => i.Key))
        {
            token.ThrowIfCancellationRequested();
            var key = "query:" + item.Key;
            FleetEntry Missing(string text, string title = "Calcul à préciser") => new(key, item.Title ?? "Requête enregistrée", "Requêtes", FleetDataKind.Value,
                title, null, null, text, Tone.Off, null, "Aucun résultat courant", [], [], null, null, null, false);
            if (snapshot?.Library is not { } library || snapshot.Dataset is not { } dataset)
            { entries[key] = Missing(snapshot?.Problem ?? "Bibliothèque non lue ; le widget reste conservé."); continue; }
            var link = library.Widgets.Concat(library.Records.SelectMany(r => r.ArchivedWidgets)).FirstOrDefault(w => w.Id == item.Key && w.Board == "fleet");
            var inherited = library.Consumers.Where(c => c.Kind == "legacyFleet" && (c.Id == item.Key || c.RecipeId == item.Key)).ToArray();
            var recipeId = link?.RecipeId ?? (inherited.Length == 1 ? inherited[0].RecipeId : null);
            var revision = link?.BoundRevision ?? (inherited.Length == 1 ? inherited[0].BoundRevision : 0);
            var record = library.Records.FirstOrDefault(r => r.Id == recipeId);
            if (record is null || revision < 1)
            { entries[key] = Missing("Lien ou requête absent de la bibliothèque. Retirez ce widget ou reliez explicitement une requête depuis le catalogue.", "Requête absente"); continue; }
            if (record.Archived)
            { entries[key] = Missing("Requête archivée : aucun résultat actuel. Son lien et ses révisions restent consultables dans l’atelier.", "Requête archivée"); continue; }
            var recipe = QueryLibrary.RevisionRecipe(record, revision);
            if (recipe is null)
            { entries[key] = Missing("La révision liée n’est plus conservée. Confirmez la révision actuelle depuis le catalogue."); continue; }
            try
            {
                var query = QueryEngine.Compile(recipe);
                var expectedHash = record.Revision == revision ? record.Fingerprint : record.History.First(h => h.Revision == revision).Fingerprint;
                if (query.Fingerprint != expectedHash) { throw new QueryDefinitionException("Empreinte de la révision liée non confirmée ; rien n’est calculé."); }
                var evaluation = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), input.Now);
                var all = QueryRecordBuilder.Build(dataset, query.Target, input.Scope, input.Now);
                var population = all.Where(r => query.InPopulation(r, evaluation)).ToImmutableArray();
                var states = population.Select(r => query.Evaluate(r, evaluation)).ToImmutableArray();
                var matched = population.Where((_, i) => states[i] == MatchState.Match).ToImmutableArray();
                var unknown = population.Where((_, i) => states[i] == MatchState.Unknown).ToImmutableArray();
                var noMatch = population.Where((_, i) => states[i] == MatchState.NoMatch).ToImmutableArray();
                var parts = ImmutableArray.CreateBuilder<FleetPart>();
                var computer = query.Target == QueryTarget.Computer;
                void Part(string suffix, string label, IReadOnlyList<QueryRecord> rows, Tone? tone)
                {
                    var targetKey = key + "|" + suffix;
                    var ids = computer ? rows.Select(r => Guid.Parse(r.Id)).ToImmutableArray() : [];
                    if (computer && ids.Any(g => !computed.Rows.ContainsKey(g))) { throw new QueryDefinitionException("Identité du calcul remplacée ; recalculez le tableau avant d’ouvrir les détails."); }
                    // Other target kinds remain readable; workstation drill-down is never fabricated for accounts or groups.
                    targets[targetKey] = ids; labels[targetKey] = label;
                    parts.Add(new FleetPart(label, rows.Count, tone, computer ? targetKey : "", computer ? rows.Count : 0));
                }
                Part("matched", "Correspondants", matched, Tone.Info);
                Part("unknown", "Inconnus", unknown, Tone.Off);
                Part("noMatch", "Non correspondants", noMatch, null);
                if (query.Resolved.GroupBy is not null && item.Visual is "Pie" or "Bar" or "Column")
                {
                    parts.Clear();
                    var groups = QueryAnalysis.Items(QueryAnalysis.Group(query, population, states), 10);
                    for (var i = 0; i < groups.Length; i++)
                    {
                        token.ThrowIfCancellationRequested(); var group = groups[i];
                        var segment = QueryEngine.Compile(QueryAnalysis.SegmentRecipe(recipe, group.Select));
                        var exact = matched.Where(r => segment.Evaluate(r, evaluation) == MatchState.Match).ToImmutableArray();
                        if (exact.Length != group.Value) { throw new QueryDefinitionException("Détails incomplets pour une part ; aucune répartition approximative publiée."); }
                        Part("group" + i, group.Label, exact, group.Select.Missing ? Tone.Off : null);
                    }
                }
                var coverage = QueryAnalysis.Coverage(query, population, evaluation);
                var dates = coverage.Sources.Select(c => c.Source + " : " + (c.Oldest is { } oldest ? oldest.ToString("u", System.Globalization.CultureInfo.InvariantCulture) : "non daté"));
                var detail = FrenchText.Integer(matched.Length) + " correspondants · " + FrenchText.Integer(unknown.Length) + " inconnus · " + FrenchText.Integer(noMatch.Length) + " non correspondants. "
                    + "Sources : " + string.Join(" ; ", dates) + "." + (computer ? "" : " Ouvrez l’atelier pour les détails des " + QueryTexts.TargetLabel(query.Target).ToLowerInvariant() + ".");
                var stale = revision != record.Revision;
                var subtitle = "Révision " + FrenchText.Integer(revision) + " · empreinte " + query.Fingerprint[..12] + " · " + FrenchText.Integer(coverage.Complete) + "/" + FrenchText.Integer(population.Length) + " couverts"
                    + (stale ? " · révision " + FrenchText.Integer(record.Revision) + " à confirmer" : "");
                var action = stale ? new FleetAction("queryConfirm:" + record.Id + ":" + record.Revision, "Confirmer la nouvelle révision", "Relit la bibliothèque et lie la révision affichée ; aucune collecte.") : null;
                entries[key] = new FleetEntry(key, item.Title ?? record.Name, "Requêtes", item.Visual is "Kpi" or "Text" ? FleetDataKind.Value : FleetDataKind.Distribution,
                    FrenchText.Integer(matched.Length), matched.Length, null, detail, unknown.Length > 0 || stale ? Tone.Warn : Tone.Info, null, subtitle,
                    parts.ToImmutable(), [], computer ? matched.Length : null, computer ? key + "|matched" : null, action, true);
            }
            catch (QueryDefinitionException ex)
            {
                foreach (var stale in targets.Keys.Where(k => k.StartsWith(key + "|", StringComparison.Ordinal)).ToArray()) { targets.Remove(stale); labels.Remove(stale); }
                entries[key] = Missing(ex.Message);
            }
        }
        return computed with { Board = computed.Board with { Entries = entries.ToImmutable() }, Targets = targets.ToImmutable(), TargetLabels = labels.ToImmutable() };
    }
}
