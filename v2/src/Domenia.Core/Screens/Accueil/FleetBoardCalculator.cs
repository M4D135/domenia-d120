using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Accueil;

/// <summary>
/// The fleet board of Domenia 1 (Domenia-BoardFleet.Model.ps1, Get-DomeniaFleetBoardData, with the health rules of
/// Domenia-HealthRules.Model.ps1 and Domenia-Boards.Model.ps1): every widget of the catalog, the points of attention, the
/// health score with its coverage, the exact set of workstations of every figure, the daily snapshot figures and their
/// fingerprints, the explanation of the score. Pure: same input, same result.
/// </summary>
public static class FleetBoardCalculator
{
    public const int FormatVersion = 3;
    public const int MinimumCoveragePercent = 50;

    private static readonly string[] BucketNames = ["0 à 6 j", "7 à 29 j", "30 à 89 j", "90 à 179 j", "180 j et plus", "non renseignée"];
    private static readonly string[] RamNames = ["≤" + FrenchText.Nbsp + "4 Go", "5 à 8 Go", "9 à 16 Go", "17 à 32 Go", ">" + FrenchText.Nbsp + "32 Go"];
    private static readonly string[] PresenceNames = ["En ligne", "Sans réponse", "Non vérifié"];
    private static readonly string[] WmiNames = ["WMI a répondu", "WMI non confirmé", "WMI non relevé"];
    private static readonly string[] ReachNames = ["Ping et WMI répondent", "WMI répond, pas le ping", "Ping répond, WMI non confirmé", "Ni ping ni WMI", "Un seul canal relevé", "Aucun relevé"];
    private static readonly string[] KindNames = ["Postes de travail", "Serveurs", "Système non renseigné"];

    /// <summary>Rules of the catalog evaluated on the fleet and taking part in the score.</summary>
    public static ImmutableArray<string> ScoredRules { get; } = ["eos.ended", "eos.soon", "stale", "never", "pwdold", "laps.none", "laps.expired", "bitlocker.none", "lowdisk", "disk.tight", "uptime"];

    private static readonly string[] DirectoryRules = ["stale", "never", "pwdold", "laps.none", "laps.expired", "ad.disabled", "eos.ended", "eos.soon", "bitlocker.none"];

    public static FleetComputation Compute(FleetBoardInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        var context = new Context(input);
        return context.Run();
    }

    // ---------------------------------------------------------------- one calculation

    private sealed class Machine
    {
        public required DirectoryComputer Computer { get; init; }
        public Guid Guid => Computer.ObjectGuid;
        public string Name => Computer.Name;
        public string Dn => Computer.DistinguishedName;
        public required string Parent { get; init; }
        public required bool Enabled { get; init; }
        public required string Os { get; init; }
        public required bool OsKnown { get; init; }
        public required WindowsLifecycleInfo Release { get; init; }
        public required string VersionLabel { get; init; }
        public required string Kind { get; init; }
        public required DateOnly? Logon { get; init; }
        public required int Bucket { get; init; }
        public required bool Created { get; init; }
        public required DateTimeOffset? PasswordSet { get; init; }
        public required char Laps { get; init; }
        public required char BitLocker { get; init; }
        public required string Site { get; init; }
        public required HealthPolicy Policy { get; init; }
        public required string PolicyScope { get; init; }
        public string Presence { get; set; } = "Non vérifié";
        public DateTimeOffset? PingAt { get; set; }
        public MeasureState Wmi { get; set; } = MeasureState.Absent;
        public DateTimeOffset? WmiAt { get; set; }
        public string Reach { get; set; } = "Aucun relevé";
        public bool Inventory { get; set; }
        public DateTimeOffset? InventoryAt { get; set; }
        public string? Model { get; set; }
        public string? Ram { get; set; }
        public double? DiskFree { get; set; }
        public double? UptimeDays { get; set; }
        public string? InventoryRelease { get; set; }
        public string? Bios { get; set; }
        public string? User { get; set; }
    }

    private sealed class RuleHits
    {
        public List<Guid> Active { get; } = [];
        public List<Guid> Masked { get; } = [];
    }

    private sealed class Context(FleetBoardInput input)
    {
        private readonly DateTimeOffset now = input.Now;
        private readonly TimeZoneInfo zone = input.Zone;
        private readonly DateOnly today = LocalDays.DateOf(input.Now, input.Zone);
        private readonly Dictionary<string, (HealthPolicy Policy, string Source)> policies = new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, List<Guid>> targets = new(StringComparer.Ordinal);
        private readonly Dictionary<string, string> labels = new(StringComparer.Ordinal);
        private readonly Dictionary<string, FleetEntry> entries = new(StringComparer.Ordinal);
        private readonly List<FleetHint> hints = [];
        private HealthPolicy boardPolicy = HealthPolicy.Default;

        public FleetComputation Run()
        {
            var scope = input.Scope;
            var directory = input.State.Directory;
            boardPolicy = HealthRules.Resolve(input.Book, ScopeRules.IsDomainRoot(scope, input.DomainDn) ? "" : scope.Dn).Policy;
            var limits = boardPolicy.Thresholds;
            var observations = new Dictionary<Guid, WorkstationObservation>();
            foreach (var o in input.State.Observations.Workstations)
            {
                observations.TryAdd(o.ComputerGuid, o);
            }
            var machines = directory.Computers.Where(c => ScopeRules.Contains(scope, c.DistinguishedName)).Select(Build).ToList();
            var active = machines.Where(m => m.Enabled).ToList();
            var byGuid = active.ToDictionary(m => m.Guid);
            var disabledMachines = machines.Where(m => !m.Enabled).ToList();
            foreach (var m in active)
            {
                Observe(m, observations.GetValueOrDefault(m.Guid));
            }

            // ---------------------------------------------------------------- directory aggregates
            var total = active.Count;
            var machineCount = machines.Count;
            var lapsVisible = active.Any(m => m.Laps is 'O' or 'E');
            var bitlockerVisible = active.Any(m => m.BitLocker == 'K');
            var staleMachines = active.Where(m => m.Logon is DateOnly d && d <= today.AddDays(-limits.StaleDays)).ToList();
            var activityUnknown = active.Count(m => m.Logon is null);
            var ended = active.Where(m => m.Release.Status == LifecycleStatus.Ended).ToList();
            var soon = active.Where(m => m.Release.Status == LifecycleStatus.Soon).ToList();
            var windows10 = active.Where(IsWindows10).ToList();
            var created = active.Where(m => m.Created).ToList();
            var pwdOld = active.Where(m => m.PasswordSet is DateTimeOffset p && p < now - TimeSpan.FromDays(limits.PasswordDays)).ToList();
            var factsKnown = active.Count(m => m.PasswordSet is not null);

            Set("fleet.machines", machines);
            Set("fleet.enabled", active);
            Set("fleet.disabled", disabledMachines);
            Set("fleet.accountunknown", []);
            Set("fleet.accountstatus", machines);
            Set("fleet.accountstatus|Activés", active);
            Set("fleet.accountstatus|Désactivés", disabledMachines);
            Set("fleet.accountstatus|État inconnu", []);
            Set("fleet.stale", staleMachines);
            Set("fleet.created", created);
            Set("fleet.pwdold", pwdOld);
            Set("fleet.laps", active.Where(m => lapsVisible && m.Laps == 'N'));
            Set("fleet.bitlocker", active.Where(m => bitlockerVisible && m.BitLocker == 'N'));
            Set("fleet.eos", ended);
            Set("fleet.win10", windows10);
            Set("fleet.versions", active);
            Set("fleet.os", active);
            Set("fleet.servers", active);
            Set("fleet.lastlogon", active);
            Set("fleet.ou", active);
            Set("fleet.presence", active);
            Set("fleet.wmi", active);
            Set("fleet.reach", active);
            foreach (var m in active)
            {
                Add("fleet.versions|" + m.VersionLabel, m);
                Add("fleet.os|" + m.Os, m);
                Add("fleet.servers|" + m.Kind, m);
                Add("fleet.lastlogon|" + BucketNames[m.Bucket], m);
                Add("fleet.ou|" + m.Site, m);
                Add("fleet.presence|" + m.Presence, m);
                Add("fleet.wmi|" + WmiGroup(m.Wmi), m);
                Add("fleet.reach|" + m.Reach, m);
            }

            var machineDetail = FrenchText.Integer(total) + " activés · " + FrenchText.Integer(disabledMachines.Count) + " désactivés · 0 état inconnu · "
                + (ScopeRules.IsDomainRoot(scope, input.DomainDn) ? "domaine" : scope.Subtree ? "OU et sous-OU" : "OU directe");
            Entry("fleet.machines", FrenchText.Integer(machineCount), machineCount, null, machineDetail, null, targetsKey: "fleet.machines");
            Entry("fleet.enabled", FrenchText.Integer(total), total, null, "Comptes AD activés ; ce nombre ne décrit pas la présence réseau.", null, targetsKey: "fleet.enabled");
            Entry("fleet.accountunknown", "0", 0, null, "État du compte AD non lu ; ne vaut ni activé ni désactivé.", null, targetsKey: "fleet.accountunknown");
            Distribution("fleet.accountstatus", FrenchText.Integer(machineCount), machineDetail, [("Activés", total, Tone.Ok), ("Désactivés", disabledMachines.Count, Tone.Off), ("État inconnu", 0, Tone.Info)],
                FrenchText.Count(machineCount, "compte", "comptes"), keepEmpty: true);
            Entry("fleet.stale", FrenchText.Integer(staleMachines.Count), staleMachines.Count, null,
                "lastLogonTimestamp approximatif ; " + FrenchText.Count(activityUnknown, "date inconnue", "dates inconnues") + ", sans rapport avec le ping.",
                staleMachines.Count > 0 ? Tone.Warn : Tone.Ok, title: "Sans connexion AD depuis " + FrenchText.Integer(limits.StaleDays) + " j", targetsKey: "fleet.stale");
            var kindItems = KindNames.Select(k => (k, active.Count(m => m.Kind == k), (Tone?)null)).ToList();
            var servers = active.Count(m => m.Kind == "Serveurs");
            Distribution("fleet.servers", FrenchText.Count(servers, "serveur", "serveurs"),
                FrenchText.Count(active.Count(m => m.Kind == "Postes de travail"), "poste de travail", "postes de travail") + " sur " + FrenchText.Count(total, "compte actif", "comptes actifs"),
                kindItems, FrenchText.Count(total, "compte", "comptes"));
            Entry("fleet.disabled", FrenchText.Integer(disabledMachines.Count), disabledMachines.Count, null,
                disabledMachines.Count > 0 ? "Désactivés, encore dans le périmètre." : "Aucun compte désactivé dans le périmètre.",
                disabledMachines.Count > 0 ? Tone.Warn : Tone.Ok, targetsKey: "fleet.disabled");
            if (factsKnown == 0 && total > 0)
            {
                Entry("fleet.created", "Non lu", null, null, "Non lu : mettez à jour la base locale de l’OU pour lire cet attribut.", Tone.Off, measured: false);
                Entry("fleet.pwdold", "Non lu", null, null, "Non lu : mettez à jour la base locale de l’OU pour lire cet attribut.", Tone.Off, measured: false);
            }
            else
            {
                Entry("fleet.created", FrenchText.Integer(created.Count), created.Count, null, "Lu avec la base pour " + FrenchText.Count(factsKnown, "poste", "postes") + " sur " + FrenchText.Integer(total) + ".", null, targetsKey: "fleet.created");
                Entry("fleet.pwdold", FrenchText.Integer(pwdOld.Count), pwdOld.Count, null, "Lu avec la base pour " + FrenchText.Count(factsKnown, "poste", "postes") + " sur " + FrenchText.Integer(total) + ".",
                    pwdOld.Count > 0 ? Tone.Warn : Tone.Ok, title: "Mot de passe machine de plus de " + FrenchText.Integer(limits.PasswordDays) + " j", targetsKey: "fleet.pwdold");
            }

            // Security: LAPS read with the base, BitLocker read on request for the OU (never the domain root).
            var lapsCount = active.Count(m => m.Laps is 'O' or 'E');
            var lapsMissing = active.Count(m => m.Laps == 'N');
            var lapsExpired = active.Count(m => m.Laps == 'E');
            if (total == 0 || active.All(m => m.Laps == ' '))
            {
                Entry("fleet.laps", "Non lu", null, null, "Non lu : mettez à jour la base locale de l’OU pour lire cet attribut.", Tone.Off, measured: false);
            }
            else if (lapsCount + lapsMissing == 0)
            {
                Entry("fleet.laps", "Non disponible", null, null, "Non disponible dans ce domaine : attributs LAPS absents du schéma.", Tone.Off, measured: false);
            }
            else if (lapsCount == 0)
            {
                Entry("fleet.laps", "Non déterminé", null, null, "Aucune expiration LAPS visible avec ce compte sur " + FrenchText.Count(total, "poste", "postes") + " (droits ou LAPS non déployé).", Tone.Off, measured: false);
            }
            else
            {
                Entry("fleet.laps", FrenchText.Integer(lapsMissing), lapsMissing, null,
                    FrenchText.Count(lapsCount, "poste avec expiration visible", "postes avec expiration visible") + (lapsExpired > 0 ? ", dont " + FrenchText.Count(lapsExpired, "expirée", "expirées") : "") + " sur " + FrenchText.Integer(total) + ".",
                    lapsMissing > 0 || lapsExpired > 0 ? Tone.Warn : Tone.Ok, targetsKey: "fleet.laps");
            }
            var isRoot = ScopeRules.IsDomainRoot(scope, input.DomainDn);
            var bitlockerAction = isRoot ? null : new FleetAction("bitlocker", "Lire la présence des clés BitLocker de cette OU", "Recherche paginée des objets de récupération de l’OU affichée (nom, emplacement et date seulement, jamais la clé).");
            var bitlockerRead = input.BitLocker is not null;
            var bitlockerKeys = active.Count(m => m.BitLocker == 'K');
            var bitlockerMissing = active.Count(m => m.BitLocker == 'N');
            var bitlockerCoverage = bitlockerRead ? Coverage(active.Count(m => m.BitLocker is 'K' or 'N'), total, input.BitLocker!.At) : "";
            if (!bitlockerRead)
            {
                Entry("fleet.bitlocker", "Non lu", null, null, isRoot ? "Choisissez une OU : lecture refusée à la racine du domaine." : "Présence des clés non lue pour cette OU.", Tone.Off, action: bitlockerAction, measured: false);
            }
            else if (!input.BitLocker!.ClassPresent)
            {
                Entry("fleet.bitlocker", "Non disponible", null, null, "Non disponible dans ce domaine : classe de récupération BitLocker absente du schéma.", Tone.Off, action: bitlockerAction, measured: false);
            }
            else if (bitlockerKeys == 0)
            {
                Entry("fleet.bitlocker", "Non déterminé", null, null, "Aucune clé visible avec ce compte (droits ou clés non sauvegardées dans AD) · " + bitlockerCoverage, Tone.Off, action: bitlockerAction, measured: false);
            }
            else
            {
                Entry("fleet.bitlocker", FrenchText.Integer(bitlockerMissing), bitlockerMissing, null, bitlockerCoverage + (input.BitLocker.Truncated ? " · lecture tronquée : aucun « pas de clé » n’est déduit des postes non lus" : ""),
                    bitlockerMissing > 0 ? Tone.Warn : Tone.Ok, action: bitlockerAction, targetsKey: "fleet.bitlocker");
            }

            // Windows versions and end of service.
            if (total > 0)
            {
                var versionItems = Rank(active.GroupBy(m => m.VersionLabel).Select(g => (g.Key, g.Count())));
                var lead = versionItems.First();
                Distribution("fleet.versions", lead.Label, FrenchText.Count(lead.Value, "poste", "postes") + " sur " + FrenchText.Integer(total), [.. versionItems.Select(v => (v.Label, v.Value, (Tone?)null))],
                    FrenchText.Count(total, "poste", "postes"));
            }
            var soonCount = soon.Count;
            Entry("fleet.eos", FrenchText.Integer(ended.Count), ended.Count, null,
                soonCount > 0 ? FrenchText.Integer(soonCount) + " à surveiller (fin dans 90 jours ou moins)" : ended.Count > 0 ? "Versions plus maintenues : à migrer." : "Aucune version en fin de service.",
                ended.Count > 0 ? Tone.Alert : soonCount > 0 ? Tone.Warn : Tone.Ok, targetsKey: "fleet.eos");
            var win10End = windows10.Select(m => m.Release.End).Where(e => e is not null).Max();
            var win10Tone = windows10.Count == 0 ? Tone.Ok
                : windows10.Any(m => m.Release.Status == LifecycleStatus.Ended) ? Tone.Alert
                : windows10.Any(m => m.Release.Status == LifecycleStatus.Soon) ? Tone.Warn
                : windows10.Any(m => m.Release.Status == LifecycleStatus.Ok) ? Tone.Ok : Tone.Off;
            Entry("fleet.win10", FrenchText.Integer(windows10.Count), windows10.Count, null,
                "Hors LTSC, LTSB et IoT" + (windows10.Count == 0 ? "." : win10End is DateOnly we ? FrenchText.Colon + "fin de service le " + FrenchText.ShortDate(we) + "." : FrenchText.Colon + "date de fin inconnue."),
                win10Tone, targetsKey: "fleet.win10");

            // Distribution: systems (6 + others), last logon (6 buckets, empty ones kept), workstations per OU.
            if (total > 0)
            {
                var osRanked = Rank(active.GroupBy(m => m.Os).Select(g => (g.Key, g.Count())));
                var osItems = osRanked.Take(6).Select(o => (o.Label, o.Value, (Tone?)null)).ToList();
                var others = osRanked.Skip(6).ToList();
                if (others.Count > 0)
                {
                    osItems.Add(("Autres", others.Sum(o => o.Value), null));
                    Set("fleet.os|Autres", active.Where(m => others.Any(o => o.Label == m.Os)));
                }
                Distribution("fleet.os", osRanked[0].Label, FrenchText.Count(osRanked[0].Value, "poste", "postes") + " sur " + FrenchText.Integer(total), osItems, FrenchText.Count(total, "poste", "postes"));
                var logonItems = BucketNames.Select((b, i) => (b, active.Count(m => m.Bucket == i), (Tone?)null)).ToList();
                var logonLead = logonItems.OrderByDescending(x => x.Item2).First();
                Series("fleet.lastlogon", logonLead.b, FrenchText.Count(logonLead.Item2, "poste", "postes") + " sur " + FrenchText.Integer(total), logonItems);
                var ouRanked = Rank(active.GroupBy(m => m.Site).Select(g => (g.Key, g.Count())));
                Distribution("fleet.ou", ouRanked[0].Label, FrenchText.Count(ouRanked[0].Value, "poste", "postes") + " sur " + FrenchText.Integer(total), [.. ouRanked.Select(o => (o.Label, o.Value, (Tone?)null))],
                    FrenchText.Count(total, "poste", "postes"), title: isRoot ? null : "Postes par sous-OU");
            }
            else
            {
                hints.Add(new FleetHint("Répartition", "Aucun poste actif dans ce périmètre de la base locale : mettez à jour la base locale de l’OU.", Collect()));
            }

            // ---------------------------------------------------------------- observations
            var observed = active.Where(m => m.Presence != "Non vérifié").ToList();
            var lastCheck = observed.Select(m => m.PingAt).Max();
            var oldestPing = observed.Select(m => m.PingAt).Min();
            var observedOld = oldestPing is DateTimeOffset op && (now - op).TotalDays > 7;
            var observedText = Coverage(observed.Count, total, lastCheck);
            var pingStates = active.Select(m => observations.GetValueOrDefault(m.Guid)?.Presence is PresenceMeasure p && p.HasReading
                ? (MeasureState.Known, p.CheckedAt)
                : (observations.GetValueOrDefault(m.Guid)?.Presence.State is MeasureState s && s != MeasureState.Known ? s : MeasureState.Absent, (DateTimeOffset?)null)).ToList();
            var pingFamily = CollectionClocks.Family("ping", pingStates, total, now, input.ObservationMaxAgeDays, zone);
            var presenceItems = PresenceNames.Select(p => (p, active.Count(m => m.Presence == p), (Tone?)(p == "En ligne" ? Tone.Ok : p == "Sans réponse" ? Tone.Warn : Tone.Off))).Where(x => x.Item2 > 0).ToList();
            if (presenceItems.Count > 0)
            {
                var lead = presenceItems.OrderByDescending(x => x.Item2).First();
                var unknownPing = CollectionClocks.StatesText(pingFamily.States);
                Distribution("fleet.presence", lead.p, observedText + (unknownPing.Length > 0 ? " · sans mesure ping utilisable" + FrenchText.Colon + unknownPing : ""), presenceItems,
                    FrenchText.Count(total, "poste", "postes"), old: observedOld);
            }
            var wmiDated = active.Where(m => m.WmiAt is not null).ToList();
            var wmiOldest = wmiDated.Select(m => m.WmiAt).Min();
            var wmiOld = wmiOldest is DateTimeOffset wo && (now - wo).TotalDays > 7;
            if (total > 0)
            {
                var wmiItems = WmiNames.Select(n => (n, active.Count(m => WmiGroup(m.Wmi) == n), (Tone?)(n == WmiNames[0] ? Tone.Ok : n == WmiNames[1] ? Tone.Warn : Tone.Off))).Where(x => x.Item2 > 0).ToList();
                var wmiStates = new SortedDictionary<string, int>(StringComparer.Ordinal);
                foreach (var m in active.Where(m => m.Wmi != MeasureState.Known))
                {
                    var key = CollectionClocks.StateKey(m.Wmi);
                    wmiStates[key] = wmiStates.GetValueOrDefault(key) + 1;
                }
                var wmiUnknown = CollectionClocks.StatesText(wmiStates);
                var wmiLead = wmiItems.OrderByDescending(x => x.Item2).First();
                Distribution("fleet.wmi", wmiLead.n, FrenchText.Count(wmiDated.Count, "poste avec une lecture WMI datée", "postes avec une lecture WMI datée") + " sur " + FrenchText.Integer(total) + " ; indépendant du ping"
                    + (wmiUnknown.Length > 0 ? " · sans réponse WMI utilisable" + FrenchText.Colon + wmiUnknown : ""), wmiItems, FrenchText.Count(total, "poste", "postes"), old: wmiOld);
                var reachTones = new Dictionary<string, Tone>(StringComparer.Ordinal)
                {
                    [ReachNames[0]] = Tone.Ok, [ReachNames[1]] = Tone.Info, [ReachNames[2]] = Tone.Warn, [ReachNames[3]] = Tone.Warn, [ReachNames[4]] = Tone.Off, [ReachNames[5]] = Tone.Off,
                };
                var reachItems = ReachNames.Select(n => (n, active.Count(m => m.Reach == n), (Tone?)reachTones[n])).Where(x => x.Item2 > 0).ToList();
                var reachLead = reachItems.OrderByDescending(x => x.Item2).First();
                Distribution("fleet.reach", reachLead.n, "Une absence de réponse au ping ou à WMI ne prouve pas que le poste est éteint.", reachItems, FrenchText.Count(total, "poste", "postes"), old: observedOld || wmiOld);
            }
            var users = active.Where(m => m.User is not null).Select(m => m.User!.ToLowerInvariant()).Distinct().Count();
            var sessions = active.Count(m => m.User is not null);
            Entry("fleet.users", FrenchText.Integer(users), users, null, "sur " + FrenchText.Count(sessions, "poste avec une session", "postes avec une session") + " · " + FrenchText.Count(input.Facts.Associations, "association au total", "associations au total"),
                observedOld ? Tone.Off : null);
            Entry("fleet.lastcheck", lastCheck is DateTimeOffset lc ? TimeZoneInfo.ConvertTime(lc, zone).ToString("dd'/'MM HH':'mm", CultureInfo.InvariantCulture) : "Aucune", null, null, observedText,
                observedOld ? Tone.Off : null, measured: lastCheck is not null);

            var inventories = active.Where(m => m.Inventory).ToList();
            var inventoryNewest = inventories.Select(m => m.InventoryAt).Max();
            var inventoryOldest = inventories.Select(m => m.InventoryAt).Min();
            var inventoryOld = inventoryOldest is DateTimeOffset io && (now - io).TotalDays > 7;
            var inventoryText = Coverage(inventories.Count, total, inventoryNewest);
            var inventoryFamily = CollectionClocks.Family("inventaire WMI", active.Select(m => observations.GetValueOrDefault(m.Guid)?.Inventory is InventoryMeasure i && i.HasReading
                ? (MeasureState.Known, i.CheckedAt)
                : (observations.GetValueOrDefault(m.Guid)?.Inventory.State is MeasureState s && s != MeasureState.Known ? s : MeasureState.Absent, (DateTimeOffset?)null)).ToList(), total, now, input.ObservationMaxAgeDays, zone);
            int? lowDiskFigure = null;
            var lowDisk = new List<Machine>();
            List<Machine> longUptime;
            if (inventories.Count == 0)
            {
                hints.Add(new FleetHint("Relevés des postes", "« Relever ce périmètre » recueille les modèles, la mémoire, les disques, les versions et les démarrages des postes actifs de l’OU choisie.", Collect()));
            }
            else
            {
                foreach (var m in inventories)
                {
                    Add("fleet.models|" + (m.Model ?? "Modèle inconnu"), m);
                    Add("fleet.releases|" + (m.InventoryRelease ?? "Version inconnue"), m);
                    if (m.Ram is string ram)
                    {
                        Add("fleet.ram|" + ram, m);
                    }
                }
                Set("fleet.models", inventories);
                Set("fleet.releases", inventories);
                Set("fleet.ram", inventories.Where(m => m.Ram is not null));
                var models = Rank(inventories.GroupBy(m => m.Model ?? "Modèle inconnu").Select(g => (g.Key, g.Count())));
                Distribution("fleet.models", models[0].Label, inventoryText, [.. models.Select(x => (x.Label, x.Value, (Tone?)null))], FrenchText.Count(inventories.Count, "poste", "postes"), old: inventoryOld);
                var releases = Rank(inventories.GroupBy(m => m.InventoryRelease ?? "Version inconnue").Select(g => (g.Key, g.Count())));
                Distribution("fleet.releases", releases[0].Label, inventoryText, [.. releases.Select(x => (x.Label, x.Value, (Tone?)null))], FrenchText.Count(inventories.Count, "poste", "postes"), old: inventoryOld);
                var ramItems = RamNames.Select(r => (r, inventories.Count(m => m.Ram == r), (Tone?)null)).ToList();
                if (ramItems.Sum(r => r.Item2) > 0)
                {
                    var ramLead = ramItems.OrderByDescending(x => x.Item2).First();
                    Series("fleet.ram", ramLead.r, inventoryText, ramItems, old: inventoryOld);
                }
                var alertLimit = limits.DiskFreeAlert;
                var warnLimit = limits.DiskFreeWarn;
                var diskNames = warnLimit < 50
                    ? new[] { "moins de " + alertLimit + FrenchText.Nbsp + "%", alertLimit + " à " + warnLimit + FrenchText.Nbsp + "%", warnLimit + " à 50" + FrenchText.Nbsp + "%", "50" + FrenchText.Nbsp + "% et plus" }
                    : ["moins de " + alertLimit + FrenchText.Nbsp + "%", alertLimit + " à " + warnLimit + FrenchText.Nbsp + "%", warnLimit + FrenchText.Nbsp + "% et plus"];
                var diskTones = new Tone?[] { Tone.Alert, Tone.Warn, Tone.Info, Tone.Info };
                var withDisk = inventories.Where(m => m.DiskFree is not null).ToList();
                Set("fleet.diskfree", withDisk);
                foreach (var m in withDisk)
                {
                    var pct = m.DiskFree!.Value;
                    var bucket = pct < alertLimit ? 0 : pct < warnLimit ? 1 : diskNames.Length == 3 || pct < 50 ? 2 : 3;
                    Add("fleet.diskfree|" + diskNames[bucket], m);
                    if (pct < alertLimit)
                    {
                        lowDisk.Add(m);
                    }
                }
                if (withDisk.Count > 0)
                {
                    var diskItems = diskNames.Select((n, i) => (n, targets.GetValueOrDefault("fleet.diskfree|" + n)?.Count ?? 0, diskTones[i])).ToList();
                    var diskLead = diskItems.OrderByDescending(x => x.Item2).First();
                    lowDiskFigure = lowDisk.Count;
                    Series("fleet.diskfree", diskLead.n, inventoryText, diskItems, old: inventoryOld);
                    Set("fleet.lowdisk", lowDisk);
                    Entry("fleet.lowdisk", FrenchText.Integer(lowDisk.Count), lowDisk.Count, null, "Moins de " + alertLimit + FrenchText.Nbsp + "% libre · " + inventoryText,
                        inventoryOld ? Tone.Off : lowDisk.Count > 0 ? Tone.Alert : Tone.Ok, targetsKey: "fleet.lowdisk");
                }
                var booted = inventories.Where(m => m.UptimeDays is not null).ToList();
                longUptime = [.. booted.Where(m => m.UptimeDays > limits.UptimeDays)];
                if (booted.Count > 0)
                {
                    Set("fleet.uptime", longUptime);
                    Entry("fleet.uptime", FrenchText.Integer(longUptime.Count), longUptime.Count, null, "Redémarrage conseillé · " + inventoryText,
                        inventoryOld ? Tone.Off : longUptime.Count > 0 ? Tone.Warn : Tone.Ok, title: "Sans redémarrage depuis " + FrenchText.Integer(limits.UptimeDays) + " j", targetsKey: "fleet.uptime");
                }
            }

            // ---------------------------------------------------------------- points of attention (per-OU policies)
            var hits = new Dictionary<string, RuleHits>(StringComparer.Ordinal);
            void Hit(string rule, Machine m, string? policyRule = null)
            {
                if (!hits.TryGetValue(rule, out var h))
                {
                    hits[rule] = h = new RuleHits();
                }
                var enabled = HealthRules.IsEnabled(m.Policy, policyRule ?? RuleOf(rule), now);
                (enabled ? h.Active : h.Masked).Add(m.Guid);
            }
            foreach (var m in active)
            {
                var t = m.Policy.Thresholds;
                if (m.Release.Status == LifecycleStatus.Ended)
                {
                    Hit("eos.ended|" + EosLabel(m), m, "eos.ended");
                }
                else if (m.Release.Status == LifecycleStatus.Soon)
                {
                    Hit("eos.soon|" + EosLabel(m), m, "eos.soon");
                }
                if (m.Logon is DateOnly logon && logon <= today.AddDays(-t.StaleDays))
                {
                    Hit("stale", m);
                }
                if (m.Logon is null)
                {
                    Hit("never", m);
                }
                if (m.PasswordSet is DateTimeOffset pw && pw < now - TimeSpan.FromDays(t.PasswordDays))
                {
                    Hit("pwdold", m);
                }
                if (lapsVisible && m.Laps == 'N')
                {
                    Hit("laps.none", m);
                }
                if (m.Laps == 'E')
                {
                    Hit("laps.expired", m);
                }
                if (bitlockerVisible && m.BitLocker == 'N')
                {
                    Hit("bitlocker.none", m);
                }
                if (m.DiskFree is double free)
                {
                    if (free < t.DiskFreeAlert)
                    {
                        Hit("lowdisk", m);
                    }
                    else if (free < t.DiskFreeWarn)
                    {
                        Hit("disk.tight", m);
                    }
                }
                if (m.UptimeDays is double up && up > t.UptimeDays)
                {
                    Hit("uptime", m);
                }
                foreach (var rule in m.Policy.CustomRules)
                {
                    double? value = rule.Measure switch { "DiskFree" => m.DiskFree, "UptimeDays" => m.UptimeDays, _ => null };
                    if (value is double v && (rule.Operator == "LessThan" ? v < rule.Threshold : v > rule.Threshold))
                    {
                        Hit(rule.Id, m);
                    }
                }
            }
            var points = new List<(FleetPoint Point, RuleHits Hits)>();
            void Point(string id, string level, string text, RuleHits h, string? key = null)
            {
                var targetsKey = "point:" + (key ?? id);
                Set(targetsKey, h.Active.Select(g => byGuid[g]));
                labels[targetsKey] = text;
                points.Add((new FleetPoint(RuleOf(id), RuleName(RuleOf(id)), level, text, h.Active.Count, targetsKey), h));
            }
            foreach (var (key, h) in hits.Where(x => x.Key.StartsWith("eos.ended|", StringComparison.Ordinal)).OrderBy(x => x.Key, StringComparer.Ordinal))
            {
                var sample = byGuid[h.Active.Count > 0 ? h.Active[0] : h.Masked[0]];
                var when = (sample.Release.Guessed ? "fin de service au plus tard le " : "fin de service le ") + (sample.Release.End is DateOnly e ? FrenchText.ShortDate(e) : "");
                if (h.Active.Count > 0)
                {
                    Point("eos.ended", "alert", FrenchText.Count(h.Active.Count, "poste", "postes") + " sous " + key[10..] + ", " + when + FrenchText.Colon + "à migrer.", h, key);
                }
                else
                {
                    points.Add((new FleetPoint("eos.ended", HealthRules.RuleName("eos.ended"), "alert", "", 0, null), h));
                }
            }
            foreach (var (key, h) in hits.Where(x => x.Key.StartsWith("eos.soon|", StringComparison.Ordinal)).OrderBy(x => x.Key, StringComparer.Ordinal))
            {
                var sample = byGuid[h.Active.Count > 0 ? h.Active[0] : h.Masked[0]];
                if (h.Active.Count > 0)
                {
                    Point("eos.soon", "warn", FrenchText.Count(h.Active.Count, "poste", "postes") + " sous " + key[9..] + ", fin de service le " + (sample.Release.End is DateOnly e ? FrenchText.ShortDate(e) : "") + ".", h, key);
                }
                else
                {
                    points.Add((new FleetPoint("eos.soon", HealthRules.RuleName("eos.soon"), "warn", "", 0, null), h));
                }
            }
            void Simple(string id, string level, Func<int, string> text)
            {
                if (hits.TryGetValue(id, out var h))
                {
                    if (h.Active.Count > 0)
                    {
                        Point(id, level, text(h.Active.Count), h);
                    }
                    else
                    {
                        points.Add((new FleetPoint(id, HealthRules.RuleName(id), level, "", 0, null), h));
                    }
                }
            }
            Simple("stale", "warn", n => Plural(n, "poste sans connexion au domaine", "postes sans connexion au domaine") + " depuis " + FrenchText.Integer(limits.StaleDays) + " jours ou plus (date AD approximative)" + FrenchText.Colon + "à vérifier.");
            Simple("never", "warn", n => Plural(n, "compte ordinateur sans date de connexion AD renseignée.", "comptes ordinateur sans date de connexion AD renseignée."));
            var partialBase = !input.State.Directory.Complete;
            if (partialBase)
            {
                var h = new RuleHits();
                Point("index.partial", "warn", "Base locale incomplète : dernière lecture arrêtée à sa limite. Les chiffres peuvent être sous-estimés : utilisez « Mettre à jour la base locale de l’OU ».", h);
            }
            Simple("pwdold", "warn", n => Plural(n, "poste avec un mot de passe machine", "postes avec un mot de passe machine") + " de plus de " + FrenchText.Integer(limits.PasswordDays) + " jours.");
            Simple("laps.none", "warn", n => Plural(n, "poste sans expiration LAPS visible.", "postes sans expiration LAPS visible."));
            Simple("laps.expired", "warn", n => Plural(n, "poste dont le mot de passe LAPS a expiré.", "postes dont le mot de passe LAPS a expiré."));
            Simple("bitlocker.none", "warn", n => Plural(n, "poste sans clé BitLocker visible.", "postes sans clé BitLocker visible."));
            if (created.Count > 0)
            {
                var h = new RuleHits();
                h.Active.AddRange(created.Select(m => m.Guid));
                Point("created", "info", Plural(created.Count, "poste créé ces 30 derniers jours.", "postes créés ces 30 derniers jours."), h);
            }
            if (disabledMachines.Count > 0)
            {
                var h = new RuleHits();
                h.Active.AddRange(disabledMachines.Select(m => m.Guid));
                var key = "point:disabled";
                Set(key, disabledMachines);
                var text = Plural(disabledMachines.Count, "compte ordinateur désactivé encore dans l’OU", "comptes ordinateur désactivés encore dans l’OU") + FrenchText.Colon + "à déplacer ou supprimer.";
                labels[key] = text;
                points.Add((new FleetPoint("disabled", "Comptes désactivés dans l’OU", "info", text, disabledMachines.Count, key), h));
            }
            var unreachable = active.Where(m => m.Presence == "Sans réponse").ToList();
            if (unreachable.Count > 0)
            {
                var wmiOnly = unreachable.Count(m => m.Wmi == MeasureState.Known);
                var h = new RuleHits();
                h.Active.AddRange(unreachable.Select(m => m.Guid));
                Point("unreachable", "info", Plural(unreachable.Count, "poste sans réponse au ping", "postes sans réponse au ping") + " au dernier relevé"
                    + (wmiOnly > 0 ? ", dont " + FrenchText.Integer(wmiOnly) + " " + (wmiOnly > 1 ? "ayant" : "ayant") + " répondu à WMI (ICMP probablement filtré)" : "") + FrenchText.Colon + "absence de réponse, pas une preuve d’arrêt.", h);
            }
            var wmiFailed = active.Where(m => m.Wmi is MeasureState.Refused or MeasureState.Error).ToList();
            if (wmiFailed.Count > 0)
            {
                var h = new RuleHits();
                h.Active.AddRange(wmiFailed.Select(m => m.Guid));
                var refused = wmiFailed.Count(m => m.Wmi == MeasureState.Refused);
                var failedText = CollectionClocks.StatesText(new Dictionary<string, int> { ["refused"] = refused, ["error"] = wmiFailed.Count - refused });
                Point("wmi.failed", "info", Plural(wmiFailed.Count, "poste sans lecture WMI confirmée", "postes sans lecture WMI confirmée") + " au dernier essai (" + failedText + ")" + FrenchText.Colon + "à relever de nouveau, pas une preuve d’arrêt.", h);
            }
            Simple("lowdisk", "alert", n => Plural(n, "poste avec moins de", "postes avec moins de") + " " + limits.DiskFreeAlert + FrenchText.Nbsp + "% libre sur C:.");
            Simple("disk.tight", "warn", n => Plural(n, "poste avec peu d’espace sur C:", "postes avec peu d’espace sur C:") + " (moins de " + limits.DiskFreeWarn + FrenchText.Nbsp + "% libre).");
            Simple("uptime", "warn", n => Plural(n, "poste non redémarré", "postes non redémarrés") + " depuis plus de " + FrenchText.Integer(limits.UptimeDays) + " jours.");
            foreach (var rule in active.SelectMany(m => m.Policy.CustomRules).GroupBy(r => r.Id).Select(g => g.First()).OrderBy(r => r.Id, StringComparer.Ordinal))
            {
                var level = rule.Severity == "Alert" ? "alert" : "warn";
                if (hits.TryGetValue(rule.Id, out var h))
                {
                    if (h.Active.Count > 0)
                    {
                        Point(rule.Id, level, rule.Name + FrenchText.Colon + Plural(h.Active.Count, "poste concerné.", "postes concernés."), h);
                        points[^1] = (points[^1].Point with { Rule = rule.Name }, h);
                    }
                    else
                    {
                        points.Add((new FleetPoint(rule.Id, rule.Name, level, "", 0, null), h));
                    }
                }
            }
            if (input.Facts.RejectedObservations > 0)
            {
                Point("cache.invalid", "warn", Plural(input.Facts.RejectedObservations, "relevé ignoré", "relevés ignorés") + FrenchText.Colon + "contenu illisible ou identité AD différente. Les postes restent dans la base et peuvent être relevés à nouveau.", new RuleHits());
            }

            // ---------------------------------------------------------------- health population and score
            var visible = points.Where(p => p.Point.Count > 0 || p.Point.Id is "index.partial" or "cache.invalid").ToList();
            var problemIds = new HashSet<Guid>(visible.Where(p => p.Point.Level is "alert" or "warn").SelectMany(p => p.Hits.Active));
            var healthy = new List<Machine>();
            var problems = new List<Machine>();
            var unknown = new List<Machine>();
            foreach (var m in active)
            {
                if (problemIds.Contains(m.Guid))
                {
                    problems.Add(m);
                }
                else if (Known(m))
                {
                    healthy.Add(m);
                }
                else
                {
                    unknown.Add(m);
                }
            }
            Set("fleet.health", active);
            Set("fleet.attention", problems);
            Set("fleet.health|Sans problème", healthy);
            Set("fleet.health|Problèmes", problems);
            Set("fleet.health|Incomplets", unknown);
            var explanation = Explain(active, hits, visible, healthy.Count, unknown.Count, inventories, pingFamily, inventoryFamily);
            var alerts = visible.Count(p => p.Point.Level == "alert");
            var warnings = visible.Count(p => p.Point.Level == "warn");
            var information = visible.Count(p => p.Point.Level == "info");
            var (score, verdict, tone, detail) = Score(total, healthy.Count, unknown.Count, alerts);
            var badges = new List<string>();
            if (partialBase)
            {
                badges.Add("Base AD incomplète : couverture partielle");
                score = null;
                if (alerts == 0)
                {
                    verdict = "Évaluation partielle";
                    tone = Tone.Off;
                }
            }
            if (explanation.SuspendedRules > 0)
            {
                badges.Add(Plural(explanation.SuspendedRules, "règle suspendue temporairement", "règles suspendues temporairement"));
            }
            badges.Add(FrenchText.Integer(healthy.Count + problems.Count) + " évalués / " + FrenchText.Count(total, "compte activé", "comptes activés") + " ; " + Plural(unknown.Count, "incomplet", "incomplets"));
            var sorted = visible.OrderBy(p => p.Point.Level switch { "alert" => 0, "warn" => 1, _ => 2 }).Select(p => p.Point).ToImmutableArray();
            var reliable = score is not null && !partialBase;
            var pointsTitle = PointsTitle(alerts + warnings, information, reliable);
            var health = new FleetHealth(score, verdict, tone, detail, badges.Count > 0 ? string.Join(" · ", badges) : null, pointsTitle, alerts, warnings, information, sorted,
                explanation.MaskedMachines, total, healthy.Count + problems.Count, healthy.Count, problems.Count, unknown.Count,
                "fleet.health|Sans problème", "fleet.health|Problèmes", "fleet.health|Incomplets");
            entries[FleetCatalog.Health] = new FleetEntry(FleetCatalog.Health, "Santé du parc", "Santé", FleetDataKind.Health, verdict, score, score is null ? null : FrenchText.Nbsp + "%",
                detail, tone, null, health.Badge, [
                    Part("Sans problème", healthy.Count, Tone.Ok, "fleet.health|Sans problème"),
                    Part("Problèmes", problems.Count, alerts > 0 ? Tone.Alert : Tone.Warn, "fleet.health|Problèmes"),
                    Part("Incomplets", unknown.Count, Tone.Off, "fleet.health|Incomplets")], [], total, "fleet.health", null, score is not null);
            entries[FleetCatalog.Attention] = new FleetEntry(FleetCatalog.Attention, pointsTitle, "Santé", FleetDataKind.List, pointsTitle, alerts + warnings, null,
                alerts + warnings > 0 ? string.Join(" · ", new[] { alerts > 0 ? Plural(alerts, "critique", "critiques") : "", warnings > 0 ? FrenchText.Integer(warnings) + " à surveiller" : "" }.Where(s => s.Length > 0)) : "Aucun point à vérifier",
                tone, null, null, [], [], problems.Count, "fleet.attention", null, true);

            // ---------------------------------------------------------------- snapshot and trends
            var assessed = healthy.Concat(problems).ToList();
            var policyList = active.Select(m => (m.PolicyScope, m.Policy)).Distinct().ToList();
            var coverageTokens = active.Select(m => string.Join("|",
                m.Guid.ToString("D"), m.Logon is null ? 0 : 1, m.Release.Build.Length > 0 ? 1 : 0, m.PasswordSet is null ? 0 : 1,
                m.Laps is 'O' or 'E' or 'N' or 'X' ? 1 : 0, m.BitLocker is 'K' or 'N' or 'X' ? 1 : 0, m.DiskFree is null ? 0 : 1, m.UptimeDays is null ? 0 : 1));
            var figures = new FleetFigures(total, healthy.Count, problems.Count, staleMachines.Count, limits.StaleDays, ended.Count, disabledMachines.Count, windows10.Count, lowDiskFigure,
                assessed.Count, unknown.Count, score, observed.Count, inventories.Count,
                FleetFingerprint.Of(active.Select(m => m.Guid.ToString("D"))), FleetFingerprint.Of(assessed.Select(m => m.Guid.ToString("D"))),
                FleetFingerprint.Of(coverageTokens), HealthRules.Fingerprint(policyList, now), FormatVersion);
            var snapshot = new FleetSnapshot("actuel", "current", "Vue actuelle · " + CollectionClocks.Local(now, zone), today, now, figures);
            Trends(input.History, snapshot, limits.StaleDays);
            if (!entries.ContainsKey("fleet.trend"))
            {
                hints.Add(new FleetHint("Évolution", "Deux relevés datés du même indicateur sont nécessaires pour afficher une évolution. Un instantané local est conservé au premier calcul de chaque jour ; aucun jour manquant n’est remplacé par zéro.", null));
            }

            // ---------------------------------------------------------------- probe and query widgets of the layout
            foreach (var item in input.Layout.Where(i => i.Source == FleetWidgetSource.Probe).GroupBy(i => i.Key).Select(g => g.First()))
            {
                ProbeEntry(item, active);
            }
            foreach (var item in input.Layout.Where(i => i.Source == FleetWidgetSource.Query).GroupBy(i => i.Key).Select(g => g.First()))
            {
                entries["query:" + item.Key] = new FleetEntry("query:" + item.Key, item.Title ?? "Requête enregistrée", item.Group, FleetDataKind.Distribution, "Requête absente", null, null,
                    "Requête absente de la bibliothèque : l’atelier de requêtes n’est pas encore disponible dans cette version. Retirez ce widget ou attendez l’atelier ; rien n’est calculé.",
                    Tone.Off, null, "Bibliothèque non lue", [], [], null, null, null, false);
            }

            // ---------------------------------------------------------------- result
            foreach (var key in entries.Values.Where(e => e.Kind is FleetDataKind.Distribution or FleetDataKind.Series).SelectMany(e => e.Items.Select(i => i.TargetsKey)).ToList())
            {
                targets.TryAdd(key, []);
            }
            var scopeLabel = isRoot ? "Domaine " + input.DomainName : "OU " + scope.Label;
            var population = new FleetPopulation(machineCount, total, disabledMachines.Count, 0, "comptes ordinateur recensés : activés, désactivés et état inconnu", input.Facts.StoreId);
            var board = new FleetBoard("", now, scope, scopeLabel, population, entries.ToImmutableSortedDictionary(StringComparer.Ordinal), health, [.. hints],
                FrenchText.Count(machineCount, "compte ordinateur", "comptes ordinateur") + " dans le périmètre" + FrenchText.Colon + machineDetail + ".", snapshot);
            var rows = machines.ToImmutableDictionary(m => m.Guid, Row);
            var dimensions = active.ToImmutableDictionary(m => m.Guid, m => new FleetPivotFacts(
                m.Site, m.VersionLabel, m.Model ?? "Modèle non lu", m.Ram ?? "RAM non lue", m.Presence, m.Bios ?? "BIOS non relevé",
                m.Presence is "En ligne" or "Sans réponse", m.Inventory));
            return new FleetComputation(board,
                targets.ToImmutableDictionary(p => p.Key, p => p.Value.Distinct().ToImmutableArray(), StringComparer.Ordinal),
                labels.ToImmutableDictionary(StringComparer.Ordinal), rows, dimensions, explanation, [.. active.Select(m => m.Guid)]);
        }

        // ---------------------------------------------------------------- building a workstation

        private Machine Build(DirectoryComputer c)
        {
            var parent = DistinguishedName.Parent(c.DistinguishedName) ?? input.DomainDn;
            var enabled = !AdValues.IsDisabled(c.UserAccountControl);
            var osRaw = c.OperatingSystem?.Trim();
            var os = string.IsNullOrEmpty(osRaw) ? "Système non renseigné" : osRaw.Replace("Microsoft ", "", StringComparison.Ordinal).Replace("Professionnel", "Pro", StringComparison.Ordinal).Replace("Professional", "Pro", StringComparison.Ordinal);
            var release = WindowsLifecycle.Evaluate(c.OperatingSystemVersion, os, today);
            var versionLabel = release.Build.Length > 0 ? (release.Label.Length > 0 ? release.Label : os + " (build " + release.Build + ")") : "Version non lue";
            var kind = string.IsNullOrEmpty(osRaw) ? KindNames[2] : release.Family == WindowsFamily.Server ? KindNames[1] : KindNames[0];
            DateOnly? logon = AdValues.FromFileTime(c.LastLogonTimestamp) is DateTimeOffset l ? LocalDays.DateOf(l, zone) : null;
            var bucket = logon is not DateOnly day ? 5
                : day > today.AddDays(-7) ? 0
                : day > today.AddDays(-30) ? 1
                : day > today.AddDays(-90) ? 2
                : day > today.AddDays(-180) ? 3 : 4;
            var laps = c.Laps == LapsKind.None && c.LapsExpiration is null ? 'N'
                : AdValues.FromFileTime(c.LapsExpiration) is DateTimeOffset expiry ? (expiry > now ? 'O' : 'E') : 'N';
            var bit = 'U';
            if (input.BitLocker is BitLockerPresence presence)
            {
                bit = !presence.ClassPresent ? 'X' : presence.Machines.TryGetValue(c.ObjectGuid, out var fact) && fact.Keys > 0 ? 'K' : presence.Truncated && !presence.Machines.ContainsKey(c.ObjectGuid) ? 'U' : 'N';
            }
            var (policy, source) = PolicyFor(parent);
            return new Machine
            {
                Computer = c,
                Parent = parent,
                Enabled = enabled,
                Os = os,
                OsKnown = !string.IsNullOrEmpty(osRaw),
                Release = release,
                VersionLabel = versionLabel,
                Kind = kind,
                Logon = logon,
                Bucket = bucket,
                Created = c.WhenCreated >= now - TimeSpan.FromDays(30),
                PasswordSet = AdValues.FromFileTime(c.PasswordLastSet),
                Laps = laps,
                BitLocker = bit,
                Site = SiteOf(parent),
                Policy = policy,
                PolicyScope = source,
            };
        }

        private (HealthPolicy Policy, string Source) PolicyFor(string parent)
        {
            if (!policies.TryGetValue(parent, out var resolved))
            {
                var r = HealthRules.Resolve(input.Book, HealthRules.IsInDomain(parent, input.DomainDn) ? parent : "");
                resolved = (r.Policy, r.SourceDn ?? "");
                policies[parent] = resolved;
            }
            return resolved;
        }

        /// <summary>The direct sub-OU of the scope that holds the workstation (the OU itself for its direct children).</summary>
        private string SiteOf(string parent)
        {
            try
            {
                var scope = input.Scope;
                var parentNames = DistinguishedName.Parse(parent);
                if (ScopeRules.IsDomainRoot(scope, input.DomainDn))
                {
                    return parentNames.Length > 0 && !parentNames[0].Type.Equals("DC", StringComparison.OrdinalIgnoreCase) ? parentNames[0].Value : input.DomainName;
                }
                var scopeNames = DistinguishedName.Parse(scope.Dn);
                if (parentNames.Length <= scopeNames.Length)
                {
                    return scope.Label;
                }
                return parentNames[parentNames.Length - scopeNames.Length - 1].Value;
            }
            catch (FormatException)
            {
                return "OU non renseignée";
            }
        }

        private void Observe(Machine m, WorkstationObservation? o)
        {
            var maxAge = TimeSpan.FromDays(input.ObservationMaxAgeDays);
            if (o is not null && o.Presence.HasReading && o.Presence.CheckedAt is DateTimeOffset checkedAt && checkedAt <= now + TimeSpan.FromMinutes(5) && now - checkedAt <= maxAge)
            {
                m.Presence = o.Presence.Answered == true ? "En ligne" : "Sans réponse";
                m.PingAt = checkedAt;
            }
            var facts = input.Facts.Machines.GetValueOrDefault(m.Guid);
            if (facts is not null)
            {
                m.Wmi = facts.WmiState;
                m.WmiAt = facts.WmiAt;
                if (facts.ConsoleUser is string user && facts.ConsoleAt is DateTimeOffset seen && now - seen <= maxAge && seen <= now + TimeSpan.FromMinutes(5))
                {
                    m.User = user;
                }
                if (facts.BiosVersion is string bios && facts.BiosAt is DateTimeOffset biosAt && now - biosAt <= maxAge)
                {
                    m.Bios = bios.Trim();
                }
            }
            if (o is not null && o.Inventory.HasReading && o.Inventory.CheckedAt is DateTimeOffset invAt && invAt <= now + TimeSpan.FromMinutes(5) && now - invAt <= maxAge)
            {
                var inv = o.Inventory;
                m.Inventory = true;
                m.InventoryAt = invAt;
                m.Model = string.IsNullOrWhiteSpace(inv.Model) ? "Modèle inconnu" : inv.Model.Trim();
                if (inv.MemoryBytes is long bytes && bytes > 0)
                {
                    var gb = bytes / (double)(1L << 30);
                    m.Ram = gb <= 4.5 ? RamNames[0] : gb <= 8.5 ? RamNames[1] : gb <= 16.5 ? RamNames[2] : gb <= 32.5 ? RamNames[3] : RamNames[4];
                }
                if (inv.SystemDiskSizeBytes is long size && size > 0 && inv.SystemDiskFreeBytes is long free && free >= 0 && free <= size)
                {
                    m.DiskFree = 100.0 * free / size;
                }
                if (inv.LastBootAt is DateTimeOffset boot && boot <= now)
                {
                    m.UptimeDays = (now - boot).TotalDays;
                }
                var release = WindowsLifecycle.Evaluate(inv.Build, inv.OsCaption, today);
                m.InventoryRelease = release.Name.Length > 0 ? release.Name : !string.IsNullOrEmpty(inv.Build) ? "Build " + inv.Build : "Version inconnue";
                // A CIM read that succeeded answers for WMI, unless a later attempt failed (more than 15 minutes after it, point 72).
                var laterFailure = facts is { WmiState: MeasureState.Refused or MeasureState.Error, WmiAt: DateTimeOffset failedAt } && failedAt > invAt + TimeSpan.FromMinutes(15);
                if (!laterFailure)
                {
                    m.Wmi = MeasureState.Known;
                    m.WmiAt = facts?.WmiState == MeasureState.Known && facts.WmiAt is DateTimeOffset known && known > invAt ? known : invAt;
                }
            }
            else if (facts is null && o is not null)
            {
                m.Wmi = InventoryState(o);
            }
            m.Reach = ReachLabel(m.Presence, m.Wmi);
        }

        // ---------------------------------------------------------------- health

        private bool Known(Machine m)
        {
            var p = m.Policy;
            bool On(string id) => HealthRules.IsEnabled(p, id, now);
            var customOn = p.CustomRules.Where(r => On(r.Id)).ToList();
            var enabledCount = ScoredRules.Count(On) + customOn.Count;
            var known = enabledCount > 0 && !customOn.Any(r => r.Measure == "MemoryUsed");
            if (On("eos.ended") || On("eos.soon"))
            {
                known &= m.Release.Build.Length > 0 && m.OsKnown;
            }
            if (On("pwdold"))
            {
                known &= m.PasswordSet is not null;
            }
            if (On("laps.none") || On("laps.expired"))
            {
                known &= m.Laps is 'O' or 'E' or 'X';
            }
            if (On("bitlocker.none"))
            {
                known &= m.BitLocker is 'K' or 'X';
            }
            if (On("stale") || On("never"))
            {
                known &= m.Logon is not null;
            }
            if (On("lowdisk") || On("disk.tight") || customOn.Any(r => r.Measure == "DiskFree"))
            {
                known &= m.DiskFree is not null;
            }
            if (On("uptime") || customOn.Any(r => r.Measure == "UptimeDays"))
            {
                known &= m.UptimeDays is not null;
            }
            return known;
        }

        private static (int? Score, string Verdict, Tone Tone, string Detail) Score(int total, int healthy, int unassessed, int alerts)
        {
            unassessed = Math.Clamp(unassessed, 0, total);
            var assessed = Math.Max(0, total - unassessed);
            if (assessed == 0)
            {
                return (null, total > 0 ? "Données insuffisantes" : "Aucun poste évalué", Tone.Off,
                    FrenchText.Integer(assessed) + " évalué sur " + FrenchText.Integer(total) + " · " + Plural(unassessed, "non évalué", "non évalués"));
            }
            var percent = (int)Math.Floor(100.0 * assessed / total);
            var sufficient = 100 * assessed >= MinimumCoveragePercent * total;
            var coverageText = "couverture " + percent + FrenchText.Nbsp + "% (" + FrenchText.Integer(assessed) + " évalués sur " + FrenchText.Integer(total) + ")";
            healthy = Math.Clamp(healthy, 0, assessed);
            if (unassessed > 0 && !sufficient)
            {
                return (null, alerts > 0 ? "Critique" : "Couverture insuffisante", alerts > 0 ? Tone.Alert : Tone.Off,
                    Plural(healthy, "poste sans point détecté", "postes sans point détecté") + " sur " + FrenchText.Integer(assessed) + " évalués · " + coverageText + FrenchText.Colon + "score affiché à partir de " + MinimumCoveragePercent + FrenchText.Nbsp + "%");
            }
            var score = (int)Math.Floor(100.0 * healthy / assessed);
            var verdict = alerts > 0 ? "Critique" : score >= 90 && unassessed > 0 ? "Évaluation partielle" : score >= 90 ? "Bon état" : score >= 75 ? "À surveiller" : "Dégradé";
            var tone = alerts > 0 || verdict == "Dégradé" ? Tone.Alert : verdict == "À surveiller" ? Tone.Warn : unassessed > 0 ? Tone.Off : Tone.Ok;
            var detail = Plural(healthy, "poste", "postes") + " sur " + FrenchText.Integer(assessed) + " évalués sans point détecté · " + Plural(unassessed, "non évalué", "non évalués");
            if (unassessed > 0)
            {
                detail += " · " + coverageText;
            }
            return (score, verdict, tone, detail);
        }

        private static string PointsTitle(int points, int information, bool reliable)
        {
            var info = information > 0 ? Plural(information, "information", "informations") : "";
            var head = points > 0 ? Plural(points, "point à vérifier", "points à vérifier") : !reliable ? "Aucun problème établi" : info.Length > 0 ? "Aucun point à vérifier" : "Rien à signaler";
            return info.Length > 0 ? head + " · " + info : head;
        }

        private FleetExplanation Explain(List<Machine> active, Dictionary<string, RuleHits> hits, List<(FleetPoint Point, RuleHits Hits)> visible, int healthy, int unknown,
            List<Machine> inventories, MeasureFamilyFreshness ping, MeasureFamilyFreshness inventory)
        {
            var lapsVisible = active.Any(m => m.Laps is 'O' or 'E');
            var bitlockerVisible = active.Any(m => m.BitLocker == 'K');
            var eligible = new Dictionary<string, int>(StringComparer.Ordinal)
            {
                ["eos.ended"] = active.Count(m => m.Release.End is not null),
                ["eos.soon"] = active.Count(m => m.Release.End is not null),
                ["stale"] = active.Count(m => m.Logon is not null),
                ["never"] = active.Count,
                ["pwdold"] = active.Count(m => m.PasswordSet is not null),
                ["laps.none"] = lapsVisible ? active.Count(m => m.Laps is 'O' or 'E' or 'N') : 0,
                ["laps.expired"] = active.Count(m => m.Laps is 'O' or 'E'),
                ["bitlocker.none"] = bitlockerVisible ? active.Count(m => m.BitLocker is 'K' or 'N') : 0,
                ["lowdisk"] = active.Count(m => m.DiskFree is not null),
                ["disk.tight"] = active.Count(m => m.DiskFree is not null),
                ["uptime"] = active.Count(m => m.UptimeDays is not null),
            };
            var measures = new Dictionary<string, int>(StringComparer.Ordinal) { ["DiskFree"] = eligible["lowdisk"], ["UptimeDays"] = eligible["uptime"] };
            // Every rule id: catalog, custom alerts, and the diagnostics of the view.
            var customRules = active.SelectMany(m => m.Policy.CustomRules).GroupBy(r => r.Id).Select(g => g.First()).ToDictionary(r => r.Id, StringComparer.Ordinal);
            var ids = HealthRules.Catalog.Select(r => r.Id).Concat(customRules.Keys).Concat(visible.Select(v => v.Point.Id)).Distinct().Order(StringComparer.Ordinal).ToList();
            var activeById = new Dictionary<string, HashSet<Guid>>(StringComparer.Ordinal);
            var maskedById = new Dictionary<string, HashSet<Guid>>(StringComparer.Ordinal);
            foreach (var (key, h) in hits)
            {
                var id = RuleOf(key);
                var a = activeById.TryGetValue(id, out var x) ? x : activeById[id] = [];
                var b = maskedById.TryGetValue(id, out var y) ? y : maskedById[id] = [];
                a.UnionWith(h.Active);
                b.UnionWith(h.Masked);
            }
            foreach (var (point, h) in visible.Where(v => !hits.ContainsKey(v.Point.Id)))
            {
                var a = activeById.TryGetValue(point.Id, out var x) ? x : activeById[point.Id] = [];
                if (point.Level is "alert" or "warn")
                {
                    a.UnionWith(h.Active);
                }
            }
            var flagged = new Dictionary<Guid, int>();
            foreach (var set in activeById.Where(p => p.Key is not ("created" or "disabled" or "unreachable" or "wmi.failed")).Select(p => p.Value))
            {
                foreach (var g in set)
                {
                    flagged[g] = flagged.GetValueOrDefault(g) + 1;
                }
            }
            var distinctPolicies = active.GroupBy(m => m.PolicyScope, StringComparer.OrdinalIgnoreCase).Select(g => (Scope: g.Key, g.First().Policy, Count: g.Count())).ToList();
            var rows = new List<FleetExplanationRow>();
            var suspendedRules = 0;
            var maskedAll = new HashSet<Guid>();
            var total = active.Count;
            foreach (var id in ids)
            {
                var name = customRules.TryGetValue(id, out var custom) ? custom.Name : RuleName(id);
                var statuses = distinctPolicies.Select(p => HealthRules.State(p.Policy, id, now)).Distinct().ToList();
                if (statuses.Count == 0)
                {
                    statuses.Add(HealthRules.State(boardPolicy, id, now));
                }
                var status = statuses.Count > 1 ? "Selon l’OU" : statuses[0] switch { HealthRuleState.Disabled => "Désactivée", HealthRuleState.Suspended => "Suspendue", _ => "Activée" };
                var reasons = distinctPolicies.Where(p => HealthRules.State(p.Policy, id, now) == HealthRuleState.Suspended)
                    .Select(p => HealthRules.SuspensionText(HealthRules.Suspension(p.Policy, id, now)!, zone)).Distinct().ToList();
                if (statuses.Contains(HealthRuleState.Suspended))
                {
                    suspendedRules++;
                }
                var hitSet = activeById.GetValueOrDefault(id) ?? [];
                var maskedSet = maskedById.GetValueOrDefault(id) ?? [];
                maskedAll.UnionWith(maskedSet);
                var count = id is "created" or "disabled" or "unreachable" or "wmi.failed" ? 0 : hitSet.Count;
                var exclusive = hitSet.Count(g => flagged.GetValueOrDefault(g) == 1);
                int? eligibleCount = eligible.TryGetValue(id, out var e) ? e : custom is not null && measures.TryGetValue(custom.Measure, out var me) ? me : null;
                var isRule = HealthRules.IsKnownRule(id) || custom is not null;
                var fleetRule = custom is not null || HealthRules.Catalog.Any(r => r.Id == id && r.Fleet);
                var eligibleText = !isRule ? "Diagnostic de la vue" : eligibleCount is int ec ? FrenchText.Integer(ec) + " / " + FrenchText.Integer(total) : "Non mesuré sur le parc";
                if (isRule && !fleetRule)
                {
                    eligibleCount = null;
                    eligibleText = "Non mesuré sur le parc";
                }
                string effect;
                if (status == "Désactivée")
                {
                    effect = "Exclue du score";
                }
                else if (status == "Suspendue")
                {
                    effect = "Suspendue " + string.Join(" ; ", reasons);
                }
                else
                {
                    effect = count > 0 ? Plural(count, "poste retiré des postes sains", "postes retirés des postes sains") + ", dont " + FrenchText.Integer(exclusive) + " par ce seul contrôle" : "Aucun poste signalé";
                    if (status == "Selon l’OU")
                    {
                        effect += " ; selon les règles de chaque OU";
                    }
                }
                var consequence = "";
                if (maskedSet.Count > 0)
                {
                    var why = status == "Suspendue" ? "pendant la suspension" : status == "Désactivée" ? "si la règle était activée" : "là où la règle est désactivée ou suspendue";
                    consequence = Plural(maskedSet.Count, "poste serait signalé", "postes seraient signalés") + " " + why;
                }
                else if (status is "Désactivée" or "Suspendue" && isRule)
                {
                    consequence = eligibleCount is > 0 ? "Aucun poste concerné dans les données disponibles" : "Donnée non mesurée : effet inconnu";
                }
                var unmeasured = eligibleCount is not int known || known == 0 || known < total;
                var missing = unmeasured && isRule;
                var observationState = count + maskedSet.Count > 0 ? "Problème" : unmeasured ? "Inconnu" : "Sain";
                if (count == 0 && missing && status is not ("Désactivée" or "Suspendue"))
                {
                    effect = "Non évalué sur toutes les données : aucun bon état déduit";
                }
                var hitKey = "rule:" + id;
                var maskedKey = "masked:" + id;
                Set(hitKey, active.Where(m => hitSet.Contains(m.Guid)));
                Set(maskedKey, active.Where(m => maskedSet.Contains(m.Guid)));
                labels[hitKey] = name + FrenchText.Colon + "postes signalés";
                labels[maskedKey] = name + FrenchText.Colon + "postes masqués";
                rows.Add(new FleetExplanationRow(id, name, status, count, effect, eligibleText, eligibleCount, exclusive, maskedSet.Count, consequence, observationState, missing,
                    Evidence(id, custom, visible, ping, inventory, inventories), hitSet.Count > 0 ? hitKey : null, maskedSet.Count > 0 ? maskedKey : null));
            }
            var activeRules = rows.Count(r => r.Status is "Activée" or "Selon l’OU" && (HealthRules.IsKnownRule(r.Id) || customRules.ContainsKey(r.Id)));
            var assessedCount = Math.Max(0, total - unknown);
            var summary = "Score = part des postes évalués sans problème" + FrenchText.Colon + FrenchText.Integer(healthy) + " / " + FrenchText.Integer(assessedCount) + ". "
                + Plural(unknown, "poste incomplet exclu", "postes incomplets exclus") + " du dénominateur, jamais considérés sains. Un poste touché par plusieurs règles compte une fois dans le score. "
                + "La colonne « Évaluables » donne, pour chaque règle, les postes dont la donnée est connue. Une règle désactivée ou suspendue ne retire aucun poste du score ; ce qu’elle aurait signalé reste affiché.";
            var policyRows = distinctPolicies.Select(p => new FleetPolicyRow(
                p.Scope.Length > 0 ? HealthRules.ScopeLabel(p.Scope, input.DomainDn) : "Domaine : règles par défaut", p.Count, p.Policy.Suspensions.Count(s => s.UntilUtc > now),
                "AD " + FrenchText.Integer(p.Policy.Thresholds.StaleDays) + " j · mot de passe " + FrenchText.Integer(p.Policy.Thresholds.PasswordDays) + " j · disque "
                + p.Policy.Thresholds.DiskFreeAlert + "/" + p.Policy.Thresholds.DiskFreeWarn + FrenchText.Nbsp + "%")).ToImmutableArray();
            return new FleetExplanation(summary, activeRules, rows.Count(r => r.Status == "Désactivée"), suspendedRules, maskedAll.Count, total, unknown, assessedCount, [.. rows], policyRows, input.Scope.Dn);
        }

        private FleetEvidence Evidence(string id, CustomHealthRule? custom, List<(FleetPoint Point, RuleHits Hits)> visible, MeasureFamilyFreshness ping, MeasureFamilyFreshness inventory, List<Machine> inventories)
        {
            var directory = DirectoryRules.Contains(id, StringComparer.Ordinal);
            var source = directory ? "Active Directory · base locale" : "Inventaire WMI / registre · base locale";
            if (id is "eos.ended" or "eos.soon")
            {
                source += " · table de cycle de vie Windows";
            }
            string observed;
            if (directory)
            {
                observed = "Source lue le " + CollectionClocks.Local(input.State.Directory.ReadAt, zone);
            }
            else if (inventory.Oldest is DateTimeOffset o && inventory.Newest is DateTimeOffset n)
            {
                observed = o == n ? "Source lue le " + CollectionClocks.Local(o, zone) : "Relevés de la source du " + CollectionClocks.Local(o, zone) + " au " + CollectionClocks.Local(n, zone);
            }
            else
            {
                observed = id is "unreachable" ? ping.Text : "Date de collecte inconnue";
            }
            var value = string.Join(" ; ", visible.Where(v => v.Point.Id == id && v.Point.Text.Length > 0).Select(v => v.Point.Text).Distinct());
            if (value.Length == 0)
            {
                value = "Aucune valeur détaillée disponible pour ce contrôle.";
            }
            var t = boardPolicy.Thresholds;
            var rule = id switch
            {
                "stale" => FrenchText.Integer(t.StaleDays) + " jours sans connexion AD",
                "pwdold" => FrenchText.Integer(t.PasswordDays) + " jours depuis le mot de passe machine",
                "lowdisk" => "Espace libre < " + t.DiskFreeAlert + FrenchText.Nbsp + "%",
                "disk.tight" => "Espace libre < " + t.DiskFreeWarn + FrenchText.Nbsp + "%",
                "uptime" => "Démarrage depuis plus de " + FrenchText.Integer(t.UptimeDays) + " jours",
                "memory" => "Mémoire utilisée > " + t.MemoryUsedWarn + FrenchText.Nbsp + "%",
                _ => custom is not null ? custom.Name : "Contrôle " + id,
            } + " ; voir les règles appliquées par OU pour les exceptions";
            var collection = directory
                ? "Lancez « Mettre à jour la base locale de l’OU » dans « Contrôles du parc » pour actualiser explicitement la lecture de cette OU."
                : "Lancez explicitement le relevé ping puis WMI de l’OU depuis « Contrôles du parc » ; rien n’est collecté depuis cette fenêtre.";
            _ = inventories;
            return new FleetEvidence(source, observed, value, rule, collection);
        }

        // ---------------------------------------------------------------- trends

        private void Trends(ImmutableArray<FleetSnapshot> history, FleetSnapshot current, int staleDays)
        {
            var days = new SortedDictionary<DateOnly, FleetFigures>();
            foreach (var s in history.Where(s => s.Kind == "daily"))
            {
                if (s.Day > today || s.Day < today.AddDays(-89))
                {
                    continue;
                }
                days.TryAdd(s.Day, s.Figures);
            }
            days[today] = current.Figures;
            var curves = new (string Key, Func<FleetFigures, int?> Figure, string Text)[]
            {
                ("fleet.trend", f => f.Problems, "postes à traiter"),
                ("fleet.trend.win10", f => f.Windows10, "postes sous Windows 10"),
                ("fleet.trend.stale", f => f.Stale, "postes sans connexion AD au-delà du seuil (actuellement " + FrenchText.Integer(staleDays) + " j)"),
                ("fleet.trend.lowdisk", f => f.LowDisk, "postes analysés avec C: presque plein"),
            };
            foreach (var (key, figure, text) in curves)
            {
                var points = days.Where(d => figure(d.Value) is int v && v >= 0).Select(d => new FleetTrendPoint(d.Key, d.Key.ToString("dd'/'MM", CultureInfo.InvariantCulture), figure(d.Value)!.Value)).ToImmutableArray();
                if (points.Length < 2)
                {
                    continue;
                }
                var note = "";
                if (key == "fleet.trend.stale")
                {
                    var other = days.Count(d => d.Value.StaleDays != staleDays);
                    if (other > 0)
                    {
                        note = " ; " + Plural(other, "jour compté avec un autre seuil", "jours comptés avec un autre seuil") + FrenchText.Colon + "ces jours ne se comparent pas directement";
                    }
                }
                FleetCatalog.TryGet(key, out var definition);
                entries[key] = new FleetEntry(key, definition!.Title, definition.Group, FleetDataKind.Timeline, FrenchText.Integer((long)points[^1].Value), points[^1].Value, null,
                    Plural(points.Length, "jour relevé", "jours relevés") + " sur 90" + FrenchText.Colon + text + note, null, null, null, [], points, null, null, null, true);
            }
        }

        // ---------------------------------------------------------------- probe widgets

        private void ProbeEntry(FleetLayoutItem item, List<Machine> active)
        {
            var probe = ProbeCatalog.Find(item.Key);
            var key = "probe:" + item.Key;
            if (probe is null)
            {
                entries[key] = new FleetEntry(key, item.Title ?? item.Key, item.Group, FleetDataKind.Distribution, "Sonde inconnue", null, null,
                    "Sonde absente du catalogue de cette version : retirez ce widget.", Tone.Off, null, null, [], [], null, null, null, false);
                return;
            }
            var readings = input.Probes.ByProbe.GetValueOrDefault(probe.Id) ?? ImmutableDictionary<Guid, ProbeReading>.Empty;
            var activeIds = active.Select(m => m.Guid).ToHashSet();
            var measure = ProbeCatalog.Measure(probe, readings.Where(r => activeIds.Contains(r.Key)).Select(r => (r.Key, r.Value)), item.Visual, now, input.ObservationMaxAgeDays);
            if (measure.Machines == 0)
            {
                entries[key] = new FleetEntry(key, item.Title ?? probe.Name, item.Group, FleetDataKind.Distribution, "À relever", null, null,
                    "Valeur non relevée sur ce périmètre : lancez le relevé WMI de l’OU, la sonde fait partie du plan des sondes figé au clic." + (probe.Slow ? " Sonde lente : collecte explicite sur une liste courte." : ""),
                    Tone.Off, null, "À calculer", [], [], 0, null, new FleetAction("collect", "Relever ce périmètre", "Prépare le relevé ping puis WMI des postes actifs de l’OU, avec confirmation."), false);
                return;
            }
            var coverage = Coverage(measure.Machines, active.Count, measure.Newest);
            var parts = new List<FleetPart>();
            foreach (var (label, value, guids) in measure.Items)
            {
                var targetsKey = key + "|" + label;
                Set(targetsKey, active.Where(m => guids.Contains(m.Guid)));
                parts.Add(new FleetPart(label, value, null, targetsKey, guids.Length));
            }
            Set(key, active.Where(m => readings.ContainsKey(m.Guid)));
            var lead = parts.OrderByDescending(p => p.Value).FirstOrDefault();
            var old = measure.Oldest is DateTimeOffset oldest && (now - oldest).TotalDays > 7;
            var detail = measure.Summary + " · " + coverage + (probe.Mode == "All" ? " · Un poste peut figurer dans plusieurs catégories." : "");
            entries[key] = new FleetEntry(key, item.Title ?? probe.Name, item.Group, measure.Numeric ? FleetDataKind.Series : FleetDataKind.Distribution,
                lead?.Label ?? "", null, ProbeCatalog.Unit(probe).Trim().Length > 0 ? ProbeCatalog.Unit(probe) : null, detail, old ? Tone.Off : null,
                FrenchText.Count(measure.Machines, "poste", "postes"), coverage, [.. parts], [], measure.Machines, key, null, true);
        }

        // ---------------------------------------------------------------- helpers

        private void Set(string key, IEnumerable<Machine> machines) => targets[key] = [.. machines.Select(m => m.Guid)];

        private void Add(string key, Machine m)
        {
            if (!targets.TryGetValue(key, out var list))
            {
                targets[key] = list = [];
            }
            list.Add(m.Guid);
        }

        private FleetPart Part(string label, int value, Tone? tone, string key) => new(label, value, tone, key, targets.GetValueOrDefault(key)?.Count ?? value);

        private void Entry(string key, string value, double? number, string? unit, string detail, Tone? tone, string? title = null, FleetAction? action = null, string? targetsKey = null, bool measured = true)
        {
            FleetCatalog.TryGet(key, out var definition);
            entries[key] = new FleetEntry(key, title ?? definition!.Title, definition!.Group, definition.Kind, value, number, unit, detail, tone, null, null, [], [],
                targetsKey is null ? null : targets.GetValueOrDefault(targetsKey)?.Count, targetsKey, action, measured);
        }

        private void Distribution(string key, string value, string detail, IReadOnlyList<(string Label, int Value, Tone? Tone)> items, string centerText, string? title = null, bool old = false, bool keepEmpty = false)
        {
            FleetCatalog.TryGet(key, out var definition);
            var parts = items.Where(i => keepEmpty || i.Value > 0).Select(i => Part(i.Label, i.Value, i.Tone, key + "|" + i.Label)).ToImmutableArray();
            entries[key] = new FleetEntry(key, title ?? definition!.Title, definition!.Group, FleetDataKind.Distribution, value, null, null, detail, old ? Tone.Off : null, centerText, null,
                parts, [], targets.GetValueOrDefault(key)?.Count, key, null, true);
        }

        private void Series(string key, string value, string detail, IReadOnlyList<(string Label, int Value, Tone? Tone)> items, bool old = false)
        {
            FleetCatalog.TryGet(key, out var definition);
            var parts = items.Select(i => Part(i.Label, i.Value, i.Tone, key + "|" + i.Label)).ToImmutableArray();
            entries[key] = new FleetEntry(key, definition!.Title, definition.Group, FleetDataKind.Series, value, null, null, detail, old ? Tone.Off : null, null, null,
                parts, [], targets.GetValueOrDefault(key)?.Count, key, null, true);
        }

        private string Coverage(int analysed, int total, DateTimeOffset? last) =>
            Plural(analysed, "poste analysé", "postes analysés") + " sur " + FrenchText.Integer(total)
            + (last is DateTimeOffset at ? ", le " + TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM", CultureInfo.InvariantCulture) : "");

        private static FleetAction Collect() => new("collect", "Relever ce périmètre", "Prépare la collecte des postes actifs de ce tableau de bord (ping puis WMI), avec confirmation.");

        private FleetTargetRow Row(Machine m) => new(
            m.Name, m.Dn, m.Guid, OuPath(m.Parent), m.Enabled ? "Activé" : "Désactivé", m.Os == "Système non renseigné" ? null : m.VersionLabel != "Version non lue" ? m.VersionLabel : m.Os,
            m.Logon, m.Presence, m.DiskFree is double d ? Math.Round(d, 1) : null, m.UptimeDays is double u ? (int)Math.Floor(u) : null, m.Model, m.User);

        private string OuPath(string parent)
        {
            try
            {
                var names = DistinguishedName.Parse(parent).Where(n => !n.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)).Select(n => n.Value).Reverse();
                return string.Join(FrenchText.PathSeparator, names);
            }
            catch (FormatException)
            {
                return parent;
            }
        }

        private static string EosLabel(Machine m) => m.Release.Label.Length > 0 ? m.Release.Label : m.Os;

        private static bool IsWindows10(Machine m) =>
            (m.Os.StartsWith("Windows 10", StringComparison.Ordinal) || m.Release.Name.StartsWith("Windows 10", StringComparison.Ordinal))
            && m.Release.Family is WindowsFamily.Pro or WindowsFamily.Enterprise;

        private static MeasureState InventoryState(WorkstationObservation? o) => o?.Inventory.State switch
        {
            MeasureState.Error => MeasureState.Error,
            MeasureState.Refused => MeasureState.Refused,
            MeasureState.Expired => MeasureState.Expired,
            MeasureState.Known => MeasureState.Expired,
            null => MeasureState.Absent,
            _ => MeasureState.Absent,
        };

        private static string RuleName(string id) => id switch
        {
            "created" => "Postes créés récemment",
            "unreachable" => "Sans réponse au ping",
            "wmi.failed" => "Lecture WMI non confirmée",
            "index.partial" => "Base locale incomplète",
            "cache.invalid" => "Relevés ignorés",
            "disabled" => "Comptes désactivés dans l’OU",
            _ => HealthRules.RuleName(id),
        };

        private static string RuleOf(string key)
        {
            var bar = key.IndexOf('|', StringComparison.Ordinal);
            return bar < 0 ? key : key[..bar];
        }

        private static List<(string Label, int Value)> Rank(IEnumerable<(string Label, int Value)> items) =>
            [.. items.OrderByDescending(i => i.Value).ThenBy(i => i.Label, StringComparer.Ordinal)];
    }

    /// <summary>« Ping et WMI répondent »… (Get-DomeniaFleetReachLabel): neither channel decides alone whether a workstation is reachable.</summary>
    public static string ReachLabel(string presence, MeasureState wmi)
    {
        var ping = presence == "En ligne" ? "yes" : presence == "Sans réponse" ? "no" : "";
        var cim = wmi is MeasureState.Known or MeasureState.Incomplete ? "yes" : wmi is MeasureState.Refused or MeasureState.Error ? "no" : "";
        return (ping, cim) switch
        {
            ("yes", "yes") => ReachNames[0],
            ("no", "yes") => ReachNames[1],
            ("yes", "no") => ReachNames[2],
            ("no", "no") => ReachNames[3],
            _ when ping.Length > 0 || cim.Length > 0 => ReachNames[4],
            _ => ReachNames[5],
        };
    }

    public static string WmiGroup(MeasureState state) => state switch
    {
        MeasureState.Known or MeasureState.Incomplete => WmiNames[0],
        MeasureState.Refused or MeasureState.Error => WmiNames[1],
        _ => WmiNames[2],
    };

    /// <summary>« 1 poste », « 3 postes »: the French plural (0 and 1 take the singular).</summary>
    public static string Plural(long n, string singular, string plural) => FrenchText.Integer(n) + " " + (n >= 2 ? plural : singular);
}
