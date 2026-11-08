using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdRelationChangeExecutor
{
    public async Task<WritePlanDraft> PlanRemovalAsync(string key, string fingerprint, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(key); ArgumentNullException.ThrowIfNull(fingerprint);
        var local = await ReadAsync(cancellationToken).ConfigureAwait(false);
        var rows = local.Stored.Rows.Where(r => RelationRules.Key(r.Relation) == key).ToArray();
        if (rows.Length != 1) { throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Association introuvable ou ambiguë ; rechargez la liste."); }
        var relation = rows[0].Relation;
        if (RelationRules.Fingerprint(relation) != fingerprint)
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Association modifiée depuis son affichage ; rechargez la liste."); }
        var risks = new List<WriteRisk>();
        if (relation.Kind == RelationKind.Assignment)
        { risks.Add(new(Tone.Warn, "Affectation déclarée par un opérateur ; retirez-la seulement si elle est fausse. « Restaurer » la remet.")); }
        else if (relation.Kind == RelationKind.Imported)
        { risks.Add(new(Tone.Info, "Association importée ; « Annuler l’import » permet de retirer le lot entier.")); }
        return Hold(local, "Retirer l’association", "Retrait d’association",
            RelationChange.Pair(relation) + " sera retirée de la base locale. Le retrait sera journalisé et restaurable. Aucun objet AD n’est modifié.",
            RelationChange.Pair(relation), [new(RelationChangeOperation.Remove, relation, null, "Retirée du stockage local.", null)], risks,
            RelationChange.RemoveReversibility());
    }

    public async Task<WritePlanDraft> PlanRestoreAsync(string? entryId, CancellationToken cancellationToken)
    {
        var local = await ReadAsync(cancellationToken).ConfigureAwait(false);
        var history = await local.Writer.ReadRelationJournalAsync(cancellationToken).ConfigureAwait(false);
        if (!history.LegacyReadable) { throw WriteErrors.Refusal(WriteErrors.Stale, "Journal D1 inaccessible ; la restauration ne peut pas être préparée."); }
        var restorable = RelationRules.Restorable(history.Entries);
        var entry = (entryId is null ? restorable.FirstOrDefault() : restorable.FirstOrDefault(e => e.Id == entryId))
            ?? throw WriteErrors.Refusal(RelationErrors.NothingToRestore, RelationErrors.NothingToRestoreMessage);
        if (local.Stored.Rows.Any(r => RelationRules.Same(r.Relation, entry.Relation)))
        { throw WriteErrors.Refusal(RelationErrors.AlreadyExists, RelationErrors.AlreadyExistsMessage); }
        return Hold(local, RelationRules.RestoreLabel(entry.Relation.UserLogin, entry.Relation.Computer), "Restauration d’association",
            RelationChange.Pair(entry.Relation) + " sera remise depuis le journal, avec sa date, ses identités et sa source d’origine.",
            RelationChange.Pair(entry.Relation), [new(RelationChangeOperation.Add, null, entry.Relation, null, entry.Id)], [], RelationChange.AddReversibility());
    }

    public async Task<WritePlanDraft> PlanImportUndoAsync(string? batchId, CancellationToken cancellationToken)
    {
        var local = await ReadAsync(cancellationToken).ConfigureAwait(false);
        var records = local.Stored.Rows.Select(r => r.Relation).ToArray();
        var batch = batchId ?? RelationProjection.LastImport(records, source.Clock.GetUtcNow(), source.Zone)?.BatchId
            ?? throw WriteErrors.Refusal(RelationErrors.NoBatch, RelationErrors.NoBatchMessage);
        var rows = records.Where(r => r.Kind == RelationKind.Imported && string.Equals(r.BatchId ?? RelationImport.BatchToken(r.Details), batch, StringComparison.Ordinal))
            .OrderBy(r => r.Computer, StringComparer.Ordinal).ThenBy(RelationRules.Key, StringComparer.Ordinal).ToArray();
        if (rows.Length == 0) { throw WriteErrors.Refusal(RelationErrors.NoBatch, RelationErrors.NoBatchMessage); }
        var shown = rows.Take(WritePlans.MaxChanges).ToArray();
        var risks = new List<WriteRisk> { new(Tone.Warn, FrenchText.Count(shown.Length, "association importée sera retirée", "associations importées seront retirées") + " ; vérifiez le lot avant de confirmer.") };
        if (rows.Length > shown.Length)
        { risks.Add(new(Tone.Info, FrenchText.Count(rows.Length - shown.Length, "association restera", "associations resteront") + " dans le lot après ce retrait, limité à 64 lignes.")); }
        return Hold(local, "Annuler l’import", "Annulation d’import", "Retrait des associations du lot " + batch + ". Chaque retrait est journalisé et restaurable individuellement.",
            "Lot " + batch, shown.Select(r => new RelationChangeItem(RelationChangeOperation.Remove, r, null, "Import annulé (lot " + batch + ").", null)).ToArray(),
            risks, RelationChange.RemoveReversibility());
    }

    public Task<RelationAutoSave> SaveObservationsAsync(CancellationToken cancellationToken) =>
        AdRelationSession.For(source).SaveAsync(source.Epoch, cancellationToken);
}
