using System.Diagnostics;
using System.Text;

namespace Domenia.Store;

/// <summary>Cooperative D2 connection barrier; the switch additionally holds a real OS deny-write handle on the database.</summary>
internal static class StorageWriteFence
{
    internal static string Marker(string path) => path + ".domenia-readonly";

    internal static IDisposable Writer(string path, CancellationToken token)
    {
        var lease = Open(path, exclusive: false, token);
        try
        {
            if (File.Exists(Marker(path))) { throw new IOException("Ancienne base protégée après bascule ; aucune écriture autorisée à cet emplacement."); }
            return lease;
        }
        catch { lease.Dispose(); throw; }
    }

    internal static IDisposable Exclusive(string path, CancellationToken token) => Open(path, exclusive: true, token);

    private static FileStream Open(string path, bool exclusive, CancellationToken token)
    {
        var lockPath = path + ".domenia-write.lock";
        CompatibleDirectoryCache.ValidateLocalPath(lockPath);
        var elapsed = Stopwatch.StartNew();
        while (true)
        {
            token.ThrowIfCancellationRequested();
            try
            {
                if (!File.Exists(lockPath))
                {
                    using var created = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite);
                    created.Flush(flushToDisk: true);
                }
                return new FileStream(lockPath, FileMode.Open, exclusive ? FileAccess.ReadWrite : FileAccess.Read, exclusive ? FileShare.None : FileShare.Read);
            }
            catch (IOException) when (elapsed.Elapsed < TimeSpan.FromSeconds(5)) { token.WaitHandle.WaitOne(50); }
        }
    }

    internal static void Protect(string path, string transaction)
    {
        var marker = Marker(path); CompatibleDirectoryCache.ValidateLocalPath(marker);
        if (File.Exists(marker))
        {
            if (new FileInfo(marker).Length > 128 || File.ReadAllText(marker) != transaction) { throw new IOException("Marqueur d’une autre bascule ; protection conservée."); }
            return;
        }
        using var file = new FileStream(marker, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 128, FileOptions.WriteThrough);
        file.Write(Encoding.UTF8.GetBytes(transaction)); file.Flush(flushToDisk: true);
    }

    internal static void Unprotect(string path, string transaction)
    {
        var marker = Marker(path); CompatibleDirectoryCache.ValidateLocalPath(marker);
        if (!File.Exists(marker)) { return; }
        if (new FileInfo(marker).Length > 128 || File.ReadAllText(marker) != transaction) { throw new IOException("Marqueur d’une autre bascule ; aucune protection retirée."); }
        File.Delete(marker);
    }
}
