namespace Domenia.Core;

/// <summary>Result of the app.info operation (docs/OPERATIONS.md § 2).</summary>
public sealed record AppInfo(
    string Name,
    string Version,
    string Runtime,
    string WebViewRuntime,
    string Mode,
    string ModeLabel,
    ModeReason ModeReason,
    string ModeDetail,
    string? Banner);

public static class AppInfoBuilder
{
    public const string SimulationModeText = "simulation";
    public const string DirectoryModeText = "annuaire";

    /// <summary>Builds app.info from the startup decision; the banner is set only in simulation.</summary>
    public static AppInfo Build(ModeDecision decision, string runtime, string webViewRuntime)
    {
        ArgumentNullException.ThrowIfNull(decision);
        var simulation = decision.Mode == AppMode.Simulation;
        return new AppInfo(
            ProductInfo.Name,
            ProductInfo.Version,
            runtime,
            webViewRuntime,
            simulation ? SimulationModeText : DirectoryModeText,
            simulation ? ModeTexts.SimulationLabel : ModeTexts.DirectoryLabel,
            decision.Reason,
            decision.Detail,
            simulation ? decision.Banner ?? ModeTexts.Banner : null);
    }
}
