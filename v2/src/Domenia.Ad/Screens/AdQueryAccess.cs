using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

/// <summary>The same selected LDAP lease qualifies the computer before and after a query workshop reading.</summary>
internal sealed class AdQueryAccess(AdDirectorySource source, DirectoryComputer computer, long epoch,
    AdWorkstationReadAccess held) : IDisposable
{
    private readonly AdReadAccess ldap = held.Directory;
    internal AdWorkstationReadAccess Held => held;
    internal DirectoryComputer Computer { get; } = computer;
    internal AdWorkstationAccess Machine { get; } = held.Machine;
    internal long Epoch { get; } = epoch;

    internal static async Task<AdQueryAccess> OpenAsync(AdDirectorySource source, Guid guid, CancellationToken token,
        long? expectedAccountVersion = null, long? expectedMachineGeneration = null)
    {
        var epoch = source.Epoch;
        var directory = (await source.ReadLocalAsync(token).ConfigureAwait(false)).Directory;
        var original = AdComputerIndex.For(directory).Find(guid)
            ?? throw new DomeniaOperationException(Domenia.Core.Queries.QueryErrors.WmiUnknownComputer, "Poste absent ou ambigu dans la base locale.");
        if (!HasWindowsTarget(original) || original.DnsHostName is not { } host)
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité locale sans cible Windows valide ; aucun contact distant."); }
        if (source.Epoch != epoch)
        { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée depuis la lecture locale ; aucun contact distant."); }
        // Admit both credentials in the order selected by the non-consuming LDAP preview. The shared
        // owner retains the exact identities through both qualifications and the physical native read.
        var held = await AdWorkstationReadAccess.AcquireAsync(source, host, original.DistinguishedName, token,
            expectedAccountVersion, expectedMachineGeneration).ConfigureAwait(false);
        try
        {
            if (source.Epoch != epoch)
            { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée pendant l’admission ; aucun contact distant."); }
            var fresh = await QualifyAsync(source, held.Directory, original, token).ConfigureAwait(false);
            if (!Domenia.Core.Queries.QueryComputerIdentity.Of(original).Matches(fresh))
            { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Cible modifiée depuis la lecture locale ; aucun contact CIM."); }
            await held.Machine.BeforeContactAsync(source, host, token).ConfigureAwait(false);
            var result = new AdQueryAccess(source, fresh, epoch, held); result.EnsureCurrent(); return result;
        }
        catch { held.Dispose(); throw; }
    }

    /// <summary>
    /// A computer account that can be a qualified Windows target: a valid DNS host name whose first label matches the account
    /// name. A pre-staged account (no dNSHostName) or a renamed one whose DNS name was not updated has none.
    /// </summary>
    internal static bool HasWindowsTarget(DirectoryComputer computer) => computer.DnsHostName is { } host && CimQuery.IsHostName(host)
        && WorkstationIdentity.ExpectedName(computer) is not null;

    internal static async Task<DirectoryComputer> QualifyAsync(AdDirectorySource source, AdReadAccess ldap, DirectoryComputer expected, CancellationToken token)
    {
        var rows = await ldap.SearchAsync(new(expected.DistinguishedName, "(objectClass=computer)", AdSearchScope.Base,
            [.. AdDirectoryMapper.ComputerAttributes, "objectClass"])
        { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(10), ExpandRanges = true, MaxRangeValues = 50_000 }, token).ConfigureAwait(false);
        var fresh = rows.Count == 1 && rows[0].Strings("objectClass").Contains("computer", StringComparer.OrdinalIgnoreCase)
            && DistinguishedName.AreEqual(rows[0].DistinguishedName, expected.DistinguishedName) ? AdDirectoryMapper.Computer(rows[0]) : null;
        if (fresh is null || fresh.ObjectGuid != expected.ObjectGuid || fresh.Sid != expected.Sid || fresh.WhenCreated != expected.WhenCreated
            || fresh.WhenCreated == DateTimeOffset.MinValue || fresh.WhenCreated > source.Clock.GetUtcNow()
            || !HasWindowsTarget(fresh))
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité du compte ordinateur absente, modifiée ou incohérente ; lecture écartée."); }
        return fresh;
    }

    internal void EnsureCurrent()
    {
        ldap.EnsureCurrent(); Machine.EnsureCurrent();
        if (source.Epoch != Epoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée ; lecture de requête écartée."); }
    }

    internal async Task ConfirmAsync(string? reportedName, CancellationToken token, NativeWorkstationIdentity? native)
    {
        EnsureCurrent();
        if (!WorkstationIdentity.Matches(Computer, reportedName, native))
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité Windows non confirmée ; aucune donnée attribuée à ce poste."); }
        await ConfirmDirectoryAsync(token).ConfigureAwait(false);
    }

    internal async Task ConfirmDirectoryAsync(CancellationToken token)
    {
        EnsureCurrent();
        var fresh = await QualifyAsync(source, ldap, Computer, token).ConfigureAwait(false);
        if (!Domenia.Core.Queries.QueryComputerIdentity.Of(Computer).Matches(fresh))
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Cible du compte ordinateur modifiée pendant la lecture ; résultat écarté."); }
        EnsureCurrent();
    }

    public void Dispose() => held.Dispose();
}
