using System.Collections.Immutable;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

internal sealed record TaskCimQuery(string Category, string Namespace, string Class, string Fields, string Filter, int Cap)
{
    internal string[] Properties => Fields.Split(',');
}

/// <summary>Finite local projections. The remote result never supplies a query, registry path or command.</summary>
internal static class RemoteTaskReadInventory
{
    private const string Cim = @"root\cimv2";
    internal static TaskCimQuery[] Queries(RemoteTaskReadKind kind) =>
    [
        new(InventoryCategories.System, Cim, "Win32_ComputerSystem", "Name,Domain,Manufacturer,Model,TotalPhysicalMemory,NumberOfLogicalProcessors,UserName,DomainRole,SystemType,PCSystemType", "", 2),
        new(InventoryCategories.System, Cim, "Win32_OperatingSystem", "Caption,Version,BuildNumber,OSLanguage,OSArchitecture,InstallDate,LastBootUpTime,LocalDateTime,TotalVisibleMemorySize,FreePhysicalMemory,SystemDrive", "", 2),
        new(InventoryCategories.Volumes, Cim, "Win32_LogicalDisk", "DeviceID,VolumeName,FileSystem,Size,FreeSpace", "DriveType=3", 32),
        .. kind == RemoteTaskReadKind.Diagnostic ? [] : new TaskCimQuery[]
        {
            new(InventoryCategories.System, Cim, "Win32_SystemEnclosure", "SerialNumber,ChassisTypes", "", 4),
            new(InventoryCategories.Bios, Cim, "Win32_BIOS", "Manufacturer,BIOSVersion,SMBIOSBIOSVersion,ReleaseDate,SerialNumber", "", 1),
            new(InventoryCategories.Processor, Cim, "Win32_Processor", "Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed,LoadPercentage,Architecture,VirtualizationFirmwareEnabled", "", 16),
            new(InventoryCategories.Memory, Cim, "Win32_PhysicalMemory", "DeviceLocator,Capacity,Speed,Manufacturer,PartNumber", "", 64),
            new(InventoryCategories.Memory, Cim, "Win32_PhysicalMemoryArray", "Use,MemoryDevices,MaxCapacityEx", "", 8),
            new(InventoryCategories.Network, Cim, "Win32_NetworkAdapter", "Name,NetConnectionStatus,Speed,MACAddress", "PhysicalAdapter=True", 32),
            new(InventoryCategories.Network, Cim, "Win32_NetworkAdapterConfiguration", "Description,MACAddress,IPAddress,IPSubnet,DefaultIPGateway,DNSServerSearchOrder,DHCPEnabled", "IPEnabled=True", 32),
            new(InventoryCategories.Tpm, @"root\cimv2\Security\MicrosoftTpm", "Win32_Tpm", "IsEnabled_InitialValue,IsActivated_InitialValue,IsOwned_InitialValue,SpecVersion", "", 1),
            new(InventoryCategories.BitLocker, @"root\cimv2\Security\MicrosoftVolumeEncryption", "Win32_EncryptableVolume", "DriveLetter,ProtectionStatus,ConversionStatus,EncryptionMethod", "", 32),
            new(InventoryCategories.Antivirus, @"root\SecurityCenter2", "AntiVirusProduct", "displayName,productState", "", 8),
            new(InventoryCategories.Antivirus, @"root\Microsoft\Windows\Defender", "MSFT_MpComputerStatus", "AntivirusEnabled,RealTimeProtectionEnabled,BehaviorMonitorEnabled,AntivirusSignatureAge,QuickScanAge,FullScanAge,AMProductVersion,AMRunningMode", "", 1),
            new(InventoryCategories.Hotfixes, Cim, "Win32_QuickFixEngineering", "HotFixID,Description,InstalledOn", "", 256),
            new(InventoryCategories.Services, Cim, "Win32_Service", "Name,DisplayName,State,StartMode,DelayedAutoStart,ProcessId,StartName,ExitCode,Description", "", 256),
        },
    ];

    internal static string Body(RemoteTaskReadKind kind)
    {
        var script = new StringBuilder("$domeniaWatch=[Diagnostics.Stopwatch]::StartNew();$domeniaSources=[Collections.Generic.List[object]]::new()\n");
        script.AppendLine("""
            function Domenia-Value($v) {
                if($null -eq $v){return $null}
                if($v -is [datetime]){return $v.ToUniversalTime().ToString('yyyyMMddHHmmss.ffffff',[Globalization.CultureInfo]::InvariantCulture)+'+000'}
                if($v -is [array]){if($v.Count -gt 64){throw 'Valeur trop grande'};return ,@($v | ForEach-Object {Domenia-Value $_})}
                if($v -is [bool]){return $v}
                $s=[Convert]::ToString($v,[Globalization.CultureInfo]::InvariantCulture)
                if($s.Length -gt 4096){throw 'Valeur trop longue'};return $s
            }
            function Domenia-Cim($ns,$class,$properties,$filter,$cap) {
                $rows=[Collections.Generic.List[object]]::new();$code=0;$truncated=$false
                if($domeniaWatch.Elapsed.TotalSeconds -gt 22){$code=1460}
                else {try {
                    $parameters=@{Namespace=$ns;ClassName=$class;Property=$properties;OperationTimeoutSec=2;ErrorAction='Stop'}
                    if($filter){$parameters.Filter=$filter}
                    Get-CimInstance @parameters | Select-Object -First ($cap+1) | ForEach-Object {
                        if($rows.Count -ge $cap){$truncated=$true}
                        else {try {$row=[ordered]@{};foreach($p in $properties){$row[$p]=Domenia-Value $_.$p};$rows.Add([pscustomobject]$row)} catch {$truncated=$true}}
                    }
                } catch {$code=$_.Exception.HResult}}
                $domeniaSources.Add([pscustomobject]@{Class=$class;Code=$code;Truncated=$truncated;Rows=$rows.ToArray()})
            }
            """);
        foreach (var q in Queries(kind))
        {
            script.Append("Domenia-Cim '").Append(q.Namespace).Append("' '").Append(q.Class).Append("' @('")
                .Append(string.Join("','", q.Properties)).Append("') '").Append(q.Filter).Append("' ").Append(q.Cap.ToString(CultureInfo.InvariantCulture)).Append('\n');
        }
        // Missing keys are meaningful only when the registry open and native reads succeeded.
        script.AppendLine("""
            $reboot=[ordered]@{Cbs=$null;Update=$null;Rename=$null};$rebootCode=0
            try {
                $h=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
                try {
                    foreach($item in @(@('Cbs','SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'),@('Update','SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))) {
                        $k=$h.OpenSubKey($item[1],$false);try {$reboot[$item[0]]=($null -ne $k)} finally {if($k){$k.Dispose()}}
                    }
                    $k=$h.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager',$false)
                    try {if(-not $k){throw 'Session Manager absent'};$v=$k.GetValue('PendingFileRenameOperations',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);if($null -ne $v -and $v -isnot [string[]]){throw 'Type illisible'};$reboot.Rename=($null -ne $v -and $v.Count -gt 0)} finally {if($k){$k.Dispose()}}
                } finally {$h.Dispose()}
            } catch {$rebootCode=$_.Exception.HResult}
            $domeniaResult=[pscustomobject]@{Format='Domenia.TaskInventory/1';Computer=[Environment]::MachineName;Sources=$domeniaSources.ToArray();Reboot=[pscustomobject]@{Code=$rebootCode;Values=[pscustomobject]$reboot}}
            """);
        return script.ToString();
    }

    internal sealed record Reply(TaskCimQuery Query, int Code, bool Truncated, IReadOnlyList<WmiInstance> Rows);
    internal static InventorySnapshot Parse(JsonElement root, RemoteTaskReadPlan plan, DateTimeOffset now)
    {
        RemoteTaskReadJson.Object(root, "Format", "Computer", "Sources", "Reboot");
        if (RemoteTaskReadJson.Text(root, "Format") != "Domenia.TaskInventory/1"
            || !string.Equals(RemoteTaskReadJson.Text(root, "Computer"), plan.Host.Split('.')[0], StringComparison.OrdinalIgnoreCase)) { throw new JsonException(); }
        var expected = Queries(plan.Kind); var source = root.GetProperty("Sources");
        if (source.ValueKind != JsonValueKind.Array || source.GetArrayLength() != expected.Length) { throw new JsonException(); }
        var replies = new List<Reply>();
        foreach (var row in source.EnumerateArray())
        {
            RemoteTaskReadJson.Object(row, "Class", "Code", "Truncated", "Rows");
            var query = expected.SingleOrDefault(q => q.Class == RemoteTaskReadJson.Text(row, "Class")) ?? throw new JsonException();
            if (replies.Any(r => r.Query == query)) { throw new JsonException(); }
            var code = RemoteTaskReadJson.Int(row, "Code"); var truncated = RemoteTaskReadJson.Bool(row, "Truncated"); var rows = row.GetProperty("Rows");
            if (rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > query.Cap) { throw new JsonException(); }
            var instances = new List<WmiInstance>();
            foreach (var item in rows.EnumerateArray())
            {
                RemoteTaskReadJson.Object(item, query.Properties);
                instances.Add(new(item.EnumerateObject().ToDictionary(p => p.Name, p => RemoteTaskReadJson.Value(p.Value), StringComparer.OrdinalIgnoreCase)));
            }
            replies.Add(new(query, code, truncated, instances));
        }
        var identity = replies.Single(r => r.Query.Class == "Win32_ComputerSystem");
        if (identity.Code != 0 || identity.Truncated || identity.Rows.Count != 1
            || !string.Equals(identity.Rows[0].Text("Name"), plan.Host.Split('.')[0], StringComparison.OrdinalIgnoreCase)
            || identity.Rows[0].Int("DomainRole") is not (>= 0 and <= 3)) { throw new JsonException("Identité système non qualifiée."); }
        var reboot = root.GetProperty("Reboot"); RemoteTaskReadJson.Object(reboot, "Code", "Values");
        var flags = reboot.GetProperty("Values"); RemoteTaskReadJson.Object(flags, "Cbs", "Update", "Rename");
        var values = new[] { "Cbs", "Update", "Rename" }.Select(k => flags.GetProperty(k).ValueKind == JsonValueKind.Null ? (bool?)null : RemoteTaskReadJson.Bool(flags, k)).ToArray();
        return WmiWorkstationReader.ProjectTaskSnapshot(plan, replies, RemoteTaskReadJson.Int(reboot, "Code"), values, now);
    }
}

public sealed partial class WmiWorkstationReader
{
    /// <summary>Projects a bounded, already received task reply; every provider is an in-memory lookup, never a new connection.</summary>
    internal static InventorySnapshot ProjectTaskSnapshot(RemoteTaskReadPlan plan, IReadOnlyList<RemoteTaskReadInventory.Reply> replies, int rebootCode, bool?[] reboot, DateTimeOffset now)
    {
        IEnumerable<WmiInstance> Rows(string ns, string query, TimeSpan _)
        {
            var name = query.Split(" FROM ", StringSplitOptions.None).ElementAtOrDefault(1)?.Split(' ')[0];
            var found = replies.SingleOrDefault(r => r.Query.Class.Equals(name, StringComparison.OrdinalIgnoreCase) && r.Query.Namespace.Equals(ns, StringComparison.OrdinalIgnoreCase));
            if (found is null) { throw new COMException("Source non couverte par cette lecture ponctuelle.", unchecked((int)0x8004100C)); }
            foreach (var row in found.Rows)
            {
                if (plan.Kind == RemoteTaskReadKind.Diagnostic && name == "Win32_LogicalDisk")
                {
                    var drive = replies.Single(r => r.Query.Class == "Win32_OperatingSystem").Rows.SingleOrDefault()?.Text("SystemDrive");
                    if (!string.Equals(row.Text("DeviceID"), drive, StringComparison.OrdinalIgnoreCase)) { continue; }
                }
                yield return row;
            }
            if (found.Code != 0) { throw new COMException("Source locale refusée ou interrompue.", found.Code == 1460 ? unchecked((int)0x800705B4) : found.Code); }
            if (found.Truncated) { throw new TimeoutException("Plafond local atteint."); }
        }
        var time = new TaskReplyClock(now);
        using var session = new CimSession(plan.Host, TimeSpan.FromSeconds(30), time) { ReadOverride = Rows,
            RegistryOverride = (_, _) => new(50, null) };
        var access = new List<SourceAccess>(); var snapshot = Empty(plan.Host, now, plan.Kind == RemoteTaskReadKind.InventoryFull, InventoryTransport.ScheduledTask);
        if (plan.Kind == RemoteTaskReadKind.Diagnostic)
        {
            snapshot = ReadDiagnosticSystem(session, snapshot, access, true);
            snapshot = ReadDiagnosticDisk(session, snapshot, access, snapshot.Os?.SystemDrive);
        }
        else
        {
            snapshot = ReadSystem(session, snapshot, access, CancellationToken.None);
            snapshot = ReadBios(session, snapshot, access, CancellationToken.None);
            // Domenia 1's local fallback reports the BIOS serial, also when the enclosure provider is absent.
            // A partial/refused BIOS source must not fill an unknown identity field from an unqualified row.
            var bios = replies.Single(r => r.Query.Class == "Win32_BIOS");
            if (snapshot.System is { SerialNumber: null } system && bios is { Code: 0, Truncated: false }
                && bios.Rows.Count == 1 && bios.Rows[0].Text("SerialNumber") is { Length: > 0 } serial)
            { snapshot = snapshot with { System = system with { SerialNumber = serial } }; }
            snapshot = ReadProcessors(session, snapshot, access, CancellationToken.None);
            snapshot = ReadMemory(session, snapshot, access, CancellationToken.None);
            snapshot = ReadVolumes(session, snapshot, access, CancellationToken.None);
            snapshot = ReadNetwork(session, snapshot, access, CancellationToken.None);
            snapshot = ReadTpm(session, snapshot, access, CancellationToken.None);
            snapshot = ReadBitLocker(session, snapshot, access, CancellationToken.None);
            snapshot = ReadAntivirus(session, snapshot, access, CancellationToken.None);
            snapshot = ReadHotfixes(session, snapshot, access, CancellationToken.None);
            snapshot = ReadServices(session, snapshot, access, CancellationToken.None);
        }
        var confirmed = new[] { "CBS", "Windows Update" }.Where((_, i) => reboot[i] == true).ToImmutableArray();
        var complete = rebootCode == 0 && reboot.All(v => v.HasValue);
        snapshot = snapshot with { PendingReboot = new(confirmed, reboot[2] == true ? ["Renommages de fichiers en attente"] : []) { Complete = complete } };
        access.Add(new(InventoryCategories.Reboot, complete ? SourceStatus.Ok : rebootCode is 5 or unchecked((int)0x80070005) ? SourceStatus.Refused : SourceStatus.Partial,
            complete ? "Trois indicateurs lus sous SYSTEM ; renommages conservés comme indice partiel." : "Au moins un indicateur non lu ; aucune absence de redémarrage requise confirmée.", 0, confirmed.Length, InventoryTransport.ScheduledTask));
        foreach (var category in Categories(plan.Kind == RemoteTaskReadKind.InventoryFull ? WorkstationReading.Full : plan.Kind == RemoteTaskReadKind.Diagnostic ? WorkstationReading.Diagnostic : WorkstationReading.Quick))
        { if (!access.Any(a => a.Category == category)) { access.Add(new(category, SourceStatus.Unavailable, "Source non couverte par ce programme ponctuel borné ; aucun résultat supposé.", 0, 0, InventoryTransport.ScheduledTask)); } }
        return snapshot with { Access = [.. access.Select(a => a with { Transport = InventoryTransport.ScheduledTask, Detail = "Tâche SYSTEM · " + a.Detail })] };
    }
    private sealed class TaskReplyClock(DateTimeOffset now) : TimeProvider { public override DateTimeOffset GetUtcNow() => now; }
}
