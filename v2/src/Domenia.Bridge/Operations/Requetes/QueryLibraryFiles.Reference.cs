using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Security.AccessControl;
using System.Security.Principal;
using Domenia.Core.Queries;

namespace Domenia.Bridge.Operations.Requetes;

public sealed partial class QueryLibraryFiles
{
    public Task<byte[]?> ReadReferenceAsync(string rootKey, CancellationToken token) => Task.Run(() => ReferenceRead(PathOf(rootKey)), token);
    private static void QualifyReferencePath(string path)
    {
        if (path.StartsWith(@"\\", StringComparison.Ordinal) || new DriveInfo(Path.GetPathRoot(path)!).DriveType != DriveType.Fixed)
        { throw new QueryDefinitionException("La bibliothèque de référence doit être sur un disque local fixe."); }
        using var parents = ReferenceFileAccess.PinParents(path, allowMissing: true);
        using var terminal = ReferenceFileAccess.OpenRead(path, allowMissing: true);
    }

    private static byte[]? ReferenceRead(string path, bool verifyProofs = true, long maximum = MaxFileBytes)
    {
        QualifyReferencePath(path);
        using var parents = ReferenceFileAccess.PinParents(path, allowMissing: true);
        if (verifyProofs) { VerifyReferenceProofs(path); }
        try
        {
            using var stream = ReferenceFileAccess.OpenRead(path, allowMissing: true);
            if (stream is null) { return null; }
            if (stream.Length > maximum) { throw new QueryDefinitionException("Fichier de bibliothèque ou preuve hors limites."); }
            var bytes = new byte[checked((int)stream.Length)]; stream.ReadExactly(bytes);
            if (stream.ReadByte() != -1) { throw new QueryDefinitionException("Bibliothèque modifiée pendant sa lecture."); }
            return bytes;
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    private sealed record ReferenceIntent(string BeforeSha256, string AfterSha256, string Backup);
    private static void WriteReferenceEvidence(string path, byte[] bytes)
    {
        using var user = WindowsIdentity.GetCurrent(); var security = new FileSecurity(); security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { user.User ?? throw new IOException("Identité Windows absente."), new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) }.DistinctBy(s => s.Value))
        { security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow)); }
        using var file = FileSystemAclExtensions.Create(new FileInfo(path), FileMode.CreateNew, FileSystemRights.FullControl, FileShare.None, 4096, FileOptions.WriteThrough, security);
        file.Write(bytes); file.Flush(true);
    }
    private static string ReferenceSha(byte[]? value) => value is null ? "absent" : Convert.ToHexStringLower(SHA256.HashData(value));
    private static void VerifyReferenceProofs(string path)
    {
        var directory = Path.GetDirectoryName(path)!;
        if (!Directory.Exists(directory)) { return; }
        var intents = Directory.EnumerateFiles(directory, Path.GetFileName(path) + ".reference-*.intent").Take(129).ToArray();
        if (intents.Length > 128) { throw new QueryDefinitionException("Trop de transactions de référence conservées ; réconciliation nécessaire."); }
        long backupBytes = 0;
        foreach (var intentPath in intents)
        {
            QualifyReferencePath(intentPath);
            if (new FileInfo(intentPath).Length > 2048) { throw new QueryDefinitionException("Intention de référence hors limites."); }
            var bytes = ReferenceRead(intentPath, false, 2048)!;
            ReferenceIntent? intent;
            try { intent = JsonSerializer.Deserialize<ReferenceIntent>(bytes); }
            catch (JsonException) { throw new QueryDefinitionException("Intention de référence illisible ; aucune nouvelle application."); }
            var prefix = intentPath[..^7];
            var verified = ReferenceRead(prefix + ".verified", false, 64);
            if (intent is null || intent.Backup != Path.GetFileName(prefix + ".previous") || !QueryReferenceCodec.IsHash(intent.AfterSha256)
                || intent.BeforeSha256 != "absent" && !QueryReferenceCodec.IsHash(intent.BeforeSha256)
                || verified is null || !verified.AsSpan().SequenceEqual(Encoding.ASCII.GetBytes(ReferenceSha(bytes))))
            { throw new QueryDefinitionException("Transaction de référence non confirmée ; preuves conservées, réconciliation explicite nécessaire."); }
            if (intent.BeforeSha256 != "absent")
            {
                var previous = ReferenceRead(prefix + ".previous", false); backupBytes += previous?.LongLength ?? 0;
                if (backupBytes > 128L * 1024 * 1024 || ReferenceSha(previous) != intent.BeforeSha256)
                { throw new QueryDefinitionException("Original de référence différent, absent ou hors quota ; état incertain, aucune application supplémentaire."); }
            }
        }
    }

    // Called only under the existing interprocess mutex. No cleanup of old backups or ambiguous artifacts.
    private QueryStoreWrite UpdateReference(string path, byte[]? expected, QueryStoreUpdate next, CancellationToken token)
    {
        QualifyReferencePath(path);
        using var parents = ReferenceFileAccess.PinParents(path);
        var entries = Directory.EnumerateFileSystemEntries(Path.GetDirectoryName(path)!, Path.GetFileName(path) + ".reference-*").Take(514).ToArray();
        long total = 0;
        if (entries.Length > 508) { throw new QueryDefinitionException("Quota de 512 preuves de bibliothèque atteint ; preuves conservées."); }
        if (entries.Count(p => p.EndsWith(".intent", StringComparison.Ordinal)) >= 128)
        { throw new QueryDefinitionException("Quota de 128 transactions de référence atteint ; preuves conservées."); }
        foreach (var entry in entries)
        {
            QualifyReferencePath(entry); total = checked(total + new FileInfo(entry).Length);
            if (total + next.Document.LongLength + (expected?.LongLength ?? 0) > 128L * 1024 * 1024)
            { throw new QueryDefinitionException("Quota de 128 Mio de preuves de bibliothèque atteint ; preuves conservées."); }
        }
        if (total + next.Document.LongLength + (expected?.LongLength ?? 0) + 4096 > 128L * 1024 * 1024)
        { throw new QueryDefinitionException("Quota de 128 Mio de preuves de bibliothèque atteint ; preuves conservées."); }
        var current = ReferenceRead(path);
        if ((current is null) != (expected is null) || current is not null && !current.AsSpan().SequenceEqual(expected))
        { throw new QueryDefinitionException("Bibliothèque modifiée avant préparation ; patch refusé."); }
        var suffix = Guid.NewGuid().ToString("N"); var temporary = path + ".reference-" + suffix + ".prepared";
        var backup = path + ".reference-" + suffix + ".previous";
        if (File.Exists(backup) || Directory.Exists(backup)) { throw new QueryDefinitionException("Nom de sauvegarde déjà occupé ; aucune copie écrasée."); }
        WriteReferenceEvidence(temporary, next.Document);
        if (ReferenceRead(temporary) is not { } prepared || !prepared.AsSpan().SequenceEqual(next.Document))
        { throw new QueryDefinitionException("Copie préparée différente ; preuves conservées."); }
        current = ReferenceRead(path);
        if ((current is null) != (expected is null) || current is not null && !current.AsSpan().SequenceEqual(expected))
        { throw new QueryDefinitionException("Bibliothèque modifiée pendant préparation ; preuves conservées."); }
        next.ValidateContext!.Invoke(); token.ThrowIfCancellationRequested(); QualifyReferencePath(path);
        var intentBytes = JsonSerializer.SerializeToUtf8Bytes(new ReferenceIntent(ReferenceSha(expected), ReferenceSha(next.Document), Path.GetFileName(backup)));
        var intentPath = path + ".reference-" + suffix + ".intent";
        WriteReferenceEvidence(intentPath, intentBytes);
        // File.Replace retains the file actually displaced, including a non-cooperative change after the final observation.
        try
        {
            if (expected is null) { File.Move(temporary, path); }
            else { File.Replace(temporary, path, backup, ignoreMetadataErrors: false); }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { throw new QueryDefinitionException("Publication de bibliothèque incertaine ; conservez les fichiers .reference- et relisez le reçu avant toute action."); }
        var previous = expected is null ? null : ReferenceRead(backup);
        var after = ReferenceRead(path, false);
        if (expected is not null && (previous is null || !previous.AsSpan().SequenceEqual(expected)))
        { throw new QueryDefinitionException("Le fichier réellement remplacé diffère de l’aperçu ; il reste conservé. Résultat incertain, aucune compensation automatique."); }
        if (after is null || !after.AsSpan().SequenceEqual(next.Document))
        { throw new QueryDefinitionException("Bibliothèque finale différente ; intention non confirmée conservée, résultat incertain."); }
        WriteReferenceEvidence(path + ".reference-" + suffix + ".verified", Encoding.ASCII.GetBytes(ReferenceSha(intentBytes)));
        VerifyReferenceProofs(path);
        return new QueryStoreWrite(true, true)
        { Source = "Fichier local", DocumentSha256 = after is null ? null : Convert.ToHexStringLower(SHA256.HashData(after)) };
    }
}
