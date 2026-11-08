using System.Runtime.InteropServices;
using System.Xml.Linq;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

internal sealed partial class WsmanReadChannel
{
    // Dedicated transient launcher obtains shell primitives, never an arbitrary script through Query/SELECT.
    internal IReadShellWire TransientShellWire() => new NativeShellWire(this);
    internal COMException TransientFault(COMException error) => Fault(error);
}

/// <summary>One shell, one command. Lost responses never create a second shell or command.</summary>
internal sealed class RemoteWinRmScriptLauncher : IRemoteScriptLauncher
{
    private const string ShellNamespace = "http://schemas.microsoft.com/wbem/wsman/1/windows/shell";
    private readonly string? host;
    private readonly RemoteProbeCredential? credential;
    private readonly TimeProvider clock;
    private readonly string? testWindowsFolder;
    private WsmanReadChannel? channel;
    private IReadShellWire? wire;
    private string? shellId, commandId;
    private bool attempted, done, closed;
    private int frames, outputBytes;
    private long started;

    internal RemoteWinRmScriptLauncher(string host, RemoteProbeCredential? credential, TimeProvider clock)
    { this.host = host; this.credential = credential; this.clock = clock; }
    internal RemoteWinRmScriptLauncher(IReadShellWire wire, string windowsFolder, TimeProvider clock)
    { this.wire = wire; testWindowsFolder = windowsFolder; this.clock = clock; }

    public string Preflight(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (testWindowsFolder is not null) { return RemoteScriptPlan.WindowsFolder(testWindowsFolder); }
        channel = new(host!, credential, clock, token); channel.Identify(TimeSpan.FromSeconds(5));
        var rows = channel.Query(@"root\cimv2", "SELECT WindowsDirectory FROM Win32_OperatingSystem", TimeSpan.FromSeconds(5)).Take(2).ToArray();
        if (rows.Length != 1 || rows[0].Text("WindowsDirectory") is not { } folder) { throw new InvalidDataException("Répertoire Windows distant absent ou ambigu."); }
        wire = channel.TransientShellWire(); return RemoteScriptPlan.WindowsFolder(folder);
    }
    public void Start(string command, CancellationToken token)
    {
        if (attempted || wire is null) { throw new InvalidOperationException("Shell déjà tenté ou précontrôle absent."); }
        token.ThrowIfCancellationRequested(); started = clock.GetTimestamp(); attempted = true;
        XNamespace ns = ShellNamespace;
        var shell = new XElement(ns + "Shell", new XElement(ns + "Lifetime", "PT40S"), new XElement(ns + "IdleTimeOut", "PT60S"),
            new XElement(ns + "InputStreams", "stdin"), new XElement(ns + "OutputStreams", "stdout stderr"));
        try
        {
            shellId = WsmanReadChannel.ShellId(wire.Create(TimeSpan.FromSeconds(5), shell.ToString(SaveOptions.DisableFormatting)));
            token.ThrowIfCancellationRequested();
            // The command is assembled only from the qualified Windows folder and the closed plan GUID.
            // WINRS_SKIP_CMD_SHELL=FALSE permits %SystemRoot% semantics but no operator text reaches this line.
            var endExecutable = command.IndexOf('"', 1);
            if (!command.StartsWith('"') || endExecutable < 2 || endExecutable + 2 >= command.Length || command[endExecutable + 1] != ' ')
            { throw new InvalidDataException("Commande WinRM hors du programme fermé."); }
            var line = new XElement(ns + "CommandLine", new XElement(ns + "Command", command[..(endExecutable + 1)]),
                new XElement(ns + "Arguments", command[(endExecutable + 2)..]));
            commandId = WsmanReadChannel.CommandId(wire.Command(TimeSpan.FromSeconds(5), shellId, line.ToString(SaveOptions.DisableFormatting)));
        }
        catch (COMException ex) { throw channel?.TransientFault(ex) ?? ex; }
    }
    public bool Finished
    {
        get
        {
            if (done) { return true; }
            if (wire is null || commandId is null) { return false; }
            if (++frames > 4096 || clock.GetElapsedTime(started) > TimeSpan.FromSeconds(35)) { throw new TimeoutException("Réception WinRM bornée terminée."); }
            XNamespace ns = ShellNamespace;
            var receive = new XElement(ns + "Receive", new XElement(ns + "DesiredStream", new XAttribute("CommandId", commandId), "stdout stderr"));
            string response;
            try { response = wire.Receive(TimeSpan.FromSeconds(2), receive.ToString(SaveOptions.DisableFormatting)); }
            catch (COMException ex)
            {
                var fault = channel?.TransientFault(ex) ?? ex;
                if (fault.HResult == unchecked((int)0x80338029)) { return false; } // Resume only this command's output.
                throw fault;
            }
            var frame = WsmanReadChannel.ParseOutput(response, commandId);
            foreach (var stream in frame.Streams)
            {
                outputBytes = checked(outputBytes + stream.Bytes.Length);
                if (outputBytes > RemoteTaskReadProgram.MaximumOutput) { throw new InvalidDataException("Sortie du programme WinRM hors limites."); }
            }
            done = frame.Done; return done;
        }
    }
    public bool CloseOwned()
    {
        if (closed || !attempted) { return true; }
        if (wire is null || shellId is null) { return false; }
        // Delete closes only the shell returned by our one Create. It does not use the cancelled read token.
        wire.Delete(TimeSpan.FromSeconds(2), shellId); closed = true; return true;
    }
    public void Dispose() { try { wire?.Dispose(); } finally { channel?.Dispose(); } }
}
