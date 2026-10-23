using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private sealed record StorageBackupProof(string PlanId, string PlanFingerprint, string StoreId, string DomainDn,
        LocalStoreBackup Backup, string? Destination, bool Published, bool Retired);
    private sealed record StorageBackupEnvelope(string Sha256, string Json);
    private string BackupFolder => System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Path)!, "Backups");
    private string BackupReceiptFolder => System.IO.Path.Combine(BackupFolder, ".receipts");
    private static string BackupRaw(WritePlan plan, string key) => plan.Changes.Single(x => x.Attribute == key).AfterValue
        ?? throw new InvalidDataException("Valeur du plan de sauvegarde absente.");
    private string BackupReceiptPath(string id) => System.IO.Path.Combine(BackupReceiptFolder, id + ".json");

    public async Task<WritePlanDraft> PrepareStorageBackupAsync(StoragePolicy policy, string annex, string series, string? destination, CancellationToken cancellationToken)
    {
        if (StoragePolicyRules.Problem(policy) is { } problem) { throw new ArgumentException(problem, nameof(policy)); }
        var store = await InspectLocalStoreAsync(false, false, cancellationToken).ConfigureAwait(false);
        StorageWritePlans.EnsureWritable(store);
        var canonical = BackupPreferencesRules.Bind(annex, "", clock.GetUtcNow()).Json;
        if (canonical != annex) { throw new InvalidDataException("L’annexe doit contenir uniquement les préférences approuvées, dans leur format canonique."); }
        var draft = destination is null
            ? StorageWritePlans.BackupDraft(store, policy, annex, clock.GetUtcNow(), clock.LocalTimeZone, series)
            : StorageWritePlans.BackupCopyDraft(store, destination, policy, annex, clock.GetUtcNow(), clock.LocalTimeZone);
        var previous = draft.Changes.Single(x => x.Attribute == "backup.file").AfterValue!;
        var file = previous[..^3] + "-" + WritePlans.NewId()[..12] + ".db";
        var changes = draft.Changes.Select(x => x with
        {
            AfterValue = x.Attribute == "backup.file" ? file : x.AfterValue,
            After = x.After?.Replace(previous, file, StringComparison.Ordinal).Replace(previous[..^3] + ".preferences.json", file[..^3] + ".preferences.json", StringComparison.Ordinal),
        }).ToImmutableArray();
        changes = changes.Add(new("backup.revision", "Révision relue avant copie", WriteChangeKind.Replace, store.Revision.ToString(CultureInfo.InvariantCulture), "Même révision dans la sauvegarde", null, store.Revision.ToString(CultureInfo.InvariantCulture)));
        if (destination is not null)
        {
            var target = System.IO.Path.GetFullPath(destination.Trim());
            ValidateBackupDestination(target);
            var hash = await Task.Run(() => File.Exists(target) ? BackupFileHash(target) : "absent", cancellationToken).ConfigureAwait(false);
            changes = changes.Add(new("backup.destinationBefore", "Fichier cible avant publication", WriteChangeKind.Replace, hash == "absent" ? "Absent" : "Fichier existant identifié par SHA-256", "Copie vérifiée ; ancien fichier conservé s’il existe", null, hash));
        }
        var risks = draft.Risks.Add(new(Tone.Info, "Les copies sorties de la rotation sont conservées dans Backups/Retired ; leur suppression définitive reste manuelle."));
        return draft with { Changes = changes, Risks = risks };
    }

    public Task<WritePrecheck> CheckStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken) => Task.Run(() =>
    {
        ValidateStorageBackupPlan(plan, requireCurrent: true);
        if (!File.Exists(Path)) { return WritePrecheck.Stale("Base absente ; aucune base de remplacement créée."); }
        using var db = new SqliteDatabase(Path, true, cancellationToken: cancellationToken);
        db.Begin(false); CheckIdentity(db, true);
        var current = Inspect(db).Revision.ToString(CultureInfo.InvariantCulture) == BackupRaw(plan, "backup.revision");
        db.Commit();
        if (!current) { return WritePrecheck.Stale("La base a changé depuis le plan de sauvegarde ; préparez-le de nouveau."); }
        if (ReadStorageBackupProof(plan.Id) is not null || File.Exists(BackupReceiptPath(plan.Id) + ".intent"))
        { return WritePrecheck.Stale("Cette sauvegarde a déjà été envoyée ; relisez son reçu sans la rejouer."); }
        if (plan.Kind == StorageWritePlans.BackupCopy && !BackupDestinationMatches(plan))
        { return WritePrecheck.Stale("Le fichier cible a changé depuis la confirmation ; aucune publication."); }
        return WritePrecheck.Valid("Base, révision et destination relues ; aucune copie lancée.");
    }, cancellationToken);

    public async Task<WriteOutcome> ApplyStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ValidateStorageBackupPlan(plan, requireCurrent: true);
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await Task.Run(() => ExecuteStorageBackup(plan, cancellationToken), cancellationToken).ConfigureAwait(false); }
        finally { writer.Release(); }
    }

    private WriteOutcome ExecuteStorageBackup(WritePlan plan, CancellationToken token)
    {
        ValidateStorageBackupPlan(plan, requireCurrent: true);
        var previous = ReadStorageBackupProof(plan.Id);
        if (previous is not null)
        {
            if (previous.PlanFingerprint != plan.Fingerprint) { throw new InvalidDataException("Identifiant de sauvegarde déjà utilisé pour un autre plan."); }
            return new(WriteResult.NoChange, "Sauvegarde déjà enregistrée ; aucun rejeu. Utilisez la relecture du reçu.");
        }
        if (File.Exists(BackupReceiptPath(plan.Id) + ".intent")) { throw new IOException("Sauvegarde précédemment envoyée sans preuve finale ; aucun rejeu automatique."); }
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { throw WriteErrors.Refusal(WriteErrors.Stale, "Base absente ; aucune création pour la sauvegarde."); }
        var destination = plan.Kind == StorageWritePlans.BackupCopy ? BackupRaw(plan, "backup.export") : null;
        if (destination is not null && !BackupDestinationMatches(plan)) { throw WriteErrors.Refusal(WriteErrors.Stale, "Destination modifiée depuis le plan."); }
        using var sourceDb = new SqliteDatabase(Path, true, cancellationToken: token);
        sourceDb.Begin(false); CheckIdentity(sourceDb, true);
        var inspection = Inspect(sourceDb);
        if (inspection.Revision.ToString(CultureInfo.InvariantCulture) != BackupRaw(plan, "backup.revision"))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Révision modifiée depuis le plan de sauvegarde."); }
        var file = BackupRaw(plan, "backup.file");
        var target = System.IO.Path.Combine(BackupFolder, file);
        var partial = target + ".partial-" + plan.Id;
        CompatibleDirectoryCache.ValidateLocalPath(target); CompatibleDirectoryCache.ValidateLocalPath(BackupReceiptPath(plan.Id));
        Directory.CreateDirectory(BackupReceiptFolder);
        using (var intent = new FileStream(BackupReceiptPath(plan.Id) + ".intent", FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            var bytes = Encoding.UTF8.GetBytes(plan.Fingerprint); intent.Write(bytes); intent.Flush(flushToDisk: true);
        }
        using (new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
        using (var copy = new SqliteDatabase(partial, false, cancellationToken: token))
        {
            sourceDb.BackupTo(copy);
            copy.Script("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;");
            CheckIdentity(copy, true);
            if (copy.Scalar("PRAGMA quick_check;") as string != "ok" || Inspect(copy).Revision != inspection.Revision)
            { throw new InvalidDataException("Sauvegarde SQLite ou révision non conforme ; copie partielle conservée pour diagnostic."); }
        }
        sourceDb.Commit(); token.ThrowIfCancellationRequested();
        File.Move(partial, target, overwrite: false);
        var hash = BackupFileHash(target);
        var at = clock.GetUtcNow();
        var preferences = BackupPreferencesRules.Bind(BackupRaw(plan, "backup.preferences"), hash, at);
        var annexPath = System.IO.Path.ChangeExtension(target, ".preferences.json");
        WriteNewBackupFile(annexPath, JsonSerializer.SerializeToUtf8Bytes(preferences, Json));
        var counts = new LocalStoreCounts(inspection.Objects, inspection.Observations, null, inspection.Associations, inspection.Recipes, null);
        var backup = new LocalStoreBackup(plan.Id, file, at, new FileInfo(target).Length, hash, true, at, BackupRaw(plan, "backup.series"), inspection.Revision, counts, null, preferences);
        var proof = new StorageBackupProof(plan.Id, plan.Fingerprint, StoreId, DomainDn, backup, destination, destination is null, false);
        SaveStorageBackupProof(proof);
        // The verified local copy remains recoverable even if publication is interrupted.
        if (destination is not null)
        {
            if (!BackupDestinationMatches(plan)) { throw new IOException("La destination a changé pendant la copie ; sauvegarde locale vérifiée conservée, aucune publication."); }
            var staged = destination + ".domenia-" + plan.Id + ".partial";
            CompatibleDirectoryCache.ValidateLocalPath(staged);
            File.Copy(target, staged, overwrite: false);
            if (BackupFileHash(staged) != hash) { throw new InvalidDataException("Empreinte de la copie de publication différente."); }
            if (File.Exists(destination))
            {
                var preserved = destination + ".previous-" + plan.Id + ".db";
                CompatibleDirectoryCache.ValidateLocalPath(preserved);
                // Moving the old file aside first makes the final publication create-only. A concurrent replacement is never overwritten.
                File.Move(destination, preserved, overwrite: false);
                if (BackupFileHash(preserved) != BackupRaw(plan, "backup.destinationBefore"))
                {
                    if (!File.Exists(destination)) { File.Move(preserved, destination, overwrite: false); }
                    throw new IOException("Destination modifiée au moment de la publication ; original conservé, aucune nouvelle copie publiée.");
                }
                File.Move(staged, destination, overwrite: false);
            }
            else { File.Move(staged, destination, overwrite: false); }
            var exportedAnnex = destination + ".preferences-" + plan.Id + ".json";
            WriteNewBackupFile(exportedAnnex, JsonSerializer.SerializeToUtf8Bytes(preferences, Json));
            if (BackupFileHash(destination) != hash) { throw new InvalidDataException("Publication non conforme ; copie locale conservée."); }
            proof = proof with { Published = true }; SaveStorageBackupProof(proof);
        }
        var rotated = plan.Changes.SingleOrDefault(x => x.Attribute == "backup.rotation")?.BeforeValue;
        if (rotated is not null) { RetireStorageBackup(rotated, plan.Id); }
        lastBackup = new(target, hash, backup.Bytes, at);
        return new(WriteResult.Applied, "Sauvegarde vérifiée, annexe de préférences liée au SHA-256 " + hash + (destination is null ? "." : " et publication relue."));
    }

    public Task<WriteVerification> VerifyStorageBackupAsync(WritePlan plan, CancellationToken cancellationToken) => Task.Run(() =>
    {
        ValidateStorageBackupPlan(plan, requireCurrent: false);
        var proof = ReadStorageBackupProof(plan.Id);
        if (proof is null) { return new WriteVerification(VerificationState.Unknown, "Aucune preuve finale de sauvegarde ; aucun rejeu automatique."); }
        if (proof.PlanFingerprint != plan.Fingerprint || proof.Retired) { return new WriteVerification(VerificationState.Mismatch, "Sauvegarde remplacée par la rotation ou liée à un autre plan."); }
        ValidateBackupArtifact(proof, cancellationToken);
        if (!proof.Published) { return new WriteVerification(VerificationState.Mismatch, "Copie locale vérifiée ; publication interrompue, aucune reprise automatique."); }
        if (proof.Destination is { } destination)
        {
            ValidateBackupDestination(destination);
            if (!File.Exists(destination) || BackupFileHash(destination) != proof.Backup.Sha256)
            { return new WriteVerification(VerificationState.Mismatch, "Fichier publié absent ou modifié ; copie locale conservée."); }
            var annex = ReadBackupJson<BackupPreferences>(destination + ".preferences-" + plan.Id + ".json");
            if (annex != proof.Backup.Preferences) { throw new InvalidDataException("Annexe publiée incohérente."); }
        }
        return new WriteVerification(VerificationState.Verified, "Copie SQLite et préférences relues, SHA-256 conforme au reçu" + (proof.Destination is null ? "." : " ; publication vérifiée."));
    }, cancellationToken);

    private void ValidateStorageBackupPlan(WritePlan plan, bool requireCurrent)
    {
        if (plan.Kind is not (StorageWritePlans.Backup or StorageWritePlans.BackupCopy) || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText
            || !WritePlans.IsPlanId(plan.Id) || !WritePlans.IsIntact(plan) || plan.Target.Dn != Path || plan.Target.ObjectGuid != StorageWritePlans.StoreGuid(StoreId)
            || requireCurrent && plan.ExpiresAt <= clock.GetUtcNow()) { throw new InvalidDataException("Plan de sauvegarde invalide, expiré ou d’une autre base."); }
        var file = BackupRaw(plan, "backup.file");
        if (file.Length is < 4 or > 128 || !file.EndsWith(".db", StringComparison.Ordinal) || file.Contains("..", StringComparison.Ordinal)
            || file.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('-' or '_' or '.')) || BackupRaw(plan, "backup.series") is not ("manual" or "scheduled")
            || !long.TryParse(BackupRaw(plan, "backup.revision"), NumberStyles.None, CultureInfo.InvariantCulture, out _))
        { throw new InvalidDataException("Nom ou révision de sauvegarde invalide."); }
        if (plan.Kind == StorageWritePlans.BackupCopy) { ValidateBackupDestination(BackupRaw(plan, "backup.export")); }
    }

    private void ValidateBackupDestination(string target)
    {
        if (LocalStoreRules.DestinationProblem(target, Path) is { } problem) { throw new InvalidDataException(problem); }
        CompatibleDirectoryCache.ValidateLocalPath(target);
        if (!Directory.Exists(System.IO.Path.GetDirectoryName(target))) { throw new DirectoryNotFoundException("Dossier de publication absent ; aucun dossier créé implicitement."); }
    }
    private bool BackupDestinationMatches(WritePlan plan)
    {
        var target = BackupRaw(plan, "backup.export"); ValidateBackupDestination(target);
        return (File.Exists(target) ? BackupFileHash(target) : "absent") == BackupRaw(plan, "backup.destinationBefore");
    }
    private static string BackupFileHash(string path)
    {
        CompatibleDirectoryCache.ValidateLocalPath(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }
    private static void WriteNewBackupFile(string path, byte[] bytes)
    {
        CompatibleDirectoryCache.ValidateLocalPath(path);
        using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        file.Write(bytes); file.Flush(flushToDisk: true);
    }
    private static T ReadBackupJson<T>(string path)
    {
        CompatibleDirectoryCache.ValidateLocalPath(path);
        if (new FileInfo(path).Length > 1_048_576) { throw new InvalidDataException("Métadonnées de sauvegarde trop volumineuses."); }
        return JsonSerializer.Deserialize<T>(File.ReadAllBytes(path), Json) ?? throw new InvalidDataException("Métadonnées de sauvegarde illisibles.");
    }
    private StorageBackupProof? ReadStorageBackupProof(string id)
    {
        if (!WritePlans.IsPlanId(id)) { throw new InvalidDataException("Identifiant de sauvegarde invalide."); }
        var path = BackupReceiptPath(id);
        if (!File.Exists(path)) { return null; }
        var envelope = ReadBackupJson<StorageBackupEnvelope>(path);
        if (BackupPreferencesRules.Sha256(envelope.Json) != envelope.Sha256) { throw new InvalidDataException("Reçu de sauvegarde altéré."); }
        var proof = JsonSerializer.Deserialize<StorageBackupProof>(envelope.Json, Json) ?? throw new InvalidDataException("Reçu de sauvegarde illisible.");
        if (proof.PlanId != id || proof.StoreId != StoreId || proof.DomainDn != DomainDn || proof.Backup.Id != id || !BackupPreferencesRules.IsBound(proof.Backup)
            || System.IO.Path.GetFileName(proof.Backup.FileName) != proof.Backup.FileName || proof.Backup.FileName.Contains("..", StringComparison.Ordinal))
        { throw new InvalidDataException("Reçu de sauvegarde d’une autre base ou incohérent."); }
        return proof;
    }
    private void SaveStorageBackupProof(StorageBackupProof proof)
    {
        var json = JsonSerializer.Serialize(proof, Json);
        var path = BackupReceiptPath(proof.PlanId);
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        WriteNewBackupFile(temporary, JsonSerializer.SerializeToUtf8Bytes(new StorageBackupEnvelope(BackupPreferencesRules.Sha256(json), json), Json));
        File.Move(temporary, path, overwrite: true);
        if (ReadStorageBackupProof(proof.PlanId) != proof) { throw new InvalidDataException("Reçu de sauvegarde non relu après publication."); }
    }
    private void ValidateBackupArtifact(StorageBackupProof proof, CancellationToken token)
    {
        var target = System.IO.Path.Combine(BackupFolder, proof.Backup.FileName);
        if (!File.Exists(target) || new FileInfo(target).Length != proof.Backup.Bytes || BackupFileHash(target) != proof.Backup.Sha256)
        { throw new InvalidDataException("Sauvegarde absente ou empreinte différente ; aucune copie certifiée."); }
        using var copy = new SqliteDatabase(target, true, cancellationToken: token);
        CheckIdentity(copy, true);
        if (copy.Scalar("PRAGMA quick_check;") as string != "ok" || Inspect(copy).Revision != proof.Backup.Revision)
        { throw new InvalidDataException("Sauvegarde SQLite incohérente."); }
        if (ReadBackupJson<BackupPreferences>(System.IO.Path.ChangeExtension(target, ".preferences.json")) != proof.Backup.Preferences)
        { throw new InvalidDataException("Annexe de préférences incohérente."); }
    }
    private ImmutableArray<LocalStoreBackup> ReadRegisteredBackups()
    {
        if (!Directory.Exists(BackupReceiptFolder)) { return []; }
        CompatibleDirectoryCache.ValidateLocalPath(System.IO.Path.Combine(BackupReceiptFolder, "probe.json"));
        var paths = Directory.EnumerateFiles(BackupReceiptFolder, "*.json").Take(4097).ToArray();
        if (paths.Length > 4096) { throw new InvalidDataException("Plus de 4 096 reçus de sauvegarde ; lecture interrompue sans liste partielle."); }
        return [.. paths.Select(p => ReadStorageBackupProof(System.IO.Path.GetFileNameWithoutExtension(p))!)
            .Where(p => !p.Retired).Select(p => p.Backup).OrderByDescending(b => b.At)];
    }
    private void RetireStorageBackup(string id, string replacement)
    {
        var proof = ReadStorageBackupProof(id) ?? throw new InvalidDataException("Copie de rotation non enregistrée ; aucune suppression.");
        if (id == replacement || proof.Retired) { throw new InvalidDataException("Rotation incohérente."); }
        ValidateBackupArtifact(proof, CancellationToken.None);
        // Retain recoverable originals outside the active rotation; never delete an unqualified file.
        var retired = System.IO.Path.Combine(BackupFolder, "Retired"); Directory.CreateDirectory(retired);
        var source = System.IO.Path.Combine(BackupFolder, proof.Backup.FileName);
        var target = System.IO.Path.Combine(retired, proof.Backup.FileName); CompatibleDirectoryCache.ValidateLocalPath(target);
        File.Move(source, target, overwrite: false);
        File.Move(System.IO.Path.ChangeExtension(source, ".preferences.json"), System.IO.Path.ChangeExtension(target, ".preferences.json"), overwrite: false);
        SaveStorageBackupProof(proof with { Retired = true });
    }
}
