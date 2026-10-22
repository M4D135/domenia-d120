using System.Collections.Immutable;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>A fictitious contact (no contact exists in the generated directory: they are derived for the « Fiche » screen).</summary>
internal sealed record SimulatedContact(Guid Id, string Dn, string Cn, ImmutableDictionary<string, ImmutableArray<string>> Attributes, DateTimeOffset Created, long Usn);

/// <summary>One object of the fictitious directory as the « Fiche » screen sees it, whatever its kind.</summary>
internal sealed record SimulatedObject(FicheKind Kind, Guid Id, string Dn, object Value);

/// <summary>
/// Data of the « Fiche » screen in simulation (docs/PLATFORM.md § 4): derived from the generated world and from the sub-stream
/// « screen/fiche » only, so that adding draws here never moves the directory nor another screen. The directory itself is read
/// through <see cref="SimulatedDirectorySource.CurrentDirectory"/> (writes of the session included); what the generated
/// directory does not hold (contact attributes, addresses, profile paths, logon hours, contacts themselves, associations between
/// users and workstations) is derived deterministically, and the writes of the session on those attributes are kept here, in
/// memory only (never persisted, like the overlay). One instance per source (session).
/// </summary>
internal sealed class SimulatedFicheWorld
{
    private static readonly ConditionalWeakTable<SimulatedDirectorySource, SimulatedFicheWorld> Worlds = new();

    private readonly SimulatedDirectorySource source;
    private readonly Lock gate = new();
    private readonly Lazy<ImmutableArray<SimulatedContact>> generatedContacts;
    private readonly Lazy<ImmutableArray<(Guid Computer, Guid User, string Evidence, DateTimeOffset When)>> links;
    private ImmutableDictionary<Guid, ImmutableDictionary<string, ImmutableArray<string>>> overrides = ImmutableDictionary<Guid, ImmutableDictionary<string, ImmutableArray<string>>>.Empty;
    private ImmutableDictionary<Guid, string> contactDns = ImmutableDictionary<Guid, string>.Empty;
    private ImmutableHashSet<Guid> removedContacts = ImmutableHashSet<Guid>.Empty;
    // Objects whose local associations were removed after their deletion (Domenia 1 Remove-LinksForDeletedObject).
    private ImmutableHashSet<Guid> unlinked = ImmutableHashSet<Guid>.Empty;
    private long version;
    private (long Overlay, long Local, Dictionary<string, SimulatedObject> ByDn, Dictionary<Guid, SimulatedObject> ById)? index;

    private SimulatedFicheWorld(SimulatedDirectorySource source)
    {
        this.source = source;
        generatedContacts = new(GenerateContacts, LazyThreadSafetyMode.ExecutionAndPublication);
        links = new(GenerateLinks, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    /// <summary>The screen data of one simulated source (one per session).</summary>
    public static SimulatedFicheWorld For(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        return Worlds.GetValue(source, static s => new SimulatedFicheWorld(s));
    }

    public SimulatedDirectorySource Source => source;

    public DirectorySnapshot Directory => source.CurrentDirectory;

    public TimeZoneInfo Zone => source.World.TimeZone;

    public DateTimeOffset Now => source.Clock.GetUtcNow();

    public string? Controller => source.World.Session.Controller?.DnsName;

    private SeededRandom Stream(string name) => source.ScreenStream("fiche").Fork(name);

    // ---------------------------------------------------------------- lookup

    private (Dictionary<string, SimulatedObject> ByDn, Dictionary<Guid, SimulatedObject> ById) Index()
    {
        var overlayVersion = source.Overlay.Version;
        lock (gate)
        {
            if (index is { } known && known.Overlay == overlayVersion && known.Local == version)
            {
                return (known.ByDn, known.ById);
            }
            var byDn = new Dictionary<string, SimulatedObject>(StringComparer.OrdinalIgnoreCase);
            var byId = new Dictionary<Guid, SimulatedObject>();
            var directory = source.CurrentDirectory;
            void Add(SimulatedObject item)
            {
                byDn.TryAdd(item.Dn, item);
                byId.TryAdd(item.Id, item);
            }
            Add(new SimulatedObject(FicheKind.Container, IdOf("container/" + directory.Domain.RootDn), directory.Domain.RootDn, directory.Domain));
            foreach (var container in directory.Domain.Containers)
            {
                Add(new SimulatedObject(FicheKind.Container, IdOf("container/" + container), container, container));
            }
            foreach (var ou in directory.OrganizationalUnits)
            {
                Add(new SimulatedObject(FicheKind.Ou, ou.ObjectGuid, ou.DistinguishedName, ou));
            }
            foreach (var user in directory.Users)
            {
                Add(new SimulatedObject(FicheKind.User, user.ObjectGuid, user.DistinguishedName, user));
            }
            foreach (var computer in directory.Computers)
            {
                Add(new SimulatedObject(FicheKind.Computer, computer.ObjectGuid, computer.DistinguishedName, computer));
            }
            foreach (var group in directory.Groups)
            {
                Add(new SimulatedObject(FicheKind.Group, group.ObjectGuid, group.DistinguishedName, group));
            }
            foreach (var contact in ContactsLocked())
            {
                Add(new SimulatedObject(FicheKind.Contact, contact.Id, contact.Dn, contact));
            }
            index = (overlayVersion, version, byDn, byId);
            return (byDn, byId);
        }
    }

    private static Guid IdOf(string name)
    {
        var bytes = System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("domenia/fiche/" + name));
        return new Guid(bytes.AsSpan(0, 16));
    }

    /// <summary>The object at this DN (exact text, then RFC 4514 comparison), or null.</summary>
    public SimulatedObject? Find(string dn)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (byDn, _) = Index();
        if (byDn.TryGetValue(dn, out var found))
        {
            return found;
        }
        string normalized;
        try
        {
            normalized = DistinguishedName.Format(DistinguishedName.Parse(dn));
        }
        catch (FormatException)
        {
            return null;
        }
        return byDn.TryGetValue(normalized, out found) ? found : byDn.Values.FirstOrDefault(o => FicheValues.SameDn(o.Dn, dn));
    }

    public SimulatedObject? Find(Guid id) => Index().ById.GetValueOrDefault(id);

    public bool Exists(string dn) => Find(dn) is not null;

    public IEnumerable<SimulatedObject> All() => Index().ById.Values;

    /// <summary>Direct children of a branch (one level).</summary>
    public IEnumerable<SimulatedObject> ChildrenOf(string dn) =>
        All().Where(o => DistinguishedName.Parent(o.Dn) is string parent && FicheValues.SameDn(parent, dn));

    // ---------------------------------------------------------------- contacts

    private ImmutableArray<SimulatedContact> ContactsLocked()
    {
        var removed = removedContacts;
        var moved = contactDns;
        var local = overrides;
        return [.. generatedContacts.Value.Where(c => !removed.Contains(c.Id)).Select(c =>
        {
            var dn = moved.GetValueOrDefault(c.Id, c.Dn);
            var attributes = local.TryGetValue(c.Id, out var changed) ? Merge(c.Attributes, changed) : c.Attributes;
            return c with { Dn = dn, Attributes = attributes };
        })];
    }

    private static ImmutableDictionary<string, ImmutableArray<string>> Merge(ImmutableDictionary<string, ImmutableArray<string>> baseValues, ImmutableDictionary<string, ImmutableArray<string>> changes)
    {
        var builder = baseValues.ToBuilder();
        foreach (var (key, values) in changes)
        {
            if (values.IsDefaultOrEmpty)
            {
                builder.Remove(key);
            }
            else
            {
                builder[key] = values;
            }
        }
        return builder.ToImmutable();
    }

    private static readonly (string Company, string Title, string Department)[] ContactProfiles =
    [
        ("Fournitures Exemple", "Chargée de compte", "Ventes"), ("Transports Démo", "Responsable logistique", "Exploitation"),
        ("Cabinet Fictif & Associés", "Avocat associé", "Conseil"), ("Imprimerie de l’Exemple", "Technicien", "Maintenance"),
        ("Société Imaginaire", "Directrice commerciale", "Direction"), ("Nettoyage Exemple", "Chef d’équipe", "Services"),
        ("Assurances Démo", "Conseiller", "Entreprises"), ("Formation Fictive", "Formatrice", "Pédagogie"),
        ("Exemple Énergie", "Ingénieur d’affaires", "Grands comptes"), ("Banque Imaginaire", "Chargé d’affaires", "Entreprises"),
        ("Audit Exemple", "Auditrice", "Audit"), ("Sécurité Démo", "Responsable de site", "Exploitation"),
    ];

    private ImmutableArray<SimulatedContact> GenerateContacts()
    {
        var directory = source.World.Directory;
        var random = Stream("contacts");
        var reference = source.World.Reference;
        var parent = directory.OrganizationalUnits.FirstOrDefault(o => o.Name == "Distribution")?.DistinguishedName ?? "CN=Users," + directory.Domain.RootDn;
        var contacts = ImmutableArray.CreateBuilder<SimulatedContact>();
        var usedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var count = 18;
        var usn = 900_000L;
        for (var i = 0; i < count; i++)
        {
            var female = random.Chance(50);
            var given = random.Pick(female ? FrenchNames.Female : FrenchNames.Male);
            var surname = random.Pick(FrenchNames.Surnames);
            var cn = given + " " + surname;
            if (!usedNames.Add(cn))
            {
                cn += " (" + (i + 1).ToString(CultureInfo.InvariantCulture) + ")";
                usedNames.Add(cn);
            }
            var profile = ContactProfiles[i % ContactProfiles.Length];
            var domain = Slug(profile.Company) + ".example";
            var mail = Slug(given) + "." + Slug(surname) + "@" + domain;
            var id = NewGuid(random);
            var created = reference - TimeSpan.FromDays(random.Next(40, 1800)) - TimeSpan.FromMinutes(random.Next(0, 1440));
            var changed = created + TimeSpan.FromDays(random.Next(0, Math.Max(1, (int)(reference - created).TotalDays)));
            var phone = "+33 1 99 00 " + random.Next(10, 99).ToString(CultureInfo.InvariantCulture) + " " + random.Next(10, 99).ToString(CultureInfo.InvariantCulture);
            var mobile = "+33 6 39 98 " + random.Next(10, 99).ToString(CultureInfo.InvariantCulture) + " " + random.Next(10, 99).ToString(CultureInfo.InvariantCulture);
            usn += random.Next(10, 500);
            var dn = DistinguishedName.Child("CN", cn, parent);
            var attributes = new Dictionary<string, ImmutableArray<string>>(StringComparer.OrdinalIgnoreCase)
            {
                ["objectClass"] = ["top", "person", "organizationalPerson", "contact"],
                ["objectCategory"] = ["CN=Person,CN=Schema,CN=Configuration," + directory.Domain.RootDn],
                ["cn"] = [cn],
                ["name"] = [cn],
                ["givenName"] = [given],
                ["sn"] = [surname],
                ["displayName"] = [cn],
                ["mail"] = [mail],
                ["company"] = [profile.Company],
                ["title"] = [profile.Title],
                ["department"] = [profile.Department],
                ["telephoneNumber"] = [phone],
                ["mobile"] = [mobile],
                ["description"] = ["Contact externe · " + profile.Company],
                ["instanceType"] = ["4"],
                ["whenCreated"] = [FicheValues.GeneralizedTime(created)],
                ["whenChanged"] = [FicheValues.GeneralizedTime(changed)],
                ["uSNCreated"] = [(usn - 3).ToString(CultureInfo.InvariantCulture)],
                ["uSNChanged"] = [usn.ToString(CultureInfo.InvariantCulture)],
            };
            contacts.Add(new SimulatedContact(id, dn, cn, attributes.ToImmutableDictionary(StringComparer.OrdinalIgnoreCase), created, usn));
        }
        return contacts.ToImmutable();
    }

    private static Guid NewGuid(SeededRandom random)
    {
        Span<byte> bytes = stackalloc byte[16];
        BitConverter.TryWriteBytes(bytes, random.NextUInt64());
        BitConverter.TryWriteBytes(bytes[8..], random.NextUInt64());
        return new Guid(bytes);
    }

    private static string Slug(string text)
    {
        var folded = FrenchText.Fold(text);
        var builder = new StringBuilder();
        foreach (var c in folded)
        {
            if (char.IsAsciiLetterOrDigit(c))
            {
                builder.Append(c);
            }
            else if (builder.Length > 0 && builder[^1] != '-')
            {
                builder.Append('-');
            }
        }
        return builder.ToString().Trim('-');
    }

    // ---------------------------------------------------------------- associations between users and workstations

    /// <summary>
    /// One association per active workstation: its declared owner (managedBy) when it has one, otherwise an active person of the
    /// same site drawn without repetition; Camille Bernard and the session account always have one (support scenarios).
    /// </summary>
    private ImmutableArray<(Guid Computer, Guid User, string Evidence, DateTimeOffset When)> GenerateLinks()
    {
        var world = source.World;
        var directory = world.Directory;
        var random = Stream("links");
        var reference = world.Reference;
        var observations = world.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var usersByDn = directory.Users.ToDictionary(u => u.DistinguishedName, StringComparer.OrdinalIgnoreCase);
        var result = ImmutableArray.CreateBuilder<(Guid Computer, Guid User, string Evidence, DateTimeOffset When)>();
        var taken = new HashSet<Guid>();
        foreach (var site in SimulationProfile.Sites)
        {
            var computers = directory.Computers
                .Where(c => !AdValues.IsDisabled(c.UserAccountControl) && c.DistinguishedName.Contains("OU=" + site.Name + ",OU=Postes,", StringComparison.OrdinalIgnoreCase))
                .OrderBy(c => c.Name, StringComparer.Ordinal).ToList();
            var people = directory.Users
                .Where(u => !AdValues.IsDisabled(u.UserAccountControl) && string.Equals(u.Office, site.Name, StringComparison.Ordinal)
                    && u.DistinguishedName.Contains(",OU=Utilisateurs,", StringComparison.OrdinalIgnoreCase))
                .OrderBy(u => u.SamAccountName, StringComparer.Ordinal).ToList();
            random.Shuffle(people);
            var priority = people.Where(u => u.SamAccountName is "c.bernard" or SimulationProfile.PersonLogin).ToList();
            foreach (var p in priority)
            {
                people.Remove(p);
                people.Insert(0, p);
            }
            var cursor = 0;
            foreach (var computer in computers)
            {
                observations.TryGetValue(computer.ObjectGuid, out var observation);
                var when = observation?.Presence.LastOnlineAt ?? observation?.Presence.CheckedAt ?? reference - TimeSpan.FromHours(random.Next(2, 200));
                if (computer.ManagedByDn is string owner && usersByDn.TryGetValue(owner, out var declared))
                {
                    result.Add((computer.ObjectGuid, declared.ObjectGuid, "declared", computer.WhenChanged));
                    taken.Add(declared.ObjectGuid);
                    continue;
                }
                while (cursor < people.Count && taken.Contains(people[cursor].ObjectGuid))
                {
                    cursor++;
                }
                if (cursor >= people.Count)
                {
                    continue;
                }
                var person = people[cursor++];
                taken.Add(person.ObjectGuid);
                result.Add((computer.ObjectGuid, person.ObjectGuid, random.Chance(85) ? "observed" : "history", when));
            }
        }
        return result.ToImmutable();
    }

    private IEnumerable<(Guid Computer, Guid User, string Evidence, DateTimeOffset When)> Links()
    {
        var removed = unlinked;
        return links.Value.Where(l => !removed.Contains(l.Computer) && !removed.Contains(l.User));
    }

    /// <summary>Number of local associations that name this object (user or computer).</summary>
    public int LinkCount(Guid id) => Links().Count(l => l.Computer == id || l.User == id);

    /// <summary>Removes from the local memory every association that names this object; returns how many were removed.</summary>
    public int ForgetLinks(Guid id)
    {
        lock (gate)
        {
            var count = Links().Count(l => l.Computer == id || l.User == id);
            unlinked = unlinked.Add(id);
            version++;
            return count;
        }
    }

    /// <summary>Associations of a user (its workstations) or of a computer (its users), primary first.</summary>
    public ImmutableArray<FicheAssociation> Associations(SimulatedObject item)
    {
        ArgumentNullException.ThrowIfNull(item);
        var list = new List<FicheAssociation>();
        if (item.Kind == FicheKind.User)
        {
            foreach (var link in Links().Where(l => l.User == item.Id))
            {
                if (Find(link.Computer) is { Value: DirectoryComputer computer } found)
                {
                    var (label, rule) = FicheRelationRules.Evidence(link.Evidence);
                    list.Add(new FicheAssociation(computer.Name, found.Dn, computer.ObjectGuid, "computer", link.Evidence, label, rule, link.When,
                        link.Evidence == "declared" ? "managedBy" : link.Evidence == "observed" ? "Session console" : "Profil du poste", false));
                }
            }
        }
        else if (item.Kind == FicheKind.Computer)
        {
            foreach (var link in Links().Where(l => l.Computer == item.Id))
            {
                if (Find(link.User) is { Value: DirectoryUser user } found)
                {
                    var (label, rule) = FicheRelationRules.Evidence(link.Evidence);
                    list.Add(new FicheAssociation(user.DisplayName ?? user.Cn, found.Dn, user.ObjectGuid, "user", link.Evidence, label, rule, link.When,
                        link.Evidence == "declared" ? "managedBy" : link.Evidence == "observed" ? "Session console" : "Profil du poste", false));
                }
            }
        }
        return FicheRelationRules.Order(list);
    }

    /// <summary>Last committed measures of a workstation, with the console account of its observed user when it answered.</summary>
    public FicheObservation? Observation(SimulatedObject computer)
    {
        ArgumentNullException.ThrowIfNull(computer);
        if (computer.Value is not DirectoryComputer value)
        {
            return null;
        }
        var observation = source.CurrentObservations.Workstations.FirstOrDefault(o => o.ComputerGuid == value.ObjectGuid);
        if (observation is null)
        {
            return new FicheObservation(computer.Dn, value.Name, MeasureState.Absent, null, null, null, null, null, MeasureState.Absent, null);
        }
        string? console = null;
        DateTimeOffset? consoleAt = null;
        if (observation.Presence.HasReading && observation.Presence.Answered == true)
        {
            var link = Links().FirstOrDefault(l => l.Computer == value.ObjectGuid && l.Evidence != "history");
            if (link.User != Guid.Empty && Find(link.User) is { Value: DirectoryUser user })
            {
                console = source.World.Directory.Domain.NetbiosName + "\\" + user.SamAccountName;
            }
            consoleAt = observation.Presence.CheckedAt;
        }
        return new FicheObservation(computer.Dn, value.Name, observation.Presence.State, observation.Presence.Answered, observation.Presence.CheckedAt,
            observation.Presence.LastOnlineAt, console, consoleAt, observation.Inventory.State, observation.Inventory.CheckedAt);
    }

    /// <summary>Raw observation of a workstation (inventory figures for the triage).</summary>
    public WorkstationObservation? RawObservation(Guid computer) => source.CurrentObservations.Workstations.FirstOrDefault(o => o.ComputerGuid == computer);

    // ---------------------------------------------------------------- entries

    /// <summary>The object as a fiche entry: attributes of the directory, derived attributes, then the writes of the session.</summary>
    public FicheEntry Entry(SimulatedObject item)
    {
        ArgumentNullException.ThrowIfNull(item);
        var attributes = new Dictionary<string, IEnumerable<string?>>(StringComparer.OrdinalIgnoreCase);
        void Set(string name, params string?[] values) => attributes[name] = values;
        var domain = source.World.Directory.Domain;
        var schema = "CN=Schema,CN=Configuration," + domain.RootDn;
        string name;
        switch (item.Value)
        {
            case DirectoryUser u:
                name = u.Cn;
                Set("objectClass", "top", "person", "organizationalPerson", "user");
                Set("objectCategory", "CN=Person," + schema);
                Set("cn", u.Cn);
                Set("name", u.Cn);
                Set("sAMAccountName", u.SamAccountName);
                Set("userPrincipalName", u.UserPrincipalName);
                Set("displayName", u.DisplayName);
                Set("givenName", u.GivenName);
                Set("sn", u.Surname);
                Set("mail", u.Mail);
                Set("title", u.Title);
                Set("department", u.Department);
                Set("physicalDeliveryOfficeName", u.Office);
                Set("telephoneNumber", u.TelephoneNumber);
                Set("manager", u.ManagerDn);
                Set("description", u.Description);
                Set("employeeID", u.EmployeeId);
                Set("userAccountControl", Num(u.UserAccountControl));
                Set("msDS-User-Account-Control-Computed", Num(u.ComputedAccountControl));
                Set("lockoutTime", Num(u.LockoutTime));
                Set("badPwdCount", Num(u.BadPasswordCount));
                Set("pwdLastSet", Num(u.PasswordLastSet));
                Set("msDS-UserPasswordExpiryTimeComputed", Num(u.PasswordExpiryComputed));
                Set("lastLogonTimestamp", Num(u.LastLogonTimestamp));
                Set("accountExpires", Num(u.AccountExpires));
                Set("adminCount", Num(u.AdminCount));
                Set("primaryGroupID", Num(u.PrimaryGroupId));
                Set("memberOf", [.. u.MemberOf]);
                Set("objectSid", u.Sid);
                Set("sAMAccountType", "805306368");
                Common(Set, u.ObjectGuid, u.DistinguishedName, u.WhenCreated, u.WhenChanged, u.UsnChanged);
                UserExtras(Set, u);
                break;
            case DirectoryComputer c:
                name = c.Name;
                Set("objectClass", "top", "person", "organizationalPerson", "user", "computer");
                Set("objectCategory", "CN=Computer," + schema);
                Set("cn", c.Name);
                Set("name", c.Name);
                Set("sAMAccountName", c.SamAccountName);
                Set("dNSHostName", c.DnsHostName);
                Set("description", c.Description);
                Set("location", c.Location);
                Set("managedBy", c.ManagedByDn);
                Set("operatingSystem", c.OperatingSystem);
                Set("operatingSystemVersion", c.OperatingSystemVersion);
                Set("userAccountControl", Num(c.UserAccountControl));
                Set("lastLogonTimestamp", Num(c.LastLogonTimestamp));
                Set("pwdLastSet", Num(c.PasswordLastSet));
                Set("primaryGroupID", Num(c.PrimaryGroupId));
                Set("memberOf", [.. c.MemberOf]);
                Set("objectSid", c.Sid);
                Set("sAMAccountType", "805306369");
                Set(c.Laps == LapsKind.Legacy ? "ms-Mcs-AdmPwdExpirationTime" : "msLAPS-PasswordExpirationTime", Num(c.LapsExpiration));
                Set("servicePrincipalName", "HOST/" + c.Name, c.DnsHostName is null ? null : "HOST/" + c.DnsHostName, "RestrictedKrbHost/" + c.Name,
                    c.DnsHostName is null ? null : "RestrictedKrbHost/" + c.DnsHostName);
                Set("msDS-SupportedEncryptionTypes", "28");
                if (AdValues.HasFlag(c.UserAccountControl, AdValues.ServerTrustAccount))
                {
                    Set("isCriticalSystemObject", "TRUE");
                }
                Common(Set, c.ObjectGuid, c.DistinguishedName, c.WhenCreated, c.WhenChanged, c.UsnChanged);
                break;
            case DirectoryGroup g:
                name = g.Name;
                Set("objectClass", "top", "group");
                Set("objectCategory", "CN=Group," + schema);
                Set("cn", g.Name);
                Set("name", g.Name);
                Set("sAMAccountName", g.SamAccountName);
                Set("groupType", Num(g.GroupType));
                Set("sAMAccountType", Num(SamAccountType(g.GroupType)));
                Set("description", g.Description);
                Set("mail", g.Mail);
                Set("managedBy", g.ManagedByDn);
                Set("adminCount", Num(g.AdminCount));
                Set("member", [.. g.Members]);
                Set("memberOf", [.. g.MemberOf]);
                Set("objectSid", g.Sid);
                if (g.DistinguishedName.Contains("CN=Builtin,", StringComparison.OrdinalIgnoreCase) || g.DistinguishedName.Contains("CN=Users,", StringComparison.OrdinalIgnoreCase))
                {
                    Set("isCriticalSystemObject", "TRUE");
                }
                Common(Set, g.ObjectGuid, g.DistinguishedName, g.WhenCreated, g.WhenChanged, g.UsnChanged);
                break;
            case DirectoryOu o:
                name = o.Name;
                Set("objectClass", "top", "organizationalUnit");
                Set("objectCategory", "CN=Organizational-Unit," + schema);
                Set("ou", o.Name);
                Set("name", o.Name);
                Set("description", o.Description);
                Set("managedBy", o.ManagedByDn);
                if (o.Name is "Postes" or "Utilisateurs" or "Serveurs" or "Domain Controllers" or "Comptes à privilèges")
                {
                    Set("gPLink", "[LDAP://cn={" + IdOf("gpo/" + o.Name).ToString("D").ToUpperInvariant() + "},cn=policies,cn=system," + domain.RootDn + ";0]");
                }
                if (o.Name == "Domain Controllers")
                {
                    Set("isCriticalSystemObject", "TRUE");
                }
                Common(Set, o.ObjectGuid, o.DistinguishedName, o.WhenCreated, o.WhenChanged, o.UsnChanged);
                break;
            case SimulatedContact contact:
                name = contact.Cn;
                foreach (var (key, values) in contact.Attributes)
                {
                    attributes[key] = values;
                }
                attributes["distinguishedName"] = [contact.Dn];
                attributes["objectGUID"] = [contact.Id.ToString("D")];
                var groupsOfContact = source.CurrentDirectory.Groups.Where(g => g.Members.Any(m => FicheValues.SameDn(m, contact.Dn))).Select(g => g.DistinguishedName).ToArray();
                attributes["memberOf"] = groupsOfContact;
                break;
            case DomainInfo d:
                name = d.DnsName;
                Set("objectClass", "top", "domain", "domainDNS");
                Set("name", d.NetbiosName);
                Set("dc", d.DnsName.Split('.')[0]);
                Set("objectSid", d.DomainSid);
                Set("maxPwdAge", Num(-d.PasswordPolicy.MaxPasswordAge.Ticks));
                Set("minPwdLength", Num(d.PasswordPolicy.MinPasswordLength));
                Set("pwdHistoryLength", Num(d.PasswordPolicy.PasswordHistoryLength));
                Set("lockoutThreshold", Num(d.PasswordPolicy.LockoutThreshold));
                Set("lockoutDuration", Num(-d.PasswordPolicy.LockoutDuration.Ticks));
                Set("description", "Domaine " + d.DnsName + " (annuaire fictif de la simulation).");
                Set("isCriticalSystemObject", "TRUE");
                Set("distinguishedName", d.RootDn);
                Set("objectGUID", item.Id.ToString("D"));
                break;
            case string container:
                name = FicheValues.DisplayName(container);
                Set("objectClass", "top", container.StartsWith("CN=Builtin", StringComparison.OrdinalIgnoreCase) ? "builtinDomain" : "container");
                Set("cn", name);
                Set("name", name);
                Set("description", name switch
                {
                    "Users" => "Conteneur par défaut des comptes d’utilisateurs mis à niveau.",
                    "Computers" => "Conteneur par défaut des ordinateurs mis à niveau.",
                    "Builtin" => "Groupes locaux intégrés du domaine.",
                    _ => "Conteneur par défaut.",
                });
                Set("isCriticalSystemObject", "TRUE");
                Set("distinguishedName", container);
                Set("objectGUID", item.Id.ToString("D"));
                break;
            default:
                throw new InvalidOperationException("Unknown simulated object.");
        }
        ImmutableDictionary<string, ImmutableArray<string>>? local;
        lock (gate)
        {
            local = overrides.GetValueOrDefault(item.Id);
        }
        if (local is not null && item.Kind != FicheKind.Contact)
        {
            foreach (var (key, values) in local)
            {
                attributes[key] = values.IsDefault ? [] : values;
            }
        }
        return FicheEntry.Create(item.Kind, item.Id, item.Dn, name, attributes);
    }

    private static int SamAccountType(int groupType) =>
        (groupType & 0x4) != 0 || (groupType & 0x1) != 0
            ? (groupType & unchecked((int)0x80000000)) != 0 ? 536870912 : 536870913
            : (groupType & unchecked((int)0x80000000)) != 0 ? 268435456 : 268435457;

    private static string? Num(long? value) => value?.ToString(CultureInfo.InvariantCulture);

    private static void Common(Action<string, string?[]> set, Guid id, string dn, DateTimeOffset created, DateTimeOffset changed, long usn)
    {
        set("objectGUID", [id.ToString("D")]);
        set("distinguishedName", [dn]);
        set("whenCreated", [FicheValues.GeneralizedTime(created)]);
        set("whenChanged", [FicheValues.GeneralizedTime(changed)]);
        set("uSNChanged", [usn.ToString(CultureInfo.InvariantCulture)]);
        set("uSNCreated", [Math.Max(1, usn - 7 - (Math.Abs(id.GetHashCode()) % 400)).ToString(CultureInfo.InvariantCulture)]);
        set("instanceType", ["4"]);
    }

    private static readonly Dictionary<string, (string Street, string Postal, string City, string Region)> Addresses = new(StringComparer.Ordinal)
    {
        ["Paris"] = ("1 place de l’Exemple", "75001", "Paris", "Île-de-France"),
        ["Lyon"] = ("8 quai de l’Exemple", "69002", "Lyon", "Auvergne-Rhône-Alpes"),
        ["Marseille"] = ("25 boulevard de l’Exemple", "13002", "Marseille", "Provence-Alpes-Côte d’Azur"),
        ["Lille"] = ("4 rue de l’Exemple", "59000", "Lille", "Hauts-de-France"),
        ["Bordeaux"] = ("17 cours de l’Exemple", "33000", "Bordeaux", "Nouvelle-Aquitaine"),
    };

    /// <summary>Attributes of a user that the generated directory does not hold, derived from its GUID (deterministic).</summary>
    private void UserExtras(Action<string, string?[]> set, DirectoryUser user)
    {
        var random = Stream("user/" + user.ObjectGuid.ToString("N"));
        var person = user.DistinguishedName.Contains(",OU=Utilisateurs,", StringComparison.OrdinalIgnoreCase);
        var reference = source.World.Reference;
        set("company", ["Example"]);
        set("logonCount", [(user.LastLogonTimestamp is null ? 0 : random.Next(40, 3200)).ToString(CultureInfo.InvariantCulture)]);
        if (user.BadPasswordCount is int bad && bad > 0)
        {
            var at = AdValues.FromFileTime(user.LockoutTime) ?? reference - TimeSpan.FromMinutes(random.Next(5, 600));
            set("badPasswordTime", [AdValues.ToFileTime(at - TimeSpan.FromSeconds(random.Next(2, 40))).ToString(CultureInfo.InvariantCulture)]);
        }
        if (user.SamAccountName.StartsWith("svc-", StringComparison.Ordinal))
        {
            var service = user.SamAccountName[4..];
            set("servicePrincipalName", [service == "sql" ? "MSSQLSvc/srv-sql-01.example.local:1433" : "HTTP/" + service + ".example.local"]);
            set("msDS-SupportedEncryptionTypes", ["24"]);
        }
        if (user.Sid.EndsWith("-500", StringComparison.Ordinal) || user.Sid.EndsWith("-501", StringComparison.Ordinal) || user.Sid.EndsWith("-502", StringComparison.Ordinal))
        {
            set("isCriticalSystemObject", ["TRUE"]);
        }
        if (!person || user.Office is null || !Addresses.TryGetValue(user.Office, out var address))
        {
            return;
        }
        set("streetAddress", [address.Street]);
        set("postalCode", [address.Postal]);
        set("l", [address.City]);
        set("st", [address.Region]);
        set("co", ["France"]);
        set("c", ["FR"]);
        set("countryCode", ["250"]);
        if (random.Chance(65))
        {
            set("mobile", ["+33 6 39 98 " + random.Next(10, 99).ToString(CultureInfo.InvariantCulture) + " " + random.Next(10, 99).ToString(CultureInfo.InvariantCulture)]);
        }
        if (random.Chance(30))
        {
            set("ipPhone", [random.Next(2000, 7999).ToString(CultureInfo.InvariantCulture)]);
        }
        var server = "SRV-FIC-0" + (1 + random.Next(4)).ToString(CultureInfo.InvariantCulture) + ".example.local";
        set("homeDirectory", ["\\\\" + server + "\\Utilisateurs$\\" + user.SamAccountName]);
        set("homeDrive", ["H:"]);
        if (random.Chance(40))
        {
            set("scriptPath", ["logon.cmd"]);
        }
        if (random.Chance(5))
        {
            set("profilePath", ["\\\\SRV-FIC-01.example.local\\Profils$\\" + user.SamAccountName]);
        }
        // Logon hours restricted for some warehouse staff (Monday to Friday, 06:00–21:00 local time); allowed workstations for a few.
        if (string.Equals(user.Department, "Logistique", StringComparison.Ordinal) && random.Chance(18))
        {
            set("logonHours", [LogonHours(DayOfWeek.Monday, DayOfWeek.Friday, 6, 21)]);
        }
        if (string.Equals(user.Department, "Finances", StringComparison.Ordinal) && random.Chance(8))
        {
            var mine = Links().Where(l => l.User == user.ObjectGuid).Select(l => Find(l.Computer)?.Value as DirectoryComputer).Where(c => c is not null).Select(c => c!.Name).ToList();
            var allowed = random.Chance(50) || mine.Count == 0 ? "PC-PAR-0001,PC-PAR-0002" : string.Join(",", mine.Append("PC-PAR-0001"));
            set("userWorkstations", [allowed]);
        }
    }

    /// <summary>logonHours bytes (« FF-FF-… ») allowing the given local hours on the given days, at the offset of the reference.</summary>
    private string LogonHours(DayOfWeek first, DayOfWeek last, int fromHour, int toHour)
    {
        var bytes = new byte[21];
        var offset = (int)Zone.GetUtcOffset(source.World.Reference).TotalHours;
        for (var day = (int)first; day <= (int)last; day++)
        {
            for (var hour = fromHour; hour < toHour; hour++)
            {
                var utc = (((day * 24) + hour - offset) % 168 + 168) % 168;
                bytes[utc / 8] |= (byte)(1 << (utc % 8));
            }
        }
        return BitConverter.ToString(bytes);
    }

    /// <summary>Summary of an object for the local index (names, kinds, places, privilege facts).</summary>
    public FicheSummary Summary(SimulatedObject item)
    {
        ArgumentNullException.ThrowIfNull(item);
        return item.Value switch
        {
            DirectoryUser u => new FicheSummary(u.DistinguishedName, u.DisplayName ?? u.Cn, FicheKind.User, u.SamAccountName,
                string.Join(" · ", new[] { u.Title, u.Department, u.Office }.Where(s => !string.IsNullOrEmpty(s))), AdValues.IsDisabled(u.UserAccountControl), u.ObjectGuid, u.Sid, null, u.AdminCount, u.UserPrincipalName),
            DirectoryComputer c => new FicheSummary(c.DistinguishedName, c.Name, FicheKind.Computer, c.SamAccountName,
                WindowsRelease.Describe(c.OperatingSystem, c.OperatingSystemVersion)?.Label ?? c.OperatingSystem, AdValues.IsDisabled(c.UserAccountControl), c.ObjectGuid, c.Sid),
            DirectoryGroup g => new FicheSummary(g.DistinguishedName, g.Name, FicheKind.Group, g.SamAccountName, g.Description ?? FicheMemberships.GroupTypeLabel(g.GroupType), false, g.ObjectGuid, g.Sid, g.GroupType, g.AdminCount),
            DirectoryOu o => new FicheSummary(o.DistinguishedName, o.Name, FicheKind.Ou, null, FicheValues.ReadablePath(o.DistinguishedName), false, o.ObjectGuid),
            SimulatedContact contact => new FicheSummary(contact.Dn, contact.Attributes.TryGetValue("displayName", out var display) && display.Length > 0 ? display[0] : contact.Cn, FicheKind.Contact, null,
                contact.Attributes.TryGetValue("company", out var company) && company.Length > 0 ? company[0] : "Contact", false, contact.Id),
            DomainInfo d => new FicheSummary(d.RootDn, d.DnsName, FicheKind.Container, null, "Domaine", false, item.Id),
            string container => new FicheSummary(container, FicheValues.DisplayName(container), FicheKind.Container, null, "Conteneur par défaut", false, item.Id),
            _ => throw new InvalidOperationException("Unknown simulated object."),
        };
    }

    // ---------------------------------------------------------------- writes (executors of Domenia.Simulation only)

    private static readonly HashSet<string> UserColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        "givenName", "sn", "displayName", "userPrincipalName", "mail", "title", "department", "physicalDeliveryOfficeName", "telephoneNumber",
        "manager", "description", "employeeID", "userAccountControl", "lockoutTime", "pwdLastSet", "accountExpires",
    };

    private static readonly HashSet<string> ComputerColumns = new(StringComparer.OrdinalIgnoreCase) { "description", "location", "managedBy", "userAccountControl" };

    private static readonly HashSet<string> GroupColumns = new(StringComparer.OrdinalIgnoreCase) { "description", "mail", "managedBy" };

    private static readonly HashSet<string> OuColumns = new(StringComparer.OrdinalIgnoreCase) { "description", "managedBy" };

    /// <summary>
    /// Writes plain attribute values on one object: attributes the generated directory holds go to the overlay of the source (seen
    /// by every screen), the others stay in the memory of this screen. whenChanged and uSNChanged follow, as on a controller.
    /// Returns false when the object no longer exists.
    /// </summary>
    public bool WriteAttributes(Guid id, IReadOnlyDictionary<string, ImmutableArray<string>> changes, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(changes);
        var item = Find(id);
        if (item is null)
        {
            return false;
        }
        var policy = source.World.Directory.Domain.PasswordPolicy;
        var columns = item.Kind switch
        {
            FicheKind.User => UserColumns,
            FicheKind.Computer => ComputerColumns,
            FicheKind.Group => GroupColumns,
            FicheKind.Ou => OuColumns,
            _ => new HashSet<string>(StringComparer.OrdinalIgnoreCase),
        };
        var local = changes.Where(c => !columns.Contains(c.Key)).ToDictionary(c => c.Key, c => c.Value, StringComparer.OrdinalIgnoreCase);
        var recorded = changes.Where(c => columns.Contains(c.Key)).ToDictionary(c => c.Key, c => c.Value, StringComparer.OrdinalIgnoreCase);
        string? First(string key) => recorded.TryGetValue(key, out var v) && !v.IsDefaultOrEmpty ? v[0] : null;
        long? Long(string key) => long.TryParse(First(key), NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : null;
        var ok = source.EditDirectory(edit =>
        {
            var usn = edit.NextUsn();
            switch (item.Kind)
            {
                case FicheKind.User:
                    var user = edit.Current.Users.FirstOrDefault(u => u.ObjectGuid == id);
                    if (user is null)
                    {
                        return false;
                    }
                    var next = user with { WhenChanged = now, UsnChanged = usn };
                    foreach (var key in recorded.Keys)
                    {
                        next = key.ToUpperInvariant() switch
                        {
                            "GIVENNAME" => next with { GivenName = First(key) },
                            "SN" => next with { Surname = First(key) },
                            "DISPLAYNAME" => next with { DisplayName = First(key) },
                            "USERPRINCIPALNAME" => next with { UserPrincipalName = First(key) },
                            "MAIL" => next with { Mail = First(key) },
                            "TITLE" => next with { Title = First(key) },
                            "DEPARTMENT" => next with { Department = First(key) },
                            "PHYSICALDELIVERYOFFICENAME" => next with { Office = First(key) },
                            "TELEPHONENUMBER" => next with { TelephoneNumber = First(key) },
                            "MANAGER" => next with { ManagerDn = First(key) },
                            "DESCRIPTION" => next with { Description = First(key) },
                            "EMPLOYEEID" => next with { EmployeeId = First(key) },
                            "USERACCOUNTCONTROL" => next with { UserAccountControl = (int)(Long(key) ?? next.UserAccountControl) },
                            "LOCKOUTTIME" => next with { LockoutTime = Long(key) ?? 0, BadPasswordCount = (Long(key) ?? 0) == 0 && next.BadPasswordCount is not null ? 0 : next.BadPasswordCount },
                            "PWDLASTSET" => next with { PasswordLastSet = Long(key) },
                            "ACCOUNTEXPIRES" => next with { AccountExpires = Long(key) is long e && e != 0 ? e : AdValues.Never },
                            _ => next,
                        };
                    }
                    edit.Put(Recompute(next, policy, now));
                    return true;
                case FicheKind.Computer:
                    var computer = edit.Current.Computers.FirstOrDefault(c => c.ObjectGuid == id);
                    if (computer is null)
                    {
                        return false;
                    }
                    var nextComputer = computer with { WhenChanged = now, UsnChanged = usn };
                    foreach (var key in recorded.Keys)
                    {
                        nextComputer = key.ToUpperInvariant() switch
                        {
                            "DESCRIPTION" => nextComputer with { Description = First(key) },
                            "LOCATION" => nextComputer with { Location = First(key) },
                            "MANAGEDBY" => nextComputer with { ManagedByDn = First(key) },
                            "USERACCOUNTCONTROL" => nextComputer with { UserAccountControl = (int)(Long(key) ?? nextComputer.UserAccountControl) },
                            _ => nextComputer,
                        };
                    }
                    edit.Put(nextComputer);
                    return true;
                case FicheKind.Group:
                    var group = edit.Current.Groups.FirstOrDefault(g => g.ObjectGuid == id);
                    if (group is null)
                    {
                        return false;
                    }
                    var nextGroup = group with { WhenChanged = now, UsnChanged = usn };
                    foreach (var key in recorded.Keys)
                    {
                        nextGroup = key.ToUpperInvariant() switch
                        {
                            "DESCRIPTION" => nextGroup with { Description = First(key) },
                            "MAIL" => nextGroup with { Mail = First(key) },
                            "MANAGEDBY" => nextGroup with { ManagedByDn = First(key) },
                            _ => nextGroup,
                        };
                    }
                    edit.Put(nextGroup);
                    return true;
                case FicheKind.Ou:
                    var ou = edit.Current.OrganizationalUnits.FirstOrDefault(o => o.ObjectGuid == id);
                    if (ou is null)
                    {
                        return false;
                    }
                    var nextOu = ou with { WhenChanged = now, UsnChanged = usn };
                    foreach (var key in recorded.Keys)
                    {
                        nextOu = key.ToUpperInvariant() switch
                        {
                            "DESCRIPTION" => nextOu with { Description = First(key) },
                            "MANAGEDBY" => nextOu with { ManagedByDn = First(key) },
                            _ => nextOu,
                        };
                    }
                    edit.Put(nextOu);
                    return true;
                default:
                    // Contacts and containers live in the memory of this screen only.
                    local["whenChanged"] = [FicheValues.GeneralizedTime(now)];
                    local["uSNChanged"] = [usn.ToString(CultureInfo.InvariantCulture)];
                    return true;
            }
        });
        if (!ok)
        {
            return false;
        }
        if (local.Count > 0)
        {
            lock (gate)
            {
                var current = overrides.GetValueOrDefault(item.Id) ?? ImmutableDictionary<string, ImmutableArray<string>>.Empty.WithComparers(StringComparer.OrdinalIgnoreCase);
                foreach (var (key, values) in local)
                {
                    current = current.SetItem(key, values.IsDefault ? [] : values);
                }
                overrides = overrides.SetItem(item.Id, current);
                version++;
            }
        }
        return true;
    }

    /// <summary>
    /// What a controller computes after a write on a user: the expiry of the password (never, must change, or last change + maximum
    /// age), the lockout and expired bits of msDS-User-Account-Control-Computed.
    /// </summary>
    private static DirectoryUser Recompute(DirectoryUser user, DomainPasswordPolicy policy, DateTimeOffset now)
    {
        long? expiry;
        if (AdValues.HasFlag(user.UserAccountControl, AdValues.DontExpirePassword))
        {
            expiry = AdValues.Never;
        }
        else if (user.PasswordLastSet is 0)
        {
            expiry = 0;
        }
        else if (AdValues.FromFileTime(user.PasswordLastSet) is DateTimeOffset set && policy.MaxPasswordAge > TimeSpan.Zero)
        {
            expiry = AdValues.ToFileTime(set + policy.MaxPasswordAge);
        }
        else
        {
            expiry = user.PasswordExpiryComputed;
        }
        var computed = user.ComputedAccountControl ?? 0;
        if (user.LockoutTime is null or 0)
        {
            computed &= ~AdValues.LockedOut;
        }
        var expired = AdValues.FromFileTime(expiry) is DateTimeOffset at && at <= now;
        computed = expired ? computed | AdValues.PasswordExpired : computed & ~AdValues.PasswordExpired;
        return user with { PasswordExpiryComputed = expiry, ComputedAccountControl = user.ComputedAccountControl is null ? null : computed };
    }

    /// <summary>Adds or removes one direct member of one group, both sides of the link (member and memberOf).</summary>
    public bool WriteMember(Guid groupId, string memberDn, bool add, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(memberDn);
        return source.EditDirectory(edit =>
        {
            var group = edit.Current.Groups.FirstOrDefault(g => g.ObjectGuid == groupId);
            if (group is null)
            {
                return false;
            }
            var usn = edit.NextUsn();
            var present = group.Members.Any(m => FicheValues.SameDn(m, memberDn));
            if (present == add)
            {
                return true;
            }
            var members = add ? group.Members.Add(memberDn) : [.. group.Members.Where(m => !FicheValues.SameDn(m, memberDn))];
            edit.Put(group with { Members = members, WhenChanged = now, UsnChanged = usn });
            ImmutableArray<string> Update(ImmutableArray<string> memberOf) =>
                add ? memberOf.Add(group.DistinguishedName) : [.. memberOf.Where(g => !FicheValues.SameDn(g, group.DistinguishedName))];
            if (edit.Current.Users.FirstOrDefault(u => FicheValues.SameDn(u.DistinguishedName, memberDn)) is DirectoryUser user)
            {
                edit.Put(user with { MemberOf = Update(user.MemberOf) });
            }
            else if (edit.Current.Computers.FirstOrDefault(c => FicheValues.SameDn(c.DistinguishedName, memberDn)) is DirectoryComputer computer)
            {
                edit.Put(computer with { MemberOf = Update(computer.MemberOf) });
            }
            else if (edit.Current.Groups.FirstOrDefault(g => FicheValues.SameDn(g.DistinguishedName, memberDn)) is DirectoryGroup inner)
            {
                edit.Put(inner with { MemberOf = Update(inner.MemberOf) });
            }
            return true;
        });
    }

    /// <summary>Moves one object (DN changed, GUID kept) and every reference to it (members, memberOf, manager, managedBy).</summary>
    public bool WriteMove(Guid id, string destinationDn, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(destinationDn);
        var item = Find(id);
        if (item is null)
        {
            return false;
        }
        if (item.Value is SimulatedContact contact)
        {
            var newDn = DistinguishedName.Child("CN", contact.Cn, destinationDn);
            source.EditDirectory(edit =>
            {
                RewriteReferences(edit, contact.Dn, newDn);
                return true;
            });
            lock (gate)
            {
                contactDns = contactDns.SetItem(contact.Id, newDn);
                var current = overrides.GetValueOrDefault(contact.Id) ?? ImmutableDictionary<string, ImmutableArray<string>>.Empty.WithComparers(StringComparer.OrdinalIgnoreCase);
                overrides = overrides.SetItem(contact.Id, current.SetItem("whenChanged", [FicheValues.GeneralizedTime(now)]));
                version++;
            }
            return true;
        }
        return source.EditDirectory(edit =>
        {
            var usn = edit.NextUsn();
            switch (item.Kind)
            {
                case FicheKind.User when edit.Current.Users.FirstOrDefault(u => u.ObjectGuid == id) is DirectoryUser user:
                    var userDn = DistinguishedName.Child("CN", user.Cn, destinationDn);
                    RewriteReferences(edit, user.DistinguishedName, userDn);
                    edit.Put(Current(edit, user) with { DistinguishedName = userDn, WhenChanged = now, UsnChanged = usn });
                    return true;
                case FicheKind.Computer when edit.Current.Computers.FirstOrDefault(c => c.ObjectGuid == id) is DirectoryComputer computer:
                    var computerDn = DistinguishedName.Child("CN", computer.Name, destinationDn);
                    RewriteReferences(edit, computer.DistinguishedName, computerDn);
                    edit.Put(Current(edit, computer) with { DistinguishedName = computerDn, WhenChanged = now, UsnChanged = usn });
                    return true;
                case FicheKind.Group when edit.Current.Groups.FirstOrDefault(g => g.ObjectGuid == id) is DirectoryGroup group:
                    var groupDn = DistinguishedName.Child("CN", group.Name, destinationDn);
                    RewriteReferences(edit, group.DistinguishedName, groupDn);
                    edit.Put(Current(edit, group) with { DistinguishedName = groupDn, WhenChanged = now, UsnChanged = usn });
                    return true;
                default:
                    return false;
            }
        });
    }

    // The latest version of an object inside an edit (it may have been put already by RewriteReferences).
    private static DirectoryUser Current(SimulatedDirectoryEdit edit, DirectoryUser user) => edit.Users.GetValueOrDefault(user.ObjectGuid) ?? user;

    private static DirectoryComputer Current(SimulatedDirectoryEdit edit, DirectoryComputer computer) => edit.Computers.GetValueOrDefault(computer.ObjectGuid) ?? computer;

    private static DirectoryGroup Current(SimulatedDirectoryEdit edit, DirectoryGroup group) => edit.Groups.GetValueOrDefault(group.ObjectGuid) ?? group;

    /// <summary>Replaces (or removes, with null) every link to <paramref name="oldDn"/>, as the controller keeps linked attributes consistent.</summary>
    private static void RewriteReferences(SimulatedDirectoryEdit edit, string oldDn, string? newDn)
    {
        ImmutableArray<string> Fix(ImmutableArray<string> values)
        {
            if (!values.Any(v => FicheValues.SameDn(v, oldDn)))
            {
                return values;
            }
            return newDn is null ? [.. values.Where(v => !FicheValues.SameDn(v, oldDn))] : [.. values.Select(v => FicheValues.SameDn(v, oldDn) ? newDn : v)];
        }
        string? FixOne(string? value) => value is not null && FicheValues.SameDn(value, oldDn) ? newDn : value;
        foreach (var user in edit.Current.Users)
        {
            var latest = Current(edit, user);
            var fixedUser = latest with { MemberOf = Fix(latest.MemberOf), ManagerDn = FixOne(latest.ManagerDn) };
            if (fixedUser.MemberOf != latest.MemberOf || fixedUser.ManagerDn != latest.ManagerDn)
            {
                edit.Put(fixedUser);
            }
        }
        foreach (var computer in edit.Current.Computers)
        {
            var latest = Current(edit, computer);
            var fixedComputer = latest with { MemberOf = Fix(latest.MemberOf), ManagedByDn = FixOne(latest.ManagedByDn) };
            if (fixedComputer.MemberOf != latest.MemberOf || fixedComputer.ManagedByDn != latest.ManagedByDn)
            {
                edit.Put(fixedComputer);
            }
        }
        foreach (var group in edit.Current.Groups)
        {
            var latest = Current(edit, group);
            var fixedGroup = latest with { Members = Fix(latest.Members), MemberOf = Fix(latest.MemberOf), ManagedByDn = FixOne(latest.ManagedByDn) };
            if (fixedGroup.Members != latest.Members || fixedGroup.MemberOf != latest.MemberOf || fixedGroup.ManagedByDn != latest.ManagedByDn)
            {
                edit.Put(fixedGroup);
            }
        }
        foreach (var ou in edit.Current.OrganizationalUnits)
        {
            var latest = edit.Ous.GetValueOrDefault(ou.ObjectGuid) ?? ou;
            if (FixOne(latest.ManagedByDn) != latest.ManagedByDn)
            {
                edit.Put(latest with { ManagedByDn = FixOne(latest.ManagedByDn) });
            }
        }
    }

    /// <summary>Deletes one object (never recursively) and every link to it.</summary>
    public bool WriteDelete(Guid id)
    {
        var item = Find(id);
        if (item is null)
        {
            return false;
        }
        var ok = source.EditDirectory(edit =>
        {
            RewriteReferences(edit, item.Dn, null);
            if (item.Kind is FicheKind.User or FicheKind.Computer or FicheKind.Group or FicheKind.Ou)
            {
                edit.Remove(id);
            }
            return true;
        });
        if (ok && item.Kind == FicheKind.Contact)
        {
            lock (gate)
            {
                removedContacts = removedContacts.Add(id);
                version++;
            }
        }
        return ok;
    }

    /// <summary>Creates an OU under a branch; its GUID is derived from the seed, the DN and the change number (deterministic).</summary>
    public bool WriteCreateOu(string childDn, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(childDn);
        var name = FicheValues.DisplayName(childDn);
        return source.EditDirectory(edit =>
        {
            if (edit.Current.OrganizationalUnits.Any(o => FicheValues.SameDn(o.DistinguishedName, childDn)))
            {
                return true;
            }
            var usn = edit.NextUsn();
            var random = Stream("ou/" + childDn.ToUpperInvariant() + "/" + usn.ToString(CultureInfo.InvariantCulture));
            edit.Put(new DirectoryOu(NewGuid(random), childDn, name, null, null, now, now, usn));
            return true;
        });
    }
}
