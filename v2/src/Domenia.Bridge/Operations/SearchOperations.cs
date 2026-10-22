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
    private static readonly string[] ArgsModeIdsContext = ["mode", "ids", "context"];
    private static readonly string[] ArgsSurveyContext = ["scope", "global", "hasTerm", "wholeDomain", "hasFilter", "coversList", "scopeLabel", "subtree", "listLimit"];
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
            new OperationDefinition("search.run", readClass, async (args, _, ct) =>
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
                return await service.RunAsync(text, scope, Type(values), Limit(values), match, ct).ConfigureAwait(false);
            }, "Recherche de la barre (domaine entier, ou une OU choisie), ou par adresse dans les relevés locaux."),

            new OperationDefinition("search.browse", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsDnSubtreeTypeLimit);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                return await service.BrowseAsync(dn, BridgeArguments.GetBoolean(values, "subtree"), Type(values), Limit(values), ct).ConfigureAwait(false);
            }, "Contenu d’une OU (ou du domaine, en liste seulement), avec son propre filtre vide."),

            new OperationDefinition("search.containers", readClass, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.ContainersAsync(ct).ConfigureAwait(false);
            }, "Conteneurs de la racine du domaine (Users, Computers, conteneurs système) pour l’arborescence."),

            new OperationDefinition("search.view", readClass, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsIdDnSubtreeWholeDomainLimit);
                var id = Identifier(values, "id");
                return await service.ViewAsync(id, OptionalDn(values, "dn"), BridgeArguments.GetBoolean(values, "subtree"), BridgeArguments.GetBoolean(values, "wholeDomain"), Limit(values), ct).ConfigureAwait(false);
            }, "Vue prête à l’emploi sur l’OU choisie (ou, explicitement, sur tout le domaine)."),

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

            new OperationDefinition("search.survey.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var (mode, ids, survey) = Survey(args);
                return await service.SurveyPlanAsync(mode, ids, survey, ct).ConfigureAwait(false);
            }, "Cibles exactes et confirmation chiffrée d’un relevé de la liste ; rien n’est lu."),

            new OperationDefinition("search.survey.run", OperationClass.NetworkRead, async (args, bridge, ct) =>
            {
                var (mode, ids, survey) = Survey(args);
                return await service.SurveyRunAsync(mode, ids, survey, progress => bridge.Publish("progress", progress), ct).ConfigureAwait(false);
            }, "Relevé de la liste confirmé (ping, utilisateur connecté, matériel), une seule fois, arrêt possible.", ServedInSimulation: true),

            new OperationDefinition("search.survey.stop", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsRunId);
                return Task.FromResult<object?>(service.Stop(Hex32(values, "runId")));
            }, "Arrêt du relevé en cours ; les mesures reçues sont conservées."),

            new OperationDefinition("search.recheck", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsId);
                return await service.RecheckAsync(Id(values, "id"), ct).ConfigureAwait(false);
            }, "Un ping et l’utilisateur connecté du seul poste sélectionné.", ServedInSimulation: true),

            new OperationDefinition("search.netdiag", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ArgsIds);
                return await service.DiagnoseAsync(Ids(values, "ids", 1, 500), ct).ConfigureAwait(false);
            }, "Diagnostic réseau groupé (ping puis ports 445, 135, 5985, 5986), 50 postes au plus ; aucun compte envoyé.", ServedInSimulation: true),

            new OperationDefinition("search.memory", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await memory.StateAsync(await DomainAsync(ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            }, "Recherches et objets récents, favoris d’OU, vues personnelles et favoris de requête du domaine."),

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

    private static (SurveyMode Mode, List<Guid> Ids, SurveyContext Context) Survey(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, ArgsModeIdsContext);
        if (!SearchSurvey.TryParseMode(BridgeArguments.GetString(values, "mode"), out var mode))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("mode") + " vaut ping, console, analyse, complete ou unaddressed.");
        }
        var ids = Ids(values, "ids", 1, MaxIds);
        if (!values.TryGetValue("context", out var raw) || raw.ValueKind != JsonValueKind.Object)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("context") + " est obligatoire et doit être un objet.");
        }
        var c = BridgeArguments.ReadObject(raw, ArgsSurveyContext);
        var scope = BridgeArguments.GetString(c, "scope") switch
        {
            "results" => SurveyScope.Results,
            "selection" => SurveyScope.Selection,
            _ => throw BridgeArguments.Invalid(FrenchText.Quote("scope") + " vaut results ou selection."),
        };
        var context = new SurveyContext(scope, OptionalBool(c, "global", false), OptionalBool(c, "hasTerm", false), OptionalBool(c, "wholeDomain", false),
            OptionalBool(c, "hasFilter", false), OptionalBool(c, "coversList", false), OptionalText(c, "scopeLabel", 200), OptionalBool(c, "subtree", true),
            Int(c, "listLimit", 0, 0, SearchLimits.MaxLimit));
        return (mode, ids, context);
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
