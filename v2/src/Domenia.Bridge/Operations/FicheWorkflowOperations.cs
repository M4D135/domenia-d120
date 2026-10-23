using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Explicit preparation only; every effective mutation remains in write.execute.</summary>
public sealed class FicheWorkflowOperations : IOperationModule
{
    public string Screen => "fiche";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
    [
        new("fiche.lifecycle.create", context.Mode == AppMode.Simulation ? OperationClass.LocalRead : OperationClass.NetworkRead, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["kind", "dn", "guid", "add", "remove", "fields", "target"]);
            var kind = BridgeArguments.GetString(values, "kind") switch { "arrival" => LifecycleKind.Arrival, "serviceChange" => LifecycleKind.ServiceChange, "suspension" => LifecycleKind.Suspension, _ => throw BridgeArguments.Invalid("Séquence inconnue.") };
            var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
            if (!Guid.TryParse(BridgeArguments.GetString(values, "guid"), out var guid)) { throw BridgeArguments.Invalid("GUID du compte requis."); }
            var fields = ImmutableDictionary.CreateBuilder<string, string?>(StringComparer.OrdinalIgnoreCase);
            if (values.TryGetValue("fields", out var map))
            {
                if (map.ValueKind != JsonValueKind.Object || map.EnumerateObject().Count() > 20) { throw BridgeArguments.Invalid("Champs hors limites."); }
                foreach (var field in map.EnumerateObject())
                {
                    if (field.Value.ValueKind is not (JsonValueKind.String or JsonValueKind.Null) || fields.ContainsKey(field.Name)) { throw BridgeArguments.Invalid("Champ invalide ou répété."); }
                    fields.Add(field.Name, field.Value.ValueKind == JsonValueKind.Null ? null : field.Value.GetString());
                }
            }
            var target = BridgeArguments.GetOptionalString(values, "target");
            return await LifecycleWorkflow.From(context).CreateAsync(new(kind, dn, guid, Dns(values, "add"), Dns(values, "remove"), fields.ToImmutable(), target), token).ConfigureAwait(false);
        }, "Prépare une séquence bornée sur un compte identifié ; aucune écriture envoyée."),
        new("fiche.lifecycle.get", OperationClass.Local, async (args, _, token) =>
            await LifecycleWorkflow.From(context).ReadAsync(Id(BridgeArguments.ReadObject(args, ["id"])), token).ConfigureAwait(false),
            "État local de la séquence de cette session ; aucune étape relancée."),
        new("fiche.lifecycle.close", OperationClass.Local, async (args, _, token) =>
        {
            await LifecycleWorkflow.From(context).CloseAsync(Id(BridgeArguments.ReadObject(args, ["id"])), token).ConfigureAwait(false);
            return true;
        }, "Ferme la séquence en mémoire ; conserve tous ses reçus et ne rejoue aucune écriture."),
        new("fiche.lifecycle.prepare", context.Mode == AppMode.Simulation ? OperationClass.LocalRead : OperationClass.NetworkRead, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["id", "review"]);
            return await LifecycleWorkflow.From(context).PrepareAsync(Id(values), BridgeArguments.GetBoolean(values, "review"), token).ConfigureAwait(false);
        }, "Relit et prépare une seule étape ; le contrôle de fiche exige un geste explicite."),
        new("fiche.lifecycle.plan", OperationClass.LocalRead, async (args, _, token) =>
            await LifecycleWorkflow.From(context).PreparedAsync(Id(BridgeArguments.ReadObject(args, ["id"])), token).ConfigureAwait(false),
            "Présente le plan déjà préparé de l’étape, sans nouvelle lecture ni nouvelle écriture."),
        new("fiche.lifecycle.record", OperationClass.LocalRead, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["id", "receipt"]);
            return await LifecycleWorkflow.From(context).RecordAsync(Id(values), BridgeArguments.GetString(values, "receipt"), token).ConfigureAwait(false);
        }, "Relit le reçu de l’étape et bloque la suite si son effet n’est pas prouvé."),
        new("fiche.compensation.context", OperationClass.LocalRead, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["id"]);
            var id = BridgeArguments.GetString(values, "id");
            if (id.Length is < 1 or > 64) { throw BridgeArguments.Invalid("Référence du reçu invalide."); }
            var receipt = await WriteCircuit.From(context).GetAsync(id, token).ConfigureAwait(false);
            var assessment = WriteKindRules.Assess(receipt);
            return new { receipt.Id, Dn = CompensationPlanner.CurrentDn(receipt.Plan), Guid = receipt.Target.ObjectGuid, assessment };
        }, "Cible actuelle attendue d’une compensation, depuis le reçu local uniquement."),
        new("fiche.compensation.plan", context.Mode == AppMode.Simulation ? OperationClass.LocalRead : OperationClass.NetworkRead, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["id", "dn"]);
            var id = BridgeArguments.GetString(values, "id");
            if (id.Length is < 1 or > 64) { throw BridgeArguments.Invalid("Référence du reçu invalide."); }
            var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
            return await CompensationPlanner.PlanAsync(context, id, dn, token).ConfigureAwait(false);
        }, "Prépare un inverse exact seulement si la relecture retrouve les valeurs écrites par le reçu."),
    ];

    private static string Id(IReadOnlyDictionary<string, JsonElement> values)
    {
        var id = BridgeArguments.GetString(values, "id");
        return id.Length is > 0 and <= 64 ? id : throw BridgeArguments.Invalid("Identifiant de séquence invalide.");
    }
    private static ImmutableArray<string> Dns(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var list)) { return []; }
        if (list.ValueKind != JsonValueKind.Array || list.GetArrayLength() > 20) { throw BridgeArguments.Invalid("Vingt groupes au plus."); }
        return [.. list.EnumerateArray().Select(v => v.ValueKind == JsonValueKind.String
            ? BridgeArguments.RequireDistinguishedName(v.GetString()!, name) : throw BridgeArguments.Invalid("DN de groupe requis."))];
    }
}
