using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json.Nodes;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Reads of the Assistance screen in simulation (docs/ops/assistance.md): derived from the fictitious directory as the session
/// sees it (<see cref="SimulatedDirectorySource.CurrentDirectory"/>) and from its observations, in memory, no network and no
/// disk. Data that the generated world does not hold (lockout events, GPO, software, sessions…) comes from the named sub-stream
/// « screen/assistance » of the seed, one fork per read and object: the same seed always gives the same answers, and these
/// draws never move the directory nor another screen. Every read waits a short realistic delay (« latency/screen/assistance/… »).
/// It serves both interfaces of the screen, like the OU tree reader: <see cref="IAssistanceIndex"/> (what the local base holds
/// in directory mode) and <see cref="IAssistanceReader"/> (what is read from the directory or a workstation).
/// </summary>
public sealed class SimulatedAssistanceReader : IAssistanceReader, IAssistanceIndex
{
    private const string Screen = "assistance";
    private readonly SimulatedDirectorySource source;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedAssistanceReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    private DateTimeOffset Now => source.Clock.GetUtcNow();

    private TimeZoneInfo Zone => source.World.TimeZone;

    public async Task<ImmutableArray<SubjectHit>> SearchAsync(string text, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(text);
        await source.SimulateScreenLatencyAsync(Screen + "/search", 40, 120, cancellationToken).ConfigureAwait(false);
        var wanted = FrenchText.Fold(text.Trim());
        if (wanted.Length == 0)
        {
            return [];
        }
        var directory = source.CurrentDirectory;
        var now = Now;
        var hits = new List<(int Rank, SubjectHit Hit)>();
        foreach (var user in directory.Users)
        {
            var rank = Rank(wanted, user.SamAccountName, user.DisplayName ?? user.Cn, user.UserPrincipalName, user.Mail);
            if (rank >= 0)
            {
                hits.Add((rank, UserHit(user, directory, now)));
            }
        }
        foreach (var computer in directory.Computers)
        {
            var rank = Rank(wanted, computer.Name, computer.Name, computer.DnsHostName, null);
            if (rank >= 0)
            {
                hits.Add((rank, ComputerHit(computer, null)));
            }
        }
        return [.. hits.OrderBy(h => h.Rank).ThenBy(h => h.Hit.Kind).ThenBy(h => h.Hit.Name, StringComparer.Create(CultureInfo.GetCultureInfo("fr-FR"), true))
            .Take(Math.Clamp(limit, 1, 50)).Select(h => h.Hit)];
    }

    public async Task<ImmutableArray<NamedComputer>> ComputersNamedAsync(IReadOnlyList<string> names, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(names);
        await source.SimulateScreenLatencyAsync(Screen + "/search", 40, 120, cancellationToken).ConfigureAwait(false);
        var byName = new Dictionary<string, DirectoryComputer>(StringComparer.OrdinalIgnoreCase);
        foreach (var computer in source.CurrentDirectory.Computers)
        {
            byName.TryAdd(computer.Name, computer);
            byName.TryAdd(computer.SamAccountName.TrimEnd('$'), computer);
            if (computer.DnsHostName is { } dns)
            {
                byName.TryAdd(dns, computer);
            }
        }
        var found = new List<NamedComputer>();
        foreach (var name in names)
        {
            var key = (name ?? "").Trim().TrimEnd('$');
            if (key.Length > 0 && byName.TryGetValue(key, out var computer))
            {
                found.Add(new NamedComputer(name!.Trim(), computer.ObjectGuid, ComputerHit(computer, null)));
            }
        }
        return [.. found];
    }

    public async Task<ImmutableArray<SubjectSuggestion>> SuggestionsAsync(ScopeSelection? scope, CancellationToken cancellationToken)
    {
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var now = Now;
        var policy = directory.Domain.PasswordPolicy;
        var suggestions = new List<SubjectSuggestion>();
        var people = directory.Users.Where(u => !AdValues.IsDisabled(u.UserAccountControl) && u.DistinguishedName.Contains("OU=Utilisateurs", StringComparison.OrdinalIgnoreCase)).ToList();
        var locked = people.Where(u => AccountState.Evaluate(u.UserAccountControl, u.ComputedAccountControl, u.LockoutTime).Lock == LockState.Locked)
            .OrderByDescending(u => u.SamAccountName == "c.bernard").ThenByDescending(u => u.LockoutTime).Take(2);
        foreach (var user in locked)
        {
            suggestions.Add(new SubjectSuggestion(UserHit(user, directory, now), "Compte verrouillé" + (user.BadPasswordCount is int bad ? " après " + AssistanceText.Count(bad, "échec", "échecs") : "")));
        }
        var expired = people.Where(u => AccountState.ClassifyPassword(u, policy.MaxPasswordAge, now, TimeSpan.FromDays(7)) == PasswordClass.Expired)
            .OrderBy(u => u.SamAccountName, StringComparer.Ordinal).Take(1);
        foreach (var user in expired)
        {
            suggestions.Add(new SubjectSuggestion(UserHit(user, directory, now), "Mot de passe expiré"));
        }
        var mustChange = people.Where(u => u.PasswordLastSet == 0).OrderBy(u => u.SamAccountName, StringComparer.Ordinal).Take(1);
        foreach (var user in mustChange)
        {
            suggestions.Add(new SubjectSuggestion(UserHit(user, directory, now), "Changement du mot de passe exigé"));
        }
        var observations = state.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var candidates = directory.Computers
            .Where(c => !AdValues.IsDisabled(c.UserAccountControl) && (scope is null || ScopeRules.Contains(scope, c.DistinguishedName)))
            .Select(c => (Computer: c, Observation: observations.GetValueOrDefault(c.ObjectGuid)))
            .ToList();
        var watch = new List<(int Order, DirectoryComputer Computer, WorkstationObservation? Observation, string Reason)>();
        foreach (var (computer, observation) in candidates)
        {
            if (observation is null)
            {
                continue;
            }
            if (FreePercent(observation.Inventory) is double free && free < 10)
            {
                watch.Add((0, computer, observation, "Disque C: presque plein (" + FrenchText.Percent(free) + " libre)"));
            }
            else if (observation.Presence.HasReading && observation.Presence.Answered == false)
            {
                watch.Add((1, computer, observation, "Aucune réponse au dernier relevé de présence"));
            }
            else if (observation.Inventory.LastBootAt is DateTimeOffset boot && (now - boot).TotalDays > 30)
            {
                watch.Add((2, computer, observation, "Sans redémarrage depuis " + AssistanceText.Count((long)(now - boot).TotalDays, "jour", "jours")));
            }
        }
        foreach (var group in watch.GroupBy(w => w.Order).OrderBy(g => g.Key))
        {
            foreach (var item in group.OrderBy(w => w.Computer.Name, StringComparer.Ordinal).Take(group.Key == 0 ? 2 : 1))
            {
                suggestions.Add(new SubjectSuggestion(ComputerHit(item.Computer, item.Observation), item.Reason));
            }
        }
        return [.. suggestions];
    }

    public async Task<SubjectRecord?> ReadSubjectAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await source.SimulateScreenLatencyAsync(Screen + "/read", 80, 220, cancellationToken).ConfigureAwait(false);
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var user = directory.Users.FirstOrDefault(u => SameDn(u.DistinguishedName, dn));
        if (user is not null)
        {
            return UserRecord(user, directory);
        }
        var computer = directory.Computers.FirstOrDefault(c => SameDn(c.DistinguishedName, dn));
        return computer is null ? null : ComputerRecord(computer, directory, state.Observations);
    }

    public async Task<SubjectRecord?> LocateAsync(Guid id, CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync(Screen + "/read", 80, 220, cancellationToken).ConfigureAwait(false);
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        if (directory.Users.FirstOrDefault(u => u.ObjectGuid == id) is { } user)
        {
            return UserRecord(user, directory);
        }
        return directory.Computers.FirstOrDefault(c => c.ObjectGuid == id) is { } computer ? ComputerRecord(computer, directory, state.Observations) : null;
    }

    public async Task<StepReading> RunStepAsync(AssistanceAction action, SubjectRecord subject, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(action);
        ArgumentNullException.ThrowIfNull(subject);
        var (min, max) = action.Id switch
        {
            "inventoryDeep" => (1200, 2400),
            "inventory" or "software" or "gpoApplied" or "machineIdentity" => (600, 1400),
            "diagnostics" or "sessions" or "lockoutEvents" => (400, 1000),
            _ => (150, 450),
        };
        await source.SimulateScreenLatencyAsync(Screen + "/step", min, max, cancellationToken).ConfigureAwait(false);
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var random = source.ScreenStream(Screen).Fork("step/" + action.Id + "/" + subject.Guid.ToString("N"));
        var steps = new SimulatedAssistanceSteps(directory, state.Observations, source.World, Now, Zone, random);
        return steps.Run(action, subject);
    }

    public async Task<ImmutableArray<RawIncident>> SessionIncidentsAsync(CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync(Screen + "/incidents", 30, 90, cancellationToken).ConfigureAwait(false);
        var world = source.World;
        var directory = source.CurrentDirectory;
        var reference = world.Reference;
        var incidents = new List<RawIncident>();
        var n = 0;
        foreach (var entry in world.Journal.Where(e => e.Tone is Tone.Warn or Tone.Alert))
        {
            incidents.Add(new RawIncident("simulation|journal|" + (n++).ToString(CultureInfo.InvariantCulture), entry.At, entry.Tone, "Journal", entry.Label, "simulation"));
        }
        string NameOf(Guid id, string fallback) => directory.Computers.FirstOrDefault(x => x.ObjectGuid == id)?.Name ?? fallback;
        var probe = world.Presence.ErrorProbes.Order().Select(id => NameOf(id, "PC-MRS-0012")).FirstOrDefault() ?? "PC-MRS-0012";
        var silent = world.Presence.NeverAnswer.Order().Select(id => NameOf(id, "PC-LIL-0007")).FirstOrDefault() ?? "PC-LIL-0007";
        var quarantined = directory.Computers.Where(c => AdValues.IsDisabled(c.UserAccountControl) && c.Name.StartsWith("P", StringComparison.Ordinal))
            .Select(c => c.Name).Order(StringComparer.Ordinal).FirstOrDefault() ?? "PC-BDX-0031";
        var laptop = directory.Computers.Where(c => c.Name.StartsWith("PT-PAR", StringComparison.Ordinal)).Select(c => c.Name).Order(StringComparer.Ordinal).Skip(3).FirstOrDefault() ?? "PT-PAR-0118";
        var desk = directory.Computers.Where(c => c.Name.StartsWith("PC-PAR", StringComparison.Ordinal)).Select(c => c.Name).Order(StringComparer.Ordinal).Skip(7).FirstOrDefault() ?? "PC-PAR-0007";
        var colon = FrenchText.Colon;
        (int Minutes, Tone Tone, string Area, string Text)[] extra =
        [
            (35, Tone.Warn, "Inventaire", $"Relevé d’inventaire de {laptop}{colon}délai dépassé après 60 s (lecture WMI)."),
            (64, Tone.Alert, "Inventaire", $"Accès refusé (0x80070005) à WMI sur {probe}{colon}le compte de la session n’est pas administrateur du poste."),
            (88, Tone.Alert, "Poste", $"Le serveur RPC n’est pas disponible (0x800706BA){colon}{silent} ne répond pas."),
            (140, Tone.Warn, "Partages", $"Erreur système 1219{colon}connexions multiples à \\\\srv-fic01\\commun avec des identifiants différents."),
            (180, Tone.Warn, "Poste", $"Hôte inconnu{colon}{quarantined.ToLowerInvariant()}.{SimulationProfile.DnsName} ne se résout pas (0x80070035)."),
            (240, Tone.Warn, "Moteur", $"Le moteur exécute déjà 8 tâches{colon}limite physique atteinte, lecture mise en attente."),
            (275, Tone.Alert, "Connexion", $"Échec d’ouverture de session{colon}identifiants non valides (0x8007052E) pour une lecture explicite."),
            (330, Tone.Warn, "Outils distants", $"PsExec{colon}code 1 renvoyé par {desk} (sortie à examiner)."),
        ];
        foreach (var item in extra)
        {
            incidents.Add(new RawIncident("simulation|extra|" + (n++).ToString(CultureInfo.InvariantCulture), reference - TimeSpan.FromMinutes(item.Minutes), item.Tone, item.Area, item.Text, "simulation"));
        }
        return [.. incidents];
    }

    public async Task<DossierData> DossierDataAsync(DossierRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        await source.SimulateScreenLatencyAsync(Screen + "/dossier", 300, 800, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var perimeter = request.Perimeter;
        var wanted = perimeter.Guids.Select(g => Guid.Parse(g)).ToHashSet();
        var inScope = directory.Computers.Where(c => perimeter.Kind == "OU"
                ? ScopeRules.Contains(new ScopeSelection(perimeter.OrganizationalUnit!, "", true), c.DistinguishedName)
                : wanted.Contains(c.ObjectGuid))
            .OrderBy(c => c.Name, StringComparer.Ordinal).ToList();
        var limit = Math.Clamp(request.Limit, 1, OfflineDossiers.MaxRows);
        var computersTruncated = inScope.Count > limit;
        var computers = inScope.Take(limit).ToList();
        var observations = state.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var controller = directory.Domain.Controllers.FirstOrDefault()?.DnsName ?? "";
        var computerRows = new JsonArray();
        var observationRows = new JsonArray();
        var linkRows = new JsonArray();
        foreach (var computer in computers)
        {
            computerRows.Add((JsonNode?)new JsonObject
            {
                ["Guid"] = computer.ObjectGuid.ToString("D"),
                ["Nom"] = computer.Name,
                ["DN"] = computer.DistinguishedName,
                ["Etat"] = AdValues.IsDisabled(computer.UserAccountControl) ? "Désactivé" : "Actif",
                ["Description"] = computer.Description,
                ["DerniereConnexion"] = Iso(AdValues.FromFileTime(computer.LastLogonTimestamp)),
                ["ModifieAD"] = Iso(computer.WhenChanged),
                ["SynchroniseUtc"] = Iso(directory.ReadAt),
                ["Controleur"] = controller,
                ["Systeme"] = computer.OperatingSystem + " " + computer.OperatingSystemVersion,
                ["CreeAD"] = Iso(computer.WhenCreated),
                ["MotDePasseMachineDefini"] = Iso(AdValues.FromFileTime(computer.PasswordLastSet)),
                ["FaitsLusUtc"] = Iso(directory.ReadAt),
            });
            if (observations.TryGetValue(computer.ObjectGuid, out var observation))
            {
                if (observation.Presence.State != MeasureState.NotRead)
                {
                    observationRows.Add((JsonNode?)Observation(computer, "presence", observation.Presence.State, observation.Presence.CheckedAt,
                        observation.Presence.Answered == true ? observation.Presence.CheckedAt : null,
                        new JsonObject { ["Repond"] = observation.Presence.Answered, ["DerniereReponseUtc"] = Iso(observation.Presence.LastOnlineAt) }));
                }
                if (observation.Inventory.State != MeasureState.NotRead)
                {
                    var inventory = observation.Inventory;
                    observationRows.Add((JsonNode?)Observation(computer, "inventaire", inventory.State, inventory.CheckedAt, inventory.HasReading ? inventory.CheckedAt : null,
                        new JsonObject
                        {
                            ["Modele"] = inventory.Model,
                            ["Systeme"] = inventory.OsCaption,
                            ["Build"] = inventory.Build,
                            ["MemoireOctets"] = inventory.MemoryBytes,
                            ["DisqueSystemeOctets"] = inventory.SystemDiskSizeBytes,
                            ["DisqueSystemeLibreOctets"] = inventory.SystemDiskFreeBytes,
                            ["DernierDemarrageUtc"] = Iso(inventory.LastBootAt),
                        }));
                }
            }
            if (computer.ManagedByDn is { } owner && directory.Users.FirstOrDefault(u => SameDn(u.DistinguishedName, owner)) is { } user)
            {
                linkRows.Add((JsonNode?)new JsonObject
                {
                    ["Poste"] = computer.Name,
                    ["Compte"] = user.SamAccountName,
                    ["Source"] = "managedBy",
                    ["Confiance"] = 90,
                    ["VerifieAD"] = true,
                    ["ObserveUtc"] = Iso(directory.ReadAt),
                    ["Details"] = "Responsable déclaré dans l’annuaire (managedBy).",
                    ["CompteGuid"] = user.ObjectGuid.ToString("D"),
                    ["PosteGuid"] = computer.ObjectGuid.ToString("D"),
                    ["CompteDN"] = user.DistinguishedName,
                    ["PosteDN"] = computer.DistinguishedName,
                });
            }
        }
        var observationsTruncated = observationRows.Count > limit;
        while (observationRows.Count > limit)
        {
            observationRows.RemoveAt(observationRows.Count - 1);
        }
        var sourceInfo = new JsonObject
        {
            ["Base"] = "Annuaire fictif de la simulation, en mémoire",
            ["Domaine"] = directory.Domain.DnsName,
            ["LectureAnnuaireUtc"] = Iso(directory.ReadAt),
            ["Revision"] = source.Overlay.Version,
            ["Simulation"] = true,
        };
        var stateInfo = new JsonObject
        {
            ["Base"] = "Simulation",
            ["Domaine"] = directory.Domain.DnsName,
            ["DerniereLectureUtc"] = Iso(directory.ReadAt),
            ["LectureComplete"] = directory.Complete,
            ["Objets"] = directory.ObjectCount,
            ["Familles"] = new JsonObject
            {
                ["Utilisateurs"] = directory.Users.Length,
                ["Postes"] = directory.Computers.Length,
                ["Groupes"] = directory.Groups.Length,
                ["UnitesOrganisation"] = directory.OrganizationalUnits.Length,
            },
            ["ReleveObservationsUtc"] = Iso(state.Observations.TakenAt),
        };
        return new DossierData(sourceInfo, stateInfo, computerRows, computersTruncated, observationRows, observationsTruncated, linkRows, new JsonArray(),
            ["Simulation" + FrenchText.Colon + "données fictives de l’annuaire " + directory.Domain.DnsName + ", aucune base locale ouverte."]);
    }

    // ---------------------------------------------------------------- helpers

    private static JsonObject Observation(DirectoryComputer computer, string family, MeasureState state, DateTimeOffset? attempt, DateTimeOffset? success, JsonObject data) => new()
    {
        ["Guid"] = computer.ObjectGuid.ToString("D"),
        ["DN"] = computer.DistinguishedName,
        ["Famille"] = family,
        ["Statut"] = state.ToString(),
        ["TentativeUtc"] = Iso(attempt),
        ["ReussiteUtc"] = Iso(success),
        ["Erreur"] = state is MeasureState.Error or MeasureState.Refused ? "Lecture non aboutie" : null,
        ["Definition"] = null,
        ["Donnees"] = data,
        ["Note"] = "",
    };

    private static string? Iso(DateTimeOffset? value) => value?.UtcDateTime.ToString("o", CultureInfo.InvariantCulture);

    internal static bool SameDn(string left, string right)
    {
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    internal static double? FreePercent(InventoryMeasure inventory) =>
        inventory.HasReading && inventory.SystemDiskSizeBytes is long size && size > 0 && inventory.SystemDiskFreeBytes is long free
            ? Math.Round(free * 100.0 / size, 1) : null;

    /// <summary>Rank of a match: 0 exact login, 1 start of a name, 2 anywhere; −1 none.</summary>
    private static int Rank(string wanted, string login, string name, string? third, string? fourth)
    {
        var l = FrenchText.Fold(login);
        if (l == wanted)
        {
            return 0;
        }
        var n = FrenchText.Fold(name);
        if (l.StartsWith(wanted, StringComparison.Ordinal) || n.StartsWith(wanted, StringComparison.Ordinal) || n.Contains(" " + wanted, StringComparison.Ordinal))
        {
            return 1;
        }
        foreach (var value in new[] { l, n, third is null ? "" : FrenchText.Fold(third), fourth is null ? "" : FrenchText.Fold(fourth) })
        {
            if (value.Contains(wanted, StringComparison.Ordinal))
            {
                return 2;
            }
        }
        return -1;
    }

    /// <summary>Readable path of the containers of a DN, without the domain: « Utilisateurs › Lyon › Commercial ».</summary>
    internal static string ContainerPath(string dn)
    {
        try
        {
            var names = DistinguishedName.Parse(dn);
            var containers = names.Skip(1).Where(r => !r.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)).Select(r => r.Value).Reverse();
            return string.Join(FrenchText.PathSeparator, containers);
        }
        catch (FormatException)
        {
            return "";
        }
    }

    internal static (Tone Tone, string Label) UserState(DirectoryUser user, DirectorySnapshot directory, DateTimeOffset now)
    {
        var state = AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime);
        if (state.Disabled)
        {
            return (Tone.Off, "Désactivé");
        }
        if (state.Lock == LockState.Locked)
        {
            return (Tone.Alert, "Verrouillé");
        }
        if (state.Lock == LockState.ToCheck)
        {
            return (Tone.Warn, "Verrouillage à vérifier");
        }
        return AccountState.ClassifyPassword(user, directory.Domain.PasswordPolicy.MaxPasswordAge, now, TimeSpan.FromDays(7)) switch
        {
            PasswordClass.Expired => (Tone.Warn, "Mot de passe expiré"),
            PasswordClass.MustChange => (Tone.Info, "Mot de passe à changer"),
            PasswordClass.Expiring => (Tone.Info, "Mot de passe bientôt expiré"),
            _ => (Tone.Ok, "Actif"),
        };
    }

    private static SubjectHit UserHit(DirectoryUser user, DirectorySnapshot directory, DateTimeOffset now)
    {
        var (tone, label) = UserState(user, directory, now);
        var detail = string.Join(" · ", new[] { user.Title, user.Department }.Where(v => !string.IsNullOrWhiteSpace(v)));
        if (detail.Length == 0)
        {
            detail = user.Description ?? "Compte utilisateur";
        }
        return new SubjectHit(user.DistinguishedName, AssistanceSubject.User, user.DisplayName ?? user.Cn, user.SamAccountName, detail, ContainerPath(user.DistinguishedName), tone, label);
    }

    private static SubjectHit ComputerHit(DirectoryComputer computer, WorkstationObservation? observation)
    {
        var (tone, label) = ComputerState(computer, observation);
        var system = WindowsRelease.Describe(computer.OperatingSystem, computer.OperatingSystemVersion)?.Label ?? computer.OperatingSystem ?? "Système inconnu";
        return new SubjectHit(computer.DistinguishedName, AssistanceSubject.Computer, computer.Name, computer.SamAccountName, system, ContainerPath(computer.DistinguishedName), tone, label);
    }

    internal static (Tone Tone, string Label) ComputerState(DirectoryComputer computer, WorkstationObservation? observation)
    {
        if (AdValues.IsDisabled(computer.UserAccountControl))
        {
            return (Tone.Off, "Désactivé");
        }
        if (observation?.Presence is { } presence && presence.HasReading)
        {
            return presence.Answered == true ? (Tone.Ok, "En ligne") : (Tone.Warn, "Hors ligne au dernier relevé");
        }
        return (Tone.Off, observation is null ? "Actif" : "Présence inconnue");
    }

    private string Date(DateTimeOffset? at) =>
        at is DateTimeOffset value ? TimeZoneInfo.ConvertTime(value, Zone).ToString("dd'/'MM'/'yyyy' à 'HH':'mm", CultureInfo.InvariantCulture) : "—";

    private SubjectRecord UserRecord(DirectoryUser user, DirectorySnapshot directory)
    {
        var now = Now;
        var properties = new Dictionary<string, IReadOnlyList<object?>>(StringComparer.OrdinalIgnoreCase);
        void Put(string name, object? value)
        {
            if (value is not null)
            {
                properties[name] = [value];
            }
        }
        Put("name", user.Cn);
        Put("distinguishedName", user.DistinguishedName);
        Put("objectGUID", user.ObjectGuid);
        Put("sAMAccountName", user.SamAccountName);
        Put("userPrincipalName", user.UserPrincipalName);
        Put("displayName", user.DisplayName);
        Put("mail", user.Mail);
        Put("department", user.Department);
        Put("title", user.Title);
        Put("physicalDeliveryOfficeName", user.Office);
        Put("manager", user.ManagerDn);
        Put("userAccountControl", user.UserAccountControl);
        Put("msDS-User-Account-Control-Computed", user.ComputedAccountControl);
        Put("lockoutTime", user.LockoutTime);
        Put("pwdLastSet", user.PasswordLastSet);
        Put("accountExpires", user.AccountExpires);
        Put("whenCreated", user.WhenCreated);
        Put("whenChanged", user.WhenChanged);
        Put("uSNChanged", user.UsnChanged);
        properties["memberOf"] = [.. user.MemberOf.Cast<object?>()];
        Put("primaryGroupID", user.PrimaryGroupId);
        Put("adminCount", user.AdminCount);

        var (tone, label) = UserState(user, directory, now);
        var policy = directory.Domain.PasswordPolicy;
        var passwordClass = AccountState.ClassifyPassword(user, policy.MaxPasswordAge, now, TimeSpan.FromDays(7));
        var expiry = AdValues.FromFileTime(user.PasswordExpiryComputed)
            ?? (AdValues.FromFileTime(user.PasswordLastSet) is DateTimeOffset set && policy.MaxPasswordAge > TimeSpan.Zero ? set + policy.MaxPasswordAge : null);
        var password = passwordClass switch
        {
            PasswordClass.MustChange => ("À changer à la prochaine ouverture de session", Tone.Info),
            PasswordClass.NeverExpires => ("N’expire jamais", Tone.Info),
            PasswordClass.Expired => ("Expiré" + (expiry is null ? "" : " le " + Date(expiry)), Tone.Warn),
            PasswordClass.Expiring => ("Expire le " + Date(expiry), Tone.Warn),
            _ => (expiry is null ? "Valide" : "Valide jusqu’au " + Date(expiry), Tone.Ok),
        };
        var facts = ImmutableArray.Create(
            new SubjectFact("État", label, tone),
            new SubjectFact("Mot de passe", password.Item1, password.Item2),
            new SubjectFact("Dernière connexion", AdValues.FromFileTime(user.LastLogonTimestamp) is DateTimeOffset logon ? Date(logon) : "Jamais connecté", Tone.Off),
            new SubjectFact("Échecs de mot de passe", user.BadPasswordCount is int bad ? FrenchText.Integer(bad) : "—", user.BadPasswordCount is > 2 ? Tone.Warn : Tone.Off),
            new SubjectFact("Service", user.Department ?? "—", Tone.Off),
            new SubjectFact("Fonction", user.Title ?? user.Description ?? "—", Tone.Off));
        var pills = new List<SubjectPill> { new(tone, label) };
        if (user.AdminCount == 1)
        {
            pills.Add(new SubjectPill(Tone.Info, "Compte protégé (adminCount)"));
        }
        if (user.BadPasswordCount is > 0 && tone != Tone.Alert)
        {
            pills.Add(new SubjectPill(Tone.Warn, AssistanceText.Count(user.BadPasswordCount.Value, "échec récent", "échecs récents")));
        }
        var related = directory.Computers.Where(c => c.ManagedByDn is { } owner && SameDn(owner, user.DistinguishedName))
            .OrderBy(c => c.Name, StringComparer.Ordinal).Select(c => ComputerHit(c, null)).ToImmutableArray();
        return new SubjectRecord(user.DistinguishedName, user.ObjectGuid, AssistanceSubject.User, user.DisplayName ?? user.Cn, user.SamAccountName,
            ContainerPath(user.DistinguishedName), properties, true, null, facts, [.. pills], related, now);
    }

    private SubjectRecord ComputerRecord(DirectoryComputer computer, DirectorySnapshot directory, FleetObservations fleet)
    {
        var now = Now;
        var observation = fleet.Workstations.FirstOrDefault(o => o.ComputerGuid == computer.ObjectGuid);
        var properties = new Dictionary<string, IReadOnlyList<object?>>(StringComparer.OrdinalIgnoreCase);
        void Put(string name, object? value)
        {
            if (value is not null)
            {
                properties[name] = [value];
            }
        }
        Put("name", computer.Name);
        Put("distinguishedName", computer.DistinguishedName);
        Put("objectGUID", computer.ObjectGuid);
        Put("sAMAccountName", computer.SamAccountName);
        Put("dNSHostName", computer.DnsHostName);
        Put("operatingSystem", computer.OperatingSystem);
        Put("operatingSystemVersion", computer.OperatingSystemVersion);
        Put("location", computer.Location);
        Put("managedBy", computer.ManagedByDn);
        Put("userAccountControl", computer.UserAccountControl);
        Put("pwdLastSet", computer.PasswordLastSet);
        Put("whenCreated", computer.WhenCreated);
        Put("whenChanged", computer.WhenChanged);
        Put("uSNChanged", computer.UsnChanged);
        properties["memberOf"] = [.. computer.MemberOf.Cast<object?>()];
        Put("primaryGroupID", computer.PrimaryGroupId);

        var (tone, label) = ComputerState(computer, observation);
        var presence = observation?.Presence;
        var inventory = observation?.Inventory;
        var free = inventory is null ? null : FreePercent(inventory);
        var lapsExpiry = AdValues.FromFileTime(computer.LapsExpiration);
        var presenceText = presence is { HasReading: true }
            ? (presence.Answered == true ? "En ligne · relevé le " : "Pas de réponse · relevé le ") + Date(presence.CheckedAt)
            : "Jamais relevée";
        var system = WindowsRelease.Describe(computer.OperatingSystem, computer.OperatingSystemVersion)?.Label ?? computer.OperatingSystem ?? "—";
        var lapsText = computer.Laps == LapsKind.None ? "Absent" : lapsExpiry is DateTimeOffset l ? (l <= now ? "Expiré le " : "Renouvelé avant le ") + Date(l) : "Date illisible";
        var facts = ImmutableArray.Create(
            new SubjectFact("Présence", presenceText, presence is { HasReading: true } ? (presence.Answered == true ? Tone.Ok : Tone.Warn) : Tone.Off),
            new SubjectFact("Système", system, Tone.Off),
            new SubjectFact("Modèle", inventory?.Model ?? "—", Tone.Off),
            new SubjectFact("Disque C:", free is double f ? FrenchText.Percent(f) + " libre" : "—", free switch { < 10 => Tone.Alert, < 20 => Tone.Warn, null => Tone.Off, _ => Tone.Ok }),
            new SubjectFact("LAPS", lapsText, computer.Laps == LapsKind.None ? Tone.Warn : lapsExpiry is DateTimeOffset e && e <= now ? Tone.Alert : Tone.Ok),
            new SubjectFact("Dernier démarrage", inventory?.LastBootAt is DateTimeOffset boot ? Date(boot) : "—", inventory?.LastBootAt is DateTimeOffset b && (now - b).TotalDays > 30 ? Tone.Warn : Tone.Off));
        var pills = new List<SubjectPill> { new(tone, label) };
        pills.Add(new SubjectPill(Tone.Info, computer.Name.StartsWith("PT-", StringComparison.Ordinal) ? "Portable" : "Poste fixe"));
        if (free is < 10)
        {
            pills.Add(new SubjectPill(Tone.Alert, "Disque presque plein"));
        }
        var related = ImmutableArray<SubjectHit>.Empty;
        if (computer.ManagedByDn is { } owner && directory.Users.FirstOrDefault(u => SameDn(u.DistinguishedName, owner)) is { } user)
        {
            related = [UserHit(user, directory, now)];
        }
        var signals = new MachineSignals(computer.Laps, lapsExpiry, presence is { HasReading: true } ? presence.Answered : null, presence?.CheckedAt,
            free, inventory?.LastBootAt, AdValues.FromFileTime(computer.LastLogonTimestamp));
        return new SubjectRecord(computer.DistinguishedName, computer.ObjectGuid, AssistanceSubject.Computer, computer.Name, computer.SamAccountName,
            ContainerPath(computer.DistinguishedName), properties, true, signals, facts, [.. pills], related, now);
    }
}
