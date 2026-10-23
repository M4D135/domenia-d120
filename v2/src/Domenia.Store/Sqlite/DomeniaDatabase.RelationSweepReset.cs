using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    public Task<WritePrecheck> CheckRelationSweepResetAsync(RelationSweepResetWrite request, CancellationToken token) => Task.Run(() =>
    {
        ValidateSweepReset(request); CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return WritePrecheck.Stale("Base du plan introuvable ; aucune nouvelle base créée pour l’effacement."); }
        using var db = new SqliteDatabase(Path, true, cancellationToken: token); db.Begin(false); CheckIdentity(db, true);
        var check = ExistingSweepReset(db, request) is not null ? WritePrecheck.Valid("Effacement déjà enregistré ; aucun rejeu.")
            : CheckSweepResetRows(request, ReadRelationSweeps(db, token));
        db.Commit(); return check;
    }, token);

    public async Task<RelationSweepResetResult> ResetRelationSweepsAsync(RelationSweepResetWrite request, CancellationToken token)
    {
        ValidateSweepReset(request); await writer.WaitAsync(token).ConfigureAwait(false);
        try { return await Task.Run(() => ResetSweeps(request, token), token).ConfigureAwait(false); }
        finally { writer.Release(); }
    }

    private RelationSweepResetResult ResetSweeps(RelationSweepResetWrite request, CancellationToken token)
    {
        EnsureReady(); CompatibleDirectoryCache.ValidateLocalPath(Path);
        using var db = new SqliteDatabase(Path, false, cancellationToken: token); CheckIdentity(db, false);
        if (ExistingSweepReset(db, request) is { } recorded) { return recorded; }
        var backup = lastBackup = Backup(db, token);
        db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, false);
        if (ExistingSweepReset(db, request) is { } raced) { db.Commit(); return raced; }
        var before = ReadRelationSweeps(db, token); var check = CheckSweepResetRows(request, before);
        if (!check.Current) { throw WriteErrors.Refusal(WriteErrors.Stale, check.Detail); }
        using (var saved = new SqliteDatabase(backup.Path, true, cancellationToken: token))
        {
            CheckIdentity(saved, true); var recoverable = ReadRelationSweeps(saved, token);
            if (recoverable.Truncated || recoverable.Rejected > 0 || recoverable.Total != before.Total || recoverable.Generation != before.Generation || recoverable.Fingerprint != before.Fingerprint)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Sauvegarde et relevés courants différents ; aucune suppression. Préparez de nouveau l’effacement."); }
        }
        EnsureSweepLedger(db);
        var changesBefore = (long)db.Scalar("SELECT total_changes();")!;
        if (Table(db, "park_state")) { db.Execute("DELETE FROM park_state;"); }
        var generation = checked(before.Generation + 1);
        db.Execute("UPDATE domenia_v2_sweep_state SET generation=?1 WHERE id=1;", generation);
        db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
        var revision = (long)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;")!;
        db.Execute("INSERT INTO domenia_v2_sweep_writes(id,request_sha256,operation,generation,updated,ignored,revision,backup_path,backup_sha256) VALUES(?1,?2,'reset',?3,?4,0,?5,?6,?7);",
            request.Plan.Id, SweepResetHash(request), generation, before.Total, revision, backup.Path, backup.Sha256);
        var after = ReadRelationSweeps(db, token);
        // SQLite counts trigger and foreign-key writes too. Reject any side effect beyond these rows, generation, revision and receipt.
        var changes = (long)db.Scalar("SELECT total_changes();")! - changesBefore;
        if (after.Total != 0 || after.Rejected > 0 || after.Truncated || after.Generation != generation || changes != before.Total + 3)
        { throw new InvalidDataException("Effacement non conforme ou effets supplémentaires d’un déclencheur ; transaction annulée."); }
        db.Commit(); return new(checked((int)before.Total), generation, revision, false, backup.Path, backup.Sha256);
    }

    private void ValidateSweepReset(RelationSweepResetWrite request)
    {
        ArgumentNullException.ThrowIfNull(request); ArgumentNullException.ThrowIfNull(request.Plan);
        var plan = request.Plan;
        if (request.StoreId != StoreId || request.Generation < 0 || plan.Kind != RelationSweepReset.Kind || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText
            || !WritePlans.IsPlanId(plan.Id) || !WritePlans.IsIntact(plan) || plan.Target.ObjectGuid != RelationSweepReset.MemoryGuid.ToString("D")
            || plan.Target.Dn != RelationSweepReset.StoreTarget(StoreId, DomainDn) || plan.Changes.Length != 1)
        { throw new ArgumentException("Plan d’effacement invalide ou d’une autre base."); }
        var change = plan.Changes[0]; var raw = change.BeforeValue?.Split('|');
        if (change.Attribute != RelationSweepReset.Attribute || change.Kind != WriteChangeKind.Reset || change.AfterValue != RelationSweepReset.Value(0, "")
            || raw is not { Length: 2 } || !int.TryParse(raw[0], NumberStyles.None, CultureInfo.InvariantCulture, out var count) || count is < 1 or > 50_000
            || raw[1].Length != 64 || raw[1].Any(c => !char.IsAsciiHexDigit(c)) || raw[0] != count.ToString(CultureInfo.InvariantCulture))
        { throw new ArgumentException("État de départ du plan d’effacement illisible."); }
    }

    private WritePrecheck CheckSweepResetRows(RelationSweepResetWrite request, RelationSweepCacheSnapshot current)
    {
        if (request.Plan.ExpiresAt <= clock.GetUtcNow()) { return WritePrecheck.Stale("Plan d’effacement expiré ; préparez-le de nouveau."); }
        if (current.Truncated || current.Rejected > 0 || current.Rows.Length != current.Total
            || current.Rows.GroupBy(r => r.StorageKey, StringComparer.Ordinal).Any(g => g.Count() > 1))
        { return WritePrecheck.Stale("Mémoire partielle ou ambiguë ; aucune suppression des lignes illisibles."); }
        if (current.Generation != request.Generation || current.Generation == long.MaxValue)
        { return WritePrecheck.Stale("Génération de relevés modifiée ou épuisée ; préparez de nouveau l’effacement."); }
        return RelationSweepReset.Check(request.Plan, checked((int)current.Total), current.Fingerprint);
    }

    private static string SweepResetHash(RelationSweepResetWrite request) => Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(request)));

    private static RelationSweepResetResult? ExistingSweepReset(SqliteDatabase db, RelationSweepResetWrite request)
    {
        if (!Table(db, SweepWritesTable)) { return null; }
        // A record receipt may precede the additive reset columns; inspect identity before reading optional metadata.
        var ids = db.Query("SELECT request_sha256,operation FROM domenia_v2_sweep_writes WHERE id=?1 LIMIT 2;", request.Plan.Id);
        if (ids.Count == 0) { return null; }
        if (ids.Count != 1 || (string?)ids[0]["request_sha256"] != SweepResetHash(request) || (string?)ids[0]["operation"] != "reset")
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Identifiant déjà utilisé pour un autre changement ; aucun effacement rejoué."); }
        var row = db.Query("SELECT generation,updated,ignored,revision,backup_path,backup_sha256 FROM domenia_v2_sweep_writes WHERE id=?1;", request.Plan.Id).Single();
        if (row["generation"] is not long generation || request.Generation == long.MaxValue || generation != request.Generation + 1
            || row["updated"] is not long count || count is < 0 or > 50_000 || row["ignored"] is not long ignored || ignored != 0
            || row["revision"] is not long revision || revision < 0 || row["backup_path"] is not string path || path.Length is 0 or > 32_768
            || row["backup_sha256"] is not string hash || hash.Length != 64 || hash.Any(c => !char.IsAsciiHexDigit(c)))
        { throw new InvalidDataException("Reçu d’effacement illisible ; aucun rejeu."); }
        return new((int)count, generation, revision, true, path, hash);
    }
}
