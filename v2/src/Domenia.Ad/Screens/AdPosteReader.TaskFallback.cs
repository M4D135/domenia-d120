using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    private sealed record TaskFallback(RemoteTaskReadResult? Result, string Notice, string? Action = null);
    private async Task<TaskFallback> ReadTaskFallbackAsync(LocalPoste local, AdWorkstationAccess machine, RemoteTaskReadKind kind,
        SoftwareRequest? software, bool authenticationRejected, CancellationToken token)
    {
        token.ThrowIfCancellationRequested(); machine.EnsureCurrent(); EnsureEpoch(local.Epoch);
        if (authenticationRejected) { return new(null, "Authentification rejetée ; aucun repli ni autre compte essayé."); }
        if (!machine.Settings.UseTaskFallback) { return new(null, "Repli par tâche désactivé dans la configuration."); }
        if ((local.Computer.UserAccountControl & AdValues.ServerTrustAccount) != 0) { return new(null, "Contrôleur de domaine : aucune tâche de lecture créée."); }
        if (source.LocalStore is not IRemoteTaskReadJournal journal) { return new(null, "Journal local durable indisponible ; aucun artefact créé."); }
        var session = await source.GetSessionAsync(token).ConfigureAwait(false); var consent = PosteSession.For(source);
        consent.EnsureSession(session.Account.Login + "|" + (session.Domain?.DnsName ?? "") + "|" + session.Epoch.ToString(System.Globalization.CultureInfo.InvariantCulture), source.Clock.GetUtcNow());
        var dn = local.Computer.DistinguishedName;
        if (!consent.Covers(ConsentKind.ReadFallback, dn, source.Clock.GetUtcNow(), local.Computer.ObjectGuid))
        { return new(null, "Sources non lues par CIM. Une lecture ponctuelle sous SYSTEM peut être autorisée pour ce poste (jusqu’à 45 s supplémentaires, tâche et fichiers temporaires journalisés).", "readFallback"); }
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(45), source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token, timeout.Token);
        using var directory = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, dn, stop.Token).ConfigureAwait(false);
        async Task Confirm(CancellationToken ct)
        {
            var parent = await SecretComputerAsync(local, directory, ["objectGUID", "objectClass", "objectSid", "whenCreated", "dNSHostName", "sAMAccountName", "userAccountControl"], ct).ConfigureAwait(false);
            if (parent.Time("whenCreated") != local.Computer.WhenCreated || parent.Sid("objectSid") != local.Computer.Sid || !ConfirmedTaskWorkstation(parent)
                || !string.Equals(parent.String("dNSHostName"), local.Computer.DnsHostName, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(parent.String("sAMAccountName"), local.Computer.SamAccountName, StringComparison.OrdinalIgnoreCase))
            { throw new DomeniaOperationException(PosteErrors.ComputerUnknown, "Identité AD modifiée ; résultat de tâche non attribué au poste."); }
            directory.EnsureCurrent(); machine.EnsureCurrent(); EnsureEpoch(local.Epoch); ct.ThrowIfCancellationRequested();
        }
        await Confirm(stop.Token).ConfigureAwait(false);
        var plan = RemoteTaskReadRunner.PreparePlan(local.Computer, local.Fleet.Facts.StoreId, machine.Credential.Account ?? session.Account.Login, source.Clock.GetUtcNow(), kind, software);
        var remote = await (TaskReadRunnerFactory?.Invoke() ?? new RemoteTaskReadRunner(source.Clock)).RunAsync(plan, journal, machine.Credential, async ct =>
        {
            await Confirm(ct).ConfigureAwait(false);
            await EnsureTaskWriteStateAsync(local.Computer.ObjectGuid, ct).ConfigureAwait(false);
            return consent.ConsumeReadFallback(dn, kind == RemoteTaskReadKind.Software ? "logiciels" : kind == RemoteTaskReadKind.Diagnostic ? "diagnostic" : "inventaire", source.Clock.GetUtcNow(), local.Computer.ObjectGuid);
        }, stop.Token).ConfigureAwait(false);
        directory.EnsureCurrent(); machine.EnsureCurrent(); EnsureEpoch(local.Epoch);
        var notice = "Opération " + plan.Id.ToString("N") + ". " + remote.Reading.Access.Detail + " " + remote.Notice
            + (remote.CleanupConfirmed ? " Nettoyage distant confirmé." : " Nettoyage distant non confirmé : reçu conservé ; consultez Intervenir avant tout nouveau repli.");
        if (remote.Reading.Access.Status == SourceStatus.Refused || remote.Reading.Access.AuthenticationRejected)
        { machine.Refused(plan.Host, "Lecture ponctuelle SYSTEM", remote.Reading.Access.AuthenticationRejected); }
        if (remote.WorkerPending || remote.Inventory is null && remote.Software is null) { return new(remote, notice); }
        ConfirmIdentity(local.Computer, remote.Reading.ReportedName);
        try { await Confirm(stop.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return new(remote with { Inventory = null, Software = null }, notice + " Identité AD finale non relue après arrêt ; données de repli écartées."); }
        return new(remote, notice);
    }

    private async Task EnsureTaskWriteStateAsync(Guid computer, CancellationToken token)
    {
        if (source.AccountContext is not { } context) { return; }
        var log = await context.Receipts.ReadAllAsync(token).ConfigureAwait(false);
        if (log.Unreadable != 0 || WriteCircuit.From(context).InFlight
            || log.Receipts.Any(r => WriteReceipts.IsPending(r) && string.Equals(r.Plan.Target.ObjectGuid, computer.ToString("D"), StringComparison.OrdinalIgnoreCase)))
        { throw new DomeniaOperationException(PosteErrors.Pending, "Écriture active, incertaine ou reçus illisibles ; aucune tâche de lecture créée."); }
    }

    internal static bool NeedsTaskFallback(InventorySnapshot value) => value.Access.Any(a => a.Status is SourceStatus.Refused or SourceStatus.Unavailable or SourceStatus.Unreachable or SourceStatus.Error or SourceStatus.Partial);

    internal static InventorySnapshot MergeTaskInventory(InventorySnapshot direct, InventorySnapshot fallback)
    {
        bool Take(string category) => fallback.Read(category) && (!direct.Read(category)
            || fallback.StatusOf(category) is SourceStatus.Ok or SourceStatus.Empty && direct.StatusOf(category) is not (SourceStatus.Ok or SourceStatus.Empty));
        var keys = fallback.Access.Where(a => Take(a.Category)).Select(a => a.Category).ToHashSet(StringComparer.Ordinal);
        bool Pick(string c) => keys.Contains(c);
        return direct with
        {
            CollectedAt = fallback.CollectedAt, ReportedName = fallback.ReportedName,
            DurationMs = (int)Math.Min((long)direct.DurationMs + fallback.DurationMs, int.MaxValue),
            Access = [.. direct.Access.Where(a => !keys.Contains(a.Category)), .. fallback.Access.Where(a => keys.Contains(a.Category))],
            Os = Pick(InventoryCategories.System) ? fallback.Os : direct.Os,
            System = Pick(InventoryCategories.System) ? fallback.System : direct.System,
            Console = Pick(InventoryCategories.System) ? fallback.Console : direct.Console,
            Memory = Pick(InventoryCategories.System) ? fallback.Memory : direct.Memory,
            Bios = Pick(InventoryCategories.Bios) ? fallback.Bios : direct.Bios,
            SecureBoot = Pick(InventoryCategories.Bios) ? fallback.SecureBoot : direct.SecureBoot,
            Processors = Pick(InventoryCategories.Processor) ? fallback.Processors : direct.Processors,
            MemoryModules = Pick(InventoryCategories.Memory) ? fallback.MemoryModules : direct.MemoryModules,
            MemoryArray = Pick(InventoryCategories.Memory) ? fallback.MemoryArray : direct.MemoryArray,
            Volumes = Pick(InventoryCategories.Volumes) ? fallback.Volumes : direct.Volumes,
            Network = Pick(InventoryCategories.Network) ? fallback.Network : direct.Network,
            Tpm = Pick(InventoryCategories.Tpm) ? fallback.Tpm : direct.Tpm,
            BitLocker = Pick(InventoryCategories.BitLocker) ? fallback.BitLocker : direct.BitLocker,
            Antivirus = Pick(InventoryCategories.Antivirus) ? fallback.Antivirus : direct.Antivirus,
            Defender = Pick(InventoryCategories.Antivirus) ? fallback.Defender : direct.Defender,
            Hotfixes = Pick(InventoryCategories.Hotfixes) ? fallback.Hotfixes : direct.Hotfixes,
            Services = Pick(InventoryCategories.Services) ? fallback.Services : direct.Services,
            PendingReboot = Pick(InventoryCategories.Reboot) ? fallback.PendingReboot : direct.PendingReboot,
        };
    }
}
