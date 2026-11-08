using System.Collections.Immutable;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>Lossless bounded entries. Legacy nested arrays are flattened, never repaired or filtered on save.</summary>
public sealed record SearchWorkspaceStore(ImmutableArray<JsonElement> Entries, bool LegacyImported)
{
    public static SearchWorkspaceStore Read(JsonElement? value)
    {
        if (value is null) return new([], false);
        var raw = value.Value;
        if (Encoding.UTF8.GetByteCount(raw.GetRawText()) > SearchMemoryRules.MaxStoreBytes) throw Refused();
        var imported = false;
        if (raw.ValueKind == JsonValueKind.Object)
        {
            if (raw.EnumerateObject().Select(p => p.Name).Distinct(StringComparer.Ordinal).Count() != 3
                || raw.EnumerateObject().Count() != 3 || !raw.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var v) || v != 1
                || !raw.TryGetProperty("legacyImported", out var flag) || flag.ValueKind is not (JsonValueKind.True or JsonValueKind.False)
                || !raw.TryGetProperty("entries", out raw)) throw Refused();
            imported = flag.GetBoolean();
        }
        if (raw.ValueKind != JsonValueKind.Array) throw Refused();
        var entries = ImmutableArray.CreateBuilder<JsonElement>();
        Flatten(raw, 0);
        return new(entries.ToImmutable(), imported);
        void Flatten(JsonElement item, int depth)
        {
            if (depth > 128) throw Refused();
            if (item.ValueKind == JsonValueKind.Array)
            { foreach (var child in item.EnumerateArray()) Flatten(child, depth + 1); return; }
            // Null, scalars, malformed and foreign-domain records remain evidence, and count toward the bound.
            if (entries.Count == SearchMemoryRules.MaxWorkspaces) throw Refused();
            entries.Add(item.Clone());
        }
    }

    public JsonElement Encode()
    {
        if (Entries.Length > SearchMemoryRules.MaxWorkspaces) throw Refused();
        var value = JsonSerializer.SerializeToElement(new { version = 1, legacyImported = LegacyImported, entries = Entries });
        if (Encoding.UTF8.GetByteCount(value.GetRawText()) > SearchMemoryRules.MaxStoreBytes) throw Refused();
        return value;
    }

    public static JsonElement DecodeLegacy(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) > SearchMemoryRules.MaxStoreBytes) throw Refused();
        using var parsed = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 160 });
        // Flatten the old PowerShell array wrapping before persistence (the D2 profile remains depth-bounded).
        return JsonSerializer.SerializeToElement(Read(parsed.RootElement).Entries);
    }

    internal static DomeniaOperationException Refused() => new("search.workspaceRefused",
        "Bibliothèque de vues illisible ou trop volumineuse ; aucune entrée n’a été remplacée (100 entrées et 1 Mio au maximum).");
}

public static class LegacySearchWorkspaces
{
    // Names from D1 Domenia-Main.xaml DgObjects, mapped to real D2 columns; unknown keys remain in raw evidence.
    private static readonly IReadOnlyDictionary<string, string> Columns = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["Type"] = "kind", ["Name"] = "name", ["DisplayName"] = "display", ["SessionDisplay"] = "console",
        ["Login"] = "login", ["Upn"] = "upn", ["UPN"] = "upn", ["SessionState"] = "consoleState", ["DirectoryState"] = "freshness", ["Association"] = "association", ["Presence"] = "presence",
        ["State"] = "state", ["OS"] = "os", ["OperatingSystem"] = "os", ["LastLogonSort"] = "lastLogon",
        ["Mail"] = "mail", ["Description"] = "description", ["ChangedSort"] = "changed", ["CreatedSort"] = "created",
        ["Path"] = "container", ["DN"] = "dn", ["Dn"] = "dn", ["ObjectGuid"] = "guid",
    };

    public static SearchWorkspace? Read(JsonElement row, string root, string dns)
    {
        try
        {
            if (Property(row, "Version") is not { } version || !version.TryGetInt32(out var v) || v != 1
                || !DistinguishedName.AreEqual(Text(row, "DomainDn") ?? "", root)
                || !Guid.TryParse(Text(row, "Id"), out var id) || id == Guid.Empty) return null;
            var type = Text(row, "TypeLabel") switch
            { "Tous" => SearchTypeFilter.All, "Utilisateurs" => SearchTypeFilter.Users, "Machines" => SearchTypeFilter.Computers,
                "Groupes" => SearchTypeFilter.Groups, "OU et conteneurs" => SearchTypeFilter.Ous, _ => (SearchTypeFilter)(-1) };
            if (!Enum.IsDefined(type)) return null;
            var presence = Text(row, "Presence") switch
            { "Tous" => "all", "En ligne" => "online", "Sans réponse au ping" => "noReply", "Non vérifié" => "unknown", "Erreur de ping" => "error", _ => "" };
            if (Property(row, "Subtree") is not { ValueKind: JsonValueKind.True or JsonValueKind.False } depth
                || Property(row, "Limit") is not { } limit || !limit.TryGetInt32(out var max)) return null;
            var layout = Layout(row);
            var set = type == SearchTypeFilter.Computers ? "computers" : type == SearchTypeFilter.Users ? "users" : "mixed";
            var draft = new SearchWorkspaceDraft(Text(row, "Name") ?? "", Text(row, "OuDn") ?? "", depth.GetBoolean(), type,
                presence, Text(row, "LocalFilter") ?? "", max, set, layout);
            return SearchMemoryRules.Workspace(draft, root, dns, id.ToString("N"), DateTimeOffset.UnixEpoch).Workspace;
        }
        catch (Exception ex) when (ex is JsonException or FormatException or InvalidOperationException or ArgumentException or InvalidDataException)
        { return null; }
    }

    private static SearchLayout? Layout(JsonElement row)
    {
        var order = new List<(int Index, string Key)>();
        var widths = ImmutableDictionary.CreateBuilder<string, int>(StringComparer.Ordinal);
        if (Property(row, "Columns") is { } columns && columns.ValueKind != JsonValueKind.Null)
        {
            if (columns.ValueKind != JsonValueKind.Array || columns.GetArrayLength() > 100) throw new InvalidDataException();
            foreach (var col in columns.EnumerateArray())
            {
                var key = Text(col, "Key") ?? "";
                // No guessed equivalent or silently changed width/unit. Unsupported layouts stay retained but unavailable.
                if (!Columns.TryGetValue(key, out var mapped) || order.Any(c => c.Key == mapped)
                    || Property(col, "Index") is not { } index || !index.TryGetInt32(out var n) || n is < 0 or > 99
                    || order.Any(c => c.Index == n) || Text(col, "Unit") != "Pixel" || Property(col, "Width") is not { } width
                    || !width.TryGetDouble(out var w) || !double.IsFinite(w) || w is < 40 or > 1600 || w != Math.Truncate(w)) throw new InvalidDataException();
                order.Add((n, mapped)); widths.Add(mapped, (int)w);
            }
        }
        var sort = ImmutableArray.CreateBuilder<SearchSortKey>();
        if (Property(row, "Sort") is { } sorts && sorts.ValueKind != JsonValueKind.Null)
        {
            if (sorts.ValueKind != JsonValueKind.Array || sorts.GetArrayLength() > 4) throw new InvalidDataException();
            foreach (var item in sorts.EnumerateArray())
            {
                if (!Columns.TryGetValue(Text(item, "Field") ?? "", out var key) || sort.Any(s => s.Id == key)) throw new InvalidDataException();
                var direction = Text(item, "Direction") switch { "Ascending" => 1, "Descending" => -1, _ => 0 };
                if (direction == 0) throw new InvalidDataException();
                sort.Add(new(key, direction));
            }
        }
        return order.Count == 0 && sort.Count == 0 ? null : new([.. order.OrderBy(c => c.Index).Select(c => c.Key)], [], widths.ToImmutable(), sort.ToImmutable(), "normal");
    }

    internal static JsonElement? Property(JsonElement row, string key)
    {
        if (row.ValueKind != JsonValueKind.Object) throw new InvalidDataException();
        var fields = row.EnumerateObject().Where(p => p.Name.Equals(key, StringComparison.OrdinalIgnoreCase)).ToArray();
        if (fields.Length > 1) throw new InvalidDataException();
        return fields.Length == 0 ? null : fields[0].Value;
    }
    private static string? Text(JsonElement row, string key) => Property(row, key) is { } value ? value.GetString() : null;
}
