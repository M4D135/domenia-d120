using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdDirectorySource
{
    private readonly HashSet<ConnectionRetirement> connectionRetirements = [];
    private void DrainConnectionRetirements()
    {
        ConnectionRetirement[] held;
        lock (gate) held = [.. connectionRetirements];
        foreach (var retirement in held) retirement.Dispose();
    }
    private sealed class ConnectionRetirement(AdDirectorySource owner, IAdConnection? previous, AdSyncState? synchronization) : IDisposable
    {
        private readonly Lock cleanupGate = new();
        public void Dispose()
        {
            lock (cleanupGate)
            {
                // A cleanup failure cannot turn a committed login into a refusal or close the new connection.
                // Keep failed owners reachable and bounded; the final source close attempts their cleanup again.
                try { previous?.Dispose(); previous = null; }
                catch (Exception) { Notice("Connexion remplacée : nettoyage de l’ancien transport non confirmé ; propriétaire conservé."); }
                try { synchronization?.Dispose(); synchronization = null; }
                catch (Exception) { Notice("Connexion remplacée : nettoyage de l’ancien état de synchronisation non confirmé ; propriétaire conservé."); }
                if (previous is null && synchronization is null) { lock (owner.gate) owner.connectionRetirements.Remove(this); }
            }
        }
        private void Notice(string message)
        { try { owner.AccountContext?.Log.Warning(message); } catch (Exception) { /* Logging cannot undo a committed login. */ } }
    }
}
