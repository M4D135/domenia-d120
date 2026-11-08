using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

internal sealed record ShellReading(SourceStatus Status, string? Json, bool AuthenticationRejected, bool CleanupComplete);

internal interface IReadShellWire : IDisposable
{
    string Create(TimeSpan timeout, string input);
    string Command(TimeSpan timeout, string shellId, string input);
    string Receive(TimeSpan timeout, string input);
    void Delete(TimeSpan timeout, string shellId);
}

internal sealed partial class WsmanReadChannel
{
    private const string ShellNamespace = "http://schemas.microsoft.com/wbem/wsman/1/windows/shell";
    private const string ShellResource = ShellNamespace + "/cmd";
    // One of the fixed scripts admitted here. No user input, profile loading or write commands.
    private const string AppxScript = """
        $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
        [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
        $rows=[Collections.Generic.List[object]]::new();$code=0;$truncated=$false
        try {
            Get-AppxPackage -AllUsers -ErrorAction Stop | Select-Object -First 2001 | ForEach-Object {
                if($rows.Count -ge 2000){$truncated=$true}
                else {$rows.Add([pscustomobject]@{Name=[string]$_.Name;Version=[string]$_.Version;Publisher=[string]$_.Publisher;Location=[string]$_.InstallLocation;Architecture=[string]$_.Architecture})}
            }
        } catch {$code=$_.Exception.HResult}
        $result=[pscustomobject]@{Format='Domenia.AppxRead/1';Computer=[Environment]::MachineName;Code=$code;Truncated=$truncated;Rows=$rows.ToArray()}
        [Console]::Out.Write(($result | ConvertTo-Json -Depth 4 -Compress))
        exit 0
        """;

    internal IReadShellWire? ShellOverride { get; init; }

    private sealed class NativeShellWire(WsmanReadChannel owner) : IReadShellWire
    {
        private object? creator, shell;
        public string Create(TimeSpan timeout, string input)
        {
            owner.Session(timeout);
            creator = ((dynamic)owner.automation!).CreateResourceLocator(ShellResource);
            ((dynamic)creator).AddOption("WINRS_NOPROFILE", "TRUE", 1);
            ((dynamic)creator).AddOption("WINRS_CODEPAGE", "65001", 1);
            return (string)owner.Session(timeout).Create(creator, input, 0);
        }
        public string Command(TimeSpan timeout, string shellId, string input)
        {
            shell = ((dynamic)owner.automation!).CreateResourceLocator(ShellResource);
            ((dynamic)shell).AddSelector("ShellId", shellId);
            ((dynamic)shell).AddOption("WINRS_SKIP_CMD_SHELL", "FALSE", 1);
            return (string)owner.Session(timeout).Invoke(ShellNamespace + "/Command", shell, input, 0);
        }
        public string Receive(TimeSpan timeout, string input) => (string)owner.Session(timeout).Invoke(ShellNamespace + "/Receive", shell!, input, 0);
        public void Delete(TimeSpan timeout, string shellId)
        {
            if (owner.connection is null || owner.refused is not null) { throw new COMException("Fermeture de shell non confirmée."); }
            if (shell is null)
            {
                shell = ((dynamic)owner.automation!).CreateResourceLocator(ShellResource);
                ((dynamic)shell).AddSelector("ShellId", shellId);
            }
            ((dynamic)owner.connection).Timeout = (int)timeout.TotalMilliseconds;
            ((dynamic)owner.connection).Delete(shell, 0);
        }
        public void Dispose() { Release(shell); Release(creator); }
    }

    internal ShellReading ReadAppx(TimeSpan timeout) => ReadScript(AppxScript, timeout);

    private ShellReading ReadScript(string script, TimeSpan timeout)
    {
        var start = clock.GetTimestamp();
        TimeSpan Left()
        {
            token.ThrowIfCancellationRequested();
            var left = timeout - clock.GetElapsedTime(start);
            if (left <= TimeSpan.Zero) { throw new TimeoutException(); }
            return left;
        }
        using var wire = ShellOverride ?? new NativeShellWire(this);
        string? shellId = null;
        var cleanup = true;
        var created = false;
        var status = SourceStatus.Error;
        var rejected = false;
        string? json = null;
        using var output = new MemoryStream();
        var stderr = false;
        XNamespace ns = ShellNamespace;
        try
        {
            var shell = new XElement(ns + "Shell", new XElement(ns + "Lifetime", XmlConvert.ToString(timeout + TimeSpan.FromSeconds(5))),
                new XElement(ns + "IdleTimeOut", "PT60S"), new XElement(ns + "OutputStreams", "stdout stderr"));
            created = true; // Even a lost Create response can have created a shell; never repeat Create.
            var response = wire.Create(Left(), shell.ToString(SaveOptions.DisableFormatting));
            shellId = ShellId(response);
            var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            var command = new XElement(ns + "CommandLine",
                new XElement(ns + "Command", "\"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\""),
                new XElement(ns + "Arguments", "-NoLogo -NoProfile -NonInteractive -EncodedCommand " + encoded));
            response = wire.Command(Left(), shellId, command.ToString(SaveOptions.DisableFormatting));
            var commandId = CommandId(response);
            var receive = new XElement(ns + "Receive", new XElement(ns + "DesiredStream", new XAttribute("CommandId", commandId), "stdout stderr"));
            for (var frames = 0; ; frames++)
            {
                if (frames >= 4096) { throw new XmlException("Trop de fragments WinRM."); }
                try { response = wire.Receive(Left(), receive.ToString(SaveOptions.DisableFormatting)); }
                catch (COMException ex)
                {
                    var error = Fault(ex);
                    // MS-WSMV Receive may time out while the same command is still running: resume only its output.
                    if (error.HResult == unchecked((int)0x80338029)) { continue; }
                    throw error;
                }
                var frame = ParseOutput(response, commandId);
                foreach (var (name, bytes) in frame.Streams)
                {
                    if (name == "stderr") { stderr |= bytes.Length > 0; continue; }
                    if (output.Length + bytes.Length > 1_048_576) { throw new XmlException("Sortie WinRM hors limites."); }
                    output.Write(bytes);
                }
                if (!frame.Done) { continue; }
                if (frame.ExitCode != 0 || stderr) { status = SourceStatus.Error; break; }
                json = new UTF8Encoding(false, true).GetString(output.GetBuffer(), 0, (int)output.Length);
                status = SourceStatus.Ok;
                break;
            }
        }
        catch (COMException ex)
        {
            var error = Fault(ex); status = CimSession.Classify(error) ?? SourceStatus.Error;
            rejected = Domenia.Core.WindowsAuthenticationErrors.IsRejected(error.HResult);
        }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException or XmlException or DecoderFallbackException or FormatException)
        { status = ex is TimeoutException or OperationCanceledException ? SourceStatus.Interrupted : SourceStatus.Error; }
        finally
        {
            // Delete only the shell created here, even when the read token was cancelled. Never close a desktop/session.
            if (created)
            {
                cleanup = false;
                if (shellId is not null && refused is null)
                {
                    try { wire.Delete(TimeSpan.FromSeconds(2), shellId); cleanup = true; }
                    catch (COMException) { /* Returned explicitly as CleanupComplete=false; no hidden retry or new shell. */ }
                }
            }
        }
        return new(status, json, rejected, cleanup);
    }

    internal static string ShellId(string xml)
    {
        var root = ParseXml(xml);
        XNamespace selectors = "http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd";
        var ids = root.DescendantsAndSelf().Where(e => e.Name == XName.Get("ShellId", ShellNamespace)
            || e.Name == selectors + "Selector" && (string?)e.Attribute("Name") == "ShellId").Select(e => NormalizeId(e.Value)).Distinct().ToArray();
        return ids.Length == 1 ? ids[0] : throw new XmlException("Identité de shell WinRM absente ou contradictoire.");
    }
    internal static string CommandId(string xml)
    {
        var root = ParseXml(xml);
        if (root.Name != XName.Get("CommandResponse", ShellNamespace)) { throw new XmlException("Réponse de commande WinRM inattendue."); }
        var ids = root.Elements(XName.Get("CommandId", ShellNamespace)).ToArray();
        return ids.Length == 1 ? NormalizeId(ids[0].Value) : throw new XmlException("Identité de commande WinRM illisible.");
    }
    private static string NormalizeId(string value) => Guid.TryParse(value.StartsWith("uuid:", StringComparison.OrdinalIgnoreCase) ? value[5..] : value, out var id)
        ? id.ToString("D") : throw new XmlException("Identité WinRM invalide.");

    internal sealed record OutputFrame(bool Done, uint? ExitCode, IReadOnlyList<(string Name, byte[] Bytes)> Streams);
    internal static OutputFrame ParseOutput(string xml, string commandId)
    {
        var root = ParseXml(xml);
        XNamespace ns = ShellNamespace;
        if (root.Name != ns + "ReceiveResponse") { throw new XmlException("Réponse de réception WinRM inattendue."); }
        var streams = new List<(string Name, byte[] Bytes)>();
        var total = 0;
        foreach (var stream in root.Elements(ns + "Stream"))
        {
            if (NormalizeId((string?)stream.Attribute("CommandId") ?? "") != commandId) { throw new XmlException("Sortie d’une autre commande WinRM."); }
            var name = (string?)stream.Attribute("Name");
            if (name is not ("stdout" or "stderr") || stream.HasElements) { throw new XmlException("Flux WinRM inattendu."); }
            var bytes = Convert.FromBase64String(stream.Value);
            total += bytes.Length;
            if (total > 1_048_576) { throw new XmlException("Fragment WinRM hors limites."); }
            streams.Add((name, bytes));
        }
        var states = root.Elements(ns + "CommandState").ToArray();
        if (states.Length > 1) { throw new XmlException("État WinRM contradictoire."); }
        if (states.Length == 0) { return new(false, null, streams); }
        var state = states[0];
        if (NormalizeId((string?)state.Attribute("CommandId") ?? "") != commandId) { throw new XmlException("État d’une autre commande WinRM."); }
        var stateName = (string?)state.Attribute("State");
        if (stateName != ShellNamespace + "/CommandState/Done")
        {
            if (stateName is not (ShellNamespace + "/CommandState/Running" or ShellNamespace + "/CommandState/Pending")) { throw new XmlException("État WinRM inconnu."); }
            return new(false, null, streams);
        }
        var codes = state.Elements(ns + "ExitCode").ToArray();
        return codes.Length == 1 && uint.TryParse(codes[0].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var code)
            ? new(true, code, streams) : throw new XmlException("Code de fin WinRM absent.");
    }
}
