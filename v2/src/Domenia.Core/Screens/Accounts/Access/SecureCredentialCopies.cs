using System.Runtime.InteropServices;
using System.Security;

namespace Domenia.Core;

/// <summary>Tracks borrowed in-process secrets until their real owner finishes. Never serializes or hashes a password.</summary>
public static class SecureCredentialCopies
{
    private static readonly Lock Gate = new();
    private static readonly HashSet<Lease> Active = [];

    /// <summary>The owner must dispose the returned lease before disposing its secret (including after a native timeout).</summary>
    public static IDisposable Track(SecureString? secret)
    {
        var lease = new Lease(secret);
        if (secret is not null) { lock (Gate) { Active.Add(lease); } }
        return lease;
    }

    public static bool Contains(SecureString secret, IDisposable? except = null)
    {
        lock (Gate) { return Active.Any(item => !ReferenceEquals(item, except) && Equal(item.Secret!, secret)); }
    }

    public static bool Equal(SecureString first, SecureString second)
    {
        if (first.Length != second.Length) { return false; }
        var a = IntPtr.Zero; var b = IntPtr.Zero;
        try
        {
            a = Marshal.SecureStringToGlobalAllocUnicode(first); b = Marshal.SecureStringToGlobalAllocUnicode(second);
            var difference = 0;
            for (var index = 0; index < first.Length; index++) { difference |= Marshal.ReadInt16(a, index * 2) ^ Marshal.ReadInt16(b, index * 2); }
            return difference == 0;
        }
        finally { if (a != IntPtr.Zero) { Marshal.ZeroFreeGlobalAllocUnicode(a); } if (b != IntPtr.Zero) { Marshal.ZeroFreeGlobalAllocUnicode(b); } }
    }

    private sealed class Lease(SecureString? secret) : IDisposable
    {
        internal SecureString? Secret => secret;
        public void Dispose() { lock (Gate) { Active.Remove(this); } }
    }
}
