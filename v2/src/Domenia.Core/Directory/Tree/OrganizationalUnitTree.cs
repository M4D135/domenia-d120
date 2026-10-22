using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>
/// OU tree of a directory snapshot, pure and immutable once built: children, readable paths, object counts (sub-OUs
/// included) and accent-insensitive search. Same code for the simulated directory and, later, the local base.
/// Containers (CN=Users…) are not OUs: they are never listed, an OU below one is listed under its nearest OU (or the root).
/// </summary>
public sealed class OrganizationalUnitTree
{
    /// <summary>French order, case ignored, independent of the workstation culture.</summary>
    private static readonly StringComparer NameOrder = StringComparer.Create(CultureInfo.GetCultureInfo("fr-FR"), CompareOptions.IgnoreCase);

    private readonly Dictionary<string, Node> nodes;
    private readonly Dictionary<string, ImmutableArray<Node>> children;
    private readonly ImmutableArray<Node> byPath;
    private readonly string rootKey;

    private OrganizationalUnitTree(OuParent root, string rootKey, Dictionary<string, Node> nodes)
    {
        Root = root;
        this.rootKey = rootKey;
        this.nodes = nodes;
        children = nodes.Values
            .GroupBy(n => n.ParentKey, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.OrderBy(n => n.Name, NameOrder).ThenBy(n => n.Dn, StringComparer.Ordinal).ToImmutableArray(), StringComparer.OrdinalIgnoreCase);
        byPath = [.. nodes.Values.OrderBy(n => n.Path, NameOrder).ThenBy(n => n.Dn, StringComparer.Ordinal)];
    }

    /// <summary>The domain root: its DN, its DNS name as name and path.</summary>
    public OuParent Root { get; }

    /// <summary>Number of OUs in the tree.</summary>
    public int Count => nodes.Count;

    public static OrganizationalUnitTree Build(DirectorySnapshot snapshot, bool objectsRead = true)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var domain = snapshot.Domain;
        var rootNames = DistinguishedName.Parse(domain.RootDn);
        var rootKey = DistinguishedName.Format(rootNames);
        var root = new OuParent(domain.RootDn, domain.DnsName, domain.DnsName);
        var nodes = new Dictionary<string, Node>(StringComparer.OrdinalIgnoreCase);
        foreach (var ou in snapshot.OrganizationalUnits)
        {
            if (!TryParse(ou.DistinguishedName, out var names) || !DistinguishedName.IsWithin(names, rootNames, subtree: true))
            {
                continue;
            }
            var key = DistinguishedName.Format(names);
            var name = string.IsNullOrWhiteSpace(ou.Name) ? names[0].Value : ou.Name;
            var segments = names.Take(names.Length - rootNames.Length).Reverse().Select(n => n.Value);
            var path = domain.DnsName + FrenchText.PathSeparator + string.Join(FrenchText.PathSeparator, segments);
            nodes.TryAdd(key, new Node(ou.DistinguishedName, name, path, key, names));
        }
        // Parent: the nearest OU above, else the root (an OU below a container is still reachable).
        foreach (var node in nodes.Values)
        {
            node.ParentKey = rootKey;
            for (var i = 1; i < node.Names.Length - rootNames.Length; i++)
            {
                var ancestor = DistinguishedName.Format(node.Names[i..]);
                if (nodes.ContainsKey(ancestor))
                {
                    node.ParentKey = ancestor;
                    break;
                }
            }
        }
        foreach (var user in snapshot.Users)
        {
            CountIn(nodes, user.DistinguishedName, rootNames.Length, static n => n.Users++);
        }
        foreach (var computer in snapshot.Computers)
        {
            CountIn(nodes, computer.DistinguishedName, rootNames.Length, static n => n.Computers++);
        }
        foreach (var group in snapshot.Groups)
        {
            CountIn(nodes, group.DistinguishedName, rootNames.Length, static n => n.Groups++);
        }
        foreach (var node in nodes.Values)
        {
            node.CountsKnown = objectsRead && snapshot.CoversScope(new ScopeSelection(node.Dn, node.Name, true));
        }
        return new OrganizationalUnitTree(root, rootKey, nodes);
    }

    /// <summary>Children of an OU, or of the root when <paramref name="dn"/> is null or the root DN; null when unknown.</summary>
    public OuChildren? Children(string? dn)
    {
        string key;
        OuParent parent;
        if (dn is null || IsRoot(dn))
        {
            key = rootKey;
            parent = Root;
        }
        else if (Lookup(dn) is Node node)
        {
            key = node.Key;
            parent = new OuParent(node.Dn, node.Name, node.Path);
        }
        else
        {
            return null;
        }
        var list = children.TryGetValue(key, out var found) ? found : [];
        return new OuChildren(parent, [.. list.Select(Entry)]);
    }

    /// <summary>The OU with this DN, or null (malformed DN, root, container or unknown OU).</summary>
    public OuEntry? Find(string dn) => Lookup(dn) is Node node ? Entry(node) : null;

    /// <summary>True when <paramref name="dn"/> names the domain root (escaping and case ignored).</summary>
    public bool IsRoot(string dn) => TryParse(dn, out var names) && string.Equals(DistinguishedName.Format(names), rootKey, StringComparison.OrdinalIgnoreCase);

    /// <summary>OUs whose folded name or path contains the folded text, in path order; empty text finds nothing.</summary>
    public OuSearchResult Search(string text, int limit)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        var folded = FrenchText.Fold(text.Trim());
        if (folded.Length == 0)
        {
            return new OuSearchResult([], false);
        }
        var results = ImmutableArray.CreateBuilder<OuEntry>(Math.Min(limit, 16));
        var truncated = false;
        foreach (var node in byPath)
        {
            if (!node.FoldedName.Contains(folded, StringComparison.Ordinal) && !node.FoldedPath.Contains(folded, StringComparison.Ordinal))
            {
                continue;
            }
            if (results.Count == limit)
            {
                truncated = true;
                break;
            }
            results.Add(Entry(node));
        }
        return new OuSearchResult(results.ToImmutable(), truncated);
    }

    private Node? Lookup(string dn) =>
        TryParse(dn, out var names) && nodes.TryGetValue(DistinguishedName.Format(names), out var node) ? node : null;

    private OuEntry Entry(Node node) =>
        new(node.Dn, node.Name, node.Path, children.ContainsKey(node.Key), new OuCounts(node.CountsKnown ? node.Users : null, node.CountsKnown ? node.Computers : null, node.CountsKnown ? node.Groups : null));

    private static void CountIn(Dictionary<string, Node> nodes, string dn, int rootLength, Action<Node> add)
    {
        if (!TryParse(dn, out var names))
        {
            return;
        }
        for (var i = 1; i < names.Length - rootLength; i++)
        {
            if (nodes.TryGetValue(DistinguishedName.Format(names[i..]), out var node))
            {
                add(node);
            }
        }
    }

    private static bool TryParse(string? dn, out ImmutableArray<RelativeName> names)
    {
        names = [];
        if (string.IsNullOrEmpty(dn))
        {
            return false;
        }
        try
        {
            names = DistinguishedName.Parse(dn);
            return names.Length > 0;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private sealed class Node(string dn, string name, string path, string key, ImmutableArray<RelativeName> names)
    {
        public string Dn { get; } = dn;
        public string Name { get; } = name;
        public string Path { get; } = path;
        public string Key { get; } = key;
        public ImmutableArray<RelativeName> Names { get; } = names;
        public string FoldedName { get; } = FrenchText.Fold(name);
        public string FoldedPath { get; } = FrenchText.Fold(path);
        public string ParentKey { get; set; } = "";
        public bool CountsKnown { get; set; }
        public int Users { get; set; }
        public int Computers { get; set; }
        public int Groups { get; set; }
    }
}
