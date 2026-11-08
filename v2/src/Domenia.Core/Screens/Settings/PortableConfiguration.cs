using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Domenia.Core;

public sealed record PortableConfigurationDocument(string Text, string Sha256, DateTimeOffset ExportedAt, string Mode,
    ImmutableDictionary<string, JsonElement> Values, JsonElement? Interface);
public sealed record PortableConfigurationExport(string Text, string Sha256, ImmutableArray<string> Included, ImmutableArray<string> Excluded);

/// <summary>Strict reusable preferences-export codec. No path, identity, account, data or execution permission is inferred.</summary>
public static class PortableConfiguration
{
    public const string FileName = "Domenia.settings.seed.json";
    public const int MaxBytes = PreferenceTransfer.MaxBytes;
    public static ImmutableArray<string> InterfaceFields { get; } = ["theme", "motion", "navCollapsed", "profile", "density", "helpTips", "logWrap", "logSize"];

    public static PortableConfigurationDocument Read(string text)
    {
        if (string.IsNullOrWhiteSpace(text) || Encoding.UTF8.GetByteCount(text) > MaxBytes) throw Invalid();
        using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = PreferenceTransfer.MaxDepth + 4 });
        var root = document.RootElement;
        Duplicates(root);
        Fields(root, ["format", "version", "exportedAt", "mode", "values", "interface"]);
        if (!root.TryGetProperty("format", out var format) || format.ValueKind != JsonValueKind.String || format.GetString() != PreferenceTransfer.Format
            || !root.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var number) || number != PreferenceTransfer.Version
            || !root.TryGetProperty("exportedAt", out var at) || at.ValueKind != JsonValueKind.String || !at.TryGetDateTimeOffset(out var exportedAt)
            || !root.TryGetProperty("mode", out var mode) || mode.ValueKind != JsonValueKind.String || mode.GetString() is not { Length: > 0 and <= 80 } modeName || modeName.Any(char.IsControl)
            || !root.TryGetProperty("values", out var values) || values.ValueKind != JsonValueKind.Object || values.EnumerateObject().Count() > PreferenceTransfer.MaxKeys)
            throw Invalid();
        var result = ImmutableDictionary.CreateBuilder<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in values.EnumerateObject())
        {
            ValidateValue(property.Name, property.Value);
            result.Add(property.Name, property.Value.Clone());
        }
        JsonElement? ui = root.TryGetProperty("interface", out var raw) ? ValidateInterface(raw) : null;
        return new(text, Hash(text), exportedAt, modeName, result.ToImmutable(), ui);
    }

    public static void ValidateValue(string key, JsonElement value)
    {
        if (Encoding.UTF8.GetByteCount(value.GetRawText()) > PreferenceTransfer.MaxValueBytes || PreferenceApproval.Problem(key, value) is not null) throw Invalid();
        Duplicates(value);
        if (key.StartsWith(WorkingScope.PreferencePrefix, StringComparison.Ordinal)) Fields(value, ["dn", "subtree"]);
        if (key == StoragePolicyRules.PreferenceKey)
            Fields(value, ["automaticBackup", "backupHours", "backupKeep", "presenceDays", "consoleDays", "inventoryDays", "probeDays", "detailDays", "linkHistoryDays"]);
        if (key == CollectionSettingsRules.PreferenceKey)
        {
            Fields(value, ["profile", "freshness", "windows", "budgets", .. CollectionSettingsRules.BudgetDefinitions.Select(b => b.Id)]);
            foreach (var name in new[] { "freshness", "windows", "budgets" })
                if (value.TryGetProperty(name, out var child) && child.ValueKind != JsonValueKind.Object) throw Invalid();
            if (value.TryGetProperty("budgets", out var budgets)) Fields(budgets, [.. CollectionSettingsRules.BudgetDefinitions.Select(b => b.Id)]);
            // The owning validator checks profile/family names and every scalar; no unrecognized root payload survives.
        }
    }

    public static JsonElement ValidateInterface(JsonElement value)
    {
        Fields(value, InterfaceFields);
        Duplicates(value);
        foreach (var property in value.EnumerateObject())
        {
            var valid = property.Name switch
            {
                "logWrap" => property.Value.ValueKind is JsonValueKind.True or JsonValueKind.False,
                "logSize" => property.Value.ValueKind == JsonValueKind.Number && property.Value.TryGetInt32(out var n) && n is 10 or 11 or 12 or 14 or 16 or 18,
                _ => ShellInterfaceRules.NormalizeField(property.Name, property.Value) is not null,
            };
            if (!valid) throw Invalid();
        }
        return value.Clone();
    }

    public static ImmutableDictionary<string, JsonElement> WithDefaults(IReadOnlyDictionary<string, JsonElement> values)
    {
        var result = values.ToImmutableDictionary(StringComparer.Ordinal).ToBuilder();
        result.TryAdd(DashboardService.DisabledWidgetsPreference, JsonSerializer.SerializeToElement(Array.Empty<string>()));
        result.TryAdd(CollectionSettingsRules.PreferenceKey, CollectionSettingsRules.ToJson(CollectionSettingsRules.Default));
        result.TryAdd(StoragePolicyRules.PreferenceKey, StoragePolicyRules.ToJson(StoragePolicyRules.Default));
        result.TryAdd(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(100));
        return result.ToImmutable();
    }

    public static PortableConfigurationExport Export(IReadOnlyDictionary<string, JsonElement> values, IReadOnlyList<string> selectedKeys, JsonElement? ui, string mode, DateTimeOffset now)
    {
        if (selectedKeys.Count > PreferenceTransfer.MaxKeys || selectedKeys.Distinct(StringComparer.Ordinal).Count() != selectedKeys.Count) throw Invalid();
        var available = WithDefaults(values);
        var kept = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var key in selectedKeys)
        {
            if (!available.TryGetValue(key, out var value)) throw Invalid();
            ValidateValue(key, value); kept.Add(key, value);
        }
        var exported = PreferenceTransfer.Export(kept, mode, now);
        var root = JsonNode.Parse(exported.Text)!.AsObject();
        if (ui is { } part) root["interface"] = JsonNode.Parse(ValidateInterface(part).GetRawText());
        var text = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        var parsed = Read(text);
        return new(text, parsed.Sha256, [.. kept.Keys.Order(StringComparer.Ordinal), .. (ui is null ? Array.Empty<string>() : new[] { "interface" })],
            [.. available.Keys.Where(k => !kept.ContainsKey(k)).Order(StringComparer.Ordinal)]);
    }

    public static string Hash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    private static InvalidDataException Invalid() => new("Configuration distribuable invalide, inconnue ou hors limites ; aucune valeur appliquée.");
    private static void Fields(JsonElement value, IEnumerable<string> allowed)
    {
        if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Any(p => !allowed.Contains(p.Name, StringComparer.Ordinal))) throw Invalid();
    }
    private static void Duplicates(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in value.EnumerateObject()) { if (!seen.Add(property.Name)) throw Invalid(); Duplicates(property.Value); }
        }
        else if (value.ValueKind == JsonValueKind.Array) foreach (var child in value.EnumerateArray()) Duplicates(child);
    }
}
