using System.Collections.Immutable;
using System.Globalization;
using System.Security.Principal;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Fresh exact-object reads shared by fiches, account details and write preconditions; never writes or falls back to cache.</summary>
internal sealed class AdFicheObjects(AdDirectorySource source)
{
    private static readonly string[] Identity = ["objectGUID", "objectClass", "name", "distinguishedName", "uSNChanged"];
    private static readonly string[] Computed = ["msDS-User-Account-Control-Computed", "msDS-UserPasswordExpiryTimeComputed", "msDS-ResultantPSO"];

    internal async Task<FicheRead> ReadAsync(string dn, CancellationToken token)
    {
        ValidateDn(dn);
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(10), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token, elapsed.Token);
        var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
        EnsureDomain(dn, domain.RootDn);
        var generation = source.Epoch;
        var readAt = source.Clock.GetUtcNow();
        var first = await OneAsync(dn, [.. Identity, "allowedAttributes"], true, budget.Token).ConfigureAwait(false)
            ?? throw new DomeniaOperationException(FicheErrors.Unknown, FicheErrors.UnknownMessage);
        var names = first.Strings("allowedAttributes");
        if (names.Count is 0 or > 4096 || names.Any(n => !FicheAttributeRules.IsValidName(n)))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Liste des attributs de l’objet illisible : aucune fiche incomplète publiée."); }
        var requested = names.Concat(Identity).Concat(Computed).Where(n => !FicheAttributeRules.IsSensitive(n))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (requested.Length > 4096) { throw AdAttributeRange.Incomplete(); }
        // Opening a fiche never expands every member of a large group. Explicit member reads count more on demand.
        var safe = requested.Select(n => n.Equals("member", StringComparison.OrdinalIgnoreCase) || n.Equals("memberOf", StringComparison.OrdinalIgnoreCase)
            ? n + ";range=0-1499" : n).ToArray();
        var last = await OneAsync(dn, safe, false, budget.Token).ConfigureAwait(false)
            ?? throw new DomeniaOperationException(FicheErrors.Unknown, FicheErrors.UnknownMessage);
        SameVersion(first, last);
        EnsureEpoch(generation);
        return new(Project(last), readAt, source.ControllerName, names.Count(FicheAttributeRules.IsSensitive));
    }

    internal async Task<AdEntry?> ReadExactAsync(string dn, IReadOnlyList<string> attributes, TimeSpan duration, CancellationToken token)
    {
        ValidateDn(dn);
        using var elapsed = new CancellationTokenSource(duration, source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token, elapsed.Token);
        var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
        EnsureDomain(dn, domain.RootDn);
        var generation = source.Epoch;
        var entry = await OneAsync(dn, [.. attributes.Concat(Identity).Distinct(StringComparer.OrdinalIgnoreCase)], true, budget.Token).ConfigureAwait(false);
        EnsureEpoch(generation);
        return entry;
    }

    internal async Task<DirectoryUser?> UserAsync(string dn, CancellationToken token)
    {
        var entry = await ReadExactAsync(dn, AdDirectoryMapper.UserAttributes, TimeSpan.FromSeconds(10), token).ConfigureAwait(false);
        if (entry is null) { return null; }
        var classes = entry.Strings("objectClass");
        if (!classes.Contains("user", StringComparer.OrdinalIgnoreCase) || classes.Any(c => c.Equals("computer", StringComparison.OrdinalIgnoreCase)
            || c.Equals("msDS-ManagedServiceAccount", StringComparison.OrdinalIgnoreCase) || c.Equals("msDS-GroupManagedServiceAccount", StringComparison.OrdinalIgnoreCase))) { return null; }
        // An unreadable UAC is not an enabled account; its state must not authorize an account action.
        return entry.Int("userAccountControl") is not null && entry.Guid("objectGUID") is { } id && id != Guid.Empty
            ? AdDirectoryMapper.User(entry) ?? throw AdAttributeRange.Incomplete() : throw AdAttributeRange.Incomplete();
    }

    private async Task<AdEntry?> OneAsync(string dn, IReadOnlyList<string> attributes, bool expand, CancellationToken token)
    {
        try
        {
            var connection = source.Connection;
            var binary = connection is IAdBinarySchemaProvider provider
                ? await provider.ReadBinaryAttributesAsync(token).ConfigureAwait(false) : null;
            var selectedBinary = attributes.Select(a => AdAttributeRange.TryParse(a, out var range) ? range!.Attribute : a)
                .Where(a => binary?.Contains(a) == true).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var result = await connection.SearchAsync(new(dn, "(objectClass=*)", AdSearchScope.Base, attributes)
            {
                PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10),
                ExpandRanges = expand, MaxRangeValues = expand && attributes.Contains("allowedAttributes") ? 4096 : 50_000,
                ReadOwnerAndDacl = attributes.Contains("nTSecurityDescriptor", StringComparer.OrdinalIgnoreCase),
                BinaryAttributes = selectedBinary,
            }, token).ConfigureAwait(false);
            if (result.Count > 1 || result.Any(e => !FicheValues.SameDn(e.DistinguishedName, dn) || e.Guid("objectGUID") is not { } id || id == Guid.Empty))
            { throw AdAttributeRange.Incomplete(); }
            return result.SingleOrDefault();
        }
        catch (DomeniaOperationException ex) when (ex.Code == AdErrors.NoSuchObject) { return null; }
    }

    internal static FicheEntry Project(AdEntry entry)
    {
        if (entry.Guid("objectGUID") is not { } guid || guid == Guid.Empty) { throw AdAttributeRange.Incomplete(); }
        var classes = entry.Strings("objectClass").ToHashSet(StringComparer.OrdinalIgnoreCase);
        var kind = classes.Contains("computer") ? FicheKind.Computer : classes.Contains("group") ? FicheKind.Group
            : classes.Contains("contact") ? FicheKind.Contact : classes.Contains("user") ? FicheKind.User
            : classes.Contains("organizationalUnit") ? FicheKind.Ou
            : classes.Contains("container") || classes.Contains("domainDNS") || classes.Contains("builtinDomain") ? FicheKind.Container
            : throw new DomeniaOperationException(FicheErrors.NotApplicable, "Ce type d’objet ne dispose pas d’une fiche.");
        var values = new Dictionary<string, IEnumerable<string?>>(StringComparer.OrdinalIgnoreCase);
        var bytes = 0L;
        foreach (var key in entry.AttributeNames)
        {
            var ranged = AdAttributeRange.TryParse(key, out var range);
            var attribute = ranged ? range!.Attribute : key;
            if (FicheAttributeRules.IsSensitive(attribute)) { continue; }
            if (!FicheAttributeRules.IsValidName(attribute) || values.ContainsKey(attribute)) { throw AdAttributeRange.Incomplete(); }
            var raw = entry.Raw(key);
            if (raw.Count > 50_000) { throw AdAttributeRange.Incomplete(); }
            var converted = raw.Select(v => Value(attribute, v)).ToArray();
            bytes += converted.Sum(v => (long)v.Length * sizeof(char));
            if (bytes > 4 * 1024 * 1024) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Fiche trop volumineuse : affinez la lecture des attributs."); }
            values.Add(attribute, converted);
            if (ranged)
            {
                // A non-terminal initial slice is useful but never a complete membership list.
                if (range!.Start != 0 || range.End is { } end && end + 1 != raw.Count) { throw AdAttributeRange.Incomplete(); }
                if (range.End is not null)
                {
                    var canonical = attribute.Equals("memberOf", StringComparison.OrdinalIgnoreCase) ? "memberOf"
                        : attribute.Equals("member", StringComparison.OrdinalIgnoreCase) ? "member" : null;
                    if (canonical is null) { throw AdAttributeRange.Incomplete(); }
                    values.Add("__" + canonical + "Complete", new[] { "FALSE" });
                    values.Add("__" + canonical + "Note", new[] { "Première tranche lue seulement ; la liste est incomplète." });
                }
            }
        }
        return FicheEntry.Create(kind, guid, entry.DistinguishedName, entry.String("name") ?? AdDirectoryMapper.LeafValue(entry.DistinguishedName), values);
    }

    private static string Value(string attribute, object value)
    {
        if (value is not byte[] binary) { return Convert.ToString(value, CultureInfo.InvariantCulture) ?? ""; }
        if (attribute.Equals("objectGUID", StringComparison.OrdinalIgnoreCase))
        { return binary.Length == 16 ? new Guid(binary).ToString("D") : throw AdAttributeRange.Incomplete(); }
        if (attribute.Equals("objectSid", StringComparison.OrdinalIgnoreCase) || attribute.Equals("sIDHistory", StringComparison.OrdinalIgnoreCase)
            || attribute.Equals("tokenGroups", StringComparison.OrdinalIgnoreCase))
        {
            try { return new SecurityIdentifier(binary, 0).Value; }
            catch (ArgumentException) { throw AdAttributeRange.Incomplete(); }
        }
        return Convert.ToHexString(binary);
    }

    internal static void SameVersion(AdEntry first, AdEntry last)
    {
        if (first.Guid("objectGUID") is not { } id || last.Guid("objectGUID") != id || first.Long("uSNChanged") is not { } usn
            || last.Long("uSNChanged") != usn || !FicheValues.SameDn(first.DistinguishedName, last.DistinguishedName))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Objet modifié pendant la lecture : relisez la fiche avant de préparer une action."); }
    }

    internal static void ValidateDn(string dn)
    {
        try { if (DistinguishedName.Parse(dn).IsDefaultOrEmpty) { throw new FormatException(); } }
        catch (Exception ex) when (ex is FormatException or ArgumentException)
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Nom distinctif invalide : aucune lecture lancée."); }
    }

    internal static void EnsureDomain(string dn, string root)
    {
        if (!FicheValues.SameDn(dn, root) && !ScopeRules.Contains(new(root, "", true), dn))
        { throw new DomeniaOperationException(DomeniaErrors.ScopeOutsideDomain, DomeniaErrors.ScopeOutsideDomainMessage); }
    }

    private void EnsureEpoch(long generation)
    {
        if (generation != source.Epoch) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la lecture de l’objet."); }
    }
}
