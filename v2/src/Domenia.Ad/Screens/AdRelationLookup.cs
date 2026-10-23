using System.Runtime.CompilerServices;
using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.Ad;

/// <summary>Local identity index. Duplicate identities are excluded; a missing GUID never falls back to a name.</summary>
internal sealed class AdRelationLookup : IRelationDirectoryLookup
{
    private static readonly ConditionalWeakTable<DirectorySnapshot, AdRelationLookup> Indexes = new();
    internal static AdRelationLookup For(DirectorySnapshot directory) => Indexes.GetValue(directory, static d => new(d));
    private readonly Dictionary<Guid, RelationObject> objects;
    private readonly Dictionary<string, RelationObject[]> byDn;
    private readonly Dictionary<string, RelationObject[]> names;
    private readonly DirectorySnapshot directory;
    internal AdRelationLookup(DirectorySnapshot directory)
    {
        this.directory = directory;
        var candidates = new List<(RelationObject Object, string[] Names)>();
        foreach (var user in directory.Users)
        {
            if (!Valid(user.ObjectGuid, user.DistinguishedName) || string.IsNullOrWhiteSpace(user.SamAccountName)) { continue; }
            var detail = string.Join(" · ", new[] { user.Title, user.Department }.Where(t => !string.IsNullOrWhiteSpace(t)));
            var value = new RelationObject(RelationSubjectKind.User, user.ObjectGuid, user.DistinguishedName, user.DisplayName ?? user.Cn, user.SamAccountName,
                detail.Length == 0 ? user.Description : detail, !AdValues.IsDisabled(user.UserAccountControl), AdValues.FromFileTime(user.LastLogonTimestamp), user.WhenCreated, user.Sid, user.UserPrincipalName);
            candidates.Add((value, new[] { user.SamAccountName, user.UserPrincipalName }.OfType<string>().Where(s => s.Length > 0).ToArray()));
        }
        foreach (var computer in directory.Computers)
        {
            if (!Valid(computer.ObjectGuid, computer.DistinguishedName) || WorkstationIdentity.ExpectedName(computer) is not { } host) { continue; }
            var value = new RelationObject(RelationSubjectKind.Computer, computer.ObjectGuid, computer.DistinguishedName, host, computer.SamAccountName ?? host + "$",
                computer.OperatingSystem, !AdValues.IsDisabled(computer.UserAccountControl), AdValues.FromFileTime(computer.LastLogonTimestamp), computer.WhenCreated, computer.Sid, null);
            candidates.Add((value, new[] { host, computer.SamAccountName, computer.DnsHostName }.OfType<string>().Where(s => s.Length > 0).ToArray()));
        }
        var duplicatedDn = candidates.GroupBy(c => DnKey(c.Object.Dn), StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var unique = candidates.GroupBy(c => c.Object.Guid).Where(g => g.Count() == 1).Select(g => g.Single())
            .Where(c => !duplicatedDn.Contains(DnKey(c.Object.Dn))).ToArray();
        Rejected = directory.Users.Length + directory.Computers.Length - unique.Length;
        objects = unique.ToDictionary(c => c.Object.Guid, c => c.Object);
        byDn = unique.GroupBy(c => DnKey(c.Object.Dn), StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.Select(c => c.Object).ToArray(), StringComparer.OrdinalIgnoreCase);
        names = unique.SelectMany(c => c.Names.Distinct(StringComparer.OrdinalIgnoreCase).Select(n => (Name: n, c.Object)))
            .GroupBy(p => p.Name, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.Select(p => p.Object).Distinct().ToArray(), StringComparer.OrdinalIgnoreCase);
    }
    internal int Rejected { get; }
    internal IEnumerable<RelationObject> Users => objects.Values.Where(o => o.Kind == RelationSubjectKind.User);
    internal IEnumerable<RelationObject> Computers => objects.Values.Where(o => o.Kind == RelationSubjectKind.Computer);
    public RelationObject? User(Guid? guid, string login) => guid is { } id ? ByGuid(id, RelationSubjectKind.User) : ByName(login, RelationSubjectKind.User);
    public RelationObject? Computer(Guid? guid, string name) => guid is { } id ? ByGuid(id, RelationSubjectKind.Computer) : ByName(name, RelationSubjectKind.Computer);
    internal RelationObject? ByGuid(Guid id, RelationSubjectKind kind) => objects.GetValueOrDefault(id) is { } value && value.Kind == kind ? value : null;
    internal RelationObject? Find(string reference)
    {
        var value = reference.Trim();
        if (value.Length is 0 or > 4096 || value.Any(char.IsControl)) { return null; }
        try
        {
            if (value.Contains('=')) { return byDn.GetValueOrDefault(DnKey(value))?.SingleOrDefault(); }
        }
        catch (FormatException) { return null; }
        var matches = NameMatches(value); return matches.Length == 1 ? matches[0] : null;
    }
    private RelationObject? ByName(string reference, RelationSubjectKind kind)
    {
        var matches = NameMatches(reference).Where(o => o.Kind == kind).ToArray(); return matches.Length == 1 ? matches[0] : null;
    }
    private RelationObject[] NameMatches(string reference)
    {
        var name = reference.Trim(); var slash = name.IndexOf('\\');
        if (slash >= 0)
        {
            var authority = name[..slash];
            if (!authority.Equals(directory.Domain.NetbiosName, StringComparison.OrdinalIgnoreCase) && !authority.Equals(directory.Domain.DnsName, StringComparison.OrdinalIgnoreCase)) { return []; }
            name = name[(slash + 1)..];
        }
        return names.GetValueOrDefault(name, []);
    }
    private static string DnKey(string dn) => DistinguishedName.Format(DistinguishedName.Parse(dn));
    private bool Valid(Guid id, string dn)
    {
        try { return id != Guid.Empty && ScopeRules.Contains(new(directory.Domain.RootDn, "", true), dn); }
        catch (FormatException) { return false; }
    }
}
