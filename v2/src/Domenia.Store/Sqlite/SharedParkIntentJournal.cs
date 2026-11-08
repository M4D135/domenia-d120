using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// Durable, private, immutable local journal of shared-park intentions: one sealed document per plan, written once under a dedicated
/// local directory behind a private DACL, then re-readable across instances and after the batch has expired. It reuses
/// <see cref="SharedParkIntentDocument"/> verbatim for the format — it never rewrites the codec nor invents another JSON — and binds
/// every operation to the expected store, domain, plan id and plan fingerprint. It is an intention journal, never a receipt: it proves
/// no copy was ever made, certifies no completed backup nor any publication success, and grants no right to replay a plan. The declared
/// SQLite/TSV backup paths inside an intention are never opened, touched or attested here; the future caller must have verified them
/// before <see cref="CreateAsync"/> and may only advance after a success and a re-read.
/// </summary>
internal sealed class SharedParkIntentJournal
{
    /// <summary>Hard ceiling on the complete document, delegated to the codec; measured before any allocation on read.</summary>
    internal const int MaxDocumentBytes = SharedParkIntentDocument.MaxDocumentBytes;

    /// <summary>Hard ceiling on the intentions retained under the root; enforced atomically under the admission lock.</summary>
    internal const int MaxIntentions = 128;

    private const string Extension = ".sharedparkintent";
    private const string LockFileName = "journal.lock";
    private const int MaxPathLength = 1024;
    private const int MaxIdentityLength = 512;
    private const int MaxDomainLength = 1024;
    private static readonly TimeSpan LockWait = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan LockRetry = TimeSpan.FromMilliseconds(20);
    private static readonly char[] InvalidComponentChars = ['<', '>', '"', '|', '?', '*', ':'];
    private static readonly string[] ReservedDeviceNames = ["CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        "COM\u00B9", "COM\u00B2", "COM\u00B3", "LPT\u00B9", "LPT\u00B2", "LPT\u00B3"];

    private readonly string root;
    private readonly string expectedStoreId;
    private readonly string expectedDomainDn;
    private readonly TimeProvider clock;

    /// <summary>
    /// Binds the dedicated local root and the expected identities, qualifying them lexically only: the constructor creates and reads no
    /// directory, opens no file and touches no ACL. The root must be an absolute, canonical local path (no UNC, device namespace,
    /// alternate data stream, drive root or control character); the physical qualification of the root and its ancestors happens on the
    /// operation, never here.
    /// </summary>
    internal SharedParkIntentJournal(string root, string expectedStoreId, string expectedDomainDn, TimeProvider clock)
    {
        this.root = QualifiedRoot(root);
        this.expectedStoreId = QualifiedIdentity(expectedStoreId, MaxIdentityLength, nameof(expectedStoreId));
        this.expectedDomainDn = QualifiedIdentity(expectedDomainDn, MaxDomainLength, nameof(expectedDomainDn));
        this.clock = clock ?? throw new ArgumentNullException(nameof(clock));
    }

    /// <summary>The qualified dedicated local root, exposed read-only so the caller can point at the journal without deriving paths itself.</summary>
    internal string Root => root;

    /// <summary>Seals one intention for a plan and persists it durably, off the UI thread, exactly once for that plan id.</summary>
    internal Task CreateAsync(SharedParkIntent intent, CancellationToken token) => Task.Run(() => Create(intent, token), token);

    /// <summary>Re-reads the intention of a plan, off the UI thread, with the exact expected identities; a still-well-formed intention
    /// whose batch has since expired stays readable (proof after a restart), never a right to replay it.</summary>
    internal Task<SharedParkIntent?> ReadAsync(string planId, string planFingerprint, CancellationToken token)
        => Task.Run(() => Read(planId, planFingerprint, token), token);

    /// <summary>Seals <paramref name="intent"/> with the expected context and the injected clock, then writes it once. A pre-cancelled
    /// token and an invalid intention are refused before any I/O; a plan already journalled is refused without touching its bytes; the
    /// document is flushed and re-read from the same handle before the operation acknowledges.</summary>
    internal SharedParkIntent Create(SharedParkIntent intent, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(intent);
        var document = SharedParkIntentDocument.Encode(intent, expectedStoreId, expectedDomainDn, intent.PlanId, intent.PlanFingerprint, clock.GetUtcNow(), token);
        var path = IntentPath(intent.PlanId);
        EnsureRootPrivate(token);
        using (var admission = AcquireLock(token))
        {
            RequirePrivateRoot(token);
            CountIntentions(token);
            if (QualifyFile(path, token))
            { throw new InvalidDataException("Une intention existe déjà pour ce plan ; son contenu n’est ni relu ni écrasé, relisez-la plutôt."); }
            RequirePrivateRoot(token);
            // Waiting for another writer must not admit a batch which has expired meanwhile. Reuse the codec's complete validation.
            document = SharedParkIntentDocument.Encode(intent, expectedStoreId, expectedDomainDn, intent.PlanId, intent.PlanFingerprint, clock.GetUtcNow(), token);
            token.ThrowIfCancellationRequested();
            using var held = FileSystemAclExtensions.Create(new FileInfo(path), FileMode.CreateNew,
                FileSystemRights.Read | FileSystemRights.Write | FileSystemRights.Synchronize, FileShare.None, 4096,
                FileOptions.WriteThrough, PrivateFileSecurity());
            RequirePrivateRoot(token);
            RequireFile(path, token);
            VerifyPrivateFileAcl(held);
            token.ThrowIfCancellationRequested();
            held.Write(document);
            token.ThrowIfCancellationRequested();
            held.Flush(flushToDisk: true);
            token.ThrowIfCancellationRequested();
            held.Position = 0;
            var reread = new byte[document.Length];
            held.ReadExactly(reread);
            token.ThrowIfCancellationRequested();
            if (held.ReadByte() != -1) { throw new InvalidDataException("Intention de parc partagé agrandie après son écriture ; rien n’est acquitté."); }
            if (!reread.AsSpan().SequenceEqual(document)) { throw new InvalidDataException("Relecture de l’intention différente des octets écrits ; rien n’est acquitté."); }
            SharedParkIntentDocument.Decode(reread, expectedStoreId, expectedDomainDn, intent.PlanId, intent.PlanFingerprint, clock.GetUtcNow(), token);
            RequirePrivateRoot(token);
            RequireFile(path, token);
            VerifyPrivateFileAcl(held);
            token.ThrowIfCancellationRequested();
        }
        token.ThrowIfCancellationRequested();
        return intent;
    }

    /// <summary>Re-reads the intention of one plan. A genuinely qualified absence (no root, or no file for that plan) returns null and
    /// creates nothing; an access error, a reparse point, a corruption or a partial document is never an absence but an exception.</summary>
    internal SharedParkIntent? Read(string planId, string planFingerprint, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var path = IntentPath(planId);
        if (planFingerprint is not { Length: 64 } || !planFingerprint.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f')))
        { throw new InvalidDataException("L’empreinte attendue du plan doit être 64 chiffres hexadécimaux en minuscules avant toute lecture."); }
        if (!EnsureRootPhysical(token))
        {
            if (EnsureRootPhysical(token)) { throw new IOException("Le répertoire du journal est apparu pendant la qualification de son absence ; relisez explicitement."); }
            token.ThrowIfCancellationRequested();
            return null;
        }
        RequirePrivateRoot(token);
        if (!QualifyFile(path, token)) { return QualifiedAbsence(path, token); }
        FileStream file;
        try
        {
            token.ThrowIfCancellationRequested();
            file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        }
        catch (FileNotFoundException)
        {
            return QualifiedAbsence(path, token);
        }
        SharedParkIntent intent;
        using (file)
        {
            RequirePrivateRoot(token);
            RequireFile(path, token);
            VerifyPrivateFileAcl(file);
            token.ThrowIfCancellationRequested();
            var length = file.Length;
            if (length > MaxDocumentBytes) { throw new InvalidDataException("Intention de parc partagé au-delà de 64 Kio avant toute lecture."); }
            var buffer = new byte[checked((int)length)];
            file.ReadExactly(buffer);
            token.ThrowIfCancellationRequested();
            if (file.ReadByte() != -1) { throw new InvalidDataException("Intention de parc partagé agrandie pendant sa lecture."); }
            intent = SharedParkIntentDocument.Decode(buffer, expectedStoreId, expectedDomainDn, planId, planFingerprint, clock.GetUtcNow(), token);
            RequirePrivateRoot(token);
            RequireFile(path, token);
            VerifyPrivateFileAcl(file);
            token.ThrowIfCancellationRequested();
        }
        token.ThrowIfCancellationRequested();
        return intent;
    }

    private SharedParkIntent? QualifiedAbsence(string path, CancellationToken token)
    {
        RequirePrivateRoot(token);
        if (QualifyFile(path, token)) { throw new IOException("L’intention est apparue pendant la qualification de son absence ; relisez explicitement."); }
        token.ThrowIfCancellationRequested();
        return null;
    }

    /// <summary>Deterministic file name from the validated plan id only, under the dedicated root.</summary>
    private string IntentPath(string planId)
    {
        if (!WritePlans.IsPlanId(planId)) { throw new InvalidDataException("Identifiant de plan hors des règles WritePlans ; aucun chemin n’est dérivé d’un identifiant libre."); }
        return Path.Combine(root, planId + Extension);
    }

    /// <summary>Qualifies the root and its existing ancestors physically (no reparse point anywhere on the way, the root itself must be a
    /// real directory when present). Returns whether the root exists; never creates anything.</summary>
    private bool EnsureRootPhysical(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var current = Path.GetPathRoot(root)!;
        if (new DriveInfo(current).DriveType == DriveType.Network)
        { throw new InvalidDataException("Le journal d’intentions doit rester sur un disque local, jamais un lecteur réseau."); }
        // Start at the drive, so a missing descendant cannot hide an inaccessible, non-directory or redirected ancestor.
        token.ThrowIfCancellationRequested();
        RequireDirectoryAttributes(File.GetAttributes(current));
        foreach (var component in root[3..].Split('\\'))
        {
            current = Path.Combine(current, component);
            token.ThrowIfCancellationRequested();
            FileAttributes attributes;
            try { attributes = File.GetAttributes(current); }
            catch (FileNotFoundException) { token.ThrowIfCancellationRequested(); return false; }
            catch (DirectoryNotFoundException) { token.ThrowIfCancellationRequested(); return false; }
            RequireDirectoryAttributes(attributes);
        }
        token.ThrowIfCancellationRequested();
        return true;
    }

    private static void RequireDirectoryAttributes(FileAttributes attributes)
    {
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        { throw new InvalidDataException("Répertoire ou ancêtre du journal d’intentions redirigé refusé."); }
        if ((attributes & FileAttributes.Directory) == 0)
        { throw new InvalidDataException("Le répertoire du journal d’intentions et chacun de ses ancêtres doivent être de vrais dossiers."); }
    }

    /// <summary>Creates the dedicated root when absent and gives it a private DACL (current user, SYSTEM, Administrators, nothing
    /// inherited), then reads that protection back. An incompatible protection is refused rather than claimed private; no external
    /// parent ACL is ever modified.</summary>
    private void EnsureRootPrivate(CancellationToken token)
    {
        if (!EnsureRootPhysical(token))
        {
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            foreach (var principal in PrivatePrincipals())
            { security.AddAccessRule(new FileSystemAccessRule(principal, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow)); }
            token.ThrowIfCancellationRequested();
            // The security descriptor is part of directory creation. If another creator wins, this API leaves its ACL unchanged;
            // the requalification below must still prove it private. Existing external parents are never reprotected.
            FileSystemAclExtensions.Create(new DirectoryInfo(root), security);
        }
        RequirePrivateRoot(token);
    }

    private void RequirePrivateRoot(CancellationToken token)
    {
        if (!EnsureRootPhysical(token)) { throw new DirectoryNotFoundException("Le répertoire du journal d’intentions a disparu ; aucune absence d’intention n’est déduite."); }
        token.ThrowIfCancellationRequested();
        var read = new DirectoryInfo(root).GetAccessControl(AccessControlSections.Access) ?? throw new IOException("DACL du répertoire du journal illisible.");
        VerifyPrivateAcl(read, PrivatePrincipals(), InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit);
        token.ThrowIfCancellationRequested();
    }

    /// <summary>Only a missing terminal entry under separately qualified parents is an absence. No Exists helper hides access errors.</summary>
    private static bool QualifyFile(string path, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        FileAttributes attributes;
        try { attributes = File.GetAttributes(path); }
        catch (FileNotFoundException) { token.ThrowIfCancellationRequested(); return false; }
        if ((attributes & FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("Fichier du journal d’intentions redirigé refusé."); }
        if ((attributes & FileAttributes.Directory) != 0) { throw new InvalidDataException("Un dossier ne peut pas être une intention ni un verrou du journal."); }
        token.ThrowIfCancellationRequested();
        return true;
    }

    private static void RequireFile(string path, CancellationToken token)
    {
        if (!QualifyFile(path, token)) { throw new FileNotFoundException("Un fichier du journal a disparu pendant son utilisation ; rien n’est acquitté.", path); }
    }

    /// <summary>Exclusive, bounded, cancellable admission lock over counting/admission/creation. It is ephemeral (deleted on close of its
    /// own handle) and never touches an intention file; a lock held elsewhere is waited for briefly, never stolen nor cleaned by name.</summary>
    private FileStream AcquireLock(CancellationToken token)
    {
        var lockPath = Path.Combine(root, LockFileName);
        var deadline = Stopwatch.GetTimestamp() + (long)(LockWait.TotalSeconds * Stopwatch.Frequency);
        while (true)
        {
            RequirePrivateRoot(token);
            if (QualifyFile(lockPath, token))
            {
                WaitForLock(deadline, token);
                continue;
            }
            token.ThrowIfCancellationRequested();
            FileStream held;
            try
            {
                held = FileSystemAclExtensions.Create(new FileInfo(lockPath), FileMode.CreateNew,
                    FileSystemRights.Read | FileSystemRights.Write | FileSystemRights.Delete | FileSystemRights.Synchronize,
                    FileShare.None, 4096, FileOptions.DeleteOnClose, PrivateFileSecurity());
            }
            catch (IOException ex) when (IsCreationCollision(ex))
            {
                // Another creator may win between the absent-name check and CreateNew. Only name or sharing collisions wait;
                // access denied (also used for pending deletion) and unrelated I/O failures propagate unchanged.
                WaitForLock(deadline, token, ex);
                continue;
            }
            try
            {
                RequirePrivateRoot(token);
                RequireFile(lockPath, token);
                VerifyPrivateFileAcl(held);
                token.ThrowIfCancellationRequested();
                return held;
            }
            catch { held.Dispose(); throw; }
        }
    }

    private static bool IsCreationCollision(IOException exception) => (exception.HResult & 0xFFFF) is 32 or 80 or 183;

    private static void WaitForLock(long deadline, CancellationToken token, IOException? collision = null)
    {
        token.ThrowIfCancellationRequested();
        if (Stopwatch.GetTimestamp() >= deadline)
        { throw new IOException("Verrou d’admission du journal d’intentions indisponible ; aucune intention n’est créée.", collision); }
        token.WaitHandle.WaitOne(LockRetry);
        token.ThrowIfCancellationRequested();
        if (Stopwatch.GetTimestamp() >= deadline)
        { throw new IOException("Verrou d’admission du journal d’intentions indisponible ; aucune intention n’est créée.", collision); }
    }

    /// <summary>Bounded enumeration of the intentions under the root: at most <see cref="MaxIntentions"/> are admitted, an unexpected
    /// entry or a saturated directory is refused, nothing is ever cleaned automatically.</summary>
    private void CountIntentions(CancellationToken token)
    {
        var intentions = 0;
        var scanned = 0;
        foreach (var entry in Directory.EnumerateFileSystemEntries(root))
        {
            token.ThrowIfCancellationRequested();
            if (++scanned > MaxIntentions + 1) { throw new IOException("Répertoire du journal d’intentions saturé ; rien n’est nettoyé ni ajouté."); }
            RequireFile(entry, token);
            var name = Path.GetFileName(entry);
            if (name.EndsWith(Extension, StringComparison.Ordinal) && WritePlans.IsPlanId(name[..^Extension.Length]))
            {
                if (++intentions >= MaxIntentions) { throw new InvalidDataException("Au plus " + MaxIntentions + " intentions de parc partagé retenues ; aucune admission supplémentaire."); }
            }
            else if (!name.Equals(LockFileName, StringComparison.Ordinal))
            {
                throw new InvalidDataException("Entrée inattendue dans le répertoire du journal d’intentions ; rien n’est nettoyé automatiquement.");
            }
        }
        token.ThrowIfCancellationRequested();
    }

    private static SecurityIdentifier[] PrivatePrincipals()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return [identity.User ?? throw new IOException("Identité Windows absente ; le journal d’intentions ne peut pas être rendu privé."),
            new(WellKnownSidType.LocalSystemSid, null), new(WellKnownSidType.BuiltinAdministratorsSid, null)];
    }

    private static FileSecurity PrivateFileSecurity()
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var principal in PrivatePrincipals()) { security.AddAccessRule(new FileSystemAccessRule(principal, FileSystemRights.FullControl, AccessControlType.Allow)); }
        return security;
    }

    /// <summary>The DACL of the owned file is read back from the handle that owns it, never through the name of a replaceable object.</summary>
    private static void VerifyPrivateFileAcl(FileStream held)
    {
        var read = held.GetAccessControl() ?? throw new IOException("DACL de l’intention de parc partagé illisible depuis le handle tenu.");
        VerifyPrivateAcl(read, PrivatePrincipals(), InheritanceFlags.None);
    }

    private static void VerifyPrivateAcl(FileSystemSecurity security, SecurityIdentifier[] principals, InheritanceFlags inheritance)
    {
        var allowed = principals.Select(p => p.Value).Distinct(StringComparer.Ordinal).ToHashSet(StringComparer.Ordinal);
        var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        if (!security.AreAccessRulesProtected || rules.Length != allowed.Count
            || rules.Any(r => r.IsInherited || r.AccessControlType != AccessControlType.Allow || r.FileSystemRights != FileSystemRights.FullControl
                || r.InheritanceFlags != inheritance || r.PropagationFlags != PropagationFlags.None || !allowed.Contains(r.IdentityReference.Value))
            || !allowed.SetEquals(rules.Select(r => r.IdentityReference.Value)))
        { throw new IOException("DACL privé du journal d’intentions non confirmé à la relecture ; rien n’est acquitté."); }
    }

    private static string QualifiedRoot(string root)
    {
        if (root is null || root.Length is 0 or > MaxPathLength || root.Any(char.IsControl) || root.Contains('/'))
        { throw new InvalidDataException("Répertoire du journal d’intentions local absolu attendu (1 024 caractères au plus, sans caractère de contrôle ni barre oblique) ; rien n’est complété en silence."); }
        if (!(root.Length >= 4 && char.IsAsciiLetter(root[0]) && root[1] == ':' && root[2] == '\\'))
        { throw new InvalidDataException("Répertoire du journal d’intentions local absolu sur lecteur attendu (partage, périphérique, racine seule ou chemin relatif refusés)."); }
        if (root.AsSpan(3).Contains(':')) { throw new InvalidDataException("Répertoire du journal d’intentions avec périphérique ou flux alternatif refusé."); }
        foreach (var segment in root[3..].Split('\\'))
        {
            if (segment.Length == 0 || segment is "." or ".." || segment.EndsWith('.') || segment.EndsWith(' ')
                || segment.IndexOfAny(InvalidComponentChars) >= 0)
            { throw new InvalidDataException("Répertoire du journal d’intentions non canonique : composant vide, ambigu ou contenant un caractère Windows interdit."); }
            var dot = segment.IndexOf('.');
            if (ReservedDeviceNames.Contains(dot < 0 ? segment : segment[..dot], StringComparer.OrdinalIgnoreCase))
            { throw new InvalidDataException("Répertoire du journal d’intentions portant un nom de périphérique DOS réservé."); }
        }
        var full = Path.GetFullPath(root);
        if (!string.Equals(full, root, StringComparison.OrdinalIgnoreCase))
        { throw new InvalidDataException("Répertoire du journal d’intentions non canonique ; rien n’est normalisé en silence."); }
        return full;
    }

    private static string QualifiedIdentity(string value, int max, string name)
    {
        if (string.IsNullOrEmpty(value) || value.Length > max || value.Any(char.IsControl)) { throw new InvalidDataException($"Identité attendue « {name} » absente, non bornée ou contenant un caractère de contrôle."); }
        return value;
    }
}
