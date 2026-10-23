using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private const string SweepWritesTable = "domenia_v2_sweep_writes";

    public Task<WritePrecheck> CheckRelationSweepsAsync(RelationSweepWrite request, CancellationToken token) => Task.Run(() =>
    {
        ValidateSweepWrite(request); CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return CheckSweepRows(request, EmptySweeps()); }
        using var db = new SqliteDatabase(Path, true, cancellationToken: token); db.Begin(false); CheckIdentity(db, true);
        var check = ExistingSweepWrite(db, request) is not null ? WritePrecheck.Valid("Ce passage est déjà enregistré ; aucun rejeu.")
            : CheckSweepRows(request, ReadRelationSweeps(db, token));
        db.Commit(); return check;
    }, token);

    public async Task<RelationSweepWriteResult> ApplyRelationSweepsAsync(RelationSweepWrite request, CancellationToken token)
    {
        ValidateSweepWrite(request); await writer.WaitAsync(token).ConfigureAwait(false);
        try { return await Task.Run(() => ApplySweeps(request, token), token).ConfigureAwait(false); }
        finally { writer.Release(); }
    }

    private RelationSweepWriteResult ApplySweeps(RelationSweepWrite request, CancellationToken token)
    {
        EnsureReady(); CompatibleDirectoryCache.ValidateLocalPath(Path);
        using var db = new SqliteDatabase(Path, false, cancellationToken: token); CheckIdentity(db, false);
        if (ExistingSweepWrite(db, request) is { } recorded) { return recorded; }
        if (!Table(db, SweepWritesTable)) { lastBackup = Backup(db, token); } else { EnsureBackup(db, token); }
        db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, false);
        if (ExistingSweepWrite(db, request) is { } raced) { db.Commit(); return raced; }
        var check = CheckSweepRows(request, ReadRelationSweeps(db, token));
        if (!check.Current) { throw WriteErrors.Refusal(WriteErrors.Stale, check.Detail); }
        EnsureSweepWriteSchema(db);
        // Capture after additive columns exist, so unchanged original rows retain exactly the same physical fingerprint.
        var before = ReadRelationSweeps(db, token); var occupied = before.Rows.Select(r => r.StorageKey).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var original = before.Rows.ToDictionary(r => r.StorageKey, StringComparer.Ordinal);
        var expected = new Dictionary<string, (RelationSweepUpdate Update, int Attempts, string? Preserved)>(StringComparer.Ordinal);
        var updated = 0; var ignored = 0; var added = 0;
        foreach (var value in request.Updates)
        {
            token.ThrowIfCancellationRequested();
            var old = before.Rows.SingleOrDefault(r => r.ComputerGuid == value.ComputerGuid);
            // Equal timestamps cannot establish the order of two answers either. Keep the existing state and attempt count.
            if (old?.At is { } previous && previous >= value.At) { ignored++; continue; }
            var attempts = old is null ? 1 : (int)Math.Min(int.MaxValue, (long)old.Attempts + 1);
            var key = old?.StorageKey ?? NewSweepKey(value, occupied);
            if (old is null)
            {
                db.Execute("INSERT INTO park_state(computer_key,computer,computer_guid,computer_dn,last_probe,status,user_login,attempts) VALUES(?1,?2,?3,?4,?5,?6,?7,?8);",
                    key, value.Computer, value.ComputerGuid.ToString("D"), value.ComputerDn, Stamp(value.At), value.Status, value.UserLogin, attempts);
                occupied.Add(key); added++;
            }
            else
            {
                db.Execute("UPDATE park_state SET computer=?2,computer_guid=?3,computer_dn=?4,last_probe=?5,status=?6,user_login=?7,attempts=?8 WHERE computer_key=?1;",
                    key, value.Computer, value.ComputerGuid.ToString("D"), value.ComputerDn, Stamp(value.At), value.Status, value.UserLogin, attempts);
            }
            expected.Add(key, (value, attempts, old?.PreservedFingerprint)); updated++;
        }
        var after = ReadRelationSweeps(db, token);
        if (after.Truncated || after.Rejected > 0 || after.Total != before.Total + added || after.Generation != before.Generation
            || after.Rows.GroupBy(r => r.StorageKey, StringComparer.Ordinal).Any(g => g.Count() != 1))
        { throw new InvalidDataException("Relecture du passage non conforme ; transaction annulée."); }
        foreach (var row in after.Rows)
        {
            if (!expected.TryGetValue(row.StorageKey, out var value))
            {
                if (!original.TryGetValue(row.StorageKey, out var unchanged) || unchanged.StorageFingerprint != row.StorageFingerprint)
                { throw new InvalidDataException("Une autre ligne de relevé a été modifiée ; transaction annulée."); }
                continue;
            }
            if (row.ComputerGuid != value.Update.ComputerGuid || row.ComputerDn != value.Update.ComputerDn || row.Computer != value.Update.Computer || row.At != value.Update.At
                || row.Status != value.Update.Status || row.UserLogin != value.Update.UserLogin || row.Attempts != value.Attempts
                || value.Preserved is { } fingerprint && row.PreservedFingerprint != fingerprint)
            { throw new InvalidDataException("Valeurs ou colonnes historiques du relevé modifiées ; transaction annulée."); }
        }
        if (expected.Keys.Any(k => !after.Rows.Any(r => r.StorageKey == k))) { throw new InvalidDataException("Relevé attendu absent ; transaction annulée."); }
        if (updated > 0) { db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;"); }
        var revision = (long)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;")!;
        db.Execute("INSERT INTO domenia_v2_sweep_writes(id,request_sha256,operation,generation,updated,ignored,revision) VALUES(?1,?2,'record',?3,?4,?5,?6);",
            request.BatchId, SweepRequestHash(request), after.Generation, updated, ignored, revision);
        db.Commit();
        return new(updated, ignored, after.Generation, revision, false,
            FrenchText.Count(updated, "passage enregistré et relu", "passages enregistrés et relus") + ", " + FrenchText.Count(ignored, "réponse ancienne ou simultanée ignorée", "réponses anciennes ou simultanées ignorées") + ".");
    }

    private void ValidateSweepWrite(RelationSweepWrite request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.StoreId != StoreId || !WritePlans.IsPlanId(request.BatchId) || request.BatchId == RelationChange.SessionResultId || request.Generation < 0
            || request.Updates.IsDefaultOrEmpty || request.Updates.Length > 50 || request.Updates.Any(r => r is null) || request.Updates.Select(r => r.ComputerGuid).Distinct().Count() != request.Updates.Length)
        { throw new ArgumentException("Passage local invalide, d’une autre base ou supérieur à cinquante postes."); }
        foreach (var value in request.Updates)
        {
            if (value.ComputerGuid == Guid.Empty || value.Computer is not { Length: > 0 and <= 63 } || !value.Computer.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_')
                || value.ComputerDn is not { Length: > 0 and <= 4096 } || value.ComputerDn.Any(char.IsControl) || !InDomain(value.ComputerDn)
                || DistinguishedName.AreEqual(value.ComputerDn, DomainDn) || value.At == DateTimeOffset.MinValue || value.At > clock.GetUtcNow().AddMinutes(2)
                || value.Status is not ("CONFIRME" or "LU" or "REFUSE" or "AUTH_REJETEE" or "DELAI" or "ERREUR" or "PING_MUET")
                || value.UserLogin?.Length > 320 || value.UserLogin?.Any(char.IsControl) == true)
            { throw new ArgumentException("Identité, date, compte ou état de relevé hors contrat."); }
        }
    }

    private static WritePrecheck CheckSweepRows(RelationSweepWrite request, RelationSweepCacheSnapshot snapshot)
    {
        if (snapshot.Truncated || snapshot.Rejected > 0 || snapshot.Rows.Length != snapshot.Total
            || snapshot.Rows.GroupBy(r => r.StorageKey, StringComparer.Ordinal).Any(g => g.Count() > 1))
        { return WritePrecheck.Stale("Mémoire des relevés partielle ou ambiguë ; aucune écriture partielle."); }
        if (snapshot.Generation != request.Generation) { return WritePrecheck.Stale("La mémoire des relevés a été effacée depuis le début de ce passage ; résultat tardif non réintroduit."); }
        var targets = request.Updates.Select(r => r.ComputerGuid).ToHashSet();
        if (snapshot.Rows.Where(r => r.ComputerGuid is { } id && targets.Contains(id)).GroupBy(r => r.ComputerGuid).Any(g => g.Count() > 1))
        { return WritePrecheck.Stale("Plusieurs relevés portent le même GUID de cible ; aucune ligne choisie arbitrairement."); }
        return WritePrecheck.Valid("Mémoire lisible de la même génération ; anciennes lignes sans GUID conservées.");
    }

    private static string SweepRequestHash(RelationSweepWrite request) => Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(request)));

    private static RelationSweepWriteResult? ExistingSweepWrite(SqliteDatabase db, RelationSweepWrite request)
    {
        if (!Table(db, SweepWritesTable)) { return null; }
        var rows = db.Query("SELECT request_sha256,operation,generation,updated,ignored,revision FROM domenia_v2_sweep_writes WHERE id=?1 LIMIT 2;", request.BatchId);
        if (rows.Count == 0) { return null; }
        if (rows.Count != 1 || (string?)rows[0]["request_sha256"] != SweepRequestHash(request) || (string?)rows[0]["operation"] != "record")
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Identifiant de passage déjà utilisé pour un autre contenu ; aucun rejeu."); }
        var row = rows[0];
        if (row["generation"] is not long generation || generation != request.Generation || row["updated"] is not long updated || updated is < 0 or > 50
            || row["ignored"] is not long ignored || ignored is < 0 or > 50 || updated + ignored != request.Updates.Length
            || row["revision"] is not long revision || revision < 0)
        { throw new InvalidDataException("Reçu de passage illisible ; aucun rejeu."); }
        return new((int)updated, (int)ignored, generation, revision, true, "Passage déjà enregistré ; reçu relu, aucune nouvelle tentative comptée.");
    }

    private static void EnsureSweepWriteSchema(SqliteDatabase db)
    {
        var columns = db.Query("PRAGMA table_info(park_state);").Select(r => (string)r["name"]!).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!columns.Contains("computer_guid")) { db.Execute("ALTER TABLE park_state ADD COLUMN computer_guid TEXT;"); }
        if (!columns.Contains("computer_dn")) { db.Execute("ALTER TABLE park_state ADD COLUMN computer_dn TEXT;"); }
        if (!Table(db, "domenia_v2_sweep_state"))
        {
            db.Execute("CREATE TABLE domenia_v2_sweep_state(id INTEGER PRIMARY KEY CHECK(id=1),generation INTEGER NOT NULL CHECK(generation>=0));");
            db.Execute("INSERT INTO domenia_v2_sweep_state(id,generation) VALUES(1,0);");
        }
        db.Execute("CREATE TABLE IF NOT EXISTS domenia_v2_sweep_writes(id TEXT PRIMARY KEY,request_sha256 TEXT NOT NULL,operation TEXT NOT NULL,generation INTEGER NOT NULL,updated INTEGER NOT NULL,ignored INTEGER NOT NULL,revision INTEGER NOT NULL);");
    }

    private static string NewSweepKey(RelationSweepUpdate value, HashSet<string> occupied)
    {
        if (!occupied.Contains(value.Computer)) { return value.Computer; }
        var prefix = value.Computer + "|" + value.ComputerGuid.ToString("D"); var key = prefix; var suffix = 0;
        while (occupied.Contains(key)) { key = prefix + "|" + (++suffix).ToString(System.Globalization.CultureInfo.InvariantCulture); }
        return key;
    }
}
