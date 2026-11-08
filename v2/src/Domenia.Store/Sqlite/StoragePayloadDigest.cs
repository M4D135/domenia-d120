using System.Security.Cryptography;
using System.Text.Json;

namespace Domenia.Store;

/// <summary>Hashes a bounded serialization without retaining a second full copy of a fleet payload.</summary>
internal sealed class StoragePayloadDigest(long maximum, CancellationToken token) : Stream
{
    private readonly IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    internal long Bytes { get; private set; }
    internal string Finish() => Convert.ToHexStringLower(hash.GetHashAndReset());
    public override void Write(byte[] buffer, int offset, int count) => Write(buffer.AsSpan(offset, count));
    public override void Write(ReadOnlySpan<byte> buffer)
    {
        token.ThrowIfCancellationRequested();
        if (buffer.Length > maximum - Bytes) throw new InvalidDataException("Lot local trop volumineux ; aucune admission ni écriture.");
        hash.AppendData(buffer); Bytes += buffer.Length;
    }
    public override bool CanRead => false;
    public override bool CanSeek => false;
    public override bool CanWrite => true;
    public override long Length => Bytes;
    public override long Position { get => Bytes; set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { if (disposing) hash.Dispose(); base.Dispose(disposing); }

    internal static (long Bytes, string Sha256) Of(object payload, JsonSerializerOptions options, long maximum, CancellationToken token)
    {
        using var stream = new StoragePayloadDigest(maximum, token);
        JsonSerializer.Serialize(stream, payload, options);
        return (stream.Bytes, stream.Finish());
    }
}
