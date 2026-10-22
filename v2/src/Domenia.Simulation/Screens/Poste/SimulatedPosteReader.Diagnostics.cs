using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Simulation.Poste;

namespace Domenia.Simulation;

/// <summary>Diagnosis, WMI explorer, probe readings, slow triage, logons, last user and secrets of the simulation.</summary>
public sealed partial class SimulatedPosteReader
{
    // ------------------------------------------------------------------ diagnosis

    public async Task<DiagnosticResult> DiagnosticAsync(string dn, IProgress<PosteProgress>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        var started = Sim.Now;
        var reachable = Sim.Reachable(c.ObjectGuid, observation);
        var answers = Sim.Answers(c.ObjectGuid, observation) == true && !Sim.PingFiltered(c.ObjectGuid);
        var stale = AdValues.FromFileTime(c.LastLogonTimestamp) is not DateTimeOffset logon || (started - logon).TotalDays > 90;
        var r = Sim.Live(machine);
        var checks = new List<DiagCheck>();
        void Add(string check, string status, string method, string detail) => checks.Add(new DiagCheck(check, status, method, r.Next(3, reachable ? 160 : 1900), detail));
        var dnsOk = !(stale && !reachable && r.Chance(60));
        Add("Resolution DNS", dnsOk ? "OK" : "ERREUR", "DNS", dnsOk ? machine.DnsName + " → " + machine.Ip : "Aucun enregistrement pour " + machine.DnsName);
        Add("Ping", answers ? "OK" : "ERREUR", "ICMP", answers ? "Réponse en " + r.Next(1, 14).ToString(CultureInfo.InvariantCulture) + " ms" : "Délai d’attente dépassé (1 écho)");
        foreach (var (port, label) in new[] { (135, "RPC"), (445, "SMB"), (3389, "RDP") })
        {
            Add("TCP " + port.ToString(CultureInfo.InvariantCulture), reachable ? "OK" : "INJOIGNABLE", "TCP", reachable ? label + " ouvert" : "Aucune réponse (filtré ou poste éteint)");
        }
        var blocked = reachable && Sim.CimBlocked(machine);
        var winRm = reachable && !blocked && WinRmRunning(machine);
        Add("TCP 5985", winRm ? "OK" : "INJOIGNABLE", "TCP", winRm ? "WinRM HTTP ouvert" : "WinRM HTTP fermé");
        Add("TCP 5986", "INJOIGNABLE", "TCP", "WinRM HTTPS fermé (non configuré)");
        Add("Session CIM", !reachable ? "IGNORE" : blocked ? "REFUSE" : "OK", "DCOM", !reachable ? "Non tenté : aucun port de gestion ne répond" : blocked ? "RPC filtré par le pare-feu du poste (0x800706BA) : session CIM refusée" : "Session CIM ouverte (DCOM)");
        Add("Partage C$", reachable ? "OK" : "IGNORE", "SMB", reachable ? "\\\\" + c.Name + "\\C$ accessible avec le compte des opérations poste" : "Non tenté");
        Add("WinRM", winRm ? "OK" : "INJOIGNABLE", "WSMan", winRm ? "Écoute WS-Management (HTTP)" : blocked ? "WinRM fermé sur le poste" : "Service WinRM arrêté (lecture par DCOM)");
        Add("Transport PsExec", reachable ? "INDISPONIBLE" : "IGNORE", "SMB", reachable ? "PsExec absent du pack : repli non disponible" : "Non tenté");
        var fallback = blocked && PosteSession.For(source).ConsumeReadFallback(c.DistinguishedName, "diagnostic", started);
        Add("Transport Task Scheduler", !reachable ? "IGNORE" : !blocked ? "OK" : fallback ? "OK" : "IGNORE", "RPC",
            !reachable ? "Non tenté" : !blocked ? "Planificateur joignable (/query)" : fallback ? "Tâche planifiée unique créée, lue puis supprimée (lecture de repli autorisée, consommée)" : "Non tenté : lecture de repli non autorisée (vue Intervenir)");
        if (reachable && (!blocked || fallback))
        {
            var inventory = LiveSnapshot(machine, false, observation, started);
            var c1 = inventory.Volumes.First();
            var pct = 100d * c1.FreeBytes!.Value / c1.SizeBytes!.Value;
            Add("Systeme", "OK", "CIM", inventory.Os!.Caption + " " + inventory.Os.Version);
            Add("Disque systeme", pct < 10 ? "ERREUR" : "OK", "CIM", FrenchText.Percent(pct) + " libres sur C:");
            Add("Redemarrage en attente", inventory.PendingReboot!.Confirmed.IsEmpty ? "OK" : "ERREUR", "Registre", inventory.PendingReboot.Confirmed.IsEmpty ? "Aucun" : string.Join(", ", inventory.PendingReboot.Confirmed));
        }
        var done = 0;
        try
        {
            for (var i = 0; i < checks.Count; i++)
            {
                progress?.Report(new PosteProgress(i + 1, checks.Count, checks[i].Check));
                await Wait("diagnostic", 30, reachable ? 90 : 160, cancellationToken).ConfigureAwait(false);
                done = i + 1;
            }
        }
        catch (OperationCanceledException) when (done > 0)
        {
            // A stop keeps the checks already made (partial result, Domenia 1 PST-037); the others are « non tentés ».
            for (var i = done; i < checks.Count; i++)
            {
                checks[i] = checks[i] with { Status = "IGNORE", DurationMs = 0, Detail = "Non tenté : diagnostic arrêté à votre demande" };
            }
        }
        var now = Sim.Now;
        return PosteDiagnostics.Verdict(c.Name, checks, now, (int)Math.Max(0, (now - started).TotalMilliseconds) + checks.Sum(x => x.DurationMs) / 4, Sim.Zone);
    }

    public async Task<QuickDiagResult> QuickDiagnosticAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        await Wait("quick", 600, 1200, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        var r = Sim.Live(machine);
        if (!Sim.Reachable(c.ObjectGuid, observation))
        {
            var down = new QuickRaw(SourceStatus.Unreachable, "poste injoignable");
            var raw0 = new QuickDiagRaw(r.Next(6000, 9000), down, null, null, down, null, down, null, null,
                new QuickRaw(SourceStatus.Ok, null), [(135, false), (445, false), (5985, false)], down, []);
            return PosteDiagnostics.QuickFacts(c.Name, raw0, now, Sim.Zone, Sim.Reader);
        }
        if (Sim.CimBlocked(machine))
        {
            // Quick diagnosis has no fallback: a CIM refusal concludes nothing and says so.
            var refused = new QuickRaw(SourceStatus.Refused, "CIM refusé (RPC filtré)");
            var rawRefused = new QuickDiagRaw(r.Next(3000, 6000), refused, null, null, refused, null, refused, null, null,
                new QuickRaw(SourceStatus.Ok, null), [(135, false), (445, true), (5985, false)], refused, []);
            return PosteDiagnostics.QuickFacts(c.Name, rawRefused, now, Sim.Zone, Sim.Reader);
        }
        var inventory = LiveSnapshot(machine, false, observation, now);
        var services = inventory.Services.ToDictionary(s => s.Name, StringComparer.OrdinalIgnoreCase);
        var ok = new QuickRaw(SourceStatus.Ok, null);
        var raw = new QuickDiagRaw(r.Next(2400, 7600), ok, inventory.Os!.Caption, inventory.Os.Version, ok, inventory.Os.LastBoot, ok, inventory.Volumes[0].FreeBytes, inventory.Volumes[0].SizeBytes,
            ok, [(135, true), (445, true), (5985, WinRmRunning(machine))], ok,
            [.. PosteDiagnostics.QuickServices.Select(n => services.TryGetValue(n, out var s) ? (n, true, (string?)s.State, (string?)s.StartMode) : (n, false, (string?)null, (string?)null))]);
        return PosteDiagnostics.QuickFacts(c.Name, raw, now, Sim.Zone, Sim.Reader);
    }

    private bool WinRmRunning(PosteMachine machine) =>
        Sim.ServiceStates(machine.Computer.ObjectGuid).TryGetValue("WinRM", out var state) ? state == "Running" : machine.Services.Any(s => s.Name == "WinRM" && s.State == "Running");

    // ------------------------------------------------------------------ WMI explorer

    private static readonly ImmutableArray<string> Namespaces =
    [
        "root\\cimv2", "root\\cimv2\\Security", "root\\cimv2\\Security\\MicrosoftVolumeEncryption", "root\\cimv2\\Security\\MicrosoftTpm", "root\\StandardCimv2",
        "root\\Microsoft", "root\\Microsoft\\Windows", "root\\Microsoft\\Windows\\Defender", "root\\Microsoft\\Windows\\Storage", "root\\Microsoft\\Windows\\TaskScheduler",
        "root\\Microsoft\\Windows\\DeviceGuard", "root\\SecurityCenter2", "root\\wmi", "root\\subscription", "root\\Policy", "root\\Interop",
    ];

    private static readonly ImmutableDictionary<string, ImmutableArray<string>> Classes = new Dictionary<string, ImmutableArray<string>>(StringComparer.OrdinalIgnoreCase)
    {
        ["root\\cimv2"] =
        [
            "Win32_BIOS", "Win32_Battery", "Win32_ComputerSystem", "Win32_InstalledWin32Program", "Win32_LogicalDisk", "Win32_NetworkAdapter", "Win32_NetworkAdapterConfiguration",
            "Win32_OperatingSystem", "Win32_PhysicalMemory", "Win32_PhysicalMemoryArray", "Win32_PnPEntity", "Win32_Printer", "Win32_Process", "Win32_Processor", "Win32_Product",
            "Win32_QuickFixEngineering", "Win32_Service", "Win32_Share", "Win32_StartupCommand", "Win32_TimeZone", "Win32_UserAccount", "Win32_VideoController",
        ],
        ["root\\cimv2\\Security\\MicrosoftVolumeEncryption"] = ["Win32_EncryptableVolume"],
        ["root\\cimv2\\Security\\MicrosoftTpm"] = ["Win32_Tpm"],
        ["root\\StandardCimv2"] = ["MSFT_NetAdapter", "MSFT_NetConnectionProfile", "MSFT_NetFirewallProfile", "MSFT_NetIPAddress"],
        ["root\\Microsoft\\Windows\\Defender"] = ["MSFT_MpComputerStatus", "MSFT_MpPreference", "MSFT_MpThreat"],
        ["root\\Microsoft\\Windows\\Storage"] = ["MSFT_Disk", "MSFT_PhysicalDisk", "MSFT_StorageReliabilityCounter", "MSFT_Volume"],
        ["root\\Microsoft\\Windows\\TaskScheduler"] = ["MSFT_ScheduledTask"],
        ["root\\Microsoft\\Windows\\DeviceGuard"] = ["Win32_DeviceGuard"],
        ["root\\SecurityCenter2"] = ["AntiVirusProduct", "FirewallProduct"],
        ["root\\wmi"] = ["BatteryCycleCount", "BatteryFullChargedCapacity", "BatteryStaticData", "MSStorageDriver_FailurePredictStatus", "WmiMonitorConnectionParams", "WmiMonitorID"],
    }.ToImmutableDictionary(StringComparer.OrdinalIgnoreCase);

    public async Task<WmiNamespaces> WmiNamespacesAsync(string dn, string? parent, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, _, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        Sim.Unreachable(c, observation);
        RequireCim(c, Sim.Machine(c));
        await Wait("wmi", 150, 450, cancellationToken).ConfigureAwait(false);
        var root = string.IsNullOrWhiteSpace(parent) ? "root" : parent.Trim();
        var children = Namespaces.Where(n => n.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase) && n.Count(ch => ch == '\\') == root.Count(ch => ch == '\\') + 1)
            .Select(n => new WmiNamespace(n[(n.LastIndexOf('\\') + 1)..], n, Namespaces.Any(o => o.StartsWith(n + "\\", StringComparison.OrdinalIgnoreCase)))).ToImmutableArray();
        return new WmiNamespaces(c.Name, root, children, FrenchText.Count(children.Length, "espace de noms", "espaces de noms") + " sous " + root + " sur " + c.Name + ".");
    }

    public async Task<WmiClasses> WmiClassesAsync(string dn, string ns, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(ns);
        var (c, _, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        Sim.Unreachable(c, observation);
        RequireCim(c, Sim.Machine(c));
        await Wait("wmi", 150, 450, cancellationToken).ConfigureAwait(false);
        var list = Classes.TryGetValue(ns, out var known) ? known : [];
        var classes = list.Select(n => PosteLabels.MsiProviderClasses.Contains(n)
            ? new WmiClassInfo(n, true, "Classe du fournisseur MSI bloquée : sa lecture vérifie chaque paquet installé.")
            : new WmiClassInfo(n, false, null)).ToImmutableArray();
        return new WmiClasses(c.Name, ns, classes, FrenchText.Count(classes.Length, "classe", "classes") + " dans " + ns + (classes.Any(x => x.Blocked) ? " (classes du fournisseur MSI bloquées)" : "") + ".");
    }

    public async Task<WmiQueryResult> WmiQueryAsync(string dn, WmiRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(request);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        Sim.Unreachable(c, observation);
        RequireCim(c, Sim.Machine(c));
        await Wait("wmi", 200, 600, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        var data = LiveSnapshot(machine, true, observation, now);
        var (schema, rows) = Instances(request.Class, data, machine);
        var filtered = rows;
        var note = "";
        if (request.Where is { } where)
        {
            var conditions = where.Split(" AND ", StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(p => p.Split('=', 2)).Where(p => p.Length == 2).Select(p => (Name: p[0].Trim(), Value: p[1].Trim().Trim('\'', '"'))).ToList();
            var indexed = conditions.Select(cond => (Index: schema.FindIndex(s => s.Name.Equals(cond.Name, StringComparison.OrdinalIgnoreCase)), cond.Value)).ToList();
            if (indexed.Count == 0 || indexed.Any(i => i.Index < 0))
            {
                note = " Filtre non interprété par la simulation : toutes les instances sont rendues.";
            }
            else
            {
                filtered = rows.Where(row => indexed.All(i => string.Equals(row[i.Index], i.Value, StringComparison.OrdinalIgnoreCase))).ToList();
            }
        }
        var truncated = filtered.Count > request.Limit;
        var shown = filtered.Take(request.Limit).Select(r => r.ToImmutableArray()).ToImmutableArray();
        var query = PosteWmi.Query(request);
        return new WmiQueryResult(c.Name, request.Namespace, request.Class, request.Where, request.Limit, truncated, [.. schema], shown,
            FrenchText.Count(shown.Length, "instance", "instances") + (truncated ? " (limite de " + FrenchText.Integer(request.Limit) + " atteinte)" : "") + " · réponse de " + c.Name + " · lecture seule, aucune méthode invoquée." + note,
            query, Sim.Live(machine).Next(80, 900));
    }

    private static (List<WmiProperty> Schema, List<string?[]> Rows) Instances(string cls, InventorySnapshot d, PosteMachine m)
    {
        static WmiProperty P(string name, string type, bool key = false) => new(name, type, key, key ? "key" : "read");
        static string? S(object? value) => value switch
        {
            null => null,
            DateTimeOffset at => at.UtcDateTime.ToString("yyyyMMddHHmmss.ffffff", CultureInfo.InvariantCulture) + "+000",
            bool b => b ? "True" : "False",
            IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
            _ => value.ToString(),
        };
        switch (cls.ToUpperInvariant())
        {
            case "WIN32_OPERATINGSYSTEM":
                return ([P("Caption", "string"), P("Version", "string"), P("BuildNumber", "string"), P("OSArchitecture", "string"), P("LastBootUpTime", "datetime"), P("InstallDate", "datetime"), P("TotalVisibleMemorySize", "uint64"), P("FreePhysicalMemory", "uint64"), P("OSLanguage", "uint32"), P("CSName", "string", true)],
                    [[d.Os!.Caption, d.Os.Version, d.Os.Build, d.Os.Architecture, S(d.Os.LastBoot), S(d.Os.InstallDate), S(d.Memory?.VisibleKb), S(d.Memory?.FreeKb), S(d.Os.Language), d.Computer]]);
            case "WIN32_COMPUTERSYSTEM":
                return ([P("Name", "string", true), P("Manufacturer", "string"), P("Model", "string"), P("Domain", "string"), P("DomainRole", "uint16"), P("TotalPhysicalMemory", "uint64"), P("NumberOfLogicalProcessors", "uint32"), P("PCSystemTypeEx", "uint16"), P("UserName", "string")],
                    [[d.Computer, d.System!.Manufacturer, d.System.Model, d.Os!.Domain, "1", S(d.System.TotalPhysicalMemory), S(d.System.LogicalProcessors), S(d.System.PcSystemType), d.System.UserName]]);
            case "WIN32_BIOS":
                return ([P("SMBIOSBIOSVersion", "string"), P("Manufacturer", "string"), P("ReleaseDate", "datetime"), P("SerialNumber", "string", true), P("SMBIOSMajorVersion", "uint16")],
                    [[d.Bios!.Version, d.Bios.Manufacturer, S(d.Bios.ReleaseDate), m.Serial, "3"]]);
            case "WIN32_PROCESSOR":
                return ([P("DeviceID", "string", true), P("Name", "string"), P("NumberOfCores", "uint32"), P("NumberOfLogicalProcessors", "uint32"), P("MaxClockSpeed", "uint32"), P("LoadPercentage", "uint16"), P("VirtualizationFirmwareEnabled", "boolean")],
                    [.. d.Processors.Select((p, i) => new string?[] { "CPU" + i.ToString(CultureInfo.InvariantCulture), p.Name, S(p.Cores), S(p.LogicalProcessors), S(p.MaxClockMhz), S(p.LoadPercent), S(p.VirtualizationFirmware) })]);
            case "WIN32_LOGICALDISK":
                return ([P("DeviceID", "string", true), P("VolumeName", "string"), P("FileSystem", "string"), P("Size", "uint64"), P("FreeSpace", "uint64"), P("DriveType", "uint32")],
                    [.. d.Volumes.Select(v => new string?[] { v.Id, v.Label, v.FileSystem, S(v.SizeBytes), S(v.FreeBytes), "3" })]);
            case "WIN32_SERVICE":
                return ([P("Name", "string", true), P("DisplayName", "string"), P("State", "string"), P("StartMode", "string"), P("ProcessId", "uint32"), P("ExitCode", "uint32")],
                    [.. d.Services.Select(s => new string?[] { s.Name, s.DisplayName, s.State, s.StartMode, S(s.ProcessId ?? 0), S(s.ExitCode ?? 0) })]);
            case "WIN32_PROCESS":
                return ([P("Handle", "string", true), P("Name", "string"), P("WorkingSetSize", "uint64"), P("CreationDate", "datetime")],
                    [.. d.Processes.Select(p => new string?[] { S(p.Id), p.Name, S(p.WorkingSetBytes), S(p.StartedAt) })]);
            case "WIN32_NETWORKADAPTERCONFIGURATION":
                return ([P("Index", "uint32", true), P("Description", "string"), P("MACAddress", "string"), P("IPAddress", "string[]"), P("DefaultIPGateway", "string[]"), P("DNSServerSearchOrder", "string[]"), P("DHCPEnabled", "boolean")],
                    [.. d.Network.Where(n => n.Ipv4.Length > 0).Select((n, i) => new string?[] { S(i), n.Name, n.Mac?.Replace('-', ':'), "{" + string.Join(", ", n.Ipv4) + "}", n.Gateway is null ? null : "{" + n.Gateway + "}", "{" + string.Join(", ", n.Dns) + "}", S(n.Dhcp) })]);
            case "WIN32_QUICKFIXENGINEERING":
                return ([P("HotFixID", "string", true), P("Description", "string"), P("InstalledOn", "string")],
                    [.. d.Hotfixes.Select(h => new string?[] { h.Id, h.Description, h.InstalledOn?.ToString("M'/'d'/'yyyy", CultureInfo.InvariantCulture) })]);
            case "WIN32_STARTUPCOMMAND":
                return ([P("Name", "string", true), P("Location", "string"), P("Command", "string")],
                    [.. d.Startup.Select(s => new string?[] { s.Name, s.Location, s.Executable })]);
            case "WIN32_ENCRYPTABLEVOLUME":
                return ([P("DriveLetter", "string", true), P("ProtectionStatus", "uint32"), P("ConversionStatus", "uint32"), P("EncryptionMethod", "uint32")],
                    [.. d.BitLocker.Select(v => new string?[] { v.Drive, S(v.Protection), S(v.Conversion), S(v.Method) })]);
            case "ANTIVIRUSPRODUCT":
                return ([P("displayName", "string"), P("productState", "uint32"), P("timestamp", "string")],
                    [.. d.Antivirus.Select(a => new string?[] { a.Name, S(a.ProductState), a.Timestamp?.ToString("R", CultureInfo.InvariantCulture) })]);
            case "WIN32_PRODUCT":
                return ([], []);
            default:
                return ([P("Name", "string", true)], []);
        }
    }

    // ------------------------------------------------------------------ probes and readings

    private static readonly ImmutableArray<string> BoardProbes = [.. PosteReadings.Catalog.SelectMany(r => r.Probes).Distinct(StringComparer.Ordinal)];

    public async Task<ProbeStore> ProbeStoreAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        await Wait("readings", 60, 160, cancellationToken).ConfigureAwait(false);
        var session = Sim.SessionProbes(c.ObjectGuid);
        if (session is not null)
        {
            return session;
        }
        if (observation?.Inventory is not { HasReading: true } inv)
        {
            return new ProbeStore(c.Name, null, [.. BoardProbes.Select(p => new ProbeStatus(p, ProbeState.NotRead, null, null, null, 0))], [], [], [], null);
        }
        var at = inv.CheckedAt!.Value.AddMinutes(-new SeededRandom(machine.Seed).Fork("probes/at").Next(5, 240));
        var stable = new SeededRandom(machine.Seed).Fork("probes");
        var data = machine.Snapshot(at, true, stable, Sim.ServiceStates(c.ObjectGuid), Sim.Boot(c.ObjectGuid), true);
        return Store(c, machine, data, at, stable);
    }

    private static ProbeStore Store(DirectoryComputer c, PosteMachine machine, InventorySnapshot data, DateTimeOffset at, SeededRandom r)
    {
        var statuses = BoardProbes.Select(p =>
        {
            if (p == "sec.avproducts" && machine.RefusedSources.Contains(InventoryCategories.Antivirus))
            {
                return new ProbeStatus(p, ProbeState.Refused, null, at, "Accès refusé (0x80070005)", 0);
            }
            if (p == "disk.reliability" && machine.MediaType == 3)
            {
                return new ProbeStatus(p, ProbeState.Absent, null, at, "Pilote sans compteurs de fiabilité", 0);
            }
            if (p is "hw.batterystatic" or "hw.batteryfullcharge" or "hw.batterycycles" && !machine.Laptop)
            {
                return new ProbeStatus(p, ProbeState.Read, at, at, null, 0);
            }
            var failed = r.Chance(2);
            return failed ? new ProbeStatus(p, ProbeState.Failed, at.AddDays(-r.Next(8, 30)), at, "Délai dépassé (WMI)", 0) : new ProbeStatus(p, ProbeState.Read, at, at, null, 1);
        }).ToImmutableArray();
        return new ProbeStore(c.Name, data, statuses, machine.VolumeHistory, machine.MonitorHistory, machine.DockHints, at);
    }

    public async Task<ProbeStore> CollectProbesAsync(string dn, ImmutableArray<string> probes, IProgress<PosteProgress>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        Sim.Unreachable(c, observation);
        RequireCim(c, machine);
        // Only the probes the board needs are read (PST-110); the others keep their stored state.
        var wanted = probes.IsDefaultOrEmpty ? BoardProbes : [.. BoardProbes.Where(probes.Contains)];
        var read = 0;
        try
        {
            for (var i = 0; i < wanted.Length; i++)
            {
                progress?.Report(new PosteProgress(i, wanted.Length, ProbeCatalog.Find(wanted[i])?.Name ?? wanted[i]));
                await Wait("probes", 25, 70, cancellationToken).ConfigureAwait(false);
                read = i + 1;
            }
        }
        catch (OperationCanceledException) when (read > 0)
        {
            // A stop keeps the probes already read (partial reading), the others stay as stored.
        }
        var now = Sim.Now;
        var previous = await ProbeStoreAsync(dn, CancellationToken.None).ConfigureAwait(false);
        var data = LiveSnapshot(machine, true, observation, now);
        var fresh = Store(c, machine, data, now, Sim.Live(machine));
        var done = wanted.Take(read).ToHashSet(StringComparer.Ordinal);
        var statuses = fresh.Probes.Select(p => done.Contains(p.ProbeId) ? p : previous.Probes.FirstOrDefault(o => o.ProbeId == p.ProbeId) ?? p with { State = ProbeState.NotRead }).ToImmutableArray();
        var c1 = data.Volumes.First();
        var store = fresh with { Probes = statuses, SystemVolumeHistory = [.. machine.VolumeHistory, new VolumeSample(now, c1.SizeBytes ?? 0, c1.FreeBytes ?? 0)] };
        Sim.RecordProbes(c.ObjectGuid, store);
        progress?.Report(new PosteProgress(wanted.Length, wanted.Length, read < wanted.Length ? "Relevé partiel enregistré" : "Relevé enregistré"));
        return store;
    }

    public async Task<SlowTriage> SlowTriageAsync(string dn, PosteHealthPolicy policy, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(policy);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        Sim.Unreachable(c, observation);
        RequireCim(c, Sim.Machine(c));
        await Wait("slow", 900, 1600, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        var data = LiveSnapshot(machine, true, observation, now);
        var (first, second) = TwoReads(machine, observation);
        var processes = PosteProcesses.Measure(c.Name, first, second, 1500, machine.Model.Threads, now, Sim.Zone);
        return PosteSlow.Triage(c.Name, data, processes, policy, now);
    }

    // ------------------------------------------------------------------ directory reads: logons, last user

    public async Task<LogonActivity> LogonByControllerAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, machine, _) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        var zone = Sim.Zone;
        var r = new SeededRandom(machine.Seed).Fork("logons");
        var stamp = AdValues.FromFileTime(c.LastLogonTimestamp);
        var controllers = ImmutableArray.CreateBuilder<ControllerLogon>();
        foreach (var dc in source.CurrentDirectory.Domain.Controllers)
        {
            await Wait("logon", 120, 320, cancellationToken).ConfigureAwait(false);
            if (dc.DnsName.StartsWith("DC02", StringComparison.OrdinalIgnoreCase) && r.Chance(15))
            {
                controllers.Add(new ControllerLogon(dc.DnsName, dc.Site, FactState.Unavailable, null, "Contrôleur injoignable : non lu."));
                continue;
            }
            var value = stamp is DateTimeOffset s ? Min(now, s.AddHours(r.Next(0, 300))) : (DateTimeOffset?)null;
            controllers.Add(new ControllerLogon(dc.DnsName, dc.Site, FactState.Observed, value, value is DateTimeOffset v ? PosteText.LocalDateTime(v, zone) + " (" + PosteText.Age(v, now) + ")" : "Jamais (attribut absent)"));
        }
        var built = controllers.ToImmutable();
        var latest = built.Where(x => x.LastLogon is not null).Select(x => x.LastLogon).Max();
        var read = built.Count(x => x.State == FactState.Observed);
        var coverage = FrenchText.Count(read, "contrôleur lu", "contrôleurs lus") + " sur " + FrenchText.Integer(built.Length);
        var text = latest is DateTimeOffset l
            ? "Dernière connexion connue le " + PosteText.LocalDateTime(l, zone) + " (" + coverage + ")" + (read < built.Length ? " : un contrôleur non lu peut connaître une connexion plus récente." : ".")
            : "Aucune connexion connue sur les contrôleurs lus (" + coverage + ").";
        var facts = ImmutableArray.Create(
            PosteText.Fact("lastLogonTimestamp", stamp is DateTimeOffset st ? PosteText.LocalDateTime(st, zone) + " · répliqué, approximatif à 14 jours près" : "Absent", stamp is null ? FactState.Unknown : FactState.Estimated, "Annuaire (attribut répliqué)",
                "Une connexion ne prouve pas une présence actuelle.", at: now, tone: Tone.Info),
            PosteText.Fact("lastLogon par contrôleur", text, read == built.Length ? FactState.Observed : FactState.Estimated, "Lecture de chaque contrôleur (non répliqué)", "Rapprochez de la dernière présence réseau mesurée.", at: now, tone: read == built.Length ? Tone.Ok : Tone.Warn));
        return new LogonActivity(c.Name, now, stamp, stamp is DateTimeOffset s2 ? PosteText.LocalDateTime(s2, zone) : "Absent", built, latest, coverage, text, facts);
    }

    private static DateTimeOffset Min(DateTimeOffset a, DateTimeOffset b) => a < b ? a : b;

    public async Task<LastUserDetection> DetectLastUserAsync(string dn, IProgress<PosteProgress>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        var reachable = Sim.Reachable(c.ObjectGuid, observation);
        var open = Sim.Answers(c.ObjectGuid, observation) == true;
        var r = Sim.Live(machine);
        var user = machine.User;
        var attempts = ImmutableArray.CreateBuilder<DetectionAttempt>();
        string? candidate = null;
        // CIM refused (PST-011, PST-023): the CIM methods conclude nothing; the single SYSTEM task needs the fallback read of the session.
        var blocked = reachable && Sim.CimBlocked(machine);
        var steps = new (string Method, Func<(string Status, string Detail, string? Candidate)> Run)[]
        {
            ("Association locale", () => user is null ? ("VIDE", "Aucune association mémorisée", null) : ("OK", "Association connue immédiatement (" + user.Name + ")", null)),
            ("CIM utilisateur courant (Win32_ComputerSystem)", () => !reachable ? ("INJOIGNABLE", "Poste muet au ping : CIM non lancé", null) : blocked ? ("REFUSE", "CIM refusé (RPC filtré par le pare-feu du poste)", null) : open && user is not null ? ("OK", SimulationProfile.NetbiosName + "\\" + user.Login, user.Login) : ("VIDE", "Console vide", null)),
            ("LogonUI (dernier utilisateur affiché)", () => !reachable ? ("IGNORE", "Non tenté", null) : blocked ? ("REFUSE", "Registre lu par CIM : refusé", null) : user is not null ? ("OK", SimulationProfile.NetbiosName + "\\" + user.Login, user.Login) : ("VIDE", "Aucun nom affiché", null)),
            ("WinRM (quser)", () => reachable && WinRmRunning(machine) ? (open && user is not null ? "OK" : "VIDE", open && user is not null ? user.Login + " (console, active)" : "Aucune session", open ? user?.Login : null) : ("IGNORE", "WinRM fermé sur le poste : méthode non plausible", null)),
            ("Registre distant", () => ("IGNORE", "Non autorisé (RemoteRegistry arrêté, aucune modification de service)", null)),
            ("Profils CIM (Win32_UserProfile)", () => !reachable ? ("IGNORE", "Non tenté", null) : blocked ? ("REFUSE", "CIM refusé", null) : ("OK", "Profil le plus récent : " + (user?.Login ?? "aucun profil de domaine"), user?.Login)),
            ("Journal 4624", () => ("IGNORE", "Désactivé par la configuration", null)),
            ("Tâche SYSTEM unique", () => !blocked || candidate is not null ? ("IGNORE", "Non nécessaire : une méthode précédente a répondu ou CIM est ouvert", null)
                : PosteSession.For(source).ConsumeReadFallback(c.DistinguishedName, "détection de l’utilisateur", Sim.Now)
                    ? (user is not null && open ? "OK" : "VIDE", user is not null && open ? "Tâche planifiée unique créée, lue puis supprimée : " + user.Login + " (lecture de repli consommée)" : "Tâche planifiée unique : aucune session ouverte (lecture de repli consommée)", user is not null && open ? user.Login : null)
                    : ("IGNORE", "Non tenté : lecture de repli non autorisée (vue Intervenir)", null)),
        };
        var order = 0;
        foreach (var (method, run) in steps)
        {
            order++;
            progress?.Report(new PosteProgress(order, steps.Length, method));
            await Wait("lastuser", 60, 220, cancellationToken).ConfigureAwait(false);
            var (status, detail, found) = run();
            candidate ??= found;
            attempts.Add(new DetectionAttempt(order, method, status, PosteDiagnostics.StatusLabel(status) switch { "VIDE" => "Rien trouvé", var l => l }, status switch { "OK" => Tone.Ok, "VIDE" => Tone.Info, "IGNORE" => Tone.Off, _ => Tone.Warn }, r.Next(20, 2900), detail, found));
            if (found is not null && method.StartsWith("CIM", StringComparison.Ordinal))
            {
                break;
            }
        }
        var now = Sim.Now;
        UserRef? verified = null;
        if (candidate is not null)
        {
            var account = source.CurrentDirectory.Users.FirstOrDefault(u => string.Equals(u.SamAccountName, candidate, StringComparison.OrdinalIgnoreCase));
            if (account is not null)
            {
                verified = new UserRef(account.DisplayName ?? account.Cn, account.SamAccountName, account.DistinguishedName, account.ObjectGuid);
                Sim.RecordDetected(c.ObjectGuid, verified, now, attempts.Last(a => a.Candidate is not null).Method.Split(' ')[0]);
            }
        }
        var association = Association(machine, observation, Sim.Zone);
        var verdict = verified is not null
            ? "Utilisateur détecté : " + verified.Name + " (" + verified.Login + "), vérifié par identité AD exacte." + (association.Badge == AssociationBadge.Contradictory ? " L’association déclarée est conservée : contradiction signalée." : "")
            : reachable ? "Aucun utilisateur détecté : l’association existante est conservée." : "Lecture distante indisponible : l’association existante est conservée.";
        return new LastUserDetection(c.Name, now, attempts.ToImmutable(), verified, verified is not null, verdict, association, 25);
    }

    // ------------------------------------------------------------------ secrets

    public async Task<LapsView> LapsAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, _, _) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        await Wait("secrets", 200, 500, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        if (PosteSimulation.LapsDenied(machine) && Sim.OtherAccount(c.ObjectGuid, "laps") is null)
        {
            // The refusal is remembered for this workstation and this resource only (PST-062): another account is offered.
            return PosteSecrets.Laps(c.Name, "AccessDenied", "NotAttempted", false, false, "WindowsLaps", null, null, null, Sim.Reader, now, Sim.Zone);
        }
        var expiration = AdValues.FromFileTime(c.LapsExpiration);
        var view = expiration is null || c.Laps == LapsKind.None
            ? PosteSecrets.Laps(c.Name, "NotPublished", "NotAttempted", false, false, "WindowsLaps", null, null, null, Sim.Reader, now, Sim.Zone)
            : c.Laps == LapsKind.Legacy
                ? PosteSecrets.Laps(c.Name, "OK", "NotEncrypted", true, true, "LegacyLaps", expiration, "Administrateur", null, Sim.Reader, now, Sim.Zone)
                : PosteSecrets.Laps(c.Name, "OK", "OK", true, true, "WindowsLaps", expiration, "Administrateur", SimulationProfile.NetbiosName + "\\GG-Admins-Postes", Sim.Reader, now, Sim.Zone);
        Sim.RecordLapsIndex(c.ObjectGuid, now);
        return view;
    }

    public async Task<SecretReading> RevealLapsAsync(string dn, CancellationToken cancellationToken)
    {
        var view = await LapsAsync(dn, cancellationToken).ConfigureAwait(false);
        if (!view.CanReveal)
        {
            throw new DomeniaOperationException(PosteErrors.Refused, "Aucun mot de passe LAPS lisible pour ce poste (" + view.StateLabel.ToLowerInvariant() + ") : rien n’est révélé.");
        }
        var c = Sim.Find(dn);
        var machine = Sim.Machine(c);
        var r = new SeededRandom(machine.Seed).Fork("laps/" + (c.LapsExpiration ?? 0).ToString(CultureInfo.InvariantCulture));
        const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789#%+=";
        var password = new StringBuilder(20);
        for (var i = 0; i < 20; i++)
        {
            password.Append(Alphabet[r.Next(Alphabet.Length)]);
        }
        return new SecretReading("laps", c.Name, "Administrateur", null, password.ToString(), [], SecretPolicy.RevealSeconds, SecretPolicy.ExtensionSeconds, SecretPolicy.Extensions, SecretPolicy.ClipboardLimit,
            "Valeur fictive de la simulation : aucun mot de passe réel n’existe dans l’annuaire fictif. Jamais journalisée, gardée ni exportée.", true, Sim.Now);
    }

    private ImmutableArray<BitLockerKeyInfo> Keys(DirectoryComputer c, PosteMachine machine)
    {
        if (machine.BitLockerConversion == 0)
        {
            return [];
        }
        var r = new SeededRandom(machine.Seed).Fork("bitlocker/keys");
        var count = r.Chance(30) ? 2 : 1;
        var keys = ImmutableArray.CreateBuilder<BitLockerKeyInfo>();
        for (var i = 0; i < count; i++)
        {
            var created = c.WhenCreated.AddDays(1 + i * r.Next(90, 400));
            var bytes = new byte[16];
            BitConverter.TryWriteBytes(bytes.AsSpan(0, 8), r.NextUInt64());
            BitConverter.TryWriteBytes(bytes.AsSpan(8, 8), r.NextUInt64());
            var guid = new Guid(bytes);
            var name = created.ToOffset(TimeSpan.FromHours(1)).ToString("yyyy'-'MM'-'dd'T'HH':'mm':'sszzz", CultureInfo.InvariantCulture) + "{" + guid.ToString("D").ToUpperInvariant() + "}";
            var info = PosteSecrets.KeyInfo(name, DistinguishedName.Child("CN", name, c.DistinguishedName), guid, created, "C:", Sim.Zone);
            if (info is not null)
            {
                keys.Add(info);
            }
        }
        return [.. keys.OrderByDescending(k => k.CreatedAt)];
    }

    public async Task<BitLockerList> BitLockerListAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var (c, machine, _) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        await Wait("secrets", 200, 500, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        if (PosteSimulation.BitLockerDenied(machine))
        {
            return new BitLockerList(c.Name, now, FactState.Refused, "Lecture BitLocker refusée pour ce compte : aucune conclusion sur la présence de clés. Un autre compte sera proposé (invite Windows) avant toute nouvelle lecture.",
                [], PosteSecrets.ColumnHeader(true, false), Sim.Reader, true,
                [PosteText.Fact("Lecture BitLocker", "Refusée", FactState.Refused, "Contrôleur de domaine", "Refus limité à la ressource BitLocker : le canal annuaire reste utilisable. Refus mémorisé pour ce poste.", at: now)]);
        }
        var keys = Keys(c, machine);
        Sim.RecordBitLockerIndex(c.ObjectGuid, keys.Length, now);
        var status = keys.IsEmpty
            ? "Aucune clé visible sous ce poste : aucun résultat ne prouve pas l’absence de clé (droits, autre emplacement)."
            : FrenchText.Count(keys.Length, "objet de récupération", "objets de récupération") + " sous " + c.Name + " ; métadonnées seulement, clé non lue.";
        return new BitLockerList(c.Name, now, FactState.Observed, status, keys, PosteSecrets.ColumnHeader(true, false), Sim.Reader, false,
            [PosteText.Fact("Recherche", "Un niveau sous le poste (OneLevel), 256 objets au plus", FactState.Observed, "Contrôleur " + (Sim.Controller ?? ""), "msFVE-RecoveryPassword n’est pas demandé par cette liste.", at: now, tone: Tone.Info)]);
    }

    public async Task<SecretReading> RevealBitLockerAsync(string dn, string keyDn, string expectedId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(keyDn);
        ArgumentNullException.ThrowIfNull(expectedId);
        var (c, machine, _) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        if (!PosteSecrets.IsDirectChild(c.DistinguishedName, keyDn))
        {
            throw new DomeniaOperationException(PosteErrors.KeyNotChild, PosteErrors.KeyNotChildMessage);
        }
        await Wait("secrets", 200, 500, cancellationToken).ConfigureAwait(false);
        if (PosteSimulation.BitLockerDenied(machine) && Sim.OtherAccount(c.ObjectGuid, "bitlocker") is null)
        {
            throw new DomeniaOperationException(PosteErrors.Refused, "Lecture de la clé refusée pour ce compte : rien n’est révélé. Un autre compte sera proposé (invite Windows).");
        }
        var key = Keys(c, machine).FirstOrDefault(k => PosteDirectoryWrites.SameDn(k.Dn, keyDn))
            ?? throw new DomeniaOperationException(PosteErrors.KeyNotChild, "Cette clé n’existe pas sous le poste ouvert : aucune valeur n’est lue.");
        // The identifier read back with the key must be the one the operator chose (Domenia 1 Mismatch): no value otherwise.
        if (!PosteSecrets.MatchesExpected(key.KeyGuid, expectedId))
        {
            throw new DomeniaOperationException(PosteErrors.KeyMismatch, PosteErrors.KeyMismatchMessage);
        }
        var r = new SeededRandom(machine.Seed).Fork("bitlocker/" + key.KeyGuid);
        // A recovery password: eight blocks of six digits, each block a multiple of 11 (format checked by Windows).
        var value = string.Join("-", Enumerable.Range(0, 8).Select(_ => (r.Next(0, 65536) * 11).ToString("000000", CultureInfo.InvariantCulture)));
        return new SecretReading("bitlocker", c.Name, key.RecoveryId, key.KeyGuid, null, PosteSecrets.Blocks(value), SecretPolicy.RevealSeconds, SecretPolicy.ExtensionSeconds, SecretPolicy.Extensions, SecretPolicy.ClipboardLimit,
            "Clé fictive de la simulation : comparez l’identifiant " + key.RecoveryId + " avec l’écran du poste avant de dicter. Jamais journalisée, gardée ni exportée.", true, Sim.Now);
    }

    /// <summary>
    /// Proposal of another account for a refused secret resource (PST-060, PST-062): the fictitious Windows prompt accepts it,
    /// the refusal remembered for this workstation and this resource is lifted. No password is ever asked or kept here.
    /// </summary>
    public async Task<OtherAccountResult> UseOtherAccountAsync(string dn, string resource, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        if (resource is not ("laps" or "bitlocker"))
        {
            throw new DomeniaOperationException(PosteErrors.Refused, "Ressource de secret inconnue : laps ou bitlocker seulement. Aucun compte n’a été proposé.");
        }
        var (c, machine, _) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        await Wait("secrets", 150, 400, cancellationToken).ConfigureAwait(false);
        var denied = resource == "laps" ? PosteSimulation.LapsDenied(machine) : PosteSimulation.BitLockerDenied(machine);
        if (!denied)
        {
            return new OtherAccountResult(c.Name, resource, false, Sim.Reader,
                "Aucun refus mémorisé pour cette ressource sur ce poste : le compte de la session suffit, aucun autre compte n’est proposé.", true);
        }
        var account = SimulationProfile.NetbiosName + "\\gg-secours-secrets";
        Sim.AcceptOtherAccount(c.ObjectGuid, resource, account);
        return new OtherAccountResult(c.Name, resource, true, account,
            "Compte " + account + " accepté pour la lecture " + (resource == "laps" ? "LAPS" : "BitLocker") + " de " + c.Name
            + " : le refus est levé pour cette seule ressource, pas pour les autres. Aucune valeur lue ici, aucun mot de passe demandé.", true);
    }

    /// <summary>
    /// Non-secret index of the secrets of the working OU (PST-066): counts and rows built from the local base and the reads of
    /// this session; entries written for an older holder of the same name are left out (PST-065). No key, no value.
    /// </summary>
    public async Task<SecretsIndex> SecretsIndexAsync(ScopeSelection scope, IProgress<PosteProgress>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scope);
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        await Wait("secrets", 500, 1200, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        var observations = state.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        const int Cap = 50_000;
        var computers = source.CurrentDirectory.Computers
            .Where(c => ScopeRules.Contains(scope, c.DistinguishedName) && (c.UserAccountControl & AdValues.ServerTrustAccount) == 0)
            .OrderBy(c => c.Name, PosteText.French).ToList();
        var rows = ImmutableArray.CreateBuilder<SecretsIndexRow>();
        var withKeys = 0;
        var withoutKeys = 0;
        var refused = 0;
        var lapsExpired = 0;
        var lapsMissing = 0;
        var done = 0;
        foreach (var c in computers)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var machine = Sim.Machine(c);
            observations.TryGetValue(c.ObjectGuid, out var observation);
            int? keys;
            FactState bitLockerState;
            if (PosteSimulation.BitLockerDenied(machine) && Sim.OtherAccount(c.ObjectGuid, "bitlocker") is null)
            {
                keys = null;
                bitLockerState = FactState.Refused;
                refused++;
            }
            else if (Sim.BitLockerIndex(c.ObjectGuid) is (int readKeys, DateTimeOffset readAt))
            {
                keys = readKeys;
                bitLockerState = FactState.Observed;
                if (readKeys > 0)
                {
                    withKeys++;
                }
                else
                {
                    withoutKeys++;
                }
            }
            else if (Sim.StoredBitLockerIndex(machine) is (int storedKeys, DateTimeOffset storedAt, Guid holder)
                     && PosteSecrets.IndexApplies(holder, storedAt, c.ObjectGuid, c.WhenCreated))
            {
                keys = storedKeys;
                bitLockerState = FactState.Estimated;
                if (storedKeys > 0)
                {
                    withKeys++;
                }
                else
                {
                    withoutKeys++;
                }
            }
            else
            {
                keys = null;
                bitLockerState = FactState.Unknown;
                withoutKeys++;
            }
            var expiration = AdValues.FromFileTime(c.LapsExpiration);
            var expired = c.Laps != LapsKind.None && expiration is DateTimeOffset exp && exp < now;
            if (expired)
            {
                lapsExpired++;
            }
            else if (c.Laps == LapsKind.None)
            {
                lapsMissing++;
            }
            rows.Add(new SecretsIndexRow(c.DistinguishedName, c.Name, keys, bitLockerState, expiration, expired, c.Laps.ToString()));
            done++;
            if (done % 25 == 0 || done == computers.Count)
            {
                progress?.Report(new PosteProgress(done, computers.Count, "Index des secrets de l’OU"));
            }
            if (rows.Count >= Cap)
            {
                break;
            }
        }
        var truncated = computers.Count > rows.Count;
        var summary = FrenchText.Count(rows.Count, "poste", "postes") + " de l’OU " + scope.Label
            + " · " + FrenchText.Integer(withKeys) + " avec au moins une clé BitLocker lisible, " + FrenchText.Integer(refused) + " lecture refusée"
            + " · " + FrenchText.Integer(lapsExpired) + " expiration LAPS échue, " + FrenchText.Integer(lapsMissing) + " sans publication LAPS"
            + (truncated ? " · liste tronquée à " + FrenchText.Integer(Cap) + " lignes" : "") + " ; aucune clé, aucune valeur.";
        return new SecretsIndex(scope, now, computers.Count, withKeys, withoutKeys, refused, lapsExpired, lapsMissing, truncated, summary, rows.ToImmutable());
    }

    /// <summary>The user account of a session login (domain or UPN prefix removed), for the card link of PST-073.</summary>
    public async Task<UserRef?> FindAccountAsync(string login, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrEmpty(login);
        await Wait("account", 40, 120, cancellationToken).ConfigureAwait(false);
        var wanted = login.Contains('@', StringComparison.Ordinal) ? login[..login.IndexOf('@')] : login[(login.LastIndexOf('\\') + 1)..];
        if (wanted.Length == 0)
        {
            return null;
        }
        var user = source.CurrentDirectory.Users.FirstOrDefault(u => string.Equals(u.SamAccountName, wanted, StringComparison.OrdinalIgnoreCase));
        return user is null ? null : new UserRef(user.DisplayName ?? user.Cn, user.SamAccountName, user.DistinguishedName, user.ObjectGuid);
    }

    // ------------------------------------------------------------------ groups (local choice of a membership)

    public async Task<ImmutableArray<DnRef>> GroupsAsync(string? text, CancellationToken cancellationToken)
    {
        await Wait("groups", 40, 120, cancellationToken).ConfigureAwait(false);
        var needle = FrenchText.Fold((text ?? "").Trim());
        return
        [
            .. source.CurrentDirectory.Groups.Where(g => needle.Length == 0 || FrenchText.Fold(g.Name).Contains(needle, StringComparison.Ordinal))
                .OrderBy(g => g.Name, PosteText.French).Take(50).Select(g => new DnRef(g.DistinguishedName, g.Name)),
        ];
    }
}
