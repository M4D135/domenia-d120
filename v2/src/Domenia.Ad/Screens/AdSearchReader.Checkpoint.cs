using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdSearchReader
{
    private sealed record ControllerStamp(string Controller, Guid Invocation, long? Usn);

    private async Task<ControllerStamp?> ReadControllerStampAsync(string rootDn, CancellationToken token)
    {
        try
        {
            // RootDseAsync caches the bind metadata. A version proof needs a fresh base read on this connection.
            var roots = await source.Connection.SearchAsync(new("", "(objectClass=*)", AdSearchScope.Base,
                ["defaultNamingContext", "configurationNamingContext", "schemaNamingContext", "rootDomainNamingContext", "dnsHostName", "dsServiceName", "isSynchronized", "highestCommittedUSN"])
            { SizeLimit = 2, PageSize = 1, ExpandRanges = false, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(12) }, token).ConfigureAwait(false);
            if (roots.Count != 1 || roots[0].DistinguishedName.Length != 0) { return null; }
            var root = AdConnection.MapRootDse(roots[0]);
            if (root.IsSynchronized != true || string.IsNullOrWhiteSpace(root.DnsHostName) || root.DnsHostName.Length > 255
                || !string.Equals(root.DnsHostName, source.Connection.Server, StringComparison.OrdinalIgnoreCase)
                || !DistinguishedName.AreEqual(root.DefaultNamingContext, rootDn) || string.IsNullOrWhiteSpace(root.ConfigurationNamingContext)
                || root.DsServiceName is not { Length: > 0 and <= 4096 } service
                || !DistinguishedName.IsWithin(service, root.ConfigurationNamingContext, true))
            { return null; }
            var rows = await source.Connection.SearchAsync(new(service, "(objectClass=nTDSDSA)", AdSearchScope.Base, ["invocationID"])
            { SizeLimit = 2, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(12),
                BinaryAttributes = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "invocationID" } }, token).ConfigureAwait(false);
            if (rows.Count != 1 || !DistinguishedName.AreEqual(rows[0].DistinguishedName, service)
                || rows[0].Guid("invocationID") is not { } invocation || invocation == Guid.Empty)
            { return null; }
            return new(root.DnsHostName, invocation, root.HighestCommittedUsn is >= 0 ? root.HighestCommittedUsn : null);
        }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.AccessDenied or AdErrors.NoSuchObject or AdErrors.Timeout)
        { return null; } // No inferred identity or account fallback when the version object is unreadable.
    }

    private static string Fingerprint(object value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value))));

    private static string QueryFingerprint(SearchQuery query, IReadOnlyList<(string Key, string Filter)> stages) => Fingerprint(new
    {
        Base = DistinguishedName.Format(DistinguishedName.Parse(query.BaseDn)).ToUpperInvariant(), query.Subtree, query.Kind,
        query.Type, query.ViewId, query.Take, Filters = stages.Select(s => s.Filter).ToArray(),
    });

    private static string ReaderFingerprint(SessionSnapshot session) => Fingerprint(new
    { Login = session.Account.Login.ToUpperInvariant(), session.Authentication.Method, Root = session.Domain?.RootDn });

    // USNs are local to a controller instance. A manual read stays complete, as does one periodic read
    // every fifteen minutes, to detect moved/deleted/filter-excluded objects without privileged controls.
    private static bool CanReadIncremental(SearchQuery query, string queryFingerprint, string readerFingerprint,
        long epoch, DateTimeOffset at, ControllerStamp? stamp) =>
        query.Incremental && query.Reconcile && query.Checkpoint is { HighestCommittedUsn: >= 0 and < long.MaxValue, FullReadAt: { } full } previous
        && stamp is { Usn: >= 0 } && previous.Epoch == epoch && previous.ReaderFingerprint == readerFingerprint
        && previous.QueryFingerprint == queryFingerprint && previous.Controller.Equals(stamp.Controller, StringComparison.OrdinalIgnoreCase)
        && previous.InvocationId == stamp.Invocation && stamp.Usn >= previous.HighestCommittedUsn
        && previous.ReadAt <= at && full <= at && at - full < TimeSpan.FromMinutes(15);

    private static SearchReadQualification QualifyCheckpoint(SearchQuery query, string queryFingerprint, string readerFingerprint,
        long epoch, DateTimeOffset at, int count, bool partial, ControllerStamp? before, ControllerStamp? after, bool incremental = false)
    {
        var previous = query.Checkpoint;
        if (before is null || after is null || !string.Equals(before.Controller, after.Controller, StringComparison.OrdinalIgnoreCase)
            || before.Invocation != after.Invocation || before.Usn is { } first && after.Usn is { } last && last < first)
        { return new(null, false, false, "Instance du contrôleur non certifiée ou modifiée ; aucun repère avancé ni absence déduite."); }
        var continuous = previous is not null && previous.Epoch == epoch && previous.ReaderFingerprint == readerFingerprint
            && previous.QueryFingerprint == queryFingerprint && previous.ReadAt <= at
            && previous.InvocationId == after.Invocation && string.Equals(previous.Controller, after.Controller, StringComparison.OrdinalIgnoreCase)
            && !(previous.HighestCommittedUsn is { } old && (before.Usn is null || before.Usn < old || after.Usn is null || after.Usn < old));
        if (previous is not null && !continuous)
        { return new(null, false, false, "Contrôleur, instance, compte ou périmètre différent : ancien repère écarté ; prochaine revérification complète requise."); }
        if (partial)
        { return new(null, false, continuous, "Lecture partielle : repère non avancé et aucune absence déduite."); }
        // Store the watermark read BEFORE the query, not after it: a concurrent change after an early page
        // must still be eligible at the next read. The checkpoint is advanced only after the whole delta succeeds.
        var next = new SearchReadCheckpoint(after.Controller, after.Invocation, before.Usn, queryFingerprint, readerFingerprint,
            epoch, at, incremental ? previous!.Count : count) { FullReadAt = incremental ? previous!.FullReadAt : at };
        return new(next, continuous, false, incremental
            ? "Changements depuis le repère précédent ; les absences seront vérifiées à la prochaine lecture complète (15 min au plus, ou Revérifier maintenant)."
            : continuous ? "Même contrôleur et même instance relus ; liste complète dans sa limite." : "Premier repère qualifié ; aucune continuité antérieure supposée.");
    }
}
