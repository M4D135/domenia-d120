using System.Collections.Immutable;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// Nested memberships, cycles and « why a member » (AUD-012, AUD-013; Domenia 1 ConvertTo-DomeniaNestedGroupView,
/// Find-DomeniaGroupCycles, Get-DomeniaGroupMembershipExplanation, Find-DomeniaMembershipPath, Test-DomeniaPrivilegedGroup).
/// A truncated read never leads to « not a member ». Pure.
/// </summary>
public static partial class AuditGroupRules
{
    public const int MaxCycles = 20;

    private static string Key(string dn) => dn.Trim().ToLowerInvariant();

    /// <summary>Privileged group: adminCount 1, built-in operators, well-known domain RIDs, or a known name.</summary>
    public static bool IsPrivileged(string? sid, string? name, int? adminCount)
    {
        if (adminCount == 1)
        {
            return true;
        }
        if (sid is not null && (BuiltinPrivilegedPattern().IsMatch(sid) || DomainPrivilegedPattern().IsMatch(sid)))
        {
            return true;
        }
        return name is not null && PrivilegedNamePattern().IsMatch(name);
    }

    /// <summary>
    /// Cycles of a membership graph (key → parent keys), iterative depth-first walk: each cycle reported once whatever its
    /// starting point, the start repeated at the end, at most <paramref name="maxCycles"/>.
    /// </summary>
    public static ImmutableArray<ImmutableArray<string>> FindCycles(IReadOnlyDictionary<string, ImmutableArray<string>> edges, int maxCycles = MaxCycles)
    {
        ArgumentNullException.ThrowIfNull(edges);
        var cycles = ImmutableArray.CreateBuilder<ImmutableArray<string>>();
        var color = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var root in edges.Keys.Order(StringComparer.Ordinal))
        {
            if (color.ContainsKey(root))
            {
                continue;
            }
            var stack = new Stack<(string Node, ImmutableArray<string> Children, int Index)>();
            var path = new List<string>();
            stack.Push((root, edges[root], 0));
            color[root] = 1;
            path.Add(root);
            while (stack.Count > 0)
            {
                var frame = stack.Pop();
                if (frame.Index < frame.Children.Length)
                {
                    var next = frame.Children[frame.Index];
                    stack.Push(frame with { Index = frame.Index + 1 });
                    var state = color.GetValueOrDefault(next);
                    if (state == 0)
                    {
                        stack.Push((next, edges.TryGetValue(next, out var children) ? children : [], 0));
                        color[next] = 1;
                        path.Add(next);
                    }
                    else if (state == 1)
                    {
                        var start = path.FindIndex(p => string.Equals(p, next, StringComparison.OrdinalIgnoreCase));
                        if (start >= 0)
                        {
                            var members = path.Skip(start).ToList();
                            var signature = string.Join('|', members.Select(m => m.ToLowerInvariant()).Order(StringComparer.Ordinal));
                            if (seen.Add(signature))
                            {
                                members.Add(next);
                                cycles.Add([.. members]);
                                if (cycles.Count >= maxCycles)
                                {
                                    return cycles.ToImmutable();
                                }
                            }
                        }
                    }
                }
                else
                {
                    color[frame.Node] = 2;
                    path.RemoveAt(path.Count - 1);
                }
            }
        }
        return cycles.ToImmutable();
    }

    /// <summary>Rows, cycles, unread groups, primary group and graph of a GroupPathRead (ConvertTo-DomeniaNestedGroupView).</summary>
    public static AuditGroups View(GroupGraphRead read)
    {
        ArgumentNullException.ThrowIfNull(read);
        var model = Model(read);
        var cycleKeys = new HashSet<string>(StringComparer.Ordinal);
        var cycleEdges = new HashSet<(string, string)>();
        foreach (var cycle in model.Cycles)
        {
            for (var i = 0; i < cycle.Length; i++)
            {
                cycleKeys.Add(cycle[i]);
                if (i + 1 < cycle.Length)
                {
                    cycleEdges.Add((cycle[i], cycle[i + 1]));
                }
            }
        }
        var rows = new List<AuditGroupRow>();
        foreach (var (key, depth) in model.Depth)
        {
            if (key == model.StartKey)
            {
                continue;
            }
            model.Info.TryGetValue(key, out var node);
            string state;
            var tone = Tone.Ok;
            if (model.Unread.TryGetValue(key, out var reason))
            {
                state = "Non lu : " + reason;
                tone = Tone.Warn;
            }
            else if (node is null)
            {
                state = "Non lu : lecture arrêtée avant ce groupe";
                tone = Tone.Warn;
            }
            else if (node.Partial)
            {
                state = "Lu partiellement : plus de 1 500 appartenances, liste incomplète";
                tone = Tone.Warn;
            }
            else
            {
                state = "Lu";
            }
            var via = model.Via.TryGetValue(key, out var parent) && parent != model.StartKey ? "Par " + model.Labels[parent] : "Appartenance directe";
            var privileged = node is not null && IsPrivileged(node.Sid, node.Name, node.AdminCount);
            rows.Add(new AuditGroupRow(model.Display[key], model.Labels[key], depth, via, PathTo(model, key), state, tone, cycleKeys.Contains(key), privileged));
        }
        var sorted = rows.OrderBy(r => r.Depth).ThenBy(r => FrenchText.Fold(r.Name), StringComparer.Ordinal).ThenBy(r => r.Dn, StringComparer.Ordinal).ToImmutableArray();
        var direct = sorted.Count(r => r.Depth == 1);
        var maxDepth = sorted.Length == 0 ? 0 : sorted.Max(r => r.Depth);
        var cycleTexts = model.Cycles.Select(c => string.Join(" → ", c.Select(k => model.Labels[k]))).ToImmutableArray();
        var unread = model.Unread.Keys.Order(StringComparer.Ordinal).Select(k => new AuditUnreadGroup(model.Display[k], model.Labels[k], model.Unread[k])).ToImmutableArray();
        var lines = new List<string>
        {
            FrenchText.Count(sorted.Length, "groupe", "groupes") + " : " + FrenchText.Count(direct, "direct", "directs") + ", "
                + FrenchText.Integer(sorted.Length - direct) + " par imbrication, profondeur maximale " + FrenchText.Integer(maxDepth) + ".",
        };
        if (cycleTexts.Length > 0)
        {
            lines.Add(FrenchText.Count(cycleTexts.Length, "cycle", "cycles") + " d’imbrication : " + string.Join(" ; ", cycleTexts) + ".");
        }
        if (unread.Length > 0)
        {
            lines.Add(FrenchText.Count(unread.Length, "groupe non lu", "groupes non lus") + " : leurs propres appartenances manquent.");
        }
        if (!read.StartComplete)
        {
            lines.Add("Appartenances directes de l’objet lues partiellement : " + read.StartNote);
        }
        if (read.Truncated)
        {
            lines.Add("Lecture bornée : " + read.TruncatedReason + " Une absence ne prouve rien.");
        }
        AuditPrimaryGroup? primary = null;
        if (read.PrimaryGroup is { } p)
        {
            var text = !string.IsNullOrEmpty(p.Name)
                ? "Groupe principal : " + p.Name + " (primaryGroupID, absent de memberOf)."
                : !string.IsNullOrEmpty(p.Sid) ? "Groupe principal : " + p.Sid + " (nom non lu)." : string.Empty;
            if (text.Length > 0)
            {
                lines.Add(text);
                primary = new AuditPrimaryGroup(p.Dn, p.Name, p.Sid, text);
            }
        }
        lines.Add("Groupes d’autres domaines et appartenances par le groupe principal des groupes non couverts.");
        return new AuditGroups(
            read.Dn,
            sorted,
            cycleTexts,
            unread,
            primary,
            read.Truncated || !read.StartComplete,
            direct,
            sorted.Length - direct,
            maxDepth,
            sorted.Count(r => r.Privileged),
            string.Join("\n", lines),
            Graph(model, sorted, cycleKeys, cycleEdges, primary),
            read.Controller,
            read.ReadAt,
            read.ElapsedMs);
    }

    /// <summary>Why the object is (or may be) a member of one group (Get-DomeniaGroupMembershipExplanation).</summary>
    public static AuditMembership Explain(GroupGraphRead read, string groupDn, bool? serverAnswer, string? serverError, bool confirmed)
    {
        ArgumentNullException.ThrowIfNull(read);
        ArgumentNullException.ThrowIfNull(groupDn);
        var model = Model(read);
        var targetKey = Key(groupDn);
        var groupName = model.Labels.TryGetValue(targetKey, out var label) ? label : AuditText.NameOf(groupDn);
        if (read.PrimaryGroup?.Dn is string primaryDn && Key(primaryDn) == targetKey)
        {
            return new AuditMembership(read.Dn, groupDn, groupName, true, true, [], "Membre par son groupe principal (primaryGroupID) : cette appartenance n’apparaît pas dans memberOf.", confirmed, null);
        }
        var local = ShortestPath(model.Edges, model.StartKey, targetKey);
        bool? member;
        bool certain;
        if (serverAnswer is bool answer)
        {
            member = answer;
            certain = true;
        }
        else if (local.Found)
        {
            member = true;
            certain = true;
        }
        else if (read.Truncated || !read.StartComplete || local.Truncated)
        {
            member = null;
            certain = false;
        }
        else
        {
            member = false;
            certain = false;
        }
        var names = local.Found ? local.Path.Select(k => model.Labels.TryGetValue(k, out var l) ? l : AuditText.NameOf(k)).ToImmutableArray() : [];
        var lines = new List<string>();
        if (names.Length > 0)
        {
            lines.Add("Chemin : " + string.Join(" → ", names) + (names.Length == 2 ? " (appartenance directe)" : string.Empty));
        }
        if (serverAnswer == true)
        {
            lines.Add("Membre : confirmé par le contrôleur (appartenance directe ou imbriquée).");
        }
        else if (serverAnswer == false)
        {
            lines.Add("Non membre selon le contrôleur pour ce compte de lecture. Le groupe principal et les groupes d’autres domaines ne sont pas couverts par ce test.");
        }
        else if (local.Found)
        {
            lines.Add("Membre : chemin trouvé dans les appartenances lues.");
        }
        else if (member is null)
        {
            lines.Add("Indéterminé : la lecture est bornée ou incomplète. Demandez la confirmation au contrôleur.");
        }
        else
        {
            lines.Add("Aucun chemin dans les appartenances lues. Le groupe principal et les groupes d’autres domaines ne sont pas couverts ; le contrôleur peut confirmer.");
        }
        if (!string.IsNullOrEmpty(serverError))
        {
            lines.Add("Confirmation du contrôleur impossible : " + serverError);
        }
        if (local.CycleSeen)
        {
            lines.Add("Un cycle d’imbrication a été rencontré sur le parcours ; il est ignoré pour le calcul.");
        }
        return new AuditMembership(read.Dn, groupDn, groupName, member, certain, names, string.Join("\n", lines), confirmed, serverError);
    }

    private sealed record GraphModel(
        string StartKey,
        Dictionary<string, string> Display,
        Dictionary<string, ImmutableArray<string>> Edges,
        Dictionary<string, GroupNodeRead> Info,
        Dictionary<string, string> Unread,
        Dictionary<string, string> Labels,
        List<(string Key, int Depth)> Depth,
        Dictionary<string, string> Via,
        ImmutableArray<ImmutableArray<string>> Cycles);

    private static GraphModel Model(GroupGraphRead read)
    {
        var startKey = Key(read.Dn);
        var display = new Dictionary<string, string>(StringComparer.Ordinal) { [startKey] = read.Dn };
        var edges = new Dictionary<string, ImmutableArray<string>>(StringComparer.Ordinal);
        ImmutableArray<string> Parents(IEnumerable<string> dns)
        {
            var list = new List<string>();
            foreach (var dn in dns.Where(d => !string.IsNullOrWhiteSpace(d)))
            {
                var key = Key(dn);
                display.TryAdd(key, dn);
                if (!list.Contains(key))
                {
                    list.Add(key);
                }
            }
            return [.. list];
        }
        edges[startKey] = Parents(read.StartParents);
        var info = new Dictionary<string, GroupNodeRead>(StringComparer.Ordinal);
        foreach (var node in read.Nodes.Where(n => !string.IsNullOrWhiteSpace(n.Dn)))
        {
            var key = Key(node.Dn);
            display[key] = node.Dn;
            edges[key] = Parents(node.Parents);
            info[key] = node;
        }
        var unread = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var item in read.Unread.Where(u => !string.IsNullOrWhiteSpace(u.Dn)))
        {
            var key = Key(item.Dn);
            display.TryAdd(key, item.Dn);
            unread.TryAdd(key, string.IsNullOrWhiteSpace(item.Reason) ? "Non lu" : item.Reason);
        }
        var labels = display.ToDictionary(p => p.Key, p => info.TryGetValue(p.Key, out var n) && !string.IsNullOrEmpty(n.Name) ? n.Name : AuditText.NameOf(p.Value), StringComparer.Ordinal);
        // Breadth-first from the object: depth and first parent give the path shown for each group.
        var depth = new List<(string, int)>();
        var depths = new Dictionary<string, int>(StringComparer.Ordinal) { [startKey] = 0 };
        var via = new Dictionary<string, string>(StringComparer.Ordinal);
        var queue = new Queue<string>();
        queue.Enqueue(startKey);
        depth.Add((startKey, 0));
        while (queue.Count > 0)
        {
            var current = queue.Dequeue();
            if (!edges.TryGetValue(current, out var parents))
            {
                continue;
            }
            foreach (var parent in parents)
            {
                if (depths.ContainsKey(parent))
                {
                    continue;
                }
                depths[parent] = depths[current] + 1;
                via[parent] = current;
                depth.Add((parent, depths[parent]));
                queue.Enqueue(parent);
            }
        }
        // The object itself takes part: an audited group inside a loop closes a cycle through it.
        var cycles = FindCycles(edges);
        return new GraphModel(startKey, display, edges, info, unread, labels, depth, via, cycles);
    }

    private static ImmutableArray<string> PathTo(GraphModel model, string key)
    {
        var path = new List<string> { model.Labels[key] };
        var cursor = key;
        var guard = 0;
        while (model.Via.TryGetValue(cursor, out var parent) && guard++ < 64)
        {
            path.Insert(0, model.Labels[parent]);
            cursor = parent;
        }
        return [.. path];
    }

    private static AuditGraph Graph(GraphModel model, ImmutableArray<AuditGroupRow> rows, HashSet<string> cycleKeys, HashSet<(string, string)> cycleEdges, AuditPrimaryGroup? primary)
    {
        var nodes = ImmutableArray.CreateBuilder<AuditGraphNode>();
        nodes.Add(new AuditGraphNode(model.StartKey, model.Labels[model.StartKey], 0, "start", false, cycleKeys.Contains(model.StartKey), false));
        var known = new HashSet<string>(StringComparer.Ordinal) { model.StartKey };
        foreach (var row in rows)
        {
            var key = Key(row.Dn);
            known.Add(key);
            nodes.Add(new AuditGraphNode(key, row.Name, row.Depth, "group", row.Privileged, row.Cycle, row.Tone != Tone.Ok));
        }
        var edges = ImmutableArray.CreateBuilder<AuditGraphEdge>();
        foreach (var (from, parents) in model.Edges.OrderBy(p => p.Key, StringComparer.Ordinal))
        {
            if (!known.Contains(from))
            {
                continue;
            }
            foreach (var to in parents.Where(known.Contains))
            {
                edges.Add(new AuditGraphEdge(from, to, cycleEdges.Contains((from, to))));
            }
        }
        if (primary?.Dn is string primaryDn && !known.Contains(Key(primaryDn)))
        {
            var key = Key(primaryDn);
            nodes.Add(new AuditGraphNode(key, primary.Name ?? AuditText.NameOf(primaryDn), 1, "primary", false, false, false));
            edges.Add(new AuditGraphEdge(model.StartKey, key, false));
        }
        return new AuditGraph(nodes.ToImmutable(), edges.ToImmutable());
    }

    private sealed record PathResult(bool Found, ImmutableArray<string> Path, bool Truncated, bool CycleSeen);

    /// <summary>Breadth-first walk with cycle protection and explicit limits (Find-DomeniaMembershipPath).</summary>
    private static PathResult ShortestPath(Dictionary<string, ImmutableArray<string>> edges, string start, string target, int maxDepth = 16, int maxNodes = 5000)
    {
        var visited = new HashSet<string>(StringComparer.Ordinal) { start };
        var parent = new Dictionary<string, string>(StringComparer.Ordinal);
        var depth = new Dictionary<string, int>(StringComparer.Ordinal) { [start] = 0 };
        var queue = new Queue<string>();
        queue.Enqueue(start);
        var truncated = false;
        var cycle = false;
        while (queue.Count > 0)
        {
            var node = queue.Dequeue();
            if (node == target && node != start)
            {
                var path = new List<string>();
                string? cursor = node;
                while (cursor is not null)
                {
                    path.Insert(0, cursor);
                    cursor = parent.TryGetValue(cursor, out var p) ? p : null;
                }
                return new PathResult(true, [.. path], truncated, cycle);
            }
            if (depth[node] >= maxDepth)
            {
                truncated = true;
                continue;
            }
            if (!edges.TryGetValue(node, out var parents))
            {
                continue;
            }
            foreach (var next in parents)
            {
                if (!visited.Add(next))
                {
                    cycle = cycle || next == start || parent.ContainsKey(next);
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
        return new PathResult(false, [], truncated, cycle);
    }

    [GeneratedRegex(@"^S-1-5-32-(544|548|549|550|551)$", RegexOptions.CultureInvariant)]
    private static partial Regex BuiltinPrivilegedPattern();

    [GeneratedRegex(@"-(512|516|517|518|519|520|526|527)$", RegexOptions.CultureInvariant)]
    private static partial Regex DomainPrivilegedPattern();

    [GeneratedRegex(@"^(Admins du domaine|Domain Admins|Administrateurs de l.entreprise|Enterprise Admins|Administrateurs du sch.ma|Schema Admins|Administrateurs|Administrators|Op.rateurs de compte|Account Operators|Op.rateurs de serveur|Server Operators|Op.rateurs de sauvegarde|Backup Operators|Propri.taires cr.ateurs de la strat.gie de groupe|Group Policy Creator Owners|DnsAdmins)$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex PrivilegedNamePattern();
}
