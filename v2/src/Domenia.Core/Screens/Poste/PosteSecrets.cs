using System.Collections.Immutable;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Domenia.Core.Poste;

/// <summary>LAPS state as Domenia 1 told it apart (ConvertTo-DomeniaLapsView): reading and decryption are separate.</summary>
public enum LapsState
{
    ReadDenied,
    Prerequisite,
    Unconfirmed,
    NotPublished,
    Available,
    Empty,
    DecryptDenied,
    DecryptPending,
    Unknown,
}

/// <summary>Result of poste.laps.read: metadata only — the password is never part of this view.</summary>
public sealed record LapsView(string Computer, DateTimeOffset ReadAt, LapsState State, string StateLabel, string Message, Tone Tone, bool CanReveal, bool OfferOtherAccount, string Identity, ImmutableArray<PosteFact> Facts);

/// <summary>Metadata of one BitLocker recovery object (msFVE-RecoveryInformation): the key itself is not requested.</summary>
public sealed record BitLockerKeyInfo(string RecoveryId, string KeyGuid, string Dn, DateTimeOffset? CreatedAt, string Created, string Volume);

/// <summary>Result of poste.bitlocker.list: metadata only, 256 objects at most, one level under the computer.</summary>
public sealed record BitLockerList(string Computer, DateTimeOffset ReadAt, FactState ReadState, string StatusText, ImmutableArray<BitLockerKeyInfo> Keys, string ColumnHeader, string Identity, bool OfferOtherAccount, ImmutableArray<PosteFact> Facts);

/// <summary>One numbered block of a recovery password, read aloud block by block (UX-18).</summary>
public sealed record SecretBlock(int Index, string Label, string Digits);

/// <summary>
/// One secret read on an explicit gesture (a LAPS password or a BitLocker recovery key). It never leaves the engine: the
/// bridge hands it to the secure window of the host (<see cref="IPosteSecretWindow"/>) and answers the page with a
/// <see cref="SecretShown"/> that holds no value (OPERATIONS.md § 1.2). Never journalled, cached, exported nor written in a
/// receipt. <see cref="Value"/> is null for a BitLocker key, whose digits are in <see cref="Blocks"/>; both are excluded from
/// any JSON form by construction.
/// </summary>
public sealed record SecretReading(
    string Kind,
    string Computer,
    string Identifier,
    string? KeyGuid,
    [property: JsonIgnore] string? Value,
    [property: JsonIgnore] ImmutableArray<SecretBlock> Blocks,
    int RevealSeconds,
    int ExtensionSeconds,
    int Extensions,
    string ClipboardLimit,
    string Notice,
    bool Simulated,
    DateTimeOffset ReadAt)
{
    /// <summary>The value as it is copied: the password, or the eight blocks joined by dashes.</summary>
    public string CopyText() => Value ?? string.Join("-", Blocks.Select(b => b.Digits));

    /// <summary>Never the value: a secret printed by mistake (journal, exception) shows its identifier only.</summary>
    public override string ToString() => Kind + " " + Computer + " " + Identifier;
}

/// <summary>
/// Answer of poste.laps.reveal and poste.bitlocker.reveal: where the value is shown (the secure window of the host), until
/// when, and its non-secret identity. The value itself is never part of it.
/// </summary>
public sealed record SecretShown(
    string Kind,
    string Computer,
    string Identifier,
    string? KeyGuid,
    string Where,
    DateTimeOffset Until,
    int RevealSeconds,
    int ExtensionSeconds,
    int Extensions,
    string ClipboardLimit,
    string Notice,
    bool Simulated,
    DateTimeOffset ReadAt);

/// <summary>Exposure policy of the secrets (Domenia 1 Get-DomeniaSecretExposurePolicy).</summary>
public static class SecretPolicy
{
    public const int RevealSeconds = 30;
    public const int ExtensionSeconds = 30;
    public const int Extensions = 1;
    public const int ClipboardClearSeconds = 30;
    public const string ClipboardLimit = "Les gestionnaires de presse-papiers tiers et l’historique Windows peuvent conserver une copie hors de Domenia.";
}

/// <summary>Rules of the LAPS and BitLocker secrets of a workstation (Domenia 1 D057 to D059, UX-18). Pure.</summary>
public static partial class PosteSecrets
{
    /// <summary>Most recovery objects listed (OneLevel under the computer).</summary>
    public const int BitLockerCap = 256;

    [GeneratedRegex(@"^[0-9]{6}(-[0-9]{6}){7}$", RegexOptions.CultureInvariant, 200)]
    private static partial Regex RecoveryPassword();

    public static string LapsStateLabel(LapsState state) => state switch
    {
        LapsState.ReadDenied => "Lecture refusée",
        LapsState.Prerequisite => "Prérequis absent",
        LapsState.Unconfirmed => "Publication non confirmée",
        LapsState.NotPublished => "Non publié",
        LapsState.Available => "Disponible",
        LapsState.Empty => "Valeur absente",
        LapsState.DecryptDenied => "Déchiffrement refusé",
        LapsState.DecryptPending => "Déchiffrement non tenté",
        _ => "Indéterminé",
    };

    /// <summary>
    /// The LAPS view from metadata (ConvertTo-DomeniaLapsView): an unreadable confidential attribute looks absent and proves
    /// nothing; a decryption refused is not an empty password; another account is offered on a refusal.
    /// </summary>
    public static LapsView Laps(string computer, string readStatus, string decryptStatus, bool published, bool passwordPresent, string source, DateTimeOffset? expiration, string? account, string? decryptor, string identity, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var facts = ImmutableArray.CreateBuilder<PosteFact>();
        var sourceLabel = source switch { "WindowsLaps" => "Windows LAPS", "LegacyLaps" => "LAPS historique (ms-Mcs-AdmPwd)", _ => "Source non déterminée" };
        facts.Add(PosteText.Fact("Source", sourceLabel, source is "WindowsLaps" or "LegacyLaps" ? FactState.Observed : FactState.Unknown, "Attributs AD du poste", at: now, tone: Tone.Info));
        LapsState state;
        string message;
        switch (readStatus)
        {
            case "AccessDenied":
                state = LapsState.ReadDenied;
                message = "Lecture des attributs LAPS refusée pour ce compte.";
                facts.Add(PosteText.Fact("Lecture", "Refusée", FactState.Refused, "Contrôleur de domaine", "Un refus de lecture ne dit pas si un mot de passe est publié.", at: now));
                break;
            case "ModuleMissing":
                state = LapsState.Prerequisite;
                message = "Module LAPS absent sur ce poste d’administration.";
                facts.Add(PosteText.Fact("Lecture", "Prérequis absent", FactState.Unavailable, "Poste d’administration", at: now));
                break;
            case "Unconfirmed":
                state = LapsState.Unconfirmed;
                message = "Aucune valeur LAPS visible avec ce compte : publication ou droits à vérifier.";
                facts.Add(PosteText.Fact("Publication", "Non confirmée", FactState.Unknown, "Attributs AD du poste", "Un attribut confidentiel illisible paraît absent : ce n’est pas une preuve d’absence.", at: now));
                break;
            case "Failed":
                state = LapsState.Unknown;
                message = "Lecture LAPS non aboutie : aucun constat sur la publication.";
                facts.Add(PosteText.Fact("Lecture", "Non aboutie", FactState.Unavailable, "Contrôleur de domaine", at: now));
                break;
            case "NotPublished":
                state = LapsState.NotPublished;
                message = "Aucun mot de passe LAPS publié pour ce poste, d’après les attributs lisibles.";
                facts.Add(PosteText.Fact("Publication", "Aucune", FactState.Observed, "Attributs AD du poste", "Constat valable pour le compte de lecture utilisé.", at: now, tone: Tone.Warn));
                break;
            case "OK" when !published:
                goto case "NotPublished";
            case "OK":
                facts.Add(PosteText.Fact("Publication", "Publié", FactState.Observed, "Attributs AD du poste", at: now));
                if (expiration is DateTimeOffset exp)
                {
                    facts.Add(PosteText.Fact("Expiration", PosteText.LocalDateTime(exp, zone) + (exp < now ? " (échue)" : ""), FactState.Observed, "Attributs AD du poste", exp < now ? "Rotation en attente : le poste renouvellera le mot de passe à son prochain contact." : null, at: now, tone: exp < now ? Tone.Warn : Tone.Ok));
                }
                if (!string.IsNullOrWhiteSpace(account))
                {
                    facts.Add(PosteText.Fact("Compte géré", account, FactState.Observed, "Attributs AD du poste", at: now, tone: Tone.Info));
                }
                if (!string.IsNullOrWhiteSpace(decryptor))
                {
                    facts.Add(PosteText.Fact("Déchiffreur autorisé", decryptor, FactState.Observed, "Attributs AD du poste", at: now, tone: Tone.Info));
                }
                (state, message) = decryptStatus switch
                {
                    "OK" or "NotEncrypted" when passwordPresent => (LapsState.Available, "Mot de passe publié et lisible. Révélation d’une seule valeur, à la demande, pendant 30 s."),
                    "OK" or "NotEncrypted" => (LapsState.Empty, "Lecture aboutie mais valeur absente."),
                    "Unauthorized" => (LapsState.DecryptDenied, "Mot de passe publié et lu, mais ce compte n’est pas autorisé à le déchiffrer."),
                    _ => (LapsState.DecryptPending, "Mot de passe publié ; déchiffrement non tenté."),
                };
                if (state == LapsState.DecryptDenied)
                {
                    facts.Add(PosteText.Fact("Déchiffrement", "Refusé", FactState.Refused, "Contrôleur de domaine", "Le mot de passe existe : seul le déchiffrement est refusé à ce compte.", at: now));
                }
                break;
            default:
                state = LapsState.Unknown;
                message = "État LAPS non déterminé.";
                break;
        }
        var tone = state switch
        {
            LapsState.Available => Tone.Ok,
            LapsState.ReadDenied or LapsState.DecryptDenied => Tone.Alert,
            LapsState.NotPublished or LapsState.Unconfirmed or LapsState.Empty => Tone.Warn,
            _ => Tone.Off,
        };
        return new LapsView(computer, now, state, LapsStateLabel(state), message, tone, state == LapsState.Available,
            state is LapsState.ReadDenied or LapsState.DecryptDenied or LapsState.Unconfirmed, identity, facts.ToImmutable());
    }

    /// <summary>Metadata of the recovery objects (ConvertTo-DomeniaBitLockerKeyList): the GUID of the key names the row.</summary>
    public static BitLockerKeyInfo? KeyInfo(string name, string dn, Guid? recoveryGuid, DateTimeOffset? whenCreated, string volume, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(zone);
        string guid;
        if (recoveryGuid is Guid g)
        {
            guid = g.ToString("D").ToUpperInvariant();
        }
        else
        {
            var open = name.IndexOf('{', StringComparison.Ordinal);
            var close = name.IndexOf('}', StringComparison.Ordinal);
            if (open < 0 || close <= open || !Guid.TryParse(name.AsSpan(open + 1, close - open - 1), out var parsed))
            {
                return null;
            }
            guid = parsed.ToString("D").ToUpperInvariant();
        }
        return new BitLockerKeyInfo(guid[..8], guid, dn, whenCreated, whenCreated is DateTimeOffset at ? PosteText.LocalDateTime(at, zone) : "date inconnue", volume);
    }

    /// <summary>
    /// Keys matching the first characters of the recovery identifier shown by the workstation (Find-DomeniaBitLockerKey,
    /// tolerant typing improved: dashes, spaces and braces ignored). Local only: nothing is read, nothing revealed.
    /// </summary>
    public static (ImmutableArray<BitLockerKeyInfo> Matches, bool Unique, string Message) Find(IReadOnlyList<BitLockerKeyInfo> keys, string? recoveryId)
    {
        ArgumentNullException.ThrowIfNull(keys);
        var wanted = new string((recoveryId ?? "").Where(char.IsAsciiHexDigit).ToArray()).ToUpperInvariant();
        if (wanted.Length < 4)
        {
            return ([], false, "Saisissez au moins les quatre premiers caractères de l’identifiant de récupération (format XXXXXXXX-…).");
        }
        var found = keys.Where(k => k.KeyGuid.Replace("-", "", StringComparison.Ordinal).StartsWith(wanted, StringComparison.OrdinalIgnoreCase)).ToImmutableArray();
        var message = found.Length switch
        {
            0 => "Aucune clé ne porte cet identifiant pour ce poste.",
            1 => "Clé identifiée. Révélez-la ou copiez-la à la demande.",
            _ => FrenchText.Integer(found.Length) + " clés correspondent : complétez l’identifiant.",
        };
        return (found, found.Length == 1, message);
    }

    /// <summary>
    /// True when the recovery identifier read back with the key is the one the operator chose (Domenia 1 Mismatch): dashes,
    /// braces and case ignored, the whole GUID compared. A different identifier gives no value.
    /// </summary>
    public static bool MatchesExpected(string? keyGuid, string? expected)
    {
        static string Norm(string? v) => new string((v ?? "").Where(char.IsAsciiHexDigit).ToArray()).ToUpperInvariant();
        var read = Norm(keyGuid);
        var wanted = Norm(expected);
        return read.Length == 32 && string.Equals(read, wanted, StringComparison.Ordinal);
    }

    /// <summary>
    /// Index entries of an older holder of the same name are left out (Domenia 1 PST-065): an entry written for another GUID,
    /// or before the creation of the computer read by GUID, describes another object.
    /// </summary>
    public static bool IndexApplies(Guid entryGuid, DateTimeOffset entryAt, Guid computerGuid, DateTimeOffset whenCreated) =>
        entryGuid == computerGuid && entryAt >= whenCreated;

    /// <summary>The eight numbered blocks of a recovery password; any other shape gives no block (never dictated).</summary>
    public static ImmutableArray<SecretBlock> Blocks(string? value)
    {
        var text = (value ?? "").Trim();
        if (!RecoveryPassword().IsMatch(text))
        {
            return [];
        }
        return [.. text.Split('-').Select((digits, i) => new SecretBlock(i + 1, "Bloc " + (i + 1).ToString(System.Globalization.CultureInfo.InvariantCulture), digits))];
    }

    /// <summary>True when <paramref name="childDn"/> is exactly one RDN below <paramref name="parentDn"/> (Test-DomeniaDirectChildDn).</summary>
    public static bool IsDirectChild(string parentDn, string childDn)
    {
        ArgumentNullException.ThrowIfNull(parentDn);
        ArgumentNullException.ThrowIfNull(childDn);
        try
        {
            var parent = DistinguishedName.Parse(parentDn);
            var child = DistinguishedName.Parse(childDn);
            return child.Length == parent.Length + 1 && DistinguishedName.IsWithin(child, parent, subtree: false);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    /// <summary>Header of the identity column of the secrets grid (UX-18).</summary>
    public static string ColumnHeader(bool bitLocker, bool laps) => (bitLocker, laps) switch
    {
        (true, false) => "Identifiant de récupération",
        (false, true) => "Compte",
        _ => "Compte ou identifiant",
    };

    /// <summary>Which identity will read a secret (Get-DomeniaSecretIdentityReason): no privileged account required in advance.</summary>
    public static (string Identity, string Reason) Identity(string account, bool deniedBefore) =>
        deniedBefore
            ? (account, "Un refus est mémorisé pour ce poste : un autre compte sera proposé (invite Windows) avant toute nouvelle lecture.")
            : (account, "Jeton Windows de la session (" + account + ") tant qu’il n’est pas refusé ; aucun compte privilégié n’est exigé d’avance. Le contrôleur décide.");
}

/// <summary>Result of the proposal of another account for a refused secret resource (no password ever in it).</summary>
public sealed record OtherAccountResult(string Computer, string Resource, bool Accepted, string Identity, string Text, bool Simulated);

/// <summary>One workstation of the secrets index of the OU (metadata only).</summary>
public sealed record SecretsIndexRow(string Dn, string Computer, int? BitLockerKeys, FactState BitLockerState, DateTimeOffset? LapsExpiration, bool LapsExpired, string LapsKind);

/// <summary>Result of poste.secrets.index: counts, the sentence above the list and the rows (no value, no key).</summary>
public sealed record SecretsIndex(ScopeSelection Scope, DateTimeOffset ReadAt, int Total, int WithKeys, int WithoutKeys, int Refused, int LapsExpired, int LapsMissing, bool Truncated, string Summary, ImmutableArray<SecretsIndexRow> Rows);
