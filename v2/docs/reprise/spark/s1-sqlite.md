Écris l'accès SQLite de `Domenia.Store` (projet `v2/src/Domenia.Store`, espace de noms `Domenia.Store`), compatible avec
la base de Domenia 1, SANS paquet NuGet : par P/Invoke sur `winsqlite3.dll`, la copie de SQLite livrée avec Windows 10/11
(`[LibraryImport("winsqlite3.dll")]` + `[DefaultDllImportSearchPaths(DllImportSearchPath.System32)]`, comme le fait Domenia 1
avec `DefinePInvokeMethod` — extrait fourni). En x64 la convention d'appel par défaut convient.

Fichiers à produire :
1. `v2/src/Domenia.Store/Sqlite/SqliteNative.cs` : `internal static partial class SqliteNative` avec les fonctions utiles :
   sqlite3_open_v2, sqlite3_close_v2, sqlite3_prepare_v2 (texte SQL en UTF-8, `byte*` ou `ReadOnlySpan<byte>` épinglé),
   sqlite3_step, sqlite3_reset, sqlite3_clear_bindings, sqlite3_finalize, sqlite3_bind_text (UTF-8, longueur en octets,
   destructeur SQLITE_TRANSIENT = (IntPtr)(-1)), sqlite3_bind_int64, sqlite3_bind_double, sqlite3_bind_blob, sqlite3_bind_null,
   sqlite3_column_count, sqlite3_column_name, sqlite3_column_type, sqlite3_column_int64, sqlite3_column_double,
   sqlite3_column_text, sqlite3_column_bytes, sqlite3_column_blob, sqlite3_errmsg, sqlite3_extended_errcode,
   sqlite3_busy_timeout, sqlite3_changes, sqlite3_last_insert_rowid. Constantes : SQLITE_OK, SQLITE_ROW, SQLITE_DONE,
   SQLITE_BUSY, SQLITE_OPEN_READONLY, SQLITE_OPEN_READWRITE, SQLITE_OPEN_CREATE, SQLITE_OPEN_FULLMUTEX, types de colonnes.
2. `v2/src/Domenia.Store/Sqlite/SqliteDatabase.cs` : `public sealed class SqliteDatabase : IDisposable`
   - `public static SqliteDatabase Open(string path, bool readOnly)` (création si absent quand `readOnly` est faux ;
     `busy_timeout` 5000 ms ; FULLMUTEX) ; un handle `SafeHandle` (classe `SqliteDatabaseHandle`) fermé par `sqlite3_close_v2`.
   - `int Execute(string sql, params object?[] parameters)` (renvoie `sqlite3_changes`) ; `object? Scalar(string sql, params object?[])` ;
     `IReadOnlyList<T> Query<T>(string sql, Func<SqliteRow, T> map, params object?[] parameters)` ;
     `void ExecuteScript(string sql)` : plusieurs instructions séparées par « ; » (boucle prepare/step avec le reste du texte).
   - `SqliteTransaction BeginTransaction()` (« BEGIN IMMEDIATE », `Commit()`, rollback au Dispose si non validée).
   - paramètres positionnels `?` : null, string, long, int, short, double, float, decimal (en double), bool (0/1), byte[],
     Guid (texte « D » minuscule), DateTimeOffset et DateTime (texte ISO 8601 UTC « o »), enum (son nom).
   - accès par un seul thread à la fois : verrou interne (`Lock`) autour de chaque appel.
3. `v2/src/Domenia.Store/Sqlite/SqliteRow.cs` : lecture d'une ligne courante : `int Count`, `string Name(int i)`,
   `bool IsNull(int i)`, `string? String(int i)`, `long? Long(int i)`, `int? Int(int i)`, `double? Double(int i)`,
   `byte[]? Bytes(int i)`, et les mêmes par nom de colonne (insensible à la casse).
4. `v2/src/Domenia.Store/Sqlite/SqliteException.cs` : `public sealed class SqliteException : Exception` avec `int Code`,
   `int ExtendedCode` ; `Message` en français générique (« Base locale : erreur SQLite 5 (base occupée). ») ;
   `public string? Detail` = texte de sqlite3_errmsg (pour le journal technique seulement, jamais montré tel quel).
5. `v2/src/Domenia.Store/Sqlite/DomeniaStoreSchema.cs` : `public static class DomeniaStoreSchema` :
   - `public const int Version = 11;`
   - `public static void Ensure(SqliteDatabase database)` : applique les PRAGMA et TOUTES les instructions
     `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` du schéma de Domenia 1 fourni (extrait d1-schema), à
     l'identique (mêmes noms de tables, colonnes, types, contraintes), dans une transaction, puis
     `INSERT OR IGNORE INTO schema_info(key,value) VALUES('schema_version','11')`.
   - `public static int? ReadVersion(SqliteDatabase database)` (null si `schema_info` absente).
   Garde le DDL dans une constante `private const string Script = """ ... """;` (littéral brut C# 11).
6. `v2/src/Domenia.Store/Domenia.Store.csproj` modifié : ajoute `<AllowUnsafeBlocks>true</AllowUnsafeBlocks>` (le générateur
   de LibraryImport en a besoin), garde la référence de projet existante.
7. `v2/tests/Domenia.Tests/SqliteStoreTests.cs` : tests (classe `public static class SqliteStoreTests`, méthodes
   `[Test] public static void ...()`, assertions `Check.True(bool, string)`, `Check.Equal<T>(T, T, string)`,
   `Check.False`, `Check.Null`, `Check.NotNull`, `Check.Throws<T>(Action, string)`) : base temporaire dans
   `Path.GetTempPath()` (nom aléatoire, supprimée à la fin même en échec, fichiers -wal et -shm compris), création du
   schéma (version 11 relue), insertion et relecture de chaque type de paramètre, transaction annulée, script multiple,
   ouverture en lecture seule qui refuse l'écriture. Espace de noms `Domenia.Tests` ; `using Domenia.Store;`.

Contraintes : aucun avertissement (CA2101 n'a pas lieu d'être avec LibraryImport ; marque `SqliteNative` `internal` ;
`SafeHandle` correct ; `unsafe` permis dans SqliteNative et SqliteDatabase uniquement si nécessaire). Pas d'E/S réseau.
