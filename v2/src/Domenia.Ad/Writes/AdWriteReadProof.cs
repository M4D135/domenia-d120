using System.Collections.Immutable;
using System.Security.AccessControl;
using Domenia.Core;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Ad;

/// <summary>Conservative proof for absent fields. LDAP search/filter alone hides denied properties (MS-ADTS 3.1.1.4.3).
/// Only unconditional general READ_PROPERTY for an authenticated reader, without any possibly applicable deny,
/// and a freshly read non-confidential schema flag qualify absence. Specialized ACLs remain unknown.</summary>
internal static class AdWriteReadProof
{
    internal static readonly string[] Protection = ["adminCount", "isCriticalSystemObject"];
    internal static async Task<ImmutableArray<string>> KnownAsync(AdDirectorySource source, AdEntry entry,
        IEnumerable<string> candidates, CancellationToken token)
    {
        var epoch = source.Epoch; var connection = source.Connection;
        var known = entry.AttributeNames.Where(a => entry.Raw(a).Count > 0).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var missing = candidates.Where(a => FicheAttributeRules.IsValidName(a) && !FicheAttributeRules.IsSensitive(a) && !known.Contains(a))
            .Distinct(StringComparer.OrdinalIgnoreCase).Take(129).ToArray();
        if (missing.Length == 0 || missing.Length > 128 || !AllowsGeneralRead(entry)) return [.. known];
        var root = await connection.RootDseAsync(token).ConfigureAwait(false);
        if (!AdSchemaReader.ValidContext(root.SchemaNamingContext)) return [.. known];
        var filter = "(&(objectClass=attributeSchema)(|" + string.Concat(missing.Select(a => "(lDAPDisplayName=" + LdapFilterText.Escape(a) + ")")) + "))";
        var request = new AdSearchRequest(root.SchemaNamingContext, filter, AdSearchScope.Subtree,
            ["lDAPDisplayName", "searchFlags", "objectGUID", "uSNChanged"])
        { SizeLimit = missing.Length + 1, PageSize = Math.Min(missing.Length + 1, 129), Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10) };
        var rows = await connection.SearchAsync(request, token).ConfigureAwait(false);
        if (rows.Count > missing.Length) return [.. known];
        var qualified = new Dictionary<string, AdEntry>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in missing)
        {
            var matches = rows.Where(r => string.Equals(r.String("lDAPDisplayName"), name, StringComparison.OrdinalIgnoreCase)).ToArray();
            // No default zero: an omitted/masked/malformed schema flag supplies no proof either.
            if (matches.Length == 1 && matches[0].Raw("lDAPDisplayName").Count == 1
                && FicheValues.SameDn(DistinguishedName.Parent(matches[0].DistinguishedName), root.SchemaNamingContext)
                && matches[0].Raw("searchFlags").Count == 1 && matches[0].Int("searchFlags") is { } flags
                && matches[0].Guid("objectGUID") is { } schemaId && schemaId != Guid.Empty && matches[0].Long("uSNChanged") is > 0
                && flags >= 0 && (flags & 0x280) == 0) qualified.Add(name, matches[0]);
        }
        if (qualified.Count == 0 || entry.Guid("objectGUID") is not { } id || entry.Long("uSNChanged") is not > 0) return [.. known];
        // Flags can change without changing the target's USN. Read the target inside two equal schema-version reads.
        // A newly unmasked value is then seen, never mislabeled as an old empty value.
        var target = await connection.SearchAsync(new(entry.DistinguishedName, "(objectClass=*)", AdSearchScope.Base,
            [.. qualified.Keys.Select(n => n.Equals("member", StringComparison.OrdinalIgnoreCase) ? "member;range=0-0" : n), "objectGUID", "uSNChanged", "nTSecurityDescriptor"])
        { SizeLimit = 2, PageSize = 1, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10), ExpandRanges = false, ReadOwnerAndDacl = true }, token).ConfigureAwait(false);
        if (target.Count != 1 || target[0].Guid("objectGUID") != id || target[0].Long("uSNChanged") != entry.Long("uSNChanged")
            || !FicheValues.SameDn(target[0].DistinguishedName, entry.DistinguishedName) || !AllowsGeneralRead(target[0])
            || entry.Bytes("nTSecurityDescriptor") is not { } oldAcl || target[0].Bytes("nTSecurityDescriptor") is not { } newAcl || !oldAcl.AsSpan().SequenceEqual(newAcl)) return [.. known];
        var after = await connection.SearchAsync(request, token).ConfigureAwait(false);
        if (after.Count != rows.Count || epoch != source.Epoch || !ReferenceEquals(connection, source.Connection)) return [.. known];
        foreach (var (name, schema) in qualified)
        {
            var confirmations = after.Where(r => string.Equals(r.String("lDAPDisplayName"), name, StringComparison.OrdinalIgnoreCase)).ToArray();
            if (confirmations.Length != 1 || confirmations[0].Raw("lDAPDisplayName").Count != 1 || confirmations[0].Raw("searchFlags").Count != 1
                || confirmations[0].Guid("objectGUID") != schema.Guid("objectGUID") || confirmations[0].Long("uSNChanged") != schema.Long("uSNChanged")
                || confirmations[0].Int("searchFlags") != schema.Int("searchFlags") || !FicheValues.SameDn(confirmations[0].DistinguishedName, schema.DistinguishedName)) continue;
            if (!target[0].AttributeNames.Any(a => (a.Equals(name, StringComparison.OrdinalIgnoreCase)
                || AdAttributeRange.TryParse(a, out var range) && range!.Attribute.Equals(name, StringComparison.OrdinalIgnoreCase)) && target[0].Raw(a).Count > 0)) known.Add(name);
        }
        return [.. known.Order(StringComparer.OrdinalIgnoreCase)];
    }

    internal static bool AllowsGeneralRead(AdEntry entry)
    {
        if (entry.Raw("nTSecurityDescriptor") is not { Count: 1 } raw || raw[0] is not byte[] { Length: > 0 and <= 65_536 } bytes) return false;
        try
        {
            var descriptor = new RawSecurityDescriptor(bytes, 0);
            if ((descriptor.ControlFlags & ControlFlags.DiscretionaryAclPresent) == 0) return false;
            var acl = descriptor.DiscretionaryAcl;
            if (acl is null) return true; // Explicit null DACL grants all; absence of a descriptor above never does.
            if (acl.Count > 4096) return false;
            var allowed = false;
            foreach (GenericAce ace in acl)
            {
                if ((ace.AceFlags & AceFlags.InheritOnly) != 0) continue;
                if (ace is not QualifiedAce qualified || ace is not KnownAce known) return false;
                var reads = ((uint)known.AccessMask & (0x10u | 0x80000000u | 0x10000000u)) != 0;
                if (!reads) continue;
                if (qualified.IsCallback || qualified.AceQualifier != AceQualifier.AccessAllowed) return false;
                // ObjectType restricts the property/property set; InheritedObjectType only governs inheritance.
                // An effective non-object-specific ACE has general semantics (ACCESS_ALLOWED_OBJECT_ACE).
                if (ace is ObjectAce objectAce)
                {
                    if ((objectAce.ObjectAceFlags & ~(ObjectAceFlags.ObjectAceTypePresent | ObjectAceFlags.InheritedObjectAceTypePresent)) != 0) return false;
                    if ((objectAce.ObjectAceFlags & ObjectAceFlags.ObjectAceTypePresent) != 0) continue;
                }
                if (known.SecurityIdentifier.Value is "S-1-1-0" or "S-1-5-11") allowed = true;
            }
            return allowed;
        }
        catch (Exception ex) when (ex is ArgumentException or IndexOutOfRangeException or OverflowException) { return false; }
    }

    internal static void RequireProtection(FicheEntry entry)
    {
        foreach (var name in Protection)
            if (!entry.IsKnown(name)) throw WriteErrors.Refusal(WriteErrors.TargetUnknown,
                "Protection de l’objet non qualifiée : un attribut absent peut être masqué par les droits. Aucune écriture préparée ni envoyée.");
        var admin = entry.All("adminCount"); var critical = entry.All("isCriticalSystemObject");
        if (admin.Length > 1 || admin.Length == 1 && (entry.Int32("adminCount") is not (0 or 1))
            || critical.Length > 1 || critical.Length == 1 && !string.Equals(critical[0], "TRUE", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(critical[0], "FALSE", StringComparison.OrdinalIgnoreCase))
            throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Marqueur de protection illisible ; aucune écriture préparée ni envoyée.");
    }
}
