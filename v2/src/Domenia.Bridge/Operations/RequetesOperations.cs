using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Ldap;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Bridge;

/// <summary>
/// Query workshop (« Atelier de requêtes », docs/ops/requetes.md): visual builder and LDAP text kept in sync, validation,
/// targets and scope, previews frozen with their definition, distributions, details and explanations, collection of the
/// missing measures, local library with revisions, widgets, packs, scripts, selection for Recherche, advanced WMI. Reads are
/// local (base or fictitious directory) unless stated; the network reads (collection, WMI) follow an explicit gesture and are
/// served by the fictitious directory in simulation. Library writes are LocalWrite (its own file, never the directory).
/// </summary>
public sealed class RequetesOperations : IOperationModule
{
    /// <summary>Longest text of one message from the page (the bridge refuses messages over 1 Mo): larger packs go in parts.</summary>
    public const int MaxPackLength = 900_000;

    /// <summary>Longest part of a pack sent in several messages (16 Mio in all, docs/ops/requetes.md § 3.6).</summary>
    public const int MaxPackPart = 400_000;

    public string Screen => "requetes";

    private sealed record Session(SessionSnapshot Snapshot, string Root, string Domain);

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var readers = context.Readers;
        var workshop = QueryWorkshop.From(context);
        var library = RequetesServices.Library(context);
        var exports = QueryExportStore.From(context);
        const OperationClass network = OperationClass.NetworkRead;

        async Task<Session> SessionAsync(CancellationToken ct)
        {
            var raw = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
            var session = await WorkingScope.From(context).ApplyAsync(raw, ct).ConfigureAwait(false);
            var root = session.Domain?.RootDn ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
            return new Session(session, root, session.Domain?.DnsName ?? root);
        }

        // Workstations follow the working OU; accounts and groups are read in the whole domain of the local base (as on the
        // Accueil), unless the workshop has an OU of its own. Every read stays local.
        ScopeSelection? ScopeFor(Session session, QueryTarget target) =>
            workshop.StoredScope(session.Root) ?? (target == QueryTarget.Computer ? session.Snapshot.Scope : null);

        async Task<(QueryDataset Dataset, ImmutableArray<QueryRecord> Records, ScopeSelection? Scope)> RecordsAsync(Session session, QueryTarget target, CancellationToken ct)
        {
            var dataset = await readers.Require<IQueryWorkshopReader>().DatasetAsync(ct).ConfigureAwait(false);
            var scope = ScopeFor(session, target);
            return (dataset, QueryRecordBuilder.Build(dataset, target, scope, context.Clock.GetUtcNow()), scope);
        }

        CompiledQuery Compile(QueryRecipe recipe)
        {
            try
            {
                return QueryEngine.Compile(recipe);
            }
            catch (QueryDefinitionException ex)
            {
                throw new DomeniaOperationException(QueryErrors.Invalid, ex.Message);
            }
        }

        object ScopeView(Session session, QueryDataset? dataset)
        {
            var stored = workshop.StoredScope(session.Root);
            var effective = stored ?? session.Snapshot.Scope;
            object? counts = null;
            if (dataset is not null)
            {
                var now = context.Clock.GetUtcNow();
                counts = new
                {
                    computer = QueryRecordBuilder.Build(dataset, QueryTarget.Computer, effective, now).Length,
                    user = QueryRecordBuilder.Build(dataset, QueryTarget.User, stored, now).Length,
                    group = QueryRecordBuilder.Build(dataset, QueryTarget.Group, stored, now).Length,
                };
            }
            return new
            {
                working = session.Snapshot.Scope,
                workshop = stored,
                effective,
                wholeDomain = effective is not null && ScopeRules.IsDomainRoot(effective, session.Root),
                accountsInDomain = stored is null,
                domain = new { dnsName = session.Domain, rootDn = session.Root },
                @base = dataset is null ? null : new { readAt = dataset.Directory.ReadAt, objects = dataset.Directory.ObjectCount, complete = dataset.Directory.Complete, source = dataset.SourceLabel, simulated = dataset.Simulated },
                counts,
            };
        }

        object Validation(QueryRecipe recipe)
        {
            var validation = QueryEngine.Validate(recipe);
            if (validation.Compiled is not { } compiled)
            {
                return new
                {
                    valid = false,
                    errors = validation.Errors,
                    warnings = validation.Warnings,
                    recipe,
                    fingerprint = (string?)null,
                    conditionCount = QueryRecipeWalk.Clauses(recipe).Count(),
                    summary = ImmutableArray<QuerySummaryLine>.Empty,
                    outline = ImmutableArray<QueryOutlineRow>.Empty,
                    parameters = ImmutableArray<QueryParameterRow>.Empty,
                    requested = ImmutableArray<string>.Empty,
                    clocks = ImmutableArray<string>.Empty,
                    ldap = (LdapTranslation?)null,
                    command = (string?)null,
                    format = recipe.Format,
                };
            }
            var now = context.Clock.GetUtcNow();
            var ldap = QueryLdap.Translate(compiled.Resolved, now);
            return new
            {
                valid = true,
                errors = validation.Errors,
                warnings = validation.Warnings,
                recipe = compiled.Normalized,
                fingerprint = (string?)compiled.Fingerprint,
                conditionCount = QueryRecipeWalk.Clauses(compiled.Normalized).Count(),
                summary = RequetesViews.Summary(compiled.Normalized),
                outline = QueryAnalysis.Outline(compiled.Normalized),
                parameters = QueryEngine.ParameterRows(compiled.Normalized),
                requested = compiled.RequestedFields,
                clocks = compiled.Clocks,
                ldap = (LdapTranslation?)ldap,
                command = (string?)QueryScript.Command(compiled, ldap, null),
                format = compiled.Normalized.MinimalFormat(),
            };
        }

        QueryPageView Page(QueryEvaluation evaluation, string verdict, string? text, string state, int offset, int limit, bool stale)
        {
            var columns = RequetesViews.Columns(evaluation.Query);
            var terms = (text ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(FrenchText.Fold).ToList();
            var selected = new List<QueryRowView>();
            var total = 0;
            for (var i = 0; i < evaluation.Population.Length; i++)
            {
                var record = evaluation.Population[i];
                var v = evaluation.Verdicts[i];
                if (verdict != "all" && QueryTexts.VerdictKey(v) != verdict)
                {
                    continue;
                }
                if (state == "active" && record.Active != true || state == "disabled" && record.Active != false)
                {
                    continue;
                }
                if (terms.Count > 0)
                {
                    var hay = FrenchText.Fold(record.Name + " " + record.Dn);
                    if (!terms.All(t => hay.Contains(t, StringComparison.Ordinal)))
                    {
                        continue;
                    }
                }
                total++;
                if (total > offset && selected.Count < limit)
                {
                    selected.Add(RequetesViews.Row(record, v, columns, evaluation.Query));
                }
            }
            return new QueryPageView([.. selected], total, offset, limit, offset + selected.Count < total, stale);
        }

        async Task<bool> StaleAsync(QueryEvaluation evaluation, CancellationToken ct)
        {
            var dataset = await readers.Require<IQueryWorkshopReader>().DatasetAsync(ct).ConfigureAwait(false);
            return dataset.Version != evaluation.Description.DatasetVersion;
        }

        static object? RowValue(QueryRecord record, string id) => record.Values.GetValueOrDefault(id);

        static object SaveView(QuerySaveResult saved) => new
        {
            id = saved.Record.Id,
            name = saved.Record.Name,
            category = saved.Record.Category,
            description = saved.Record.Description,
            revision = saved.Record.Revision,
            fingerprint = saved.Record.Fingerprint,
            recipe = saved.Record.Recipe,
            receipt = saved.Receipt,
            written = saved.Written,
            widget = saved.Widget,
            droppedWidgets = saved.Dropped,
            migratedWidgets = saved.Migrated,
            remote = RequetesViews.Remote(saved.Record.Recipe),
        };

        return
        [
            new OperationDefinition("requetes.catalog", OperationClass.Local, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = RequetesArgs.Optional(args, ["target"]);
                var target = RequetesArgs.Target(values);
                var fields = QueryCatalog.Fields(target);
                return (object?)new
                {
                    target = RequetesViews.TargetKey(target),
                    targets = new[] { new { id = "computer", label = QueryTexts.TargetLabel(QueryTarget.Computer) }, new { id = "user", label = QueryTexts.TargetLabel(QueryTarget.User) }, new { id = "group", label = QueryTexts.TargetLabel(QueryTarget.Group) } },
                    fields,
                    instanceFields = target == QueryTarget.Computer ? QueryCatalog.InstanceFields : [],
                    collections = target == QueryTarget.Computer ? QueryProbeCatalog.All.Where(p => p.Mode == "All").Select(p => new { id = QueryCatalog.ProbePrefix + p.Id, name = p.Category + " · " + p.Name, properties = p.Properties }).ToArray() : [],
                    ldapAttributes = LdapSchema.All.Select(a => new { name = a.Name, syntax = a.SyntaxLabel, read = a.ReadByDomenia, description = a.Description, example = a.Example }).ToArray(),
                    ldapFields = LdapSchema.All.Select(QueryCatalog.LdapAttributeField).ToArray(),
                    operators = Enum.GetValues<QueryOperator>().Select(o => new { id = JsonNamingPolicy.CamelCase.ConvertName(o.ToString()), label = QueryTexts.OperatorLabel(o) }).ToArray(),
                    categories = fields.Select(f => f.Category).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray(),
                    sources = new[] { new { id = "ad", label = "Annuaire AD" }, new { id = "local", label = "Calcul local" }, new { id = "observation", label = "Relevé du poste" }, new { id = "probe", label = "Sonde WMI" } },
                    limits = new { conditions = QueryLimits.MaxConditions, depth = QueryLimits.MaxTreeDepth, nodes = QueryLimits.MaxTreeNodes, parameters = QueryLimits.MaxParameters, name = QueryLimits.MaxNameLength, ldap = QueryLimits.MaxLdapLength, pack = QueryLibrary.MaxDocumentBytes, packPart = MaxPackPart },
                };
            }), "Catalogue des informations interrogeables d’une cible, opérateurs, attributs LDAP et limites."),

            new OperationDefinition("requetes.validate", OperationClass.Local, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe"]);
                return Validation(RequetesArgs.Recipe(values));
            }), "Valide un brouillon : erreurs, avertissements, forme normalisée, filtre LDAP, résumé et paramètres."),

            new OperationDefinition("requetes.ldap.read", OperationClass.Local, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["text", "recipe"]);
                var text = RequetesArgs.Text(values, "text", QueryLimits.MaxLdapLength);
                var current = RequetesArgs.Recipe(values);
                var reading = QueryLdap.Read(text, current);
                return reading.Valid ? new { reading.Valid, reading.Error, reading.Position, reading.Recipe, reading.Pretty, reading.Warnings, validation = Validation(reading.Recipe!) } : (object)new { reading.Valid, reading.Error, reading.Position, reading.Recipe, reading.Pretty, reading.Warnings, validation = (object?)null };
            }), "Lit un filtre LDAP saisi et le traduit en conditions de la requête (ou dit l’erreur et sa position)."),

            new OperationDefinition("requetes.value.preview", OperationClass.Local, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["target", "field", "text"]);
                var target = RequetesArgs.Target(values);
                var id = RequetesArgs.Text(values, "field", 200);
                var text = RequetesArgs.Text(values, "text", QueryLimits.MaxTextValue);
                var field = QueryCatalog.Find(target, id) ?? throw new DomeniaOperationException(QueryErrors.Invalid, QueryTexts.InvalidMessage("information inconnue."));
                return field.Kind == QueryFieldKind.Number ? QueryFormat.PreviewNumber(text, field) : new QueryNumberPreview(true, null, "");
            }), "Conversion d’unités en direct d’une valeur numérique saisie (8192 Mo = 8 Go, 48 h = 2 j)."),

            new OperationDefinition("requetes.scope", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var dataset = readers.Find<IQueryWorkshopReader>() is { } reader ? await reader.DatasetAsync(ct).ConfigureAwait(false) : null;
                return ScopeView(session, dataset);
            }, "Périmètre de l’atelier (OU de travail ou choix propre), date de la base et nombre d’objets par cible."),

            new OperationDefinition("requetes.scope.set", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["dn", "subtree"]);
                var dn = BridgeArguments.GetOptionalString(values, "dn");
                var subtree = RequetesArgs.Bool(values, "subtree", true);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                ScopeSelection? scope = null;
                if (dn is not null)
                {
                    BridgeArguments.RequireDistinguishedName(dn, "dn");
                    var candidate = new ScopeSelection(dn, dn, subtree);
                    if (ScopeRules.IsDomainRoot(candidate, session.Root))
                    {
                        scope = new ScopeSelection(session.Root, session.Domain, true);
                    }
                    else
                    {
                        if (!ScopeRules.Contains(new ScopeSelection(session.Root, session.Root, true), dn))
                        {
                            throw new DomeniaOperationException(DomeniaErrors.ScopeOutsideDomain, DomeniaErrors.ScopeOutsideDomainMessage);
                        }
                        var index = readers.Require<IOrganizationalUnitIndex>();
                        var entry = await index.FindLocalAsync(dn, ct).ConfigureAwait(false) ?? throw new DomeniaOperationException(DomeniaErrors.ScopeUnknown, DomeniaErrors.ScopeUnknownMessage);
                        scope = new ScopeSelection(entry.Dn, entry.Name, subtree);
                    }
                }
                var persisted = await workshop.StoreScopeAsync(session.Root, scope, ct).ConfigureAwait(false);
                context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Requêtes" + FrenchText.Colon + (scope is null ? "périmètre de l’atelier : OU de travail" : "périmètre de l’atelier : " + scope.Label + (scope.Subtree ? "" : " (sans sous-OU)")), Tone.Info));
                var dataset = await readers.Require<IQueryWorkshopReader>().DatasetAsync(ct).ConfigureAwait(false);
                return new { scope = ScopeView(session, dataset), persisted };
            }, "Choisit le périmètre propre à l’atelier (ou revient à l’OU de travail) ; mémorisé par domaine dans les préférences."),

            new OperationDefinition("requetes.preview", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe", "limit", "verdict"]);
                var recipe = RequetesArgs.Recipe(values);
                var limit = RequetesArgs.Int(values, "limit", 1, QueryLimits.MaxPreviewPage, QueryLimits.PreviewPage);
                var asked = RequetesArgs.Choice(values, "verdict", "auto", "auto", "all", "match", "unknown", "noMatch");
                var compiled = Compile(recipe);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var (dataset, records, scope) = await RecordsAsync(session, compiled.Target, ct).ConfigureAwait(false);
                var now = context.Clock.GetUtcNow();
                var evaluation = workshop.Evaluate(compiled, records, dataset, scope, now, session.Domain);
                // Domenia 1 opens the results on the matching objects (CmbQueryResult = Correspondants), all objects when none matches.
                var verdict = asked == "auto" ? (evaluation.Matched > 0 ? "match" : "all") : asked;
                var page = Page(evaluation, verdict, null, "all", 0, limit, false);
                QueryGroupsView? groups = null;
                if (evaluation.Groups is { } summary)
                {
                    groups = new QueryGroupsView(summary.Field, summary.FieldName, summary.Matched, summary.CategoryCount, summary.Missing, QueryAnalysis.Items(summary, 10));
                }
                var (one, many) = QueryTexts.Noun(compiled.Target);
                var text = FrenchText.Count(evaluation.Matched, "correspondant", "correspondants") + ", " + FrenchText.Count(evaluation.Unknown, "inconnu", "inconnus") + ", "
                    + FrenchText.Count(evaluation.NotMatched, "non correspondant", "non correspondants") + " sur " + FrenchText.Count(evaluation.Population.Length, one, many);
                context.Journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "aperçu « " + compiled.Recipe.Name + " » : " + text, Tone.Info));
                // Technical journal: counts only, never the name typed by the operator.
                context.Log.Info("Requêtes" + FrenchText.Colon + "aperçu calculé (" + text + ").");
                return new QueryPreviewView(evaluation.Id, now, compiled.Fingerprint, evaluation.Description,
                    new QueryCountsView(evaluation.Total, evaluation.Population.Length, evaluation.Matched, evaluation.Unknown, evaluation.NotMatched),
                    RequetesViews.Columns(compiled), page.Rows, page.HasMore, groups, evaluation.Ldap, QueryEngine.Validate(recipe).Warnings, text, verdict, page.Total);
            }).ConfigureAwait(false), "Aperçu local : évalue la requête sur les données locales du périmètre et garde le résultat figé."),

            new OperationDefinition("requetes.preview.page", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["evaluationId", "verdict", "text", "state", "offset", "limit"]);
                var evaluation = workshop.RequireEvaluation(RequetesArgs.Id32(values, "evaluationId"));
                var verdict = RequetesArgs.Choice(values, "verdict", "all", "all", "match", "unknown", "noMatch");
                var text = RequetesArgs.OptionalText(values, "text", 256);
                var state = RequetesArgs.Choice(values, "state", "all", "all", "active", "disabled");
                var offset = RequetesArgs.Int(values, "offset", 0, 10_000_000, 0);
                var limit = RequetesArgs.Int(values, "limit", 1, QueryLimits.MaxPreviewPage, QueryLimits.PreviewPage);
                return Page(evaluation, verdict, text, state, offset, limit, await StaleAsync(evaluation, ct).ConfigureAwait(false));
            }, "Page de résultats d’un aperçu figé, filtrée par verdict, texte et état de compte."),

            new OperationDefinition("requetes.preview.groups", OperationClass.LocalRead, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["evaluationId", "text", "offset", "limit"]);
                var evaluation = workshop.RequireEvaluation(RequetesArgs.Id32(values, "evaluationId"));
                var summary = evaluation.Groups ?? throw new DomeniaOperationException(QueryErrors.Invalid, QueryTexts.InvalidMessage("cette requête n’a pas de répartition."));
                var page = QueryAnalysis.Page(summary, RequetesArgs.Int(values, "offset", 0, 10_000_000, 0), RequetesArgs.Int(values, "limit", 1, QueryLimits.MaxGroupPage, QueryLimits.GroupPage), RequetesArgs.OptionalText(values, "text", 256));
                return new { field = summary.Field, fieldName = summary.FieldName, page, items = QueryAnalysis.Items(summary, 10) };
            }), "Répartition complète et exacte d’un aperçu figé, filtrable et paginée par 100."),

            new OperationDefinition("requetes.preview.object", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["evaluationId", "id"]);
                var evaluation = workshop.RequireEvaluation(RequetesArgs.Id32(values, "evaluationId"));
                var id = RequetesArgs.Guid(values, "id").ToString("D");
                var index = evaluation.IndexOf(id);
                if (index < 0)
                {
                    throw new DomeniaOperationException(QueryErrors.ObjectUnknown, QueryErrors.ObjectUnknownMessage);
                }
                return RequetesViews.Object(evaluation, evaluation.Population[index], evaluation.Verdicts[index], await StaleAsync(evaluation, ct).ConfigureAwait(false));
            }, "Fiche locale d’un objet de l’aperçu et « Pourquoi ce résultat ? » sur la définition figée."),

            new OperationDefinition("requetes.preview.segment", OperationClass.Local, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["evaluationId", "label", "missing", "value", "excluded"]);
                var evaluation = workshop.RequireEvaluation(RequetesArgs.Id32(values, "evaluationId"));
                var summary = evaluation.Groups ?? throw new DomeniaOperationException(QueryErrors.Invalid, QueryTexts.InvalidMessage("cette requête n’a pas de répartition."));
                var label = RequetesArgs.Text(values, "label", 200);
                var missing = RequetesArgs.Bool(values, "missing", false);
                var value = values.TryGetValue("value", out var raw) ? QueryRecipeJson.ReadValue(raw, "valeur") : QueryValue.None;
                ImmutableArray<QueryValue> excluded = values.TryGetValue("excluded", out var list) && list.ValueKind == JsonValueKind.Array
                    ? [.. list.EnumerateArray().Take(64).Select(e => QueryRecipeJson.ReadValue(e, "valeur exclue"))]
                    : [];
                var known = missing || summary.Categories.Any(c => c.Value.Invariant == value.Invariant) || excluded.Length > 0;
                if (!known)
                {
                    throw new DomeniaOperationException(QueryErrors.Invalid, "La répartition ne correspond plus à la requête affichée : relancez l’aperçu.");
                }
                var recipe = QueryAnalysis.SegmentRecipe(evaluation.Query.Normalized, new QueryGroupSelection(label, summary.Field, missing, value, excluded));
                return Validation(recipe);
            }), "Recette restreinte aux objets d’une valeur de répartition (segment ET), prête pour un nouvel aperçu."),

            new OperationDefinition("requetes.preview.export", OperationClass.Local, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["evaluationId", "verdict", "format"]);
                var evaluation = workshop.RequireEvaluation(RequetesArgs.Id32(values, "evaluationId"));
                var verdict = RequetesArgs.Choice(values, "verdict", "match", "all", "match", "unknown", "noMatch");
                var format = RequetesArgs.Choice(values, "format", "csv", "csv", "json");
                return QueryExports.Results(context, evaluation, verdict, format, context.Clock.GetUtcNow(), await StaleAsync(evaluation, ct).ConfigureAwait(false));
            }).ConfigureAwait(false), "Prépare l’export de tous les résultats d’un verdict (CSV « ; » ou JSON) et de ses métadonnées, sur l’aperçu figé : jeton, faits et extrait."),

            new OperationDefinition("requetes.export.content", OperationClass.Local, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["token"]);
                return QueryExports.Content(context, RequetesArgs.Id32(values, "token"));
            }), "Contenu complet d’un export préparé, pour le copier (la page n’écrit jamais de fichier elle-même)."),

            new OperationDefinition("requetes.export.save", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["token", "metadata"]);
                var token = RequetesArgs.Id32(values, "token");
                var export = exports.Require(token);
                var saved = await QueryExports.SaveAsync(context, token, RequetesArgs.Bool(values, "metadata", true), ct).ConfigureAwait(false);
                long? next = null;
                if (export.Kind == "pack" && export.PackId is { } packId)
                {
                    var session = await SessionAsync(ct).ConfigureAwait(false);
                    next = await library.ConfirmPackExportAsync(session.Root, packId, export.PackName ?? "", export.PackVersion, export.Rows, ct).ConfigureAwait(false);
                }
                return new { saved, nextVersion = next };
            }, "Enregistre un export préparé (et ses métadonnées) dans le dossier Exports des données de Domenia : lignes recomptées, écriture atomique, nom unique."),

            new OperationDefinition("requetes.coverage", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe", "coherenceHours"]);
                var compiled = Compile(RequetesArgs.Recipe(values));
                var hours = RequetesArgs.OptionalDecimal(values, "coherenceHours");
                if (hours is decimal h && (h <= 0 || h > QueryLimits.MaxCoherenceHours))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("coherenceHours") + " doit être compris entre 0 exclu et 8 760.");
                }
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var (dataset, records, _) = await RecordsAsync(session, compiled.Target, ct).ConfigureAwait(false);
                var evaluationContext = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), context.Clock.GetUtcNow());
                return QueryAnalysis.Coverage(compiled, records, evaluationContext, hours);
            }).ConfigureAwait(false), "Couverture des informations demandées, dates de chaque source et fenêtre commune proposée (aucune collecte)."),

            new OperationDefinition("requetes.collect.plan", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe", "cacheMinutes", "reuseDays"]);
                var compiled = Compile(RequetesArgs.Recipe(values));
                if (compiled.Target != QueryTarget.Computer || compiled.RequestedFields.All(f => QueryCatalog.Find(compiled.Target, f, compiled.Resolved.ReadDefinition) is not { Source: QuerySource.Observation or QuerySource.Probe or QuerySource.Instance or QuerySource.Detail }))
                {
                    throw new DomeniaOperationException(QueryErrors.CollectRefused, "La requête n’utilise que l’annuaire et les calculs locaux : rien à collecter sur les postes.");
                }
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var (dataset, records, scope) = await RecordsAsync(session, compiled.Target, ct).ConfigureAwait(false);
                ScopeRules.EnsureNotDomainRoot(scope, session.Root);
                var now = context.Clock.GetUtcNow();
                var evaluationContext = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), now);
                var plan = QueryAnalysis.CollectPlan(compiled, records, evaluationContext, now, RequetesArgs.Int(values, "cacheMinutes", 0, 1440, 15), RequetesArgs.Int(values, "reuseDays", 0, 3650, 0));
                var ticket = workshop.Keep(plan, compiled.Fingerprint);
                return new { ticket = ticket.Id, expiresAt = ticket.ExpiresAt, plan };
            }).ConfigureAwait(false), "Plan local des mesures manquantes, en erreur ou trop anciennes : postes, familles, sondes et coût compté (aucune lecture)."),

            new OperationDefinition("requetes.collect.run", network, async (args, bridge, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["ticket"]);
                var ticket = workshop.Take(RequetesArgs.Id32(values, "ticket")) ?? throw new DomeniaOperationException(QueryErrors.CollectRefused, "Plan de collecte inconnu, expiré ou déjà lancé : préparez-le de nouveau. Rien n’a été lu.");
                var plan = ticket.Plan;
                if (plan.Targets.Length == 0)
                {
                    return new { result = (QueryMeasureResult?)null, text = "Aucun poste à relire : toutes les mesures demandées sont à jour." };
                }
                bridge.Publish("progress", new { stage = "reading", label = "Relevé de " + FrenchText.Count(plan.Targets.Length, "poste", "postes") + " en cours" });
                var request = new QueryMeasureRequest([.. plan.Targets.Select(t => Guid.Parse(t.Id))], plan.Ping, plan.Console, plan.Inventory, plan.ProbeIds,
                    plan.Detail is { } detail ? [detail] : []);
                var result = await readers.Require<IQueryWorkshopReader>().MeasureAsync(request, ct).ConfigureAwait(false);
                var text = "Relevé terminé : " + FrenchText.Count(result.Answered, "poste lu", "postes lus") + ", " + FrenchText.Count(result.Failed, "sans réponse", "sans réponse")
                    + (result.SkippedDisabled > 0 ? ", " + FrenchText.Count(result.SkippedDisabled, "désactivé ignoré", "désactivés ignorés") : "") + ". Les anciennes valeurs des postes sans réponse restent datées de leur relevé.";
                context.Journal.Add(new JournalEntry(result.At, "Requêtes" + FrenchText.Colon + text, result.Failed > 0 ? Tone.Warn : Tone.Ok));
                return new { result = (QueryMeasureResult?)result, text };
            }, "Lance le relevé confirmé du plan : seuls les postes et mesures du plan sont lus, une fois.", ServedInSimulation: true),

            new OperationDefinition("requetes.collect.object", network, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["evaluationId", "id"]);
                var evaluation = workshop.RequireEvaluation(RequetesArgs.Id32(values, "evaluationId"));
                var guid = RequetesArgs.Guid(values, "id");
                if (evaluation.Query.Target != QueryTarget.Computer || evaluation.IndexOf(guid.ToString("D")) < 0)
                {
                    throw new DomeniaOperationException(QueryErrors.ObjectUnknown, QueryErrors.ObjectUnknownMessage);
                }
                if (await StaleAsync(evaluation, ct).ConfigureAwait(false))
                {
                    throw new DomeniaOperationException(QueryErrors.EvaluationUnknown, "L’aperçu n’est plus à jour : relancez-le avant d’actualiser ce poste.");
                }
                var probes = evaluation.Query.RequestedFields.Select(f => QueryCatalog.Find(QueryTarget.Computer, f)?.ProbeId).OfType<string>().Distinct(StringComparer.Ordinal).ToImmutableArray();
                var detailRead = evaluation.Query.Resolved.ReadDefinition;
                var result = await readers.Require<IQueryWorkshopReader>().MeasureAsync(new QueryMeasureRequest([guid], true, true, true, probes, detailRead is null ? [] : [detailRead]), ct).ConfigureAwait(false);
                var name = evaluation.Population[evaluation.IndexOf(guid.ToString("D"))].Name;
                var text = result.Answered > 0 ? name + " relevé : présence, inventaire" + (probes.Length > 0 ? ", " + FrenchText.Count(probes.Length, "sonde", "sondes") : "") + (detailRead is null ? "" : " et SELECT WMI enregistré") + " à jour." : name + " n’a pas répondu : ses anciennes valeurs restent datées de leur relevé.";
                context.Journal.Add(new JournalEntry(result.At, "Requêtes" + FrenchText.Colon + text, result.Answered > 0 ? Tone.Ok : Tone.Warn));
                return new { result, text };
            }, "Actualiser ce poste : relevé explicite du seul poste choisi (présence, inventaire et sondes de la requête).", ServedInSimulation: true),

            new OperationDefinition("requetes.object.test", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe", "id"]);
                var compiled = Compile(RequetesArgs.Recipe(values));
                var guid = RequetesArgs.Guid(values, "id");
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var dataset = await readers.Require<IQueryWorkshopReader>().DatasetAsync(ct).ConfigureAwait(false);
                var now = context.Clock.GetUtcNow();
                var record = compiled.Target == QueryTarget.Computer
                    ? QueryRecordBuilder.Computer(dataset, guid, now)
                    : QueryRecordBuilder.Build(dataset, compiled.Target, null, now).FirstOrDefault(r => r.Id == guid.ToString("D"));
                if (record is null)
                {
                    throw new DomeniaOperationException(QueryErrors.ObjectUnknown, "Objet introuvable dans les données locales : rien n’a été évalué.");
                }
                var evaluationContext = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), now);
                var scope = ScopeFor(session, compiled.Target);
                var inScope = scope is null || ScopeRules.Contains(scope, record.Dn) || ScopeRules.IsDomainRoot(scope, session.Root);
                var inPopulation = compiled.InPopulation(record, evaluationContext);
                var verdict = compiled.Evaluate(record, evaluationContext);
                var label = !inPopulation ? "Hors sélection (segment ou sélection figée)" : verdict switch
                {
                    MatchState.Match => "Correspond",
                    MatchState.NoMatch => "Ne correspond pas",
                    _ => "Inconnu : une information manque ou n’est pas exploitable",
                };
                return new { id = record.Id, name = record.Name, dn = record.Dn, verdict = inPopulation ? QueryTexts.VerdictKey(verdict) : "outside", label, inScope, explanation = compiled.Explain(record, evaluationContext) };
            }).ConfigureAwait(false), "Teste le brouillon sur un seul objet, sans lecture réseau ni collecte."),

            new OperationDefinition("requetes.objects.find", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["text", "target"]);
                var text = FrenchText.Fold(RequetesArgs.Text(values, "text", 100).Trim());
                var target = RequetesArgs.Target(values);
                var dataset = await readers.Require<IQueryWorkshopReader>().DatasetAsync(ct).ConfigureAwait(false);
                var now = context.Clock.GetUtcNow();
                var found = QueryRecordBuilder.Build(dataset, target, null, now)
                    .Where(r => text.Length > 0 && FrenchText.Fold(r.Name + " " + (RowValue(r, "sam") as string ?? "")).Contains(text, StringComparison.Ordinal))
                    .OrderBy(r => FrenchText.Fold(r.Name), StringComparer.Ordinal).Take(20)
                    .Select(r => new { id = r.Id, name = r.Name, dn = r.Dn, active = r.Active, os = RowValue(r, "os") as string, presence = RowValue(r, "presenceBucket") as string }).ToArray();
                return found;
            }, "Au plus 20 objets de la base locale dont le nom contient le texte (choix d’un poste à tester ou à interroger)."),

            new OperationDefinition("requetes.library.list", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["search", "category", "source", "target", "offset", "limit", "sort"]);
                var search = RequetesArgs.OptionalText(values, "search", 256) ?? "";
                var category = RequetesArgs.OptionalText(values, "category", 120);
                var source = RequetesArgs.Choice(values, "source", "all", "all", "templates", "personal", "archives");
                var sort = RequetesArgs.Choice(values, "sort", "name", "name", "recent");
                var targetFilter = values.ContainsKey("target") ? RequetesViews.TargetKey(RequetesArgs.Target(values)) : null;
                var offset = RequetesArgs.Int(values, "offset", 0, 1_000_000, 0);
                var limit = RequetesArgs.Int(values, "limit", 1, 5000, 100);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var content = await library.ReadAsync(session.Root, ct).ConfigureAwait(false);
                var rows = new List<QueryLibraryRowView>();
                foreach (var record in content.Records)
                {
                    rows.Add(new QueryLibraryRowView(record.Id, record.Name, record.Category, record.Archived ? "archive" : "personal", record.Archived ? "Archive" : "Mes requêtes",
                        RequetesViews.TargetKey(record.Recipe.Target), RequetesViews.Informations(record.Recipe), record.Description, record.Revision, record.UpdatedAt, record.Archived,
                        RequetesViews.Remote(record.Recipe), RequetesViews.ProvenanceText(record.Provenance), content.Widgets.Count(w => w.RecipeId == record.Id)));
                }
                foreach (var template in QueryTemplates.All)
                {
                    rows.Add(new QueryLibraryRowView(template.Recipe.Id, template.Recipe.Name, template.Category, "template", "Modèle livré", RequetesViews.TargetKey(template.Recipe.Target),
                        RequetesViews.Informations(template.Recipe), template.Description, 0, null, false, RequetesViews.Remote(template.Recipe), "Modèle livré avec Domenia.", 0));
                }
                var terms = search.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(FrenchText.Fold).ToList();
                var filtered = rows.Where(r => source switch
                    {
                        "templates" => r.Source == "template",
                        "personal" => r.Source == "personal",
                        "archives" => r.Source == "archive",
                        _ => r.Source != "archive",
                    })
                    .Where(r => targetFilter is null || r.Target == targetFilter)
                    .Where(r => category is null || string.Equals(r.Category, category, StringComparison.Ordinal))
                    .Where(r => terms.All(t => FrenchText.Fold(r.Name + " " + r.Category + " " + r.Description + " " + r.Informations).Contains(t, StringComparison.Ordinal)));
                var ordered = sort == "recent"
                    ? filtered.OrderBy(r => r.Source == "template" ? 1 : 0).ThenByDescending(r => r.UpdatedAt ?? DateTimeOffset.MinValue).ThenBy(r => FrenchText.Fold(r.Name), StringComparer.Ordinal).ToList()
                    : filtered.OrderBy(r => r.Source == "template" ? 1 : 0).ThenBy(r => FrenchText.Fold(r.Category), StringComparer.Ordinal).ThenBy(r => FrenchText.Fold(r.Name), StringComparer.Ordinal).ToList();
                var categories = rows.Where(r => targetFilter is null || r.Target == targetFilter).Select(r => r.Category).Distinct(StringComparer.Ordinal).OrderBy(FrenchText.Fold, StringComparer.Ordinal).ToImmutableArray();
                return new QueryLibraryListView([.. ordered.Skip(offset).Take(limit)], rows.Count, ordered.Count, offset, limit, categories, content.Unreadable, library.Persistent);
            }).ConfigureAwait(false), "Bibliothèque : modèles livrés, requêtes personnelles et archives, recherche sans accents, catégories, tri par nom ou par date (100 récentes), pages."),

            new OperationDefinition("requetes.library.get", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["id"]);
                var id = RequetesArgs.RecipeId(values, "id");
                if (QueryTemplates.Find(id) is { } template)
                {
                    return new QueryLibraryDetailView(id, template.Recipe.Name, template.Category, "template", template.Description, 0, null, false, template.Recipe, [], null,
                        "Modèle livré avec Domenia : il se copie en requête personnelle à l’enregistrement.", RequetesViews.Sources(template.Recipe), RequetesViews.Collection(template.Recipe), [],
                        RequetesViews.Summary(template.Recipe), [], [], QueryEngine.Compile(template.Recipe).Fingerprint);
                }
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var content = await library.ReadAsync(session.Root, ct).ConfigureAwait(false);
                var record = content.Records.FirstOrDefault(r => r.Id == id) ?? throw new DomeniaOperationException(QueryErrors.NotFound, QueryErrors.NotFoundMessage);
                return new QueryLibraryDetailView(record.Id, record.Name, record.Category, record.Archived ? "archive" : "personal", record.Description, record.Revision, record.UpdatedAt, record.Archived,
                    record.Recipe, [.. record.History.Select(h => new QueryRevisionView(h.Revision, h.SavedAt, h.Fingerprint))], record.Provenance, RequetesViews.ProvenanceText(record.Provenance),
                    RequetesViews.Sources(record.Recipe), RequetesViews.Collection(record.Recipe), [.. content.Widgets.Where(w => w.RecipeId == id)], RequetesViews.Summary(record.Recipe),
                    record.ArchivedWidgets, [.. content.Consumers.Where(c => c.RecipeId == id)], record.Fingerprint);
            }).ConfigureAwait(false), "Détail d’usage d’une requête : description, sources, collecte, provenance déclarée, révisions, widgets (et widgets retirés par l’archivage), éléments liés."),

            new OperationDefinition("requetes.library.impact", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["id", "recipe"]);
                var id = RequetesArgs.RecipeId(values, "id");
                var draft = values.ContainsKey("recipe") ? RequetesArgs.Recipe(values) : null;
                var session = await SessionAsync(ct).ConfigureAwait(false);
                return await library.ImpactAsync(session.Root, id, draft, workshop.Search?.RecipeId, ct).ConfigureAwait(false);
            }).ConfigureAwait(false), "Revue d’impact avant modification ou archivage : widgets liés, liens qui ne pourront plus s’afficher, favoris et sélection de Recherche, règles de santé, différences."),

            new OperationDefinition("requetes.library.save", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe", "category", "description", "expectedRevision", "mode"]);
                var recipe = RequetesArgs.Recipe(values);
                var expected = RequetesArgs.Long(values, "expectedRevision", 0, long.MaxValue - 1);
                var mode = RequetesArgs.Choice(values, "mode", "update", "update", "copy", "migrate");
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var saved = await library.SaveAsync(session.Root, recipe, RequetesArgs.OptionalText(values, "category", 80), RequetesArgs.OptionalText(values, "description", 500), expected, mode, null, ct).ConfigureAwait(false);
                context.Log.Info($"Requêtes{FrenchText.Colon}requête {saved.Record.Id} enregistrée (révision {saved.Record.Revision}).");
                return SaveView(saved);
            }).ConfigureAwait(false), "Enregistre la requête dans la bibliothèque locale (nouvelle révision, copie ou mise à jour des widgets liés après la revue d’impact) avec un reçu relu sur le disque."),

            new OperationDefinition("requetes.library.archive", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["id", "expectedRevision"]);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var (record, receipt, removed) = await library.ArchiveAsync(session.Root, RequetesArgs.RecipeId(values, "id"), RequetesArgs.Long(values, "expectedRevision", 0, long.MaxValue - 1), ct).ConfigureAwait(false);
                context.Log.Info($"Requêtes{FrenchText.Colon}requête {record.Id} archivée (révision {record.Revision}).");
                return new { id = record.Id, name = record.Name, revision = record.Revision, receipt, removedWidgets = removed };
            }).ConfigureAwait(false), "Archive une requête (révisions conservées) et retire ses widgets dans la même écriture ; ils restent attachés à l’archive pour une restauration."),

            new OperationDefinition("requetes.library.restore", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["id", "expectedRevision", "restoreWidgets"]);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var (record, receipt, restored) = await library.RestoreAsync(session.Root, RequetesArgs.RecipeId(values, "id"), RequetesArgs.Long(values, "expectedRevision", 0, long.MaxValue - 1),
                    RequetesArgs.Bool(values, "restoreWidgets", true), ct).ConfigureAwait(false);
                context.Log.Info($"Requêtes{FrenchText.Colon}requête {record.Id} restaurée (révision {record.Revision}).");
                return new { id = record.Id, name = record.Name, revision = record.Revision, recipe = record.Recipe, receipt, restoredWidgets = restored };
            }).ConfigureAwait(false), "Restaure une requête archivée avec une nouvelle révision, et les widgets que son archivage avait retirés."),

            new OperationDefinition("requetes.library.revert", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["id", "revision", "expectedRevision", "mode"]);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var saved = await library.RevertAsync(session.Root, RequetesArgs.RecipeId(values, "id"), RequetesArgs.Long(values, "revision", 1, long.MaxValue - 1),
                    RequetesArgs.Long(values, "expectedRevision", 1, long.MaxValue - 1), RequetesArgs.Choice(values, "mode", "update", "update", "migrate"), ct).ConfigureAwait(false);
                return SaveView(saved);
            }).ConfigureAwait(false), "Restaure une révision précédente d’une requête comme nouvelle révision (les widgets liés suivent seulement avec « migrate »)."),

            new OperationDefinition("requetes.widget.save", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe", "board", "visual", "title", "expectedRevision", "category", "mode"]);
                var recipe = RequetesArgs.Recipe(values);
                var widget = new QueryWidgetRequest(RequetesArgs.Choice(values, "board", "fleet", "fleet", "computer"), RequetesArgs.Choice(values, "visual", "kpi", "kpi", "text", "bar", "pie", "column"),
                    RequetesArgs.Text(values, "title", 80));
                var mode = RequetesArgs.Choice(values, "mode", "update", "update", "copy", "migrate");
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var saved = await library.SaveAsync(session.Root, recipe, RequetesArgs.OptionalText(values, "category", 80), null, RequetesArgs.Long(values, "expectedRevision", 0, long.MaxValue - 1), mode, widget, ct)
                    .ConfigureAwait(false);
                context.Log.Info($"Requêtes{FrenchText.Colon}requête {saved.Record.Id} enregistrée (révision {saved.Record.Revision}).");
                return SaveView(saved);
            }).ConfigureAwait(false), "Enregistre la requête et son widget dans la même écriture ; une définition modifiée qui a déjà des widgets exige le choix de la revue d’impact (mise à jour ou copie)."),

            new OperationDefinition("requetes.widget.list", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                BridgeArguments.RequireNone(args);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var content = await library.ReadAsync(session.Root, ct).ConfigureAwait(false);
                return content.Widgets.Select(w =>
                {
                    var record = content.Records.FirstOrDefault(r => r.Id == w.RecipeId);
                    var displayable = record is not null && QueryLibrary.Displayable(w, record.Recipe.Target);
                    var state = record is null ? "Requête absente de la bibliothèque"
                        : record.Archived ? "Requête archivée"
                        : !displayable ? "Ne peut plus s’afficher : la requête ne porte plus sur les postes"
                        : w.BoundRevision < record.Revision ? "Lié à la révision " + FrenchText.Integer(w.BoundRevision) + " : confirmez la mise à jour"
                        : "Révision " + FrenchText.Integer(record.Revision) + " évaluée";
                    return new
                    {
                        w.Id, w.RecipeId, recipeName = record?.Name, w.Board, w.Visual, w.Title, w.BoundRevision, currentRevision = record?.Revision, state, displayable,
                        warn = record is null || record.Archived || !displayable || w.BoundRevision < record.Revision, w.CreatedAt,
                    };
                }).ToArray();
            }).ConfigureAwait(false), "Widgets de requêtes enregistrés, avec la révision qu’ils évaluent et leur état."),

            new OperationDefinition("requetes.widget.evaluate", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["id", "computer"]);
                var id = RequetesArgs.Id32(values, "id");
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var content = await library.ReadAsync(session.Root, ct).ConfigureAwait(false);
                var widget = content.Widgets.FirstOrDefault(w => w.Id == id) ?? throw new DomeniaOperationException(QueryErrors.NotFound, "Widget introuvable : il a été retiré. Rien n’a été évalué.");
                var record = content.Records.FirstOrDefault(r => r.Id == widget.RecipeId)
                    ?? throw new DomeniaOperationException(QueryErrors.NotFound, "Requête du widget absente de la bibliothèque : le widget ne peut pas être évalué.");
                var recipe = QueryLibrary.RevisionRecipe(record, widget.BoundRevision)
                    ?? throw new DomeniaOperationException(QueryErrors.RevisionChanged, "Révision liée (" + FrenchText.Integer(widget.BoundRevision) + ") plus conservée : confirmez la mise à jour du widget.");
                var compiled = Compile(recipe);
                var now = context.Clock.GetUtcNow();
                var (dataset, records, scope) = await RecordsAsync(session, compiled.Target, ct).ConfigureAwait(false);
                var evaluationContext = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), now);
                var (one, many) = QueryTexts.Noun(compiled.Target);
                object? computer = null;
                if (widget.Board == "computer")
                {
                    var guid = RequetesArgs.Guid(values, "computer");
                    var single = QueryRecordBuilder.Computer(dataset, guid, now) ?? throw new DomeniaOperationException(QueryErrors.ObjectUnknown, QueryErrors.ObjectUnknownMessage);
                    var inPopulation = compiled.InPopulation(single, evaluationContext);
                    var state = inPopulation ? compiled.Evaluate(single, evaluationContext) : MatchState.NoMatch;
                    computer = new { id = single.Id, name = single.Name, verdict = inPopulation ? QueryTexts.VerdictKey(state) : "outside", explanation = compiled.Explain(single, evaluationContext) };
                }
                var population = records.Where(r => compiled.InPopulation(r, evaluationContext)).ToImmutableArray();
                var verdicts = population.Select(r => compiled.Evaluate(r, evaluationContext)).ToImmutableArray();
                var matched = verdicts.Count(v => v == MatchState.Match);
                var unknown = verdicts.Count(v => v == MatchState.Unknown);
                var groups = compiled.Resolved.GroupBy is null ? null : QueryAnalysis.Group(compiled, population, verdicts);
                return new
                {
                    widget.Id, widget.Title, widget.Visual, widget.Board, widget.BoundRevision, currentRevision = record.Revision, needsConfirmation = widget.BoundRevision < record.Revision,
                    archived = record.Archived, recipeName = record.Name, evaluatedAt = now, scope = scope?.Label ?? session.Domain,
                    counts = new { total = records.Length, population = population.Length, matched, unknown, noMatch = population.Length - matched - unknown },
                    groups = groups is null ? null : new { field = groups.Field, fieldName = groups.FieldName, items = QueryAnalysis.Items(groups, 10) },
                    text = FrenchText.Count(matched, one, many) + " sur " + FrenchText.Integer(population.Length) + (unknown > 0 ? ", " + FrenchText.Count(unknown, "inconnu", "inconnus") : ""),
                    computer,
                };
            }).ConfigureAwait(false), "Évalue un widget (la révision qu’il lie) sur les données locales : chiffres, répartition et, pour la fiche d’un poste, le verdict de ce poste."),

            new OperationDefinition("requetes.widget.remove", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["id"]);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                return new { removed = await library.UnlinkWidgetAsync(session.Root, RequetesArgs.Id32(values, "id"), ct).ConfigureAwait(false) };
            }).ConfigureAwait(false), "Retire un widget de requête (la requête reste dans la bibliothèque)."),

            new OperationDefinition("requetes.consumer.bind", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["kind", "id", "recipeId", "title", "scope"]);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var scope = RequetesArgs.OptionalText(values, "scope", BridgeArguments.MaxDistinguishedNameLength);
                return await library.BindConsumerAsync(session.Root, RequetesArgs.Choice(values, "kind", "search", "search", "health"), RequetesArgs.Text(values, "id", 64),
                    RequetesArgs.RecipeId(values, "recipeId"), RequetesArgs.Text(values, "title", 120), scope, ct).ConfigureAwait(false);
            }).ConfigureAwait(false), "Déclare un élément d’un autre écran qui utilise une requête enregistrée (favori de Recherche, règle de Santé) : listé par la revue d’impact."),

            new OperationDefinition("requetes.consumer.release", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["kind", "id"]);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                return new { released = await library.ReleaseConsumerAsync(session.Root, RequetesArgs.Choice(values, "kind", "search", "search", "health"), RequetesArgs.Text(values, "id", 64), ct).ConfigureAwait(false) };
            }).ConfigureAwait(false), "Retire la déclaration d’un élément qui utilisait une requête."),

            new OperationDefinition("requetes.pack.version", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["name"]);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                return new { version = await library.ProposedVersionAsync(session.Root, RequetesArgs.Text(values, "name", 80), ct).ConfigureAwait(false) };
            }).ConfigureAwait(false), "Version proposée pour le prochain export d’un pack (elle avance quand le fichier est enregistré)."),

            new OperationDefinition("requetes.pack.export", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["name", "version", "ids", "origin"]);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var name = RequetesArgs.Text(values, "name", 80);
                var pack = await library.ExportPackAsync(session.Root, session.Root, name, RequetesArgs.Long(values, "version", 1, 1_000_000),
                    RequetesArgs.Strings(values, "ids", 5000, 80), RequetesArgs.OptionalText(values, "origin", 256), ct).ConfigureAwait(false);
                var text = "Pack « " + name.Trim() + " » version " + pack.Version.ToString(CultureInfo.InvariantCulture) + " : " + FrenchText.Count(pack.Count, "requête", "requêtes")
                    + ". La version proposée passera à " + pack.NextVersion.ToString(CultureInfo.InvariantCulture) + " une fois le fichier enregistré.";
                return QueryExports.Prepare(context, "pack", pack.FileName, pack.Json, pack.Count, "application/json", text, pack, name.Trim());
            }).ConfigureAwait(false), "Prépare le pack JSON Domenia.QueryPack/3 nommé, versionné et à empreinte de contenu des requêtes personnelles choisies (5 000 recettes, 16 Mio)."),

            new OperationDefinition("requetes.pack.part", OperationClass.Local, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["upload", "index", "count", "text"]);
                var count = RequetesArgs.Int(values, "count", 1, 64, 1);
                var index = RequetesArgs.Int(values, "index", 0, count - 1, 0);
                var upload = index == 0 ? null : RequetesArgs.Id32(values, "upload");
                var (id, received, chars) = exports.Part(upload, index, count, RequetesArgs.Text(values, "text", MaxPackPart));
                return new { upload = id, received, count, chars };
            }), "Reçoit une partie d’un pack trop gros pour un seul message (400 000 caractères par partie, 16 Mio en tout), dans l’ordre."),

            new OperationDefinition("requetes.pack.examine", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["content", "upload"]);
                var content = values.ContainsKey("upload") ? exports.TakeUpload(RequetesArgs.Id32(values, "upload")) : RequetesArgs.Text(values, "content", MaxPackLength);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                try
                {
                    return await library.ExaminePackAsync(session.Root, session.Root, content, ct).ConfigureAwait(false);
                }
                catch (QueryDefinitionException ex)
                {
                    throw new DomeniaOperationException(QueryErrors.PackInvalid, ex.Message);
                }
            }).ConfigureAwait(false), "Examine un pack avant import (16 Mio au plus, par parties au-delà d’un message) : provenance, version, intégrité, état et différences de chaque recette ; rien n’est écrit."),

            new OperationDefinition("requetes.pack.apply", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["examinationId", "choices"]);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var (entry, created, replaced, copied, ignored, receipt) = await library.ApplyImportAsync(session.Root, RequetesArgs.Id32(values, "examinationId"), RequetesArgs.StringMap(values, "choices", 5000), ct).ConfigureAwait(false);
                return new { importId = entry.ImportId, created, replaced, copied, ignored, receipt };
            }).ConfigureAwait(false), "Applique les choix d’import (ignorer, créer, nouvelle copie, remplacer) en une écriture, révisions vérifiées, avec point de restauration."),

            new OperationDefinition("requetes.pack.history", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                BridgeArguments.RequireNone(args);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var entries = await library.HistoryAsync(session.Root, ct).ConfigureAwait(false);
                return entries.Select(e => new
                {
                    e.ImportId,
                    e.Kind,
                    e.At,
                    e.PackName,
                    e.PackVersion,
                    e.Verified,
                    count = (e.Kind == "rollback" ? e.Remaining : e.Items).Length,
                    label = (e.PackName is { } n ? "« " + n + " » v" + e.PackVersion.ToString(CultureInfo.InvariantCulture) : "Pack sans version") + " · "
                        + (e.Kind == "rollback" ? "restauration interrompue, " + FrenchText.Count(e.Remaining.Length, "recette encore à restaurer", "recettes encore à restaurer") : FrenchText.Count(e.Items.Length, "recette", "recettes")),
                    items = (e.Kind == "rollback" ? e.Remaining : e.Items).Select(i => new { i.Id, i.Name, created = i.Before is null }).ToArray(),
                }).ToArray();
            }).ConfigureAwait(false), "Imports restaurables de cette bibliothèque (journal de 40 entrées), du plus récent au plus ancien."),

            new OperationDefinition("requetes.pack.rollback", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["importId"]);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                try
                {
                    var (entry, restored, refused) = await library.RollbackAsync(session.Root, RequetesArgs.Id32(values, "importId"), ct).ConfigureAwait(false);
                    return new { rollbackId = entry.ImportId, restored, refused };
                }
                catch (QueryDefinitionException ex) when (!ex.Message.StartsWith(QueryLibrary.StoreFailedPrefix, StringComparison.Ordinal))
                {
                    throw new DomeniaOperationException(QueryErrors.RollbackRefused, ex.Message);
                }
            }).ConfigureAwait(false), "Restaure la bibliothèque avant un import (définitions remplacées remises, créations retirées)."),

            new OperationDefinition("requetes.script", OperationClass.Local, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe", "format", "searchBase"]);
                var compiled = Compile(RequetesArgs.Recipe(values));
                var format = RequetesArgs.Choice(values, "format", "powershell", "powershell", "json", "ldap", "command");
                var searchBase = RequetesArgs.OptionalText(values, "searchBase", BridgeArguments.MaxDistinguishedNameLength);
                var now = context.Clock.GetUtcNow();
                var ldap = QueryLdap.Translate(compiled.Resolved, now);
                var slug = WindowsRelease.Slug(compiled.Normalized.Name);
                var (content, fileName, mime, text) = format switch
                {
                    "json" => (QueryRecipeJson.Write(compiled.Normalized, indented: true), "Domenia-requete-" + slug + ".json", "application/json", "Recette au format Domenia, relisible par l’import d’un pack et par le script PowerShell (-ShowDefinition)."),
                    "ldap" => (ldap.Pretty, "Domenia-requete-" + slug + ".ldap.txt", "text/plain", ldap.Exact ? "Filtre exact : toute la requête s’exprime en LDAP." : "Partie annuaire de la requête : les autres conditions restent évaluées par Domenia."),
                    "command" => (QueryScript.Command(compiled, ldap, searchBase), "Domenia-requete-" + slug + ".cmd.txt", "text/plain", "Commande en lecture seule (candidats de l’annuaire)."),
                    _ => (QueryScript.PowerShell(compiled, ldap, now), "Domenia-requete-" + slug + ".ps1", "text/plain",
                        "Script en lecture seule : -RecordsPath évalue toute la requête sur un export JSON de l’aperçu ; -SearchBase lit les candidats de l’annuaire."),
                };
                return QueryExports.Prepare(context, "script", fileName, content, 1, mime, text);
            }), "Exporte une requête en script PowerShell commenté (évaluation sur un export ou lecture seule de l’annuaire), en JSON Domenia 2, en filtre LDAP ou en commande."),

            new OperationDefinition("requetes.search.apply", OperationClass.Local, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["evaluationId"]);
                var evaluation = workshop.RequireEvaluation(RequetesArgs.Id32(values, "evaluationId"));
                if (context.Clock.GetUtcNow() - evaluation.Description.EvaluatedAt > TimeSpan.FromMinutes(10) || await StaleAsync(evaluation, ct).ConfigureAwait(false))
                {
                    throw new DomeniaOperationException(QueryErrors.EvaluationUnknown, "Aperçu trop ancien ou données changées depuis : relancez l’aperçu avant de l’appliquer à Recherche.");
                }
                var ids = evaluation.Population.Where((_, i) => evaluation.Verdicts[i] == MatchState.Match).Select(r => r.Id).ToImmutableArray();
                var selection = new QuerySearchSelection(evaluation.Query.Recipe.Id, evaluation.Query.Recipe.Name, evaluation.Query.Target, ids, context.Clock.GetUtcNow(), evaluation.Query.Fingerprint);
                workshop.Search = selection;
                context.Journal.Add(new JournalEntry(selection.At, "Requêtes" + FrenchText.Colon + "sélection figée pour Recherche (" + FrenchText.Count(ids.Length, "objet", "objets") + ", inconnus exclus)", Tone.Info));
                return new { count = ids.Length, at = selection.At, recipeName = selection.RecipeName, target = RequetesViews.TargetKey(selection.Target) };
            }, "Fige les GUID des objets correspondants (inconnus exclus) comme filtre daté des résultats de Recherche."),

            new OperationDefinition("requetes.search.selection", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(workshop.Search is { } s ? new { s.RecipeId, s.RecipeName, target = RequetesViews.TargetKey(s.Target), s.Ids, s.At, s.Fingerprint, count = s.Ids.Length } : null);
            }, "Sélection figée pour Recherche (ou null) : lue par l’écran Rechercher."),

            new OperationDefinition("requetes.search.clear", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                var had = workshop.Search is not null;
                workshop.Search = null;
                return Task.FromResult<object?>(new { cleared = had });
            }, "Retire la sélection figée pour Recherche."),

            new OperationDefinition("requetes.cmdlets", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = RequetesArgs.Optional(args, ["text", "module", "source"]);
                var terms = (RequetesArgs.OptionalText(values, "text", 100) ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(FrenchText.Fold).ToList();
                var module = RequetesArgs.OptionalText(values, "module", 40);
                var asked = RequetesArgs.Choice(values, "source", "auto", "auto", "builtin", "installed");
                // The help files of the installed modules are read on the operator's gesture (and by default in directory mode);
                // the simulation shows the delivered reference unless asked.
                InstalledCmdlets? installed = null;
                if (asked == "installed" || asked == "auto" && context.Mode != AppMode.Simulation)
                {
                    installed = await QueryCmdletHelp.From(context).ReadAsync(ct).ConfigureAwait(false);
                }
                var useInstalled = installed is { Cmdlets.Length: > 0 };
                IReadOnlyList<QueryCmdlet> all = useInstalled ? installed!.Cmdlets : QueryCmdlets.All;
                var list = all.Where(c => module is null || c.Module == module)
                    .Where(c => terms.All(t => FrenchText.Fold(c.Name + " " + c.Synopsis + " " + c.Syntax + " " + string.Join(" ", c.Parameters ?? [])).Contains(t, StringComparison.Ordinal)))
                    .Select(c => new { c.Name, c.Module, c.Write, c.Credential, c.Synopsis, c.Syntax, c.Example, help = c.HelpText, parameters = c.Parameters ?? [], parameterCount = c.Parameters?.Count ?? 0, c.Source })
                    .ToArray();
                return new
                {
                    modules = all.Select(c => c.Module).Distinct(StringComparer.Ordinal).ToArray(),
                    cmdlets = list,
                    total = all.Count,
                    source = useInstalled ? "installed" : "builtin",
                    installed = installed is null ? null : new { modules = installed.Modules, files = installed.Files.Length, readAt = installed.ReadAt, found = installed.Cmdlets.Length },
                };
            }).ConfigureAwait(false), "Référence des cmdlets ActiveDirectory et LAPS : aide des modules installés sur ce poste (lue localement) ou référence intégrée ; jamais exécutées par Domenia."),

            new OperationDefinition("requetes.details.list", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["requestKey", "offset", "limit"]);
                var key = RequetesArgs.OptionalText(values, "requestKey", 64);
                var offset = RequetesArgs.Int(values, "offset", 0, 10_000_000, 0);
                var limit = RequetesArgs.Int(values, "limit", 1, 250, 250);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var dataset = await readers.Require<IQueryWorkshopReader>().DatasetAsync(ct).ConfigureAwait(false);
                var content = await library.ReadAsync(session.Root, ct).ConfigureAwait(false);
                var known = content.Records.Select(r => r.Recipe.ReadDefinition).OfType<WmiReadDefinition>().GroupBy(d => d.RequestKey).ToDictionary(g => g.Key, g => g.First(), StringComparer.Ordinal);
                var computers = dataset.Directory.Computers.ToDictionary(c => c.ObjectGuid);
                var all = dataset.Details.SelectMany(p => p.Value.Select(d => (Computer: p.Key, Detail: d))).ToList();
                var definitions = all.GroupBy(x => x.Detail.RequestKey).Select(g =>
                {
                    known.TryGetValue(g.Key, out var definition);
                    return new
                    {
                        requestKey = g.Key,
                        className = definition?.ClassName,
                        query = definition?.CanonicalQuery,
                        @namespace = definition?.Namespace,
                        computers = g.Count(),
                        failed = g.Count(x => !x.Detail.Success),
                        newest = g.Max(x => x.Detail.At),
                        recipes = content.Records.Where(r => r.Recipe.ReadDefinition?.RequestKey == g.Key).Select(r => r.Name).Take(5).ToArray(),
                    };
                }).OrderByDescending(d => d.newest).ToArray();
                var rows = all.Where(x => key is null || x.Detail.RequestKey == key)
                    .Select(x => (x.Detail, Name: computers.TryGetValue(x.Computer, out var c) ? c.Name : x.Computer.ToString("D"), Dn: computers.TryGetValue(x.Computer, out var d) ? d.DistinguishedName : "", x.Computer))
                    .OrderBy(x => FrenchText.Fold(x.Name), StringComparer.Ordinal).ThenBy(x => x.Detail.RequestKey, StringComparer.Ordinal).ToList();
                return new
                {
                    definitions,
                    rows = rows.Skip(offset).Take(limit).Select(x => new
                    {
                        computer = x.Computer.ToString("D"), name = x.Name, dn = x.Dn, requestKey = x.Detail.RequestKey, className = known.TryGetValue(x.Detail.RequestKey, out var def) ? def.ClassName : null,
                        at = x.Detail.At, success = x.Detail.Success, count = x.Detail.StoredCount, complete = x.Detail.CountComplete && !x.Detail.Truncated, truncated = x.Detail.Truncated,
                    }).ToArray(),
                    total = rows.Count,
                    offset,
                    limit,
                    hasMore = offset + limit < rows.Count,
                };
            }).ConfigureAwait(false), "Résultats des SELECT WMI mémorisés par poste (nombre d’instances, date, lecture complète ou non), par pages de 250 ; aucune lecture distante."),

            new OperationDefinition("requetes.draft.get", OperationClass.LocalRead, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                if (!context.Preferences.TryGet(QueryWorkshop.DraftKey, out var value) || value.ValueKind != JsonValueKind.Object || !value.TryGetProperty("recipe", out var recipe))
                {
                    return Task.FromResult<object?>(null);
                }
                try
                {
                    var read = QueryRecipeJson.Read(recipe);
                    object? origin = null;
                    if (value.TryGetProperty("base", out var b) && b.ValueKind == JsonValueKind.Object && b.TryGetProperty("id", out var bid) && bid.ValueKind == JsonValueKind.String
                        && b.TryGetProperty("revision", out var brev) && brev.TryGetInt64(out var revision) && b.TryGetProperty("source", out var bsource) && bsource.GetString() is "personal" or "template")
                    {
                        origin = new { id = bid.GetString(), revision, source = bsource.GetString(), fingerprint = b.TryGetProperty("fingerprint", out var fp) && fp.ValueKind == JsonValueKind.String ? fp.GetString() : null };
                    }
                    return Task.FromResult<object?>(new { recipe = read, savedAt = value.TryGetProperty("savedAt", out var at) && at.ValueKind == JsonValueKind.String ? at.GetString() : null, @base = origin });
                }
                catch (QueryDefinitionException)
                {
                    return Task.FromResult<object?>(null);
                }
            }, "Brouillon de l’atelier mémorisé dans les préférences locales, avec la révision dont il part (repris à la réouverture)."),

            new OperationDefinition("requetes.draft.keep", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe", "base"]);
                JsonElement? element = null;
                if (values.TryGetValue("recipe", out var raw) && raw.ValueKind != JsonValueKind.Null)
                {
                    var recipe = RequetesArgs.Recipe(values);
                    var json = QueryRecipeJson.Write(recipe);
                    if (Encoding.UTF8.GetByteCount(json) > QueryLimits.MaxDefinitionBytes)
                    {
                        throw BridgeArguments.Invalid("brouillon supérieur à 64 Kio.");
                    }
                    object? origin = null;
                    if (values.TryGetValue("base", out var b) && b.ValueKind == JsonValueKind.Object)
                    {
                        var bv = BridgeArguments.ReadObject(b, ["id", "revision", "source", "fingerprint"]);
                        var fingerprint = RequetesArgs.OptionalText(bv, "fingerprint", 64);
                        origin = new { id = RequetesArgs.RecipeId(bv, "id"), revision = RequetesArgs.Long(bv, "revision", 0, long.MaxValue - 1), source = RequetesArgs.Choice(bv, "source", "personal", "personal", "template"), fingerprint };
                    }
                    using var document = JsonDocument.Parse(json);
                    element = JsonSerializer.SerializeToElement(new { recipe = document.RootElement.Clone(), savedAt = context.Clock.GetUtcNow().UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture), @base = origin });
                }
                try
                {
                    await context.Preferences.SetAsync(QueryWorkshop.DraftKey, element, ct).ConfigureAwait(false);
                    return new { persisted = context.Preferences.Persistent };
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    context.Log.Warning($"Brouillon de requête non enregistré : {ex.GetType().Name}.");
                    return new { persisted = false };
                }
            }).ConfigureAwait(false), "Mémorise (ou efface, avec null) le brouillon de l’atelier et la révision dont il part, dans les préférences locales."),
        ];
    }
}
