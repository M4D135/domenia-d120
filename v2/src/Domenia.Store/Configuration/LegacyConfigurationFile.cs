using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// Reads Domenia.config.json next to the executable (format of Domenia 1, read only). An absent, oversized or invalid
/// file never blocks the start: it is traced (file name and reason only, never its content) and the defaults apply.
/// </summary>
public static class LegacyConfigurationFile
{
    public static LegacyConfiguration Read(string folder, ITechnicalJournal log)
    {
        ArgumentException.ThrowIfNullOrEmpty(folder);
        ArgumentNullException.ThrowIfNull(log);
        var result = Load(Path.Combine(folder, LegacyConfiguration.FileName));
        switch (result.State)
        {
            case ConfigurationFileState.Absent:
                log.Info($"{LegacyConfiguration.FileName} absent : réglages par défaut.");
                break;
            case ConfigurationFileState.Invalid:
                log.Warning($"{LegacyConfiguration.FileName} ignoré ({result.Problem}) : réglages par défaut.");
                break;
            default:
                log.Info($"{LegacyConfiguration.FileName} lu : Auth.DemoProvider {(result.DemoProvider ? "activé" : "non activé")}.");
                break;
        }
        return result;
    }

    private static LegacyConfiguration Load(string file)
    {
        try
        {
            var info = new FileInfo(file);
            if (!info.Exists)
            {
                return LegacyConfiguration.Absent;
            }
            if (info.Length > LegacyConfiguration.MaxBytes)
            {
                return LegacyConfiguration.Invalid("fichier de plus de 1 Mo");
            }
            return LegacyConfiguration.Parse(File.ReadAllBytes(file));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return LegacyConfiguration.Invalid("lecture impossible, " + ex.GetType().Name);
        }
    }
}
