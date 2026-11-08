using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Real fiche reads. Local entry points never connect; network reads are bounded and tied to the session generation.</summary>
public sealed partial class AdFicheReader(AdDirectorySource source) : IFicheReader, IFicheVisitCacheReader, IRuntimeConfigurationConsumer
{
    private readonly AdFicheObjects objects = new(source);
    private readonly Lock localGate = new();
    private FicheVisitCache<FicheLocalRead> recent = new(source.Clock, TimeSpan.FromSeconds(45));
    private FicheVisitCache<FicheSummary> seen = new(source.Clock, TimeSpan.FromSeconds(90));
    public void Configure(RuntimeConfiguration configuration)
    {
        var maximum = configuration.Integer("Cache", "MaxEntries", 400);
        recent = new(source.Clock, TimeSpan.FromSeconds(configuration.Integer("Cache", "ObjectTtlSeconds", 45)), maximum);
        seen = new(source.Clock, TimeSpan.FromSeconds(configuration.Integer("Cache", "TtlSeconds", 90)), maximum);
    }
    internal FicheVisitMetrics ObjectVisits => recent.Metrics;
    internal FicheVisitMetrics SummaryVisits => seen.Metrics;
    private long recentEpoch = -1;
    private long recentDirectoryRevision = -1;

    private void EnsureEpoch(long epoch)
    {
        if (source.Epoch != epoch) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la lecture de fiche."); }
    }

    private async Task<long> NetworkEpochAsync(string dn, CancellationToken token)
    {
        AdFicheObjects.ValidateDn(dn);
        var domain = await source.DomainAsync(token).ConfigureAwait(false);
        AdFicheObjects.EnsureDomain(dn, domain.RootDn);
        return source.Epoch;
    }

    private async Task RememberAsync(FicheRead read, long epoch, CancellationToken token)
    {
        EnsureEpoch(epoch);
        var item = new FicheLocalRead(read.Entry, read.ReadAt) { Provenance = read.Provenance };
        if (source.LocalStore is IFicheCache cache) { item = await cache.SaveFicheAsync(item, token).ConfigureAwait(false); }
        EnsureEpoch(epoch);
        lock (localGate)
        {
            ResetRecent();
            EnsureEpoch(epoch);
            if (item.Provenance is null || item.Provenance.SameReader(source.FicheReaderHash)) recent.Put(item.Entry.ObjectGuid, item, item.ReadAt);
        }
    }

    public void ClearVisits() { lock (localGate) { recent.Clear(); seen.Clear(); } }

    internal void Forget(Guid id)
    { lock (localGate) { recent.Remove(id); seen.Remove(id); } }

    private void ResetRecent()
    {
        var revision = (source.Connection as IAdReachability)?.Availability.Revision ?? 0;
        if (recentEpoch != source.Epoch || recentDirectoryRevision != revision)
        { recent.Clear(); seen.Clear(); recentEpoch = source.Epoch; recentDirectoryRevision = revision; }
    }

    public async Task<FicheRead> ReadAsync(string dn, CancellationToken cancellationToken)
    {
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(10), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var epoch = await NetworkEpochAsync(dn, budget.Token).ConfigureAwait(false);
        var read = await objects.ReadAsync(dn, budget.Token).ConfigureAwait(false);
        await RememberAsync(read, epoch, cancellationToken).ConfigureAwait(false);
        return read;
    }

    public async Task<FicheEntry?> ReadByGuidAsync(Guid objectGuid, CancellationToken cancellationToken)
    {
        var filter = AdObjectAccess.GuidFilter(objectGuid);
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(15), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
        var epoch = source.Epoch;
        var rows = await source.Connection.SearchAsync(new(domain.RootDn, filter, AdSearchScope.Subtree, ["objectGUID"])
        { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(5), Budget = TimeSpan.FromSeconds(5) }, budget.Token).ConfigureAwait(false);
        EnsureEpoch(epoch);
        if (rows.Count == 0) { return null; }
        if (rows.Count != 1 || rows[0].Guid("objectGUID") != objectGuid) { throw AdAttributeRange.Incomplete(); }
        var read = await objects.ReadAsync(rows[0].DistinguishedName, budget.Token).ConfigureAwait(false);
        if (read.Entry.ObjectGuid != objectGuid) { throw AdAttributeRange.Incomplete(); }
        await RememberAsync(read, epoch, budget.Token).ConfigureAwait(false);
        EnsureEpoch(epoch);
        return read.Entry;
    }

    private async Task<DirectoryState?> LocalAsync(CancellationToken token)
    {
        try { return await source.ReadLocalAsync(token).ConfigureAwait(false); }
        catch (DomeniaOperationException ex) when (ex.Code == AdErrors.NotConnected) { return null; }
    }

    public async Task<FicheLocalRead?> PreviewAsync(string dn, CancellationToken cancellationToken)
    {
        AdFicheObjects.ValidateDn(dn);
        var epoch = source.Epoch;
        var local = await LocalAsync(cancellationToken).ConfigureAwait(false);
        if (local is not null) { AdFicheObjects.EnsureDomain(dn, local.Directory.Domain.RootDn); }
        FicheLocalRead? memory;
        lock (localGate) { ResetRecent(); memory = recent.Find(v => FicheValues.SameDn(v.Entry.Dn, dn) && (v.Provenance is null || v.Provenance.SameReader(source.FicheReaderHash))); }
        var stored = source.LocalStore is IFicheCache cache ? await cache.ReadFicheAsync(dn, cancellationToken).ConfigureAwait(false) : null;
        if (stored?.Provenance is { } provenance && !provenance.SameReader(source.FicheReaderHash)) stored = null;
        var typedAllowed = local?.Directory.ReaderLogin is not { } owner || FicheCacheProvenance.ReaderKey(owner) == source.FicheReaderHash;
        var typed = local is null || !typedAllowed ? null : AdFicheProjection.All(local.Directory).FirstOrDefault(v => FicheValues.SameDn(v.Entry.Dn, dn));
        EnsureEpoch(epoch);
        var candidates = new[] { memory, stored, typed }.Where(v => v is not null).ToArray();
        if (candidates.Select(v => v!.Entry.ObjectGuid).Distinct().Take(2).Count() > 1)
            throw FicheErrors.Error(FicheErrors.Ambiguous, "Plusieurs identités locales pour ce nom : relisez l’annuaire.");
        var best = candidates.MaxBy(v => v!.ReadAt);
        if (best is null) { return null; }
        var latest = (await LocalIndexAsync(cancellationToken).ConfigureAwait(false)).FirstOrDefault(v => v.ObjectGuid == best.Entry.ObjectGuid);
        EnsureEpoch(epoch);
        return latest is not null && latest.ObservedAt >= best.ReadAt && !FicheValues.SameDn(latest.Dn, dn) ? null : best;
    }

    private async Task<ImmutableArray<FicheSummary>> LocalIndexAsync(CancellationToken token)
    {
        var epoch = source.Epoch;
        var local = await LocalAsync(token).ConfigureAwait(false);
        // A cached session census may predate a deletion, a rename or another process's commit.
        // Durable stores, when present, are authoritative; visit caches cannot resurrect a removed identity.
        var directory = source.LocalStore is IObjectDirectoryCache objects ? await objects.ReadKnownAsync(token).ConfigureAwait(false)
            : source.LocalStore is { } store ? await store.ReadAsync(token).ConfigureAwait(false) : local?.Directory;
        var typedAllowed = directory?.ReaderLogin is not { } owner || FicheCacheProvenance.ReaderKey(owner) == source.FicheReaderHash;
        var items = directory is null || !typedAllowed ? new Dictionary<Guid, FicheSummary>() : AdFicheProjection.All(directory).ToDictionary(v => v.Entry.ObjectGuid, v => FicheSummary.From(v.Entry, v.ReadAt));
        void Add(FicheSummary item)
        { if (item.ReaderHash is { } reader && reader != source.FicheReaderHash) return;
          if (!items.TryGetValue(item.ObjectGuid, out var old) || old.ObservedAt is null || item.ObservedAt >= old.ObservedAt) { items[item.ObjectGuid] = item; } }
        // Raw fiches supplement the typed census, including contacts and containers not present in old projections.
        if (source.LocalStore is IFicheCache cache)
        {
            foreach (var item in await cache.ReadFicheIndexAsync(token).ConfigureAwait(false)) { Add(item); }
        }
        lock (localGate)
        {
            ResetRecent();
            if (source.LocalStore is not IFicheCache)
            {
                foreach (var item in recent.Snapshot()) { Add(FicheSummary.From(item.Entry, item.ReadAt, item.Provenance?.ReaderHash)); }
                foreach (var item in seen.Snapshot()) { Add(item); }
            }
        }
        EnsureEpoch(epoch);
        return [.. items.Values];
    }

    public async Task<IReadOnlyDictionary<string, FicheSummary>> IndexAsync(IReadOnlyCollection<string> dns, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dns);
        if (dns.Count > 2000) { throw FicheErrors.Error(FicheErrors.Invalid, "Index limité à 2 000 objets."); }
        foreach (var dn in dns) { AdFicheObjects.ValidateDn(dn); }
        var index = (await LocalIndexAsync(cancellationToken).ConfigureAwait(false)).GroupBy(e => DnKey(e.Dn)).ToDictionary(g => g.Key, g => g.OrderByDescending(e => e.ObservedAt).ToArray());
        var result = new Dictionary<string, FicheSummary>(StringComparer.OrdinalIgnoreCase);
        foreach (var dn in dns.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (index.TryGetValue(DnKey(dn), out var matches) && matches.Length == 1) { result.Add(dn, matches[0]); }
        }
        return result;
    }

    public async Task<FicheSummary?> LocalByIdAsync(string id, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(id);
        var index = await LocalIndexAsync(cancellationToken).ConfigureAwait(false);
        var matches = Guid.TryParse(id.Trim(), out var guid) ? index.Where(e => e.ObjectGuid == guid)
            : index.Where(e => e.Sid is not null && e.Sid.Equals(id.Trim(), StringComparison.OrdinalIgnoreCase));
        var found = matches.Take(2).ToArray();
        return found.Length == 1 ? found[0] : null;
    }

    public async Task<ImmutableArray<FicheSummary>> SearchLocalAsync(string text, IReadOnlyCollection<FicheKind> kinds, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(text); ArgumentNullException.ThrowIfNull(kinds);
        if (limit is < 1 or > 200 || kinds.Any(k => !Enum.IsDefined(k))) { throw FicheErrors.Error(FicheErrors.Invalid, "Recherche locale limitée à 200 objets."); }
        var wanted = FrenchText.Fold(text.Trim());
        if (wanted.Length == 0) { return []; }
        return [.. (await LocalIndexAsync(cancellationToken).ConfigureAwait(false)).Where(e => kinds.Count == 0 || kinds.Contains(e.Kind))
            .Select(e => (Entry: e, Values: new[] { e.Name, e.Sam, e.Upn, e.Mail, e.Detail, e.Dn }.Where(v => v is not null).Select(v => FrenchText.Fold(v!)).ToArray()))
            .Where(e => e.Values.Any(v => v.Contains(wanted, StringComparison.Ordinal)))
            .OrderBy(e => e.Values.Contains(wanted) ? 0 : e.Values.Any(v => v.StartsWith(wanted, StringComparison.Ordinal)) ? 1 : 2)
            .ThenBy(e => FrenchText.Fold(e.Entry.Name), StringComparer.Ordinal).Take(limit).Select(e => e.Entry)];
    }

    public async Task<int?> LocalChildCountAsync(string dn, CancellationToken cancellationToken)
    {
        AdFicheObjects.ValidateDn(dn);
        var local = await LocalAsync(cancellationToken).ConfigureAwait(false);
        var scope = new ScopeSelection(dn, "", false);
        return local?.Directory.CoversScope(scope) == true ? AdFicheProjection.All(local.Directory).Count(v => ScopeRules.Contains(scope, v.Entry.Dn)) : null;
    }

    private static string DnKey(string dn) => DistinguishedName.Format(DistinguishedName.Parse(dn)).ToUpperInvariant();

    private void RememberSummaries(IEnumerable<AdEntry> entries, long epoch)
    {
        var summaries = new List<FicheSummary>();
        foreach (var entry in entries)
        {
            try { summaries.Add(FicheSummary.From(AdFicheObjects.Project(entry), source.Clock.GetUtcNow(), source.FicheReaderHash)); }
            catch (DomeniaOperationException ex) when (ex.Code == FicheErrors.NotApplicable) { /* Unsupported children remain listed by DN. */ }
        }
        EnsureEpoch(epoch);
        lock (localGate)
        {
            ResetRecent();
            EnsureEpoch(epoch);
            foreach (var item in summaries) { seen.Put(item.ObjectGuid, item, item.ObservedAt ?? source.Clock.GetUtcNow()); }
        }
    }

    // The account guard belongs to EngineContext; the bridge adds its actual local refusals to this source's readings.
    public Task<ImmutableArray<FicheDomeniaRefusal>> RefusalsAsync(string dn, DateTimeOffset since, CancellationToken cancellationToken)
    { AdFicheObjects.ValidateDn(dn); cancellationToken.ThrowIfCancellationRequested(); return Task.FromResult(ImmutableArray<FicheDomeniaRefusal>.Empty); }

    public async Task<FicheRelationsRead> RelationsAsync(string dn, CancellationToken cancellationToken)
    {
        var entry = (await PreviewAsync(dn, cancellationToken).ConfigureAwait(false))?.Entry;
        if (entry is null) { return new(null, [], null, [], []); }
        var local = await LocalAsync(cancellationToken).ConfigureAwait(false);
        var entries = local is null ? [] : AdFicheProjection.All(local.Directory).Select(e => e.Entry).ToArray();
        return new(entry.First("manager"), [.. entry.All("directReports").Concat(entries.Where(e => FicheValues.SameDn(e.First("manager"), dn)).Select(e => e.Dn)).Distinct(StringComparer.OrdinalIgnoreCase)],
            entry.First("managedBy"), [.. entries.Where(e => FicheValues.SameDn(e.First("managedBy"), dn)).Select(e => e.Dn)], []);
    }
}
