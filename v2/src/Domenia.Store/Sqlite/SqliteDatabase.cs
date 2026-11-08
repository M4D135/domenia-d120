using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>Native Windows SQLite. One owner per connection, bound values, explicit transactions.</summary>
internal sealed class SqliteDatabase : IDisposable
{
    private IntPtr handle;
    private readonly string path;
    private readonly CancellationToken cancellationToken;
    private readonly Native.Progress progress;
    private bool transaction;
    // Idle statements only: nested enumerations never share a cursor or another caller's bindings.
    internal const int StatementCapacity = 32;
    private readonly LinkedList<(string Sql, IntPtr Handle)> statements = new();
    internal int CachedStatementCount => statements.Count;
    internal long PreparedStatementCount { get; private set; }
    internal bool InWriteTransaction { get; private set; }
    internal bool InTransaction => transaction;
    private IDisposable? storageWriter;
    private readonly OperationActivity? operations;

    public SqliteDatabase(string path, bool readOnly, int? busyTimeoutMs = null, CancellationToken cancellationToken = default, OperationActivity? operations = null)
    {
        this.path = path;
        this.operations = operations;
        this.cancellationToken = cancellationToken;
        progress = _ => cancellationToken.IsCancellationRequested ? 1 : 0;
        ValidateFiles(path, cancellationToken);
        if (!readOnly) { storageWriter = StorageWriteFence.Writer(path, cancellationToken); }
        int code;
        try { code = Native.sqlite3_open_v2(path, out handle, (readOnly ? 1 : 2 | 4) | 65536, IntPtr.Zero); }
        catch { storageWriter?.Dispose(); storageWriter = null; throw; }
        if (code != 0)
        {
            Dispose();
            if ((code & 255) is 5 or 6) OperationsMeasurements.RecordSqliteBusy(operations);
            throw new SqliteStoreException(code, "Ouverture de la base impossible ; aucun fichier n’a été remplacé.");
        }
        Native.sqlite3_busy_timeout(handle, Math.Clamp(busyTimeoutMs ?? operations?.SqliteBusyTimeoutMs ?? OperationsMeasurements.SqliteBusyTimeoutMs, 100, 5000));
        Native.sqlite3_progress_handler(handle, 1000, progress, IntPtr.Zero);
    }

    // All native openings, including read-only, backup and portable stores, inspect SQLite's sidecars first.
    internal static void ValidateFiles(string path, CancellationToken token = default)
    {
        if (path == ":memory:") return;
        foreach (var suffix in new[] { "", "-wal", "-shm", "-journal", ".domenia-write.lock", ".domenia-readonly" })
        {
            token.ThrowIfCancellationRequested();
            var file = path + suffix;
            CompatibleDirectoryCache.ValidateLocalPath(file);
            try
            {
                if ((File.GetAttributes(file) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                    throw new InvalidDataException("Base ou fichier annexe redirigé ou non régulier ; aucune ouverture SQLite.");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }

    public List<Dictionary<string, object?>> Query(string sql, params object?[] values) => [.. ReadRows(sql, values)];

    /// <summary>One native row at a time; the caller owns this connection for the enumeration.</summary>
    public IEnumerable<Dictionary<string, object?>> ReadRows(string sql, params object?[] values)
    {
        using var measurement = OperationRequests.MeasureStorage(RequestStorageKind.Read);
        using var statement = Prepare(sql, values);
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var code = statement.Step();
            if (code == 101) { measurement?.Success(); yield break; }
            Check(code, 100);
            var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            for (var column = 0; column < Native.sqlite3_column_count(statement.Handle); column++)
            {
                var name = Marshal.PtrToStringUTF8(Native.sqlite3_column_name(statement.Handle, column)) ?? throw new InvalidDataException("Colonne SQLite sans nom.");
                object? value = Native.sqlite3_column_type(statement.Handle, column) switch
                {
                    1 => Native.sqlite3_column_int64(statement.Handle, column),
                    2 => Native.sqlite3_column_double(statement.Handle, column),
                    3 => Text(statement.Handle, column),
                    4 => Blob(statement.Handle, column),
                    5 => null,
                    _ => throw new InvalidDataException("Type SQLite inconnu."),
                };
                row.Add(name, value);
            }
            measurement?.Row(); measurement?.Pause();
            yield return row;
            measurement?.Resume();
        }
    }

    public long Execute(string sql, params object?[] values)
    {
        using var measurement = OperationRequests.MeasureStorage(RequestStorageKind.Write);
        using var statement = Prepare(sql, values);
        Check(statement.Step(), 101);
        var changed = Native.sqlite3_changes(handle);
        measurement?.Success();
        return changed;
    }

    public object? Scalar(string sql, params object?[] values) => Query(sql, values).FirstOrDefault()?.Values.FirstOrDefault();

    /// <summary>Only for embedded schema and fixed PRAGMAs, never interpolated application values.</summary>
    public void Script(string sql)
    {
        using var measurement = OperationRequests.MeasureStorage(RequestStorageKind.Control);
        cancellationToken.ThrowIfCancellationRequested();
        var code = Native.sqlite3_exec(handle, sql, IntPtr.Zero, IntPtr.Zero, out var error);
        if (error != IntPtr.Zero) { Native.sqlite3_free(error); }
        Check(code);
        measurement?.Success();
    }

    public void Begin(bool write = true)
    {
        if (transaction) { throw new InvalidOperationException("Transaction déjà ouverte."); }
        if (write) { StorageWriteBudgetScope.Check(path); }
        Script(write ? "BEGIN IMMEDIATE;" : "BEGIN;");
        transaction = true;
        InWriteTransaction = write;
        if (write) { StorageReplayScope.Check(path, this); }
    }

    public void Commit()
    {
        if (!transaction) { throw new InvalidOperationException("Aucune transaction."); }
        var writing = InWriteTransaction;
        if (writing)
        {
            StorageWriteBudgetScope.Check(path);
            StorageReplayScope.BeforeCommit(path, this);
        }
        Script("COMMIT;");
        transaction = false;
        InWriteTransaction = false;
        if (writing) StorageReplayScope.Committed(path);
    }

    public void Rollback()
    {
        if (!transaction) { return; }
        var code = Native.sqlite3_exec(handle, "ROLLBACK;", IntPtr.Zero, IntPtr.Zero, out var error);
        if (error != IntPtr.Zero) { Native.sqlite3_free(error); }
        transaction = false;
        InWriteTransaction = false;
        Check(code);
    }

    public void BackupTo(SqliteDatabase destination, Action? stepCompleted = null)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var backup = Native.sqlite3_backup_init(destination.handle, "main", handle, "main");
        if (backup == IntPtr.Zero)
        {
            var code = Native.sqlite3_errcode(destination.handle);
            if ((code & 255) is 5 or 6) OperationsMeasurements.RecordSqliteBusy(operations ?? destination.operations);
            throw new SqliteStoreException(code, "Sauvegarde SQLite non initialisée.");
        }
        var step = 0;
        var finish = 0;
        try
        {
            do
            {
                cancellationToken.ThrowIfCancellationRequested();
                step = Native.sqlite3_backup_step(backup, 256);
                stepCompleted?.Invoke();
            } while (step == 0);
        }
        finally { finish = Native.sqlite3_backup_finish(backup); }
        Check(step, 101);
        Check(finish);
    }

    private Statement Prepare(string sql, object?[] values)
    {
        ObjectDisposedException.ThrowIf(handle == IntPtr.Zero, this);
        cancellationToken.ThrowIfCancellationRequested();
        if (sql.Contains('\0')) { throw new ArgumentException("SQL contenant un caractère nul.", nameof(sql)); }
        IntPtr prepared = IntPtr.Zero;
        for (var node = statements.First; node is not null; node = node.Next)
        {
            if (node.Value.Sql != sql) continue;
            prepared = node.Value.Handle;
            statements.Remove(node);
            break;
        }
        try
        {
            if (prepared == IntPtr.Zero)
            {
                var bytes = Encoding.UTF8.GetBytes(sql + "\0");
                var pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
                try
                {
                    Check(Native.sqlite3_prepare_v2(handle, pin.AddrOfPinnedObject(), bytes.Length, out prepared, out var tail));
                    PreparedStatementCount++;
                    var trailing = Marshal.PtrToStringUTF8(tail) ?? "";
                    if (prepared == IntPtr.Zero || !string.IsNullOrWhiteSpace(trailing))
                        throw new ArgumentException("Une seule instruction SQL est admise.", nameof(sql));
                }
                finally { pin.Free(); }
            }
            if (Native.sqlite3_bind_parameter_count(prepared) != values.Length) { throw new ArgumentException("Nombre de paramètres SQL incohérent.", nameof(values)); }
            for (var i = 0; i < values.Length; i++)
            {
                var at = i + 1;
                var value = values[i];
                var code = value switch
                {
                    null => Native.sqlite3_bind_null(prepared, at),
                    string text => Native.sqlite3_bind_text(prepared, at, text, Encoding.UTF8.GetByteCount(text), new IntPtr(-1)),
                    byte[] blob => Native.sqlite3_bind_blob(prepared, at, blob, blob.Length, new IntPtr(-1)),
                    bool flag => Native.sqlite3_bind_int64(prepared, at, flag ? 1 : 0),
                    int number => Native.sqlite3_bind_int64(prepared, at, number),
                    long number => Native.sqlite3_bind_int64(prepared, at, number),
                    double number when double.IsFinite(number) => Native.sqlite3_bind_double(prepared, at, number),
                    _ => throw new ArgumentException("Type de paramètre SQL non pris en charge.", nameof(values)),
                };
                Check(code);
            }
            var result = new Statement(this, sql, prepared);
            prepared = IntPtr.Zero;
            return result;
        }
        finally
        {
            if (prepared != IntPtr.Zero) { Native.sqlite3_finalize(prepared); }
        }
    }

    private void ReturnStatement(string sql, IntPtr statement, bool stepFailed)
    {
        // close_v2 permits an active reader to release its final statement after the owner was disposed.
        if (handle == IntPtr.Zero) { Native.sqlite3_finalize(statement); return; }
        var reset = Native.sqlite3_reset(statement);
        var clear = Native.sqlite3_clear_bindings(statement);
        if (reset != 0 || clear != 0)
        {
            Native.sqlite3_finalize(statement);
            // The step error was already measured and surfaced. Disposal must not count it twice or replace it.
            if (!stepFailed) { Check(reset); Check(clear); }
            return;
        }
        // Do not retain oversized dynamic SQL, or multiple idle copies created by nested readers.
        if (sql.Length > 65_536 || statements.Any(item => item.Sql == sql))
        { Native.sqlite3_finalize(statement); return; }
        statements.AddFirst((sql, statement));
        if (statements.Count > StatementCapacity)
        {
            Native.sqlite3_finalize(statements.Last!.Value.Handle);
            statements.RemoveLast();
        }
    }

    private void Check(int code, int expected = 0)
    {
        if (code == expected) { return; }
        if (code == 9) { cancellationToken.ThrowIfCancellationRequested(); }
        if ((code & 255) is 5 or 6) { OperationsMeasurements.RecordSqliteBusy(operations); }
        throw new SqliteStoreException(code, (code & 255) is 5 or 6 ? "Base occupée ; aucun résultat vide n’a été substitué." : "Opération SQLite interrompue (code " + code.ToString(CultureInfo.InvariantCulture) + ").");
    }

    private static string Text(IntPtr statement, int column) => Marshal.PtrToStringUTF8(Native.sqlite3_column_text(statement, column), Native.sqlite3_column_bytes(statement, column)) ?? "";
    private static byte[] Blob(IntPtr statement, int column)
    {
        var result = new byte[Native.sqlite3_column_bytes(statement, column)];
        if (result.Length > 0) { Marshal.Copy(Native.sqlite3_column_blob(statement, column), result, 0, result.Length); }
        return result;
    }

    public void Dispose()
    {
        if (handle == IntPtr.Zero) { storageWriter?.Dispose(); storageWriter = null; return; }
        foreach (var statement in statements) Native.sqlite3_finalize(statement.Handle);
        statements.Clear();
        // close_v2 rolls back an uncommitted transaction and releases the connection after its statements.
        Native.sqlite3_close_v2(handle);
        handle = IntPtr.Zero;
        GC.KeepAlive(progress);
        storageWriter?.Dispose(); storageWriter = null;
    }

    private sealed class Statement(SqliteDatabase owner, string sql, IntPtr handle) : IDisposable
    {
        public IntPtr Handle { get; } = handle;
        private bool disposed;
        private bool stepFailed;
        public int Step()
        {
            var code = Native.sqlite3_step(Handle);
            stepFailed = code is not (100 or 101);
            return code;
        }
        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            owner.ReturnStatement(sql, Handle, stepFailed);
        }
    }

    private static class Native
    {
        private const string Library = "winsqlite3.dll";
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int Progress(IntPtr context);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out IntPtr db, int flags, IntPtr vfs);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_close_v2(IntPtr db);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_busy_timeout(IntPtr db, int ms);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void sqlite3_progress_handler(IntPtr db, int instructions, Progress callback, IntPtr context);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_prepare_v2(IntPtr db, IntPtr sql, int bytes, out IntPtr statement, out IntPtr tail);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_exec(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, IntPtr callback, IntPtr context, out IntPtr error);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void sqlite3_free(IntPtr pointer);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_step(IntPtr statement);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_finalize(IntPtr statement);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_reset(IntPtr statement);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_clear_bindings(IntPtr statement);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_bind_parameter_count(IntPtr statement);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_bind_null(IntPtr statement, int index);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_bind_int64(IntPtr statement, int index, long value);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_bind_double(IntPtr statement, int index, double value);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_bind_text(IntPtr statement, int index, [MarshalAs(UnmanagedType.LPUTF8Str)] string value, int bytes, IntPtr destructor);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_bind_blob(IntPtr statement, int index, byte[] value, int bytes, IntPtr destructor);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_column_count(IntPtr statement);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_column_type(IntPtr statement, int column);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr sqlite3_column_name(IntPtr statement, int column);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr sqlite3_column_blob(IntPtr statement, int column);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_column_bytes(IntPtr statement, int column);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern long sqlite3_column_int64(IntPtr statement, int column);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern double sqlite3_column_double(IntPtr statement, int column);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_changes(IntPtr db);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_errcode(IntPtr db);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr sqlite3_backup_init(IntPtr destination, [MarshalAs(UnmanagedType.LPUTF8Str)] string destinationName, IntPtr source, [MarshalAs(UnmanagedType.LPUTF8Str)] string sourceName);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_backup_step(IntPtr backup, int pages);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_backup_finish(IntPtr backup);
    }
}

public sealed class SqliteStoreException(int code, string message) : IOException(message)
{
    public int SqliteCode { get; } = code;
    public bool Busy => (SqliteCode & 255) is 5 or 6;
}
