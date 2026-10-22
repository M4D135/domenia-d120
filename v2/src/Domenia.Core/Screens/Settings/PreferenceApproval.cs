using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// The « approved preferences » of Domenia 2 (Domenia 1 Get-DomeniaBackupPreferencesJson, PreferenceTransfer): a closed list of
/// keys, each with its owner screen and a mandatory validator. Only these keys are exported, imported, joined to a backup
/// and re-applied by a restore; any other key (a key of a newer version, a typing error, a key of another screen without a
/// validator) is refused by name. Some keys are of this workstation only and never leave it: the connection identity and
/// the geometry of the window. Pure.
/// </summary>
public static class PreferenceApproval
{
    /// <summary>Zoom of the interface (PAR-009), in percent: 80 to 150.</summary>
    public const string ZoomKey = "settings.zoom";

    /// <summary>Size, position and state of the main window of this workstation (PAR-051): never exported.</summary>
    public const string WindowKey = "settings.window";

    public const int ZoomMinimum = 80;
    public const int ZoomMaximum = 150;

    /// <summary>Keys of this workstation only: never exported, imported, joined to a backup nor re-applied.</summary>
    public static ImmutableArray<string> LocalOnly { get; } = [SettingsViewRules.ConnectionKey, WindowKey];

    /// <summary>The approved keys (exact names, or prefixes ending with a dot), with their owner, in plain words.</summary>
    public static ImmutableArray<(string Key, string Label)> Approved { get; } =
    [
        (DashboardService.DisabledWidgetsPreference, "Widgets désactivés de l’Accueil"),
        (WorkingScope.PreferencePrefix, "OU de travail de chaque domaine"),
        (CollectionSettingsRules.PreferenceKey, "Profil, durées, fenêtre et budgets de collecte"),
        (StoragePolicyRules.PreferenceKey, "Conservation et sauvegarde automatique"),
        (ZoomKey, "Zoom de l’interface"),
    ];

    /// <summary>True for a key of this workstation only (connection identity, window).</summary>
    public static bool IsLocalOnly(string key)
    {
        ArgumentNullException.ThrowIfNull(key);
        return LocalOnly.Any(k => key == k || key.StartsWith(k + ".", StringComparison.Ordinal));
    }

    /// <summary>True for a key of the closed list (whatever its value).</summary>
    public static bool IsApproved(string key)
    {
        ArgumentNullException.ThrowIfNull(key);
        if (!PreferenceKeys.IsValid(key) || IsLocalOnly(key))
        {
            return false;
        }
        if (key.StartsWith(WorkingScope.PreferencePrefix, StringComparison.Ordinal))
        {
            var hash = key[WorkingScope.PreferencePrefix.Length..];
            return hash.Length == 64 && hash.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
        }
        return Approved.Any(a => !a.Key.EndsWith('.') && a.Key == key);
    }

    /// <summary>
    /// Why a value cannot be taken for a key (null when it can): local key, unknown key, or a value its owner would refuse.
    /// Every approved key has a validator; nothing is accepted on its name alone.
    /// </summary>
    public static string? Problem(string key, JsonElement value)
    {
        ArgumentNullException.ThrowIfNull(key);
        if (!PreferenceKeys.IsValid(key))
        {
            return "nom de clé invalide.";
        }
        if (IsLocalOnly(key))
        {
            return key == WindowKey ? "fenêtre de ce poste, jamais importée." : "identité de connexion, jamais importée.";
        }
        if (!IsApproved(key))
        {
            return "clé inconnue de cette version de Domenia" + FrenchText.Colon + "non importée.";
        }
        switch (key)
        {
            case DashboardService.DisabledWidgetsPreference:
                if (value.ValueKind != JsonValueKind.Array)
                {
                    return "liste de widgets attendue.";
                }
                foreach (var item in value.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.String || !WidgetCatalog.All.Any(w => w.Id == item.GetString()))
                    {
                        return "widget inconnu dans la liste.";
                    }
                }
                return null;
            case CollectionSettingsRules.PreferenceKey:
                var warnings = new List<string>();
                _ = CollectionSettingsRules.Read(value, warnings);
                return warnings.Count > 0 ? "réglages de collecte illisibles (" + warnings[0].TrimEnd('.') + ")." : null;
            case StoragePolicyRules.PreferenceKey:
                _ = StoragePolicyRules.Read(value, out var unreadable);
                return unreadable ? "politique de conservation illisible ou hors limites." : null;
            case ZoomKey:
                return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var zoom) && zoom is >= ZoomMinimum and <= ZoomMaximum
                    ? null
                    : "zoom de 80 à 150" + FrenchText.Nbsp + "% attendu.";
        }
        // Working OU of a domain: the DN is checked again against the local index when it is restored (WorkingScope).
        if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty("dn", out var dn) || dn.ValueKind != JsonValueKind.String)
        {
            return "OU de travail illisible.";
        }
        try
        {
            _ = DistinguishedName.Parse(dn.GetString()!);
        }
        catch (FormatException)
        {
            return "OU de travail illisible.";
        }
        return value.TryGetProperty("subtree", out var subtree) && subtree.ValueKind is not (JsonValueKind.True or JsonValueKind.False)
            ? "OU de travail illisible."
            : null;
    }

    /// <summary>The approved and valid values of a document, in key order.</summary>
    public static ImmutableArray<(string Key, JsonElement Value)> Filter(IReadOnlyDictionary<string, JsonElement> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        return [.. values.Where(v => Problem(v.Key, v.Value) is null).OrderBy(v => v.Key, StringComparer.Ordinal).Select(v => (v.Key, v.Value))];
    }
}

/// <summary>
/// The annex of the preferences joined to a backup (Domenia 1 PAR-034, Domenia.BackupPreferences.1): the approved values of
/// the moment as a canonical JSON object, bound to the SHA-256 of the copy once it is produced. A restore re-applies it
/// only after the switch to the restored base is verified, and only its approved values (the workstation keeps its own
/// connection identity and window). Pure.
/// </summary>
public static class BackupPreferencesRules
{
    public const string Format = "Domenia.BackupPreferences.1";

    /// <summary>Largest annex accepted (Domenia 1: 4 MB for every preference; Domenia 2 joins the approved keys only).</summary>
    public const int MaxBytes = 262_144;

    /// <summary>Canonical JSON object of the approved values of a document (sorted keys, compact): what a backup joins.</summary>
    public static string Snapshot(IReadOnlyDictionary<string, JsonElement> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        return Canonical(PreferenceApproval.Filter(values));
    }

    private static string Canonical(IEnumerable<(string Key, JsonElement Value)> values)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            writer.WriteStartObject();
            foreach (var (key, value) in values.OrderBy(v => v.Key, StringComparer.Ordinal))
            {
                writer.WritePropertyName(key);
                value.WriteTo(writer);
            }
            writer.WriteEndObject();
        }
        var text = Encoding.UTF8.GetString(buffer.ToArray());
        return Encoding.UTF8.GetByteCount(text) > MaxBytes
            ? throw new DomeniaOperationException(StorageWritePlans.StoreUnavailable, "Préférences trop volumineuses pour une sauvegarde complète" + FrenchText.Colon + "aucune sauvegarde préparée.")
            : text;
    }

    /// <summary>Approved values of an annex document (an unreadable document gives none).</summary>
    public static ImmutableArray<(string Key, JsonElement Value)> Values(string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        if (Encoding.UTF8.GetByteCount(json) > MaxBytes)
        {
            return [];
        }
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = PreferenceTransfer.MaxDepth + 4 });
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return [];
            }
            var values = document.RootElement.EnumerateObject().GroupBy(p => p.Name, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.First().Value.Clone(), StringComparer.Ordinal);
            return PreferenceApproval.Filter(values);
        }
        catch (JsonException)
        {
            return [];
        }
    }

    /// <summary>Number of approved values of an annex document.</summary>
    public static int Count(string json) => Values(json).Length;

    /// <summary>Lowercase SHA-256 of a text.</summary>
    public static string Sha256(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    }

    /// <summary>The annex of a copy, bound to the SHA-256 of that copy (written once the copy is verified).</summary>
    public static BackupPreferences Bind(string json, string databaseSha256, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(json);
        ArgumentNullException.ThrowIfNull(databaseSha256);
        var canonical = Canonical(Values(json));
        return new BackupPreferences(Format, databaseSha256, WritePlans.TruncateToSecond(at), Count(canonical), Sha256(canonical), canonical);
    }

    /// <summary>True when the annex of a backup exists, has the expected format, is intact and is bound to this very copy.</summary>
    public static bool IsBound(LocalStoreBackup backup)
    {
        ArgumentNullException.ThrowIfNull(backup);
        return backup.Preferences is BackupPreferences annex
            && annex.Format == Format
            && string.Equals(annex.DatabaseSha256, backup.Sha256, StringComparison.Ordinal)
            && string.Equals(annex.Sha256, Sha256(annex.Json), StringComparison.Ordinal);
    }

    /// <summary>« annexe Domenia.BackupPreferences.1 · 3 clés approuvées (…) » for a plan or a list.</summary>
    public static string Describe(int keys) =>
        "annexe " + Format + " · " + (keys > 0 ? FrenchText.Count(keys, "clé approuvée", "clés approuvées") : "aucune clé approuvée pour l’instant")
        + ", sans identité de connexion ni fenêtre de ce poste, liée au SHA-256 de la copie";
}
