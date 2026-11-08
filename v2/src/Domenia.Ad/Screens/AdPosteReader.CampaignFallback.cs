using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    /// <summary>Automatic inventory fallback is reachable only inside an explicit frozen campaign scope, once per target.</summary>
    internal async Task<WorkstationInventoryRead?> ReadCampaignFallbackAsync(DirectoryComputer expected, AdWorkstationAccess access, CancellationToken token)
    {
        if (!TransientReadAuthorization.Covers(access.Settings, expected.ObjectGuid)) { return null; }
        var local = await LocalAsync(expected.DistinguishedName, token).ConfigureAwait(false);
        if (!Domenia.Core.Queries.QueryComputerIdentity.Of(expected).Matches(local.Computer))
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Cible de campagne modifiée ; aucune collecte ponctuelle."); }
        var result = await ReadTaskFallbackAsync(local, access, RemoteTaskReadKind.InventoryQuick, null, false, token).ConfigureAwait(false);
        if (result.Result is not { WorkerPending: false, Inventory: { } inventory } || !WorkstationIdentity.Matches(expected, inventory.ReportedName, inventory.HostIdentity)) { return null; }
        var disk = inventory.Os?.SystemDrive is { } drive ? inventory.Volumes.FirstOrDefault(v => string.Equals(v.Id, drive, StringComparison.OrdinalIgnoreCase)) : null;
        var state = inventory.Read(InventoryCategories.System) && inventory.Read(InventoryCategories.Volumes) && inventory.Read(InventoryCategories.Bios)
            && inventory.Os is not null && inventory.System is not null && disk?.SizeBytes is > 0 ? MeasureState.Known : MeasureState.Incomplete;
        var at = inventory.CollectedAt;
        return new(new(state, at, disk?.SizeBytes, disk?.FreeBytes, inventory.Os?.LastBoot, inventory.System?.Model,
            inventory.System?.TotalPhysicalMemory, inventory.Os?.Caption, inventory.Os?.Build),
            new(inventory.Console?.Account, inventory.Console?.At, inventory.Bios?.Version, inventory.Bios is null ? null : at,
                state, at, state == MeasureState.Known ? null : "Collecte ponctuelle partielle ; données reçues conservées."))
        { ReportedName = inventory.ReportedName, HostIdentity = inventory.HostIdentity, ReadPhysicallyCompleted = true,
          AuthenticationRejected = inventory.Access.Any(a => a.AuthenticationRejected), RetryFailure = CollectionReadFailure.Success };
    }
}
