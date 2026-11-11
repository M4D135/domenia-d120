using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using ProbeCatalog = Domenia.Core.Accueil.ProbeCatalog;
using ProbeReading = Domenia.Core.Accueil.ProbeReading;

namespace Domenia.Inventory;

/// <summary>Only immutable catalog projections are sent to WMI; all probes share one workstation budget.</summary>
public sealed class WmiFleetProbeReader(TimeProvider clock)
{
    internal Func<string, TimeSpan, CancellationToken, CimSession>? SessionFactory { get; init; }
    public Action? ProjectionReused { get; init; }

    public Task<ImmutableDictionary<string, ProbeReading>> ReadAsync(DirectoryComputer computer, ImmutableArray<string> probeIds, CancellationToken cancellationToken,
        RemoteProbeCredential? credential = null, PosteConfiguration? configuration = null, bool retainPartialOnCancellation = false) =>
        ReadFrozenAsync(computer, PersonalProbeCatalog.Builtins(probeIds), cancellationToken, credential, configuration, retainPartialOnCancellation);

    public async Task<ImmutableDictionary<string, ProbeReading>> ReadFrozenAsync(DirectoryComputer computer, ImmutableArray<FrozenProbe> probes, CancellationToken cancellationToken,
        RemoteProbeCredential? credential = null, PosteConfiguration? configuration = null, bool retainPartialOnCancellation = false)
    {
        cancellationToken.ThrowIfCancellationRequested();
        PersonalProbeCatalog.Validate(probes);
        var definitions = probes.Select(p => p.RuntimeDefinition).ToArray();
        if (definitions.Length == 0) { return ImmutableDictionary<string, ProbeReading>.Empty; }
        if ((computer.UserAccountControl & AdValues.ServerTrustAccount) != 0 && definitions.All(d => d.SkipOnDc))
        { return definitions.ToImmutableDictionary(d => d.Id, _ => new ProbeReading(MeasureState.NotRead, clock.GetUtcNow(), [], "Sondes exclues sur les contrôleurs de domaine ; aucun contact CIM.")); }
        if (configuration is { UseCim: false })
        { return definitions.ToImmutableDictionary(d => d.Id, _ => new ProbeReading(MeasureState.NotRead, clock.GetUtcNow(), [], "Lecture CIM désactivée par Remote.UseCim ; aucun contact.")); }
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var gate = new object();
        var latest = ImmutableDictionary<string, ProbeReading>.Empty.WithComparers(StringComparer.Ordinal);
        var host = computer.DnsHostName ?? computer.Name;
        var budget = CimBudgets.ProbesFor(definitions.Length);
        NativeReadProgress? progressState = null;
        var reading = await WmiReadWorkers.StartAsync(host, credential, owned =>
        {
            using var advancing = new NativeReadProgress(clock, budget, inventory: false, stop.Token);
            Volatile.Write(ref progressState, advancing);
            using var session = SessionFactory?.Invoke(host, budget, advancing.Token) ?? new CimSession(host, budget, clock, cancellationToken: advancing.Token, credential: owned,
                transport: configuration?.ReadCimTransport ?? InventoryTransport.Dcom);
            session.QueryCompleted = advancing.Completed; session.NativeStarting = advancing.StartingProcess;
            CimReading? identity = null;
            var personal = definitions.Any(d => d.Origin == "Personnalisée");
            if (definitions.Any(d => !d.SkipOnDc || (computer.UserAccountControl & 8192) == 0))
            { identity = session.Read("identity", @"root\cimv2", personal ? "SELECT Name, DNSHostName, Domain, DomainRole FROM Win32_ComputerSystem" : "SELECT Name, DNSHostName, Domain FROM Win32_ComputerSystem", 1, TimeSpan.FromSeconds(4), allowProjectionReuse: false); }
            var confirmed = identity?.Status == SourceStatus.Ok && WorkstationIdentity.Matches(computer, identity.Instances.FirstOrDefault()?.Text("Name"), identity.HostIdentity);
            var role = identity?.Instances.FirstOrDefault()?.Int("DomainRole");
            var filterAt = clock.GetUtcNow();
            string Query(ProbeDefinition d)
            {
                var filter = ProbeCatalog.ResolveFilter(d.Filter, filterAt);
                return "SELECT " + string.Join(", ", d.Properties) + " FROM " + d.Class + (string.IsNullOrWhiteSpace(filter) ? "" : " WHERE " + filter);
            }
            session.PlanProjections(definitions.Where(d => confirmed && !(d.SkipOnDc && ((computer.UserAccountControl & AdValues.ServerTrustAccount) != 0 || role is 4 or 5))
                && (d.Origin != "Personnalisée" || role is >= 0 and <= 3)).Select(d => new CimProjection(d.Namespace, Query(d), 2000)), ProjectionReused);
            foreach (var definition in definitions)
            {
                if (advancing.Token.IsCancellationRequested || session.OutOfBudget) { break; }
                ProbeReading result;
                if (definition.SkipOnDc && ((computer.UserAccountControl & 8192) != 0 || role is 4 or 5))
                { result = new(MeasureState.NotRead, clock.GetUtcNow(), [], "Sonde exclue sur les contrôleurs de domaine."); }
                else if (!confirmed)
                { result = new(identity?.Status == SourceStatus.Refused ? MeasureState.Refused : MeasureState.Incomplete, clock.GetUtcNow(), [], "Identité CIM non confirmée ; sondes non associées au poste.") { AuthenticationRejected = identity?.AuthenticationRejected == true }; }
                else if (definition.Origin == "Personnalisée" && role is not (>= 0 and <= 3))
                { result = new(MeasureState.NotRead, clock.GetUtcNow(), [], role is 4 or 5
                    ? "Contrôleur de domaine confirmé par CIM : sonde personnalisée exclue."
                    : "Rôle de la machine non confirmé par CIM : sonde personnalisée non envoyée."); }
                else
                {
                    var measured = session.Read(definition.Id, definition.Namespace, Query(definition), 2000, CimBudgets.ProbeQuery);
                    if (advancing.Token.IsCancellationRequested || session.OutOfBudget)
                    { measured = measured with { Detail = NativeReadProgress.Stopped(advancing, measured.Detail) }; }
                    result = Project(definition, measured, clock.GetUtcNow());
                }
                lock (gate) { latest = latest.SetItem(definition.Id, result with { DefinitionHash = ProbeDefinitionIdentity.Of(definition) }); }
            }
            lock (gate)
            {
                foreach (var definition in definitions.Where(d => !latest.ContainsKey(d.Id)))
                { latest = latest.SetItem(definition.Id, new(MeasureState.NotRead, clock.GetUtcNow(), [], NativeReadProgress.Stopped(advancing, "Arrêt ou budget atteint ; sonde non lue."))); }
                return latest;
            }
        }, cancellationToken).ConfigureAwait(false);
        ImmutableDictionary<string, ProbeReading> Partial() { lock (gate) { return latest; } }
        var completed = await NativeReadCompletion.AwaitAsync(reading, stop, budget + CimBudgets.GiveUpMargin, clock, cancellationToken, Partial).ConfigureAwait(false);
        var result = completed.Value;
        if (completed.Stop != NativeReadStop.None)
        {
            var error = completed.Stop == NativeReadStop.Cancelled ? "Lecture arrêtée ; sonde non lue." : "Budget de lecture atteint ; sonde non lue.";
            error = NativeReadProgress.Stopped(Volatile.Read(ref progressState), error);
            foreach (var definition in definitions.Where(d => !result.ContainsKey(d.Id)))
            { result = result.SetItem(definition.Id, new(MeasureState.NotRead, clock.GetUtcNow(), [], error)); }
        }
        if (!retainPartialOnCancellation) { cancellationToken.ThrowIfCancellationRequested(); }
        return result;
    }

    internal static ProbeReading Project(ProbeDefinition definition, CimReading measured, DateTimeOffset at)
    {
        var state = measured.Status switch
        {
            SourceStatus.Ok or SourceStatus.Empty => MeasureState.Known,
            SourceStatus.Refused => MeasureState.Refused,
            SourceStatus.Partial => MeasureState.Incomplete,
            SourceStatus.Error => MeasureState.Error,
            _ => MeasureState.NotRead,
        };
        if (state != MeasureState.Known) { return new(state, at, [], measured.Detail) { AuthenticationRejected = measured.AuthenticationRejected, FailureStatus = measured.Status, DefinitionHash = ProbeDefinitionIdentity.Of(definition) }; }
        if (definition.Mode == "Count") { return new(state, at, [measured.Items.ToString(CultureInfo.InvariantCulture)], null) { DefinitionHash = ProbeDefinitionIdentity.Of(definition) }; }
        var values = ImmutableArray.CreateBuilder<string>();
        var bytes = 2; var limited = false;
        void Add(string text)
        {
            // Count the actual escaped UTF-8 JSON, not characters. Incomplete is never a complete empty value.
            var size = JsonEncodedText.Encode(text).EncodedUtf8Bytes.Length + 3;
            if (bytes + size > CimBudgets.ProbeResultBytes) { limited = true; return; }
            values.Add(text); bytes += size;
        }
        foreach (var row in measured.Instances)
        {
            if (definition.Properties.Length > 1)
            {
                var cells = definition.Properties.Select(p => Format(row.Raw(p), definition)).ToArray();
                if (cells.All(v => v is not null)) { Add(string.Join('|', cells)); }
            }
            else if (definition.Properties.Length == 1)
            {
                var value = row.Raw(definition.Properties[0]);
                if (value is Array array)
                {
                    foreach (var item in array)
                    { if (Format(item, definition) is string text) { Add(text); } if (limited) { break; } }
                }
                else if (Format(value, definition) is string text) { Add(text); }
            }
            if (limited || definition.Mode == "First" && values.Count > 0) { break; }
        }
        return new(limited ? MeasureState.Incomplete : state, at, values.ToImmutable(),
            limited ? "Projection limitée à 256 Kio ; valeurs reçues conservées, sonde incomplète." : null)
        { DefinitionHash = ProbeDefinitionIdentity.Of(definition), FailureStatus = limited ? SourceStatus.Partial : null };
    }

    private static string? Format(object? value, ProbeDefinition definition)
    {
        if (value is null) { return null; }
        if (definition.Transform is "DaysSince" or "Year")
        { return value is string text && CimQuery.ParseDmtf(text) is { } date ? date.ToString("O", CultureInfo.InvariantCulture) : null; }
        return value switch
        {
            string text when !string.IsNullOrWhiteSpace(text) => text.Trim(),
            bool flag => flag ? "True" : "False",
            byte or short or ushort or int or uint or long or ulong or decimal => Convert.ToString(value, CultureInfo.InvariantCulture),
            float f when float.IsFinite(f) => f.ToString(CultureInfo.InvariantCulture),
            double d when double.IsFinite(d) => d.ToString(CultureInfo.InvariantCulture),
            _ => null,
        };
    }
}
