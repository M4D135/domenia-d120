using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class WmiWorkstationReader
{
    public async Task<SourceAccess> ReadDiagnosticTransportAsync(string host, DiagnosticTransport kind, TimeSpan budget, CancellationToken cancellationToken, RemoteProbeCredential? credential = null)
    {
        if (!CimQuery.IsHostName(host) || !Enum.IsDefined(kind) || budget <= TimeSpan.Zero || budget > TimeSpan.FromSeconds(8))
        { throw new ArgumentException("Contrôle de transport invalide."); }
        var began = clock.GetTimestamp();
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Task<CimReading> work;
        try { work = WmiReadWorkers.Start(credential, owned =>
        {
            using var session = Session(host, budget, stop.Token, owned);
            return session.ReadDiagnosticTransport(kind);
        }, cancellationToken); }
        catch { stop.Dispose(); throw; }
        try { return (await work.WaitAsync(budget, clock, cancellationToken).ConfigureAwait(false)).ToAccess(kind == DiagnosticTransport.WinRm ? InventoryTransport.WinRm : InventoryTransport.NetApi); }
        catch (Exception ex) when (ex is OperationCanceledException or TimeoutException)
        { stop.Cancel(); return new(kind.ToString(), SourceStatus.Interrupted, "Contrôle arrêté ou délai atteint ; aucune réponse concluante reçue.", (int)clock.GetElapsedTime(began).TotalMilliseconds, 0, InventoryTransport.NetApi); }
        finally { DisposeAfter(work, stop); }
    }

    private static InventorySnapshot ReadDiagnosticSystem(CimSession session, InventorySnapshot current, List<SourceAccess> access, bool full = false)
    {
        var identity = session.Read(InventoryCategories.System, Cimv2, "SELECT Name FROM Win32_ComputerSystem", 1, TimeSpan.FromSeconds(3));
        var reported = identity.Status == SourceStatus.Ok ? identity.Instances.SingleOrDefault()?.Text("Name") : null;
        if (full && !string.Equals(session.Host.Split('.')[0], reported, StringComparison.OrdinalIgnoreCase))
        { AddAccess(access, session, InventoryCategories.System, identity with { Status = identity.Status == SourceStatus.Ok ? SourceStatus.Unavailable : identity.Status, Detail = "Identité Windows non confirmée ; système non lu." }); return current with { ReportedName = reported }; }
        var os = session.Read(InventoryCategories.System, Cimv2, "SELECT Caption, Version, LastBootUpTime" + (full ? ", SystemDrive" : "") + " FROM Win32_OperatingSystem", 1, TimeSpan.FromSeconds(4));
        AddAccess(access, session, InventoryCategories.System, identity, os);
        var value = os.Instances.FirstOrDefault();
        return current with
        {
            ReportedName = identity.Instances.FirstOrDefault()?.Text("Name"),
            Os = value is null ? null : new(value.Text("Caption") ?? "", value.Text("Version") ?? "", "", null, "", null, null, value.Dmtf("LastBootUpTime"), null, null, null) { SystemDrive = value.Text("SystemDrive") },
        };
    }

    private static InventorySnapshot ReadDiagnosticDisk(CimSession session, InventorySnapshot current, List<SourceAccess> access, string? drive = "C:")
    {
        if (drive is not { Length: 2 } || drive[1] != ':' || !char.IsAsciiLetter(drive[0]))
        { access.Add(new(InventoryCategories.Volumes, SourceStatus.Unavailable, "Lettre du volume système non déterminée ; aucun volume supposé.", 0, 0, session.Transport)); return current; }
        var read = session.Read(InventoryCategories.Volumes, Cimv2, "SELECT DeviceID, Size, FreeSpace FROM Win32_LogicalDisk WHERE DeviceID='" + drive + "'", 2, TimeSpan.FromSeconds(4));
        AddAccess(access, session, InventoryCategories.Volumes, read);
        var rows = read.Instances.Where(r => r.Text("DeviceID")?.Equals(drive, StringComparison.OrdinalIgnoreCase) == true).ToArray();
        if (rows.Length != read.Items || rows.Length > 1) { Incomplete(access, InventoryCategories.Volumes, "Réponse de volume inattendue ou ambiguë."); return current; }
        return current with { Volumes = [.. rows.Select(r => new LogicalDisk(drive, null, null, r.Number("Size"), r.Number("FreeSpace")))] };
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
