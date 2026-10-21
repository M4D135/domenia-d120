using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Domenia.E2E.Cdp;
using Domenia.E2E.Driver;
using Domenia.E2E.Report;
using Domenia.E2E.Scenarios;

namespace Domenia.E2E.Runner;

/// <summary>Setup failure of a run (Domenia not started, port exposed, page never ready…), in French.</summary>
internal sealed class SessionException(string message) : Exception(message)
{
}

/// <summary>
/// One Domenia process driven by the harness: started with --e2e-port and DOMENIA_E2E=1 (plus --simulation in simulation
/// mode), DevTools endpoint found on the loopback, page connected, console and journal followed, closed at the end.
/// </summary>
internal sealed class AppSession : IAsyncDisposable
{
    private static readonly TimeSpan StartupLimit = TimeSpan.FromSeconds(90);

    private readonly HttpClient http = DevToolsEndpoint.CreateClient();
    private readonly Lock gate = new();
    private readonly List<ConsoleEntry> console = [];
    private Process? process;
    private CdpConnection? cdp;
    private int currentStep;

    private AppSession(JournalTail journal)
    {
        Journal = journal;
    }

    public PageDriver Page { get; private set; } = null!;

    public JournalTail Journal { get; }

    public int Port { get; private set; }

    public string? BrowserVersion { get; private set; }

    /// <summary>Exit code once the process has ended, else null.</summary>
    public int? ExitCode => process is { HasExited: true } p ? p.ExitCode : null;

    public bool Exited => process is null || process.HasExited;

    /// <summary>Step number console messages are attributed to (0 = start).</summary>
    public int CurrentStep
    {
        get => Volatile.Read(ref currentStep);
        set => Volatile.Write(ref currentStep, value);
    }

    /// <param name="journal">Taken by the caller before the start, so a start that fails still has its journal lines.</param>
    public static async Task<AppSession> StartAsync(string exe, RunMode mode, JournalTail journal, CancellationToken cancellationToken)
    {
        var session = new AppSession(journal);
        try
        {
            await session.LaunchAsync(exe, mode, cancellationToken).ConfigureAwait(false);
            return session;
        }
        catch
        {
            await session.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    public IReadOnlyList<ConsoleEntry> ConsoleSnapshot()
    {
        lock (gate)
        {
            return [.. console];
        }
    }

    private async Task LaunchAsync(string exe, RunMode mode, CancellationToken cancellationToken)
    {
        Port = DevToolsEndpoint.FreeLoopbackPort();
        var start = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(exe) ?? Environment.CurrentDirectory,
        };
        if (mode == RunMode.Simulation)
        {
            start.ArgumentList.Add("--simulation");
        }
        start.ArgumentList.Add("--e2e-port");
        start.ArgumentList.Add(Port.ToString(CultureInfo.InvariantCulture));
        // The E2E switch lives in this child's environment only, never in the machine's or the user's.
        start.Environment["DOMENIA_E2E"] = "1";
        start.Environment.Remove("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS");
        start.Environment.Remove("WEBVIEW2_PIPE_FOR_SCRIPT_DEBUGGER");
        if (mode == RunMode.Annuaire)
        {
            // Directory mode is decided by the join state of the workstation, with the identity of this session.
            start.Environment.Remove("DOMENIA_SIMULATION");
        }
        process = Process.Start(start) ?? throw new SessionException("Domenia n’a pas pu être lancé.");
        var clock = Stopwatch.StartNew();
        DevToolsTarget? target = null;
        while (target is null)
        {
            if (process.HasExited)
            {
                throw new SessionException($"Domenia s’est arrêté au démarrage avec le code {process.ExitCode} (voir le journal technique).");
            }
            if (clock.Elapsed > StartupLimit)
            {
                throw new SessionException($"Protocole DevTools introuvable sur 127.0.0.1:{Port} après {(int)StartupLimit.TotalSeconds} s : l’interface ne s’est pas ouverte.");
            }
            target = await DevToolsEndpoint.FindInterfacePageAsync(http, Port, cancellationToken).ConfigureAwait(false);
            if (target is null)
            {
                await Task.Delay(250, cancellationToken).ConfigureAwait(false);
            }
        }
        // The protocol has no authentication: it must never be reachable from another machine.
        var listeners = DevToolsEndpoint.Listeners(Port);
        if (!DevToolsEndpoint.LoopbackOnly(listeners))
        {
            throw new SessionException($"Port de débogage exposé hors de la boucle locale ({string.Join(", ", listeners)}) : exécution arrêtée.");
        }
        BrowserVersion = await DevToolsEndpoint.BrowserVersionAsync(http, Port, cancellationToken).ConfigureAwait(false);
        cdp = await CdpConnection.ConnectAsync(target.WebSocket, TimeSpan.FromSeconds(10), cancellationToken).ConfigureAwait(false);
        cdp.EventReceived += OnEvent;
        Page = new PageDriver(cdp);
        await Page.EnableAsync(cancellationToken).ConfigureAwait(false);
    }

    private void OnEvent(string method, JsonElement parameters)
    {
        ConsoleEntry? entry = method switch
        {
            "Runtime.consoleAPICalled" => FromConsoleCall(parameters),
            "Runtime.exceptionThrown" => FromException(parameters),
            "Log.entryAdded" => FromLog(parameters),
            _ => null,
        };
        if (entry is null)
        {
            return;
        }
        lock (gate)
        {
            if (console.Count < 500)
            {
                console.Add(entry);
            }
        }
    }

    private ConsoleEntry? FromConsoleCall(JsonElement p)
    {
        var type = Str(p, "type");
        var level = type switch
        {
            "error" or "assert" => "error",
            "warning" => "warning",
            _ => null,
        };
        if (level is null)
        {
            return null;
        }
        var parts = new List<string>();
        if (p.TryGetProperty("args", out var args) && args.ValueKind == JsonValueKind.Array)
        {
            foreach (var arg in args.EnumerateArray())
            {
                parts.Add(arg.TryGetProperty("value", out var value) ? (value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : value.GetRawText())
                    : Str(arg, "description") ?? Str(arg, "unserializableValue") ?? Str(arg, "type") ?? "");
            }
        }
        return new ConsoleEntry(CurrentStep, level, "console", Clip(string.Join(" ", parts)));
    }

    private ConsoleEntry? FromException(JsonElement p)
    {
        if (!p.TryGetProperty("exceptionDetails", out var details))
        {
            return null;
        }
        var text = details.TryGetProperty("exception", out var exception) ? Str(exception, "description") : null;
        text ??= Str(details, "text") ?? "Exception";
        var url = Str(details, "url");
        return new ConsoleEntry(CurrentStep, "error", "exception", Clip(text + (url is null ? "" : $" ({ShortUrl(url)})")));
    }

    private ConsoleEntry? FromLog(JsonElement p)
    {
        if (!p.TryGetProperty("entry", out var entry))
        {
            return null;
        }
        var level = Str(entry, "level");
        if (level is not ("error" or "warning"))
        {
            return null;
        }
        var url = Str(entry, "url");
        var source = Str(entry, "source") ?? "log";
        // The browser asks for /favicon.ico by itself; its absence is not an error of the page (kept as a warning).
        if (level == "error" && source == "network" && IsFavicon(url))
        {
            level = "warning";
            source = "network (icône demandée par le navigateur)";
        }
        return new ConsoleEntry(CurrentStep, level, source, Clip((Str(entry, "text") ?? "") + (url is null ? "" : $" ({ShortUrl(url)})")));
    }

    internal static bool IsFavicon(string? url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri)
        && string.Equals(uri.Host, DevToolsEndpoint.InterfaceHost, StringComparison.OrdinalIgnoreCase)
        && string.Equals(uri.AbsolutePath, "/favicon.ico", StringComparison.OrdinalIgnoreCase);

    private static string ShortUrl(string url) => Uri.TryCreate(url, UriKind.Absolute, out var uri) ? uri.Host + uri.AbsolutePath : url;

    private static string Clip(string text) => text.Length > 2000 ? text[..2000] + "…" : text;

    private static string? Str(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    /// <summary>Closes the window like the operator would (WM_CLOSE), then stops the process tree if it lingers.</summary>
    public async Task<int?> CloseAsync()
    {
        if (cdp is not null)
        {
            cdp.EventReceived -= OnEvent;
            await cdp.DisposeAsync().ConfigureAwait(false);
            cdp = null;
        }
        if (process is null)
        {
            return null;
        }
        if (!process.HasExited)
        {
            process.Refresh();
            var asked = process.CloseMainWindow();
            using var bounded = new CancellationTokenSource(TimeSpan.FromSeconds(asked ? 15 : 1));
            try
            {
                await process.WaitForExitAsync(bounded.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                try
                {
                    process.Kill(entireProcessTree: true);
                }
                catch (InvalidOperationException)
                {
                    // Ended between the wait and the kill.
                }
                using var last = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                await process.WaitForExitAsync(last.Token).ConfigureAwait(false);
                await WaitBrowserGoneAsync().ConfigureAwait(false);
                return null;
            }
        }
        await WaitBrowserGoneAsync().ConfigureAwait(false);
        return process.ExitCode;
    }

    /// <summary>
    /// The WebView2 browser process outlives its host by a moment and holds the E2E profile meanwhile: the next run could
    /// not empty it. That process owns the DevTools port, so the port closing marks its end (10 s at most).
    /// </summary>
    private async Task WaitBrowserGoneAsync()
    {
        if (Port == 0)
        {
            return;
        }
        var clock = Stopwatch.StartNew();
        while (DevToolsEndpoint.Listeners(Port).Count > 0 && clock.Elapsed < TimeSpan.FromSeconds(10))
        {
            await Task.Delay(200, CancellationToken.None).ConfigureAwait(false);
        }
        // Its renderer and GPU processes end with it; a short margin lets them release their files.
        await Task.Delay(500, CancellationToken.None).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            await CloseAsync().ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or OperationCanceledException)
        {
            Console.Error.WriteLine($"Domenia n’a pas pu être arrêté proprement : {ex.GetType().Name}.");
        }
        process?.Dispose();
        http.Dispose();
    }
}

/// <summary>
/// Lines appended to the technical journal of Domenia (%LOCALAPPDATA%\Domenia\logs\domenia.log) since the harness started
/// the process: same account, read only, shared reading (Domenia keeps appending).
/// </summary>
internal sealed class JournalTail
{
    private readonly long offset;

    private JournalTail(string? path, long offset)
    {
        Path = path;
        this.offset = offset;
    }

    public string? Path { get; }

    public static string? DefaultPath()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return System.IO.Path.IsPathFullyQualified(root) ? System.IO.Path.Combine(root, "Domenia", "logs", "domenia.log") : null;
    }

    public static JournalTail FromNow()
    {
        var path = DefaultPath();
        var length = path is not null && File.Exists(path) ? new FileInfo(path).Length : 0;
        return new JournalTail(path, length);
    }

    /// <summary>Every line written since the start of the run (a journal replaced meanwhile is read from its beginning).</summary>
    public IReadOnlyList<string> Lines()
    {
        if (Path is null || !File.Exists(Path))
        {
            return [];
        }
        try
        {
            using var stream = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var from = stream.Length >= offset ? offset : 0;
            stream.Seek(from, SeekOrigin.Begin);
            using var reader = new StreamReader(stream, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: true);
            var text = reader.ReadToEnd();
            return text.Split('\n').Select(l => l.TrimEnd('\r')).Where(l => l.Length > 0).ToList();
        }
        catch (IOException)
        {
            return [];
        }
        catch (UnauthorizedAccessException)
        {
            return [];
        }
    }
}
