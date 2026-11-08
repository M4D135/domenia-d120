using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>Category of one read row against the base.</summary>
public enum ReconcileCategory
{
    Added,
    Moved,
    Renamed,
    Changed,
    Refreshed,
    Unchanged,
    Conflict,
}

/// <summary>One read row with its category and, for a change, the fields that differ.</summary>
public sealed record ReconcileItem(IndexRecord Row, IndexRecord? Existing, ReconcileCategory Category, string Detail);

/// <summary>
/// Reconciliation of a read with the base, before anything is written: rows to write, rows kept because the base holds a more
/// recent observation, rows of the scope a complete read did not return (recorded as not seen, never deleted).
/// </summary>
public sealed record SyncReconciliation(
    ImmutableArray<ReconcileItem> Items,
    ImmutableArray<IndexRecord> Unseen,
    SyncReconcileCounts Counts,
    ImmutableArray<SyncReconcileSample> Samples);

/// <summary>How an incremental pass is used (Domenia 1 Resolve-DomeniaIncrementalSync).</summary>
public sealed record SyncIncremental(bool FullRescan, bool CanAssertAbsence, bool Advances, SyncCheckpoint? Next, ImmutableArray<string> Notes);

/// <summary>
/// Pure rules of the storage of a read (Domenia 1 IndexBulk, Merge-DomeniaIndexRows and points 13 to 15): identity by GUID (a
/// rename or a move replaces the row, never a duplicate), a newer local observation is never overwritten, the objects of the
/// scope absent from a complete read leave the copy as « not seen », the batch is fingerprinted (SHA-256 of its canonical rows)
/// and checked again (count and identities) before the commit, and the checkpoint only moves with the data it describes.
/// </summary>
public static class SyncReconcile
{
    /// <summary>Examples shown per category in the preview of a storage.</summary>
    public const int SamplesPerCategory = 4;

    private static readonly JsonSerializerOptions LineJson = new() { WriteIndented = false };

    /// <summary>Compared values of two versions of an object (Domenia 1 Get-DomeniaSnapshotFields), with their labels.</summary>
    public static ImmutableArray<(string Field, string Label, Func<IndexRecord, string> Value)> Fields { get; } =
    [
        ("type", "Type", r => SyncIndex.TypeLabel(r.Type)),
        ("name", "Nom", r => r.Name),
        ("login", "Identifiant", r => r.Login ?? ""),
        ("upn", "UPN ou nom DNS", r => r.Upn ?? ""),
        ("display", "Nom affiché", r => r.DisplayName ?? ""),
        ("description", "Description", r => r.Description ?? ""),
        ("extra", "Service, système ou lieu", r => r.Extra ?? ""),
        ("state", "État du compte", r => SyncIndex.StateLabel(r.Enabled)),
    ];

    /// <summary>
    /// SHA-256 (lower-case hex) of the canonical lines of a batch: one compact JSON line per row, sorted by GUID, without the
    /// moment of observation. Two reads of the same data give the same fingerprint.
    /// </summary>
    public static string Fingerprint(IEnumerable<IndexRecord> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var builder = new StringBuilder();
        foreach (var row in rows.OrderBy(r => r.ObjectGuid.ToString("D"), StringComparer.Ordinal))
        {
            builder.Append(JsonSerializer.Serialize(new
            {
                g = row.ObjectGuid.ToString("D"),
                t = row.Type == IndexObjectType.Computer ? "Machine" : "Utilisateur",
                n = row.Name,
                l = row.Login,
                u = row.Upn,
                d = row.DisplayName,
                s = row.Description,
                x = row.Extra,
                e = row.Enabled,
                dn = row.Dn,
                w = row.WhenChanged?.UtcDateTime.ToString("o", CultureInfo.InvariantCulture),
                v = row.Usn,
                ll = row.LastLogon?.UtcDateTime.ToString("o", CultureInfo.InvariantCulture),
                lk = row.Laps.ToString(),
                le = row.LapsExpiration?.UtcDateTime.ToString("o", CultureInfo.InvariantCulture),
            }, LineJson)).Append('\n');
        }
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(builder.ToString())));
    }

    /// <summary>Fingerprint of the identities only (count and GUIDs), the second check of a batch before its commit.</summary>
    public static string IdentityFingerprint(IEnumerable<Guid> identities)
    {
        ArgumentNullException.ThrowIfNull(identities);
        var text = string.Join('\n', identities.Select(g => g.ToString("D")).Order(StringComparer.Ordinal));
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    }

    /// <summary>Labels of the values that differ between two versions of an object, « » when none.</summary>
    public static string ChangedFields(IndexRecord before, IndexRecord after)
    {
        ArgumentNullException.ThrowIfNull(before);
        ArgumentNullException.ThrowIfNull(after);
        return string.Join(", ", Fields.Where(f => !string.Equals(f.Value(before), f.Value(after), StringComparison.Ordinal)).Select(f => f.Label));
    }

    /// <summary>
    /// The limit that makes a read incomplete although no quota, budget or stop cut it (Domenia 1 Get-DomeniaIndexWorkerCode
    /// and IndexBulk): a class whose read failed (« échec d’une classe = passe incomplète, jamais un annuaire vide »), a complete
    /// read that returns no object while the base holds some in the scope, an empty census of the domain. Only an explicit
    /// rebuild (<paramref name="rebuild"/>, Domenia 1 ReplaceAll) may confirm an empty domain after a checkpoint. Null: nothing
    /// cuts the read.
    /// </summary>
    /// <param name="read">Objects returned by the read.</param>
    /// <param name="knownInScope">Objects of the base inside the scope of the read.</param>
    /// <param name="failedClasses">Classes whose read failed (« postes », « comptes »), named by the reader.</param>
    /// <param name="census">Identities of the census of a domain pass; null when the pass has no census (OU, incremental part).</param>
    /// <param name="domainPass">The read covers the domain (changes of the domain or rebuild).</param>
    /// <param name="hasCheckpoint">The base holds a checkpoint of the domain (it was built once).</param>
    /// <param name="rebuild">The operator asked a complete rebuild explicitly.</param>
    public static SyncCut? EmptyReadCut(int read, int knownInScope, IReadOnlyCollection<string> failedClasses, int? census, bool domainPass, bool hasCheckpoint, bool rebuild)
    {
        ArgumentNullException.ThrowIfNull(failedClasses);
        var c = SyncText.C;
        var readText = FrenchText.Count(read, "objet relu", "objets relus") + " dans la passe";
        if (failedClasses.Count > 0)
        {
            return new SyncCut("erreur", 0, "Lecture des " + string.Join(" et des ", failedClasses) + " en échec" + c + "passe incomplète, jamais un annuaire vide (" + readText
                + "). Aucune absence n’est déduite et le repère ne bouge pas.");
        }
        if (rebuild)
        {
            return null;
        }
        if (domainPass && census is 0 && (knownInScope > 0 || hasCheckpoint))
        {
            return new SyncCut("vide", 0, "Recensement vide" + c + "relancez une reconstruction complète explicite pour confirmer une base vide (" + readText + "). Aucune absence ni nouveau repère ne sont validés.");
        }
        if (read == 0 && knownInScope > 0)
        {
            return new SyncCut("vide", 0, domainPass && hasCheckpoint
                ? "Domaine vide après le repère" + c + "une reconstruction complète explicite est exigée pour vider la base. Aucune absence n’est déduite."
                : "Lecture complète vide alors que la base contient " + FrenchText.Count(knownInScope, "objet", "objets") + " dans ce périmètre" + c
                    + "passe tenue pour incomplète, aucune absence n’est déduite.");
        }
        return null;
    }

    /// <summary>
    /// Refusal of the storage of a batch (Domenia 1 IndexBulk): a complete domain pass whose census is empty while the base is
    /// not, outside an explicit rebuild. Null: the batch may be stored.
    /// </summary>
    public static string? StorageRefusal(bool domainPass, bool complete, bool rebuild, int census, int baseCount)
    {
        if (domainPass && complete && !rebuild && census == 0 && baseCount > 0)
        {
            return "Recensement vide" + SyncText.C + "reconstruction complète explicite requise, transaction refusée. Rien n’a été écrit.";
        }
        return null;
    }

    /// <summary>
    /// Fingerprint of a preview (SHA-256 of « GUID|category » lines and the unseen GUIDs): two previews with the same counts but
    /// other objects never pass for the same preview when the plan is checked again before its commit.
    /// </summary>
    public static string PreviewFingerprint(SyncReconciliation reconciliation)
    {
        ArgumentNullException.ThrowIfNull(reconciliation);
        var lines = reconciliation.Items.Select(i => i.Row.ObjectGuid.ToString("D") + "|" + CategoryKey(i.Category))
            .Concat(reconciliation.Unseen.Select(u => u.ObjectGuid.ToString("D") + "|unseen"))
            .Order(StringComparer.Ordinal);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join('\n', lines))));
    }

    /// <summary>
    /// Reconciles a read with the base. <paramref name="scopeDn"/> is the OU read with its sub-OUs, or null for the domain;
    /// <paramref name="assertAbsence"/> is true only for a complete read of the whole scope on which absences may be recorded.
    /// An empty read never asserts an absence (it would empty the scope), unless <paramref name="rebuild"/> confirms it.
    /// </summary>
    public static SyncReconciliation Reconcile(IReadOnlyDictionary<Guid, IndexRecord> current, IReadOnlyCollection<IndexRecord> read, string? scopeDn, bool assertAbsence, bool rebuild = false)
    {
        ArgumentNullException.ThrowIfNull(current);
        ArgumentNullException.ThrowIfNull(read);
        assertAbsence = assertAbsence && (read.Count > 0 || rebuild);
        var items = ImmutableArray.CreateBuilder<ReconcileItem>(read.Count);
        var seen = new HashSet<Guid>();
        foreach (var row in read)
        {
            if (!seen.Add(row.ObjectGuid))
            {
                continue;
            }
            if (!current.TryGetValue(row.ObjectGuid, out var existing))
            {
                items.Add(new ReconcileItem(row, null, ReconcileCategory.Added, "Nouveau dans la base" + SyncText.C + SyncLocations.Location(row.Dn)));
                continue;
            }
            if (existing.ObservedAt > row.ObservedAt)
            {
                items.Add(new ReconcileItem(row, existing, ReconcileCategory.Conflict, "Observation locale plus récente conservée (" + SyncLocations.Location(existing.Dn) + ")"));
                continue;
            }
            if (!SyncLocations.Same(existing.Dn, row.Dn))
            {
                var move = SyncLocations.Move(existing.Dn, row.Dn, scopeDn);
                items.Add(new ReconcileItem(row, existing, move.Kind == MoveKind.Renamed ? ReconcileCategory.Renamed : ReconcileCategory.Moved, move.Text));
                continue;
            }
            var fields = ChangedFields(existing, row);
            if (fields.Length > 0)
            {
                items.Add(new ReconcileItem(row, existing, ReconcileCategory.Changed, "Valeurs modifiées" + SyncText.C + fields));
            }
            else if (existing.Usn != row.Usn || existing.WhenChanged != row.WhenChanged || existing.LastLogon != row.LastLogon || existing.LapsExpiration != row.LapsExpiration)
            {
                items.Add(new ReconcileItem(row, existing, ReconcileCategory.Refreshed, "Dates de l’annuaire mises à jour"));
            }
            else
            {
                items.Add(new ReconcileItem(row, existing, ReconcileCategory.Unchanged, "Inchangé"));
            }
        }
        var unseen = assertAbsence
            ? current.Values.Where(r => !seen.Contains(r.ObjectGuid) && (scopeDn is null || SyncLocations.InScope(r.Dn, scopeDn)))
                .OrderBy(r => r.Dn, StringComparer.OrdinalIgnoreCase).ToImmutableArray()
            : [];
        var built = items.ToImmutable();
        int Count(ReconcileCategory category) => built.Count(i => i.Category == category);
        var added = Count(ReconcileCategory.Added);
        var moved = Count(ReconcileCategory.Moved);
        var renamed = Count(ReconcileCategory.Renamed);
        var changed = Count(ReconcileCategory.Changed);
        var refreshed = Count(ReconcileCategory.Refreshed);
        var counts = new SyncReconcileCounts(added, moved + renamed + changed + refreshed, moved, renamed, changed, Count(ReconcileCategory.Unchanged), unseen.Length,
            Count(ReconcileCategory.Conflict), current.Count + added - unseen.Length);
        var samples = ImmutableArray.CreateBuilder<SyncReconcileSample>();
        foreach (var category in new[] { ReconcileCategory.Added, ReconcileCategory.Moved, ReconcileCategory.Renamed, ReconcileCategory.Changed, ReconcileCategory.Conflict })
        {
            foreach (var item in built.Where(i => i.Category == category).OrderBy(i => i.Row.Name, StringComparer.OrdinalIgnoreCase).Take(SamplesPerCategory))
            {
                samples.Add(new SyncReconcileSample(CategoryKey(category), item.Row.Name, item.Row.Type, item.Detail));
            }
        }
        foreach (var row in unseen.Take(SamplesPerCategory))
        {
            samples.Add(new SyncReconcileSample("unseen", row.Name, row.Type, "Non revu par la lecture complète" + SyncText.C + SyncLocations.Location(row.Dn) + " (absence non prouvée, rien n’est supprimé dans l’annuaire)"));
        }
        return new SyncReconciliation(built, unseen, counts, samples.ToImmutable());
    }

    public static string CategoryKey(ReconcileCategory category) => category switch
    {
        ReconcileCategory.Added => "added",
        ReconcileCategory.Moved => "moved",
        ReconcileCategory.Renamed => "renamed",
        ReconcileCategory.Changed => "changed",
        ReconcileCategory.Refreshed => "refreshed",
        ReconcileCategory.Conflict => "conflict",
        _ => "unchanged",
    };

    /// <summary>
    /// The base after a reconciliation: rows written under their GUID (a conflict keeps the local row), unseen rows removed and
    /// returned as absences recorded « not seen » for this scope and this read (never as deletions).
    /// </summary>
    public static (Dictionary<Guid, IndexRecord> Rows, ImmutableArray<AbsenceRecord> Absences) Apply(IReadOnlyDictionary<Guid, IndexRecord> current, SyncReconciliation reconciliation, string scopeDn, DateTimeOffset readAt, string? server)
    {
        ArgumentNullException.ThrowIfNull(current);
        ArgumentNullException.ThrowIfNull(reconciliation);
        ArgumentNullException.ThrowIfNull(scopeDn);
        var rows = new Dictionary<Guid, IndexRecord>(current);
        foreach (var item in reconciliation.Items)
        {
            if (item.Category != ReconcileCategory.Conflict)
            {
                rows[item.Row.ObjectGuid] = item.Row;
            }
        }
        var absences = ImmutableArray.CreateBuilder<AbsenceRecord>();
        foreach (var row in reconciliation.Unseen)
        {
            rows.Remove(row.ObjectGuid);
            absences.Add(new AbsenceRecord(row.ObjectGuid, row.Name, row.Type, row.Dn, null, AbsenceStatus.NotSeen, readAt, null, "", scopeDn, server));
        }
        return (rows, absences.ToImmutable());
    }

    /// <summary>
    /// How an incremental answer is used (Domenia 1 Resolve-DomeniaIncrementalSync): the previous checkpoint is reused only on
    /// the same controller instance and the same scope; an absence is asserted only after a complete answer of the whole scope
    /// on that instance; the checkpoint moves only with a complete answer that names its instance (invocationID).
    /// </summary>
    public static SyncIncremental Incremental(SyncCheckpoint? checkpoint, string controller, string? invocationId, long highestUsn, string scopeDn, bool partial, bool visibilityReduced, bool scopeComplete, int count, DateTimeOffset readAt)
    {
        var notes = ImmutableArray.CreateBuilder<string>();
        var sameInstance = checkpoint is not null && string.Equals(checkpoint.Controller, controller, StringComparison.OrdinalIgnoreCase)
            && !string.IsNullOrEmpty(checkpoint.InvocationId) && string.Equals(checkpoint.InvocationId, invocationId, StringComparison.OrdinalIgnoreCase);
        var sameScope = checkpoint is not null && SyncLocations.Same(checkpoint.ScopeDn, scopeDn);
        var full = false;
        if (!sameInstance)
        {
            full = true;
            notes.Add("Contrôleur ou instance différents" + SyncText.C + "le repère précédent n’est pas réutilisé.");
        }
        else if (!sameScope)
        {
            full = true;
            notes.Add("Périmètre différent" + SyncText.C + "nouvelle lecture complète du périmètre choisi.");
        }
        var assert = sameInstance && sameScope && !partial && !visibilityReduced && scopeComplete;
        if (!assert)
        {
            if (partial)
            {
                notes.Add("Réponse partielle" + SyncText.C + "aucune absence n’est déduite.");
            }
            if (visibilityReduced)
            {
                notes.Add("Visibilité réduite pour ce compte" + SyncText.C + "aucune absence n’est déduite.");
            }
        }
        var advances = !partial && !visibilityReduced && !string.IsNullOrEmpty(invocationId);
        var next = advances ? new SyncCheckpoint(controller, invocationId!, highestUsn, readAt, count, scopeDn) : checkpoint;
        if (!advances)
        {
            notes.Add("Le repère de synchronisation n’avance pas" + SyncText.C + (partial ? "réponse incomplète." : "instance du contrôleur inconnue."));
        }
        return new SyncIncremental(full, assert, advances, next, notes.ToImmutable());
    }
}
