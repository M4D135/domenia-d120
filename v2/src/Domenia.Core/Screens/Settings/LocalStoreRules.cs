using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>Reading of the free space of the volume of the base (Get-DomeniaStorageSpaceState).</summary>
public sealed record StorageSpaceView(string State, Tone Tone, string Label, long? FreeBytes, string FreeText, DateTimeOffset? MeasuredAt, bool Stale, long WriteReserveBytes, long SuspendBelowBytes, long WarnBelowBytes, bool BlocksCollections, string Text);

/// <summary>« Base du domaine example.local · 41,2 Mo · sauvegardée il y a 2 h » (Get-DomeniaDatabaseLocationSummary).</summary>
public sealed record StorageLocationView(string Text, bool Alert, string AlertText, string PathLabel, string? Path);

/// <summary>One sentence for the local save state, never claiming a save that did not happen (Get-DomeniaPersistenceLabel).</summary>
public sealed record StorageWriterView(string State, Tone Tone, string Text, string Unsaved, bool CanResume, string? ResumeReason);

/// <summary>Which assistant buttons may act now, and why (Get-DomeniaStorageMaintenanceControlState).</summary>
public sealed record StorageMaintenanceView(bool Move, bool Restore, bool Resume, bool Rollback, string Text, Tone Tone, string? MoveReason, string? RestoreReason, string? ResumeReason, string? RollbackReason);

/// <summary>One check of an integrity report in plain words.</summary>
public sealed record StorageCheckView(string Id, string Label, string Status, string StatusLabel, Tone Tone, string? Detail);

/// <summary>Reading of an integrity report (Get-DomeniaStorageIntegrityVerdict).</summary>
public sealed record StorageIntegrityView(string Verdict, Tone Tone, int Failed, int Warnings, int Unknown, bool Readable, DateTimeOffset CheckedAt, long DurationMilliseconds, ImmutableArray<StorageCheckView> Checks, ImmutableArray<string> Lines);

/// <summary>One category of the usage measure, with its share of the measured bytes (or rows).</summary>
public sealed record StorageCategoryView(string Id, string Label, long Rows, long? Bytes, string BytesText, double Share);

/// <summary>One measured read in plain words.</summary>
public sealed record StorageProbeView(string Name, string Label, long Rows, double Milliseconds, string How, string Text);

/// <summary>Reading of the usage measure (PAR-025).</summary>
public sealed record StorageUsageView(DateTimeOffset MeasuredAt, long DatabaseBytes, string DatabaseText, long WalBytes, string WalText, bool DbstatAvailable, ImmutableArray<StorageCategoryView> Categories, ImmutableArray<StorageProbeView> Probes, string ProbesText, long DurationMilliseconds);

/// <summary>A purge category (closed list, Get-DomeniaRetentionPolicy): purgeable or never, with its current size.</summary>
public sealed record PurgeCategoryView(string Id, string Label, string Mode, bool Purgeable, long Rows, long? Bytes, string Detail);

/// <summary>One table group counted by a purge preview.</summary>
public sealed record PurgeTargetView(string Category, string Label, string Table, string Action, long Rows);

/// <summary>Result of settings.storage.purge.preview (PAR-031): exact counts, refusals and the fingerprint the plan requires.</summary>
public sealed record PurgePreview(ImmutableArray<string> Categories, int HistoryDays, DateTimeOffset? HistoryCutoff, ImmutableArray<PurgeTargetView> Targets, long TotalRows, ImmutableArray<string> Refused, ImmutableArray<string> Lines, ImmutableArray<string> Never, string Fingerprint, bool KeepsReceipts, bool KeepsConfiguration, bool KeepsManualLinks, bool NothingToDo);

/// <summary>One cached perimeter as shown (Get-DomeniaCacheCatalogRows).</summary>
public sealed record CacheCatalogRow(string Scope, string Source, string Controller, string Reader, long Objects, string Observed, string Age, string Usage);

/// <summary>One backup as listed by the page: proof, last batch, last measure, content and annex of its preferences.</summary>
public sealed record StorageBackupView(string Id, string FileName, DateTimeOffset At, long Bytes, string BytesText, string Sha256, string Sha256Short, bool Verified, string Kind, string KindLabel, bool InRotation,
    int PreferenceKeys, bool PreferencesBound, long Revision, DateTimeOffset? LastMeasureAt, string Content);

/// <summary>One tile of the summary band (objects, measures, backups, space).</summary>
public sealed record StorageTile(string Id, string Label, string Value, string Sub, Tone Tone);

/// <summary>Takeover of the Domenia 1 data, as shown by the page: sources found, the plan, its blockers and the guards.</summary>
public sealed record LegacyView(
    string State,
    Tone Tone,
    string Text,
    string Location,
    LegacyDatabase? Database,
    ImmutableArray<LegacyFileView> Files,
    ImmutableArray<LegacyStep> Steps,
    ImmutableArray<string> Blockers,
    ImmutableArray<string> Guards,
    long WriteCount,
    DateTimeOffset? ImportedAt);

/// <summary>Result of settings.storage.</summary>
public sealed record StorageView(
    bool Available,
    bool Simulated,
    string? UnavailableReason,
    StorageLocationView? Location,
    ImmutableArray<StorageTile> Tiles,
    string Content,
    long Revision,
    string Schema,
    StorageSpaceView? Space,
    StorageWriterView? Writer,
    StorageMaintenanceView? Maintenance,
    ImmutableArray<StorageBackupView> Backups,
    BackupSchedule? Schedule,
    StoragePolicy Policy,
    bool PolicyUnreadable,
    ImmutableArray<RetentionFamilyView> Retention,
    ImmutableArray<string> Limits,
    StorageUsageView? Usage,
    StorageIntegrityView? Integrity,
    ImmutableArray<PurgeCategoryView> Purge,
    ImmutableArray<string> Never,
    ImmutableArray<CacheCatalogRow> Catalog,
    LegacyView? Legacy,
    ImmutableArray<LocalStoreExport> Exports,
    string Scenario,
    string? ExportName,
    string? BackupFolder);

/// <summary>One retention family as edited by the page.</summary>
public sealed record RetentionFamilyView(string Family, string PolicyKey, string Label, int Days, string DaysText, bool Compaction, string Loss);

/// <summary>What the host read about a destination folder (read only: nothing is created nor written).</summary>
public sealed record DestinationFacts(bool FolderExists, bool LocalFixedDrive, bool ReparsePoint, bool FileExists, long? FreeBytes);

/// <summary>Result of settings.storage.destination.check: the destination admitted or the rule it breaks, with the space of its volume.</summary>
public sealed record DestinationCheck(bool Ok, string Purpose, string Path, string? Problem, bool FolderExists, bool FileExists, long? FreeBytes, string FreeText, long ReserveBytes, string ReserveText, string Text);

/// <summary>A local folder proposed for a destination (Documents, Bureau, dossier des exports…).</summary>
public sealed record DestinationFolder(string Id, string Label, string Path);

/// <summary>Result of settings.storage.destinations: the proposed name and the proposed folders.</summary>
public sealed record DestinationProposal(string FileName, string? BackupFolder, ImmutableArray<DestinationFolder> Folders);

/// <summary>One sub-folder of a local folder (settings.folders.browse).</summary>
public sealed record FolderEntry(string Name, string Path);

/// <summary>Result of settings.folders.browse: the folder, its parent, its sub-folders (500 at most), or the local drives.</summary>
public sealed record FolderListing(string? Path, string? Parent, ImmutableArray<FolderEntry> Folders, bool Truncated, string Text);

/// <summary>
/// Pure rules and wording of the local base (Domenia 1 PAR-010 to PAR-036, points 31 to 40): space, location, writer,
/// assistant, integrity, usage, limits, purge and cache catalogue. Workers (or the simulation) measure; these rules never
/// read a disk, a setting or the clock. An unknown measure stays unknown and is written as such.
/// </summary>
public static class LocalStoreRules
{
    public const long WriteReserve = 33554432L;
    public const long SuspendReserve = 536870912L;
    public const long WarnReserve = 2147483648L;

    /// <summary>Default age of the history purge (Domenia 1: 730 days, 1 to 36 500).</summary>
    public const int DefaultHistoryDays = 730;

    /// <summary>Labels of the integrity checks, in the order of the report.</summary>
    public static ImmutableArray<(string Id, string Label)> CheckLabels { get; } =
    [
        ("open", "Ouverture"), ("schema", "Schéma"), ("tables", "Tables et colonnes"), ("identity", "Identité de la base"),
        ("redirect", "Bascule"), ("receipts", "Reçus"), ("foreignKeys", "Références"), ("quickCheck", "Contrôle SQLite"), ("wal", "Journal SQLite"),
    ];

    private static readonly (string Name, string Label)[] ProbeLabels =
    [
        ("directoryPage", "page de l’index par type"), ("activeMachines", "postes actifs triés"), ("familyPage", "page de mesures d’une famille"), ("textSearch", "recherche de texte"),
    ];

    /// <summary>Labels of the row categories of the base.</summary>
    public static string CategoryLabel(string id) => id switch
    {
        "observations" => "Observations",
        "snapshots" => "Instantanés",
        "history" => "Historique",
        "index" => "Index",
        "manualLinks" => "Associations",
        "secrets" => "Métadonnées de secrets",
        _ => id,
    };

    /// <summary>Copy reserve on the destination volume: twice the source (file and WAL) plus 32 MiB (Get-DomeniaStorageCopyReserve).</summary>
    public static long CopyReserve(long sourceBytes)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(sourceBytes);
        return 2L * sourceBytes + WriteReserve;
    }

    /// <summary>
    /// Free space state (point 35): writes refused under 32 MiB plus four times the incoming queue, new collections suspended
    /// under 512 MiB plus four times the queue, alert under 2 GiB. Without a measure: Unknown, nothing is blocked or claimed;
    /// a measure older than 30 minutes is said old.
    /// </summary>
    public static StorageSpaceView Space(LocalStoreSpace space, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(space);
        ArgumentNullException.ThrowIfNull(zone);
        var queued = Math.Max(0L, space.QueuedBytes);
        var write = WriteReserve + 4L * queued;
        var suspend = SuspendReserve + 4L * queued;
        var warn = WarnReserve + 4L * queued;
        if (space.FreeBytes is not long free || space.MeasuredAt is not DateTimeOffset measured)
        {
            return new StorageSpaceView("unknown", Tone.Off, "Non mesuré", null, "non mesuré", null, false, write, suspend, warn, false,
                "Espace libre du volume de la base" + FrenchText.Colon + "non mesuré dans cette session. Chaque enregistrement contrôle sa propre réserve ; « Mesurer » donne l’état du disque.");
        }
        var stale = now - measured > TimeSpan.FromMinutes(30);
        var when = SettingsFormat.LocalDate(measured, zone);
        var freeText = SettingsFormat.Size(free);
        var (state, tone, label, text) = free < write
            ? ("critical", Tone.Alert, "Critique", "Espace disque critique" + FrenchText.Colon + freeText + " libres (mesure du " + when + "). Écritures refusées sous " + SettingsFormat.Size(write) + " et nouvelles collectes suspendues. Libérez de la place puis cliquez sur « Mesurer ».")
            : free < suspend
                ? ("suspend", Tone.Alert, "Insuffisant", "Espace disque insuffisant" + FrenchText.Colon + freeText + " libres (mesure du " + when + "). Nouvelles collectes suspendues sous " + SettingsFormat.Size(suspend) + " ; ce qui est déjà collecté continue de s’enregistrer. Libérez de la place puis cliquez sur « Mesurer ».")
                : free < warn
                    ? ("low", Tone.Warn, "À surveiller", "Espace disque à surveiller" + FrenchText.Colon + freeText + " libres (mesure du " + when + "). Les nouvelles collectes seront suspendues sous " + SettingsFormat.Size(suspend) + ".")
                    : ("ok", Tone.Ok, "Suffisant", "Espace libre du volume de la base" + FrenchText.Colon + freeText + " (mesure du " + when + ").");
        if (stale)
        {
            text += " Mesure ancienne" + FrenchText.Colon + "cliquez sur « Mesurer » pour l’actualiser.";
        }
        return new StorageSpaceView(state, tone, label, free, freeText, measured, stale, write, suspend, warn, state is "critical" or "suspend", text);
    }

    /// <summary>
    /// Readable location (UI-19): « Base du domaine X · 4,2 Mo · sauvegardée il y a 2 h », « Base de démonstration · … »; a
    /// soft alert when no backup exists or the last one is older than seven days. The path stays in the tip and the copy.
    /// </summary>
    public static StorageLocationView Location(LocalStoreSnapshot store, DateTimeOffset? lastBackup, DateTimeOffset now, string? path)
    {
        ArgumentNullException.ThrowIfNull(store);
        if (!store.Available)
        {
            return new StorageLocationView("Aucune base locale pour ce domaine pour l’instant.", false, "", store.PathLabel, null);
        }
        var head = store.Simulated ? "Base de démonstration" : string.IsNullOrWhiteSpace(store.Domain) ? "Base locale" : "Base du domaine " + store.Domain;
        // The same total everywhere (tile, location, journal note): the file and its SQLite journal together, said so.
        var size = SettingsFormat.Size(store.DatabaseBytes + store.WalBytes) + (store.WalBytes > 0 ? " avec son journal" : "");
        string saved;
        var alert = false;
        var alertText = "";
        if (lastBackup is DateTimeOffset at)
        {
            saved = "sauvegardée " + SettingsFormat.Elapsed(at, now);
            if ((now - at).TotalDays > 7)
            {
                alert = true;
                alertText = "Dernière sauvegarde il y a plus de 7 jours" + FrenchText.Colon + "pensez à « Sauvegarder maintenant ».";
            }
        }
        else
        {
            saved = "jamais sauvegardée";
            alert = !store.Simulated;
            alertText = alert ? "Aucune sauvegarde de cette base" + FrenchText.Colon + "pensez à « Sauvegarder maintenant »." : "";
        }
        return new StorageLocationView(head + " · " + size + " · " + saved, alert, alertText, store.PathLabel, path);
    }

    /// <summary>Counts reported by an inspection; a missing counter is unknown, never zero (Format-DomeniaStorageContent).</summary>
    public static string Content(LocalStoreCounts counts)
    {
        ArgumentNullException.ThrowIfNull(counts);
        static string Part(long? value, string singular, string plural) =>
            value is long n && n >= 0 ? FrenchText.Count(n, singular, plural) : plural + FrenchText.Colon + "nombre inconnu";
        return string.Join(", ",
            Part(counts.Objects, "objet AD", "objets AD"),
            Part(counts.Measures, "mesure", "mesures"),
            Part(counts.Details, "détail", "détails"),
            Part(counts.Associations, "association", "associations"),
            Part(counts.Queries, "requête", "requêtes"),
            Part(counts.Receipts, "reçu", "reçus"));
    }

    /// <summary>
    /// The local save state (D028): unavailable, suspended (resume offered), conflicts, failures, pending, saved; what is
    /// still only in memory is said plainly (Format-DomeniaStorageUnsaved).
    /// </summary>
    public static StorageWriterView Writer(LocalStoreWriter writer, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(writer);
        var unsaved = writer.Pending <= 0 && writer.QueuedChanges <= 0
            ? "Aucune donnée en attente d’enregistrement."
            : "Non enregistré, en mémoire" + FrenchText.Colon + FrenchText.Count(writer.Pending, "élément en file", "éléments en file")
              + (writer.QueuedChanges > 0 ? ", dont " + FrenchText.Count(writer.QueuedChanges, "changement collecté", "changements collectés") + " (" + SettingsFormat.Size(writer.QueuedBytes) + ")" : "")
              + (writer.Suspended ? " ; enregistrement suspendu, reprise ci-dessous" : "") + ".";
        if (writer.Unavailable)
        {
            return new StorageWriterView("unavailable", Tone.Alert, "En mémoire uniquement" + FrenchText.Colon + "stockage local indisponible, rien n’est enregistré.", unsaved, false, "Stockage local indisponible.");
        }
        if (writer.Suspended)
        {
            return new StorageWriterView("suspended", Tone.Alert,
                "En mémoire uniquement" + FrenchText.Colon + "enregistrement suspendu après des échecs" + (writer.Fault is { Length: > 0 } fault ? " (" + fault.TrimEnd('.') + ")" : "") + ". Reprise" + FrenchText.Colon + "« Reprendre les sauvegardes ».",
                unsaved, true, null);
        }
        var notSuspended = "Les enregistrements locaux ne sont pas suspendus" + FrenchText.Colon + "rien à reprendre.";
        if (writer.Conflicts > 0)
        {
            return new StorageWriterView("conflicts", Tone.Warn, "En mémoire" + FrenchText.Colon + FrenchText.Count(writer.Conflicts, "association modifiée ailleurs, non enregistrée", "associations modifiées ailleurs, non enregistrées") + ". Rechargez les associations.", unsaved, false, notSuspended);
        }
        if (writer.Failures > 0)
        {
            return new StorageWriterView("failures", Tone.Warn, "En mémoire" + FrenchText.Colon + FrenchText.Count(writer.Failures, "enregistrement en échec", "enregistrements en échec") + ", nouvel essai prévu.", unsaved, false, notSuspended);
        }
        if (writer.Pending > 0)
        {
            return new StorageWriterView("pending", Tone.Info, "En mémoire" + FrenchText.Colon + FrenchText.Count(writer.Pending, "modification à enregistrer", "modifications à enregistrer") + ".", unsaved, false, notSuspended);
        }
        var when = writer.LastSavedAt is DateTimeOffset at ? " (" + SettingsFormat.Elapsed(at, now) + ")" : "";
        return new StorageWriterView("saved", Tone.Ok, "Enregistré" + when + ".", unsaved, false, notSuspended);
    }

    /// <summary>
    /// Assistant buttons (point 32): a drain or a running step blocks everything; a pending switch only offers resume or
    /// rollback; a base declared unreadable only accepts a restore (then a resume). Each refusal says why.
    /// </summary>
    public static StorageMaintenanceView Maintenance(LocalStoreSnapshot store)
    {
        ArgumentNullException.ThrowIfNull(store);
        var m = store.Maintenance;
        var hasDatabase = store.Available;
        var job = !string.IsNullOrEmpty(m.Job);
        var target = !string.IsNullOrEmpty(m.TargetPath);
        var idle = hasDatabase && !m.Draining && !job;
        string text;
        var tone = Tone.Info;
        if (!hasDatabase)
        {
            text = "Aucune base locale active.";
            tone = Tone.Off;
        }
        else if (m.Draining)
        {
            text = "Copie en attente" + FrenchText.Colon + "les nouvelles collectes sont suspendues le temps d’enregistrer la file.";
        }
        else if (job)
        {
            text = "Étape de maintenance en cours ; les autres actions attendent sa fin.";
        }
        else if (m.Recovery && !m.RecoveryReceipt)
        {
            text = "Base locale illisible" + FrenchText.Colon + "restaurez une sauvegarde vérifiée. Les collectes restent suspendues.";
            tone = Tone.Alert;
        }
        else if (m.Locked)
        {
            text = "Bascule à terminer" + FrenchText.Colon + "reprenez-la ou revenez à la base précédente. Aucun fichier ne sera supprimé.";
            tone = Tone.Warn;
        }
        else if (m.CanUndo)
        {
            text = "Base basculée dans cette session" + FrenchText.Colon + "« Revenir à la base précédente » reste possible tant que la nouvelle base n’a reçu aucune écriture. Aucun fichier ne sera supprimé.";
            tone = Tone.Warn;
        }
        else
        {
            text = store.Simulated
                ? "Base fictive de la simulation, en mémoire seulement" + FrenchText.Colon + "chaque déplacement ou restauration s’y joue sans toucher au disque."
                : "La base active reste sur un disque local. Chaque déplacement ou restauration conserve le fichier d’origine.";
        }
        // A base proven unreadable only accepts the restore of a verified backup (PAR-021).
        var unreadable = m.Recovery && !m.RecoveryReceipt;
        var move = idle && !m.Locked && !unreadable;
        var restore = idle && (!m.Locked || unreadable);
        var resume = idle && m.Locked && target && (!m.Recovery || m.RecoveryReceipt);
        var rollback = idle && !unreadable && ((m.Locked && target && !m.Recovery) || (!m.Locked && m.CanUndo));
        var busy = !hasDatabase ? "Aucune base locale active." : m.Draining ? "Copie en attente." : job ? "Étape de maintenance en cours." : null;
        var onlyRestore = unreadable ? "Base locale illisible" + FrenchText.Colon + "seule la restauration d’une sauvegarde vérifiée est proposée." : null;
        return new StorageMaintenanceView(move, restore, resume, rollback, text, tone,
            move ? null : busy ?? onlyRestore ?? "Bascule à terminer d’abord.",
            restore ? null : busy ?? "Bascule à terminer d’abord.",
            resume ? null : busy ?? "Aucune bascule interrompue" + FrenchText.Colon + "rien à reprendre.",
            rollback ? null : busy ?? onlyRestore ?? "Aucune bascule de cette session à annuler.");
    }

    /// <summary>
    /// Integrity verdict (point 36): every expected check once with a known status; one failure gives « Défaut » and points to
    /// the restore assistant. Nothing is repaired automatically.
    /// </summary>
    public static StorageIntegrityView Integrity(LocalStoreIntegrity report, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(report);
        ArgumentNullException.ThrowIfNull(zone);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var checks = new List<StorageCheckView>();
        int failed = 0, warned = 0, unknown = 0;
        foreach (var check in report.Checks)
        {
            var label = CheckLabels.FirstOrDefault(c => c.Id == check.Id).Label;
            if (label is null || !seen.Add(check.Id) || check.Status is not ("ok" or "warning" or "failed" or "unknown"))
            {
                throw new InvalidOperationException("Inconsistent integrity report.");
            }
            var (statusLabel, tone) = check.Status switch
            {
                "ok" => ("conforme", Tone.Ok),
                "warning" => ("à surveiller", Tone.Warn),
                "failed" => ("défaut", Tone.Alert),
                _ => ("non vérifié", Tone.Off),
            };
            if (check.Status == "failed")
            {
                failed++;
            }
            else if (check.Status == "warning")
            {
                warned++;
            }
            else if (check.Status == "unknown")
            {
                unknown++;
            }
            checks.Add(new StorageCheckView(check.Id, label, check.Status, statusLabel, tone, check.Detail));
        }
        if (report.Readable ? CheckLabels.Any(c => !seen.Contains(c.Id)) : (!seen.Contains("open") || failed < 1))
        {
            throw new InvalidOperationException("Incomplete integrity report.");
        }
        var (verdict, verdictTone) = failed > 0 ? ("Défaut", Tone.Alert) : warned > 0 ? ("À surveiller", Tone.Warn) : unknown > 0 ? ("Incomplet", Tone.Info) : ("Sain", Tone.Ok);
        var lines = new List<string>
        {
            "Contrôle du " + SettingsFormat.LocalDate(report.CheckedAt, zone, seconds: true) + " en " + FrenchText.Integer(report.DurationMilliseconds) + FrenchText.Nbsp + "ms" + FrenchText.Colon + verdict + ".",
        };
        lines.AddRange(checks.Select(c => c.Label + FrenchText.Colon + c.StatusLabel + (string.IsNullOrWhiteSpace(c.Detail) ? "" : " (" + c.Detail.TrimEnd('.') + ")") + "."));
        if (failed > 0)
        {
            lines.Add("Restaurez une sauvegarde vérifiée avec « Restaurer une sauvegarde… »" + FrenchText.Colon + "la base actuelle reste en place, sans modification.");
        }
        lines.Add("Ce contrôle lit la base sans la modifier ; aucune réparation automatique.");
        return new StorageIntegrityView(verdict, verdictTone, failed, warned, unknown, report.Readable, report.CheckedAt, report.DurationMilliseconds, [.. checks], [.. lines]);
    }

    /// <summary>How SQLite served a measured read, from the plan it returned: index, full sort in memory or full scan.</summary>
    public static string PlanHow(string plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        if (plan.Contains("USE TEMP B-TREE FOR ORDER BY", StringComparison.Ordinal))
        {
            return "tri complet en mémoire";
        }
        if (plan.Contains("USING INDEX", StringComparison.Ordinal) || plan.Contains("USING COVERING INDEX", StringComparison.Ordinal))
        {
            return "index";
        }
        return plan.StartsWith("SCAN ", StringComparison.Ordinal) || plan.Contains("| SCAN ", StringComparison.Ordinal) ? "parcours complet" : "plan inconnu";
    }

    /// <summary>Reading of the usage measure (PAR-025, Format-DomeniaStorageReadProbes); improvement: share per category for the chart.</summary>
    public static StorageUsageView Usage(LocalStoreUsage usage)
    {
        ArgumentNullException.ThrowIfNull(usage);
        var byBytes = usage.DbstatAvailable;
        double total = byBytes ? usage.Categories.Sum(c => c.Bytes ?? 0) : usage.Categories.Sum(c => c.Rows);
        var categories = usage.Categories
            .OrderByDescending(c => byBytes ? c.Bytes ?? -1 : c.Rows)
            .Select(c => new StorageCategoryView(c.Id, c.Label, c.Rows, byBytes ? c.Bytes : null, byBytes ? SettingsFormat.Size(c.Bytes) : "inconnu",
                total > 0 ? Math.Round((byBytes ? c.Bytes ?? 0 : c.Rows) * 1000.0 / total) / 10.0 : 0));
        var probes = usage.Probes
            .Select(p => (Probe: p, Label: ProbeLabels.FirstOrDefault(l => l.Name == p.Name).Label))
            .Where(x => x.Label is not null)
            .Select(x =>
            {
                var how = PlanHow(x.Probe.Plan);
                var ms = x.Probe.Milliseconds.ToString("0.##", CultureInfo.InvariantCulture).Replace('.', ',');
                return new StorageProbeView(x.Probe.Name, x.Label, x.Probe.Rows, x.Probe.Milliseconds, how,
                    x.Label + " (" + FrenchText.Count(x.Probe.Rows, "ligne", "lignes") + ")" + FrenchText.Colon + ms + FrenchText.Nbsp + "ms, " + how);
            })
            .ToImmutableArray();
        var text = probes.IsEmpty ? "" : "Lectures mesurées sur cette base" + FrenchText.Colon + string.Join(" ; ", probes.Select(p => p.Text)) + ".";
        return new StorageUsageView(usage.MeasuredAt, usage.DatabaseBytes, SettingsFormat.Size(usage.DatabaseBytes), usage.WalBytes, SettingsFormat.Size(usage.WalBytes),
            usage.DbstatAvailable, [.. categories], probes, text, usage.DurationMilliseconds);
    }

    /// <summary>
    /// The explicit bounds of local storage (point 40): queues, caches, series, thresholds and retention, with the measured
    /// values when a measure exists. No unlimited storage is promised; what is not measured is said not measured.
    /// </summary>
    public static ImmutableArray<string> Limits(StoragePolicy policy, int maxConcurrent, int maxQueued, LocalStoreUsage? usage, StorageSpaceView? space, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        var lines = new List<string>
        {
            "Le stockage local n’est pas illimité" + c + "chaque file, cache et série a une limite, et la base grandit avec ce qui est conservé.",
            "Mémoire" + c + "file d’écriture de 4" + FrenchText.ThousandsSeparator + "096 changements ou 32" + FrenchText.Nbsp + "Mo au plus (lots de 250 changements ou 4" + FrenchText.Nbsp + "Mo), 256 éléments en attente ; recherches de 20" + FrenchText.ThousandsSeparator + "000 lignes au plus.",
            "Moteur" + c + FrenchText.Count(maxConcurrent, "tâche simultanée", "tâches simultanées") + " et " + FrenchText.Integer(maxQueued) + " en attente au plus.",
        };
        lines.Add(usage is not null
            ? "Disque" + c + "base de " + SettingsFormat.Size(usage.DatabaseBytes) + ", journal SQLite de " + SettingsFormat.Size(usage.WalBytes) + ", mesurés le " + SettingsFormat.LocalDate(usage.MeasuredAt, zone) + "."
            : "Disque" + c + "taille de la base non mesurée dans cette session (« Mesurer »).");
        lines.Add("Espace disque" + c + "nouvelles collectes suspendues sous " + SettingsFormat.Size(space?.SuspendBelowBytes ?? SuspendReserve) + " libres, écritures refusées sous "
            + SettingsFormat.Size(space?.WriteReserveBytes ?? WriteReserve) + " (seuils relevés de quatre fois la file en attente).");
        var retention = string.Join(", ", StoragePolicyRules.Families.Select(f =>
        {
            var days = StoragePolicyRules.DaysOf(policy, f.Family);
            return f.Label + " " + (days > 0 ? FrenchText.Integer(days) + FrenchText.Nbsp + "j" : "sans limite");
        }));
        lines.Add("Conservation" + c + retention + ". Mesures de performance" + c + "10" + FrenchText.ThousandsSeparator + "000 dernières ; instantanés du parc" + c + "400 jours ; cache de recherche" + c
            + "20 requêtes par périmètre, chacune de 20" + FrenchText.ThousandsSeparator + "000 lignes et 32" + FrenchText.Nbsp + "Mo au plus ; sauvegardes" + c
            + FrenchText.Count(policy.BackupKeep, "copie", "copies") + " manuelles ou automatiques et " + FrenchText.Count(policy.BackupKeep, "copie", "copies") + " avant un geste, toutes vérifiées. Reçus gardés sans limite.");
        if (usage is { Categories.Length: > 0 })
        {
            var top = Usage(usage).Categories.Take(3).Select(x => x.Label + " (" + (usage.DbstatAvailable ? x.BytesText + ", " : "") + FrenchText.Count(x.Rows, "ligne", "lignes") + ")");
            lines.Add("Collections les plus volumineuses à la dernière mesure" + c + string.Join(", ", top) + ".");
        }
        return [.. lines];
    }

    /// <summary>Closed list of the purge categories (D029): four purgeable, four never.</summary>
    public static ImmutableArray<(string Id, string Label, string Mode, bool Purgeable)> PurgeCategories { get; } =
    [
        ("observations", "Mesures de présence, console, inventaire et détails WMI", "all", true),
        ("snapshots", "Captures et instantanés", "all", true),
        ("history", "Historique ancien hors associations déclarées", "bounded", true),
        ("index", "Index des objets de l’annuaire", "all", true),
        ("logs", "Journal d’audit", "never", false),
        ("configuration", "Configuration et préférences", "never", false),
        ("manualLinks", "Associations déclarées et leur historique", "never", false),
        ("receipts", "Reçus d’opérations", "never", false),
    ];

    /// <summary>What a purge never touches (PAR-032), in plain words.</summary>
    public static ImmutableArray<string> NeverPurged { get; } =
    [
        "Le journal d’audit, la configuration et les préférences, les associations déclarées et leur historique, et les reçus d’opérations ne sont jamais purgeables.",
        "La purge de l’historique garde l’historique complet d’un poste dont l’association actuelle est déclarée.",
        "Les métadonnées BitLocker et LAPS (secret_state) ne sont jamais une cible de l’index ; aucun secret n’est jamais stocké.",
        "Une sauvegarde vérifiée est faite juste avant la purge (amélioration de Domenia 2) ; elle reste hors de la rotation.",
    ];

    /// <summary>
    /// Tables of each purgeable category (closed identifiers, never SQL from the page, Get-DomeniaPurgeTargets). <c>Key</c> is the
    /// key of the rows counted by the inspection (<see cref="LocalStoreTable.Table"/>): the table, or the table and the part of it
    /// that the category owns (the clocks of the collections and of the directory share one metadata table).
    /// </summary>
    public static ImmutableArray<(string Table, string Action, string Label, string Key)> PurgeTargets(string category) => category switch
    {
        "observations" =>
        [
            ("domenia_observations", "delete", "Mesures par famille", "domenia_observations"), ("domenia_details", "delete", "Résultats détaillés", "domenia_details"),
            ("presence_cache", "delete", "Présence en cache", "presence_cache"), ("park_state", "delete", "État du parc", "park_state"),
            ("park_session_cache", "delete", "Cache de session du parc", "park_session_cache"), ("domenia_domain_metadata", "delete", "Horloges ping et WMI", "domenia_domain_metadata.collection"),
        ],
        "snapshots" => [("adcc_live_queries", "delete", "Instantanés de recherche", "adcc_live_queries")],
        "history" =>
        [
            ("user_machine_history", "delete", "Historique des associations (déclarées gardées)", "user_machine_history"), ("user_scan_history", "delete", "Historique des relevés d’utilisateurs", "user_scan_history"),
            ("operation_runs", "delete", "Exécutions d’opérations", "operation_runs"), ("fleet_snapshots", "delete", "Instantanés quotidiens du parc", "fleet_snapshots"),
        ],
        "index" =>
        [
            ("ad_objects", "delete", "Objets de l’annuaire", "ad_objects"), ("domenia_directory_data", "delete", "Données d’annuaire", "domenia_directory_data"),
            ("ad_computer_facts", "delete", "Faits des ordinateurs", "ad_computer_facts"), ("domenia_provenance", "delete", "Provenance", "domenia_provenance"),
            ("ad_snapshots", "delete", "Relevés de l’annuaire", "ad_snapshots"), ("domenia_domain_metadata", "delete", "Horloge des lectures AD", "domenia_domain_metadata.directory"),
            ("sync_state", "reset", "Point de reprise du domaine", "sync_state"),
        ],
        _ => throw new ArgumentException("Category not purgeable: " + category, nameof(category)),
    };

    /// <summary>
    /// Rows a purge of one category removes from each of its tables. All-or-nothing categories empty their tables; the history
    /// keeps what is younger than its age (exact for the association history, the same share for the other history tables)
    /// and the full history of a workstation whose association is declared. Without a count per table (an inspection that
    /// did not count them), the category total is reported on its first table, never invented on the others.
    /// </summary>
    public static ImmutableArray<(string Table, string Action, string Label, long Rows)> PurgeTableRows(LocalStoreSnapshot store, string category, int historyDays)
    {
        ArgumentNullException.ThrowIfNull(store);
        var targets = PurgeTargets(category);
        if (!store.NativePurgeTargets.IsEmpty)
        {
            return [.. store.NativePurgeTargets.Where(x => x.Category == category).Select(x =>
                (x.Table, x.Action, x.Label, category == "history"
                    ? x.DayCounts.Skip(Math.Clamp(historyDays, 1, StoragePolicyRules.MaxRetentionDays)).Sum(n => (long)n)
                    : x.Rows))];
        }
        var counted = store.Tables.ToDictionary(t => t.Table, t => t.Rows, StringComparer.Ordinal);
        if (counted.Count == 0)
        {
            var total = category == "history" ? HistoryFallback(store, historyDays) : store.Categories.FirstOrDefault(c => c.Id == category)?.Rows ?? 0;
            return [.. targets.Select((t, n) => (t.Table, t.Action, t.Label, n == 0 ? total : 0L))];
        }
        long Count(string key) => counted.TryGetValue(key, out var rows) ? Math.Max(0, rows) : 0;
        if (category != "history")
        {
            // A reset table keeps one row per domain: it is reset, not removed.
            return [.. targets.Select(t => (t.Table, t.Action, t.Label, t.Action == "reset" ? Math.Min(1L, Count(t.Key)) : Count(t.Key)))];
        }
        var history = store.Families.FirstOrDefault(f => f.Family == "linkHistory");
        var all = history is null ? 0 : history.DayCounts.Sum(x => (long)x);
        var older = history is null ? 0 : StoragePolicyRules.RowsOlderThan(history, historyDays, compaction: false);
        var share = all > 0 ? older / (double)all : 0;
        return [.. targets.Select(t => (t.Table, t.Action, t.Label, t.Table == "user_machine_history" ? older : (long)Math.Round(Count(t.Key) * share)))];
    }

    private static long HistoryFallback(LocalStoreSnapshot store, int historyDays)
    {
        var history = store.Families.FirstOrDefault(f => f.Family == "linkHistory");
        var older = history is null ? 0 : StoragePolicyRules.RowsOlderThan(history, historyDays, compaction: false);
        var others = store.Categories.FirstOrDefault(c => c.Id == "history")?.Rows ?? 0;
        var total = history is null ? 0 : history.DayCounts.Sum(x => (long)x);
        return older + (total > 0 ? (long)Math.Round((others - total) * (older / (double)total)) : 0);
    }

    /// <summary>Current size of each purge category in the base.</summary>
    public static ImmutableArray<PurgeCategoryView> PurgeView(LocalStoreSnapshot store)
    {
        ArgumentNullException.ThrowIfNull(store);
        return
        [
            .. PurgeCategories.Select(p =>
            {
                var category = store.Categories.FirstOrDefault(c => c.Id == p.Id);
                var detail = p.Mode switch
                {
                    "all" => "Vidé entièrement, reconstruit par les prochaines lectures.",
                    "bounded" => "Seulement plus ancien que l’âge choisi (730 jours par défaut).",
                    _ => "Jamais purgé.",
                };
                return new PurgeCategoryView(p.Id, p.Label, p.Mode, p.Purgeable, category?.Rows ?? 0, category?.Bytes, detail);
            }),
        ];
    }

    /// <summary>
    /// Purge preview (PAR-031, Get-DomeniaPurgePlan): exact counts per table group, refusals named, and the fingerprint the
    /// plan requires. A non-purgeable or unknown category is refused, never purged.
    /// </summary>
    public static PurgePreview PurgePlan(LocalStoreSnapshot store, IReadOnlyCollection<string> selection, int historyDays, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(selection);
        ArgumentNullException.ThrowIfNull(zone);
        var categories = new List<string>();
        var refused = new List<string>();
        var targets = new List<PurgeTargetView>();
        foreach (var key in selection.Select(s => s.Trim()).Distinct(StringComparer.Ordinal))
        {
            var entry = PurgeCategories.FirstOrDefault(p => p.Id == key);
            if (entry.Id is null)
            {
                refused.Add(key + FrenchText.Colon + "catégorie inconnue.");
                continue;
            }
            if (!entry.Purgeable)
            {
                refused.Add(entry.Label + FrenchText.Colon + "jamais purgé.");
                continue;
            }
            categories.Add(entry.Id);
            targets.AddRange(PurgeTableRows(store, entry.Id, historyDays).Select(t => new PurgeTargetView(entry.Id, t.Label, t.Table, t.Action, t.Rows)));
        }
        var cutoff = categories.Contains("history") ? WritePlans.TruncateToSecond(now) - TimeSpan.FromDays(historyDays) : (DateTimeOffset?)null;
        var lines = new List<string>();
        foreach (var category in categories)
        {
            var label = PurgeCategories.First(p => p.Id == category).Label;
            var rows = PurgeRows(store, category, historyDays);
            lines.Add(category == "history"
                ? label + FrenchText.Colon + FrenchText.Count(rows, "ligne antérieure", "lignes antérieures") + " au " + SettingsFormat.LocalDate(cutoff!.Value, zone) + " à retirer."
                : label + FrenchText.Colon + FrenchText.Count(rows, "ligne à retirer", "lignes à retirer") + (category == "index" ? " ; le point de reprise du domaine est réinitialisé, la prochaine lecture de l’annuaire sera complète." : "."));
        }
        lines.Add("Les vues concernées sont invalidées ensuite et se reconstruisent aux prochaines lectures.");
        var total = categories.Sum(c => PurgeRows(store, c, historyDays));
        var fingerprint = StoragePolicyRules.Fingerprint("purge", store,
            categories.Select(c => c + "=" + PurgeRows(store, c, historyDays).ToString(CultureInfo.InvariantCulture)).Append("history=" + historyDays.ToString(CultureInfo.InvariantCulture)));
        return new PurgePreview([.. categories], historyDays, cutoff, [.. targets], total, [.. refused], [.. lines], NeverPurged, fingerprint, true, true, true, categories.Count == 0 || total == 0);
    }

    /// <summary>Rows a purge of one category removes, all tables together (a reset point is not a removed row).</summary>
    public static long PurgeRows(LocalStoreSnapshot store, string category, int historyDays)
    {
        ArgumentNullException.ThrowIfNull(store);
        return PurgeTableRows(store, category, historyDays).Where(t => t.Action != "reset").Sum(t => t.Rows);
    }

    /// <summary>One readable line per cached perimeter, with the use allowed (Get-DomeniaCacheCatalogRows).</summary>
    public static ImmutableArray<CacheCatalogRow> Catalog(IEnumerable<LocalStoreScope> scopes, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(scopes);
        ArgumentNullException.ThrowIfNull(zone);
        return
        [
            .. scopes.Select(s =>
            {
                var age = "";
                if (s.ObservedAt is DateTimeOffset observed)
                {
                    var span = now - observed;
                    age = span.TotalDays >= 1 ? FrenchText.Integer((long)span.TotalDays) + FrenchText.Nbsp + "j"
                        : span.TotalHours >= 1 ? FrenchText.Integer((long)span.TotalHours) + FrenchText.Nbsp + "h"
                        : FrenchText.Integer((long)Math.Max(0, span.TotalMinutes)) + FrenchText.Nbsp + "min";
                }
                return new CacheCatalogRow(s.Scope, s.Source, s.Controller, s.Reader, s.Rows,
                    s.ObservedAt is DateTimeOffset at ? SettingsFormat.LocalDate(at, zone) : "inconnu", age,
                    "Consultation historique. Aucune modification sans relecture AD.");
            }),
        ];
    }

    /// <summary>Label of a kind of backup.</summary>
    public static string BackupKindLabel(string kind) => kind switch
    {
        "manual" => "Manuelle",
        "scheduled" => "Planifiée",
        "gesture" => "Avant un geste",
        "retention" => "Avant conservation",
        "purge" => "Avant purge",
        "migration" => "Avant migration",
        "import" => "Avant reprise",
        _ => kind,
    };

    /// <summary>Backups of the rotation (manual and scheduled); the others form their own series, kept apart.</summary>
    public static bool InRotation(string kind) => kind is "manual" or "scheduled";

    /// <summary>Backups as listed, most recent first.</summary>
    public static ImmutableArray<StorageBackupView> Backups(LocalStoreSnapshot store)
    {
        ArgumentNullException.ThrowIfNull(store);
        return
        [
            .. store.Backups.OrderByDescending(b => b.At).Select(b => new StorageBackupView(b.Id, b.FileName, b.At, b.Bytes, SettingsFormat.Size(b.Bytes),
                b.Sha256, SettingsFormat.ShortSha(b.Sha256), StoragePolicyRules.IsVerified(b), b.Kind, BackupKindLabel(b.Kind), InRotation(b.Kind), b.PreferenceKeys,
                BackupPreferencesRules.IsBound(b), b.Revision, b.LastMeasureAt, Content(b.Counts))),
        ];
    }

    /// <summary>
    /// Checks a destination chosen by the operator for a copy or a move (PAR-016, PAR-035): absolute local path on a drive,
    /// file ending in .db, never a share, a device path or the active base and its journals. Returns the refusal, or null.
    /// </summary>
    public static string? DestinationProblem(string? destination, string activePath)
    {
        ArgumentNullException.ThrowIfNull(activePath);
        var path = (destination ?? "").Trim();
        if (path.Length == 0)
        {
            return "Indiquez le fichier de destination (chemin complet, par exemple D:\\Domenia\\Domenia.db).";
        }
        if (path.Length > 260)
        {
            return "Chemin trop long" + FrenchText.Colon + "260 caractères au plus.";
        }
        if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.StartsWith("//", StringComparison.Ordinal))
        {
            return "Destination réseau refusée" + FrenchText.Colon + "une base locale reste sur un disque local.";
        }
        if (path.Length < 4 || !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\')
        {
            return "Chemin complet attendu, sur un lecteur local (par exemple D:\\Domenia\\Domenia.db).";
        }
        if (path.IndexOfAny(['<', '>', '"', '|', '?', '*']) >= 0 || path[2..].Contains(':', StringComparison.Ordinal) || path.Any(char.IsControl))
        {
            return "Caractères non admis dans le chemin.";
        }
        if (path.Contains(@"\..\", StringComparison.Ordinal) || path.EndsWith(@"\..", StringComparison.Ordinal) || path.Contains(@"\.\", StringComparison.Ordinal))
        {
            return "Chemin relatif refusé" + FrenchText.Colon + "indiquez le chemin complet.";
        }
        // The active base and its journals first: « Domenia.db-wal » is refused as the journal it is, not for its extension.
        string[] journals = ["", "-wal", "-shm", "-journal"];
        if (journals.Any(j => string.Equals(path, activePath + j, StringComparison.OrdinalIgnoreCase)))
        {
            return "La base active et ses journaux ne peuvent pas servir de destination.";
        }
        if (!path.EndsWith(".db", StringComparison.OrdinalIgnoreCase))
        {
            return "La destination doit être un fichier .db.";
        }
        return null;
    }

    /// <summary>
    /// Checks a destination with what the host read about it (PAR-016, PAR-035, Domenia 1 Test-MaintWTarget): the path rules,
    /// then an existing folder on a local fixed drive that is no link or junction, then the reserve of its volume (a move:
    /// two copies of the base and its journal plus 32 MiB; a copy: one copy plus 32 MiB). A move goes to a new file only; a
    /// copy replaces the chosen file, which is said. Never creates nor writes anything.
    /// </summary>
    public static DestinationCheck CheckDestination(string? destination, string purpose, string activePath, long baseBytes, DestinationFacts facts)
    {
        ArgumentNullException.ThrowIfNull(purpose);
        ArgumentNullException.ThrowIfNull(activePath);
        ArgumentNullException.ThrowIfNull(facts);
        var move = purpose == "move";
        var path = (destination ?? "").Trim();
        var reserve = move ? CopyReserve(Math.Max(0, baseBytes)) : Math.Max(0, baseBytes) + WriteReserve;
        var freeText = facts.FreeBytes is long f ? SettingsFormat.Size(f) : "inconnu";
        DestinationCheck Refuse(string problem) => new(false, purpose, path, problem, facts.FolderExists, facts.FileExists, facts.FreeBytes, freeText, reserve, SettingsFormat.Size(reserve), problem);
        if (DestinationProblem(path, activePath) is string problem)
        {
            return Refuse(problem);
        }
        if (!facts.LocalFixedDrive)
        {
            return Refuse("Lecteur refusé" + FrenchText.Colon + "un disque local fixe est exigé (ni amovible, ni réseau, ni CD).");
        }
        if (!facts.FolderExists)
        {
            return Refuse("Dossier absent" + FrenchText.Colon + "choisissez un dossier qui existe ; Domenia ne crée aucun dossier.");
        }
        if (facts.ReparsePoint)
        {
            return Refuse("Lien ou jonction refusé" + FrenchText.Colon + "choisissez le dossier réel.");
        }
        if (move && facts.FileExists)
        {
            return Refuse("Un fichier porte déjà ce nom" + FrenchText.Colon + "un déplacement va toujours vers un nouveau fichier.");
        }
        if (facts.FreeBytes is long free && free < reserve)
        {
            return Refuse("Espace insuffisant sur ce volume" + FrenchText.Colon + SettingsFormat.Size(free) + " libres pour " + SettingsFormat.Size(reserve) + " exigés.");
        }
        var text = "Destination admise" + FrenchText.Colon + (facts.FreeBytes is long left ? SettingsFormat.Size(left) + " libres, " : "")
            + SettingsFormat.Size(reserve) + " réservés" + (move ? " (deux copies et 32" + FrenchText.Nbsp + "Mo de marge)" : " (une copie et 32" + FrenchText.Nbsp + "Mo de marge)") + "."
            + (!move && facts.FileExists ? " Le fichier existant sera remplacé par la copie vérifiée." : "");
        return new DestinationCheck(true, purpose, path, null, facts.FolderExists, facts.FileExists, facts.FreeBytes, freeText, reserve, SettingsFormat.Size(reserve), text);
    }

    /// <summary>
    /// Checks the path of a backup chosen for a restore (PAR-017): a .db file of a local disk (or of the data folder of this
    /// account, %LOCALAPPDATA%), never a share, a device path or a relative path. Returns the refusal, or null.
    /// </summary>
    public static string? BackupFileProblem(string? path)
    {
        var p = (path ?? "").Trim();
        if (p.Length == 0)
        {
            return "Indiquez le fichier .db à restaurer (chemin complet).";
        }
        if (p.Length > 260)
        {
            return "Chemin trop long" + FrenchText.Colon + "260 caractères au plus.";
        }
        if (p.StartsWith(@"\\", StringComparison.Ordinal) || p.StartsWith("//", StringComparison.Ordinal))
        {
            return "Sauvegarde sur un partage refusée" + FrenchText.Colon + "copiez-la d’abord sur un disque local.";
        }
        var data = p.StartsWith(@"%LOCALAPPDATA%\", StringComparison.OrdinalIgnoreCase);
        if (!data && (p.Length < 4 || !char.IsAsciiLetter(p[0]) || p[1] != ':' || p[2] != '\\'))
        {
            return "Chemin complet attendu, sur un disque local (par exemple D:\\Domenia\\Domenia-20261021-1430.db).";
        }
        var rest = data ? p["%LOCALAPPDATA%".Length..] : p[2..];
        if (rest.IndexOfAny(['<', '>', '"', '|', '?', '*', ':']) >= 0 || p.Any(char.IsControl))
        {
            return "Caractères non admis dans le chemin.";
        }
        if (p.Contains(@"\..\", StringComparison.Ordinal) || p.Contains(@"\.\", StringComparison.Ordinal) || p.EndsWith(@"\..", StringComparison.Ordinal))
        {
            return "Chemin relatif refusé" + FrenchText.Colon + "indiquez le chemin complet.";
        }
        return p.EndsWith(".db", StringComparison.OrdinalIgnoreCase) ? null : "La sauvegarde doit être un fichier .db.";
    }
}
