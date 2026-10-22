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

/// <summary>Widget made from a saved recipe (Domenia 1 « sonde dashboard »): board, visual, title and the revision it is bound to.</summary>
public sealed record QueryWidgetLink(string Id, string RecipeId, long BoundRevision, string Board, string Visual, string Title, DateTimeOffset CreatedAt);

/// <summary>
/// Consumer of a saved recipe declared by another screen (Domenia 1 dependencies): a favourite of Recherche (« search », shows
/// the current definition) or a health rule (« health », keeps its revision until refreshed explicitly in Santé).
/// </summary>
public sealed record QueryConsumerLink(string Kind, string Id, string RecipeId, long BoundRevision, string Title, string? Scope, DateTimeOffset BoundAt);

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
    ImmutableArray<QueryRevision> History,
    ImmutableArray<QueryWidgetLink> ArchivedWidgets);

/// <summary>State of a recipe before an import changed it (restore point).</summary>
public sealed record QueryLibrarySnapshot(long Revision, bool Archived, string Category, string Name, string Definition, string DefinitionSha256, QueryProvenance? Provenance);

public sealed record QueryImportChange(string Id, string Name, long Revision, int Sequence, QueryLibrarySnapshot? Before);

/// <summary>One import or rollback of the journal (Domenia 1 Domenia.QueryImportJournal/1).</summary>
public sealed record QueryImportEntry(string ImportId, string Kind, string? RollsBack, DateTimeOffset At, string? PackId, string? PackName, long PackVersion, string? Origin, bool Verified,
    ImmutableArray<QueryImportChange> Items, ImmutableArray<QueryImportChange> Remaining);

/// <summary>Receipt of a library write: stored on disk or for the session only, read back from the medium, revision and fingerprint.</summary>
public sealed record QueryStoreReceipt(bool Persisted, bool ReadBack, long Revision, string Fingerprint, DateTimeOffset SavedAt, string Text);

/// <summary>Consumer of a recipe listed before it changes (Domenia 1 Get-DomeniaQueryRecipeImpact).</summary>
public sealed record QueryImpactRow(string Kind, string Element, string Name, string Link, string ConsumerId);

public sealed record QueryImpact(string RecipeId, long CurrentRevision, bool Changed, ImmutableArray<QueryDifference> Changes, ImmutableArray<QueryImpactRow> Rows, int Widgets, int Orphans, int Views,
    int Alerts, bool HasConsumers, bool TargetChanged);

/// <summary>Examination of a pack (preview only: nothing is written).</summary>
public sealed record QueryImportItem(string Id, string Name, string Status, string StatusLabel, string ChangeSummary, ImmutableArray<QueryDifference> Changes, ImmutableArray<string> AllowedActions,
    string DefaultAction, long ExpectedRevision);

public sealed record QueryImportPlan(string ExaminationId, string Format, string? PackId, string? PackName, long PackVersion, string? Origin, string? ExportedAt, bool Verified, string Integrity,
    long PreviousVersion, ImmutableArray<QueryImportItem> Items, DateTimeOffset ExpiresAt);

/// <summary>Everything the library holds for one domain (read once per change of the stored document).</summary>
public sealed record QueryLibraryContent(IReadOnlyList<QueryLibraryRecord> Records, IReadOnlyList<QueryWidgetLink> Widgets, IReadOnlyList<QueryConsumerLink> Consumers, int Unreadable);

/// <summary>Widget asked together with a save (recipe and link written in the same document, Domenia 1 atomic batch).</summary>
public sealed record QueryWidgetRequest(string Board, string Visual, string Title);

/// <summary>Result of a save: the record, its receipt, whether something was written, the widget linked and the links dropped.</summary>
public sealed record QuerySaveResult(QueryLibraryRecord Record, QueryStoreReceipt Receipt, bool Written, QueryWidgetLink? Widget, ImmutableArray<QueryWidgetLink> Dropped, int Migrated);

/// <summary>Prepared pack: content, file name, number of recipes and the version to propose once the file is saved.</summary>
public sealed record QueryPackExport(string Json, string FileName, int Count, string PackId, long Version, long NextVersion);

/// <summary>
/// Local library of recipes for the domain of the session (LocalWrite, never the directory): personal recipes with revisions,
/// archives with the widgets they removed, widget links, consumers declared by other screens, the import journal with restore
/// points and the proposed version of each pack. One document per domain in its own medium (<see cref="IQueryLibraryStore"/>):
/// every write is a read-modify-write of the document as it is on the medium, under a lock shared by every Domenia process,
/// the expected revision is checked against that fresh state, the recipe and its links go in the same atomic write, and the
/// receipt says « relue » only when the medium gave the written document back. A write the medium refuses changes nothing
/// and says so: the draft stays in the workshop.
/// </summary>
public sealed class QueryLibrary : IDisposable
{
    public const string DocumentFormat = "domenia.queryLibrary";
    public const int DocumentVersion = 2;

    /// <summary>Largest library document of one domain (Domenia 1 packs: 16 Mio).</summary>
    public const int MaxDocumentBytes = 16 * 1024 * 1024;

    public const int MaxHistory = 5;

    /// <summary>Import journal entries kept (Domenia 1 .query-imports.jsonl: 40 lines).</summary>
    public const int MaxJournal = 40;

    public const int MaxRecipes = 5000;
    public const int MaxWidgets = 64;
    public const int MaxConsumers = 249;
    public const string PackFormat = "Domenia.QueryPack/3";
    public const string ImpactRequiredPrefix = "Des widgets utilisent cette requête";
    public const string StoreFailedPrefix = "Bibliothèque locale non enregistrée";
    private static readonly TimeSpan ExaminationLife = TimeSpan.FromMinutes(30);

    private readonly IQueryLibraryStore store;
    private readonly OperationJournal journal;
    private readonly TimeProvider clock;
    private readonly ITechnicalJournal log;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<string, (string Hash, State State)> cache = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (QueryImportPlan Plan, ImmutableArray<QueryRecipe> Recipes, string RootKey)> examinations = new(StringComparer.Ordinal);

    /// <summary>One domain document, parsed. Mutable only inside a write (a fresh copy read from the medium under the lock).</summary>
    private sealed class State
    {
        public long Generation { get; set; }

        public List<QueryLibraryRecord> Records { get; } = [];

        public List<QueryWidgetLink> Widgets { get; } = [];

        public List<QueryConsumerLink> Consumers { get; } = [];

        public List<QueryImportEntry> Imports { get; } = [];

        public SortedDictionary<string, long> PackVersions { get; } = new(StringComparer.Ordinal);

        /// <summary>Entries that cannot be read (bad definition, older or damaged): kept as they are, never dropped by a write.</summary>
        public List<JsonElement> Unreadable { get; } = [];

        /// <summary>The whole document cannot be used (bad JSON, unknown format): its values are ignored, it is kept aside before a write.</summary>
        public bool WholeUnreadable { get; set; }

        /// <summary>Written by a later version of Domenia: read only, never replaced.</summary>
        public bool Newer { get; set; }

        public bool Dirty { get; set; }
    }

    public QueryLibrary(IQueryLibraryStore store, OperationJournal journal, TimeProvider clock, ITechnicalJournal log)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(journal);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        this.store = store;
        this.journal = journal;
        this.clock = clock;
        this.log = log;
    }

    public bool Persistent => store.Persistent;

    public void Dispose() => gate.Dispose();

    /// <summary>Hash of a domain root used to key its document (same rule as the working OU).</summary>
    public static string RootKey(string rootDn)
    {
        ArgumentNullException.ThrowIfNull(rootDn);
        var canonical = DistinguishedName.Format(DistinguishedName.Parse(rootDn)).ToUpperInvariant();
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
    }

    /// <summary>Stable identity of a named pack across its versions (Domenia 1 Get-DomeniaQueryPackId).</summary>
    public static string PackId(string name) => QueryRecipeJson.Sha256("Domenia.QueryPack|" + FrenchText.Fold(name ?? "").Trim())[..32];

    // ---------- Reading ----------

    /// <summary>Personal recipes and archives of the domain, widgets and consumers, as stored now.</summary>
    public async Task<QueryLibraryContent> ReadAsync(string rootDn, CancellationToken cancellationToken)
    {
        var state = await LoadAsync(RootKey(rootDn), cancellationToken).ConfigureAwait(false);
        return new QueryLibraryContent([.. state.Records], [.. state.Widgets], [.. state.Consumers], state.Unreadable.Count + (state.WholeUnreadable ? 1 : 0));
    }

    public async Task<QueryLibraryRecord?> FindAsync(string rootDn, string id, CancellationToken cancellationToken)
    {
        var content = await ReadAsync(rootDn, cancellationToken).ConfigureAwait(false);
        return content.Records.FirstOrDefault(r => string.Equals(r.Id, id, StringComparison.Ordinal));
    }

    /// <summary>Recent personal recipes (Domenia 1 « Charger » : the 100 most recently revised), newest first.</summary>
    public async Task<ImmutableArray<QueryLibraryRecord>> RecentAsync(string rootDn, int count, CancellationToken cancellationToken)
    {
        var content = await ReadAsync(rootDn, cancellationToken).ConfigureAwait(false);
        return [.. content.Records.Where(r => !r.Archived).OrderByDescending(r => r.UpdatedAt).ThenBy(r => r.Id, StringComparer.Ordinal).Take(Math.Max(1, Math.Min(count, 100)))];
    }

    private async Task<State> LoadAsync(string rootKey, CancellationToken cancellationToken)
    {
        byte[]? bytes;
        try
        {
            bytes = await store.ReadAsync(rootKey, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Bibliothèque de requêtes non lue : {ex.GetType().Name}.");
            throw new QueryDefinitionException(StoreFailedPrefix + FrenchText.Colon + "le fichier de la bibliothèque ne peut pas être lu pour l’instant (verrouillé ou droits). Réessayez ; rien n’a été changé.");
        }
        var hash = bytes is null ? "" : Convert.ToHexStringLower(SHA256.HashData(bytes));
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (cache.TryGetValue(rootKey, out var entry) && entry.Hash == hash)
            {
                return entry.State;
            }
            var state = Parse(bytes);
            cache[rootKey] = (hash, state);
            return state;
        }
        finally
        {
            gate.Release();
        }
    }

    private static readonly JsonSerializerOptions StoreJson = CreateStoreJson();

    private static JsonSerializerOptions CreateStoreJson()
    {
        var options = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = false, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
        options.Converters.Add(new System.Text.Json.Serialization.JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        options.MakeReadOnly(populateMissingResolver: true);
        return options;
    }

    private State Parse(byte[]? bytes)
    {
        var state = new State();
        if (bytes is null || bytes.Length == 0)
        {
            return state;
        }
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 96 });
        }
        catch (JsonException)
        {
            log.Warning("Bibliothèque de requêtes illisible (JSON) : valeurs ignorées ; le fichier sera mis de côté avant la prochaine écriture.");
            state.WholeUnreadable = true;
            return state;
        }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || Text(root, "format", "") != DocumentFormat || !root.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number)
            {
                log.Warning("Bibliothèque de requêtes illisible (format inconnu) : valeurs ignorées ; le fichier sera mis de côté avant la prochaine écriture.");
                state.WholeUnreadable = true;
                return state;
            }
            if (!version.TryGetInt32(out var number) || number > DocumentVersion)
            {
                log.Warning("Bibliothèque de requêtes écrite par une version plus récente : lecture seule.");
                state.Newer = true;
            }
            state.Generation = root.TryGetProperty("generation", out var generation) && generation.TryGetInt64(out var g) ? g : 0;
            ReadArray(root, "recipes", item => ReadRecord(item, state), state);
            ReadArray(root, "widgets", item =>
            {
                var link = item.Deserialize<QueryWidgetLink>(StoreJson);
                if (link is null || link.Id.Length is 0 or > 64 || link.RecipeId.Length is 0 or > 80)
                {
                    return false;
                }
                state.Widgets.Add(link);
                return true;
            }, state);
            ReadArray(root, "consumers", item =>
            {
                var link = item.Deserialize<QueryConsumerLink>(StoreJson);
                if (link is null || link.Kind is not ("search" or "health") || link.Id.Length is 0 or > 64)
                {
                    return false;
                }
                state.Consumers.Add(link);
                return true;
            }, state);
            ReadArray(root, "imports", item =>
            {
                if (item.Deserialize<QueryImportEntry>(StoreJson) is not { } entry || entry.ImportId.Length != 32)
                {
                    return false;
                }
                state.Imports.Add(entry);
                return true;
            }, state);
            if (root.TryGetProperty("packVersions", out var packs) && packs.ValueKind == JsonValueKind.Object)
            {
                foreach (var pack in packs.EnumerateObject())
                {
                    if (pack.Name.Length == 32 && pack.Value.TryGetInt64(out var next) && next is >= 1 and <= 1_000_000)
                    {
                        state.PackVersions[pack.Name] = next;
                    }
                }
            }
            if (root.TryGetProperty("unreadable", out var kept) && kept.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in kept.EnumerateArray().Take(10_000))
                {
                    state.Unreadable.Add(item.Clone());
                }
            }
        }
        if (state.Unreadable.Count > 0)
        {
            log.Warning($"Bibliothèque de requêtes : {state.Unreadable.Count} enregistrement(s) illisible(s) conservé(s) tel(s) quel(s), sans être utilisé(s).");
        }
        return state;
    }

    private static void ReadArray(JsonElement root, string name, Func<JsonElement, bool> read, State state)
    {
        if (!root.TryGetProperty(name, out var list) || list.ValueKind != JsonValueKind.Array)
        {
            return;
        }
        foreach (var item in list.EnumerateArray())
        {
            bool ok;
            try
            {
                ok = read(item);
            }
            catch (Exception ex) when (ex is JsonException or QueryDefinitionException or KeyNotFoundException or InvalidOperationException or FormatException or NotSupportedException)
            {
                ok = false;
            }
            if (!ok)
            {
                // Kept as it is (with the collection it came from), so a later write never loses it.
                state.Unreadable.Add(JsonSerializer.SerializeToElement(new { from = name, value = item }));
            }
        }
    }

    private static bool ReadRecord(JsonElement item, State state)
    {
        var definition = item.GetProperty("definition").GetString() ?? "";
        var recipe = QueryRecipeJson.Read(definition);
        var compiled = QueryEngine.Compile(recipe);
        var fingerprint = item.GetProperty("fingerprint").GetString() ?? "";
        if (!string.Equals(fingerprint, compiled.Fingerprint, StringComparison.Ordinal) || recipe.Id.StartsWith(QueryTemplates.Prefix, StringComparison.Ordinal)
            || state.Records.Any(r => r.Id == recipe.Id))
        {
            return false;
        }
        var history = item.TryGetProperty("history", out var h) && h.ValueKind == JsonValueKind.Array
            ? h.EnumerateArray().Select(x => x.Deserialize<QueryRevision>(StoreJson)).OfType<QueryRevision>().ToImmutableArray()
            : [];
        var archivedWidgets = item.TryGetProperty("archivedWidgets", out var w) && w.ValueKind == JsonValueKind.Array
            ? w.EnumerateArray().Select(x => x.Deserialize<QueryWidgetLink>(StoreJson)).OfType<QueryWidgetLink>().ToImmutableArray()
            : [];
        var provenance = item.TryGetProperty("provenance", out var p) && p.ValueKind == JsonValueKind.Object ? p.Deserialize<QueryProvenance>(StoreJson) : null;
        state.Records.Add(new QueryLibraryRecord(recipe.Id, recipe.Name, Text(item, "category", "Mes requêtes"), Text(item, "description", ""), item.GetProperty("revision").GetInt64(),
            item.GetProperty("createdAt").GetDateTimeOffset(), item.GetProperty("updatedAt").GetDateTimeOffset(), item.TryGetProperty("archived", out var a) && a.ValueKind == JsonValueKind.True,
            fingerprint, recipe, provenance, history, archivedWidgets));
        return true;
    }

    private static string Text(JsonElement item, string name, string fallback) =>
        item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? fallback : fallback;

    // ---------- Writing ----------

    private static byte[] Serialize(State state, string rootKey, DateTimeOffset now)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            writer.WriteStartObject();
            writer.WriteString("format", DocumentFormat);
            writer.WriteNumber("version", DocumentVersion);
            writer.WriteNumber("generation", state.Generation);
            writer.WriteString("domainKey", rootKey);
            writer.WriteString("savedAt", now);
            writer.WriteStartArray("recipes");
            foreach (var record in state.Records)
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
                if (record.ArchivedWidgets.Length > 0)
                {
                    writer.WritePropertyName("archivedWidgets");
                    JsonSerializer.Serialize(writer, record.ArchivedWidgets, StoreJson);
                }
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WritePropertyName("widgets");
            JsonSerializer.Serialize(writer, state.Widgets, StoreJson);
            writer.WritePropertyName("consumers");
            JsonSerializer.Serialize(writer, state.Consumers, StoreJson);
            writer.WritePropertyName("imports");
            JsonSerializer.Serialize(writer, state.Imports, StoreJson);
            writer.WriteStartObject("packVersions");
            foreach (var (pack, next) in state.PackVersions)
            {
                writer.WriteNumber(pack, next);
            }
            writer.WriteEndObject();
            writer.WriteStartArray("unreadable");
            foreach (var item in state.Unreadable)
            {
                item.WriteTo(writer);
            }
            writer.WriteEndArray();
            writer.WriteEndObject();
        }
        return buffer.WrittenSpan.ToArray();
    }

    /// <summary>The document within its budget: the oldest revisions go first, the current definitions are never dropped.</summary>
    private static byte[] Fit(State state, string rootKey, DateTimeOffset now)
    {
        var bytes = Serialize(state, rootKey, now);
        while (bytes.Length > MaxDocumentBytes && state.Records.Any(r => r.History.Length > 0))
        {
            var longest = state.Records.Max(x => x.History.Length);
            for (var i = 0; i < state.Records.Count; i++)
            {
                if (state.Records[i].History.Length == longest)
                {
                    state.Records[i] = state.Records[i] with { History = state.Records[i].History.RemoveAt(state.Records[i].History.Length - 1) };
                }
            }
            bytes = Serialize(state, rootKey, now);
        }
        while (bytes.Length > MaxDocumentBytes && state.Imports.Count > 1)
        {
            state.Imports.RemoveAt(0);
            bytes = Serialize(state, rootKey, now);
        }
        if (bytes.Length > MaxDocumentBytes)
        {
            throw new QueryDefinitionException("Bibliothèque locale pleine (16 Mio) : archivez puis exportez des requêtes avant d’en enregistrer d’autres. Rien n’a été écrit.");
        }
        return bytes;
    }

    /// <summary>
    /// One write of a domain document: <paramref name="change"/> runs on the document read from the medium under the exclusive
    /// lock (revisions are checked against it), and the result is written atomically then read back. Nothing is written when
    /// <paramref name="change"/> throws or leaves the document unchanged.
    /// </summary>
    private async Task<(T Result, QueryStoreWrite? Write)> MutateAsync<T>(string rootKey, Func<State, T> change, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            T result = default!;
            State? written = null;
            byte[]? bytes = null;
            QueryStoreWrite? write;
            try
            {
                write = await store.UpdateAsync(rootKey, current =>
                {
                    var state = Parse(current);
                    if (state.Newer)
                    {
                        throw new QueryDefinitionException("La bibliothèque de ce domaine a été écrite par une version plus récente de Domenia : elle reste en lecture seule ici. Rien n’a été écrit.");
                    }
                    var keepAside = state.WholeUnreadable;
                    result = change(state);
                    if (!state.Dirty)
                    {
                        return null;
                    }
                    state.Generation++;
                    state.WholeUnreadable = false;
                    state.Dirty = false;
                    bytes = Fit(state, rootKey, clock.GetUtcNow());
                    written = state;
                    return new QueryStoreUpdate(bytes, keepAside);
                }, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                log.Warning($"Bibliothèque de requêtes non enregistrée : {ex.GetType().Name}.");
                journal.Add(new JournalEntry(clock.GetUtcNow(), "Requêtes" + FrenchText.Colon + "bibliothèque non enregistrée (disque, droits ou fichier verrouillé), rien n’a été écrit", Tone.Warn));
                throw new QueryDefinitionException(StoreFailedPrefix + " (disque plein, droits ou fichier verrouillé par une autre application) : rien n’a été écrit. Votre brouillon reste dans l’atelier ; réessayez.");
            }
            if (written is not null && bytes is not null)
            {
                cache[rootKey] = (Convert.ToHexStringLower(SHA256.HashData(bytes)), written);
            }
            return (result, write);
        }
        finally
        {
            gate.Release();
        }
    }

    private QueryStoreReceipt Receipt(QueryStoreWrite? write, QueryLibraryRecord record, DateTimeOffset at)
    {
        var persisted = write?.Persisted ?? store.Persistent;
        var readBack = write?.ReadBack ?? true;
        var revision = "Révision " + FrenchText.Integer(record.Revision);
        var text = !persisted
            ? revision + " valable pour cette session seulement : ce mode n’enregistre rien sur le disque (capture, E2E ou sans dossier de données)."
            : readBack
                ? revision + " enregistrée dans la bibliothèque locale et relue sur le disque (empreinte " + record.Fingerprint[..12] + ")."
                : revision + " envoyée à la bibliothèque locale, mais la relecture du disque diffère : relisez la bibliothèque avant de continuer.";
        return new QueryStoreReceipt(persisted, readBack, record.Revision, record.Fingerprint, at, text);
    }

    private static QueryDefinitionException RevisionChanged(long current) =>
        new("La requête a changé depuis sa lecture (révision " + FrenchText.Integer(current) + ") : relisez-la avant d’enregistrer. Rien n’a été écrit.");

    private static void CheckWidget(QueryWidgetRequest widget, QueryTarget target)
    {
        if (widget.Board is not ("fleet" or "computer") || widget.Visual is not ("kpi" or "text" or "bar" or "pie" or "column"))
        {
            throw new QueryDefinitionException("Destination ou représentation de widget inconnue.");
        }
        if (widget.Board == "computer" && target != QueryTarget.Computer)
        {
            throw new QueryDefinitionException("Le tableau de bord d’un poste n’accepte que les requêtes sur les postes.");
        }
        if (!QueryFormat.CleanText(widget.Title, 80))
        {
            throw new QueryDefinitionException("Titre de widget invalide (1 à 80 caractères, sans caractère de contrôle).");
        }
    }

    /// <summary>A widget can only be shown on a board that accepts the recipe target (the computer board takes computers only).</summary>
    public static bool Displayable(QueryWidgetLink widget, QueryTarget target)
    {
        ArgumentNullException.ThrowIfNull(widget);
        return widget.Board == "fleet" || target == QueryTarget.Computer;
    }

    /// <summary>
    /// Saves a recipe (Domenia 1 Save-DomeniaQueryRecipe): a new revision of a personal recipe, or a personal copy of a delivered
    /// model. <paramref name="mode"/> « update » keeps the identifier and is refused when widgets evaluate the current revision
    /// and the definition changes (the impact review must choose); « copy » saves a new independent recipe « (nouvelle version) »
    /// and leaves the saved one and its consumers untouched; « migrate » binds the linked widgets to the new revision (those no
    /// longer displayable for the target are dropped and returned). <paramref name="widget"/> is linked in the same write. An
    /// unchanged definition writes nothing (except a new widget).
    /// </summary>
    public async Task<QuerySaveResult> SaveAsync(string rootDn, QueryRecipe recipe, string? category, string? description, long expectedRevision, string mode, QueryWidgetRequest? widget,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        var cat = string.IsNullOrWhiteSpace(category) ? null : category.Trim();
        if (cat is not null && !QueryFormat.CleanText(cat, 80))
        {
            throw new QueryDefinitionException("Catégorie de bibliothèque invalide (80 caractères, sans caractère de contrôle).");
        }
        var desc = description?.Trim();
        if (desc is not null && (desc.Length > 500 || desc.Any(c => char.IsControl(c) && c != '\n')))
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
        if (widget is not null)
        {
            CheckWidget(widget, normalized.Target);
        }
        var rootKey = RootKey(rootDn);
        var now = clock.GetUtcNow();
        var (result, write) = await MutateAsync(rootKey, state =>
        {
            var index = state.Records.FindIndex(r => string.Equals(r.Id, normalized.Id, StringComparison.Ordinal));
            var existing = index >= 0 ? state.Records[index] : null;
            var currentRevision = existing?.Revision ?? 0;
            if (currentRevision != expectedRevision)
            {
                throw RevisionChanged(currentRevision);
            }
            if (existing is null && state.Records.Count >= MaxRecipes)
            {
                throw new QueryDefinitionException("La bibliothèque locale contient déjà 5 000 requêtes : archivez ou exportez avant d’en ajouter. Rien n’a été écrit.");
            }
            var bound = state.Widgets.Where(w => w.RecipeId == normalized.Id).ToList();
            var definitionChanged = existing is null || existing.Fingerprint != compiled.Fingerprint;
            if (existing is not null && !existing.Archived && definitionChanged && mode == "update" && bound.Count > 0)
            {
                throw new QueryDefinitionException(ImpactRequiredPrefix + " (" + FrenchText.Count(bound.Count, "widget lié", "widgets liés")
                    + ") : ouvrez la revue d’impact et choisissez de mettre à jour les widgets ou d’enregistrer une copie. Rien n’a été écrit.");
            }
            var finalCategory = cat ?? existing?.Category ?? "Mes requêtes";
            var finalDescription = desc ?? existing?.Description ?? "";
            QueryLibraryRecord record;
            var written = true;
            if (existing is not null && !existing.Archived && !definitionChanged && existing.Category == finalCategory && existing.Description == finalDescription)
            {
                record = existing;
                written = false;
            }
            else
            {
                var history = existing is null ? [] : existing.History.Insert(0, new QueryRevision(existing.Revision, existing.UpdatedAt, existing.Fingerprint, QueryRecipeJson.Write(existing.Recipe)));
                if (history.Length > MaxHistory)
                {
                    history = history.RemoveRange(MaxHistory, history.Length - MaxHistory);
                }
                record = new QueryLibraryRecord(normalized.Id, normalized.Name, finalCategory, finalDescription, currentRevision + 1, existing?.CreatedAt ?? now, now, false, compiled.Fingerprint,
                    normalized, existing?.Provenance, history, existing?.ArchivedWidgets ?? []);
                if (index >= 0)
                {
                    state.Records[index] = record;
                }
                else
                {
                    state.Records.Add(record);
                }
                state.Dirty = true;
            }
            var dropped = ImmutableArray.CreateBuilder<QueryWidgetLink>();
            var migrated = 0;
            if (mode == "migrate" && written)
            {
                for (var i = state.Widgets.Count - 1; i >= 0; i--)
                {
                    var link = state.Widgets[i];
                    if (link.RecipeId != record.Id)
                    {
                        continue;
                    }
                    if (!Displayable(link, record.Recipe.Target))
                    {
                        dropped.Add(link);
                        state.Widgets.RemoveAt(i);
                        continue;
                    }
                    state.Widgets[i] = link with { BoundRevision = record.Revision };
                    migrated++;
                }
            }
            QueryWidgetLink? linked = null;
            if (widget is not null)
            {
                var at = state.Widgets.FindIndex(w => w.RecipeId == record.Id && w.Board == widget.Board);
                linked = new QueryWidgetLink(at >= 0 ? state.Widgets[at].Id : Guid.NewGuid().ToString("N"), record.Id, record.Revision, widget.Board, widget.Visual, widget.Title.Trim(), now);
                if (at >= 0)
                {
                    state.Widgets[at] = linked;
                }
                else
                {
                    if (state.Widgets.Count >= MaxWidgets)
                    {
                        throw new QueryDefinitionException("64 widgets de requêtes au plus : retirez-en un avant d’en ajouter. Rien n’a été écrit.");
                    }
                    state.Widgets.Add(linked);
                }
                state.Dirty = true;
            }
            return (record, written, linked, dropped.ToImmutable(), migrated);
        }, cancellationToken).ConfigureAwait(false);
        var (saved, wrote, linkedWidget, droppedWidgets, migratedCount) = result;
        if (wrote)
        {
            journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "« " + saved.Name + " » enregistrée (révision " + FrenchText.Integer(saved.Revision) + ")"
                + (migratedCount > 0 ? ", " + FrenchText.Count(migratedCount, "widget mis à jour", "widgets mis à jour") : ""), Tone.Ok));
        }
        if (linkedWidget is not null)
        {
            journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "widget « " + linkedWidget.Title + " » ajouté au " + (linkedWidget.Board == "fleet" ? "tableau de bord général" : "tableau de bord du poste"), Tone.Ok));
        }
        return new QuerySaveResult(saved, Receipt(write, saved, wrote ? now : saved.UpdatedAt), wrote, linkedWidget, droppedWidgets, migratedCount);
    }

    /// <summary>
    /// Archives a recipe (revisions kept) and detaches its widgets in the same write (Domenia 1 archive); the removed widgets
    /// stay with the archived record, so a restore (from the receipt or from the library) brings them back.
    /// </summary>
    public async Task<(QueryLibraryRecord Record, QueryStoreReceipt Receipt, ImmutableArray<QueryWidgetLink> Removed)> ArchiveAsync(string rootDn, string id, long expectedRevision, CancellationToken cancellationToken)
    {
        if (id.StartsWith(QueryTemplates.Prefix, StringComparison.Ordinal))
        {
            throw new QueryDefinitionException(QueryErrors.TemplateReadOnlyMessage);
        }
        var now = clock.GetUtcNow();
        var ((record, removed, changed), write) = await MutateAsync(RootKey(rootDn), state =>
        {
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
                return (existing, ImmutableArray<QueryWidgetLink>.Empty, false);
            }
            var taken = state.Widgets.Where(w => w.RecipeId == id).ToImmutableArray();
            state.Widgets.RemoveAll(w => w.RecipeId == id);
            var archived = existing with { Archived = true, Revision = existing.Revision + 1, UpdatedAt = now, ArchivedWidgets = taken };
            state.Records[index] = archived;
            state.Dirty = true;
            return (archived, taken, true);
        }, cancellationToken).ConfigureAwait(false);
        if (changed)
        {
            journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "« " + record.Name + " » archivée" + (removed.Length > 0 ? ", " + FrenchText.Count(removed.Length, "widget retiré", "widgets retirés") : ""), Tone.Info));
        }
        return (record, Receipt(write, record, changed ? now : record.UpdatedAt), removed);
    }

    /// <summary>Restores an archived recipe with a new revision; <paramref name="restoreWidgets"/> brings back the widgets its archive removed.</summary>
    public async Task<(QueryLibraryRecord Record, QueryStoreReceipt Receipt, ImmutableArray<QueryWidgetLink> Restored)> RestoreAsync(string rootDn, string id, long expectedRevision, bool restoreWidgets,
        CancellationToken cancellationToken)
    {
        var now = clock.GetUtcNow();
        var ((record, restored), write) = await MutateAsync(RootKey(rootDn), state =>
        {
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
            if (!existing.Archived)
            {
                throw new QueryDefinitionException("Cette requête n’est pas archivée : rien à restaurer.");
            }
            var back = ImmutableArray.CreateBuilder<QueryWidgetLink>();
            var revision = existing.Revision + 1;
            if (restoreWidgets)
            {
                foreach (var widget in existing.ArchivedWidgets)
                {
                    if (state.Widgets.Count < MaxWidgets && state.Widgets.All(x => x.Id != widget.Id) && Displayable(widget, existing.Recipe.Target))
                    {
                        var again = widget with { BoundRevision = revision };
                        state.Widgets.Add(again);
                        back.Add(again);
                    }
                }
            }
            var active = existing with { Archived = false, Revision = revision, UpdatedAt = now, ArchivedWidgets = restoreWidgets ? [] : existing.ArchivedWidgets };
            state.Records[index] = active;
            state.Dirty = true;
            return (active, back.ToImmutable());
        }, cancellationToken).ConfigureAwait(false);
        journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "« " + record.Name + " » restaurée (révision " + FrenchText.Integer(record.Revision) + ")"
            + (restored.Length > 0 ? " avec " + FrenchText.Count(restored.Length, "widget", "widgets") : ""), Tone.Ok));
        return (record, Receipt(write, record, now), restored);
    }

    /// <summary>Restores one earlier revision of a recipe as a new revision (history panel), with the impact choice of the page.</summary>
    public async Task<QuerySaveResult> RevertAsync(string rootDn, string id, long revision, long expectedRevision, string mode, CancellationToken cancellationToken)
    {
        var record = await FindAsync(rootDn, id, cancellationToken).ConfigureAwait(false) ?? throw new QueryDefinitionException(QueryErrors.NotFoundMessage);
        var old = record.History.FirstOrDefault(h => h.Revision == revision) ?? throw new QueryDefinitionException("Révision introuvable dans l’historique conservé. Rien n’a été écrit.");
        var recipe = QueryRecipeJson.Read(old.Definition) with { Id = id };
        return await SaveAsync(rootDn, recipe, record.Category, record.Description, expectedRevision, mode == "migrate" ? "migrate" : "update", null, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>A stored revision of a recipe (current or kept in its history), for a widget bound to an older revision.</summary>
    public static QueryRecipe? RevisionRecipe(QueryLibraryRecord record, long revision)
    {
        ArgumentNullException.ThrowIfNull(record);
        if (record.Revision == revision)
        {
            return record.Recipe;
        }
        var old = record.History.FirstOrDefault(h => h.Revision == revision);
        if (old is null)
        {
            return null;
        }
        try
        {
            return QueryRecipeJson.Read(old.Definition) with { Id = record.Id };
        }
        catch (QueryDefinitionException)
        {
            return null;
        }
    }

    // ---------- Widgets and consumers ----------

    public async Task<bool> UnlinkWidgetAsync(string rootDn, string widgetId, CancellationToken cancellationToken)
    {
        var now = clock.GetUtcNow();
        var (removed, _) = await MutateAsync(RootKey(rootDn), state =>
        {
            var link = state.Widgets.FirstOrDefault(w => w.Id == widgetId);
            if (link is null)
            {
                return null;
            }
            state.Widgets.Remove(link);
            state.Dirty = true;
            return link;
        }, cancellationToken).ConfigureAwait(false);
        if (removed is not null)
        {
            journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "widget « " + removed.Title + " » retiré", Tone.Info));
        }
        return removed is not null;
    }

    /// <summary>
    /// Declares (or renews) a consumer of a saved recipe for another screen: a favourite of Recherche or a health rule, bound to
    /// the current revision. Listed by the impact review; never changes the recipe.
    /// </summary>
    public async Task<QueryConsumerLink> BindConsumerAsync(string rootDn, string kind, string id, string recipeId, string title, string? scope, CancellationToken cancellationToken)
    {
        if (kind is not ("search" or "health") || id.Length is 0 or > 64 || !id.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-'))
        {
            throw new QueryDefinitionException(QueryTexts.InvalidMessage("consommateur inconnu (recherche ou santé, identifiant de 64 caractères au plus)."));
        }
        if (!QueryFormat.CleanText(title, 120))
        {
            throw new QueryDefinitionException(QueryTexts.InvalidMessage("titre du consommateur invalide (120 caractères)."));
        }
        var now = clock.GetUtcNow();
        var (link, _) = await MutateAsync(RootKey(rootDn), state =>
        {
            var record = state.Records.FirstOrDefault(r => r.Id == recipeId && !r.Archived) ?? throw new QueryDefinitionException(QueryErrors.NotFoundMessage);
            var at = state.Consumers.FindIndex(c => c.Kind == kind && c.Id == id);
            var bound = new QueryConsumerLink(kind, id, recipeId, record.Revision, title.Trim(), scope, now);
            if (at >= 0)
            {
                state.Consumers[at] = bound;
            }
            else
            {
                if (state.Consumers.Count >= MaxConsumers)
                {
                    throw new QueryDefinitionException("249 éléments liés au plus dans la bibliothèque : retirez-en avant d’en ajouter. Rien n’a été écrit.");
                }
                state.Consumers.Add(bound);
            }
            state.Dirty = true;
            return bound;
        }, cancellationToken).ConfigureAwait(false);
        return link;
    }

    public async Task<bool> ReleaseConsumerAsync(string rootDn, string kind, string id, CancellationToken cancellationToken)
    {
        var (removed, _) = await MutateAsync(RootKey(rootDn), state =>
        {
            var count = state.Consumers.RemoveAll(c => c.Kind == kind && c.Id == id);
            state.Dirty = count > 0;
            return count > 0;
        }, cancellationToken).ConfigureAwait(false);
        return removed;
    }

    /// <summary>
    /// Consumers of a recipe before it changes or is archived (Domenia 1 Get-DomeniaQueryRecipeImpact): widgets of the general
    /// and workstation boards with the revision they are bound to, links that can no longer be shown (a workstation widget of
    /// a recipe whose target changes), favourites of Recherche and the frozen selection, health rules (which keep their
    /// revision). <paramref name="draft"/> tells what would change.
    /// </summary>
    public async Task<QueryImpact> ImpactAsync(string rootDn, string id, QueryRecipe? draft, string? searchRecipeId, CancellationToken cancellationToken)
    {
        var content = await ReadAsync(rootDn, cancellationToken).ConfigureAwait(false);
        var record = content.Records.FirstOrDefault(r => r.Id == id);
        var rows = ImmutableArray.CreateBuilder<QueryImpactRow>();
        var current = record?.Revision ?? 0;
        var compiledDraft = draft is null ? null : QueryEngine.Compile(draft);
        var target = compiledDraft?.Target ?? record?.Recipe.Target ?? QueryTarget.Computer;
        int widgets = 0, orphans = 0, views = 0, alerts = 0;
        foreach (var widget in content.Widgets.Where(w => w.RecipeId == id))
        {
            var board = widget.Board == "fleet" ? "Tableau de bord général" : "Tableau de bord du poste";
            if (record is null)
            {
                orphans++;
                rows.Add(new QueryImpactRow("orphan", board, widget.Title, "Requête absente de la bibliothèque : le widget ne peut plus être évalué", widget.Id));
                continue;
            }
            if (!Displayable(widget, target))
            {
                orphans++;
                rows.Add(new QueryImpactRow("orphan", board, widget.Title, "Ne peut plus s’afficher pour la cible « " + QueryTexts.TargetLabel(target) + " » : il sera retiré si vous mettez à jour", widget.Id));
                continue;
            }
            widgets++;
            var link = widget.BoundRevision < current ? "Lié à une ancienne révision (" + FrenchText.Integer(widget.BoundRevision) + ")" : "Lié à la révision " + FrenchText.Integer(widget.BoundRevision);
            rows.Add(new QueryImpactRow("widget", board, widget.Title, link, widget.Id));
        }
        foreach (var consumer in content.Consumers.Where(c => c.RecipeId == id))
        {
            if (consumer.Kind == "search")
            {
                views++;
                rows.Add(new QueryImpactRow("view", "Vue de Recherche", consumer.Title, "Favori de la liste des requêtes : affiche la définition courante", consumer.Id));
            }
            else
            {
                alerts++;
                rows.Add(new QueryImpactRow("health", "Santé" + (consumer.Scope is { Length: > 0 } scope ? " · " + scope : ""), consumer.Title,
                    "Révision " + FrenchText.Integer(consumer.BoundRevision) + " conservée ; actualisation explicite dans Santé", consumer.Id));
            }
        }
        if (searchRecipeId == id)
        {
            views++;
            rows.Add(new QueryImpactRow("view", "Vue de Recherche", "Sélection figée appliquée aux résultats", "Garde les GUID figés à son application", "search"));
        }
        var changes = compiledDraft is null || record is null ? [] : QueryAnalysis.Compare(record.Recipe, compiledDraft.Normalized);
        var changed = record is null || compiledDraft is null || compiledDraft.Fingerprint != record.Fingerprint;
        var targetChanged = record is not null && compiledDraft is not null && compiledDraft.Target != record.Recipe.Target;
        return new QueryImpact(id, current, changed, changes, rows.ToImmutable(), widgets, orphans, views, alerts, rows.Count > 0, targetChanged);
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
    /// Versioned, self-checking pack of personal recipes (data only: importing it never executes anything). Nothing is written:
    /// the proposed version of the next export moves on only once the file is saved (<see cref="ConfirmPackExportAsync"/>).
    /// </summary>
    public async Task<QueryPackExport> ExportPackAsync(string rootDn, string domainDn, string name, long version, IReadOnlyCollection<string>? ids, string? origin, CancellationToken cancellationToken)
    {
        name = (name ?? "").Trim();
        if (!QueryFormat.CleanText(name, 80))
        {
            throw new QueryDefinitionException("Nom de pack invalide (1 à 80 caractères, sans caractère de contrôle).");
        }
        if (version is < 1 or > 1000000)
        {
            throw new QueryDefinitionException("Version de pack invalide (nombre entier de 1 à 1 000 000).");
        }
        if (origin is not null && !QueryFormat.CleanText(origin, 256, allowEmpty: true))
        {
            throw new QueryDefinitionException("Provenance du pack invalide.");
        }
        var content = await ReadAsync(rootDn, cancellationToken).ConfigureAwait(false);
        var chosen = content.Records.Where(r => !r.Archived && (ids is null || ids.Count == 0 || ids.Contains(r.Id))).OrderBy(r => FrenchText.Fold(r.Name), StringComparer.Ordinal).ToList();
        if (chosen.Count == 0)
        {
            throw new QueryDefinitionException("Aucune requête personnelle à exporter : enregistrez d’abord une requête.");
        }
        if (chosen.Count > 5000)
        {
            throw new QueryDefinitionException("Un pack contient au maximum 5 000 recettes ; exportez la sélection en plusieurs packs.");
        }
        var packId = PackId(name);
        var now = clock.GetUtcNow();
        var hash = ContentHash(packId, version, chosen.Select(r => r.Recipe));
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
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
        }
        if (buffer.WrittenCount > MaxDocumentBytes)
        {
            throw new QueryDefinitionException("Le pack dépasserait 16 Mio : exportez la sélection en plusieurs packs.");
        }
        var json = Encoding.UTF8.GetString(buffer.WrittenSpan);
        var file = "Domenia-requetes-" + WindowsRelease.Slug(name) + "-v" + version.ToString(CultureInfo.InvariantCulture) + ".json";
        return new QueryPackExport(json, file, chosen.Count, packId, version, version + 1);
    }

    /// <summary>Remembers that the file of a pack version was saved: the next export of the same pack proposes the following version.</summary>
    public async Task<long> ConfirmPackExportAsync(string rootDn, string packId, string packName, long version, int count, CancellationToken cancellationToken)
    {
        var now = clock.GetUtcNow();
        var (next, _) = await MutateAsync(RootKey(rootDn), state =>
        {
            var proposed = Math.Min(1_000_000, version + 1);
            if (!state.PackVersions.TryGetValue(packId, out var known) || known < proposed)
            {
                state.PackVersions[packId] = proposed;
                state.Dirty = true;
            }
            return state.PackVersions[packId];
        }, cancellationToken).ConfigureAwait(false);
        journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "pack « " + packName + " » v" + version.ToString(CultureInfo.InvariantCulture) + " exporté (" + FrenchText.Count(count, "requête", "requêtes") + ")", Tone.Info));
        return next;
    }

    /// <summary>Proposed version of the next export of a pack (1 for a new pack).</summary>
    public async Task<long> ProposedVersionAsync(string rootDn, string name, CancellationToken cancellationToken)
    {
        var state = await LoadAsync(RootKey(rootDn), cancellationToken).ConfigureAwait(false);
        return state.PackVersions.TryGetValue(PackId(name ?? ""), out var next) ? next : 1;
    }

    /// <summary>
    /// Reads a pack and prepares its import plan (Domenia 1 New-DomeniaQueryPackImportPlan): provenance, version, integrity,
    /// version already imported, and for each recipe its state with its differences. Nothing is written.
    /// </summary>
    public async Task<QueryImportPlan> ExaminePackAsync(string rootDn, string domainDn, string json, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(json);
        if (Encoding.UTF8.GetByteCount(json) > MaxDocumentBytes)
        {
            throw new QueryDefinitionException("Pack de plus de 16 Mio : rien n’a été importé.");
        }
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
                throw new QueryDefinitionException("Le pack dépasse 5 000 recettes.");
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
            var state = await LoadAsync(RootKey(rootDn), cancellationToken).ConfigureAwait(false);
            var records = state.Records;
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
            var previous = state.Imports.Where(e => e.Kind == "import" && e.PackId == packId && packId.Length > 0).Select(e => e.PackVersion).DefaultIfEmpty(0).Max();
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

    private static void Journal(State state, QueryImportEntry entry)
    {
        state.Imports.Add(entry);
        while (state.Imports.Count > MaxJournal)
        {
            state.Imports.RemoveAt(0);
        }
    }

    /// <summary>
    /// Applies the chosen actions of an examined pack in one write (Domenia 1 Start-DomeniaQueryImport), every revision checked
    /// against the stored document: creations go to « Import · &lt;pack&gt; » with their provenance; the journal keeps a restore point.
    /// </summary>
    public async Task<(QueryImportEntry Entry, int Created, int Replaced, int Copied, int Ignored, QueryStoreReceipt? Receipt)> ApplyImportAsync(string rootDn, string examinationId,
        IReadOnlyDictionary<string, string> choices, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(choices);
        var rootKey = RootKey(rootDn);
        (QueryImportPlan Plan, ImmutableArray<QueryRecipe> Recipes, string RootKey) exam;
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!examinations.TryGetValue(examinationId, out exam) || exam.Plan.ExpiresAt < clock.GetUtcNow() || exam.RootKey != rootKey)
            {
                throw new QueryDefinitionException(QueryErrors.ImportUnknownMessage);
            }
        }
        finally
        {
            gate.Release();
        }
        var now = clock.GetUtcNow();
        var category = "Import · " + (exam.Plan.PackName ?? "pack sans nom");
        if (category.Length > 80)
        {
            category = category[..80];
        }
        var ((entry, created, replaced, copied, ignored, last), write) = await MutateAsync(rootKey, state =>
        {
            var changes = new List<QueryImportChange>();
            int c = 0, r = 0, k = 0, i = 0, sequence = 0;
            QueryLibraryRecord? lastRecord = null;
            foreach (var item in exam.Plan.Items)
            {
                var action = choices.GetValueOrDefault(item.Id, "ignore");
                if (!item.AllowedActions.Contains(action))
                {
                    throw new QueryDefinitionException("Action non permise pour « " + item.Name + " ». Rien n’a été importé.");
                }
                if (action == "ignore")
                {
                    i++;
                    continue;
                }
                var recipe = exam.Recipes.First(x => x.Id == item.Id);
                var compiled = QueryEngine.Compile(recipe);
                var provenance = new QueryProvenance(exam.Plan.PackId, exam.Plan.PackName, exam.Plan.PackVersion, exam.Plan.Origin, recipe.Id, compiled.Fingerprint, exam.Plan.Verified);
                var index = state.Records.FindIndex(x => x.Id == recipe.Id);
                var current = index >= 0 ? state.Records[index] : null;
                if ((current?.Revision ?? 0) != item.ExpectedRevision)
                {
                    throw RevisionChanged(current?.Revision ?? 0);
                }
                sequence++;
                switch (action)
                {
                    case "create":
                        lastRecord = new QueryLibraryRecord(recipe.Id, recipe.Name, category, "", 1, now, now, false, compiled.Fingerprint, compiled.Normalized, provenance, [], []);
                        state.Records.Add(lastRecord);
                        changes.Add(new QueryImportChange(lastRecord.Id, lastRecord.Name, 1, sequence, null));
                        c++;
                        break;
                    case "copy":
                        var copy = compiled.Normalized with { Id = Guid.NewGuid().ToString("N"), Name = Clip(recipe.Name + " (copie importée)") };
                        var copyCompiled = QueryEngine.Compile(copy);
                        lastRecord = new QueryLibraryRecord(copy.Id, copy.Name, category, "", 1, now, now, false, copyCompiled.Fingerprint, copyCompiled.Normalized, provenance, [], []);
                        state.Records.Add(lastRecord);
                        changes.Add(new QueryImportChange(lastRecord.Id, lastRecord.Name, 1, sequence, null));
                        k++;
                        break;
                    default:
                        var before = new QueryLibrarySnapshot(current!.Revision, current.Archived, current.Category, current.Name, QueryRecipeJson.Write(current.Recipe), current.Fingerprint, current.Provenance);
                        var history = current.History.Insert(0, new QueryRevision(current.Revision, current.UpdatedAt, current.Fingerprint, QueryRecipeJson.Write(current.Recipe)));
                        lastRecord = current with
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
                        state.Records[index] = lastRecord;
                        changes.Add(new QueryImportChange(lastRecord.Id, lastRecord.Name, lastRecord.Revision, sequence, before));
                        r++;
                        break;
                }
            }
            if (state.Records.Count > MaxRecipes)
            {
                throw new QueryDefinitionException("L’import dépasserait 5 000 requêtes dans la bibliothèque locale. Rien n’a été importé.");
            }
            var journalEntry = new QueryImportEntry(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)), "import", null, now, exam.Plan.PackId, exam.Plan.PackName, exam.Plan.PackVersion,
                exam.Plan.Origin, exam.Plan.Verified, [.. changes], []);
            if (changes.Count > 0)
            {
                Journal(state, journalEntry);
                state.Dirty = true;
            }
            return (journalEntry, c, r, k, i, lastRecord);
        }, cancellationToken).ConfigureAwait(false);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            examinations.Remove(examinationId);
        }
        finally
        {
            gate.Release();
        }
        journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "import du pack « " + (exam.Plan.PackName ?? "sans nom") + " » : " + FrenchText.Count(created + copied, "création", "créations") + ", "
            + FrenchText.Count(replaced, "remplacement", "remplacements") + ", " + FrenchText.Count(ignored, "ignorée", "ignorées"), Tone.Ok));
        return (entry, created, replaced, copied, ignored, last is null ? null : Receipt(write, last, now));
    }

    private static string Clip(string name) => name.Length > QueryLimits.MaxNameLength ? name[..QueryLimits.MaxNameLength] : name;

    /// <summary>Imports that can still be undone, newest first (Domenia 1 ConvertFrom-DomeniaQueryImportJournal).</summary>
    public async Task<ImmutableArray<QueryImportEntry>> HistoryAsync(string rootDn, CancellationToken cancellationToken)
    {
        var state = await LoadAsync(RootKey(rootDn), cancellationToken).ConfigureAwait(false);
        return Available(state);
    }

    private static ImmutableArray<QueryImportEntry> Available(State state)
    {
        var rolledBack = state.Imports.Where(e => e.Kind == "rollback" && e.Remaining.Length == 0).Select(e => e.RollsBack).OfType<string>().ToHashSet(StringComparer.Ordinal);
        var available = new List<QueryImportEntry>();
        foreach (var entry in state.Imports)
        {
            if (entry.Kind == "rollback")
            {
                // The last interrupted rollback of an import stays restorable (« Reprendre la restauration »).
                var latest = state.Imports.LastOrDefault(e => e.Kind == "rollback" && e.RollsBack == entry.RollsBack);
                if (entry.Remaining.Length > 0 && !rolledBack.Contains(entry.RollsBack ?? "") && ReferenceEquals(latest, entry))
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

    /// <summary>
    /// Restores the library as it was before an import (Domenia 1 « Restaurer avant cet import… »): replaced definitions come back,
    /// creations are removed (with their widgets). A recipe modified since the import is not restored (the rest is, and stays
    /// restorable later).
    /// </summary>
    public async Task<(QueryImportEntry Entry, int Restored, int Refused)> RollbackAsync(string rootDn, string importId, CancellationToken cancellationToken)
    {
        var now = clock.GetUtcNow();
        var ((entry, restoredCount, refusedCount, widgetsRemoved, packName), _) = await MutateAsync(RootKey(rootDn), state =>
        {
            var source = state.Imports.FirstOrDefault(e => e.ImportId == importId) ?? throw new QueryDefinitionException("Import introuvable dans le journal : rien n’a été restauré.");
            var items = source.Kind == "rollback" ? source.Remaining : source.Items;
            if (items.Length == 0)
            {
                throw new QueryDefinitionException("Cet import n’a rien à restaurer.");
            }
            var restored = new List<QueryImportChange>();
            var remaining = new List<QueryImportChange>();
            var removedWidgets = 0;
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
                    removedWidgets += state.Widgets.RemoveAll(w => w.RecipeId == item.Id);
                    state.Consumers.RemoveAll(c => c.RecipeId == item.Id);
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
            var rollback = new QueryImportEntry(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)), "rollback", source.Kind == "rollback" ? source.RollsBack : source.ImportId, now,
                source.PackId, source.PackName, source.PackVersion, source.Origin, source.Verified, [.. restored], [.. remaining]);
            Journal(state, rollback);
            state.Dirty = true;
            return (rollback, restored.Count, remaining.Count, removedWidgets, source.PackName);
        }, cancellationToken).ConfigureAwait(false);
        journal.Add(new JournalEntry(now, "Requêtes" + FrenchText.Colon + "restauration avant l’import « " + (packName ?? "pack sans nom") + " » : " + FrenchText.Count(restoredCount, "recette restaurée", "recettes restaurées")
            + (refusedCount > 0 ? ", " + FrenchText.Count(refusedCount, "refusée", "refusées") : "") + (widgetsRemoved > 0 ? ", " + FrenchText.Count(widgetsRemoved, "widget retiré", "widgets retirés") : ""),
            refusedCount > 0 ? Tone.Warn : Tone.Ok));
        return (entry, restoredCount, refusedCount);
    }
}
