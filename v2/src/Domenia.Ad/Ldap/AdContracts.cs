using System.Globalization;
using System.Net;
using System.Security.Principal;

namespace Domenia.Ad;

/// <summary>Scope of an LDAP search.</summary>
public enum AdSearchScope
{
    Base,
    OneLevel,
    Subtree,
}

/// <summary>
/// One LDAP search. <see cref="PageSize"/> pages the answer (simple paged results control); <see cref="SizeLimit"/> stops after
/// that many entries (0: no limit of Domenia, the server keeps its own); <see cref="Timeout"/> bounds every page.
/// </summary>
public sealed record AdSearchRequest(string BaseDn, string Filter, AdSearchScope Scope, IReadOnlyList<string> Attributes)
{
    public int PageSize { get; init; } = 500;

    public int SizeLimit { get; init; }

    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(30);
}

/// <summary>How a modification changes an attribute.</summary>
public enum AdModificationKind
{
    Replace,
    Add,
    Delete,
}

/// <summary>One change of one attribute: values are <see cref="string"/> or <see cref="byte"/> arrays (none: clear on Replace/Delete).</summary>
public sealed record AdModification(string Attribute, AdModificationKind Kind, IReadOnlyList<object> Values);

/// <summary>What the RootDSE of the controller says (read without credentials of an object, always allowed).</summary>
public sealed record AdRootDse(
    string DefaultNamingContext,
    string ConfigurationNamingContext,
    string SchemaNamingContext,
    string RootDomainNamingContext,
    string DnsHostName,
    string? ServerName,
    int? DomainFunctionality,
    IReadOnlyList<string> SupportedControls,
    DateTimeOffset? CurrentTime);

/// <summary>
/// How to reach the directory. <see cref="Server"/> null: the domain locator chooses a controller of <see cref="DomainDnsName"/>
/// (null too: the domain of the computer). <see cref="Credential"/> null: the Windows session (Negotiate, Kerberos), always
/// signed and sealed; a password never leaves the <see cref="NetworkCredential"/> it was given in.
/// </summary>
public sealed record AdConnectionOptions(string? Server, string? DomainDnsName)
{
    public TimeSpan ConnectTimeout { get; init; } = TimeSpan.FromSeconds(15);

    public NetworkCredential? Credential { get; init; }
}

/// <summary>
/// The only door of Domenia.Ad to the directory: searches, reads and the few writes of the write executors. Thread safe;
/// the connection is opened (and bound) on the first call, never in the constructor. Every failure is a
/// <see cref="Core.DomeniaOperationException"/> with a code of <see cref="AdErrors"/> and a French message without secret.
/// </summary>
public interface IAdConnection : IDisposable
{
    /// <summary>DNS name of the controller in use once connected (null before the first call).</summary>
    string? Server { get; }

    Task<AdRootDse> RootDseAsync(CancellationToken cancellationToken);

    /// <summary>Every entry of the search, page after page (stops at <see cref="AdSearchRequest.SizeLimit"/>).</summary>
    Task<IReadOnlyList<AdEntry>> SearchAsync(AdSearchRequest request, CancellationToken cancellationToken);

    /// <summary>One object by its DN (base search), or null when it does not exist.</summary>
    Task<AdEntry?> ReadAsync(string distinguishedName, IReadOnlyList<string> attributes, CancellationToken cancellationToken);

    Task ModifyAsync(string distinguishedName, IReadOnlyList<AdModification> modifications, CancellationToken cancellationToken);

    /// <summary>Moves and/or renames an object (ModifyDN): <paramref name="newRdn"/> like « CN=PC-01 ».</summary>
    Task RenameAsync(string distinguishedName, string newParentDn, string newRdn, CancellationToken cancellationToken);

    Task AddAsync(string distinguishedName, IReadOnlyDictionary<string, IReadOnlyList<object>> attributes, CancellationToken cancellationToken);

    Task DeleteAsync(string distinguishedName, CancellationToken cancellationToken);
}

/// <summary>
/// One entry read from the directory: its DN and its values (<see cref="string"/> for text attributes, <see cref="byte"/> arrays
/// for binary ones: objectGUID, objectSid…). Attribute names are compared without case. Ranged values (member;range=0-1499)
/// are already gathered under their plain name by the connection.
/// </summary>
public sealed class AdEntry
{
    private readonly Dictionary<string, IReadOnlyList<object>> values;

    public AdEntry(string distinguishedName, IReadOnlyDictionary<string, IReadOnlyList<object>> attributes)
    {
        ArgumentNullException.ThrowIfNull(distinguishedName);
        ArgumentNullException.ThrowIfNull(attributes);
        DistinguishedName = distinguishedName;
        values = new Dictionary<string, IReadOnlyList<object>>(attributes, StringComparer.OrdinalIgnoreCase);
    }

    public string DistinguishedName { get; }

    public IEnumerable<string> AttributeNames => values.Keys;

    public bool Has(string name) => values.TryGetValue(name, out var list) && list.Count > 0;

    public IReadOnlyList<object> Raw(string name) => values.TryGetValue(name, out var list) ? list : [];

    public string? String(string name)
    {
        var raw = Raw(name);
        return raw.Count == 0 ? null : raw[0] switch
        {
            string text => text,
            byte[] bytes => System.Text.Encoding.UTF8.GetString(bytes),
            var other => Convert.ToString(other, CultureInfo.InvariantCulture),
        };
    }

    public IReadOnlyList<string> Strings(string name) =>
        [.. Raw(name).Select(v => v switch
        {
            string text => text,
            byte[] bytes => System.Text.Encoding.UTF8.GetString(bytes),
            var other => Convert.ToString(other, CultureInfo.InvariantCulture) ?? "",
        })];

    public int? Int(string name) => int.TryParse(String(name), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : null;

    public long? Long(string name) => long.TryParse(String(name), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : null;

    public byte[]? Bytes(string name) => Raw(name) is { Count: > 0 } raw && raw[0] is byte[] bytes ? bytes : null;

    /// <summary>objectGUID (16 bytes, Microsoft byte order).</summary>
    public Guid? Guid(string name) => Bytes(name) is { Length: 16 } bytes ? new Guid(bytes) : null;

    /// <summary>objectSid as « S-1-5-21-… ».</summary>
    public string? Sid(string name) => Bytes(name) is { Length: >= 8 } bytes ? new SecurityIdentifier(bytes, 0).Value : null;

    /// <summary>A generalized time (whenCreated, whenChanged: « 20261021162600.0Z »), in UTC.</summary>
    public DateTimeOffset? Time(string name)
    {
        var text = String(name);
        if (text is null)
        {
            return null;
        }
        var core = text.Split('.', 'Z')[0];
        return DateTime.TryParseExact(core, "yyyyMMddHHmmss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var at)
            ? new DateTimeOffset(at, TimeSpan.Zero)
            : null;
    }
}

/// <summary>Stable codes and French messages of the directory failures (never a secret, never the request).</summary>
public static class AdErrors
{
    public const string Unavailable = "ad.unavailable";
    public const string UnavailableMessage = "Annuaire injoignable\u00A0: aucun contrôleur de domaine n’a répondu. Les données déjà lues restent affichées.";

    public const string Credentials = "ad.credentials";
    public const string CredentialsMessage = "Identifiants refusés par l’annuaire\u00A0: vérifiez le compte et son mot de passe.";

    public const string AccessDenied = "ad.accessDenied";
    public const string AccessDeniedMessage = "Accès refusé par l’annuaire\u00A0: le compte de la session n’a pas ce droit sur cet objet.";

    public const string NoSuchObject = "ad.noSuchObject";
    public const string NoSuchObjectMessage = "Objet introuvable dans l’annuaire\u00A0: il a peut-être été déplacé ou supprimé.";

    public const string Timeout = "ad.timeout";
    public const string TimeoutMessage = "Délai dépassé\u00A0: l’annuaire n’a pas répondu à temps. Ce n’est pas une coupure\u00A0; relancez plus tard.";

    public const string Constraint = "ad.constraint";
    public const string ConstraintMessage = "L’annuaire refuse cette valeur (contrainte ou stratégie)\u00A0: rien n’a été changé.";

    public const string Unwilling = "ad.unwilling";
    public const string UnwillingMessage = "L’annuaire refuse d’effectuer cette opération (stratégie de mot de passe, objet protégé…)\u00A0: rien n’a été changé.";

    public const string Exists = "ad.exists";
    public const string ExistsMessage = "Un objet de ce nom existe déjà à cet emplacement\u00A0: rien n’a été créé.";

    public const string Failed = "ad.failed";
    public const string FailedMessage = "L’annuaire a renvoyé une erreur\u00A0: le détail technique est dans le journal.";

    public const string NotConnected = "ad.notConnected";
    public const string NotConnectedMessage = "Pas de connexion à l’annuaire dans cette session\u00A0: ouvrez la session sur le domaine.";
}
