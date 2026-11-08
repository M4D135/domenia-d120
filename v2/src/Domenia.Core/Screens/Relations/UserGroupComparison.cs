using System.Collections.Immutable;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>Side of a group difference: only the first user, only the second, or both.</summary>
public enum UserGroupCategory
{
    OnlyLeft,
    OnlyRight,
    Common,
}

/// <summary>How a user holds a group: not at all, directly (memberOf), through nested groups, or as primary group.</summary>
public enum UserGroupOrigin
{
    None,
    Direct,
    Nested,
    Primary,
}

public sealed record UserComparisonSide(string Dn, string Name, string Login, string Label, string? Title, string? Department, string? Office, string? Manager, int Groups);

public sealed record UserAttributeComparison(string Attribute, string Label, string? Left, string? Right, bool Same);

public sealed record UserGroupDifference(
    string Dn,
    string Name,
    UserGroupCategory Category,
    string CategoryLabel,
    UserGroupOrigin LeftOrigin,
    UserGroupOrigin RightOrigin,
    string? Path,
    int Depth,
    bool Primary,
    bool Privileged,
    string? Alert);

public sealed record UserGroupComparisonCounts(int OnlyLeft, int OnlyRight, int Common, int Privileged, int PrivilegedDifferences, int AttributeDifferences);

/// <summary>
/// Comparison of the access of two users (Domenia 1 R40 « Droits comparés », FIC-004 to FIC-006): organisation attributes,
/// direct, nested and primary groups on both sides, path and privileges of each group, limits of the read, and the text for a
/// ticket. Read only: nothing is ever applied from one user to the other.
/// </summary>
public sealed record UserGroupComparison(
    UserComparisonSide Left,
    UserComparisonSide Right,
    ImmutableArray<UserAttributeComparison> Attributes,
    ImmutableArray<UserGroupDifference> Groups,
    UserGroupComparisonCounts Counts,
    ImmutableArray<string> Limits,
    string Summary,
    string Note,
    string Ticket,
    DateTimeOffset ReadAt);

/// <summary>
/// Pure rules of the comparison of two users (port of Compare-DomeniaUserAccess, Get-DomeniaUserGroupAccessMap,
/// Compare-DomeniaUserGroupAccess and Format-DomeniaUserAccessDiffTicket): breadth-first walk of memberOf bounded by depth
/// and count, loops counted and never walked, primary group added as a direct group, privileged groups flagged.
/// </summary>
public static partial class UserGroupComparer
{
    public const int MaxDepth = 16;
    public const int MaxGroups = 2000;

    private static string C => FrenchText.Colon;

    /// <summary>
    /// The account of the second side, resolved exactly in the copy of the directory: sAMAccountName, DOMAINE\compte (this
    /// domain only), UPN or DN. A namesake from another domain or an ambiguous text resolves to nothing, with the reason.
    /// </summary>
    public static (DirectoryUser? User, string Reason) Resolve(DirectorySnapshot directory, string text)
    {
        ArgumentNullException.ThrowIfNull(directory);
        var value = (text ?? "").Trim();
        if (value.Length < 2)
        {
            return (null, "Saisissez l’identifiant, DOMAINE\\compte, l’UPN ou le DN du second compte.");
        }
        if (value.Contains('=', StringComparison.Ordinal))
        {
            try
            {
                _ = DistinguishedName.Parse(value);
            }
            catch (FormatException)
            {
                return (null, "Nom distinctif illisible" + C + "aucun compte comparé.");
            }
            var byDn = directory.Users.FirstOrDefault(u => SameDn(u.DistinguishedName, value));
            return byDn is null ? (null, "Aucun compte utilisateur à ce DN dans la copie de l’annuaire.") : (byDn, "");
        }
        var login = value;
        var slash = value.IndexOf('\\', StringComparison.Ordinal);
        if (slash >= 0)
        {
            var authority = value[..slash];
            if (!string.Equals(authority, directory.Domain.NetbiosName, StringComparison.OrdinalIgnoreCase)
                && !string.Equals(authority, directory.Domain.DnsName, StringComparison.OrdinalIgnoreCase))
            {
                return (null, "Compte d’un autre domaine (" + authority + ")" + C + "seul le domaine de la session est comparé.");
            }
            login = value[(slash + 1)..];
        }
        if (value.Contains('@', StringComparison.Ordinal) && slash < 0)
        {
            var byUpn = directory.Users.Where(u => string.Equals(u.UserPrincipalName, value, StringComparison.OrdinalIgnoreCase)).ToList();
            if (byUpn.Count == 1)
            {
                return (byUpn[0], "");
            }
            return (null, byUpn.Count == 0 ? "Aucun compte avec cet UPN dans la copie de l’annuaire." : "Plusieurs comptes portent cet UPN" + C + "précisez le DN.");
        }
        var matches = directory.Users.Where(u => string.Equals(u.SamAccountName, login, StringComparison.OrdinalIgnoreCase)).ToList();
        return matches.Count switch
        {
            1 => (matches[0], ""),
            0 => (null, "Aucun compte " + FrenchText.Quote(login) + " dans la copie de l’annuaire."),
            _ => (null, "Identifiant ambigu" + C + "précisez le DN."),
        };
    }

    /// <summary>
    /// Compares two users read in <paramref name="directory"/>; <paramref name="readAt"/> dates the ticket text.
    /// <paramref name="companyOf"/> reads the company attribute (« Société », Domenia 1 Compare-DomeniaUserAccess) where the
    /// source holds it; without it, the company is compared as unknown on both sides.
    /// </summary>
    public static UserGroupComparison Compare(DirectoryUser left, DirectoryUser right, DirectorySnapshot directory, DateTimeOffset readAt, TimeZoneInfo zone, int maxDepth = MaxDepth, int maxGroups = MaxGroups,
        Func<DirectoryUser, string?>? companyOf = null)
    {
        ArgumentNullException.ThrowIfNull(left);
        ArgumentNullException.ThrowIfNull(right);
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(zone);
        var groupsByDn = directory.Groups.GroupBy(g => g.DistinguishedName, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        var leftMap = Map(left, directory, groupsByDn, maxDepth, maxGroups);
        var rightMap = Map(right, directory, groupsByDn, maxDepth, maxGroups);
        var leftLabel = left.SamAccountName;
        var rightLabel = string.Equals(right.SamAccountName, leftLabel, StringComparison.OrdinalIgnoreCase) ? right.SamAccountName + " (2)" : right.SamAccountName;

        var rows = new List<(int Order, UserGroupDifference Row)>();
        var keys = leftMap.Groups.Keys.Concat(rightMap.Groups.Keys).Distinct(StringComparer.OrdinalIgnoreCase);
        int onlyLeft = 0, onlyRight = 0, common = 0;
        foreach (var key in keys)
        {
            var inLeft = leftMap.Groups.TryGetValue(key, out var l);
            var inRight = rightMap.Groups.TryGetValue(key, out var r);
            var info = inLeft ? l! : r!;
            UserGroupCategory category;
            int order;
            if (inLeft && !inRight)
            {
                category = UserGroupCategory.OnlyLeft;
                order = 0;
                onlyLeft++;
            }
            else if (inRight && !inLeft)
            {
                category = UserGroupCategory.OnlyRight;
                order = 1;
                onlyRight++;
            }
            else
            {
                category = UserGroupCategory.Common;
                order = 2;
                common++;
            }
            var path = inLeft ? leftMap.PathTo(key, left) : rightMap.PathTo(key, right);
            var privileged = IsPrivileged(info.Name, info.Sid, info.AdminCount);
            string? alert = privileged
                ? category == UserGroupCategory.Common
                    ? "Groupe à privilèges, commun aux deux comptes."
                    : "Groupe à privilèges" + C + "vérifier l’écart avant toute attribution."
                : null;
            var label = category switch
            {
                UserGroupCategory.OnlyLeft => "Seulement chez " + leftLabel,
                UserGroupCategory.OnlyRight => "Seulement chez " + rightLabel,
                _ => "Commun",
            };
            rows.Add((order, new UserGroupDifference(info.Dn, info.Name, category, label,
                inLeft ? OriginOf(l!) : UserGroupOrigin.None, inRight ? OriginOf(r!) : UserGroupOrigin.None,
                path, info.Depth, (l?.Primary ?? false) || (r?.Primary ?? false), privileged, alert)));
        }
        var sorted = rows.OrderBy(x => x.Order).ThenBy(x => x.Row.Primary ? 0 : 1).ThenBy(x => x.Row.Name, StringComparer.Create(CultureInfo.InvariantCulture, CompareOptions.IgnoreCase))
            .Select(x => x.Row).ToImmutableArray();

        var attributes = ImmutableArray.Create(
            Attribute("department", "Service", left.Department, right.Department),
            Attribute("title", "Fonction", left.Title, right.Title),
            Attribute("company", "Société", companyOf?.Invoke(left), companyOf?.Invoke(right)),
            Attribute("physicalDeliveryOfficeName", "Bureau", left.Office, right.Office),
            ManagerAttribute(left.ManagerDn, right.ManagerDn, directory));

        var limits = ImmutableArray.CreateBuilder<string>();
        if (leftMap.Truncated || rightMap.Truncated)
        {
            limits.Add("Lecture bornée (" + FrenchText.Integer(maxGroups) + " groupes, " + FrenchText.Integer(maxDepth) + " niveaux) pour au moins un compte" + C + "la comparaison peut être incomplète.");
        }
        var unread = leftMap.Unread + rightMap.Unread;
        if (unread > 0)
        {
            limits.Add(FrenchText.Count(unread, "groupe non lu", "groupes non lus") + " pendant les lectures (autre domaine ou objet absent)" + C + "leur contenu n’est pas comparé.");
        }
        if (!leftMap.PrimaryKnown)
        {
            limits.Add("Groupe principal du premier compte non résolu" + C + "il peut manquer dans la comparaison.");
        }
        if (!rightMap.PrimaryKnown)
        {
            limits.Add("Groupe principal du second compte non résolu" + C + "il peut manquer dans la comparaison.");
        }
        var privilegedCount = sorted.Count(g => g.Privileged);
        var privilegedDifferences = sorted.Count(g => g.Privileged && g.Category != UserGroupCategory.Common);
        var summary = FrenchText.Count(onlyLeft, "groupe", "groupes") + " seulement chez " + leftLabel + ", " + FrenchText.Integer(onlyRight) + " seulement chez " + rightLabel
            + ", " + FrenchText.Count(common, "commun", "communs") + ".";
        if (privilegedDifferences > 0)
        {
            summary += " " + FrenchText.Count(privilegedDifferences, "écart touche un groupe à privilèges", "écarts touchent des groupes à privilèges") + ".";
        }
        if (limits.Count > 0)
        {
            summary += " " + string.Join(" ", limits);
        }
        const string note = "Lecture seule" + " : aucune différence n’est appliquée. Le groupe principal est inclus ; les groupes d’autres domaines non lus ne le sont pas.";
        var leftSide = Side(left, leftLabel, directory, leftMap.Groups.Count);
        var rightSide = Side(right, rightLabel, directory, rightMap.Groups.Count);
        var counts = new UserGroupComparisonCounts(onlyLeft, onlyRight, common, privilegedCount, privilegedDifferences, attributes.Count(a => !a.Same));
        var result = new UserGroupComparison(leftSide, rightSide, attributes, sorted, counts, limits.ToImmutable(), summary, note, "", readAt);
        return result with { Ticket = Ticket(result, zone) };
    }

    /// <summary>
    /// Text ready to paste in a ticket (Domenia 1 Format-DomeniaUserAccessDiffTicket): both DNs, date, groups by category with
    /// DN, path, primary and privileges, limits. Repeats only what was read; no secret.
    /// </summary>
    public static string Ticket(UserGroupComparison comparison, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(comparison);
        ArgumentNullException.ThrowIfNull(zone);
        var lines = new List<string>
        {
            "Comparaison des droits AD (lecture seule)",
            "Premier utilisateur (" + comparison.Left.Label + ")" + C + comparison.Left.Dn,
            "Second utilisateur (" + comparison.Right.Label + ")" + C + comparison.Right.Dn,
            "Comparaison" + C + WritePlans.LocalTime(comparison.ReadAt, zone),
            "",
        };
        foreach (var attribute in comparison.Attributes.Where(a => !a.Same))
        {
            lines.Add(attribute.Label + C + (attribute.Left ?? "—") + " / " + (attribute.Right ?? "—"));
        }
        if (comparison.Attributes.Any(a => !a.Same))
        {
            lines.Add("");
        }
        foreach (var category in new[] { UserGroupCategory.OnlyLeft, UserGroupCategory.OnlyRight, UserGroupCategory.Common })
        {
            var rows = comparison.Groups.Where(g => g.Category == category).ToList();
            var title = category switch
            {
                UserGroupCategory.OnlyLeft => "Seulement chez " + comparison.Left.Label,
                UserGroupCategory.OnlyRight => "Seulement chez " + comparison.Right.Label,
                _ => "Commun",
            };
            lines.Add(title + C + FrenchText.Integer(rows.Count));
            foreach (var row in rows.OrderBy(g => g.Name, StringComparer.OrdinalIgnoreCase))
            {
                var line = "- " + row.Name + (row.Primary ? " (groupe principal)" : "") + " [" + row.Dn + "]";
                if (!string.IsNullOrEmpty(row.Path))
                {
                    line += " — chemin" + C + row.Path;
                }
                if (row.Privileged)
                {
                    line += " — groupe à privilèges";
                }
                lines.Add(line);
            }
        }
        lines.Add("");
        foreach (var limit in comparison.Limits)
        {
            lines.Add("Limite" + C + limit);
        }
        lines.Add(comparison.Note);
        return string.Join("\r\n", lines);
    }

    /// <summary>
    /// Privileged group (Domenia 1 Test-DomeniaPrivilegedGroup): adminCount = 1, built-in administration groups, the domain
    /// and enterprise administration RIDs, or their French and English names.
    /// </summary>
    public static bool IsPrivileged(string? name, string? sid, int? adminCount)
    {
        if (adminCount == 1)
        {
            return true;
        }
        var s = sid ?? "";
        if (BuiltinPattern().IsMatch(s) || DomainRidPattern().IsMatch(s))
        {
            return true;
        }
        return PrivilegedNamePattern().IsMatch(name ?? "");
    }

    private static UserGroupOrigin OriginOf(GroupNode node) => node.Primary ? UserGroupOrigin.Primary : node.Depth <= 1 ? UserGroupOrigin.Direct : UserGroupOrigin.Nested;

    private static UserAttributeComparison Attribute(string attribute, string label, string? left, string? right)
    {
        var l = string.IsNullOrWhiteSpace(left) ? null : left.Trim();
        var r = string.IsNullOrWhiteSpace(right) ? null : right.Trim();
        return new UserAttributeComparison(attribute, label, l, r, string.Equals(l, r, StringComparison.Ordinal));
    }

    private static UserAttributeComparison ManagerAttribute(string? left, string? right, DirectorySnapshot directory)
    {
        var a = ManagerName(left, directory); var b = ManagerName(right, directory);
        var same = string.IsNullOrWhiteSpace(left) && string.IsNullOrWhiteSpace(right)
            || !string.IsNullOrWhiteSpace(left) && !string.IsNullOrWhiteSpace(right) && SameDn(left, right);
        if (!same && string.Equals(a, b, StringComparison.OrdinalIgnoreCase)) { a = left; b = right; }
        return new("manager", "Responsable", a, b, same);
    }

    private static string? ManagerName(string? managerDn, DirectorySnapshot directory)
    {
        if (string.IsNullOrWhiteSpace(managerDn))
        {
            return null;
        }
        var manager = directory.Users.FirstOrDefault(u => SameDn(u.DistinguishedName, managerDn));
        return manager?.DisplayName ?? RelationRules.FirstValue(managerDn);
    }

    private static UserComparisonSide Side(DirectoryUser user, string label, DirectorySnapshot directory, int groups) =>
        new(user.DistinguishedName, user.DisplayName ?? user.Cn, user.SamAccountName, label, user.Title, user.Department, user.Office, ManagerName(user.ManagerDn, directory), groups);

    private sealed record GroupNode(string Dn, string Name, string? Sid, int? AdminCount, int Depth, bool Primary);

    private sealed class GroupMap(Dictionary<string, GroupNode> groups, Dictionary<string, string> parentOf, bool truncated, int unread, bool primaryKnown)
    {
        public Dictionary<string, GroupNode> Groups { get; } = groups;

        public bool Truncated { get; } = truncated;

        public int Unread { get; } = unread;

        public bool PrimaryKnown { get; } = primaryKnown;

        /// <summary>« Julien Martin → GG-Informatique-Paris → DL-Partage-Informatique-M ».</summary>
        public string? PathTo(string groupDn, DirectoryUser user)
        {
            var names = new List<string>();
            var cursor = groupDn;
            var guard = 0;
            while (guard++ <= MaxDepth + 1 && Groups.TryGetValue(cursor, out var node))
            {
                names.Add(node.Name);
                if (!parentOf.TryGetValue(cursor, out var parent) || SameDn(parent, user.DistinguishedName))
                {
                    break;
                }
                cursor = parent;
            }
            if (names.Count == 0)
            {
                return null;
            }
            names.Add(user.DisplayName ?? user.Cn);
            names.Reverse();
            return string.Join(" → ", names);
        }
    }

    private static GroupMap Map(DirectoryUser user, DirectorySnapshot directory, Dictionary<string, DirectoryGroup> groupsByDn, int maxDepth, int maxGroups)
    {
        var groups = new Dictionary<string, GroupNode>(StringComparer.OrdinalIgnoreCase);
        var parentOf = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var primarySid = directory.Domain.DomainSid + "-" + user.PrimaryGroupId.ToString(CultureInfo.InvariantCulture);
        var primary = directory.Groups.FirstOrDefault(g => string.Equals(g.Sid, primarySid, StringComparison.OrdinalIgnoreCase));
        var start = user.MemberOf.ToList();
        if (primary is not null && !start.Contains(primary.DistinguishedName, StringComparer.OrdinalIgnoreCase))
        {
            start.Add(primary.DistinguishedName);
        }
        var queue = new Queue<(string Dn, int Depth, IReadOnlyList<string> Parents)>();
        queue.Enqueue((user.DistinguishedName, 0, start));
        var truncated = false;
        var unread = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        while (queue.Count > 0)
        {
            var (current, depth, parents) = queue.Dequeue();
            foreach (var parent in parents)
            {
                // A parent already on the chain back to the user closes a loop: counted, never walked.
                if (OnChain(current, parent, parentOf))
                {
                    continue;
                }
                var next = depth + 1;
                if (next > maxDepth)
                {
                    truncated = true;
                    continue;
                }
                if (groups.ContainsKey(parent))
                {
                    continue;
                }
                if (groups.Count >= maxGroups)
                {
                    truncated = true;
                    continue;
                }
                if (!groupsByDn.TryGetValue(parent, out var group))
                {
                    unread.Add(parent);
                    continue;
                }
                var isPrimary = primary is not null && depth == 0 && SameDn(parent, primary.DistinguishedName) && !user.MemberOf.Contains(parent, StringComparer.OrdinalIgnoreCase);
                groups[parent] = new GroupNode(group.DistinguishedName, group.Name, group.Sid, group.AdminCount, next, isPrimary);
                parentOf[parent] = current;
                queue.Enqueue((parent, next, group.MemberOf));
            }
        }
        return new GroupMap(groups, parentOf, truncated, unread.Count, primary is not null);
    }

    private static bool OnChain(string current, string candidate, Dictionary<string, string> parentOf)
    {
        var cursor = current;
        var guard = 0;
        while (cursor is not null && guard++ <= MaxDepth + 1)
        {
            if (SameDn(cursor, candidate))
            {
                return true;
            }
            cursor = parentOf.TryGetValue(cursor, out var up) ? up : null;
        }
        return false;
    }

    private static bool SameDn(string left, string right)
    {
        if (string.Equals(left, right, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    [GeneratedRegex(@"^S-1-5-32-(544|548|549|550|551)$", RegexOptions.CultureInvariant)]
    private static partial Regex BuiltinPattern();

    [GeneratedRegex(@"-(512|516|517|518|519|520|526|527)$", RegexOptions.CultureInvariant)]
    private static partial Regex DomainRidPattern();

    [GeneratedRegex(@"^(Admins du domaine|Domain Admins|Administrateurs de l.entreprise|Enterprise Admins|Administrateurs du sch.ma|Schema Admins|Administrateurs|Administrators|Op.rateurs de compte|Account Operators|Op.rateurs de serveur|Server Operators|Op.rateurs de sauvegarde|Backup Operators|Propri.taires cr.ateurs de la strat.gie de groupe|Group Policy Creator Owners|DnsAdmins)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex PrivilegedNamePattern();
}
