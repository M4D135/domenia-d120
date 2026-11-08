using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>One logical search: bounded retained rows, bounded current page and exact duplicate accounting.
/// Streaming keeps only the current unacknowledged page and bounded identity digests, never a second full result.</summary>
internal sealed class AdPageBuffer
{
    internal const int DefaultRetainedRows = 2000, MaximumRows = AdDirectoryReader.MaxObjectsPerKindLimit + 1;
    internal const long MaximumRetainedBytes = 128L * 1024 * 1024, MaximumPageBytes = 16L * 1024 * 1024;
    private readonly bool retain;
    private readonly bool rootDse;
    private readonly int limit, pageLimit;
    private readonly List<AdEntry> retained = [];
    private List<AdEntry> page = [];
    private readonly HashSet<Guid> guids = [];
    private readonly HashSet<string> names = new(StringComparer.Ordinal);
    private long retainedBytes, pageBytes;
    internal int Accepted { get; private set; }
    internal int Duplicates { get; private set; }
    internal int Refused { get; private set; }
    internal IReadOnlyList<AdEntry> Retained => retained;
    internal IReadOnlyList<AdEntry> Page => page;

    internal AdPageBuffer(AdSearchRequest request)
    {
        retain = request.RetainEntries;
        rootDse = request.Scope == AdSearchScope.Base && request.BaseDn.Length == 0;
        limit = request.SizeLimit > 0 ? request.SizeLimit : retain ? DefaultRetainedRows : MaximumRows;
        pageLimit = AdConnection.EffectivePageSize(request.PageSize);
        if (limit > MaximumRows || request.SizeLimit < 0) throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Limite LDAP hors contrat.");
    }

    internal void BeginPage()
    {
        page = []; pageBytes = 0;
    }

    internal void Add(AdEntry entry)
    {
        var guid = entry.Guid("objectGUID");
        if (guid == Guid.Empty) throw Reject("identité vide");
        if (entry.DistinguishedName.Length > 4096) throw Reject("identité hors limite");
        System.Collections.Immutable.ImmutableArray<RelativeName> parsed;
        try { parsed = DistinguishedName.Parse(entry.DistinguishedName); }
        catch (FormatException) { throw Reject("identité illisible"); }
        if (parsed.IsEmpty && !(rootDse && entry.DistinguishedName.Length == 0)) throw Reject("identité illisible");
        // Fixed-size digests retain neither a potentially large DN nor any account attribute.
        var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(string.Concat(parsed.SelectMany(r => new[] { r.Type.ToUpperInvariant(), r.Value.ToUpperInvariant() }).Select(value => value.Length.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":" + value)))));
        if (names.Contains(key) || guid is { } id && guids.Contains(id))
        { Duplicates++; throw Reject("identité répétée, aucune ligne choisie arbitrairement"); }
        var bytes = Size(entry);
        if (Accepted >= limit || page.Count >= pageLimit || bytes > MaximumPageBytes - pageBytes
            || retain && bytes > MaximumRetainedBytes - retainedBytes) throw Reject("capacité du tampon atteinte");
        names.Add(key); if (guid is { } given) guids.Add(given);
        page.Add(entry); pageBytes += bytes; Accepted++;
        if (retain) { retained.Add(entry); retainedBytes += bytes; }
    }

    private DomeniaOperationException Reject(string reason)
    {
        Refused++;
        return new("ad.bufferLimit", "Lecture LDAP incomplète : " + reason + ". Lignes acceptées : " + Accepted
            + ", doublons : " + Duplicates + ", refusées : " + Refused + ". Aucune fin complète ni absence déduite ; pages déjà acquittées conservées.");
    }

    private static long Size(AdEntry entry)
    {
        long bytes = Encoding.UTF8.GetByteCount(entry.DistinguishedName);
        foreach (var name in entry.AttributeNames)
        {
            bytes += Encoding.UTF8.GetByteCount(name) + 32;
            foreach (var value in entry.Raw(name))
            {
                bytes += value switch { string text => Encoding.UTF8.GetByteCount(text), byte[] binary => binary.LongLength, _ => 32 };
                bytes += 16;
                if (bytes > MaximumPageBytes) return bytes;
            }
        }
        return bytes + 128;
    }
}
