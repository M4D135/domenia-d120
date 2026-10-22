using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Domenia.Core;

/// <summary>Who the object is: kind, names, identifiers, dates and place (header of the fiche, FIC-039 « Résumé »).</summary>
public sealed record FicheIdentity(
    string Kind,
    string KindLabel,
    string Name,
    string Dn,
    string Guid,
    string? Sid,
    string? Sam,
    string? Upn,
    string ObjectClass,
    ImmutableArray<string> Classes,
    DateTimeOffset? Created,
    DateTimeOffset? Changed,
    long? Usn,
    string Path,
    string? ParentDn,
    string Initials,
    string Subtitle);

/// <summary>How the values shown were obtained (FIC-030, FIC-035): local base preview, fresh directory read or simulation.</summary>
public sealed record FicheOrigin(string Source, string Label, DateTimeOffset ReadAt, string? Controller, bool Preview, string Detail);

/// <summary>One state pill of the header.</summary>
public sealed record FicheState(string Id, string Tone, string Label, string Detail);

/// <summary>One value of a section (kit kvSection item), with an optional link to another fiche.</summary>
public sealed record FicheItem(string Key, string Label, string? Value, string? Sub, bool Mono, bool Copy, string? Tone, bool Wide, FicheLink? Link);

/// <summary>One section of the general tab.</summary>
public sealed record FicheSection(string Id, string Title, string Icon, ImmutableArray<FicheItem> Items);

/// <summary>One field the operator may edit (FIC-009): only fields that can be saved, with their current value.</summary>
public sealed record FicheField(string Attribute, string Label, string Group, string Type, string? Value, string? Display, int MaxLength, string? Hint);

/// <summary>Edit mode of the fiche: available or why not, and the fields.</summary>
public sealed record FicheEditor(bool Available, string? Reason, ImmutableArray<FicheField> Fields);

/// <summary>One security option of userAccountControl (FIC-015).</summary>
public sealed record FicheOption(string Id, string Label, int Flag, bool On, bool HighRisk, bool Advanced, string Detail);

/// <summary>Account of a user or a computer: state, lockout, password, expiry, logon activity and options (FIC-043, FIC-047).</summary>
public sealed record FicheAccount(
    string StateLabel,
    int? Uac,
    string UacLabel,
    bool? Disabled,
    string Lock,
    string LockLabel,
    DateTimeOffset? LockedAt,
    long? BadPasswordCount,
    DateTimeOffset? BadPasswordAt,
    DateTimeOffset? PasswordLastSet,
    bool MustChange,
    DateTimeOffset? PasswordExpires,
    string PasswordLabel,
    string PasswordTone,
    string? AccountExpires,
    bool AccountNeverExpires,
    string AccountExpiresLabel,
    string AccountExpiresTone,
    FicheLogonActivity Logon,
    ImmutableArray<FicheOption> Options,
    bool Protected,
    bool Computer);

/// <summary>Last known presence (FIC-046): the workstation itself, or the associated workstation of a user.</summary>
public sealed record FichePresenceView(string State, string Label, DateTimeOffset? CheckedAt, string? Computer, string? ComputerDn, string Detail);

/// <summary>One action of the fiche with its availability and the reason when it is greyed.</summary>
public sealed record FicheAction(string Id, string Label, string Kind, bool Available, string? Reason, bool Danger);

/// <summary>One tab of the fiche for this kind of object.</summary>
public sealed record FicheTab(string Id, string Label, int? Count);

/// <summary>Counts shown on the tabs and in the header.</summary>
public sealed record FicheCounts(int? Groups, int? Members, int? Children, int? Linked, int? Reports);

/// <summary>
/// Settings that the page needs to show and pre-check (FIC-001, FIC-014, FIC-036): forced password change by default, length of the
/// generated password, clipboard delay, raw writes, each setting with its provenance, and the usage profile of the freshness.
/// </summary>
public sealed record FicheSettingsSummary(
    bool ForcePasswordChange,
    int PasswordLength,
    int ClipboardSeconds,
    bool RawWrite,
    bool ContainerDelete,
    bool TypedDelete,
    ImmutableArray<FicheSettingView> Items,
    string FileText,
    string FreshnessText)
{
    public static FicheSettingsSummary Of(FicheSecurityPolicy policy, ImmutableArray<FicheSettingView> items, string fileText, FicheFreshnessTable table)
    {
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(table);
        return new FicheSettingsSummary(policy.ForcePasswordChangeOnReset, policy.GeneratedPasswordLength, policy.ClipboardClearSeconds, policy.AllowRawAttributeWrite,
            policy.AllowContainerDelete, policy.RequireTypedDeleteConfirmation, items.IsDefault ? [] : items, fileText, table.Text);
    }
}

/// <summary>Result of fiche.read and fiche.preview: the whole fiche of one object.</summary>
public sealed record FicheSheet(
    FicheIdentity Identity,
    FicheOrigin Origin,
    ImmutableArray<FicheState> States,
    FicheBand? Band,
    ImmutableArray<FicheSection> Sections,
    FicheEditor Edit,
    FicheAccount? Account,
    FicheCounts Counts,
    ImmutableArray<FicheFreshness> Freshness,
    FicheLink? Manager,
    ImmutableArray<FicheAssociation> Linked,
    FichePresenceView? Presence,
    ImmutableArray<FicheAction> Actions,
    ImmutableArray<FicheTab> Tabs,
    string Landing,
    string Summary,
    ImmutableArray<FicheFact> Support,
    string Signature,
    FicheSettingsSummary Settings);

/// <summary>What the sheet needs besides the entry: origin, clock, names of the linked objects and what writes are possible.</summary>
public sealed record FicheContext(
    string Source,
    DateTimeOffset ReadAt,
    string? Controller,
    bool Preview,
    DateTimeOffset Now,
    TimeZoneInfo Zone,
    string RootDn,
    IReadOnlyDictionary<string, FicheSummary> Index,
    ImmutableArray<FicheAssociation> Associations,
    FicheObservation? Observation,
    int? Children,
    int? Reports,
    bool Writes,
    string? WritesReason,
    FicheLogonInterval Interval,
    FicheSecurityPolicy Policy,
    FicheFreshnessTable? Table = null,
    IReadOnlyDictionary<string, DateTimeOffset>? Attempts = null,
    DateTimeOffset? HistoryReadAt = null,
    ImmutableArray<FicheSettingView> SettingItems = default,
    string SettingsText = "");

/// <summary>
/// Builds the fiche of one object from its entry (Domenia 1 Fill-UserObject, Fill-ComputerObject, Fill-GroupObject,
/// Fill-ContainerObject, Fill-GenericObject, Set-VisibleTabsForType, Get-DomeniaLandingView, Update-DomeniaUserSupportBand). Pure.
/// </summary>
public static class FicheSheets
{
    private static readonly string C = FrenchText.Colon;

    /// <summary>Tabs ids, in display order.</summary>
    public static readonly ImmutableArray<string> TabIds = ["general", "compte", "groupes", "membres", "relations", "droits", "attributs", "historique", "appel"];

    private static readonly (int Flag, string Id, string Label, bool HighRisk, bool Advanced, string Detail)[] UserOptions =
    [
        (0x10000, "passwordNeverExpires", "Le mot de passe n’expire jamais", false, false, "Le compte ignore la durée de validité de la stratégie."),
        (0x40000, "smartcardRequired", "Carte à puce obligatoire", false, false, "Le mot de passe ne permet plus d’ouvrir une session interactive."),
        (0x100000, "notDelegated", "Le compte est sensible et ne peut pas être délégué", false, false, "Protège les comptes à privilèges contre la délégation Kerberos."),
        (0x20, "passwordNotRequired", "Mot de passe non requis", true, true, "Un mot de passe vide peut être accepté."),
        (0x80, "reversibleEncryption", "Chiffrement réversible du mot de passe", true, true, "Le mot de passe est stocké de façon récupérable."),
        (0x400000, "noPreAuth", "Pré-authentification Kerberos facultative", true, true, "Expose le compte au « AS-REP roasting »."),
        (0x200000, "desOnly", "Chiffrement DES uniquement", true, true, "Algorithme obsolète, déconseillé."),
        (0x80000, "trustedForDelegation", "Délégation approuvée (non contrainte)", true, true, "Le compte peut emprunter l’identité de tout utilisateur qui s’y connecte."),
        (0x1000000, "trustedToAuthForDelegation", "Délégation contrainte avec transition de protocole", true, true, "Le compte peut obtenir des tickets au nom d’autres utilisateurs."),
    ];

    /// <summary>Options of userAccountControl the fiche can change, with their flag (FIC-015).</summary>
    public static ImmutableArray<(int Flag, string Id, string Label, bool HighRisk)> OptionFlags { get; } =
        [.. UserOptions.Select(o => (o.Flag, o.Id, o.Label, o.HighRisk))];

    /// <summary>Kind of a fiche in the contract (« user », « computer »…).</summary>
    public static string KindId(FicheKind kind) => FicheMemberships.KindId(kind);

    /// <summary>« Compte utilisateur », « Poste de travail », « Serveur »…</summary>
    public static string KindLabel(FicheEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        switch (entry.Kind)
        {
            case FicheKind.User:
                return "Compte utilisateur";
            case FicheKind.Computer:
                var uac = entry.Int32("userAccountControl") ?? 0;
                if (AdValues.HasFlag(uac, AdValues.ServerTrustAccount))
                {
                    return "Contrôleur de domaine";
                }
                var os = entry.First("operatingSystem") ?? "";
                return os.Contains("Server", StringComparison.OrdinalIgnoreCase) ? "Serveur" : "Poste de travail";
            case FicheKind.Group:
                return entry.Int32("groupType") is int groupType ? FicheMemberships.GroupTypeLabel(groupType) : "Groupe";
            case FicheKind.Ou:
                return "Unité d’organisation";
            case FicheKind.Contact:
                return "Contact";
            default:
                return entry.Dn.StartsWith("DC=", StringComparison.OrdinalIgnoreCase) ? "Domaine" : "Conteneur";
        }
    }

    /// <summary>Builds the fiche.</summary>
    public static FicheSheet Build(FicheEntry entry, FicheContext context)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(context);
        var zone = context.Zone;
        var now = context.Now;
        var identity = Identity(entry, context);
        var origin = Origin(context);
        var account = entry.Kind is FicheKind.User or FicheKind.Computer ? Account(entry, context) : null;
        var managerDn = entry.First(entry.Kind is FicheKind.User or FicheKind.Contact ? "manager" : "managedBy");
        var manager = managerDn is null ? null : LinkOf(managerDn, context.Index);
        var presence = Presence(entry, context);
        var states = States(entry, account, presence, context);
        var band = context.Preview ? null : FicheDiagnostics.Band(entry, now, zone);
        var counts = new FicheCounts(
            entry.Kind is FicheKind.User or FicheKind.Computer or FicheKind.Group or FicheKind.Contact ? entry.All("memberOf").Length : null,
            entry.Kind == FicheKind.Group ? entry.All("member").Length : null,
            context.Children,
            context.Associations.Length,
            context.Reports);
        var sections = Sections(entry, account, context);
        var edit = Editor(entry, context);
        var actions = Actions(entry, account, context);
        var tabs = Tabs(entry, counts);
        var freshness = Freshness(entry, context);
        var support = entry.Kind == FicheKind.User ? FicheDiagnostics.Support(entry, origin.Label, now, zone, context.Controller, context.ReadAt) : [];
        var table = context.Table ?? FicheFreshnessTable.Standard;
        return new FicheSheet(identity, origin, states, band, sections, edit, account, counts, freshness, manager, context.Associations, presence, actions, tabs,
            Landing(entry), Summary(identity, presence, zone), support, Signature(entry, context),
            FicheSettingsSummary.Of(context.Policy, context.SettingItems, context.SettingsText, table));
    }

    /// <summary>
    /// Tab the fiche opens on (Get-DomeniaLandingView, UX-27: open on what is read first): a user on its identity, a computer on its
    /// overview, a group on its members (Domenia 1 TabGroup), an OU or a container on its content (TabContainer), anything else on
    /// the summary of the general tab.
    /// </summary>
    public static string Landing(FicheEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        return entry.Kind switch
        {
            FicheKind.Group => "membres",
            FicheKind.Ou => "membres",
            FicheKind.Container when !entry.Dn.StartsWith("DC=", StringComparison.OrdinalIgnoreCase) => "membres",
            _ => "general",
        };
    }

    private static FicheIdentity Identity(FicheEntry entry, FicheContext context)
    {
        var classes = entry.All("objectClass");
        var name = entry.Kind is FicheKind.User or FicheKind.Contact ? entry.First("displayName") ?? entry.Name : entry.Name;
        var subtitle = entry.Kind switch
        {
            FicheKind.User or FicheKind.Contact => string.Join(" · ", new[] { entry.First("title"), entry.First("department"), entry.First("physicalDeliveryOfficeName") ?? entry.First("company") }.Where(s => !string.IsNullOrWhiteSpace(s))),
            FicheKind.Computer => string.Join(" · ", new[] { WindowsRelease.Describe(entry.First("operatingSystem"), entry.First("operatingSystemVersion"))?.Label ?? entry.First("operatingSystem"), entry.First("location") }.Where(s => !string.IsNullOrWhiteSpace(s))),
            FicheKind.Group => entry.First("description") ?? "",
            _ => entry.First("description") ?? "",
        };
        if (subtitle.Length == 0)
        {
            subtitle = FicheValues.ReadablePath(entry.Dn);
        }
        return new FicheIdentity(KindId(entry.Kind), KindLabel(entry), name, entry.Dn, entry.ObjectGuid.ToString("D"), entry.First("objectSid"), entry.First("sAMAccountName"),
            entry.First("userPrincipalName"), classes.Length > 0 ? classes[^1] : KindId(entry.Kind), classes, entry.Generalized("whenCreated"), entry.Generalized("whenChanged"),
            entry.Int64("uSNChanged"), FicheValues.ReadablePath(entry.Dn), DistinguishedName.Parent(entry.Dn), FicheValues.Initials(name), subtitle);
    }

    private static FicheOrigin Origin(FicheContext context)
    {
        var zone = context.Zone;
        var at = FicheValues.LocalDateTime(context.ReadAt, zone);
        return context.Source switch
        {
            "baseLocale" => new FicheOrigin("baseLocale", "Base locale", context.ReadAt, context.Controller, true,
                "Valeurs du " + at + ", relecture en cours" + C + "aucune écriture ni sonde tant que la lecture de l’annuaire n’est pas arrivée."),
            "simulation" => new FicheOrigin("simulation", "Annuaire fictif", context.ReadAt, context.Controller, false,
                "Lu dans l’annuaire fictif (simulation) le " + at + (context.Controller is null ? "" : ", comme le ferait " + context.Controller) + "."),
            _ => new FicheOrigin("annuaire", "Annuaire", context.ReadAt, context.Controller, false,
                "Lu sur " + (context.Controller ?? "le contrôleur") + " le " + at + "."),
        };
    }

    private static FicheLink LinkOf(string dn, IReadOnlyDictionary<string, FicheSummary> index) =>
        index.TryGetValue(dn, out var known)
            ? new FicheLink(known.Dn, known.Name, KindId(known.Kind), known.Detail)
            : new FicheLink(dn, FicheValues.DisplayName(dn), "unknown", null);

    private static FicheAccount Account(FicheEntry entry, FicheContext context)
    {
        var zone = context.Zone;
        var now = context.Now;
        var uac = entry.Int32("userAccountControl");
        var computed = entry.Int32("msDS-User-Account-Control-Computed");
        var lockout = entry.Int64("lockoutTime");
        var state = AccountState.Evaluate(uac ?? 0, computed, lockout);
        var isComputer = entry.Kind == FicheKind.Computer;
        var lockedAt = entry.FileTime("lockoutTime");
        string lockId, lockLabel;
        if (isComputer)
        {
            (lockId, lockLabel) = ("unlocked", "Sans objet pour un ordinateur");
        }
        else if (computed is null && lockout is > 0)
        {
            (lockId, lockLabel) = ("toCheck", "Verrouillage à vérifier" + C + "état calculé du contrôleur non lu");
        }
        else if (state.Lock == LockState.Locked)
        {
            (lockId, lockLabel) = ("locked", lockedAt is DateTimeOffset at ? "Verrouillé depuis le " + FicheValues.LocalDateTime(at, zone) : "Verrouillé");
        }
        else if (lockout is > 0 && lockedAt is DateTimeOffset expired)
        {
            (lockId, lockLabel) = ("expired", "Non verrouillé (verrouillage du " + FicheValues.LocalDateTime(expired, zone) + " expiré)");
        }
        else
        {
            (lockId, lockLabel) = ("unlocked", "Non verrouillé");
        }
        var pwdLastSet = entry.FileTime("pwdLastSet");
        var mustChange = !isComputer && entry.Int64("pwdLastSet") == 0;
        var expires = isComputer ? null : FicheDiagnostics.PasswordExpiry(entry);
        string passwordLabel;
        string passwordTone;
        if (isComputer)
        {
            var age = pwdLastSet is DateTimeOffset set ? (int)Math.Floor((now - set).TotalDays) : (int?)null;
            passwordLabel = pwdLastSet is DateTimeOffset p ? "Mot de passe machine renouvelé le " + FicheValues.LocalDate(p, zone) + " (il y a " + FrenchText.Count(age ?? 0, "jour", "jours") + ")" : "Date du mot de passe machine non lue";
            passwordTone = age > 60 ? "warn" : "ok";
        }
        else if (mustChange)
        {
            (passwordLabel, passwordTone) = ("À changer à la prochaine ouverture de session", "warn");
        }
        else if (state.PasswordNeverExpires)
        {
            (passwordLabel, passwordTone) = ("N’expire jamais (option du compte)", "info");
        }
        else if (computed is int c && AdValues.HasFlag(c, AdValues.PasswordExpired))
        {
            (passwordLabel, passwordTone) = (expires is DateTimeOffset e0 ? "Expiré depuis le " + FicheValues.LocalDateTime(e0, zone) : "Expiré", "alert");
        }
        else if (expires is DateTimeOffset e)
        {
            var days = (int)Math.Ceiling((e - now).TotalDays);
            (passwordLabel, passwordTone) = days <= 0
                ? ("Expiré depuis le " + FicheValues.LocalDateTime(e, zone), "alert")
                : ("Expire le " + FicheValues.LocalDateTime(e, zone) + " (dans " + FrenchText.Count(days, "jour", "jours") + ")", days <= 14 ? "warn" : "ok");
        }
        else if (entry.Int64("msDS-UserPasswordExpiryTimeComputed") == AdValues.Never)
        {
            (passwordLabel, passwordTone) = ("N’expire pas", "info");
        }
        else
        {
            (passwordLabel, passwordTone) = ("Échéance non calculée par le contrôleur", "off");
        }
        var accountRaw = entry.Int64("accountExpires");
        var accountAt = entry.FileTime("accountExpires");
        var neverExpires = accountRaw is null or 0 or AdValues.Never || accountAt is null;
        string accountLabel;
        string accountTone;
        if (neverExpires)
        {
            (accountLabel, accountTone) = ("N’expire jamais", "off");
        }
        else if (accountAt!.Value <= now)
        {
            (accountLabel, accountTone) = ("Expiré depuis le " + FicheValues.LocalDate(accountAt.Value, zone), "alert");
        }
        else
        {
            var days = (int)Math.Ceiling((accountAt.Value - now).TotalDays);
            (accountLabel, accountTone) = ("Expire le " + FicheValues.LocalDate(accountAt.Value, zone) + " (dans " + FrenchText.Count(days, "jour", "jours") + ")", days <= 7 ? "warn" : "info");
        }
        // Same reading as Domenia 1 (Set-ADAccountExpiration -DateTime): the local day of accountExpires is the expiry day.
        var accountDay = neverExpires ? null : FicheValues.LocalDay(accountAt!.Value, zone).ToString("yyyy'-'MM'-'dd", CultureInfo.InvariantCulture);
        var logon = FicheDiagnostics.Activity(entry.FileTime("lastLogonTimestamp"), context.Interval, now, zone);
        var options = isComputer
            ? ImmutableArray<FicheOption>.Empty
            : [.. UserOptions.Select(o => new FicheOption(o.Id, o.Label, o.Flag, uac is int u && AdValues.HasFlag(u, o.Flag), o.HighRisk, o.Advanced, o.Detail))];
        return new FicheAccount(FicheAttributeRules.UacStatusLabel(uac, computed, lockout), uac, uac is int value ? FicheAttributeRules.UacFlagsLabel(value) : "Options non déterminées",
            uac is int d ? AdValues.IsDisabled(d) : null, lockId, lockLabel, lockedAt, entry.Int64("badPwdCount"), entry.FileTime("badPasswordTime"), pwdLastSet, mustChange, expires,
            passwordLabel, passwordTone, accountDay, neverExpires, accountLabel, accountTone, logon, options, entry.Int32("adminCount") == 1, isComputer);
    }

    private static FichePresenceView? Presence(FicheEntry entry, FicheContext context)
    {
        if (entry.Kind is not (FicheKind.User or FicheKind.Computer))
        {
            return null;
        }
        var observation = context.Observation;
        var zone = context.Zone;
        if (entry.Kind == FicheKind.User && context.Associations.Length == 0)
        {
            return new FichePresenceView("unknown", "Aucun poste associé", null, null, null,
                "Un compte n’a pas d’adresse" + C + "la présence se mesure sur son poste associé, et aucun n’est connu de Domenia.");
        }
        if (observation is null)
        {
            return new FichePresenceView("unknown", "Présence non relevée", null, null, null, "Aucun relevé de présence enregistré.");
        }
        var via = entry.Kind == FicheKind.User ? " (poste associé " + observation.Computer + ")" : "";
        if (observation.PresenceState != MeasureState.Known || observation.Answered is null || observation.PresenceAt is null)
        {
            return new FichePresenceView("unknown", "Présence non relevée" + via, observation.PresenceAt, observation.Computer, observation.ComputerDn,
                "Le dernier relevé n’a pas donné de réponse exploitable" + C + "« Vérifier la présence » lance un ping.");
        }
        var at = observation.PresenceAt.Value;
        var stale = (context.Now - at).TotalMinutes > 2;
        var online = observation.Answered == true;
        var label = (online ? "En ligne" : "Sans réponse au ping") + via;
        var detail = "Relevé du " + FicheValues.LocalDateTime(at, zone) + (stale ? " (à relire" + C + "plus de 2 min)" : "") + ".";
        if (!online && observation.LastOnlineAt is DateTimeOffset seen)
        {
            detail += " Dernière réponse le " + FicheValues.LocalDateTime(seen, zone) + ".";
        }
        return new FichePresenceView(stale ? "stale" : online ? "online" : "offline", label, at, observation.Computer, observation.ComputerDn, detail);
    }

    private static ImmutableArray<FicheState> States(FicheEntry entry, FicheAccount? account, FichePresenceView? presence, FicheContext context)
    {
        var states = new List<FicheState>();
        var now = context.Now;
        if (context.Preview)
        {
            states.Add(new FicheState("preview", "info", "Aperçu local", "Valeurs de la base locale ; la lecture de l’annuaire les remplace dès son arrivée."));
        }
        if (account is not null)
        {
            if (account.Disabled == true)
            {
                states.Add(new FicheState("disabled", "alert", "Désactivé", "Le compte ne peut pas ouvrir de session."));
            }
            else if (account.Disabled == false)
            {
                states.Add(new FicheState("enabled", "ok", "Activé", "Lu dans userAccountControl."));
            }
            switch (account.Lock)
            {
                case "locked":
                    states.Add(new FicheState("locked", "alert", "Verrouillé", account.LockLabel));
                    break;
                case "toCheck":
                    states.Add(new FicheState("lockCheck", "warn", "Verrouillage à vérifier", account.LockLabel));
                    break;
            }
            if (!account.Computer)
            {
                if (account.PasswordTone == "alert")
                {
                    states.Add(new FicheState("passwordExpired", "alert", "Mot de passe expiré", account.PasswordLabel));
                }
                else if (account.MustChange)
                {
                    states.Add(new FicheState("mustChange", "warn", "Mot de passe à changer", account.PasswordLabel));
                }
                else if (account.PasswordTone == "warn")
                {
                    states.Add(new FicheState("passwordExpiring", "warn", "Mot de passe bientôt expiré", account.PasswordLabel));
                }
                else if (account.Options.Any(o => o.Id == "passwordNeverExpires" && o.On))
                {
                    states.Add(new FicheState("neverExpires", "info", "Mot de passe sans expiration", account.PasswordLabel));
                }
            }
            else if (account.PasswordTone == "warn")
            {
                states.Add(new FicheState("machinePassword", "warn", "Mot de passe machine ancien", account.PasswordLabel));
            }
            if (account.AccountExpiresTone is "alert" or "warn")
            {
                states.Add(new FicheState("accountExpires", account.AccountExpiresTone, account.AccountExpiresTone == "alert" ? "Compte expiré" : "Expire bientôt", account.AccountExpiresLabel));
            }
            if (account.Logon.Badge is string badge && account.Logon.BadgeTone == "warn")
            {
                states.Add(new FicheState("inactive", "warn", badge, account.Logon.Text));
            }
            if (account.Protected)
            {
                states.Add(new FicheState("protected", "accent", "Compte à privilèges", "adminCount = 1" + C + "objet protégé par AdminSDHolder ; écritures restreintes."));
            }
        }
        if (presence is not null && entry.Kind == FicheKind.Computer && presence.State is "online" or "offline" or "stale")
        {
            states.Add(new FicheState("presence", presence.State == "online" ? "ok" : presence.State == "stale" ? "off" : "warn", presence.Label, presence.Detail));
        }
        if (entry.Kind == FicheKind.Computer && entry.FileTime("msLAPS-PasswordExpirationTime") is DateTimeOffset laps && laps < now)
        {
            states.Add(new FicheState("lapsExpired", "warn", "LAPS expiré", "Expiration du mot de passe LAPS dépassée (date seulement, aucun secret lu)."));
        }
        if (entry.Kind == FicheKind.Group && entry.Int32("groupType") is int groupType)
        {
            states.Add(new FicheState("category", FicheMemberships.Category(groupType) == "security" ? "info" : "off", FicheMemberships.Category(groupType) == "security" ? "Sécurité" : "Distribution", FicheMemberships.GroupTypeLabel(groupType)));
            if (FicheMemberships.IsPrivileged(entry.Name, entry.First("objectSid"), entry.Int32("adminCount")))
            {
                states.Add(new FicheState("privileged", "accent", "Groupe à privilèges", "Toute attribution se décide et se justifie au cas par cas."));
            }
        }
        if (entry.Kind == FicheKind.Ou && entry.All("gPLink").Length > 0)
        {
            var count = (entry.First("gPLink") ?? "").Split('[', StringSplitOptions.RemoveEmptyEntries).Length;
            states.Add(new FicheState("gpo", "info", FrenchText.Count(count, "stratégie liée", "stratégies liées"), "Attribut gPLink de l’OU."));
        }
        if (string.Equals(entry.First("isCriticalSystemObject"), "TRUE", StringComparison.OrdinalIgnoreCase))
        {
            states.Add(new FicheState("critical", "accent", "Objet système", "isCriticalSystemObject" + C + "objet indispensable au domaine."));
        }
        return [.. states];
    }

    private static FicheItem Item(string key, string label, string? value, string? sub = null, bool mono = false, bool copy = false, string? tone = null, bool wide = false, FicheLink? link = null) =>
        new(key, label, string.IsNullOrWhiteSpace(value) ? null : value, sub, mono, copy && !string.IsNullOrWhiteSpace(value), tone, wide, link);

    private static ImmutableArray<FicheSection> Sections(FicheEntry e, FicheAccount? account, FicheContext context)
    {
        var zone = context.Zone;
        var sections = new List<FicheSection>();
        FicheLink? Link(string attribute) => e.First(attribute) is string dn ? LinkOf(dn, context.Index) : null;
        string? Date(string attribute) => e.Generalized(attribute) is DateTimeOffset at ? FicheValues.LocalDateTime(at, zone) : null;
        switch (e.Kind)
        {
            case FicheKind.User:
            case FicheKind.Contact:
                sections.Add(new FicheSection("identite", "Identité", "user",
                [
                    Item("displayName", "Nom affiché", e.First("displayName") ?? e.Name),
                    Item("givenName", "Prénom", e.First("givenName")),
                    Item("sn", "Nom", e.First("sn")),
                    .. e.Kind == FicheKind.User
                        ? new[]
                        {
                            Item("sAMAccountName", "Identifiant", e.First("sAMAccountName"), mono: true, copy: true),
                            Item("userPrincipalName", "Nom de connexion", e.First("userPrincipalName"), mono: true, copy: true),
                            Item("employeeID", "Matricule", e.First("employeeID"), mono: true),
                        }
                        : [],
                ]));
                var manager = Link("manager");
                sections.Add(new FicheSection("organisation", "Organisation", "users",
                [
                    Item("title", "Fonction", e.First("title")),
                    Item("department", "Service", e.First("department")),
                    Item("company", "Société", e.First("company")),
                    Item("physicalDeliveryOfficeName", "Bureau", e.First("physicalDeliveryOfficeName")),
                    Item("manager", "Responsable", manager?.Name, manager?.Detail, link: manager),
                    Item("description", "Description", e.First("description"), wide: true),
                ]));
                var address = string.Join(", ", new[] { e.First("streetAddress"), string.Join(" ", new[] { e.First("postalCode"), e.First("l") }.Where(s => !string.IsNullOrWhiteSpace(s))) }.Where(s => !string.IsNullOrWhiteSpace(s)));
                sections.Add(new FicheSection("coordonnees", "Coordonnées", "link",
                [
                    Item("mail", "Messagerie", e.First("mail"), mono: true, copy: true),
                    Item("telephoneNumber", "Téléphone", e.First("telephoneNumber"), copy: true),
                    Item("mobile", "Mobile", e.First("mobile"), copy: true),
                    Item("ipPhone", "Téléphone IP", e.First("ipPhone")),
                    Item("address", "Adresse", address.Length == 0 ? null : address, e.First("st") is string region ? region + (e.First("co") is string co ? " · " + co : "") : e.First("co"), wide: true),
                    Item("wWWHomePage", "Page web", e.First("wWWHomePage"), mono: true),
                ]));
                if (e.Kind == FicheKind.User)
                {
                    var drive = e.First("homeDrive");
                    sections.Add(new FicheSection("profil", "Profil et ouverture de session", "monitor",
                    [
                        Item("homeDirectory", "Dossier de base", e.First("homeDirectory"), drive is null ? null : "Lecteur " + drive, mono: true, copy: true, wide: true),
                        Item("profilePath", "Chemin du profil", e.First("profilePath"), mono: true, wide: true),
                        Item("scriptPath", "Script de connexion", e.First("scriptPath"), mono: true),
                        Item("userWorkstations", "Postes autorisés", e.First("userWorkstations") ?? "Tous les postes", mono: e.Has("userWorkstations")),
                        Item("logonHours", "Heures de connexion", FicheCallSheets.LogonHours(e.First("logonHours"), true, (int)zone.GetUtcOffset(context.Now).TotalMinutes, context.Now).Summary, wide: true),
                    ]));
                }
                break;
            case FicheKind.Computer:
                var release = WindowsRelease.Describe(e.First("operatingSystem"), e.First("operatingSystemVersion"));
                var managedBy = Link("managedBy");
                var laps = e.FileTime("msLAPS-PasswordExpirationTime") ?? e.FileTime("ms-Mcs-AdmPwdExpirationTime");
                sections.Add(new FicheSection("systeme", "Système", "monitor",
                [
                    Item("operatingSystem", "Système d’exploitation", e.First("operatingSystem"), release?.Label),
                    Item("operatingSystemVersion", "Version", e.First("operatingSystemVersion"), mono: true),
                    Item("dNSHostName", "Nom DNS", e.First("dNSHostName"), mono: true, copy: true),
                    Item("sAMAccountName", "Compte machine", e.First("sAMAccountName"), mono: true, copy: true),
                ]));
                sections.Add(new FicheSection("gestion", "Gestion", "users",
                [
                    Item("description", "Description", e.First("description"), wide: true),
                    Item("location", "Emplacement", e.First("location")),
                    Item("managedBy", "Responsable", managedBy?.Name, managedBy?.Detail, link: managedBy),
                    Item("laps", "Mot de passe LAPS", laps is DateTimeOffset l ? "Expire le " + FicheValues.LocalDateTime(l, zone) : "Aucune expiration visible",
                        "Date seulement" + C + "aucun mot de passe n’est lu.", tone: laps is DateTimeOffset le && le < context.Now ? "warn" : null),
                ]));
                break;
            case FicheKind.Group:
                var groupType = e.Int32("groupType");
                var owner = Link("managedBy");
                sections.Add(new FicheSection("groupe", "Groupe", "group",
                [
                    Item("name", "Nom", e.Name),
                    Item("sAMAccountName", "Nom pré-Windows 2000", e.First("sAMAccountName"), mono: true, copy: true),
                    Item("groupType", "Type", groupType is int gt ? FicheMemberships.GroupTypeLabel(gt) : null),
                    Item("mail", "Messagerie", e.First("mail"), mono: true, copy: true),
                    Item("managedBy", "Géré par", owner?.Name, owner?.Detail, link: owner),
                    Item("member", "Membres directs", FrenchText.Integer(e.All("member").Length), "Attribut member, lu par plages"),
                    Item("description", "Description", e.First("description"), wide: true),
                ]));
                break;
            default:
                var ouOwner = Link("managedBy");
                sections.Add(new FicheSection("branche", e.Kind == FicheKind.Ou ? "Unité d’organisation" : "Conteneur", "folder",
                [
                    Item("name", "Nom", e.Name),
                    Item("description", "Description", e.First("description"), wide: true),
                    Item("managedBy", "Géré par", ouOwner?.Name, ouOwner?.Detail, link: ouOwner),
                    Item("children", "Objets directs", context.Children is int n ? FrenchText.Integer(n) : null),
                    Item("gPLink", "Stratégies liées", e.Has("gPLink") ? FrenchText.Integer((e.First("gPLink") ?? "").Split('[', StringSplitOptions.RemoveEmptyEntries).Length) : "Aucune"),
                ]));
                break;
        }
        sections.Add(new FicheSection("objet", "Objet", "object",
        [
            Item("objectClass", "Classe", string.Join(", ", e.All("objectClass")), mono: true),
            Item("objectGUID", "GUID", e.ObjectGuid.ToString("D"), mono: true, copy: true),
            Item("objectSid", "SID", e.First("objectSid"), mono: true, copy: true),
            Item("whenCreated", "Créé le", Date("whenCreated")),
            Item("whenChanged", "Modifié le", Date("whenChanged")),
            Item("uSNChanged", "USN", e.First("uSNChanged"), mono: true),
            Item("distinguishedName", "Chemin (DN)", e.Dn, mono: true, copy: true, wide: true),
        ]));
        return [.. sections.Select(s => s with { Items = [.. s.Items.Where(i => i.Value is not null || i.Key is "manager" or "managedBy" or "description" or "mail" or "telephoneNumber")] })];
    }

    private static readonly (string Attribute, string Label, string Group, string Type, int Max, string? Hint)[] UserFields =
    [
        ("givenName", "Prénom", "identite", "text", 64, null),
        ("sn", "Nom", "identite", "text", 64, null),
        ("displayName", "Nom affiché", "identite", "text", 256, null),
        ("userPrincipalName", "Nom de connexion (UPN)", "identite", "upn", 256, "Forme identifiant@domaine"),
        ("title", "Fonction", "organisation", "text", 128, null),
        ("department", "Service", "organisation", "text", 64, null),
        ("company", "Société", "organisation", "text", 64, null),
        ("physicalDeliveryOfficeName", "Bureau", "organisation", "text", 128, null),
        ("manager", "Responsable", "organisation", "dn", 2048, "Choisi dans l’annuaire"),
        ("description", "Description", "organisation", "multiline", 1024, null),
        ("mail", "Messagerie", "coordonnees", "email", 256, null),
        ("telephoneNumber", "Téléphone", "coordonnees", "phone", 64, null),
        ("mobile", "Mobile", "coordonnees", "phone", 64, null),
        ("homePhone", "Téléphone domicile", "coordonnees", "phone", 64, null),
        ("facsimileTelephoneNumber", "Télécopie", "coordonnees", "phone", 64, null),
        ("ipPhone", "Téléphone IP", "coordonnees", "phone", 64, null),
        ("wWWHomePage", "Page web", "coordonnees", "text", 2048, null),
        ("streetAddress", "Adresse", "coordonnees", "multiline", 1024, null),
        ("postalCode", "Code postal", "coordonnees", "text", 40, null),
        ("l", "Ville", "coordonnees", "text", 128, null),
        ("st", "Région", "coordonnees", "text", 128, null),
        ("co", "Pays", "coordonnees", "text", 128, null),
        ("employeeID", "Matricule", "profil", "text", 16, null),
        ("profilePath", "Chemin du profil", "profil", "text", 260, "Chemin UNC, par exemple \\\\serveur\\partage\\profil"),
        ("scriptPath", "Script de connexion", "profil", "text", 260, null),
        ("homeDirectory", "Dossier de base", "profil", "text", 260, "Chemin UNC, par exemple \\\\serveur\\partage\\dossier"),
        ("homeDrive", "Lecteur du dossier de base", "profil", "drive", 3, "Une lettre suivie de deux-points, par exemple H:"),
        ("userWorkstations", "Postes autorisés", "profil", "text", 1024, "Noms NetBIOS séparés par des virgules ; vide = tous"),
    ];

    private static readonly (string Attribute, string Label, string Group, string Type, int Max, string? Hint)[] ComputerFields =
    [
        ("description", "Description", "gestion", "multiline", 1024, null),
        ("location", "Emplacement", "gestion", "text", 1024, null),
        ("managedBy", "Responsable", "gestion", "dn", 2048, "Choisi dans l’annuaire"),
    ];

    private static readonly (string Attribute, string Label, string Group, string Type, int Max, string? Hint)[] GroupFields =
    [
        ("description", "Description", "groupe", "multiline", 1024, null),
        ("mail", "Messagerie", "groupe", "email", 256, null),
        ("managedBy", "Géré par", "groupe", "dn", 2048, "Choisi dans l’annuaire"),
    ];

    private static readonly (string Attribute, string Label, string Group, string Type, int Max, string? Hint)[] OuFields =
    [
        ("description", "Description", "branche", "multiline", 1024, null),
        ("managedBy", "Géré par", "branche", "dn", 2048, "Choisi dans l’annuaire"),
    ];

    private static readonly (string Attribute, string Label, string Group, string Type, int Max, string? Hint)[] ContactFields =
    [
        ("givenName", "Prénom", "identite", "text", 64, null),
        ("sn", "Nom", "identite", "text", 64, null),
        ("displayName", "Nom affiché", "identite", "text", 256, null),
        ("title", "Fonction", "organisation", "text", 128, null),
        ("department", "Service", "organisation", "text", 64, null),
        ("company", "Société", "organisation", "text", 64, null),
        ("physicalDeliveryOfficeName", "Bureau", "organisation", "text", 128, null),
        ("description", "Description", "organisation", "multiline", 1024, null),
        ("mail", "Messagerie", "coordonnees", "email", 256, null),
        ("telephoneNumber", "Téléphone", "coordonnees", "phone", 64, null),
        ("mobile", "Mobile", "coordonnees", "phone", 64, null),
    ];

    /// <summary>Attributes the fiche may save for a kind of object, with their maximum length (the update plan checks them again).</summary>
    public static IReadOnlyDictionary<string, int> EditableAttributes(FicheKind kind)
    {
        var fields = kind switch
        {
            FicheKind.User => UserFields,
            FicheKind.Computer => ComputerFields,
            FicheKind.Group => GroupFields,
            FicheKind.Ou or FicheKind.Container => OuFields,
            _ => ContactFields,
        };
        return fields.ToDictionary(f => f.Attribute, f => f.Max, StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>Label of an editable attribute (plans and receipts).</summary>
    public static string FieldLabel(FicheKind kind, string attribute)
    {
        var fields = kind switch
        {
            FicheKind.User => UserFields,
            FicheKind.Computer => ComputerFields,
            FicheKind.Group => GroupFields,
            FicheKind.Ou or FicheKind.Container => OuFields,
            _ => ContactFields,
        };
        return fields.FirstOrDefault(f => string.Equals(f.Attribute, attribute, StringComparison.OrdinalIgnoreCase)).Label ?? attribute;
    }

    private static FicheEditor Editor(FicheEntry entry, FicheContext context)
    {
        var fields = entry.Kind switch
        {
            FicheKind.User => UserFields,
            FicheKind.Computer => ComputerFields,
            FicheKind.Group => GroupFields,
            FicheKind.Ou => OuFields,
            FicheKind.Contact => ContactFields,
            _ => [],
        };
        var list = fields.Select(f =>
        {
            var value = entry.First(f.Attribute);
            var display = f.Type == "dn" && value is not null ? LinkOf(value, context.Index).Name : null;
            return new FicheField(f.Attribute, f.Label, f.Group, f.Type, value, display, f.Max, f.Hint);
        }).ToImmutableArray();
        var reason = WriteReason(context);
        if (reason is null && entry.Kind == FicheKind.Container)
        {
            reason = "Les conteneurs par défaut ne se modifient pas depuis la fiche.";
        }
        return new FicheEditor(reason is null && list.Length > 0, reason, list);
    }

    private static string? WriteReason(FicheContext context)
    {
        if (context.Preview)
        {
            return "Aperçu de la base locale" + C + "les écritures attendent la lecture de l’annuaire.";
        }
        return context.Writes ? null : context.WritesReason ?? "Écritures non disponibles dans ce mode.";
    }

    private static ImmutableArray<FicheAction> Actions(FicheEntry entry, FicheAccount? account, FicheContext context)
    {
        var actions = new List<FicheAction>();
        var write = WriteReason(context);
        var isProtected = entry.Int32("adminCount") == 1;
        var critical = string.Equals(entry.First("isCriticalSystemObject"), "TRUE", StringComparison.OrdinalIgnoreCase);
        var probe = context.Preview ? "Aperçu de la base locale" + C + "aucune sonde avant la lecture de l’annuaire." : null;
        void Add(string id, string label, string kind, string? reason, bool danger = false) => actions.Add(new FicheAction(id, label, kind, reason is null, reason, danger));
        var kind = entry.Kind;
        if (kind != FicheKind.Container)
        {
            Add("edit", "Modifier", "write", write);
        }
        if (kind == FicheKind.User && account is not null)
        {
            Add("unlock", "Déverrouiller", "write", write ?? (entry.Int64("lockoutTime") is > 0 ? null : "Ce compte n’est pas verrouillé."));
            // A protected account (adminCount = 1) is allowed, as in Domenia 1: the plan asks for the typed name.
            Add("resetPassword", "Réinitialiser le mot de passe…", "write", write ?? (critical ? "Objet système" + C + "jamais réinitialisé depuis Domenia." : null), danger: true);
            Add("expirePassword", "Imposer un nouveau mot de passe", "write", write ?? (account.MustChange ? "Le mot de passe est déjà à changer à la prochaine ouverture de session." : null));
            Add("expiration", "Expiration du compte…", "write", write);
            Add("options", "Options de sécurité…", "write", write);
        }
        if (kind is FicheKind.User or FicheKind.Computer && account is not null)
        {
            var disabled = account.Disabled == true;
            var guard = write ?? (critical ? "Objet système" + C + "jamais désactivé depuis Domenia." : isProtected && !disabled ? "Objet protégé (adminCount = 1)" + C + "désactivation bloquée, comme dans Domenia 1." : null);
            Add(disabled ? "enable" : "disable", disabled ? "Activer le compte" : "Désactiver le compte", "write", guard, danger: !disabled);
        }
        if (kind is FicheKind.User or FicheKind.Computer or FicheKind.Group or FicheKind.Contact)
        {
            Add("move", "Déplacer…", "write", write ?? (critical ? "Objet système" + C + "jamais déplacé depuis Domenia." : null));
        }
        if (kind is FicheKind.User or FicheKind.Computer or FicheKind.Contact)
        {
            Add("groupAdd", "Ajouter à un groupe…", "write", write);
        }
        if (kind == FicheKind.Group)
        {
            Add("memberAdd", "Ajouter un membre…", "write", write ?? (isProtected ? "Groupe protégé (adminCount = 1)" + C + "modification bloquée, comme dans Domenia 1." : null));
        }
        if (kind is FicheKind.Ou or FicheKind.Container)
        {
            Add("createOu", "Créer une OU…", "write", write ?? (entry.Dn.StartsWith("CN=Builtin", StringComparison.OrdinalIgnoreCase) ? "Conteneur Builtin" + C + "aucune OU ne s’y crée." : null));
        }
        if (kind == FicheKind.Ou || (kind == FicheKind.Container && entry.Dn.StartsWith("DC=", StringComparison.OrdinalIgnoreCase)))
        {
            Add("setScope", "Définir comme OU de travail", "local", null);
        }
        if (kind != FicheKind.Container)
        {
            string? deleteGuard = write;
            if (deleteGuard is null && critical)
            {
                deleteGuard = "Objet système" + C + "suppression interdite.";
            }
            else if (deleteGuard is null && isProtected)
            {
                deleteGuard = "Objet protégé (adminCount = 1)" + C + "suppression bloquée.";
            }
            else if (deleteGuard is null && kind == FicheKind.Ou && !context.Policy.AllowContainerDelete)
            {
                deleteGuard = context.Children is int children && children > 0
                    ? "Suppression des OU interdite par la configuration (Security.AllowContainerDelete) ; cette OU contient " + FrenchText.Count(children, "objet direct", "objets directs") + "."
                    : "Suppression des OU interdite par la configuration (Security.AllowContainerDelete).";
            }
            Add("delete", "Supprimer…", "write", deleteGuard, danger: true);
        }
        if (kind == FicheKind.User)
        {
            Add("lockouts", "Lire les verrouillages (4740)", "network", probe ?? (string.IsNullOrEmpty(entry.First("objectSid")) ? "SID du compte non lu." : null));
            Add("logonByDc", "Lire la connexion sur chaque contrôleur", "network", probe);
            Add("compare", "Comparer les droits avec…", "network", probe);
            Add("callSheet", "Fiche d’appel", "local", null);
        }
        if (kind == FicheKind.Computer)
        {
            Add("logonByDc", "Lire la connexion sur chaque contrôleur", "network", probe);
            Add("openPoste", "Ouvrir dans Poste", "local", null);
        }
        if (kind is FicheKind.User or FicheKind.Computer)
        {
            Add("presence", "Vérifier la présence", "network", probe ?? (kind == FicheKind.User && context.Associations.Length == 0 ? "Aucun poste associé" + C + "la présence d’un compte se mesure sur son poste." : null));
        }
        Add("rights", "Estimer les droits effectifs", "network", probe);
        Add("reread", "Relire depuis l’annuaire", "network", null);
        Add("copySummary", "Copier le résumé", "local", null);
        // The domain root opens in the fiche (quick accesses, working OU): an object placed directly under it has a parent to
        // open; only the root itself has none inside the domain.
        if (DistinguishedName.Parent(entry.Dn) is not null && !entry.Dn.StartsWith("DC=", StringComparison.OrdinalIgnoreCase))
        {
            Add("openParent", "Ouvrir le parent", "local", null);
        }
        return [.. actions];
    }

    private static ImmutableArray<FicheTab> Tabs(FicheEntry entry, FicheCounts counts)
    {
        var tabs = new List<FicheTab> { new("general", "Général", null) };
        switch (entry.Kind)
        {
            case FicheKind.User:
                tabs.Add(new FicheTab("compte", "Compte", null));
                tabs.Add(new FicheTab("groupes", "Groupes", counts.Groups));
                break;
            case FicheKind.Computer:
                tabs.Add(new FicheTab("compte", "Compte machine", null));
                tabs.Add(new FicheTab("groupes", "Groupes", counts.Groups));
                break;
            case FicheKind.Group:
                tabs.Add(new FicheTab("membres", "Membres", counts.Members));
                tabs.Add(new FicheTab("groupes", "Membre de", counts.Groups));
                break;
            case FicheKind.Contact:
                tabs.Add(new FicheTab("groupes", "Groupes", counts.Groups));
                break;
            default:
                tabs.Add(new FicheTab("membres", "Contenu", counts.Children));
                break;
        }
        var linked = (counts.Linked ?? 0) + (counts.Reports ?? 0);
        tabs.Add(new FicheTab("relations", "Relations", entry.Kind is FicheKind.User or FicheKind.Computer ? linked : null));
        tabs.Add(new FicheTab("droits", "Droits", null));
        tabs.Add(new FicheTab("attributs", "Attributs", entry.Attributes.Count));
        tabs.Add(new FicheTab("historique", "Historique", null));
        if (entry.Kind == FicheKind.User)
        {
            tabs.Add(new FicheTab("appel", "Fiche d’appel", null));
        }
        return [.. tabs];
    }

    /// <summary>
    /// Freshness per nature (FIC-036): identity and attributes from the read of the fiche, presence and console from the last measure
    /// of the workstation (or, for the console, the date of the console session that established the association), history from the
    /// read of the replication metadata in this session (never whenChanged, which dates the object and not an observation). Durations
    /// come from the usage profile; the last attempt is said when more recent than the observation.
    /// </summary>
    private static ImmutableArray<FicheFreshness> Freshness(FicheEntry entry, FicheContext context)
    {
        var table = context.Table;
        DateTimeOffset? Attempt(string nature) => context.Attempts is not null && context.Attempts.TryGetValue(nature, out var at) ? at : null;
        var readAt = context.Preview ? (DateTimeOffset?)null : context.ReadAt;
        var list = new List<FicheFreshness>
        {
            FicheDiagnostics.Freshness("identity", context.Preview ? context.ReadAt : readAt, Attempt("identity"), context.Now, context.Zone, table),
            FicheDiagnostics.Freshness("attributes", context.Preview ? context.ReadAt : readAt, Attempt("attributes"), context.Now, context.Zone, table),
        };
        if (entry.Kind is FicheKind.User or FicheKind.Computer)
        {
            list.Add(FicheDiagnostics.Freshness("presence", context.Observation?.PresenceAt, Attempt("presence"), context.Now, context.Zone, table));
            var console = context.Observation?.ConsoleAt
                ?? context.Associations.Where(a => a.Evidence == "observed").Select(a => a.When).OfType<DateTimeOffset>().DefaultIfEmpty().Max();
            list.Add(FicheDiagnostics.Freshness("console", console == default(DateTimeOffset) ? null : console, Attempt("console"), context.Now, context.Zone, table));
        }
        list.Add(FicheDiagnostics.Freshness("history", context.HistoryReadAt, null, context.Now, context.Zone, table));
        return [.. list];
    }

    /// <summary>Text of « Copier le résumé » (Copy-ObjectSummary): type, name, class, GUID, dates, DN and presence.</summary>
    private static string Summary(FicheIdentity identity, FichePresenceView? presence, TimeZoneInfo zone)
    {
        var builder = new StringBuilder();
        builder.Append("Type").Append(C).Append(identity.KindLabel).Append("\r\n");
        builder.Append("Nom").Append(C).Append(identity.Name).Append("\r\n");
        if (identity.Sam is not null)
        {
            builder.Append("Identifiant").Append(C).Append(identity.Sam).Append("\r\n");
        }
        builder.Append("Classe").Append(C).Append(string.Join(", ", identity.Classes)).Append("\r\n");
        builder.Append("GUID").Append(C).Append(identity.Guid).Append("\r\n");
        if (identity.Created is DateTimeOffset created)
        {
            builder.Append("Créé").Append(C).Append(FicheValues.LocalDateTime(created, zone)).Append("\r\n");
        }
        if (identity.Changed is DateTimeOffset changed)
        {
            builder.Append("Modifié").Append(C).Append(FicheValues.LocalDateTime(changed, zone)).Append("\r\n");
        }
        builder.Append("DN").Append(C).Append(identity.Dn);
        if (presence is not null)
        {
            builder.Append("\r\n").Append("Présence").Append(C).Append(presence.Label);
            if (presence.Computer is not null)
            {
                builder.Append(" (cible").Append(C).Append(presence.Computer).Append(')');
            }
        }
        return builder.ToString();
    }

    /// <summary>
    /// What decides a full redraw of the page (FIC-031): identity, account state, memberships and links. When it is unchanged,
    /// the page updates only the display fields that changed (Get-DomeniaObjectPresentationDelta); when everything is unchanged,
    /// nothing is redrawn.
    /// </summary>
    private static string Signature(FicheEntry entry, FicheContext context)
    {
        var builder = new StringBuilder();
        builder.Append(entry.ObjectGuid.ToString("N")).Append('|').Append(entry.Dn.ToUpperInvariant());
        foreach (var attribute in new[] { "userAccountControl", "msDS-User-Account-Control-Computed", "lockoutTime", "pwdLastSet", "accountExpires", "adminCount", "groupType", "managedBy", "manager" })
        {
            builder.Append('|').Append(entry.First(attribute));
        }
        builder.Append('|').Append(string.Join(';', entry.All("memberOf").Select(d => d.ToUpperInvariant()).Order(StringComparer.Ordinal)));
        builder.Append('|').Append(entry.All("member").Length.ToString(CultureInfo.InvariantCulture));
        builder.Append('|').Append(string.Join(';', context.Associations.Select(a => a.Dn.ToUpperInvariant())));
        builder.Append('|').Append(context.Preview ? "P" : "L");
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(builder.ToString())))[..16];
    }
}
