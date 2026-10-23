using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>Result of settings.storage.legacy.preview: the simulation of the takeover, before any confirmation.</summary>
public sealed record LegacyPreview(bool Found, string Location, string Domain, ImmutableArray<LegacyStep> Steps, ImmutableArray<string> Blockers, ImmutableArray<string> Lines, long WriteCount, string Fingerprint, bool NothingToDo);

/// <summary>
/// Builds the view of the local base (settings.storage) and the simulation of the Domenia 1 takeover from a snapshot, the
/// storage policy and the engine bounds. Pure.
/// </summary>
public static class StorageViewBuilder
{
    /// <summary>Fallback when no local store can be inspected in this mode.</summary>
    public const string DirectoryModeReason = "Aucune base locale disponible pour ce domaine. Les réglages restent enregistrés ; une première lecture explicite prépare la base.";

    /// <summary>View when the mode has no base (directory mode of this version).</summary>
    public static StorageView Unavailable(StoragePolicy policy, bool policyUnreadable, int maxConcurrent, int maxQueued, TimeZoneInfo zone) =>
        new(false, false, DirectoryModeReason, null, [], "", 0, "", null, null, null, [], null, policy, policyUnreadable, Retention(policy),
            LocalStoreRules.Limits(policy, maxConcurrent, maxQueued, null, null, zone), null, null, [], LocalStoreRules.NeverPurged, [], null, [], "normal", null, null);

    /// <summary>Retention families of a policy, as the editor shows them.</summary>
    public static ImmutableArray<RetentionFamilyView> Retention(StoragePolicy policy)
    {
        ArgumentNullException.ThrowIfNull(policy);
        return
        [
            .. StoragePolicyRules.Families.Select(f =>
            {
                var days = StoragePolicyRules.DaysOf(policy, f.Family);
                return new RetentionFamilyView(f.Family, f.PolicyKey, f.Label, days, SettingsFormat.Days(days), f.Compaction, f.Loss);
            }),
        ];
    }

    /// <summary>
    /// The whole view of the local base. <paramref name="lastAttempt"/> and <paramref name="lastFailure"/> come from the automatic
    /// backup of this session (its last try and why it failed), when it ran.
    /// </summary>
    public static StorageView Build(LocalStoreSnapshot store, StoragePolicy policy, bool policyUnreadable, int maxConcurrent, int maxQueued, DateTimeOffset now, TimeZoneInfo zone, string? path,
        DateTimeOffset? lastAttempt = null, string? lastFailure = null, DateTimeOffset? lastFailureAt = null)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(zone);
        if (!store.Available)
        {
            return Unavailable(policy, policyUnreadable, maxConcurrent, maxQueued, zone) with
            {
                UnavailableReason = store.LastFailure ?? "Aucune base locale créée pour ce domaine. Une première lecture explicite prépare la base.",
                Integrity = store.Integrity is null ? null : LocalStoreRules.Integrity(store.Integrity, zone),
                Maintenance = LocalStoreRules.Maintenance(store),
                Backups = LocalStoreRules.Backups(store),
                Legacy = Legacy(store.Legacy, store.Domain, zone),
            };
        }
        var lastVerified = store.Backups.Where(StoragePolicyRules.IsVerified).OrderByDescending(b => b.At).FirstOrDefault();
        var space = LocalStoreRules.Space(store.Space, now, zone);
        var writer = LocalStoreRules.Writer(store.Writer, now);
        var usage = store.Usage is null ? null : LocalStoreRules.Usage(store.Usage);
        var busy = BackupBusy(store);
        var failureAt = lastFailureAt ?? store.LastFailureAt;
        var schedule = StoragePolicyRules.Schedule(policy, lastVerified, lastAttempt ?? store.LastFailureAt, lastFailure ?? store.LastFailure, failureAt, busy, now, zone);
        var measures = store.Counts.Measures;
        var tiles = ImmutableArray.Create(
            new StorageTile("objects", "Objets de l’annuaire", store.Counts.Objects is long o ? FrenchText.Integer(o) : "—", "index local", Tone.Info),
            new StorageTile("measures", "Mesures des postes", measures is long m ? FrenchText.Integer(m) : "—", FrenchText.Count(store.Counts.Details ?? 0, "détail", "détails"), Tone.Info),
            new StorageTile("backups", "Sauvegardes vérifiées", FrenchText.Integer(store.Backups.Count(StoragePolicyRules.IsVerified)),
                lastVerified is null ? "aucune" : "dernière " + SettingsFormat.Elapsed(lastVerified.At, now), lastVerified is null ? Tone.Warn : (now - lastVerified.At).TotalDays > 7 ? Tone.Warn : Tone.Ok),
            new StorageTile("space", "Espace libre du volume", space.FreeBytes is null ? "—" : space.FreeText, space.FreeBytes is null ? "non mesuré : « Mesurer » dans Diagnostic" : space.Label, space.Tone));
        return new StorageView(
            true,
            store.Simulated,
            null,
            LocalStoreRules.Location(store, lastVerified?.At, now, path),
            tiles,
            LocalStoreRules.Content(store.Counts),
            store.Revision,
            store.Schema,
            space,
            writer,
            LocalStoreRules.Maintenance(store),
            LocalStoreRules.Backups(store),
            schedule,
            policy,
            policyUnreadable,
            Retention(policy),
            LocalStoreRules.Limits(policy, maxConcurrent, maxQueued, store.Usage, space, zone),
            usage,
            store.Integrity is null ? null : LocalStoreRules.Integrity(store.Integrity, zone),
            LocalStoreRules.PurgeView(store),
            LocalStoreRules.NeverPurged,
            LocalStoreRules.Catalog(store.Scopes, now, zone),
            Legacy(store.Legacy, store.Domain, zone),
            store.Exports,
            StorageWritePlans.ScenarioOf(store),
            StorageWritePlans.ExportFileName(now, zone),
            BackupFolder(store.PathLabel));
    }

    /// <summary>The automatic backup waits while an operation or a local save is under way (Test-DomeniaStorageBackupBusy).</summary>
    public static bool BackupBusy(LocalStoreSnapshot store)
    {
        ArgumentNullException.ThrowIfNull(store);
        return store.Writer.Pending > 0 || store.Writer.Active || store.Maintenance.Draining || !string.IsNullOrEmpty(store.Maintenance.Job);
    }

    /// <summary>« …\Domains\example.local\Backups » for a base « …\Domains\example.local\Domenia.db ».</summary>
    public static string? BackupFolder(string? pathLabel)
    {
        if (string.IsNullOrWhiteSpace(pathLabel))
        {
            return null;
        }
        var at = pathLabel.LastIndexOf('\\');
        return at <= 0 ? null : pathLabel[..at] + "\\Backups";
    }

    /// <summary>State of the takeover of the Domenia 1 data for the domain of the session.</summary>
    public static LegacyView Legacy(LegacySource legacy, string domain, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(legacy);
        ArgumentNullException.ThrowIfNull(domain);
        ArgumentNullException.ThrowIfNull(zone);
        var plan = LegacyRules.Plan(legacy, domain);
        var files = LegacyRules.Files(legacy);
        if (!legacy.Found)
        {
            return new LegacyView("none", Tone.Off, "Aucune donnée de Domenia 1 trouvée sur ce poste.", legacy.Location, null, files, [], [], LegacyRules.Guards, 0, null);
        }
        if (plan.Already)
        {
            return new LegacyView("imported", Tone.Ok,
                "Données de Domenia 1 déjà reprises" + (legacy.ImportedAt is DateTimeOffset at ? " le " + SettingsFormat.LocalDate(at, zone) : "") + " ; la reprise est idempotente.",
                legacy.Location, legacy.Database, files, plan.Steps, plan.Blockers, LegacyRules.Guards, 0, legacy.ImportedAt);
        }
        if (plan.Blockers.Length > 0)
        {
            return new LegacyView("blocked", Tone.Warn,
                "Reprise des données de Domenia 1 bloquée" + FrenchText.Colon + FrenchText.Count(plan.Blockers.Length, "blocage", "blocages") + ", rien ne sera écrit. La simulation dit pourquoi.",
                legacy.Location, legacy.Database, files, plan.Steps, plan.Blockers, LegacyRules.Guards, 0, legacy.ImportedAt);
        }
        if (plan.WriteCount == 0)
        {
            return new LegacyView("nothing", Tone.Ok, "Données de Domenia 1 trouvées" + FrenchText.Colon + "tout est déjà présent dans Domenia 2, rien à ajouter.",
                legacy.Location, legacy.Database, files, plan.Steps, plan.Blockers, LegacyRules.Guards, 0, legacy.ImportedAt);
        }
        var taken = plan.Steps.Where(st => st.Action is "import" or "add").Select(st => FrenchText.Integer(st.Rows) + " " + st.Label.ToLowerInvariant());
        return new LegacyView("available", Tone.Info,
            "Données de Domenia 1 trouvées pour " + legacy.Domain + FrenchText.Colon + string.Join(", ", taken) + ". Simulez la reprise avant de confirmer.",
            legacy.Location, legacy.Database, files, plan.Steps, plan.Blockers, LegacyRules.Guards, plan.WriteCount, legacy.ImportedAt);
    }

    /// <summary>
    /// Simulation of the takeover (PAR-028): what would be taken, what is refused and why, and the fingerprint the plan
    /// requires. The fingerprint binds the markers, every step, the identity of the base and its revision.
    /// </summary>
    public static LegacyPreview LegacySimulation(LocalStoreSnapshot store, string domain, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(domain);
        ArgumentNullException.ThrowIfNull(zone);
        var legacy = store.Legacy;
        var plan = LegacyRules.Plan(legacy, domain);
        var lines = new List<string>(plan.Lines);
        if (legacy.Found && legacy.ReadAt is DateTimeOffset read)
        {
            lines.Insert(0, "Sources lues le " + SettingsFormat.LocalDate(read, zone) + " dans " + legacy.Location + ", domaine " + legacy.Domain + ".");
        }
        if (plan.Blockers.Length > 0)
        {
            lines.Add("Blocages" + FrenchText.Colon + string.Join(" ", plan.Blockers) + " Aucune reprise proposée.");
        }
        else if (plan.WriteCount > 0)
        {
            lines.Add("À reprendre" + FrenchText.Colon + FrenchText.Count(plan.WriteCount, "ligne", "lignes") + " ; associations existantes conservées.");
        }
        var parts = new List<string> { "marker=" + legacy.Marker, "applied=" + (legacy.AppliedMarker ?? ""), "domain=" + domain.ToLowerInvariant() };
        parts.AddRange(plan.Steps.Select(st => st.Id + "=" + st.Action + ":" + st.Rows.ToString(CultureInfo.InvariantCulture)));
        parts.AddRange(plan.Blockers.Select(b => "blocker=" + b));
        var fingerprint = StoragePolicyRules.Fingerprint("legacy", store, parts);
        return new LegacyPreview(legacy.Found, legacy.Location, legacy.Domain, plan.Steps, plan.Blockers, [.. lines], plan.WriteCount, fingerprint, !plan.Allowed);
    }
}
