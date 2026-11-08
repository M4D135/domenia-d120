using Domenia.Core;

namespace Domenia.App.Settings;

/// <summary>The configuration displayed and consumed during this context. A later file change requires a new launch.</summary>
internal sealed class ConfigurationHostSnapshot
{
    private ConfigurationHostSnapshot(ConfigurationReport report) { Report = report; }
    internal ConfigurationReport Report { get; }
    internal QueueTiming QueueTiming => Domenia.Core.QueueTiming.From(Report);

    internal static ConfigurationHostSnapshot From(EngineContext context) => context.Shared(static value => new ConfigurationHostSnapshot(value.Configuration.Report));
    internal static ConfigurationReport Read(string folder, ITechnicalJournal log) => ReadRuntime(folder, log).Report;

    internal static RuntimeConfiguration ReadRuntime(string folder, ITechnicalJournal log)
    {
        byte[]? bytes;
        try
        {
            using var stream = new FileStream(Path.Combine(folder, LegacyConfiguration.FileName), FileMode.Open,
                FileAccess.Read, FileShare.Read);
            if (stream.Length > LegacyConfiguration.MaxBytes) bytes = new byte[LegacyConfiguration.MaxBytes + 1];
            else
            {
                bytes = new byte[(int)stream.Length];
                stream.ReadExactly(bytes);
                if (stream.ReadByte() != -1) bytes = new byte[LegacyConfiguration.MaxBytes + 1];
            }
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { bytes = null; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Configuration de session illisible ({error.GetType().Name}) ; défauts conservés.");
            bytes = [0xFF];
        }
        return RuntimeConfiguration.Read(bytes, LegacyConfiguration.FileName + " (à côté de Domenia.exe, instantané du démarrage)");
    }
}
