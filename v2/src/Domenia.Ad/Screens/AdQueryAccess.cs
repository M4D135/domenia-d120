using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

/// <summary>The same selected LDAP lease qualifies the computer before and after a query workshop reading.</summary>
internal sealed class AdQueryAccess(AdDirectorySource source, DirectoryComputer computer, long epoch, AdReadAccess ldap,
    AdWorkstationAccess machine) : IDisposable
{
    internal DirectoryComputer Computer { get; } = computer;
    internal AdWorkstationAccess Machine { get; } = machine;
    internal long Epoch { get; } = epoch;

    internal static async Task<AdQueryAccess> OpenAsync(AdDirectorySource source, Guid guid, CancellationToken token)
    {
        var epoch = source.Epoch;
        var directory = (await source.ReadLocalAsync(token).ConfigureAwait(false)).Directory;
        var candidates = directory.Computers.Where(c => c.ObjectGuid == guid && guid != Guid.Empty).Take(2).ToArray();
        if (candidates.Length != 1) { throw new DomeniaOperationException(Domenia.Core.Queries.QueryErrors.WmiUnknownComputer, "Poste absent ou ambigu dans la base locale."); }
        var original = candidates[0];
        var ldap = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, original.DistinguishedName, token).ConfigureAwait(false);
        AdWorkstationAccess? machine = null;
        try
        {
            var fresh = await QualifyAsync(source, ldap, original, token).ConfigureAwait(false);
            machine = await AdWorkstationAccess.AcquireAsync(source, fresh.DnsHostName!, token).ConfigureAwait(false);
            var result = new AdQueryAccess(source, fresh, epoch, ldap, machine); result.EnsureCurrent(); return result;
        }
        catch { machine?.Dispose(); ldap.Dispose(); throw; }
    }

    private static async Task<DirectoryComputer> QualifyAsync(AdDirectorySource source, AdReadAccess ldap, DirectoryComputer expected, CancellationToken token)
    {
        var rows = await ldap.SearchAsync(new(expected.DistinguishedName, "(objectClass=computer)", AdSearchScope.Base,
            [.. AdDirectoryMapper.ComputerAttributes, "objectClass"])
        { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(10), ExpandRanges = true, MaxRangeValues = 50_000 }, token).ConfigureAwait(false);
        var fresh = rows.Count == 1 && rows[0].Strings("objectClass").Contains("computer", StringComparer.OrdinalIgnoreCase)
            && DistinguishedName.AreEqual(rows[0].DistinguishedName, expected.DistinguishedName) ? AdDirectoryMapper.Computer(rows[0]) : null;
        if (fresh is null || fresh.ObjectGuid != expected.ObjectGuid || fresh.Sid != expected.Sid || fresh.WhenCreated != expected.WhenCreated
            || fresh.WhenCreated == DateTimeOffset.MinValue || fresh.WhenCreated > source.Clock.GetUtcNow()
            || fresh.DnsHostName is not { } host || !CimQuery.IsHostName(host) || WorkstationIdentity.ExpectedName(fresh) is null)
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité du compte ordinateur absente, modifiée ou incohérente ; lecture écartée."); }
        return fresh;
    }

    internal void EnsureCurrent()
    {
        ldap.EnsureCurrent(); Machine.EnsureCurrent();
        if (source.Epoch != Epoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée ; lecture de requête écartée."); }
    }

    internal async Task ConfirmAsync(string? reportedName, CancellationToken token)
    {
        EnsureCurrent();
        if (!WorkstationIdentity.Matches(Computer, reportedName))
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité Windows non confirmée ; aucune donnée attribuée à ce poste."); }
        await ConfirmDirectoryAsync(token).ConfigureAwait(false);
    }

    internal async Task ConfirmDirectoryAsync(CancellationToken token)
    {
        EnsureCurrent();
        var fresh = await QualifyAsync(source, ldap, Computer, token).ConfigureAwait(false);
        if (!string.Equals(fresh.DnsHostName, Computer.DnsHostName, StringComparison.OrdinalIgnoreCase)
            || !string.Equals(fresh.SamAccountName, Computer.SamAccountName, StringComparison.OrdinalIgnoreCase))
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Cible du compte ordinateur modifiée pendant la lecture ; résultat écarté."); }
        EnsureCurrent();
    }

    public void Dispose() { Machine.Dispose(); ldap.Dispose(); }
}
