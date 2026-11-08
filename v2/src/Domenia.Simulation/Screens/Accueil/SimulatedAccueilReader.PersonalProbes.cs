using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;
using ProbeReading = Domenia.Core.Accueil.ProbeReading;

namespace Domenia.Simulation;

public sealed partial class SimulatedAccueilReader
{
    private readonly Lock probeGate = new();
    private long probeEpoch = -1;
    private ProbeReadings recordedProbes = ProbeReadings.Empty;

    public Task<ProbeReadings> StoredProbesAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        lock (probeGate)
        { return Task.FromResult(probeEpoch == source.CurrentSession.Epoch ? recordedProbes : ProbeReadings.Empty); }
    }

    private void RememberProbes(ProbeReadings readings, long epoch)
    {
        lock (probeGate)
        {
            if (source.CurrentSession.Epoch != epoch)
            { throw new DomeniaOperationException("refresh.scopeChanged", "Session simulée modifiée ; valeurs de sondes écartées."); }
            if (probeEpoch != epoch) { recordedProbes = ProbeReadings.Empty; probeEpoch = epoch; }
            recordedProbes = recordedProbes.Merge(readings);
        }
    }

    public async Task<ProbeReadings> CollectFrozenProbesAsync(ImmutableArray<FrozenProbe> probes, ScopeSelection scope,
        IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, CancellationToken token)
    {
        PersonalProbeCatalog.Validate(probes);
        var frozen = targets.ToImmutableDictionary();
        void Confirm()
        {
            token.ThrowIfCancellationRequested();
            var actual = source.CurrentDirectory.Computers.ToDictionary(c => c.ObjectGuid);
            if (source.CurrentSession.Epoch != expectedEpoch || frozen.Any(p => !actual.TryGetValue(p.Key, out var computer)
                || !p.Value.Matches(computer) || !ScopeRules.Contains(scope, computer.DistinguishedName)))
            { throw new DomeniaOperationException("refresh.scopeChanged", "Identité ou session simulée différente du plan ; sondes refusées."); }
        }
        Confirm();
        var builtins = probes.Where(p => !PersonalProbeCatalog.IsKey(p.Key)).Select(p => p.Key).ToImmutableArray();
        var result = builtins.IsEmpty ? ProbeReadings.Empty
            : await CollectProbesAsync(builtins, scope, frozen.Keys.ToArray(), token).ConfigureAwait(false);
        var custom = probes.Where(p => PersonalProbeCatalog.IsKey(p.Key)).ToArray();
        if (custom.Length > 0)
        { await source.SimulateScreenLatencyAsync("accueil/personalProbes", 400, 1100, token).ConfigureAwait(false); }
        Confirm();
        var at = source.Clock.GetUtcNow();
        var perProbe = ImmutableDictionary.CreateBuilder<string, ImmutableDictionary<Guid, ProbeReading>>(StringComparer.Ordinal);
        foreach (var probe in custom)
        {
            var rows = ImmutableDictionary.CreateBuilder<Guid, ProbeReading>();
            foreach (var (id, identity) in frozen)
            {
                token.ThrowIfCancellationRequested();
                rows[id] = (identity.UserAccountControl & AdValues.ServerTrustAccount) != 0
                    ? new(MeasureState.NotRead, at, [], "Sonde personnelle exclue sur les contrôleurs de domaine simulés.")
                    : SimulatePersonalProbe(probe.Definition, id, at);
            }
            perProbe[probe.Key] = rows.ToImmutable();
        }
        Confirm();
        result = result.Merge(new(perProbe.ToImmutable()));
        RememberProbes(result, expectedEpoch);
        return result;
    }

    private ProbeReading SimulatePersonalProbe(ProbeDefinition definition, Guid computer, DateTimeOffset at)
    {
        var catalog = SimulatedWmiCatalog.Find(definition.Namespace, definition.Class);
        var filter = ProbeCatalog.ResolveFilter(definition.Filter, at);
        var select = WqlRules.Parse("SELECT " + string.Join(", ", definition.Properties) + " FROM " + definition.Class
            + (filter.Length == 0 ? "" : " WHERE " + filter));
        if (catalog is null || select.ReferencedProperties.Any(p => !catalog.Properties.Any(f => f.Name.Equals(p, StringComparison.OrdinalIgnoreCase))))
        { return new(MeasureState.NotRead, at, [], "Cette propriété n’est pas représentée dans le monde simulé ; aucune valeur inventée."); }
        var instances = SimulatedWmiCatalog.Instances(source, computer, catalog).Where(row => WqlRules.Matches(select.Where, ForFilter(row))).Take(2001).ToArray();
        if (instances.Length > 2000)
        { return new(MeasureState.Incomplete, at, [], "Plafond de 2 000 instances atteint en simulation."); }
        if (definition.Mode == "Count") { return new(MeasureState.Known, at, [instances.Length.ToString(CultureInfo.InvariantCulture)], null); }
        var values = ImmutableArray.CreateBuilder<string>();
        foreach (var instance in instances)
        {
            var cells = definition.Properties.Select(p => instance.FirstOrDefault(v => p.Equals(v.Key, StringComparison.OrdinalIgnoreCase)).Value).ToArray();
            if (cells.All(v => !string.IsNullOrWhiteSpace(v))) { values.Add(string.Join('|', cells)); }
            if (definition.Mode == "First" && values.Count > 0) { break; }
        }
        return new(MeasureState.Known, at, values.ToImmutable(), null);

        IReadOnlyDictionary<string, string?> ForFilter(IReadOnlyDictionary<string, string?> row)
        {
            var result = new Dictionary<string, string?>(row, StringComparer.OrdinalIgnoreCase);
            foreach (var property in catalog.Properties.Where(p => p.CimType.Equals("datetime", StringComparison.OrdinalIgnoreCase)))
                if (result.TryGetValue(property.Name, out var value) && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var time))
                { result[property.Name] = time.UtcDateTime.ToString("yyyyMMddHHmmss.ffffff'+000'", CultureInfo.InvariantCulture); }
            return result;
        }
    }
}
