using Domenia.Bridge;
using Domenia.Core;
using Domenia.App.Settings;

namespace Domenia.App;

internal sealed record DemoSessionStatus(bool Active, bool Available, bool Busy, string Domain, string Message);

/// <summary>A control request schedules a host transition after its Bridge response; it never drains its own request.</summary>
internal sealed class DemoSessionHost(AppMode mode)
{
    private Action<string>? schedule;
    private int busy;
    public void Attach(Action<string> action) => schedule = action;
    public DemoSessionStatus Status() => new(DemoSessionProcess.Active, schedule is not null && !HostFacts.Unattended,
        Volatile.Read(ref busy) != 0, DemoSessionProcess.Active ? "example.invalid" : "",
        DemoSessionProcess.Active ? "Démonstration — données fictives. Réinitialiser ne change que cet espace ; quitter retrouve la fenêtre précédente."
            : "Ouvrez un espace fictif neuf. Les opérations en cours doivent se terminer ; votre contexte reste dans cette fenêtre.");
    public object Request(string action)
    {
        if (HostFacts.Unattended || schedule is null) throw new DomeniaOperationException("demo.unavailable", "Commande de démonstration indisponible dans cette fenêtre pilotée.");
        if (action is not ("open" or "reset" or "exit") || action == "open" && DemoSessionProcess.Active || action != "open" && !DemoSessionProcess.Active)
            throw new DomeniaOperationException("demo.context", "Cette commande ne correspond pas à l’espace affiché.");
        if (action != "open" && mode != AppMode.Simulation) throw new DomeniaOperationException("demo.context", "Aucun contexte réel ne peut être réinitialisé par la démonstration.");
        if (Interlocked.CompareExchange(ref busy, 1, 0) != 0) throw new DomeniaOperationException("demo.busy", "Une transition de démonstration est déjà en cours.");
        try { schedule(action); }
        catch { Finish(); throw; }
        return new { accepted = true, message = "Transition demandée ; les opérations en cours sont qualifiées avant toute bascule." };
    }
    public void Finish() => Volatile.Write(ref busy, 0);
}

public sealed class DemoSessionHostOperations : IOperationModule
{
    public string Screen => "settings";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        var host = context.Shared(static c => new DemoSessionHost(c.Mode));
        return
        [
            new("settings.demo.session", OperationClass.Local, (args, _, _) =>
            { BridgeArguments.RequireNone(args); return Task.FromResult<object?>(host.Status()); }, "État de l’espace fictif et des commandes de démonstration."),
            Command("open"), Command("reset"), Command("exit"),
        ];
        OperationDefinition Command(string action) => new("settings.demo." + action, OperationClass.Local, (args, _, _) =>
        { BridgeArguments.RequireNone(args); return Task.FromResult<object?>(host.Request(action)); }, "Transition explicite de démonstration, après suspension vérifiée du moteur.");
    }
}
