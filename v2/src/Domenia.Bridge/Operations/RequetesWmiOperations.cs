using System.Collections.Immutable;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Bridge;

/// <summary>
/// Advanced WMI of the query workshop (Domenia 1 « WMI avancé », docs/ops/requetes.md § 7): namespaces one level at a time,
/// class definitions, schema of a class, SELECT prepared from checked properties, local analysis of a SELECT, test on the
/// chosen workstation, declared relations, recipe from a tested SELECT. Each remote read follows an explicit gesture on one
/// workstation; the metadata read stay in memory with their date. In simulation, a fictitious catalog answers.
/// </summary>
public sealed class RequetesWmiOperations : IOperationModule
{
    private static readonly TimeSpan CacheLife = TimeSpan.FromHours(24);

    public string Screen => "requetes";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var readers = context.Readers;
        var workshop = QueryWorkshop.From(context);

        static string Key(string kind, Guid computer, string ns, string? name = null) => kind + "|" + computer.ToString("N") + "|" + ns.ToUpperInvariant() + "|" + (name ?? "").ToUpperInvariant();

        static string Namespace(IReadOnlyDictionary<string, System.Text.Json.JsonElement> values)
        {
            var ns = RequetesArgs.Text(values, "namespace", 256);
            try
            {
                WqlRules.CheckNamespace(ns);
            }
            catch (QueryDefinitionException ex)
            {
                throw new DomeniaOperationException(QueryErrors.WmiInvalid, ex.Message);
            }
            return ns;
        }

        WmiClassSchema? CachedSchema(Guid computer, string ns, string? className) =>
            className is null ? null : workshop.Cached<WmiClassSchema>(Key("schema", computer, ns, className), CacheLife);

        object? Tested(Guid computer)
        {
            var last = workshop.LastTest(computer);
            return last is { } t ? new { t.Tested.Namespace, t.Tested.CanonicalQuery, t.Tested.Computer, t.Tested.At, className = t.Result.ClassName, rows = t.Result.Rows.Length, t.Result.Truncated } : null;
        }

        return
        [
            new OperationDefinition("requetes.wmi.cache", OperationClass.LocalRead, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["computer", "namespace", "className", "filter"]);
                var computer = RequetesArgs.Guid(values, "computer");
                var ns = Namespace(values);
                var className = RequetesArgs.OptionalText(values, "className", 128);
                var filter = RequetesArgs.OptionalText(values, "filter", 128);
                return new
                {
                    namespaces = workshop.Cached<WmiNamespaceList>(Key("ns", computer, ns), CacheLife),
                    classes = workshop.Cached<WmiClassList>(Key("classes", computer, ns, filter), CacheLife),
                    schema = CachedSchema(computer, ns, className),
                    tested = Tested(computer),
                };
            }), "Métadonnées WMI déjà lues pour ce poste (avec leur date) et dernier SELECT testé ; aucune lecture distante."),

            new OperationDefinition("requetes.wmi.namespaces", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["computer", "namespace"]);
                var computer = RequetesArgs.Guid(values, "computer");
                var ns = Namespace(values);
                var list = await readers.Require<IQueryWmiReader>().NamespacesAsync(computer, ns, ct).ConfigureAwait(false);
                workshop.Cache(Key("ns", computer, ns), list);
                return list;
            }, "Lit sur le poste les espaces de noms enfants directs d’un espace (un seul niveau, 500 au plus).", ServedInSimulation: true),

            new OperationDefinition("requetes.wmi.classes", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["computer", "namespace", "filter"]);
                var computer = RequetesArgs.Guid(values, "computer");
                var ns = Namespace(values);
                var filter = RequetesArgs.OptionalText(values, "filter", 128);
                try
                {
                    WqlRules.CheckClassFilter(filter);
                }
                catch (QueryDefinitionException ex)
                {
                    throw new DomeniaOperationException(QueryErrors.WmiInvalid, ex.Message);
                }
                var list = await readers.Require<IQueryWmiReader>().ClassesAsync(computer, ns, filter, ct).ConfigureAwait(false);
                workshop.Cache(Key("classes", computer, ns, filter), list);
                return list;
            }, "Lit sur le poste les définitions de classes d’un espace (2 000 au plus), filtrables par un nom éventuellement terminé par *.", ServedInSimulation: true),

            new OperationDefinition("requetes.wmi.schema", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ["computer", "namespace", "className"]);
                var computer = RequetesArgs.Guid(values, "computer");
                var ns = Namespace(values);
                var className = RequetesArgs.Text(values, "className", 128);
                try
                {
                    WqlRules.CheckTarget(ns, className);
                }
                catch (QueryDefinitionException ex)
                {
                    throw new DomeniaOperationException(QueryErrors.WmiInvalid, ex.Message);
                }
                var schema = await readers.Require<IQueryWmiReader>().SchemaAsync(computer, ns, className, ct).ConfigureAwait(false);
                workshop.Cache(Key("schema", computer, ns, className), schema);
                return schema;
            }, "Lit sur le poste le schéma d’une classe : propriétés (type CIM, clé, unité, description) ; propriétés de secret écartées.", ServedInSimulation: true),

            new OperationDefinition("requetes.wmi.build", OperationClass.Local, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["computer", "namespace", "className", "properties"]);
                var computer = RequetesArgs.Guid(values, "computer");
                var ns = Namespace(values);
                var className = RequetesArgs.Text(values, "className", 128);
                var properties = RequetesArgs.Strings(values, "properties", 64, 128);
                var schema = CachedSchema(computer, ns, className) ?? throw new DomeniaOperationException(QueryErrors.WmiNotTested, "Lisez d’abord le schéma de cette classe sur le poste : le SELECT se prépare à partir du schéma relu.");
                if (properties.Length == 0)
                {
                    throw new DomeniaOperationException(QueryErrors.WmiInvalid, "Cochez au moins une propriété du schéma.");
                }
                var unknown = properties.Where(p => schema.Properties.All(x => !string.Equals(x.Name, p, StringComparison.OrdinalIgnoreCase))).ToList();
                if (unknown.Count > 0)
                {
                    throw new DomeniaOperationException(QueryErrors.WmiInvalid, "Propriétés absentes du schéma relu : " + string.Join(", ", unknown) + ".");
                }
                return new { query = "SELECT " + string.Join(", ", properties) + " FROM " + schema.ClassName };
            }), "Prépare « SELECT p1, p2 FROM Classe » à partir des propriétés cochées du schéma relu."),

            new OperationDefinition("requetes.wmi.analyze", OperationClass.Local, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["computer", "computerName", "namespace", "query", "limit"]);
                var computer = values.ContainsKey("computer") ? RequetesArgs.Guid(values, "computer") : Guid.Empty;
                var computerName = RequetesArgs.OptionalText(values, "computerName", 64);
                var ns = Namespace(values);
                var query = RequetesArgs.Text(values, "query", 8192);
                var limit = RequetesArgs.Int(values, "limit", 1, 2000, 100);
                WqlSelect? parsed = null;
                try
                {
                    parsed = WqlRules.Parse(query);
                }
                catch (QueryDefinitionException)
                {
                    // The report below says why.
                }
                var schema = parsed is null || computer == Guid.Empty ? null : CachedSchema(computer, ns, parsed.ClassName);
                var last = computer == Guid.Empty ? null : workshop.LastTest(computer);
                return WqlRules.Plan(ns, query, limit, schema?.Properties.Select(p => p.Name).ToList(), schema?.Properties.Where(p => p.Key).Select(p => p.Name).ToList(), schema?.ClassName,
                    last?.Tested, computer == Guid.Empty ? null : computerName ?? last?.Tested.Computer);
            }), "Analyse locale d’un SELECT WQL (grammaire fermée) : classe, propriétés et clés, préconditions, limites, prudence, état « testé »."),

            new OperationDefinition("requetes.wmi.run", OperationClass.NetworkRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["computer", "namespace", "query", "limit"]);
                var computer = RequetesArgs.Guid(values, "computer");
                var ns = Namespace(values);
                var limit = RequetesArgs.Int(values, "limit", 1, 2000, 100);
                WqlSelect select;
                try
                {
                    var plan = WqlRules.Parse(RequetesArgs.Text(values, "query", 8192));
                    var schema = CachedSchema(computer, ns, plan.ClassName);
                    select = schema is null ? plan : WqlRules.Parse(plan.CanonicalQuery, schema.Properties.Select(p => p.Name).ToList());
                    WqlRules.CheckTarget(ns, select.ClassName);
                }
                catch (QueryDefinitionException ex)
                {
                    throw new DomeniaOperationException(QueryErrors.WmiInvalid, ex.Message);
                }
                var result = await readers.Require<IQueryWmiReader>().SelectAsync(computer, ns, select, limit, ct).ConfigureAwait(false);
                workshop.Tested(computer, new WmiTested(ns, select.CanonicalQuery, result.Computer, result.ReadAt), result);
                context.Journal.Add(new JournalEntry(result.ReadAt, "Requêtes" + FrenchText.Colon + "SELECT WMI exécuté sur " + result.Computer + " (" + FrenchText.Count(result.Rows.Length, "instance", "instances") + (result.Truncated ? ", résultat partiel" : "") + ")", result.Truncated ? Tone.Warn : Tone.Ok));
                // Technical journal: the count only, never the computer or the SELECT typed by the operator.
                context.Log.Info("Requêtes" + FrenchText.Colon + "SELECT WMI exécuté (" + FrenchText.Count(result.Rows.Length, "instance", "instances") + (result.Truncated ? ", résultat partiel" : "") + ").");
                return result;
            }).ConfigureAwait(false), "Exécute le SELECT sur le poste choisi (1 à 2 000 instances), enregistre le résultat et marque la requête testée.", ServedInSimulation: true),

            new OperationDefinition("requetes.wmi.relations", OperationClass.Local, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["className"]);
                return WqlRules.RelationPresets(RequetesArgs.Text(values, "className", 128));
            }), "Relations déclarées ou références prévues depuis une classe (disque ↔ partition, carte ↔ configuration, service ↔ processus…)."),

            new OperationDefinition("requetes.wmi.relation", OperationClass.NetworkRead, async (args, _, ct) => await RequetesArgs.Guard(async () =>
            {
                var values = BridgeArguments.ReadObject(args, ["computer", "namespace", "preset", "rowId"]);
                var computer = RequetesArgs.Guid(values, "computer");
                var ns = Namespace(values);
                var presetId = RequetesArgs.Text(values, "preset", 64);
                var rowId = RequetesArgs.Text(values, "rowId", 512);
                var last = workshop.LastTest(computer) ?? throw new DomeniaOperationException(QueryErrors.WmiNotTested, "Exécutez d’abord un SELECT sur ce poste : une relation part d’une instance du dernier résultat.");
                var preset = WqlRules.RelationPresets(last.Result.ClassName).FirstOrDefault(p => p.Id == presetId)
                    ?? throw new DomeniaOperationException(QueryErrors.WmiInvalid, "Relation non déclarée pour la classe " + last.Result.ClassName + ".");
                var row = last.Result.Rows.FirstOrDefault(r => r.Id == rowId) ?? throw new DomeniaOperationException(QueryErrors.WmiInvalid, "Instance absente du dernier résultat de ce poste.");
                var result = await readers.Require<IQueryWmiReader>().RelatedAsync(computer, ns, last.Result.ClassName, row, preset, ct).ConfigureAwait(false);
                return result;
            }).ConfigureAwait(false), "Lit une relation déclarée depuis une instance du dernier résultat du même poste ; aucune jointure libre.", ServedInSimulation: true),

            new OperationDefinition("requetes.wmi.recipe", OperationClass.Local, (args, _, _) => RequetesArgs.Guard(() =>
            {
                var values = BridgeArguments.ReadObject(args, ["computer", "namespace", "query", "limit", "name"]);
                var computer = RequetesArgs.Guid(values, "computer");
                var ns = Namespace(values);
                var limit = RequetesArgs.Int(values, "limit", 1, 2000, 100);
                var definition = WqlRules.NewReadDefinition(ns, RequetesArgs.Text(values, "query", 8192), limit);
                var last = workshop.LastTest(computer);
                if (last is not { } t || t.Tested.CanonicalQuery != definition.CanonicalQuery || !string.Equals(t.Tested.Namespace, ns, StringComparison.OrdinalIgnoreCase))
                {
                    throw new DomeniaOperationException(QueryErrors.WmiNotTested, "Pas encore testée sous cette forme sur ce poste : exécutez-la avant d’en faire une recette.");
                }
                var name = RequetesArgs.OptionalText(values, "name", QueryLimits.MaxNameLength) ?? "WMI · " + definition.ClassName;
                var recipe = QueryRecipe.Empty(QueryTarget.Computer) with
                {
                    Name = name.Trim().Length > 0 ? name.Trim() : "WMI · " + definition.ClassName,
                    ReadDefinition = definition,
                    Clauses = [new QueryClause(QueryCatalog.DetailPrefix + definition.RequestKey + ":exists", QueryOperator.Equal, QueryValue.FromBoolean(true))],
                };
                var compiled = QueryEngine.Compile(recipe);
                return new { recipe = compiled.Normalized, fields = QueryCatalog.DetailFields(definition), text = "Recette locale préparée : l’aperçu et les widgets n’utilisent que les résultats déjà mémorisés ; la lecture distante reste explicite." };
            }), "Transforme un SELECT testé sur ce poste en recette « WMI · Classe » (au moins une instance, nombre) sur les résultats mémorisés."),
        ];
    }
}
