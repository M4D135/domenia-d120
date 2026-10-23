using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class WmiWorkstationReader
{
    private static InventorySnapshot ReadDiagnosticSystem(CimSession session, InventorySnapshot current, List<SourceAccess> access)
    {
        var identity = session.Read(InventoryCategories.System, Cimv2, "SELECT Name FROM Win32_ComputerSystem", 1, TimeSpan.FromSeconds(3));
        var os = session.Read(InventoryCategories.System, Cimv2, "SELECT Caption, Version, LastBootUpTime FROM Win32_OperatingSystem", 1, TimeSpan.FromSeconds(4));
        AddAccess(access, session, InventoryCategories.System, identity, os);
        var value = os.Instances.FirstOrDefault();
        return current with
        {
            ReportedName = identity.Instances.FirstOrDefault()?.Text("Name"),
            Os = value is null ? null : new(value.Text("Caption") ?? "", value.Text("Version") ?? "", "", null, "", null, null, value.Dmtf("LastBootUpTime"), null, null, null),
        };
    }

    private static InventorySnapshot ReadDiagnosticDisk(CimSession session, InventorySnapshot current, List<SourceAccess> access)
    {
        var read = session.Read(InventoryCategories.Volumes, Cimv2, "SELECT DeviceID, Size, FreeSpace FROM Win32_LogicalDisk WHERE DeviceID='C:'", 2, TimeSpan.FromSeconds(4));
        AddAccess(access, session, InventoryCategories.Volumes, read);
        var rows = read.Instances.Where(r => r.Text("DeviceID")?.Equals("C:", StringComparison.OrdinalIgnoreCase) == true).ToArray();
        if (rows.Length != read.Items || rows.Length > 1) { Incomplete(access, InventoryCategories.Volumes, "Réponse de volume inattendue ou ambiguë."); return current; }
        return current with { Volumes = [.. rows.Select(r => new LogicalDisk("C:", null, null, r.Number("Size"), r.Number("FreeSpace")))] };
    }

    private static InventorySnapshot ReadDiagnosticServices(CimSession session, InventorySnapshot current, List<SourceAccess> access)
    {
        var read = session.Read(InventoryCategories.Services, Cimv2, "SELECT Name, State, StartMode FROM Win32_Service WHERE "
            + string.Join(" OR ", PosteDiagnostics.QuickServices.Select(n => "Name='" + n + "'")), 5, TimeSpan.FromSeconds(4));
        AddAccess(access, session, InventoryCategories.Services, read);
        var rows = read.Instances.Where(r => r.Text("Name") is { } n && PosteDiagnostics.QuickServices.Contains(n, StringComparer.OrdinalIgnoreCase))
            .GroupBy(r => r.Text("Name"), StringComparer.OrdinalIgnoreCase).Where(g => g.Count() == 1).Select(g => g.Single()).ToArray();
        if (rows.Length != read.Items || rows.Any(r => r.Text("State") is null || r.Text("StartMode") is null))
        { Incomplete(access, InventoryCategories.Services, "État de certains services absent ou ambigu ; liste incomplète."); }
        return current with { Services = [.. rows.Select(r => new ServiceEntry(r.Text("Name")!, r.Text("Name")!, r.Text("State") ?? "", r.Text("StartMode") ?? "", null, null, null, null, [], null))] };
    }
}
