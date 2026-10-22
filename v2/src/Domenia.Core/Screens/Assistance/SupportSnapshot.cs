using System.Collections.Immutable;
using System.Globalization;
using System.Security;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>What a capture holds of one attribute (Domenia 1: Provided, Partial, NotProvided).</summary>
public enum FieldCoverage
{
    Provided,
    Partial,
    NotProvided,
}

/// <summary>Where the values of a capture come from: a fresh directory read, the local cache, or unknown.</summary>
public enum SnapshotSource
{
    Live,
    Cache,
    Unknown,
}

/// <summary>One allowlisted attribute of a capture, with its coverage and its cleaned values (128 at most).</summary>
public sealed record SnapshotField(string Name, FieldCoverage Coverage, ImmutableArray<string> Values);

/// <summary>
/// Filtered and masked capture of one directory object (Domenia 1 New-DomeniaSupportSnapshot, format 1): a closed list of 30
/// attributes without secrets, certificates nor notes, each value bounded to 1 024 characters, its identity based on the GUID
/// (else on the DN). <see cref="Kind"/> is « user », « computer », « group » or « object ».
/// </summary>
public sealed record SupportSnapshot(
    int Format,
    string Id,
    string Identity,
    string Scope,
    string Dn,
    string Name,
    string Kind,
    string KindLabel,
    SnapshotSource Source,
    DateTimeOffset ObservedAt,
    DateTimeOffset CapturedAt,
    ImmutableArray<SnapshotField> Fields,
    int FieldCount)
{
    public SnapshotField? Field(string name) => Fields.FirstOrDefault(f => string.Equals(f.Name, name, StringComparison.Ordinal));

    public FieldCoverage Coverage(string name) => Field(name)?.Coverage ?? FieldCoverage.NotProvided;

    /// <summary>Values of one attribute joined by « ; » (empty when not provided).</summary>
    public string Text(string name) => Field(name) is { Coverage: not FieldCoverage.NotProvided } field ? string.Join(" ; ", field.Values) : "";

    /// <summary>Integer value of a fully provided attribute; null when absent, partial or unreadable (never 0 by default).</summary>
    public long? Int64(string name) =>
        Coverage(name) == FieldCoverage.Provided && long.TryParse(Text(name), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : null;
}

/// <summary>
/// Cleaning of one value before it enters a capture, a report or an export (Domenia 1 ConvertTo-DomeniaSupportText): control
/// characters removed, secret-looking text masked as a defence in depth, length bounded. A value that is not text (secure
/// string, bytes, any object) is excluded.
/// </summary>
public static partial class SupportText
{
    public const int DefaultLimit = 1024;
    public const string Excluded = "[valeur exclue]";
    public const string Unsupported = "[type non pris en charge]";
    public const string Masked = "[masqué]";
    public const string RecoveryKeyMasked = "[clé de récupération masquée]";
    public const string Truncated = " [tronqué]";

    public static string Clean(object? value, int limit = DefaultLimit)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 16);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(limit, 32768);
        string text;
        switch (value)
        {
            case null:
                return "";
            case SecureString or byte[]:
                return Excluded;
            case DateTimeOffset instant:
                text = instant.UtcDateTime.ToString("o", CultureInfo.InvariantCulture);
                break;
            case DateTime date:
                text = date.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);
                break;
            case string s:
                text = s;
                break;
            case Guid guid:
                text = guid.ToString("D");
                break;
            case bool flag:
                text = flag ? "True" : "False";
                break;
            case IFormattable formattable when value.GetType().IsValueType:
                text = formattable.ToString(null, CultureInfo.InvariantCulture);
                break;
            default:
                return Unsupported;
        }
        var wasLong = text.Length > limit;
        if (wasLong)
        {
            text = text[..(limit + 1)];
        }
        text = ControlCharacters().Replace(text, " ");
        text = SecretAssignment().Replace(text, "$1=" + Masked);
        text = BearerToken().Replace(text, "Bearer " + Masked);
        text = RecoveryKey().Replace(text, RecoveryKeyMasked);
        if (wasLong || text.Length > limit)
        {
            return text[..Math.Min(limit, text.Length)] + Truncated;
        }
        return text;
    }

    /// <summary>True when the cleaned value lost something (masked, truncated, excluded or unsupported): the field is partial.</summary>
    public static bool LostSomething(string cleaned)
    {
        ArgumentNullException.ThrowIfNull(cleaned);
        return cleaned.Contains(Masked, StringComparison.Ordinal) || cleaned.Contains(RecoveryKeyMasked, StringComparison.Ordinal)
            || cleaned.EndsWith(Truncated, StringComparison.Ordinal) || cleaned == Excluded || cleaned == Unsupported;
    }

    /// <summary>One line, bounded with an ellipsis (Domenia 1 ConvertTo-DomeniaFlatText).</summary>
    public static string Flat(string? text, int maximum = 240)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }
        var flat = Whitespace().Replace(text, " ").Trim();
        return maximum > 3 && flat.Length > maximum ? flat[..(maximum - 1)] + "…" : flat;
    }

    [GeneratedRegex(@"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]", RegexOptions.CultureInvariant, 100)]
    private static partial Regex ControlCharacters();

    [GeneratedRegex(@"\b(password|passwd|pwd|mot de passe|motdepasse|secret|token|api[_-]?key)\s*[:=]\s*[^\r\n]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 100)]
    private static partial Regex SecretAssignment();

    [GeneratedRegex(@"\bBearer\s+[^\s]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 100)]
    private static partial Regex BearerToken();

    [GeneratedRegex(@"(?<!\d)(?:\d{6}-){7}\d{6}(?!\d)", RegexOptions.CultureInvariant, 100)]
    private static partial Regex RecoveryKey();

    [GeneratedRegex(@"\s+", RegexOptions.CultureInvariant, 100)]
    private static partial Regex Whitespace();
}

/// <summary>Masks of secret-looking text before a log, a trace or an export (Domenia 1 Protect-DomeniaSecretText).</summary>
public static partial class SupportSecretMask
{
    public static string Protect(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }
        var masked = RecoveryPassword().Replace(text, SupportText.RecoveryKeyMasked);
        masked = AuthorizationScheme().Replace(masked, "$1 ***");
        masked = JsonMember().Replace(masked, "$1\"***\"");
        masked = KeyValue().Replace(masked, "$1$2***");
        masked = CommandSwitch().Replace(masked, "$1$2 ***");
        return masked;
    }

    [GeneratedRegex(@"(?<!\d)(?:\d{6}-){7}\d{6}(?!\d)", RegexOptions.CultureInvariant, 100)]
    private static partial Regex RecoveryPassword();

    [GeneratedRegex(@"\b(Bearer|Basic)\s+[A-Za-z0-9_.~+/=-]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 100)]
    private static partial Regex AuthorizationScheme();

    [GeneratedRegex(@"(""(?:password|passwd|pwd|pass|p|motdepasse|secret|token|api[_-]?key|apikey|client[_-]?secret)""\s*:\s*)(""(?:\\.|[^""\\])*""|[^,}\s]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 100)]
    private static partial Regex JsonMember();

    [GeneratedRegex(@"\b(password|passwd|pwd|pass|motdepasse|mot\s+de\s+passe|secret|token|authorization|api[_-]?key|apikey|client[_-]?secret)(\s*[=:]\s*)(?!(?:Bearer|Basic)\s)(""[^""]*""|'[^']*'|[^\s;,]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 100)]
    private static partial Regex KeyValue();

    [GeneratedRegex(@"(^|\s)([-/](?:p|rp|pass|password|pwd))(?:\s+|[:=])(""[^""]*""|'[^']*'|\S+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 100)]
    private static partial Regex CommandSwitch();
}

/// <summary>Builder of the captures (Domenia 1 Get-DomeniaSupportFieldNames, New-DomeniaSupportSnapshot).</summary>
public static class SupportSnapshots
{
    public const int CurrentFormat = 1;
    public const int MaxValues = 128;

    /// <summary>Positive allowlist, deliberately excluding secrets, certificates and free-text notes (30 attributes).</summary>
    public static ImmutableArray<string> FieldNames { get; } =
    [
        "name", "distinguishedName", "objectGUID", "sAMAccountName", "userPrincipalName",
        "displayName", "mail", "department", "company", "title", "physicalDeliveryOfficeName",
        "manager", "managedBy", "dNSHostName", "operatingSystem", "operatingSystemVersion",
        "location", "userAccountControl", "msDS-User-Account-Control-Computed",
        "lockoutTime", "pwdLastSet", "accountExpires", "whenCreated", "whenChanged",
        "uSNChanged", "memberOf", "primaryGroupID", "adminCount", "isCriticalSystemObject",
    ];

    public static string KindLabel(string kind) => kind switch
    {
        "user" => "Utilisateur",
        "computer" => "Poste",
        "group" => "Groupe",
        _ => "Objet",
    };

    /// <summary>
    /// Freezes the allowlisted attributes of one object. A ranged memberOf (« memberOf;range=… ») or one read incompletely
    /// (<paramref name="memberOfComplete"/> false) is partial; a value masked, truncated or excluded makes its field partial;
    /// more than 128 values too. The identity is the GUID when it is provided, else the DN in lower case.
    /// </summary>
    public static SupportSnapshot Create(
        IReadOnlyDictionary<string, IReadOnlyList<object?>> properties,
        string scope,
        string dn,
        string name,
        string kind,
        SnapshotSource source,
        DateTimeOffset observedAt,
        DateTimeOffset capturedAt,
        bool memberOfComplete = true,
        string? id = null)
    {
        ArgumentNullException.ThrowIfNull(properties);
        ArgumentNullException.ThrowIfNull(scope);
        ArgumentNullException.ThrowIfNull(dn);
        var fields = ImmutableArray.CreateBuilder<SnapshotField>(FieldNames.Length);
        var count = 0;
        foreach (var field in FieldNames)
        {
            var key = properties.Keys.FirstOrDefault(k => string.Equals(k, field, StringComparison.OrdinalIgnoreCase));
            var ranged = false;
            if (key is null && field == "memberOf")
            {
                key = properties.Keys.FirstOrDefault(k => k.StartsWith("memberOf;range=", StringComparison.OrdinalIgnoreCase));
                ranged = key is not null;
            }
            if (key is null)
            {
                fields.Add(new SnapshotField(field, FieldCoverage.NotProvided, []));
                continue;
            }
            var partial = ranged || (field == "memberOf" && !memberOfComplete);
            var values = ImmutableArray.CreateBuilder<string>();
            foreach (var value in properties[key] ?? [])
            {
                if (values.Count >= MaxValues)
                {
                    partial = true;
                    break;
                }
                var clean = SupportText.Clean(value);
                if (SupportText.LostSomething(clean))
                {
                    partial = true;
                }
                if (clean.Length > 0)
                {
                    values.Add(clean);
                }
            }
            fields.Add(new SnapshotField(field, partial ? FieldCoverage.Partial : FieldCoverage.Provided, values.ToImmutable()));
            count++;
        }
        var built = fields.MoveToImmutable();
        var identity = "dn:" + dn.Trim().ToLowerInvariant();
        var guidField = built.First(f => f.Name == "objectGUID");
        if (guidField.Coverage != FieldCoverage.NotProvided && guidField.Values.Length > 0
            && Guid.TryParse(guidField.Values[0], out var guid) && guid != Guid.Empty)
        {
            identity = "guid:" + guid.ToString("D");
        }
        var cleanKind = kind is "user" or "computer" or "group" ? kind : "object";
        return new SupportSnapshot(
            CurrentFormat,
            id ?? Guid.NewGuid().ToString("N"),
            identity,
            scope.Trim().ToLowerInvariant(),
            SupportText.Clean(dn, 4096),
            SupportText.Clean(name, 256),
            cleanKind,
            KindLabel(cleanKind),
            source,
            observedAt.ToUniversalTime(),
            capturedAt.ToUniversalTime(),
            built,
            count);
    }

    /// <summary>The same capture with every field that is not fully provided marked partial (historical captures).</summary>
    public static SupportSnapshot AsHistorical(SupportSnapshot snapshot, IReadOnlyDictionary<string, FieldCoverage> declared)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(declared);
        var fields = snapshot.Fields.Select(f =>
            declared.TryGetValue(f.Name, out var state) && state != FieldCoverage.Provided ? f with { Coverage = FieldCoverage.Partial } : f).ToImmutableArray();
        return snapshot with { Fields = fields, Source = SnapshotSource.Cache };
    }
}
