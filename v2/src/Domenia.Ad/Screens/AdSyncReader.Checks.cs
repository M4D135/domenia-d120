using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdSyncReader
{
    public async Task<AbsenceCheckResult> CheckAbsencesAsync(Action<SyncProgress> progress, CancellationToken cancellationToken)
    {
        var local = await Store.ReadSyncStateAsync(cancellationToken).ConfigureAwait(false);
        var selection = SyncAbsences.SelectToCheck(local.Absences);
        if (selection.IsEmpty) { throw new DomeniaOperationException(SyncErrors.NothingToCheck, SyncErrors.NothingToCheckMessage); }
        var (records, read, server, at, epoch) = await ReadIdentitiesAsync(local.DomainDn, [.. selection.Select(x => x.ObjectGuid)], progress, cancellationToken).ConfigureAwait(false);
        var outcomes = selection.Select(a =>
        {
            records.TryGetValue(a.ObjectGuid, out var record);
            return (Original: a, Outcome: SyncAbsences.Resolve(a, new(read, record?.Dn, DeletedProbe.NotRequested, false, null, null, false, record), source.Zone));
        }).ToArray();
        var resolutions = outcomes.Select(x => x.Outcome.Resolution).ToImmutableArray();
        var changed = outcomes.Select(x => x.Original with { Status = x.Outcome.Status, FoundDn = x.Outcome.FoundDn, CheckedAt = at, Detail = x.Outcome.Detail, Server = server }).ToImmutableArray();
        var kept = outcomes.Select(x => x.Outcome.Keep).OfType<IndexRecord>().ToImmutableArray();
        var batch = new AdSyncBatch(WritePlans.NewId(), "Vérification des disparitions", epoch, at, at.AddMinutes(15), kept, null, changed, []);
        batch = batch.AtBase(local);
            State.Hold(batch);
        return new(batch.Id, selection.Length, SyncAbsences.Counts(resolutions), DeletedProbe.NotRequested,
            "Objets supprimés non interrogés ; une absence ne prouve aucune suppression.", server, at, resolutions,
            "Vérification par GUID terminée. Les objets retrouvés peuvent être réintégrés ; les autres restent non confirmés.", true, batch.Expires);
    }

    public async Task<GapReadResult> ReadGapsAsync(Action<SyncProgress> progress, CancellationToken cancellationToken)
    {
        var local = await Store.ReadSyncStateAsync(cancellationToken).ConfigureAwait(false);
        var selection = local.Gaps.OrderBy(x => x.SeenAt).ThenBy(x => x.ObjectGuid).Take(SyncAbsences.CheckLimit).ToImmutableArray();
        if (selection.IsEmpty) { throw new DomeniaOperationException(SyncErrors.NothingToRead, SyncErrors.NothingToReadMessage); }
        var (records, read, _, at, epoch) = await ReadIdentitiesAsync(local.DomainDn, [.. selection.Select(x => x.ObjectGuid)], progress, cancellationToken).ConfigureAwait(false);
        var outcomes = selection.Select(g =>
        {
            records.TryGetValue(g.ObjectGuid, out var record);
            return (Original: g, Outcome: SyncAbsences.ResolveGap(g, new(read, record?.Dn, record)));
        }).ToArray();
        var resolutions = outcomes.Select(x => x.Outcome.Resolution).ToImmutableArray();
        var kept = outcomes.Select(x => x.Outcome.Keep).OfType<IndexRecord>().ToImmutableArray();
        var resolved = outcomes.Where(x => x.Outcome.LeavesList).Select(x => x.Original.ObjectGuid).ToImmutableArray();
        var batch = new AdSyncBatch(WritePlans.NewId(), "Identités manquantes du recensement", epoch, at, at.AddMinutes(15), kept, null, [], resolved);
        batch = batch.AtBase(local);
            State.Hold(batch);
        var gone = resolutions.Count(x => x.Status == "notFound");
        return new(batch.Id, selection.Length, kept.Length, gone, selection.Length - kept.Length - gone, resolutions,
            "Lecture ciblée terminée ; aucun résultat n’est enregistré sans confirmation du plan.", kept.Length + resolved.Length > 0, batch.Expires);
    }

    private async Task<(Dictionary<Guid, IndexRecord> Rows, DomainRead Read, string Server, DateTimeOffset At, long Epoch)> ReadIdentitiesAsync(
        string domain, ImmutableArray<Guid> identities, Action<SyncProgress> progress, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(progress);
        var epoch = source.Epoch;
        var run = Start(SyncTarget.Domain, "Lecture ciblée par GUID");
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token, run.Stop.Token); stop.CancelAfter(TimeSpan.FromSeconds(SyncAbsences.BudgetSeconds));
        var rows = new Dictionary<Guid, IndexRecord>(); var read = DomainRead.Read;
        try
        {
            using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, domain, stop.Token).ConfigureAwait(false);
            var properties = AdDirectoryMapper.UserAttributes.Concat(AdDirectoryMapper.ComputerAttributes).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            for (var offset = 0; offset < identities.Length; offset += SyncAbsences.BatchSize)
            {
                var group = identities.Skip(offset).Take(SyncAbsences.BatchSize).ToHashSet();
                try
                {
                    var entries = await access.SearchAsync(new(domain, "(&(|" + AdDirectoryMapper.ComputerFilter + AdDirectoryMapper.UserFilter + ")(|" + string.Concat(group.Select(AdObjectAccess.GuidFilter)) + "))", AdSearchScope.Subtree, properties)
                    { PageSize = 50, SizeLimit = group.Count + 1, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(15) }, stop.Token).ConfigureAwait(false);
                    if (entries.Count > group.Count) { throw new InvalidDataException("Identités ambiguës dans la réponse ciblée."); }
                    foreach (var entry in entries)
                    {
                        var type = entry.Strings("objectClass").Contains("computer", StringComparer.OrdinalIgnoreCase) || entry.Has("dNSHostName") ? IndexObjectType.Computer : IndexObjectType.User;
                        var row = Project(entry, type, source.Clock.GetUtcNow());
                        if (row is null || !group.Contains(row.ObjectGuid) || !SyncLocations.InScope(row.Dn, domain) || !rows.TryAdd(row.ObjectGuid, row))
                        { throw new InvalidDataException("Identité de réponse ciblée absente, dupliquée ou hors domaine."); }
                    }
                    progress(new(run.Id, SyncPhase.Reading, "Vérification par GUID", Math.Min(identities.Length, offset + group.Count), identities.Length, null, 0, null, "Objets effectivement retrouvés : " + rows.Count));
                }
                catch (OperationCanceledException) { read = DomainRead.Unavailable; break; }
                catch (DomeniaOperationException) { read = DomainRead.Refused; break; }
            }
            access.EnsureCurrent();
            // A partly failed identity pass never declares the unreturned tail absent.
            if (read != DomainRead.Read) { rows.Clear(); }
            return (rows, read, access.Controller ?? "Non établi", source.Clock.GetUtcNow(), epoch);
        }
        finally { Finish(run.Stop); }
    }
}
