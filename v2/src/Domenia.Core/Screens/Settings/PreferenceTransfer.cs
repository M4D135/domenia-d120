using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>Keys of one owner screen in the preferences document.</summary>
public sealed record PreferenceOwner(string Id, string Label, int Keys, long Bytes, ImmutableArray<string> Names);

/// <summary>Result of settings.preferences: the document of the mode, its keys by owner, and the reset groups.</summary>
public sealed record PreferencesView(
    bool Persistent,
    string FileLabel,
    string? Path,
    bool Exists,
    long Bytes,
    DateTimeOffset? ModifiedAt,
    bool Readable,
    string State,
    ImmutableArray<PreferenceOwner> Owners,
    int Keys,
    ImmutableArray<PreferenceResetGroup> ResetGroups,
    ImmutableArray<string> Rules);

/// <summary>A reset group offered by the page (PAR-050 improvement: reset by group).</summary>
public sealed record PreferenceResetGroup(string Id, string Label, string Detail, bool Engine);

/// <summary>Export of the preferences (text to copy): approved keys only, no identity, no secret.</summary>
public sealed record PreferenceExport(string Text, int Keys, long Bytes, ImmutableArray<string> Excluded);

/// <summary>One change an import would make.</summary>
public sealed record PreferenceChange(string Key, string Owner, string Kind, string? Before, string After);

/// <summary>Result of settings.preferences.import.preview: what the import would change, what it refuses, and its fingerprint.</summary>
public sealed record PreferenceImportPreview(bool Valid, string? Problem, DateTimeOffset? ExportedAt, string? Mode, ImmutableArray<PreferenceChange> Changes, ImmutableArray<string> Refused, int Unchanged, bool HasInterface, string Fingerprint);

/// <summary>Result of settings.preferences.import and settings.preferences.reset.</summary>
public sealed record PreferenceApplyResult(int Changed, ImmutableArray<string> Keys, ImmutableArray<string> Failed, string Summary);

/// <summary>
/// Export and import of the preferences (improvement of PAR-050, Domenia 1 Domenia.BackupPreferences.1): a JSON document of
/// the approved keys only (<see cref="PreferenceApproval"/>: closed list, a validator per key), never the connection identity,
/// the window of this workstation nor a secret, bounded (1 MiB, 8 levels, 64 KiB per value). An import is previewed first and
/// applied only with the fingerprint of its preview (the current values included), so a preview made on other values is
/// refused; an unknown key is refused by name, never written. Pure.
/// </summary>
public static class PreferenceTransfer
{
    public const string Format = "domenia.preferencesExport";
    public const int Version = 1;
    public const int MaxBytes = 1_048_576;
    public const int MaxValueBytes = 65_536;
    public const int MaxDepth = 8;
    public const int MaxKeys = 512;

    /// <summary>Reset groups of the page: interface (web profile), widgets, working OU, collection, storage, connection, all.</summary>
    public static ImmutableArray<PreferenceResetGroup> ResetGroups { get; } =
    [
        new("interface", "Interface", "Thème, animations, menu, densité, profil et infobulles d’aide, zoom à 100" + FrenchText.Nbsp + "%, lecture du journal.", false),
        new("widgets", "Widgets de l’Accueil", "Toutes les mesures de l’Accueil redeviennent actives.", true),
        new("workingScope", "OU de travail", "L’OU de travail revient à celle par défaut de la session.", true),
        new("collection", "Collecte et budgets", "Profil Standard, durées du profil, fenêtre du profil, budgets par défaut.", true),
        new("storage", "Conservation et sauvegardes", "Politique de conservation et sauvegarde automatique par défaut (rien n’est supprimé).", true),
        new("connection", "Connexion", "« Se souvenir de mon identifiant » décoché, identifiant et compte du coffre oubliés (jamais de mot de passe).", true),
        new("all", "Tout", "Tous les groupes ci-dessus et la fenêtre mémorisée ; les reçus d’écriture et le journal ne sont jamais touchés.", true),
    ];

    /// <summary>Label of the screen that owns a key (its first segment).</summary>
    public static string OwnerLabel(string owner) => owner switch
    {
        "dashboard" => "Accueil",
        "session" => "Session et OU de travail",
        "settings" => "Paramètres",
        "search" => "Rechercher",
        "fiche" or "object" => "Fiche",
        "accounts" => "Comptes",
        "relations" => "Utilisateurs et postes",
        "computer" or "workstation" => "Poste",
        "assistance" or "support" => "Assistance",
        "queries" or "requetes" => "Atelier de requêtes",
        "audit" => "Audit AD",
        "schema" => "Schéma",
        "sync" or "synchro" => "Synchronisation",
        "operations" or "write" => "Opérations",
        _ => owner,
    };

    /// <summary>True for a key that may be exported and imported (approved list, never a key of this workstation only).</summary>
    public static bool IsTransferable(string key) => PreferenceApproval.IsApproved(key);

    /// <summary>Keys grouped by owner screen, from the values of a document.</summary>
    public static ImmutableArray<PreferenceOwner> Owners(IReadOnlyDictionary<string, JsonElement> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        return
        [
            .. values.Where(v => PreferenceKeys.IsValid(v.Key))
                .GroupBy(v => v.Key.Split('.')[0], StringComparer.Ordinal)
                .OrderBy(g => g.Key, StringComparer.Ordinal)
                .Select(g => new PreferenceOwner(g.Key, OwnerLabel(g.Key), g.Count(), g.Sum(v => (long)Encoding.UTF8.GetByteCount(v.Value.GetRawText())),
                    [.. g.Select(v => v.Key).Order(StringComparer.Ordinal)])),
        ];
    }

    /// <summary>The export document of the transferable values (sorted keys, indented).</summary>
    public static PreferenceExport Export(IReadOnlyDictionary<string, JsonElement> values, string mode, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(values);
        ArgumentNullException.ThrowIfNull(mode);
        var excluded = values.Where(v => PreferenceApproval.Problem(v.Key, v.Value) is not null).Select(v => v.Key).Order(StringComparer.Ordinal).ToImmutableArray();
        var kept = PreferenceApproval.Filter(values).ToList();
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            writer.WriteStartObject();
            writer.WriteString("format", Format);
            writer.WriteNumber("version", Version);
            writer.WriteString("exportedAt", WritePlans.TruncateToSecond(now).UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture));
            writer.WriteString("mode", mode);
            writer.WriteStartObject("values");
            foreach (var (key, value) in kept)
            {
                writer.WritePropertyName(key);
                value.WriteTo(writer);
            }
            writer.WriteEndObject();
            writer.WriteEndObject();
        }
        var text = Encoding.UTF8.GetString(buffer.ToArray());
        return new PreferenceExport(text, kept.Count, buffer.Length, excluded);
    }

    private static int Depth(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Object => 1 + (element.EnumerateObject().Select(p => Depth(p.Value)).DefaultIfEmpty(0).Max()),
        JsonValueKind.Array => 1 + (element.EnumerateArray().Select(Depth).DefaultIfEmpty(0).Max()),
        _ => 0,
    };

    private static string Short(JsonElement value)
    {
        var raw = value.GetRawText();
        return raw.Length <= 120 ? raw : raw[..117] + "…";
    }

    /// <summary>
    /// Preview of an import against the current values (<paramref name="current"/>: key → value, absent when not set). Each key
    /// goes through <see cref="PreferenceApproval.Problem"/>: local or unknown keys and invalid values are refused by name.
    /// </summary>
    public static PreferenceImportPreview Preview(string? text, Func<string, JsonElement?> current)
    {
        ArgumentNullException.ThrowIfNull(current);
        static PreferenceImportPreview Invalid(string problem) => new(false, problem, null, null, [], [], 0, false, "");
        if (string.IsNullOrWhiteSpace(text))
        {
            return Invalid("Collez le texte d’un export de préférences de Domenia.");
        }
        if (Encoding.UTF8.GetByteCount(text) > MaxBytes)
        {
            return Invalid("Texte de plus de 1 Mo" + FrenchText.Colon + "import refusé.");
        }
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = MaxDepth + 4, CommentHandling = JsonCommentHandling.Disallow });
        }
        catch (JsonException)
        {
            return Invalid("Texte illisible" + FrenchText.Colon + "ce n’est pas un export JSON de Domenia.");
        }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("format", out var format) || format.ValueKind != JsonValueKind.String || format.GetString() != Format)
            {
                return Invalid("Format inconnu" + FrenchText.Colon + "« " + Format + " » attendu.");
            }
            if (!root.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var v) || v != Version)
            {
                return Invalid("Version d’export non prise en charge par cette version de Domenia.");
            }
            DateTimeOffset? exportedAt = root.TryGetProperty("exportedAt", out var at) && at.ValueKind == JsonValueKind.String
                && DateTimeOffset.TryParse(at.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed) ? parsed : null;
            var mode = root.TryGetProperty("mode", out var m) && m.ValueKind == JsonValueKind.String ? m.GetString() : null;
            var hasInterface = root.TryGetProperty("interface", out var ui) && ui.ValueKind == JsonValueKind.Object;
            if (!root.TryGetProperty("values", out var values) || values.ValueKind != JsonValueKind.Object)
            {
                return Invalid("Export sans valeurs.");
            }
            var changes = new List<PreferenceChange>();
            var refused = new List<string>();
            var unchanged = 0;
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var canonical = new StringBuilder();
            foreach (var property in values.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
            {
                var key = property.Name;
                if (!seen.Add(key))
                {
                    refused.Add(key + FrenchText.Colon + "clé en double.");
                    continue;
                }
                if (seen.Count > MaxKeys)
                {
                    refused.Add("Plus de " + FrenchText.Integer(MaxKeys) + " clés" + FrenchText.Colon + "les suivantes sont ignorées.");
                    break;
                }
                if (Encoding.UTF8.GetByteCount(property.Value.GetRawText()) > MaxValueBytes || Depth(property.Value) > MaxDepth)
                {
                    refused.Add(key + FrenchText.Colon + "valeur trop volumineuse ou trop imbriquée.");
                    continue;
                }
                if (PreferenceApproval.Problem(key, property.Value) is string problem)
                {
                    refused.Add(key + FrenchText.Colon + problem);
                    continue;
                }
                var before = current(key);
                var after = property.Value.GetRawText();
                canonical.Append(key).Append('=').Append(after).Append('|').Append(before?.GetRawText() ?? "∅").Append('\n');
                if (before is JsonElement b && JsonElement.DeepEquals(b, property.Value))
                {
                    unchanged++;
                    continue;
                }
                changes.Add(new PreferenceChange(key, OwnerLabel(key.Split('.')[0]), before is null ? "add" : "replace", before is JsonElement old ? Short(old) : null, Short(property.Value)));
            }
            var fingerprint = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical.ToString())));
            return new PreferenceImportPreview(true, null, exportedAt, mode, [.. changes], [.. refused], unchanged, hasInterface, fingerprint);
        }
    }

    /// <summary>Values of an export text that the preview admitted (key → value), in key order; empty for an invalid text.</summary>
    public static ImmutableArray<(string Key, JsonElement Value)> Values(string text, IReadOnlyCollection<string> keys)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(keys);
        using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = MaxDepth + 4 });
        if (!document.RootElement.TryGetProperty("values", out var values) || values.ValueKind != JsonValueKind.Object)
        {
            return [];
        }
        return [.. values.EnumerateObject().Where(p => keys.Contains(p.Name)).OrderBy(p => p.Name, StringComparer.Ordinal).Select(p => (p.Name, p.Value.Clone()))];
    }
}
