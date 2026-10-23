using System.Globalization;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private sealed record WriterResumeProof(string PlanId, string PlanFingerprint, string StoreId, string DomainDn, string AfterFingerprint, int Replayed)
    {
        public bool IdentityOnly { get; init; }
        public int Retained { get; init; }
    }
    private sealed record ResumeSelection(bool IdentityOnly, int Replay, int Examine)
    {
        internal string Value => (IdentityOnly ? "identity" : "snapshot") + "|" + Replay.ToString(CultureInfo.InvariantCulture) + "|" + Examine.ToString(CultureInfo.InvariantCulture);
    }
    internal async Task<WritePlanDraft> PrepareWriterResumeAsync(CancellationToken token)
    {
        var snapshot = await InspectLocalStoreAsync(false, false, token).ConfigureAwait(false);
        var draft = StorageWritePlans.WriterResumeDraft(snapshot);
        var state = WriterStateFingerprint();
        HeldWrite[] held; lock (Health.Gate) { held = [.. Health.Held]; }
        string? qualified = null;
        if (held.Any(x => x.Before.Length == 64)) { qualified = await TryWriteSnapshotAsync(token).ConfigureAwait(false); }
        var identityOnly = qualified is null;
        var before = qualified ?? await Task.Run(() => ReadWriterIdentity(token), token).ConfigureAwait(false);
        var replay = identityOnly ? 0 : held.Count(x => x.Before == before);
        var selection = new ResumeSelection(identityOnly, replay, held.Length - replay);
        if (state != WriterStateFingerprint()) { throw WriteErrors.Refusal(WriteErrors.Stale, "File d’enregistrement modifiée pendant la préparation."); }
        var summary = FrenchText.Count(replay, "lot relu sera enregistré", "lots relus seront enregistrés") + ". "
            + FrenchText.Count(selection.Examine, "lot restera en mémoire pour examen", "lots resteront en mémoire pour examen")
            + ", sans rejeu et sans effacement. Les nouveaux enregistrements seront de nouveau admis.";
        return draft with
        {
            Summary = summary,
            Risks = draft.Risks.Add(new(selection.Examine > 0 ? Tone.Warn : Tone.Info,
                "Seuls les lots dont la base d’origine est encore identique sont réessayés. Les autres restent dans cette session et seront perdus à sa fermeture ; ce geste ne les efface pas.")),
            Changes = draft.Changes
                .Add(new("local.writerState", "File et défauts observés", WriteChangeKind.Replace, state, "Reprise de cette file", state, null))
                .Add(new("local.resumeBase", identityOnly ? "Identité de la base, sans rejeu" : "Base d’origine des lots rejouables", WriteChangeKind.Replace, before, "État revérifié à l’envoi", before, null))
                .Add(new("local.resumeSelection", "Sort des données en attente", WriteChangeKind.Replace, null, summary, null, selection.Value)),
        };
    }
    internal Task<WritePrecheck> CheckWriterResumeAsync(WritePlan plan, CancellationToken token) => Task.Run(() =>
    {
        ValidateWriterResume(plan, true);
        if (WriterStateFingerprint() != WriterAnchor(plan, "local.writerState")) { return WritePrecheck.Stale("File ou état de l’écrivain modifié depuis le plan."); }
        if (ResumeBase(plan, token) != WriterAnchor(plan, "local.resumeBase")) { return WritePrecheck.Stale("Base modifiée depuis le plan de reprise ; lots conservés sans rejeu."); }
        return WritePrecheck.Valid("File et périmètre confirmés ; seuls les lots annoncés réessayables seront envoyés. Les lots pour examen restent conservés.");
    }, token);

    internal async Task<WriteOutcome> ApplyWriterResumeAsync(WritePlan plan, CancellationToken token)
    {
        ValidateWriterResume(plan, true);
        var health = Health;
        await health.Sending.WaitAsync(token).ConfigureAwait(false);
        try
        {
            using (var db = new SqliteDatabase(Path, true, cancellationToken: token))
            {
                CheckIdentity(db, true);
                if ((long)db.Scalar("SELECT count(*) FROM sqlite_master WHERE type='trigger';")! != 0)
                { throw WriteErrors.Refusal(WriteErrors.Stale, "Déclencheur SQLite non qualifié ; aucun lot repris."); }
                if (ReadWriterResumeProof(db, plan) is not null) { return new(WriteResult.NoChange, "Reprise déjà enregistrée ; aucun lot rejoué."); }
            }
            if (WriterStateFingerprint() != WriterAnchor(plan, "local.writerState")) { throw WriteErrors.Refusal(WriteErrors.Stale, "File modifiée depuis la confirmation."); }
            HeldWrite[] pending;
            lock (health.Gate)
            {
                if (!health.Suspended && health.Held.Count == 0 || health.Active || health.Waiting > 0) { throw WriteErrors.Refusal(WriteErrors.Stale, "Écrivain actif ou non suspendu."); }
                health.Suspended = true; health.Active = true; health.Version++; pending = [.. health.Held];
            }
            CheckWriterSpace(0);
            using var budget = StorageWriteBudgetScope.Enter(Path, () => CheckWriterSpace(0));
            var selection = WriterSelection(plan);
            var initial = WriterAnchor(plan, "local.resumeBase");
            var current = await Task.Run(() => ResumeBase(plan, token), token).ConfigureAwait(false);
            var eligible = pending.Where(x => !selection.IdentityOnly && x.Before == initial).ToArray();
            if (initial != current || eligible.Length != selection.Replay || pending.Length - eligible.Length != selection.Examine)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "L’état de la base ou le sort des lots a changé ; aucun rejeu. Les données restent en mémoire pour examen."); }
            var replayed = 0;
            foreach (var job in eligible)
            {
                token.ThrowIfCancellationRequested();
                var expected = current;
                using var replay = StorageReplayScope.Enter(Path, db =>
                {
                    CheckIdentity(db, false); CheckWriterSpace(0);
                    if (StorageWriteSnapshot.Read(db, token) != expected)
                    { throw WriteErrors.Refusal(WriteErrors.Stale, "La base a changé avant le lot repris ; aucun écrasement."); }
                }, db => StorageWriteSnapshot.Read(db, token));
                await job.Replay(token).ConfigureAwait(false);
                var after = replay.AfterFingerprint ?? await Task.Run(() => ReadWriteSnapshot(token), token).ConfigureAwait(false);
                if (replay.AfterFingerprint is null && after != expected) { throw new InvalidDataException("Lot repris sans preuve de transaction ; examen nécessaire."); }
                current = after; replayed++;
                lock (health.Gate) { health.Held.RemoveAll(x => x.Id == job.Id); health.Version++; }
            }
            await writer.WaitAsync(token).ConfigureAwait(false);
            try
            {
                await Task.Run(() =>
                {
                    CheckWriterSpace(0);
                    using var db = new SqliteDatabase(Path, false, cancellationToken: token);
                    db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, false);
                    if ((long)db.Scalar("SELECT count(*) FROM sqlite_master WHERE type='trigger';")! != 0)
                    { throw WriteErrors.Refusal(WriteErrors.Stale, "Déclencheur SQLite non qualifié ; aucun reçu de reprise envoyé."); }
                    if ((selection.IdentityOnly ? WriterIdentity(db) : StorageWriteSnapshot.Read(db, token)) != current)
                    { throw WriteErrors.Refusal(WriteErrors.Stale, "Base modifiée avant le reçu de reprise."); }
                    var proof = new WriterResumeProof(plan.Id, plan.Fingerprint, StoreId, DomainDn, current, replayed)
                    { IdentityOnly = selection.IdentityOnly, Retained = selection.Examine };
                    var payload = JsonSerializer.Serialize(proof, Json);
                    db.Script("CREATE TABLE IF NOT EXISTS domenia_v2_writer_receipts(plan_id TEXT PRIMARY KEY,sha256 TEXT NOT NULL,payload TEXT NOT NULL);");
                    db.Execute("INSERT INTO domenia_v2_writer_receipts(plan_id,sha256,payload) VALUES(?1,?2,?3);", plan.Id, BackupPreferencesRules.Sha256(payload), payload);
                    db.Commit();
                    if (ReadWriterResumeProof(db, plan) != proof) { throw new InvalidDataException("Reçu de reprise non relu."); }
                }, token).ConfigureAwait(false);
            }
            finally { writer.Release(); }
            lock (health.Gate)
            {
                health.Suspended = false; health.Failures = 0;
                health.Fault = selection.Examine > 0 ? FrenchText.Count(selection.Examine, "lot conservé pour examen", "lots conservés pour examen") + " ; aucune écriture ni suppression de ces données." : null;
                health.SavedAt = clock.GetUtcNow(); health.Version++;
            }
            return new(WriteResult.Applied, replayed.ToString(CultureInfo.InvariantCulture) + " lots collectés sauvegardés et relus ; "
                + selection.Examine.ToString(CultureInfo.InvariantCulture) + " lots conservés en mémoire pour examen, sans rejeu. Écrivain réarmé. Aucun plan opérateur rejoué.");
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            lock (health.Gate)
            {
                health.Suspended = true; health.Failures++; health.Fault = "Reprise interrompue : " + ex.Message;
                if (ex is DomeniaOperationException || ex is SqliteStoreException { Busy: true }) { health.Conflicts++; }
                health.Version++;
            }
            throw;
        }
        finally
        {
            lock (health.Gate) { health.Active = false; health.ActiveBytes = 0; health.Version++; }
            health.Sending.Release();
        }
    }
    internal Task<WriteVerification> VerifyWriterResumeAsync(WritePlan plan, CancellationToken token) => Task.Run(() =>
    {
        ValidateWriterResume(plan, false);
        if (!File.Exists(Path)) { return new WriteVerification(VerificationState.Unknown, "Base absente ; reçu de reprise inaccessible."); }
        using var db = new SqliteDatabase(Path, true, cancellationToken: token);
        db.Begin(false); CheckIdentity(db, true);
        var proof = ReadWriterResumeProof(db, plan);
        if (proof is null) { return new WriteVerification(VerificationState.Unknown, "Aucun reçu de reprise terminé ; aucun rejeu implicite."); }
        return (proof.IdentityOnly ? WriterIdentity(db) : StorageWriteSnapshot.Read(db, token)) == proof.AfterFingerprint
            ? new WriteVerification(VerificationState.Verified, proof.IdentityOnly
                ? "Réarmement enregistré et relu ; aucun lot rejoué. " + proof.Retained.ToString(CultureInfo.InvariantCulture) + " lots étaient conservés pour examen dans la session d’origine ; ce reçu ne prouve pas leur conservation après fermeture."
                : "État après reprise relu dans la base d’origine ; reçu durable conforme. " + proof.Retained.ToString(CultureInfo.InvariantCulture) + " lots non rejoués restaient dans la session d’origine.")
            : new WriteVerification(VerificationState.Mismatch, "Reprise enregistrée mais base modifiée depuis ; état courant différent.");
    }, token);
    private void ValidateWriterResume(WritePlan plan, bool current)
    {
        if (plan.Kind != StorageWritePlans.WriterResume || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText || !WritePlans.IsPlanId(plan.Id)
            || !WritePlans.IsIntact(plan) || plan.Target.Kind != StorageWritePlans.TargetKind || plan.Target.Dn != Path
            || plan.Target.ObjectGuid != StorageWritePlans.StoreGuid(StoreId) || current && plan.ExpiresAt <= clock.GetUtcNow()
            || plan.Changes.Length != 4 || plan.Changes.SingleOrDefault(x => x.Attribute == "writer.state")?.AfterValue != "active")
        { throw new InvalidDataException("Plan de reprise de l’écrivain invalide, expiré ou d’une autre base."); }
        _ = WriterSelection(plan);
        foreach (var key in new[] { "local.writerState", "local.resumeBase" })
        {
            var value = plan.Changes.SingleOrDefault(x => x.Attribute == key)?.BeforeValue;
            if (value is not { Length: 64 } || value.Any(c => !char.IsAsciiHexDigit(c))) { throw new InvalidDataException("Empreinte de reprise de l’écrivain invalide."); }
        }
    }
    private static ResumeSelection WriterSelection(WritePlan plan)
    {
        var text = plan.Changes.SingleOrDefault(x => x.Attribute == "local.resumeSelection")?.AfterValue;
        var parts = text?.Split('|');
        if (parts is not { Length: 3 } || parts[0] is not ("snapshot" or "identity")
            || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var replay)
            || !int.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out var examine)
            || replay < 0 || examine < 0 || replay + (long)examine > 32 || parts[0] == "identity" && replay != 0)
        { throw new InvalidDataException("Sélection de reprise incohérente."); }
        return new(parts[0] == "identity", replay, examine);
    }
    private string ResumeBase(WritePlan plan, CancellationToken token) => WriterSelection(plan).IdentityOnly ? ReadWriterIdentity(token) : ReadWriteSnapshot(token);
    private string ReadWriterIdentity(CancellationToken token)
    {
        using var db = new SqliteDatabase(Path, true, cancellationToken: token);
        db.Begin(false); return WriterIdentity(db);
    }
    private string WriterIdentity(SqliteDatabase db)
    {
        CheckIdentity(db, false);
        return BackupPreferencesRules.Sha256(JsonSerializer.Serialize(db.Query("SELECT store_id,domain_dn,revision FROM domenia_store_state WHERE id=1;"), Json));
    }
    private static string WriterAnchor(WritePlan plan, string key) => plan.Changes.Single(x => x.Attribute == key).BeforeValue!;
    private WriterResumeProof? ReadWriterResumeProof(SqliteDatabase db, WritePlan plan)
    {
        if (!Table(db, "domenia_v2_writer_receipts")) { return null; }
        var row = db.Query("SELECT sha256,CASE WHEN length(payload)<=4096 THEN payload ELSE NULL END AS payload FROM domenia_v2_writer_receipts WHERE plan_id=?1;", plan.Id).SingleOrDefault();
        if (row is null) { return null; }
        var text = row["payload"] as string ?? throw new InvalidDataException("Reçu de reprise trop volumineux.");
        if (BackupPreferencesRules.Sha256(text) != row["sha256"] as string) { throw new InvalidDataException("Reçu de reprise altéré."); }
        var proof = JsonSerializer.Deserialize<WriterResumeProof>(text, Json) ?? throw new InvalidDataException("Reçu de reprise illisible.");
        if (proof.PlanId != plan.Id || proof.PlanFingerprint != plan.Fingerprint || proof.StoreId != StoreId || proof.DomainDn != DomainDn
            || proof.Replayed is < 0 or > 32 || proof.Retained is < 0 or > 32 || proof.Replayed + proof.Retained > 32
            || proof.IdentityOnly != WriterSelection(plan).IdentityOnly || proof.Replayed != WriterSelection(plan).Replay
            || proof.Retained != WriterSelection(plan).Examine || proof.AfterFingerprint.Length != 64)
        { throw new InvalidDataException("Reçu de reprise étranger ou incohérent."); }
        return proof;
    }
}
