using System.Buffers.Binary;
using System.Security;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

// Data only: no script, command line, method name or executable comes from the peer.
internal enum NativeReadKind { Query, Metadata, Registry, Appx, Inventory, Events, LocalAdmins, Diagnostic, WinRmUser, RegistryUser, AccessTrial }
internal sealed record NativeReadHello(string Host, InventoryTransport Transport, int BudgetMs, bool Session, string? Account, bool ReadsEnabled, bool RegistryEnabled);
internal sealed record NativeReadRequest(NativeReadKind Kind, int BudgetMs)
{
    public string? Category { get; init; }
    public string? Namespace { get; init; }
    public string? Query { get; init; }
    public string? ClassName { get; init; }
    public int MaxItems { get; init; }
    public WmiMetadataKind Metadata { get; init; }
    public RegistryRequest? Registry { get; init; }
    public InventoryShellRead Inventory { get; init; }
    public EventQuery? Events { get; init; }
    public DiagnosticTransport Diagnostic { get; init; }
    public string? ExpectedComputerName { get; init; }
    public bool RequireLocalAdministrator { get; init; }
    public MachineAdministrationPrincipal? AdministrationPrincipal { get; init; }

    internal void Check()
    {
        if (!Enum.IsDefined(Kind) || BudgetMs is < 1 or > 300_000) { throw new InvalidDataException("Lecture native hors contrat."); }
        if (AdministrationPrincipal is not null && (Kind != NativeReadKind.AccessTrial || !RequireLocalAdministrator || !AdministrationPrincipal.IsBounded))
        { throw new InvalidDataException("Identité d’administration native hors contrat."); }
        switch (Kind)
        {
            case NativeReadKind.Query:
                if (Category is not { Length: > 0 and <= 256 } || Namespace is not { Length: <= 256 }
                    || Query is not { Length: <= 16_384 } || MaxItems is < 1 or > 20_000 || !CimQuery.IsReadOnlySelect(Query, Namespace))
                { throw new InvalidDataException("Requête native refusée."); }
                break;
            case NativeReadKind.Metadata: CimSession.CheckMetadata(Metadata, Namespace ?? "", ClassName); break;
            case NativeReadKind.Registry:
                if (Registry is null || !InventoryRegistry.Allowed(Registry)) { throw new InvalidDataException("Registre natif refusé."); } break;
            case NativeReadKind.Inventory:
                if (Inventory is not (InventoryShellRead.Certificates or InventoryShellRead.Tasks)) { throw new InvalidDataException("Inventaire natif refusé."); } break;
            case NativeReadKind.Events: _ = WsmanReadChannel.CheckedEventPreset(Events ?? throw new InvalidDataException()); break;
            case NativeReadKind.Diagnostic:
                if (!Enum.IsDefined(Diagnostic)) { throw new InvalidDataException("Diagnostic natif refusé."); } break;
            case NativeReadKind.AccessTrial:
                if (RequireLocalAdministrator && ExpectedComputerName is null) { throw new InvalidDataException("Cible de preuve locale absente."); }
                if (ExpectedComputerName is not null && (!CimQuery.IsHostName(ExpectedComputerName) || ExpectedComputerName.Length > 255))
                { throw new InvalidDataException("Identité d’essai native refusée."); } break;
        }
    }
}

internal sealed record NativeTrialReading(string Outcome, string? ErrorText, string? Category, string? Caption, string? ConfirmedComputerName = null, string? AdministratorSid = null);
internal sealed record NativeReadReply(CimReading? Reading = null, RegistryReading? Registry = null, WorkstationUserReading? User = null, bool Failed = false, NativeTrialReading? Trial = null);

internal static class NativeReadProtocol
{
    internal const int RequestLimit = 65_536;
    internal const int ResponseLimit = 8 * 1024 * 1024;
    internal const int PasswordCharacters = 4096;
    private static readonly JsonSerializerOptions Json = CreateJson();
    private static JsonSerializerOptions CreateJson()
    {
        var options = new JsonSerializerOptions { MaxDepth = 12, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };
        options.Converters.Add(new ValueConverter());
        options.Converters.Add(new InstanceConverter());
        return options;
    }

    private static int primed;

    /// <summary>Builds the serializer metadata of the request and reply graphs once per process, before any request budget
    /// runs: the parent primes while its child starts, the child during its own startup. Bench of 11/11/2026: the first
    /// source of a fresh reading process took 9.5 s against 0.15 s for the same queries read directly, and in WinRM that
    /// cold cost plus a 4.2 s refusal passed the request's deadline. In memory only; nothing leaves the process.</summary>
    internal static void Prime()
    {
        if (Interlocked.Exchange(ref primed, 1) != 0) { return; }
        var request = new NativeReadRequest(NativeReadKind.Query, 1)
        { Category = "Système", Namespace = @"root\cimv2", Query = "SELECT Caption FROM Win32_OperatingSystem", MaxItems = 1 };
        _ = JsonSerializer.Deserialize<NativeReadRequest>(JsonSerializer.SerializeToUtf8Bytes(request, Json), Json);
        var instance = new WmiInstance(new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase) { ["Caption"] = "Windows", ["BuildNumber"] = 26100u });
        var reply = new NativeReadReply(Reading: new CimReading("Système", SourceStatus.Ok, "1 instance lue", 1, [instance]));
        _ = JsonSerializer.Deserialize<NativeReadReply>(JsonSerializer.SerializeToUtf8Bytes(reply, Json), Json);
    }

    internal static async Task WriteAsync<T>(Stream stream, T value, int limit, CancellationToken token)
    {
        // The bounded stream rejects during serialization, before a large response can allocate an unbounded buffer.
        using var buffer = new LimitedBuffer(limit);
        JsonSerializer.Serialize(buffer, value, Json);
        await WriteFrameAsync(stream, buffer.GetBuffer().AsMemory(0, checked((int)buffer.Length)), limit, token).ConfigureAwait(false);
    }

    internal static async Task<T> ReadAsync<T>(Stream stream, int limit, CancellationToken token)
    {
        var bytes = await ReadFrameAsync(stream, limit, token).ConfigureAwait(false);
        try { return JsonSerializer.Deserialize<T>(bytes, Json) ?? throw new InvalidDataException("Réponse native vide."); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    internal static async Task WriteFrameAsync(Stream stream, ReadOnlyMemory<byte> bytes, int limit, CancellationToken token)
    {
        if (bytes.Length > limit) { throw new InvalidDataException("Message natif hors limites."); }
        var header = new byte[8]; BinaryPrimitives.WriteInt32LittleEndian(header, 1); BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(4), bytes.Length);
        await stream.WriteAsync(header, token).ConfigureAwait(false);
        await stream.WriteAsync(bytes, token).ConfigureAwait(false);
        await stream.FlushAsync(token).ConfigureAwait(false);
    }

    internal static async Task<byte[]> ReadFrameAsync(Stream stream, int limit, CancellationToken token)
    {
        var header = new byte[8]; await stream.ReadExactlyAsync(header, token).ConfigureAwait(false);
        var length = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(4));
        if (BinaryPrimitives.ReadInt32LittleEndian(header) != 1 || length < 0 || length > limit) { throw new InvalidDataException("Message natif hors contrat."); }
        var bytes = new byte[length];
        try { await stream.ReadExactlyAsync(bytes, token).ConfigureAwait(false); return bytes; }
        catch { CryptographicOperations.ZeroMemory(bytes); throw; }
    }

    internal static async Task WritePasswordAsync(Stream stream, SecureString? password, CancellationToken token)
    {
        if (password?.Length > PasswordCharacters) { throw new InvalidDataException("Secret natif hors limites."); }
        var bytes = new byte[(password?.Length ?? 0) * 2];
        var pointer = password is null ? IntPtr.Zero : Marshal.SecureStringToGlobalAllocUnicode(password);
        try
        {
            if (pointer != IntPtr.Zero) { Marshal.Copy(pointer, bytes, 0, bytes.Length); }
            await WriteFrameAsync(stream, bytes, PasswordCharacters * 2, token).ConfigureAwait(false);
        }
        finally { CryptographicOperations.ZeroMemory(bytes); if (pointer != IntPtr.Zero) { Marshal.ZeroFreeGlobalAllocUnicode(pointer); } }
    }

    internal static async Task<SecureString?> ReadPasswordAsync(Stream stream, CancellationToken token)
    {
        var bytes = await ReadFrameAsync(stream, PasswordCharacters * 2, token).ConfigureAwait(false);
        SecureString? password = null;
        try
        {
            if ((bytes.Length & 1) != 0) { throw new InvalidDataException("Secret natif hors contrat."); }
            if (bytes.Length == 0) { return null; }
            password = new();
            for (var i = 0; i < bytes.Length; i += 2) { password.AppendChar((char)BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(i, 2))); }
            password.MakeReadOnly(); return password;
        }
        catch { password?.Dispose(); throw; }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    private sealed class LimitedBuffer(int limit) : Stream
    {
        // Composition avoids MemoryStream's compatibility dispatch from Write(span) back to a derived Write(array).
        private readonly MemoryStream storage = new();
        internal byte[] GetBuffer() => storage.GetBuffer();
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => storage.Length;
        public override long Position { get => storage.Position; set => throw new NotSupportedException(); }
        public override void Flush() => storage.Flush();
        public override void Write(byte[] buffer, int offset, int count)
        { CheckLength(count); storage.Write(buffer, offset, count); }
        public override void Write(ReadOnlySpan<byte> buffer)
        { CheckLength(buffer.Length); storage.Write(buffer); }
        private void CheckLength(int count)
        { if (Length + count > limit) { throw new InvalidDataException("Réponse native hors limites."); } }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        protected override void Dispose(bool disposing)
        {
            if (disposing) { CryptographicOperations.ZeroMemory(GetBuffer().AsSpan(0, checked((int)Length))); storage.Dispose(); }
            base.Dispose(disposing);
        }
    }

    private sealed class InstanceConverter : JsonConverter<WmiInstance>
    {
        public override WmiInstance Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        {
            var values = JsonSerializer.Deserialize<Dictionary<string, object?>>(ref reader, options) ?? throw new JsonException();
            if (values.Count > 128 || values.Keys.Any(k => k.Length > 256)) { throw new JsonException(); }
            return new(values);
        }
        public override void Write(Utf8JsonWriter writer, WmiInstance value, JsonSerializerOptions options)
        {
            writer.WriteStartObject(); var count = 0;
            foreach (var name in value.Names)
            {
                if (++count > 128 || name.Length > 256) { throw new JsonException(); }
                writer.WritePropertyName(name); JsonSerializer.Serialize(writer, value.Raw(name), options);
            }
            writer.WriteEndObject();
        }
    }

    private sealed class ValueConverter : JsonConverter<object>
    {
        public override object? Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        {
            switch (reader.TokenType)
            {
                case JsonTokenType.Null: return null;
                case JsonTokenType.True: return true;
                case JsonTokenType.False: return false;
                case JsonTokenType.String:
                    var text = reader.GetString(); if (text?.Length > 32768) { throw new JsonException(); } return text;
                case JsonTokenType.Number:
                    if (reader.TryGetInt64(out var signed)) { return signed; }
                    if (reader.TryGetUInt64(out var unsigned)) { return unsigned; }
                    return reader.GetDouble();
                case JsonTokenType.StartArray:
                    var items = new List<object?>();
                    while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
                    { if (items.Count == 2048 || reader.TokenType is JsonTokenType.StartArray or JsonTokenType.StartObject) { throw new JsonException(); } items.Add(Read(ref reader, typeof(object), options)); }
                    if (reader.TokenType != JsonTokenType.EndArray) { throw new JsonException(); }
                    return items.All(x => x is string) ? items.Cast<string>().ToArray() : items.ToArray();
                default: throw new JsonException();
            }
        }
        public override void Write(Utf8JsonWriter writer, object value, JsonSerializerOptions options)
        {
            if (value is Array array)
            {
                if (array.Rank != 1 || array.Length > 2048) { throw new JsonException(); }
                writer.WriteStartArray();
                foreach (var item in array) { if (item is Array) { throw new JsonException(); } if (item is null) { writer.WriteNullValue(); } else { Write(writer, item, options); } }
                writer.WriteEndArray(); return;
            }
            if (value is string text) { if (text.Length > 32768) { throw new JsonException(); } writer.WriteStringValue(text); return; }
            if (value is not (bool or byte or sbyte or short or ushort or int or uint or long or ulong or float or double or decimal)) { throw new JsonException(); }
            JsonSerializer.Serialize(writer, value, value.GetType(), options);
        }
    }
}
