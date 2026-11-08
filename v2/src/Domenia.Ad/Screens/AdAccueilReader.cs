using System.Collections.Concurrent;
using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using QueryComputerIdentity = Domenia.Core.Queries.QueryComputerIdentity;
using Domenia.Inventory;

namespace Domenia.Ad;

/// <summary>Local fleet views and explicit bounded LDAP/CIM measurements for the home page.</summary>
public sealed class AdAccueilReader : IAccueilReader, IAccueilProbeRetryReader
{
    private readonly AdDirectorySource source;
    private readonly WmiFleetProbeReader probes;
    private readonly ProbeFailureCache failures;
    internal Func<DirectoryComputer, ImmutableArray<string>, CancellationToken, Task<ImmutableDictionary<string, ProbeReading>>>? ProbeOverride { get; init; }

    public AdAccueilReader(AdDirectorySource source)
    {
        this.source = source;
        probes = new(source.Clock) { ProjectionReused = () => { if (source.AccountContext is { } context) { OperationActivity.From(context).RecordGroupedCimReuse(); } } };
        failures = new(source.Clock);
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

    public Task<DirectoryState> ReadPresenceAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, CancellationToken token) =>
        source.ReadPresenceAsync(scope, targets, expectedEpoch, token);

    public Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, CancellationToken token) =>
        source.ReadInventoryAsync(scope, targets, expectedEpoch, token);

    public Task<ProbeReadings> CollectProbesAsync(ImmutableArray<string> probeIds, ScopeSelection scope, IReadOnlyCollection<Guid> online, CancellationToken cancellationToken) =>
        CollectProbesCoreAsync(PersonalProbeCatalog.Builtins(probeIds), scope, online, null, null, cancellationToken);

    public Task<ProbeReadings> CollectProbesAsync(ImmutableArray<string> probeIds, ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets,
        long expectedEpoch, CancellationToken cancellationToken)
    {
        var frozen = targets.ToImmutableDictionary();
        return CollectProbesCoreAsync(PersonalProbeCatalog.Builtins(probeIds), scope, frozen.Keys.ToArray(), frozen, expectedEpoch, cancellationToken);
    }

    public Task<ProbeReadings> CollectFrozenProbesAsync(ImmutableArray<FrozenProbe> definitions, ScopeSelection scope,
        IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, CancellationToken cancellationToken)
    {
        var frozen = targets.ToImmutableDictionary();
        return CollectProbesCoreAsync(definitions, scope, frozen.Keys.ToArray(), frozen, expectedEpoch, cancellationToken);
    }

    public Task<ProbeReadings> RetryFrozenProbesAsync(ImmutableArray<FrozenProbe> definitions, ScopeSelection scope,
        IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, CancellationToken token)
    {
        var frozen = targets.ToImmutableDictionary();
        return CollectProbesCoreAsync(definitions, scope, frozen.Keys.ToArray(), frozen, expectedEpoch, token, retryFailures: true);
    }

    private async Task<ProbeReadings> CollectProbesCoreAsync(ImmutableArray<FrozenProbe> definitions, ScopeSelection scope, IReadOnlyCollection<Guid> online,
        IReadOnlyDictionary<Guid, QueryComputerIdentity>? expected, long? expectedEpoch, CancellationToken cancellationToken, bool retryFailures = false)
    {
        PersonalProbeCatalog.Validate(definitions);
        using var stopWork = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cancellationToken = stopWork.Token;
        var probeIds = definitions.Select(p => p.Key).ToImmutableArray();
        var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        AdDirectoryReader.EnsureScope(scope, local.Directory.Domain.RootDn);
        var generation = source.Epoch;
        var actual = AdComputerIndex.For(local.Directory);
        if (expectedEpoch is not null && generation != expectedEpoch || expected is not null && expected.Any(p =>
            actual.Find(p.Key) is not { } computer || !p.Value.Matches(computer) || !ScopeRules.Contains(scope, computer.DistinguishedName)))
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité ou session différente du plan de sondes ; aucune collecte."); }
        var allowUnanswered = CollectionNetworkPolicy.Read(source.AccountContext?.Preferences);
        var wanted = online.ToHashSet();
        var computers = CampaignBranches.Order(wanted.Select(actual.Find).OfType<DirectoryComputer>().Where(c =>
            local.Observations.Find(c.ObjectGuid) is { } observation && CollectionNetworkPolicy.Eligible(observation.Presence, allowUnanswered)
            && ScopeRules.Contains(scope, c.DistinguishedName) && !AdValues.IsDisabled(c.UserAccountControl))).ToArray();
        var definitionKeys = definitions.ToDictionary(d => d.Key, d => BoundedCacheKey.Create(d), StringComparer.Ordinal);
        var completed = new ConcurrentDictionary<Guid, ImmutableDictionary<string, ProbeReading>>();
        var pending = new ConcurrentQueue<Guid>();
        using var saving = new SemaphoreSlim(1, 1);
        var lastSave = source.Clock.GetTimestamp();
        System.Runtime.ExceptionServices.ExceptionDispatchInfo? writeFailure = null;
        async Task FlushAsync(bool final = false)
        {
            if (pending.IsEmpty) { return; }
            await saving.WaitAsync(CancellationToken.None).ConfigureAwait(false);
            try
            {
                writeFailure?.Throw();
                if (!final && pending.Count < 32 && source.Clock.GetElapsedTime(lastSave) < TimeSpan.FromSeconds(5)) { return; }
                // At most eight bounded remittances in one turn; the next turn cannot overtake an acknowledgement.
                for (var part = 0; part < 8 && !pending.IsEmpty; part++)
                {
                    var ids = new HashSet<Guid>();
                    while (ids.Count < 32 && pending.TryDequeue(out var id)) { ids.Add(id); }
                    if (ids.Count == 0) break;
                    var batch = new ProbeReadings(probeIds.Distinct(StringComparer.Ordinal).ToImmutableDictionary(id => id,
                        id => ids.Where(guid => completed[guid].ContainsKey(id)).ToImmutableDictionary(guid => guid, guid => completed[guid][id]), StringComparer.Ordinal));
                    try
                    {
                        await source.SaveFleetAsync(FleetCachePatch.Empty with { Probes = batch }, generation, CancellationToken.None).ConfigureAwait(false);
                        lastSave = source.Clock.GetTimestamp();
                    }
                    catch (Exception ex)
                    {
                        writeFailure = System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(ex);
                        await stopWork.CancelAsync().ConfigureAwait(false);
                        throw;
                    }
                }
            }
            finally { saving.Release(); }
        }
        var parallel = Math.Min(6, CollectionSettingsRules.Read(source.AccountContext?.Preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var collectionSettings) == true
            ? collectionSettings : null, []).Budgets.GetValueOrDefault(CollectionSettingsRules.Concurrency, 4));
        var work = Parallel.ForEachAsync(computers, new ParallelOptions
        { MaxDegreeOfParallelism = parallel, CancellationToken = cancellationToken }, async (computer, workerToken) =>
        {
            try
            {
                if (source.Epoch != generation) { throw new OperationCanceledException("La session a changé.", cancellationToken); }
                if (probeIds.IsEmpty || (computer.UserAccountControl & 8192) != 0 && definitions.All(p => p.Definition.SkipOnDc))
                {
                    completed[computer.ObjectGuid] = probeIds.Distinct().ToImmutableDictionary(id => id,
                        id => new ProbeReading(MeasureState.NotRead, source.Clock.GetUtcNow(), [], "Sonde exclue sur les contrôleurs de domaine."));
                    return;
                }
                var identity = QueryComputerIdentity.Of(computer);
                var accountVersion = source.AccountContext is { } accounts ? AccountAccess.From(accounts).SelectionVersion : 0;
                var machineVersion = source.AccountContext is { } machines ? MachineAccountService.From(machines).Generation : 0;
                var hostKey = BoundedCacheKey.Create(new { generation, accountVersion, machineVersion, domain = local.Directory.Domain.RootDn, identity });
                var keys = definitions.ToDictionary(d => d.Key, d => hostKey is null || definitionKeys[d.Key] is null ? null : hostKey + ":" + definitionKeys[d.Key]);
                var held = definitions.Select(d => (d.Key, Reading: retryFailures ? null : failures.Read(keys[d.Key]))).Where(p => p.Reading is not null)
                    .ToImmutableDictionary(p => p.Key, p => p.Reading!, StringComparer.Ordinal);
                var activeDefinitions = definitions.Where(d => !held.ContainsKey(d.Key)).ToImmutableArray();
                if (activeDefinitions.IsEmpty)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (source.Epoch != generation || source.AccountContext is { } current
                        && (AccountAccess.From(current).SelectionVersion != accountVersion || MachineAccountService.From(current).Generation != machineVersion))
                        throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Compte modifié pendant la lecture des tentatives conservées.");
                    completed[computer.ObjectGuid] = held;
                    return;
                }
                using var access = ProbeOverride is null ? await AdQueryAccess.OpenAsync(source, computer.ObjectGuid, cancellationToken).ConfigureAwait(false) : null;
                if (source.Epoch != generation) { throw new OperationCanceledException("La session a changé.", cancellationToken); }
                if (access is not null && !QueryComputerIdentity.Of(computer).Matches(access.Computer))
                { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité du poste modifiée avant les sondes ; aucune collecte."); }
                var readings = await (ProbeOverride?.Invoke(computer, activeDefinitions.Select(d => d.Key).ToImmutableArray(), cancellationToken) ?? probes.ReadFrozenAsync(computer, activeDefinitions, cancellationToken,
                    access!.Machine.Credential, access.Machine.Settings, retainPartialOnCancellation: true)).ConfigureAwait(false);
                access?.EnsureCurrent();
                if (readings.Values.Any(r => r.State == MeasureState.Refused || r.AuthenticationRejected))
                { access?.Machine.Refused(computer.Name, "Sondes du parc", readings.Values.Any(r => r.AuthenticationRejected)); }
                readings = held.SetItems(readings);
                try
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (access is not null) { await access.ConfirmDirectoryAsync(cancellationToken).ConfigureAwait(false); }
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    access?.EnsureCurrent();
                    if (source.Epoch != generation || source.CurrentDirectory is not { } latest
                        || !latest.Computers.Any(c => c.ObjectGuid == computer.ObjectGuid && QueryComputerIdentity.Of(computer).Matches(c)))
                        throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Identité ou session modifiée pendant l’arrêt ; sondes écartées.");
                    // Keep physically completed values without launching LDAP after stop. Unqualified values
                    // remain incomplete and cannot satisfy the next campaign's missing-data calculation.
                    completed[computer.ObjectGuid] = readings.ToImmutableDictionary(p => p.Key, p => p.Value with
                    {
                        State = p.Value.State == MeasureState.Known ? MeasureState.Incomplete : p.Value.State,
                        Error = "Lecture arrêtée ; qualification AD finale non terminée." + (p.Value.Error is null ? "" : " " + p.Value.Error),
                    }, StringComparer.Ordinal);
                    throw;
                }
                if (source.Epoch != generation) { throw new OperationCanceledException("La session a changé.", cancellationToken); }
                if (source.AccountContext is { } currentAccounts && (AccountAccess.From(currentAccounts).SelectionVersion != accountVersion
                    || MachineAccountService.From(currentAccounts).Generation != machineVersion))
                    throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Compte modifié pendant les sondes ; résultats écartés.");
                var qualified = readings.ToImmutableDictionary(p => p.Key, p => p.Value with { Identity = identity }, StringComparer.Ordinal);
                foreach (var definition in activeDefinitions)
                    if (qualified.TryGetValue(definition.Key, out var attempted)) failures.Remember(keys[definition.Key], attempted);
                completed[computer.ObjectGuid] = qualified;
            }
            catch (DomeniaOperationException ex) when (ex.Code is MachineErrors.AccountPaused or AccountAccess.ContextRefused or "machine.busy" or "operation.siteBusy" or "operation.physicalBusy")
            { completed[computer.ObjectGuid] = probeIds.Distinct().ToImmutableDictionary(id => id, id => new ProbeReading(MeasureState.NotRead, source.Clock.GetUtcNow(), [], "Lecture non envoyée : " + ex.Code)); }
            finally
            {
                if (completed.ContainsKey(computer.ObjectGuid)) { pending.Enqueue(computer.ObjectGuid); await FlushAsync().ConfigureAwait(false); }
            }
        });
        var interrupted = false;
        System.Runtime.ExceptionServices.ExceptionDispatchInfo? failure = null;
        try { await work.ConfigureAwait(false); }
        catch (OperationCanceledException) { interrupted = true; }
        catch (Exception ex) { failure = System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(ex); }
        interrupted |= cancellationToken.IsCancellationRequested;
        var result = ImmutableDictionary.CreateBuilder<string, ImmutableDictionary<Guid, ProbeReading>>(StringComparer.Ordinal);
        foreach (var id in probeIds.Distinct(StringComparer.Ordinal))
        { result[id] = completed.Where(p => p.Value.ContainsKey(id)).ToImmutableDictionary(p => p.Key, p => p.Value[id]); }
        var measured = new ProbeReadings(result.ToImmutable());
        if (writeFailure is null) { while (!pending.IsEmpty) await FlushAsync(final: true).ConfigureAwait(false); }
        else { failure = writeFailure; }
        failure?.Throw();
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
        var observedAt = source.Clock.GetUtcNow();
        // Only a complete read proves zero keys for a known target. Missing targets in a partial pass remain unknown.
        if (classPresent && !truncated)
            foreach (var computer in computers) facts.TryAdd(computer.ObjectGuid, new(0, null));
        var result = new BitLockerPresence(scope.Dn, scope.Subtree, observedAt, classPresent, truncated,
            facts.ToImmutableDictionary(p => p.Key, p => p.Value with { ObservedAt = observedAt }));
        var committed = await source.SaveFleetAsync(FleetCachePatch.Empty with { BitLocker = [result] }, generation, cancellationToken).ConfigureAwait(false);
        return committed.Facts.BitLocker.Single(p => ScopeRules.SameScope(new(p.ScopeDn, "", p.Subtree), scope));
    }

    private static string Key(string dn) => DistinguishedName.Format(DistinguishedName.Parse(dn));
}
