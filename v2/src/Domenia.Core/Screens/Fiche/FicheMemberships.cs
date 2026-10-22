using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>One group of an object (direct or nested), as the grids of the fiche show it (Domenia 1 UI-06, FIC-023, FIC-026).</summary>
public sealed record FicheGroupRow(
    string Name,
    string Dn,
    string Type,
    string Category,
    string Ou,
    bool Privileged,
    bool Protected,
    string Membership,
    int Depth,
    string? Via,
    bool Primary);

/// <summary>Primary group of an account (primaryGroupID: never in memberOf, always shown apart).</summary>
public sealed record FichePrimaryGroup(string Name, string? Dn, int Rid, string Label);

/// <summary>Result of fiche.groups: direct groups (memberOf) and the primary group.</summary>
public sealed record FicheGroupList(
    string Dn,
    int Total,
    int Shown,
    bool Complete,
    string Label,
    string? Note,
    FichePrimaryGroup? Primary,
    int Privileged,
    ImmutableArray<FicheGroupRow> Rows);

/// <summary>One member of a group, or one child of an OU, with its type from the local index (FIC-024).</summary>
public sealed record FicheMemberRow(string Name, string Dn, string Type, string TypeLabel, string Ou, bool Disabled, string? Detail, bool Privileged);

/// <summary>Members by type, for the chips above the grid.</summary>
public sealed record FicheTypeCount(string Type, string Label, int Count);

/// <summary>Result of fiche.members: members of a group (attribute member) or children of an OU or container.</summary>
public sealed record FicheMemberList(
    string Dn,
    string Mode,
    int Total,
    int Shown,
    bool Complete,
    string Label,
    string? Note,
    ImmutableArray<FicheTypeCount> Counts,
    ImmutableArray<FicheMemberRow> Rows);

/// <summary>One group of the memberOf graph (read on demand), with what the privilege rule needs.</summary>
public sealed record FicheGraphNode(string Dn, string Name, string? Sid, int? AdminCount, int GroupType);

/// <summary>
/// memberOf edges around one object, read on demand (GroupPathRead): the object to its direct groups, then each group read to
/// its own parents, bounded (2 000 groups, 16 levels). A group not read has no entry: its parents are unknown.
/// </summary>
public sealed record FicheGroupGraph(
    string StartDn,
    ImmutableDictionary<string, ImmutableArray<string>> Edges,
    ImmutableDictionary<string, FicheGraphNode> Nodes,
    bool Truncated,
    int Unread,
    FichePrimaryGroup? Primary);

/// <summary>Result of fiche.groups.nested: the groups reached through other groups only.</summary>
public sealed record FicheNestedList(string Dn, int Direct, int Nested, bool Truncated, int Unread, string Summary, ImmutableArray<FicheGroupRow> Rows);

/// <summary>
/// Result of fiche.groups.why (« Pourquoi membre ? », FIC-027): <see cref="Basis"/> says what the answer rests on (« direct »,
/// « path », « primary », « controller » for the transitive answer of the controller, « unknown »).
/// </summary>
public sealed record FicheWhy(string Group, bool Known, bool? Member, bool NeedsRead, ImmutableArray<string> Path, string Text, string Basis = "unknown");

/// <summary>Result of a breadth-first walk (Find-DomeniaMembershipPath).</summary>
public sealed record FicheMembershipPath(bool Found, ImmutableArray<string> Path, bool Direct, bool Truncated, bool CycleSeen, int Visited);

/// <summary>One account of a comparison.</summary>
public sealed record FicheParty(string Name, string Dn, string Label, string? Sam);

/// <summary>One organisation attribute compared (Compare-DomeniaUserAccess, merged per FIC-004).</summary>
public sealed record FicheCompareOrg(string Element, string? Left, string? Right, bool Same);

/// <summary>One group of a comparison (Compare-DomeniaUserGroupAccess).</summary>
public sealed record FicheCompareRow(string Group, string Dn, string Category, string Side, string Origin, string Path, int Depth, bool Primary, bool Privileged, string? Alert);

/// <summary>Result of fiche.compare: read only, nothing is ever applied (CanApply = false in Domenia 1).</summary>
public sealed record FicheComparison(
    FicheParty Left,
    FicheParty Right,
    ImmutableArray<FicheCompareOrg> Organisation,
    ImmutableArray<FicheCompareRow> Rows,
    int LeftOnly,
    int RightOnly,
    int Common,
    int PrivilegedDifferences,
    bool Truncated,
    ImmutableArray<string> Limits,
    string Summary,
    string Note,
    string Ticket,
    DateTimeOffset ComparedAt);

/// <summary>One step of a group delta (New-DomeniaGroupDelta): add or remove, never the whole list.</summary>
public sealed record FicheGroupDeltaStep(string Action, string GroupDn, string GroupName, string MemberDn, string Label);

/// <summary>Result of fiche.groups.delta: the steps, one write plan each, and the notes about contradictions.</summary>
public sealed record FicheGroupDelta(ImmutableArray<FicheGroupDeltaStep> Steps, ImmutableArray<string> Notes, bool WritesFullList);

/// <summary>One step of a delta checked again on the controller: « verified », « failed » (re-read differs) or « toCheck » (not read).</summary>
public sealed record FicheDeltaCheckRow(string Label, string GroupDn, string GroupName, string Action, string Status, string StatusLabel);

/// <summary>
/// Postcondition of a group delta (Test-DomeniaGroupDeltaPostcondition): every step compared with the memberOf read again on the
/// controller; overall « verified », « partial » (a step failed), « toCheck » (a step could not be read) or « none » (no step).
/// </summary>
public sealed record FicheDeltaCheck(string Dn, string Overall, string OverallLabel, ImmutableArray<FicheDeltaCheckRow> Rows, DateTimeOffset ReadAt, string Text);

/// <summary>
/// Pure membership rules of the fiche (Domenia-Directory.Model.ps1): readable rows, breadth-first paths with limits and
/// cycles, nested groups, « Pourquoi membre ? », privileged groups, the comparison of two accounts and its ticket text, and
/// the group delta. A truncated walk never concludes that an object is not a member.
/// </summary>
public static partial class FicheMemberships
{
    public const int MaxRows = 2000;
    public const int MaxDepth = 16;
    public const int MaxNodes = 5000;

    [GeneratedRegex("^(Admins du domaine|Domain Admins|Administrateurs de l.entreprise|Enterprise Admins|Administrateurs du sch.ma|Schema Admins|Administrateurs|Administrators|Op.rateurs de compte|Account Operators|Op.rateurs de serveur|Server Operators|Op.rateurs de sauvegarde|Backup Operators|Propri.taires cr.ateurs de la strat.gie de groupe|Group Policy Creator Owners|DnsAdmins)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex PrivilegedName();

    [GeneratedRegex("^S-1-5-32-(544|548|549|550|551)$", RegexOptions.CultureInvariant)]
    private static partial Regex PrivilegedBuiltin();

    [GeneratedRegex("-(512|516|517|518|519|520|526|527)$", RegexOptions.CultureInvariant)]
    private static partial Regex PrivilegedRid();

    /// <summary>Privileged group (Test-DomeniaPrivilegedGroup): adminCount = 1, a well-known SID or a well-known name.</summary>
    public static bool IsPrivileged(string? name, string? sid, int? adminCount)
    {
        if (adminCount == 1)
        {
            return true;
        }
        if (!string.IsNullOrEmpty(sid) && (PrivilegedBuiltin().IsMatch(sid) || PrivilegedRid().IsMatch(sid)))
        {
            return true;
        }
        return !string.IsNullOrEmpty(name) && PrivilegedName().IsMatch(name);
    }

    /// <summary>« Groupe de sécurité global », « Groupe de distribution universel »… from groupType.</summary>
    public static string GroupTypeLabel(int groupType)
    {
        var security = (groupType & unchecked((int)0x80000000)) != 0;
        var scope = (groupType & 0x1) != 0 ? "local intégré"
            : (groupType & 0x4) != 0 ? "local de domaine"
            : (groupType & 0x8) != 0 ? "universel"
            : (groupType & 0x2) != 0 ? "global"
            : "de portée inconnue";
        return (security ? "Groupe de sécurité " : "Groupe de distribution ") + scope;
    }

    public static string Category(int groupType) => (groupType & unchecked((int)0x80000000)) != 0 ? "security" : "distribution";

    /// <summary>Name of a well-known primary group RID (513 Utilisateurs du domaine…), or « RID n ».</summary>
    public static FichePrimaryGroup? PrimaryGroup(int? rid, string? dn, string? name)
    {
        if (rid is not int value || value <= 0)
        {
            return null;
        }
        var known = value switch
        {
            512 => "Admins du domaine",
            513 => "Utilisateurs du domaine",
            514 => "Invités du domaine",
            515 => "Ordinateurs du domaine",
            516 => "Contrôleurs de domaine",
            _ => null,
        };
        var label = name ?? known ?? "RID " + value.ToString(CultureInfo.InvariantCulture);
        return new FichePrimaryGroup(label, dn, value, label + " (RID " + value.ToString(CultureInfo.InvariantCulture) + ")");
    }

    /// <summary>« 2 000 affichés sur 3 412 membres directs », with the reason of a partial read (Get-DomeniaMembershipLabel).</summary>
    public static string Label(int shown, int total, bool complete, string? note, string singular, string plural)
    {
        var text = total > shown
            ? FrenchText.Integer(shown) + " affichés sur " + FrenchText.Count(total, singular, plural)
            : FrenchText.Count(total, singular, plural);
        if (!complete)
        {
            text += " · lecture partielle" + (string.IsNullOrEmpty(note) ? ", couverture non confirmée" : FrenchText.Colon + note);
        }
        return text;
    }

    /// <summary>Direct groups of an object as rows (ConvertTo-DomeniaMembershipRows -Kind MemberOf), types from the local index.</summary>
    public static FicheGroupList Groups(FicheEntry entry, IReadOnlyDictionary<string, FicheSummary> index, FichePrimaryGroup? primary)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(index);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var rows = new List<FicheGroupRow>();
        var total = 0;
        foreach (var dn in entry.All("memberOf"))
        {
            var text = dn.Trim();
            if (text.Length == 0 || !seen.Add(text))
            {
                continue;
            }
            total++;
            if (rows.Count >= MaxRows)
            {
                continue;
            }
            index.TryGetValue(text, out var known);
            rows.Add(GroupRow(text, known, "Directe", 1, null, false));
        }
        var sorted = rows.OrderByDescending(r => r.Privileged).ThenBy(r => r.Name, StringComparer.Create(CultureInfo.GetCultureInfo("fr-FR"), true)).ToImmutableArray();
        var note = entry.First("__memberOfNote");
        var complete = !string.Equals(entry.First("__memberOfComplete"), "FALSE", StringComparison.OrdinalIgnoreCase);
        var label = Label(sorted.Length, total, complete, note, "groupe direct", "groupes directs");
        return new FicheGroupList(entry.Dn, total, sorted.Length, complete, label, complete ? null : note, primary, sorted.Count(r => r.Privileged), sorted);
    }

    private static FicheGroupRow GroupRow(string dn, FicheSummary? known, string membership, int depth, string? via, bool primary)
    {
        var name = known?.Name ?? FicheValues.DisplayName(dn);
        var type = known?.GroupType is int groupType ? GroupTypeLabel(groupType) : "Groupe";
        var category = known?.GroupType is int g ? Category(g) : "security";
        var privileged = IsPrivileged(name, known?.Sid, known?.AdminCount);
        return new FicheGroupRow(name, dn, type, category, FicheValues.ReadablePath(dn), privileged, known?.AdminCount == 1, membership, depth, via, primary);
    }

    /// <summary>
    /// Members of a group or children of an OU as rows (ConvertTo-DomeniaMembershipRows -Kind Members): the type comes from the
    /// local index only (« Non lu » otherwise, never guessed from a name), duplicates dropped, 2 000 rows kept.
    /// </summary>
    /// <param name="counted">Members counted by the read by ranges when more than the DNs given were seen (50 000 at most).</param>
    public static FicheMemberList Members(string dn, string mode, IReadOnlyList<string> dns, IReadOnlyDictionary<string, FicheSummary> index, bool complete, string? note, int? counted = null)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(dns);
        ArgumentNullException.ThrowIfNull(index);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var rows = new List<FicheMemberRow>();
        var total = 0;
        foreach (var member in dns)
        {
            var text = member.Trim();
            if (text.Length == 0 || !seen.Add(text))
            {
                continue;
            }
            total++;
            if (rows.Count >= MaxRows)
            {
                continue;
            }
            index.TryGetValue(text, out var known);
            var type = known is null ? "unknown" : KindId(known.Kind);
            var typeLabel = known is null ? "Non lu" : KindLabel(known.Kind, known.Kind == FicheKind.Group && known.GroupType is int gt ? gt : null);
            var privileged = known is not null && known.Kind == FicheKind.Group && IsPrivileged(known.Name, known.Sid, known.AdminCount);
            rows.Add(new FicheMemberRow(known?.Name ?? FicheValues.DisplayName(text), text, type, typeLabel, FicheValues.ReadablePath(text), known?.Disabled ?? false, known?.Detail, privileged || known?.AdminCount == 1));
        }
        // The read by ranges counts beyond the DNs it keeps: the total is the one counted (never less than the rows).
        total = Math.Max(total, counted ?? 0);
        var counts = rows.GroupBy(r => r.Type)
            .Select(g => new FicheTypeCount(g.Key, TypePlural(g.Key), g.Count()))
            .OrderByDescending(c => c.Count).ThenBy(c => c.Type, StringComparer.Ordinal)
            .ToImmutableArray();
        var sorted = rows.OrderBy(r => TypeOrder(r.Type)).ThenBy(r => r.Name, StringComparer.Create(CultureInfo.GetCultureInfo("fr-FR"), true)).ToImmutableArray();
        var label = mode == "children"
            ? Label(sorted.Length, total, complete, note, "objet dans cette branche", "objets dans cette branche")
            : Label(sorted.Length, total, complete, note, "membre direct", "membres directs");
        return new FicheMemberList(dn, mode, total, sorted.Length, complete, label, complete ? null : note, counts, sorted);
    }

    public static string KindId(FicheKind kind) => kind switch
    {
        FicheKind.User => "user",
        FicheKind.Computer => "computer",
        FicheKind.Group => "group",
        FicheKind.Ou => "ou",
        FicheKind.Contact => "contact",
        _ => "container",
    };

    public static string KindLabel(FicheKind kind, int? groupType = null) => kind switch
    {
        FicheKind.User => "Utilisateur",
        FicheKind.Computer => "Ordinateur",
        FicheKind.Group => groupType is int g ? GroupTypeLabel(g) : "Groupe",
        FicheKind.Ou => "Unité d’organisation",
        FicheKind.Contact => "Contact",
        _ => "Conteneur",
    };

    private static string TypePlural(string type) => type switch
    {
        "user" => "Utilisateurs",
        "computer" => "Ordinateurs",
        "group" => "Groupes",
        "ou" => "Unités d’organisation",
        "contact" => "Contacts",
        "container" => "Conteneurs",
        _ => "Non lus",
    };

    private static int TypeOrder(string type) => type switch
    {
        "ou" => 0,
        "container" => 1,
        "group" => 2,
        "user" => 3,
        "computer" => 4,
        "contact" => 5,
        _ => 6,
    };

    /// <summary>
    /// Breadth-first walk of the memberOf edges with cycle protection and explicit limits (Find-DomeniaMembershipPath):
    /// 16 levels and 5 000 nodes by default; a walk stopped at a limit is marked truncated.
    /// </summary>
    public static FicheMembershipPath FindPath(IReadOnlyDictionary<string, ImmutableArray<string>> edges, string start, string target, int maxDepth = MaxDepth, int maxNodes = MaxNodes)
    {
        ArgumentNullException.ThrowIfNull(edges);
        ArgumentNullException.ThrowIfNull(start);
        ArgumentNullException.ThrowIfNull(target);
        var comparer = StringComparer.OrdinalIgnoreCase;
        var lookup = new Dictionary<string, ImmutableArray<string>>(edges, comparer);
        var visited = new HashSet<string>(comparer) { start };
        var parent = new Dictionary<string, string>(comparer);
        var depth = new Dictionary<string, int>(comparer) { [start] = 0 };
        var queue = new Queue<string>();
        queue.Enqueue(start);
        var truncated = false;
        var cycle = false;
        while (queue.Count > 0)
        {
            var node = queue.Dequeue();
            if (comparer.Equals(node, target) && !comparer.Equals(node, start))
            {
                var path = new List<string>();
                string? cursor = node;
                while (cursor is not null)
                {
                    path.Insert(0, cursor);
                    cursor = parent.TryGetValue(cursor, out var up) ? up : null;
                }
                return new FicheMembershipPath(true, [.. path], path.Count == 2, truncated, cycle, visited.Count);
            }
            if (depth[node] >= maxDepth)
            {
                truncated = true;
                continue;
            }
            if (!lookup.TryGetValue(node, out var parents))
            {
                continue;
            }
            foreach (var next in parents)
            {
                if (string.IsNullOrEmpty(next))
                {
                    continue;
                }
                if (!visited.Add(next))
                {
                    cycle = cycle || comparer.Equals(next, start) || parent.ContainsKey(next);
                    continue;
                }
                if (visited.Count > maxNodes)
                {
                    truncated = true;
                    break;
                }
                parent[next] = node;
                depth[next] = depth[node] + 1;
                queue.Enqueue(next);
            }
            if (visited.Count > maxNodes)
            {
                break;
            }
        }
        return new FicheMembershipPath(false, [], false, truncated, cycle, visited.Count);
    }

    /// <summary>Groups reached through other groups only (depth 2 or more), with the direct group they go through (Get-DomeniaNestedMembershipRows).</summary>
    public static FicheNestedList Nested(FicheGroupGraph graph, IReadOnlyDictionary<string, FicheSummary> index)
    {
        ArgumentNullException.ThrowIfNull(graph);
        ArgumentNullException.ThrowIfNull(index);
        var comparer = StringComparer.OrdinalIgnoreCase;
        var depth = new Dictionary<string, int>(comparer) { [graph.StartDn] = 0 };
        var via = new Dictionary<string, string>(comparer);
        var queue = new Queue<string>();
        queue.Enqueue(graph.StartDn);
        var rows = new List<FicheGroupRow>();
        var direct = 0;
        while (queue.Count > 0)
        {
            var node = queue.Dequeue();
            if (depth[node] >= MaxDepth || !graph.Edges.TryGetValue(node, out var parents))
            {
                continue;
            }
            foreach (var parentDn in parents)
            {
                if (depth.ContainsKey(parentDn))
                {
                    continue;
                }
                depth[parentDn] = depth[node] + 1;
                via[parentDn] = depth[node] == 0 ? parentDn : via[node];
                queue.Enqueue(parentDn);
                if (depth[parentDn] == 1)
                {
                    direct++;
                    continue;
                }
                if (rows.Count >= MaxRows)
                {
                    continue;
                }
                var known = Known(graph, index, parentDn);
                rows.Add(GroupRow(parentDn, known, "Imbriquée", depth[parentDn], NameOf(graph, index, via[parentDn]), false));
            }
        }
        var ordered = rows.OrderBy(r => r.Depth).ThenBy(r => r.Name, StringComparer.Create(CultureInfo.GetCultureInfo("fr-FR"), true)).ToImmutableArray();
        var summary = FrenchText.Count(ordered.Length, "groupe imbriqué lu", "groupes imbriqués lus") + " en plus des " + FrenchText.Count(direct, "groupe direct", "groupes directs") + ".";
        if (graph.Truncated)
        {
            summary += " Lecture bornée (2 000 groupes, 16 niveaux)" + FrenchText.Colon + "la liste peut être incomplète.";
        }
        if (graph.Unread > 0)
        {
            summary += " " + FrenchText.Count(graph.Unread, "groupe non lu", "groupes non lus") + " (droits ou autre domaine).";
        }
        if (graph.Primary is not null)
        {
            summary += " Groupe principal (" + graph.Primary.Name + ") porté par primaryGroupID, hors de memberOf.";
        }
        return new FicheNestedList(graph.StartDn, direct, ordered.Length, graph.Truncated, graph.Unread, summary, ordered);
    }

    private static FicheSummary? Known(FicheGroupGraph graph, IReadOnlyDictionary<string, FicheSummary> index, string dn)
    {
        if (index.TryGetValue(dn, out var known))
        {
            return known;
        }
        return graph.Nodes.TryGetValue(dn, out var node)
            ? new FicheSummary(dn, node.Name, FicheKind.Group, null, null, false, Guid.Empty, node.Sid, node.GroupType, node.AdminCount)
            : null;
    }

    private static string NameOf(FicheGroupGraph graph, IReadOnlyDictionary<string, FicheSummary> index, string dn) =>
        Known(graph, index, dn)?.Name ?? FicheValues.DisplayName(dn);

    /// <summary>
    /// « Pourquoi membre ? » (Get-DomeniaMembershipWhy): a direct group needs no read; otherwise the path comes from the edges
    /// read on demand. A truncated or partial walk never concludes that the object is not a member.
    /// </summary>
    public static FicheWhy Why(string objectDn, string objectName, string groupDn, string groupName, bool direct, FicheGroupGraph? graph, bool primary, bool? transitive = null)
    {
        ArgumentNullException.ThrowIfNull(objectDn);
        ArgumentNullException.ThrowIfNull(groupDn);
        var c = FrenchText.Colon;
        var obj = FrenchText.Quote(objectName);
        var grp = FrenchText.Quote(groupName);
        if (primary)
        {
            return new FicheWhy(groupName, true, true, false, [objectName, groupName], obj + " a " + grp + " pour groupe principal" + c + "l’appartenance est portée par primaryGroupID, pas par l’attribut member.", "primary");
        }
        if (direct)
        {
            return new FicheWhy(groupName, true, true, false, [objectName, groupName], obj + " est membre direct de " + grp + c + "l’attribut member du groupe le nomme.", "direct");
        }
        if (graph is null)
        {
            return new FicheWhy(groupName, false, null, true, [], "Lecture des groupes imbriqués nécessaire pour expliquer l’appartenance à " + grp + ".");
        }
        var found = FindPath(graph.Edges, objectDn, groupDn);
        if (found.Found)
        {
            var names = found.Path.Select(dn => FicheValues.SameDn(dn, objectDn) ? objectName : graph.Nodes.TryGetValue(dn, out var n) ? n.Name : FicheValues.DisplayName(dn)).ToImmutableArray();
            var levels = names.Length - 1;
            return new FicheWhy(groupName, true, true, false, names,
                obj + " est membre de " + grp + " par imbrication" + c + string.Join(" → ", names) + " (" + FrenchText.Count(levels, "niveau", "niveaux") + ").", "path");
        }
        // No path in the groups read: the transitive answer of the controller (memberOf:1.2.840.113556.1.4.1941) decides when it came.
        const string chain = " (règle de chaînage 1.2.840.113556.1.4.1941)";
        if (transitive == true)
        {
            return new FicheWhy(groupName, true, true, false, [objectName, groupName],
                "Le contrôleur confirme que " + obj + " est membre de " + grp + " par imbrication" + chain + c + "le chemin passe par des groupes non lus ici (autre domaine ou lecture bornée).", "controller");
        }
        if (transitive == false && !found.Truncated && !graph.Truncated && graph.Unread == 0)
        {
            return new FicheWhy(groupName, true, false, false, [],
                "Le contrôleur confirme que " + obj + " n’est pas membre de " + grp + chain + c + "aucun chemin dans les groupes lus non plus. Le groupe principal n’est pas couvert par cette règle.", "controller");
        }
        if (found.Truncated || graph.Truncated || graph.Unread > 0)
        {
            var missing = graph.Unread > 0 ? " " + FrenchText.Count(graph.Unread, "groupe non lu", "groupes non lus") + "." : "";
            var controller = transitive == false ? " Le contrôleur répond " + FrenchText.Quote("non membre") + chain + "." : transitive is null ? " Le contrôleur n’a pas répondu à la question transitive." : "";
            return new FicheWhy(groupName, false, null, false, [], "Appartenance à " + grp + " indéterminée" + c + "la lecture des groupes imbriqués est incomplète." + missing + controller, "unknown");
        }
        return new FicheWhy(groupName, false, false, false, [], "Aucun chemin vers " + grp + " dans les groupes lus" + FrenchText.Nbsp + "; le groupe principal et les groupes d’autres domaines ne sont pas couverts.", "path");
    }

    private static readonly (string Attribute, string Label)[] Organisation =
    [
        ("department", "Service"), ("title", "Fonction"), ("company", "Société"), ("physicalDeliveryOfficeName", "Bureau"), ("manager", "Responsable"),
    ];

    /// <summary>
    /// Comparison of the group access of two users (Compare-DomeniaUserGroupAccess) and of their organisation attributes
    /// (Compare-DomeniaUserAccess, merged per FIC-004). Read only: nothing is applied.
    /// </summary>
    public static FicheComparison Compare(FicheEntry left, FicheGroupGraph leftGraph, FicheEntry right, FicheGroupGraph rightGraph, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(left);
        ArgumentNullException.ThrowIfNull(right);
        ArgumentNullException.ThrowIfNull(leftGraph);
        ArgumentNullException.ThrowIfNull(rightGraph);
        ArgumentNullException.ThrowIfNull(zone);
        var leftParty = new FicheParty(left.First("displayName") ?? left.Name, left.Dn, "A", left.First("sAMAccountName"));
        var rightParty = new FicheParty(right.First("displayName") ?? right.Name, right.Dn, "B", right.First("sAMAccountName"));
        var org = Organisation.Select(o =>
        {
            var l = left.First(o.Attribute);
            var r = right.First(o.Attribute);
            if (o.Attribute == "manager")
            {
                l = l is null ? null : FicheValues.DisplayName(l);
                r = r is null ? null : FicheValues.DisplayName(r);
            }
            return new FicheCompareOrg(o.Label, l, r, string.Equals(l ?? "", r ?? "", StringComparison.Ordinal));
        }).ToImmutableArray();
        var leftMap = AccessMap(leftGraph);
        var rightMap = AccessMap(rightGraph);
        var keys = leftMap.Groups.Keys.Union(rightMap.Groups.Keys, StringComparer.OrdinalIgnoreCase).ToList();
        var rows = new List<(int Order, FicheCompareRow Row)>();
        int leftOnly = 0, rightOnly = 0, common = 0;
        foreach (var key in keys)
        {
            var inLeft = leftMap.Groups.TryGetValue(key, out var leftInfo);
            var inRight = rightMap.Groups.TryGetValue(key, out var rightInfo);
            var info = inLeft ? leftInfo! : rightInfo!;
            string category, side;
            int order;
            if (inLeft && !inRight)
            {
                category = "Seulement chez A";
                side = "left";
                order = 0;
                leftOnly++;
            }
            else if (inRight && !inLeft)
            {
                category = "Seulement chez B";
                side = "right";
                order = 1;
                rightOnly++;
            }
            else
            {
                category = "Commun";
                side = "both";
                order = 2;
                common++;
            }
            var path = "";
            if (inLeft)
            {
                path = PathText(leftMap, leftGraph.StartDn, leftParty.Name, info.Dn);
            }
            if (path.Length == 0 && inRight)
            {
                path = PathText(rightMap, rightGraph.StartDn, rightParty.Name, info.Dn);
            }
            if (path.Length == 0 && info.Primary)
            {
                path = (inLeft ? leftParty.Name : rightParty.Name) + " → " + info.Name;
            }
            var privileged = IsPrivileged(info.Name, info.Sid, info.AdminCount);
            string? alert = privileged
                ? category == "Commun" ? "Groupe à privilèges, commun aux deux comptes." : "Groupe à privilèges" + FrenchText.Colon + "vérifier l’écart avant toute attribution."
                : null;
            rows.Add((order, new FicheCompareRow(info.Name, info.Dn, category, side, info.Primary ? "Groupe principal" : "memberOf", path, info.Depth, info.Primary, privileged, alert)));
        }
        var sorted = rows.OrderBy(r => r.Order).ThenBy(r => r.Row.Primary ? 0 : 1)
            .ThenBy(r => r.Row.Group, StringComparer.Create(CultureInfo.GetCultureInfo("fr-FR"), true))
            .Select(r => r.Row).ToImmutableArray();
        var limits = new List<string>();
        if (leftMap.Truncated || rightMap.Truncated)
        {
            limits.Add("Lecture bornée (2 000 groupes, 16 niveaux ou 10 s) pour au moins un compte" + FrenchText.Colon + "la comparaison peut être incomplète.");
        }
        var unread = leftGraph.Unread + rightGraph.Unread;
        if (unread > 0)
        {
            limits.Add(FrenchText.Count(unread, "groupe non lu", "groupes non lus") + " pendant les lectures" + FrenchText.Colon + "leur contenu n’est pas comparé.");
        }
        if (leftGraph.Primary is null)
        {
            limits.Add("Groupe principal du premier compte non résolu" + FrenchText.Colon + "il peut manquer dans la comparaison.");
        }
        if (rightGraph.Primary is null)
        {
            limits.Add("Groupe principal du second compte non résolu" + FrenchText.Colon + "il peut manquer dans la comparaison.");
        }
        const string note = "Lecture seule : aucune différence n’est appliquée. Le groupe principal est inclus ; les groupes d’autres domaines non lus ne le sont pas.";
        var summary = FrenchText.Count(leftOnly, "groupe", "groupes") + " seulement chez A, " + FrenchText.Integer(rightOnly) + " seulement chez B, " + FrenchText.Count(common, "commun", "communs") + ".";
        if (limits.Count > 0)
        {
            summary += " " + string.Join(" ", limits);
        }
        var privilegedDifferences = sorted.Count(r => r.Privileged && r.Side != "both");
        var comparison = new FicheComparison(leftParty, rightParty, org, sorted, leftOnly, rightOnly, common, privilegedDifferences,
            leftMap.Truncated || rightMap.Truncated, [.. limits], summary, note, "", now);
        return comparison with { Ticket = Ticket(comparison, FicheValues.LocalDateTime(now, zone)) };
    }

    private sealed record AccessInfo(string Dn, string Name, string? Sid, int? AdminCount, int Depth, bool Primary);

    private sealed record AccessMapResult(Dictionary<string, AccessInfo> Groups, Dictionary<string, ImmutableArray<string>> Edges, bool Truncated);

    /// <summary>Groups of one account, direct or nested, primary group included as a direct edge (Get-DomeniaUserGroupAccessMap).</summary>
    private static AccessMapResult AccessMap(FicheGroupGraph graph)
    {
        var comparer = StringComparer.OrdinalIgnoreCase;
        var edges = new Dictionary<string, ImmutableArray<string>>(graph.Edges, comparer);
        var primaryDn = graph.Primary?.Dn;
        if (!string.IsNullOrEmpty(primaryDn))
        {
            var start = edges.TryGetValue(graph.StartDn, out var known) ? known : [];
            if (!start.Contains(primaryDn, comparer))
            {
                edges[graph.StartDn] = start.Add(primaryDn);
            }
        }
        var groups = new Dictionary<string, AccessInfo>(comparer);
        var visited = new HashSet<string>(comparer) { graph.StartDn };
        var parentOf = new Dictionary<string, string>(comparer);
        var queue = new Queue<(string Dn, int Depth)>();
        queue.Enqueue((graph.StartDn, 0));
        var bounded = false;
        while (queue.Count > 0)
        {
            var (current, currentDepth) = queue.Dequeue();
            if (!edges.TryGetValue(current, out var parents))
            {
                continue;
            }
            foreach (var parent in parents)
            {
                if (string.IsNullOrEmpty(parent))
                {
                    continue;
                }
                // A parent already on the chain back to the user closes a loop: counted, never walked.
                string? cursor = current;
                var loop = false;
                var guard = 0;
                while (cursor is not null && guard <= MaxDepth)
                {
                    if (comparer.Equals(cursor, parent))
                    {
                        loop = true;
                        break;
                    }
                    cursor = parentOf.TryGetValue(cursor, out var up) ? up : null;
                    guard++;
                }
                if (loop)
                {
                    continue;
                }
                var nextDepth = currentDepth + 1;
                if (nextDepth > MaxDepth)
                {
                    bounded = true;
                    continue;
                }
                if (visited.Contains(parent))
                {
                    continue;
                }
                if (visited.Count - 1 >= MaxNodes)
                {
                    bounded = true;
                    continue;
                }
                visited.Add(parent);
                parentOf[parent] = current;
                graph.Nodes.TryGetValue(parent, out var node);
                var isPrimary = !string.IsNullOrEmpty(primaryDn) && comparer.Equals(parent, primaryDn);
                var name = node?.Name ?? (isPrimary ? graph.Primary!.Name : FicheValues.DisplayName(parent));
                groups[parent] = new AccessInfo(parent, name, node?.Sid, node?.AdminCount, nextDepth, isPrimary);
                queue.Enqueue((parent, nextDepth));
            }
        }
        return new AccessMapResult(groups, edges, graph.Truncated || bounded);
    }

    private static string PathText(AccessMapResult map, string startDn, string startName, string target)
    {
        var found = FindPath(map.Edges, startDn, target);
        if (!found.Found)
        {
            return "";
        }
        return string.Join(" → ", found.Path.Select(dn => FicheValues.SameDn(dn, startDn) ? startName : map.Groups.TryGetValue(dn, out var info) ? info.Name : FicheValues.DisplayName(dn)));
    }

    /// <summary>Plain text for a ticket (Format-DomeniaUserAccessDiffTicket): only what was read, no secret.</summary>
    public static string Ticket(FicheComparison comparison, string when)
    {
        ArgumentNullException.ThrowIfNull(comparison);
        var c = FrenchText.Colon;
        var builder = new StringBuilder();
        builder.Append("Comparaison des droits AD (lecture seule)").Append("\r\n");
        builder.Append("Premier utilisateur (A)").Append(c).Append(comparison.Left.Dn).Append("\r\n");
        builder.Append("Second utilisateur (B)").Append(c).Append(comparison.Right.Dn).Append("\r\n");
        if (!string.IsNullOrEmpty(when))
        {
            builder.Append("Comparaison").Append(c).Append(when).Append("\r\n");
        }
        builder.Append("\r\n");
        foreach (var org in comparison.Organisation.Where(o => !o.Same))
        {
            builder.Append("Organisation · ").Append(org.Element).Append(c).Append(org.Left ?? "—").Append(" / ").Append(org.Right ?? "—").Append("\r\n");
        }
        foreach (var category in new[] { "Seulement chez A", "Seulement chez B", "Commun" })
        {
            var rows = comparison.Rows.Where(r => r.Category == category).OrderBy(r => r.Group, StringComparer.Create(CultureInfo.GetCultureInfo("fr-FR"), true)).ToList();
            builder.Append(category).Append(c).Append(FrenchText.Integer(rows.Count)).Append("\r\n");
            foreach (var row in rows)
            {
                builder.Append("- ").Append(row.Group);
                if (row.Primary)
                {
                    builder.Append(" (groupe principal)");
                }
                builder.Append(" [").Append(row.Dn).Append(']');
                if (row.Path.Length > 0)
                {
                    builder.Append(" — chemin").Append(c).Append(row.Path);
                }
                if (row.Privileged)
                {
                    builder.Append(" — groupe à privilèges");
                }
                builder.Append("\r\n");
            }
        }
        builder.Append("\r\n");
        foreach (var limit in comparison.Limits)
        {
            builder.Append("Limite").Append(c).Append(limit).Append("\r\n");
        }
        builder.Append(comparison.Note);
        return builder.ToString();
    }

    /// <summary>
    /// Group delta (New-DomeniaGroupDelta): only the chosen additions and removals, contradictions ignored, « already member » and
    /// « not a member » noted (each is checked again on the controller by its own plan). The full list is never written back.
    /// </summary>
    public static FicheGroupDelta Delta(IReadOnlyCollection<string> current, IReadOnlyCollection<string> add, IReadOnlyCollection<string> remove, string memberDn)
    {
        ArgumentNullException.ThrowIfNull(current);
        ArgumentNullException.ThrowIfNull(add);
        ArgumentNullException.ThrowIfNull(remove);
        ArgumentNullException.ThrowIfNull(memberDn);
        var comparer = StringComparer.OrdinalIgnoreCase;
        var currentSet = new HashSet<string>(current.Where(g => !string.IsNullOrWhiteSpace(g)), comparer);
        var removeSet = new HashSet<string>(remove.Where(g => !string.IsNullOrWhiteSpace(g)), comparer);
        var addSet = new HashSet<string>(add.Where(g => !string.IsNullOrWhiteSpace(g)), comparer);
        var steps = new List<FicheGroupDeltaStep>();
        var notes = new List<string>();
        var seen = new HashSet<string>(comparer);
        var c = FrenchText.Colon;
        foreach (var group in add)
        {
            if (string.IsNullOrWhiteSpace(group) || !seen.Add("+" + group))
            {
                continue;
            }
            var name = FicheValues.DisplayName(group);
            if (removeSet.Contains(group))
            {
                notes.Add(name + c + "demande d’ajout et de retrait à la fois, ignorée.");
                continue;
            }
            if (currentSet.Contains(group))
            {
                notes.Add(name + c + "déjà membre d’après la dernière lecture ; l’ajout sera revérifié sur le contrôleur.");
            }
            steps.Add(new FicheGroupDeltaStep("add", group, name, memberDn, "Ajouter à " + name));
        }
        foreach (var group in remove)
        {
            if (string.IsNullOrWhiteSpace(group) || !seen.Add("-" + group) || addSet.Contains(group))
            {
                continue;
            }
            var name = FicheValues.DisplayName(group);
            if (!currentSet.Contains(group))
            {
                notes.Add(name + c + "non membre d’après la dernière lecture ; le retrait sera revérifié sur le contrôleur.");
            }
            steps.Add(new FicheGroupDeltaStep("remove", group, name, memberDn, "Retirer de " + name));
        }
        return new FicheGroupDelta([.. steps], [.. notes], false);
    }

    /// <summary>
    /// Postcondition of a delta (Test-DomeniaGroupDeltaPostcondition): each step compared with the memberOf read again on the
    /// controller (<paramref name="observed"/>, null when the re-read failed). A step whose group is in memberOf as expected is
    /// « verified », otherwise « failed »; without a re-read, « toCheck ». Overall: a failure makes it « partial », an unread step
    /// « toCheck », no step « none ».
    /// </summary>
    public static FicheDeltaCheck DeltaPostcondition(string dn, IReadOnlyList<FicheGroupDeltaStep> steps, IReadOnlyCollection<string>? observed, DateTimeOffset readAt)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(steps);
        var groups = observed is null ? null : new HashSet<string>(observed, StringComparer.OrdinalIgnoreCase);
        var rows = new List<FicheDeltaCheckRow>();
        foreach (var step in steps)
        {
            var expected = step.Action == "add";
            string status;
            if (groups is null)
            {
                status = "toCheck";
            }
            else
            {
                var member = groups.Contains(step.GroupDn) || groups.Any(g => FicheValues.SameDn(g, step.GroupDn));
                status = member == expected ? "verified" : "failed";
            }
            rows.Add(new FicheDeltaCheckRow(step.Label, step.GroupDn, step.GroupName, step.Action, status, status switch
            {
                "verified" => "Vérifié",
                "failed" => "Échec",
                _ => "À vérifier",
            }));
        }
        var overall = rows.Count == 0 ? "none" : rows.Any(r => r.Status == "failed") ? "partial" : rows.Any(r => r.Status == "toCheck") ? "toCheck" : "verified";
        var label = overall switch { "none" => "Aucun changement", "partial" => "Partiel", "toCheck" => "À vérifier", _ => "Vérifié" };
        var verified = rows.Count(r => r.Status == "verified");
        var text = overall switch
        {
            "none" => "Aucune étape à vérifier.",
            "verified" => FrenchText.Count(verified, "étape vérifiée", "étapes vérifiées") + " sur le contrôleur" + FrenchText.Colon + "les appartenances relues sont celles attendues.",
            "partial" => FrenchText.Count(rows.Count(r => r.Status == "failed"), "étape en échec", "étapes en échec") + " à la relecture" + FrenchText.Colon + "rien n’est rejoué, préparez un nouveau plan pour ces groupes.",
            _ => "Relecture des appartenances non aboutie" + FrenchText.Colon + "relisez la fiche pour vérifier.",
        };
        return new FicheDeltaCheck(dn, overall, label, [.. rows], readAt, text);
    }
}
