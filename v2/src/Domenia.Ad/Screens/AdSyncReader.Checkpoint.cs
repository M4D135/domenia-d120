using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdSyncReader
{
    private sealed record ControllerCheckpoint(string Controller, string ServiceDn, Guid Invocation, long Usn, string Reader);
    private static string ReaderHash(AdReadAccess access) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(access.AccountKey)));

    private static SyncCheckpoint? LocalCheckpoint(SyncLocalState local)
    {
        var entry = local.Scopes.FirstOrDefault(x => x.Key == SyncStateEntry.DirectoryKey && !x.Partial);
        return entry is { Usn: > 0, Server.Length: > 0, InvocationId.Length: > 0, CheckpointItems: >= 0 }
            ? new(entry.Server, entry.InvocationId, entry.Usn, entry.LastSync, entry.CheckpointItems.Value, local.DomainDn) : null;
    }

    private static async Task<ControllerCheckpoint?> ControllerStampAsync(AdReadAccess access, CancellationToken token)
    {
        var root = await access.RootDseAsync(token).ConfigureAwait(false);
        if (root.HighestCommittedUsn is not > 0 || root.IsSynchronized != true || string.IsNullOrWhiteSpace(root.DsServiceName)
            || string.IsNullOrWhiteSpace(root.DnsHostName) || !string.Equals(root.DnsHostName, access.Controller, StringComparison.OrdinalIgnoreCase))
        { return null; }
        var invocation = await ReadInvocationAsync(access, root.DsServiceName, token).ConfigureAwait(false);
        return invocation is { } id ? new(root.DnsHostName, root.DsServiceName, id, root.HighestCommittedUsn.Value, ReaderHash(access)) : null;
    }

    private static async Task<Guid?> ReadInvocationAsync(AdReadAccess access, string serviceDn, CancellationToken token)
    {
        var rows = await access.SearchForestAsync(new(serviceDn, "(objectClass=nTDSDSA)", AdSearchScope.Base, ["invocationID"])
        { SizeLimit = 2, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(15), BinaryAttributes = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "invocationID" } }, token).ConfigureAwait(false);
        if (rows.Count != 1 || !DistinguishedName.AreEqual(rows[0].DistinguishedName, serviceDn)) { return null; }
        return rows[0].Guid("invocationID") is { } id && id != Guid.Empty ? id : null;
    }

    private SyncCheckpointCheck CanUseCheckpoint(SyncLocalState local, ControllerCheckpoint? remote)
    {
        if (remote is null) { return new(false, "NoInstance", "Instance du contrôleur non certifiée ; lecture complète, sans avancement USN."); }
        var previous = LocalCheckpoint(local);
        var check = SyncCoverageRules.CheckCheckpoint(previous, remote.Controller, local.DomainDn, local.Rows.Length, remote.Usn, source.Clock.GetUtcNow());
        if (!check.Usable) { return check; }
        if (previous!.Count > local.Rows.Length || previous.Usn == long.MaxValue || local.UnidentifiedLegacyObjects > 0)
        { return new(false, "IncompleteBase", "La base ne contient plus toutes les identités du repère ; lecture complète."); }
        if (!string.Equals(previous!.InvocationId, remote.Invocation.ToString("D"), StringComparison.OrdinalIgnoreCase))
        { return new(false, "OtherInstance", "Instance du contrôleur différente ; aucun ancien USN réutilisé."); }
        if (local.Scopes.Single(x => x.Key == SyncStateEntry.DirectoryKey).ReaderFingerprint != remote.Reader)
        { return new(false, "OtherReader", "Compte lecteur différent ou inconnu ; lecture complète du périmètre visible."); }
        return check;
    }

    private static string DeltaFilter(string filter, SyncCheckpoint checkpoint) => "(&" + filter + "(uSNChanged>="
        + checked(checkpoint.Usn + 1).ToString(CultureInfo.InvariantCulture) + "))";

    private static async Task<HashSet<Guid>> CensusAsync(AdReadAccess access, string domain, int maximum, CancellationToken token)
    {
        var entries = await access.SearchAsync(new(domain, "(|" + AdDirectoryMapper.ComputerFilter + AdDirectoryMapper.UserFilter + ")", AdSearchScope.Subtree,
            ["objectGUID", "distinguishedName"]) { SizeLimit = maximum + 1, PageSize = 500, Budget = TimeSpan.FromMinutes(20) }, token).ConfigureAwait(false);
        if (entries.Count > maximum) { throw new DomeniaOperationException("sync.censusVolume", "Recensement au-delà de la limite confirmée ; repère USN conservé."); }
        var ids = new HashSet<Guid>();
        foreach (var entry in entries)
        {
            if (entry.Guid("objectGUID") is not { } id || id == Guid.Empty || !ids.Add(id) || !SyncLocations.InScope(entry.DistinguishedName, domain))
            { throw new InvalidDataException("Recensement sans identité, dupliqué ou hors domaine ; repère USN conservé."); }
        }
        return ids;
    }
}
