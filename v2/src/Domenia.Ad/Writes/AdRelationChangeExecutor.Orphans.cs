using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdRelationChangeExecutor
{
    public async Task<WritePlanDraft> PlanOrphanCleanupAsync(string checkId, IReadOnlyList<string> keys, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(checkId); ArgumentNullException.ThrowIfNull(keys);
        if (keys.Count > WritePlans.MaxChanges) { throw WriteErrors.Refusal(RelationErrors.TooMany, RelationErrors.TooManyMessage(keys.Count)); }
        var local = await ReadAsync(cancellationToken).ConfigureAwait(false);
        var check = AdRelationResults.For(source).Recall<AdRelationOrphanCheck>(checkId, local.Session.Epoch);
        if (check.StoreId != local.Stored.StoreId) { throw WriteErrors.Refusal(WriteErrors.Stale, "Contrôle d’une autre base locale."); }
        var records = local.Stored.Rows.GroupBy(r => RelationRules.Key(r.Relation), StringComparer.Ordinal).Where(g => g.Count() == 1)
            .ToDictionary(g => g.Key, g => g.Single().Relation, StringComparer.Ordinal);
        var selected = keys.Distinct(StringComparer.Ordinal).Where(k => check.Rows.TryGetValue(k, out var row) && records.TryGetValue(k, out var current)
            && !AdRelationsReader.Protected(current) && RelationRules.Fingerprint(current) == row.Fingerprint).Select(k => records[k]).ToImmutableArray();
        if (selected.Length == 0) { throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune association contrôlée, inchangée et non protégée n’est sélectionnée."); }
        await ValidateAbsenceAsync(selected, cancellationToken).ConfigureAwait(false);
        return Hold(local, "Retirer les associations à examiner", "Nettoyage des associations non retrouvées",
            FrenchText.Count(selected.Length, "association sera retirée", "associations seront retirées") + " localement, avec journal et restauration. Aucun objet AD n’est supprimé.",
            RelationChange.Changes(selected.Length), selected.Select(r => new RelationChangeItem(RelationChangeOperation.Remove, r, null,
                "Contrôle AD initial : " + check.Rows[RelationRules.Key(r)].Reason, null)).ToArray(),
            [new(Tone.Warn, "Non retrouvé ne signifie pas supprimé : droits de lecture ou renommage peuvent expliquer ce contrôle. Vérifiez les lignes sélectionnées."),
             new(Tone.Info, FrenchText.Count(keys.Distinct(StringComparer.Ordinal).Count() - selected.Length, "ligne non admissible conservée", "lignes non admissibles conservées") + ".")],
            RelationChange.RemoveReversibility(), selected);
    }

    private async Task ValidateAbsenceAsync(ImmutableArray<StoredRelation> records, CancellationToken token)
    {
        if (records.Length == 0) { return; }
        var domain = source.CurrentDirectory?.Domain ?? throw WriteErrors.Refusal(WriteErrors.Stale, "Domaine local indisponible.");
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(60), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token, elapsed.Token);
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, budget.Token).ConfigureAwait(false);
        var read = await AdRelationAbsence.CheckAsync(access, domain, records, budget.Token).ConfigureAwait(false);
        if (read.Uncertain > 0 || read.Missing.Count != records.Length)
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Objet désormais retrouvé ou contrôle non concluant ; aucune association retirée. Relancez le contrôle."); }
        access.EnsureCurrent();
    }
}
