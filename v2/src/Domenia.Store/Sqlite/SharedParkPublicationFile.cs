using System.Collections.Immutable;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using Domenia.Core;
using Microsoft.Win32.SafeHandles;

namespace Domenia.Store;

/// <summary>
/// One explicitly confirmed publication while the caller holds the D1 lock. Windows/SMB supplies atomic replacement, not an
/// identity-conditional rename: an uncooperative replacement can still race the final check. The file actually displaced is
/// retained in the exclusively created private evidence directory and compared after replacement, before any local commit.
/// A mismatch or an error after Attempted is uncertainty, never a right to compensate or replay. Dispose closes handles only.
/// </summary>
internal sealed class SharedParkPublicationFile : IDisposable
{
    internal const int MaxSlots = 32;
    private readonly string target;
    private readonly string stage;
    private readonly string evidence;
    private readonly string previous;
    private readonly bool existed;
    private readonly string expectedSha;
    private readonly string proposedSha;
    private readonly string parentDacl;
    private readonly string? initialDacl;
    private readonly byte[]? initialSecurityDescriptor;
    private readonly bool initialDaclProtected;
    private readonly string? initialOwner;
    private string? stagedOwner;
    private readonly PathPins pins;
    private BoundFile? initial;
    private BoundFile? staged;
    private BoundFile? published;
    private BoundFile? displaced;
    internal bool Attempted { get; private set; }

    internal static void ValidatePaths(string target, string planId, string database, ImmutableArray<string> configs,
        ImmutableArray<string> protectedDirectories, CancellationToken token)
    {
        if (!WritePlans.IsPlanId(planId)) { throw new InvalidDataException("Identifiant de publication invalide."); }
        var prefix = target + ".domenia-" + planId;
        // Every path this publication will itself create is qualified with the reader's own rules: the sibling temporary brother, the
        // private evidence directory and the displaced file it will hold. A name refused here never reaches an API call.
        foreach (var path in new[] { target, prefix + ".tmp", prefix + ".evidence", prefix + ".evidence\\previous.tsv" })
        { SharedParkRemoteReader.Validate(path, database, configs, protectedDirectories, token); }
        if (System.IO.Path.GetFileName(target).Length > 170) { throw new InvalidDataException("Nom du TSV trop long pour ses preuves de publication."); }
    }

    internal SharedParkPublicationFile(string path, string planId, bool expectedExists, string expectedSha, byte[] bytes,
        CancellationToken token)
    {
        target = path; stage = path + ".domenia-" + planId + ".tmp";
        evidence = path + ".domenia-" + planId + ".evidence";
        previous = System.IO.Path.Combine(evidence, "previous.tsv");
        existed = expectedExists; this.expectedSha = expectedSha; proposedSha = SharedParkFile.Hash(bytes);
        if (bytes.Length > SharedParkFile.MaxBytes) { throw new InvalidDataException("Publication supérieure à 16 Mio."); }
        pins = new PathPins(System.IO.Path.GetDirectoryName(target)!, token);
        try
        {
            var parent = System.IO.Path.GetDirectoryName(target)!;
            parentDacl = Dacl(new DirectoryInfo(parent).GetAccessControl());
            var prefix = System.IO.Path.GetFileName(target) + ".domenia-";
            var entries = Directory.EnumerateFileSystemEntries(parent, prefix + "*").Take(2 * MaxSlots + 1).ToArray();
            var slots = new HashSet<string>(StringComparer.Ordinal);
            foreach (var entry in entries)
            {
                token.ThrowIfCancellationRequested();
                var name = System.IO.Path.GetFileName(entry)[prefix.Length..];
                var suffix = name.Length >= 32 ? name[32..] : "";
                if (name.Length < 32 || !WritePlans.IsPlanId(name[..32]) || suffix is not (".tmp" or ".evidence")
                    || (File.GetAttributes(entry) & FileAttributes.ReparsePoint) != 0)
                { throw new InvalidDataException("Preuve de publication étrangère ou redirigée ; aucun nettoyage implicite."); }
                slots.Add(name[..32]);
            }
            if (entries.Length > 2 * MaxSlots || slots.Count >= MaxSlots)
            { throw new IOException("Quota de 32 publications conservées atteint ; preuves laissées en place."); }
            initial = expectedExists ? BoundFile.Open(target, SharedParkFile.MaxBytes, token, allowDelete: true) : null;
            var initialSecurity = initial?.Stream.GetAccessControl();
            initialDacl = initialSecurity is null ? null : Dacl(initialSecurity);
            initialSecurityDescriptor = initialSecurity?.GetSecurityDescriptorBinaryForm();
            initialDaclProtected = initialSecurity?.AreAccessRulesProtected ?? false;
            initialOwner = initialSecurity is null ? null : Owner(initialSecurity);
            CheckBefore(token);
            CreatePrivateDirectory(evidence);
            pins.Add(evidence);
            RequirePrivate(new DirectoryInfo(evidence).GetAccessControl(), FileSystemRights.FullControl, directory: true);
            // Prepared bytes are private at creation, never briefly exposed through the share's inherited permissions. Existing
            // target permissions are preserved by ReplaceFile; an absent target receives inheritance only after its move below.
            using (var output = FileSystemAclExtensions.Create(new FileInfo(stage), FileMode.CreateNew, FileSystemRights.FullControl,
                FileShare.None, 65536, FileOptions.WriteThrough, PrivateFileSecurity()))
            {
                RequirePrivate(output.GetAccessControl(), FileSystemRights.FullControl, directory: false);
                for (var offset = 0; offset < bytes.Length; offset += 65536)
                { token.ThrowIfCancellationRequested(); output.Write(bytes.AsSpan(offset, Math.Min(65536, bytes.Length - offset))); }
                output.Flush(flushToDisk: true);
                RequirePrivate(output.GetAccessControl(), FileSystemRights.FullControl, directory: false);
            }
            staged = BoundFile.Open(stage, SharedParkFile.MaxBytes, token, allowDelete: true);
            var stagedSecurity = staged.Stream.GetAccessControl();
            RequirePrivate(stagedSecurity, FileSystemRights.FullControl, directory: false);
            stagedOwner = Owner(stagedSecurity);
            if (staged.Sha256 != proposedSha || staged.Length != bytes.Length) { throw new InvalidDataException("Fichier temporaire différent du contenu confirmé."); }
        }
        catch { Dispose(); throw; }
    }

    internal void CheckBefore(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (existed)
        {
            using var current = BoundFile.Open(target, SharedParkFile.MaxBytes, token, allowDelete: true);
            if (initial is null || current.Identity != initial.Identity || current.Sha256 != expectedSha || initial.Rehash(token) != expectedSha)
            { throw new InvalidDataException("CAS physique du TSV refusé avant publication."); }
            var currentSecurity = current.Stream.GetAccessControl(); var heldSecurity = initial.Stream.GetAccessControl();
            if (Dacl(currentSecurity) != initialDacl || Dacl(heldSecurity) != initialDacl
                || Owner(currentSecurity) != initialOwner || Owner(heldSecurity) != initialOwner)
            { throw new InvalidDataException("Droits du TSV modifiés avant publication."); }
        }
        else if (Present(target)) { throw new InvalidDataException("TSV apparu avant publication ; absence attendue."); }
        if (Dacl(new DirectoryInfo(System.IO.Path.GetDirectoryName(target)!).GetAccessControl()) != parentDacl)
        { throw new InvalidDataException("Droits du parent modifiés avant publication."); }
    }

    internal void Publish(CancellationToken token, Action? immediatelyBeforeReplace = null, Action? immediatelyAfterRename = null)
    {
        CheckBefore(token);
        RequirePrivate(new DirectoryInfo(evidence).GetAccessControl(), FileSystemRights.FullControl, directory: true);
        if (Present(previous)) { throw new InvalidDataException("Preuve déplacée déjà présente ; aucun écrasement."); }
        using (var checkStage = BoundFile.Open(stage, SharedParkFile.MaxBytes, token, allowDelete: true))
        {
            if (staged is null || checkStage.Identity != staged.Identity || checkStage.Sha256 != proposedSha)
            { throw new InvalidDataException("Fichier temporaire remplacé avant publication."); }
            var checkedSecurity = checkStage.Stream.GetAccessControl();
            RequirePrivate(checkedSecurity, FileSystemRights.FullControl, directory: false);
            if (Owner(checkedSecurity) != stagedOwner) { throw new InvalidDataException("Propriétaire du temporaire modifié avant publication."); }
        }
        token.ThrowIfCancellationRequested();
        // Deliberate interleaving seam: tests demonstrate that the cooperative D1 lock is not a universal physical CAS.
        immediatelyBeforeReplace?.Invoke();
        token.ThrowIfCancellationRequested();
        // ReplaceFile opens its replacement with write/delete access; relinquish the read lease only after recording its inode.
        // The inode and SHA must match again at the published path before SQLite can commit.
        staged?.Dispose();
        Attempted = true;
        try
        {
            if (existed) { File.Replace(stage, target, previous, ignoreMetadataErrors: false); }
            else { File.Move(stage, target, overwrite: false); }
            immediatelyAfterRename?.Invoke();
            // The old TSV keeps its own DACL when moved. Protect the newly retained artifact through an identity-bound handle,
            // including a raced/unexpected displaced file, before considering cancellation or accepting its content. The rename
            // and ACL change are not atomic: a crash or inaccessible share in between remains an unconfirmed protection.
            ProtectDisplaced();
            token.ThrowIfCancellationRequested();
            if (existed && (initial is null || displaced is null || displaced.Identity != initial.Identity || displaced.Sha256 != expectedSha
                || Owner(displaced.Stream.GetAccessControl()) != initialOwner))
            { throw new InvalidDataException("Le fichier effectivement déplacé diffère de l’état confirmé ; état incertain."); }
            published = BoundFile.Open(target, SharedParkFile.MaxBytes, token, allowDelete: false, changeSecurity: !existed);
            if (staged is null || published.Identity != staged.Identity || published.Sha256 != proposedSha)
            { throw new InvalidDataException("Publication non relue à l’identique ; état incertain."); }
            if (existed) { ConfirmPublishedPermissions(token); }
            else { InheritPublishedPermissions(); }
            RequirePrivate(new DirectoryInfo(evidence).GetAccessControl(), FileSystemRights.FullControl, directory: true);
        }
        catch
        {
            // ReplaceFile can fail after moving the old file or after merging its DACL into the still-named temporary. Retain both
            // artifacts and protect only our identified inode/owned evidence path. A protection failure propagates as uncertainty;
            // neither the target's contents nor its pre-existing DACL is rolled back or repaired.
            try { ProtectDisplaced(); }
            finally { ProtectRemainingStage(); }
            throw;
        }
    }

    private void ProtectDisplaced()
    {
        if (!existed || displaced is not null || !Present(previous)) { return; }
        // No token before the small ACL operation: cancellation must not knowingly leave a newly retained proof permissive.
        // Hash/length remain bounded; a larger raced file is protected before being refused, never truncated.
        displaced = BoundFile.Open(previous, SharedParkFile.MaxBytes, CancellationToken.None, allowDelete: false,
            changeSecurity: true, protectOnOpen: true);
    }

    private void ProtectRemainingStage()
    {
        if (!Present(stage)) { return; }
        using var retained = BoundFile.Open(stage, SharedParkFile.MaxBytes, CancellationToken.None, allowDelete: false, changeSecurity: true);
        if (staged is null || retained.Identity != staged.Identity) { throw new InvalidDataException("Temporaire remplacé après tentative ; sa protection reste inconnue."); }
        retained.Stream.SetAccessControl(PrivateFileSecurity());
        RequirePrivate(retained.Stream.GetAccessControl(), FileSystemRights.FullControl, directory: false);
    }

    private void InheritPublishedPermissions()
    {
        if (published is null || Dacl(new DirectoryInfo(System.IO.Path.GetDirectoryName(target)!).GetAccessControl()) != parentDacl)
        { throw new InvalidDataException("Droits du parent modifiés après publication ; nouveau fichier laissé privé."); }
        var permissions = published.Stream.GetAccessControl();
        RequirePrivate(permissions, FileSystemRights.FullControl, directory: false);
        if (Owner(permissions) != stagedOwner) { throw new InvalidDataException("Propriétaire du nouveau fichier modifié ; état incertain."); }
        foreach (var rule in permissions.GetAccessRules(includeExplicit: true, includeInherited: false, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>())
        { permissions.RemoveAccessRuleSpecific(rule); }
        // An allocated empty DACL, never a NULL DACL: Windows propagates the parent's inheritable ACEs when protection is removed.
        // Nothing is granted to another principal here, and no directory ACE is naively copied onto a file.
        permissions.SetAccessRuleProtection(isProtected: false, preserveInheritance: false);
        published.Stream.SetAccessControl(permissions);
        var actual = published.Stream.GetAccessControl();
        var rules = actual.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        if (actual.AreAccessRulesProtected || rules.Length == 0 || rules.Any(rule => !rule.IsInherited) || Owner(actual) != stagedOwner
            || Dacl(new DirectoryInfo(System.IO.Path.GetDirectoryName(target)!).GetAccessControl()) != parentDacl)
        { throw new InvalidDataException("Héritage effectif du nouveau TSV non confirmé ; état incertain."); }
    }

    private void ConfirmPublishedPermissions(CancellationToken token)
    {
        if (published is null || initialDacl is null || initialSecurityDescriptor is null
            || Dacl(new DirectoryInfo(System.IO.Path.GetDirectoryName(target)!).GetAccessControl()) != parentDacl)
        { throw new InvalidDataException("Droits du parent modifiés après remplacement ; état incertain."); }
        var permissions = published.Stream.GetAccessControl();
        if (Owner(permissions) != stagedOwner)
        { throw new InvalidDataException("Propriétaire du fichier publié modifié ; état incertain."); }
        var observedDacl = Dacl(permissions);
        var expectedDescriptor = new RawSecurityDescriptor(initialSecurityDescriptor, 0);
        var observedDescriptor = new RawSecurityDescriptor(permissions.GetSecurityDescriptorBinaryForm(), 0);
        if (observedDacl == initialDacl && SharedParkPublicationDacl.IsExact(expectedDescriptor, observedDescriptor)) { return; }
        // Only two observed conversions may be finalized: the replacement's protection bit alone, or the strictly matched
        // legacy inherited-ACE duplication below. Neither converted DACL is accepted as the final policy. The handle is
        // bound to our published inode, the displaced inode/SHA matched, and the parent policy must remain identical.
        // This is not an atomic security CAS: a noncooperating WRITE_DAC holder can still race the check and the update,
        // just as it can race ReplaceFile's ACL merge. Any observable ACE/owner/parent difference remains Unknown.
        var legacyConversion = SharedParkPublicationDacl.IsLegacyInheritedDuplication(expectedDescriptor, observedDescriptor);
        if (!legacyConversion)
        {
            if (initialDaclProtected || !permissions.AreAccessRulesProtected)
            { throw PermissionMismatch("Droits de la cible existante non conservés ; état incertain.", observedDacl); }
            permissions.SetAccessRuleProtection(isProtected: false, preserveInheritance: false);
            if (Dacl(permissions) != initialDacl
                || !SharedParkPublicationDacl.IsExact(expectedDescriptor, new RawSecurityDescriptor(permissions.GetSecurityDescriptorBinaryForm(), 0)))
            { throw PermissionMismatch("Droits de la cible existante modifiés au-delà de la protection ; état incertain.", observedDacl); }
        }
        // An already matching DACL needs no WRITE_DAC. Acquire that extra right only for this exact transition while the
        // original read handle still refuses writes/renames, then qualify the second handle and the observed policy again.
        using var securityAccess = BoundFile.Open(target, SharedParkFile.MaxBytes, token, allowDelete: false, changeSecurity: true);
        var observed = securityAccess.Stream.GetAccessControl();
        if (securityAccess.Identity != published.Identity || securityAccess.Sha256 != proposedSha || securityAccess.Length != published.Length
            || Owner(observed) != stagedOwner || Dacl(observed) != observedDacl
            || !SharedParkPublicationDacl.IsExact(observedDescriptor, new RawSecurityDescriptor(observed.GetSecurityDescriptorBinaryForm(), 0))
            || Dacl(new DirectoryInfo(System.IO.Path.GetDirectoryName(target)!).GetAccessControl()) != parentDacl)
        { throw new InvalidDataException("Fichier ou droits modifiés avant remise d’héritage ; état incertain."); }
        token.ThrowIfCancellationRequested();
        if (legacyConversion)
        {
            // Windows fixtures observe this precise legacy-to-auto-inherited duplication after ReplaceFile. SetSecurityInfo
            // applies the current inheritance model; use the documented legacy FILE API only for this exact conversion.
            // The name and all ancestors are
            // pinned by open read handles without FILE_SHARE_DELETE; the extra handle above proves WRITE_DAC admission.
            // DACL_SECURITY_INFORMATION alone excludes owner/group/SACL changes. No claim is made until the full reread.
            if (!Native.SetFileSecurity(target, 4, initialSecurityDescriptor))
            { throw new IOException("Descripteur hérité initial non rétabli ; état incertain.", new Win32Exception(Marshal.GetLastWin32Error())); }
        }
        else { securityAccess.Stream.SetAccessControl(permissions); }
        var actual = published.Stream.GetAccessControl();
        if (Dacl(actual) != initialDacl || Owner(actual) != stagedOwner
            || !SharedParkPublicationDacl.IsExact(expectedDescriptor, new RawSecurityDescriptor(actual.GetSecurityDescriptorBinaryForm(), 0))
            || Dacl(new DirectoryInfo(System.IO.Path.GetDirectoryName(target)!).GetAccessControl()) != parentDacl)
        { throw PermissionMismatch("Héritage de la cible existante non relu à l’identique ; état incertain.", Dacl(actual)); }
    }

    private InvalidDataException PermissionMismatch(string detail, string observedDacl)
    {
        // Only the internal fixture observer receives these descriptors. Public outcomes retain their bounded wording.
        var error = new InvalidDataException(detail);
        error.Data["SharedPark.InitialDacl"] = initialDacl;
        error.Data["SharedPark.PublishedDacl"] = observedDacl;
        return error;
    }

    private static string Dacl(FileSystemSecurity security) => security.GetSecurityDescriptorSddlForm(AccessControlSections.Access);
    private static string Owner(FileSystemSecurity security) => security.GetOwner(typeof(SecurityIdentifier))?.Value
        ?? throw new InvalidDataException("Propriétaire du fichier absent.");

    private static FileSecurity PrivateFileSecurity()
    {
        using var user = WindowsIdentity.GetCurrent();
        var security = new FileSecurity(); security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { user.User ?? throw new IOException("Identité Windows absente."),
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) }.DistinctBy(s => s.Value))
        { security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow)); }
        return security;
    }

    public void Dispose() { displaced?.Dispose(); published?.Dispose(); staged?.Dispose(); initial?.Dispose(); pins.Dispose(); }

    internal static BoundFile VerifyBackup(SharedParkBackupReference reference, string expectedPath, long max, CancellationToken token)
    {
        if (reference.Path != expectedPath) { throw new InvalidDataException("Chemin de sauvegarde différent du lot attendu."); }
        CompatibleDirectoryCache.ValidateLocalPath(reference.Path);
        var result = BoundFile.Open(reference.Path, max, token, allowDelete: false);
        try
        {
            RequirePrivate(result.Stream.GetAccessControl(), FileSystemRights.Read | FileSystemRights.Synchronize, directory: false);
            if (result.Length != reference.Length || result.Sha256 != reference.Sha256) { throw new InvalidDataException("Sauvegarde physique absente ou altérée."); }
            return result;
        }
        catch { result.Dispose(); throw; }
    }

    private static bool Present(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) { throw new InvalidDataException("Cible de publication non ordinaire."); }
            return true;
        }
        catch (FileNotFoundException) { return false; }
    }

    internal static void RequirePrivate(FileSystemSecurity security, FileSystemRights rights, bool directory)
    {
        using var user = WindowsIdentity.GetCurrent();
        var expected = new[] { user.User?.Value ?? throw new IOException("Identité Windows absente."), "S-1-5-18", "S-1-5-32-544" }.ToHashSet(StringComparer.Ordinal);
        var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        var flags = directory ? InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit : InheritanceFlags.None;
        if (!security.AreAccessRulesProtected || rules.Length != expected.Count || !expected.SetEquals(rules.Select(r => r.IdentityReference.Value))
            || rules.Any(r => r.IsInherited || r.AccessControlType != AccessControlType.Allow || r.FileSystemRights != rights
                || r.InheritanceFlags != flags || r.PropagationFlags != PropagationFlags.None))
        { throw new InvalidDataException("Protection privée des preuves non conforme."); }
    }

    private static void CreatePrivateDirectory(string path)
    {
        var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
        using var user = WindowsIdentity.GetCurrent();
        foreach (var sid in new[] { user.User ?? throw new IOException("Identité Windows absente."),
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) }.DistinctBy(s => s.Value))
        { security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow)); }
        var bytes = security.GetSecurityDescriptorBinaryForm(); var held = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try
        {
            var attributes = new Native.SecurityAttributes { Length = Marshal.SizeOf<Native.SecurityAttributes>(), Descriptor = held.AddrOfPinnedObject() };
            if (!Native.CreateDirectory(path, ref attributes)) { throw new IOException("Dossier de preuve déjà présent ou non créé exclusivement.", new Win32Exception(Marshal.GetLastWin32Error())); }
        }
        finally { held.Free(); }
    }

    internal sealed class BoundFile : IDisposable
    {
        internal FileStream Stream { get; }
        internal (uint Volume, uint High, uint Low) Identity { get; }
        internal long Length { get; }
        internal string Sha256 { get; }

        private BoundFile(FileStream stream, Native.Information information, long max, CancellationToken token)
        {
            Stream = stream; Identity = (information.Volume, information.IndexHigh, information.IndexLow); Length = stream.Length;
            if (Length > max) { throw new InvalidDataException("Fichier de preuve hors limites."); }
            Sha256 = Rehash(token);
        }

        internal static BoundFile Open(string path, long max, CancellationToken token, bool allowDelete,
            bool changeSecurity = false, bool protectOnOpen = false)
        {
            token.ThrowIfCancellationRequested();
            var handle = Native.CreateFile(path, changeSecurity ? 0x80040000u : 0x80000000u, allowDelete ? 5u : 1u, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw new IOException("Fichier de preuve inaccessible.", new Win32Exception(Marshal.GetLastWin32Error())); }
            FileStream? stream = null;
            try
            {
                if (!Native.GetFileInformationByHandle(handle, out var information)
                    || (information.Attributes & (uint)(FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || information.Links != 1)
                { throw new InvalidDataException("Fichier redirigé, lié ou non ordinaire."); }
                stream = new FileStream(handle, FileAccess.Read);
                if (protectOnOpen)
                {
                    stream.SetAccessControl(PrivateFileSecurity());
                    RequirePrivate(stream.GetAccessControl(), FileSystemRights.FullControl, directory: false);
                }
                return new BoundFile(stream, information, max, token);
            }
            catch { stream?.Dispose(); handle.Dispose(); throw; }
        }

        internal string Rehash(CancellationToken token)
        {
            Stream.Position = 0; using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[65536]; long total = 0;
            while (true)
            {
                token.ThrowIfCancellationRequested(); var read = Stream.Read(buffer); if (read == 0) { break; }
                total += read; if (total > Length) { throw new InvalidDataException("Preuve agrandie pendant la lecture."); }
                hash.AppendData(buffer, 0, read);
            }
            if (total != Length || Stream.Length != Length) { throw new InvalidDataException("Longueur de preuve modifiée."); }
            token.ThrowIfCancellationRequested(); return Convert.ToHexStringLower(hash.GetHashAndReset());
        }
        public void Dispose() => Stream.Dispose();
    }

    internal sealed class PathPins : IDisposable
    {
        private readonly List<SafeFileHandle> handles = [];
        internal PathPins(string directory, CancellationToken token)
        {
            try
            {
                var root = System.IO.Path.GetPathRoot(directory)!.TrimEnd('\\'); var ancestors = new Stack<string>();
                for (var at = directory; ; at = System.IO.Path.GetDirectoryName(at)!)
                { ancestors.Push(at); if (at.TrimEnd('\\').Equals(root, StringComparison.OrdinalIgnoreCase)) { break; } }
                foreach (var at in ancestors) { token.ThrowIfCancellationRequested(); Add(at); }
            }
            catch { Dispose(); throw; }
        }
        internal void Add(string path)
        {
            // Attribute-only opens do not participate in Windows share-mode admission. Request directory read access so
            // omitting FILE_SHARE_DELETE actually prevents an ancestor rename; child creation remains permitted.
            var handle = Native.CreateFile(path, 0x81, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw new IOException("Parent de preuve inaccessible.", new Win32Exception(Marshal.GetLastWin32Error())); }
            handles.Add(handle);
            if (!Native.GetFileInformationByHandle(handle, out var information) || (information.Attributes & (uint)FileAttributes.Directory) == 0
                || (information.Attributes & (uint)FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("Parent de preuve non ordinaire."); }
        }
        public void Dispose() { for (var i = handles.Count - 1; i >= 0; i--) { handles[i].Dispose(); } handles.Clear(); }
    }

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)] internal struct SecurityAttributes { internal int Length; internal IntPtr Descriptor; internal int Inherit; }
        [StructLayout(LayoutKind.Sequential)] internal struct Information
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
        [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetFileInformationByHandle(SafeFileHandle file, out Information information);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("advapi32.dll", EntryPoint = "SetFileSecurityW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetFileSecurity(string path, uint information, [In] byte[] descriptor);
    }
}
