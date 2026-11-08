using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private sealed class DirectoryStage(string path, FileStream file, string hash) : IDisposable
    {
        public string Hash { get; } = hash;
        public IEnumerable<StoredObject> Objects()
        {
            file.Position = 0;
            using var reader = new StreamReader(file, new UTF8Encoding(false, true), false, 65536, leaveOpen: true);
            _ = reader.ReadLine() ?? throw new InvalidDataException("En-tête du lot absent.");
            while (reader.ReadLine() is { } line)
            {
                if (line.Length == 0) continue;
                yield return JsonSerializer.Deserialize<StoredObject>(line, Json) ?? throw new InvalidDataException("Ligne du lot illisible.");
            }
        }
        public void Delete() { file.Dispose(); File.Delete(path); }
        public void Dispose() => file.Dispose();
    }

    /// <summary>One bounded object buffer, not whole-census strings/UTF-8/decoded copies. The retained stage stays opened
    /// read-only without write/delete sharing from hash verification through transaction completion.</summary>
    private DirectoryStage OpenDirectoryStage(string batchId, StoredDirectoryHeader header, IEnumerable<StoredObject> objects,
        int expectedCount, ScopeSelection scope, CancellationToken token)
    {
        var folder = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Path)!, "Staging");
        Directory.CreateDirectory(folder);
        var staged = System.IO.Path.Combine(folder, batchId + ".jsonl");
        CompatibleDirectoryCache.ValidateLocalPath(staged);
        using var expected = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        long expectedBytes = 0;
        using (var output = File.Exists(staged) ? null : new FileStream(staged, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.WriteThrough))
        {
            void Line<T>(T item)
            {
                token.ThrowIfCancellationRequested();
                var bytes = JsonSerializer.SerializeToUtf8Bytes(item, Json);
                // The outer JSONL wrapper escapes the typed JSON once. This is an explicit per-object refusal.
                if (bytes.Length > 16 * 1024 * 1024) throw new InvalidDataException("Un objet dépasse la limite du lot local ; aucune troncature effectuée.");
                expectedBytes = checked(expectedBytes + bytes.Length + 1);
                expected.AppendData(bytes); expected.AppendData("\n"u8);
                output?.Write(bytes); output?.WriteByte((byte)'\n');
            }
            Line(header);
            var ids = new HashSet<Guid>();
            foreach (var obj in objects)
            {
                if (obj.Guid == Guid.Empty || !InReadScope(scope, obj.Dn) || !ids.Add(obj.Guid))
                    throw new InvalidDataException("Lot hors périmètre ou identités dupliquées : aucune écriture.");
                Line(obj);
            }
            if (ids.Count != expectedCount) throw new InvalidDataException("Compte du lot incohérent.");
            if (expectedCount == 0)
            {
                // Preserve the historical empty JSONL batch fingerprint (header + two newlines).
                expected.AppendData("\n"u8); expectedBytes++; output?.WriteByte((byte)'\n');
            }
            output?.Flush(flushToDisk: true);
        }
        var hash = Convert.ToHexStringLower(expected.GetHashAndReset());
        var input = new FileStream(staged, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan);
        try
        {
            if (input.Length != expectedBytes || Convert.ToHexStringLower(SHA256.HashData(input)) != hash)
                throw new InvalidDataException("Identifiant de lot déjà utilisé avec un contenu différent.");
            return new(staged, input, hash);
        }
        catch { input.Dispose(); throw; }
    }
}
