using System.Security.Cryptography;
using System.Text;

namespace Domenia.Core;

/// <summary>Answer of <see cref="ConfirmationTokens.Check"/>.</summary>
public enum TokenCheck
{
    Valid,
    Unknown,
    Invalid,
    Expired,
    Used,
}

/// <summary>
/// Single-use confirmation tokens of the write plans (docs/WRITES.md § 3). A token is 32 random bytes (43 characters, base64url)
/// handed to the page with its plan; only the SHA-256 of « token | fingerprint of the plan » is kept, so a token is bound to
/// the exact plan it was issued for: a plan changed after sealing never matches. A token expires with its plan (five minutes)
/// and is consumed by the first execution that passes the checks, whatever the outcome afterwards: a write never runs twice
/// from one confirmation (Domenia 1 TRV-232). Comparisons run in constant time. Thread safe.
/// </summary>
public sealed class ConfirmationTokens
{
    /// <summary>Length of a token: 32 bytes in base64url without padding.</summary>
    public const int TokenLength = 43;

    /// <summary>Most tokens kept; the oldest expired or used ones go first.</summary>
    public const int Capacity = 64;

    private readonly Lock gate = new();
    private readonly Dictionary<string, Entry> entries = new(StringComparer.Ordinal);

    /// <summary>Issues the token of a plan; a plan has only one token.</summary>
    public string Issue(string planId, string fingerprint, DateTimeOffset expiresAt, DateTimeOffset now)
    {
        ArgumentException.ThrowIfNullOrEmpty(planId);
        ArgumentException.ThrowIfNullOrEmpty(fingerprint);
        var token = Base64Url(RandomNumberGenerator.GetBytes(32));
        lock (gate)
        {
            if (entries.ContainsKey(planId))
            {
                throw new InvalidOperationException("A plan has only one confirmation token.");
            }
            Purge(now);
            entries.Add(planId, new Entry(Bind(token, fingerprint), expiresAt));
        }
        return token;
    }

    /// <summary>Checks a token without consuming it. <paramref name="fingerprint"/> is recomputed from the plan as it is now.</summary>
    public TokenCheck Check(string planId, string token, string fingerprint, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(planId);
        ArgumentNullException.ThrowIfNull(token);
        ArgumentNullException.ThrowIfNull(fingerprint);
        lock (gate)
        {
            if (!entries.TryGetValue(planId, out var entry))
            {
                return TokenCheck.Unknown;
            }
            if (entry.Used)
            {
                return TokenCheck.Used;
            }
            if (!CryptographicOperations.FixedTimeEquals(entry.Hash, Bind(token, fingerprint)))
            {
                return TokenCheck.Invalid;
            }
            return now >= entry.ExpiresAt ? TokenCheck.Expired : TokenCheck.Valid;
        }
    }

    /// <summary>
    /// Consumes a token: true for the first caller only (a double click, or two pages, never send a plan twice). False when the
    /// token is unknown or already used.
    /// </summary>
    public bool Consume(string planId)
    {
        ArgumentNullException.ThrowIfNull(planId);
        lock (gate)
        {
            if (!entries.TryGetValue(planId, out var entry) || entry.Used)
            {
                return false;
            }
            entry.Used = true;
            return true;
        }
    }

    /// <summary>Well-formed token text (43 base64url characters); anything else is refused before any lookup.</summary>
    public static bool IsWellFormed(string? token) =>
        token is { Length: TokenLength } && token.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');

    private void Purge(DateTimeOffset now)
    {
        // Used tokens stay until well after their expiry, so a second attempt is told « already used », not « unknown ».
        foreach (var key in entries.Where(p => now >= p.Value.ExpiresAt + WritePlans.Lifetime).Select(p => p.Key).ToList())
        {
            entries.Remove(key);
        }
        while (entries.Count >= Capacity)
        {
            entries.Remove(entries.MinBy(p => p.Value.ExpiresAt).Key);
        }
    }

    private static byte[] Bind(string token, string fingerprint) => SHA256.HashData(Encoding.UTF8.GetBytes(token + "|" + fingerprint));

    private static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private sealed class Entry(byte[] hash, DateTimeOffset expiresAt)
    {
        public byte[] Hash { get; } = hash;

        public DateTimeOffset ExpiresAt { get; } = expiresAt;

        public bool Used { get; set; }
    }
}
