using Domenia.Core;

namespace Domenia.App;

internal enum HostPhase { Starting, Running, Closing }

/// <summary>Same incident reference in the durable log and native report. Diagnostic failure never claims a path
/// was written; the fallback is bounded and masked before any native dialog receives it.</summary>
internal sealed record HostIncidentReport(string Code, HostPhase Phase, string Title, string Message, string? JournalPath)
{
    private static int phase;
    public static HostPhase CurrentPhase => (HostPhase)Volatile.Read(ref phase);
    public static void Starting() => Volatile.Write(ref phase, (int)HostPhase.Starting);
    public static void SessionShown() => Interlocked.CompareExchange(ref phase, (int)HostPhase.Running, (int)HostPhase.Starting);
    public static void Closing() => Volatile.Write(ref phase, (int)HostPhase.Closing);
    public static void CancelClosing(HostPhase previous) => Interlocked.CompareExchange(ref phase, (int)previous, (int)HostPhase.Closing);

    public static HostIncidentReport Create(Exception failure, Action<string> log, Func<bool> flush,
        Func<TechnicalJournalStatus> status, bool expert = false)
    {
        var at = CurrentPhase;
        var code = "INC-" + Guid.NewGuid().ToString("N").ToUpperInvariant();
        var title = at switch { HostPhase.Starting => "Démarrage interrompu", HostPhase.Closing => "Fermeture incomplète", _ => "Incident de l’application" };
        var text = at switch
        {
            HostPhase.Starting => "Domenia n’a pas pu terminer son démarrage.",
            HostPhase.Closing => "Domenia a rencontré un incident pendant sa fermeture. Les données déjà enregistrées restent conservées ; la fin des travaux encore actifs n’est pas confirmée.",
            _ => "Domenia a rencontré une erreur imprévue et va se fermer.",
        };
        var detail = Detail(failure);
        string? path = null;
#pragma warning disable CA1031 // An incident report must also work when the logger itself failed.
        try
        {
            log(code + " · Hôte · " + title + " · " + detail);
            if (flush())
            {
                var saved = status();
                if (saved.Pending == 0 && saved.State is "ready" or "fallback" && saved.Path is { Length: > 0 } actual)
                    path = actual;
            }
        }
        catch (Exception) { /* No durable path can be claimed. The masked fallback below remains available. */ }
#pragma warning restore CA1031
        var body = text + "\n\nRéférence : " + code + (path is null
            ? "\nJournal non confirmé. Conservez cette référence et le détail masqué ci-dessous.\n\n" + detail
            : "\nJournal : " + path + (expert ? "\n\nDétail masqué :\n" + detail : ""));
        return new(code, at, title, body, path);
    }

    private static string Detail(Exception failure)
    {
#pragma warning disable CA1031 // Exception getters and masking are observers, not part of shutdown ownership.
        try
        {
            var type = failure.GetType().Name;
            var message = failure.Message;
            var stack = failure.StackTrace ?? "";
            if (message.Length > 8192 || stack.Length > 8192 || message.Length + stack.Length > 8192)
                return type + " : détail hors limites, contenu non affiché.";
            return SupportSecretMask.Protect(type + ": " + message + (stack.Length == 0 ? "" : "\n" + stack));
        }
        catch (Exception) { return "Détail indisponible ; aucun contenu non masqué affiché."; }
#pragma warning restore CA1031
    }
}
