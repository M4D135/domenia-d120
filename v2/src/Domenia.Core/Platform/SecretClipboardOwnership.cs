using System.Security.Cryptography;
using System.Runtime.InteropServices;

namespace Domenia.Core;

/// <summary>Only an ownership fingerprint is retained, never the copied secret. A later copy of even the
/// same text belongs to the operator and must survive expiry or application closure.</summary>
public sealed class SecretClipboardOwnership : IDisposable
{
    private readonly Lock gate = new();
    private byte[]? hash;
    private readonly uint sequence;
    public SecretClipboardOwnership(string value, uint sequence)
    {
        this.sequence = sequence;
        hash = SHA256.HashData(MemoryMarshal.AsBytes(value.AsSpan()));
    }
    public bool Matches(string value, uint currentSequence)
    {
        lock (gate)
        {
            if (hash is null || sequence == 0 || sequence != currentSequence) return false;
            var candidate = SHA256.HashData(MemoryMarshal.AsBytes(value.AsSpan()));
            try { return CryptographicOperations.FixedTimeEquals(hash, candidate); }
            finally { CryptographicOperations.ZeroMemory(candidate); }
        }
    }
    public void Dispose()
    {
        lock (gate) { if (hash is { } value) CryptographicOperations.ZeroMemory(value); hash = null; }
    }
}
