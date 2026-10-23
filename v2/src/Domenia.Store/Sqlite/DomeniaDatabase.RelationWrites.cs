using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private const string RelationJournalTable = "domenia_v2_relation_journal";
    private const string RelationWritesTable = "domenia_v2_relation_writes";

    public Task<WritePrecheck> CheckRelationsAsync(RelationStoreWrite request, CancellationToken token) => Task.Run(() =>
    {
        ValidateRelationWrite(request);
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return CheckRelationRows(request, RelationCacheSnapshot.Empty(StoreId, DomainDn)); }
        using var db = new SqliteDatabase(Path, true, cancellationToken: token);
        db.Begin(false); CheckIdentity(db, true);
        var result = ExistingRelationWrite(db, request) is not null ? WritePrecheck.Valid("Ce lot a déjà été enregistré ; il ne sera pas rejoué.")
            : CheckRelationRows(request, ReadRelations(db, token));
        db.Commit(); return result;
    }, token);

    public async Task<RelationStoreResult> ApplyRelationsAsync(RelationStoreWrite request, CancellationToken token)
    {
        ValidateRelationWrite(request);
        await writer.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() => ApplyRelations(request, token), token).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private RelationStoreResult ApplyRelations(RelationStoreWrite request, CancellationToken token)
    {
        EnsureReady(); CompatibleDirectoryCache.ValidateLocalPath(Path);
        using var db = new SqliteDatabase(Path, false, cancellationToken: token);
        CheckIdentity(db, false);
        // A committed plan is never replayed, even if another legitimate plan subsequently removed its result.
        if (ExistingRelationWrite(db, request) is { } committed) { return committed; }
        var destructive = request.Items.Any(i => i.Before is not null);
        if (destructive || !Table(db, RelationWritesTable)) { lastBackup = Backup(db, token); }
        else { EnsureBackup(db, token); }
        using var journalFile = OpenRelationJournalForAppend();
        if (journalFile is null && request.Items.Any(i => i.RestoresEntry is not null))
        { throw RelationStale("Le journal historique est occupé ou inaccessible ; restauration différée."); }
        db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, false);
        if (ExistingRelationWrite(db, request) is { } raced) { db.Commit(); return raced; }
        var snapshot = ReadRelations(db, token);
        var check = CheckRelationRows(request, snapshot);
        if (!check.Current) { throw RelationStale(check.Detail); }
        ValidateRestorations(db, request, token);
        var store = UniqueRelationStore(snapshot);
        var records = request.Items.Where(i => i.After is not null).Select(i => i.After!).ToDictionary(RelationRules.Fingerprint, StringComparer.Ordinal);
        var notes = request.Items.ToDictionary(i => RelationRules.Fingerprint(i.After ?? i.Before!), i => (i.Note, i.RestoresEntry), StringComparer.Ordinal);
        var result = RelationChange.Apply(request.Plan, store, key => records.GetValueOrDefault(key),
            key => notes.GetValueOrDefault(key), clock.GetUtcNow(), WritePlans.NewId);
        EnsureRelationWriteSchema(db);
        var physical = snapshot.Rows.GroupBy(r => RelationRules.Key(r.Relation), StringComparer.Ordinal)
            .Where(g => g.Count() == 1).ToDictionary(g => g.Key, g => g.First(), StringComparer.Ordinal);
        var occupied = snapshot.Rows.Select(r => r.StorageKey).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var item in request.Items)
        {
            token.ThrowIfCancellationRequested();
            var beforeKey = item.Before is null ? null : RelationRules.Key(item.Before);
            var afterKey = item.After is null ? null : RelationRules.Key(item.After);
            var old = beforeKey is null ? null : physical.GetValueOrDefault(beforeKey);
            if (item.After is null)
            {
                if (old is not null) { db.Execute("DELETE FROM user_machine_links WHERE computer_key=?1;", old.StorageKey); occupied.Remove(old.StorageKey); }
                continue;
            }
            if (store.TryGetValue(afterKey!, out var held) && RelationRules.Fingerprint(held) == RelationRules.Fingerprint(item.After)) { continue; }
            var storageKey = old?.StorageKey ?? NewRelationStorageKey(item.After, occupied);
            WriteRelationRow(db, storageKey, item.After, old is not null);
            occupied.Add(storageKey);
        }
        foreach (var entry in result.Journal)
        {
            var payload = SerializeRelationJournal(entry);
            if (Encoding.UTF8.GetByteCount(payload) > RelationJournalLineBytes) { throw new InvalidDataException("Entrée de journal trop volumineuse ; lot annulé."); }
            db.Execute("INSERT INTO domenia_v2_relation_journal(id,plan_id,at,payload,restores_id,exported) VALUES(?1,?2,?3,?4,?5,0);",
                entry.Id, request.Plan.Id, Stamp(entry.At), payload, entry.Action == RelationJournalAction.Restored ? entry.Note : null);
        }
        // Re-read before COMMIT: an incompatible schema, trigger or conversion rolls back the whole lot, including its journal.
        var reread = ReadRelations(db, token);
        var persisted = UniqueRelationStore(reread);
        var verification = RelationChange.Verify(request.Plan, persisted);
        var exact = persisted.Count == result.Store.Count && result.Store.All(p => persisted.TryGetValue(p.Key, out var value)
            && RelationRules.Fingerprint(value) == RelationRules.Fingerprint(p.Value));
        if (reread.Rejected > 0 || reread.Truncated || !exact || reread.Total != snapshot.Total + result.Store.Count - store.Count
            || verification.State != VerificationState.Verified)
        { throw new InvalidDataException("Relecture des associations non conforme ; transaction annulée."); }
        if (result.Applied > 0) { db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;"); }
        var revision = (long)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;")!;
        db.Execute("INSERT INTO domenia_v2_relation_writes(id,fingerprint,request_sha256,revision,applied,already_done) VALUES(?1,?2,?3,?4,?5,?6);",
            request.Plan.Id, request.Plan.Fingerprint, RelationRequestHash(request), revision, result.Applied, result.AlreadyDone);
        db.Commit();
        // SQLite is authoritative. A failed legacy projection never loses a removal or makes a committed lot replayable.
        var pending = ExportRelationJournal(db, journalFile);
        return new(result.Applied, result.AlreadyDone, revision, pending, pending == 0 ? "Associations et journal enregistrés puis relus."
            : "Associations et journal enregistrés puis relus dans SQLite ; copie du journal D1 en attente.");
    }

    private void ValidateRelationWrite(RelationStoreWrite request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var plan = request.Plan;
        if (request.StoreId != StoreId || plan.Kind != RelationChange.Kind || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText
            || plan.Target.Kind != "relations" || plan.Target.ObjectGuid != RelationChange.StoreGuid.ToString("D") || plan.Controller is not null
            || !WritePlans.IsPlanId(plan.Id) || !WritePlans.IsIntact(plan) || plan.ExpiresAt <= clock.GetUtcNow() || plan.CreatedAt > clock.GetUtcNow().AddMinutes(2)
            || request.Items.Length is < 1 or > WritePlans.MaxChanges || request.Items.Length != plan.Changes.Length || request.Expected.Length > WritePlans.MaxChanges * 2)
        { throw RelationStale("Plan local invalide, expiré ou destiné à une autre base."); }
        var touched = new HashSet<string>(StringComparer.Ordinal);
        for (var i = 0; i < request.Items.Length; i++)
        {
            var item = request.Items[i]; var change = plan.Changes[i];
            var kind = item.Operation switch { RelationChangeOperation.Add => WriteChangeKind.Add, RelationChangeOperation.Remove => WriteChangeKind.Remove,
                RelationChangeOperation.Replace => WriteChangeKind.Replace, _ => throw RelationStale("Opération locale inconnue.") };
            if (change.Attribute != RelationChange.Attribute || change.Kind != kind || change.ReferenceGuid is not null
                || change.BeforeValue != (item.Before is null ? null : RelationChange.Value(item.Before))
                || change.AfterValue != (item.After is null ? null : RelationChange.Value(item.After))
                || kind == WriteChangeKind.Add && (item.Before is not null || item.After is null)
                || kind == WriteChangeKind.Remove && (item.Before is null || item.After is not null)
                || kind == WriteChangeKind.Replace && (item.Before is null || item.After is null)
                || item.Note?.Length > 4096 || item.RestoresEntry is not null && (!WritePlans.IsPlanId(item.RestoresEntry) || kind != WriteChangeKind.Add))
            { throw RelationStale("Les données conservées ne correspondent plus au plan scellé."); }
            var keys = new[] { item.Before, item.After }.OfType<StoredRelation>().Select(RelationRules.Key).Distinct(StringComparer.Ordinal);
            if (keys.Any(key => !touched.Add(key))) { throw RelationStale("Une même association est touchée plusieurs fois dans ce lot."); }
            if (item.After is not null) { ValidateRelationRecord(item.After); }
        }
        if (request.Expected.Select(r => r.StorageKey).Distinct(StringComparer.Ordinal).Count() != request.Expected.Length
            || request.Expected.Any(r => !touched.Contains(RelationRules.Key(r.Relation))))
        { throw RelationStale("Préconditions physiques incohérentes."); }
    }

    private void ValidateRelationRecord(StoredRelation relation)
    {
        var row = RelationValues(relation, "validation");
        if (!Enum.IsDefined(relation.Kind) || relation.UserGuid == Guid.Empty || relation.ComputerGuid == Guid.Empty
            || RelationColumns.Any(c => row.GetValueOrDefault(c.Name) is string text && (text.Length > c.Limit || text.Contains('\0')))
            || !TryRelation(row, out var parsed, out var uncertain) || uncertain || RelationRules.Fingerprint(parsed!) != RelationRules.Fingerprint(relation))
        { throw new InvalidDataException("Association hors contrat ; aucune écriture."); }
    }

    private static WritePrecheck CheckRelationRows(RelationStoreWrite request, RelationCacheSnapshot current)
    {
        if (current.Truncated || current.Rejected > 0) { return WritePrecheck.Stale("La base contient des associations non lisibles ou dépasse la limite ; aucune écriture partielle."); }
        var keys = request.Items.SelectMany(i => new[] { i.Before, i.After }).OfType<StoredRelation>().Select(RelationRules.Key).ToHashSet(StringComparer.Ordinal);
        var actual = current.Rows.Where(r => keys.Contains(RelationRules.Key(r.Relation))).ToArray();
        if (actual.GroupBy(r => RelationRules.Key(r.Relation), StringComparer.Ordinal).Any(g => g.Count() > 1))
        { return WritePrecheck.Stale("Plusieurs lignes physiques représentent la même association ; aucun choix arbitraire."); }
        // Physical compare-and-swap also detects legacy confidence/date formatting changes hidden by the typed view.
        foreach (var expected in request.Expected)
        {
            var row = actual.SingleOrDefault(r => r.StorageKey == expected.StorageKey);
            if (row is not null && row.StorageFingerprint != expected.StorageFingerprint)
            { return WritePrecheck.Stale("Une ligne historique a changé depuis le plan ; rechargez les associations."); }
            if (row is null && current.Rows.Any(r => r.StorageKey == expected.StorageKey))
            { return WritePrecheck.Stale("Une clé historique désigne désormais une autre association."); }
        }
        foreach (var item in request.Items.Where(i => i.Before is not null))
        {
            if (!request.Expected.Any(r => RelationRules.Key(r.Relation) == RelationRules.Key(item.Before!)
                && RelationRules.Fingerprint(r.Relation) == RelationRules.Fingerprint(item.Before!)))
            { return WritePrecheck.Stale("Précondition physique manquante pour un retrait ou une mise à jour."); }
        }
        foreach (var row in actual)
        {
            if (request.Expected.Any(r => r.StorageKey == row.StorageKey)) { continue; }
            // Another actor may already have applied an addition, but cannot silently relocate the row being replaced/removed.
            if (!request.Items.Any(i => i.Operation == RelationChangeOperation.Add && i.After is not null
                && RelationRules.Fingerprint(i.After) == RelationRules.Fingerprint(row.Relation)))
            { return WritePrecheck.Stale("L’association a changé de clé physique depuis le plan."); }
        }
        var records = request.Items.Where(i => i.After is not null).Select(i => RelationRules.Fingerprint(i.After!)).ToHashSet(StringComparer.Ordinal);
        return RelationChange.Check(request.Plan, UniqueRelationStore(current), records.Contains);
    }

    private static ImmutableDictionary<string, StoredRelation> UniqueRelationStore(RelationCacheSnapshot snapshot) => snapshot.Rows
        .GroupBy(r => RelationRules.Key(r.Relation), StringComparer.Ordinal).Where(g => g.Count() == 1)
        .ToImmutableDictionary(g => g.Key, g => g.First().Relation, StringComparer.Ordinal);

    private RelationStoreResult? ExistingRelationWrite(SqliteDatabase db, RelationStoreWrite request)
    {
        if (!Table(db, RelationWritesTable)) { return null; }
        var row = db.Query("SELECT fingerprint,request_sha256,revision,applied,already_done FROM domenia_v2_relation_writes WHERE id=?1;", request.Plan.Id).SingleOrDefault();
        if (row is null) { return null; }
        if ((string?)row["fingerprint"] != request.Plan.Fingerprint || (string?)row["request_sha256"] != RelationRequestHash(request))
        { throw RelationStale("Cet identifiant de lot a déjà été utilisé avec un autre contenu."); }
        var pending = (int)(long)db.Scalar("SELECT count(*) FROM domenia_v2_relation_journal WHERE exported=0;")!;
        return new(0, checked((int)((long)row["applied"]! + (long)row["already_done"]!)), (long)row["revision"]!, pending,
            "Ce lot a déjà été enregistré ; aucun rejeu. Sa postcondition doit être relue séparément.");
    }

    private static string RelationRequestHash(RelationStoreWrite request) => Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new
    { request.StoreId, request.Plan.Fingerprint, Expected = request.Expected.OrderBy(r => r.StorageKey, StringComparer.Ordinal), request.Items })));

    private static void EnsureRelationWriteSchema(SqliteDatabase db)
    {
        var columns = db.Query("PRAGMA table_info(user_machine_links);").Select(r => (string)r["name"]!).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var name in new[] { "kind", "batch_id", "declarant" })
        { if (!columns.Contains(name)) { db.Script("ALTER TABLE user_machine_links ADD COLUMN " + name + " TEXT;"); } }
        db.Script("CREATE TABLE IF NOT EXISTS domenia_v2_relation_writes(id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,request_sha256 TEXT NOT NULL,revision INTEGER NOT NULL,applied INTEGER NOT NULL,already_done INTEGER NOT NULL);"
            + "CREATE TABLE IF NOT EXISTS domenia_v2_relation_journal(id TEXT PRIMARY KEY,plan_id TEXT NOT NULL,at TEXT NOT NULL,payload TEXT NOT NULL,restores_id TEXT UNIQUE,exported INTEGER NOT NULL DEFAULT 0);"
            + "CREATE INDEX IF NOT EXISTS idx_domenia_v2_relation_journal_at ON domenia_v2_relation_journal(at,id);");
    }

    private static string NewRelationStorageKey(StoredRelation relation, HashSet<string> occupied)
    {
        var primary = RelationRules.ComputerKey(relation.Computer).ToUpperInvariant();
        var key = occupied.Contains(primary) ? primary + "|" + RelationRules.Key(relation) : primary;
        if (key.Length == 0 || key.Length > 1024 || occupied.Contains(key)) { throw RelationStale("Clé physique déjà utilisée ; aucune association écrasée."); }
        return key;
    }

    private static Dictionary<string, object?> RelationValues(StoredRelation r, string key) => new(StringComparer.OrdinalIgnoreCase)
    {
        ["computer_key"] = key, ["user_login"] = r.UserLogin, ["computer"] = r.Computer, ["source"] = r.Source,
        ["observed_at"] = r.When?.ToUniversalTime().ToString("o"), ["details"] = r.Details,
        ["user_guid"] = r.UserGuid?.ToString("D"), ["computer_guid"] = r.ComputerGuid?.ToString("D"), ["user_dn"] = r.UserDn, ["computer_dn"] = r.ComputerDn,
        ["kind"] = RelationRules.KindName(r.Kind), ["batch_id"] = r.BatchId, ["declarant"] = r.Declarant, ["verified_in_ad"] = r.VerifiedInAd ? 1L : 0L,
    };

    private static void WriteRelationRow(SqliteDatabase db, string key, StoredRelation relation, bool update)
    {
        var row = RelationValues(relation, key); var fields = row.Keys.Where(n => n != "computer_key").ToArray();
        // Updating named columns preserves confidence and any D1 extension columns; never INSERT OR REPLACE a legacy row.
        var sql = update ? "UPDATE user_machine_links SET " + string.Join(',', fields.Select((name, i) => name + "=?" + (i + 2))) + " WHERE computer_key=?1;"
            : "INSERT INTO user_machine_links(computer_key," + string.Join(',', fields) + ",confidence) VALUES(?1," + string.Join(',', fields.Select((_, i) => "?" + (i + 2))) + ",0);";
        var changed = db.Execute(sql, new object?[] { key }.Concat(fields.Select(n => row[n])).ToArray());
        if (changed != 1) { throw RelationStale("La ligne attendue n’a pas été modifiée exactement une fois."); }
    }

    private static DomeniaOperationException RelationStale(string detail) => WriteErrors.Refusal(WriteErrors.Stale, detail);
}
