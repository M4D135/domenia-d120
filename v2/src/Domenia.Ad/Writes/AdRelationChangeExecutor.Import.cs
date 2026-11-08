using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdRelationChangeExecutor
{
    public async Task<WritePlanDraft> PlanImportAsync(string previewId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(previewId);
        var local = await ReadAsync(cancellationToken).ConfigureAwait(false);
        var held = AdRelationResults.For(source).Recall<AdRelationImportPreview>(previewId, local.Session.Epoch);
        if (held.StoreId != local.Stored.StoreId) { throw WriteErrors.Refusal(WriteErrors.Stale, "Aperçu d’une autre base ; relancez l’import."); }
        var lookup = AdRelationLookup.For(source.CurrentDirectory!); var rows = new List<StoredRelation>(); var skipped = 0;
        foreach (var incoming in held.Importable)
        {
            var user = lookup.User(incoming.UserGuid, incoming.UserLogin); var computer = lookup.Computer(incoming.ComputerGuid, incoming.Computer);
            if (user is null || computer is null || !DistinguishedName.AreEqual(user.Dn, incoming.UserDn!) || !DistinguishedName.AreEqual(computer.Dn, incoming.ComputerDn!)
                || user.Login != incoming.UserLogin || computer.Name != incoming.Computer)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Une identité de l’index local a changé depuis l’aperçu ; relancez-le."); }
            if (local.Stored.Rows.Any(r => RelationImport.SameComputer(r.Relation, incoming.ComputerGuid, incoming.Computer))) { skipped++; }
            else { rows.Add(incoming); }
        }
        if (rows.Count == 0) { throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune ligne à importer ; les postes sont déjà associés ou aucune ligne de l’aperçu n’est valide."); }
        var preview = held.Preview; var risks = new List<WriteRisk> { new(Tone.Info, "Identités connues de l’index local ; aucune vérification réseau actuelle. Source du format imposée, aucune association existante remplacée.") };
        if (skipped > 0) { risks.Add(new(Tone.Warn, FrenchText.Count(skipped, "poste associé depuis l’aperçu conservé", "postes associés depuis l’aperçu conservés") + ".")); }
        if (preview.Counts.Deferred > 0) { risks.Add(new(Tone.Info, "Lignes au-delà de 64 reportées ; un nouvel aperçu du fichier permettra de préparer la suite.")); }
        return Hold(local, "Importer " + RelationChange.Changes(rows.Count), "Import d’associations",
            FrenchText.Count(rows.Count, "association sera ajoutée", "associations seront ajoutées") + " depuis " + preview.FileName + ". Lot de retour arrière : " + preview.BatchId + ".",
            preview.Source + " · " + preview.FileName, rows.Select(r => new RelationChangeItem(RelationChangeOperation.Add, null, r,
                preview.Source + " " + preview.FileName + " (lot " + preview.BatchId + ").", null)).ToArray(), risks, RelationChange.ImportReversibility(preview.BatchId));
    }
}
