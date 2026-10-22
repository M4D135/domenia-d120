using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Poste;

/// <summary>
/// The workstation dashboard (Domenia 1 Get-DomeniaComputerBoardData, Add-DomeniaComputerBoardAdEntries,
/// Complete-DomeniaBoardData), built from the object card and, when there is one, the last inventory. Pure: the current
/// time and the zone are parameters; nothing is read from the workstation or the directory here. A value that was not read
/// stays « Non lu », a source that answered without item reads « 0 », a disabled rule never scores.
/// </summary>
public static class PosteBoardBuilder
{
    private static readonly PosteRoute Secrets = new("secrets", null, null, "Vue Secrets du poste");
    private static readonly PosteRoute Restart = new("intervenir", null, "redemarrer", "Redémarrer : vue Intervenir");
    private static readonly PosteRoute DiskTools = new("intervenir", null, "outils", "Ouvrir le disque C : vue Intervenir");
    private static readonly PosteRoute ServicesView = new("inventaire", "services", null, "Services : vue Inventaire");

    public const string QuickAction = "inventory.quick";
    public const string DeepAction = "inventory.deep";

    /// <summary>The six checks of the protection list (Domenia 1 computer.status), in their order.</summary>
    public static ImmutableArray<(string Key, string Label)> ProtectionChecks { get; } =
    [
        ("computer.bitlocker", "BitLocker"), ("computer.secureboot", "Démarrage sécurisé"), ("computer.firewall", "Pare-feu"),
        ("computer.antivirus", "Antivirus"), ("computer.reboot", "Redémarrage en attente"), ("computer.hotfix", "Dernier correctif"),
    ];

    public static PosteBoard Build(PosteComputer computer, InventorySnapshot? inventory, PosteHealthPolicy policy, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(computer);
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(zone);
        var points = new List<AttentionPoint>();
        var ad = AdSheet(computer, inventory, policy, now, zone, points);
        if (inventory is null)
        {
            var hints = ImmutableArray.Create(
                new BoardHint("identite", "Lancez un inventaire (rapide ou complet) pour remplir cette section.", "Inventaire rapide", QuickAction),
                new BoardHint("ressources", "Lancez un inventaire pour mesurer la mémoire, le processeur et les disques.", "Inventaire rapide", QuickAction),
                new BoardHint("activite", "L’inventaire complet ajoute les processus et les erreurs système.", "Inventaire complet", DeepAction),
                new BoardHint("securite", "Lancez un inventaire pour lire BitLocker, le pare-feu et l’antivirus.", "Inventaire rapide", QuickAction));
            // Without inventory the six checks are listed « Non lu »: nothing read is never told « Rien à signaler » (PST-100).
            var protectionEmpty = Checklist(ProtectionChecks, new Dictionary<string, SheetLine>(StringComparer.Ordinal));
            var healthAdOnly = Health(points, policy, "Aucun inventaire dans cette session ni dans la base locale : seuls les attributs de l’annuaire sont évalués", QuickAction);
            return new PosteBoard(healthAdOnly, null, ad, protectionEmpty, null, null, null, [], [], hints,
                "Aucun inventaire : le tableau ne montre que le compte du poste dans l’annuaire.", null, false);
        }

        var lines = new Dictionary<string, SheetLine>(StringComparer.Ordinal);
        var identity = IdentitySheet(computer, inventory, policy, now, zone, points, lines);
        var resources = Resources(inventory, policy, points);
        var disks = Disks(inventory, policy, points);
        var activity = Activity(inventory, policy, points, now);
        var counts = Counts(inventory, policy, points);
        var sections = Sections(inventory, policy, now, zone, points, lines);
        CustomPoints(inventory, resources, disks, policy, points, now);
        var protection = Checklist(ProtectionChecks, lines);
        var securityRead = inventory.Read(InventoryCategories.Antivirus) && inventory.Read(InventoryCategories.Firewall) && inventory.Read(InventoryCategories.BitLocker);
        var health = Health(points, policy, securityRead ? null : "Partiel : antivirus, pare-feu ou BitLocker non lu", securityRead ? null : DeepAction);
        var boardHints = ImmutableArray.CreateBuilder<BoardHint>();
        if (activity.Processes.IsEmpty && !inventory.Deep)
        {
            boardHints.Add(new BoardHint("activite", "Non lu pendant cet inventaire rapide : l’inventaire complet ajoute les processus, les erreurs système, les tâches et les certificats.", "Inventaire complet", DeepAction));
        }
        if (resources.Memory is null && resources.Cpu is null)
        {
            boardHints.Add(new BoardHint("ressources", "Aucune mesure relevée pendant cet inventaire.", "Inventaire rapide", QuickAction));
        }
        var summary = (inventory.Deep ? "Inventaire complet" : "Inventaire rapide") + " du " + PosteText.LocalDateTime(inventory.CollectedAt, zone)
            + " (" + PosteText.Age(inventory.CollectedAt, now) + ") ; " + FrenchText.Count(inventory.Access.Count(a => a.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial), "source lue", "sources lues")
            + " sur " + FrenchText.Integer(inventory.Access.Length) + ", aucune nouvelle requête pour ce tableau.";
        return new PosteBoard(health, identity, ad, protection, resources, disks, activity, counts, sections, boardHints.ToImmutable(), summary, inventory.CollectedAt, inventory.Deep);
    }

    // ------------------------------------------------------------------ computer account (PST-096, PST-012)

    /// <summary>Account sheet from the attributes read with the object card; the clock skew comes from the inventory.</summary>
    public static PosteSheet AdSheet(PosteComputer computer, InventorySnapshot? inventory, PosteHealthPolicy policy, DateTimeOffset now, TimeZoneInfo zone, List<AttentionPoint> points)
    {
        ArgumentNullException.ThrowIfNull(computer);
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(points);
        ArgumentNullException.ThrowIfNull(zone);
        var lines = ImmutableArray.CreateBuilder<SheetLine>();
        var created = PosteText.LocalDate(computer.WhenCreated, zone);
        if (computer.Enabled is not bool enabled)
        {
            lines.Add(new SheetLine("computer.ad.account", "Compte ordinateur", "État inconnu", "userAccountControl illisible : relisez la fiche avant toute action. Créé le " + created, Tone.Off, false));
        }
        else
        {
            if (!enabled)
            {
                Note(points, policy, AttentionLevel.Alert, "Compte ordinateur désactivé dans l’annuaire : le poste ne peut plus s’authentifier.", "ad.disabled", new PosteRoute("intervenir", null, "compte", "Compte AD : vue Intervenir"));
            }
            lines.Add(new SheetLine("computer.ad.account", "Compte ordinateur", enabled ? "Activé" : "Désactivé", "Compte AD ; créé le " + created, enabled ? Tone.Ok : Tone.Alert, false));
        }
        lines.Add(new SheetLine("computer.ad.ou", "Unité d’organisation", computer.Ou.Name, computer.Ou.Path, null, false));
        lines.Add(new SheetLine("computer.ad.dns", "Nom DNS", computer.DnsName ?? "Non renseigné", computer.DnsName is null ? "dNSHostName absent : le poste n’a peut-être jamais démarré dans le domaine" : "dNSHostName", computer.DnsName is null ? Tone.Off : null, computer.DnsName is not null));
        lines.Add(new SheetLine("computer.ad.sid", "SID", computer.Sid, "objectSid du compte ordinateur", null, true));
        lines.Add(new SheetLine("computer.ad.uac", "userAccountControl", computer.UserAccountControl is int uac ? PosteLabels.UacText(uac) : "Illisible", "Indicateurs du compte (valeur brute puis lecture)", computer.UserAccountControl is null ? Tone.Off : null, computer.UserAccountControl is not null));
        lines.Add(new SheetLine("computer.ad.description", "Description", string.IsNullOrWhiteSpace(computer.Description) ? "Non renseignée" : computer.Description!, "Attribut description", string.IsNullOrWhiteSpace(computer.Description) ? Tone.Off : null, false));
        lines.Add(new SheetLine("computer.ad.location", "Emplacement", string.IsNullOrWhiteSpace(computer.Location) ? "Non renseigné" : computer.Location!, "Attribut location", string.IsNullOrWhiteSpace(computer.Location) ? Tone.Off : null, false));
        if (computer.PasswordLastSet is DateTimeOffset pwd)
        {
            var days = (int)(now - pwd).TotalDays;
            var late = days > policy.PasswordDays;
            if (late)
            {
                Note(points, policy, AttentionLevel.Warn, "Mot de passe machine ancien (" + FrenchText.Count(days, "jour", "jours") + ") : prévenir l’administrateur.", "pwdold", null);
            }
            lines.Add(new SheetLine("computer.ad.password", "Mot de passe machine", "il y a " + FrenchText.Integer(days) + " j",
                late ? "Mot de passe machine ancien : relation d’approbation à vérifier par l’administrateur" : "Renouvelé le " + PosteText.LocalDate(pwd, zone), late ? Tone.Warn : Tone.Ok, false));
        }
        if (computer.LastLogonTimestamp is DateTimeOffset logon)
        {
            var days = (int)(now - logon).TotalDays;
            var late = days >= policy.StaleDays;
            if (late)
            {
                Note(points, policy, AttentionLevel.Warn, "Aucune connexion au domaine depuis " + FrenchText.Count(days, "jour", "jours") + " (lastLogonTimestamp approximatif).", "stale", null);
            }
            lines.Add(new SheetLine("computer.ad.lastlogon", "Dernière connexion", "il y a " + FrenchText.Integer(days) + " j",
                late ? "Plus de " + FrenchText.Integer(policy.StaleDays) + " jours, date AD approximative" : PosteText.LocalDate(logon, zone) + " · date approximative, à 14 jours près", late ? Tone.Warn : Tone.Ok, false));
        }
        else
        {
            Note(points, policy, AttentionLevel.Warn, "Aucune date de connexion au domaine (lastLogonTimestamp absent) : poste jamais connecté ou attribut non répliqué.", "never", null);
            lines.Add(new SheetLine("computer.ad.lastlogon", "Dernière connexion", "Jamais", "lastLogonTimestamp absent", Tone.Warn, false));
        }
        if (computer.LapsExpiration is DateTimeOffset laps)
        {
            var expired = laps < now;
            if (expired)
            {
                Note(points, policy, AttentionLevel.Warn, "Mot de passe LAPS expiré (rotation en attente).", "laps.expired", Secrets);
            }
            lines.Add(new SheetLine("computer.ad.laps", "Mot de passe LAPS", expired ? "Expiré" : "Valide", computer.LapsKind + " · expiration le " + PosteText.LocalDateTime(laps, zone), expired ? Tone.Warn : Tone.Ok, false));
        }
        else
        {
            Note(points, policy, AttentionLevel.Info, "Expiration LAPS non visible : LAPS absent, non publié ou attribut illisible avec ce compte.", "laps.none", Secrets);
            lines.Add(new SheetLine("computer.ad.laps", "Mot de passe LAPS", "Non visible", "Aucune expiration lisible (absence ou droits)", Tone.Off, false));
        }
        if (computer.ManagedBy is { } manager)
        {
            lines.Add(new SheetLine("computer.ad.managedby", "Géré par", manager.Name, "Attribut managedBy", null, false));
        }
        if (inventory?.ClockSkewSeconds is int skew)
        {
            var gap = Math.Abs(skew);
            var byController = inventory.ClockAgainstController;
            var against = byController ? "par rapport au contrôleur de domaine" : "par rapport à ce poste d’administration";
            if (gap > 300 && byController)
            {
                Note(points, policy, AttentionLevel.Alert, "Horloge décalée de " + FrenchText.Signed(skew) + " s " + against + " : risque d’échec de l’authentification Kerberos.", "clock", null);
            }
            else if (gap > 60)
            {
                Note(points, policy, AttentionLevel.Warn, "Horloge décalée de " + FrenchText.Signed(skew) + " s " + against + "." + (byController ? "" : " Vérifiez la synchronisation des deux postes ; le contrôleur n’a pas été lu."), "clock", null);
            }
            var detail = !byController ? "Écart avec ce poste d’administration (contrôleur non lu)" : gap > 300 ? "Plus de 5 min avec le contrôleur : risque d’échec Kerberos" : "Écart avec le contrôleur de domaine";
            lines.Add(new SheetLine("computer.ad.clock", "Horloge", gap < 2 ? "À l’heure" : FrenchText.Signed(skew) + " s", detail, gap > 300 && byController ? Tone.Alert : gap > 60 ? Tone.Warn : Tone.Ok, false));
        }
        var built = lines.ToImmutable();
        var toCheck = built.Count(l => l.State is Tone.Warn or Tone.Alert);
        return new PosteSheet("computer.adaccount", "Compte machine dans Active Directory", FrenchText.Count(built.Count(l => l.State != Tone.Off), "information", "informations"),
            toCheck > 0 ? FrenchText.Integer(toCheck) + " à vérifier" : null, built.Any(l => l.State == Tone.Alert) ? Tone.Alert : toCheck > 0 ? Tone.Warn : null, built);
    }

    // ------------------------------------------------------------------ identity (PST-095)

    private static PosteSheet IdentitySheet(PosteComputer computer, InventorySnapshot inv, PosteHealthPolicy policy, DateTimeOffset now, TimeZoneInfo zone, List<AttentionPoint> points, Dictionary<string, SheetLine> all)
    {
        var lines = ImmutableArray.CreateBuilder<SheetLine>();
        void Add(SheetLine line)
        {
            lines.Add(line);
            all[line.Key] = line;
        }
        if (inv.Os is { } os)
        {
            var release = WindowsRelease.Describe(os.Caption, "10.0 (" + os.Build + ")");
            var label = release?.Label ?? os.Caption;
            Add(new SheetLine("computer.os", "Système", label, os.Caption + " · build " + os.Build + (os.Revision is int rev ? "." + rev.ToString(CultureInfo.InvariantCulture) : "") + " · " + os.Architecture, null, false));
        }
        else
        {
            Add(new SheetLine("computer.os", "Système", "Non lu", computer.OperatingSystem ?? "Système non renseigné dans l’annuaire", Tone.Off, false));
        }
        if (inv.System is { } sys)
        {
            var virtualPlatform = sys.Hypervisor ?? PosteLabels.VirtualPlatform(sys.Manufacturer, sys.Model);
            Add(new SheetLine("computer.model", "Modèle", PosteText.Model(sys.Manufacturer, sys.Model),
                (string.IsNullOrWhiteSpace(sys.SerialNumber) ? "Numéro de série non renseigné" : "N° de série " + sys.SerialNumber) + (virtualPlatform is null ? "" : " · machine virtuelle estimée (" + virtualPlatform + ")"), null, !string.IsNullOrWhiteSpace(sys.SerialNumber)));
        }
        if (!inv.Processors.IsEmpty)
        {
            var cpu = inv.Processors[0];
            var cores = inv.Processors.Sum(p => p.Cores ?? 0);
            var threads = inv.Processors.Sum(p => p.LogicalProcessors ?? 0);
            Add(new SheetLine("computer.cpu", "Processeur", cpu.Name.Trim(),
                FrenchText.Count(cores, "cœur", "cœurs") + ", " + FrenchText.Count(threads, "processeur logique", "processeurs logiques") + (cpu.MaxClockMhz is int mhz ? " · " + FrenchText.Integer(mhz) + " MHz" : ""), null, false));
        }
        var installed = inv.MemoryModules.Where(m => m.CapacityBytes is > 0).Sum(m => m.CapacityBytes!.Value);
        if (installed > 0 || inv.System?.TotalPhysicalMemory is > 0)
        {
            var total = installed > 0 ? installed : inv.System!.TotalPhysicalMemory!.Value;
            var slots = inv.MemoryArray?.Slots;
            var detail = inv.MemoryModules.IsEmpty
                ? "Aucune barrette exposée (machine virtuelle probable) : mémoire visible par Windows"
                : FrenchText.Count(inv.MemoryModules.Length, "barrette", "barrettes") + (slots is int s ? " sur " + FrenchText.Count(s, "emplacement", "emplacements") : "");
            Add(new SheetLine("computer.memory", "Mémoire installée", PosteText.Size(total), detail, null, false));
        }
        if (inv.Os?.LastBoot is DateTimeOffset boot)
        {
            var uptime = now - boot;
            var days = (int)uptime.TotalDays;
            var late = days >= policy.UptimeDays;
            if (late)
            {
                Note(points, policy, AttentionLevel.Warn, "Pas de redémarrage depuis " + FrenchText.Count(days, "jour", "jours") + ".", "uptime", Restart);
            }
            Add(new SheetLine("computer.uptime", "En service depuis", PosteText.Duration(uptime), "Démarré le " + PosteText.LocalDateTime(boot, zone), late ? Tone.Warn : null, false));
        }
        else
        {
            Add(new SheetLine("computer.uptime", "En service depuis", "Non lu", "Dernier démarrage non renseigné", Tone.Off, false));
        }
        var console = inv.System?.UserName;
        Add(new SheetLine("computer.user", "Utilisateur connecté", string.IsNullOrWhiteSpace(console) ? "Aucun à la console" : console!,
            string.IsNullOrWhiteSpace(console) ? "Console vide au moment de l’inventaire (une session RDP reste possible)" : "Session console au moment de l’inventaire", null, false));
        var adapter = inv.Network.Where(n => n.Physical && n.Ipv4.Length > 0).OrderByDescending(n => n.Status == 2).FirstOrDefault();
        if (adapter is not null)
        {
            Add(new SheetLine("computer.ip", "Adresse IP", adapter.Ipv4[0], (adapter.Gateway is null ? "Passerelle non renseignée" : "Passerelle " + adapter.Gateway) + " · " + adapter.Name, null, true));
        }
        if (inv.Os is { } osDomain)
        {
            Add(new SheetLine("computer.domain", "Domaine", osDomain.Domain ?? "Non renseigné", PosteLabels.DomainRole(osDomain.DomainRole), null, false));
        }
        var built = lines.ToImmutable();
        var toCheck = built.Count(l => l.State is Tone.Warn or Tone.Alert);
        return new PosteSheet("computer.identity", "Identité du poste", FrenchText.Count(built.Count(l => l.State != Tone.Off), "information", "informations"),
            toCheck > 0 ? FrenchText.Integer(toCheck) + " à vérifier" : null, toCheck > 0 ? Tone.Warn : null, built);
    }

    // ------------------------------------------------------------------ resources (PST-097)

    private static ResourceGauges Resources(InventorySnapshot inv, PosteHealthPolicy policy, List<AttentionPoint> points)
    {
        MeterValue? memory = null;
        if (inv.Memory is { VisibleKb: > 0 } usage && usage.FreeKb is long free && free >= 0 && free <= usage.VisibleKb)
        {
            var total = usage.VisibleKb!.Value;
            var used = total - free;
            var percent = Math.Round(100d * used / total, 1);
            var warn = percent > policy.MemoryUsedWarn;
            if (warn)
            {
                Note(points, policy, AttentionLevel.Warn, "Mémoire utilisée à plus de " + FrenchText.Integer(policy.MemoryUsedWarn) + " % (" + FrenchText.Percent(percent, 0) + " au relevé).", "memory", null);
            }
            memory = new MeterValue(percent, FrenchText.Percent(percent, 0), PosteText.Size(used * 1024d) + " sur " + PosteText.Size(total * 1024d), warn ? Tone.Warn : Tone.Ok);
        }
        MeterValue? cpu = null;
        if (inv.Processors.Any(p => p.LoadPercent is not null))
        {
            var load = inv.Processors.Where(p => p.LoadPercent is not null).Average(p => p.LoadPercent!.Value);
            cpu = new MeterValue(Math.Round(load, 1), FrenchText.Percent(load, 0), "Charge instantanée au relevé (une photographie, pas une moyenne)", load >= 90 ? Tone.Warn : Tone.Ok);
        }
        MeterValue? battery = null;
        string? batteryText = null;
        if (inv.Read(InventoryCategories.Batteries))
        {
            var first = inv.Batteries.FirstOrDefault(b => b.ChargePercent is not null);
            if (first is null)
            {
                batteryText = inv.Batteries.IsEmpty ? "Aucune batterie (poste fixe ou batterie non exposée)" : "Charge non renseignée";
            }
            else
            {
                var charge = first.ChargePercent!.Value;
                var low = charge < policy.BatteryWarn;
                if (low)
                {
                    Note(points, policy, AttentionLevel.Warn, "Batterie à " + FrenchText.Integer(charge) + " %.", "battery", null);
                }
                battery = new MeterValue(charge, FrenchText.Integer(charge) + " %", low ? "Moins de " + FrenchText.Integer(policy.BatteryWarn) + " % : poste à brancher" : "Charge restante · " + PosteLabels.BatteryStatus(first.Status), low ? Tone.Warn : Tone.Ok);
            }
        }
        var text = memory is null && cpu is null ? "Aucune mesure chiffrée relevée pendant cet inventaire." : null;
        return new ResourceGauges(memory, cpu, battery, batteryText, text);
    }

    // ------------------------------------------------------------------ disks (PST-098)

    private static DiskBoard Disks(InventorySnapshot inv, PosteHealthPolicy policy, List<AttentionPoint> points)
    {
        var volumes = inv.Volumes.Where(v => v.SizeBytes is > 0 && v.FreeBytes is >= 0 && v.FreeBytes <= v.SizeBytes).ToList();
        var system = volumes.FirstOrDefault(v => string.Equals(v.Id, "C:", StringComparison.OrdinalIgnoreCase)) ?? volumes.FirstOrDefault();
        DiskGauge? systemGauge = null;
        if (system is not null)
        {
            var percent = Math.Round(100d * system.FreeBytes!.Value / system.SizeBytes!.Value, 1);
            var state = policy.DiskState(percent);
            var name = "Disque " + system.Id;
            if (state == Tone.Alert)
            {
                Note(points, policy, AttentionLevel.Alert, name + " presque plein (" + FrenchText.Percent(percent) + " libre).", "lowdisk", DiskTools);
            }
            else if (state == Tone.Warn)
            {
                Note(points, policy, AttentionLevel.Warn, "Peu d’espace sur " + name + " (" + FrenchText.Percent(percent) + " libre).", "disk.tight", DiskTools);
            }
            systemGauge = new DiskGauge(system.Id, system.SizeBytes, system.FreeBytes, percent, state, PosteText.Size(system.FreeBytes.Value) + " libres sur " + PosteText.Size(system.SizeBytes.Value));
        }
        var others = ImmutableArray.CreateBuilder<DiskGauge>();
        foreach (var volume in volumes.Where(v => !ReferenceEquals(v, system)).OrderBy(v => (double)v.FreeBytes!.Value / v.SizeBytes!.Value))
        {
            var percent = Math.Round(100d * volume.FreeBytes!.Value / volume.SizeBytes!.Value, 1);
            var state = policy.DiskState(percent);
            if (state == Tone.Alert)
            {
                Note(points, policy, AttentionLevel.Alert, "Volume " + volume.Id + " presque plein (" + FrenchText.Percent(percent) + " libre).", "lowdisk", null);
            }
            others.Add(new DiskGauge(volume.Id, volume.SizeBytes, volume.FreeBytes, percent, state, PosteText.Size(volume.FreeBytes.Value) + " libres sur " + PosteText.Size(volume.SizeBytes!.Value)));
        }
        return new DiskBoard(systemGauge, others.ToImmutable(), others.Count == 0 ? "Aucun autre volume" : FrenchText.Count(others.Count, "autre volume", "autres volumes"));
    }

    // ------------------------------------------------------------------ activity (PST-099)

    private static ActivityBoard Activity(InventorySnapshot inv, PosteHealthPolicy policy, List<AttentionPoint> points, DateTimeOffset now)
    {
        var services = ImmutableArray<CountPart>.Empty;
        var total = 0;
        if (inv.Read(InventoryCategories.Services))
        {
            var running = inv.Services.Count(s => s.State == "Running");
            var autoStopped = 0;
            var expected = 0;
            foreach (var s in inv.Services.Where(s => s.StartMode == "Auto" && s.State == "Stopped"))
            {
                if (PosteServices.StopExpected(s.Name, out _))
                {
                    expected++;
                }
                else
                {
                    autoStopped++;
                }
            }
            var manual = inv.Services.Count(s => s.StartMode == "Manual" && s.State != "Running");
            var disabled = inv.Services.Count(s => s.StartMode == "Disabled");
            total = inv.Services.Length;
            services =
            [
                new("running", "En cours", running, Tone.Ok),
                new("autoStopped", "Arrêtés (automatiques)", autoStopped, Tone.Warn),
                new("expected", "Sur déclencheur ou différés", expected, Tone.Info),
                new("manual", "Manuels arrêtés", manual, Tone.Off),
                new("disabled", "Désactivés", disabled, Tone.Off),
            ];
            if (autoStopped > 0)
            {
                Note(points, policy, AttentionLevel.Warn, FrenchText.Count(autoStopped, "service automatique arrêté", "services automatiques arrêtés") + ".", "services", ServicesView);
            }
        }
        var processes = ImmutableArray<ProcessBar>.Empty;
        var measure = "";
        if (inv.Read(InventoryCategories.Processes))
        {
            measure = "Mémoire de travail (Mo) au relevé ; la charge processeur se mesure entre deux lectures (onglet Processus).";
            processes =
            [
                .. inv.Processes.Where(p => p.WorkingSetBytes is > 0 && p.Id > 4).GroupBy(p => p.Name, StringComparer.OrdinalIgnoreCase)
                    .Select(g => (Name: g.Key, Bytes: g.Sum(p => p.WorkingSetBytes!.Value), Count: g.Count()))
                    .OrderByDescending(x => x.Bytes).ThenBy(x => x.Name, StringComparer.Ordinal).Take(6)
                    .Select(x => new ProcessBar(x.Name, Math.Round(x.Bytes / 1048576d), "Mo", PosteText.Size(x.Bytes) + (x.Count > 1 ? " (" + FrenchText.Integer(x.Count) + " instances)" : ""))),
            ];
        }
        var events = ImmutableArray<EventSourceCount>.Empty;
        var ignored = 0;
        var eventsText = "Journal Système non lu (inventaire complet)";
        if (inv.Read(InventoryCategories.Events))
        {
            var recent = inv.SystemEvents.Where(e => e.At >= now.AddDays(-3) && string.Equals(e.Level, "Erreur", StringComparison.Ordinal)).ToList();
            var critical = 0;
            var generic = 0;
            var bySource = new Dictionary<string, (int Count, AttentionLevel Level)>(StringComparer.OrdinalIgnoreCase);
            foreach (var e in recent)
            {
                var (level, _) = PosteEvents.SystemEventLevel(e.Provider, e.Id);
                if (level == "Ignore")
                {
                    ignored++;
                    continue;
                }
                var lvl = level == "Warn" ? AttentionLevel.Warn : AttentionLevel.Info;
                if (lvl == AttentionLevel.Warn)
                {
                    critical++;
                }
                else
                {
                    generic++;
                }
                bySource[e.Provider] = bySource.TryGetValue(e.Provider, out var known) ? (known.Count + 1, known.Level == AttentionLevel.Warn ? known.Level : lvl) : (1, lvl);
            }
            events = [.. bySource.OrderByDescending(p => p.Value.Count).ThenBy(p => p.Key, StringComparer.Ordinal).Select(p => new EventSourceCount(p.Key, p.Value.Count, p.Value.Level))];
            if (critical > 0)
            {
                Note(points, policy, AttentionLevel.Warn, FrenchText.Count(critical, "erreur critique", "erreurs critiques") + " dans le journal Système sur 3 jours (disque, NTFS ou arrêt inattendu).", "events", null);
            }
            if (generic > 0)
            {
                points.Add(new AttentionPoint(AttentionLevel.Info, FrenchText.Count(generic, "autre erreur", "autres erreurs") + " dans le journal Système sur 3 jours.", "events.info", null, null));
            }
            eventsText = recent.Count == 0 ? "Aucune erreur dans le journal Système sur 3 jours" : FrenchText.Count(critical + generic, "erreur retenue", "erreurs retenues") + (ignored > 0 ? ", " + FrenchText.Count(ignored, "ignorée", "ignorées") + " (bruit connu)" : "");
        }
        var hint = inv.Deep ? null : "L’inventaire complet ajoute les processus et les erreurs système.";
        return new ActivityBoard(services, total, processes, measure, events, ignored, eventsText, hint);
    }

    // ------------------------------------------------------------------ count tiles (PST-107)

    private static ImmutableArray<CountTile> Counts(InventorySnapshot inv, PosteHealthPolicy policy, List<AttentionPoint> points)
    {
        var tiles = ImmutableArray.CreateBuilder<CountTile>();
        void Tile(string key, string label, string category, int count, string detail, bool watch, string rule)
        {
            if (!inv.Read(category))
            {
                tiles.Add(new CountTile(key, label, null, Tone.Off, "Non lu pendant cet inventaire", category));
                return;
            }
            Tone? state = null;
            if (watch)
            {
                state = count > 0 ? Tone.Warn : Tone.Ok;
                if (count > 0)
                {
                    Note(points, policy, AttentionLevel.Warn, FrenchText.Integer(count) + " " + label.ToLower(CultureInfo.GetCultureInfo("fr-FR")) + ".", rule, null);
                }
            }
            tiles.Add(new CountTile(key, label, count, state, detail, category));
        }
        var devices = inv.Devices.Where(d => !PosteLabels.DeviceCodeIsChoice(d.Code)).ToList();
        Tile("computer.devices", "Périphériques en erreur", InventoryCategories.Devices, devices.Count, devices.Count == 0 ? "Aucun" : devices[0].Name + (devices.Count > 1 ? " et " + FrenchText.Count(devices.Count - 1, "autre", "autres") : "") + " · " + PosteLabels.DeviceError(devices[0].Code), true, "devices");
        Tile("computer.drivers", "Pilotes non signés", InventoryCategories.Drivers, inv.UnsignedDrivers.Length, inv.UnsignedDrivers.IsEmpty ? "Aucun" : inv.UnsignedDrivers[0].Name, true, "drivers");
        Tile("computer.admins", "Administrateurs locaux", InventoryCategories.Admins, inv.LocalAdmins.Length, inv.LocalAdmins.IsEmpty ? "Groupe non lu" : string.Join(", ", inv.LocalAdmins.Take(3)), false, "");
        Tile("computer.sessions", "Sessions et comptes locaux", InventoryCategories.Sessions, inv.Sessions.Count(s => !string.IsNullOrEmpty(s.User)), inv.Sessions.Any(s => !string.IsNullOrEmpty(s.User)) ? string.Join(", ", inv.Sessions.Where(s => !string.IsNullOrEmpty(s.User)).Select(s => s.User!).Take(2)) : "Aucune", false, "");
        var autostart = inv.Startup.Count(s => !s.Microsoft);
        Tile("computer.autostart", "Démarrage automatique", InventoryCategories.Startup, inv.Startup.Length, inv.Startup.IsEmpty ? "Aucun programme" : FrenchText.Integer(autostart) + " hors Microsoft", false, "");
        Tile("computer.shares", "Partages", InventoryCategories.Shares, inv.Shares.Count(s => !s.Name.EndsWith('$')), inv.Shares.All(s => s.Name.EndsWith('$')) ? "Aucun partage (hors partages administratifs)" : string.Join(", ", inv.Shares.Where(s => !s.Name.EndsWith('$')).Select(s => s.Name).Take(3)), false, "");
        var offline = inv.Printers.Count(p => p.Offline || p.Error);
        Tile("computer.printers", "Imprimantes", InventoryCategories.Printers, inv.Printers.Length, inv.Printers.IsEmpty ? "Aucune" : (inv.Printers.FirstOrDefault(p => p.Default)?.Name ?? inv.Printers[0].Name) + (offline > 0 ? " · " + FrenchText.Integer(offline) + " hors ligne ou en erreur" : ""), false, "");
        if (inv.Read(InventoryCategories.Displays))
        {
            var first = inv.Displays.FirstOrDefault();
            tiles.Add(new CountTile("computer.display", "Affichage", inv.Displays.Length, null, first is null ? "Aucun écran identifié" : first.Name + " · " + first.Connection + (inv.Displays.Length > 1 ? " et " + FrenchText.Count(inv.Displays.Length - 1, "autre", "autres") : ""), InventoryCategories.Displays));
        }
        if (inv.Read(InventoryCategories.PhysicalDisks))
        {
            var disk = inv.PhysicalDisks.FirstOrDefault();
            tiles.Add(new CountTile("computer.physicaldisk", "Disque physique", inv.PhysicalDisks.Length, disk?.Health is 1 or 2 ? Tone.Alert : null,
                disk is null ? "Aucun disque renvoyé" : disk.Name + " · " + PosteLabels.MediaType(disk.MediaType) + " " + PosteLabels.BusType(disk.BusType), InventoryCategories.PhysicalDisks));
        }
        return tiles.ToImmutable();
    }

    // ------------------------------------------------------------------ protection sections (PST-100 to PST-106)

    private static ImmutableArray<BoardSection> Sections(InventorySnapshot inv, PosteHealthPolicy policy, DateTimeOffset now, TimeZoneInfo zone, List<AttentionPoint> points, Dictionary<string, SheetLine> lines)
    {
        var sections = ImmutableArray.CreateBuilder<BoardSection>();
        var src = "Inventaire du " + PosteText.LocalDateTime(inv.CollectedAt, zone);

        // BitLocker of the system volume first (PST-102): encrypted with protection off is suspended, not unencrypted.
        if (inv.Read(InventoryCategories.BitLocker))
        {
            var facts = ImmutableArray.CreateBuilder<PosteFact>();
            var system = inv.BitLocker.FirstOrDefault(v => string.Equals(v.Drive, "C:", StringComparison.OrdinalIgnoreCase)) ?? inv.BitLocker.FirstOrDefault();
            string value;
            Tone state;
            if (system is null)
            {
                value = "Aucun volume chiffrable renvoyé";
                state = Tone.Warn;
                Note(points, policy, AttentionLevel.Warn, "BitLocker : aucun volume chiffrable renvoyé.", "bitlocker.none", Secrets);
            }
            else
            {
                var encrypted = system.Conversion is 1 || system.EncryptedPercent >= 99.9;
                var suspended = encrypted && system.Protection == 0;
                if (suspended)
                {
                    value = "Protection suspendue";
                    state = Tone.Warn;
                    Note(points, policy, AttentionLevel.Warn, "BitLocker : protection suspendue sur " + system.Drive + ", volume chiffré.", "bitlocker.suspended", Secrets);
                }
                else if (system.Protection == 1)
                {
                    value = "Protégé";
                    state = Tone.Ok;
                }
                else
                {
                    value = encrypted ? "Protection inconnue" : "Non chiffré";
                    state = Tone.Warn;
                    Note(points, policy, AttentionLevel.Warn, "BitLocker : " + system.Drive + " " + value.ToLower(CultureInfo.GetCultureInfo("fr-FR")) + ".", "bitlocker.none", Secrets);
                }
                foreach (var v in inv.BitLocker)
                {
                    var enc = v.Conversion is 1 || v.EncryptedPercent >= 99.9;
                    var text = (v.Protection == 1 ? "protégé" : enc && v.Protection == 0 ? "protection suspendue" : enc ? "chiffré" : "non chiffré")
                        + (v.Method is int m and > 0 ? " · " + PosteLabels.BitLockerMethod(m) : "")
                        + (v.EncryptedPercent is double pct && pct < 99.9 ? " · " + FrenchText.Percent(pct, 0) + " chiffré" : "")
                        + (v.ProtectorCount is int k ? " · " + FrenchText.Count(k, "protecteur", "protecteurs") : "");
                    facts.Add(PosteText.Fact("Volume " + v.Drive, text, FactState.Observed, "Win32_EncryptableVolume", v.Protection == 1 ? null : "Chiffré avec protection suspendue n’est pas protégé.", at: inv.CollectedAt, tone: v.Protection == 1 ? Tone.Ok : Tone.Warn));
                }
            }
            lines["computer.bitlocker"] = new SheetLine("computer.bitlocker", "BitLocker", value, system?.Drive is string d ? "Volume " + d : null, state, false);
            sections.Add(new BoardSection("bitlocker", "BitLocker du volume système", value, "Le mot « Protection » seul ne prouve rien : état de protection et de chiffrement lus ensemble.", state, facts.ToImmutable()));
        }

        // Firewall by effective profile (PST-101): the policy wins over the local key.
        if (inv.Read(InventoryCategories.Firewall))
        {
            var facts = ImmutableArray.CreateBuilder<PosteFact>();
            var off = new List<string>();
            var appliedOff = new List<string>();
            foreach (var profile in inv.Firewall)
            {
                var effective = profile.PolicyEnabled ?? profile.LocalEnabled;
                var origin = profile.PolicyEnabled is null ? "clé locale" : "stratégie de groupe";
                var applied = profile.Connections.Length > 0;
                if (effective == false)
                {
                    off.Add(profile.Name);
                    if (applied)
                    {
                        appliedOff.Add(profile.Name);
                    }
                }
                facts.Add(PosteText.Fact("Profil " + profile.Name, (effective switch { true => "Activé", false => "Désactivé", _ => "Inconnu" }) + " (" + origin + ")" + (applied ? " · appliqué à " + string.Join(", ", profile.Connections) : " · aucune connexion active"),
                    effective is null ? FactState.Unknown : FactState.Observed, "Pare-feu Windows", null, at: inv.CollectedAt, tone: effective == false ? (applied ? Tone.Alert : Tone.Warn) : effective == true ? Tone.Ok : Tone.Off));
            }
            if (appliedOff.Count > 0)
            {
                Note(points, policy, AttentionLevel.Warn, "Pare-feu désactivé sur le profil appliqué : " + string.Join(", ", appliedOff) + ".", "firewall", null);
            }
            else if (off.Count > 0)
            {
                Note(points, policy, AttentionLevel.Warn, "Pare-feu désactivé : " + string.Join(", ", off) + ".", "firewall", null);
            }
            var value = off.Count == 0 ? "Activé sur tous les profils" : "Désactivé sur " + string.Join(", ", off);
            var state = appliedOff.Count > 0 ? Tone.Alert : off.Count > 0 ? Tone.Warn : Tone.Ok;
            lines["computer.firewall"] = new SheetLine("computer.firewall", "Pare-feu", off.Count == 0 ? "Activé" : "Désactivé (" + string.Join(", ", off) + ")", null, state, false);
            sections.Add(new BoardSection("firewall", "Pare-feu par profil effectif", value, "La stratégie prime sur la clé locale ; profil désactivé appliqué nommé en premier.", state,
                [.. facts.ToImmutable().OrderByDescending(f => f.Tone == Tone.Alert)]));
        }

        // Antivirus: products of the Security Center (estimated state) and Defender details.
        if (inv.Read(InventoryCategories.Antivirus))
        {
            var facts = ImmutableArray.CreateBuilder<PosteFact>();
            var active = false;
            foreach (var product in inv.Antivirus)
            {
                var (enabled, upToDate) = PosteLabels.AntivirusState(product.ProductState);
                active |= enabled == true;
                facts.Add(PosteText.Fact(product.Name, (enabled switch { true => "Actif", false => "Inactif", _ => "État inconnu" }) + (upToDate switch { true => ", signatures à jour", false => ", signatures à vérifier", _ => "" }),
                    FactState.Estimated, "Centre de sécurité (productState)", "Décodage non documenté : estimation.", at: inv.CollectedAt, tone: enabled == true ? Tone.Ok : Tone.Warn));
            }
            if (inv.Defender is { } defender)
            {
                facts.Add(PosteText.Fact("Microsoft Defender", (defender.RealTime == true ? "Protection en temps réel active" : "Protection en temps réel inactive") + (defender.Passive == true ? " (mode passif)" : "")
                    + (defender.SignatureAgeDays is int age ? " · signatures de " + FrenchText.Count(age, "jour", "jours") : ""), FactState.Observed, "MSFT_MpComputerStatus",
                    defender.Passive == true ? "Mode passif : un autre antivirus est déclaré." : null, at: inv.CollectedAt, tone: defender.RealTime == true && defender.SignatureAgeDays is null or < 7 ? Tone.Ok : Tone.Warn));
            }
            var value = inv.Antivirus.IsEmpty ? "Aucun produit déclaré" : active ? string.Join(", ", inv.Antivirus.Select(a => a.Name)) : "Aucun produit actif";
            var state = active ? Tone.Ok : Tone.Warn;
            lines["computer.antivirus"] = new SheetLine("computer.antivirus", "Antivirus", value, null, state, false);
            sections.Add(new BoardSection("antivirus", "Antivirus et Defender", value, "Produits déclarés au Centre de sécurité ; un serveur peut ne pas en avoir.", state, facts.ToImmutable()));
        }

        // Pending reboot (PST-104): only a confirmed obligation is a point; partial hints are shown without one.
        if (inv.Read(InventoryCategories.Reboot) && inv.PendingReboot is { } reboot)
        {
            var pending = !reboot.Confirmed.IsEmpty;
            if (pending)
            {
                Note(points, policy, AttentionLevel.Warn, "Redémarrage en attente, confirmé par : " + string.Join(", ", reboot.Confirmed) + ".", "reboot", Restart);
            }
            var value = pending ? "Oui" : reboot.Partial.IsEmpty ? "Non" : "Indices partiels";
            var detail = pending ? "Confirmé par " + string.Join(", ", reboot.Confirmed) : reboot.Partial.IsEmpty ? "Aucun indicateur du registre" : "Indices partiels : " + string.Join(", ", reboot.Partial) + " (pas une obligation)";
            var state = pending ? Tone.Warn : Tone.Ok;
            lines["computer.reboot"] = new SheetLine("computer.reboot", "Redémarrage en attente", value, detail, pending ? Tone.Warn : reboot.Partial.IsEmpty ? Tone.Ok : null, false);
            sections.Add(new BoardSection("reboot", "Redémarrage en attente", value, detail, state,
                [
                    .. reboot.Confirmed.Select(c => PosteText.Fact(c, "Obligation confirmée", FactState.Observed, "Registre", null, at: inv.CollectedAt, tone: Tone.Warn)),
                    .. reboot.Partial.Select(c => PosteText.Fact(c, "Indice partiel", FactState.Estimated, "Registre", "Un indice partiel n’est pas une obligation.", at: inv.CollectedAt, tone: Tone.Info)),
                ]));
        }

        // Windows Update, WSUS, hotfixes and build (PST-103): compliance is never concluded.
        if (inv.Read(InventoryCategories.Hotfixes) || inv.Read(InventoryCategories.Updates))
        {
            var facts = ImmutableArray.CreateBuilder<PosteFact>();
            var latest = inv.Hotfixes.Where(h => h.InstalledOn is not null).OrderByDescending(h => h.InstalledOn).FirstOrDefault();
            Tone hotfixState = Tone.Off;
            if (latest?.InstalledOn is DateTimeOffset installed)
            {
                var age = (int)(now - installed).TotalDays;
                var old = age > policy.HotfixDays;
                hotfixState = old ? Tone.Warn : Tone.Ok;
                if (old)
                {
                    Note(points, policy, AttentionLevel.Warn, "Dernier correctif installé il y a " + FrenchText.Count(age, "jour", "jours") + ".", "hotfix", null);
                }
                lines["computer.hotfix"] = new SheetLine("computer.hotfix", "Dernier correctif", "il y a " + FrenchText.Integer(age) + " j", PosteText.LocalDate(installed, zone) + " · " + latest.Id + " · " + FrenchText.Count(inv.Hotfixes.Length, "correctif", "correctifs"), old ? Tone.Warn : Tone.Ok, false);
                facts.Add(PosteText.Fact("Dernier correctif (QFE)", latest.Id + " installé le " + PosteText.LocalDate(installed, zone), FactState.Observed, "Win32_QuickFixEngineering", "QFE ne liste pas toutes les mises à jour : conformité non évaluée.", at: inv.CollectedAt, tone: hotfixState));
            }
            if (inv.Os is { } os)
            {
                facts.Add(PosteText.Fact("Build", os.Build + (os.Revision is int rev ? "." + rev.ToString(CultureInfo.InvariantCulture) : ""), FactState.Observed, "Win32_OperatingSystem", null, at: inv.CollectedAt, tone: Tone.Info));
            }
            if (inv.Updates is { } updates)
            {
                if (!string.IsNullOrWhiteSpace(updates.WsusServer))
                {
                    facts.Add(PosteText.Fact("Serveur WSUS", updates.UseWsus == true ? updates.WsusServer! : "Adresse déclarée, non appliquée (UseWUServer) : " + updates.WsusServer, FactState.Observed, "Registre (stratégie Windows Update)",
                        "Configuration lue, pas un contact avec le serveur.", at: inv.CollectedAt, tone: updates.UseWsus == true ? Tone.Info : Tone.Warn));
                }
                else
                {
                    facts.Add(PosteText.Fact("Source des mises à jour", "Windows Update (aucun serveur WSUS configuré)", FactState.Observed, "Registre (stratégie Windows Update)", null, at: inv.CollectedAt, tone: Tone.Info));
                }
                facts.AddRange(PosteUpdates.Facts(updates, now, zone));
            }
            var value = latest?.InstalledOn is DateTimeOffset at ? "Dernier correctif " + PosteText.Age(at, now) : "Aucun correctif daté";
            sections.Add(new BoardSection("updates", "Windows Update, WSUS et correctifs", value, "Conformité non évaluée : QFE ne liste pas toutes les mises à jour.", hotfixState, facts.ToImmutable()));
        }

        // Secure Boot (PST-105): a point only when it is off on UEFI firmware; legacy BIOS or no value is not measured.
        if (inv.Read(InventoryCategories.Bios) && inv.SecureBoot is { } boot)
        {
            var uefi = string.Equals(boot.Firmware, "UEFI", StringComparison.OrdinalIgnoreCase);
            if (boot.Enabled == false && uefi)
            {
                Note(points, policy, AttentionLevel.Warn, "Secure Boot désactivé sur un micrologiciel UEFI.", "secureboot", null);
            }
            var value = boot.Enabled switch { true => "Activé", false => uefi ? "Désactivé" : "Non applicable (BIOS hérité)", _ => "Non mesuré" };
            var state = boot.Enabled == true ? Tone.Ok : boot.Enabled == false && uefi ? Tone.Warn : Tone.Off;
            lines["computer.secureboot"] = new SheetLine("computer.secureboot", "Démarrage sécurisé", value, "Micrologiciel " + (boot.Firmware ?? "non renseigné"), state, false);
            sections.Add(new BoardSection("secureboot", "Démarrage sécurisé", value, "Micrologiciel " + (boot.Firmware ?? "non renseigné"), state,
                [
                    PosteText.Fact("Secure Boot", value, boot.Enabled is null ? FactState.Unknown : FactState.Observed, "Registre (SecureBoot\\State)", uefi ? null : "BIOS hérité ou valeur absente : non mesuré.", at: inv.CollectedAt, tone: state),
                    PosteText.Fact("Sécurité basée sur la virtualisation", boot.VbsRunning switch { true => "En cours", false => "Arrêtée", _ => "Non lue" }, boot.VbsRunning is null ? FactState.Unknown : FactState.Observed, "Win32_DeviceGuard", null, at: inv.CollectedAt, tone: Tone.Info),
                ]));
        }

        // Machine certificates (PST-106): a partial read never shows a good state; the private key is never read.
        if (inv.Read(InventoryCategories.Certificates))
        {
            var expired = inv.Certificates.Where(c => c.NotAfter < now).ToList();
            var soon = inv.Certificates.Where(c => c.NotAfter >= now && c.NotAfter < now.AddDays(30)).ToList();
            var valid = inv.Certificates.Length - expired.Count - soon.Count;
            if (expired.Count > 0)
            {
                Note(points, policy, AttentionLevel.Warn, FrenchText.Count(expired.Count, "certificat machine expiré", "certificats machine expirés") + " : " + string.Join(", ", expired.Take(2).Select(c => c.Subject)) + ".", "certificates", null);
            }
            else if (soon.Count > 0)
            {
                Note(points, policy, AttentionLevel.Warn, FrenchText.Count(soon.Count, "certificat machine expirant", "certificats machine expirant") + " dans les 30 jours.", "certificates", null);
            }
            var partial = inv.StatusOf(InventoryCategories.Certificates) == SourceStatus.Partial;
            var detail = FrenchText.Count(expired.Count, "expiré", "expirés") + ", " + FrenchText.Integer(soon.Count) + " sous 30 jours, " + FrenchText.Count(valid, "valide", "valides") + (partial ? " · lecture partielle" : "");
            var state = expired.Count > 0 || soon.Count > 0 ? Tone.Warn : partial ? Tone.Off : Tone.Ok;
            sections.Add(new BoardSection("certificates", "Certificats machine", FrenchText.Count(inv.Certificates.Length, "certificat", "certificats"), detail, state,
                [
                    .. inv.Certificates.OrderBy(c => c.NotAfter).Select(c => PosteText.Fact(c.Subject,
                        (c.NotAfter < now ? "Expiré le " : "Expire le ") + PosteText.LocalDate(c.NotAfter, zone) + " · émis par " + c.Issuer + (c.Usages.IsEmpty ? "" : " · " + string.Join(", ", c.Usages)),
                        FactState.Observed, "Magasin Personnel de l’ordinateur", "Clé privée jamais lue, rien n’est exporté.", at: inv.CollectedAt,
                        tone: c.NotAfter < now ? Tone.Alert : c.NotAfter < now.AddDays(30) ? Tone.Warn : Tone.Ok)),
                ]));
        }
        return sections.ToImmutable();
    }

    // ------------------------------------------------------------------ checklist and health

    private static PosteSheet Checklist(IReadOnlyList<(string Key, string Label)> keys, Dictionary<string, SheetLine> known)
    {
        var lines = ImmutableArray.CreateBuilder<SheetLine>();
        foreach (var (key, label) in keys)
        {
            lines.Add(known.TryGetValue(key, out var line) ? line : new SheetLine(key, label, "Non lu", null, Tone.Off, false));
        }
        var built = lines.ToImmutable();
        var read = built.Count(l => l.State != Tone.Off || l.Value != "Non lu");
        var toCheck = built.Count(l => l.State is Tone.Warn or Tone.Alert);
        var unread = built.Count(l => l.State == Tone.Off && l.Value == "Non lu");
        var value = read == 0 ? "Non lu" : toCheck > 0 ? FrenchText.Integer(toCheck) + " à vérifier" : unread > 0 ? "Rien à signaler sur ce qui est lu" : "Rien à signaler";
        return new PosteSheet("computer.status", "État de la protection", value, FrenchText.Count(read, "contrôle lu", "contrôles lus") + " sur " + FrenchText.Integer(built.Length),
            built.Any(l => l.State == Tone.Alert) ? Tone.Alert : toCheck > 0 ? Tone.Warn : null, built);
    }

    /// <summary>Score, verdict and title of the points (Get-DomeniaBoardHealth, Get-DomeniaHealthPointsTitle, CO-10, DS-05).</summary>
    public static PosteHealth Health(IReadOnlyList<AttentionPoint> all, PosteHealthPolicy policy, string? badge, string? badgeAction)
    {
        ArgumentNullException.ThrowIfNull(all);
        ArgumentNullException.ThrowIfNull(policy);
        var active = all.Where(p => p.Reason is null).ToList();
        var suppressed = all.Where(p => p.Reason is not null).ToImmutableArray();
        var alerts = active.Count(p => p.Level == AttentionLevel.Alert);
        var warnings = active.Count(p => p.Level == AttentionLevel.Warn);
        var information = active.Count(p => p.Level == AttentionLevel.Info);
        int? score = Math.Max(0, 100 - 25 * alerts - 10 * warnings);
        var state = alerts > 0 || score < 60 ? Tone.Alert : warnings > 0 ? Tone.Warn : Tone.Ok;
        var verdict = alerts > 0 ? "Critique" : state == Tone.Alert ? "Dégradé" : state == Tone.Warn ? "À surveiller" : "Bon état";
        var detail = alerts + warnings > 0
            ? string.Join(" · ", new[] { alerts > 0 ? FrenchText.Count(alerts, "critique", "critiques") : null, warnings > 0 ? FrenchText.Integer(warnings) + " à surveiller" : null }.Where(t => t is not null))
            : "Aucun point à vérifier";
        if (badge is not null && alerts + warnings == 0)
        {
            score = null;
            verdict = "Données insuffisantes";
            state = Tone.Off;
            detail = "Aucun problème établi ; contrôles incomplets.";
        }
        var enabledRules = PosteHealthPolicy.Rules.Count(r => policy.Counts(r.Id)) + policy.CustomRules.Count(r => r.Enabled && policy.Counts(r.Id));
        if (enabledRules == 0)
        {
            score = null;
            verdict = "Aucun contrôle activé";
            state = Tone.Off;
            detail = "Activez un contrôle dans les règles de santé.";
        }
        var disabledPoints = suppressed.Count(p => p.Reason!.StartsWith("Règle désactivée", StringComparison.Ordinal) || p.Reason.StartsWith("Alerte personnalisée", StringComparison.Ordinal));
        if (disabledPoints > 0)
        {
            badge = string.Join(" · ", new[] { badge, FrenchText.Count(disabledPoints, "point non compté (règle désactivée)", "points non comptés (règles désactivées)") }.Where(t => t is not null));
        }
        var suspendedRules = policy.Suspensions.Count(s => policy.SuspensionOf(s.RuleId) is not null);
        if (suspendedRules > 0)
        {
            badge = string.Join(" · ", new[] { badge, FrenchText.Count(suspendedRules, "règle suspendue temporairement", "règles suspendues temporairement") }.Where(t => t is not null));
        }
        var notes = ImmutableArray.CreateBuilder<string>();
        foreach (var s in policy.Suspensions.Where(s => policy.SuspensionOf(s.RuleId) is not null))
        {
            notes.Add(RuleName(s.RuleId, policy) + " : suspendue " + s.Text + ".");
        }
        foreach (var rule in PosteHealthPolicy.Rules.Where(r => !policy.IsEnabled(r.Id)))
        {
            notes.Add(rule.Name + " : désactivée.");
        }
        foreach (var rule in policy.CustomRules)
        {
            notes.Add("Alerte personnalisée « " + rule.Name + " »" + (rule.Enabled ? "" : " (désactivée)") + ".");
        }
        if (policy.QueryRules > 0)
        {
            notes.Add(FrenchText.Count(policy.QueryRules, "alerte sur requête enregistrée", "alertes sur requêtes enregistrées") + " : évaluée" + (policy.QueryRules >= 2 ? "s" : "") + " par l’atelier de requêtes, pas sur ce tableau.");
        }
        var pointsCount = alerts + warnings;
        var info = information > 0 ? FrenchText.Count(information, "information", "informations") : null;
        var head = pointsCount > 0 ? FrenchText.Count(pointsCount, "point à vérifier", "points à vérifier")
            : score is null || badge is not null ? "Aucun problème établi" : info is not null ? "Aucun point à vérifier" : "Rien à signaler";
        var title = string.Join(" · ", new[] { head, info }.Where(t => t is not null));
        var sorted = active.OrderBy(p => p.Level).ToImmutableArray();
        return new PosteHealth(score, verdict, state, alerts, warnings, information, title, detail, badge, badgeAction, sorted, suppressed, policy.Thresholds, policy.Origin, notes.ToImmutable());
    }

    private static string RuleName(string id, PosteHealthPolicy policy) =>
        PosteHealthPolicy.Rules.FirstOrDefault(r => r.Id == id)?.Name ?? policy.CustomRules.FirstOrDefault(r => r.Id == id)?.Name ?? id;

    /// <summary>Adds a point; a disabled rule never scores nor lists, what it would flag stays explainable (Domenia 1 point 75).</summary>
    private static void Note(List<AttentionPoint> points, PosteHealthPolicy policy, AttentionLevel level, string text, string rule, PosteRoute? route)
    {
        if (rule.Length > 0 && !policy.IsEnabled(rule))
        {
            if (level != AttentionLevel.Info)
            {
                points.Add(new AttentionPoint(level, text, rule, route, "Règle désactivée dans les règles de santé"));
            }
            return;
        }
        if (rule.Length > 0 && policy.SuspensionOf(rule) is { } suspension)
        {
            // A suspended rule never scores; what it would flag stays explainable (Domenia 1 point 75, Suspensions).
            if (level != AttentionLevel.Info)
            {
                points.Add(new AttentionPoint(level, text, rule, route, "Règle suspendue " + suspension.Text));
            }
            return;
        }
        points.Add(new AttentionPoint(level, text, rule, route, null));
    }

    /// <summary>
    /// Custom alerts of the policy on the measures of this inventory (Domenia 1 Add-DomeniaCustomHealthAttention): free space
    /// of the system volume, days since the last start, used memory. A measure that was not read flags nothing.
    /// </summary>
    private static void CustomPoints(InventorySnapshot inv, ResourceGauges resources, DiskBoard disks, PosteHealthPolicy policy, List<AttentionPoint> points, DateTimeOffset now)
    {
        foreach (var rule in policy.CustomRules)
        {
            double? measure = rule.Measure switch
            {
                "DiskFree" => disks.System?.FreePercent,
                "UptimeDays" => inv.Os?.LastBoot is DateTimeOffset boot ? Math.Floor((now - boot).TotalDays) : null,
                "MemoryUsed" => resources.Memory?.Percent,
                _ => null,
            };
            if (measure is not double value)
            {
                continue;
            }
            var hit = rule.Operator == "LessThan" ? value < rule.Threshold : value > rule.Threshold;
            if (!hit)
            {
                continue;
            }
            var unit = rule.Measure == "UptimeDays" ? " j" : " %";
            var text = rule.Name + " (" + FrenchText.Decimal(value, rule.Measure == "UptimeDays" ? 0 : 1) + unit + (rule.Operator == "LessThan" ? ", seuil inférieur à " : ", seuil supérieur à ") + FrenchText.Decimal(rule.Threshold, 0) + unit + ").";
            if (!rule.Enabled)
            {
                points.Add(new AttentionPoint(rule.Severity, text, rule.Id, null, "Alerte personnalisée désactivée"));
                continue;
            }
            Note(points, policy, rule.Severity, text, rule.Id, null);
        }
    }
}
