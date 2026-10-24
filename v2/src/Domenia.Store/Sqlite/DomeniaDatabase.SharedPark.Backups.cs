using System.Collections.Immutable;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using Domenia.Core;
using Microsoft.Win32.SafeHandles;

namespace Domenia.Store;

/// <summary>Copies already created and independently re-read. Null means an observed absence, never a zero-byte substitute.
/// This is neither an intention nor a receipt, and does not authorize publication or replay.</summary>
internal sealed record SharedParkVerifiedBackups(SharedParkBackupReference? SqliteBackup, SharedParkBackupReference? TsvBackup,
    string? SqliteLogicalFingerprint);

public sealed partial class DomeniaDatabase
{
    /// <summary>
    /// Captures the sources of an unexpired preview, without changing either source. The caller supplies an EXISTING dedicated
    /// local private directory; its ACL is checked, never repaired. A batch subdirectory is created exclusively with a private
    /// inherited DACL, so SQLite's temporary sidecars are private too. Cancellation/failure retains every created file.
    /// SQLite backup runs on a pinned read transaction (including WAL), bounded to 256 MiB; its StorageWriteSnapshot and
    /// qualified park identity are compared before sealing. Re-reads detect changes observed during capture, including D1 changes
    /// without revision increments. These observations are not the physical CAS under the future publication lock: absent files
    /// can appear, or sources change after the last check. The future caller must persist its intention then lock/recheck/publish.
    /// </summary>
    internal Task<SharedParkVerifiedBackups> CreateSharedParkBackupsAsync(SharedParkBatch expected, string backupDirectory,
        ImmutableArray<string> configFiles, ImmutableArray<string> protectedDirectories, CancellationToken cancellationToken,
        Action? beforeFinalRead = null) => Task.Run(async () =>
    {
        ArgumentNullException.ThrowIfNull(expected);
        cancellationToken.ThrowIfCancellationRequested();
        ValidateSharedParkBackupBatch(expected);
        using var directory = SharedParkBackupFiles.Open(backupDirectory, Path, expected.Path, configFiles, protectedDirectories, cancellationToken);
        var protections = protectedDirectories.Add(directory.Root);
        // The existing qualified reader owns TSV path validation, presence, strict decoding and the 16 MiB limit.
        var remote = await SharedParkRemoteReader.ReadAsync(expected.Path, Path, configFiles, protections, clock.GetUtcNow(), cancellationToken).ConfigureAwait(false);
        MatchSharedParkBackupRemote(expected, remote);
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        var absent = LocalBaseAbsent(cancellationToken);
        if (absent != !expected.LocalExists) { throw new InvalidDataException("Présence SQLite modifiée depuis l’aperçu."); }
        using var sourcePin = absent ? null : directory.PinSqliteSource(Path, cancellationToken);
        using var source = absent ? null : new SqliteDatabase(Path, true, cancellationToken: cancellationToken);
        long version = 0;
        string? logical = null;
        long sqliteBytes = 0;
        if (source is not null)
        {
            source.Begin(false);
            version = (long)source.Scalar("PRAGMA data_version;")!;
            MatchSharedParkBackupLocal(expected, ReadSharedParkBackupLocal(source, cancellationToken));
            sqliteBytes = SharedParkBackupSize(source);
            logical = StorageWriteSnapshot.Read(source, cancellationToken);
        }
        else { MatchSharedParkBackupLocal(expected, AbsentSharedParkLocal()); }

        // Reserve room for the standalone copy AND a possible rollback/WAL image, plus bounded journal headers/sidecars.
        directory.CreateBatch(expected.Id, checked(2 * sqliteBytes + remote.Bytes.LongLength + 65536), cancellationToken);
        SharedParkBackupReference? sqliteReference = null;
        SharedParkBackupReference? tsvReference = null;
        if (source is not null)
        {
            using (var output = directory.CreateFile("initial.db"))
            {
                // Read/write sharing is needed only while the native SQLite connection writes this exclusively created inode.
                // The held file denies delete; the private held directory prevents renaming its ancestors.
                using (var copy = new SqliteDatabase(directory.FilePath("initial.db"), false, cancellationToken: cancellationToken))
                {
                    source.BackupTo(copy);
                    copy.Script("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;");
                    if (copy.Scalar("PRAGMA quick_check;") as string != "ok") { throw new InvalidDataException("Copie SQLite corrompue ; preuve conservée."); }
                    MatchSharedParkBackupLocal(expected, ReadSharedParkBackupLocal(copy, cancellationToken));
                    if (SharedParkBackupSize(copy) != sqliteBytes || StorageWriteSnapshot.Read(copy, cancellationToken) != logical)
                    { throw new InvalidDataException("Copie SQLite différente de la transaction source ; preuve conservée."); }
                }
                directory.Seal(output);
            }
            sqliteReference = directory.Measure("initial.db", SharedParkBackupFiles.MaxSqliteBytes, cancellationToken);
            using (var sealedCopy = new SqliteDatabase(sqliteReference.Path, true, cancellationToken: cancellationToken))
            {
                sealedCopy.Begin(false);
                if (sealedCopy.Scalar("PRAGMA quick_check;") as string != "ok") { throw new InvalidDataException("Copie SQLite scellée corrompue."); }
                MatchSharedParkBackupLocal(expected, ReadSharedParkBackupLocal(sealedCopy, cancellationToken));
                if (SharedParkBackupSize(sealedCopy) != sqliteBytes || StorageWriteSnapshot.Read(sealedCopy, cancellationToken) != logical)
                { throw new InvalidDataException("Copie SQLite scellée différente de la transaction source."); }
                sealedCopy.Commit();
            }
            source.Commit();
        }
        if (remote.Exists)
        {
            using (var output = directory.CreateFile("initial.tsv"))
            {
                for (var offset = 0; offset < remote.Bytes.Length; offset += 65536)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    output.Write(remote.Bytes.AsSpan(offset, Math.Min(65536, remote.Bytes.Length - offset)));
                }
                directory.Seal(output);
            }
            tsvReference = directory.Measure("initial.tsv", SharedParkFile.MaxBytes, cancellationToken);
            if (tsvReference.Length != remote.Bytes.LongLength || tsvReference.Sha256 != remote.Sha256)
            { throw new InvalidDataException("Copie TSV différente des octets observés ; preuve conservée."); }
        }

        // Optional internal fault/interleaving seam. It conveys no validation and cannot bypass any final check.
        beforeFinalRead?.Invoke();
        cancellationToken.ThrowIfCancellationRequested();
        ValidateSharedParkBackupBatch(expected);
        if (LocalBaseAbsent(cancellationToken) != absent) { throw new InvalidDataException("Présence SQLite modifiée pendant la sauvegarde."); }
        if (source is not null)
        {
            source.Begin(false);
            if ((long)source.Scalar("PRAGMA data_version;")! != version) { throw new InvalidDataException("SQLite modifié pendant la sauvegarde."); }
            MatchSharedParkBackupLocal(expected, ReadSharedParkBackupLocal(source, cancellationToken));
            if (StorageWriteSnapshot.Read(source, cancellationToken) != logical) { throw new InvalidDataException("Contenu SQLite modifié pendant la sauvegarde."); }
            source.Commit();
        }
        MatchSharedParkBackupRemote(expected, await SharedParkRemoteReader.ReadAsync(expected.Path, Path, configFiles,
            protections, clock.GetUtcNow(), cancellationToken).ConfigureAwait(false));
        if (sqliteReference is not null) { directory.Verify(sqliteReference, SharedParkBackupFiles.MaxSqliteBytes, cancellationToken); }
        if (tsvReference is not null) { directory.Verify(tsvReference, SharedParkFile.MaxBytes, cancellationToken); }
        directory.VerifyProtection();
        cancellationToken.ThrowIfCancellationRequested();
        return new SharedParkVerifiedBackups(sqliteReference, tsvReference, logical);
    }, cancellationToken);

    private SharedParkLocalRead ReadSharedParkBackupLocal(SqliteDatabase source, CancellationToken token)
    {
        CheckIdentity(source, allowLegacy: true);
        var (revision, legacy) = ReadSharedParkRevision(source);
        return QualifySharedParkLocal(ReadRelationSweeps(source, token), revision, legacy, token);
    }

    private void ValidateSharedParkBackupBatch(SharedParkBatch batch)
    {
        var now = clock.GetUtcNow();
        if (!WritePlans.IsPlanId(batch.Id) || !WritePlans.IsPlanId(batch.SessionId) || batch.StoreId != StoreId || batch.DomainDn != DomainDn
            || batch.Epoch < 0 || batch.Revision < 0 || batch.Generation < 0 || batch.CreatedAt.Offset != TimeSpan.Zero
            || batch.ExpiresAt.Offset != TimeSpan.Zero || batch.CreatedAt <= DateTimeOffset.UnixEpoch || batch.CreatedAt > now
            || batch.ExpiresAt <= now || batch.ExpiresAt - batch.CreatedAt > TimeSpan.FromMinutes(15))
        { throw new InvalidDataException("Lot de sauvegarde étranger, invalide ou expiré."); }
    }

    private static void MatchSharedParkBackupLocal(SharedParkBatch expected, SharedParkLocalRead actual)
    {
        if (actual.Exists != expected.LocalExists || actual.Legacy != expected.Legacy || actual.StoreId != expected.StoreId
            || actual.DomainDn != expected.DomainDn || actual.Revision != expected.Revision || actual.Generation != expected.Generation
            || actual.RowsFingerprint != expected.RowsFingerprint || actual.Fingerprint != expected.LocalFingerprint)
        { throw new InvalidDataException("Identité ou empreinte SQLite différente de l’aperçu ; aucune sauvegarde certifiée."); }
    }

    private static void MatchSharedParkBackupRemote(SharedParkBatch expected, SharedParkRemoteRead actual)
    {
        if (actual.Path != expected.Path || actual.Exists != expected.RemoteExists || actual.Sha256 != expected.RemoteSha256)
        { throw new InvalidDataException("Présence, chemin ou SHA du TSV modifié depuis l’aperçu."); }
    }

    private static long SharedParkBackupSize(SqliteDatabase db)
    {
        var pages = (long)db.Scalar("PRAGMA page_count;")!;
        var size = (long)db.Scalar("PRAGMA page_size;")!;
        if (pages <= 0 || size is < 512 or > 65536 || pages > SharedParkBackupFiles.MaxSqliteBytes / size)
        { throw new InvalidDataException("Sauvegarde SQLite supérieure à 256 Mio ou géométrie illisible."); }
        return pages * size;
    }
}

/// <summary>Private create-only disk evidence. No automatic removal, overwrite, ACL repair or rotation. The file DACL is sealed
/// read-only after writing; the owner/administrator can still deliberately change it, so hashes are always re-read by consumers.</summary>
internal sealed class SharedParkBackupFiles : IDisposable
{
    internal const long MaxSqliteBytes = 256L * 1024 * 1024;
    internal const long MaxRetainedBytes = 1024L * 1024 * 1024;
    internal const int MaxBatches = 32;
    private const FileSystemRights ReadRights = FileSystemRights.Read | FileSystemRights.Synchronize;
    private readonly List<SafeFileHandle> pins = [];
    private readonly Dictionary<string, (uint Volume, uint High, uint Low)> identities = new(StringComparer.OrdinalIgnoreCase);
    private readonly SecurityIdentifier[] principals;
    private string? batchDirectory;
    private FileStream? admission;
    internal string Root { get; }

    private SharedParkBackupFiles(string root)
    {
        Root = root;
        using var identity = WindowsIdentity.GetCurrent();
        principals = new[] { identity.User ?? throw new IOException("Identité Windows absente."),
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) }
            .DistinctBy(s => s.Value).ToArray();
    }

    internal static SharedParkBackupFiles Open(string root, string database, string tsv, ImmutableArray<string> configs,
        ImmutableArray<string> forbiddenDirectories, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        // Reuse the strict lexical qualifier through an ordinary non-db probe. This performs no I/O to the TSV.
        if (string.IsNullOrEmpty(root) || root.Length > 960 || root.EndsWith('\\') || root.EndsWith('/')) { throw new InvalidDataException("Dossier privé canonique borné attendu."); }
        var probe = System.IO.Path.Combine(root, "backup-probe.tsv");
        SharedParkRemoteReader.Validate(probe, database, configs, forbiddenDirectories, token);
        CompatibleDirectoryCache.ValidateLocalPath(probe);
        var canonical = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(probe))!;
        if (canonical != root || canonical.Split('\\').Any(s => s.Equals("dev", StringComparison.OrdinalIgnoreCase)))
        { throw new InvalidDataException("Destination non canonique ou dans dev ; aucune création."); }
        foreach (var source in configs.Add(database).Add(tsv))
        {
            if (source.Equals(canonical, StringComparison.OrdinalIgnoreCase) || source.StartsWith(canonical + "\\", StringComparison.OrdinalIgnoreCase))
            { throw new InvalidDataException("La destination contient une source ou une configuration protégée."); }
        }
        var result = new SharedParkBackupFiles(canonical);
        try
        {
            var ancestors = new Stack<string>();
            for (var current = canonical; current is not null; current = System.IO.Path.GetDirectoryName(current)) { ancestors.Push(current); }
            foreach (var directory in ancestors) { token.ThrowIfCancellationRequested(); result.Pin(directory); }
            result.CheckAcl(new DirectoryInfo(canonical).GetAccessControl(), FileSystemRights.FullControl, directory: true);
            return result;
        }
        catch { result.Dispose(); throw; }
    }

    internal void CreateBatch(string id, long bytes, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (batchDirectory is not null || !WritePlans.IsPlanId(id)) { throw new InvalidDataException("Réservation de sauvegarde invalide."); }
        // The private admission file is owned exclusively from quota scan through final verification. Existing locks are never
        // adopted, deleted or waited out. DeleteOnClose releases only the file created by this handle, never an evidence file.
        var admissionPath = System.IO.Path.Combine(Root, ".capture.lock");
        admission = FileSystemAclExtensions.Create(new FileInfo(admissionPath), FileMode.CreateNew, FileSystemRights.FullControl,
            FileShare.None, 128, FileOptions.DeleteOnClose | FileOptions.WriteThrough, FileSecurity(FileSystemRights.FullControl));
        CheckAcl(admission.GetAccessControl(), FileSystemRights.FullControl, directory: false);
        long retained = 0;
        var entries = Directory.EnumerateFileSystemEntries(Root).Take(MaxBatches + 2)
            .Where(p => !p.Equals(admissionPath, StringComparison.OrdinalIgnoreCase)).ToArray();
        if (entries.Length >= MaxBatches) { throw new IOException("Quota de 32 lots de sauvegarde atteint ; preuves conservées."); }
        foreach (var dir in entries)
        {
            token.ThrowIfCancellationRequested();
            var directoryAttributes = File.GetAttributes(dir);
            if ((directoryAttributes & FileAttributes.ReparsePoint) != 0 || (directoryAttributes & FileAttributes.Directory) == 0)
            { throw new InvalidDataException("Entrée de sauvegarde non ordinaire ou redirigée."); }
            var files = Directory.EnumerateFileSystemEntries(dir).Take(9).ToArray();
            if (files.Length > 8) { throw new InvalidDataException("Lot de sauvegarde hors limites."); }
            foreach (var file in files)
            {
                var attributes = File.GetAttributes(file);
                if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) { throw new InvalidDataException("Preuve non ordinaire."); }
                retained = checked(retained + new FileInfo(file).Length);
            }
        }
        if (retained > MaxRetainedBytes - bytes) { throw new IOException("Quota de 1 Gio de preuves atteint ; rien n’est supprimé."); }
        if (new DriveInfo(System.IO.Path.GetPathRoot(Root)!).AvailableFreeSpace < 512L * 1024 * 1024 + bytes)
        { throw new IOException("Moins de 512 Mio de marge disque pour la sauvegarde."); }
        var target = System.IO.Path.Combine(Root, id);
        var security = DirectorySecurity();
        var descriptor = security.GetSecurityDescriptorBinaryForm();
        var pinned = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
        try
        {
            var attributes = new Native.SecurityAttributes { Length = Marshal.SizeOf<Native.SecurityAttributes>(), Descriptor = pinned.AddrOfPinnedObject() };
            if (!Native.CreateDirectory(target, ref attributes)) { throw new IOException("Dossier de lot déjà présent ou impossible à créer exclusivement.", new Win32Exception(Marshal.GetLastWin32Error())); }
        }
        finally { pinned.Free(); }
        batchDirectory = target;
        Pin(target);
        CheckAcl(new DirectoryInfo(target).GetAccessControl(), FileSystemRights.FullControl, directory: true);
        token.ThrowIfCancellationRequested();
    }

    internal FileStream CreateFile(string name)
    {
        var file = FileSystemAclExtensions.Create(new FileInfo(FilePath(name)), FileMode.CreateNew,
            FileSystemRights.Read | FileSystemRights.Write | FileSystemRights.ChangePermissions | FileSystemRights.Synchronize,
            FileShare.ReadWrite, 65536, FileOptions.WriteThrough, FileSecurity(FileSystemRights.FullControl));
        try { CheckAcl(file.GetAccessControl(), FileSystemRights.FullControl, directory: false); return file; }
        catch { file.Dispose(); throw; }
    }

    internal FileStream PinSqliteSource(string path, CancellationToken token)
    {
        var ancestors = new Stack<string>();
        for (var current = System.IO.Path.GetDirectoryName(path); current is not null; current = System.IO.Path.GetDirectoryName(current)) { ancestors.Push(current); }
        foreach (var directory in ancestors) { token.ThrowIfCancellationRequested(); Pin(directory); }
        foreach (var suffix in new[] { "-wal", "-shm", "-journal" }) { CompatibleDirectoryCache.ValidateLocalPath(path + suffix); }
        var handle = Native.CreateFile(path, 0x80000000, 3, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid) { handle.Dispose(); throw new IOException("Source SQLite inaccessible.", new Win32Exception(Marshal.GetLastWin32Error())); }
        try
        {
            if (!Native.GetFileInformationByHandle(handle, out var information)
                || (information.Attributes & (uint)(FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            { throw new InvalidDataException("Source SQLite non ordinaire ou redirigée."); }
            var stream = new FileStream(handle, FileAccess.Read);
            if (stream.Length > MaxSqliteBytes) { stream.Dispose(); throw new InvalidDataException("Source SQLite supérieure à 256 Mio."); }
            return stream;
        }
        catch { handle.Dispose(); throw; }
    }

    internal void Seal(FileStream file)
    {
        file.Flush(flushToDisk: true);
        file.SetAccessControl(FileSecurity(ReadRights));
        CheckAcl(file.GetAccessControl(), ReadRights, directory: false);
    }

    internal SharedParkBackupReference Measure(string name, long max, CancellationToken token)
    {
        var path = FilePath(name);
        using var handle = Native.CreateFile(path, 0x80000000, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid) { throw new IOException("Copie inaccessible ou encore ouverte en écriture.", new Win32Exception(Marshal.GetLastWin32Error())); }
        if (!Native.GetFileInformationByHandle(handle, out var information)
            || (information.Attributes & (uint)(FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || information.Links != 1)
        { throw new InvalidDataException("Copie de sauvegarde redirigée, liée ou non ordinaire."); }
        var identity = (information.Volume, information.IndexHigh, information.IndexLow);
        if (identities.TryGetValue(path, out var previous) && previous != identity) { throw new InvalidDataException("Identité physique de la copie remplacée."); }
        identities[path] = identity;
        using var file = new FileStream(handle, FileAccess.Read);
        CheckAcl(file.GetAccessControl(), ReadRights, directory: false);
        var length = file.Length;
        if (length > max) { throw new InvalidDataException("Copie de sauvegarde hors limites."); }
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[65536];
        long read = 0;
        while (true)
        {
            token.ThrowIfCancellationRequested();
            var count = file.Read(buffer);
            if (count == 0) { break; }
            read = checked(read + count);
            if (read > max || read > length) { throw new InvalidDataException("Copie modifiée pendant sa relecture."); }
            hash.AppendData(buffer, 0, count);
        }
        if (read != length || file.Length != length) { throw new InvalidDataException("Longueur de copie différente à la relecture."); }
        token.ThrowIfCancellationRequested();
        return new(path, length, Convert.ToHexStringLower(hash.GetHashAndReset()));
    }

    internal void Verify(SharedParkBackupReference reference, long max, CancellationToken token)
    {
        if (Measure(System.IO.Path.GetFileName(reference.Path), max, token) != reference)
        { throw new InvalidDataException("Copie de sauvegarde altérée après création."); }
    }

    internal void VerifyProtection()
    {
        CheckAcl(new DirectoryInfo(Root).GetAccessControl(), FileSystemRights.FullControl, directory: true);
        if (batchDirectory is null) { throw new InvalidDataException("Dossier de lot absent."); }
        CheckAcl(new DirectoryInfo(batchDirectory).GetAccessControl(), FileSystemRights.FullControl, directory: true);
        if (admission is null) { throw new InvalidDataException("Admission privée absente."); }
        CheckAcl(admission.GetAccessControl(), FileSystemRights.FullControl, directory: false);
    }

    internal string FilePath(string name)
    {
        if (batchDirectory is null || name is not ("initial.db" or "initial.tsv")) { throw new InvalidDataException("Nom de preuve non qualifié."); }
        return System.IO.Path.Combine(batchDirectory, name);
    }

    private DirectorySecurity DirectorySecurity()
    {
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var principal in principals) { security.AddAccessRule(new FileSystemAccessRule(principal, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow)); }
        return security;
    }

    private FileSecurity FileSecurity(FileSystemRights rights)
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var principal in principals) { security.AddAccessRule(new FileSystemAccessRule(principal, rights, AccessControlType.Allow)); }
        return security;
    }

    private void CheckAcl(FileSystemSecurity security, FileSystemRights rights, bool directory)
    {
        var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        var inheritance = directory ? InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit : InheritanceFlags.None;
        if (!security.AreAccessRulesProtected || rules.Length != principals.Length
            || rules.Any(r => r.IsInherited || r.AccessControlType != AccessControlType.Allow || r.FileSystemRights != rights
                || r.InheritanceFlags != inheritance || r.PropagationFlags != PropagationFlags.None)
            || !principals.Select(s => s.Value).ToHashSet(StringComparer.Ordinal).SetEquals(rules.Select(r => r.IdentityReference.Value)))
        { throw new InvalidDataException("DACL privée de sauvegarde non conforme ; aucune réparation implicite."); }
    }

    private void Pin(string directory)
    {
        var handle = Native.CreateFile(directory, 0x80, 1, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid) { handle.Dispose(); throw new IOException("Parent de sauvegarde inaccessible ou occupé.", new Win32Exception(Marshal.GetLastWin32Error())); }
        pins.Add(handle);
        if (!Native.GetFileInformationByHandle(handle, out var information)) { throw new IOException("Identité de répertoire illisible.", new Win32Exception(Marshal.GetLastWin32Error())); }
        if ((information.Attributes & (uint)FileAttributes.Directory) == 0 || (information.Attributes & (uint)FileAttributes.ReparsePoint) != 0)
        { throw new InvalidDataException("Parent de sauvegarde non ordinaire ou redirigé."); }
    }

    public void Dispose()
    {
        admission?.Dispose(); admission = null;
        for (var i = pins.Count - 1; i >= 0; i--) { pins[i].Dispose(); }
        pins.Clear();
    }

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)] internal struct SecurityAttributes { internal int Length; internal IntPtr Descriptor; internal int Inherit; }
        [StructLayout(LayoutKind.Sequential)] internal struct FileInformation
        {
            internal uint Attributes;
            internal System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("kernel32.dll", EntryPoint = "CreateDirectoryW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CreateDirectory(string path, ref SecurityAttributes attributes);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation information);
    }
}
