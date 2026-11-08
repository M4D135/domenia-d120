using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

internal sealed partial class RemoteWriteNativeBackend
{
    private RemoteWriteResult ScheduledProgram(RemoteWriteRequest request)
    {
        object? service = null, folder = null, task = null, running = null;
        var name = RemoteWriteTask.Name(request); var taskXml = RemoteWriteTask.Xml(request); var created = false; var launched = false;
        static void Release(object? value) { if (value is not null && Marshal.IsComObject(value)) Marshal.FinalReleaseComObject(value); }
        try
        {
            service = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", throwOnError: true)!)!;
            TaskSchedulerConnection.Connect(service, request.Computer.DnsHostName!, credential);
            var connected = ((string)((dynamic)service).TargetServer).TrimStart('\\');
            if (!string.Equals(connected, request.Computer.DnsHostName, StringComparison.OrdinalIgnoreCase)
                && !string.Equals(connected, WorkstationIdentity.ExpectedName(request.Computer), StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Serveur du planificateur différent de la cible qualifiée.");
            folder = ((dynamic)service).GetFolder(@"\");
            if ((string)((dynamic)folder).Path != @"\") throw new InvalidDataException("Dossier planificateur inattendu.");
            try { task = ((dynamic)folder).GetTask(name); }
            catch (COMException ex) when (ex.HResult == unchecked((int)0x80070002)) { task = null; }
            if (task is not null) return new(WriteResult.NotApplied, "Nom de tâche déjà présent ; aucun remplacement.");
            // CREATE only. No trigger, no password at registration, no restart policy, no automatic retry.
            sent = true;
            task = ((dynamic)folder).RegisterTask(name, taskXml, 2,
                RemoteWriteTask.Principal(request), null, request.Run!.Interactive ? 3 : 5, RemoteTaskReadProgram.TaskAcl);
            created = true;
            if (!RemoteWriteTask.Owns((string)((dynamic)task).Xml, request)) throw new InvalidDataException("Tâche relue différente du plan.");
            running = ((dynamic)task).Run(null);
            var began = clock.GetTimestamp();
            do
            {
                var state = (int)((dynamic)task).State; var code = (int)((dynamic)task).LastTaskResult;
                // Fresh task, no triggers and exactly one Run: a completed result belongs to this attempt.
                if (state == 3 && code != 0x00041303 && code != 0x00041301 && code != 0x00041325)
                {
                    launched = true;
                    return code == 0 ? new(WriteResult.Delivered, "Programme lancé par " + name + " ; effet du programme non vérifiable.")
                        : new(WriteResult.Unknown, "Enveloppe du programme terminée avec le code " + code.ToString(System.Globalization.CultureInfo.InvariantCulture) + " ; effet à contrôler.");
                }
                Thread.Sleep(100);
            } while (clock.GetElapsedTime(began) < TimeoutOf(request));
            return new(WriteResult.Unknown, "Tâche " + name + " encore active ou en attente ; aucun arrêt et définition conservée pour inspection.", false);
        }
        finally
        {
            try
            {
                // A task definition can be deleted without terminating the running action. Never call Stop or Terminate.
                // Lost registration acknowledgement or changed XML keeps the artifact for manual inspection.
                if (created && launched && folder is not null)
                {
                    object? check = null;
                    try
                    {
                        check = ((dynamic)folder).GetTask(name);
                        if (!RemoteWriteTask.Owns((string)((dynamic)check).Xml, request)) throw new IOException("Propriété de la tâche non confirmée ; conservée.");
                        ((dynamic)folder).DeleteTask(name, 0);
                    }
                    finally { Release(check); }
                }
            }
            finally { Release(running); Release(task); Release(folder); Release(service); }
        }
    }
}

internal static class RemoteWriteTask
{
    private static readonly XNamespace Ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";
    internal static string Name(RemoteWriteRequest request) => "Domenia-Write-" + request.OperationId.ToString("N");
    internal static string Principal(RemoteWriteRequest request) => request.Run is { Interactive: true }
        ? RemoteWriteClient.IsAccountSid(request.RunUserSid) ? request.RunUserSid! : throw new InvalidDataException("SID interactif non qualifié.") : "S-1-5-18";
    private const string HostCommand = @"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe";
    private static string HostArguments(RemoteWriteRequest request) => "-NoLogo -NoProfile -NonInteractive -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(Program(request)));
    internal static string Program(RemoteWriteRequest request)
    {
        RemoteWriteClient.Validate(request); var run = request.Run!;
        var data = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new { host = request.Computer.DnsHostName, sam = WorkstationIdentity.ExpectedName(request.Computer),
            domain = string.Join('.', DistinguishedName.Parse(request.Computer.DistinguishedName).Where(r => r.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)).Select(r => r.Value)),
            sid = Principal(request), command = run.Command, arguments = run.Arguments, timeout = request.TimeoutSeconds },
            new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
        var script = "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$p=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + data + "'))|ConvertFrom-Json);" + """
            try {
                if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne $p.sid){exit 87};
                $rows=@(Get-CimInstance -ClassName Win32_ComputerSystem -Property Name,DNSHostName,Domain -OperationTimeoutSec $p.timeout);
                if($rows.Count -ne 1 -or $rows[0].Domain -ine $p.domain -or -not $rows[0].DNSHostName){exit 87};
                $label=$p.host.Split('.')[0]; $name=[string]$rows[0].Name; $dns=[string]$rows[0].DNSHostName;
                if($name -ine $p.sam -and -not($p.sam -ieq $label -and $label.Length -gt 15 -and $name -ieq $label.Substring(0,15))){exit 87};
                if($dns.Split('.')[0] -ine $label -or ($dns.Contains('.') -and $dns -ine $p.host)){exit 87};
                $start=New-Object Diagnostics.ProcessStartInfo; $start.FileName=[string]$p.command; $start.Arguments=[string]$p.arguments; $start.UseShellExecute=$false;
                $process=[Diagnostics.Process]::Start($start); if($null -eq $process){exit 87}; $process.Dispose(); exit 0
            } catch { exit 1 }
            """;
        RemoteProgramSafety.RequireSafe(script); return script;
    }
    private static string Marker(RemoteWriteRequest request) => "Domenia.RemoteWrite/1:" + request.Computer.ObjectGuid.ToString("D") + ":"
        + request.OperationId.ToString("N") + ":" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(request.Run!.Command + "\0" + request.Run.Arguments)));
    internal static string Xml(RemoteWriteRequest request)
    {
        RemoteWriteClient.Validate(request); var run = request.Run!; var arguments = HostArguments(request);
        if (arguments.Length > 30_000) throw new InvalidDataException("Enveloppe du programme trop longue ; aucun artefact créé.");
        XElement E(string name, object content) => new(Ns + name, content);
        return new XElement(Ns + "Task", new XAttribute("version", "1.2"),
            E("RegistrationInfo", E("Description", Marker(request))), E("Triggers", ""),
            E("Principals", new XElement(Ns + "Principal", new XAttribute("id", "Operator"), E("UserId", Principal(request)),
                run.Interactive ? E("LogonType", "InteractiveToken") : null, E("RunLevel", run.Elevated ? "HighestAvailable" : "LeastPrivilege"))),
            E("Settings", new object[] { E("MultipleInstancesPolicy", "IgnoreNew"), E("DisallowStartIfOnBatteries", false), E("StopIfGoingOnBatteries", false),
                E("AllowHardTerminate", false), E("StartWhenAvailable", false), E("AllowStartOnDemand", true), E("Enabled", true), E("Hidden", false), E("ExecutionTimeLimit", "PT0S") }),
            new XElement(Ns + "Actions", new XAttribute("Context", "Operator"), E("Exec", new object[] { E("Command", HostCommand), E("Arguments", arguments) })))
            .ToString(SaveOptions.DisableFormatting);
    }
    internal static bool Owns(string xml, RemoteWriteRequest request)
    {
        if (xml.Length > 65_536) return false;
        try
        {
            using var reader = XmlReader.Create(new StringReader(xml), new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 65_536 });
            var root = XElement.Load(reader); var run = request.Run!;
            XElement? One(XElement? p, string n) => p?.Elements(Ns + n).Take(2).ToArray() is [var one] ? one : null;
            var info = One(root, "RegistrationInfo"); var actions = One(root, "Actions"); var exec = One(actions, "Exec");
            var principals = One(root, "Principals"); var principal = One(principals, "Principal"); var settings = One(root, "Settings");
            return root.Name == Ns + "Task" && (string?)One(info, "Description") == Marker(request)
                && principals?.Elements().Count() == 1 && (run.Interactive ? (string?)One(principal, "UserId") == Principal(request)
                    : (string?)One(principal, "UserId") is "S-1-5-18" or "SYSTEM" or @"NT AUTHORITY\SYSTEM")
                && (string?)One(principal, "LogonType") == (run.Interactive ? "InteractiveToken" : null) && One(principal, "GroupId") is null
                && (string?)One(principal, "RunLevel") == (run.Elevated ? "HighestAvailable" : "LeastPrivilege")
                && (string?)actions?.Attribute("Context") == (string?)principal?.Attribute("id")
                && actions?.Elements().Count() == 1 && (string?)One(exec, "Command") == HostCommand && (string?)One(exec, "Arguments") == HostArguments(request)
                && exec?.Elements().All(e => e.Name == Ns + "Command" || e.Name == Ns + "Arguments") == true
                && root.Elements(Ns + "Triggers").Count() <= 1 && (One(root, "Triggers") is not { HasElements: true })
                && (string?)One(settings, "ExecutionTimeLimit") == "PT0S" && (string?)One(settings, "MultipleInstancesPolicy") == "IgnoreNew"
                && settings?.Elements(Ns + "RestartOnFailure").Any() == false
                && (string?)One(settings, "AllowHardTerminate") == "false" && (string?)One(settings, "StartWhenAvailable") == "false"
                && (string?)One(settings, "AllowStartOnDemand") == "true" && (string?)One(settings, "Enabled") == "true"
                && (string?)One(settings, "DisallowStartIfOnBatteries") == "false" && (string?)One(settings, "StopIfGoingOnBatteries") == "false";
        }
        catch (XmlException) { return false; }
    }
}
