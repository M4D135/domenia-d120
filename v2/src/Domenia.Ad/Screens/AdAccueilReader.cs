using System.Collections.Concurrent;
using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Inventory;

namespace Domenia.Ad;

/// <summary>Local fleet views and explicit bounded LDAP/CIM measurements for the home page.</summary>
public sealed class AdAccueilReader : IAccueilReader
{
    private readonly AdDirectorySource source;
    private readonly WmiFleetProbeReader probes;
    internal Func<DirectoryComputer, ImmutableArray<string>, CancellationToken, Task<ImmutableDictionary<string, ProbeReading>>>? ProbeOverride { get; init; }

    public AdAccueilReader(AdDirectorySource source)
    {
        this.source = source;
        probes = new(source.Clock);
    }

    public async Task<AccueilFacts> FactsAsync(CancellationToken cancellationToken)
    {
        await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        return source.FleetDetails.Facts;
    }

    public async Task<ProbeReadings> StoredProbesAsync(CancellationToken cancellationToken)
    {
        await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        return source.FleetDetails.Probes;
    }

    public Task<ImmutableArray<FleetSnapshot>> HistoryAsync(ScopeSelection scope, CancellationToken cancellationToken) =>
        source.LocalStore is IAccueilCache cache ? cache.ReadFleetHistoryAsync(scope, cancellationToken) : Task.FromResult(ImmutableArray<FleetSnapshot>.Empty);

    public Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlySet<Guid> targets, CancellationToken cancellationToken) =>
        source.ReadInventoryAsync(scope, targets, cancellationToken);

    public async Task<ProbeReadings> CollectProbesAsync(ImmutableArray<string> probeIds, ScopeSelection scope, IReadOnlyCollection<Guid> online, CancellationToken cancellationToken)
    {
        if (probeIds.IsDefault || probeIds.Length > 128 || probeIds.Any(id => ProbeCatalog.Find(id) is null))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Liste de sondes invalide : aucun poste contacté."); }
        var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        AdDirectoryReader.EnsureScope(scope, local.Directory.Domain.RootDn);
        var generation = source.Epoch;
        var wanted = online.ToHashSet();
        var answered = local.Observations.Workstations.Where(o => o.Presence.HasReading && o.Presence.Answered == true).Select(o => o.ComputerGuid).ToHashSet();
        var computers = local.Directory.Computers.Where(c => wanted.Contains(c.ObjectGuid) && answered.Contains(c.ObjectGuid)
            && ScopeRules.Contains(scope, c.DistinguishedName) && !AdValues.IsDisabled(c.UserAccountControl)).ToArray();
        var completed = new ConcurrentDictionary<Guid, ImmutableDictionary<string, ProbeReading>>();
        using var limit = new SemaphoreSlim(6);
        var tasks = computers.Select(async computer =>
        {
            await limit.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                if (source.Epoch != generation) { throw new OperationCanceledException("La session a changé.", cancellationToken); }
                if (probeIds.IsEmpty || (computer.UserAccountControl & 8192) != 0 && probeIds.All(id => ProbeCatalog.Find(id)!.SkipOnDc))
                {
                    completed[computer.ObjectGuid] = probeIds.Distinct().ToImmutableDictionary(id => id,
                        id => new ProbeReading(MeasureState.NotRead, source.Clock.GetUtcNow(), [], "Sonde exclue sur les contrôleurs de domaine."));
                    return;
                }
                using var access = ProbeOverride is null ? await AdWorkstationAccess.AcquireAsync(source, computer.DnsHostName ?? computer.Name, cancellationToken).ConfigureAwait(false) : null;
                var readings = await (ProbeOverride?.Invoke(computer, probeIds, cancellationToken) ?? probes.ReadAsync(computer, probeIds, cancellationToken, access!.Credential, access.Settings)).ConfigureAwait(false);
                access?.EnsureCurrent();
                if (readings.Values.Any(r => r.State == MeasureState.Refused || r.AuthenticationRejected))
                { access?.Refused(computer.Name, "Sondes du parc", readings.Values.Any(r => r.AuthenticationRejected)); }
                completed[computer.ObjectGuid] = readings;
            }
            catch (DomeniaOperationException ex) when (ex.Code is MachineErrors.AccountPaused or AccountAccess.ContextRefused or "machine.busy")
            { completed[computer.ObjectGuid] = probeIds.Distinct().ToImmutableDictionary(id => id, id => new ProbeReading(MeasureState.NotRead, source.Clock.GetUtcNow(), [], "Lecture non envoyée : " + ex.Code)); }
            finally { limit.Release(); }
        }).ToArray();
        var interrupted = false;
        try { await Task.WhenAll(tasks).ConfigureAwait(false); }
        catch (OperationCanceledException) { interrupted = true; }
        var result = ImmutableDictionary.CreateBuilder<string, ImmutableDictionary<Guid, ProbeReading>>(StringComparer.Ordinal);
        foreach (var id in probeIds.Distinct(StringComparer.Ordinal))
        { result[id] = completed.Where(p => p.Value.ContainsKey(id)).ToImmutableDictionary(p => p.Key, p => p.Value[id]); }
        var measured = new ProbeReadings(result.ToImmutable());
        if (completed.Count > 0) { await source.SaveFleetAsync(FleetCachePatch.Empty with { Probes = measured }, generation, CancellationToken.None).ConfigureAwait(false); }
        if (interrupted) { throw new OperationCanceledException(cancellationToken); }
        return measured;
    }

    public async Task<BitLockerPresence> ReadBitLockerAsync(ScopeSelection scope, CancellationToken cancellationToken)
    {
        var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        AdDirectoryReader.EnsureScope(scope, local.Directory.Domain.RootDn);
        var computers = local.Directory.Computers.Where(c => ScopeRules.Contains(scope, c.DistinguishedName)).ToArray();
        if (computers.Length == 0) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Relisez d’abord l’annuaire de cette OU pour identifier ses postes."); }
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(180), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        await source.DomainAsync(budget.Token).ConfigureAwait(false);
        var generation = source.Epoch;
        var root = await source.Connection.RootDseAsync(budget.Token).ConfigureAwait(false);
        if (!AdSchemaReader.ValidContext(root.SchemaNamingContext) || !DistinguishedName.AreEqual(root.DefaultNamingContext, local.Directory.Domain.RootDn))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Contexte de schéma ou de domaine incohérent : lecture BitLocker refusée."); }
        var schema = await source.Connection.SearchAsync(new(root.SchemaNamingContext, "(&(objectClass=classSchema)(lDAPDisplayName=msFVE-RecoveryInformation))", AdSearchScope.OneLevel, ["lDAPDisplayName"]) { SizeLimit = 2 }, budget.Token).ConfigureAwait(false);
        var classPresent = schema.Count == 1 && schema[0].String("lDAPDisplayName") == "msFVE-RecoveryInformation";
        if (schema.Count > 0 && !classPresent) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Définition BitLocker incohérente dans le schéma."); }
        var byDn = computers.ToDictionary(c => Key(c.DistinguishedName), c => c.ObjectGuid, StringComparer.OrdinalIgnoreCase);
        var facts = ImmutableDictionary.CreateBuilder<Guid, BitLockerFact>();
        var truncated = false;
        var count = 0;
        if (classPresent)
        {
            // A recovery object is a child of a computer, so OneLevel on the OU would miss every key.
            var bases = scope.Subtree ? new[] { scope.Dn } : computers.Select(c => c.DistinguishedName).ToArray();
            try
            {
                foreach (var dn in bases)
                {
                    var rows = await source.Connection.SearchAsync(new(dn, "(objectClass=msFVE-RecoveryInformation)", scope.Subtree ? AdSearchScope.Subtree : AdSearchScope.OneLevel, ["distinguishedName", "whenCreated"])
                    { PageSize = 500, SizeLimit = 100_001 - count, Timeout = TimeSpan.FromSeconds(30) }, budget.Token).ConfigureAwait(false);
                    foreach (var entry in rows)
                    {
                        if (count++ == 100_000) { truncated = true; break; }
                        string? parent;
                        try { parent = DistinguishedName.Parent(entry.DistinguishedName); }
                        catch (FormatException) { truncated = true; continue; }
                        if (parent is null || !ScopeRules.Contains(scope, parent) || !byDn.TryGetValue(Key(parent), out var id)) { truncated = true; continue; }
                        var at = entry.Time("whenCreated");
                        if (at is null || at > source.Clock.GetUtcNow()) { truncated = true; at = null; }
                        var old = facts.GetValueOrDefault(id);
                        facts[id] = new((old?.Keys ?? 0) + 1, old?.Newest is { } previous && (at is null || previous > at) ? previous : at);
                    }
                    if (count >= 100_000 && dn != bases[^1]) { truncated = true; break; }
                    if (truncated && count > 100_000) { break; }
                }
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && elapsed.IsCancellationRequested) { truncated = true; }
            catch (DomeniaOperationException ex) when (ex.Code == AdErrors.Timeout) { truncated = true; }
        }
        cancellationToken.ThrowIfCancellationRequested();
        var result = new BitLockerPresence(scope.Dn, scope.Subtree, source.Clock.GetUtcNow(), classPresent, truncated, facts.ToImmutable());
        await source.SaveFleetAsync(FleetCachePatch.Empty with { BitLocker = [result] }, generation, cancellationToken).ConfigureAwait(false);
        return result;
    }

    private static string Key(string dn) => DistinguishedName.Format(DistinguishedName.Parse(dn));
}
