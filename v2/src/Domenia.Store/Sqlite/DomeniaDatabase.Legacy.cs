using System.Globalization;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private const string LegacyStateAttribute = "local.legacyState";
    private sealed record LegacyProof(string PlanId, string PlanFingerprint, string StoreId, string DomainDn,
        long Revision, long Imported, string Marker, string AfterFingerprint, DatabaseBackup Backup);

    internal async Task<WritePlanDraft> PrepareStorageLegacyAsync(IReadOnlyList<string> roots, string domain, string previewFingerprint, CancellationToken token)
    {
        var expectedDomain = LegacyRules.DomainOf(DomainDn)!;
        if (!domain.Trim().TrimEnd('.').Equals(expectedDomain, StringComparison.OrdinalIgnoreCase)
            && !domain.Equals(DomainDn, StringComparison.OrdinalIgnoreCase))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Domaine de la reprise différent de celui de la base."); }
        var snapshot = await InspectLocalStoreAsync(false, false, token).ConfigureAwait(false);
        StorageWritePlans.EnsureWritable(snapshot);
        return await Task.Run(() =>
        {
            using var sources = LegacyImportFiles.Read(roots, token, clock.LocalTimeZone);
            using var db = new SqliteDatabase(Path, true, cancellationToken: token);
            db.Begin(false); CheckIdentity(db, true);
            var inventory = ReadLegacyInventory(db, token);
            snapshot = WithLegacySources(snapshot, sources, inventory);
            var preview = StorageViewBuilder.LegacySimulation(snapshot, domain, clock.LocalTimeZone);
            var draft = StorageWritePlans.LegacyImportDraft(snapshot, domain, previewFingerprint, preview.Fingerprint);
            return draft with { Changes = draft.Changes.Add(new(LegacyStateAttribute, "Contenu des tables historiques", WriteChangeKind.Replace,
                inventory.Fingerprint, "Même contenu avant reprise", inventory.Fingerprint, null)) };
        }, token).ConfigureAwait(false);
    }

    internal Task<WritePrecheck> CheckStorageLegacyAsync(IReadOnlyList<string> roots, WritePlan plan, CancellationToken token) => Task.Run(() =>
    {
        ValidateLegacyPlan(plan, true);
        using var sources = LegacyImportFiles.Read(roots, token, clock.LocalTimeZone);
        using var db = new SqliteDatabase(Path, true, cancellationToken: token);
        db.Begin(false); CheckIdentity(db, true);
        if (ReadLegacyProof(db, plan) is not null) { return WritePrecheck.Stale("Reprise déjà validée ; relisez son reçu sans la rejouer."); }
        var inventory = ReadLegacyInventory(db, token);
        return MatchesLegacyPlan(plan, inventory, sources) ? WritePrecheck.Valid("Sources verrouillées, empreintes et tables cibles relues.")
            : WritePrecheck.Stale("Sources historiques ou base modifiées depuis le plan ; refaites la simulation.");
    }, token);

    internal async Task<WriteOutcome> ApplyStorageLegacyAsync(IReadOnlyList<string> roots, WritePlan plan, CancellationToken token)
    {
        ValidateLegacyPlan(plan, true);
        await writer.WaitAsync(token).ConfigureAwait(false);
        try { return await Task.Run(() => ExecuteStorageLegacy(roots, plan, token), token).ConfigureAwait(false); }
        finally { writer.Release(); }
    }

    private WriteOutcome ExecuteStorageLegacy(IReadOnlyList<string> roots, WritePlan plan, CancellationToken token)
    {
        ValidateLegacyPlan(plan, true); CompatibleDirectoryCache.ValidateLocalPath(Path);
        using var sources = LegacyImportFiles.Read(roots, token, clock.LocalTimeZone);
        using (var read = new SqliteDatabase(Path, true, cancellationToken: token))
        {
            read.Begin(false); CheckIdentity(read, true);
            if (ReadLegacyProof(read, plan) is not null) { return new(WriteResult.NoChange, "Reprise déjà validée ; aucun rejeu."); }
            if (!MatchesLegacyPlan(plan, ReadLegacyInventory(read, token), sources))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Sources historiques ou base modifiées depuis le plan."); }
        }
        _ = Initialize(token);
        using var db = new SqliteDatabase(Path, false, cancellationToken: token);
        CheckIdentity(db, false);
        var backup = lastBackup = Backup(db, token);
        db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, false);
        var before = ReadLegacyInventory(db, token);
        if (!MatchesLegacyPlan(plan, before, sources)) { throw WriteErrors.Refusal(WriteErrors.Stale, "Sources ou base modifiées pendant la confirmation ; aucune reprise."); }
        using (var saved = new SqliteDatabase(backup.Path, true, cancellationToken: token))
        {
            CheckIdentity(saved, true);
            if (ReadLegacyInventory(saved, token).Fingerprint != before.Fingerprint)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Sauvegarde différente du contenu confirmé ; aucune reprise."); }
        }
        if ((long)db.Scalar("SELECT count(*) FROM sqlite_master WHERE type='trigger';")! != 0)
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Déclencheur SQLite non qualifié ; reprise refusée."); }
        long imported = 0;
        foreach (var file in sources.Files)
        {
            long count = 0;
            foreach (var row in file.Rows)
            {
                token.ThrowIfCancellationRequested();
                if (row.Kind == "Liens" && before.LinkedComputers.Contains(row.Key)) { continue; }
                InsertLegacyRow(db, row); count++;
            }
            var planned = plan.Changes.SingleOrDefault(x => x.Attribute == "legacy.file." + file.Info.Kind)?.AfterValue ?? "0";
            if (count.ToString(CultureInfo.InvariantCulture) != planned) { throw new InvalidDataException("Quantité historique différente du plan ; transaction annulée."); }
            imported += count;
        }
        if (imported < 1) { throw new InvalidDataException("Aucune ligne historique ajoutée ; transaction annulée."); }
        var now = clock.GetUtcNow().ToString("O", CultureInfo.InvariantCulture);
        db.Execute("INSERT INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('legacy_import','legacy_import',?1,0,?2,?3,?4);", DomainDn, now, imported, "marker=" + sources.Marker);
        var revision = checked(before.Revision + 1);
        db.Execute("UPDATE domenia_store_state SET revision=?1 WHERE id=1;", revision);
        var after = ReadLegacyInventory(db, token);
        foreach (var file in sources.Files)
        {
            var table = LegacyRules.FileTarget(file.Info.Kind)!;
            var expected = long.Parse(plan.Changes.SingleOrDefault(x => x.Attribute == "legacy.file." + file.Info.Kind)?.AfterValue ?? "0", CultureInfo.InvariantCulture);
            if (after.Counts[table] != before.Counts[table] + expected) { throw new InvalidDataException("Relecture des lignes importées incohérente."); }
        }
        if (after.Revision != revision || after.Marker != sources.Marker) { throw new InvalidDataException("Marqueur historique non relu."); }
        var proof = new LegacyProof(plan.Id, plan.Fingerprint, StoreId, DomainDn, revision, imported, sources.Marker, after.Fingerprint, backup);
        SaveLegacyProof(db, proof);
        if (ReadLegacyProof(db, plan) != proof) { throw new InvalidDataException("Reçu historique non relu avant commit."); }
        db.Commit();
        using var reread = new SqliteDatabase(Path, true, cancellationToken: token);
        reread.Begin(false); CheckIdentity(reread, false);
        if (ReadLegacyProof(reread, plan) != proof || ReadLegacyInventory(reread, token).Fingerprint != proof.AfterFingerprint)
        { throw new InvalidDataException("Reprise validée mais contenu modifié avant sa relecture ; consultez le reçu."); }
        return new(WriteResult.Applied, imported.ToString(CultureInfo.InvariantCulture) + " lignes historiques reprises et relues ; sauvegarde SHA-256 " + backup.Sha256 + ".");
    }

    internal Task<WriteVerification> VerifyStorageLegacyAsync(WritePlan plan, CancellationToken token) => Task.Run(() =>
    {
        ValidateLegacyPlan(plan, false);
        if (!File.Exists(Path)) { return new WriteVerification(VerificationState.Unknown, "Base absente ; preuve historique inaccessible."); }
        using var db = new SqliteDatabase(Path, true, cancellationToken: token);
        db.Begin(false); CheckIdentity(db, true);
        var proof = ReadLegacyProof(db, plan);
        if (proof is null) { return new WriteVerification(VerificationState.Unknown, "Aucune reprise validée ; aucun rejeu automatique."); }
        var current = ReadLegacyInventory(db, token);
        if (!File.Exists(proof.Backup.Path) || BackupFileHash(proof.Backup.Path) != proof.Backup.Sha256)
        { return new WriteVerification(VerificationState.Mismatch, "Reprise enregistrée mais sauvegarde absente ou altérée."); }
        return current.Revision == proof.Revision && current.Fingerprint == proof.AfterFingerprint && current.Marker == proof.Marker
            ? new WriteVerification(VerificationState.Verified, "Données importées, marqueur et sauvegarde relus ; preuve durable conforme.")
            : new WriteVerification(VerificationState.Mismatch, "Reprise enregistrée ; contenu modifié depuis son reçu.");
    }, token);

    private void ValidateLegacyPlan(WritePlan plan, bool current)
    {
        if (plan.Kind != StorageWritePlans.LegacyImport || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText || !WritePlans.IsPlanId(plan.Id)
            || !WritePlans.IsIntact(plan) || plan.Target.Kind != StorageWritePlans.TargetKind || plan.Target.Dn != Path
            || plan.Target.ObjectGuid != StorageWritePlans.StoreGuid(StoreId) || current && plan.ExpiresAt <= clock.GetUtcNow()
            || !plan.Confirmation.TypedNameRequired || plan.Confirmation.TypedName != DomainDn)
        { throw new InvalidDataException("Plan de reprise historique invalide, expiré ou d’une autre base."); }
        var anchor = plan.Changes.SingleOrDefault(x => x.Attribute == LegacyStateAttribute)?.BeforeValue;
        var marker = plan.Changes.SingleOrDefault(x => x.Attribute == "legacy.marker")?.AfterValue;
        var revision = plan.Changes.SingleOrDefault(x => x.Attribute == "revision");
        static bool Hash(string? value) => value is { Length: 64 } && value.All(char.IsAsciiHexDigit);
        if (!Hash(anchor) || !Hash(marker) || revision is null || !long.TryParse(revision.BeforeValue, NumberStyles.None, CultureInfo.InvariantCulture, out var before)
            || before < 0 || before == long.MaxValue || revision.AfterValue != (before + 1).ToString(CultureInfo.InvariantCulture)
            || plan.Changes.Select(x => x.Attribute).Distinct(StringComparer.Ordinal).Count() != plan.Changes.Length
            || plan.Changes.Any(x => x.Attribute is not (LegacyStateAttribute or "legacy.marker" or "revision") && !LegacyRules.FileKinds.Any(k => x.Attribute == "legacy.file." + k.Kind))
            || !plan.Changes.Any(x => x.Attribute.StartsWith("legacy.file.", StringComparison.Ordinal))
            || plan.Changes.Where(x => x.Attribute.StartsWith("legacy.file.", StringComparison.Ordinal)).Any(x => !long.TryParse(x.AfterValue, NumberStyles.None, CultureInfo.InvariantCulture, out var count) || count is < 1 or > LegacyRules.MaxRows))
        { throw new InvalidDataException("Empreinte, quantités ou marqueur du plan historique invalides."); }
    }
    private bool MatchesLegacyPlan(WritePlan plan, LegacyInventory inventory, LegacyImportFiles sources)
    {
        if (inventory.Marker is not null || inventory.Revision.ToString(CultureInfo.InvariantCulture) != plan.Changes.Single(x => x.Attribute == "revision").BeforeValue
            || inventory.Fingerprint != plan.Changes.Single(x => x.Attribute == LegacyStateAttribute).BeforeValue
            || sources.Marker != plan.Changes.Single(x => x.Attribute == "legacy.marker").AfterValue) { return false; }
        var source = new LegacySource(true, Path, DomainDn, clock.GetUtcNow(), null, [], [.. sources.Files.Select(x => x.Info)], inventory.Counts, sources.Marker, null, null);
        var rules = LegacyRules.Plan(source, DomainDn);
        return rules.Allowed && rules.Blockers.IsEmpty;
    }
    private static void SaveLegacyProof(SqliteDatabase db, LegacyProof proof)
    {
        db.Script("CREATE TABLE IF NOT EXISTS domenia_v2_legacy_receipts(plan_id TEXT PRIMARY KEY,sha256 TEXT NOT NULL,payload TEXT NOT NULL);");
        var payload = JsonSerializer.Serialize(proof, Json);
        db.Execute("INSERT INTO domenia_v2_legacy_receipts(plan_id,sha256,payload) VALUES(?1,?2,?3);", proof.PlanId, BackupPreferencesRules.Sha256(payload), payload);
    }
    private LegacyProof? ReadLegacyProof(SqliteDatabase db, WritePlan plan)
    {
        if (!Table(db, "domenia_v2_legacy_receipts")) { return null; }
        var row = db.Query("SELECT sha256,CASE WHEN length(payload)<=16384 THEN payload ELSE NULL END AS payload FROM domenia_v2_legacy_receipts WHERE plan_id=?1;", plan.Id).SingleOrDefault();
        if (row is null) { return null; }
        var payload = row["payload"] as string ?? throw new InvalidDataException("Reçu historique trop volumineux.");
        if (BackupPreferencesRules.Sha256(payload) != row["sha256"] as string) { throw new InvalidDataException("Reçu historique altéré."); }
        var proof = JsonSerializer.Deserialize<LegacyProof>(payload, Json) ?? throw new InvalidDataException("Reçu historique illisible.");
        if (proof.PlanId != plan.Id || proof.PlanFingerprint != plan.Fingerprint || proof.StoreId != StoreId || proof.DomainDn != DomainDn
            || proof.Revision < 1 || proof.Imported < 1 || proof.Backup.Sha256.Length != 64 || proof.AfterFingerprint.Length != 64
            || proof.Marker != plan.Changes.Single(x => x.Attribute == "legacy.marker").AfterValue || System.IO.Path.GetDirectoryName(proof.Backup.Path) != BackupFolder)
        { throw new InvalidDataException("Preuve historique d’une autre base ou incohérente."); }
        return proof;
    }
}
