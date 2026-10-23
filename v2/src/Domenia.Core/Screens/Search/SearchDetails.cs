using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>
/// Local preview and comparison of the search screen, ported from Domenia 1 (Get-DomeniaSearchPreviewRows,
/// Get-DomeniaComputerComparison, points 58 and 59): every value keeps its own date, a value never read stays « Non lu »,
/// an empty column of the base is « Non renseigné », and a missing value is never « Identique ». Pure.
/// </summary>
public static class SearchDetails
{
    public const int MaxAttributes = 80;
    public const int MinCompared = 2;
    public const int MaxCompared = 8;
    private const string Unread = "Non lu";
    private const string Unset = "Non renseigné";
    private const string NoDate = "Date non confirmée";

    /// <summary>Local date and time « 21/10/2026 18:14 », or « — ».</summary>
    public static string When(DateTimeOffset? at, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        if (at is not DateTimeOffset value)
        {
            return "—";
        }
        var local = TimeZoneInfo.ConvertTime(value, timeZone);
        return local.ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// Stored fiche of one object, from the local base only: identity with the date of the read, directory attributes
    /// (80 at most), then for a workstation its presence, console user, inventory and addresses (Domenia 1 RCH-001).
    /// </summary>
    public static SearchPreview Preview(SearchRow row, object record, DirectorySnapshot snapshot, WorkstationObservation? observation, TimeZoneInfo timeZone, string sourceLabel)
    {
        ArgumentNullException.ThrowIfNull(row);
        ArgumentNullException.ThrowIfNull(record);
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(timeZone);
        var read = "Lu le " + When(snapshot.ReadAt, timeZone) + " · " + sourceLabel;
        var sections = ImmutableArray.CreateBuilder<SearchPreviewSection>();
        sections.Add(new SearchPreviewSection("identity", "Identité", [
            Item("Nom", row.Name, read),
            Item("Type", row.KindLabel, read),
            Item("Chemin", row.Dn, read, mono: true),
            Item("État du compte", row.State.Label, read, row.State.Tone),
            Item("Description", row.Description, read),
            Item("Identifiant", row.Login, read, mono: true),
            Item("UPN / DNS", row.Upn, read, mono: true),
            Item("Connexion AD approximative", row.LastLogon is null ? null : When(row.LastLogon, timeZone), read),
        ]));
        var attributes = Attributes(record, snapshot, timeZone);
        var truncated = attributes.Count > MaxAttributes;
        var shown = attributes.Take(MaxAttributes).Select(a => Item(a.Name, a.Value, read, mono: a.Mono)).ToList();
        if (truncated)
        {
            shown.Add(new SearchPreviewItem("Attributs AD", "Affichage limité à " + FrenchText.Integer(MaxAttributes) + " attributs ; les autres restent dans la base locale.", "", Tone.Info, false));
        }
        sections.Add(new SearchPreviewSection("attributes", "Attributs de l’annuaire", [.. shown]));
        if (row.Kind == SearchObjectKind.Computer)
        {
            sections.Add(PresenceSection(row, timeZone));
            sections.Add(ConsoleSection(row, timeZone));
            sections.Add(InventorySection(observation, timeZone));
            sections.Add(AddressSection(row, timeZone));
        }
        else if (row.Kind == SearchObjectKind.User && row.Association is SearchAssociation association)
        {
            sections.Add(new SearchPreviewSection("association", "Postes associés", [
                Item("Association mémorisée", association.Label, association.Source),
                Item("Qualification", association.Qualification, association.Note),
            ]));
        }
        return new SearchPreview(row, sections.ToImmutable(), sourceLabel, attributes.Count, truncated);
    }

    /// <summary>
    /// Two to eight objects of one kind side by side, from the local base: identity and system lines, then the measured
    /// families of a workstation. Each line says whether the values differ (same, different, dateOnly, unknown).
    /// </summary>
    public static SearchComparison Compare(IReadOnlyList<(SearchRow Row, object Record, WorkstationObservation? Observation)> items, DirectorySnapshot snapshot, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(items);
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(timeZone);
        var kind = items.Count > 0 ? items[0].Row.Kind : SearchObjectKind.Computer;
        var read = When(snapshot.ReadAt, timeZone);
        var definitions = kind == SearchObjectKind.Computer ? ComputerLines(snapshot, timeZone) : UserLines(snapshot, timeZone);
        var lines = ImmutableArray.CreateBuilder<SearchComparisonLine>();
        foreach (var (family, property, value) in definitions)
        {
            lines.Add(Line(family, property, items.Select(i => value(i.Record) is string text ? new SearchComparisonValue(text, read, true) : new SearchComparisonValue(Unset, read, false))));
        }
        if (kind == SearchObjectKind.Computer)
        {
            lines.Add(Line("Présence réseau", "État", items.Select(i => i.Row.Presence is SearchPresence p && p.State != SearchPresenceState.Unknown
                ? new SearchComparisonValue(p.Label, When(p.CheckedAt, timeZone), true) : new SearchComparisonValue(Unread, NoDate, false))));
            lines.Add(Line("Présence réseau", "Dernière réponse", items.Select(i => i.Row.Presence?.LastOnlineAt is DateTimeOffset at
                ? new SearchComparisonValue(When(at, timeZone), When(i.Row.Presence.CheckedAt, timeZone), true) : new SearchComparisonValue(Unread, NoDate, false))));
            lines.Add(Line("Utilisateur connecté", "Session à la console", items.Select(i => i.Row.Console is SearchConsole c && c.State != "unknown"
                ? new SearchComparisonValue(c.Label, When(c.At, timeZone), true) : new SearchComparisonValue(Unread, NoDate, false))));
            foreach (var (property, value) in InventoryFields())
            {
                lines.Add(Line("Inventaire", property, items.Select(i => i.Observation?.Inventory is { HasReading: true } inventory && value(inventory) is string text
                    ? new SearchComparisonValue(text, When(inventory.CheckedAt, timeZone), true) : new SearchComparisonValue(Unread, NoDate, false))));
            }
        }
        var built = lines.ToImmutable();
        var different = built.Count(l => l.Difference == "different");
        var same = built.Count(l => l.Difference is "same" or "dateOnly");
        var unknown = built.Count(l => l.Difference == "unknown");
        var summary = FrenchText.Count(items.Count, "objet comparé", "objets comparés") + " · " + FrenchText.Count(different, "propriété différente", "propriétés différentes")
            + " · " + FrenchText.Count(unknown, "propriété incomplète", "propriétés incomplètes") + " · valeurs de la base locale, aucune relecture.";
        return new SearchComparison(kind, [.. items.Select(i => i.Row)], built, different, same, unknown, summary);
    }

    private static SearchComparisonLine Line(string family, string property, IEnumerable<SearchComparisonValue> values)
    {
        var list = values.ToImmutableArray();
        var known = list.Where(v => v.Known).Select(v => v.Text).Distinct(StringComparer.Ordinal).Count();
        var dates = list.Where(v => v.Known).Select(v => v.Date).Distinct(StringComparer.Ordinal).Count();
        var unknown = list.Any(v => !v.Known);
        var (comparison, difference) = list.Length == 1 ? ("", "single")
            : unknown ? (known > 1 ? "Incomplet, valeurs connues différentes" : "Incomplet", "unknown")
            : known > 1 ? ("Valeurs différentes", "different")
            : dates > 1 ? ("Valeurs identiques, dates différentes", "dateOnly")
            : ("Identique", "same");
        return new SearchComparisonLine(family, property, comparison, difference, list);
    }

    private static List<(string Family, string Property, Func<object, string?> Value)> ComputerLines(DirectorySnapshot snapshot, TimeZoneInfo zone) =>
    [
        ("Identité AD", "Identité AD", o => ((DirectoryComputer)o).ObjectGuid.ToString("D")),
        ("Identité AD", "Nom", o => ((DirectoryComputer)o).Name),
        ("Identité AD", "OU", o => SearchTexts.ContainerPath(((DirectoryComputer)o).DistinguishedName, snapshot.Domain.DnsName)),
        ("Identité AD", "Compte activé", o => AdValues.IsDisabled(((DirectoryComputer)o).UserAccountControl) ? "Non" : "Oui"),
        ("Identité AD", "Description", o => Empty(((DirectoryComputer)o).Description)),
        ("Identité AD", "Connexion AD approximative", o => DateOrNull(AdValues.FromFileTime(((DirectoryComputer)o).LastLogonTimestamp), zone)),
        ("Système", "Système", o => Empty(((DirectoryComputer)o).OperatingSystem)),
        ("Système", "Version du système", o => Empty(((DirectoryComputer)o).OperatingSystemVersion)),
        ("Système", "Création AD", o => When(((DirectoryComputer)o).WhenCreated, zone)),
        ("Système", "Mot de passe machine modifié", o => DateOrNull(AdValues.FromFileTime(((DirectoryComputer)o).PasswordLastSet), zone)),
        ("Système", "Emplacement", o => Empty(((DirectoryComputer)o).Location)),
        ("Système", "LAPS", o => ((DirectoryComputer)o).Laps switch { LapsKind.Windows => "LAPS Windows", LapsKind.Legacy => "LAPS hérité", _ => "Aucun" }),
    ];

    private static List<(string Family, string Property, Func<object, string?> Value)> UserLines(DirectorySnapshot snapshot, TimeZoneInfo zone) =>
    [
        ("Identité AD", "Identité AD", o => ((DirectoryUser)o).ObjectGuid.ToString("D")),
        ("Identité AD", "Nom affiché", o => Empty(((DirectoryUser)o).DisplayName)),
        ("Identité AD", "Compte", o => ((DirectoryUser)o).SamAccountName),
        ("Identité AD", "UPN", o => Empty(((DirectoryUser)o).UserPrincipalName)),
        ("Identité AD", "Courriel", o => Empty(((DirectoryUser)o).Mail)),
        ("Identité AD", "OU", o => SearchTexts.ContainerPath(((DirectoryUser)o).DistinguishedName, snapshot.Domain.DnsName)),
        ("Organisation", "Service", o => Empty(((DirectoryUser)o).Department)),
        ("Organisation", "Fonction", o => Empty(((DirectoryUser)o).Title)),
        ("Organisation", "Bureau", o => Empty(((DirectoryUser)o).Office)),
        ("Organisation", "Responsable", o => ((DirectoryUser)o).ManagerDn is string m ? SearchTexts.Leaf(m) : null),
        ("Compte", "État", o => State((DirectoryUser)o)),
        ("Compte", "Mot de passe", o => Password((DirectoryUser)o, snapshot)),
        ("Compte", "Mot de passe changé", o => DateOrNull(AdValues.FromFileTime(((DirectoryUser)o).PasswordLastSet), zone)),
        ("Compte", "Expiration du compte", o => ((DirectoryUser)o).AccountExpires is long v && (v == 0 || v == AdValues.Never) ? "Jamais" : DateOrNull(AdValues.FromFileTime(((DirectoryUser)o).AccountExpires), zone)),
        ("Compte", "Connexion AD approximative", o => DateOrNull(AdValues.FromFileTime(((DirectoryUser)o).LastLogonTimestamp), zone)),
        ("Compte", "Création AD", o => When(((DirectoryUser)o).WhenCreated, zone)),
        ("Compte", "Groupes (memberOf)", o => FrenchText.Count(((DirectoryUser)o).MemberOf.Length, "groupe", "groupes")),
        ("Compte", "Compte protégé (adminCount)", o => ((DirectoryUser)o).AdminCount == 1 ? "Oui" : "Non"),
    ];

    private static IEnumerable<(string Property, Func<InventoryMeasure, string?> Value)> InventoryFields() =>
    [
        ("Modèle", i => Empty(i.Model)),
        ("Mémoire", i => i.MemoryBytes is long m && m > 0 ? FrenchText.Integer((long)Math.Round(m / (double)(1L << 30))) + FrenchText.Nbsp + "Go" : null),
        ("Espace libre sur C:", i => i.SystemDiskSizeBytes is long size && size > 0 && i.SystemDiskFreeBytes is long free ? FrenchText.Percent(100.0 * free / size) : null),
        ("Système relevé", i => Empty(i.OsCaption)),
        ("Version relevée", i => Empty(i.Build)),
    ];

    private static List<(string Name, string Value, bool Mono)> Attributes(object record, DirectorySnapshot snapshot, TimeZoneInfo zone)
    {
        var list = new List<(string Name, string Value, bool Mono)>();
        void Add(string name, string? value, bool mono = false)
        {
            if (!string.IsNullOrEmpty(value))
            {
                list.Add(("Attribut AD · " + name, value, mono));
            }
        }
        void Date(string name, long? fileTime)
        {
            if (fileTime is long v)
            {
                list.Add(("Attribut AD · " + name, v <= 0 ? "0 (aucune date)" : v == AdValues.Never ? "Jamais (valeur maximale)" : When(AdValues.FromFileTime(v), zone), false));
            }
        }
        switch (record)
        {
            case DirectoryUser u:
                Add("sAMAccountName", u.SamAccountName, true);
                Add("userPrincipalName", u.UserPrincipalName, true);
                Add("displayName", u.DisplayName);
                Add("givenName", u.GivenName);
                Add("sn", u.Surname);
                Add("mail", u.Mail, true);
                Add("title", u.Title);
                Add("department", u.Department);
                Add("physicalDeliveryOfficeName", u.Office);
                Add("telephoneNumber", u.TelephoneNumber, true);
                Add("manager", u.ManagerDn, true);
                Add("employeeID", u.EmployeeId, true);
                Add("description", u.Description);
                Add("userAccountControl", Uac(u.UserAccountControl), true);
                Add("msDS-User-Account-Control-Computed", u.ComputedAccountControl?.ToString(CultureInfo.InvariantCulture), true);
                Date("lockoutTime", u.LockoutTime);
                Add("badPwdCount", u.BadPasswordCount?.ToString(CultureInfo.InvariantCulture));
                Date("pwdLastSet", u.PasswordLastSet);
                Date("msDS-UserPasswordExpiryTimeComputed", u.PasswordExpiryComputed);
                Date("lastLogonTimestamp", u.LastLogonTimestamp);
                Date("accountExpires", u.AccountExpires);
                Add("whenCreated", When(u.WhenCreated, zone));
                Add("whenChanged", When(u.WhenChanged, zone));
                Add("uSNChanged", u.UsnChanged.ToString(CultureInfo.InvariantCulture), true);
                Add("adminCount", u.AdminCount?.ToString(CultureInfo.InvariantCulture));
                Add("primaryGroupID", u.PrimaryGroupId.ToString(CultureInfo.InvariantCulture));
                Add("objectSid", u.Sid, true);
                Add("objectGUID", u.ObjectGuid.ToString("D"), true);
                Add("memberOf", Members(u.MemberOf));
                break;
            case DirectoryComputer c:
                Add("sAMAccountName", c.SamAccountName, true);
                Add("dNSHostName", c.DnsHostName, true);
                Add("operatingSystem", c.OperatingSystem);
                Add("operatingSystemVersion", c.OperatingSystemVersion);
                Add("description", c.Description);
                Add("location", c.Location);
                Add("managedBy", c.ManagedByDn, true);
                Add("userAccountControl", Uac(c.UserAccountControl), true);
                Date("lastLogonTimestamp", c.LastLogonTimestamp);
                Date("pwdLastSet", c.PasswordLastSet);
                Date(c.Laps == LapsKind.Legacy ? "ms-Mcs-AdmPwdExpirationTime" : "msLAPS-PasswordExpirationTime", c.LapsExpiration);
                Add("whenCreated", When(c.WhenCreated, zone));
                Add("whenChanged", When(c.WhenChanged, zone));
                Add("uSNChanged", c.UsnChanged.ToString(CultureInfo.InvariantCulture), true);
                Add("primaryGroupID", c.PrimaryGroupId.ToString(CultureInfo.InvariantCulture));
                Add("objectSid", c.Sid, true);
                Add("objectGUID", c.ObjectGuid.ToString("D"), true);
                Add("memberOf", Members(c.MemberOf));
                break;
            case DirectoryGroup g:
                Add("sAMAccountName", g.SamAccountName, true);
                Add("groupType", g.GroupType.ToString(CultureInfo.InvariantCulture) + " · " + SearchTexts.GroupScope(g.GroupType), true);
                Add("description", g.Description);
                Add("mail", g.Mail, true);
                Add("managedBy", g.ManagedByDn, true);
                Add("adminCount", g.AdminCount?.ToString(CultureInfo.InvariantCulture));
                Add("member", FrenchText.Count(g.Members.Length, "membre direct", "membres directs") + (g.Members.Length > 0 ? FrenchText.Colon + string.Join(", ", g.Members.Take(12).Select(SearchTexts.Leaf)) + (g.Members.Length > 12 ? "…" : "") : ""));
                Add("memberOf", Members(g.MemberOf));
                Add("whenCreated", When(g.WhenCreated, zone));
                Add("whenChanged", When(g.WhenChanged, zone));
                Add("uSNChanged", g.UsnChanged.ToString(CultureInfo.InvariantCulture), true);
                Add("objectSid", g.Sid, true);
                Add("objectGUID", g.ObjectGuid.ToString("D"), true);
                break;
            case DirectoryContact c:
                Add("displayName", c.DisplayName);
                Add("givenName", c.GivenName);
                Add("sn", c.Surname);
                Add("mail", c.Mail, true);
                Add("title", c.Title);
                Add("department", c.Department);
                Add("physicalDeliveryOfficeName", c.Office);
                Add("telephoneNumber", c.TelephoneNumber, true);
                Add("manager", c.ManagerDn, true);
                Add("description", c.Description);
                Add("whenCreated", When(c.WhenCreated, zone));
                Add("whenChanged", When(c.WhenChanged, zone));
                Add("uSNChanged", c.UsnChanged.ToString(CultureInfo.InvariantCulture), true);
                Add("objectGUID", c.ObjectGuid.ToString("D"), true);
                Add("memberOf", Members(c.MemberOf));
                break;
            case DirectoryOu ou:
                Add("description", ou.Description);
                Add("managedBy", ou.ManagedByDn, true);
                Add("whenCreated", When(ou.WhenCreated, zone));
                Add("whenChanged", When(ou.WhenChanged, zone));
                Add("uSNChanged", ou.UsnChanged.ToString(CultureInfo.InvariantCulture), true);
                Add("objectGUID", ou.ObjectGuid.ToString("D"), true);
                var counts = SearchCounts(ou.DistinguishedName, snapshot);
                Add("Contenu (calculé)", counts);
                break;
        }
        return list;
    }

    private static string SearchCounts(string dn, DirectorySnapshot snapshot)
    {
        bool In(string child) => SearchMemoryRules.Within(child, dn) && !SearchLists.IsRoot(child, dn);
        return FrenchText.Count(snapshot.Users.Count(u => In(u.DistinguishedName)), "utilisateur", "utilisateurs") + " · "
            + FrenchText.Count(snapshot.Computers.Count(c => In(c.DistinguishedName)), "ordinateur", "ordinateurs") + " · "
            + FrenchText.Count(snapshot.Groups.Count(g => In(g.DistinguishedName)), "groupe", "groupes") + ", sous-OU comprises";
    }

    private static SearchPreviewSection PresenceSection(SearchRow row, TimeZoneInfo zone)
    {
        if (row.Presence is not SearchPresence p || p.State == SearchPresenceState.Unknown && p.CheckedAt is null)
        {
            return new SearchPreviewSection("presence", "Présence réseau", [new SearchPreviewItem("Présence réseau", Unread, "Aucun relevé enregistré", Tone.Off, false)]);
        }
        return new SearchPreviewSection("presence", "Présence réseau", [
            new SearchPreviewItem("État", p.Label, p.CheckedAt is null ? NoDate : "Relevé le " + When(p.CheckedAt, zone), p.Tone, false),
            new SearchPreviewItem("Dernière réponse au ping", p.LastOnlineAt is null ? "Aucune réponse enregistrée" : When(p.LastOnlineAt, zone), "", null, false),
            new SearchPreviewItem("Lecture", p.Detail, "", Tone.Info, false),
        ]);
    }

    private static SearchPreviewSection ConsoleSection(SearchRow row, TimeZoneInfo zone) =>
        row.Console is SearchConsole c && c.State != "unknown"
            ? new SearchPreviewSection("console", "Utilisateur connecté", [
                new SearchPreviewItem("Session à la console", c.Label, c.At is null ? NoDate : "Relevé le " + When(c.At, zone), c.State == "seen" ? Tone.Ok : Tone.Off, false),
                new SearchPreviewItem("Compte", c.Login ?? "—", "", null, true),
                new SearchPreviewItem("Limite", "Console seulement" + FrenchText.Colon + "les sessions RDP ne sont pas recensées par ce relevé.", "", Tone.Info, false),
            ])
            : new SearchPreviewSection("console", "Utilisateur connecté", [new SearchPreviewItem("Utilisateur connecté", Unread, "Aucun relevé enregistré", Tone.Off, false)]);

    private static SearchPreviewSection InventorySection(WorkstationObservation? observation, TimeZoneInfo zone)
    {
        if (observation?.Inventory is not { HasReading: true } i)
        {
            return new SearchPreviewSection("inventory", "Inventaire", [new SearchPreviewItem("Inventaire", Unread, "Aucun relevé enregistré", Tone.Off, false)]);
        }
        var date = "Relevé le " + When(i.CheckedAt, zone);
        var items = InventoryFields().Select(f => new SearchPreviewItem(f.Property, f.Value(i) ?? Unread, date, null, false)).ToList();
        items.Add(new SearchPreviewItem("Dernier démarrage", i.LastBootAt is null ? Unread : When(i.LastBootAt, zone), date, null, false));
        return new SearchPreviewSection("inventory", "Inventaire", [.. items]);
    }

    private static SearchPreviewSection AddressSection(SearchRow row, TimeZoneInfo zone) =>
        row.Address is SearchAddressReading a
            ? new SearchPreviewSection("addresses", "Adresses relevées", [
                new SearchPreviewItem("Adresse IP", a.Ip ?? Unread, a.ObservedAt is null ? NoDate : "Relevée le " + When(a.ObservedAt, zone), null, true),
                new SearchPreviewItem("Adresse MAC", a.Mac ?? Unread, a.ObservedAt is null ? NoDate : "Relevée le " + When(a.ObservedAt, zone), null, true),
                new SearchPreviewItem("Prudence", "Une adresse peut avoir changé depuis le relevé ; elle n’est pas relue dans l’annuaire.", "", Tone.Info, false),
            ])
            : new SearchPreviewSection("addresses", "Adresses relevées", [new SearchPreviewItem("Adresses", Unread, "Aucun relevé réseau enregistré", Tone.Off, false)]);

    private static SearchPreviewItem Item(string label, string? value, string date, Tone? tone = null, bool mono = false) =>
        new(label, string.IsNullOrWhiteSpace(value) ? Unset + " dans la base locale" : value, string.IsNullOrEmpty(date) ? NoDate : date, tone, mono);

    private static string Uac(int value)
    {
        var flags = new List<string>();
        if ((value & AdValues.AccountDisabled) != 0) flags.Add("désactivé");
        if ((value & AdValues.PasswordNotRequired) != 0) flags.Add("mot de passe non exigé");
        if ((value & AdValues.NormalAccount) != 0) flags.Add("compte normal");
        if ((value & AdValues.WorkstationTrustAccount) != 0) flags.Add("poste");
        if ((value & AdValues.ServerTrustAccount) != 0) flags.Add("contrôleur");
        if ((value & AdValues.DontExpirePassword) != 0) flags.Add("mot de passe sans expiration");
        if ((value & AdValues.SmartCardRequired) != 0) flags.Add("carte à puce exigée");
        if ((value & AdValues.TrustedForDelegation) != 0) flags.Add("délégation approuvée");
        return value.ToString(CultureInfo.InvariantCulture) + (flags.Count > 0 ? " (" + string.Join(", ", flags) + ")" : "");
    }

    private static string? Members(ImmutableArray<string> dns) =>
        dns.IsDefaultOrEmpty ? null : FrenchText.Count(dns.Length, "groupe", "groupes") + FrenchText.Colon + string.Join(", ", dns.Take(12).Select(SearchTexts.Leaf)) + (dns.Length > 12 ? "…" : "");

    private static string State(DirectoryUser user)
    {
        var state = AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime);
        return state.Disabled ? "Désactivé" : state.Lock switch { LockState.Locked => "Verrouillé", LockState.ToCheck => "Verrouillage à vérifier", _ => "Actif" };
    }

    private static string Password(DirectoryUser user, DirectorySnapshot snapshot) =>
        AccountState.ClassifyPassword(user, snapshot.Domain.PasswordPolicy.MaxPasswordAge, snapshot.ReadAt, TimeSpan.FromDays(7)) switch
        {
            PasswordClass.MustChange => "À changer à la prochaine connexion",
            PasswordClass.NeverExpires => "N’expire jamais",
            PasswordClass.Expired => "Expiré",
            PasswordClass.Expiring => "Expire sous 7 jours",
            _ => "Valide",
        };

    private static string? Empty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;

    private static string? DateOrNull(DateTimeOffset? at, TimeZoneInfo zone) => at is null ? null : When(at, zone);
}
