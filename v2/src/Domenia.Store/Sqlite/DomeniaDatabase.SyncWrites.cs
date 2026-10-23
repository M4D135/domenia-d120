using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    public async Task<WritePrecheck> CheckSyncChangeAsync(SyncLocalChange change, CancellationToken cancellationToken)
    {
        ValidateSyncChange(change);
        var state = await ReadSyncStateAsync(cancellationToken).ConfigureAwait(false);
        return state.Revision == change.ExpectedRevision && SyncLocalIdentity.Fingerprint(state) == change.BeforeSha256
            ? WritePrecheck.Valid("Base et aperçu de synchronisation inchangés.") : WritePrecheck.Stale("Base modifiée depuis l’aperçu : préparez un nouveau plan.");
    }

    public async Task<SyncStorageReceipt> ApplySyncChangeAsync(SyncLocalChange change, CancellationToken cancellationToken)
    {
        ValidateSyncChange(change);
        var serialized = JsonSerializer.Serialize(change, Json);
        var sha = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(serialized)));
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady(); CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = new SqliteDatabase(Path, readOnly: false, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: false);
                var existing = SyncReceipt(db, change.Plan.Id, sha);
                if (existing is not null) { return existing; }
                var backup = lastBackup = Backup(db, cancellationToken);
                db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, allowLegacy: false);
                existing = SyncReceipt(db, change.Plan.Id, sha);
                if (existing is not null) { db.Rollback(); return existing; }
                var state = ReadSyncState(db);
                // Initialisation only adds empty schema objects; an absent store is compared with its original empty view.
                var comparable = change.ExpectedRevision == 0 && state.Rows.IsEmpty && state.Scopes.IsEmpty && state.Snapshots.IsEmpty
                    ? state with { Available = false } : state;
                if (state.Revision != change.ExpectedRevision || SyncLocalIdentity.Fingerprint(state) != change.BeforeSha256 && SyncLocalIdentity.Fingerprint(comparable) != change.BeforeSha256)
                { throw WriteErrors.Refusal(WriteErrors.Stale, "Base modifiée pendant la confirmation ; aucune écriture."); }
                using (var saved = new SqliteDatabase(backup.Path, readOnly: true, cancellationToken: cancellationToken))
                {
                    CheckIdentity(saved, allowLegacy: true);
                    if (SyncLocalIdentity.Fingerprint(ReadSyncState(saved)) != SyncLocalIdentity.Fingerprint(state))
                    { throw WriteErrors.Refusal(WriteErrors.Stale, "La base a changé pendant la sauvegarde ; aucune écriture."); }
                }
                // A legacy trigger could mutate an unrelated table without appearing in the sync projection.
                if ((long)db.Scalar("SELECT count(*) FROM sqlite_master WHERE type='trigger';")! != 0)
                { throw WriteErrors.Refusal(WriteErrors.Stale, "Déclencheur SQLite non qualifié ; la base est conservée sans modification."); }
                var revision = checked(state.Revision + 1);
                if (change.ResetPark)
                {
                    var park = state.Park ?? throw new InvalidDataException("Relevés du parc absents de la transaction.");
                    if (park.Total == 0 || park.Truncated || park.Rejected > 0 || park.UncertainDates > 0 || park.Rows.Length != park.Total || park.Generation == long.MaxValue)
                    { throw WriteErrors.Refusal(WriteErrors.Stale, "Relevé du parc vide, partiel ou illisible ; aucune suppression."); }
                    EnsureSweepLedger(db);
                    if (db.Execute("DELETE FROM park_state;") != park.Total) { throw new InvalidDataException("Nombre de relevés effacés incohérent."); }
                    db.Execute("UPDATE domenia_v2_sweep_state SET generation=?1 WHERE id=1;", park.Generation + 1);
                }
                foreach (var row in change.Rows)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var old = state.Rows.FirstOrDefault(x => x.ObjectGuid == row.ObjectGuid);
                    if (old is not null && old.ObservedAt > row.ObservedAt) { throw WriteErrors.Refusal(WriteErrors.Stale, "Une observation plus récente doit être conservée."); }
                    WriteIndex(db, row, change.Coverage?.Server ?? change.Plan.Controller, revision);
                }
                foreach (var absence in change.Absences)
                {
                    db.Execute("INSERT INTO ad_absences(object_key,object_guid,object_type,name,last_dn,scope_dn,noticed_at,server,status,checked_at,found_dn,detail) VALUES(?1,?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) ON CONFLICT(object_key) DO UPDATE SET name=excluded.name,last_dn=excluded.last_dn,scope_dn=excluded.scope_dn,noticed_at=excluded.noticed_at,server=excluded.server,status=excluded.status,checked_at=excluded.checked_at,found_dn=excluded.found_dn,detail=excluded.detail;",
                        absence.ObjectGuid.ToString("D"), absence.Type == IndexObjectType.Computer ? "Machine" : "Utilisateur", absence.Name, absence.LastDn, absence.ScopeDn, Stamp(absence.NoticedAt), absence.Server, absence.Status.ToString(), Stamp(absence.CheckedAt), absence.FoundDn, absence.Detail);
                }
                foreach (var id in change.ResolvedGaps) { db.Execute("DELETE FROM ad_census_gaps WHERE object_guid=?1 COLLATE NOCASE;", id.ToString("D")); }
                if (change.Coverage is { } coverage)
                {
                    db.Execute("INSERT INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(scope) DO UPDATE SET server=excluded.server,base_dn=excluded.base_dn,highest_usn=excluded.highest_usn,last_sync=excluded.last_sync,item_count=excluded.item_count,details=excluded.details;",
                        coverage.Key, coverage.Server, coverage.BaseDn, coverage.Usn, Stamp(coverage.LastSync), coverage.Items, "depth=" + coverage.Depth + (coverage.Partial ? ";partial" : ";full") + ";cut=" + coverage.CutReason + ";limit=" + coverage.CutLimit.ToString(System.Globalization.CultureInfo.InvariantCulture));
                }
                if (change.Capture is { } capture)
                {
                    if (state.Snapshots.Length >= SyncSnapshots.MaxPerDomain || state.Snapshots.Any(x => x.Id == capture.Id)) { throw WriteErrors.Refusal(WriteErrors.Stale, "Limite des relevés atteinte ou identité déjà utilisée."); }
                    db.Execute("INSERT INTO ad_snapshots(snapshot_id,label,domain_dn,scope_dn,subtree,captured_at,object_count,coverage_state,coverage_at,coverage_source,coverage_text,rows_sha256) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12);",
                        capture.Id, capture.Label, capture.DomainDn, capture.ScopeDn, capture.Subtree ? 1 : 0, Stamp(capture.CapturedAt), capture.Lines.Length, capture.CoverageState.ToString(), Stamp(capture.CoverageAt), capture.CoverageSource, capture.CoverageText, capture.RowsSha256);
                    foreach (var line in capture.Lines)
                    { db.Execute("INSERT INTO ad_snapshot_rows(snapshot_id,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11);", capture.Id, line.ObjectGuid.ToString("D"), line.Type == IndexObjectType.Computer ? "Machine" : "Utilisateur", line.Name, line.Login, line.Upn, line.DisplayName, line.Description, line.Extra, line.Enabled ? "Actif" : "Desactive", line.Dn); }
                }
                if (change.DeleteSnapshot is { } deleted)
                {
                    if (!state.Snapshots.Any(x => x.Id == deleted)) { throw WriteErrors.Refusal(WriteErrors.Stale, "Relevé déjà absent."); }
                    db.Execute("DELETE FROM ad_snapshot_rows WHERE snapshot_id=?1;", deleted);
                    if (db.Execute("DELETE FROM ad_snapshots WHERE snapshot_id=?1;", deleted) != 1) { throw new InvalidDataException("Effacement du relevé non confirmé."); }
                }
                db.Execute("UPDATE domenia_store_state SET revision=?1 WHERE id=1;", revision);
                var after = ReadSyncState(db);
                foreach (var row in change.Rows)
                { if (after.Rows.SingleOrDefault(x => x.ObjectGuid == row.ObjectGuid) != row) { throw new InvalidDataException("Relecture des lignes avant commit incohérente."); } }
                if (change.Capture is { } proof && !after.Snapshots.Any(x => x.Id == proof.Id && x.RowsSha256 == proof.RowsSha256)
                    || change.DeleteSnapshot is { } gone && after.Snapshots.Any(x => x.Id == gone)) { throw new InvalidDataException("Relecture du relevé incohérente."); }
                foreach (var absence in change.Absences)
                { if (after.Absences.SingleOrDefault(x => x.ObjectGuid == absence.ObjectGuid) != absence) { throw new InvalidDataException("Relecture des disparitions incohérente."); } }
                if (change.ResolvedGaps.Any(id => after.Gaps.Any(x => x.ObjectGuid == id))
                    || change.Coverage is { } expectedCoverage && after.Scopes.SingleOrDefault(x => x.Key == expectedCoverage.Key) != expectedCoverage
                    || change.ResetPark && (after.Park?.Total != 0 || after.Park.Generation != state.Park!.Generation + 1))
                { throw new InvalidDataException("Relecture de la couverture, du recensement ou du parc incohérente."); }
                var receipt = new SyncStorageReceipt(change.Plan.Id, "local", change.Plan.Title, clock.GetUtcNow(), change.Rows.Length + change.Absences.Length + change.ResolvedGaps.Length + (change.Capture?.Lines.Length ?? 0) + (change.ResetPark ? checked((int)state.Park!.Total) : 0), sha, true,
                    "Transaction locale relue et validée ; sauvegarde SHA-256 " + lastBackup!.Sha256 + ". Aucun objet AD supprimé.");
                db.Script("CREATE TABLE IF NOT EXISTS domenia_v2_sync_receipts(plan_id TEXT PRIMARY KEY,sha256 TEXT NOT NULL,committed_at TEXT NOT NULL,payload TEXT NOT NULL);");
                db.Execute("INSERT INTO domenia_v2_sync_receipts(plan_id,sha256,committed_at,payload) VALUES(?1,?2,?3,?4);", change.Plan.Id, sha, Stamp(receipt.At), JsonSerializer.Serialize(receipt, Json));
                if (SyncReceipt(db, change.Plan.Id, sha) != receipt) { throw new InvalidDataException("Reçu de synchronisation incohérent avant commit."); }
                SaveSyncProof(db, change.Plan, receipt, SyncLocalIdentity.Fingerprint(after), revision, backup.Sha256);
                db.Commit();
                using var reread = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
                CheckIdentity(reread, allowLegacy: false);
                _ = ReadSyncProof(reread, change.Plan) ?? throw new InvalidDataException("Preuve de transaction absente après commit.");
                return SyncReceipt(db, change.Plan.Id, sha) ?? throw new InvalidDataException("Reçu absent après commit.");
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private void ValidateSyncChange(SyncLocalChange change)
    {
        ArgumentNullException.ThrowIfNull(change);
        var plan = change.Plan;
        if (change.StoreId != StoreId || change.ExpectedRevision < 0 || change.BeforeSha256.Length != 64 || plan.Kind != SyncStoreChange.Kind || plan.Simulated
            || plan.Mode != AppInfoBuilder.DirectoryModeText || !WritePlans.IsIntact(plan) || plan.Target.Dn != SyncLocalIdentity.Target(StoreId, DomainDn)
            || !WritePlans.IsPlanId(plan.Id) || plan.Target.ObjectGuid != SyncStoreChange.IndexStoreGuid.ToString("D")
            || plan.ExpiresAt <= clock.GetUtcNow() || change.Rows.IsDefault || change.Absences.IsDefault || change.ResolvedGaps.IsDefault
            || change.Rows.Length > SyncRowsLimit || change.Absences.Length > SyncRowsLimit || change.ResolvedGaps.Length > SyncRowsLimit
            || change.Rows.Select(x => x.ObjectGuid).Distinct().Count() != change.Rows.Length
            || change.Absences.Select(x => x.ObjectGuid).Distinct().Count() != change.Absences.Length
            || change.ResolvedGaps.Distinct().Count() != change.ResolvedGaps.Length
            || plan.Changes.Count(x => x.Attribute == SyncLocalIdentity.StateAttribute && x.BeforeValue == SyncLocalIdentity.StateValue(change)) != 1
            || plan.Changes.Count(x => x.Attribute == SyncLocalIdentity.PayloadAttribute && x.AfterValue == SyncLocalIdentity.PayloadFingerprint(change)) != 1)
        { throw new InvalidDataException("Plan local de synchronisation invalide ou expiré."); }
        var head = SyncStoreChange.Head(plan) ?? throw new InvalidDataException("Opération locale inconnue.");
        var batch = change.Capture is null && change.DeleteSnapshot is null && !change.ResetPark;
        if ((head.Operation == SyncStoreOperation.Batch) != batch
            || (head.Operation == SyncStoreOperation.SnapshotCapture) != (change.Capture is not null)
            || (head.Operation == SyncStoreOperation.SnapshotDelete) != (change.DeleteSnapshot is not null)
            || (head.Operation == SyncStoreOperation.ParkReset) != change.ResetPark
            || !batch && (!change.Rows.IsEmpty || !change.Absences.IsEmpty || !change.ResolvedGaps.IsEmpty || change.Coverage is not null))
        { throw new InvalidDataException("Le contenu local ne correspond pas à l’opération confirmée."); }
        if (change.Rows.Any(x => x.ObjectGuid == Guid.Empty || !InDomain(x.Dn) || x.ObservedAt == DateTimeOffset.MinValue || x.ObservedAt > clock.GetUtcNow().AddMinutes(2))
            || change.Absences.Any(x => x.ObjectGuid == Guid.Empty || !InDomain(x.LastDn) || !InDomain(x.ScopeDn)
                || x.FoundDn is not null && !InDomain(x.FoundDn) || x.NoticedAt == DateTimeOffset.MinValue || x.Detail.Length > 4096)
            || change.ResolvedGaps.Any(x => x == Guid.Empty))
        { throw new InvalidDataException("Identité ou date du lot local invalide."); }
        if (change.Coverage is { } coverage && (!InDomain(coverage.BaseDn) || coverage.Depth is not ("Subtree" or "OneLevel") || coverage.LastSync > clock.GetUtcNow().AddMinutes(2)
            || coverage.InvocationId is not null || coverage.Usn != 0 || coverage.Items != change.Rows.Length
            || coverage.Partial != coverage.Key.StartsWith("attempt:", StringComparison.Ordinal)
            || coverage.Partial && change.Absences.Any(x => x.Status == AbsenceStatus.NotSeen)
            || coverage.CutReason?.Any(c => !char.IsAsciiLetter(c)) == true || coverage.CutLimit < 0))
        { throw new InvalidDataException("Couverture du lot local invalide."); }
        if (change.Capture is { } snapshot && (!InDomain(snapshot.ScopeDn) || !DistinguishedName.AreEqual(snapshot.DomainDn, DomainDn) || !WritePlans.IsPlanId(snapshot.Id)
            || snapshot.Lines.Length > SyncSnapshots.MaxObjects || SyncSnapshots.Fingerprint(snapshot.Lines) != snapshot.RowsSha256 || snapshot.Lines.Any(x => !InDomain(x.Dn) || !ScopeRules.Contains(new(snapshot.ScopeDn, snapshot.Label, snapshot.Subtree), x.Dn))
            || snapshot.Lines.Select(x => x.ObjectGuid).Distinct().Count() != snapshot.Lines.Length || head.Id != snapshot.Id || head.Sha256 != snapshot.RowsSha256))
        { throw new InvalidDataException("Relevé local invalide."); }
        if (change.DeleteSnapshot is { } id && (!WritePlans.IsPlanId(id) || head.Id != id)) { throw new InvalidDataException("Identité de relevé invalide."); }
    }

    private static SyncStorageReceipt? SyncReceipt(SqliteDatabase db, string id, string sha)
    {
        if (!Table(db, "domenia_v2_sync_receipts")) { return null; }
        var row = db.Query("SELECT sha256,CASE WHEN length(payload)<=16384 THEN payload ELSE NULL END AS payload FROM domenia_v2_sync_receipts WHERE plan_id=?1;", id).SingleOrDefault();
        if (row is null) { return null; }
        if (row["sha256"] as string != sha) { throw new InvalidDataException("Identifiant de plan déjà utilisé avec un autre lot."); }
        return JsonSerializer.Deserialize<SyncStorageReceipt>(row["payload"] as string ?? throw new InvalidDataException("Reçu trop volumineux."), Json) ?? throw new InvalidDataException("Reçu illisible.");
    }
}
