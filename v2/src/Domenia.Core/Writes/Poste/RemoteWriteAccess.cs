using System.Collections.Immutable;

namespace Domenia.Core.Poste;

public sealed record RemoteWriteDecision(bool Allowed, ImmutableArray<string> Reasons)
{
    public void Require()
    {
        if (!Allowed) throw new DomeniaOperationException("remote.writeBlocked", string.Join(" ", Reasons) + " Aucun envoi effectué.");
    }
}

/// <summary>One closed policy for remote plans and their actual sends. A confirmed plan is the V2 write permission;
/// Session.ReadOnly describes ordinary browsing, not a global permanent write mode.</summary>
public static class RemoteWriteAccess
{
    public static bool IsRemoteKind(string kind) => kind is PosteRemoteWrites.RestartKind or PosteRemoteWrites.RestartCancelKind
        or PosteRemoteWrites.GpUpdateKind or PosteRemoteWrites.ServiceKind or PosteRemoteWrites.RunKind or PosteRemoteWrites.WakeKind;
    public static RemoteWriteDecision Evaluate(AppMode mode, SessionSnapshot session, bool inFlight = false, int pending = 0,
        int unreadable = 0, bool requiresWinRm = false, bool winRmEnabled = true, bool executorAvailable = true)
    {
        var reasons = ImmutableArray.CreateBuilder<string>();
        // Simulation has its own in-memory executors. This decision never authorizes a real transport in that mode.
        if (mode != AppMode.Simulation)
        {
            if (session.Connection != ConnectionState.Connected) reasons.Add("Annuaire non connecté : sélection locale seulement.");
            if (session.DirectoryAvailability.State is DirectoryAvailabilityState.Offline or DirectoryAvailabilityState.Slow)
                reasons.Add("Annuaire indisponible ou trop lent : identité à revérifier avant intervention.");
            if (!session.Administration.AllowsRemote) reasons.Add(session.Administration.Detail);
        }
        if (inFlight) reasons.Add("Une écriture est en cours.");
        if (pending > 0) reasons.Add("Une écriture reste à vérifier dans Opérations.");
        if (unreadable > 0 || pending < 0 || unreadable < 0) reasons.Add("État des reçus indisponible.");
        if (requiresWinRm && !winRmEnabled) reasons.Add("WinRM est désactivé par la configuration.");
        if (!executorAvailable) reasons.Add("Exécuteur indisponible pour cette action.");
        return new(reasons.Count == 0, reasons.ToImmutable());
    }
}
