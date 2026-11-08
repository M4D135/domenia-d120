using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using Domenia.Core.Poste;
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
public sealed partial class RequetesOperations : IOperationModule
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
            var current = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
            if (!DistinguishedName.AreEqual(dataset.Directory.Domain.RootDn, session.Root) || current.Epoch != session.Snapshot.Epoch
                || current.Domain?.RootDn is not { } root || !DistinguishedName.AreEqual(root, session.Root)
                || !string.Equals(current.Account.Login, session.Snapshot.Account.Login, StringComparison.OrdinalIgnoreCase))
            { throw new DomeniaOperationException(QueryErrors.EvaluationUnknown, "Session ou domaine modifié pendant la lecture locale de l’aperçu."); }
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

        async Task<QueryRecipe> BindAsync(QueryRecipe recipe, CancellationToken ct) =>
            await QueryPersonalProbes.BindAsync(recipe, context.Preferences, ct).ConfigureAwait(false);

        async Task<CompiledQuery> CompileAsync(QueryRecipe recipe, CancellationToken ct) =>
            Compile(await BindAsync(recipe, ct).ConfigureAwait(false));

        static bool SameScope(ScopeSelection? expected, ScopeSelection? actual) => expected is null ? actual is null
            : actual is not null && ScopeRules.SameScope(expected, actual);

        async Task ConfirmCollectionAsync(string root, long epoch, string account, ScopeSelection? scope,
            ImmutableDictionary<Guid, QueryComputerIdentity> identities, ImmutableArray<FrozenProbe> personal, long accountVersion, long machineGeneration, CancellationToken ct)
        {
            var session = await SessionAsync(ct).ConfigureAwait(false);
            if (root.Length == 0 || !DistinguishedName.AreEqual(root, session.Root) || session.Snapshot.Epoch != epoch
                || !string.Equals(account, session.Snapshot.Account.Login, StringComparison.OrdinalIgnoreCase)
                || !SameScope(scope, ScopeFor(session, QueryTarget.Computer)))
                throw new DomeniaOperationException(QueryErrors.CollectRefused, "Session ou périmètre modifié depuis le plan : préparez-le de nouveau. Rien n’a été lu.");
            var (dataset, _, _) = await RecordsAsync(session, QueryTarget.Computer, ct).ConfigureAwait(false);
            var computers = dataset.Directory.Computers.ToDictionary(c => c.ObjectGuid);
            if (identities.Any(p => !computers.TryGetValue(p.Key, out var actual) || !p.Value.Matches(actual)))
                throw new DomeniaOperationException(QueryErrors.CollectRefused, "Une identité AD figée a changé depuis le plan. Rien n’a été lu.");
            await ProfileProbeCatalog.ConfirmAsync(context.Preferences, personal, ct).ConfigureAwait(false);
            if (AccountAccess.From(context).SelectionVersion != accountVersion || MachineAccountService.From(context).Generation != machineGeneration)
                throw new DomeniaOperationException(QueryErrors.CollectRefused, "La sélection des comptes a changé depuis le plan. Repréparez-le avant toute lecture.");
            ct.ThrowIfCancellationRequested();
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
            await QueryPersonalProbes.ConfirmAsync(evaluation.Query, context.Preferences, ct).ConfigureAwait(false);
            var dataset = await readers.Require<IQueryWorkshopReader>().DatasetAsync(ct).ConfigureAwait(false);
            var current = await SessionAsync(ct).ConfigureAwait(false);
            return dataset.Version != evaluation.Description.DatasetVersion || !DistinguishedName.AreEqual(dataset.Directory.Domain.RootDn, evaluation.RootDn)
                || !DistinguishedName.AreEqual(current.Root, evaluation.RootDn) || current.Snapshot.Epoch != evaluation.SessionEpoch
                || !string.Equals(current.Snapshot.Account.Login, evaluation.SessionAccount, StringComparison.OrdinalIgnoreCase)
                || !SameScope(evaluation.Scope, ScopeFor(current, evaluation.Query.Target));
        }

        static object? RowValue(QueryRecord record, string id) => record.Values.GetValueOrDefault(id);

        static object SaveView(QuerySaveResult saved, PosteQueryPlacement? placement = null) => new
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
            placement,
            droppedWidgets = saved.Dropped,
            migratedWidgets = saved.Migrated,
            remote = RequetesViews.Remote(saved.Record.Recipe),
        };

        return
        [
            new OperationDefinition("requetes.catalog", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = RequetesArgs.Optional(args, ["target"]);
                var target = RequetesArgs.Target(values);
                var personal = new QueryProbeContext((await ProfileProbeCatalog.ReadAsync(context.Preferences, ct).ConfigureAwait(false)).Entries);
                var fields = QueryCatalog.Fields(target, personal);
                return (object?)new
                {
                    target = RequetesViews.TargetKey(target),
                    targets = new[] { new { id = "computer", label = QueryTexts.TargetLabel(QueryTarget.Computer) }, new { id = "user", label = QueryTexts.TargetLabel(QueryTarget.User) }, new { id = "group", label = QueryTexts.TargetLabel(QueryTarget.Group) } },
                    fields,
                    instanceFields = target == QueryTarget.Computer ? QueryCatalog.InstanceFields.AddRange(personal.InstanceFields) : [],
                    collections = target == QueryTarget.Computer ? QueryProbeCatalog.All.Concat(personal.Personal).Where(p => p.Mode == "All").Select(p => new { id = QueryCatalog.ProbePrefix + p.Id, name = p.Category + " · " + p.Name, properties = p.Properties }).ToArray() : [],
                    ldapAttributes = LdapSchema.All.Select(a => new { name = a.Name, syntax = a.SyntaxLabel, read = a.ReadByDomenia, description = a.Description, example = a.Example }).ToArray(),
                    ldapFields = LdapSchema.All.Select(QueryCatalog.LdapAttributeField).ToArray(),
                    operators = Enum.GetValues<QueryOperator>().Select(o => new { id = JsonNamingPolicy.CamelCase.ConvertName(o.ToString()), label = QueryTexts.OperatorLabel(o) }).ToArray(),
                    categories = fields.Select(f => f.Category).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray(),
                    sources = new[] { new { id = "ad", label = "Annuaire AD" }, new { id = "local", label = "Calcul local" }, new { id = "observation", label = "Relevé du poste" }, new { id = "probe", label = "Sonde WMI" } },
                    limits = new { conditions = QueryLimits.MaxConditions, depth = QueryLimits.MaxTreeDepth, nodes = QueryLimits.MaxTreeNodes, parameters = QueryLimits.MaxParameters, name = QueryLimits.MaxNameLength, ldap = QueryLimits.MaxLdapLength, pack = QueryLibrary.MaxDocumentBytes, packPart = MaxPackPart },
                };
            }).ConfigureAwait(false), "Catalogue embarqué et personnel du profil : informations typées, opérateurs, attributs LDAP et limites, sans collecte."),

            new OperationDefinition("requetes.validate", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe"]);
                return Validation(await BindAsync(RequetesArgs.Recipe(values), ct).ConfigureAwait(false));
            }).ConfigureAwait(false), "Valide un brouillon et fige les définitions personnelles présentes dans le profil : erreurs, forme normalisée, LDAP, résumé et paramètres."),

            new OperationDefinition("requetes.ldap.read", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["text", "recipe"]);
                var text = RequetesArgs.Text(values, "text", QueryLimits.MaxLdapLength);
                var current = await BindAsync(RequetesArgs.Recipe(values), ct).ConfigureAwait(false);
                var reading = QueryLdap.Read(text, current);
                return reading.Valid ? new { reading.Valid, reading.Error, reading.Position, reading.Recipe, reading.Pretty, reading.Warnings, validation = Validation(reading.Recipe!) } : (object)new { reading.Valid, reading.Error, reading.Position, reading.Recipe, reading.Pretty, reading.Warnings, validation = (object?)null };
            }).ConfigureAwait(false), "Lit un filtre LDAP saisi et le traduit en conditions de la requête (ou dit l’erreur et sa position)."),

            new OperationDefinition("requetes.value.preview", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["target", "field", "text"]);
                var target = RequetesArgs.Target(values);
                var id = RequetesArgs.Text(values, "field", 256);
                var text = RequetesArgs.Text(values, "text", QueryLimits.MaxTextValue);
                var personal = new QueryProbeContext((await ProfileProbeCatalog.ReadAsync(context.Preferences, ct).ConfigureAwait(false)).Entries);
                var field = QueryCatalog.Find(target, id, probes: personal) ?? throw new DomeniaOperationException(QueryErrors.Invalid, QueryTexts.InvalidMessage("information inconnue."));
                return field.Kind == QueryFieldKind.Number ? QueryFormat.PreviewNumber(text, field) : new QueryNumberPreview(true, null, "");
            }).ConfigureAwait(false), "Conversion d’unités en direct d’une valeur numérique saisie, y compris pour une propriété personnelle déclarée."),

            new OperationDefinition("requetes.home.recipe", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["revision", "key"]);
                var revision = RequetesArgs.Text(values, "revision", 128);
                var key = RequetesArgs.Text(values, "key", 512);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var draft = await AccueilService.From(context).QueryDraftAsync(revision, key, ct).ConfigureAwait(false);
                if (!DistinguishedName.AreEqual(session.Root, draft.DomainDn)
                    || !string.Equals(session.Snapshot.Account.Login, draft.Account, StringComparison.OrdinalIgnoreCase))
                    throw new DomeniaOperationException(AccueilService.BoardReplaced, AccueilService.BoardReplacedMessage);
                return new { draft, scope = new {
                    working = session.Snapshot.Scope, workshop = draft.Scope, effective = draft.Scope,
                    wholeDomain = false, accountsInDomain = false,
                    domain = new { dnsName = session.Domain, rootDn = draft.DomainDn },
                    @base = draft.Base, counts = new { computer = draft.LocalComputers },
                } };
            }, "Ouvre un chiffre exact de l’Accueil dans l’atelier : conditions vérifiées ou sélection explicitement figée, sans collecte réseau."),

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
                var recipe = await BindAsync(RequetesArgs.Recipe(values), ct).ConfigureAwait(false);
                var limit = RequetesArgs.Int(values, "limit", 1, QueryLimits.MaxPreviewPage, QueryLimits.PreviewPage);
                var asked = RequetesArgs.Choice(values, "verdict", "auto", "auto", "all", "match", "unknown", "noMatch");
                var compiled = Compile(recipe);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var (dataset, records, scope) = await RecordsAsync(session, compiled.Target, ct).ConfigureAwait(false);
                var now = context.Clock.GetUtcNow();
                await QueryPersonalProbes.ConfirmAsync(compiled, context.Preferences, ct).ConfigureAwait(false);
                var evaluation = workshop.Evaluate(compiled, records, dataset, scope, now, session.Domain, session.Snapshot,
                    AccountAccess.From(context).SelectionVersion, MachineAccountService.From(context).Generation);
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

            new OperationDefinition("requetes.preview.groups", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["evaluationId", "text", "offset", "limit"]);
                var evaluation = workshop.RequireEvaluation(RequetesArgs.Id32(values, "evaluationId"));
                await QueryPersonalProbes.ConfirmAsync(evaluation.Query, context.Preferences, ct).ConfigureAwait(false);
                var summary = evaluation.Groups ?? throw new DomeniaOperationException(QueryErrors.Invalid, QueryTexts.InvalidMessage("cette requête n’a pas de répartition."));
                var page = QueryAnalysis.Page(summary, RequetesArgs.Int(values, "offset", 0, 10_000_000, 0), RequetesArgs.Int(values, "limit", 1, QueryLimits.MaxGroupPage, QueryLimits.GroupPage), RequetesArgs.OptionalText(values, "text", 256));
                return new { field = summary.Field, fieldName = summary.FieldName, page, items = QueryAnalysis.Items(summary, 10) };
            }).ConfigureAwait(false), "Répartition complète et exacte d’un aperçu figé, filtrable et paginée par 100."),

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

            new OperationDefinition("requetes.preview.segment", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["evaluationId", "label", "missing", "value", "excluded"]);
                var evaluation = workshop.RequireEvaluation(RequetesArgs.Id32(values, "evaluationId"));
                await QueryPersonalProbes.ConfirmAsync(evaluation.Query, context.Preferences, ct).ConfigureAwait(false);
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
            }).ConfigureAwait(false), "Recette restreinte aux objets d’une valeur de répartition (segment ET), prête pour un nouvel aperçu."),

            new OperationDefinition("requetes.preview.export", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
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
                var compiled = await CompileAsync(RequetesArgs.Recipe(values), ct).ConfigureAwait(false);
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
                var compiled = await CompileAsync(RequetesArgs.Recipe(values), ct).ConfigureAwait(false);
                if (compiled.Target != QueryTarget.Computer || compiled.RequestedFields.All(f => compiled.FindField(f) is not { Source: QuerySource.Observation or QuerySource.Probe or QuerySource.Instance or QuerySource.Detail }))
                {
                    throw new DomeniaOperationException(QueryErrors.CollectRefused, "La requête n’utilise que l’annuaire et les calculs locaux : rien à collecter sur les postes.");
                }
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var (dataset, records, scope) = await RecordsAsync(session, compiled.Target, ct).ConfigureAwait(false);
                ScopeRules.EnsureNotDomainRoot(scope, session.Root);
                var now = context.Clock.GetUtcNow();
                var evaluationContext = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), now);
                var collection = CollectionSettingsRules.Read(context.Preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var settings) ? settings : null, []);
                var plan = QueryAnalysis.CollectPlan(compiled, records, evaluationContext, now, RequetesArgs.Int(values, "cacheMinutes", 0, 1440, 15), RequetesArgs.Int(values, "reuseDays", 0, 3650, 0), concurrency: 1,
                    freshnessSeconds: CollectionSettingsRules.FreshnessTable(collection).ToDictionary(f => f.Family, f => f.Seconds));
                CollectionAdmission.EnsureTargets(collection, plan.Targets.Length);
                plan = plan with { ConfiguredConcurrency = collection.Budgets.GetValueOrDefault(CollectionSettingsRules.Concurrency, 4),
                    EffectiveConcurrency = 1, ConfirmationRequired = plan.Targets.Length > 200 || !CollectionAdmission.Window(collection, context.Clock).Open,
                    Text = plan.Text + " " + CollectionAdmission.Notice(collection, context.Clock)
                        + " Atelier : un poste à la fois pour préserver les autorisations à usage unique." };
                if (plan.Targets.Length > 1000) throw new DomeniaOperationException(QueryErrors.CollectRefused, "Au plus 1 000 postes par collecte explicite : réduisez le périmètre avant de confirmer.");
                await QueryPersonalProbes.ConfirmAsync(compiled, context.Preferences, ct).ConfigureAwait(false);
                var ticket = workshop.Keep(plan, compiled.Fingerprint, dataset, scope, session.Snapshot,
                    AccountAccess.From(context).SelectionVersion, MachineAccountService.From(context).Generation);
                return new { ticket = ticket.Id, expiresAt = ticket.ExpiresAt, plan };
            }).ConfigureAwait(false), "Plan local des mesures manquantes, en erreur ou trop anciennes : postes, familles, sondes et coût compté (aucune lecture)."),

            new OperationDefinition("requetes.collect.run", network, async (args, bridge, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["ticket", "confirmed"]);
                var ticket = workshop.Take(RequetesArgs.Id32(values, "ticket")) ?? throw new DomeniaOperationException(QueryErrors.CollectRefused, "Plan de collecte inconnu, expiré ou déjà lancé : préparez-le de nouveau. Rien n’a été lu.");
                var plan = ticket.Plan;
                if ((plan.ConfirmationRequired || !CollectionAdmission.Window(CollectionAdmission.Read(context.Preferences), context.Clock).Open)
                    && !RequetesArgs.Bool(values, "confirmed", false))
                    throw new DomeniaOperationException("collection.confirmation", "Confirmez le nombre de postes et la fenêtre avant cette collecte.");
                CollectionAdmission.EnsureTargets(CollectionAdmission.Read(context.Preferences), plan.Targets.Length);
                await ConfirmCollectionAsync(ticket.RootDn, ticket.Epoch, ticket.Account, ticket.Scope, ticket.Identities, plan.PersonalProbes,
                    ticket.AccountVersion, ticket.MachineGeneration, ct).ConfigureAwait(false);
                if (plan.Targets.Length == 0)
                {
                    return new { result = (QueryMeasureResult?)null, text = plan.Text };
                }
                bridge.Publish("progress", new { stage = "reading", label = "Relevé de " + FrenchText.Count(plan.Targets.Length, "poste", "postes") + " en cours" });
                var request = new QueryMeasureRequest([.. plan.Targets.Select(t => Guid.Parse(t.Id))], plan.Ping, plan.Console, plan.Inventory, plan.ProbeIds,
                    plan.Detail is { } detail ? [detail] : [])
                { PersonalProbes = plan.PersonalProbes, ExpectedEpoch = ticket.Epoch, ExpectedIdentities = ticket.Identities,
                    ExpectedAccountVersion = ticket.AccountVersion, ExpectedMachineGeneration = ticket.MachineGeneration,
                    TargetMeasures = plan.Targets.ToImmutableDictionary(t => Guid.Parse(t.Id), t => new QueryMeasureMask(t.Families.Contains("Presence"),
                        t.Families.Contains("Console"), t.Families.Contains("Inventory"), t.MissingProbes,
                        t.Families.Contains("Detail") && plan.Detail is { } selected ? [selected.RequestKey] : [])) };
                var result = await readers.Require<IQueryWorkshopReader>().MeasureAsync(request, ct).ConfigureAwait(false);
                var text = (result.NotRead > 0 ? "Relevé partiel : " : "Relevé terminé : ") + FrenchText.Count(result.Answered, "poste lu", "postes lus") + ", " + FrenchText.Count(result.Failed - result.NotRead, "lecture incomplète ou sans réponse", "lectures incomplètes ou sans réponse")
                    + (result.SkippedDisabled > 0 ? ", " + FrenchText.Count(result.SkippedDisabled, "désactivé ignoré", "désactivés ignorés") : "")
                    + (result.NotRead > 0 ? ", " + FrenchText.Count(result.NotRead, "poste non contacté", "postes non contactés") + ". " + result.StopReason : ".")
                    + " Les anciennes valeurs restent datées de leur relevé.";
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
                var probes = evaluation.Query.RequestedFields.Select(f => evaluation.Query.FindField(f)?.ProbeId).OfType<string>().Distinct(StringComparer.Ordinal).ToImmutableArray();
                var detailRead = evaluation.Query.Resolved.ReadDefinition;
                if (!evaluation.Identities.TryGetValue(guid, out var identity)) throw new DomeniaOperationException(QueryErrors.ObjectUnknown, QueryErrors.ObjectUnknownMessage);
                var identities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(guid, identity);
                var personal = evaluation.Query.Probes.Definitions.Where(p => probes.Contains(p.Key)).ToImmutableArray();
                await ConfirmCollectionAsync(evaluation.RootDn, evaluation.SessionEpoch, evaluation.SessionAccount, evaluation.Scope, identities, personal,
                    evaluation.AccountVersion, evaluation.MachineGeneration, ct).ConfigureAwait(false);
                var request = new QueryMeasureRequest([guid], true, true, true, probes, detailRead is null ? [] : [detailRead])
                { PersonalProbes = personal, ExpectedEpoch = evaluation.SessionEpoch, ExpectedIdentities = identities,
                    ExpectedAccountVersion = evaluation.AccountVersion, ExpectedMachineGeneration = evaluation.MachineGeneration };
                var result = await readers.Require<IQueryWorkshopReader>().MeasureAsync(request, ct).ConfigureAwait(false);
                var name = evaluation.Population[evaluation.IndexOf(guid.ToString("D"))].Name;
                var text = result.Answered > 0 ? name + " relevé : présence, inventaire" + (probes.Length > 0 ? ", " + FrenchText.Count(probes.Length, "sonde", "sondes") : "") + (detailRead is null ? "" : " et SELECT WMI enregistré") + " à jour." : name + " n’a pas répondu : ses anciennes valeurs restent datées de leur relevé.";
                context.Journal.Add(new JournalEntry(result.At, "Requêtes" + FrenchText.Colon + text, result.Answered > 0 ? Tone.Ok : Tone.Warn));
                return new { result, text };
            }, "Actualiser ce poste : relevé explicite du seul poste choisi (présence, inventaire et sondes de la requête).", ServedInSimulation: true),

            new OperationDefinition("requetes.object.test", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe", "id"]);
                var compiled = await CompileAsync(RequetesArgs.Recipe(values), ct).ConfigureAwait(false);
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
                return new QueryLibraryListView([.. ordered.Skip(offset).Take(limit)], rows.Count, ordered.Count, offset, limit, categories, content.Unreadable, content.Persistent)
                { Generation = content.Generation, LegacyMigration = content.LegacyMigration };
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
                var collection = RequetesViews.Collection(record.Recipe);
                try { await QueryPersonalProbes.ConfirmAsync(Compile(record.Recipe), context.Preferences, ct).ConfigureAwait(false); }
                catch (DomeniaOperationException ex)
                { collection = "Utilisation indisponible dans ce profil : " + ex.Message + " L’import de recette n’importe aucune sonde ; importez sa définition exacte depuis le tiroir Sondes WMI de l’Accueil."; }
                return new QueryLibraryDetailView(record.Id, record.Name, record.Category, record.Archived ? "archive" : "personal", record.Description, record.Revision, record.UpdatedAt, record.Archived,
                    record.Recipe, [.. record.History.Select(h => new QueryRevisionView(h.Revision, h.SavedAt, h.Fingerprint))], record.Provenance, RequetesViews.ProvenanceText(record.Provenance),
                    RequetesViews.Sources(record.Recipe), collection, [.. content.Widgets.Where(w => w.RecipeId == id)], RequetesViews.Summary(record.Recipe),
                    record.ArchivedWidgets, [.. content.Consumers.Where(c => c.RecipeId == id)], record.Fingerprint);
            }).ConfigureAwait(false), "Détail d’usage d’une requête : description, sources, collecte, provenance déclarée, révisions, widgets (et widgets retirés par l’archivage), éléments liés."),

            new OperationDefinition("requetes.library.impact", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["id", "recipe"]);
                var id = RequetesArgs.RecipeId(values, "id");
                var draft = values.ContainsKey("recipe") ? await BindAsync(RequetesArgs.Recipe(values), ct).ConfigureAwait(false) : null;
                var session = await SessionAsync(ct).ConfigureAwait(false);
                return await library.ImpactAsync(session.Root, id, draft, workshop.Search?.RecipeId, ct).ConfigureAwait(false);
            }).ConfigureAwait(false), "Revue d’impact avant modification ou archivage : widgets liés, liens qui ne pourront plus s’afficher, favoris et sélection de Recherche, règles de santé, différences."),

            new OperationDefinition("requetes.library.save", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe", "category", "description", "expectedRevision", "mode"]);
                var recipe = await BindAsync(RequetesArgs.Recipe(values), ct).ConfigureAwait(false);
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
                var recipe = await BindAsync(RequetesArgs.Recipe(values), ct).ConfigureAwait(false);
                var widget = new QueryWidgetRequest(RequetesArgs.Choice(values, "board", "fleet", "fleet", "computer"), RequetesArgs.Choice(values, "visual", "kpi", "kpi", "text", "bar", "pie", "column"),
                    RequetesArgs.Text(values, "title", 80));
                if (widget.Board == "computer" && widget.Visual is not ("kpi" or "text"))
                    throw BridgeArguments.Invalid("Un poste affiche un verdict ou son explication, pas une distribution de population.");
                var mode = RequetesArgs.Choice(values, "mode", "update", "update", "copy", "migrate");
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var saved = await library.SaveAsync(session.Root, recipe, RequetesArgs.OptionalText(values, "category", 80), null, RequetesArgs.Long(values, "expectedRevision", 0, long.MaxValue - 1), mode, widget, ct)
                    .ConfigureAwait(false);
                context.Log.Info($"Requêtes{FrenchText.Colon}requête {saved.Record.Id} enregistrée (révision {saved.Record.Revision}).");
                var placement = saved.Widget is { Board: "computer" } linked
                    ? await PlacePosteWidgetAsync(context, library, session, linked, saved.Record.Fingerprint, ct).ConfigureAwait(false) : null;
                return SaveView(saved, placement);
            }).ConfigureAwait(false), "Enregistre la requête et son widget ; ajoute explicitement la carte Poste à la dernière disposition, avec un résultat distinct si cet ajout échoue."),

            new OperationDefinition("requetes.widget.place", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["id", "revision", "fingerprint"]);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var content = await library.ReadAsync(session.Root, ct).ConfigureAwait(false);
                var widget = content.Widgets.SingleOrDefault(w => w.Id == RequetesArgs.Id32(values, "id"))
                    ?? throw BridgeArguments.Invalid("Widget absent de la bibliothèque.");
                var revision = RequetesArgs.Long(values, "revision", 1, long.MaxValue - 1);
                var fingerprint = RequetesArgs.Text(values, "fingerprint", 64);
                if (widget.BoundRevision != revision) throw BridgeArguments.Invalid("Liaison modifiée ; relisez les widgets avant l’ajout.");
                return await PlacePosteWidgetAsync(context, library, session, widget, fingerprint, ct).ConfigureAwait(false);
            }).ConfigureAwait(false), "Place explicitement un widget existant dans la dernière disposition Poste, sans créer de recette ni lancer de collecte."),

            new OperationDefinition("requetes.widget.list", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                BridgeArguments.RequireNone(args);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var content = await library.ReadAsync(session.Root, ct).ConfigureAwait(false);
                PosteLayoutView? posteLayout;
                try { posteLayout = await PosteBoardLayouts.ReadLatestAsync(context.Preferences, "Computer", ct).ConfigureAwait(false); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException or JsonException) { posteLayout = null; }
                return content.Widgets.Select(w =>
                {
                    var record = content.Records.FirstOrDefault(r => r.Id == w.RecipeId);
                    var displayable = record is not null && QueryLibrary.Displayable(w, record.Recipe.Target);
                    var state = record is null ? "Requête absente de la bibliothèque"
                        : record.Archived ? "Requête archivée"
                        : !displayable ? "Ne peut plus s’afficher : la requête ne porte plus sur les postes"
                        : w.BoundRevision < record.Revision ? "Lié à la révision " + FrenchText.Integer(w.BoundRevision) + " : confirmez la mise à jour"
                        : "Révision " + FrenchText.Integer(record.Revision) + " liée";
                    return new
                    {
                        placed = w.Board == "computer" && posteLayout is { } layout && (!layout.Stored || PosteQueryLayout.Contains(layout, w.Id, session.Root)),
                        fingerprint = record is { } linkedRecord && linkedRecord.Revision == w.BoundRevision ? linkedRecord.Fingerprint : record?.History.SingleOrDefault(h => h.Revision == w.BoundRevision)?.Fingerprint,
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
                var compiled = await CompileAsync(recipe, ct).ConfigureAwait(false);
                var now = context.Clock.GetUtcNow();
                if (widget.Board == "computer")
                {
                    var local = await readers.Require<IQueryWorkshopReader>().DatasetAsync(ct).ConfigureAwait(false);
                    var current = await SessionAsync(ct).ConfigureAwait(false);
                    if (!DistinguishedName.AreEqual(local.Directory.Domain.RootDn, session.Root) || !DistinguishedName.AreEqual(current.Root, session.Root)
                        || current.Snapshot.Epoch != session.Snapshot.Epoch || !string.Equals(current.Snapshot.Account.Login, session.Snapshot.Account.Login, StringComparison.OrdinalIgnoreCase))
                        throw BridgeArguments.Invalid("Session remplacée pendant le calcul local.");
                    var guid = RequetesArgs.Guid(values, "computer");
                    var machine = local.Directory.Computers.SingleOrDefault(c => c.ObjectGuid == guid)
                        ?? throw new DomeniaOperationException(QueryErrors.ObjectUnknown, QueryErrors.ObjectUnknownMessage);
                    var fingerprint = record.Revision == widget.BoundRevision ? record.Fingerprint : record.History.Single(h => h.Revision == widget.BoundRevision).Fingerprint;
                    var binding = new BoardQueryBinding(QueryLibrary.RootKey(session.Root), record.Id, widget.BoundRevision, fingerprint, record.Revision, record.Name, false)
                        { LibraryWidgetId = widget.Id };
                    var item = new Domenia.Core.Accueil.FleetLayoutItem("q-" + widget.Id, Domenia.Core.Accueil.FleetWidgetSource.Query, BoardQueryBindings.Key(binding), "Verdict", "M", widget.Title, false, "")
                        { QueryBinding = binding };
                    var personal = (await ProfileProbeCatalog.ReadAsync(context.Preferences, ct).ConfigureAwait(false)).Entries;
                    var result = PosteQueryCards.Build(item, content, local, guid, machine.DistinguishedName, now, personalProbes: personal);
                    return new { widget.Id, widget.Title, widget.Visual, widget.Board, widget.BoundRevision, currentRevision = record.Revision,
                        needsConfirmation = widget.BoundRevision < record.Revision, recipeName = record.Name, evaluatedAt = now, scope = machine.Name,
                        counts = (object?)null, groups = (object?)null, text = result.Explanation,
                        computer = new { id = guid, name = machine.Name, verdict = result.Verdict, explanation = result.Explanation } };
                }
                var (dataset, records, scope) = await RecordsAsync(session, compiled.Target, ct).ConfigureAwait(false);
                var evaluationContext = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), now);
                var (one, many) = QueryTexts.Noun(compiled.Target);
                object? computer = null;
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
                var id = RequetesArgs.Id32(values, "id");
                var content = await library.ReadAsync(session.Root, ct).ConfigureAwait(false);
                var widget = content.Widgets.SingleOrDefault(w => w.Id == id);
                var removed = await library.UnlinkWidgetAsync(session.Root, id, ct).ConfigureAwait(false);
                string? layoutWarning = null;
                if (widget?.Board == "computer")
                {
                    try { await PosteQueryLayout.RemoveAsync(context.Preferences, session.Root, id, ct, context.Clock.GetUtcNow()).ConfigureAwait(false); }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException or JsonException)
                    { layoutWarning = "Lien retiré de la bibliothèque. La carte reste dans la disposition sans calcul ; retirez-la avec Personnaliser. " + ex.Message; }
                }
                return new { removed, layoutWarning };
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
                var values = BridgeArguments.ReadObject(args, ["name", "version", "ids", "origin", "reference"]);
                var reference = RequetesArgs.Bool(values, "reference", false);
                var access = reference ? await QueryReferenceContext.Capture(context, ct).ConfigureAwait(false) : null;
                var session = await SessionAsync(ct).ConfigureAwait(false);
                var name = RequetesArgs.Text(values, "name", 80);
                var pack = reference
                    ? await library.ExportReferencePatchAsync(session.Root, name, RequetesArgs.Long(values, "version", 1, 1_000_000), RequetesArgs.Strings(values, "ids", 500, 80), access!, ct).ConfigureAwait(false)
                    : await library.ExportPackAsync(session.Root, session.Root, name, RequetesArgs.Long(values, "version", 1, 1_000_000),
                        RequetesArgs.Strings(values, "ids", 5000, 80), RequetesArgs.OptionalText(values, "origin", 256), ct).ConfigureAwait(false);
                var text = "Pack « " + name.Trim() + " » version " + pack.Version.ToString(CultureInfo.InvariantCulture) + " : " + FrenchText.Count(pack.Count, "requête", "requêtes")
                    + ". La version proposée passera à " + pack.NextVersion.ToString(CultureInfo.InvariantCulture) + " une fois le fichier enregistré."
                    + (reference ? " Patch strict de référence : catégories et descriptions incluses, aucune sélection de GUID ni données collectées. Intégrité SHA-256, éditeur non authentifié." : "");
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
                // The strict format has its own validator; the historical permissive importer never receives it.
                var reference = QueryReferenceContext.IsReference(content);
                var access = reference ? await QueryReferenceContext.Capture(context, ct).ConfigureAwait(false) : null;
                var session = await SessionAsync(ct).ConfigureAwait(false);
                try
                {
                    return reference ? await library.ExamineReferencePatchAsync(session.Root, content, access!, ct).ConfigureAwait(false)
                        : await library.ExaminePackAsync(session.Root, session.Root, content, ct).ConfigureAwait(false);
                }
                catch (QueryDefinitionException ex)
                {
                    throw new DomeniaOperationException(QueryErrors.PackInvalid, ex.Message);
                }
            }).ConfigureAwait(false), "Examine un pack avant import (16 Mio au plus, par parties au-delà d’un message) : provenance, version, intégrité, état et différences de chaque recette ; rien n’est écrit."),

            new OperationDefinition("requetes.pack.apply", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["examinationId", "choices", "reference"]);
                var reference = RequetesArgs.Bool(values, "reference", false);
                if (reference && context.Mode == AppMode.Simulation
                    && !await library.IsDemonstrationReferencePreviewAsync(RequetesArgs.Id32(values, "examinationId"), ct).ConfigureAwait(false))
                { throw new QueryDefinitionException("Aucun aperçu fictif qualifié dans cette démonstration ; un patch réel reste interdit."); }
                var session = await SessionAsync(ct).ConfigureAwait(false);
                if (reference)
                {
                    var applied = await library.ApplyReferencePatchAsync(session.Root, RequetesArgs.Id32(values, "examinationId"), RequetesArgs.StringMap(values, "choices", 500), ct).ConfigureAwait(false);
                    return new { importId = applied.Receipt.Id, created = applied.AlreadyApplied ? 0 : applied.Receipt.Created,
                        replaced = applied.AlreadyApplied ? 0 : applied.Receipt.Replaced, copied = 0, ignored = applied.Receipt.Ignored, alreadyApplied = applied.AlreadyApplied,
                        receipt = new { applied.ReadBack, applied.Persisted, applied.Text, applied.Receipt.Sha256 } };
                }
                var (entry, created, replaced, copied, ignored, receipt) = await library.ApplyImportAsync(session.Root, RequetesArgs.Id32(values, "examinationId"), RequetesArgs.StringMap(values, "choices", 5000), ct).ConfigureAwait(false);
                return new { importId = entry.ImportId, created, replaced, copied, ignored, receipt };
            }).ConfigureAwait(false), "Applique les choix d’import (ignorer, créer, nouvelle copie, remplacer) en une écriture, révisions vérifiées, avec point de restauration."),

            new OperationDefinition("requetes.reference.history", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                BridgeArguments.RequireNone(args);
                if (context.Mode == AppMode.Simulation) { return await QueryReferenceDemo.HistoryAsync(context, library, ct).ConfigureAwait(false); }
                var access = await QueryReferenceContext.Capture(context, ct).ConfigureAwait(false);
                var session = await SessionAsync(ct).ConfigureAwait(false);
                return await library.ReferenceHistoryAsync(session.Root, access, ct).ConfigureAwait(false);
            }).ConfigureAwait(false), "Relit les reçus SHA-256 des patches de référence dans la bibliothèque locale ; ne contacte aucun partage."),

            new OperationDefinition("requetes.reference.demo.prepare", OperationClass.LocalWrite, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                BridgeArguments.RequireNone(args);
                return await QueryReferenceDemo.PrepareAsync(context, library, ct).ConfigureAwait(false);
            }).ConfigureAwait(false), "Prépare uniquement deux références inventées dans le magasin mémoire de démonstration : un conflit et un ajout. Aucun chemin ni contenu extérieur."),

            new OperationDefinition("requetes.reference.discard", OperationClass.Local, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["examinationId"]);
                await library.DiscardReferencePreviewAsync(RequetesArgs.Id32(values, "examinationId"), ct).ConfigureAwait(false);
                return new { discarded = true };
            }).ConfigureAwait(false), "Libère uniquement l’aperçu en mémoire d’un patch ; ne supprime aucune preuve."),

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

            new OperationDefinition("requetes.script", OperationClass.LocalRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["recipe", "format", "searchBase"]);
                var compiled = await CompileAsync(RequetesArgs.Recipe(values), ct).ConfigureAwait(false);
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
            }).ConfigureAwait(false), "Exporte une requête en script PowerShell commenté (évaluation sur un export ou lecture seule de l’annuaire), en JSON Domenia 2, en filtre LDAP ou en commande."),

            new OperationDefinition("requetes.search.apply", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["evaluationId"]);
                var evaluation = workshop.RequireEvaluation(RequetesArgs.Id32(values, "evaluationId"));
                if (context.Clock.GetUtcNow() - evaluation.Description.EvaluatedAt > TimeSpan.FromMinutes(10) || await StaleAsync(evaluation, ct).ConfigureAwait(false))
                {
                    throw new DomeniaOperationException(QueryErrors.EvaluationUnknown, "Aperçu trop ancien ou données changées depuis : relancez l’aperçu avant de l’appliquer à Recherche.");
                }
                var session = await SessionAsync(ct).ConfigureAwait(false);
                if (evaluation.Query.Target != QueryTarget.Computer || !DistinguishedName.AreEqual(evaluation.RootDn, session.Root)
                    || evaluation.SessionEpoch != session.Snapshot.Epoch || !string.Equals(evaluation.SessionAccount, session.Snapshot.Account.Login, StringComparison.OrdinalIgnoreCase))
                { throw new DomeniaOperationException(QueryErrors.EvaluationUnknown, "La sélection Recherche exige un aperçu de postes de cette session et de ce domaine."); }
                var ids = evaluation.Population.Where((_, i) => evaluation.Verdicts[i] == MatchState.Match).Select(r => r.Id).ToImmutableArray();
                if (ids.Length > SearchLimits.MaxLimit)
                { throw new DomeniaOperationException(QueryErrors.Invalid, "Au plus 20 000 GUID dans une sélection Recherche ; réduisez le périmètre sans tronquer la sélection."); }
                ct.ThrowIfCancellationRequested();
                var selection = new QuerySearchSelection(evaluation.Query.Recipe.Id, evaluation.Query.Recipe.Name, evaluation.Query.Target, ids, context.Clock.GetUtcNow(), evaluation.Query.Fingerprint)
                    { RootDn = session.Root, Epoch = session.Snapshot.Epoch, Account = session.Snapshot.Account.Login };
                workshop.Search = selection;
                context.Journal.Add(new JournalEntry(selection.At, "Requêtes" + FrenchText.Colon + "sélection figée pour Recherche (" + FrenchText.Count(ids.Length, "objet", "objets") + ", inconnus exclus)", Tone.Info));
                return new { count = ids.Length, at = selection.At, recipeName = selection.RecipeName, target = RequetesViews.TargetKey(selection.Target) };
            }, "Fige les GUID des objets correspondants (inconnus exclus) comme filtre daté des résultats de Recherche."),

            new OperationDefinition("requetes.search.selection", OperationClass.Local, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
                return workshop.Search is { Target: QueryTarget.Computer } s && s.Matches(session)
                    ? new { s.RecipeId, s.RecipeName, target = RequetesViews.TargetKey(s.Target), s.Ids, s.At, s.Fingerprint, s.RootDn, count = s.Ids.Length } : null;
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
                    var recipe = await BindAsync(RequetesArgs.Recipe(values), ct).ConfigureAwait(false);
                    var json = QueryRecipeJson.Write(recipe);
                    if (Encoding.UTF8.GetByteCount(json) > QueryLimits.MaxRecipeBytes
                        || Encoding.UTF8.GetByteCount(recipe.ObjectIds is null ? json : QueryRecipeJson.Write(recipe with { ObjectIds = null })) > QueryLimits.MaxDefinitionBytes)
                    {
                        throw BridgeArguments.Invalid("brouillon supérieur à 64 Kio de conditions ou 900 000 octets avec ses GUID.");
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
