using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Simulation;

/// <summary>
/// Raw values of a probe for one fictitious workstation, in the form WMI would give them (texts, numbers in invariant culture,
/// dates in ISO 8601), derived from the inventory of the world when it holds the value and from a per-computer draw
/// otherwise. The transforms of the catalog apply afterwards, exactly as on real readings.
/// </summary>
internal static class SimulatedProbeValues
{
    public static ImmutableArray<string> Generate(ProbeDefinition probe, DirectoryComputer computer, InventoryMeasure inventory, MachineFacts? facts, SeededRandom draw, DateTimeOffset now)
    {
        var laptop = computer.Name.StartsWith("PT-", StringComparison.Ordinal);
        var model = inventory.Model ?? (laptop ? "Dell Latitude 5440" : "Dell OptiPlex 7010");
        var maker = model.StartsWith("Dell", StringComparison.Ordinal) ? "Dell Inc." : model.StartsWith("HP", StringComparison.Ordinal) ? "HP" : "LENOVO";
        var site = SiteCode(computer.DistinguishedName);
        string N(long n) => n.ToString(CultureInfo.InvariantCulture);
        string Pick(params string[] items) => items[draw.Next(items.Length)];
        string Iso(DateTimeOffset at) => at.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture);
        ImmutableArray<string> One(string value) => [value];
        var memory = inventory.MemoryBytes ?? (16L << 30);
        var boot = inventory.LastBootAt ?? now - TimeSpan.FromDays(draw.Next(1, 9));
        return probe.Id switch
        {
            "hw.maker" => One(maker),
            "hw.model" => One(model),
            "hw.ram" => One(N(memory - (draw.Next(200, 900) * (1L << 20)))),
            "hw.cpu" => One(maker switch
            {
                "Dell Inc." => laptop ? "13th Gen Intel(R) Core(TM) i5-1345U" : "13th Gen Intel(R) Core(TM) i5-13500",
                "HP" => laptop ? "13th Gen Intel(R) Core(TM) i7-1365U" : "Intel(R) Core(TM) i5-10500",
                _ => laptop ? "AMD Ryzen 5 PRO 7540U w/ Radeon 740M Graphics" : "13th Gen Intel(R) Core(TM) i5-13400T",
            }),
            "hw.cpuload" => One(N(draw.Next(2, 66))),
            "hw.cpumhz" => One(laptop ? "1600" : Pick("2500", "3100")),
            "hw.virtualization" or "hw.slat" => One(draw.Next(100) < 94 ? "True" : "False"),
            "hw.batterylevel" => laptop ? One(N(draw.Next(18, 101))) : [],
            "hw.cores" => One(laptop ? Pick("6", "10") : Pick("6", "10", "14")),
            "hw.threads" => One(laptop ? Pick("12", "16") : Pick("12", "16", "20")),
            "hw.bios" => facts?.BiosVersion is string bios ? One(bios) : [],
            "hw.biosyear" => One(Iso(now - TimeSpan.FromDays(draw.Next(90, 900)))),
            "hw.gpu" => One(maker == "LENOVO" && laptop ? "AMD Radeon(TM) 740M Graphics" : laptop ? "Intel(R) Iris(R) Xe Graphics" : "Intel(R) UHD Graphics 770"),
            "hw.screens" => One(laptop ? Pick("1", "2") : Pick("1", "2", "2", "3")),
            "hw.battery" => One(laptop ? "1" : "0"),
            "hw.chassis" => One(laptop ? "2" : "1"),
            "hw.serialmissing" => One((maker == "Dell Inc." ? "" : maker == "HP" ? "5CG" : "PF") + Serial(draw)),
            "os.caption" => One(inventory.OsCaption ?? "Microsoft " + computer.OperatingSystem),
            "os.release" => One((inventory.Build ?? WindowsRelease.ParseBuild(computer.OperatingSystemVersion)?.ToString(CultureInfo.InvariantCulture) ?? "") + "|1"),
            "os.arch" => One("64 bits"),
            "os.uptime" => One(Iso(boot)),
            "os.installyear" => One(Iso(computer.WhenCreated + TimeSpan.FromDays(draw.Next(0, 40)))),
            "os.lang" => One(draw.Next(100) < 97 ? "1036" : "1033"),
            "os.tz" => One("(UTC+01:00) Bruxelles, Copenhague, Madrid, Paris"),
            "os.pagefile" => One(N(Math.Min(16384, memory / (1L << 20) / 4))),
            "os.freeram" => One(N((long)(memory / 1024 * (draw.Next(18, 61) / 100.0)))),
            "os.virtualfree" => One(N((long)(memory / 1024 * (draw.Next(30, 81) / 100.0)))),
            "os.visiblememory" => One(N(memory / 1024 - draw.Next(200_000, 600_000))),
            "os.users" => One("1"),
            "os.producttype" => One("1"),
            "disk.cfree" => inventory.SystemDiskSizeBytes is long size && inventory.SystemDiskFreeBytes is long free ? One(N(free) + "|" + N(size)) : [],
            "disk.csize" => inventory.SystemDiskSizeBytes is long csize ? One(N(csize)) : [],
            "disk.count" => One(draw.Next(100) < 85 ? "1" : "2"),
            "disk.media" => One(draw.Next(100) < 96 ? "4" : "3"),
            "disk.health" => One(draw.Next(100) < 98 ? "0" : "1"),
            "disk.removable" => One(draw.Next(100) < 80 ? "0" : "1"),
            "sec.bitlocker" => One(draw.Next(100) < 93 ? "1" : "0"),
            "sec.av" => One("Microsoft Defender Antivirus"),
            "sec.localusers" => One(draw.Next(100) < 85 ? "1" : "2"),
            "sec.shares" => One(draw.Next(100) < 90 ? "0" : "1"),
            "sec.defender" or "sec.realtime" or "sec.behavior" => One(draw.Next(100) < 98 ? "True" : "False"),
            "sec.signatures" => One(N(draw.Next(0, 4))),
            "sec.quickscan" => One(N(draw.Next(0, 8))),
            "sec.fullscan" => One(draw.Next(100) < 12 ? "65535" : N(draw.Next(3, 61))),
            "sec.defenderversion" => One(Pick("4.18.24090.11", "4.18.25010.11")),
            "sec.tpmversion" => One("2.0, 0, 1.59"),
            "sec.tpmenabled" or "sec.tpmactivated" => One("True"),
            "net.adapter" => laptop ? One(Pick("Intel(R) Wi-Fi 6E AX211 160MHz", "Intel(R) Ethernet Connection (16) I219-LM")) : One("Intel(R) Ethernet Connection (17) I219-LM"),
            "net.speed" => One(laptop ? Pick("866700000", "1000000000", "1200000000") : "1000000000"),
            "net.dhcp" => One("True"),
            "net.dns" => One("10." + SiteOctet(site) + ".0.10"),
            "net.gateway" => One("10." + SiteOctet(site) + ".0.1"),
            "net.wifi" => One(laptop && draw.Next(100) < 55 ? "1" : "0"),
            "soft.printers" => One(N(draw.Next(2, 7))),
            "soft.defaultprinter" => One(draw.Next(100) < 70 ? "IMP-" + site + "-" + draw.Next(1, 9).ToString("00", CultureInfo.InvariantCulture) : "Microsoft Print to PDF"),
            "soft.startup" => One(N(draw.Next(4, 13))),
            "soft.stoppedauto" => One(N(draw.Next(100) < 70 ? 0 : draw.Next(1, 4))),
            "soft.running" => One(N(draw.Next(85, 131))),
            "soft.spooler" or "soft.winrm" or "soft.w32time" or "soft.firewall" or "soft.defender" or "soft.dnsclient" => One(draw.Next(100) < 97 ? "Running" : "Stopped"),
            "soft.wuauserv" or "soft.bits" or "soft.rdp" => One(draw.Next(100) < 60 ? "Running" : "Stopped"),
            "soft.hotfixcount" => One(N(draw.Next(8, 23))),
            "soft.processes" => One(N(draw.Next(120, 261))),
            "user.console" => facts?.ConsoleUser is string user ? One(user) : [],
            "user.profiles" => One(N(draw.Next(1, 7))),
            "user.sessions" => One("1"),
            "evt.syserrors" => One(N(draw.Next(100) < 60 ? draw.Next(0, 3) : draw.Next(3, 13))),
            "evt.unexpected" => One(N(draw.Next(100) < 85 ? 0 : draw.Next(1, 3))),
            "hw.memorymodules" => memory > (8L << 30) ? ["DIMM A", "DIMM B"] : ["DIMM A"],
            "hw.memoryarrays" => One("Carte mère"),
            "disk.volumes" => draw.Next(100) < 85 ? ["C:"] : ["C:", "D:"],
            "disk.physical" => One(Pick("Samsung PM9B1 NVMe 512 Go", "SK hynix PC801 NVMe 512 Go", "KIOXIA KBG50ZNV256G")),
            "disk.reliability" => One("Disque 0"),
            "hw.batteries" or "hw.batterystatic" => laptop ? One("Batterie interne") : [],
            "hw.batteryfullcharge" => laptop ? One(N(draw.Next(38_000, 54_000))) : [],
            "hw.batterycycles" => laptop ? One(N(draw.Next(40, 640))) : [],
            "hw.biosdetails" => facts?.BiosVersion is string details ? One(details) : [],
            "hw.processors" => One("CPU0"),
            "hw.monitors" => laptop ? ["Écran interne", Pick("DELL P2423D", "HP E24 G5", "LEN T24i-30")] : [Pick("DELL P2423D", "HP E24 G5", "LEN T24i-30")],
            "net.interfaces" => laptop ? ["Wi-Fi", "Ethernet"] : ["Ethernet"],
            "net.configurations" => One("DHCP"),
            "soft.printerdetails" => ["Microsoft Print to PDF", "IMP-" + site + "-0" + draw.Next(1, 9).ToString(CultureInfo.InvariantCulture)],
            "hw.deviceerrors" => draw.Next(100) < 90 ? [] : One("Périphérique inconnu"),
            "soft.servicedetails" => ["Spooler", "WinRM", "W32Time"],
            "soft.hotfixdetails" => One("KB5" + draw.Next(30_000, 49_999).ToString(CultureInfo.InvariantCulture)),
            "soft.processdetails" => ["explorer.exe", "msedge.exe", "OUTLOOK.EXE"],
            "soft.scheduledtasks" => ["MicrosoftEdgeUpdateTaskMachineCore", "OneDrive Reporting Task"],
            "soft.startupdetails" => ["SecurityHealth", "OneDrive"],
            "soft.installed" => ["Microsoft 365 Apps", "Microsoft Edge", "7-Zip 24.08"],
            "sec.defenderdetails" => One("Microsoft Defender"),
            "sec.firewallprofiles" => ["Domain", "Private", "Public"],
            "sec.deviceguard" => One(draw.Next(100) < 80 ? "Activé" : "Non configuré"),
            "sec.bitlockervolumes" => One("C:"),
            "sec.tpmdetails" => One("2.0"),
            "hw.memoryusage" => One(N((long)(memory / 1024 * (draw.Next(35, 85) / 100.0)))),
            "hw.computersystem" => One(model),
            "hw.monitorconnections" => laptop ? ["2147483648", Pick("5", "10")] : [Pick("5", "10")],
            "hw.dockhints" => laptop && draw.Next(100) < 40 ? One("Station d’accueil USB-C") : [],
            "net.connectionprofiles" => One("2"),
            "sec.avproducts" => One("Microsoft Defender Antivirus"),
            _ => probe.Mode == "Count" ? One(N(draw.Next(0, 5))) : One("Valeur " + (char)('A' + draw.Next(3))),
        };
    }

    private static string Serial(SeededRandom draw)
    {
        const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ0123456789";
        var chars = new char[7];
        for (var i = 0; i < chars.Length; i++)
        {
            chars[i] = alphabet[draw.Next(alphabet.Length)];
        }
        return new string(chars);
    }

    private static string SiteCode(string dn)
    {
        foreach (var site in SimulationProfile.Sites)
        {
            if (dn.Contains("OU=" + site.Name + ",", StringComparison.OrdinalIgnoreCase))
            {
                return site.Code;
            }
        }
        return "PAR";
    }

    private static string SiteOctet(string code) => code switch { "PAR" => "10", "LYO" => "20", "MRS" => "30", "LIL" => "40", _ => "50" };
}
