namespace Domenia.Inventory;

public sealed partial class RemoteTaskReadRunner
{
    private static readonly Lock AdmissionGate = new();
    private static int closing;
    public static int ActiveReads => Hosts.Count;

    /// <summary>Atomically fences new reads and cleanup workers; dispose only if closing is cancelled.</summary>
    public static IDisposable SuspendNewReads()
    {
        lock (AdmissionGate) { closing++; return new ClosingLease(); }
    }

    private static void Admit(string host)
    {
        lock (AdmissionGate)
        {
            if (closing != 0) { throw new Domenia.Core.DomeniaOperationException("poste.closing", "Fermeture en cours ; aucune nouvelle tâche distante."); }
            if (!Hosts.TryAdd(host, 0)) { throw Busy(); }
            if (!Slots.Wait(0)) { Hosts.TryRemove(host, out _); throw Busy(); }
        }
    }

    private sealed class ClosingLease : IDisposable
    {
        private bool released;
        public void Dispose() { lock (AdmissionGate) { if (!released) { released = true; closing--; } } }
    }
}
