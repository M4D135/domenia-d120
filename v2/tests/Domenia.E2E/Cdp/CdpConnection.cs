using System.Buffers;
using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Domenia.E2E.Cdp;

/// <summary>Error answered by the DevTools protocol, or connection lost while a command was waiting.</summary>
internal sealed class CdpException(string message) : Exception(message)
{
}

/// <summary>
/// One WebSocket session on a page target of the WebView2 (Chrome DevTools Protocol): numbered commands answered by id,
/// events pushed to <see cref="EventReceived"/> from the receiving loop. Loopback only (checked by
/// <see cref="DevToolsEndpoint"/> before connecting), no proxy, no origin header.
/// </summary>
internal sealed class CdpConnection : IAsyncDisposable
{
    private const int ChunkSize = 64 * 1024;

    /// <summary>A screenshot of a 4K surface stays far below; anything bigger is not a DevTools answer.</summary>
    private const int MaxMessageBytes = 64 * 1024 * 1024;

    private readonly ClientWebSocket socket = new();
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> pending = new();
    private readonly SemaphoreSlim sendGate = new(1, 1);
    private readonly CancellationTokenSource stop = new();
    private Task receiving = Task.CompletedTask;
    private int nextId;
    private volatile string? closedReason;

    private CdpConnection()
    {
    }

    /// <summary>Raised on the receiving loop: (method, params). Handlers must be quick and thread-safe.</summary>
    public event Action<string, JsonElement>? EventReceived;

    public bool IsOpen => closedReason is null && socket.State == WebSocketState.Open;

    public static async Task<CdpConnection> ConnectAsync(Uri endpoint, TimeSpan timeout, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        var connection = new CdpConnection();
        try
        {
            connection.socket.Options.Proxy = null;
            connection.socket.Options.KeepAliveInterval = TimeSpan.Zero;
            using var bounded = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            bounded.CancelAfter(timeout);
            await connection.socket.ConnectAsync(endpoint, bounded.Token).ConfigureAwait(false);
            connection.receiving = Task.Run(connection.ReceiveLoopAsync, CancellationToken.None);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    /// <summary>Sends a command and returns its « result » object; a protocol error becomes a <see cref="CdpException"/>.</summary>
    public async Task<JsonElement> SendAsync(string method, JsonObject? parameters, TimeSpan timeout, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrEmpty(method);
        if (closedReason is string reason)
        {
            throw new CdpException($"Connexion DevTools fermée ({reason}) : commande {method} non envoyée.");
        }
        var id = Interlocked.Increment(ref nextId);
        var answer = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = answer;
        try
        {
            var message = new JsonObject
            {
                ["id"] = id,
                ["method"] = method,
                ["params"] = parameters ?? new JsonObject(),
            };
            var bytes = JsonSerializer.SerializeToUtf8Bytes(message);
            await sendGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                await socket.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                sendGate.Release();
            }
            try
            {
                return await answer.Task.WaitAsync(timeout, cancellationToken).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                throw new CdpException($"Aucune réponse du protocole DevTools à {method} après {(int)timeout.TotalMilliseconds} ms.");
            }
        }
        catch (WebSocketException ex)
        {
            throw new CdpException($"Connexion DevTools interrompue pendant {method} ({ex.WebSocketErrorCode}).");
        }
        finally
        {
            pending.TryRemove(id, out _);
        }
    }

    private async Task ReceiveLoopAsync()
    {
        var buffer = new ArrayBufferWriter<byte>(ChunkSize);
        try
        {
            while (!stop.IsCancellationRequested && socket.State == WebSocketState.Open)
            {
                buffer.Clear();
                ValueWebSocketReceiveResult result;
                do
                {
                    result = await socket.ReceiveAsync(buffer.GetMemory(ChunkSize), stop.Token).ConfigureAwait(false);
                    buffer.Advance(result.Count);
                    if (buffer.WrittenCount > MaxMessageBytes)
                    {
                        Close("message trop volumineux");
                        return;
                    }
                }
                while (!result.EndOfMessage && result.MessageType != WebSocketMessageType.Close);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    Close("fermée par le navigateur");
                    return;
                }
                Dispatch(buffer.WrittenMemory);
            }
            Close("arrêt demandé");
        }
        catch (OperationCanceledException)
        {
            Close("arrêt demandé");
        }
        catch (WebSocketException ex)
        {
            Close($"erreur WebSocket {ex.WebSocketErrorCode}");
        }
        catch (JsonException)
        {
            Close("message JSON illisible");
        }
        catch (InvalidOperationException)
        {
            Close("message de forme inattendue");
        }
    }

    private void Dispatch(ReadOnlyMemory<byte> message)
    {
        using var document = JsonDocument.Parse(message);
        var root = document.RootElement;
        if (root.TryGetProperty("id", out var idElement) && idElement.TryGetInt32(out var id))
        {
            if (!pending.TryGetValue(id, out var answer))
            {
                return;
            }
            if (root.TryGetProperty("error", out var error))
            {
                var text = error.TryGetProperty("message", out var m) ? m.GetString() : null;
                var code = error.TryGetProperty("code", out var c) && c.TryGetInt32(out var n) ? n : 0;
                answer.TrySetException(new CdpException($"Erreur du protocole DevTools {code} : {text ?? "sans message"}."));
                return;
            }
            answer.TrySetResult(root.TryGetProperty("result", out var value) ? value.Clone() : default);
            return;
        }
        if (root.TryGetProperty("method", out var method) && method.GetString() is string name)
        {
            var parameters = root.TryGetProperty("params", out var p) ? p.Clone() : default;
            EventReceived?.Invoke(name, parameters);
        }
    }

    private void Close(string reason)
    {
        closedReason ??= reason;
        foreach (var entry in pending)
        {
            entry.Value.TrySetException(new CdpException($"Connexion DevTools fermée ({closedReason})."));
        }
    }

    public async ValueTask DisposeAsync()
    {
        await stop.CancelAsync().ConfigureAwait(false);
        if (socket.State == WebSocketState.Open)
        {
            try
            {
                using var bounded = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "fin", bounded.Token).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is WebSocketException or OperationCanceledException)
            {
                // The browser may already be gone: nothing left to close.
                Close("fermeture sans réponse");
            }
        }
        try
        {
            await receiving.ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is WebSocketException or OperationCanceledException or ObjectDisposedException)
        {
            Close("boucle de réception arrêtée");
        }
        Close("connexion libérée");
        socket.Dispose();
        sendGate.Dispose();
        stop.Dispose();
    }
}
