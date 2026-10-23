using System.Collections.Frozen;
using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Facts a source knows beside the directory: console user, remembered association, address and survey results of a
/// workstation (local readings in directory mode, derived data in simulation). Every member may answer null (« non lu »).
/// </summary>
public interface ISearchEnrichment
{
    /// <summary>Presence reading newer than the observation of the source (a survey of this screen), or null.</summary>
    PresenceMeasure? Presence(Guid computer);

    SearchConsole? Console(Guid computer);

    /// <summary>Workstation(s) of a user, or user of a workstation.</summary>
    SearchAssociation? Association(Guid objectId);

    SearchAddressReading? Address(Guid computer);
}

/// <summary>Readable texts of the search screen (paths, states, presence, group scopes), independent of the culture.</summary>
public static class SearchTexts
{
    /// <summary>Readings of presence older than this are « Non vérifié » (ObservationMaxAgeDays of Domenia 1).</summary>
    public static readonly TimeSpan PresenceMaxAge = TimeSpan.FromDays(30);

    /// <summary>Sans connexion AD au-delà de ce délai (lastLogonTimestamp, à 14 jours près).</summary>
    public static readonly TimeSpan InactiveAfter = TimeSpan.FromDays(90);

    /// <summary>Readable path of the container of an object: « example.local › Utilisateurs › Paris ».</summary>
    public static string ContainerPath(string dn, string dnsName)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var parent = SafeParent(dn);
        return parent is null ? dnsName : Path(parent, dnsName);
    }

    /// <summary>Readable path of a DN from the domain down (DC components become the DNS name).</summary>
    public static string Path(string dn, string dnsName)
    {
        ArgumentNullException.ThrowIfNull(dn);
        try
        {
            var names = DistinguishedName.Parse(dn);
            var segments = names.Where(n => !string.Equals(n.Type, "DC", StringComparison.OrdinalIgnoreCase)).Reverse().Select(n => n.Value);
            var list = new List<string> { dnsName };
            list.AddRange(segments);
            return string.Join(FrenchText.PathSeparator, list);
        }
        catch (FormatException)
        {
            return dn;
        }
    }

    /// <summary>Value of the first RDN (the object name as the DN writes it), or the DN itself.</summary>
    public static string Leaf(string dn)
    {
        ArgumentNullException.ThrowIfNull(dn);
        try
        {
            var names = DistinguishedName.Parse(dn);
            return names.Length > 0 ? names[0].Value : dn;
        }
        catch (FormatException)
        {
            return dn;
        }
    }

    /// <summary>Parent DN, or null for a malformed or single-RDN DN.</summary>
    public static string? SafeParent(string dn)
    {
        try
        {
            _ = DistinguishedName.Parse(dn);
            return DistinguishedName.Parent(dn);
        }
        catch (FormatException)
        {
            return null;
        }
    }

    /// <summary>Scope and kind of a group from groupType: « Global · sécurité », « Domaine local · distribution »…</summary>
    public static string GroupScope(int groupType)
    {
        var scope = (groupType & 0x1) != 0 ? "Local intégré"
            : (groupType & 0x4) != 0 ? "Domaine local"
            : (groupType & 0x8) != 0 ? "Universel"
            : "Global";
        var kind = (groupType & unchecked((int)0x80000000)) != 0 ? "sécurité" : "distribution";
        return scope + " · " + kind;
    }

    /// <summary>State of a user account (Domenia 1 RCH-072: Actif, Désactivé, Verrouillé, Mot de passe expiré, Verrouillage à vérifier).</summary>
    public static SearchState UserState(AccountState state, bool passwordExpired)
    {
        ArgumentNullException.ThrowIfNull(state);
        if (state.Disabled)
        {
            return new SearchState("disabled", "Désactivé", Tone.Off);
        }
        if (state.Lock == LockState.Locked)
        {
            return new SearchState("locked", "Verrouillé", Tone.Alert);
        }
        if (state.Lock == LockState.ToCheck)
        {
            return new SearchState("lockCheck", "Verrouillage à vérifier", Tone.Warn);
        }
        return passwordExpired ? new SearchState("expired", "Mot de passe expiré", Tone.Warn) : new SearchState("active", "Actif", Tone.Ok);
    }

    /// <summary>
    /// Presence of a workstation for the list (FI-16): a reading of less than 30 days answered or not, a probe in error, or
    /// « Non vérifié ». A missing answer is never a verdict that the workstation is off.
    /// </summary>
    public static SearchPresence Presence(PresenceMeasure? measure, DateTimeOffset now)
    {
        var m = measure ?? PresenceMeasure.Unread;
        if (m.State is MeasureState.Error or MeasureState.Refused)
        {
            var refused = m.State == MeasureState.Refused;
            return new SearchPresence(SearchPresenceState.Error, refused ? "Relevé refusé" : "Erreur de ping", Tone.Alert, m.CheckedAt, m.LastOnlineAt,
                refused ? "La sonde a été refusée pour ce poste" + FrenchText.Colon + "rien n’est conclu sur sa présence."
                    : "Le relevé n’a pas abouti (nom non résolu ou sonde en erreur)" + FrenchText.Colon + "rien n’est conclu sur sa présence.");
        }
        if (m.HasReading && m.CheckedAt is DateTimeOffset at && now - at <= PresenceMaxAge)
        {
            return m.Answered == true
                ? new SearchPresence(SearchPresenceState.Online, "En ligne", Tone.Ok, at, m.LastOnlineAt ?? at, "Le poste a répondu au ping lors du dernier relevé.")
                : new SearchPresence(SearchPresenceState.NoReply, "Sans réponse au ping", Tone.Warn, at, m.LastOnlineAt,
                    "Pas de réponse ICMP" + FrenchText.Colon + "poste indisponible ou ICMP filtré, sans preuve qu’il est éteint.");
        }
        return new SearchPresence(SearchPresenceState.Unknown, "Non vérifié", Tone.Off, m.CheckedAt, m.LastOnlineAt,
            "Aucun relevé de moins de 30 jours. Sélectionnez ce poste puis « Revérifier ce poste » pour envoyer un seul ping ; aucun contrôle collectif.");
    }

    /// <summary>Label of a presence key, as the pills and the filters show it.</summary>
    public static string PresenceLabel(SearchPresenceState state) => state switch
    {
        SearchPresenceState.Online => "En ligne",
        SearchPresenceState.NoReply => "Sans réponse au ping",
        SearchPresenceState.Error => "Erreur de ping",
        _ => "Non vérifié",
    };
}

/// <summary>
/// Builds the canonical display rows of the search screen from directory records, local observations and the facts of
/// the source (RCH-072, RCH-075). Pure: <paramref name="now"/> is an input, nothing is read here.
/// </summary>
public sealed class SearchRowFactory
{
    private readonly DirectorySnapshot snapshot;
    private readonly FrozenDictionary<Guid, WorkstationObservation> observations;
    private readonly ISearchEnrichment? enrichment;
    private readonly DateTimeOffset now;
    private readonly string dnsName;

    public SearchRowFactory(DirectorySnapshot snapshot, IEnumerable<WorkstationObservation> observations, ISearchEnrichment? enrichment, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(observations);
        this.snapshot = snapshot;
        this.observations = observations.GroupBy(o => o.ComputerGuid).ToFrozenDictionary(g => g.Key, g => g.Last());
        this.enrichment = enrichment;
        this.now = now;
        dnsName = snapshot.Domain.DnsName;
    }

    /// <summary>Observation of a workstation, or null when none is recorded.</summary>
    public WorkstationObservation? Observation(Guid computer) => observations.TryGetValue(computer, out var o) ? o : null;

    /// <summary>The row of any directory record (user, computer, group or OU).</summary>
    private static DateTimeOffset? Date(DateTimeOffset at) => at == DateTimeOffset.MinValue ? null : at;

    public SearchRow Row(object record, int rank = 9, string? verdict = null) => record switch
    {
        DirectoryUser user => User(user, rank, verdict),
        DirectoryComputer computer => Computer(computer, rank, verdict),
        DirectoryGroup group => Group(group, rank, verdict),
        DirectoryOu ou => Ou(ou, rank, verdict),
        DirectoryContact contact => Contact(contact, rank, verdict),
        _ => throw new ArgumentException("Unknown directory record.", nameof(record)),
    };

    public SearchRow User(DirectoryUser user, int rank = 9, string? verdict = null)
    {
        ArgumentNullException.ThrowIfNull(user);
        var state = AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime);
        var password = AccountState.ClassifyPassword(user, snapshot.Domain.PasswordPolicy.MaxPasswordAge, now, TimeSpan.FromDays(7));
        var expired = !state.Disabled && password == PasswordClass.Expired;
        var lastLogon = AdValues.FromFileTime(user.LastLogonTimestamp);
        var accountExpires = AdValues.FromFileTime(user.AccountExpires);
        var flags = new SearchFlags(
            state.Disabled,
            state.Lock == LockState.Locked,
            state.Lock == LockState.ToCheck,
            expired,
            state.PasswordNeverExpires,
            state.PasswordNotRequired,
            user.PasswordLastSet == 0,
            !state.Disabled && lastLogon is DateTimeOffset seen && now - seen >= SearchTexts.InactiveAfter,
            !state.Disabled && lastLogon is null,
            SearchMatcher.IsAdminAccount(user.AdminCount, user.SamAccountName),
            accountExpires is DateTimeOffset soon && soon >= now && soon <= now + TimeSpan.FromDays(30),
            accountExpires is DateTimeOffset past && past <= now);
        return new SearchRow(
            Id(user.ObjectGuid), SearchObjectKind.User, "Utilisateur", user.Cn, user.DisplayName, user.SamAccountName, user.UserPrincipalName,
            user.Mail, user.Description, user.DistinguishedName, SearchTexts.ContainerPath(user.DistinguishedName, dnsName),
            SearchTexts.UserState(state, expired), flags, null, null, lastLogon, Date(user.WhenChanged), Date(user.WhenCreated), ObservedAt(user.ObjectGuid),
            null, null, enrichment?.Association(user.ObjectGuid), null, null, verdict, rank);
    }

    public SearchRow Computer(DirectoryComputer computer, int rank = 9, string? verdict = null)
    {
        ArgumentNullException.ThrowIfNull(computer);
        var disabled = AdValues.IsDisabled(computer.UserAccountControl);
        var lastLogon = AdValues.FromFileTime(computer.LastLogonTimestamp);
        var release = WindowsRelease.Describe(computer.OperatingSystem, computer.OperatingSystemVersion);
        var controller = AdValues.HasFlag(computer.UserAccountControl, AdValues.ServerTrustAccount);
        var kindLabel = controller ? "Contrôleur de domaine" : release?.IsServer == true ? "Serveur" : "Poste";
        var flags = new SearchFlags(disabled, false, false, false, false, false, false,
            !disabled && lastLogon is DateTimeOffset seen && now - seen >= SearchTexts.InactiveAfter,
            !disabled && lastLogon is null, false, false, false);
        var measure = enrichment?.Presence(computer.ObjectGuid) ?? Observation(computer.ObjectGuid)?.Presence;
        var osVersion = computer.OperatingSystem is null ? null
            : computer.OperatingSystemVersion is null ? computer.OperatingSystem : computer.OperatingSystem + " · " + computer.OperatingSystemVersion;
        return new SearchRow(
            Id(computer.ObjectGuid), SearchObjectKind.Computer, kindLabel, computer.Name, null, computer.SamAccountName.TrimEnd('$'), computer.DnsHostName,
            null, computer.Description, computer.DistinguishedName, SearchTexts.ContainerPath(computer.DistinguishedName, dnsName),
            disabled ? new SearchState("disabled", "Désactivé", Tone.Off) : new SearchState("active", "Actif", Tone.Ok), flags,
            release?.Label ?? computer.OperatingSystem, osVersion, lastLogon, Date(computer.WhenChanged), Date(computer.WhenCreated), ObservedAt(computer.ObjectGuid),
            SearchTexts.Presence(measure, now), enrichment?.Console(computer.ObjectGuid), enrichment?.Association(computer.ObjectGuid),
            enrichment?.Address(computer.ObjectGuid), null, verdict, rank);
    }

    public SearchRow Group(DirectoryGroup group, int rank = 9, string? verdict = null)
    {
        ArgumentNullException.ThrowIfNull(group);
        var scope = SearchTexts.GroupScope(group.GroupType);
        var flags = new SearchFlags(false, false, false, false, false, false, false, false, false, group.AdminCount == 1, false, false);
        return new SearchRow(
            Id(group.ObjectGuid), SearchObjectKind.Group, "Groupe", group.Name, null, group.SamAccountName, null, group.Mail, group.Description,
            group.DistinguishedName, SearchTexts.ContainerPath(group.DistinguishedName, dnsName), new SearchState("group", scope, Tone.Info), flags,
            null, null, null, Date(group.WhenChanged), Date(group.WhenCreated), ObservedAt(group.ObjectGuid), null, null, null, null,
            new SearchGroupInfo(scope, group.Members.Length), verdict, rank);
    }

    public SearchRow Ou(DirectoryOu ou, int rank = 9, string? verdict = null)
    {
        ArgumentNullException.ThrowIfNull(ou);
        var flags = new SearchFlags(false, false, false, false, false, false, false, false, false, false, false, false);
        return new SearchRow(
            Id(ou.ObjectGuid), SearchObjectKind.Ou, "OU", ou.Name, null, null, null, null, ou.Description, ou.DistinguishedName,
            SearchTexts.ContainerPath(ou.DistinguishedName, dnsName), new SearchState("ou", "Unité d’organisation", Tone.Off), flags,
            null, null, null, Date(ou.WhenChanged), Date(ou.WhenCreated), ObservedAt(ou.ObjectGuid), null, null, null, null, null, verdict, rank);
    }

    public SearchRow Contact(DirectoryContact contact, int rank = 9, string? verdict = null)
    {
        ArgumentNullException.ThrowIfNull(contact);
        return new(Id(contact.ObjectGuid), SearchObjectKind.Contact, "Contact", contact.Name, contact.DisplayName, null, null,
            contact.Mail, contact.Description, contact.DistinguishedName, SearchTexts.ContainerPath(contact.DistinguishedName, dnsName),
            new SearchState("contact", "Contact d’annuaire", Tone.Info), new(false, false, false, false, false, false, false, false, false, false, false, false),
            null, null, null, Date(contact.WhenChanged), Date(contact.WhenCreated), ObservedAt(contact.ObjectGuid), null, null, null, null, null, verdict, rank);
    }

    private DateTimeOffset ObservedAt(Guid id) => snapshot.ObjectReadAt?.GetValueOrDefault(id, snapshot.ReadAt) ?? snapshot.ReadAt;

    /// <summary>Candidates of every object of the snapshot, in the order of the snapshot (OUs, users, computers, groups).</summary>
    public static ImmutableArray<SearchCandidate> Candidates(DirectorySnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var list = ImmutableArray.CreateBuilder<SearchCandidate>(snapshot.ObjectCount);
        foreach (var ou in snapshot.OrganizationalUnits)
        {
            list.Add(new SearchCandidate(SearchObjectKind.Ou, ou.ObjectGuid, null, ou.DistinguishedName, ou.Name, null, null, null, null, null, null, null, null, ou));
        }
        foreach (var u in snapshot.Users)
        {
            list.Add(new SearchCandidate(SearchObjectKind.User, u.ObjectGuid, u.Sid, u.DistinguishedName, u.Cn, u.Cn, u.SamAccountName, u.DisplayName,
                u.GivenName, u.Surname, u.UserPrincipalName, u.Mail, null, u));
        }
        foreach (var c in snapshot.Computers)
        {
            list.Add(new SearchCandidate(SearchObjectKind.Computer, c.ObjectGuid, c.Sid, c.DistinguishedName, c.Name, c.Name, c.SamAccountName.TrimEnd('$'), null,
                null, null, null, null, c.DnsHostName, c));
        }
        foreach (var g in snapshot.Groups)
        {
            list.Add(new SearchCandidate(SearchObjectKind.Group, g.ObjectGuid, g.Sid, g.DistinguishedName, g.Name, g.Name, g.SamAccountName, null, null, null, null, g.Mail, null, g));
        }
        foreach (var c in snapshot.Contacts ?? [])
        {
            list.Add(new SearchCandidate(SearchObjectKind.Contact, c.ObjectGuid, null, c.DistinguishedName, c.Name, c.Name, null,
                c.DisplayName, c.GivenName, c.Surname, null, c.Mail, null, c));
        }
        return list.MoveToImmutable();
    }

    private static string Id(Guid id) => id.ToString("D");
}
