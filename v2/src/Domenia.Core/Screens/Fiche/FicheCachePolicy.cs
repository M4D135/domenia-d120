using System.Security.Cryptography;
using System.Text;

namespace Domenia.Core;

/// <summary>Identity of a local read, not authorization to write. A DN is a locator, never part of this key.</summary>
public sealed record FicheCacheProvenance(string DomainDn, Guid ObjectGuid, string ReaderHash, string? Controller,
    Guid? InvocationId, long? UsnChanged)
{
    public string CacheKey => Key(DomainDn, ObjectGuid, ReaderHash);
    public bool VersionQualified => Controller is { Length: > 0 } && InvocationId is { } id && id != Guid.Empty && UsnChanged is >= 0;
    public static string ReaderKey(string login) => Hash(login.Trim().ToUpperInvariant());
    public static string Key(string domain, Guid id, string reader) => Hash(DistinguishedName.Format(DistinguishedName.Parse(domain)).ToUpperInvariant()
        + "|" + id.ToString("D") + "|" + reader);
    private static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    public bool IsValid => ObjectGuid != Guid.Empty && !string.IsNullOrWhiteSpace(DomainDn)
        && ReaderHash is { Length: 64 } && ReaderHash.All(char.IsAsciiHexDigitLower)
        && (Controller is null || Controller.Length is > 0 and <= 255) && InvocationId != Guid.Empty && UsnChanged is not < 0;
    public bool SameReader(string readerHash) => IsValid && ReaderHash == readerHash;
    public bool SameVersion(FicheCacheProvenance other) => VersionQualified && other.VersionQualified && CacheKey == other.CacheKey
        && string.Equals(Controller, other.Controller, StringComparison.OrdinalIgnoreCase) && InvocationId == other.InvocationId && UsnChanged == other.UsnChanged;
}

public sealed record FicheCacheDecision(bool Consult, bool Copy, bool Modify, string State, string Reason);

/// <summary>Shared consultation/copy/edit decision. Cached data never authorize a write, regardless of age.</summary>
public static class FicheCachePolicy
{
    public static readonly TimeSpan Freshness = TimeSpan.FromMinutes(15);
    public static FicheCacheDecision Decide(bool live, DateTimeOffset? observed, DateTimeOffset now, bool identityKnown = true)
    {
        if (!identityKnown) return new(false, false, false, "unknown", "Identité de l’objet non confirmée : relisez la fiche.");
        if (observed is not { } at || at == DateTimeOffset.MinValue || at > now.AddMinutes(5))
            return new(true, true, false, "unknown", "Date de lecture inconnue ou future : consultation historique uniquement, relecture nécessaire avant modification.");
        if (!live) return new(true, true, false, now - at <= Freshness ? "cached" : "expired",
            "Consultation historique hors ligne. Copie des valeurs affichées autorisée ; aucune modification sans relecture de l’annuaire.");
        if (now - at > Freshness) return new(true, true, false, "expired", "Lecture de plus de 15 minutes : consultation et copie possibles, relisez avant de modifier.");
        return new(true, true, true, "live", "Lecture récente de l’annuaire ; chaque écriture vérifie encore l’identité et la version de l’objet.");
    }
}
