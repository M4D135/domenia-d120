using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class CimSession
{
    internal Func<EventQuery, TimeSpan, ShellReading>? EventsShellOverride { get; init; }

    internal CimReading ReadEvents(EventQuery query, Action<CimReading>? publish = null)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var preset = WsmanReadChannel.CheckedEventPreset(query);
        const string category = InventoryCategories.Events;
        if (!ReadsEnabled) { return new(category, SourceStatus.Skipped, "Relevé CIM désactivé ; aucun contact.", 0, []); }
        if (authenticationRefused) { return new(category, SourceStatus.Refused, "Authentification déjà refusée ; aucun nouvel essai.", 0, []) { AuthenticationRejected = true }; }
        if (OutOfBudget || cancellationToken.IsCancellationRequested) { return new(category, SourceStatus.Interrupted, "Lecture arrêtée ou budget atteint.", 0, []); }
        var start = clock.GetTimestamp();
        if (Transport != InventoryTransport.WinRm) { return ReadClassicEvents(query, preset, publish); }
        if (System.Net.IPAddress.TryParse(Host, out _)) { return new(category, SourceStatus.Unavailable, "WinRM Kerberos demande le nom DNS du poste.", 0, []); }
        var budget = Remaining < TimeSpan.FromSeconds(30) ? Remaining : TimeSpan.FromSeconds(30);
        if (budget <= TimeSpan.FromSeconds(2)) { return new(category, SourceStatus.Interrupted, "Budget insuffisant pour lire et fermer le shell.", 0, []); }
        var reply = EventsShellOverride?.Invoke(query, budget - TimeSpan.FromSeconds(2)) ?? WinRm.ReadEvents(query, budget - TimeSpan.FromSeconds(2));
        authenticationRefused |= reply.AuthenticationRejected;
        var detail = reply.CleanupComplete ? "" : " Fermeture du shell non confirmée ; aucune nouvelle création.";
        var duration = (int)clock.GetElapsedTime(start).TotalMilliseconds;
        if (reply.Status != SourceStatus.Ok || reply.Json is null)
        { return new(category, reply.Status, "Journal " + PosteLabels.SourceStatusLabel(reply.Status).ToLowerInvariant() + "." + detail, duration, []) { AuthenticationRejected = reply.AuthenticationRejected }; }
        try
        {
            var result = ParseEvents(reply.Json, Host, query) with { DurationMs = duration };
            authenticationRefused |= result.AuthenticationRejected;
            return reply.CleanupComplete ? result : result with { Status = result.Answered ? SourceStatus.Partial : result.Status, Detail = result.Detail + detail };
        }
        catch (JsonException) { return new(category, SourceStatus.Error, "Réponse d’événements hors contrat, hors limites ou identité différente." + detail, duration, []); }
    }

    private CimReading ReadClassicEvents(EventQuery query, EventPreset preset, Action<CimReading>? publish)
    {
        var readings = new List<CimReading>();
        var start = query.Start.UtcDateTime.ToString("yyyyMMddHHmmss.ffffff+000", CultureInfo.InvariantCulture);
        var end = query.End.UtcDateTime.ToString("yyyyMMddHHmmss.ffffff+000", CultureInfo.InvariantCulture);
        foreach (var log in preset.Logs)
        {
            if (log is not ("System" or "Application"))
            { readings.Add(new(InventoryCategories.Events, SourceStatus.Unavailable, "Le journal " + log + " demande la lecture WinRM ; aucun repli implicite.", 0, [])); continue; }
            var where = "Logfile='" + log + "' AND TimeGenerated>='" + start + "' AND TimeGenerated<='" + end + "' AND ("
                + string.Join(" OR ", preset.EventIds.Select(id => "EventCode=" + id.ToString(CultureInfo.InvariantCulture))) + ") AND ("
                + string.Join(" OR ", preset.Providers.Select(p => "SourceName='" + p + "'")) + ")";
            var reading = Read(InventoryCategories.Events, @"root\cimv2",
                "SELECT Logfile, SourceName, EventCode, EventType, TimeGenerated, ComputerName, Message FROM Win32_NTLogEvent WHERE " + where, query.MaxEvents + 1, TimeSpan.FromSeconds(30));
            readings.Add(reading with { Instances = [.. reading.Instances.Select(r => new WmiInstance(new Dictionary<string, object?>
            {
                ["Id"] = r.Int("EventCode"), ["Provider"] = r.Text("SourceName"), ["Log"] = r.Text("Logfile"),
                ["Level"] = r.Int("EventType") switch { 1 => 2, 2 => 3, 4 => 4, 8 => 0, 16 => 0, _ => -1 },
                ["At"] = r.Dmtf("TimeGenerated")?.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture),
                ["Machine"] = r.Text("ComputerName"), ["Message"] = PosteText.Flat(r.Text("Message") ?? "", 500),
            }))] });
            publish?.Invoke(CombineEvents([.. readings, .. readings.Count < preset.Logs.Length
                ? new[] { new CimReading(InventoryCategories.Events, SourceStatus.Interrupted, "Autres journaux non encore lus.", 0, []) } : []], query));
        }
        return CombineEvents(readings, query);
    }

    internal static CimReading ParseEvents(string json, string host, EventQuery query)
    {
        var preset = WsmanReadChannel.CheckedEventPreset(query);
        if (json.Length > 1_048_576) { throw new JsonException(); }
        using var doc = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object || Text(root, "Format") != "Domenia.EventsRead/1"
            || !string.Equals(Text(root, "Computer"), host.Split('.')[0], StringComparison.OrdinalIgnoreCase)
            || !root.TryGetProperty("Access", out var access) || access.ValueKind != JsonValueKind.Array || access.GetArrayLength() != preset.Logs.Length
            || !root.TryGetProperty("Rows", out var rows) || rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > (query.MaxEvents + 1) * preset.Logs.Length)
        { throw new JsonException(); }
        var readings = new List<CimReading>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var part in access.EnumerateArray())
        {
            if (part.ValueKind != JsonValueKind.Object) { throw new JsonException(); }
            var log = Text(part, "Log");
            if (log is null || !preset.Logs.Contains(log, StringComparer.OrdinalIgnoreCase) || !seen.Add(log)
                || !part.TryGetProperty("Code", out var code) || code.ValueKind != JsonValueKind.Number || !code.TryGetInt32(out var value)
                || !part.TryGetProperty("Partial", out var partial) || partial.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) { throw new JsonException(); }
            var values = new List<WmiInstance>();
            foreach (var row in rows.EnumerateArray())
            {
                if (row.ValueKind != JsonValueKind.Object) { throw new JsonException(); }
                var rowLog = Text(row, "Log");
                if (rowLog is null || !preset.Logs.Contains(rowLog, StringComparer.OrdinalIgnoreCase)) { throw new JsonException(); }
                if (!rowLog.Equals(log, StringComparison.OrdinalIgnoreCase)) { continue; }
                if (!row.TryGetProperty("Id", out var id) || id.ValueKind != JsonValueKind.Number || !id.TryGetInt32(out var number)
                    || !row.TryGetProperty("Level", out var level) || level.ValueKind != JsonValueKind.Number || !level.TryGetInt32(out var severity)) { throw new JsonException(); }
                values.Add(new(new Dictionary<string, object?>
                {
                    ["Id"] = number, ["Level"] = severity, ["Log"] = rowLog, ["Provider"] = Text(row, "Provider"),
                    ["At"] = Text(row, "At"), ["Machine"] = Text(row, "Machine"), ["Message"] = Text(row, "Message"),
                }));
            }
            if (values.Count > query.MaxEvents + 1) { throw new JsonException(); }
            var status = value != 0 ? values.Count > 0 ? SourceStatus.Partial : Classify(new COMException("Journal non lu.", value)) ?? SourceStatus.Error
                : partial.GetBoolean() ? SourceStatus.Partial : values.Count == 0 ? SourceStatus.Empty : SourceStatus.Ok;
            readings.Add(new(InventoryCategories.Events, status, log + " : " + PosteLabels.SourceStatusLabel(status), 0, values) { AuthenticationRejected = WindowsAuthenticationErrors.IsRejected(value) });
        }
        return CombineEvents(readings, query);
    }

    private static CimReading CombineEvents(IReadOnlyList<CimReading> readings, EventQuery query)
    {
        var preset = WsmanReadChannel.CheckedEventPreset(query);
        var raw = readings.SelectMany(r => r.Answered ? r.Instances : []).ToArray();
        var valid = raw.Where(r => r.Int("Id") is { } id && preset.EventIds.Contains(id)
            && r.Text("Log") is { } log && preset.Logs.Contains(log, StringComparer.OrdinalIgnoreCase)
            && r.Text("Provider") is { } provider && preset.Providers.Contains(provider, StringComparer.OrdinalIgnoreCase)
            && r.Int("Level") is >= 0 and <= 5 && UtcDate(r.Text("At")) is { } at && at >= query.Start && at <= query.End
            && r.Raw("Message") is string { Length: <= 500 }).OrderByDescending(r => UtcDate(r.Text("At"))).Take(query.MaxEvents).ToArray();
        var answered = readings.Any(r => r.Answered);
        var partial = raw.Length != valid.Length || readings.Any(r => r.Status is not (SourceStatus.Ok or SourceStatus.Empty));
        var status = answered ? partial ? SourceStatus.Partial : valid.Length > 0 ? SourceStatus.Ok : SourceStatus.Empty
            : readings.Any(r => r.Status == SourceStatus.Refused) ? SourceStatus.Refused
            : readings.Any(r => r.Status == SourceStatus.Interrupted) ? SourceStatus.Interrupted : SourceStatus.Unavailable;
        return new(InventoryCategories.Events, status, string.Join(" · ", readings.Select(r => r.Detail)) + (partial ? " · Lecture incomplète : aucune absence confirmée." : ""),
            readings.Sum(r => r.DurationMs), valid) { AuthenticationRejected = readings.Any(r => r.AuthenticationRejected) };
    }
}
