using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed record WorkstationProbesRead(string? ReportedName, DateTimeOffset At,
    ImmutableArray<SourceAccess> Access, ImmutableDictionary<string, ProbeValues> Values);

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
        var latest = new WorkstationProbesRead(null, clock.GetUtcNow(), [], ImmutableDictionary<string, ProbeValues>.Empty);
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Task<WorkstationProbesRead> work;
        try { work = WmiReadWorkers.Start(credential, owned =>
        {
            using var session = Session(host, CimBudgets.Probes, stop.Token, owned);
            var identity = session.Read("identity", Cimv2, "SELECT Name FROM Win32_ComputerSystem", 1, TimeSpan.FromSeconds(3));
            var name = identity.Status == SourceStatus.Ok ? identity.Instances.SingleOrDefault()?.Text("Name") : null;
            var confirmed = string.Equals(host.Split('.')[0], name, StringComparison.OrdinalIgnoreCase);
            var result = latest with { ReportedName = name };
            Volatile.Write(ref latest, result);
            foreach (var definition in definitions)
            {
                if (stop.IsCancellationRequested || session.OutOfBudget) { break; }
                progress?.Report(new(result.Access.Length, definitions.Length, definition.Name));
                var rows = ImmutableArray.CreateBuilder<ImmutableArray<JsonElement>>(); var bytes = 2; var limited = false;
                var at = clock.GetUtcNow();
                void Receive(WmiInstance row)
                {
                    var cells = definition.Properties.Select(p => ProbeCell(row.Raw(p), ref limited)).ToImmutableArray();
                    var size = Encoding.UTF8.GetByteCount(JsonSerializer.Serialize(cells)) + 1;
                    if (bytes + size > PosteProbeCache.MaxProbeBytes - 1024) { limited = true; return; }
                    rows.Add(cells); bytes += size;
                    Volatile.Write(ref latest, result with
                    {
                        At = at, Values = result.Values.SetItem(definition.Id, new(at, false, rows.ToImmutable())),
                        Access = [.. result.Access, new(definition.Id, SourceStatus.Partial, "Lecture en cours ; lignes reçues conservées.", 0, rows.Count, transport)],
                    });
                }
                var reading = confirmed ? session.Read(definition.Id, definition.Namespace,
                    "SELECT " + string.Join(", ", definition.Properties) + " FROM " + definition.Class + (definition.Filter.Length == 0 ? "" : " WHERE " + definition.Filter),
                    PosteProbeCache.MaxRows, TimeSpan.FromSeconds(8), Receive)
                    : new CimReading(definition.Id, identity.Status is SourceStatus.Refused or SourceStatus.Skipped ? identity.Status : SourceStatus.Unavailable,
                        "Identité Windows non confirmée ; sonde non contactée.", 0, []) { AuthenticationRejected = identity.AuthenticationRejected };
                if (limited && reading.Answered) { reading = reading with { Status = SourceStatus.Partial, Detail = "Valeurs ou volume bornés ; relevé incomplet." }; }
                var values = result.Values;
                if (reading.Answered) { values = values.SetItem(definition.Id, new(at, reading.Status is SourceStatus.Ok or SourceStatus.Empty, rows.ToImmutable())); }
                result = result with { At = at, Values = values, Access = [.. result.Access, reading.ToAccess(transport) with { Items = rows.Count }] };
                Volatile.Write(ref latest, result);
            }
            return result;
        }, cancellationToken); }
        catch { stop.Dispose(); throw; }
        WorkstationProbesRead received;
        try { received = await work.WaitAsync(CimBudgets.Probes + CimBudgets.GiveUpMargin, clock, cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        { stop.Cancel(); received = Volatile.Read(ref latest); }
        finally { DisposeAfter(work, stop); }
        return received with { Access = [.. received.Access, .. definitions.Where(d => !received.Access.Any(a => a.Category == d.Id))
            .Select(d => new SourceAccess(d.Id, SourceStatus.Interrupted, "Arrêt ou budget atteint ; sonde non lue.", 0, 0, transport))] };
    }

    private static JsonElement ProbeCell(object? value, ref bool limited)
    {
        if (value is Array array && (array.Rank != 1 || array.Length > 256)) { limited = true; return JsonSerializer.SerializeToElement<object?>(null); }
        if (value is not (null or string or bool or byte or short or ushort or int or uint or long or ulong or float or double or decimal or Array)
            || value is float f && !float.IsFinite(f) || value is double d && !double.IsFinite(d))
        { limited = true; return JsonSerializer.SerializeToElement<object?>(null); }
        if (value is Array items)
        {
            var cells = new List<JsonElement>();
            foreach (var item in items)
            { if (item is Array) { limited = true; cells.Add(JsonSerializer.SerializeToElement<object?>(null)); } else { cells.Add(ProbeCell(item, ref limited)); } }
            return JsonSerializer.SerializeToElement(cells);
        }
        if (value is string text && text.Length > 2048) { limited = true; value = null; }
        return JsonSerializer.SerializeToElement(value);
    }
}
