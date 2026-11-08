using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

public sealed record HomeQueryDraft(QueryRecipe Recipe, ScopeSelection Scope, string DomainDn, string Revision,
    DateTimeOffset At, string Account, int Count, bool Frozen, int Missing, string Note, bool Persisted, HomeQueryBase Base, int LocalComputers);

public sealed record HomeQueryBase(DateTimeOffset ReadAt, int Objects, bool Complete, string Source, bool Simulated);

public sealed partial class AccueilService
{
    /// <summary>Transfers the engine's full set, never the bounded rows of the drawer. Equivalent rules are checked
    /// against the displayed calculation; composite/custom figures keep an explicitly frozen GUID selection.</summary>
    public async Task<HomeQueryDraft> QueryDraftAsync(string revision, string key, CancellationToken token)
    {
        var selection = await SearchSelectionAsync(revision, key, token).ConfigureAwait(false);
        var dataset = await context.Readers.Require<IQueryWorkshopReader>().DatasetAsync(token).ConfigureAwait(false);
        if (!DistinguishedName.AreEqual(dataset.Directory.Domain.RootDn, selection.DomainDn))
            throw new DomeniaOperationException(BoardReplaced, BoardReplacedMessage);
        var records = QueryRecordBuilder.Build(dataset, QueryTarget.Computer, selection.Scope, selection.At);
        var recipe = HomeQueryRecipes.Resolve(key, selection.Label, selection.Guids, records, selection.At, selection.Account);
        _ = await SearchSelectionAsync(revision, key, token).ConfigureAwait(false);
        var workshop = QueryWorkshop.From(context);
        var persisted = await workshop.StoreScopeAsync(selection.DomainDn, selection.Scope, token).ConfigureAwait(false);
        if (workshop.StoredScope(selection.DomainDn) != selection.Scope)
            throw new DomeniaOperationException("query.scopeUnavailable", "Le périmètre de l’atelier n’a pas pu être retenu. Aucun aperçu élargi.");
        _ = await SearchSelectionAsync(revision, key, token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        var available = records.Select(r => r.Id).ToHashSet(StringComparer.Ordinal);
        var missing = selection.Guids.Count(id => !available.Contains(id.ToString("D")));
        var frozen = recipe.ObjectIds is not null;
        var note = (frozen ? "Sélection figée" : "Conditions équivalentes vérifiées") + " · " + selection.Label + " · "
            + FrenchText.Count(selection.Guids.Length, "poste", "postes") + " · calcul du "
            + selection.At.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss 'UTC'", CultureInfo.InvariantCulture) + " · " + selection.Account
            + (frozen ? ". Les nouveaux postes ne seront pas ajoutés à cette sélection." : ". Les prochains aperçus réévalueront ces conditions.")
            + (missing == 0 ? "" : " " + FrenchText.Count(missing, "identité absente du cache", "identités absentes du cache") + " ; GUID conservés sans remplacement.");
        return new(recipe, selection.Scope, selection.DomainDn, revision, selection.At, selection.Account,
            selection.Guids.Length, frozen, missing, note, persisted,
            new(dataset.Directory.ReadAt, dataset.Directory.ObjectCount, dataset.Directory.Complete, dataset.SourceLabel, dataset.Simulated), records.Length);
    }
}

internal static class HomeQueryRecipes
{
    internal static QueryRecipe Resolve(string key, string label, ImmutableArray<Guid> ids, ImmutableArray<QueryRecord> records,
        DateTimeOffset at, string account)
    {
        if (ids.Any(id => id == Guid.Empty) || ids.Distinct().Count() != ids.Length)
            throw new DomeniaOperationException("query.selectionInvalid", "Identités du calcul invalides ou répétées. Recalculez l’Accueil.");
        var candidate = Equivalent(key);
        if (candidate is not null)
        {
            var compiled = QueryEngine.Compile(candidate);
            var evaluation = new QueryEvaluationContext(null, at);
            var actual = records.Where(r => compiled.InPopulation(r, evaluation) && compiled.Evaluate(r, evaluation) == MatchState.Match)
                .Select(r => r.Id).ToHashSet(StringComparer.Ordinal);
            if (actual.SetEquals(ids.Select(id => id.ToString("D"))))
                return compiled.Normalized with { Name = Clip(label, QueryLimits.MaxNameLength) };
        }
        if (ids.Length > QueryLimits.MaxObjectIds)
            throw new DomeniaOperationException("query.selectionTooLarge", "Cette sélection figée dépasse 20 000 postes. Choisissez une OU plus précise ; aucune identité n’a été tronquée.");
        var name = "Sélection · " + Clip(label, 35) + " · " + at.UtcDateTime.ToString("yyyy-MM-dd HH:mm 'UTC'", CultureInfo.InvariantCulture) + " · " + Clip(account, 40);
        return QueryRecipe.Empty() with { Name = Clip(name, QueryLimits.MaxNameLength), ObjectIds = [.. ids.Select(id => id.ToString("D"))] };
    }

    // Only mappings with defined field semantics are offered. Policy-dependent health figures and folded « Autres »
    // remain frozen, rather than silently adopting a default threshold or a guessed translation.
    private static QueryRecipe? Equivalent(string key)
    {
        var split = key.IndexOf('|');
        var family = split < 0 ? key : key[..split];
        var value = split < 0 ? null : key[(split + 1)..];
        var active = new QueryClause("active", QueryOperator.Equal, QueryValue.FromBoolean(true));
        QueryRecipe Rule(params QueryClause[] clauses) => QueryRecipe.Empty() with { Clauses = [.. clauses] };
        QueryClause Equal(string field, string text) => new(field, QueryOperator.Equal, QueryValue.FromText(text));
        if (value is null)
            return family switch
            {
                "fleet.machines" or "fleet.accountstatus" => Rule(),
                "fleet.enabled" or "fleet.versions" or "fleet.os" or "fleet.servers" or "fleet.lastlogon" or "fleet.ou" => Rule(active),
                "fleet.disabled" => Rule(active with { Value = QueryValue.FromBoolean(false) }),
                "fleet.laps" => Rule(active, Equal("laps", "N")),
                "fleet.bitlocker" => Rule(active, Equal("bitlocker", "N")),
                "fleet.eos" => Rule(active, Equal("lifeStatus", "Ended")),
                "fleet.win10" => Rule(active, new("win10", QueryOperator.Equal, QueryValue.FromBoolean(true))),
                _ => null,
            };
        if (value == "Autres") return null;
        if (family == "fleet.accountstatus" && value is "Activés" or "Désactivés")
            return Rule(active with { Value = QueryValue.FromBoolean(value == "Activés") });
        var field = family switch
        {
            "fleet.os" => "osLabel", "fleet.versions" => "release", "fleet.servers" => "osFamily",
            "fleet.ou" => "site", "fleet.models" => "model", "fleet.releases" => "observedRelease",
            "fleet.presence" => "presenceBucket", _ => null,
        };
        return field is null ? null : Rule(active, Equal(field, value));
    }

    private static string Clip(string value, int length) => value.Length <= length ? value : value[..length];
}
