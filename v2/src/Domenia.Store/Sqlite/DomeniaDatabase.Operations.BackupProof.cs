using System.Security.Cryptography;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private readonly Lock collectionBackupGate = new();
    private CollectionStorageLease? collectionStorageLease;

    public bool HasOperationsLease { get { lock (collectionBackupGate) { return collectionStorageLease is not null; } } }

    private IDisposable RetainCollectionLock(FileStream collectionLock)
    {
        lock (collectionBackupGate)
        {
            if (collectionStorageLease is not null) { collectionLock.Dispose(); throw new IOException("Une collecte locale détient déjà la preuve de sauvegarde."); }
            return collectionStorageLease = new CollectionStorageLease(this, collectionLock);
        }
    }

    /// <summary>
    /// A verified handle is retained only for the admitted collection. FileShare.Read prevents a
    /// Windows writer, rename or deletion from changing its bytes while checkpoints reuse its hash.
    /// A timestamp/size cache alone would not supply that guarantee.
    /// </summary>
    private bool VerifyOrRetainBackup(DatabaseBackup backup)
    {
        lock (collectionBackupGate)
        {
            if (collectionStorageLease is not { } lease)
            {
                using var read = File.OpenRead(backup.Path);
                return Convert.ToHexStringLower(SHA256.HashData(read)) == backup.Sha256;
            }
            if (lease.Backup == backup && lease.Proof is not null) { return true; }
            FileStream? proof = null;
            try
            {
                proof = new FileStream(backup.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, FileOptions.SequentialScan);
                if (proof.Length != backup.Bytes || Convert.ToHexStringLower(SHA256.HashData(proof)) != backup.Sha256) { return false; }
                lease.Proof?.Dispose(); lease.Proof = proof; lease.Backup = backup; proof = null;
                return true;
            }
            finally { proof?.Dispose(); }
        }
    }

    private sealed class CollectionStorageLease(DomeniaDatabase owner, FileStream collectionLock) : IDisposable
    {
        internal DatabaseBackup? Backup;
        internal FileStream? Proof;
        private bool disposed;
        public void Dispose()
        {
            lock (owner.collectionBackupGate)
            {
                if (disposed) { return; }
                disposed = true;
                if (ReferenceEquals(owner.collectionStorageLease, this)) { owner.collectionStorageLease = null; }
                Proof?.Dispose(); Proof = null; Backup = null;
                collectionLock.Dispose();
            }
        }
    }
}
