using System.Collections.Immutable;
using Domenia.Core.Queries;
using Domenia.Core.Accueil;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Core;

public sealed partial class SearchService
{
    private sealed record FrozenRecipe(SessionSnapshot Session, ImmutableArray<SearchRow> Rows, int Selected,
        SearchRecipeInfo Info, SearchVerdictTotals Totals, string Source, bool DirectoryComplete)
    {
        public ImmutableArray<FrozenProbe> PersonalProbes { get; init; } = [];
    }

    public async Task<SearchResult> RecipeAsync(QueryLibrary library, string id, long revision, string fingerprint,
        string dn, bool subtree, string verdict, int limit, CancellationToken token)
    {
        if (limit is < 1 or > SearchLimits.MaxLimit || verdict is not ("match" or "unknown" or "noMatch" or "all"))
        { throw new DomeniaOperationException(SearchErrors.ViewUnknown, "Limite ou verdict de recette invalide."); }
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        var root = session.Domain?.RootDn ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        var scopeDn = DistinguishedName.AreEqual(root, dn) ? root : await RequireBaseAsync(context.Readers.Require<ISearchReader>(), dn, root, token).ConfigureAwait(false);
        var content = await library.ReadAsync(root, token).ConfigureAwait(false);
        var stored = content.Records.SingleOrDefault(r => r.Id == id && !r.Archived)
            ?? throw new DomeniaOperationException(SearchErrors.ViewUnknown, "Recette absente ou archivée : rouvrez le catalogue.");
        if (stored.Revision != revision || stored.Fingerprint != fingerprint)
        { throw new DomeniaOperationException(SearchErrors.ViewUnknown, "La recette a changé depuis le catalogue : choisissez explicitement sa nouvelle révision."); }
        var compiled = QueryEngine.Compile(stored.Recipe);
        if (compiled.Target != QueryTarget.Computer || compiled.Fingerprint != fingerprint)
        { throw new DomeniaOperationException(SearchErrors.ViewUnknown, "Recherche attend une recette de postes avec une empreinte qualifiée."); }
        await QueryPersonalProbes.ConfirmAsync(compiled, context.Preferences, token).ConfigureAwait(false);
        var dataset = await context.Readers.Require<IQueryWorkshopReader>().DatasetAsync(token).ConfigureAwait(false);
        if (!DistinguishedName.AreEqual(dataset.Directory.Domain.RootDn, root))
        { throw new DomeniaOperationException(SearchErrors.ListUnknown, "Les données locales appartiennent à un autre domaine."); }
        var scope = new ScopeSelection(scopeDn, SearchTexts.Leaf(scopeDn), subtree);
        var at = context.Clock.GetUtcNow();
        // A domain root with subtree=false still means direct children. Do not inherit the workshop's domain shortcut.
        var records = QueryRecordBuilder.Build(dataset, QueryTarget.Computer, scope, at).Where(r => ScopeRules.Contains(scope, r.Dn));
        var evaluation = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), at);
        var candidates = new List<(QueryRecord Record, MatchState Verdict)>();
        var matched = 0; var unknown = 0; var noMatch = 0;
        foreach (var record in records)
        {
            token.ThrowIfCancellationRequested();
            if (!compiled.InPopulation(record, evaluation)) { continue; }
            var state = compiled.Evaluate(record, evaluation);
            if (state == MatchState.Match) { matched++; } else if (state == MatchState.Unknown) { unknown++; } else { noMatch++; }
            if (verdict == "all" || verdict == "match" && state == MatchState.Match || verdict == "unknown" && state == MatchState.Unknown || verdict == "noMatch" && state == MatchState.NoMatch)
            { candidates.Add((record, state)); }
        }
        var factory = new SearchRowFactory(dataset.Directory, dataset.Observations.Workstations, null, at);
        var computers = dataset.Directory.Computers.ToDictionary(c => c.ObjectGuid);
        var rows = candidates.OrderBy(c => c.Verdict == MatchState.Match ? 0 : c.Verdict == MatchState.Unknown ? 1 : 2)
            .ThenBy(c => FrenchText.Fold(c.Record.Name), StringComparer.Ordinal).ThenBy(c => c.Record.Id, StringComparer.Ordinal)
            .Take(SearchLimits.MaxLimit).Select(c => factory.Computer(computers[Guid.Parse(c.Record.Id)], verdict: c.Verdict switch
            { MatchState.Match => "Correspond", MatchState.Unknown => "Inconnu", _ => "Ne correspond pas" })).ToImmutableArray();
        var latest = await library.ReadAsync(root, token).ConfigureAwait(false);
        if (!latest.Records.Any(r => r.Id == id && !r.Archived && r.Revision == revision && r.Fingerprint == fingerprint))
        { throw new DomeniaOperationException(SearchErrors.ViewUnknown, "La recette a changé pendant le calcul : aucun résultat publié."); }
        await RequireRecipeSessionAsync(session, token).ConfigureAwait(false);
        await QueryPersonalProbes.ConfirmAsync(compiled, context.Preferences, token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        var sourceComplete = dataset.Directory.CoversScope(scope);
        var info = new SearchRecipeInfo(id, revision, fingerprint, root, verdict, at, sourceComplete);
        var coverage = "Base locale du " + QueryFormat.LocalDate(dataset.Directory.ReadAt, Zone) + " · "
            + (sourceComplete ? "copie d’annuaire complète pour ce périmètre" : "copie d’annuaire partielle : les objets absents restent inconnus")
            + " · observations et SELECT mémorisés évalués avec leurs dates ; aucune collecte lancée.";
        var totals = new SearchVerdictTotals(matched, unknown, noMatch, verdict switch { "match" => "Correspondants", "unknown" => "Inconnus", "noMatch" => "Non correspondants", _ => "Tous" }, null, coverage);
        var frozen = new FrozenRecipe(session, rows, candidates.Count, info, totals, dataset.SourceLabel, sourceComplete)
        { PersonalProbes = compiled.Probes.Definitions };
        var note = "Révision " + revision + " · empreinte " + fingerprint + " · calcul local figé. " + coverage;
        var whole = DistinguishedName.AreEqual(scopeDn, root);
        var view = new SearchViewInfo("recipe:" + id, stored.Name, note, whole, false, "Pour collecter les mesures manquantes, ouvrez cette recette dans l’atelier puis préparez explicitement sa collecte.");
        var plan = new SearchPlan(SearchPlanKind.LocalQuery, true, "", note, [], [], null, null, "", false, "");
        var stateList = Register(new ListState(SearchListKind.LocalQuery, plan, SearchTypeFilter.Computers, scopeDn, subtree, view.Id, "", SearchMatchMode.Prefix,
            SearchLists.Scope(false, scopeDn, root, session.Domain?.DnsName ?? root, subtree), view) { Recipe = frozen, Verdict = verdict });
        return RecipePage(stateList, Math.Min(limit, 10_000), false);
    }

    public async Task<SearchResult> RecipeMoreAsync(string listId, int target, CancellationToken token)
    {
        var state = RequireList(listId);
        var frozen = state.Recipe ?? throw new DomeniaOperationException(SearchErrors.ListUnknown, "Cette liste n’est pas un résultat de recette figé.");
        return await WithBusyAsync(state, async () =>
        {
            await RequireRecipeSessionAsync(frozen.Session, token).ConfigureAwait(false);
            await ProfileProbeCatalog.ConfirmAsync(context.Preferences, frozen.PersonalProbes, token).ConfigureAwait(false);
            if (target <= state.Loaded || target > SearchLimits.MaxLimit || state.Loaded >= frozen.Rows.Length)
            { throw new DomeniaOperationException(SearchErrors.ListComplete, "Aucune suite demandée dans les bornes du résultat figé."); }
            token.ThrowIfCancellationRequested();
            return RecipePage(state, Math.Min(target, state.Loaded + 10_000), true);
        }).ConfigureAwait(false);
    }

    private SearchResult RecipePage(ListState state, int target, bool appended)
    {
        var frozen = state.Recipe!;
        var page = frozen.Rows.Skip(state.Loaded).Take(Math.Max(0, target - state.Loaded)).ToImmutableArray();
        var more = state.Loaded + page.Length < frozen.Selected;
        var result = Complete(state, new(page, more, null, frozen.Info.At, frozen.Source), target, appended);
        var allowed = state.Loaded < frozen.Rows.Length;
        var next = Math.Min(frozen.Rows.Length, state.Loaded + 10_000);
        var counter = FrenchText.Count(state.Loaded, "poste affiché", "postes affichés") + " sur " + FrenchText.Integer(frozen.Selected) + " dans ce verdict · même calcul figé";
        return result with
        {
            Recipe = frozen.Info, Verdicts = frozen.Totals, Counter = counter,
            Complete = !more && frozen.DirectoryComplete,
            Absence = !frozen.DirectoryComplete ? "Copie locale partielle : l’absence d’un objet n’est pas établie."
                : more ? "Les objets au-delà de la limite ne sont pas affichés." : "Résultat complet sur les objets présents dans la copie locale.",
            Continuation = new(allowed, next, Math.Max(0, next - state.Loaded), 0, null, allowed ? "Lire la suite du même calcul local, sans réévaluer la recette." : more ? "20 000 postes au maximum ; réduisez le périmètre." : "Résultat figé entièrement affiché."),
        };
    }

    private async Task RequireRecipeSessionAsync(SessionSnapshot expected, CancellationToken token)
    {
        var actual = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        if (actual.Epoch != expected.Epoch || actual.Domain?.RootDn is not { } root || expected.Domain?.RootDn is not { } expectedRoot
            || !DistinguishedName.AreEqual(root, expectedRoot) || !string.Equals(actual.Account.Login, expected.Account.Login, StringComparison.OrdinalIgnoreCase))
        { throw new DomeniaOperationException(SearchErrors.ListUnknown, "La session ou le domaine a changé : le résultat précédent ne peut pas être réutilisé."); }
    }
}
