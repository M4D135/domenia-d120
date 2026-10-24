using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>Bounded D1 TSV, protected by the same sidecar lock as legacy consoles. Never steals a stale lock.</summary>
internal static class SharedParkFile
{
    internal const int MaxBytes = 16 * 1024 * 1024;
    internal const int MaxRows = 50_000;
    internal const int MaxLineChars = 4096;
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private static ReadOnlySpan<byte> ByteOrderMark => [0xEF, 0xBB, 0xBF];
    internal sealed record Read(bool Exists, byte[] Bytes, string Sha256, ImmutableArray<SharedParkLine> Rows);
    internal sealed record Lease(FileStream Stream, int Attempts) : IDisposable { public void Dispose() => Stream.Dispose(); }
    internal static string PathValue(string path)
    {
        if (path.Length is 0 or > 1024 || !System.IO.Path.IsPathFullyQualified(path) || path.Any(char.IsControl)
            || path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal)
            || path.EndsWith(".db", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".lock", StringComparison.OrdinalIgnoreCase)
            || path.AsSpan(System.IO.Path.GetPathRoot(path)!.Length).Contains(':'))
        { throw new InvalidDataException("ParkSweep.SharedPath doit désigner un fichier absolu ordinaire, hors base SQLite et flux alternatif."); }
        return System.IO.Path.GetFullPath(path);
    }
    internal static async Task<Lease> LockAsync(string path, CancellationToken token)
    {
        PathValue(path);
        for (var attempt = 1; attempt <= SyncPark.LockAttempts; attempt++)
        {
            token.ThrowIfCancellationRequested();
            try
            {
                var file = await Task.Run(() => new FileStream(path + ".lock", FileMode.CreateNew, FileAccess.Write, FileShare.None,
                    4096, FileOptions.DeleteOnClose | FileOptions.WriteThrough), token).ConfigureAwait(false);
                return new(file, attempt);
            }
            // 183/80/17: another console already created the sidecar; 32/33: it is held open, on a local disk or a share.
            catch (IOException ex) when ((ex.HResult & 0xffff) is 80 or 183 or 17 or 32 or 33)
            {
                if (attempt == SyncPark.LockAttempts) { throw new DomeniaOperationException("sync.sharedLockBusy", "Verrou partagé occupé après 12 essais ; aucun rejeu automatique. Relancez la lecture après libération du verrou."); }
                await Task.Delay(250, token).ConfigureAwait(false);
            }
        }
        throw new InvalidOperationException("Nombre d’essais de verrou incohérent.");
    }
    internal static Read ReadFile(string path, DateTimeOffset now, CancellationToken token)
    {
        PathValue(path); token.ThrowIfCancellationRequested();
        byte[] bytes;
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length > MaxBytes) { throw new InvalidDataException("Relevé partagé supérieur à 16 Mio ; aucune lecture partielle utilisée."); }
            bytes = new byte[checked((int)file.Length)]; file.ReadExactly(bytes);
            if (file.ReadByte() != -1) { throw new InvalidDataException("Fichier partagé modifié pendant la lecture."); }
        }
        catch (FileNotFoundException) { return new(false, [], Hash([]), []); }
        token.ThrowIfCancellationRequested();
        var text = Decode(bytes);
        var rows = ImmutableArray.CreateBuilder<SharedParkLine>(); var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using var reader = new StringReader(text);
        while (reader.ReadLine() is { } line)
        {
            token.ThrowIfCancellationRequested(); if (line.Length == 0) { continue; }
            if (line.Length > MaxLineChars || rows.Count >= MaxRows) { throw new InvalidDataException("Relevé partagé hors limites (50 000 postes, 4 096 caractères par ligne)."); }
            var fields = line.Split('\t');
            if (fields.Length is < 5 or > 6 || !DateTimeOffset.TryParse(fields[1], CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at)
                || at <= DateTimeOffset.UnixEpoch || at > now.AddMinutes(2)
                || !int.TryParse(fields[4], NumberStyles.None, CultureInfo.InvariantCulture, out var attempts))
            { throw new InvalidDataException("Ligne TSV partagée invalide ; le fichier est conservé sans réécriture."); }
            var row = new SharedParkLine(fields[0], at, fields[2], Empty(fields[3]), attempts, fields.Length == 6 ? Empty(fields[5]) : null);
            Validate(row); if (!names.Add(row.Computer)) { throw new InvalidDataException("Poste dupliqué dans le relevé partagé ; aucune fusion ambiguë."); }
            rows.Add(row);
        }
        return new(true, bytes, Hash(bytes), rows.ToImmutable());
    }
    internal static void Validate(SharedParkLine row)
    {
        // U+FEFF is not a control character for char.IsControl: the only one ever admitted is the file preamble, removed by Decode before this point.
        if (row.Computer.Length is 0 or > 255 || row.Computer.Trim() != row.Computer || row.Computer.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not '.' and not '-' and not '_')
            || row.Status.Length is 0 or > 100 || row.Status.Any(char.IsControl) || row.Status.Contains('\uFEFF')
            || row.At <= DateTimeOffset.UnixEpoch || row.Attempts < 0
            || row.User?.Length > 320 || row.User?.Any(char.IsControl) == true || row.User?.Contains('\uFEFF') == true
            || row.ProbedBy?.Length > 320 || row.ProbedBy?.Any(char.IsControl) == true || row.ProbedBy?.Contains('\uFEFF') == true)
        { throw new InvalidDataException("Valeur du relevé partagé non qualifiée ; aucune ligne tronquée ni corrigée implicitement."); }
    }
    internal static byte[] Encode(ImmutableArray<SharedParkLine> rows)
    {
        if (rows.IsDefault) { throw new InvalidDataException("Fusion absente ; aucun octet produit."); }
        if (rows.Length > MaxRows) { throw new InvalidDataException("Fusion supérieure à 50 000 postes."); }
        var text = new StringBuilder();
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in rows.OrderBy(x => x.Computer, StringComparer.OrdinalIgnoreCase))
        {
            Validate(row);
            if (!names.Add(row.Computer)) { throw new InvalidDataException("Deux postes du relevé portent le même nom sans distinction de casse ; aucune écriture ambiguë."); }
            var line = string.Create(CultureInfo.InvariantCulture, $"{row.Computer}\t{row.At.ToUniversalTime():O}\t{row.Status}\t{row.User}\t{row.Attempts}\t{row.ProbedBy}");
            if (line.Length > MaxLineChars) { throw new InvalidDataException("Ligne du relevé partagé dépassant 4 096 caractères ; aucune écriture tronquée."); }
            text.Append(line).Append('\n');
            if (text.Length > MaxBytes) { throw new InvalidDataException("Fusion supérieure à 16 Mio."); }
        }
        var bytes = Utf8.GetBytes(text.ToString());
        if (bytes.Length > MaxBytes) { throw new InvalidDataException("Fusion supérieure à 16 Mio UTF-8."); }
        return bytes;
    }
    internal static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    /// <summary>Strict UTF-8 with at most one leading byte order mark: a broken byte never becomes a replacement character, and U+FEFF elsewhere is refused by <see cref="Validate"/>.</summary>
    private static string Decode(byte[] bytes)
    {
        var offset = bytes.StartsWith(ByteOrderMark) ? ByteOrderMark.Length : 0;
        string text;
        try { text = Utf8.GetString(bytes, offset, bytes.Length - offset); }
        catch (DecoderFallbackException ex) { throw new InvalidDataException("Relevé partagé non décodable en UTF-8 strict ; aucun caractère de remplacement, le fichier est conservé tel quel.", ex); }
        if (text.StartsWith('\uFEFF')) { throw new InvalidDataException("Un seul jeu d’octets de début UTF-8 est admis, au tout début du relevé partagé."); }
        return text;
    }
    private static string? Empty(string value) => value.Length == 0 ? null : value;
}
