using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdPosteReader : IPosteTaskReadJournalReader
{
    private static bool ConfirmedTaskWorkstation(AdEntry entry) => entry.Raw("userAccountControl").Count == 1
        && entry.Long("userAccountControl") is >= 0 and <= uint.MaxValue and var flags && (flags & AdValues.ServerTrustAccount) == 0;

    public async Task<ImmutableArray<RemoteTaskPending>> PendingTaskReadsAsync(string computerDn, CancellationToken cancellationToken)
    {
        var local = await LocalAsync(computerDn, cancellationToken).ConfigureAwait(false);
        if (source.LocalStore is not IRemoteTaskReadJournal journal) { return []; }
        var pending = await journal.PendingTaskReadsAsync(cancellationToken).ConfigureAwait(false); EnsureEpoch(local.Epoch);
        return [.. pending.Where(r => MatchesCleanup(local, r.Plan)).Select(r => new RemoteTaskPending(r.Plan.Id, r.Plan.PreparedAt, r.Plan.Account,
            r.Completion?.ResultReceived == true, r.Completion?.ExecutionStopped == true, r.Completion?.Detail ?? "Préparation enregistrée, aucun achèvement confirmé."))];
    }

    private static bool MatchesCleanup(LocalPoste local, RemoteTaskReadPlan plan) => plan.StoreId == local.Fleet.Facts.StoreId
        && plan.ComputerGuid == local.Computer.ObjectGuid && DistinguishedName.AreEqual(plan.ComputerDn, local.Computer.DistinguishedName)
        && plan.ComputerCreated == local.Computer.WhenCreated && string.Equals(plan.Host, local.Computer.DnsHostName, StringComparison.OrdinalIgnoreCase)
        && (local.Computer.UserAccountControl & AdValues.ServerTrustAccount) == 0;

    internal async Task<RemoteTaskReadRecord> CleanupRecordAsync(string dn, Guid operationId, bool verifyNetwork, CancellationToken token)
    {
        var local = await LocalAsync(dn, token).ConfigureAwait(false);
        if (source.LocalStore is not IRemoteTaskReadJournal journal) { throw WriteErrors.Refusal(WriteErrors.Stale, "Journal local indisponible."); }
        var record = await journal.ReadTaskReadAsync(operationId, token).ConfigureAwait(false);
        if (record is null || !MatchesCleanup(local, record.Plan))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Opération absente ou identité du poste différente ; aucun nettoyage."); }
        if (verifyNetwork)
        {
            using var directory = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, dn, token).ConfigureAwait(false);
            using var machine = await AdWorkstationAccess.AcquireAsync(source, record.Plan.Host, token).ConfigureAwait(false);
            var parent = await SecretComputerAsync(local, directory, ["objectGUID", "objectClass", "objectSid", "whenCreated", "dNSHostName", "sAMAccountName", "userAccountControl"], token).ConfigureAwait(false);
            if (parent.Time("whenCreated") != local.Computer.WhenCreated || parent.Sid("objectSid") != local.Computer.Sid
                || !ConfirmedTaskWorkstation(parent)
                || !string.Equals(parent.String("dNSHostName"), record.Plan.Host, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(parent.String("sAMAccountName"), local.Computer.SamAccountName, StringComparison.OrdinalIgnoreCase))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Identité AD du poste modifiée ; aucun nettoyage."); }
            var session = await source.GetSessionAsync(token).ConfigureAwait(false);
            if (!string.Equals(machine.Credential.Account ?? session.Account.Login, record.Plan.Account, StringComparison.OrdinalIgnoreCase))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Sélectionnez le compte d’origine pour vérifier les artefacts de cette opération."); }
            directory.EnsureCurrent(); machine.EnsureCurrent();
        }
        EnsureEpoch(local.Epoch);
        return record;
    }

    internal async Task<RemoteTaskCleanupResult> ExecuteCleanupAsync(RemoteTaskReadRecord expected, CancellationToken token)
    {
        var plan = expected.Plan;
        var current = await CleanupRecordAsync(plan.ComputerDn, plan.Id, true, token).ConfigureAwait(false);
        if (current != expected) { throw WriteErrors.Refusal(WriteErrors.Stale, "Reçu modifié pendant la confirmation ; préparez un nouveau plan."); }
        var epoch = source.Epoch;
        using var machine = await AdWorkstationAccess.AcquireAsync(source, plan.Host, token).ConfigureAwait(false);
        return await (TaskReadRunnerFactory?.Invoke() ?? new RemoteTaskReadRunner(source.Clock))
            .RecoverCleanupAsync(plan, (IRemoteTaskReadJournal)source.LocalStore!, machine.Credential, async ct =>
            {
                EnsureEpoch(epoch); machine.EnsureCurrent();
                var reread = await CleanupRecordAsync(plan.ComputerDn, plan.Id, true, ct).ConfigureAwait(false);
                EnsureEpoch(epoch); machine.EnsureCurrent();
                return reread == expected;
            }, token).ConfigureAwait(false);
    }
}
