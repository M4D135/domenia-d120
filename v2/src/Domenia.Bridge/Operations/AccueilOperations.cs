using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Bridge;

/// <summary>
/// Operations of the home page beyond its ten widgets (docs/ops/accueil.md): fleet board of Domenia 1, exact sets, layout and
/// catalogs, explicit OU refresh, provenance, analysis, health rules, BitLocker presence, working OU root and favourites, first
/// steps, last view and session tools. Handlers validate the arguments and delegate to <see cref="AccueilService"/>.
/// </summary>
public sealed class AccueilOperations : IOperationModule
{
    private static readonly string[] TargetsArguments = ["revision", "key"];
    private static readonly string[] LayoutArguments = ["items"];
    private static readonly string[] LayoutItemNames = ["id", "source", "key", "visual", "size", "title", "paused", "group"];
    private static readonly string[] PresetArguments = ["preset"];
    private static readonly string[] IdArguments = ["id"];
    private static readonly string[] ModeArguments = ["mode"];
    private static readonly string[] PlanArguments = ["planId", "force"];
    private static readonly string[] CompareArguments = ["before", "after"];
    private static readonly string[] PivotArguments = ["table", "filter"];
    private static readonly string[] LabelArguments = ["label"];
    private static readonly string[] DnArguments = ["dn"];
    private static readonly string[] PolicyArguments = ["dn", "policy"];
    private static readonly string[] FavoriteArguments = ["name", "dn", "subtree"];
    private static readonly string[] DismissArguments = ["dismissed"];
    private static readonly string[] RevisionArguments = ["revision"];

    public string Screen => "accueil";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var service = AccueilService.From(context);
        service.AttachQueryLibrary(Operations.Requetes.RequetesServices.Library(context));
        return
        [
            // ---------------------------------------------------------------- board, exact sets, layout, catalogs
            new OperationDefinition("accueil.board", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.BoardAsync(ct).ConfigureAwait(false);
            }, "Tableau du parc de l’OU de travail, calculé depuis la base locale ; aucune lecture réseau."),

            new OperationDefinition("accueil.targets", OperationClass.LocalRead, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, TargetsArguments);
                var revision = Bounded(BridgeArguments.GetString(values, "revision"), "revision", 64);
                var key = Bounded(BridgeArguments.GetString(values, "key"), "key", 512);
                return Task.FromResult<object?>(service.Targets(revision, key));
            }, "Postes exacts d’un chiffre, depuis le calcul qui l’a produit."),

            new OperationDefinition("accueil.layout", OperationClass.LocalRead, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(service.Layout());
            }, "Disposition du tableau du parc."),

            new OperationDefinition("accueil.layout.save", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, LayoutArguments);
                if (!values.TryGetValue("items", out var items) || items.ValueKind != JsonValueKind.Array || items.GetArrayLength() > FleetCatalog.MaxItems)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("items") + " doit être une liste de 64 widgets au plus.");
                }
                return await service.SaveLayoutAsync([.. items.EnumerateArray().Select(LayoutItem)], ct).ConfigureAwait(false);
            }, "Mémorise la disposition du tableau du parc dans les préférences locales."),

            new OperationDefinition("accueil.layout.reset", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, PresetArguments);
                return await service.ResetLayoutAsync(BridgeArguments.GetOptionalString(values, "preset"), ct).ConfigureAwait(false);
            }, "Rétablit la disposition livrée ou applique une disposition prédéfinie."),

            new OperationDefinition("accueil.widgets.catalog", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.CatalogAsync(ct).ConfigureAwait(false);
            }, "Catalogue des widgets du parc et des sondes WMI."),

            new OperationDefinition("accueil.query.bind", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["id", "revision"]);
                var id = BridgeArguments.GetString(values, "id");
                if (!values.TryGetValue("revision", out var number) || number.ValueKind != JsonValueKind.Number || !number.TryGetInt64(out var revision) || revision < 1
                    || id.Length != 32 || !id.All(char.IsAsciiHexDigitLower)) { throw BridgeArguments.Invalid("Requête ou révision invalide."); }
                return await service.BindQueryAsync(id, revision, ct).ConfigureAwait(false);
            }, "Lie la révision affichée d’une requête au tableau ; écriture locale, aucune collecte."),

            new OperationDefinition("accueil.health.query", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["id", "revision"]);
                var id = BridgeArguments.GetString(values, "id");
                if (!values.TryGetValue("revision", out var number) || number.ValueKind != JsonValueKind.Number || !number.TryGetInt64(out var revision) || revision < 1
                    || id.Length != 32 || !id.All(char.IsAsciiHexDigitLower)) { throw BridgeArguments.Invalid("Requête ou révision invalide."); }
                return await service.FreezeHealthQueryAsync(id, revision, ct).ConfigureAwait(false);
            }, "Fige une requête sur les postes et son empreinte pour une alerte locale ; aucune collecte."),

            new OperationDefinition("accueil.probe", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, IdArguments);
                return Task.FromResult<object?>(AccueilService.Probe(Bounded(BridgeArguments.GetString(values, "id"), "id", 128)));
            }, "Contrat d’une sonde WMI : droits, coût, comportement, limites, sources et tests."),

            // ---------------------------------------------------------------- explicit refresh of the OU
            new OperationDefinition("accueil.refresh.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ModeArguments);
                return await service.PlanRefreshAsync(BridgeArguments.GetString(values, "mode"), ct).ConfigureAwait(false);
            }, "Plan d’une actualisation de l’OU, figé au clic ; rien n’est contacté."),

            // NetworkRead: AD read of the OU, ping and WMI of its workstations, after the operator's confirmation; bounded to the
            // working OU (never the domain root). Served by the fictitious directory in simulation.
            new OperationDefinition("accueil.refresh.run", OperationClass.NetworkRead, async (args, bridge, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, PlanArguments);
                var planId = BridgeArguments.GetString(values, "planId");
                if (planId.Length != 32 || !planId.All(char.IsAsciiHexDigitLower))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("planId") + " doit être un identifiant de plan (32 caractères hexadécimaux).");
                }
                var force = false;
                if (values.TryGetValue("force", out var f))
                {
                    force = f.ValueKind switch
                    {
                        JsonValueKind.True => true,
                        JsonValueKind.False => false,
                        _ => throw BridgeArguments.Invalid(FrenchText.Quote("force") + " doit être un booléen."),
                    };
                }
                return await service.RunRefreshAsync(planId, force, progress => bridge.Publish("progress", progress), ct).ConfigureAwait(false);
            }, "Exécute une fois un plan d’actualisation confirmé ; jamais rejoué. « force » relit aussi les postes déjà à jour.", ServedInSimulation: true),

            new OperationDefinition("accueil.refresh.stop", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(service.StopRefresh());
            }, "Arrête l’actualisation en cours ; les mesures déjà enregistrées sont conservées."),

            new OperationDefinition("accueil.refresh.state", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(service.RefreshStatus());
            }, "Actualisation en cours et dernier compte rendu de la session."),

            // ---------------------------------------------------------------- provenance, collections, analysis
            new OperationDefinition("accueil.provenance", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.ProvenanceAsync(ct).ConfigureAwait(false);
            }, "Fraîcheur de la base, mesures des postes actifs et horloges des relevés de l’OU."),

            new OperationDefinition("accueil.collections", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.CollectionsAsync(ct).ConfigureAwait(false);
            }, "Derniers relevés par OU (300 au plus)."),

            new OperationDefinition("accueil.analysis.snapshots", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.SnapshotsAsync(ct).ConfigureAwait(false);
            }, "Relevés quotidiens, instantanés manuels et vue actuelle de l’OU."),

            new OperationDefinition("accueil.analysis.compare", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, CompareArguments);
                return await service.CompareAsync(Bounded(BridgeArguments.GetString(values, "before"), "before", 64), Bounded(BridgeArguments.GetString(values, "after"), "after", 64), ct).ConfigureAwait(false);
            }, "Compare deux relevés : périmètre, couverture, règles et état observé."),

            new OperationDefinition("accueil.analysis.pivots", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, PivotArguments);
                var filter = BridgeArguments.GetOptionalString(values, "filter");
                if (filter is { Length: > 100 })
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("filter") + " doit faire au plus 100 caractères.");
                }
                return await service.PivotsAsync(Bounded(BridgeArguments.GetString(values, "table"), "table", 32), filter, ct).ConfigureAwait(false);
            }, "Tableau croisé du parc ; chaque cellule ouvre ses postes exacts."),

            // LocalWrite: the manual snapshot is kept in the local preferences of the application (counts and fingerprints only).
            new OperationDefinition("accueil.snapshot.take", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, LabelArguments);
                return await service.TakeSnapshotAsync(BridgeArguments.GetOptionalString(values, "label"), ct).ConfigureAwait(false);
            }, "Instantané manuel daté de la vue actuelle (avant ou après une campagne), gardé dans les préférences locales."),

            // ---------------------------------------------------------------- health rules
            new OperationDefinition("accueil.health.policy", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, DnArguments);
                return await service.HealthPolicyAsync(OptionalDn(values), ct).ConfigureAwait(false);
            }, "Règles de santé d’une portée, avec l’origine de chaque réglage."),

            new OperationDefinition("accueil.health.save", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, PolicyArguments);
                var dn = OptionalDn(values);
                if (!values.TryGetValue("policy", out var policy))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("policy") + " est obligatoire et doit être un objet.");
                }
                var current = (await service.HealthPolicyAsync(dn, ct).ConfigureAwait(false)).Policy;
                var parsed = HealthPolicyJson.ReadPolicy(policy, current, context.Clock.GetUtcNow());
                return await service.SaveHealthAsync(dn, parsed, ct).ConfigureAwait(false);
            }, "Enregistre les règles de santé d’une portée dans les préférences locales."),

            new OperationDefinition("accueil.health.revert", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, DnArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                return await service.RevertHealthAsync(dn, ct).ConfigureAwait(false);
            }, "Revient aux règles héritées pour une OU."),

            new OperationDefinition("accueil.health.exceptions", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.HealthExceptionsAsync(ct).ConfigureAwait(false);
            }, "Exceptions par OU du domaine."),

            new OperationDefinition("accueil.health.explain", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.ExplainAsync(ct).ConfigureAwait(false);
            }, "Comprendre le score : effet de chaque contrôle."),

            // ---------------------------------------------------------------- BitLocker presence
            new OperationDefinition("accueil.bitlocker.read", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.ReadBitLockerAsync(ct).ConfigureAwait(false);
            }, "Présence des clés de récupération BitLocker de l’OU de travail ; jamais une clé.", ServedInSimulation: true),

            // ---------------------------------------------------------------- working OU: root and favourites
            new OperationDefinition("accueil.scope.reset", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.ResetScopeAsync(ct).ConfigureAwait(false);
            }, "Revient à l’OU de travail par défaut (OU racine) et renvoie la session."),

            new OperationDefinition("accueil.favorites", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.FavoritesAsync(ct).ConfigureAwait(false);
            }, "OU favorites du domaine."),

            new OperationDefinition("accueil.favorite.save", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, FavoriteArguments);
                var name = BridgeArguments.GetString(values, "name");
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var subtree = BridgeArguments.GetBoolean(values, "subtree");
                return await service.SaveFavoriteAsync(name, dn, subtree, ct).ConfigureAwait(false);
            }, "Ajoute ou renomme une OU favorite (préférences locales)."),

            new OperationDefinition("accueil.favorite.drop", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, IdArguments);
                return await service.DropFavoriteAsync(Bounded(BridgeArguments.GetString(values, "id"), "id", 32), ct).ConfigureAwait(false);
            }, "Retire une OU favorite."),

            // ---------------------------------------------------------------- first steps, help, last view
            new OperationDefinition("accueil.firstSteps", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.FirstStepsAsync(ct).ConfigureAwait(false);
            }, "Premiers pas : connexion, OU, première lecture, tableau de bord."),

            new OperationDefinition("accueil.firstSteps.dismiss", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, DismissArguments);
                return await service.DismissFirstStepsAsync(BridgeArguments.GetBoolean(values, "dismissed"), ct).ConfigureAwait(false);
            }, "Masque ou réaffiche la carte des premiers pas."),

            new OperationDefinition("accueil.help.seen", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return new HelpSeenResult(await service.HelpSeenAsync(ct).ConfigureAwait(false));
            }, "Mémorise que l’aide de l’Accueil a été ouverte."),

            new OperationDefinition("accueil.lastView", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.LastViewAsync(ct).ConfigureAwait(false);
            }, "Dernière vue enregistrée pour la même base et la même OU."),

            new OperationDefinition("accueil.lastView.save", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, RevisionArguments);
                return await service.SaveLastViewAsync(Bounded(BridgeArguments.GetString(values, "revision"), "revision", 64), ct).ConfigureAwait(false);
            }, "Mémorise le résumé du calcul affiché pour le prochain démarrage."),

            // ---------------------------------------------------------------- session tools
            new OperationDefinition("accueil.selfCheck", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.SelfCheckAsync(ct).ConfigureAwait(false);
            }, "Vérifier l’application : session, base, préférences, reçus, catalogues."),

            new OperationDefinition("accueil.session.details", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.SessionDetailsAsync(ct).ConfigureAwait(false);
            }, "Détails de la session : liens utilisateur–poste, dernière vérification, derniers calculs, écritures locales."),

            new OperationDefinition("accueil.cache.clear", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(service.ClearCache());
            }, "Vide les caches de l’Accueil en mémoire ; aucune mesure perdue."),

            new OperationDefinition("accueil.journal", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.JournalAsync(ct).ConfigureAwait(false);
            }, "Journal des opérations de la session et de la source."),
        ];
    }

    private static string Bounded(string value, string name, int max) =>
        value.Length is > 0 && value.Length <= max && !value.Any(char.IsControl)
            ? value
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un texte de 1 à " + FrenchText.Integer(max) + " caractères.");

    private static string? OptionalDn(IReadOnlyDictionary<string, JsonElement> values)
    {
        var dn = BridgeArguments.GetOptionalString(values, "dn");
        return dn is null ? null : BridgeArguments.RequireDistinguishedName(dn, "dn");
    }

    private static FleetLayoutItem LayoutItem(JsonElement item)
    {
        if (item.ValueKind != JsonValueKind.Object)
        {
            throw BridgeArguments.Invalid("chaque widget doit être un objet.");
        }
        var values = BridgeArguments.ReadObject(item, LayoutItemNames);
        var source = BridgeArguments.GetString(values, "source") switch
        {
            "builtin" => FleetWidgetSource.Builtin,
            "probe" => FleetWidgetSource.Probe,
            "query" => FleetWidgetSource.Query,
            _ => throw BridgeArguments.Invalid(FrenchText.Quote("source") + " doit valoir builtin, probe ou query."),
        };
        var paused = values.TryGetValue("paused", out var p) && p.ValueKind == JsonValueKind.True;
        return new FleetLayoutItem(
            BridgeArguments.GetOptionalString(values, "id") ?? "",
            source,
            Bounded(BridgeArguments.GetString(values, "key"), "key", 128),
            BridgeArguments.GetOptionalString(values, "visual") ?? "",
            BridgeArguments.GetOptionalString(values, "size") ?? "M",
            BridgeArguments.GetOptionalString(values, "title"),
            paused,
            "");
    }

    /// <summary>Result of accueil.help.seen.</summary>
    public sealed record HelpSeenResult(bool HelpSeen);
}
