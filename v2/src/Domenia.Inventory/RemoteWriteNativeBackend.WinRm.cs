using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

internal sealed partial class RemoteWriteNativeBackend
{
    private RemoteWriteResult WinRm(RemoteWriteRequest request)
    {
        if (!settings.Options.UseWinRm) return new(WriteResult.NotApplied, "WinRM désactivé ; aucun autre transport essayé.");
        using var channel = new WsmanReadChannel(request.Computer.DnsHostName!, credential, clock, CancellationToken.None);
        channel.Identify(TimeoutOf(request));
        var identities = channel.Query(@"root\cimv2", "SELECT Name,DNSHostName,Domain FROM Win32_ComputerSystem", TimeoutOf(request)).Take(2).ToArray();
        if (identities is not [var identity] || !WorkstationIdentity.Matches(request.Computer, identity.Text("Name"),
            new(request.Computer.DnsHostName!, identity.Text("Name"), identity.Text("DNSHostName"), identity.Text("Domain"))))
            throw new InvalidDataException("Identité de la connexion WinRM incohérente ; aucun envoi.");
        var os = channel.Query(@"root\cimv2", "SELECT WindowsDirectory FROM Win32_OperatingSystem", TimeoutOf(request)).Take(2).ToArray();
        if (os.Length != 1 || os[0].Text("WindowsDirectory") is not { } windows) throw new InvalidDataException("Répertoire Windows non confirmé.");
        windows = RemoteScriptPlan.WindowsFolder(windows);
        using var wire = channel.TransientShellWire();
        var timeout = TimeoutOf(request); XNamespace ns = "http://schemas.microsoft.com/wbem/wsman/1/windows/shell";
        var shellXml = new XElement(ns + "Shell", new XElement(ns + "Lifetime", "PT600S"), new XElement(ns + "IdleTimeOut", "PT600S"),
            new XElement(ns + "InputStreams", "stdin"), new XElement(ns + "OutputStreams", "stdout stderr"));
        string? shell = null; var done = false;
        try
        {
            sent = true; // Even a lost Create response is an owned remote artifact with uncertain cleanup.
            shell = WsmanReadChannel.ShellId(wire.Create(timeout, shellXml.ToString(SaveOptions.DisableFormatting)));
            var command = new XElement(ns + "CommandLine", new XElement(ns + "Command", "\"" + windows + @"\System32\WindowsPowerShell\v1.0\powershell.exe" + "\""),
                new XElement(ns + "Arguments", "-NoLogo -NoProfile -NonInteractive -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(RemoteWritePrograms.WinRm(request)))));
            var commandId = WsmanReadChannel.CommandId(wire.Command(timeout, shell, command.ToString(SaveOptions.DisableFormatting)));
            var began = clock.GetTimestamp(); var total = 0;
            for (var frames = 0; frames < 4096 && clock.GetElapsedTime(began) < timeout; frames++)
            {
                var receive = new XElement(ns + "Receive", new XElement(ns + "DesiredStream", new XAttribute("CommandId", commandId), "stdout stderr"));
                string xml;
                try { xml = wire.Receive(TimeSpan.FromMilliseconds(Math.Min(2000, timeout.TotalMilliseconds)), receive.ToString(SaveOptions.DisableFormatting)); }
                catch (COMException ex) when (ex.HResult == unchecked((int)0x80338029)) { continue; } // Same command only, no new send.
                var frame = WsmanReadChannel.ParseOutput(xml, commandId);
                foreach (var output in frame.Streams) { total = checked(total + output.Bytes.Length); if (total > 65_536) throw new InvalidDataException("Sortie de commande hors borne."); }
                if (!frame.Done) continue;
                done = true;
                if (frame.ExitCode is not { } code) return new(WriteResult.Unknown, "Commande terminée sans code de sortie fiable.");
                return ScriptCode(request.Kind, code);
            }
            return new(WriteResult.Unknown, "Fin de commande non reçue dans le délai ; aucun arrêt, autre transport ou second envoi. Shell " + shell + " à vérifier.", false);
        }
        finally
        {
            // Do not delete a live shell: that may interrupt a command already applied in part.
            if (done && shell is not null) wire.Delete(timeout, shell);
        }
    }
    internal static RemoteWriteResult ScriptCode(string kind, uint code) => code == 0
        ? new(kind is PosteRemoteWrites.GpUpdateKind or PosteRemoteWrites.RestartCancelKind ? WriteResult.Delivered : WriteResult.Applied,
            "Commande terminée avec le code zéro ; effet métier non prouvé.")
        : new(WriteResult.Unknown, "Commande achevée avec une erreur, effet à vérifier (code " + code.ToString(CultureInfo.InvariantCulture) + ").")
        { Failure = kind == PosteRemoteWrites.ServiceKind && code == 2 || kind is PosteRemoteWrites.RestartKind or PosteRemoteWrites.RestartCancelKind && code == 5
            ? OperationFailureKind.AccessDenied : null };
}

/// <summary>Closed fixed templates; all operator data is encoded JSON and used as arguments, never parsed as code.
/// No execution-policy modification, no remote configuration and no certificate-validation override.</summary>
internal static class RemoteWritePrograms
{
    internal static string WinRm(RemoteWriteRequest request)
    {
        RemoteWriteClient.Validate(request);
        if (request.Kind is not (PosteRemoteWrites.RestartKind or PosteRemoteWrites.RestartCancelKind or PosteRemoteWrites.GpUpdateKind or PosteRemoteWrites.ServiceKind))
            throw new InvalidDataException("Commande hors des programmes WinRM fermés.");
        var domain = string.Join('.', DistinguishedName.Parse(request.Computer.DistinguishedName).Where(r => r.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)).Select(r => r.Value));
        var data = new { host = request.Computer.DnsHostName, sam = WorkstationIdentity.ExpectedName(request.Computer), domain, kind = request.Kind, delay = request.Restart?.DelaySeconds ?? 0, message = request.Restart?.Message ?? "",
            now = request.Restart?.Now ?? false, service = request.Service, action = request.ServiceAction, timeout = request.TimeoutSeconds };
        var encoded = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(data));
        var script = "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$p=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + encoded + "'))|ConvertFrom-Json);" + """
            $identity=@(Get-CimInstance -ClassName Win32_ComputerSystem -Property Name,DNSHostName,Domain -OperationTimeoutSec $p.timeout);
            if($identity.Count -ne 1 -or $identity[0].Domain -ine $p.domain -or -not $identity[0].DNSHostName){exit 87};
            $label=$p.host.Split('.')[0]; $name=[string]$identity[0].Name; if($name -ine $p.sam -and -not($p.sam -ieq $label -and $label.Length -gt 15 -and $name -ieq $label.Substring(0,15))){exit 87};
            $dns=[string]$identity[0].DNSHostName; if($dns.Split('.')[0] -ine $p.host.Split('.')[0] -or ($dns.Contains('.') -and $dns -ine $p.host)){exit 87};
            if($p.kind -eq 'poste.restart' -and $p.now) { $os=@(Get-CimInstance -ClassName Win32_OperatingSystem); if($os.Count -ne 1){exit 87}; $r=Invoke-CimMethod -InputObject $os[0] -MethodName Win32Shutdown -Arguments @{Flags=6;Reserved=0}; exit ([int]$r.ReturnValue) }
            if($p.kind -eq 'poste.restart') { & "$env:SystemRoot\System32\shutdown.exe" /r /t ([string]$p.delay) /c ([string]$p.message); exit $LASTEXITCODE }
            if($p.kind -eq 'poste.restartCancel') { & "$env:SystemRoot\System32\shutdown.exe" /a; exit $LASTEXITCODE }
            if($p.kind -eq 'poste.gpupdate') { & "$env:SystemRoot\System32\gpupdate.exe" /force /wait:-1; exit $LASTEXITCODE }
            if($p.kind -eq 'poste.service') {
                $filter="Name='"+([string]$p.service).Replace('\','\\').Replace("'","\'")+"'";
                $rows=@(Get-CimInstance -ClassName Win32_Service -Filter $filter -OperationTimeoutSec $p.timeout); if($rows.Count -ne 1){exit 87}; $s=$rows[0];
                if($p.action -eq 'start') { if($s.State -ne 'Stopped' -or $s.StartMode -eq 'Disabled'){exit 87}; exit ([int](Invoke-CimMethod -InputObject $s -MethodName StartService).ReturnValue) }
                if($s.State -ne 'Running'){exit 87}; $r=Invoke-CimMethod -InputObject $s -MethodName StopService; if($r.ReturnValue -ne 0){exit ([int]$r.ReturnValue)};
                if($p.action -eq 'stop'){exit 0}; $timer=[Diagnostics.Stopwatch]::StartNew();
                do { Start-Sleep -Milliseconds 100; $s=Get-CimInstance -InputObject $s } while($s.State -ne 'Stopped' -and $timer.Elapsed.TotalSeconds -lt $p.timeout);
                if($s.State -ne 'Stopped'){exit 1460}; exit ([int](Invoke-CimMethod -InputObject $s -MethodName StartService).ReturnValue)
            }
            exit 87
            """;
        RemoteProgramSafety.RequireSafe(script); return script;
    }
}
