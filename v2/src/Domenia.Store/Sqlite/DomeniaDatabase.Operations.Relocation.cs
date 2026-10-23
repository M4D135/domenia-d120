using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    /// <summary>Called inside the destination rebind transaction, while the original collection lease remains held.</summary>
    internal void RelocateOperations(SqliteDatabase db, string previousStoreId)
    {
        if (string.IsNullOrWhiteSpace(previousStoreId)) { throw new InvalidDataException("Identité du magasin d’origine requise."); }
        if (!Table(db, "domenia_v2_operations") || db.Scalar("SELECT 1 FROM domenia_v2_operations WHERE id=1;") is null) { return; }
        var before = ReadOperations(db, previousStoreId);
        var runs = before.Runs;
        if (before.Survey is { } survey)
        {
            var family = survey.Mode == SurveyMode.Ping ? OperationsCollectionFamily.Presence : OperationsCollectionFamily.Inventory;
            var success = runs.Where(r => r.Family == family && r.Subtree == survey.Scope.Subtree && DistinguishedName.AreEqual(r.ScopeDn, survey.Scope.Dn))
                .Select(r => r.SuccessAt).Max();
            var cancelled = new OperationsCollectionRun(family, survey.Scope.Dn, survey.Scope.Label, survey.Scope.Subtree, clock.GetUtcNow(),
                OperationsCollectionStatus.Cancelled, survey.Completed.Length, survey.Targets.Length, survey.Failed, success,
                "Bascule de base : plan de reprise abandonné, mesures déjà enregistrées conservées.");
            runs = [.. runs.Append(cancelled).OrderByDescending(r => r.AttemptAt).Take(1000)];
        }
        var next = before with { StoreId = StoreId, Revision = checked(before.Revision + 1), Runs = runs, Survey = null };
        OperationsPersistence.Validate(next);
        var payload = JsonSerializer.Serialize(next, Json);
        if (System.Text.Encoding.UTF8.GetByteCount(payload) > 8_388_608) { throw new InvalidDataException("Journal déplacé supérieur à 8 Mio."); }
        db.Execute("UPDATE domenia_v2_operations SET revision=?1,payload=?2,sha256=?3 WHERE id=1;", next.Revision, payload, OperationsHash(payload));
        if (JsonSerializer.Serialize(ReadOperations(db), Json) != payload) { throw new InvalidDataException("Journal déplacé non conforme à la relecture."); }
        // The owner increments the global store revision as part of its single relocation transaction.
    }
}
