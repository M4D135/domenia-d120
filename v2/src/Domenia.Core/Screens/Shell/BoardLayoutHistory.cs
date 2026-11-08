using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domenia.Core.Accueil;

namespace Domenia.Core;

/// <summary>A stored presentation only. It grants no recipe/remote-read permission.</summary>
public sealed record BoardLayoutVersion(string Id, DateTimeOffset? SavedAt, string Sha256, ImmutableArray<FleetLayoutItem> Items);
public sealed record BoardLayoutState(bool Stored, ImmutableArray<FleetLayoutItem> Items, DateTimeOffset? SavedAt,
    ImmutableArray<BoardLayoutVersion> History, string ChoiceToken);

/// <summary>The three real boards share one bounded envelope: current choice plus five previous choices in the same preference value.</summary>
public static class BoardLayoutHistory
{
    public const int Version = 2;
    public const int MaxVersions = 5;
    public const int MaxBytes = 524_288;
    private static readonly JsonSerializerOptions Json = CreateJson();
    private sealed record Document(int Version, FleetLayoutItem[] Items, DateTimeOffset? SavedAt = null, BoardLayoutVersion[]? History = null);

    public static string ChoiceToken(JsonElement? value) => Hash(Encoding.UTF8.GetBytes(value is null ? "absent" : "choice:" + JsonSerializer.Serialize(value.Value)));
    private static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    private static string ItemsHash(IEnumerable<FleetLayoutItem> items) => Hash(JsonSerializer.SerializeToUtf8Bytes(items, Json));

    public static BoardLayoutState Read(JsonElement? value, ImmutableArray<FleetLayoutItem> defaults,
        Func<IReadOnlyList<FleetLayoutItem>, ImmutableArray<FleetLayoutItem>> normalize)
    {
        var token = ChoiceToken(value);
        if (value is null) return new(false, defaults, null, [], token);
        if (JsonSerializer.SerializeToUtf8Bytes(value.Value).Length > MaxBytes) throw new InvalidDataException("Disposition et historique trop volumineux ; document conservé.");
        QualifyFields(value.Value);
        var doc = value.Value.Deserialize<Document>(Json);
        if (doc is null || doc.Version is not (1 or Version) || doc.Items is null
            || doc.Version == 1 && (doc.History is not null || doc.SavedAt is not null)
            || doc.Version == Version && (doc.History is null || doc.SavedAt is null)
            || doc.History?.Length > MaxVersions)
            throw new InvalidDataException("Format de disposition ou d’historique inconnu ; document conservé.");
        var items = NormalizeComplete(doc.Items, normalize);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in doc.History ?? [])
        {
            if (entry is null || entry.Id is not { Length: 32 } || !entry.Id.All(char.IsAsciiHexDigit) || !ids.Add(entry.Id)
                || entry.Items.IsDefault || entry.Sha256 != ItemsHash(entry.Items))
                throw new InvalidDataException("Historique ambigu ou empreinte modifiée ; document conservé.");
            _ = NormalizeComplete(entry.Items, normalize);
        }
        return new(true, items, doc.SavedAt, [.. (doc.History ?? [])], token);
    }

    public static JsonElement Next(JsonElement? current, IReadOnlyList<FleetLayoutItem> next,
        ImmutableArray<FleetLayoutItem> defaults, Func<IReadOnlyList<FleetLayoutItem>, ImmutableArray<FleetLayoutItem>> normalize, DateTimeOffset now)
    {
        var before = Read(current, defaults, normalize);
        var clean = NormalizeComplete(next, normalize);
        if (before.Stored && before.Items.SequenceEqual(clean)) return current!.Value.Clone();
        var history = before.History;
        if (!before.Items.SequenceEqual(clean))
            history = [new(Guid.NewGuid().ToString("N"), before.SavedAt, ItemsHash(before.Items), before.Items), .. history.Take(MaxVersions - 1)];
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new Document(Version, [.. clean], now, [.. history]), Json);
        if (bytes.Length > MaxBytes) throw new InvalidDataException("Historique trop volumineux ; aucun choix remplacé.");
        using var doc = JsonDocument.Parse(bytes);
        return doc.RootElement.Clone();
    }

    public static JsonElement Restore(JsonElement? current, string id, string expectedChoiceToken,
        ImmutableArray<FleetLayoutItem> defaults, Func<IReadOnlyList<FleetLayoutItem>, ImmutableArray<FleetLayoutItem>> normalize, DateTimeOffset now)
    {
        RequireChoice(current, expectedChoiceToken);
        var state = Read(current, defaults, normalize);
        var selected = state.History.SingleOrDefault(h => h.Id == id)
            ?? throw new InvalidDataException("Cette version n’est plus conservée ; relisez les versions disponibles.");
        return Next(current, selected.Items, defaults, normalize, now);
    }

    public static void RequireChoice(JsonElement? current, string? expectedChoiceToken)
    {
        if (expectedChoiceToken is not null && ChoiceToken(current) != expectedChoiceToken)
            throw new InvalidDataException("La disposition a changé depuis son affichage. Le choix actuel est conservé ; relisez-le avant de modifier.");
    }

    private static ImmutableArray<FleetLayoutItem> NormalizeComplete(IReadOnlyList<FleetLayoutItem> items,
        Func<IReadOnlyList<FleetLayoutItem>, ImmutableArray<FleetLayoutItem>> normalize)
    {
        if (items.Count > 64 || items.Any(i => i is null || i.Key is not { Length: > 0 and <= 128 }
            || i.Id is { Length: > 64 } || i.Title is { Length: > 80 } || i.Group is { Length: > 80 }
            || i.Height is not (null or "S" or "M" or "L"))) throw new InvalidDataException("Au plus 64 cartes valides par version ; aucune troncature.");
        var clean = normalize(items);
        if (clean.Length != items.Count) throw new InvalidDataException("Une carte n’a plus de représentation dans ce tableau ; aucun remplacement partiel.");
        return clean;
    }

    private static void QualifyFields(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in value.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new InvalidDataException("Champ de disposition dupliqué ; original conservé.");
                QualifyFields(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array) foreach (var child in value.EnumerateArray()) QualifyFields(child);
    }

    private static JsonSerializerOptions CreateJson()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web) { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return options;
    }
}
