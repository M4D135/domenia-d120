using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>Native Windows SQLite. One owner per connection, bound values, explicit transactions.</summary>
internal sealed class SqliteDatabase : IDisposable
{
    private IntPtr handle;
    private readonly CancellationToken cancellationToken;
    private readonly Native.Progress progress;
    private bool transaction;

    public SqliteDatabase(string path, bool readOnly, int busyTimeoutMs = 2500, CancellationToken cancellationToken = default)
    {
        this.cancellationToken = cancellationToken;
        progress = _ => cancellationToken.IsCancellationRequested ? 1 : 0;
        var code = Native.sqlite3_open_v2(path, out handle, (readOnly ? 1 : 2 | 4) | 65536, IntPtr.Zero);
        if (code != 0)
        {
            Dispose();
            throw new SqliteStoreException(code, "Ouverture de la base impossible ; aucun fichier n’a été remplacé.");
        }
        Native.sqlite3_busy_timeout(handle, Math.Clamp(busyTimeoutMs, 100, 5000));
        Native.sqlite3_progress_handler(handle, 1000, progress, IntPtr.Zero);
    }

    public List<Dictionary<string, object?>> Query(string sql, params object?[] values)
    {
        using var statement = Prepare(sql, values);
        var rows = new List<Dictionary<string, object?>>();
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var code = Native.sqlite3_step(statement.Handle);
            if (code == 101) { return rows; }
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
            rows.Add(row);
        }
    }

    public long Execute(string sql, params object?[] values)
    {
        using var statement = Prepare(sql, values);
        Check(Native.sqlite3_step(statement.Handle), 101);
        return Native.sqlite3_changes(handle);
    }

    public object? Scalar(string sql, params object?[] values) => Query(sql, values).FirstOrDefault()?.Values.FirstOrDefault();

    /// <summary>Only for embedded schema and fixed PRAGMAs, never interpolated application values.</summary>
    public void Script(string sql)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var code = Native.sqlite3_exec(handle, sql, IntPtr.Zero, IntPtr.Zero, out var error);
        if (error != IntPtr.Zero) { Native.sqlite3_free(error); }
        Check(code);
    }

    public void Begin(bool write = true)
    {
        if (transaction) { throw new InvalidOperationException("Transaction déjà ouverte."); }
        Script(write ? "BEGIN IMMEDIATE;" : "BEGIN;");
        transaction = true;
    }

    public void Commit()
    {
        if (!transaction) { throw new InvalidOperationException("Aucune transaction."); }
        Script("COMMIT;");
        transaction = false;
    }

    public void Rollback()
    {
        if (!transaction) { return; }
        var code = Native.sqlite3_exec(handle, "ROLLBACK;", IntPtr.Zero, IntPtr.Zero, out var error);
        if (error != IntPtr.Zero) { Native.sqlite3_free(error); }
        transaction = false;
        Check(code);
    }

    public void BackupTo(SqliteDatabase destination)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var backup = Native.sqlite3_backup_init(destination.handle, "main", handle, "main");
        if (backup == IntPtr.Zero) { throw new SqliteStoreException(Native.sqlite3_errcode(destination.handle), "Sauvegarde SQLite non initialisée."); }
        var step = 0;
        var finish = 0;
        try
        {
            do
            {
                cancellationToken.ThrowIfCancellationRequested();
                step = Native.sqlite3_backup_step(backup, 256);
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
        var bytes = Encoding.UTF8.GetBytes(sql + "\0");
        var pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        IntPtr prepared = IntPtr.Zero;
        try
        {
            var start = pin.AddrOfPinnedObject();
            Check(Native.sqlite3_prepare_v2(handle, start, bytes.Length, out prepared, out var tail));
            var trailing = Marshal.PtrToStringUTF8(tail) ?? "";
            if (prepared == IntPtr.Zero || !string.IsNullOrWhiteSpace(trailing)) { throw new ArgumentException("Une seule instruction SQL est admise.", nameof(sql)); }
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
            var result = new Statement(prepared);
            prepared = IntPtr.Zero;
            return result;
        }
        finally
        {
            if (prepared != IntPtr.Zero) { Native.sqlite3_finalize(prepared); }
            pin.Free();
        }
    }

    private void Check(int code, int expected = 0)
    {
        if (code == expected) { return; }
        if (code == 9) { cancellationToken.ThrowIfCancellationRequested(); }
        if ((code & 255) is 5 or 6) { OperationsMeasurements.RecordSqliteBusy(); }
        throw new SqliteStoreException(code, code is 5 or 6 ? "Base occupée ; aucun résultat vide n’a été substitué." : "Opération SQLite interrompue (code " + code.ToString(CultureInfo.InvariantCulture) + ").");
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
        if (handle == IntPtr.Zero) { return; }
        // close_v2 rolls back an uncommitted transaction and releases the connection after its statements.
        Native.sqlite3_close_v2(handle);
        handle = IntPtr.Zero;
        GC.KeepAlive(progress);
    }

    private sealed class Statement(IntPtr handle) : IDisposable
    {
        public IntPtr Handle { get; } = handle;
        public void Dispose() => Native.sqlite3_finalize(Handle);
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
    public bool Busy => SqliteCode is 5 or 6;
}
