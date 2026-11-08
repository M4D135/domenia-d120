namespace Domenia.Core;

/// <summary>The dedicated demonstration cannot be combined with an installer, native worker or production command.</summary>
public static class DemoSessionArguments
{
    public const string Argument = "--demo-session";
    public static bool Requested(IReadOnlyList<string> args) => args.Any(a => a.Equals(Argument, StringComparison.OrdinalIgnoreCase) || a.StartsWith(Argument + "=", StringComparison.OrdinalIgnoreCase));
    public static bool Valid(IReadOnlyList<string> args) => args.Count == 1 && args[0].Equals(Argument, StringComparison.OrdinalIgnoreCase);
    public static ModeDecision Decision() => new(AppMode.Simulation, ModeReason.Demonstration,
        "Démonstration ouverte explicitement dans un espace neuf ; le contexte normal est conservé séparément.",
        "Démonstration — données fictives · example.invalid · aucun accès aux services réels.", null, []);
}
