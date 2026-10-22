using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Deterministic answers of the network reads of the relations screen in simulation: console reads (Win32_ComputerSystem by
/// CIM/DCOM in directory mode), Kerberos clues of the controller journal and couples of a harvest. Derived from the generated
/// world and the association store only (sub-stream « screen/relations/probe… »): the same workstation always answers the same
/// way during a session. No network, no disk.
/// </summary>
internal static class SimulatedRelationProbes
{
    /// <summary>Status of a console read (Domenia 1 vocabulary: LU, REFUSE, DELAI) and the account read, if any.</summary>
    public sealed record ConsoleReading(string Status, string Detail, string? Account, RelationObject? User, long DurationMs);

    public static ConsoleReading Console(SimulatedRelationState state, RelationObject computer, SimulatedRelationLookup lookup)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(computer);
        ArgumentNullException.ThrowIfNull(lookup);
        var random = state.Source.ScreenStream("relations").Fork("probe/" + computer.Guid.ToString("D"));
        var roll = random.Next(100);
        var duration = (long)random.Next(180, 3800);
        const string c = FrenchText.Colon;
        if (!computer.Enabled)
        {
            return new ConsoleReading("DELAI", "Compte ordinateur désactivé" + c + "le poste ne répond pas dans le délai (4 s).", null, null, 4000);
        }
        var observation = state.Source.World.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == computer.Guid);
        if (observation is not null && ((observation.Presence.HasReading && observation.Presence.Answered == false) || (!observation.Presence.HasReading && roll % 3 == 0)))
        {
            return new ConsoleReading("DELAI", "Le poste ne répond pas dans le délai (4 s)" + c + "éteint, hors réseau ou filtré. Une absence de réponse n’est jamais un verdict d’arrêt.", null, null, 4000);
        }
        if (roll < 5)
        {
            return new ConsoleReading("REFUSE", "Accès refusé (0x80070005)" + c + "le compte de lecture n’a pas les droits DCOM sur ce poste.", null, null, duration);
        }
        if (roll < 24)
        {
            return new ConsoleReading("LU", "Aucun compte console" + c + "personne n’a ouvert de session sur ce poste à cette date.", null, null, duration);
        }
        var relations = state.Store.Values.Where(r => r.ComputerGuid == computer.Guid).ToList();
        var pick = relations.Where(r => r.Kind is RelationKind.Console or RelationKind.RemoteSession).MaxBy(r => r.When)
            ?? relations.FirstOrDefault(r => r.Kind == RelationKind.Assignment)
            ?? relations.Where(r => r.Kind is RelationKind.Imported or RelationKind.History).MaxBy(r => r.When);
        var user = pick is null ? null : lookup.User(pick.UserGuid, pick.UserLogin);
        if (user is null)
        {
            return new ConsoleReading("LU", "Aucun compte console" + c + "personne n’a ouvert de session sur ce poste à cette date.", null, null, duration);
        }
        return new ConsoleReading("LU", "Lecture de la console à cette date ; sessions RDP non recensées. Aucun ancien lien supprimé.",
            state.Source.World.Directory.Domain.NetbiosName + "\\" + user.Login, user, duration);
    }

    /// <summary>Kerberos 4768 clues of a user over 7 days: addresses only, never a workstation (Domenia 1 REL-022).</summary>
    public static ImmutableArray<RelationHint> Kerberos(SimulatedRelationState state, RelationObject user, string controller)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(user);
        var random = state.Source.ScreenStream("relations").Fork("kerberos/" + user.Guid.ToString("D"));
        var count = random.Next(0, 5);
        var now = state.Now;
        var hints = ImmutableArray.CreateBuilder<RelationHint>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var i = 0; i < count; i++)
        {
            var address = "10.20." + random.Next(1, 6).ToString(CultureInfo.InvariantCulture) + "." + random.Next(20, 250).ToString(CultureInfo.InvariantCulture);
            if (!seen.Add(address))
            {
                continue;
            }
            hints.Add(new RelationHint(address, "Événement Kerberos 4768", "Indice IP, pas un poste identifié",
                "Authentification sur " + controller + ". Une IP ne prouve ni le poste AD ni une session ouverte.",
                WritePlans.TruncateToSecond(now - random.Between(TimeSpan.FromMinutes(10), TimeSpan.FromDays(7)))));
        }
        return [.. hints.OrderByDescending(h => h.ObservedAt)];
    }

    /// <summary>One couple of a harvest before projection.</summary>
    public sealed record HarvestCouple(RelationObject User, RelationObject Computer, DateTimeOffset First, DateTimeOffset Last, int Events, string EventIds);

    /// <summary>
    /// Couples user/workstation of the controller journal over <paramref name="days"/> days (events 4768, 4769 and 4624):
    /// the usual user of each workstation of the store on working days, and a few colleagues; machine accounts are ignored
    /// and counted. Bounded by <paramref name="maxEvents"/>, most recent couples first.
    /// </summary>
    public static (ImmutableArray<HarvestCouple> Couples, int Events, bool Truncated, int MachineAccounts, int Unresolved) Harvest(
        SimulatedRelationState state, SimulatedRelationLookup lookup, int days, int maxEvents)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(lookup);
        var random = state.Source.ScreenStream("relations").Fork("harvest/" + days.ToString(CultureInfo.InvariantCulture));
        var now = state.Now;
        var couples = new List<HarvestCouple>();
        var byComputer = state.Store.Values.Where(r => r.ComputerGuid is not null && r.UserGuid is not null)
            .GroupBy(r => r.ComputerGuid!.Value)
            .ToList();
        foreach (var group in byComputer.OrderBy(g => g.Key))
        {
            var computer = lookup.Computer(group.Key, "");
            if (computer is null || !computer.Enabled)
            {
                continue;
            }
            var usual = group.Where(r => r.Kind is RelationKind.Console or RelationKind.Assignment).MaxBy(r => r.When) ?? group.MaxBy(r => r.When)!;
            var user = lookup.User(usual.UserGuid, usual.UserLogin);
            if (user is null || random.Next(100) < 18)
            {
                continue;
            }
            var active = Math.Max(1, days * random.Next(55, 100) / 100);
            var events = active * random.Next(2, 6);
            var last = WritePlans.TruncateToSecond(now - random.Between(TimeSpan.FromMinutes(15), TimeSpan.FromDays(Math.Min(days, 3))));
            var first = WritePlans.TruncateToSecond(last - random.Between(TimeSpan.FromHours(2), TimeSpan.FromDays(Math.Max(1, days - 1))));
            couples.Add(new HarvestCouple(user, computer, first, last, events, events > 6 ? "4624, 4768, 4769" : "4624, 4768"));
            if (random.Next(100) < 9)
            {
                var other = group.Where(r => r.UserGuid != user.Guid).Select(r => lookup.User(r.UserGuid, r.UserLogin)).FirstOrDefault(u => u is not null);
                if (other is not null)
                {
                    var at = WritePlans.TruncateToSecond(now - random.Between(TimeSpan.FromHours(4), TimeSpan.FromDays(days)));
                    couples.Add(new HarvestCouple(other, computer, at, at, random.Next(1, 4), "4624"));
                }
            }
        }
        // Workstations without any association: the journal still sees who logs on there (usual user of the same site, sometimes
        // a colleague on a shared workstation). These couples are the new ones a harvest brings.
        var free = state.Source.ScreenStream("relations").Fork("harvest/" + days.ToString(CultureInfo.InvariantCulture) + "/free");
        var linked = byComputer.Select(g => g.Key).ToHashSet();
        var bySite = lookup.Users.Where(u => u.Enabled && u.Dn.Contains(",OU=Utilisateurs,", StringComparison.OrdinalIgnoreCase))
            .GroupBy(u => SiteOf(u.Dn, "Utilisateurs"), StringComparer.OrdinalIgnoreCase)
            .Where(g => g.Key.Length > 0)
            .ToDictionary(g => g.Key, g => g.OrderBy(u => u.Login, StringComparer.Ordinal).ToList(), StringComparer.OrdinalIgnoreCase);
        foreach (var computer in lookup.Computers.Where(c => c.Enabled && !linked.Contains(c.Guid) && c.Dn.Contains(",OU=Postes,", StringComparison.OrdinalIgnoreCase))
            .OrderBy(c => c.Name, StringComparer.Ordinal))
        {
            if (!bySite.TryGetValue(SiteOf(computer.Dn, "Postes"), out var people) || people.Count == 0 || free.Next(100) < 22)
            {
                continue;
            }
            var users = free.Next(100) < 24 ? 2 : 1;
            for (var n = 0; n < users; n++)
            {
                var user = people[free.Next(people.Count)];
                if (couples.Any(c => c.User.Guid == user.Guid && c.Computer.Guid == computer.Guid))
                {
                    continue;
                }
                var active = Math.Max(1, days * free.Next(30, 100) / 100);
                var events = active * free.Next(2, 6);
                var last = WritePlans.TruncateToSecond(now - free.Between(TimeSpan.FromMinutes(20), TimeSpan.FromDays(Math.Min(days, 4))));
                var first = WritePlans.TruncateToSecond(last - free.Between(TimeSpan.FromHours(1), TimeSpan.FromDays(Math.Max(1, days - 1))));
                couples.Add(new HarvestCouple(user, computer, first, last, events, events > 6 ? "4624, 4768, 4769" : "4624, 4768"));
            }
        }
        var ordered = couples.OrderByDescending(c => c.Last).ToList();
        var total = ordered.Sum(c => c.Events);
        var kept = new List<HarvestCouple>();
        var budget = 0;
        foreach (var couple in ordered)
        {
            if (budget + couple.Events > maxEvents)
            {
                break;
            }
            budget += couple.Events;
            kept.Add(couple);
        }
        var machines = byComputer.Count * Math.Max(1, days) * 2;
        var unresolved = random.Next(2, 9);
        return ([.. kept], Math.Min(total, maxEvents), total > maxEvents, machines, unresolved);
    }

    /// <summary>Site of an object from its DN: the OU just under « OU=<paramref name="branch"/> » (« Paris »), or an empty text.</summary>
    private static string SiteOf(string dn, string branch)
    {
        var marker = ",OU=" + branch + ",";
        var at = dn.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
        if (at <= 0)
        {
            return "";
        }
        var start = dn.LastIndexOf(",OU=", at - 1, StringComparison.OrdinalIgnoreCase);
        return start < 0 ? "" : dn[(start + 4)..at];
    }
}
