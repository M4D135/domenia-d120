using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Store;

/// <summary>One bounded, local configuration read on first use; construction never reads or contacts anything.</summary>
public sealed class PosteSettingsFileReader : IPosteSettingsReader
{
    private readonly string file;
    private PosteConfiguration? current;
    public PosteSettingsFileReader(IDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        file = Path.Combine(AppContext.BaseDirectory, LegacyConfiguration.FileName);
    }

    public async Task<PosteConfiguration> CurrentAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (Volatile.Read(ref current) is { } kept) { return kept; }
        var (value, retain) = await Task.Run(() => Load(file), cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        if (!retain) { return value; }
        return Interlocked.CompareExchange(ref current, value, null) ?? value;
    }

    internal static (PosteConfiguration Value, bool Retain) Load(string file)
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length > LegacyConfiguration.MaxBytes) { return (PosteConfiguration.Invalid("fichier de plus de 1 Mo"), true); }
            var bytes = new byte[LegacyConfiguration.MaxBytes + 1];
            var count = 0;
            while (count < bytes.Length)
            {
                var read = stream.Read(bytes, count, bytes.Length - count);
                if (read == 0) { break; }
                count += read;
            }
            return (PosteConfiguration.Parse(bytes.AsSpan(0, count)), true);
        }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { return (PosteConfiguration.Defaults, true); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return (PosteConfiguration.Invalid("lecture locale impossible, " + ex.GetType().Name), false); }
    }
}
