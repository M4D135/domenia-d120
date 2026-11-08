using System.Collections.Immutable;
using System.Text.Json;

namespace Domenia.Core;

public sealed record ConfigurationSnapshot(bool Exists, string Fingerprint, ImmutableDictionary<string, JsonElement> Values);
public sealed record ConfigurationDecision(string Id, string Build, string SourceSha256, string Choice);
public sealed record ConfigurationCommit(PortableConfigurationDocument? Document, string ExpectedFingerprint, DateTimeOffset At,
    ConfigurationDecision? Decision = null, bool OnlyIfAbsent = false);
public sealed record ConfigurationApplied(bool Applied, string? Backup, string? BackupSha256, string Summary, string? InterfaceId, JsonElement? Interface);

/// <summary>One bounded preferences document, strict read and whole commit; a source lease is acquired only after its mutex.</summary>
public interface IConfigurationPreferenceStore : IPreferenceStore
{
    Task<ConfigurationSnapshot> ReadConfigurationAsync(CancellationToken token);
    Task<ConfigurationApplied> CommitConfigurationAsync(ConfigurationCommit request, CancellationToken token, Func<CancellationToken, IDisposable>? qualifySource = null);
}

public static class ConfigurationChanges
{
    public const string DecisionsKey = "settings.configurationDecisions";
    public const string InterfaceKey = "settings.configurationInterface";
    public const int MaxDecisions = 128;
    public static string DecisionId(string build, string sha) => PortableConfiguration.Hash(build + "\n" + sha);
    public static bool Decided(IReadOnlyDictionary<string, JsonElement> values, string id) => Decisions(values).Any(row => row.GetProperty("id").GetString() == id);

    public static ImmutableArray<JsonElement> Decisions(IReadOnlyDictionary<string, JsonElement> values)
    {
        if (!values.TryGetValue(DecisionsKey, out var value)) return [];
        if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > MaxDecisions) throw new InvalidDataException("Historique de configuration incompatible ; original conservé.");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in value.EnumerateArray())
            if (!ConfigurationDecisionRules.Valid(row) || !ids.Add(row.GetProperty("id").GetString()!))
                throw new InvalidDataException("Historique de configuration ambigu ; original conservé.");
        return [.. value.EnumerateArray().Select(v => v.Clone())];
    }

    /// <summary>Targeted patch: unrelated and future preference keys are kept byte-for-byte as JSON values.</summary>
    public static (Dictionary<string, JsonElement> Values, ConfigurationApplied Result) Apply(ConfigurationSnapshot current, ConfigurationCommit request, string? backup, string? backupSha)
    {
        if (current.Fingerprint != request.ExpectedFingerprint || request.OnlyIfAbsent && current.Exists)
            throw new InvalidDataException("Configuration modifiée depuis l’aperçu ; aucun remplacement. Relisez l’aperçu.");
        var values = current.Values.ToDictionary(p => p.Key, p => p.Value, StringComparer.Ordinal);
        var document = request.Document is { } given ? PortableConfiguration.Read(given.Text) : null;
        if (request.Decision is { } decision)
        {
            if (decision.SourceSha256.Length != 64 || !decision.SourceSha256.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f') || decision.Build.Length is < 1 or > 200 || decision.Build.Any(char.IsControl)
                || decision.Id != DecisionId(decision.Build, decision.SourceSha256) || decision.Choice is not ("applied" or "declined")
                || (document is null) != (decision.Choice == "declined")) throw new InvalidDataException("Décision de configuration invalide.");
            var decisions = Decisions(values);
            if (Decided(values, decision.Id)) throw new InvalidDataException("Cette configuration de cette version a déjà reçu une décision.");
            if (decisions.Length >= MaxDecisions) throw new InvalidDataException("Historique de configuration plein ; aucune décision antérieure effacée.");
            values[DecisionsKey] = JsonSerializer.SerializeToElement(decisions.Add(JsonSerializer.SerializeToElement(new
            { id = decision.Id, build = decision.Build, sourceSha256 = decision.SourceSha256, choice = decision.Choice, at = request.At, backup, backupSha256 = backupSha })));
        }
        string? interfaceId = null;
        if (document is not null)
        {
            foreach (var pair in document.Values) values[pair.Key] = pair.Value.Clone();
            if (document.Interface is { } ui)
            {
                // Merge only known supplied fields. Unknown future shell fields remain untouched.
                var merged = values.TryGetValue(ShellInterfaceRules.InterfaceKey, out var old) ? old.ValueKind == JsonValueKind.Object
                    ? old.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone(), StringComparer.Ordinal)
                    : throw new InvalidDataException("Interface existante illisible ; original conservé.") : new Dictionary<string, JsonElement>(StringComparer.Ordinal);
                foreach (var property in ui.EnumerateObject().Where(p => p.Name is not ("logWrap" or "logSize"))) merged[property.Name] = property.Value.Clone();
                values[ShellInterfaceRules.InterfaceKey] = JsonSerializer.SerializeToElement(merged);
                interfaceId = Guid.NewGuid().ToString("N");
                values[InterfaceKey] = JsonSerializer.SerializeToElement(new { id = interfaceId, values = ui });
            }
        }
        return (values, new(document is not null, backup, backupSha, document is null ? "Configuration proposée refusée pour cette version et cette empreinte. Vos choix restent inchangés."
            : "Configuration enregistrée atomiquement. Les réglages métier seront pris en compte au prochain démarrage ; aucune lecture réseau lancée.", interfaceId, document?.Interface));
    }

    public static ConfigurationSnapshot MemorySnapshot(IReadOnlyDictionary<string, JsonElement> values) => new(values.Count != 0,
        PortableConfiguration.Hash(JsonSerializer.Serialize(values.OrderBy(p => p.Key, StringComparer.Ordinal).ToDictionary(p => p.Key, p => p.Value))), values.ToImmutableDictionary(StringComparer.Ordinal));
}
