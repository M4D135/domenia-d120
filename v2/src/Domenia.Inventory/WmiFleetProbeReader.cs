using System.Collections.Immutable;
using System.Globalization;
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

    public async Task<ImmutableDictionary<string, ProbeReading>> ReadAsync(DirectoryComputer computer, ImmutableArray<string> probeIds, CancellationToken cancellationToken, RemoteProbeCredential? credential = null, PosteConfiguration? configuration = null)
    {
        var definitions = probeIds.Distinct(StringComparer.Ordinal).Select(id => ProbeCatalog.Find(id)
            ?? throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Sonde inconnue : aucun poste contacté.")).ToArray();
        if (configuration is { UseCim: false })
        { return definitions.ToImmutableDictionary(d => d.Id, _ => new ProbeReading(MeasureState.NotRead, clock.GetUtcNow(), [], "Lecture CIM désactivée par Remote.UseCim ; aucun contact.")); }
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var gate = new object();
        var latest = ImmutableDictionary<string, ProbeReading>.Empty.WithComparers(StringComparer.Ordinal);
        Task<ImmutableDictionary<string, ProbeReading>> reading;
        try { reading = WmiReadWorkers.Start(credential, owned =>
        {
            var host = computer.DnsHostName ?? computer.Name;
            using var session = SessionFactory?.Invoke(host, CimBudgets.Probes, stop.Token) ?? new CimSession(host, CimBudgets.Probes, clock, cancellationToken: stop.Token, credential: owned,
                transport: configuration?.Options.UseWinRm == true ? InventoryTransport.WinRm : InventoryTransport.Dcom);
            CimReading? identity = null;
            if (definitions.Any(d => !d.SkipOnDc || (computer.UserAccountControl & 8192) == 0))
            { identity = session.Read("identity", @"root\cimv2", "SELECT Name FROM Win32_ComputerSystem", 1, TimeSpan.FromSeconds(4)); }
            var confirmed = identity?.Status == SourceStatus.Ok && WorkstationIdentity.Matches(computer, identity.Instances.FirstOrDefault()?.Text("Name"));
            foreach (var definition in definitions)
            {
                if (stop.IsCancellationRequested) { break; }
                ProbeReading result;
                if (definition.SkipOnDc && (computer.UserAccountControl & 8192) != 0)
                { result = new(MeasureState.NotRead, clock.GetUtcNow(), [], "Sonde exclue sur les contrôleurs de domaine."); }
                else if (!confirmed)
                { result = new(identity?.Status == SourceStatus.Refused ? MeasureState.Refused : MeasureState.Incomplete, clock.GetUtcNow(), [], "Identité CIM non confirmée ; sondes non associées au poste.") { AuthenticationRejected = identity?.AuthenticationRejected == true }; }
                else
                {
                    var query = "SELECT " + string.Join(", ", definition.Properties) + " FROM " + definition.Class
                        + (string.IsNullOrWhiteSpace(definition.Filter) ? "" : " WHERE " + definition.Filter);
                    var measured = session.Read(definition.Id, definition.Namespace, query, 2000, TimeSpan.FromSeconds(12));
                    result = Project(definition, measured, clock.GetUtcNow());
                }
                lock (gate) { latest = latest.SetItem(definition.Id, result); }
            }
            lock (gate) { return latest; }
        }, cancellationToken); }
        catch { stop.Dispose(); throw; }
        try { return await reading.WaitAsync(CimBudgets.Probes + CimBudgets.GiveUpMargin, clock, cancellationToken).ConfigureAwait(false); }
        catch (TimeoutException)
        {
            stop.Cancel();
            lock (gate)
            {
                foreach (var definition in definitions.Where(d => !latest.ContainsKey(d.Id)))
                { latest = latest.SetItem(definition.Id, new(MeasureState.NotRead, clock.GetUtcNow(), [], "Budget de lecture atteint.")); }
                return latest;
            }
        }
        catch (OperationCanceledException) { stop.Cancel(); throw; }
        finally
        {
            if (reading.IsCompleted) { stop.Dispose(); }
            else { _ = reading.ContinueWith(t => { _ = t.Exception; stop.Dispose(); }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default); }
        }
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
        if (state != MeasureState.Known) { return new(state, at, [], measured.Detail) { AuthenticationRejected = measured.AuthenticationRejected }; }
        if (definition.Mode == "Count") { return new(state, at, [measured.Items.ToString(CultureInfo.InvariantCulture)], null); }
        var values = ImmutableArray.CreateBuilder<string>();
        foreach (var row in measured.Instances)
        {
            if (definition.Properties.Length > 1)
            {
                var cells = definition.Properties.Select(p => Format(row.Raw(p), definition)).ToArray();
                if (cells.All(v => v is not null)) { values.Add(string.Join('|', cells)); }
            }
            else if (definition.Properties.Length == 1)
            {
                var value = row.Raw(definition.Properties[0]);
                if (value is Array array)
                {
                    foreach (var item in array) { if (Format(item, definition) is string text) { values.Add(text); } }
                }
                else if (Format(value, definition) is string text) { values.Add(text); }
            }
            if (definition.Mode == "First" && values.Count > 0) { break; }
        }
        return new(state, at, values.ToImmutable(), null);
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
