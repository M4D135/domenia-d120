using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Poste;

/// <summary>
/// The fifteen interpreted readings of a workstation (Domenia 1 Domenia-Readings.Model points 81 to 100): stored probe data
/// turned into explainable facts. A value that was not read stays unknown, a computed value is an estimate, an absent
/// provider is never a healthy state. Pure: the current time, the zone, the policy and the BIOS book are parameters.
/// </summary>
public static class PosteReadings
{
    /// <summary>A stored reading older than this is greyed (Domenia 1 FI-04).</summary>
    public const int StaleAfterSeconds = 7 * 86400;

    /// <summary>Catalog of the readings: id, title, icon and the probes they read (Get-DomeniaReadingCatalog).</summary>
    public static ImmutableArray<(string Id, string Title, string Icon, ImmutableArray<string> Probes)> Catalog { get; } =
    [
        ("memory", "Mémoire : capacité et occupation", "chip", ["hw.memorymodules", "hw.memoryarrays", "hw.memoryusage"]),
        ("volumes", "Volumes et prévision de saturation", "disk", ["disk.volumes"]),
        ("storage", "Santé du stockage", "disk", ["disk.physical", "disk.reliability"]),
        ("battery", "Batteries", "zap", ["hw.batteries", "hw.batterystatic", "hw.batteryfullcharge", "hw.batterycycles"]),
        ("bios", "BIOS et micrologiciel", "chip", ["hw.biosdetails", "hw.computersystem"]),
        ("processor", "Processeurs et virtualisation", "chip", ["hw.processors", "hw.computersystem"]),
        ("displays", "Écrans, raccordements et stations d’accueil", "monitor", ["hw.monitors", "hw.monitorconnections", "hw.dockhints"]),
        ("network", "Interfaces réseau", "wifi", ["net.interfaces", "net.configurations"]),
        ("devices", "Imprimantes et périphériques en erreur", "alert", ["soft.printerdetails", "hw.deviceerrors"]),
        ("services", "Services et profil attendu", "settings", ["soft.servicedetails"]),
        ("tasks", "Tâches planifiées et démarrage automatique", "clock", ["soft.scheduledtasks", "soft.startupdetails"]),
        ("antivirus", "Antivirus et Defender", "shield", ["sec.avproducts", "sec.defenderdetails"]),
        ("firewall", "Pare-feu et profils réseau", "shield", ["sec.firewallprofiles", "net.connectionprofiles"]),
        ("protection", "BitLocker, TPM et sécurité du démarrage", "lock", ["sec.bitlockervolumes", "sec.tpmdetails", "sec.deviceguard"]),
        ("processes", "Processus au relevé", "activity", ["soft.processdetails"]),
    ];

    public static string ProbeStateLabel(ProbeState state) => state switch
    {
        ProbeState.Read => "Lu",
        ProbeState.Partial => "Lu en partie",
        ProbeState.Refused => "Refusé",
        ProbeState.Absent => "Fournisseur absent",
        ProbeState.Failed => "En échec",
        _ => "Non lu",
    };

    public static ReadingsResult Build(ProbeStore store, PosteHealthPolicy policy, ImmutableArray<BiosReference> book, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(zone);
        var statuses = store.Probes.ToDictionary(p => p.ProbeId, StringComparer.Ordinal);
        var views = ImmutableArray.CreateBuilder<ReadingView>();
        int fresh = 0, aging = 0, stale = 0, unread = 0;
        foreach (var (id, title, icon, probes) in Catalog)
        {
            var probeViews = probes.Select(p =>
            {
                var info = ProbeCatalog.Find(p);
                var status = statuses.GetValueOrDefault(p) ?? new ProbeStatus(p, ProbeState.NotRead, null, null, null, 0);
                return new ReadingProbe(p, info?.Name ?? p, status.State, ProbeStateLabel(status.State), status.LastSuccess, status.LastAttempt, status.Error);
            }).ToImmutableArray();
            var read = probeViews.Where(p => p.State is ProbeState.Read or ProbeState.Partial).ToList();
            DateTimeOffset? at = read.Count == 0 ? null : read.Min(p => p.LastSuccess);
            var facts = ImmutableArray.CreateBuilder<PosteFact>();
            VolumeForecast? forecast = null;
            BiosCompare? bios = null;
            var data = store.Data;
            if (read.Count == 0 || data is null)
            {
                foreach (var p in probeViews)
                {
                    facts.Add(SourceFact(p, ProbeCatalog.Find(p.Id)?.Class ?? p.Id));
                }
            }
            else
            {
                var stamp = at ?? data.CollectedAt;
                switch (id)
                {
                    case "memory":
                        Memory(data, stamp, facts);
                        break;
                    case "volumes":
                        forecast = Volumes(data, store.SystemVolumeHistory, policy, stamp, zone, facts);
                        break;
                    case "storage":
                        Storage(data, stamp, facts);
                        break;
                    case "battery":
                        Battery(data, stamp, facts);
                        break;
                    case "bios":
                        bios = Bios(data, book, stamp, zone, facts);
                        break;
                    case "processor":
                        Processor(data, stamp, facts);
                        break;
                    case "displays":
                        Displays(data, store.MonitorHistory, store.DockHints, stamp, zone, facts);
                        break;
                    case "network":
                        Network(data, stamp, facts);
                        break;
                    case "devices":
                        Devices(data, stamp, facts);
                        break;
                    case "services":
                        Services(data, stamp, facts);
                        break;
                    case "tasks":
                        Tasks(data, stamp, zone, facts);
                        break;
                    case "antivirus":
                        Antivirus(data, stamp, facts);
                        break;
                    case "firewall":
                        Firewall(data, stamp, facts);
                        break;
                    case "protection":
                        Protection(data, stamp, facts);
                        break;
                    default:
                        Processes(data, stamp, facts);
                        break;
                }
                foreach (var p in probeViews.Where(p => p.State is not (ProbeState.Read or ProbeState.Partial)))
                {
                    facts.Add(SourceFact(p, ProbeCatalog.Find(p.Id)?.Class ?? p.Id));
                }
            }
            Tone state;
            string label;
            if (at is not DateTimeOffset seen)
            {
                state = Tone.Off;
                label = probeViews.Any(p => p.State == ProbeState.Refused) ? "Lecture refusée" : "Non lu";
                unread++;
            }
            else if (now - seen > TimeSpan.FromSeconds(StaleAfterSeconds))
            {
                state = Tone.Alert;
                label = "Périmé · " + PosteText.Age(seen, now);
                stale++;
            }
            else if (now - seen > TimeSpan.FromSeconds(StaleAfterSeconds / 2))
            {
                state = Tone.Warn;
                label = "Lu " + PosteText.Age(seen, now);
                aging++;
            }
            else
            {
                state = Tone.Ok;
                label = "Lu " + PosteText.Age(seen, now);
                fresh++;
            }
            views.Add(new ReadingView(id, title, icon, state, label, at, StaleAfterSeconds, facts.ToImmutable(), probeViews, forecast, bios));
        }
        var summary = FrenchText.Count(fresh, "lecture récente", "lectures récentes") + ", " + FrenchText.Integer(aging) + " vieillissante(s), "
            + FrenchText.Integer(stale) + " périmée(s), " + FrenchText.Integer(unread) + " non lue(s) ; relevés de la base locale, aucune requête au poste.";
        return new ReadingsResult(store.Computer, store.CollectedAt, views.ToImmutable(), ProbeCatalog.Probes, summary, fresh, aging, stale, unread, StaleAfterSeconds);
    }

    private static PosteFact SourceFact(ReadingProbe probe, string source) => probe.State switch
    {
        ProbeState.Refused => PosteText.Fact(probe.Name, "Lecture refusée", FactState.Refused, source, "Un refus ne dit rien de l’état du poste.", at: probe.LastAttempt),
        ProbeState.Absent => PosteText.Fact(probe.Name, "Fournisseur absent sur ce poste", FactState.Unavailable, source, "Classe ou espace de noms absent : ce n’est ni un état sain ni une panne.", at: probe.LastAttempt),
        ProbeState.Failed => PosteText.Fact(probe.Name, "Lecture en échec" + (probe.Error is null ? "" : FrenchText.Colon + PosteText.Flat(probe.Error, 120)), FactState.Unavailable, source, "Aucune conclusion.", at: probe.LastAttempt),
        _ => PosteText.Fact(probe.Name, "Non lu", FactState.Unknown, source, "Aucun relevé enregistré pour cette sonde : « Actualiser les sondes » le lit une fois.", at: probe.LastAttempt),
    };

    private static void Memory(InventorySnapshot d, DateTimeOffset at, ImmutableArray<PosteFact>.Builder facts)
    {
        long? installed = null;
        if (d.MemoryModules.IsEmpty)
        {
            facts.Add(PosteText.Fact("Mémoire installée (barrettes)", "Aucune barrette exposée par le firmware", FactState.Unknown, "Win32_PhysicalMemory",
                "Fréquent en machine virtuelle : la capacité matérielle reste inconnue ; la mémoire visible par Windows est donnée à part.", at: at));
        }
        else
        {
            var unknown = d.MemoryModules.Count(m => m.CapacityBytes is not > 0);
            var total = d.MemoryModules.Where(m => m.CapacityBytes is > 0).Sum(m => m.CapacityBytes!.Value);
            var slots = string.Join(" ; ", d.MemoryModules.Where(m => m.CapacityBytes is > 0).Select(m => m.Slot + " " + PosteText.Size(m.CapacityBytes!.Value) + (m.SpeedMhz is int mhz ? " " + FrenchText.Integer(mhz) + " MHz" : "")));
            if (unknown > 0)
            {
                facts.Add(PosteText.Fact("Mémoire installée (barrettes)", "Au moins " + PosteText.Size(total) + " (" + FrenchText.Integer(d.MemoryModules.Length) + " barrette(s) lue(s), " + FrenchText.Integer(unknown) + " sans capacité déclarée)",
                    FactState.Estimated, "Win32_PhysicalMemory", "Total minimal : une barrette sans capacité n’est pas comptée.", at: at));
            }
            else
            {
                installed = total;
                facts.Add(PosteText.Fact("Mémoire installée (barrettes)", PosteText.Size(total) + " en " + FrenchText.Count(d.MemoryModules.Length, "barrette", "barrettes") + FrenchText.Colon + slots, FactState.Observed, "Win32_PhysicalMemory", "Capacité déclarée par le firmware (SMBIOS).", at: at, tone: Tone.Info));
            }
        }
        if (d.MemoryArray is { } array)
        {
            if (array.Slots is not int slotCount || slotCount <= 0)
            {
                facts.Add(PosteText.Fact("Emplacements mémoire", "Nombre d’emplacements non déclaré", FactState.Unknown, "Win32_PhysicalMemoryArray", "Table SMBIOS du firmware.", at: at));
            }
            else if (d.MemoryModules.Length > slotCount)
            {
                facts.Add(PosteText.Fact("Emplacements mémoire", FrenchText.Integer(d.MemoryModules.Length) + " barrette(s) pour " + FrenchText.Integer(slotCount) + " emplacement(s) déclaré(s)", FactState.Unknown, "Win32_PhysicalMemoryArray", "Tables du firmware incohérentes : aucun emplacement libre n’est déduit.", at: at));
            }
            else
            {
                facts.Add(PosteText.Fact("Emplacements mémoire", FrenchText.Count(slotCount, "emplacement", "emplacements") + FrenchText.Colon + FrenchText.Integer(d.MemoryModules.Length) + " occupé(s), " + FrenchText.Integer(slotCount - d.MemoryModules.Length) + " libre(s)",
                    FactState.Observed, "Win32_PhysicalMemoryArray, Win32_PhysicalMemory", "Table SMBIOS du firmware ; une mémoire soudée compte comme un emplacement occupé.", at: at, tone: Tone.Info));
            }
            facts.Add(array.MaxCapacityBytes is long max && max > 0
                ? PosteText.Fact("Capacité maximale déclarée", PosteText.Size(max), FactState.Observed, "Win32_PhysicalMemoryArray", "Déclaration du firmware : ce n’est pas une garantie de compatibilité avec une barrette donnée.", at: at, tone: Tone.Info)
                : PosteText.Fact("Capacité maximale déclarée", "Non déclarée par le firmware", FactState.Unknown, "Win32_PhysicalMemoryArray", null, at: at));
        }
        if (d.Memory is { VisibleKb: > 0 } usage)
        {
            var visible = usage.VisibleKb!.Value;
            var reserved = installed is long inst && inst > visible * 1024 ? PosteText.Size(inst - visible * 1024) + " réservés au matériel ou au firmware" : null;
            facts.Add(PosteText.Fact("Mémoire visible par Windows", PosteText.Size(visible * 1024d), FactState.Observed, "Win32_OperatingSystem", "Part de la mémoire installée que Windows peut utiliser.", reserved, at, Tone.Info));
            if (usage.FreeKb is long free && free >= 0 && free <= visible)
            {
                var percent = 100d * (visible - free) / visible;
                facts.Add(PosteText.Fact("Mémoire utilisée au relevé", FrenchText.Percent(percent) + " (" + PosteText.Size((visible - free) * 1024d) + " sur " + PosteText.Size(visible * 1024d) + ")", FactState.Observed, "Win32_OperatingSystem",
                    "Mesure instantanée datée : elle ne décrit pas l’usage habituel du poste.", percent >= 90 ? "Pression mémoire au moment du relevé : à confirmer par plusieurs relevés avant de conclure." : null, at, percent >= 90 ? Tone.Warn : Tone.Ok));
            }
        }
    }

    /// <summary>
    /// Linear trend of the free space of one volume (Get-DomeniaVolumeSaturationForecast): no figure without 4 samples over 14
    /// days, one constant size, a falling trend (more than 1 Mo a day) and a fit of at least 0.6; horizon of 730 days.
    /// </summary>
    public static VolumeForecast Forecast(string volume, IReadOnlyList<VolumeSample> samples, TimeZoneInfo zone, int minSamples = 4, int minSpanDays = 14, double minFit = 0.6, int horizonDays = 730)
    {
        ArgumentNullException.ThrowIfNull(samples);
        ArgumentNullException.ThrowIfNull(zone);
        var sorted = samples.Where(s => s.SizeBytes > 0 && s.FreeBytes >= 0 && s.FreeBytes <= s.SizeBytes).OrderBy(s => s.At).ToImmutableArray();
        DateTimeOffset? first = sorted.IsEmpty ? null : sorted[0].At;
        DateTimeOffset? last = sorted.IsEmpty ? null : sorted[^1].At;
        var span = first is null ? 0 : (last!.Value - first.Value).TotalDays;
        long? size = sorted.IsEmpty ? null : sorted[^1].SizeBytes;
        VolumeForecast Result(string status, string text, Tone tone, double? slope = null, double? intercept = null, double? fit = null, double? days = null, DateTimeOffset? saturation = null) =>
            new(volume, status, sorted.Length, Math.Round(span, 1), first, last, slope, intercept, fit, days, saturation, size, sorted, text, tone);
        var spanText = FrenchText.Integer((long)Math.Floor(span));
        if (sorted.Length < minSamples || span < minSpanDays)
        {
            return Result("Insufficient", "Aucune prévision : " + FrenchText.Count(sorted.Length, "relevé", "relevés") + " sur " + spanText + " jour(s) ; il en faut au moins 4 sur 14 jours.", Tone.Off);
        }
        if (sorted.Select(s => Math.Round(s.SizeBytes / 1048576d)).Distinct().Count() > 1)
        {
            return Result("SizeChanged", "Aucune prévision : la taille du volume a changé pendant la période.", Tone.Off);
        }
        double n = sorted.Length, sx = 0, sy = 0, sxx = 0, sxy = 0, syy = 0;
        foreach (var s in sorted)
        {
            var x = (s.At - first!.Value).TotalDays;
            double y = s.FreeBytes;
            sx += x;
            sy += y;
            sxx += x * x;
            sxy += x * y;
            syy += y * y;
        }
        var denominator = n * sxx - sx * sx;
        if (denominator <= 0)
        {
            return Result("Insufficient", "Aucune prévision : relevés trop rapprochés.", Tone.Off);
        }
        var covariance = n * sxy - sx * sy;
        var slope = covariance / denominator;
        var intercept = (sy - slope * sx) / n;
        var variance = n * syy - sy * sy;
        if (slope >= -1048576d || variance <= 0)
        {
            return Result("Stable", "Pas de baisse de l’espace libre sur " + FrenchText.Count(sorted.Length, "relevé", "relevés") + " (" + spanText + " jours).", Tone.Ok, slope, intercept);
        }
        var fit = covariance * covariance / (denominator * variance);
        if (fit < minFit)
        {
            return Result("Irregular", "Aucune prévision : évolution irrégulière sur " + FrenchText.Count(sorted.Length, "relevé", "relevés") + " (ajustement " + FrenchText.Decimal(fit, 2) + ").", Tone.Off, slope, intercept, fit);
        }
        var daysLeft = sorted[^1].FreeBytes / -slope;
        if (daysLeft > horizonDays)
        {
            return Result("BeyondHorizon", "Baisse lente : au rythme observé, pas de saturation avant deux ans (" + FrenchText.Count(sorted.Length, "relevé", "relevés") + " sur " + spanText + " jours).", Tone.Ok, slope, intercept, fit, daysLeft);
        }
        var saturation = last!.Value.AddDays(daysLeft);
        var text = "Saturation estimée vers le " + PosteText.LocalDate(saturation, zone) + " (baisse moyenne de " + PosteText.Size(-slope) + " par jour sur " + FrenchText.Count(sorted.Length, "relevé", "relevés")
            + ", du " + PosteText.LocalDate(first!.Value, zone) + " au " + PosteText.LocalDate(last.Value, zone) + ")";
        return Result("Forecast", text, daysLeft < 30 ? Tone.Alert : Tone.Warn, slope, intercept, fit, daysLeft, saturation);
    }

    private static VolumeForecast? Volumes(InventorySnapshot d, ImmutableArray<VolumeSample> history, PosteHealthPolicy policy, DateTimeOffset at, TimeZoneInfo zone, ImmutableArray<PosteFact>.Builder facts)
    {
        VolumeForecast? forecast = null;
        if (d.Volumes.IsEmpty)
        {
            facts.Add(PosteText.Fact("Volumes locaux", "Aucun volume fixe renvoyé", FactState.Unknown, "Win32_LogicalDisk", null, at: at));
            return null;
        }
        foreach (var v in d.Volumes)
        {
            var name = "Volume " + v.Id + (string.IsNullOrWhiteSpace(v.Label) ? "" : " (" + v.Label + ")");
            if (v.SizeBytes is not long size || v.FreeBytes is not long free || size <= 0 || free < 0 || free > size)
            {
                facts.Add(PosteText.Fact(name, "Taille ou espace libre absent ou incohérent", FactState.Unknown, "Win32_LogicalDisk", null, at: at));
                continue;
            }
            var percent = 100d * free / size;
            var hint = percent < policy.DiskFreeAlert ? "Espace critique : les mises à jour et les profils peuvent échouer." : percent < policy.DiskFreeWarn ? "Espace faible : à surveiller." : null;
            facts.Add(PosteText.Fact(name, PosteText.Size(free) + " libres sur " + PosteText.Size(size) + " (" + FrenchText.Percent(percent) + ")" + (string.IsNullOrWhiteSpace(v.FileSystem) ? "" : " · " + v.FileSystem),
                FactState.Observed, "Win32_LogicalDisk", "Espace libre au relevé.", hint, at, policy.DiskState(percent)));
            if (string.Equals(v.Id, "C:", StringComparison.OrdinalIgnoreCase))
            {
                var samples = history.ToList();
                if (samples.Count == 0 || samples.Max(s => s.At) < at)
                {
                    samples.Add(new VolumeSample(at, size, free));
                }
                forecast = Forecast(v.Id, samples, zone);
                facts.Add(PosteText.Fact("Prévision de saturation de " + v.Id, forecast.Text, forecast.Status is "Forecast" or "Stable" or "BeyondHorizon" ? FactState.Estimated : FactState.Unknown, "Historique des relevés",
                    forecast.Status == "Forecast" ? "Projection linéaire : une installation ou un nettoyage change la tendance." : "Relevés enregistrés de ce poste uniquement (au plus un toutes les 6 h).",
                    forecast.DaysLeft is double days && days < 30 && forecast.Status == "Forecast" ? "Saturation possible dans moins de 30 jours : libérer de l’espace ou agrandir le volume." : null, at, forecast.Tone));
            }
        }
        return forecast;
    }

    private static void Storage(InventorySnapshot d, DateTimeOffset at, ImmutableArray<PosteFact>.Builder facts)
    {
        if (d.PhysicalDisks.IsEmpty)
        {
            facts.Add(PosteText.Fact("Disques physiques", "Aucun disque renvoyé par le fournisseur de stockage", FactState.Unknown, "MSFT_PhysicalDisk", "Aucun disque n’est déclaré sain ou défaillant sans lecture.", at: at));
            return;
        }
        foreach (var disk in d.PhysicalDisks)
        {
            var describe = string.Join(" · ", new[] { PosteLabels.MediaType(disk.MediaType), disk.BusType is int b ? "bus " + PosteLabels.BusType(b) : "", disk.SizeBytes is long s && s > 0 ? PosteText.Size(s) : "" }.Where(t => t.Length > 0));
            var limit = disk.BusType is 14 or 15 ? "Disque virtuel : la santé du support physique n’est pas visible depuis ce système."
                : disk.BusType is 8 or 16 ? "Volume RAID ou espace de stockage : la santé des disques membres n’est pas détaillée ici." : "État rapporté par le pilote de stockage.";
            facts.Add(disk.Health switch
            {
                0 => PosteText.Fact(disk.Name, "Sain selon le pilote · " + describe, FactState.Observed, "MSFT_PhysicalDisk", limit, at: at, tone: Tone.Ok),
                1 => PosteText.Fact(disk.Name, "Avertissement · " + describe, FactState.Observed, "MSFT_PhysicalDisk", limit, "Le pilote signale un problème : sauvegarder puis vérifier le disque.", at, Tone.Warn),
                2 => PosteText.Fact(disk.Name, "Défaillant · " + describe, FactState.Observed, "MSFT_PhysicalDisk", limit, "Disque déclaré défaillant : sauvegarder les données et prévoir son remplacement.", at, Tone.Alert),
                _ => PosteText.Fact(disk.Name, "État de santé inconnu · " + describe, FactState.Unknown, "MSFT_PhysicalDisk", limit + " Un état inconnu n’est pas un disque sain.", at: at),
            });
            var parts = new List<string>
            {
                disk.WearPercent is double wear ? "usure " + FrenchText.Percent(wear, 0) : "usure non exposée",
                disk.TemperatureCelsius is double t && t > 0 ? FrenchText.Decimal(t, 0) + " °C" : "température non exposée",
                disk.PowerOnHours is long h ? FrenchText.Integer(h) + " h de fonctionnement" : "durée de fonctionnement non exposée",
                disk.UncorrectedErrors is long e ? FrenchText.Count(e, "erreur non corrigée", "erreurs non corrigées") : "erreurs non corrigées non exposées",
            };
            var hints = new List<string>();
            if (disk.UncorrectedErrors is > 0)
            {
                hints.Add("Erreurs non corrigées signalées : sauvegarder et vérifier le disque.");
            }
            if (disk.WearPercent is >= 90)
            {
                hints.Add("Usure déclarée élevée : prévoir le remplacement.");
            }
            facts.Add(PosteText.Fact("Compteurs de fiabilité de " + disk.Name, string.Join(" · ", parts), FactState.Observed, "MSFT_StorageReliabilityCounter", "Valeurs du pilote ; une valeur non exposée reste inconnue.",
                hints.Count == 0 ? null : string.Join(" ", hints), at, hints.Count == 0 ? Tone.Info : Tone.Warn));
        }
    }

    private static void Battery(InventorySnapshot d, DateTimeOffset at, ImmutableArray<PosteFact>.Builder facts)
    {
        if (d.Batteries.IsEmpty)
        {
            facts.Add(PosteText.Fact("Batteries", "Aucune batterie déclarée", FactState.Observed, "Win32_Battery", "Poste fixe, ou batterie non exposée par le firmware.", at: at, tone: Tone.Info));
            return;
        }
        foreach (var b in d.Batteries)
        {
            facts.Add(PosteText.Fact("Batterie " + b.Name, (b.ChargePercent is int c ? "charge " + FrenchText.Integer(c) + " %" : "charge non renseignée") + (b.Status is int s ? " · " + PosteLabels.BatteryStatus(s) : ""),
                FactState.Observed, "Win32_Battery", "Valeurs au relevé ; la charge change en continu.", at: at, tone: Tone.Info));
            const string WearLimit = "Usure estimée = 1 − capacité à pleine charge / capacité nominale ; la calibration de la batterie fait varier ce calcul.";
            if (b.DesignedCapacity is long design && b.FullChargeCapacity is long full && design > 0 && full > 0)
            {
                if (full > design * 1.05)
                {
                    facts.Add(PosteText.Fact("Usure de la batterie " + b.Name, "Capacité à pleine charge (" + FrenchText.Integer(full) + " mWh) supérieure à la nominale (" + FrenchText.Integer(design) + " mWh) : usure non calculable",
                        FactState.Unknown, "root\\wmi", "Valeur de calibration ou unités différentes : aucune usure n’est déduite.", at: at));
                }
                else
                {
                    var wear = Math.Max(0, 100d * (1 - (double)full / design));
                    facts.Add(PosteText.Fact("Usure de la batterie " + b.Name, FrenchText.Percent(wear, 0) + " (" + FrenchText.Integer(full) + " sur " + FrenchText.Integer(design) + " mWh)", FactState.Estimated, "root\\wmi", WearLimit,
                        wear >= 40 ? "Usure de 40 % ou plus : autonomie réduite, remplacement à prévoir." : null, at, wear >= 40 ? Tone.Warn : Tone.Ok));
                }
            }
            else
            {
                facts.Add(PosteText.Fact("Usure de la batterie " + b.Name, "Non calculable (capacités non exposées)", FactState.Unknown, "root\\wmi", WearLimit, at: at));
            }
            facts.Add(b.Cycles is int cycles && cycles > 0
                ? PosteText.Fact("Cycles de charge", FrenchText.Integer(cycles), FactState.Observed, "BatteryCycleCount", null, at: at, tone: Tone.Info)
                : PosteText.Fact("Cycles de charge", "Non renseigné", FactState.Unknown, "BatteryCycleCount", "Zéro est traité comme non renseigné, jamais comme une batterie neuve.", at: at));
        }
    }

    private static BiosCompare? Bios(InventorySnapshot d, ImmutableArray<BiosReference> book, DateTimeOffset at, TimeZoneInfo zone, ImmutableArray<PosteFact>.Builder facts)
    {
        if (d.Bios is not { } bios)
        {
            facts.Add(PosteText.Fact("BIOS", "Non lu", FactState.Unknown, "Win32_BIOS", null, at: at));
            return null;
        }
        facts.Add(PosteText.Fact("Version du BIOS", bios.Version + (bios.ReleaseDate is DateTimeOffset r ? " du " + PosteText.LocalDate(r, zone) : "") + (bios.SmbiosVersion is null ? "" : " · SMBIOS " + bios.SmbiosVersion),
            FactState.Observed, "Win32_BIOS", "Une date ancienne ne prouve pas une vulnérabilité.", at: at, tone: Tone.Info));
        if (d.System is not { } system)
        {
            return null;
        }
        facts.Add(PosteText.Fact("Modèle", PosteText.Model(system.Manufacturer, system.Model), FactState.Observed, "Win32_ComputerSystem", null, at: at, tone: Tone.Info));
        var reference = BiosReferences.Find(book, system.Manufacturer, system.Model);
        var result = reference is null ? "Unknown" : BiosReferences.Compare(bios.Version, reference.Version);
        var (text, tone) = result switch
        {
            "Equal" => ("Version approuvée pour ce modèle.", Tone.Ok),
            "Older" => ("Plus ancienne que la version approuvée (" + reference!.Version + ") : mise à jour à prévoir.", Tone.Warn),
            "Newer" => ("Plus récente que la version approuvée (" + reference!.Version + ") : approuver cette version si elle est validée.", Tone.Info),
            "Different" => ("Différente de la version approuvée (" + reference!.Version + ") : formats non ordonnables, à vérifier.", Tone.Warn),
            _ => ("Aucune référence approuvée pour ce modèle : aucune conclusion sur la version ni la date.", Tone.Off),
        };
        facts.Add(PosteText.Fact("Référence du modèle", text, reference is null ? FactState.Unknown : FactState.Observed, "Références BIOS locales du domaine", "Réglage local : aucune action sur le poste.", at: at, tone: tone));
        return new BiosCompare(system.Manufacturer, system.Model, bios.Version, reference?.Version, reference?.ApprovedAt, result, text, tone, result != "Equal", reference is not null);
    }

    private static void Processor(InventorySnapshot d, DateTimeOffset at, ImmutableArray<PosteFact>.Builder facts)
    {
        foreach (var cpu in d.Processors)
        {
            var caps = new List<string>();
            if (cpu.VirtualizationFirmware is bool v)
            {
                caps.Add("virtualisation " + (v ? "activée" : "désactivée") + " dans le micrologiciel");
            }
            if (cpu.Slat is bool slat)
            {
                caps.Add("SLAT " + (slat ? "présent" : "absent"));
            }
            facts.Add(PosteText.Fact(cpu.Name.Trim(), (cpu.Architecture ?? "architecture non lue") + " · " + FrenchText.Count(cpu.Cores ?? 0, "cœur", "cœurs") + ", " + FrenchText.Count(cpu.LogicalProcessors ?? 0, "processeur logique", "processeurs logiques")
                + (caps.Count > 0 ? " · " + string.Join(", ", caps) : ""), FactState.Observed, "Win32_Processor", "Capacités déclarées : elles ne prouvent pas qu’un hyperviseur est exécuté.", at: at, tone: Tone.Info));
            if (cpu.LoadPercent is int load)
            {
                facts.Add(PosteText.Fact("Charge au relevé", FrenchText.Integer(load) + " %", FactState.Observed, "Win32_Processor", "Mesure instantanée datée, pas un usage habituel.", load >= 90 ? "Charge élevée au relevé : à confirmer par la mesure des processus." : null, at, load >= 90 ? Tone.Warn : Tone.Ok));
            }
        }
        var platform = d.System?.Hypervisor ?? PosteLabels.VirtualPlatform(d.System?.Manufacturer, d.System?.Model);
        facts.Add(platform is null
            ? PosteText.Fact("Machine physique ou virtuelle", "Physique (estimation)", FactState.Estimated, "Win32_ComputerSystem", "Aucune signature d’hyperviseur dans le modèle : une signature masquée reste possible.", at: at, tone: Tone.Info)
            : PosteText.Fact("Machine physique ou virtuelle", "Virtuelle (" + platform + ", estimation)", FactState.Estimated, "Win32_ComputerSystem", "Estimation par la signature du modèle, jamais une preuve.", at: at, tone: Tone.Info));
    }

    private static void Displays(InventorySnapshot d, ImmutableArray<MonitorChange> history, ImmutableArray<string> dockHints, DateTimeOffset at, TimeZoneInfo zone, ImmutableArray<PosteFact>.Builder facts)
    {
        if (d.Displays.IsEmpty)
        {
            facts.Add(PosteText.Fact("Écrans", "Aucun écran identifié par EDID", FactState.Unknown, "WmiMonitorID", "EDID absent, moniteur virtuel ou session à distance : aucun écran n’est déduit.", at: at));
        }
        foreach (var m in d.Displays)
        {
            facts.Add(PosteText.Fact(m.Name, string.Join(" · ", new[] { m.Manufacturer, m.Product, m.Serial is null ? null : "n° " + m.Serial, m.Year is int y ? y.ToString(CultureInfo.InvariantCulture) : null, (m.Internal ? "interne" : "externe") + " (" + m.Connection + ")" }.Where(t => !string.IsNullOrEmpty(t))),
                FactState.Observed, "WmiMonitorID, WmiMonitorConnectionParams", null, at: at, tone: Tone.Info));
        }
        foreach (var change in history.OrderByDescending(h => h.At).Take(5))
        {
            facts.Add(PosteText.Fact("Changement d’écrans", change.Text + " (" + PosteText.LocalDateTime(change.At, zone) + ")", FactState.Observed, "Historique des relevés", "20 changements gardés au plus.", at: change.At, tone: Tone.Info));
        }
        facts.Add(dockHints.IsEmpty
            ? PosteText.Fact("Station d’accueil", "Aucun indice au relevé", FactState.Unknown, "Win32_PnPEntity", "L’absence d’indice ne prouve rien : une station USB-C peut n’apparaître que comme concentrateur.", at: at)
            : PosteText.Fact("Station d’accueil", "Indices : " + string.Join(", ", dockHints), FactState.Estimated, "Win32_PnPEntity", "Indices seulement : aucune classe Windows n’identifie une station d’accueil.", at: at, tone: Tone.Info));
    }

    private static void Network(InventorySnapshot d, DateTimeOffset at, ImmutableArray<PosteFact>.Builder facts)
    {
        foreach (var n in d.Network.OrderByDescending(n => n.Physical).ThenByDescending(n => n.Status == 2))
        {
            var ip = n.Ipv4.IsEmpty ? "aucune adresse IPv4" : string.Join(", ", n.Ipv4) + (n.PrefixLength is int p ? "/" + p.ToString(CultureInfo.InvariantCulture) : "");
            var extra = string.Join(" · ", new[] { n.Mac is null ? null : "MAC " + n.Mac, ip, n.Gateway is null ? null : "passerelle " + n.Gateway, n.Dns.IsEmpty ? null : "DNS " + string.Join(", ", n.Dns), n.Dhcp switch { true => "DHCP", false => "adresse fixe", _ => null } }.Where(t => t is not null));
            facts.Add(PosteText.Fact((n.Physical ? "" : "Virtuelle · ") + n.Name, PosteLabels.Adapter(n.Status, n.SpeedBitsPerSecond) + (extra.Length > 0 ? " · " + extra : ""),
                FactState.Observed, "Win32_NetworkAdapter, Win32_NetworkAdapterConfiguration", n.Physical ? "Une vitesse déclarée n’est pas un débit mesuré." : "Interface virtuelle, listée à part.", at: at, tone: n.Status == 2 ? Tone.Ok : Tone.Off));
        }
    }

    private static void Devices(InventorySnapshot d, DateTimeOffset at, ImmutableArray<PosteFact>.Builder facts)
    {
        var printers = d.Printers.Where(p => p.Offline || p.Error).ToList();
        facts.Add(printers.Count == 0
            ? PosteText.Fact("Imprimantes", FrenchText.Count(d.Printers.Length, "imprimante", "imprimantes") + ", aucune hors ligne ni en erreur", FactState.Observed, "Win32_Printer", "Les imprimantes d’une autre session peuvent ne pas apparaître.", at: at, tone: Tone.Ok)
            : PosteText.Fact("Imprimantes en défaut", string.Join(" ; ", printers.Select(p => p.Name + (p.Offline ? " hors ligne" : " en erreur") + " · " + (p.Network ? "réseau" : "locale") + (p.Default ? " · par défaut" : ""))), FactState.Observed, "Win32_Printer", "Le pilote peut rapporter un état obsolète.", at: at, tone: Tone.Warn));
        var devices = d.Devices.Take(25).ToList();
        facts.Add(devices.Count == 0
            ? PosteText.Fact("Périphériques en erreur", "Aucun", FactState.Observed, "Win32_PnPEntity", "Une lecture refusée n’est pas un inventaire vide.", at: at, tone: Tone.Ok)
            : PosteText.Fact("Périphériques en erreur", string.Join(" ; ", devices.Select(x => x.Name + " (" + PosteLabels.DeviceError(x.Code) + ")")), FactState.Observed, "Win32_PnPEntity",
                "Le code indique l’état du gestionnaire de périphériques, pas une cause certaine ; désactivé et déconnecté sont des choix, pas des anomalies.", at: at, tone: devices.Any(x => !PosteLabels.DeviceCodeIsChoice(x.Code)) ? Tone.Warn : Tone.Info));
    }

    private static void Services(InventorySnapshot d, DateTimeOffset at, ImmutableArray<PosteFact>.Builder facts)
    {
        var rows = PosteServices.Rows(d.Services);
        foreach (var line in PosteServices.CompareProfile(rows).Where(l => l.Tone != Tone.Ok))
        {
            facts.Add(PosteText.Fact(line.Name, line.Text + " " + line.Reason, FactState.Observed, "Win32_Service", "Un écart est une piste, aucun service n’est modifié.", at: at, tone: line.Tone));
        }
        var expectedOk = PosteServices.Profile.Length - facts.Count;
        facts.Insert(0, PosteText.Fact("Profil attendu (15 services)", FrenchText.Integer(expectedOk) + " conforme(s) sur " + FrenchText.Integer(PosteServices.Profile.Length), FactState.Observed, "Win32_Service", "Services attendus sur un poste du domaine.", at: at, tone: expectedOk == PosteServices.Profile.Length ? Tone.Ok : Tone.Warn));
        foreach (var row in rows.Where(r => r.AutoStopped).Take(10))
        {
            facts.Add(PosteText.Fact(row.DisplayName, "Automatique arrêté" + (row.ExitCode is int code and not 0 ? " (code " + code.ToString(CultureInfo.InvariantCulture) + ")" : ""), FactState.Observed, "Win32_Service", "Code 1077 normal pour un démarrage sur déclencheur.", at: at, tone: Tone.Warn));
        }
    }

    private static void Tasks(InventorySnapshot d, DateTimeOffset at, TimeZoneInfo zone, ImmutableArray<PosteFact>.Builder facts)
    {
        var others = d.Tasks.Where(t => !t.Microsoft).ToList();
        facts.Add(PosteText.Fact("Tâches planifiées", FrenchText.Count(d.Tasks.Length, "tâche", "tâches") + ", dont " + FrenchText.Integer(others.Count) + " hors Microsoft", FactState.Observed, "MSFT_ScheduledTask",
            "Commandes, arguments et comptes principaux jamais lus ; dernier résultat non déduit.", at: at, tone: Tone.Info));
        foreach (var t in others.Take(8))
        {
            var result = PosteLabels.TaskResult(t.LastResult);
            facts.Add(PosteText.Fact(t.Name, (t.Author ?? "auteur non renseigné") + " · " + t.State + (result.Code.Length > 0 ? " · résultat " + result.Code + " (" + result.Text + ")" : "")
                + (t.LastRun is DateTimeOffset run ? " · dernière exécution " + PosteText.LocalDateTime(run, zone) : ""), FactState.Observed, "MSFT_ScheduledTask", null, at: at, tone: result.Failure == true ? Tone.Warn : Tone.Info));
        }
        foreach (var group in d.Startup.GroupBy(s => s.Location, StringComparer.Ordinal))
        {
            facts.Add(PosteText.Fact("Démarrage · " + group.Key, string.Join(", ", group.Select(s => s.Name + " (" + Path(s.Executable) + ")")), FactState.Observed, "Win32_StartupCommand",
                "Exécutable seulement, jamais les arguments.", at: at, tone: Tone.Info));
        }
    }

    private static string Path(string executable)
    {
        var slash = executable.LastIndexOfAny(['\\', '/']);
        return slash >= 0 ? executable[(slash + 1)..] : executable;
    }

    private static void Antivirus(InventorySnapshot d, DateTimeOffset at, ImmutableArray<PosteFact>.Builder facts)
    {
        foreach (var product in d.Antivirus)
        {
            var (enabled, upToDate) = PosteLabels.AntivirusState(product.ProductState);
            facts.Add(PosteText.Fact(product.Name, (enabled switch { true => "Actif", false => "Inactif", _ => "État inconnu" }) + (upToDate switch { true => ", signatures à jour", false => ", signatures à vérifier", _ => "" }),
                FactState.Estimated, "AntiVirusProduct (productState)", "Décodage non documenté : estimation.", at: at, tone: enabled == true ? Tone.Ok : Tone.Warn));
        }
        if (d.Defender is { } def)
        {
            facts.Add(PosteText.Fact("Defender · protections", "Antivirus " + Yes(def.AntivirusEnabled) + ", temps réel " + Yes(def.RealTime) + ", comportement " + Yes(def.Behavior) + (def.Passive == true ? " · mode passif" : ""),
                FactState.Observed, "MSFT_MpComputerStatus", def.Passive == true ? "Defender passif : un autre antivirus est déclaré." : null, at: at, tone: def.RealTime == true ? Tone.Ok : Tone.Warn));
            facts.Add(PosteText.Fact("Defender · signatures et analyses", "Signatures de " + Days(def.SignatureAgeDays) + ", analyse rapide " + Days(def.QuickScanAgeDays) + ", complète " + Days(def.FullScanAgeDays) + (def.Version is null ? "" : " · version " + def.Version),
                FactState.Observed, "MSFT_MpComputerStatus", "65535 jours signifie « jamais ».", def.SignatureAgeDays is > 7 ? "Signatures de plus de 7 jours : vérifier la source des mises à jour." : null, at, def.SignatureAgeDays is > 7 ? Tone.Warn : Tone.Info));
        }
    }

    private static string Yes(bool? value) => value switch { true => "actif", false => "inactif", _ => "non lu" };

    private static string Days(int? value) => value switch { null => "non lu", 65535 => "jamais", int v => FrenchText.Count(v, "jour", "jours") };

    private static void Firewall(InventorySnapshot d, DateTimeOffset at, ImmutableArray<PosteFact>.Builder facts)
    {
        foreach (var p in d.Firewall)
        {
            var effective = p.PolicyEnabled ?? p.LocalEnabled;
            facts.Add(PosteText.Fact("Profil " + p.Name, (effective switch { true => "activé", false => "désactivé", _ => "inconnu" }) + (p.PolicyEnabled is null ? " (magasin local)" : " (stratégie)"),
                effective is null ? FactState.Unknown : FactState.Observed, "MSFT_NetFirewallProfile", "Origine GPO lue par l’inventaire complet, pas par cette classe.", at: at, tone: effective == false ? Tone.Warn : Tone.Ok));
        }
        foreach (var n in d.Network.Where(n => n.Profile is not null))
        {
            facts.Add(PosteText.Fact("Connexion " + n.Name, "Profil appliqué : " + n.Profile, FactState.Observed, "MSFT_NetConnectionProfile", "La catégorie Domaine suppose l’authentification réseau du domaine au relevé.", at: at, tone: Tone.Info));
        }
    }

    private static void Protection(InventorySnapshot d, DateTimeOffset at, ImmutableArray<PosteFact>.Builder facts)
    {
        foreach (var v in d.BitLocker)
        {
            var encrypted = v.Conversion is 1 || v.EncryptedPercent >= 99.9;
            facts.Add(PosteText.Fact("BitLocker " + v.Drive, (v.Protection == 1 ? "protégé" : encrypted && v.Protection == 0 ? "chiffré, protection suspendue" : encrypted ? "chiffré" : "non chiffré")
                + (v.Method is int m and > 0 ? " · " + PosteLabels.BitLockerMethod(m) : ""), FactState.Observed, "Win32_EncryptableVolume", "Chiffré + protection suspendue ≠ protégé.", at: at, tone: v.Protection == 1 ? Tone.Ok : Tone.Warn));
        }
        if (d.Tpm is { } tpm)
        {
            facts.Add(PosteText.Fact("TPM", (tpm.Specification is null ? "spécification non lue" : "spécification " + tpm.Specification) + " · activé " + Yes(tpm.Enabled) + ", opérationnel " + Yes(tpm.Activated),
                FactState.Observed, "Win32_Tpm", "États initiaux du fournisseur : ils ne remplacent pas une nouvelle lecture.", at: at, tone: tpm.Enabled == true && tpm.Activated == true ? Tone.Ok : Tone.Warn));
        }
        if (d.SecureBoot is { } sb)
        {
            facts.Add(PosteText.Fact("Sécurité basée sur la virtualisation", "VBS " + (sb.VbsRunning switch { true => "en cours", false => "arrêtée", _ => "non lue" }) + " · Credential Guard " + (sb.CredentialGuard switch { true => "actif", false => "inactif", _ => "non lu" }),
                sb.VbsRunning is null ? FactState.Unknown : FactState.Observed, "Win32_DeviceGuard", "Secure Boot n’est pas lisible par ces classes : voir l’inventaire.", at: at, tone: Tone.Info));
        }
    }

    private static void Processes(InventorySnapshot d, DateTimeOffset at, ImmutableArray<PosteFact>.Builder facts)
    {
        var top = d.Processes.Where(p => p.WorkingSetBytes is > 0).OrderByDescending(p => p.WorkingSetBytes).Take(8).ToList();
        facts.Add(top.Count == 0
            ? PosteText.Fact("Processus", "Aucun processus relevé", FactState.Unknown, "Win32_Process", null, at: at)
            : PosteText.Fact("Plus gros ensembles de travail", string.Join(" ; ", top.Select(p => p.Name + " " + PosteText.Size(p.WorkingSetBytes!.Value))), FactState.Observed, "Win32_Process",
                "Aucune charge CPU déduite d’une photographie unique ; mesurez les processus sur un intervalle.", at: at, tone: Tone.Info));
    }
}
