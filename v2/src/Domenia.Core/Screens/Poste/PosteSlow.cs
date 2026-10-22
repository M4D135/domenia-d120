using System.Collections.Immutable;

namespace Domenia.Core.Poste;

/// <summary>An action the page proposes beside a finding (navigation or the existing circuit: nothing runs by itself).</summary>
public sealed record SlowAction(string Kind, string Label, string? View, string? Tab, string? Target);

/// <summary>One finding of the triage: level, title, evidence read on the workstation, advice and the useful action.</summary>
public sealed record SlowFinding(string Id, AttentionLevel? Level, string Title, string Evidence, string Advice, SlowAction? Action, int Weight);

/// <summary>Result of poste.slow: the most likely cause first, then every check with its evidence (or « non lu »).</summary>
public sealed record SlowTriage(string Computer, DateTimeOffset At, string Verdict, Tone Tone, ImmutableArray<SlowFinding> Findings, ImmutableArray<SlowFinding> Passed, ImmutableArray<SlowFinding> Unread, string Method);

/// <summary>
/// Triage of a slow workstation (new in Domenia 2, built on the rules of Domenia 1): memory pressure, processor load measured
/// over an interval, system disk, disk type and health, uptime and pending reboot, startup programs, updates or scans in
/// progress, recent crashes and disk errors, network link. Each finding cites its evidence; a check not read is said, never
/// counted as fine. Thresholds come from the health policy. Pure.
/// </summary>
public static class PosteSlow
{
    private static readonly SlowAction RestartAction = new("restart", "Préparer un redémarrage", "intervenir", null, null);
    private static readonly SlowAction ProcessesAction = new("view", "Voir les processus", "inventaire", "processus", null);
    private static readonly SlowAction DiskAction = new("view", "Voir les volumes", "releves", null, "volumes");
    private static readonly SlowAction StartupAction = new("view", "Voir le démarrage automatique", "releves", null, "tasks");
    private static readonly SlowAction EventsAction = new("view", "Voir les événements", "diagnostic", "evenements", null);
    private static readonly SlowAction StorageAction = new("view", "Voir la santé du stockage", "releves", null, "storage");

    public static SlowTriage Triage(string computer, InventorySnapshot data, ProcessesResult? processes, PosteHealthPolicy policy, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(data);
        ArgumentNullException.ThrowIfNull(policy);
        var findings = new List<SlowFinding>();
        var passed = new List<SlowFinding>();
        var unread = new List<SlowFinding>();
        void Add(SlowFinding f)
        {
            if (f.Level is null)
            {
                passed.Add(f);
            }
            else
            {
                findings.Add(f);
            }
        }

        // Memory pressure, with the processes that hold it.
        if (data.Memory is { VisibleKb: > 0 } mem && mem.FreeKb is long free && free >= 0 && free <= mem.VisibleKb)
        {
            var percent = 100d * (mem.VisibleKb!.Value - free) / mem.VisibleKb.Value;
            var heavy = (processes?.Rows ?? []).Where(r => r.WorkingSetBytes is > 0).GroupBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
                .Select(g => (g.Key, Bytes: g.Sum(r => r.WorkingSetBytes!.Value))).OrderByDescending(x => x.Bytes).Take(3)
                .Select(x => x.Key + " " + PosteText.Size(x.Bytes)).ToList();
            var evidence = FrenchText.Percent(percent, 0) + " de " + PosteText.Size(mem.VisibleKb.Value * 1024d) + " utilisés" + (heavy.Count > 0 ? FrenchText.Colon + string.Join(", ", heavy) : "");
            Add(percent >= policy.MemoryUsedWarn
                ? new SlowFinding("memory", AttentionLevel.Alert, "Mémoire saturée", evidence, "Fermez les applications les plus gourmandes ou redémarrez le poste ; au-delà, prévoyez plus de mémoire.", ProcessesAction, 30)
                : percent >= 80
                    ? new SlowFinding("memory", AttentionLevel.Warn, "Mémoire très sollicitée", evidence, "Surveillez les applications ouvertes : le système commence à paginer.", ProcessesAction, 15)
                    : new SlowFinding("memory", null, "Mémoire", evidence, "Pas de pression mémoire au relevé.", null, 0));
            var installed = data.MemoryModules.Where(m => m.CapacityBytes is > 0).Sum(m => m.CapacityBytes!.Value);
            if (installed is > 0 and <= 8L * 1024 * 1024 * 1024)
            {
                findings.Add(new SlowFinding("memory.small", AttentionLevel.Info, "Mémoire installée modeste", PosteText.Size(installed) + " installés", "Avec des applications de visioconférence et un navigateur chargé, 16 Go sont conseillés.", null, 5));
            }
        }
        else
        {
            unread.Add(new SlowFinding("memory", null, "Mémoire", "Non lue", "Mémoire libre non renvoyée : aucune conclusion.", null, 0));
        }

        // Processor load measured over an interval (a single photograph proves nothing).
        if (processes?.TotalCpu is double cpu)
        {
            var top = processes.Rows.Where(r => r.CpuPercent is > 0).Take(3).Select(r => r.Name + " " + FrenchText.Percent(r.CpuPercent!.Value, 0)).ToList();
            var evidence = FrenchText.Percent(cpu, 0) + " mesurés sur " + FrenchText.Decimal(processes.IntervalMs / 1000d, 1) + " s" + (top.Count > 0 ? FrenchText.Colon + string.Join(", ", top) : "");
            var updater = processes.Rows.FirstOrDefault(r => r.CpuPercent is >= 15 && (r.Name.Equals("TiWorker.exe", StringComparison.OrdinalIgnoreCase) || r.Name.Equals("TrustedInstaller.exe", StringComparison.OrdinalIgnoreCase) || r.Name.Equals("msiexec.exe", StringComparison.OrdinalIgnoreCase)));
            var scanner = processes.Rows.FirstOrDefault(r => r.CpuPercent is >= 15 && r.Name.Equals("MsMpEng.exe", StringComparison.OrdinalIgnoreCase));
            Add(cpu >= 85
                ? new SlowFinding("cpu", AttentionLevel.Alert, "Processeur saturé", evidence, "Identifiez le processus en cause ; une mise à jour ou une analyse en cours est passagère.", ProcessesAction, 25)
                : cpu >= 60
                    ? new SlowFinding("cpu", AttentionLevel.Warn, "Processeur très occupé", evidence, "Surveillez le processus le plus actif.", ProcessesAction, 12)
                    : new SlowFinding("cpu", null, "Processeur", evidence, "Charge normale pendant la mesure.", null, 0));
            if (updater is not null)
            {
                findings.Add(new SlowFinding("updates.running", AttentionLevel.Info, "Mises à jour en cours d’installation", updater.Name + " à " + FrenchText.Percent(updater.CpuPercent!.Value, 0), "Lenteur passagère : laissez l’installation se terminer, puis redémarrez si demandé.", null, 8));
            }
            if (scanner is not null)
            {
                findings.Add(new SlowFinding("scan.running", AttentionLevel.Info, "Analyse antivirus en cours", scanner.Name + " à " + FrenchText.Percent(scanner.CpuPercent!.Value, 0), "Lenteur passagère pendant l’analyse.", null, 6));
            }
        }
        else
        {
            unread.Add(new SlowFinding("cpu", null, "Processeur", "Non mesuré", "Deux lectures des processus sont nécessaires pour mesurer la charge.", ProcessesAction, 0));
        }

        // System disk free space and disk type and health.
        var c = data.Volumes.FirstOrDefault(v => string.Equals(v.Id, "C:", StringComparison.OrdinalIgnoreCase));
        if (c is { SizeBytes: > 0, FreeBytes: >= 0 })
        {
            var percent = 100d * c.FreeBytes!.Value / c.SizeBytes!.Value;
            var evidence = PosteText.Size(c.FreeBytes.Value) + " libres sur " + PosteText.Size(c.SizeBytes.Value) + " (" + FrenchText.Percent(percent) + ")";
            var state = policy.DiskState(percent);
            Add(state switch
            {
                Tone.Alert => new SlowFinding("disk.free", AttentionLevel.Alert, "Disque système presque plein", evidence, "Libérez de l’espace (fichiers temporaires, téléchargements, profils anciens) : la pagination et les mises à jour en souffrent.", DiskAction, 25),
                Tone.Warn => new SlowFinding("disk.free", AttentionLevel.Warn, "Peu d’espace sur le disque système", evidence, "Prévoyez un nettoyage avant qu’il ne devienne critique.", DiskAction, 10),
                _ => new SlowFinding("disk.free", null, "Espace disque", evidence, "Espace suffisant sur C:", null, 0),
            });
        }
        else
        {
            unread.Add(new SlowFinding("disk.free", null, "Espace disque", "Non lu", "Volume C: non renvoyé : aucune conclusion.", null, 0));
        }
        var system = data.PhysicalDisks.FirstOrDefault();
        if (system is not null)
        {
            var evidence = system.Name + " · " + PosteLabels.MediaType(system.MediaType) + (system.WearPercent is double w ? " · usure " + FrenchText.Percent(w, 0) : "");
            if (system.Health is 1 or 2 || system.UncorrectedErrors is > 0)
            {
                findings.Add(new SlowFinding("disk.health", AttentionLevel.Alert, "Disque en mauvaise santé", evidence + (system.UncorrectedErrors is long e && e > 0 ? " · " + FrenchText.Count(e, "erreur non corrigée", "erreurs non corrigées") : ""), "Sauvegardez les données et prévoyez le remplacement du disque.", StorageAction, 28));
            }
            else if (system.MediaType == 3)
            {
                findings.Add(new SlowFinding("disk.hdd", AttentionLevel.Warn, "Disque dur mécanique", evidence, "Lenteurs au démarrage et à l’ouverture des applications : un SSD change nettement l’usage.", StorageAction, 14));
            }
            else
            {
                passed.Add(new SlowFinding("disk.health", null, "Santé du disque", evidence, "Disque sain selon le pilote.", null, 0));
            }
        }
        else
        {
            unread.Add(new SlowFinding("disk.health", null, "Santé du disque", "Non lue", "Aucun disque physique renvoyé : aucune conclusion.", null, 0));
        }

        // Uptime and pending reboot.
        if (data.Os?.LastBoot is DateTimeOffset boot)
        {
            var days = (int)(now - boot).TotalDays;
            var evidence = "En service depuis " + PosteText.Duration(now - boot);
            Add(days >= policy.UptimeDays * 2
                ? new SlowFinding("uptime", AttentionLevel.Alert, "Pas de redémarrage depuis longtemps", evidence, "Un redémarrage libère la mémoire et termine les mises à jour en attente.", RestartAction, 18)
                : days >= policy.UptimeDays
                    ? new SlowFinding("uptime", AttentionLevel.Warn, "Redémarrage ancien", evidence, "Proposez un redémarrage différé avec message.", RestartAction, 10)
                    : new SlowFinding("uptime", null, "Dernier démarrage", evidence, "Redémarré récemment.", null, 0));
        }
        else
        {
            unread.Add(new SlowFinding("uptime", null, "Dernier démarrage", "Non lu", "Date de démarrage non renvoyée.", null, 0));
        }
        if (data.PendingReboot is { } reboot)
        {
            Add(reboot.Confirmed.IsEmpty
                ? new SlowFinding("reboot", null, "Redémarrage en attente", reboot.Partial.IsEmpty ? "Aucun indicateur" : "Indices partiels seulement", "Pas d’obligation confirmée.", null, 0)
                : new SlowFinding("reboot", AttentionLevel.Warn, "Redémarrage en attente", "Confirmé par " + string.Join(", ", reboot.Confirmed), "Les mises à jour ne sont pas terminées tant que le poste n’a pas redémarré.", RestartAction, 10));
        }

        // Startup programs outside Microsoft.
        if (!data.Startup.IsEmpty || data.Read(InventoryCategories.Startup))
        {
            var others = data.Startup.Where(s => !s.Microsoft).ToList();
            var evidence = FrenchText.Count(others.Count, "programme hors Microsoft", "programmes hors Microsoft") + " au démarrage" + (others.Count > 0 ? FrenchText.Colon + string.Join(", ", others.Take(4).Select(s => s.Name)) : "");
            Add(others.Count >= 12
                ? new SlowFinding("startup", AttentionLevel.Warn, "Nombreux programmes au démarrage", evidence, "Désactivez avec l’utilisateur les programmes inutiles (Gestionnaire des tâches, onglet Démarrage).", StartupAction, 9)
                : others.Count >= 8
                    ? new SlowFinding("startup", AttentionLevel.Info, "Programmes au démarrage", evidence, "À surveiller si l’ouverture de session est lente.", StartupAction, 4)
                    : new SlowFinding("startup", null, "Démarrage automatique", evidence, "Peu de programmes au démarrage.", null, 0));
        }

        // Recent crashes and disk errors (System and Application logs, 72 h).
        if (data.Read(InventoryCategories.Events))
        {
            var recent = data.SystemEvents.Where(e => e.At >= now.AddHours(-72)).ToList();
            var crashes = recent.Count(e => e.Id is 1000 or 1001 or 41 or 6008);
            var disk = recent.Count(e => e.Provider.Equals("disk", StringComparison.OrdinalIgnoreCase) && e.Id is 7 or 11 or 51 or 153);
            if (disk > 0)
            {
                findings.Add(new SlowFinding("events.disk", AttentionLevel.Alert, "Erreurs disque récentes", FrenchText.Count(disk, "erreur disque", "erreurs disque") + " sur 72 h (7, 11, 51, 153)", "Signe d’un disque fatigué ou d’un câble défaillant : sauvegardez et vérifiez.", EventsAction, 22));
            }
            Add(crashes >= 3
                ? new SlowFinding("events.crash", AttentionLevel.Warn, "Plantages répétés", FrenchText.Count(crashes, "plantage ou arrêt inattendu", "plantages ou arrêts inattendus") + " sur 72 h", "Relevez l’application en cause dans les événements.", EventsAction, 12)
                : new SlowFinding("events.crash", null, "Plantages", crashes == 0 ? "Aucun plantage sur 72 h" : FrenchText.Count(crashes, "plantage", "plantages") + " sur 72 h", "Pas de plantages répétés.", null, 0));
        }
        else
        {
            unread.Add(new SlowFinding("events", null, "Journaux d’événements", "Non lus", "Lecture des journaux non tentée.", EventsAction, 0));
        }

        // Network link of the wired adapter.
        var link = data.Network.Where(n => n.Physical && n.Status == 2).OrderByDescending(n => n.SpeedBitsPerSecond).FirstOrDefault();
        if (link is not null)
        {
            var evidence = link.Name + " · " + PosteLabels.Adapter(link.Status, link.SpeedBitsPerSecond);
            Add(link.SpeedBitsPerSecond is long s && s > 0 && s <= 100_000_000 && !link.Wireless
                ? new SlowFinding("network", AttentionLevel.Warn, "Lien réseau lent", evidence, "Lien filaire à 100 Mb/s ou moins : vérifiez le câble, la prise ou le port du commutateur.", null, 8)
                : new SlowFinding("network", null, "Lien réseau", evidence, link.Wireless ? "Liaison Wi-Fi : le débit réel dépend du signal." : "Lien filaire rapide.", null, 0));
        }

        var ordered = findings.OrderBy(f => f.Level).ThenByDescending(f => f.Weight).ToImmutableArray();
        var main = ordered.FirstOrDefault(f => f.Level is AttentionLevel.Alert or AttentionLevel.Warn);
        string verdict;
        Tone tone;
        if (main is null)
        {
            verdict = unread.Count > 0
                ? "Aucune cause de lenteur établie sur ce qui a été lu ; " + FrenchText.Count(unread.Count, "contrôle n’a", "contrôles n’ont") + (unread.Count >= 2 ? " pas pu être lus." : " pas pu être lu.")
                : "Aucune cause de lenteur établie : mémoire, processeur, disque et redémarrage sont normaux. Faites décrire la lenteur à l’utilisateur (application, moment).";
            tone = unread.Count > 0 ? Tone.Off : Tone.Ok;
        }
        else
        {
            var others = ordered.Count(f => f.Level is AttentionLevel.Alert or AttentionLevel.Warn) - 1;
            verdict = "Cause la plus probable : " + main.Title.ToLower(System.Globalization.CultureInfo.GetCultureInfo("fr-FR")) + " (" + main.Evidence + ")." + (others > 0 ? " " + FrenchText.Count(others, "autre piste", "autres pistes") + " à vérifier." : "");
            tone = main.Level == AttentionLevel.Alert ? Tone.Alert : Tone.Warn;
        }
        return new SlowTriage(computer, now, verdict, tone, ordered, [.. passed], [.. unread],
            "Lecture rapide du poste (mémoire, deux lectures des processus, disques, démarrage, journaux de 72 h, réseau) ; seuils des règles de santé de Domenia 1. Aucune action n’est lancée.");
    }
}
