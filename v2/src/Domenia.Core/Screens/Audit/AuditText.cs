using System.Collections.Frozen;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// Labels of the AD audit (Domenia 1, Domenia-AdAudit.Model.ps1): well-known SIDs, schema objects and extended rights,
/// rights in words, fact states, durations and replication results. Pure: no directory, network, disk nor clock.
/// </summary>
public static partial class AuditText
{
    private static readonly FrozenDictionary<string, string> WellKnownSids = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["S-1-1-0"] = "Tout le monde",
        ["S-1-3-0"] = "Créateur propriétaire",
        ["S-1-5-2"] = "Réseau",
        ["S-1-5-4"] = "Interactif",
        ["S-1-5-7"] = "Ouverture de session anonyme",
        ["S-1-5-9"] = "Contrôleurs de domaine d’entreprise",
        ["S-1-5-10"] = "L’objet lui-même (SELF)",
        ["S-1-5-11"] = "Utilisateurs authentifiés",
        ["S-1-5-18"] = "Système local",
        ["S-1-5-19"] = "Service local",
        ["S-1-5-20"] = "Service réseau",
        ["S-1-5-32-544"] = "Administrateurs (intégré)",
        ["S-1-5-32-545"] = "Utilisateurs (intégré)",
        ["S-1-5-32-546"] = "Invités (intégré)",
        ["S-1-5-32-548"] = "Opérateurs de compte",
        ["S-1-5-32-549"] = "Opérateurs de serveur",
        ["S-1-5-32-550"] = "Opérateurs d’impression",
        ["S-1-5-32-551"] = "Opérateurs de sauvegarde",
        ["S-1-5-32-554"] = "Accès compatible pré-Windows 2000",
        ["S-1-5-32-560"] = "Groupe d’accès d’autorisation Windows",
        ["S-1-5-32-561"] = "Serveurs de licences des services Terminal Server",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    private static readonly FrozenDictionary<string, string> DomainRids = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["500"] = "Administrateur du domaine",
        ["502"] = "krbtgt",
        ["512"] = "Admins du domaine",
        ["513"] = "Utilisateurs du domaine",
        ["515"] = "Ordinateurs du domaine",
        ["516"] = "Contrôleurs de domaine",
        ["517"] = "Éditeurs de certificats",
        ["518"] = "Administrateurs du schéma",
        ["519"] = "Administrateurs de l’entreprise",
        ["520"] = "Propriétaires créateurs de la stratégie de groupe",
        ["521"] = "Contrôleurs de domaine en lecture seule",
        ["526"] = "Administrateurs clés",
        ["527"] = "Administrateurs clés de l’entreprise",
        ["553"] = "Serveurs RAS et IAS",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    /// <summary>Schema objects and extended rights met most often in delegations (Get-DomeniaAdGuidLabel).</summary>
    private static readonly FrozenDictionary<Guid, string> GuidLabels = new Dictionary<Guid, string>
    {
        [new Guid("00299570-246d-11d0-a768-00aa006e0529")] = "Réinitialiser le mot de passe",
        [new Guid("ab721a53-1e2f-11d0-9819-00aa0040529b")] = "Modifier le mot de passe",
        [new Guid("ab721a54-1e2f-11d0-9819-00aa0040529b")] = "Envoyer en tant que",
        [new Guid("ab721a56-1e2f-11d0-9819-00aa0040529b")] = "Recevoir en tant que",
        [new Guid("4c164200-20c0-11d0-a768-00aa006e0529")] = "Restrictions du compte (ensemble de propriétés)",
        [new Guid("5f202010-79a5-11d0-9020-00c04fc2d4cf")] = "Informations d’ouverture de session (ensemble de propriétés)",
        [new Guid("bc0ac240-79a9-11d0-9020-00c04fc2d4cf")] = "Appartenance aux groupes (ensemble de propriétés)",
        [new Guid("59ba2f42-79a2-11d0-9020-00c04fc2d3cf")] = "Informations générales (ensemble de propriétés)",
        [new Guid("77b5b886-944a-11d1-aebd-0000f80367c1")] = "Informations personnelles (ensemble de propriétés)",
        [new Guid("e48d0154-bcf8-11d1-8702-00c04fb96050")] = "Informations publiques (ensemble de propriétés)",
        [new Guid("e45795b2-9455-11d1-aebd-0000f80367c1")] = "Informations de messagerie (ensemble de propriétés)",
        [new Guid("e45795b3-9455-11d1-aebd-0000f80367c1")] = "Informations web (ensemble de propriétés)",
        [new Guid("037088f8-0ae1-11d2-b422-00a0c968f939")] = "Informations d’accès distant (ensemble de propriétés)",
        [new Guid("91e647de-d96f-4b70-9557-d63ff4f3ccd8")] = "Informations privées (ensemble de propriétés)",
        [new Guid("bf9679c0-0de6-11d0-a285-00aa003049e2")] = "Membres du groupe (member)",
        [new Guid("bf967a68-0de6-11d0-a285-00aa003049e2")] = "Options du compte (userAccountControl)",
        [new Guid("bf967a0a-0de6-11d0-a285-00aa003049e2")] = "Date du mot de passe (pwdLastSet)",
        [new Guid("28630ebf-41d5-11d1-a9c1-0000f80367c1")] = "Verrouillage (lockoutTime)",
        [new Guid("bf9679a8-0de6-11d0-a285-00aa003049e2")] = "Script d’ouverture de session (scriptPath)",
        [new Guid("f3a64788-5306-11d1-a9c5-0000f80367c1")] = "Noms de principal de service (servicePrincipalName)",
        [new Guid("72e39547-7b18-11d1-adef-00c04fd8d5cd")] = "Écriture validée du nom DNS (dNSHostName)",
        [new Guid("3f78c3e5-f79a-46bd-a0b8-9d18116ddc79")] = "Délégation contrainte basée sur la ressource (msDS-AllowedToActOnBehalfOfOtherIdentity)",
        [new Guid("5b47d60f-6090-40b2-9f37-2a4de88f3063")] = "Informations d’identification de clé (msDS-KeyCredentialLink)",
        [new Guid("1131f6aa-9c07-11d1-f79f-00c04fc2dcd2")] = "Répliquer les modifications de l’annuaire",
        [new Guid("1131f6ad-9c07-11d1-f79f-00c04fc2dcd2")] = "Répliquer toutes les modifications de l’annuaire",
        [new Guid("89e95b76-444d-4c62-991a-0facbeda640c")] = "Répliquer les modifications d’un jeu filtré",
        [new Guid("edacfd8f-ffb3-11d1-b41d-00a0c968f939")] = "Appliquer la stratégie de groupe",
        [new Guid("bf967aba-0de6-11d0-a285-00aa003049e2")] = "Objets utilisateur",
        [new Guid("bf967a86-0de6-11d0-a285-00aa003049e2")] = "Objets ordinateur",
        [new Guid("bf967a9c-0de6-11d0-a285-00aa003049e2")] = "Objets groupe",
        [new Guid("bf967aa5-0de6-11d0-a285-00aa003049e2")] = "Unités d’organisation",
        [new Guid("4828cc14-1437-45bc-9b07-ad6f015e5f28")] = "Objets inetOrgPerson",
    }.ToFrozenDictionary();

    private static readonly FrozenDictionary<string, string> RightLabels = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["GenericAll"] = "Contrôle total",
        ["GenericRead"] = "Lecture",
        ["GenericWrite"] = "Écriture",
        ["GenericExecute"] = "Exécution",
        ["ReadProperty"] = "Lire des propriétés",
        ["WriteProperty"] = "Écrire des propriétés",
        ["ExtendedRight"] = "Droit étendu",
        ["CreateChild"] = "Créer des objets enfants",
        ["DeleteChild"] = "Supprimer des objets enfants",
        ["Delete"] = "Supprimer",
        ["DeleteTree"] = "Supprimer l’arborescence",
        ["ReadControl"] = "Lire les autorisations",
        ["WriteDacl"] = "Modifier les autorisations",
        ["WriteOwner"] = "Modifier le propriétaire",
        ["ListChildren"] = "Lister le contenu",
        ["ListObject"] = "Lister l’objet",
        ["Self"] = "Écriture validée",
        ["AccessSystemSecurity"] = "Accès à la sécurité système",
        ["Synchronize"] = "Synchroniser",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    private static readonly FrozenDictionary<long, string> ReplicationResults = new Dictionary<long, string>
    {
        [0] = "succès",
        [5] = "accès refusé",
        [1256] = "système distant non disponible",
        [1722] = "serveur RPC non disponible",
        [1753] = "point de terminaison introuvable",
        [1908] = "contrôleur de domaine introuvable",
        [8453] = "accès à la réplication refusé",
        [8524] = "échec de la recherche DNS du partenaire",
        [8545] = "objet déplacé ou partition différente",
        [8606] = "attributs insuffisants pour créer l’objet",
        [8614] = "durée de vie des objets supprimés dépassée",
    }.ToFrozenDictionary();

    /// <summary>French label of a well-known or built-in SID; null for any other account.</summary>
    public static string? WellKnownSidName(string? sid)
    {
        var value = sid?.Trim();
        if (string.IsNullOrEmpty(value))
        {
            return null;
        }
        if (WellKnownSids.TryGetValue(value, out var label))
        {
            return label;
        }
        var match = DomainRidPattern().Match(value);
        return match.Success && DomainRids.TryGetValue(match.Groups["rid"].Value, out var domain) ? domain : null;
    }

    /// <summary>True for a SID of a domain account (S-1-5-21-a-b-c-rid): the only ones whose groups can be read.</summary>
    public static bool IsDomainAccountSid(string? sid) => sid is not null && DomainAccountPattern().IsMatch(sid);

    /// <summary>Label of a schema object or an extended right; null when unknown.</summary>
    public static string? GuidLabel(Guid? guid) => guid is Guid g && GuidLabels.TryGetValue(g, out var label) ? label : null;

    /// <summary>Names of an ActiveDirectoryRights text (« ReadProperty, WriteProperty »).</summary>
    public static IReadOnlyList<string> RightNames(string? rights) =>
        string.IsNullOrWhiteSpace(rights) ? [] : [.. rights.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)];

    /// <summary>Rights in words, generic rights kept whole (Format-DomeniaAdRights).</summary>
    public static string FormatRights(string? rights) =>
        string.Join(", ", RightNames(rights).Select(n => RightLabels.TryGetValue(n, out var label) ? label : n));

    public static string FactStateLabel(AuditFactState state) => state switch
    {
        AuditFactState.Observed => "Constaté",
        AuditFactState.Estimated => "Estimé",
        AuditFactState.Refused => "Refusé",
        AuditFactState.Unavailable => "Indisponible",
        _ => "Inconnu",
    };

    /// <summary>Short duration: seconds, minutes, hours below two days, then days (Get-DomeniaDurationText).</summary>
    public static string Duration(TimeSpan span)
    {
        var abs = span.Duration();
        if (abs.TotalMinutes < 1)
        {
            return FrenchText.Integer((long)Math.Round(abs.TotalSeconds)) + FrenchText.Nbsp + "s";
        }
        if (abs.TotalHours < 1)
        {
            return FrenchText.Integer((long)Math.Floor(abs.TotalMinutes)) + FrenchText.Nbsp + "min";
        }
        if (abs.TotalDays < 2)
        {
            return FrenchText.Integer((long)Math.Floor(abs.TotalHours)) + FrenchText.Nbsp + "h";
        }
        return FrenchText.Integer((long)Math.Floor(abs.TotalDays)) + FrenchText.Nbsp + "j";
    }

    /// <summary>« 1722 (serveur RPC non disponible) », or « code n » for an unknown result.</summary>
    public static string ReplicationResult(long code) =>
        ReplicationResults.TryGetValue(code, out var label)
            ? code.ToString(CultureInfo.InvariantCulture) + " (" + label + ")"
            : "code " + code.ToString(CultureInfo.InvariantCulture);

    /// <summary>Policy interval as words: « 90 jours », « 30 min », « Jamais » (explicit zero), « Non lue ».</summary>
    public static string Interval(AdInterval interval, bool minutes = false)
    {
        ArgumentNullException.ThrowIfNull(interval);
        return interval.State switch
        {
            AdIntervalState.Never => "Jamais",
            AdIntervalState.Value when interval.Span is TimeSpan span => minutes
                ? FrenchText.Integer((long)Math.Round(span.TotalMinutes)) + FrenchText.Nbsp + "min"
                : FrenchText.Count((long)Math.Round(span.TotalDays), "jour", "jours"),
            _ => "Non lue",
        };
    }

    /// <summary>Local date and time « 21/10/2026 18:08 » in the given zone.</summary>
    public static string LocalDateTime(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>First RDN value of a DN (its name), or the DN itself when unreadable.</summary>
    public static string NameOf(string dn)
    {
        ArgumentNullException.ThrowIfNull(dn);
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

    /// <summary>Text flattened on one line and cut to <paramref name="max"/> characters (ConvertTo-DomeniaFlatText).</summary>
    public static string Flat(string? text, int max)
    {
        if (string.IsNullOrEmpty(text))
        {
            return string.Empty;
        }
        var flat = WhitespacePattern().Replace(text, " ").Trim();
        return flat.Length <= max ? flat : flat[..Math.Max(0, max - 1)] + "…";
    }

    [GeneratedRegex(@"^S-1-5-21-\d+-\d+-\d+-(?<rid>\d+)$", RegexOptions.CultureInvariant)]
    private static partial Regex DomainRidPattern();

    [GeneratedRegex(@"^S-1-5-21(-\d{1,10}){4}$", RegexOptions.CultureInvariant)]
    private static partial Regex DomainAccountPattern();

    [GeneratedRegex(@"\s+", RegexOptions.CultureInvariant)]
    private static partial Regex WhitespacePattern();
}
