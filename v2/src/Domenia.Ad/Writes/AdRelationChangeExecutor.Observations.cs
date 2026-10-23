using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdRelationChangeExecutor
{
    public async Task<WritePlanDraft> PlanObservationsAsync(string resultId, IReadOnlyList<string> keys, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(resultId); ArgumentNullException.ThrowIfNull(keys);
        if (keys.Count > WritePlans.MaxChanges) { throw WriteErrors.Refusal(RelationErrors.TooMany, RelationErrors.TooManyMessage(keys.Count)); }
        var local = await ReadAsync(cancellationToken).ConfigureAwait(false); var session = AdRelationSession.For(source);
        var origin = "Observations de la session";
        IReadOnlyCollection<StoredRelation> observations;
        if (resultId == RelationChange.SessionResultId) { observations = session.Snapshot(local.Session.Epoch); }
        else
        {
            var held = AdRelationResults.For(source).Recall<AdRelationObservationSet>(resultId, local.Session.Epoch);
            origin = held.Origin; observations = held.Relations.Values.ToArray();
            if (held.Relations.Any(p => p.Key != RelationRules.Key(p.Value))) { throw WriteErrors.Refusal(WriteErrors.Stale, "Clé d’observation incohérente."); }
        }
        if (observations.Any(r => session.ValidationError(r) is not null))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Résultat non qualifié ; seules les observations natives conservées par le moteur sont admissibles."); }
        var waiting = AdRelationSession.PrepareItems(local.Stored, observations);
        var selected = keys.ToHashSet(StringComparer.Ordinal);
        var items = (keys.Count == 0 ? waiting : waiting.Where(i => selected.Contains(RelationRules.Key(i.After!))))
            .Take(WritePlans.MaxChanges).ToArray();
        if (items.Length == 0) { throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune observation conservée à enregistrer ; les lignes sont déjà connues ou plus anciennes."); }
        var risks = new List<WriteRisk>(); var remaining = waiting.Length - items.Length;
        if (remaining > 0) { risks.Add(new(Tone.Info, FrenchText.Count(remaining, "observation restera", "observations resteront") + " en attente après ce lot ; la suite exigera une nouvelle confirmation.")); }
        if (items.Any(i => local.Stored.Rows.Any(r => r.Relation.Kind == RelationKind.Assignment && r.Relation.ComputerGuid == i.After!.ComputerGuid && r.Relation.UserGuid != i.After.UserGuid)))
        { risks.Add(new(Tone.Info, "Une affectation déclarée d’un autre compte est conservée ; la contradiction reste visible.")); }
        return Hold(local, "Enregistrer les observations", "Enregistrement d’observations",
            FrenchText.Count(items.Length, "observation sera enregistrée", "observations seront enregistrées") + " depuis « " + origin + " ». Aucune affectation déclarée n’est remplacée.",
            items.Length == 1 ? RelationChange.Pair(items[0].After!) : origin, items, risks, RelationChange.AddReversibility());
    }
}
