using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache
{
    internal Action<string>? SwitchCheckpoint { get; set; }
    public async Task<WriteOutcome> ApplyStorageSwitchAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        var db = await DatabaseAsync(cancellationToken).ConfigureAwait(false);
        var request = ReadSwitchRequest(plan);
        await loading.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(SwitchFile)!);
            using var binding = StorageWriteFence.Exclusive(SwitchFile, cancellationToken);
            using var collecting = await db.AcquireOperationsLeaseAsync(cancellationToken).ConfigureAwait(false);
            using var writers = StorageWriteFence.Exclusive(db.Path, cancellationToken);
            // FileShare.Read rejects even non-cooperative D1 writers that already hold a writable handle.
            using var active = DenySwitchSourceWrites(db.Path);
            await ValidateSwitchAsync(db, plan, request, cancellationToken).ConfigureAwait(false);
            if (plan.Kind is StorageWritePlans.Move or StorageWritePlans.Restore)
            {
                ProbeDestinationWrite(request.Destination, cancellationToken);
                SwitchCheckpoint?.Invoke("destination-writable");
                using var copySource = request.CopySource.Path == db.Path ? null : DenySwitchSourceWrites(request.CopySource.Path);
                var state = new SwitchState(1, SwitchDomain, db.Path, "prepared", plan.Id, plan.Fingerprint, plan.Kind,
                    db.Path, request.Destination, db.StoreId, request.Original.Revision, request.Original.Fingerprint,
                    File.GetAttributes(db.Path).HasFlag(FileAttributes.ReadOnly), request.CopySource, null, null, plan.Id, plan.Fingerprint, plan.Kind) { OriginalUnreadable = request.Original.PhysicalOnly };
                PublishSwitch(state); SwitchCheckpoint?.Invoke("prepared");
                await CompleteForwardAsync(db, state, plan, cancellationToken).ConfigureAwait(false);
            }
            else
            {
                var state = ReadSwitchState()!;
                // Both files stay under deny-write handles while a continuation is published.
                var other = db.Path == state.SourcePath ? state.DestinationPath : state.SourcePath;
                using var otherWriters = File.Exists(other) ? StorageWriteFence.Exclusive(other, cancellationToken) : null;
                using var otherFile = File.Exists(other) ? DenySwitchSourceWrites(other) : null;
                state = state with { LastPlanId = plan.Id, LastPlanFingerprint = plan.Fingerprint, LastKind = plan.Kind };
                if (plan.Kind == StorageWritePlans.Rollback || state.Stage is "returning" or "rolledBack")
                { await CompleteReturnAsync(db, state, plan, cancellationToken).ConfigureAwait(false); }
                else
                {
                    using var copySource = state.CopySource.Path != db.Path && state.CopySource.Path != other ? DenySwitchSourceWrites(state.CopySource.Path) : null;
                    await CompleteForwardAsync(db, state, plan, cancellationToken).ConfigureAwait(false);
                }
            }
            return new(WriteResult.Applied, "Emplacement sélectionné et relu ; ancien fichier conservé, protection des écrivains et reçu de bascule enregistrés.");
        }
        finally { loading.Release(); }
    }

    private static void ProbeDestinationWrite(string destination, CancellationToken token)
    {
        // Only after confirmation. Never touch the destination or an existing file, even on failure.
        var probe = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(destination)!, ".domenia-write-probe-" + Guid.NewGuid().ToString("N") + ".tmp");
        token.ThrowIfCancellationRequested(); ValidateLocalPath(probe);
        using var file = new FileStream(probe, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 4096,
            FileOptions.DeleteOnClose | FileOptions.WriteThrough);
        file.WriteByte(0x44); file.Flush(flushToDisk: true); file.Position = 0;
        if (file.ReadByte() != 0x44) throw new IOException("Le dossier de destination n’a pas confirmé l’écriture de contrôle ; aucune bascule.");
        ValidateLocalPath(probe); token.ThrowIfCancellationRequested();
    }

    private sealed class SwitchSourceLease(List<FileStream> files) : IDisposable
    { public void Dispose() { foreach (var file in files) { file.Dispose(); } } }

    private static IDisposable DenySwitchSourceWrites(string path)
    {
        var files = new List<FileStream>();
        try
        {
            files.Add(DenyFileWrites(path));
            foreach (var suffix in new[] { "-wal", "-shm", "-journal" })
            { if (File.Exists(path + suffix)) { files.Add(DenyFileWrites(path + suffix)); } }
            return new SwitchSourceLease(files);
        }
        catch { foreach (var file in files) { file.Dispose(); } throw; }
    }

    private static FileStream DenyFileWrites(string path)
    {
        ValidateLocalPath(path);
        try { return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read); }
        catch (IOException ex) { throw new IOException("Base encore ouverte en écriture : fermez son utilisation par une autre instance avant la bascule.", ex); }
    }

    private async Task CompleteForwardAsync(DomeniaDatabase old, SwitchState state, WritePlan plan, CancellationToken token)
    {
        var original = await CreateDatabase(state.SourcePath, SwitchDomain).InspectSwitchOriginalAsync(state.SourcePath, state.OriginalUnreadable, token).ConfigureAwait(false);
        if (original.StoreId != state.OriginalStoreId || original.Revision != state.OriginalRevision || original.Fingerprint != state.OriginalFingerprint)
        { throw new InvalidDataException("Ancienne base modifiée depuis le début de la bascule ; aucun passage automatique."); }
        StorageWriteFence.Protect(state.SourcePath, state.Transaction);
        File.SetAttributes(state.SourcePath, File.GetAttributes(state.SourcePath) | FileAttributes.ReadOnly);
        StorageWriteFence.Protect(state.DestinationPath, state.Transaction);
        var target = CreateDatabase(state.DestinationPath, SwitchDomain);
        if (state.Copy is null)
        {
            if (File.Exists(state.DestinationPath)) { throw new InvalidDataException("Destination présente sans preuve de copie ; fichier conservé pour examen."); }
            RequireSameSource(state.CopySource, await old.InspectSwitchSourceAsync(state.CopySource.Path, state.OriginalKind == StorageWritePlans.Restore, token).ConfigureAwait(false));
            // Unfinished staging files are retained. A new explicit attempt uses a new name.
            var stage = state.DestinationPath + ".partial-" + WritePlans.NewId() + ".db";
            target.CopyForSwitch(state.CopySource, stage, token, copy =>
            {
                state = state with { Stage = "copied", Copy = copy, StagingPath = stage };
                PublishSwitch(state); SwitchCheckpoint?.Invoke("copied");
            });
        }
        else if (!File.Exists(state.DestinationPath))
        {
            if (state.StagingPath is null || !File.Exists(state.StagingPath)) { throw new InvalidDataException("Copie vérifiée absente ; aucun fichier vide créé."); }
            var stage = await target.InspectSwitchSourceAsync(state.StagingPath, true, token).ConfigureAwait(false);
            RequireSameSource(state.Copy with { Path = state.StagingPath }, stage);
            File.Move(state.StagingPath, state.DestinationPath, overwrite: false);
        }
        using var published = DenySwitchSourceWrites(state.DestinationPath);
        var current = await target.InspectSwitchSourceAsync(state.DestinationPath, true, token).ConfigureAwait(false);
        RequireSameSource(state.Copy!, current);
        if (current.StoreId != target.StoreId) { throw new InvalidDataException("La copie conserve une identité d’un autre emplacement."); }
        // Includes sidecar appearance/absence; no modified original is silently certified as preserved.
        if (state.OriginalUnreadable && DomeniaDatabase.RecoveryFingerprint(state.SourcePath, token) != state.OriginalFingerprint)
        { throw new InvalidDataException("Original illisible modifié pendant la copie ; aucune sélection publiée."); }
        state = state with { Stage = "committed", ActivePath = target.Path };
        PublishSwitch(state); SwitchCheckpoint?.Invoke("committed");
        RecordSwitchProof(plan, state, current);
        StorageWriteFence.Unprotect(target.Path, state.Transaction);
        cache = new SqliteDirectoryCache(target);
    }

    private async Task CompleteReturnAsync(DomeniaDatabase db, SwitchState state, WritePlan plan, CancellationToken token)
    {
        await ValidateReturnAsync(db, state, token).ConfigureAwait(false);
        state = state with { Stage = "returning" }; PublishSwitch(state); SwitchCheckpoint?.Invoke("returning");
        StorageWriteFence.Protect(state.SourcePath, state.Transaction);
        if (File.Exists(state.DestinationPath))
        {
            StorageWriteFence.Protect(state.DestinationPath, state.Transaction);
            File.SetAttributes(state.DestinationPath, File.GetAttributes(state.DestinationPath) | FileAttributes.ReadOnly);
        }
        var source = CreateDatabase(state.SourcePath, SwitchDomain);
        var current = await source.InspectSwitchSourceAsync(source.Path, false, token).ConfigureAwait(false);
        state = state with { Stage = "rolledBack", ActivePath = source.Path };
        PublishSwitch(state); RecordSwitchProof(plan, state, current);
        var attributes = File.GetAttributes(source.Path);
        File.SetAttributes(source.Path, state.OriginalReadOnly ? attributes | FileAttributes.ReadOnly : attributes & ~FileAttributes.ReadOnly);
        StorageWriteFence.Unprotect(source.Path, state.Transaction);
        cache = new SqliteDirectoryCache(source);
    }

    public async Task<WriteVerification> VerifyStorageSwitchAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ReadSwitchRequest(plan);
        var proof = ReadSwitchDocument<SwitchProof>(SwitchProofFile(plan.Id));
        if (proof is null || proof.PlanFingerprint != plan.Fingerprint || proof.Kind != plan.Kind)
        { return new(VerificationState.Mismatch, "Reçu durable de cette bascule absent ; aucune réussite certifiée."); }
        var state = ReadSwitchState();
        if (state is null || state.ActivePath != proof.ActivePath || SwitchPending(state))
        { return new(VerificationState.Mismatch, "La sélection durable ne correspond plus au reçu ou reste à terminer."); }
        if (state.OriginalUnreadable && (proof.PreservedOriginalPath != state.SourcePath || proof.PreservedOriginalFingerprint != state.OriginalFingerprint
            || DomeniaDatabase.RecoveryFingerprint(state.SourcePath, cancellationToken) != state.OriginalFingerprint))
        { return new(VerificationState.Mismatch, "Les octets conservés de l’original illisible ne correspondent plus au reçu."); }
        var current = await (await DatabaseAsync(cancellationToken).ConfigureAwait(false)).InspectSwitchSourceAsync(proof.ActivePath, false, cancellationToken).ConfigureAwait(false);
        return current.StoreId == proof.StoreId && current.Revision == proof.Revision && current.Fingerprint == proof.Fingerprint
            ? new(VerificationState.Verified, "Base sélectionnée relue : identité, révision, quick_check et empreinte du reçu conformes ; aucune bascule en attente.")
            : new(VerificationState.Mismatch, "La base a reçu d’autres modifications depuis ce reçu ; son état initial n’est plus confirmé.");
    }
}
