using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache
{
    private sealed record SwitchRequest(string Kind, string StateHash, DomeniaDatabase.SwitchSource Original,
        DomeniaDatabase.SwitchSource CopySource, string Destination);
    private string SwitchStateHash() => File.Exists(SwitchFile) ? SwitchHash(File.ReadAllText(SwitchFile)) : "none";
    private static string SwitchValue(WritePlan plan, string key) => plan.Changes.SingleOrDefault(c => c.Attribute == key)?.AfterValue ?? "";
    private static bool SwitchKind(string kind) => kind is StorageWritePlans.Move or StorageWritePlans.Restore or StorageWritePlans.Resume or StorageWritePlans.Rollback;

    private SwitchRequest ReadSwitchRequest(WritePlan plan)
    {
        if (!WritePlans.IsIntact(plan) || !WritePlans.IsPlanId(plan.Id) || !SwitchKind(plan.Kind) || plan.Target.Kind != StorageWritePlans.TargetKind)
        { throw new InvalidDataException("Plan de bascule invalide."); }
        var value = SwitchValue(plan, "switch.proof");
        if (value.Length > 1_048_576) { throw new InvalidDataException("Preuve de bascule hors limites."); }
        var request = JsonSerializer.Deserialize<SwitchRequest>(value, SwitchJson) ?? throw new InvalidDataException("Preuve de bascule absente.");
        if (request.Kind != plan.Kind || request.Original.Path != plan.Target.Dn
            || StorageWritePlans.StoreGuid(request.Original.StoreId) != plan.Target.ObjectGuid || request.Destination != SwitchValue(plan, "store.path"))
        { throw new InvalidDataException("Le plan ne correspond pas à sa base ni à sa destination."); }
        ValidateLocalPath(request.Original.Path); ValidateLocalPath(request.CopySource.Path); ValidateLocalPath(request.Destination);
        return request;
    }

    private WritePlanDraft BindSwitch(WritePlanDraft draft, DomeniaDatabase.SwitchSource original, DomeniaDatabase.SwitchSource source, string destination) => draft with
    {
        Changes = draft.Changes.Select(c => c.Attribute == "store.path" ? c with { After = destination, AfterValue = destination }
            : c.Attribute == "revision" ? c with { After = "révision " + (source.Revision + 1).ToString(CultureInfo.InvariantCulture), AfterValue = (source.Revision + 1).ToString(CultureInfo.InvariantCulture) } : c).ToImmutableArray()
            .Add(new("switch.proof", "Sources vérifiées", WriteChangeKind.Replace, null, "Identités, révisions et empreintes relues avant la bascule ; fichiers conservés.", null,
                JsonSerializer.Serialize(new SwitchRequest(draft.Kind, SwitchStateHash(), original, source, destination), SwitchJson))),
        Risks = draft.Risks.Where(r => !r.Text.Contains("120 s", StringComparison.Ordinal)).ToImmutableArray()
            .Add(new(Tone.Info, "La bascule refuse un fichier encore ouvert en écriture. L’ancien emplacement est protégé ; une autre instance doit rouvrir le stockage pour utiliser le nouvel emplacement.")),
    };

    private static void RequireDestination(string destination, string active, long bytes)
    {
        ValidateLocalPath(destination);
        if (LocalStoreRules.DestinationProblem(destination, active) is string problem) { throw new InvalidDataException(problem); }
        if (File.Exists(destination) || Directory.Exists(destination) || File.Exists(StorageWriteFence.Marker(destination))) { throw new IOException("Destination déjà utilisée ; aucun fichier remplacé."); }
        if (!Directory.Exists(System.IO.Path.GetDirectoryName(destination))) { throw new DirectoryNotFoundException("Le dossier choisi doit déjà exister."); }
        var free = new DriveInfo(System.IO.Path.GetPathRoot(destination)!).AvailableFreeSpace;
        if (free < LocalStoreRules.CopyReserve(bytes)) { throw new IOException("Espace insuffisant pour deux copies et la marge de sécurité."); }
    }

    public async Task<WritePlanDraft> PrepareStorageMoveAsync(string destination, CancellationToken cancellationToken)
    {
        var db = await DatabaseAsync(cancellationToken).ConfigureAwait(false);
        var snapshot = await InspectLocalStoreAsync(false, false, cancellationToken).ConfigureAwait(false);
        var original = await db.InspectSwitchSourceAsync(db.Path, false, cancellationToken).ConfigureAwait(false);
        ValidateLocalPath(destination.Trim()); destination = System.IO.Path.GetFullPath(destination.Trim()); RequireDestination(destination, db.Path, original.Bytes + snapshot.WalBytes);
        var draft = StorageWritePlans.MoveDraft(snapshot, destination, new DriveInfo(System.IO.Path.GetPathRoot(destination)!).AvailableFreeSpace);
        return BindSwitch(draft, original, original, destination);
    }

    public async Task<WritePlanDraft> PrepareStorageRestoreAsync(string source, bool registeredBackup, CancellationToken cancellationToken)
    {
        var db = await DatabaseAsync(cancellationToken).ConfigureAwait(false);
        var snapshot = await InspectLocalStoreAsync(false, false, cancellationToken).ConfigureAwait(false);
        if (ReadSwitchState() is { } state && SwitchPending(state)) { throw new InvalidDataException("Terminez la bascule en attente avant une restauration."); }
        var original = await db.InspectSwitchSourceAsync(db.Path, false, cancellationToken).ConfigureAwait(false);
        var copy = registeredBackup ? await db.InspectRegisteredSwitchSourceAsync(source, cancellationToken).ConfigureAwait(false)
            : await db.InspectExternalSwitchSourceAsync(source, cancellationToken).ConfigureAwait(false);
        if (string.Equals(copy.Path, db.Path, StringComparison.OrdinalIgnoreCase)) { throw new InvalidDataException("La base active n’est pas une sauvegarde externe."); }
        var draft = StorageWritePlans.RestoreDraft(snapshot, copy.Backup!, clock.GetUtcNow(), TimeZoneInfo.Local);
        var destination = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(db.Path)!, "Domenia-restauree-" + WritePlans.NewId() + ".db");
        RequireDestination(destination, db.Path, copy.Bytes);
        return BindSwitch(draft, original, copy, destination);
    }

    public Task<WritePlanDraft> PrepareStorageResumeAsync(CancellationToken cancellationToken) => PrepareSwitchContinuation(false, cancellationToken);
    public Task<WritePlanDraft> PrepareStorageRollbackAsync(CancellationToken cancellationToken) => PrepareSwitchContinuation(true, cancellationToken);
    private async Task<WritePlanDraft> PrepareSwitchContinuation(bool rollback, CancellationToken token)
    {
        var db = await DatabaseAsync(token).ConfigureAwait(false);
        var state = ReadSwitchState() ?? throw new InvalidDataException("Aucune bascule enregistrée.");
        var snapshot = await InspectLocalStoreAsync(false, false, token).ConfigureAwait(false);
        if (state.ActivePath != db.Path) { throw new InvalidDataException("Rouvrez le stockage pour retrouver la base sélectionnée."); }
        var original = await db.InspectSwitchSourceAsync(db.Path, false, token).ConfigureAwait(false);
        if (rollback) { await ValidateReturnAsync(db, state, token).ConfigureAwait(false); }
        var draft = rollback ? StorageWritePlans.RollbackDraft(snapshot) : StorageWritePlans.ResumeDraft(snapshot);
        return BindSwitch(draft, original, state.CopySource, rollback || state.Stage is "returning" or "rolledBack" ? state.SourcePath : state.DestinationPath);
    }

    private async Task ValidateSwitchAsync(DomeniaDatabase db, WritePlan plan, SwitchRequest request, CancellationToken token)
    {
        if (plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText || plan.ExpiresAt <= clock.GetUtcNow())
        { throw new InvalidDataException("Plan de bascule expiré ou d’un autre mode."); }
        if (db.Path != request.Original.Path || db.StoreId != request.Original.StoreId || SwitchStateHash() != request.StateHash)
        { throw new InvalidDataException("L’emplacement ou le marqueur a changé depuis la confirmation."); }
        var current = await db.InspectSwitchSourceAsync(db.Path, false, token).ConfigureAwait(false);
        RequireSameSource(request.Original, current);
        if (plan.Kind is StorageWritePlans.Move or StorageWritePlans.Restore)
        {
            if (ReadSwitchState() is { } state && SwitchPending(state)) { throw new InvalidDataException("Une bascule reste à terminer."); }
            RequireDestination(request.Destination, db.Path, request.CopySource.Bytes);
            RequireSameSource(request.CopySource, await db.InspectSwitchSourceAsync(request.CopySource.Path, plan.Kind == StorageWritePlans.Restore, token).ConfigureAwait(false));
        }
        else
        {
            var state = ReadSwitchState() ?? throw new InvalidDataException("Marqueur de bascule absent.");
            if (plan.Kind == StorageWritePlans.Rollback) { await ValidateReturnAsync(db, state, token).ConfigureAwait(false); }
            else if (!SwitchPending(state)) { throw new InvalidDataException("Aucune bascule à reprendre."); }
        }
    }

    private static void RequireSameSource(DomeniaDatabase.SwitchSource expected, DomeniaDatabase.SwitchSource actual)
    {
        if (expected.Path != actual.Path || expected.StoreId != actual.StoreId || expected.Revision != actual.Revision || expected.Fingerprint != actual.Fingerprint || expected.Bytes != actual.Bytes)
        { throw new InvalidDataException("Fichier, identité, révision ou empreinte modifié depuis le plan ; aucune bascule autorisée."); }
    }

    private static async Task ValidateReturnAsync(DomeniaDatabase db, SwitchState state, CancellationToken token)
    {
        var original = await db.InspectSwitchSourceAsync(state.SourcePath, false, token).ConfigureAwait(false);
        if (original.StoreId != state.OriginalStoreId || original.Revision != state.OriginalRevision || original.Fingerprint != state.OriginalFingerprint)
        { throw new InvalidDataException("L’ancienne base a changé ; retour refusé pour préserver les données."); }
        if (File.Exists(state.DestinationPath))
        {
            if (state.Copy is null) { throw new InvalidDataException("Copie présente sans preuve complète ; conservez les fichiers pour récupération."); }
            RequireSameSource(state.Copy, await db.InspectSwitchSourceAsync(state.DestinationPath, true, token).ConfigureAwait(false));
        }
    }

    public async Task<WritePrecheck> CheckStorageSwitchAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        try
        {
            var db = await DatabaseAsync(cancellationToken).ConfigureAwait(false);
            await ValidateSwitchAsync(db, plan, ReadSwitchRequest(plan), cancellationToken).ConfigureAwait(false);
            return WritePrecheck.Valid("Sources, révisions, empreintes et marqueur relus ; l’exclusivité sera acquise avant toute copie.");
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or DomeniaOperationException or UnauthorizedAccessException)
        { return WritePrecheck.Stale(ex.Message); }
    }
}
