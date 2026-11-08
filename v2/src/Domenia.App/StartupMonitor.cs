using System.Globalization;

namespace Domenia.App;

// BCL only: also used by the OS bootstrap before any product library is admitted.
internal sealed class StartupMonitor(TimeProvider clock)
{
    private readonly Lock gate = new();
    private readonly long started = clock.GetTimestamp();
    private long phaseStarted = clock.GetTimestamp();
    private string phase = "Vérification de l’intégrité du paquet…";
    private readonly Queue<string> history = new();
    internal void Phase(string value)
    {
        lock (gate)
        {
            if (value == phase) return;
            if (history.Count == 32) history.Dequeue();
            history.Enqueue(Describe(false, 8));
            phase = StartupBootstrap.Clean(value); phaseStarted = clock.GetTimestamp();
        }
    }
    internal string Describe(bool cancelled, int warningSeconds)
    {
        lock (gate)
        {
            var now = clock.GetTimestamp();
            var stage = clock.GetElapsedTime(phaseStarted, now).TotalSeconds;
            var total = clock.GetElapsedTime(started, now).TotalSeconds;
            return (cancelled ? "Annulation demandée. Attente de la fin du travail en cours…" : phase)
                + "\r\nÉtape : " + stage.ToString("F0", CultureInfo.InvariantCulture) + " s · Total : " + total.ToString("F0", CultureInfo.InvariantCulture) + " s."
                + (!cancelled && stage >= Math.Clamp(warningSeconds, 1, 120) ? " L’opération est toujours active ; aucune durée restante n’est estimée." : "");
        }
    }
    internal string Diagnostic { get { lock (gate) return string.Join("\r\n\r\n", history.Append(Describe(false, 8))); } }
}
