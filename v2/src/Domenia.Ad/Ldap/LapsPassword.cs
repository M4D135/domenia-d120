using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Owned current LAPS value. No JSON serializer, exception or ToString may expose the password.</summary>
internal sealed class LapsPassword(string account, DateTimeOffset updated, char[] password) : IDisposable
{
    internal string Account { get; } = account;
    internal DateTimeOffset Updated { get; } = updated;
    internal ReadOnlySpan<char> Password => password;
    public void Dispose() => Array.Clear(password);
    public override string ToString() => "Mot de passe LAPS (contenu masqué)";

    internal const int MaxJsonBytes = 16 * 1024;
    internal const int MaxBlobBytes = 128 * 1024;
    internal static DomeniaOperationException Invalid() => new("poste.lapsInvalid", "Valeur LAPS illisible ou incohérente ; aucun mot de passe affiché.");

    internal static long CheckEnvelope(ReadOnlySpan<byte> data)
    {
        if (data.Length is < 17 or > MaxBlobBytes || BinaryPrimitives.ReadUInt32LittleEndian(data[8..]) != data.Length - 16
            || BinaryPrimitives.ReadUInt32LittleEndian(data[12..]) != 0) { throw Invalid(); }
        var timestamp = BinaryPrimitives.ReadInt64LittleEndian(data);
        if (AdValues.FromFileTime(timestamp) is null) { throw Invalid(); }
        return timestamp;
    }

    internal static LapsPassword ParseText(string value)
    {
        if (value.Length > MaxJsonBytes) { throw Invalid(); }
        byte[] bytes;
        try { bytes = new UTF8Encoding(false, true).GetBytes(value); }
        catch (EncoderFallbackException) { throw Invalid(); }
        try { return ParseUtf8(bytes); } finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    internal static LapsPassword ParseUtf16(byte[] value, long timestamp)
    {
        if (value.Length is < 2 or > MaxJsonBytes || value.Length % 2 != 0) { throw Invalid(); }
        var length = value.Length;
        if (value[^1] == 0 && value[^2] == 0) { length -= 2; }
        byte[]? utf8 = null;
        try
        {
            utf8 = Encoding.Convert(new UnicodeEncoding(false, false, true), new UTF8Encoding(false, true), value, 0, length);
            return ParseUtf8(utf8, timestamp);
        }
        catch (DecoderFallbackException) { throw Invalid(); }
        finally { if (utf8 is not null) { CryptographicOperations.ZeroMemory(utf8); } }
    }

    internal static LapsPassword ParseUtf8(ReadOnlySpan<byte> value, long? timestamp = null)
    {
        char[]? password = null;
        try
        {
            if (value.Length is < 2 or > MaxJsonBytes) { throw Invalid(); }
            var json = new Utf8JsonReader(value, new JsonReaderOptions { MaxDepth = 4 });
            if (!json.Read() || json.TokenType != JsonTokenType.StartObject) { throw Invalid(); }
            string? account = null; long? updated = null; var fields = new HashSet<string>(StringComparer.Ordinal);
            while (json.Read() && json.TokenType != JsonTokenType.EndObject)
            {
                if (json.TokenType != JsonTokenType.PropertyName) { throw Invalid(); }
                // Closed schema: unknown fields cannot be mistaken for a second password or an authorization claim.
                var name = json.ValueTextEquals("n") ? "n" : json.ValueTextEquals("t") ? "t" : json.ValueTextEquals("p") ? "p" : null;
                if (name is null || !fields.Add(name) || !json.Read() || json.TokenType != JsonTokenType.String) { throw Invalid(); }
                var buffer = new char[json.ValueSpan.Length];
                try
                {
                    var count = json.CopyString(buffer); var text = buffer.AsSpan(0, count);
                    if (count is < 1 or > 256 || text.ContainsAny('\0', '\r', '\n')) { throw Invalid(); }
                    switch (name)
                    {
                        case "n":
                            if (text.ContainsAny('\\', '/', '@') || text.ToArray().Any(char.IsControl)) { throw Invalid(); }
                            account = new string(text); break;
                        case "t":
                            if (count > 16 || !long.TryParse(text, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var fileTime)
                                || AdValues.FromFileTime(fileTime) is null) { throw Invalid(); }
                            updated = fileTime; break;
                        case "p": password = text.ToArray(); break;
                    }
                }
                finally { Array.Clear(buffer); }
            }
            if (json.TokenType != JsonTokenType.EndObject || json.Read() || account is null || updated is null || password is null
                || timestamp is not null && timestamp != updated) { throw Invalid(); }
            var result = new LapsPassword(account, AdValues.FromFileTime(updated)!.Value, password); password = null; return result;
        }
        catch (JsonException) { throw Invalid(); }
        catch (InvalidOperationException) { throw Invalid(); }
        finally { if (password is not null) { Array.Clear(password); } }
    }
}
