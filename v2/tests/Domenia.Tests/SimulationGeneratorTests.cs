using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class SimulationGeneratorTests
{
    private static readonly Lazy<SimulatedWorld> DefaultWorld = new(() => Generate(TestClock.Reference));

    private static SimulatedWorld World => DefaultWorld.Value;

    private static DateTimeOffset Reference => World.Reference;

    private static SimulatedWorld Generate(DateTimeOffset reference, ulong seed = SimulationOptions.DefaultSeed) =>
        SimulatedWorldGenerator.Generate(SimulationOptions.Default with { Seed = seed }, reference, TestClock.Paris);

    private static DashboardSummary Summary(SimulatedWorld world) => DashboardCalculator.Compute(new DashboardInput(
        world.InitialState, world.Session.Scope!, DashboardPolicy.Default, new HashSet<string>(), world.Journal, world.Reference, TestClock.Paris, DirectorySourceKind.Simulation));

    private static IEnumerable<DirectoryComputer> ActiveWorkstations(SimulatedWorld world) => world.Directory.Computers.Where(c =>
        !AdValues.IsDisabled(c.UserAccountControl) && DistinguishedName.IsWithin(c.DistinguishedName, world.Session.Scope!.Dn, true));

    private static bool IsPerson(DirectoryUser user) => user.EmployeeId is not null;

    [Test]
    public static void Same_seed_reference_and_zone_give_the_same_fingerprint()
    {
        var again = Generate(TestClock.Reference);
        Check.Equal(World.ComputeFingerprint(), again.ComputeFingerprint(), "même empreinte");
        Check.True(World.ComputeFingerprint() != Generate(TestClock.Reference, 42).ComputeFingerprint(), "autre graine, autre empreinte");
        Check.Equal(TestClock.Reference, World.Reference, "référence tronquée à la minute");
        Check.Equal(new DateTimeOffset(2026, 10, 21, 16, 26, 0, TimeSpan.Zero), Generate(TestClock.Reference.AddSeconds(42)).Reference, "secondes ignorées");
    }

    [Test]
    public static void Profile_counts_are_exact()
    {
        var d = World.Directory;
        Check.Equal(1258, d.Users.Length, "utilisateurs");
        Check.Equal(1186, d.Users.Count(u => !AdValues.IsDisabled(u.UserAccountControl)), "utilisateurs actifs");
        Check.Equal(454, d.Computers.Length, "ordinateurs");
        Check.Equal(431, d.Computers.Count(c => DistinguishedName.IsWithin(c.DistinguishedName, World.Session.Scope!.Dn, true)), "ordinateurs sous OU=Postes");
        Check.Equal(412, ActiveWorkstations(World).Count(), "postes actifs du périmètre");
        Check.Equal(75, d.Groups.Length, "groupes");
        Check.Equal(39, d.OrganizationalUnits.Length, "OU");
        Check.Equal(1826, d.ObjectCount, "objets");
        Check.Equal(1826, World.Session.Store.Objects, "objets de la base fictive");
        Check.Equal(Reference - TimeSpan.FromMinutes(12), d.ReadAt, "lecture à référence − 12 min");
    }

    [Test]
    public static void Figures_of_the_day_depend_only_on_the_kind_of_day()
    {
        var wednesday = Summary(World);
        var tuesday = Summary(Generate(new DateTimeOffset(2026, 11, 17, 9, 5, 0, TimeSpan.Zero)));
        foreach (var summary in new[] { wednesday, tuesday })
        {
            var online = Fixtures.Kpi(summary.Widgets[WidgetCatalog.WorkstationsOnline]);
            Check.Equal(287, online.Value, "en ligne");
            Check.Equal(412, online.Total, "postes");
            Check.Equal(98, Fixtures.Part(online.Breakdown, "noAnswer"), "sans réponse");
            Check.Equal(27, Fixtures.Part(online.Breakdown, "notChecked"), "non vérifiés");
            Check.Equal(1186, Fixtures.Kpi(summary.Widgets[WidgetCatalog.ActiveAccounts]).Value, "comptes actifs");
            Check.Equal(7, Fixtures.Kpi(summary.Widgets[WidgetCatalog.LockedAccounts]).Value, "verrouillés");
            Check.Equal(23, Fixtures.Kpi(summary.Widgets[WidgetCatalog.PasswordsExpiring]).Value, "expirants");
            Check.Equal(9, Fixtures.Kpi(summary.Widgets[WidgetCatalog.DiskAlerts]).Value, "alertes disque");
            Check.Equal(84.0, ((GaugeData)summary.Widgets[WidgetCatalog.MeasureFreshness].Data!).Percent, "fraîcheur");
            Check.Equal(63, ((WatchlistData)summary.Widgets[WidgetCatalog.Watchlist].Data!).Total, "postes à surveiller");
        }
        var saturday = Summary(Generate(new DateTimeOffset(2026, 10, 24, 10, 0, 0, TimeSpan.Zero)));
        var weekend = Fixtures.Kpi(saturday.Widgets[WidgetCatalog.WorkstationsOnline]);
        Check.Equal(61, weekend.Value, "en ligne un samedi");
        Check.Equal(324, Fixtures.Part(weekend.Breakdown, "noAnswer"), "sans réponse un samedi");
        Check.Equal(27, Fixtures.Part(weekend.Breakdown, "notChecked"), "non vérifiés un samedi");
    }

    [Test]
    public static void Distinguished_names_are_unique_escaped_and_rooted()
    {
        var d = World.Directory;
        var all = d.OrganizationalUnits.Select(o => o.DistinguishedName)
            .Concat(d.Users.Select(u => u.DistinguishedName))
            .Concat(d.Computers.Select(c => c.DistinguishedName))
            .Concat(d.Groups.Select(g => g.DistinguishedName)).ToList();
        Check.Equal(all.Count, all.Distinct(StringComparer.OrdinalIgnoreCase).Count(), "DN uniques");
        var parents = new HashSet<string>(d.OrganizationalUnits.Select(o => o.DistinguishedName).Concat(d.Domain.Containers).Append(d.Domain.RootDn), StringComparer.OrdinalIgnoreCase);
        foreach (var dn in all)
        {
            Check.True(parents.Contains(DistinguishedName.Parent(dn)!), "parent existant pour " + dn);
            Check.Equal(dn, DistinguishedName.Format(DistinguishedName.Parse(dn)), "lecture inverse de " + dn);
        }
        Check.True(d.Users.Any(u => u.DistinguishedName.StartsWith(@"CN=Le Gall\, Anne,", StringComparison.Ordinal)), "échappement de la virgule");
        Check.Equal("Le Gall, Anne", DistinguishedName.Parse(d.Users.First(u => u.Cn == "Le Gall, Anne").DistinguishedName)[0].Value, "valeur lue");
        var homonyms = d.Users.Where(u => u.Cn.EndsWith(" 2", StringComparison.Ordinal)).ToList();
        Check.True(homonyms.Count >= 1, "homonymes numérotés");
        Check.True(homonyms.All(h => h.DisplayName + " 2" == h.Cn), "nom affiché identique pour l’homonyme");
    }

    [Test]
    public static void Account_names_are_unique_and_well_formed()
    {
        var d = World.Directory;
        var sams = d.Users.Select(u => u.SamAccountName).ToList();
        Check.Equal(sams.Count, sams.Distinct(StringComparer.OrdinalIgnoreCase).Count(), "sAMAccountName uniques");
        foreach (var user in d.Users.Where(u => !u.Sid.EndsWith("-500", StringComparison.Ordinal) && !u.Sid.EndsWith("-501", StringComparison.Ordinal) && !u.Sid.EndsWith("-502", StringComparison.Ordinal)))
        {
            var sam = user.SamAccountName;
            Check.True(sam.Length is > 0 and <= 20, "longueur de " + sam);
            Check.True(sam.All(c => char.IsAsciiLetterLower(c) || char.IsAsciiDigit(c) || c is '.' or '-'), "ASCII minuscule : " + sam);
        }
        var upns = d.Users.Where(u => u.UserPrincipalName is not null).Select(u => u.UserPrincipalName!).ToList();
        Check.Equal(upns.Count, upns.Distinct(StringComparer.OrdinalIgnoreCase).Count(), "UPN uniques");
        var employees = d.Users.Where(u => u.EmployeeId is not null).Select(u => u.EmployeeId!).ToList();
        Check.Equal(employees.Count, employees.Distinct(StringComparer.Ordinal).Count(), "employeeID uniques");
        Check.True(employees.All(e => e.Length == 6 && e.All(char.IsAsciiDigit)), "employeeID à six chiffres");
        var julien = d.Users.Single(u => u.SamAccountName == "j.martin");
        Check.Equal("Julien Martin", julien.DisplayName, "j.martin est Julien Martin");
        // The session runs under the administration account adm-j.martin (decision of David, 21/10).
        var admin = d.Users.Single(u => u.SamAccountName == "adm-j.martin");
        Check.Equal(@"EXAMPLE\adm-j.martin", World.Session.Account.Login, "compte de session d’administration");
        Check.Equal(admin.DistinguishedName, World.Session.Account.Dn, "DN du compte de session");
        Check.True(admin.DistinguishedName.Contains("OU=Comptes à privilèges", StringComparison.Ordinal), "compte de session dans les comptes à privilèges");
        Check.Equal(RightsLevel.Admin, World.Session.Rights.Level, "droits estimés depuis Admins du domaine");
    }

    [Test]
    public static void Identifiers_are_unique_and_well_known_rids_exist()
    {
        var d = World.Directory;
        var guids = d.OrganizationalUnits.Select(o => o.ObjectGuid).Concat(d.Users.Select(u => u.ObjectGuid))
            .Concat(d.Computers.Select(c => c.ObjectGuid)).Concat(d.Groups.Select(g => g.ObjectGuid)).ToList();
        Check.Equal(guids.Count, guids.Distinct().Count(), "GUID uniques");
        Check.False(guids.Contains(Guid.Empty), "aucun GUID vide");
        var sids = d.Users.Select(u => u.Sid).Concat(d.Computers.Select(c => c.Sid)).Concat(d.Groups.Select(g => g.Sid)).ToList();
        Check.Equal(sids.Count, sids.Distinct(StringComparer.Ordinal).Count(), "SID uniques");
        foreach (var rid in new[] { 500, 501, 502 })
        {
            Check.True(d.Users.Any(u => u.Sid == d.Domain.DomainSid + "-" + rid), "RID utilisateur " + rid);
        }
        foreach (var rid in new[] { 512, 513, 514, 515, 516, 518, 519, 520, 525 })
        {
            Check.True(d.Groups.Any(g => g.Sid == d.Domain.DomainSid + "-" + rid), "RID groupe " + rid);
        }
        var builtin = d.Groups.Where(g => g.DistinguishedName.EndsWith("CN=Builtin," + d.Domain.RootDn, StringComparison.OrdinalIgnoreCase)).ToList();
        Check.Equal(8, builtin.Count, "groupes intégrés");
        Check.True(builtin.All(g => g.Sid.StartsWith("S-1-5-32-", StringComparison.Ordinal)), "SID S-1-5-32 des groupes intégrés");
        Check.True(d.Domain.DomainSid.StartsWith("S-1-5-21-", StringComparison.Ordinal), "SID du domaine");
    }

    [Test]
    public static void Memberships_are_symmetric_acyclic_and_shallow()
    {
        var d = World.Directory;
        var memberOfByDn = new Dictionary<string, IReadOnlyCollection<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var u in d.Users)
        {
            memberOfByDn[u.DistinguishedName] = u.MemberOf;
        }
        foreach (var c in d.Computers)
        {
            memberOfByDn[c.DistinguishedName] = c.MemberOf;
        }
        foreach (var g in d.Groups)
        {
            memberOfByDn[g.DistinguishedName] = g.MemberOf;
        }
        var groupByDn = d.Groups.ToDictionary(g => g.DistinguishedName, StringComparer.OrdinalIgnoreCase);
        foreach (var g in d.Groups)
        {
            foreach (var member in g.Members)
            {
                Check.True(memberOfByDn.TryGetValue(member, out var memberOf) && memberOf.Contains(g.DistinguishedName, StringComparer.OrdinalIgnoreCase), "memberOf symétrique de " + member);
            }
        }
        foreach (var (dn, memberOf) in memberOfByDn)
        {
            foreach (var groupDn in memberOf)
            {
                Check.True(groupByDn.TryGetValue(groupDn, out var group) && group.Members.Contains(dn, StringComparer.OrdinalIgnoreCase), "member symétrique de " + dn);
            }
        }
        int Depth(DirectoryGroup group, HashSet<string> path)
        {
            Check.True(path.Add(group.DistinguishedName), "aucun cycle par " + group.Name);
            var depth = 1 + group.MemberOf.Select(parent => Depth(groupByDn[parent], path)).DefaultIfEmpty(0).Max();
            path.Remove(group.DistinguishedName);
            return depth;
        }
        foreach (var g in d.Groups)
        {
            Check.True(Depth(g, new HashSet<string>(StringComparer.OrdinalIgnoreCase)) <= 2, "profondeur au plus 2 : " + g.Name);
        }
        var departures = d.Users.Where(u => DistinguishedName.Parent(u.DistinguishedName)!.StartsWith("OU=Départs,", StringComparison.Ordinal)).ToList();
        Check.Equal(48, departures.Count, "départs");
        Check.True(departures.All(u => u.MemberOf.IsEmpty && AdValues.IsDisabled(u.UserAccountControl)), "départs désactivés et sans groupe");
        Check.Equal(6, d.Groups.Single(g => g.Name == "GG-Support-N2").Members.Length, "GG-Support-N2");
        Check.True(d.Groups.Single(g => g.Name == "GG-Support-N2").Members.Contains(d.Users.Single(u => u.SamAccountName == "j.martin").DistinguishedName), "Julien Martin dans GG-Support-N2");
        Check.True(d.Groups.Single(g => g.Name == "Utilisateurs du domaine").Members.All(m => groupByDn.ContainsKey(m)), "groupe principal hors de member");
    }

    [Test]
    public static void Names_keep_accents_and_titles_agree_with_the_given_name()
    {
        var people = World.Directory.Users.Where(IsPerson).ToList();
        Check.True(people.Any(u => u.DisplayName!.Any(c => c > 127)), "accents conservés");
        foreach (var u in people)
        {
            foreach (var value in new[] { u.Cn, u.SamAccountName, u.DisplayName, u.GivenName, u.Surname, u.Title, u.Department, u.Mail })
            {
                Check.False(string.IsNullOrWhiteSpace(value), "champ obligatoire de " + u.Cn);
            }
        }
        var feminine = FrenchNames.Titles.Values.SelectMany(t => t.Feminine.Append(t.ManagerFeminine)).ToHashSet(StringComparer.Ordinal);
        var masculine = FrenchNames.Titles.Values.SelectMany(t => t.Masculine.Append(t.ManagerMasculine)).ToHashSet(StringComparer.Ordinal);
        foreach (var u in people)
        {
            var female = FrenchNames.Female.Contains(u.GivenName!);
            var male = FrenchNames.Male.Contains(u.GivenName!);
            if (female && !male)
            {
                Check.True(feminine.Contains(u.Title!), $"intitulé accordé : {u.DisplayName}, {u.Title}");
            }
            if (male && !female)
            {
                Check.True(masculine.Contains(u.Title!), $"intitulé accordé : {u.DisplayName}, {u.Title}");
            }
        }
    }

    [Test]
    public static void Account_states_are_consistent()
    {
        var users = World.Directory.Users;
        var active = users.Where(u => !AdValues.IsDisabled(u.UserAccountControl)).ToList();
        var locked = users.Where(u => u.ComputedAccountControl is int c && (c & AdValues.LockedOut) != 0).ToList();
        Check.Equal(7, locked.Count, "verrouillés");
        foreach (var u in locked)
        {
            Check.False(AdValues.IsDisabled(u.UserAccountControl), "verrouillé ⇒ actif");
            var at = AdValues.FromFileTime(u.LockoutTime);
            Check.True(at is DateTimeOffset l && l <= Reference && Reference - l <= TimeSpan.FromMinutes(30), "lockoutTime dans les 30 minutes");
        }
        Check.Equal(2, active.Count(u => u.LockoutTime > 0 && (u.ComputedAccountControl! & AdValues.LockedOut) == 0), "verrouillages expirés");
        Check.True(users.Any(u => u.Cn == "Camille Bernard" && locked.Contains(u)), "Camille Bernard verrouillée");
        foreach (var u in users)
        {
            if ((u.UserAccountControl & AdValues.DontExpirePassword) != 0)
            {
                Check.Equal(AdValues.Never, u.PasswordExpiryComputed, "n’expire jamais ⇒ Int64.MaxValue");
                continue;
            }
            if (u.PasswordLastSet == 0)
            {
                continue;
            }
            var expiry = AdValues.FromFileTime(u.PasswordExpiryComputed);
            var flag = (u.ComputedAccountControl! & AdValues.PasswordExpired) != 0;
            Check.Equal(expiry is DateTimeOffset e && e <= Reference, flag, "expiré ⇔ date dépassée ou bit 0x800000 : " + u.Cn);
        }
        foreach (var u in active.Where(u => u.PasswordLastSet != 0 && u.PasswordExpiryComputed != AdValues.Never))
        {
            var e = AdValues.FromFileTime(u.PasswordExpiryComputed)!.Value;
            Check.True((e - Reference).Duration() >= TimeSpan.FromHours(1), "loin du seuil « maintenant » : " + u.Cn);
            Check.True((e - (Reference + TimeSpan.FromDays(7))).Duration() >= TimeSpan.FromHours(1), "loin du seuil « 7 jours » : " + u.Cn);
        }
        Check.Equal(16, active.Count(u => (u.UserAccountControl & AdValues.DontExpirePassword) != 0), "n’expirent jamais");
        Check.Equal(4, active.Count(u => u.PasswordLastSet == 0), "à changer");
        Check.Equal(9, active.Count(u => u.LastLogonTimestamp is null), "jamais connectés");
        Check.Equal(40, active.Count(u => AdValues.FromFileTime(u.LastLogonTimestamp) is DateTimeOffset l && Reference - l > TimeSpan.FromDays(90)), "connexion de plus de 90 jours");
    }

    [Test]
    public static void Workstation_states_are_consistent()
    {
        var observations = World.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var workstations = ActiveWorkstations(World).ToList();
        Check.Equal(412, observations.Count, "un relevé par poste actif");
        foreach (var c in workstations)
        {
            var o = observations[c.ObjectGuid];
            var lastLogon = AdValues.FromFileTime(c.LastLogonTimestamp);
            if (lastLogon is null || Reference - lastLogon.Value > TimeSpan.FromDays(90))
            {
                Check.False(o.Presence.Answered == true, "inactif ⇒ pas en ligne : " + c.Name);
            }
            var inventory = o.Inventory;
            if (inventory.HasReading)
            {
                Check.True(inventory.SystemDiskSizeBytes > 0 && inventory.SystemDiskFreeBytes >= 0 && inventory.SystemDiskFreeBytes <= inventory.SystemDiskSizeBytes, "libre ≤ taille : " + c.Name);
                Check.True(inventory.LastBootAt <= inventory.CheckedAt && inventory.CheckedAt <= Reference, "démarrage avant le relevé : " + c.Name);
                var percent = (double)inventory.SystemDiskFreeBytes!.Value * 100 / inventory.SystemDiskSizeBytes!.Value;
                Check.True(Math.Abs(percent - 10) >= 0.1 && Math.Abs(percent - 20) >= 0.1, "disque loin des seuils : " + c.Name);
            }
            var release = WindowsRelease.Describe(c.OperatingSystem, c.OperatingSystemVersion);
            Check.True(release is not null && release.Key != "w10" && release.Key != "w11", "version cohérente avec le système : " + c.Name);
        }
        Check.Equal(3, World.Observations.Workstations.Count(o => o.Presence.State == MeasureState.Error), "sondes en erreur");
        Check.Equal(1, World.Observations.Workstations.Count(o => o.Presence.LastOnlineAt is null && o.Presence.HasReading && o.Inventory.HasReading
            && (double)o.Inventory.SystemDiskFreeBytes!.Value * 100 / o.Inventory.SystemDiskSizeBytes!.Value < 10), "poste au ping filtré, inventaire présent");
    }

    [Test]
    public static void Systems_follow_the_profile_and_no_date_is_in_the_future()
    {
        var workstations = ActiveWorkstations(World).ToList();
        foreach (var spec in SimulationProfile.WorkstationSystems)
        {
            Check.Equal(spec.Count, workstations.Count(c => c.OperatingSystem == spec.OperatingSystem && c.OperatingSystemVersion == spec.Version), $"{spec.OperatingSystem} {spec.Version}");
        }
        var d = World.Directory;
        bool Past(long? fileTime) => AdValues.FromFileTime(fileTime) is not DateTimeOffset at || at <= Reference;
        foreach (var u in d.Users)
        {
            Check.True(u.WhenCreated <= u.WhenChanged && u.WhenChanged <= Reference, "dates de " + u.Cn);
            Check.True(Past(u.PasswordLastSet) && Past(u.LastLogonTimestamp) && Past(u.LockoutTime), "aucune date future : " + u.Cn);
            Check.True(AdValues.FromFileTime(u.PasswordLastSet) is not DateTimeOffset set || set >= u.WhenCreated, "mot de passe après la création : " + u.Cn);
        }
        foreach (var c in d.Computers)
        {
            Check.True(c.WhenCreated <= c.WhenChanged && c.WhenChanged <= Reference, "dates de " + c.Name);
            Check.True(Past(c.PasswordLastSet) && Past(c.LastLogonTimestamp), "aucune date future : " + c.Name);
        }
        Check.True(d.OrganizationalUnits.All(o => o.WhenCreated <= Reference) && d.Groups.All(g => g.WhenCreated <= Reference), "OU et groupes créés avant la référence");
        Check.Equal(389, workstations.Count(c => c.Laps == LapsKind.Windows), "LAPS Windows");
    }
}
