using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Event « schema.read:stage »: the stage of the read under way, in words.</summary>
public sealed record SchemaReadStageEvent(SchemaReadStage Stage, string Label);

/// <summary>
/// Directory schema screen (docs/ops/schema.md, Domenia 1 points 28 and 29): status of the schema read in this session, the
/// read itself on an explicit gesture (NetworkRead, served by the simulation), then the catalog, the class and attribute
/// details, the analysis of an LDAP filter and the draft insertion of an attribute, all computed in memory (Local). Nothing here
/// changes the schema; nothing reads an object value. Handlers only validate the arguments and delegate to
/// <see cref="SchemaService"/>, <see cref="SchemaRules"/> and <see cref="LdapFilterAnalyzer"/>.
/// </summary>
public sealed class SchemaOperations : IOperationModule
{
    private static readonly string[] ListArguments = ["kind", "text", "limit"];
    private static readonly string[] NameArguments = ["name"];
    private static readonly string[] AnalyzeArguments = ["filter"];
    private static readonly string[] InsertArguments = ["filter", "attribute"];

    public string Screen => "schema";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var service = SchemaService.From(context);
        return
        [
            new OperationDefinition("schema.status", OperationClass.Local, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.StatusAsync(cancellationToken).ConfigureAwait(false);
            }, "État du schéma lu dans cette session (contrôleur, date, nombres, lecture incomplète)."),

            new OperationDefinition("schema.read", OperationClass.NetworkRead, async (args, bridge, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                var progress = new ImmediateProgress<SchemaReadStage>(stage => bridge.Publish("stage", new SchemaReadStageEvent(stage, StageLabel(stage))));
                return await service.ReadAsync(progress, cancellationToken).ConfigureAwait(false);
            }, "Lecture unique et bornée des définitions du schéma (8 000 attributs, 3 000 classes, 90 s), sur geste explicite.", ServedInSimulation: true),

            new OperationDefinition("schema.list", OperationClass.Local, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, ListArguments);
                var attributes = BridgeArguments.GetString(values, "kind") switch
                {
                    "classes" => false,
                    "attributes" => true,
                    _ => throw BridgeArguments.Invalid(FrenchText.Quote("kind") + " vaut classes ou attributes."),
                };
                var text = BridgeArguments.GetOptionalString(values, "text") ?? "";
                if (text.Length > SchemaRules.MaxListText)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus " + FrenchText.Integer(SchemaRules.MaxListText) + " caractères.");
                }
                var limit = OptionalInteger(values, "limit", 1, SchemaRules.MaxListLimit) ?? SchemaRules.DefaultListLimit;
                var catalog = await service.RequireCatalogAsync(cancellationToken).ConfigureAwait(false);
                return SchemaRules.FindEntries(catalog, text, attributes, limit);
            }, "Classes ou attributs du schéma lu dont le nom ou la description contient le texte (total exact, 500 lignes par défaut)."),

            new OperationDefinition("schema.class", OperationClass.Local, async (args, _, cancellationToken) =>
            {
                var name = Name(args);
                var catalog = await service.RequireCatalogAsync(cancellationToken).ConfigureAwait(false);
                return SchemaRules.ClassDetail(catalog, name);
            }, "Détail d’une classe : chaîne d’héritage, auxiliaires et attributs possibles, obligatoires d’abord."),

            new OperationDefinition("schema.attribute", OperationClass.Local, async (args, _, cancellationToken) =>
            {
                var name = Name(args);
                var catalog = await service.RequireCatalogAsync(cancellationToken).ConfigureAwait(false);
                return SchemaRules.AttributeDetail(catalog, name);
            }, "Détail d’un attribut : syntaxe, valeurs, index, catalogue global, indicateurs, exemple de critère et classes qui l’utilisent."),

            new OperationDefinition("schema.filter.analyze", OperationClass.Local, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, AnalyzeArguments);
                var filter = BridgeArguments.GetString(values, "filter");
                var catalog = await service.CatalogAsync(cancellationToken).ConfigureAwait(false);
                return LdapFilterAnalyzer.Analyze(filter, catalog);
            }, "Analyse locale du coût d’un filtre LDAP (RFC 4515) selon les index du schéma lu ; rien n’est envoyé au contrôleur."),

            new OperationDefinition("schema.filter.insert", OperationClass.Local, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, InsertArguments);
                var filter = BridgeArguments.GetOptionalString(values, "filter") ?? "";
                var name = RequireName(BridgeArguments.GetString(values, "attribute"), "attribute");
                var catalog = await service.RequireCatalogAsync(cancellationToken).ConfigureAwait(false);
                var attribute = catalog.FindAttribute(name)
                    ?? throw new DomeniaOperationException(SchemaErrors.UnknownAttribute, SchemaErrors.UnknownAttributeMessage);
                return LdapFilterAnalyzer.Insert(filter, attribute, catalog);
            }, "Ajoute au brouillon de filtre un exemple de critère sur l’attribut choisi, puis l’analyse ; rien n’est exécuté."),
        ];
    }

    private static string StageLabel(SchemaReadStage stage) => stage switch
    {
        SchemaReadStage.Context => "Contexte du schéma sur le contrôleur",
        SchemaReadStage.Attributes => "Définitions des attributs (" + FrenchText.Integer(SchemaReadLimits.Default.MaxAttributes) + " au plus)",
        _ => "Définitions des classes (" + FrenchText.Integer(SchemaReadLimits.Default.MaxClasses) + " au plus)",
    };

    private static string Name(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, NameArguments);
        return RequireName(BridgeArguments.GetString(values, "name"), "name");
    }

    private static string RequireName(string value, string argument) =>
        SchemaRules.IsValidName(value.Trim())
            ? value.Trim()
            : throw BridgeArguments.Invalid(FrenchText.Quote(argument) + " doit être un nom LDAP (lettres, chiffres et tirets, 128 au plus).");

    private static int? OptionalInteger(IReadOnlyDictionary<string, JsonElement> values, string name, int min, int max)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) && number >= min && number <= max
            ? number
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un entier de " + FrenchText.Integer(min) + " à " + FrenchText.Integer(max) + ".");
    }
}

/// <summary>Progress reported at once on the calling thread (no synchronization context: handlers run on the thread pool).</summary>
internal sealed class ImmediateProgress<T>(Action<T> report) : IProgress<T>
{
    public void Report(T value) => report(value);
}
