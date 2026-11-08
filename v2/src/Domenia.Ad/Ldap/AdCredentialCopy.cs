using System.Security;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Caller-owned copy tracked until handed to a native worker (which tracks its own copy).</summary>
internal sealed class AdCredentialCopy(string? user, string? domain, SecureString? password, bool tracked) : IDisposable
{
    private readonly IDisposable? lease = tracked ? SecureCredentialCopies.Track(password) : null;
    internal string? User => user;
    internal string? Domain => domain;
    internal SecureString? Password => password;
    public void Dispose() { lease?.Dispose(); password?.Dispose(); }
}
