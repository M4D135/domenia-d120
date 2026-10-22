using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// The single read of one recipe step in simulation (docs/ops/assistance.md § 5): what the directory already holds is read as
/// is (account state, groups, LAPS dates, presence and inventory readings); what it does not hold (security events, GPO,
/// software, sessions, clock offset) is drawn from the fork of the step and the object, so the same seed always gives the same
/// answer. Workstations that refuse or do not answer behave as on a real network: refusal, or failure, never a silent success.
/// </summary>
internal sealed class SimulatedAssistanceSteps(
    DirectorySnapshot directory,
    FleetObservations fleet,
    SimulatedWorld world,
    DateTimeOffset now,
    TimeZoneInfo zone,
    SeededRandom random)
{
    private static readonly string Colon = FrenchText.Colon;

    public StepReading Run(AssistanceAction action, SubjectRecord subject)
    {
        if (subject.Kind == AssistanceSubject.User)
        {
            var user = directory.Users.First(u => u.ObjectGuid == subject.Guid);
            return action.Id switch
            {
                "lockoutEvents" => Lockouts(action, user),
                "passwordPolicy" => Policy(action, user),
                "groups" => Groups(action, user.MemberOf, user.PrimaryGroupId, "compte"),
                "gpoLinks" => GpoLinks(action, user.DistinguishedName),
                _ => throw new DomeniaOperationException(AssistanceErrors.SubjectMismatch, "Cette lecture ne concerne pas un compte" + Colon + "rien n’a été lancé."),
            };
        }
        var computer = directory.Computers.First(c => c.ObjectGuid == subject.Guid);
        var observation = fleet.Workstations.FirstOrDefault(o => o.ComputerGuid == computer.ObjectGuid);
        switch (action.Id)
        {
            case "groups":
                return Groups(action, computer.MemberOf, computer.PrimaryGroupId, "poste");
            case "gpoLinks":
                return GpoLinks(action, computer.DistinguishedName);
            case "diagnostics":
                return Diagnostics(action, computer, observation);
        }
        // Every other read contacts the workstation itself.
        Reachable(computer, observation);
        return action.Id switch
        {
            "gpoApplied" => GpoApplied(action, computer),
            "machineIdentity" => Identity(action, computer),
            "inventory" => Inventory(action, computer, observation, deep: false),
            "inventoryDeep" => Inventory(action, computer, observation, deep: true),
            "software" => Software(action, computer),
            "sessions" => Sessions(action, computer),
            _ => throw new DomeniaOperationException(AssistanceErrors.SubjectMismatch, "Cette lecture ne concerne pas un poste" + Colon + "rien n’a été lancé."),
        };
    }

    // ---------------------------------------------------------------- shared

    private string Date(DateTimeOffset at) => TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM'/'yyyy' à 'HH':'mm", CultureInfo.InvariantCulture);

    /// <param name="mentions">Names of other objects the read cites (pseudonymised in the documents, never sent to the page).</param>
    private static StepReading Reading(AssistanceAction action, DateTimeOffset at, Tone tone, string summary, IEnumerable<StepFact> facts, IReadOnlyList<StepItem> items, int shown, string limit,
        IEnumerable<KnownName>? mentions = null) =>
        new(action.Id, action.Operation, action.Label, at, tone, summary, [.. facts], [.. items.Take(shown)], Math.Max(0, items.Count - shown), limit,
            [.. (mentions ?? []).Where(m => !string.IsNullOrWhiteSpace(m.Value)).DistinctBy(m => m.Value, StringComparer.OrdinalIgnoreCase)]);

    private static KnownName Machine(string name) => new(name, "Machine", "Machine");

    private static string SiteOf(string dn)
    {
        foreach (var site in SimulationProfile.Sites)
        {
            if (dn.Contains("OU=" + site.Name + ",", StringComparison.OrdinalIgnoreCase))
            {
                return site.Name;
            }
        }
        return "Paris";
    }

    private static string CodeOf(string site) => SimulationProfile.Sites.FirstOrDefault(s => s.Name == site)?.Code ?? "PAR";

    private static int SiteIndex(string site)
    {
        var index = SimulationProfile.Sites.Select(s => s.Name).ToList().IndexOf(site);
        return index < 0 ? 0 : index;
    }

    /// <summary>A workstation that refuses the account of the session, or that does not answer, ends the read: nothing is guessed.</summary>
    private void Reachable(DirectoryComputer computer, WorkstationObservation? observation)
    {
        if (AdValues.IsDisabled(computer.UserAccountControl))
        {
            throw new DomeniaOperationException(AssistanceErrors.ReadFailed,
                "Hôte inconnu" + Colon + (computer.DnsHostName ?? computer.Name) + " ne se résout plus (0x80070035). Le compte ordinateur est désactivé" + FrenchText.Nbsp + "; rien n’a été lu.");
        }
        if (world.Presence.ErrorProbes.Contains(computer.ObjectGuid))
        {
            throw new DomeniaOperationException(AssistanceErrors.ReadRefused,
                "Accès refusé (0x80070005)" + Colon + "le compte de la session n’a pas les droits d’administration de " + computer.Name + ". Rien n’a été lu.");
        }
        if (observation?.Presence is { HasReading: true, Answered: false } || (world.Presence.NeverAnswer.Contains(computer.ObjectGuid) && observation?.Inventory.HasReading != true))
        {
            throw new DomeniaOperationException(AssistanceErrors.ReadFailed,
                "Le serveur RPC n’est pas disponible (0x800706BA)" + Colon + computer.Name + " ne répond pas. Rien n’est relancé seul.");
        }
    }

    private IEnumerable<string> SiteWorkstations(string site) =>
        directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && c.DistinguishedName.Contains("OU=" + site + ",OU=Postes", StringComparison.OrdinalIgnoreCase))
            .Select(c => c.Name).Order(StringComparer.Ordinal);

    // ---------------------------------------------------------------- account reads

    private StepReading Lockouts(AssistanceAction action, DirectoryUser user)
    {
        var state = AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime);
        var pdc = directory.Domain.Controllers.FirstOrDefault()?.DnsName ?? "DC01." + SimulationProfile.DnsName;
        var count = state.Lock switch
        {
            LockState.Locked => random.Next(3, 7),
            LockState.ToCheck => random.Next(1, 3),
            _ => user.LockoutTime is > 0 ? 1 : 0,
        };
        var station = SiteWorkstations(SiteOf(user.DistinguishedName)).ToList();
        var main = station.Count > 0 ? random.Pick(station) : "PC-PAR-0001";
        var latest = AdValues.FromFileTime(user.LockoutTime) ?? now - TimeSpan.FromHours(random.Next(2, 30));
        var events = new List<(DateTimeOffset At, string Caller)>();
        var at = latest;
        for (var i = 0; i < count; i++)
        {
            if (at < now - TimeSpan.FromDays(7))
            {
                break;
            }
            var caller = i == 1 && station.Count > 2 && random.Chance(40) ? random.Pick(station) : main;
            events.Add((at, caller));
            at -= TimeSpan.FromMinutes(random.Next(45, 60 * 30));
        }
        var items = events.Select(e => new StepItem("Verrouillage depuis " + e.Caller, "Événement 4740 · " + pdc + " · " + Date(e.At), Tone.Alert)).ToList();
        var dominant = events.GroupBy(e => e.Caller).OrderByDescending(g => g.Count()).FirstOrDefault()?.Key;
        var facts = new List<StepFact>
        {
            new("Événements 4740 (7 jours)", FrenchText.Integer(events.Count), events.Count > 0 ? Tone.Alert : Tone.Ok),
            new("Poste à l’origine", dominant ?? "—", dominant is null ? Tone.Off : Tone.Warn),
            new("Dernier verrouillage", events.Count > 0 ? Date(events[0].At) : "—", Tone.Off),
            new("Échecs récents (badPwdCount)", user.BadPasswordCount is int bad ? FrenchText.Integer(bad) : "—", user.BadPasswordCount is > 2 ? Tone.Warn : Tone.Off),
            new("Contrôleur interrogé", pdc + " (émulateur PDC)", Tone.Off),
        };
        var summary = events.Count == 0
            ? "Aucun verrouillage de ce compte sur 7 jours dans le journal de l’émulateur PDC."
            : AssistanceText.Count(events.Count, "verrouillage", "verrouillages") + " en 7 jours, le plus souvent depuis " + dominant
              + Colon + "cherchez une session, un lecteur réseau ou un service qui garde l’ancien mot de passe.";
        return Reading(action, now, events.Count > 0 ? Tone.Alert : Tone.Ok, summary, facts, items, 8,
            "Journal Sécurité de l’émulateur PDC seulement" + FrenchText.Nbsp + "; un journal purgé ne montre pas les verrouillages anciens.",
            [.. events.Select(e => Machine(e.Caller)), Machine(pdc), Machine(pdc.Split('.')[0])]);
    }

    private StepReading Policy(AssistanceAction action, DirectoryUser user)
    {
        var domain = directory.Domain.PasswordPolicy;
        var privileged = user.AdminCount == 1 || user.DistinguishedName.Contains("OU=Comptes à privilèges", StringComparison.OrdinalIgnoreCase);
        var name = privileged ? "PSO-Comptes-a-privileges (stratégie fine)" : "Stratégie du domaine";
        var maxAge = privileged ? TimeSpan.FromDays(60) : domain.MaxPasswordAge;
        var minLength = privileged ? 16 : domain.MinPasswordLength;
        var history = privileged ? 24 : domain.PasswordHistoryLength;
        var threshold = privileged ? 5 : domain.LockoutThreshold;
        var duration = privileged ? TimeSpan.FromMinutes(30) : domain.LockoutDuration;
        var passwordClass = AccountState.ClassifyPassword(user, maxAge, now, TimeSpan.FromDays(7));
        var expiry = AdValues.FromFileTime(user.PasswordExpiryComputed)
            ?? (AdValues.FromFileTime(user.PasswordLastSet) is DateTimeOffset set ? set + maxAge : null);
        var (dueText, dueTone) = passwordClass switch
        {
            PasswordClass.MustChange => ("Changement exigé à la prochaine ouverture de session", Tone.Warn),
            PasswordClass.NeverExpires => ("N’expire jamais (option du compte)", Tone.Info),
            PasswordClass.Expired => ("Expiré" + (expiry is DateTimeOffset e ? " depuis le " + Date(e) : ""), Tone.Alert),
            PasswordClass.Expiring => ("Expire le " + (expiry is DateTimeOffset e2 ? Date(e2) : "—"), Tone.Warn),
            _ => (expiry is DateTimeOffset e3 ? "Valide jusqu’au " + Date(e3) : "Valide", Tone.Ok),
        };
        var facts = new[]
        {
            new StepFact("Stratégie applicable", name, privileged ? Tone.Info : Tone.Off),
            new StepFact("Durée maximale", AssistanceText.Count((long)maxAge.TotalDays, "jour", "jours"), Tone.Off),
            new StepFact("Longueur minimale", AssistanceText.Count(minLength, "caractère", "caractères"), Tone.Off),
            new StepFact("Historique", AssistanceText.Count(history, "mot de passe retenu", "mots de passe retenus"), Tone.Off),
            new StepFact("Seuil de verrouillage", threshold == 0 ? "Aucun" : AssistanceText.Count(threshold, "essai", "essais"), Tone.Off),
            new StepFact("Durée de verrouillage", AssistanceText.Count((long)duration.TotalMinutes, "minute", "minutes"), Tone.Off),
            new StepFact("Échéance du mot de passe", dueText, dueTone),
        };
        var summary = name + Colon + "mot de passe valable " + AssistanceText.Count((long)maxAge.TotalDays, "jour", "jours") + ", verrouillage après "
            + AssistanceText.Count(threshold, "essai", "essais") + ". " + dueText + ".";
        return Reading(action, now, dueTone == Tone.Alert ? Tone.Alert : dueTone == Tone.Warn ? Tone.Warn : Tone.Ok, summary, facts, [], 0,
            "Échéance calculée par le contrôleur (msDS-UserPasswordExpiryTimeComputed)" + FrenchText.Nbsp + "; aucun mot de passe n’est lu.");
    }

    private StepReading Groups(AssistanceAction action, ImmutableArray<string> memberOf, int primaryGroupId, string kind)
    {
        var byDn = directory.Groups.ToDictionary(g => g.DistinguishedName, StringComparer.OrdinalIgnoreCase);
        var direct = memberOf.Select(dn => byDn.GetValueOrDefault(dn)).OfType<DirectoryGroup>().ToList();
        var nested = new Dictionary<string, (DirectoryGroup Group, string Via)>(StringComparer.OrdinalIgnoreCase);
        var queue = new Queue<(DirectoryGroup Group, string Via)>(direct.Select(g => (g, g.Name)));
        var seen = direct.Select(g => g.DistinguishedName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        while (queue.Count > 0 && seen.Count < 2000)
        {
            var (group, via) = queue.Dequeue();
            foreach (var parentDn in group.MemberOf)
            {
                if (byDn.TryGetValue(parentDn, out var parent) && seen.Add(parent.DistinguishedName))
                {
                    nested[parent.DistinguishedName] = (parent, via);
                    queue.Enqueue((parent, via));
                }
            }
        }
        var primary = primaryGroupId switch { 513 => "Utilisateurs du domaine", 515 => "Ordinateurs du domaine", 514 => "Invités du domaine", _ => null };
        var privileged = direct.Concat(nested.Values.Select(n => n.Group)).Where(g => g.AdminCount == 1).Select(g => g.Name).Distinct().ToList();
        var items = new List<StepItem>();
        items.AddRange(direct.OrderBy(g => g.Name, StringComparer.Ordinal).Select(g => new StepItem(g.Name, "Direct" + (g.Description is { } d ? " · " + d : ""), g.AdminCount == 1 ? Tone.Warn : Tone.Info)));
        items.AddRange(nested.Values.OrderBy(n => n.Group.Name, StringComparer.Ordinal).Select(n => new StepItem(n.Group.Name, "Imbriqué via " + n.Via, n.Group.AdminCount == 1 ? Tone.Warn : Tone.Off)));
        var facts = new[]
        {
            new StepFact("Groupes directs", FrenchText.Integer(direct.Count), Tone.Off),
            new StepFact("Groupes imbriqués", FrenchText.Integer(nested.Count), Tone.Off),
            new StepFact("Groupe principal", primary ?? "—", Tone.Off),
            new StepFact("Groupes à privilèges", privileged.Count == 0 ? "Aucun" : string.Join(", ", privileged), privileged.Count == 0 ? Tone.Ok : Tone.Warn),
        };
        var summary = AssistanceText.Count(direct.Count, "groupe direct", "groupes directs") + ", " + AssistanceText.Count(nested.Count, "imbriqué", "imbriqués")
            + " pour ce " + kind + FrenchText.Nbsp + "; " + (privileged.Count == 0 ? "aucun groupe à privilèges." : AssistanceText.Count(privileged.Count, "groupe à privilèges", "groupes à privilèges") + " à examiner.");
        return Reading(action, now, privileged.Count == 0 ? Tone.Ok : Tone.Warn, summary, facts, items, 12,
            "Appartenances lues dans l’annuaire, bornées à 2 000" + FrenchText.Nbsp + "; elles ne disent pas les droits effectifs sur une ressource.",
            [.. direct.Concat(nested.Values.Select(n => n.Group)).Select(g => new KnownName(g.Name, "Groupe", "Groupe"))]);
    }

    // ---------------------------------------------------------------- group policy

    /// <summary>GPO linked at each level above the object, from the domain down (fictitious but stable names).</summary>
    private static List<(string Level, string Name, bool Enforced, bool Disabled, bool ComputerSide)> Links(string dn)
    {
        var links = new List<(string, string, bool, bool, bool)>
        {
            (SimulationProfile.DnsName, "Default Domain Policy", false, false, true),
            (SimulationProfile.DnsName, "Socle de sécurité Example", true, false, true),
        };
        var site = SiteOf(dn);
        if (dn.Contains("OU=Postes", StringComparison.OrdinalIgnoreCase))
        {
            links.Add(("OU Postes", "Postes · Socle Windows 11", false, false, true));
            links.Add(("OU Postes", "Postes · Pare-feu Windows", false, false, true));
            links.Add(("OU Postes", "Postes · Windows Update", false, false, true));
            links.Add(("OU Postes", "Postes · Portables (filtre WMI)", false, false, true));
            links.Add(("OU Postes", "Postes · Ancien proxy", false, true, true));
            if (dn.Contains("OU=Quarantaine", StringComparison.OrdinalIgnoreCase))
            {
                links.Add(("OU Quarantaine", "Quarantaine · Isolement réseau", true, false, true));
            }
            else
            {
                links.Add(("OU " + site, "Imprimantes " + site, false, false, true));
                links.Add(("OU " + site, "Postes " + site + " · Énergie", false, false, true));
            }
        }
        else if (dn.Contains("OU=Utilisateurs", StringComparison.OrdinalIgnoreCase))
        {
            links.Add(("OU Utilisateurs", "Utilisateurs · Environnement de travail", false, false, false));
            links.Add(("OU Utilisateurs", "Utilisateurs · Redirection de dossiers", false, false, false));
            links.Add(("OU " + site, "Lecteurs réseau " + site, false, false, false));
            links.Add(("OU " + site, "Imprimantes utilisateurs " + site, false, false, false));
            var service = DistinguishedName.Parse(dn).Skip(1).FirstOrDefault().Value ?? "";
            if (service.Length > 0 && service != site)
            {
                links.Add(("OU " + service, "Applications " + service, false, false, false));
            }
        }
        else if (dn.Contains("OU=Comptes à privilèges", StringComparison.OrdinalIgnoreCase))
        {
            links.Add(("OU Comptes à privilèges", "Comptes à privilèges · Restrictions", true, false, false));
        }
        return links;
    }

    private StepReading GpoLinks(AssistanceAction action, string dn)
    {
        var links = Links(dn);
        var levels = links.Select(l => l.Level).Distinct().Count();
        var disabled = links.Count(l => l.Disabled);
        var items = links.Select(l => new StepItem(l.Name, "Lien sur " + l.Level + (l.Disabled ? " · lien désactivé" : l.Enforced ? " · appliqué (non remplaçable)" : " · actif"),
            l.Disabled ? Tone.Off : l.Enforced ? Tone.Info : Tone.Ok)).ToList();
        var facts = new[]
        {
            new StepFact("Niveaux lus", FrenchText.Integer(levels), Tone.Off),
            new StepFact("Liens actifs", FrenchText.Integer(links.Count - disabled), Tone.Ok),
            new StepFact("Liens désactivés", FrenchText.Integer(disabled), disabled > 0 ? Tone.Warn : Tone.Off),
            new StepFact("Héritage bloqué", "Non", Tone.Off),
        };
        var summary = AssistanceText.Count(links.Count - disabled, "stratégie liée", "stratégies liées") + " sur " + AssistanceText.Count(levels, "niveau", "niveaux")
            + (disabled > 0 ? ", " + AssistanceText.Count(disabled, "lien désactivé", "liens désactivés") : "") + ". Le résultat réel dépend des filtres et de l’application sur le poste.";
        return Reading(action, now, disabled > 0 ? Tone.Info : Tone.Ok, summary, facts, items, 12,
            "Liens lus dans l’annuaire" + FrenchText.Nbsp + "; ils ne prouvent pas que la stratégie a été appliquée (étape « Stratégies appliquées »).");
    }

    private StepReading GpoApplied(AssistanceAction action, DirectoryComputer computer)
    {
        var laptop = computer.Name.StartsWith("PT-", StringComparison.Ordinal);
        var links = Links(computer.DistinguishedName).Where(l => l.ComputerSide && !l.Disabled).ToList();
        var applied = new List<StepItem>();
        var filtered = new List<StepItem>();
        foreach (var link in links)
        {
            if (link.Name.Contains("Portables", StringComparison.Ordinal) && !laptop)
            {
                filtered.Add(new StepItem(link.Name, "Filtrée" + Colon + "le filtre WMI ne retient que les portables", Tone.Off));
            }
            else
            {
                applied.Add(new StepItem(link.Name, "Appliquée · " + link.Level, Tone.Ok));
            }
        }
        var last = now - TimeSpan.FromMinutes(random.Next(20, 60 * 20));
        var stale = random.Chance(8);
        if (stale)
        {
            last = now - TimeSpan.FromDays(random.Next(9, 21));
        }
        var facts = new[]
        {
            new StepFact("Dernière application", Date(last), stale ? Tone.Warn : Tone.Ok),
            new StepFact("Stratégies appliquées", FrenchText.Integer(applied.Count), Tone.Ok),
            new StepFact("Stratégies filtrées", FrenchText.Integer(filtered.Count), Tone.Off),
            new StepFact("Durée du traitement", FrenchText.Decimal(random.Next(8, 46) / 10.0) + FrenchText.Nbsp + "s", Tone.Off),
        };
        var summary = stale
            ? "Les stratégies n’ont pas été appliquées depuis le " + Date(last) + Colon + "le poste ne joint peut-être plus le contrôleur."
            : AssistanceText.Count(applied.Count, "stratégie appliquée", "stratégies appliquées") + " le " + Date(last) + (filtered.Count > 0 ? ", " + AssistanceText.Count(filtered.Count, "filtrée", "filtrées") : "") + ".";
        return Reading(action, now, stale ? Tone.Warn : Tone.Ok, summary, facts, [.. applied, .. filtered], 12,
            "Dernier résultat enregistré par le poste (RSoP), sans actualisation des stratégies.");
    }

    // ---------------------------------------------------------------- workstation reads

    private StepReading Diagnostics(AssistanceAction action, DirectoryComputer computer, WorkstationObservation? observation)
    {
        var refused = world.Presence.ErrorProbes.Contains(computer.ObjectGuid);
        var answered = !AdValues.IsDisabled(computer.UserAccountControl) && !world.Presence.NeverAnswer.Contains(computer.ObjectGuid)
            && (observation?.Presence is not { HasReading: true, Answered: false }) && (observation?.Presence.HasReading == true || random.Chance(80));
        var laptop = computer.Name.StartsWith("PT-", StringComparison.Ordinal);
        var latency = random.Next(1, 28);
        string Port(string name, bool open) => name + (answered ? (open ? " ouvert" : " filtré") : " sans réponse");
        var items = new List<StepItem>
        {
            new(Port("135 (RPC)", true), "Appel de procédure distante, utilisé par WMI", answered ? Tone.Ok : Tone.Off),
            new(Port("445 (SMB)", !refused), "Partages administratifs (C$, ADMIN$)", answered ? (refused ? Tone.Warn : Tone.Ok) : Tone.Off),
            new(Port("3389 (RDP)", !laptop), "Bureau à distance", answered ? (laptop ? Tone.Off : Tone.Ok) : Tone.Off),
            new(Port("5985 (WinRM)", false), "Administration à distance PowerShell", Tone.Off),
        };
        var facts = new[]
        {
            new StepFact("Ping", answered ? "Réponse en " + FrenchText.Integer(latency) + FrenchText.Nbsp + "ms" : "Aucune réponse", answered ? Tone.Ok : Tone.Alert),
            new StepFact("Nom résolu", computer.DnsHostName ?? computer.Name, Tone.Off),
            new StepFact("Ports d’administration", answered ? (refused ? "RPC ouvert, SMB filtré" : "RPC et SMB ouverts") : "Sans réponse", answered ? (refused ? Tone.Warn : Tone.Ok) : Tone.Alert),
        };
        var summary = answered
            ? "Le poste répond en " + FrenchText.Integer(latency) + FrenchText.Nbsp + "ms" + (refused ? Colon + "SMB filtré, les lectures d’administration risquent d’être refusées." : " et ses ports d’administration sont ouverts.")
            : "Aucune réponse au ping ni sur les ports d’administration" + Colon + "le poste semble hors réseau, ou il est filtré.";
        return Reading(action, now, answered ? (refused ? Tone.Warn : Tone.Ok) : Tone.Alert, summary, facts, items, 8,
            "Un ping filtré n’est pas un poste arrêté" + FrenchText.Nbsp + "; un port ouvert ne prouve pas que les droits suffisent.",
            [Machine(computer.DnsHostName ?? computer.Name)]);
    }

    private StepReading Identity(AssistanceAction action, DirectoryComputer computer)
    {
        var site = SiteOf(computer.DistinguishedName);
        var address = "10." + (SiteIndex(site) * 10 + 11).ToString(CultureInfo.InvariantCulture) + "." + random.Next(1, 31).ToString(CultureInfo.InvariantCulture) + "."
            + random.Next(10, 251).ToString(CultureInfo.InvariantCulture);
        var mismatch = random.Chance(3);
        var returned = mismatch ? "PC-" + CodeOf(site) + "-" + random.Next(1, 999).ToString("D4", CultureInfo.InvariantCulture) : computer.Name;
        var recordAge = random.Next(0, 21);
        var facts = new[]
        {
            new StepFact("Nom DNS", computer.DnsHostName ?? "—", Tone.Off),
            new StepFact("Adresse résolue", address, Tone.Ok),
            new StepFact("Nom renvoyé par le poste (CIM)", returned, mismatch ? Tone.Alert : Tone.Ok),
            new StepFact("Âge de l’enregistrement DNS", AssistanceText.Count(recordAge, "jour", "jours"), recordAge > 14 ? Tone.Warn : Tone.Off),
        };
        var summary = mismatch
            ? "Le nom " + computer.DnsHostName + " résout en " + address + ", mais le poste qui répond s’appelle " + returned + Colon + "enregistrement DNS périmé ou poste renommé."
            : "Le nom " + computer.DnsHostName + " résout en " + address + " et le poste renvoie bien le nom " + computer.Name + ".";
        return Reading(action, now, mismatch ? Tone.Alert : recordAge > 14 ? Tone.Warn : Tone.Ok, summary, facts, [], 0,
            "Résolution faite depuis ce poste" + FrenchText.Nbsp + "; un autre site peut voir un autre enregistrement.",
            [Machine(computer.DnsHostName ?? computer.Name), Machine(returned)]);
    }

    private StepReading Inventory(AssistanceAction action, DirectoryComputer computer, WorkstationObservation? observation, bool deep)
    {
        var known = observation?.Inventory is { HasReading: true } inventory ? inventory : null;
        var laptop = computer.Name.StartsWith("PT-", StringComparison.Ordinal);
        var model = known?.Model ?? random.Pick(laptop ? SimulationProfile.LaptopModels : SimulationProfile.DesktopModels);
        var memory = known?.MemoryBytes ?? (random.Chance(50) ? 16L : 8L) * 1024 * 1024 * 1024;
        var size = known?.SystemDiskSizeBytes ?? 256L * 1000 * 1000 * 1000;
        var free = known?.SystemDiskFreeBytes ?? (long)(size * (random.Next(18, 61) / 100.0));
        var boot = known?.LastBootAt ?? now - TimeSpan.FromHours(random.Next(3, 24 * 12));
        var os = known?.OsCaption ?? computer.OperatingSystem ?? "Windows";
        var skew = random.Chance(4) ? random.Next(330, 560) * (random.Chance(50) ? 1 : -1) : random.Next(-25, 26);
        var freePercent = size > 0 ? Math.Round(free * 100.0 / size, 1) : 0;
        var uptime = (now - boot).TotalDays;
        var memoryUsed = random.Next(42, 93);
        var gib = 1024.0 * 1024 * 1024;
        var skewText = (skew < 0 ? FrenchText.Minus : "+") + FrenchText.Integer(Math.Abs(skew)) + FrenchText.Nbsp + "s";
        var facts = new List<StepFact>
        {
            new("Système", os + (known?.Build is { } build ? " (build " + build + ")" : ""), Tone.Off),
            new("Modèle", model, Tone.Off),
            new("Mémoire", FrenchText.Decimal(memory / gib, 0) + FrenchText.Nbsp + "Go · " + FrenchText.Integer(memoryUsed) + FrenchText.Nbsp + "% utilisés", memoryUsed > 85 ? Tone.Warn : Tone.Ok),
            new("Disque C:", FrenchText.Percent(freePercent) + " libre sur " + FrenchText.Decimal(size / 1e9, 0) + FrenchText.Nbsp + "Go", freePercent < 10 ? Tone.Alert : freePercent < 20 ? Tone.Warn : Tone.Ok),
            new("Dernier démarrage", Date(boot) + " (" + AssistanceText.Count((long)uptime, "jour", "jours") + ")", uptime > 30 ? Tone.Warn : Tone.Off),
            new("Écart d’horloge", skewText + " avec le contrôleur", Math.Abs(skew) > 300 ? Tone.Alert : Tone.Ok),
        };
        var items = new List<StepItem>();
        if (deep)
        {
            var cpu = random.Pick(new[] { "Intel Core i5-1345U", "Intel Core i7-1365U", "AMD Ryzen 5 PRO 7540U", "Intel Core i5-13500" });
            facts.Add(new StepFact("Processeur", cpu, Tone.Off));
            facts.Add(new StepFact("BIOS", "Version 1." + random.Next(10, 32).ToString(CultureInfo.InvariantCulture) + ".0", Tone.Off));
            facts.Add(new StepFact("Redémarrage en attente", random.Chance(25) ? "Oui (mises à jour)" : "Non", Tone.Off));
            items.Add(new StepItem("Disque C: · système", FrenchText.Decimal(free / 1e9, 1) + FrenchText.Nbsp + "Go libres sur " + FrenchText.Decimal(size / 1e9, 0) + FrenchText.Nbsp + "Go", freePercent < 10 ? Tone.Alert : Tone.Ok));
            if (!laptop && random.Chance(35))
            {
                items.Add(new StepItem("Disque D: · données", FrenchText.Decimal(random.Next(80, 400), 0) + FrenchText.Nbsp + "Go libres sur 500" + FrenchText.Nbsp + "Go", Tone.Ok));
            }
            items.Add(new StepItem("Carte réseau " + (laptop ? "Wi-Fi" : "Ethernet 1 Gbit/s"), "Adresse obtenue par DHCP", Tone.Ok));
            foreach (var (process, mb) in new[] { ("msedge.exe", random.Next(600, 2200)), ("ms-teams.exe", random.Next(400, 1400)), ("OUTLOOK.EXE", random.Next(250, 800)), ("MsMpEng.exe", random.Next(150, 400)) })
            {
                items.Add(new StepItem(process, FrenchText.Integer(mb) + FrenchText.Nbsp + "Mo de mémoire", mb > 1500 ? Tone.Warn : Tone.Off));
            }
        }
        var problems = new List<string>();
        if (freePercent < 10)
        {
            problems.Add("disque C: presque plein");
        }
        if (uptime > 30)
        {
            problems.Add("pas de redémarrage depuis " + AssistanceText.Count((long)uptime, "jour", "jours"));
        }
        if (Math.Abs(skew) > 300)
        {
            problems.Add("horloge décalée de plus de 5 minutes (Kerberos refuse l’ouverture de session)");
        }
        if (memoryUsed > 85)
        {
            problems.Add("mémoire presque saturée");
        }
        var summary = problems.Count == 0
            ? (deep ? "Inventaire complet" : "Inventaire rapide") + Colon + "mémoire, disque, démarrage et horloge sans signal particulier."
            : (deep ? "Inventaire complet" : "Inventaire rapide") + Colon + string.Join(", ", problems) + ".";
        var tone = Math.Abs(skew) > 300 || freePercent < 10 ? Tone.Alert : problems.Count > 0 ? Tone.Warn : Tone.Ok;
        return Reading(action, now, tone, summary, facts, items, 10, "Valeurs lues sur le poste à cet instant (CIM)" + FrenchText.Nbsp + "; elles changent avec l’usage.");
    }

    private StepReading Software(AssistanceAction action, DirectoryComputer computer)
    {
        var site = SiteOf(computer.DistinguishedName);
        var list = new List<(string Name, string Publisher, string Version, int SizeMb)>
        {
            ("Microsoft 365 Apps pour entreprise", "Microsoft Corporation", "16.0." + random.Next(17000, 18200).ToString(CultureInfo.InvariantCulture), 2900),
            ("Microsoft Edge", "Microsoft Corporation", "141.0." + random.Next(3000, 3600).ToString(CultureInfo.InvariantCulture) + ".55", 620),
            ("Microsoft Teams", "Microsoft Corporation", "25." + random.Next(100, 300).ToString(CultureInfo.InvariantCulture) + ".0", 380),
            ("7-Zip 24.08", "Igor Pavlov", "24.08", 6),
            ("Adobe Acrobat Reader", "Adobe", "25.001." + random.Next(20000, 21000).ToString(CultureInfo.InvariantCulture), 720),
            ("Notepad++", "Notepad++ Team", "8.7." + random.Next(1, 9).ToString(CultureInfo.InvariantCulture), 16),
            ("FortiClient VPN", "Fortinet", "7.4." + random.Next(0, 4).ToString(CultureInfo.InvariantCulture), 240),
            ("Citrix Workspace", "Citrix Systems", "24." + random.Next(2, 12).ToString(CultureInfo.InvariantCulture), 310),
            ("Pilote HP Universal Printing PCL 6", "HP", "7.3.0." + random.Next(25000, 26000).ToString(CultureInfo.InvariantCulture), 45),
        };
        if (random.Chance(55))
        {
            list.Add(("Pilote Xerox Global Print Driver", "Xerox", "5.1009." + random.Next(1, 9).ToString(CultureInfo.InvariantCulture), 70));
        }
        if (random.Chance(40))
        {
            list.Add(("VLC media player", "VideoLAN", "3.0.21", 160));
        }
        if (random.Chance(30))
        {
            list.Add(("Outil de capture " + site, "Example SA", "2." + random.Next(0, 9).ToString(CultureInfo.InvariantCulture), 30));
        }
        list.Add(("Agent de supervision Example", "Example SA", "4.2." + random.Next(0, 9).ToString(CultureInfo.InvariantCulture), 55));
        var ordered = list.OrderBy(s => s.Name, StringComparer.Create(CultureInfo.GetCultureInfo("fr-FR"), true)).ToList();
        var largest = ordered.MaxBy(s => s.SizeMb);
        var drivers = ordered.Count(s => s.Name.StartsWith("Pilote", StringComparison.Ordinal));
        var lastInstall = now - TimeSpan.FromDays(random.Next(1, 40));
        var items = ordered.Select(s => new StepItem(s.Name + " " + s.Version, s.Publisher + " · " + FrenchText.Integer(s.SizeMb) + FrenchText.Nbsp + "Mo",
            s.Name.StartsWith("Pilote", StringComparison.Ordinal) ? Tone.Info : Tone.Off)).ToList();
        var facts = new[]
        {
            new StepFact("Logiciels installés", FrenchText.Integer(ordered.Count), Tone.Off),
            new StepFact("Pilotes d’impression", FrenchText.Integer(drivers), drivers == 0 ? Tone.Warn : Tone.Ok),
            new StepFact("Le plus volumineux", largest.Name + " (" + FrenchText.Decimal(largest.SizeMb / 1000.0, 1) + FrenchText.Nbsp + "Go)", Tone.Off),
            new StepFact("Dernière installation", Date(lastInstall), Tone.Off),
        };
        var summary = AssistanceText.Count(ordered.Count, "logiciel installé", "logiciels installés") + ", dont " + AssistanceText.Count(drivers, "pilote d’impression", "pilotes d’impression")
            + Colon + "le plus volumineux est " + largest.Name + ".";
        return Reading(action, now, Tone.Ok, summary, facts, items, 12, "Lu dans le registre du poste (clés Uninstall)" + FrenchText.Nbsp + "; un logiciel portable n’y figure pas.");
    }

    private StepReading Sessions(AssistanceAction action, DirectoryComputer computer)
    {
        var items = new List<StepItem>();
        var disconnected = 0;
        if (computer.ManagedByDn is { } owner && random.Chance(75) && directory.Users.FirstOrDefault(u => u.DistinguishedName.Equals(owner, StringComparison.OrdinalIgnoreCase)) is { } user)
        {
            items.Add(new StepItem("Console · " + user.SamAccountName, "Active · inactive depuis " + AssistanceText.Count(random.Next(1, 25), "minute", "minutes"), Tone.Ok));
        }
        else if (random.Chance(55))
        {
            var people = directory.Users.Where(u => u.DistinguishedName.Contains("OU=" + SiteOf(computer.DistinguishedName) + ",OU=Utilisateurs", StringComparison.OrdinalIgnoreCase)).ToList();
            if (people.Count > 0)
            {
                items.Add(new StepItem("Console · " + random.Pick(people).SamAccountName, "Active · inactive depuis " + AssistanceText.Count(random.Next(1, 90), "minute", "minutes"), Tone.Ok));
            }
        }
        if (random.Chance(30))
        {
            disconnected++;
            var admin = random.Pick(SimulationProfile.AdminPeople).Sam;
            items.Add(new StepItem("RDP · " + admin, "Déconnectée depuis " + AssistanceText.Count(random.Next(1, 6), "jour", "jours"), Tone.Warn));
        }
        var facts = new[]
        {
            new StepFact("Sessions ouvertes", FrenchText.Integer(items.Count), Tone.Off),
            new StepFact("Sessions déconnectées", FrenchText.Integer(disconnected), disconnected > 0 ? Tone.Warn : Tone.Off),
        };
        var summary = items.Count == 0
            ? "Aucune session ouverte sur ce poste."
            : AssistanceText.Count(items.Count, "session ouverte", "sessions ouvertes") + (disconnected > 0 ? ", dont " + AssistanceText.Count(disconnected, "déconnectée", "déconnectées") + " qui garde mémoire et profil." : ".");
        return Reading(action, now, disconnected > 0 ? Tone.Warn : Tone.Ok, summary, facts, items, 8, "Sessions lues sans en fermer aucune.",
            [.. items.Select(i => new KnownName(i.Title[(i.Title.IndexOf('·', StringComparison.Ordinal) + 1)..].Trim(), "Compte", "Compte"))]);
    }
}
