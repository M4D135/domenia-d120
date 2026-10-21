using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Chooses the operating mode from the command line, the environment and the local join state (SIMULATION.md § 2).</summary>
public static class ModeResolver
{
    public const string SimulationArgument = "--simulation";
    public const string SimulationVariable = "DOMENIA_SIMULATION";

    /// <summary>Pure: the join probe is called only when neither the argument nor the variable decides.</summary>
    public static ModeDecision Resolve(IReadOnlyList<string> arguments, string? variableValue, Func<DomainJoinInfo> probeJoin)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        ArgumentNullException.ThrowIfNull(probeJoin);
        var warnings = ImmutableArray.CreateBuilder<string>();

        var simulationArgument = false;
        var ignoredArguments = 0;
        foreach (var argument in arguments)
        {
            if (string.Equals(argument, SimulationArgument, StringComparison.OrdinalIgnoreCase))
            {
                simulationArgument = true;
            }
            else
            {
                ignoredArguments++;
            }
        }
        // Ignored arguments are counted, never copied: they could carry anything.
        if (ignoredArguments > 0)
        {
            warnings.Add(ModeTexts.WarningArguments(ignoredArguments));
        }

        var variable = variableValue?.Trim();
        var variableOn = string.Equals(variable, "1", StringComparison.Ordinal);
        var variableOff = string.Equals(variable, "0", StringComparison.Ordinal);
        if (!string.IsNullOrEmpty(variable) && !variableOn && !variableOff)
        {
            warnings.Add(ModeTexts.WarningVariable);
        }

        if (simulationArgument)
        {
            return Simulation(ModeReason.Argument, ModeTexts.DetailArgument, warnings);
        }
        if (variableOn)
        {
            return Simulation(ModeReason.Environment, ModeTexts.DetailEnvironment, warnings);
        }
        if (variableOff)
        {
            return new ModeDecision(AppMode.Directory, ModeReason.EnvironmentOptOut, ModeTexts.DetailEnvironmentOptOut, null, null, warnings.ToImmutable());
        }

        var join = probeJoin();
        switch (join.State)
        {
            case DomainJoinState.Joined:
                var name = string.IsNullOrWhiteSpace(join.DomainName) ? null : join.DomainName.Trim();
                var detail = name is null ? ModeTexts.DetailJoinedWithoutName : ModeTexts.DetailDomainJoined(name);
                return new ModeDecision(AppMode.Directory, ModeReason.DomainJoined, detail, null, name, warnings.ToImmutable());
            case DomainJoinState.Workgroup:
            case DomainJoinState.Unjoined:
                return Simulation(ModeReason.NotDomainJoined, ModeTexts.DetailNotDomainJoined, warnings);
            default:
                return Simulation(ModeReason.JoinStateUnknown, ModeTexts.DetailJoinStateUnknown, warnings);
        }
    }

    private static ModeDecision Simulation(ModeReason reason, string detail, ImmutableArray<string>.Builder warnings) =>
        new(AppMode.Simulation, reason, detail, ModeTexts.Banner, null, warnings.ToImmutable());
}
