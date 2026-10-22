using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;

namespace Domenia.Core;

/// <summary>What a snapshot keeps of one object: identity, location and a few attributes, never a secret, right or membership.</summary>
public sealed record SnapshotLine(Guid ObjectGuid, IndexObjectType Type, string Name, string? Login, string? Upn, string? DisplayName, string? Description, string? Extra, bool Enabled, string Dn)
{
    public static SnapshotLine From(IndexRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        return new SnapshotLine(record.ObjectGuid, record.Type, record.Name, record.Login, record.Upn, record.DisplayName, record.Description, record.Extra, record.Enabled, record.Dn);
    }
}

/// <summary>One dated snapshot as the base keeps it (Domenia 1 table directory_snapshot and its rows).</summary>
public sealed record SnapshotRecord(
    string Id,
    string Label,
    string DomainDn,
    string ScopeDn,
    bool Subtree,
    DateTimeOffset CapturedAt,
    SnapshotCoverageState CoverageState,
    DateTimeOffset? CoverageAt,
    string? CoverageSource,
    string CoverageText,
    ImmutableArray<SnapshotLine> Lines,
    string RowsSha256);

/// <summary>Coverage proof of a snapshot (Domenia 1 ConvertTo-DomeniaSnapshotCoverage).</summary>
public sealed record SnapshotCoverageProof(SnapshotCoverageState State, DateTimeOffset? At, string? Source, string Text);

/// <summary>A validated capture request (Domenia 1 New-DomeniaSnapshotRequest).</summary>
public sealed record SnapshotRequest(string Id, string Label, string DomainDn, string ScopeDn, bool Subtree, DateTimeOffset CapturedAt, SnapshotCoverageProof Coverage);

/// <summary>
/// Pure rules of the dated snapshots of the directory (Domenia 1 point 30): a snapshot is a dated copy of the base for a scope
/// with the proof of its coverage; it holds no password, right or membership, cannot restore the directory, and a
/// disappearance between two snapshots is not a proof of deletion. Two snapshots compare only on the same domain and scope.
/// </summary>
public static class SyncSnapshots
{
    public const int MaxPerDomain = 50;
    public const int MaxObjects = 300_000;
    public const int MaxLabelLength = 120;
    public const int CompareLimit = 500;

    public const string Notice = "Un relevé est une copie datée de la base locale pour un périmètre : identité, emplacement et quelques attributs. "
        + "Il ne contient ni mot de passe, ni droit, ni appartenance de groupe, et ne permet pas de restaurer l’annuaire. "
        + "Une disparition entre deux relevés n’est pas une preuve de suppression.";

    /// <summary>Only a complete read covering the scope makes additions and disappearances conclusive.</summary>
    public static SnapshotCoverageProof Proof(SyncCoverage coverage, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(coverage);
        ArgumentNullException.ThrowIfNull(zone);
        var state = coverage.Status switch
        {
            CoverageStatus.Complete => SnapshotCoverageState.Complete,
            CoverageStatus.Partial => SnapshotCoverageState.Partial,
            CoverageStatus.UnknownDepth => SnapshotCoverageState.Unknown,
            _ => SnapshotCoverageState.Missing,
        };
        if (state == SnapshotCoverageState.Complete && coverage.At is null)
        {
            state = SnapshotCoverageState.Missing;
        }
        if (coverage.ClockInvalid)
        {
            state = SnapshotCoverageState.Unknown;
        }
        var c = SyncText.C;
        var text = coverage.ClockInvalid
            ? "Couverture" + c + "horloge douteuse (lecture datée dans le futur)" + SyncText.Semi + " ajouts et disparitions non concluants."
            : state switch
            {
                SnapshotCoverageState.Complete => "Couverture" + c + "lecture complète du " + SyncText.LocalDateTime(coverage.At!.Value, zone) + (coverage.SourceLabel is { Length: > 0 } s ? " (" + s + ")" : "") + ".",
                SnapshotCoverageState.Partial => "Couverture" + c + "la dernière lecture de ce périmètre était incomplète" + SyncText.Semi + " ajouts et disparitions non concluants.",
                SnapshotCoverageState.Unknown => "Couverture" + c + "profondeur de la dernière lecture inconnue" + SyncText.Semi + " ajouts et disparitions non concluants.",
                _ => "Couverture" + c + "aucune lecture complète de ce périmètre" + SyncText.Semi + " le relevé ne contient que les objets déjà connus.",
            };
        return new SnapshotCoverageProof(state, coverage.At, coverage.SourceLabel, text);
    }

    /// <summary>
    /// Validated capture request: a scope inside the connected domain, a bounded label (« Relevé du 21/10/2026 18:14 » when
    /// empty), an identifier of 32 lower-case hexadecimal characters and the coverage known when the operator asked.
    /// </summary>
    public static SnapshotRequest Request(string? domainDn, string? scopeDn, bool subtree, string? label, SyncCoverage coverage, string id, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(coverage);
        ArgumentNullException.ThrowIfNull(zone);
        var c = SyncText.C;
        var domain = domainDn?.Trim() ?? "";
        if (domain.Length == 0)
        {
            throw new DomeniaOperationException(SyncErrors.NoDomain, "Domaine non connecté" + c + "relevé impossible.");
        }
        var scope = string.IsNullOrWhiteSpace(scopeDn) ? domain : scopeDn.Trim();
        if (!SyncLocations.InScope(scope, domain))
        {
            throw new DomeniaOperationException(SyncErrors.OutsideDomain, "Périmètre hors du domaine connecté" + c + "relevé refusé.");
        }
        if (!WritePlans.IsPlanId(id))
        {
            throw new ArgumentException("A snapshot id is 32 lower-case hexadecimal characters.", nameof(id));
        }
        var name = SyncText.Flat(label, MaxLabelLength);
        if (name.Length == 0)
        {
            name = "Relevé du " + SyncText.LocalDateTime(now, zone);
        }
        return new SnapshotRequest(id, name, domain, scope, subtree, WritePlans.TruncateToSecond(now), Proof(coverage, zone));
    }

    /// <summary>SHA-256 of the canonical lines of a snapshot (sorted by GUID).</summary>
    public static string Fingerprint(IEnumerable<SnapshotLine> lines)
    {
        ArgumentNullException.ThrowIfNull(lines);
        var builder = new StringBuilder();
        foreach (var line in lines.OrderBy(l => l.ObjectGuid.ToString("D"), StringComparer.Ordinal))
        {
            builder.Append(line.ObjectGuid.ToString("D")).Append('\t').Append(line.Type).Append('\t').Append(line.Name).Append('\t').Append(line.Login)
                .Append('\t').Append(line.Upn).Append('\t').Append(line.DisplayName).Append('\t').Append(line.Description).Append('\t').Append(line.Extra)
                .Append('\t').Append(line.Enabled ? '1' : '0').Append('\t').Append(line.Dn).Append('\n');
        }
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(builder.ToString())));
    }

    /// <summary>Display row of one snapshot (Domenia 1 ConvertTo-DomeniaSnapshotRow).</summary>
    public static SnapshotRow Row(SnapshotRecord record, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(record);
        ArgumentNullException.ThrowIfNull(zone);
        var path = SyncLocations.Path(record.ScopeDn);
        var scopeText = path.IsEmpty ? "Domaine entier" : string.Join(FrenchText.PathSeparator, path);
        if (!record.Subtree)
        {
            scopeText += " (niveau direct)";
        }
        var date = SyncText.LocalDateTime(record.CapturedAt, zone);
        return new SnapshotRow(record.Id, record.Label, record.DomainDn, record.ScopeDn, record.Subtree, scopeText, record.CapturedAt, record.Lines.Length,
            record.CoverageState, record.CoverageAt, record.CoverageText, record.RowsSha256, record.Label + " · " + date + " · " + scopeText);
    }

    public static SnapshotList List(IReadOnlyCollection<SnapshotRecord> records, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(records);
        var rows = records.OrderByDescending(r => r.CapturedAt).Select(r => Row(r, zone)).ToImmutableArray();
        var text = rows.IsEmpty
            ? "Aucun relevé enregistré pour ce domaine."
            : FrenchText.Count(rows.Length, "relevé enregistré", "relevés enregistrés") + " pour ce domaine (" + FrenchText.Integer(MaxPerDomain) + " au plus).";
        return new SnapshotList(rows.Length, MaxPerDomain, MaxObjects, text, Notice, rows);
    }

    /// <summary>Same domain and same scope are required; an incomplete coverage or a reversed order are said (Domenia 1 Test-DomeniaSnapshotComparable).</summary>
    public static (bool Comparable, ImmutableArray<string> Reasons, ImmutableArray<string> Warnings) Comparable(SnapshotRecord? before, SnapshotRecord? after)
    {
        var reasons = ImmutableArray.CreateBuilder<string>();
        var warnings = ImmutableArray.CreateBuilder<string>();
        if (before is null || after is null)
        {
            reasons.Add("Choisissez deux relevés.");
        }
        else
        {
            if (string.Equals(before.Id, after.Id, StringComparison.Ordinal))
            {
                reasons.Add("Un relevé ne se compare pas à lui-même.");
            }
            if (!SyncLocations.Same(before.DomainDn, after.DomainDn))
            {
                reasons.Add("Domaines différents.");
            }
            if (!SyncLocations.Same(before.ScopeDn, after.ScopeDn) || before.Subtree != after.Subtree)
            {
                reasons.Add("Périmètres différents" + SyncText.C + "comparez deux relevés du même périmètre.");
            }
            if (after.CapturedAt < before.CapturedAt)
            {
                warnings.Add("Le relevé « après » est plus ancien que le relevé « avant »" + SyncText.C + "les ajouts apparaissent comme des disparitions.");
            }
            if (before.CoverageState != SnapshotCoverageState.Complete)
            {
                warnings.Add("Relevé « avant » sans couverture complète" + SyncText.C + "ajouts et disparitions non concluants.");
            }
            if (after.CoverageState != SnapshotCoverageState.Complete)
            {
                warnings.Add("Relevé « après » sans couverture complète" + SyncText.C + "ajouts et disparitions non concluants.");
            }
        }
        return (reasons.Count == 0, reasons.ToImmutable(), warnings.ToImmutable());
    }

    /// <summary>
    /// Readable comparison (Domenia 1 ConvertTo-DomeniaSnapshotReport): exact totals, rows bounded per category, moves and
    /// renames explained, values compared field by field (whenChanged and lastLogonTimestamp move on their own: not compared).
    /// </summary>
    public static SnapshotComparison Compare(SnapshotRecord before, SnapshotRecord after, TimeZoneInfo zone, int limit = CompareLimit)
    {
        ArgumentNullException.ThrowIfNull(before);
        ArgumentNullException.ThrowIfNull(after);
        var (comparable, reasons, warnings) = Comparable(before, after);
        var beforeRow = Row(before, zone);
        var afterRow = Row(after, zone);
        var bound = Math.Clamp(limit, 1, 5000);
        if (!comparable)
        {
            return new SnapshotComparison(beforeRow, afterRow, false, reasons, warnings, new SnapshotDiffCounts(0, 0, 0, 0, 0, 0, 0, 0), bound, false, [],
                ["Comparaison impossible" + SyncText.C + string.Join(" ", reasons)], Notice);
        }
        var c = SyncText.C;
        var oldByGuid = before.Lines.GroupBy(l => l.ObjectGuid).ToDictionary(g => g.Key, g => g.First());
        var newByGuid = after.Lines.GroupBy(l => l.ObjectGuid).ToDictionary(g => g.Key, g => g.First());
        var added = after.Lines.Where(l => !oldByGuid.ContainsKey(l.ObjectGuid)).OrderBy(l => l.Name, StringComparer.OrdinalIgnoreCase).ToList();
        var gone = before.Lines.Where(l => !newByGuid.ContainsKey(l.ObjectGuid)).OrderBy(l => l.Name, StringComparer.OrdinalIgnoreCase).ToList();
        var common = after.Lines.Where(l => oldByGuid.ContainsKey(l.ObjectGuid)).OrderBy(l => l.Name, StringComparer.OrdinalIgnoreCase).ToList();
        var rows = ImmutableArray.CreateBuilder<SnapshotDiffRow>();
        var truncated = false;
        foreach (var line in added.Take(bound))
        {
            rows.Add(new SnapshotDiffRow(SnapshotDiffNature.Added, "Ajout", line.Name, line.ObjectGuid.ToString("D"), "Présent dans « après »" + c + SyncLocations.Location(line.Dn), null, line.Dn));
        }
        foreach (var line in gone.Take(bound))
        {
            rows.Add(new SnapshotDiffRow(SnapshotDiffNature.Disappeared, "Disparition", line.Name, line.ObjectGuid.ToString("D"),
                "Absent de « après »" + c + "déplacé hors du périmètre, invisible ou supprimé" + SyncText.Semi + " non prouvé ici.", line.Dn, null));
        }
        truncated |= added.Count > bound || gone.Count > bound;
        int moved = 0, renamed = 0, differing = 0;
        var changedObjects = new HashSet<Guid>();
        foreach (var next in common)
        {
            var old = oldByGuid[next.ObjectGuid];
            var differs = false;
            if (!SyncLocations.Same(old.Dn, next.Dn))
            {
                var move = SyncLocations.Move(old.Dn, next.Dn, after.ScopeDn);
                var nature = move.Kind == MoveKind.Renamed ? SnapshotDiffNature.Renamed : SnapshotDiffNature.Moved;
                if (nature == SnapshotDiffNature.Renamed)
                {
                    renamed++;
                }
                else
                {
                    moved++;
                }
                differs = true;
                if (differing < bound)
                {
                    rows.Add(new SnapshotDiffRow(nature, nature == SnapshotDiffNature.Renamed ? "Renommage" : "Déplacement", next.Name, next.ObjectGuid.ToString("D"), move.Text, old.Dn, next.Dn));
                }
            }
            foreach (var (label, value) in LineFields)
            {
                var a = value(old);
                var b = value(next);
                if (!string.Equals(a, b, StringComparison.Ordinal))
                {
                    differs = true;
                    changedObjects.Add(next.ObjectGuid);
                    if (differing < bound)
                    {
                        rows.Add(new SnapshotDiffRow(SnapshotDiffNature.Changed, "Valeur modifiée", next.Name, next.ObjectGuid.ToString("D"), label, a, b));
                    }
                }
            }
            if (differs)
            {
                differing++;
            }
        }
        truncated |= differing > bound;
        var counts = new SnapshotDiffCounts(added.Count, gone.Count, common.Count, differing, Math.Max(0, common.Count - differing), moved, renamed, changedObjects.Count);
        var summary = ImmutableArray.CreateBuilder<string>();
        summary.Add(FrenchText.Quote(before.Label) + " → " + FrenchText.Quote(after.Label) + c + FrenchText.Count(added.Count, "ajout", "ajouts") + ", "
            + FrenchText.Count(gone.Count, "disparition", "disparitions") + ", " + FrenchText.Count(differing, "objet déplacé ou modifié", "objets déplacés ou modifiés")
            + ", " + FrenchText.Count(counts.Unchanged, "inchangé", "inchangés") + ".");
        if (truncated)
        {
            summary.Add("Affichage limité à " + FrenchText.Integer(bound) + " lignes par catégorie" + SyncText.Semi + " les totaux ci-dessus sont exacts.");
        }
        summary.Add("Parmi les objets communs" + c + FrenchText.Count(moved + renamed, "déplacement ou renommage", "déplacements ou renommages") + ", "
            + FrenchText.Count(changedObjects.Count, "objet aux valeurs modifiées", "objets aux valeurs modifiées") + ".");
        summary.Add(FrenchText.Quote(before.Label) + " · " + before.CoverageText);
        summary.Add(FrenchText.Quote(after.Label) + " · " + after.CoverageText);
        foreach (var warning in warnings)
        {
            summary.Add("À noter" + c + warning);
        }
        return new SnapshotComparison(beforeRow, afterRow, true, reasons, warnings, counts, bound, truncated, rows.ToImmutable(), summary.ToImmutable(), Notice);
    }

    private static readonly ImmutableArray<(string Label, Func<SnapshotLine, string> Value)> LineFields =
    [
        ("Type", l => SyncIndex.TypeLabel(l.Type)),
        ("Nom", l => l.Name),
        ("Identifiant", l => l.Login ?? ""),
        ("UPN ou nom DNS", l => l.Upn ?? ""),
        ("Nom affiché", l => l.DisplayName ?? ""),
        ("Description", l => l.Description ?? ""),
        ("Service, système ou lieu", l => l.Extra ?? ""),
        ("État du compte", l => SyncIndex.StateLabel(l.Enabled)),
    ];
}

/// <summary>Error codes of the screen (docs/ops/synchro.md § 4).</summary>
public static class SyncErrors
{
    public const string NoDomain = "synchro.noDomain";
    public const string OutsideDomain = "synchro.outsideDomain";
    public const string ScopeRoot = "synchro.scopeRoot";
    public const string ScopeRootMessage = "Choisissez une OU : la mise à jour par OU ne s’applique jamais à tout le domaine. La mise à jour des changements du domaine a son propre geste.";
    public const string EstimateUnknown = "synchro.estimateUnknown";
    public const string EstimateUnknownMessage = "Estimation inconnue ou expirée (15 min) : rien n’a été lu. Préparez de nouveau la lecture.";
    public const string NotReady = "synchro.notReady";
    public const string Busy = "synchro.busy";
    public const string BusyMessage = "Une lecture de l’annuaire est déjà en cours : attendez sa fin ou arrêtez-la.";
    public const string BatchUnknown = "synchro.batchUnknown";
    public const string BatchUnknownMessage = "Lecture inconnue, déjà enregistrée ou expirée (15 min) : rien n’a été écrit. Relancez la lecture.";
    public const string NothingToCheck = "synchro.nothingToCheck";
    public const string NothingToCheckMessage = "Aucun objet à vérifier : actualisez la liste.";
    public const string NothingToRead = "synchro.nothingToRead";
    public const string NothingToReadMessage = "Aucun objet manquant à lire : actualisez la liste.";
    public const string SnapshotUnknown = "synchro.snapshotUnknown";
    public const string SnapshotUnknownMessage = "Relevé introuvable : il a peut-être été supprimé. Actualisez la liste.";
    public const string SnapshotLimit = "synchro.snapshotLimit";
    public const string SnapshotLimitMessage = "50 relevés au plus par domaine : supprimez un ancien relevé avant d’en enregistrer un nouveau.";
    public const string SnapshotTooLarge = "synchro.snapshotTooLarge";
    public const string SnapshotTooLargeMessage = "Plus de 300 000 objets dans ce périmètre : relevé refusé. Choisissez une OU plus petite.";
    public const string ParkEmpty = "synchro.parkEmpty";
    public const string ParkEmptyMessage = "Aucun relevé du parc à oublier.";
    public const string SharedUnavailable = "synchro.sharedUnavailable";
    public const string SharedNotConfigured = "synchro.sharedNotConfigured";
    public const string SharedNotConfiguredMessage = "Aucun relevé partagé configuré (ParkSweep.SharedPath) : Domenia travaille en local, rien n’est lu.";
}
