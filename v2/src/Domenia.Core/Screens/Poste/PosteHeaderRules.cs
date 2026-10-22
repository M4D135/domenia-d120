using System.Collections.Immutable;

namespace Domenia.Core.Poste;

/// <summary>
/// The fixed header of the console and the projections shared by every source (Domenia 1 Get-DomeniaComputerHeaderView,
/// Get-DomeniaComputerPresenceBadge, Get-DomeniaComputerAccountAction, Get-DomeniaLinkSummaryText). Pure.
/// </summary>
public static class PosteHeaderRules
{
    /// <summary>
    /// Pill of the header (DS-08): an absence of ICMP never proves the workstation is off; a remembered state never gets a
    /// time; without a readable date no time is invented.
    /// </summary>
    public static PresenceBadge Badge(PresenceReading? reading, TimeZoneInfo zone, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(zone);
        if (reading is null || reading.Answered is null)
        {
            return new PresenceBadge(PresenceState.Unknown, Tone.Off, "Présence non vérifiée",
                "Aucun test de présence pour ce poste dans cette session. « Tester la réponse » envoie un seul ping.", null, false, null);
        }
        var online = reading.Answered == true;
        if (reading.Remembered)
        {
            return new PresenceBadge(PresenceState.Remembered, Tone.Info, (online ? "Répond au ping" : "Ne répond pas au ping") + " (mémoire)",
                (online ? "Réponse ICMP reçue." : "Aucune réponse ICMP : poste éteint, hors du réseau ou ICMP filtré ; ce n’est pas une preuve qu’il est éteint.")
                + " Valeur reprise de la mémoire locale : ce n’est pas un état actuel confirmé.", null, true, null);
        }
        var time = reading.CheckedAt is DateTimeOffset at ? PosteText.LocalTime(at, zone) : null;
        var label = (online ? "Répond au ping" : "Ne répond pas au ping") + (time is null ? "" : " · " + time);
        var help = online
            ? "Réponse ICMP reçue" + (reading.RoundTripMs is int rtt ? " en " + FrenchText.Integer(rtt) + " ms" : "") + ". Un poste qui répond peut tout de même refuser les outils d’administration."
            : "Aucune réponse ICMP : poste éteint, hors du réseau ou ICMP filtré. Ce n’est pas une preuve qu’il est éteint.";
        if (reading.CheckedAt is DateTimeOffset checkedAt)
        {
            help += " Dernier test à " + PosteText.LocalTime(checkedAt, zone) + " (" + PosteText.Age(checkedAt, now) + ").";
        }
        return new PresenceBadge(online ? PresenceState.Online : PresenceState.Offline, online ? Tone.Ok : Tone.Warn, label, help, reading.CheckedAt, false, reading.RoundTripMs);
    }

    /// <summary>The header of the console; every text says when it does not know.</summary>
    public static PosteHeader Header(PosteComputer computer, PresenceBadge presence, PosteAssociation association, InventorySummary? inventory, DateTimeOffset? directoryReadAt)
    {
        ArgumentNullException.ThrowIfNull(computer);
        ArgumentNullException.ThrowIfNull(presence);
        ArgumentNullException.ThrowIfNull(association);
        var os = (computer.OperatingSystem ?? "").Trim();
        var version = (computer.OperatingSystemVersion ?? "").Trim();
        var system = os.Length > 0 && version.Length > 0 ? os + " · " + (computer.Release is null ? version : computer.Release + " (" + version + ")")
            : os.Length > 0 ? os : version.Length > 0 ? "Version " + version : "Système non renseigné dans l’annuaire";
        var user = association.User;
        var userText = user is null ? "Aucun utilisateur associé" : user.Name;
        var userHelp = user is null
            ? "Aucun utilisateur associé à ce poste dans la mémoire locale. « Détecter à nouveau » interroge le poste."
            : "Ouvre la fiche de " + user.Name + (user.Login.Length > 0 && user.Login != user.Name ? " (" + user.Login + ")" : "") + ". Aucune écriture, aucune sonde du poste.";
        var inventoryText = inventory is null ? "Aucun inventaire dans cette session ni dans la base locale" : inventory.ModeLabel + " " + inventory.AgeText;
        return new PosteHeader(string.IsNullOrWhiteSpace(computer.Name) ? "Poste sans nom" : computer.Name, system, presence, user, userText, userHelp, inventoryText, inventory?.At, directoryReadAt);
    }

    /// <summary>Text of the account card (UI-07): one button only, none when userAccountControl is unreadable.</summary>
    public static string AccountText(int? userAccountControl) => userAccountControl switch
    {
        null => "État du compte non lu : relisez la fiche avant de l’activer ou de le désactiver.",
        int uac when AdValues.IsDisabled(uac) => "Compte désactivé dans le domaine : le poste ne peut plus s’authentifier.",
        _ => "Compte actif dans le domaine.",
    };

    public static string BadgeLabel(AssociationBadge badge) => badge switch
    {
        AssociationBadge.Declared => "Déclaré",
        AssociationBadge.Observed => "Observé",
        AssociationBadge.History => "Historique",
        AssociationBadge.Contradictory => "Contradictoire",
        _ => "Aucune",
    };

    public static Tone BadgeTone(AssociationBadge badge) => badge switch
    {
        AssociationBadge.Declared => Tone.Info,
        AssociationBadge.Observed => Tone.Ok,
        AssociationBadge.Contradictory => Tone.Warn,
        _ => Tone.Off,
    };

    /// <summary>
    /// One-line summary of the remembered association (Get-DomeniaLinkSummaryText): user, source, date, badge and rule; a
    /// history shows in a neutral tone, never as a current observation; an identity that cannot be proven is said.
    /// </summary>
    public static PosteAssociation Association(UserRef? user, AssociationBadge badge, string source, DateTimeOffset? at, string rule, bool identityProven, ImmutableArray<AssociationEvent> history, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        string text;
        if (user is null)
        {
            text = "Aucune association mémorisée pour ce poste. « Détecter à nouveau » interroge le poste (geste explicite).";
        }
        else
        {
            text = user.Name + " · " + BadgeLabel(badge) + " · " + source + (at is DateTimeOffset seen ? " · " + PosteText.LocalDateTime(seen, zone) : "") + " · règle : " + rule;
            if (!identityProven)
            {
                text += " · identité non vérifiable (lien hérité sans GUID)";
            }
        }
        return new PosteAssociation(user, user is null ? AssociationBadge.None : badge, BadgeLabel(user is null ? AssociationBadge.None : badge), BadgeTone(user is null ? AssociationBadge.None : badge), source, at, rule, text, identityProven, history);
    }

    /// <summary>Kind estimated from the name (PC fixed, PT laptop), the chassis or the role; never asserted.</summary>
    public static MachineKind Kind(string name, string? operatingSystem)
    {
        ArgumentNullException.ThrowIfNull(name);
        if ((operatingSystem ?? "").Contains("Server", StringComparison.OrdinalIgnoreCase))
        {
            return MachineKind.Server;
        }
        if (name.StartsWith("PT-", StringComparison.OrdinalIgnoreCase))
        {
            return MachineKind.Laptop;
        }
        return name.StartsWith("PC-", StringComparison.OrdinalIgnoreCase) ? MachineKind.Desktop : MachineKind.Unknown;
    }

    public static string KindLabel(MachineKind kind) => kind switch
    {
        MachineKind.Desktop => "Poste fixe",
        MachineKind.Laptop => "Portable",
        MachineKind.Server => "Serveur",
        MachineKind.Virtual => "Machine virtuelle",
        _ => "Poste",
    };

    /// <summary>Projection of a computer object of the directory for the console (attributes read with the object card).</summary>
    public static PosteComputer Computer(DirectoryComputer c, DirectorySnapshot directory, IReadOnlyDictionary<string, string> ouNames)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(ouNames);
        var parent = DistinguishedName.Parent(c.DistinguishedName) ?? directory.Domain.RootDn;
        var parts = DistinguishedName.Parse(parent).Where(p => p.Type.Equals("OU", StringComparison.OrdinalIgnoreCase) || p.Type.Equals("CN", StringComparison.OrdinalIgnoreCase)).Select(p => p.Value).Reverse().ToList();
        var ouName = parts.Count > 0 ? parts[^1] : directory.Domain.DnsName;
        var path = string.Join(FrenchText.PathSeparator, new[] { directory.Domain.DnsName }.Concat(parts));
        var managedBy = c.ManagedByDn is null ? null : new DnRef(c.ManagedByDn, ouNames.TryGetValue(c.ManagedByDn, out var n) ? n : DistinguishedName.Parse(c.ManagedByDn)[0].Value);
        var groups = c.MemberOf.Select(g => new DnRef(g, DistinguishedName.Parse(g)[0].Value)).OrderBy(g => g.Name, PosteText.French).ToImmutableArray();
        var kind = Kind(c.Name, c.OperatingSystem);
        var release = WindowsRelease.Describe(c.OperatingSystem, c.OperatingSystemVersion);
        var site = parts.Count >= 2 && parts[0].Equals("Postes", StringComparison.OrdinalIgnoreCase) ? parts[1] : null;
        return new PosteComputer(
            c.DistinguishedName,
            c.ObjectGuid,
            c.Name,
            c.DnsHostName,
            c.SamAccountName,
            c.Sid,
            c.OperatingSystem,
            c.OperatingSystemVersion,
            release?.Label,
            kind,
            KindLabel(kind),
            c.Description,
            c.Location,
            managedBy,
            !AdValues.IsDisabled(c.UserAccountControl),
            c.UserAccountControl,
            AccountText(c.UserAccountControl),
            c.WhenCreated,
            c.WhenChanged,
            AdValues.FromFileTime(c.PasswordLastSet),
            AdValues.FromFileTime(c.LastLogonTimestamp),
            c.Laps switch { LapsKind.Windows => "Windows LAPS", LapsKind.Legacy => "LAPS historique", _ => "Aucun LAPS" },
            AdValues.FromFileTime(c.LapsExpiration),
            new OuRef(parent, ouName, path),
            site,
            groups);
    }
}
