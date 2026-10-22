using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>Result of settings.storage.legacy.preview: the simulation of the takeover, before any confirmation.</summary>
public sealed record LegacyPreview(bool Found, string Location, string Domain, ImmutableArray<LegacyItem> Items, ImmutableArray<string> Lines, ImmutableArray<string> Refusals, string Fingerprint, bool NothingToDo);

/// <summary>
/// Builds the view of the local base (settings.storage) and the simulation of the Domenia 1 takeover from a snapshot, the
/// storage policy and the engine bounds. Pure.
/// </summary>
public static class StorageViewBuilder
{
    /// <summary>Why the base is unavailable in directory mode while Domenia.Store has no SQLite base yet (wave 3).</summary>
    public const string DirectoryModeReason = "Base locale de Domenia 2 pas encore branchée dans cette version" + FrenchText.Nbsp + ": rien n’est lu ni écrit. Les réglages de conservation et de sauvegarde restent enregistrés et s’appliqueront à la base dès qu’elle existera.";

    /// <summary>View when the mode has no base (directory mode of this version).</summary>
    public static StorageView Unavailable(StoragePolicy policy, bool policyUnreadable, int maxConcurrent, int maxQueued, TimeZoneInfo zone) =>
        new(false, false, DirectoryModeReason, null, [], "", 0, "", null, null, null, [], null, policy, policyUnreadable, Retention(policy),
            LocalStoreRules.Limits(policy, maxConcurrent, maxQueued, null, null, zone), null, null, [], LocalStoreRules.NeverPurged, [], null, []);

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

    /// <summary>The whole view of the local base.</summary>
    public static StorageView Build(LocalStoreSnapshot store, StoragePolicy policy, bool policyUnreadable, int maxConcurrent, int maxQueued, DateTimeOffset now, TimeZoneInfo zone, string? path)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(zone);
        if (!store.Available)
        {
            return Unavailable(policy, policyUnreadable, maxConcurrent, maxQueued, zone);
        }
        var lastVerified = store.Backups.Where(StoragePolicyRules.IsVerified).OrderByDescending(b => b.At).FirstOrDefault();
        var space = LocalStoreRules.Space(store.Space, now, zone);
        var writer = LocalStoreRules.Writer(store.Writer, now);
        var usage = store.Usage is null ? null : LocalStoreRules.Usage(store.Usage);
        var busy = store.Writer.Pending > 0 || store.Maintenance.Draining || !string.IsNullOrEmpty(store.Maintenance.Job);
        var schedule = StoragePolicyRules.Schedule(policy, lastVerified, store.LastFailureAt, store.LastFailure, store.LastFailureAt, busy, now, zone);
        var measures = store.Counts.Measures;
        var tiles = ImmutableArray.Create(
            new StorageTile("objects", "Objets de l’annuaire", store.Counts.Objects is long o ? FrenchText.Integer(o) : "—", "index local", Tone.Info),
            new StorageTile("measures", "Mesures des postes", measures is long m ? FrenchText.Integer(m) : "—", FrenchText.Count(store.Counts.Details ?? 0, "détail", "détails"), Tone.Info),
            new StorageTile("backups", "Sauvegardes vérifiées", FrenchText.Integer(store.Backups.Count(StoragePolicyRules.IsVerified)),
                lastVerified is null ? "aucune" : "dernière " + SettingsFormat.Elapsed(lastVerified.At, now), lastVerified is null ? Tone.Warn : (now - lastVerified.At).TotalDays > 7 ? Tone.Warn : Tone.Ok),
            new StorageTile("space", "Espace libre du volume", space.FreeBytes is null ? "—" : space.FreeText, space.FreeBytes is null ? "non mesuré : « Mesurer » dans Diagnostic" : space.Label, space.Tone));
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
            Legacy(store.Legacy, zone),
            store.Exports);
    }

    /// <summary>State of the takeover of the Domenia 1 data.</summary>
    public static LegacyView Legacy(LegacySource legacy, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(legacy);
        ArgumentNullException.ThrowIfNull(zone);
        if (!legacy.Found)
        {
            return new LegacyView("none", Tone.Off, "Aucune donnée de Domenia 1 trouvée sur ce poste.", legacy.Location, [], null, legacy.Refusals);
        }
        if (legacy.Items.All(i => i.Imported || i.Count == 0))
        {
            return new LegacyView("imported", Tone.Ok,
                "Données de Domenia 1 déjà reprises" + (legacy.ImportedAt is DateTimeOffset at ? " le " + SettingsFormat.LocalDate(at, zone) : "") + " ; la reprise est idempotente.",
                legacy.Location, legacy.Items, legacy.ImportedAt, legacy.Refusals);
        }
        var pending = legacy.Items.Where(i => !i.Imported && i.Count > 0).ToList();
        return new LegacyView("available", Tone.Info,
            "Données de Domenia 1 trouvées pour " + legacy.Domain + FrenchText.Colon + string.Join(", ", pending.Select(i => FrenchText.Integer(i.Count) + " " + i.Label.ToLowerInvariant())) + ". Simulez la reprise avant de confirmer.",
            legacy.Location, legacy.Items, legacy.ImportedAt, legacy.Refusals);
    }

    /// <summary>
    /// Simulation of the takeover (PAR-028): what would be taken, what is refused, and the fingerprint the plan requires.
    /// Nothing is read twice in a different state: the fingerprint binds the counts, the base identity and its revision.
    /// </summary>
    public static LegacyPreview LegacySimulation(LocalStoreSnapshot store, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(zone);
        var legacy = store.Legacy;
        var lines = new List<string>();
        if (!legacy.Found)
        {
            lines.Add("Aucune donnée de Domenia 1 trouvée sur ce poste" + FrenchText.Colon + "rien à reprendre.");
        }
        else
        {
            lines.Add("Source" + FrenchText.Colon + legacy.Location + (legacy.ReadAt is DateTimeOffset read ? " (lue le " + SettingsFormat.LocalDate(read, zone) + ")" : "") + ", domaine " + legacy.Domain + ".");
            foreach (var item in legacy.Items)
            {
                lines.Add(item.Label + FrenchText.Colon + (item.Imported ? "déjà repris" : item.Count == 0 ? "rien à reprendre" : FrenchText.Integer(item.Count) + " à reprendre") + (item.Detail.Length > 0 ? " (" + item.Detail + ")" : "") + ".");
            }
            lines.Add("Une sauvegarde de migration de la base est faite juste avant, hors rotation ; les fichiers de Domenia 1 restent en place.");
            lines.Add("Les associations existantes ne sont jamais remplacées, les doublons sont refusés et la colonne de détail libre n’est jamais reprise.");
        }
        var fingerprint = StoragePolicyRules.Fingerprint("legacy", store, legacy.Items.Select(i => i.Id + "=" + i.Count.ToString(CultureInfo.InvariantCulture) + (i.Imported ? ":fait" : "")));
        var nothing = !legacy.Found || legacy.Refusals.Length > 0 || legacy.Items.All(i => i.Imported || i.Count == 0);
        return new LegacyPreview(legacy.Found, legacy.Location, legacy.Domain, legacy.Items, [.. lines], legacy.Refusals, fingerprint, nothing);
    }
}
