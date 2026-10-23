using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Real fiche reads. Local entry points never connect; network reads are bounded and tied to the session generation.</summary>
public sealed partial class AdFicheReader(AdDirectorySource source) : IFicheReader
{
    private readonly AdFicheObjects objects = new(source);
    private readonly Lock localGate = new();
    private readonly Dictionary<Guid, FicheLocalRead> recent = [];
    private readonly Dictionary<Guid, FicheSummary> seen = [];
    private long recentEpoch = -1;

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
        var item = new FicheLocalRead(read.Entry, read.ReadAt);
        if (source.LocalStore is IFicheCache cache) { item = await cache.SaveFicheAsync(item, token).ConfigureAwait(false); }
        EnsureEpoch(epoch);
        lock (localGate)
        {
            ResetRecent();
            EnsureEpoch(epoch);
            if (!recent.TryGetValue(item.Entry.ObjectGuid, out var old) || old.ReadAt <= item.ReadAt) { recent[item.Entry.ObjectGuid] = item; }
            while (recent.Count > 256) { recent.Remove(recent.MinBy(p => p.Value.ReadAt).Key); }
        }
    }

    private void ResetRecent()
    {
        if (recentEpoch != source.Epoch) { recent.Clear(); seen.Clear(); recentEpoch = source.Epoch; }
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
        lock (localGate) { ResetRecent(); memory = recent.Values.Where(v => FicheValues.SameDn(v.Entry.Dn, dn)).MaxBy(v => v.ReadAt); }
        var stored = source.LocalStore is IFicheCache cache ? await cache.ReadFicheAsync(dn, cancellationToken).ConfigureAwait(false) : null;
        var typed = local is null ? null : AdFicheProjection.All(local.Directory).FirstOrDefault(v => FicheValues.SameDn(v.Entry.Dn, dn));
        EnsureEpoch(epoch);
        var best = new[] { memory, stored, typed }.Where(v => v is not null).MaxBy(v => v!.ReadAt);
        if (best is null) { return null; }
        var latest = (await LocalIndexAsync(cancellationToken).ConfigureAwait(false)).FirstOrDefault(v => v.ObjectGuid == best.Entry.ObjectGuid);
        EnsureEpoch(epoch);
        return latest is not null && latest.ObservedAt >= best.ReadAt && !FicheValues.SameDn(latest.Dn, dn) ? null : best;
    }

    private async Task<ImmutableArray<FicheSummary>> LocalIndexAsync(CancellationToken token)
    {
        var epoch = source.Epoch;
        var local = await LocalAsync(token).ConfigureAwait(false);
        var items = local is null ? new Dictionary<Guid, FicheSummary>() : AdFicheProjection.All(local.Directory).ToDictionary(v => v.Entry.ObjectGuid, v => FicheSummary.From(v.Entry, v.ReadAt));
        void Add(FicheSummary item)
        { if (!items.TryGetValue(item.ObjectGuid, out var old) || old.ObservedAt is null || item.ObservedAt >= old.ObservedAt) { items[item.ObjectGuid] = item; } }
        // Raw fiches supplement the typed census, including contacts and containers not present in old projections.
        if (source.LocalStore is IFicheCache cache)
        {
            foreach (var item in await cache.ReadFicheIndexAsync(token).ConfigureAwait(false)) { Add(item); }
        }
        lock (localGate)
        {
            ResetRecent();
            foreach (var item in recent.Values) { Add(FicheSummary.From(item.Entry, item.ReadAt)); }
            foreach (var item in seen.Values) { Add(item); }
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
            if (index.TryGetValue(DnKey(dn), out var matches) && (matches.Length == 1 || matches[0].ObservedAt > matches[1].ObservedAt)) { result.Add(dn, matches[0]); }
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
            try { summaries.Add(FicheSummary.From(AdFicheObjects.Project(entry), source.Clock.GetUtcNow())); }
            catch (DomeniaOperationException ex) when (ex.Code == FicheErrors.NotApplicable) { /* Unsupported children remain listed by DN. */ }
        }
        EnsureEpoch(epoch);
        lock (localGate)
        {
            ResetRecent();
            EnsureEpoch(epoch);
            foreach (var item in summaries) { seen[item.ObjectGuid] = item; }
            while (seen.Count > 5000) { seen.Remove(seen.MinBy(p => p.Value.ObservedAt).Key); }
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
