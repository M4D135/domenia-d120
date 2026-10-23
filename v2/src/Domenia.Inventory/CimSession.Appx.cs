using System.Runtime.InteropServices;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class CimSession
{
    internal Func<TimeSpan, ShellReading>? AppxOverride { get; init; }

    internal CimReading ReadAppx()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        const string category = "Applications du Store";
        if (Transport != InventoryTransport.WinRm || System.Net.IPAddress.TryParse(Host, out _))
        { return new(category, SourceStatus.Unavailable, "La lecture Appx demande WinRM Kerberos et le nom du poste.", 0, []); }
        if (authenticationRefused) { return new(category, SourceStatus.Refused, "Authentification déjà refusée ; aucun nouvel essai.", 0, []) { AuthenticationRejected = true }; }
        if (OutOfBudget || cancellationToken.IsCancellationRequested) { return new(category, SourceStatus.Interrupted, "Budget de lecture atteint.", 0, []); }
        var start = clock.GetTimestamp();
        var allowed = Remaining < TimeSpan.FromSeconds(60) ? Remaining : TimeSpan.FromSeconds(60);
        if (allowed <= TimeSpan.FromSeconds(2)) { return new(category, SourceStatus.Interrupted, "Budget insuffisant pour la lecture et la fermeture du shell.", 0, []); }
        var commandBudget = allowed - TimeSpan.FromSeconds(2);
        var reply = AppxOverride?.Invoke(commandBudget) ?? WinRm.ReadAppx(commandBudget);
        authenticationRefused |= reply.AuthenticationRejected;
        var duration = (int)clock.GetElapsedTime(start).TotalMilliseconds;
        var detail = reply.CleanupComplete ? "" : " Fermeture du shell de lecture non confirmée ; aucun nouvel essai de création.";
        if (reply.Status != SourceStatus.Ok || reply.Json is null)
        { return new(category, reply.Status, "Lecture Appx " + PosteLabels.SourceStatusLabel(reply.Status).ToLowerInvariant() + "." + detail, duration, []) { AuthenticationRejected = reply.AuthenticationRejected }; }
        try
        {
            var parsed = ParseAppx(reply.Json, Host) with { DurationMs = duration };
            authenticationRefused |= parsed.AuthenticationRejected;
            if (!reply.CleanupComplete) { parsed = parsed with { Status = parsed.Answered ? SourceStatus.Partial : parsed.Status, Detail = parsed.Detail + detail }; }
            return parsed;
        }
        catch (JsonException)
        { return new(category, SourceStatus.Error, "Réponse Appx malformée, hors limites ou identité différente." + detail, duration, []); }
    }

    internal static CimReading ParseAppx(string json, string host)
    {
        if (json.Length > 1_048_576) { throw new JsonException(); }
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || Text(root, "Format") != "Domenia.AppxRead/1"
            || !string.Equals(Text(root, "Computer"), host.Split('.')[0], StringComparison.OrdinalIgnoreCase)
            || !root.TryGetProperty("Code", out var codeValue) || codeValue.ValueKind != JsonValueKind.Number || !codeValue.TryGetInt32(out var code)
            || !root.TryGetProperty("Truncated", out var truncatedValue) || truncatedValue.ValueKind is not (JsonValueKind.True or JsonValueKind.False)
            || !root.TryGetProperty("Rows", out var rows) || rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > 2000)
        { throw new JsonException(); }
        var values = new List<WmiInstance>();
        var incomplete = truncatedValue.GetBoolean();
        foreach (var row in rows.EnumerateArray())
        {
            if (row.ValueKind != JsonValueKind.Object) { throw new JsonException(); }
            var name = Text(row, "Name");
            if (string.IsNullOrWhiteSpace(name)) { incomplete = true; continue; }
            var properties = new Dictionary<string, object?>();
            foreach (var property in new[] { "Name", "Version", "Publisher", "Location", "Architecture" }) { properties[property] = Text(row, property); }
            values.Add(new(properties));
        }
        var rejected = WindowsAuthenticationErrors.IsRejected(code);
        var status = code != 0 ? values.Count > 0 ? SourceStatus.Partial : CimSession.Classify(new COMException("Lecture Appx non aboutie.", code)) ?? SourceStatus.Error
            : incomplete ? SourceStatus.Partial : values.Count == 0 ? SourceStatus.Empty : SourceStatus.Ok;
        return new("Applications du Store", status, "Get-AppxPackage, tous utilisateurs, " + values.Count + " paquet(s) lu(s)."
            + (status == SourceStatus.Partial ? " Lecture incomplète : plafond, paquet illisible ou erreur du fournisseur." : ""), 0, values) { AuthenticationRejected = rejected };
    }

    private static string? Text(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var property) || property.ValueKind == JsonValueKind.Null) { return null; }
        if (property.ValueKind != JsonValueKind.String) { throw new JsonException(); }
        var value = property.GetString();
        if (value is { Length: > 4096 } || value?.Any(char.IsControl) == true) { throw new JsonException(); }
        return value;
    }
}
