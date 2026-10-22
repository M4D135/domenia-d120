using System.Buffers;
using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core.Queries;

/// <summary>Declared lineage of an imported recipe, never a trusted publisher identity.</summary>
public sealed record QueryProvenance(string? PackId, string? PackName, long PackVersion, string? Origin, string SourceRecipeId, string DefinitionSha256, bool Verified);

/// <summary>One stored revision of a recipe (the last ones are kept for the history panel).</summary>
public sealed record QueryRevision(long Revision, DateTimeOffset SavedAt, string Fingerprint, string Definition);

/// <summary>A personal recipe of the local library (one domain): definition, category, revision, archive flag, provenance.</summary>
public sealed record QueryLibraryRecord(
    string Id,
    string Name,
    string Category,
    string Description,
    long Revision,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    bool Archived,
    string Fingerprint,
    QueryRecipe Recipe,
    QueryProvenance? Provenance,
    ImmutableArray<QueryRevision> History);

/// <summary>Widget made from a saved recipe (Domenia 1 « sonde dashboard »): board, visual, title and the revision it is bound to.</summary>
public sealed record QueryWidgetLink(string Id, string RecipeId, long BoundRevision, string Board, string Visual, string Title, DateTimeOffset CreatedAt);

/// <summary>State of a recipe before an import changed it (restore point).</summary>
public sealed record QueryLibrarySnapshot(long Revision, bool Archived, string Category, string Name, string Definition, string DefinitionSha256, QueryProvenance? Provenance);

public sealed record QueryImportChange(string Id, string Name, long Revision, int Sequence, QueryLibrarySnapshot? Before);

/// <summary>One import or rollback of the journal (Domenia 1 Domenia.QueryImportJournal/1).</summary>
public sealed record QueryImportEntry(string ImportId, string Kind, string? RollsBack, DateTimeOffset At, string? PackId, string? PackName, long PackVersion, string? Origin, bool Verified,
    ImmutableArray<QueryImportChange> Items, ImmutableArray<QueryImportChange> Remaining);

/// <summary>Receipt of a library write: stored on disk or for the session only, read back, revision and fingerprint.</summary>
public sealed record QueryStoreReceipt(bool Persisted, bool ReadBack, long Revision, string Fingerprint, DateTimeOffset SavedAt, string Text);

/// <summary>Consumer of a recipe listed before it changes (Domenia 1 Get-DomeniaQueryRecipeImpact).</summary>
public sealed record QueryImpactRow(string Kind, string Element, string Name, string Link, string ConsumerId);

public sealed record QueryImpact(string RecipeId, long CurrentRevision, bool Changed, ImmutableArray<QueryDifference> Changes, ImmutableArray<QueryImpactRow> Rows, int Widgets, int Views, bool HasConsumers);

/// <summary>Examination of a pack (preview only: nothing is written).</summary>
public sealed record QueryImportItem(string Id, string Name, string Status, string StatusLabel, string ChangeSummary, ImmutableArray<QueryDifference> Changes, ImmutableArray<string> AllowedActions,
    string DefaultAction, long ExpectedRevision);

public sealed record QueryImportPlan(string ExaminationId, string Format, string? PackId, string? PackName, long PackVersion, string? Origin, string? ExportedAt, bool Verified, string Integrity,
    long PreviousVersion, ImmutableArray<QueryImportItem> Items, DateTimeOffset ExpiresAt);

/// <summary>
/// Local library of recipes for the domain of the session, kept in the preferences of the application (LocalWrite, never
/// the directory): personal recipes with revisions, archives, widget links, import journal with restore points. Every write
/// checks the expected revision, is serialized, read back and receipted; a write that fails keeps the change for the session
/// and says so. The preferences document is shared by every screen, so the library has its own budget (256 Kio).
/// </summary>
public sealed class QueryLibrary : IDisposable
{
    public const string LibraryPrefix = "requetes.library.";
    public const string ImportsPrefix = "requetes.imports.";
    public const string WidgetsPrefix = "requetes.widgets.";
    public const string PackVersionPrefix = "requetes.packVersion.";
    public const int LibraryBudget = 256 * 1024;
    public const int ImportsBudget = 128 * 1024;
    public const int MaxHistory = 5;
    public const int MaxJournal = 10;
    public const int MaxRecipes = 1000;
    public const string PackFormat = "Domenia.QueryPack/3";
    private static readonly TimeSpan ExaminationLife = TimeSpan.FromMinutes(30);

    private readonly IPreferenceStore preferences;
    private readonly OperationJournal journal;
    private readonly TimeProvider clock;
    private readonly ITechnicalJournal log;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<string, Loaded> loaded = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (QueryImportPlan Plan, ImmutableArray<QueryRecipe> Recipes, string RootKey)> examinations = new(StringComparer.Ordinal);

    private sealed class Loaded
    {
        public List<QueryLibraryRecord> Records { get; } = [];

        public List<QueryWidgetLink> Widgets { get; } = [];

        public List<QueryImportEntry> Imports { get; } = [];

        public int Unreadable { get; set; }
    }

    public QueryLibrary(IPreferenceStore preferences, OperationJournal journal, TimeProvider clock, ITechnicalJournal log)
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

    public static QueryLibrary From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new QueryLibrary(c.Preferences, c.Journal, c.Clock, c.Log));
    }

    public bool Persistent => preferences.Persistent;

    public void Dispose() => gate.Dispose();

    /// <summary>Hash of a domain root used in the preference keys (same rule as the working OU).</summary>
    public static string RootKey(string rootDn)
    {
        ArgumentNullException.ThrowIfNull(rootDn);
        var canonical = DistinguishedName.Format(DistinguishedName.Parse(rootDn)).ToUpperInvariant();
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
    }

    /// <summary>Stable identity of a named pack across its versions (Domenia 1 Get-DomeniaQueryPackId).</summary>
    public static string PackId(string name) => QueryRecipeJson.Sha256("Domenia.QueryPack|" + FrenchText.Fold(name ?? "").Trim())[..32];

    // ---------- Reading ----------

    /// <summary>Personal recipes and archives of the domain, widgets and journal (read once, then kept for the session).</summary>
    public async Task<(IReadOnlyList<QueryLibraryRecord> Records, IReadOnlyList<QueryWidgetLink> Widgets, int Unreadable)> ReadAsync(string rootDn, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = Load(RootKey(rootDn));
            return ([.. state.Records], [.. state.Widgets], state.Unreadable);
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task<QueryLibraryRecord?> FindAsync(string rootDn, string id, CancellationToken cancellationToken)
    {
        var (records, _, _) = await ReadAsync(rootDn, cancellationToken).ConfigureAwait(false);
        return records.FirstOrDefault(r => string.Equals(r.Id, id, StringComparison.Ordinal));
    }

    private Loaded Load(string rootKey)
    {
        if (loaded.TryGetValue(rootKey, out var state))
        {
            return state;
        }
        state = new Loaded();
        if (preferences.TryGet(LibraryPrefix + rootKey, out var library))
        {
            ReadRecords(library, state);
        }
        if (preferences.TryGet(WidgetsPrefix + rootKey, out var widgets) && widgets.ValueKind == JsonValueKind.Object && widgets.TryGetProperty("widgets", out var list) && list.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in list.EnumerateArray())
            {
                try
                {
                    var link = item.Deserialize<QueryWidgetLink>(StoreJson);
                    if (link is not null && link.Id.Length is > 0 and <= 64)
                    {
                        state.Widgets.Add(link);
                    }
                }
                catch (JsonException)
                {
                    state.Unreadable++;
                }
            }
        }
        if (preferences.TryGet(ImportsPrefix + rootKey, out var imports) && imports.ValueKind == JsonValueKind.Object && imports.TryGetProperty("entries", out var entries) && entries.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in entries.EnumerateArray())
            {
                try
                {
                    if (item.Deserialize<QueryImportEntry>(StoreJson) is { } entry && entry.ImportId.Length == 32)
                    {
                        state.Imports.Add(entry);
                    }
                }
                catch (JsonException)
                {
                    state.Unreadable++;
                }
            }
        }
        if (state.Unreadable > 0)
        {
            log.Warning($"Bibliothèque de requêtes : {state.Unreadable} enregistrement(s) illisible(s) écarté(s).");
        }
        loaded[rootKey] = state;
        return state;
    }

    private static readonly JsonSerializerOptions StoreJson = CreateStoreJson();

    private static JsonSerializerOptions CreateStoreJson()
    {
        var options = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = false };
        options.Converters.Add(new System.Text.Json.Serialization.JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        options.MakeReadOnly(populateMissingResolver: true);
        return options;
    }

    private void ReadRecords(JsonElement library, Loaded state)
    {
        if (library.ValueKind != JsonValueKind.Object || !library.TryGetProperty("recipes", out var recipes) || recipes.ValueKind != JsonValueKind.Array)
        {
            state.Unreadable++;
            return;
        }
        foreach (var item in recipes.EnumerateArray())
        {
            try
            {
                var definition = item.GetProperty("definition").GetString() ?? "";
                var recipe = QueryRecipeJson.Read(definition);
                var compiled = QueryEngine.Compile(recipe);
                var fingerprint = item.GetProperty("fingerprint").GetString() ?? "";
                if (!string.Equals(fingerprint, compiled.Fingerprint, StringComparison.Ordinal) || recipe.Id.StartsWith(QueryTemplates.Prefix, StringComparison.Ordinal))
                {
                    state.Unreadable++;
                    continue;
                }
                var history = item.TryGetProperty("history", out var h) && h.ValueKind == JsonValueKind.Array
                    ? h.EnumerateArray().Select(x => x.Deserialize<QueryRevision>(StoreJson)).OfType<QueryRevision>().ToImmutableArray()
                    : [];
                var provenance = item.TryGetProperty("provenance", out var p) && p.ValueKind == JsonValueKind.Object ? p.Deserialize<QueryProvenance>(StoreJson) : null;
                state.Records.Add(new QueryLibraryRecord(recipe.Id, recipe.Name, Text(item, "category", "Mes requêtes"), Text(item, "description", ""), item.GetProperty("revision").GetInt64(),
                    item.GetProperty("createdAt").GetDateTimeOffset(), item.GetProperty("updatedAt").GetDateTimeOffset(), item.TryGetProperty("archived", out var a) && a.ValueKind == JsonValueKind.True,
                    fingerprint, recipe, provenance, history));
            }
            catch (Exception ex) when (ex is JsonException or QueryDefinitionException or KeyNotFoundException or InvalidOperationException or FormatException)
            {
                state.Unreadable++;
            }
        }
    }

    private static string Text(JsonElement item, string name, string fallback) =>
        item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? fallback : fallback;

    // ---------- Writing ----------

    private static JsonElement Element(Action<Utf8JsonWriter> write)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            write(writer);
        }
        using var document = JsonDocument.Parse(buffer.WrittenMemory);
        return document.RootElement.Clone();
    }

    private static JsonElement LibraryElement(IEnumerable<QueryLibraryRecord> records) => Element(writer =>
    {
        writer.WriteStartObject();
        writer.WriteString("format", "domenia.queryLibrary");
        writer.WriteNumber("version", 1);
        writer.WriteStartArray("recipes");
        foreach (var record in records)
        {
            writer.WriteStartObject();
            writer.WriteString("id", record.Id);
            writer.WriteString("category", record.Category);
            writer.WriteString("description", record.Description);
            writer.WriteNumber("revision", record.Revision);
            writer.WriteString("createdAt", record.CreatedAt);
            writer.WriteString("updatedAt", record.UpdatedAt);
            writer.WriteBoolean("archived", record.Archived);
            writer.WriteString("fingerprint", record.Fingerprint);
            writer.WriteString("definition", QueryRecipeJson.Write(record.Recipe));
            if (record.Provenance is { } provenance)
            {
                writer.WritePropertyName("provenance");
                JsonSerializer.Serialize(writer, provenance, StoreJson);
            }
            writer.WritePropertyName("history");
            JsonSerializer.Serialize(writer, record.History, StoreJson);
            writer.WriteEndObject();
        }
        writer.WriteEndArray();
        writer.WriteEndObject();
    });

    private async Task<bool> WriteAsync(string key, JsonElement value, CancellationToken cancellationToken)
    {
        try
        {
            await preferences.SetAsync(key, value, cancellationToken).ConfigureAwait(false);
            return preferences.Persistent;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Bibliothèque de requêtes non enregistrée : {ex.GetType().Name}.");
            journal.Add(new JournalEntry(clock.GetUtcNow(), "Préférences non enregistrées" + FrenchText.Colon + "la bibliothèque de requêtes vaut pour cette session", Tone.Warn));
            return false;
        }
    }

    /// <summary>Writes the library of a domain within its budget, then reads it back; never throws for a disk failure.</summary>
    private async Task<(bool Persisted, bool ReadBack)> CommitAsync(string rootKey, Loaded state, CancellationToken cancellationToken)
    {
        var element = Trim(state.Records);
        var persisted = await WriteAsync(LibraryPrefix + rootKey, element, cancellationToken).ConfigureAwait(false);
        var readBack = preferences.TryGet(LibraryPrefix + rootKey, out var stored) && stored.GetRawText() == element.GetRawText();
        return (persisted, readBack);
    }

    private JsonElement Trim(List<QueryLibraryRecord> records)
    {
        var element = LibraryElement(records);
        // Oldest revisions go first when the budget is reached; the current definitions are never dropped.
        while (Encoding.UTF8.GetByteCount(element.GetRawText()) > LibraryBudget && records.Any(r => r.History.Length > 0))
        {
            var index = records.FindIndex(r => r.History.Length == records.Max(x => x.History.Length));
            records[index] = records[index] with { History = records[index].History.RemoveAt(records[index].History.Length - 1) };
            element = LibraryElement(records);
        }
        if (Encoding.UTF8.GetByteCount(element.GetRawText()) > LibraryBudget)
        {
            throw new QueryDefinitionException("Bibliothèque locale pleine (256 Kio) : archivez puis exportez des requêtes avant d’en enregistrer d’autres. Rien n’a été écrit.");
        }
        return element;
    }

    private QueryStoreReceipt Receipt(bool persisted, bool readBack, QueryLibraryRecord record, DateTimeOffset at)
    {
        var text = persisted && readBack
            ? "Révision " + FrenchText.Integer(record.Revision) + " enregistrée dans les préférences locales et relue (empreinte " + record.Fingerprint[..12] + ")."
            : persisted
                ? "Révision " + FrenchText.Integer(record.Revision) + " envoyée aux préférences locales ; la relecture diffère : relisez la bibliothèque."
                : "Révision " + FrenchText.Integer(record.Revision) + " valable pour cette session seulement : les préférences locales n’ont pas pu être écrites.";
        return new QueryStoreReceipt(persisted, readBack, record.Revision, record.Fingerprint, at, text);
    }

    private static QueryDefinitionException RevisionChanged(long current) =>
        new("La requête a changé depuis sa lecture (révision " + FrenchText.Integer(current) + ") : relisez-la avant d’enregistrer. Rien n’a été écrit.");

    /// <summary>
    /// Saves a recipe (Domenia 1 Save-DomeniaQueryRecipe): a new revision of a personal recipe, or a personal copy of a delivered
    /// model. <paramref name="mode"/> « update » keeps the identifier, « copy » saves a new independent recipe « (nouvelle version) »,
    /// « migrate » updates and binds the linked widgets to the new revision. An unchanged definition writes nothing.
    /// </summary>
    public async Task<(QueryLibraryRecord Record, QueryStoreReceipt Receipt, bool Written)> SaveAsync(string rootDn, QueryRecipe recipe, string? category, string? description, long expectedRevision, string mode, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        var cat = string.IsNullOrWhiteSpace(category) ? null : category.Trim();
        if (cat is not null && !QueryFormat.CleanText(cat, 80))
        {
            throw new QueryDefinitionException("Catégorie de bibliothèque invalide (80 caractères, sans caractère de contrôle).");
        }
        var desc = (description ?? "").Trim();
        if (desc.Length > 500 || desc.Any(c => char.IsControl(c) && c != '\n'))
        {
            throw new QueryDefinitionException("Description limitée à 500 caractères, sans caractère de contrôle.");
        }
        if (mode is not ("update" or "copy" or "migrate"))
        {
            throw new QueryDefinitionException(QueryTexts.InvalidMessage("choix d’enregistrement inconnu."));
        }
        var template = recipe.Id.StartsWith(QueryTemplates.Prefix, StringComparison.Ordinal);
        if (template || mode == "copy")
        {
            var suffix = template ? "" : " (nouvelle version)";
            var name = recipe.Name.Length + suffix.Length > QueryLimits.MaxNameLength ? recipe.Name[..(QueryLimits.MaxNameLength - suffix.Length)] : recipe.Name;
            recipe = recipe with { Id = Guid.NewGuid().ToString("N"), Name = name + suffix };
            expectedRevision = 0;
            mode = "update";
        }
        var compiled = QueryEngine.Compile(recipe);
        var normalized = compiled.Normalized with { Format = compiled.Normalized.MinimalFormat() };
        var rootKey = RootKey(rootDn);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = Load(rootKey);
            var now = clock.GetUtcNow();
            var index = state.Records.FindIndex(r => string.Equals(r.Id, normalized.Id, StringComparison.Ordinal));
            var existing = index >= 0 ? state.Records[index] : null;
            var currentRevision = existing?.Revision ?? 0;
            if (currentRevision != expectedRevision)
            {
                throw RevisionChanged(currentRevision);
            }
            if (existing is null && state.Records.Count >= MaxRecipes)
            {
                throw new QueryDefinitionException("La bibliothèque locale contient déjà 1 000 requêtes : archivez ou exportez avant d’en ajouter. Rien n’a été écrit.");
            }
            var finalCategory = cat ?? existing?.Category ?? "Mes requêtes";
            if (existing is not null && !existing.Archived && existing.Fingerprint == compiled.Fingerprint && existing.Category == finalCategory && existing.Description == desc)
            {
                return (existing, Receipt(preferences.Persistent, true, existing, existing.UpdatedAt), false);
            }
            var history = existing is null ? [] : existing.History.Insert(0, new QueryRevision(existing.Revision, existing.UpdatedAt, existing.Fingerprint, QueryRecipeJson.Write(existing.Recipe)));
            if (history.Length > MaxHistory)
            {
                history = history.RemoveRange(MaxHistory, history.Length - MaxHistory);
            }
            var record = new QueryLibraryRecord(normalized.Id, normalized.Name, finalCategory, desc, currentRevision + 1, existing?.CreatedAt ?? now, now, false, compiled.Fingerprint, normalized, existing?.Provenance, history);
            var previous = state.Records.ToList();
            if (index >= 0)
            {
                state.Records[index] = record;
            }
            else
            {
                state.Records.Add(record);
            }
            (bool, bool) result;
            try
            {
                result = await CommitAsync(rootKey, state, cancellationToken).ConfigureAwait(false);
            }
            catch (QueryDefinitionException)
            {
                state.Records.Clear();
                state.Records.AddRange(previous);
                throw;
            }
            if (mode == "migrate")
            {
                for (var i = 0; i < state.Widgets.Count; i++)
                {
                    if (state.Widgets[i].RecipeId == record.Id)
                    {
                        state.Widgets[i] = state.Widgets[i] with { BoundRevision = record.Revision };
                    }
                }
                await WriteWidgetsAsync(rootKey, state, cancellationToken).ConfigureAwait(false);
            }
            journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "« " + record.Name + " » enregistrée (révision " + FrenchText.Integer(record.Revision) + ")", Tone.Ok));
            return (record, Receipt(result.Item1, result.Item2, record, now), true);
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>Archives a recipe (revisions kept) and detaches its widgets in the same write (Domenia 1 archive).</summary>
    public async Task<(QueryLibraryRecord Record, QueryStoreReceipt Receipt, ImmutableArray<QueryWidgetLink> Removed)> ArchiveAsync(string rootDn, string id, long expectedRevision, CancellationToken cancellationToken)
    {
        if (id.StartsWith(QueryTemplates.Prefix, StringComparison.Ordinal))
        {
            throw new QueryDefinitionException("Un modèle livré ne s’archive pas. Rien n’a été écrit.");
        }
        var rootKey = RootKey(rootDn);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = Load(rootKey);
            var index = state.Records.FindIndex(r => string.Equals(r.Id, id, StringComparison.Ordinal));
            if (index < 0)
            {
                throw new QueryDefinitionException(QueryErrors.NotFoundMessage);
            }
            var existing = state.Records[index];
            if (existing.Revision != expectedRevision)
            {
                throw RevisionChanged(existing.Revision);
            }
            if (existing.Archived)
            {
                return (existing, Receipt(preferences.Persistent, true, existing, existing.UpdatedAt), []);
            }
            var now = clock.GetUtcNow();
            var record = existing with { Archived = true, Revision = existing.Revision + 1, UpdatedAt = now };
            state.Records[index] = record;
            var removed = state.Widgets.Where(w => w.RecipeId == id).ToImmutableArray();
            state.Widgets.RemoveAll(w => w.RecipeId == id);
            var (persisted, readBack) = await CommitAsync(rootKey, state, cancellationToken).ConfigureAwait(false);
            if (removed.Length > 0)
            {
                await WriteWidgetsAsync(rootKey, state, cancellationToken).ConfigureAwait(false);
            }
            journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "« " + record.Name + " » archivée" + (removed.Length > 0 ? ", " + FrenchText.Count(removed.Length, "widget retiré", "widgets retirés") : ""), Tone.Info));
            return (record, Receipt(persisted, readBack, record, now), removed);
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>Restores an archived recipe with a new revision; <paramref name="widgets"/> brings back the links removed by its archive (undo).</summary>
    public async Task<(QueryLibraryRecord Record, QueryStoreReceipt Receipt)> RestoreAsync(string rootDn, string id, long expectedRevision, IReadOnlyList<QueryWidgetLink>? widgets, CancellationToken cancellationToken)
    {
        var rootKey = RootKey(rootDn);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = Load(rootKey);
            var index = state.Records.FindIndex(r => string.Equals(r.Id, id, StringComparison.Ordinal));
            if (index < 0)
            {
                throw new QueryDefinitionException(QueryErrors.NotFoundMessage);
            }
            var existing = state.Records[index];
            if (existing.Revision != expectedRevision)
            {
                throw RevisionChanged(existing.Revision);
            }
            var now = clock.GetUtcNow();
            var record = existing with { Archived = false, Revision = existing.Revision + 1, UpdatedAt = now };
            state.Records[index] = record;
            var (persisted, readBack) = await CommitAsync(rootKey, state, cancellationToken).ConfigureAwait(false);
            if (widgets is { Count: > 0 })
            {
                foreach (var widget in widgets.Where(w => w.RecipeId == id && state.Widgets.All(x => x.Id != w.Id)))
                {
                    state.Widgets.Add(widget with { BoundRevision = record.Revision });
                }
                await WriteWidgetsAsync(rootKey, state, cancellationToken).ConfigureAwait(false);
            }
            journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "« " + record.Name + " » restaurée (révision " + FrenchText.Integer(record.Revision) + ")", Tone.Ok));
            return (record, Receipt(persisted, readBack, record, now));
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>Restores one earlier revision of a recipe as a new revision (history panel).</summary>
    public async Task<(QueryLibraryRecord Record, QueryStoreReceipt Receipt, bool Written)> RevertAsync(string rootDn, string id, long revision, long expectedRevision, CancellationToken cancellationToken)
    {
        var record = await FindAsync(rootDn, id, cancellationToken).ConfigureAwait(false) ?? throw new QueryDefinitionException(QueryErrors.NotFoundMessage);
        var old = record.History.FirstOrDefault(h => h.Revision == revision) ?? throw new QueryDefinitionException("Révision introuvable dans l’historique conservé. Rien n’a été écrit.");
        var recipe = QueryRecipeJson.Read(old.Definition) with { Id = id };
        return await SaveAsync(rootDn, recipe, record.Category, record.Description, expectedRevision, "update", cancellationToken).ConfigureAwait(false);
    }

    // ---------- Widgets ----------

    private async Task WriteWidgetsAsync(string rootKey, Loaded state, CancellationToken cancellationToken)
    {
        var element = Element(writer =>
        {
            writer.WriteStartObject();
            writer.WritePropertyName("widgets");
            JsonSerializer.Serialize(writer, state.Widgets, StoreJson);
            writer.WriteEndObject();
        });
        await WriteAsync(WidgetsPrefix + rootKey, element, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Adds (or updates) the widget of a saved recipe; the link records the revision it is bound to.</summary>
    public async Task<QueryWidgetLink> LinkWidgetAsync(string rootDn, string recipeId, string board, string visual, string title, CancellationToken cancellationToken)
    {
        if (board is not ("fleet" or "computer") || visual is not ("kpi" or "text" or "bar" or "pie" or "column"))
        {
            throw new QueryDefinitionException("Destination ou représentation de widget inconnue.");
        }
        if (!QueryFormat.CleanText(title, 80))
        {
            throw new QueryDefinitionException("Titre de widget invalide (80 caractères).");
        }
        var rootKey = RootKey(rootDn);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = Load(rootKey);
            var record = state.Records.FirstOrDefault(r => r.Id == recipeId && !r.Archived) ?? throw new QueryDefinitionException("Enregistrez la requête avant d’en faire un widget.");
            var index = state.Widgets.FindIndex(w => w.RecipeId == recipeId && w.Board == board);
            var link = new QueryWidgetLink(index >= 0 ? state.Widgets[index].Id : Guid.NewGuid().ToString("N"), recipeId, record.Revision, board, visual, title.Trim(), clock.GetUtcNow());
            if (index >= 0)
            {
                state.Widgets[index] = link;
            }
            else
            {
                if (state.Widgets.Count >= 64)
                {
                    throw new QueryDefinitionException("64 widgets de requêtes au plus.");
                }
                state.Widgets.Add(link);
            }
            await WriteWidgetsAsync(rootKey, state, cancellationToken).ConfigureAwait(false);
            journal.Add(new JournalEntry(link.CreatedAt, "Requêtes" + FrenchText.Colon + "widget « " + link.Title + " » ajouté au " + (board == "fleet" ? "tableau de bord général" : "tableau de bord du poste"), Tone.Ok));
            return link;
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task<bool> UnlinkWidgetAsync(string rootDn, string widgetId, CancellationToken cancellationToken)
    {
        var rootKey = RootKey(rootDn);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = Load(rootKey);
            if (state.Widgets.RemoveAll(w => w.Id == widgetId) == 0)
            {
                return false;
            }
            await WriteWidgetsAsync(rootKey, state, cancellationToken).ConfigureAwait(false);
            return true;
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// Consumers of a recipe before it changes (Domenia 1 Get-DomeniaQueryRecipeImpact): widgets with the revision they are bound
    /// to, the frozen selection of Recherche. <paramref name="draft"/> tells what would change.
    /// </summary>
    public async Task<QueryImpact> ImpactAsync(string rootDn, string id, QueryRecipe? draft, string? searchRecipeId, CancellationToken cancellationToken)
    {
        var (records, widgets, _) = await ReadAsync(rootDn, cancellationToken).ConfigureAwait(false);
        var record = records.FirstOrDefault(r => r.Id == id);
        var rows = ImmutableArray.CreateBuilder<QueryImpactRow>();
        var current = record?.Revision ?? 0;
        foreach (var widget in widgets.Where(w => w.RecipeId == id))
        {
            var link = widget.BoundRevision < current ? "Lié à une ancienne révision (" + FrenchText.Integer(widget.BoundRevision) + ")" : "Lié à la révision " + FrenchText.Integer(widget.BoundRevision);
            rows.Add(new QueryImpactRow("widget", widget.Board == "fleet" ? "Tableau de bord général" : "Tableau de bord du poste", widget.Title, link, widget.Id));
        }
        var views = 0;
        if (searchRecipeId == id)
        {
            views++;
            rows.Add(new QueryImpactRow("view", "Vue de Recherche", "Sélection figée appliquée aux résultats", "Garde les GUID figés à son application", "search"));
        }
        var changes = draft is null || record is null ? [] : QueryAnalysis.Compare(record.Recipe, QueryEngine.Compile(draft).Normalized);
        var changed = record is null || draft is null || QueryEngine.Compile(draft).Fingerprint != record.Fingerprint;
        return new QueryImpact(id, current, changed, changes, rows.ToImmutable(), widgets.Count(w => w.RecipeId == id), views, rows.Count > 0);
    }

    // ---------- Packs ----------

    /// <summary>Integrity of a versioned pack: identity, version and the fingerprint of every definition, in order.</summary>
    public static string ContentHash(string packId, long version, IEnumerable<QueryRecipe> recipes)
    {
        ArgumentNullException.ThrowIfNull(recipes);
        var lines = new List<string> { PackFormat, packId, version.ToString(CultureInfo.InvariantCulture) };
        lines.AddRange(recipes.Select(r => r.Id + ":" + QueryEngine.Compile(r).Fingerprint));
        return QueryRecipeJson.Sha256(string.Join("\n", lines));
    }

    /// <summary>
    /// Versioned, self-checking pack of personal recipes (data only: importing it never executes anything). The proposed version
    /// of the next export of the same pack is remembered.
    /// </summary>
    public async Task<(string Json, string FileName, int Count, long NextVersion)> ExportPackAsync(string rootDn, string domainDn, string name, long version, IReadOnlyCollection<string>? ids, string? origin, CancellationToken cancellationToken)
    {
        name = (name ?? "").Trim();
        if (!QueryFormat.CleanText(name, 80))
        {
            throw new QueryDefinitionException("Nom de pack invalide (1 à 80 caractères, sans caractère de contrôle).");
        }
        if (version is < 1 or > 1000000)
        {
            throw new QueryDefinitionException("Version de pack invalide (nombre entier de 1 à 1 000 000).");
        }
        if (origin is not null && !QueryFormat.CleanText(origin, 256, allowEmpty: true))
        {
            throw new QueryDefinitionException("Provenance du pack invalide.");
        }
        var (records, _, _) = await ReadAsync(rootDn, cancellationToken).ConfigureAwait(false);
        var chosen = records.Where(r => !r.Archived && (ids is null || ids.Count == 0 || ids.Contains(r.Id))).OrderBy(r => FrenchText.Fold(r.Name), StringComparer.Ordinal).ToList();
        if (chosen.Count == 0)
        {
            throw new QueryDefinitionException("Aucune requête personnelle à exporter : enregistrez d’abord une requête.");
        }
        if (chosen.Count > 5000)
        {
            throw new QueryDefinitionException("Un pack contient au maximum 5 000 recettes ; exportez la sélection en plusieurs packs.");
        }
        var packId = PackId(name);
        var now = clock.GetUtcNow();
        var hash = ContentHash(packId, version, chosen.Select(r => r.Recipe));
        var element = Element(writer =>
        {
            writer.WriteStartObject();
            writer.WriteString("Format", PackFormat);
            writer.WriteString("PackId", packId);
            writer.WriteString("PackName", name);
            writer.WriteNumber("PackVersion", version);
            writer.WriteString("Origin", origin ?? "");
            writer.WriteString("DomainDn", domainDn);
            writer.WriteString("ExportedAtUtc", now.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture));
            writer.WriteString("ContentSHA256", hash);
            writer.WriteStartArray("Recipes");
            foreach (var record in chosen)
            {
                QueryRecipeJson.WriteRecipe(writer, record.Recipe);
            }
            writer.WriteEndArray();
            writer.WriteEndObject();
        });
        var json = JsonSerializer.Serialize(element, new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        var next = version + 1;
        await WriteAsync(PackVersionPrefix + packId, JsonSerializer.SerializeToElement(next), cancellationToken).ConfigureAwait(false);
        journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "pack « " + name + " » v" + version.ToString(CultureInfo.InvariantCulture) + " exporté (" + FrenchText.Count(chosen.Count, "requête", "requêtes") + ")", Tone.Info));
        var file = "Domenia-requetes-" + WindowsRelease.Slug(name) + "-v" + version.ToString(CultureInfo.InvariantCulture) + ".json";
        return (json, file, chosen.Count, next);
    }

    /// <summary>Proposed version of the next export of a pack (1 for a new pack).</summary>
    public long ProposedVersion(string name) =>
        preferences.TryGet(PackVersionPrefix + PackId(name ?? ""), out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var next) && next is >= 1 and <= 1000000 ? next : 1;

    /// <summary>
    /// Reads a pack and prepares its import plan (Domenia 1 New-DomeniaQueryPackImportPlan): provenance, version, integrity,
    /// version already imported, and for each recipe its state with its differences. Nothing is written.
    /// </summary>
    public async Task<QueryImportPlan> ExaminePackAsync(string rootDn, string domainDn, string json, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(json);
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 64 });
        }
        catch (JsonException)
        {
            throw new QueryDefinitionException("Pack illisible : ce fichier n’est pas un JSON valide. Rien n’a été importé.");
        }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new QueryDefinitionException("Pack illisible. Rien n’a été importé.");
            }
            string Prop(string name) => root.EnumerateObject().FirstOrDefault(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase)).Value is { ValueKind: JsonValueKind.String } v ? v.GetString() ?? "" : "";
            var format = Prop("Format");
            if (format.StartsWith("Domenia.QueryLibrary/", StringComparison.Ordinal))
            {
                QueryRecipeJson.CheckFormat(format, "Domenia.QueryLibrary", 1, "bibliothèque");
            }
            else
            {
                QueryRecipeJson.CheckFormat(format, "Domenia.QueryPack", 3, "pack");
            }
            var recipesElement = root.EnumerateObject().FirstOrDefault(p => p.Name is "Recipes" or "recipes" or "Queries" or "queries").Value;
            if (recipesElement.ValueKind != JsonValueKind.Array)
            {
                throw new QueryDefinitionException("Pack sans liste de recettes. Rien n’a été importé.");
            }
            if (recipesElement.GetArrayLength() > 5000)
            {
                throw new QueryDefinitionException("Le pack dépasse 5 000 recettes.");
            }
            var origin = Prop("Origin");
            if (!QueryFormat.CleanText(origin, 256, allowEmpty: true))
            {
                throw new QueryDefinitionException("Provenance du pack invalide.");
            }
            var recipes = new List<QueryRecipe>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in recipesElement.EnumerateArray())
            {
                var recipe = QueryRecipeJson.Read(Accents(item));
                if (!seen.Add(recipe.Id))
                {
                    throw new QueryDefinitionException("Identifiant de recette dupliqué dans le pack. Rien n’a été importé.");
                }
                if (recipe.Id.StartsWith(QueryTemplates.Prefix, StringComparison.Ordinal))
                {
                    throw new QueryDefinitionException("Identifiant réservé aux modèles livrés dans le pack. Rien n’a été importé.");
                }
                QueryEngine.Compile(recipe);
                recipes.Add(recipe);
            }
            var packName = Prop("PackName");
            var packId = Prop("PackId");
            long packVersion = root.EnumerateObject().FirstOrDefault(p => p.Name == "PackVersion").Value is { ValueKind: JsonValueKind.Number } pv && pv.TryGetInt64(out var parsed) ? parsed : 0;
            bool verified;
            string integrity;
            if (format == PackFormat)
            {
                if (!QueryFormat.CleanText(packName, 80) || packVersion is < 1 or > 1000000 || packId != PackId(packName))
                {
                    throw new QueryDefinitionException("Identité du pack incohérente avec son nom. Aucune recette importée.");
                }
                if (ContentHash(packId, packVersion, recipes) != Prop("ContentSHA256"))
                {
                    throw new QueryDefinitionException("Pack modifié ou incomplet : son empreinte de contenu ne correspond pas. Aucune recette importée.");
                }
                verified = true;
                integrity = "Intégrité vérifiée : empreinte de contenu conforme.";
            }
            else
            {
                verified = false;
                integrity = "Intégrité non vérifiable : pack écrit par Domenia 1 (empreintes calculées par PowerShell). Relisez chaque recette avant de l’importer.";
            }
            var (records, _, _) = await ReadAsync(rootDn, cancellationToken).ConfigureAwait(false);
            var items = ImmutableArray.CreateBuilder<QueryImportItem>();
            var packDomain = Prop("DomainDn");
            foreach (var recipe in recipes)
            {
                var current = records.FirstOrDefault(r => r.Id == recipe.Id);
                var foreign = recipe.ObjectIds is not null && packDomain.Length > 0 && !string.Equals(packDomain, domainDn, StringComparison.OrdinalIgnoreCase);
                var fingerprint = QueryEngine.Compile(recipe).Fingerprint;
                var status = foreign ? "foreignDomain" : current is null ? "new" : current.Archived ? "archived" : current.Fingerprint == fingerprint ? "identical" : "conflict";
                var label = status switch
                {
                    "foreignDomain" => "Domaine différent",
                    "new" => "Nouvelle",
                    "archived" => "Archivée localement",
                    "identical" => "Identique",
                    _ => "Conflit",
                };
                var changes = QueryAnalysis.Compare(current?.Recipe, QueryEngine.Compile(recipe).Normalized);
                ImmutableArray<string> allowed = status switch
                {
                    "new" => ["ignore", "create"],
                    "conflict" or "archived" => ["ignore", "copy", "replace"],
                    _ => ["ignore"],
                };
                items.Add(new QueryImportItem(recipe.Id, recipe.Name, status, label, QueryAnalysis.ChangeSummary(changes, status == "new"), changes, allowed, "ignore", current?.Revision ?? 0));
            }
            var state = await HistoryAsync(rootDn, cancellationToken).ConfigureAwait(false);
            var previous = state.Where(e => e.PackId == packId && packId.Length > 0).Select(e => e.PackVersion).DefaultIfEmpty(0).Max();
            var examination = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
            var plan = new QueryImportPlan(examination, format, packId.Length > 0 ? packId : null, packName.Length > 0 ? packName : null, packVersion, origin.Length > 0 ? origin : null,
                Prop("ExportedAtUtc") is { Length: > 0 } exported ? exported : null, verified, integrity, previous, items.ToImmutable(), clock.GetUtcNow() + ExaminationLife);
            await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                foreach (var key in examinations.Where(e => e.Value.Plan.ExpiresAt < clock.GetUtcNow()).Select(e => e.Key).ToList())
                {
                    examinations.Remove(key);
                }
                examinations[examination] = (plan, [.. recipes], RootKey(rootDn));
            }
            finally
            {
                gate.Release();
            }
            return plan;
        }
    }

    // Domenia 1 coded values written without accents in older packs.
    private static JsonElement Accents(JsonElement recipe)
    {
        var text = recipe.GetRawText();
        foreach (var (before, after) in new[] { ("\"Sans reponse\"", "\"Sans réponse\""), ("\"Non verifie\"", "\"Non vérifié\""), ("\"Non protege\"", "\"Non protégé\""), ("\"Protege\"", "\"Protégé\""), ("\"Defaillant\"", "\"Défaillant\""), ("\"Controleur de domaine\"", "\"Contrôleur de domaine\"") })
        {
            text = text.Replace(before, after, StringComparison.Ordinal);
        }
        using var document = JsonDocument.Parse(text);
        return document.RootElement.Clone();
    }

    /// <summary>
    /// Applies the chosen actions of an examined pack, one recipe after another with its revision checked (Domenia 1
    /// Start-DomeniaQueryImport): creations go to « Import · &lt;pack&gt; » with their provenance; the journal keeps a restore point.
    /// </summary>
    public async Task<(QueryImportEntry Entry, int Created, int Replaced, int Copied, int Ignored, QueryStoreReceipt? Receipt)> ApplyImportAsync(string rootDn, string examinationId,
        IReadOnlyDictionary<string, string> choices, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(choices);
        var rootKey = RootKey(rootDn);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!examinations.TryGetValue(examinationId, out var exam) || exam.Plan.ExpiresAt < clock.GetUtcNow() || exam.RootKey != rootKey)
            {
                throw new QueryDefinitionException(QueryErrors.ImportUnknownMessage);
            }
            var state = Load(rootKey);
            var now = clock.GetUtcNow();
            var category = "Import · " + (exam.Plan.PackName ?? "pack sans nom");
            if (category.Length > 80)
            {
                category = category[..80];
            }
            var changes = new List<QueryImportChange>();
            int created = 0, replaced = 0, copied = 0, ignored = 0, sequence = 0;
            var previous = state.Records.ToList();
            foreach (var item in exam.Plan.Items)
            {
                var action = choices.GetValueOrDefault(item.Id, "ignore");
                if (!item.AllowedActions.Contains(action))
                {
                    throw new QueryDefinitionException("Action non permise pour « " + item.Name + " ». Rien n’a été importé.");
                }
                if (action == "ignore")
                {
                    ignored++;
                    continue;
                }
                var recipe = exam.Recipes.First(r => r.Id == item.Id);
                var compiled = QueryEngine.Compile(recipe);
                var provenance = new QueryProvenance(exam.Plan.PackId, exam.Plan.PackName, exam.Plan.PackVersion, exam.Plan.Origin, recipe.Id, compiled.Fingerprint, exam.Plan.Verified);
                var index = state.Records.FindIndex(r => r.Id == recipe.Id);
                var current = index >= 0 ? state.Records[index] : null;
                if ((current?.Revision ?? 0) != item.ExpectedRevision)
                {
                    state.Records.Clear();
                    state.Records.AddRange(previous);
                    throw RevisionChanged(current?.Revision ?? 0);
                }
                sequence++;
                switch (action)
                {
                    case "create":
                        var record = new QueryLibraryRecord(recipe.Id, recipe.Name, category, "", 1, now, now, false, compiled.Fingerprint, compiled.Normalized, provenance, []);
                        state.Records.Add(record);
                        changes.Add(new QueryImportChange(record.Id, record.Name, 1, sequence, null));
                        created++;
                        break;
                    case "copy":
                        var copy = compiled.Normalized with { Id = Guid.NewGuid().ToString("N"), Name = Clip(recipe.Name + " (copie importée)") };
                        var copyCompiled = QueryEngine.Compile(copy);
                        var copyRecord = new QueryLibraryRecord(copy.Id, copy.Name, category, "", 1, now, now, false, copyCompiled.Fingerprint, copyCompiled.Normalized, provenance, []);
                        state.Records.Add(copyRecord);
                        changes.Add(new QueryImportChange(copyRecord.Id, copyRecord.Name, 1, sequence, null));
                        copied++;
                        break;
                    default:
                        var before = new QueryLibrarySnapshot(current!.Revision, current.Archived, current.Category, current.Name, QueryRecipeJson.Write(current.Recipe), current.Fingerprint, current.Provenance);
                        var history = current.History.Insert(0, new QueryRevision(current.Revision, current.UpdatedAt, current.Fingerprint, QueryRecipeJson.Write(current.Recipe)));
                        var replacedRecord = current with
                        {
                            Name = recipe.Name,
                            Revision = current.Revision + 1,
                            UpdatedAt = now,
                            Archived = false,
                            Fingerprint = compiled.Fingerprint,
                            Recipe = compiled.Normalized,
                            Provenance = provenance,
                            History = history.Length > MaxHistory ? history.RemoveRange(MaxHistory, history.Length - MaxHistory) : history,
                        };
                        state.Records[index] = replacedRecord;
                        changes.Add(new QueryImportChange(replacedRecord.Id, replacedRecord.Name, replacedRecord.Revision, sequence, before));
                        replaced++;
                        break;
                }
            }
            if (state.Records.Count > MaxRecipes)
            {
                state.Records.Clear();
                state.Records.AddRange(previous);
                throw new QueryDefinitionException("L’import dépasserait 1 000 requêtes dans la bibliothèque locale. Rien n’a été importé.");
            }
            QueryStoreReceipt? receipt = null;
            if (changes.Count > 0)
            {
                (bool, bool) result;
                try
                {
                    result = await CommitAsync(rootKey, state, cancellationToken).ConfigureAwait(false);
                }
                catch (QueryDefinitionException)
                {
                    state.Records.Clear();
                    state.Records.AddRange(previous);
                    throw;
                }
                var last = state.Records.First(r => r.Id == changes[^1].Id);
                receipt = Receipt(result.Item1, result.Item2, last, now);
            }
            var entry = new QueryImportEntry(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)), "import", null, now, exam.Plan.PackId, exam.Plan.PackName, exam.Plan.PackVersion, exam.Plan.Origin,
                exam.Plan.Verified, [.. changes], []);
            if (changes.Count > 0)
            {
                state.Imports.Add(entry);
                await WriteImportsAsync(rootKey, state, cancellationToken).ConfigureAwait(false);
            }
            examinations.Remove(examinationId);
            journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "import du pack « " + (exam.Plan.PackName ?? "sans nom") + " » : " + FrenchText.Count(created + copied, "création", "créations") + ", "
                + FrenchText.Count(replaced, "remplacement", "remplacements") + ", " + FrenchText.Count(ignored, "ignorée", "ignorées"), Tone.Ok));
            return (entry, created, replaced, copied, ignored, receipt);
        }
        finally
        {
            gate.Release();
        }
    }

    private static string Clip(string name) => name.Length > QueryLimits.MaxNameLength ? name[..QueryLimits.MaxNameLength] : name;

    private async Task WriteImportsAsync(string rootKey, Loaded state, CancellationToken cancellationToken)
    {
        while (state.Imports.Count > MaxJournal)
        {
            state.Imports.RemoveAt(0);
        }
        JsonElement element;
        while (true)
        {
            element = Element(writer =>
            {
                writer.WriteStartObject();
                writer.WritePropertyName("entries");
                JsonSerializer.Serialize(writer, state.Imports, StoreJson);
                writer.WriteEndObject();
            });
            if (Encoding.UTF8.GetByteCount(element.GetRawText()) <= ImportsBudget || state.Imports.Count <= 1)
            {
                break;
            }
            state.Imports.RemoveAt(0);
        }
        await WriteAsync(ImportsPrefix + rootKey, element, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Imports that can still be undone, newest first (Domenia 1 ConvertFrom-DomeniaQueryImportJournal).</summary>
    public async Task<ImmutableArray<QueryImportEntry>> HistoryAsync(string rootDn, CancellationToken cancellationToken)
    {
        var rootKey = RootKey(rootDn);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = Load(rootKey);
            var rolledBack = state.Imports.Where(e => e.Kind == "rollback" && e.Remaining.Length == 0).Select(e => e.RollsBack).OfType<string>().ToHashSet(StringComparer.Ordinal);
            var available = new List<QueryImportEntry>();
            foreach (var entry in state.Imports)
            {
                if (entry.Kind == "rollback")
                {
                    if (entry.Remaining.Length > 0 && !rolledBack.Contains(entry.ImportId))
                    {
                        available.Add(entry);
                    }
                    continue;
                }
                if (!rolledBack.Contains(entry.ImportId) && !state.Imports.Any(e => e.Kind == "rollback" && e.RollsBack == entry.ImportId))
                {
                    available.Add(entry);
                }
            }
            available.Reverse();
            return [.. available];
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// Restores the library as it was before an import (Domenia 1 « Restaurer avant cet import… »): replaced definitions come back,
    /// creations are removed. A recipe modified since the import is not restored (the rest is, and stays restorable later).
    /// </summary>
    public async Task<(QueryImportEntry Entry, int Restored, int Refused)> RollbackAsync(string rootDn, string importId, CancellationToken cancellationToken)
    {
        var rootKey = RootKey(rootDn);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = Load(rootKey);
            var source = state.Imports.FirstOrDefault(e => e.ImportId == importId) ?? throw new QueryDefinitionException("Import introuvable dans le journal : rien n’a été restauré.");
            var items = source.Kind == "rollback" ? source.Remaining : source.Items;
            if (items.Length == 0)
            {
                throw new QueryDefinitionException("Cet import n’a rien à restaurer.");
            }
            var now = clock.GetUtcNow();
            var restored = new List<QueryImportChange>();
            var remaining = new List<QueryImportChange>();
            foreach (var item in items.OrderByDescending(i => i.Sequence))
            {
                var index = state.Records.FindIndex(r => r.Id == item.Id);
                var current = index >= 0 ? state.Records[index] : null;
                if (current is null || current.Revision != item.Revision)
                {
                    remaining.Add(item);
                    continue;
                }
                if (item.Before is null)
                {
                    state.Records.RemoveAt(index);
                    restored.Add(item);
                    continue;
                }
                QueryRecipe recipe;
                try
                {
                    recipe = QueryRecipeJson.Read(item.Before.Definition);
                    if (QueryEngine.Compile(recipe).Fingerprint != item.Before.DefinitionSha256)
                    {
                        remaining.Add(item);
                        continue;
                    }
                }
                catch (QueryDefinitionException)
                {
                    remaining.Add(item);
                    continue;
                }
                state.Records[index] = current with
                {
                    Name = item.Before.Name,
                    Category = item.Before.Category,
                    Archived = item.Before.Archived,
                    Recipe = recipe,
                    Fingerprint = item.Before.DefinitionSha256,
                    Provenance = item.Before.Provenance,
                    Revision = current.Revision + 1,
                    UpdatedAt = now,
                };
                restored.Add(item);
            }
            if (restored.Count == 0)
            {
                throw new QueryDefinitionException("Restauration refusée : chaque recette de cet import a été modifiée depuis. Rien n’a été restauré.");
            }
            await CommitAsync(rootKey, state, cancellationToken).ConfigureAwait(false);
            var entry = new QueryImportEntry(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)), "rollback", source.Kind == "rollback" ? source.RollsBack : source.ImportId, now,
                source.PackId, source.PackName, source.PackVersion, source.Origin, source.Verified, [.. restored], [.. remaining]);
            state.Imports.Add(entry);
            await WriteImportsAsync(rootKey, state, cancellationToken).ConfigureAwait(false);
            journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "restauration avant l’import « " + (source.PackName ?? "pack sans nom") + " » : " + FrenchText.Count(restored.Count, "recette restaurée", "recettes restaurées")
                + (remaining.Count > 0 ? ", " + FrenchText.Count(remaining.Count, "refusée", "refusées") : ""), remaining.Count > 0 ? Tone.Warn : Tone.Ok));
            return (entry, restored.Count, remaining.Count);
        }
        finally
        {
            gate.Release();
        }
    }
}
