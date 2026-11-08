using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core.Queries;

public sealed record QueryReferenceItem(QueryRecipe Recipe, string Category, string Description);
public sealed record QueryReferencePatch(string Id, string Name, long Version, string DomainKey, DateTimeOffset CreatedAt,
    ImmutableArray<QueryReferenceItem> Items, string Sha256);
public sealed record QueryReferenceReceipt(string Id, string PatchId, long Version, string Sha256, string BeforeSha256,
    DateTimeOffset AppliedAt, int Created, int Replaced, int Ignored)
{
    public bool Simulated { get; init; }
}
public sealed record QueryReferenceResult(QueryReferenceReceipt Receipt, bool AlreadyApplied, bool Persisted, bool ReadBack, string Text);

/// <summary>Strict declarative interchange. SHA-256 covers the exact UTF-8 payload, including metadata and literal values.
/// It proves integrity, never publisher authenticity. No PowerShell, formula, macro or query is executed by this codec.</summary>
public static class QueryReferenceCodec
{
    public const string Format = "Domenia.ReferencePatch/1";
    public const int MaxBytes = 16 * 1024 * 1024, MaxItems = 500;
    private static readonly UTF8Encoding Utf8 = new(false, true);
    public static bool IsHash(string? value) => value is { Length: 64 } && value.All(char.IsAsciiHexDigitLower);
    internal static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    public static string Write(string name, long version, string domainKey, DateTimeOffset at, IEnumerable<QueryReferenceItem> items)
    {
        var payload = JsonSerializer.Serialize(new
        {
            id = QueryLibrary.PackId(name), name, version, domainKey, createdAt = at.ToString("O", CultureInfo.InvariantCulture),
            items = items.Select(i => new { definition = QueryRecipeJson.Write(i.Recipe), category = i.Category, description = i.Description }).ToArray(),
        });
        var text = JsonSerializer.Serialize(new { format = Format, application = "Domenia", payload, sha256 = Hash(Utf8.GetBytes(payload)) });
        _ = Read(text, at); // Export is subject to the same qualification and bounds as import.
        return text;
    }

    public static QueryReferencePatch Read(string text, DateTimeOffset now)
    {
        if (text is null || text.Length > MaxBytes) { throw Bad("Patch limité à 16 Mio."); }
        try
        {
            if (Utf8.GetByteCount(text) > MaxBytes) { throw Bad("Patch limité à 16 Mio."); }
            using var json = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 64 });
            var envelope = Object(json.RootElement, "format", "application", "payload", "sha256");
            if (String(envelope, "format") != Format || String(envelope, "application") != "Domenia") { throw Bad("Application ou version de patch inconnue."); }
            var payload = String(envelope, "payload"); var hash = String(envelope, "sha256");
            if (!IsHash(hash) || Hash(Utf8.GetBytes(payload)) != hash) { throw Bad("Empreinte SHA-256 du patch différente."); }
            using var contents = JsonDocument.Parse(payload, new JsonDocumentOptions { MaxDepth = 64 });
            var data = Object(contents.RootElement, "id", "name", "version", "domainKey", "createdAt", "items");
            var name = String(data, "name"); var id = String(data, "id"); var root = String(data, "domainKey");
            if (!QueryFormat.CleanText(name, 80) || id != QueryLibrary.PackId(name) || !IsHash(root)
                || data["version"].ValueKind != JsonValueKind.Number || !data["version"].TryGetInt64(out var version) || version is < 1 or > 1_000_000)
            { throw Bad("Identité, domaine ou version du patch invalide."); }
            var date = String(data, "createdAt");
            if (!DateTimeOffset.TryParseExact(date, "O", CultureInfo.InvariantCulture, DateTimeStyles.None, out var created) || created > now.AddMinutes(2))
            { throw Bad("Date de patch absente, imprécise ou future."); }
            var array = data["items"];
            if (array.ValueKind != JsonValueKind.Array || array.GetArrayLength() is < 1 or > MaxItems) { throw Bad("Un patch contient de 1 à 500 requêtes."); }
            var items = ImmutableArray.CreateBuilder<QueryReferenceItem>(); var ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (var row in array.EnumerateArray())
            {
                var values = Object(row, "definition", "category", "description");
                var definition = String(values, "definition"); var category = String(values, "category"); var description = String(values, "description");
                if (Utf8.GetByteCount(definition) > 1_048_576 || !QueryFormat.CleanText(category, 80, allowEmpty: true)
                    || !QueryFormat.CleanText(description, 500, allowEmpty: true)) { throw Bad("Définition ou métadonnées hors limites."); }
                var recipe = QueryRecipeJson.Read(definition);
                var compiled = QueryEngine.Compile(recipe);
                if (QueryRecipeJson.Write(recipe) != QueryRecipeJson.Write(compiled.Normalized))
                { throw Bad("La définition nécessiterait une normalisation ; réexportez-la depuis la bibliothèque avant diffusion."); }
                if (!QueryRecipeJson.IdPattern().IsMatch(recipe.Id) || recipe.Id.StartsWith(QueryTemplates.Prefix, StringComparison.Ordinal) || !ids.Add(recipe.Id))
                { throw Bad("Identifiant absent, réservé ou dupliqué."); }
                // Explicit object selections are production identities, not a distributable reference recipe.
                if (recipe.ObjectIds is not null) { throw Bad("Une sélection de GUID réels ne peut pas être diffusée dans un patch de référence."); }
                items.Add(new(recipe, category, description));
            }
            return new(id, name, version, root, created, items.ToImmutable(), hash);
        }
        catch (Exception ex) when (ex is JsonException or EncoderFallbackException or InvalidOperationException)
        { throw Bad("JSON de patch invalide ; aucune modification."); }
    }

    private static Dictionary<string, JsonElement> Object(JsonElement value, params string[] names)
    {
        if (value.ValueKind != JsonValueKind.Object) { throw Bad("Objet JSON attendu."); }
        var result = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var item in value.EnumerateObject())
        { if (!names.Contains(item.Name, StringComparer.Ordinal) || !result.TryAdd(item.Name, item.Value)) { throw Bad("Champ inconnu ou dupliqué dans le patch."); } }
        if (result.Count != names.Length) { throw Bad("Champ obligatoire absent du patch."); }
        return result;
    }
    private static string String(Dictionary<string, JsonElement> fields, string name) => fields[name].ValueKind == JsonValueKind.String
        ? fields[name].GetString()! : throw Bad("Champ texte attendu : " + name + ".");
    internal static QueryDefinitionException Bad(string message) => new(message);
}

/// <summary>A source-bound capability created by the engine, never from page flags. Every actual use rejects simulation
/// before touching a persistent medium. The caller supplies its real source/session validator at publication boundaries.</summary>
public sealed class QueryReferenceAccess
{
    private readonly EngineContext context;
    private readonly Action validate;
    private readonly Func<IDisposable>? acquire;
    private readonly MemoryQueryLibraryStore? demonstrationStore;
    public bool Demonstration => demonstrationStore is not null;
    public QueryReferenceAccess(EngineContext context, Action validate, Func<IDisposable>? acquire = null)
    {
        ArgumentNullException.ThrowIfNull(context); ArgumentNullException.ThrowIfNull(validate);
        this.context = context; this.validate = validate; this.acquire = acquire; Validate();
    }
    private QueryReferenceAccess(EngineContext context, MemoryQueryLibraryStore store)
    { this.context = context; validate = () => { }; demonstrationStore = store; Validate(); }
    internal static QueryReferenceAccess DemonstrationOnly(EngineContext context, MemoryQueryLibraryStore store) => new(context, store);
    internal void ValidateStore(IQueryLibraryStore actual)
    {
        Validate();
        if (demonstrationStore is not null && !ReferenceEquals(demonstrationStore, actual))
        { throw QueryReferenceCodec.Bad("Capacité de démonstration liée à un autre magasin ; aucun accès autorisé."); }
    }
    internal IDisposable? Hold(IQueryLibraryStore actual) { ValidateStore(actual); return acquire?.Invoke(); }
    public void Validate()
    {
        if (demonstrationStore is not null)
        {
            if (context.Mode != AppMode.Simulation || context.Directory.Kind != DirectorySourceKind.Simulation || demonstrationStore.Persistent)
            { throw QueryReferenceCodec.Bad("Le scénario fictif exige le magasin mémoire exact de la démonstration."); }
            return;
        }
        if (context.Mode == AppMode.Simulation || context.Directory.Kind == DirectorySourceKind.Simulation)
        { throw QueryReferenceCodec.Bad("Un patch de référence réel est interdit depuis la démonstration. Aucune bibliothèque réelle n’a été ouverte."); }
        validate();
    }
}
