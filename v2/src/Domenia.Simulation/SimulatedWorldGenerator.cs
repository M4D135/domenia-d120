using System.Buffers.Binary;
using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Builds the fictitious directory of docs/SIMULATION.md § 4 and 5. Pure: (options, reference, time zone) → world. Every
/// population with a fixed size is chosen by a deterministic shuffle, and every date is placed far from the thresholds, so
/// the figures of the day depend only on the seed and on whether the reference is a working day.
/// </summary>
public static class SimulatedWorldGenerator
{
    public static SimulatedWorld Generate(SimulationOptions options, DateTimeOffset reference, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(timeZone);
        var utc = reference.ToUniversalTime();
        var truncated = new DateTimeOffset(utc.UtcTicks - utc.UtcTicks % TimeSpan.TicksPerMinute, TimeSpan.Zero);
        return new WorldBuilder(options.Seed, truncated, timeZone).Build();
    }
}

/// <summary>Mutable drafts while generating; converted to immutable records at the end.</summary>
internal sealed class WorldBuilder
{
    private const int GlobalSecurity = unchecked((int)0x80000002);
    private const int DomainLocalSecurity = unchecked((int)0x80000004);
    private const int BuiltinLocalSecurity = unchecked((int)0x80000005);
    private const int UniversalSecurity = unchecked((int)0x80000008);
    private const int UniversalDistribution = 0x8;
    private const int NormalUser = AdValues.NormalAccount;
    private const int DisabledUser = AdValues.NormalAccount | AdValues.AccountDisabled;
    private const int NeverExpiringUser = AdValues.NormalAccount | AdValues.DontExpirePassword;
    private const int Workstation = AdValues.WorkstationTrustAccount;
    private const int DisabledWorkstation = AdValues.WorkstationTrustAccount | AdValues.AccountDisabled;
    private const int DomainControllerAccount = AdValues.ServerTrustAccount | AdValues.TrustedForDelegation;

    private static readonly TimeSpan MaxPasswordAge = TimeSpan.FromDays(90);
    private static readonly string[] AppGroups = ["Paie", "Compta", "CRM", "GED", "Planning", "Stocks", "Achats", "Intranet", "VPN", "Messagerie"];
    private static readonly string[] ShareNames = ["Direction", "Finances", "RH", "Informatique", "Juridique", "Communication", "Achats", "Commercial", "Logistique", "Qualité", "Projets", "Commun"];
    private static readonly char[] NameSeparators = ['-', ' '];

    private readonly SeededRandom root;
    private readonly SeededRandom userGuids;
    private readonly DateTimeOffset reference;
    private readonly TimeZoneInfo timeZone;
    private readonly DateTimeOffset domainCreated;
    private readonly string domainSid;
    private readonly HashSet<string> samTaken = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> mailTaken = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<int> employeeIds = [];
    private readonly Dictionary<string, int> phoneCounters = new(StringComparer.Ordinal);
    private readonly Dictionary<string, HashSet<string>> cnTaken = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> ouDn = new(StringComparer.Ordinal);
    private readonly List<OuDraft> ous = [];
    private readonly List<UserDraft> users = [];
    private readonly List<ComputerDraft> computers = [];
    private readonly List<GroupDraft> groups = [];
    private readonly Dictionary<string, GroupDraft> groupByName = new(StringComparer.Ordinal);

    public WorldBuilder(ulong seed, DateTimeOffset reference, TimeZoneInfo timeZone)
    {
        root = new SeededRandom(seed);
        userGuids = root.Fork("users/guids");
        this.reference = reference;
        this.timeZone = timeZone;
        var domain = root.Fork("domain");
        domainCreated = reference - TimeSpan.FromDays(8 * 365 + domain.Next(10, 60));
        domainSid = string.Create(CultureInfo.InvariantCulture, $"S-1-5-21-{domain.NextUInt32()}-{domain.NextUInt32()}-{domain.NextUInt32()}");
    }

    private bool Weekend
    {
        get
        {
            var day = LocalDays.DateOf(reference, timeZone).DayOfWeek;
            return day is DayOfWeek.Saturday or DayOfWeek.Sunday;
        }
    }

    public SimulatedWorld Build()
    {
        BuildOrganizationalUnits();
        BuildGroups();
        var julien = BuildUsers();
        BuildComputers();
        BuildMemberships(julien);
        var snapshot = ToSnapshot();
        var (observations, presence) = BuildObservations();
        var history = BuildHistory(snapshot);
        var journal = BuildJournal(snapshot);
        // The session runs under the administration account of Julien Martin (decision of David, 21/10), not his own name.
        var operatorAccount = users.First(u => u.Sam == SimulationProfile.SessionLogin);
        var rights = OperatorRights(operatorAccount);
        var session = new SessionSnapshot(
            ConnectionState.Simulated,
            new DomainIdentity(SimulationProfile.DnsName, SimulationProfile.NetbiosName, SimulationProfile.RootDn),
            new ControllerIdentity("DC01." + SimulationProfile.DnsName, "Paris"),
            new AccountIdentity(SimulationProfile.NetbiosName + "\\" + operatorAccount.Sam, operatorAccount.DisplayName, operatorAccount.Given, operatorAccount.Dn),
            new AuthenticationInfo(AuthenticationMethod.None, null, "Aucune (simulation)"),
            new ScopeSelection(ouDn["Postes"], SimulationProfile.WorkingOuName, true),
            rights,
            // Writes are admitted in simulation, on the in-memory overlay only (decision of David, 21/10): not read only.
            false,
            new StoreStatus(snapshot.ReadAt, snapshot.ObjectCount, snapshot.Complete));
        return new SimulatedWorld(reference, timeZone, Weekend, snapshot, observations, history, journal, session, presence);
    }

    /// <summary>Rights estimated from the groups of the session account (Admins du domaine, then GG-Admins-*), never verified.</summary>
    private RightsInfo OperatorRights(UserDraft account)
    {
        var domainAdmins = groupByName["Admins du domaine"].Dn;
        var names = groups.Where(g => account.MemberOf.Contains(g.Dn)).Select(g => g.Name).Order(StringComparer.Ordinal).ToList();
        var level = account.MemberOf.Contains(domainAdmins) ? RightsLevel.Admin
            : names.Any(n => n.StartsWith("GG-Admins-", StringComparison.Ordinal)) ? RightsLevel.Delegated : RightsLevel.Read;
        var detail = "Simulation\u00A0: droits estimés depuis les groupes du compte fictif (" + string.Join(", ", names) + ")\u00A0; les écritures ne modifient que l’annuaire fictif, en mémoire.";
        return new RightsInfo(level, SessionTexts.RightsLabel(level), true, detail);
    }

    // ---------------------------------------------------------------- OUs

    private void BuildOrganizationalUnits()
    {
        var random = root.Fork("ous");
        string Add(string key, string name, string parentDn, string description)
        {
            var dn = DistinguishedName.Child("OU", name, parentDn);
            var created = domainCreated + random.Between(TimeSpan.FromHours(1), TimeSpan.FromDays(400));
            ous.Add(new OuDraft
            {
                Guid = NewGuid(random),
                Dn = dn,
                Name = name,
                Description = description,
                Created = created,
                Changed = created + random.Between(TimeSpan.Zero, TimeSpan.FromDays(900)),
                Usn = random.Next(5_000, 20_000),
            });
            ouDn[key] = dn;
            return dn;
        }

        var rootDn = SimulationProfile.RootDn;
        Add("Domain Controllers", "Domain Controllers", rootDn, "Contrôleurs de domaine.");
        var people = Add("Utilisateurs", "Utilisateurs", rootDn, "Comptes des collaborateurs, par site et par service.");
        foreach (var site in SimulationProfile.Sites)
        {
            var siteDn = Add("Utilisateurs/" + site.Name, site.Name, people, $"Collaborateurs du site de {site.Name}.");
            foreach (var service in SimulationProfile.Services.Where(s => s.Site == site.Name))
            {
                Add($"Utilisateurs/{site.Name}/{service.Name}", service.Name, siteDn, $"Service {service.Name}, site de {site.Name}.");
            }
        }
        Add("Utilisateurs/Départs", "Départs", people, "Comptes désactivés en attente de suppression.");
        var workstations = Add("Postes", "Postes", rootDn, "Postes de travail, par site.");
        foreach (var site in SimulationProfile.Sites)
        {
            Add("Postes/" + site.Name, site.Name, workstations, $"Postes du site de {site.Name}.");
        }
        Add("Postes/Quarantaine", "Quarantaine", workstations, "Comptes ordinateur désactivés, en attente de vérification.");
        var servers = Add("Serveurs", "Serveurs", rootDn, "Serveurs membres du domaine.");
        Add("Serveurs/Applications", "Applications", servers, "Serveurs d’applications et de bases de données.");
        Add("Serveurs/Fichiers", "Fichiers", servers, "Serveurs de fichiers.");
        Add("Serveurs/Impression", "Impression", servers, "Serveurs d’impression.");
        var groupsDn = Add("Groupes", "Groupes", rootDn, "Groupes du domaine.");
        Add("Groupes/Sécurité", "Sécurité", groupsDn, "Groupes de sécurité globaux : services, sites, applications.");
        Add("Groupes/Distribution", "Distribution", groupsDn, "Listes de diffusion.");
        Add("Groupes/Ressources", "Ressources", groupsDn, "Groupes locaux de domaine des partages.");
        Add("Comptes de service", "Comptes de service", rootDn, "Comptes techniques des applications.");
        Add("Comptes à privilèges", "Comptes à privilèges", rootDn, "Comptes d’administration nominatifs.");
    }

    // ---------------------------------------------------------------- Groups

    private void BuildGroups()
    {
        var random = root.Fork("groups");
        var builtin = "CN=Builtin," + SimulationProfile.RootDn;
        var usersContainer = "CN=Users," + SimulationProfile.RootDn;
        var nextRid = 1100;
        GroupDraft Add(string name, string parentDn, int groupType, string sid, string description, int? adminCount = null, string? mail = null)
        {
            var created = domainCreated + random.Between(TimeSpan.Zero, TimeSpan.FromDays(600));
            var group = new GroupDraft
            {
                Guid = NewGuid(random),
                Sid = sid,
                Dn = DistinguishedName.Child("CN", name, parentDn),
                Name = name,
                GroupType = groupType,
                Description = description,
                AdminCount = adminCount,
                Mail = mail,
                Created = created,
                Changed = created + random.Between(TimeSpan.Zero, TimeSpan.FromDays(700)),
                Usn = random.Next(20_000, 900_000),
            };
            groups.Add(group);
            groupByName.Add(name, group);
            return group;
        }
        string Rid(int rid) => domainSid + "-" + rid.ToString(CultureInfo.InvariantCulture);
        string NextSid() => Rid(nextRid++);

        Add("Administrateurs", builtin, BuiltinLocalSecurity, "S-1-5-32-544", "Accès complet et illimité à l’ordinateur et au domaine.", 1);
        Add("Utilisateurs", builtin, BuiltinLocalSecurity, "S-1-5-32-545", "Les utilisateurs ne peuvent pas effectuer de modifications accidentelles du système.");
        Add("Invités", builtin, BuiltinLocalSecurity, "S-1-5-32-546", "Accès invité, restreint.");
        Add("Opérateurs de compte", builtin, BuiltinLocalSecurity, "S-1-5-32-548", "Gestion des comptes d’utilisateurs et des groupes.", 1);
        Add("Opérateurs de serveur", builtin, BuiltinLocalSecurity, "S-1-5-32-549", "Administration des contrôleurs de domaine.", 1);
        Add("Opérateurs d’impression", builtin, BuiltinLocalSecurity, "S-1-5-32-550", "Gestion des imprimantes du domaine.", 1);
        Add("Opérateurs de sauvegarde", builtin, BuiltinLocalSecurity, "S-1-5-32-551", "Sauvegarde et restauration des fichiers.", 1);
        Add("Utilisateurs du Bureau à distance", builtin, BuiltinLocalSecurity, "S-1-5-32-555", "Ouverture de session à distance.");

        Add("Admins du domaine", usersContainer, GlobalSecurity, Rid(512), "Administrateurs désignés du domaine.", 1);
        Add("Utilisateurs du domaine", usersContainer, GlobalSecurity, Rid(513), "Tous les utilisateurs du domaine.");
        Add("Invités du domaine", usersContainer, GlobalSecurity, Rid(514), "Tous les invités du domaine.");
        Add("Ordinateurs du domaine", usersContainer, GlobalSecurity, Rid(515), "Toutes les stations de travail et tous les serveurs joints au domaine.");
        Add("Contrôleurs de domaine", usersContainer, GlobalSecurity, Rid(516), "Tous les contrôleurs de domaine du domaine.");
        Add("Administrateurs du schéma", usersContainer, UniversalSecurity, Rid(518), "Administrateurs désignés du schéma.", 1);
        Add("Administrateurs de l’entreprise", usersContainer, UniversalSecurity, Rid(519), "Administrateurs désignés de l’entreprise.", 1);
        Add("Propriétaires créateurs de la stratégie de groupe", usersContainer, GlobalSecurity, Rid(520), "Les membres de ce groupe peuvent modifier la stratégie de groupe du domaine.");
        Add("Protected Users", usersContainer, GlobalSecurity, Rid(525), "Protections supplémentaires contre les menaces d’authentification.");

        var security = ouDn["Groupes/Sécurité"];
        foreach (var service in SimulationProfile.Services)
        {
            Add($"GG-{service.GroupName}-{service.Site}", security, GlobalSecurity, NextSid(), $"Service {service.Name}, site de {service.Site}.");
        }
        Add("GG-Admins-Postes", security, GlobalSecurity, NextSid(), "Administration des postes de travail.");
        Add("GG-Admins-Serveurs", security, GlobalSecurity, NextSid(), "Administration des serveurs membres.");
        Add("GG-Support-N1", security, GlobalSecurity, NextSid(), "Support de premier niveau.");
        Add("GG-Support-N2", security, GlobalSecurity, NextSid(), "Support de deuxième niveau.");
        foreach (var app in AppGroups)
        {
            Add("GG-App-" + app, security, GlobalSecurity, NextSid(), $"Utilisateurs de l’application {app}.");
        }
        var resources = ouDn["Groupes/Ressources"];
        foreach (var share in ShareNames)
        {
            Add($"DL-Partage-{share}-L", resources, DomainLocalSecurity, NextSid(), $"Partage {share} : lecture.");
            Add($"DL-Partage-{share}-M", resources, DomainLocalSecurity, NextSid(), $"Partage {share} : modification.");
        }
        var distribution = ouDn["Groupes/Distribution"];
        foreach (var site in SimulationProfile.Sites)
        {
            Add("LD-" + site.Name, distribution, UniversalDistribution, NextSid(), $"Liste de diffusion du site de {site.Name}.", null, $"ld-{Ascii(site.Name)}@{SimulationProfile.DnsName}");
        }
        Add("LD-Tous", distribution, UniversalDistribution, NextSid(), "Liste de diffusion de tous les sites.", null, "ld-tous@" + SimulationProfile.DnsName);
    }

    // ---------------------------------------------------------------- Users

    private UserDraft BuildUsers()
    {
        var names = root.Fork("users/names");
        var ids = root.Fork("users/ids");
        samTaken.Add(SimulationProfile.PersonLogin);
        var usersContainer = "CN=Users," + SimulationProfile.RootDn;

        // Built-in accounts first, as in a new domain.
        var administrator = AddUser(new UserDraft { Kind = UserKind.Builtin, Rid = 500, Sam = "Administrateur", Cn = "Administrateur", Uac = NeverExpiringUser, AdminCount = 1, Description = "Compte d’utilisateur d’administration du domaine." }, usersContainer);
        var guest = AddUser(new UserDraft { Kind = UserKind.Builtin, Rid = 501, Sam = "Invité", Cn = "Invité", Uac = AdValues.AccountDisabled | AdValues.PasswordNotRequired | NeverExpiringUser, PrimaryGroup = 514, Description = "Compte d’utilisateur invité pour l’accès au domaine." }, usersContainer);
        var krbtgt = AddUser(new UserDraft { Kind = UserKind.Builtin, Rid = 502, Sam = "krbtgt", Cn = "krbtgt", Uac = DisabledUser, AdminCount = 1, Description = "Compte de service du centre de distribution de clés." }, usersContainer);

        // People, service by service; the first person of each service is its manager.
        var managers = new List<UserDraft>();
        UserDraft? julien = null;
        UserDraft? camille = null;
        for (var s = 0; s < SimulationProfile.Services.Length; s++)
        {
            var service = SimulationProfile.Services[s];
            var parent = ouDn[$"Utilisateurs/{service.Site}/{service.Name}"];
            var titles = FrenchNames.Titles[service.Name];
            UserDraft? previous = null;
            for (var p = 0; p < service.People; p++)
            {
                var (given, surname, female, imported) = FixedPerson(service, p) ?? RandomPerson(names);
                if (service.Site == "Paris" && service.Name == "Commercial" && p == 2 && previous is not null)
                {
                    // Two homonyms in the same OU: the second gets « Prénom Nom 2 » as cn.
                    (given, surname, female) = (previous.Given!, previous.Surname!, previous.Female);
                }
                var isJulien = service.Site == "Paris" && service.Name == "Informatique" && p == 1;
                var user = NewPerson(given, surname, female, imported, service.Site, service.Name, parent, ids, isJulien ? SimulationProfile.PersonLogin : null);
                user.Title = isJulien ? "Technicien support" : titles.Pick(names, female, p == 0);
                user.IsManager = p == 0;
                user.ServiceIndex = s;
                AddUser(user, null);
                if (p == 0)
                {
                    managers.Add(user);
                }
                if (isJulien)
                {
                    julien = user;
                }
                if (service.Site == "Lyon" && service.Name == "Commercial" && p == 1)
                {
                    camille = user;
                }
                previous = user;
            }
        }
        var director = managers[0];
        foreach (var person in users.Where(u => u.Kind == UserKind.Person))
        {
            var manager = managers[person.ServiceIndex];
            person.ManagerDn = person.IsManager ? (ReferenceEquals(person, director) ? null : director.Dn) : manager.Dn;
        }

        // Departures: disabled, description « Départ le jj/mm/aaaa », no group.
        var departures = ouDn["Utilisateurs/Départs"];
        for (var d = 0; d < SimulationProfile.Departures; d++)
        {
            var service = names.Pick(SimulationProfile.Services);
            var (given, surname, female, _) = RandomPerson(names);
            var user = NewPerson(given, surname, female, false, service.Site, service.Name, departures, ids, null);
            user.Title = FrenchNames.Titles[service.Name].Pick(names, female, false);
            user.Departed = true;
            user.Uac = DisabledUser;
            user.Telephone = null;
            AddUser(user, null);
        }

        // Named administration accounts and service accounts.
        var privileged = ouDn["Comptes à privilèges"];
        foreach (var (sam, given, surname, female) in SimulationProfile.AdminPeople)
        {
            samTaken.Add(sam);
            AddUser(new UserDraft
            {
                Kind = UserKind.Admin,
                Sam = sam,
                Cn = sam,
                Upn = sam + "@" + SimulationProfile.DnsName,
                DisplayName = $"{given} {surname} (administration)",
                Given = given,
                Surname = surname,
                Female = female,
                Title = "Compte d’administration",
                Department = "Informatique",
                Office = "Paris",
                AdminCount = 1,
                Description = "Compte d’administration nominatif, sans messagerie.",
            }, privileged);
        }
        var serviceOu = ouDn["Comptes de service"];
        foreach (var sam in SimulationProfile.ServiceAccountNames)
        {
            samTaken.Add(sam);
            var label = sam["svc-".Length..];
            AddUser(new UserDraft
            {
                Kind = UserKind.Service,
                Sam = sam,
                Cn = sam,
                Upn = sam + "@" + SimulationProfile.DnsName,
                DisplayName = "Compte de service " + label,
                Uac = NeverExpiringUser,
                Description = $"Compte technique de l’application {label}.",
            }, serviceOu);
        }

        AssignUserStates(julien!, camille!);
        AssignUserDates(administrator, guest, krbtgt);
        for (var i = 0; i < users.Count; i++)
        {
            if (users[i].Rid == 0)
            {
                users[i].Rid = 2000 + i;
            }
        }
        return julien!;
    }

    private static (string Given, string Surname, bool Female, bool Imported)? FixedPerson(ServiceSpec service, int index) => (service.Site, service.Name, index) switch
    {
        ("Paris", "Informatique", 1) => ("Julien", "Martin", false, false),
        ("Lyon", "Commercial", 1) => ("Camille", "Bernard", true, false),
        ("Lille", "Commercial", 1) => ("Anne", "Le Gall", true, true),
        ("Lille", "Commercial", 2) => ("Loïc", "Le Goff", false, true),
        ("Lille", "Commercial", 3) => ("Aïssatou", "N'Diaye", true, true),
        _ => null,
    };

    private static (string Given, string Surname, bool Female, bool Imported) RandomPerson(SeededRandom names)
    {
        var female = names.Next(2) == 0;
        var given = names.Pick(female ? FrenchNames.Female : FrenchNames.Male);
        var surname = names.Pick(FrenchNames.Surnames);
        return (given, surname, female, false);
    }

    private UserDraft NewPerson(string given, string surname, bool female, bool imported, string site, string service, string parentDn, SeededRandom ids, string? fixedSam)
    {
        var sam = fixedSam ?? AllocateSam(given, surname);
        var siteSpec = SimulationProfile.Sites.First(s => s.Name == site);
        return new UserDraft
        {
            Kind = UserKind.Person,
            Sam = sam,
            Cn = imported ? $"{surname}, {given}" : $"{given} {surname}",
            Upn = sam + "@" + SimulationProfile.DnsName,
            DisplayName = $"{given} {surname}",
            Given = given,
            Surname = surname,
            Female = female,
            Mail = AllocateMail(given, surname),
            Department = service,
            Office = site,
            Site = site,
            Telephone = NextPhone(siteSpec.PhonePrefix, ids),
            EmployeeId = NextEmployeeId(ids),
            ParentDn = parentDn,
        };
    }

    private UserDraft AddUser(UserDraft user, string? parentDn)
    {
        var parent = parentDn ?? user.ParentDn ?? throw new InvalidOperationException("User without parent.");
        user.ParentDn = parent;
        user.Cn = UniqueCn(parent, user.Cn);
        user.Dn = DistinguishedName.Child("CN", user.Cn, parent);
        user.Guid = NewGuid(userGuids);
        users.Add(user);
        return user;
    }

    /// <summary>Exact populations among the active people, chosen by shuffles (docs/SIMULATION.md § 4.4).</summary>
    private void AssignUserStates(UserDraft julien, UserDraft camille)
    {
        var random = root.Fork("users/states");
        var people = users.Where(u => u.Kind == UserKind.Person && !u.Departed).ToList();

        var leaveCandidates = people.Where(u => !u.IsManager && !ReferenceEquals(u, julien) && !ReferenceEquals(u, camille)).ToList();
        random.Shuffle(leaveCandidates);
        foreach (var user in leaveCandidates.Take(SimulationProfile.LongLeave))
        {
            user.Uac = DisabledUser;
            user.LongLeave = true;
            user.Description = "Congé de longue durée";
        }

        var active = people.Where(u => !u.LongLeave && !ReferenceEquals(u, julien) && !ReferenceEquals(u, camille)).ToList();
        random.Shuffle(active);
        var next = 0;
        List<UserDraft> Take(int count)
        {
            var slice = active.GetRange(next, count);
            next += count;
            return slice;
        }
        foreach (var u in Take(SimulationProfile.NeverExpiringPeople))
        {
            u.Uac = NeverExpiringUser;
            u.Password = PasswordKind.NeverExpires;
        }
        foreach (var u in Take(SimulationProfile.MustChange))
        {
            u.Password = PasswordKind.MustChange;
            u.RecentlyCreated = true;
            u.Logon = LogonKind.None;
        }
        foreach (var u in Take(SimulationProfile.Expired))
        {
            u.Password = PasswordKind.Expired;
        }
        foreach (var u in Take(SimulationProfile.Expiring))
        {
            u.Password = PasswordKind.Expiring;
        }
        foreach (var u in Take(SimulationProfile.LockedPeople).Append(camille))
        {
            u.Locked = true;
        }
        foreach (var u in Take(SimulationProfile.LockoutExpired))
        {
            u.LockoutExpired = true;
        }
        foreach (var u in Take(SimulationProfile.RecentWithoutLogon))
        {
            u.RecentlyCreated = true;
            u.Logon = LogonKind.None;
        }
        foreach (var u in Take(SimulationProfile.StaleLogonPeople))
        {
            u.Logon = LogonKind.Stale;
        }
        foreach (var u in Take(SimulationProfile.Interns))
        {
            u.Intern = true;
            u.Description = "Stagiaire";
        }
        foreach (var u in Take(SimulationProfile.BadPasswordPeople))
        {
            u.BadPasswordCount = random.Next(1, 5);
        }
        foreach (var u in users.Where(u => u.Kind == UserKind.Service))
        {
            u.Password = PasswordKind.NeverExpires;
        }
    }

    private void AssignUserDates(UserDraft administrator, UserDraft guest, UserDraft krbtgt)
    {
        var random = root.Fork("users/dates");
        foreach (var u in users)
        {
            u.Usn = random.Next(20_000, 990_000);
            if (u.Kind == UserKind.Builtin)
            {
                u.Created = domainCreated;
                if (ReferenceEquals(u, administrator))
                {
                    u.Password = PasswordKind.NeverExpires;
                    u.PasswordSet = Ago(random.Between(TimeSpan.FromDays(200), TimeSpan.FromDays(1500)));
                    u.LastLogon = Ago(random.Between(TimeSpan.FromDays(1), TimeSpan.FromDays(10)));
                }
                else if (ReferenceEquals(u, guest))
                {
                    u.Password = PasswordKind.MustChange;
                    u.LastLogon = null;
                }
                else if (ReferenceEquals(u, krbtgt))
                {
                    u.PasswordSet = domainCreated + TimeSpan.FromHours(1);
                    u.LastLogon = null;
                }
                u.Changed = Latest(u.Created, u.PasswordSet) + TimeSpan.FromMinutes(5);
                continue;
            }
            if (u.Departed || u.LongLeave)
            {
                u.Created = Ago(random.Between(TimeSpan.FromDays(400), TimeSpan.FromDays(8 * 365)));
                u.PasswordSet = Ago(random.Between(TimeSpan.FromDays(100), TimeSpan.FromDays(900)));
                DateTimeOffset left;
                if (u.Departed)
                {
                    left = Ago(random.Between(TimeSpan.FromDays(5), TimeSpan.FromDays(200)));
                    u.Description = "Départ le " + FrenchText.ShortDate(LocalDays.DateOf(left, timeZone));
                    u.LastLogon = left - random.Between(TimeSpan.Zero, TimeSpan.FromDays(3));
                }
                else
                {
                    u.LastLogon = Ago(random.Between(TimeSpan.FromDays(60), TimeSpan.FromDays(300)));
                    left = u.LastLogon.Value + random.Between(TimeSpan.FromDays(1), TimeSpan.FromDays(20));
                }
                u.Created = Earliest(u.Created, u.PasswordSet!.Value, u.LastLogon!.Value, random);
                u.Changed = Latest(left, u.PasswordSet);
                continue;
            }

            // Active people, administration and service accounts.
            var createdAge = u.RecentlyCreated
                ? random.Between(TimeSpan.FromDays(1), TimeSpan.FromDays(29))
                : u.Kind == UserKind.Person
                    ? random.Between(TimeSpan.FromDays(31), TimeSpan.FromDays(8 * 365))
                    : random.Between(TimeSpan.FromDays(200), TimeSpan.FromDays(5 * 365));
            u.Created = Ago(createdAge);
            switch (u.Password)
            {
                case PasswordKind.MustChange:
                    u.PasswordSet = null;
                    break;
                case PasswordKind.NeverExpires:
                    u.PasswordSet = Ago(random.Between(TimeSpan.FromDays(100), TimeSpan.FromDays(900)));
                    break;
                case PasswordKind.Expired:
                    u.PasswordSet = Ago(random.Between(TimeSpan.FromDays(91), TimeSpan.FromDays(130)));
                    break;
                case PasswordKind.Expiring:
                    var expiry = reference + random.Between(TimeSpan.FromHours(1), TimeSpan.FromDays(6) + TimeSpan.FromHours(20));
                    u.PasswordSet = expiry - MaxPasswordAge;
                    break;
                default:
                    var longest = Min(TimeSpan.FromDays(82), createdAge - TimeSpan.FromMinutes(10));
                    u.PasswordSet = Ago(random.Between(TimeSpan.FromHours(1), longest));
                    break;
            }
            if (u.PasswordSet is DateTimeOffset passwordSet)
            {
                u.Created = Earliest(u.Created, passwordSet, passwordSet, random);
            }
            switch (u.Logon)
            {
                case LogonKind.None:
                    u.LastLogon = null;
                    break;
                case LogonKind.Stale:
                    u.LastLogon = Ago(random.Between(TimeSpan.FromDays(91), TimeSpan.FromDays(400)));
                    u.Created = Earliest(u.Created, u.LastLogon.Value, u.LastLogon.Value, random);
                    break;
                default:
                    if (u.Password == PasswordKind.Expired)
                    {
                        // Last logon before the password expired.
                        u.LastLogon = u.PasswordSet!.Value + MaxPasswordAge - random.Between(TimeSpan.FromDays(1), TimeSpan.FromDays(10));
                    }
                    else
                    {
                        var available = reference - u.Created - TimeSpan.FromMinutes(5);
                        var longest = Min(u.Kind == UserKind.Service ? TimeSpan.FromDays(1) : TimeSpan.FromDays(14), available);
                        u.LastLogon = Ago(random.Between(Min(TimeSpan.FromMinutes(10), longest), longest));
                    }
                    break;
            }
            if (u.Locked)
            {
                u.LockoutAt = Ago(random.Between(TimeSpan.FromMinutes(13), TimeSpan.FromMinutes(28)));
                u.BadPasswordCount = 5;
            }
            else if (u.LockoutExpired)
            {
                u.LockoutAt = Ago(random.Between(TimeSpan.FromHours(2), TimeSpan.FromHours(5)));
            }
            if (u.Intern)
            {
                u.AccountExpiresAt = reference + random.Between(TimeSpan.FromDays(10), TimeSpan.FromDays(70));
            }
            var changedAge = random.Between(TimeSpan.Zero, Min(TimeSpan.FromDays(60), reference - u.Created));
            u.Changed = Latest(Ago(changedAge), Latest(u.PasswordSet ?? u.Created, u.LockoutAt));
        }
    }

    // ---------------------------------------------------------------- Computers

    private void BuildComputers()
    {
        var random = root.Fork("computers");
        var ids = root.Fork("computers/ids");
        var numbers = new Dictionary<string, int>(StringComparer.Ordinal);

        // Domain controllers.
        var dcOu = ouDn["Domain Controllers"];
        string[] dcSites = ["Paris", "Lyon"];
        for (var i = 0; i < 2; i++)
        {
            var name = "DC0" + (i + 1).ToString(CultureInfo.InvariantCulture);
            computers.Add(new ComputerDraft
            {
                Kind = ComputerKind.DomainController,
                Guid = NewGuid(ids),
                Rid = 1000 + i,
                Name = name,
                DnsHostName = name + "." + SimulationProfile.DnsName,
                ParentDn = dcOu,
                OperatingSystem = "Windows Server 2022 Datacenter",
                OperatingSystemVersion = "10.0 (20348)",
                Uac = DomainControllerAccount,
                PrimaryGroup = 516,
                Location = dcSites[i] + " – salle serveurs",
                Site = dcSites[i],
            });
        }

        // Active workstations of the working OU, site by site.
        var systems = SimulationProfile.WorkstationSystems.SelectMany(o => Enumerable.Repeat(o, o.Count)).ToList();
        root.Fork("computers/os").Shuffle(systems);
        var systemIndex = 0;
        foreach (var site in SimulationProfile.Sites)
        {
            var laptops = (site.Workstations * SimulationProfile.LaptopPercent + 50) / 100;
            var flags = Enumerable.Range(0, site.Workstations).Select(i => i < laptops).ToList();
            random.Shuffle(flags);
            for (var i = 0; i < site.Workstations; i++)
            {
                var number = i + 1;
                var os = systems[systemIndex++];
                computers.Add(NewWorkstation(ComputerKind.Workstation, site, flags[i], number, ouDn["Postes/" + site.Name], os, ids));
            }
            numbers[site.Name] = site.Workstations;
        }

        // Quarantined (disabled) workstations, numbered after each site's last one.
        for (var k = 0; k < SimulationProfile.QuarantinedWorkstations; k++)
        {
            var site = SimulationProfile.Sites[k % SimulationProfile.Sites.Length];
            var number = ++numbers[site.Name];
            var os = random.Pick(SimulationProfile.WorkstationSystems);
            computers.Add(NewWorkstation(ComputerKind.Quarantined, site, random.Chance(SimulationProfile.LaptopPercent), number, ouDn["Postes/Quarantaine"], os, ids));
        }

        // Just joined, still in CN=Computers (outside the working OU). The last one has not registered its DNS name yet
        // (Domenia 1 TRV-047: « un poste sans DNS »); the draws are unchanged, so nothing else of the world moves.
        const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        for (var k = 0; k < SimulationProfile.JustJoinedWorkstations; k++)
        {
            var suffix = string.Concat(Enumerable.Range(0, 7).Select(_ => Alphabet[random.Next(Alphabet.Length)]));
            var name = "DESKTOP-" + suffix;
            computers.Add(new ComputerDraft
            {
                Kind = ComputerKind.JustJoined,
                Guid = NewGuid(ids),
                Name = name,
                DnsHostName = k == SimulationProfile.JustJoinedWorkstations - 1 ? null : name.ToLowerInvariant() + "." + SimulationProfile.DnsName,
                ParentDn = "CN=Computers," + SimulationProfile.RootDn,
                OperatingSystem = "Windows 11 Professionnel",
                OperatingSystemVersion = "10.0 (26100)",
                Uac = Workstation,
                PrimaryGroup = 515,
            });
        }

        // Member servers.
        var serverOs = new List<(string Os, string Version)>();
        serverOs.AddRange(Enumerable.Repeat(("Windows Server 2022 Standard", "10.0 (20348)"), 6));
        serverOs.AddRange(Enumerable.Repeat(("Windows Server 2022 Datacenter", "10.0 (20348)"), 4));
        serverOs.AddRange(Enumerable.Repeat(("Windows Server 2025 Standard", "10.0 (26100)"), 4));
        serverOs.AddRange(Enumerable.Repeat(("Windows Server 2019 Standard", "10.0 (17763)"), 4));
        root.Fork("servers/os").Shuffle(serverOs);
        (string Prefix, int Count, string Ou)[] serverGroups =
        [
            ("SRV-APP", 6, "Serveurs/Applications"), ("SRV-SQL", 3, "Serveurs/Applications"), ("SRV-WEB", 3, "Serveurs/Applications"),
            ("SRV-FIC", 4, "Serveurs/Fichiers"), ("SRV-IMP", 2, "Serveurs/Impression"),
        ];
        var serverIndex = 0;
        foreach (var (prefix, count, ou) in serverGroups)
        {
            for (var n = 1; n <= count; n++)
            {
                var name = prefix + "-" + n.ToString("D2", CultureInfo.InvariantCulture);
                var (os, version) = serverOs[serverIndex++];
                computers.Add(new ComputerDraft
                {
                    Kind = ComputerKind.Server,
                    Guid = NewGuid(ids),
                    Name = name,
                    DnsHostName = name.ToLowerInvariant() + "." + SimulationProfile.DnsName,
                    ParentDn = ouDn[ou],
                    OperatingSystem = os,
                    OperatingSystemVersion = version,
                    Uac = Workstation,
                    PrimaryGroup = 515,
                    Location = "Paris – salle serveurs",
                    Site = "Paris",
                });
            }
        }

        AssignComputerStates(random);
        for (var i = 0; i < computers.Count; i++)
        {
            if (computers[i].Rid == 0)
            {
                computers[i].Rid = 5000 + i;
            }
        }
    }

    private static ComputerDraft NewWorkstation(ComputerKind kind, SiteSpec site, bool laptop, int number, string parentDn, OsSpec os, SeededRandom ids)
    {
        var name = $"{(laptop ? "PT" : "PC")}-{site.Code}-{number.ToString("D4", CultureInfo.InvariantCulture)}";
        return new ComputerDraft
        {
            Kind = kind,
            Guid = NewGuid(ids),
            Name = name,
            DnsHostName = name.ToLowerInvariant() + "." + SimulationProfile.DnsName,
            ParentDn = parentDn,
            OperatingSystem = os.OperatingSystem,
            OperatingSystemVersion = os.Version,
            Uac = kind == ComputerKind.Quarantined ? DisabledWorkstation : Workstation,
            PrimaryGroup = 515,
            Laptop = laptop,
            Site = site.Name,
        };
    }

    /// <summary>Exact workstation states (docs/SIMULATION.md § 4.5), then dates, descriptions, locations and LAPS.</summary>
    private void AssignComputerStates(SeededRandom random)
    {
        var active = ActiveWorkstations();
        var order = Enumerable.Range(0, active.Count).ToList();
        root.Fork("computers/states").Shuffle(order);
        var next = 0;
        IEnumerable<int> Take(int count)
        {
            var slice = order.GetRange(next, count);
            next += count;
            return slice;
        }
        foreach (var i in Take(SimulationProfile.StaleWorkstations))
        {
            active[i].State = WorkstationState.Stale;
        }
        foreach (var i in Take(SimulationProfile.NeverLoggedOnWorkstations))
        {
            active[i].State = WorkstationState.NeverLoggedOn;
        }
        foreach (var i in Take(SimulationProfile.MachinePasswordOldOnly))
        {
            active[i].State = WorkstationState.PasswordOld;
        }
        foreach (var i in Take(SimulationProfile.RecentlyCreatedWorkstations))
        {
            active[i].State = WorkstationState.RecentlyCreated;
        }
        // Probes always in error: fixed workstations among the remaining ones.
        foreach (var i in order.Skip(next).Where(i => !active[i].Laptop).Take(SimulationProfile.ErrorProbes))
        {
            active[i].ErrorProbe = true;
        }

        var dates = root.Fork("computers/dates");
        foreach (var c in computers)
        {
            c.Usn = dates.Next(20_000, 990_000);
            switch (c.Kind)
            {
                case ComputerKind.DomainController:
                    c.Created = domainCreated + TimeSpan.FromHours(c.Rid - 999);
                    c.PasswordSet = Ago(dates.Between(TimeSpan.FromHours(1), TimeSpan.FromDays(29)));
                    c.LastLogon = Ago(dates.Between(TimeSpan.FromMinutes(5), TimeSpan.FromDays(1)));
                    break;
                case ComputerKind.Quarantined:
                    c.LastLogon = Ago(dates.Between(TimeSpan.FromDays(100), TimeSpan.FromDays(500)));
                    c.PasswordSet = c.LastLogon - dates.Between(TimeSpan.Zero, TimeSpan.FromDays(25));
                    c.Created = Earliest(Ago(dates.Between(TimeSpan.FromDays(400), TimeSpan.FromDays(6 * 365))), c.PasswordSet.Value, c.PasswordSet.Value, dates);
                    c.Description = "Désactivé : poste non retrouvé lors de l’inventaire.";
                    break;
                case ComputerKind.JustJoined:
                    c.Created = Ago(dates.Between(TimeSpan.FromDays(1), TimeSpan.FromDays(20)));
                    c.PasswordSet = c.Created + TimeSpan.FromMinutes(3);
                    c.LastLogon = Ago(dates.Between(TimeSpan.FromMinutes(10), reference - c.Created - TimeSpan.FromMinutes(10)));
                    break;
                case ComputerKind.Server:
                    c.Created = Ago(dates.Between(TimeSpan.FromDays(200), TimeSpan.FromDays(6 * 365)));
                    c.PasswordSet = Ago(dates.Between(TimeSpan.FromHours(1), TimeSpan.FromDays(29)));
                    c.LastLogon = Ago(dates.Between(TimeSpan.FromMinutes(5), TimeSpan.FromDays(10)));
                    break;
                default:
                    WorkstationDates(c, dates);
                    break;
            }
            c.Changed = Latest(c.Created, c.PasswordSet);
        }

        // About 40 % of the fixed workstations carry their user's name, with managedBy.
        var desktops = active.Where(c => !c.Laptop).ToList();
        random.Shuffle(desktops);
        var named = (desktops.Count * 40 + 50) / 100;
        var peopleBySite = users.Where(u => u.Kind == UserKind.Person && u.Active).GroupBy(u => u.Site!).ToDictionary(g => g.Key, g => g.ToList(), StringComparer.Ordinal);
        foreach (var c in desktops.Take(named))
        {
            var owner = random.Pick(peopleBySite[c.Site!]);
            c.Description = "Poste de " + owner.DisplayName;
            c.ManagedByDn = owner.Dn;
        }
        foreach (var c in computers.Where(c => c.Kind is ComputerKind.Workstation or ComputerKind.Quarantined))
        {
            c.Location = $"{c.Site} – bâtiment {(char)('A' + random.Next(3))}, étage {random.Next(5).ToString(CultureInfo.InvariantCulture)}";
        }

        // Windows LAPS: expiration dates only.
        var laps = Enumerable.Range(0, active.Count).ToList();
        root.Fork("computers/laps").Shuffle(laps);
        var lapsDates = root.Fork("computers/laps/dates");
        for (var k = 0; k < laps.Count; k++)
        {
            var c = active[laps[k]];
            if (k < SimulationProfile.WithoutLaps)
            {
                c.Laps = LapsKind.None;
                continue;
            }
            c.Laps = LapsKind.Windows;
            c.LapsExpiration = k < SimulationProfile.WithoutLaps + SimulationProfile.LapsExpired
                ? Ago(lapsDates.Between(TimeSpan.FromDays(1), TimeSpan.FromDays(20)))
                : reference + lapsDates.Between(TimeSpan.FromDays(1), TimeSpan.FromDays(30));
        }
    }

    private void WorkstationDates(ComputerDraft c, SeededRandom dates)
    {
        switch (c.State)
        {
            case WorkstationState.Stale:
                c.LastLogon = Ago(dates.Between(TimeSpan.FromDays(91), TimeSpan.FromDays(400)));
                c.PasswordSet = c.LastLogon - dates.Between(TimeSpan.Zero, TimeSpan.FromDays(20));
                c.Created = Earliest(Ago(dates.Between(TimeSpan.FromDays(61), TimeSpan.FromDays(7 * 365))), c.PasswordSet.Value, c.PasswordSet.Value, dates);
                break;
            case WorkstationState.NeverLoggedOn:
                c.Created = Ago(dates.Between(TimeSpan.FromDays(61), TimeSpan.FromDays(700)));
                c.PasswordSet = c.Created + dates.Between(TimeSpan.Zero, TimeSpan.FromMinutes(10));
                c.LastLogon = null;
                break;
            case WorkstationState.PasswordOld:
                c.PasswordSet = Ago(dates.Between(TimeSpan.FromDays(61), TimeSpan.FromDays(120)));
                c.LastLogon = Ago(dates.Between(TimeSpan.FromMinutes(10), TimeSpan.FromDays(14)));
                c.Created = Earliest(Ago(dates.Between(TimeSpan.FromDays(61), TimeSpan.FromDays(7 * 365))), c.PasswordSet.Value, c.PasswordSet.Value, dates);
                break;
            case WorkstationState.RecentlyCreated:
                var createdAge = dates.Between(TimeSpan.FromDays(1), TimeSpan.FromDays(29));
                c.Created = Ago(createdAge);
                c.PasswordSet = Ago(dates.Between(TimeSpan.FromHours(1), createdAge - TimeSpan.FromMinutes(10)));
                c.LastLogon = Ago(dates.Between(TimeSpan.FromMinutes(10), Min(TimeSpan.FromDays(14), createdAge - TimeSpan.FromMinutes(10))));
                break;
            default:
                c.Created = Ago(dates.Between(TimeSpan.FromDays(61), TimeSpan.FromDays(7 * 365)));
                c.PasswordSet = Ago(dates.Between(TimeSpan.FromHours(1), TimeSpan.FromDays(29)));
                c.LastLogon = Ago(dates.Between(TimeSpan.FromMinutes(10), TimeSpan.FromDays(14)));
                break;
        }
    }

    private List<ComputerDraft> ActiveWorkstations() => [.. computers.Where(c => c.Kind == ComputerKind.Workstation)];

    // ---------------------------------------------------------------- Memberships (AGDLP)

    private void BuildMemberships(UserDraft julien)
    {
        var random = root.Fork("groups/members");
        void Member(string groupName, UserDraft user)
        {
            var group = groupByName[groupName];
            group.Members.Add(user.Dn);
            user.MemberOf.Add(group.Dn);
        }
        void Nest(string childName, string parentName)
        {
            var child = groupByName[childName];
            var parent = groupByName[parentName];
            parent.Members.Add(child.Dn);
            child.MemberOf.Add(parent.Dn);
        }

        var applications = new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            ["Direction"] = ["Intranet", "VPN", "Messagerie"],
            ["Finances"] = ["Compta", "Paie", "Intranet"],
            ["Ressources humaines"] = ["Paie", "Planning", "Intranet"],
            ["Informatique"] = ["VPN", "GED", "Intranet", "CRM"],
            ["Juridique"] = ["GED", "Intranet"],
            ["Communication"] = ["Intranet", "GED", "Messagerie"],
            ["Achats"] = ["Achats", "Stocks", "Compta"],
            ["Commercial"] = ["CRM", "Planning", "VPN"],
            ["Logistique"] = ["Stocks", "Planning"],
        };
        foreach (var person in users.Where(u => u.Kind == UserKind.Person && !u.Departed))
        {
            var service = SimulationProfile.Services[person.ServiceIndex];
            Member($"GG-{service.GroupName}-{service.Site}", person);
            Member("LD-" + service.Site, person);
            if (!person.Active)
            {
                continue;
            }
            var apps = applications[service.Name].ToList();
            random.Shuffle(apps);
            foreach (var app in apps.Take(random.Next(0, Math.Min(3, apps.Count) + 1)))
            {
                Member("GG-App-" + app, person);
            }
        }

        // Support teams of the IT service: Julien Martin and five colleagues in N2, ten others in N1.
        var it = users.Where(u => u.Kind == UserKind.Person && u.Active && u.Department == "Informatique" && !ReferenceEquals(u, julien)).ToList();
        random.Shuffle(it);
        Member("GG-Support-N2", julien);
        foreach (var u in it.Take(5))
        {
            Member("GG-Support-N2", u);
        }
        foreach (var u in it.Skip(5).Take(10))
        {
            Member("GG-Support-N1", u);
        }

        var admins = users.Where(u => u.Kind == UserKind.Admin).ToList();
        for (var i = 0; i < admins.Count; i++)
        {
            Member("GG-Admins-Postes", admins[i]);
            Member("GG-Admins-Serveurs", admins[i]);
            Member("Protected Users", admins[i]);
            if (i < 2)
            {
                Member("Admins du domaine", admins[i]);
            }
        }
        var administrator = users.First(u => u.Rid == 500);
        Member("Admins du domaine", administrator);
        Member("Administrateurs du schéma", administrator);
        Member("Administrateurs de l’entreprise", administrator);
        Member("Propriétaires créateurs de la stratégie de groupe", administrator);
        Member("Administrateurs", administrator);
        Member("Invités", users.First(u => u.Rid == 501));
        Member("Opérateurs de sauvegarde", users.First(u => u.Sam == "svc-sauvegarde"));
        Member("Opérateurs d’impression", users.First(u => u.Sam == "svc-impression"));

        foreach (var service in SimulationProfile.Services)
        {
            var gg = $"GG-{service.GroupName}-{service.Site}";
            Nest(gg, $"DL-Partage-{service.GroupName}-M");
            Nest(gg, "DL-Partage-Commun-M");
        }
        foreach (var site in SimulationProfile.Sites)
        {
            Nest("LD-" + site.Name, "LD-Tous");
        }
        Nest("GG-Support-N2", "GG-Admins-Postes");
        Nest("GG-Support-N1", "Utilisateurs du Bureau à distance");
        Nest("Admins du domaine", "Administrateurs");
        Nest("Administrateurs de l’entreprise", "Administrateurs");
        Nest("Utilisateurs du domaine", "Utilisateurs");
        Nest("Invités du domaine", "Invités");
    }

    // ---------------------------------------------------------------- Snapshot

    private DirectorySnapshot ToSnapshot()
    {
        var policy = new DomainPasswordPolicy(MaxPasswordAge, 12, 24, 5, TimeSpan.FromMinutes(30), TimeSpan.FromMinutes(30));
        var domain = new DomainInfo(
            SimulationProfile.DnsName,
            SimulationProfile.NetbiosName,
            SimulationProfile.RootDn,
            domainSid,
            [new DomainController("DC01." + SimulationProfile.DnsName, "Paris"), new DomainController("DC02." + SimulationProfile.DnsName, "Lyon")],
            policy,
            ["CN=Users," + SimulationProfile.RootDn, "CN=Computers," + SimulationProfile.RootDn, "CN=Builtin," + SimulationProfile.RootDn]);
        return new DirectorySnapshot(
            domain,
            reference - TimeSpan.FromMinutes(12),
            true,
            [.. ous.Select(o => new DirectoryOu(o.Guid, o.Dn, o.Name, o.Description, null, o.Created, o.Changed, o.Usn))],
            [.. users.Select(ToRecord)],
            [.. computers.Select(ToRecord)],
            [.. groups.Select(g => new DirectoryGroup(g.Guid, g.Sid, g.Dn, g.Name, g.Name, g.GroupType, g.Description, g.Mail, null, g.AdminCount,
                [.. g.Members], [.. g.MemberOf], g.Created, g.Changed, g.Usn))]);
    }

    private DirectoryUser ToRecord(UserDraft u)
    {
        var neverExpires = AdValues.HasFlag(u.Uac, AdValues.DontExpirePassword);
        var mustChange = u.Password == PasswordKind.MustChange;
        long? expiry = null;
        if (neverExpires)
        {
            expiry = AdValues.Never;
        }
        else if (mustChange)
        {
            expiry = 0;
        }
        else if (u.PasswordSet is DateTimeOffset set)
        {
            expiry = AdValues.ToFileTime(set + MaxPasswordAge);
        }
        var computed = 0;
        if (u.Locked)
        {
            computed |= AdValues.LockedOut;
        }
        if (!neverExpires && !mustChange && u.PasswordSet is DateTimeOffset passwordSet && passwordSet + MaxPasswordAge <= reference)
        {
            computed |= AdValues.PasswordExpired;
        }
        return new DirectoryUser(
            u.Guid,
            domainSid + "-" + u.Rid.ToString(CultureInfo.InvariantCulture),
            u.Dn,
            u.Cn,
            u.Sam,
            u.Upn,
            u.DisplayName,
            u.Given,
            u.Surname,
            u.Mail,
            u.Title,
            u.Department,
            u.Office,
            u.Telephone,
            u.ManagerDn,
            u.Description,
            u.EmployeeId,
            u.Uac,
            computed,
            u.LockoutAt is DateTimeOffset lockout ? AdValues.ToFileTime(lockout) : 0,
            u.BadPasswordCount,
            mustChange ? 0 : u.PasswordSet is DateTimeOffset pwd ? AdValues.ToFileTime(pwd) : 0,
            expiry,
            u.LastLogon is DateTimeOffset logon ? AdValues.ToFileTime(logon) : (long?)null,
            u.AccountExpiresAt is DateTimeOffset expires ? AdValues.ToFileTime(expires) : AdValues.Never,
            u.Created,
            u.Changed,
            u.Usn,
            u.AdminCount,
            u.PrimaryGroup,
            [.. u.MemberOf]);
    }

    private DirectoryComputer ToRecord(ComputerDraft c) => new(
        c.Guid,
        domainSid + "-" + c.Rid.ToString(CultureInfo.InvariantCulture),
        DistinguishedName.Child("CN", c.Name, c.ParentDn),
        c.Name,
        c.DnsHostName,
        c.Name + "$",
        c.Description,
        c.Location,
        c.ManagedByDn,
        c.OperatingSystem,
        c.OperatingSystemVersion,
        c.Uac,
        c.LastLogon is DateTimeOffset logon ? AdValues.ToFileTime(logon) : (long?)null,
        c.PasswordSet is DateTimeOffset set ? AdValues.ToFileTime(set) : (long?)null,
        c.Created,
        c.Changed,
        c.Usn,
        c.Laps,
        c.LapsExpiration is DateTimeOffset laps ? AdValues.ToFileTime(laps) : (long?)null,
        c.PrimaryGroup,
        []);

    // ---------------------------------------------------------------- Observations (round 0)

    private (FleetObservations Observations, PresenceModel Presence) BuildObservations()
    {
        var active = ActiveWorkstations();
        var inactive = active.Where(c => c.State is WorkstationState.Stale or WorkstationState.NeverLoggedOn).ToHashSet();
        var errors = active.Where(c => c.ErrorProbe).ToHashSet();

        // Inventory issues only on workstations with no directory point, so every workstation has at most one family of points.
        var issueCandidates = active.Where(c => !inactive.Contains(c) && !errors.Contains(c) && c.State != WorkstationState.PasswordOld).ToList();
        root.Fork("inventory/issues").Shuffle(issueCandidates);
        var cursor = 0;
        List<ComputerDraft> Take(int count)
        {
            var slice = issueCandidates.GetRange(cursor, count);
            cursor += count;
            return slice;
        }
        var critical = Take(SimulationProfile.CriticalDiskPercents.Length);
        var tight = Take(SimulationProfile.TightDisks).ToHashSet();
        var uptime = Take(SimulationProfile.LongUptime).ToHashSet();
        var noInventory = Take(SimulationProfile.WithoutInventoryOthers).ToHashSet();
        var criticalPercent = critical.Select((c, i) => (c, SimulationProfile.CriticalDiskPercents[i])).ToDictionary(x => x.c, x => x.Item2);
        var pingFiltered = critical[SimulationProfile.PingFilteredIndex];

        // Inventory readings.
        var inv = root.Fork("inventory");
        var inventories = new Dictionary<ComputerDraft, InventoryMeasure>();
        var firstKnown = true;
        var expiredInactive = 0;
        foreach (var c in active)
        {
            if (inactive.Contains(c))
            {
                inventories[c] = expiredInactive++ < SimulationProfile.InactiveWithExpiredInventory
                    ? new InventoryMeasure(MeasureState.Expired, Ago(inv.Between(TimeSpan.FromDays(40), TimeSpan.FromDays(200))), null, null, null, null, null, null, null)
                    : InventoryMeasure.Unread;
                continue;
            }
            if (errors.Contains(c))
            {
                inventories[c] = new InventoryMeasure(MeasureState.Error, null, null, null, null, null, null, null, null);
                continue;
            }
            if (noInventory.Contains(c))
            {
                inventories[c] = InventoryMeasure.Unread;
                continue;
            }
            var nominal = inv.Next(100) switch { < 60 => 256L, < 95 => 512L, _ => 1000L };
            var size = nominal * 1_000_000_000L - inv.Next(400, 2500) * 1_000_000L;
            var percent = criticalPercent.TryGetValue(c, out var p) ? p
                : tight.Contains(c) ? inv.Next(102, 199) / 10.0
                : inv.Next(202, 851) / 10.0;
            var free = (long)Math.Round(size * percent / 100.0, MidpointRounding.AwayFromZero);
            var bootAge = uptime.Contains(c)
                ? inv.Between(TimeSpan.FromDays(31), TimeSpan.FromDays(75))
                : inv.Between(TimeSpan.FromHours(1), TimeSpan.FromDays(12));
            TimeSpan checkAge;
            if (firstKnown)
            {
                checkAge = TimeSpan.FromMinutes(55);
                firstKnown = false;
            }
            else
            {
                checkAge = inv.Between(TimeSpan.FromMinutes(56), Min(bootAge, TimeSpan.FromDays(6)));
            }
            var memory = inv.Next(100) switch { < 25 => 8L, < 85 => 16L, _ => 32L } * 1024L * 1024L * 1024L;
            var model = inv.Pick(c.Laptop ? SimulationProfile.LaptopModels : SimulationProfile.DesktopModels);
            var build = WindowsRelease.ParseBuild(c.OperatingSystemVersion)?.ToString(CultureInfo.InvariantCulture);
            inventories[c] = new InventoryMeasure(MeasureState.Known, Ago(checkAge), size, free, Ago(bootAge), model, memory, "Microsoft " + c.OperatingSystem, build);
        }

        // Presence: fixed rank per workstation; the online ones are the lowest ranks among the eligible.
        var ranks = Enumerable.Range(0, active.Count).ToList();
        root.Fork("presence").Shuffle(ranks);
        var target = Weekend ? SimulationProfile.OnlineWeekend : SimulationProfile.OnlineWorkday;
        var neverAnswer = inactive.Append(pingFiltered).ToHashSet();
        var eligible = Enumerable.Range(0, active.Count).Where(i => !neverAnswer.Contains(active[i]) && !errors.Contains(active[i])).OrderBy(i => ranks[i]).ToList();
        var online = eligible.Take(target).ToHashSet();
        var remaining = Enumerable.Range(0, active.Count).Where(i => !online.Contains(i) && !errors.Contains(active[i]) && active[i] != pingFiltered).ToList();
        root.Fork("presence/initial").Shuffle(remaining);
        var neverChecked = remaining.Take(SimulationProfile.NeverChecked - SimulationProfile.ErrorProbes).ToHashSet();
        var expired = remaining.Skip(neverChecked.Count).Take(SimulationProfile.CheckExpired).ToHashSet();
        var aging = remaining.Skip(neverChecked.Count + expired.Count).Take(SimulationProfile.CheckAging).ToHashSet();

        var times = root.Fork("presence/dates");
        var dayStart = LocalDays.StartOf(LocalDays.DateOf(reference, timeZone), timeZone);
        var windowStart = Latest(dayStart, reference - TimeSpan.FromHours(8));
        var windowEnd = reference - TimeSpan.FromMinutes(28);
        if (windowEnd < windowStart)
        {
            windowEnd = reference;
        }
        var latestOnline = true;
        var observations = ImmutableArray.CreateBuilder<WorkstationObservation>(active.Count);
        for (var i = 0; i < active.Count; i++)
        {
            var c = active[i];
            PresenceMeasure presence;
            if (errors.Contains(c))
            {
                presence = new PresenceMeasure(MeasureState.Error, null, null, null);
            }
            else if (online.Contains(i))
            {
                DateTimeOffset at;
                if (latestOnline)
                {
                    at = windowEnd;
                    latestOnline = false;
                }
                else
                {
                    at = windowStart + times.Between(TimeSpan.Zero, windowEnd - windowStart);
                }
                presence = new PresenceMeasure(MeasureState.Known, true, at, at);
            }
            else if (neverChecked.Contains(i))
            {
                presence = PresenceMeasure.Unread;
            }
            else
            {
                var checkAge = expired.Contains(i) ? times.Between(TimeSpan.FromDays(31), TimeSpan.FromDays(120))
                    : aging.Contains(i) ? times.Between(TimeSpan.FromDays(7) + TimeSpan.FromHours(12), TimeSpan.FromDays(29) + TimeSpan.FromHours(12))
                    : times.Between(TimeSpan.FromMinutes(29), TimeSpan.FromDays(6) + TimeSpan.FromHours(12));
                var checkedAt = Ago(checkAge);
                // Answered two days or more before the reading: never counted in today's activity, even on a 25-hour day.
                DateTimeOffset? lastOnline = neverAnswer.Contains(c) ? null : checkedAt - times.Between(TimeSpan.FromDays(2), TimeSpan.FromDays(40));
                presence = new PresenceMeasure(MeasureState.Known, false, checkedAt, lastOnline);
            }
            observations.Add(new WorkstationObservation(c.Guid, presence, inventories[c]));
        }
        var built = observations.ToImmutable();
        var takenAt = built.SelectMany(o => new[] { o.Presence.CheckedAt, o.Inventory.CheckedAt }).Where(d => d is not null).Max();
        var presenceModel = new PresenceModel(
            root.Seed,
            target,
            [.. active.Select(c => c.Guid)],
            [.. ranks],
            [.. errors.Select(c => c.Guid)],
            [.. neverAnswer.Select(c => c.Guid)]);
        return (new FleetObservations(takenAt, built), presenceModel);
    }

    // ---------------------------------------------------------------- History and journal

    private ImmutableArray<DailyFigures> BuildHistory(DirectorySnapshot snapshot)
    {
        var today = LocalDays.DateOf(reference, timeZone);
        var activeToday = snapshot.Users.Count(u => !AdValues.IsDisabled(u.UserAccountControl));
        var accounts = root.Fork("history/accounts");
        var activeByDay = new int[13];
        var value = activeToday;
        for (var back = 1; back <= 13; back++)
        {
            var day = today.AddDays(-back);
            value -= day.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday ? 0 : accounts.Next(0, 4);
            activeByDay[13 - back] = value;
        }
        var random = root.Fork("history");
        var result = ImmutableArray.CreateBuilder<DailyFigures>(13);
        for (var k = 0; k < 13; k++)
        {
            var day = today.AddDays(k - 13);
            var weekend = day.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday;
            var online = weekend ? random.Next(48, 71) : random.Next(265, 301);
            var seen = online + (weekend ? random.Next(5, 13) : random.Next(8, 26));
            result.Add(new DailyFigures(day, online, seen, activeByDay[k], random.Next(0, 13), random.Next(15, 27), random.Next(6, 12)));
        }
        return result.ToImmutable();
    }

    private ImmutableArray<JournalEntry> BuildJournal(DirectorySnapshot snapshot)
    {
        var c = FrenchText.Colon;
        (int Minutes, string Label, Tone Tone)[] entries =
        [
            (12, $"Lecture de l’annuaire{c}{FrenchText.Count(snapshot.ObjectCount, "objet", "objets")}", Tone.Ok),
            (28, $"Relevé de présence de l’OU Paris{c}158 en ligne sur 186", Tone.Ok),
            (55, $"Relevé d’inventaire de l’OU Lyon{c}74 postes sur 82", Tone.Ok),
            (99, $"Diagnostic de verrouillage{c}Camille Bernard", Tone.Warn),
            (201, "Lecture BitLocker refusée pour l’OU Marseille", Tone.Alert),
            (226, $"Recherche {FrenchText.Quote("dupont")}{c}12 résultats", Tone.Info),
            (302, $"Relevé de présence de l’OU Lyon{c}61 en ligne sur 82", Tone.Ok),
            (390, $"Export des comptes verrouillés{c}7 lignes", Tone.Info),
            (1500, $"Lecture de l’annuaire{c}{FrenchText.Count(1824, "objet", "objets")}", Tone.Ok),
            (1560, $"Relevé d’inventaire de l’OU Paris{c}171 postes sur 186", Tone.Ok),
            (1680, $"Relevé de présence de l’OU Marseille{c}sondes refusées pour 3 postes", Tone.Warn),
            (2880, $"Requête {FrenchText.Quote("Postes sans LAPS")}{c}23 résultats", Tone.Info),
            (3060, $"Lecture de l’annuaire{c}{FrenchText.Count(1821, "objet", "objets")}", Tone.Ok),
            (4320, $"Première lecture de l’OU Postes{c}431 comptes ordinateur", Tone.Ok),
        ];
        return [.. entries.Select(e => new JournalEntry(reference - TimeSpan.FromMinutes(e.Minutes), e.Label, e.Tone))];
    }

    // ---------------------------------------------------------------- Helpers

    private DateTimeOffset Ago(TimeSpan span) => reference - span;

    private static TimeSpan Min(TimeSpan a, TimeSpan b) => a < b ? a : b;

    private static DateTimeOffset Latest(DateTimeOffset a, DateTimeOffset? b) => b is DateTimeOffset other && other > a ? other : a;

    /// <summary>Keeps a creation date before two later dates, moving it back by up to 300 days when needed.</summary>
    private static DateTimeOffset Earliest(DateTimeOffset created, DateTimeOffset first, DateTimeOffset second, SeededRandom random)
    {
        var limit = first < second ? first : second;
        return created <= limit ? created : limit - random.Between(TimeSpan.FromDays(1), TimeSpan.FromDays(300));
    }

    private string UniqueCn(string parentDn, string cn)
    {
        if (!cnTaken.TryGetValue(parentDn, out var taken))
        {
            taken = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            cnTaken.Add(parentDn, taken);
        }
        var candidate = cn;
        for (var n = 2; !taken.Add(candidate); n++)
        {
            candidate = cn + " " + n.ToString(CultureInfo.InvariantCulture);
        }
        return candidate;
    }

    /// <summary>Initial of each part of the given name, a dot, the surname in plain ASCII; 20 characters at most, numbered when taken.</summary>
    private string AllocateSam(string given, string surname)
    {
        var initials = string.Concat(given.Split(NameSeparators, StringSplitOptions.RemoveEmptyEntries).Select(part => Ascii(part)).Where(a => a.Length > 0).Select(a => a[0]));
        return Unique(samTaken, initials + "." + Ascii(surname), 20);
    }

    private string AllocateMail(string given, string surname)
    {
        var local = Ascii(given, keepHyphens: true) + "." + Ascii(surname, keepHyphens: true);
        return Unique(mailTaken, local, 64) + "@" + SimulationProfile.DnsName;
    }

    private string NextPhone(string prefix, SeededRandom ids)
    {
        if (!phoneCounters.TryGetValue(prefix, out var counter))
        {
            counter = ids.Next(0, 4000);
        }
        phoneCounters[prefix] = counter + 1;
        var n = counter % 10_000;
        return $"{prefix} {(n / 100).ToString("D2", CultureInfo.InvariantCulture)} {(n % 100).ToString("D2", CultureInfo.InvariantCulture)}";
    }

    private string NextEmployeeId(SeededRandom ids)
    {
        int id;
        do
        {
            id = ids.Next(100_000, 1_000_000);
        }
        while (!employeeIds.Add(id));
        return id.ToString(CultureInfo.InvariantCulture);
    }

    private static string Unique(HashSet<string> taken, string baseName, int maxLength)
    {
        var first = baseName.Length > maxLength ? baseName[..maxLength] : baseName;
        if (taken.Add(first))
        {
            return first;
        }
        for (var n = 2; ; n++)
        {
            var suffix = n.ToString(CultureInfo.InvariantCulture);
            var head = baseName.Length + suffix.Length > maxLength ? baseName[..(maxLength - suffix.Length)] : baseName;
            if (taken.Add(head + suffix))
            {
                return head + suffix;
            }
        }
    }

    /// <summary>Lower-case ASCII letters and digits only (accents removed); hyphens kept on request.</summary>
    internal static string Ascii(string text, bool keepHyphens = false)
    {
        var builder = new StringBuilder(text.Length);
        foreach (var c in text.Normalize(NormalizationForm.FormD))
        {
            if (char.IsAsciiLetterOrDigit(c))
            {
                builder.Append(char.ToLowerInvariant(c));
            }
            else if (keepHyphens && c == '-')
            {
                builder.Append('-');
            }
        }
        return builder.ToString();
    }

    private static Guid NewGuid(SeededRandom random)
    {
        Span<byte> bytes = stackalloc byte[16];
        BinaryPrimitives.WriteUInt64LittleEndian(bytes, random.NextUInt64());
        BinaryPrimitives.WriteUInt64LittleEndian(bytes[8..], random.NextUInt64());
        bytes[7] = (byte)((bytes[7] & 0x0F) | 0x40);
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);
        return new Guid(bytes);
    }

    // ---------------------------------------------------------------- Drafts

    private enum UserKind
    {
        Builtin,
        Person,
        Admin,
        Service,
    }

    private enum PasswordKind
    {
        Normal,
        NeverExpires,
        MustChange,
        Expired,
        Expiring,
    }

    private enum LogonKind
    {
        Recent,
        Stale,
        None,
    }

    private enum ComputerKind
    {
        Workstation,
        Quarantined,
        JustJoined,
        Server,
        DomainController,
    }

    private enum WorkstationState
    {
        Normal,
        Stale,
        NeverLoggedOn,
        PasswordOld,
        RecentlyCreated,
    }

    private sealed class OuDraft
    {
        public Guid Guid { get; init; }
        public string Dn { get; init; } = "";
        public string Name { get; init; } = "";
        public string? Description { get; init; }
        public DateTimeOffset Created { get; init; }
        public DateTimeOffset Changed { get; init; }
        public long Usn { get; init; }
    }

    private sealed class UserDraft
    {
        public UserKind Kind { get; init; }
        public Guid Guid { get; set; }
        public int Rid { get; set; }
        public string? ParentDn { get; set; }
        public string Dn { get; set; } = "";
        public string Cn { get; set; } = "";
        public string Sam { get; init; } = "";
        public string? Upn { get; init; }
        public string? DisplayName { get; init; }
        public string? Given { get; init; }
        public string? Surname { get; init; }
        public bool Female { get; init; }
        public string? Mail { get; init; }
        public string? Title { get; set; }
        public string? Department { get; init; }
        public string? Office { get; init; }
        public string? Site { get; init; }
        public string? Telephone { get; set; }
        public string? ManagerDn { get; set; }
        public string? Description { get; set; }
        public string? EmployeeId { get; init; }
        public int Uac { get; set; } = NormalUser;
        public int? AdminCount { get; init; }
        public int PrimaryGroup { get; init; } = 513;
        public int ServiceIndex { get; set; }
        public bool IsManager { get; set; }
        public bool Departed { get; set; }
        public bool LongLeave { get; set; }
        public PasswordKind Password { get; set; }
        public LogonKind Logon { get; set; }
        public bool RecentlyCreated { get; set; }
        public bool Locked { get; set; }
        public bool LockoutExpired { get; set; }
        public bool Intern { get; set; }
        public int? BadPasswordCount { get; set; } = 0;
        public DateTimeOffset Created { get; set; }
        public DateTimeOffset Changed { get; set; }
        public DateTimeOffset? PasswordSet { get; set; }
        public DateTimeOffset? LastLogon { get; set; }
        public DateTimeOffset? LockoutAt { get; set; }
        public DateTimeOffset? AccountExpiresAt { get; set; }
        public long Usn { get; set; }
        public List<string> MemberOf { get; } = [];

        public bool Active => !AdValues.IsDisabled(Uac);
    }

    private sealed class ComputerDraft
    {
        public ComputerKind Kind { get; init; }
        public Guid Guid { get; init; }
        public int Rid { get; set; }
        public string Name { get; init; } = "";
        public string? DnsHostName { get; init; }
        public string ParentDn { get; init; } = "";
        public string? OperatingSystem { get; init; }
        public string? OperatingSystemVersion { get; init; }
        public int Uac { get; init; }
        public int PrimaryGroup { get; init; }
        public bool Laptop { get; init; }
        public string? Site { get; init; }
        public string? Location { get; set; }
        public string? Description { get; set; }
        public string? ManagedByDn { get; set; }
        public WorkstationState State { get; set; }
        public bool ErrorProbe { get; set; }
        public LapsKind Laps { get; set; }
        public DateTimeOffset? LapsExpiration { get; set; }
        public DateTimeOffset Created { get; set; }
        public DateTimeOffset Changed { get; set; }
        public DateTimeOffset? PasswordSet { get; set; }
        public DateTimeOffset? LastLogon { get; set; }
        public long Usn { get; set; }
    }

    private sealed class GroupDraft
    {
        public Guid Guid { get; init; }
        public string Sid { get; init; } = "";
        public string Dn { get; init; } = "";
        public string Name { get; init; } = "";
        public int GroupType { get; init; }
        public string? Description { get; init; }
        public string? Mail { get; init; }
        public int? AdminCount { get; init; }
        public DateTimeOffset Created { get; init; }
        public DateTimeOffset Changed { get; init; }
        public long Usn { get; init; }
        public List<string> Members { get; } = [];
        public List<string> MemberOf { get; } = [];
    }
}
