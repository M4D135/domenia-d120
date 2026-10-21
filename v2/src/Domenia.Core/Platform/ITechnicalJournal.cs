namespace Domenia.Core;

/// <summary>
/// Technical journal of the application (%LOCALAPPDATA%\Domenia\logs in the host). Never receives page input, secrets or
/// bulk data; implementations never throw.
/// </summary>
public interface ITechnicalJournal
{
    void Info(string message);

    void Warning(string message);

    void Error(string message, Exception exception);
}

/// <summary>Journal that keeps nothing (pure tests, tools).</summary>
public sealed class SilentTechnicalJournal : ITechnicalJournal
{
    public static SilentTechnicalJournal Instance { get; } = new();

    public void Info(string message)
    {
    }

    public void Warning(string message)
    {
    }

    public void Error(string message, Exception exception)
    {
    }
}
