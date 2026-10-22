using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Domenia.Core;

/// <summary>
/// Rules of the interface preferences kept by the engine (docs/ops/shell.md § « Préférences de l’interface »). Closed list of
/// fields with bounded values; layouts and boards are maps of bounded JSON values; favourite OUs are DNs of the domain of the
/// session. Pure: no disk, no clock.
/// </summary>
public static class ShellInterfaceRules
{
    public const string InterfaceKey = "shell.interface";
    public const string LayoutsKey = "shell.layouts";
    public const string BoardsKey = "shell.boards";
    public const string FavouritesPrefix = "shell.ouFavourites.";

    public const int MaxLayouts = 200;
    public const int MaxLayoutBytes = 16_384;
    public const int MaxLayoutsBytes = 262_144;
    public const int MaxBoards = 16;
    public const int MaxBoardBytes = 65_536;
    public const int MaxFavourites = 20;
    public const int MaxRecent = 12;
    public const int MinNavWidth = 200;
    public const int MaxNavWidth = 360;

    private static readonly string[] Themes = ["light", "dark", "contrast", "system"];
    private static readonly string[] Motions = ["full", "reduced", "system"];
    private static readonly string[] Profiles = ["essentiel", "expert"];
    private static readonly string[] Densities = ["compact", "normal", "confortable"];
    private static readonly string[] Booleans = ["navCollapsed", "helpTips", "helpIntroSeen", "bannerCompact"];
    private static readonly string[] Lists = ["recentCommands", "recentPages", "pinnedCommands"];

    /// <summary>Empty JSON object (no stored value).</summary>
    public static JsonElement EmptyObject { get; } = JsonDocument.Parse("{}").RootElement.Clone();

    /// <summary>
    /// The stored choices with the changes applied: unknown fields and out-of-bounds values are dropped, a field set to null in
    /// the changes is removed. Never throws for a stored value of an unexpected shape (it counts as empty).
    /// </summary>
    public static JsonElement MergeInterface(JsonElement? stored, JsonElement? changes)
    {
        var result = new JsonObject();
        Apply(result, stored, removeOnNull: false);
        Apply(result, changes, removeOnNull: true);
        return JsonSerializer.SerializeToElement(result);
    }

    /// <summary>One field of the closed list, normalized; null when the value is not admitted.</summary>
    public static JsonNode? NormalizeField(string name, JsonElement value)
    {
        ArgumentNullException.ThrowIfNull(name);
        switch (name)
        {
            case "theme":
                return Choice(value, Themes);
            case "motion":
                return Choice(value, Motions);
            case "profile":
                return Choice(value, Profiles);
            case "density":
                return Choice(value, Densities);
            case "navWidth":
                return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var width) && width is >= MinNavWidth and <= MaxNavWidth
                    ? JsonValue.Create(width)
                    : null;
            default:
                if (Booleans.Contains(name, StringComparer.Ordinal))
                {
                    return value.ValueKind is JsonValueKind.True or JsonValueKind.False ? JsonValue.Create(value.GetBoolean()) : null;
                }
                if (Lists.Contains(name, StringComparer.Ordinal))
                {
                    return value.ValueKind == JsonValueKind.Array ? RecentList(value, name == "recentPages") : null;
                }
                return null;
        }
    }

    /// <summary>Keys of remembered layouts: letters, digits, « : . _ - », 100 characters at most, starting with a letter or digit.</summary>
    public static bool IsLayoutKey(string? key) =>
        !string.IsNullOrEmpty(key) && key.Length <= 100 && char.IsAsciiLetterOrDigit(key[0])
        && key.All(c => char.IsAsciiLetterOrDigit(c) || c is ':' or '.' or '_' or '-');

    /// <summary>Board names: one lower camel case word of 32 characters at most (« interface », « poste »).</summary>
    public static bool IsBoardKey(string? key) =>
        !string.IsNullOrEmpty(key) && key.Length <= 32 && char.IsAsciiLetterLower(key[0]) && key.All(char.IsAsciiLetterOrDigit);

    /// <summary>
    /// A map of bounded JSON values (layouts or boards) with the changes applied: a null value removes its key; an invalid key,
    /// a value too large, or a key beyond the count or total bounds is refused (counted in <paramref name="refused"/>), the
    /// stored entries are kept.
    /// </summary>
    public static JsonElement MergeMap(JsonElement? stored, JsonElement? changes, Func<string, bool> isKey, int maxEntries, int maxValueBytes, int maxTotalBytes, out int refused)
    {
        ArgumentNullException.ThrowIfNull(isKey);
        refused = 0;
        var map = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        if (stored is { ValueKind: JsonValueKind.Object } known)
        {
            foreach (var property in known.EnumerateObject())
            {
                if (isKey(property.Name) && property.Value.ValueKind != JsonValueKind.Null && Size(property.Value) <= maxValueBytes)
                {
                    map[property.Name] = property.Value.Clone();
                }
            }
        }
        if (changes is { ValueKind: JsonValueKind.Object } update)
        {
            foreach (var property in update.EnumerateObject())
            {
                if (!isKey(property.Name))
                {
                    refused++;
                    continue;
                }
                if (property.Value.ValueKind == JsonValueKind.Null)
                {
                    map.Remove(property.Name);
                    continue;
                }
                if (Size(property.Value) > maxValueBytes || (!map.ContainsKey(property.Name) && map.Count >= maxEntries))
                {
                    refused++;
                    continue;
                }
                var before = map.TryGetValue(property.Name, out var previous) ? previous : (JsonElement?)null;
                map[property.Name] = property.Value.Clone();
                if (map.Values.Sum(Size) > maxTotalBytes)
                {
                    // Over the total bound: the earlier value (or none) stays.
                    if (before is JsonElement keep)
                    {
                        map[property.Name] = keep;
                    }
                    else
                    {
                        map.Remove(property.Name);
                    }
                    refused++;
                }
            }
        }
        var node = new JsonObject();
        foreach (var (key, value) in map.OrderBy(p => p.Key, StringComparer.Ordinal))
        {
            node[key] = JsonNode.Parse(value.GetRawText());
        }
        return JsonSerializer.SerializeToElement(node);
    }

    /// <summary>
    /// Favourite OUs of a domain, in their order: well-formed DNs inside the domain (never the root itself), each once (case
    /// and escapes ignored), at most 20.
    /// </summary>
    public static ImmutableArray<string> NormalizeFavourites(IEnumerable<string?> dns, string rootDn)
    {
        ArgumentNullException.ThrowIfNull(dns);
        ArgumentException.ThrowIfNullOrEmpty(rootDn);
        var result = ImmutableArray.CreateBuilder<string>();
        foreach (var dn in dns)
        {
            if (string.IsNullOrWhiteSpace(dn) || dn.Length > 2048 || result.Count >= MaxFavourites)
            {
                continue;
            }
            try
            {
                _ = DistinguishedName.Parse(dn);
            }
            catch (FormatException)
            {
                continue;
            }
            if (DistinguishedName.AreEqual(dn, rootDn) || !DistinguishedName.IsWithin(dn, rootDn, subtree: true) || result.Any(f => DistinguishedName.AreEqual(f, dn)))
            {
                continue;
            }
            result.Add(dn);
        }
        return result.ToImmutable();
    }

    /// <summary>Preference key of the favourites of a domain: SHA-256 of its root DN in lower case (no name in the file).</summary>
    public static string FavouritesKey(string rootDn)
    {
        ArgumentException.ThrowIfNullOrEmpty(rootDn);
        return FavouritesPrefix + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(rootDn.Trim().ToLowerInvariant())));
    }

    private static void Apply(JsonObject target, JsonElement? source, bool removeOnNull)
    {
        if (source is not { ValueKind: JsonValueKind.Object } element)
        {
            return;
        }
        foreach (var property in element.EnumerateObject())
        {
            if (property.Value.ValueKind == JsonValueKind.Null)
            {
                if (removeOnNull)
                {
                    target.Remove(property.Name);
                }
                continue;
            }
            var normalized = NormalizeField(property.Name, property.Value);
            if (normalized is not null)
            {
                target[property.Name] = normalized;
            }
        }
    }

    private static JsonValue? Choice(JsonElement value, string[] allowed) =>
        value.ValueKind == JsonValueKind.String && allowed.Contains(value.GetString()!, StringComparer.Ordinal) ? JsonValue.Create(value.GetString()!) : null;

    private static JsonArray RecentList(JsonElement value, bool pages)
    {
        var list = new JsonArray();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in value.EnumerateArray())
        {
            if (list.Count >= MaxRecent || item.ValueKind != JsonValueKind.String)
            {
                continue;
            }
            var text = item.GetString()!;
            var valid = pages ? IsRecentPage(text) : IsCommandId(text);
            if (valid && seen.Add(text))
            {
                list.Add(text);
            }
        }
        return list;
    }

    /// <summary>Command identifiers of the palette: « page:accueil », « theme-dark », « unlock ».</summary>
    public static bool IsCommandId(string? id) =>
        !string.IsNullOrEmpty(id) && id.Length <= 64 && char.IsAsciiLetterLower(id[0])
        && id.All(c => char.IsAsciiLetterOrDigit(c) || c is ':' or '.' or '_' or '-');

    /// <summary>Addresses of recent screens: « #/fiche?dn=… », 300 characters at most, printable ASCII only (encoded query).</summary>
    public static bool IsRecentPage(string? hash)
    {
        if (string.IsNullOrEmpty(hash) || hash.Length > 300 || !hash.StartsWith("#/", StringComparison.Ordinal))
        {
            return false;
        }
        var query = hash.IndexOf('?', StringComparison.Ordinal);
        var route = query < 0 ? hash[2..] : hash[2..query];
        return route.Length is > 0 and <= 30
            && char.IsAsciiLetterLower(route[0])
            && route.All(c => char.IsAsciiLetterLower(c) || char.IsAsciiDigit(c) || c == '-')
            && hash.All(c => c > ' ' && c < '\u007f');
    }

    private static int Size(JsonElement value) => Encoding.UTF8.GetByteCount(value.GetRawText());
}

/// <summary>
/// Interface preferences of the engine (shell.interface.get / set), shared by the modules of the context. The values live in
/// the local preferences of the mode (LocalWrite: preferences.json or preferences-simulation.json, memory only in capture and
/// E2E). A write that fails never fails the operation: the change holds for the session and the operator is told.
/// </summary>
public sealed class ShellInterfaceStore : IDisposable
{
    private readonly IPreferenceStore preferences;
    private readonly OperationJournal journal;
    private readonly TimeProvider clock;
    private readonly ITechnicalJournal log;
    private readonly SemaphoreSlim gate = new(1, 1);

    public ShellInterfaceStore(IPreferenceStore preferences, OperationJournal journal, TimeProvider clock, ITechnicalJournal log)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        ArgumentNullException.ThrowIfNull(journal);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        this.preferences = preferences;
        this.journal = journal;
        this.clock = clock;
        this.log = log;
    }

    /// <summary>The store shared by every module of the context.</summary>
    public static ShellInterfaceStore From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new ShellInterfaceStore(c.Preferences, c.Journal, c.Clock, c.Log));
    }

    /// <summary>Current preferences; <paramref name="rootDn"/> selects the favourite OUs of the domain of the session (null: none).</summary>
    public async Task<ShellInterfaceSnapshot> GetAsync(string? rootDn, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return Snapshot(rootDn, null);
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// Applies the changes of each section given (null: section untouched) and writes the changed keys. Returns the preferences
    /// as they now hold, with a warning when a value was refused or could not be written.
    /// </summary>
    public async Task<ShellInterfaceSnapshot> SetAsync(
        string? rootDn,
        JsonElement? interfaceChanges,
        JsonElement? layoutChanges,
        JsonElement? boardChanges,
        IReadOnlyList<string?>? favourites,
        CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var warnings = new List<string>();
            var refused = 0;
            if (interfaceChanges is JsonElement changes)
            {
                var merged = ShellInterfaceRules.MergeInterface(Read(ShellInterfaceRules.InterfaceKey), changes);
                await WriteAsync(ShellInterfaceRules.InterfaceKey, merged, warnings, cancellationToken).ConfigureAwait(false);
            }
            if (layoutChanges is JsonElement layouts)
            {
                var merged = ShellInterfaceRules.MergeMap(Read(ShellInterfaceRules.LayoutsKey), layouts, ShellInterfaceRules.IsLayoutKey,
                    ShellInterfaceRules.MaxLayouts, ShellInterfaceRules.MaxLayoutBytes, ShellInterfaceRules.MaxLayoutsBytes, out var count);
                refused += count;
                await WriteAsync(ShellInterfaceRules.LayoutsKey, merged, warnings, cancellationToken).ConfigureAwait(false);
            }
            if (boardChanges is JsonElement boards)
            {
                var merged = ShellInterfaceRules.MergeMap(Read(ShellInterfaceRules.BoardsKey), boards, ShellInterfaceRules.IsBoardKey,
                    ShellInterfaceRules.MaxBoards, ShellInterfaceRules.MaxBoardBytes, ShellInterfaceRules.MaxBoardBytes * ShellInterfaceRules.MaxBoards, out var count);
                refused += count;
                await WriteAsync(ShellInterfaceRules.BoardsKey, merged, warnings, cancellationToken).ConfigureAwait(false);
            }
            if (favourites is not null)
            {
                if (string.IsNullOrEmpty(rootDn))
                {
                    warnings.Add("Favoris non enregistrés" + FrenchText.Colon + "domaine de la session inconnu.");
                }
                else
                {
                    var list = ShellInterfaceRules.NormalizeFavourites(favourites, rootDn);
                    refused += favourites.Count - list.Length;
                    await WriteAsync(ShellInterfaceRules.FavouritesKey(rootDn), JsonSerializer.SerializeToElement(list), warnings, cancellationToken).ConfigureAwait(false);
                }
            }
            if (refused > 0)
            {
                // Counts only: a refused key or value is never written to the journal.
                log.Warning($"Préférences de l’interface : {refused.ToString(System.Globalization.CultureInfo.InvariantCulture)} valeur(s) refusée(s).");
                warnings.Add(FrenchText.Count(refused, "valeur refusée", "valeurs refusées") + FrenchText.Colon + "hors des bornes admises, rien n’a été enregistré pour elles.");
            }
            return Snapshot(rootDn, warnings.Count == 0 ? null : string.Join(" ", warnings));
        }
        finally
        {
            gate.Release();
        }
    }

    private ShellInterfaceSnapshot Snapshot(string? rootDn, string? warning)
    {
        var iface = ShellInterfaceRules.MergeInterface(Read(ShellInterfaceRules.InterfaceKey), null);
        var layouts = ShellInterfaceRules.MergeMap(Read(ShellInterfaceRules.LayoutsKey), null, ShellInterfaceRules.IsLayoutKey,
            ShellInterfaceRules.MaxLayouts, ShellInterfaceRules.MaxLayoutBytes, ShellInterfaceRules.MaxLayoutsBytes, out _);
        var boards = ShellInterfaceRules.MergeMap(Read(ShellInterfaceRules.BoardsKey), null, ShellInterfaceRules.IsBoardKey,
            ShellInterfaceRules.MaxBoards, ShellInterfaceRules.MaxBoardBytes, ShellInterfaceRules.MaxBoardBytes * ShellInterfaceRules.MaxBoards, out _);
        var favourites = ImmutableArray<string>.Empty;
        if (!string.IsNullOrEmpty(rootDn) && Read(ShellInterfaceRules.FavouritesKey(rootDn)) is { ValueKind: JsonValueKind.Array } list)
        {
            favourites = ShellInterfaceRules.NormalizeFavourites(list.EnumerateArray().Select(e => e.ValueKind == JsonValueKind.String ? e.GetString() : null), rootDn);
        }
        return new ShellInterfaceSnapshot(preferences.Persistent, iface, layouts, boards, favourites, warning);
    }

    private JsonElement? Read(string key) => preferences.TryGet(key, out var value) ? value : null;

    public void Dispose() => gate.Dispose();

    private async Task WriteAsync(string key, JsonElement value, List<string> warnings, CancellationToken cancellationToken)
    {
        if (preferences.TryGet(key, out var current) && string.Equals(current.GetRawText(), value.GetRawText(), StringComparison.Ordinal))
        {
            return;
        }
        try
        {
            await preferences.SetAsync(key, value, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // The choice stays for the session; the operator is told it will not survive a restart.
            log.Warning($"Préférences non enregistrées (interface) : {ex.GetType().Name}.");
            if (!warnings.Any(w => w.StartsWith("Préférences non enregistrées", StringComparison.Ordinal)))
            {
                journal.Add(new JournalEntry(clock.GetUtcNow(), "Préférences non enregistrées" + FrenchText.Colon + "les réglages de l’interface valent pour cette session", Tone.Warn));
                warnings.Add("Préférences non enregistrées" + FrenchText.Colon + "les réglages de l’interface valent pour cette session.");
            }
        }
    }
}
