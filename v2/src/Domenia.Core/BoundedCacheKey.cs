using System.Security.Cryptography;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>A bounded content key; exceeding the budget means recompute, never hash a truncated prefix.</summary>
public static class BoundedCacheKey
{
    public static string? Create(object value, int maxBytes = 262144, int maxNodes = 4096)
    {
        try
        {
            using var stream = new LimitedStream(maxBytes);
            JsonSerializer.Serialize(stream, value);
            var reader = new Utf8JsonReader(stream.GetBuffer().AsSpan(0, (int)stream.Length));
            var nodes = 0;
            while (reader.Read()) if (++nodes > maxNodes) return null;
            return Convert.ToHexString(SHA256.HashData(stream.GetBuffer().AsSpan(0, (int)stream.Length)));
        }
        catch (CacheLimitException) { return null; }
        catch (JsonException) { return null; }
        catch (NotSupportedException) { return null; }
    }
    private sealed class CacheLimitException : Exception { }
    private sealed class LimitedStream(int limit) : MemoryStream
    {
        public override void Write(byte[] buffer, int offset, int count)
        { if (Length + count > limit) throw new CacheLimitException(); base.Write(buffer, offset, count); }
        public override void Write(ReadOnlySpan<byte> buffer)
        { if (Length + buffer.Length > limit) throw new CacheLimitException(); base.Write(buffer); }
    }
}
