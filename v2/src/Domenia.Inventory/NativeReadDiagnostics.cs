using System.ComponentModel;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Domenia.Inventory;

/// <summary>Only one bounded, validated record from our child may reach the journal; never raw stderr.</summary>
internal static class NativeReadDiagnostics
{
    internal const int MaxFrameBytes = 512;
    private const int MaxTypeLength = 256;

    internal enum Phase { Startup, Connect, VerifyPeer, ReadHello, ReadPassword, ValidateHello, Warmup, CreateSession, Handshake, RequestRead, ValidateRequest, Execute, ReplyWrite }
    internal sealed class Context { internal Phase Current { get; set; } = Phase.Startup; }
    internal sealed record Frame(Phase Stage, string ExceptionType, int HResult, int? Win32Code);
    internal sealed record ExitObservation(Frame? Failure, int ExitCode, bool ParentTerminationRequested)
    {
        internal string Format()
        {
            var stage = Failure?.Stage.ToString() ?? "absent";
            var type = Failure?.ExceptionType ?? "absent";
            var hresult = Failure is { } failure ? Hex(failure.HResult) : "absent";
            var win32 = Failure?.Win32Code is { } code ? Hex(code) : "absent";
            return FormattableString.Invariant($"childPhase={stage}; childType={type}; childHresult={hresult}; childWin32={win32}; childExitCode={Hex(ExitCode)}; parentTerminationRequested={ParentTerminationRequested}.");
        }
    }

    internal static Frame Capture(Phase phase, Exception exception)
    {
        var name = exception.GetType().FullName ?? exception.GetType().Name;
        var bounded = new string(name.Take(MaxTypeLength).Select(c => IsTypeCharacter(c) ? c : '?').ToArray());
        return new(phase, bounded, exception.HResult, exception is Win32Exception native ? native.NativeErrorCode : null);
    }

    internal static byte[] Encode(Frame frame)
    {
        if (!Enum.IsDefined(frame.Stage) || !ValidType(frame.ExceptionType)) { throw new InvalidDataException("Diagnostic natif hors contrat."); }
        var win32 = frame.Win32Code?.ToString("X8", CultureInfo.InvariantCulture) ?? "";
        var bytes = Encoding.ASCII.GetBytes(FormattableString.Invariant($"DR1|{frame.Stage}|{frame.ExceptionType}|{frame.HResult:X8}|{win32}"));
        if (bytes.Length > MaxFrameBytes) { CryptographicOperations.ZeroMemory(bytes); throw new InvalidDataException("Diagnostic natif trop long."); }
        return bytes;
    }

    internal static Frame? TryParse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.IsEmpty || bytes.Length > MaxFrameBytes) { return null; }
        foreach (var value in bytes) { if (value is < 32 or > 126) { return null; } }
        var parts = Encoding.ASCII.GetString(bytes).Split('|');
        if (parts.Length != 5 || parts[0] != "DR1"
            || !Enum.TryParse<Phase>(parts[1], out var phase) || !Enum.IsDefined(phase) || parts[1] != phase.ToString()
            || !ValidType(parts[2]) || !TryHex(parts[3], out var hresult)) { return null; }
        int? win32 = null;
        if (parts[4].Length != 0)
        {
            if (!TryHex(parts[4], out var value)) { return null; }
            win32 = value;
        }
        return new(phase, parts[2], hresult, win32);
    }

    internal static void TryWrite(Phase phase, Exception exception)
    {
        byte[]? bytes = null;
#pragma warning disable CA1031 // Diagnostic must never replace the original failure or emit arbitrary exception text.
        try
        {
            bytes = Encode(Capture(phase, exception));
            using var stderr = Console.OpenStandardError();
            stderr.Write(bytes); stderr.Flush();
        }
        catch { }
#pragma warning restore CA1031
        finally { if (bytes is not null) { CryptographicOperations.ZeroMemory(bytes); } }
    }

    internal static async Task<Frame?> ReadAsync(Stream stream)
    {
        var retained = new byte[MaxFrameBytes];
        var scratch = new byte[256];
        var length = 0;
        var oversized = false;
        try
        {
            int read;
            while ((read = await stream.ReadAsync(scratch).ConfigureAwait(false)) != 0)
            {
                // Continue draining an invalid stream without retaining it, until the owned child exits.
                if (oversized) { continue; }
                if (read > retained.Length - length) { oversized = true; continue; }
                scratch.AsSpan(0, read).CopyTo(retained.AsSpan(length)); length += read;
            }
            return oversized ? null : TryParse(retained.AsSpan(0, length));
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or OperationCanceledException) { return null; }
        finally { CryptographicOperations.ZeroMemory(retained); CryptographicOperations.ZeroMemory(scratch); }
    }

    internal static Frame? Finish(Task<Frame?>? reader)
    {
        if (reader is null) { return null; }
#pragma warning disable CA1031 // The child has exited; observe the reader on every cleanup path, without replacing its outcome.
        try { return reader.GetAwaiter().GetResult(); }
        catch { return null; }
#pragma warning restore CA1031
    }

    private static bool ValidType(string? type) => type is { Length: > 0 and <= MaxTypeLength }
        && (char.IsAsciiLetter(type[0]) || type[0] == '_') && type.All(IsTypeCharacter);
    private static bool IsTypeCharacter(char value) => char.IsAsciiLetterOrDigit(value) || ". _+`<>[]*,=&?".IndexOf(value) >= 0;
    private static string Hex(int value) => "0x" + value.ToString("X8", CultureInfo.InvariantCulture);
    private static bool TryHex(string value, out int number)
    {
        number = 0;
        return value.Length == 8 && value.All(char.IsAsciiHexDigit)
            && int.TryParse(value, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out number);
    }
}
