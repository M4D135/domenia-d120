using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Simulation.Poste;

namespace Domenia.Simulation;

/// <summary>
/// The workstation console in simulation (docs/ops/poste.md): every value is derived from the generated world and the
/// sub-stream « screen/poste » (one fork per computer GUID), in memory only — no network, no WMI, no disk. Network reads keep
/// the rules of the real ones: a workstation that does not answer the ping is not read by WMI, a refused source concludes
/// nothing, each read waits a realistic, cancellable delay (« latency/screen/poste/… »), none with SimulationLatency.None.
/// </summary>
public sealed partial class SimulatedPosteReader : IPosteReader
{
    private readonly SimulatedDirectorySource source;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedPosteReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    private PosteSimulation Sim => PosteSimulation.For(source);

    public PosteOptions Options { get; } = new(
        true,
        true,
        "Simulation : réveil activé pour essayer le circuit (réglage réel par défaut : désactivé, Features.WakeOnLan).",
        ["10.0.0.0/8"],
        300,
        PosteRemote.RestartMinutes,
        SimulationProfile.NetbiosName + "\\adm-" + SimulationProfile.SessionLogin,
        [
            new SuiteTool("pesto", "Pesto", false, "Chemin de Pesto non configuré (Suite.Pesto) : rien n’est lancé en simulation.", PosteRemote.SuiteFields),
            new SuiteTool("filpro", "FILPRO", false, "Chemin de FILPRO non configuré (Suite.FilPro) : rien n’est lancé en simulation.", PosteRemote.SuiteFields),
        ],
        "Simulation : postes fictifs dérivés de l’annuaire example.local ; aucune requête ne part.");

    private Task Wait(string kind, int min, int max, CancellationToken cancellationToken) =>
        source.SimulateScreenLatencyAsync("poste/" + kind, min, max, cancellationToken);

    private async Task<(DirectoryComputer Computer, PosteMachine Machine, WorkstationObservation? Observation)> ResolveAsync(string dn, CancellationToken cancellationToken)
    {
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var computer = Sim.Find(dn);
        var observation = state.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == computer.ObjectGuid);
        return (computer, Sim.Machine(computer), observation);
    }

    private Dictionary<string, string> UserNames() =>
        source.CurrentDirectory.Users.GroupBy(u => u.DistinguishedName, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First().DisplayName ?? g.First().Cn, StringComparer.OrdinalIgnoreCase);

    private InventorySnapshot? StoredInventory(PosteMachine machine, WorkstationObservation? observation)
    {
        var session = Sim.SessionInventory(machine.Computer.ObjectGuid);
        if (session is not null)
        {
            return session;
        }
        if (observation?.Inventory is not { HasReading: true } inv)
        {
            return null;
        }
        var stable = new SeededRandom(machine.Seed).Fork("stored");
        return machine.Snapshot(inv.CheckedAt!.Value, false, stable, Sim.ServiceStates(machine.Computer.ObjectGuid), Sim.Boot(machine.Computer.ObjectGuid), Sim.Answers(machine.Computer.ObjectGuid, observation) == true);
    }

    private InventorySnapshot LiveSnapshot(PosteMachine machine, bool deep, WorkstationObservation? observation, DateTimeOffset now)
    {
        _ = Sim.ScheduledRestart(machine.Computer.ObjectGuid, now);
        return machine.Snapshot(now, deep, Sim.Live(machine), Sim.ServiceStates(machine.Computer.ObjectGuid), Sim.Boot(machine.Computer.ObjectGuid), Sim.Answers(machine.Computer.ObjectGuid, observation) == true);
    }

    // ------------------------------------------------------------------ master list (local)

    public async Task<PosteList> ListAsync(ScopeSelection? scope, string? text, int limit, PosteHealthPolicy policy, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(policy);
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        await Wait("list", 40, 120, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var now = Sim.Now;
        var observations = state.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var inScope = directory.Computers.Where(c => scope is null || ScopeRules.Contains(scope, c.DistinguishedName))
            .Where(c => (c.UserAccountControl & AdValues.ServerTrustAccount) == 0).ToList();
        var needle = FrenchText.Fold((text ?? "").Trim());
        var rows = new List<PosteRow>(inScope.Count);
        foreach (var c in inScope)
        {
            var machine = Sim.Machine(c);
            observations.TryGetValue(c.ObjectGuid, out var observation);
            var row = Row(c, machine, observation, policy, now);
            if (needle.Length > 0)
            {
                var hay = FrenchText.Fold(string.Join(" ", c.Name, row.User?.Name, row.User?.Login, row.Os, row.Release, row.Site, row.Ou, c.Description));
                if (!needle.Split(' ', StringSplitOptions.RemoveEmptyEntries).All(w => hay.Contains(w, StringComparison.Ordinal)))
                {
                    continue;
                }
            }
            rows.Add(row);
        }
        var sorted = rows.OrderBy(r => r.Name, PosteText.French).ToList();
        var bounded = Math.Clamp(limit, 1, 1000);
        var shown = sorted.Take(bounded).ToImmutableArray();
        var online = rows.Count(r => r.Presence == PresenceState.Online);
        var watch = rows.Count(r => r.Health.Level is Tone.Warn or Tone.Alert);
        var summary = FrenchText.Count(rows.Count, "poste", "postes") + (needle.Length > 0 ? (rows.Count >= 2 ? " trouvés" : " trouvé") : "") + (scope is null ? "" : " · OU de travail " + scope.Label)
            + " · " + FrenchText.Count(online, "répond", "répondent") + " au dernier relevé · " + FrenchText.Integer(watch) + " à surveiller ; liste locale, aucune requête au poste.";
        return new PosteList(scope, rows.Count, shown.Length, sorted.Count > bounded, text, summary, shown);
    }

    private PosteRow Row(DirectoryComputer c, PosteMachine machine, WorkstationObservation? observation, PosteHealthPolicy policy, DateTimeOffset now)
    {
        var answers = Sim.Answers(c.ObjectGuid, observation);
        var ping = Sim.LastPing(c.ObjectGuid);
        var presenceAt = ping?.CheckedAt ?? observation?.Presence.CheckedAt;
        // Same reading as the Accueil (WorkstationsOnline): a reading older than 30 days is remembered, never « online ».
        var read = ping is not null || observation?.Presence.HasReading == true;
        var stale = ping is null && observation?.Presence.CheckedAt is DateTimeOffset seen && now - seen >= TimeSpan.FromDays(30);
        var presence = Sim.ErrorProbe(c.ObjectGuid) ? PresenceState.Error
            : !read ? PresenceState.Unknown
            : stale ? PresenceState.Remembered
            : answers == true ? PresenceState.Online
            : PresenceState.Offline;
        var label = presence switch
        {
            PresenceState.Online => "Répond au ping",
            PresenceState.Remembered => "Relevé de plus de 30 jours",
            PresenceState.Offline => Sim.PingFiltered(c.ObjectGuid) ? "Ping filtré (répond à WMI)" : "Ne répond pas",
            PresenceState.Error => "Sonde en erreur",
            _ => "Non vérifié",
        };
        var points = 0;
        var level = Tone.Ok;
        void Point(Tone tone)
        {
            points++;
            if (tone == Tone.Alert || level != Tone.Alert)
            {
                level = tone == Tone.Alert ? Tone.Alert : Tone.Warn;
            }
        }
        if (AdValues.IsDisabled(c.UserAccountControl))
        {
            Point(Tone.Alert);
        }
        if (AdValues.FromFileTime(c.LastLogonTimestamp) is DateTimeOffset logon && (now - logon).TotalDays >= policy.StaleDays || c.LastLogonTimestamp is null)
        {
            Point(Tone.Warn);
        }
        if (AdValues.FromFileTime(c.PasswordLastSet) is DateTimeOffset pwd && (now - pwd).TotalDays > policy.PasswordDays)
        {
            Point(Tone.Warn);
        }
        if (AdValues.FromFileTime(c.LapsExpiration) is DateTimeOffset laps && laps < now)
        {
            Point(Tone.Warn);
        }
        var inventory = Sim.SessionInventory(c.ObjectGuid);
        DateTimeOffset? inventoryAt = inventory?.CollectedAt ?? (observation?.Inventory.HasReading == true ? observation.Inventory.CheckedAt : null);
        if (observation?.Inventory is { HasReading: true, SystemDiskSizeBytes: > 0 } inv && inv.SystemDiskFreeBytes is long free)
        {
            var state = policy.DiskState(100d * free / inv.SystemDiskSizeBytes!.Value);
            if (state != Tone.Ok)
            {
                Point(state);
            }
            if (inv.LastBootAt is DateTimeOffset boot && (now - boot).TotalDays >= policy.UptimeDays)
            {
                Point(Tone.Warn);
            }
        }
        var health = new PosteRowHealth(points == 0 ? (inventoryAt is null ? Tone.Off : Tone.Ok) : level, points,
            points == 0 ? (inventoryAt is null ? "Aucun point (sans inventaire)" : "Rien à signaler") : FrenchText.Count(points, "point à vérifier", "points à vérifier"));
        var kind = PosteHeaderRules.Kind(c.Name, c.OperatingSystem);
        var ou = DistinguishedName.Parse(DistinguishedName.Parent(c.DistinguishedName) ?? c.DistinguishedName)[0].Value;
        return new PosteRow(c.DistinguishedName, c.ObjectGuid, c.Name, c.DnsHostName, !AdValues.IsDisabled(c.UserAccountControl), c.OperatingSystem,
            WindowsRelease.Describe(c.OperatingSystem, c.OperatingSystemVersion)?.Label, kind, machine.Site, ou, User(machine), presence, label, presenceAt, inventoryAt, health);
    }

    private UserRef? User(PosteMachine machine) => Sim.Detected(machine.Computer.ObjectGuid)?.User ?? machine.User;

    // ------------------------------------------------------------------ console (local)

    public async Task<PosteConsole> OpenAsync(string dn, PosteHealthPolicy policy, ConsentState consent, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(consent);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        await Wait("open", 50, 140, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        var zone = Sim.Zone;
        var directory = source.CurrentDirectory;
        var computer = PosteHeaderRules.Computer(c, directory, UserNames());
        var inventory = StoredInventory(machine, observation);
        var session = Sim.SessionInventory(c.ObjectGuid) is not null;
        InventorySummary? summary = inventory is null ? null : new InventorySummary(inventory.CollectedAt, inventory.Deep, inventory.Deep ? "Inventaire complet" : "Inventaire rapide",
            PosteText.Age(inventory.CollectedAt, now), session ? "Lu dans cette session" : "Base locale (dernier inventaire validé)",
            inventory.Access.Count(a => a.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial), inventory.Access.Count(a => a.Status == SourceStatus.Refused), inventory.DurationMs, PosteLabels.TransportLabel(inventory.Transport));
        var board = PosteBoardBuilder.Build(computer, inventory, policy, now, zone);
        var association = Association(machine, observation, zone);
        var presence = PosteHeaderRules.Badge(PresenceOf(c.ObjectGuid, observation), zone, now);
        if (Sim.ErrorProbe(c.ObjectGuid))
        {
            presence = new PresenceBadge(PresenceState.Error, Tone.Alert, "Test impossible", "La sonde de présence de ce poste est en erreur : le ping n’a pas pu être envoyé. Le détail est dans le journal de session.", null, false, null);
        }
        var header = PosteHeaderRules.Header(computer, presence, association, summary, directory.ReadAt);
        var secrets = Secrets(machine, computer, now, zone);
        var notes = ImmutableArray.CreateBuilder<PosteFact>();
        if (Sim.PingFiltered(c.ObjectGuid))
        {
            notes.Add(PosteText.Fact("Présence", "Ping filtré : ce poste répond à WMI sans jamais répondre au ping", FactState.Observed, "Relevés de la base locale", "Une absence de réponse ICMP ne prouve pas que le poste est éteint.", at: now, tone: Tone.Info));
        }
        if (Sim.ScheduledRestart(c.ObjectGuid, now) is { } restart)
        {
            notes.Add(PosteText.Fact("Redémarrage programmé", "Prévu à " + PosteText.LocalTime(restart.At, zone) + FrenchText.Colon + FrenchQuote(restart.Message), FactState.Observed, "Reçu d’écriture de la session", "Annulable avant l’échéance depuis la vue Intervenir.", at: now, tone: Tone.Warn));
        }
        return new PosteConsole(computer, header, association, Sim.LastLive(c.ObjectGuid), summary, board,
            inventory is null ? "Aucun inventaire de ce poste dans la base locale ni dans cette session : lancez un inventaire rapide (lecture seule, environ 1 min)." : null,
            secrets, consent, Options, false, true, notes.ToImmutable());
    }

    private static string FrenchQuote(string text) => FrenchText.Quote(PosteText.Flat(text, 80) + (text.Length > 80 ? "…" : ""));

    private PresenceReading? PresenceOf(Guid id, WorkstationObservation? observation)
    {
        var ping = Sim.LastPing(id);
        if (ping is not null)
        {
            return ping;
        }
        if (observation?.Presence is { HasReading: true } p)
        {
            return new PresenceReading(p.Answered, null, null, p.CheckedAt, p.LastOnlineAt, false, "Relevé de présence (base locale)");
        }
        return null;
    }

    private PosteAssociation Association(PosteMachine machine, WorkstationObservation? observation, TimeZoneInfo zone)
    {
        var detected = Sim.Detected(machine.Computer.ObjectGuid);
        var at = observation?.Presence.LastOnlineAt ?? observation?.Inventory.CheckedAt ?? machine.Computer.WhenChanged;
        var history = ImmutableArray.CreateBuilder<AssociationEvent>();
        if (machine.User is { } user)
        {
            history.Add(new AssociationEvent(machine.Computer.WhenCreated.AddDays(2), user.Name, machine.Badge == AssociationBadge.Declared ? "managedBy (annuaire)" : "Relevé console", "Première association connue"));
            if (machine.Badge is AssociationBadge.Observed or AssociationBadge.Contradictory)
            {
                history.Add(new AssociationEvent(at, user.Name, "Relevé console", "Utilisateur vu à la console"));
            }
        }
        if (detected is { } d)
        {
            history.Add(new AssociationEvent(d.At, d.User.Name, d.Method, "Détection de la session"));
            var keep = machine.Badge == AssociationBadge.Declared && machine.User is not null && machine.User.Login != d.User.Login;
            return PosteHeaderRules.Association(keep ? machine.User : d.User, keep ? AssociationBadge.Contradictory : AssociationBadge.Observed,
                keep ? "managedBy conservé · " + d.User.Name + " détecté (" + d.Method + ")" : "Détection (" + d.Method + ")", d.At,
                keep ? "Une association déclarée n’est jamais écrasée par une détection" : "Candidat vérifié par identité AD exacte", true, [.. history.OrderByDescending(h => h.At)], zone);
        }
        var (source, rule) = machine.Badge switch
        {
            AssociationBadge.Declared => ("managedBy (annuaire)", "Attribut managedBy du compte ordinateur"),
            AssociationBadge.Contradictory => ("managedBy et relevé console", "Le relevé console montre un autre compte que managedBy"),
            AssociationBadge.History => ("Ancien relevé console", "Dernier utilisateur vu il y a plus de 30 jours"),
            _ => ("Relevé console", "Utilisateur à la console au dernier relevé"),
        };
        return PosteHeaderRules.Association(machine.User, machine.Badge, source, machine.User is null ? null : at, rule, machine.Badge != AssociationBadge.History, [.. history.OrderByDescending(h => h.At)], zone);
    }

    private SecretsSummary Secrets(PosteMachine machine, PosteComputer computer, DateTimeOffset now, TimeZoneInfo zone)
    {
        var id = machine.Computer.ObjectGuid;
        var session = Sim.BitLockerIndex(id);
        var lapsRead = Sim.LapsIndex(id);
        var bitLockerDenied = PosteSimulation.BitLockerDenied(machine) && Sim.OtherAccount(id, "bitlocker") is null;
        var lapsDenied = PosteSimulation.LapsDenied(machine) && Sim.OtherAccount(id, "laps") is null;
        var (identity, reason) = PosteSecrets.Identity(Sim.Reader, bitLockerDenied || lapsDenied);
        var parts = new List<string>();
        (int Keys, DateTimeOffset At)? index = session;
        string? discarded = null;
        if (index is null && Sim.StoredBitLockerIndex(machine) is { } stored)
        {
            // The index of the local base is checked by GUID and creation date: an older holder of the name is left out (PST-065).
            if (PosteSecrets.IndexApplies(stored.Holder, stored.At, id, machine.Computer.WhenCreated))
            {
                index = (Keys(machine.Computer, machine).Length, stored.At);
            }
            else
            {
                discarded = "métadonnées BitLocker du " + PosteText.LocalDate(stored.At, zone) + " écartées : elles concernent un ancien détenteur du nom (poste actuel créé le " + PosteText.LocalDate(machine.Computer.WhenCreated, zone) + ")";
            }
        }
        parts.Add(index is { } b ? FrenchText.Count(b.Keys, "clé BitLocker", "clés BitLocker") + " (" + (session is null ? "base locale, " : "") + "lu le " + PosteText.LocalDateTime(b.At, zone) + ")" : "Clés BitLocker non lues");
        parts.Add(computer.LapsExpiration is DateTimeOffset exp ? computer.LapsKind + ", expiration le " + PosteText.LocalDateTime(exp, zone) + (exp < now ? " (échue)" : "") : "Aucune expiration LAPS visible");
        if (lapsRead is DateTimeOffset at)
        {
            parts.Add("métadonnées LAPS lues le " + PosteText.LocalDateTime(at, zone));
        }
        if (discarded is not null)
        {
            parts.Add(discarded);
        }
        return new SecretsSummary(string.Join(" · ", parts) + ". Jamais une clé ni un mot de passe.", index?.Keys, index?.At, computer.LapsKind, computer.LapsExpiration,
            computer.LapsExpiration is DateTimeOffset e && e < now, identity, reason, bitLockerDenied, lapsDenied);
    }

    // ------------------------------------------------------------------ presence and live state

    public async Task<PresenceReading> PingAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        await Wait("ping", 120, 380, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        if (Sim.ErrorProbe(c.ObjectGuid))
        {
            throw new DomeniaOperationException(PosteErrors.Unreachable, "Erreur de ping : la sonde de ce poste est en erreur, le ping n’a pas pu être envoyé. Aucune conclusion sur sa présence.");
        }
        var answers = Sim.PingFiltered(c.ObjectGuid) ? false : Sim.Answers(c.ObjectGuid, observation) ?? false;
        var live = Sim.Live(machine);
        var previous = Sim.LastPing(c.ObjectGuid);
        var reading = new PresenceReading(answers, answers ? live.Next(1, 14) : null, machine.Ip, now,
            answers ? now : previous?.LastOnlineAt ?? observation?.Presence.LastOnlineAt, false, "Ping (un seul écho ICMP)");
        Sim.RecordPing(c.ObjectGuid, reading);
        return reading;
    }

    public async Task<PosteLive> LiveAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var reading = await PingAsync(dn, cancellationToken).ConfigureAwait(false);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        await Wait("live", 300, 700, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        var zone = Sim.Zone;
        var facts = ImmutableArray.CreateBuilder<PosteFact>();
        facts.Add(PosteText.Fact("Présence", reading.Answered == true ? "Répond au ping en " + FrenchText.Integer(reading.RoundTripMs ?? 0) + " ms (" + reading.Address + ")" : "Ne répond pas au ping", FactState.Observed, "Ping (un seul écho ICMP)",
            reading.Answered == true ? null : "Une absence de réponse ICMP ne prouve pas que le poste est éteint.", at: now, tone: reading.Answered == true ? Tone.Ok : Tone.Warn));
        if (!Sim.Reachable(c.ObjectGuid, observation))
        {
            facts.Add(PosteText.Fact("Durée de fonctionnement", "Non lue", FactState.Unknown, "CIM Win32_OperatingSystem", "Poste muet au ping : WMI non lancé.", at: now));
            facts.Add(PosteText.Fact("Utilisateur connecté", "Non lu", FactState.Unknown, "CIM Win32_ComputerSystem", "Poste muet au ping : WMI non lancé.", at: now));
            var down = new PosteLive(reading, null, null, null, "Non lu", null, "Non lues", now, facts.ToImmutable());
            Sim.RecordLive(c.ObjectGuid, down);
            return down;
        }
        _ = Sim.ScheduledRestart(c.ObjectGuid, now);
        var boot = Sim.Boot(c.ObjectGuid) ?? machine.LastBoot;
        var user = User(machine);
        var sessions = user is null ? 0 : 1;
        facts.Add(PosteText.Fact("Durée de fonctionnement", "En service depuis " + PosteText.Duration(now - boot) + " (démarré le " + PosteText.LocalDateTime(boot, zone) + ")", FactState.Observed, "CIM Win32_OperatingSystem (LastBootUpTime)",
            "Heure déclarée par le poste.", (now - boot).TotalDays >= 30 ? "Pas de redémarrage depuis longtemps : proposez un redémarrage différé." : null, now, (now - boot).TotalDays >= 30 ? Tone.Warn : Tone.Ok));
        facts.Add(PosteText.Fact("Utilisateur connecté", user is null ? "Aucun à la console" : SimulationProfile.NetbiosName + "\\" + user.Login + " (" + user.Name + ")", FactState.Observed, "CIM Win32_ComputerSystem (UserName)",
            user is null ? "Console vide : cela ne signifie pas absence de session RDP." : null, at: now, tone: Tone.Info));
        var live = new PosteLive(reading, boot, PosteText.Duration(now - boot), user, user is null ? "Aucun utilisateur à la console" : user.Name, sessions,
            sessions == 0 ? "Aucune session utilisateur" : FrenchText.Count(sessions, "session ouverte", "sessions ouvertes"), now, facts.ToImmutable());
        Sim.RecordLive(c.ObjectGuid, live);
        return live;
    }

    // ------------------------------------------------------------------ inventory

    public async Task<InventoryResult> InventoryAsync(string dn, bool deep, PosteHealthPolicy policy, IProgress<PosteProgress>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(policy);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        Sim.Unreachable(c, observation);
        var categories = deep ? InventoryCategories.Quick.AddRange(InventoryCategories.DeepOnly) : InventoryCategories.Quick;
        var label = deep ? "inventaire complet" : "inventaire rapide";
        var computer = PosteHeaderRules.Computer(c, source.CurrentDirectory, UserNames());
        var transport = InventoryTransport.Dcom;
        if (Sim.CimBlocked(machine))
        {
            // CIM refused: never a silent switch to an intrusive transport; one fallback read only with its authorization.
            if (!PosteSession.For(source).ConsumeReadFallback(c.DistinguishedName, label, Sim.Now))
            {
                await Wait("inventory/refused", 300, 700, cancellationToken).ConfigureAwait(false);
                var refusedAt = Sim.Now;
                var refused = LiveSnapshot(machine, deep, observation, refusedAt).WithStatus(categories, SourceStatus.Refused, CimRefusedDetail);
                var refusedBoard = PosteBoardBuilder.Build(computer, refused, policy, refusedAt, Sim.Zone);
                return InventoryRows.Build(refused, refusedBoard, "Non lu : CIM refusé", refusedAt, Sim.Zone, FallbackNotice(c.Name), InventoryRows.FallbackAction);
            }
            transport = InventoryTransport.ScheduledTask;
        }
        var budgetSeconds = deep ? 150 : 55;
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        budget.CancelAfter(TimeSpan.FromSeconds(budgetSeconds));
        var read = 0;
        string? interrupted = null;
        try
        {
            for (var i = 0; i < categories.Length; i++)
            {
                progress?.Report(new PosteProgress(i, categories.Length, "Lecture : " + categories[i]));
                await Wait(deep ? "inventory/deep" : "inventory/quick", deep ? 40 : 25, deep ? 90 : 60, budget.Token).ConfigureAwait(false);
                read = i + 1;
            }
        }
        catch (OperationCanceledException) when (budget.IsCancellationRequested)
        {
            interrupted = cancellationToken.IsCancellationRequested ? "relevé arrêté à votre demande" : "budget de " + FrenchText.Integer(budgetSeconds) + " s atteint";
        }
        if (interrupted is not null && read == 0)
        {
            throw cancellationToken.IsCancellationRequested
                ? new DomeniaOperationException(PosteErrors.Cancelled, PosteErrors.CancelledMessage)
                : new DomeniaOperationException(PosteErrors.Unreachable, "Budget de " + FrenchText.Integer(budgetSeconds) + " s atteint avant toute lecture : rien n’a été lu ni enregistré.");
        }
        progress?.Report(new PosteProgress(categories.Length, categories.Length, interrupted is null ? "Mise en forme du tableau" : "Résultat partiel : mise en forme"));
        var now = Sim.Now;
        var snapshot = LiveSnapshot(machine, deep, observation, now);
        if (transport != InventoryTransport.Dcom)
        {
            snapshot = snapshot.By(transport);
        }
        if (interrupted is not null)
        {
            // Partial result rather than loss (PST-037): what was read is kept and recorded, the rest is « Interrompu ».
            snapshot = snapshot.WithStatus(categories.Skip(read), SourceStatus.Interrupted, interrupted);
        }
        Sim.RecordInventory(c.ObjectGuid, snapshot);
        var board = PosteBoardBuilder.Build(computer, snapshot, policy, now, Sim.Zone);
        var origin = transport == InventoryTransport.Dcom ? "Lu maintenant (session)" : "Lu maintenant par la lecture de repli (tâche planifiée, autorisation consommée)";
        return InventoryRows.Build(snapshot, board, origin, now, Sim.Zone,
            transport == InventoryTransport.Dcom ? null : "Lecture de repli utilisée : CIM refusé, une tâche planifiée unique a lu le poste puis a été supprimée. L’autorisation est consommée.", null);
    }

    private const string CimRefusedDetail = "CIM refusé (DCOM et WinRM) : non lu, aucun transport de repli sans autorisation";

    private static string FallbackNotice(string computer) =>
        "CIM refuse la lecture de " + computer + " (DCOM filtré, WinRM fermé) : rien n’a été lu. Une seule lecture de repli (tâche planifiée) est possible si vous l’autorisez ; elle laisse une trace sur le poste.";

    public async Task<InventoryResult?> CachedInventoryAsync(string dn, PosteHealthPolicy policy, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(policy);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        await Wait("inventory/cached", 40, 120, cancellationToken).ConfigureAwait(false);
        var inventory = StoredInventory(machine, observation);
        if (inventory is null)
        {
            return null;
        }
        var now = Sim.Now;
        var session = Sim.SessionInventory(c.ObjectGuid) is not null;
        var computer = PosteHeaderRules.Computer(c, source.CurrentDirectory, UserNames());
        var board = PosteBoardBuilder.Build(computer, inventory, policy, now, Sim.Zone);
        return InventoryRows.Build(inventory, board, session ? "Lu dans cette session" : "Base locale (dernier inventaire validé)", now, Sim.Zone);
    }

    /// <summary>A read that has no fallback (services, processes, events, sessions, WMI) on a workstation whose CIM refuses.</summary>
    private void RequireCim(DirectoryComputer c, PosteMachine machine)
    {
        if (Sim.CimBlocked(machine))
        {
            throw new DomeniaOperationException(PosteErrors.CimRefused, "CIM refuse la lecture de " + c.Name + " (DCOM filtré, WinRM fermé) : rien n’a été lu. Seuls l’inventaire, les logiciels et la détection de l’utilisateur peuvent passer par une lecture de repli autorisée (vue Intervenir).");
        }
    }

    // ------------------------------------------------------------------ software

    public async Task<SoftwareResult> SoftwareAsync(string dn, SoftwareRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(request);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        Sim.Unreachable(c, observation);
        var fallback = false;
        if (Sim.CimBlocked(machine))
        {
            if (!PosteSession.For(source).ConsumeReadFallback(c.DistinguishedName, "logiciels", Sim.Now))
            {
                throw new DomeniaOperationException(PosteErrors.CimRefused, FallbackNotice(c.Name));
            }
            fallback = true;
        }
        await Wait("software", 600, 1200, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        var winRm = Sim.ServiceStates(c.ObjectGuid).TryGetValue("WinRM", out var winrm) ? winrm == "Running" : machine.Services.Any(s => s.Name == "WinRM" && s.State == "Running");
        var entries = machine.Software.Where(s => s.Scope == "Machine" || (s.Scope == "Utilisateur" && request.PerUser) || (s.Scope == "Store" && request.Store && winRm)).ToList();
        if (request.Updates)
        {
            entries.AddRange(machine.Hotfixes.Select(h => new SoftwareEntry("Mise à jour " + h.Id, null, "Microsoft Corporation", h.InstalledOn is DateTimeOffset at ? DateOnly.FromDateTime(at.UtcDateTime) : null, null, "64 bits", "Machine", null, null, null, "Uninstall64")));
        }
        var rows = PosteSoftware.Rows(entries);
        var access = ImmutableArray.CreateBuilder<SoftwareScopeAccess>();
        access.Add(new SoftwareScopeAccess("Machine", SourceStatus.Ok, "Lu", rows.Count(r => r.Scope == "Machine"), "Registre Uninstall 64 et 32 bits (StdRegProv), inventaire SCCM ; jamais Win32_Product"));
        access.Add(request.PerUser
            ? new SoftwareScopeAccess("Utilisateur", rows.Any(r => r.Scope == "Utilisateur") ? SourceStatus.Ok : SourceStatus.Empty, rows.Any(r => r.Scope == "Utilisateur") ? "Lu" : "Lu, rien trouvé", rows.Count(r => r.Scope == "Utilisateur"), "Ruches HKU chargées (profils ouverts seulement)")
            : new SoftwareScopeAccess("Utilisateur", SourceStatus.Skipped, "Non demandé", 0, "Cochez « Profils » pour lire les ruches chargées"));
        access.Add(!request.Store
            ? new SoftwareScopeAccess("Store", SourceStatus.Skipped, "Non demandé", 0, "Cochez « Store » pour lire les applications Appx (WinRM)")
            : winRm
                ? new SoftwareScopeAccess("Store", SourceStatus.Ok, "Lu", rows.Count(r => r.Scope == "Store"), "Appx par WinRM")
                : new SoftwareScopeAccess("Store", SourceStatus.Unavailable, "Indisponible", 0, "WinRM arrêté sur le poste : les applications du Store ne sont pas lues (aucun repli)"));
        var built = access.ToImmutable();
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now, Sim.Zone).DateTime);
        var facts = ImmutableArray.Create(PosteText.Fact("Logiciels", FrenchText.Count(rows.Length, "entrée lue", "entrées lues"), FactState.Observed, "Registre et SCCM", "Une ligne par entrée ; rien n’est fusionné.", at: now, tone: Tone.Info));
        return new SoftwareResult(c.Name, now, fallback ? "Lu maintenant par la lecture de repli (tâche planifiée)" : "Lu maintenant (session)", "Liste lue sur le poste le " + PosteText.LocalDateTime(now, Sim.Zone) + " (portée machine" + (request.PerUser ? ", profils" : "") + (request.Store ? ", Store" : "") + ").",
            true, rows.Length, rows, built, PosteSoftware.AccessSummary(built), PosteSoftware.NotCovered(built, request), PosteSoftware.Columns(rows), PosteSoftware.Board(rows, today), facts);
    }

    public async Task<SoftwareResult> CachedSoftwareAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        var inventory = StoredInventory(machine, observation);
        var now = Sim.Now;
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now, Sim.Zone).DateTime);
        var request = new SoftwareRequest(false, false, false);
        if (inventory is null)
        {
            var empty = ImmutableArray<SoftwareRow>.Empty;
            return new SoftwareResult(c.Name, null, "Aucun inventaire", "Aucun inventaire de ce poste : « Charger les logiciels » lit le poste (geste explicite).", false, 0, empty, [], "Aucune portée lue.", null,
                PosteSoftware.Columns(empty), PosteSoftware.Board(empty, today), []);
        }
        var rows = PosteSoftware.Rows(inventory.Software);
        ImmutableArray<SoftwareScopeAccess> access = [new SoftwareScopeAccess("Machine", SourceStatus.Ok, "Lu", rows.Length, "Inventaire rapide (noms et versions)")];
        return new SoftwareResult(c.Name, inventory.CollectedAt, "Inventaire du " + PosteText.LocalDateTime(inventory.CollectedAt, Sim.Zone),
            "Liste tirée de l’inventaire " + (inventory.Deep ? "complet" : "rapide") + " du " + PosteText.LocalDateTime(inventory.CollectedAt, Sim.Zone) + " : noms et versions seulement ; éditeur, date, taille et désinstallation non lus. « Charger les logiciels » relit le poste en complet.",
            false, rows.Length, rows, access, PosteSoftware.AccessSummary(access), PosteSoftware.NotCovered(access, request), PosteSoftware.Columns(rows), PosteSoftware.Board(rows, today),
            [PosteText.Fact("Synthèse", "Déclarée non calculée sur les éditeurs, dates et tailles (non lus par l’inventaire rapide)", FactState.Estimated, "Inventaire rapide", null, at: now, tone: Tone.Info)]);
    }

    // ------------------------------------------------------------------ services and processes

    public async Task<ServicesResult> ServicesAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        Sim.Unreachable(c, observation);
        RequireCim(c, machine);
        await Wait("services", 300, 700, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        var states = Sim.ServiceStates(c.ObjectGuid);
        var services = machine.Services.Select(s => states.TryGetValue(s.Name, out var st) ? s with { State = st, ExitCode = st == "Running" ? null : s.ExitCode } : s).ToList();
        var rows = PosteServices.Rows(services);
        var auto = rows.Count(r => r.AutoStopped);
        var expected = rows.Count(r => r.StopExpected);
        return new ServicesResult(c.Name, now, rows.Length, auto, expected, false, 0, PosteServices.Summary(rows.Length, auto, expected, c.Name, now, Sim.Zone, false), rows, PosteServices.CompareProfile(rows),
            [PosteText.Fact("Lecture", "Win32_Service lu une fois, " + FrenchText.Integer(rows.Length) + " instances", FactState.Observed, "CIM (DCOM)", "Plafond de 500 instances ; aucune commande ni mot de passe lus.", at: now, tone: Tone.Info)]);
    }

    public async Task<ProcessesResult> ProcessesAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        Sim.Unreachable(c, observation);
        RequireCim(c, machine);
        await Wait("processes", 700, 1200, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        var (first, second) = TwoReads(machine, observation);
        return PosteProcesses.Measure(c.Name, first, second, 1500, machine.Model.Threads, now, Sim.Zone);
    }

    /// <summary>Two reads of the processes 1.5 s apart: the second adds the processor time each process used meanwhile.</summary>
    private (ImmutableArray<ProcessEntry> First, ImmutableArray<ProcessEntry> Second) TwoReads(PosteMachine machine, WorkstationObservation? observation)
    {
        var live = Sim.Live(machine);
        var open = Sim.Answers(machine.Computer.ObjectGuid, observation) == true;
        var first = machine.Processes(live, open);
        var logical = machine.Model.Threads;
        var budget = machine.Slow == SlowCause.Cpu ? live.Next(86, 98) : live.Next(4, 32);
        var weights = first.Select(p =>
        {
            var spec = PosteCatalogs.Processes.FirstOrDefault(s => s.Name == p.Name);
            var w = (spec?.CpuWeight ?? 1) * (live.Next(1, 10));
            if (machine.Slow == SlowCause.Cpu && p.Name is "MsMpEng.exe" or "TiWorker.exe")
            {
                w *= 30;
            }
            if (machine.Slow == SlowCause.Memory && p.Name is "ms-teams.exe" or "chrome.exe")
            {
                w *= 4;
            }
            return (double)w;
        }).ToList();
        var total = Math.Max(1, weights.Sum());
        var second = first.Select((p, i) => p with { CpuSeconds = (p.CpuSeconds ?? 0) + budget / 100d * 1.5 * logical * weights[i] / total, WorkingSetBytes = p.WorkingSetBytes + live.Next(-2, 3) * 1048576L }).ToImmutableArray();
        return (first, second);
    }

    // ------------------------------------------------------------------ events and sessions

    public async Task<EventsResult> EventsAsync(string dn, string preset, int hours, int maxEvents, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var definition = PosteEvents.Preset(preset) ?? throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Arguments invalides : préréglage d’événements inconnu.");
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        Sim.Unreachable(c, observation);
        RequireCim(c, machine);
        await Wait("events", 300, 800, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        var query = PosteEvents.Query(definition, hours, maxEvents, now);
        var events = machine.Events.Where(e => e.At >= query.Start && e.At <= query.End && definition.EventIds.Contains(e.Id)
            && definition.Logs.Contains(e.Log, StringComparer.OrdinalIgnoreCase)).ToList();
        return PosteEvents.Interpret(c.Name, query, events.Count == 0 ? SourceStatus.Empty : SourceStatus.Ok, events, false, Sim.Reader, Sim.Zone);
    }

    public async Task<SessionsResult> SessionsAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        Sim.Unreachable(c, observation);
        RequireCim(c, machine);
        await Wait("sessions", 200, 500, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        var user = User(machine);
        var boot = Sim.Boot(c.ObjectGuid) ?? machine.LastBoot;
        var r = new SeededRandom(machine.Seed).Fork("sessions");
        var sessions = new List<LocalSession>
        {
            new("0", "Services", null, null, "Déconnecté", "Console", null, null, null),
            new("65536", "RDP-Tcp", null, null, "Écoute", "RDP", null, null, null),
        };
        if (user is not null && Sim.Answers(c.ObjectGuid, observation) == true)
        {
            sessions.Add(new LocalSession("1", "Console", user.Login, SimulationProfile.NetbiosName, "Active", "Console", Max(boot, now.AddHours(-r.Next(1, 9))), TimeSpan.FromMinutes(r.Next(0, 18)), null));
        }
        if (r.Chance(10))
        {
            sessions.Add(new LocalSession("2", "RDP-Tcp#3", "adm-n.petit", SimulationProfile.NetbiosName, "Déconnecté", "RDP", now.AddDays(-r.Next(1, 4)), TimeSpan.FromHours(r.Next(20, 70)), "SUPPORT-02"));
        }
        return PosteSessions.View(c.Name, SourceStatus.Ok, sessions, now, Sim.Reader, Sim.Zone);
    }

    private static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;
}
