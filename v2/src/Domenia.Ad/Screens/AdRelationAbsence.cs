using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Exact GUIDs, or complete legacy names, queried in batches. A refusal or incomplete batch is never an absence.</summary>
internal static class AdRelationAbsence
{
    private enum Presence { Unknown, Found, NotFound }
    private sealed record Identity(string Key, RelationSubjectKind Kind, Guid? Guid, string? Attribute, string Name, string? Filter);
    internal sealed record Result(IReadOnlyDictionary<string, string> Missing, int Uncertain);
    internal static async Task<Result> CheckAsync(AdReadAccess access, DomainInfo domain, IReadOnlyList<StoredRelation> records, CancellationToken token)
    {
        if (records.Count > 64) { throw new ArgumentOutOfRangeException(nameof(records)); }
        var pairs = records.Select(r => (Record: r, User: Identify(r.UserGuid, r.UserLogin, RelationSubjectKind.User, domain),
            Computer: Identify(r.ComputerGuid, r.Computer, RelationSubjectKind.Computer, domain))).ToArray();
        var presence = new Dictionary<string, Presence>(StringComparer.OrdinalIgnoreCase);
        foreach (var kind in new[] { RelationSubjectKind.User, RelationSubjectKind.Computer })
        {
            var ids = pairs.Select(p => kind == RelationSubjectKind.User ? p.User : p.Computer).DistinctBy(i => i.Key, StringComparer.OrdinalIgnoreCase).ToArray();
            foreach (var id in ids) { presence[id.Key] = Presence.Unknown; }
            var valid = ids.Where(i => i.Filter is not null).ToArray();
            if (valid.Length == 0) { continue; }
            var filter = "(&" + (kind == RelationSubjectKind.User ? AdDirectoryMapper.UserFilter : AdDirectoryMapper.ComputerFilter) + "(|" + string.Concat(valid.Select(i => i.Filter)) + "))";
            var rows = await access.SearchAsync(new(domain.RootDn, filter, AdSearchScope.Subtree, AdRelationDirectory.Attributes)
            { PageSize = 129, SizeLimit = 129, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(10), ExpandRanges = false }, token).ConfigureAwait(false);
            var mapped = rows.Take(129).Select(r => (Entry: r, Object: AdRelationDirectory.Map(r, domain))).ToArray();
            var complete = rows.Count < 129 && mapped.All(r => r.Object?.Kind == kind && valid.Any(i => Matches(i, r.Entry)))
                && mapped.Select(r => r.Object?.Guid).Distinct().Count() == mapped.Length
                && mapped.Select(r => DistinguishedName.Format(DistinguishedName.Parse(r.Entry.DistinguishedName))).Distinct(StringComparer.OrdinalIgnoreCase).Count() == mapped.Length;
            foreach (var id in valid)
            {
                var matches = mapped.Where(r => Matches(id, r.Entry)).ToArray();
                if (matches.Length == 1 && matches[0].Object?.Kind == kind) { presence[id.Key] = Presence.Found; }
                else if (matches.Length == 0 && complete) { presence[id.Key] = Presence.NotFound; }
            }
        }
        var missing = new Dictionary<string, string>(StringComparer.Ordinal); var uncertain = 0;
        foreach (var pair in pairs)
        {
            var user = presence[pair.User.Key]; var computer = presence[pair.Computer.Key];
            if (user == Presence.Unknown || computer == Presence.Unknown) { uncertain++; continue; }
            if (user == Presence.Found && computer == Presence.Found) { continue; }
            var reason = user == Presence.NotFound && computer == Presence.NotFound ? "Compte et poste non retrouvés" : user == Presence.NotFound ? "Compte non retrouvé" : "Poste non retrouvé";
            reason += " avec ce compte de lecture. Une invisibilité liée aux droits reste possible ; suppression non prouvée.";
            if (pair.Record.UserGuid is null || pair.Record.ComputerGuid is null) { reason += " Lien ancien vérifié par nom : renommage possible."; }
            missing.Add(RelationRules.Key(pair.Record), reason);
        }
        access.EnsureCurrent(); return new(missing, uncertain);
    }
    private static bool Matches(Identity id, AdEntry row) => id.Guid is { } guid ? row.Guid("objectGUID") == guid
        : id.Attribute is not null && string.Equals(row.String(id.Attribute), id.Name, StringComparison.OrdinalIgnoreCase);
    private static Identity Identify(Guid? guid, string name, RelationSubjectKind kind, DomainInfo domain)
    {
        var prefix = kind == RelationSubjectKind.User ? "u:" : "c:";
        if (guid is { } id) { return new(prefix + id.ToString("D"), kind, id, null, "", id == System.Guid.Empty ? null : AdObjectAccess.GuidFilter(id)); }
        var raw = name.Trim(); var key = prefix + "name:" + raw;
        Identity Invalid() => new(key, kind, null, null, raw, null);
        if (raw.Length is 0 or > 320 || raw.Any(char.IsControl)) { return Invalid(); }
        string attribute; string value;
        if (kind == RelationSubjectKind.User)
        {
            var slash = raw.IndexOf('\\');
            if (slash >= 0)
            {
                var authority = raw[..slash];
                if (!authority.Equals(domain.NetbiosName, StringComparison.OrdinalIgnoreCase) && !authority.Equals(domain.DnsName, StringComparison.OrdinalIgnoreCase)) { return Invalid(); }
                raw = raw[(slash + 1)..];
                if (raw.Length == 0 || raw.Contains('\\') || raw.Contains('@')) { return Invalid(); }
            }
            attribute = raw.Contains('@') ? "userPrincipalName" : "sAMAccountName"; value = raw;
            if (raw.EndsWith('$')) { return Invalid(); }
        }
        else
        {
            raw = raw.TrimEnd('.'); var dot = raw.IndexOf('.');
            var host = dot < 0 ? raw.EndsWith('$') ? raw[..^1] : raw : raw[..dot];
            if (host.Length is 0 or > 63 || !host.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_')
                || dot >= 0 && !raw[(dot + 1)..].Equals(domain.DnsName, StringComparison.OrdinalIgnoreCase)) { return Invalid(); }
            attribute = dot >= 0 ? "dNSHostName" : "sAMAccountName"; value = dot >= 0 ? raw : host + "$";
        }
        return new(key, kind, null, attribute, value, "(" + attribute + "=" + SearchText.LdapLiteral(value) + ")");
    }
}
