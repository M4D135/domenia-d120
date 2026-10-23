using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Simulation.Poste;

/// <summary>
/// Builds the fictitious workstation of each computer of the generated directory (docs/PLATFORM.md § 4): only the seed, the
/// reference date and the zone count; the sub-stream « screen/poste » then one fork per computer GUID, so adding a draw to a
/// workstation shifts neither the directory nor another workstation nor another screen. Pure.
/// </summary>
internal static class PosteMachines
{
    private static readonly string[] SiteNets = ["Paris|10.10", "Lyon|10.20", "Marseille|10.30", "Lille|10.40", "Bordeaux|10.50"];

    public static PosteMachine Build(DirectoryComputer c, WorkstationObservation? observation, SimulatedWorld world, DirectorySnapshot directory, SeededRandom screen)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(world);
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(screen);
        var r = screen.Fork(c.ObjectGuid.ToString("N"));
        var now = world.Reference;
        var inventory = observation?.Inventory is { HasReading: true } inv ? inv : null;
        var laptop = c.Name.StartsWith("PT-", StringComparison.OrdinalIgnoreCase);
        var parent = DistinguishedName.Parse(c.DistinguishedName);
        var site = parent.Skip(1).FirstOrDefault(p => p.Type.Equals("OU", StringComparison.OrdinalIgnoreCase)).Value ?? "Paris";
        var siteSpec = SimulationProfile.Sites.FirstOrDefault(s => s.Name == site) ?? SimulationProfile.Sites[0];
        var model = ModelFor(inventory?.Model, laptop, r.Fork("model"));
        var hw = r.Fork("hardware");
        var memory = inventory?.MemoryBytes ?? hw.Pick([8L, 16L, 16L, 16L, 32L]) * 1024 * 1024 * 1024;
        var modulesCount = laptop ? 2 : memory >= 32L * 1024 * 1024 * 1024 ? 4 : 2;
        var speed = laptop ? 5200 : 3200;
        var modules = Enumerable.Range(0, modulesCount).Select(i => new MemoryModule(laptop ? (i == 0 ? "Controller0-ChannelA" : "Controller1-ChannelA") : "DIMM " + (i + 1).ToString(CultureInfo.InvariantCulture),
            memory / modulesCount, speed, hw.Pick(["Samsung", "SK Hynix", "Micron", "Kingston"]), "M" + hw.Next(100000, 999999).ToString(CultureInfo.InvariantCulture))).ToImmutableArray();
        var nominal = hw.Next(100) switch { < 60 => 256L, < 95 => 512L, _ => 1000L };
        var size = inventory?.SystemDiskSizeBytes ?? nominal * 1_000_000_000L - hw.Next(400, 2500) * 1_000_000L;
        var free = inventory?.SystemDiskFreeBytes ?? (long)(size * hw.Next(222, 801) / 1000d);
        var critical = 100d * free / size < 10;
        var hdd = !laptop && hw.Chance(7);
        var wearAlert = hw.Chance(2);
        var boot = inventory?.LastBootAt ?? now - hw.Between(TimeSpan.FromHours(2), TimeSpan.FromDays(9));
        var sec = r.Fork("security");
        var bitlockerMode = sec.Next(100) switch { < 4 => "suspended", < 7 when !laptop => "off", _ => "on" };
        var net = r.Fork("network");
        var siteNet = SiteNets.Select(s => s.Split('|')).FirstOrDefault(s => s[0] == site)?[1] ?? "10.10";
        var third = net.Next(0, 4) + 4 * net.Next(0, 2);
        var ip = siteNet + "." + third.ToString(CultureInfo.InvariantCulture) + "." + net.Next(20, 250).ToString(CultureInfo.InvariantCulture);
        var gateway = siteNet + "." + (third & ~3).ToString(CultureInfo.InvariantCulture) + ".1";
        var mac = model.MacPrefix + "-" + string.Join("-", Enumerable.Range(0, 3).Select(_ => net.Next(0, 256).ToString("X2", CultureInfo.InvariantCulture)));
        var slowRoll = r.Fork("slow");
        var slow = critical ? SlowCause.Disk : slowRoll.Next(100) switch
        {
            < 5 => SlowCause.Memory,
            < 8 => SlowCause.Cpu,
            < 10 when !laptop => SlowCause.Hdd,
            < 13 => SlowCause.Startup,
            _ => SlowCause.None,
        };
        if (hdd && slow == SlowCause.None)
        {
            slow = SlowCause.Hdd;
        }
        var user = Association(c, directory, site, r.Fork("user"), out var badge, out var department);
        var softwareRng = r.Fork("software");
        var software = Software(model, department, softwareRng, now);
        var startup = Startup(software, slow, r.Fork("startup"));
        var services = Services(software, laptop, r.Fork("services"));
        var refused = r.Fork("access").Chance(3) ? ImmutableArray.Create(InventoryCategories.Antivirus) : [];
        var hotfixes = Hotfixes(r.Fork("hotfixes"), now);
        var build = WindowsRelease.ParseBuild(c.OperatingSystemVersion)?.ToString(CultureInfo.InvariantCulture) ?? "26100";
        var revision = build switch { "26100" => 6899, "26200" => 6899, "22631" => 6060, "19045" => 6456, "19044" => 6456, _ => 1000 };
        var history = VolumeHistory(size, free, now, r.Fork("history"), critical);
        var displays = Displays(laptop, model, r.Fork("displays"));
        return new PosteMachine
        {
            Computer = c,
            Site = site,
            SiteCode = siteSpec.Code,
            Laptop = laptop,
            Model = model,
            Serial = model.Maker switch
            {
                "Dell Inc." => string.Concat(Enumerable.Range(0, 7).Select(_ => "BCDFGHJKLMNPQRSTVWXZ0123456789"[hw.Next(30)])),
                "HP" => "5CG" + hw.Next(3000, 4999).ToString(CultureInfo.InvariantCulture) + string.Concat(Enumerable.Range(0, 3).Select(_ => "ABCDEFGHJKLMNPQRSTUVWXYZ"[hw.Next(24)])),
                _ => "PF" + string.Concat(Enumerable.Range(0, 6).Select(_ => "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"[hw.Next(34)])),
            },
            MemoryBytes = memory,
            Modules = modules,
            Slots = laptop ? 2 : 4,
            DiskSize = size,
            DiskFree = free,
            MediaType = hdd ? 3 : 4,
            BusType = hdd ? 11 : 17,
            DiskName = hdd ? "ST1000DM010-2EP102" : hw.Pick(["Samsung PM9A1 NVMe 512GB", "SK hynix PC801 NVMe 512GB", "KIOXIA KXG80ZNV256G", "Micron 2450 NVMe 256GB"]),
            DiskHealth = wearAlert ? 1 : 0,
            Wear = hdd ? null : wearAlert ? hw.Next(91, 97) : hw.Next(1, 36),
            Temperature = hw.Next(31, 47),
            PowerOnHours = hw.Next(900, 21000),
            Uncorrected = wearAlert ? hw.Next(2, 40) : 0,
            DataVolume = !laptop && hw.Chance(18) ? (480_000_000_000L, (long)(480_000_000_000L * hw.Next(300, 900) / 1000d)) : null,
            BiosVersion = model.BiosPrefix + model.Maker switch
            {
                "Dell Inc." => hw.Next(18, 26).ToString(CultureInfo.InvariantCulture) + ".0",
                "HP" => hw.Next(10, 21).ToString("00", CultureInfo.InvariantCulture) + ".00",
                _ => hw.Next(40, 62).ToString(CultureInfo.InvariantCulture) + "W (1." + hw.Next(30, 52).ToString(CultureInfo.InvariantCulture) + " )",
            },
            BiosDate = now.AddDays(-hw.Next(60, 700)),
            SecureBoot = sec.Chance(3) ? false : true,
            BitLockerProtection = bitlockerMode == "on" ? 1 : 0,
            BitLockerConversion = bitlockerMode == "off" ? 0 : 1,
            Mac = mac,
            Ip = ip,
            Prefix = 22,
            Gateway = gateway,
            LinkSpeed = net.Chance(6) ? 100_000_000 : 1_000_000_000,
            FirewallPublicOff = sec.Chance(2),
            SignatureAge = sec.Chance(4) ? sec.Next(9, 21) : sec.Next(0, 3),
            Hotfixes = hotfixes,
            Software = software,
            Startup = startup,
            Services = services,
            Devices = r.Fork("devices").Next(100) switch
            {
                < 3 => [new DeviceError("Périphérique Bluetooth Intel(R) Wireless", 43, "Bluetooth")],
                < 5 => [new DeviceError("Lecteur d’empreintes digitales Synaptics", 28, "Biometric")],
                < 9 => [new DeviceError("Carte réseau Wi-Fi désactivée", 22, "Net")],
                _ => [],
            },
            Displays = displays,
            Battery = laptop ? Battery(r.Fork("battery")) : null,
            UnsignedDrivers = r.Fork("drivers").Chance(2) ? [new DriverInfo("Pilote de clé USB OTP", "Fournisseur inconnu", "1.0.3.0")] : [],
            Shares = r.Fork("shares").Chance(6) ? [new ShareInfo("ADMIN$", "C:\\Windows", "Administration à distance"), new ShareInfo("C$", "C:\\", "Partage par défaut"), new ShareInfo("IPC$", "", "IPC distant"), new ShareInfo("Scans", "D:\\Scans", "Numérisations du copieur")]
                : [new ShareInfo("ADMIN$", "C:\\Windows", "Administration à distance"), new ShareInfo("C$", "C:\\", "Partage par défaut"), new ShareInfo("IPC$", "", "IPC distant")],
            Printers =
            [
                new PrinterInfo("Copieur " + site + " · RDC", "HP Universal Printing PCL 6", "IP_10.0." + siteSpec.Code.Length.ToString(CultureInfo.InvariantCulture) + ".80", true, true, r.Fork("printers").Chance(5), false),
                new PrinterInfo("Microsoft Print to PDF", "Microsoft Print To PDF", "PORTPROMPT:", false, false, false, false),
            ],
            Reboot = r.Fork("reboot").Next(100) switch
            {
                < 8 => new PendingReboot(["Component Based Servicing", "Windows Update"], []),
                < 13 => new PendingReboot([], ["PendingFileRenameOperations"]),
                _ => new PendingReboot([], []),
            },
            ClockSkew = r.Fork("clock").Next(1000) switch { < 6 => 412, < 25 => 96, _ => r.Fork("clock/s").Next(-2, 3) },
            Proxy = net.Chance(30) ? "proxy.example.local:3128" : null,
            Events = Events(c, boot, slow, wearAlert, r.Fork("events"), now),
            Tasks = Tasks(r.Fork("tasks"), now),
            Certificates = Certificates(c, r.Fork("certificates"), now),
            LastBoot = boot,
            InstallDate = c.WhenCreated.AddHours(2),
            Caption = "Microsoft " + (c.OperatingSystem ?? "Windows 11 Entreprise"),
            Build = build,
            Revision = revision,
            Slow = slow,
            BaseMemoryUse = slow == SlowCause.Memory ? 93 : hw.Next(38, 72),
            User = user,
            Badge = badge,
            Department = department,
            RefusedSources = refused,
            MonitorHistory = laptop && displays.Length > 1
                ? [new MonitorChange(now.AddDays(-r.Fork("mon").Next(2, 40)), "Écran externe " + displays[1].Name + " raccordé")]
                : [],
            VolumeHistory = history,
            DockHints = laptop && displays.Length > 1 ? ["Dell WD19S (USB-C)", "Realtek USB GbE Family Controller"] : [],
            Seed = r.Fork("live").Seed,
        };
    }

    private static SimModel ModelFor(string? label, bool laptop, SeededRandom r)
    {
        var models = PosteCatalogs.Models.Where(m => m.Laptop == laptop).ToList();
        return models.FirstOrDefault(m => string.Equals(PosteCatalogs.Label(m), label, StringComparison.Ordinal)) ?? r.Pick(models);
    }

    /// <summary>The user of the workstation: managedBy (declared), else a user of the same site seen at the console (observed).</summary>
    private static UserRef? Association(DirectoryComputer c, DirectorySnapshot directory, string site, SeededRandom r, out AssociationBadge badge, out string department)
    {
        department = "Commercial";
        if (c.ManagedByDn is not null)
        {
            var owner = directory.Users.FirstOrDefault(u => string.Equals(u.DistinguishedName, c.ManagedByDn, StringComparison.OrdinalIgnoreCase));
            if (owner is not null)
            {
                department = owner.Department ?? department;
                badge = r.Chance(6) ? AssociationBadge.Contradictory : AssociationBadge.Declared;
                return new UserRef(owner.DisplayName ?? owner.Cn, owner.SamAccountName, owner.DistinguishedName, owner.ObjectGuid);
            }
        }
        if (r.Chance(14))
        {
            badge = AssociationBadge.None;
            return null;
        }
        var candidates = directory.Users.Where(u => !AdValues.IsDisabled(u.UserAccountControl) && u.DistinguishedName.Contains(",OU=" + site + ",OU=Utilisateurs,", StringComparison.OrdinalIgnoreCase)).ToList();
        if (candidates.Count == 0)
        {
            badge = AssociationBadge.None;
            return null;
        }
        var user = candidates[r.Next(candidates.Count)];
        department = user.Department ?? department;
        badge = r.Chance(10) ? AssociationBadge.History : AssociationBadge.Observed;
        return new UserRef(user.DisplayName ?? user.Cn, user.SamAccountName, user.DistinguishedName, user.ObjectGuid);
    }

    private static ImmutableArray<SoftwareEntry> Software(SimModel model, string department, SeededRandom r, DateTimeOffset now)
    {
        var list = ImmutableArray.CreateBuilder<SoftwareEntry>();
        var today = DateOnly.FromDateTime(now.UtcDateTime);
        foreach (var s in PosteCatalogs.Software)
        {
            if (s.Departments.Length > 0 && !s.Departments.Split(',').Contains(department, StringComparer.Ordinal) && !r.Chance(4))
            {
                continue;
            }
            if (!r.Chance(s.Percent))
            {
                continue;
            }
            var installed = r.Chance(12) ? today.AddDays(-r.Next(1, 29)) : today.AddDays(-r.Next(40, 900));
            var location = s.Scope == "Store" ? null : (s.Architecture == "32 bits" ? "C:\\Program Files (x86)\\" : "C:\\Program Files\\") + s.Name.Split(' ')[0];
            list.Add(new SoftwareEntry(s.Name, s.Version, s.Publisher, s.Scope == "Store" ? null : installed, s.SizeMb * 1048576L, s.Architecture, s.Scope, s.Scope == "Utilisateur" ? "Profil de l’utilisateur" : null,
                location, s.Scope == "Machine" ? "MsiExec.exe /X{…}" : null, s.Source));
            if (s.Name.StartsWith("Microsoft Visual C++ 2015-2022 Redistributable (x86)", StringComparison.Ordinal) && r.Chance(30))
            {
                list.Add(new SoftwareEntry(s.Name, "14.38.33135", s.Publisher, today.AddDays(-r.Next(300, 900)), s.SizeMb * 1048576L, s.Architecture, s.Scope, null, location, "MsiExec.exe /X{…}", s.Source));
            }
        }
        list.Add(new SoftwareEntry(model.VendorTool, model.Maker == "Dell Inc." ? "5.5.0" : model.Maker == "HP" ? "9.42.27.0" : "10.2508.16.0", model.Maker == "LENOVO" ? "Lenovo" : model.Maker,
            today.AddDays(-r.Next(60, 500)), 180L * 1048576, "64 bits", "Machine", null, "C:\\Program Files\\" + model.VendorTool.Split(' ')[0], "MsiExec.exe /X{…}", "Uninstall64"));
        return list.ToImmutable();
    }

    private static ImmutableArray<StartupEntry> Startup(ImmutableArray<SoftwareEntry> software, SlowCause slow, SeededRandom r)
    {
        var count = slow == SlowCause.Startup ? r.Next(13, 16) : r.Next(4, 9);
        return [.. PosteCatalogs.Startup.Take(count).Select(s => new StartupEntry(s.Name, s.Executable, s.Location, null, s.Microsoft))
            .Where(s => s.Name != "Zoom" || software.Any(x => x.Name.StartsWith("Zoom", StringComparison.Ordinal)))];
    }

    private static ImmutableArray<ServiceEntry> Services(ImmutableArray<SoftwareEntry> software, bool laptop, SeededRandom r)
    {
        var broken = r.Next(100) switch { < 3 => "Spooler", < 5 => "WSearch", < 6 => "Dnscache", _ => null };
        var winRmOff = r.Chance(10);
        var pid = 600;
        var list = ImmutableArray.CreateBuilder<ServiceEntry>();
        foreach (var s in PosteCatalogs.Services)
        {
            if (s.Name == "WlanSvc" && !laptop)
            {
                continue;
            }
            if (s.Name == "gupdate" && !software.Any(x => x.Name == "Google Chrome"))
            {
                continue;
            }
            if (s.Name == "WinRM" && winRmOff)
            {
                list.Add(new ServiceEntry(s.Name, s.Display, "Stopped", "Manual", false, null, s.Account, null, [.. s.DependsOn.Split(',', StringSplitOptions.RemoveEmptyEntries)], s.Description) { DependenciesRead = true });
                continue;
            }
            var state = s.Name == broken ? "Stopped" : s.State;
            int? exit = state == "Stopped" && s.StartMode == "Auto" ? (s.Name == broken ? 1067 : s.Delayed ? 0 : 1077) : null;
            pid += r.Next(4, 180) * 4;
            list.Add(new ServiceEntry(s.Name, s.Display, state, s.StartMode, s.Delayed, state == "Running" ? pid : null, s.Account, exit,
                [.. s.DependsOn.Split(',', StringSplitOptions.RemoveEmptyEntries)], s.Description) { DependenciesRead = true });
        }
        return list.ToImmutable();
    }

    private static ImmutableArray<Hotfix> Hotfixes(SeededRandom r, DateTimeOffset now)
    {
        var old = r.Chance(5);
        var latest = old ? now.AddDays(-r.Next(65, 140)) : new DateTimeOffset(2026, 10, 15, 6, 0, 0, TimeSpan.Zero).AddDays(-r.Next(0, 3));
        if (latest > now)
        {
            latest = now.AddDays(-1);
        }
        return
        [
            new Hotfix("KB5066835", "Mise à jour de sécurité", latest),
            new Hotfix("KB5065789", "Mise à jour", latest.AddDays(-27)),
            new Hotfix("KB5064401", "Mise à jour de la pile de maintenance", latest.AddDays(-34)),
            new Hotfix("KB5063878", "Mise à jour de sécurité", latest.AddDays(-58)),
        ];
    }

    private static ImmutableArray<VolumeSample> VolumeHistory(long size, long free, DateTimeOffset now, SeededRandom r, bool critical)
    {
        var count = r.Next(10, 26);
        var dailyFall = critical ? r.Next(260, 900) * 1_048_576L : r.Chance(40) ? r.Next(20, 250) * 1_048_576L : 0;
        var list = ImmutableArray.CreateBuilder<VolumeSample>();
        for (var i = count; i >= 1; i--)
        {
            var at = now.AddDays(-i * 2.5).AddHours(-r.Next(0, 6));
            var noise = (long)((r.NextDouble() - 0.5) * 300_000_000);
            var value = Math.Clamp(free + (long)(dailyFall * i * 2.5) + noise, 0, size);
            list.Add(new VolumeSample(at, size, value));
        }
        return list.ToImmutable();
    }

    private static ImmutableArray<DisplayInfo> Displays(bool laptop, SimModel model, SeededRandom r)
    {
        var list = ImmutableArray.CreateBuilder<DisplayInfo>();
        if (laptop)
        {
            list.Add(new DisplayInfo("Écran intégré", model.Maker.Split(' ')[0], "LCD 14\u00A0po", null, 2023, "Interne (eDP)", true));
            if (r.Chance(50))
            {
                list.Add(new DisplayInfo("DELL P2422H", "Dell", "P2422H", "CN0" + r.Next(10000, 99999).ToString(CultureInfo.InvariantCulture), r.Next(2021, 2025), "DisplayPort (station d’accueil)", false));
            }
        }
        else
        {
            list.Add(new DisplayInfo("HP E24 G5", "HP", "E24 G5", "CNK" + r.Next(10000, 99999).ToString(CultureInfo.InvariantCulture), r.Next(2021, 2025), "DisplayPort", false));
            if (r.Chance(45))
            {
                list.Add(new DisplayInfo("HP E24 G5", "HP", "E24 G5", "CNK" + r.Next(10000, 99999).ToString(CultureInfo.InvariantCulture), r.Next(2021, 2025), "HDMI", false));
            }
        }
        return list.ToImmutable();
    }

    private static BatteryInfo Battery(SeededRandom r)
    {
        var design = r.Pick([54_000L, 57_000L, 63_000L]);
        var worn = r.Chance(12);
        var full = (long)(design * (worn ? r.Next(48, 60) : r.Next(78, 99)) / 100d);
        return new BatteryInfo("DELL VKYJX38 / LGC", r.Chance(8) ? r.Next(9, 19) : r.Next(35, 100), r.Pick([2, 2, 6, 1]), design, full, r.Next(40, worn ? 900 : 420));
    }

    private static ImmutableArray<EventEntry> Events(DirectoryComputer c, DateTimeOffset boot, SlowCause slow, bool diskErrors, SeededRandom r, DateTimeOffset now)
    {
        var list = new List<EventEntry>
        {
            new(6005, "EventLog", "System", "Information", boot.AddSeconds(40), c.Name, null, "Le service Journal des événements a été démarré."),
            new(10016, "Microsoft-Windows-DistributedCOM", "System", "Erreur", now.AddHours(-r.Next(2, 40)), c.Name, "S-1-5-18", "Les paramètres d’autorisation propres à l’application n’accordent pas l’autorisation Activation locale."),
            new(7016, "Microsoft-Windows-GroupPolicy", "System", "Information", now.AddHours(-r.Next(1, 8)), c.Name, "S-1-5-18", "Fin du traitement de l’extension de stratégie de groupe Registre."),
            new(19, "Microsoft-Windows-WindowsUpdateClient", "System", "Information", now.AddDays(-r.Next(5, 9)), c.Name, "S-1-5-18", "Installation réussie : Windows a installé la mise à jour suivante : KB5066835."),
        };
        if (r.Chance(10))
        {
            list.Add(new EventEntry(41, "Microsoft-Windows-Kernel-Power", "System", "Erreur", now.AddHours(-r.Next(5, 60)), c.Name, null, "Le système a redémarré sans s’arrêter correctement au préalable."));
            list.Add(new EventEntry(6008, "EventLog", "System", "Erreur", now.AddHours(-r.Next(5, 60)), c.Name, null, "L’arrêt système précédent n’était pas prévu."));
        }
        if (diskErrors || slow == SlowCause.Hdd && r.Chance(50))
        {
            list.Add(new EventEntry(51, "disk", "System", "Erreur", now.AddHours(-r.Next(3, 50)), c.Name, null, "Une erreur a été détectée sur le périphérique \\Device\\Harddisk0\\DR0 lors d’une opération de pagination."));
            list.Add(new EventEntry(153, "disk", "System", "Avertissement", now.AddHours(-r.Next(3, 50)), c.Name, null, "L’opération d’E/S à l’adresse logique a été relancée."));
        }
        if (slow is SlowCause.Memory or SlowCause.Cpu || r.Chance(8))
        {
            for (var i = 0; i < r.Next(3, 6); i++)
            {
                list.Add(new EventEntry(1000, "Application Error", "Application", "Erreur", now.AddHours(-r.Next(1, 70)), c.Name, null, "Nom de l’application défaillante : ms-teams.exe, version : 25275.2601.4002.2815."));
            }
        }
        if (r.Chance(6))
        {
            list.Add(new EventEntry(1085, "Microsoft-Windows-GroupPolicy", "System", "Avertissement", now.AddHours(-r.Next(3, 70)), c.Name, "S-1-5-18", "Échec de l’application des paramètres Préférences de mappage de lecteur."));
        }
        return [.. list.OrderByDescending(e => e.At)];
    }

    private static ImmutableArray<TaskEntry> Tasks(SeededRandom r, DateTimeOffset now) =>
        [
            .. PosteCatalogs.Tasks.Select(t => new TaskEntry(t.Name, t.Path, t.Author, r.Chance(5) ? "Désactivée" : "Prête",
                t.Microsoft ? "0x0" : r.Next(100) switch { < 8 => "0x80070002", < 12 => "0x41303", _ => "0x0" },
                now.AddHours(-r.Next(1, 160)), now.AddHours(r.Next(1, 160)), t.Microsoft)),
        ];

    private static ImmutableArray<CertificateEntry> Certificates(DirectoryComputer c, SeededRandom r, DateTimeOffset now)
    {
        var expiry = r.Next(100) switch { < 2 => now.AddDays(-r.Next(3, 40)), < 7 => now.AddDays(r.Next(4, 28)), _ => now.AddDays(r.Next(60, 360)) };
        return
        [
            new CertificateEntry("CN=" + (c.DnsHostName ?? c.Name), "CN=EXAMPLE-CA, DC=example, DC=local", expiry, ["Authentification du client", "Authentification du serveur"], Convert.ToHexString(BitConverter.GetBytes(r.NextUInt64()))),
            new CertificateEntry("CN=" + c.Name + "-VPN", "CN=EXAMPLE-VPN-CA, O=Example", now.AddDays(r.Next(200, 1500)), ["Authentification du client"], Convert.ToHexString(BitConverter.GetBytes(r.NextUInt64()))),
        ];
    }
}
