using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed record WorkstationProbesRead(string? ReportedName, DateTimeOffset At,
    ImmutableArray<SourceAccess> Access, ImmutableDictionary<string, ProbeValues> Values)
{
    public NativeWorkstationIdentity? HostIdentity { get; init; }
}

public sealed partial class WmiWorkstationReader
{
    public static ImmutableArray<ProbeInfo> CheckProbes(ImmutableArray<string> ids)
    {
        if (!ids.IsDefault && ids.Length > ProbeCatalog.Probes.Length) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Trop de sondes demandées."); }
        var selected = ids.IsDefaultOrEmpty ? PosteReadings.Catalog.SelectMany(r => r.Probes).Distinct(StringComparer.Ordinal) : ids.Distinct(StringComparer.Ordinal);
        return [.. selected.Select(id => ProbeCatalog.Find(id) ?? throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Sonde inconnue ; aucun contact."))];
    }

    public async Task<WorkstationProbesRead> ReadProbesAsync(string host, ImmutableArray<string> ids, IProgress<PosteProgress>? progress,
        CancellationToken cancellationToken, RemoteProbeCredential? credential = null)
    {
        var definitions = CheckProbes(ids);
        if (!CimQuery.IsHostName(host)) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Nom de poste invalide."); }
        var budget = CimBudgets.ProbesFor(definitions.Length);
        var latest = new WorkstationProbesRead(null, clock.GetUtcNow(), [], ImmutableDictionary<string, ProbeValues>.Empty);
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        NativeReadProgress? progressState = null;
        Task<WorkstationProbesRead> work;
        try { work = await WmiReadWorkers.StartAsync(host, credential, owned =>
        {
            using var advancing = new NativeReadProgress(clock, budget, inventory: false, stop.Token);
            Volatile.Write(ref progressState, advancing);
            using var session = Session(host, budget, advancing.Token, owned);
            session.QueryCompleted = advancing.Completed;
            var identity = session.Read("identity", Cimv2, "SELECT Name, DNSHostName, Domain FROM Win32_ComputerSystem", 1, TimeSpan.FromSeconds(3), allowProjectionReuse: false);
            var name = identity.Status == SourceStatus.Ok ? identity.Instances.SingleOrDefault()?.Text("Name") : null;
            var confirmed = identity.HostIdentity?.State == NativeIdentityState.Confirmed;
            string Query(ProbeInfo d) => "SELECT " + string.Join(", ", d.Properties) + " FROM " + d.Class + (d.Filter.Length == 0 ? "" : " WHERE " + d.Filter);
            session.PlanProjections(definitions.Select(d => new CimProjection(d.Namespace, Query(d), PosteProbeCache.MaxRows)), ProjectionReused);
            var result = latest with { ReportedName = name, HostIdentity = identity.HostIdentity };
            Volatile.Write(ref latest, result);
            foreach (var definition in definitions)
            {
                if (advancing.Token.IsCancellationRequested || session.OutOfBudget) { break; }
                progress?.Report(new(result.Access.Length, definitions.Length, definition.Name));
                var rows = ImmutableArray.CreateBuilder<ImmutableArray<JsonElement>>(); var bytes = 2; var limited = false; var omittedRows = 0; var omittedCells = 0; var secretsRemoved = 0;
                var at = clock.GetUtcNow();
                JsonElement RemovedSecret() { secretsRemoved++; return JsonSerializer.SerializeToElement<object?>(null); }
                ProbeValues Values(bool complete) => new(at, complete, rows.ToImmutable()) { DefinitionHash = ProbeDefinitionIdentity.Of(definition), Columns = definition.Properties, OmittedRows = omittedRows, OmittedCells = omittedCells, SecretsRemoved = secretsRemoved };
                void Receive(WmiInstance row)
                {
                    var cells = definition.Properties.Select(p => PosteDetailPrivacy.Sensitive(p) ? RemovedSecret() : ProbeCell(row.Raw(p), ref omittedCells)).ToImmutableArray();
                    var size = Encoding.UTF8.GetByteCount(JsonSerializer.Serialize(cells)) + 1;
                    if (bytes + size > PosteProbeCache.ProjectionBytes - 1024 || rows.Count == PosteProbeCache.MaxRows) { omittedRows++; limited = true; }
                    else { rows.Add(cells); bytes += size; }
                    limited |= omittedCells > 0 || secretsRemoved > 0;
                    Volatile.Write(ref latest, result with
                    {
                        At = at, Values = result.Values.SetItem(definition.Id, Values(false)),
                        Access = [.. result.Access, new(definition.Id, SourceStatus.Partial, "Lecture en cours ; lignes reçues conservées.", 0, rows.Count, transport)],
                    });
                }
                var reading = confirmed ? session.Read(definition.Id, definition.Namespace,
                    Query(definition),
                    PosteProbeCache.MaxRows, CimBudgets.ProbeQuery, Receive)
                    : new CimReading(definition.Id, identity.Status is SourceStatus.Refused or SourceStatus.Skipped ? identity.Status : SourceStatus.Unavailable,
                        "Identité Windows non confirmée ; sonde non contactée.", 0, []) { AuthenticationRejected = identity.AuthenticationRejected };
                if (advancing.Token.IsCancellationRequested || session.OutOfBudget) { reading = reading with { Detail = NativeReadProgress.Stopped(advancing, reading.Detail) }; }
                if (limited && reading.Answered) { reading = reading with { Status = SourceStatus.Partial, Detail = "Valeurs ou volume bornés ; relevé incomplet." }; }
                var values = result.Values;
                if (reading.Answered) { values = values.SetItem(definition.Id, Values(reading.Status is SourceStatus.Ok or SourceStatus.Empty)); }
                result = result with { At = at, Values = values, Access = [.. result.Access, reading.ToAccess(transport) with { Items = rows.Count }] };
                Volatile.Write(ref latest, result);
            }
            return result;
        }, cancellationToken).ConfigureAwait(false); }
        catch { stop.Dispose(); throw; }
        WorkstationProbesRead received;
        try { received = await work.WaitAsync(budget + CimBudgets.GiveUpMargin, clock, cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        { stop.Cancel(); received = Volatile.Read(ref latest); }
        finally { DisposeAfter(work, stop); }
        return received with { Access = [.. received.Access, .. definitions.Where(d => !received.Access.Any(a => a.Category == d.Id))
            .Select(d => new SourceAccess(d.Id, SourceStatus.Interrupted, NativeReadProgress.Stopped(Volatile.Read(ref progressState), "Arrêt ou budget atteint ; sonde non lue."), 0, 0, transport))] };
    }

    private static JsonElement ProbeCell(object? value, ref int omitted)
    {
        if (value is DateTimeOffset offset) value = offset.UtcDateTime.ToString("O", System.Globalization.CultureInfo.InvariantCulture);
        else if (value is DateTime date)
        {
            if (date.Kind != DateTimeKind.Utc) { omitted++; return JsonSerializer.SerializeToElement<object?>(null); }
            value = date.ToString("O", System.Globalization.CultureInfo.InvariantCulture);
        }
        if (value is Array array && (array.Rank != 1 || array.Length > 256)) { omitted++; return JsonSerializer.SerializeToElement<object?>(null); }
        if (value is not (null or string or bool or byte or short or ushort or int or uint or long or ulong or float or double or decimal or Array)
            || value is float f && !float.IsFinite(f) || value is double d && !double.IsFinite(d))
        { omitted++; return JsonSerializer.SerializeToElement<object?>(null); }
        if (value is Array items)
        {
            var cells = new List<JsonElement>();
            foreach (var item in items)
            { if (item is Array) { omitted++; cells.Add(JsonSerializer.SerializeToElement<object?>(null)); } else { cells.Add(ProbeCell(item, ref omitted)); } }
            return JsonSerializer.SerializeToElement(cells);
        }
        if (value is string text && Encoding.UTF8.GetByteCount(text) > PosteProbeCache.MaxCellBytes) { omitted++; value = null; }
        return JsonSerializer.SerializeToElement(value);
    }
}
