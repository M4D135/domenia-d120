using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    internal sealed record SwitchSource(string Path, string StoreId, long Revision, long Bytes, string Fingerprint, LocalStoreBackup? Backup);

    internal Task<SwitchSource> InspectSwitchSourceAsync(string path, bool requireStandalone, CancellationToken token) => Task.Run(() =>
        InspectSwitchSource(path, requireStandalone, token), token);

    private SwitchSource InspectSwitchSource(string path, bool requireStandalone, CancellationToken token)
    {
        CompatibleDirectoryCache.ValidateLocalPath(path);
        if (!File.Exists(path) || !path.EndsWith(".db", StringComparison.OrdinalIgnoreCase)) { throw new InvalidDataException("Source SQLite locale absente ou non .db."); }
        if (requireStandalone && File.Exists(path + "-wal") && new FileInfo(path + "-wal").Length > 0)
        { throw new InvalidDataException("La source utilise encore un journal WAL ; choisissez une sauvegarde autonome vérifiée."); }
        using var db = new SqliteDatabase(path, true, cancellationToken: token); db.Begin(false);
        var identity = db.Scalar("SELECT store_id FROM domenia_store_state WHERE id=1;") as string;
        if (identity is not { Length: 64 } || identity.Any(c => !char.IsAsciiHexDigit(c))) { throw new InvalidDataException("Identité de la source absente ou invalide."); }
        CheckIdentity(db, false, identity);
        EnsureSwitchTasksClosed(db);
        if (db.Scalar("PRAGMA quick_check;") as string != "ok") { throw new InvalidDataException("Contrôle SQLite de la source en échec."); }
        var revision = (long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") ?? throw new InvalidDataException("Révision de la source absente.");
        if (revision < 0 || revision == long.MaxValue) { throw new InvalidDataException("Révision de la source hors limites."); }
        db.Commit();
        return new(path, identity, revision, new FileInfo(path).Length, SwitchFileFingerprint(path), null);
    }

    internal Task<SwitchSource> InspectRegisteredSwitchSourceAsync(string id, CancellationToken token) => Task.Run(() =>
    {
        if (!WritePlans.IsPlanId(id)) { throw new InvalidDataException("Identifiant de sauvegarde invalide."); }
        var proof = ReadStorageBackupProof(id) ?? throw new InvalidDataException("Sauvegarde absente du registre de cette base.");
        if (proof.Retired) { throw new InvalidDataException("Sauvegarde retirée de la rotation ; choisissez explicitement son fichier conservé."); }
        ValidateBackupArtifact(proof, token);
        return InspectSwitchSource(System.IO.Path.Combine(BackupFolder, proof.Backup.FileName), true, token) with { Backup = proof.Backup };
    }, token);

    internal Task<SwitchSource> InspectExternalSwitchSourceAsync(string path, CancellationToken token) => Task.Run(() =>
    {
        var source = InspectSwitchSource(path, true, token);
        var hash = BackupFileHash(path);
        var annexPath = System.IO.Path.ChangeExtension(path, ".preferences.json");
        var annex = File.Exists(annexPath) ? ReadBackupJson<BackupPreferences>(annexPath) : null;
        var at = clock.GetUtcNow();
        var backup = new LocalStoreBackup(WritePlans.NewId(), System.IO.Path.GetFileName(path), new DateTimeOffset(File.GetLastWriteTimeUtc(path)),
            source.Bytes, hash, true, at, "external", source.Revision, new(null, null, null, null, null, null), null, annex);
        if (annex is not null && !BackupPreferencesRules.IsBound(backup)) { throw new InvalidDataException("Annexe de préférences étrangère ou altérée."); }
        return source with { Backup = backup };
    }, token);

    internal static string SwitchFileFingerprint(string path)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var suffix in new[] { "", "-wal", "-journal" })
        {
            hash.AppendData(Encoding.UTF8.GetBytes("file" + suffix + "\n"));
            var current = path + suffix; CompatibleDirectoryCache.ValidateLocalPath(current);
            if (!File.Exists(current)) { hash.AppendData([0]); continue; }
            using var file = new FileStream(current, FileMode.Open, FileAccess.Read, FileShare.Read);
            hash.AppendData([1]); hash.AppendData(BitConverter.GetBytes(file.Length));
            var buffer = new byte[65_536]; int count;
            while ((count = file.Read(buffer)) > 0) { hash.AppendData(buffer.AsSpan(0, count)); }
        }
        return Convert.ToHexStringLower(hash.GetHashAndReset());
    }

    private static void EnsureSwitchTasksClosed(SqliteDatabase db)
    {
        if (Table(db, RemoteReads) && (long?)db.Scalar("SELECT count(*) FROM " + RemoteReads + " WHERE pending<>0;") > 0)
        { throw new InvalidDataException("Une lecture distante exige encore son nettoyage ; terminez-la avant toute bascule ou restauration de cette copie."); }
    }

    /// <summary>The caller holds OS deny-write handles on the source and active files until the pointer is durably published.</summary>
    internal SwitchSource CopyForSwitch(SwitchSource original, string stagingPath, CancellationToken token, Action<SwitchSource> ready)
    {
        if (File.Exists(stagingPath) || File.Exists(Path)) { throw new IOException("Destination déjà présente ; aucun fichier remplacé."); }
        CompatibleDirectoryCache.ValidateLocalPath(stagingPath); CompatibleDirectoryCache.ValidateLocalPath(Path);
        using (new FileStream(stagingPath, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
        using (var source = new SqliteDatabase(original.Path, true, cancellationToken: token))
        using (var copy = new SqliteDatabase(stagingPath, false, cancellationToken: token))
        {
            source.Begin(false); CheckIdentity(source, false, original.StoreId); EnsureSwitchTasksClosed(source);
            if ((long?)source.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") != original.Revision
                || SwitchFileFingerprint(original.Path) != original.Fingerprint)
            { throw new InvalidDataException("Source modifiée depuis la confirmation ; copie non publiée."); }
            source.BackupTo(copy); source.Commit();
            copy.Script("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;"); copy.Begin();
            CheckIdentity(copy, false, original.StoreId); EnsureSwitchTasksClosed(copy);
            if (Table(copy, "domenia_v2_metadata") && copy.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") is string json)
            {
                var fleet = JsonSerializer.Deserialize<CachedFleet>(json, Json) ?? throw new InvalidDataException("Relevés de la copie illisibles.");
                if (fleet.Facts.StoreId != original.StoreId) { throw new InvalidDataException("Relevés d’une autre base dans la copie."); }
                copy.Execute("UPDATE domenia_v2_metadata SET payload=?1 WHERE key='fleet';", JsonSerializer.Serialize(fleet with { Facts = fleet.Facts with { StoreId = StoreId } }, Json));
            }
            RelocateOperations(copy, original.StoreId);
            copy.Execute("CREATE TABLE IF NOT EXISTS domenia_v2_store_lineage(previous_store_id TEXT PRIMARY KEY NOT NULL,domain_dn TEXT NOT NULL);");
            copy.Execute("INSERT OR IGNORE INTO domenia_v2_store_lineage(previous_store_id,domain_dn) VALUES(?1,?2);", original.StoreId, DomainDn);
            copy.Execute("UPDATE domenia_store_state SET store_id=?1,revision=revision+1 WHERE id=1;", StoreId);
            CheckIdentity(copy, false);
            if (copy.Scalar("PRAGMA quick_check;") as string != "ok" || (long?)copy.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") != original.Revision + 1)
            { throw new InvalidDataException("Copie non conforme après réattribution du magasin."); }
            copy.Commit();
        }
        var staged = InspectSwitchSource(stagingPath, true, token) with { Path = Path };
        ready(staged);
        token.ThrowIfCancellationRequested(); File.Move(stagingPath, Path, overwrite: false);
        return InspectSwitchSource(Path, true, token);
    }

    private bool HistoricalStore(SqliteDatabase db, string storeId) => Table(db, "domenia_v2_store_lineage")
        && db.Scalar("SELECT domain_dn FROM domenia_v2_store_lineage WHERE previous_store_id=?1;", storeId) is string domain
        && DistinguishedName.AreEqual(domain, DomainDn);
}
