using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>Private process-owned spool. Opening a screen never creates it; only an explicitly requested read does.</summary>
internal sealed class SyncBatchFile : ISyncBatchLease
{
    private const long MaximumBytes = 256L * 1024 * 1024;
    private const int MaximumLine = 1024 * 1024;
    private const int MaximumRows = 300_000;
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private sealed record Line(string Kind, SyncBatchHeader? Header = null, IndexRecord? Row = null, AbsenceRecord? Absence = null, Guid? Gap = null);
    private readonly Lock gate = new();
    private FileStream? stream;
    public SyncBatchHeader Header { get; }
    public long Bytes { get; }
    public string Sha256 { get; }
    internal string Path { get; }

    private SyncBatchFile(string path, FileStream file, SyncBatchHeader header, long bytes, string sha)
    { Path = path; stream = file; Header = header; Bytes = bytes; Sha256 = sha; }

    internal static SyncBatchFile Stage(DomeniaDatabase database, SyncStagedBatch batch, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        Validate(batch, database.StoreId, database.DomainDn);
        var path = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(database.Path)!, "SyncPending", batch.Header.SessionId, batch.Header.Id + ".jsonl");
        CompatibleDirectoryCache.ValidateLocalPath(path);
        var root = System.IO.Path.GetPathRoot(path)!;
        // The count is an admission estimate; the exact growing size is checked again before every line.
        EnsureSpace(root, 0);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        CompatibleDirectoryCache.ValidateLocalPath(path);
        var file = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read, 64 * 1024,
            FileOptions.SequentialScan | FileOptions.DeleteOnClose);
        try
        {
            using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long lastSpaceCheck = -1024 * 1024;
            void Write(Line line)
            {
                token.ThrowIfCancellationRequested();
                var bytes = JsonSerializer.SerializeToUtf8Bytes(line);
                if (bytes.Length > MaximumLine || file.Length + bytes.Length + 1 > MaximumBytes)
                { throw new InvalidDataException("Lot de synchronisation trop volumineux ; aucune écriture dans la base."); }
                if (file.Length - lastSpaceCheck >= 1024 * 1024)
                { EnsureSpace(root, Math.Max(bytes.Length + 1, 1024 * 1024)); lastSpaceCheck = file.Length; }
                file.Write(bytes); file.WriteByte((byte)'\n');
                digest.AppendData(bytes); digest.AppendData([(byte)'\n']);
            }
            Write(new("header", Header: batch.Header));
            foreach (var row in batch.Rows) { Write(new("row", Row: row)); }
            foreach (var row in batch.Absences) { Write(new("absence", Absence: row)); }
            foreach (var id in batch.ResolvedGaps) { Write(new("gap", Gap: id)); }
            file.Flush(flushToDisk: true);
            var lease = new SyncBatchFile(path, file, batch.Header, file.Length, Convert.ToHexStringLower(digest.GetHashAndReset()));
            // Re-read the same held file before handing a reference to the UI/executor.
            _ = lease.Read(token);
            return lease;
        }
        catch { file.Dispose(); throw; }
    }

    public Task<SyncStagedBatch> ReadAsync(CancellationToken cancellationToken) => Task.Run(() => Read(cancellationToken), cancellationToken);

    private SyncStagedBatch Read(CancellationToken token)
    {
        lock (gate)
        {
            token.ThrowIfCancellationRequested();
            var file = stream ?? throw new InvalidDataException("Lot temporaire fermé ou abandonné ; relancez une lecture.");
            if (file.Length != Bytes || Bytes is <= 0 or > MaximumBytes) { throw new InvalidDataException("Taille du lot temporaire modifiée."); }
            file.Position = 0;
            using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            using var reader = new StreamReader(file, Utf8, detectEncodingFromByteOrderMarks: false, bufferSize: 64 * 1024, leaveOpen: true);
            SyncBatchHeader? header = null;
            var rows = ImmutableArray.CreateBuilder<IndexRecord>(); var absences = ImmutableArray.CreateBuilder<AbsenceRecord>(); var gaps = ImmutableArray.CreateBuilder<Guid>();
            long bytesRead = 0; var number = 0;
            var lines = new BoundedLines(reader);
            while (lines.Read(token) is { } text)
            {
                var bytes = Utf8.GetBytes(text);
                bytesRead = checked(bytesRead + bytes.Length + 1);
                if (bytesRead > Bytes) { throw new InvalidDataException("Lot temporaire plus grand que son reçu."); }
                digest.AppendData(bytes); digest.AppendData([(byte)'\n']);
                var line = JsonSerializer.Deserialize<Line>(bytes) ?? throw new InvalidDataException("Ligne de lot absente.");
                if (number++ == 0)
                {
                    if (line.Kind != "header" || line.Header != Header || line.Row is not null || line.Absence is not null || line.Gap is not null)
                    { throw new InvalidDataException("Identité du lot temporaire modifiée."); }
                    header = line.Header;
                }
                else if (line.Kind == "row" && line.Row is { } row && line.Header is null && line.Absence is null && line.Gap is null && rows.Count < Header.Rows) { rows.Add(row); }
                else if (line.Kind == "absence" && line.Absence is { } absence && line.Header is null && line.Row is null && line.Gap is null && absences.Count < Header.Absences) { absences.Add(absence); }
                else if (line.Kind == "gap" && line.Gap is { } gap && line.Header is null && line.Row is null && line.Absence is null && gaps.Count < Header.ResolvedGaps) { gaps.Add(gap); }
                else { throw new InvalidDataException("Type ou nombre de lignes du lot temporaire invalide."); }
            }
            if (bytesRead != Bytes || Convert.ToHexStringLower(digest.GetHashAndReset()) != Sha256 || header is null)
            { throw new InvalidDataException("Empreinte du lot temporaire différente ; aucune donnée réutilisée."); }
            var result = new SyncStagedBatch(header, rows.ToImmutable(), absences.ToImmutable(), gaps.ToImmutable());
            Validate(result, Header.StoreId, Header.DomainDn);
            return result;
        }
    }

    private sealed class BoundedLines(StreamReader reader)
    {
        private readonly char[] buffer = new char[8192];
        private int position;
        private int count;
        internal string? Read(CancellationToken token)
        {
            var text = new StringBuilder();
            while (true)
            {
                token.ThrowIfCancellationRequested();
                if (position == count)
                {
                    position = 0; count = reader.Read(buffer);
                    if (count == 0)
                    {
                        if (text.Length != 0) { throw new InvalidDataException("Dernière ligne du lot incomplète."); }
                        return null;
                    }
                }
                var end = Array.IndexOf(buffer, '\n', position, count - position);
                var length = (end < 0 ? count : end) - position;
                if (text.Length + length > MaximumLine || Array.IndexOf(buffer, '\r', position, length) >= 0)
                { throw new InvalidDataException("Ligne du lot invalide ou trop longue."); }
                text.Append(buffer, position, length); position += length;
                if (end >= 0) { position++; return text.ToString(); }
            }
        }
    }

    private static void Validate(SyncStagedBatch batch, string storeId, string domain)
    {
        var h = batch.Header;
        if (!WritePlans.IsPlanId(h.Id) || !WritePlans.IsPlanId(h.SessionId) || h.StoreId != storeId || !DistinguishedName.AreEqual(h.DomainDn, domain)
            || h.Revision < 0 || h.Epoch < 0 || h.Expires <= h.At || h.Expires - h.At > TimeSpan.FromMinutes(15)
            || h.BeforeSha256.Length != 64 || !h.BeforeSha256.All(char.IsAsciiHexDigit) || h.Label.Length is 0 or > 1024
            || batch.Rows.IsDefault || batch.Absences.IsDefault || batch.ResolvedGaps.IsDefault
            || h.Rows != batch.Rows.Length || h.Absences != batch.Absences.Length || h.ResolvedGaps != batch.ResolvedGaps.Length
            || h.Rows > MaximumRows || h.Absences > MaximumRows || h.ResolvedGaps > MaximumRows)
        { throw new InvalidDataException("Contexte, taille ou identité du lot temporaire invalide."); }
        if (h.Coverage is { } coverage && !SyncLocations.InScope(coverage.BaseDn, domain))
        { throw new InvalidDataException("Couverture du lot hors domaine."); }
        var ids = new HashSet<Guid>();
        foreach (var row in batch.Rows)
        {
            if (row.ObjectGuid == Guid.Empty || !ids.Add(row.ObjectGuid) || !SyncLocations.InScope(row.Dn, domain))
            { throw new InvalidDataException("Objet sans identité, dupliqué ou hors domaine dans le lot temporaire."); }
        }
        ids.Clear();
        foreach (var row in batch.Absences)
        {
            if (row.ObjectGuid == Guid.Empty || !ids.Add(row.ObjectGuid) || !SyncLocations.InScope(row.LastDn, domain) || !SyncLocations.InScope(row.ScopeDn, domain)
                || row.FoundDn is { } found && !SyncLocations.InScope(found, domain))
            { throw new InvalidDataException("Disparition sans identité, dupliquée ou hors domaine dans le lot temporaire."); }
        }
        if (batch.ResolvedGaps.Any(x => x == Guid.Empty) || batch.ResolvedGaps.Distinct().Count() != batch.ResolvedGaps.Length)
        { throw new InvalidDataException("Écarts du lot temporaire sans identité ou dupliqués."); }
    }

    private static void EnsureSpace(string root, int nextBytes)
    {
        if (new DriveInfo(root).AvailableFreeSpace < 32L * 1024 * 1024 + 4L * nextBytes)
        { throw new IOException("Espace libre insuffisant pour conserver la lecture temporaire ; la base est inchangée."); }
    }

    public void Dispose()
    {
        lock (gate)
        {
            // DeleteOnClose removes only this process-owned file, including after a failed/abandoned read.
            stream?.Dispose(); stream = null;
        }
    }
}
