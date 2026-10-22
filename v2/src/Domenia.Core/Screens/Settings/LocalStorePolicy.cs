using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>One family line of a retention preview: rows older than the cutoff, and what leaves with them.</summary>
public sealed record RetentionPreviewRow(string Family, string Label, int Days, DateTimeOffset? Cutoff, long Rows, bool Compaction, string Text);

/// <summary>Result of settings.storage.retention.preview: counts per family, wording and the fingerprint the plan requires.</summary>
public sealed record RetentionPreview(StoragePolicy Policy, DateTimeOffset At, ImmutableArray<RetentionPreviewRow> Families, long TotalRows, ImmutableArray<string> Lines, string Fingerprint, bool NothingToDo);

/// <summary>What the automatic backup will do next and what it last proved (Get-DomeniaStorageBackupSchedule).</summary>
public sealed record BackupSchedule(bool Enabled, bool Due, string Reason, DateTimeOffset? NextAt, ImmutableArray<string> Lines);

/// <summary>
/// Pure rules of the storage policy (Domenia 1 PAR-022, PAR-023, PAR-036): bounds, retention families and cutoffs, preview
/// wording, backup decision and schedule. No disk, no clock read here: every time-dependent rule takes <c>now</c>.
/// </summary>
public static class StoragePolicyRules
{
    /// <summary>Preference key of the storage policy (screen « settings »).</summary>
    public const string PreferenceKey = "settings.storage";

    public const int MaxRetentionDays = 36500;

    /// <summary>Defaults of Domenia 1: automatic backup off, 24 h, 7 copies; 30/90/180/90/30 days; association history whole.</summary>
    public static StoragePolicy Default { get; } = new(false, 24, 7, 30, 90, 180, 90, 30, 0);

    /// <summary>Closed list of retention families; the retention executor uses the same identifiers and refuses any other.</summary>
    public static ImmutableArray<RetentionFamily> Families { get; } =
    [
        new("presence", "presenceDays", "Présence ping", false, "ces postes perdront leur dernier état de présence connu et apparaîtront non relevés"),
        new("console", "consoleDays", "Utilisateur connecté", false, "ces postes perdront le dernier utilisateur connecté relevé"),
        new("inventory", "inventoryDays", "Inventaire", false, "ces postes perdront leur dernier inventaire léger (modèle, mémoire, disque, système)"),
        new("probe", "probeDays", "Sondes", false, "les résultats de sondes WMI correspondants seront à relire sur les postes"),
        new("detail", "detailDays", "Détails", false, "les résultats détaillés (logiciels, instances) seront à relire sur les postes"),
        new("linkHistory", "linkHistoryDays", "Historique des associations", true, "seules les observations identiques répétées sont retirées ; chaque changement d’utilisateur et la première et la dernière observation de chaque période sont gardés"),
    ];

    /// <summary>Days of a family under a policy.</summary>
    public static int DaysOf(StoragePolicy policy, string family)
    {
        ArgumentNullException.ThrowIfNull(policy);
        return family switch
        {
            "presence" => policy.PresenceDays,
            "console" => policy.ConsoleDays,
            "inventory" => policy.InventoryDays,
            "probe" => policy.ProbeDays,
            "detail" => policy.DetailDays,
            "linkHistory" => policy.LinkHistoryDays,
            _ => throw new ArgumentException("Unknown retention family.", nameof(family)),
        };
    }

    /// <summary>
    /// Validation of a policy: backup every 1 to 720 hours, 2 to 30 copies kept, retention 0 (no limit) to 36 500 days.
    /// Returns the precision of the refusal, or null when valid.
    /// </summary>
    public static string? Problem(StoragePolicy policy)
    {
        ArgumentNullException.ThrowIfNull(policy);
        if (policy.BackupHours is < 1 or > 720 || policy.BackupKeep is < 2 or > 30)
        {
            return "Sauvegarde" + FrenchText.Colon + "fréquence de 1 à 720 heures, de 2 à 30 copies conservées.";
        }
        foreach (var family in Families)
        {
            if (DaysOf(policy, family.Family) is < 0 or > MaxRetentionDays)
            {
                return "Conservation" + FrenchText.Colon + "de 0 (sans limite) à " + FrenchText.Integer(MaxRetentionDays) + " jours.";
            }
        }
        return null;
    }

    /// <summary>
    /// Reads the stored policy (an absent key keeps its default, as Domenia 1 did for LinkHistoryDays). An unreadable or
    /// invalid document gives <c>null</c> with <paramref name="unreadable"/> = true: the data policy then says « durée
    /// inconnue », never a default (PAR-029).
    /// </summary>
    public static StoragePolicy Read(JsonElement? stored, out bool unreadable)
    {
        unreadable = false;
        if (stored is not JsonElement root || root.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
        {
            return Default;
        }
        if (root.ValueKind != JsonValueKind.Object)
        {
            unreadable = true;
            return Default;
        }
        var bad = false;
        bool Flag(string name, bool fallback) =>
            root.TryGetProperty(name, out var v) ? v.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => Bad(fallback) } : fallback;
        int Number(string name, int fallback) =>
            root.TryGetProperty(name, out var v) ? (v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n) ? n : Bad(fallback)) : fallback;
        T Bad<T>(T fallback)
        {
            bad = true;
            return fallback;
        }
        var policy = new StoragePolicy(
            Flag("automaticBackup", Default.AutomaticBackup),
            Number("backupHours", Default.BackupHours),
            Number("backupKeep", Default.BackupKeep),
            Number("presenceDays", Default.PresenceDays),
            Number("consoleDays", Default.ConsoleDays),
            Number("inventoryDays", Default.InventoryDays),
            Number("probeDays", Default.ProbeDays),
            Number("detailDays", Default.DetailDays),
            Number("linkHistoryDays", Default.LinkHistoryDays));
        if (bad || Problem(policy) is not null)
        {
            unreadable = true;
            return Default;
        }
        return policy;
    }

    /// <summary>Stored form (camelCase, fixed order).</summary>
    public static JsonElement ToJson(StoragePolicy policy)
    {
        ArgumentNullException.ThrowIfNull(policy);
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteBoolean("automaticBackup", policy.AutomaticBackup);
            writer.WriteNumber("backupHours", policy.BackupHours);
            writer.WriteNumber("backupKeep", policy.BackupKeep);
            writer.WriteNumber("presenceDays", policy.PresenceDays);
            writer.WriteNumber("consoleDays", policy.ConsoleDays);
            writer.WriteNumber("inventoryDays", policy.InventoryDays);
            writer.WriteNumber("probeDays", policy.ProbeDays);
            writer.WriteNumber("detailDays", policy.DetailDays);
            writer.WriteNumber("linkHistoryDays", policy.LinkHistoryDays);
            writer.WriteEndObject();
        }
        using var document = JsonDocument.Parse(buffer.ToArray());
        return document.RootElement.Clone();
    }

    /// <summary>« 30 jours, appliqués après prévisualisation et confirmation ; aucune suppression automatique. » (Get-DomeniaDataRetentionText).</summary>
    public static string RetentionText(int days) =>
        days <= 0 ? "Sans limite de durée." : FrenchText.Count(days, "jour", "jours") + ", appliqués après prévisualisation et confirmation ; aucune suppression automatique.";

    /// <summary>Cutoff of a family: now minus its days, or null (kept without time limit).</summary>
    public static DateTimeOffset? Cutoff(StoragePolicy policy, string family, DateTimeOffset now)
    {
        var days = DaysOf(policy, family);
        return days > 0 ? now - TimeSpan.FromDays(days) : null;
    }

    /// <summary>Rows of a family strictly older than <paramref name="days"/> days (repeated ones only for a compaction).</summary>
    public static long RowsOlderThan(LocalStoreFamily family, int days, bool compaction)
    {
        ArgumentNullException.ThrowIfNull(family);
        if (days <= 0)
        {
            return 0;
        }
        var cells = compaction ? family.Repeated : family.DayCounts;
        long total = 0;
        for (var n = days; n < cells.Length; n++)
        {
            total += cells[n];
        }
        return total;
    }

    /// <summary>
    /// Preview of the retention (PAR-023, Get-DomeniaStorageRetentionLines): what each family loses, what is always kept,
    /// and a fingerprint of the counts and cutoffs that the plan requires (« Refaites la prévisualisation » otherwise). A
    /// family missing from the base stops everything (programming error), never a silent zero.
    /// </summary>
    public static RetentionPreview Preview(StoragePolicy policy, LocalStoreSnapshot store, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(zone);
        var at = WritePlans.TruncateToSecond(now);
        var rows = new List<RetentionPreviewRow>();
        var lines = new List<string>();
        foreach (var family in Families)
        {
            var days = DaysOf(policy, family.Family);
            var cutoff = days > 0 ? at - TimeSpan.FromDays(days) : (DateTimeOffset?)null;
            if (cutoff is null)
            {
                var keep = family.Label + FrenchText.Colon + "conservé sans limite de durée.";
                rows.Add(new RetentionPreviewRow(family.Family, family.Label, days, null, 0, family.Compaction, keep));
                lines.Add(keep);
                continue;
            }
            var data = store.Families.FirstOrDefault(f => f.Family == family.Family)
                ?? throw new InvalidOperationException("Retention family missing from the base: " + family.Family);
            var count = RowsOlderThan(data, days, family.Compaction);
            var date = SettingsFormat.LocalDate(cutoff.Value, zone);
            var what = family.Compaction ? FrenchText.Count(count, "observation répétée", "observations répétées") : FrenchText.Count(count, "mesure", "mesures");
            var text = count <= 0
                ? family.Label + FrenchText.Colon + "rien d’antérieur au " + date + "."
                : family.Label + FrenchText.Colon + what + " antérieure" + (count > 1 ? "s" : "") + " au " + date + " à retirer ; " + family.Loss + ".";
            rows.Add(new RetentionPreviewRow(family.Family, family.Label, days, cutoff, count, family.Compaction, text));
            lines.Add(text);
        }
        lines.Add("Toujours conservés" + FrenchText.Colon + "objets AD, comptes, associations actuelles et déclarées, requêtes, journaux et reçus ; dates illisibles et tentatives récentes.");
        lines.Add("Une sauvegarde vérifiée est faite juste avant ; elle reste hors de la rotation planifiée.");
        lines.Add("La suppression libère de la place réutilisable dans la base ; elle ne réduit pas immédiatement la taille du fichier.");
        var total = rows.Sum(r => r.Rows);
        var fingerprint = Fingerprint("retention", store, rows.Select(r => r.Family + "=" + r.Days.ToString(CultureInfo.InvariantCulture) + ":" + r.Rows.ToString(CultureInfo.InvariantCulture)));
        return new RetentionPreview(policy, at, [.. rows], total, [.. lines], fingerprint, total == 0);
    }

    /// <summary>
    /// SHA-256 of what a preview counted, bound to the identity and revision of the base: the plan of a preview whose base
    /// changed is refused (« Refaites la prévisualisation »).
    /// </summary>
    public static string Fingerprint(string kind, LocalStoreSnapshot store, IEnumerable<string> parts)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(parts);
        var text = kind + "\n" + store.StoreId + "\n" + store.Revision.ToString(CultureInfo.InvariantCulture) + "\n" + string.Join("\n", parts);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    }

    /// <summary>
    /// Whether the automatic backup is due (Get-DomeniaStorageBackupDecision): Disabled, Busy, InvalidClock (a date after the
    /// clock stops the schedule), RetryCooldown (15 min after an attempt), Recent, or Scheduled.
    /// </summary>
    public static (bool Due, string Reason) BackupDecision(StoragePolicy policy, DateTimeOffset? lastSuccess, DateTimeOffset? lastAttempt, bool busy, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(policy);
        if (!policy.AutomaticBackup)
        {
            return (false, "disabled");
        }
        if (busy)
        {
            return (false, "busy");
        }
        if ((lastSuccess is DateTimeOffset s && s > now.AddMinutes(2)) || (lastAttempt is DateTimeOffset a && a > now.AddMinutes(2)))
        {
            return (false, "invalidClock");
        }
        if (lastAttempt is DateTimeOffset attempt && attempt > now.AddMinutes(-15))
        {
            return (false, "retryCooldown");
        }
        if (lastSuccess is DateTimeOffset success && success > now.AddHours(-policy.BackupHours))
        {
            return (false, "recent");
        }
        return (true, "scheduled");
    }

    /// <summary>Wording of the automatic backup and of its last proof (Get-DomeniaStorageBackupSchedule).</summary>
    public static BackupSchedule Schedule(StoragePolicy policy, LocalStoreBackup? last, DateTimeOffset? lastAttempt, string? lastFailure, DateTimeOffset? lastFailureAt, bool busy, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(zone);
        var lines = new List<string>
        {
            policy.AutomaticBackup
                ? "Sauvegarde automatique" + FrenchText.Colon + "toutes les " + FrenchText.Integer(policy.BackupHours) + FrenchText.Nbsp + "h tant que Domenia est ouvert ; " + FrenchText.Count(policy.BackupKeep, "copie conservée", "copies conservées") + " dans le dossier Backups."
                : "Sauvegarde automatique" + FrenchText.Colon + "désactivée. « Sauvegarder maintenant » reste disponible.",
        };
        var verified = last is not null && IsVerified(last) ? last : null;
        if (verified is not null)
        {
            lines.Add("Dernière sauvegarde vérifiée" + FrenchText.Colon + SettingsFormat.LocalDate(verified.At, zone) + " (contrôle SQLite réussi, "
                + SettingsFormat.Size(verified.Bytes) + ", empreinte SHA-256 " + SettingsFormat.ShortSha(verified.Sha256) + ").");
        }
        else
        {
            lines.Add("Aucune sauvegarde vérifiée enregistrée pour cette base.");
        }
        var (due, reason) = BackupDecision(policy, verified?.At, lastAttempt, busy, now);
        DateTimeOffset? next = null;
        switch (reason)
        {
            case "scheduled":
                lines.Add("Prochaine sauvegarde" + FrenchText.Colon + "à la prochaine vérification (une par minute), dès qu’aucune opération locale n’est en cours.");
                break;
            case "busy":
                lines.Add("Prochaine sauvegarde" + FrenchText.Colon + "différée tant qu’une opération ou un enregistrement local est en cours.");
                break;
            case "retryCooldown":
                next = lastAttempt!.Value.AddMinutes(15);
                if (verified is not null && verified.At >= lastAttempt.Value)
                {
                    var dueAt = verified.At.AddHours(policy.BackupHours);
                    if (dueAt > next)
                    {
                        next = dueAt;
                    }
                    lines.Add("Prochaine sauvegarde" + FrenchText.Colon + "au plus tôt le " + SettingsFormat.LocalDate(next.Value, zone) + ", si Domenia est ouvert.");
                }
                else
                {
                    lines.Add("Nouvel essai au plus tôt le " + SettingsFormat.LocalDate(next.Value, zone) + ".");
                }
                break;
            case "recent":
                next = verified!.At.AddHours(policy.BackupHours);
                lines.Add("Prochaine sauvegarde" + FrenchText.Colon + "au plus tôt le " + SettingsFormat.LocalDate(next.Value, zone) + ", si Domenia est ouvert.");
                break;
            case "invalidClock":
                lines.Add("Dernière sauvegarde datée après l’horloge du poste" + FrenchText.Colon + "planification arrêtée, vérifiez la date du poste.");
                break;
        }
        if (lastFailureAt is DateTimeOffset failureAt && !string.IsNullOrWhiteSpace(lastFailure))
        {
            lines.Add("Dernier échec (cette session)" + FrenchText.Colon + SettingsFormat.LocalDate(failureAt, zone) + FrenchText.Colon + lastFailure.TrimEnd('.') + ".");
        }
        return new BackupSchedule(policy.AutomaticBackup, due, reason, next, [.. lines]);
    }

    /// <summary>
    /// One verification rule for every copy of the base (Test-DomeniaBackupReceiptVerified): a file, the passed quick_check,
    /// the SHA-256 of the produced file and the date of that verification.
    /// </summary>
    public static bool IsVerified(LocalStoreBackup backup)
    {
        ArgumentNullException.ThrowIfNull(backup);
        return !string.IsNullOrWhiteSpace(backup.FileName) && backup.Verified && SettingsFormat.Sha256Text(backup.Sha256) is not null && backup.VerifiedAt is not null;
    }
}
