using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>Plan of a verified backup of the local base (PAR-033, PAR-034).</summary>
public interface IStorageBackupExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanBackupAsync(StoragePolicy policy, int preferenceKeys, CancellationToken cancellationToken);
}

/// <summary>Plan of a verified backup published to a file chosen by the operator (PAR-035).</summary>
public interface IStorageBackupCopyExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanBackupCopyAsync(string destination, StoragePolicy policy, int preferenceKeys, CancellationToken cancellationToken);
}

/// <summary>Plan of the retention of old measures, bound to the fingerprint of its preview (PAR-024).</summary>
public interface IStorageRetentionExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanRetentionAsync(StoragePolicy policy, string fingerprint, CancellationToken cancellationToken);
}

/// <summary>Plan of a voluntary purge of closed categories, bound to the fingerprint of its preview (PAR-031).</summary>
public interface IStoragePurgeExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanPurgeAsync(IReadOnlyCollection<string> categories, int historyDays, string fingerprint, CancellationToken cancellationToken);
}

/// <summary>Plan of the move of the local base to a new local file (PAR-016).</summary>
public interface IStorageMoveExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanMoveAsync(string destination, CancellationToken cancellationToken);
}

/// <summary>Plan of the restore of a verified backup into a new file (PAR-017).</summary>
public interface IStorageRestoreExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanRestoreAsync(string backupId, CancellationToken cancellationToken);
}

/// <summary>Plan of the end of an interrupted switch (PAR-018).</summary>
public interface IStorageResumeExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanResumeAsync(CancellationToken cancellationToken);
}

/// <summary>Plan of the return to the previous base after a switch of this session (PAR-019).</summary>
public interface IStorageRollbackExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanRollbackAsync(CancellationToken cancellationToken);
}

/// <summary>Plan of the resumption of the suspended writer of the base (PAR-010).</summary>
public interface IStorageWriterResumeExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanWriterResumeAsync(CancellationToken cancellationToken);
}

/// <summary>Plan of the takeover of the Domenia 1 data, bound to the fingerprint of its simulation (PAR-028).</summary>
public interface IStorageLegacyImportExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanLegacyImportAsync(string fingerprint, CancellationToken cancellationToken);
}

/// <summary>
/// Plans of the writes of the local base (docs/ops/parametres.md § 6): pure drafts built from a snapshot of the base, with
/// the same circuit as every write (plan, confirmation, receipt written before, re-read after, never replayed). The target
/// is the base itself (kind « localStore »): its readable name, its path and a GUID derived from its identity.
/// </summary>
public static class StorageWritePlans
{
    public const string TargetKind = "localStore";
    public const string Backup = "storage.backup";
    public const string BackupCopy = "storage.backupCopy";
    public const string Retention = "storage.retention";
    public const string Purge = "storage.purge";
    public const string Move = "storage.move";
    public const string Restore = "storage.restore";
    public const string Resume = "storage.resume";
    public const string Rollback = "storage.rollback";
    public const string WriterResume = "storage.writerResume";
    public const string LegacyImport = "storage.legacyImport";

    /// <summary>Error of a preview that no longer matches the base: the plan is refused, nothing is written.</summary>
    public const string PreviewStale = "settings.previewStale";

    /// <summary>The base of the mode cannot be written (absent, or in recovery).</summary>
    public const string StoreUnavailable = "settings.storeUnavailable";

    /// <summary>A destination refused before any copy (share, device path, active base, not a .db file).</summary>
    public const string DestinationRefused = "settings.destinationRefused";

    private static readonly WriteConfirmation Simple = new(false, null, "Confirmation simple" + FrenchText.Colon + "écriture de la base locale de Domenia, jamais de l’annuaire ni d’un poste.");

    /// <summary>The base as the target of a plan.</summary>
    public static WriteTarget Target(LocalStoreSnapshot store)
    {
        ArgumentNullException.ThrowIfNull(store);
        var name = store.Simulated ? "Base fictive · " + store.Domain : "Base du domaine " + store.Domain;
        return new WriteTarget(TargetKind, store.Simulated ? "Base locale (simulation)" : "Base locale", name, store.PathLabel, StoreGuid(store.StoreId), null);
    }

    /// <summary>GUID of a base, derived from the first half of its SHA-256 identity (path and domain).</summary>
    public static string StoreGuid(string storeId)
    {
        ArgumentNullException.ThrowIfNull(storeId);
        return Guid.TryParseExact(storeId.Length >= 32 ? storeId[..32] : storeId.PadRight(32, '0'), "N", out var guid) && guid != Guid.Empty
            ? guid.ToString("D")
            : "00000000-0000-4000-8000-000000000001";
    }

    /// <summary>Refuses a plan when the base cannot be written now (absent, proven unreadable, step running).</summary>
    public static void EnsureWritable(LocalStoreSnapshot store, bool allowRecovery = false)
    {
        ArgumentNullException.ThrowIfNull(store);
        if (!store.Available)
        {
            throw new DomeniaOperationException(StoreUnavailable, "Aucune base locale active" + FrenchText.Colon + "aucune écriture préparée.");
        }
        if (store.Maintenance.Draining || !string.IsNullOrEmpty(store.Maintenance.Job))
        {
            throw new DomeniaOperationException(StoreUnavailable, "Étape de maintenance en cours" + FrenchText.Colon + "attendez sa fin ; aucune écriture préparée.");
        }
        if (!allowRecovery && store.Maintenance.Recovery && !store.Maintenance.RecoveryReceipt)
        {
            throw new DomeniaOperationException(StoreUnavailable, "Base locale illisible" + FrenchText.Colon + "seule la restauration d’une sauvegarde vérifiée est proposée.");
        }
    }

    private static string Iso(DateTimeOffset at) => at.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture);

    private static WriteChange RevisionChange(LocalStoreSnapshot store, long after) => new(
        "revision", "Révision de la base", WriteChangeKind.Replace,
        "révision " + FrenchText.Integer(store.Revision), "révision " + FrenchText.Integer(after),
        store.Revision.ToString(CultureInfo.InvariantCulture), after.ToString(CultureInfo.InvariantCulture));

    /// <summary>File name of a new backup: « Domenia-AAAAMMJJ-HHmmss.db » in local time.</summary>
    public static string BackupFileName(DateTimeOffset now, TimeZoneInfo zone, string prefix = "Domenia")
    {
        ArgumentNullException.ThrowIfNull(zone);
        return prefix + "-" + TimeZoneInfo.ConvertTime(now, zone).ToString("yyyyMMdd'-'HHmmss", CultureInfo.InvariantCulture) + ".db";
    }

    /// <summary>The backup of the rotation that a new copy would push out, or null.</summary>
    public static LocalStoreBackup? RotatedOut(LocalStoreSnapshot store, int keep)
    {
        ArgumentNullException.ThrowIfNull(store);
        var rotation = store.Backups.Where(b => LocalStoreRules.InRotation(b.Kind)).OrderBy(b => b.At).ToList();
        return rotation.Count >= keep ? rotation[0] : null;
    }

    /// <summary>Draft of a verified backup (hot copy by the SQLite backup API, quick_check, SHA-256, rotation, preferences).</summary>
    public static WritePlanDraft BackupDraft(LocalStoreSnapshot store, StoragePolicy policy, int preferenceKeys, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(policy);
        EnsureWritable(store);
        if (store.Maintenance.Locked)
        {
            throw new DomeniaOperationException(StoreUnavailable, "Bascule à terminer" + FrenchText.Colon + "aucune sauvegarde tant qu’elle n’est pas reprise ou annulée.");
        }
        var file = BackupFileName(now, zone);
        var out1 = RotatedOut(store, policy.BackupKeep);
        var changes = new List<WriteChange>
        {
            new("backup.file", "Nouvelle sauvegarde", WriteChangeKind.Add, null, file + " (" + SettingsFormat.Size(store.DatabaseBytes) + " environ, journal en mode delete)", null, file),
            new("backup.preferences", "Préférences jointes", WriteChangeKind.Add, null,
                preferenceKeys > 0 ? "annexe .preferences.json (" + FrenchText.Count(preferenceKeys, "clé approuvée", "clés approuvées") + ", sans identité de connexion)" : "aucune préférence approuvée à joindre",
                null, preferenceKeys.ToString(CultureInfo.InvariantCulture)),
        };
        if (out1 is not null)
        {
            changes.Add(new WriteChange("backup.rotation", "Rotation des copies", WriteChangeKind.Remove, out1.FileName,
                "retirée (" + FrenchText.Count(policy.BackupKeep, "copie conservée", "copies conservées") + ")", out1.Id, null));
        }
        var risks = new List<WriteRisk>
        {
            new(Tone.Info, "L’original est ouvert en lecture seule et n’est jamais modifié ; une copie partielle est supprimée en cas d’échec."),
            new(Tone.Info, "La copie compte comme réussie seulement avec son contrôle SQLite (quick_check), son empreinte SHA-256 et sa date de vérification."),
        };
        if (store.Simulated)
        {
            risks.Add(new WriteRisk(Tone.Info, "Simulation" + FrenchText.Colon + "copie fictive en mémoire, aucun fichier n’est écrit sur le disque."));
        }
        return new WritePlanDraft(Backup, "Sauvegarder la base locale", "Sauvegarde de la base locale",
            "Copie à chaud cohérente de " + Target(store).Name + ", contrôlée puis rangée dans le dossier Backups.",
            Target(store), [.. changes], [.. risks], Simple,
            new WriteReversibility(true, "Sans effet sur la base", "Une sauvegarde ajoute un fichier ; la base active n’est pas modifiée. Une copie inutile se supprime à la main."),
            null);
    }

    /// <summary>Draft of a backup published to a chosen file (atomic publication; the local verified copy stays if the export fails).</summary>
    public static WritePlanDraft BackupCopyDraft(LocalStoreSnapshot store, string destination, StoragePolicy policy, int preferenceKeys, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(destination);
        var draft = BackupDraft(store, policy, preferenceKeys, now, zone);
        if (LocalStoreRules.DestinationProblem(destination, store.PathLabel) is string problem)
        {
            throw new DomeniaOperationException(DestinationRefused, problem + " Aucune copie préparée.");
        }
        var path = destination.Trim();
        var changes = draft.Changes.Add(new WriteChange("backup.export", "Copie publiée vers", WriteChangeKind.Add, null, path, null, path));
        var risks = draft.Risks.Add(new WriteRisk(Tone.Warn, "Le fichier choisi est remplacé s’il existe ; les liens, jonctions et dossiers absents sont refusés à l’écriture."));
        return draft with
        {
            Kind = BackupCopy,
            Title = "Copier une sauvegarde vers un fichier",
            Label = "Copie d’une sauvegarde vers un fichier",
            Summary = "Sauvegarde vérifiée de " + draft.Target.Name + ", puis publiée atomiquement vers " + path + ".",
            Changes = changes,
            Risks = risks,
        };
    }

    /// <summary>Draft of the retention (PAR-024): one change per family with rows to remove, a backup before, revision + 1.</summary>
    public static WritePlanDraft RetentionDraft(LocalStoreSnapshot store, RetentionPreview preview, string fingerprint, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(preview);
        ArgumentNullException.ThrowIfNull(fingerprint);
        ArgumentNullException.ThrowIfNull(zone);
        EnsureWritable(store);
        if (!string.Equals(preview.Fingerprint, fingerprint, StringComparison.Ordinal))
        {
            throw new DomeniaOperationException(PreviewStale, "La base ou la politique a changé depuis la prévisualisation" + FrenchText.Colon + "refaites la prévisualisation ; rien n’a été retiré.");
        }
        if (preview.NothingToDo)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune mesure plus ancienne que la politique de conservation" + FrenchText.Colon + "rien à retirer.");
        }
        var changes = new List<WriteChange> { RevisionChange(store, store.Revision + 1) };
        foreach (var row in preview.Families.Where(r => r.Rows > 0))
        {
            var what = row.Compaction ? FrenchText.Count(row.Rows, "observation répétée", "observations répétées") : FrenchText.Count(row.Rows, "mesure", "mesures");
            changes.Add(new WriteChange("retention." + row.Family, row.Label, WriteChangeKind.Remove,
                what + " antérieure" + (row.Rows > 1 ? "s" : "") + " au " + SettingsFormat.LocalDate(row.Cutoff!.Value, zone), "retirée" + (row.Rows > 1 ? "s" : ""),
                row.Rows.ToString(CultureInfo.InvariantCulture) + "@" + Iso(row.Cutoff.Value), "0"));
        }
        return new WritePlanDraft(Retention, "Appliquer la conservation", "Conservation des mesures",
            "Retrait de " + FrenchText.Count(preview.TotalRows, "ligne trop ancienne", "lignes trop anciennes") + " de " + Target(store).Name + ", après une sauvegarde vérifiée.",
            Target(store), [.. changes],
            [
                new(Tone.Warn, "Les postes concernés perdront leurs derniers états trop anciens (présence, utilisateur, inventaire, sondes) : ils seront à relire."),
                new(Tone.Info, "Une sauvegarde vérifiée est faite juste avant (copie autonome, quick_check, identité et révision contrôlées) ; elle reste hors rotation."),
                new(Tone.Info, "Toujours conservés : objets AD, comptes, associations actuelles et déclarées, requêtes, journaux et reçus."),
                new(Tone.Info, "La place libérée est réutilisable mais le fichier ne rétrécit pas."),
            ],
            Simple,
            new WriteReversibility(false, "Retour par la sauvegarde", "Les lignes retirées ne reviennent qu’en restaurant la sauvegarde faite juste avant (« Restaurer une sauvegarde… »)."),
            null);
    }

    /// <summary>Draft of a purge (PAR-031): exact rows per category, typed confirmation of the domain, verified backup before.</summary>
    public static WritePlanDraft PurgeDraft(LocalStoreSnapshot store, PurgePreview preview, string fingerprint, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(preview);
        ArgumentNullException.ThrowIfNull(fingerprint);
        ArgumentNullException.ThrowIfNull(zone);
        EnsureWritable(store);
        if (!string.Equals(preview.Fingerprint, fingerprint, StringComparison.Ordinal))
        {
            throw new DomeniaOperationException(PreviewStale, "La base a changé depuis la simulation de la purge" + FrenchText.Colon + "refaites la simulation ; rien n’a été retiré.");
        }
        if (preview.Refused.Length > 0 || preview.NothingToDo)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, preview.Refused.Length > 0
                ? string.Join(" ", preview.Refused) + " Aucune purge préparée."
                : "Rien à purger dans les catégories choisies.");
        }
        var changes = new List<WriteChange> { RevisionChange(store, store.Revision + 1) };
        foreach (var category in preview.Categories)
        {
            var label = LocalStoreRules.PurgeCategories.First(p => p.Id == category).Label;
            var rows = LocalStoreRules.PurgeRows(store, category, preview.HistoryDays);
            changes.Add(new WriteChange("purge." + category, label, category == "index" ? WriteChangeKind.Reset : WriteChangeKind.Remove,
                category == "history"
                    ? FrenchText.Count(rows, "ligne antérieure", "lignes antérieures") + " au " + SettingsFormat.LocalDate(preview.HistoryCutoff!.Value, zone)
                    : FrenchText.Count(rows, "ligne", "lignes"),
                category == "index" ? "vidé, point de reprise réinitialisé" : "retirée" + (rows > 1 ? "s" : ""),
                rows.ToString(CultureInfo.InvariantCulture) + (category == "history" ? "@" + Iso(preview.HistoryCutoff!.Value) : ""), "0"));
        }
        var domain = store.Domain;
        return new WritePlanDraft(Purge, "Purger des données locales", "Purge des données locales",
            "Purge volontaire de " + FrenchText.Count(preview.TotalRows, "ligne", "lignes") + " de " + Target(store).Name + " (" + string.Join(", ", preview.Categories.Select(c => LocalStoreRules.CategoryLabel(c).ToLowerInvariant())) + ").",
            Target(store), [.. changes],
            [
                new(Tone.Alert, "Les données retirées ne se reconstruisent qu’avec de nouvelles lectures de l’annuaire et des postes."),
                new(Tone.Info, "Une sauvegarde vérifiée est faite juste avant (amélioration de Domenia 2) ; elle reste hors rotation."),
                new(Tone.Info, "Jamais purgés : journal d’audit, configuration et préférences, associations déclarées et leur historique, reçus d’opérations."),
            ],
            new WriteConfirmation(true, domain, "Saisie du nom du domaine exigée" + FrenchText.Colon + "une purge retire des données en nombre."),
            new WriteReversibility(false, "Retour par la sauvegarde", "Les lignes purgées ne reviennent qu’en restaurant la sauvegarde faite juste avant."),
            null);
    }

    /// <summary>Draft of the move of the base to a new local file (copy, check, switch; original kept read only with a marker).</summary>
    public static WritePlanDraft MoveDraft(LocalStoreSnapshot store, string destination, long? freeBytes)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(destination);
        EnsureWritable(store);
        if (store.Maintenance.Locked)
        {
            throw new DomeniaOperationException(StoreUnavailable, "Bascule à terminer d’abord" + FrenchText.Colon + "aucun déplacement préparé.");
        }
        if (LocalStoreRules.DestinationProblem(destination, store.PathLabel) is string problem)
        {
            throw new DomeniaOperationException(DestinationRefused, problem + " Aucun déplacement préparé.");
        }
        var path = destination.Trim();
        var reserve = LocalStoreRules.CopyReserve(store.DatabaseBytes + store.WalBytes);
        if (freeBytes is long free && free < reserve)
        {
            throw new DomeniaOperationException(DestinationRefused, "Espace insuffisant sur la destination" + FrenchText.Colon + SettingsFormat.Size(free) + " libres pour " + SettingsFormat.Size(reserve) + " exigés. Aucun déplacement préparé.");
        }
        return new WritePlanDraft(Move, "Déplacer la base locale", "Déplacement de la base locale",
            "Copie vérifiée de " + Target(store).Name + " vers " + path + ", puis bascule ; le fichier d’origine est gardé en lecture seule.",
            Target(store),
            [
                new("store.path", "Emplacement de la base", WriteChangeKind.Move, store.PathLabel, path, store.PathLabel, path),
                new("store.original", "Fichier d’origine", WriteChangeKind.Replace, "base active", "conservé en lecture seule, avec un marqueur", "active", "readOnlyMarker"),
            ],
            [
                new(Tone.Warn, "Les nouvelles collectes sont suspendues le temps d’enregistrer la file (120 s au plus), puis la copie est contrôlée avant la bascule."),
                new(Tone.Info, "Réserve exigée sur la destination" + FrenchText.Colon + SettingsFormat.Size(reserve) + " (deux copies et 32 Mo de marge)" + (freeBytes is long f ? " ; libre" + FrenchText.Colon + SettingsFormat.Size(f) + "." : " ; espace libre mesuré au moment de la copie.")),
                new(Tone.Info, "Aucun original n’est écrasé ; une copie non confirmée laisse la session sur la base courante, les deux fichiers gardés."),
            ],
            Simple,
            new WriteReversibility(true, "Retour possible", "« Revenir à la base précédente » reste possible tant que la nouvelle base n’a reçu aucune écriture ; aucun fichier n’est supprimé."),
            null);
    }

    /// <summary>Draft of the restore of a verified backup into a new file; the backup is never modified, the active base never overwritten.</summary>
    public static WritePlanDraft RestoreDraft(LocalStoreSnapshot store, LocalStoreBackup backup, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(backup);
        ArgumentNullException.ThrowIfNull(zone);
        EnsureWritable(store, allowRecovery: true);
        if (store.Maintenance.Locked && !store.Maintenance.Recovery)
        {
            throw new DomeniaOperationException(StoreUnavailable, "Bascule à terminer d’abord" + FrenchText.Colon + "aucune restauration préparée.");
        }
        if (!StoragePolicyRules.IsVerified(backup))
        {
            throw new DomeniaOperationException(StoreUnavailable, "Cette sauvegarde n’est pas vérifiée (contrôle SQLite, empreinte ou date absents)" + FrenchText.Colon + "aucune restauration préparée.");
        }
        var file = BackupFileName(now, zone, "Domenia-restauree");
        var changes = new List<WriteChange>
        {
            RevisionChange(store, backup.Revision),
            new("restore.source", "Sauvegarde restaurée", WriteChangeKind.Replace, null, backup.FileName + " (" + SettingsFormat.Size(backup.Bytes) + ", SHA-256 " + SettingsFormat.ShortSha(backup.Sha256) + ")", null, backup.Id),
            new("store.path", "Base active", WriteChangeKind.Replace, store.PathLabel, file + " (nouveau fichier)", store.PathLabel, file),
        };
        void Diff(string attribute, string label, long? before, long? after)
        {
            if (before is long b && after is long a && a != b)
            {
                changes.Add(new WriteChange(attribute, label, WriteChangeKind.Replace, FrenchText.Integer(b), FrenchText.Integer(a), b.ToString(CultureInfo.InvariantCulture), a.ToString(CultureInfo.InvariantCulture)));
            }
        }
        Diff("count.objects", "Objets AD", store.Counts.Objects, backup.Counts.Objects);
        Diff("count.measures", "Mesures", store.Counts.Measures, backup.Counts.Measures);
        Diff("count.associations", "Associations", store.Counts.Associations, backup.Counts.Associations);
        return new WritePlanDraft(Restore, "Restaurer une sauvegarde", "Restauration d’une sauvegarde",
            "Restauration de " + backup.FileName + " (écrite le " + SettingsFormat.LocalDate(backup.At, zone) + ") dans un nouveau fichier, puis bascule.",
            Target(store), [.. changes],
            [
                new(Tone.Warn, "Les écritures postérieures à la sauvegarde ne seront plus visibles ; la base active est conservée, intacte."),
                new(Tone.Info, "La sauvegarde doit passer le schéma, quick_check et l’identité du domaine ; elle n’est jamais modifiée."),
                new(Tone.Info, backup.PreferenceKeys > 0 ? "Les préférences jointes (" + FrenchText.Count(backup.PreferenceKeys, "clé", "clés") + ") sont réappliquées après la bascule vérifiée." : "Sauvegarde sans annexe de préférences : les données seules sont restaurées."),
            ],
            new WriteConfirmation(true, store.Domain, "Saisie du nom du domaine exigée" + FrenchText.Colon + "la base active change."),
            new WriteReversibility(true, "Retour possible", "« Revenir à la base précédente » reste possible tant que la base restaurée n’a reçu aucune écriture ; aucun fichier n’est supprimé."),
            null);
    }

    /// <summary>Draft of the end of an interrupted switch (identity of the target checked again; no file deleted).</summary>
    public static WritePlanDraft ResumeDraft(LocalStoreSnapshot store)
    {
        ArgumentNullException.ThrowIfNull(store);
        EnsureWritable(store, allowRecovery: true);
        var m = store.Maintenance;
        if (!m.Locked || string.IsNullOrEmpty(m.TargetPath) || (m.Recovery && !m.RecoveryReceipt))
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune bascule interrompue" + FrenchText.Colon + "rien à reprendre.");
        }
        return new WritePlanDraft(Resume, "Reprendre la bascule", "Reprise d’une bascule interrompue",
            "Fin du passage vers la copie vérifiée désignée par le marqueur" + FrenchText.Colon + m.TargetPath + ".",
            Target(store),
            [new("store.path", "Base active", WriteChangeKind.Replace, store.PathLabel, m.TargetPath, store.PathLabel, m.TargetPath)],
            [new(Tone.Info, "L’identité de la copie est revérifiée avant la bascule ; aucun fichier n’est supprimé.")],
            Simple,
            new WriteReversibility(true, "Retour possible", "« Revenir à la base précédente » reste possible ensuite tant que la base n’a reçu aucune écriture."),
            null);
    }

    /// <summary>Draft of the return to the previous base (refused when the new base received a write).</summary>
    public static WritePlanDraft RollbackDraft(LocalStoreSnapshot store)
    {
        ArgumentNullException.ThrowIfNull(store);
        EnsureWritable(store);
        var m = store.Maintenance;
        var target = m.Locked ? m.PreviousPath : m.CanUndo ? m.PreviousPath : null;
        if (string.IsNullOrEmpty(target))
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune bascule de cette session à annuler" + FrenchText.Colon + "rien à faire.");
        }
        return new WritePlanDraft(Rollback, "Revenir à la base précédente", "Retour à la base précédente",
            "La session revient à " + target + " ; le marqueur de l’original est retiré.",
            Target(store),
            [
                RevisionChange(store, store.Revision),
                new("store.path", "Base active", WriteChangeKind.Replace, store.PathLabel, target, store.PathLabel, target),
            ],
            [new(Tone.Info, "Refusé si quelque chose est en file ou en cours, ou si la nouvelle base a changé ; aucun fichier n’est supprimé.")],
            Simple,
            new WriteReversibility(true, "Fichiers conservés", "Les deux fichiers restent sur le disque ; la base quittée reste disponible pour une restauration."),
            null);
    }

    /// <summary>Draft of the resumption of the suspended writer (the queue is armed again without losing the memory).</summary>
    public static WritePlanDraft WriterResumeDraft(LocalStoreSnapshot store)
    {
        ArgumentNullException.ThrowIfNull(store);
        if (!store.Available || !store.Writer.Suspended)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Les enregistrements locaux ne sont pas suspendus" + FrenchText.Colon + "rien à reprendre.");
        }
        if (store.Writer.Pending < 0)
        {
            throw new DomeniaOperationException(StoreUnavailable, "Un enregistrement est encore actif" + FrenchText.Colon + "attendez sa fin.");
        }
        return new WritePlanDraft(WriterResume, "Reprendre les sauvegardes locales", "Reprise des enregistrements locaux",
            "L’écrivain de la base est réarmé ; " + FrenchText.Count(store.Writer.Pending, "élément en mémoire repart", "éléments en mémoire repartent") + " vers la base.",
            Target(store),
            [new("writer.state", "Enregistrement local", WriteChangeKind.Replace, "suspendu", "actif", "suspended", "active")],
            [new(Tone.Info, "Aucune reprise automatique en boucle : un nouvel échec suspend de nouveau l’écrivain et le dit."), new(Tone.Info, "Aucune écriture dans l’annuaire.")],
            Simple,
            new WriteReversibility(true, "Sans perte", "Rien n’est effacé de la mémoire ; l’écrivain peut être suspendu de nouveau par un échec."),
            null);
    }

    /// <summary>Draft of the takeover of the Domenia 1 data (simulation shown first, idempotent, existing associations never replaced).</summary>
    public static WritePlanDraft LegacyImportDraft(LocalStoreSnapshot store, string expected, string fingerprint)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(expected);
        ArgumentNullException.ThrowIfNull(fingerprint);
        EnsureWritable(store);
        var legacy = store.Legacy;
        if (!legacy.Found)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune donnée de Domenia 1 trouvée sur ce poste" + FrenchText.Colon + "rien à reprendre.");
        }
        if (legacy.Refusals.Length > 0)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, string.Join(" ", legacy.Refusals));
        }
        if (!string.Equals(expected, fingerprint, StringComparison.Ordinal))
        {
            throw new DomeniaOperationException(PreviewStale, "Les données ont changé depuis la simulation de la reprise" + FrenchText.Colon + "refaites la simulation ; rien n’a été repris.");
        }
        var items = legacy.Items.Where(i => !i.Imported && i.Count > 0).ToList();
        if (items.Count == 0)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Données de Domenia 1 déjà reprises" + (legacy.ImportedAt is null ? "" : " (la reprise est idempotente)") + FrenchText.Colon + "rien de nouveau à reprendre.");
        }
        var changes = new List<WriteChange> { RevisionChange(store, store.Revision + 1) };
        changes.AddRange(items.Select(i => new WriteChange("legacy." + i.Id, i.Label, WriteChangeKind.Add, null,
            FrenchText.Integer(i.Count) + " repris" + (i.Detail.Length > 0 ? " (" + i.Detail + ")" : ""), null, i.Count.ToString(CultureInfo.InvariantCulture))));
        return new WritePlanDraft(LegacyImport, "Reprendre les données de Domenia 1", "Reprise des données de Domenia 1",
            "Reprise des données de Domenia 1 de " + legacy.Domain + " dans " + Target(store).Name + ", après une sauvegarde de migration.",
            Target(store), [.. changes],
            [
                new(Tone.Warn, "Les associations déjà présentes ne sont jamais remplacées ; les doublons sont refusés."),
                new(Tone.Info, "Les fichiers de Domenia 1 restent en place ; la reprise est idempotente et n’est jamais rejouée automatiquement."),
                new(Tone.Info, "La colonne de détail libre n’est jamais reprise ; aucun mot de passe ni secret n’existe dans ces données."),
            ],
            new WriteConfirmation(true, store.Domain, "Saisie du nom du domaine exigée" + FrenchText.Colon + "la reprise ajoute des données à la base."),
            new WriteReversibility(false, "Retour par la sauvegarde", "La sauvegarde de migration faite juste avant reste hors rotation ; une restauration revient à l’état précédent."),
            null);
    }

    /// <summary>
    /// Preconditions read again just before sending: same base, same revision when the plan carries one. Never writes.
    /// </summary>
    public static WritePrecheck CheckRevision(WritePlan plan, LocalStoreSnapshot store)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(store);
        if (!store.Available || !string.Equals(StoreGuid(store.StoreId), plan.Target.ObjectGuid, StringComparison.OrdinalIgnoreCase))
        {
            return WritePrecheck.Stale("La base locale active n’est plus celle du plan" + FrenchText.Colon + "rien n’a été envoyé. Préparez de nouveau l’écriture.");
        }
        var revision = plan.Changes.FirstOrDefault(c => c.Attribute == "revision");
        if (revision is not null && !string.Equals(revision.BeforeValue, store.Revision.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal))
        {
            return WritePrecheck.Stale("La base a changé depuis le plan (révision " + FrenchText.Integer(store.Revision) + ")" + FrenchText.Colon + "rien n’a été envoyé. Préparez de nouveau l’écriture.");
        }
        return WritePrecheck.Valid("Base relue" + FrenchText.Colon + Target(store).Name + ", révision " + FrenchText.Integer(store.Revision) + ", identité inchangée.");
    }

    /// <summary>Rows announced by the changes of a plan whose attributes start with <paramref name="prefix"/> (« retention. », « purge. »).</summary>
    public static ImmutableArray<(string Id, long Rows, DateTimeOffset? Cutoff)> PlannedRows(WritePlan plan, string prefix)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(prefix);
        var rows = ImmutableArray.CreateBuilder<(string, long, DateTimeOffset?)>();
        foreach (var change in plan.Changes.Where(c => c.Attribute.StartsWith(prefix, StringComparison.Ordinal)))
        {
            var raw = change.BeforeValue ?? "0";
            var at = raw.IndexOf('@', StringComparison.Ordinal);
            var count = long.Parse(at < 0 ? raw : raw[..at], CultureInfo.InvariantCulture);
            DateTimeOffset? cutoff = at < 0 ? null : DateTimeOffset.Parse(raw[(at + 1)..], CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
            rows.Add((change.Attribute[prefix.Length..], count, cutoff));
        }
        return rows.ToImmutable();
    }
}
