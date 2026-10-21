using Domenia.Core;

namespace Domenia.App;

/// <summary>The technical journal of the host (<see cref="TechnicalLog"/>) as seen by the engine services.</summary>
internal sealed class AppTechnicalJournal : ITechnicalJournal
{
    public static AppTechnicalJournal Instance { get; } = new();

    public void Info(string message) => TechnicalLog.Info(message);

    public void Warning(string message) => TechnicalLog.Warning(message);

    public void Error(string message, Exception exception) => TechnicalLog.Error(message, exception);
}
