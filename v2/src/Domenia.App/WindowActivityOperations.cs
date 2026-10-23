using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.App;

internal sealed record WindowActivityState(bool Visible, bool Active, bool Writing);

/// <summary>Local host state only; reading it never activates a window or starts network work.</summary>
public sealed class WindowActivityOperations : IOperationModule
{
    private static WindowActivityState latest = new(false, false, false);
    internal static WindowActivityState State => Volatile.Read(ref latest);
    internal static void Set(WindowActivityState value) => Volatile.Write(ref latest, value);
    public string Screen => "shell";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
    [
        new("shell.window.activity", OperationClass.LocalRead, (args, _, _) =>
        {
            BridgeArguments.RequireNone(args);
            return Task.FromResult<object?>(State with { Writing = WriteCircuit.From(context).InFlight });
        }, "État local de la fenêtre et présence d’un envoi en cours, sans lecture réseau."),
    ];
}
