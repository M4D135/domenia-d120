namespace Domenia.Store;

/// <summary>Same-volume publication; callers own their interprocess lock and semantic validation.</summary>
internal static class AtomicLocalFile
{
    internal static string? Write(string path, ReadOnlySpan<byte> bytes, bool replace, CancellationToken token, bool keepPrevious = false)
    {
        CompatibleDirectoryCache.ValidateLocalPath(path);
        var folder = Path.GetDirectoryName(path)!;
        var temporary = Path.Combine(folder, ".domenia-" + Guid.NewGuid().ToString("N") + ".tmp");
        CompatibleDirectoryCache.ValidateLocalPath(temporary);
        token.ThrowIfCancellationRequested();
        Directory.CreateDirectory(folder);
        var created = false;
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                created = true;
                const int block = 128 * 1024;
                for (var offset = 0; offset < bytes.Length; offset += block)
                { token.ThrowIfCancellationRequested(); stream.Write(bytes.Slice(offset, Math.Min(block, bytes.Length - offset))); }
                stream.Flush(flushToDisk: true);
            }
            token.ThrowIfCancellationRequested();
            CompatibleDirectoryCache.ValidateLocalPath(path);
            if (replace && keepPrevious && File.Exists(path))
            {
                // Never replace an earlier recovery version. File.Replace publishes the new file and preserves
                // the exact replaced version atomically, unlike a copy made before a separate rename.
                var backup = path + ".bak-" + Guid.NewGuid().ToString("N");
                CompatibleDirectoryCache.ValidateLocalPath(backup);
                File.Replace(temporary, path, backup);
                created = false;
                return backup;
            }
            File.Move(temporary, path, overwrite: replace);
            created = false;
            return null;
        }
        finally
        {
            if (created) { CompatibleDirectoryCache.ValidateLocalPath(temporary); File.Delete(temporary); }
        }
    }
}
