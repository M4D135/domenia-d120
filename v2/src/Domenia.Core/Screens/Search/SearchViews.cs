using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>
/// Ready-made read-only view of the directory (Domenia 1 Get-DomeniaWorkViews, D038): a filter and a type, no account, no
/// right, no write mode. <see cref="Matches"/> evaluates in memory the very filter <see cref="LdapFilter"/> sends in
/// directory mode.
/// </summary>
public sealed record SearchWorkView(string Id, string Name, string Category, SearchTypeFilter Type, string Note, string LdapFilter, string Cost, Func<object, bool> Matches);

/// <summary>Verdict of a local query on one workstation, and the value read.</summary>
public sealed record SearchLocalVerdict(string Verdict, string Value);

/// <summary>
/// Local query on the workstations of the local base (RCH-122): evaluated on the readings, Correspondants, Inconnus (no
/// reading of less than 30 days, never guessed) or Non correspondants. No directory read, no ping, no survey.
/// </summary>
public sealed record SearchLocalQuery(string Id, string Name, string Category, string Description, Func<DirectoryComputer, WorkstationObservation?, DateTimeOffset, SearchLocalVerdict> Evaluate);

/// <summary>Ready-made views and delivered local queries of the search screen.</summary>
public static class SearchViews
{
    public const string Match = "match";
    public const string Unknown = "unknown";
    public const string NoMatch = "noMatch";

    private const string Person = "(objectCategory=person)(objectClass=user)";
    private const string Enabled = "(!(userAccountControl:1.2.840.113556.1.4.803:=2))";
    private const string Bitwise = "Filtre bit à bit sur userAccountControl" + FrenchText.Colon + "jamais indexé, l’annuaire lit chaque compte du périmètre.";
    private const string Indexed = "Filtre sur des attributs habituellement indexés (objectCategory, dates de connexion)" + FrenchText.Colon + "coût modéré. Sans schéma lu, l’usage des index reste estimé.";
    private const string Category = "Filtre sur objectCategory, indexé" + FrenchText.Colon + "coût faible.";

    private static readonly TimeSpan Inactive = TimeSpan.FromDays(90);
    private static readonly TimeSpan Fresh = TimeSpan.FromDays(30);

    /// <summary>The thirteen work views of Domenia 1, with their filters computed for <paramref name="now"/>.</summary>
    public static ImmutableArray<SearchWorkView> All(DateTimeOffset now)
    {
        var nowFt = Ft(now);
        var in30 = Ft(now + TimeSpan.FromDays(30));
        var inactive = Ft(now - Inactive);
        var pwdOld = Ft(now - TimeSpan.FromDays(365));
        var recent = (now - TimeSpan.FromDays(7)).UtcDateTime.ToString("yyyyMMddHHmmss", CultureInfo.InvariantCulture) + ".0Z";
        return
        [
            new("expiring", "Comptes expirant sous 30 jours", "Comptes", SearchTypeFilter.Users, "Date d’expiration du compte, pas du mot de passe.",
                "(&" + Person + "(accountExpires>=" + nowFt + ")(accountExpires<=" + in30 + "))", Indexed,
                o => o is DirectoryUser u && AdValues.FromFileTime(u.AccountExpires) is DateTimeOffset at && at >= now && at <= now + TimeSpan.FromDays(30)),
            new("disabled", "Comptes désactivés", "Comptes", SearchTypeFilter.Users, "Comptes dont l’option « compte désactivé » est posée (userAccountControl).",
                "(&" + Person + "(userAccountControl:1.2.840.113556.1.4.803:=2))", Bitwise,
                o => o is DirectoryUser u && AdValues.IsDisabled(u.UserAccountControl)),
            new("expiredaccounts", "Comptes à la date d’expiration dépassée", "Comptes", SearchTypeFilter.Users,
                "Date d’expiration du compte (accountExpires) passée. « N’expire jamais » (0 ou valeur maximale) est exclu. L’expiration bloque l’ouverture de session sans désactiver le compte.",
                "(&" + Person + "(accountExpires>=1)(accountExpires<=" + nowFt + "))", Indexed,
                o => o is DirectoryUser u && AdValues.FromFileTime(u.AccountExpires) is DateTimeOffset at && at <= now),
            new("lockedusers", "Comptes avec un verrouillage enregistré", "Comptes", SearchTypeFilter.Users,
                "lockoutTime non nul. Il n’est remis à zéro qu’au déverrouillage ou à la prochaine ouverture de session réussie" + FrenchText.Colon
                + "un verrouillage échu peut encore figurer. L’état actuel se confirme sur la fiche (état calculé par le contrôleur).",
                "(&" + Person + "(lockoutTime>=1))", Indexed,
                o => o is DirectoryUser u && u.LockoutTime is > 0),
            new("inactiveusers", "Comptes actifs sans connexion depuis 90 jours", "Comptes", SearchTypeFilter.Users,
                "Comptes activés dont la dernière connexion répliquée (lastLogonTimestamp, à 14 jours près) date d’au moins 90 jours. Les comptes jamais connectés sont dans une vue distincte. Aucun compte n’est déclaré supprimable.",
                "(&" + Person + Enabled + "(lastLogonTimestamp<=" + inactive + "))", Bitwise,
                o => o is DirectoryUser u && !AdValues.IsDisabled(u.UserAccountControl) && AdValues.FromFileTime(u.LastLogonTimestamp) is DateTimeOffset at && at <= now - Inactive),
            new("neverloggedusers", "Comptes actifs jamais connectés", "Comptes", SearchTypeFilter.Users,
                "Comptes activés sans aucune date de connexion répliquée (lastLogonTimestamp absent)" + FrenchText.Colon + "compte neuf, compte de service ou compte oublié. Aucune conclusion sans vérification.",
                "(&" + Person + Enabled + "(!(lastLogonTimestamp=*)))", Bitwise,
                o => o is DirectoryUser u && !AdValues.IsDisabled(u.UserAccountControl) && AdValues.FromFileTime(u.LastLogonTimestamp) is null),
            new("pwdneverexpires", "Mots de passe sans expiration (option du compte)", "Mots de passe", SearchTypeFilter.Users,
                "Option « Le mot de passe n’expire jamais » lue dans userAccountControl. Aucun mot de passe n’est lu ; une option à revoir, pas une compromission.",
                "(&" + Person + "(userAccountControl:1.2.840.113556.1.4.803:=65536))", Bitwise,
                o => o is DirectoryUser u && AdValues.HasFlag(u.UserAccountControl, AdValues.DontExpirePassword)),
            new("pwdnotrequired", "Comptes sans mot de passe exigé (option du compte)", "Mots de passe", SearchTypeFilter.Users,
                "Option PASSWD_NOTREQD lue dans userAccountControl" + FrenchText.Colon + "l’exigence est levée, le compte peut avoir un mot de passe. Aucun mot de passe n’est lu.",
                "(&" + Person + "(userAccountControl:1.2.840.113556.1.4.803:=32))", Bitwise,
                o => o is DirectoryUser u && AdValues.HasFlag(u.UserAccountControl, AdValues.PasswordNotRequired)),
            new("pwdold", "Mots de passe inchangés depuis un an", "Mots de passe", SearchTypeFilter.Users,
                "Comptes activés dont le dernier changement de mot de passe (pwdLastSet) date d’au moins 365 jours. L’âge seul ne dit ni la robustesse ni une compromission ; la stratégie applicable se lit dans Audit AD.",
                "(&" + Person + Enabled + "(pwdLastSet>=1)(pwdLastSet<=" + pwdOld + "))", Bitwise,
                o => o is DirectoryUser u && !AdValues.IsDisabled(u.UserAccountControl) && AdValues.FromFileTime(u.PasswordLastSet) is DateTimeOffset at && at <= now - TimeSpan.FromDays(365)),
            new("pwdmustchange", "Changement de mot de passe demandé", "Mots de passe", SearchTypeFilter.Users,
                "pwdLastSet à zéro" + FrenchText.Colon + "changement imposé à la prochaine ouverture de session (compte neuf ou mot de passe réinitialisé). Listé à part des mots de passe anciens.",
                "(&" + Person + "(pwdLastSet=0))", Indexed,
                o => o is DirectoryUser u && u.PasswordLastSet == 0),
            new("recent", "Objets modifiés depuis 7 jours", "Objets", SearchTypeFilter.All, "whenChanged est propre à chaque contrôleur.",
                "(whenChanged>=" + recent + ")", Indexed,
                o => WhenChanged(o) is DateTimeOffset at && at >= now - TimeSpan.FromDays(7)),
            new("oucomputers", "Postes de cette OU", "Postes", SearchTypeFilter.Computers, "Périmètre" + FrenchText.Colon + "OU sélectionnée.",
                "(objectCategory=computer)", Category,
                o => o is DirectoryComputer),
            new("stalecomputers", "Postes sans connexion depuis 90 jours", "Postes", SearchTypeFilter.Computers,
                "Postes jamais connectés inclus. lastLogonTimestamp est approximatif (retard de réplication jusqu’à 14 jours). Aucun objet n’est déclaré supprimable.",
                "(&(objectCategory=computer)(|(lastLogonTimestamp<=" + inactive + ")(!(lastLogonTimestamp=*))))", Indexed,
                o => o is DirectoryComputer c && (AdValues.FromFileTime(c.LastLogonTimestamp) is not DateTimeOffset at || at <= now - Inactive)),
        ];
    }

    /// <summary>Delivered local queries on the workstations of the local base (readings dated, never guessed).</summary>
    public static ImmutableArray<SearchLocalQuery> LocalQueries { get; } =
    [
        new("local.nolaps", "Postes sans LAPS visible", "Sécurité des postes",
            "Postes sans date d’expiration LAPS lisible (ms-Mcs-AdmPwdExpirationTime, msLAPS-PasswordExpirationTime). Aucun mot de passe n’est lu.",
            (c, _, _) => c.Laps == LapsKind.None || c.LapsExpiration is null ? new(Match, "Aucune expiration LAPS lisible") : new(NoMatch, c.Laps == LapsKind.Windows ? "LAPS Windows" : "LAPS hérité")),
        new("local.lapsexpired", "Mot de passe LAPS expiré", "Sécurité des postes",
            "Date d’expiration LAPS passée" + FrenchText.Colon + "le mot de passe aurait dû être renouvelé par le poste. Aucun mot de passe n’est lu.",
            (c, _, now) => AdValues.FromFileTime(c.LapsExpiration) is DateTimeOffset at
                ? at <= now ? new(Match, "Expiré le " + Day(at)) : new(NoMatch, "Valable jusqu’au " + Day(at))
                : new(Unknown, "Aucune expiration LAPS lisible")),
        new("local.lowdisk", "Disque C presque plein (moins de 10 % libre)", "Matériel",
            "Relevé d’inventaire de moins de 30 jours. Un disque de taille nulle ou illisible est inconnu, jamais plein.",
            (_, o, now) => Disk(o, now, 10)),
        new("local.disk20", "Disque C sous 20 % libre", "Matériel",
            "Relevé d’inventaire de moins de 30 jours" + FrenchText.Colon + "moins de 20 % libre sur C:.",
            (_, o, now) => Disk(o, now, 20)),
        new("local.uptime", "Sans redémarrage depuis 30 jours", "Matériel",
            "Dernier démarrage relevé par l’inventaire de moins de 30 jours.",
            (_, o, now) => Inventory(o, now) is InventoryMeasure i && i.LastBootAt is DateTimeOffset boot
                ? now - boot >= TimeSpan.FromDays(30) ? new(Match, "Démarré le " + Day(boot)) : new(NoMatch, "Démarré le " + Day(boot))
                : new(Unknown, "Aucun relevé d’inventaire récent")),
        new("local.ram8", "Mémoire de 8 Go ou moins", "Matériel",
            "Mémoire relevée par l’inventaire de moins de 30 jours.",
            (_, o, now) => Inventory(o, now) is InventoryMeasure i && i.MemoryBytes is long bytes && bytes > 0
                ? bytes <= 8L << 30 ? new(Match, Gib(bytes)) : new(NoMatch, Gib(bytes))
                : new(Unknown, "Aucun relevé d’inventaire récent")),
        new("local.win10", "Windows 10 hors LTSC", "Systèmes",
            "Système déclaré dans l’annuaire (operatingSystem)" + FrenchText.Colon + "Windows 10 hors éditions LTSC, LTSB et IoT.",
            (c, _, _) => c.OperatingSystem is null ? new(Unknown, "Système non renseigné")
                : c.OperatingSystem.Contains("Windows 10", StringComparison.OrdinalIgnoreCase) && !c.OperatingSystem.Contains("LTS", StringComparison.OrdinalIgnoreCase)
                    && !c.OperatingSystem.Contains("IoT", StringComparison.OrdinalIgnoreCase)
                    ? new(Match, c.OperatingSystem) : new(NoMatch, c.OperatingSystem)),
        new("local.noreply", "Sans réponse au dernier relevé de présence", "Présence",
            "Relevé de présence de moins de 30 jours sans réponse au ping" + FrenchText.Colon + "une absence de réponse ne prouve pas qu’un poste est éteint.",
            (_, o, now) => o?.Presence is { HasReading: true, CheckedAt: DateTimeOffset at } p && now - at <= Fresh
                ? p.Answered == true ? new(NoMatch, "En ligne") : new(Match, "Sans réponse au ping")
                : new(Unknown, "Aucun relevé de présence récent")),
        new("local.neverread", "Jamais relevés", "Présence",
            "Postes sans aucun relevé de présence ni d’inventaire enregistré.",
            (_, o, _) => o is null || (!o.Presence.HasReading && !o.Inventory.HasReading && o.Presence.LastOnlineAt is null)
                ? new(Match, "Aucun relevé") : new(NoMatch, "Relevé enregistré")),
    ];

    /// <summary>Label of a verdict of a local query.</summary>
    public static string VerdictLabel(string verdict) => verdict switch
    {
        Match => "Correspond",
        NoMatch => "Ne correspond pas",
        _ => "Inconnu",
    };

    private static SearchLocalVerdict Disk(WorkstationObservation? observation, DateTimeOffset now, double threshold)
    {
        if (Inventory(observation, now) is not InventoryMeasure i || i.SystemDiskSizeBytes is not long size || size <= 0 || i.SystemDiskFreeBytes is not long free)
        {
            return new(Unknown, "Aucun relevé d’inventaire récent");
        }
        var percent = 100.0 * free / size;
        var text = FrenchText.Percent(percent) + " libre";
        return percent < threshold ? new(Match, text) : new(NoMatch, text);
    }

    private static InventoryMeasure? Inventory(WorkstationObservation? observation, DateTimeOffset now) =>
        observation?.Inventory is { HasReading: true, CheckedAt: DateTimeOffset at } inventory && now - at <= Fresh ? inventory : null;

    private static DateTimeOffset? WhenChanged(object record) => record switch
    {
        DirectoryUser u => u.WhenChanged,
        DirectoryComputer c => c.WhenChanged,
        DirectoryGroup g => g.WhenChanged,
        DirectoryOu ou => ou.WhenChanged,
        _ => null,
    };

    private static string Ft(DateTimeOffset at) => AdValues.ToFileTime(at).ToString(CultureInfo.InvariantCulture);

    private static string Day(DateTimeOffset at) => FrenchText.ShortDate(DateOnly.FromDateTime(at.UtcDateTime));

    private static string Gib(long bytes) => FrenchText.Integer((long)Math.Round(bytes / (double)(1L << 30))) + FrenchText.Nbsp + "Go";
}
