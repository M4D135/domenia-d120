using System.Security.AccessControl;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Tests;

/// <summary>Explicit readable AD fixture, used only by positive native-write doubles. Adverse tests remove/change it.</summary>
internal static class AdWriteFixtureProof
{
    internal const string SchemaDn = "CN=Schema,CN=Configuration," + Fixtures.Root;
    internal static byte[] Descriptor(string sddl = "O:SYG:SYD:(A;;RP;;;AU)")
    {
        var sd = new RawSecurityDescriptor(sddl); var bytes = new byte[sd.BinaryLength]; sd.GetBinaryForm(bytes, 0); return bytes;
    }
    internal static IReadOnlyList<AdEntry> Schema(AdSearchRequest request, int? flags = 0, long version = 1)
    {
        var names = LdapFilterText.Parse(request.Filter).Children.Single(p => p.Kind == LdapFilterKind.Or).Children.Select(n => n.Text!);
        return [.. names.Select(n => new AdEntry("CN=" + n + "," + SchemaDn, new Dictionary<string, IReadOnlyList<object>>
        { ["lDAPDisplayName"] = [n], ["searchFlags"] = flags is { } value ? [value.ToString(System.Globalization.CultureInfo.InvariantCulture)] : [],
            ["objectGUID"] = [Fixtures.IdOf("schema/" + n).ToByteArray()], ["uSNChanged"] = [version.ToString(System.Globalization.CultureInfo.InvariantCulture)] }))];
    }
}
