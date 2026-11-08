using System.Collections.Immutable;
using System.Globalization;
using System.Management;
using System.Net;
using System.Net.Sockets;
using Domenia.Core;
using Domenia.Core.Poste;
using WmiEnumerationOptions = System.Management.EnumerationOptions;

namespace Domenia.Inventory;

internal sealed partial class RemoteWriteNativeBackend(RemoteProbeCredential? credential, PosteConfiguration settings, TimeProvider clock) : IRemoteWriteBackend
{
    private bool sent;
    private readonly List<ManagementScope> scopes = [];
    private readonly List<ConnectionOptions> connectionOptions = [];
    private TimeSpan TimeoutOf(RemoteWriteRequest request) => TimeSpan.FromSeconds(request.TimeoutSeconds);
    public RemoteWriteSnapshot Inspect(RemoteWriteRequest request, CancellationToken token)
    {
        using var session = new CimSession(request.Computer.DnsHostName!, TimeoutOf(request), clock, null, token, credential, settings.SelectedCimTransport);
        var identityRead = session.Read("Identity", @"root\cimv2", "SELECT Name,DNSHostName,Domain,UserName FROM Win32_ComputerSystem", 2, TimeoutOf(request));
        if (identityRead.Status == SourceStatus.Refused) throw new RemoteWriteAccessException(identityRead.AuthenticationRejected);
        var identity = identityRead.HostIdentity;
        if (identityRead.Status != SourceStatus.Ok || identity is null || !WorkstationIdentity.Matches(request.Computer, identityRead.Instances.SingleOrDefault()?.Text("Name"), identity))
            throw new InvalidDataException("Identité Windows non confirmée avant intervention.");
        var os = session.Read("System", @"root\cimv2", "SELECT LastBootUpTime FROM Win32_OperatingSystem", 2, TimeoutOf(request));
        var boot = os.Status == SourceStatus.Ok && os.Items == 1 ? os.Instances[0].Dmtf("LastBootUpTime") : null;
        ServiceRow? service = null;
        if (request.Service is { } name)
        {
            var rows = session.Read("Service", @"root\cimv2", "SELECT Name,DisplayName,State,StartMode,ProcessId,StartName,ExitCode FROM Win32_Service WHERE Name='" + Escape(name) + "'", 2, TimeoutOf(request));
            if (rows.Status == SourceStatus.Refused) throw new RemoteWriteAccessException(rows.AuthenticationRejected);
            if (rows.Status != SourceStatus.Ok || rows.Items != 1 || !string.Equals(rows.Instances[0].Text("Name"), name, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Service absent ou ambigu ; aucune action.");
            var row = rows.Instances[0]; var state = row.Text("State") ?? "Unknown"; var start = row.Text("StartMode") ?? "Unknown";
            service = new(name, row.Text("DisplayName") ?? name, state, state, start, start, false, false, null,
                state == "Stopped" && start != "Disabled", state == "Running", state == "Running", row.Int("ProcessId"), row.Text("StartName"), row.Int("ExitCode"), [], [], false, null, null)
                { DependenciesRead = false, DependentsComplete = false };
        }
        // Console identity is not an exhaustive WTS session list; never display zero sessions from this query.
        var console = identityRead.Instances[0].Text("UserName");
        string? consoleSid = null;
        if (request.Run is { Interactive: true } run)
        {
            if (!string.Equals(console, run.RunUser, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Session interactive différente de la demande.");
            var user = run.RunUser!.Split('\\');
            var account = session.Read("Interactive identity", @"root\cimv2", "SELECT Name,Domain,SID FROM Win32_UserAccount WHERE Name='" + Escape(user[1]) + "' AND Domain='" + Escape(user[0]) + "'", 2, TimeoutOf(request));
            if (account.Status == SourceStatus.Refused) throw new RemoteWriteAccessException(account.AuthenticationRejected);
            if (account.Status != SourceStatus.Ok || account.Items != 1 || !string.Equals(account.Instances[0].Text("Name"), user[1], StringComparison.OrdinalIgnoreCase)
                || !string.Equals(account.Instances[0].Text("Domain"), user[0], StringComparison.OrdinalIgnoreCase)
                || !RemoteWriteClient.IsAccountSid(consoleSid = account.Instances[0].Text("SID")))
                throw new InvalidDataException("SID du compte interactif absent ou ambigu.");
        }
        return new(identity, boot, service, console is null ? [] : [console], false) { ConsoleUserSid = consoleSid };
    }

    public RemoteWriteResult Execute(RemoteWriteRequest request)
    {
        try
        {
            if (request.Kind == PosteRemoteWrites.WakeKind)
            {
                var wake = request.Wake!;
                using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp) { EnableBroadcast = true, SendTimeout = request.TimeoutSeconds * 1000 };
                var bytes = PosteRemote.WakePacket(wake.MacAddress); sent = true;
                var count = socket.SendTo(bytes, new IPEndPoint(IPAddress.Parse(wake.Broadcast), wake.Port));
                return new(count == bytes.Length ? WriteResult.Delivered : WriteResult.Unknown,
                    count == bytes.Length ? "Datagramme de réveil envoyé une fois ; allumage non vérifié." : "Envoi du datagramme non confirmé.");
            }
            var inspection = Inspect(request, CancellationToken.None);
            if (request.Run is { Interactive: true } run && (!run.RunUser!.Contains('\\')
                || !inspection.Sessions.Contains(run.RunUser, StringComparer.OrdinalIgnoreCase)
                || inspection.ConsoleUserSid != request.RunUserSid))
                return new(WriteResult.NotApplied, "Session interactive qualifiée non confirmée ; aucun lancement.");
            return request.Kind switch
            {
                PosteRemoteWrites.RestartKind when request.Restart!.Now && settings.SelectedCimTransport == InventoryTransport.Dcom => ImmediateRestart(request),
                PosteRemoteWrites.RestartKind or PosteRemoteWrites.RestartCancelKind or PosteRemoteWrites.GpUpdateKind => WinRm(request),
                PosteRemoteWrites.ServiceKind => settings.SelectedCimTransport == InventoryTransport.Dcom ? Service(request) : WinRm(request),
                PosteRemoteWrites.RunKind => ScheduledProgram(request),
                _ => new(WriteResult.NotApplied, "Action non admise par le fournisseur."),
            };
        }
        catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
        {
            // Never copy exception text: a command or its arguments may be present in a native diagnostic.
            return new(sent ? WriteResult.Unknown : WriteResult.NotApplied,
                sent ? "Réponse ou nettoyage non confirmé après tentative d’envoi ; aucune relance." + (request.Kind == PosteRemoteWrites.RunKind ? " Tâche " + RemoteWriteTask.Name(request) + " à contrôler." : "") + " Code 0x" + ex.HResult.ToString("X8", CultureInfo.InvariantCulture) + "."
                    : "Précontrôle distant non abouti ; aucun envoi. Code 0x" + ex.HResult.ToString("X8", CultureInfo.InvariantCulture) + ".", !sent) { Failure = ex is RemoteWriteAccessException access ? access.AuthenticationRejected ? OperationFailureKind.LogonFailure : OperationFailureKind.AccessDenied : OperationFailure.Classify(ex).Kind };
        }
    }

    private ManagementScope Dcom(RemoteWriteRequest request)
    {
        if (!settings.UseCim || settings.DirectMode == "winrm") throw new InvalidOperationException("Commande DCOM désactivée.");
        var options = new ConnectionOptions { Authentication = AuthenticationLevel.PacketPrivacy, Impersonation = ImpersonationLevel.Impersonate,
            EnablePrivileges = request.Kind == PosteRemoteWrites.RestartKind, Timeout = TimeoutOf(request) };
        if (credential is { Session: false }) { options.Username = credential.Account; options.SecurePassword = credential.Password; }
        var scope = new ManagementScope(@"\\" + request.Computer.DnsHostName + @"\root\cimv2", options);
        connectionOptions.Add(options); scopes.Add(scope); scope.Connect();
        using var identitySearch = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT Name,DNSHostName,Domain FROM Win32_ComputerSystem"),
            new WmiEnumerationOptions { Timeout = TimeoutOf(request), ReturnImmediately = true, Rewindable = false, BlockSize = 1 });
        using var identityRows = identitySearch.Get(); var count = 0;
        foreach (ManagementObject row in identityRows)
        {
            using (row)
            {
                if (++count > 1 || !WorkstationIdentity.Matches(request.Computer, row["Name"] as string,
                    new(request.Computer.DnsHostName!, row["Name"] as string, row["DNSHostName"] as string, row["Domain"] as string)))
                    throw new InvalidDataException("Identité de la connexion DCOM incohérente ; aucun envoi.");
            }
        }
        if (count != 1) throw new InvalidDataException("Identité DCOM absente.");
        return scope;
    }
    private RemoteWriteResult ImmediateRestart(RemoteWriteRequest request)
    {
        var scope = Dcom(request);
        using var searcher = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT __PATH FROM Win32_OperatingSystem"), new WmiEnumerationOptions { Timeout = TimeoutOf(request), ReturnImmediately = true, Rewindable = false, BlockSize = 1 });
        using var rows = searcher.Get();
        var objects = new List<ManagementObject>();
        try
        {
            foreach (ManagementObject item in rows) { objects.Add(item); if (objects.Count > 1) throw new InvalidDataException("Système distant ambigu."); }
            if (objects.Count != 1) throw new InvalidDataException("Système distant absent.");
            using var input = objects[0].GetMethodParameters("Win32Shutdown"); input["Flags"] = 6; input["Reserved"] = 0;
            sent = true;
            using var answer = objects[0].InvokeMethod("Win32Shutdown", input, new InvokeMethodOptions { Timeout = TimeoutOf(request) });
            return ShutdownCode(answer?["ReturnValue"]);
        }
        finally { foreach (var item in objects) item.Dispose(); }
    }
    private RemoteWriteResult Service(RemoteWriteRequest request)
    {
        var scope = Dcom(request);
        using var service = new ManagementObject(scope, new ManagementPath("Win32_Service.Name=\"" + request.Service!.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + "\""), new ObjectGetOptions { Timeout = TimeoutOf(request) });
        service.Get();
        var state = service["State"] as string;
        if (request.ServiceAction == "start" ? state != "Stopped" : state != "Running")
            return new(WriteResult.NotApplied, "État du service changé avant l’envoi.");
        RemoteWriteResult Invoke(string method)
        {
            sent = true;
            using var response = service.InvokeMethod(method, null, new InvokeMethodOptions { Timeout = TimeoutOf(request) });
            return Code(response?["ReturnValue"], "Commande de service");
        }
        if (request.ServiceAction == "start") return Invoke("StartService");
        var stopped = Invoke("StopService");
        if (request.ServiceAction == "stop" || stopped.Result != WriteResult.Applied) return stopped;
        var began = clock.GetTimestamp();
        do
        {
            service.Get();
            if (service["State"] as string == "Stopped")
            {
                var restarted = Invoke("StartService");
                return restarted.Result == WriteResult.Applied ? restarted : restarted with { Result = WriteResult.Unknown, Detail = "Arrêt accepté, redémarrage non confirmé ; service à vérifier." };
            }
            Thread.Sleep(100);
        } while (clock.GetElapsedTime(began) < TimeoutOf(request));
        return new(WriteResult.Unknown, "Arrêt demandé ; état arrêté non observé dans le budget. Aucun démarrage envoyé.");
    }
    internal static RemoteWriteResult Code(object? value, string label) => value is uint code
        ? code == 0 ? new(WriteResult.Applied, label + " acceptée ; effet à relire.") : new(code is 7 or 8 || code > 24 ? WriteResult.Unknown : WriteResult.NotApplied, label + " refusée par Windows (code " + code.ToString(CultureInfo.InvariantCulture) + ").") { Failure = code == 2 ? OperationFailureKind.AccessDenied : null }
        : new(WriteResult.Unknown, label + " sans code de retour fiable ; aucune relance.");
    internal static RemoteWriteResult ShutdownCode(object? value) => value is uint code && code == 0
        ? new(WriteResult.Applied, "Redémarrage accepté ; nouveau démarrage à relire.")
        : new(WriteResult.Unknown, "Retour indéterminé du redémarrage forcé ; WMI peut être interrompu par l’arrêt. Aucun renvoi.");
    private static string Escape(string value) => value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("'", "\\'", StringComparison.Ordinal);
    public void Dispose()
    {
        List<Exception>? failures = null;
        foreach (var scope in scopes) { try { scope.Options.SecurePassword = null; } catch (Exception ex) { (failures ??= []).Add(ex); } }
        foreach (var options in connectionOptions) { try { options.SecurePassword = null; } catch (Exception ex) { (failures ??= []).Add(ex); } }
        scopes.Clear(); connectionOptions.Clear();
        if (failures is not null) throw new AggregateException("Nettoyage des options natives non confirmé.", failures);
    }
}
