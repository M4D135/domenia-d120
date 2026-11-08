using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Core.Accueil;

/// <summary>A catalog key and the exact declaration it names. A personal key includes the canonical declaration hash.</summary>
public sealed record FrozenProbe(string Key, ProbeDefinition Definition)
{
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<FrozenProbe, ProbeDefinition> Runtime = new();
    [System.Text.Json.Serialization.JsonIgnore]
    public ProbeDefinition RuntimeDefinition => Key == Definition.Id ? Definition
        : Runtime.GetValue(this, static frozen => frozen.Definition with { Id = frozen.Key });
}

public sealed record PersonalProbeSnapshot(ImmutableArray<FrozenProbe> Entries, string ChoiceToken)
{
    public FrozenProbe? Find(string? key) => key is null ? null : ProbeCatalog.Find(key) is { } builtin
        ? new(key, builtin) : Entries.FirstOrDefault(entry => entry.Key == key);

    public ImmutableArray<FrozenProbe> Resolve(IEnumerable<string> keys) => [.. keys.Select(key => Find(key)
        ?? throw new DomeniaOperationException("probes.changed", "Définition de sonde absente de ce profil : importez sa version exacte ou retirez le widget. Aucune collecte."))];
}

/// <summary>Pure profile catalog codec. Import adds immutable versions; it never deletes a definition used by a widget or checkpoint.</summary>
public static class PersonalProbeCatalog
{
    public const string PreferenceKey = "accueil.personalProbes";
    public const int Capacity = 64;
    public const int MaximumBytes = 262_144;
    public const string Format = "Domenia.PersonalProbeCatalog/1";

    public static bool IsKey(string? key) => key is { Length: 71 } && key.StartsWith("custom.", StringComparison.Ordinal)
        && key.AsSpan(7).ToArray().All(c => char.IsAsciiDigit(c) || c is >= 'a' and <= 'f');

    public static string TextHash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    public static string Key(ProbeDefinition definition) => "custom." + TextHash("Domenia.CustomProbe/1\n" + ProbeCatalog.WriteDefinition(definition));

    public static ImmutableArray<FrozenProbe> Builtins(ImmutableArray<string> keys)
    {
        if (keys.IsDefault || keys.Length > 128) { throw Invalid("Liste de sondes invalide ; aucun poste contacté."); }
        return [.. keys.Distinct(StringComparer.Ordinal).Select(key => new FrozenProbe(key,
            ProbeCatalog.Find(key) ?? throw Invalid("Sonde embarquée inconnue ; la définition personnelle figée est requise avant toute collecte.")))];
    }

    public static ImmutableArray<FrozenProbe> Import(string document)
    {
        if (document is null || document.Length > MaximumBytes || Encoding.UTF8.GetByteCount(document) > MaximumBytes)
        { throw Invalid("Document de sondes trop volumineux (256 Kio au plus)."); }
        try
        {
            var definitions = ProbeCatalog.ReadDetailed(document);
            using var source = JsonDocument.Parse(document, new JsonDocumentOptions { MaxDepth = 16 });
            if (source.RootElement.TryGetProperty("DocumentationReviewedUtc", out _) || source.RootElement.TryGetProperty("Qualification", out _)
                || source.RootElement.GetProperty("Probes").EnumerateArray().Any(p => p.TryGetProperty("DocumentationReviewedUtc", out _)))
            { throw Invalid("Métadonnée documentaire globale non prise en charge pour une sonde personnelle. Placez la qualification dans ProviderQualification de chaque définition ; aucune métadonnée n’est écartée silencieusement."); }
            if (definitions.IsDefaultOrEmpty || definitions.Length > Capacity) { throw Invalid("Un import contient de 1 à 64 sondes déclaratives."); }
            foreach (var definition in definitions) { ValidatePersonal(definition); }
            return [.. definitions.Select(definition => new FrozenProbe(Key(definition), definition))];
        }
        catch (Exception ex) when (ex is InvalidDataException or JsonException or QueryDefinitionException)
        { throw Invalid(ex.Message); }
    }

    /// <summary>Validate at the execution boundary as well as at import, before any native worker starts.</summary>
    public static void Validate(ImmutableArray<FrozenProbe> probes)
    {
        if (probes.IsDefault || probes.Length > 128 || probes.Any(p => p is null || p.Definition is null || p.Key is null)
            || probes.Select(p => p.Key).Distinct(StringComparer.Ordinal).Count() != probes.Length)
        { throw Invalid("Liste de définitions figées invalide."); }
        foreach (var probe in probes)
        {
            if (IsKey(probe.Key))
            {
                try
                {
                    // Public immutable records can also be constructed in code. They pass the same bounds and typed
                    // declaration loader as an import before a provider worker is admitted.
                    _ = ProbeCatalog.ReadDetailed("{\"SchemaVersion\":1,\"Probes\":[" + ProbeCatalog.WriteDefinition(probe.Definition) + "]}");
                }
                catch (Exception ex) when (ex is InvalidDataException or JsonException or ArgumentException)
                { throw Invalid(ex.Message); }
                ValidatePersonal(probe.Definition);
                if (probe.Key != Key(probe.Definition)) { throw Invalid("La définition diffère de sa clé immuable."); }
            }
            else if (ProbeCatalog.Find(probe.Key) is not { } builtin || !ReferenceEquals(builtin, probe.Definition))
            { throw Invalid("Une sonde embarquée ne peut pas être redéfinie par le profil."); }
        }
    }

    private static void ValidatePersonal(ProbeDefinition definition)
    {
        var contract = ProbeCatalog.Contract(definition);
        if (definition.Origin != "Personnalisée" || !contract.Valid) { throw Invalid("Origine Personnalisée et contrat complet requis. " + string.Join(" ", contract.Errors)); }
        // A personal projection does not expand the provider classes the delivered catalog already permits.
        if (!ProbeCatalog.All.Any(p => p.Namespace.Equals(definition.Namespace, StringComparison.OrdinalIgnoreCase)
            && p.Class.Equals(definition.Class, StringComparison.OrdinalIgnoreCase)))
        { throw Invalid("Classe et espace de noms absents du catalogue autorisé : " + definition.Class + "."); }
        var filter = ProbeCatalog.ResolveFilter(definition.Filter, new DateTimeOffset(2026, 1, 8, 0, 0, 0, TimeSpan.Zero));
        var query = "SELECT " + string.Join(", ", definition.Properties) + " FROM " + definition.Class + (filter.Length == 0 ? "" : " WHERE " + filter);
        if (query.Length > CimReadSafety.MaximumSelectLength) { throw Invalid("Projection supérieure à la limite de 4 000 caractères du transport ; aucune collecte."); }
        var select = WqlRules.Parse(query);
        WqlRules.CheckTarget(definition.Namespace, select.ClassName);
    }

    public static PersonalProbeSnapshot Read(JsonElement? value)
    {
        if (value is null || value.Value.ValueKind == JsonValueKind.Null) { return new([], TextHash("absent")); }
        try
        {
            var raw = value.Value.GetRawText();
            if (raw.Length > MaximumBytes || Encoding.UTF8.GetByteCount(raw) > MaximumBytes) { throw Invalid("Catalogue personnel trop volumineux."); }
            var root = Object(value.Value, ["format", "entries"]);
            if (root["format"].ValueKind != JsonValueKind.String || root["format"].GetString() != Format
                || root["entries"].ValueKind != JsonValueKind.Array || root["entries"].GetArrayLength() > Capacity)
            { throw Invalid("Format ou taille du catalogue personnel invalide ; original conservé."); }
            var entries = ImmutableArray.CreateBuilder<FrozenProbe>();
            var keys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var element in root["entries"].EnumerateArray())
            {
                var row = Object(element, ["key", "definition"]);
                var key = row["key"].ValueKind == JsonValueKind.String ? row["key"].GetString() : null;
                if (!IsKey(key) || !keys.Add(key!)) { throw Invalid("Clé de sonde personnelle invalide ou répétée."); }
                var definition = ProbeCatalog.ReadDetailed("{\"SchemaVersion\":1,\"Probes\":[" + row["definition"].GetRawText() + "]}").Single();
                ValidatePersonal(definition);
                if (Key(definition) != key) { throw Invalid("Définition personnelle modifiée sous une ancienne clé ; original conservé."); }
                entries.Add(new(key!, definition));
            }
            return new(entries.ToImmutable(), TextHash(raw));
        }
        catch (Exception ex) when (ex is JsonException or InvalidDataException or QueryDefinitionException or KeyNotFoundException or InvalidOperationException)
        { throw Invalid("Catalogue personnel illisible ; aucun remplacement automatique. " + ex.Message); }
    }

    public static JsonElement Merge(PersonalProbeSnapshot current, ImmutableArray<FrozenProbe> additions)
    {
        Validate(additions);
        var existing = current.Entries.Select(p => p.Key).ToHashSet(StringComparer.Ordinal);
        var all = current.Entries.AddRange(additions.Where(p => !existing.Contains(p.Key)));
        if (all.Length > Capacity) { throw Invalid("Le catalogue conserve au plus 64 versions. Aucun ancien widget ni aucune définition n’a été supprimé."); }
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject(); writer.WriteString("format", Format); writer.WriteStartArray("entries");
            foreach (var entry in all)
            {
                writer.WriteStartObject(); writer.WriteString("key", entry.Key); writer.WritePropertyName("definition");
                ProbeCatalog.WriteDefinition(writer, entry.Definition); writer.WriteEndObject();
            }
            writer.WriteEndArray(); writer.WriteEndObject();
        }
        if (stream.Length > MaximumBytes) { throw Invalid("Le catalogue personnel dépasserait 256 Kio ; aucune modification."); }
        using var document = JsonDocument.Parse(stream.ToArray());
        return document.RootElement.Clone();
    }

    public static void RequireChoice(PersonalProbeSnapshot current, string token)
    {
        if (current.ChoiceToken != token)
        { throw new DomeniaOperationException("probes.changed", "Le catalogue a changé depuis l’aperçu. Relisez-le avant de confirmer ; aucune modification."); }
    }

    public static string Export(FrozenProbe entry) => "{\"SchemaVersion\":1,\"Probes\":[" + ProbeCatalog.WriteDefinition(entry.Definition) + "]}";

    private static Dictionary<string, JsonElement> Object(JsonElement value, string[] names)
    {
        if (value.ValueKind != JsonValueKind.Object) { throw Invalid("Objet de catalogue attendu."); }
        var result = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
            if (!names.Contains(property.Name, StringComparer.Ordinal) || !result.TryAdd(property.Name, property.Value))
            { throw Invalid("Propriété inconnue ou répétée dans le catalogue personnel."); }
        if (result.Count != names.Length) { throw Invalid("Catalogue personnel incomplet."); }
        return result;
    }

    private static DomeniaOperationException Invalid(string message) => new("probes.invalid", message);
}
