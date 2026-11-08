using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;

namespace Domenia.E2E.Cdp;

/// <summary>Page target listed by the DevTools HTTP endpoint of the WebView2 browser process.</summary>
internal sealed record DevToolsTarget(string Id, string Url, Uri WebSocket);

/// <summary>
/// Discovery on http://127.0.0.1:&lt;port&gt;/json (loopback only, no proxy): the page of the Domenia interface, the
/// browser version, and the check that nothing listens on that port outside the loopback.
/// </summary>
internal static class DevToolsEndpoint
{
    public const string InterfaceHost = "domenia.local";

    public static HttpClient CreateClient() => new(new SocketsHttpHandler { UseProxy = false, ConnectTimeout = TimeSpan.FromSeconds(2) })
    {
        Timeout = TimeSpan.FromSeconds(5),
    };

    /// <summary>A free TCP port of the loopback, from the ephemeral range Windows hands out (always above 1024).</summary>
    public static int FreeLoopbackPort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    /// <summary>Listening sockets on this port, whatever process owns them (no elevation needed).</summary>
    public static IReadOnlyList<IPEndPoint> Listeners(int port) =>
        [.. IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Where(e => e.Port == port)];

    /// <summary>True when every listener of the port is a loopback address (and there is at least one).</summary>
    public static bool LoopbackOnly(IReadOnlyList<IPEndPoint> listeners) =>
        listeners.Count > 0 && listeners.All(e => IPAddress.IsLoopback(e.Address));

    /// <summary>
    /// The page that shows the interface (https://domenia.local/…), or null while the browser has not listed it yet
    /// (endpoint not open, page still on about:blank). The WebSocket address must point back to the same loopback port.
    /// </summary>
    public static async Task<DevToolsTarget?> FindInterfacePageAsync(HttpClient http, int port, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(http);
        string json;
        try
        {
            json = await http.GetStringAsync(new Uri($"http://127.0.0.1:{port}/json/list"), cancellationToken).ConfigureAwait(false);
        }
        catch (HttpRequestException)
        {
            return null;
        }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        return ParseTargets(json, port).FirstOrDefault();
    }

    /// <summary>Pure: page targets of the interface in a /json/list answer, safe WebSocket addresses only.</summary>
    public static IReadOnlyList<DevToolsTarget> ParseTargets(string json, int port)
    {
        var result = new List<DevToolsTarget>();
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != JsonValueKind.Array)
        {
            return result;
        }
        foreach (var item in document.RootElement.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object
                || !string.Equals(Text(item, "type"), "page", StringComparison.Ordinal)
                || Text(item, "url") is not string url
                || !Uri.TryCreate(url, UriKind.Absolute, out var page)
                || page.Scheme != Uri.UriSchemeHttps
                || !string.Equals(page.Host, InterfaceHost, StringComparison.OrdinalIgnoreCase)
                || Text(item, "webSocketDebuggerUrl") is not string socketText
                || !Uri.TryCreate(socketText, UriKind.Absolute, out var socket)
                || socket.Scheme != "ws"
                || socket.Port != port
                || !(string.Equals(socket.Host, "127.0.0.1", StringComparison.Ordinal) || string.Equals(socket.Host, "localhost", StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }
            result.Add(new DevToolsTarget(Text(item, "id") ?? "", url, socket));
        }
        return result;
    }

    /// <summary>« Edg/154.0.4258.62 » or null.</summary>
    public static async Task<string?> BrowserVersionAsync(HttpClient http, int port, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(http);
        try
        {
            var json = await http.GetStringAsync(new Uri($"http://127.0.0.1:{port}/json/version"), cancellationToken).ConfigureAwait(false);
            using var document = JsonDocument.Parse(json);
            return document.RootElement.ValueKind == JsonValueKind.Object ? Text(document.RootElement, "Browser") : null;
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or TaskCanceledException)
        {
            return null;
        }
    }

    private static string? Text(JsonElement item, string name) =>
        item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}
