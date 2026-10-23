using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private void CheckQueryRoot(string key)
    { if (key != QueryLibrary.RootKey(DomainDn)) { throw new InvalidDataException("Bibliothèque d’un autre domaine ; aucune lecture ni écriture."); } }

    public Task<byte[]?> ReadQueryLibraryAsync(string rootKey, CancellationToken cancellationToken) => Task.Run(() =>
    {
        CheckQueryRoot(rootKey); CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return null; }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
        db.Begin(write: false); CheckIdentity(db, allowLegacy: true);
        var (document, _) = ReadQueryLibrary(db, rootKey); db.Commit(); return document;
    }, cancellationToken);

    public async Task<QueryStoreWrite?> UpdateQueryLibraryAsync(string rootKey, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken)
    {
        CheckQueryRoot(rootKey); ArgumentNullException.ThrowIfNull(update);
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady(); CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = new SqliteDatabase(Path, readOnly: false, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: false);
                if (!Table(db, "domenia_v2_query_library")) { lastBackup = Backup(db, cancellationToken); } else { EnsureBackup(db, cancellationToken); }
                db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, allowLegacy: false);
                var previousRevision = (long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") ?? throw new InvalidDataException("Révision du stockage absente.");
                var (before, legacy) = ReadQueryLibrary(db, rootKey);
                var next = update(before?.ToArray());
                if (next is null) { db.Commit(); return (QueryStoreWrite?)null; }
                CheckQueryDocument(rootKey, next.Document);
                var text = new UTF8Encoding(false, true).GetString(next.Document);
                var sha = QueryHash(text);
                db.Execute("CREATE TABLE IF NOT EXISTS domenia_v2_query_library(domain_key TEXT PRIMARY KEY NOT NULL,document TEXT NOT NULL,sha256 TEXT NOT NULL,legacy_sha256 TEXT NOT NULL,revision INTEGER NOT NULL);");
                db.Execute("CREATE TABLE IF NOT EXISTS domenia_v2_query_library_archive(id TEXT PRIMARY KEY NOT NULL,domain_key TEXT NOT NULL,document BLOB NOT NULL,sha256 TEXT NOT NULL,at_utc TEXT NOT NULL);");
                if (next.KeepPrevious && before is not null)
                { db.Execute("INSERT INTO domenia_v2_query_library_archive(id,domain_key,document,sha256,at_utc) VALUES(?1,?2,?3,?4,?5);", Guid.NewGuid().ToString("N"), rootKey, before, Convert.ToHexStringLower(SHA256.HashData(before)), clock.GetUtcNow().ToString("O", CultureInfo.InvariantCulture)); }
                db.Execute("INSERT INTO domenia_v2_query_library(domain_key,document,sha256,legacy_sha256,revision) VALUES(?1,?2,?3,?4,1) ON CONFLICT(domain_key) DO UPDATE SET document=excluded.document,sha256=excluded.sha256,legacy_sha256=excluded.legacy_sha256,revision=revision+1;", rootKey, text, sha, legacy);
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                var (inside, _) = ReadQueryLibrary(db, rootKey);
                if (inside is null || !inside.AsSpan().SequenceEqual(next.Document)) { throw new InvalidDataException("Bibliothèque différente après écriture ; transaction annulée."); }
                var storedRevision = (long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;");
                if (storedRevision != checked(previousRevision + 1)) { throw new InvalidDataException("Révision inattendue après écriture de bibliothèque ; transaction annulée."); }
                db.Commit(); var (after, _) = ReadQueryLibrary(db, rootKey);
                if (after is null || !after.AsSpan().SequenceEqual(next.Document)) { throw new InvalidDataException("Bibliothèque modifiée avant relecture du reçu."); }
                return new QueryStoreWrite(true, true) { Source = "SQLite", StoreId = StoreId, StoreRevision = storedRevision,
                    DomainKey = rootKey, DocumentSha256 = Convert.ToHexStringLower(SHA256.HashData(after)) };
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private static void CheckQueryDocument(string rootKey, byte[] document)
    {
        if (document.Length > 16_777_216) { throw new InvalidDataException("Bibliothèque limitée à 16 Mio."); }
        using var json = JsonDocument.Parse(document, new JsonDocumentOptions { MaxDepth = 96 });
        var root = json.RootElement;
        if (root.GetProperty("format").GetString() != QueryLibrary.DocumentFormat || root.GetProperty("version").GetInt32() != QueryLibrary.DocumentVersion
            || root.GetProperty("domainKey").GetString() != rootKey || root.GetProperty("recipes").GetArrayLength() > 5000)
        { throw new InvalidDataException("Format ou domaine de bibliothèque invalide."); }
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var record in root.GetProperty("recipes").EnumerateArray())
        {
            var definition = record.GetProperty("definition").GetString() ?? throw new InvalidDataException("Définition de recette absente.");
            if (Encoding.UTF8.GetByteCount(definition) > 1_048_576) { throw new InvalidDataException("Définition de recette supérieure à 1 Mio."); }
            var recipe = QueryRecipeJson.Read(definition);
            var compiled = QueryEngine.Compile(recipe);
            if (!ids.Add(recipe.Id) || recipe.Id != record.GetProperty("id").GetString() || recipe.Id.StartsWith(QueryTemplates.Prefix, StringComparison.Ordinal)
                || record.GetProperty("fingerprint").GetString() != compiled.Fingerprint || record.GetProperty("revision").GetInt64() <= 0)
            { throw new InvalidDataException("Recette incohérente ou dupliquée ; bibliothèque non écrite."); }
        }
    }

    private (byte[]? Document, string LegacyHash) ReadQueryLibrary(SqliteDatabase db, string rootKey)
    {
        var legacy = LegacyQueryRows(db);
        var metadata = LegacyQueryMetadata(db);
        var legacyHash = metadata.Revisions.Count == 0 && metadata.Provenances.Count == 0 && metadata.Dependencies.Count == 0
            ? QueryHash(JsonSerializer.Serialize(legacy))
            : QueryHash(JsonSerializer.Serialize(new { Recipes = legacy, metadata.Revisions, metadata.Provenances, metadata.Dependencies }));
        if (Table(db, "domenia_v2_query_library"))
        {
            var rows = db.Query("SELECT CASE WHEN length(CAST(document AS BLOB))<=16777216 THEN document END AS document,sha256,legacy_sha256 FROM domenia_v2_query_library WHERE domain_key=?1;", rootKey);
            if (rows.Count == 1)
            {
                if (rows[0]["document"] is not string text || QueryHash(text) != rows[0]["sha256"] as string) { throw new InvalidDataException("Bibliothèque SQLite altérée ou hors limites."); }
                if (rows[0]["legacy_sha256"] as string != legacyHash)
                { throw new InvalidDataException("Bibliothèque Domenia 1 modifiée depuis la reprise ; réconciliation explicite nécessaire, aucune version écrasée."); }
                return (Encoding.UTF8.GetBytes(text), legacyHash);
            }
        }
        var projected = ProjectQueryLegacy(legacy, metadata);
        if (legacy.Count == 0) { return (null, legacyHash); }
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject(); writer.WriteString("format", QueryLibrary.DocumentFormat); writer.WriteNumber("version", QueryLibrary.DocumentVersion);
            writer.WriteNumber("generation", 0); writer.WriteString("domainKey", rootKey); writer.WriteStartArray("recipes");
            foreach (var row in legacy)
            {
                var text = (string)row["definition_json"]!;
                var compiled = LegacyQueryDefinition(text, (string)row["id"]!, (long)row["definition_version"]!, row["definition_sha256"] as string);
                var recipe = compiled.Normalized;
                var created = QueryDate((string)row["created_utc"]!); var updated = QueryDate((string)row["updated_utc"]!);
                if (updated < created || updated > clock.GetUtcNow().AddMinutes(2) || (long)row["revision"]! <= 0 || (long)row["archived"]! is < 0 or > 1
                    || row["name"] as string != recipe.Name || !QueryFormat.CleanText(row["category"] as string ?? "", 80))
                { throw new InvalidDataException("Nom, catégorie, révision ou date de recette Domenia 1 invalide."); }
                writer.WriteStartObject(); writer.WriteString("id", recipe.Id); writer.WriteString("category", row["category"] as string ?? "Mes requêtes");
                writer.WriteString("description", "Recette reprise de la bibliothèque SQLite Domenia 1 ; original conservé.");
                writer.WriteNumber("revision", (long)row["revision"]!); writer.WriteString("createdAt", created); writer.WriteString("updatedAt", updated);
                writer.WriteBoolean("archived", (long)row["archived"]! == 1); writer.WriteString("fingerprint", compiled.Fingerprint); writer.WriteString("definition", QueryRecipeJson.Write(compiled.Normalized));
                writer.WritePropertyName("history"); JsonSerializer.Serialize(writer, projected.History[recipe.Id], QueryLegacyJson);
                if (projected.Provenance.TryGetValue(recipe.Id, out var provenance))
                { writer.WritePropertyName("provenance"); JsonSerializer.Serialize(writer, provenance, QueryLegacyJson); }
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            foreach (var key in new[] { "widgets", "imports", "unreadable" }) { writer.WriteStartArray(key); writer.WriteEndArray(); }
            writer.WritePropertyName("consumers"); JsonSerializer.Serialize(writer, projected.Dependencies, QueryLegacyJson);
            writer.WriteStartObject("packVersions"); writer.WriteEndObject(); writer.WriteEndObject();
        }
        if (stream.Length > 16_777_216) { throw new InvalidDataException("Bibliothèque héritée supérieure à 16 Mio."); }
        return (stream.ToArray(), legacyHash);
    }

    private List<Dictionary<string, object?>> LegacyQueryRows(SqliteDatabase db)
    {
        if (!Table(db, "domenia_query_recipes")) { return []; }
        if ((long?)db.Scalar("SELECT coalesce(sum(length(CAST(definition_json AS BLOB))),0) FROM domenia_query_recipes;") > 16_777_216)
        { throw new InvalidDataException("Bibliothèque Domenia 1 supérieure à 16 Mio."); }
        var rows = db.Query("SELECT id,domain_dn,name,category,revision,definition_version,CASE WHEN length(CAST(definition_json AS BLOB))<=1048576 THEN definition_json END AS definition_json,definition_sha256,created_utc,updated_utc,archived FROM domenia_query_recipes ORDER BY id LIMIT 5001;");
        if (rows.Count > 5000 || rows.Any(r => r["definition_json"] is not string || r["domain_dn"] is not string domain || !DistinguishedName.AreEqual(domain, DomainDn)))
        { throw new InvalidDataException("Bibliothèque Domenia 1 hors limites ou d’un autre domaine."); }
        return rows.Select(r => r.ToDictionary(p => p.Key, p => p.Value, StringComparer.Ordinal)).ToList();
    }

    private static DateTimeOffset QueryDate(string text)
    {
        if (text.Length is < 20 or > 40 || !DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var value)
            || !(text.EndsWith('Z') || text.Length >= 6 && text[^3] == ':' && text[^6] is '+' or '-'))
        { throw new InvalidDataException("Date héritée sans fuseau explicite."); }
        return value;
    }
}
