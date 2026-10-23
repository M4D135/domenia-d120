using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class CimSession
{
    internal Func<InventoryShellRead, TimeSpan, ShellReading>? InventoryShellOverride { get; init; }

    internal CimReading ReadInventoryShell(InventoryShellRead kind)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var category = ShellCategory(kind);
        if (!ReadsEnabled) { return new(category, SourceStatus.Skipped, "Relevé désactivé par Remote.UseCim ; aucun contact.", 0, []); }
        if (Transport != InventoryTransport.WinRm || System.Net.IPAddress.TryParse(Host, out _))
        { return new(category, SourceStatus.Unavailable, "Cette source demande WinRM Kerberos et le nom du poste.", 0, []); }
        if (authenticationRefused) { return new(category, SourceStatus.Refused, "Authentification déjà refusée ; aucun nouvel essai.", 0, []) { AuthenticationRejected = true }; }
        if (OutOfBudget || cancellationToken.IsCancellationRequested) { return new(category, SourceStatus.Interrupted, "Budget de lecture atteint.", 0, []); }
        var start = clock.GetTimestamp();
        var ceiling = TimeSpan.FromSeconds(kind == InventoryShellRead.Tasks ? 30 : 15);
        var allowed = Remaining < ceiling ? Remaining : ceiling;
        if (allowed <= TimeSpan.FromSeconds(2)) { return new(category, SourceStatus.Interrupted, "Budget insuffisant pour la lecture et la fermeture du shell.", 0, []); }
        var reply = InventoryShellOverride?.Invoke(kind, allowed - TimeSpan.FromSeconds(2)) ?? WinRm.ReadInventory(kind, allowed - TimeSpan.FromSeconds(2));
        authenticationRefused |= reply.AuthenticationRejected;
        var detail = reply.CleanupComplete ? "" : " Fermeture du shell non confirmée ; aucune nouvelle création.";
        var duration = (int)clock.GetElapsedTime(start).TotalMilliseconds;
        if (reply.Status != SourceStatus.Ok || reply.Json is null)
        { return new(category, reply.Status, "Source " + PosteLabels.SourceStatusLabel(reply.Status).ToLowerInvariant() + "." + detail, duration, []) { AuthenticationRejected = reply.AuthenticationRejected }; }
        try
        {
            var parsed = ParseInventoryShell(kind, reply.Json, Host) with { DurationMs = duration };
            authenticationRefused |= parsed.AuthenticationRejected;
            return !reply.CleanupComplete ? parsed with { Status = parsed.Answered ? SourceStatus.Partial : parsed.Status, Detail = parsed.Detail + detail } : parsed;
        }
        catch (JsonException) { return new(category, SourceStatus.Error, "Réponse hors contrat, hors limites ou identité différente." + detail, duration, []); }
    }

    private static string ShellCategory(InventoryShellRead kind) => kind switch
    {
        InventoryShellRead.Certificates => InventoryCategories.Certificates,
        InventoryShellRead.Tasks => InventoryCategories.Tasks,
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    internal static CimReading ParseInventoryShell(InventoryShellRead kind, string json, string host)
    {
        var category = ShellCategory(kind);
        var certificates = kind == InventoryShellRead.Certificates;
        if (json.Length > 1_048_576) { throw new JsonException(); }
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || Text(root, "Format") != (certificates ? "Domenia.CertificatesRead/1" : "Domenia.TasksRead/1")
            || !string.Equals(Text(root, "Computer"), host.Split('.')[0], StringComparison.OrdinalIgnoreCase)
            || !root.TryGetProperty("Code", out var codeValue) || codeValue.ValueKind != JsonValueKind.Number || !codeValue.TryGetInt32(out var code)
            || !root.TryGetProperty("Truncated", out var truncated) || truncated.ValueKind is not (JsonValueKind.True or JsonValueKind.False)
            || !root.TryGetProperty("Rows", out var rows) || rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > (certificates ? 512 : 1000))
        { throw new JsonException(); }
        var values = new List<WmiInstance>();
        var incomplete = truncated.GetBoolean();
        foreach (var row in rows.EnumerateArray())
        {
            if (row.ValueKind != JsonValueKind.Object) { throw new JsonException(); }
            var properties = new Dictionary<string, object?>();
            foreach (var property in certificates ? new[] { "Subject", "Issuer", "NotAfter", "Thumbprint" } : ["Name", "Path", "Author", "State", "LastResult", "LastRun", "NextRun"])
            { properties[property] = Text(row, property); }
            if (certificates)
            {
                var thumbprint = (string?)properties["Thumbprint"];
                if (thumbprint is not { Length: 40 } || !thumbprint.All(char.IsAsciiHexDigit) || UtcDate((string?)properties["NotAfter"]) is null)
                { incomplete = true; continue; }
                if (!row.TryGetProperty("Usages", out var usages) || usages.ValueKind != JsonValueKind.Array || usages.GetArrayLength() > 64) { throw new JsonException(); }
                var oids = usages.EnumerateArray().Select(value => value.ValueKind == JsonValueKind.String ? value.GetString() : throw new JsonException()).ToArray();
                if (oids.Any(oid => oid is not { Length: > 0 and <= 128 } || oid.Any(c => !char.IsAsciiDigit(c) && c != '.'))) { throw new JsonException(); }
                properties["Usages"] = oids;
            }
            else
            {
                if (properties["Name"] is not string { Length: > 0 } || properties["Path"] is not string { Length: > 0 }) { incomplete = true; continue; }
                foreach (var date in new[] { "LastRun", "NextRun" })
                {
                    if (properties[date] is string text && UtcDate(text) is null) { incomplete = true; properties[date] = null; }
                }
                if (properties["LastResult"] is not string result || !uint.TryParse(result, NumberStyles.None, CultureInfo.InvariantCulture, out _))
                { incomplete = true; properties["LastResult"] = null; }
                if (properties["State"] is not string state || !int.TryParse(state, NumberStyles.None, CultureInfo.InvariantCulture, out var number) || number is < 0 or > 4)
                { incomplete = true; properties["State"] = null; }
            }
            values.Add(new(properties));
        }
        var rejected = WindowsAuthenticationErrors.IsRejected(code);
        var status = code != 0 ? values.Count > 0 ? SourceStatus.Partial : Classify(new COMException("Source non lue.", code)) ?? SourceStatus.Error
            : incomplete ? SourceStatus.Partial : values.Count == 0 ? SourceStatus.Empty : SourceStatus.Ok;
        return new(category, status, (certificates ? "Certificats publics du magasin machine My" : "Définitions et dernières exécutions des tâches")
            + " : " + values.Count + " élément(s)." + (status == SourceStatus.Partial ? " Lecture incomplète, élément illisible ou plafond atteint." : ""), 0, values) { AuthenticationRejected = rejected };
    }

    internal static DateTimeOffset? UtcDate(string? text) => text is { Length: <= 40 } && (text.EndsWith('Z') || text.EndsWith("+00:00", StringComparison.Ordinal))
        && DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) ? date : null;
}
