namespace Domenia.App;

/// <summary>One attempt per explicitly opened window. A refusal or a user departure consumes the opportunity.</summary>
internal sealed class StartupActivation
{
    private int attempted;
    private int switchedAway;
    internal void UserSwitchedAway() => Interlocked.Exchange(ref switchedAway, 1);
    internal string TryActivate(bool foregroundBelongsToProcess, Func<bool> activate)
    {
        if (Interlocked.Exchange(ref attempted, 1) != 0) return "déjà traitée";
        if (Volatile.Read(ref switchedAway) != 0) return "session Windows quittée ; aucune activation";
        if (!foregroundBelongsToProcess) return "autre fenêtre au premier plan ; aucune activation";
        return activate() ? "premier plan obtenu" : "activation refusée par Windows ; aucune nouvelle tentative";
    }
}
