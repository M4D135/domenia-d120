using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Search screen (docs/ops/rechercher.md): the bar, the OU lists, the ready-made views and local queries, the explicit
/// continuation, suggestions, preview and comparison, the surveys of the list (plan, run, stop), the single recheck, the
/// network diagnostic, the reverse DNS and what the screen remembers (recents, OU favourites, personal views). Handlers only
/// validate the arguments and delegate to <see cref="SearchService"/> and <see cref="SearchMemory"/>. Directory reads are
/// LocalRead in simulation (fictitious directory in memory) and NetworkRead in directory mode; probes of workstations are
/// NetworkRead, served by the simulation; memory operations are LocalWrite (preferences only, never the directory).
/// </summary>
public sealed partial class SearchOperations : IOperationModule
{
    private static readonly string[] ArgsTextScopeTypeLimitMatch = ["text", "scope", "type", "limit", "match"];
    private static readonly string[] ArgsDnSubtreeTypeLimit = ["dn", "subtree", "type", "limit"];
    private static readonly string[] ArgsIdDnSubtreeWholeDomainLimit = ["id", "dn", "subtree", "wholeDomain", "limit"];
    private static readonly string[] ArgsIdDnSubtreeVerdictLimit = ["id", "dn", "subtree", "verdict", "limit"];
    private static readonly string[] ArgsListIdLimit = ["listId", "limit"];
    private static readonly string[] ArgsSelection = ["ids", "label", "at"];
    private static readonly string[] ArgsTextType = ["text", "type"];
    private static readonly string[] ArgsId = ["id"];
    private static readonly string[] ArgsIds = ["ids"];
    private static readonly string[] ArgsIp = ["ip"];
    private static readonly string[] ArgsRunId = ["runId"];
    private static readonly string[] ArgsKindTextTypeDn = ["kind", "text", "type", "dn"];
    private static readonly string[] ArgsDnNameSubtreeTypeTerm = ["dn", "name", "subtree", "type", "term"];
    private static readonly string[] ArgsDn = ["dn"];
    private static readonly string[] ArgsDnIndex = ["dn", "index"];
    private static readonly string[] ArgsIdFavorite = ["id", "favorite"];
    private static readonly string[] ArgsSurveyPlan = ["mode", "listId", "ids", "scope", "resume"];
    private static readonly string[] ArgsSurveyRun = ["planId", "typedCount"];
    private static readonly string[] ArgsRecheck = ["id", "mode", "listId", "onClick"];
    private static readonly string[] ArgsListIdIds = ["listId", "ids"];
    private static readonly string[] ArgsListId = ["listId"];
    private static readonly string[] ArgsListIdOffset = ["listId", "offset"];
    private static readonly string[] ArgsCounts = ["counts"];
    private static readonly string[] ArgsWorkspace = ["name", "dn", "subtree", "type", "presence", "filter", "limit", "columnSet", "layout"];
    private static readonly string[] ArgsLayout = ["order", "hidden", "widths", "sort", "density"];
    private static readonly string[] ArgsIdDir = ["id", "dir"];

    /// <summary>Most identifiers accepted from the page in one call (survey targets of a list).</summary>
    public const int MaxIds = 5000;

    public string Screen => "search";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var service = SearchService.From(context);
        var memory = SearchMemory.From(context);
        var readClass = context.Mode == AppMode.Simulation ? OperationClass.LocalRead : OperationClass.NetworkRead;
        var sourceLabel = context.Mode == AppMode.Simulation ? "Annuaire fictif" : "Annuaire en direct";
        async Task<DomainIdentity> DomainAsync(CancellationToken cancellationToken)
        {
            var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
            return session.Domain ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        }

        return
        [
            new OperationDefinition("search.run", readClass, async (args, bridge, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsTextScopeTypeLimitMatch);
                var text = Text(values, "text", SearchLimits.MaxTextLength);
                var scope = OptionalDn(values, "scope");
                var match = OptionalString(values, "match") switch
                {
                    null or "prefix" => SearchMatchMode.Prefix,
                    "contains" => SearchMatchMode.Contains,
                    _ => throw BridgeArguments.Invalid(FrenchText.Quote("match") + " vaut prefix ou contains."),
                };
                return await service.RunAsync(text, scope, Type(values), Limit(values), match, ct, cached => bridge.Publish("cached", cached)).ConfigureAwait(false);
            }, "Recherche de la barre (domaine entier, ou une OU choisie), ou par adresse dans les relevés locaux ; une recherche simple publie d’abord les lignes de la base locale."),

            new OperationDefinition("search.browse", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsDnSubtreeTypeLimit);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                return await service.BrowseAsync(dn, BridgeArguments.GetBoolean(values, "subtree"), Type(values), Limit(values), ct).ConfigureAwait(false);
            }, "Contenu d’une OU (ou du domaine, en liste seulement), avec son propre filtre vide."),

            new OperationDefinition("search.containers", readClass, async (args, _, ct) =>
            {
                var values = args.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null ? new Dictionary<string, JsonElement>() : BridgeArguments.ReadObject(args, ArgsCounts);
                return await service.ContainersAsync(OptionalBool(values, "counts", false), ct).ConfigureAwait(false);
            }, "Conteneurs de la racine du domaine (Users, Computers, conteneurs système) pour l’arborescence ; leurs objets ne sont comptés que sur demande."),

            new OperationDefinition("search.view", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsIdDnSubtreeWholeDomainLimit);
                var id = Identifier(values, "id");
                var dn = OptionalDn(values, "dn");
                var wholeDomain = BridgeArguments.GetBoolean(values, "wholeDomain");
                if (dn is null && !wholeDomain)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("dn") + " est obligatoire sans " + FrenchText.Quote("wholeDomain") + FrenchText.Colon + "tout le domaine est un choix explicite.");
                }
                return await service.ViewAsync(id, dn, BridgeArguments.GetBoolean(values, "subtree"), wholeDomain, Limit(values), ct).ConfigureAwait(false);
            }, "Vue prête à l’emploi sur l’OU choisie (ou, explicitement, sur tout le domaine)."),

            // REQ-048: the frozen selection of the query workshop (requetes.search.selection, read by the page), shown as a list
            // read from the local data only; 5 000 objects at most, never continued.
            new OperationDefinition("search.selection", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsSelection);
                var label = BridgeArguments.GetString(values, "label").Trim();
                if (label.Length is 0 or > 120)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("label") + " est le nom de la requête (1 à 120 caractères).");
                }
                var at = BridgeArguments.GetOptionalString(values, "at") is { } text && DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed)
                    ? parsed : context.Clock.GetUtcNow();
                return await service.SelectionAsync(Ids(values, "ids", 1, SearchLimits.MaxLimit), label, at, ct).ConfigureAwait(false);
            }, "Sélection figée de l’atelier de requêtes, lue dans les données locales (5 000 objets au plus)."),

            new OperationDefinition("search.localQuery", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsIdDnSubtreeVerdictLimit);
                var id = Identifier(values, "id");
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var verdict = OptionalString(values, "verdict") ?? SearchViews.Match;
                if (verdict is not (SearchViews.Match or SearchViews.Unknown or SearchViews.NoMatch or "all"))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("verdict") + " vaut match, unknown, noMatch ou all.");
                }
                return await service.LocalQueryAsync(id, dn, BridgeArguments.GetBoolean(values, "subtree"), verdict, Limit(values), ct).ConfigureAwait(false);
            }, "Requête locale sur les postes d’une OU (base locale)."),

            new OperationDefinition("search.more", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsListIdLimit);
                var listId = Hex32(values, "listId");
                var target = Int(values, "limit", null, 2, SearchLimits.MaxLimit);
                return await service.MoreAsync(listId, target, ct).ConfigureAwait(false);
            }, "Lignes suivantes d’une liste seulement, sans relire les lignes déjà chargées."),

            new OperationDefinition("search.suggest", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsTextType);
                var text = Text(values, "text", 100);
                return await service.SuggestAsync(text, Type(values), ct).ConfigureAwait(false);
            }, "Objets de la base locale pour le champ de recherche ; aucune requête d’annuaire."),

            new OperationDefinition("search.preview", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsId);
                return await service.PreviewAsync(Id(values, "id"), ct).ConfigureAwait(false);
            }, "Fiche enregistrée d’un objet, depuis la base locale."),

            new OperationDefinition("search.compare", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsIds);
                return await service.CompareAsync(Ids(values, "ids", SearchDetails.MinCompared, SearchDetails.MaxCompared), ct).ConfigureAwait(false);
            }, "Deux à huit objets d’un même type côte à côte, depuis la base locale."),

            new OperationDefinition("search.catalog", OperationClass.LocalRead, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(service.Catalog(memory.QueryFavorites(), sourceLabel));
            }, "Vues prêtes à l’emploi et requêtes locales, avec les favoris de requête."),

            new OperationDefinition("search.dns.reverse", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsIp);
                return await service.ReverseDnsAsync(Text(values, "ip", 15), ct).ConfigureAwait(false);
            }, "Résolution DNS inverse d’une adresse IPv4, sur le clic de l’opérateur.", ServedInSimulation: true),

            new OperationDefinition("search.revalidate", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsIds);
                return await service.RevalidateAsync(Ids(values, "ids", 1, 500), ct).ConfigureAwait(false);
            }, "Relecture des objets listés (500 au plus) ; une absence ne prouve pas une suppression."),

            new OperationDefinition("search.reconcile", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsListId);
                return await service.ReconcileAsync(Hex32(values, "listId"), ct).ConfigureAwait(false);
            }, "Relit la dernière liste explicite avec son filtre, sa portée et sa taille : nouveaux objets ajoutés, absents à revérifier, jamais supprimés."),

            new OperationDefinition("search.measures", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsListIdOffset);
                return await service.MeasuresAsync(Hex32(values, "listId"), Int(values, "offset", 0, 0, SearchLimits.MaxLimit), ct).ConfigureAwait(false);
            }, "Mesures enregistrées des lignes d’une liste, depuis la base locale, par pages de 250."),

            new OperationDefinition("search.preload", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsId);
                return await service.PreloadAsync(Id(values, "id"), ct).ConfigureAwait(false);
            }, "Relit la fiche de la seule ligne sélectionnée, pour l’aperçu et la ligne affichée."),

            new OperationDefinition("search.survey.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsSurveyPlan);
                if (!SearchSurvey.TryParseMode(BridgeArguments.GetString(values, "mode"), out var mode))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("mode") + " vaut ping, console, analyse, complete ou unaddressed.");
                }
                var resume = OptionalBool(values, "resume", false);
                List<Guid> ids = resume && !values.ContainsKey("ids") ? [] : Ids(values, "ids", 1, MaxIds);
                var scope = OptionalString(values, "scope") switch
                {
                    null or "results" => SurveyScope.Results,
                    "selection" => SurveyScope.Selection,
                    _ => throw BridgeArguments.Invalid(FrenchText.Quote("scope") + " vaut results ou selection."),
                };
                return await service.SurveyPlanAsync(mode, Hex32(values, "listId"), ids, scope, resume, ct).ConfigureAwait(false);
            }, "Cibles exactes et confirmation chiffrée d’un relevé des lignes d’une liste ; rien n’est lu, le plan vaut dix minutes pour un seul lancement."),

            new OperationDefinition("search.survey.run", OperationClass.NetworkRead, async (args, bridge, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsSurveyRun);
                int? typed = values.TryGetValue("typedCount", out var raw) && raw.ValueKind != JsonValueKind.Null ? Int(values, "typedCount", null, 0, MaxIds) : null;
                return await service.SurveyRunAsync(Hex32(values, "planId"), typed, progress => bridge.Publish("progress", progress), ct).ConfigureAwait(false);
            }, "Relevé confirmé d’un plan (ping, utilisateur connecté, matériel), une seule fois, arrêt possible.", ServedInSimulation: true),

            new OperationDefinition("search.survey.stop", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsRunId);
                return Task.FromResult<object?>(service.Stop(Hex32(values, "runId")));
            }, "Arrêt du relevé en cours ; les mesures reçues sont conservées."),

            new OperationDefinition("search.survey.state", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(service.SurveyState());
            }, "Plan de reprise du relevé interrompu et suspension des vérifications sur sélection."),

            new OperationDefinition("search.survey.forget", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(service.ForgetResume());
            }, "Abandonne le plan de reprise ; les mesures déjà validées restent."),

            new OperationDefinition("search.checks.resume", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(service.ResumeChecks());
            }, "Reprend les vérifications sur sélection suspendues après un compte distant refusé."),

            new OperationDefinition("search.recheck", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsRecheck);
                var mode = OptionalString(values, "mode") switch
                {
                    null or "console" => SurveyMode.Console,
                    "ping" => SurveyMode.Ping,
                    _ => throw BridgeArguments.Invalid(FrenchText.Quote("mode") + " vaut ping ou console."),
                };
                // The engine judges on the list shown (whole domain view, membership): listId is required.
                return await service.RecheckAsync(Id(values, "id"), mode, Hex32(values, "listId"), OptionalBool(values, "onClick", false), ct).ConfigureAwait(false);
            }, "Un ping (et l’utilisateur connecté) du seul poste sélectionné.", ServedInSimulation: true),

            new OperationDefinition("search.netdiag", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsListIdIds);
                return await service.DiagnoseAsync(Hex32(values, "listId"), Ids(values, "ids", 1, 500), ct).ConfigureAwait(false);
            }, "Diagnostic réseau groupé des lignes d’une liste (ping puis ports 445, 135, 5985, 5986), 50 postes au plus ; aucun compte envoyé.", ServedInSimulation: true),

            new OperationDefinition("search.policy", OperationClass.LocalRead, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(service.Policy());
            }, "Réglages de l’administrateur (Domenia.config.json : revalidation des objets listés, actions masquées ou grisées) et budgets des relevés (Paramètres)."),

            new OperationDefinition("search.memory", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                // First display of a domain: the saved searches of Domenia 1 become OU favourites once (RCH-004).
                var reader = context.Readers.Find<ISearchReader>();
                return await memory.StateAsync(await DomainAsync(ct).ConfigureAwait(false), ct,
                    reader is null ? null : reader.LegacySavedSearchesAsync).ConfigureAwait(false);
            }, "Recherches et objets récents, favoris d’OU, vues personnelles et favoris de requête du domaine ; reprise unique des recherches enregistrées de Domenia 1."),

            new OperationDefinition("search.recent.add", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsKindTextTypeDn);
                var kind = BridgeArguments.GetString(values, "kind");
                if (kind is not ("search" or "object"))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("kind") + " vaut search ou object.");
                }
                var text = Text(values, "text", SearchLimits.MaxTextLength);
                var type = OptionalText(values, "type", 40);
                var dn = OptionalDn(values, "dn");
                return await memory.AddRecentAsync(await DomainAsync(ct).ConfigureAwait(false), kind, text, type, dn, ct).ConfigureAwait(false);
            }, "Mémorise une recherche ou un objet récent (préférences locales)."),

            new OperationDefinition("search.recent.clear", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await memory.ClearRecentsAsync(await DomainAsync(ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            }, "Efface les recherches et objets récents du domaine (préférences locales)."),

            new OperationDefinition("search.favorite.pin", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsDnNameSubtreeTypeTerm);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var index = context.Readers.Find<IOrganizationalUnitIndex>();
                bool? exists = index is null ? null : await index.FindLocalAsync(dn, ct).ConfigureAwait(false) is not null;
                return await memory.PinAsync(await DomainAsync(ct).ConfigureAwait(false), dn, OptionalText(values, "name", 200), BridgeArguments.GetBoolean(values, "subtree"),
                    Type(values), OptionalText(values, "term", 200), exists, ct).ConfigureAwait(false);
            }, "Épingle une OU au-dessus de l’arbre (préférences locales, par domaine)."),

            new OperationDefinition("search.favorite.unpin", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsDn);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                return await memory.UnpinAsync(await DomainAsync(ct).ConfigureAwait(false), dn, ct).ConfigureAwait(false);
            }, "Retire une OU des favoris ; rien n’est changé dans l’annuaire."),

            new OperationDefinition("search.favorite.move", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsDnIndex);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                return await memory.MoveAsync(await DomainAsync(ct).ConfigureAwait(false), dn, Int(values, "index", null, 0, SearchMemoryRules.MaxFavorites), ct).ConfigureAwait(false);
            }, "Déplace un favori d’OU dans la liste."),

            new OperationDefinition("search.workspace.save", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var draft = Workspace(args);
                return await memory.SaveWorkspaceAsync(await DomainAsync(ct).ConfigureAwait(false), draft, ct).ConfigureAwait(false);
            }, "Enregistre une vue personnelle (OU, filtres, colonnes, tri), sans aucune ligne ni compte."),

            new OperationDefinition("search.workspace.remove", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsId);
                return await memory.RemoveWorkspaceAsync(await DomainAsync(ct).ConfigureAwait(false), Hex32(values, "id"), ct).ConfigureAwait(false);
            }, "Retire une vue personnelle ; « Annuler » la rétablit tant que les vues n’ont pas changé."),

            new OperationDefinition("search.workspace.undo", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await memory.UndoRemoveAsync(await DomainAsync(ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            }, "Rétablit la dernière vue retirée."),

            new OperationDefinition("search.query.favorite", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsIdFavorite);
                var id = BridgeArguments.GetString(values, "id");
                return await memory.SetQueryFavoriteAsync(await DomainAsync(ct).ConfigureAwait(false), id, BridgeArguments.GetBoolean(values, "favorite"), ct).ConfigureAwait(false);
            }, "Épingle ou retire une requête des favoris (200 au plus)."),
        ];
    }

    // ---------- Arguments ----------

    private static string Text(IReadOnlyDictionary<string, JsonElement> values, string name, int max)
    {
        var text = BridgeArguments.GetString(values, name);
        return text.Length <= max ? text : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit faire au plus " + FrenchText.Integer(max) + " caractères.");
    }

    private static string? OptionalText(IReadOnlyDictionary<string, JsonElement> values, string name, int max)
    {
        var text = BridgeArguments.GetOptionalString(values, name);
        return text is null || text.Length <= max ? text : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit faire au plus " + FrenchText.Integer(max) + " caractères.");
    }

    private static string? OptionalString(IReadOnlyDictionary<string, JsonElement> values, string name) => BridgeArguments.GetOptionalString(values, name);

    private static string? OptionalDn(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var dn = BridgeArguments.GetOptionalString(values, name);
        return dn is null ? null : BridgeArguments.RequireDistinguishedName(dn, name);
    }

    private static SearchTypeFilter Type(IReadOnlyDictionary<string, JsonElement> values) => OptionalString(values, "type") switch
    {
        null or "all" => SearchTypeFilter.All,
        "users" => SearchTypeFilter.Users,
        "computers" => SearchTypeFilter.Computers,
        "groups" => SearchTypeFilter.Groups,
        "ous" => SearchTypeFilter.Ous,
        _ => throw BridgeArguments.Invalid(FrenchText.Quote("type") + " vaut all, users, computers, groups ou ous."),
    };

    private static int Limit(IReadOnlyDictionary<string, JsonElement> values) => Int(values, "limit", SearchLimits.DefaultLimit, 1, SearchLimits.MaxLimit);

    /// <summary>Integer in [min ; max]; absent or null gives the default (required when the default is null).</summary>
    private static int Int(IReadOnlyDictionary<string, JsonElement> values, string name, int? fallback, int min, int max)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return fallback ?? throw BridgeArguments.Invalid(FrenchText.Quote(name) + " est obligatoire et doit être un entier.");
        }
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) && number >= min && number <= max)
        {
            return number;
        }
        throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un entier de " + FrenchText.Integer(min) + " à " + FrenchText.Integer(max) + ".");
    }

    private static bool OptionalBool(IReadOnlyDictionary<string, JsonElement> values, string name, bool fallback)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return fallback;
        }
        return value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit valoir true ou false.");
    }

    private static Guid Id(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var text = BridgeArguments.GetString(values, name);
        return text.Length == 36 && Guid.TryParseExact(text, "D", out var id)
            ? id
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un identifiant d’objet (GUID).");
    }

    private static List<Guid> Ids(IReadOnlyDictionary<string, JsonElement> values, string name, int min, int max)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind != JsonValueKind.Array)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " est obligatoire et doit être une liste d’identifiants.");
        }
        var count = value.GetArrayLength();
        if (count < min || count > max)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit compter de " + FrenchText.Integer(min) + " à " + FrenchText.Integer(max) + " identifiants.");
        }
        var list = new List<Guid>(count);
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String || item.GetString() is not string text || text.Length != 36 || !Guid.TryParseExact(text, "D", out var id))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit contenir des identifiants d’objet (GUID).");
            }
            list.Add(id);
        }
        return list;
    }

    private static string Hex32(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var text = BridgeArguments.GetString(values, name);
        return HexPattern().IsMatch(text) ? text : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un identifiant (32 caractères hexadécimaux).");
    }

    private static string Identifier(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var text = BridgeArguments.GetString(values, name);
        return IdentifierPattern().IsMatch(text) ? text : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un identifiant de vue ou de requête.");
    }

    private static SearchWorkspaceDraft Workspace(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, ArgsWorkspace);
        var name = Text(values, "name", 200);
        var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
        var presence = OptionalString(values, "presence") ?? "all";
        var columnSet = OptionalString(values, "columnSet") ?? "mixed";
        var filter = OptionalText(values, "filter", 200) ?? "";
        SearchLayout? layout = null;
        if (values.TryGetValue("layout", out var raw) && raw.ValueKind != JsonValueKind.Null)
        {
            layout = Layout(raw);
        }
        return new SearchWorkspaceDraft(name, dn, BridgeArguments.GetBoolean(values, "subtree"), Type(values), presence, filter, Limit(values), columnSet, layout);
    }

    private static SearchLayout Layout(JsonElement raw)
    {
        var values = BridgeArguments.ReadObject(raw, ArgsLayout);
        ImmutableArray<string> Strings(string name)
        {
            if (!values.TryGetValue(name, out var list) || list.ValueKind == JsonValueKind.Null)
            {
                return [];
            }
            if (list.ValueKind != JsonValueKind.Array || list.GetArrayLength() > 100 || list.EnumerateArray().Any(e => e.ValueKind != JsonValueKind.String))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être une liste de clés de colonnes.");
            }
            return [.. list.EnumerateArray().Select(e => e.GetString()!)];
        }
        var widths = ImmutableDictionary.CreateBuilder<string, int>(StringComparer.Ordinal);
        if (values.TryGetValue("widths", out var w) && w.ValueKind != JsonValueKind.Null)
        {
            if (w.ValueKind != JsonValueKind.Object)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("widths") + " doit être un objet.");
            }
            foreach (var p in w.EnumerateObject())
            {
                if (p.Value.ValueKind != JsonValueKind.Number || !p.Value.TryGetInt32(out var width) || widths.Count >= 100)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("widths") + " doit associer des clés de colonnes à des largeurs entières.");
                }
                widths[p.Name] = width;
            }
        }
        var sort = ImmutableArray.CreateBuilder<SearchSortKey>();
        if (values.TryGetValue("sort", out var s) && s.ValueKind != JsonValueKind.Null)
        {
            if (s.ValueKind != JsonValueKind.Array || s.GetArrayLength() > 4)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("sort") + " doit être une liste de quatre critères au plus.");
            }
            foreach (var item in s.EnumerateArray())
            {
                var key = BridgeArguments.ReadObject(item, ArgsIdDir);
                sort.Add(new SearchSortKey(BridgeArguments.GetString(key, "id"), Int(key, "dir", null, -1, 1)));
            }
        }
        return new SearchLayout(Strings("order"), Strings("hidden"), widths.ToImmutable(), sort.ToImmutable(), OptionalString(values, "density") ?? "normal");
    }

    [GeneratedRegex("^[0-9a-f]{32}$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex HexPattern();

    [GeneratedRegex(@"^[a-z][a-z0-9.]{0,60}$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex IdentifierPattern();
}
