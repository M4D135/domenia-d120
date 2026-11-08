using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    internal sealed record SwitchSource(string Path, string StoreId, long Revision, long Bytes, string Fingerprint, LocalStoreBackup? Backup)
    {
        // A recovery original has a path-derived identity, never an asserted SQLite identity or revision.
        public bool PhysicalOnly { get; init; }
        public bool Legacy { get; init; }
    }

    internal async Task<SwitchSource> InspectSwitchOriginalAsync(string path, bool unreadable, CancellationToken token)
    {
        if (!unreadable) { return await InspectSwitchSourceAsync(path, false, token).ConfigureAwait(false); }
        if (!string.Equals(path, Path, StringComparison.OrdinalIgnoreCase))
        { throw new InvalidDataException("Original illisible d’un autre emplacement."); }
        var fingerprint = RecoveryFingerprint(path, token);
        var inspection = await InspectLocalStoreAsync(false, true, token).ConfigureAwait(false);
        if (!inspection.Available || !inspection.Maintenance.Recovery)
        { throw new InvalidDataException("Corruption de l’original non confirmée ; refaire le plan de restauration."); }
        if (RecoveryFingerprint(path, token) != fingerprint)
        { throw new InvalidDataException("Original illisible modifié pendant sa qualification."); }
        return new(path, StoreId, -1, new FileInfo(path).Length, fingerprint, null) { PhysicalOnly = true };
    }

    internal static string RecoveryFingerprint(string path, CancellationToken token)
    {
        // Recovery is deliberately bounded and hashes every SQLite sidecar that could carry original bytes.
        const long maximum = 256L * 1024 * 1024;
        long total = 0;
        foreach (var suffix in new[] { "", "-wal", "-shm", "-journal" })
        {
            token.ThrowIfCancellationRequested(); var file = path + suffix;
            CompatibleDirectoryCache.ValidateLocalPath(file);
            if (suffix.Length == 0 && !File.Exists(file)) { throw new FileNotFoundException("Original illisible absent ; aucun remplacement implicite.", file); }
            if (File.Exists(file)) { total = checked(total + new FileInfo(file).Length); }
            if (total > maximum) { throw new InvalidDataException("Original illisible et journaux au-delà de 256 Mio ; récupération manuelle requise."); }
        }
        return SwitchFileFingerprint(path, token, maximum);
    }

    internal Task<SwitchSource> InspectSwitchSourceAsync(string path, bool requireStandalone, CancellationToken token) => Task.Run(() =>
        InspectSwitchSource(path, requireStandalone, token), token);

    private SwitchSource InspectSwitchSource(string path, bool requireStandalone, CancellationToken token)
    {
        CompatibleDirectoryCache.ValidateLocalPath(path);
        if (!File.Exists(path) || !path.EndsWith(".db", StringComparison.OrdinalIgnoreCase)) { throw new InvalidDataException("Source SQLite locale absente ou non .db."); }
        if (requireStandalone && File.Exists(path + "-wal") && new FileInfo(path + "-wal").Length > 0)
        { throw new InvalidDataException("La source utilise encore un journal WAL ; choisissez une sauvegarde autonome vérifiée."); }
        using var db = OpenPath(path, true, cancellationToken: token); db.Begin(false);
        if ((long?)db.Scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name GLOB 'domenia_v2_*';") == 0)
        {
            if (!requireStandalone) throw new InvalidDataException("Une base D1 séparée doit être reprise par copie explicite.");
            var legacy = CheckLegacySwitchSource(db, token);
            db.Commit();
            var fingerprint = SwitchFileFingerprint(path, token);
            var identityProof = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("domenia-d1-source\n" + DomainDn.ToLowerInvariant() + "\n" + fingerprint)));
            return new(path, legacy.Identity ?? identityProof, legacy.Revision, new FileInfo(path).Length, fingerprint, null) { Legacy = true };
        }
        var identity = db.Scalar("SELECT store_id FROM domenia_store_state WHERE id=1;") as string;
        if (identity is not { Length: 64 } || identity.Any(c => !char.IsAsciiHexDigit(c))) { throw new InvalidDataException("Identité de la source absente ou invalide."); }
        CheckIdentity(db, false, identity);
        if ((long)db.Scalar("SELECT count(*) FROM ad_objects WHERE object_type IN ('Machine','Utilisateur');")! > SyncRowsLimit)
            throw new InvalidDataException("Plus de 300 000 comptes historiques ; reprise manuelle requise.");
        _ = IndexRows(db, null); // Mandatory GUID/state checks before any publication, preserving valid GUID-less archives.
        EnsureSwitchTasksClosed(db);
        if (db.Scalar("PRAGMA quick_check;") as string != "ok") { throw new InvalidDataException("Contrôle SQLite de la source en échec."); }
        var revision = (long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") ?? throw new InvalidDataException("Révision de la source absente.");
        if (revision < 0 || revision == long.MaxValue) { throw new InvalidDataException("Révision de la source hors limites."); }
        db.Commit();
        return new(path, identity, revision, new FileInfo(path).Length, SwitchFileFingerprint(path, token), null);
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
        var annex = ReadExternalBackupPreferences(path, hash, token);
        var at = clock.GetUtcNow();
        var backup = new LocalStoreBackup(WritePlans.NewId(), System.IO.Path.GetFileName(path), new DateTimeOffset(File.GetLastWriteTimeUtc(path)),
            source.Bytes, hash, true, at, "external", source.Revision, new(null, null, null, null, null, null), null, annex);
        if (annex is not null && !BackupPreferencesRules.IsBound(backup)) { throw new InvalidDataException("Annexe de préférences étrangère ou altérée."); }
        return source with { Backup = backup };
    }, token);

    private static BackupPreferences? ReadExternalBackupPreferences(string path, string databaseHash, CancellationToken token)
    {
        var canonical = System.IO.Path.ChangeExtension(path, ".preferences.json");
        var prefix = System.IO.Path.GetFileName(path) + ".preferences-";
        // Exported annexes retain their plan ID to avoid overwriting older proofs. Resolve the one bound to these bytes.
        var entries = Directory.EnumerateFileSystemEntries(System.IO.Path.GetDirectoryName(path)!).Take(4097).ToArray();
        if (entries.Length > 4096) { throw new InvalidDataException("Dossier de sauvegarde au-delà de 4096 entrées ; recherche d’annexe interrompue."); }
        var exported = entries.Where(p => System.IO.Path.GetFileName(p).StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            && p.EndsWith(".json", StringComparison.OrdinalIgnoreCase)).Take(33).ToArray();
        if (exported.Length > 32) { throw new InvalidDataException("Plus de 32 annexes de sauvegarde ; sélection manuelle requise."); }
        BackupPreferences? selected = null;
        foreach (var candidate in (File.Exists(canonical) ? new[] { canonical } : []).Concat(exported))
        {
            token.ThrowIfCancellationRequested(); CompatibleDirectoryCache.ValidateLocalPath(candidate);
            if (candidate != canonical && !WritePlans.IsPlanId(System.IO.Path.GetFileName(candidate)[prefix.Length..^5]))
            { throw new InvalidDataException("Nom d’annexe exportée invalide."); }
            using var file = new FileStream(candidate, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length > BackupPreferencesRules.MaxEnvelopeBytes) { throw new InvalidDataException("Métadonnées de sauvegarde trop volumineuses."); }
            var bytes = new byte[checked((int)file.Length)]; file.ReadExactly(bytes);
            var annex = JsonSerializer.Deserialize<BackupPreferences>(bytes, Json) ?? throw new InvalidDataException("Annexe de préférences illisible.");
            if (annex.DatabaseSha256 != databaseHash)
            {
                if (candidate == canonical) { throw new InvalidDataException("Annexe de préférences étrangère ou altérée."); }
                continue; // Historical export of different database bytes, retained intact.
            }
            if (selected is not null && selected != annex) { throw new InvalidDataException("Annexes contradictoires pour la même sauvegarde ; aucune préférence choisie arbitrairement."); }
            selected = annex;
        }
        return selected;
    }

    internal static string SwitchFileFingerprint(string path, CancellationToken token = default, long maximumBytes = long.MaxValue)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        long measured = 0;
        foreach (var suffix in new[] { "", "-wal", "-shm", "-journal" })
        {
            hash.AppendData(Encoding.UTF8.GetBytes("file" + suffix + "\n"));
            var current = path + suffix; CompatibleDirectoryCache.ValidateLocalPath(current);
            if (!File.Exists(current)) { hash.AppendData([0]); continue; }
            using var file = new FileStream(current, FileMode.Open, FileAccess.Read, FileShare.Read);
            hash.AppendData([1]); hash.AppendData(BitConverter.GetBytes(file.Length));
            var buffer = new byte[65_536]; int count;
            while ((count = file.Read(buffer)) > 0)
            {
                token.ThrowIfCancellationRequested();
                measured = checked(measured + count);
                if (measured > maximumBytes) { throw new InvalidDataException("Original illisible et journaux au-delà de 256 Mio ; récupération manuelle requise."); }
                hash.AppendData(buffer.AsSpan(0, count));
            }
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
        using (var source = OpenPath(original.Path, true, cancellationToken: token))
        using (var copy = OpenPath(stagingPath, false, cancellationToken: token))
        {
            source.Begin(false);
            if (original.Legacy) CheckLegacySwitchSource(source, token);
            else { CheckIdentity(source, false, original.StoreId); EnsureSwitchTasksClosed(source); }
            if ((!original.Legacy && (long?)source.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") != original.Revision)
                || SwitchFileFingerprint(original.Path, token) != original.Fingerprint)
            { throw new InvalidDataException("Source modifiée depuis la confirmation ; copie non publiée."); }
            source.BackupTo(copy); source.Commit();
            copy.Script("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;"); copy.Begin();
            if (original.Legacy)
            {
                // The immutable original is retained under deny-write handles. Upgrade ONLY the transaction on its copy,
                // using this destination's identity; do not initialize or create backup sidecars beside the historical source.
                var legacy = CheckLegacySwitchSource(copy, token);
                if (legacy.Identity is not null) copy.Execute("UPDATE domenia_store_state SET store_id=?1 WHERE id=1;", StoreId);
                Upgrade(copy);
                copy.Execute("INSERT INTO domenia_v2_metadata(key,payload) VALUES('legacy.directory','1');");
                _ = ReadLegacyDirectory(copy, null); // Prove the real local projection before selecting this copy.
            }
            else
            {
                CheckIdentity(copy, false, original.StoreId); EnsureSwitchTasksClosed(copy);
                RebindFleet(copy, original.StoreId); RelocateOperations(copy, original.StoreId);
            }
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

    private (string? Identity, long Revision) CheckLegacySwitchSource(SqliteDatabase db, CancellationToken token)
    {
        if (!Table(db, "schema_info") || !Table(db, "sync_state") || !Table(db, "ad_objects"))
            throw new InvalidDataException("Base D1 non qualifiée : schéma, domaine et index historique requis.");
        var versions = db.Query("SELECT key,value FROM schema_info WHERE key IN ('schema_version','domenia_schema');");
        if (versions.Count != 2 || versions.Count(v => (string?)v["key"] == "schema_version" && (string?)v["value"] == "11") != 1
            || versions.Count(v => (string?)v["key"] == "domenia_schema" && (string?)v["value"] == "1") != 1)
            throw new InvalidDataException("Reprise d’une base D1 séparée : schéma 11, révision 1 attendus ; aucune conversion devinée.");
        string? identity = null; long revision = 0;
        if (Table(db, "domenia_store_state"))
        {
            var rows = db.Query("SELECT id,store_id,domain_dn,revision FROM domenia_store_state LIMIT 2;");
            if (rows.Count > 1) throw new InvalidDataException("Identité D1 ambiguë.");
            if (rows.Count == 1)
            {
                identity = rows[0]["store_id"] as string;
                if (identity is not { Length: 64 } || !identity.All(char.IsAsciiHexDigit) || (long?)rows[0]["id"] != 1
                    || rows[0]["domain_dn"] is not string declared || !DistinguishedName.AreEqual(declared, DomainDn)
                    || rows[0]["revision"] is not long known || known < 0 || known == long.MaxValue)
                    throw new InvalidDataException("Identité, domaine ou révision D1 incohérente.");
                revision = known;
            }
        }
        var scopes = db.Query("SELECT base_dn FROM sync_state WHERE scope='directory' LIMIT 2;");
        if (scopes.Count > 1 || scopes.Count == 0 && identity is null
            || scopes.Any(row => row["base_dn"] is not string domain || !DistinguishedName.AreEqual(domain, DomainDn)))
            throw new InvalidDataException("Domaine D1 absent, ambigu ou différent ; aucune reprise.");
        // No V2 state without its identity can be reinterpreted as D1 after a damaged/deleted identity table.
        if ((long?)db.Scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name GLOB 'domenia_v2_*';") != 0)
            throw new InvalidDataException("Tables V2 sans identité : récupération manuelle requise, pas de reprise D1.");
        var count = 0;
        foreach (var row in db.ReadRows("SELECT distinguished_name,object_guid FROM ad_objects;"))
        {
            token.ThrowIfCancellationRequested();
            if (++count > 1_000_000 || !InDomain(row["distinguished_name"] as string))
                throw new InvalidDataException("Index historique hors du domaine ou au-delà d’un million d’objets ; aucune reprise.");
            if (row["object_guid"] is string guid && guid.Length > 0 && (!Guid.TryParseExact(guid, "D", out var id) || id == Guid.Empty || guid != id.ToString("D")))
                throw new InvalidDataException("GUID historique hors du format D1 canonique (D minuscule) ; original conservé pour vérification.");
        }
        if ((long)db.Scalar("SELECT count(*) FROM ad_objects WHERE object_type IN ('Machine','Utilisateur');")! > SyncRowsLimit)
            throw new InvalidDataException("Plus de 300 000 comptes historiques ; reprise manuelle requise.");
        _ = IndexRows(db, null); // Mandatory GUID/state checks before any publication, preserving valid GUID-less archives.
        EnsureSwitchTasksClosed(db);
        if (db.Scalar("PRAGMA quick_check;") as string != "ok") throw new InvalidDataException("Intégrité de la base D1 non confirmée.");
        return (identity, revision);
    }

    private bool HistoricalStore(SqliteDatabase db, string storeId) => Table(db, "domenia_v2_store_lineage")
        && db.Scalar("SELECT domain_dn FROM domenia_v2_store_lineage WHERE previous_store_id=?1;", storeId) is string domain
        && DistinguishedName.AreEqual(domain, DomainDn);
}
