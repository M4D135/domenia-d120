using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Store;

internal enum SharedParkApplyStage { IntentRecorded, BeforePublication, NativeReplaceWindow, Published, BeforeCommit, BeforeLocalInstall, Committed }

public sealed partial class DomeniaDatabase
{
    /// <summary>
    /// Pure metadata draft for the existing write circuit. The source executor must bind its origin and consume the normal
    /// confirmation token; this internal Store API provides no alternate UI or public execution route. Nothing is created here: the
    /// physical copies, the durable intention and the receipt described below are what the confirmed execution of <em>this</em> plan
    /// will produce, never a state the preview has already reached, so no wording here may attest them as already obtained.
    /// </summary>
    internal WritePlanDraft DraftSharedPark(SharedParkPreparedPreview preview, WritePlanOrigin origin)
    {
        ArgumentNullException.ThrowIfNull(preview); ArgumentNullException.ThrowIfNull(origin);
        var batch = preview.Reference; ValidateSharedParkBackupBatch(batch);
        if (origin.Epoch != batch.Epoch || string.IsNullOrWhiteSpace(origin.SessionKey)) { throw new InvalidDataException("Origine du plan différente de l’aperçu."); }
        var c = FrenchText.Colon;
        var hash = SharedParkIdentity.Fingerprint(batch);
        return new WritePlanDraft(SyncStoreChange.Kind, "Synchroniser le relevé partagé", "Relevé partagé du parc",
            "Publier les relevés fusionnés dans le fichier partagé et conserver les observations externes à part, sous leur propre clé, dans la base locale.",
            SyncStoreChange.ParkTarget("Relevé partagé du parc", false) with { Dn = SyncLocalIdentity.Target(StoreId, DomainDn) },
            [new(SyncStoreChange.BatchAttribute, "Lot d’aperçu lié", WriteChangeKind.Replace, null, "Fusion du parc", null,
                SyncStoreChange.HeadValue("park", batch.Id, hash, batch.MergedRows)),
             new(SharedParkIdentity.PathAttribute, "Fichier partagé", WriteChangeKind.Replace, batch.RemoteExists ? batch.Path : null, batch.Path, null, batch.Path),
             new(SharedParkIdentity.PayloadAttribute, "Octets proposés", WriteChangeKind.Replace, null, "Contenu relu du spool de l’aperçu", null, batch.ProposedSha256)],
            [new(Tone.Warn, "Les noms de postes, dates, statuts et comptes du relevé seront écrits dans ce fichier partagé. Aucun objet Active Directory n’est modifié."),
             new(Tone.Warn, "Le partage et SQLite ne forment pas une transaction unique. Une interruption peut laisser un résultat incertain ; aucun rejeu ni retour arrière automatique."),
             new(Tone.Warn, "Le verrou partagé n’écarte que les consoles coopérantes" + c + "un écrivain qui l’ignore reste possible. Toute ambiguïté après la tentative est annoncée incertaine, jamais comme un succès.")],
            new(false, null, "Confirmer explicitement l’écriture du fichier partagé et de la mémoire locale. La confirmation porte sur le lot tel qu’il est lié au plan" + c
                + "identifiant et empreinte du lot, empreinte et volume des octets du spool, session et époque de la source, magasin et domaine, chemin du fichier partagé et expiration du plan."),
            new(true, "Point de retour" + c + "copies et intention que le protocole s’engage à créer",
                "Rien n’est encore créé à l’aperçu" + c + "l’exécution confirmée écrira d’abord les copies physiques vérifiées du fichier partagé et de la base, puis l’intention durable relue à l’identique, avant toute tentative de publication. Le reçu SQLite ne sera commis que dans la même transaction que les relevés locaux. Une compensation reste un nouveau geste de l’opérateur (vérification à froid puis décision explicite), jamais automatique."),
            null) { Origin = origin };
    }

    /// <summary>
    /// Explicit, confirmed execution only. The caller must hold its source/maintenance gate for this entire operation; validateSource
    /// MUST revalidate its actual source epoch, session identity and configuration. Passing a number or a no-op proves no source gate.
    /// A historical store is bound by minimal additive metadata in the same transaction; its original tables/rows stay intact.
    /// An absent store is prepared privately on the final volume and installed without replacement only after committing its receipt.
    /// The D1 lock protects cooperating writers. Atomic file replacement is not a universal CAS: every actually displaced file is
    /// retained and compared, and any ambiguity after attempting publication returns Unknown with intention/copies intact.
    /// No general legacy migration, compensation, retry or journal cleanup is initiated here. Local park changes and their receipt commit together.
    /// </summary>
    internal Task<WriteOutcome> ApplySharedParkConfirmedAsync(SharedParkPreparedPreview preview, WritePlan plan, string backupRoot,
        string journalRoot, ImmutableArray<string> configFiles, ImmutableArray<string> protectedDirectories, Action validateSource,
        CancellationToken token, Action<SharedParkApplyStage>? checkpoint = null,
        Action<Exception>? publicationFailure = null) => Task.Run(async () =>
    {
        ArgumentNullException.ThrowIfNull(preview); ArgumentNullException.ThrowIfNull(validateSource);
        var batch = preview.Reference;
        ValidateSharedParkPlan(plan, batch, current: true);
        ValidateSharedParkRoots(backupRoot, journalRoot);
        var protections = protectedDirectories.Add(backupRoot).Add(journalRoot).Add(SharedParkPendingSqlite.RootFor(Path));
        SharedParkRemoteReader.Validate(System.IO.Path.Combine(journalRoot, "probe.tsv"), Path, configFiles, protectedDirectories.Add(backupRoot), token);
        SharedParkPublicationFile.ValidatePaths(batch.Path, plan.Id, Path, configFiles, protections, token);
        var journal = new SharedParkIntentJournal(journalRoot, StoreId, DomainDn, clock);
        validateSource(); token.ThrowIfCancellationRequested();
        await writer.WaitAsync(token).ConfigureAwait(false);
        SharedParkPublicationFile? publication = null;
        try
        {
            if (await journal.ReadAsync(plan.Id, plan.Fingerprint, token).ConfigureAwait(false) is not null)
            { throw new InvalidDataException("Une intention existe déjà ; vérifiez son résultat, aucun rejeu autorisé."); }
            validateSource(); token.ThrowIfCancellationRequested();
            var proposed = await preview.ReadProposedAsync(batch.SessionId, batch.Epoch, token).ConfigureAwait(false);
            validateSource(); token.ThrowIfCancellationRequested();
            if (proposed.LongLength != batch.PayloadBytes || SharedParkFile.Hash(proposed) != batch.ProposedSha256)
            { throw new InvalidDataException("Spool proposé différent du plan confirmé."); }
            var copies = await CreateSharedParkBackupsAsync(batch, backupRoot, configFiles, protectedDirectories.Add(journalRoot), token).ConfigureAwait(false);
            validateSource(); token.ThrowIfCancellationRequested();
            var intent = new SharedParkIntent(SharedParkIntentDocument.DocumentVersion, plan.Id, plan.Fingerprint, batch,
                SharedParkIdentity.Fingerprint(batch), clock.GetUtcNow(), copies.SqliteBackup, copies.TsvBackup);
            using var evidence = OpenSharedParkEvidence(intent, backupRoot, token);
            validateSource(); token.ThrowIfCancellationRequested();
            await journal.CreateAsync(intent, token).ConfigureAwait(false);
            validateSource(); token.ThrowIfCancellationRequested();
            if (await journal.ReadAsync(plan.Id, plan.Fingerprint, token).ConfigureAwait(false) != intent)
            { throw new InvalidDataException("Intention durable non relue à l’identique."); }
            checkpoint?.Invoke(SharedParkApplyStage.IntentRecorded);
            token.ThrowIfCancellationRequested(); validateSource();
            using var sharedLock = await SharedParkFile.LockAsync(batch.Path, token).ConfigureAwait(false);
            validateSource(); ValidateSharedParkPlan(plan, batch, current: true);
            // Pin the real source inode and ancestors, then let SQLite BEGIN IMMEDIATE exclude other SQLite writers. The existing
            // StorageWriteFence.Writer inside SqliteDatabase also respects a retired-store marker; no extra fence file is invented.
            using var privatePaths = SharedParkBackupFiles.Open(backupRoot, Path, batch.Path, configFiles, protectedDirectories.Add(journalRoot), token);
            using var pending = batch.LocalExists ? null : new SharedParkPendingSqlite(Path, plan.Id, token);
            using var sourceIdentity = privatePaths.PinSqliteSource(pending?.Path ?? Path, token);
            using var db = OpenPath(pending?.Path ?? Path, false, cancellationToken: token);
            db.Script("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;"); db.Begin();
            var local = pending is null ? ReadSharedParkBackupLocal(db, token) : AbsentSharedParkLocal();
            MatchSharedParkBackupLocal(batch, local);
            if (pending is null && StorageWriteSnapshot.Read(db, token) != copies.SqliteLogicalFingerprint)
            { throw new InvalidDataException("CAS SQLite refusé : la base diffère de sa sauvegarde vérifiée."); }
            if (pending is not null)
            {
                pending.RequireAbsent(token); Upgrade(db);
                if (ReadRelationSweeps(db, token).Fingerprint != local.RowsFingerprint)
                { throw new InvalidDataException("Initialisation SQLite non vide ; aucune publication."); }
            }
            validateSource(); token.ThrowIfCancellationRequested();
            var remote = await SharedParkRemoteReader.ReadAsync(batch.Path, Path, configFiles, protections, clock.GetUtcNow(), token).ConfigureAwait(false);
            validateSource(); token.ThrowIfCancellationRequested();
            MatchSharedParkBackupRemote(batch, remote);
            var merge = SharedParkMerge.Preview(local, remote.Rows, clock.GetUtcNow(), token);
            if (merge.Added != batch.Added || merge.Replaced != batch.Replaced || merge.Lines.Length != batch.MergedRows
                || !SharedParkFile.Encode(merge.Lines).AsSpan().SequenceEqual(proposed))
            { throw new InvalidDataException("Fusion recalculée différente du contenu confirmé."); }
            var updates = PrepareSharedParkUpdates(db, local, merge.RemoteWinners);
            ValidateSharedParkReceiptSchema(db);
            if (ReadSharedParkReceipt(db, plan.Id) is not null) { throw new InvalidDataException("Reçu existant ; aucun rejeu."); }
            token.ThrowIfCancellationRequested(); validateSource(); ValidateSharedParkPlan(plan, batch, current: true);
            if (pending is null) { MatchSharedParkBackupLocal(batch, ReadSharedParkBackupLocal(db, token)); }
            else { pending.RequireAbsent(token); }
            MatchSharedParkBackupRemote(batch, await SharedParkRemoteReader.ReadAsync(batch.Path, Path, configFiles,
                protections, clock.GetUtcNow(), token).ConfigureAwait(false));
            validateSource(); token.ThrowIfCancellationRequested();
            if (local.Legacy) { BindSharedParkLegacy(db, local, token); }
            // Limit growth as well as the initial backup. SQLite will refuse a larger transaction, which remains Unknown if the
            // TSV was already published. The page-size value is read from this connection, never assumed from a file length.
            var pageSize = (long)db.Scalar("PRAGMA page_size;")!;
            if (pageSize is < 512 or > 65536) { throw new InvalidDataException("Géométrie SQLite non qualifiée."); }
            db.Script("PRAGMA max_page_count=" + (SharedParkBackupFiles.MaxSqliteBytes / pageSize).ToString(System.Globalization.CultureInfo.InvariantCulture) + ";");
            publication = new SharedParkPublicationFile(batch.Path, plan.Id, batch.RemoteExists, batch.RemoteSha256, proposed, token);
            // Last seam before the rename. Everything above has already been re-read under the lock, so anything injected here can only
            // be caught by the physical CAS that Publish performs again, on its own, immediately before it attempts the replacement.
            checkpoint?.Invoke(SharedParkApplyStage.BeforePublication);
            token.ThrowIfCancellationRequested(); validateSource();
            // The temporary and the private evidence directory have just been prepared and the seam has run: real time may have passed,
            // and the plan or its batch may have expired meanwhile. Both time bounds are requalified here, never after a rename is
            // attempted — this is a refusal before any attempt, so Attempted stays false and no uncertainty is manufactured.
            ValidateSharedParkPlan(plan, batch, current: true);
            publication.Publish(token, () =>
            {
                checkpoint?.Invoke(SharedParkApplyStage.NativeReplaceWindow);
                token.ThrowIfCancellationRequested(); validateSource(); ValidateSharedParkPlan(plan, batch, current: true);
                pending?.RequireAbsent(token);
            });
            checkpoint?.Invoke(SharedParkApplyStage.Published);
            token.ThrowIfCancellationRequested(); validateSource();
            var beforeChanges = (long)db.Scalar("SELECT total_changes();")!;
            foreach (var update in updates)
            {
                token.ThrowIfCancellationRequested();
                var line = update.Line;
                var changed = update.Previous is null
                    ? db.Execute("INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts) VALUES(?1,?2,?3,?4,?5,?6);",
                        update.Key, line.Computer, Stamp(line.At), SharedParkStoredStatus(line.Status), line.User, line.Attempts)
                    : db.Execute("UPDATE park_state SET computer=?2,last_probe=?3,status=?4,user_login=?5,attempts=?6 WHERE computer_key=?1;",
                        update.Key, line.Computer, Stamp(line.At), SharedParkStoredStatus(line.Status), line.User, line.Attempts);
                if (changed != 1) { throw new InvalidDataException("Nombre de relevés externes modifiés inattendu."); }
            }
            var after = ReadRelationSweeps(db, token);
            VerifySharedParkUpdates(local.Sweeps, after, updates);
            var revision = checked(batch.Revision + 1);
            if (db.Execute("UPDATE domenia_store_state SET revision=?1 WHERE id=1 AND revision=?2;", revision, batch.Revision) != 1)
            { throw new InvalidDataException("Révision SQLite modifiée pendant la transaction."); }
            var receipt = new SharedParkCommitReceipt(1, plan.Id, plan.Fingerprint, batch.Id, SharedParkIdentity.Fingerprint(batch),
                StoreId, DomainDn, batch.Path, batch.ProposedSha256, after.Fingerprint, revision, after.Generation, updates.Length, clock.GetUtcNow());
            SaveSharedParkReceipt(db, receipt);
            if (ReadSharedParkReceipt(db, plan.Id) != receipt || (long)db.Scalar("SELECT total_changes();")! - beforeChanges != updates.Length + 2L)
            { throw new InvalidDataException("Reçu ou effets SQLite supplémentaires ; transaction annulée, partage à vérifier."); }
            checkpoint?.Invoke(SharedParkApplyStage.BeforeCommit);
            token.ThrowIfCancellationRequested(); validateSource();
            _ = SharedParkBackupSize(db);
            db.Commit();
            if (pending is not null)
            {
                // SQLite is fully closed before the same-volume create-only installation. A committed private base and its receipt
                // survive every failure here; the active path is never overwritten and no compensation is attempted.
                db.Dispose(); sourceIdentity.Dispose();
                checkpoint?.Invoke(SharedParkApplyStage.BeforeLocalInstall);
                token.ThrowIfCancellationRequested(); validateSource(); pending.Install(token);
            }
            checkpoint?.Invoke(SharedParkApplyStage.Committed);
            var verification = await VerifySharedParkConfirmedAsync(plan, backupRoot, journalRoot, configFiles, protectedDirectories, token).ConfigureAwait(false);
            return verification.State == VerificationState.Verified
                ? new WriteOutcome(WriteResult.Applied, "Fichier partagé et transaction locale relus ; intention, copies initiales et reçu durable conservés.")
                : new WriteOutcome(WriteResult.Unknown, "Publication tentée ; les deux états ne sont pas confirmés ensemble. Relisez le reçu, aucun rejeu automatique.");
        }
        catch (Exception error) when (publication?.Attempted == true)
        {
            // Internal local-fixture diagnostics only; the normal receipt remains bounded and never exposes exception data.
            try { publicationFailure?.Invoke(error); }
            catch (Exception) { /* A diagnostic observer cannot replace the uncertain outcome of an attempted publication. */ }
            return new WriteOutcome(WriteResult.Unknown, "Publication tentée puis interrompue ou non conforme ; intention et preuves conservées. Aucune compensation ni nouvelle tentative automatique.");
        }
        finally
        {
            try { publication?.Dispose(); }
            catch (Exception) when (publication?.Attempted == true) { /* Closing a read handle cannot turn uncertainty into NotApplied. */ }
            finally { writer.Release(); }
        }
    }, token);

    private void BindSharedParkLegacy(SqliteDatabase db, SharedParkLocalRead local, CancellationToken token)
    {
        if (!local.Legacy || local.Revision != 0 || Table(db, "domenia_store_state"))
        { throw new InvalidDataException("Identité historique différente de celle confirmée."); }
        var before = (long)db.Scalar("SELECT total_changes();")!;
        db.Script("CREATE TABLE domenia_store_state(id INTEGER PRIMARY KEY CHECK(id=1),store_id TEXT NOT NULL,domain_dn TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0);"
            + "CREATE TABLE IF NOT EXISTS park_state(computer_key TEXT PRIMARY KEY,computer TEXT,last_probe TEXT,status TEXT,user_login TEXT,attempts INTEGER DEFAULT 0);");
        if (db.Execute("INSERT INTO domenia_store_state(id,store_id,domain_dn,revision) VALUES(1,?1,?2,0);", StoreId, DomainDn) != 1
            || (long)db.Scalar("SELECT total_changes();")! - before != 1 || ReadRelationSweeps(db, token).Fingerprint != local.RowsFingerprint)
        { throw new InvalidDataException("Rattachement historique a modifié autre chose que son identité additive."); }
        // schema_info and all D1 tables retain their original version and contents. A later explicit general initialization can
        // upgrade other features independently; this operation only installs the metadata needed for its own atomic receipt.
        CheckIdentity(db, allowLegacy: true);
    }

    private void ValidateSharedParkPlan(WritePlan plan, SharedParkBatch batch, bool current)
    {
        ArgumentNullException.ThrowIfNull(plan);
        if (current) { ValidateSharedParkBackupBatch(batch); }
        var head = SyncStoreChange.Head(plan);
        if (!WritePlans.IsPlanId(plan.Id) || !WritePlans.IsIntact(plan) || plan.Kind != SyncStoreChange.Kind || plan.Simulated
            || plan.Mode != AppInfoBuilder.DirectoryModeText || plan.Target.Kind != "database"
            || plan.Target.ObjectGuid != SyncStoreChange.ParkStoreGuid.ToString("D") || plan.Target.Dn != SyncLocalIdentity.Target(StoreId, DomainDn)
            || plan.Controller is not null || plan.Changes.Length != 3 || head is not { Operation: SyncStoreOperation.Batch, Kind: "park" }
            || head.Id != batch.Id || head.Sha256 != SharedParkIdentity.Fingerprint(batch) || head.Count != batch.MergedRows || head.Preview != ""
            || plan.Changes[1].Attribute != SharedParkIdentity.PathAttribute || plan.Changes[1].AfterValue != batch.Path
            || plan.Changes[2].Attribute != SharedParkIdentity.PayloadAttribute || plan.Changes[2].AfterValue != batch.ProposedSha256
            || plan.Changes.Any(c => c.Kind != WriteChangeKind.Replace || c.BeforeValue is not null || c.ReferenceGuid is not null)
            || batch.StoreId != StoreId || batch.DomainDn != DomainDn || current && (plan.ExpiresAt <= clock.GetUtcNow() || plan.CreatedAt > clock.GetUtcNow()))
        { throw new InvalidDataException("Plan de partage absent, altéré, étranger ou expiré."); }
    }

    private static void ValidateSharedParkRoots(string backupRoot, string journalRoot)
    {
        if (string.IsNullOrWhiteSpace(backupRoot) || string.IsNullOrWhiteSpace(journalRoot)
            || !System.IO.Path.IsPathFullyQualified(backupRoot) || !System.IO.Path.IsPathFullyQualified(journalRoot)
            || backupRoot.Replace('/', '\\').Split('\\').Any(c => c.Equals("dev", StringComparison.OrdinalIgnoreCase))
            || journalRoot.Replace('/', '\\').Split('\\').Any(c => c.Equals("dev", StringComparison.OrdinalIgnoreCase))
            || backupRoot.Equals(journalRoot, StringComparison.OrdinalIgnoreCase)
            || backupRoot.StartsWith(journalRoot.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)
            || journalRoot.StartsWith(backupRoot.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
        { throw new InvalidDataException("Dossiers locaux de sauvegardes et d’intentions distincts et non imbriqués requis."); }
    }

    private sealed record SharedParkUpdate(string Key, SharedParkLine Line, RelationSweepRecord? Previous);

    private static ImmutableArray<SharedParkUpdate> PrepareSharedParkUpdates(SqliteDatabase db, SharedParkLocalRead local, ImmutableArray<SharedParkLine> winners)
    {
        if (local.Revision == long.MaxValue || !HasOnlyQualifiedStorageTriggers(db))
        { throw new InvalidDataException("Révision épuisée ou déclencheur SQLite non qualifié ; aucune publication."); }
        var updates = ImmutableArray.CreateBuilder<SharedParkUpdate>();
        var columns = db.Query("PRAGMA table_info(park_state);");
        var supplied = new HashSet<string>(["computer_key", "computer", "last_probe", "status", "user_login", "attempts"], StringComparer.OrdinalIgnoreCase);
        var requiredExtension = columns.Any(c => !supplied.Contains((string)c["name"]!) && c["notnull"] is 1L && c["dflt_value"] is null);
        foreach (var line in winners)
        {
            _ = SharedParkStoredStatus(line.Status);
            var key = "shared:" + SyncPark.Key(line.Computer);
            var occupied = local.Sweeps.Rows.Where(r => r.StorageKey.Equals(key, StringComparison.OrdinalIgnoreCase)).ToArray();
            if (occupied.Length > 1) { throw new InvalidDataException("Clé de relevé partagé ambiguë."); }
            var previous = occupied.SingleOrDefault();
            if (previous is not null && (previous.ComputerGuid is not null || previous.ComputerDn is not null
                || !previous.Computer.Equals(line.Computer, StringComparison.OrdinalIgnoreCase)
                || !previous.Status.StartsWith(SyncPark.SharedPrefix, StringComparison.OrdinalIgnoreCase)))
            { throw new InvalidDataException("Clé shared occupée par une observation native ou non qualifiée ; aucune publication."); }
            if (previous is null && requiredExtension) { throw new InvalidDataException("Colonne historique obligatoire sans défaut ; aucun ajout implicite."); }
            updates.Add(new(previous?.StorageKey ?? key, line, previous));
        }
        if (updates.Count != updates.Select(u => u.Key).Distinct(StringComparer.Ordinal).Count())
        { throw new InvalidDataException("Deux relevés distants viseraient la même clé locale ; aucune publication."); }
        if (local.Sweeps.Total + updates.Count(u => u.Previous is null) > SharedParkFile.MaxRows)
        { throw new InvalidDataException("Mémoire locale dépasserait 50 000 lignes ; aucune publication."); }
        return updates.ToImmutable();
    }

    private static string SharedParkStoredStatus(string status)
    {
        var raw = status.StartsWith(SyncPark.SharedPrefix, StringComparison.OrdinalIgnoreCase) ? status[SyncPark.SharedPrefix.Length..] : status;
        if (raw.StartsWith(SyncPark.SharedPrefix, StringComparison.OrdinalIgnoreCase) || string.IsNullOrEmpty(raw))
        { throw new InvalidDataException("Préfixe partagé répété ou statut absent."); }
        return SyncPark.SharedPrefix + raw;
    }

    private static void VerifySharedParkUpdates(RelationSweepCacheSnapshot before, RelationSweepCacheSnapshot after, ImmutableArray<SharedParkUpdate> updates)
    {
        if (after.Truncated || after.Rejected != 0 || after.UncertainDates != 0 || after.Rows.Length != after.Total
            || after.Generation != before.Generation || after.Total != before.Total + updates.Count(u => u.Previous is null))
        { throw new InvalidDataException("Relecture locale partielle ou génération modifiée."); }
        if (before.Rows.Select(r => r.StorageKey).Distinct(StringComparer.Ordinal).Count() != before.Rows.Length)
        { throw new InvalidDataException("Clés locales dupliquées à la relecture ; aucune publication acquittée."); }
        var original = before.Rows.ToDictionary(r => r.StorageKey, StringComparer.Ordinal);
        var expected = updates.ToDictionary(u => u.Key, StringComparer.Ordinal);
        foreach (var row in after.Rows)
        {
            if (!expected.TryGetValue(row.StorageKey, out var update))
            {
                if (!original.TryGetValue(row.StorageKey, out var old) || old.StorageFingerprint != row.StorageFingerprint)
                { throw new InvalidDataException("Observation native modifiée par le partage ; transaction annulée."); }
                continue;
            }
            var line = update.Line;
            if (row.ComputerGuid is not null || row.ComputerDn is not null || row.Computer != line.Computer || row.At != line.At
                || row.Status != SharedParkStoredStatus(line.Status) || row.UserLogin != line.User || row.Attempts != line.Attempts
                || update.Previous is { } previous && row.PreservedFingerprint != previous.PreservedFingerprint)
            { throw new InvalidDataException("Observation externe non relue à l’identique."); }
        }
        if (expected.Keys.Any(key => !after.Rows.Any(row => row.StorageKey == key))) { throw new InvalidDataException("Observation externe absente après écriture."); }
    }
}
