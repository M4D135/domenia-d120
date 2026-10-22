using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// The association store of the simulation, derived from the generated world only (docs/PLATFORM.md § 4): the named sub-stream
/// « screen/relations » of the seed, the reference date and the time zone. Exact populations are chosen by shuffles, never by
/// independent draws, so the figures of the screen depend only on the seed: declared assignments, observed consoles (with
/// exactly <see cref="Contradictions"/> workstations where the session and the assignment name different accounts), history
/// relevés, an import batch (« Annuler l’import »), clues, remote sessions on servers, legacy rows without GUID (two of them for
/// a recycled workstation name) and orphan links (some of them protected); <see cref="UnassignedShare"/> percent of the
/// workstations have no seeded row, for an import or a harvest. The journal holds the import, a few declarations, a removal
/// still restorable and one already restored.
/// </summary>
internal static class SimulatedRelationSeed
{
    public const int Contradictions = 9;
    public const int ImportedRows = 24;
    public const int Clues = 10;
    public const int RemoteSessions = 12;
    public const int LegacyRows = 14;
    public const int OrphanRows = 11;
    public const int ProtectedOrphans = 3;

    /// <summary>
    /// Share of the workstations (percent) left without any seeded association: an import or a harvest of the controller journal
    /// finds them (more than one batch of 64 new couples), as on a parc where the relations are being built.
    /// </summary>
    public const int UnassignedShare = 30;

    private static readonly string[] HistorySources =
    [
        "Journal du contrôleur 4624",
        "Historique LogonUI (dernier utilisateur)",
        "Profils du poste (Win32_UserProfile)",
        "Journal du contrôleur 4624",
    ];

    public sealed record Seed(ImmutableDictionary<string, StoredRelation> Store, ImmutableList<RelationJournalRecord> Journal, string ImportBatch);

    public static Seed Build(SimulatedWorld world, DirectorySnapshot directory, SeededRandom random)
    {
        ArgumentNullException.ThrowIfNull(world);
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(random);
        var now = world.Reference;
        var netbios = directory.Domain.NetbiosName;
        var people = directory.Users
            .Where(u => u.Department is not null && !AdValues.IsDisabled(u.UserAccountControl) && u.Office is not null && u.AdminCount != 1)
            .ToList();
        var peopleBySite = people.GroupBy(u => u.Office!, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.ToList(), StringComparer.Ordinal);
        var byDn = directory.Users.ToDictionary(u => u.DistinguishedName, StringComparer.OrdinalIgnoreCase);
        var admins = directory.Users.Where(u => u.SamAccountName.StartsWith("adm-", StringComparison.Ordinal)).ToList();
        var declarants = admins.Select(a => netbios + "\\" + a.SamAccountName).ToList();
        var workstations = directory.Computers
            .Where(c => c.Name.StartsWith("PC-", StringComparison.Ordinal) || c.Name.StartsWith("PT-", StringComparison.Ordinal))
            .Where(c => !AdValues.IsDisabled(c.UserAccountControl) && c.DistinguishedName.Contains("OU=Postes", StringComparison.OrdinalIgnoreCase))
            .ToList();
        var julien = directory.Users.First(u => u.SamAccountName == SimulationProfile.PersonLogin);
        var camille = directory.Users.First(u => u.GivenName == "Camille" && u.Surname == "Bernard");
        var store = ImmutableDictionary.CreateBuilder<string, StoredRelation>(StringComparer.Ordinal);
        var journal = new List<RelationJournalRecord>();
        var ids = random.Fork("journal/ids");
        string NewId() => ids.NextUInt64().ToString("x16", CultureInfo.InvariantCulture) + ids.NextUInt64().ToString("x16", CultureInfo.InvariantCulture);
        DateTimeOffset Ago(TimeSpan span) => WritePlans.TruncateToSecond(now - span);
        void Put(StoredRelation relation) => store[RelationRules.Key(relation)] = relation;

        // Owner of each workstation: the person named in managedBy, otherwise a person of the same site.
        var owners = new Dictionary<Guid, DirectoryUser>();
        var ownerDraw = random.Fork("owners");
        foreach (var computer in workstations)
        {
            var site = SiteOf(computer.Name);
            if (computer.ManagedByDn is not null && byDn.TryGetValue(computer.ManagedByDn, out var managed))
            {
                owners[computer.ObjectGuid] = managed;
            }
            else if (site is not null && peopleBySite.TryGetValue(site, out var local) && local.Count > 0)
            {
                owners[computer.ObjectGuid] = ownerDraw.Pick(local);
            }
        }

        // Julien Martin and Camille Bernard get fixed workstations of their site, so the screen opens on a rich example.
        var parisDesktops = workstations.Where(c => c.Name.StartsWith("PC-PAR-", StringComparison.Ordinal)).OrderBy(c => c.Name, StringComparer.Ordinal).ToList();
        var parisLaptops = workstations.Where(c => c.Name.StartsWith("PT-PAR-", StringComparison.Ordinal)).OrderBy(c => c.Name, StringComparer.Ordinal).ToList();
        var lyonDesktops = workstations.Where(c => c.Name.StartsWith("PC-LYO-", StringComparison.Ordinal)).OrderBy(c => c.Name, StringComparer.Ordinal).ToList();
        var julienPc = parisDesktops[7];
        var julienLaptop = parisLaptops[2];
        var julienOld = parisDesktops[31];
        var camillePc = lyonDesktops[3];
        owners[julienPc.ObjectGuid] = julien;
        owners[julienLaptop.ObjectGuid] = julien;
        owners[camillePc.ObjectGuid] = camille;
        var reserved = new HashSet<Guid> { julienPc.ObjectGuid, julienLaptop.ObjectGuid, julienOld.ObjectGuid, camillePc.ObjectGuid };

        // Workstations without any seeded row, chosen by a shuffle; the import batch below takes some of them.
        var candidates = workstations.Where(c => owners.ContainsKey(c.ObjectGuid) && !reserved.Contains(c.ObjectGuid)).OrderBy(c => c.Name, StringComparer.Ordinal).ToList();
        random.Fork("unassigned").Shuffle(candidates);
        var unassigned = candidates.Take(candidates.Count * UnassignedShare / 100).Select(c => c.ObjectGuid).ToHashSet();
        var order = workstations.Where(c => owners.ContainsKey(c.ObjectGuid) && !reserved.Contains(c.ObjectGuid) && !unassigned.Contains(c.ObjectGuid)).ToList();
        random.Fork("order").Shuffle(order);
        var declaredCount = order.Count * 45 / 100;
        var declared = order.Take(declaredCount).ToList();
        var dates = random.Fork("dates");
        var details = random.Fork("details");

        StoredRelation Relation(DirectoryUser user, DirectoryComputer computer, RelationKind kind, string source, DateTimeOffset when, string? text, bool verified, string? declarant, string? batch = null) =>
            new(user.SamAccountName, user.ObjectGuid, user.DistinguishedName, computer.Name, computer.ObjectGuid, computer.DistinguishedName,
                kind, source, when, text, verified, declarant, batch);

        // Declared assignments (« Saisie manuelle »), several months old.
        foreach (var computer in declared)
        {
            var when = Ago(dates.Between(TimeSpan.FromDays(25), TimeSpan.FromDays(700)));
            Put(Relation(owners[computer.ObjectGuid], computer, RelationKind.Assignment, RelationRules.ManualSource, when,
                "Association confirmée dans Relations depuis Recherche AD manuelle.", true, details.Pick(declarants)));
        }

        // Observed consoles in the last 14 days; exactly « Contradictions » declared workstations show another account.
        var observedPool = order.Skip(declaredCount / 3).ToList();
        random.Fork("observed").Shuffle(observedPool);
        var observed = observedPool.Take(order.Count * 58 / 100).ToList();
        var contradicted = declared.Where(c => observed.Contains(c)).Take(Contradictions - 1).Select(c => c.ObjectGuid).ToHashSet();
        foreach (var computer in observed)
        {
            var owner = owners[computer.ObjectGuid];
            var user = owner;
            if (contradicted.Contains(computer.ObjectGuid))
            {
                var site = SiteOf(computer.Name)!;
                var others = peopleBySite[site].Where(p => p.ObjectGuid != owner.ObjectGuid).ToList();
                user = details.Pick(others);
            }
            var when = Ago(dates.Between(TimeSpan.FromMinutes(20), TimeSpan.FromDays(14)));
            Put(Relation(user, computer, RelationKind.Console, RelationRules.ConsoleSource, when,
                "Lecture de la console à cette date ; sessions RDP non recensées. Aucun ancien lien supprimé.", true, null));
        }

        // History relevés (journal of the controller, LogonUI, profiles), older.
        var historyPool = order.ToList();
        random.Fork("history").Shuffle(historyPool);
        foreach (var computer in historyPool.Take(order.Count * 48 / 100))
        {
            var owner = owners[computer.ObjectGuid];
            var when = Ago(dates.Between(TimeSpan.FromDays(16), TimeSpan.FromDays(300)));
            Put(Relation(owner, computer, RelationKind.History, details.Pick(HistorySources), when,
                "Ouverture de session relevée ; ne prouve pas une présence actuelle.", true, null));
        }

        // The fixed examples.
        Put(Relation(julien, julienPc, RelationKind.Assignment, RelationRules.ManualSource, Ago(TimeSpan.FromDays(212)),
            "Association confirmée dans Relations depuis Recherche AD manuelle.", true, declarants[1]));
        Put(Relation(julien, julienPc, RelationKind.Console, RelationRules.ConsoleSource, Ago(TimeSpan.FromMinutes(47)),
            "Lecture de la console à cette date ; sessions RDP non recensées. Aucun ancien lien supprimé.", true, null));
        Put(Relation(julien, julienLaptop, RelationKind.Console, RelationRules.ConsoleSource, Ago(TimeSpan.FromHours(26)),
            "Lecture de la console à cette date ; sessions RDP non recensées. Aucun ancien lien supprimé.", true, null));
        Put(Relation(julien, julienLaptop, RelationKind.History, "Journal du contrôleur 4624", Ago(TimeSpan.FromDays(9)),
            "Ouverture de session relevée ; ne prouve pas une présence actuelle.", true, null));
        Put(Relation(julien, julienOld, RelationKind.History, "Profils du poste (Win32_UserProfile)", Ago(TimeSpan.FromDays(240)),
            "Profil local présent, dernière utilisation relevée ; ne prouve pas une présence actuelle.", true, null));
        var colleague = peopleBySite["Paris"].First(p => p.Department == "Informatique" && p.ObjectGuid != julien.ObjectGuid);
        Put(Relation(colleague, julienPc, RelationKind.History, "Historique LogonUI (dernier utilisateur)", Ago(TimeSpan.FromDays(33)),
            "Ouverture de session relevée ; ne prouve pas une présence actuelle.", true, null));
        Put(Relation(camille, camillePc, RelationKind.Assignment, RelationRules.ManualSource, Ago(TimeSpan.FromDays(400)),
            "Association confirmée dans Relations depuis Recherche AD manuelle.", true, declarants[2]));
        var camilleNeighbour = peopleBySite["Lyon"].First(p => p.Department == "Commercial" && p.ObjectGuid != camille.ObjectGuid);
        Put(Relation(camilleNeighbour, camillePc, RelationKind.Console, RelationRules.ConsoleSource, Ago(TimeSpan.FromHours(3)),
            "Lecture de la console à cette date ; sessions RDP non recensées. Aucun ancien lien supprimé.", true, null));

        // Import batch of GLPI, six days ago, on workstations without stored association.
        var batchAt = Ago(TimeSpan.FromDays(6) + TimeSpan.FromHours(3));
        var batch = RelationImport.BatchId("5eedb47c" + random.Fork("batch").NextUInt64().ToString("x16", CultureInfo.InvariantCulture), batchAt);
        var linked = store.Values.Where(r => r.ComputerGuid is not null).Select(r => r.ComputerGuid!.Value).ToHashSet();
        // Workstations without any stored association (Domenia 1: an import never replaces one), north and south-west sites first.
        var importable = workstations.Where(c => owners.ContainsKey(c.ObjectGuid) && !linked.Contains(c.ObjectGuid) && !reserved.Contains(c.ObjectGuid))
            .OrderBy(c => c.Name.Contains("-LIL-", StringComparison.Ordinal) || c.Name.Contains("-BDX-", StringComparison.Ordinal) ? 0 : 1)
            .ThenBy(c => c.Name, StringComparer.Ordinal).Take(ImportedRows).ToList();
        var record = 0;
        foreach (var computer in importable)
        {
            record++;
            var owner = owners[computer.ObjectGuid];
            var inventoried = Ago(TimeSpan.FromDays(7) + dates.Between(TimeSpan.FromHours(1), TimeSpan.FromDays(20)));
            var text = "Lot d’import " + batch + ". Importé depuis glpi-ordinateurs.csv, enregistrement " + record.ToString(CultureInfo.InvariantCulture)
                + ". Numéro de série GLPI" + FrenchText.Colon + "CZ" + details.Next(10_000_000, 99_999_999).ToString(CultureInfo.InvariantCulture) + ".";
            var relation = Relation(owner, computer, RelationKind.Imported, "Import GLPI", inventoried, text, true, declarants[0], batch);
            Put(relation);
            journal.Add(new RelationJournalRecord(NewId(), RelationJournalAction.Added, batchAt, declarants[0], "Import GLPI glpi-ordinateurs.csv (lot " + batch + ").", RelationRules.Key(relation), relation));
        }

        // Clues: inventory lines and mentions, never an observed session.
        var cluePool = workstations.Where(c => owners.ContainsKey(c.ObjectGuid) && !reserved.Contains(c.ObjectGuid) && !unassigned.Contains(c.ObjectGuid)).ToList();
        random.Fork("clues").Shuffle(cluePool);
        foreach (var computer in cluePool.Take(Clues))
        {
            Put(Relation(owners[computer.ObjectGuid], computer, RelationKind.Hint, "Inventaire du poste", Ago(dates.Between(TimeSpan.FromDays(2), TimeSpan.FromDays(40))),
                "Utilisateur déclaré dans l’inventaire logiciel du poste ; aucune session observée.", false, null));
        }

        // Remote sessions of administration accounts on member servers.
        var servers = directory.Computers.Where(c => c.Name.StartsWith("SRV-", StringComparison.Ordinal)).OrderBy(c => c.Name, StringComparer.Ordinal).ToList();
        var remote = random.Fork("remote");
        for (var i = 0; i < RemoteSessions && admins.Count > 0; i++)
        {
            var admin = admins[i % admins.Count];
            var server = servers[remote.Next(servers.Count)];
            Put(Relation(admin, server, RelationKind.RemoteSession, "Session distante WTS (RDP)", Ago(remote.Between(TimeSpan.FromHours(1), TimeSpan.FromDays(12))),
                "Session de bureau à distance lue sur le serveur ; une observation ne vaut pas affectation.", true, null));
        }

        // Legacy rows of Domenia 1 before RC1.14: names only. Two of them predate the current object of their name.
        var legacy = random.Fork("legacy");
        var legacyPool = workstations.Where(c => owners.ContainsKey(c.ObjectGuid) && !reserved.Contains(c.ObjectGuid) && !unassigned.Contains(c.ObjectGuid)).OrderBy(c => c.Name, StringComparer.Ordinal).ToList();
        legacy.Shuffle(legacyPool);
        var recent = workstations.OrderByDescending(c => c.WhenCreated).Where(c => owners.ContainsKey(c.ObjectGuid) && !unassigned.Contains(c.ObjectGuid)).Take(2).ToList();
        foreach (var computer in legacyPool.Take(LegacyRows - recent.Count).Concat(recent))
        {
            var owner = owners[computer.ObjectGuid];
            var when = recent.Contains(computer)
                ? WritePlans.TruncateToSecond(computer.WhenCreated - legacy.Between(TimeSpan.FromDays(30), TimeSpan.FromDays(200)))
                : Ago(legacy.Between(TimeSpan.FromDays(320), TimeSpan.FromDays(900)));
            Put(new StoredRelation(owner.SamAccountName, null, null, computer.Name, null, null, RelationKind.History, "Historique LogonUI (migration Domenia 1)",
                when, "Ligne reprise de Domenia 1 sans GUID ; identité non vérifiable.", false, null, null));
        }

        // Orphan links: workstations and accounts no longer in the directory; three of them are protected declarations.
        var orphanDraw = random.Fork("orphans");
        string[] goneUsers = ["m.ancien", "l.depart", "c.stagiaire", "p.prestataire"];
        for (var i = 0; i < OrphanRows; i++)
        {
            var site = SimulationProfile.Sites[i % SimulationProfile.Sites.Length];
            var number = site.Workstations + 40 + i;
            var name = "PC-" + site.Code + "-" + number.ToString("D4", CultureInfo.InvariantCulture);
            var computerGone = i % 3 != 2;
            var user = computerGone ? orphanDraw.Pick(peopleBySite[site.Name]) : null;
            var login = user?.SamAccountName ?? goneUsers[i % goneUsers.Length];
            var computer = computerGone ? null : order[orphanDraw.Next(order.Count)];
            var kind = i % 2 == 0 ? RelationKind.Console : RelationKind.History;
            var source = kind == RelationKind.Console ? RelationRules.ConsoleSource : "Journal du contrôleur 4624";
            Put(new StoredRelation(login, user?.ObjectGuid ?? GuidOf(orphanDraw), user?.DistinguishedName,
                computer?.Name ?? name, computer?.ObjectGuid ?? GuidOf(orphanDraw), computer?.DistinguishedName,
                kind, source, Ago(orphanDraw.Between(TimeSpan.FromDays(60), TimeSpan.FromDays(400))),
                "Relevé conservé ; l’objet a pu être supprimé ou renommé depuis.", true, null, null));
        }
        for (var i = 0; i < ProtectedOrphans; i++)
        {
            var site = SimulationProfile.Sites[i];
            var name = "PC-" + site.Code + "-" + (site.Workstations + 80 + i).ToString("D4", CultureInfo.InvariantCulture);
            var user = orphanDraw.Pick(peopleBySite[site.Name]);
            Put(new StoredRelation(user.SamAccountName, user.ObjectGuid, user.DistinguishedName, name, GuidOf(orphanDraw), null, RelationKind.Assignment,
                RelationRules.ManualSource, Ago(orphanDraw.Between(TimeSpan.FromDays(400), TimeSpan.FromDays(900))),
                "Association confirmée dans Relations depuis Recherche AD manuelle.", true, declarants[i % declarants.Count], null));
        }

        // Journal: recent declarations, a removal still restorable and a removal already restored.
        foreach (var relation in store.Values.Where(r => r.Kind == RelationKind.Assignment && r.When > now - TimeSpan.FromDays(40)).OrderBy(r => r.When).Take(6))
        {
            journal.Add(new RelationJournalRecord(NewId(), RelationJournalAction.Added, relation.When!.Value, relation.Declarant,
                "Association déclarée depuis Relations.", RelationRules.Key(relation), relation));
        }
        var removedPool = workstations.Where(c => owners.ContainsKey(c.ObjectGuid) && !unassigned.Contains(c.ObjectGuid) && c.Name.StartsWith("PC-MRS-", StringComparison.Ordinal)).OrderBy(c => c.Name, StringComparer.Ordinal).ToList();
        var removed = Relation(owners[removedPool[4].ObjectGuid], removedPool[4], RelationKind.Console, RelationRules.ConsoleSource, Ago(TimeSpan.FromDays(19)),
            "Lecture de la console à cette date ; sessions RDP non recensées.", true, null);
        store.Remove(RelationRules.Key(removed));
        journal.Add(new RelationJournalRecord(NewId(), RelationJournalAction.Removed, Ago(TimeSpan.FromHours(30)), declarants[3],
            "Retirée du stockage local.", RelationRules.Key(removed), removed));
        var restoredRelation = Relation(owners[removedPool[9].ObjectGuid], removedPool[9], RelationKind.Assignment, RelationRules.ManualSource, Ago(TimeSpan.FromDays(80)),
            "Association confirmée dans Relations depuis Recherche AD manuelle.", true, declarants[4 % declarants.Count]);
        Put(restoredRelation);
        var removalId = NewId();
        journal.Add(new RelationJournalRecord(removalId, RelationJournalAction.Removed, Ago(TimeSpan.FromDays(3) + TimeSpan.FromHours(2)), declarants[4 % declarants.Count],
            "Retirée du stockage local.", RelationRules.Key(restoredRelation), restoredRelation));
        journal.Add(new RelationJournalRecord(NewId(), RelationJournalAction.Restored, Ago(TimeSpan.FromDays(3)), declarants[4 % declarants.Count],
            removalId, RelationRules.Key(restoredRelation), restoredRelation));

        return new Seed(store.ToImmutable(), [.. journal.OrderBy(e => e.At)], batch);
    }

    /// <summary>Site of a workstation name (« PC-LYO-0004 » → Lyon).</summary>
    public static string? SiteOf(string computer)
    {
        foreach (var site in SimulationProfile.Sites)
        {
            if (computer.Contains("-" + site.Code + "-", StringComparison.Ordinal))
            {
                return site.Name;
            }
        }
        return null;
    }

    private static Guid GuidOf(SeededRandom random)
    {
        Span<byte> bytes = stackalloc byte[16];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt64LittleEndian(bytes, random.NextUInt64());
        System.Buffers.Binary.BinaryPrimitives.WriteUInt64LittleEndian(bytes[8..], random.NextUInt64());
        bytes[7] = (byte)((bytes[7] & 0x0F) | 0x40);
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);
        return new Guid(bytes);
    }
}
