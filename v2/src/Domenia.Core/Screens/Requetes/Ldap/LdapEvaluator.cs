using System.Collections.Immutable;
using System.Globalization;
using System.Numerics;
using System.Text;

namespace Domenia.Core.Queries.Ldap;

/// <summary>How an entry holds an attribute: values, known to be absent, or not read by Domenia (Undefined).</summary>
public enum LdapPresence
{
    Present,
    Absent,
    NotRead,
}

/// <summary>Directory entry as an LDAP filter sees it: string values in their LDAP form (integers, « TRUE », generalized time).</summary>
public interface ILdapEntry
{
    string DistinguishedName { get; }

    LdapPresence Get(LdapAttribute attribute, out IReadOnlyList<string> values);
}

/// <summary>Transitive links for the in-chain rule (1.2.840.113556.1.4.1941).</summary>
public interface ILdapChain
{
    /// <summary>True when <paramref name="target"/> is reached from <paramref name="entry"/> by following <paramref name="attribute"/> (memberOf, member, manager).</summary>
    bool Reaches(ILdapEntry entry, LdapAttribute attribute, string target);
}

/// <summary>
/// Three-valued evaluation of an LDAP filter (RFC 4511 § 4.5.1.7): TRUE (Match), FALSE (NoMatch), Undefined (Unknown).
/// An attribute unknown to the schema, not read by Domenia, an invalid assertion value or an unsupported matching rule
/// give Undefined; an attribute known to be absent gives FALSE, as on a controller. NOT of Undefined stays Undefined.
/// Pure: works on the simulated directory and on the local base alike.
/// </summary>
public static class LdapEvaluator
{
    private static readonly DateTimeOffset Epoch = new(1601, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public static MatchState Evaluate(LdapFilter filter, ILdapEntry entry, ILdapChain? chain = null)
    {
        ArgumentNullException.ThrowIfNull(filter);
        ArgumentNullException.ThrowIfNull(entry);
        switch (filter.Kind)
        {
            case LdapFilterKind.And:
                {
                    var unknown = false;
                    foreach (var child in filter.Children)
                    {
                        var state = Evaluate(child, entry, chain);
                        if (state == MatchState.NoMatch)
                        {
                            return MatchState.NoMatch;
                        }
                        unknown |= state == MatchState.Unknown;
                    }
                    return unknown ? MatchState.Unknown : MatchState.Match;
                }
            case LdapFilterKind.Or:
                {
                    var unknown = false;
                    foreach (var child in filter.Children)
                    {
                        var state = Evaluate(child, entry, chain);
                        if (state == MatchState.Match)
                        {
                            return MatchState.Match;
                        }
                        unknown |= state == MatchState.Unknown;
                    }
                    return unknown ? MatchState.Unknown : MatchState.NoMatch;
                }
            case LdapFilterKind.Not:
                return filter.Children.Length == 0 ? MatchState.Unknown : Negate(Evaluate(filter.Children[0], entry, chain));
            default:
                return Item(filter, entry, chain);
        }
    }

    public static MatchState Negate(MatchState state) => state switch
    {
        MatchState.Match => MatchState.NoMatch,
        MatchState.NoMatch => MatchState.Match,
        _ => MatchState.Unknown,
    };

    /// <summary>Why an item is Undefined, in French (explanations); null when it decides.</summary>
    public static string? UndefinedReason(LdapFilter filter, ILdapEntry entry)
    {
        ArgumentNullException.ThrowIfNull(filter);
        ArgumentNullException.ThrowIfNull(entry);
        if (filter.Kind is LdapFilterKind.And or LdapFilterKind.Or or LdapFilterKind.Not)
        {
            return null;
        }
        if (filter.Attribute is null)
        {
            return "Filtre étendu sans attribut : non évalué localement.";
        }
        if (LdapSchema.Find(filter.Attribute) is not { } attribute)
        {
            return "Attribut « " + filter.Attribute + " » inconnu du schéma de Domenia.";
        }
        if (entry.Get(attribute, out _) == LdapPresence.NotRead)
        {
            return "Attribut « " + attribute.Name + " » non conservé par Domenia : le contrôleur l’évaluera en mode annuaire.";
        }
        return null;
    }

    private static MatchState Item(LdapFilter filter, ILdapEntry entry, ILdapChain? chain)
    {
        if (filter.Attribute is null || LdapSchema.Find(filter.Attribute) is not { } attribute)
        {
            return MatchState.Unknown;
        }
        var presence = entry.Get(attribute, out var values);
        if (presence == LdapPresence.NotRead)
        {
            return MatchState.Unknown;
        }
        if (filter.Kind == LdapFilterKind.Present)
        {
            return presence == LdapPresence.Present && values.Count > 0 ? MatchState.Match : MatchState.NoMatch;
        }
        if (filter.DnAttributes)
        {
            return MatchState.Unknown;
        }
        switch (filter.Kind)
        {
            case LdapFilterKind.Equality:
            case LdapFilterKind.Approx:
                return Any(attribute, presence, values, v => Equal(attribute, v, filter));
            case LdapFilterKind.GreaterOrEqual:
            case LdapFilterKind.LessOrEqual:
                if (!attribute.Ordered)
                {
                    return MatchState.Unknown;
                }
                return Any(attribute, presence, values, v => Compare(attribute, v, filter.Text) is int c ? (filter.Kind == LdapFilterKind.GreaterOrEqual ? c >= 0 : c <= 0) : null);
            case LdapFilterKind.Substring:
                if (!attribute.Substrings)
                {
                    return MatchState.Unknown;
                }
                return Any(attribute, presence, values, v => SubstringMatch(v, filter));
            case LdapFilterKind.Extensible:
                return Extensible(filter, attribute, entry, presence, values, chain);
            default:
                return MatchState.Unknown;
        }
    }

    // Any value TRUE gives TRUE; otherwise any Undefined value gives Undefined; otherwise FALSE (absent attribute: FALSE).
    private static MatchState Any(LdapAttribute attribute, LdapPresence presence, IReadOnlyList<string> values, Func<string, bool?> test)
    {
        if (presence == LdapPresence.Absent || values.Count == 0)
        {
            return MatchState.NoMatch;
        }
        var unknown = false;
        foreach (var value in values)
        {
            switch (test(value))
            {
                case true:
                    return MatchState.Match;
                case null:
                    unknown = true;
                    break;
            }
        }
        _ = attribute;
        return unknown ? MatchState.Unknown : MatchState.NoMatch;
    }

    private static bool? Equal(LdapAttribute attribute, string value, LdapFilter filter)
    {
        var assertion = filter.Text;
        switch (attribute.Syntax)
        {
            case LdapSyntax.Integer:
                return BigInteger.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var a)
                    && BigInteger.TryParse(assertion.Trim(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var b) ? a == b : null;
            case LdapSyntax.Boolean:
                return assertion is "TRUE" or "FALSE" ? string.Equals(value, assertion, StringComparison.Ordinal) : null;
            case LdapSyntax.Time:
                return ParseTime(value) is DateTimeOffset tv && ParseTime(assertion) is DateTimeOffset ta ? tv == ta : null;
            case LdapSyntax.Dn:
                try
                {
                    return DistinguishedName.AreEqual(value, assertion);
                }
                catch (FormatException)
                {
                    return null;
                }
            case LdapSyntax.ObjectCategory:
                return SameCategory(value, assertion);
            case LdapSyntax.Guid:
                return AssertionGuid(filter) is Guid guid ? Guid.TryParse(value, out var g) && g == guid : null;
            case LdapSyntax.Sid:
                return AssertionSid(filter) is string sid ? string.Equals(value, sid, StringComparison.OrdinalIgnoreCase) : null;
            default:
                return string.Equals(Normalize(value), Normalize(assertion), StringComparison.OrdinalIgnoreCase);
        }
    }

    private static int? Compare(LdapAttribute attribute, string value, string assertion)
    {
        switch (attribute.Syntax)
        {
            case LdapSyntax.Integer:
                return BigInteger.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var a)
                    && BigInteger.TryParse(assertion.Trim(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var b) ? a.CompareTo(b) : null;
            case LdapSyntax.Time:
                return ParseTime(value) is DateTimeOffset tv && ParseTime(assertion) is DateTimeOffset ta ? tv.CompareTo(ta) : null;
            default:
                return string.Compare(Normalize(value).ToUpperInvariant(), Normalize(assertion).ToUpperInvariant(), StringComparison.Ordinal);
        }
    }

    private static bool SubstringMatch(string value, LdapFilter filter)
    {
        var text = Normalize(value);
        var position = 0;
        if (filter.Initial is { } initial)
        {
            var start = Normalize(initial);
            if (!text.StartsWith(start, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
            position = start.Length;
        }
        foreach (var part in filter.Any)
        {
            var piece = Normalize(part);
            var found = text.IndexOf(piece, position, StringComparison.OrdinalIgnoreCase);
            if (found < 0)
            {
                return false;
            }
            position = found + piece.Length;
        }
        if (filter.Final is { } final)
        {
            var end = Normalize(final);
            return text.Length - position >= end.Length && text.EndsWith(end, StringComparison.OrdinalIgnoreCase);
        }
        return true;
    }

    private static MatchState Extensible(LdapFilter filter, LdapAttribute attribute, ILdapEntry entry, LdapPresence presence, IReadOnlyList<string> values, ILdapChain? chain)
    {
        switch (filter.MatchingRule)
        {
            case LdapSchema.BitAnd:
            case LdapSchema.BitOr:
                if (attribute.Syntax != LdapSyntax.Integer || !long.TryParse(filter.Text.Trim(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var mask))
                {
                    return MatchState.Unknown;
                }
                var and = filter.MatchingRule == LdapSchema.BitAnd;
                return Any(attribute, presence, values, v => long.TryParse(v, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) ? (and ? (n & mask) == mask : (n & mask) != 0) : null);
            case LdapSchema.InChain:
                if (attribute.Syntax != LdapSyntax.Dn || chain is null)
                {
                    return MatchState.Unknown;
                }
                try
                {
                    _ = DistinguishedName.Parse(filter.Text);
                }
                catch (FormatException)
                {
                    return MatchState.Unknown;
                }
                return chain.Reaches(entry, attribute, filter.Text) ? MatchState.Match : MatchState.NoMatch;
            case null:
                return Any(attribute, presence, values, v => Equal(attribute, v, filter));
            default:
                return MatchState.Unknown;
        }
    }

    private static string Normalize(string value)
    {
        // Directory strings compare with insignificant leading, trailing and repeated spaces.
        var builder = new StringBuilder(value.Length);
        var space = false;
        foreach (var c in value.Trim())
        {
            if (c == ' ')
            {
                space = true;
                continue;
            }
            if (space)
            {
                builder.Append(' ');
                space = false;
            }
            builder.Append(c);
        }
        return builder.ToString();
    }

    private static bool SameCategory(string value, string assertion)
    {
        if (assertion.Contains('=', StringComparison.Ordinal))
        {
            try
            {
                return DistinguishedName.AreEqual(value, assertion);
            }
            catch (FormatException)
            {
                return false;
            }
        }
        var comma = value.IndexOf(',', StringComparison.Ordinal);
        var cn = value.StartsWith("CN=", StringComparison.OrdinalIgnoreCase) && comma > 3 ? value[3..comma] : value;
        var shortName = assertion.Trim().ToUpperInvariant() switch
        {
            "COMPUTER" => "Computer",
            "USER" or "PERSON" or "CONTACT" => "Person",
            "GROUP" => "Group",
            "ORGANIZATIONALUNIT" => "Organizational-Unit",
            _ => assertion.Trim(),
        };
        return string.Equals(cn, shortName, StringComparison.OrdinalIgnoreCase);
    }

    private static Guid? AssertionGuid(LdapFilter filter)
    {
        if (!filter.Bytes.IsDefault && filter.Bytes.Length == 16)
        {
            return new Guid(filter.Bytes.AsSpan());
        }
        return Guid.TryParse(filter.Text.Trim().Trim('{', '}'), out var guid) ? guid : null;
    }

    private static string? AssertionSid(LdapFilter filter)
    {
        var text = filter.Text.Trim();
        if (text.StartsWith("S-", StringComparison.OrdinalIgnoreCase))
        {
            return text.ToUpperInvariant();
        }
        if (filter.Bytes.IsDefault)
        {
            return null;
        }
        var bytes = filter.Bytes.AsSpan();
        // Binary SID: revision 1, sub-authority count, 6-octet authority (big-endian), then little-endian 32-bit sub-authorities.
        if (bytes.Length < 8 || bytes[0] != 1 || bytes.Length != 8 + bytes[1] * 4)
        {
            return null;
        }
        long authority = 0;
        for (var i = 2; i < 8; i++)
        {
            authority = (authority << 8) | bytes[i];
        }
        var builder = new StringBuilder("S-1-").Append(authority.ToString(CultureInfo.InvariantCulture));
        for (var i = 0; i < bytes[1]; i++)
        {
            builder.Append('-').Append(BitConverter.ToUInt32(bytes.Slice(8 + i * 4, 4)).ToString(CultureInfo.InvariantCulture));
        }
        return builder.ToString();
    }

    /// <summary>Generalized time « 20261021162600.0Z » (fraction and zone optional) as UTC; null when unreadable.</summary>
    public static DateTimeOffset? ParseTime(string text)
    {
        var value = (text ?? "").Trim();
        if (value.Length < 14 || !value[..14].All(char.IsAsciiDigit))
        {
            return null;
        }
        return DateTime.TryParseExact(value[..14], "yyyyMMddHHmmss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var date)
            ? new DateTimeOffset(date, TimeSpan.Zero)
            : null;
    }

    /// <summary>Generalized time text of a date (LDAP form).</summary>
    public static string FormatTime(DateTimeOffset at) => at.UtcDateTime.ToString("yyyyMMddHHmmss", CultureInfo.InvariantCulture) + ".0Z";

    /// <summary>FILETIME of a date (large integer attributes such as lastLogonTimestamp).</summary>
    public static long FileTime(DateTimeOffset at) => at <= Epoch ? 0 : AdValues.ToFileTime(at);
}

/// <summary>
/// LDAP view of the objects of a directory snapshot (computers, users, groups): the attributes Domenia keeps, in their LDAP
/// form. An attribute of the schema that Domenia does not keep is « not read » (Undefined), never « absent ».
/// </summary>
public sealed class DirectoryLdapEntry : ILdapEntry
{
    private readonly Dictionary<string, IReadOnlyList<string>> values = new(StringComparer.OrdinalIgnoreCase);

    private DirectoryLdapEntry(string dn) => DistinguishedName = dn;

    public string DistinguishedName { get; }

    public LdapPresence Get(LdapAttribute attribute, out IReadOnlyList<string> found)
    {
        ArgumentNullException.ThrowIfNull(attribute);
        if (values.TryGetValue(attribute.Name, out var list))
        {
            found = list;
            return list.Count > 0 ? LdapPresence.Present : LdapPresence.Absent;
        }
        found = [];
        return attribute.ReadByDomenia ? LdapPresence.Absent : LdapPresence.NotRead;
    }

    private void Set(string name, string? value)
    {
        if (!string.IsNullOrEmpty(value))
        {
            values[name] = [value];
        }
    }

    private void Set(string name, long? value)
    {
        if (value is long v)
        {
            values[name] = [v.ToString(CultureInfo.InvariantCulture)];
        }
    }

    private void Set(string name, IEnumerable<string> list)
    {
        var items = list.Where(v => !string.IsNullOrEmpty(v)).ToList();
        if (items.Count > 0)
        {
            values[name] = items;
        }
    }

    private static string Category(string cn, string rootDn) => "CN=" + cn + ",CN=Schema,CN=Configuration," + rootDn;

    private static string Rdn(string dn)
    {
        try
        {
            var names = Core.DistinguishedName.Parse(dn);
            return names.Length > 0 ? names[0].Value : dn;
        }
        catch (FormatException)
        {
            return dn;
        }
    }

    private void Common(Guid guid, string sid, string dn, DateTimeOffset created, DateTimeOffset changed, long usn)
    {
        Set("distinguishedName", dn);
        Set("name", Rdn(dn));
        Set("cn", Rdn(dn));
        values["objectGUID"] = [guid.ToString("D")];
        Set("objectSid", sid);
        Set("whenCreated", LdapEvaluator.FormatTime(created));
        Set("whenChanged", LdapEvaluator.FormatTime(changed));
        Set("uSNChanged", usn);
    }

    public static DirectoryLdapEntry From(DirectoryComputer computer, DomainInfo domain)
    {
        ArgumentNullException.ThrowIfNull(computer);
        ArgumentNullException.ThrowIfNull(domain);
        var entry = new DirectoryLdapEntry(computer.DistinguishedName);
        entry.Common(computer.ObjectGuid, computer.Sid, computer.DistinguishedName, computer.WhenCreated, computer.WhenChanged, computer.UsnChanged);
        entry.Set("objectClass", ["top", "person", "organizationalPerson", "user", "computer"]);
        entry.Set("objectCategory", Category("Computer", domain.RootDn));
        entry.Set("sAMAccountName", computer.SamAccountName);
        entry.Set("dNSHostName", computer.DnsHostName);
        entry.Set("description", computer.Description);
        entry.Set("location", computer.Location);
        entry.Set("managedBy", computer.ManagedByDn);
        entry.Set("operatingSystem", computer.OperatingSystem);
        entry.Set("operatingSystemVersion", computer.OperatingSystemVersion);
        entry.Set("userAccountControl", computer.UserAccountControl);
        entry.Set("lastLogonTimestamp", computer.LastLogonTimestamp);
        entry.Set("pwdLastSet", computer.PasswordLastSet);
        entry.Set("primaryGroupID", computer.PrimaryGroupId);
        entry.Set("memberOf", computer.MemberOf);
        if (computer.Laps == LapsKind.Windows)
        {
            entry.Set("msLAPS-PasswordExpirationTime", computer.LapsExpiration);
        }
        else if (computer.Laps == LapsKind.Legacy)
        {
            entry.Set("ms-Mcs-AdmPwdExpirationTime", computer.LapsExpiration);
        }
        return entry;
    }

    public static DirectoryLdapEntry From(DirectoryUser user, DomainInfo domain)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(domain);
        var entry = new DirectoryLdapEntry(user.DistinguishedName);
        entry.Common(user.ObjectGuid, user.Sid, user.DistinguishedName, user.WhenCreated, user.WhenChanged, user.UsnChanged);
        entry.Set("cn", user.Cn);
        entry.Set("objectClass", ["top", "person", "organizationalPerson", "user"]);
        entry.Set("objectCategory", Category("Person", domain.RootDn));
        entry.Set("sAMAccountName", user.SamAccountName);
        entry.Set("userPrincipalName", user.UserPrincipalName);
        entry.Set("displayName", user.DisplayName);
        entry.Set("givenName", user.GivenName);
        entry.Set("sn", user.Surname);
        entry.Set("mail", user.Mail);
        entry.Set("title", user.Title);
        entry.Set("department", user.Department);
        entry.Set("physicalDeliveryOfficeName", user.Office);
        entry.Set("telephoneNumber", user.TelephoneNumber);
        entry.Set("manager", user.ManagerDn);
        entry.Set("description", user.Description);
        entry.Set("employeeID", user.EmployeeId);
        entry.Set("userAccountControl", user.UserAccountControl);
        entry.Set("msDS-User-Account-Control-Computed", user.ComputedAccountControl);
        entry.Set("lockoutTime", user.LockoutTime);
        entry.Set("badPwdCount", user.BadPasswordCount);
        entry.Set("pwdLastSet", user.PasswordLastSet);
        entry.Set("msDS-UserPasswordExpiryTimeComputed", user.PasswordExpiryComputed);
        entry.Set("lastLogonTimestamp", user.LastLogonTimestamp);
        entry.Set("accountExpires", user.AccountExpires);
        entry.Set("adminCount", user.AdminCount);
        entry.Set("primaryGroupID", user.PrimaryGroupId);
        entry.Set("memberOf", user.MemberOf);
        return entry;
    }

    public static DirectoryLdapEntry From(DirectoryGroup group, DomainInfo domain)
    {
        ArgumentNullException.ThrowIfNull(group);
        ArgumentNullException.ThrowIfNull(domain);
        var entry = new DirectoryLdapEntry(group.DistinguishedName);
        entry.Common(group.ObjectGuid, group.Sid, group.DistinguishedName, group.WhenCreated, group.WhenChanged, group.UsnChanged);
        entry.Set("objectClass", ["top", "group"]);
        entry.Set("objectCategory", Category("Group", domain.RootDn));
        entry.Set("sAMAccountName", group.SamAccountName);
        entry.Set("description", group.Description);
        entry.Set("mail", group.Mail);
        entry.Set("managedBy", group.ManagedByDn);
        entry.Set("adminCount", group.AdminCount);
        entry.Set("groupType", group.GroupType);
        entry.Set("member", group.Members);
        entry.Set("memberOf", group.MemberOf);
        return entry;
    }
}

/// <summary>Transitive links of a snapshot (memberOf, member, manager), for the in-chain rule. Depth bounded, cycles ignored.</summary>
public sealed class DirectoryLdapChain : ILdapChain
{
    private const int MaxDepth = 32;
    private readonly Dictionary<string, ImmutableArray<string>> memberOf = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, ImmutableArray<string>> members = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> managers = new(StringComparer.OrdinalIgnoreCase);

    public DirectoryLdapChain(DirectorySnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        foreach (var user in snapshot.Users)
        {
            memberOf[user.DistinguishedName] = user.MemberOf;
            if (user.ManagerDn is not null)
            {
                managers[user.DistinguishedName] = user.ManagerDn;
            }
        }
        foreach (var computer in snapshot.Computers)
        {
            memberOf[computer.DistinguishedName] = computer.MemberOf;
        }
        foreach (var group in snapshot.Groups)
        {
            memberOf[group.DistinguishedName] = group.MemberOf;
            members[group.DistinguishedName] = group.Members;
        }
    }

    public bool Reaches(ILdapEntry entry, LdapAttribute attribute, string target)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(attribute);
        ArgumentNullException.ThrowIfNull(target);
        IEnumerable<string> Next(string dn)
        {
            if (attribute.Name == "memberOf" && memberOf.TryGetValue(dn, out var groups))
            {
                return groups;
            }
            if (attribute.Name == "member" && members.TryGetValue(dn, out var list))
            {
                return list;
            }
            if (attribute.Name == "manager" && managers.TryGetValue(dn, out var manager))
            {
                return [manager];
            }
            return [];
        }
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { entry.DistinguishedName };
        var frontier = new List<string> { entry.DistinguishedName };
        for (var depth = 0; depth < MaxDepth && frontier.Count > 0; depth++)
        {
            var next = new List<string>();
            foreach (var dn in frontier)
            {
                foreach (var linked in Next(dn))
                {
                    if (Same(linked, target))
                    {
                        return true;
                    }
                    if (seen.Add(linked))
                    {
                        next.Add(linked);
                    }
                }
            }
            frontier = next;
        }
        return false;
    }

    private static bool Same(string left, string right)
    {
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
