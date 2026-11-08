using System.Collections.Immutable;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// The fictitious local base of the simulation (docs/ops/parametres.md § 5): sizes, rows per table, measure families aged day
/// by day, backups with their annex, writer, maintenance, cached perimeters and the Domenia 1 data found for the takeover.
/// Derived once from the generated world and the « screen/settings » sub-stream of the seed, then kept in memory for the
/// session: the writes of Paramètres (backup, retention, purge, move, restore, resume, rollback, writer, takeover,
/// demonstration scenarios) change it, nothing is ever written on the disk and no SQLite base is ever opened
/// (SIMULATION.md § 1). One instance per source, shared by the reader and the executors.
/// </summary>
public sealed class SimulatedLocalStore
{
    private const int Days = 800;
    private static readonly ConditionalWeakTable<SimulatedDirectorySource, SimulatedLocalStore> Stores = new();

    private readonly SimulatedDirectorySource source;
    private readonly Lock gate = new();
    private State? state;
    private State? previous;

    private SimulatedLocalStore(SimulatedDirectorySource source) => this.source = source;

    /// <summary>The fictitious base of a source (created on first use, generated on first read).</summary>
    public static SimulatedLocalStore For(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        return Stores.GetValue(source, static s => new SimulatedLocalStore(s));
    }

    /// <summary>Clock and time zone of the simulation.</summary>
    internal TimeProvider Clock => source.Clock;

    internal TimeZoneInfo Zone => source.World.TimeZone;

    /// <summary>Current snapshot (generated now if needed).</summary>
    public LocalStoreSnapshot Snapshot()
    {
        lock (gate)
        {
            return Current().ToSnapshot();
        }
    }

    private State Current() => state ??= Generate();

    // ---------- Generation ----------

    private State Generate()
    {
        var world = source.World;
        var random = source.ScreenStream("settings");
        var directory = world.Directory;
        var reference = world.Reference;
        var domain = directory.Domain.DnsName;
        var path = @"%LOCALAPPDATA%\Domenia\Data\Domains\" + domain + @"\Domenia.db";
        var activeWorkstations = directory.Computers.Count(c => (c.UserAccountControl & AdValues.AccountDisabled) == 0);
        var s = new State
        {
            Domain = domain,
            Path = path,
            StoreId = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(path.ToLowerInvariant() + "\n" + directory.Domain.RootDn.ToLowerInvariant()))),
            Revision = 1284,
            Objects = directory.ObjectCount,
            Computers = directory.Computers.Length,
            ActiveComputers = activeWorkstations,
            Associations = 214,
            Queries = 12,
            Receipts = 1284,
            WalBytes = 4_300_800 + random.Fork("wal").Next(0, 1_800_000),
            LastWriteAt = reference - TimeSpan.FromMinutes(4),
            LastSavedAt = reference - TimeSpan.FromMinutes(4),
            VolumeBytes = 64_424_509_440L + random.Fork("volume").NextInt64(0, 8_589_934_592L),
            Snapshots = 24,
            ScanHistory = 3046,
            Runs = 1187,
            FleetSnapshots = 400,
            SessionCache = 48,
            DirectorySnapshots = 6,
            Secrets = directory.Computers.Count(c => c.Laps != LapsKind.None),
        };
        s.Families["presence"] = Ages(random.Fork("presence"), activeWorkstations * 0.85, 120, activeWorkstations * 0.12, 420);
        s.Families["console"] = Ages(random.Fork("console"), activeWorkstations * 0.38, 95, activeWorkstations * 0.05, 300);
        s.Families["inventory"] = Ages(random.Fork("inventory"), activeWorkstations / 7.0, 400, 0, 0);
        s.Families["probe"] = Ages(random.Fork("probe"), activeWorkstations * 6 / 30.0, 300, 0, 0);
        s.Families["detail"] = Ages(random.Fork("detail"), 41, 210, 0, 0);
        var history = Ages(random.Fork("history"), 18, 640, 0, 0);
        s.Families["linkHistory"] = history;
        var repeat = random.Fork("repeat");
        s.Repeated = [.. history.Select(v => (int)Math.Round(v * (0.66 + repeat.NextDouble() * 0.12)))];
        s.DatabaseBytes = s.ComputeBytes();
        s.Backups.AddRange(InitialBackups(s, random.Fork("backups"), reference, world.TimeZone));
        s.Scopes.AddRange(
        [
            new LocalStoreScope("OU Postes (sous-OU comprises)", "Lecture LDAP de l’annuaire fictif", world.Session.Controller?.DnsName ?? "", world.Session.Account.Login,
                directory.Computers.Count(c => c.DistinguishedName.EndsWith(",OU=Postes," + directory.Domain.RootDn, StringComparison.OrdinalIgnoreCase)), directory.ReadAt),
            new LocalStoreScope("Domaine " + domain + " · comptes et groupes", "Lecture LDAP de l’annuaire fictif", world.Session.Controller?.DnsName ?? "", world.Session.Account.Login,
                directory.Users.Length + directory.Groups.Length, directory.ReadAt - TimeSpan.FromHours(2)),
            new LocalStoreScope("OU Serveurs (sous-OU comprises)", "Lecture LDAP de l’annuaire fictif", world.Session.Controller?.DnsName ?? "", world.Session.Account.Login,
                directory.Computers.Count(c => c.DistinguishedName.EndsWith(",OU=Serveurs," + directory.Domain.RootDn, StringComparison.OrdinalIgnoreCase)), reference - TimeSpan.FromDays(3) - TimeSpan.FromHours(5)),
        ]);
        s.LegacyReadAt = reference - TimeSpan.FromMinutes(11);
        // The Domenia 1 base found next to the data folder, never taken over yet: part of it is already in Domenia 2 (the
        // index and the measures were read again since), the rest is taken by its rule.
        s.LegacyParts.AddRange(
        [
            new LegacyPart("objects", "Index des objets", "ad_objects", directory.ObjectCount - 37, 0, "emptyOnly"),
            new LegacyPart("measures", "Mesures des postes", "domenia_observations", 61_204, 0, "emptyOnly"),
            new LegacyPart("links", "Associations déclarées", "user_machine_links", 49, 12, "addMissing"),
            new LegacyPart("queries", "Requêtes enregistrées", "query_library", 12, 5, "addMissing"),
            new LegacyPart("receipts", "Reçus d’opérations terminés", "operation_receipts", 41, 0, "history"),
        ]);
        s.LegacySettings.AddRange(
        [
            new LegacyPart("favorites", "Favoris d’OU", "dashboard.ouFavorites", 6, 0, "addMissing"),
            new LegacyPart("layouts", "Dispositions de grilles", "grid.layouts", 9, 0, "addMissing"),
            new LegacyPart("collection", "Réglages de collecte", CollectionSettingsRules.PreferenceKey, 1, 0, "addMissing"),
        ]);
        return s;
    }

    /// <summary>Rows per age in days: about <paramref name="perDay"/> a day over <paramref name="recentDays"/>, then a thinner tail.</summary>
    private static int[] Ages(SeededRandom random, double perDay, int recentDays, double tailPerDay, int tailDays)
    {
        var cells = new int[Days];
        for (var day = 0; day < Days; day++)
        {
            var mean = day < recentDays ? perDay : day < recentDays + tailDays ? tailPerDay : 0;
            if (mean <= 0)
            {
                continue;
            }
            cells[day] = (int)Math.Round(mean * (0.82 + random.NextDouble() * 0.36));
        }
        return cells;
    }

    private static IEnumerable<LocalStoreBackup> InitialBackups(State s, SeededRandom random, DateTimeOffset reference, TimeZoneInfo zone)
    {
        (TimeSpan Age, string Kind, string Prefix)[] plan =
        [
            (TimeSpan.FromDays(38) + TimeSpan.FromHours(7), "migration", "Migration-schema11"),
            (TimeSpan.FromDays(13) + TimeSpan.FromHours(2), "manual", "Domenia"),
            (TimeSpan.FromDays(9) + TimeSpan.FromHours(6), "gesture", "Geste"),
            (TimeSpan.FromDays(8) + TimeSpan.FromHours(1), "manual", "Domenia"),
            (TimeSpan.FromDays(6) + TimeSpan.FromHours(3), "gesture", "Geste"),
            (TimeSpan.FromDays(4) + TimeSpan.FromHours(8), "manual", "Domenia"),
            (TimeSpan.FromDays(3) + TimeSpan.FromHours(4), "gesture", "Geste"),
            (TimeSpan.FromDays(1) + TimeSpan.FromHours(4), "gesture", "Geste"),
            (TimeSpan.FromHours(2) + TimeSpan.FromMinutes(13), "manual", "Domenia"),
        ];
        // The approved preferences of the fictitious session as they were joined to the copies made from the interface.
        var annex = """{"dashboard.disabledWidgets":[],"settings.storage":{"automaticBackup":false,"backupHours":24,"backupKeep":7,"presenceDays":30,"consoleDays":90,"inventoryDays":180,"probeDays":90,"detailDays":30,"linkHistoryDays":0}}""";
        foreach (var (age, kind, prefix) in plan)
        {
            var at = WritePlans.TruncateToSecond(reference - age - TimeSpan.FromSeconds(random.Next(0, 59)));
            var shrink = 1.0 - age.TotalDays * 0.004;
            var file = StorageWritePlans.BackupFileName(at, zone, prefix);
            var revision = s.Revision - (long)Math.Round(age.TotalDays * 11);
            var sha = Sha(file);
            yield return new LocalStoreBackup(
                Id(file),
                file,
                at,
                (long)(s.DatabaseBytes * shrink) / 4096 * 4096,
                sha,
                true,
                at + TimeSpan.FromSeconds(3),
                kind,
                revision,
                new LocalStoreCounts(s.Objects - (long)Math.Round(age.TotalDays * 0.6), (long)(s.MeasureRows * shrink), (long)(s.Families["detail"].Sum() * shrink),
                    s.Associations - (long)Math.Round(age.TotalDays / 4), s.Queries - (age.TotalDays > 20 ? 2 : 0), revision),
                at - TimeSpan.FromMinutes(7 + random.Next(0, 40)),
                // A migration copy is made by the takeover, not from the interface: no annex.
                kind == "migration" ? null : BackupPreferencesRules.Bind(annex, sha, at + TimeSpan.FromSeconds(3)));
        }
    }

    private static string Id(string seed) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("domenia.simulation.backup|" + seed)))[..32];

    private static string Sha(string seed) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("domenia.simulation.file|" + seed)));

    // ---------- Reads kept for the session ----------

    /// <summary>Usage measure and free space of the fictitious volume, kept for the session (read only: the base does not change).</summary>
    internal LocalStoreSnapshot Measure(DateTimeOffset now)
    {
        lock (gate)
        {
            var s = Current();
            s.SpaceFree = s.VolumeBytes - s.DatabaseBytes - s.WalBytes;
            s.SpaceAt = now;
            var categories = s.Categories();
            s.Usage = new LocalStoreUsage(now, s.DatabaseBytes, s.WalBytes, true, categories,
            [
                new LocalStoreReadProbe("directoryPage", Math.Min(100, s.Objects), 3.84, "SEARCH ad_objects USING INDEX ix_ad_objects_type (object_type=?)"),
                new LocalStoreReadProbe("activeMachines", s.Computers, 11.27, "SCAN ad_objects USING COVERING INDEX ix_ad_objects_name"),
                new LocalStoreReadProbe("familyPage", Math.Min(250, s.MeasureRows), 6.41, "SEARCH domenia_observations USING INDEX ix_observations_family (family=?)"),
                new LocalStoreReadProbe("textSearch", 37, 42.66, "SCAN domenia_directory_data"),
            ], 640);
            return s.ToSnapshot();
        }
    }

    /// <summary>Nine read-only checks of the fictitious base, kept for the session (a base proven unreadable fails its quick_check).</summary>
    internal LocalStoreSnapshot CheckIntegrity(DateTimeOffset now)
    {
        lock (gate)
        {
            var s = Current();
            s.Integrity = s.Recovery
                ? new LocalStoreIntegrity(now, 498, false,
                [
                    new LocalStoreCheck("open", "ok", "ouverture en lecture seule"),
                    new LocalStoreCheck("schema", "unknown", "non vérifié après le défaut"),
                    new LocalStoreCheck("tables", "unknown", "non vérifié après le défaut"),
                    new LocalStoreCheck("identity", "ok", s.Domain + ", identité cohérente avec son chemin"),
                    new LocalStoreCheck("redirect", "ok", "aucune bascule en attente"),
                    new LocalStoreCheck("receipts", "unknown", "non vérifié après le défaut"),
                    new LocalStoreCheck("foreignKeys", "unknown", "non vérifié après le défaut"),
                    new LocalStoreCheck("quickCheck", "failed", "SQLITE_CORRUPT (11) : page 4 812 illisible"),
                    new LocalStoreCheck("wal", "warning", SettingsFormat.Size(s.WalBytes) + ", point de contrôle impossible"),
                ])
                : new LocalStoreIntegrity(now, 512, true,
                [
                    new LocalStoreCheck("open", "ok", "ouverture en lecture seule"),
                    new LocalStoreCheck("schema", "ok", "schéma " + s.Schema),
                    new LocalStoreCheck("tables", "ok", "27 tables, colonnes attendues présentes"),
                    new LocalStoreCheck("identity", "ok", s.Domain + ", identité cohérente avec son chemin"),
                    new LocalStoreCheck("redirect", s.Locked ? "warning" : "ok", s.Locked ? "bascule à terminer" : "aucune bascule en attente"),
                    new LocalStoreCheck("receipts", "ok", FrenchText.Count(s.Revision, "lot", "lots") + ", empreintes vérifiées"),
                    new LocalStoreCheck("foreignKeys", "ok", "aucune référence orpheline"),
                    new LocalStoreCheck("quickCheck", "ok", "ok"),
                    new LocalStoreCheck("wal", "ok", SettingsFormat.Size(s.WalBytes) + ", point de contrôle passé"),
                ]);
            return s.ToSnapshot();
        }
    }

    // ---------- Writes of the simulation (executors of this assembly only) ----------

    /// <summary>
    /// Adds a verified backup (fictitious: no file) under the planned name, with its annex bound to its SHA-256 when one is
    /// given, and the rotation of the kinds in rotation.
    /// </summary>
    internal LocalStoreBackup AddBackup(string kind, DateTimeOffset now, int keep, string? annex, string prefix = "Domenia", string? fileName = null)
    {
        lock (gate)
        {
            return Current().AddBackup(kind, now, keep, annex, Zone, prefix, fileName);
        }
    }

    /// <summary>Records the publication of a backup to a chosen file (fictitious: nothing written).</summary>
    internal void AddExport(string destination, LocalStoreBackup backup)
    {
        lock (gate)
        {
            Current().Exports.Add(new LocalStoreExport(destination, backup.At, backup.Sha256, backup.Bytes, backup.Id));
        }
    }

    /// <summary>Removes the rows older than each planned cutoff (repeated observations only for the history), revision + 1.</summary>
    internal void ApplyRetention(IReadOnlyList<(string Family, long Rows, DateTimeOffset? Cutoff)> rows, DateTimeOffset now)
    {
        lock (gate)
        {
            var s = Current();
            foreach (var (family, _, cutoff) in rows)
            {
                if (cutoff is not DateTimeOffset at || !s.Families.TryGetValue(family, out var cells))
                {
                    continue;
                }
                var days = Math.Max(0, (int)Math.Ceiling((now - at).TotalDays - 0.0001));
                for (var n = days; n < cells.Length; n++)
                {
                    if (family == "linkHistory")
                    {
                        cells[n] -= s.Repeated[n];
                        s.Repeated[n] = 0;
                    }
                    else
                    {
                        cells[n] = 0;
                    }
                }
            }
            s.Wrote(now);
        }
    }

    /// <summary>Purges the planned categories (history older than its age only; declared associations kept), revision + 1.</summary>
    internal void ApplyPurge(IReadOnlyCollection<string> categories, int historyDays, DateTimeOffset now)
    {
        lock (gate)
        {
            var s = Current();
            foreach (var category in categories)
            {
                switch (category)
                {
                    case "observations":
                        foreach (var family in new[] { "presence", "console", "inventory", "probe", "detail" })
                        {
                            Array.Clear(s.Families[family]);
                        }
                        s.ParkRows = 0;
                        s.SessionCache = 0;
                        s.CollectionClocks = 0;
                        break;
                    case "snapshots":
                        s.Snapshots = 0;
                        break;
                    case "history":
                        var cells = s.Families["linkHistory"];
                        var total = cells.Sum(x => (long)x);
                        long older = 0;
                        for (var n = historyDays; n < cells.Length; n++)
                        {
                            older += cells[n];
                            cells[n] = 0;
                            s.Repeated[n] = 0;
                        }
                        var share = total > 0 ? older / (double)total : 0;
                        s.ScanHistory -= (long)Math.Round(s.ScanHistory * share);
                        s.Runs -= (long)Math.Round(s.Runs * share);
                        s.FleetSnapshots -= (long)Math.Round(s.FleetSnapshots * share);
                        break;
                    case "index":
                        s.Objects = 0;
                        s.Computers = 0;
                        s.DirectorySnapshots = 0;
                        s.DirectoryClock = 0;
                        s.Scopes.Clear();
                        break;
                }
            }
            s.Wrote(now);
        }
    }

    /// <summary>Moves the fictitious base: new path, original kept read only with a marker, return possible.</summary>
    internal void Move(string destination)
    {
        lock (gate)
        {
            var s = Current();
            previous = s.Clone();
            s.PreviousPath = s.Path;
            s.Path = destination;
            s.CanUndo = true;
        }
    }

    /// <summary>
    /// Restores a backup into a new fictitious file: counts and revision of the backup, return possible. A base proven
    /// unreadable is left for the restored one (its recovery ends here).
    /// </summary>
    internal void Restore(LocalStoreBackup backup, string file)
    {
        lock (gate)
        {
            var s = Current();
            previous = s.Clone();
            var ratio = s.MeasureRows > 0 && backup.Counts.Measures is long measures ? measures / (double)s.MeasureRows : 1;
            foreach (var family in new[] { "presence", "console", "inventory", "probe", "detail" })
            {
                var cells = s.Families[family];
                for (var n = 0; n < cells.Length; n++)
                {
                    cells[n] = (int)Math.Round(cells[n] * ratio);
                }
            }
            s.Objects = backup.Counts.Objects ?? s.Objects;
            s.Associations = backup.Counts.Associations ?? s.Associations;
            s.Queries = backup.Counts.Queries ?? s.Queries;
            s.Revision = backup.Revision;
            s.PreviousPath = s.Path;
            var folder = s.Path[..(s.Path.LastIndexOf('\\') + 1)];
            s.Path = folder + file;
            s.CanUndo = true;
            s.Recovery = false;
            s.Integrity = null;
            s.Locked = false;
            s.TargetPath = null;
        }
    }

    /// <summary>Ends an interrupted switch: the session goes to the verified copy named by the marker, return possible.</summary>
    internal bool ResumeSwitch()
    {
        lock (gate)
        {
            var s = Current();
            if (!s.Locked || string.IsNullOrEmpty(s.TargetPath))
            {
                return false;
            }
            previous = s.Clone();
            previous.Locked = false;
            previous.TargetPath = null;
            s.PreviousPath = s.Path;
            s.Path = s.TargetPath;
            s.Locked = false;
            s.TargetPath = null;
            s.CanUndo = true;
            return true;
        }
    }

    /// <summary>
    /// Back to the base before the switch of this session, or abandon of an interrupted switch (the marker is removed, the
    /// session stays on its base); refused by the plan when there is none or after a write.
    /// </summary>
    internal bool Rollback()
    {
        lock (gate)
        {
            if (state is { Locked: true })
            {
                state.Locked = false;
                state.TargetPath = null;
                state.PreviousPath = null;
                return true;
            }
            if (previous is null || state is null || !state.CanUndo)
            {
                return false;
            }
            var exports = state.Exports.ToList();
            var backups = state.Backups.ToList();
            state = previous;
            state.Exports.Clear();
            state.Exports.AddRange(exports);
            state.Backups.Clear();
            state.Backups.AddRange(backups);
            state.CanUndo = false;
            state.PreviousPath = null;
            previous = null;
            return true;
        }
    }

    /// <summary>Re-arms the suspended writer: what was in memory is saved (revision + 1), the failures are forgotten.</summary>
    internal bool ResumeWriter(DateTimeOffset now)
    {
        lock (gate)
        {
            var s = Current();
            if (!s.WriterSuspended)
            {
                return false;
            }
            s.WriterSuspended = false;
            s.WriterFailures = 0;
            s.WriterFault = null;
            s.WriterPending = 0;
            s.WriterQueuedChanges = 0;
            s.WriterQueuedBytes = 0;
            s.Wrote(now);
            return true;
        }
    }

    /// <summary>Takes over the Domenia 1 data by the steps of the plan (idempotent: the marker is set), revision + 1.</summary>
    internal long ImportLegacy(IReadOnlyCollection<LegacyStep> steps, string marker, DateTimeOffset now)
    {
        lock (gate)
        {
            var s = Current();
            long taken = 0;
            foreach (var step in steps.Where(st => st.Action is "import" or "add"))
            {
                taken += step.Rows;
                var id = step.Id.StartsWith("part.", StringComparison.Ordinal) ? step.Id["part.".Length..] : step.Id;
                if (id == "links")
                {
                    s.Associations += step.Rows;
                }
                else if (id == "queries")
                {
                    s.Queries += step.Rows;
                }
                else if (id == "receipts")
                {
                    s.Receipts += step.Rows;
                }
                for (var n = 0; n < s.LegacyParts.Count; n++)
                {
                    if (s.LegacyParts[n].Id == id)
                    {
                        s.LegacyParts[n] = s.LegacyParts[n] with { Present = s.LegacyParts[n].Rows };
                    }
                }
                for (var n = 0; n < s.LegacySettings.Count; n++)
                {
                    if (s.LegacySettings[n].Id == id)
                    {
                        s.LegacySettings[n] = s.LegacySettings[n] with { Present = s.LegacySettings[n].Rows };
                    }
                }
            }
            if (taken > 0)
            {
                s.LegacyAppliedMarker = marker;
                s.LegacyImportedAt = now;
                s.Wrote(now);
            }
            return taken;
        }
    }

    /// <summary>
    /// Puts the fictitious base in a demonstration state (« writerSuspended », « switchInterrupted », « storeUnreadable »,
    /// « lowSpace ») or back to « normal ». Only the simulation knows these states; nothing real changes.
    /// </summary>
    internal void Scenario(string scenario, DateTimeOffset now)
    {
        lock (gate)
        {
            var s = Current();
            // Every scenario starts from a sound base, then breaks one thing.
            s.WriterSuspended = false;
            s.WriterActive = false;
            s.WriterFailures = 0;
            s.WriterFault = null;
            s.WriterPending = 0;
            s.WriterQueuedChanges = 0;
            s.WriterQueuedBytes = 0;
            s.Recovery = false;
            if (s.Locked)
            {
                s.Locked = false;
                s.TargetPath = null;
                s.PreviousPath = null;
            }
            if (s.SpaceFree is long free && free < LocalStoreRules.SuspendReserve)
            {
                s.SpaceFree = s.VolumeBytes - s.DatabaseBytes - s.WalBytes;
                s.SpaceAt = now;
            }
            s.Integrity = null;
            switch (scenario)
            {
                case "writerSuspended":
                    s.WriterSuspended = true;
                    s.WriterFailures = 3;
                    s.WriterFault = "espace insuffisant pour le lot suivant (moins de 32 Mo libres plus quatre fois le lot)";
                    s.WriterPending = 14;
                    s.WriterQueuedChanges = 126;
                    s.WriterQueuedBytes = 431_104;
                    break;
                case "switchInterrupted":
                    s.Locked = true;
                    s.PreviousPath = s.Path;
                    s.TargetPath = s.Path[..(s.Path.LastIndexOf('\\') + 1)] + "Domenia-deplacee.db";
                    s.CanUndo = false;
                    break;
                case "storeUnreadable":
                    s.Recovery = true;
                    s.CanUndo = false;
                    break;
                case "lowSpace":
                    s.SpaceFree = 402_653_184;
                    s.SpaceAt = now;
                    break;
            }
        }
    }

    // ---------- Mutable state ----------

    private sealed class State
    {
        public string Domain { get; set; } = "";
        public string Path { get; set; } = "";
        public string StoreId { get; set; } = "";
        public long Revision { get; set; }
        public string Schema { get; } = "11 (révision 1)";
        public long Objects { get; set; }
        public long Computers { get; set; }
        public long ActiveComputers { get; set; }
        public long Associations { get; set; }
        public long Queries { get; set; }
        public long Receipts { get; set; }
        public long WalBytes { get; set; }
        public long DatabaseBytes { get; set; }
        public DateTimeOffset LastWriteAt { get; set; }
        public DateTimeOffset LastSavedAt { get; set; }
        public long VolumeBytes { get; set; }
        public long? SpaceFree { get; set; }
        public DateTimeOffset? SpaceAt { get; set; }
        public long Snapshots { get; set; }
        public long ScanHistory { get; set; }
        public long Runs { get; set; }
        public long FleetSnapshots { get; set; }
        public long SessionCache { get; set; }
        public long DirectorySnapshots { get; set; }
        public long CollectionClocks { get; set; } = 2;
        public long DirectoryClock { get; set; } = 1;
        public long? ParkRows { get; set; }
        public long Secrets { get; set; }
        public Dictionary<string, int[]> Families { get; private set; } = new(StringComparer.Ordinal);
        public int[] Repeated { get; set; } = [];
        public List<LocalStoreBackup> Backups { get; private set; } = [];
        public List<LocalStoreScope> Scopes { get; private set; } = [];
        public List<LegacyPart> LegacyParts { get; private set; } = [];
        public List<LegacyPart> LegacySettings { get; private set; } = [];
        public List<LocalStoreExport> Exports { get; private set; } = [];
        public DateTimeOffset? LegacyReadAt { get; set; }
        public DateTimeOffset? LegacyImportedAt { get; set; }
        public string? LegacyAppliedMarker { get; set; }
        public LocalStoreUsage? Usage { get; set; }
        public LocalStoreIntegrity? Integrity { get; set; }
        public bool Locked { get; set; }
        public string? TargetPath { get; set; }
        public bool Recovery { get; set; }
        public bool CanUndo { get; set; }
        public string? PreviousPath { get; set; }
        public bool WriterSuspended { get; set; }
        public bool WriterActive { get; set; }
        public int WriterPending { get; set; }
        public long WriterQueuedChanges { get; set; }
        public long WriterQueuedBytes { get; set; }
        public int WriterFailures { get; set; }
        public string? WriterFault { get; set; }

        public long MeasureRows => new[] { "presence", "console", "inventory", "probe" }.Sum(f => Families[f].Sum(x => (long)x));

        private long DetailRows => Families["detail"].Sum(x => (long)x);

        private long LinkHistoryRows => Families["linkHistory"].Sum(x => (long)x);

        private long LatestMeasureAge
        {
            get
            {
                for (var day = 0; day < Days; day++)
                {
                    if (new[] { "presence", "console", "inventory", "probe" }.Any(f => Families[f][day] > 0))
                    {
                        return day;
                    }
                }
                return -1;
            }
        }

        /// <summary>Rows per table (keys of <see cref="LocalStoreRules.PurgeTargets"/>), the categories adding them up.</summary>
        public ImmutableArray<LocalStoreTable> Tables()
        {
            var measures = MeasureRows;
            return
            [
                new("domenia_observations", measures),
                new("domenia_details", DetailRows),
                new("presence_cache", measures > 0 ? ActiveComputers : 0),
                new("park_state", ParkRows ?? Computers),
                new("park_session_cache", SessionCache),
                new("domenia_domain_metadata.collection", CollectionClocks),
                new("adcc_live_queries", Snapshots),
                new("user_machine_history", LinkHistoryRows),
                new("user_scan_history", ScanHistory),
                new("operation_runs", Runs),
                new("fleet_snapshots", FleetSnapshots),
                new("ad_objects", Objects),
                new("domenia_directory_data", Objects),
                new("ad_computer_facts", Computers),
                new("domenia_provenance", Objects),
                new("ad_snapshots", DirectorySnapshots),
                new("domenia_domain_metadata.directory", DirectoryClock),
                new("sync_state", 1),
                new("user_machine_links", Associations),
                new("secret_state", Secrets),
                new("query_library", Queries),
            ];
        }

        private long Sum(params string[] tables)
        {
            var rows = Tables().ToDictionary(t => t.Table, t => t.Rows, StringComparer.Ordinal);
            return tables.Sum(t => rows.GetValueOrDefault(t));
        }

        public ImmutableArray<LocalStoreCategory> Categories()
        {
            var observations = Sum("domenia_observations", "domenia_details", "presence_cache", "park_state", "park_session_cache", "domenia_domain_metadata.collection");
            var history = Sum("user_machine_history", "user_scan_history", "operation_runs", "fleet_snapshots");
            var index = Sum("ad_objects", "domenia_directory_data", "ad_computer_facts", "domenia_provenance", "ad_snapshots", "domenia_domain_metadata.directory");
            return
            [
                new("observations", LocalStoreRules.CategoryLabel("observations"), observations,
                    Families["presence"].Sum(x => (long)x) * 180 + Families["console"].Sum(x => (long)x) * 220 + Families["inventory"].Sum(x => (long)x) * 1400
                    + Families["probe"].Sum(x => (long)x) * 640 + DetailRows * 2600 + (observations - MeasureRows - DetailRows) * 320),
                new("snapshots", LocalStoreRules.CategoryLabel("snapshots"), Snapshots, Snapshots * 184_320),
                new("history", LocalStoreRules.CategoryLabel("history"), history, history * 160),
                new("index", LocalStoreRules.CategoryLabel("index"), index, index * 1900),
                new("manualLinks", LocalStoreRules.CategoryLabel("manualLinks"), Associations, Associations * 300),
                new("secrets", LocalStoreRules.CategoryLabel("secrets"), Secrets, Secrets * 400),
            ];
        }

        public long ComputeBytes()
        {
            var raw = Categories().Sum(c => c.Bytes ?? 0);
            return (long)(raw * 1.18) / 4096 * 4096 + 4096 * 64;
        }

        public void Wrote(DateTimeOffset now)
        {
            Revision++;
            LastWriteAt = now;
            LastSavedAt = now;
            // A write to the new base ends the possible return to the previous one (PAR-019).
            CanUndo = false;
            // The file never shrinks after a deletion: its size only grows with new data.
            DatabaseBytes = Math.Max(DatabaseBytes, ComputeBytes());
        }

        public LocalStoreBackup AddBackup(string kind, DateTimeOffset now, int keep, string? annex, TimeZoneInfo zone, string prefix, string? fileName)
        {
            var at = WritePlans.TruncateToSecond(now);
            var file = string.IsNullOrEmpty(fileName) ? StorageWritePlans.BackupFileName(at, zone, prefix) : fileName;
            if (Backups.Any(b => b.FileName == file))
            {
                file = file[..^3] + "-" + (Backups.Count + 1).ToString(CultureInfo.InvariantCulture) + ".db";
            }
            var revision = Revision.ToString(CultureInfo.InvariantCulture);
            var sha = Sha(file + "|" + revision);
            var age = LatestMeasureAge;
            var backup = new LocalStoreBackup(Id(file + "|" + revision), file, at, ComputeBytes(), sha, true, at + TimeSpan.FromSeconds(2), kind, Revision,
                new LocalStoreCounts(Objects, MeasureRows, DetailRows, Associations, Queries, Revision),
                age < 0 ? null : LastWriteAt - TimeSpan.FromDays(age),
                annex is null ? null : BackupPreferencesRules.Bind(annex, sha, at + TimeSpan.FromSeconds(2)));
            if (LocalStoreRules.InRotation(kind))
            {
                var rotation = Backups.Where(b => LocalStoreRules.InRotation(b.Kind)).OrderBy(b => b.At).ToList();
                while (rotation.Count >= keep && rotation.Count > 0)
                {
                    Backups.Remove(rotation[0]);
                    rotation.RemoveAt(0);
                }
            }
            Backups.Add(backup);
            return backup;
        }

        public State Clone()
        {
            var copy = (State)MemberwiseClone();
            copy.Families = Families.ToDictionary(p => p.Key, p => (int[])p.Value.Clone(), StringComparer.Ordinal);
            copy.Repeated = (int[])Repeated.Clone();
            copy.Backups = [.. Backups];
            copy.Scopes = [.. Scopes];
            copy.LegacyParts = [.. LegacyParts];
            copy.LegacySettings = [.. LegacySettings];
            copy.Exports = [.. Exports];
            return copy;
        }

        private LegacySource Legacy()
        {
            // Parts already held by Domenia 2: the « emptyOnly » tables of the base count their current rows.
            var parts = LegacyParts.Select(p => p.Rule == "emptyOnly" ? p with { Present = p.Target == "ad_objects" ? Objects : p.Target == "domenia_observations" ? MeasureRows : p.Present } : p).ToImmutableArray();
            var database = new LegacyDatabase("Domenia.db", @"%LOCALAPPDATA%\DOMENIA\Domenia.db (base de Domenia 1, fictive)", "11", "1", Domain, 91_226_112, parts);
            var tables = Tables().ToImmutableDictionary(t => t.Table, t => t.Rows, StringComparer.Ordinal);
            var marker = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("domenia.simulation.legacy|" + Domain + "|" + string.Join("|", LegacyParts.Select(p => p.Id + "=" + p.Rows.ToString(CultureInfo.InvariantCulture))))));
            return new LegacySource(true, @"%LOCALAPPDATA%\DOMENIA (Domenia 1, données fictives de la simulation)", Domain, LegacyReadAt, database, [.. LegacySettings], [], tables, marker, LegacyAppliedMarker, LegacyImportedAt);
        }

        public LocalStoreSnapshot ToSnapshot()
        {
            var families = Families.Select(p => new LocalStoreFamily(p.Key, [.. p.Value], p.Key == "linkHistory" ? [.. Repeated] : [])).OrderBy(f => f.Family, StringComparer.Ordinal).ToImmutableArray();
            return new LocalStoreSnapshot(
                true,
                true,
                Domain,
                Path,
                StoreId,
                Revision,
                Schema,
                DatabaseBytes,
                WalBytes,
                LastWriteAt,
                new LocalStoreCounts(Objects, MeasureRows, DetailRows, Associations, Queries, Receipts),
                Categories(),
                Tables(),
                families,
                [.. Backups],
                new LocalStoreSpace(SpaceFree, SpaceAt, WriterQueuedBytes),
                new LocalStoreWriter(false, WriterSuspended, WriterActive, WriterPending, WriterQueuedChanges, WriterQueuedBytes, WriterFailures, 0, LastSavedAt, WriterFault),
                new LocalStoreMaintenance(Locked, false, null, Recovery, false, TargetPath, CanUndo, PreviousPath),
                Usage,
                Integrity,
                [.. Scopes],
                Legacy(),
                [.. Exports],
                null,
                null);
        }
    }
}
