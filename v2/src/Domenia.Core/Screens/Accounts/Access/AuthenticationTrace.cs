using System.Globalization;

namespace Domenia.Core;

public enum AuthenticationStage { Validation, ControllerAndBind, RootDse, DomainIdentity, AccountIdentity, SessionQueue, TransportQueue, ControllerSetup, Bind }

/// <summary>Closed, bounded, flow-local diagnostic. No API accepts an account, secret, exception, endpoint or arbitrary text.</summary>
public sealed class AuthenticationTrace(TimeProvider provider)
{
    private readonly TimeProvider clock = provider;
    private static readonly AsyncLocal<AuthenticationTrace?> Current = new();
    private readonly Lock gate = new();
    private readonly Queue<string> lines = new();
    private readonly long started = provider.GetTimestamp();
    private bool finished;
    public IDisposable Attach()
    {
        var before = Current.Value; Current.Value = this;
        return new Once(() => Current.Value = before);
    }
    public static IDisposable Step(AuthenticationStage stage)
    {
        var trace = Current.Value;
        if (trace is null) return new Once(static () => { });
        var start = trace.clock.GetTimestamp(); trace.Append(Label(stage) + " : début");
        return new Once(() => trace.Append(Label(stage) + " : fin d’étape (" + trace.clock.GetElapsedTime(start).TotalMilliseconds.ToString("F0", CultureInfo.InvariantCulture) + " ms)"));
    }
    public static void NativeAuthentication(int? subcode)
    {
        var safe = subcode is 0x525 or 0x52e or 0x52f or 0x530 or 0x531 or 0x532 or 0x533 or 0x701 or 0x773 or 0x775;
        Current.Value?.Append("Authentification : LDAP 49" + (safe ? " / 0x" + subcode!.Value.ToString("X", CultureInfo.InvariantCulture) : "") + ". Diagnostic serveur libre non conservé.");
    }
    public void CancellationRequested() => Append("Annulation demandée ; aucun appel Windows arrêté de force.");
    public void Finish(bool cancelled, bool failed)
    {
        lock (gate)
        {
            if (finished) return;
            Append(cancelled ? "Validation annulée ; les travaux natifs encore retenus terminent leur nettoyage."
                : failed ? "Validation non confirmée ; consultez le résultat de l’opération." : "Validation terminée ; droits sur les ressources non déduits.");
            finished = true;
        }
    }
    public double ElapsedMilliseconds => clock.GetElapsedTime(started).TotalMilliseconds;
    public string Text { get { lock (gate) return string.Join(Environment.NewLine, lines); } }
    private void Append(string text)
    {
        lock (gate)
        {
            if (finished) return;
            if (lines.Count == 128) lines.Dequeue();
            lines.Enqueue(clock.GetUtcNow().ToString("O", CultureInfo.InvariantCulture) + " +" + clock.GetElapsedTime(started).TotalMilliseconds.ToString("F0", CultureInfo.InvariantCulture) + " ms — " + text);
        }
    }
    private static string Label(AuthenticationStage stage) => stage switch
    {
        AuthenticationStage.SessionQueue => "Attente de la connexion de session",
        AuthenticationStage.TransportQueue => "Attente du transport LDAP",
        AuthenticationStage.ControllerSetup => "Préparation du contrôleur LDAP (découverte Windows possible pendant Bind)",
        AuthenticationStage.Bind => "Liaison LDAP (résolution Windows incluse si nécessaire)",
        AuthenticationStage.ControllerAndBind => "Résolution du contrôleur et liaison LDAP",
        AuthenticationStage.RootDse => "Lecture RootDSE",
        AuthenticationStage.DomainIdentity => "Qualification du domaine",
        AuthenticationStage.AccountIdentity => "Lecture de l’identité du compte",
        _ => "Validation",
    };
    private sealed class Once(Action action) : IDisposable
    {
        private Action? remaining = action;
        public void Dispose() => Interlocked.Exchange(ref remaining, null)?.Invoke();
    }
}
