using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    private PosteDetailMemory? Detail(LocalPoste local, string family)
    {
        var memory = local.Fleet.WorkstationDetails.GetValueOrDefault(local.Computer.ObjectGuid)?.GetValueOrDefault(family);
        if (memory is null || memory.Latest.At < local.Computer.WhenCreated || !WorkstationIdentity.MatchesHistorical(local.Computer, memory.Latest.ReportedName, memory.Latest.HostIdentity)) return null;
        if (memory.LastUsable is { } old && (old.At < local.Computer.WhenCreated || !WorkstationIdentity.MatchesHistorical(local.Computer, old.ReportedName, old.HostIdentity))) memory = memory with { LastUsable = null };
        return memory;
    }

    public async Task<PosteDetailMemory?> CachedDetailAsync(string dn, string family, CancellationToken cancellationToken)
    {
        if (!PosteDetailCache.Family(family)) throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Famille de relevé inconnue.");
        var local = await LocalAsync(dn, cancellationToken).ConfigureAwait(false);
        var memory = Detail(local, family);
        EnsureDetailOwner(local);
        return memory;
    }

    private void EnsureDetailOwner(LocalPoste local)
    {
        EnsureEpoch(local.Epoch);
        if (local.Owner != CurrentRecentOwner()) throw new DomeniaOperationException(AdErrors.NotConnected,
            "Compte ou base modifié pendant le relevé détaillé ; publication refusée.");
    }

    private async Task SaveDetailAsync(LocalPoste local, PosteDetailSnapshot detail)
    {
        EnsureDetailOwner(local);
        var needsNativeProof = detail.Complete || detail.Software?.Rows.Length > 0 || detail.Services?.Rows.Length > 0 || detail.Wmi?.Instances.Length > 0;
        if (detail.At < local.Computer.WhenCreated || (needsNativeProof
                ? !WorkstationIdentity.Matches(local.Computer, detail.ReportedName, detail.HostIdentity)
                : !WorkstationIdentity.MatchesHistorical(local.Computer, detail.ReportedName)))
            throw new InvalidDataException("Identité ou date du relevé détaillé incompatible avec le poste.");
        var projected = PosteDetailCache.Project(detail);
        var memory = new PosteDetailMemory(projected, null);
        PosteDetailCache.Validate(memory, projected.Family, source.Clock.GetUtcNow());
        await source.SaveFleetAsync(FleetCachePatch.Empty with
        {
            WorkstationDetails = ImmutableDictionary<Guid, ImmutableDictionary<string, PosteDetailMemory>>.Empty
                .Add(local.Computer.ObjectGuid, ImmutableDictionary<string, PosteDetailMemory>.Empty.Add(projected.Family, memory)),
        }, local.Epoch, CancellationToken.None).ConfigureAwait(false);
        EnsureDetailOwner(local);
    }
}
