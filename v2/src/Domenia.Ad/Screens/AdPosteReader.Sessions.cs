using Domenia.Core.Poste;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    private async Task<LegacySessionCacheRead> StoredSessionsAsync(LocalPoste local, CancellationToken token)
    {
        var current = PosteSessionCache.Applicable(local.Fleet.WorkstationSessions.GetValueOrDefault(local.Computer.ObjectGuid), local.Computer.WhenCreated, source.Clock.GetUtcNow());
        if (source.LocalStore is not ILegacySessionCache legacy) { return new(current, null); }
        LegacySessionCacheRead previous;
        try { previous = await legacy.ReadLegacySessionsAsync(local.Computer, token).ConfigureAwait(false); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { previous = new(null, "Historique Domenia 1 inaccessible ; aucune nouvelle lecture au poste."); }
        EnsureEpoch(local.Epoch);
        var old = PosteSessionCache.Applicable(previous.Memory, local.Computer.WhenCreated, source.Clock.GetUtcNow());
        if (old is null) { return new(current, previous.Notice); }
        if (current is null) { return new(old, previous.Notice); }
        // Older complete D1 data may fill the history of a later V2 failure. Equal dates keep V2 unchanged.
        var combined = current.Latest.At >= old.Latest.At ? PosteSessionCache.Merge(old, current) : PosteSessionCache.Merge(current, old);
        if (current.Latest.At == old.Latest.At) { combined = current; }
        return new(combined, previous.Notice);
    }
}
