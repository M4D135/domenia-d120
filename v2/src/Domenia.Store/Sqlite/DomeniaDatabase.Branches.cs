using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private const int BranchBytes = 64 * 1024 * 1024;
    private static string BranchKey(string dn) => DistinguishedName.Format(DistinguishedName.Parse(dn)).ToUpperInvariant();

    public Task<DirectoryBranch?> ReadBranchAsync(string dn, CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!DatabaseFileExists()) { return null; }
        using var db = Open(readOnly: true, cancellationToken: cancellationToken);
        db.Begin(write: false); CheckIdentity(db, allowLegacy: true);
        var read = ReadBranch(db, dn); db.Commit(); return read;
    }, cancellationToken);

    public Task<DirectoryBranch> SaveBranchAsync(DirectoryBranch branch, CancellationToken cancellationToken) =>
        ObserveWriteAsync("SaveBranch", branch, true, ct => SaveBranchCoreAsync(branch, ct), cancellationToken);

    private async Task<DirectoryBranch> SaveBranchCoreAsync(DirectoryBranch branch, CancellationToken cancellationToken)
    {
        DirectoryBranchRules.Validate(branch, DomainDn);
        var json = JsonSerializer.Serialize(branch, Json);
        if (Encoding.UTF8.GetByteCount(json) > BranchBytes) { throw new InvalidDataException("Branche supérieure au budget de 64 Mio : enregistrement annulé."); }
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                EnsureReady(); CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = Open(readOnly: false, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: false);
                if (!Table(db, "domenia_v2_directory_branches")) { lastBackup = Backup(db, cancellationToken); } else { EnsureBackup(db, cancellationToken); }
                db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, allowLegacy: false);
                db.Execute("CREATE TABLE IF NOT EXISTS domenia_v2_directory_branches(parent_dn TEXT PRIMARY KEY NOT NULL,payload TEXT NOT NULL,sha256 TEXT NOT NULL);");
                var key = BranchKey(branch.Parent.Dn);
                if (db.Scalar("SELECT 1 FROM domenia_v2_directory_branches WHERE parent_dn=?1;", key) is null
                    && (long?)db.Scalar("SELECT COUNT(*) FROM domenia_v2_directory_branches;") >= DirectoryBranchRules.MaxChildren)
                { throw new InvalidDataException("Cache limité à 100 000 branches : enregistrement annulé."); }
                db.Execute("INSERT INTO domenia_v2_directory_branches(parent_dn,payload,sha256) VALUES(?1,?2,?3) ON CONFLICT(parent_dn) DO UPDATE SET payload=excluded.payload,sha256=excluded.sha256;", key, json, QueryHash(json));
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                if (ReadBranch(db, branch.Parent.Dn)?.ReadId != branch.ReadId) { throw new InvalidDataException("Branche différente après écriture : transaction annulée."); }
                db.Commit();
            }, cancellationToken).ConfigureAwait(false);
            // Read after commit with a fresh connection. No network object is published before this succeeds.
            var verified = await ReadBranchAsync(branch.Parent.Dn, cancellationToken).ConfigureAwait(false);
            if (verified?.ReadId != branch.ReadId) { throw new InvalidDataException("Branche modifiée ou absente après commit : publication annulée."); }
            return verified;
        }
        finally { writer.Release(); }
    }

    private DirectoryBranch? ReadBranch(SqliteDatabase db, string dn)
    {
        if (!Table(db, "domenia_v2_directory_branches")) { return null; }
        var row = db.Query("SELECT CASE WHEN length(CAST(payload AS BLOB))<=67108864 THEN payload END AS payload,sha256 FROM domenia_v2_directory_branches WHERE parent_dn=?1;", BranchKey(dn)).SingleOrDefault();
        if (row is null) { return null; }
        if (row["payload"] is not string json || QueryHash(json) != row["sha256"] as string) { throw new InvalidDataException("Branche illisible ou empreinte différente."); }
        var branch = JsonSerializer.Deserialize<DirectoryBranch>(json, Json) ?? throw new InvalidDataException("Branche vide.");
        DirectoryBranchRules.Validate(branch, DomainDn);
        if (!DistinguishedName.AreEqual(branch.Parent.Dn, dn)) { throw new InvalidDataException("Identité de branche incohérente."); }
        return branch;
    }
}
