using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Derives the local base of the simulation from the generated world (docs/ops/synchro.md § 7), with the sub-stream
/// « screen/synchro » of the seed only: the generated directory is the truth of the controller, and the base is what earlier
/// reads kept of it. The working OU « Postes » was read completely 12 minutes ago (the date of the session's cache); the
/// changes of the domain were read 3 days and 4 hours ago (checkpoint), so the objects changed since then are older versions in
/// the base, the objects created since are missing, a few identities seen by the census are missing (census gaps), a few objects
/// deleted since are still there, and the last complete reads recorded disappeared objects to verify. Exact counts, chosen by
/// shuffling candidates (never independent draws); dates relative to the reference of the world.
/// </summary>
public static class SimulatedSyncSeed
{
    public static readonly TimeSpan CheckpointAge = TimeSpan.FromHours(3 * 24 + 4);
    public const int ChangedSinceCheckpoint = 48;
    public const int CensusGapsFound = 11;
    public const int VisibleAgain = 3;
    public const int GhostWorkstations = 6;
    public const int TombstonedWorkstations = 4;
    public const int GhostUsers = 4;
    public const int PendingGhosts = 4;
    public const string SharedPath = @"\\SRV-FIC-01.example.local\Domenia$\releve-parc.json";

    private static readonly string[] OtherConsoles = [@"EXAMPLE\c.durand", @"EXAMPLE\adm-l.petit"];

    private static readonly Dictionary<string, string> SiteCodes = new(StringComparer.Ordinal)
    {
        ["Paris"] = "PAR",
        ["Lyon"] = "LYO",
        ["Marseille"] = "MRS",
        ["Lille"] = "LIL",
        ["Bordeaux"] = "BDX",
    };

    internal static void Fill(SimulatedSyncState state, SimulatedWorld world, SeededRandom random)
    {
        var reference = world.Reference;
        var directory = world.Directory;
        var root = directory.Domain.RootDn;
        var postes = directory.OrganizationalUnits.First(o => o.Name == SimulationProfile.WorkingOuName && SyncLocations.Same(DistinguishedName.Parent(o.DistinguishedName), root)).DistinguishedName;
        var postesReadAt = directory.ReadAt;
        var checkpointAt = reference - CheckpointAge;
        var created = new Dictionary<Guid, DateTimeOffset>();
        var managers = new Dictionary<Guid, string?>();
        var truth = new List<IndexRecord>(directory.Users.Length + directory.Computers.Length);
        foreach (var user in directory.Users)
        {
            truth.Add(SimulatedSyncReader.ToRecord(user, checkpointAt));
            created[user.ObjectGuid] = user.WhenCreated;
        }
        foreach (var computer in directory.Computers)
        {
            truth.Add(SimulatedSyncReader.ToRecord(computer, checkpointAt));
            created[computer.ObjectGuid] = computer.WhenCreated;
            managers[computer.ObjectGuid] = computer.ManagedByDn;
        }
        state.SetInvocation(NewGuid(random.Fork("invocation")).ToString("D"));

        // Checkpoint: the USN below which the base already holds the objects (48 objects changed since).
        var usns = truth.Select(t => t.Usn).Order().ToList();
        var checkpointUsn = usns[Math.Max(0, usns.Count - ChangedSinceCheckpoint - 1)];
        bool InPostes(IndexRecord r) => SyncLocations.InScope(r.Dn, postes);
        bool Stable(IndexRecord r) => r.Usn <= checkpointUsn && !InPostes(r);

        var users = truth.Where(t => t.Type == IndexObjectType.User && Stable(t) && t.Enabled && SyncLocations.Path(t.Dn).FirstOrDefault() == "Utilisateurs").ToList();
        var taken = new HashSet<Guid>();
        List<IndexRecord> Pick(IEnumerable<IndexRecord> candidates, string stream, int count)
        {
            var list = candidates.Where(c => !taken.Contains(c.ObjectGuid)).OrderBy(c => c.ObjectGuid.ToString("D"), StringComparer.Ordinal).ToList();
            random.Fork(stream).Shuffle(list);
            var chosen = list.Take(count).ToList();
            foreach (var c in chosen)
            {
                taken.Add(c.ObjectGuid);
            }
            return chosen;
        }

        var gaps = Pick(users, "gaps", CensusGapsFound);
        var visible = Pick(users, "visible", VisibleAgain);
        var unconfirmed = Pick(users, "unconfirmed", 1);
        var desktops = truth.Where(t => t.Type == IndexObjectType.Computer && t.Name.StartsWith("DESKTOP-", StringComparison.Ordinal)).Take(2).ToList();
        foreach (var d in desktops)
        {
            taken.Add(d.ObjectGuid);
        }
        var servers = truth.Where(t => t.Type == IndexObjectType.Computer && Stable(t) && SyncLocations.Path(t.Dn).FirstOrDefault() == "Serveurs").ToList();
        var earlierMoved = Pick(servers, "earlier-moved", 1);

        // Objects changed since the checkpoint (outside Postes, which was read 12 minutes ago): older versions in the base.
        var changed = truth.Where(t => t.Usn > checkpointUsn && !InPostes(t) && !taken.Contains(t.ObjectGuid)).ToList();
        var createdSince = changed.Where(t => created[t.ObjectGuid] > checkpointAt).Select(t => t.ObjectGuid).ToHashSet();
        var perturbable = changed.Where(t => !createdSince.Contains(t.ObjectGuid)).OrderBy(t => t.ObjectGuid.ToString("D"), StringComparer.Ordinal).ToList();
        random.Fork("changed").Shuffle(perturbable);
        var perturbation = new Dictionary<Guid, Func<IndexRecord, IndexRecord>>();
        var ous = directory.OrganizationalUnits.Select(o => o.DistinguishedName).ToList();
        var shape = random.Fork("changed/values");
        foreach (var (row, index) in perturbable.Select((r, i) => (r, i)))
        {
            Func<IndexRecord, IndexRecord>? change = index switch
            {
                < 5 => OtherPlace(row, ous, root, shape) is string dn ? r => r with { Dn = dn } : null,
                < 8 => r => r with { Name = OldName(r), Dn = DistinguishedName.Child("CN", OldName(r), DistinguishedName.Parent(r.Dn) ?? root) },
                < 16 => r => r with { Description = OldDescription(r, shape) },
                < 19 => r => r with { Enabled = !r.Enabled },
                _ => null,
            };
            var olderUsn = checkpointUsn - shape.Next(1, 500);
            var olderChange = checkpointAt - shape.Between(TimeSpan.FromDays(1), TimeSpan.FromDays(40));
            perturbation[row.ObjectGuid] = r => (change is null ? r : change(r)) with { Usn = olderUsn, WhenChanged = olderChange };
        }

        // Base rows.
        var rows = new Dictionary<Guid, IndexRecord>();
        foreach (var t in truth)
        {
            if (taken.Contains(t.ObjectGuid) && !earlierMoved.Any(e => e.ObjectGuid == t.ObjectGuid))
            {
                continue;
            }
            if (createdSince.Contains(t.ObjectGuid))
            {
                continue;
            }
            var row = t with { ObservedAt = InPostes(t) ? postesReadAt : checkpointAt };
            if (perturbation.TryGetValue(t.ObjectGuid, out var apply))
            {
                row = apply(row);
            }
            rows[row.ObjectGuid] = row;
        }

        // Objects deleted after the checkpoint, still in the base until a complete read of their branch.
        var departures = ous.First(o => SyncLocations.Name(o) == "Départs");
        var ghostNames = random.Fork("ghost-users");
        for (var i = 0; i < PendingGhosts; i++)
        {
            var name = PersonName(ghostNames);
            var guid = NewGuid(ghostNames);
            var dn = DistinguishedName.Child("CN", name, departures);
            var login = Login(name, i + 60);
            rows[guid] = new IndexRecord(guid, IndexObjectType.User, name, login, login + "@" + directory.Domain.DnsName, name, "Départ le " + FrenchText.ShortDate(DateOnly.FromDateTime((checkpointAt - TimeSpan.FromDays(20 + i)).UtcDateTime)),
                null, false, dn, checkpointAt - TimeSpan.FromDays(19 + i), checkpointUsn - 600 - i, null, LapsKind.None, null, checkpointAt);
            state.Tombstones[guid] = new Tombstone(guid, name, IndexObjectType.User, departures, checkpointAt + TimeSpan.FromHours(6 + 13 * i), i == 0);
        }
        state.SetRows(rows);

        // Disappeared objects recorded by the last complete reads (removed from the base, never declared deleted).
        var stamp = random.Fork("absences");
        var sites = directory.OrganizationalUnits.Where(o => SyncLocations.Same(DistinguishedName.Parent(o.DistinguishedName), postes) && SiteCodes.ContainsKey(o.Name)).Select(o => o.DistinguishedName).ToList();
        for (var i = 0; i < GhostWorkstations; i++)
        {
            var site = sites[stamp.Next(sites.Count)];
            var code = SiteCodes[SyncLocations.Name(site)];
            var name = "PC-" + code + "-" + (900 + i * 7 + stamp.Next(1, 6)).ToString("0000", CultureInfo.InvariantCulture);
            var guid = NewGuid(stamp);
            state.Absences.Add(new AbsenceRecord(guid, name, IndexObjectType.Computer, DistinguishedName.Child("CN", name, site), null, AbsenceStatus.NotSeen, postesReadAt, null, "", postes, state.Controller));
            if (i < TombstonedWorkstations)
            {
                state.Tombstones[guid] = new Tombstone(guid, name, IndexObjectType.Computer, site, reference - stamp.Between(TimeSpan.FromHours(20), TimeSpan.FromDays(6)), i == 1);
            }
        }
        var lyon = sites.FirstOrDefault(s => SyncLocations.Name(s) == "Lyon") ?? sites[0];
        foreach (var desktop in desktops)
        {
            var oldDn = DistinguishedName.Child("CN", desktop.Name, lyon);
            state.Absences.Add(new AbsenceRecord(desktop.ObjectGuid, desktop.Name, IndexObjectType.Computer, oldDn, null, AbsenceStatus.NotSeen, postesReadAt, null, "", postes, state.Controller));
        }
        foreach (var user in visible)
        {
            state.Absences.Add(new AbsenceRecord(user.ObjectGuid, user.Name, IndexObjectType.User, user.Dn, null, AbsenceStatus.NotSeen, checkpointAt, null, "", root, state.Controller));
        }
        for (var i = 0; i < GhostUsers; i++)
        {
            var name = PersonName(ghostNames);
            var guid = NewGuid(ghostNames);
            state.Absences.Add(new AbsenceRecord(guid, name, IndexObjectType.User, DistinguishedName.Child("CN", name, departures), null, AbsenceStatus.NotSeen, checkpointAt, null, "", root, state.Controller));
            state.Tombstones[guid] = new Tombstone(guid, name, IndexObjectType.User, departures, checkpointAt - TimeSpan.FromHours(8 + 9 * i), i == 2);
        }

        // Verifications done two days ago: two deletions proven, one move, one not found, one controller unavailable.
        var earlier = checkpointAt - TimeSpan.FromDays(7);
        var checkedAt = reference - TimeSpan.FromDays(2);
        for (var i = 0; i < 2; i++)
        {
            var name = PersonName(ghostNames);
            var guid = NewGuid(ghostNames);
            var record = new AbsenceRecord(guid, name, IndexObjectType.User, DistinguishedName.Child("CN", name, departures), null, AbsenceStatus.NotSeen, earlier, null, "", root, state.Controller);
            var tomb = new Tombstone(guid, name, IndexObjectType.User, departures, earlier - TimeSpan.FromDays(1 + i), false);
            state.Tombstones[guid] = tomb;
            state.Absences.Add(Checked(record, new AbsenceCheck(DomainRead.Read, null, DeletedProbe.Read, true, tomb.DeletedAt, tomb.LastKnownParent, false, null), checkedAt, state));
        }
        foreach (var server in earlierMoved)
        {
            var oldPlace = OtherPlace(server, ous, root, stamp) ?? server.Dn;
            var record = new AbsenceRecord(server.ObjectGuid, server.Name, IndexObjectType.Computer, oldPlace, null, AbsenceStatus.NotSeen, earlier, null, "", DistinguishedName.Parent(oldPlace) ?? root, state.Controller);
            state.Absences.Add(Checked(record, new AbsenceCheck(DomainRead.Read, server.Dn, DeletedProbe.NotRequested, false, null, null, false, server), checkedAt, state));
        }
        {
            var name = "PC-LIL-0" + stamp.Next(870, 899).ToString(CultureInfo.InvariantCulture);
            var guid = NewGuid(stamp);
            var site = sites.FirstOrDefault(s => SyncLocations.Name(s) == "Lille") ?? sites[0];
            var record = new AbsenceRecord(guid, name, IndexObjectType.Computer, DistinguishedName.Child("CN", name, site), null, AbsenceStatus.NotSeen, earlier, null, "", postes, state.Controller);
            state.Absences.Add(Checked(record, new AbsenceCheck(DomainRead.Read, null, DeletedProbe.Read, false, null, null, false, null), checkedAt, state));
        }
        foreach (var user in unconfirmed)
        {
            var record = new AbsenceRecord(user.ObjectGuid, user.Name, IndexObjectType.User, user.Dn, null, AbsenceStatus.NotSeen, earlier, null, "", root, state.Controller);
            state.Absences.Add(Checked(record, new AbsenceCheck(DomainRead.Unavailable, null, DeletedProbe.NotRequested, false, null, null, false, null), reference - TimeSpan.FromDays(1), state));
        }

        // Census gaps: identities of the last census missing from the base (eleven still exist, one was deleted since).
        foreach (var gap in gaps)
        {
            state.Gaps.Add(new CensusGapRecord(gap.ObjectGuid, gap.Dn, checkpointAt));
        }
        {
            var lille = ous.FirstOrDefault(o => SyncLocations.Name(o) == "Lille" && SyncLocations.Path(o).FirstOrDefault() == "Utilisateurs") ?? departures;
            var name = PersonName(ghostNames);
            state.Gaps.Add(new CensusGapRecord(NewGuid(ghostNames), DistinguishedName.Child("CN", name, lille), checkpointAt));
        }

        // Coverage lines and checkpoint.
        var serversOu = ous.First(o => SyncLocations.Name(o) == "Serveurs" && SyncLocations.Same(DistinguishedName.Parent(o), root));
        var parisUsers = ous.First(o => SyncLocations.Name(o) == "Paris" && SyncLocations.Path(o).FirstOrDefault() == "Utilisateurs");
        var lyonUsers = ous.First(o => SyncLocations.Name(o) == "Lyon" && SyncLocations.Path(o).FirstOrDefault() == "Utilisateurs");
        int Within(string dn) => rows.Values.Count(r => SyncLocations.InScope(r.Dn, dn));
        state.PutSyncState(new SyncStateEntry(SyncStateEntry.DirectoryKey, root, checkpointAt, "Subtree", false, rows.Count, state.Controller, checkpointUsn, state.InvocationId, null, 0));
        state.PutSyncState(new SyncStateEntry(SyncStateEntry.OuKey(postes), postes, postesReadAt, "Subtree", false, Within(postes), state.Controller, 0, state.InvocationId, null, 0));
        state.PutSyncState(new SyncStateEntry(SyncStateEntry.OuKey(parisUsers), parisUsers, reference - TimeSpan.FromHours(26), "Subtree", false, Within(parisUsers), state.Controller, 0, state.InvocationId, null, 0));
        state.PutSyncState(new SyncStateEntry(SyncStateEntry.OuKey(lyonUsers), lyonUsers, reference - TimeSpan.FromDays(9), "Subtree", false, Within(lyonUsers), "DC02." + directory.Domain.DnsName, 0, null, null, 0));
        var attemptAt = reference - TimeSpan.FromDays(2);
        state.PutSyncState(new SyncStateEntry(SyncStateEntry.AttemptPrefix + SyncStateEntry.OuKey(serversOu), serversOu, attemptAt, "Subtree", true, 9, state.Controller, 0, state.InvocationId, "serveur", 120));
        state.Checkpoint = new SyncCheckpoint(state.Controller, state.InvocationId, checkpointUsn, checkpointAt, rows.Count, root);
        state.Partial = new PartialMarker(attemptAt, 9, "serveur", 120, serversOu);
        state.LastBackupAt = reference - TimeSpan.FromMinutes(47);

        // Associations of the base: workstations and the user named in their « managedBy ».
        var loginByDn = directory.Users.ToDictionary(u => u.DistinguishedName, u => u.SamAccountName, StringComparer.OrdinalIgnoreCase);
        foreach (var computer in directory.Computers.Where(c => c.ManagedByDn is not null && rows.ContainsKey(c.ObjectGuid)))
        {
            if (loginByDn.TryGetValue(computer.ManagedByDn!, out var login))
            {
                Link(state, computer.Name, login);
            }
        }

        SeedSnapshots(state, world, random.Fork("snapshots"), postes, root, created);
        SeedPark(state, world, random.Fork("park"), postes, managers, loginByDn);
    }

    private static AbsenceRecord Checked(AbsenceRecord record, AbsenceCheck check, DateTimeOffset at, SimulatedSyncState state)
    {
        var outcome = SyncAbsences.Resolve(record, check, state.Zone);
        return record with { Status = outcome.Status, FoundDn = outcome.FoundDn, Detail = outcome.Detail, CheckedAt = at };
    }

    private static void Link(SimulatedSyncState state, string computer, string login)
    {
        var key = SyncPark.Key(computer);
        if (!state.LinksByComputer.TryGetValue(key, out var users))
        {
            users = new SortedSet<string>(StringComparer.Ordinal);
            state.LinksByComputer[key] = users;
        }
        users.Add(login);
        var userKey = login.ToLowerInvariant();
        if (!state.LinksByUser.TryGetValue(userKey, out var computers))
        {
            computers = new SortedSet<string>(StringComparer.Ordinal);
            state.LinksByUser[userKey] = computers;
        }
        computers.Add(computer);
    }

    /// <summary>
    /// Three dated snapshots: OU Postes 21 and 7 days ago (complete coverage; « before the Windows 11 migration » holds Windows 10
    /// workstations), and the whole domain 26 days ago (coverage incomplete). Their lines are the base of today taken back in
    /// time: objects created since are left out, objects deleted since are put back, a few moved, renamed or changed.
    /// </summary>
    private static void SeedSnapshots(SimulatedSyncState state, SimulatedWorld world, SeededRandom random, string postes, string root, Dictionary<Guid, DateTimeOffset> created)
    {
        var reference = world.Reference;
        var zone = world.TimeZone;
        var postesLines = state.Rows.Values.Where(r => SyncLocations.InScope(r.Dn, postes)).OrderBy(r => r.Dn, StringComparer.OrdinalIgnoreCase).ToList();
        var ghostLines = state.Absences.Where(a => SyncLocations.InScope(a.LastDn, postes) && a.Status == AbsenceStatus.NotSeen)
            .Select(a => new SnapshotLine(a.ObjectGuid, a.Type, a.Name, a.Name + "$", a.Name.ToLowerInvariant() + "." + world.Directory.Domain.DnsName, null, null, "Windows 11 Entreprise", true, a.LastDn))
            .ToList();
        var sites = world.Directory.OrganizationalUnits.Where(o => SyncLocations.Same(DistinguishedName.Parent(o.DistinguishedName), postes) && SiteCodes.ContainsKey(o.Name)).Select(o => o.DistinguishedName).ToList();
        var movers = postesLines.Where(r => r.Enabled).OrderBy(r => r.ObjectGuid.ToString("D"), StringComparer.Ordinal).ToList();
        random.Fork("movers").Shuffle(movers);

        SnapshotLine Moved(SnapshotLine line, int salt)
        {
            var parent = DistinguishedName.Parent(line.Dn);
            var other = sites.Where(s => !SyncLocations.Same(s, parent)).ToList();
            return other.Count == 0 ? line : line with { Dn = DistinguishedName.Child("CN", line.Name, other[salt % other.Count]) };
        }

        SnapshotRecord Build(string id, string label, DateTimeOffset at, int moves, int descriptions, int flips, int windows10, IEnumerable<SnapshotLine> extra)
        {
            var lines = postesLines.Where(r => !created.TryGetValue(r.ObjectGuid, out var c) || c <= at).Select(SnapshotLine.From).ToDictionary(l => l.ObjectGuid);
            foreach (var line in ghostLines.Concat(extra))
            {
                lines[line.ObjectGuid] = line;
            }
            var n = 0;
            foreach (var mover in movers.Where(m => lines.ContainsKey(m.ObjectGuid)).Take(moves + descriptions + flips))
            {
                var line = lines[mover.ObjectGuid];
                lines[mover.ObjectGuid] = n < moves ? Moved(line, n) : n < moves + descriptions ? line with { Description = "Poste de prêt" } : line with { Enabled = !line.Enabled };
                n++;
            }
            foreach (var line in lines.Values.Where(l => (l.Extra ?? "").StartsWith("Windows 11", StringComparison.Ordinal)).OrderBy(l => l.ObjectGuid.ToString("D"), StringComparer.Ordinal).Take(windows10).ToList())
            {
                lines[line.ObjectGuid] = line with { Extra = "Windows 10 Entreprise" + (line.Extra!.Contains(" / ", StringComparison.Ordinal) ? line.Extra[line.Extra.IndexOf(" / ", StringComparison.Ordinal)..] : "") };
            }
            var coverageAt = at - TimeSpan.FromMinutes(35);
            var ordered = lines.Values.OrderBy(l => l.Dn, StringComparer.OrdinalIgnoreCase).ToImmutableArray();
            return new SnapshotRecord(id, label, root, postes, true, at, SnapshotCoverageState.Complete, coverageAt, "Postes",
                "Couverture" + SyncText.C + "lecture complète du " + SyncText.LocalDateTime(coverageAt, zone) + " (Postes).", ordered, SyncSnapshots.Fingerprint(ordered));
        }

        var older = random.Fork("older");
        var olderGhosts = Enumerable.Range(0, 3).Select(i =>
        {
            var site = sites[older.Next(sites.Count)];
            var name = "PC-" + SiteCodes[SyncLocations.Name(site)] + "-" + (850 + i * 5 + older.Next(1, 4)).ToString("0000", CultureInfo.InvariantCulture);
            return new SnapshotLine(NewGuid(older), IndexObjectType.Computer, name, name + "$", name.ToLowerInvariant() + "." + world.Directory.Domain.DnsName, null, null, "Windows 10 Entreprise", true, DistinguishedName.Child("CN", name, site));
        }).ToList();
        state.Snapshots.Add(Build(Id(random, "s1"), "Avant la migration Windows 11", Day(reference, 21, 9, zone), 6, 4, 2, 20, olderGhosts));
        state.Snapshots.Add(Build(Id(random, "s2"), "Contrôle hebdomadaire", Day(reference, 7, 8, zone), 3, 2, 1, 0, []));

        // The whole domain, 26 days ago, while a pass had stopped early: coverage not proven.
        var domainAt = Day(reference, 26, 17, zone);
        var domainLines = state.Rows.Values.Where(r => !created.TryGetValue(r.ObjectGuid, out var c) || c <= domainAt).Select(SnapshotLine.From).ToDictionary(l => l.ObjectGuid);
        foreach (var absence in state.Absences.Where(a => a.Type == IndexObjectType.User && a.Status is AbsenceStatus.NotSeen or AbsenceStatus.Deleted))
        {
            domainLines[absence.ObjectGuid] = new SnapshotLine(absence.ObjectGuid, IndexObjectType.User, absence.Name, null, null, absence.Name, null, null, false, absence.LastDn);
        }
        var described = domainLines.Values.Where(l => l.Type == IndexObjectType.User && l.Enabled).OrderBy(l => l.ObjectGuid.ToString("D"), StringComparer.Ordinal).ToList();
        random.Fork("domain").Shuffle(described);
        foreach (var line in described.Take(10))
        {
            domainLines[line.ObjectGuid] = line with { Description = "Arrivée prévue" };
        }
        var domainOrdered = domainLines.Values.OrderBy(l => l.Dn, StringComparer.OrdinalIgnoreCase).ToImmutableArray();
        state.Snapshots.Add(new SnapshotRecord(Id(random, "s3"), "Domaine · fin septembre", root, root, true, domainAt, SnapshotCoverageState.Partial, null, null,
            "Couverture" + SyncText.C + "la dernière lecture de ce périmètre était incomplète" + SyncText.Semi + " ajouts et disparitions non concluants.", domainOrdered, SyncSnapshots.Fingerprint(domainOrdered)));
    }

    /// <summary>
    /// Park survey kept by the base: 70 % of the active workstations of Postes (those inactive for more than 90 days are set
    /// aside), with the user seen, and a shared survey of two other consoles, partly more recent.
    /// </summary>
    private static void SeedPark(SimulatedSyncState state, SimulatedWorld world, SeededRandom random, string postes, Dictionary<Guid, string?> managers, Dictionary<string, string> loginByDn)
    {
        var reference = world.Reference;
        var active = state.Rows.Values.Where(r => r.Type == IndexObjectType.Computer && r.Enabled && SyncLocations.InScope(r.Dn, postes)).OrderBy(r => r.Name, StringComparer.Ordinal).ToList();
        var dormant = active.Where(r => r.LastLogon is null || r.LastLogon < reference - TimeSpan.FromDays(90)).ToList();
        state.Dormants = dormant.Count;
        var candidates = active.Except(dormant).ToList();
        random.Fork("order").Shuffle(candidates);
        var surveyed = candidates.Take(candidates.Count * 70 / 100).ToList();
        var others = candidates.Skip(surveyed.Count).ToList();
        var people = state.Rows.Values.Where(r => r.Type == IndexObjectType.User && r.Enabled && r.Login is not null && SyncLocations.Path(r.Dn).FirstOrDefault() == "Utilisateurs")
            .Select(r => r.Login!).Order(StringComparer.Ordinal).ToList();
        var draws = random.Fork("entries");
        ParkEntry Entry(IndexRecord computer, string probedBy, TimeSpan minAge, TimeSpan maxAge)
        {
            var roll = draws.Next(100);
            var status = roll < 60 ? ParkStatus.Session : roll < 85 ? ParkStatus.Empty : roll < 97 ? ParkStatus.Unreachable : ParkStatus.Refused;
            string? user = null;
            if (status == ParkStatus.Session)
            {
                user = managers.TryGetValue(computer.ObjectGuid, out var manager) && manager is not null && loginByDn.TryGetValue(manager, out var login) ? login : people[draws.Next(people.Count)];
            }
            var attempts = status switch
            {
                ParkStatus.Unreachable => draws.Next(1, 4),
                ParkStatus.Refused => 1,
                _ => 0,
            };
            return new ParkEntry(computer.Name, reference - draws.Between(minAge, maxAge), status, user, attempts, probedBy);
        }
        var park = new Dictionary<string, ParkEntry>(StringComparer.Ordinal);
        foreach (var computer in surveyed)
        {
            park[SyncPark.Key(computer.Name)] = Entry(computer, state.Operator, TimeSpan.FromMinutes(40), TimeSpan.FromDays(9));
        }
        state.SetPark(park);
        var shared = new Dictionary<string, ParkEntry>(StringComparer.Ordinal);
        var share = random.Fork("shared");
        foreach (var (entry, index) in park.Values.OrderBy(e => e.Computer, StringComparer.Ordinal).Take(30).Select((e, i) => (e, i)))
        {
            shared[SyncPark.Key(entry.Computer)] = index < 12
                ? entry with { LastProbe = Min(reference - TimeSpan.FromMinutes(10), entry.LastProbe + share.Between(TimeSpan.FromHours(2), TimeSpan.FromDays(2))), ProbedBy = OtherConsoles[index % 2] }
                : entry with { LastProbe = entry.LastProbe - share.Between(TimeSpan.FromHours(1), TimeSpan.FromDays(3)) };
        }
        foreach (var (computer, index) in others.Take(18).Select((c, i) => (c, i)))
        {
            shared[SyncPark.Key(computer.Name)] = Entry(computer, OtherConsoles[index % 2], TimeSpan.FromHours(3), TimeSpan.FromDays(5));
        }
        state.SetSharedFile(shared);
        state.SharedPath = SharedPath;
        state.SharedLastSync = reference - TimeSpan.FromDays(2) - TimeSpan.FromHours(3);
    }

    private static DateTimeOffset Min(DateTimeOffset a, DateTimeOffset b) => a < b ? a : b;

    /// <summary>A day <paramref name="daysAgo"/> before the reference, at a fixed local hour (UTC instant).</summary>
    private static DateTimeOffset Day(DateTimeOffset reference, int daysAgo, int hour, TimeZoneInfo zone)
    {
        var day = LocalDays.DateOf(reference - TimeSpan.FromDays(daysAgo), zone);
        return LocalDays.StartOf(day, zone) + TimeSpan.FromHours(hour) + TimeSpan.FromMinutes(12);
    }

    private static string Id(SeededRandom random, string name)
    {
        var r = random.Fork("id/" + name);
        return r.NextUInt64().ToString("x16", CultureInfo.InvariantCulture) + r.NextUInt64().ToString("x16", CultureInfo.InvariantCulture);
    }

    /// <summary>Another OU of the same top-level branch, for an object that was elsewhere before (null when there is none).</summary>
    private static string? OtherPlace(IndexRecord row, List<string> ous, string root, SeededRandom random)
    {
        var parent = DistinguishedName.Parent(row.Dn);
        var top = TopLevel(row.Dn, root);
        if (parent is null || top is null)
        {
            return null;
        }
        var candidates = ous.Where(o => !SyncLocations.Same(o, parent) && SyncLocations.InScope(o, top) && SyncLocations.Name(o) != "Départs").Order(StringComparer.OrdinalIgnoreCase).ToList();
        return candidates.Count == 0 ? null : DistinguishedName.Child("CN", SyncLocations.Name(row.Dn), candidates[random.Next(candidates.Count)]);
    }

    private static string? TopLevel(string dn, string root)
    {
        string? current = dn;
        while (current is not null)
        {
            var parent = DistinguishedName.Parent(current);
            if (parent is not null && SyncLocations.Same(parent, root))
            {
                return current;
            }
            current = parent;
        }
        return null;
    }

    private static string OldName(IndexRecord row) => row.Type == IndexObjectType.Computer
        ? row.Name + "-OLD"
        : row.Name.Contains(' ', StringComparison.Ordinal) ? row.Name[(row.Name.IndexOf(' ', StringComparison.Ordinal) + 1)..] + ", " + row.Name[..row.Name.IndexOf(' ', StringComparison.Ordinal)] : row.Name + " (ancien)";

    private static string OldDescription(IndexRecord row, SeededRandom random)
    {
        string[] texts = row.Type == IndexObjectType.Computer
            ? ["Serveur à décommissionner", "Ancienne salle serveur", "Machine de recette"]
            : ["Congé de longue durée", "Mission à Lyon", "Stagiaire", "Mutation prévue"];
        return texts[random.Next(texts.Length)];
    }

    private static string PersonName(SeededRandom random)
    {
        var female = random.Chance(50);
        var first = female ? FrenchNames.Female[random.Next(FrenchNames.Female.Length)] : FrenchNames.Male[random.Next(FrenchNames.Male.Length)];
        return first + " " + FrenchNames.Surnames[random.Next(FrenchNames.Surnames.Length)];
    }

    private static string Login(string name, int salt)
    {
        var space = name.IndexOf(' ', StringComparison.Ordinal);
        var first = space > 0 ? name[..space] : name;
        var last = space > 0 ? name[(space + 1)..] : name;
        var initials = string.Concat(first.Split('-', StringSplitOptions.RemoveEmptyEntries).Select(p => char.ToLowerInvariant(p[0])));
        var clean = new string(FrenchText.Fold(last).Where(char.IsAsciiLetterOrDigit).ToArray());
        return initials + "." + clean + (salt % 7 == 0 ? "2" : "");
    }

    /// <summary>A GUID from the stream (version 4 bits set, deterministic).</summary>
    public static Guid NewGuid(SeededRandom random)
    {
        Span<byte> bytes = stackalloc byte[16];
        BitConverter.TryWriteBytes(bytes[..8], random.NextUInt64());
        BitConverter.TryWriteBytes(bytes[8..], random.NextUInt64());
        bytes[7] = (byte)((bytes[7] & 0x0F) | 0x40);
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);
        return new Guid(bytes);
    }
}
