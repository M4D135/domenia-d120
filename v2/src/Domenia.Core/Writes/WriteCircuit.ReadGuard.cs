namespace Domenia.Core;

public sealed partial class WriteCircuit
{
    private long consultationVersion;

    /// <summary>Refuses new consultation while a write runs or its durable outcome needs review. Never verifies or replays.</summary>
    public async Task<long> EnsureConsultationAllowedAsync(CancellationToken cancellationToken)
    {
        var version = Interlocked.Read(ref consultationVersion);
        if (InFlight) throw ConsultationBusy();
        var (all, unreadable) = await ReadAsync("Reçus illisibles : ouvrez Opérations avant de reprendre la consultation.", cancellationToken).ConfigureAwait(false);
        if (InFlight || version != Interlocked.Read(ref consultationVersion)) throw ConsultationBusy();
        if (unreadable != 0 || all.Any(WriteReceipts.IsPending))
            throw WriteErrors.Refusal("read.receiptsPending", "Une écriture reste à vérifier : ouvrez son reçu dans Opérations avant de reprendre la consultation. Aucun nouvel envoi.");
        return version;
    }

    public async Task EnsureConsultationUnchangedAsync(long version, CancellationToken cancellationToken)
    {
        if (await EnsureConsultationAllowedAsync(cancellationToken).ConfigureAwait(false) != version) throw ConsultationBusy();
    }

    /// <summary>Use the same receipt evidence as send admission, including the live native link before offering cancellation.</summary>
    public async Task<(int Pending, int CancelPending, int Unreadable)> RemotePendingAsync(SessionSnapshot session, string? dn, CancellationToken token)
    {
        var (rows, unreadable) = await ReadAsync(WriteErrors.ReceiptsUnreadableMessage, token).ConfigureAwait(false);
        var waiting = rows.Where(WriteReceipts.IsPending).ToArray();
        var cancel = writers.ForKind(Poste.PosteRemoteWrites.RestartCancelKind) as Poste.IPosteRestartCancelExecutor;
        var simulated = mode == AppMode.Simulation;
        var modeText = simulated ? AppInfoBuilder.SimulationModeText : AppInfoBuilder.DirectoryModeText;
        var covered = waiting.Count(r => WriteReceiptStates.CancellationCandidate(r, dn, session.Account.Login, session.Controller?.DnsName, modeText, simulated)
            && cancel?.OwnsPendingRestart(r.Plan) == true);
        return (waiting.Length, waiting.Length - covered, unreadable);
    }

    private static DomeniaOperationException ConsultationBusy() => WriteErrors.Refusal("read.writeBusy",
        "Une écriture est en cours ou vient de modifier les données : attendez son reçu, puis relancez la consultation.");
}
