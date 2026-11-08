using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>Immutable object-and-reader context shared by selected-object pages. This is provenance, never an authorization token.</summary>
public sealed record SelectionIdentity(string Domain, Guid ObjectGuid, string? Sid, string Kind, string Dn, string Name,
    string? Login, string Reader, long Epoch, long Generation, string? StoreId)
{
    public static SelectionIdentity? Capture(SessionSnapshot session, Guid guid, string? kind, string dn, string name,
        string? login, string? sid, long generation = 0)
    {
        if (guid == Guid.Empty || kind is not ("user" or "computer" or "group" or "ou" or "container" or "contact")
            || string.IsNullOrWhiteSpace(name) || name.Length > 1024 || dn.Length > 4096 || (sid?.Length ?? 0) > 256
            || (login?.Length ?? 0) > 320 || generation < 0) return null;
        try
        {
            var canonical = DistinguishedName.Format(DistinguishedName.Parse(dn)).ToUpperInvariant();
            var root = session.Domain?.RootDn;
            if (string.IsNullOrWhiteSpace(root) || !(DistinguishedName.AreEqual(dn, root) || DistinguishedName.IsWithin(dn, root, true))) return null;
            return new(DistinguishedName.Format(DistinguishedName.Parse(root)).ToUpperInvariant(), guid, sid?.ToUpperInvariant(), kind,
                canonical, name, login, ReaderKey(session), session.Epoch, generation, session.StoreId);
        }
        catch (FormatException) { return null; }
    }
    public bool SameContext(SelectionIdentity? other) => other is not null && Domain == other.Domain && ObjectGuid == other.ObjectGuid
        && Sid == other.Sid && Kind == other.Kind && Dn == other.Dn && string.Equals(Name, other.Name, StringComparison.OrdinalIgnoreCase)
        && string.Equals(Login, other.Login, StringComparison.OrdinalIgnoreCase) && Reader == other.Reader
        && Epoch == other.Epoch && Generation == other.Generation && StoreId == other.StoreId;
    public static string ReaderKey(SessionSnapshot session) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(
        JsonSerializer.Serialize(new[] { SessionIdentity.Key(session), session.Epoch.ToString(System.Globalization.CultureInfo.InvariantCulture), session.StoreId ?? "" }))));
}
