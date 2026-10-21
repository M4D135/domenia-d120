using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.App;

/// <summary>
/// Wiring of the engine for the chosen mode. Nothing heavy happens here: the simulated world is generated on first use,
/// off the UI thread, and the directory mode reads nothing until Domenia.Ad is wired.
/// </summary>
internal sealed class Composition : IDisposable
{
    private readonly DashboardService dashboard;

    private Composition(ModeDecision decision, DashboardService dashboard, OperationRegistry registry)
    {
        Decision = decision;
        this.dashboard = dashboard;
        Registry = registry;
        Admission = AdmissionGuards.For(decision.Mode);
    }

    public ModeDecision Decision { get; }

    public OperationRegistry Registry { get; }

    public Func<OperationDefinition, BridgeError?>? Admission { get; }

    public string WindowTitle => Decision.Mode == AppMode.Simulation ? ProductInfo.Name + ModeTexts.WindowTitleSuffix : ProductInfo.Name;

    public static Composition Create(ModeDecision decision)
    {
        ArgumentNullException.ThrowIfNull(decision);
        IDirectorySource source = decision.Mode == AppMode.Simulation
            ? new SimulatedDirectorySource(SimulationOptions.Default, TimeProvider.System)
            : new UnavailableDirectorySource(decision.JoinedDomain, static () => Environment.UserDomainName + "\\" + Environment.UserName);
        var dashboard = new DashboardService(source, new OperationJournal(), TimeProvider.System);
        var info = AppInfoBuilder.Build(decision, Environment.Version.ToString(), AppPaths.WebViewRuntime is null ? "windows" : "embarque");
        return new Composition(decision, dashboard, HostOperations.CreateRegistry(info, dashboard));
    }

    public void Dispose() => dashboard.Dispose();
}
