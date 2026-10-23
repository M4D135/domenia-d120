using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>Kind of object a fiche shows (Domenia 1 Set-VisibleTabsForType: Utilisateur, Machine, Groupe, OU, Conteneur, plus contacts).</summary>
public enum FicheKind
{
    User,
    Computer,
    Group,
    Ou,
    Contact,
    Container,
}

/// <summary>
/// One directory object as read, whatever its source: its kind, identity and every attribute read, as LDAP string values
/// (integers in decimal, large integers as FILETIME decimal, GUID in « D » form, SID in « S-1-… » form, generalized time for
/// whenCreated and whenChanged, binary values in hexadecimal). The simulation builds it from the fictitious directory, the
/// directory mode will build it from an LDAP entry (wave 3): every rule of the fiche works on this bag only. Sensitive
/// attributes (passwords, LAPS, BitLocker, keys) are never put in it (<see cref="FicheAttributeRules.IsSensitive"/>).
/// </summary>
public sealed record FicheEntry(FicheKind Kind, Guid ObjectGuid, string Dn, string Name, ImmutableDictionary<string, ImmutableArray<string>> Attributes)
{
    /// <summary>Builds an entry from name/values pairs: empty values and sensitive attributes are dropped, names are case insensitive.</summary>
    public static FicheEntry Create(FicheKind kind, Guid objectGuid, string dn, string name, IEnumerable<KeyValuePair<string, IEnumerable<string?>>> attributes)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(attributes);
        var builder = ImmutableDictionary.CreateBuilder<string, ImmutableArray<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in attributes)
        {
            if (FicheAttributeRules.IsSensitive(pair.Key))
            {
                continue;
            }
            var values = pair.Value.Where(v => !string.IsNullOrEmpty(v)).Select(v => v!).ToImmutableArray();
            if (values.Length > 0)
            {
                builder[pair.Key] = values;
            }
        }
        return new FicheEntry(kind, objectGuid, dn, name, builder.ToImmutable());
    }

    public bool Has(string attribute) => Attributes.ContainsKey(attribute);

    /// <summary>First value of an attribute, or null when it was not read or is empty.</summary>
    public string? First(string attribute) => Attributes.TryGetValue(attribute, out var values) && values.Length > 0 ? values[0] : null;

    /// <summary>Every value of an attribute (empty when absent).</summary>
    public ImmutableArray<string> All(string attribute) => Attributes.TryGetValue(attribute, out var values) ? values : [];

    public long? Int64(string attribute) =>
        long.TryParse(First(attribute), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : null;

    public int? Int32(string attribute) =>
        int.TryParse(First(attribute), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : null;

    /// <summary>A FILETIME attribute as a date; 0, « never » and unreadable values give null.</summary>
    public DateTimeOffset? FileTime(string attribute) => AdValues.FromFileTime(Int64(attribute));

    /// <summary>A generalized time attribute (whenCreated, whenChanged) as a date.</summary>
    public DateTimeOffset? Generalized(string attribute) => FicheValues.ParseGeneralizedTime(First(attribute));

    /// <summary>Entry with some attributes replaced (null or empty values remove them).</summary>
    public FicheEntry With(IReadOnlyDictionary<string, ImmutableArray<string>> changes, string? dn = null, string? name = null)
    {
        ArgumentNullException.ThrowIfNull(changes);
        var builder = Attributes.ToBuilder();
        foreach (var (key, values) in changes)
        {
            var kept = values.IsDefault ? [] : values.Where(v => !string.IsNullOrEmpty(v)).ToImmutableArray();
            if (kept.Length == 0)
            {
                builder.Remove(key);
            }
            else
            {
                builder[key] = kept;
            }
        }
        return this with { Dn = dn ?? Dn, Name = name ?? Name, Attributes = builder.ToImmutable() };
    }
}

/// <summary>An object of the local index (name, kind and place), for names, pickers, member types and recent fiches.</summary>
public sealed record FicheSummary(
    string Dn,
    string Name,
    FicheKind Kind,
    string? Sam,
    string? Detail,
    bool Disabled,
    Guid ObjectGuid,
    string? Sid = null,
    int? GroupType = null,
    int? AdminCount = null,
    string? Upn = null)
{
    public static FicheSummary From(FicheEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        return new(entry.Dn, entry.First("displayName") ?? entry.Name, entry.Kind, entry.First("sAMAccountName"),
            entry.First("description") ?? entry.First("mail"), entry.Int32("userAccountControl") is { } uac && AdValues.IsDisabled(uac),
            entry.ObjectGuid, entry.First("objectSid"), entry.Int32("groupType"), entry.Int32("adminCount"), entry.First("userPrincipalName"));
    }
}

/// <summary>Encodings of the values of a fiche (pure, independent of the culture).</summary>
public static class FicheValues
{
    /// <summary>« 20261021162600.0Z » as written by the directory.</summary>
    public static string GeneralizedTime(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyyMMddHHmmss'.0Z'", CultureInfo.InvariantCulture);

    public static DateTimeOffset? ParseGeneralizedTime(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length < 14)
        {
            return null;
        }
        return DateTime.TryParseExact(value[..14], "yyyyMMddHHmmss", CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed)
            ? new DateTimeOffset(parsed, TimeSpan.Zero)
            : null;
    }

    public static string Number(long value) => value.ToString(CultureInfo.InvariantCulture);

    /// <summary>« 21/10/2026 » in the zone.</summary>
    public static string LocalDate(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM'/'yyyy", CultureInfo.InvariantCulture);
    }

    /// <summary>« 21/10/2026 18:08 » in the zone (Domenia 1 Format-DomeniaCallSheetDate).</summary>
    public static string LocalDateTime(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>« 21/10 18:08 » in the zone (support band of Domenia 1).</summary>
    public static string ShortDateTime(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>Local calendar day of an instant.</summary>
    public static DateOnly LocalDay(DateTimeOffset at, TimeZoneInfo zone) => LocalDays.DateOf(at, zone);

    /// <summary>Value of the first RDN of a DN, escapes decoded (Get-DomeniaDnDisplayName); the DN itself when unreadable.</summary>
    public static string DisplayName(string? dn)
    {
        if (string.IsNullOrWhiteSpace(dn))
        {
            return "";
        }
        try
        {
            var parts = DistinguishedName.Parse(dn);
            return parts.Length > 0 ? parts[0].Value : dn;
        }
        catch (FormatException)
        {
            return dn;
        }
    }

    /// <summary>
    /// Readable path of a DN from the domain down (« example.local › Utilisateurs › Lyon »), the object itself excluded unless
    /// <paramref name="includeSelf"/>; the DC components give the DNS name.
    /// </summary>
    public static string ReadablePath(string dn, bool includeSelf = false)
    {
        ArgumentNullException.ThrowIfNull(dn);
        try
        {
            var parts = DistinguishedName.Parse(dn);
            var domain = string.Join('.', parts.Where(p => p.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)).Select(p => p.Value));
            var names = parts.Where(p => !p.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)).Select(p => p.Value).Reverse().ToList();
            if (!includeSelf && names.Count > 0 && !parts[0].Type.Equals("DC", StringComparison.OrdinalIgnoreCase))
            {
                names.RemoveAt(names.Count - 1);
            }
            var items = new List<string>();
            if (domain.Length > 0)
            {
                items.Add(domain);
            }
            items.AddRange(names);
            return string.Join(FrenchText.PathSeparator, items);
        }
        catch (FormatException)
        {
            return dn;
        }
    }

    /// <summary>Same DN, case and escaping ignored; malformed DNs are never equal.</summary>
    public static bool SameDn(string? left, string? right)
    {
        if (left is null || right is null)
        {
            return false;
        }
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

    /// <summary>Two letters for an avatar: initials of the first two words, or the first two letters.</summary>
    public static string Initials(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        var words = name.Split([' ', '-', ',', '.', '_'], StringSplitOptions.RemoveEmptyEntries)
            .Where(w => char.IsLetterOrDigit(w[0])).ToList();
        if (words.Count >= 2)
        {
            return string.Concat(char.ToUpperInvariant(words[0][0]), char.ToUpperInvariant(words[1][0]));
        }
        if (words.Count == 1)
        {
            var word = words[0];
            return word.Length >= 2 ? string.Concat(char.ToUpperInvariant(word[0]), char.ToLowerInvariant(word[1])) : word.ToUpperInvariant();
        }
        return "?";
    }
}
