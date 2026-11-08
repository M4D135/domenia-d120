using System.Buffers.Binary;
using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32.SafeHandles;

namespace Domenia.App;

/// <summary>One private local request and one response per stage. No payload registry, network, credential or command text.</summary>
internal static class PackageUpdateChannel
{
    private const int Maximum = 16384;
    private static readonly JsonSerializerOptions Json = new()
    { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, MaxDepth = 10 };

    internal static string Name() => "Domenia-update-" + Guid.NewGuid().ToString("N");
    internal static bool ValidName(string name) => name.Length == 47 && name.StartsWith("Domenia-update-", StringComparison.Ordinal)
        && Guid.TryParseExact(name["Domenia-update-".Length..], "N", out _);
    internal static NamedPipeServerStream Server(string name) => new(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly, Maximum, Maximum);
    internal static NamedPipeClientStream Client(string name) => new(".", name, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

    internal static async Task SendAsync<T>(Stream pipe, T value, CancellationToken token)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, Json);
        if (bytes.Length is <= 0 or > Maximum) { throw new InvalidDataException("Message d’assistant hors limites."); }
        var header = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header, bytes.Length);
        await pipe.WriteAsync(header, token).ConfigureAwait(false); await pipe.WriteAsync(bytes, token).ConfigureAwait(false);
        await pipe.FlushAsync(token).ConfigureAwait(false);
    }

    internal static async Task<T> ReadAsync<T>(Stream pipe, CancellationToken token)
    {
        var header = new byte[4]; await pipe.ReadExactlyAsync(header, token).ConfigureAwait(false);
        var size = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (size is <= 0 or > Maximum) { throw new InvalidDataException("Réponse d’assistant hors limites."); }
        var bytes = new byte[size]; await pipe.ReadExactlyAsync(bytes, token).ConfigureAwait(false);
        using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 10 });
        static void Unique(JsonElement element)
        {
            if (element.ValueKind == JsonValueKind.Object)
            {
                var names = new HashSet<string>(StringComparer.Ordinal);
                foreach (var field in element.EnumerateObject())
                { if (!names.Add(field.Name)) { throw new InvalidDataException("Champ d’assistant répété."); } Unique(field.Value); }
            }
            else if (element.ValueKind == JsonValueKind.Array) { foreach (var child in element.EnumerateArray()) { Unique(child); } }
        }
        Unique(document.RootElement);
        return document.RootElement.Deserialize<T>(Json) ?? throw new InvalidDataException("Réponse d’assistant vide.");
    }

    internal static void VerifyClient(NamedPipeServerStream pipe, int expected)
    {
        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var actual) || actual != expected)
        { throw new UnauthorizedAccessException("Identité du processus assistant non confirmée."); }
    }
    internal static void VerifyServer(NamedPipeClientStream pipe, int expected)
    {
        if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var actual) || actual != expected)
        { throw new UnauthorizedAccessException("Identité du parent de l’assistant non confirmée."); }
    }
    internal static void VerifyImage(Process process, string root, long? startedTicks = null)
    {
        if (process.HasExited || !string.Equals(process.MainModule?.FileName, Path.Combine(root, "Domenia.exe"), StringComparison.OrdinalIgnoreCase)
            || startedTicks is { } ticks && process.StartTime.ToUniversalTime().Ticks != ticks)
        { throw new UnauthorizedAccessException("Processus propriétaire différent de l’installation attendue."); }
    }

    internal static Process Start(string root, string argument, string pipe)
    {
        var start = new ProcessStartInfo(Path.Combine(root, "Domenia.exe"))
        { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = root };
        start.ArgumentList.Add(argument); start.ArgumentList.Add(pipe);
        start.ArgumentList.Add(Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture));
        start.Environment["DOTNET_EnableDiagnostics"] = "0";
        return Process.Start(start) ?? throw new IOException("Assistant non démarré.");
    }

    // Only a Process returned by Start is passed here. Never kill a discovered parent or another launcher's process.
    internal static async Task<bool> StopOwnedAsync(Process child)
    {
        try
        {
            if (!child.HasExited) child.Kill(entireProcessTree: true);
            await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
            return child.HasExited;
        }
        catch (Exception ex) when (ex is InvalidOperationException or Win32Exception or TimeoutException or NotSupportedException)
        { return false; }
    }

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint processId);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
