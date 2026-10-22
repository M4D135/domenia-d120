using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// Settings of the « Fiche » screen read from Domenia.config.json next to the executable (Security.* and CallSheet.TicketTemplate,
/// format of Domenia 1, read only). Found by the composition like any screen reader, in both modes: the constructor takes the
/// directory source only to be discovered and reads nothing; the file is read once, off the UI thread, at the first call.
/// An absent, oversized or invalid file never blocks anything: the defaults of Domenia 1 apply and the reason is kept (never
/// the content of the file). A read that fails (file locked by a backup or an antivirus) is not kept: the next call tries again.
/// </summary>
public sealed class FicheSettingsFileReader : IFicheSettingsReader
{
    private readonly Lock gate = new();
    private readonly string file;
    private FicheConfiguration? kept;

    public FicheSettingsFileReader(IDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        file = Path.Combine(AppContext.BaseDirectory, LegacyConfiguration.FileName);
    }

    public Task<FicheConfiguration> ReadAsync(CancellationToken cancellationToken)
    {
        lock (gate)
        {
            if (kept is not null)
            {
                return Task.FromResult(kept);
            }
        }
        return Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            var (configuration, keep) = Load(file);
            if (keep)
            {
                lock (gate)
                {
                    kept ??= configuration;
                    return kept;
                }
            }
            return configuration;
        }, cancellationToken);
    }

    private static (FicheConfiguration Configuration, bool Keep) Load(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists)
            {
                return (FicheConfiguration.Absent, true);
            }
            if (info.Length > LegacyConfiguration.MaxBytes)
            {
                return (FicheConfiguration.Invalid("fichier de plus de 1 Mo"), true);
            }
            return (FicheConfiguration.Parse(File.ReadAllBytes(path)), true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return (FicheConfiguration.Invalid("lecture impossible, " + ex.GetType().Name), false);
        }
    }
}
