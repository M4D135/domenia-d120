using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Executor of the changes of the local base of the « Synchronisation et base autonome » screen (docs/ops/synchro.md § 5,
/// docs/WRITES.md § 6), served by the source of the mode: Domenia.Simulation changes the base kept in memory, Domenia.Store
/// will change the SQLite base in wave 3. No plan of this executor writes Active Directory: the base is a local copy. Each plan
/// read builds a draft from a fresh read of the base (and of the batch kept by the engine); the circuit seals it, the operator
/// confirms it, write.execute runs it once with its receipt and its re-read. Pure rules: <see cref="SyncStoreChange"/>.
/// </summary>
public interface ISyncStoreExecutor : IWriteExecutor
{
    /// <summary>Storage of a result kept by the engine: a read of the directory, a verification, a census gap read or the shared park survey.</summary>
    Task<WritePlanDraft> PlanBatchAsync(string batchId, CancellationToken cancellationToken);

    /// <summary>Dated snapshot of the base for the scope (Domenia 1 point 30); no directory read.</summary>
    Task<WritePlanDraft> PlanSnapshotCaptureAsync(string? label, SyncScope scope, CancellationToken cancellationToken);

    /// <summary>Deletion of one snapshot from the base.</summary>
    Task<WritePlanDraft> PlanSnapshotDeleteAsync(string snapshotId, CancellationToken cancellationToken);

    /// <summary>« Oublier les relevés »: the scanning state of the park only, after a verified backup (Domenia 1 FI-13).</summary>
    Task<WritePlanDraft> PlanParkResetAsync(CancellationToken cancellationToken);
}

/// <summary>Operation of a plan of the local base, read back from its first change.</summary>
public enum SyncStoreOperation
{
    Batch,
    SnapshotCapture,
    SnapshotDelete,
    ParkReset,
}

/// <summary>The first change of a plan decoded: operation, identifier, fingerprint and count it was planned with.</summary>
public sealed record SyncStoreHead(SyncStoreOperation Operation, string Kind, string Id, string Sha256, int Count);

/// <summary>
/// Pure rules of the plans of the local base: targets (one fixed identity per store, so an uncertain receipt only holds back its
/// own store), drafts in plain words with their raw values, decoding of a plan by the executor. The first change always names
/// the operation, the identifier and the fingerprint the operator saw; the others describe its effects.
/// </summary>
public static class SyncStoreChange
{
    public const string Kind = "synchro.store";

    public const string BatchAttribute = "batch";
    public const string SnapshotCaptureAttribute = "snapshot.capture";
    public const string SnapshotDeleteAttribute = "snapshot.delete";
    public const string ParkResetAttribute = "park.reset";

    /// <summary>Identity of the index of the base as the target of a plan (it is not a directory object).</summary>
    public static readonly Guid IndexStoreGuid = new("5e0c1a7b-2f4d-4c8e-9a61-3b7d2e9f4a10");

    /// <summary>Identity of the snapshots of the base.</summary>
    public static readonly Guid SnapshotStoreGuid = new("8a3f6d21-7c4b-4e19-b0d2-6f1e9c3a5b77");

    /// <summary>Identity of the park survey of the base.</summary>
    public static readonly Guid ParkStoreGuid = new("c4e9b2a0-1d3f-4a6c-8e57-2b9f0d6a1c38");

    private static string C => FrenchText.Colon;

    public static WriteTarget IndexTarget(string name, bool simulated) => new(
        "database", "Base locale", name,
        simulated ? "Base locale de la simulation · copie de l’annuaire fictif, en mémoire" : "Base locale de Domenia · copie de l’annuaire",
        IndexStoreGuid.ToString("D"), null);

    public static WriteTarget SnapshotTarget(string name, bool simulated) => new(
        "database", "Relevés de l’annuaire", name,
        simulated ? "Base locale de la simulation · relevés datés" : "Base locale de Domenia · relevés datés",
        SnapshotStoreGuid.ToString("D"), null);

    public static WriteTarget ParkTarget(string name, bool simulated) => new(
        "database", "Relevé du parc", name,
        simulated ? "Base locale de la simulation · relevé du parc" : "Base locale de Domenia · relevé du parc",
        ParkStoreGuid.ToString("D"), null);

    /// <summary>Raw value of the first change: « kind:id|sha256|count ».</summary>
    public static string HeadValue(string kind, string id, string sha256, int count)
    {
        ArgumentException.ThrowIfNullOrEmpty(kind);
        ArgumentException.ThrowIfNullOrEmpty(id);
        return kind + ":" + id + "|" + (sha256 ?? "") + "|" + count.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    /// <summary>Decodes the first change of a plan; null when the plan is not one of this executor.</summary>
    public static SyncStoreHead? Head(WritePlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        if (!string.Equals(plan.Kind, Kind, StringComparison.Ordinal) || plan.Changes.IsDefaultOrEmpty)
        {
            return null;
        }
        var first = plan.Changes[0];
        var operation = first.Attribute switch
        {
            BatchAttribute => SyncStoreOperation.Batch,
            SnapshotCaptureAttribute => SyncStoreOperation.SnapshotCapture,
            SnapshotDeleteAttribute => SyncStoreOperation.SnapshotDelete,
            ParkResetAttribute => SyncStoreOperation.ParkReset,
            _ => (SyncStoreOperation?)null,
        };
        var raw = first.AfterValue ?? first.BeforeValue;
        if (operation is null || raw is null)
        {
            return null;
        }
        var colon = raw.IndexOf(':', StringComparison.Ordinal);
        string[] parts = colon < 0 ? [] : raw[(colon + 1)..].Split('|');
        if (colon <= 0 || parts.Length != 3 || !int.TryParse(parts[2], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var count))
        {
            return null;
        }
        return new SyncStoreHead(operation.Value, raw[..colon], parts[0], parts[1], count);
    }

    /// <summary>
    /// Draft of a plan of the base. <paramref name="effects"/> describe the consequences (counts, coverage, checkpoint); the
    /// confirmation is simple because nothing leaves the workstation and the base is backed up first when it is rewritten.
    /// </summary>
    public static WritePlanDraft Draft(string title, string label, string summary, WriteTarget target, WriteChange head, IEnumerable<WriteChange> effects,
        IEnumerable<WriteRisk> risks, WriteReversibility reversibility, string? controller)
    {
        ArgumentNullException.ThrowIfNull(head);
        ArgumentNullException.ThrowIfNull(effects);
        ArgumentNullException.ThrowIfNull(risks);
        var changes = ImmutableArray.CreateBuilder<WriteChange>();
        changes.Add(head);
        changes.AddRange(effects.Take(WritePlans.MaxChanges - 1));
        var allRisks = ImmutableArray.CreateBuilder<WriteRisk>();
        allRisks.Add(new WriteRisk(Tone.Info, "Base locale de Domenia seulement" + C + "aucun objet Active Directory n’est modifié, rien ne quitte ce poste."));
        allRisks.AddRange(risks);
        return new WritePlanDraft(Kind, title, label, summary, target, changes.ToImmutable(), allRisks.ToImmutable(),
            new WriteConfirmation(false, null, "Confirmation simple" + C + "changement de la base locale seulement, tracé par un reçu puis relu."),
            reversibility, controller);
    }

    /// <summary>Effect line « Objets ajoutés : — → 12 objets » with its raw value « added=12 ».</summary>
    public static WriteChange Effect(string attribute, string label, WriteChangeKind kind, string? before, string? after, string? beforeValue, string? afterValue) =>
        new(attribute, label, kind, before, after, beforeValue, afterValue);

    /// <summary>Count in plain words for an effect line.</summary>
    public static string Objects(int count) => FrenchText.Count(count, "objet", "objets");

    public static WriteReversibility BackedUp(string backupNotice) => new(true, "Point de retour" + C + "sauvegarde vérifiée",
        backupNotice + " Une compensation reste un nouveau geste de l’opérateur (restauration de la sauvegarde ou nouvelle lecture), jamais automatique.");

    public static WriteReversibility SnapshotRemovable { get; } = new(true, "Relevé supprimable", "Le relevé pourra être supprimé ensuite depuis la liste des relevés.");

    public static WriteReversibility Definitive { get; } = new(false, "Définitif", "Un relevé supprimé ne se restaure pas" + SyncText.Semi + " les prochains relevés repartent de la base du moment.");
}
