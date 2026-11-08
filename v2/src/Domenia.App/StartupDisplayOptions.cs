using Domenia.Core;

namespace Domenia.App;

internal sealed record StartupDisplayOptions(bool Show, bool KeepUntilReady, int WarningSeconds)
{
    internal static StartupDisplayOptions Read(ConfigurationReport report)
    {
        bool Flag(string key) => report.Sections.FirstOrDefault(section => section.Id == "Startup")?.Entries
            .FirstOrDefault(entry => entry.Key == key)?.Value != "false";
        return new(Flag("ShowMonitor"), Flag("KeepMonitorUntilReady"), ConfigurationRules.Integer(report, "Startup", "WarnStageSeconds", 8));
    }
}
